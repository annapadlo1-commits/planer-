-- B4F-131..138 executable contract. Every fixture and mutation is rolled back.

begin;

insert into auth.users(
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,is_super_admin,created_at,updated_at
) values
(
  '00000000-0000-0000-0000-000000000000',
  'b4f10000-0000-4000-8000-000000000131',
  'authenticated','authenticated','personal-employee@example.invalid','',now(),
  '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,false,now(),now()
),
(
  '00000000-0000-0000-0000-000000000000',
  'b4f10000-0000-4000-8000-000000000134',
  'authenticated','authenticated','personal-manager@example.invalid','',now(),
  '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,false,now(),now()
);

insert into public.user_permissions(auth_user_id,app_role)
values('b4f10000-0000-4000-8000-000000000134','OWNER'),
  ('b4f10000-0000-4000-8000-000000000131','EMPLOYEE');

insert into public.application_access_directory_v1(
  email,app_role,auth_user_id,active,created_by
) values
  ('personal-employee@example.invalid','EMPLOYEE','b4f10000-0000-4000-8000-000000000131',true,
    'b4f10000-0000-4000-8000-000000000134'),
  ('personal-manager@example.invalid','OWNER','b4f10000-0000-4000-8000-000000000134',true,
    'b4f10000-0000-4000-8000-000000000134');

do $$
declare v_employee uuid;
begin
  select employee.id into v_employee from public.employees employee
  where employee.active and employee.archived_at is null
    and employee.auth_user_id is null
  order by employee.created_at,employee.id limit 1;
  if v_employee is null then raise exception 'PERSONAL_WORKSPACE_TEST_EMPLOYEE_MISSING'; end if;
  update public.employees set auth_user_id='b4f10000-0000-4000-8000-000000000131'
  where id=v_employee;
  perform set_config('personal_test.employee',v_employee::text,true);

  if to_regclass('public.user_profiles_v1') is null
    or to_regclass('public.employee_requests_v1') is null then
    raise exception 'PERSONAL_WORKSPACE_TABLES_MISSING';
  end if;
  if not exists(select 1 from pg_class table_row
      where table_row.oid='public.user_profiles_v1'::regclass and table_row.relrowsecurity)
    or not exists(select 1 from pg_class table_row
      where table_row.oid='public.employee_requests_v1'::regclass and table_row.relrowsecurity) then
    raise exception 'PERSONAL_WORKSPACE_RLS_MISSING';
  end if;
  if has_function_privilege('anon','public.personal_profile_workspace_uat_v1()','execute')
    or has_function_privilege('anon','public.employee_request_submit_uat_v1(text,date[],boolean,time without time zone,time without time zone,text)','execute')
    or not has_function_privilege('authenticated','public.personal_action_workspace_uat_v1()','execute') then
    raise exception 'PERSONAL_WORKSPACE_FUNCTION_GRANTS_INVALID';
  end if;
  if has_table_privilege('authenticated','public.employee_requests_v1','insert')
    or has_table_privilege('authenticated','public.notifications','update') then
    raise exception 'PERSONAL_WORKSPACE_DIRECT_WRITE_GRANT_FOUND';
  end if;
  if not exists(select 1 from storage.buckets bucket where bucket.id='profile-avatars'
      and not bucket.public and bucket.file_size_limit=5242880) then
    raise exception 'PRIVATE_PROFILE_AVATAR_BUCKET_MISSING';
  end if;
end;
$$;

select set_config('request.jwt.claim.sub','b4f10000-0000-4000-8000-000000000131',true);
select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;

do $$
declare
  v_profile jsonb;
  v_action jsonb;
  v_leave jsonb;
  v_sickness jsonb;
  v_message jsonb;
  v_matrix public.matrix_versions%rowtype;
  v_day date;
