-- B4F-166: persist complete stage proof and a reproducible component stamp.
-- This migration is audit-only: it does not change any solver objective,
-- constraint, weight, tolerance or strategy ordering.

alter table public.optimization_runs_v2
  add column if not exists version_stamp jsonb not null default '{}'::jsonb;

alter table public.plan_variants_v2
  add column if not exists stage_proof jsonb not null default '[]'::jsonb,
  add column if not exists version_stamp jsonb not null default '{}'::jsonb;

alter table public.optimization_runs_v2
  add constraint optimization_runs_v2_version_stamp_object_b4f166
  check (jsonb_typeof(version_stamp)='object');

alter table public.plan_variants_v2
  add constraint plan_variants_v2_stage_proof_array_b4f166
  check (jsonb_typeof(stage_proof)='array'),
  add constraint plan_variants_v2_version_stamp_object_b4f166
  check (jsonb_typeof(version_stamp)='object');

comment on column public.optimization_runs_v2.version_stamp is
  'B4F-166 immutable runtime component identity for a solver run.';
comment on column public.plan_variants_v2.stage_proof is
  'B4F-166 ordered CP-SAT stage proof: status, value, frozen bound, tolerance, budget, elapsed and fallback.';
comment on column public.plan_variants_v2.version_stamp is
  'B4F-166 frontend, solver, gateway, database, Matrix strategy and snapshot identity used by this variant.';

create or replace function solver_private.validate_stage_proof_b4f166(
  p_stage_proof jsonb
) returns void
language plpgsql
immutable
security definer
set search_path=''
as $$
declare
  v_stage jsonb;
begin
  if jsonb_typeof(p_stage_proof)<>'array'
    or jsonb_array_length(p_stage_proof) not between 1 and 1000 then
    raise exception 'STAGE_PROOF_REQUIRED';
  end if;

  for v_stage in select item.value from jsonb_array_elements(p_stage_proof) item(value)
  loop
    if jsonb_typeof(v_stage)<>'object'
      or not (v_stage ?& array[
        'tier','name','status','value','frozenUpperBound','tolerance',
        'timeBudgetSeconds','elapsedSeconds','usedFallback'
      ]) then
      raise exception 'STAGE_PROOF_INCOMPLETE';
    end if;
    if jsonb_typeof(v_stage->'tier')<>'number'
      or jsonb_typeof(v_stage->'name')<>'string'
      or length(v_stage->>'name') not between 1 and 100
      or jsonb_typeof(v_stage->'status')<>'string'
      or length(v_stage->>'status') not between 1 and 40
      or jsonb_typeof(v_stage->'value')<>'number'
      or jsonb_typeof(v_stage->'frozenUpperBound')<>'number'
      or jsonb_typeof(v_stage->'tolerance')<>'number'
      or (v_stage->>'tolerance')::numeric<0
      or jsonb_typeof(v_stage->'timeBudgetSeconds')<>'number'
      or (v_stage->>'timeBudgetSeconds')::numeric not between 0 and 86400
      or jsonb_typeof(v_stage->'elapsedSeconds')<>'number'
      or (v_stage->>'elapsedSeconds')::numeric not between 0 and 86400
      or jsonb_typeof(v_stage->'usedFallback')<>'boolean' then
      raise exception 'STAGE_PROOF_INVALID';
    end if;
  end loop;
end;
$$;

revoke all on function solver_private.validate_stage_proof_b4f166(jsonb)
  from public,anon,authenticated,service_role;

