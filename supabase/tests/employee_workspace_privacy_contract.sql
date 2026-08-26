-- TECH-AUD-2026-08-25-003 metadata and exposure contract.

begin;

do $$
declare
  v_function regprocedure;
  v_definition text;
  v_wrapper text;
begin
  v_function:=to_regprocedure('public.matrix_v2_workspace(date)');
  if v_function is null then raise exception 'WORKSPACE_RPC_MISSING'; end if;
  select pg_get_functiondef(v_function) into v_definition;
  if position('authorization_private.matrix_v2_visible_employee_ids_uat_v1()' in v_definition)=0
    or position('matrix_v2_workspace_before_employee_privacy_uat_v1' in v_definition)=0 then
    raise exception 'CANONICAL_PRIVACY_BOUNDARY_MISSING';
  end if;
  if not has_function_privilege('authenticated',v_function,'EXECUTE')
    or has_function_privilege('anon',v_function,'EXECUTE') then
    raise exception 'WORKSPACE_PUBLIC_GRANTS_INVALID';
  end if;

  foreach v_wrapper in array array[
    'matrix_v2_workspace_before_categories_uat_v1',
    'matrix_v2_workspace_before_overtime_uat_v1',
    'matrix_v2_workspace_before_ad_hoc_projection_uat_v1',
    'matrix_v2_workspace_before_b4f91_uat_v1',
    'matrix_v2_workspace_before_b4f52_uat_v1',
    'matrix_v2_workspace_before_employee_privacy_uat_v1'
  ] loop
    v_function:=to_regprocedure(format('public.%I(date)',v_wrapper));
    if v_function is null then raise exception 'INTERNAL_WRAPPER_MISSING:%',v_wrapper; end if;
    if has_function_privilege('public',v_function,'EXECUTE')
      or has_function_privilege('anon',v_function,'EXECUTE')
      or has_function_privilege('authenticated',v_function,'EXECUTE')
      or has_function_privilege('service_role',v_function,'EXECUTE') then
      raise exception 'INTERNAL_WRAPPER_EXPOSED:%',v_wrapper;
    end if;
  end loop;

  v_function:=to_regprocedure('authorization_private.matrix_v2_visible_employee_ids_uat_v1()');
  if v_function is null then raise exception 'VISIBLE_EMPLOYEE_HELPER_MISSING'; end if;
  select pg_get_functiondef(v_function) into v_definition;
  if position('public.matrix_v2_can_manage_employee(employee.id)' in v_definition)=0 then
    raise exception 'VISIBLE_EMPLOYEE_HELPER_DIVERGES_FROM_PHASE1';
  end if;
  if has_function_privilege('public',v_function,'EXECUTE')
    or has_function_privilege('anon',v_function,'EXECUTE')
    or has_function_privilege('authenticated',v_function,'EXECUTE')
    or has_function_privilege('service_role',v_function,'EXECUTE') then
    raise exception 'VISIBLE_EMPLOYEE_HELPER_EXPOSED';
  end if;

  if exists(
    select 1 from pg_proc function_row
    join pg_namespace schema_row on schema_row.oid=function_row.pronamespace
    where (schema_row.nspname,function_row.proname) in (
      ('public','matrix_v2_workspace'),
      ('authorization_private','matrix_v2_visible_employee_ids_uat_v1')
    ) and (
      not function_row.prosecdef
      or function_row.proconfig is null
      or not ('search_path=""'=any(function_row.proconfig))
    )
  ) then raise exception 'PRIVACY_FUNCTION_SECURITY_DEFINER_CONFIGURATION_INVALID'; end if;
end;
$$;

rollback;
