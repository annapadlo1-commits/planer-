-- B4: one workbook must restore every business input consumed by Matrix v2.
-- The public boundary is UAT-only and atomically composes the existing,
-- independently verified configuration and finance import contracts.

create or replace function solver_private.matrix_v2_full_import_phase_uat_v1(
  p_configuration jsonb,
  p_phase text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_phase text:=upper(trim(coalesce(p_phase,'')));
  v_matrix uuid;
  v_row jsonb;
  v_existing uuid;
  v_employee uuid;
  v_role uuid;
  v_location uuid;
  v_duty uuid;
  v_scenario uuid;
  v_strategy uuid;
  v_pay_rule uuid;
  v_parent uuid;
  v_constraint uuid;
  v_role_ids jsonb;
  v_duty_ids jsonb;
  v_location_ids jsonb;
  v_shift_ids jsonb;
  v_applied integer:=0;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if p_configuration is null or jsonb_typeof(p_configuration)<>'object' then
    raise exception 'INVALID_FULL_IMPORT_CONFIGURATION';
  end if;
  if v_phase not in ('PRE','POST') then raise exception 'INVALID_FULL_IMPORT_PHASE'; end if;
  v_matrix:=public.matrix_v2_create_draft(null);

  if v_phase='PRE' then
    if jsonb_typeof(p_configuration->'settings')='object' then
      perform public.matrix_v2_admin_save_alpha16('MATRIX_SETTINGS',null,p_configuration->'settings');
      v_applied:=v_applied+1;
    end if;

    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'roles','[]'::jsonb)) loop
      select item.id into v_existing from public.matrix_roles_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'code');
      perform public.matrix_v2_admin_save_alpha16('ROLE',v_existing,v_row);
      v_applied:=v_applied+1;
    end loop;
    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'locations','[]'::jsonb)) loop
      select item.id into v_existing from public.matrix_locations_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'code');
      perform public.matrix_v2_admin_save_alpha16('LOCATION',v_existing,v_row);
      v_applied:=v_applied+1;
    end loop;
    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'duties','[]'::jsonb)) loop
      select item.id into v_existing from public.matrix_duties_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'code');
      perform public.matrix_v2_admin_save_alpha16('DUTY',v_existing,v_row);
      v_applied:=v_applied+1;
    end loop;

    -- Root scenarios are created first so child rows can resolve their parent code.
    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'scenarios','[]'::jsonb))
      where nullif(trim(value->>'parentScenarioCode'),'') is null loop
      select item.id into v_existing from public.matrix_scenarios_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'code');
      perform public.matrix_v2_admin_save_alpha16('SCENARIO',v_existing,
        v_row||jsonb_build_object('parentScenarioId',null));
      v_applied:=v_applied+1;
    end loop;
    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'scenarios','[]'::jsonb)) loop
      v_parent:=null;
      if nullif(trim(v_row->>'parentScenarioCode'),'') is not null then
        select item.id into v_parent from public.matrix_scenarios_v2 item
        where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'parentScenarioCode');
        if v_parent is null then raise exception 'FULL_IMPORT_PARENT_SCENARIO_NOT_FOUND|%',v_row->>'parentScenarioCode'; end if;
      end if;
      select item.id into v_existing from public.matrix_scenarios_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'code');
      perform public.matrix_v2_admin_save_alpha16('SCENARIO',v_existing,
        v_row||jsonb_build_object('parentScenarioId',v_parent));
    end loop;
    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'strategies','[]'::jsonb)) loop
      select item.id into v_existing from public.matrix_strategies_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'code');
      perform public.matrix_v2_admin_save_alpha16('STRATEGY',v_existing,v_row);
      v_applied:=v_applied+1;
    end loop;
  else
    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'strategyObjectives','[]'::jsonb)) loop
      select item.id into v_strategy from public.matrix_strategies_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'strategyCode');
      if v_strategy is null then raise exception 'FULL_IMPORT_STRATEGY_NOT_FOUND|%',v_row->>'strategyCode'; end if;
      perform public.matrix_v2_admin_save_alpha16('OBJECTIVE',null,
        v_row||jsonb_build_object('strategyId',v_strategy));
      v_applied:=v_applied+1;
    end loop;
    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'scenarioStrategies','[]'::jsonb)) loop
      select item.id into v_scenario from public.matrix_scenarios_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'scenarioCode');
      select item.id into v_strategy from public.matrix_strategies_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'strategyCode');
      if v_scenario is null or v_strategy is null then
        raise exception 'FULL_IMPORT_SCENARIO_STRATEGY_NOT_FOUND|%|%',v_row->>'scenarioCode',v_row->>'strategyCode';
      end if;
      perform public.matrix_v2_admin_save_alpha16('SCENARIO_STRATEGY',null,
        v_row||jsonb_build_object('scenarioId',v_scenario,'strategyId',v_strategy));
      v_applied:=v_applied+1;
    end loop;

    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'payRules','[]'::jsonb)) loop
      select item.id into v_existing from public.matrix_pay_rules_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'code');
      select coalesce(jsonb_agg(item.id::text),'[]'::jsonb) into v_role_ids
      from public.matrix_roles_v2 item where item.matrix_version_id=v_matrix
        and upper(item.code) in (select upper(value) from jsonb_array_elements_text(coalesce(v_row->'roleCodes','[]'::jsonb)));
      select coalesce(jsonb_agg(item.id::text),'[]'::jsonb) into v_duty_ids
      from public.matrix_duties_v2 item where item.matrix_version_id=v_matrix
        and upper(item.code) in (select upper(value) from jsonb_array_elements_text(coalesce(v_row->'dutyCodes','[]'::jsonb)));
      select coalesce(jsonb_agg(item.id::text),'[]'::jsonb) into v_location_ids
      from public.matrix_locations_v2 item where item.matrix_version_id=v_matrix
        and upper(item.code) in (select upper(value) from jsonb_array_elements_text(coalesce(v_row->'locationCodes','[]'::jsonb)));
      select coalesce(jsonb_agg(item.id::text),'[]'::jsonb) into v_shift_ids
      from public.matrix_shift_templates_v2 item where item.matrix_version_id=v_matrix
        and upper(item.code) in (select upper(value) from jsonb_array_elements_text(coalesce(v_row->'shiftCodes','[]'::jsonb)));
      perform public.matrix_v2_admin_save_alpha16('PAY_RULE',v_existing,v_row||jsonb_build_object(
        'roleIds',v_role_ids,'dutyIds',v_duty_ids,'locationIds',v_location_ids,'shiftIds',v_shift_ids));
      v_applied:=v_applied+1;
    end loop;
    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'scenarioPayRuleOverrides','[]'::jsonb)) loop
      select item.id into v_scenario from public.matrix_scenarios_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'scenarioCode');
      select item.id into v_pay_rule from public.matrix_pay_rules_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'payRuleCode');
      if v_scenario is null or v_pay_rule is null then
        raise exception 'FULL_IMPORT_SCENARIO_PAY_RULE_NOT_FOUND|%|%',v_row->>'scenarioCode',v_row->>'payRuleCode';
      end if;
      perform public.matrix_v2_admin_save_alpha16('SCENARIO_PAY_RULE',null,
        v_row||jsonb_build_object('scenarioId',v_scenario,'payRuleId',v_pay_rule));
      v_applied:=v_applied+1;
    end loop;
    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'scenarioBudgets','[]'::jsonb)) loop
      select item.id into v_scenario from public.matrix_scenarios_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'scenarioCode');
      select item.id into v_location from public.matrix_locations_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(nullif(v_row->>'locationCode',''));
      select item.id into v_role from public.matrix_roles_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(nullif(v_row->>'roleCode',''));
      select item.id into v_duty from public.matrix_duties_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(nullif(v_row->>'dutyCode',''));
      if v_scenario is null then raise exception 'FULL_IMPORT_SCENARIO_NOT_FOUND|%',v_row->>'scenarioCode'; end if;
      perform public.matrix_v2_admin_save_alpha16('SCENARIO_BUDGET',null,v_row||jsonb_build_object(
        'scenarioId',v_scenario,'locationId',v_location,'roleId',v_role,'dutyId',v_duty));
      v_applied:=v_applied+1;
    end loop;

    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'employeeRoles','[]'::jsonb)) loop
      select item.employee_id into v_employee from public.matrix_employee_profiles_v2 item
      where item.matrix_version_id=v_matrix and upper(item.employee_no)=upper(v_row->>'employeeNo');
      select item.id into v_role from public.matrix_roles_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'roleCode');
      if v_employee is null or v_role is null then raise exception 'FULL_IMPORT_EMPLOYEE_ROLE_NOT_FOUND|%|%',v_row->>'employeeNo',v_row->>'roleCode'; end if;
      perform public.matrix_v2_admin_save_alpha16('EMPLOYEE_ROLE',null,
        v_row||jsonb_build_object('employeeId',v_employee,'roleId',v_role));
      v_applied:=v_applied+1;
    end loop;
    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'employeeLocationsDetailed','[]'::jsonb)) loop
      select item.employee_id into v_employee from public.matrix_employee_profiles_v2 item
      where item.matrix_version_id=v_matrix and upper(item.employee_no)=upper(v_row->>'employeeNo');
      select item.id into v_location from public.matrix_locations_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'locationCode');
      if v_employee is null or v_location is null then raise exception 'FULL_IMPORT_EMPLOYEE_LOCATION_NOT_FOUND|%|%',v_row->>'employeeNo',v_row->>'locationCode'; end if;
      perform public.matrix_v2_admin_save_alpha16('EMPLOYEE_LOCATION',null,
        v_row||jsonb_build_object('employeeId',v_employee,'locationId',v_location));
      v_applied:=v_applied+1;
    end loop;
    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'employeeCapabilities','[]'::jsonb)) loop
      select item.employee_id into v_employee from public.matrix_employee_profiles_v2 item
      where item.matrix_version_id=v_matrix and upper(item.employee_no)=upper(v_row->>'employeeNo');
      select item.id into v_duty from public.matrix_duties_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'dutyCode');
      select item.id into v_role from public.matrix_roles_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(nullif(v_row->>'roleCode',''));
      select item.id into v_location from public.matrix_locations_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(nullif(v_row->>'locationCode',''));
      if v_employee is null or v_duty is null then raise exception 'FULL_IMPORT_EMPLOYEE_DUTY_NOT_FOUND|%|%',v_row->>'employeeNo',v_row->>'dutyCode'; end if;
      perform public.matrix_v2_admin_save_alpha16('EMPLOYEE_DUTY',null,v_row||jsonb_build_object(
        'employeeId',v_employee,'dutyId',v_duty,'roleId',v_role,'locationId',v_location));
      v_applied:=v_applied+1;
    end loop;

    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'timeConstraints','[]'::jsonb))
      where coalesce((value->>'active')::boolean,true) loop
      select item.employee_id into v_employee from public.matrix_employee_profiles_v2 item
      where item.matrix_version_id=v_matrix and upper(item.employee_no)=upper(v_row->>'employeeNo');
      if v_employee is null then raise exception 'FULL_IMPORT_EMPLOYEE_NOT_FOUND|%',v_row->>'employeeNo'; end if;
      v_constraint:=case when pg_catalog.pg_input_is_valid(coalesce(v_row->>'constraintId',''),'uuid')
        then (v_row->>'constraintId')::uuid else null end;
      if v_constraint is not null and not exists(select 1 from public.employee_time_constraints_v2 item where item.id=v_constraint) then
        v_constraint:=null;
      end if;
      if v_constraint is null then
        select item.id into v_existing from public.employee_time_constraints_v2 item
        where item.employee_id=v_employee and item.status='ACTIVE'
          and item.constraint_kind=upper(v_row->>'kind')
          and lower(item.time_range)=(v_row->>'startsAt')::timestamptz
          and upper(item.time_range)=(v_row->>'endsAt')::timestamptz
          and coalesce(item.note,'')=coalesce(v_row->>'note','') limit 1;
        if v_existing is not null then continue; end if;
      end if;
      perform public.employee_time_constraint_save_v2(v_constraint,v_employee,v_row->>'kind',
        (v_row->>'startsAt')::timestamptz,(v_row->>'endsAt')::timestamptz,nullif(v_row->>'note',''));
      v_applied:=v_applied+1;
    end loop;
  end if;
  return jsonb_build_object('phase',v_phase,'appliedRows',v_applied,'matrixVersionId',v_matrix);
