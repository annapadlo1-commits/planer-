-- UAT-only repair: cancelling the currently visible draft must not depend on a
-- matrix id retained by an already-open browser view. The lifecycle invariant
-- allows one current draft. The operation is idempotent when another tab has
-- already discarded it and fails closed if corrupted data contains >1 draft.

create or replace function public.matrix_v2_discard_current_draft_uat_v2()
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_draft public.matrix_versions%rowtype;
  v_active uuid;
  v_draft_count integer;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;

  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));

  select count(*)::integer into v_draft_count
  from public.matrix_versions
  where status='DRAFT';

  if v_draft_count > 1 then
    raise exception 'MULTIPLE_MATRIX_DRAFTS_FOUND';
  end if;

  select * into v_draft
  from public.matrix_versions
  where status='DRAFT'
  order by version desc
  limit 1
  for update;

  if v_draft.id is null then
    select id into v_active
    from public.matrix_versions
    where status='ACTIVE'
    order by effective_from desc nulls last,version desc
    limit 1;
    return jsonb_build_object(
      'discarded',null,
      'alreadyDiscarded',true,
      'activeMatrixVersionId',v_active
    );
  end if;

  if exists(
    select 1 from public.optimization_runs_v2 r
    where r.matrix_version_id=v_draft.id
  ) then
    raise exception 'DRAFT_ALREADY_USED_BY_GENERATOR';
  end if;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,old_data)
  values(
    auth.uid(),'matrix_version',v_draft.id::text,'DISCARD_DRAFT',
    jsonb_build_object('version',v_draft.version,'name',v_draft.name)
  );

  delete from public.matrix_versions where id=v_draft.id;

  select id into v_active
  from public.matrix_versions
  where status='ACTIVE'
  order by effective_from desc nulls last,version desc
  limit 1;

  return jsonb_build_object(
    'discarded',v_draft.id,
    'alreadyDiscarded',false,
    'activeMatrixVersionId',v_active
  );
end;
$$;

revoke all on function public.matrix_v2_discard_current_draft_uat_v2() from public,anon;
grant execute on function public.matrix_v2_discard_current_draft_uat_v2() to authenticated;

comment on function public.matrix_v2_discard_current_draft_uat_v2() is
  'UAT: idempotently discard the single current matrix draft after OWNER/ADMIN authorization.';

notify pgrst,'reload schema';
