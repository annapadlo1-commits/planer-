-- AUD-2026-09-01-008 / B4F-175 safety boundary for the current single-company UAT.
-- This does not introduce a multi-tenant model.  One Supabase project remains
-- one company, and every Matrix version belongs to that same implicit company.
begin;

do $guard$
begin
  if not exists (
    select 1
    from public.uat_environment_controls control
    where control.control_key='ISOLATED_UAT_DESTRUCTIVE_TOOLS'
      and control.enabled is true
      and control.config->>'environment'='ISOLATED_UAT'
      and control.config->>'projectRef'='nhthrtpkfpmufmrmdyjg'
  ) then
    raise exception 'AUD008_WRONG_SUPABASE_PROJECT';
  end if;
end;
$guard$;

create table solver_private.single_company_boundary_uat_v1 (
  singleton_key smallint not null default 1 check (singleton_key=1),
  boundary_id uuid not null,
  project_ref text not null check (project_ref='nhthrtpkfpmufmrmdyjg'),
  created_at timestamptz not null default now(),
  primary key (singleton_key),
  unique (boundary_id)
);

insert into solver_private.single_company_boundary_uat_v1(
  singleton_key,boundary_id,project_ref
) values(
  1,'a0080000-0000-4000-8000-000000000001','nhthrtpkfpmufmrmdyjg'
);

revoke all on table solver_private.single_company_boundary_uat_v1
  from public,anon,authenticated,service_role;

create or replace function solver_private.matrix_v2_current_company_boundary_uat_v1()
returns uuid
language sql
stable
security definer
set search_path=''
as $function$
  select boundary_id
  from solver_private.single_company_boundary_uat_v1
  where singleton_key=1
$function$;

revoke all on function solver_private.matrix_v2_current_company_boundary_uat_v1()
  from public,anon,authenticated,service_role;

create or replace function solver_private.matrix_v2_assert_single_company_payload_uat_v1(
  p_configuration jsonb,
  p_allow_hr_finance boolean default false
) returns uuid
language plpgsql
stable
security definer
set search_path=''
as $function$
declare
  v_boundary uuid;
  v_candidate text;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (
    public.has_app_role('OWNER')
    or public.has_app_role('ADMIN')
    or (p_allow_hr_finance and public.has_app_role('HR_FINANCE'))
  ) then
    raise exception 'FORBIDDEN';
  end if;
  if jsonb_typeof(coalesce(p_configuration,'{}'::jsonb))<>'object' then
    raise exception 'INVALID_COMPANY_CONFIGURATION';
  end if;

  v_boundary:=solver_private.matrix_v2_current_company_boundary_uat_v1();
  if v_boundary is null then raise exception 'SINGLE_COMPANY_BOUNDARY_MISSING'; end if;

  if p_configuration ? 'organizationId' or p_configuration ? 'tenantId'
    or p_configuration ? 'organization_id' or p_configuration ? 'tenant_id'
    or p_configuration ? 'companyBoundaryId'
    or coalesce(p_configuration->'_workbook','{}'::jsonb) ? 'organizationId'
    or coalesce(p_configuration->'_workbook','{}'::jsonb) ? 'tenantId'
    or coalesce(p_configuration->'_workbook','{}'::jsonb) ? 'organization_id'
    or coalesce(p_configuration->'_workbook','{}'::jsonb) ? 'tenant_id' then
    raise exception 'SECOND_COMPANY_FORBIDDEN';
  end if;

  v_candidate:=nullif(trim(coalesce(
    p_configuration#>>'{_workbook,companyBoundaryId}',
    ''
  )), '');
  if v_candidate is null then
    raise exception 'WORKBOOK_COMPANY_BOUNDARY_REQUIRED';
  end if;
  if not pg_catalog.pg_input_is_valid(v_candidate,'uuid') then
    raise exception 'WORKBOOK_COMPANY_BOUNDARY_INVALID';
  end if;
  if v_candidate::uuid<>v_boundary then
    raise exception 'SECOND_COMPANY_FORBIDDEN';
  end if;
  return v_boundary;
