begin;
delete from public.shifts where id = 'f4300000-0000-4000-8000-000000000001'::uuid;
delete from public.plans where id = 'f4200000-0000-4000-8000-000000000001'::uuid;
delete from public.locations where id = 'f4100000-0000-4000-8000-000000000001'::uuid;
commit;

select jsonb_build_object(
  'auditUsers', (select count(*) from auth.users where raw_user_meta_data->>'audit_marker' = 'PHASE3_ANON_SCHEDULE'),
  'auditEmployees', (select count(*) from public.employees where first_name like 'AUDIT PHASE3%'),
  'auditRoles', (select count(*) from public.roles where name like 'AUDIT PHASE3%'),
  'auditLocations', (select count(*) from public.locations where name like 'AUDIT PHASE3%'),
  'auditMatrices', (select count(*) from public.matrix_versions where name like 'AUDIT PHASE3%'),
  'auditSchedules', (
    (select count(*) from public.plans where name like 'AUDIT PHASE3%') +
    (select count(*) from public.published_schedules_v2 where name like 'AUDIT PHASE3%') +
    (select count(*) from public.published_role_schedules_v2 where name like 'AUDIT PHASE3%')
  ),
  'auditShifts', (select count(*) from public.shifts where shift_code like 'AUDIT_PHASE3%'),
  'auditAssignments', (select count(*) from public.assignments a join public.shifts s on s.id=a.shift_id where s.shift_code like 'AUDIT_PHASE3%'),
  'auditStandby', (select count(*) from public.published_standby_assignments_v2 where id='f4400000-0000-4000-8000-000000000001'::uuid),
  'ownerGrants', (select count(*) from public.matrix_scope_grants_v2 where app_role='OWNER' and active),
  'activeMatrices', (select count(*) from public.matrix_versions where status='ACTIVE')
) as phase3_fixture_cleanup;
