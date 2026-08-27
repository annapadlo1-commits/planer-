-- Phase 4A.1 / TECH-AUD-2026-08-27-020, 023, 024 and 025.
-- Close legacy direct-table manager bypasses without changing business data.

begin;

create or replace function public.matrix_v2_can_manage_legacy_resource_uat_v1(
  p_role_code text default null,
  p_legacy_location_id uuid default null,
  p_employee_id uuid default null
) returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_matrix_id uuid;
  v_match_count integer;
  v_role_id uuid;
  v_location_id uuid;
begin
  if auth.uid() is null then return false; end if;

  select count(*),(array_agg(matrix.id))[1] into v_match_count,v_matrix_id
  from public.matrix_versions matrix
  where matrix.status='ACTIVE';
  if v_match_count<>1 then return false; end if;

  if nullif(trim(coalesce(p_role_code,'')),'') is not null then
    select count(*),(array_agg(role.id))[1] into v_match_count,v_role_id
    from public.matrix_roles_v2 role
    where role.matrix_version_id=v_matrix_id and role.active
      and upper(role.code)=upper(trim(p_role_code));
    if v_match_count<>1 then return false; end if;
  end if;

  if p_legacy_location_id is not null then
    select count(*),(array_agg(matrix_location.id))[1] into v_match_count,v_location_id
    from public.locations legacy_location
    join public.matrix_locations_v2 matrix_location
      on upper(matrix_location.code::text)=upper(legacy_location.code::text)
    where legacy_location.id=p_legacy_location_id
      and matrix_location.matrix_version_id=v_matrix_id
      and matrix_location.active;
    if v_match_count<>1 then return false; end if;
  end if;

  return public.matrix_v2_can_manage_resource_uat_v1(
    v_role_id,v_location_id,p_employee_id
  );
end;
$$;

alter function public.matrix_v2_can_manage_legacy_resource_uat_v1(text,uuid,uuid)
  owner to postgres;

revoke all on function public.matrix_v2_can_manage_legacy_resource_uat_v1(text,uuid,uuid)
  from public,anon,authenticated,service_role;
grant execute on function public.matrix_v2_can_manage_legacy_resource_uat_v1(text,uuid,uuid)
  to authenticated;

-- Resolve legacy assignment resources under the trusted function owner.  RLS
-- on shifts must not be able to erase the location used for authorization.
create or replace function public.matrix_v2_can_manage_legacy_assignment_uat_v1(
  p_assignment_id uuid
) returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role_code text;
  v_employee_id uuid;
  v_location_id uuid;
begin
  if auth.uid() is null or p_assignment_id is null then return false; end if;

  select assignment.assigned_role::text,assignment.employee_id,shift.location_id
  into v_role_code,v_employee_id,v_location_id
  from public.assignments assignment
  join public.shifts shift on shift.id=assignment.shift_id
  where assignment.id=p_assignment_id;

  if v_role_code is null or v_employee_id is null or v_location_id is null then
    return false;
  end if;

  return public.matrix_v2_can_manage_legacy_resource_uat_v1(
    v_role_code,v_location_id,v_employee_id
  );
end;
$$;

alter function public.matrix_v2_can_manage_legacy_assignment_uat_v1(uuid)
  owner to postgres;
revoke all on function public.matrix_v2_can_manage_legacy_assignment_uat_v1(uuid)
  from public,anon,authenticated,service_role;
grant execute on function public.matrix_v2_can_manage_legacy_assignment_uat_v1(uuid)
  to authenticated;

-- plan_issues has the same hidden-shift boundary as assignments.  Resolve the
-- issue role and actual shift location without depending on caller-visible RLS.
create or replace function public.matrix_v2_can_manage_legacy_plan_issue_uat_v1(
  p_issue_id uuid
) returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role_code text;
  v_location_id uuid;
begin
  if auth.uid() is null or p_issue_id is null then return false; end if;

  select issue.role::text,shift.location_id
  into v_role_code,v_location_id
  from public.plan_issues issue
  join public.shifts shift on shift.id=issue.shift_id
  where issue.id=p_issue_id;

  if v_role_code is null or v_location_id is null then return false; end if;

  return public.matrix_v2_can_manage_legacy_resource_uat_v1(
    v_role_code,v_location_id,null
  );
end;
$$;

alter function public.matrix_v2_can_manage_legacy_plan_issue_uat_v1(uuid)
  owner to postgres;
revoke all on function public.matrix_v2_can_manage_legacy_plan_issue_uat_v1(uuid)
  from public,anon,authenticated,service_role;
grant execute on function public.matrix_v2_can_manage_legacy_plan_issue_uat_v1(uuid)
  to authenticated;

drop policy if exists employee_reads_own_assignments on public.assignments;
create policy employee_reads_own_assignments on public.assignments
for select to authenticated
using (
  exists(select 1 from public.employees employee
    where employee.id=assignments.employee_id and employee.auth_user_id=auth.uid())
  or public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  or public.matrix_v2_can_manage_legacy_assignment_uat_v1(assignments.id)
);

-- Published legacy schedules remain an intentional company-wide authenticated
-- read. Draft/archived plan and shift rows are global only for OWNER/ADMIN.
drop policy if exists authenticated_reads_plans on public.plans;
create policy authenticated_reads_plans on public.plans
for select to authenticated
using (
  plans.status='PUBLISHED'
  or public.has_app_role('OWNER') or public.has_app_role('ADMIN')
);

drop policy if exists employee_reads_published_shifts on public.shifts;
create policy employee_reads_published_shifts on public.shifts
for select to authenticated
using (
  exists(select 1 from public.plans plan where plan.id=shifts.plan_id and plan.status='PUBLISHED')
  or public.has_app_role('OWNER') or public.has_app_role('ADMIN')
);