end;
$function$;

revoke all on function solver_private.matrix_v2_assert_single_company_payload_uat_v1(jsonb,boolean)
  from public,anon,authenticated,service_role;

create or replace function solver_private.matrix_v2_enforce_single_company_boundary_uat_v1()
returns trigger
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_boundary uuid;
  v_candidate text;
begin
  perform pg_advisory_xact_lock(hashtext('matrix-v2-single-company-boundary'));
  v_boundary:=solver_private.matrix_v2_current_company_boundary_uat_v1();
  if v_boundary is null then raise exception 'SINGLE_COMPANY_BOUNDARY_MISSING'; end if;

  if tg_op='UPDATE' and (
    new.base_version_id is distinct from old.base_version_id
    or new.schema_version is distinct from old.schema_version
  ) then
    raise exception 'MATRIX_VERSION_LINEAGE_IMMUTABLE';
  end if;

  if coalesce(new.schema_version,1)<2 then
    raise exception 'LEGACY_COMPANY_VERSION_DISABLED';
  end if;

  if new.base_version_id is null then
    if exists(
      select 1 from public.matrix_versions version
      where version.base_version_id is null and version.id<>new.id
    ) then
      raise exception 'SECOND_COMPANY_FORBIDDEN';
    end if;
  elsif not exists(
    with recursive lineage as (
      select version.id,version.base_version_id,array[version.id] path,false cycle
      from public.matrix_versions version
      where version.id=new.base_version_id and version.schema_version>=2
      union all
      select parent.id,parent.base_version_id,
        lineage.path||parent.id,parent.id=any(lineage.path)
      from lineage
      join public.matrix_versions parent on parent.id=lineage.base_version_id
      where not lineage.cycle and parent.schema_version>=2
    )
    select 1 from lineage
    where base_version_id is null and not cycle
  ) then
    raise exception 'MATRIX_VERSION_LINEAGE_INVALID';
  end if;

  if jsonb_typeof(coalesce(new.settings,'{}'::jsonb))<>'object' then
    raise exception 'INVALID_MATRIX_SETTINGS';
  end if;
  if coalesce(new.settings,'{}'::jsonb) ? 'organizationId'
    or coalesce(new.settings,'{}'::jsonb) ? 'tenantId'
    or coalesce(new.settings,'{}'::jsonb) ? 'organization_id'
    or coalesce(new.settings,'{}'::jsonb) ? 'tenant_id' then
    raise exception 'SECOND_COMPANY_FORBIDDEN';
  end if;
  v_candidate:=nullif(trim(coalesce(new.settings->>'companyBoundaryId','')), '');
  if v_candidate is not null then
    if not pg_catalog.pg_input_is_valid(v_candidate,'uuid') then
      raise exception 'SECOND_COMPANY_FORBIDDEN';
    end if;
    if v_candidate::uuid<>v_boundary then
      raise exception 'SECOND_COMPANY_FORBIDDEN';
    end if;
  end if;
  return new;
end;
$function$;

revoke all on function solver_private.matrix_v2_enforce_single_company_boundary_uat_v1()
  from public,anon,authenticated,service_role;

-- Serialize the validation, index installation and trigger cut-over with all
-- concurrent writers.  Without this lock, a second session could insert an
-- invalid archived descendant after the preflight but before the trigger is
-- installed, because the partial unique indexes cover only root/draft/active.
select pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
lock table public.matrix_versions in share row exclusive mode;
select pg_advisory_xact_lock(hashtext('matrix-v2-single-company-boundary'));

