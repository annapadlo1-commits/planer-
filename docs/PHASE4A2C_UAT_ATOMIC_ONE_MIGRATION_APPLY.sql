-- Phase 4A.2C existing-UAT atomic one-migration runner.
-- MUTATING: execute only after reviewed source is merged and the user gives
-- separate explicit authorization. Execute this complete file in one
-- Supabase MCP execute_sql call. Do not use db push or apply_migration.

begin;
set transaction isolation level repeatable read;
set local statement_timeout = '30s';
set local lock_timeout = '5s';

-- Acquire the ledger table lock before the first snapshot-taking SELECT.
-- Under REPEATABLE READ this ensures a concurrent ledger writer that commits
-- while we wait is included in every subsequent fingerprint.
lock table supabase_migrations.schema_migrations
  in share row exclusive mode;

select pg_catalog.pg_advisory_xact_lock(
  pg_catalog.hashtextextended('phase4a2c_uat_atomic_apply', 0)
);

do $apply$
declare
  v_pre_fingerprint text;
  v_post_fingerprint text;
  v_default_acl_count integer;
  v_default_acl_payload text;
  v_security_count integer;
  v_security_payload text;
  v_sql text;
  v_statements constant text[] := array[
    'alter default privileges for role "postgres" revoke all on functions from public, "anon", "authenticated", "service_role"',
    'alter default privileges for role "postgres" revoke all on tables from public, "anon", "authenticated", "service_role"',
    'alter default privileges for role "postgres" revoke all on sequences from public, "anon", "authenticated", "service_role"',
    'alter default privileges for role "postgres" in schema "public" revoke all on functions from public, "postgres", "anon", "authenticated", "service_role"',
    'alter default privileges for role "postgres" in schema "public" revoke all on tables from public, "postgres", "anon", "authenticated", "service_role"',
    'alter default privileges for role "postgres" in schema "public" revoke all on sequences from public, "postgres", "anon", "authenticated", "service_role"'
  ]::text[];
