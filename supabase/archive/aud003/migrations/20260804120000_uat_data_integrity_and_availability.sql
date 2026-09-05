-- UAT integrity fixes: calendar-first availability, contract-aware defaults,
-- pay-rate employment validation and schedule-month publication readiness.

create or replace function public.employee_availability_bulk_save_v2(
  p_from date,
  p_to date,
  p_kind text,
  p_all_day boolean default true,
  p_local_start time default null,
  p_local_end time default null,
  p_preferred_location_id uuid default null,
  p_note text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_employee_id uuid;
  v_kind text := upper(trim(coalesce(p_kind,'')));
  v_timezone text;
  v_day date;
  v_start timestamptz;
  v_end timestamptz;
  v_count integer := 0;
  v_source_key text;
  v_location_logical_id uuid;
  v_preference public.employee_preferences%rowtype;
  v_constraint public.employee_time_constraints_v2%rowtype;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select employee.id into v_employee_id
  from public.employees employee
  where employee.auth_user_id=v_actor and employee.active
    and employee.archived_at is null
  order by employee.created_at limit 1;
  if v_employee_id is null then raise exception 'EMPLOYEE_PROFILE_REQUIRED'; end if;
  if p_from is null or p_to is null or p_to<p_from or p_to-p_from>62 then
    raise exception 'INVALID_DATE_RANGE';
  end if;
  if v_kind not in ('AVAILABLE','PREFER_NOT_TO_WORK','CANNOT_WORK') then
    raise exception 'INVALID_AVAILABILITY_KIND';
  end if;
  if not coalesce(p_all_day,false)
    and (p_local_start is null or p_local_end is null or p_local_end=p_local_start) then
    raise exception 'HOURS_REQUIRED';
  end if;

  select nullif(version.settings->>'timezone','') into v_timezone
  from public.matrix_versions version
  where version.status in ('ACTIVE','DRAFT')
    and (version.effective_from is null or version.effective_from<=p_to)
    and (version.effective_to is null or version.effective_to>=p_from)
  order by (version.status='ACTIVE') desc,version.version desc limit 1;
  if v_timezone is null then raise exception 'MATRIX_TIMEZONE_REQUIRED'; end if;

  if p_preferred_location_id is not null then
    select location.logical_id into v_location_logical_id
    from public.matrix_locations_v2 location
    join public.matrix_versions version on version.id=location.matrix_version_id
    where location.id=p_preferred_location_id and location.active
      and version.status in ('ACTIVE','DRAFT')
    order by (version.status='ACTIVE') desc,version.version desc limit 1;
    if v_location_logical_id is null then
      raise exception 'PREFERRED_LOCATION_NOT_FOUND';
    end if;
  end if;

  for v_day in select generate_series(p_from,p_to,interval '1 day')::date loop
    v_start := v_day::timestamp at time zone v_timezone;
    v_end := (v_day+1)::timestamp at time zone v_timezone;

    -- A day has one employee-controlled effective state. Protected HR/manager
    -- entries are deliberately excluded and remain authoritative.
    for v_preference in
      select preference.* from public.employee_preferences preference
      where preference.employee_id=v_employee_id
        and preference.status='ACTIVE'
        and preference.source='GRAFIK_PRO'
        and preference.editable_by_employee
        and preference.preference_type in ('OTHER','PREFERRED_LOCATION')
        and preference.valid_from<=v_day and preference.valid_to>=v_day
      for update
    loop
      update public.employee_preferences set status='CANCELLED'
      where id=v_preference.id;
      if v_preference.valid_from<v_day then
        insert into public.employee_preferences(
          employee_id,valid_from,valid_to,preference_type,preference_value,
          source,editable_by_employee,status
        ) values(
          v_preference.employee_id,v_preference.valid_from,v_day-1,
          v_preference.preference_type,v_preference.preference_value,
          v_preference.source,v_preference.editable_by_employee,'ACTIVE'
        );
      end if;
      if v_preference.valid_to>v_day then
        insert into public.employee_preferences(
          employee_id,valid_from,valid_to,preference_type,preference_value,
          source,editable_by_employee,status
        ) values(
          v_preference.employee_id,v_day+1,v_preference.valid_to,
          v_preference.preference_type,v_preference.preference_value,
          v_preference.source,v_preference.editable_by_employee,'ACTIVE'
        );
      end if;
    end loop;

    for v_constraint in
      select constraint_row.* from public.employee_time_constraints_v2 constraint_row
      where constraint_row.employee_id=v_employee_id
        and constraint_row.status='ACTIVE'
        and constraint_row.source='GRAFIK_PRO'
        and constraint_row.editable_by_employee
        and constraint_row.time_range && tstzrange(v_start,v_end,'[)')
      for update
    loop
      update public.employee_time_constraints_v2
      set status='REVOKED',revoked_at=now(),updated_at=now()
      where id=v_constraint.id;
      if lower(v_constraint.time_range)<v_start then
        insert into public.employee_time_constraints_v2(
          employee_id,constraint_kind,time_range,location_logical_id,source,
          source_record_key,priority,editable_by_employee,status,note,created_by
        ) values(
          v_employee_id,v_constraint.constraint_kind,
          tstzrange(lower(v_constraint.time_range),v_start,'[)'),
          v_constraint.location_logical_id,'GRAFIK_PRO',
          'self-split:left:'||gen_random_uuid()::text,v_constraint.priority,
          true,'ACTIVE',v_constraint.note,v_actor
        );
      end if;
      if upper(v_constraint.time_range)>v_end then
        insert into public.employee_time_constraints_v2(
          employee_id,constraint_kind,time_range,location_logical_id,source,
          source_record_key,priority,editable_by_employee,status,note,created_by
        ) values(
          v_employee_id,v_constraint.constraint_kind,
          tstzrange(v_end,upper(v_constraint.time_range),'[)'),
          v_constraint.location_logical_id,'GRAFIK_PRO',
          'self-split:right:'||gen_random_uuid()::text,v_constraint.priority,
          true,'ACTIVE',v_constraint.note,v_actor
        );
      end if;
    end loop;

    -- An all-day AVAILABLE entry without metadata is the baseline state and
    -- therefore needs no row. This keeps the calendar and solver consistent:
    -- green by default, with only exceptions persisted.
    if v_kind='PREFER_NOT_TO_WORK' then
      insert into public.employee_preferences(
        employee_id,valid_from,valid_to,preference_type,preference_value,
        source,editable_by_employee,status
      ) values(
        v_employee_id,v_day,v_day,'OTHER',jsonb_strip_nulls(jsonb_build_object(
          'kind','DAY_OFF','strength','SOFT','note',nullif(trim(p_note),''))),
        'GRAFIK_PRO',true,'ACTIVE'
      );
    elsif v_kind='CANNOT_WORK' or not coalesce(p_all_day,false) then
      if not coalesce(p_all_day,false) then
        v_start := (v_day+p_local_start)::timestamp at time zone v_timezone;
        v_end := case when p_local_end>p_local_start
          then (v_day+p_local_end)::timestamp at time zone v_timezone
          else (v_day+1+p_local_end)::timestamp at time zone v_timezone end;
      end if;
      v_source_key := 'self-day:'||v_employee_id::text||':'||v_kind||':'
        ||v_start::text||':'||v_end::text;
      insert into public.employee_time_constraints_v2(
        employee_id,constraint_kind,time_range,location_logical_id,source,
        source_record_key,priority,editable_by_employee,status,note,created_by
      ) values(
        v_employee_id,
        case when v_kind='AVAILABLE' then 'AVAILABLE_WINDOW' else 'UNAVAILABLE' end,
        tstzrange(v_start,v_end,'[)'),v_location_logical_id,'GRAFIK_PRO',
        v_source_key,100,true,'ACTIVE',nullif(trim(p_note),''),v_actor
      ) on conflict (source,source_record_key)
        where source_record_key is not null
        do update set status='ACTIVE',revoked_at=null,updated_at=now(),
          note=excluded.note,location_logical_id=excluded.location_logical_id;
    end if;

    if p_preferred_location_id is not null then
      insert into public.employee_preferences(
        employee_id,valid_from,valid_to,preference_type,preference_value,
        source,editable_by_employee,status
      ) values(
        v_employee_id,v_day,v_day,'PREFERRED_LOCATION',
        jsonb_build_object('locationId',p_preferred_location_id),
        'GRAFIK_PRO',true,'ACTIVE'
      );
    end if;
    v_count := v_count+1;
  end loop;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'employee_availability_v2',v_employee_id::text,'SET_DAYS',
    jsonb_build_object('from',p_from,'to',p_to,'kind',v_kind,
      'allDay',p_all_day,'days',v_count,
      'preferredLocationId',p_preferred_location_id));
  return jsonb_build_object('employeeId',v_employee_id,'savedDays',v_count,
    'kind',v_kind);
end;
$$;

revoke all on function public.employee_availability_bulk_save_v2(
  date,date,text,boolean,time,time,uuid,text
) from public,anon,authenticated;
grant execute on function public.employee_availability_bulk_save_v2(
  date,date,text,boolean,time,time,uuid,text
) to authenticated;

create or replace function public.employee_pay_rate_save_v2(
  p_id uuid,
  p_employee_id uuid,
  p_valid_from date,
  p_valid_to date,
  p_base_rate_minor bigint,
  p_currency text default null,
  p_contract_type text default null,
  p_active boolean default true
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_currency text;
  v_employment_start date;
  v_employment_end date;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')
      or public.has_app_role('HR_FINANCE')) then
    raise exception 'FORBIDDEN';
  end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  if not exists(select 1 from public.employees e where e.id=p_employee_id) then
    raise exception 'EMPLOYEE_NOT_FOUND';
  end if;
  if p_valid_from is null or (p_valid_to is not null and p_valid_to<p_valid_from)
      or p_base_rate_minor is null or p_base_rate_minor<0 then
    raise exception 'INVALID_PAY_RATE';
  end if;
  if p_id is not null and not exists(
    select 1 from public.employee_pay_rates_v2 rate
    where rate.id=p_id and rate.employee_id=p_employee_id
  ) then raise exception 'PAY_RATE_NOT_FOUND'; end if;

  select profile.employment_start,profile.employment_end
  into v_employment_start,v_employment_end
  from public.matrix_employee_profiles_v2 profile
  join public.matrix_versions version on version.id=profile.matrix_version_id
  where profile.employee_id=p_employee_id
  order by (version.status='DRAFT') desc,version.version desc limit 1;
  if v_employment_start is not null and p_valid_from<v_employment_start then
    raise exception 'PAY_RATE_BEFORE_EMPLOYMENT';
  end if;
  if v_employment_end is not null
    and (p_valid_from>v_employment_end
      or p_valid_to is null or p_valid_to>v_employment_end) then
    raise exception 'PAY_RATE_OUTSIDE_EMPLOYMENT';
  end if;

  select upper(mv.settings->>'currency') into v_currency
  from public.matrix_versions mv
  where mv.status in ('DRAFT','ACTIVE') and mv.schema_version>=2
  order by (mv.status='DRAFT') desc,mv.version desc limit 1;
  v_currency:=coalesce(nullif(upper(trim(p_currency)),''),v_currency);
  if not public.matrix_v2_is_iso_4217_currency(v_currency) then
    raise exception 'INVALID_CURRENCY';
  end if;
  if coalesce(p_active,true) and exists(
    select 1 from public.employee_pay_rates_v2 x
    where x.employee_id=p_employee_id and x.active and x.id is distinct from p_id
      and daterange(x.valid_from,case when x.valid_to is null then null else x.valid_to+1 end,'[)')
        && daterange(p_valid_from,case when p_valid_to is null then null else p_valid_to+1 end,'[)')
  ) then raise exception 'OVERLAPPING_ACTIVE_PAY_RATE'; end if;

  if p_id is null then
    insert into public.employee_pay_rates_v2(
      employee_id,valid_from,valid_to,base_rate_minor,currency,contract_type,
      active,created_by,updated_by
    ) values(
      p_employee_id,p_valid_from,p_valid_to,p_base_rate_minor,v_currency,
      nullif(trim(p_contract_type),''),coalesce(p_active,true),auth.uid(),auth.uid()
    ) returning id into v_id;
  else
    update public.employee_pay_rates_v2 set employee_id=p_employee_id,
      valid_from=p_valid_from,valid_to=p_valid_to,base_rate_minor=p_base_rate_minor,
      currency=v_currency,contract_type=nullif(trim(p_contract_type),''),
      active=coalesce(p_active,true),updated_by=auth.uid(),updated_at=now()
    where id=p_id and employee_id=p_employee_id returning id into v_id;
    if v_id is null then raise exception 'PAY_RATE_NOT_FOUND'; end if;
  end if;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'employee_pay_rate_v2',v_id::text,'UPSERT',jsonb_build_object(
    'employeeId',p_employee_id,'validFrom',p_valid_from,'validTo',p_valid_to,
    'currency',v_currency,'active',coalesce(p_active,true)));
  return v_id;