create or replace function public.optimizer_request_v2(
  p_month date,
  p_scenario_id uuid,
  p_scope_type text,
  p_scope_role_id uuid,
  p_name text,
  p_idempotency_key text,
  p_frontend_version text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_result jsonb;
  v_run_id uuid;
  v_existing_frontend_version text;
begin
  if p_frontend_version is null
    or p_frontend_version !~ '^[A-Za-z0-9][A-Za-z0-9._:@/-]{0,499}$' then
    raise exception 'FRONTEND_VERSION_INVALID';
  end if;

  v_result := public.optimizer_request_v2(
    p_month,p_scenario_id,p_scope_type,p_scope_role_id,p_name,p_idempotency_key
  );
  v_run_id := nullif(v_result#>>'{run,id}','')::uuid;
  if v_run_id is null then raise exception 'RUN_ID_MISSING'; end if;

  select r.version_stamp#>>'{frontend,buildId}'
  into v_existing_frontend_version
  from public.optimization_runs_v2 r
  where r.id=v_run_id
  for update;
  if v_existing_frontend_version is not null
    and v_existing_frontend_version<>p_frontend_version then
    raise exception 'IDEMPOTENCY_KEY_REUSED';
  end if;

  update public.optimization_runs_v2 r
  set version_stamp=jsonb_set(
        r.version_stamp,
        '{frontend}',
        jsonb_build_object('buildId',p_frontend_version),
        true
      ),
      updated_at=now()
  where r.id=v_run_id;

  return v_result||jsonb_build_object(
    'versionStamp',jsonb_build_object(
      'schemaVersion',1,
      'frontend',jsonb_build_object('buildId',p_frontend_version)
    )
  );
end;
$$;

revoke execute on function public.optimizer_request_v2(date,uuid,text,uuid,text,text)
  from public,anon,authenticated,service_role;
revoke all on function public.optimizer_request_v2(date,uuid,text,uuid,text,text,text)
  from public,anon,authenticated,service_role;
grant execute on function public.optimizer_request_v2(date,uuid,text,uuid,text,text,text)
  to authenticated;

create or replace function public.solver_save_variant_v2(
  p_run_id uuid,
  p_attempt_id uuid,
  p_lease_token uuid,
  p_variant jsonb,
  p_gateway_version text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_result jsonb;
  v_variant_id uuid;
  v_frontend_version text;
  v_solver_version text;
  v_snapshot_schema_version integer;
  v_snapshot_hash text;
  v_matrix_version_id uuid;
  v_matrix_version integer;
  v_matrix_content_hash text;
  v_strategy_semantics_version text;
  v_worker_id text;
  v_worker_version text;
  v_worker_execution_name text;
  v_version_stamp jsonb;
begin
  if p_gateway_version is null
    or p_gateway_version !~ '^[A-Za-z0-9][A-Za-z0-9._:@/-]{0,499}$' then
    raise exception 'GATEWAY_VERSION_INVALID';
  end if;
  perform solver_private.validate_stage_proof_b4f166(p_variant->'stageObjectives');

  select
    r.version_stamp#>>'{frontend,buildId}',
    r.solver_version,
    r.snapshot_schema_version,
    r.snapshot_hash,
    r.matrix_version_id,
    mv.version,
    mv.content_hash,
    mv.settings->>'strategySemanticsVersion',
    a.worker_id,
    a.worker_version,
    a.worker_execution_name
  into
    v_frontend_version,
    v_solver_version,
    v_snapshot_schema_version,
    v_snapshot_hash,
    v_matrix_version_id,
    v_matrix_version,
    v_matrix_content_hash,
    v_strategy_semantics_version,
    v_worker_id,
    v_worker_version,
    v_worker_execution_name
  from public.optimization_runs_v2 r
  join solver_private.optimization_attempts_v2 a
    on a.id=p_attempt_id and a.run_id=r.id
  join public.matrix_versions mv on mv.id=r.matrix_version_id
  where r.id=p_run_id;

  if v_frontend_version is null then
    raise exception 'FRONTEND_VERSION_STAMP_MISSING';
  end if;
  if v_solver_version is null or v_worker_version is null
    or v_matrix_content_hash is null or v_strategy_semantics_version is null then
    raise exception 'RUNTIME_VERSION_STAMP_INCOMPLETE';
  end if;

  v_version_stamp := jsonb_build_object(
    'schemaVersion',1,
    'frontend',jsonb_build_object('buildId',v_frontend_version),
    'solver',jsonb_strip_nulls(jsonb_build_object(
      'configuredVersion',v_solver_version,
      'workerVersion',v_worker_version,
      'workerId',v_worker_id,
      'workerExecutionName',v_worker_execution_name
    )),
    'gateway',jsonb_build_object('deploymentId',p_gateway_version),
    'database',jsonb_build_object(
      'schemaVersion','20260822173000_b4f166_stage_proof_version_stamp'
    ),
    'strategyConfig',jsonb_build_object(
      'matrixVersionId',v_matrix_version_id,
      'matrixVersion',v_matrix_version,
      'contentHash',v_matrix_content_hash,
      'strategySemanticsVersion',v_strategy_semantics_version
    ),
    'snapshot',jsonb_build_object(
      'schemaVersion',v_snapshot_schema_version,
      'snapshotHash',v_snapshot_hash
    )
  );

  v_result := public.solver_save_variant_v2(
    p_run_id,p_attempt_id,p_lease_token,p_variant
  );
  v_variant_id := nullif(v_result->>'variantId','')::uuid;
  if v_variant_id is null then raise exception 'VARIANT_ID_MISSING'; end if;

  update public.plan_variants_v2 v
  set stage_proof=p_variant->'stageObjectives',
      version_stamp=v_version_stamp
  where v.id=v_variant_id and v.run_id=p_run_id;
  if not found then raise exception 'VARIANT_NOT_FOUND'; end if;

  update public.optimization_runs_v2 r
  set version_stamp=v_version_stamp,
      updated_at=now()
  where r.id=p_run_id;

  return v_result||jsonb_build_object(
    'stageCount',jsonb_array_length(p_variant->'stageObjectives'),
    'versionStamp',v_version_stamp
  );
end;
$$;

revoke execute on function public.solver_save_variant_v2(uuid,uuid,uuid,jsonb)
  from public,anon,authenticated,service_role;
revoke all on function public.solver_save_variant_v2(uuid,uuid,uuid,jsonb,text)
  from public,anon,authenticated,service_role;
grant execute on function public.solver_save_variant_v2(uuid,uuid,uuid,jsonb,text)
  to service_role;

create or replace function public.optimizer_variants_v2(p_run_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare v_visibility text; v_variants jsonb;
begin
  if not solver_private.can_access_run_v2(p_run_id) then raise exception 'RUN_NOT_FOUND'; end if;
  v_visibility:=public.application_finance_visibility_current_uat_v1();
  select coalesce(jsonb_agg(
    case
      when v_visibility in ('FULL','AGGREGATE') then item
      when v_visibility='BUDGET_ONLY' then
        item-'totalCostMinor'-'budgetMinor'-'currency'||jsonb_build_object('budgetStatus',jsonb_build_object(
          'configured',item->'budgetMinor' is not null and jsonb_typeof(item->'budgetMinor')<>'null',
          'withinBudget',case when item->'budgetMinor' is null or jsonb_typeof(item->'budgetMinor')='null' then null
            else (item->>'totalCostMinor')::numeric <= (item->>'budgetMinor')::numeric end))
      else item-'totalCostMinor'-'budgetMinor'-'currency'
    end order by ordinal
  ),'[]'::jsonb) into v_variants
  from (
    select run_strategy.ordinal,jsonb_build_object(
      'id',variant.id,'name',variant.name,
      'strategy',jsonb_build_object('id',strategy.id,'name',strategy.name,'description',strategy.description),
      'status',variant.status,'hardViolations',variant.hard_violations,
      'assignmentCount',variant.assignment_count,'unfilledCount',variant.unfilled_count,
      'totalCostMinor',finance.total_cost_minor,'budgetMinor',finance.budget_minor,'currency',finance.currency,
      'solverStatus',variant.solver_status,'recommended',variant.recommended,'selected',variant.selected,
      'equivalentToVariantId',variant.equivalent_to_variant_id,'metrics',variant.metrics,
      'stageProof',variant.stage_proof,'versionStamp',variant.version_stamp) item
    from public.plan_variants_v2 variant
    join public.optimization_run_strategies_v2 run_strategy on run_strategy.id=variant.run_strategy_id
    join public.matrix_strategies_v2 strategy on strategy.id=variant.strategy_id
    left join solver_private.plan_variant_finance_v2 finance on finance.variant_id=variant.id
    where variant.run_id=p_run_id and variant.variant_kind='GENERATED'
  ) source;
  return jsonb_build_object('runId',p_run_id,'variants',v_variants);
end;
$$;

do $$
begin
  perform solver_private.validate_stage_proof_b4f166(jsonb_build_array(
    jsonb_build_object(
      'tier',0,'name','MIGRATION_CHECK','status','OPTIMAL','value',0,
      'frozenUpperBound',0,'tolerance',0,'timeBudgetSeconds',0,
      'elapsedSeconds',0,'usedFallback',false
    )
  ));
  if has_function_privilege(
    'authenticated',
    'public.optimizer_request_v2(date,uuid,text,uuid,text,text)',
    'EXECUTE'
  ) then raise exception 'LEGACY_REQUEST_RPC_STILL_EXPOSED'; end if;
  if not has_function_privilege(
    'authenticated',
    'public.optimizer_request_v2(date,uuid,text,uuid,text,text,text)',
    'EXECUTE'
  ) then raise exception 'VERSIONED_REQUEST_RPC_NOT_EXPOSED'; end if;
  if has_function_privilege(
    'service_role',
    'public.solver_save_variant_v2(uuid,uuid,uuid,jsonb)',
    'EXECUTE'
  ) then raise exception 'LEGACY_SAVE_RPC_STILL_EXPOSED'; end if;
  if not has_function_privilege(
    'service_role',
    'public.solver_save_variant_v2(uuid,uuid,uuid,jsonb,text)',
    'EXECUTE'
  ) then raise exception 'VERSIONED_SAVE_RPC_NOT_EXPOSED'; end if;
end;
$$;
