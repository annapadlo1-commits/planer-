begin;

set local statement_timeout = '30s';
set local lock_timeout = '5s';
set local row_security = on;

do $phase4a2c_identity_guard$
begin
  if current_user is distinct from 'postgres' then
    raise exception 'PHASE4A2C_CREATOR_ROLE_INVALID:%', current_user;
  end if;

  if current_setting('phase4a2c.isolated_restore_gate', true) is distinct from 'on' then
    raise exception 'PHASE4A2C_ISOLATED_GATE_OPT_IN_REQUIRED';
  end if;

  if inet_client_addr() is null
    or not (
      inet_client_addr() <<= inet '127.0.0.0/8'
      or inet_client_addr() = inet '::1'
    )
  then
    raise exception 'PHASE4A2C_REMOTE_DATABASE_REFUSED:%', inet_client_addr();
  end if;

  if to_regnamespace('public') is null
    or to_regrole('anon') is null
    or to_regrole('authenticated') is null
    or to_regrole('service_role') is null
  then
    raise exception 'PHASE4A2C_REQUIRED_PLATFORM_IDENTITY_MISSING';
  end if;

  if to_regclass('public.phase4a2c_acl_probe_table') is not null
    or to_regclass('public.phase4a2c_acl_probe_sequence') is not null
    or to_regprocedure('public.phase4a2c_acl_probe_invoker()') is not null
    or to_regprocedure('public.phase4a2c_acl_probe_definer()') is not null
  then
    raise exception 'PHASE4A2C_PROBE_RESIDUE_PREEXISTS';
  end if;
end;
$phase4a2c_identity_guard$;

do $phase4a2c_catalog_guard$
declare
  v_acl text[];
  v_count bigint;
  v_payload text;
