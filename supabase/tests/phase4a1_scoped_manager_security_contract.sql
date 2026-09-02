-- Phase 4A.1: effective RLS/ACL contract for TECH-AUD-020/023/024-write/025.
-- TECH-AUD-026 legacy operational-event read remains intentionally deferred.
-- Run after all migrations. Every fixture and assertion is rolled back.

begin;

do $$
declare v_policy record;v_definition text;
begin
  if has_function_privilege('anon',
    'public.matrix_v2_can_manage_legacy_resource_uat_v1(text,uuid,uuid)','execute')
  then raise exception 'PHASE4A_LEGACY_SCOPE_HELPER_EXPOSED_TO_ANON'; end if;

  for v_policy in
    select * from pg_policies
    where schemaname='public' and policyname=any(array[
      'employee_reads_own_assignments','availability_read','availability_manage',
      'authenticated_reads_plans','employee_reads_published_shifts','availability_history_read',
      'managers_manage_events','employee_reads_self',
      'authenticated_reads_employee_locations','authenticated_reads_employee_capabilities',
      'employee_reads_own_attendance','plan_issues_read',
      'employer_cost_components_read_v2','incident_rates_read_v2',
      'matrix_role_categories_v2_select'
    ])
  loop
    if v_policy.roles<>array['authenticated']::name[] then
      raise exception 'PHASE4A_POLICY_ROLE_INVALID:%.%',v_policy.tablename,v_policy.policyname;
    end if;
  end loop;

  if exists(
    select 1 from pg_policies
    where schemaname='public'
      and policyname=any(array[
        'employee_reads_own_assignments','availability_read','availability_manage',
        'authenticated_reads_plans','employee_reads_published_shifts','availability_history_read',
        'managers_manage_events','employee_reads_self',
        'authenticated_reads_employee_locations','authenticated_reads_employee_capabilities',
        'employee_reads_own_attendance','plan_issues_read'
      ])
      and coalesce(qual,'')||coalesce(with_check,'')
        ~ 'has_app_role\(''(ROLE_MANAGER|LOCATION_MANAGER)'''
  ) then raise exception 'PHASE4A_RAW_MANAGER_POLICY_PREDICATE_REMAINS'; end if;

  if exists(
    select 1 from pg_policies
    where schemaname='public'
      and tablename in ('employer_cost_components_v2','recovery_incident_rate_revisions_v2')
      and coalesce(qual,'') ~ '(ROLE_MANAGER|LOCATION_MANAGER)'
  ) then raise exception 'PHASE4A_MANAGER_DIRECT_FINANCE_READ_REMAINS'; end if;

  v_definition:=pg_get_functiondef(
    'public.matrix_v2_can_manage_legacy_resource_uat_v1(text,uuid,uuid)'::regprocedure
  );
  if v_definition !~ 'count\(\*\).*array_agg\(matrix.id\)'
    or regexp_count(v_definition,'v_match_count\s*<>\s*1') < 3
  then raise exception 'PHASE4A_ZERO_OR_MULTIPLE_ACTIVE_MATRIX_GUARD_MISSING'; end if;
  if v_definition !~ 'count\(\*\).*array_agg\(role.id\)' then
    raise exception 'PHASE4A_ZERO_OR_MULTIPLE_ROLE_MAPPING_GUARD_MISSING'; end if;
  if v_definition !~ 'count\(\*\).*array_agg\(matrix_location.id\)' then
    raise exception 'PHASE4A_ZERO_OR_MULTIPLE_LOCATION_MAPPING_GUARD_MISSING'; end if;
  if v_definition ~* 'order by.*matrix.version|limit 1' then
    raise exception 'PHASE4A_AMBIGUOUS_MAPPING_SELECTS_FIRST';
  end if;
  if has_function_privilege('service_role',
    'public.matrix_v2_can_manage_legacy_resource_uat_v1(text,uuid,uuid)','execute')
  then raise exception 'PHASE4A_LEGACY_SCOPE_HELPER_EXPOSED_TO_SERVICE_ROLE'; end if;

  for v_definition in
    select pg_get_functiondef(helper.oid)
    from unnest(array[
      'public.matrix_v2_can_manage_legacy_assignment_uat_v1(uuid)'::regprocedure,
      'public.matrix_v2_can_manage_legacy_plan_issue_uat_v1(uuid)'::regprocedure
    ]) helper(oid)
  loop
    if v_definition !~* 'security definer' or v_definition !~* 'search_path'
      or v_definition !~ 'matrix_v2_can_manage_legacy_resource_uat_v1'
    then raise exception 'PHASE4A_TRUSTED_ROW_HELPER_CONTRACT_INVALID'; end if;
  end loop;
  if has_function_privilege('anon',
      'public.matrix_v2_can_manage_legacy_assignment_uat_v1(uuid)','execute')
    or has_function_privilege('service_role',
      'public.matrix_v2_can_manage_legacy_assignment_uat_v1(uuid)','execute')
    or not has_function_privilege('authenticated',
      'public.matrix_v2_can_manage_legacy_assignment_uat_v1(uuid)','execute')
    or has_function_privilege('anon',
      'public.matrix_v2_can_manage_legacy_plan_issue_uat_v1(uuid)','execute')
    or has_function_privilege('service_role',
      'public.matrix_v2_can_manage_legacy_plan_issue_uat_v1(uuid)','execute')
    or not has_function_privilege('authenticated',
      'public.matrix_v2_can_manage_legacy_plan_issue_uat_v1(uuid)','execute')
  then raise exception 'PHASE4A_TRUSTED_ROW_HELPER_ACL_INVALID'; end if;
