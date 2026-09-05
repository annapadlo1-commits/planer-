begin;

do $$
declare
  v_definition text;
  v_variant public.plan_variants_v2%rowtype;
  v_run public.optimization_runs_v2%rowtype;
  v_result jsonb;
  v_publication_id uuid;
begin
  select pg_get_functiondef(
    'public.optimizer_publish_role_variant_uat_v2(uuid,uuid,text,text)'::regprocedure
  ) into v_definition;
  if v_definition not like '%SELECT_VARIANT_FOR_ATOMIC_ROLE_PUBLICATION%'
    or v_definition not like '%optimizer_publish_role_variant_before_b4f121_uat_v2%' then
    raise exception 'B4F121_ATOMIC_WRAPPER_MISSING';
  end if;
  if not has_function_privilege(
    'authenticated',
    'public.optimizer_publish_role_variant_uat_v2(uuid,uuid,text,text)',
    'execute'
  ) then raise exception 'B4F121_AUTHENTICATED_GRANT_MISSING'; end if;
  if has_function_privilege(
    'authenticated',
    'public.optimizer_publish_role_variant_before_b4f121_uat_v2(uuid,uuid,text,text)',
    'execute'
  ) then raise exception 'B4F121_OLD_IMPLEMENTATION_STILL_PUBLIC'; end if;

  select variant.* into v_variant
  from public.plan_variants_v2 variant
  join public.optimization_runs_v2 run on run.id=variant.run_id
  where variant.variant_kind='LEADER_COPY'
    and variant.source_variant_id is not null
    and variant.leader_workflow_status='READY_TO_MERGE'
    and variant.hard_violations=0
    and run.status='READY'
    and run.scope_type='ROLE'
    and run.request_engine='ORTOOLS_V2'
  order by coalesce(variant.last_edited_at,variant.created_at) desc
  limit 1;
  if v_variant.id is null then raise exception 'B4F121_READY_LEADER_FIXTURE_MISSING'; end if;
  select * into v_run from public.optimization_runs_v2 where id=v_variant.run_id;

  -- Reproduce the UAT defect: the leader workspace remains visible, but the
  -- generated baseline is the selected database variant after Studio closes.
  update public.plan_variants_v2 set selected=false,status='READY',
    selected_at=null,selected_by=null where id=v_variant.id;
  update public.plan_variants_v2 set selected=true,status='SELECTED',
    selected_at=now(),selected_by=v_run.requested_by
  where id=v_variant.source_variant_id;

  perform set_config('request.jwt.claim.sub',v_run.requested_by::text,true);
  v_result:=public.optimizer_publish_role_variant_uat_v2(
    v_run.id,v_variant.id,'[ROLLBACK B4F-121] atomowa publikacja',
    'b4f121-'||replace(gen_random_uuid()::text,'-','')
  );

  if v_result->>'status'<>'PUBLISHED' then
    raise exception 'B4F121_PUBLICATION_NOT_COMPLETED: %',v_result;
  end if;
  select id into v_publication_id from public.published_role_schedules_v2
  where id=(v_result->>'roleScheduleId')::uuid and variant_id=v_variant.id
    and status='PUBLISHED';
  if v_publication_id is null then raise exception 'B4F121_WRONG_VARIANT_PUBLISHED'; end if;
  if not exists(
    select 1 from public.plan_variants_v2 variant
    where variant.id=v_variant.id and variant.selected
      and variant.status='PUBLISHED'
      and variant.leader_workflow_status='PUBLISHED'
  ) then raise exception 'B4F121_LEADER_STATE_NOT_ATOMIC'; end if;
end;
$$;

rollback;
