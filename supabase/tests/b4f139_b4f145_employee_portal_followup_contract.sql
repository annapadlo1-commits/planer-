-- B4F-139..145 executable database contract. Every fixture is rolled back.

begin;

insert into auth.users(
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,is_super_admin,created_at,updated_at
) values
(
  '00000000-0000-0000-0000-000000000000',
  'b4f10000-0000-4000-8000-000000000139',
  'authenticated','authenticated','portal-followup-proposer@example.invalid','',now(),
  '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,false,now(),now()
),
(
  '00000000-0000-0000-0000-000000000000',
  'b4f10000-0000-4000-8000-000000000145',
  'authenticated','authenticated','portal-followup-candidate@example.invalid','',now(),
  '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,false,now(),now()
);

do $$
declare
  v_employee uuid;
begin
  if has_function_privilege(
      'anon',
      'public.employee_request_submit_uat_v2(text,date[],boolean,time without time zone,time without time zone,text)',
      'execute'
    ) or not has_function_privilege(
      'authenticated',
      'public.employee_request_submit_uat_v2(text,date[],boolean,time without time zone,time without time zone,text)',
      'execute'
    ) then
    raise exception 'PARTIAL_REQUEST_V2_GRANTS_INVALID';
  end if;
  if has_function_privilege(
      'authenticated','solver_private.shift_swap_personal_notifications_v1()','execute'
    ) or has_function_privilege(
      'authenticated','solver_private.normalize_personal_notification_v1()','execute'
    ) then
    raise exception 'PRIVATE_TRIGGER_FUNCTION_EXPOSED';
  end if;
  if not exists(select 1 from pg_trigger trigger_row
      where trigger_row.tgrelid='public.notifications'::regclass
        and trigger_row.tgname='notifications_personal_normalize_v1'
        and trigger_row.tgenabled='O')
    or not exists(select 1 from pg_trigger trigger_row
      where trigger_row.tgrelid='public.shift_swap_requests_v2'::regclass
        and trigger_row.tgname='shift_swap_personal_notifications_v1'
        and trigger_row.tgenabled='O') then
    raise exception 'PERSONAL_NOTIFICATION_TRIGGERS_MISSING';
  end if;

  select employee.id into v_employee
  from public.employees employee
  where employee.active and employee.archived_at is null
    and employee.auth_user_id is null
  order by employee.created_at,employee.id limit 1;
  if v_employee is null then raise exception 'PARTIAL_REQUEST_TEST_EMPLOYEE_MISSING'; end if;
  update public.employees
  set auth_user_id='b4f10000-0000-4000-8000-000000000139'
  where id=v_employee;
  perform set_config('portal_followup.employee',v_employee::text,true);
end;
$$;

select set_config('request.jwt.claim.sub','b4f10000-0000-4000-8000-000000000139',true);
select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;

do $$
declare
  v_matrix public.matrix_versions%rowtype;
  v_day date;
  v_result jsonb;
  v_first uuid;
  v_second uuid;
begin
  select * into v_matrix from public.matrix_versions matrix_row
  where matrix_row.status='ACTIVE' and matrix_row.schema_version>=2
    and (matrix_row.effective_to is null or matrix_row.effective_to>=current_date+2)
  order by matrix_row.version desc limit 1;
  if v_matrix.id is null then raise exception 'ACTIVE_MATRIX_FOR_PARTIAL_REQUEST_MISSING'; end if;
  v_day:=greatest(current_date+1,v_matrix.effective_from+1);
  if v_matrix.effective_to is not null and v_day+1>v_matrix.effective_to then
    raise exception 'ACTIVE_MATRIX_PARTIAL_WINDOW_TOO_SHORT';
  end if;
  v_result:=public.employee_request_submit_uat_v2(
    'SICKNESS',array[v_day,v_day+1],false,'08:00','12:00','Częściowe L4'
  );
  if jsonb_array_length(v_result->'requestIds')<>2 then
    raise exception 'PARTIAL_MULTI_DAY_REQUEST_NOT_SPLIT: %',v_result;
  end if;
  v_first:=(v_result->'requestIds'->>0)::uuid;
  v_second:=(v_result->'requestIds'->>1)::uuid;
  if not exists(select 1 from public.employee_requests_v1 request_row
      where request_row.id=v_first
        and upper(request_row.requested_range)-lower(request_row.requested_range)=interval '4 hours')
    or not exists(select 1 from public.employee_requests_v1 request_row
      where request_row.id=v_second
        and upper(request_row.requested_range)-lower(request_row.requested_range)=interval '4 hours') then
    raise exception 'PARTIAL_REQUEST_DURATION_INVALID';
  end if;
  if exists(select 1
      from public.employee_requests_v1 first_request
      join public.employee_requests_v1 second_request on second_request.id=v_second
      where first_request.id=v_first
        and first_request.requested_range && second_request.requested_range) then
    raise exception 'PARTIAL_REQUESTS_BRIDGED_OVERNIGHT';
  end if;

end;
$$;

reset role;

do $$
begin
  insert into public.notifications(recipient_id,title,body)
  values('b4f10000-0000-4000-8000-000000000139',
    'Zmieniono Twój grafik — test','Sprawdź nową wersję.');
  if not exists(select 1 from public.notifications notification
      where notification.recipient_id='b4f10000-0000-4000-8000-000000000139'
        and notification.title='Zmieniono Twój grafik — test'
        and notification.kind='SCHEDULE_PUBLISHED'
        and notification.action_route='/my-schedule'
        and notification.sent_at is not null) then
    raise exception 'SCHEDULE_NOTIFICATION_NOT_NORMALIZED';
  end if;