end;
$$;

-- ZERO resource mappings deny. Seeded KELNER/location A checks below prove
-- EXACTLY ONE. The catalog guards above prove MORE THAN ONE uses the same
-- fail-closed <> 1 branch even where uniqueness constraints prevent fixtures.
set local role authenticated;
select set_config('request.jwt.claim.sub','f4a10000-0000-4000-8000-000000000003',true);
do $$ begin
  if public.matrix_v2_can_manage_legacy_resource_uat_v1('NO_SUCH_ROLE',null,null) then
    raise exception 'PHASE4A_ZERO_ROLE_MAPPING_ALLOWED'; end if;
  if public.matrix_v2_can_manage_legacy_resource_uat_v1(
    null,'ffffffff-ffff-4fff-8fff-ffffffffffff',null) then
    raise exception 'PHASE4A_ZERO_LOCATION_MAPPING_ALLOWED'; end if;
end $$;
reset role;

-- Real application roles used by the RLS matrix.
insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,is_super_admin,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',email,'',now(),
  '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,false,now(),now()
from (values
  ('f4a10000-0000-4000-8000-000000000001'::uuid,'phase4a-owner@example.invalid'),
  ('f4a10000-0000-4000-8000-000000000002'::uuid,'phase4a-admin@example.invalid'),
  ('f4a10000-0000-4000-8000-000000000003'::uuid,'phase4a-role-x@example.invalid'),
  ('f4a10000-0000-4000-8000-000000000004'::uuid,'phase4a-role-y@example.invalid'),
  ('f4a10000-0000-4000-8000-000000000005'::uuid,'phase4a-location-a@example.invalid'),
  ('f4a10000-0000-4000-8000-000000000006'::uuid,'phase4a-location-b@example.invalid'),
  ('f4a10000-0000-4000-8000-000000000007'::uuid,'phase4a-employee-a@example.invalid'),
  ('f4a10000-0000-4000-8000-000000000008'::uuid,'phase4a-employee-b@example.invalid'),
  ('f4a10000-0000-4000-8000-000000000009'::uuid,'phase4a-no-role@example.invalid')
) fixture(id,email);

insert into public.user_permissions(auth_user_id,app_role) values
  ('f4a10000-0000-4000-8000-000000000001','OWNER'),
  ('f4a10000-0000-4000-8000-000000000002','ADMIN'),
  ('f4a10000-0000-4000-8000-000000000003','ROLE_MANAGER'),
  ('f4a10000-0000-4000-8000-000000000004','ROLE_MANAGER'),
  ('f4a10000-0000-4000-8000-000000000005','LOCATION_MANAGER'),
  ('f4a10000-0000-4000-8000-000000000006','LOCATION_MANAGER'),
  ('f4a10000-0000-4000-8000-000000000007','EMPLOYEE'),
  ('f4a10000-0000-4000-8000-000000000008','EMPLOYEE');

