-- Synchronize the complete Matrix publication validator used by the current
-- contract tests and immutable solver snapshot. The development branch ran an
-- earlier body, while the source migration already contains this final body.

create or replace function solver_private.jsonb_deep_merge_v2(
  p_base jsonb,p_override jsonb
)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_result jsonb:=case when jsonb_typeof(p_base)='object'
    then p_base else '{}'::jsonb end;
  v_key text;
  v_value jsonb;
begin
  if p_override is null then return v_result; end if;
  if jsonb_typeof(p_override)<>'object' then return p_override; end if;
  for v_key,v_value in select entry.key,entry.value
    from jsonb_each(p_override) entry
  loop
    if jsonb_typeof(v_result->v_key)='object'
      and jsonb_typeof(v_value)='object' then
      v_result:=jsonb_set(
        v_result,array[v_key],
        solver_private.jsonb_deep_merge_v2(v_result->v_key,v_value),true
      );
    else
      v_result:=jsonb_set(v_result,array[v_key],v_value,true);
    end if;
  end loop;
  return v_result;
end;
$$;

create or replace function solver_private.jsonb_deep_merge_array_v2(
  p_values jsonb[]
)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_result jsonb:='{}'::jsonb;
  v_value jsonb;
begin
  if p_values is null then return v_result; end if;
  foreach v_value in array p_values loop
    v_result:=solver_private.jsonb_deep_merge_v2(v_result,v_value);
  end loop;
  return v_result;
end;
$$;

revoke all on function solver_private.jsonb_deep_merge_v2(jsonb,jsonb),
  solver_private.jsonb_deep_merge_array_v2(jsonb[])
  from public,anon,authenticated;
grant execute on function solver_private.jsonb_deep_merge_v2(jsonb,jsonb),
  solver_private.jsonb_deep_merge_array_v2(jsonb[])
  to service_role;

create or replace function public.matrix_v2_is_supported_objective_config(
  p_direction text,p_parameters jsonb
) returns boolean
language sql
immutable
strict
set search_path = ''
as $$
  select jsonb_typeof(p_parameters)='object'
    and p_parameters-array['target','targetValue']='{}'::jsonb
    and not (p_parameters ? 'target' and p_parameters ? 'targetValue')
    and (
      not (p_parameters ? 'target' or p_parameters ? 'targetValue')
      or (
        case upper(p_direction)
          when 'MIN' then 'MINIMIZE'
          when 'MAX' then 'MAXIMIZE'
          else upper(p_direction)
        end='MINIMIZE'
        and coalesce(p_parameters->>case
          when p_parameters ? 'targetValue' then 'targetValue'
          else 'target' end,'') ~ '^[0-9]+$'
      )
    );
$$;

revoke all on function public.matrix_v2_is_supported_objective_config(text,jsonb)
  from public,anon,authenticated;
grant execute on function public.matrix_v2_is_supported_objective_config(text,jsonb)
  to service_role;

