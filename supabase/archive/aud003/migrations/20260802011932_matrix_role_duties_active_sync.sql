-- Older development branches created role-duty links before draft-level
-- activation was added. Publication and cloning both require this flag.

alter table public.matrix_role_duties_v2
  add column if not exists active boolean not null default true;
