-- F4 / P0 transactional contract. Safe to repeat: all fixtures roll back.

begin;

insert into auth.users(
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,is_super_admin,created_at,updated_at
) values(
  '00000000-0000-0000-0000-000000000000',
  'f4000000-0000-4000-8000-000000000001',
  'authenticated','authenticated','f4-period-invariant@example.invalid','',now(),
  '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,
  false,now(),now()
);
insert into public.user_permissions(auth_user_id,app_role)
values('f4000000-0000-4000-8000-000000000001','OWNER');

do $$
declare
  v_definition text;
begin
  if has_function_privilege(
      'anon','public.matrix_v2_employee_save_alpha16(uuid,jsonb)','execute')
    or has_function_privilege(
      'authenticated','public.matrix_v2_employee_save_alpha16(uuid,jsonb)','execute')
    or has_function_privilege(
      'service_role','public.matrix_v2_employee_save_alpha16(uuid,jsonb)','execute')
  then
    raise exception 'F4_LEGACY_ALPHA16_WRITE_ROUTE_STILL_OPEN';
  end if;
  if not has_function_privilege(
      'authenticated','public.matrix_v2_employee_save_uat_v4(uuid,jsonb)','execute')
  then
    raise exception 'F4_CURRENT_EMPLOYEE_WRITE_ROUTE_CLOSED';
  end if;

  if not exists(
      select 1 from pg_catalog.pg_trigger trigger_row
      where trigger_row.tgrelid='public.employee_pay_rates_v2'::regclass
        and trigger_row.tgname='employee_pay_rate_employment_guard_uat_v1'
        and trigger_row.tgenabled<>'D'
    ) or not exists(
      select 1 from pg_catalog.pg_trigger trigger_row
      where trigger_row.tgrelid='public.matrix_employee_profiles_v2'::regclass
        and trigger_row.tgname='matrix_employee_profile_pay_rate_guard_uat_v1'
        and trigger_row.tgenabled<>'D'
    ) then
    raise exception 'F4_BIDIRECTIONAL_TRIGGERS_MISSING';
  end if;

  v_definition:=pg_get_functiondef(
    'solver_private.assert_employment_pay_rate_period_uat_v1(uuid,date,date,date,date)'::regprocedure
  );
  if position('PAY_RATE_OUTSIDE_EMPLOYMENT' in v_definition)=0
    or position('EMPLOYMENT_DATES_CONFLICT_PAY_RATES' in v_definition)=0
    or position('and rate.active' in lower(v_definition))>0 then
    raise exception 'F4_AUTHORITATIVE_INVARIANT_INCOMPLETE';
  end if;
  if has_function_privilege(
      'authenticated',
      'solver_private.assert_employment_pay_rate_period_uat_v1(uuid,date,date,date,date)',
      'execute'
    ) then
    raise exception 'F4_PRIVATE_INVARIANT_EXPOSED';
  end if;
end;
$$;

select set_config(
  'request.jwt.claim.sub','f4000000-0000-4000-8000-000000000001',true
);
select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;

do $$
declare
  v_draft uuid;
  v_employee uuid;
  v_profile uuid;
  v_result jsonb;
  v_start date:=current_date;
  v_end date:=current_date+30;
begin
  v_draft:=public.matrix_v2_create_draft('F4 employment/pay-rate invariant');

  v_result:=public.matrix_v2_employee_save_uat_v4(null,jsonb_build_object(
    'firstName','F4','lastName','Invariant',
    'email','f4-invariant-employee@example.invalid',
    'employmentStart',v_start,'employmentEnd',v_end,
    'nominalMonthlyMinutes',9600,'maximumMonthlyMinutes',12000,
    'maximumWeeklyMinutes',2400,'maximumConsecutiveDays',6,
    'minimumRestMinutes',660,'onlyMorning',false,'onlyEvening',false,
    'noWeekends',false,'contractType','ZLECENIE'
  ));
  v_employee:=(v_result->>'id')::uuid;
  v_profile:=(v_result->>'profileId')::uuid;
  if v_employee is null or v_profile is null then
    raise exception 'F4_EMPLOYEE_FIXTURE_CREATE_FAILED';
  end if;
  perform set_config('f4_test.employee_id',v_employee::text,true);
  perform set_config('f4_test.profile_id',v_profile::text,true);
end;
$$;

-- Privileged direct table writes are guarded in both directions.  This
-- deliberately leaves the authenticated role for the backend-only checks.
reset role;
do $$
declare
  v_employee uuid;
  v_profile uuid;
  v_rate uuid;
  v_currency text;
  v_start date:=current_date;
  v_end date:=current_date+30;
  v_message text;
