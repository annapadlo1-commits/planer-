begin;

do $$
begin
  if exists (
    select 1 from public.locations
    where id = 'f4100000-0000-4000-8000-000000000001'::uuid
      and name <> 'AUDIT PHASE3 LOCATION'
  ) then
    raise exception 'PHASE3_LOCATION_ID_COLLISION';
  end if;
  if exists (
    select 1 from public.plans
    where id = 'f4200000-0000-4000-8000-000000000001'::uuid
      and name <> 'AUDIT PHASE3 PUBLISHED PLAN'
  ) then
    raise exception 'PHASE3_PLAN_ID_COLLISION';
  end if;
  if exists (
    select 1 from public.shifts
    where id = 'f4300000-0000-4000-8000-000000000001'::uuid
      and shift_code <> 'AUDIT_PHASE3_SHIFT'
  ) then
    raise exception 'PHASE3_SHIFT_ID_COLLISION';
  end if;
end $$;

delete from public.shifts where id = 'f4300000-0000-4000-8000-000000000001'::uuid;
delete from public.plans where id = 'f4200000-0000-4000-8000-000000000001'::uuid;
delete from public.locations where id = 'f4100000-0000-4000-8000-000000000001'::uuid;

insert into public.locations(id, code, name, timezone, active)
values ('f4100000-0000-4000-8000-000000000001', 'KRUCZA', 'AUDIT PHASE3 LOCATION', 'Europe/Warsaw', true);

-- The active ORTOOLS_V2 guard intentionally blocks new legacy publications.
-- Disable triggers only for this valid audit row so PostgREST/RLS can be tested
-- against the historical/imported PUBLISHED state the policy still accepts.
set local session_replication_role = replica;
insert into public.plans(
  id, month, name, scenario_code, optimization_mode, staffing_level,
  status, version, generated_at, published_at
)
values (
  'f4200000-0000-4000-8000-000000000001', '2026-10-01',
  'AUDIT PHASE3 PUBLISHED PLAN', 'AUDIT_PHASE3', 'BALANCED', 'AUDIT',
  'PUBLISHED', 1, now(), now()
);
set local session_replication_role = origin;

insert into public.shifts(
  id, plan_id, location_id, shift_date, shift_code,
  starts_at, ends_at, status
)
values (
  'f4300000-0000-4000-8000-000000000001',
  'f4200000-0000-4000-8000-000000000001',
  'f4100000-0000-4000-8000-000000000001',
  '2026-10-15', 'AUDIT_PHASE3_SHIFT',
  '2026-10-15T08:00:00+02:00', '2026-10-15T16:00:00+02:00', 'PLANNED'
);

commit;

select jsonb_build_object(
  'locations', (select count(*) from public.locations where name like 'AUDIT PHASE3%'),
  'plans', (select count(*) from public.plans where name like 'AUDIT PHASE3%'),
  'shifts', (select count(*) from public.shifts where shift_code like 'AUDIT_PHASE3%')
) as phase3_fixture_setup;
