create or replace function public.optimizer_leader_assignment_drag_uat_v1(
  p_variant_id uuid,
  p_source_assignment_id uuid,
  p_target_assignment_id uuid default null,
  p_target_issue_id bigint default null,
  p_reason text default 'Przeciągnięcie w Studio lidera'
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid:=auth.uid();
  v_reason text:=trim(coalesce(p_reason,''));
  v_source public.plan_assignments_v2%rowtype;
  v_target public.plan_assignments_v2%rowtype;
  v_issue public.plan_issues_v2%rowtype;
  v_source_context jsonb;v_target_context jsonb;v_candidate jsonb;
  v_snapshot jsonb;v_slot jsonb;v_new_assignment_id uuid;v_source_duty_id uuid;
begin
  if length(v_reason)<3 then raise exception 'EDIT_REASON_REQUIRED'; end if;
  if (p_target_assignment_id is null)=(p_target_issue_id is null) then
    raise exception 'DRAG_TARGET_REQUIRED';
  end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then
    raise exception 'LEADER_VARIANT_NOT_EDITABLE';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-edit:'||p_variant_id::text,0));
  select * into v_source from public.plan_assignments_v2
    where id=p_source_assignment_id and variant_id=p_variant_id for update;
  if v_source.id is null then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
  if v_source.locked then raise exception 'LOCKED_ASSIGNMENT_CANNOT_BE_REMOVED'; end if;

  if p_target_assignment_id is not null then
    if p_target_assignment_id=p_source_assignment_id then raise exception 'DRAG_TARGET_UNCHANGED'; end if;
    select * into v_target from public.plan_assignments_v2
      where id=p_target_assignment_id and variant_id=p_variant_id for update;
    if v_target.id is null then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
    if v_target.locked then raise exception 'LOCKED_ASSIGNMENT_CANNOT_BE_REMOVED'; end if;
    v_target_context:=public.optimizer_leader_assignment_context_uat_v4(
      p_variant_id,p_target_assignment_id,null);
    select value into v_candidate from jsonb_array_elements(coalesce(v_target_context->'candidates','[]'::jsonb))
      where value->>'employeeId'=v_source.employee_id::text;
    if v_candidate is null or not coalesce((v_candidate->>'workPatternAllowed')::boolean,false)
      or coalesce(v_candidate->>'dutyCoverageMode','NOT_COVERED')<>'DIRECT' then
      raise exception 'VARIANT_EMPLOYEE_ELIGIBILITY_INVALID';
    end if;
    v_source_context:=public.optimizer_leader_assignment_context_uat_v4(
      p_variant_id,p_source_assignment_id,null);
    select value into v_candidate from jsonb_array_elements(coalesce(v_source_context->'candidates','[]'::jsonb))
      where value->>'employeeId'=v_target.employee_id::text;
    if v_candidate is null or not coalesce((v_candidate->>'workPatternAllowed')::boolean,false)
      or coalesce(v_candidate->>'dutyCoverageMode','NOT_COVERED')<>'DIRECT' then
      raise exception 'VARIANT_EMPLOYEE_ELIGIBILITY_INVALID';
    end if;
    update public.plan_assignments_v2 set employee_id=v_target.employee_id,
      explanation=coalesce(explanation,'{}'::jsonb)||jsonb_build_object(
        'edited',true,'editedBy',v_actor,'editedAt',now(),'reason',v_reason,
        'dragOperation','SWAP','pairedAssignmentId',v_target.id)
      where id=v_source.id;
    update public.plan_assignments_v2 set employee_id=v_source.employee_id,
      explanation=coalesce(explanation,'{}'::jsonb)||jsonb_build_object(
        'edited',true,'editedBy',v_actor,'editedAt',now(),'reason',v_reason,
        'dragOperation','SWAP','pairedAssignmentId',v_source.id)
      where id=v_target.id;
  else
    select * into v_issue from public.plan_issues_v2
      where id=p_target_issue_id and variant_id=p_variant_id and issue_code='UNFILLED_SLOT' for update;
    if v_issue.id is null then raise exception 'UNFILLED_ISSUE_NOT_FOUND'; end if;
    v_target_context:=public.optimizer_leader_assignment_context_uat_v4(
      p_variant_id,null,p_target_issue_id);
    select value into v_candidate from jsonb_array_elements(coalesce(v_target_context->'candidates','[]'::jsonb))
      where value->>'employeeId'=v_source.employee_id::text;
    if v_candidate is null or not coalesce((v_candidate->>'workPatternAllowed')::boolean,false)
      or coalesce(v_candidate->>'dutyCoverageMode','NOT_COVERED')<>'DIRECT' then
      raise exception 'VARIANT_EMPLOYEE_ELIGIBILITY_INVALID';
    end if;
    select snapshot into v_snapshot from solver_private.optimization_snapshots_v2 snapshot
      join public.plan_variants_v2 variant on variant.run_id=snapshot.run_id where variant.id=p_variant_id;
    insert into public.plan_assignments_v2(variant_id,shift_id,slot_key,employee_id,role_id,locked,explanation)
    values(p_variant_id,v_issue.shift_id,v_issue.slot_key,v_source.employee_id,v_issue.role_id,false,
      jsonb_build_object('edited',true,'editedBy',v_actor,'editedAt',now(),'reason',v_reason,
        'dragOperation','MOVE','sourceAssignmentId',v_source.id,'filledIssueId',v_issue.id))
    returning id into v_new_assignment_id;
    select slot.value into v_slot from jsonb_array_elements(coalesce(v_snapshot->'slots','[]'::jsonb)) slot
      where slot.value->>'slotId'=v_issue.slot_key;
    insert into public.plan_assignment_duties_v2(assignment_id,duty_id)
    select v_new_assignment_id,(duty.value#>>'{}')::uuid
      from jsonb_array_elements(coalesce(v_slot->'dutyIds','[]'::jsonb)) duty;
    delete from public.plan_issues_v2 where id=v_issue.id;
    select duty_id into v_source_duty_id from public.plan_assignment_duties_v2
      where assignment_id=v_source.id order by duty_id limit 1;
    insert into public.plan_issues_v2(variant_id,shift_id,slot_key,issue_code,severity,role_id,duty_id,
      required_count,assigned_count,message,metadata)
    values(p_variant_id,v_source.shift_id,v_source.slot_key,'UNFILLED_SLOT','WARNING',v_source.role_id,
      v_source_duty_id,1,0,'Miejsce zwolnione przez przeniesienie w Studio lidera.',
      jsonb_build_object('movedAssignmentId',v_source.id,'reason',v_reason));
    delete from public.plan_assignments_v2 where id=v_source.id;
  end if;
  return solver_private.refresh_leader_variant_uat_v1(p_variant_id,v_actor,v_reason)
    ||jsonb_build_object('operation',case when p_target_assignment_id is null then 'MOVE' else 'SWAP' end,
      'sourceAssignmentId',p_source_assignment_id,'targetAssignmentId',p_target_assignment_id,
      'targetIssueId',p_target_issue_id,'newAssignmentId',v_new_assignment_id);
end;
$$;

revoke all on function public.optimizer_leader_assignment_drag_uat_v1(uuid,uuid,uuid,bigint,text)
  from public,anon,authenticated;
grant execute on function public.optimizer_leader_assignment_drag_uat_v1(uuid,uuid,uuid,bigint,text)
  to authenticated;