end;
$$;

revoke all on function public.employee_pay_rate_save_v2(
  uuid,uuid,date,date,bigint,text,text,boolean
) from public,anon,authenticated;
grant execute on function public.employee_pay_rate_save_v2(
  uuid,uuid,date,date,bigint,text,text,boolean
) to authenticated;

-- Editing employment dates must not leave an already recorded rate outside
-- the employee's period of cooperation.  The browser performs the same check,
-- but this wrapper makes the rule authoritative for every caller.
create or replace function public.matrix_v2_employee_save_uat_v3(
  p_employee_id uuid default null,
  p_data jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_start date;
  v_end date;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE')) then raise exception 'FORBIDDEN'; end if;
  if nullif(p_data->>'employmentStart','') is not null
    and not pg_catalog.pg_input_is_valid(p_data->>'employmentStart','date') then
    raise exception 'INVALID_EMPLOYMENT_DATES';
  end if;
  if nullif(p_data->>'employmentEnd','') is not null
    and not pg_catalog.pg_input_is_valid(p_data->>'employmentEnd','date') then
    raise exception 'INVALID_EMPLOYMENT_DATES';
  end if;
  v_start:=nullif(p_data->>'employmentStart','')::date;
  v_end:=nullif(p_data->>'employmentEnd','')::date;
  if v_end is not null and (v_start is null or v_end<v_start) then
    raise exception 'INVALID_EMPLOYMENT_DATES';
  end if;
  if p_employee_id is not null and exists(
    select 1 from public.employee_pay_rates_v2 rate
    where rate.employee_id=p_employee_id and (
      (v_start is not null and rate.valid_from<v_start)
      or (v_end is not null and (
        rate.valid_from>v_end or rate.valid_to is null or rate.valid_to>v_end
      ))
    )
  ) then raise exception 'EMPLOYMENT_DATES_CONFLICT_PAY_RATES'; end if;
  return public.matrix_v2_employee_save_uat_v2(p_employee_id,p_data);
end;
$$;

create or replace function public.matrix_v2_finance_step_skip_uat_v2(
  p_employee_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_matrix uuid;
  v_employee_no text;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE')) then raise exception 'FORBIDDEN'; end if;
  select profile.matrix_version_id,profile.employee_no
  into v_matrix,v_employee_no
  from public.matrix_employee_profiles_v2 profile
  join public.matrix_versions version on version.id=profile.matrix_version_id
  where profile.employee_id=p_employee_id and version.status='DRAFT'
  order by version.version desc limit 1;
  if v_matrix is null then raise exception 'MATRIX_EMPLOYEE_NOT_FOUND'; end if;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_v2_employee_finance',p_employee_id::text,
    'PAY_RATE_STEP_SKIPPED',jsonb_build_object(
      'matrixVersionId',v_matrix,'employeeNo',v_employee_no,
      'publicationRemainsBlocked',true
    ));
  return jsonb_build_object('employeeId',p_employee_id,'skipped',true);
end;
$$;

revoke all on function public.matrix_v2_employee_save_uat_v3(uuid,jsonb),
  public.matrix_v2_finance_step_skip_uat_v2(uuid)
  from public,anon,authenticated;
grant execute on function public.matrix_v2_employee_save_uat_v3(uuid,jsonb),
  public.matrix_v2_finance_step_skip_uat_v2(uuid)
  to authenticated;

-- A rate must cover every employed calendar day in the schedule month.  A
-- point-in-time check on the first day hid gaps later in the month and could
-- allow Matrix publication with an incomplete cost basis.
create or replace function solver_private.employee_pay_rate_covers_period_v2(
  p_employee_id uuid,
  p_from date,
  p_to date
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_from is not null and p_to is not null and p_to>=p_from
    and not exists(
      select 1
      from pg_catalog.generate_series(p_from,p_to,interval '1 day') covered_day
      where not exists(
        select 1 from public.employee_pay_rates_v2 rate
        where rate.employee_id=p_employee_id and rate.active
          and rate.valid_from<=covered_day::date
          and (rate.valid_to is null or rate.valid_to>=covered_day::date)
      )
    );
$$;

revoke all on function solver_private.employee_pay_rate_covers_period_v2(
  uuid,date,date
) from public,anon,authenticated;

-- Existing demo data used explicit business codes (RANO/SRODEK/WIECZOR), but
-- all 32 rows were stored as MIDDLE.  This repair is intentionally invoked by
-- an owner from the Matrix warning.  It creates/uses a draft and never rewrites
-- the published historical version in place.
create or replace function public.matrix_v2_normalize_shift_periods_uat_v2()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_matrix uuid;
  v_updated integer:=0;
  v_recognized integer:=0;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  v_matrix:=public.matrix_v2_create_draft(null);

  select count(*) into v_recognized
  from public.matrix_shift_templates_v2 shift_row
  where shift_row.matrix_version_id=v_matrix and shift_row.active
    and (upper(shift_row.code) like 'RANO%'
      or upper(shift_row.code) like 'SRODEK%'
      or upper(shift_row.code) like 'ŚRODEK%'
      or upper(shift_row.code) like 'WIECZOR%'
      or upper(shift_row.code) like 'WIECZÓR%');

  update public.matrix_shift_templates_v2 shift_row set
    shift_period=case
      when upper(shift_row.code) like 'RANO%' then 'MORNING'
      when upper(shift_row.code) like 'WIECZOR%'
        or upper(shift_row.code) like 'WIECZÓR%' then 'EVENING'
      else 'MIDDLE'
    end,
    updated_at=now()
  where shift_row.matrix_version_id=v_matrix and shift_row.active
    and (upper(shift_row.code) like 'RANO%'
      or upper(shift_row.code) like 'SRODEK%'
      or upper(shift_row.code) like 'ŚRODEK%'
      or upper(shift_row.code) like 'WIECZOR%'
      or upper(shift_row.code) like 'WIECZÓR%')
    and shift_row.shift_period is distinct from case
      when upper(shift_row.code) like 'RANO%' then 'MORNING'
      when upper(shift_row.code) like 'WIECZOR%'
        or upper(shift_row.code) like 'WIECZÓR%' then 'EVENING'
      else 'MIDDLE'
    end;
  get diagnostics v_updated=row_count;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_v2_shift_periods',v_matrix::text,'NORMALIZE_FROM_CODES',
    jsonb_build_object('recognized',v_recognized,'updated',v_updated,
      'convention',jsonb_build_object(
        'RANO','MORNING','SRODEK','MIDDLE','WIECZOR','EVENING')));
  return jsonb_build_object('matrixVersionId',v_matrix,
    'recognized',v_recognized,'updated',v_updated);
end;
$$;

revoke all on function public.matrix_v2_normalize_shift_periods_uat_v2()
  from public,anon,authenticated;
grant execute on function public.matrix_v2_normalize_shift_periods_uat_v2()
  to authenticated;

create or replace function public.matrix_v2_publication_readiness_uat_v2(
  p_effective_from date,
  p_schedule_month date
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_matrix uuid;
  v_month date:=date_trunc('month',coalesce(p_schedule_month,p_effective_from,current_date))::date;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  select mv.id into v_matrix from public.matrix_versions mv
  where mv.status='DRAFT' and mv.schema_version>=2
  order by mv.version desc limit 1;
  if v_matrix is null then raise exception 'NO_MATRIX_V2_DRAFT'; end if;

  return jsonb_build_object(
    'ready',not exists(
      select 1 from public.matrix_employee_profiles_v2 profile
      where profile.matrix_version_id=v_matrix and profile.active
        and coalesce(profile.employment_start,v_month)<v_month+interval '1 month'
        and coalesce(profile.employment_end,v_month)>=v_month
        and (
          not solver_private.employee_pay_rate_covers_period_v2(
            profile.employee_id,
            greatest(v_month,coalesce(profile.employment_start,v_month)),
            least((v_month+interval '1 month'-interval '1 day')::date,
              coalesce(profile.employment_end,(v_month+interval '1 month'-interval '1 day')::date))
          )
          or not exists(select 1 from public.matrix_employee_roles_v2 role_grant
            where role_grant.matrix_version_id=v_matrix
              and role_grant.employee_id=profile.employee_id and role_grant.active)
          or not exists(select 1 from public.matrix_employee_locations_v2 location_grant
            where location_grant.matrix_version_id=v_matrix
              and location_grant.employee_id=profile.employee_id
              and location_grant.active and location_grant.standard_allowed)
        )
    ) and not exists(
      select 1 from public.matrix_shift_templates_v2 shift_row
      where shift_row.matrix_version_id=v_matrix and shift_row.active
        and shift_row.shift_period is distinct from case
          when upper(shift_row.code) like 'RANO%' then 'MORNING'
          when upper(shift_row.code) like 'SRODEK%'
            or upper(shift_row.code) like 'ŚRODEK%' then 'MIDDLE'
          when upper(shift_row.code) like 'WIECZOR%'
            or upper(shift_row.code) like 'WIECZÓR%' then 'EVENING'
          else shift_row.shift_period
        end
    ),
    'blockers',coalesce((
      select jsonb_agg(blocker order by blocker->>'employeeNo',blocker->>'code')
      from (
        select jsonb_build_object(
          'code','MISSING_PAY_RATE','employeeId',profile.employee_id,
          'employeeNo',profile.employee_no,
          'employeeName',profile.first_name||' '||profile.last_name,
          'requiredFrom',greatest(v_month,coalesce(profile.employment_start,v_month)),
          'requiredTo',least((v_month+interval '1 month'-interval '1 day')::date,
            coalesce(profile.employment_end,(v_month+interval '1 month'-interval '1 day')::date)),
          'foundRates',coalesce((
            select jsonb_agg(jsonb_build_object(
              'validFrom',rate.valid_from,'validTo',rate.valid_to,
              'amountMinor',rate.base_rate_minor,'currency',rate.currency
            ) order by rate.valid_from)
            from public.employee_pay_rates_v2 rate
            where rate.employee_id=profile.employee_id and rate.active
          ),'[]'::jsonb),
          'message','Brak ciągłej aktywnej stawki dla całego okresu pracy w miesiącu grafiku.'
        ) blocker
        from public.matrix_employee_profiles_v2 profile
        where profile.matrix_version_id=v_matrix and profile.active
          and coalesce(profile.employment_start,v_month)<v_month+interval '1 month'
          and coalesce(profile.employment_end,v_month)>=v_month
          and not solver_private.employee_pay_rate_covers_period_v2(
            profile.employee_id,
            greatest(v_month,coalesce(profile.employment_start,v_month)),
            least((v_month+interval '1 month'-interval '1 day')::date,
              coalesce(profile.employment_end,(v_month+interval '1 month'-interval '1 day')::date))
          )
        union all
        select jsonb_build_object(
          'code','MISSING_ROLE','employeeId',profile.employee_id,
          'employeeNo',profile.employee_no,
          'employeeName',profile.first_name||' '||profile.last_name,
          'message','Brak aktywnej roli w Matrixie.'
        )
        from public.matrix_employee_profiles_v2 profile
        where profile.matrix_version_id=v_matrix and profile.active
          and coalesce(profile.employment_start,v_month)<v_month+interval '1 month'
          and coalesce(profile.employment_end,v_month)>=v_month
          and not exists(select 1 from public.matrix_employee_roles_v2 role_grant
            where role_grant.matrix_version_id=v_matrix
              and role_grant.employee_id=profile.employee_id and role_grant.active)
        union all
        select jsonb_build_object(
          'code','MISSING_STANDARD_LOCATION','employeeId',profile.employee_id,
          'employeeNo',profile.employee_no,
          'employeeName',profile.first_name||' '||profile.last_name,
          'message','Brak co najmniej jednego zwykłego lokalu pracy.'
        )
        from public.matrix_employee_profiles_v2 profile
        where profile.matrix_version_id=v_matrix and profile.active
          and coalesce(profile.employment_start,v_month)<v_month+interval '1 month'
          and coalesce(profile.employment_end,v_month)>=v_month
          and not exists(select 1 from public.matrix_employee_locations_v2 location_grant
            where location_grant.matrix_version_id=v_matrix
              and location_grant.employee_id=profile.employee_id
              and location_grant.active and location_grant.standard_allowed)
        union all
        select jsonb_build_object(
          'code','SHIFT_PERIOD_MISMATCH','shiftTemplateId',shift_row.id,
          'shiftName',shift_row.name,'shiftCode',shift_row.code,
          'storedPeriod',shift_row.shift_period,
          'expectedPeriod',case
            when upper(shift_row.code) like 'RANO%' then 'MORNING'
            when upper(shift_row.code) like 'SRODEK%'
              or upper(shift_row.code) like 'ŚRODEK%' then 'MIDDLE'
            when upper(shift_row.code) like 'WIECZOR%'
              or upper(shift_row.code) like 'WIECZÓR%' then 'EVENING'
          end,
          'message','Pora zmiany jest niespójna z jej jednoznacznym kodem.'
        )
        from public.matrix_shift_templates_v2 shift_row
        where shift_row.matrix_version_id=v_matrix and shift_row.active
          and shift_row.shift_period is distinct from case
            when upper(shift_row.code) like 'RANO%' then 'MORNING'
            when upper(shift_row.code) like 'SRODEK%'
              or upper(shift_row.code) like 'ŚRODEK%' then 'MIDDLE'
            when upper(shift_row.code) like 'WIECZOR%'
              or upper(shift_row.code) like 'WIECZÓR%' then 'EVENING'
            else shift_row.shift_period
          end
      ) problems
    ),'[]'::jsonb),
    'effectiveFrom',coalesce(p_effective_from,current_date),
    'scheduleMonth',v_month,
    'matrixVersionId',v_matrix
  );
end;
$$;

revoke all on function public.matrix_v2_publication_readiness_uat_v2(date,date)
  from public,anon,authenticated;
grant execute on function public.matrix_v2_publication_readiness_uat_v2(date,date)
  to authenticated;

comment on function public.matrix_v2_publication_readiness_uat_v2(date,date) is
  'Checks Matrix publication integrity against the schedule month, not the wall-clock publication day.';

create or replace function public.optimizer_variant_issue_diagnostics_uat_v2(
  p_variant_id uuid,
  p_issue_id bigint
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_variant public.plan_variants_v2%rowtype;
  v_run public.optimization_runs_v2%rowtype;
  v_issue public.plan_issues_v2%rowtype;
  v_shift public.plan_shifts_v2%rowtype;
  v_shift_period text;
  v_timezone text;
  v_default_rest integer;
  v_default_missing boolean;
  v_summary jsonb;
  v_candidates jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into v_variant from public.plan_variants_v2 variant
  where variant.id=p_variant_id;
  if v_variant.id is null then raise exception 'VARIANT_NOT_FOUND'; end if;
  select * into v_run from public.optimization_runs_v2 run
  where run.id=v_variant.run_id;
  if v_run.id is null or not solver_private.can_access_run_v2(v_run.id) then
    raise exception 'VARIANT_NOT_FOUND';
  end if;
  select * into v_issue from public.plan_issues_v2 issue
  where issue.id=p_issue_id and issue.variant_id=p_variant_id
    and issue.issue_code='UNFILLED_SLOT';
  if v_issue.id is null then raise exception 'UNFILLED_ISSUE_NOT_FOUND'; end if;
  select * into v_shift from public.plan_shifts_v2 shift
  where shift.id=v_issue.shift_id;
  if v_shift.id is null then raise exception 'SHIFT_NOT_FOUND'; end if;
  select template.shift_period,location.timezone
  into v_shift_period,v_timezone
  from public.matrix_shift_templates_v2 template
  join public.matrix_locations_v2 location on location.id=template.location_id
  where template.id=v_shift.shift_template_id;
  select coalesce(
      (snapshot.snapshot->'settings'->>'minimumRestMinutes')::integer,
      (matrix.settings->>'minimumRestMinutes')::integer,660
    ),coalesce(
      (snapshot.snapshot->'settings'->>'missingAvailabilityMeansAvailable')::boolean,
      (matrix.settings->>'missingAvailabilityMeansAvailable')::boolean,true
    )
  into v_default_rest,v_default_missing
  from public.matrix_versions matrix
  left join solver_private.optimization_snapshots_v2 snapshot
    on snapshot.run_id=v_run.id
  where matrix.id=v_run.matrix_version_id;

  with scheduled as (
    select assignment.employee_id,shift.starts_at,shift.ends_at,shift.shift_date
    from public.plan_assignments_v2 assignment
    join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
    where assignment.variant_id=p_variant_id
  ), profiles as (
    select profile.*,coalesce(hr.contract_type,'INNE') contract_type,
      case when coalesce(hr.contract_type,'INNE') in ('ZLECENIE','B2B')
        and profile.work_time_policy<>'CUSTOM'
        then 0 else coalesce(profile.minimum_rest_minutes,v_default_rest) end rest_minutes
    from public.matrix_employee_profiles_v2 profile
    left join public.employee_hr_profiles hr on hr.employee_id=profile.employee_id
    where profile.matrix_version_id=v_run.matrix_version_id
      and profile.active and profile.archived_at is null
  ), evaluated as (
    select profile.*,
      exists(select 1 from public.matrix_employee_roles_v2 grant_row
        where grant_row.matrix_version_id=v_run.matrix_version_id
          and grant_row.employee_id=profile.employee_id
          and grant_row.role_id=v_issue.role_id and grant_row.active
          and (grant_row.valid_from is null or grant_row.valid_from<=v_shift.shift_date)
          and (grant_row.valid_to is null or grant_row.valid_to>=v_shift.shift_date)) role_ok,
      exists(select 1 from public.matrix_employee_locations_v2 grant_row
        where grant_row.matrix_version_id=v_run.matrix_version_id
          and grant_row.employee_id=profile.employee_id
          and grant_row.location_id=v_shift.location_id
          and grant_row.active and grant_row.standard_allowed
          and (grant_row.valid_from is null or grant_row.valid_from<=v_shift.shift_date)
          and (grant_row.valid_to is null or grant_row.valid_to>=v_shift.shift_date)) location_ok,
      v_issue.duty_id is null or exists(
        select 1 from public.matrix_employee_duties_v2 grant_row
        where grant_row.matrix_version_id=v_run.matrix_version_id
          and grant_row.employee_id=profile.employee_id
          and grant_row.duty_id=v_issue.duty_id and grant_row.active
          and (grant_row.role_id is null or grant_row.role_id=v_issue.role_id)
          and (grant_row.location_id is null or grant_row.location_id=v_shift.location_id)
          and (grant_row.valid_from is null or grant_row.valid_from<=v_shift.shift_date)
          and (grant_row.valid_to is null or grant_row.valid_to>=v_shift.shift_date)) duty_ok,
      exists(select 1 from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and tstzrange(assignment.starts_at,assignment.ends_at,'[)')
            && tstzrange(v_shift.starts_at,v_shift.ends_at,'[)')) overlap,
      exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=profile.employee_id
          and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
          and constraint_row.time_range
            && tstzrange(v_shift.starts_at,v_shift.ends_at,'[)')) blocked_time,
      exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=profile.employee_id
          and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind='AVAILABLE_WINDOW'
          and constraint_row.time_range && tstzrange(
            v_shift.shift_date::timestamp at time zone v_timezone,
            (v_shift.shift_date+1)::timestamp at time zone v_timezone,'[)')) has_day_window,
      exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=profile.employee_id
          and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind='AVAILABLE_WINDOW'
          and lower(constraint_row.time_range)<=v_shift.starts_at
          and upper(constraint_row.time_range)>=v_shift.ends_at) covers_window,
      coalesce((select sum(extract(epoch from
        (assignment.ends_at-assignment.starts_at))/60)::integer
        from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and assignment.shift_date>=v_run.month
          and assignment.shift_date<(v_run.month+interval '1 month')::date),0)
        monthly_minutes,
      coalesce((select sum(extract(epoch from
        (assignment.ends_at-assignment.starts_at))/60)::integer
        from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and assignment.shift_date>=date_trunc('week',v_shift.shift_date)::date
          and assignment.shift_date<date_trunc('week',v_shift.shift_date)::date+7),0)
        weekly_minutes,
      (select max(assignment.ends_at) from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and assignment.ends_at<=v_shift.starts_at) previous_end,
      (select min(assignment.starts_at) from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and assignment.starts_at>=v_shift.ends_at) next_start,
      coalesce((select min(day_offset.value)-1
        from generate_series(1,31) day_offset(value)
        where not exists(select 1 from scheduled assignment
          where assignment.employee_id=profile.employee_id
            and assignment.shift_date=v_shift.shift_date-day_offset.value)),31)
        consecutive_before,
      coalesce((select min(day_offset.value)-1
        from generate_series(1,31) day_offset(value)
        where not exists(select 1 from scheduled assignment
          where assignment.employee_id=profile.employee_id
            and assignment.shift_date=v_shift.shift_date+day_offset.value)),31)
        consecutive_after,
      coalesce(solver_private.alpha16_preference_level_v2(
        profile.employee_id,v_run.matrix_version_id,v_run.month,v_shift_period
      ),'NEUTRAL') preference_level
    from profiles profile
  ), classified as (
    select candidate.employee_id,candidate.employee_no,candidate.first_name,
      candidate.last_name,candidate.role_ok,candidate.location_ok,
      candidate.duty_ok,candidate.has_day_window,candidate.covers_window,
      array_remove(array[
        case when (candidate.employment_start is not null
          and candidate.employment_start>v_shift.shift_date)
          or (candidate.employment_end is not null
          and candidate.employment_end<v_shift.shift_date) then 'OUTSIDE_EMPLOYMENT' end,
        case when not candidate.role_ok then 'ROLE_REQUIRED' end,
        case when not candidate.location_ok then 'LOCATION_NOT_ALLOWED' end,
        case when not candidate.duty_ok then 'DUTY_REQUIRED' end,
        case when candidate.no_weekends and extract(isodow from v_shift.shift_date) in (6,7)
          then 'WEEKEND_BLOCKED' end,
        case when candidate.only_morning and v_shift_period<>'MORNING'
          or candidate.only_evening and v_shift_period<>'EVENING'
          or candidate.preference_level='BLOCKED' then 'MANAGER_SHIFT_BLOCK' end,
        case when candidate.blocked_time then 'DECLARED_UNAVAILABLE' end,
        case when candidate.has_day_window and not candidate.covers_window
          then 'OUTSIDE_AVAILABILITY_WINDOW' end,
        case when not candidate.has_day_window and not v_default_missing
          then 'MISSING_AVAILABILITY' end,
        case when candidate.overlap then 'SHIFT_OVERLAP' end,
        case when candidate.previous_end is not null and extract(epoch from
          (v_shift.starts_at-candidate.previous_end))/60<candidate.rest_minutes
          then 'REST_AFTER_PREVIOUS_SHIFT' end,
        case when candidate.next_start is not null and extract(epoch from
          (candidate.next_start-v_shift.ends_at))/60<candidate.rest_minutes
          then 'REST_BEFORE_NEXT_SHIFT' end,
        case when (candidate.contract_type not in ('ZLECENIE','B2B')
            or candidate.work_time_policy='CUSTOM')
          and candidate.monthly_minutes
            +extract(epoch from (v_shift.ends_at-v_shift.starts_at))/60
            >candidate.maximum_monthly_minutes then 'MONTHLY_LIMIT' end,
        case when (candidate.contract_type not in ('ZLECENIE','B2B')
            or candidate.work_time_policy='CUSTOM')
          and candidate.weekly_minutes
            +extract(epoch from (v_shift.ends_at-v_shift.starts_at))/60
            >candidate.maximum_weekly_minutes then 'WEEKLY_LIMIT' end,
        case when (candidate.contract_type not in ('ZLECENIE','B2B')
            or candidate.work_time_policy='CUSTOM')
          and candidate.consecutive_before+1+candidate.consecutive_after
            >candidate.maximum_consecutive_days then 'MAX_CONSECUTIVE_DAYS' end
      ]::text[],null) reasons
    from evaluated candidate
  )
  select jsonb_build_object(
      'considered',count(*),
      'eligible',count(*) filter(where cardinality(candidate.reasons)=0),
      'blocked',count(*) filter(where cardinality(candidate.reasons)>0),
      'reasons',coalesce((select jsonb_agg(jsonb_build_object(
        'code',reason_count.reason,'count',reason_count.amount
      ) order by reason_count.amount desc,reason_count.reason)
        from (select reason,count(*) amount
          from classified item
          cross join lateral unnest(item.reasons) reason
          group by reason) reason_count),'[]'::jsonb)
    ),
    coalesce(jsonb_agg(jsonb_build_object(
      'employeeId',candidate.employee_id,
      'employeeNo',candidate.employee_no,
      'employeeName',candidate.first_name||' '||candidate.last_name,
      'roleMatch',candidate.role_ok,
      'locationMatch',candidate.location_ok,
      'dutyMatch',candidate.duty_ok,
      'hasDeclaredWindow',candidate.has_day_window,
      'coversShift',candidate.covers_window,
      'reasons',to_jsonb(candidate.reasons)
    ) order by candidate.role_ok desc,candidate.location_ok desc,
      candidate.last_name,candidate.first_name),'[]'::jsonb)
  into v_summary,v_candidates
  from classified candidate;

  return jsonb_build_object(
    'variantId',p_variant_id,
    'issueId',p_issue_id,
    'shift',jsonb_build_object(
      'date',v_shift.shift_date,'startsAt',v_shift.starts_at,
      'endsAt',v_shift.ends_at,'shiftPeriod',v_shift_period
    ),
    'summary',v_summary,
    'candidates',v_candidates
  );
