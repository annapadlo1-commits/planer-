alter table solver_private.leader_variant_history_v2
  add column if not exists is_checkpoint boolean not null default false,
  add column if not exists checkpoint_name text;

alter table solver_private.leader_variant_history_v2
  drop constraint if exists leader_variant_history_checkpoint_name_v2;
alter table solver_private.leader_variant_history_v2
  add constraint leader_variant_history_checkpoint_name_v2 check(
    (not is_checkpoint and checkpoint_name is null)
    or (is_checkpoint and length(trim(checkpoint_name)) between 3 and 120)
  );

create or replace function public.optimizer_leader_history_status_uat_v1(p_variant_id uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_cursor bigint;
begin
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then
    raise exception 'LEADER_VARIANT_NOT_EDITABLE';
  end if;
  select current_seq into v_cursor from solver_private.leader_variant_history_cursor_v2
    where variant_id=p_variant_id;
  return jsonb_build_object(
    'canUndo',exists(select 1 from solver_private.leader_variant_history_v2 where variant_id=p_variant_id and seq<v_cursor),
    'canRedo',exists(select 1 from solver_private.leader_variant_history_v2 where variant_id=p_variant_id and seq>v_cursor),
    'entries',coalesce((select jsonb_agg(jsonb_build_object('seq',h.seq,'revision',h.revision,
      'label',h.label,'createdAt',h.created_at,'current',h.seq=v_cursor,
      'isCheckpoint',h.is_checkpoint,'checkpointName',h.checkpoint_name) order by h.seq desc)
      from solver_private.leader_variant_history_v2 h where h.variant_id=p_variant_id),'[]'::jsonb)
  );
end;
$$;

create or replace function public.optimizer_leader_checkpoint_create_uat_v1(
  p_variant_id uuid,p_name text
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid:=auth.uid();
  v_variant public.plan_variants_v2%rowtype;
  v_seq bigint;
  v_name text:=trim(coalesce(p_name,''));
begin
  if length(v_name) not between 3 and 120 then raise exception 'CHECKPOINT_NAME_INVALID'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then
    raise exception 'LEADER_VARIANT_NOT_EDITABLE';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-edit:'||p_variant_id::text,0));
  select * into v_variant from public.plan_variants_v2 variant
  where variant.id=p_variant_id for update;
  if v_variant.leader_workflow_status<>'DRAFT' then raise exception 'LEADER_CHECKPOINT_DRAFT_REQUIRED'; end if;
  v_seq:=solver_private.record_leader_variant_history_v2(
    p_variant_id,v_variant.revision,'Punkt kontrolny: '||v_name,v_actor
  );
  update solver_private.leader_variant_history_v2
  set is_checkpoint=true,checkpoint_name=v_name
  where seq=v_seq and variant_id=p_variant_id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'plan_variant_v2',p_variant_id::text,'LEADER_CHECKPOINT_CREATE',
    jsonb_build_object('historySeq',v_seq,'revision',v_variant.revision,'name',v_name));
  return jsonb_build_object('variantId',p_variant_id,'historySeq',v_seq,
    'revision',v_variant.revision,'name',v_name);
end;
$$;

create or replace function public.optimizer_leader_checkpoint_restore_uat_v1(
  p_variant_id uuid,p_history_seq bigint,p_reason text
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid:=auth.uid();
  v_variant public.plan_variants_v2%rowtype;
  v_target solver_private.leader_variant_history_v2%rowtype;
  v_result jsonb;
begin
  if length(trim(coalesce(p_reason,'')))<3 then raise exception 'CHECKPOINT_RESTORE_REASON_REQUIRED'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then
    raise exception 'LEADER_VARIANT_NOT_EDITABLE';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-edit:'||p_variant_id::text,0));
  select * into v_variant from public.plan_variants_v2 variant
  where variant.id=p_variant_id for update;
  if v_variant.leader_workflow_status<>'DRAFT' then raise exception 'LEADER_CHECKPOINT_DRAFT_REQUIRED'; end if;
  select * into v_target from solver_private.leader_variant_history_v2 history
  where history.variant_id=p_variant_id and history.seq=p_history_seq
    and history.is_checkpoint for update;
  if v_target.seq is null then raise exception 'LEADER_CHECKPOINT_NOT_FOUND'; end if;

  perform set_config('solver_private.history_restore','on',true);
  delete from public.plan_assignments_v2 where variant_id=p_variant_id;
  delete from public.plan_issues_v2 where variant_id=p_variant_id;
  insert into public.plan_assignments_v2(id,variant_id,shift_id,slot_key,employee_id,role_id,locked,explanation,created_at)
  select id,variant_id,shift_id,slot_key,employee_id,role_id,locked,explanation,created_at
  from jsonb_populate_recordset(null::public.plan_assignments_v2,v_target.snapshot->'assignments');
  insert into public.plan_assignment_duties_v2(assignment_id,duty_id)
  select assignment_id,duty_id
  from jsonb_populate_recordset(null::public.plan_assignment_duties_v2,v_target.snapshot->'duties');
  insert into public.plan_issues_v2(id,variant_id,shift_id,slot_key,issue_code,severity,role_id,duty_id,
    required_count,assigned_count,message,metadata,created_at)
  select id,variant_id,shift_id,slot_key,issue_code,severity,role_id,duty_id,
    required_count,assigned_count,message,metadata,created_at
  from jsonb_populate_recordset(null::public.plan_issues_v2,v_target.snapshot->'issues');
  v_result:=solver_private.refresh_leader_variant_uat_v1(
    p_variant_id,v_actor,'Przywrócenie punktu kontrolnego: '||v_target.checkpoint_name
  );
  update solver_private.leader_variant_history_cursor_v2 set current_seq=v_target.seq,
    updated_at=now(),updated_by=v_actor where variant_id=p_variant_id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'plan_variant_v2',p_variant_id::text,'LEADER_CHECKPOINT_RESTORE',
    jsonb_build_object('historySeq',v_target.seq,'checkpointRevision',v_target.revision,
      'name',v_target.checkpoint_name,'reason',trim(p_reason)));
  return v_result||jsonb_build_object('historySeq',v_target.seq,
    'checkpointRevision',v_target.revision,'checkpointName',v_target.checkpoint_name);
end;
$$;

revoke all on function public.optimizer_leader_history_status_uat_v1(uuid),
  public.optimizer_leader_checkpoint_create_uat_v1(uuid,text),
  public.optimizer_leader_checkpoint_restore_uat_v1(uuid,bigint,text)
  from public,anon,authenticated;
grant execute on function public.optimizer_leader_history_status_uat_v1(uuid),
  public.optimizer_leader_checkpoint_create_uat_v1(uuid,text),
  public.optimizer_leader_checkpoint_restore_uat_v1(uuid,bigint,text)
  to authenticated;

notify pgrst,'reload schema';
