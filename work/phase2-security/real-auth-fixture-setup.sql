begin;

do $$
declare v_project_ref text;
begin
  select config->>'projectRef' into v_project_ref
  from public.uat_environment_controls
  where control_key='ISOLATED_UAT_DESTRUCTIVE_TOOLS' and enabled
    and config->>'environment'='ISOLATED_UAT';
  if v_project_ref is distinct from 'nhthrtpkfpmufmrmdyjg'
    or v_project_ref='bdybebzvzapihjdauehg' then
    raise exception 'ABORT_UNEXPECTED_PROJECT_REF:%',coalesce(v_project_ref,'NULL');
  end if;
  if not exists(select 1 from supabase_migrations.schema_migrations where version='20260826140255') then
    raise exception 'ABORT_PHASE1_MIGRATION_MISSING';
  end if;
  if (select count(*) from auth.users where lower(email) like 'audit-phase2-%@szafunek.pl')<>5
    or (select count(*) from auth.users where lower(email) not like 'audit-phase2-%@szafunek.pl')<>1 then
    raise exception 'ABORT_AUTH_BASELINE_CHANGED';
  end if;
  if exists(select 1 from public.employees)
    or exists(select 1 from public.matrix_versions where status='ACTIVE') then
    raise exception 'ABORT_UAT_BUSINESS_BASELINE_NOT_EMPTY';
  end if;
  if exists(select 1 from public.matrix_versions
    where not (status='DRAFT' and name='Pierwsza konfiguracja firmy')) then
    raise exception 'ABORT_UNEXPECTED_NONEMPTY_MATRIX_BASELINE';
  end if;
end;
$$;

do $$
declare
  v_owner uuid;
  v_role_manager uuid;
  v_location_manager uuid;
  v_employee_a_user uuid;
  v_employee_b_user uuid;
  v_version integer;
