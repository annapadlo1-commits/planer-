create or replace function public.optimizer_leader_assignment_lock_uat_v1(
  p_variant_id uuid,p_assignment_id uuid,p_locked boolean,p_reason text
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid();v_assignment public.plan_assignments_v2%rowtype;
  v_reason text:=trim(coalesce(p_reason,''));v_result jsonb;
begin
  if length(v_reason)<3 then raise exception 'EDIT_REASON_REQUIRED'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then
    raise exception 'LEADER_VARIANT_NOT_EDITABLE';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-edit:'||p_variant_id::text,0));
  select * into v_assignment from public.plan_assignments_v2
    where id=p_assignment_id and variant_id=p_variant_id for update;
  if v_assignment.id is null then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
  update public.plan_assignments_v2 set locked=p_locked,
    explanation=coalesce(explanation,'{}'::jsonb)||jsonb_build_object(
      'edited',true,'editedBy',v_actor,'editedAt',now(),'reason',v_reason,
      'leaderLocked',p_locked)
    where id=p_assignment_id;
  v_result:=solver_private.refresh_leader_variant_uat_v1(p_variant_id,v_actor,v_reason);
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'plan_assignment_v2',p_assignment_id::text,
    case when p_locked then 'LEADER_LOCK' else 'LEADER_UNLOCK' end,
    jsonb_build_object('variantId',p_variant_id,'reason',v_reason));
  return v_result||jsonb_build_object('assignmentId',p_assignment_id,'locked',p_locked);
end;
$$;

revoke all on function public.optimizer_leader_assignment_lock_uat_v1(uuid,uuid,boolean,text)
  from public,anon,authenticated;
grant execute on function public.optimizer_leader_assignment_lock_uat_v1(uuid,uuid,boolean,text)
  to authenticated;
