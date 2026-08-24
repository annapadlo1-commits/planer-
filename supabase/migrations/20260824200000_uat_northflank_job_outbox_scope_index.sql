-- UAT only: cover the optional role-scope foreign key used by outbox cleanup
-- and role-scoped reconciliation without changing the private access boundary.
create index if not exists solver_job_dispatch_scope_role_uat_v1_idx
  on solver_private.solver_job_dispatch_outbox_uat_v1(scope_role_id)
  where scope_role_id is not null;