create or replace function public.matrix_v2_publish_draft(
  p_effective_from date default current_date
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_draft public.matrix_versions%rowtype;
  v_active public.matrix_versions%rowtype;
  v_default_count integer;
  v_cycle boolean;
  v_document jsonb;
  v_hash text;
  v_scenario record;
  v_active_strategy_count integer;
begin
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if p_effective_from is null then raise exception 'EFFECTIVE_FROM_REQUIRED'; end if;
  if p_effective_from>current_date then
    raise exception 'FUTURE_MATRIX_ACTIVATION_REQUIRES_SCHEDULER';
  end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));

  select * into v_draft from public.matrix_versions mv
  where mv.status='DRAFT' and mv.schema_version>=2
  order by mv.version desc limit 1 for update;
  if v_draft.id is null then raise exception 'NO_MATRIX_V2_DRAFT'; end if;
  select * into v_active from public.matrix_versions mv
  where mv.status='ACTIVE' order by mv.version desc limit 1 for update;
  if exists(select 1 from public.matrix_versions mv
      where mv.status='ACTIVE' and p_effective_from<mv.effective_from) then
    raise exception 'EFFECTIVE_FROM_PRECEDES_ACTIVE_MATRIX';
  end if;

  select count(*) into v_default_count from public.matrix_scenarios_v2 s
  where s.matrix_version_id=v_draft.id and s.active and s.is_default;
  if v_default_count<>1 then raise exception 'EXACTLY_ONE_ACTIVE_DEFAULT_SCENARIO_REQUIRED'; end if;
  if exists(select 1 from public.matrix_scenarios_v2 s
    where s.matrix_version_id=v_draft.id and s.active and s.is_default
      and s.parent_scenario_id is not null) then
    raise exception 'DEFAULT_SCENARIO_CANNOT_INHERIT';
  end if;

  if not exists(select 1 from public.matrix_roles_v2 x
      where x.matrix_version_id=v_draft.id and x.active)
    or not exists(select 1 from public.matrix_locations_v2 x
      where x.matrix_version_id=v_draft.id and x.active)
    or not exists(select 1 from public.matrix_shift_templates_v2 x
      where x.matrix_version_id=v_draft.id and x.active)
    or not exists(select 1 from public.matrix_strategies_v2 x
      where x.matrix_version_id=v_draft.id and x.active) then
    raise exception 'ACTIVE_ROLE_LOCATION_SHIFT_AND_STRATEGY_REQUIRED';
  end if;

  if exists(select 1 from public.matrix_locations_v2 l
    where l.matrix_version_id=v_draft.id
      and not exists(select 1 from pg_catalog.pg_timezone_names tz
        where tz.name=l.timezone)) then
    raise exception 'INVALID_LOCATION_TIMEZONE';
  end if;
  if exists(
    select 1 from public.matrix_shift_templates_v2 shift_row
    where shift_row.matrix_version_id=v_draft.id and shift_row.active
      and shift_row.ends_next_day is distinct from
        (shift_row.ends_at<=shift_row.starts_at)
  ) then raise exception 'SHIFT_OVERNIGHT_FLAG_INCONSISTENT'; end if;
  if not public.matrix_v2_is_iso_4217_currency(
    upper(coalesce(v_draft.settings->>'currency',''))
  ) then
    raise exception 'INVALID_MATRIX_CURRENCY';
  end if;
  if nullif(v_draft.settings->>'timezone','') is null or not exists(
    select 1 from pg_catalog.pg_timezone_names tz
    where tz.name=v_draft.settings->>'timezone'
  ) then raise exception 'INVALID_MATRIX_TIMEZONE'; end if;
  if coalesce(v_draft.settings->>'minimumRestMinutes','') !~ '^[0-9]+$'
    or (v_draft.settings->>'minimumRestMinutes')::integer<0
    or coalesce(v_draft.settings->>'maximumShiftsPerDay','') !~ '^[0-9]+$'
    or (v_draft.settings->>'maximumShiftsPerDay')::integer not between 1 and 24
    or jsonb_typeof(v_draft.settings->'missingAvailabilityMeansAvailable')<>'boolean'
    or jsonb_typeof(v_draft.settings->'requireOptimal')<>'boolean'
  then raise exception 'INVALID_MATRIX_SETTINGS'; end if;
  if exists(
    select 1 from public.matrix_scenarios_v2 s
    where s.matrix_version_id=v_draft.id and s.active and (
      jsonb_typeof(s.settings_overrides)<>'object'
      or s.settings_overrides-array[
        'timezone','minimumRestMinutes','maximumShiftsPerDay',
        'missingAvailabilityMeansAvailable','requireOptimal',
        'onlyMorningBeforeMinute','onlyEveningAfterMinute','randomSeed'
      ]<>'{}'::jsonb
      or (s.settings_overrides ? 'timezone' and (
        nullif(s.settings_overrides->>'timezone','') is null
        or not exists(select 1 from pg_catalog.pg_timezone_names tz
          where tz.name=s.settings_overrides->>'timezone')
      ))
      or (s.settings_overrides ? 'minimumRestMinutes' and (
        coalesce(s.settings_overrides->>'minimumRestMinutes','') !~ '^[0-9]+$'
        or (s.settings_overrides->>'minimumRestMinutes')::integer<0
      ))
      or (s.settings_overrides ? 'maximumShiftsPerDay' and (
        coalesce(s.settings_overrides->>'maximumShiftsPerDay','') !~ '^[0-9]+$'
        or (s.settings_overrides->>'maximumShiftsPerDay')::integer not between 1 and 24
      ))
      or (s.settings_overrides ? 'missingAvailabilityMeansAvailable'
        and jsonb_typeof(s.settings_overrides->'missingAvailabilityMeansAvailable')<>'boolean')
      or (s.settings_overrides ? 'requireOptimal'
        and jsonb_typeof(s.settings_overrides->'requireOptimal')<>'boolean')
      or (s.settings_overrides ? 'onlyMorningBeforeMinute' and (
        coalesce(s.settings_overrides->>'onlyMorningBeforeMinute','') !~ '^[0-9]+$'
        or (s.settings_overrides->>'onlyMorningBeforeMinute')::integer>2880
      ))
      or (s.settings_overrides ? 'onlyEveningAfterMinute' and (
        coalesce(s.settings_overrides->>'onlyEveningAfterMinute','') !~ '^[0-9]+$'
        or (s.settings_overrides->>'onlyEveningAfterMinute')::integer>2880
      ))
      or (s.settings_overrides ? 'randomSeed' and
        coalesce(s.settings_overrides->>'randomSeed','') !~ '^[0-9]+$')
    )
  ) then raise exception 'INVALID_SCENARIO_SETTINGS_OVERRIDE'; end if;
  if exists(
    select 1 from public.matrix_pay_rules_v2 p
    where p.matrix_version_id=v_draft.id and p.active
      and p.currency<>upper(v_draft.settings->>'currency')
  ) or exists(
    select 1 from public.matrix_scenario_budgets_v2 b
    where b.matrix_version_id=v_draft.id
      and b.currency<>upper(v_draft.settings->>'currency')
  ) or exists(
    select 1 from public.employee_pay_rates_v2 r
    join public.matrix_employee_profiles_v2 profile
      on profile.matrix_version_id=v_draft.id
      and profile.employee_id=r.employee_id and profile.active
    where r.active and r.valid_from<=p_effective_from
      and (r.valid_to is null or r.valid_to>=p_effective_from)
      and r.currency<>upper(v_draft.settings->>'currency')
  ) then raise exception 'MIXED_CURRENCIES_UNSUPPORTED'; end if;
  if exists(
    select 1 from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=v_draft.id and profile.active
      and not exists(
        select 1 from public.employee_pay_rates_v2 rate
        where rate.employee_id=profile.employee_id and rate.active
          and rate.valid_from<=p_effective_from
          and (rate.valid_to is null or rate.valid_to>=p_effective_from)
      )
  ) then raise exception 'ACTIVE_EMPLOYEE_REQUIRES_PAY_RATE'; end if;
  if exists(
    select 1 from public.matrix_pay_rules_v2 p
    where p.matrix_version_id=v_draft.id and p.active and (
      jsonb_typeof(p.condition_expression)<>'object'
      or p.condition_expression-array['conditions']<>'{}'::jsonb
      or (p.condition_expression ? 'conditions'
        and jsonb_typeof(p.condition_expression->'conditions')<>'array')
      or p.formula_expression<>'{}'::jsonb
      or (p.local_start is null)<>(p.local_end is null)
      or (
        case when p.local_start is null then 0 else 1 end
        +(select count(*) from jsonb_array_elements(
          coalesce(p.condition_expression->'conditions','[]'::jsonb)
        ) condition where lower(coalesce(condition.value->>'field',''))='local_time'
          and upper(coalesce(condition.value->>'operator',''))='OVERLAPS_TIME')
      )>1
      or (
        p.calculation_method in (
          'SHIFT_DURATION_THRESHOLD_PER_HOUR','MONTHLY_THRESHOLD_PER_HOUR'
        ) and (
          p.local_start is not null or exists(
            select 1 from jsonb_array_elements(
              coalesce(p.condition_expression->'conditions','[]'::jsonb)
            ) condition where lower(coalesce(condition.value->>'field',''))='local_time'
              and upper(coalesce(condition.value->>'operator',''))='OVERLAPS_TIME'
          )
        )
      )
      or (p.calculation_method='MULTIPLIER'
        and p.multiplier_basis_points<10000)
      or (p.calculation_method='FIXED_PER_SHIFT' and (
        p.rate_minor_per_hour is not null or p.percent_basis_points is not null
        or p.multiplier_basis_points is not null or p.threshold_minutes is not null
      ))
      or (p.calculation_method='PER_HOUR' and (
        p.amount_minor is not null or p.percent_basis_points is not null
        or p.multiplier_basis_points is not null or p.threshold_minutes is not null
      ))
      or (p.calculation_method='PERCENT_BASE' and (
        p.amount_minor is not null or p.rate_minor_per_hour is not null
        or p.multiplier_basis_points is not null or p.threshold_minutes is not null
      ))
      or (p.calculation_method='MULTIPLIER' and (
        p.amount_minor is not null or p.rate_minor_per_hour is not null
        or p.percent_basis_points is not null or p.threshold_minutes is not null
      ))
      or (p.calculation_method in (
        'SHIFT_DURATION_THRESHOLD_PER_HOUR','MONTHLY_THRESHOLD_PER_HOUR'
      ) and (
        p.amount_minor is not null or p.percent_basis_points is not null
        or p.multiplier_basis_points is not null
      ))
    )
  ) then raise exception 'INVALID_PAY_RULE_CONFIGURATION'; end if;
  if exists(
    select 1
    from public.matrix_pay_rules_v2 p
    cross join lateral jsonb_array_elements(
      coalesce(p.condition_expression->'conditions','[]'::jsonb)
    ) condition
    where p.matrix_version_id=v_draft.id and p.active
      and not public.matrix_v2_is_supported_pay_condition(condition.value)
  ) then raise exception 'UNSUPPORTED_PAY_RULE_CONDITION'; end if;
  if exists(
    select 1 from public.matrix_pay_rules_v2 left_rule
    join public.matrix_pay_rules_v2 right_rule
      on right_rule.matrix_version_id=left_rule.matrix_version_id
      and right_rule.id>left_rule.id and right_rule.active
      and coalesce(right_rule.stacking_group,right_rule.id::text)
        =coalesce(left_rule.stacking_group,left_rule.id::text)
      and right_rule.stacking_mode<>left_rule.stacking_mode
    where left_rule.matrix_version_id=v_draft.id and left_rule.active
  ) then raise exception 'INCONSISTENT_PAY_STACKING_GROUP'; end if;
  if exists(
    select 1 from public.matrix_scenario_pay_rule_overrides_v2 override
    join public.matrix_scenarios_v2 scenario
      on scenario.id=override.scenario_id and scenario.active
    join public.matrix_pay_rules_v2 rule
      on rule.id=override.pay_rule_id and rule.active
    where override.matrix_version_id=v_draft.id and (
      coalesce(override.formula_expression,'{}'::jsonb)<>'{}'::jsonb
      or (rule.calculation_method='FIXED_PER_SHIFT' and (
        override.rate_minor_per_hour is not null
        or override.percent_basis_points is not null
        or override.multiplier_basis_points is not null
      ))
      or (rule.calculation_method in (
        'PER_HOUR','SHIFT_DURATION_THRESHOLD_PER_HOUR',
        'MONTHLY_THRESHOLD_PER_HOUR'
      ) and (
        override.amount_minor is not null
        or override.percent_basis_points is not null
        or override.multiplier_basis_points is not null
      ))
      or (rule.calculation_method='PERCENT_BASE' and (
        override.amount_minor is not null or override.rate_minor_per_hour is not null
        or override.multiplier_basis_points is not null
      ))
      or (rule.calculation_method='MULTIPLIER' and (
        override.amount_minor is not null or override.rate_minor_per_hour is not null
        or override.percent_basis_points is not null
        or (override.multiplier_basis_points is not null
          and override.multiplier_basis_points<10000)
      ))
    )
  ) then raise exception 'INVALID_SCENARIO_PAY_RULE_OVERRIDE'; end if;
  if exists(select 1 from public.matrix_shift_templates_v2 s
    where s.matrix_version_id=v_draft.id
      and cardinality(s.day_mask)<>(select count(distinct d) from unnest(s.day_mask) d)) then
    raise exception 'SHIFT_DAY_MASK_CONTAINS_DUPLICATES';
  end if;

  with recursive walk(id,parent_scenario_id,path,cycle) as (
    select s.id,s.parent_scenario_id,array[s.id],false
    from public.matrix_scenarios_v2 s where s.matrix_version_id=v_draft.id
    union all
    select p.id,p.parent_scenario_id,w.path||p.id,p.id=any(w.path)
    from walk w join public.matrix_scenarios_v2 p on p.id=w.parent_scenario_id
    where not w.cycle
  ) select coalesce(bool_or(w.cycle),false) into v_cycle from walk w;
  if v_cycle then raise exception 'SCENARIO_INHERITANCE_CYCLE'; end if;
  if exists(
    with recursive chain as (
      select s.id,s.parent_scenario_id,0 depth
      from public.matrix_scenarios_v2 s
      where s.matrix_version_id=v_draft.id
      union all
      select parent.id,parent.parent_scenario_id,chain.depth+1
      from chain
      join public.matrix_scenarios_v2 parent
        on parent.id=chain.parent_scenario_id
        and parent.matrix_version_id=v_draft.id
      where chain.depth<32
    )
    select 1 from chain
    where chain.depth=32 and chain.parent_scenario_id is not null
  ) then raise exception 'SCENARIO_INHERITANCE_TOO_DEEP'; end if;
  if exists(select 1 from public.matrix_scenarios_v2 s
    join public.matrix_scenarios_v2 p on p.id=s.parent_scenario_id
    where s.matrix_version_id=v_draft.id and s.active and not p.active) then
    raise exception 'ACTIVE_SCENARIO_HAS_INACTIVE_PARENT';
  end if;

  if exists(
    select 1 from public.matrix_strategies_v2 s
    where s.matrix_version_id=v_draft.id and s.active and (
      upper(s.solver_code)<>'CP_SAT'
      or jsonb_typeof(s.solver_options)<>'object'
    )
  ) then raise exception 'UNSUPPORTED_STRATEGY_SOLVER_CONFIGURATION'; end if;
  if exists(
    select 1 from public.matrix_strategies_v2 s
    where s.matrix_version_id=v_draft.id and s.active and (
      s.solver_options-array['maxTimeSeconds','randomSeed']<>'{}'::jsonb
      or (s.solver_options ? 'maxTimeSeconds' and (
        coalesce(s.solver_options->>'maxTimeSeconds','') !~ '^[0-9]+$'
        or (s.solver_options->>'maxTimeSeconds')::integer not between 1 and 86400
      ))
      or (s.solver_options ? 'randomSeed' and (
        coalesce(s.solver_options->>'randomSeed','') !~ '^[0-9]+$'
        or (s.solver_options->>'randomSeed')::numeric>2147483647
      ))
    )
  ) then raise exception 'INVALID_STRATEGY_SOLVER_OPTIONS'; end if;

  if exists(
    select 1 from public.matrix_strategy_objectives_v2 o
    join public.matrix_strategies_v2 s on s.id=o.strategy_id and s.active
    where o.matrix_version_id=v_draft.id and o.active and (
      upper(o.metric_code) not in (
        'UNFILLED','TOTAL_COST','PREFERENCE_VIOLATIONS',
        'HOME_LOCATION_VIOLATIONS','NOMINAL_DEVIATION_MINUTES',
        'OVERTIME_MINUTES','LOAD_SPREAD_MINUTES','WEEKEND_SPREAD',
        'BASELINE_CHANGES','COST','TOTAL_COST_UNITS','PREFERENCES',
        'HOME_LOCATION','NOMINAL_DEVIATION','OVERTIME','LOAD_SPREAD',
        'BASELINE_CHANGES_COUNT','UNFILLED_SEATS','TOTAL_COST_MINOR',
        'WORKLOAD_VARIANCE','WEEKEND_VARIANCE','NON_HOME_LOCATION_COUNT'
      )
      or jsonb_typeof(o.parameters)<>'object'
    )
  ) then raise exception 'UNSUPPORTED_STRATEGY_OBJECTIVE'; end if;
  if exists(
    select 1 from public.matrix_strategy_objectives_v2 o
    join public.matrix_strategies_v2 s on s.id=o.strategy_id and s.active
    where o.matrix_version_id=v_draft.id and o.active and (
      o.parameters-array['target','targetValue']<>'{}'::jsonb
      or (o.parameters ? 'target' and o.parameters ? 'targetValue')
      or ((o.parameters ? 'target' or o.parameters ? 'targetValue') and (
        upper(o.direction)<>'MINIMIZE'
        or coalesce(o.parameters->>case when o.parameters ? 'targetValue'
          then 'targetValue' else 'target' end,'') !~ '^[0-9]+$'
      ))
    )
  ) then raise exception 'INVALID_STRATEGY_OBJECTIVE_PARAMETERS'; end if;

  if exists(
    select 1 from public.matrix_scenario_strategies_v2 ss
    join public.matrix_scenarios_v2 sc on sc.id=ss.scenario_id and sc.active
    join public.matrix_strategies_v2 st on st.id=ss.strategy_id and st.active
    where ss.matrix_version_id=v_draft.id and ss.active and (
      jsonb_typeof(ss.objective_overrides)<>'object'
      or jsonb_typeof(ss.solver_overrides)<>'object'
    )
  ) then raise exception 'INVALID_SCENARIO_STRATEGY_OVERRIDE'; end if;
  if exists(
    select 1
    from public.matrix_scenario_strategies_v2 ss
    join public.matrix_scenarios_v2 sc on sc.id=ss.scenario_id and sc.active
    join public.matrix_strategies_v2 st on st.id=ss.strategy_id and st.active
    cross join lateral jsonb_each(ss.objective_overrides) ov
    left join public.matrix_strategy_objectives_v2 objective
      on objective.strategy_id=ss.strategy_id
      and objective.metric_code=upper(ov.key) and objective.active
    where ss.matrix_version_id=v_draft.id and ss.active and (
      ov.key<>upper(ov.key)
      or objective.id is null
      or jsonb_typeof(ov.value)<>'object'
      or (ov.value ? 'parameters'
        and jsonb_typeof(ov.value->'parameters')<>'object')
    )
  ) then raise exception 'INVALID_SCENARIO_OBJECTIVE_OVERRIDE'; end if;
  if exists(
    select 1
    from public.matrix_scenario_strategies_v2 ss
    join public.matrix_scenarios_v2 sc on sc.id=ss.scenario_id and sc.active
    join public.matrix_strategies_v2 st on st.id=ss.strategy_id and st.active
    cross join lateral jsonb_each(ss.objective_overrides) ov
    join public.matrix_strategy_objectives_v2 objective
      on objective.strategy_id=ss.strategy_id
      and objective.metric_code=upper(ov.key) and objective.active
    where ss.matrix_version_id=v_draft.id and ss.active and (
      ov.value-array['active','tier','weight','direction','tolerance','parameters']
        <>'{}'::jsonb
      or (ov.value ? 'active' and jsonb_typeof(ov.value->'active')<>'boolean')
      or (ov.value ? 'tier' and (
        coalesce(ov.value->>'tier','') !~ '^[0-9]+$'
        or (ov.value->>'tier')::integer not between 1 and 100
      ))
      or (ov.value ? 'weight' and coalesce(ov.value->>'weight','') !~ '^[0-9]+$')
      or (ov.value ? 'tolerance'
        and coalesce(ov.value->>'tolerance','') !~ '^[0-9]+$')
      or (ov.value ? 'direction' and upper(ov.value->>'direction')
        not in ('MIN','MINIMIZE','MAX','MAXIMIZE'))
      or (
        (objective.parameters||coalesce(
          ov.value->'parameters','{}'::jsonb
        ))-array['target','targetValue']<>'{}'::jsonb
        or (
          (objective.parameters||coalesce(
            ov.value->'parameters','{}'::jsonb
          )) ? 'target'
          and (objective.parameters||coalesce(
            ov.value->'parameters','{}'::jsonb
          )) ? 'targetValue'
        )
        or (
          (
            (objective.parameters||coalesce(
              ov.value->'parameters','{}'::jsonb
            )) ? 'target'
            or (objective.parameters||coalesce(
              ov.value->'parameters','{}'::jsonb
            )) ? 'targetValue'
          ) and (
            case upper(coalesce(ov.value->>'direction',objective.direction))
              when 'MIN' then 'MINIMIZE'
              when 'MAX' then 'MAXIMIZE'
              else upper(coalesce(ov.value->>'direction',objective.direction))
            end <> 'MINIMIZE'
            or coalesce(
              (objective.parameters||coalesce(
                ov.value->'parameters','{}'::jsonb
              ))->>case when (objective.parameters||coalesce(
                ov.value->'parameters','{}'::jsonb
              )) ? 'targetValue' then 'targetValue' else 'target' end,
              ''
            ) !~ '^[0-9]+$'
          )
        )
      )
    )
  ) then raise exception 'INVALID_SCENARIO_OBJECTIVE_OVERRIDE'; end if;
  if exists(
    select 1 from public.matrix_scenario_strategies_v2 ss
    join public.matrix_scenarios_v2 sc on sc.id=ss.scenario_id and sc.active
    join public.matrix_strategies_v2 st on st.id=ss.strategy_id and st.active
    where ss.matrix_version_id=v_draft.id and ss.active and (
      ss.solver_overrides-array['maxTimeSeconds','randomSeed']<>'{}'::jsonb
      or (ss.solver_overrides ? 'maxTimeSeconds' and (
        coalesce(ss.solver_overrides->>'maxTimeSeconds','') !~ '^[0-9]+$'
        or (ss.solver_overrides->>'maxTimeSeconds')::integer not between 1 and 86400
      ))
      or (ss.solver_overrides ? 'randomSeed' and (
        coalesce(ss.solver_overrides->>'randomSeed','') !~ '^[0-9]+$'
        or (ss.solver_overrides->>'randomSeed')::numeric>2147483647
      ))
    )
  ) then raise exception 'INVALID_SCENARIO_SOLVER_OVERRIDE'; end if;

  -- Validate the exact inherited configuration emitted by the snapshot, not
  -- just each override row in isolation. A child may override direction while
  -- inheriting a target, or introduce the second target alias; both must fail
  -- at publication rather than in the worker.
  if exists(
    with recursive scenario_chain as (
      select scenario.id root_id,scenario.id,scenario.parent_scenario_id,0 depth
      from public.matrix_scenarios_v2 scenario
      where scenario.matrix_version_id=v_draft.id and scenario.active
      union all
      select chain.root_id,parent.id,parent.parent_scenario_id,chain.depth+1
      from scenario_chain chain
      join public.matrix_scenarios_v2 parent
        on parent.id=chain.parent_scenario_id
        and parent.matrix_version_id=v_draft.id
      where chain.depth<32
    ), raw_links as (
      select chain.root_id,chain.depth,link.id,link.strategy_id,
        link.active,link.objective_overrides
      from scenario_chain chain
      join public.matrix_scenario_strategies_v2 link
        on link.scenario_id=chain.id
        and link.matrix_version_id=v_draft.id
    ), resolved_links as (
      select link.root_id,link.strategy_id,
        (array_agg(link.active order by link.depth,link.id))[1] active,
        solver_private.jsonb_deep_merge_array_v2(array_agg(
          link.objective_overrides order by link.depth desc,link.id
        )) objective_overrides
      from raw_links link
      group by link.root_id,link.strategy_id
    )
    select 1
    from resolved_links resolved
    join public.matrix_strategies_v2 strategy
      on strategy.id=resolved.strategy_id and strategy.active
    join public.matrix_strategy_objectives_v2 objective
      on objective.strategy_id=resolved.strategy_id and objective.active
    cross join lateral (select coalesce(
      resolved.objective_overrides->upper(objective.metric_code),'{}'::jsonb
    ) value) override_config
    where resolved.active
      and coalesce((override_config.value->>'active')::boolean,true)
      and not public.matrix_v2_is_supported_objective_config(
        coalesce(override_config.value->>'direction',objective.direction),
        objective.parameters||coalesce(
          override_config.value->'parameters','{}'::jsonb
        )
      )
  ) then raise exception 'INVALID_RESOLVED_SCENARIO_OBJECTIVE'; end if;

  for v_scenario in
    select s.id from public.matrix_scenarios_v2 s
    where s.matrix_version_id=v_draft.id and s.active
  loop
    with recursive chain as (
      select s.id,s.parent_scenario_id,0 depth
      from public.matrix_scenarios_v2 s where s.id=v_scenario.id
      union all
      select parent.id,parent.parent_scenario_id,chain.depth+1
      from public.matrix_scenarios_v2 parent
      join chain on chain.parent_scenario_id=parent.id
      where parent.matrix_version_id=v_draft.id and chain.depth<32
    ), resolved as (
      select distinct on (ss.strategy_id) ss.strategy_id,ss.active,chain.depth
      from chain join public.matrix_scenario_strategies_v2 ss
        on ss.scenario_id=chain.id and ss.matrix_version_id=v_draft.id
      order by ss.strategy_id,chain.depth,ss.id
    )
    select count(*) into v_active_strategy_count
    from resolved r join public.matrix_strategies_v2 st
      on st.id=r.strategy_id and st.active
    where r.active;
    if v_active_strategy_count=0 then
      raise exception 'ACTIVE_SCENARIO_WITHOUT_ACTIVE_STRATEGY:%',v_scenario.id;
    end if;
  end loop;
  if exists(select 1 from public.matrix_strategies_v2 s
    where s.matrix_version_id=v_draft.id and s.active
      and not exists(select 1 from public.matrix_strategy_objectives_v2 o
        where o.strategy_id=s.id and o.active and o.tier=1 and o.metric_code='UNFILLED')) then
    raise exception 'ACTIVE_STRATEGY_REQUIRES_TIER1_UNFILLED_OBJECTIVE';
  end if;

  if exists(select 1 from public.matrix_staffing_rules_v2 x
    join public.matrix_scenarios_v2 sc on sc.id=x.scenario_id
    join public.matrix_shift_templates_v2 sh on sh.id=x.shift_template_id
    join public.matrix_roles_v2 r on r.id=x.role_id
    left join public.matrix_duties_v2 d on d.id=x.duty_id
    where x.matrix_version_id=v_draft.id and x.active
      and (not sc.active or not sh.active or not r.active
        or (x.duty_id is not null and not d.active))) then
    raise exception 'ACTIVE_STAFFING_RULE_REFERENCES_INACTIVE_SCOPE';
  end if;

  -- Publishing is the fail-closed boundary. Dormant rows may remain in a
  -- draft for editing history, but no active configuration may point at a
  -- role, duty, location or shift that the snapshot itself will omit.
  if exists(
    select 1 from public.matrix_shift_templates_v2 shift_row
    join public.matrix_locations_v2 location on location.id=shift_row.location_id
    where shift_row.matrix_version_id=v_draft.id and shift_row.active
      and not location.active
  ) then raise exception 'ACTIVE_SHIFT_REFERENCES_INACTIVE_LOCATION'; end if;
  if exists(
    select 1 from public.matrix_role_duties_v2 link
    join public.matrix_roles_v2 role on role.id=link.role_id
    join public.matrix_duties_v2 duty on duty.id=link.duty_id
    where link.matrix_version_id=v_draft.id and link.active
      and (not role.active or not duty.active)
  ) then raise exception 'ROLE_DUTY_REFERENCES_INACTIVE_SCOPE'; end if;
  if exists(
    select 1 from public.matrix_employee_roles_v2 grant_row
    join public.matrix_employee_profiles_v2 profile
      on profile.matrix_version_id=grant_row.matrix_version_id
      and profile.employee_id=grant_row.employee_id
    join public.matrix_roles_v2 role on role.id=grant_row.role_id
    where grant_row.matrix_version_id=v_draft.id and profile.active
      and grant_row.active and not role.active
  ) then raise exception 'EMPLOYEE_ROLE_REFERENCES_INACTIVE_ROLE'; end if;
  if exists(
    select 1 from public.matrix_employee_locations_v2 grant_row
    join public.matrix_employee_profiles_v2 profile
      on profile.matrix_version_id=grant_row.matrix_version_id
      and profile.employee_id=grant_row.employee_id
    join public.matrix_locations_v2 location on location.id=grant_row.location_id
    where grant_row.matrix_version_id=v_draft.id and profile.active
      and grant_row.active and not location.active
  ) then raise exception 'EMPLOYEE_LOCATION_REFERENCES_INACTIVE_LOCATION'; end if;
  if exists(
    select 1 from public.matrix_employee_duties_v2 grant_row
    join public.matrix_employee_profiles_v2 profile
      on profile.matrix_version_id=grant_row.matrix_version_id
      and profile.employee_id=grant_row.employee_id
    join public.matrix_duties_v2 duty on duty.id=grant_row.duty_id
    left join public.matrix_roles_v2 role on role.id=grant_row.role_id
    left join public.matrix_locations_v2 location on location.id=grant_row.location_id
    where grant_row.matrix_version_id=v_draft.id and profile.active
      and grant_row.active and (
        not duty.active
        or (grant_row.role_id is not null and not role.active)
        or (grant_row.location_id is not null and not location.active)
      )
  ) then raise exception 'EMPLOYEE_DUTY_REFERENCES_INACTIVE_SCOPE'; end if;
  if exists(
    select 1 from public.matrix_scenario_strategies_v2 link
    join public.matrix_scenarios_v2 scenario on scenario.id=link.scenario_id
    join public.matrix_strategies_v2 strategy on strategy.id=link.strategy_id
    where link.matrix_version_id=v_draft.id and scenario.active
      and link.active and not strategy.active
  ) then raise exception 'SCENARIO_REFERENCES_INACTIVE_STRATEGY'; end if;
  if exists(
    select 1 from public.matrix_pay_rules_v2 rule
    left join public.matrix_pay_rule_roles_v2 role_link on role_link.pay_rule_id=rule.id
    left join public.matrix_roles_v2 role on role.id=role_link.role_id
    left join public.matrix_pay_rule_duties_v2 duty_link on duty_link.pay_rule_id=rule.id
    left join public.matrix_duties_v2 duty on duty.id=duty_link.duty_id
    left join public.matrix_pay_rule_locations_v2 location_link
      on location_link.pay_rule_id=rule.id
    left join public.matrix_locations_v2 location on location.id=location_link.location_id
    left join public.matrix_pay_rule_shifts_v2 shift_link on shift_link.pay_rule_id=rule.id
    left join public.matrix_shift_templates_v2 shift_row
      on shift_row.id=shift_link.shift_template_id
    where rule.matrix_version_id=v_draft.id and rule.active and (
      (role_link.pay_rule_id is not null and not role.active)
      or (duty_link.pay_rule_id is not null and not duty.active)
      or (location_link.pay_rule_id is not null and not location.active)
      or (shift_link.pay_rule_id is not null and not shift_row.active)
    )
  ) then raise exception 'PAY_RULE_REFERENCES_INACTIVE_SCOPE'; end if;
  if exists(
    select 1 from public.matrix_scenario_budgets_v2 budget
    join public.matrix_scenarios_v2 scenario on scenario.id=budget.scenario_id
    left join public.matrix_locations_v2 location on location.id=budget.location_id
    left join public.matrix_roles_v2 role on role.id=budget.role_id
    left join public.matrix_duties_v2 duty on duty.id=budget.duty_id
    where budget.matrix_version_id=v_draft.id and scenario.active and (
      (budget.location_id is not null and not location.active)
      or (budget.role_id is not null and not role.active)
      or (budget.duty_id is not null and not duty.active)
    )
  ) then raise exception 'SCENARIO_BUDGET_REFERENCES_INACTIVE_SCOPE'; end if;

  v_document:=public.matrix_v2_content_document(v_draft.id);
  if v_document is null then raise exception 'MATRIX_V2_CONTENT_NOT_FOUND'; end if;
  v_hash:=encode(extensions.digest(v_document::text,'sha256'),'hex');

  update public.matrix_versions set status='ARCHIVED',
    effective_to=greatest(effective_from,p_effective_from)
  where status='DRAFT' and id<>v_draft.id;
  update public.matrix_versions set status='ARCHIVED',
    effective_to=greatest(effective_from,p_effective_from-1)
  where status='ACTIVE' and id<>v_draft.id;
  update public.matrix_versions set status='ACTIVE',effective_from=p_effective_from,
    effective_to=null,activated_at=now(),published_at=now(),published_by=auth.uid(),
    content_hash=v_hash,schema_version=2
  where id=v_draft.id;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_v2',v_draft.id::text,'PUBLISH',jsonb_build_object(
    'version',v_draft.version,'effectiveFrom',p_effective_from,
    'contentHash',v_hash,'solverEngine',(select f.engine
      from public.solver_feature_flags f where f.flag_key='DEFAULT_ENGINE')));
  return v_draft.id;
end;
$$;

revoke all on function public.matrix_v2_publish_draft(date)
  from public,anon,authenticated;
grant execute on function public.matrix_v2_publish_draft(date)
  to authenticated;
