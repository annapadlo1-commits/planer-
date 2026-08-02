-- Alpha 16 workforce, Matrix import and self-service preference contract.
-- Safe to run repeatedly: every identity, draft and data mutation is rolled back.

begin;

do $$
declare
  v_definition text;
  v_signature text;
begin
  if to_regclass('public.operational_assignment_overrides_v2') is null then
    raise exception 'ALPHA16_OPERATIONAL_OVERRIDE_TABLE_MISSING';
  end if;
  if not exists(select 1 from pg_class relation
      where relation.oid='public.operational_assignment_overrides_v2'::regclass
        and relation.relrowsecurity) then
    raise exception 'ALPHA16_OPERATIONAL_OVERRIDE_RLS_DISABLED';
  end if;
  if has_table_privilege(
      'authenticated','public.operational_assignment_overrides_v2','select')
    or has_table_privilege(
      'authenticated','public.operational_assignment_overrides_v2','insert')
    or has_table_privilege(
      'anon','public.operational_assignment_overrides_v2','select') then
    raise exception 'ALPHA16_OPERATIONAL_OVERRIDE_GRANTS_TOO_BROAD';
  end if;

  if has_function_privilege(
      'anon','public.matrix_v2_employee_save_alpha16(uuid,jsonb)','execute')
    or has_function_privilege(
      'anon','public.employee_shift_preferences_save_self_v2(date,jsonb)','execute')
    or has_function_privilege(
      'anon','public.optimizer_emergency_assign_alpha16(uuid,bigint,uuid,boolean,text,boolean)','execute')
    or not has_function_privilege(
      'authenticated','public.matrix_v2_employee_save_alpha16(uuid,jsonb)','execute')
    or not has_function_privilege(
      'authenticated','public.matrix_v2_import_preview_alpha16(jsonb)','execute')
    or not has_function_privilege(
      'authenticated','public.optimizer_candidate_diagnostics_alpha16(uuid,bigint)','execute')
    or not has_function_privilege(
      'authenticated','public.optimizer_selected_variant_workspace_alpha16(uuid)','execute')
    or not has_function_privilege(
      'authenticated','public.optimizer_published_schedule_alpha16(uuid)','execute')
    or not has_function_privilege(
      'authenticated','public.optimizer_publication_attempt_alpha16(uuid,uuid,text)','execute')
    or not has_function_privilege(
      'authenticated','public.optimizer_publish_company_variant_alpha16(uuid,uuid,text,text,text)','execute')
    or has_function_privilege(
      'anon','public.optimizer_publish_company_variant_alpha16(uuid,uuid,text,text,text)','execute') then
    raise exception 'ALPHA16_RPC_GRANTS_INVALID';
  end if;

  foreach v_signature in array array[
    'public.generate_plan(date,text,text,text,text)',
    'public.publish_plan(uuid)',
    'public.emergency_assign(uuid,uuid,public.employee_role,boolean)',
    'public.employee_update(uuid,jsonb)',
    'public.employee_availability_save_month(date,jsonb,boolean)',
    'public.attendance_clock(text,text,numeric,numeric)',
    'public.matrix_save_item(text,uuid,jsonb)',
    'public.generate_role_plan(date,uuid,text,text,text,text)',
    'public.optimizer_prepare_v2(date,text,text,integer)',
    'public.optimizer_publish_company_variant_v2(uuid,uuid,text,text)'
  ] loop
    if has_function_privilege('authenticated',v_signature,'execute')
      or has_function_privilege('anon',v_signature,'execute') then
      raise exception 'ALPHA15_RUNTIME_RPC_STILL_EXPOSED:%',v_signature;
    end if;
  end loop;

  if not exists(select 1 from information_schema.columns column_row
      where column_row.table_schema='public'
        and column_row.table_name='matrix_shift_templates_v2'
        and column_row.column_name='shift_period')
    or not exists(select 1 from information_schema.columns column_row
      where column_row.table_schema='public'
        and column_row.table_name='matrix_role_duties_v2'
        and column_row.column_name='shift_obligation')
    or not exists(select 1 from information_schema.columns column_row
      where column_row.table_schema='public'
        and column_row.table_name='matrix_role_duties_v2'
        and column_row.column_name='shift_period') then
    raise exception 'ALPHA16_SHIFT_PERIOD_COLUMNS_MISSING';
  end if;

  v_definition:=pg_get_functiondef(
    'public.optimizer_emergency_assign_alpha16(uuid,bigint,uuid,boolean,text,boolean)'::regprocedure
  );
  if position('EMERGENCY_ASSIGNMENT_HARD_BLOCK' in v_definition)=0
    or position('SOFT_OVERRIDE_REASON_REQUIRED' in v_definition)=0
    or position('operational_assignment_override_v2' in v_definition)=0
    or position('public.notifications' in v_definition)=0
    or position('public.audit_log' in v_definition)=0 then
    raise exception 'ALPHA16_EMERGENCY_ASSIGNMENT_GUARDS_INCOMPLETE';
  end if;

  v_definition:=pg_get_functiondef(
    'public.optimizer_candidate_diagnostics_alpha16(uuid,bigint)'::regprocedure
  );
  if position('DECLARED_UNAVAILABLE' in v_definition)=0
    or position('OUTSIDE_AVAILABILITY_WINDOW' in v_definition)=0
    or position('REST_AFTER_PREVIOUS_SHIFT' in v_definition)=0
    or position('MONTHLY_LIMIT' in v_definition)=0
    or position('MAX_CONSECUTIVE_DAYS' in v_definition)=0
    or position('MANAGER_SHIFT_BLOCK' in v_definition)=0 then
    raise exception 'ALPHA16_CANDIDATE_DIAGNOSTICS_INCOMPLETE';
  end if;

  v_definition:=pg_get_functiondef(
    'public.optimizer_operational_workspace_alpha16(date)'::regprocedure
  );
  if position('variantId' in v_definition)=0
    or position('issue.variant_id' in v_definition)=0 then
    raise exception 'ALPHA16_OPERATIONAL_WORKSPACE_INCOMPLETE';
  end if;

  v_definition:=pg_get_functiondef(
    'public.optimizer_publish_company_variant_alpha16(uuid,uuid,text,text,text)'::regprocedure
  );
  if position('WARNING_REASON_REQUIRED' in v_definition)=0
    or position('PUBLICATION_COMPLETED' in v_definition)=0
    or position('public.audit_log' in v_definition)=0 then
    raise exception 'ALPHA16_PUBLICATION_AUDIT_INCOMPLETE';
  end if;
