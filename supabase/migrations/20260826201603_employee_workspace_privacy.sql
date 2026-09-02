-- TECH-AUD-2026-08-25-003: keep every employee-derived workspace projection
-- inside one canonical, server-resolved employee visibility boundary.

begin;

create or replace function authorization_private.matrix_v2_visible_employee_ids_uat_v1()
returns table(employee_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select employee.id
  from public.employees employee
  where public.matrix_v2_can_manage_employee(employee.id)
$$;

revoke all on function authorization_private.matrix_v2_visible_employee_ids_uat_v1()
  from public, anon, authenticated, service_role;

alter function public.matrix_v2_workspace(date)
  rename to matrix_v2_workspace_before_employee_privacy_uat_v1;

create function public.matrix_v2_workspace(p_month date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_payload jsonb;
  v_matrix uuid;
  v_visible_employee_ids uuid[];
  v_employees jsonb;
  v_ad_hoc_workers jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;

  v_payload := public.matrix_v2_workspace_before_employee_privacy_uat_v1(p_month);
  v_matrix := nullif(v_payload->'matrixVersion'->>'id', '')::uuid;

  select coalesce(array_agg(visible.employee_id order by visible.employee_id), '{}'::uuid[])
  into v_visible_employee_ids
  from authorization_private.matrix_v2_visible_employee_ids_uat_v1() visible;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', employee.id,
      'employeeNo', employee.employee_no,
      'firstName', employee.first_name,
      'lastName', employee.last_name,
      'active', employee.active and employee.archived_at is null
    )
    || coalesce((
      select jsonb_build_object(
        'employmentStage', profile.employment_stage,
        'probationEnd', profile.probation_end
      )
      from public.matrix_employee_profiles_v2 profile
      where profile.matrix_version_id = v_matrix
        and profile.employee_id = employee.id
    ), '{}'::jsonb)
    || jsonb_build_object(
      'overtimePolicy', coalesce((
        select profile.overtime_policy
        from public.matrix_employee_profiles_v2 profile
        where profile.matrix_version_id = v_matrix
          and profile.employee_id = employee.id
      ), 'NEVER')
    )
    order by employee.active desc, employee.last_name, employee.first_name, employee.employee_no
  ), '[]'::jsonb)
  into v_employees
  from public.employees employee
  where employee.id = any(v_visible_employee_ids);
  v_payload := jsonb_set(v_payload, '{employees}', v_employees, true);

  select coalesce(jsonb_agg(item.value order by item.ordinality), '[]'::jsonb)
  into v_employees
  from jsonb_array_elements(coalesce(v_payload->'employeeRoles', '[]'::jsonb))
    with ordinality item(value, ordinality)
  where nullif(item.value->>'employee_id', '')::uuid = any(v_visible_employee_ids);
  v_payload := jsonb_set(v_payload, '{employeeRoles}', v_employees, true);

  select coalesce(jsonb_agg(item.value order by item.ordinality), '[]'::jsonb)
  into v_employees
  from jsonb_array_elements(coalesce(v_payload->'employeeLocations', '[]'::jsonb))
    with ordinality item(value, ordinality)
  where nullif(item.value->>'employee_id', '')::uuid = any(v_visible_employee_ids);
  v_payload := jsonb_set(v_payload, '{employeeLocations}', v_employees, true);

  select coalesce(jsonb_agg(item.value order by item.ordinality), '[]'::jsonb)
  into v_employees
  from jsonb_array_elements(coalesce(v_payload->'employeeDuties', '[]'::jsonb))
    with ordinality item(value, ordinality)
  where nullif(item.value->>'employee_id', '')::uuid = any(v_visible_employee_ids);
  v_payload := jsonb_set(v_payload, '{employeeDuties}', v_employees, true);

  select coalesce(jsonb_agg(item.value order by item.ordinality), '[]'::jsonb)
  into v_employees
  from jsonb_array_elements(coalesce(v_payload->'timeConstraints', '[]'::jsonb))
    with ordinality item(value, ordinality)
  where nullif(item.value->>'employeeId', '')::uuid = any(v_visible_employee_ids);
  v_payload := jsonb_set(v_payload, '{timeConstraints}', v_employees, true);

  select coalesce(jsonb_agg(item.value order by item.ordinality), '[]'::jsonb)
  into v_employees
  from jsonb_array_elements(coalesce(v_payload->'workPatterns', '[]'::jsonb))
    with ordinality item(value, ordinality)
  where nullif(item.value->>'employeeId', '')::uuid = any(v_visible_employee_ids);
  v_payload := jsonb_set(v_payload, '{workPatterns}', v_employees, true);

  select coalesce(jsonb_agg(item.value order by item.ordinality), '[]'::jsonb)
  into v_employees
  from jsonb_array_elements(coalesce(v_payload->'employeePayRates', '[]'::jsonb))
    with ordinality item(value, ordinality)
  where nullif(item.value->>'employee_id', '')::uuid = any(v_visible_employee_ids);
  v_payload := jsonb_set(v_payload, '{employeePayRates}', v_employees, true);

  -- An ad-hoc identity is a recovery resource. A linked employee must be visible
  -- and the recovery role/employee resource must be inside the caller's scope.
  -- A temporary identity has no employee or location relation, so it can only be
  -- resolved through its role scope. HR_FINANCE keeps its pre-existing full
  -- finance/recovery projection; field-level finance redaction already ran in
  -- the wrapped function and remains independent from person visibility.
  select coalesce(jsonb_agg(item.value order by item.ordinality), '[]'::jsonb)
  into v_ad_hoc_workers
  from jsonb_array_elements(coalesce(v_payload->'adHocWorkers', '[]'::jsonb))
    with ordinality item(value, ordinality)
  where (
      nullif(item.value->>'employee_id', '') is null
      or nullif(item.value->>'employee_id', '')::uuid = any(v_visible_employee_ids)
    )
    and (
      public.has_app_role('HR_FINANCE')
      or public.matrix_v2_can_manage_resource_uat_v1(
        nullif(item.value->>'role_id', '')::uuid,
        null,
        nullif(item.value->>'employee_id', '')::uuid
      )
    );
  v_payload := jsonb_set(v_payload, '{adHocWorkers}', v_ad_hoc_workers, true);

  return v_payload;
end;
$$;

-- The final function is the sole authenticated workspace entry point. Historical
-- wrappers remain callable only by their owner through SECURITY DEFINER nesting.
revoke all on function
  public.matrix_v2_workspace_before_categories_uat_v1(date),
  public.matrix_v2_workspace_before_overtime_uat_v1(date),
  public.matrix_v2_workspace_before_ad_hoc_projection_uat_v1(date),
  public.matrix_v2_workspace_before_b4f91_uat_v1(date),
  public.matrix_v2_workspace_before_b4f52_uat_v1(date),
  public.matrix_v2_workspace_before_employee_privacy_uat_v1(date),
  public.matrix_v2_workspace(date)
from public, anon, authenticated, service_role;

grant execute on function public.matrix_v2_workspace(date) to authenticated;

comment on function authorization_private.matrix_v2_visible_employee_ids_uat_v1() is
  'Canonical employee visibility set for matrix_v2_workspace, delegated to Phase 1 resource-aware authorization.';
comment on function public.matrix_v2_workspace(date) is
  'Employee-scoped configuration workspace with independent server-side finance redaction.';

notify pgrst, 'reload schema';

commit;
