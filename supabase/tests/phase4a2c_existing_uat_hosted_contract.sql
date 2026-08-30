begin;

set local statement_timeout = '30s';
set local lock_timeout = '5s';
set local row_security = on;

do $identity$
declare
  v_ledger_count integer;
begin
  if current_user is distinct from 'postgres' then
    raise exception 'PHASE4A2C_UAT_CREATOR_INVALID:%', current_user;
  end if;

  if not exists (
    select 1 from public.uat_environment_controls
    where control_key = 'ISOLATED_UAT_DESTRUCTIVE_TOOLS'
      and enabled is true
      and config->>'projectRef' = 'nhthrtpkfpmufmrmdyjg'
      and config->>'environment' = 'ISOLATED_UAT'
  ) then
    raise exception 'PHASE4A2C_UAT_IDENTITY_INVALID';
  end if;

  select count(*) into v_ledger_count
  from supabase_migrations.schema_migrations;

  if v_ledger_count <> 255 or (
    select count(*) from supabase_migrations.schema_migrations
    where version = '20260830180000'
      and name = 'phase4a2c_default_privileges_hardening'
  ) <> 1 then
    raise exception 'PHASE4A2C_UAT_LEDGER_INVALID:%', v_ledger_count;
  end if;

  if (select count(*) from public.matrix_versions where status = 'ACTIVE') <> 1
    or not exists (
      select 1 from public.matrix_versions
      where status = 'ACTIVE'
        and workforce_count = 86
        and content_hash = '32dac23aea267e87c037a47dd796f06da03f9ab17e01da94c21603b301681187'
        and workforce_hash = '0d64a87e0e96a3f77852f4234d12881c294b3dca8a555ae78644e10ff050b9a2'
    )
  then
    raise exception 'PHASE4A2C_UAT_MATRIX_CHANGED';
  end if;

  if to_regclass('public.phase4a2c_uat_probe_table') is not null
    or to_regclass('public.phase4a2c_uat_probe_sequence') is not null
    or to_regprocedure('public.phase4a2c_uat_probe_invoker()') is not null
    or to_regprocedure('public.phase4a2c_uat_probe_definer()') is not null
  then
    raise exception 'PHASE4A2C_UAT_PROBE_RESIDUE_PREEXISTS';
  end if;
end;
$identity$;

do $catalog$
declare
  v_count integer;
  v_payload text;
begin
  if (select array(
    select a::text from pg_catalog.pg_default_acl d2
    cross join lateral unnest(d2.defaclacl) a
    where d2.defaclrole = 'postgres'::regrole
      and d2.defaclnamespace = 0 and d2.defaclobjtype = 'f'
    order by a::text collate "C"
  )) is distinct from array['postgres=X/postgres']::text[] then
    raise exception 'PHASE4A2C_UAT_GLOBAL_ROUTINE_ACL_INVALID';
  end if;

  if exists (
    select 1 from pg_catalog.pg_default_acl d
    left join pg_catalog.pg_namespace n on n.oid = d.defaclnamespace
    where d.defaclrole = 'postgres'::regrole
      and ((d.defaclnamespace = 0 and d.defaclobjtype in ('r','S'))
        or (n.nspname = 'public' and d.defaclobjtype in ('f','r','S')))
  ) then
    raise exception 'PHASE4A2C_UAT_DEFAULT_ACL_NOT_HARDENED';
  end if;

  select count(*), string_agg(
    format('%s|%s|%s|%s', r.schema_name, r.grantor_name, r.object_type, r.acl_items),
    E'\n' order by r.schema_name collate "C", r.grantor_name collate "C",
                     r.object_type collate "C"
  ) into v_count, v_payload
  from (
    select coalesce(n.nspname, '') schema_name,
           pg_catalog.pg_get_userbyid(d.defaclrole) grantor_name,
           d.defaclobjtype::text object_type,
           coalesce((select string_agg(a::text, ',' order by a::text collate "C")
                     from unnest(d.defaclacl) a), '') acl_items
    from pg_catalog.pg_default_acl d
    left join pg_catalog.pg_namespace n on n.oid = d.defaclnamespace
    where n.nspname is distinct from 'supabase_functions'
       or pg_catalog.pg_get_userbyid(d.defaclrole) is distinct from 'supabase_admin'
  ) r;

  if v_count <> 27 or octet_length(v_payload) <> 2708
    or encode(pg_catalog.sha256(pg_catalog.convert_to(v_payload, 'UTF8')), 'hex') <>
      '1f690d52941e6a5865cb59919ded58fa087f2e594215836bd33a78a1141ae9ff'
  then
    raise exception 'PHASE4A2C_UAT_DEFAULT_ACL_FINGERPRINT_INVALID:%', v_count;
  end if;
end;
$catalog$;

create table public.phase4a2c_uat_probe_table (id bigint primary key);
create sequence public.phase4a2c_uat_probe_sequence;
create function public.phase4a2c_uat_probe_invoker() returns integer
language sql immutable security invoker set search_path = '' as 'select 1';
create function public.phase4a2c_uat_probe_definer() returns integer
language sql stable security definer set search_path = '' as 'select 1';

do $canaries$
declare
  v_role text;
begin
  foreach v_role in array array['anon','authenticated','service_role']::text[] loop
    if has_table_privilege(v_role, 'public.phase4a2c_uat_probe_table', 'SELECT')
      or has_sequence_privilege(v_role, 'public.phase4a2c_uat_probe_sequence', 'USAGE')
      or has_function_privilege(v_role, 'public.phase4a2c_uat_probe_invoker()', 'EXECUTE')
      or has_function_privilege(v_role, 'public.phase4a2c_uat_probe_definer()', 'EXECUTE')
    then
      raise exception 'PHASE4A2C_UAT_DEFAULT_DENY_FAILED:%', v_role;
    end if;
  end loop;

  if not has_table_privilege('postgres', 'public.phase4a2c_uat_probe_table', 'SELECT')
    or not has_sequence_privilege('postgres', 'public.phase4a2c_uat_probe_sequence', 'USAGE')
    or not has_function_privilege('postgres', 'public.phase4a2c_uat_probe_definer()', 'EXECUTE')
  then
    raise exception 'PHASE4A2C_UAT_OWNER_RIGHTS_MISSING';
  end if;

  if exists (
    select 1 from pg_catalog.pg_proc
    where oid = 'public.phase4a2c_uat_probe_definer()'::regprocedure
      and (not prosecdef or proowner <> 'postgres'::regrole
        or proconfig is distinct from array['search_path=""']::text[])
  ) then
    raise exception 'PHASE4A2C_UAT_DEFINER_CANARY_INVALID';
  end if;
end;
$canaries$;

rollback;