do $lineage_guard$
begin
  if exists(
    select 1 from public.matrix_versions where coalesce(schema_version,1)<2
  ) then
    raise exception 'AUD008_LEGACY_COMPANY_VERSIONS_EXIST';
  end if;
  if (select count(*) from public.matrix_versions
      where base_version_id is null)>1 then
    raise exception 'AUD008_MULTIPLE_COMPANY_ROOTS_EXIST';
  end if;
  if (select count(*) from public.matrix_versions
      where schema_version>=2 and status='DRAFT')>1 then
    raise exception 'AUD008_MULTIPLE_DRAFTS_EXIST';
  end if;
  if (select count(*) from public.matrix_versions
      where schema_version>=2 and status='ACTIVE')>1 then
    raise exception 'AUD008_MULTIPLE_ACTIVE_VERSIONS_EXIST';
  end if;
  if exists(
    with recursive lineage(start_id,id,base_version_id,path,cycle) as (
      select version.id,version.id,version.base_version_id,array[version.id],false
      from public.matrix_versions version
      where version.schema_version>=2
      union all
      select lineage.start_id,parent.id,parent.base_version_id,
        lineage.path||parent.id,parent.id=any(lineage.path)
      from lineage
      join public.matrix_versions parent on parent.id=lineage.base_version_id
      where not lineage.cycle and parent.schema_version>=2
    )
    select 1
    from public.matrix_versions version
    where version.schema_version>=2
      and not exists(
        select 1 from lineage
        where lineage.start_id=version.id
          and lineage.base_version_id is null
          and not lineage.cycle
      )
  ) then
    raise exception 'AUD008_EXISTING_LINEAGE_INVALID';
  end if;
  if exists(
    select 1
    from public.matrix_versions version
    where coalesce(version.settings,'{}'::jsonb) ? 'organizationId'
       or coalesce(version.settings,'{}'::jsonb) ? 'tenantId'
       or coalesce(version.settings,'{}'::jsonb) ? 'organization_id'
       or coalesce(version.settings,'{}'::jsonb) ? 'tenant_id'
       or (
         nullif(trim(coalesce(version.settings->>'companyBoundaryId','')),'') is not null
         and (
           not pg_catalog.pg_input_is_valid(
             nullif(trim(version.settings->>'companyBoundaryId'),''),'uuid'
           )
           or version.settings->>'companyBoundaryId'<>
             'a0080000-0000-4000-8000-000000000001'
         )
       )
  ) then
    raise exception 'AUD008_EXISTING_COMPANY_METADATA_INVALID';
  end if;
end;
$lineage_guard$;

create unique index matrix_versions_single_company_root_uat_v1
  on public.matrix_versions ((1))
  where base_version_id is null;
create unique index matrix_versions_single_draft_uat_v1
  on public.matrix_versions ((1))
  where status='DRAFT';
create unique index matrix_versions_single_active_uat_v1
  on public.matrix_versions ((1))
  where status='ACTIVE';

create trigger matrix_v2_single_company_boundary_uat_v1
before insert or update
on public.matrix_versions
for each row execute function
  solver_private.matrix_v2_enforce_single_company_boundary_uat_v1();

create or replace function public.matrix_v2_company_boundary_uat_v1()
returns uuid
language plpgsql
stable
security definer
set search_path=''
as $function$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (
    public.has_app_role('OWNER')
    or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE')
  ) then
    raise exception 'FORBIDDEN';
  end if;
  return solver_private.matrix_v2_current_company_boundary_uat_v1();
end;
$function$;

revoke all on function public.matrix_v2_company_boundary_uat_v1()
  from public,anon,authenticated,service_role;
grant execute on function public.matrix_v2_company_boundary_uat_v1()
  to authenticated;

create or replace function public.matrix_v2_claim_single_company_uat_v1(
  p_boundary_id uuid
) returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_boundary uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-single-company-boundary'));
  v_boundary:=solver_private.matrix_v2_current_company_boundary_uat_v1();
  if v_boundary is null then
    raise exception 'SINGLE_COMPANY_BOUNDARY_MISSING';
  end if;
  if p_boundary_id is null or p_boundary_id<>v_boundary then
    raise exception 'SECOND_COMPANY_FORBIDDEN';
  end if;
  return jsonb_build_object('accepted',true,'companyBoundaryId',v_boundary);
end;
$function$;

revoke all on function public.matrix_v2_claim_single_company_uat_v1(uuid)
  from public,anon,authenticated,service_role;
