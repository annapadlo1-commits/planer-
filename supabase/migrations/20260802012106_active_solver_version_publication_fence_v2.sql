-- GRAFIK PRO 3.0 — active OR-Tools version fence and employee timezone sync.
--
-- This is deliberately a later sync migration. It upgrades branches that
-- already applied optimizer_publication_v2 and also participates in clean
-- replay without rewriting deployed migration history.

create or replace function solver_private.active_ortools_solver_version_v2()
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_engine text;
  v_enabled boolean;
  v_solver_version text;
begin
  select flag.engine,flag.enabled,
    nullif(trim(flag.config->>'solverVersion'),'')
  into v_engine,v_enabled,v_solver_version
  from public.solver_feature_flags flag
  where flag.flag_key='DEFAULT_ENGINE';

  if v_enabled is distinct from true
    or v_engine is distinct from 'ORTOOLS_V2' then
    raise exception 'ORTOOLS_ACTIVE_SOLVER_VERSION_REQUIRED';
  end if;
  if length(coalesce(v_solver_version,'')) not between 1 and 200 then
    raise exception 'SOLVER_VERSION_CONFIGURATION_REQUIRED';
  end if;
  return v_solver_version;
end;
$$;

revoke all on function solver_private.active_ortools_solver_version_v2()
  from public,anon,authenticated;
grant execute on function solver_private.active_ortools_solver_version_v2()
  to service_role;

comment on function solver_private.active_ortools_solver_version_v2() is
  'Fail-closed source of the enabled DEFAULT_ENGINE ORTOOLS_V2 solverVersion.';

-- Direct writes must not bypass the public selection RPC version fence.
create or replace function solver_private.guard_active_variant_selection_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_active_solver_version text;
  v_request_engine text;
  v_run_solver_version text;
begin
  if not new.selected
    or (tg_op='UPDATE' and old.selected is true) then
    return new;
  end if;

  v_active_solver_version :=
    solver_private.active_ortools_solver_version_v2();
  select run.request_engine,run.solver_version
  into v_request_engine,v_run_solver_version
  from public.optimization_runs_v2 run
  where run.id=new.run_id;

  if v_request_engine is distinct from 'ORTOOLS_V2' then
    raise exception 'SHADOW_RUN_NOT_SELECTABLE';
  end if;
  if v_run_solver_version is distinct from v_active_solver_version then
    raise exception 'RUN_SOLVER_VERSION_NOT_ACTIVE';
  end if;
  return new;
end;
$$;

revoke all on function solver_private.guard_active_variant_selection_v2()
  from public,anon,authenticated;
grant execute on function solver_private.guard_active_variant_selection_v2()
  to service_role;

drop trigger if exists plan_variants_v2_active_solver_selection
  on public.plan_variants_v2;
create trigger plan_variants_v2_active_solver_selection
before insert or update of selected on public.plan_variants_v2
for each row execute function solver_private.guard_active_variant_selection_v2();

-- The link trigger is the final database boundary shared by COMPANY and
-- ROLE_COMPOSITE publication. It re-reads the active version and therefore
-- protects all present and future publication RPCs.
create or replace function solver_private.guard_production_variant_link_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_active_solver_version text;
  v_request_engine text;
  v_run_solver_version text;
begin
  v_active_solver_version :=
    solver_private.active_ortools_solver_version_v2();
  select run.request_engine,run.solver_version
  into v_request_engine,v_run_solver_version
  from public.plan_variants_v2 variant
  join public.optimization_runs_v2 run on run.id=variant.run_id
  where variant.id=new.variant_id;

  if v_request_engine is distinct from 'ORTOOLS_V2' then
    raise exception 'SHADOW_RUN_NOT_PUBLISHABLE';
  end if;
  if v_run_solver_version is distinct from v_active_solver_version then
    raise exception 'RUN_SOLVER_VERSION_NOT_ACTIVE';
  end if;
  return new;
end;
$$;

revoke all on function solver_private.guard_production_variant_link_v2()
  from public,anon,authenticated;
grant execute on function solver_private.guard_production_variant_link_v2()
  to service_role;

-- Preserve the audited publication implementations as private implementation
-- details. Public wrappers below add the active-version fence before any
-- idempotency shortcut or publication mutation can run.
alter function public.optimizer_select_variant_v2(uuid,uuid)
  set schema solver_private;
alter function solver_private.optimizer_select_variant_v2(uuid,uuid)
  rename to optimizer_select_variant_pre_version_fence_v2;