end;
$$;

revoke all on function public.optimizer_variant_issue_diagnostics_uat_v2(
  uuid,bigint
) from public,anon,authenticated;
grant execute on function public.optimizer_variant_issue_diagnostics_uat_v2(
  uuid,bigint
) to authenticated;

comment on function public.optimizer_variant_issue_diagnostics_uat_v2(uuid,bigint) is
  'Explains every candidate for an unfilled slot using the same missing-availability default as the solver and returns role-matching employee details.';

create or replace function public.employee_time_constraints_self_v2(
  p_month date
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_month date:=date_trunc('month',p_month)::date;
  v_employee_id uuid;
  v_matrix uuid;
  v_timezone text;
  v_default_available boolean;
  v_period_start timestamptz;
  v_period_end timestamptz;
  v_constraints jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  select employee.id into v_employee_id
  from public.employees employee
  where employee.auth_user_id=auth.uid() and employee.active
    and employee.archived_at is null
  order by employee.id limit 1;
  if v_employee_id is null then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  select matrix.id,nullif(matrix.settings->>'timezone',''),
    coalesce((matrix.settings->>'missingAvailabilityMeansAvailable')::boolean,true)
  into v_matrix,v_timezone,v_default_available
  from public.matrix_versions matrix
  where matrix.status in ('ACTIVE','ARCHIVED') and matrix.schema_version>=2
    and matrix.effective_from<=v_month
    and coalesce(matrix.content_hash,'') ~ '^[0-9a-f]{64}$'
    and coalesce(matrix.workforce_hash,'') ~ '^[0-9a-f]{64}$'
  order by matrix.effective_from desc,matrix.version desc limit 1;
  if v_timezone is null then raise exception 'MATRIX_V2_FOR_MONTH_NOT_FOUND'; end if;
  v_period_start:=v_month::timestamp at time zone v_timezone;
  v_period_end:=(v_month+interval '1 month')::timestamp at time zone v_timezone;

  with entries as (
    select constraint_row.id,constraint_row.constraint_kind kind,
      lower(constraint_row.time_range) starts_at,
      upper(constraint_row.time_range) ends_at,
      constraint_row.source,
      constraint_row.source='GRAFIK_PRO'
        and constraint_row.editable_by_employee editable,
      constraint_row.note,
      (select location.id from public.matrix_locations_v2 location
        where location.matrix_version_id=v_matrix
          and location.logical_id=constraint_row.location_logical_id
        order by location.active desc,location.sort_order limit 1) preferred_location_id
    from public.employee_time_constraints_v2 constraint_row
    where constraint_row.employee_id=v_employee_id
      and constraint_row.status='ACTIVE'
      and constraint_row.time_range
        && tstzrange(v_period_start,v_period_end,'[)')
    union all
    select preference.id,
      case when preference.preference_type='OTHER'
        then 'PREFER_NOT_TO_WORK' else 'PREFERRED_LOCATION' end,
      preference.valid_from::timestamp at time zone v_timezone,
      (preference.valid_to+1)::timestamp at time zone v_timezone,
      preference.source,
      preference.source='GRAFIK_PRO' and preference.editable_by_employee,
      nullif(preference.preference_value->>'note',''),
      case when preference.preference_type='PREFERRED_LOCATION'
        and preference.preference_value->>'locationId'
          ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
        then (preference.preference_value->>'locationId')::uuid else null end
    from public.employee_preferences preference
    where preference.employee_id=v_employee_id
      and preference.status='ACTIVE'
      and preference.valid_from<v_month+interval '1 month'
      and preference.valid_to>=v_month
      and (preference.preference_type='PREFERRED_LOCATION'
        or (preference.preference_type='OTHER'
          and preference.preference_value->>'kind'='DAY_OFF'
          and preference.preference_value->>'strength'='SOFT'))
  )
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
    'id',entry.id,'kind',entry.kind,'startsAt',entry.starts_at,
    'endsAt',entry.ends_at,'source',entry.source,
    'editable',entry.editable,'note',entry.note,
    'preferredLocationId',entry.preferred_location_id
  )) order by entry.starts_at,entry.ends_at,entry.id),'[]'::jsonb)
  into v_constraints from entries entry;
  return jsonb_build_object(
    'employeeId',v_employee_id,'timezone',v_timezone,
    'defaultAvailable',v_default_available,
    'constraints',v_constraints
  );
