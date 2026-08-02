-- Synchronize immutable snapshot construction and run creation after the
-- versioned-workforce migration. Earlier branch bodies did not persist the
-- Matrix content/workforce hashes required for historical reproducibility.

create or replace function solver_private.build_snapshot_payload_v2(
  p_run_id uuid,
  p_month date,
  p_matrix_version_id uuid,
  p_scenario_id uuid,
  p_scope_type text,
  p_scope_role_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_month date := date_trunc('month',p_month)::date;
  v_period_end date := (date_trunc('month',p_month)+interval '1 month - 1 day')::date;
  v_matrix public.matrix_versions%rowtype;
  v_settings jsonb := '{}'::jsonb;
  v_snapshot jsonb;
  v_scenario record;
  v_seed integer;
  v_currency text;
  v_timezone text;
  v_budgets jsonb := '[]'::jsonb;
  v_external jsonb := '[]'::jsonb;
  v_baseline jsonb := '[]'::jsonb;
  v_locked jsonb := '[]'::jsonb;
  v_slot_count bigint:=0;
  v_employee_count bigint:=0;
begin
  select * into v_matrix
  from public.matrix_versions mv
  where mv.id=p_matrix_version_id and mv.schema_version>=2;
  if v_matrix.id is null then raise exception 'MATRIX_V2_NOT_FOUND'; end if;
  if coalesce(v_matrix.content_hash,'') !~ '^[0-9a-f]{64}$'
    or coalesce(v_matrix.workforce_hash,'') !~ '^[0-9a-f]{64}$' then
    raise exception 'MATRIX_V2_NOT_PUBLISHED';
  end if;

  v_currency := upper(coalesce(v_matrix.settings->>'currency',''));
  if not public.matrix_v2_is_iso_4217_currency(v_currency) then
    raise exception 'INVALID_MATRIX_CURRENCY';
  end if;
  if exists(
    select 1 from public.matrix_pay_rules_v2 p
    where p.matrix_version_id=p_matrix_version_id and p.active
      and p.currency<>v_currency
  ) or exists(
    select 1 from public.matrix_scenario_budgets_v2 b
    where b.matrix_version_id=p_matrix_version_id and b.currency<>v_currency
  ) or exists(
    select 1
    from public.employee_pay_rates_v2 r
    join public.matrix_employee_profiles_v2 profile
      on profile.matrix_version_id=p_matrix_version_id
      and profile.employee_id=r.employee_id
      and profile.active and profile.archived_at is null
      and (profile.employment_start is null or profile.employment_start<=v_period_end)
      and (profile.employment_end is null or profile.employment_end>=v_month)
    where r.active and r.valid_from<=v_period_end
      and (r.valid_to is null or r.valid_to>=v_month)
      and (p_scope_role_id is null or exists(
        select 1 from public.matrix_employee_roles_v2 role_grant
        where role_grant.matrix_version_id=p_matrix_version_id
          and role_grant.employee_id=profile.employee_id
          and role_grant.role_id=p_scope_role_id and role_grant.active
          and (role_grant.valid_from is null or role_grant.valid_from<=v_period_end)
          and (role_grant.valid_to is null or role_grant.valid_to>=v_month)
      ))
      and r.currency<>v_currency
  ) then raise exception 'MIXED_CURRENCIES_UNSUPPORTED'; end if;

  v_settings := coalesce(v_matrix.settings,'{}'::jsonb);
  for v_scenario in
    with recursive chain as (
      select s.id,s.parent_scenario_id,s.settings_overrides,0 depth
      from public.matrix_scenarios_v2 s
      where s.id=p_scenario_id and s.matrix_version_id=p_matrix_version_id
      union all
      select p.id,p.parent_scenario_id,p.settings_overrides,c.depth+1
      from public.matrix_scenarios_v2 p join chain c on c.parent_scenario_id=p.id
      where p.matrix_version_id=p_matrix_version_id and c.depth<32
    )
    select * from chain order by depth desc
  loop
    v_settings := v_settings||coalesce(v_scenario.settings_overrides,'{}'::jsonb);
  end loop;
  v_settings := (v_settings-'currency')||jsonb_build_object('currency',v_currency);
  v_timezone := nullif(v_settings->>'timezone','');
  if not exists(select 1 from pg_timezone_names where name=v_timezone) then
    raise exception 'INVALID_MATRIX_TIMEZONE';
  end if;
  if coalesce(v_settings->>'minimumRestMinutes','') !~ '^[0-9]+$'
    or (v_settings->>'minimumRestMinutes')::integer<0
    or coalesce(v_settings->>'maximumShiftsPerDay','') !~ '^[0-9]+$'
    or (v_settings->>'maximumShiftsPerDay')::integer not between 1 and 24
    or jsonb_typeof(v_settings->'missingAvailabilityMeansAvailable')<>'boolean'
    or jsonb_typeof(v_settings->'requireOptimal')<>'boolean'
  then raise exception 'INVALID_MATRIX_SETTINGS'; end if;
  if exists(
    select 1
    from public.matrix_employee_profiles_v2 profile
    cross join lateral generate_series(
      greatest(v_month,coalesce(profile.employment_start,v_month)),
      least(v_period_end,coalesce(profile.employment_end,v_period_end)),
      interval '1 day'
    ) work_day
    where profile.matrix_version_id=p_matrix_version_id
      and profile.active and profile.archived_at is null
      and (p_scope_role_id is null or exists(
        select 1 from public.matrix_employee_roles_v2 role_grant
        where role_grant.matrix_version_id=p_matrix_version_id
          and role_grant.employee_id=profile.employee_id
          and role_grant.role_id=p_scope_role_id and role_grant.active
          and (role_grant.valid_from is null
            or role_grant.valid_from<=work_day::date)
          and (role_grant.valid_to is null or role_grant.valid_to>=work_day::date)
      ))
      and not exists(
        select 1 from public.employee_pay_rates_v2 rate
        where rate.employee_id=profile.employee_id and rate.active
          and rate.valid_from<=work_day::date
          and (rate.valid_to is null or rate.valid_to>=work_day::date)
      )
  ) then raise exception 'EMPLOYEE_PAY_RATE_COVERAGE_GAP'; end if;
  v_budgets := solver_private.resolved_budgets_v2(
    v_month,p_matrix_version_id,p_scenario_id,p_scope_role_id
  );

  select coalesce(sum(d.required_count),0) into v_slot_count
  from solver_private.resolved_demand_v2(
    v_month,p_matrix_version_id,p_scenario_id,p_scope_role_id
  ) d;
  select count(*) into v_employee_count
  from public.matrix_employee_profiles_v2 profile
  where profile.matrix_version_id=p_matrix_version_id
    and profile.active and profile.archived_at is null
    and (profile.employment_start is null or profile.employment_start<=v_period_end)
    and (profile.employment_end is null or profile.employment_end>=v_month)
    and (p_scope_role_id is null or exists(
      select 1 from public.matrix_employee_roles_v2 role_grant
      where role_grant.matrix_version_id=p_matrix_version_id
        and role_grant.employee_id=profile.employee_id
        and role_grant.role_id=p_scope_role_id and role_grant.active
        and (role_grant.valid_from is null or role_grant.valid_from<=v_period_end)
        and (role_grant.valid_to is null or role_grant.valid_to>=v_month)
    ));
  if v_slot_count>25000 then raise exception 'SOLVER_CAPACITY_SLOT_LIMIT'; end if;
  if v_employee_count>5000 then raise exception 'SOLVER_CAPACITY_EMPLOYEE_LIMIT'; end if;
  if v_slot_count*v_employee_count>2000000 then
    raise exception 'SOLVER_CAPACITY_VARIABLE_LIMIT';
  end if;

  v_seed := coalesce(
    nullif(v_settings->>'randomSeed','')::integer,
    (abs(hashtextextended(p_run_id::text,0))%2147483647)::integer
  );

  select jsonb_build_object(
    'schemaVersion',2,
    'runId',p_run_id,
    'matrixVersionId',p_matrix_version_id,
    'matrixContentHash',v_matrix.content_hash,
    'workforceHash',v_matrix.workforce_hash,
    'scenarioId',p_scenario_id,
    'currency',v_currency,
    'periodStart',v_month,
    'periodEnd',v_period_end,
    'scope',jsonb_build_object('type',p_scope_type,'roleId',p_scope_role_id),
    'settings',jsonb_build_object(
      'timezone',v_timezone,
      'missingAvailabilityMeansAvailable',(v_settings->>'missingAvailabilityMeansAvailable')::boolean,
      'defaultMinimumRestMinutes',(v_settings->>'minimumRestMinutes')::integer,
      'maximumShiftsPerDay',(v_settings->>'maximumShiftsPerDay')::integer,
      'onlyMorningBeforeMinute',nullif(v_settings->>'onlyMorningBeforeMinute','')::integer,
      'onlyEveningAfterMinute',nullif(v_settings->>'onlyEveningAfterMinute','')::integer,
      'requireOptimal',(v_settings->>'requireOptimal')::boolean,
      'randomSeed',v_seed
    ),
    'strategies',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',s.id,'code',s.code,'label',s.name,'description',s.description,
        'sortOrder',ss.sort_order,
        'timeLimitSeconds',coalesce(
          nullif(ss.solver_overrides->>'maxTimeSeconds','')::integer,
          nullif(s.solver_options->>'maxTimeSeconds','')::integer,300
        ),
        'randomSeed',coalesce(
          nullif(ss.solver_overrides->>'randomSeed','')::integer,
          nullif(s.solver_options->>'randomSeed','')::integer,v_seed
        ),
        'objectiveTerms',coalesce((
          select jsonb_agg(jsonb_build_object(
            'tier',coalesce(nullif(cfg.value->>'tier','')::smallint,o.tier),
            'metric',o.metric_code,
            'weight',coalesce(nullif(cfg.value->>'weight','')::bigint,o.weight),
            'direction',case upper(coalesce(cfg.value->>'direction',o.direction))
              when 'MAXIMIZE' then 'MAX' when 'MAX' then 'MAX' else 'MIN' end,
            'tolerance',coalesce(
              nullif(cfg.value->>'tolerance','')::bigint,o.tolerance
            ),
            'parameters',o.parameters||coalesce(cfg.value->'parameters','{}'::jsonb)
          ) order by
            coalesce(nullif(cfg.value->>'tier','')::smallint,o.tier),
            o.sort_order,o.metric_code)
          from public.matrix_strategy_objectives_v2 o
          cross join lateral (select coalesce(
            ss.objective_overrides->upper(o.metric_code),'{}'::jsonb
          ) value) cfg
          where o.strategy_id=s.id and o.matrix_version_id=p_matrix_version_id
            and o.active and coalesce((cfg.value->>'active')::boolean,true)
        ),'[]'::jsonb)
      ) order by ss.sort_order,s.sort_order,s.code)
      from (
        with recursive scenario_chain as (
          select sc.id,sc.parent_scenario_id,0 depth
          from public.matrix_scenarios_v2 sc
          where sc.id=p_scenario_id and sc.matrix_version_id=p_matrix_version_id
          union all
          select parent.id,parent.parent_scenario_id,chain.depth+1
          from public.matrix_scenarios_v2 parent
          join scenario_chain chain on chain.parent_scenario_id=parent.id
          where parent.matrix_version_id=p_matrix_version_id and chain.depth<32
        ), raw_links as (
          select link.id,link.strategy_id,link.sort_order,link.active,
            link.objective_overrides,link.solver_overrides,chain.depth
          from scenario_chain chain
          join public.matrix_scenario_strategies_v2 link
            on link.scenario_id=chain.id
          where link.matrix_version_id=p_matrix_version_id
        )
        select link.strategy_id,
          (array_agg(link.sort_order order by link.depth,link.id))[1] sort_order,
          (array_agg(link.active order by link.depth,link.id))[1] active,
          solver_private.jsonb_deep_merge_array_v2(array_agg(
            link.objective_overrides order by link.depth desc,link.id
          )) objective_overrides,
          solver_private.jsonb_deep_merge_array_v2(array_agg(
            link.solver_overrides order by link.depth desc,link.id
          )) solver_overrides
        from raw_links link
        group by link.strategy_id
      ) ss
      join public.matrix_strategies_v2 s
        on s.id=ss.strategy_id and s.matrix_version_id=p_matrix_version_id
      where ss.active and s.active
    ),'[]'::jsonb),
    'roles',coalesce((
      select jsonb_agg(jsonb_build_object('id',r.id,'code',r.code,'label',r.name)
        order by r.sort_order,r.code)
      from public.matrix_roles_v2 r
      where r.matrix_version_id=p_matrix_version_id and r.active
    ),'[]'::jsonb),
    'duties',coalesce((
      select jsonb_agg(jsonb_build_object('id',d.id,'code',d.code,'label',d.name)
        order by d.sort_order,d.code)
      from public.matrix_duties_v2 d
      where d.matrix_version_id=p_matrix_version_id and d.active
    ),'[]'::jsonb),
    'locations',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',l.id,'code',l.code,'label',l.name,'timezone',l.timezone
      ) order by l.sort_order,l.code)
      from public.matrix_locations_v2 l
      where l.matrix_version_id=p_matrix_version_id and l.active
    ),'[]'::jsonb),
    'shiftTemplates',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',st.id,'locationId',st.location_id,'code',st.code,'label',st.name,
        'startTime',to_char(st.starts_at,'HH24:MI'),
        'endTime',to_char(st.ends_at,'HH24:MI'),
        'endsNextDay',st.ends_next_day,'weekdays',to_jsonb(st.day_mask)
      ) order by st.sort_order,st.code)
      from public.matrix_shift_templates_v2 st
      join public.matrix_locations_v2 l on l.id=st.location_id and l.active
      where st.matrix_version_id=p_matrix_version_id and st.active
    ),'[]'::jsonb),
    'demand',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',d.demand_id,'shiftTemplateId',d.shift_template_id,
        'roleId',d.role_id,'dutyIds',to_jsonb(d.duty_ids),
        'requiredCount',d.required_count,'dates',jsonb_build_array(d.work_date)
      ) order by d.starts_at,d.location_id,d.role_id,d.demand_id)
      from solver_private.resolved_demand_v2(
        v_month,p_matrix_version_id,p_scenario_id,p_scope_role_id
      ) d
    ),'[]'::jsonb),
    'slots',coalesce((
      select jsonb_agg(jsonb_build_object(
        'slotId',d.work_date::text||'|'||d.shift_template_id::text||'|'||
          d.role_id::text||'|'||coalesce(array_to_string(d.duty_ids,','),'-')||'|'||
          d.demand_id::text||'|'||seat.seat_index::text,
        'demandId',d.demand_id,
        'occurrenceId',d.work_date::text||'|'||d.shift_template_id::text,
        'seatIndex',seat.seat_index,'date',d.work_date,
        'shiftTemplateId',d.shift_template_id,'locationId',d.location_id,
        'roleId',d.role_id,'dutyIds',to_jsonb(d.duty_ids),
        'start',d.starts_at,'end',d.ends_at,'durationMinutes',d.duration_minutes
      ) order by d.starts_at,d.location_id,d.role_id,
        d.work_date::text||'|'||d.shift_template_id::text||'|'||d.role_id::text||'|'||
        coalesce(array_to_string(d.duty_ids,','),'-')||'|'||d.demand_id::text||'|'||seat.seat_index::text)
      from solver_private.resolved_demand_v2(
        v_month,p_matrix_version_id,p_scenario_id,p_scope_role_id
      ) d
      cross join lateral generate_series(1,d.required_count) seat(seat_index)
    ),'[]'::jsonb),
    'employees',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',profile.employee_id,
        'roleIds',coalesce((select jsonb_agg(er.role_id::text order by er.role_id::text)
          from public.matrix_employee_roles_v2 er
          where er.matrix_version_id=p_matrix_version_id
            and er.employee_id=profile.employee_id and er.active
            and (er.valid_from is null or er.valid_from<=v_period_end)
            and (er.valid_to is null or er.valid_to>=v_month)),'[]'::jsonb),
        'roleGrants',coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'roleId',er.role_id,'validFrom',er.valid_from,'validTo',er.valid_to
          )) order by er.role_id::text,er.valid_from nulls first,er.id)
          from public.matrix_employee_roles_v2 er
          where er.matrix_version_id=p_matrix_version_id
            and er.employee_id=profile.employee_id and er.active
            and (er.valid_from is null or er.valid_from<=v_period_end)
            and (er.valid_to is null or er.valid_to>=v_month)),'[]'::jsonb),
        'dutyIds',coalesce((select jsonb_agg(distinct ed.duty_id::text order by ed.duty_id::text)
          from public.matrix_employee_duties_v2 ed
          where ed.matrix_version_id=p_matrix_version_id
            and ed.employee_id=profile.employee_id and ed.active
            and ed.role_id is null and ed.location_id is null
            and (ed.valid_from is null or ed.valid_from<=v_period_end)
            and (ed.valid_to is null or ed.valid_to>=v_month)),'[]'::jsonb),
        'dutyGrants',coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'dutyId',ed.duty_id,'roleId',ed.role_id,'locationId',ed.location_id,
            'validFrom',ed.valid_from,'validTo',ed.valid_to
          )) order by ed.duty_id::text,ed.role_id::text nulls first,
            ed.location_id::text nulls first,ed.valid_from nulls first,ed.id)
          from public.matrix_employee_duties_v2 ed
          where ed.matrix_version_id=p_matrix_version_id
            and ed.employee_id=profile.employee_id and ed.active
            and (ed.valid_from is null or ed.valid_from<=v_period_end)
            and (ed.valid_to is null or ed.valid_to>=v_month)),'[]'::jsonb),
        'locationIds',coalesce((select jsonb_agg(el.location_id::text order by el.location_id::text)
          from public.matrix_employee_locations_v2 el
          where el.matrix_version_id=p_matrix_version_id
            and el.employee_id=profile.employee_id and el.active
            and el.standard_allowed
            and (el.valid_from is null or el.valid_from<=v_period_end)
            and (el.valid_to is null or el.valid_to>=v_month)),'[]'::jsonb),
        'locationGrants',coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'locationId',el.location_id,'standardAllowed',el.standard_allowed,
            'overtimeAllowed',el.overtime_allowed,'validFrom',el.valid_from,
            'validTo',el.valid_to
          )) order by el.location_id::text,el.valid_from nulls first,el.id)
          from public.matrix_employee_locations_v2 el
          where el.matrix_version_id=p_matrix_version_id
            and el.employee_id=profile.employee_id and el.active
            and (el.valid_from is null or el.valid_from<=v_period_end)
            and (el.valid_to is null or el.valid_to>=v_month)),'[]'::jsonb),
        'homeLocationIds',coalesce((select jsonb_agg(el.location_id::text order by el.location_id::text)
          from public.matrix_employee_locations_v2 el
          where el.matrix_version_id=p_matrix_version_id
            and el.employee_id=profile.employee_id
            and el.active and el.home_location),'[]'::jsonb),
        -- Legacy fields are only a compatibility fallback when no dated v2
        -- period covers a slot; they must never borrow a future period's rate.
        'baseHourlyRateMinor',round(e.hourly_rate*100)::bigint,
        'contractCode',coalesce(hr.contract_type,'OTHER'),
        'payRatePeriods',coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'validFrom',pr.valid_from,'validTo',pr.valid_to,
            'baseRateMinor',pr.base_rate_minor,
            'contractCode',coalesce(pr.contract_type,hr.contract_type,'OTHER')
          )) order by pr.valid_from,pr.id)
          from public.employee_pay_rates_v2 pr
          where pr.employee_id=profile.employee_id and pr.active
            and pr.valid_from<=v_period_end
            and (pr.valid_to is null or pr.valid_to>=v_month)),'[]'::jsonb),
        'employmentStart',profile.employment_start,
        'employmentEnd',profile.employment_end,
        'nominalMonthlyMinutes',profile.nominal_monthly_minutes,
        'maximumMonthlyMinutes',profile.maximum_monthly_minutes,
        'maximumWeeklyMinutes',profile.maximum_weekly_minutes,
        'maximumShiftsPerDay',(v_settings->>'maximumShiftsPerDay')::integer,
        'maximumConsecutiveDays',profile.maximum_consecutive_days,
        'minimumRestMinutes',coalesce(
          profile.minimum_rest_minutes,(v_settings->>'minimumRestMinutes')::integer
        ),
        'noWeekends',profile.no_weekends,
        'onlyMorningBeforeMinute',case when profile.only_morning then
          nullif(v_settings->>'onlyMorningBeforeMinute','')::integer else null end,
        'onlyEveningAfterMinute',case when profile.only_evening then
          nullif(v_settings->>'onlyEveningAfterMinute','')::integer else null end,
        'preferredShiftTemplateIds',coalesce((
          select jsonb_agg(st.id::text order by st.id::text)
          from public.matrix_shift_templates_v2 st
          where st.matrix_version_id=p_matrix_version_id and st.active
            and profile.preferred_shift_code is not null
            and st.code=profile.preferred_shift_code
        ),'[]'::jsonb),
        'preferredLocationIds',coalesce((
          select jsonb_agg(preferred.location_id order by preferred.location_id)
          from (
            select distinct ml.id::text location_id
            from public.employee_preferences ep
            join public.matrix_locations_v2 ml
              on ml.matrix_version_id=p_matrix_version_id and ml.active
              and (
                ml.id=case
                  when coalesce(
                    ep.preference_value->>'locationId',
                    ep.preference_value->>'location_id'
                  ) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
                  then coalesce(
                    ep.preference_value->>'locationId',
                    ep.preference_value->>'location_id'
                  )::uuid
                  else null
                end
                or upper(ml.code)=upper(coalesce(
                  ep.preference_value->>'locationCode',
                  ep.preference_value->>'location',
                  ep.preference_value->>'code'
                ))
              )
            where ep.employee_id=profile.employee_id and ep.status='ACTIVE'
              and ep.preference_type='PREFERRED_LOCATION'
              and ep.valid_from<=v_period_end and ep.valid_to>=v_month
          ) preferred
        ),'[]'::jsonb),
        'softDayOffDates',coalesce((
          select jsonb_agg(gs::date order by gs::date)
          from public.employee_preferences ep
          cross join lateral generate_series(ep.valid_from,ep.valid_to,interval '1 day') gs
          where ep.employee_id=profile.employee_id and ep.status='ACTIVE'
            and ep.preference_type='OTHER'
            and ep.preference_value->>'kind'='DAY_OFF'
            and ep.valid_from<=v_period_end and ep.valid_to>=v_month
        ),'[]'::jsonb)
      ) order by profile.employee_no)
      from public.matrix_employee_profiles_v2 profile
      join public.employees e on e.id=profile.employee_id
      left join public.employee_hr_profiles hr
        on hr.employee_id=profile.employee_id
      where profile.matrix_version_id=p_matrix_version_id
        and profile.active and profile.archived_at is null
        and (profile.employment_start is null
          or profile.employment_start<=v_period_end)
        and (profile.employment_end is null or profile.employment_end>=v_month)
        and (p_scope_role_id is null or exists(
          select 1 from public.matrix_employee_roles_v2 er
          where er.matrix_version_id=p_matrix_version_id
            and er.employee_id=profile.employee_id
            and er.role_id=p_scope_role_id and er.active
            and (er.valid_from is null or er.valid_from<=v_period_end)
            and (er.valid_to is null or er.valid_to>=v_month)
        ))
    ),'[]'::jsonb),
    'availabilityWindows',coalesce((
      select jsonb_agg(jsonb_build_object(
        'employeeId',c.employee_id,'start',lower(c.time_range),'end',upper(c.time_range)
      ) order by c.employee_id,lower(c.time_range))
      from public.employee_time_constraints_v2 c
      where c.status='ACTIVE' and c.constraint_kind='AVAILABLE_WINDOW'
        and c.time_range && tstzrange(v_month::timestamp at time zone v_timezone,
          (v_period_end+1)::timestamp at time zone v_timezone,'[)')
        and exists(
          select 1 from public.matrix_employee_profiles_v2 profile
          where profile.matrix_version_id=p_matrix_version_id
            and profile.employee_id=c.employee_id
            and profile.active and profile.archived_at is null
            and (profile.employment_start is null or profile.employment_start<=v_period_end)
            and (profile.employment_end is null or profile.employment_end>=v_month)
            and (p_scope_role_id is null or exists(
              select 1 from public.matrix_employee_roles_v2 role_grant
              where role_grant.matrix_version_id=p_matrix_version_id
                and role_grant.employee_id=profile.employee_id
                and role_grant.role_id=p_scope_role_id and role_grant.active
                and (role_grant.valid_from is null or role_grant.valid_from<=v_period_end)
                and (role_grant.valid_to is null or role_grant.valid_to>=v_month)
            ))
        )
    ),'[]'::jsonb),
    'hardBlocks',coalesce((
      select jsonb_agg(jsonb_build_object(
        'employeeId',c.employee_id,'start',lower(c.time_range),'end',upper(c.time_range),
        'kind',c.constraint_kind,'source',c.source
      ) order by c.employee_id,lower(c.time_range))
      from public.employee_time_constraints_v2 c
      where c.status='ACTIVE' and c.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
        and c.time_range && tstzrange(v_month::timestamp at time zone v_timezone,
          (v_period_end+1)::timestamp at time zone v_timezone,'[)')
        and exists(
          select 1 from public.matrix_employee_profiles_v2 profile
          where profile.matrix_version_id=p_matrix_version_id
            and profile.employee_id=c.employee_id
            and profile.active and profile.archived_at is null
            and (profile.employment_start is null or profile.employment_start<=v_period_end)
            and (profile.employment_end is null or profile.employment_end>=v_month)
            and (p_scope_role_id is null or exists(
              select 1 from public.matrix_employee_roles_v2 role_grant
              where role_grant.matrix_version_id=p_matrix_version_id
                and role_grant.employee_id=profile.employee_id
                and role_grant.role_id=p_scope_role_id and role_grant.active
                and (role_grant.valid_from is null or role_grant.valid_from<=v_period_end)
                and (role_grant.valid_to is null or role_grant.valid_to>=v_month)
            ))
        )
    ),'[]'::jsonb),
    'externalAssignments','[]'::jsonb,
    'lockedAssignments','[]'::jsonb,
    'baselineAssignments','[]'::jsonb,
    'payRules',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',pr.id,'calculationType',pr.calculation_method,
        'currency',pr.currency,
        'values',jsonb_strip_nulls(jsonb_build_object(
          'amountMinor',coalesce(ov.amount_minor,pr.amount_minor),
          'rateMinorPerHour',coalesce(ov.rate_minor_per_hour,pr.rate_minor_per_hour),
          'percentBasisPoints',coalesce(ov.percent_basis_points,pr.percent_basis_points),
          'multiplierBasisPoints',coalesce(ov.multiplier_basis_points,pr.multiplier_basis_points),
          'thresholdMinutes',pr.threshold_minutes
        )),
        'conditions',coalesce(pr.condition_expression->'conditions','[]'::jsonb)
          ||coalesce((select jsonb_build_array(jsonb_build_object(
              'field','role_id','operator','IN','value',jsonb_agg(x.role_id::text order by x.role_id::text)
            )) from public.matrix_pay_rule_roles_v2 x where x.pay_rule_id=pr.id
              having count(*)>0),'[]'::jsonb)
          ||coalesce((select jsonb_build_array(jsonb_build_object(
              'field','duty_ids','operator',
              case when bool_or(x.match_mode='ALL') then 'CONTAINS_ALL' else 'CONTAINS_ANY' end,
              'value',jsonb_agg(x.duty_id::text order by x.duty_id::text)
            )) from public.matrix_pay_rule_duties_v2 x where x.pay_rule_id=pr.id
              having count(*)>0),'[]'::jsonb)
          ||coalesce((select jsonb_build_array(jsonb_build_object(
              'field','location_id','operator','IN',
              'value',jsonb_agg(x.location_id::text order by x.location_id::text)
            )) from public.matrix_pay_rule_locations_v2 x where x.pay_rule_id=pr.id
              having count(*)>0),'[]'::jsonb)
          ||coalesce((select jsonb_build_array(jsonb_build_object(
              'field','shift_template_id','operator','IN',
              'value',jsonb_agg(x.shift_template_id::text order by x.shift_template_id::text)
            )) from public.matrix_pay_rule_shifts_v2 x where x.pay_rule_id=pr.id
              having count(*)>0),'[]'::jsonb),
        'stackingGroup',pr.stacking_group,'stackingMode',pr.stacking_mode,
        'priority',pr.priority,'active',pr.active and coalesce(ov.enabled,true),
        'effectiveFrom',pr.valid_from,'effectiveTo',pr.valid_to,
        'dayMask',to_jsonb(pr.day_mask),'localStart',pr.local_start,'localEnd',pr.local_end,
        'roleIds',coalesce((select jsonb_agg(x.role_id::text order by x.role_id::text)
          from public.matrix_pay_rule_roles_v2 x where x.pay_rule_id=pr.id),'[]'::jsonb),
        'dutyIds',coalesce((select jsonb_agg(x.duty_id::text order by x.duty_id::text)
          from public.matrix_pay_rule_duties_v2 x where x.pay_rule_id=pr.id),'[]'::jsonb),
        'locationIds',coalesce((select jsonb_agg(x.location_id::text order by x.location_id::text)
          from public.matrix_pay_rule_locations_v2 x where x.pay_rule_id=pr.id),'[]'::jsonb),
        'shiftTemplateIds',coalesce((select jsonb_agg(x.shift_template_id::text order by x.shift_template_id::text)
          from public.matrix_pay_rule_shifts_v2 x where x.pay_rule_id=pr.id),'[]'::jsonb)
      ) order by pr.priority,pr.code)
      from public.matrix_pay_rules_v2 pr
      left join lateral (
        with recursive scenario_chain as (
          select sc.id,sc.parent_scenario_id,0 depth
          from public.matrix_scenarios_v2 sc
          where sc.id=p_scenario_id and sc.matrix_version_id=p_matrix_version_id
          union all
          select parent.id,parent.parent_scenario_id,chain.depth+1
          from public.matrix_scenarios_v2 parent
          join scenario_chain chain on chain.parent_scenario_id=parent.id
          where parent.matrix_version_id=p_matrix_version_id and chain.depth<32
        )
        select
          (array_agg(override.enabled order by chain.depth,override.id))[1]
            enabled,
          (array_agg(override.amount_minor order by chain.depth,override.id)
            filter(where override.amount_minor is not null))[1] amount_minor,
          (array_agg(override.rate_minor_per_hour order by chain.depth,override.id)
            filter(where override.rate_minor_per_hour is not null))[1]
            rate_minor_per_hour,
          (array_agg(override.percent_basis_points order by chain.depth,override.id)
            filter(where override.percent_basis_points is not null))[1]
            percent_basis_points,
          (array_agg(override.multiplier_basis_points order by chain.depth,override.id)
            filter(where override.multiplier_basis_points is not null))[1]
            multiplier_basis_points
        from scenario_chain chain
        join public.matrix_scenario_pay_rule_overrides_v2 override
          on override.scenario_id=chain.id and override.pay_rule_id=pr.id
        where override.matrix_version_id=p_matrix_version_id
      ) ov on true
      where pr.matrix_version_id=p_matrix_version_id and pr.active
    ),'[]'::jsonb),
    'budgets',v_budgets,
    'budget',coalesce((
      select jsonb_build_object(
        'amountMinor',(b.value->>'amountMinor')::bigint,
        'hard',coalesce((b.value->>'hard')::boolean,false),
        'currency',v_currency
      )
      from jsonb_array_elements(v_budgets) b
      where nullif(b.value->>'locationId','') is null
        and nullif(b.value->>'roleId','') is null
        and nullif(b.value->>'dutyId','') is null
      limit 1
    ),jsonb_build_object(
      'amountMinor',null,'hard',false,'currency',v_currency
    ))
  ) into v_snapshot;
  if jsonb_array_length(v_snapshot->'strategies')>32 then
    raise exception 'SOLVER_CAPACITY_STRATEGY_LIMIT';
  end if;

  -- Previous selected v2 assignments and the latest legacy plan are projected
  -- onto deterministic slot IDs. They remain soft baseline hints unless they
  -- were explicitly locked. For ROLE runs, assignments owned by other roles
  -- are hard external time blocks and prevent cross-role collisions.
  with chosen_legacy_plan as (
    select p.id from public.plans p where p.month=v_month
    order by case p.status when 'PUBLISHED' then 1 when 'READY' then 2 else 3 end,
      p.version desc,p.created_at desc limit 1
  ), legacy_numbered as (
    select a.employee_id,a.locked,sh.starts_at,sh.ends_at,sh.shift_date,
      mt.id shift_template_id,mr.id role_id,
      row_number() over(
        partition by sh.shift_date,mt.id,mr.id order by a.locked desc,a.id
      ) seat_number
    from chosen_legacy_plan cp
    join public.shifts sh on sh.plan_id=cp.id
    join public.assignments a on a.shift_id=sh.id
    join public.locations old_location on old_location.id=sh.location_id
    join public.matrix_locations_v2 ml
      on ml.matrix_version_id=p_matrix_version_id and ml.code=old_location.code::text
    join public.matrix_shift_templates_v2 mt
      on mt.matrix_version_id=p_matrix_version_id and mt.location_id=ml.id
      and mt.code=sh.shift_code
    join public.matrix_roles_v2 mr
      on mr.matrix_version_id=p_matrix_version_id and mr.code=a.assigned_role::text
  ), snapshot_slots as (
    select slot.value->>'slotId' slot_id,(slot.value->>'date')::date shift_date,
      (slot.value->>'shiftTemplateId')::uuid shift_template_id,
      (slot.value->>'roleId')::uuid role_id,
      row_number() over(
        partition by (slot.value->>'date')::date,
          (slot.value->>'shiftTemplateId')::uuid,(slot.value->>'roleId')::uuid
        order by (slot.value->>'seatIndex')::integer,slot.value->>'slotId'
      ) seat_number
    from jsonb_array_elements(v_snapshot->'slots') slot
  ), legacy_projection as (
    select ss.slot_id,l.employee_id,l.locked,1 source_priority
    from legacy_numbered l join snapshot_slots ss
      on ss.shift_date=l.shift_date and ss.shift_template_id=l.shift_template_id
      and ss.role_id=l.role_id and ss.seat_number=l.seat_number
  ), selected_v2 as (
    select pa.slot_key slot_id,pa.employee_id,pa.locked,2 source_priority,
      coalesce(v.selected_at,v.created_at) selected_at
    from public.plan_assignments_v2 pa
    join public.plan_variants_v2 v on v.id=pa.variant_id and v.selected
    join public.optimization_runs_v2 r on r.id=v.run_id
    where r.month=v_month and r.matrix_version_id=p_matrix_version_id
      and r.request_engine='ORTOOLS_V2'
      and exists(select 1 from snapshot_slots ss where ss.slot_id=pa.slot_key)
  ), combined as (
    select slot_id,employee_id,locked,source_priority,null::timestamptz selected_at
    from legacy_projection
    union all
    select slot_id,employee_id,locked,source_priority,selected_at from selected_v2
  ), deduplicated as (
    select distinct on (slot_id) slot_id,employee_id,locked
    from combined order by slot_id,source_priority desc,selected_at desc nulls last
  ), scoped_baseline as (
    select d.*,exists(
      select 1 from jsonb_array_elements(v_snapshot->'employees') employee
      where employee.value->>'id'=d.employee_id::text
    ) employee_present
    from deduplicated d
  )
  select
    coalesce(jsonb_agg(jsonb_build_object('slotId',slot_id,'employeeId',employee_id)
      order by slot_id) filter(where employee_present),'[]'::jsonb),
    coalesce(jsonb_agg(jsonb_build_object('slotId',slot_id,'employeeId',employee_id)
      order by slot_id) filter(where locked),'[]'::jsonb)
  into v_baseline,v_locked from scoped_baseline;
  if exists(
    select 1 from jsonb_array_elements(v_locked) lock_item
    where not exists(
      select 1 from jsonb_array_elements(v_snapshot->'employees') employee
      where employee.value->>'id'=lock_item.value->>'employeeId'
    )
  ) then raise exception 'LOCKED_ASSIGNMENT_EMPLOYEE_OUTSIDE_SNAPSHOT'; end if;

  -- Assignments outside the generated scope stay hard. For ROLE runs that
  -- means the other roles in the same month. For every scope it also includes
  -- adjacent-month assignments, so rest and consecutive-day rules are not
  -- accidentally reset at midnight on the first/last day of the month.
  with target_role as (
    select code from public.matrix_roles_v2 where id=p_scope_role_id
  ), ranked_legacy_plans as (
    select p.id,p.month,row_number() over(
      partition by p.month
      order by case p.status when 'PUBLISHED' then 1 when 'READY' then 2 else 3 end,
        p.version desc,p.created_at desc
    ) plan_rank
    from public.plans p
    where p.month between (v_month-interval '1 month')::date
      and (v_month+interval '1 month')::date
  ), latest_selected_role_variants as (
    select ranked.variant_id
    from (
      select v.id variant_id,
        row_number() over(
          partition by r.scope_role_id
          order by coalesce(v.selected_at,v.created_at) desc,v.id desc
        ) selection_rank
      from public.plan_variants_v2 v
      join public.optimization_runs_v2 r on r.id=v.run_id
      where p_scope_type='ROLE'
        and r.month=v_month
        and r.matrix_version_id=p_matrix_version_id
        and r.scenario_id=p_scenario_id
        and r.request_engine='ORTOOLS_V2'
        and r.scope_type='ROLE'
        and r.scope_role_id is distinct from p_scope_role_id
        and v.selected
    ) ranked
    where ranked.selection_rank=1
  ), blocks as (
    select a.employee_id,sh.starts_at,sh.ends_at
    from ranked_legacy_plans cp
    join public.shifts sh on sh.plan_id=cp.id
    join public.assignments a on a.shift_id=sh.id
    left join target_role tr on true
    where cp.plan_rank=1 and (
      sh.shift_date<v_month
      or sh.shift_date>v_period_end
      or (p_scope_type='ROLE' and a.assigned_role::text<>tr.code)
    )
    union
    select pa.employee_id,ps.starts_at,ps.ends_at
    from public.plan_assignments_v2 pa
    join public.plan_shifts_v2 ps on ps.id=pa.shift_id
    join public.plan_variants_v2 v on v.id=pa.variant_id
    join public.optimization_runs_v2 r on r.id=v.run_id
    where r.month between (v_month-interval '1 month')::date
        and (v_month+interval '1 month')::date
      and (
        (
          v.status='PUBLISHED'
          and (
            ps.shift_date<v_month
            or ps.shift_date>v_period_end
          )
        )
        or (
          p_scope_type='ROLE'
          and r.month=v_month
          and v.id in (select x.variant_id from latest_selected_role_variants x)
          and pa.role_id is distinct from p_scope_role_id
        )
      )
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'employeeId',block.employee_id,'start',block.starts_at,'end',block.ends_at
  ) order by block.employee_id,block.starts_at,block.ends_at),'[]'::jsonb)
  into v_external
  from blocks block
  where exists(
    select 1 from jsonb_array_elements(v_snapshot->'employees') employee
    where employee.value->>'id'=block.employee_id::text
  );
  v_snapshot := jsonb_set(v_snapshot,'{baselineAssignments}',v_baseline,true);
  v_snapshot := jsonb_set(v_snapshot,'{lockedAssignments}',v_locked,true);
  v_snapshot := jsonb_set(v_snapshot,'{externalAssignments}',v_external,true);

  return v_snapshot;
