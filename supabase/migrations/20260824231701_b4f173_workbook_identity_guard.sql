-- B4F-173: a hidden workbook identifier is an update hint, never an
-- authorization boundary.  Authorization remains server-side OWNER/ADMIN;
-- the identifier is checked against the single current DRAFT before preview
-- and again inside the atomic apply transaction.

alter function public.matrix_v2_team_import_preview_uat_v1(jsonb,text)
  rename to matrix_v2_team_import_preview_uat_v1_core_20260824;
alter function public.matrix_v2_team_import_apply_uat_v1(jsonb,text)
  rename to matrix_v2_team_import_apply_uat_v1_core_20260824;

create or replace function solver_private.matrix_v2_assert_workbook_identity_uat_v1(
  p_configuration jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_workbook jsonb:=coalesce(p_configuration->'_workbook','{}'::jsonb);
  v_mode text:=coalesce(v_workbook->>'mode','');
  v_contract text:=coalesce(v_workbook->>'contractVersion','');
  v_source text:=coalesce(v_workbook->>'sourceMatrixVersionId','');
  v_draft uuid;
  v_draft_count integer;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
  if jsonb_typeof(p_configuration)<>'object' then raise exception 'INVALID_TEAM_IMPORT_PAYLOAD'; end if;
  if v_workbook ? 'organizationId' or v_workbook ? 'tenantId' then
    raise exception 'WORKBOOK_SCOPE_IDENTIFIER_FORBIDDEN';
  end if;
  if v_contract<>'2' then raise exception 'WORKBOOK_CONTRACT_UNSUPPORTED'; end if;
  if v_mode not in ('EMPTY_TEMPLATE','CURRENT_CONFIG_EXPORT') then
    raise exception 'WORKBOOK_METADATA_REQUIRED';
  end if;

  select count(*) into v_draft_count
  from public.matrix_versions
  where status='DRAFT' and schema_version>=2;
  if v_draft_count<>1 then raise exception 'MATRIX_V2_SINGLE_DRAFT_REQUIRED'; end if;
  select id into v_draft from public.matrix_versions where status='DRAFT' and schema_version>=2 limit 1;

  if v_mode='EMPTY_TEMPLATE' then
    if v_source<>'' then raise exception 'WORKBOOK_SOURCE_MATRIX_INVALID'; end if;
  else
    if v_source!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
      raise exception 'WORKBOOK_SOURCE_MATRIX_INVALID';
    end if;
    if v_source::uuid<>v_draft then raise exception 'WORKBOOK_SOURCE_MATRIX_STALE'; end if;
  end if;
  return jsonb_build_object('mode',v_mode,'contractVersion',v_contract,'currentDraftId',v_draft);
end;
$$;

create or replace function public.matrix_v2_team_import_preview_uat_v1(
  p_configuration jsonb,
  p_mode text default 'UPDATE'
) returns jsonb
language plpgsql
security definer
set search_path = ''
set statement_timeout = '180s'
as $$
declare
  v_identity jsonb;
  v_result jsonb;
begin
  v_identity:=solver_private.matrix_v2_assert_workbook_identity_uat_v1(p_configuration);
  v_result:=public.matrix_v2_team_import_preview_uat_v1_core_20260824(p_configuration,p_mode);
  return v_result||jsonb_build_object('workbookIdentity',v_identity);
end;
$$;

create or replace function public.matrix_v2_team_import_apply_uat_v1(
  p_configuration jsonb,
  p_mode text default 'UPDATE'
) returns jsonb
language plpgsql
security definer
set search_path = ''
set statement_timeout = '180s'
as $$
declare
  v_identity jsonb;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  v_identity:=solver_private.matrix_v2_assert_workbook_identity_uat_v1(p_configuration);
  v_result:=public.matrix_v2_team_import_apply_uat_v1_core_20260824(p_configuration,p_mode);
  return v_result||jsonb_build_object('workbookIdentity',v_identity);
end;
$$;

revoke all on function solver_private.matrix_v2_assert_workbook_identity_uat_v1(jsonb),
  public.matrix_v2_team_import_preview_uat_v1_core_20260824(jsonb,text),
  public.matrix_v2_team_import_apply_uat_v1_core_20260824(jsonb,text),
  public.matrix_v2_team_import_preview_uat_v1(jsonb,text),
  public.matrix_v2_team_import_apply_uat_v1(jsonb,text)
  from public,anon,authenticated;
grant execute on function public.matrix_v2_team_import_preview_uat_v1(jsonb,text),
  public.matrix_v2_team_import_apply_uat_v1(jsonb,text)
  to authenticated;

comment on function public.matrix_v2_team_import_preview_uat_v1(jsonb,text) is
  'B4F-173 UAT preview: validates v2 workbook mode and current DRAFT identity before the existing dependency-ordered dry run.';
comment on function public.matrix_v2_team_import_apply_uat_v1(jsonb,text) is
  'B4F-173 UAT atomic apply: revalidates v2 workbook identity under the lifecycle advisory lock before mutation.';

notify pgrst,'reload schema';