insert into public.employees(id,auth_user_id,employee_no,first_name,last_name,primary_role,
  monthly_nominal_minutes,max_weekly_minutes,active) values
  ('f4a11000-0000-4000-8000-000000000001','f4a10000-0000-4000-8000-000000000007','P4A-A','Phase4A','Employee A','KELNER',9600,2400,true),
  ('f4a11000-0000-4000-8000-000000000002','f4a10000-0000-4000-8000-000000000008','P4A-B','Phase4A','Employee B','BARMAN',9600,2400,true),
  ('f4a11000-0000-4000-8000-000000000003',null,'P4A-N','Phase4A','Unrelated','PREP',9600,2400,true),
  ('f4a11000-0000-4000-8000-000000000004',null,'P4A-I','Phase4A','Inactive','POMOC',9600,2400,false);

do $$
declare v_version integer;v_settings jsonb;
begin
  select coalesce(max(version),0)+1 into v_version from public.matrix_versions;
  -- A schema-only restore has no prior ACTIVE Matrix. Keep this rollback-local
  -- fixture independent of business data with the complete safe-first-run
  -- settings shape. Existing ACTIVE values are applied last and therefore win.
  select jsonb_build_object(
      'currency','PLN',
      'timezone','Europe/Warsaw',
      'minimumRestMinutes',660,
      'maximumShiftsPerDay',1,
      'missingAvailabilityMeansAvailable',true,
      'requireOptimal',false,
      'maxShiftsPerDay',1,
      'standbyTiersPerRoleDay',2
    ) || coalesce((
      select settings from public.matrix_versions
      where status='ACTIVE' order by version desc limit 1
    ),'{}'::jsonb)
    into v_settings;
  insert into public.matrix_versions(id,version,name,status,effective_from,settings,schema_version,
    activated_at,published_at) values(
      'f4a12000-0000-4000-8000-000000000001',v_version,'Phase 4A contract','DRAFT',
      current_date,v_settings,2,null,null);
end;
$$;

insert into public.matrix_roles_v2(id,matrix_version_id,logical_id,code,name,color,active) values
  ('f4a13000-0000-4000-8000-000000000001','f4a12000-0000-4000-8000-000000000001','f4a13100-0000-4000-8000-000000000001','KELNER','Role X','#111111',true),
  ('f4a13000-0000-4000-8000-000000000002','f4a12000-0000-4000-8000-000000000001','f4a13100-0000-4000-8000-000000000002','BARMAN','Role Y','#222222',true),
  ('f4a13000-0000-4000-8000-000000000003'::uuid,
   'f4a12000-0000-4000-8000-000000000001'::uuid,
   'f4a13100-0000-4000-8000-000000000003'::uuid,
   'PREP'::text,'Unrelated role'::text,'#333333'::text,true);

-- Supply rollback-local legacy rows when the environment has no legacy
-- locations. Existing rows win by their unique code and are never updated.
insert into public.locations(id,code,name,timezone,active) values
  ('f4a14500-0000-4000-8000-000000000001'::uuid,
   'KRUCZA'::public.location_code,'Krucza'::text,'Europe/Warsaw'::text,true),
  ('f4a14500-0000-4000-8000-000000000002'::uuid,
   'PAWILONY'::public.location_code,'Pawilony'::text,'Europe/Warsaw'::text,true)
on conflict(code) do nothing;

do $$
begin
  if not exists(select 1 from public.locations where code='KRUCZA')
    or not exists(select 1 from public.locations where code='PAWILONY')
  then raise exception 'PHASE4A_LEGACY_LOCATION_FIXTURE_MISSING'; end if;
end;
$$;

