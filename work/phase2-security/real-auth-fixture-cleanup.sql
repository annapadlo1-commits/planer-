begin;

do $$
declare v_project_ref text;v_original_owner uuid;v_reset jsonb;
begin
  select config->>'projectRef' into v_project_ref
  from public.uat_environment_controls
  where control_key='ISOLATED_UAT_DESTRUCTIVE_TOOLS' and enabled
    and config->>'environment'='ISOLATED_UAT';
  if v_project_ref is distinct from 'nhthrtpkfpmufmrmdyjg'
    or v_project_ref='bdybebzvzapihjdauehg' then
    raise exception 'ABORT_CLEANUP_UNEXPECTED_PROJECT_REF:%',coalesce(v_project_ref,'NULL');
  end if;
  if (select count(*) from auth.users where lower(email) not like 'audit-phase2-%@szafunek.pl')<>1
    or exists(select 1 from public.employees where employee_no not like 'AUDIT-P2-%')
    or exists(select 1 from public.matrix_versions where status='ACTIVE' and id<>'f3200000-0000-4000-8000-000000000001') then
    raise exception 'ABORT_CLEANUP_FOREIGN_STATE_DETECTED';
  end if;
  select users.id into strict v_original_owner
  from auth.users users join public.matrix_scope_grants_v2 grants on grants.auth_user_id=users.id
  where lower(users.email) not like 'audit-phase2-%@szafunek.pl'
    and grants.app_role='OWNER' and grants.active;
  perform set_config('request.jwt.claim.sub',v_original_owner::text,true);
  perform set_config('request.jwt.claim.role','authenticated',true);
  v_reset:=public.uat_full_business_reset_v1('WYCZYŚĆ UAT I POZOSTAĆ PRZY PUSTEJ KONFIGURACJI');
  if coalesce((v_reset->>'ok')::boolean,false) is not true or v_reset->>'endState'<>'EMPTY_FIRST_RUN' then
    raise exception 'CLEANUP_RESET_FAILED:%',v_reset;
  end if;
end;
$$;

select jsonb_build_object(
  'auditAuthUsers',(select count(*) from auth.users where lower(email) like 'audit-phase2-%@szafunek.pl'),
  'auditEmployees',(select count(*) from public.employees where employee_no like 'AUDIT-P2-%'),
  'auditRoles',(select count(*) from public.matrix_roles_v2 where code like 'AUDIT_P2_ROLE_%'),
  'auditLocations',(select count(*) from public.matrix_locations_v2 where code like 'AUDIT_P2_LOCATION_%'),
  'auditMatrices',(select count(*) from public.matrix_versions where id='f3200000-0000-4000-8000-000000000001'),
  'auditPatterns',(select count(*) from public.employee_weekly_work_patterns_v2 where reason like 'AUDIT P2 %'),
  'auditAdHoc',(select count(*) from public.recovery_ad_hoc_pool_v2 where notes='AUDIT P2'),
  'auditDependentData',(
    (select count(*) from public.employee_time_constraints_v2 where note like 'AUDIT P2 %')+
    (select count(*) from public.employee_pay_rates_v2 where employee_id::text like 'f3100000-%')
  ),
  'activeMatrices',(select count(*) from public.matrix_versions where status='ACTIVE'),
  'ownerGrants',(select count(*) from public.matrix_scope_grants_v2 where app_role='OWNER' and active)
) as phase2_real_auth_cleanup;

commit;
