-- Transactional contract for versioned Matrix v2 employees.
-- Safe to run repeatedly: every identity, draft and publication is rolled back.

begin;

insert into auth.users(
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,is_super_admin,created_at,updated_at
) values(
  '00000000-0000-0000-0000-000000000000',
  'e1a00000-0000-4000-8000-000000000001',
  'authenticated','authenticated','matrix-lifecycle-owner@example.invalid','',now(),
  '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,false,now(),now()
);
insert into public.user_permissions(auth_user_id,app_role)
values('e1a00000-0000-4000-8000-000000000001','OWNER');

do $$
declare
  v_definition text;
begin
  if to_regclass('public.matrix_employee_profiles_v2') is null then
    raise exception 'MATRIX_EMPLOYEE_PROFILES_V2_MISSING';
  end if;
  if not exists(select 1 from pg_class c
      where c.oid='public.matrix_employee_profiles_v2'::regclass
        and c.relrowsecurity) then
    raise exception 'MATRIX_EMPLOYEE_PROFILES_V2_RLS_DISABLED';
  end if;
  if has_table_privilege('anon','public.matrix_employee_profiles_v2','select')
    or has_table_privilege('authenticated','public.matrix_employee_profiles_v2','select')
    or has_table_privilege('authenticated','public.matrix_employee_profiles_v2','insert')
  then raise exception 'MATRIX_EMPLOYEE_PROFILE_GRANTS_TOO_BROAD'; end if;
  if not has_function_privilege('authenticated',
      'public.matrix_v2_employee_save_v2(uuid,jsonb)','execute')
    or not has_function_privilege('authenticated',
      'public.matrix_v2_employee_archive_v2(uuid,text,boolean)','execute')
    or not has_function_privilege('authenticated',
      'public.matrix_v2_employee_directory_v2()','execute')
    or has_function_privilege('anon',
      'public.matrix_v2_employee_save_v2(uuid,jsonb)','execute')
  then raise exception 'MATRIX_EMPLOYEE_RPC_GRANTS_INVALID'; end if;

  v_definition:=pg_get_functiondef(
    'solver_private.variant_set_workspace_v2(uuid[],jsonb,boolean)'::regprocedure
  );
  if position('matrix_employee_profiles_v2' in v_definition)=0
    or position('join public.employees employee' in v_definition)>0 then
    raise exception 'HISTORICAL_WORKSPACE_USES_MUTABLE_EMPLOYEE_DIRECTORY';
  end if;
end;
$$;

select set_config(
  'request.jwt.claim.sub',
  'e1a00000-0000-4000-8000-000000000001',
  true
);
select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;

do $$
declare
  v_draft uuid;
  v_employee uuid;
  v_role uuid;
  v_location uuid;
  v_first_matrix uuid;
  v_second_matrix uuid;
  v_currency text;
