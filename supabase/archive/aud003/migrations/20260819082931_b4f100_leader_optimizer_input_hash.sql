-- B4F-100 regression: a leader refill/re-optimization augments the immutable
-- solver snapshot with locks, a baseline and audit metadata.  The run-level
-- hash must keep representing only the published Matrix/workforce input,
-- because solver_finalize_v2 rebuilds that base snapshot to detect concurrent
-- configuration changes.  Replacing the run hash with the augmented worker
-- payload made every otherwise valid leader run finish as SNAPSHOT_CHANGED.

create or replace function public.optimizer_leader_refill_request_uat_v1(
  p_variant_id uuid,p_reason text,p_idempotency_key text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_actor uuid:=auth.uid();v_reason text:=trim(coalesce(p_reason,''));
  v_variant public.plan_variants_v2%rowtype;v_run public.optimization_runs_v2%rowtype;
  v_requested jsonb;v_refill_run_id uuid;v_snapshot jsonb;v_locked jsonb;v_hash text;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if length(v_reason)<3 then raise exception 'EDIT_REASON_REQUIRED'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then
    raise exception 'LEADER_VARIANT_NOT_EDITABLE';
  end if;
  select * into v_variant from public.plan_variants_v2 where id=p_variant_id for update;
  if v_variant.id is null then raise exception 'LEADER_VARIANT_NOT_FOUND'; end if;
  if v_variant.leader_workflow_status<>'DRAFT' then raise exception 'LEADER_REFILL_DRAFT_REQUIRED'; end if;
  select * into v_run from public.optimization_runs_v2 where id=v_variant.run_id;
  if v_run.id is null then raise exception 'LEADER_REFILL_BASE_RUN_NOT_FOUND'; end if;

  v_requested:=public.optimizer_request_v2(v_run.month,v_run.scenario_id,v_run.scope_type,
    v_run.scope_role_id,left('Uzupełnienie wakatów • '||v_variant.name,200),p_idempotency_key);
  v_refill_run_id:=coalesce(
    nullif(v_requested->>'runId',''),
    nullif(v_requested#>>'{run,id}','')
  )::uuid;
  if v_refill_run_id is null then raise exception 'RUN_ID_MISSING'; end if;

  select snapshot into v_snapshot from solver_private.optimization_snapshots_v2
    where run_id=v_refill_run_id for update;
  if v_snapshot is null then raise exception 'SNAPSHOT_NOT_FOUND'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('slotId',assignment.slot_key,
    'employeeId',assignment.employee_id) order by assignment.slot_key),'[]'::jsonb)
  into v_locked from public.plan_assignments_v2 assignment where assignment.variant_id=p_variant_id;
  v_snapshot:=jsonb_set(v_snapshot,'{lockedAssignments}',v_locked,true);
  v_snapshot:=jsonb_set(v_snapshot,'{baselineAssignments}',v_locked,true);
  v_snapshot:=jsonb_set(v_snapshot,'{leaderStudioRefill}',jsonb_build_object(
    'variantId',p_variant_id,'revision',v_variant.revision,'requestedBy',v_actor,
    'requestedAt',now(),'mode','FILL_REMAINING','reason',v_reason),true);
  v_hash:=encode(extensions.digest(convert_to(
    solver_private.canonical_json_v2(v_snapshot),'UTF8'
  ),'sha256'),'hex');
  update solver_private.optimization_snapshots_v2 set snapshot=v_snapshot,snapshot_hash=v_hash
    where run_id=v_refill_run_id;
  -- Deliberately do not replace optimization_runs_v2.snapshot_hash.  It is
  -- the base-input hash used by solver_finalize_v2 for stale-input detection.
  update public.optimization_run_strategies_v2 set metrics=coalesce(metrics,'{}'::jsonb)||
    jsonb_build_object('leaderRefillVariantId',p_variant_id,
      'leaderRefillRevision',v_variant.revision)
    where run_id=v_refill_run_id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'plan_variant_v2',p_variant_id::text,'REQUEST_LEADER_REFILL',jsonb_build_object(
    'runId',v_refill_run_id,'revision',v_variant.revision,
    'lockedAssignments',jsonb_array_length(v_locked),'reason',v_reason));
  return v_requested||jsonb_build_object(
    'runId',v_refill_run_id,'leaderVariantId',p_variant_id,'leaderRevision',v_variant.revision
  );
end;$$;

