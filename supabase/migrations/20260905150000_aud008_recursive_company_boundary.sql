-- AUD-008 follow-up: reject company/tenant metadata at every JSON depth.
-- The current UAT remains a one-project/one-company system. B4F-175 is separate.
begin;

-- Do not wait indefinitely for Matrix writers during the controlled UAT change.
set local lock_timeout = '10s';
set local statement_timeout = '5min';

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

create or replace function solver_private.matrix_v2_reject_foreign_company_metadata_uat_v1(
  p_value jsonb,
  p_path text[] default array[]::text[],
  p_allow_workbook_boundary boolean default false,
  p_allow_root_boundary boolean default false
) returns void
language plpgsql
stable
security definer
set search_path=''
as $function$
declare
  v_key text;
  v_child jsonb;
  v_normalized_key text;
  v_candidate text;
  v_boundary uuid;
begin
  if p_value is null then return; end if;

  if jsonb_typeof(p_value)='array' then
    for v_child in select item.value from jsonb_array_elements(p_value) item loop
      perform solver_private.matrix_v2_reject_foreign_company_metadata_uat_v1(
        v_child,p_path||'[*]'::text,p_allow_workbook_boundary,
        p_allow_root_boundary
      );
    end loop;
    return;
  end if;
  if jsonb_typeof(p_value)<>'object' then return; end if;

  for v_key,v_child in select item.key,item.value from jsonb_each(p_value) item loop
    v_normalized_key:=lower(replace(v_key,'_',''));
    if v_normalized_key in ('organizationid','tenantid') then
      raise exception 'SECOND_COMPANY_FORBIDDEN';
    end if;
    if v_normalized_key='companyboundaryid' then
      if not (
        p_allow_workbook_boundary
          and p_path=array['_workbook']::text[]
          and v_key='companyBoundaryId'
        or p_allow_root_boundary
          and cardinality(p_path)=0
          and v_key='companyBoundaryId'
      ) then
        raise exception 'SECOND_COMPANY_FORBIDDEN';
      end if;
      if jsonb_typeof(v_child)<>'string' then
        raise exception 'SECOND_COMPANY_FORBIDDEN';
      end if;
      v_candidate:=nullif(trim(v_child#>>array[]::text[]),'');
      if v_candidate is null
        or not pg_catalog.pg_input_is_valid(v_candidate,'uuid') then
        raise exception 'SECOND_COMPANY_FORBIDDEN';
      end if;
      v_boundary:=solver_private.matrix_v2_current_company_boundary_uat_v1();
      if v_boundary is null then
        raise exception 'SINGLE_COMPANY_BOUNDARY_MISSING';
      end if;
      if v_candidate::uuid<>v_boundary then
        raise exception 'SECOND_COMPANY_FORBIDDEN';
      end if;
    else
      perform solver_private.matrix_v2_reject_foreign_company_metadata_uat_v1(
        v_child,p_path||v_key,p_allow_workbook_boundary,p_allow_root_boundary
      );
    end if;
  end loop;
end;
$function$;

revoke all on function
  solver_private.matrix_v2_reject_foreign_company_metadata_uat_v1(
    jsonb,text[],boolean,boolean
  ) from public,anon,authenticated,service_role;
grant execute on function
  solver_private.matrix_v2_reject_foreign_company_metadata_uat_v1(
    jsonb,text[],boolean,boolean
  ) to postgres;

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
  perform solver_private.matrix_v2_reject_foreign_company_metadata_uat_v1(
    p_configuration,array[]::text[],true,false
  );

  v_candidate:=nullif(trim(coalesce(
    p_configuration#>>'{_workbook,companyBoundaryId}',''
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

revoke all on function
  solver_private.matrix_v2_assert_single_company_payload_uat_v1(jsonb,boolean)
  from public,anon,authenticated,service_role;
grant execute on function
  solver_private.matrix_v2_assert_single_company_payload_uat_v1(jsonb,boolean)
  to postgres;

create or replace function solver_private.matrix_v2_reject_nested_company_settings_uat_v1()
returns trigger
language plpgsql
security definer
set search_path=''
as $function$
begin
  perform solver_private.matrix_v2_reject_foreign_company_metadata_uat_v1(
    coalesce(new.settings,'{}'::jsonb),array[]::text[],false,true
  );
  return new;
end;
$function$;

revoke all on function
  solver_private.matrix_v2_reject_nested_company_settings_uat_v1()
  from public,anon,authenticated,service_role;

-- Serialize preflight and trigger installation with all Matrix writers.
select pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
lock table public.matrix_versions in share row exclusive mode;
select pg_advisory_xact_lock(hashtext('matrix-v2-single-company-boundary'));

do $existing_payload_guard$
declare
  v_settings jsonb;
begin
  for v_settings in select settings from public.matrix_versions loop
    perform solver_private.matrix_v2_reject_foreign_company_metadata_uat_v1(
      coalesce(v_settings,'{}'::jsonb),array[]::text[],false,true
    );
  end loop;
end;
$existing_payload_guard$;

drop trigger if exists matrix_v2_recursive_company_boundary_uat_v1
  on public.matrix_versions;
create trigger matrix_v2_recursive_company_boundary_uat_v1
before insert or update of settings
on public.matrix_versions
for each row execute function
  solver_private.matrix_v2_reject_nested_company_settings_uat_v1();

create or replace function public.matrix_v2_company_boundary_uat_v1()
returns uuid
language plpgsql
stable
security definer
set search_path=''
as $function$
declare
  v_boundary uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (
    public.has_app_role('OWNER')
    or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE')
  ) then
    raise exception 'FORBIDDEN';
  end if;
  v_boundary:=solver_private.matrix_v2_current_company_boundary_uat_v1();
  if v_boundary is null then raise exception 'SINGLE_COMPANY_BOUNDARY_MISSING'; end if;
  return v_boundary;
end;
$function$;

revoke all on function public.matrix_v2_company_boundary_uat_v1()
  from public,anon,authenticated,service_role;
grant execute on function public.matrix_v2_company_boundary_uat_v1()
  to authenticated;

-- Onboarding is a supported authenticated entry point on the live UAT. Reassert
-- the exact ACL so a clean baseline rebuild cannot silently make it unreachable.
revoke all on function public.matrix_v2_ensure_first_run_uat_v1()
  from public,anon,authenticated,service_role;
grant execute on function public.matrix_v2_ensure_first_run_uat_v1()
  to authenticated;

-- Close two historic import implementations explicitly, even though their
-- current ACL is already postgres-only. They must never become Data API paths.
revoke all on function public.matrix_v2_import_preview_before_mx_k10(jsonb)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_v2_import_apply_before_mx_k10(jsonb)
  from public,anon,authenticated,service_role;
grant execute on function public.matrix_v2_import_preview_before_mx_k10(jsonb),
  public.matrix_v2_import_apply_before_mx_k10(jsonb)
  to postgres;

comment on function
  solver_private.matrix_v2_reject_foreign_company_metadata_uat_v1(
    jsonb,text[],boolean,boolean
  ) is 'AUD-008 fail-closed recursive detector for organization, tenant and company-boundary metadata. B4F-175 remains a separate future decision.';

commit;
