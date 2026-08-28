-- RUN ONLY IN SZAFUNEK UAT PROJECT nhthrtpkfpmufmrmdyjg — DO NOT RUN IN PRODUCTION
-- Phase 4A.2 migration-baseline capture preflight.
-- Every executable statement is a diagnostic SELECT. This file does not repair the ledger.

-- A. SESSION CONTEXT
select current_database() as database_name,
       current_user as session_user,
       current_setting('server_version') as postgres_version,
       clock_timestamp() at time zone 'UTC' as checked_at_utc;

-- B. IN-DATABASE UAT IDENTITY CONTROL
select control_key,
       enabled,
       config->>'projectRef' as project_ref,
       config->>'environment' as environment,
       case
         when config->>'projectRef'='nhthrtpkfpmufmrmdyjg'
          and config->>'environment'='ISOLATED_UAT'
           then 'UAT_IDENTITY_MATCH'
         else 'STOP — WRONG DATABASE IDENTITY'
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

-- H. OBJECTS EXCLUDED FROM THE DEFAULT SUPABASE MANAGED-SCHEMA DUMP
select schemaname,
       tablename,
       policyname,
       roles,
       cmd
from pg_catalog.pg_policies
where schemaname in ('auth','storage','realtime')
order by schemaname,tablename,policyname;

-- I. REALTIME PUBLICATION MEMBERS
select p.pubname as publication_name,
       n.nspname as schema_name,
       c.relname as table_name
from pg_catalog.pg_publication p
join pg_catalog.pg_publication_rel pr on pr.prpubid=p.oid
join pg_catalog.pg_class c on c.oid=pr.prrelid
join pg_catalog.pg_namespace n on n.oid=c.relnamespace
order by p.pubname,n.nspname,c.relname;

-- J. STORAGE BUCKET CONFIGURATION (NO OBJECT DATA)
select id,
       name,
       public,
       file_size_limit,
       allowed_mime_types
from storage.buckets
order by id;

-- K. CRON INVENTORY (COMMAND CONTENT IS NOT EXPOSED)
select jobid,
       jobname,
       schedule,
       md5(command) as command_md5,
       octet_length(command) as command_bytes,
       active
from cron.job
order by jobid;

-- L. FINAL FAIL-CLOSED CAPTURE VERDICT
select case
  when (
    select config->>'projectRef'='nhthrtpkfpmufmrmdyjg'
       and config->>'environment'='ISOLATED_UAT'
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
  then 'GO — READ-ONLY SCHEMA CAPTURE ONLY'
  else 'STOP — IDENTITY, LEDGER, OR MATRIX STATE CHANGED'
end as phase4a2_capture_verdict;
