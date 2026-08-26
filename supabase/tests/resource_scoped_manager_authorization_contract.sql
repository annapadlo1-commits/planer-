begin;

-- Phase 1 contract: scoped managers may mutate only canonical resources
-- covered by their exact role/location grant. Every fixture is rolled back.
do $$
declare
  v_definition text;
begin
  if has_schema_privilege('authenticated','authorization_private','usage')
    or has_function_privilege(
      'authenticated',
      'authorization_private.enter_resource_scope_uat_v1()',
      'execute'
    ) then
    raise exception 'PHASE1_PRIVATE_SCOPE_ENTRYPOINT_EXPOSED';
  end if;

  if has_function_privilege(
      'authenticated',
      'public.role_plan_refresh_conflicts(uuid)',
      'execute'
    ) then
    raise exception 'PHASE1_RETIRED_MUTATION_STILL_EXPOSED';
  end if;

  if has_function_privilege(
      'authenticated',
      'public.employee_weekly_work_patterns_replace_before_phase1_uat_v1(uuid,date,date,jsonb,text)',
      'execute'
    ) then
    raise exception 'PHASE1_UNGUARDED_IMPLEMENTATION_EXPOSED';
  end if;
  if has_function_privilege(
      'authenticated',
      'public.optimizer_publish_role_composite_before_phase1_uat_v1(date,uuid,uuid[],text,text,text)',
      'execute'
    ) then
    raise exception 'PHASE1_UNGUARDED_COMPOSITE_PUBLICATION_EXPOSED';
  end if;

  v_definition:=pg_get_functiondef(
    'public.can_manage_plans()'::regprocedure
  );
  if position('has_app_role(''ROLE_MANAGER'')' in v_definition)>0
    or position('has_app_role(''LOCATION_MANAGER'')' in v_definition)>0 then
    raise exception 'PHASE1_GLOBAL_MANAGER_PREDICATE_REMAINS';
  end if;
end;
$$;