end;
$$;

revoke all on function public.employee_time_constraints_self_v2(date)
  from public,anon,authenticated;
grant execute on function public.employee_time_constraints_self_v2(date)
  to authenticated;

comment on function public.employee_time_constraints_self_v2(date) is
  'Returns calendar-ready employee availability exceptions and the effective default availability for the selected month.';

-- Normalize spreadsheet identities before preview and apply.  Older demo
-- profiles may not have copied the address stored on public.employees, while
-- the Apps Script workbook intentionally has no GP number.  In that case the
-- canonical (oldest numbered) employee is updated instead of creating a copy.
-- Blank contractor limits remain non-binding neutral values rather than
-- invented employment-contract defaults.  Existing values are preserved when
-- a cell is blank, except for ZLECENIE/B2B using CONTRACT_DEFAULT: that explicit
-- policy clears legacy 168/210/40 defaults instead of carrying them forward.
create or replace function solver_private.matrix_v2_import_normalize_uat_v3(
  p_payload jsonb,
  p_matrix_version_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_employees jsonb;
  v_employee_duties jsonb;
begin
  select coalesce(jsonb_agg(
    source.value || jsonb_strip_nulls(jsonb_build_object(
      'employeeNo',coalesce(nullif(trim(source.value->>'employeeNo'),''),match.employee_no),
      'contractType',coalesce(nullif(trim(source.value->>'contractType'),''),match.contract_type),
      'employmentFraction',case
        when nullif(trim(source.value->>'employmentFraction'),'') is not null
          then source.value->>'employmentFraction'
        when match.employment_fraction is not null then match.employment_fraction::text
        when nullif(trim(source.value->>'contractType'),'') is not null
          or match.contract_type is not null then '1'
        else null end,
      'workTimePolicy',case
        when nullif(trim(source.value->>'workTimePolicy'),'') is not null
          then source.value->>'workTimePolicy'
        when match.work_time_policy is not null then match.work_time_policy
        when nullif(trim(source.value->>'contractType'),'') is not null
          or match.contract_type is not null then 'CONTRACT_DEFAULT'
        else null end,
      'nominalHours',case
        when nullif(trim(source.value->>'nominalHours'),'') is not null
          then source.value->>'nominalHours'
        when solver_private.normalize_contract_type_v2(coalesce(
          nullif(source.value->>'contractType',''),match.contract_type
        )) in ('ZLECENIE','B2B')
          and upper(coalesce(nullif(source.value->>'workTimePolicy',''),
            match.work_time_policy,'CONTRACT_DEFAULT'))<>'CUSTOM' then '0'
        when match.nominal_monthly_minutes is not null
          then (match.nominal_monthly_minutes::numeric/60)::text
        else null end,
      'maximumMonthlyHours',case
        when nullif(trim(source.value->>'maximumMonthlyHours'),'') is not null
          then source.value->>'maximumMonthlyHours'
        when solver_private.normalize_contract_type_v2(coalesce(
          nullif(source.value->>'contractType',''),match.contract_type
        )) in ('ZLECENIE','B2B')
          and upper(coalesce(nullif(source.value->>'workTimePolicy',''),
            match.work_time_policy,'CONTRACT_DEFAULT'))<>'CUSTOM' then '0'
        when match.maximum_monthly_minutes is not null
          then (match.maximum_monthly_minutes::numeric/60)::text
        else null end,
      'maximumWeeklyHours',case
        when nullif(trim(source.value->>'maximumWeeklyHours'),'') is not null
          then source.value->>'maximumWeeklyHours'
        when solver_private.normalize_contract_type_v2(coalesce(
          nullif(source.value->>'contractType',''),match.contract_type
        )) in ('ZLECENIE','B2B')
          and upper(coalesce(nullif(source.value->>'workTimePolicy',''),
            match.work_time_policy,'CONTRACT_DEFAULT'))<>'CUSTOM' then '0'
        when match.maximum_weekly_minutes is not null
          then (match.maximum_weekly_minutes::numeric/60)::text
        else null end,
      'maximumConsecutiveDays',case
        when nullif(trim(source.value->>'maximumConsecutiveDays'),'') is not null
          then source.value->>'maximumConsecutiveDays'
        when solver_private.normalize_contract_type_v2(coalesce(
          nullif(source.value->>'contractType',''),match.contract_type
        )) in ('ZLECENIE','B2B')
          and upper(coalesce(nullif(source.value->>'workTimePolicy',''),
            match.work_time_policy,'CONTRACT_DEFAULT'))<>'CUSTOM' then '31'
        when match.maximum_consecutive_days is not null
          then match.maximum_consecutive_days::text
        else null end
    )) order by source.ordinality
  ),'[]'::jsonb) into v_employees
  from jsonb_array_elements(coalesce(p_payload->'employees','[]'::jsonb))
    with ordinality source(value,ordinality)
  left join lateral (
    select profile.employee_no,profile.nominal_monthly_minutes,
      profile.maximum_monthly_minutes,profile.maximum_weekly_minutes,
      profile.maximum_consecutive_days,profile.work_time_policy,
      hr.contract_type,hr.employment_fraction
    from public.matrix_employee_profiles_v2 profile
    join public.employees employee on employee.id=profile.employee_id
    left join public.employee_hr_profiles hr on hr.employee_id=profile.employee_id
    where profile.matrix_version_id=p_matrix_version_id and (
      (nullif(trim(source.value->>'employeeNo'),'') is not null
        and upper(profile.employee_no)=upper(trim(source.value->>'employeeNo')))
      or (nullif(lower(trim(source.value->>'email')),'') is not null and (
        lower(coalesce(profile.email,''))=lower(trim(source.value->>'email'))
        or lower(coalesce(employee.email,''))=lower(trim(source.value->>'email'))
      ))
    )
    order by profile.active desc,
      case when profile.employee_no~*'^GP-[0-9]+$'
        then substring(profile.employee_no from '[0-9]+$')::integer
        else 2147483647 end,
      profile.created_at,profile.employee_id
    limit 1
  ) match on true;

  select coalesce(jsonb_agg(
    source.value || case when match.employee_no is null then '{}'::jsonb
      else jsonb_build_object('employeeNo',match.employee_no) end
    order by source.ordinality
  ),'[]'::jsonb) into v_employee_duties
  from jsonb_array_elements(coalesce(p_payload->'employeeDuties','[]'::jsonb))
    with ordinality source(value,ordinality)
  left join lateral (
    select profile.employee_no
    from public.matrix_employee_profiles_v2 profile
    join public.employees employee on employee.id=profile.employee_id
    where profile.matrix_version_id=p_matrix_version_id and (
      (nullif(trim(source.value->>'employeeNo'),'') is not null
        and upper(profile.employee_no)=upper(trim(source.value->>'employeeNo')))
      or (nullif(lower(trim(source.value->>'email')),'') is not null and (
        lower(coalesce(profile.email,''))=lower(trim(source.value->>'email'))
        or lower(coalesce(employee.email,''))=lower(trim(source.value->>'email'))
      ))
    )
    order by profile.active desc,
      case when profile.employee_no~*'^GP-[0-9]+$'
        then substring(profile.employee_no from '[0-9]+$')::integer
        else 2147483647 end,
      profile.created_at,profile.employee_id
    limit 1
  ) match on true;

  return jsonb_set(
    jsonb_set(p_payload,'{employees}',v_employees,true),
    '{employeeDuties}',v_employee_duties,true
  );
end;
$$;

revoke all on function solver_private.matrix_v2_import_normalize_uat_v3(jsonb,uuid)
  from public,anon,authenticated;
grant execute on function solver_private.matrix_v2_import_normalize_uat_v3(jsonb,uuid)
  to service_role;

create or replace function public.matrix_v2_import_preview_uat_v3(
  p_payload jsonb,
  p_mode text default 'UPDATE'
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_mode text:=upper(trim(coalesce(p_mode,'UPDATE')));
  v_preview jsonb;
  v_normalized jsonb;
  v_matrix uuid;
  v_updates integer;
  v_creates integer;
  v_archives integer:=0;
  v_archive_rows jsonb:='[]'::jsonb;
  v_errors jsonb;
  v_row jsonb;
  v_index integer;
  v_contract text;
  v_limits_invalid boolean;
  v_employee uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if v_mode not in ('UPDATE','REPLACE') then raise exception 'INVALID_IMPORT_MODE'; end if;
  v_preview:=public.matrix_v2_import_preview_uat_v2(p_payload);
  v_matrix:=(v_preview->>'matrixVersionId')::uuid;
  v_normalized:=solver_private.matrix_v2_import_normalize_uat_v3(p_payload,v_matrix);
  v_preview:=public.matrix_v2_import_preview_uat_v2(v_normalized);
  v_errors:=coalesce(v_preview->'errors','[]'::jsonb);
  for v_row,v_index in
    select source.value,source.ordinality::integer
    from jsonb_array_elements(coalesce(v_normalized->'employees','[]'::jsonb))
      with ordinality source(value,ordinality)
  loop
    v_contract:=solver_private.normalize_contract_type_v2(v_row->>'contractType');
    if nullif(trim(v_row->>'contractType'),'') is null then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','CONTRACT_TYPE_REQUIRED',
        'message','Wybierz formę współpracy. Import nie przypisuje umowy automatycznie.'
      ));
    end if;
    if (v_row ? 'active' and jsonb_typeof(v_row->'active')<>'boolean')
      or (v_row ? 'onlyMorning' and jsonb_typeof(v_row->'onlyMorning')<>'boolean')
      or (v_row ? 'onlyEvening' and jsonb_typeof(v_row->'onlyEvening')<>'boolean')
      or (v_row ? 'noWeekends' and jsonb_typeof(v_row->'noWeekends')<>'boolean') then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','INVALID_EMPLOYEE_BOOLEAN',
        'message','Pola aktywności i ograniczeń muszą mieć wartość TAK albo NIE.'
      ));
    elsif coalesce((v_row->>'onlyMorning')::boolean,false)
      and coalesce((v_row->>'onlyEvening')::boolean,false) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','CONFLICTING_SHIFT_LIMITS',
        'message','Pracownik nie może mieć jednocześnie ograniczenia tylko rano i tylko popołudnie.'
      ));
    end if;
    if v_row ? 'locationGrants' then
      if jsonb_typeof(v_row->'locationGrants')<>'array' then
        v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
          'sheet','PRACOWNICY','row',v_index+1,'code','INVALID_LOCATION_GRANTS',
          'message','Uprawnienia lokalowe muszą być listą lokali.'
        ));
      elsif exists(
        select 1 from jsonb_array_elements(v_row->'locationGrants') location_grant
        where jsonb_typeof(location_grant.value)<>'object'
          or nullif(trim(location_grant.value->>'code'),'') is null
          or not exists(select 1 from public.matrix_locations_v2 location_row
            where location_row.matrix_version_id=v_matrix and location_row.active
              and upper(location_row.code)=upper(location_grant.value->>'code'))
          or (location_grant.value ? 'standardAllowed'
            and jsonb_typeof(location_grant.value->'standardAllowed')<>'boolean')
          or (location_grant.value ? 'overtimeAllowed'
            and jsonb_typeof(location_grant.value->'overtimeAllowed')<>'boolean')
          or (location_grant.value ? 'homeLocation'
            and jsonb_typeof(location_grant.value->'homeLocation')<>'boolean')
          or not (
            case when jsonb_typeof(location_grant.value->'standardAllowed')='boolean'
              then (location_grant.value->>'standardAllowed')::boolean else false end
            or case when jsonb_typeof(location_grant.value->'overtimeAllowed')='boolean'
              then (location_grant.value->>'overtimeAllowed')::boolean else false end
            or case when jsonb_typeof(location_grant.value->'homeLocation')='boolean'
              then (location_grant.value->>'homeLocation')::boolean else false end
          )
          or (
            case when jsonb_typeof(location_grant.value->'homeLocation')='boolean'
              then (location_grant.value->>'homeLocation')::boolean else false end
            and not case when jsonb_typeof(location_grant.value->'standardAllowed')='boolean'
              then (location_grant.value->>'standardAllowed')::boolean else false end
          )
      ) or (
        select count(*) from jsonb_array_elements(v_row->'locationGrants') location_grant
        where case when jsonb_typeof(location_grant.value->'homeLocation')='boolean'
          then (location_grant.value->>'homeLocation')::boolean else false end
      )>1 or (
        select count(*) from jsonb_array_elements(v_row->'locationGrants') location_grant
      )<>(
        select count(distinct upper(trim(location_grant.value->>'code')))
        from jsonb_array_elements(v_row->'locationGrants') location_grant
      ) then
        v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
          'sheet','PRACOWNICY','row',v_index+1,'code','INVALID_LOCATION_GRANTS',
          'message','Sprawdź zwykłe, nadgodzinowe i bazowe uprawnienia do lokali. Każdy lokal może wystąpić tylko raz.'
        ));
      end if;
    end if;
    if v_row ? 'dutyCodes' then
      if jsonb_typeof(v_row->'dutyCodes')<>'array' or exists(
        select 1 from jsonb_array_elements_text(v_row->'dutyCodes') duty_code
        where not exists(
          select 1 from public.matrix_duties_v2 duty
          where duty.matrix_version_id=v_matrix and duty.active
            and upper(duty.code)=upper(duty_code.value)
        )
      ) then
        v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
          'sheet','PRACOWNICY','row',v_index+1,'code','INVALID_DUTY_COLUMNS',
          'message','Co najmniej jedna kolumna obowiązku nie odpowiada aktywnemu obowiązkowi w Matrixie.'
        ));
      end if;
    end if;
    if nullif(v_row->>'employmentStart','') is not null
      and not pg_catalog.pg_input_is_valid(v_row->>'employmentStart','date') then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','INVALID_EMPLOYMENT_START',
        'message','Data rozpoczęcia zatrudnienia jest nieprawidłowa.'
      ));
    end if;
    if nullif(v_row->>'employmentEnd','') is not null
      and not pg_catalog.pg_input_is_valid(v_row->>'employmentEnd','date') then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','INVALID_EMPLOYMENT_END',
        'message','Data zakończenia zatrudnienia jest nieprawidłowa.'
      ));
    elsif nullif(v_row->>'employmentEnd','') is not null
      and nullif(v_row->>'employmentStart','') is null then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','EMPLOYMENT_START_REQUIRED',
        'message','Data zakończenia wymaga daty rozpoczęcia zatrudnienia.'
      ));
    elsif nullif(v_row->>'employmentStart','') is not null
      and pg_catalog.pg_input_is_valid(v_row->>'employmentStart','date')
      and nullif(v_row->>'employmentEnd','') is not null
      and pg_catalog.pg_input_is_valid(v_row->>'employmentEnd','date')
      and (v_row->>'employmentEnd')::date<(v_row->>'employmentStart')::date then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','INVALID_EMPLOYMENT_DATES',
        'message','Data zakończenia nie może poprzedzać rozpoczęcia zatrudnienia.'
      ));
    end if;
    v_employee:=null;
    if (nullif(v_row->>'employmentStart','') is null
        or pg_catalog.pg_input_is_valid(v_row->>'employmentStart','date'))
      and (nullif(v_row->>'employmentEnd','') is null
        or pg_catalog.pg_input_is_valid(v_row->>'employmentEnd','date')) then
      select profile.employee_id into v_employee
      from public.matrix_employee_profiles_v2 profile
      where profile.matrix_version_id=v_matrix
        and nullif(trim(v_row->>'employeeNo'),'') is not null
        and upper(profile.employee_no)=upper(trim(v_row->>'employeeNo'));
      if v_employee is not null and exists(
        select 1 from public.employee_pay_rates_v2 rate
        where rate.employee_id=v_employee and (
          (nullif(v_row->>'employmentStart','') is not null
            and rate.valid_from<(v_row->>'employmentStart')::date)
          or (nullif(v_row->>'employmentEnd','') is not null and (
            rate.valid_from>(v_row->>'employmentEnd')::date
            or rate.valid_to is null
            or rate.valid_to>(v_row->>'employmentEnd')::date
          ))
        )
      ) then
        v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
          'sheet','PRACOWNICY','row',v_index+1,
          'code','EMPLOYMENT_DATES_CONFLICT_PAY_RATES',
          'message','Okres zatrudnienia jest sprzeczny z zapisaną historią stawek tego pracownika.'
        ));
      end if;
    end if;
    if v_contract in ('UMOWA_O_PRACE','CZESC_ETATU') and (
      nullif(v_row->>'nominalHours','') is null
      or nullif(v_row->>'maximumMonthlyHours','') is null
      or nullif(v_row->>'maximumWeeklyHours','') is null
      or nullif(v_row->>'maximumConsecutiveDays','') is null
    ) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','EMPLOYMENT_LIMITS_REQUIRED',
        'message','Dla umowy o pracę podaj nominał, limit miesięczny, limit tygodniowy i maksymalną liczbę kolejnych dni.'
      ));
    end if;
    v_limits_invalid:=coalesce(v_row->>'nominalHours','') !~ '^\d+([.,]\d+)?$'
      or coalesce(v_row->>'maximumMonthlyHours','') !~ '^\d+([.,]\d+)?$'
      or coalesce(v_row->>'maximumWeeklyHours','') !~ '^\d+([.,]\d+)?$'
      or coalesce(v_row->>'maximumConsecutiveDays','') !~ '^\d+$'
      or coalesce(v_row->>'employmentFraction','') !~ '^\d+([.,]\d+)?$'
      or (nullif(v_row->>'minimumRestHours','') is not null
        and (v_row->>'minimumRestHours') !~ '^\d+([.,]\d+)?$');
    if not v_limits_invalid then
      v_limits_invalid:=replace(v_row->>'maximumMonthlyHours',',','.')::numeric
        <replace(v_row->>'nominalHours',',','.')::numeric
        or replace(v_row->>'nominalHours',',','.')::numeric>744
        or replace(v_row->>'maximumMonthlyHours',',','.')::numeric>744
        or replace(v_row->>'maximumWeeklyHours',',','.')::numeric>168
        or (v_row->>'maximumConsecutiveDays')::integer not between 1 and 31
        or replace(v_row->>'employmentFraction',',','.')::numeric not between .01 and 1
        or (nullif(v_row->>'minimumRestHours','') is not null
          and replace(v_row->>'minimumRestHours',',','.')::numeric>48);
    end if;
    if v_limits_invalid then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','INVALID_EMPLOYEE_LIMITS',
        'message','Sprawdź nominał i limity. Limit miesięczny nie może być niższy od nominału.'
      ));
    end if;
    if nullif(v_row->>'preferenceMonth','') is not null
      and not pg_catalog.pg_input_is_valid(v_row->>'preferenceMonth','date') then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','INVALID_PREFERENCE_MONTH',
        'message','Miesiąc preferencji ma nieprawidłową datę.'
      ));
    end if;
    if upper(coalesce(v_row->>'workTimePolicy','CONTRACT_DEFAULT'))
      not in ('CONTRACT_DEFAULT','CUSTOM') then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','INVALID_WORK_TIME_POLICY',
        'message','Polityka czasu pracy to CONTRACT_DEFAULT albo CUSTOM.'
      ));
    end if;
  end loop;
  v_preview:=jsonb_set(v_preview,'{errors}',v_errors,true);
  v_preview:=jsonb_set(v_preview,'{valid}',to_jsonb(jsonb_array_length(v_errors)=0),true);

  select count(*) into v_updates
  from jsonb_array_elements(coalesce(v_normalized->'employees','[]'::jsonb)) imported
  where exists(select 1 from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=v_matrix and (
      (nullif(trim(imported.value->>'employeeNo'),'') is not null
        and upper(profile.employee_no)=upper(trim(imported.value->>'employeeNo')))
      or (nullif(lower(trim(imported.value->>'email')),'') is not null
        and lower(profile.email)=lower(trim(imported.value->>'email')))
    ));
  v_creates:=jsonb_array_length(coalesce(v_normalized->'employees','[]'::jsonb))-v_updates;
  if v_mode='REPLACE' then
    select count(*),coalesce(jsonb_agg(jsonb_build_object(
      'employeeId',profile.employee_id,'employeeNo',profile.employee_no,
      'employeeName',profile.first_name||' '||profile.last_name,
      'email',coalesce(profile.email,employee.email),
      'reason',case when exists(
        select 1 from jsonb_array_elements(coalesce(v_normalized->'employees','[]'::jsonb)) imported
        where nullif(lower(trim(imported.value->>'email')),'') is not null
          and lower(trim(imported.value->>'email')) in (
            lower(coalesce(profile.email,'')),lower(coalesce(employee.email,''))
          )
      ) then 'DUPLICATE_IDENTITY' else 'NOT_IN_FILE' end
    ) order by profile.employee_no),'[]'::jsonb)
    into v_archives,v_archive_rows
    from public.matrix_employee_profiles_v2 profile
    join public.employees employee on employee.id=profile.employee_id
    where profile.matrix_version_id=v_matrix and profile.active
      and not exists(
        select 1 from jsonb_array_elements(coalesce(v_normalized->'employees','[]'::jsonb)) imported
        where nullif(trim(imported.value->>'employeeNo'),'') is not null
          and upper(profile.employee_no)=upper(trim(imported.value->>'employeeNo'))
      );
  end if;
  v_preview:=jsonb_set(v_preview,'{summary,employeesToUpdate}',to_jsonb(v_updates),true);
  v_preview:=jsonb_set(v_preview,'{summary,employeesToCreate}',to_jsonb(v_creates),true);
  v_preview:=jsonb_set(v_preview,'{summary,employeesToArchive}',to_jsonb(v_archives),true);
  return v_preview||jsonb_build_object(
    'mode',v_mode,'employeesToArchive',v_archive_rows
  );
