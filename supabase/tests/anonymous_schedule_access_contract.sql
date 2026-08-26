-- TECH-AUD-2026-08-25-004: anonymous published schedule boundary.
-- This contract exercises effective ACL/RLS semantics with a real PUBLISHED
-- legacy row; it does not rely on matching migration text.

begin;

do $$
declare
  v_schedule_function regprocedure;
begin
  if not (select relrowsecurity from pg_class where oid='public.shifts'::regclass) then
    raise exception 'SHIFTS_RLS_DISABLED';
  end if;

  if exists (
    select 1
    from pg_proc function_row
    join pg_namespace schema_row on schema_row.oid=function_row.pronamespace
    where schema_row.nspname='public'
      and function_row.prokind='f'
      and function_row.prosecdef
      and has_function_privilege('anon',function_row.oid,'EXECUTE')
      and pg_get_functiondef(function_row.oid) ~* '(public\.)?(plans|shifts|assignments|published_schedules_v2|published_role_schedules_v2|published_standby_assignments_v2|plan_shifts_v2|plan_assignments_v2)'
  ) then raise exception 'ANON_SCHEDULE_SECURITY_DEFINER_BYPASS'; end if;

  foreach v_schedule_function in array array[
    to_regprocedure('public.optimizer_employee_schedule_uat_v3(date)'),
    to_regprocedure('public.published_employee_category_calendar_uat_v3(date)'),
    to_regprocedure('public.schedule_publication_status_uat_v2(date)'),
    to_regprocedure('public.optimizer_published_schedule_v2(uuid)')
  ] loop
    if v_schedule_function is null then raise exception 'SCHEDULE_RPC_MISSING'; end if;
    if has_function_privilege('anon',v_schedule_function,'EXECUTE') then
      raise exception 'ANON_SCHEDULE_RPC_EXECUTABLE:%',v_schedule_function;
    end if;
    if not has_function_privilege('authenticated',v_schedule_function,'EXECUTE') then
      raise exception 'AUTHENTICATED_SCHEDULE_RPC_REMOVED:%',v_schedule_function;
    end if;
  end loop;

  if exists (
    select 1 from unnest(array[
      'public.published_schedules_v2'::regclass,
      'public.published_role_schedules_v2'::regclass,
      'public.published_schedule_variants_v2'::regclass,
      'public.published_standby_assignments_v2'::regclass,
      'public.plan_shifts_v2'::regclass,
      'public.plan_assignments_v2'::regclass,
      'public.plan_assignment_duties_v2'::regclass
    ]) relation_oid
    where has_table_privilege('anon',relation_oid,'SELECT')
  ) then raise exception 'ANON_V2_SCHEDULE_TABLE_SELECT_PRIVILEGE'; end if;
end;
$$;

delete from public.shifts where id='f4300000-0000-4000-8000-000000000001'::uuid;
delete from public.plans where id='f4200000-0000-4000-8000-000000000001'::uuid;
delete from public.locations where id='f4100000-0000-4000-8000-000000000001'::uuid;

insert into public.locations(id,code,name,timezone,active)
values ('f4100000-0000-4000-8000-000000000001','KRUCZA','AUDIT PHASE3 CONTRACT','Europe/Warsaw',true);

set local session_replication_role=replica;
insert into public.plans(
  id,month,name,scenario_code,optimization_mode,staffing_level,status,version,generated_at,published_at
) values (
  'f4200000-0000-4000-8000-000000000001','2026-10-01','AUDIT PHASE3 CONTRACT',
  'AUDIT_PHASE3','BALANCED','AUDIT','PUBLISHED',1,now(),now()
);
set local session_replication_role=origin;

insert into public.shifts(
  id,plan_id,location_id,shift_date,shift_code,starts_at,ends_at,status
) values (
  'f4300000-0000-4000-8000-000000000001',
  'f4200000-0000-4000-8000-000000000001',
  'f4100000-0000-4000-8000-000000000001',
  '2026-10-15','AUDIT_PHASE3_CONTRACT',
  '2026-10-15T08:00:00+02:00','2026-10-15T16:00:00+02:00','PLANNED'
);

set local role anon;
do $$
begin
  perform 1
  from public.shifts
  where id='f4300000-0000-4000-8000-000000000001'::uuid;
  if found then raise exception 'ANONYMOUS_PUBLISHED_SHIFT_ROW_EXPOSED'; end if;
exception
  when insufficient_privilege then null;
end;
$$;
reset role;

rollback;
