\set ON_ERROR_STOP on
begin;

do $$
declare
  v_boundary uuid;
begin
  select boundary_id into strict v_boundary
  from solver_private.single_company_boundary_uat_v1
  where singleton_key=1;
  if v_boundary<>'a0080000-0000-4000-8000-000000000001'::uuid then
    raise exception 'AUD008_FIRST_COMPANY_BOUNDARY_INVALID';
  end if;
  if (select count(*) from public.matrix_versions
      where schema_version>=2 and base_version_id is null)>1 then
    raise exception 'AUD008_MULTIPLE_COMPANY_ROOTS';
  end if;
  if to_regclass('public.matrix_versions_single_company_root_uat_v1') is null
    or to_regclass('public.matrix_versions_single_draft_uat_v1') is null
    or to_regclass('public.matrix_versions_single_active_uat_v1') is null then
    raise exception 'AUD008_ATOMIC_INDEX_MISSING';
  end if;
end $$;

insert into auth.users(
  instance_id,id,aud,role,email,encrypted_password,
  raw_app_meta_data,raw_user_meta_data,is_super_admin,created_at,updated_at
)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',
  email,'','{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,
  false,now(),now()
from (values
  ('a0081000-0000-4000-8000-000000000001'::uuid,'aud008-owner@example.invalid'),
  ('a0081000-0000-4000-8000-000000000002'::uuid,'aud008-manager@example.invalid'),
  ('a0081000-0000-4000-8000-000000000003'::uuid,'aud008-employee@example.invalid'),
  ('a0081000-0000-4000-8000-000000000004'::uuid,'aud008-multirole@example.invalid'),
  ('a0081000-0000-4000-8000-000000000005'::uuid,'aud008-finance@example.invalid'),
  ('a0081000-0000-4000-8000-000000000006'::uuid,'aud008-location-manager@example.invalid'),
  ('a0081000-0000-4000-8000-000000000007'::uuid,'aud008-manager-employee@example.invalid')
) fixture(id,email);

insert into public.user_permissions(auth_user_id,app_role) values
  ('a0081000-0000-4000-8000-000000000001','OWNER'),
  ('a0081000-0000-4000-8000-000000000002','ROLE_MANAGER'),
  ('a0081000-0000-4000-8000-000000000003','EMPLOYEE'),
  ('a0081000-0000-4000-8000-000000000004','OWNER'),
  ('a0081000-0000-4000-8000-000000000004','EMPLOYEE'),
  ('a0081000-0000-4000-8000-000000000005','HR_FINANCE'),
  ('a0081000-0000-4000-8000-000000000006','LOCATION_MANAGER'),
  ('a0081000-0000-4000-8000-000000000007','ROLE_MANAGER'),
  ('a0081000-0000-4000-8000-000000000007','EMPLOYEE');

