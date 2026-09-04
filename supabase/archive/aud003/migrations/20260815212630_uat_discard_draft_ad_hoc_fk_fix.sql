-- UAT-only repair: operational ad-hoc rows may point at role snapshots from
-- the current draft. Preserve them by reconnecting to the matching logical
-- role in the active version before the draft cascade removes its roles.

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
  v_ad_hoc_reconnected integer:=0;
  v_ad_hoc_removed integer:=0;
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

  select id into v_active
  from public.matrix_versions
  where status='ACTIVE'
  order by effective_from desc nulls last,version desc
  limit 1;

  if v_draft.id is null then
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

  update public.recovery_ad_hoc_pool_v2 pool
  set role_id=active_role.id,updated_at=now()
  from public.matrix_roles_v2 draft_role
  join public.matrix_roles_v2 active_role
    on active_role.matrix_version_id=v_active
   and active_role.logical_id=draft_role.logical_id
  where pool.role_id=draft_role.id
    and draft_role.matrix_version_id=v_draft.id;
  get diagnostics v_ad_hoc_reconnected=row_count;

  delete from public.recovery_ad_hoc_pool_v2 pool
  using public.matrix_roles_v2 draft_role
  where pool.role_id=draft_role.id
    and draft_role.matrix_version_id=v_draft.id;
  get diagnostics v_ad_hoc_removed=row_count;

  delete from public.matrix_versions where id=v_draft.id;

  return jsonb_build_object(
    'discarded',v_draft.id,
    'alreadyDiscarded',false,
    'activeMatrixVersionId',v_active,
    'adHocRowsReconnected',v_ad_hoc_reconnected,
    'adHocRowsRemoved',v_ad_hoc_removed
  );
end;
$$;

revoke all on function public.matrix_v2_discard_current_draft_uat_v2() from public,anon;
grant execute on function public.matrix_v2_discard_current_draft_uat_v2() to authenticated;

comment on function public.matrix_v2_discard_current_draft_uat_v2() is
  'UAT: discard the current draft while reconnecting operational ad-hoc rows to the active logical role.';

notify pgrst,'reload schema';
