-- Phase 4A.2C existing-UAT preflight. SELECT-only and fail-closed.

with identity_gate as (
  select count(*) = 1
     and bool_and(enabled is true)
     and bool_and(config->>'projectRef' = 'nhthrtpkfpmufmrmdyjg')
     and bool_and(config->>'environment' = 'ISOLATED_UAT') as ok
  from public.uat_environment_controls
  where control_key = 'ISOLATED_UAT_DESTRUCTIVE_TOOLS'
), ledger_gate as (
  select count(*) = 254
     and md5(string_agg(
       version::text || '|' || name::text || '|' ||
       coalesce(cardinality(statements), 0)::text || '|' ||
       octet_length(coalesce(array_to_string(statements, E'\n'), ''))::text || '|' ||
       md5(coalesce(array_to_string(statements, E'\n'), '')),
       E'\n' order by version
     )) = '04c5c2ad59937027420bd7c71b782d14'
     and count(*) filter (
       where version = '20260830180000'
          or name = 'phase4a2c_default_privileges_hardening'
     ) = 0 as ok
  from supabase_migrations.schema_migrations
), matrix_gate as (
  select count(*) = 1
     and bool_and(workforce_count = 86)
     and bool_and(content_hash =
       '32dac23aea267e87c037a47dd796f06da03f9ab17e01da94c21603b301681187')
     and bool_and(workforce_hash =
       '0d64a87e0e96a3f77852f4234d12881c294b3dca8a555ae78644e10ff050b9a2') as ok
  from public.matrix_versions
  where status = 'ACTIVE'
), acl_rows as (
  select coalesce(n.nspname, '') as schema_name,
         pg_catalog.pg_get_userbyid(d.defaclrole) as grantor_name,
         d.defaclobjtype::text as object_type,
         coalesce((
           select string_agg(a::text, ',' order by a::text collate "C")
           from unnest(d.defaclacl) a
         ), '') as acl_items
  from pg_catalog.pg_default_acl d
  left join pg_catalog.pg_namespace n on n.oid = d.defaclnamespace
  where n.nspname is distinct from 'supabase_functions'
     or pg_catalog.pg_get_userbyid(d.defaclrole) is distinct from 'supabase_admin'
), acl_gate as (
  select count(*) = 29
     and octet_length(string_agg(
       format('%s|%s|%s|%s', schema_name, grantor_name, object_type, acl_items),
       E'\n' order by schema_name collate "C", grantor_name collate "C",
                        object_type collate "C"
     )) = 3005
     and encode(pg_catalog.sha256(pg_catalog.convert_to(string_agg(
       format('%s|%s|%s|%s', schema_name, grantor_name, object_type, acl_items),
       E'\n' order by schema_name collate "C", grantor_name collate "C",
                        object_type collate "C"
     ), 'UTF8')), 'hex') =
       'c86785623e746bdaf24fabcb75b2a6019385b230830284d851ec27ad030933a3' as ok
  from acl_rows
), residue_gate as (
  select not exists (
    select 1 from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname like 'phase4a2c_uat_probe_%'
  ) and not exists (
    select 1 from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'phase4a2c_uat_probe_%'
  ) as ok
)
select case
  when current_user = 'postgres'
   and (select ok from identity_gate)
   and (select ok from ledger_gate)
   and (select ok from matrix_gate)
   and (select ok from acl_gate)
   and (select ok from residue_gate)
  then 'GO — PHASE4A2C UAT PREFLIGHT'
  else 'STOP — PHASE4A2C UAT STATE CHANGED'
end as phase4a2c_uat_preflight_verdict;

