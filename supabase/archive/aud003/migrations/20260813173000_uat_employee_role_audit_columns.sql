-- UAT import compatibility: backup-role assignments are audited in the same
-- way as employee profiles.  The import function already records the actor,
-- but the versioned role-assignment table did not yet expose those columns.
alter table public.matrix_employee_roles_v2
  add column if not exists created_by uuid references auth.users(id) on delete set null,
  add column if not exists updated_by uuid references auth.users(id) on delete set null,
  add column if not exists updated_at timestamptz not null default now();

comment on column public.matrix_employee_roles_v2.created_by is
  'Actor who created the versioned employee-role assignment.';
comment on column public.matrix_employee_roles_v2.updated_by is
  'Actor who last changed the versioned employee-role assignment.';
comment on column public.matrix_employee_roles_v2.updated_at is
  'Timestamp of the latest employee-role assignment change.';