grant execute on function public.matrix_v2_claim_single_company_uat_v1(uuid)
  to authenticated;

create or replace function public.matrix_v2_team_import_preview_uat_v1(
  p_configuration jsonb,p_mode text default 'UPDATE'
) returns jsonb
language plpgsql
security definer
set search_path=''
set statement_timeout='180s'
as $function$
declare
  v_boundary uuid;
  v_identity jsonb;
  v_result jsonb;
begin
  v_boundary:=solver_private.matrix_v2_assert_single_company_payload_uat_v1(p_configuration);
  v_identity:=solver_private.matrix_v2_assert_workbook_identity_uat_v1(p_configuration);
  v_result:=public.matrix_v2_team_import_preview_uat_v1_core_20260824(p_configuration,p_mode);
  return v_result||jsonb_build_object(
    'workbookIdentity',v_identity,'companyBoundaryId',v_boundary
  );
end;
$function$;

create or replace function public.matrix_v2_team_import_apply_uat_v1(
  p_configuration jsonb,p_mode text default 'UPDATE'
) returns jsonb
language plpgsql
security definer
set search_path=''
set statement_timeout='180s'
as $function$
declare
  v_boundary uuid;
  v_identity jsonb;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  v_boundary:=solver_private.matrix_v2_assert_single_company_payload_uat_v1(p_configuration);
  v_identity:=solver_private.matrix_v2_assert_workbook_identity_uat_v1(p_configuration);
  v_result:=public.matrix_v2_team_import_apply_uat_v1_core_20260824(p_configuration,p_mode);
  return v_result||jsonb_build_object(
    'workbookIdentity',v_identity,'companyBoundaryId',v_boundary
  );
end;
$function$;

create or replace function public.matrix_v2_full_import_preview_uat_v1(
  p_payload jsonb,p_mode text default 'UPDATE'
) returns jsonb
language plpgsql
security definer
set search_path=''
set statement_timeout='60s'
set lock_timeout='60s'
as $function$
declare
  v_payload jsonb;
begin
  perform solver_private.matrix_v2_assert_single_company_payload_uat_v1(
    coalesce(p_payload->'configuration','{}'::jsonb)
  );
  perform solver_private.matrix_v2_assert_single_company_payload_uat_v1(
    coalesce(p_payload->'finance','{}'::jsonb),true
  );
  v_payload:=jsonb_set(
    coalesce(p_payload,'{}'::jsonb),
    '{configuration}',
    solver_private.matrix_v2_full_import_configuration_uat_v2(
      coalesce(p_payload->'configuration','{}'::jsonb)
    ),true
  );
  return public.matrix_v2_full_import_preview_raw_uat_v1(v_payload,p_mode);
end;
$function$;

create or replace function public.matrix_v2_full_import_apply_uat_v1(
  p_payload jsonb,p_mode text default 'UPDATE'
) returns jsonb
language plpgsql
security definer
set search_path=''
set statement_timeout='60s'
set lock_timeout='60s'
as $function$
declare
  v_payload jsonb;
begin
  perform solver_private.matrix_v2_assert_single_company_payload_uat_v1(
    coalesce(p_payload->'configuration','{}'::jsonb)
  );
  perform solver_private.matrix_v2_assert_single_company_payload_uat_v1(
    coalesce(p_payload->'finance','{}'::jsonb),true
  );
  v_payload:=jsonb_set(
    coalesce(p_payload,'{}'::jsonb),
    '{configuration}',
    solver_private.matrix_v2_full_import_configuration_uat_v2(
      coalesce(p_payload->'configuration','{}'::jsonb)
    ),true
  );
  return public.matrix_v2_full_import_apply_raw_uat_v1(v_payload,p_mode);
end;
$function$;

-- Preserve the established finance implementation behind a guarded public
-- surface.  Renaming preserves internal OID references, while every Data API
-- entry point below validates the workbook boundary before calling it.
alter function public.matrix_v2_finance_import_preview_uat_v1(jsonb)
  rename to matrix_v2_finance_import_preview_core_aud008;