end;
$$;

do $$
declare
  v_assignment record;
  v_request uuid;
  v_candidate uuid;
begin
  update public.employees set auth_user_id=null
  where id=current_setting('portal_followup.employee')::uuid;
  for v_assignment in
    select assignment.id,assignment.employee_id,assignment.role_id,
      role.matrix_version_id,shift.shift_date
    from public.plan_assignments_v2 assignment
    join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
    join public.matrix_roles_v2 role on role.id=assignment.role_id
    where shift.starts_at>now()
      and solver_private.assignment_is_currently_published_v2(assignment.id)
      and not exists(select 1 from public.shift_swap_requests_v2 request
        where request.original_assignment_id=assignment.id
          and request.status in ('OPEN','EMPLOYEE_ACCEPTED'))
    order by shift.starts_at,assignment.id
    limit 50
  loop
    v_request:=gen_random_uuid();
    insert into public.shift_swap_requests_v2(
      id,month,matrix_version_id,original_assignment_id,role_id,
      proposer_employee_id,target_employee_id,message,created_by
    ) values(
      v_request,date_trunc('month',v_assignment.shift_date)::date,
      v_assignment.matrix_version_id,v_assignment.id,v_assignment.role_id,
      v_assignment.employee_id,null,'Kontrakt ogólnej tablicy',
      'b4f10000-0000-4000-8000-000000000139'
    );
    select employee.id into v_candidate
    from public.employees employee
    where employee.active and employee.archived_at is null
      and employee.auth_user_id is null
      and employee.id<>v_assignment.employee_id
      and cardinality(solver_private.swap_candidate_reasons_uat_v2(v_request,employee.id))=0
    order by employee.employee_no,employee.id limit 1;
    exit when v_candidate is not null;
    delete from public.shift_swap_requests_v2 where id=v_request;
  end loop;
  if v_candidate is null then raise exception 'ELIGIBLE_PUBLIC_SWAP_FIXTURE_MISSING'; end if;

  delete from public.shift_swap_requests_v2 where id=v_request;
  update public.employees
  set auth_user_id='b4f10000-0000-4000-8000-000000000139'
  where id=v_assignment.employee_id;
  update public.employees
  set auth_user_id='b4f10000-0000-4000-8000-000000000145'
  where id=v_candidate;
  v_request:=gen_random_uuid();
  insert into public.shift_swap_requests_v2(
    id,month,matrix_version_id,original_assignment_id,role_id,
    proposer_employee_id,target_employee_id,message,created_by
  ) values(
    v_request,date_trunc('month',v_assignment.shift_date)::date,
    v_assignment.matrix_version_id,v_assignment.id,v_assignment.role_id,
    v_assignment.employee_id,null,'Kontrakt ogólnej tablicy',
    'b4f10000-0000-4000-8000-000000000139'
  );
  if not exists(select 1 from public.notifications notification
      where notification.recipient_id='b4f10000-0000-4000-8000-000000000145'
        and notification.context_type='SHIFT_SWAP'
        and notification.context_id=v_request::text
        and notification.title='Nowa oferta na tablicy zmian'
        and notification.action_route='/swaps') then
    raise exception 'GENERAL_SWAP_NOTIFICATION_MISSING';
  end if;

  update public.shift_swap_requests_v2
  set status='EMPLOYEE_ACCEPTED',accepted_by_employee_id=v_candidate,
    employee_decided_at=now()
  where id=v_request;
  if not exists(select 1 from public.notifications notification
      where notification.recipient_id='b4f10000-0000-4000-8000-000000000139'
        and notification.context_type='SHIFT_SWAP'
        and notification.context_id=v_request::text
        and notification.title='Ktoś przyjął Twoją propozycję zmiany'
        and notification.action_route='/swaps') then
    raise exception 'PROPOSER_SWAP_ACCEPTED_NOTIFICATION_MISSING';
  end if;
  if exists(select 1 from public.notifications notification
      where notification.context_type='SHIFT_SWAP'
        and notification.context_id=v_request::text
        and notification.title='Nowa oferta na tablicy zmian'
        and notification.resolved_at is null) then
    raise exception 'GENERAL_SWAP_NOTIFICATION_NOT_RESOLVED_AFTER_TAKE';
  end if;
  if not exists(select 1 from public.notifications notification
      where notification.context_type='SHIFT_SWAP'
        and notification.context_id=v_request::text
        and notification.title='Zamiana czeka na akceptację'
        and notification.action_required and notification.resolved_at is null) then
    raise exception 'MANAGER_SWAP_ACTION_NOTIFICATION_MISSING';
  end if;
  update public.shift_swap_requests_v2
  set status='LEADER_REJECTED',leader_decided_at=now(),
    leader_reason='Kontrakt zakończenia powiadomienia'
  where id=v_request;
  if exists(select 1 from public.notifications notification
      where notification.context_type='SHIFT_SWAP'
        and notification.context_id=v_request::text
        and notification.action_required and notification.resolved_at is null) then
    raise exception 'MANAGER_SWAP_ACTION_NOT_RESOLVED_AFTER_DECISION';
  end if;
end;
$$;

select 'B4F-139..B4F-145 EMPLOYEE_PORTAL_FOLLOWUP_CONTRACT_PASS' as result;

rollback;
