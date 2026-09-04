-- B4F-74: bind the Studio impact analysis to the exact leader revision and
-- calculate workload, overtime, preference penalties and individual cost from
-- the same frozen snapshot that was used by the solver.
create or replace function public.optimizer_variant_workload_distribution_uat_v1(
  p_variant_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_run public.optimization_runs_v2%rowtype;
  v_scope_category uuid;
  v_timezone text;
  v_snapshot jsonb;
  v_variant_revision integer;
  v_finance_visibility text;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;

  select run.* into v_run
  from public.plan_variants_v2 variant
  join public.optimization_runs_v2 run on run.id=variant.run_id
  where variant.id=p_variant_id;
  if v_run.id is null or not solver_private.can_access_run_v2(v_run.id) then
    raise exception 'VARIANT_NOT_FOUND';
  end if;

  select variant.revision into v_variant_revision
  from public.plan_variants_v2 variant where variant.id=p_variant_id;
  select snapshot.snapshot into v_snapshot
  from solver_private.optimization_snapshots_v2 snapshot
  where snapshot.run_id=v_run.id;
  if v_snapshot is null then raise exception 'SNAPSHOT_NOT_FOUND'; end if;

  select coalesce(nullif(version.settings->>'timezone',''),'Europe/Warsaw')
    into v_timezone
  from public.matrix_versions version
  where version.id=v_run.matrix_version_id;
  v_finance_visibility:=public.application_finance_visibility_current_uat_v1();

  if v_run.scope_type='ROLE' and v_run.scope_role_id is not null then
    select role.category_id into v_scope_category
    from public.matrix_roles_v2 role
    where role.id=v_run.scope_role_id
      and role.matrix_version_id=v_run.matrix_version_id;
  end if;

  with roster as (
    select profile.employee_id,profile.employee_no,profile.first_name,profile.last_name,
      profile.nominal_monthly_minutes,profile.maximum_monthly_minutes,
      array_agg(distinct role.name order by role.name) role_names,
      coalesce((select array_agg(distinct location_grant.location_id order by location_grant.location_id)
        from public.matrix_employee_locations_v2 location_grant
        where location_grant.matrix_version_id=profile.matrix_version_id
          and location_grant.employee_id=profile.employee_id
          and location_grant.active and location_grant.standard_allowed),'{}'::uuid[]) eligible_location_ids
    from public.matrix_employee_profiles_v2 profile
    join public.matrix_employee_roles_v2 employee_role
      on employee_role.matrix_version_id=profile.matrix_version_id
     and employee_role.employee_id=profile.employee_id and employee_role.active
     and (employee_role.valid_from is null or employee_role.valid_from<(v_run.month+interval '1 month')::date)
     and (employee_role.valid_to is null or employee_role.valid_to>=v_run.month)
    join public.matrix_roles_v2 role on role.id=employee_role.role_id
    where profile.matrix_version_id=v_run.matrix_version_id
      and profile.active and profile.archived_at is null
      and (profile.employment_start is null or profile.employment_start<(v_run.month+interval '1 month')::date)
      and (profile.employment_end is null or profile.employment_end>=v_run.month)
      and (
        v_run.scope_type<>'ROLE'
        or (v_scope_category is not null and role.category_id=v_scope_category)
        or (v_scope_category is null and employee_role.role_id=v_run.scope_role_id)
      )
    group by profile.employee_id,profile.employee_no,profile.first_name,profile.last_name,
      profile.nominal_monthly_minutes,profile.maximum_monthly_minutes,profile.matrix_version_id
  ), snapshot_employees as (
    select employee.value employee
    from jsonb_array_elements(coalesce(v_snapshot->'employees','[]'::jsonb)) employee
  ), snapshot_slots as (
    select slot.value slot
    from jsonb_array_elements(coalesce(v_snapshot->'slots','[]'::jsonb)) slot
  ), assignment_source as (
    select assignment.id,assignment.employee_id,assignment.role_id,shift_row.location_id,
      extract(epoch from (shift_row.ends_at-shift_row.starts_at))/60 planned_minutes,
      coalesce(cost.cost_minor,0) cost_minor,
      employee.employee,slot.slot,
      (slot.slot->>'date')::date slot_date,
      (extract(epoch from (((slot.slot->>'start')::timestamptz at time zone v_timezone)::time))/60)::integer slot_start_minute,
      (extract(epoch from (((slot.slot->>'end')::timestamptz at time zone v_timezone)::time))/60)::integer
        + case when ((slot.slot->>'end')::timestamptz at time zone v_timezone)::date
          > ((slot.slot->>'start')::timestamptz at time zone v_timezone)::date then 1440 else 0 end slot_end_minute
    from public.plan_assignments_v2 assignment
    join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
    join snapshot_employees employee on employee.employee->>'id'=assignment.employee_id::text
    join snapshot_slots slot on slot.slot->>'slotId'=assignment.slot_key
    left join lateral (
      select coalesce(sum(component.amount_minor),0)::bigint cost_minor
      from solver_private.plan_assignment_cost_components_v2 component
      where component.assignment_id=assignment.id
    ) cost on true
    where assignment.variant_id=p_variant_id
  ), assignment_detail as (
    select source.*,
      (
        case when jsonb_array_length(coalesce(source.employee->'preferredShiftTemplateIds','[]'::jsonb))>0
          and not (coalesce(source.employee->'preferredShiftTemplateIds','[]'::jsonb) ? (source.slot->>'shiftTemplateId')) then 1 else 0 end
        + case when coalesce(source.employee->'avoidedShiftTemplateIds','[]'::jsonb) ? (source.slot->>'shiftTemplateId') then 1 else 0 end
        + case when jsonb_array_length(coalesce(source.employee->'preferredLocationIds','[]'::jsonb))>0
          and not (coalesce(source.employee->'preferredLocationIds','[]'::jsonb) ? (source.slot->>'locationId')) then 1 else 0 end
        + case when coalesce(source.employee->'softDayOffDates','[]'::jsonb) ? (source.slot->>'date') then 1 else 0 end
        + case when exists(
            select 1 from jsonb_array_elements(coalesce(v_snapshot->'workPatterns','[]'::jsonb)) pattern
            where pattern.value->>'employeeId'=source.employee_id::text
              and upper(coalesce(pattern.value->>'enforcement',''))='PREFERENCE'
              and (pattern.value->>'validFrom')::date<=source.slot_date
              and (nullif(pattern.value->>'validTo','') is null or (pattern.value->>'validTo')::date>=source.slot_date)
          ) and not exists(
            select 1 from jsonb_array_elements(coalesce(v_snapshot->'workPatterns','[]'::jsonb)) pattern
            where pattern.value->>'employeeId'=source.employee_id::text
              and upper(coalesce(pattern.value->>'enforcement',''))='PREFERENCE'
              and (pattern.value->>'validFrom')::date<=source.slot_date
              and (nullif(pattern.value->>'validTo','') is null or (pattern.value->>'validTo')::date>=source.slot_date)
              and (pattern.value->>'weekday')::integer=extract(isodow from source.slot_date)::integer
              and (nullif(pattern.value->>'roleId','') is null or (pattern.value->>'roleId')::uuid=source.role_id)
              and (nullif(pattern.value->>'locationId','') is null or (pattern.value->>'locationId')::uuid=source.location_id)
              and (extract(epoch from (pattern.value->>'localStart')::time)/60)::integer<=source.slot_start_minute
              and source.slot_end_minute<=
                (extract(epoch from (pattern.value->>'localEnd')::time)/60)::integer
                + case when (pattern.value->>'localEnd')::time<=(pattern.value->>'localStart')::time then 1440 else 0 end
          ) then 1 else 0 end
      )::integer preference_violations
    from assignment_source source
  ), assignment_stats as (
    select detail.employee_id,count(distinct detail.id)::integer shift_count,
      coalesce(sum(detail.planned_minutes),0)::integer planned_minutes,
      coalesce(sum(detail.cost_minor),0)::bigint cost_minor,
      coalesce(sum(detail.preference_violations),0)::integer preference_violations
    from assignment_detail detail group by detail.employee_id
  ), external_stats as (
    select (external.value->>'employeeId')::uuid employee_id,
      coalesce(sum(extract(epoch from ((external.value->>'end')::timestamptz-(external.value->>'start')::timestamptz))/60),0)::integer external_minutes
    from jsonb_array_elements(coalesce(v_snapshot->'externalAssignments','[]'::jsonb)) external
    where (((external.value->>'start')::timestamptz at time zone v_timezone)::date
      between v_run.month and (v_run.month+interval '1 month'-interval '1 day')::date)
    group by (external.value->>'employeeId')::uuid
  ), availability as (
    select roster.employee_id,
      coalesce((select count(distinct unavailable_day.day)::integer
        from public.employee_time_constraints_v2 constraint_row
        cross join lateral generate_series(
          greatest((lower(constraint_row.time_range) at time zone v_timezone)::date,v_run.month),
          least(((upper(constraint_row.time_range)-interval '1 microsecond') at time zone v_timezone)::date,
            (v_run.month+interval '1 month'-interval '1 day')::date),interval '1 day'
        ) unavailable_day(day)
        where constraint_row.employee_id=roster.employee_id
          and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
          and constraint_row.time_range&&tstzrange(v_run.month::timestamp at time zone v_timezone,
            (v_run.month+interval '1 month')::timestamp at time zone v_timezone,'[)')),0) hard_unavailable_days,
      coalesce((select count(distinct (lower(constraint_row.time_range) at time zone v_timezone)::date)::integer
        from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=roster.employee_id
          and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind='AVAILABLE_WINDOW'
          and constraint_row.time_range&&tstzrange(v_run.month::timestamp at time zone v_timezone,
            (v_run.month+interval '1 month')::timestamp at time zone v_timezone,'[)')),0) available_window_days
    from roster
  )
  select jsonb_build_object('variantId',p_variant_id,'revision',coalesce(v_variant_revision,0),'employees',coalesce(jsonb_agg(
    jsonb_build_object(
      'employeeId',roster.employee_id,'employeeNo',roster.employee_no,
      'employeeName',roster.first_name||' '||roster.last_name,
      'roleNames',to_jsonb(roster.role_names),
      'eligibleLocationIds',to_jsonb(roster.eligible_location_ids),
      'plannedMinutes',coalesce(stats.planned_minutes,0),
      'externalMinutes',coalesce(external.external_minutes,0),
      'totalMonthlyMinutes',coalesce(stats.planned_minutes,0)+coalesce(external.external_minutes,0),
      'overtimeMinutes',case when roster.nominal_monthly_minutes is null then 0 else
        greatest(0,coalesce(stats.planned_minutes,0)+coalesce(external.external_minutes,0)-roster.nominal_monthly_minutes) end,
      'shiftCount',coalesce(stats.shift_count,0),
      'nominalMonthlyMinutes',coalesce(roster.nominal_monthly_minutes,0),
      'maximumMonthlyMinutes',coalesce(roster.maximum_monthly_minutes,0),
      'differenceMinutes',coalesce(stats.planned_minutes,0)+coalesce(external.external_minutes,0)-coalesce(roster.nominal_monthly_minutes,0),
      'hardUnavailableDays',availability.hard_unavailable_days,
      'availableWindowDays',availability.available_window_days,
      'preferenceViolations',coalesce(stats.preference_violations,0),
      'costMinor',case when v_finance_visibility='FULL' then coalesce(stats.cost_minor,0) else null end,
      'assignmentImpacts',coalesce((select jsonb_agg(jsonb_build_object(
          'roleId',detail.role_id,'locationId',detail.location_id,
          'plannedMinutes',detail.planned_minutes,
          'costMinor',case when v_finance_visibility='FULL' then detail.cost_minor else null end,
          'preferenceViolations',detail.preference_violations
        ) order by detail.id)
        from assignment_detail detail where detail.employee_id=roster.employee_id),'[]'::jsonb),
      'reasonCode',case
        when coalesce(roster.nominal_monthly_minutes,0)=0 then 'TARGET_NOT_SET'
        when coalesce(roster.maximum_monthly_minutes,0)>0
          and coalesce(stats.planned_minutes,0)+coalesce(external.external_minutes,0)>=roster.maximum_monthly_minutes then 'MAXIMUM_REACHED'
        when coalesce(stats.planned_minutes,0)+coalesce(external.external_minutes,0)<roster.nominal_monthly_minutes
          and availability.hard_unavailable_days>0 then 'AVAILABILITY_LIMITED'
        when coalesce(stats.planned_minutes,0)+coalesce(external.external_minutes,0)<roster.nominal_monthly_minutes
          and availability.available_window_days>0 then 'AVAILABILITY_WINDOW_LIMITED'
        when coalesce(stats.planned_minutes,0)+coalesce(external.external_minutes,0)<roster.nominal_monthly_minutes then 'SOLVER_DISTRIBUTION'
        when coalesce(stats.planned_minutes,0)+coalesce(external.external_minutes,0)>roster.nominal_monthly_minutes then 'ABOVE_NOMINAL'
        else 'ON_TARGET' end,
      'locations',coalesce((select jsonb_agg(jsonb_build_object(
          'id',location.id,'name',location.name,'minutes',location_assignment.minutes,
          'shiftCount',location_assignment.shift_count
        ) order by location.name)
        from (
          select shift_row.location_id,count(distinct assignment.id)::integer shift_count,
            sum(extract(epoch from (shift_row.ends_at-shift_row.starts_at))/60)::integer minutes
          from public.plan_assignments_v2 assignment
          join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
          where assignment.variant_id=p_variant_id and assignment.employee_id=roster.employee_id
          group by shift_row.location_id
        ) location_assignment
        join public.matrix_locations_v2 location on location.id=location_assignment.location_id
      ),'[]'::jsonb)
    ) order by coalesce(stats.planned_minutes,0)+coalesce(external.external_minutes,0) desc,roster.last_name,roster.first_name
  ),'[]'::jsonb)) into v_result
  from roster
  left join assignment_stats stats on stats.employee_id=roster.employee_id
  left join external_stats external on external.employee_id=roster.employee_id
  join availability on availability.employee_id=roster.employee_id;
  return v_result;
end;
$$;

revoke all on function public.optimizer_variant_workload_distribution_uat_v1(uuid)
  from public,anon,authenticated;
grant execute on function public.optimizer_variant_workload_distribution_uat_v1(uuid)
  to authenticated;

notify pgrst,'reload schema';
