-- Keep legacy compatibility reads behind the same ACTIVE publication boundary
-- as Matrix v2. Owners and administrators may inspect drafts through these
-- projections, but every mutation still goes through an audited RPC.

revoke insert, update, delete, truncate, references, trigger
  on table public.matrix_versions,
    public.matrix_roles,
    public.matrix_locations,
    public.matrix_shift_templates,
    public.matrix_functions,
    public.matrix_role_functions,
    public.matrix_demand,
    public.matrix_scenarios,
    public.optimizer_profiles,
    public.matrix_employee_roles
  from public, anon, authenticated;

drop policy if exists matrix_owner_write on public.matrix_versions;
drop policy if exists matrix_scenarios_write on public.matrix_scenarios;
drop policy if exists optimizer_profiles_manage on public.optimizer_profiles;

drop policy if exists matrix_read on public.matrix_versions;
create policy matrix_read on public.matrix_versions
for select to authenticated
using (
  status='ACTIVE' or public.has_app_role('OWNER') or public.has_app_role('ADMIN')
);

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'matrix_roles','matrix_locations','matrix_shift_templates','matrix_functions'
  ] loop
    execute format('drop policy if exists matrix_read on public.%I',v_table);
    execute format(
      'create policy matrix_read on public.%I for select to authenticated '
      ||'using (exists(select 1 from public.matrix_versions mv '
      ||'where mv.id=matrix_version_id and (mv.status=''ACTIVE'' '
      ||'or public.has_app_role(''OWNER'') or public.has_app_role(''ADMIN''))))',
      v_table
    );
    execute format('drop policy if exists matrix_owner_write on public.%I',v_table);
  end loop;
end;
$$;

drop policy if exists matrix_read on public.matrix_role_functions;
create policy matrix_read on public.matrix_role_functions
for select to authenticated
using (
  exists(
    select 1
    from public.matrix_roles role_row
    join public.matrix_versions mv on mv.id=role_row.matrix_version_id
    where role_row.id=role_id
      and (mv.status='ACTIVE' or public.has_app_role('OWNER')
        or public.has_app_role('ADMIN'))
  )
);
drop policy if exists matrix_owner_write on public.matrix_role_functions;

drop policy if exists matrix_read on public.matrix_demand;
create policy matrix_read on public.matrix_demand
for select to authenticated
using (
  exists(
    select 1
    from public.matrix_shift_templates shift_row
    join public.matrix_versions mv on mv.id=shift_row.matrix_version_id
    where shift_row.id=shift_template_id
      and (mv.status='ACTIVE' or public.has_app_role('OWNER')
        or public.has_app_role('ADMIN'))
  )
);
drop policy if exists matrix_owner_write on public.matrix_demand;

drop policy if exists matrix_scenarios_read on public.matrix_scenarios;
create policy matrix_scenarios_read on public.matrix_scenarios
for select to authenticated
using (
  exists(
    select 1 from public.matrix_versions mv
    where mv.id=matrix_version_id
      and (mv.status='ACTIVE' or public.has_app_role('OWNER')
        or public.has_app_role('ADMIN'))
  )
);

drop policy if exists optimizer_profiles_read on public.optimizer_profiles;
create policy optimizer_profiles_read on public.optimizer_profiles
for select to authenticated
using (
  public.can_manage_plans() and exists(
    select 1 from public.matrix_versions mv
    where mv.id=matrix_version_id
      and (mv.status='ACTIVE' or public.has_app_role('OWNER')
        or public.has_app_role('ADMIN'))
  )
);

drop policy if exists matrix_employee_roles_read on public.matrix_employee_roles;
create policy matrix_employee_roles_read on public.matrix_employee_roles
for select to authenticated
using (
  (
    public.can_manage_plans()
    or exists(
      select 1 from public.employees employee
      where employee.id=employee_id
        and employee.auth_user_id=(select auth.uid())
    )
  ) and exists(
    select 1 from public.matrix_versions mv
    where mv.id=matrix_version_id
      and (mv.status='ACTIVE' or public.has_app_role('OWNER')
        or public.has_app_role('ADMIN'))
  )
);