insert into auth.users(
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,is_super_admin,created_at,updated_at
) values
  ('00000000-0000-0000-0000-000000000000','f1000000-0000-4000-8000-000000000001',
   'authenticated','authenticated','phase1-owner@example.invalid','',now(),
   '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,false,now(),now()),
  ('00000000-0000-0000-0000-000000000000','f1000000-0000-4000-8000-000000000002',
   'authenticated','authenticated','phase1-role-x@example.invalid','',now(),
   '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,false,now(),now()),
  ('00000000-0000-0000-0000-000000000000','f1000000-0000-4000-8000-000000000003',
   'authenticated','authenticated','phase1-location-a@example.invalid','',now(),
   '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,false,now(),now()),
  ('00000000-0000-0000-0000-000000000000','f1000000-0000-4000-8000-000000000004',
   'authenticated','authenticated','phase1-employee-a@example.invalid','',now(),
   '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,false,now(),now()),
  ('00000000-0000-0000-0000-000000000000','f1000000-0000-4000-8000-000000000005',
   'authenticated','authenticated','phase1-employee-b@example.invalid','',now(),
   '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,false,now(),now());

insert into public.user_permissions(auth_user_id,app_role) values
  ('f1000000-0000-4000-8000-000000000001','OWNER'),
  ('f1000000-0000-4000-8000-000000000002','ROLE_MANAGER'),
  ('f1000000-0000-4000-8000-000000000003','LOCATION_MANAGER'),
  ('f1000000-0000-4000-8000-000000000004','EMPLOYEE'),
  ('f1000000-0000-4000-8000-000000000005','EMPLOYEE');

insert into public.employees(
  id,auth_user_id,employee_no,first_name,last_name,primary_role,
  monthly_nominal_minutes,max_weekly_minutes,active
) values
  ('f1100000-0000-4000-8000-000000000001','f1000000-0000-4000-8000-000000000004',
   'PHASE1-A','Phase','Employee A',null,9600,2400,true),
  ('f1100000-0000-4000-8000-000000000002','f1000000-0000-4000-8000-000000000005',
   'PHASE1-B','Phase','Employee B',null,9600,2400,true);

do $$
declare
  v_version integer;
  v_settings jsonb;
begin
  select coalesce(max(version),0)+1 into v_version from public.matrix_versions;
  select coalesce(settings,'{}'::jsonb) into v_settings
  from public.matrix_versions where status='ACTIVE'
  order by version desc limit 1;

  insert into public.matrix_versions(
    id,version,name,status,effective_from,settings,schema_version
  ) values(
    'f1200000-0000-4000-8000-000000000001',v_version,
    'Phase 1 scoped authorization fixture','DRAFT',current_date,
    coalesce(v_settings,'{}'::jsonb),2
  );

  insert into public.matrix_roles_v2(
    id,matrix_version_id,logical_id,code,name,color,active
  ) values
    ('f1300000-0000-4000-8000-000000000001','f1200000-0000-4000-8000-000000000001',
     'f1310000-0000-4000-8000-000000000001','PHASE1_ROLE_X','Phase 1 Role X','#7257d8',true),
    ('f1300000-0000-4000-8000-000000000002','f1200000-0000-4000-8000-000000000001',
     'f1310000-0000-4000-8000-000000000002','PHASE1_ROLE_Y','Phase 1 Role Y','#4a8d78',true);

  insert into public.matrix_locations_v2(
    id,matrix_version_id,logical_id,code,name,timezone,active
  ) values
    ('f1400000-0000-4000-8000-000000000001','f1200000-0000-4000-8000-000000000001',
     'f1410000-0000-4000-8000-000000000001','PHASE1_LOCATION_A','Phase 1 Location A','Europe/Warsaw',true),
    ('f1400000-0000-4000-8000-000000000002','f1200000-0000-4000-8000-000000000001',
     'f1410000-0000-4000-8000-000000000002','PHASE1_LOCATION_B','Phase 1 Location B','Europe/Warsaw',true);

  insert into public.matrix_employee_profiles_v2(
    matrix_version_id,employee_id,employee_no,first_name,last_name,active,
    nominal_monthly_minutes,maximum_monthly_minutes,maximum_weekly_minutes,
    maximum_consecutive_days,minimum_rest_minutes
  ) values
    ('f1200000-0000-4000-8000-000000000001','f1100000-0000-4000-8000-000000000001',
     'PHASE1-A','Phase','Employee A',true,9600,12000,2400,6,660),
    ('f1200000-0000-4000-8000-000000000001','f1100000-0000-4000-8000-000000000002',
     'PHASE1-B','Phase','Employee B',true,9600,12000,2400,6,660);

  insert into public.matrix_employee_roles_v2(
    matrix_version_id,employee_id,role_id,is_primary,can_lead,active
  ) values
    ('f1200000-0000-4000-8000-000000000001','f1100000-0000-4000-8000-000000000001',
     'f1300000-0000-4000-8000-000000000001',true,false,true),
    ('f1200000-0000-4000-8000-000000000001','f1100000-0000-4000-8000-000000000002',
     'f1300000-0000-4000-8000-000000000002',true,false,true);

  insert into public.matrix_employee_locations_v2(
    matrix_version_id,employee_id,location_id,standard_allowed,home_location,active
  ) values
    ('f1200000-0000-4000-8000-000000000001','f1100000-0000-4000-8000-000000000001',
     'f1400000-0000-4000-8000-000000000001',true,true,true),
    ('f1200000-0000-4000-8000-000000000001','f1100000-0000-4000-8000-000000000002',
     'f1400000-0000-4000-8000-000000000002',true,true,true);

  -- Use the same canonical seeding routine as production publication so the
  -- temporary ACTIVE fixture satisfies all current strategy invariants.
  perform solver_private.matrix_v2_seed_required_defaults_uat_v1(
    'f1200000-0000-4000-8000-000000000001'
  );

  update public.matrix_versions
  set status='ARCHIVED',effective_to=greatest(effective_from,current_date-1)
  where status='ACTIVE';
  update public.matrix_versions
  set status='ACTIVE',activated_at=now(),published_at=now()
  where id='f1200000-0000-4000-8000-000000000001';
end;
$$;

insert into public.matrix_scope_grants_v2(
  auth_user_id,app_role,role_logical_id,location_logical_id,active,created_by
) values
  ('f1000000-0000-4000-8000-000000000002','ROLE_MANAGER',
   'f1310000-0000-4000-8000-000000000001',null,true,'f1000000-0000-4000-8000-000000000001'),
  ('f1000000-0000-4000-8000-000000000003','LOCATION_MANAGER',
   null,'f1410000-0000-4000-8000-000000000001',true,'f1000000-0000-4000-8000-000000000001');

-- Wildcard manager grants must be impossible at the storage boundary.
do $$
begin
  begin
    insert into public.matrix_scope_grants_v2(auth_user_id,app_role,active)
    values('f1000000-0000-4000-8000-000000000002','ROLE_MANAGER',true);
    raise exception 'PHASE1_ROLE_MANAGER_WILDCARD_ACCEPTED';
  exception
    when check_violation then null;
  end;
  begin
    insert into public.matrix_scope_grants_v2(auth_user_id,app_role,active)
    values('f1000000-0000-4000-8000-000000000003','LOCATION_MANAGER',true);
    raise exception 'PHASE1_LOCATION_MANAGER_WILDCARD_ACCEPTED';
  exception
    when check_violation then null;
  end;
end;
$$;

select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;

-- OWNER remains global and can mutate a resource outside manager X/A scope.
select set_config('request.jwt.claim.sub','f1000000-0000-4000-8000-000000000001',true);
do $$
declare v_result jsonb;
begin
  if not public.matrix_v2_can_manage_resource_uat_v1(
    'f1300000-0000-4000-8000-000000000002',
    'f1400000-0000-4000-8000-000000000002',
    'f1100000-0000-4000-8000-000000000002'
  ) then raise exception 'PHASE1_OWNER_GLOBAL_ACCESS_DENIED'; end if;

  v_result:=public.employee_weekly_work_patterns_replace_uat_v1(
    'f1100000-0000-4000-8000-000000000002',current_date,null,
    jsonb_build_array(jsonb_build_object(
      'weekday',1,'localStart','09:00','localEnd','17:00','enforcement','HARD',
      'roleId','f1300000-0000-4000-8000-000000000002',
      'locationId','f1400000-0000-4000-8000-000000000002'
    )),'Phase 1 owner positive contract'
  );
  if coalesce((v_result->>'count')::integer,0)<>1 then
    raise exception 'PHASE1_OWNER_MUTATION_FAILED:%',v_result;
  end if;
end;
$$;

-- ROLE_MANAGER X: own role/employee succeeds; Y, B and mismatched payload fail.
select set_config('request.jwt.claim.sub','f1000000-0000-4000-8000-000000000002',true);
do $$
begin
  if public.can_manage_plans() then raise exception 'PHASE1_ROLE_MANAGER_RETAINED_GLOBAL_ACCESS'; end if;
  if not public.matrix_v2_can_manage_resource_uat_v1(
      'f1300000-0000-4000-8000-000000000001',null,
      'f1100000-0000-4000-8000-000000000001')
    or public.matrix_v2_can_manage_resource_uat_v1(
      'f1300000-0000-4000-8000-000000000002',null,
      'f1100000-0000-4000-8000-000000000002') then
    raise exception 'PHASE1_ROLE_MANAGER_HELPER_SCOPE_INVALID';
  end if;

  perform public.employee_weekly_work_patterns_replace_uat_v1(
    'f1100000-0000-4000-8000-000000000001',current_date,null,
    jsonb_build_array(jsonb_build_object(
      'weekday',2,'localStart','09:00','localEnd','17:00','enforcement','HARD',
      'roleId','f1300000-0000-4000-8000-000000000001',
      'locationId','f1400000-0000-4000-8000-000000000001'
    )),'Phase 1 role manager positive contract'
  );

  begin
    perform public.employee_weekly_work_patterns_replace_uat_v1(
      'f1100000-0000-4000-8000-000000000002',current_date,null,'[]'::jsonb,
      'Phase 1 cross employee denied'
    );
    raise exception 'PHASE1_ROLE_MANAGER_CROSS_EMPLOYEE_ACCEPTED';
  exception when others then
    if sqlerrm not like '%RESOURCE_SCOPE_FORBIDDEN%' then raise; end if;
  end;

  begin
    perform public.employee_weekly_work_patterns_replace_uat_v1(
      'f1100000-0000-4000-8000-000000000001',current_date,null,
      jsonb_build_array(jsonb_build_object(
        'weekday',3,'localStart','09:00','localEnd','17:00','enforcement','HARD',
        'roleId','f1300000-0000-4000-8000-000000000002',
        'locationId','f1400000-0000-4000-8000-000000000001'
      )),'Phase 1 allowed employee foreign role denied'
    );
    raise exception 'PHASE1_ALLOWED_EMPLOYEE_FOREIGN_ROLE_ACCEPTED';
  exception when others then
    if sqlerrm not like '%WORK_PATTERN_RESOURCE_SCOPE_FORBIDDEN%' then raise; end if;
  end;

  begin
    perform public.optimizer_publish_role_composite_uat_v3(
      current_date,'f1500000-0000-4000-8000-000000000001',
      array['f1500000-0000-4000-8000-000000000002'::uuid],
      'Phase 1 foreign composite','phase1-foreign-composite',null
    );
    raise exception 'PHASE1_UNRESOLVED_COMPOSITE_RESOURCE_ACCEPTED';
  exception when others then
    if sqlerrm not like '%RESOURCE_SCOPE_FORBIDDEN%' then raise; end if;
  end;
end;
$$;

-- LOCATION_MANAGER A: own location/employee succeeds; location B fails.
select set_config('request.jwt.claim.sub','f1000000-0000-4000-8000-000000000003',true);
do $$
begin
  if public.can_manage_plans() then raise exception 'PHASE1_LOCATION_MANAGER_RETAINED_GLOBAL_ACCESS'; end if;
  if not public.matrix_v2_can_manage_resource_uat_v1(
      null,'f1400000-0000-4000-8000-000000000001',
      'f1100000-0000-4000-8000-000000000001')
    or public.matrix_v2_can_manage_resource_uat_v1(
      null,'f1400000-0000-4000-8000-000000000002',
      'f1100000-0000-4000-8000-000000000002') then
    raise exception 'PHASE1_LOCATION_MANAGER_HELPER_SCOPE_INVALID';
  end if;

  perform public.employee_weekly_work_patterns_replace_uat_v1(
    'f1100000-0000-4000-8000-000000000001',current_date,null,
    jsonb_build_array(jsonb_build_object(
      'weekday',4,'localStart','09:00','localEnd','17:00','enforcement','HARD',
      'roleId','f1300000-0000-4000-8000-000000000001',
      'locationId','f1400000-0000-4000-8000-000000000001'
    )),'Phase 1 location manager positive contract'
  );

  begin
    perform public.employee_weekly_work_patterns_replace_uat_v1(
      'f1100000-0000-4000-8000-000000000002',current_date,null,'[]'::jsonb,
      'Phase 1 cross location denied'
    );
    raise exception 'PHASE1_LOCATION_MANAGER_CROSS_LOCATION_ACCEPTED';
  exception when others then
    if sqlerrm not like '%RESOURCE_SCOPE_FORBIDDEN%' then raise; end if;
  end;
end;
$$;

-- EMPLOYEE retains only the existing self-service predicate, not manager RPCs.
select set_config('request.jwt.claim.sub','f1000000-0000-4000-8000-000000000004',true);
do $$
begin
  if not public.matrix_v2_can_manage_employee('f1100000-0000-4000-8000-000000000001')
    or public.matrix_v2_can_manage_employee('f1100000-0000-4000-8000-000000000002')
    or public.matrix_v2_can_manage_resource_uat_v1(null,null,'f1100000-0000-4000-8000-000000000001') then
    raise exception 'PHASE1_EMPLOYEE_SELF_BOUNDARY_INVALID';
  end if;
  begin
    perform public.employee_weekly_work_patterns_replace_uat_v1(
      'f1100000-0000-4000-8000-000000000001',current_date,null,'[]'::jsonb,
      'Phase 1 employee manager RPC denied'
    );
    raise exception 'PHASE1_EMPLOYEE_MANAGER_MUTATION_ACCEPTED';
  exception when others then
    if sqlerrm not like '%RESOURCE_SCOPE_FORBIDDEN%' then raise; end if;
  end;
end;
$$;

select set_config('request.jwt.claim.sub','f1000000-0000-4000-8000-000000000005',true);
do $$
begin
  if not public.matrix_v2_can_manage_employee('f1100000-0000-4000-8000-000000000002')
    or public.matrix_v2_can_manage_employee('f1100000-0000-4000-8000-000000000001') then
    raise exception 'PHASE1_EMPLOYEE_B_SELF_BOUNDARY_INVALID';
  end if;
end;
$$;

reset role;
rollback;
