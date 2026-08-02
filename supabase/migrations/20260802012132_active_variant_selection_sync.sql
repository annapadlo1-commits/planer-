-- Express the selection fence as an explicit positive provenance match. This
-- fails closed for a missing run as well as SHADOW or stale-version runs.

create or replace function public.optimizer_select_variant_v2(
  p_run_id uuid,
  p_variant_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_engine text;
  v_enabled boolean;
  v_active_solver_version text;
begin
  perform solver_private.lock_planning_revision_v2();
  select flag.engine,flag.enabled into v_engine,v_enabled
  from public.solver_feature_flags flag
  where flag.flag_key='DEFAULT_ENGINE';
  if v_enabled is distinct from true
    or v_engine is distinct from 'ORTOOLS_V2' then
    raise exception 'ORTOOLS_SELECTION_DISABLED';
  end if;
  v_active_solver_version :=
    solver_private.active_ortools_solver_version_v2();

  if not exists(
    select 1 from public.optimization_runs_v2 run
    where run.id=p_run_id
      and run.request_engine='ORTOOLS_V2'
      and run.solver_version=v_active_solver_version
  ) then raise exception 'RUN_SOLVER_VERSION_NOT_ACTIVE'; end if;

  return solver_private.optimizer_select_variant_pre_version_fence_v2(
    p_run_id,p_variant_id
  );
end;
$$;

revoke all on function public.optimizer_select_variant_v2(uuid,uuid)
  from public,anon;
grant execute on function public.optimizer_select_variant_v2(uuid,uuid)
  to authenticated;
