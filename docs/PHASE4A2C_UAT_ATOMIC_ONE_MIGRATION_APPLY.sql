-- Phase 4A.2C existing-UAT atomic one-migration runner.
-- MUTATING: execute only after reviewed source is merged and the user gives
-- separate explicit authorization. Execute this complete file in one
-- Supabase MCP execute_sql call. Do not use db push or apply_migration.

begin;
set local statement_timeout = '30s';
set local lock_timeout = '5s';

select pg_catalog.pg_advisory_xact_lock(
  pg_catalog.hashtextextended('phase4a2c_uat_atomic_apply', 0)
);

lock table supabase_migrations.schema_migrations
  in share row exclusive mode;

do $apply$
declare
  v_pre_fingerprint text;
  v_post_fingerprint text;
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