drop policy if exists availability_read on public.employee_availability;
create policy availability_read on public.employee_availability
for select to authenticated
using (
  exists(select 1 from public.employees employee
    where employee.id=employee_availability.employee_id and employee.auth_user_id=auth.uid())
  or public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  or public.matrix_v2_can_manage_resource_uat_v1(null,null,employee_availability.employee_id)
);

drop policy if exists availability_manage on public.employee_availability;
create policy availability_manage on public.employee_availability
for all to authenticated
using (
  exists(select 1 from public.employees employee
    where employee.id=employee_availability.employee_id and employee.auth_user_id=auth.uid())
  or public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  or public.matrix_v2_can_manage_resource_uat_v1(null,null,employee_availability.employee_id)
)
with check (
  exists(select 1 from public.employees employee
    where employee.id=employee_availability.employee_id and employee.auth_user_id=auth.uid())
  or public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  or public.matrix_v2_can_manage_resource_uat_v1(null,null,employee_availability.employee_id)
);

drop policy if exists availability_history_read on public.employee_availability_history;
create policy availability_history_read on public.employee_availability_history
for select to authenticated
using (
  exists(select 1 from public.employees employee
    where employee.id=employee_availability_history.employee_id
      and employee.auth_user_id=auth.uid())
  or public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  or public.matrix_v2_can_manage_resource_uat_v1(
    null,null,employee_availability_history.employee_id
  )
);

drop policy if exists managers_manage_events on public.operational_events;
create policy managers_manage_events on public.operational_events
for all to authenticated
using (
  public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  or public.matrix_v2_can_manage_legacy_resource_uat_v1(null,operational_events.location_id,null)
)
with check (
  public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  or public.matrix_v2_can_manage_legacy_resource_uat_v1(null,operational_events.location_id,null)
);

-- Legacy person tables remain available for employee self-service and global
-- administrative roles. Scoped managers are resolved through the canonical
-- active-Matrix employee boundary instead of their global app-role name.
drop policy if exists employee_reads_self on public.employees;
create policy employee_reads_self on public.employees
for select to authenticated
using (
  auth_user_id=auth.uid()
  or public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  or public.has_app_role('HR_FINANCE')
  or public.matrix_v2_can_manage_resource_uat_v1(null,null,employees.id)
);

drop policy if exists authenticated_reads_employee_locations on public.employee_locations;
create policy authenticated_reads_employee_locations on public.employee_locations
for select to authenticated
using (
  exists(select 1 from public.employees employee
    where employee.id=employee_locations.employee_id and employee.auth_user_id=auth.uid())
  or public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  or public.matrix_v2_can_manage_resource_uat_v1(null,null,employee_locations.employee_id)
);

drop policy if exists authenticated_reads_employee_capabilities on public.employee_capabilities;
create policy authenticated_reads_employee_capabilities on public.employee_capabilities
for select to authenticated
using (
  exists(select 1 from public.employees employee
    where employee.id=employee_capabilities.employee_id and employee.auth_user_id=auth.uid())
  or public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  or public.matrix_v2_can_manage_resource_uat_v1(null,null,employee_capabilities.employee_id)
);

drop policy if exists employee_reads_own_attendance on public.attendance_events;
create policy employee_reads_own_attendance on public.attendance_events
for select to authenticated
using (
  exists(select 1 from public.employees employee
    where employee.id=attendance_events.employee_id and employee.auth_user_id=auth.uid())
  or public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  or public.has_app_role('HR_FINANCE')
  or public.matrix_v2_can_manage_legacy_resource_uat_v1(
    null,attendance_events.location_id,attendance_events.employee_id
  )
);

drop policy if exists plan_issues_read on public.plan_issues;
create policy plan_issues_read on public.plan_issues
for select to authenticated
using (
  public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  or public.matrix_v2_can_manage_legacy_plan_issue_uat_v1(plan_issues.id)
);

-- Finance configuration and incident rates already have redacted, authorized
-- RPC projections. Direct table access is admin/finance-only.
drop policy if exists employer_cost_components_read_v2 on public.employer_cost_components_v2;
create policy employer_cost_components_read_v2 on public.employer_cost_components_v2
for select to authenticated
using (
  public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  or public.has_app_role('HR_FINANCE')
);

drop policy if exists incident_rates_read_v2 on public.recovery_incident_rate_revisions_v2;
create policy incident_rates_read_v2 on public.recovery_incident_rate_revisions_v2
for select to authenticated
using (
  public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  or public.has_app_role('HR_FINANCE')
);

-- Role categories are a shared dictionary for configuration and finance, but a
-- role manager may read only categories containing a role in their scope.
drop policy if exists matrix_role_categories_v2_select on public.matrix_role_categories_v2;
create policy matrix_role_categories_v2_select on public.matrix_role_categories_v2
for select to authenticated
using (
  public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  or public.has_app_role('HR_FINANCE')
  or exists(
    select 1 from public.matrix_roles_v2 role
    where role.category_id=matrix_role_categories_v2.id and role.active
      and public.matrix_v2_can_manage_resource_uat_v1(role.id,null,null)
  )
);

comment on function public.matrix_v2_can_manage_legacy_resource_uat_v1(text,uuid,uuid) is
  'Phase 4A fail-closed adapter from legacy role/location resources to canonical active-Matrix scoped authorization.';
comment on function public.matrix_v2_can_manage_legacy_assignment_uat_v1(uuid) is
  'Phase 4A trusted assignment resource resolver; reads the actual shift location before canonical scoped authorization.';
comment on function public.matrix_v2_can_manage_legacy_plan_issue_uat_v1(uuid) is
  'Phase 4A trusted plan-issue resource resolver; reads the actual shift location before canonical scoped authorization.';

notify pgrst,'reload schema';

commit;
