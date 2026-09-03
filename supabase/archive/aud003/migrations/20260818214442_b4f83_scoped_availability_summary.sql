-- B4F-83/B4F-84: a manager-facing availability summary must keep the
-- category, role and location dimensions. The existing v3 aggregate remains
-- unchanged for backwards compatibility.

create or replace function public.workforce_calendar_context_uat_v4(p_month date)
returns jsonb
language plpgsql stable security definer set search_path=''
as $$
declare
  v_base jsonb;
  v_matrix uuid;
  v_month date:=date_trunc('month',p_month)::date;
  v_scoped jsonb:='[]'::jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  v_base:=public.workforce_calendar_context_uat_v3(v_month);
  if not public.can_manage_plans() then
    return v_base||jsonb_build_object('availabilityScopedSummary','[]'::jsonb);
  end if;
  v_matrix:=nullif(v_base->>'matrixVersionId','')::uuid;

  with days as (
    select generate_series(v_month,(v_month+interval '1 month - 1 day')::date,
      interval '1 day')::date work_date
  ), scopes as (
    select distinct role.id role_id,role.name role_name,role.logical_id role_logical_id,
      category.id category_id,category.name category_name,
      location.id location_id,location.name location_name,location.logical_id location_logical_id,
      location.timezone
    from public.matrix_staffing_rules_v2 staffing
    join public.matrix_shift_templates_v2 template
      on template.id=staffing.shift_template_id and template.matrix_version_id=v_matrix
      and template.active
    join public.matrix_roles_v2 role on role.id=staffing.role_id
      and role.matrix_version_id=v_matrix and role.active
    join public.matrix_role_categories_v2 category on category.id=role.category_id
      and category.matrix_version_id=v_matrix and category.active
    join public.matrix_locations_v2 location on location.id=template.location_id
      and location.matrix_version_id=v_matrix and location.active
    where staffing.matrix_version_id=v_matrix and staffing.active
      and (public.has_app_role('OWNER') or public.has_app_role('ADMIN') or exists(
        select 1 from public.matrix_scope_grants_v2 scope_grant
        where scope_grant.auth_user_id=auth.uid() and scope_grant.active
          and scope_grant.app_role='ROLE_MANAGER'
          and (scope_grant.role_logical_id is null or scope_grant.role_logical_id=role.logical_id)
          and (scope_grant.location_logical_id is null or scope_grant.location_logical_id=location.logical_id)
      ))
  ), eligible as (
    select day.work_date,scope.*,profile.employee_id,
      profile.first_name||' '||profile.last_name employee_name,
      exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=profile.employee_id and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
          and constraint_row.time_range&&tstzrange(
            day.work_date::timestamp at time zone scope.timezone,
            (day.work_date+1)::timestamp at time zone scope.timezone,'[)')) hard_unavailable,
      exists(select 1 from public.employee_preferences preference
        where preference.employee_id=profile.employee_id and preference.status='ACTIVE'
          and preference.preference_type='OTHER'
          and preference.preference_value->>'kind'='DAY_OFF'
          and preference.preference_value->>'strength'='SOFT'
          and preference.valid_from<=day.work_date and preference.valid_to>=day.work_date) soft_unavailable,
      exists(select 1 from public.availability_exception_reviews_v2 review
        where review.matrix_version_id=v_matrix and review.employee_id=profile.employee_id
          and review.role_id=scope.role_id and review.work_date=day.work_date
          and review.status='PENDING') pending_review
    from days day cross join scopes scope
    left join public.matrix_employee_roles_v2 role_grant
      on role_grant.matrix_version_id=v_matrix and role_grant.role_id=scope.role_id
      and role_grant.active
      and (role_grant.valid_from is null or role_grant.valid_from<=day.work_date)
      and (role_grant.valid_to is null or role_grant.valid_to>=day.work_date)
    left join public.matrix_employee_locations_v2 location_grant
      on location_grant.matrix_version_id=v_matrix
      and location_grant.employee_id=role_grant.employee_id
      and location_grant.location_id=scope.location_id and location_grant.active
      and (location_grant.valid_from is null or location_grant.valid_from<=day.work_date)
      and (location_grant.valid_to is null or location_grant.valid_to>=day.work_date)
    left join public.matrix_employee_profiles_v2 profile
      on location_grant.employee_id is not null
      and profile.matrix_version_id=v_matrix and profile.employee_id=role_grant.employee_id
      and profile.active and profile.archived_at is null
      and (profile.employment_start is null or profile.employment_start<=day.work_date)
      and (profile.employment_end is null or profile.employment_end>=day.work_date)
  ), grouped as (
    select work_date,category_id,category_name,role_id,role_name,location_id,location_name,
      count(distinct employee_id) total_count,
      count(distinct employee_id) filter(where not hard_unavailable and not pending_review) available_count,
      count(distinct employee_id) filter(where hard_unavailable) hard_count,
      count(distinct employee_id) filter(where soft_unavailable) soft_count,
      count(distinct employee_id) filter(where pending_review) pending_count,
      count(distinct employee_id) filter(where hard_unavailable or soft_unavailable or pending_review) recorded_count,
      coalesce(to_jsonb(array_agg(distinct employee_name order by employee_name)
        filter(where hard_unavailable)),'[]'::jsonb) hard_employees,
      coalesce(to_jsonb(array_agg(distinct employee_name order by employee_name)
        filter(where soft_unavailable)),'[]'::jsonb) soft_employees,
      coalesce(to_jsonb(array_agg(distinct employee_name order by employee_name)
        filter(where pending_review)),'[]'::jsonb) pending_employees
    from eligible group by work_date,category_id,category_name,role_id,role_name,location_id,location_name
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'date',work_date,'categoryId',category_id,'categoryName',category_name,
    'roleId',role_id,'roleName',role_name,'locationId',location_id,'locationName',location_name,
    'totalCount',total_count,'availableCount',available_count,
    'recordedCount',recorded_count,
    'progressPercent',case when total_count=0 then 100 else round(recorded_count::numeric*100/total_count)::integer end,
    'hardCount',hard_count,'softCount',soft_count,'pendingCount',pending_count,
    'hardEmployees',hard_employees,'softEmployees',soft_employees,'pendingEmployees',pending_employees
  ) order by work_date,category_name,role_name,location_name),'[]'::jsonb)
  into v_scoped from grouped;

  return v_base||jsonb_build_object('availabilityScopedSummary',v_scoped);
end;
$$;

revoke all on function public.workforce_calendar_context_uat_v4(date)
from public,anon,authenticated;
grant execute on function public.workforce_calendar_context_uat_v4(date) to authenticated;

comment on function public.workforce_calendar_context_uat_v4(date)
is 'B4F-83: permission-scoped availability by category, role, location and local work day.';
