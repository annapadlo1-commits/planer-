-- Persist the requested engine separately from the version string. This is
-- part of immutable run provenance and prevents SHADOW results from being
-- mistaken for production OR-Tools publications.

alter table public.optimization_runs_v2
  add column if not exists request_engine text;

update public.optimization_runs_v2
set request_engine='SHADOW'
where request_engine is null;

alter table public.optimization_runs_v2
  alter column request_engine set not null,
  alter column solver_version drop default;

do $$
begin
  if not exists(
    select 1 from pg_constraint
    where conrelid='public.optimization_runs_v2'::regclass
      and conname='optimization_runs_v2_request_engine_check'
  ) then
    alter table public.optimization_runs_v2
      add constraint optimization_runs_v2_request_engine_check
      check(request_engine in ('SHADOW','ORTOOLS_V2'));
  end if;
end;
$$;

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

drop trigger if exists optimization_runs_v2_provenance_immutable
  on public.optimization_runs_v2;
create trigger optimization_runs_v2_provenance_immutable
before update of request_engine,solver_version on public.optimization_runs_v2
for each row execute function solver_private.guard_run_provenance_v2();