end;
$$;

insert into auth.users(
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,is_super_admin,created_at,updated_at
) values(
  '00000000-0000-0000-0000-000000000000',
  'a1600000-0000-4000-8000-000000000001',
  'authenticated','authenticated','alpha16-owner@example.invalid','',now(),
  '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,false,now(),now()
);
insert into public.user_permissions(auth_user_id,app_role)
values('a1600000-0000-4000-8000-000000000001','OWNER');

do $$
declare
  v_employee uuid;
  v_matrix uuid;
  v_month date:=date_trunc('month',current_date)::date;
begin
  select employee.id into v_employee
  from public.employees employee
  where employee.active and employee.archived_at is null
    and employee.auth_user_id is null
  order by employee.id limit 1;
  select matrix.id into v_matrix
  from public.matrix_versions matrix
  where matrix.status in ('ACTIVE','ARCHIVED') and matrix.schema_version>=2
    and matrix.effective_from<=v_month
  order by matrix.effective_from desc,matrix.version desc limit 1;
  if v_employee is null or v_matrix is null then
    raise exception 'ALPHA16_SELF_SERVICE_FIXTURE_MISSING';
  end if;
  update public.employees
  set auth_user_id='a1600000-0000-4000-8000-000000000001'
  where id=v_employee;
  insert into public.employee_preferences(
    employee_id,valid_from,valid_to,preference_type,preference_value,
    source,editable_by_employee,status
  ) values(
    v_employee,v_month,(v_month+interval '1 month - 1 day')::date,
    'PREFERRED_SHIFT',jsonb_build_object(
      'period','MORNING','level','BLOCKED','matrixVersionId',v_matrix
    ),'MANAGER',false,'ACTIVE'
  );
