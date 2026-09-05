-- B4F-87: the employee calendar exposes only coworkers from categories in
-- which the signed-in employee has an active role in the source Matrix.
-- The payload deliberately contains no pay, absence reasons or preferences.

create or replace function public.published_employee_category_calendar_uat_v3(
  p_month date
) returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $function$
declare
  v_month date:=date_trunc('month',p_month)::date;
  v_status jsonb;
  v_employee uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;

  select employee.id into v_employee
  from public.employees employee
  where employee.auth_user_id=auth.uid()
    and employee.active
    and employee.archived_at is null
  order by employee.employee_no
  limit 1;

  if v_employee is null then raise exception 'EMPLOYEE_ACCOUNT_NOT_LINKED'; end if;

  v_status:=public.schedule_publication_status_uat_v2(v_month);
  if coalesce((v_status->>'conflict')::boolean,false) then
    raise exception 'SCHEDULE_PUBLICATION_CONFLICT_REQUIRES_OWNER_RESOLUTION';
  end if;

  return (
    with company_variants as (
      select distinct link.variant_id
      from public.published_schedules_v2 schedule
      join public.published_schedule_variants_v2 link on link.schedule_id=schedule.id
      where schedule.month=v_month and schedule.status='PUBLISHED'
    ),
    latest_role_variants as (
      select distinct on(role.logical_id) publication.variant_id
      from public.published_role_schedules_v2 publication
      join public.matrix_roles_v2 role on role.id=publication.role_id
      where publication.month=v_month and publication.status='PUBLISHED'
      order by role.logical_id,publication.published_at desc nulls last,
        publication.created_at desc,publication.id desc
    ),
    current_variants as (
      select variant_id from company_variants
      union all
      select variant_id from latest_role_variants
      where not exists(select 1 from company_variants)
    ),
    scoped_rows as (
      select assignment.id,shift.shift_date,shift.starts_at,shift.ends_at,
        location.logical_id location_id,location.name location_name,
        template.name shift_name,role.logical_id role_id,role.name role_name,
        category.logical_id category_id,category.name category_name,
        coalesce(replacement.replacement_employee_id,assignment.employee_id) employee_id,
        coalesce(replacement_profile.first_name||' '||replacement_profile.last_name,
          profile.first_name||' '||profile.last_name) employee_name,
        coalesce(replacement_profile.employee_no,profile.employee_no) employee_no,
        replacement.id is not null is_swap,swap_request.id swap_audit_id
      from public.plan_assignments_v2 assignment
      join current_variants current on current.variant_id=assignment.variant_id
      join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
      join public.matrix_locations_v2 location on location.id=shift.location_id
      join public.matrix_shift_templates_v2 template on template.id=shift.shift_template_id
      join public.matrix_roles_v2 role on role.id=assignment.role_id
      join public.matrix_role_categories_v2 category on category.id=role.category_id
      join public.matrix_employee_profiles_v2 profile
        on profile.matrix_version_id=role.matrix_version_id
       and profile.employee_id=assignment.employee_id
      left join public.operational_assignment_replacements_v2 replacement
        on replacement.original_assignment_id=assignment.id and replacement.status='ACTIVE'
      left join public.matrix_employee_profiles_v2 replacement_profile
        on replacement_profile.matrix_version_id=role.matrix_version_id
       and replacement_profile.employee_id=replacement.replacement_employee_id
      left join public.shift_swap_requests_v2 swap_request
        on swap_request.replacement_id=replacement.id
      where shift.shift_date>=v_month
        and shift.shift_date<(v_month+interval '1 month')::date
        and exists(
          select 1
          from public.matrix_employee_roles_v2 viewer_grant
          join public.matrix_roles_v2 viewer_role on viewer_role.id=viewer_grant.role_id
          where viewer_grant.matrix_version_id=role.matrix_version_id
            and viewer_grant.employee_id=v_employee
            and viewer_grant.active
            and viewer_role.active
            and viewer_role.category_id=role.category_id
            and (viewer_grant.valid_from is null
              or viewer_grant.valid_from<(v_month+interval '1 month')::date)
            and (viewer_grant.valid_to is null or viewer_grant.valid_to>=v_month)
        )
    )
    select jsonb_build_object(
      'month',v_month,
      'publication',v_status,
      'employeeId',v_employee,
      'scopeCategories',coalesce((
        select jsonb_agg(category_item order by category_item->>'name')
        from (
          select distinct jsonb_build_object(
            'id',row_value.category_id,'name',row_value.category_name
          ) category_item
          from scoped_rows row_value
        ) categories
      ),'[]'::jsonb),
      'assignments',coalesce((
        select jsonb_agg(jsonb_build_object(
          'id',row_value.id,'date',row_value.shift_date,
          'startsAt',row_value.starts_at,'endsAt',row_value.ends_at,
          'locationId',row_value.location_id,'locationName',row_value.location_name,
          'shiftName',row_value.shift_name,
          'roleId',row_value.role_id,'roleName',row_value.role_name,
          'categoryId',row_value.category_id,'categoryName',row_value.category_name,
          'employeeId',row_value.employee_id,'employeeName',row_value.employee_name,
          'employeeNo',row_value.employee_no,'isSwap',row_value.is_swap,
          'swapAuditId',row_value.swap_audit_id
        ) order by row_value.starts_at,row_value.location_name,
          row_value.role_name,row_value.employee_name)
        from scoped_rows row_value
      ),'[]'::jsonb)
    )
  );
end;
$function$;

revoke all on function public.published_employee_category_calendar_uat_v3(date)
  from public,anon;
grant execute on function public.published_employee_category_calendar_uat_v3(date)
  to authenticated;

-- The legacy calendar returns the whole company and is used only from
-- SECURITY DEFINER owner/UAT wrappers. It must not remain a direct employee
-- API once the category-scoped contract is available.
revoke all on function public.published_company_calendar_uat_v2(date)
  from authenticated;
grant execute on function public.published_company_calendar_uat_v2(date)
  to service_role;

comment on function public.published_employee_category_calendar_uat_v3(date) is
  'B4F-87: category-scoped coworker calendar for the signed-in employee; no finance or absence details.';
