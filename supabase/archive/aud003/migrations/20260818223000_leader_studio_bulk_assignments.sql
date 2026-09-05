create or replace function public.optimizer_leader_assignments_bulk_uat_v1(
  p_variant_id uuid,p_assignment_ids uuid[],p_operation text,p_reason text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_actor uuid:=auth.uid();v_operation text:=upper(trim(coalesce(p_operation,'')));
  v_expected integer;v_found integer;v_locked integer;v_result jsonb;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then raise exception 'LEADER_VARIANT_FORBIDDEN'; end if;
  if length(trim(coalesce(p_reason,'')))<3 then raise exception 'EDIT_REASON_REQUIRED'; end if;
  if v_operation not in ('LOCK','UNLOCK','REMOVE') then raise exception 'LEADER_BULK_OPERATION_INVALID'; end if;
  select count(distinct id) into v_expected from unnest(coalesce(p_assignment_ids,'{}'::uuid[])) id;
  if v_expected<1 or v_expected>1000 then raise exception 'LEADER_BULK_SELECTION_INVALID'; end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-edit:'||p_variant_id::text,0));
  perform 1 from public.plan_assignments_v2 assignment where assignment.variant_id=p_variant_id
    and assignment.id=any(p_assignment_ids) for update;
  select count(*),count(*) filter(where assignment.locked) into v_found,v_locked
  from public.plan_assignments_v2 assignment where assignment.variant_id=p_variant_id
    and assignment.id=any(p_assignment_ids);
  if v_found<>v_expected then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
  if v_operation='REMOVE' and v_locked>0 then raise exception 'LOCKED_ASSIGNMENT_CANNOT_BE_REMOVED'; end if;

  if v_operation in ('LOCK','UNLOCK') then
    update public.plan_assignments_v2 assignment set locked=v_operation='LOCK',
      explanation=coalesce(assignment.explanation,'{}'::jsonb)||jsonb_build_object(
        'edited',true,'editedBy',v_actor,'editedAt',now(),'reason',trim(p_reason),
        'bulkOperation',v_operation,'leaderLocked',v_operation='LOCK')
    where assignment.variant_id=p_variant_id and assignment.id=any(p_assignment_ids);
  else
    insert into public.plan_issues_v2(variant_id,shift_id,slot_key,issue_code,severity,role_id,duty_id,
      required_count,assigned_count,message,metadata)
    select assignment.variant_id,assignment.shift_id,assignment.slot_key,'UNFILLED_SLOT','WARNING',assignment.role_id,
      duty.duty_id,1,0,'Miejsce zwolnione przez operację zbiorczą w Studio lidera.',
      jsonb_build_object('removedAssignmentId',assignment.id,'reason',trim(p_reason),'bulkOperation','REMOVE')
    from public.plan_assignments_v2 assignment
    left join lateral(select link.duty_id from public.plan_assignment_duties_v2 link
      where link.assignment_id=assignment.id order by link.duty_id limit 1) duty on true
    where assignment.variant_id=p_variant_id and assignment.id=any(p_assignment_ids);
    delete from public.plan_assignments_v2 assignment where assignment.variant_id=p_variant_id
      and assignment.id=any(p_assignment_ids);
  end if;
  v_result:=solver_private.refresh_leader_variant_uat_v1(p_variant_id,v_actor,trim(p_reason));
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'plan_variant_v2',p_variant_id::text,'LEADER_BULK_'||v_operation,
    jsonb_build_object('assignmentIds',p_assignment_ids,'count',v_expected,'reason',trim(p_reason)));
  return v_result||jsonb_build_object('operation',v_operation,'affected',v_expected);
end;$$;

revoke all on function public.optimizer_leader_assignments_bulk_uat_v1(uuid,uuid[],text,text)
  from public,anon,authenticated;
grant execute on function public.optimizer_leader_assignments_bulk_uat_v1(uuid,uuid[],text,text)
  to authenticated;
