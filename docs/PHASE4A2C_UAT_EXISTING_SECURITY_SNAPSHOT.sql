-- Canonical read-only snapshot of existing public object ACL, RLS and policies.
-- Run immediately before and after Phase 4A.2C. Exact equality is required.

with records as (
  select 'relation_acl|' || n.nspname || '|' || c.relname || '|' ||
         c.relkind::text || '|' ||
         case when x.grantee = 0 then 'PUBLIC'
              else pg_catalog.pg_get_userbyid(x.grantee) end || '|' ||
         x.privilege_type || '|' || x.is_grantable::text as record
  from pg_catalog.pg_class c
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  cross join lateral pg_catalog.aclexplode(coalesce(
    c.relacl,
    pg_catalog.acldefault(
      case when c.relkind = 'S' then 'S'::"char" else 'r'::"char" end,
      c.relowner
    )
  )) x
  where n.nspname = 'public' and c.relkind in ('r','p','v','m','S')

  union all

  select 'routine_acl|' || n.nspname || '|' || p.proname || '|' ||
         pg_catalog.pg_get_function_identity_arguments(p.oid) || '|' ||
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
), payload as (
  select count(*)::int as record_count,
         string_agg(record, E'\n' order by record collate "C") as value
  from records
)
select record_count,
       octet_length(value) as serialized_bytes,
       pg_catalog.encode(
         pg_catalog.sha256(pg_catalog.convert_to(value, 'UTF8')), 'hex'
       ) as sha256,
       case
         when record_count = 3623
          and octet_length(value) = 337074
          and pg_catalog.encode(
            pg_catalog.sha256(pg_catalog.convert_to(value, 'UTF8')), 'hex'
          ) = '5166ef241ec5b86a22eeb72c4ee62bca8d5da66efdae6fecbc1c9c1883e10185'
         then 'MATCH — EXISTING SECURITY STATE UNCHANGED'
         else 'STOP — EXISTING ACL, RLS, OR POLICY STATE CHANGED'
       end as verdict
from payload;
