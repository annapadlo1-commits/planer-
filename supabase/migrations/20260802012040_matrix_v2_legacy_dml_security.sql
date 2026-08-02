-- Matrix v2 is edited through audited SECURITY DEFINER RPCs.  Direct writes
-- to the legacy compatibility tables would bypass draft/publication guards,
-- so application roles retain read access only (still constrained by RLS).

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
  from anon, authenticated;

grant select
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
  to authenticated;

comment on table public.matrix_versions is
  'Legacy-compatible Matrix projection. Application writes are permitted only through Matrix v2 RPCs.';