insert into public.matrix_locations_v2(id,matrix_version_id,logical_id,code,name,timezone,active) values
  ('f4a14000-0000-4000-8000-000000000001'::uuid,
   'f4a12000-0000-4000-8000-000000000001'::uuid,
   'f4a14100-0000-4000-8000-000000000001'::uuid,
   'KRUCZA'::text,'Location A'::text,'Europe/Warsaw'::text,true),
  ('f4a14000-0000-4000-8000-000000000002'::uuid,
   'f4a12000-0000-4000-8000-000000000001'::uuid,
   'f4a14100-0000-4000-8000-000000000002'::uuid,
   'PAWILONY'::text,'Location B'::text,'Europe/Warsaw'::text,true),
  ('f4a14000-0000-4000-8000-000000000003'::uuid,
   'f4a12000-0000-4000-8000-000000000001'::uuid,
   'f4a14100-0000-4000-8000-000000000003'::uuid,
   'ISOLATED'::text,'Unrelated location'::text,'Europe/Warsaw'::text,true);

-- Versioned role/location membership requires one profile in the same Matrix
-- for every employee fixture, including unrelated and inactive employees.
insert into public.matrix_employee_profiles_v2(
  matrix_version_id,employee_id,employee_no,first_name,last_name,email,active,
  employment_start,employment_end,nominal_monthly_minutes,
  maximum_monthly_minutes,maximum_weekly_minutes,maximum_consecutive_days,
  minimum_rest_minutes,only_morning,only_evening,no_weekends,
  preferred_shift_code,archived_at
) values
  ('f4a12000-0000-4000-8000-000000000001'::uuid,
   'f4a11000-0000-4000-8000-000000000001'::uuid,
   'P4A-A'::text,'Phase4A'::text,'Employee A'::text,null::text,true,
   null::date,null::date,9600::integer,9600::integer,2400::integer,6::integer,
   null::integer,false,false,false,null::text,null::timestamptz),
  ('f4a12000-0000-4000-8000-000000000001'::uuid,
   'f4a11000-0000-4000-8000-000000000002'::uuid,
   'P4A-B'::text,'Phase4A'::text,'Employee B'::text,null::text,true,
   null::date,null::date,9600::integer,9600::integer,2400::integer,6::integer,
   null::integer,false,false,false,null::text,null::timestamptz),
  ('f4a12000-0000-4000-8000-000000000001'::uuid,
   'f4a11000-0000-4000-8000-000000000003'::uuid,
   'P4A-N'::text,'Phase4A'::text,'Unrelated'::text,null::text,true,
   null::date,null::date,9600::integer,9600::integer,2400::integer,6::integer,
   null::integer,false,false,false,null::text,null::timestamptz),
  ('f4a12000-0000-4000-8000-000000000001'::uuid,
   'f4a11000-0000-4000-8000-000000000004'::uuid,
   'P4A-I'::text,'Phase4A'::text,'Inactive'::text,null::text,false,
   null::date,null::date,9600::integer,9600::integer,2400::integer,6::integer,
   null::integer,false,false,false,null::text,now()::timestamptz);

insert into public.matrix_employee_roles_v2(matrix_version_id,employee_id,role_id,is_primary,can_lead,active) values
  ('f4a12000-0000-4000-8000-000000000001','f4a11000-0000-4000-8000-000000000001','f4a13000-0000-4000-8000-000000000001',true,false,true),
  ('f4a12000-0000-4000-8000-000000000001','f4a11000-0000-4000-8000-000000000002','f4a13000-0000-4000-8000-000000000002',true,false,true),
  ('f4a12000-0000-4000-8000-000000000001'::uuid,
   'f4a11000-0000-4000-8000-000000000003'::uuid,
   'f4a13000-0000-4000-8000-000000000003'::uuid,true,false,true);
insert into public.matrix_employee_locations_v2(
  matrix_version_id,employee_id,location_id,
  standard_allowed,overtime_allowed,home_location,active
) values
  ('f4a12000-0000-4000-8000-000000000001','f4a11000-0000-4000-8000-000000000001','f4a14000-0000-4000-8000-000000000001',true,false,true,true),
  ('f4a12000-0000-4000-8000-000000000001','f4a11000-0000-4000-8000-000000000001','f4a14000-0000-4000-8000-000000000002',true,false,false,true),
  ('f4a12000-0000-4000-8000-000000000001','f4a11000-0000-4000-8000-000000000002','f4a14000-0000-4000-8000-000000000002',true,false,true,true),
  ('f4a12000-0000-4000-8000-000000000001'::uuid,
   'f4a11000-0000-4000-8000-000000000003'::uuid,
   'f4a14000-0000-4000-8000-000000000003'::uuid,true,false,true,true);

