alter table public.plan_variants_v2
  add column if not exists leader_workflow_status text not null default 'DRAFT';

alter table public.plan_variants_v2 drop constraint if exists plan_variants_v2_leader_workflow_status_check;
alter table public.plan_variants_v2 add constraint plan_variants_v2_leader_workflow_status_check
  check(leader_workflow_status in ('DRAFT','REVIEW','LEADER_APPROVED','READY_TO_MERGE','PUBLISHED'));

create or replace function public.optimizer_leader_workflow_status_uat_v1(p_variant_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_variant public.plan_variants_v2%rowtype;
begin
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id)
    and not exists(select 1 from public.plan_variants_v2 v join public.optimization_runs_v2 r on r.id=v.run_id
      where v.id=p_variant_id and r.requested_by=auth.uid()) then raise exception 'LEADER_VARIANT_FORBIDDEN'; end if;
  select * into v_variant from public.plan_variants_v2 where id=p_variant_id and variant_kind='LEADER_COPY';
  if v_variant.id is null then raise exception 'LEADER_VARIANT_NOT_FOUND'; end if;
  return jsonb_build_object('variantId',v_variant.id,'status',case when v_variant.status='PUBLISHED' then 'PUBLISHED' else v_variant.leader_workflow_status end,
    'published',v_variant.status='PUBLISHED');
end;$$;

create or replace function public.optimizer_leader_workflow_transition_uat_v1(
  p_variant_id uuid,p_target_status text,p_reason text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_actor uuid:=auth.uid();v_variant public.plan_variants_v2%rowtype;v_target text:=upper(trim(coalesce(p_target_status,'')));
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if length(trim(coalesce(p_reason,'')))<3 then raise exception 'EDIT_REASON_REQUIRED'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then raise exception 'LEADER_VARIANT_FORBIDDEN'; end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-edit:'||p_variant_id::text,0));
  select * into v_variant from public.plan_variants_v2 where id=p_variant_id and variant_kind='LEADER_COPY' for update;
  if v_variant.id is null then raise exception 'LEADER_VARIANT_NOT_FOUND'; end if;
  if v_variant.status='PUBLISHED' or v_variant.leader_workflow_status='PUBLISHED' then raise exception 'LEADER_VARIANT_NOT_EDITABLE'; end if;
  if not (
    (v_variant.leader_workflow_status='DRAFT' and v_target='REVIEW') or
    (v_variant.leader_workflow_status='REVIEW' and v_target in ('DRAFT','LEADER_APPROVED')) or
    (v_variant.leader_workflow_status='LEADER_APPROVED' and v_target in ('DRAFT','READY_TO_MERGE')) or
    (v_variant.leader_workflow_status='READY_TO_MERGE' and v_target='DRAFT')
  ) then raise exception 'LEADER_WORKFLOW_TRANSITION_INVALID'; end if;
  if v_target='READY_TO_MERGE' and not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'LEADER_READY_TO_MERGE_FORBIDDEN';
  end if;
  if v_target in ('LEADER_APPROVED','READY_TO_MERGE') and (v_variant.hard_violations>0 or v_variant.status='FAILED') then
    raise exception 'VARIANT_HAS_HARD_VIOLATIONS';
  end if;
  update public.plan_variants_v2 set leader_workflow_status=v_target,last_edited_at=now(),last_edited_by=v_actor
    where id=p_variant_id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,old_data,new_data)
  values(v_actor,'plan_variant_v2',p_variant_id::text,'LEADER_WORKFLOW_TRANSITION',
    jsonb_build_object('status',v_variant.leader_workflow_status),
    jsonb_build_object('status',v_target,'reason',trim(p_reason)));
  return jsonb_build_object('variantId',p_variant_id,'status',v_target,'reason',trim(p_reason));
end;$$;

create or replace function solver_private.sync_leader_workflow_published_uat_v1()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.variant_kind='LEADER_COPY' and new.status='PUBLISHED' then new.leader_workflow_status:='PUBLISHED'; end if;
  return new;
end;$$;

drop trigger if exists sync_leader_workflow_published_uat_v1 on public.plan_variants_v2;
create trigger sync_leader_workflow_published_uat_v1 before update of status on public.plan_variants_v2
for each row execute function solver_private.sync_leader_workflow_published_uat_v1();

revoke all on function public.optimizer_leader_workflow_status_uat_v1(uuid),
 public.optimizer_leader_workflow_transition_uat_v1(uuid,text,text),
 solver_private.sync_leader_workflow_published_uat_v1() from public,anon,authenticated;
grant execute on function public.optimizer_leader_workflow_status_uat_v1(uuid),
 public.optimizer_leader_workflow_transition_uat_v1(uuid,text,text) to authenticated;
