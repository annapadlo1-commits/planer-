-- Role publication and employee visibility must remain deployable together.

begin;

do $$
declare
  v_role_table_rls boolean;
  v_role_publish_definition text;
  v_role_publish_delegate_definition text;
  v_employee_schedule_definition text;
begin
  select relrowsecurity into v_role_table_rls
  from pg_class
  where oid='public.published_role_schedules_v2'::regclass;
  if not coalesce(v_role_table_rls,false) then
    raise exception 'PUBLISHED_ROLE_SCHEDULES_RLS_DISABLED';
  end if;

  v_role_publish_definition:=pg_get_functiondef(
    'public.optimizer_publish_role_variant_uat_v2(uuid,uuid,text,text)'::regprocedure
  );
  if position(
      'public.optimizer_publish_role_variant_before_b4f121_uat_v2'
      in v_role_publish_definition
    )=0 then
    raise exception 'ROLE_PUBLICATION_SECURED_DELEGATE_MISSING';
  end if;

  v_role_publish_delegate_definition:=pg_get_functiondef(
    'public.optimizer_publish_role_variant_before_b4f121_uat_v2(uuid,uuid,text,text)'::regprocedure
  );
  if position('ROLE_PUBLICATION_FORBIDDEN' in v_role_publish_delegate_definition)=0
    or position(
      'solver_private.revalidate_materialized_variant_v2'
      in v_role_publish_delegate_definition
    )=0 then
    raise exception 'ROLE_PUBLICATION_AUTH_OR_REVALIDATION_MISSING';
  end if;

  v_employee_schedule_definition:=pg_get_functiondef(
    'public.optimizer_employee_schedule_uat_v2(date)'::regprocedure
  );
  if position('v_source_type:=''ROLE''' in v_employee_schedule_definition)=0
    or position('EMPLOYEE_ACCOUNT_NOT_LINKED' in v_employee_schedule_definition)=0 then
    raise exception 'EMPLOYEE_ROLE_SCHEDULE_CONTRACT_MISSING';
  end if;

  if has_function_privilege(
      'anon',
      'public.optimizer_publish_role_variant_uat_v2(uuid,uuid,text,text)',
      'EXECUTE'
    )
    or has_function_privilege(
      'anon',
      'public.optimizer_employee_schedule_uat_v2(date)',
      'EXECUTE'
    ) then
    raise exception 'ANON_RUNTIME_RPC_EXECUTE_NOT_REVOKED';
  end if;
end;
$$;

rollback;
