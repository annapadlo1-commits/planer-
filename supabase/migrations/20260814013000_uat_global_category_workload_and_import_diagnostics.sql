-- UAT only. Category generation must expose every role in that category in
-- workload analysis. The previous RPC treated the category anchor as a single
-- role, so BARBACK/HOST/RUNNER and equivalent roles in every other category
-- disappeared from search and statistics.
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

  if v_run.scope_type='ROLE' and v_run.scope_role_id is not null then
    select role.category_id into v_scope_category
    from public.matrix_roles_v2 role
    where role.id=v_run.scope_role_id
      and role.matrix_version_id=v_run.matrix_version_id;
  end if;

  with roster as (
    select profile.employee_id,profile.employee_no,profile.first_name,profile.last_name,
      profile.nominal_monthly_minutes,profile.maximum_monthly_minutes,
      array_agg(distinct role.name order by role.name) role_names
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
      profile.nominal_monthly_minutes,profile.maximum_monthly_minutes
  ), assignment_stats as (
    select assignment.employee_id,
      count(distinct assignment.shift_id)::integer shift_count,
      coalesce(sum(extract(epoch from (shift_row.ends_at-shift_row.starts_at))/60),0)::integer planned_minutes
    from public.plan_assignments_v2 assignment
    join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
    where assignment.variant_id=p_variant_id
    group by assignment.employee_id
  ), availability as (
    select roster.employee_id,
      coalesce((select count(distinct unavailable_day.day)::integer
        from public.employee_time_constraints_v2 constraint_row
        cross join lateral generate_series(
          greatest(lower(constraint_row.time_range)::date,v_run.month),
          least((upper(constraint_row.time_range)-interval '1 second')::date,
            (v_run.month+interval '1 month'-interval '1 day')::date),interval '1 day'
        ) unavailable_day(day)
        where constraint_row.employee_id=roster.employee_id
          and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
          and constraint_row.time_range&&tstzrange(v_run.month::timestamp at time zone 'UTC',
            (v_run.month+interval '1 month')::timestamp at time zone 'UTC','[)')),0) hard_unavailable_days,
      coalesce((select count(distinct lower(constraint_row.time_range)::date)::integer
        from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=roster.employee_id
          and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind='AVAILABLE_WINDOW'
          and constraint_row.time_range&&tstzrange(v_run.month::timestamp at time zone 'UTC',
            (v_run.month+interval '1 month')::timestamp at time zone 'UTC','[)')),0) available_window_days
    from roster
  )
  select jsonb_build_object('variantId',p_variant_id,'employees',coalesce(jsonb_agg(
    jsonb_build_object(
      'employeeId',roster.employee_id,'employeeNo',roster.employee_no,
      'employeeName',roster.first_name||' '||roster.last_name,
      'roleNames',to_jsonb(roster.role_names),
      'plannedMinutes',coalesce(stats.planned_minutes,0),
      'shiftCount',coalesce(stats.shift_count,0),
      'nominalMonthlyMinutes',coalesce(roster.nominal_monthly_minutes,0),
      'maximumMonthlyMinutes',coalesce(roster.maximum_monthly_minutes,0),
      'differenceMinutes',coalesce(stats.planned_minutes,0)-coalesce(roster.nominal_monthly_minutes,0),
      'hardUnavailableDays',availability.hard_unavailable_days,
      'availableWindowDays',availability.available_window_days,
      'reasonCode',case
        when coalesce(roster.nominal_monthly_minutes,0)=0 then 'TARGET_NOT_SET'
        when coalesce(roster.maximum_monthly_minutes,0)>0
          and coalesce(stats.planned_minutes,0)>=roster.maximum_monthly_minutes then 'MAXIMUM_REACHED'
        when coalesce(stats.planned_minutes,0)<roster.nominal_monthly_minutes
          and availability.hard_unavailable_days>0 then 'AVAILABILITY_LIMITED'
        when coalesce(stats.planned_minutes,0)<roster.nominal_monthly_minutes
          and availability.available_window_days>0 then 'AVAILABILITY_WINDOW_LIMITED'
        when coalesce(stats.planned_minutes,0)<roster.nominal_monthly_minutes then 'SOLVER_DISTRIBUTION'
        when coalesce(stats.planned_minutes,0)>roster.nominal_monthly_minutes then 'ABOVE_NOMINAL'
        else 'ON_TARGET' end,
      'locations',coalesce((select jsonb_agg(jsonb_build_object(
          'id',location.id,'name',location.name,'minutes',location_assignment.minutes,
          'shiftCount',location_assignment.shift_count
        ) order by location.name)
        from (
          select shift_row.location_id,
            count(distinct assignment.shift_id)::integer shift_count,
            sum(extract(epoch from (shift_row.ends_at-shift_row.starts_at))/60)::integer minutes
          from public.plan_assignments_v2 assignment
          join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
          where assignment.variant_id=p_variant_id and assignment.employee_id=roster.employee_id
          group by shift_row.location_id
        ) location_assignment
        join public.matrix_locations_v2 location on location.id=location_assignment.location_id
      ),'[]'::jsonb)
    ) order by coalesce(stats.planned_minutes,0) desc,roster.last_name,roster.first_name
  ),'[]'::jsonb)) into v_result
  from roster
  left join assignment_stats stats on stats.employee_id=roster.employee_id
  join availability on availability.employee_id=roster.employee_id;
  return v_result;
end;
$$;

revoke all on function public.optimizer_variant_workload_distribution_uat_v1(uuid)
  from public,anon,authenticated;
grant execute on function public.optimizer_variant_workload_distribution_uat_v1(uuid)
  to authenticated;

-- Preserve exact server causes and give full first-run workbooks enough time.
-- Preview remains atomic: the existing core deliberately rolls its work back.
alter function public.matrix_v2_team_import_preview_uat_v1(jsonb,text)
  rename to matrix_v2_team_import_preview_uat_v1_core_20260814;
alter function public.matrix_v2_team_import_preview_uat_v1_core_20260814(jsonb,text)
  set statement_timeout to '180s';

create or replace function public.matrix_v2_team_import_preview_uat_v1(
  p_configuration jsonb,
  p_mode text default 'UPDATE'
) returns jsonb
language plpgsql
security definer
set search_path = ''
set statement_timeout = '180s'
as $$
begin
  return public.matrix_v2_team_import_preview_uat_v1_core_20260814(
    p_configuration,p_mode
  );
exception when others then
  if sqlerrm like 'MATRIX_%' or sqlerrm like 'INVALID_%'
    or sqlerrm like 'EMPLOYEE_%' or sqlerrm like 'IMPORTED_%'
    or sqlerrm like 'FULL_IMPORT_%' or sqlerrm like 'ROLE_%' then
    raise;
  end if;
  raise exception 'TEAM_IMPORT_PREVIEW_FAILED|%|%|%',
    gen_random_uuid(),sqlstate,sqlerrm;
end;
$$;

alter function public.matrix_v2_team_import_apply_uat_v1(jsonb,text)
  set statement_timeout to '180s';
revoke all on function public.matrix_v2_team_import_preview_uat_v1_core_20260814(jsonb,text)
  from public,anon,authenticated;
revoke all on function public.matrix_v2_team_import_preview_uat_v1(jsonb,text)
  from public,anon,authenticated;
grant execute on function public.matrix_v2_team_import_preview_uat_v1(jsonb,text)
  to authenticated;

notify pgrst,'reload schema';