end;
$$;

create or replace function solver_private.matrix_v2_full_finance_payload_uat_v1(
  p_finance jsonb
) returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_set(coalesce(p_finance,'{}'::jsonb),'{payRates}',coalesce((
    select jsonb_agg(case
      when nullif(value->>'rateId','') is not null
        and pg_catalog.pg_input_is_valid(value->>'rateId','uuid')
        and not exists(select 1 from public.employee_pay_rates_v2 rate where rate.id=(value->>'rateId')::uuid)
      then value||jsonb_build_object('rateId','') else value end order by (value->>'sourceRow')::integer)
    from jsonb_array_elements(coalesce(p_finance->'payRates','[]'::jsonb))
  ),'[]'::jsonb),true);
$$;

create or replace function public.matrix_v2_full_import_preview_uat_v1(
  p_payload jsonb,
  p_mode text default 'UPDATE'
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_configuration jsonb:=coalesce(p_payload->'configuration','{}'::jsonb);
  v_configuration_without_rates jsonb;
  v_finance jsonb:=coalesce(p_payload->'finance','{}'::jsonb);
  v_configuration_preview jsonb;
  v_finance_preview jsonb;
  v_result jsonb;
  v_extra integer;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
  if jsonb_typeof(p_payload)<>'object' then raise exception 'INVALID_FULL_IMPORT_PAYLOAD'; end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  v_configuration_without_rates:=jsonb_set(v_configuration,'{employees}',coalesce((
    select jsonb_agg(value-'baseRate') from jsonb_array_elements(coalesce(v_configuration->'employees','[]'::jsonb))
  ),'[]'::jsonb),true);

  begin
    perform solver_private.matrix_v2_full_import_phase_uat_v1(v_configuration,'PRE');
    v_configuration_preview:=public.matrix_v2_import_preview_uat_v5(v_configuration_without_rates,p_mode);
    if coalesce((v_configuration_preview->>'valid')::boolean,false) then
      perform public.matrix_v2_import_apply_uat_v5(v_configuration_without_rates,p_mode);
      perform solver_private.matrix_v2_full_import_phase_uat_v1(v_configuration,'POST');
      v_finance_preview:=public.matrix_v2_finance_import_preview_uat_v1(
        solver_private.matrix_v2_full_finance_payload_uat_v1(v_finance));
    else
      v_finance_preview:=jsonb_build_object('valid',false,'errors','[]'::jsonb,'warnings','[]'::jsonb,
        'normalizedRows','[]'::jsonb,'summary',jsonb_build_object('rows',jsonb_array_length(coalesce(v_finance->'payRates','[]'::jsonb)),
          'employees',0,'create',0,'update',0,'deactivate',0,'unchanged',0));
    end if;
    v_extra:=jsonb_array_length(coalesce(v_configuration->'roles','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'locations','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'duties','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'scenarios','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'strategies','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'strategyObjectives','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'scenarioStrategies','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'payRules','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'scenarioPayRuleOverrides','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'scenarioBudgets','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'employeeRoles','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'employeeLocationsDetailed','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'employeeCapabilities','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'timeConstraints','[]'::jsonb));
    v_result:=jsonb_build_object(
      'valid',coalesce((v_configuration_preview->>'valid')::boolean,false)
        and coalesce((v_finance_preview->>'valid')::boolean,false),
      'errors',coalesce(v_configuration_preview->'errors','[]'::jsonb)||coalesce(v_finance_preview->'errors','[]'::jsonb),
      'warnings',coalesce(v_configuration_preview->'warnings','[]'::jsonb)||coalesce(v_finance_preview->'warnings','[]'::jsonb),
      'configuration',v_configuration_preview,'finance',v_finance_preview,
      'summary',coalesce(v_configuration_preview->'summary','{}'::jsonb)||jsonb_build_object(
        'total',coalesce((v_configuration_preview#>>'{summary,total}')::integer,0)+v_extra,
        'financeRows',coalesce((v_finance_preview#>>'{summary,rows}')::integer,0),
        'financeEmployees',coalesce((v_finance_preview#>>'{summary,employees}')::integer,0),
        'financeChanges',coalesce((v_finance_preview#>>'{summary,create}')::integer,0)
          +coalesce((v_finance_preview#>>'{summary,update}')::integer,0)
          +coalesce((v_finance_preview#>>'{summary,deactivate}')::integer,0),
        'roles',jsonb_array_length(coalesce(v_configuration->'roles','[]'::jsonb)),
        'locations',jsonb_array_length(coalesce(v_configuration->'locations','[]'::jsonb)),
        'duties',jsonb_array_length(coalesce(v_configuration->'duties','[]'::jsonb)),
        'scenarios',jsonb_array_length(coalesce(v_configuration->'scenarios','[]'::jsonb)),
        'strategies',jsonb_array_length(coalesce(v_configuration->'strategies','[]'::jsonb)),
        'payRules',jsonb_array_length(coalesce(v_configuration->'payRules','[]'::jsonb)),
        'timeConstraints',jsonb_array_length(coalesce(v_configuration->'timeConstraints','[]'::jsonb))
      ));
    raise sqlstate 'GPF01' using message='FULL_IMPORT_DRY_RUN_COMPLETE';
  exception when sqlstate 'GPF01' then
    return v_result;
  end;
end;
$$;

create or replace function public.matrix_v2_full_import_apply_uat_v1(
  p_payload jsonb,
  p_mode text default 'UPDATE'
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_configuration jsonb:=coalesce(p_payload->'configuration','{}'::jsonb);
  v_configuration_without_rates jsonb;
  v_finance jsonb:=coalesce(p_payload->'finance','{}'::jsonb);
  v_configuration_result jsonb;
  v_finance_result jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  v_configuration_without_rates:=jsonb_set(v_configuration,'{employees}',coalesce((
    select jsonb_agg(value-'baseRate') from jsonb_array_elements(coalesce(v_configuration->'employees','[]'::jsonb))
  ),'[]'::jsonb),true);
  perform solver_private.matrix_v2_full_import_phase_uat_v1(v_configuration,'PRE');
  v_configuration_result:=public.matrix_v2_import_apply_uat_v5(v_configuration_without_rates,p_mode);
  perform solver_private.matrix_v2_full_import_phase_uat_v1(v_configuration,'POST');
  v_finance_result:=public.matrix_v2_finance_import_apply_uat_v1(
    solver_private.matrix_v2_full_finance_payload_uat_v1(v_finance));
  return v_configuration_result||jsonb_build_object('finance',v_finance_result,'atomic',true,'scope','FULL_COMPANY');
exception when others then
  if sqlerrm like 'FULL_IMPORT_%' or sqlerrm like 'MATRIX_%' or sqlerrm like 'INVALID_%'
    or sqlerrm like 'EMPLOYEE_%' or sqlerrm like 'PAY_RATE_%' or sqlerrm like 'OVERLAPPING_%'
    or sqlerrm like 'FINANCE_%' then raise; end if;
  raise exception 'FULL_IMPORT_APPLY_FAILED|%|%|%',gen_random_uuid(),sqlstate,sqlerrm;
end;
$$;

revoke all on function solver_private.matrix_v2_full_import_phase_uat_v1(jsonb,text),
  solver_private.matrix_v2_full_finance_payload_uat_v1(jsonb)
  from public,anon,authenticated;
revoke all on function public.matrix_v2_full_import_preview_uat_v1(jsonb,text),
  public.matrix_v2_full_import_apply_uat_v1(jsonb,text)
  from public,anon,authenticated;
grant execute on function public.matrix_v2_full_import_preview_uat_v1(jsonb,text),
  public.matrix_v2_full_import_apply_uat_v1(jsonb,text)
  to authenticated;

comment on function public.matrix_v2_full_import_apply_uat_v1(jsonb,text) is
  'UAT-only atomic restore of every business input from one GRAFIK PRO workbook; strict OWNER/ADMIN boundary.';

notify pgrst,'reload schema';
