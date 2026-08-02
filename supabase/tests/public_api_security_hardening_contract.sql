-- Public API security regression contract.

begin;

do $$
begin
  if not (
    select table_row.relrowsecurity
    from pg_class table_row
    where table_row.oid='public.audit_log'::regclass
  ) then raise exception 'AUDIT_LOG_RLS_DISABLED'; end if;

  if has_table_privilege('anon','public.audit_log','SELECT')
    or has_table_privilege('anon','public.audit_log','INSERT')
    or has_table_privilege('authenticated','public.audit_log','SELECT')
    or has_table_privilege('authenticated','public.audit_log','INSERT')
  then raise exception 'AUDIT_LOG_PUBLIC_PRIVILEGE_LEAK'; end if;
  if not has_table_privilege('service_role','public.audit_log','SELECT')
    or not has_table_privilege('service_role','public.audit_log','INSERT')
  then raise exception 'AUDIT_LOG_SERVICE_PRIVILEGE_MISSING'; end if;

  if exists(
    select 1
    from pg_proc procedure_row
    join pg_namespace namespace_row
      on namespace_row.oid=procedure_row.pronamespace
    where namespace_row.nspname='public'
      and procedure_row.prosecdef
      and procedure_row.prokind='f'
      and has_function_privilege('anon',procedure_row.oid,'EXECUTE')
  ) then raise exception 'ANON_SECURITY_DEFINER_EXECUTE_LEAK'; end if;

  if not has_function_privilege(
    'authenticated','public.current_user_access()','EXECUTE'
  ) or not has_function_privilege(
    'authenticated','public.matrix_v2_workspace(date)','EXECUTE'
  ) or not has_function_privilege(
    'authenticated','public.matrix_v2_admin_save(text,uuid,jsonb)','EXECUTE'
  ) then raise exception 'AUTHENTICATED_APPLICATION_RPC_REMOVED'; end if;

  if not exists(
    select 1
    from pg_proc procedure_row
    where procedure_row.oid=
      'public.shift_minutes(timestamptz,timestamptz)'::regprocedure
      and 'search_path=""'=any(
        coalesce(procedure_row.proconfig,array[]::text[])
      )
  ) then raise exception 'SHIFT_MINUTES_SEARCH_PATH_MUTABLE'; end if;
end;
$$;

rollback;
