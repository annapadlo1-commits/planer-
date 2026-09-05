-- B4F-100 regression: optimizer_request_v2 returns the run identifier inside
-- the `run` object. The first refill wrapper looked for a top-level `runId`,
-- raised RUN_ID_MISSING and rolled the whole request back.
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
  v_hash:=encode(extensions.digest(convert_to(solver_private.canonical_json_v2(v_snapshot),'UTF8'),'sha256'),'hex');
  update solver_private.optimization_snapshots_v2 set snapshot=v_snapshot,snapshot_hash=v_hash
    where run_id=v_refill_run_id;
  update public.optimization_runs_v2 set snapshot_hash=v_hash where id=v_refill_run_id;
  update public.optimization_run_strategies_v2 set metrics=coalesce(metrics,'{}'::jsonb)||
    jsonb_build_object('leaderRefillVariantId',p_variant_id,'leaderRefillRevision',v_variant.revision)
    where run_id=v_refill_run_id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'plan_variant_v2',p_variant_id::text,'REQUEST_LEADER_REFILL',jsonb_build_object(
    'runId',v_refill_run_id,'revision',v_variant.revision,
    'lockedAssignments',jsonb_array_length(v_locked),'reason',v_reason));
  return v_requested||jsonb_build_object(
    'runId',v_refill_run_id,'leaderVariantId',p_variant_id,'leaderRevision',v_variant.revision
  );
end;$$;

revoke all on function public.optimizer_leader_refill_request_uat_v1(uuid,text,text)
  from public,anon,authenticated;
grant execute on function public.optimizer_leader_refill_request_uat_v1(uuid,text,text)
  to authenticated;

comment on function public.optimizer_leader_refill_request_uat_v1(uuid,text,text)
is 'B4F-100: queues a fill-only run, resolves optimizer_request_v2 run.id and returns a stable top-level runId.';

notify pgrst,'reload schema';
