-- B4F-121: closing the full-screen Studio must not make publication target the
-- generated baseline.  A READY_TO_MERGE leader copy is selected and published
-- inside one database transaction and one public RPC call.

alter function public.optimizer_publish_role_variant_uat_v2(uuid,uuid,text,text)
  rename to optimizer_publish_role_variant_before_b4f121_uat_v2;

revoke all on function public.optimizer_publish_role_variant_before_b4f121_uat_v2(
  uuid,uuid,text,text
) from public,anon,authenticated;

create or replace function public.optimizer_publish_role_variant_uat_v2(
  p_run_id uuid,
  p_variant_id uuid,
  p_name text,
  p_idempotency_key text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid:=auth.uid();
  v_variant public.plan_variants_v2%rowtype;
  v_result jsonb;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;

  perform solver_private.lock_planning_revision_v2();
  perform pg_advisory_xact_lock(hashtextextended(
    'select-v2:'||p_run_id::text,0
  ));

  select variant.* into v_variant
  from public.plan_variants_v2 variant
  join public.optimization_runs_v2 run on run.id=variant.run_id
  where variant.id=p_variant_id and variant.run_id=p_run_id
    and run.status='READY' and run.scope_type='ROLE'
    and run.request_engine='ORTOOLS_V2'
  for update of variant;
  if v_variant.id is null then raise exception 'VARIANT_NOT_FOUND'; end if;

  if v_variant.variant_kind='LEADER_COPY' then
    if v_variant.hard_violations<>0
      or v_variant.leader_workflow_status not in ('READY_TO_MERGE','PUBLISHED') then
      raise exception 'LEADER_VARIANT_NOT_READY_TO_PUBLISH';
    end if;

    if v_variant.status<>'PUBLISHED' then
      update public.plan_variants_v2 variant set
        selected=false,
        status=case when variant.status='SELECTED' then 'READY' else variant.status end,
        selected_at=null,
        selected_by=null
      where variant.run_id=p_run_id and variant.selected and variant.id<>p_variant_id;

      update public.plan_variants_v2 variant set
        selected=true,
        status='SELECTED',
        selected_at=now(),
        selected_by=v_actor
      where variant.id=p_variant_id;

      insert into public.audit_log(
        actor_id,entity_type,entity_id,action,new_data
      ) values(
        v_actor,'optimization_run_v2',p_run_id::text,
        'SELECT_VARIANT_FOR_ATOMIC_ROLE_PUBLICATION',
        jsonb_build_object('variantId',p_variant_id)
      );
    end if;
  end if;

  v_result:=public.optimizer_publish_role_variant_before_b4f121_uat_v2(
    p_run_id,p_variant_id,p_name,p_idempotency_key
  );

  if v_variant.variant_kind='LEADER_COPY' then
    update public.plan_variants_v2 variant
    set leader_workflow_status='PUBLISHED'
    where variant.id=p_variant_id and variant.status='PUBLISHED';
  end if;
  return v_result;
end;
$$;

revoke all on function public.optimizer_publish_role_variant_uat_v2(
  uuid,uuid,text,text
) from public,anon,authenticated;
grant execute on function public.optimizer_publish_role_variant_uat_v2(
  uuid,uuid,text,text
) to authenticated;

comment on function public.optimizer_publish_role_variant_uat_v2(uuid,uuid,text,text)
is 'B4F-121: atomically selects a READY_TO_MERGE leader copy and publishes that exact variant in one RPC.';
comment on function public.optimizer_publish_role_variant_before_b4f121_uat_v2(uuid,uuid,text,text)
is 'B4F-121: private pre-atomic role publication implementation; callable only by the secured wrapper.';

notify pgrst,'reload schema';
