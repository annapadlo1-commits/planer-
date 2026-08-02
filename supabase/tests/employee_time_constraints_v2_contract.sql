-- Employee exact-window availability contract. The transaction proves that an
-- authenticated employee can store more than one local window on a day, read
-- only the self-scoped active ranges, and revoke their own rows.

begin;

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

  -- The disposable branch intentionally contains no real employee logins.
  -- Link its single owner identity to one demo employee only inside this
  -- transaction, then exercise the exact same self-service RPC boundary.
  select up.auth_user_id into v_auth_user
  from public.user_permissions up
  where up.app_role='OWNER' order by up.id limit 1;
  select employee_row.id into v_employee
  from public.employees employee_row
  where employee_row.active and employee_row.archived_at is null
    and employee_row.auth_user_id is null
  order by employee_row.id limit 1;
  if v_auth_user is null or v_employee is null then
    raise exception 'TIME_CONSTRAINT_TEST_IDENTITY_CONTEXT_MISSING';
  end if;
  update public.employees set auth_user_id=v_auth_user where id=v_employee;
end;
$$;

select set_config(
  'request.jwt.claim.sub',
  (
    select employee_row.auth_user_id::text
    from public.employees employee_row
    where employee_row.auth_user_id is not null
      and employee_row.active
      and employee_row.archived_at is null
    order by employee_row.id
    limit 1
  ),
  true
);
select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;

do $$
declare
  v_month date:=date_trunc('month',current_date)::date;
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

  -- Materialize the initial branch seed as a formally published Matrix v2;
  -- production organizations already have these hashes after publication.
  perform public.matrix_v2_create_draft('Employee availability contract');
  perform public.matrix_v2_publish_draft(v_month);

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