end;
$$;

revoke all on function solver_private.build_snapshot_payload_v2(
  uuid,date,uuid,uuid,text,uuid
) from public,anon,authenticated;
grant execute on function solver_private.build_snapshot_payload_v2(
  uuid,date,uuid,uuid,text,uuid
) to service_role;

create or replace function public.optimizer_configuration_v2(p_month date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_month date:=date_trunc('month',p_month)::date;
  v_period_end date:=(date_trunc('month',p_month)+interval '1 month - 1 day')::date;
  v_engine text;
  v_enabled boolean;
  v_solver_version text;
  v_matrix public.matrix_versions%rowtype;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  select flag.engine,flag.enabled,nullif(trim(flag.config->>'solverVersion'),'')
  into v_engine,v_enabled,v_solver_version
  from public.solver_feature_flags flag
  where flag.flag_key='DEFAULT_ENGINE';
  if v_engine is null then raise exception 'SOLVER_ENGINE_CONFIGURATION_MISSING'; end if;
  if not coalesce(v_enabled,false) then raise exception 'SOLVER_DISABLED'; end if;
  if v_engine not in ('ALPHA15','SHADOW','ORTOOLS_V2') then
    raise exception 'SOLVER_ENGINE_CONFIGURATION_INVALID';
  end if;
  if v_engine='ALPHA15' then
    return jsonb_build_object('engine',v_engine,'enabled',true);
  end if;
  if length(coalesce(v_solver_version,'')) not between 1 and 200 then
    raise exception 'SOLVER_VERSION_CONFIGURATION_REQUIRED';
  end if;

  select * into v_matrix
  from public.matrix_versions matrix_version
  where matrix_version.status in ('ACTIVE','ARCHIVED')
    and matrix_version.schema_version>=2
    and matrix_version.effective_from<=v_month
    and coalesce(matrix_version.content_hash,'') ~ '^[0-9a-f]{64}$'
    and coalesce(matrix_version.workforce_hash,'') ~ '^[0-9a-f]{64}$'
  order by matrix_version.effective_from desc,matrix_version.version desc
  limit 1;
  if v_matrix.id is null then raise exception 'MATRIX_V2_FOR_MONTH_NOT_FOUND'; end if;

  return jsonb_build_object(
    'engine',v_engine,'enabled',true,'solverVersion',v_solver_version,
    'matrixVersion',jsonb_build_object(
      'id',v_matrix.id,'schemaVersion',v_matrix.schema_version,
      'effectiveFrom',v_matrix.effective_from,'settings',v_matrix.settings,
      'contentHash',v_matrix.content_hash,'workforceHash',v_matrix.workforce_hash
    ),
    'scenarios',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',scenario.id,'code',scenario.code,'name',scenario.name,
        'description',scenario.description,'isDefault',scenario.is_default,
        'sortOrder',scenario.sort_order,'parentScenarioId',scenario.parent_scenario_id,
        'available',(
          (scenario.valid_from is null or scenario.valid_from<=v_period_end)
          and (scenario.valid_to is null or scenario.valid_to>=v_month)
        )
      ) order by scenario.sort_order,scenario.name)
      from public.matrix_scenarios_v2 scenario
      where scenario.matrix_version_id=v_matrix.id and scenario.active
    ),'[]'::jsonb),
    'roles',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',role_row.id,'code',role_row.code,'name',role_row.name,
        'sortOrder',role_row.sort_order
      ) order by role_row.sort_order,role_row.name)
      from public.matrix_roles_v2 role_row
      where role_row.matrix_version_id=v_matrix.id and role_row.active
    ),'[]'::jsonb),
    'locations',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',location_row.id,'code',location_row.code,'name',location_row.name,
        'sortOrder',location_row.sort_order,'timezone',location_row.timezone
      ) order by location_row.sort_order,location_row.name)
      from public.matrix_locations_v2 location_row
      where location_row.matrix_version_id=v_matrix.id and location_row.active
    ),'[]'::jsonb),
    'strategies',coalesce((
      select jsonb_agg(jsonb_build_object('id',strategy.id) order by strategy.id)
      from public.matrix_strategies_v2 strategy
      where strategy.matrix_version_id=v_matrix.id and strategy.active
    ),'[]'::jsonb),
    'scenarioStrategies',coalesce((
      select jsonb_agg(jsonb_build_object(
        'scenarioId',link.scenario_id,'strategyId',link.strategy_id,
        'active',link.active
      ) order by link.scenario_id,link.sort_order,link.id)
      from public.matrix_scenario_strategies_v2 link
      where link.matrix_version_id=v_matrix.id
    ),'[]'::jsonb)
  );
