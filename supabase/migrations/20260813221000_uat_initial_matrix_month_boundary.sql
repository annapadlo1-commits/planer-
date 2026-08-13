-- UAT only: the first company setup is a monthly planning configuration.
-- The destructive UAT reset used the reset day (for example 2026-08-13)
-- as effective_from, while the optimizer resolves a monthly configuration at
-- the first day of the month. This made a freshly published configuration
-- visible in Settings but invisible to the generator for that same month.

create or replace function solver_private.normalize_initial_matrix_month_uat_v1()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  if new.version=1
    and new.status='DRAFT'
    and new.name='Pierwsza konfiguracja firmy'
    and not exists(select 1 from public.matrix_versions)
  then
    new.effective_from:=date_trunc('month',new.effective_from)::date;
  end if;
  return new;
end;
$$;

revoke all on function solver_private.normalize_initial_matrix_month_uat_v1()
  from public,anon,authenticated;

drop trigger if exists normalize_initial_matrix_month_uat_v1
  on public.matrix_versions;
create trigger normalize_initial_matrix_month_uat_v1
before insert on public.matrix_versions
for each row execute function solver_private.normalize_initial_matrix_month_uat_v1();

-- Published versions are immutable. For the already published first UAT
-- version we therefore resolve the only configuration created inside the
-- requested month, but only when no configuration existed on month day one.
-- This keeps the historical rule: a later mid-month publication cannot replace
-- a configuration that already covered the first day of that month.
create or replace function solver_private.matrix_covers_planning_month_uat_v1(
  p_effective_from date,
  p_month date
) returns boolean
language sql
stable
security definer
set search_path=''
as $$
  select p_effective_from<=date_trunc('month',p_month)::date
    or (
      p_effective_from<(date_trunc('month',p_month)+interval '1 month')::date
      and not exists(
        select 1 from public.matrix_versions prior_matrix
        where prior_matrix.status in ('ACTIVE','ARCHIVED')
          and prior_matrix.schema_version>=2
          and prior_matrix.effective_from<=date_trunc('month',p_month)::date
          and coalesce(prior_matrix.content_hash,'') ~ '^[0-9a-f]{64}$'
          and coalesce(prior_matrix.workforce_hash,'') ~ '^[0-9a-f]{64}$'
      )
    );
$$;

revoke all on function solver_private.matrix_covers_planning_month_uat_v1(date,date)
  from public,anon,authenticated;
grant execute on function solver_private.matrix_covers_planning_month_uat_v1(date,date)
  to service_role;

-- Keep every month-bound public workflow on one resolver. Recreating each
-- function from its current definition preserves its signature, owner,
-- security mode and grants while replacing only the month predicate.
do $$
declare
  function_row record;
  function_definition text;
begin
  for function_row in
    select procedure.oid
    from pg_catalog.pg_proc procedure
    join pg_catalog.pg_namespace namespace on namespace.oid=procedure.pronamespace
    where procedure.prokind='f'
      and namespace.nspname='public'
      and procedure.proname in (
        'employee_shift_preferences_self_v2',
        'employee_time_constraints_self_v2',
        'operational_program_preview_uat_v1',
        'operational_program_workspace_uat_v1',
        'optimizer_configuration_v2',
        'optimizer_demand_profiles_uat_v1',
        'optimizer_request_v2',
        'uat_master_employee_portal_context_v2',
        'workforce_calendar_context_uat_v2'
      )
  loop
    function_definition:=pg_catalog.pg_get_functiondef(function_row.oid);
    function_definition:=pg_catalog.regexp_replace(
      function_definition,
      '([a-z_][a-z0-9_]*)\\.effective_from\\s*<=\\s*v_month',
      'solver_private.matrix_covers_planning_month_uat_v1(\\1.effective_from,v_month)',
      'gi'
    );
    execute function_definition;
  end loop;
end;
$$;

comment on function solver_private.normalize_initial_matrix_month_uat_v1() is
  'UAT first-run guard: normalizes the initial reset draft to the first day of its planning month so monthly optimizer lookup and Settings use the same configuration.';

comment on function solver_private.matrix_covers_planning_month_uat_v1(date,date) is
  'UAT first-run fallback: resolves the first immutable configuration published inside a month only when no earlier configuration covered that month start.';
