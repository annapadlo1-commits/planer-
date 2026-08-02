-- Transactional contract for the planning-data revision boundary.
-- Safe to run repeatedly: every mutation is rolled back.

begin;

do $$
declare
  v_before bigint;
  v_after bigint;
  v_missing text[];
begin
  if has_table_privilege(
    'authenticated',
    'solver_private.planning_data_revision_v2',
    'SELECT'
  ) then
    raise exception 'AUTHENTICATED_MUST_NOT_READ_PLANNING_REVISION';
  end if;
  if has_function_privilege(
    'authenticated',
    'solver_private.lock_planning_revision_v2()',
    'EXECUTE'
  ) then
    raise exception 'AUTHENTICATED_MUST_NOT_LOCK_PLANNING_REVISION';
  end if;

  select array_agg(required.table_name order by required.table_name)
  into v_missing
  from unnest(array[
    'assignments',
    'employee_hr_profiles',
    'employee_pay_rates_v2',
    'employee_preferences',
    'employee_time_constraints_v2',
    'employee_availability',
    'employees',
    'matrix_duties_v2',
    'matrix_employee_duties_v2',
    'matrix_employee_locations_v2',
    'matrix_employee_profiles_v2',
    'matrix_employee_roles_v2',
    'matrix_locations_v2',
    'matrix_pay_rule_duties_v2',
    'matrix_pay_rule_locations_v2',
    'matrix_pay_rule_roles_v2',
    'matrix_pay_rule_shifts_v2',
    'matrix_pay_rules_v2',
    'matrix_role_duties_v2',
    'matrix_scenario_budgets_v2',
    'matrix_scenario_pay_rule_overrides_v2',
    'matrix_scenario_strategies_v2',
    'matrix_scenarios_v2',
    'matrix_shift_templates_v2',
    'matrix_staffing_rules_v2',
    'matrix_strategies_v2',
    'matrix_strategy_objectives_v2',
    'matrix_versions',
    'locations',
    'monthly_budgets',
    'plan_assignment_duties_v2',
    'plan_assignments_v2',
    'plan_shifts_v2',
    'plan_variants_v2',
    'plans',
    'published_schedule_variants_v2',
    'published_schedules_v2',
    'shifts'
  ]) as required(table_name)
  where not exists(
    select 1
    from pg_trigger trigger_row
    join pg_class relation on relation.oid=trigger_row.tgrelid
    join pg_namespace namespace on namespace.oid=relation.relnamespace
    where namespace.nspname='public'
      and relation.relname=required.table_name
      and trigger_row.tgname='planning_revision_v2_bump'
      and not trigger_row.tgisinternal
  );
  if v_missing is not null then
    raise exception 'PLANNING_REVISION_TRIGGERS_MISSING: %',v_missing;
  end if;

  select revision into v_before
  from solver_private.planning_data_revision_v2
  where singleton;
  perform solver_private.lock_planning_revision_v2();
  -- Statement triggers must also cover imports whose filter happens to match
  -- no rows; this keeps every attempted bulk-write boundary deterministic.
  update public.matrix_versions set settings=settings where false;
  select revision into v_after
  from solver_private.planning_data_revision_v2
  where singleton;
  if v_after<>v_before+1 then
    raise exception 'PLANNING_REVISION_DID_NOT_ADVANCE_ONCE: % -> %',
      v_before,v_after;
  end if;

  if position(
    'lock_planning_revision_v2' in
    pg_get_functiondef(
      'public.optimizer_request_v2(date,uuid,text,uuid,text,text)'::regprocedure
    )
  )=0 then raise exception 'OPTIMIZER_REQUEST_NOT_REVISION_LOCKED'; end if;
  if position(
    'ORTOOLS_REQUEST_DISABLED' in pg_get_functiondef(
      'public.optimizer_request_v2(date,uuid,text,uuid,text,text)'::regprocedure
    )
  )=0 then raise exception 'ALPHA15_V2_REQUEST_NOT_BLOCKED'; end if;
  if position(
    'lock_planning_revision_v2' in
    pg_get_functiondef(
      'public.solver_finalize_v2(uuid,uuid,uuid)'::regprocedure
    )
  )=0 then raise exception 'SOLVER_FINALIZE_NOT_REVISION_LOCKED'; end if;
  if position(
    'lock_planning_revision_v2' in
    pg_get_functiondef(
      'public.optimizer_publish_company_variant_v2(uuid,uuid,text,text)'::regprocedure
    )
  )=0 then raise exception 'COMPANY_PUBLICATION_NOT_REVISION_LOCKED'; end if;
  if position(
    'lock_planning_revision_v2' in
    pg_get_functiondef(
      'public.optimizer_publish_role_composite_v2(date,uuid,uuid[],text,text)'::regprocedure
    )
  )=0 then raise exception 'COMPOSITE_PUBLICATION_NOT_REVISION_LOCKED'; end if;
end;
$$;

rollback;
