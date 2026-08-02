-- Complete the active-version publication boundary on branches that applied
-- an earlier optimizer publication draft. The public wrappers acquire the
-- global planning lock before any fence/idempotency check, and every new
-- production link is guarded by the exact active solver version.

drop trigger if exists published_schedule_variants_v2_production_only
  on public.published_schedule_variants_v2;
create trigger published_schedule_variants_v2_production_only
before insert on public.published_schedule_variants_v2
for each row execute function solver_private.guard_production_variant_link_v2();

create or replace function public.optimizer_publish_company_variant_v2(
  p_run_id uuid,
  p_variant_id uuid,
  p_name text,
  p_idempotency_key text
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
  v_request_engine text;
  v_run_solver_version text;
begin
  perform solver_private.lock_planning_revision_v2();
  select flag.engine,flag.enabled into v_engine,v_enabled
  from public.solver_feature_flags flag
  where flag.flag_key='DEFAULT_ENGINE';
  if v_enabled is distinct from true
    or v_engine is distinct from 'ORTOOLS_V2' then
    raise exception 'ORTOOLS_PUBLICATION_DISABLED';
  end if;
  v_active_solver_version :=
    solver_private.active_ortools_solver_version_v2();

  select run.request_engine,run.solver_version
  into v_request_engine,v_run_solver_version
  from public.optimization_runs_v2 run
  where run.id=p_run_id;
  if v_request_engine is not null
    and v_request_engine is distinct from 'ORTOOLS_V2' then
    raise exception 'SHADOW_RUN_NOT_PUBLISHABLE';
  end if;
  if v_request_engine is not null
    and v_run_solver_version is distinct from v_active_solver_version then
    raise exception 'RUN_SOLVER_VERSION_NOT_ACTIVE';
  end if;

  return
    solver_private.optimizer_publish_company_variant_pre_version_fence_v2(
      p_run_id,p_variant_id,p_name,p_idempotency_key
    );
end;
$$;

create or replace function public.optimizer_publish_role_composite_v2(
  p_month date,
  p_scenario_id uuid,
  p_variant_ids uuid[],
  p_name text,
  p_idempotency_key text
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
    raise exception 'ORTOOLS_PUBLICATION_DISABLED';
  end if;
  v_active_solver_version :=
    solver_private.active_ortools_solver_version_v2();

  if exists(
    select 1
    from public.plan_variants_v2 variant
    join public.optimization_runs_v2 run on run.id=variant.run_id
    where variant.id=any(p_variant_ids)
      and run.request_engine is distinct from 'ORTOOLS_V2'
  ) then raise exception 'SHADOW_RUN_NOT_PUBLISHABLE'; end if;
  if exists(
    select 1
    from public.plan_variants_v2 variant
    join public.optimization_runs_v2 run on run.id=variant.run_id
    where variant.id=any(p_variant_ids)
      and run.request_engine='ORTOOLS_V2'
      and run.solver_version is distinct from v_active_solver_version
  ) then raise exception 'RUN_SOLVER_VERSION_NOT_ACTIVE'; end if;

  return
    solver_private.optimizer_publish_role_composite_pre_version_fence_v2(
      p_month,p_scenario_id,p_variant_ids,p_name,p_idempotency_key
    );
end;
$$;

revoke all on function
  public.optimizer_publish_company_variant_v2(uuid,uuid,text,text)
  from public,anon;
revoke all on function
  public.optimizer_publish_role_composite_v2(date,uuid,uuid[],text,text)
  from public,anon;
grant execute on function
  public.optimizer_publish_company_variant_v2(uuid,uuid,text,text)
  to authenticated;
grant execute on function
  public.optimizer_publish_role_composite_v2(date,uuid,uuid[],text,text)
  to authenticated;