begin
  select array(
    select acl_item::text
    from pg_catalog.pg_default_acl nested_default
    cross join lateral unnest(nested_default.defaclacl) acl_item
    where nested_default.oid = default_acl.oid
    order by acl_item::text collate "C"
  )
  into v_acl
  from pg_catalog.pg_default_acl default_acl
  where default_acl.defaclrole = 'postgres'::regrole
    and default_acl.defaclnamespace = 0
    and default_acl.defaclobjtype = 'f';

  if v_acl is distinct from array['postgres=X/postgres']::text[] then
    raise exception 'PHASE4A2C_GLOBAL_ROUTINE_DEFAULT_ACL_INVALID:%', v_acl;
  end if;

  if exists (
    select 1
    from pg_catalog.pg_default_acl default_acl
    where default_acl.defaclrole = 'postgres'::regrole
      and default_acl.defaclnamespace = 0
      and default_acl.defaclobjtype in ('r', 'S')
  ) then
    raise exception 'PHASE4A2C_GLOBAL_RELATION_DEFAULT_ACL_INVALID';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_default_acl default_acl
    join pg_catalog.pg_namespace namespace_row
      on namespace_row.oid = default_acl.defaclnamespace
    where default_acl.defaclrole = 'postgres'::regrole
      and namespace_row.nspname = 'public'
      and default_acl.defaclobjtype in ('f', 'r', 'S')
  ) then
    raise exception 'PHASE4A2C_PUBLIC_DEFAULT_ACL_NOT_CANONICAL';
  end if;

  -- The three pinned fresh-platform supabase_functions rows are managed state.
  -- They must remain byte-identical and are excluded from the UAT-derived
  -- application/default-ACL payload below.
  select
    count(*),
    string_agg(
      format(
        '%s|%s|%s|%s',
        namespace_row.nspname,
        pg_get_userbyid(default_acl.defaclrole),
        default_acl.defaclobjtype::text,
        coalesce((
          select string_agg(
            acl_item::text, ',' order by acl_item::text collate "C"
          )
          from unnest(default_acl.defaclacl) acl_item
        ), '')
      ),
      E'\n'
      order by
        namespace_row.nspname collate "C",
        pg_get_userbyid(default_acl.defaclrole) collate "C",
        default_acl.defaclobjtype::text collate "C"
    )
  into v_count, v_payload
  from pg_catalog.pg_default_acl default_acl
  join pg_catalog.pg_namespace namespace_row
    on namespace_row.oid = default_acl.defaclnamespace
  where namespace_row.nspname = 'supabase_functions'
    and pg_get_userbyid(default_acl.defaclrole) = 'supabase_admin';

  if v_count <> 3
    or octet_length(v_payload) <> 470
    or encode(
      pg_catalog.sha256(pg_catalog.convert_to(v_payload, 'UTF8')), 'hex'
    ) <> '4e48afbadff3c1f4a2bf8d07c492872b05ba062c59161f708e5a615e04434efe'
  then
    raise exception 'PHASE4A2C_PLATFORM_DEFAULT_ACL_COMPAT_INVALID:%', v_count;
  end if;

  select
    count(*),
    string_agg(
      format(
        '%s|%s|%s|%s',
        acl_record.schema_name,
        acl_record.grantor_name,
        acl_record.object_type,
        acl_record.acl_items
      ),
      E'\n'
      order by
        acl_record.schema_name collate "C",
        acl_record.grantor_name collate "C",
        acl_record.object_type collate "C"
    )
  into v_count, v_payload
  from (
    select
      coalesce(namespace_row.nspname, '') as schema_name,
      pg_get_userbyid(default_acl.defaclrole) as grantor_name,
      default_acl.defaclobjtype::text as object_type,
      coalesce((
        select string_agg(
          acl_item::text, ',' order by acl_item::text collate "C"
        )
        from unnest(default_acl.defaclacl) acl_item
      ), '') as acl_items
    from pg_catalog.pg_default_acl default_acl
    left join pg_catalog.pg_namespace namespace_row
      on namespace_row.oid = default_acl.defaclnamespace
    where namespace_row.nspname is distinct from 'supabase_functions'
      or pg_get_userbyid(default_acl.defaclrole) is distinct from 'supabase_admin'
  ) acl_record;

  if v_count <> 27
    or octet_length(v_payload) <> 2708
    or encode(
      pg_catalog.sha256(pg_catalog.convert_to(v_payload, 'UTF8')), 'hex'
    ) <> '1f690d52941e6a5865cb59919ded58fa087f2e594215836bd33a78a1141ae9ff'
  then
    raise exception 'PHASE4A2C_DEFAULT_ACL_FINGERPRINT_INVALID:%', v_count;
  end if;
end;
$phase4a2c_catalog_guard$;

create table public.phase4a2c_acl_probe_table (
  id bigint primary key,
  owner_id uuid not null
);

create sequence public.phase4a2c_acl_probe_sequence;

create function public.phase4a2c_acl_probe_invoker()
returns integer
language sql
immutable
security invoker
set search_path = ''
as $phase4a2c_invoker$
  select 1;
$phase4a2c_invoker$;

create function public.phase4a2c_acl_probe_definer()
returns integer
language sql
stable
security definer
set search_path = ''
as $phase4a2c_definer$
  select 1;
$phase4a2c_definer$;

do $phase4a2c_default_deny_guard$
declare
  v_privilege text;
  v_role text;
