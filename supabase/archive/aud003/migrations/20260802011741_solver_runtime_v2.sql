-- GRAFIK PRO 3.0 — target solver runtime v2
-- Additive runtime for Python + OR-Tools. Alpha 15 tables and RPCs remain intact.

create extension if not exists pgmq;

create schema if not exists solver_private;
revoke all on schema solver_private from public, anon, authenticated;
grant usage on schema solver_private to service_role;

create table public.optimization_runs_v2 (
  id uuid primary key default gen_random_uuid(),
  idempotency_key text not null check (length(idempotency_key) between 8 and 200),
  month date not null check (date_trunc('month',month)::date=month),
  matrix_version_id uuid not null references public.matrix_versions(id),
  scenario_id uuid not null references public.matrix_scenarios_v2(id),
  scope_type text not null default 'COMPANY' check (scope_type in ('COMPANY','ROLE')),
  scope_role_id uuid references public.matrix_roles_v2(id),
  name text not null,
  status text not null default 'QUEUED' check (status in (
    'QUEUED','RUNNING','VALIDATING','READY','CANCEL_REQUESTED',
    'CANCELLED','FAILED','STALE_INPUT'
  )),
  phase text not null default 'QUEUED',
  progress smallint not null default 0 check (progress between 0 and 100),
  requested_by uuid not null references auth.users(id),
  snapshot_schema_version integer not null default 2 check (snapshot_schema_version > 0),
  snapshot_hash text not null check (snapshot_hash ~ '^[0-9a-f]{64}$'),
  solver_version text not null check (length(solver_version) between 1 and 200),
  request_engine text not null check (request_engine in ('SHADOW','ORTOOLS_V2')),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  max_attempts integer not null default 3 check (max_attempts between 1 and 20),
  queue_message_id bigint,
  lease_owner text,
  lease_token uuid,
  lease_expires_at timestamptz,
  worker_execution_name text,
  heartbeat_at timestamptz,
  cancel_requested_at timestamptz,
  failure_code text,
  failure_message text,
  created_at timestamptz not null default now(),
  queued_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz,
  updated_at timestamptz not null default now(),
  unique(requested_by,idempotency_key),
  check ((scope_type='ROLE')=(scope_role_id is not null)),
  check ((lease_owner is null and lease_token is null and lease_expires_at is null)
    or (lease_owner is not null and lease_token is not null and lease_expires_at is not null))
);

create or replace function solver_private.guard_run_provenance_v2()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.request_engine is distinct from old.request_engine then
    raise exception 'RUN_REQUEST_ENGINE_IMMUTABLE';
  end if;
  if new.solver_version is distinct from old.solver_version then
    raise exception 'RUN_SOLVER_VERSION_IMMUTABLE';
  end if;
  return new;
end;
$$;

revoke all on function solver_private.guard_run_provenance_v2()
  from public,anon,authenticated;
grant execute on function solver_private.guard_run_provenance_v2()
  to service_role;

create trigger optimization_runs_v2_provenance_immutable
before update of request_engine,solver_version on public.optimization_runs_v2
for each row execute function solver_private.guard_run_provenance_v2();

create table solver_private.optimization_attempts_v2 (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references public.optimization_runs_v2(id) on delete cascade,
  attempt_number integer not null check (attempt_number > 0),
  task_attempt integer not null default 0 check (task_attempt >= 0),
  worker_id text not null,
  worker_execution_name text,
  lease_token uuid not null,
  status text not null default 'RUNNING' check (status in ('RUNNING','SUCCEEDED','INTERRUPTED','FAILED','LEASE_LOST')),
  started_at timestamptz not null default now(),
  heartbeat_at timestamptz not null default now(),
  finished_at timestamptz,
  error_code text,
  error_message text,
  unique(run_id,attempt_number)
);

create table public.optimization_run_strategies_v2 (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references public.optimization_runs_v2(id) on delete cascade,
  strategy_id uuid not null references public.matrix_strategies_v2(id),
  ordinal integer not null check (ordinal > 0),
  status text not null default 'QUEUED' check (status in (
    'QUEUED','RUNNING','VALIDATING','READY','CANCELLED','FAILED','STALE_INPUT'
  )),
  phase text not null default 'QUEUED',
  progress smallint not null default 0 check (progress between 0 and 100),
  metrics jsonb not null default '{}'::jsonb,
  failure_code text,
  started_at timestamptz,
  finished_at timestamptz,
  updated_at timestamptz not null default now(),
  unique(run_id,strategy_id),
  unique(run_id,ordinal)
);

