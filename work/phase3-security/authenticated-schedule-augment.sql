begin;

set local session_replication_role=replica;

insert into public.plan_shifts_v2(
  id,variant_id,slot_group_key,shift_template_id,location_id,shift_date,starts_at,ends_at
)
select
  'f4500000-0000-4000-8000-000000000001',publication.variant_id,'AUDIT_PHASE3_PUBLISHED_X',
  'f2500000-0000-4000-8000-000000000001','f2400000-0000-4000-8000-000000000001',
  '2026-08-20','2026-08-20 09:00+02','2026-08-20 17:00+02'
from public.published_role_schedules_v2 publication
where publication.id='f2600000-0000-4000-8000-000000000011'::uuid;

insert into public.plan_shifts_v2(
  id,variant_id,slot_group_key,shift_template_id,location_id,shift_date,starts_at,ends_at
)
select
  'f4500000-0000-4000-8000-000000000002',publication.variant_id,'AUDIT_PHASE3_PUBLISHED_Y',
  'f2500000-0000-4000-8000-000000000002','f2400000-0000-4000-8000-000000000002',
  '2026-08-21','2026-08-21 09:00+02','2026-08-21 17:00+02'
from public.published_role_schedules_v2 publication
where publication.id='f2600000-0000-4000-8000-000000000012'::uuid;

insert into public.plan_assignments_v2(id,variant_id,shift_id,slot_key,employee_id,role_id)
select
  'f4600000-0000-4000-8000-000000000001',shift_row.variant_id,shift_row.id,
  'AUDIT_PHASE3_PUBLISHED_X_SLOT','f2100000-0000-4000-8000-000000000001',
  'f2300000-0000-4000-8000-000000000001'
from public.plan_shifts_v2 shift_row
where shift_row.id='f4500000-0000-4000-8000-000000000001'::uuid;

insert into public.plan_assignments_v2(id,variant_id,shift_id,slot_key,employee_id,role_id)
select
  'f4600000-0000-4000-8000-000000000002',shift_row.variant_id,shift_row.id,
  'AUDIT_PHASE3_PUBLISHED_Y_SLOT','f2100000-0000-4000-8000-000000000002',
  'f2300000-0000-4000-8000-000000000002'
from public.plan_shifts_v2 shift_row
where shift_row.id='f4500000-0000-4000-8000-000000000002'::uuid;

set local session_replication_role=origin;
commit;

select jsonb_build_object(
  'shifts',(select count(*) from public.plan_shifts_v2 where id::text like 'f4500000-%'),
  'assignments',(select count(*) from public.plan_assignments_v2 where id::text like 'f4600000-%')
) phase3_authenticated_schedule_augment;
