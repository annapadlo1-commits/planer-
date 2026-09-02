-- RUN ONLY IN SZAFUNEK UAT PROJECT nhthrtpkfpmufmrmdyjg — DO NOT RUN IN PRODUCTION
-- Phase 4A.2 migration-baseline capture preflight.
-- Every executable statement is a diagnostic SELECT. This file does not repair the ledger.
-- Companion fingerprint serialization: phase4a2-companion-v2.

-- A. SESSION CONTEXT AND PRIVILEGED CAPTURE ROLE
select current_database() as database_name,
       current_user as session_user,
       current_setting('server_version') as postgres_version,
       current_setting('server_version_num') as postgres_version_num,
       current_setting('search_path') as search_path,
       current_setting('quote_all_identifiers') as quote_all_identifiers,
       coalesce((
         select rolsuper or rolbypassrls
         from pg_catalog.pg_roles
         where rolname=current_user
       ),false) as capture_role_bypasses_rls,
       pg_catalog.has_table_privilege(current_user,'cron.job','SELECT') as can_read_cron_inventory,
       pg_catalog.has_table_privilege(current_user,'storage.buckets','SELECT') as can_read_bucket_inventory,
       clock_timestamp() at time zone 'UTC' as checked_at_utc;

-- B. IN-DATABASE UAT IDENTITY CONTROL
select control_key,
       enabled,
       config->>'projectRef' as project_ref,
       config->>'environment' as environment,
       case
         when enabled is true
          and config->>'projectRef'='nhthrtpkfpmufmrmdyjg'
          and config->>'environment'='ISOLATED_UAT'
           then 'UAT_IDENTITY_MATCH'
         else 'STOP — WRONG OR DISABLED DATABASE IDENTITY'
       end as identity_verdict
from public.uat_environment_controls
where control_key='ISOLATED_UAT_DESTRUCTIVE_TOOLS';

-- C. EXACT MIGRATION-LEDGER FINGERPRINT
select snapshot.*,
       case
         when snapshot.ledger_count=254
          and snapshot.ledger_fingerprint='04c5c2ad59937027420bd7c71b782d14'
           then 'LEDGER_MATCH'
         else 'STOP — LEDGER CHANGED, RECAPTURE AND REVIEW'
       end as ledger_verdict
from (
  select count(*)::int as ledger_count,
         md5(string_agg(
           version::text || '|' || name::text || '|' ||
           coalesce(cardinality(statements),0)::text || '|' ||
           octet_length(coalesce(array_to_string(statements,E'\n'),''))::text || '|' ||
           md5(coalesce(array_to_string(statements,E'\n'),'')),
           E'\n' order by version
         )) as ledger_fingerprint
  from supabase_migrations.schema_migrations
) snapshot;

-- D. PROTECTED RECENT CHAIN
select expected.version,
       expected.name,
       exists(
         select 1
         from supabase_migrations.schema_migrations applied
         where applied.version=expected.version and applied.name=expected.name
       ) as exact_row_present
from (values
  ('20260824182754','uat_northflank_job_runtime'),
  ('20260824183338','uat_northflank_job_gateway_regex_fix'),
  ('20260824183525','uat_northflank_job_contract_probe_hash_fix'),
  ('20260824183905','uat_northflank_job_stamp_schema_immutable'),
  ('20260824184140','uat_northflank_job_gate_b_probe'),
  ('20260824190050','uat_northflank_job_outbox_scope_index'),
  ('20260824215911','uat_northflank_job_mode_provenance'),
  ('20260826140255','resource_scoped_manager_authorization'),
  ('20260826201603','employee_workspace_privacy'),
  ('20260826210712','explicit_anonymous_schedule_hardening'),
  ('20260826224321','restore_frontend_rpc_parity'),
  ('20260827160000','phase4a1_scoped_manager_security_hardening')
) expected(version,name)
order by expected.version;