create table public.plan_variants_v2 (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references public.optimization_runs_v2(id) on delete cascade,
  run_strategy_id uuid not null references public.optimization_run_strategies_v2(id) on delete cascade,
  strategy_id uuid not null references public.matrix_strategies_v2(id),
  name text not null,
  status text not null default 'READY' check (status in ('READY','SELECTED','PUBLISHED','ARCHIVED')),
  hard_violations integer not null default 0 check (hard_violations >= 0),
  assignment_count integer not null default 0 check (assignment_count >= 0),
  unfilled_count integer not null default 0 check (unfilled_count >= 0),
  solver_status text not null check (solver_status in ('OPTIMAL','FEASIBLE')),
  solution_hash text not null check (solution_hash ~ '^[0-9a-f]{64}$'),
  objective_bound bigint,
  metrics jsonb not null default '{}'::jsonb,
  recommended boolean not null default false,
  selected boolean not null default false,
  equivalent_to_variant_id uuid references public.plan_variants_v2(id) on delete set null,
  snapshot_hash text not null check (snapshot_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now(),
  selected_at timestamptz,
  selected_by uuid references auth.users(id),
  published_at timestamptz,
  unique(run_id,strategy_id),
  unique(run_strategy_id)
);

create unique index plan_variants_v2_one_selected_per_run
  on public.plan_variants_v2(run_id) where selected;
create unique index plan_variants_v2_one_recommended_per_run
  on public.plan_variants_v2(run_id) where recommended;

create table public.plan_shifts_v2 (
  id uuid primary key default gen_random_uuid(),
  variant_id uuid not null references public.plan_variants_v2(id) on delete cascade,
  slot_group_key text not null,
  shift_template_id uuid not null references public.matrix_shift_templates_v2(id),
  location_id uuid not null references public.matrix_locations_v2(id),
  shift_date date not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  source_type text not null default 'MATRIX',
  source_id uuid,
  created_at timestamptz not null default now(),
  check (ends_at > starts_at),
  unique(variant_id,slot_group_key)
);

create table public.plan_assignments_v2 (
  id uuid primary key default gen_random_uuid(),
  variant_id uuid not null references public.plan_variants_v2(id) on delete cascade,
  shift_id uuid not null references public.plan_shifts_v2(id) on delete cascade,
  slot_key text not null,
  employee_id uuid not null references public.employees(id),
  role_id uuid not null references public.matrix_roles_v2(id),
  locked boolean not null default false,
  explanation jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique(variant_id,slot_key),
  unique(shift_id,employee_id,role_id,slot_key)
);

create table public.plan_assignment_duties_v2 (
  assignment_id uuid not null references public.plan_assignments_v2(id) on delete cascade,
  duty_id uuid not null references public.matrix_duties_v2(id),
  primary key(assignment_id,duty_id)
);

create table public.plan_issues_v2 (
  id bigint generated always as identity primary key,
  variant_id uuid not null references public.plan_variants_v2(id) on delete cascade,
  shift_id uuid references public.plan_shifts_v2(id) on delete cascade,
  slot_key text,
  issue_code text not null,
  severity text not null check (severity in ('INFO','WARNING','CRITICAL')),
  role_id uuid references public.matrix_roles_v2(id),
  duty_id uuid references public.matrix_duties_v2(id),
  required_count integer,
  assigned_count integer,
  message text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table solver_private.optimization_snapshots_v2 (
  run_id uuid primary key references public.optimization_runs_v2(id) on delete cascade,
  schema_version integer not null check (schema_version > 0),
  snapshot_hash text not null check (snapshot_hash ~ '^[0-9a-f]{64}$'),
  snapshot jsonb not null,
  created_at timestamptz not null default now(),
  immutable boolean not null default true
);

create table solver_private.plan_variant_finance_v2 (
  variant_id uuid primary key references public.plan_variants_v2(id) on delete cascade,
  base_cost_units bigint not null default 0 check (base_cost_units >= 0),
  additions_cost_units bigint not null default 0 check (additions_cost_units >= 0),
  total_cost_units bigint not null default 0 check (total_cost_units >= 0),
  base_cost_minor bigint not null default 0 check (base_cost_minor >= 0),
  additions_cost_minor bigint not null default 0 check (additions_cost_minor >= 0),
  total_cost_minor bigint not null default 0 check (total_cost_minor >= 0),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  budget_minor bigint,
  hard_budget_exceeded boolean not null default false,
  breakdown jsonb not null default '{}'::jsonb,
  check (budget_minor is null or budget_minor >= 0),
  check (base_cost_units+additions_cost_units=total_cost_units),
  check (base_cost_minor+additions_cost_minor=total_cost_minor)
);

create table solver_private.plan_assignment_cost_components_v2 (
  id bigint generated always as identity primary key,
  assignment_id uuid not null references public.plan_assignments_v2(id) on delete cascade,
  pay_rule_id uuid references public.matrix_pay_rules_v2(id),
  component_code text not null,
  amount_minor bigint not null,
  quantity_minutes integer,
  calculation_basis jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique(assignment_id,pay_rule_id,component_code)
);

create index optimization_runs_v2_status_queue_idx
  on public.optimization_runs_v2(status,queued_at)
  where status in ('QUEUED','RUNNING','CANCEL_REQUESTED');
create index optimization_runs_v2_requester_month_idx
  on public.optimization_runs_v2(requested_by,month,created_at desc);
create index optimization_runs_v2_matrix_idx on public.optimization_runs_v2(matrix_version_id);
create index optimization_runs_v2_scenario_idx on public.optimization_runs_v2(scenario_id);
create index optimization_runs_v2_scope_role_idx on public.optimization_runs_v2(scope_role_id) where scope_role_id is not null;
create index optimization_attempts_v2_run_idx
  on solver_private.optimization_attempts_v2(run_id,attempt_number desc);
create index optimization_run_strategies_v2_run_idx on public.optimization_run_strategies_v2(run_id,ordinal);
create index optimization_run_strategies_v2_strategy_idx on public.optimization_run_strategies_v2(strategy_id);
create index plan_variants_v2_run_idx on public.plan_variants_v2(run_id,created_at);
create index plan_variants_v2_strategy_idx on public.plan_variants_v2(strategy_id);
create index plan_variants_v2_solution_idx on public.plan_variants_v2(run_id,solution_hash);
create index plan_variants_v2_equivalent_idx on public.plan_variants_v2(equivalent_to_variant_id)
  where equivalent_to_variant_id is not null;
create index plan_variants_v2_selected_by_idx on public.plan_variants_v2(selected_by)
  where selected_by is not null;
create index plan_shifts_v2_variant_date_idx on public.plan_shifts_v2(variant_id,shift_date,starts_at);
create index plan_shifts_v2_template_idx on public.plan_shifts_v2(shift_template_id);
create index plan_shifts_v2_location_idx on public.plan_shifts_v2(location_id);
create index plan_assignments_v2_variant_employee_idx on public.plan_assignments_v2(variant_id,employee_id);
create index plan_assignments_v2_shift_idx on public.plan_assignments_v2(shift_id);
create index plan_assignments_v2_employee_idx on public.plan_assignments_v2(employee_id);
create index plan_assignments_v2_role_idx on public.plan_assignments_v2(role_id);
create index plan_assignment_duties_v2_duty_idx on public.plan_assignment_duties_v2(duty_id);
create index plan_issues_v2_variant_severity_idx on public.plan_issues_v2(variant_id,severity);
create index plan_issues_v2_shift_idx on public.plan_issues_v2(shift_id) where shift_id is not null;
create index plan_issues_v2_role_idx on public.plan_issues_v2(role_id) where role_id is not null;
create index plan_issues_v2_duty_idx on public.plan_issues_v2(duty_id) where duty_id is not null;
create index plan_assignment_cost_components_v2_assignment_idx
  on solver_private.plan_assignment_cost_components_v2(assignment_id);
create index plan_assignment_cost_components_v2_rule_idx
  on solver_private.plan_assignment_cost_components_v2(pay_rule_id) where pay_rule_id is not null;

alter table public.optimization_runs_v2 enable row level security;
alter table public.optimization_run_strategies_v2 enable row level security;
alter table public.plan_variants_v2 enable row level security;
alter table public.plan_shifts_v2 enable row level security;
alter table public.plan_assignments_v2 enable row level security;
alter table public.plan_assignment_duties_v2 enable row level security;
alter table public.plan_issues_v2 enable row level security;

create policy optimization_runs_v2_read on public.optimization_runs_v2
for select to authenticated using (
  requested_by=(select auth.uid())
  or (select public.has_app_role('OWNER'))
  or (select public.has_app_role('ADMIN'))
);

create policy optimization_run_strategies_v2_read on public.optimization_run_strategies_v2
for select to authenticated using (exists(
  select 1 from public.optimization_runs_v2 r
  where r.id=run_id and (
    r.requested_by=(select auth.uid())
    or (select public.has_app_role('OWNER'))
    or (select public.has_app_role('ADMIN'))
  )
));

create policy plan_variants_v2_read on public.plan_variants_v2
for select to authenticated using (exists(
  select 1 from public.optimization_runs_v2 r
  where r.id=run_id and (
    r.requested_by=(select auth.uid())
    or (select public.has_app_role('OWNER'))
    or (select public.has_app_role('ADMIN'))
  )
));

create policy plan_shifts_v2_read on public.plan_shifts_v2
for select to authenticated using (exists(
  select 1 from public.plan_variants_v2 v
  join public.optimization_runs_v2 r on r.id=v.run_id
  where v.id=variant_id and (
    r.requested_by=(select auth.uid())
    or (select public.has_app_role('OWNER'))
    or (select public.has_app_role('ADMIN'))
  )
));

create policy plan_assignments_v2_read on public.plan_assignments_v2
for select to authenticated using (exists(
  select 1 from public.plan_variants_v2 v
  join public.optimization_runs_v2 r on r.id=v.run_id
  where v.id=variant_id and (
    r.requested_by=(select auth.uid())
    or (select public.has_app_role('OWNER'))
    or (select public.has_app_role('ADMIN'))
  )
));

create policy plan_assignment_duties_v2_read on public.plan_assignment_duties_v2
for select to authenticated using (exists(
  select 1 from public.plan_assignments_v2 a
  join public.plan_variants_v2 v on v.id=a.variant_id
  join public.optimization_runs_v2 r on r.id=v.run_id
  where a.id=assignment_id and (
    r.requested_by=(select auth.uid())
    or (select public.has_app_role('OWNER'))
    or (select public.has_app_role('ADMIN'))
  )
));

create policy plan_issues_v2_read on public.plan_issues_v2
for select to authenticated using (exists(
  select 1 from public.plan_variants_v2 v
  join public.optimization_runs_v2 r on r.id=v.run_id
  where v.id=variant_id and (
    r.requested_by=(select auth.uid())
    or (select public.has_app_role('OWNER'))
    or (select public.has_app_role('ADMIN'))
  )
));

revoke all on public.optimization_runs_v2,
  public.optimization_run_strategies_v2,
  public.plan_variants_v2,
  public.plan_shifts_v2,
  public.plan_assignments_v2,
  public.plan_assignment_duties_v2,
  public.plan_issues_v2 from public,anon,authenticated;

grant select on public.optimization_runs_v2,
  public.optimization_run_strategies_v2,
  public.plan_variants_v2,
  public.plan_shifts_v2,
  public.plan_assignments_v2,
  public.plan_assignment_duties_v2,
  public.plan_issues_v2 to authenticated;

grant all on public.optimization_runs_v2,
  public.optimization_run_strategies_v2,
  public.plan_variants_v2,
  public.plan_shifts_v2,
  public.plan_assignments_v2,
  public.plan_assignment_duties_v2,
  public.plan_issues_v2 to service_role;
grant usage,select on sequence public.plan_issues_v2_id_seq to service_role;

revoke all on all tables in schema solver_private from public,anon,authenticated;
revoke all on all sequences in schema solver_private from public,anon,authenticated;
grant all on all tables in schema solver_private to service_role;
grant usage,select on all sequences in schema solver_private to service_role;

do $$
begin
  if not exists(select 1 from pgmq.meta where queue_name='schedule_optimizer_v2') then
    perform pgmq.create('schedule_optimizer_v2');
  end if;
end $$;

revoke all on schema pgmq from public,anon,authenticated;
revoke all on all tables in schema pgmq from public,anon,authenticated;
revoke all on all sequences in schema pgmq from public,anon,authenticated;

do $$
begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime') then
    if not exists(
      select 1 from pg_publication_tables
      where pubname='supabase_realtime' and schemaname='public' and tablename='optimization_runs_v2'
    ) then
      alter publication supabase_realtime add table public.optimization_runs_v2;
    end if;
    if not exists(
      select 1 from pg_publication_tables
      where pubname='supabase_realtime' and schemaname='public' and tablename='optimization_run_strategies_v2'
    ) then
      alter publication supabase_realtime add table public.optimization_run_strategies_v2;
    end if;
  end if;
end $$;

comment on table solver_private.optimization_snapshots_v2 is
  'Immutable, finance-bearing solver input. Never expose through the Data API or Realtime.';
comment on table public.optimization_runs_v2 is
  'Sanitized run status projection. Snapshot and pay data live in solver_private.';