end;
$$;

revoke all on function public.optimizer_configuration_v2(date)
  from public,anon,authenticated;
grant execute on function public.optimizer_configuration_v2(date)
  to authenticated;

create or replace function public.optimizer_request_v2(
  p_month date,
  p_scenario_id uuid,
  p_scope_type text,
  p_scope_role_id uuid,
  p_name text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_month date := date_trunc('month',p_month)::date;
  v_period_end date := (date_trunc('month',p_month)+interval '1 month - 1 day')::date;
  v_matrix_id uuid;
  v_scenario public.matrix_scenarios_v2%rowtype;
  v_scope_logical_id uuid;
  v_run_id uuid;
  v_existing public.optimization_runs_v2%rowtype;
  v_snapshot jsonb;
  v_hash text;
  v_message_id bigint;
  v_engine text;
  v_solver_version text;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  select flag.engine,nullif(trim(flag.config->>'solverVersion'),'')
  into v_engine,v_solver_version
  from public.solver_feature_flags flag
  where flag.flag_key='DEFAULT_ENGINE' and flag.enabled;
  if v_engine is null then raise exception 'SOLVER_ENGINE_CONFIGURATION_MISSING'; end if;
  if v_engine not in ('ALPHA15','SHADOW','ORTOOLS_V2') then
    raise exception 'SOLVER_ENGINE_CONFIGURATION_INVALID';
  end if;
  if v_engine not in ('SHADOW','ORTOOLS_V2') then
    raise exception 'ORTOOLS_REQUEST_DISABLED';
  end if;
  if length(coalesce(v_solver_version,'')) not between 1 and 200 then
    raise exception 'SOLVER_VERSION_CONFIGURATION_REQUIRED';
  end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  p_scope_type := upper(coalesce(p_scope_type,'COMPANY'));
  if p_scope_type not in ('COMPANY','ROLE') then raise exception 'INVALID_SCOPE'; end if;
  if (p_scope_type='ROLE')<>(p_scope_role_id is not null) then
    raise exception 'INVALID_SCOPE_ROLE';
  end if;
  if length(coalesce(p_idempotency_key,'')) not between 8 and 200 then
    raise exception 'INVALID_IDEMPOTENCY_KEY';
  end if;
  if length(trim(coalesce(p_name,''))) not between 1 and 200 then
    raise exception 'INVALID_PLAN_NAME';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_user::text||':'||p_idempotency_key,0));
  select * into v_existing from public.optimization_runs_v2 r
  where r.requested_by=v_user and r.idempotency_key=p_idempotency_key;
  if v_existing.id is not null then
    if v_existing.month<>v_month
      or v_existing.scenario_id<>p_scenario_id
      or v_existing.scope_type<>p_scope_type
      or v_existing.scope_role_id is distinct from p_scope_role_id
      or v_existing.request_engine<>v_engine
      or v_existing.solver_version<>v_solver_version
      or v_existing.name<>trim(p_name) then
      raise exception 'IDEMPOTENCY_KEY_REUSED';
    end if;
    return solver_private.run_status_payload_v2(v_existing.id)
      ||jsonb_build_object('reused',true);
  end if;

  -- Serialize the immutable snapshot boundary with every planning-data write.
  -- The lock is released automatically when this request transaction commits.
  perform solver_private.lock_planning_revision_v2();

  -- A monthly run always uses the Matrix that was effective at the first day
  -- of that month. This keeps historical reruns reproducible and prevents a
  -- mid-month publication from rewriting rules for days already elapsed.
  select mv.id into v_matrix_id
  from public.matrix_versions mv
  where mv.status in ('ACTIVE','ARCHIVED') and mv.schema_version>=2
    and mv.effective_from<=v_month
    and coalesce(mv.content_hash,'') ~ '^[0-9a-f]{64}$'
    and coalesce(mv.workforce_hash,'') ~ '^[0-9a-f]{64}$'
  order by mv.effective_from desc,mv.version desc limit 1;
  if v_matrix_id is null then raise exception 'MATRIX_V2_FOR_MONTH_NOT_FOUND'; end if;

  select * into v_scenario from public.matrix_scenarios_v2 s
  where s.id=p_scenario_id and s.matrix_version_id=v_matrix_id and s.active;
  if v_scenario.id is null then raise exception 'SCENARIO_NOT_FOUND'; end if;
  if v_scenario.valid_to is not null and v_scenario.valid_to<v_month then
    raise exception 'SCENARIO_OUTSIDE_PERIOD';
  end if;
  if v_scenario.valid_from is not null and v_scenario.valid_from>v_period_end then
    raise exception 'SCENARIO_OUTSIDE_PERIOD';
  end if;
  if p_scope_type='COMPANY' and not (
    public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  ) then raise exception 'COMPANY_SCOPE_FORBIDDEN'; end if;
  if p_scope_type='ROLE' then
    select r.logical_id into v_scope_logical_id
    from public.matrix_roles_v2 r
    where r.id=p_scope_role_id and r.matrix_version_id=v_matrix_id and r.active;
    if v_scope_logical_id is null then raise exception 'SCOPE_ROLE_NOT_FOUND'; end if;
    if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN'))
      and not exists(
        select 1 from public.matrix_scope_grants_v2 g
        where g.auth_user_id=v_user and g.active and g.app_role='ROLE_MANAGER'
          and (g.role_logical_id is null or g.role_logical_id=v_scope_logical_id)
      ) then raise exception 'ROLE_SCOPE_FORBIDDEN'; end if;
  end if;

  v_run_id := gen_random_uuid();
  v_snapshot := solver_private.build_snapshot_payload_v2(
    v_run_id,v_month,v_matrix_id,v_scenario.id,p_scope_type,p_scope_role_id
  );
  if jsonb_array_length(v_snapshot->'strategies')=0 then
    raise exception 'SNAPSHOT_HAS_NO_STRATEGIES';
  end if;
  v_hash := encode(extensions.digest(convert_to(
    solver_private.canonical_json_v2(v_snapshot),'UTF8'
  ),'sha256'),'hex');

  insert into public.optimization_runs_v2(
    id,idempotency_key,month,matrix_version_id,scenario_id,scope_type,
    scope_role_id,name,requested_by,snapshot_hash,request_engine,solver_version
  ) values(
    v_run_id,p_idempotency_key,v_month,v_matrix_id,v_scenario.id,p_scope_type,
    p_scope_role_id,trim(p_name),v_user,v_hash,v_engine,v_solver_version
  );

  insert into public.optimization_run_strategies_v2(
    run_id,strategy_id,ordinal,status,phase,progress
  )
  select v_run_id,(strategy.value->>'id')::uuid,strategy.ordinality::integer,
    'QUEUED','QUEUED',0
  from jsonb_array_elements(v_snapshot->'strategies')
    with ordinality strategy(value,ordinality)
  order by strategy.ordinality;

  insert into solver_private.optimization_snapshots_v2(
    run_id,schema_version,snapshot_hash,snapshot
  ) values(v_run_id,2,v_hash,v_snapshot);

  select pgmq.send('schedule_optimizer_v2',jsonb_build_object(
    'schemaVersion',2,'runId',v_run_id,'snapshotHash',v_hash
  )) into v_message_id;
  update public.optimization_runs_v2 set queue_message_id=v_message_id where id=v_run_id;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_user,'optimization_run_v2',v_run_id::text,'REQUEST',jsonb_build_object(
    'month',v_month,'matrixVersionId',v_matrix_id,'scenarioId',v_scenario.id,
    'scopeType',p_scope_type,'scopeRoleId',p_scope_role_id,'snapshotHash',v_hash,
    'requestEngine',v_engine,'solverVersion',v_solver_version
  ));

  return jsonb_build_object(
    'run',jsonb_build_object(
      'id',v_run_id,'status','QUEUED','phase','QUEUED','progress',0,
      'month',v_month,'scopeType',p_scope_type,'scopeRoleId',p_scope_role_id,
      'requestEngine',v_engine,'solverVersion',v_solver_version,
      'scenario',jsonb_build_object('id',v_scenario.id,'name',v_scenario.name),
      'createdAt',now()
    ),'reused',false
  );
end;
$$;

revoke all on function public.optimizer_request_v2(
  date,uuid,text,uuid,text,text
) from public,anon,authenticated;
grant execute on function public.optimizer_request_v2(
  date,uuid,text,uuid,text,text
) to authenticated;