alter function public.matrix_v2_finance_import_apply_uat_v1(jsonb)
  rename to matrix_v2_finance_import_apply_core_aud008;

revoke all on function public.matrix_v2_finance_import_preview_core_aud008(jsonb)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_v2_finance_import_apply_core_aud008(jsonb)
  from public,anon,authenticated,service_role;

create function public.matrix_v2_finance_import_preview_uat_v1(p_payload jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
set statement_timeout='60s'
set lock_timeout='60s'
as $function$
begin
  perform solver_private.matrix_v2_assert_single_company_payload_uat_v1(
    coalesce(p_payload,'{}'::jsonb),true
  );
  return public.matrix_v2_finance_import_preview_core_aud008(p_payload);
end;
$function$;

create function public.matrix_v2_finance_import_apply_uat_v1(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=''
set statement_timeout='60s'
set lock_timeout='60s'
as $function$
begin
  perform solver_private.matrix_v2_assert_single_company_payload_uat_v1(
    coalesce(p_payload,'{}'::jsonb),true
  );
  return public.matrix_v2_finance_import_apply_core_aud008(p_payload);
end;
$function$;

-- The supported public import surface is limited to the guarded team/full
-- wrappers.  Historical generic functions remain for internal composition,
-- but cannot be invoked through PostgREST by browser or service JWTs.
revoke all on function public.matrix_v2_full_import_preview_raw_uat_v1(jsonb,text)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_v2_full_import_apply_raw_uat_v1(jsonb,text)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_v2_import_preview_alpha16(jsonb)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_v2_import_apply_alpha16(jsonb)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_v2_import_preview_uat_v2(jsonb)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_v2_import_apply_uat_v2(jsonb)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_v2_import_preview_uat_v3(jsonb,text)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_v2_import_apply_uat_v3(jsonb,text)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_v2_import_preview_uat_v4(jsonb,text)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_v2_import_apply_uat_v4(jsonb,text)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_v2_import_preview_uat_v5(jsonb,text)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_v2_import_apply_uat_v5(jsonb,text)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_v2_team_import_preview_uat_v1_core_20260814(jsonb,text)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_v2_team_import_preview_uat_v1_core_20260824(jsonb,text)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_v2_team_import_apply_uat_v1_core_20260824(jsonb,text)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_import_apply(text,jsonb,jsonb)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_create_draft(text)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_register_import(text,jsonb,jsonb)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_publish_draft(date)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_save_demand(uuid,uuid,integer,text)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_save_item(text,uuid,jsonb)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_save_shift(uuid,jsonb)
  from public,anon,authenticated,service_role;

-- Reassert the supported wrapper ACL after CREATE OR REPLACE.
revoke all on function public.matrix_v2_team_import_preview_uat_v1(jsonb,text)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_v2_team_import_apply_uat_v1(jsonb,text)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_v2_full_import_preview_uat_v1(jsonb,text)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_v2_full_import_apply_uat_v1(jsonb,text)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_v2_finance_import_preview_uat_v1(jsonb)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_v2_finance_import_apply_uat_v1(jsonb)
  from public,anon,authenticated,service_role;
grant execute on function public.matrix_v2_team_import_preview_uat_v1(jsonb,text),
  public.matrix_v2_team_import_apply_uat_v1(jsonb,text),
  public.matrix_v2_full_import_preview_uat_v1(jsonb,text),
  public.matrix_v2_full_import_apply_uat_v1(jsonb,text),
  public.matrix_v2_finance_import_preview_uat_v1(jsonb),
  public.matrix_v2_finance_import_apply_uat_v1(jsonb)
  to authenticated;

comment on table solver_private.single_company_boundary_uat_v1 is
  'AUD-008: current-version UAT safety boundary. One Supabase project equals one company; B4F-175 multi-tenant architecture remains out of scope.';
comment on function public.matrix_v2_claim_single_company_uat_v1(uuid) is
  'AUD-008 direct API proof: accepts only the existing project company boundary and rejects a second company atomically.';

commit;