end;
$$;

create or replace function public.matrix_v2_import_apply_uat_v3(
  p_payload jsonb,
  p_mode text default 'UPDATE'
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_mode text:=upper(trim(coalesce(p_mode,'UPDATE')));
  v_preview jsonb;
  v_normalized jsonb;
  v_result jsonb;
  v_matrix uuid;
  v_apply_payload jsonb;
  v_profile public.matrix_employee_profiles_v2%rowtype;
  v_row jsonb;
  v_employee uuid;
  v_existing_rate public.employee_pay_rates_v2%rowtype;
  v_rate_start date;
  v_rate_end date;
  v_employment_end date;
  v_next_rate_start date;
  v_rate_amount bigint;
  v_effective date;
  v_currency text;
  v_archived integer:=0;
  v_location uuid;
  v_location_grant jsonb;
  v_profile_active boolean;
  v_desired_active boolean;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  v_preview:=public.matrix_v2_import_preview_uat_v3(p_payload,v_mode);
  if not (v_preview->>'valid')::boolean then raise exception 'MATRIX_IMPORT_HAS_ERRORS'; end if;
  v_matrix:=(v_preview->>'matrixVersionId')::uuid;
  v_normalized:=solver_private.matrix_v2_import_normalize_uat_v3(p_payload,v_matrix);
  -- Rates are saved below with the later of the workbook month (when present),
  -- the Matrix effective date and the employee's start date.  The older
  -- importer used only the Matrix date and could create a rate before
  -- employment or in a technical draft month unrelated to the schedule.
  select coalesce(jsonb_agg(
    (source.value-'baseRate')||jsonb_build_object('baseRate','')
    order by source.ordinality
  ),'[]'::jsonb) into v_apply_payload
  from jsonb_array_elements(coalesce(v_normalized->'employees','[]'::jsonb))
    with ordinality source(value,ordinality);
  v_apply_payload:=jsonb_set(v_normalized,'{employees}',v_apply_payload,true);
  v_result:=public.matrix_v2_import_apply_uat_v2(v_apply_payload);
  select matrix.effective_from,upper(matrix.settings->>'currency')
  into v_effective,v_currency
  from public.matrix_versions matrix where matrix.id=v_matrix;

  -- The v2 importer predates the Apps Script columns that distinguish normal
  -- and overtime location access and therefore deliberately cannot persist
  -- them.  Apply those explicit grants, employee shift limits and active state
  -- only when the workbook actually contains the corresponding fields.
  for v_row in select value from jsonb_array_elements(
    coalesce(v_normalized->'employees','[]'::jsonb)
  ) loop
    select profile.employee_id,profile.active into v_employee,v_profile_active
    from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=v_matrix
      and upper(profile.employee_no)=upper(v_row->>'employeeNo');
    if v_employee is null then raise exception 'IMPORTED_EMPLOYEE_NOT_FOUND'; end if;

    if v_row ? 'onlyMorning' or v_row ? 'onlyEvening' or v_row ? 'noWeekends' then
      update public.matrix_employee_profiles_v2 profile set
        only_morning=case when v_row ? 'onlyMorning'
          then (v_row->>'onlyMorning')::boolean else profile.only_morning end,
        only_evening=case when v_row ? 'onlyEvening'
          then (v_row->>'onlyEvening')::boolean else profile.only_evening end,
        no_weekends=case when v_row ? 'noWeekends'
          then (v_row->>'noWeekends')::boolean else profile.no_weekends end,
        updated_by=auth.uid(),updated_at=now()
      where profile.matrix_version_id=v_matrix and profile.employee_id=v_employee;
    end if;

    if v_row ? 'locationGrants' then
      update public.matrix_employee_locations_v2 location_grant set
        standard_allowed=false,overtime_allowed=false,home_location=false,active=false
      where location_grant.matrix_version_id=v_matrix
        and location_grant.employee_id=v_employee;
      for v_location_grant in select value from jsonb_array_elements(v_row->'locationGrants')
      loop
        select location_row.id into v_location
        from public.matrix_locations_v2 location_row
        where location_row.matrix_version_id=v_matrix and location_row.active
          and upper(location_row.code)=upper(v_location_grant->>'code');
        if v_location is null then raise exception 'LOCATION_NOT_IN_MATRIX_V2'; end if;
        insert into public.matrix_employee_locations_v2(
          matrix_version_id,employee_id,location_id,standard_allowed,
          overtime_allowed,home_location,active
        ) values(
          v_matrix,v_employee,v_location,
          coalesce((v_location_grant->>'standardAllowed')::boolean,false),
          coalesce((v_location_grant->>'overtimeAllowed')::boolean,false),
          coalesce((v_location_grant->>'homeLocation')::boolean,false),true
        ) on conflict(matrix_version_id,employee_id,location_id) do update set
          standard_allowed=excluded.standard_allowed,
          overtime_allowed=excluded.overtime_allowed,
          home_location=excluded.home_location,active=true;
      end loop;
    end if;

    -- When the workbook carries a duty dictionary, its employee columns are a
    -- complete statement for those duties: TAK activates the capability and a
    -- blank/NIE cell withdraws it.  Without this step an unchecked Excel cell
    -- could never remove an obsolete capability.
    if v_row ? 'dutyCodes' and jsonb_typeof(v_row->'dutyCodes')='array' then
      update public.matrix_employee_duties_v2 capability set
        active=false,updated_at=now()
      from public.matrix_duties_v2 duty
      where capability.matrix_version_id=v_matrix
        and capability.employee_id=v_employee
        and capability.duty_id=duty.id
        and duty.matrix_version_id=v_matrix
        and upper(duty.code) in (
          select upper(code.value)
          from jsonb_array_elements_text(v_row->'dutyCodes') code
        )
        and not exists(
          select 1
          from jsonb_array_elements(coalesce(v_normalized->'employeeDuties','[]'::jsonb)) imported
          where upper(coalesce(imported.value->>'employeeNo',''))=upper(v_row->>'employeeNo')
            and upper(coalesce(imported.value->>'dutyCode',''))=upper(duty.code)
            and coalesce((imported.value->>'active')::boolean,true)
        );
    end if;

    if v_row ? 'active' then
      v_desired_active:=(v_row->>'active')::boolean;
      if v_desired_active is distinct from v_profile_active then
        perform public.matrix_v2_employee_archive_v2(
          v_employee,
          case when v_desired_active then null
            else 'Archiwizacja zgodna z polem AKTYWNY w imporcie Matrixa.' end,
          not v_desired_active
        );
      end if;
    end if;
  end loop;

  for v_row in select value from jsonb_array_elements(
    coalesce(v_normalized->'employees','[]'::jsonb)
  ) where nullif(value->>'baseRate','') is not null
  loop
    select profile.employee_id,greatest(
      coalesce(nullif(v_row->>'preferenceMonth','')::date,v_effective),
      coalesce(profile.employment_start,
        coalesce(nullif(v_row->>'preferenceMonth','')::date,v_effective))
    ),profile.employment_end into v_employee,v_rate_start,v_employment_end
    from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=v_matrix
      and upper(profile.employee_no)=upper(v_row->>'employeeNo');
    if v_employee is null then raise exception 'IMPORTED_EMPLOYEE_NOT_FOUND'; end if;
    select min(rate.valid_from) into v_next_rate_start
    from public.employee_pay_rates_v2 rate
    where rate.employee_id=v_employee and rate.active
      and rate.valid_from>v_rate_start;
    v_rate_end:=case
      when v_next_rate_start is null then v_employment_end
      when v_employment_end is null then v_next_rate_start-1
      else least(v_employment_end,v_next_rate_start-1)
    end;
    select * into v_existing_rate
    from public.employee_pay_rates_v2 rate
    where rate.employee_id=v_employee and rate.active
      and rate.valid_from<=v_rate_start
      and (rate.valid_to is null or rate.valid_to>=v_rate_start)
    order by rate.valid_from desc,rate.id limit 1;
    v_rate_amount:=round(replace(v_row->>'baseRate',',','.')::numeric*100)::bigint;
    -- Re-importing an unchanged workbook is idempotent.  Do not split a rate
    -- period merely because the same amount and contract were supplied again.
    if v_existing_rate.id is not null
      and v_existing_rate.base_rate_minor=v_rate_amount
      and upper(coalesce(v_existing_rate.currency,''))=upper(coalesce(v_currency,''))
      and upper(coalesce(v_existing_rate.contract_type,''))=
        upper(coalesce(nullif(v_row->>'contractType',''),'')) then
      continue;
    end if;
    if v_existing_rate.id is not null and v_existing_rate.valid_from<v_rate_start then
      perform public.employee_pay_rate_save_v2(
        v_existing_rate.id,v_employee,v_existing_rate.valid_from,v_rate_start-1,
        v_existing_rate.base_rate_minor,v_existing_rate.currency,
        v_existing_rate.contract_type,v_existing_rate.active
      );
      v_existing_rate.id:=null;
    end if;
    perform public.employee_pay_rate_save_v2(
      v_existing_rate.id,v_employee,v_rate_start,v_rate_end,v_rate_amount,
      v_currency,nullif(v_row->>'contractType',''),true
    );
  end loop;

  if v_mode='REPLACE' then
    for v_profile in
      select profile.* from public.matrix_employee_profiles_v2 profile
      where profile.matrix_version_id=v_matrix and profile.active
        and not exists(
          select 1 from jsonb_array_elements(coalesce(v_normalized->'employees','[]'::jsonb)) imported
          where nullif(trim(imported.value->>'employeeNo'),'') is not null
            and upper(profile.employee_no)=upper(trim(imported.value->>'employeeNo'))
        )
      for update
    loop
      perform public.matrix_v2_employee_archive_v2(
        v_profile.employee_id,
        'Archiwizacja automatyczna: pracownik nie wystąpił w imporcie zastępującym bazę.',
        true
      );
      v_archived:=v_archived+1;
    end loop;
  end if;
  return v_result||jsonb_build_object('mode',v_mode,'archivedEmployees',v_archived);
end;
$$;

revoke all on function public.matrix_v2_import_preview_uat_v3(jsonb,text),
  public.matrix_v2_import_apply_uat_v3(jsonb,text)
  from public,anon,authenticated;
grant execute on function public.matrix_v2_import_preview_uat_v3(jsonb,text),
  public.matrix_v2_import_apply_uat_v3(jsonb,text)
  to authenticated;

comment on function public.matrix_v2_import_apply_uat_v3(jsonb,text) is
  'UPDATE upserts only workbook rows. REPLACE additionally archives draft employees absent from the workbook, preserving version and audit history.';

-- One business staffing requirement often applies to many shifts (for example,
-- every evening shift at a location).  Saving those rows one by one made the UI
-- error-prone and could leave a half-applied batch.  This RPC deliberately wraps
-- the existing, audited single-row command in one database transaction.
create or replace function public.matrix_v2_staffing_rules_bulk_save_uat_v2(
  p_scenario_id uuid,
  p_shift_template_ids uuid[],
  p_role_id uuid,
  p_duty_id uuid,
  p_operation text,
  p_count_value integer,
  p_multiplier_basis_points integer,
  p_active boolean
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_matrix uuid;
  v_shifts uuid[];
  v_shift uuid;
  v_operation text:=upper(trim(coalesce(p_operation,'')));
  v_saved integer:=0;
  v_target_scenario uuid;
  v_target_role uuid;
  v_target_duty uuid;
  v_target_shift uuid;
  v_existing uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;

  select coalesce(array_agg(distinct shift_id),array[]::uuid[])
  into v_shifts
  from unnest(coalesce(p_shift_template_ids,array[]::uuid[])) shift_id;
  if cardinality(v_shifts)<1 then raise exception 'SHIFT_SELECTION_REQUIRED'; end if;
  if cardinality(v_shifts)>100 then raise exception 'TOO_MANY_SHIFTS_SELECTED'; end if;
  if p_scenario_id is null then raise exception 'SCENARIO_REQUIRED'; end if;
  if p_role_id is null then raise exception 'ROLE_REQUIRED'; end if;
  if v_operation not in ('SET','ADD','MULTIPLY','REMOVE') then
    raise exception 'INVALID_STAFFING_OPERATION';
  end if;
  if v_operation in ('SET','ADD') and p_count_value is null then
    raise exception 'STAFFING_COUNT_REQUIRED';
  end if;
  if v_operation in ('SET','ADD') and p_count_value<0 then
    raise exception 'STAFFING_COUNT_NEGATIVE';
  end if;
  if v_operation='MULTIPLY' and coalesce(p_multiplier_basis_points,-1)<0 then
    raise exception 'INVALID_STAFFING_MULTIPLIER';
  end if;

  v_matrix:=public.matrix_v2_create_draft(null);

  -- Validate every reference up front.  The following FOREACH loop therefore
  -- cannot partially apply a batch before discovering a bad final selection.
  select target.id into v_target_scenario
    from public.matrix_scenarios_v2 source
    join public.matrix_scenarios_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=p_scenario_id and target.active;
  if v_target_scenario is null then raise exception 'SCENARIO_NOT_IN_MATRIX_V2'; end if;
  select target.id into v_target_role
    from public.matrix_roles_v2 source
    join public.matrix_roles_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=p_role_id and target.active;
  if v_target_role is null then raise exception 'ROLE_NOT_IN_MATRIX_V2'; end if;
  if p_duty_id is not null then
    select target.id into v_target_duty
      from public.matrix_duties_v2 source
      join public.matrix_duties_v2 target
        on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
      where source.id=p_duty_id and target.active;
    if v_target_duty is null then raise exception 'DUTY_NOT_IN_MATRIX_V2'; end if;
  end if;
  if (
    select count(distinct selected.shift_id)
    from unnest(v_shifts) selected(shift_id)
    join public.matrix_shift_templates_v2 source on source.id=selected.shift_id
    join public.matrix_shift_templates_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where target.active
  )<>cardinality(v_shifts) then
    raise exception 'SHIFT_NOT_IN_MATRIX_V2';
  end if;

  foreach v_shift in array v_shifts loop
    select target.id into v_target_shift
    from public.matrix_shift_templates_v2 source
    join public.matrix_shift_templates_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=v_shift and target.active;
    if v_target_shift is null then raise exception 'SHIFT_NOT_IN_MATRIX_V2'; end if;
    select rule.id into v_existing
    from public.matrix_staffing_rules_v2 rule
    where rule.matrix_version_id=v_matrix
      and rule.scenario_id=v_target_scenario
      and rule.shift_template_id=v_target_shift
      and rule.role_id=v_target_role
      and rule.duty_id is not distinct from v_target_duty;
    perform public.matrix_v2_admin_save_alpha16(
      'STAFFING_RULE',v_existing,
      jsonb_build_object(
        'scenarioId',v_target_scenario,
        'shiftTemplateId',v_target_shift,
        'roleId',v_target_role,
        'dutyId',v_target_duty,
        'operation',v_operation,
        'countValue',case when v_operation in ('SET','ADD') then p_count_value else null end,
        'multiplierBasisPoints',case when v_operation='MULTIPLY' then p_multiplier_basis_points else null end,
        'active',coalesce(p_active,true),
        'sourceMetadata',jsonb_build_object(
          'source','MATRIX_BULK_UI','batchSize',cardinality(v_shifts)
        )
      )
    );
    v_saved:=v_saved+1;
  end loop;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_version',v_matrix::text,'BULK_SAVE_STAFFING',
    jsonb_build_object(
      'scenarioId',v_target_scenario,'roleId',v_target_role,
      'dutyId',v_target_duty,
      'operation',v_operation,'shiftTemplateIds',to_jsonb(v_shifts),'saved',v_saved
    ));
  return jsonb_build_object('matrixVersionId',v_matrix,'saved',v_saved);
end;
$$;

revoke all on function public.matrix_v2_staffing_rules_bulk_save_uat_v2(
  uuid,uuid[],uuid,uuid,text,integer,integer,boolean
) from public,anon,authenticated;
grant execute on function public.matrix_v2_staffing_rules_bulk_save_uat_v2(
  uuid,uuid[],uuid,uuid,text,integer,integer,boolean
) to authenticated;

comment on function public.matrix_v2_staffing_rules_bulk_save_uat_v2(
  uuid,uuid[],uuid,uuid,text,integer,integer,boolean
) is 'Atomically creates or replaces one staffing requirement across multiple selected shifts.';

-- Read model for the missing Matrix revision history UI.  The RPC is owner
-- protected because audit payloads may describe HR or finance configuration.
create or replace function public.matrix_v2_revision_history_uat_v2(
  p_limit integer default 250
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_limit integer:=least(greatest(coalesce(p_limit,250),1),1000);
  v_versions jsonb;
  v_audit jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',version.id,'version',version.version,'name',version.name,
    'status',version.status,'effectiveFrom',version.effective_from,
    'effectiveTo',version.effective_to,'createdAt',version.created_at,
    'activatedAt',version.activated_at,'publishedAt',version.published_at,
    'baseVersionId',version.base_version_id,'contentHash',version.content_hash,
    'workforceHash',version.workforce_hash,
    'createdBy',coalesce(nullif(trim(coalesce(creator.raw_user_meta_data->>'full_name','')),''),creator.email,'System'),
    'publishedBy',coalesce(nullif(trim(coalesce(publisher.raw_user_meta_data->>'full_name','')),''),publisher.email),
    'counts',jsonb_build_object(
      'employees',(select count(*) from public.matrix_employee_profiles_v2 row_value where row_value.matrix_version_id=version.id and row_value.active),
      'roles',(select count(*) from public.matrix_roles_v2 row_value where row_value.matrix_version_id=version.id and row_value.active),
      'locations',(select count(*) from public.matrix_locations_v2 row_value where row_value.matrix_version_id=version.id and row_value.active),
      'duties',(select count(*) from public.matrix_duties_v2 row_value where row_value.matrix_version_id=version.id and row_value.active),
      'shifts',(select count(*) from public.matrix_shift_templates_v2 row_value where row_value.matrix_version_id=version.id and row_value.active),
      'staffingRules',(select count(*) from public.matrix_staffing_rules_v2 row_value where row_value.matrix_version_id=version.id and row_value.active),
      'scenarios',(select count(*) from public.matrix_scenarios_v2 row_value where row_value.matrix_version_id=version.id and row_value.active),
      'strategies',(select count(*) from public.matrix_strategies_v2 row_value where row_value.matrix_version_id=version.id and row_value.active)
    )
  ) order by version.version desc),'[]'::jsonb)
  into v_versions
  from public.matrix_versions version
  left join auth.users creator on creator.id=version.created_by
  left join auth.users publisher on publisher.id=version.published_by
  where version.schema_version>=2;

  with recent as (
    select log.*,
      coalesce(
        log.new_data->>'matrixVersionId',log.new_data->>'matrix_version_id',
        log.old_data->>'matrixVersionId',log.old_data->>'matrix_version_id',
        case when log.entity_type in ('matrix_v2','matrix_version') then log.entity_id end
      ) matrix_version_id,
      case
        when log.entity_type like '%employee%' then 'Pracownicy i umowy'
        when log.entity_type like '%staffing%' then 'Wymagana obsada'
        when log.entity_type like '%strategy%' or log.entity_type like '%scenario%' then 'Scenariusze i warianty'
        when log.entity_type like '%pay%' or log.entity_type like '%budget%' then 'Finanse'
        when log.entity_type like '%role%' or log.entity_type like '%location%'
          or log.entity_type like '%duty%' or log.entity_type like '%shift%' then 'Role, lokale i zmiany'
        when log.action like '%IMPORT%' or log.entity_type like '%import%' then 'Import Excel'
        when log.action='PUBLISH' then 'Publikacja'
        else 'Ustawienia Matrixa'
      end section
    from public.audit_log log
    where log.entity_type like 'matrix_v2%'
      or log.entity_type='matrix_version'
      or log.entity_type='employee_pay_rate_v2'
    order by log.created_at desc,log.id desc
    limit v_limit
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',recent.id,'createdAt',recent.created_at,
    'actorId',recent.actor_id,
    'actor',coalesce(nullif(trim(coalesce(actor.raw_user_meta_data->>'full_name','')),''),actor.email,'System'),
    'matrixVersionId',recent.matrix_version_id,'section',recent.section,
    'entityType',recent.entity_type,'entityId',recent.entity_id,
    'action',recent.action,'oldData',recent.old_data,'newData',recent.new_data
  ) order by recent.created_at desc,recent.id desc),'[]'::jsonb)
  into v_audit
  from recent
  left join auth.users actor on actor.id=recent.actor_id;

  return jsonb_build_object('versions',v_versions,'audit',v_audit);
