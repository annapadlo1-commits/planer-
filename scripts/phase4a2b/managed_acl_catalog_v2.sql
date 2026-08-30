-- Phase 4A.2B managed ACL catalog v2.
-- SELECT-only canonical inventory; explicit text casts prevent PostgreSQL name
-- (63-byte) coercion from truncating function identities across UNION branches.
with acl_record as (
  select
    'schema'::text as object_kind,
    namespace_row.nspname::text as schema_name,
    namespace_row.nspname::text as object_identity,
    ''::text as object_subkind,
    pg_get_userbyid(namespace_row.nspowner)::text as owner_name,
    coalesce((
      select string_agg(
        acl_item::text, ',' order by acl_item::text collate "C"
      )
      from unnest(namespace_row.nspacl) acl_item
    ), ''::text) as acl_items
  from pg_catalog.pg_namespace namespace_row
  where namespace_row.nspname in ('cron', 'public')
    and namespace_row.nspacl is not null

  union all

  select
    'function'::text,
    namespace_row.nspname::text,
    format(
      '%I.%I(%s)',
      namespace_row.nspname,
      procedure_row.proname,
      pg_get_function_identity_arguments(procedure_row.oid)
    )::text,
    procedure_row.prokind::text,
    pg_get_userbyid(procedure_row.proowner)::text,
    coalesce((
      select string_agg(
        acl_item::text, ',' order by acl_item::text collate "C"
      )
      from unnest(procedure_row.proacl) acl_item
    ), ''::text)
  from pg_catalog.pg_proc procedure_row
  join pg_catalog.pg_namespace namespace_row
    on namespace_row.oid = procedure_row.pronamespace
  where namespace_row.nspname in ('cron', 'extensions', 'vault')
    and procedure_row.proacl is not null

  union all

  select
    'relation'::text,
    namespace_row.nspname::text,
    format('%I.%I', namespace_row.nspname, relation_row.relname)::text,
    relation_row.relkind::text,
    pg_get_userbyid(relation_row.relowner)::text,
    coalesce((
      select string_agg(
        acl_item::text, ',' order by acl_item::text collate "C"
      )
      from unnest(relation_row.relacl) acl_item
    ), ''::text)
  from pg_catalog.pg_class relation_row
  join pg_catalog.pg_namespace namespace_row
    on namespace_row.oid = relation_row.relnamespace
  where namespace_row.nspname in ('cron', 'extensions', 'vault')
    and relation_row.relacl is not null
),
catalog as (
  select format(
    '%s|%s|%s|%s|%s|%s',
    object_kind,
    schema_name,
    object_identity,
    object_subkind,
    owner_name,
    acl_items
  )::text as canonical_line
  from acl_record
),
payload as (
  select
    count(*)::bigint as record_count,
    string_agg(canonical_line, E'\n' order by canonical_line collate "C")::text
      as canonical_payload
  from catalog
)
select jsonb_build_object(
  'serialization', 'phase4a2b-managed-acl-v2',
  'record_count', record_count,
  'canonical_bytes', octet_length(canonical_payload),
  'canonical_sha256', encode(
    pg_catalog.sha256(pg_catalog.convert_to(canonical_payload, 'UTF8')),
    'hex'
  ),
  'canonical_lines', string_to_array(canonical_payload, E'\n')
)::text
from payload;