begin
  foreach v_role in array array['anon', 'authenticated', 'service_role']::text[]
  loop
    if has_schema_privilege(v_role, 'public', 'CREATE') then
      raise exception 'PHASE4A2C_API_ROLE_CAN_CREATE:%', v_role;
    end if;

    foreach v_privilege in array array[
      'SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE',
      'REFERENCES', 'TRIGGER', 'MAINTAIN'
    ]::text[]
    loop
      if has_table_privilege(
        v_role, 'public.phase4a2c_acl_probe_table'::regclass, v_privilege
      ) then
        raise exception 'PHASE4A2C_TABLE_DEFAULT_NOT_DENIED:%:%', v_role, v_privilege;
      end if;
    end loop;

    foreach v_privilege in array array['SELECT', 'UPDATE', 'USAGE']::text[]
    loop
      if has_sequence_privilege(
        v_role, 'public.phase4a2c_acl_probe_sequence'::regclass, v_privilege
      ) then
        raise exception 'PHASE4A2C_SEQUENCE_DEFAULT_NOT_DENIED:%:%', v_role, v_privilege;
      end if;
    end loop;

    if has_function_privilege(
      v_role, 'public.phase4a2c_acl_probe_invoker()'::regprocedure, 'EXECUTE'
    ) or has_function_privilege(
      v_role, 'public.phase4a2c_acl_probe_definer()'::regprocedure, 'EXECUTE'
    ) then
      raise exception 'PHASE4A2C_ROUTINE_DEFAULT_NOT_DENIED:%', v_role;
    end if;
  end loop;

  if exists (
    select 1
    from (
      select exploded_acl.grantee
      from pg_catalog.pg_class relation_row
      cross join lateral pg_catalog.aclexplode(
        coalesce(
          relation_row.relacl,
          pg_catalog.acldefault('r', relation_row.relowner)
        )
      ) exploded_acl
      where relation_row.oid = 'public.phase4a2c_acl_probe_table'::regclass

      union all

      select exploded_acl.grantee
      from pg_catalog.pg_class relation_row
      cross join lateral pg_catalog.aclexplode(
        coalesce(
          relation_row.relacl,
          pg_catalog.acldefault('s', relation_row.relowner)
        )
      ) exploded_acl
      where relation_row.oid = 'public.phase4a2c_acl_probe_sequence'::regclass

      union all

      select exploded_acl.grantee
      from pg_catalog.pg_proc procedure_row
      cross join lateral pg_catalog.aclexplode(
        coalesce(
          procedure_row.proacl,
          pg_catalog.acldefault('f', procedure_row.proowner)
        )
      ) exploded_acl
      where procedure_row.oid in (
        'public.phase4a2c_acl_probe_invoker()'::regprocedure,
        'public.phase4a2c_acl_probe_definer()'::regprocedure
      )
    ) direct_acl
    where direct_acl.grantee = 0
      or pg_get_userbyid(direct_acl.grantee) in (
        'anon', 'authenticated', 'service_role'
      )
  ) then
    raise exception 'PHASE4A2C_RAW_DEFAULT_ACL_NOT_DENIED';
  end if;

  foreach v_privilege in array array[
    'SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE',
    'REFERENCES', 'TRIGGER', 'MAINTAIN'
  ]::text[]
  loop
    if not has_table_privilege(
      'postgres', 'public.phase4a2c_acl_probe_table'::regclass, v_privilege
    ) then
      raise exception 'PHASE4A2C_OWNER_TABLE_PRIVILEGE_MISSING:%', v_privilege;
    end if;
  end loop;

  foreach v_privilege in array array['SELECT', 'UPDATE', 'USAGE']::text[]
  loop
    if not has_sequence_privilege(
      'postgres', 'public.phase4a2c_acl_probe_sequence'::regclass, v_privilege
    ) then
      raise exception 'PHASE4A2C_OWNER_SEQUENCE_PRIVILEGE_MISSING:%', v_privilege;
    end if;
  end loop;

  if not has_function_privilege(
    'postgres', 'public.phase4a2c_acl_probe_invoker()'::regprocedure, 'EXECUTE'
  ) or not has_function_privilege(
    'postgres', 'public.phase4a2c_acl_probe_definer()'::regprocedure, 'EXECUTE'
  ) then
    raise exception 'PHASE4A2C_OWNER_ROUTINE_PRIVILEGE_MISSING';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_proc procedure_row
    where procedure_row.oid = 'public.phase4a2c_acl_probe_definer()'::regprocedure
      and (
        procedure_row.proowner <> 'postgres'::regrole
        or not procedure_row.prosecdef
        or procedure_row.proconfig is distinct from array['search_path=""']::text[]
      )
  ) then
    raise exception 'PHASE4A2C_DEFINER_PROBE_SECURITY_INVALID';
  end if;