revoke all on function
  solver_private.optimizer_select_variant_pre_version_fence_v2(uuid,uuid)
  from public,anon,authenticated,service_role;

alter function public.optimizer_publish_company_variant_v2(uuid,uuid,text,text)
  set schema solver_private;
alter function
  solver_private.optimizer_publish_company_variant_v2(uuid,uuid,text,text)
  rename to optimizer_publish_company_variant_pre_version_fence_v2;
revoke all on function
  solver_private.optimizer_publish_company_variant_pre_version_fence_v2(
    uuid,uuid,text,text
  ) from public,anon,authenticated,service_role;

alter function
  public.optimizer_publish_role_composite_v2(date,uuid,uuid[],text,text)
  set schema solver_private;
alter function
  solver_private.optimizer_publish_role_composite_v2(
    date,uuid,uuid[],text,text
  ) rename to optimizer_publish_role_composite_pre_version_fence_v2;
revoke all on function
  solver_private.optimizer_publish_role_composite_pre_version_fence_v2(
    date,uuid,uuid[],text,text
  ) from public,anon,authenticated,service_role;

create or replace function public.optimizer_select_variant_v2(
  p_run_id uuid,
  p_variant_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_engine text;
  v_enabled boolean;
  v_active_solver_version text;
begin
  select flag.engine,flag.enabled into v_engine,v_enabled
  from public.solver_feature_flags flag
  where flag.flag_key='DEFAULT_ENGINE';
  if v_enabled is distinct from true
    or v_engine is distinct from 'ORTOOLS_V2' then
    raise exception 'ORTOOLS_SELECTION_DISABLED';
  end if;
  v_active_solver_version :=
    solver_private.active_ortools_solver_version_v2();

  if exists(
    select 1 from public.optimization_runs_v2 run
    where run.id=p_run_id
      and (
        run.request_engine is distinct from 'ORTOOLS_V2'
        or run.solver_version is distinct from v_active_solver_version
      )
  ) then raise exception 'RUN_SOLVER_VERSION_NOT_ACTIVE'; end if;

  return solver_private.optimizer_select_variant_pre_version_fence_v2(
    p_run_id,p_variant_id
  );
end;
$$;

create or replace function public.optimizer_publish_company_variant_v2(
  p_run_id uuid,
  p_variant_id uuid,
  p_name text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_engine text;
  v_enabled boolean;
  v_active_solver_version text;
  v_request_engine text;
  v_run_solver_version text;
begin
  select flag.engine,flag.enabled into v_engine,v_enabled
  from public.solver_feature_flags flag
  where flag.flag_key='DEFAULT_ENGINE';
  if v_enabled is distinct from true
    or v_engine is distinct from 'ORTOOLS_V2' then
    raise exception 'ORTOOLS_PUBLICATION_DISABLED';
  end if;
  v_active_solver_version :=
    solver_private.active_ortools_solver_version_v2();

  select run.request_engine,run.solver_version
  into v_request_engine,v_run_solver_version
  from public.optimization_runs_v2 run
  where run.id=p_run_id;
  if v_request_engine is not null
    and v_request_engine is distinct from 'ORTOOLS_V2' then
    raise exception 'SHADOW_RUN_NOT_PUBLISHABLE';
  end if;
  if v_request_engine is not null
    and v_run_solver_version is distinct from v_active_solver_version then
    raise exception 'RUN_SOLVER_VERSION_NOT_ACTIVE';
  end if;

  return
    solver_private.optimizer_publish_company_variant_pre_version_fence_v2(
      p_run_id,p_variant_id,p_name,p_idempotency_key
    );
end;
$$;

create or replace function public.optimizer_publish_role_composite_v2(
  p_month date,
  p_scenario_id uuid,
  p_variant_ids uuid[],
  p_name text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_engine text;
  v_enabled boolean;
  v_active_solver_version text;
begin
  select flag.engine,flag.enabled into v_engine,v_enabled
  from public.solver_feature_flags flag
  where flag.flag_key='DEFAULT_ENGINE';
  if v_enabled is distinct from true
    or v_engine is distinct from 'ORTOOLS_V2' then
    raise exception 'ORTOOLS_PUBLICATION_DISABLED';
  end if;
  v_active_solver_version :=
    solver_private.active_ortools_solver_version_v2();

  if exists(
    select 1
    from public.plan_variants_v2 variant
    join public.optimization_runs_v2 run on run.id=variant.run_id
    where variant.id=any(p_variant_ids)
      and run.request_engine is distinct from 'ORTOOLS_V2'
  ) then raise exception 'SHADOW_RUN_NOT_PUBLISHABLE'; end if;
  if exists(
    select 1
    from public.plan_variants_v2 variant
    join public.optimization_runs_v2 run on run.id=variant.run_id
    where variant.id=any(p_variant_ids)
      and run.request_engine='ORTOOLS_V2'
      and run.solver_version is distinct from v_active_solver_version
  ) then raise exception 'RUN_SOLVER_VERSION_NOT_ACTIVE'; end if;

  return
    solver_private.optimizer_publish_role_composite_pre_version_fence_v2(
      p_month,p_scenario_id,p_variant_ids,p_name,p_idempotency_key
    );
end;
$$;

-- Candidates must never silently reuse a selected result produced by an
-- older worker image after DEFAULT_ENGINE.config.solverVersion changes.
create or replace function public.optimizer_role_composite_candidates_v2(
  p_month date,
  p_scenario_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_month date;
  v_matrix_version_id uuid;
  v_scenario_name text;
  v_active_solver_version text;
  v_roles jsonb;
  v_missing_roles jsonb;
  v_variant_ids jsonb;
  v_demanded_count integer;
  v_candidate_count integer;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  if p_scenario_id is null then raise exception 'SCENARIO_REQUIRED'; end if;
  v_month := date_trunc('month',p_month)::date;
  v_active_solver_version :=
    solver_private.active_ortools_solver_version_v2();

  select scenario.matrix_version_id,scenario.name
  into v_matrix_version_id,v_scenario_name
  from public.matrix_scenarios_v2 scenario
  join public.matrix_versions matrix
    on matrix.id=scenario.matrix_version_id and matrix.schema_version>=2
  where scenario.id=p_scenario_id and scenario.active;
  if v_matrix_version_id is null then raise exception 'SCENARIO_NOT_FOUND'; end if;

  with demanded as (
    select demand.role_id,sum(demand.required_count)::bigint demand_slot_count
    from solver_private.resolved_demand_v2(
      v_month,v_matrix_version_id,p_scenario_id,null
    ) demand
    group by demand.role_id
  ), candidates as (
    select demanded.role_id,demanded.demand_slot_count,role.name role_name,
      role.color role_color,role.sort_order,
      candidate.run_id,candidate.run_created_at,candidate.run_finished_at,
      candidate.variant_id,candidate.variant_name,candidate.variant_status,
      candidate.assignment_count,candidate.unfilled_count,
      candidate.solver_status,candidate.selected_at,
      candidate.strategy_id,candidate.strategy_name,candidate.strategy_code
    from demanded
    join public.matrix_roles_v2 role
      on role.id=demanded.role_id
      and role.matrix_version_id=v_matrix_version_id
    left join lateral (
      select run.id run_id,run.created_at run_created_at,
        run.finished_at run_finished_at,variant.id variant_id,
        variant.name variant_name,variant.status variant_status,
        variant.assignment_count,variant.unfilled_count,
        variant.solver_status,variant.selected_at,
        strategy.id strategy_id,strategy.name strategy_name,
        strategy.code strategy_code
      from public.optimization_runs_v2 run
      join public.plan_variants_v2 variant
        on variant.run_id=run.id and variant.selected
        and variant.hard_violations=0
        and variant.status in ('SELECTED','PUBLISHED')
      join public.matrix_strategies_v2 strategy
        on strategy.id=variant.strategy_id
      where run.month=v_month
        and run.matrix_version_id=v_matrix_version_id
        and run.scenario_id=p_scenario_id
        and run.request_engine='ORTOOLS_V2'
        and run.solver_version=v_active_solver_version
        and run.scope_type='ROLE'
        and run.scope_role_id=demanded.role_id
        and run.status='READY'
      order by run.finished_at desc nulls last,run.created_at desc,
        variant.selected_at desc nulls last,variant.created_at desc,
        run.id desc,variant.id desc
      limit 1
    ) candidate on true
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'role',jsonb_build_object(
        'id',candidate.role_id,'name',candidate.role_name,
        'color',candidate.role_color,'sortOrder',candidate.sort_order
      ),
      'demandSlotCount',candidate.demand_slot_count,
      'run',case when candidate.run_id is null then null else jsonb_build_object(
        'id',candidate.run_id,'status','READY',
        'createdAt',candidate.run_created_at,
        'finishedAt',candidate.run_finished_at
      ) end,
      'variant',case when candidate.variant_id is null then null
        else jsonb_build_object(
          'id',candidate.variant_id,'name',candidate.variant_name,
          'status',candidate.variant_status,
          'assignmentCount',candidate.assignment_count,
          'unfilledCount',candidate.unfilled_count,
          'solverStatus',candidate.solver_status,
          'selectedAt',candidate.selected_at,
          'strategy',jsonb_build_object(
            'id',candidate.strategy_id,'name',candidate.strategy_name,
            'code',candidate.strategy_code
          )
        ) end,
      'ready',candidate.variant_id is not null
    ) order by candidate.sort_order,candidate.role_name,
      candidate.role_id::text),'[]'::jsonb),
    coalesce(jsonb_agg(jsonb_build_object(
      'id',candidate.role_id,'name',candidate.role_name
    ) order by candidate.sort_order,candidate.role_name,
      candidate.role_id::text)
      filter(where candidate.variant_id is null),'[]'::jsonb),
    coalesce(jsonb_agg(to_jsonb(candidate.variant_id)
      order by candidate.sort_order,candidate.role_name,
        candidate.role_id::text)
      filter(where candidate.variant_id is not null),'[]'::jsonb),
    count(*)::integer,count(candidate.variant_id)::integer
  into v_roles,v_missing_roles,v_variant_ids,
    v_demanded_count,v_candidate_count
  from candidates candidate;

  return jsonb_build_object(
    'month',v_month,
    'scenario',jsonb_build_object(
      'id',p_scenario_id,'name',v_scenario_name
    ),
    'matrixVersionId',v_matrix_version_id,
    'roles',v_roles,
    'missingRoles',v_missing_roles,
    'variantIds',v_variant_ids,
    'demandedRoleCount',v_demanded_count,
    'ready',v_demanded_count>0 and v_candidate_count=v_demanded_count
  );
end;
$$;

-- Employee assignment timestamps are absolute instants. The versioned Matrix
-- location timezone is returned alongside them so clients can render the
-- intended local wall-clock time, including DST boundaries.
create or replace function public.optimizer_employee_published_schedule_v2(
  p_month date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_engine text;
  v_employee_id uuid;
  v_schedule_id uuid;
  v_matrix_version_id uuid;
  v_month date:=date_trunc('month',p_month)::date;
  v_assignments jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  select flag.engine into v_engine
  from public.solver_feature_flags flag
  where flag.flag_key='DEFAULT_ENGINE' and flag.enabled;
  if v_engine is null then raise exception 'SOLVER_ENGINE_CONFIGURATION_MISSING'; end if;
  if v_engine not in ('ALPHA15','SHADOW','ORTOOLS_V2') then
    raise exception 'SOLVER_ENGINE_CONFIGURATION_INVALID';
  end if;
  if v_engine<>'ORTOOLS_V2' then return null; end if;
  select employee.id into v_employee_id
  from public.employees employee
  where employee.auth_user_id=auth.uid()
    and employee.active and employee.archived_at is null
  order by employee.employee_no limit 1;
  if v_employee_id is null then
    raise exception 'EMPLOYEE_ACCOUNT_NOT_LINKED';
  end if;
  select schedule.id,schedule.matrix_version_id
  into v_schedule_id,v_matrix_version_id
  from public.published_schedules_v2 schedule
  where schedule.month=v_month and schedule.status='PUBLISHED'
  order by schedule.published_at desc,schedule.id desc limit 1;
  if v_schedule_id is null then
    return jsonb_build_object(
      'engine','ORTOOLS_V2','scheduleId',null,'assignments','[]'::jsonb
    );
  end if;

  with own_assignments as (
    select assignment.id,assignment.employee_id,assignment.role_id,
      assignment.shift_id,shift.slot_group_key,shift.shift_date,
      shift.starts_at,shift.ends_at,shift.location_id,
      shift.shift_template_id
    from public.published_schedule_variants_v2 link
    join public.plan_assignments_v2 assignment
      on assignment.variant_id=link.variant_id
    join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
    where link.schedule_id=v_schedule_id
      and assignment.employee_id=v_employee_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',own.id,
    'shiftId',own.slot_group_key,
    'date',own.shift_date,
    'startsAt',own.starts_at,
    'endsAt',own.ends_at,
    'shiftCode',shift_template.code,
    'shiftName',shift_template.name,
    'location',location.name,
    'locationCode',location.code,
    'locationTimezone',location.timezone,
    'role',role.name,
    'roleCode',role.code,
    'capability',coalesce((
      select string_agg(duty.name,', ' order by duty.sort_order,duty.name)
      from public.plan_assignment_duties_v2 assignment_duty
      join public.matrix_duties_v2 duty
        on duty.id=assignment_duty.duty_id
      where assignment_duty.assignment_id=own.id
    ),''),
    'coworkers',coalesce((
      select jsonb_agg(jsonb_build_object(
        'name',coworker.first_name||' '||coworker.last_name,
        'role',coworker_role.name,
        'capability',coalesce((
          select string_agg(
            duty.name,', ' order by duty.sort_order,duty.name
          )
          from public.plan_assignment_duties_v2 assignment_duty
          join public.matrix_duties_v2 duty
            on duty.id=assignment_duty.duty_id
          where assignment_duty.assignment_id=coworker_assignment.id
        ),'')
      ) order by coworker.last_name,coworker.first_name,
        coworker_assignment.id)
      from public.published_schedule_variants_v2 coworker_link
      join public.plan_assignments_v2 coworker_assignment
        on coworker_assignment.variant_id=coworker_link.variant_id
      join public.plan_shifts_v2 coworker_shift
        on coworker_shift.id=coworker_assignment.shift_id
      join public.matrix_employee_profiles_v2 coworker
        on coworker.matrix_version_id=v_matrix_version_id
        and coworker.employee_id=coworker_assignment.employee_id
      join public.matrix_roles_v2 coworker_role
        on coworker_role.id=coworker_assignment.role_id
      where coworker_link.schedule_id=v_schedule_id
        and coworker_assignment.employee_id<>v_employee_id
        and coworker_shift.slot_group_key=own.slot_group_key
        and coworker_shift.location_id=own.location_id
        and coworker_shift.starts_at=own.starts_at
        and coworker_shift.ends_at=own.ends_at
    ),'[]'::jsonb)
  ) order by own.starts_at,own.id),'[]'::jsonb)
  into v_assignments
  from own_assignments own
  join public.matrix_locations_v2 location
    on location.id=own.location_id
    and location.matrix_version_id=v_matrix_version_id
  join public.matrix_shift_templates_v2 shift_template
    on shift_template.id=own.shift_template_id
  join public.matrix_roles_v2 role on role.id=own.role_id;

  return jsonb_build_object(
    'engine','ORTOOLS_V2','scheduleId',v_schedule_id,
    'assignments',v_assignments
  );
end;
$$;

revoke all on function public.optimizer_select_variant_v2(uuid,uuid)
  from public,anon;
revoke all on function
  public.optimizer_publish_company_variant_v2(uuid,uuid,text,text)
  from public,anon;
revoke all on function
  public.optimizer_publish_role_composite_v2(date,uuid,uuid[],text,text)
  from public,anon;
revoke all on function
  public.optimizer_role_composite_candidates_v2(date,uuid)
  from public,anon;
revoke all on function
  public.optimizer_employee_published_schedule_v2(date)
  from public,anon;

grant execute on function public.optimizer_select_variant_v2(uuid,uuid)
  to authenticated;
grant execute on function
  public.optimizer_publish_company_variant_v2(uuid,uuid,text,text)
  to authenticated;
grant execute on function
  public.optimizer_publish_role_composite_v2(date,uuid,uuid[],text,text)
  to authenticated;
grant execute on function
  public.optimizer_role_composite_candidates_v2(date,uuid)
  to authenticated;
grant execute on function
  public.optimizer_employee_published_schedule_v2(date)
  to authenticated;

comment on function public.optimizer_select_variant_v2(uuid,uuid) is
  'Selects only a READY variant produced by the currently active OR-Tools solver version.';
comment on function
  public.optimizer_publish_company_variant_v2(uuid,uuid,text,text) is
  'Publishes a selected COMPANY variant only when its run matches active solverVersion.';
comment on function
  public.optimizer_publish_role_composite_v2(date,uuid,uuid[],text,text) is
  'Publishes ROLE variants only when every run matches active solverVersion.';
comment on function public.optimizer_role_composite_candidates_v2(date,uuid) is
  'Returns selected ROLE candidates produced by the exact active solverVersion.';
comment on function public.optimizer_employee_published_schedule_v2(date) is
  'Returns employee assignments with the versioned Matrix locationTimezone.';
