-- UAT-006: publish a company schedule over existing role publications only
-- after an explicit, audited owner decision.  Archiving and publication are
-- one transaction, so a failed publication cannot leave the month empty.

create or replace function public.optimizer_publish_company_variant_resolved_uat_v2(
  p_run_id uuid,
  p_variant_id uuid,
  p_name text,
  p_idempotency_key text,
  p_warning_reason text default null,
  p_role_replacement_reason text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid:=auth.uid();
  v_run public.optimization_runs_v2%rowtype;
  v_archived_role_schedules integer:=0;
  v_result jsonb;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'COMPANY_PUBLICATION_OWNER_REQUIRED';
  end if;

  select run.* into v_run
  from public.optimization_runs_v2 run
  where run.id=p_run_id
  for update;
  if v_run.id is null or not solver_private.can_access_run_v2(p_run_id) then
    raise exception 'RUN_NOT_FOUND';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'publish-v2-month:'||v_run.month::text,0
  ));

  if exists(
    select 1 from public.published_role_schedules_v2 publication
    where publication.month=v_run.month and publication.status='PUBLISHED'
  ) then
    if length(trim(coalesce(p_role_replacement_reason,'')))<5 then
      raise exception 'ROLE_PUBLICATION_REPLACEMENT_REASON_REQUIRED';
    end if;
    update public.published_role_schedules_v2 publication set
      status='ARCHIVED',archived_at=now(),archived_by=v_actor
    where publication.month=v_run.month and publication.status='PUBLISHED';
    get diagnostics v_archived_role_schedules=row_count;
  end if;

  v_result:=public.optimizer_publish_company_variant_alpha16(
    p_run_id,p_variant_id,p_name,p_idempotency_key,p_warning_reason
  );
  if not coalesce((v_result->>'published')::boolean,false) then
    raise exception 'ATOMIC_COMPANY_PUBLICATION_FAILED: %',
      coalesce(v_result->>'message',v_result->>'code','UNKNOWN');
  end if;

  if v_archived_role_schedules>0 then
    insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
    values(v_actor,'schedule_publication_authority_v2',v_run.month::text,
      'REPLACE_ROLES_WITH_COMPANY',jsonb_build_object(
        'reason',trim(p_role_replacement_reason),
        'archivedRoleSchedules',v_archived_role_schedules,
        'scheduleId',v_result->>'scheduleId',
        'runId',p_run_id,'variantId',p_variant_id
      ));
  end if;

  return v_result||jsonb_build_object(
    'archivedRoleSchedules',v_archived_role_schedules,
    'publicationAuthority','COMPANY'
  );
end;
$$;

revoke all on function public.optimizer_publish_company_variant_resolved_uat_v2(
  uuid,uuid,text,text,text,text
) from public,anon,authenticated;
grant execute on function public.optimizer_publish_company_variant_resolved_uat_v2(
  uuid,uuid,text,text,text,text
) to authenticated;

comment on function public.optimizer_publish_company_variant_resolved_uat_v2(
  uuid,uuid,text,text,text,text
) is 'Atomically archives active role publications and publishes a company variant after an explicit audited owner decision.';

notify pgrst,'reload schema';
