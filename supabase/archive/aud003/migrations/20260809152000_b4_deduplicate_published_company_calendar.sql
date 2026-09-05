-- B4: one authoritative publication per logical role in the employee company calendar.
-- Historical role publications stay auditable, but must never be rendered as a second team.

create or replace function public.published_company_calendar_uat_v2(p_month date)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $function$
declare
  v_month date:=date_trunc('month',p_month)::date;
  v_status jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  v_status:=public.schedule_publication_status_uat_v2(v_month);
  if coalesce((v_status->>'conflict')::boolean,false) then
    raise exception 'SCHEDULE_PUBLICATION_CONFLICT_REQUIRES_OWNER_RESOLUTION';
  end if;

  return jsonb_build_object(
    'month',v_month,
    'publication',v_status,
    'assignments',coalesce((
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
      )
      select jsonb_agg(jsonb_build_object(
        'id',assignment.id,'date',shift.shift_date,'startsAt',shift.starts_at,
        'endsAt',shift.ends_at,'locationId',location.logical_id,
        'locationName',location.name,'shiftName',template.name,
        'roleId',role.logical_id,'roleName',role.name,
        'employeeId',coalesce(replacement.replacement_employee_id,assignment.employee_id),
        'employeeName',coalesce(replacement_profile.first_name||' '||replacement_profile.last_name,
          profile.first_name||' '||profile.last_name),
        'employeeNo',coalesce(replacement_profile.employee_no,profile.employee_no),
        'isSwap',replacement.id is not null,'swapAuditId',swap_request.id
      ) order by shift.starts_at,location.name,role.name,profile.last_name)
      from public.plan_assignments_v2 assignment
      join current_variants current on current.variant_id=assignment.variant_id
      join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
      join public.matrix_locations_v2 location on location.id=shift.location_id
      join public.matrix_shift_templates_v2 template on template.id=shift.shift_template_id
      join public.matrix_roles_v2 role on role.id=assignment.role_id
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
    ),'[]'::jsonb)
  );
end;
$function$;

revoke all on function public.published_company_calendar_uat_v2(date) from public,anon;
grant execute on function public.published_company_calendar_uat_v2(date) to authenticated;