begin
  select id into strict v_owner from auth.users where lower(email)='audit-phase2-owner@szafunek.pl';
  select id into strict v_role_manager from auth.users where lower(email)='audit-phase2-role-manager-x@szafunek.pl';
  select id into strict v_location_manager from auth.users where lower(email)='audit-phase2-location-manager-a@szafunek.pl';
  select id into strict v_employee_a_user from auth.users where lower(email)='audit-phase2-employee-a@szafunek.pl';
  select id into strict v_employee_b_user from auth.users where lower(email)='audit-phase2-employee-b@szafunek.pl';

  insert into public.user_permissions(auth_user_id,app_role) values
    (v_owner,'OWNER'),(v_role_manager,'ROLE_MANAGER'),(v_location_manager,'LOCATION_MANAGER'),
    (v_employee_a_user,'EMPLOYEE'),(v_employee_b_user,'EMPLOYEE');

  insert into public.application_finance_visibility_policy_v1(app_role,visibility,updated_by) values
    ('OWNER','FULL',v_owner),('ADMIN','FULL',v_owner),('HR_FINANCE','FULL',v_owner),
    ('ROLE_MANAGER','NONE',v_owner),('LOCATION_MANAGER','NONE',v_owner),('EMPLOYEE','NONE',v_owner);

  insert into public.employees(
    id,auth_user_id,email,employee_no,first_name,last_name,primary_role,
    monthly_nominal_minutes,max_weekly_minutes,active
  ) values
    ('f3100000-0000-4000-8000-000000000001',v_employee_a_user,'audit-phase2-employee-a@szafunek.pl','AUDIT-P2-A','AUDIT','EMPLOYEE 1 X A',null,9600,2400,true),
    ('f3100000-0000-4000-8000-000000000002',v_employee_b_user,'audit-phase2-employee-b@szafunek.pl','AUDIT-P2-B','AUDIT','EMPLOYEE 2 Y A',null,9600,2400,true),
    ('f3100000-0000-4000-8000-000000000003',null,null,'AUDIT-P2-C','AUDIT','EMPLOYEE 3 X B',null,9600,2400,true),
    ('f3100000-0000-4000-8000-000000000004',null,null,'AUDIT-P2-D','AUDIT','EMPLOYEE 4 Y B',null,9600,2400,true);

  select coalesce(max(version),0)+1 into v_version from public.matrix_versions;
  insert into public.matrix_versions(
    id,version,name,status,effective_from,settings,created_by,schema_version,
    content_hash,workforce_hash,workforce_count,published_by,published_at
  ) values(
    'f3200000-0000-4000-8000-000000000001',v_version,'AUDIT PHASE2 PRIVACY','DRAFT','2026-08-01',
    '{"currency":"PLN","timezone":"Europe/Warsaw","minimumRestMinutes":660,"maximumShiftsPerDay":1,"maxShiftsPerDay":1}'::jsonb,
    v_owner,2,repeat('3',64),repeat('4',64),4,v_owner,now()
  );

  delete from public.matrix_versions
  where status='DRAFT' and name='Pierwsza konfiguracja firmy';

  insert into public.matrix_role_categories_v2(id,matrix_version_id,logical_id,code,name,color,active) values
    ('f3250000-0000-4000-8000-000000000001','f3200000-0000-4000-8000-000000000001','f3260000-0000-4000-8000-000000000001','AUDIT_P2_CATEGORY_X','AUDIT P2 CATEGORY X','#7257d8',true),
    ('f3250000-0000-4000-8000-000000000002','f3200000-0000-4000-8000-000000000001','f3260000-0000-4000-8000-000000000002','AUDIT_P2_CATEGORY_Y','AUDIT P2 CATEGORY Y','#4a8d78',true);
  insert into public.matrix_roles_v2(id,matrix_version_id,logical_id,code,name,color,category_id,active) values
    ('f3300000-0000-4000-8000-000000000001','f3200000-0000-4000-8000-000000000001','f3310000-0000-4000-8000-000000000001','AUDIT_P2_ROLE_X','AUDIT P2 ROLE X','#7257d8','f3250000-0000-4000-8000-000000000001',true),
    ('f3300000-0000-4000-8000-000000000002','f3200000-0000-4000-8000-000000000001','f3310000-0000-4000-8000-000000000002','AUDIT_P2_ROLE_Y','AUDIT P2 ROLE Y','#4a8d78','f3250000-0000-4000-8000-000000000002',true);
  insert into public.matrix_locations_v2(id,matrix_version_id,logical_id,code,name,timezone,active) values
    ('f3400000-0000-4000-8000-000000000001','f3200000-0000-4000-8000-000000000001','f3410000-0000-4000-8000-000000000001','AUDIT_P2_LOCATION_A','AUDIT P2 LOCATION A','Europe/Warsaw',true),
    ('f3400000-0000-4000-8000-000000000002','f3200000-0000-4000-8000-000000000001','f3410000-0000-4000-8000-000000000002','AUDIT_P2_LOCATION_B','AUDIT P2 LOCATION B','Europe/Warsaw',true);

  insert into public.matrix_employee_profiles_v2(
    matrix_version_id,employee_id,employee_no,first_name,last_name,active,
    nominal_monthly_minutes,maximum_monthly_minutes,maximum_weekly_minutes,
    maximum_consecutive_days,minimum_rest_minutes
  ) select 'f3200000-0000-4000-8000-000000000001',employee.id,employee.employee_no,
      employee.first_name,employee.last_name,true,9600,12000,2400,6,660
    from public.employees employee where employee.employee_no like 'AUDIT-P2-%';

  insert into public.matrix_employee_roles_v2(matrix_version_id,employee_id,role_id,is_primary,can_lead,active) values
    ('f3200000-0000-4000-8000-000000000001','f3100000-0000-4000-8000-000000000001','f3300000-0000-4000-8000-000000000001',true,false,true),
    ('f3200000-0000-4000-8000-000000000001','f3100000-0000-4000-8000-000000000002','f3300000-0000-4000-8000-000000000002',true,false,true),
    ('f3200000-0000-4000-8000-000000000001','f3100000-0000-4000-8000-000000000003','f3300000-0000-4000-8000-000000000001',true,false,true),
    ('f3200000-0000-4000-8000-000000000001','f3100000-0000-4000-8000-000000000004','f3300000-0000-4000-8000-000000000002',true,false,true);
  insert into public.matrix_employee_locations_v2(matrix_version_id,employee_id,location_id,standard_allowed,home_location,active) values
    ('f3200000-0000-4000-8000-000000000001','f3100000-0000-4000-8000-000000000001','f3400000-0000-4000-8000-000000000001',true,true,true),
    ('f3200000-0000-4000-8000-000000000001','f3100000-0000-4000-8000-000000000002','f3400000-0000-4000-8000-000000000001',true,true,true),
    ('f3200000-0000-4000-8000-000000000001','f3100000-0000-4000-8000-000000000003','f3400000-0000-4000-8000-000000000002',true,true,true),
    ('f3200000-0000-4000-8000-000000000001','f3100000-0000-4000-8000-000000000004','f3400000-0000-4000-8000-000000000002',true,true,true);

  insert into public.employee_weekly_work_patterns_v2(
    employee_id,weekday,local_start,local_end,role_id,location_id,enforcement,
    valid_from,valid_to,reason,created_by
  ) values
    ('f3100000-0000-4000-8000-000000000001',1,'09:00','17:00','f3300000-0000-4000-8000-000000000001','f3400000-0000-4000-8000-000000000001','HARD','2026-08-01',null,'AUDIT P2 A',v_owner),
    ('f3100000-0000-4000-8000-000000000002',2,'09:00','17:00','f3300000-0000-4000-8000-000000000002','f3400000-0000-4000-8000-000000000001','HARD','2026-08-01',null,'AUDIT P2 B',v_owner),
    ('f3100000-0000-4000-8000-000000000003',3,'09:00','17:00','f3300000-0000-4000-8000-000000000001','f3400000-0000-4000-8000-000000000002','HARD','2026-08-01',null,'AUDIT P2 C',v_owner),
    ('f3100000-0000-4000-8000-000000000004',4,'09:00','17:00','f3300000-0000-4000-8000-000000000002','f3400000-0000-4000-8000-000000000002','HARD','2026-08-01',null,'AUDIT P2 D',v_owner);

  insert into public.employee_time_constraints_v2(employee_id,constraint_kind,time_range,note,created_by) values
    ('f3100000-0000-4000-8000-000000000001','UNAVAILABLE','[2026-08-10 08:00+02,2026-08-10 16:00+02)','AUDIT P2 A',v_owner),
    ('f3100000-0000-4000-8000-000000000002','UNAVAILABLE','[2026-08-11 08:00+02,2026-08-11 16:00+02)','AUDIT P2 B',v_owner),
    ('f3100000-0000-4000-8000-000000000003','UNAVAILABLE','[2026-08-12 08:00+02,2026-08-12 16:00+02)','AUDIT P2 C',v_owner),
    ('f3100000-0000-4000-8000-000000000004','UNAVAILABLE','[2026-08-13 08:00+02,2026-08-13 16:00+02)','AUDIT P2 D',v_owner);

  insert into public.employee_pay_rates_v2(employee_id,valid_from,base_rate_minor,currency,contract_type,created_by,updated_by)
    select employee.id,'2026-01-01',3000,'PLN','UMOWA_O_PRACE',v_owner,v_owner
    from public.employees employee where employee.employee_no like 'AUDIT-P2-%';

  insert into public.recovery_ad_hoc_pool_v2(
    employee_id,display_name,email,phone,role_id,base_rate_minor,currency,notes,created_by
  ) values
    ('f3100000-0000-4000-8000-000000000001','AUDIT P2 ADHOC A','audit-p2-a@invalid.test','1001','f3300000-0000-4000-8000-000000000001',4100,'PLN','AUDIT P2',v_owner),
    ('f3100000-0000-4000-8000-000000000002','AUDIT P2 ADHOC B','audit-p2-b@invalid.test','1002','f3300000-0000-4000-8000-000000000002',4200,'PLN','AUDIT P2',v_owner),
    ('f3100000-0000-4000-8000-000000000003','AUDIT P2 ADHOC C','audit-p2-c@invalid.test','1003','f3300000-0000-4000-8000-000000000001',4300,'PLN','AUDIT P2',v_owner),
    ('f3100000-0000-4000-8000-000000000004','AUDIT P2 ADHOC D','audit-p2-d@invalid.test','1004','f3300000-0000-4000-8000-000000000002',4400,'PLN','AUDIT P2',v_owner),
    (null,'AUDIT P2 TEMP X','audit-p2-x@invalid.test','1091','f3300000-0000-4000-8000-000000000001',4500,'PLN','AUDIT P2',v_owner),
    (null,'AUDIT P2 TEMP Y','audit-p2-y@invalid.test','1092','f3300000-0000-4000-8000-000000000002',4600,'PLN','AUDIT P2',v_owner);

  perform solver_private.matrix_v2_seed_required_defaults_uat_v1(
    'f3200000-0000-4000-8000-000000000001'
  );
  update public.matrix_versions set status='ACTIVE',activated_at=now()
  where id='f3200000-0000-4000-8000-000000000001';

  insert into public.matrix_scope_grants_v2(auth_user_id,app_role,role_logical_id,location_logical_id,active,created_by) values
    (v_owner,'OWNER',null,null,true,v_owner),
    (v_role_manager,'ROLE_MANAGER','f3310000-0000-4000-8000-000000000001',null,true,v_owner),
    (v_location_manager,'LOCATION_MANAGER',null,'f3410000-0000-4000-8000-000000000001',true,v_owner);
  insert into public.application_access_directory_v1(email,app_role,role_logical_id,location_logical_id,auth_user_id,active,created_by) values
    ('audit-phase2-owner@szafunek.pl','OWNER',null,null,v_owner,true,v_owner),
    ('audit-phase2-role-manager-x@szafunek.pl','ROLE_MANAGER','f3310000-0000-4000-8000-000000000001',null,v_role_manager,true,v_owner),
    ('audit-phase2-location-manager-a@szafunek.pl','LOCATION_MANAGER',null,'f3410000-0000-4000-8000-000000000001',v_location_manager,true,v_owner),
    ('audit-phase2-employee-a@szafunek.pl','EMPLOYEE',null,null,v_employee_a_user,true,v_owner),
    ('audit-phase2-employee-b@szafunek.pl','EMPLOYEE',null,null,v_employee_b_user,true,v_owner);
end;
$$;

select jsonb_build_object(
  'authUsers',(select count(*) from auth.users where lower(email) like 'audit-phase2-%@szafunek.pl'),
  'employees',(select count(*) from public.employees where employee_no like 'AUDIT-P2-%'),
  'activeMatrices',(select count(*) from public.matrix_versions where id='f3200000-0000-4000-8000-000000000001' and status='ACTIVE'),
  'patterns',(select count(*) from public.employee_weekly_work_patterns_v2 where reason like 'AUDIT P2 %'),
  'adHoc',(select count(*) from public.recovery_ad_hoc_pool_v2 where notes='AUDIT P2')
) as phase2_real_auth_fixture;

commit;