create or replace function pg_temp.aud008_business_state()
returns jsonb
language sql
stable
security definer
set search_path=''
as $function$
  select jsonb_build_object(
    'versions',(select count(*) from public.matrix_versions),
    'versionsDigest',(select md5(coalesce(jsonb_agg(to_jsonb(row) order by to_jsonb(row)::text)::text,'[]')) from public.matrix_versions row),
    'imports',(select count(*) from public.matrix_import_runs),
    'importsDigest',(select md5(coalesce(jsonb_agg(to_jsonb(row) order by to_jsonb(row)::text)::text,'[]')) from public.matrix_import_runs row),
    'categories',(select count(*) from public.matrix_role_categories_v2),
    'categoriesDigest',(select md5(coalesce(jsonb_agg(to_jsonb(row) order by to_jsonb(row)::text)::text,'[]')) from public.matrix_role_categories_v2 row),
    'roles',(select count(*) from public.matrix_roles_v2),
    'rolesDigest',(select md5(coalesce(jsonb_agg(to_jsonb(row) order by to_jsonb(row)::text)::text,'[]')) from public.matrix_roles_v2 row),
    'duties',(select count(*) from public.matrix_duties_v2),
    'dutiesDigest',(select md5(coalesce(jsonb_agg(to_jsonb(row) order by to_jsonb(row)::text)::text,'[]')) from public.matrix_duties_v2 row),
    'roleDuties',(select count(*) from public.matrix_role_duties_v2),
    'roleDutiesDigest',(select md5(coalesce(jsonb_agg(to_jsonb(row) order by to_jsonb(row)::text)::text,'[]')) from public.matrix_role_duties_v2 row),
    'locations',(select count(*) from public.matrix_locations_v2),
    'locationsDigest',(select md5(coalesce(jsonb_agg(to_jsonb(row) order by to_jsonb(row)::text)::text,'[]')) from public.matrix_locations_v2 row),
    'shifts',(select count(*) from public.matrix_shift_templates_v2),
    'shiftsDigest',(select md5(coalesce(jsonb_agg(to_jsonb(row) order by to_jsonb(row)::text)::text,'[]')) from public.matrix_shift_templates_v2 row),
    'profiles',(select count(*) from public.matrix_employee_profiles_v2),
    'profilesDigest',(select md5(coalesce(jsonb_agg(to_jsonb(row) order by to_jsonb(row)::text)::text,'[]')) from public.matrix_employee_profiles_v2 row),
    'employees',(select count(*) from public.employees),
    'employeesDigest',(select md5(coalesce(jsonb_agg(to_jsonb(row) order by to_jsonb(row)::text)::text,'[]')) from public.employees row),
    'employeeHr',(select count(*) from public.employee_hr_profiles),
    'employeeHrDigest',(select md5(coalesce(jsonb_agg(to_jsonb(row) order by to_jsonb(row)::text)::text,'[]')) from public.employee_hr_profiles row),
    'employeePayRates',(select count(*) from public.employee_pay_rates_v2),
    'employeePayRatesDigest',(select md5(coalesce(jsonb_agg(to_jsonb(row) order by to_jsonb(row)::text)::text,'[]')) from public.employee_pay_rates_v2 row),
    'employeeRoles',(select count(*) from public.matrix_employee_roles_v2),
    'employeeRolesDigest',(select md5(coalesce(jsonb_agg(to_jsonb(row) order by to_jsonb(row)::text)::text,'[]')) from public.matrix_employee_roles_v2 row),
    'employeeDuties',(select count(*) from public.matrix_employee_duties_v2),
    'employeeDutiesDigest',(select md5(coalesce(jsonb_agg(to_jsonb(row) order by to_jsonb(row)::text)::text,'[]')) from public.matrix_employee_duties_v2 row),
    'employeeLocations',(select count(*) from public.matrix_employee_locations_v2),
    'employeeLocationsDigest',(select md5(coalesce(jsonb_agg(to_jsonb(row) order by to_jsonb(row)::text)::text,'[]')) from public.matrix_employee_locations_v2 row),
    'payRules',(select count(*) from public.matrix_pay_rules_v2),
    'payRulesDigest',(select md5(coalesce(jsonb_agg(to_jsonb(row) order by to_jsonb(row)::text)::text,'[]')) from public.matrix_pay_rules_v2 row),
    'auditLog',(select count(*) from public.audit_log),
    'auditLogDigest',(select md5(coalesce(jsonb_agg(to_jsonb(row) order by to_jsonb(row)::text)::text,'[]')) from public.audit_log row)
  )
$function$;

grant execute on function pg_temp.aud008_business_state() to authenticated;

create or replace function pg_temp.aud008_team_fixture_applied(p_employee_no text)
returns boolean
language sql
stable
security definer
set search_path=''
as $function$
  select exists(
    select 1
    from public.matrix_employee_profiles_v2 profile
    join public.matrix_versions version on version.id=profile.matrix_version_id
    join public.matrix_employee_roles_v2 employee_role
      on employee_role.matrix_version_id=profile.matrix_version_id
     and employee_role.employee_id=profile.employee_id
     and employee_role.is_primary and employee_role.active
    join public.matrix_roles_v2 role_row on role_row.id=employee_role.role_id
    join public.matrix_employee_locations_v2 employee_location
      on employee_location.matrix_version_id=profile.matrix_version_id
     and employee_location.employee_id=profile.employee_id
     and employee_location.active
    join public.matrix_locations_v2 location_row on location_row.id=employee_location.location_id
    where profile.employee_no=p_employee_no and profile.active
      and version.status='DRAFT' and role_row.code='KELNER'
      and location_row.code='KRUCZA'
  )
$function$;

grant execute on function pg_temp.aud008_team_fixture_applied(text) to authenticated;

create or replace function pg_temp.aud008_claim_without_boundary()
returns void
language plpgsql
security definer
set search_path=''
as $function$
begin
  delete from solver_private.single_company_boundary_uat_v1
  where singleton_key=1;
  perform public.matrix_v2_claim_single_company_uat_v1(
    'a0080000-0000-4000-8000-000000000001'
  );
end
$function$;

grant execute on function pg_temp.aud008_claim_without_boundary() to authenticated;

create or replace function pg_temp.aud008_boundary_is_canonical()
returns boolean
language sql
stable
security definer
set search_path=''
as $function$
  select exists(
    select 1 from solver_private.single_company_boundary_uat_v1
    where singleton_key=1
      and boundary_id='a0080000-0000-4000-8000-000000000001'::uuid
  )
$function$;

grant execute on function pg_temp.aud008_boundary_is_canonical() to authenticated;

set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','a0081000-0000-4000-8000-000000000001',true);

do $$
declare
  v_result jsonb;
  v_configuration jsonb;
  v_finance jsonb;
  v_matrix uuid;
  v_rate uuid;
  v_employee_no text;
  v_versions bigint;
  v_state_before jsonb;
  v_state_after jsonb;