begin
  v_employee:=current_setting('f4_test.employee_id')::uuid;
  v_profile:=current_setting('f4_test.profile_id')::uuid;
  select coalesce(upper(version.settings->>'currency'),'PLN') into v_currency
  from public.matrix_versions version
  join public.matrix_employee_profiles_v2 profile
    on profile.matrix_version_id=version.id
  where profile.id=v_profile;

  -- Direct table INSERT cannot put a rate before employment.
  begin
    insert into public.employee_pay_rates_v2(
      employee_id,valid_from,valid_to,base_rate_minor,currency,active
    ) values(v_employee,v_start-1,v_start+1,3100,v_currency,true);
    raise exception 'F4_DIRECT_RATE_BEFORE_EMPLOYMENT_ACCEPTED';
  exception when others then
    get stacked diagnostics v_message=message_text;
    if position('PAY_RATE_OUTSIDE_EMPLOYMENT' in v_message)=0 then
      raise exception 'F4_DIRECT_RATE_WRONG_ERROR:%',v_message;
    end if;
  end;

  -- Exact boundaries are legal and create the history used by reverse checks.
  insert into public.employee_pay_rates_v2(
    employee_id,valid_from,valid_to,base_rate_minor,currency,active
  ) values(v_employee,v_start,v_end,3100,v_currency,true)
  returning id into v_rate;
  perform set_config('f4_test.rate_id',v_rate::text,true);

  -- Direct table UPDATE cannot extend that rate beyond employment.
  begin
    update public.employee_pay_rates_v2
    set valid_to=v_end+1 where id=v_rate;
    raise exception 'F4_DIRECT_RATE_AFTER_EMPLOYMENT_ACCEPTED';
  exception when others then
    get stacked diagnostics v_message=message_text;
    if position('PAY_RATE_OUTSIDE_EMPLOYMENT' in v_message)=0 then
      raise exception 'F4_DIRECT_RATE_UPDATE_WRONG_ERROR:%',v_message;
    end if;
  end;

  -- Direct employment-date changes cannot invalidate stored rate history.
  begin
    update public.matrix_employee_profiles_v2
    set employment_end=v_end-1 where id=v_profile;
    raise exception 'F4_DIRECT_EMPLOYMENT_CONFLICT_ACCEPTED';
  exception when others then
    get stacked diagnostics v_message=message_text;
    if position('EMPLOYMENT_DATES_CONFLICT_PAY_RATES' in v_message)=0 then
      raise exception 'F4_DIRECT_EMPLOYMENT_WRONG_ERROR:%',v_message;
    end if;
  end;
end;
$$;

set local role authenticated;
do $$
declare
  v_employee uuid;
  v_start date:=current_date;
  v_end date:=current_date+30;
  v_message text;
begin
  v_employee:=current_setting('f4_test.employee_id')::uuid;

  -- Even the lower-level RPC cannot bypass the table trigger.
  begin
    perform public.matrix_v2_employee_save_v2(v_employee,jsonb_build_object(
      'employmentStart',v_start+1,'employmentEnd',v_end
    ));
    raise exception 'F4_LOW_LEVEL_RPC_EMPLOYMENT_CONFLICT_ACCEPTED';
  exception when others then
    get stacked diagnostics v_message=message_text;
    if position('EMPLOYMENT_DATES_CONFLICT_PAY_RATES' in v_message)=0 then
      raise exception 'F4_LOW_LEVEL_RPC_EMPLOYMENT_WRONG_ERROR:%',v_message;
    end if;
  end;

  -- The supported RPC is protected by the same table invariant; the failed
  -- legacy-alpha16 bypass can no longer be invoked remotely.
  begin
    perform public.matrix_v2_employee_save_uat_v4(v_employee,jsonb_build_object(
      'employmentStart',v_start+1,'employmentEnd',v_end
    ));
    raise exception 'F4_RPC_EMPLOYMENT_CONFLICT_ACCEPTED';
  exception when others then
    get stacked diagnostics v_message=message_text;
    if position('EMPLOYMENT_DATES_CONFLICT_PAY_RATES' in v_message)=0 then
      raise exception 'F4_RPC_EMPLOYMENT_WRONG_ERROR:%',v_message;
    end if;
  end;
end;
$$;

reset role;
do $$
declare
  v_profile uuid:=current_setting('f4_test.profile_id')::uuid;
  v_rate uuid:=current_setting('f4_test.rate_id')::uuid;
  v_start date:=current_date;
  v_end date:=current_date+30;
begin
  if (select profile.employment_start from public.matrix_employee_profiles_v2 profile
      where profile.id=v_profile)<>v_start
    or (select profile.employment_end from public.matrix_employee_profiles_v2 profile
      where profile.id=v_profile)<>v_end
    or (select rate.valid_to from public.employee_pay_rates_v2 rate
      where rate.id=v_rate)<>v_end then
    raise exception 'F4_REJECTED_WRITE_CHANGED_DATA';
  end if;
end;
$$;

rollback;
