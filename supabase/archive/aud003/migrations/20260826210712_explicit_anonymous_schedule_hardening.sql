-- TECH-AUD-2026-08-25-004 / Phase 3B
-- Make the anonymous legacy schedule denial local to the schedule tables.
-- Authenticated row semantics are intentionally preserved.

revoke select on table public.shifts from anon;
revoke select on table public.assignments from anon;

grant select on table public.shifts to authenticated;
grant select on table public.assignments to authenticated;

drop policy if exists employee_reads_published_shifts on public.shifts;
create policy employee_reads_published_shifts
on public.shifts
for select
to authenticated
using (
  exists (
    select 1
    from public.plans p
    where p.id = shifts.plan_id
      and p.status = 'PUBLISHED'
  )
  or public.has_app_role('OWNER')
  or public.has_app_role('ADMIN')
  or public.has_app_role('ROLE_MANAGER')
  or public.has_app_role('LOCATION_MANAGER')
);

drop policy if exists employee_reads_own_assignments on public.assignments;
create policy employee_reads_own_assignments
on public.assignments
for select
to authenticated
using (
  exists (
    select 1
    from public.employees e
    where e.id = assignments.employee_id
      and e.auth_user_id = auth.uid()
  )
  or public.has_app_role('OWNER')
  or public.has_app_role('ADMIN')
  or public.has_app_role('ROLE_MANAGER')
  or public.has_app_role('LOCATION_MANAGER')
);
