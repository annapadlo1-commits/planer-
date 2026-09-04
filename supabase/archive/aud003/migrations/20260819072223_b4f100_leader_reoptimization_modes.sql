-- B4F-100: re-optimize only the unlocked portion of a Leader Studio draft.
-- The worker receives explicit locks and a baseline. Applying a result is an
-- atomic, revision-guarded replacement of unlocked assignments. PROPOSE_ONLY
-- runs are never applied automatically by the client.

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
  v_hash:=encode(extensions.digest(convert_to(solver_private.canonical_json_v2(v_snapshot),'UTF8'),'sha256'),'hex');
  update solver_private.optimization_snapshots_v2 set snapshot=v_snapshot,snapshot_hash=v_hash
    where run_id=v_new_run_id;
  update public.optimization_runs_v2 set snapshot_hash=v_hash where id=v_new_run_id;
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

create or replace function public.optimizer_leader_reoptimization_apply_uat_v1(
  p_leader_variant_id uuid,p_source_variant_id uuid,p_reason text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_actor uuid:=auth.uid();v_reason text:=trim(coalesce(p_reason,''));
  v_leader public.plan_variants_v2%rowtype;v_source public.plan_variants_v2%rowtype;
  v_source_snapshot jsonb;v_expected_revision integer;v_mode text;
  v_locked_count integer:=0;v_expected_replaced_count integer:=0;
  v_replaced_count integer:=0;v_result jsonb;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if length(v_reason)<3 then raise exception 'EDIT_REASON_REQUIRED'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_leader_variant_id) then raise exception 'LEADER_VARIANT_NOT_EDITABLE'; end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-edit:'||p_leader_variant_id::text,0));
  select * into v_leader from public.plan_variants_v2 where id=p_leader_variant_id for update;
  if v_leader.leader_workflow_status<>'DRAFT' then raise exception 'LEADER_OPTIMIZATION_DRAFT_REQUIRED'; end if;
  select * into v_source from public.plan_variants_v2 where id=p_source_variant_id
    and variant_kind='GENERATED' and status in ('READY','SELECTED') and hard_violations=0;
  if v_source.id is null then raise exception 'LEADER_OPTIMIZATION_SOURCE_INVALID'; end if;
  select snapshot into v_source_snapshot from solver_private.optimization_snapshots_v2 where run_id=v_source.run_id;
  if v_source_snapshot->'leaderStudioOptimization'->>'variantId' is distinct from p_leader_variant_id::text then
    raise exception 'LEADER_OPTIMIZATION_SOURCE_MISMATCH';
  end if;
  v_expected_revision:=(v_source_snapshot->'leaderStudioOptimization'->>'revision')::integer;
  v_mode:=v_source_snapshot->'leaderStudioOptimization'->>'mode';
  if v_leader.revision<>v_expected_revision then raise exception 'LEADER_OPTIMIZATION_DRAFT_CHANGED'; end if;

  select count(*) into v_locked_count from public.plan_assignments_v2 assignment
  where assignment.variant_id=p_leader_variant_id and assignment.locked;
  if exists(
    select 1 from public.plan_assignments_v2 locked_assignment
    where locked_assignment.variant_id=p_leader_variant_id and locked_assignment.locked
      and not exists(select 1 from public.plan_assignments_v2 source_assignment
        where source_assignment.variant_id=p_source_variant_id
          and source_assignment.slot_key=locked_assignment.slot_key
          and source_assignment.employee_id=locked_assignment.employee_id)
  ) then raise exception 'LEADER_OPTIMIZATION_LOCK_NOT_PRESERVED'; end if;
  if exists(
    select 1 from public.plan_assignments_v2 source_assignment
    join public.plan_shifts_v2 source_shift on source_shift.id=source_assignment.shift_id
    where source_assignment.variant_id=p_source_variant_id
      and not exists(select 1 from public.plan_shifts_v2 leader_shift
        where leader_shift.variant_id=p_leader_variant_id
          and leader_shift.slot_group_key=source_shift.slot_group_key)
  ) or exists(
    select 1 from public.plan_issues_v2 source_issue
    join public.plan_shifts_v2 source_shift on source_shift.id=source_issue.shift_id
    where source_issue.variant_id=p_source_variant_id
      and not exists(select 1 from public.plan_shifts_v2 leader_shift
        where leader_shift.variant_id=p_leader_variant_id
          and leader_shift.slot_group_key=source_shift.slot_group_key)
  ) then raise exception 'LEADER_OPTIMIZATION_SHIFT_MAPPING_MISSING'; end if;

  select count(*) into v_expected_replaced_count
  from public.plan_assignments_v2 source_assignment
  where source_assignment.variant_id=p_source_variant_id
    and not exists(select 1 from public.plan_assignments_v2 locked_assignment
      where locked_assignment.variant_id=p_leader_variant_id and locked_assignment.locked
        and locked_assignment.slot_key=source_assignment.slot_key);

  delete from public.plan_assignments_v2 assignment
  where assignment.variant_id=p_leader_variant_id and not assignment.locked;
  delete from public.plan_issues_v2 where variant_id=p_leader_variant_id;

  insert into public.plan_assignments_v2(
    id,variant_id,shift_id,slot_key,employee_id,role_id,locked,explanation,created_at
  )
  select public.matrix_v2_stable_uuid('LEADER_REOPT:'||p_leader_variant_id::text||':'||source_assignment.id::text),
    p_leader_variant_id,leader_shift.id,source_assignment.slot_key,source_assignment.employee_id,
    source_assignment.role_id,false,jsonb_build_object('edited',true,'editedBy',v_actor,'editedAt',now(),
      'reason',v_reason,'optimizationMode',v_mode,'optimizationSourceVariantId',p_source_variant_id),now()
  from public.plan_assignments_v2 source_assignment
  join public.plan_shifts_v2 source_shift on source_shift.id=source_assignment.shift_id
  join public.plan_shifts_v2 leader_shift on leader_shift.variant_id=p_leader_variant_id
    and leader_shift.slot_group_key=source_shift.slot_group_key
  where source_assignment.variant_id=p_source_variant_id
    and not exists(select 1 from public.plan_assignments_v2 locked_assignment
      where locked_assignment.variant_id=p_leader_variant_id and locked_assignment.locked
        and locked_assignment.slot_key=source_assignment.slot_key)
  on conflict do nothing;
  get diagnostics v_replaced_count=row_count;
  if v_replaced_count<>v_expected_replaced_count then
    raise exception 'LEADER_OPTIMIZATION_ASSIGNMENT_COPY_INCOMPLETE';
  end if;

  insert into public.plan_assignment_duties_v2(assignment_id,duty_id)
  select public.matrix_v2_stable_uuid('LEADER_REOPT:'||p_leader_variant_id::text||':'||source_assignment.id::text),
    duty.duty_id
  from public.plan_assignments_v2 source_assignment
  join public.plan_assignment_duties_v2 duty on duty.assignment_id=source_assignment.id
  where source_assignment.variant_id=p_source_variant_id
    and exists(select 1 from public.plan_assignments_v2 leader_assignment
      where leader_assignment.id=public.matrix_v2_stable_uuid(
        'LEADER_REOPT:'||p_leader_variant_id::text||':'||source_assignment.id::text))
  on conflict do nothing;

  insert into public.plan_issues_v2(variant_id,shift_id,slot_key,issue_code,severity,role_id,duty_id,
    required_count,assigned_count,message,metadata,created_at)
  select p_leader_variant_id,leader_shift.id,source_issue.slot_key,source_issue.issue_code,
    source_issue.severity,source_issue.role_id,source_issue.duty_id,source_issue.required_count,
    source_issue.assigned_count,source_issue.message,coalesce(source_issue.metadata,'{}'::jsonb)||
      jsonb_build_object('optimizationMode',v_mode,'optimizationSourceVariantId',p_source_variant_id),now()
  from public.plan_issues_v2 source_issue
  left join public.plan_shifts_v2 source_shift on source_shift.id=source_issue.shift_id
  left join public.plan_shifts_v2 leader_shift on leader_shift.variant_id=p_leader_variant_id
    and leader_shift.slot_group_key=source_shift.slot_group_key
  where source_issue.variant_id=p_source_variant_id;

  v_result:=solver_private.refresh_leader_variant_uat_v1(p_leader_variant_id,v_actor,v_reason);
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'plan_variant_v2',p_leader_variant_id::text,'APPLY_LEADER_OPTIMIZATION',jsonb_build_object(
    'sourceVariantId',p_source_variant_id,'sourceRunId',v_source.run_id,'mode',v_mode,
    'lockedAssignments',v_locked_count,'replacedAssignments',v_replaced_count,'reason',v_reason));
  return v_result||jsonb_build_object('sourceVariantId',p_source_variant_id,'mode',v_mode,
    'lockedAssignments',v_locked_count,'replacedAssignments',v_replaced_count);
end;$$;

revoke all on function public.optimizer_leader_reoptimization_request_uat_v1(uuid,text,text,text),
  public.optimizer_leader_reoptimization_apply_uat_v1(uuid,uuid,text)
  from public,anon,authenticated;
grant execute on function public.optimizer_leader_reoptimization_request_uat_v1(uuid,text,text,text),
  public.optimizer_leader_reoptimization_apply_uat_v1(uuid,uuid,text)
  to authenticated;

comment on function public.optimizer_leader_reoptimization_request_uat_v1(uuid,text,text,text)
is 'B4F-100: queues cost, fairness or propose-only optimization with only explicit leader locks fixed.';
comment on function public.optimizer_leader_reoptimization_apply_uat_v1(uuid,uuid,text)
is 'B4F-100: atomically replaces only unlocked leader assignments when the draft revision is unchanged.';

notify pgrst,'reload schema';