select solver_private.matrix_v2_seed_required_defaults_uat_v1(
  'f4a12000-0000-4000-8000-000000000001'
);
update public.matrix_versions set status='ARCHIVED',
  effective_to=greatest(effective_from,current_date-1) where status='ACTIVE';
update public.matrix_versions set status='ACTIVE',activated_at=now(),published_at=now()
where id='f4a12000-0000-4000-8000-000000000001';

insert into public.matrix_scope_grants_v2(auth_user_id,app_role,role_logical_id,active,created_by) values
  ('f4a10000-0000-4000-8000-000000000003','ROLE_MANAGER','f4a13100-0000-4000-8000-000000000001',true,'f4a10000-0000-4000-8000-000000000001'),
  ('f4a10000-0000-4000-8000-000000000004','ROLE_MANAGER','f4a13100-0000-4000-8000-000000000002',true,'f4a10000-0000-4000-8000-000000000001'),
  ('f4a10000-0000-4000-8000-000000000003','ROLE_MANAGER','f4a13100-0000-4000-8000-000000000002',false,'f4a10000-0000-4000-8000-000000000001');
insert into public.matrix_scope_grants_v2(auth_user_id,app_role,location_logical_id,active,created_by) values
  ('f4a10000-0000-4000-8000-000000000005','LOCATION_MANAGER','f4a14100-0000-4000-8000-000000000001',true,'f4a10000-0000-4000-8000-000000000001'),
  ('f4a10000-0000-4000-8000-000000000006','LOCATION_MANAGER','f4a14100-0000-4000-8000-000000000002',true,'f4a10000-0000-4000-8000-000000000001'),
  ('f4a10000-0000-4000-8000-000000000005','LOCATION_MANAGER','f4a14100-0000-4000-8000-000000000002',false,'f4a10000-0000-4000-8000-000000000001');

do $$ begin
  if exists(
    select 1 from public.matrix_scope_grants_v2
    where active and (
      role_logical_id='f4a13100-0000-4000-8000-000000000003'::uuid
      or location_logical_id='f4a14100-0000-4000-8000-000000000003'::uuid
    )
  ) then raise exception 'PHASE4A_UNRELATED_RESOURCE_SCOPE_GRANTED'; end if;
end $$;

insert into public.employee_availability(id,employee_id,work_date,available,note) values
  ('f4a15000-0000-4000-8000-000000000001','f4a11000-0000-4000-8000-000000000001',current_date,true,'A'),
  ('f4a15000-0000-4000-8000-000000000002','f4a11000-0000-4000-8000-000000000002',current_date,true,'B'),
  ('f4a15000-0000-4000-8000-000000000003','f4a11000-0000-4000-8000-000000000003',current_date,true,'N');

set local session_replication_role=replica;
insert into public.plans(id,month,name,scenario_code,optimization_mode,staffing_level,status,version,
  generated_at,published_at) values
  (
  'f4a16000-0000-4000-8000-000000000001'::uuid,date_trunc('month',current_date)::date,
  'Phase 4A published plan'::text,'PHASE4A'::text,'BALANCED'::text,'AUDIT'::text,
  'PUBLISHED'::public.plan_status,1::integer,now()::timestamptz,now()::timestamptz),
  (
  'f4a16000-0000-4000-8000-000000000002'::uuid,date_trunc('month',current_date)::date,
  'Phase 4A draft plan'::text,'PHASE4A_DRAFT'::text,'BALANCED'::text,'AUDIT'::text,
  'DRAFT'::public.plan_status,1::integer,now()::timestamptz,null::timestamptz);
set local session_replication_role=origin;
insert into public.shifts(id,plan_id,location_id,shift_date,shift_code,starts_at,ends_at,status)
select 'f4a16100-0000-4000-8000-000000000001'::uuid,
  'f4a16000-0000-4000-8000-000000000001'::uuid,
  id,current_date,'P4A_A'::text,(current_date+time '08:00')::timestamptz,
  (current_date+time '16:00')::timestamptz,'PLANNED'::text
