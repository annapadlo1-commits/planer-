-- TECH-AUD-2026-08-25-004 / Phase 3B: explicit anonymous schedule boundary.
-- The invariant is local to schedule ACL/RLS and remains true even if the
-- EXECUTE privilege of has_app_role(app_role) is changed transactionally.

begin;

do $$
declare
  v_relation regclass;
  v_schedule_function regprocedure;
begin
  foreach v_relation in array array[
    'public.shifts'::regclass,
    'public.assignments'::regclass
  ] loop
    if not (select relrowsecurity from pg_class where oid=v_relation) then
      raise exception 'LEGACY_SCHEDULE_RLS_DISABLED:%',v_relation;
    end if;
    if has_table_privilege('anon',v_relation,'SELECT') then
      raise exception 'ANON_LEGACY_SCHEDULE_SELECT_PRIVILEGE:%',v_relation;
    end if;
    if not has_table_privilege('authenticated',v_relation,'SELECT') then
      raise exception 'AUTHENTICATED_LEGACY_SCHEDULE_SELECT_REMOVED:%',v_relation;
    end if;
  end loop;

  if exists (
    select 1
    from pg_policies
    where schemaname='public'
      and tablename=any(array[
        'shifts','assignments','plans','published_schedules_v2',
        'published_role_schedules_v2','published_schedule_variants_v2',
        'published_standby_assignments_v2','plan_shifts_v2',
        'plan_assignments_v2','plan_assignment_duties_v2'
      ])
      and roles && array['public','anon']::name[]
  ) then raise exception 'ANON_TARGETED_SCHEDULE_POLICY'; end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname='public'
      and tablename='shifts'
      and cmd='SELECT'
      and roles=array['authenticated']::name[]
      and qual ~* 'plans'
      and qual ~* 'PUBLISHED'
  ) then raise exception 'AUTHENTICATED_PUBLISHED_SHIFT_POLICY_MISSING'; end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname='public'
      and tablename='assignments'
      and cmd='SELECT'
      and roles=array['authenticated']::name[]
      and qual ~* 'employee_id'
      and qual ~* 'auth.uid'
  ) then raise exception 'AUTHENTICATED_OWN_ASSIGNMENT_POLICY_MISSING'; end if;

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

-- Prove that schedule denial is independent of the helper privilege. This
-- grant and its explicit revoke are also enclosed by the outer rollback.
grant execute on function public.has_app_role(public.app_role) to anon;
set local role anon;
do $$
begin
  begin
    perform 1 from public.shifts limit 1;
    raise exception 'ANON_SHIFT_SELECT_EXECUTED_WITH_HELPER_GRANT';
  exception when insufficient_privilege then null;
  end;

  begin
    perform 1 from public.assignments limit 1;
    raise exception 'ANON_ASSIGNMENT_SELECT_EXECUTED_WITH_HELPER_GRANT';
  exception when insufficient_privilege then null;
  end;
end;
$$;
reset role;
revoke execute on function public.has_app_role(public.app_role) from anon;

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
  begin
    perform 1
    from public.shifts
    where id='f4300000-0000-4000-8000-000000000001'::uuid;
    raise exception 'ANONYMOUS_PUBLISHED_SHIFT_SELECT_EXECUTED';
  exception when insufficient_privilege then null;
  end;

  begin
    perform 1 from public.assignments limit 1;
    raise exception 'ANONYMOUS_ASSIGNMENT_SELECT_EXECUTED';
  exception when insufficient_privilege then null;
  end;
end;
$$;
reset role;

rollback;