begin
  if auth.uid() is null then raise exception 'OWNER_TEST_IDENTITY_MISSING'; end if;

  v_draft:=public.matrix_v2_create_draft('Employee lifecycle v2 contract');
  select r.id into v_role from public.matrix_roles_v2 r
  where r.matrix_version_id=v_draft and r.active order by r.sort_order,r.id limit 1;
  select l.id into v_location from public.matrix_locations_v2 l
  where l.matrix_version_id=v_draft and l.active order by l.sort_order,l.id limit 1;
  if v_role is null or v_location is null then
    raise exception 'EMPLOYEE_TEST_SCOPE_MISSING';
  end if;

  select (public.matrix_v2_employee_save_v2(null,jsonb_build_object(
    'employeeNo','UAT-EMPLOYEE-V2','firstName','Historia','lastName','Pracownika',
    'email','uat-employee-v2@example.invalid',
    'employmentStart',current_date,'nominalMonthlyMinutes',9600,
    'maximumMonthlyMinutes',12000,'maximumWeeklyMinutes',2400,
    'maximumConsecutiveDays',6,'minimumRestMinutes',660,
    'onlyMorning',false,'onlyEvening',false,'noWeekends',false,
    'primaryRoleId',v_role,'homeLocationId',v_location
  ))->>'id')::uuid into v_employee;
  if v_employee is null then raise exception 'EMPLOYEE_CREATE_FAILED'; end if;
  select upper(mv.settings->>'currency') into v_currency
  from public.matrix_versions mv where mv.id=v_draft;
  perform public.employee_pay_rate_save_v2(
    null,v_employee,current_date,null,3000,v_currency,'UAT',true
  );
  if (select e.active from public.employees e where e.id=v_employee) then
    raise exception 'DRAFT_EMPLOYEE_LEAKED_TO_ACTIVE_LEGACY_DIRECTORY';
  end if;

  perform public.matrix_v2_publish_draft(current_date);
  select mv.id into v_first_matrix from public.matrix_versions mv
  where mv.status='ACTIVE' and mv.schema_version>=2 order by mv.version desc limit 1;
  if not (select e.active from public.employees e where e.id=v_employee) then
    raise exception 'PUBLISHED_EMPLOYEE_NOT_ACTIVATED';
  end if;
  if (select mv.workforce_hash from public.matrix_versions mv
      where mv.id=v_first_matrix) !~ '^[0-9a-f]{64}$' then
    raise exception 'WORKFORCE_HASH_MISSING';
  end if;
  v_draft:=public.matrix_v2_create_draft('Employee archive v2 contract');
  perform public.matrix_v2_employee_save_v2(v_employee,jsonb_build_object(
    'firstName','Nowe imię','primaryRoleId',(
      select er.role_id from public.matrix_employee_roles_v2 er
      where er.matrix_version_id=v_draft and er.employee_id=v_employee
        and er.is_primary limit 1
    ),'homeLocationId',(
      select el.location_id from public.matrix_employee_locations_v2 el
      where el.matrix_version_id=v_draft and el.employee_id=v_employee
        and el.home_location limit 1
    )
  ));
  perform public.matrix_v2_employee_archive_v2(v_employee,'Koniec współpracy UAT',true);
  perform public.matrix_v2_publish_draft(current_date);
  select mv.id into v_second_matrix from public.matrix_versions mv
  where mv.status='ACTIVE' and mv.schema_version>=2 order by mv.version desc limit 1;
  perform set_config('grafik.employee_test_id',v_employee::text,true);
  perform set_config('grafik.employee_test_first_matrix',v_first_matrix::text,true);
  perform set_config('grafik.employee_test_second_matrix',v_second_matrix::text,true);
end;
$$;

reset role;

do $$
declare
  v_employee uuid:=current_setting('grafik.employee_test_id')::uuid;
  v_first_matrix uuid:=current_setting('grafik.employee_test_first_matrix')::uuid;
  v_second_matrix uuid:=current_setting('grafik.employee_test_second_matrix')::uuid;
begin
  if (select p.active from public.matrix_employee_profiles_v2 p
      where p.matrix_version_id=v_first_matrix and p.employee_id=v_employee) is not true
    or (select p.first_name from public.matrix_employee_profiles_v2 p
      where p.matrix_version_id=v_first_matrix and p.employee_id=v_employee)
      is distinct from 'Historia' then
    raise exception 'HISTORICAL_EMPLOYEE_PROFILE_CHANGED';
  end if;
  if (select p.active from public.matrix_employee_profiles_v2 p
      where p.matrix_version_id=v_second_matrix and p.employee_id=v_employee) is not false
    or (select e.active from public.employees e where e.id=v_employee) is not false then
    raise exception 'EMPLOYEE_ARCHIVE_NOT_ACTIVATED';
  end if;

  begin
    update public.matrix_employee_profiles_v2 set first_name='Niedozwolona zmiana'
    where matrix_version_id=v_first_matrix and employee_id=v_employee;
    raise exception 'IMMUTABLE_PROFILE_UPDATE_UNEXPECTEDLY_SUCCEEDED';
  exception when others then
    if sqlerrm not like '%MATRIX_WORKFORCE_VERSION_IMMUTABLE%' then raise; end if;
  end;
end;
$$;

rollback;
