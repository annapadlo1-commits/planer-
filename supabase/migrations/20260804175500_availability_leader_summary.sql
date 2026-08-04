-- Leader-facing daily availability aggregation. Employee users keep the same
-- calendar contract but do not receive other employees' availability details.

create or replace function public.workforce_calendar_context_uat_v3(p_month date)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_base jsonb; v_month date:=date_trunc('month',p_month)::date;
  v_matrix uuid; v_timezone text; v_summary jsonb:='[]'::jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  v_base:=public.workforce_calendar_context_uat_v2(v_month);
  if not public.can_manage_plans() then
    return v_base||jsonb_build_object('availabilitySummary','[]'::jsonb);
  end if;
  v_matrix:=nullif(v_base->>'matrixVersionId','')::uuid;
  select coalesce(nullif(version.settings->>'timezone',''),'Europe/Warsaw')
  into v_timezone from public.matrix_versions version where version.id=v_matrix;

  with days as (
    select generate_series(v_month,
      (v_month+interval '1 month - 1 day')::date,interval '1 day')::date work_date
  ), grants as (
    select grant_row.employee_id,grant_row.role_id,
      profile.first_name||' '||profile.last_name employee_name
    from public.matrix_employee_roles_v2 grant_row
    join public.matrix_employee_profiles_v2 profile
      on profile.matrix_version_id=grant_row.matrix_version_id
      and profile.employee_id=grant_row.employee_id
    where grant_row.matrix_version_id=v_matrix and grant_row.active
      and profile.active and profile.archived_at is null
  ), facts as (
    select distinct day.work_date,grant_row.role_id,grant_row.employee_id,
      grant_row.employee_name,'HARD'::text fact_kind
    from days day join grants grant_row on true
    join public.employee_time_constraints_v2 constraint_row
      on constraint_row.employee_id=grant_row.employee_id
      and constraint_row.status='ACTIVE'
      and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
      and constraint_row.time_range && tstzrange(
        day.work_date::timestamp at time zone v_timezone,
        (day.work_date+1)::timestamp at time zone v_timezone,'[)')
    union all
    select distinct day.work_date,grant_row.role_id,grant_row.employee_id,
      grant_row.employee_name,'SOFT'::text
    from days day join grants grant_row on true
    join public.employee_preferences preference
      on preference.employee_id=grant_row.employee_id
      and preference.status='ACTIVE'
      and preference.preference_type='OTHER'
      and preference.preference_value->>'kind'='DAY_OFF'
      and preference.preference_value->>'strength'='SOFT'
      and preference.valid_from<=day.work_date
      and preference.valid_to>=day.work_date
    union all
    select distinct review.work_date,review.role_id,review.employee_id,
      profile.first_name||' '||profile.last_name,'PENDING'::text
    from public.availability_exception_reviews_v2 review
    join public.matrix_employee_profiles_v2 profile
      on profile.matrix_version_id=review.matrix_version_id
      and profile.employee_id=review.employee_id
    where review.matrix_version_id=v_matrix and review.status='PENDING'
      and review.work_date>=v_month
      and review.work_date<(v_month+interval '1 month')::date
  ), grouped as (
    select fact.work_date,fact.role_id,role.name role_name,
      count(distinct fact.employee_id) filter(where fact.fact_kind='HARD') hard_count,
      count(distinct fact.employee_id) filter(where fact.fact_kind='SOFT') soft_count,
      count(distinct fact.employee_id) filter(where fact.fact_kind='PENDING') pending_count,
      coalesce(to_jsonb(array_agg(distinct fact.employee_name order by fact.employee_name)
        filter(where fact.fact_kind='HARD')),'[]'::jsonb) hard_employees,
      coalesce(to_jsonb(array_agg(distinct fact.employee_name order by fact.employee_name)
        filter(where fact.fact_kind='SOFT')),'[]'::jsonb) soft_employees,
      coalesce(to_jsonb(array_agg(distinct fact.employee_name order by fact.employee_name)
        filter(where fact.fact_kind='PENDING')),'[]'::jsonb) pending_employees
    from facts fact join public.matrix_roles_v2 role on role.id=fact.role_id
    group by fact.work_date,fact.role_id,role.name
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'date',grouped.work_date,'roleId',grouped.role_id,'roleName',grouped.role_name,
    'hardCount',grouped.hard_count,'softCount',grouped.soft_count,
    'pendingCount',grouped.pending_count,'hardEmployees',grouped.hard_employees,
    'softEmployees',grouped.soft_employees,'pendingEmployees',grouped.pending_employees
  ) order by grouped.work_date,grouped.role_name),'[]'::jsonb)
  into v_summary from grouped;

  return v_base||jsonb_build_object('availabilitySummary',v_summary);
end;
$$;

revoke all on function public.workforce_calendar_context_uat_v3(date)
  from public,anon,authenticated;
grant execute on function public.workforce_calendar_context_uat_v3(date)
  to authenticated;

notify pgrst,'reload schema';