from public.locations where code='KRUCZA'
union all
select 'f4a16100-0000-4000-8000-000000000002'::uuid,
  'f4a16000-0000-4000-8000-000000000001'::uuid,
  id,current_date,'P4A_B'::text,(current_date+time '16:00')::timestamptz,
  (current_date+time '23:00')::timestamptz,'PLANNED'::text
from public.locations where code='PAWILONY'
union all
select 'f4a16100-0000-4000-8000-000000000003'::uuid,
  'f4a16000-0000-4000-8000-000000000002'::uuid,
  id,current_date,'P4A_DRAFT_B'::text,(current_date+time '09:00')::timestamptz,
  (current_date+time '15:00')::timestamptz,'PLANNED'::text
from public.locations where code='PAWILONY';
insert into public.assignments(id,shift_id,employee_id,assigned_role,assignment_type) values
  ('f4a16200-0000-4000-8000-000000000001','f4a16100-0000-4000-8000-000000000001','f4a11000-0000-4000-8000-000000000001','KELNER','STANDARD'),
  ('f4a16200-0000-4000-8000-000000000002','f4a16100-0000-4000-8000-000000000002','f4a11000-0000-4000-8000-000000000002','BARMAN','STANDARD'),
  ('f4a16200-0000-4000-8000-000000000003','f4a16100-0000-4000-8000-000000000003','f4a11000-0000-4000-8000-000000000001','KELNER','STANDARD');
insert into public.plan_issues(id,plan_id,shift_id,issue_type,severity,role,message) values
  ('f4a16400-0000-4000-8000-000000000001','f4a16000-0000-4000-8000-000000000002',
   'f4a16100-0000-4000-8000-000000000003','SHORTAGE','WARNING','KELNER','Phase 4A draft issue B');
insert into public.operational_events(id,location_id,event_type,title,starts_at,ends_at,status)
select 'f4a16300-0000-4000-8000-000000000001'::uuid,id,'EVENT'::text,
  'Phase 4A event A'::text,(current_date+time '10:00')::timestamptz,
  (current_date+time '11:00')::timestamptz,'DRAFT'::public.event_status
from public.locations where code='KRUCZA'
union all
select 'f4a16300-0000-4000-8000-000000000002'::uuid,id,'EVENT'::text,
  'Phase 4A event B'::text,(current_date+time '12:00')::timestamptz,
  (current_date+time '13:00')::timestamptz,'DRAFT'::public.event_status
from public.locations where code='PAWILONY';

-- Verify the canonical helper matrix, including inactive grants, null/invalid
-- resources and employee self-vs-other. Direct table policy assertions below
-- use the same actor identities.
select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;

select set_config('request.jwt.claim.sub','f4a10000-0000-4000-8000-000000000003',true);
do $$ begin
  if not public.matrix_v2_can_manage_legacy_resource_uat_v1('KELNER',
      (select id from public.locations where code='KRUCZA'),
      'f4a11000-0000-4000-8000-000000000001')
    or public.matrix_v2_can_manage_legacy_resource_uat_v1('BARMAN',
      (select id from public.locations where code='PAWILONY'),
      'f4a11000-0000-4000-8000-000000000002')
    or public.matrix_v2_can_manage_legacy_resource_uat_v1('INVALID',null,null)
    or public.matrix_v2_can_manage_legacy_resource_uat_v1(null,null,
      'f4a11000-0000-4000-8000-000000000004')
  then raise exception 'PHASE4A_ROLE_X_BOUNDARY_INVALID'; end if;
  if (select count(*) from public.employee_availability)<>1 then
    raise exception 'PHASE4A_ROLE_X_AVAILABILITY_READ_LEAK'; end if;
  if (select count(*) from public.assignments)<>2 then
    raise exception 'PHASE4A_ROLE_X_ASSIGNMENT_READ_LEAK'; end if;
  update public.employee_availability set note='ROLE X'
    where employee_id='f4a11000-0000-4000-8000-000000000001';
  if found is false then raise exception 'PHASE4A_ROLE_X_LEGAL_WRITE_DENIED'; end if;
  update public.employee_availability set note='LEAK'
    where employee_id='f4a11000-0000-4000-8000-000000000002';
  if found then raise exception 'PHASE4A_ROLE_X_CROSS_WRITE_ALLOWED'; end if;