begin
  v_profile:=public.personal_profile_save_uat_v1(
    'Kocie Konto','CAT','CAT_50','#D9987E',null,'{"compact":false}'::jsonb
  );
  if v_profile->'profile'->>'displayName'<>'Kocie Konto'
    or v_profile->'profile'->>'avatarMode'<>'CAT'
    or v_profile->'profile'->>'catAvatarKey'<>'CAT_50'
    or v_profile->'profile'->>'noteColor'<>'#D9987E' then
    raise exception 'PERSONAL_PROFILE_ROUND_TRIP_FAILED: %',v_profile;
  end if;

  select * into v_matrix from public.matrix_versions matrix_row
  where matrix_row.status='ACTIVE' and matrix_row.schema_version>=2
    and (matrix_row.effective_to is null or matrix_row.effective_to>=current_date+1)
  order by matrix_row.version desc limit 1;
  if v_matrix.id is null then raise exception 'ACTIVE_MATRIX_FOR_REQUEST_TEST_MISSING'; end if;
  v_day:=greatest(current_date+1,v_matrix.effective_from+1);
  if v_matrix.effective_to is not null and v_day+4>v_matrix.effective_to then
    raise exception 'ACTIVE_MATRIX_TEST_WINDOW_TOO_SHORT';
  end if;
  perform set_config('personal_test.day',v_day::text,true);

  v_leave:=public.employee_request_submit_uat_v1(
    'LEAVE',array[v_day,v_day+1],true,null,null,'Urlop kontraktowy'
  );
  v_sickness:=public.employee_request_submit_uat_v1(
    'SICKNESS',array[v_day+3],true,null,null,'L4 kontraktowe'
  );
  if (v_leave->>'pending')::integer<>0 or (v_leave->>'saved')::integer<>1
    or jsonb_array_length(v_leave->'requestIds')<>1 then
    raise exception 'LEAVE_REQUEST_SUBMIT_FAILED: %',v_leave;
  end if;
  if (v_sickness->>'saved')::integer<>1
    or not exists(select 1 from public.employee_time_constraints_v2 constraint_row
      where constraint_row.id=(select request_row.constraint_id
        from public.employee_requests_v1 request_row
        where request_row.id=(v_sickness->'requestIds'->>0)::uuid)
        and constraint_row.constraint_kind='SICKNESS'
        and constraint_row.status='ACTIVE') then
    raise exception 'SICKNESS_NOT_APPLIED_IMMEDIATELY: %',v_sickness;
  end if;
  perform set_config('personal_test.leave_request',v_leave->'requestIds'->>0,true);
  perform set_config('personal_test.sickness_request',v_sickness->'requestIds'->>0,true);
  v_message:=public.message_conversation_create_uat_v1(
    'b4f10000-0000-4000-8000-000000000134','Kontrakt kotów','Wiadomość z kotem 50',null,null
  );
  perform set_config('personal_test.conversation',v_message->>'conversationId',true);
  v_action:=public.personal_action_workspace_uat_v1();
  if jsonb_array_length(v_action->'myRequests')<2 then
    raise exception 'EMPLOYEE_REQUEST_HISTORY_MISSING: %',v_action;
  end if;
end;
$$;

reset role;
select set_config('request.jwt.claim.sub','b4f10000-0000-4000-8000-000000000134',true);
select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;

do $$
declare
  v_action jsonb;
  v_result jsonb;
  v_messages jsonb;
  v_leave uuid:=current_setting('personal_test.leave_request')::uuid;
  v_sickness uuid:=current_setting('personal_test.sickness_request')::uuid;
begin
  v_action:=public.personal_action_workspace_uat_v1();
  if jsonb_array_length(v_action->'managerInbox')<>2
    or (v_action->>'actionCount')::integer<2 then
    raise exception 'MANAGER_ACTION_INBOX_MISSING: %',v_action;
  end if;
  if not exists(select 1 from jsonb_array_elements(v_action->'notifications') notification
      where notification->>'kind'='MESSAGE'
        and notification->>'actionRoute' like '%conversation=%') then
    raise exception 'MESSAGE_NOTIFICATION_MISSING: %',v_action;
  end if;
  v_messages:=public.message_center_workspace_uat_v1();
  if not exists(select 1 from jsonb_array_elements(v_messages->'messages') message_row
      where message_row->>'senderCatAvatarKey'='CAT_50'
        and message_row->>'senderName'='Kocie Konto') then
    raise exception 'MESSAGE_CAT_PROFILE_MISSING: %',v_messages;
  end if;
  perform public.message_mark_read_uat_v1(current_setting('personal_test.conversation')::uuid);
  begin
    perform public.employee_request_review_uat_v1(v_sickness,'REJECT','nie');
    raise exception 'SICKNESS_REJECTION_UNEXPECTEDLY_SUCCEEDED';
  exception when others then
    if sqlerrm not like '%SICKNESS_CANNOT_BE_REJECTED%' then raise; end if;
  end;
  v_result:=public.employee_request_review_uat_v1(v_sickness,'ACKNOWLEDGE',null);
  if v_result->>'status'<>'ACKNOWLEDGED' then
    raise exception 'SICKNESS_ACKNOWLEDGEMENT_FAILED: %',v_result;
  end if;
  v_result:=public.employee_request_review_uat_v1(v_leave,'APPROVE','Potwierdzony urlop');
  if v_result->>'status'<>'APPROVED'
    or not exists(select 1 from public.employee_time_constraints_v2 constraint_row
      where constraint_row.id=(v_result->>'constraintId')::uuid
        and constraint_row.constraint_kind='LEAVE' and constraint_row.status='ACTIVE') then
    raise exception 'LEAVE_APPROVAL_NOT_APPLIED: %',v_result;
  end if;
  v_action:=public.personal_action_workspace_uat_v1();
  if jsonb_array_length(v_action->'managerInbox')<>0
    or (v_action->>'actionCount')::integer<>0 then
    raise exception 'RESOLVED_MANAGER_ACTIONS_STILL_OPEN: %',v_action;
  end if;
end;
$$;

select 'B4F-131..B4F-138 PERSONAL_WORKSPACE_CONTRACT_PASS' as result;

rollback;
