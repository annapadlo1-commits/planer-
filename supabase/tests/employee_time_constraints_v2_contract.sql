-- Employee exact-window availability contract. The transaction proves that an
-- authenticated employee can store more than one local window on a day, read
-- only the self-scoped active ranges, and revoke their own rows.

begin;

insert into auth.users(
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,is_super_admin,created_at,updated_at
) values(
  '00000000-0000-0000-0000-000000000000',
  'a7a00000-0000-4000-8000-000000000001',
  'authenticated','authenticated','availability-owner@example.invalid','',now(),
  '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,false,now(),now()
);
insert into public.user_permissions(auth_user_id,app_role)
values('a7a00000-0000-4000-8000-000000000001','OWNER');

do $$
declare
  v_auth_user uuid;
  v_employee uuid;
begin
  if has_function_privilege(
    'anon','public.employee_time_constraints_self_v2(date)','EXECUTE'
  ) then raise exception 'ANON_TIME_CONSTRAINT_READ_ALLOWED'; end if;
  if not has_function_privilege(
    'authenticated','public.employee_time_constraints_self_v2(date)','EXECUTE'
  ) then raise exception 'AUTHENTICATED_TIME_CONSTRAINT_READ_MISSING'; end if;

  v_auth_user:='a7a00000-0000-4000-8000-000000000001';
  select employee_row.id into v_employee
  from public.employees employee_row
  where employee_row.auth_user_id=v_auth_user
    and employee_row.active and employee_row.archived_at is null
  order by employee_row.id limit 1;
  if v_auth_user is null then
    raise exception 'TIME_CONSTRAINT_TEST_IDENTITY_CONTEXT_MISSING';
  end if;
  if v_employee is null then
    select employee_row.id into v_employee
    from public.employees employee_row
    where employee_row.active and employee_row.archived_at is null
      and employee_row.auth_user_id is null
    order by employee_row.id limit 1;
    if v_employee is null then
      raise exception 'TIME_CONSTRAINT_TEST_EMPLOYEE_CONTEXT_MISSING';
    end if;
    update public.employees set auth_user_id=v_auth_user where id=v_employee;
  end if;
end;
$$;

select set_config(
  'request.jwt.claim.sub',
  'a7a00000-0000-4000-8000-000000000001',
  true
);
select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;

do $$
declare
  v_publish_from date;
  v_month date;
  v_employee_id uuid;
  v_timezone text;
  v_payload jsonb;
  v_first_id uuid;
  v_second_id uuid;
  v_first_start timestamptz;
  v_first_end timestamptz;
  v_second_start timestamptz;
  v_second_end timestamptz;
begin
  if auth.uid() is null then raise exception 'EMPLOYEE_TEST_IDENTITY_MISSING'; end if;

  -- A production Matrix can start in the middle of the current month. Publish
  -- the disposable draft no earlier than that active version and read the
  -- first complete month whose first day is covered by the published Matrix.
  select greatest(
    active_matrix.effective_from,
    date_trunc('month',current_date)::date
  ) into v_publish_from
  from public.matrix_versions active_matrix
  where active_matrix.status='ACTIVE' and active_matrix.schema_version>=2
  order by active_matrix.version desc limit 1;
  v_publish_from:=coalesce(
    v_publish_from,date_trunc('month',current_date)::date
  );
  v_month:=case
    when v_publish_from=date_trunc('month',v_publish_from)::date
      then v_publish_from
    else (date_trunc('month',v_publish_from)+interval '1 month')::date
  end;

  -- Materialize the initial branch seed as a formally published Matrix v2;
  -- production organizations already have these hashes after publication.
  perform public.matrix_v2_create_draft('Employee availability contract');
  perform public.matrix_v2_publish_draft(v_publish_from);

  v_payload:=public.employee_time_constraints_self_v2(v_month);
  v_employee_id:=(v_payload->>'employeeId')::uuid;
  v_timezone:=v_payload->>'timezone';
  if v_employee_id is null or v_timezone is null then
    raise exception 'SELF_TIME_CONSTRAINT_CONTEXT_MISSING: %',v_payload;
  end if;

  v_first_start:=((v_month+14)+time '08:15') at time zone v_timezone;
  v_first_end:=((v_month+14)+time '11:30') at time zone v_timezone;
  v_second_start:=((v_month+14)+time '14:00') at time zone v_timezone;
  v_second_end:=((v_month+14)+time '19:45') at time zone v_timezone;

  v_first_id:=public.employee_time_constraint_save_v2(
    null,v_employee_id,'AVAILABLE_WINDOW',v_first_start,v_first_end,
    'contract window one'
  );
  v_second_id:=public.employee_time_constraint_save_v2(
    null,v_employee_id,'AVAILABLE_WINDOW',v_second_start,v_second_end,
    'contract window two'
  );

  v_payload:=public.employee_time_constraints_self_v2(v_month);
  if not exists(
    select 1 from jsonb_array_elements(v_payload->'constraints') item
    where item.value->>'id'=v_first_id::text
      and item.value->>'kind'='AVAILABLE_WINDOW'
      and (item.value->>'editable')::boolean
  ) or not exists(
    select 1 from jsonb_array_elements(v_payload->'constraints') item
    where item.value->>'id'=v_second_id::text
      and item.value->>'kind'='AVAILABLE_WINDOW'
      and (item.value->>'editable')::boolean
  ) then raise exception 'MULTIPLE_SELF_WINDOWS_NOT_RETURNED: %',v_payload; end if;

  perform public.employee_time_constraint_revoke_v2(v_first_id);
  perform public.employee_time_constraint_revoke_v2(v_second_id);
  v_payload:=public.employee_time_constraints_self_v2(v_month);
  if exists(
    select 1 from jsonb_array_elements(v_payload->'constraints') item
    where item.value->>'id' in (v_first_id::text,v_second_id::text)
  ) then raise exception 'REVOKED_SELF_WINDOWS_STILL_VISIBLE'; end if;
end;
$$;

rollback;