-- E. CURRENT MATRIX INTEGRITY
select count(*) filter(where status='ACTIVE') as active_matrix_count,
       count(*) filter(where status='DRAFT') as draft_matrix_count,
       case when count(*) filter(where status='ACTIVE')=1
         then 'ACTIVE_MATRIX_EXACTLY_ONE'
         else 'STOP — ACTIVE MATRIX INVARIANT FAILED'
       end as matrix_verdict
from public.matrix_versions;

-- F. RLS COVERAGE FOR USER TABLES
select count(*)::int as public_table_count,
       count(*) filter(where c.relrowsecurity)::int as rls_enabled_count,
       count(*) filter(where not c.relrowsecurity)::int as rls_disabled_count
from pg_catalog.pg_class c
join pg_catalog.pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relkind in ('r','p');

-- G. ANONYMOUS SECURITY-DEFINER EXECUTION
select count(*)::int as anon_executable_security_definer_count
from pg_catalog.pg_proc p
join pg_catalog.pg_namespace n on n.oid=p.pronamespace
where p.prosecdef
  and n.nspname not in ('pg_catalog','information_schema')
  and has_function_privilege('anon',p.oid,'EXECUTE');

-- H. MANAGED-SCHEMA POLICIES, INCLUDING ACCESS PREDICATES
select schemaname,
       tablename,
       policyname,
       permissive,
       roles,
       cmd,
       qual as using_expression,
       with_check as with_check_expression
from pg_catalog.pg_policies
where schemaname in ('auth','storage','realtime')
order by schemaname collate "C",tablename collate "C",policyname collate "C";

-- I. RLS POSTURE FOR TABLES COVERED BY MANAGED-SCHEMA POLICIES
select n.nspname as schema_name,
       c.relname as table_name,
       c.relrowsecurity as rls_enabled,
       c.relforcerowsecurity as force_rls
from pg_catalog.pg_class c
join pg_catalog.pg_namespace n on n.oid=c.relnamespace
where (n.nspname,c.relname) in (
  select distinct schemaname,tablename
  from pg_catalog.pg_policies
  where schemaname in ('auth','storage','realtime')
)
order by n.nspname collate "C",c.relname collate "C";

-- J. REALTIME PUBLICATION CONFIGURATION
select p.pubname as publication_name,
       pg_catalog.pg_get_userbyid(p.pubowner) as owner_name,
       p.puballtables as all_tables,
       p.pubinsert as publish_insert,
       p.pubupdate as publish_update,
       p.pubdelete as publish_delete,
       p.pubtruncate as publish_truncate,
       p.pubviaroot as publish_via_root
from pg_catalog.pg_publication p
where p.pubname='supabase_realtime';

-- K. REALTIME DIRECT TABLE MEMBERSHIP, COLUMN LISTS, AND ROW FILTERS
select p.pubname as publication_name,
       n.nspname as schema_name,
       c.relname as table_name,
       pr.prattrs is null as all_columns,
       case when pr.prattrs is null then null else (
         select array_agg(a.attname order by a.attname collate "C")
         from pg_catalog.pg_attribute a
         where a.attrelid=pr.prrelid
           and a.attnum=any(pr.prattrs::smallint[])
       ) end as column_names,
       pg_catalog.pg_get_expr(pr.prqual,pr.prrelid,false) as row_filter
from pg_catalog.pg_publication p
join pg_catalog.pg_publication_rel pr on pr.prpubid=p.oid
join pg_catalog.pg_class c on c.oid=pr.prrelid
join pg_catalog.pg_namespace n on n.oid=c.relnamespace
where p.pubname='supabase_realtime'
order by n.nspname collate "C",c.relname collate "C";

-- L. REALTIME SCHEMA MEMBERSHIP
select p.pubname as publication_name,
       n.nspname as schema_name
from pg_catalog.pg_publication p
join pg_catalog.pg_publication_namespace pn on pn.pnpubid=p.oid
join pg_catalog.pg_namespace n on n.oid=pn.pnnspid
where p.pubname='supabase_realtime'
order by n.nspname collate "C";