begin
  v_result:=public.matrix_v2_ensure_first_run_uat_v1();
  v_matrix:=(v_result->>'matrixVersionId')::uuid;
  if v_matrix is null
    or (select count(*) from public.matrix_versions
        where schema_version>=2 and base_version_id is null)<>1
    or (select count(*) from public.matrix_versions
        where schema_version>=2 and status='DRAFT')<>1 then
    raise exception 'AUD008_FIRST_COMPANY_ONBOARDING_FAILED';
  end if;

  v_result:=public.matrix_v2_claim_single_company_uat_v1(
    'a0080000-0000-4000-8000-000000000001'
  );
  if coalesce((v_result->>'accepted')::boolean,false) is not true then
    raise exception 'AUD008_FIRST_COMPANY_REJECTED';
  end if;

  v_configuration:=jsonb_build_object(
    '_workbook',jsonb_build_object(
      'mode','EMPTY_TEMPLATE',
      'contractVersion','2',
      'companyBoundaryId','a0080000-0000-4000-8000-000000000001'
    ),
    'roleCategories',jsonb_build_array(jsonb_build_object(
      'code','SALA','name','Sala','sortOrder','1','active',true,'sourceRow',2
    )),
    'roles',jsonb_build_array(jsonb_build_object(
      'code','KELNER','name','Kelner','categoryCode','SALA',
      'sortOrder','1','active',true,'sourceRow',2
    )),
    'locations',jsonb_build_array(jsonb_build_object(
      'code','KRUCZA','name','Krucza','sortOrder','1','active',true,'sourceRow',2
    )),
    'duties','[]'::jsonb,
    'employees',jsonb_build_array(jsonb_build_object(
      'employeeNo','','firstName','Audyt','lastName','Import',
      'email','aud008-team-positive@example.invalid','primaryRoleCode','KELNER',
      'locationCodes',jsonb_build_array('KRUCZA'),'contractType','ZLECENIE',
      'active',true,'sourceRow',2
    )),
    'employeeRoles','[]'::jsonb,
    'employeeLocationsDetailed','[]'::jsonb,
    'employeeCapabilities','[]'::jsonb,
    'timeConstraints','[]'::jsonb,
    'staffingRules','[]'::jsonb
  );
  v_result:=public.matrix_v2_team_import_preview_uat_v1(v_configuration,'UPDATE');
  if coalesce((v_result->>'valid')::boolean,false) is not true
    or v_result->>'companyBoundaryId'<>
      'a0080000-0000-4000-8000-000000000001'
    or v_result#>>'{workbookIdentity,contractVersion}'<>'2' then
    raise exception 'AUD008_FIRST_COMPANY_TEAM_PREVIEW_REJECTED:%',v_result;
  end if;
  v_result:=public.matrix_v2_team_import_apply_uat_v1(v_configuration,'UPDATE');
  if coalesce((v_result->>'atomic')::boolean,false) is not true
    or v_result->>'scope'<>'TEAM_AND_STRUCTURE'
    or coalesce((v_result->>'financeDeferred')::boolean,false) is not true
    or v_result->>'validationOrder'<>'STRUCTURE_THEN_RELATIONS'
    or v_result->>'companyBoundaryId'<>
      'a0080000-0000-4000-8000-000000000001'
    or v_result#>>'{workbookIdentity,contractVersion}'<>'2' then
    raise exception 'AUD008_FIRST_COMPANY_TEAM_APPLY_REJECTED:%',v_result;
  end if;
  select employee_no into strict v_employee_no
  from public.employees
  where email='aud008-team-positive@example.invalid';
  if v_employee_no is null
    or not pg_temp.aud008_team_fixture_applied(v_employee_no) then
    raise exception 'AUD008_FIRST_COMPANY_TEAM_APPLY_INCOMPLETE';
  end if;
  v_finance:=jsonb_build_object(
    '_workbook',jsonb_build_object(
      'mode','EMPTY_TEMPLATE','contractVersion','2',
      'companyBoundaryId','a0080000-0000-4000-8000-000000000001'
    ),
    'payRates',jsonb_build_array(jsonb_build_object(
      'sourceRow',2,'rateId','','employeeNo',v_employee_no,
      'validFrom','2026-09-01','validTo','','baseRate','30.00',
      'currency','PLN','contractType','ZLECENIE','active','true'
    ))
  );
  v_result:=public.matrix_v2_finance_import_apply_uat_v1(v_finance);
  if coalesce((v_result->>'appliedRows')::integer,0)<>1
    or coalesce((v_result#>>'{summary,rows}')::integer,0)<>1
    or coalesce((v_result#>>'{summary,employees}')::integer,0)<>1
    or coalesce((v_result#>>'{summary,create}')::integer,0)<>1 then
    raise exception 'AUD008_FIRST_COMPANY_FINANCE_APPLY_REJECTED:%',v_result;
  end if;
  select id into strict v_rate
  from public.employee_pay_rates_v2
  where employee_id=(
    select id from public.employees
    where email='aud008-team-positive@example.invalid'
  ) and valid_from='2026-09-01' and active;
  v_finance:=jsonb_set(
    v_finance,'{payRates,0,rateId}',to_jsonb(v_rate::text),true
  );
  v_state_before:=pg_temp.aud008_business_state();
  v_result:=public.matrix_v2_full_import_preview_uat_v1(
    jsonb_build_object('configuration',v_configuration,'finance',v_finance),
    'UPDATE'
  );
  v_state_after:=pg_temp.aud008_business_state();
  if v_state_after is distinct from v_state_before then
    raise exception 'AUD008_FIRST_COMPANY_FULL_PREVIEW_MUTATED_STATE:%:%',
      v_state_before,v_state_after;
  end if;
  if coalesce((v_result->>'valid')::boolean,false) is not true
    or coalesce((v_result#>>'{configuration,valid}')::boolean,false) is not true
    or coalesce((v_result#>>'{finance,valid}')::boolean,false) is not true
    or jsonb_array_length(coalesce(v_result->'errors','[]'::jsonb))<>0
    or coalesce((v_result#>>'{summary,financeRows}')::integer,0)<>1
    or coalesce((v_result#>>'{finance,summary,unchanged}')::integer,0)<>1 then
    raise exception 'AUD008_FIRST_COMPANY_FULL_PREVIEW_REJECTED:%',v_result;
  end if;
  v_result:=public.matrix_v2_full_import_apply_uat_v1(
    jsonb_build_object('configuration',v_configuration,'finance',v_finance),
    'UPDATE'
  );
  if coalesce((v_result->>'atomic')::boolean,false) is not true
    or v_result->>'scope'<>'FULL_COMPANY'
    or coalesce((v_result#>>'{finance,appliedRows}')::integer,-1)<>0
    or coalesce((v_result#>>'{finance,summary,unchanged}')::integer,0)<>1
    or not exists(
    select 1 from public.employee_pay_rates_v2
    where id=v_rate and base_rate_minor=3000 and currency='PLN'
      and contract_type='ZLECENIE' and active
  ) then
    raise exception 'AUD008_FIRST_COMPANY_FULL_APPLY_REJECTED:%',v_result;
  end if;

  v_state_before:=pg_temp.aud008_business_state();
  begin
    perform public.matrix_v2_full_import_apply_uat_v1(
      jsonb_build_object(
        'configuration',jsonb_set(
          v_configuration,'{employees,0,lastName}',to_jsonb('Do wycofania'::text),true
        ),
        'finance',jsonb_set(
          v_finance,'{payRates,0,currency}',to_jsonb('EUR'::text),true
        )
      ),
      'UPDATE'
    );
    raise exception 'AUD008_FULL_APPLY_LATE_FINANCE_ERROR_NOT_RAISED';
  exception when others then
    if sqlerrm not like '%FINANCE_IMPORT_HAS_ERRORS%' then raise; end if;
  end;
  v_state_after:=pg_temp.aud008_business_state();
  if v_state_after is distinct from v_state_before then
    raise exception 'AUD008_FULL_APPLY_LATE_ERROR_LEFT_PARTIAL_DATA:%:%',
      v_state_before,v_state_after;
  end if;
  begin
    perform public.matrix_v2_claim_single_company_uat_v1(
      'a0080000-0000-4000-8000-000000000002'
    );
    raise exception 'AUD008_SECOND_COMPANY_CLAIM_ALLOWED';
  exception when others then
    if sqlerrm not like '%SECOND_COMPANY_FORBIDDEN%' then raise; end if;
  end;

  begin
    perform pg_temp.aud008_claim_without_boundary();
    raise exception 'AUD008_MISSING_BOUNDARY_CLAIM_ALLOWED';
  exception when others then
    if sqlerrm not like '%SINGLE_COMPANY_BOUNDARY_MISSING%' then raise; end if;
  end;
  if not pg_temp.aud008_boundary_is_canonical() then
    raise exception 'AUD008_MISSING_BOUNDARY_TEST_DID_NOT_ROLL_BACK';
  end if;

  select count(*) into v_versions from public.matrix_versions;
  v_state_before:=pg_temp.aud008_business_state();

  foreach v_result in array array[
    '{}'::jsonb,
    '{"_workbook":{"companyBoundaryId":"not-a-uuid"}}'::jsonb,
    '{"_workbook":{"companyBoundaryId":"a0080000-0000-4000-8000-000000000002"}}'::jsonb,
    '{"companyBoundaryId":"a0080000-0000-4000-8000-000000000001","_workbook":{"companyBoundaryId":"a0080000-0000-4000-8000-000000000001"}}'::jsonb,
    '{"organization_id":"foreign","_workbook":{"companyBoundaryId":"a0080000-0000-4000-8000-000000000001"}}'::jsonb,
    '{"tenant_id":"foreign","_workbook":{"companyBoundaryId":"a0080000-0000-4000-8000-000000000001"}}'::jsonb,
    '{"_workbook":{"organization_id":"foreign","companyBoundaryId":"a0080000-0000-4000-8000-000000000001"}}'::jsonb,
    '{"_workbook":{"tenant_id":"foreign","companyBoundaryId":"a0080000-0000-4000-8000-000000000001"}}'::jsonb,
    '{"_workbook":{"companyBoundaryId":"a0080000-0000-4000-8000-000000000001"},"employees":[{"metadata":{"organizationId":"foreign"}}]}'::jsonb,
    '{"_workbook":{"companyBoundaryId":"a0080000-0000-4000-8000-000000000001"},"roles":[{"settings":{"tenant_id":"foreign"}}]}'::jsonb,
    '{"_workbook":{"companyBoundaryId":"a0080000-0000-4000-8000-000000000001"},"finance":{"nested":{"companyBoundaryId":"a0080000-0000-4000-8000-000000000001"}}}'::jsonb,
    '{"_workbook":{"CompanyBoundaryId":"a0080000-0000-4000-8000-000000000001","companyBoundaryId":"a0080000-0000-4000-8000-000000000001"}}'::jsonb
  ] loop
    begin
      perform public.matrix_v2_team_import_preview_uat_v1(v_result,'UPDATE');
      raise exception 'AUD008_UNTRUSTED_TEAM_PREVIEW_ALLOWED';
    exception when others then
      if sqlerrm not like '%WORKBOOK_COMPANY_BOUNDARY_REQUIRED%'
        and sqlerrm not like '%WORKBOOK_COMPANY_BOUNDARY_INVALID%'
        and sqlerrm not like '%SECOND_COMPANY_FORBIDDEN%' then raise; end if;
    end;
    begin
      perform public.matrix_v2_team_import_apply_uat_v1(v_result,'UPDATE');
      raise exception 'AUD008_UNTRUSTED_TEAM_IMPORT_ALLOWED';
    exception when others then
      if sqlerrm not like '%WORKBOOK_COMPANY_BOUNDARY_REQUIRED%'
        and sqlerrm not like '%WORKBOOK_COMPANY_BOUNDARY_INVALID%'
        and sqlerrm not like '%SECOND_COMPANY_FORBIDDEN%' then raise; end if;
    end;
    begin
      perform public.matrix_v2_full_import_preview_uat_v1(
        jsonb_build_object('configuration',v_result),'UPDATE'
      );
      raise exception 'AUD008_UNTRUSTED_FULL_PREVIEW_ALLOWED';
    exception when others then
      if sqlerrm not like '%WORKBOOK_COMPANY_BOUNDARY_REQUIRED%'
        and sqlerrm not like '%WORKBOOK_COMPANY_BOUNDARY_INVALID%'
        and sqlerrm not like '%SECOND_COMPANY_FORBIDDEN%' then raise; end if;
    end;
    begin
      perform public.matrix_v2_full_import_apply_uat_v1(
        jsonb_build_object('configuration',v_result),'UPDATE'
      );
      raise exception 'AUD008_UNTRUSTED_FULL_IMPORT_ALLOWED';
    exception when others then
      if sqlerrm not like '%WORKBOOK_COMPANY_BOUNDARY_REQUIRED%'
        and sqlerrm not like '%WORKBOOK_COMPANY_BOUNDARY_INVALID%'
        and sqlerrm not like '%SECOND_COMPANY_FORBIDDEN%' then raise; end if;
    end;
    begin
      perform public.matrix_v2_finance_import_preview_uat_v1(v_result);
      raise exception 'AUD008_UNTRUSTED_FINANCE_PREVIEW_ALLOWED';
    exception when others then
      if sqlerrm not like '%WORKBOOK_COMPANY_BOUNDARY_REQUIRED%'
        and sqlerrm not like '%WORKBOOK_COMPANY_BOUNDARY_INVALID%'
        and sqlerrm not like '%SECOND_COMPANY_FORBIDDEN%' then raise; end if;
    end;
    begin
      perform public.matrix_v2_finance_import_apply_uat_v1(v_result);
      raise exception 'AUD008_UNTRUSTED_FINANCE_IMPORT_ALLOWED';
    exception when others then
      if sqlerrm not like '%WORKBOOK_COMPANY_BOUNDARY_REQUIRED%'
        and sqlerrm not like '%WORKBOOK_COMPANY_BOUNDARY_INVALID%'
        and sqlerrm not like '%SECOND_COMPANY_FORBIDDEN%' then raise; end if;
    end;
  end loop;

  foreach v_result in array array[
    '{}'::jsonb,
    '{"_workbook":{"companyBoundaryId":"a0080000-0000-4000-8000-000000000002"}}'::jsonb
  ] loop
    begin
      perform public.matrix_v2_full_import_preview_uat_v1(
        jsonb_build_object('configuration',v_configuration,'finance',v_result),
        'UPDATE'
      );
      raise exception 'AUD008_UNTRUSTED_NESTED_FINANCE_PREVIEW_ALLOWED';
    exception when others then
      if sqlerrm not like '%WORKBOOK_COMPANY_BOUNDARY_REQUIRED%'
        and sqlerrm not like '%SECOND_COMPANY_FORBIDDEN%' then raise; end if;
    end;
    begin
      perform public.matrix_v2_full_import_apply_uat_v1(
        jsonb_build_object('configuration',v_configuration,'finance',v_result),
        'UPDATE'
      );
      raise exception 'AUD008_UNTRUSTED_NESTED_FINANCE_IMPORT_ALLOWED';
    exception when others then
      if sqlerrm not like '%WORKBOOK_COMPANY_BOUNDARY_REQUIRED%'
        and sqlerrm not like '%SECOND_COMPANY_FORBIDDEN%' then raise; end if;
    end;
  end loop;

  begin
    perform public.matrix_v2_full_import_apply_uat_v1(
      jsonb_build_object('configuration',jsonb_build_object(
        '_workbook',jsonb_build_object(
          'companyBoundaryId','a0080000-0000-4000-8000-000000000002'
        )
      )),'UPDATE'
    );
    raise exception 'AUD008_FOREIGN_FULL_IMPORT_ALLOWED';
  exception when others then
    if sqlerrm not like '%SECOND_COMPANY_FORBIDDEN%' then raise; end if;
  end;
  if (select count(*) from public.matrix_versions)<>v_versions then
    raise exception 'AUD008_REJECTED_IMPORT_LEFT_PARTIAL_DATA';
  end if;
  v_state_after:=pg_temp.aud008_business_state();
  if v_state_after is distinct from v_state_before then
    raise exception 'AUD008_REJECTED_IMPORT_CHANGED_BUSINESS_STATE:%:%',
      v_state_before,v_state_after;
  end if;
end $$;

reset role;
do $$
declare
  v_matrix uuid;
  v_employee uuid:='a0082000-0000-4000-8000-000000000001';
begin
  select id into strict v_matrix from public.matrix_versions
  where status='DRAFT' and schema_version>=2;
  insert into public.employees(
    id,employee_no,first_name,last_name,email,monthly_nominal_minutes,
    max_weekly_minutes,max_monthly_minutes,active
  ) values(
    v_employee,'GP-A008','Audyt','Firma',
    'aud008-finance-positive@example.invalid',9600,2400,12000,true
  );
  insert into public.matrix_employee_profiles_v2(
    matrix_version_id,employee_id,employee_no,first_name,last_name,email,active,
    nominal_monthly_minutes,maximum_monthly_minutes,maximum_weekly_minutes,
    maximum_consecutive_days
  ) values(
    v_matrix,v_employee,'GP-A008','Audyt','Firma',
    'aud008-finance-positive@example.invalid',true,9600,12000,2400,6
  );
end $$;

set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','a0081000-0000-4000-8000-000000000002',true);
do $$ begin
  begin
    perform public.matrix_v2_claim_single_company_uat_v1(
      'a0080000-0000-4000-8000-000000000001'
    );
    raise exception 'AUD008_MANAGER_CLAIM_ALLOWED';
  exception when others then
    if sqlerrm not like '%FORBIDDEN%' then raise; end if;
  end;
  begin
    perform public.matrix_v2_team_import_preview_uat_v1(
      jsonb_build_object('_workbook',jsonb_build_object(
        'companyBoundaryId','a0080000-0000-4000-8000-000000000001'
      )),'UPDATE'
    );
    raise exception 'AUD008_ROLE_MANAGER_IMPORT_ALLOWED';
  exception when others then
    if sqlerrm not like '%FORBIDDEN%' then raise; end if;
  end;
end $$;

select set_config('request.jwt.claim.sub','a0081000-0000-4000-8000-000000000006',true);
do $$ begin
  begin
    perform public.matrix_v2_team_import_preview_uat_v1(
      jsonb_build_object('_workbook',jsonb_build_object(
        'companyBoundaryId','a0080000-0000-4000-8000-000000000001'
      )),'UPDATE'
    );
    raise exception 'AUD008_LOCATION_MANAGER_IMPORT_ALLOWED';
  exception when others then
    if sqlerrm not like '%FORBIDDEN%' then raise; end if;
  end;
end $$;

select set_config('request.jwt.claim.sub','a0081000-0000-4000-8000-000000000007',true);
do $$ begin
  begin
    perform public.matrix_v2_team_import_preview_uat_v1(
      jsonb_build_object('_workbook',jsonb_build_object(
        'companyBoundaryId','a0080000-0000-4000-8000-000000000001'
      )),'UPDATE'
    );
    raise exception 'AUD008_MANAGER_EMPLOYEE_IMPORT_ALLOWED';
  exception when others then
    if sqlerrm not like '%FORBIDDEN%' then raise; end if;
  end;
end $$;

select set_config('request.jwt.claim.sub','a0081000-0000-4000-8000-000000000005',true);
do $$
declare
  v_boundary uuid;
  v_result jsonb;
  v_payload jsonb;
begin
  v_boundary:=public.matrix_v2_company_boundary_uat_v1();
  if v_boundary<>'a0080000-0000-4000-8000-000000000001'::uuid then
    raise exception 'AUD008_HR_FINANCE_BOUNDARY_LOOKUP_FAILED';
  end if;
  v_payload:=jsonb_build_object(
    '_workbook',jsonb_build_object(
      'companyBoundaryId','a0080000-0000-4000-8000-000000000001'
    ),
    'payRates',jsonb_build_array(jsonb_build_object(
      'sourceRow',2,
      'rateId','',
      'employeeNo','GP-A008',
      'validFrom','2026-09-01',
      'validTo','',
      'baseRate','30.00',
      'currency','PLN',
      'contractType','UMOWA_O_PRACE',
      'active','true'
    ))
  );
  v_result:=public.matrix_v2_finance_import_preview_uat_v1(v_payload);
  if coalesce((v_result->>'valid')::boolean,false) is not true
    or coalesce((v_result#>>'{summary,rows}')::integer,0)<>1 then
    raise exception 'AUD008_HR_FINANCE_FIRST_COMPANY_PREVIEW_FAILED:%',v_result;
  end if;
  v_result:=public.matrix_v2_finance_import_apply_uat_v1(v_payload);
  if coalesce((v_result->>'appliedRows')::integer,0)<>1
    or not exists(
      select 1 from public.employee_pay_rates_v2 rate
      join public.employees employee on employee.id=rate.employee_id
      where employee.employee_no='GP-A008' and rate.base_rate_minor=3000
        and rate.currency='PLN' and rate.contract_type='UMOWA_O_PRACE'
        and rate.active
    ) then
    raise exception 'AUD008_HR_FINANCE_FIRST_COMPANY_APPLY_FAILED:%',v_result;
  end if;
  begin
    perform public.matrix_v2_finance_import_preview_uat_v1(
      jsonb_build_object(
        '_workbook',jsonb_build_object(
          'companyBoundaryId','a0080000-0000-4000-8000-000000000002'
        )
      )
    );
    raise exception 'AUD008_HR_FINANCE_FOREIGN_COMPANY_ALLOWED';
  exception when others then
    if sqlerrm not like '%SECOND_COMPANY_FORBIDDEN%' then raise; end if;
  end;
end $$;

select set_config('request.jwt.claim.sub','a0081000-0000-4000-8000-000000000003',true);
do $$ begin
  begin
    perform public.matrix_v2_team_import_preview_uat_v1(
      jsonb_build_object('_workbook',jsonb_build_object(
        'companyBoundaryId','a0080000-0000-4000-8000-000000000001'
      )),'UPDATE'
    );
    raise exception 'AUD008_EMPLOYEE_IMPORT_ALLOWED';
  exception when others then
    if sqlerrm not like '%FORBIDDEN%' then raise; end if;
  end;
  begin
    perform public.matrix_v2_claim_single_company_uat_v1(
      'a0080000-0000-4000-8000-000000000001'
    );
    raise exception 'AUD008_EMPLOYEE_CLAIM_ALLOWED';
  exception when others then
    if sqlerrm not like '%FORBIDDEN%' then raise; end if;
  end;
end $$;

select set_config('request.jwt.claim.sub','a0081000-0000-4000-8000-000000000004',true);
do $$ begin
  perform public.matrix_v2_claim_single_company_uat_v1(
    'a0080000-0000-4000-8000-000000000001'
  );
  begin
    perform public.matrix_v2_claim_single_company_uat_v1(
      'a0080000-0000-4000-8000-000000000002'
    );
    raise exception 'AUD008_MULTIROLE_SECOND_COMPANY_ALLOWED';
  exception when others then
    if sqlerrm not like '%SECOND_COMPANY_FORBIDDEN%' then raise; end if;
  end;
end $$;

reset role;
select set_config('request.jwt.claim.sub','',true);
select set_config('request.jwt.claim.role','anon',true);
set local role anon;
do $$ begin
  begin
    perform public.matrix_v2_claim_single_company_uat_v1(
      'a0080000-0000-4000-8000-000000000001'
    );
    raise exception 'AUD008_ANON_CLAIM_ALLOWED';
  exception when insufficient_privilege then null;
  end;
end $$;

reset role;
set local role service_role;
do $$
declare
  v_version integer;
  v_root uuid;
begin
  select coalesce(max(version),0)+1 into v_version from public.matrix_versions;
  select id into strict v_root from public.matrix_versions
  where schema_version>=2 and base_version_id is null;
  begin
    insert into public.matrix_versions(
      version,name,status,effective_from,settings,schema_version
    ) values(
      v_version,'AUD008 legacy root','ARCHIVED',current_date,'{}'::jsonb,1
    );
    raise exception 'AUD008_DIRECT_LEGACY_ROOT_ALLOWED';
  exception when others then
    if sqlerrm not like '%LEGACY_COMPANY_VERSION_DISABLED%' then raise; end if;
  end;
  v_version:=v_version+1;
  begin
    insert into public.matrix_versions(
      version,name,status,effective_from,settings,schema_version
    ) values(
      v_version,'AUD008 drugi korzeń bez metadanych','ARCHIVED',current_date,
      '{}'::jsonb,2
    );
    raise exception 'AUD008_DIRECT_SECOND_ROOT_WITHOUT_METADATA_ALLOWED';
  exception when others then
    if sqlerrm not like '%SECOND_COMPANY_FORBIDDEN%' then raise; end if;
  end;
  v_version:=v_version+1;
  begin
    insert into public.matrix_versions(
      version,name,status,effective_from,settings,schema_version
    ) values(
      v_version,'AUD008 druga firma','ARCHIVED',current_date,
      '{"companyBoundaryId":"a0080000-0000-4000-8000-000000000002"}'::jsonb,2
    );
    raise exception 'AUD008_DIRECT_API_SECOND_COMPANY_ALLOWED';
  exception when others then
    if sqlerrm not like '%SECOND_COMPANY_FORBIDDEN%' then raise; end if;
  end;
  v_version:=v_version+1;
  begin
    insert into public.matrix_versions(
      version,name,status,effective_from,settings,schema_version,base_version_id
    ) values(
      v_version,'AUD008 obca firma jako potomek','ARCHIVED',current_date,
      '{"companyBoundaryId":"a0080000-0000-4000-8000-000000000002"}'::jsonb,
      2,v_root
    );
    raise exception 'AUD008_DIRECT_FOREIGN_CHILD_ALLOWED';
  exception when others then
    if sqlerrm not like '%SECOND_COMPANY_FORBIDDEN%' then raise; end if;
  end;
  v_version:=v_version+1;
  begin
    insert into public.matrix_versions(
      version,name,status,effective_from,settings,schema_version,base_version_id
    ) values(
      v_version,'AUD008 obcy tenant jako potomek','ARCHIVED',current_date,
      '{"tenantId":"a008-foreign-company"}'::jsonb,2,v_root
    );
    raise exception 'AUD008_DIRECT_FOREIGN_TENANT_CHILD_ALLOWED';
  exception when others then
    if sqlerrm not like '%SECOND_COMPANY_FORBIDDEN%' then raise; end if;
  end;
  v_version:=v_version+1;
  begin
    insert into public.matrix_versions(
      version,name,status,effective_from,settings,schema_version,base_version_id
    ) values(
      v_version,'AUD008 zagnieżdżona obca firma','ARCHIVED',current_date,
      '{"ui":{"metadata":{"organizationId":"a008-foreign-company"}}}'::jsonb,
      2,v_root
    );
    raise exception 'AUD008_DIRECT_NESTED_FOREIGN_COMPANY_ALLOWED';
  exception when others then
    if sqlerrm not like '%SECOND_COMPANY_FORBIDDEN%' then raise; end if;
  end;
end $$;

reset role;
do $$
declare
  v_forbidden text[]:=array[
    'matrix_create_draft(text)',
    'matrix_register_import(text,jsonb,jsonb)',
    'matrix_import_apply(text,jsonb,jsonb)',
    'matrix_publish_draft(date)',
    'matrix_save_demand(uuid,uuid,integer,text)',
    'matrix_save_item(text,uuid,jsonb)',
    'matrix_save_shift(uuid,jsonb)',
    'matrix_v2_full_import_preview_raw_uat_v1(jsonb,text)',
    'matrix_v2_full_import_apply_raw_uat_v1(jsonb,text)',
    'matrix_v2_import_preview_alpha16(jsonb)',
    'matrix_v2_import_apply_alpha16(jsonb)',
    'matrix_v2_import_preview_uat_v2(jsonb)',
    'matrix_v2_import_apply_uat_v2(jsonb)',
    'matrix_v2_import_preview_uat_v3(jsonb,text)',
    'matrix_v2_import_apply_uat_v3(jsonb,text)',
    'matrix_v2_import_preview_uat_v4(jsonb,text)',
    'matrix_v2_import_apply_uat_v4(jsonb,text)',
    'matrix_v2_import_preview_uat_v5(jsonb,text)',
    'matrix_v2_import_apply_uat_v5(jsonb,text)',
    'matrix_v2_team_import_preview_uat_v1_core_20260814(jsonb,text)',
    'matrix_v2_team_import_preview_uat_v1_core_20260824(jsonb,text)',
    'matrix_v2_team_import_apply_uat_v1_core_20260824(jsonb,text)',
    'matrix_v2_import_preview_before_mx_k10(jsonb)',
    'matrix_v2_import_apply_before_mx_k10(jsonb)'
  ];
  v_signature text;
begin
  foreach v_signature in array v_forbidden loop
    if has_function_privilege('anon','public.'||v_signature,'EXECUTE')
      or has_function_privilege('authenticated','public.'||v_signature,'EXECUTE')
      or has_function_privilege('service_role','public.'||v_signature,'EXECUTE') then
      raise exception 'AUD008_UNGUARDED_IMPORT_REACHABLE:%',v_signature;
    end if;
  end loop;
end $$;

rollback;
