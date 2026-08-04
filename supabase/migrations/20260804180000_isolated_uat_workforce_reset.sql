-- The reset entrypoint ships disabled. It can only be enabled by service-role
-- configuration in an isolated UAT database; no client or owner can enable it.

create table if not exists public.uat_environment_controls (
  control_key text primary key,
  enabled boolean not null default false,
  config jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.uat_environment_controls enable row level security;
revoke all on table public.uat_environment_controls from public,anon,authenticated;
grant all on table public.uat_environment_controls to service_role;

create or replace function public.uat_matrix_workforce_reset_preview_v2()
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_enabled boolean:=false; v_draft uuid; v_version integer;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.has_app_role('OWNER') then raise exception 'FORBIDDEN'; end if;
  select control.enabled into v_enabled from public.uat_environment_controls control
    where control.control_key='ISOLATED_UAT_DESTRUCTIVE_TOOLS';
  select version.id,version.version into v_draft,v_version
  from public.matrix_versions version where version.status='DRAFT'
    and version.schema_version>=2 order by version.version desc limit 1;
  return jsonb_build_object(
    'enabled',coalesce(v_enabled,false),'draftMatrixVersionId',v_draft,
    'draftVersion',v_version,'confirmation','WYCZYŚĆ ROBOCZY MATRIX UAT',
    'employees',coalesce((select count(*) from public.matrix_employee_profiles_v2
      where matrix_version_id=v_draft),0),
    'roleAssignments',coalesce((select count(*) from public.matrix_employee_roles_v2
      where matrix_version_id=v_draft),0),
    'locationAssignments',coalesce((select count(*) from public.matrix_employee_locations_v2
      where matrix_version_id=v_draft),0),
    'dutyAssignments',coalesce((select count(*) from public.matrix_employee_duties_v2
      where matrix_version_id=v_draft),0),
    'preserves',jsonb_build_array(
      'aktywny Matrix','opublikowane grafiki','historia wersji','audit trail',
      'globalne konta pracowników','chroniona historia stawek'
    )
  );
end;
$$;

create or replace function public.uat_matrix_workforce_reset_v2(p_confirmation text)
returns jsonb language plpgsql volatile security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_enabled boolean:=false; v_draft uuid;
  v_profiles integer:=0; v_roles integer:=0; v_locations integer:=0; v_duties integer:=0;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.has_app_role('OWNER') then raise exception 'FORBIDDEN'; end if;
  select control.enabled into v_enabled from public.uat_environment_controls control
    where control.control_key='ISOLATED_UAT_DESTRUCTIVE_TOOLS';
  if not coalesce(v_enabled,false) then raise exception 'UAT_RESET_DISABLED'; end if;
  if trim(coalesce(p_confirmation,''))<>'WYCZYŚĆ ROBOCZY MATRIX UAT' then
    raise exception 'UAT_RESET_CONFIRMATION_INVALID';
  end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  select version.id into v_draft from public.matrix_versions version
  where version.status='DRAFT' and version.schema_version>=2
  order by version.version desc limit 1 for update;
  if v_draft is null then raise exception 'MATRIX_DRAFT_REQUIRED'; end if;

  delete from public.matrix_employee_duties_v2 where matrix_version_id=v_draft;
  get diagnostics v_duties=row_count;
  delete from public.matrix_employee_locations_v2 where matrix_version_id=v_draft;
  get diagnostics v_locations=row_count;
  delete from public.matrix_employee_roles_v2 where matrix_version_id=v_draft;
  get diagnostics v_roles=row_count;
  delete from public.matrix_employee_profiles_v2 where matrix_version_id=v_draft;
  get diagnostics v_profiles=row_count;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'uat_matrix_reset',v_draft::text,'RESET_DRAFT_WORKFORCE',
    jsonb_build_object('profiles',v_profiles,'roles',v_roles,
      'locations',v_locations,'duties',v_duties,
      'activeMatrixPreserved',true,'publishedSchedulesPreserved',true));
  return jsonb_build_object('draftMatrixVersionId',v_draft,'profiles',v_profiles,
    'roles',v_roles,'locations',v_locations,'duties',v_duties);
end;
$$;

revoke all on function public.uat_matrix_workforce_reset_preview_v2()
  from public,anon,authenticated;
revoke all on function public.uat_matrix_workforce_reset_v2(text)
  from public,anon,authenticated;
grant execute on function public.uat_matrix_workforce_reset_preview_v2()
  to authenticated;
grant execute on function public.uat_matrix_workforce_reset_v2(text)
  to authenticated;

notify pgrst,'reload schema';
