-- RUN ONLY IN SZAFUNEK UAT PROJECT — DO NOT RUN IN PRODUCTION
-- Phase 4A.1 manual preflight. Every executable statement is diagnostic SELECT.

-- A. IDENTITY / SAFE CONTEXT (operator must independently confirm UAT)
select current_database() as database_name, current_user as session_user,
       current_setting('server_version') as postgres_version,
       current_setting('server_version_num') as postgres_version_number;

-- B. MIGRATION LEDGER
select version,name from supabase_migrations.schema_migrations
order by version desc limit 30;
select expected.version,
       exists(select 1 from supabase_migrations.schema_migrations m
              where m.version=expected.version) as applied
from (values ('20260826140255'),('20260826201603'),('20260826210712'),
             ('20260826224321'),('20260827160000')) expected(version)
order by expected.version;
select version,name from supabase_migrations.schema_migrations
where version>'20260826210712' order by version;

-- C. RLS ENABLEMENT
select c.relname as table_name,c.relrowsecurity as rls_enabled,
       c.relforcerowsecurity as force_rls
from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname=any(array[
  'assignments','plans','shifts','employee_availability',
  'employee_availability_history','operational_events','employees',
  'employee_locations','employee_capabilities','attendance_events','plan_issues',
  'employer_cost_components_v2','recovery_incident_rate_revisions_v2',
  'matrix_role_categories_v2']) order by c.relname;

-- D. FULL POLICY INVENTORY
select tablename,policyname,permissive,roles,cmd,qual as using_expression,
       with_check as check_expression
from pg_catalog.pg_policies where schemaname='public' and tablename=any(array[
  'assignments','plans','shifts','employee_availability',
  'employee_availability_history','operational_events','employees',
  'employee_locations','employee_capabilities','attendance_events','plan_issues',
  'employer_cost_components_v2','recovery_incident_rate_revisions_v2',
  'matrix_role_categories_v2']) order by tablename,policyname;

-- E. EFFECTIVE TABLE PRIVILEGES
select target.role_name,target.table_name,
       has_table_privilege(target.role_name,'public.'||target.table_name,'SELECT') as can_select,
       has_table_privilege(target.role_name,'public.'||target.table_name,'INSERT') as can_insert,
       has_table_privilege(target.role_name,'public.'||target.table_name,'UPDATE') as can_update,
       has_table_privilege(target.role_name,'public.'||target.table_name,'DELETE') as can_delete
from (select r.role_name,t.table_name from unnest(array['anon','authenticated']) r(role_name)
      cross join unnest(array['assignments','plans','shifts','employee_availability',
      'employee_availability_history','operational_events','employees','employee_locations',
      'employee_capabilities','attendance_events','plan_issues','employer_cost_components_v2',
      'recovery_incident_rate_revisions_v2','matrix_role_categories_v2']) t(table_name)) target
order by target.table_name,target.role_name;

-- F. FUNCTION PARITY
select p.oid::regprocedure::text as signature,owner.rolname as owner,
       p.prosecdef as security_definer,p.proconfig,p.proacl,
       has_function_privilege('anon',p.oid,'EXECUTE') as anon_execute,
       has_function_privilege('authenticated',p.oid,'EXECUTE') as authenticated_execute,
       has_function_privilege('service_role',p.oid,'EXECUTE') as service_role_execute,
       md5(pg_catalog.pg_get_functiondef(p.oid)) as definition_md5
from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
join pg_catalog.pg_roles owner on owner.oid=p.proowner
where n.nspname='public' and p.proname=any(array[
  'has_app_role','can_manage_plans','matrix_v2_can_manage_resource_uat_v1'])
order by signature;

-- G. OWNER BASELINE: recent trusted SECURITY DEFINER helpers
select p.oid::regprocedure::text as signature,owner.rolname as owner,p.proconfig,p.proacl
from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
join pg_catalog.pg_roles owner on owner.oid=p.proowner
where n.nspname in ('public','authorization_private') and p.prosecdef
  and (p.proname like 'matrix_v2_%' or p.proname in ('has_app_role','can_manage_plans'))
order by n.nspname,p.proname,p.oid::regprocedure::text;

-- H. ACTIVE MATRIX INTEGRITY
select count(*) as active_matrix_count from public.matrix_versions where status='ACTIVE';
select 'ROLE_CODE' as ambiguity,upper(code) as key,count(*) as match_count
from public.matrix_roles_v2 r where r.active and exists
 (select 1 from public.matrix_versions v where v.id=r.matrix_version_id and v.status='ACTIVE')
group by upper(code) having count(*)>1
union all
select 'LOCATION_CODE',upper(code),count(*) from public.matrix_locations_v2 l where l.active and exists
 (select 1 from public.matrix_versions v where v.id=l.matrix_version_id and v.status='ACTIVE')
group by upper(code) having count(*)>1;
select resource_type,logical_id,count(*) as match_count from (
  select 'ROLE'::text resource_type,r.logical_id from public.matrix_roles_v2 r join public.matrix_versions v on v.id=r.matrix_version_id where r.active and v.status='ACTIVE'
  union all select 'LOCATION',l.logical_id from public.matrix_locations_v2 l join public.matrix_versions v on v.id=l.matrix_version_id where l.active and v.status='ACTIVE') resources
group by resource_type,logical_id having count(*)>1;

