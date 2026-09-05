-- B4F-100: the optimizer may fill only the remaining vacancies of one leader
-- draft. Existing assignments are injected as immutable locks and the result
-- can be applied only if the draft revision has not changed in the meantime.

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
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then raise exception 'LEADER_VARIANT_NOT_EDITABLE'; end if;
  select * into v_variant from public.plan_variants_v2 where id=p_variant_id for update;
  select * into v_run from public.optimization_runs_v2 where id=v_variant.run_id;
  v_requested:=public.optimizer_request_v2(v_run.month,v_run.scenario_id,v_run.scope_type,
    v_run.scope_role_id,left('Uzupełnienie wakatów • '||v_variant.name,200),p_idempotency_key);
  v_refill_run_id:=nullif(v_requested->>'runId','')::uuid;
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
    'runId',v_refill_run_id,'revision',v_variant.revision,'lockedAssignments',jsonb_array_length(v_locked),'reason',v_reason));
  return v_requested||jsonb_build_object('leaderVariantId',p_variant_id,'leaderRevision',v_variant.revision);
end;$$;

create or replace function public.optimizer_leader_refill_apply_uat_v1(
  p_leader_variant_id uuid,p_source_variant_id uuid,p_reason text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_actor uuid:=auth.uid();v_reason text:=trim(coalesce(p_reason,''));
  v_leader public.plan_variants_v2%rowtype;v_source public.plan_variants_v2%rowtype;
  v_source_snapshot jsonb;v_expected_revision integer;v_added integer:=0;v_result jsonb;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if length(v_reason)<3 then raise exception 'EDIT_REASON_REQUIRED'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_leader_variant_id) then raise exception 'LEADER_VARIANT_NOT_EDITABLE'; end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-edit:'||p_leader_variant_id::text,0));
  select * into v_leader from public.plan_variants_v2 where id=p_leader_variant_id for update;
  select * into v_source from public.plan_variants_v2 where id=p_source_variant_id
    and variant_kind='GENERATED' and status in ('READY','SELECTED') and hard_violations=0;
  if v_source.id is null then raise exception 'LEADER_REFILL_SOURCE_INVALID'; end if;
  select snapshot into v_source_snapshot from solver_private.optimization_snapshots_v2 where run_id=v_source.run_id;
  if v_source_snapshot->'leaderStudioRefill'->>'variantId' is distinct from p_leader_variant_id::text then
    raise exception 'LEADER_REFILL_SOURCE_MISMATCH';
  end if;
  v_expected_revision:=(v_source_snapshot->'leaderStudioRefill'->>'revision')::integer;
  if v_leader.revision<>v_expected_revision then raise exception 'LEADER_REFILL_DRAFT_CHANGED'; end if;

  insert into public.plan_assignments_v2(id,variant_id,shift_id,slot_key,employee_id,role_id,locked,explanation,created_at)
  select public.matrix_v2_stable_uuid('LEADER_REFILL:'||p_leader_variant_id::text||':'||source.id::text),
    p_leader_variant_id,issue.shift_id,source.slot_key,source.employee_id,source.role_id,false,
    jsonb_build_object('edited',true,'editedBy',v_actor,'editedAt',now(),'reason',v_reason,
      'refillSourceVariantId',p_source_variant_id,'refillSourceAssignmentId',source.id),now()
  from public.plan_assignments_v2 source
  join public.plan_issues_v2 issue on issue.variant_id=p_leader_variant_id
    and issue.issue_code='UNFILLED_SLOT' and issue.slot_key=source.slot_key
  where source.variant_id=p_source_variant_id
  on conflict do nothing;
  get diagnostics v_added=row_count;
  insert into public.plan_assignment_duties_v2(assignment_id,duty_id)
  select public.matrix_v2_stable_uuid('LEADER_REFILL:'||p_leader_variant_id::text||':'||source.id::text),duty.duty_id
  from public.plan_assignments_v2 source join public.plan_assignment_duties_v2 duty on duty.assignment_id=source.id
  join public.plan_issues_v2 issue on issue.variant_id=p_leader_variant_id
    and issue.issue_code='UNFILLED_SLOT' and issue.slot_key=source.slot_key
  where source.variant_id=p_source_variant_id on conflict do nothing;
  delete from public.plan_issues_v2 issue where issue.variant_id=p_leader_variant_id
    and issue.issue_code='UNFILLED_SLOT' and exists(select 1 from public.plan_assignments_v2 assignment
      where assignment.variant_id=p_leader_variant_id and assignment.slot_key=issue.slot_key);
  v_result:=solver_private.refresh_leader_variant_uat_v1(p_leader_variant_id,v_actor,v_reason);
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'plan_variant_v2',p_leader_variant_id::text,'APPLY_LEADER_REFILL',jsonb_build_object(
    'sourceVariantId',p_source_variant_id,'sourceRunId',v_source.run_id,'addedAssignments',v_added,'reason',v_reason));
  return v_result||jsonb_build_object('addedAssignments',v_added,'sourceVariantId',p_source_variant_id);
end;$$;

revoke all on function public.optimizer_leader_refill_request_uat_v1(uuid,text,text),
  public.optimizer_leader_refill_apply_uat_v1(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.optimizer_leader_refill_request_uat_v1(uuid,text,text),
  public.optimizer_leader_refill_apply_uat_v1(uuid,uuid,text) to authenticated;

comment on function public.optimizer_leader_refill_request_uat_v1(uuid,text,text)
is 'B4F-100: queues a fill-only run with every current leader assignment locked.';
comment on function public.optimizer_leader_refill_apply_uat_v1(uuid,uuid,text)
is 'B4F-100: atomically applies only newly filled vacancies when the leader draft revision is unchanged.';