end;
$phase4a2c_default_deny_guard$;

alter table public.phase4a2c_acl_probe_table enable row level security;

create policy phase4a2c_acl_probe_authenticated_select
on public.phase4a2c_acl_probe_table
for select
to authenticated
using (owner_id = (select auth.uid()));

grant select on table public.phase4a2c_acl_probe_table to authenticated;
grant usage, select on sequence public.phase4a2c_acl_probe_sequence to authenticated;
grant execute on function
  public.phase4a2c_acl_probe_invoker(),
  public.phase4a2c_acl_probe_definer()
to authenticated;

do $phase4a2c_explicit_opt_in_guard$
begin
  if not has_table_privilege(
    'authenticated', 'public.phase4a2c_acl_probe_table'::regclass, 'SELECT'
  ) or has_table_privilege(
    'authenticated', 'public.phase4a2c_acl_probe_table'::regclass, 'INSERT'
  ) then
    raise exception 'PHASE4A2C_EXPLICIT_TABLE_GRANT_INVALID';
  end if;

  if not has_sequence_privilege(
    'authenticated', 'public.phase4a2c_acl_probe_sequence'::regclass, 'USAGE'
  ) or not has_sequence_privilege(
    'authenticated', 'public.phase4a2c_acl_probe_sequence'::regclass, 'SELECT'
  ) or has_sequence_privilege(
    'authenticated', 'public.phase4a2c_acl_probe_sequence'::regclass, 'UPDATE'
  ) then
    raise exception 'PHASE4A2C_EXPLICIT_SEQUENCE_GRANT_INVALID';
  end if;

  if not has_function_privilege(
    'authenticated', 'public.phase4a2c_acl_probe_invoker()'::regprocedure, 'EXECUTE'
  ) or not has_function_privilege(
    'authenticated', 'public.phase4a2c_acl_probe_definer()'::regprocedure, 'EXECUTE'
  ) then
    raise exception 'PHASE4A2C_EXPLICIT_ROUTINE_GRANT_INVALID';
  end if;

  if has_table_privilege(
    'anon', 'public.phase4a2c_acl_probe_table'::regclass, 'SELECT'
  ) or has_table_privilege(
    'service_role', 'public.phase4a2c_acl_probe_table'::regclass, 'SELECT'
  ) or has_sequence_privilege(
    'anon', 'public.phase4a2c_acl_probe_sequence'::regclass, 'USAGE'
  ) or has_sequence_privilege(
    'service_role', 'public.phase4a2c_acl_probe_sequence'::regclass, 'USAGE'
  ) or has_function_privilege(
    'anon', 'public.phase4a2c_acl_probe_definer()'::regprocedure, 'EXECUTE'
  ) or has_function_privilege(
    'service_role', 'public.phase4a2c_acl_probe_definer()'::regprocedure, 'EXECUTE'
  ) then
    raise exception 'PHASE4A2C_EXPLICIT_GRANT_SCOPE_WIDENED';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_class relation_row
    where relation_row.oid = 'public.phase4a2c_acl_probe_table'::regclass
      and relation_row.relrowsecurity
  ) or not exists (
    select 1
    from pg_catalog.pg_policy policy_row
    where policy_row.polrelid = 'public.phase4a2c_acl_probe_table'::regclass
      and policy_row.polname = 'phase4a2c_acl_probe_authenticated_select'
      and policy_row.polcmd = 'r'
      and 'authenticated'::regrole = any(policy_row.polroles)
  ) then
    raise exception 'PHASE4A2C_EXPLICIT_RLS_POLICY_INVALID';
  end if;
end;
$phase4a2c_explicit_opt_in_guard$;

rollback;