-- M. STORAGE BUCKET CONFIGURATION (NO OBJECT OR OWNER DATA)
select id,
       name,
       public,
       file_size_limit,
       allowed_mime_types,
       avif_autodetection,
       type,
       versioning_status
from storage.buckets
order by id collate "C";

-- N. CRON INVENTORY (COMMAND CONTENT IS NOT EXPOSED)
select jobid,
       jobname,
       schedule,
       active,
       database,
       username,
       nodename,
       nodeport,
       md5(command) as command_md5,
       pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(command,'UTF8')),'hex') as command_sha256,
       octet_length(command) as command_bytes
from cron.job
order by jobname collate "C",jobid;

-- O. EXTENSION INVENTORY
select e.extname as name,
       n.nspname as schema_name,
       e.extversion as version,
       e.extrelocatable as relocatable
from pg_catalog.pg_extension e
join pg_catalog.pg_namespace n on n.oid=e.extnamespace
order by e.extname collate "C";

-- P. USER-SCHEMA OWNERSHIP AND ACL INVENTORY
select n.nspname as schema_name,
       pg_catalog.pg_get_userbyid(n.nspowner) as owner_name,
       case when n.nspacl is null then null else (
         select array_agg(a::text order by a::text collate "C")
         from unnest(n.nspacl) a
       ) end as acl_items
from pg_catalog.pg_namespace n
where n.nspname !~ '^pg_'
  and n.nspname not in (
    'information_schema','auth','extensions','graphql','graphql_public',
    'net','pgbouncer','pgmq','realtime','storage','supabase_functions',
    'supabase_migrations','vault'
  )
order by n.nspname collate "C";

-- Q. EVENT-TRIGGER INVENTORY
select e.evtname as name,
       e.evtevent as event,
       e.evtenabled as enabled,
       pg_catalog.pg_get_userbyid(e.evtowner) as owner_name,
       e.evtfoid::regprocedure::text as function_name,
       e.evttags as tags
from pg_catalog.pg_event_trigger e
order by e.evtname collate "C";

-- R. DEFAULT ACL INVENTORY
select pg_catalog.pg_get_userbyid(d.defaclrole) as grantor_name,
       n.nspname as schema_name,
       d.defaclobjtype::text as object_type,
       case when d.defaclacl is null then null else (
         select array_agg(a::text order by a::text collate "C")
         from unnest(d.defaclacl) a
       ) end as acl_items
from pg_catalog.pg_default_acl d
left join pg_catalog.pg_namespace n on n.oid=d.defaclnamespace
order by pg_catalog.pg_get_userbyid(d.defaclrole) collate "C",
         n.nspname collate "C" nulls first,
         d.defaclobjtype::text collate "C";

-- S. FINAL FAIL-CLOSED CAPTURE VERDICT
select companion_snapshot.companion_record_count,
       companion_snapshot.companion_fingerprint,
       case
         when current_user='postgres'
          and current_setting('server_version_num')='170006'
          and current_setting('search_path')=E'"\\$user", public, extensions'
          and current_setting('quote_all_identifiers')='off'
          and coalesce((
            select rolsuper or rolbypassrls
            from pg_catalog.pg_roles
            where rolname=current_user
          ),false)
          and pg_catalog.has_table_privilege(current_user,'cron.job','SELECT')
          and pg_catalog.has_table_privilege(current_user,'storage.buckets','SELECT')
          and (
            select count(*)=1
               and bool_and(
                 enabled is true
                 and config->>'projectRef'='nhthrtpkfpmufmrmdyjg'
                 and config->>'environment'='ISOLATED_UAT'
               )
            from public.uat_environment_controls
            where control_key='ISOLATED_UAT_DESTRUCTIVE_TOOLS'
          )
          and (
            select count(*)=254
               and md5(string_agg(
                 version::text || '|' || name::text || '|' ||
                 coalesce(cardinality(statements),0)::text || '|' ||
                 octet_length(coalesce(array_to_string(statements,E'\n'),''))::text || '|' ||
                 md5(coalesce(array_to_string(statements,E'\n'),'')),
                 E'\n' order by version
               ))='04c5c2ad59937027420bd7c71b782d14'
            from supabase_migrations.schema_migrations
          )
          and (select count(*)=1 from public.matrix_versions where status='ACTIVE')
          and companion_snapshot.companion_record_count=56
          and companion_snapshot.companion_fingerprint='e7f678581129e4f5669c668095e076c9e4e62e10f2fd7c913725cb559e4c074d'
         then 'GO — READ-ONLY SCHEMA CAPTURE ONLY'
         else 'STOP — IDENTITY, LEDGER, MATRIX, OR COMPANION SNAPSHOT CHANGED'
       end as phase4a2_capture_verdict
