-- GRAFIK PRO 3.0 — one transactional revision boundary for every input that
-- can change a solver snapshot or the legality of an authoritative schedule.
--
-- API functions take this row lock before snapshotting, final validation and
-- publication. Statement triggers take the same lock when planning inputs are
-- changed. PostgreSQL therefore serializes the two boundaries without relying
-- on browser timing or an eventually-consistent revision check.

create schema if not exists solver_private;
revoke all on schema solver_private from public, anon, authenticated;
grant usage on schema solver_private to service_role;

create table solver_private.planning_data_revision_v2 (
  singleton boolean primary key default true check (singleton),
  revision bigint not null default 1 check (revision > 0),
  updated_at timestamptz not null default now()
);

insert into solver_private.planning_data_revision_v2(singleton,revision)
values (true,1)
on conflict (singleton) do nothing;

create or replace function solver_private.lock_planning_revision_v2()
returns bigint
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_revision bigint;
begin
  select r.revision
  into strict v_revision
  from solver_private.planning_data_revision_v2 r
  where r.singleton
  for update;
  return v_revision;
end;
$$;

create or replace function solver_private.bump_planning_revision_v2()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  update solver_private.planning_data_revision_v2
  set revision=revision+1,updated_at=clock_timestamp()
  where singleton;
  return null;
end;
$$;

-- These tables already exist before solver API functions are installed. A
-- statement-level trigger is deliberate: one bulk Matrix import creates one
-- revision, while still sharing the same transaction lock as every row write.
do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'matrix_versions',
    'matrix_roles_v2',
    'matrix_locations_v2',
    'matrix_duties_v2',
    'matrix_shift_templates_v2',
    'matrix_role_duties_v2',
    'matrix_scenarios_v2',
    'matrix_staffing_rules_v2',
    'matrix_strategies_v2',
    'matrix_strategy_objectives_v2',
    'matrix_scenario_strategies_v2',
    'matrix_employee_roles_v2',
    'matrix_employee_locations_v2',
    'matrix_employee_duties_v2',
    'employee_time_constraints_v2',
    'matrix_pay_rules_v2',
    'matrix_pay_rule_roles_v2',
    'matrix_pay_rule_duties_v2',
    'matrix_pay_rule_locations_v2',
    'matrix_pay_rule_shifts_v2',
    'matrix_scenario_pay_rule_overrides_v2',
    'matrix_scenario_budgets_v2',
    'employee_pay_rates_v2',
    'employees',
    'employee_hr_profiles',
    'employee_preferences',
    'employee_availability',
    'locations',
    'monthly_budgets',
    'plans',
    'shifts',
    'assignments',
    'plan_variants_v2',
    'plan_shifts_v2',
    'plan_assignments_v2',
    'plan_assignment_duties_v2'
  ]
  loop
    if to_regclass(format('public.%I',v_table)) is null then
      raise exception 'PLANNING_REVISION_TABLE_MISSING: %',v_table;
    end if;
    execute format(
      'drop trigger if exists planning_revision_v2_bump on public.%I',v_table
    );
    execute format(
      'create trigger planning_revision_v2_bump '
      'before insert or update or delete or truncate on public.%I '
      'for each statement execute function solver_private.bump_planning_revision_v2()',
      v_table
    );
  end loop;
end;
$$;

revoke all on table solver_private.planning_data_revision_v2
  from public, anon, authenticated;
revoke all on function solver_private.lock_planning_revision_v2()
  from public, anon, authenticated;
revoke all on function solver_private.bump_planning_revision_v2()
  from public, anon, authenticated;

grant select on table solver_private.planning_data_revision_v2 to service_role;
grant execute on function solver_private.lock_planning_revision_v2() to service_role;

comment on table solver_private.planning_data_revision_v2 is
  'Transactional serialization boundary for Matrix, workforce and authoritative schedule inputs.';
comment on function solver_private.lock_planning_revision_v2() is
  'Takes the exclusive transaction-scoped planning revision lock and returns the current revision.';
comment on function solver_private.bump_planning_revision_v2() is
  'Statement trigger that increments the planning revision while holding its transaction lock.';