end $$;

-- ZERO active Matrix must deny. The normal one-ACTIVE path is proven above.
reset role;
do $$
begin
  begin
    update public.matrix_versions set status='ARCHIVED',
      effective_to=greatest(effective_from,current_date-1)
    where id='f4a12000-0000-4000-8000-000000000001';

    if public.matrix_v2_can_manage_legacy_resource_uat_v1('KELNER',null,null) then
      raise exception using
        errcode='P4A11',message='PHASE4A_ZERO_ACTIVE_MATRIX_ALLOWED';
    end if;

    -- The expected sentinel rolls back this inner subtransaction, including
    -- ACTIVE -> ARCHIVED, without an illegal ARCHIVED -> ACTIVE transition.
    raise exception using
      errcode='P4A10',message='PHASE4A_ZERO_ACTIVE_MATRIX_ROLLBACK';
  exception when sqlstate 'P4A10' then
    null;
  end;

  if not exists(
    select 1 from public.matrix_versions
    where id='f4a12000-0000-4000-8000-000000000001' and status='ACTIVE'
  ) then
    raise exception using
      errcode='P4A12',message='PHASE4A_ACTIVE_MATRIX_NOT_RESTORED';
  end if;
end;
$$;
set local role authenticated;

select set_config('request.jwt.claim.sub','f4a10000-0000-4000-8000-000000000005',true);
do $$ begin
  if (select count(*) from public.employee_availability)<>1 then
    raise exception 'PHASE4A_LOCATION_A_AVAILABILITY_READ_LEAK'; end if;
  if (select count(*) from public.assignments)<>1 then
    raise exception 'PHASE4A_LOCATION_A_ASSIGNMENT_READ_LEAK'; end if;
  if exists(select 1 from public.assignments
      where id='f4a16200-0000-4000-8000-000000000003')
    or exists(select 1 from public.plan_issues
      where id='f4a16400-0000-4000-8000-000000000001')
  then raise exception 'PHASE4A_LOCATION_A_DRAFT_SHIFT_LOCATION_LEAK'; end if;
  if exists(select 1 from public.shifts
      where id='f4a16100-0000-4000-8000-000000000003')
  then raise exception 'PHASE4A_LOCATION_A_DRAFT_SHIFT_VISIBLE'; end if;
  update public.operational_events set title='Phase 4A event A updated'
    where id='f4a16300-0000-4000-8000-000000000001';
  if not found then raise exception 'PHASE4A_LOCATION_A_EVENT_WRITE_DENIED'; end if;
  update public.operational_events set title='LEAK'
    where id='f4a16300-0000-4000-8000-000000000002';
  if found then raise exception 'PHASE4A_LOCATION_A_CROSS_EVENT_WRITE_ALLOWED'; end if;
end $$;

select set_config('request.jwt.claim.sub','f4a10000-0000-4000-8000-000000000004',true);
do $$ begin
  if (select count(*) from public.assignments)<>1
    or (select count(*) from public.employee_availability)<>1 then
    raise exception 'PHASE4A_ROLE_Y_BOUNDARY_INVALID'; end if;
end $$;

select set_config('request.jwt.claim.sub','f4a10000-0000-4000-8000-000000000006',true);
do $$ begin
  if (select count(*) from public.assignments)<>2
    or not exists(select 1 from public.assignments
      where id='f4a16200-0000-4000-8000-000000000003')
    or not exists(select 1 from public.plan_issues
      where id='f4a16400-0000-4000-8000-000000000001') then
    raise exception 'PHASE4A_LOCATION_B_BOUNDARY_INVALID'; end if;
  if exists(select 1 from public.shifts
      where id='f4a16100-0000-4000-8000-000000000003')
  then raise exception 'PHASE4A_LOCATION_B_DRAFT_SHIFT_VISIBLE'; end if;
  update public.operational_events set title='Phase 4A event B updated'
    where id='f4a16300-0000-4000-8000-000000000002';
  if not found then raise exception 'PHASE4A_LOCATION_B_EVENT_WRITE_DENIED'; end if;
  update public.operational_events set title='LEAK B'
    where id='f4a16300-0000-4000-8000-000000000001';
  if found then raise exception 'PHASE4A_LOCATION_B_CROSS_EVENT_WRITE_ALLOWED'; end if;