from (
  with companion_records as (
    select
      'managed_policy'::text as kind,
      p.schemaname || '.' || p.tablename || '.' || p.policyname as object_key,
      concat_ws('|',
        'managed_policy',
        'V' || encode(convert_to(p.schemaname::text,'UTF8'),'hex'),
        'V' || encode(convert_to(p.tablename::text,'UTF8'),'hex'),
        'V' || encode(convert_to(p.policyname::text,'UTF8'),'hex'),
        'V' || encode(convert_to(p.permissive::text,'UTF8'),'hex'),
        case when p.roles is null then 'N' else 'V' || encode(convert_to(coalesce((
          select string_agg(r::text,E'\n' order by r::text collate "C")
          from unnest(p.roles) r
        ),''),'UTF8'),'hex') end,
        'V' || encode(convert_to(p.cmd::text,'UTF8'),'hex'),
        case when p.qual is null then 'N' else 'V' || encode(convert_to(p.qual::text,'UTF8'),'hex') end,
        case when p.with_check is null then 'N' else 'V' || encode(convert_to(p.with_check::text,'UTF8'),'hex') end
      ) as record_text
    from pg_catalog.pg_policies p
    where p.schemaname in ('auth','storage','realtime')

    union all

    select
      'managed_policy_table',
      n.nspname || '.' || c.relname,
      concat_ws('|',
        'managed_policy_table',
        'V' || encode(convert_to(n.nspname::text,'UTF8'),'hex'),
        'V' || encode(convert_to(c.relname::text,'UTF8'),'hex'),
        'V' || encode(convert_to(c.relrowsecurity::text,'UTF8'),'hex'),
        'V' || encode(convert_to(c.relforcerowsecurity::text,'UTF8'),'hex')
      )
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid=c.relnamespace
    where (n.nspname,c.relname) in (
      select distinct schemaname,tablename
      from pg_catalog.pg_policies
      where schemaname in ('auth','storage','realtime')
    )

    union all

    select
      'storage_bucket',
      b.id,
      concat_ws('|',
        'storage_bucket',
        'V' || encode(convert_to(b.id::text,'UTF8'),'hex'),
        'V' || encode(convert_to(b.name::text,'UTF8'),'hex'),
        'V' || encode(convert_to(b.public::text,'UTF8'),'hex'),
        case when b.file_size_limit is null then 'N' else 'V' || encode(convert_to(b.file_size_limit::text,'UTF8'),'hex') end,
        case when b.allowed_mime_types is null then 'N' else 'V' || encode(convert_to(coalesce((
          select string_agg(m::text,E'\n' order by m::text collate "C")
          from unnest(b.allowed_mime_types) m
        ),''),'UTF8'),'hex') end,
        'V' || encode(convert_to(b.avif_autodetection::text,'UTF8'),'hex'),
        case when b.type is null then 'N' else 'V' || encode(convert_to(b.type::text,'UTF8'),'hex') end,
        case when b.versioning_status is null then 'N' else 'V' || encode(convert_to(b.versioning_status::text,'UTF8'),'hex') end
      )
    from storage.buckets b

    union all

    select
      'realtime_publication',
      p.pubname,
      concat_ws('|',
        'realtime_publication',
        'V' || encode(convert_to(p.pubname::text,'UTF8'),'hex'),
        'V' || encode(convert_to(pg_catalog.pg_get_userbyid(p.pubowner)::text,'UTF8'),'hex'),
        'V' || encode(convert_to(p.puballtables::text,'UTF8'),'hex'),
        'V' || encode(convert_to(p.pubinsert::text,'UTF8'),'hex'),
        'V' || encode(convert_to(p.pubupdate::text,'UTF8'),'hex'),
        'V' || encode(convert_to(p.pubdelete::text,'UTF8'),'hex'),
        'V' || encode(convert_to(p.pubtruncate::text,'UTF8'),'hex'),
        'V' || encode(convert_to(p.pubviaroot::text,'UTF8'),'hex')
      )
    from pg_catalog.pg_publication p
    where p.pubname='supabase_realtime'

    union all

    select
      'realtime_publication_member',
      p.pubname || '.' || n.nspname || '.' || c.relname,
      concat_ws('|',
        'realtime_publication_member',
        'V' || encode(convert_to(p.pubname::text,'UTF8'),'hex'),
        'V' || encode(convert_to(n.nspname::text,'UTF8'),'hex'),
        'V' || encode(convert_to(c.relname::text,'UTF8'),'hex'),
        'V' || encode(convert_to((pr.prattrs is null)::text,'UTF8'),'hex'),
        case when pr.prattrs is null then 'N' else 'V' || encode(convert_to(coalesce((
          select string_agg(a.attname,E'\n' order by a.attname collate "C")
          from pg_catalog.pg_attribute a
          where a.attrelid=pr.prrelid
            and a.attnum=any(pr.prattrs::smallint[])
        ),''),'UTF8'),'hex') end,
        case when pr.prqual is null then 'N' else 'V' || encode(convert_to(
          pg_catalog.pg_get_expr(pr.prqual,pr.prrelid,false),'UTF8'
        ),'hex') end
      )
    from pg_catalog.pg_publication p
    join pg_catalog.pg_publication_rel pr on pr.prpubid=p.oid
    join pg_catalog.pg_class c on c.oid=pr.prrelid
    join pg_catalog.pg_namespace n on n.oid=c.relnamespace
    where p.pubname='supabase_realtime'

    union all

    select
      'realtime_publication_schema',
      p.pubname || '.' || n.nspname,
      concat_ws('|',
        'realtime_publication_schema',
        'V' || encode(convert_to(p.pubname::text,'UTF8'),'hex'),
        'V' || encode(convert_to(n.nspname::text,'UTF8'),'hex')
      )
    from pg_catalog.pg_publication p
    join pg_catalog.pg_publication_namespace pn on pn.pnpubid=p.oid
    join pg_catalog.pg_namespace n on n.oid=pn.pnnspid
    where p.pubname='supabase_realtime'

    union all

    select
      'event_trigger',
      e.evtname,
      concat_ws('|',
        'event_trigger',
        'V' || encode(convert_to(e.evtname::text,'UTF8'),'hex'),
        'V' || encode(convert_to(e.evtevent::text,'UTF8'),'hex'),
        'V' || encode(convert_to(e.evtenabled::text,'UTF8'),'hex'),
        'V' || encode(convert_to(pg_catalog.pg_get_userbyid(e.evtowner)::text,'UTF8'),'hex'),
        'V' || encode(convert_to(e.evtfoid::regprocedure::text,'UTF8'),'hex'),
        case when e.evttags is null then 'N' else 'V' || encode(convert_to(coalesce((
          select string_agg(t::text,E'\n' order by t::text collate "C")
          from unnest(e.evttags) t
        ),''),'UTF8'),'hex') end
      )
    from pg_catalog.pg_event_trigger e

    union all

    select
      'cron_job',
      coalesce(j.jobname,'#' || j.jobid::text),
      concat_ws('|',
        'cron_job',
        case when j.jobname is null then 'N' else 'V' || encode(convert_to(j.jobname::text,'UTF8'),'hex') end,
        'V' || encode(convert_to(j.schedule::text,'UTF8'),'hex'),
        'V' || encode(convert_to(j.active::text,'UTF8'),'hex'),
        'V' || encode(convert_to(j.database::text,'UTF8'),'hex'),
        'V' || encode(convert_to(j.username::text,'UTF8'),'hex'),
        'V' || encode(convert_to(j.nodename::text,'UTF8'),'hex'),
        'V' || encode(convert_to(j.nodeport::text,'UTF8'),'hex'),
        'V' || encode(convert_to(
          pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(j.command,'UTF8')),'hex'),
          'UTF8'
        ),'hex'),
        'V' || encode(convert_to(octet_length(j.command)::text,'UTF8'),'hex')
      )
    from cron.job j

    union all

    select
      'extension',
      e.extname,
      concat_ws('|',
        'extension',
        'V' || encode(convert_to(e.extname::text,'UTF8'),'hex'),
        'V' || encode(convert_to(n.nspname::text,'UTF8'),'hex'),
        'V' || encode(convert_to(e.extversion::text,'UTF8'),'hex'),
        'V' || encode(convert_to(e.extrelocatable::text,'UTF8'),'hex')
      )
    from pg_catalog.pg_extension e
    join pg_catalog.pg_namespace n on n.oid=e.extnamespace

    union all

    select
      'user_schema',
      n.nspname,
      concat_ws('|',
        'user_schema',
        'V' || encode(convert_to(n.nspname::text,'UTF8'),'hex'),
        'V' || encode(convert_to(pg_catalog.pg_get_userbyid(n.nspowner)::text,'UTF8'),'hex'),
        case when n.nspacl is null then 'N' else 'V' || encode(convert_to(coalesce((
          select string_agg(a::text,E'\n' order by a::text collate "C")
          from unnest(n.nspacl) a
        ),''),'UTF8'),'hex') end
      )
    from pg_catalog.pg_namespace n
    where n.nspname !~ '^pg_'
      and n.nspname not in (
        'information_schema','auth','extensions','graphql','graphql_public',
        'net','pgbouncer','pgmq','realtime','storage','supabase_functions',
        'supabase_migrations','vault'
      )

    union all

    select
      'default_acl',
      pg_catalog.pg_get_userbyid(d.defaclrole) || '.' ||
        coalesce(n.nspname,'') || '.' || d.defaclobjtype::text,
      concat_ws('|',
        'default_acl',
        'V' || encode(convert_to(pg_catalog.pg_get_userbyid(d.defaclrole)::text,'UTF8'),'hex'),
        case when n.nspname is null then 'N' else 'V' || encode(convert_to(n.nspname::text,'UTF8'),'hex') end,
        'V' || encode(convert_to(d.defaclobjtype::text,'UTF8'),'hex'),
        case when d.defaclacl is null then 'N' else 'V' || encode(convert_to(coalesce((
          select string_agg(a::text,E'\n' order by a::text collate "C")
          from unnest(d.defaclacl) a
        ),''),'UTF8'),'hex') end
      )
    from pg_catalog.pg_default_acl d
    left join pg_catalog.pg_namespace n on n.oid=d.defaclnamespace
  )
  select count(*)::int as companion_record_count,
         pg_catalog.encode(
           pg_catalog.sha256(pg_catalog.convert_to(
             string_agg(
               record_text,E'\n'
               order by kind collate "C",object_key collate "C",record_text collate "C"
             ),
             'UTF8'
           )),
           'hex'
         ) as companion_fingerprint
  from companion_records
) companion_snapshot;
