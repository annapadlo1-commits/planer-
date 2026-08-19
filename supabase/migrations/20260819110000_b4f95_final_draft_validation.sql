-- B4F-95: checking the complete Studio draft is read-only and separate from
-- the audited decision to move it to review.

create or replace function public.optimizer_leader_draft_validate_uat_v1(p_variant_id uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare
  v_variant public.plan_variants_v2%rowtype;
  v_snapshot jsonb;
  v_payload jsonb;
  v_validation jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then
    raise exception 'LEADER_VARIANT_FORBIDDEN';
  end if;
  select * into v_variant from public.plan_variants_v2
  where id=p_variant_id and variant_kind='LEADER_COPY';
  if v_variant.id is null then raise exception 'LEADER_VARIANT_NOT_FOUND'; end if;
  select snapshot into v_snapshot from solver_private.optimization_snapshots_v2
  where run_id=v_variant.run_id;
  if v_snapshot is null then raise exception 'SNAPSHOT_NOT_FOUND'; end if;
  v_payload:=solver_private.materialized_variant_payload_v2(
    array[p_variant_id],v_snapshot,v_variant.strategy_id);
  v_validation:=solver_private.validate_variant_v2(v_snapshot,v_payload);
  return jsonb_build_object(
    'variantId',p_variant_id,
    'revision',v_variant.revision,
    'valid',coalesce((v_validation->>'hardViolations')::integer,0)=0,
    'validation',v_validation,
    'warnings',jsonb_build_object(
      'unfilledCount',coalesce((v_validation->>'unfilledCount')::integer,0)
    )
  );
end;
$$;

revoke all on function public.optimizer_leader_draft_validate_uat_v1(uuid)
  from public,anon,authenticated;
grant execute on function public.optimizer_leader_draft_validate_uat_v1(uuid)
  to authenticated;

comment on function public.optimizer_leader_draft_validate_uat_v1(uuid) is
  'Read-only full-draft validation. It never changes workflow status, assignments, audit history or publication.';

create or replace function public.optimizer_leader_workflow_transition_uat_v1(
  p_variant_id uuid,p_target_status text,p_reason text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_actor uuid:=auth.uid();v_variant public.plan_variants_v2%rowtype;
  v_target text:=upper(trim(coalesce(p_target_status,'')));v_check jsonb;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if length(trim(coalesce(p_reason,'')))<3 then raise exception 'EDIT_REASON_REQUIRED'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then raise exception 'LEADER_VARIANT_FORBIDDEN'; end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-edit:'||p_variant_id::text,0));
  select * into v_variant from public.plan_variants_v2 where id=p_variant_id and variant_kind='LEADER_COPY' for update;
  if v_variant.id is null then raise exception 'LEADER_VARIANT_NOT_FOUND'; end if;
  if v_variant.status='PUBLISHED' or v_variant.leader_workflow_status='PUBLISHED' then raise exception 'LEADER_VARIANT_NOT_EDITABLE'; end if;
  if not ((v_variant.leader_workflow_status='DRAFT' and v_target='REVIEW') or
    (v_variant.leader_workflow_status='REVIEW' and v_target in ('DRAFT','LEADER_APPROVED')) or
    (v_variant.leader_workflow_status='LEADER_APPROVED' and v_target in ('DRAFT','READY_TO_MERGE')) or
    (v_variant.leader_workflow_status='READY_TO_MERGE' and v_target='DRAFT')) then
    raise exception 'LEADER_WORKFLOW_TRANSITION_INVALID';
  end if;
  if v_target='READY_TO_MERGE' and not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'LEADER_READY_TO_MERGE_FORBIDDEN';
  end if;
  if v_target in ('REVIEW','LEADER_APPROVED','READY_TO_MERGE') then
    v_check:=public.optimizer_leader_draft_validate_uat_v1(p_variant_id);
    if not coalesce((v_check->>'valid')::boolean,false) then
      raise exception 'VARIANT_HAS_HARD_VIOLATIONS';
    end if;
  end if;
  update public.plan_variants_v2 set leader_workflow_status=v_target,last_edited_at=now(),last_edited_by=v_actor
    where id=p_variant_id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,old_data,new_data)
  values(v_actor,'plan_variant_v2',p_variant_id::text,'LEADER_WORKFLOW_TRANSITION',
    jsonb_build_object('status',v_variant.leader_workflow_status),
    jsonb_build_object('status',v_target,'reason',trim(p_reason),'validation',v_check));
  return jsonb_build_object('variantId',p_variant_id,'status',v_target,'reason',trim(p_reason),'validation',v_check);
end;$$;

revoke all on function public.optimizer_leader_workflow_transition_uat_v1(uuid,text,text)
  from public,anon,authenticated;
grant execute on function public.optimizer_leader_workflow_transition_uat_v1(uuid,text,text)
  to authenticated;