end $$;

select set_config('request.jwt.claim.sub','f4a10000-0000-4000-8000-000000000007',true);
do $$ begin
  if (select count(*) from public.employee_availability)<>1 then
    raise exception 'PHASE4A_EMPLOYEE_SELF_READ_INVALID'; end if;
  if (select count(*) from public.assignments)<>2 then
    raise exception 'PHASE4A_EMPLOYEE_SELF_ASSIGNMENT_READ_INVALID'; end if;
  update public.employee_availability set note='SELF'
    where employee_id='f4a11000-0000-4000-8000-000000000001';
  if found is false then raise exception 'PHASE4A_EMPLOYEE_SELF_WRITE_DENIED'; end if;
end $$;

select set_config('request.jwt.claim.sub','f4a10000-0000-4000-8000-000000000008',true);
do $$ begin
  if (select count(*) from public.assignments)<>1
    or (select count(*) from public.employee_availability)<>1 then
    raise exception 'PHASE4A_EMPLOYEE_B_SELF_BOUNDARY_INVALID'; end if;
end $$;

select set_config('request.jwt.claim.sub','f4a10000-0000-4000-8000-000000000001',true);
do $$ begin
  if (select count(*) from public.assignments)<>3 then
    raise exception 'PHASE4A_OWNER_GLOBAL_ACCESS_DENIED'; end if;
  update public.operational_events set title='Phase 4A owner write'
    where id='f4a16300-0000-4000-8000-000000000001';
  if not found then raise exception 'PHASE4A_OWNER_EVENT_WRITE_DENIED'; end if;
end $$;

select set_config('request.jwt.claim.sub','f4a10000-0000-4000-8000-000000000002',true);
do $$ begin
  if (select count(*) from public.assignments)<>3 then
    raise exception 'PHASE4A_ADMIN_GLOBAL_ACCESS_DENIED'; end if;
  update public.operational_events set title='Phase 4A admin write'
    where id='f4a16300-0000-4000-8000-000000000002';
  if not found then raise exception 'PHASE4A_ADMIN_EVENT_WRITE_DENIED'; end if;
end $$;

select set_config('request.jwt.claim.sub','f4a10000-0000-4000-8000-000000000009',true);
do $$ begin
  if exists(select 1 from public.employee_availability) then
    raise exception 'PHASE4A_NO_ROLE_READ_ALLOWED'; end if;
  if exists(select 1 from public.assignments) then
    raise exception 'PHASE4A_NO_ROLE_RESOURCE_READ_ALLOWED'; end if;
  if (select count(*) from public.operational_events)<>2 then
    raise exception 'PHASE4A_LEGACY_GLOBAL_EVENT_READ_CONTRACT_CHANGED'; end if;
  update public.operational_events set title='NO ROLE LEAK';
  if found then raise exception 'PHASE4A_NO_ROLE_EVENT_UPDATE_ALLOWED'; end if;
  delete from public.operational_events;
  if found then raise exception 'PHASE4A_NO_ROLE_EVENT_DELETE_ALLOWED'; end if;
  begin
    insert into public.operational_events(location_id,event_type,title,starts_at,ends_at,status)
    select id,'EVENT','NO ROLE INSERT',current_date,current_date+interval '1 hour','DRAFT'
    from public.locations where code='KRUCZA';
    raise exception 'PHASE4A_NO_ROLE_EVENT_INSERT_ALLOWED';
  exception when insufficient_privilege then null; end;
end $$;

reset role;
set local role anon;
do $$ begin
  begin
    perform 1 from public.assignments limit 1;
    raise exception 'PHASE4A_ANON_ASSIGNMENT_SELECT_ALLOWED';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

rollback;
