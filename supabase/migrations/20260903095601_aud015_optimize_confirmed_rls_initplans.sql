-- AUD-2026-09-01-015: remove per-row auth.uid() re-evaluation from the
-- eleven policies confirmed by the UAT Performance Advisor on 2026-09-03.
--
-- ALTER POLICY preserves each policy's command and role list. The predicates
-- below are the current UAT predicates with only auth.uid() wrapped in a
-- scalar subquery, as recommended by the advisor.

alter policy employee_reads_own_assignments on public.assignments
using (
  exists (
    select 1
    from public.employees employee
    where employee.id = assignments.employee_id
      and employee.auth_user_id = (select auth.uid())
  )
  or public.has_app_role('OWNER'::public.app_role)
  or public.has_app_role('ADMIN'::public.app_role)
  or public.matrix_v2_can_manage_legacy_assignment_uat_v1(id)
);

alter policy employee_reads_own_attendance on public.attendance_events
using (
  exists (
    select 1
    from public.employees employee
    where employee.id = attendance_events.employee_id
      and employee.auth_user_id = (select auth.uid())
  )
  or public.has_app_role('OWNER'::public.app_role)
  or public.has_app_role('ADMIN'::public.app_role)
  or public.has_app_role('HR_FINANCE'::public.app_role)
  or public.matrix_v2_can_manage_legacy_resource_uat_v1(null::text, location_id, employee_id)
);

alter policy availability_manage on public.employee_availability
using (
  exists (
    select 1
    from public.employees employee
    where employee.id = employee_availability.employee_id
      and employee.auth_user_id = (select auth.uid())
  )
  or public.has_app_role('OWNER'::public.app_role)
  or public.has_app_role('ADMIN'::public.app_role)
  or public.matrix_v2_can_manage_resource_uat_v1(null::uuid, null::uuid, employee_id)
)
with check (
  exists (
    select 1
    from public.employees employee
    where employee.id = employee_availability.employee_id
      and employee.auth_user_id = (select auth.uid())
  )
  or public.has_app_role('OWNER'::public.app_role)
  or public.has_app_role('ADMIN'::public.app_role)
  or public.matrix_v2_can_manage_resource_uat_v1(null::uuid, null::uuid, employee_id)
);

alter policy availability_read on public.employee_availability
using (
  exists (
    select 1
    from public.employees employee
    where employee.id = employee_availability.employee_id
      and employee.auth_user_id = (select auth.uid())
  )
  or public.has_app_role('OWNER'::public.app_role)
  or public.has_app_role('ADMIN'::public.app_role)
  or public.matrix_v2_can_manage_resource_uat_v1(null::uuid, null::uuid, employee_id)
);

alter policy availability_history_read on public.employee_availability_history
using (
  exists (
    select 1
    from public.employees employee
    where employee.id = employee_availability_history.employee_id
      and employee.auth_user_id = (select auth.uid())
  )
  or public.has_app_role('OWNER'::public.app_role)
  or public.has_app_role('ADMIN'::public.app_role)
  or public.matrix_v2_can_manage_resource_uat_v1(null::uuid, null::uuid, employee_id)
);

alter policy authenticated_reads_employee_capabilities on public.employee_capabilities
using (
  exists (
    select 1
    from public.employees employee
    where employee.id = employee_capabilities.employee_id
      and employee.auth_user_id = (select auth.uid())
  )
  or public.has_app_role('OWNER'::public.app_role)
  or public.has_app_role('ADMIN'::public.app_role)
  or public.matrix_v2_can_manage_resource_uat_v1(null::uuid, null::uuid, employee_id)
);

alter policy hr_read on public.employee_hr_profiles
using (
  public.has_app_role('OWNER'::public.app_role)
  or public.has_app_role('ADMIN'::public.app_role)
  or public.has_app_role('HR_FINANCE'::public.app_role)
  or exists (
    select 1
    from public.employees employee
    where employee.id = employee_hr_profiles.employee_id
      and employee.auth_user_id = (select auth.uid())
  )
);

alter policy authenticated_reads_employee_locations on public.employee_locations
using (
  exists (
    select 1
    from public.employees employee
    where employee.id = employee_locations.employee_id
      and employee.auth_user_id = (select auth.uid())
  )
  or public.has_app_role('OWNER'::public.app_role)
  or public.has_app_role('ADMIN'::public.app_role)
  or public.matrix_v2_can_manage_resource_uat_v1(null::uuid, null::uuid, employee_id)
);

alter policy employee_reads_self on public.employees
using (
  auth_user_id = (select auth.uid())
  or public.has_app_role('OWNER'::public.app_role)
  or public.has_app_role('ADMIN'::public.app_role)
  or public.has_app_role('HR_FINANCE'::public.app_role)
  or public.matrix_v2_can_manage_resource_uat_v1(null::uuid, null::uuid, id)
);

alter policy user_reads_own_tasks on public.tasks
using (
  assigned_to = (select auth.uid())
  or public.has_app_role('OWNER'::public.app_role)
  or public.has_app_role('ADMIN'::public.app_role)
);

alter policy users_read_own_permissions on public.user_permissions
using (
  auth_user_id = (select auth.uid())
  or public.has_app_role('OWNER'::public.app_role)
  or public.has_app_role('ADMIN'::public.app_role)
);