end;
$$;

select set_config(
  'request.jwt.claim.sub','a1600000-0000-4000-8000-000000000001',true
);
select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;

do $$
declare
  v_month date:=date_trunc('month',current_date)::date;
  v_draft uuid;
  v_role uuid;
  v_duty uuid;
  v_location_one uuid;
  v_location_two uuid;
  v_employee_one uuid;
  v_employee_two uuid;
  v_employee_no_one text;
  v_employee_no_two text;
  v_result jsonb;
  v_directory jsonb;
  v_preview jsonb;
  v_payload jsonb;
  v_role_duty uuid;
  v_index integer;
begin
  if auth.uid() is null then raise exception 'ALPHA16_OWNER_TEST_IDENTITY_MISSING'; end if;

  v_draft:=public.matrix_v2_create_draft('Alpha 16 contract');
  select role_row.id into v_role
  from public.matrix_roles_v2 role_row
  where role_row.matrix_version_id=v_draft and role_row.active
  order by role_row.sort_order,role_row.id limit 1;
  select duty_row.id into v_duty
  from public.matrix_duties_v2 duty_row
  where duty_row.matrix_version_id=v_draft and duty_row.active
  order by duty_row.sort_order,duty_row.id limit 1;
  select location_row.id into v_location_one
  from public.matrix_locations_v2 location_row
  where location_row.matrix_version_id=v_draft and location_row.active
  order by location_row.sort_order,location_row.id limit 1;
  select location_row.id into v_location_two
  from public.matrix_locations_v2 location_row
  where location_row.matrix_version_id=v_draft and location_row.active
    and location_row.id<>v_location_one
  order by location_row.sort_order,location_row.id limit 1;
  if v_location_two is null then
    v_result:=public.matrix_v2_admin_save_alpha16('LOCATION',null,jsonb_build_object(
      'code','A16_SECOND_LOCATION','name','Drugi lokal Alpha 16',
      'timezone','Europe/Warsaw','sortOrder',990,'active',true
    ));
    v_location_two:=(v_result->>'id')::uuid;
  end if;
  if v_role is null or v_location_one is null then
    raise exception 'ALPHA16_MATRIX_SCOPE_MISSING';
  end if;
  if v_duty is null then
    v_result:=public.matrix_v2_admin_save_alpha16('DUTY',null,jsonb_build_object(
      'code','A16_DUTY','name','Obowiązek Alpha 16',
      'description','Kontrakt obowiązku zmianowego','sortOrder',990,'active',true
    ));
    v_duty:=(v_result->>'id')::uuid;
  end if;

  v_result:=public.matrix_v2_employee_save_alpha16(null,jsonb_build_object(
    'firstName','Automatyczny','lastName','Numer Jeden',
    'email','alpha16-one@example.invalid','employmentStart',current_date,
    'nominalMonthlyMinutes',9600,'maximumMonthlyMinutes',12000,
    'maximumWeeklyMinutes',2400,'maximumConsecutiveDays',6,
    'minimumRestMinutes',660,'onlyMorning',false,'onlyEvening',false,
    'noWeekends',false,'primaryRoleId',v_role,
    'locationIds',jsonb_build_array(v_location_one,v_location_two),
    'preferenceMonth',v_month,
    'shiftPeriodPreferences',jsonb_build_object(
      'MORNING','BLOCKED','MIDDLE','PREFERRED','EVENING','INHERIT'
    )
  ));
  v_employee_one:=(v_result->>'id')::uuid;
  v_employee_no_one:=v_result->>'employeeNo';

  v_result:=public.matrix_v2_employee_save_alpha16(null,jsonb_build_object(
    'firstName','Automatyczny','lastName','Numer Dwa',
    'email','alpha16-two@example.invalid','employmentStart',current_date,
    'nominalMonthlyMinutes',9600,'maximumMonthlyMinutes',12000,
    'maximumWeeklyMinutes',2400,'maximumConsecutiveDays',6,
    'minimumRestMinutes',660,'onlyMorning',false,'onlyEvening',false,
    'noWeekends',false,'primaryRoleId',v_role,
    'locationIds',jsonb_build_array(v_location_one)
  ));
  v_employee_two:=(v_result->>'id')::uuid;
  v_employee_no_two:=v_result->>'employeeNo';

  if v_employee_no_one !~ '^GP-[0-9]{3,}$'
    or v_employee_no_two !~ '^GP-[0-9]{3,}$'
    or substring(v_employee_no_two from '[0-9]+$')::integer
      <>substring(v_employee_no_one from '[0-9]+$')::integer+1 then
    raise exception 'ALPHA16_EMPLOYEE_NUMBER_SEQUENCE_INVALID: %, %',
      v_employee_no_one,v_employee_no_two;
  end if;
  if (select count(*) from public.matrix_employee_locations_v2 grant_row
      where grant_row.matrix_version_id=v_draft
        and grant_row.employee_id=v_employee_one and grant_row.active
        and grant_row.standard_allowed)<>2
    or exists(select 1 from public.matrix_employee_locations_v2 grant_row
      where grant_row.matrix_version_id=v_draft
        and grant_row.employee_id=v_employee_one and grant_row.home_location) then
    raise exception 'ALPHA16_MULTI_LOCATION_OR_HOME_FLAG_INVALID';
  end if;

  v_directory:=public.matrix_v2_employee_directory_alpha16(v_month);
  if not exists(select 1
      from jsonb_array_elements(v_directory->'employees') employee
      where employee.value->>'id'=v_employee_one::text
        and jsonb_array_length(employee.value->'locationIds')=2
        and employee.value->'shiftPeriodPreferences'->>'MORNING'='BLOCKED'
        and employee.value->'shiftPeriodPreferences'->>'MIDDLE'='PREFERRED') then
    raise exception 'ALPHA16_EMPLOYEE_DIRECTORY_INCOMPLETE: %',v_directory;
  end if;

  for v_index in 1..10 loop
    perform public.matrix_v2_admin_save_alpha16('SHIFT',null,jsonb_build_object(
      'locationId',v_location_one,
      'code','A16_UAT_'||lpad(v_index::text,2,'0'),
      'name','Blok Alpha 16 '||v_index,
      'startsAt',case when v_index%2=0 then '12:00' else '15:00' end,
      'endsAt',case when v_index%2=0 then '15:00' else '17:00' end,
      'endsNextDay',false,'days',jsonb_build_array(6,7),
      'sortOrder',900+v_index,'active',true,
      'shiftPeriod',case when v_index%2=0 then 'MIDDLE' else 'EVENING' end
    ));
  end loop;
  if (select count(*) from public.matrix_shift_templates_v2 shift_row
      where shift_row.matrix_version_id=v_draft
        and shift_row.code like 'A16_UAT_%')<>10 then
    raise exception 'ALPHA16_DYNAMIC_SHIFT_COUNT_LIMITED';
  end if;

  v_result:=public.matrix_v2_admin_save_alpha16(
    'ROLE_DUTY',null,jsonb_build_object(
      'roleId',v_role,'dutyId',v_duty,'assignmentMode','REQUIRED',
      'minimumCount',1,'active',true,
      'shiftObligation',true,'shiftPeriod','MIDDLE'
    )
  );
  v_role_duty:=(v_result->>'id')::uuid;
  if not exists(select 1 from public.matrix_role_duties_v2 link
      where link.id=v_role_duty and link.shift_obligation
        and link.shift_period='MIDDLE') then
    raise exception 'ALPHA16_ROLE_DUTY_PERIOD_NOT_SAVED';
  end if;

  v_preview:=public.matrix_v2_import_preview_alpha16('{}'::jsonb);
  if (v_preview->>'valid')::boolean
    or not exists(select 1 from jsonb_array_elements(v_preview->'errors') error_row
      where error_row.value->>'code'='EMPTY_IMPORT') then
    raise exception 'ALPHA16_EMPTY_IMPORT_NOT_REJECTED: %',v_preview;
  end if;

  v_payload:=jsonb_build_object(
    'employees',jsonb_build_array(jsonb_build_object(
      'employeeNo','GP-999999','firstName','Błędny','lastName','Numer',
      'email','alpha16-bad-number@example.invalid',
      'primaryRoleCode',(select role_row.code from public.matrix_roles_v2 role_row
        where role_row.id=v_role),
      'locationCodes',jsonb_build_array((select location_row.code
        from public.matrix_locations_v2 location_row where location_row.id=v_location_one)),
      'baseRate','30.00'
    )),
    'shifts','[]'::jsonb,'staffingRules','[]'::jsonb,'roleDuties','[]'::jsonb
  );
  v_preview:=public.matrix_v2_import_preview_alpha16(v_payload);
  if (v_preview->>'valid')::boolean
    or not exists(select 1 from jsonb_array_elements(v_preview->'errors') error_row
      where error_row.value->>'code'='EMPLOYEE_NUMBER_NOT_FOUND') then
    raise exception 'ALPHA16_UNKNOWN_EMPLOYEE_NUMBER_NOT_REJECTED: %',v_preview;
  end if;

  v_payload:=jsonb_build_object(
    'shifts',jsonb_build_array(jsonb_build_object(
      'locationCode',(select location_row.code
        from public.matrix_locations_v2 location_row where location_row.id=v_location_two),
      'code','A16_IMPORT_BLOCK','name','Importowany blok obsady',
      'startsAt','12:00','endsAt','15:00','endsNextDay',false,
      'days',jsonb_build_array(7),'shiftPeriod','MIDDLE','active',true
    )),
    'employees','[]'::jsonb,'staffingRules','[]'::jsonb,'roleDuties','[]'::jsonb
  );
  v_preview:=public.matrix_v2_import_preview_alpha16(v_payload);
  if not (v_preview->>'valid')::boolean then
    raise exception 'ALPHA16_VALID_IMPORT_REJECTED: %',v_preview;
  end if;
  v_result:=public.matrix_v2_import_apply_alpha16(v_payload);
  if coalesce((v_result->>'appliedRows')::integer,0)<>1
    or not exists(select 1 from public.matrix_shift_templates_v2 shift_row
      where shift_row.matrix_version_id=v_draft
        and shift_row.code='A16_IMPORT_BLOCK'
        and shift_row.shift_period='MIDDLE') then
    raise exception 'ALPHA16_IMPORT_APPLY_FAILED: %',v_result;
  end if;

  v_result:=public.matrix_v2_publication_readiness_alpha16(current_date);
  if jsonb_typeof(v_result->'blockers')<>'array'
    or jsonb_typeof(v_result->'ready')<>'boolean' then
    raise exception 'ALPHA16_MATRIX_READINESS_NOT_DIAGNOSTIC: %',v_result;
  end if;

  v_result:=public.optimizer_runs_catalog_alpha16(v_month,'COMPANY',null);
  if jsonb_typeof(v_result->'runs')<>'array' then
    raise exception 'ALPHA16_RUN_CATALOG_INVALID: %',v_result;
  end if;
  v_result:=public.optimizer_operational_workspace_alpha16(v_month);
  if not (v_result ? 'scheduleId') or not (v_result ? 'overrides') then
    raise exception 'ALPHA16_OPERATIONAL_WORKSPACE_INVALID: %',v_result;
  end if;
end;
$$;

do $$
declare
  v_month date:=date_trunc('month',current_date)::date;
  v_preferences jsonb;
begin
  perform public.employee_shift_preferences_save_self_v2(
    v_month,jsonb_build_object(
      'MORNING','PREFERRED','MIDDLE','AVOIDED','EVENING','NEUTRAL'
    )
  );
  v_preferences:=public.employee_shift_preferences_self_v2(v_month);
  if v_preferences->'employee'->>'MORNING'<>'PREFERRED'
    or v_preferences->'employee'->>'MIDDLE'<>'AVOIDED'
    or v_preferences->'managerOverrides'->>'MORNING'<>'BLOCKED'
    or v_preferences->'effective'->>'MORNING'<>'BLOCKED' then
    raise exception 'ALPHA16_MANAGER_PREFERENCE_PRECEDENCE_INVALID: %',
      v_preferences;
  end if;
end;
$$;

rollback;