begin
  if current_user is distinct from 'postgres' then
    raise exception 'PHASE4A2C_APPLY_CREATOR_INVALID:%', current_user;
  end if;

  if (
    select count(*) = 1 and bool_and(
      enabled is true
      and config->>'projectRef' = 'nhthrtpkfpmufmrmdyjg'
      and config->>'environment' = 'ISOLATED_UAT'
    )
    from public.uat_environment_controls
    where control_key = 'ISOLATED_UAT_DESTRUCTIVE_TOOLS'
  ) is not true then
    raise exception 'PHASE4A2C_APPLY_IDENTITY_INVALID';
  end if;

  select md5(string_agg(
    version || '|' || name || '|' || coalesce(cardinality(statements), 0)::text ||
    '|' || octet_length(coalesce(array_to_string(statements, E'\n'), ''))::text ||
    '|' || md5(coalesce(array_to_string(statements, E'\n'), '')),
    E'\n' order by version
  )) into v_pre_fingerprint
  from supabase_migrations.schema_migrations;

  if (select count(*) from supabase_migrations.schema_migrations) <> 254
    or v_pre_fingerprint <> '04c5c2ad59937027420bd7c71b782d14'
    or exists (
      select 1 from supabase_migrations.schema_migrations
      where version = '20260830180000'
         or name = 'phase4a2c_default_privileges_hardening'
    )
  then
    raise exception 'PHASE4A2C_APPLY_PRE_LEDGER_INVALID:%', v_pre_fingerprint;
  end if;

  -- Revalidate every pinned pre-migration state in this same REPEATABLE READ
  -- transaction immediately before the first reviewed ALTER statement.
  if (select count(*) from public.matrix_versions where status = 'ACTIVE') <> 1
    or not exists (
      select 1 from public.matrix_versions
      where status = 'ACTIVE'
        and workforce_count = 86
        and content_hash =
          '32dac23aea267e87c037a47dd796f06da03f9ab17e01da94c21603b301681187'
        and workforce_hash =
          '0d64a87e0e96a3f77852f4234d12881c294b3dca8a555ae78644e10ff050b9a2'
    )
  then
    raise exception 'PHASE4A2C_APPLY_MATRIX_INVALID';
  end if;

  select count(*), string_agg(
    format('%s|%s|%s|%s', r.schema_name, r.grantor_name, r.object_type, r.acl_items),
    E'\n' order by r.schema_name collate "C", r.grantor_name collate "C",
                     r.object_type collate "C"
  ) into v_default_acl_count, v_default_acl_payload
  from (
    select coalesce(n.nspname, '') schema_name,
           pg_catalog.pg_get_userbyid(d.defaclrole) grantor_name,
           d.defaclobjtype::text object_type,
           coalesce((
             select string_agg(a::text, ',' order by a::text collate "C")
             from unnest(d.defaclacl) a
           ), '') acl_items
    from pg_catalog.pg_default_acl d
    left join pg_catalog.pg_namespace n on n.oid = d.defaclnamespace
    where n.nspname is distinct from 'supabase_functions'
       or pg_catalog.pg_get_userbyid(d.defaclrole) is distinct from 'supabase_admin'
  ) r;

  if v_default_acl_count <> 29
    or octet_length(v_default_acl_payload) <> 3005
    or pg_catalog.encode(
      pg_catalog.sha256(pg_catalog.convert_to(v_default_acl_payload, 'UTF8')), 'hex'
    ) <> 'c86785623e746bdaf24fabcb75b2a6019385b230830284d851ec27ad030933a3'
  then
    raise exception 'PHASE4A2C_APPLY_DEFAULT_ACL_INVALID:%', v_default_acl_count;
  end if;

  with records as (
    select 'relation_acl|' || n.nspname || '|' || c.relname || '|' ||
           c.relkind::text || '|' ||
           case when x.grantor = 0 then 'PUBLIC'
                else pg_catalog.pg_get_userbyid(x.grantor) end || '|' ||
           case when x.grantee = 0 then 'PUBLIC'
                else pg_catalog.pg_get_userbyid(x.grantee) end || '|' ||
           x.privilege_type || '|' || x.is_grantable::text as record
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    cross join lateral pg_catalog.aclexplode(coalesce(
      c.relacl, pg_catalog.acldefault(
        case when c.relkind = 'S' then 'S'::"char" else 'r'::"char" end,
        c.relowner
      )
    )) x
    where n.nspname = 'public' and c.relkind in ('r','p','v','m','S')
    union all
    select 'routine_acl|' || n.nspname || '|' || p.proname || '|' ||
           pg_catalog.pg_get_function_identity_arguments(p.oid) || '|' ||
           case when x.grantor = 0 then 'PUBLIC'
                else pg_catalog.pg_get_userbyid(x.grantor) end || '|' ||
           case when x.grantee = 0 then 'PUBLIC'
                else pg_catalog.pg_get_userbyid(x.grantee) end || '|' ||
           x.privilege_type || '|' || x.is_grantable::text
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    cross join lateral pg_catalog.aclexplode(coalesce(
      p.proacl, pg_catalog.acldefault('f', p.proowner)
    )) x
    where n.nspname = 'public'
    union all
    select 'rls|' || n.nspname || '|' || c.relname || '|' ||
           c.relrowsecurity::text || '|' || c.relforcerowsecurity::text
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r','p')
    union all
    select 'policy|' || schemaname || '|' || tablename || '|' || policyname ||
           '|' || permissive || '|' || coalesce(array_to_string(roles, ','), '') ||
           '|' || cmd || '|' || coalesce(qual, '<null>') || '|' ||
           coalesce(with_check, '<null>')
    from pg_catalog.pg_policies
    where schemaname = 'public'
  )
  select count(*)::int, string_agg(record, E'\n' order by record collate "C")
  into v_security_count, v_security_payload
  from records;

  if v_security_count <> 3623
    or octet_length(v_security_payload) <> 367503
    or pg_catalog.encode(
      pg_catalog.sha256(pg_catalog.convert_to(v_security_payload, 'UTF8')), 'hex'
    ) <> '9ea69a5ac1f4d89a7463aa2e2b8efe64e7bd87f753319e43e7e3c6b735071637'
  then
    raise exception 'PHASE4A2C_APPLY_EXISTING_SECURITY_INVALID:%', v_security_count;
  end if;

  if to_regclass('public.phase4a2c_uat_probe_table') is not null
    or to_regclass('public.phase4a2c_uat_probe_sequence') is not null
    or to_regprocedure('public.phase4a2c_uat_probe_invoker()') is not null
    or to_regprocedure('public.phase4a2c_uat_probe_definer()') is not null
  then
    raise exception 'PHASE4A2C_APPLY_PROBE_RESIDUE_PREEXISTS';
  end if;

  if cardinality(v_statements) <> 6
    or octet_length(array_to_string(v_statements, E'\n')) <> 818
    or md5(array_to_string(v_statements, E'\n')) <>
      'c3550dc2c665d7349a4919e314f7a356'
  then
    raise exception 'PHASE4A2C_APPLY_PAYLOAD_INVALID';
  end if;

  foreach v_sql in array v_statements loop
    execute v_sql;
  end loop;

  insert into supabase_migrations.schema_migrations(version, name, statements)
  values (
    '20260830180000',
    'phase4a2c_default_privileges_hardening',
    v_statements
  );

  select md5(string_agg(
    version || '|' || name || '|' || coalesce(cardinality(statements), 0)::text ||
    '|' || octet_length(coalesce(array_to_string(statements, E'\n'), ''))::text ||
    '|' || md5(coalesce(array_to_string(statements, E'\n'), '')),
    E'\n' order by version
  )) into v_post_fingerprint
  from supabase_migrations.schema_migrations;

  if (select count(*) from supabase_migrations.schema_migrations) <> 255
    or v_post_fingerprint <> '9996f95dfb7d936194efcf4e6fc59214'
  then
    raise exception 'PHASE4A2C_APPLY_POST_LEDGER_INVALID:%', v_post_fingerprint;
  end if;
end;
$apply$;

commit;