-- I. LEGACY -> MATRIX LOCATION MAPPING (IDs/codes only; no personal data)
select used.legacy_id,legacy.code as legacy_code,count(ml.id) as match_count,
       case count(ml.id) when 0 then 'ZERO' when 1 then 'EXACTLY_ONE' else 'MULTIPLE' end as classification
from (select location_id legacy_id from public.shifts union
      select location_id from public.operational_events union
      select location_id from public.employee_locations) used
join public.locations legacy on legacy.id=used.legacy_id
left join public.matrix_versions mv on mv.status='ACTIVE'
left join public.matrix_locations_v2 ml on ml.matrix_version_id=mv.id and ml.active
 and upper(ml.code::text)=upper(legacy.code::text)
group by used.legacy_id,legacy.code order by legacy.code;

-- J. LEGACY -> MATRIX ROLE MAPPING
select used.role_code,count(mr.id) as match_count,
       case count(mr.id) when 0 then 'ZERO' when 1 then 'EXACTLY_ONE' else 'MULTIPLE' end as classification
from (select assigned_role::text role_code from public.assignments union
      select role::text from public.plan_issues where role is not null) used
left join public.matrix_versions mv on mv.status='ACTIVE'
left join public.matrix_roles_v2 mr on mr.matrix_version_id=mv.id and mr.active
 and upper(mr.code)=upper(used.role_code)
group by used.role_code order by used.role_code;

-- K. SCOPE GRANT INTEGRITY (aggregate-only)
select
 count(*) filter(where active and app_role='ROLE_MANAGER' and role_logical_id is null) as role_manager_null_scope,
 count(*) filter(where active and app_role='LOCATION_MANAGER' and location_logical_id is null) as location_manager_null_scope,
 count(*) filter(where not active) as inactive_grants,
 count(*) filter(where active and app_role='ROLE_MANAGER' and role_logical_id is not null and not exists
   (select 1 from public.matrix_roles_v2 r join public.matrix_versions v on v.id=r.matrix_version_id
    where r.logical_id=matrix_scope_grants_v2.role_logical_id and r.active and v.status='ACTIVE')) as stale_role_targets,
 count(*) filter(where active and app_role='LOCATION_MANAGER' and location_logical_id is not null and not exists
   (select 1 from public.matrix_locations_v2 l join public.matrix_versions v on v.id=l.matrix_version_id
    where l.logical_id=matrix_scope_grants_v2.location_logical_id and l.active and v.status='ACTIVE')) as stale_location_targets
from public.matrix_scope_grants_v2;
select count(*) as duplicate_grant_groups from (
 select auth_user_id,app_role,role_logical_id,location_logical_id,duty_logical_id
 from public.matrix_scope_grants_v2 where active
 group by auth_user_id,app_role,role_logical_id,location_logical_id,duty_logical_id having count(*)>1) duplicate_groups;

-- L. SCHEMA COMPATIBILITY
select expected.table_name,expected.column_name,expected.expected_type,
       (c.column_name is not null) as present,c.data_type as live_type,
       (c.column_name is not null and (expected.expected_type='ANY' or c.data_type=expected.expected_type)) as compatible
from (values
 ('matrix_versions','id','uuid'),('matrix_versions','status','text'),
 ('matrix_roles_v2','matrix_version_id','uuid'),('matrix_roles_v2','id','uuid'),('matrix_roles_v2','code','text'),('matrix_roles_v2','active','boolean'),
 ('matrix_locations_v2','matrix_version_id','uuid'),('matrix_locations_v2','id','uuid'),('matrix_locations_v2','code','text'),('matrix_locations_v2','active','boolean'),
 ('locations','id','uuid'),('locations','code','ANY'),('assignments','assigned_role','ANY'),('assignments','employee_id','uuid'),('assignments','shift_id','uuid'),
 ('shifts','location_id','uuid'),('operational_events','location_id','uuid'),('employee_availability','employee_id','uuid'))
 expected(table_name,column_name,expected_type)
left join information_schema.columns c on c.table_schema='public' and c.table_name=expected.table_name and c.column_name=expected.column_name
order by expected.table_name,expected.column_name;
select expected.signature,to_regprocedure(expected.signature) is not null as present
from (values ('public.matrix_v2_can_manage_resource_uat_v1(uuid,uuid,uuid)'),
             ('public.has_app_role(app_role)'),('public.can_manage_plans()')) expected(signature);

-- M. BUSINESS ROW COUNTS
select 'assignments' table_name,count(*) row_count from public.assignments union all
select 'employee_availability',count(*) from public.employee_availability union all
select 'employee_availability_history',count(*) from public.employee_availability_history union all
select 'operational_events',count(*) from public.operational_events union all
select 'employees',count(*) from public.employees union all
select 'employee_locations',count(*) from public.employee_locations union all
select 'employee_capabilities',count(*) from public.employee_capabilities union all
select 'attendance_events',count(*) from public.attendance_events union all
select 'plan_issues',count(*) from public.plan_issues union all
select 'employer_cost_components_v2',count(*) from public.employer_cost_components_v2 union all
select 'recovery_incident_rate_revisions_v2',count(*) from public.recovery_incident_rate_revisions_v2;

-- N. BULK-ADJUST INFORMATION ONLY (metadata; function is never invoked)
select p.oid::regprocedure::text as signature,p.proacl,
       has_function_privilege('anon',p.oid,'EXECUTE') as anon_execute,
       has_function_privilege('authenticated',p.oid,'EXECUTE') as authenticated_execute
from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='matrix_v2_staffing_bulk_adjust_uat_v2';