end;
$$;

create or replace function public.matrix_v2_compare_versions_uat_v2(
  p_left_version_id uuid,
  p_right_version_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_left jsonb;
  v_right jsonb;
  v_sections jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if p_left_version_id is null or p_right_version_id is null
    or p_left_version_id=p_right_version_id then
    raise exception 'TWO_DIFFERENT_MATRIX_VERSIONS_REQUIRED';
  end if;
  v_left:=public.matrix_v2_content_document(p_left_version_id);
  v_right:=public.matrix_v2_content_document(p_right_version_id);
  if v_left is null or v_right is null then raise exception 'MATRIX_V2_NOT_FOUND'; end if;
  v_left:=v_left||jsonb_build_object('employeeProfiles',coalesce((
    select jsonb_agg(to_jsonb(profile)-array[
      'id','matrix_version_id','created_at','updated_at','created_by','updated_by'
    ] order by profile.employee_no)
    from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=p_left_version_id
  ),'[]'::jsonb));
  v_right:=v_right||jsonb_build_object('employeeProfiles',coalesce((
    select jsonb_agg(to_jsonb(profile)-array[
      'id','matrix_version_id','created_at','updated_at','created_by','updated_by'
    ] order by profile.employee_no)
    from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=p_right_version_id
  ),'[]'::jsonb));

  select jsonb_agg(jsonb_build_object(
    'key',section.key,'label',section.label,
    'leftCount',jsonb_array_length(coalesce(v_left->section.key,'[]'::jsonb)),
    'rightCount',jsonb_array_length(coalesce(v_right->section.key,'[]'::jsonb)),
    'changed',(v_left->section.key) is distinct from (v_right->section.key)
  ) order by section.ordinal)
  into v_sections
  from (values
    (1,'roles','Role'),(2,'locations','Lokale'),(3,'duties','Obowiązki'),
    (4,'shifts','Zmiany'),(5,'roleDuties','Powiązania ról i obowiązków'),
    (6,'staffingRules','Wymagana obsada'),(7,'scenarios','Scenariusze'),
    (8,'strategies','Warianty biznesowe'),(9,'objectives','Priorytety wariantów'),
    (10,'employeeProfiles','Profile i limity pracowników'),
    (11,'employeeRoles','Role pracowników'),(12,'employeeLocations','Lokale pracowników'),
    (13,'employeeDuties','Kompetencje pracowników'),(14,'payRules','Reguły płacowe'),
    (15,'scenarioBudgets','Budżety')
  ) section(ordinal,key,label);
  return jsonb_build_object(
    'leftVersionId',p_left_version_id,'rightVersionId',p_right_version_id,
    'settingsChanged',(v_left->'settings') is distinct from (v_right->'settings'),
    'sections',v_sections
  );
end;
$$;

revoke all on function public.matrix_v2_revision_history_uat_v2(integer),
  public.matrix_v2_compare_versions_uat_v2(uuid,uuid)
  from public,anon,authenticated;
grant execute on function public.matrix_v2_revision_history_uat_v2(integer),
  public.matrix_v2_compare_versions_uat_v2(uuid,uuid)
  to authenticated;

-- Finalization used to raise a generic HTTP 400 after all variants had been
-- saved.  The worker then marked the whole run failed and the useful evidence
-- disappeared from the UI.  Reconcile strategy state from persisted variants,
-- make a successful retry idempotent, and persist a precise terminal reason
-- instead of throwing for expected final validation outcomes.
create or replace function public.solver_finalize_v2(
  p_run_id uuid,p_attempt_id uuid,p_lease_token uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run public.optimization_runs_v2%rowtype;
  v_stored jsonb;
  v_current jsonb;
  v_current_hash text;
  v_expected integer;
  v_ready integer;
  v_require_optimal boolean;
  v_message text;
begin
  perform solver_private.lock_planning_revision_v2();
  select * into v_run from public.optimization_runs_v2 where id=p_run_id for update;
  if v_run.id is null then raise exception 'RUN_NOT_FOUND'; end if;

  -- A lost HTTP response may cause the same worker to retry finalization after
  -- the first transaction already committed and released its lease.
  if v_run.status='READY' then
    return jsonb_build_object('status','READY','runId',p_run_id,'reused',true,
      'variantCount',(select count(*) from public.plan_variants_v2 where run_id=p_run_id));
  end if;
  if not solver_private.lease_is_live_v2(p_run_id,p_attempt_id,p_lease_token) then
    raise exception 'LEASE_LOST';
  end if;

  if v_run.status='CANCEL_REQUESTED' then
    delete from public.plan_variants_v2 where run_id=p_run_id;
    update public.optimization_runs_v2 set status='CANCELLED',phase='CANCELLED',
      finished_at=now(),updated_at=now(),lease_owner=null,lease_token=null,lease_expires_at=null
    where id=p_run_id;
    update solver_private.optimization_attempts_v2 set status='INTERRUPTED',
      finished_at=now(),error_code='CANCEL_REQUESTED' where id=p_attempt_id;
    return jsonb_build_object('status','CANCELLED');
  end if;

  update public.optimization_runs_v2 set status='VALIDATING',phase='DATABASE_VALIDATION',
    progress=99,updated_at=now() where id=p_run_id;
  select snapshot into v_stored
  from solver_private.optimization_snapshots_v2 where run_id=p_run_id;
  if v_stored is null then raise exception 'SNAPSHOT_NOT_FOUND'; end if;
  v_current:=solver_private.build_snapshot_payload_v2(
    p_run_id,v_run.month,v_run.matrix_version_id,v_run.scenario_id,
    v_run.scope_type,v_run.scope_role_id
  );
  v_current_hash:=encode(extensions.digest(convert_to(
    solver_private.canonical_json_v2(v_current),'UTF8'
  ),'sha256'),'hex');
  if v_current_hash<>v_run.snapshot_hash then
    update public.plan_variants_v2 set status='ARCHIVED' where run_id=p_run_id;
    update public.optimization_run_strategies_v2 set status='STALE_INPUT',
      phase='STALE_INPUT',updated_at=now() where run_id=p_run_id;
    update public.optimization_runs_v2 set status='STALE_INPUT',phase='STALE_INPUT',
      failure_code='SNAPSHOT_CHANGED',
      failure_message='Dane Matrixa lub pracowników zmieniły się podczas optymalizacji.',
      finished_at=now(),updated_at=now(),lease_owner=null,lease_token=null,lease_expires_at=null
    where id=p_run_id;
    update solver_private.optimization_attempts_v2 set status='FAILED',finished_at=now(),
      error_code='SNAPSHOT_CHANGED' where id=p_attempt_id;
    return jsonb_build_object('status','STALE_INPUT','errorCode','SNAPSHOT_CHANGED',
      'currentSnapshotHash',v_current_hash);
  end if;

  -- The persisted variant is authoritative evidence that this strategy reached
  -- SAVED.  This repairs an interrupted status update without rerunning OR-Tools.
  update public.optimization_run_strategies_v2 strategy set
    status='READY',phase='SAVED',progress=100,
    started_at=coalesce(strategy.started_at,now()),
    finished_at=coalesce(strategy.finished_at,now()),updated_at=now()
  where strategy.run_id=p_run_id and exists(
    select 1 from public.plan_variants_v2 variant
    where variant.run_strategy_id=strategy.id and variant.hard_violations=0
      and variant.status='READY'
  );

  select count(*) into v_expected from public.optimization_run_strategies_v2
  where run_id=p_run_id;
  select count(distinct strategy.id) into v_ready
  from public.optimization_run_strategies_v2 strategy
  join public.plan_variants_v2 variant on variant.run_strategy_id=strategy.id
  where strategy.run_id=p_run_id and strategy.status='READY'
    and variant.status='READY' and variant.hard_violations=0;
  if v_expected=0 or v_ready<>v_expected then
    v_message:=format('Końcowa kontrola zapisała %s z %s wymaganych wariantów.',v_ready,v_expected);
    update public.optimization_run_strategies_v2 strategy set
      status='FAILED',phase='FAILED',failure_code='RUN_VARIANT_MISSING',
      finished_at=now(),updated_at=now()
    where strategy.run_id=p_run_id and not exists(
      select 1 from public.plan_variants_v2 variant
      where variant.run_strategy_id=strategy.id and variant.status='READY'
        and variant.hard_violations=0
    );
    update public.optimization_runs_v2 set status='FAILED',phase='FAILED',
      failure_code='RUN_VARIANTS_INCOMPLETE',failure_message=v_message,
      finished_at=now(),updated_at=now(),lease_owner=null,lease_token=null,lease_expires_at=null
    where id=p_run_id;
    update solver_private.optimization_attempts_v2 set status='FAILED',finished_at=now(),
      error_code='RUN_VARIANTS_INCOMPLETE',error_message=v_message where id=p_attempt_id;
    insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
    values(v_run.requested_by,'optimization_run_v2',p_run_id::text,'FINALIZE_FAILED',
      jsonb_build_object('errorCode','RUN_VARIANTS_INCOMPLETE','ready',v_ready,'expected',v_expected));
    return jsonb_build_object('status','FAILED','errorCode','RUN_VARIANTS_INCOMPLETE',
      'readyVariantCount',v_ready,'expectedVariantCount',v_expected);
  end if;

  v_require_optimal:=coalesce((v_stored->'settings'->>'requireOptimal')::boolean,true);
  if v_require_optimal and exists(
    select 1 from public.plan_variants_v2
    where run_id=p_run_id and status='READY' and solver_status<>'OPTIMAL'
  ) then
    v_message:='Matrix wymaga dowodu matematycznego optimum, a co najmniej jeden zapisany wariant jest tylko poprawnym rozwiązaniem.';
    update public.optimization_runs_v2 set status='FAILED',phase='FAILED',
      failure_code='RUN_REQUIRES_OPTIMAL_VARIANTS',failure_message=v_message,
      finished_at=now(),updated_at=now(),lease_owner=null,lease_token=null,lease_expires_at=null
    where id=p_run_id;
    update solver_private.optimization_attempts_v2 set status='FAILED',finished_at=now(),
      error_code='RUN_REQUIRES_OPTIMAL_VARIANTS',error_message=v_message where id=p_attempt_id;
    return jsonb_build_object('status','FAILED','errorCode','RUN_REQUIRES_OPTIMAL_VARIANTS');
  end if;

  update public.plan_variants_v2 set recommended=false where run_id=p_run_id;
  update public.plan_variants_v2 variant set recommended=true
  where variant.id=(
    select candidate.id from public.plan_variants_v2 candidate
    join public.optimization_run_strategies_v2 strategy on strategy.id=candidate.run_strategy_id
    where candidate.run_id=p_run_id and candidate.status='READY'
    order by strategy.ordinal limit 1
  );
  update public.optimization_runs_v2 set status='READY',phase='READY',progress=100,
    failure_code=null,failure_message=null,finished_at=now(),updated_at=now(),heartbeat_at=now(),
    lease_owner=null,lease_token=null,lease_expires_at=null
  where id=p_run_id;
  update solver_private.optimization_attempts_v2 set status='SUCCEEDED',
    heartbeat_at=now(),finished_at=now(),error_code=null,error_message=null
  where id=p_attempt_id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_run.requested_by,'optimization_run_v2',p_run_id::text,'READY',
    jsonb_build_object('variantCount',v_ready,'snapshotHash',v_run.snapshot_hash));
  return jsonb_build_object('status','READY','runId',p_run_id,'variantCount',v_ready);
end;
$$;

revoke all on function public.solver_finalize_v2(uuid,uuid,uuid)
  from public,anon,authenticated;
grant execute on function public.solver_finalize_v2(uuid,uuid,uuid) to service_role;
