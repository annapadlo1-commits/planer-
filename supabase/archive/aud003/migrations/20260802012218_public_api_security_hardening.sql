-- Close legacy public API privileges before Matrix v2 can be promoted.

alter table public.audit_log enable row level security;

revoke all on table public.audit_log from public,anon,authenticated;
grant select,insert on table public.audit_log to service_role;

do $$
declare
  v_sequence text:=pg_get_serial_sequence('public.audit_log','id');
begin
  if v_sequence is not null then
    execute format(
      'revoke all on sequence %s from public,anon,authenticated',
      v_sequence::regclass
    );
    execute format(
      'grant usage,select on sequence %s to service_role',
      v_sequence::regclass
    );
  end if;
end;
$$;

-- This helper uses only built-in functions and does not need a mutable schema
-- search path.
alter function public.shift_minutes(timestamptz,timestamptz)
  set search_path = '';

-- Legacy migrations relied on PostgreSQL's default EXECUTE grant to PUBLIC.
-- Preserve the access already available to signed-in users and service_role,
-- but remove the inherited anonymous surface from every SECURITY DEFINER RPC.
do $$
declare
  v_function record;
begin
  for v_function in
    select
      procedure_row.oid,
      format(
        '%I.%I(%s)',
        namespace_row.nspname,
        procedure_row.proname,
        pg_get_function_identity_arguments(procedure_row.oid)
      ) as identity,
      has_function_privilege(
        'authenticated',procedure_row.oid,'EXECUTE'
      ) as authenticated_can_execute,
      has_function_privilege(
        'service_role',procedure_row.oid,'EXECUTE'
      ) as service_role_can_execute
    from pg_proc procedure_row
    join pg_namespace namespace_row
      on namespace_row.oid=procedure_row.pronamespace
    where namespace_row.nspname='public'
      and procedure_row.prosecdef
      and procedure_row.prokind='f'
  loop
    execute format(
      'revoke execute on function %s from public,anon',
      v_function.identity
    );
    if v_function.authenticated_can_execute then
      execute format(
        'grant execute on function %s to authenticated',
        v_function.identity
      );
    end if;
    if v_function.service_role_can_execute then
      execute format(
        'grant execute on function %s to service_role',
        v_function.identity
      );
    end if;
  end loop;
end;
$$;