create or replace function public.optimizer_leader_reoptimization_request_uat_v1(
  p_variant_id uuid,p_mode text,p_reason text,p_idempotency_key text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_actor uuid:=auth.uid();v_mode text:=upper(trim(coalesce(p_mode,'')));
  v_reason text:=trim(coalesce(p_reason,''));v_variant public.plan_variants_v2%rowtype;
  v_run public.optimization_runs_v2%rowtype;v_requested jsonb;v_new_run_id uuid;
  v_snapshot jsonb;v_locked jsonb;v_baseline jsonb;v_hash text;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if v_mode not in ('COST','FAIRNESS','PROPOSE_ONLY') then raise exception 'LEADER_OPTIMIZATION_MODE_INVALID'; end if;
  if length(v_reason)<3 then raise exception 'EDIT_REASON_REQUIRED'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then raise exception 'LEADER_VARIANT_NOT_EDITABLE'; end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-edit:'||p_variant_id::text,0));
  select * into v_variant from public.plan_variants_v2 where id=p_variant_id for update;
  if v_variant.id is null then raise exception 'LEADER_VARIANT_NOT_FOUND'; end if;
  if v_variant.leader_workflow_status<>'DRAFT' then raise exception 'LEADER_OPTIMIZATION_DRAFT_REQUIRED'; end if;
  select * into v_run from public.optimization_runs_v2 where id=v_variant.run_id;
  if v_run.id is null then raise exception 'LEADER_OPTIMIZATION_BASE_RUN_NOT_FOUND'; end if;

  v_requested:=public.optimizer_request_v2(v_run.month,v_run.scenario_id,v_run.scope_type,
    v_run.scope_role_id,left(case v_mode when 'COST' then 'Optymalizacja kosztu • '
      when 'FAIRNESS' then 'Optymalizacja sprawiedliwości • ' else 'Propozycje zmian • ' end||v_variant.name,200),
    p_idempotency_key);
  v_new_run_id:=coalesce(nullif(v_requested->>'runId',''),nullif(v_requested#>>'{run,id}',''))::uuid;
  if v_new_run_id is null then raise exception 'RUN_ID_MISSING'; end if;
  select snapshot into v_snapshot from solver_private.optimization_snapshots_v2
    where run_id=v_new_run_id for update;
  if v_snapshot is null then raise exception 'SNAPSHOT_NOT_FOUND'; end if;

  select coalesce(jsonb_agg(jsonb_build_object('slotId',assignment.slot_key,
    'employeeId',assignment.employee_id) order by assignment.slot_key),'[]'::jsonb)
  into v_locked from public.plan_assignments_v2 assignment
  where assignment.variant_id=p_variant_id and assignment.locked;
  select coalesce(jsonb_agg(jsonb_build_object('slotId',assignment.slot_key,
    'employeeId',assignment.employee_id) order by assignment.slot_key),'[]'::jsonb)
  into v_baseline from public.plan_assignments_v2 assignment
  where assignment.variant_id=p_variant_id;

  v_snapshot:=jsonb_set(v_snapshot,'{lockedAssignments}',v_locked,true);
  v_snapshot:=jsonb_set(v_snapshot,'{baselineAssignments}',v_baseline,true);
  v_snapshot:=jsonb_set(v_snapshot,'{leaderStudioOptimization}',jsonb_build_object(
    'variantId',p_variant_id,'revision',v_variant.revision,'requestedBy',v_actor,
    'requestedAt',now(),'mode',v_mode,'reason',v_reason),true);
  v_hash:=encode(extensions.digest(convert_to(
    solver_private.canonical_json_v2(v_snapshot),'UTF8'
  ),'sha256'),'hex');
  update solver_private.optimization_snapshots_v2 set snapshot=v_snapshot,snapshot_hash=v_hash
    where run_id=v_new_run_id;
  -- Keep optimization_runs_v2.snapshot_hash on the published input.  The
  -- augmented hash remains on optimization_snapshots_v2 and every saved plan.
  update public.optimization_run_strategies_v2 set metrics=coalesce(metrics,'{}'::jsonb)||
    jsonb_build_object('leaderOptimizationVariantId',p_variant_id,
      'leaderOptimizationRevision',v_variant.revision,'leaderOptimizationMode',v_mode)
    where run_id=v_new_run_id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'plan_variant_v2',p_variant_id::text,'REQUEST_LEADER_OPTIMIZATION',jsonb_build_object(
    'runId',v_new_run_id,'revision',v_variant.revision,'mode',v_mode,
    'lockedAssignments',jsonb_array_length(v_locked),'baselineAssignments',jsonb_array_length(v_baseline),
    'reason',v_reason));
  return v_requested||jsonb_build_object('runId',v_new_run_id,'leaderVariantId',p_variant_id,
    'leaderRevision',v_variant.revision,'mode',v_mode,'lockedAssignments',jsonb_array_length(v_locked));
end;$$;

revoke all on function public.optimizer_leader_refill_request_uat_v1(uuid,text,text),
  public.optimizer_leader_reoptimization_request_uat_v1(uuid,text,text,text)
  from public,anon,authenticated;
grant execute on function public.optimizer_leader_refill_request_uat_v1(uuid,text,text),
  public.optimizer_leader_reoptimization_request_uat_v1(uuid,text,text,text)
  to authenticated;

comment on function public.optimizer_leader_refill_request_uat_v1(uuid,text,text)
is 'B4F-100: queues fill-only optimization while keeping stale-input validation bound to the published configuration hash.';
comment on function public.optimizer_leader_reoptimization_request_uat_v1(uuid,text,text,text)
is 'B4F-100: queues leader re-optimization while keeping stale-input validation bound to the published configuration hash.';

notify pgrst,'reload schema';
