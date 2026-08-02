-- End-to-end Matrix configurability UAT. It creates a role, duty, location,
-- seasonal scenario, fourth strategy, scoped pay addition and scoped budget
-- only through public admin RPCs, then requests a real immutable snapshot.
-- Every change and queue message is rolled back.

begin;

insert into auth.users(
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,is_super_admin,created_at,updated_at
) values(
  '00000000-0000-0000-0000-000000000000',
  'd1a00000-0000-4000-8000-000000000001',
  'authenticated','authenticated','dynamic-matrix-owner@example.invalid','',now(),
  '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,false,now(),now()
);
insert into public.user_permissions(auth_user_id,app_role)
values('d1a00000-0000-4000-8000-000000000001','OWNER');

select set_config(
  'request.jwt.claim.sub',
  'd1a00000-0000-4000-8000-000000000001',
  true
);
select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;

do $$
declare
  v_draft uuid;
  v_role uuid;
  v_duty uuid;
  v_location uuid;
  v_shift uuid;
  v_scenario uuid;
  v_parent_scenario uuid;
  v_strategy uuid;
  v_currency text;
  v_timezone text;
  v_publish_from date;
  v_request_month date;
  v_result jsonb;
  v_run jsonb;
  v_rejected boolean:=false;
begin
  if auth.uid() is null then raise exception 'OWNER_TEST_IDENTITY_MISSING'; end if;

  -- A production Matrix can start in the middle of the current month. Publish
  -- the disposable draft no earlier than that active version and request the
  -- first complete month whose first day is covered by the published Matrix.
  select greatest(
    active_matrix.effective_from,
    date_trunc('month',current_date)::date
  ) into v_publish_from
  from public.matrix_versions active_matrix
  where active_matrix.status='ACTIVE' and active_matrix.schema_version>=2
  order by active_matrix.version desc limit 1;
  v_publish_from:=coalesce(
    v_publish_from,date_trunc('month',current_date)::date
  );
  v_request_month:=case
    when v_publish_from=date_trunc('month',v_publish_from)::date
      then v_publish_from
    else (date_trunc('month',v_publish_from)+interval '1 month')::date
  end;

  v_draft:=public.matrix_v2_create_draft('Dynamic Matrix v2 UAT');
  select upper(mv.settings->>'currency'),mv.settings->>'timezone'
    into v_currency,v_timezone
  from public.matrix_versions mv where mv.id=v_draft;

  v_result:=public.matrix_v2_admin_save('ROLE',null,jsonb_build_object(
    'code','SEASONAL_CONCIERGE','name','Konsjerż sezonowy',
    'color','#3355aa','sortOrder',910,'active',true
  ));
  v_role:=(v_result->>'id')::uuid;
  v_result:=public.matrix_v2_admin_save('DUTY',null,jsonb_build_object(
    'code','VIP_HOST','name','Opieka nad gościem VIP',
    'description','Konfigurowalny obowiązek sezonowy',
    'color','#aa5533','sortOrder',910,'active',true
  ));
  v_duty:=(v_result->>'id')::uuid;
  v_result:=public.matrix_v2_admin_save('LOCATION',null,jsonb_build_object(
    'code','ROOFTOP_UAT','name','Taras sezonowy',
    'timezone',v_timezone,'sortOrder',910,'active',true
  ));
  v_location:=(v_result->>'id')::uuid;
  v_result:=public.matrix_v2_admin_save('SHIFT',null,jsonb_build_object(
    'locationId',v_location,'code','SEASON_EVENING','name','Wieczór sezonowy',
    'startsAt','16:00','endsAt','23:30','endsNextDay',false,
    'days',jsonb_build_array(1,2,3,4,5,6,7),'sortOrder',910,'active',true
  ));
  v_shift:=(v_result->>'id')::uuid;
  perform public.matrix_v2_admin_save('ROLE_DUTY',null,jsonb_build_object(
    'roleId',v_role,'dutyId',v_duty,
    'assignmentMode','REQUIRED','minimumCount',1
  ));

  select s.id into v_parent_scenario
  from public.matrix_scenarios_v2 s
  where s.matrix_version_id=v_draft and s.active and s.is_default;
  v_result:=public.matrix_v2_admin_save('SCENARIO',null,jsonb_build_object(
    'code','HIGH_SEASON_UAT','name','Wysoki sezon UAT',
    'description','Większa obsada i osobny budżet bez zmiany kodu',
    'parentScenarioId',v_parent_scenario,'color','#cc7722',
    'isDefault',false,'active',true,'sortOrder',910
  ));
  v_scenario:=(v_result->>'id')::uuid;
  perform public.matrix_v2_admin_save('STAFFING_RULE',null,jsonb_build_object(
    'scenarioId',v_scenario,'shiftTemplateId',v_shift,
    'roleId',v_role,'dutyId',v_duty,
    'operation','SET','countValue',2,'active',true,
    'sourceMetadata',jsonb_build_object('test','dynamic-matrix-v2')
  ));

  v_result:=public.matrix_v2_admin_save('STRATEGY',null,jsonb_build_object(
    'code','SEASONAL_SERVICE_UAT','name','Obsługa sezonowa UAT',
    'description','Czwarta, dynamicznie dodana strategia',
    'solverCode','CP_SAT','sortOrder',910,'active',true
  ));
  v_strategy:=(v_result->>'id')::uuid;
  perform public.matrix_v2_admin_save('OBJECTIVE',null,jsonb_build_object(
    'strategyId',v_strategy,'tier',1,'sortOrder',1,
    'metricCode','UNFILLED','direction','MINIMIZE',
    'weight',1,'tolerance',0,'active',true
  ));
  perform public.matrix_v2_admin_save('OBJECTIVE',null,jsonb_build_object(
    'strategyId',v_strategy,'tier',2,'sortOrder',1,
    'metricCode','TOTAL_COST','direction','MINIMIZE',
    'weight',1,'tolerance',0,'active',true
  ));
  -- The three existing links remain only on the parent scenario. The child
  -- adds one strategy, proving that snapshot resolution inherits an arbitrary
  -- strategy set instead of expecting three hard-coded variants.
  perform public.matrix_v2_admin_save(
    'SCENARIO_STRATEGY',null,jsonb_build_object(
      'scenarioId',v_scenario,'strategyId',v_strategy,
      'sortOrder',910,'active',true,
      'objectiveOverrides',jsonb_build_object(
        'TOTAL_COST',jsonb_build_object('weight',2)
      ),
      'solverOverrides',jsonb_build_object('maxTimeSeconds',120)
    )
  );

  -- Parent and child overrides are individually legal but their resolved
  -- combination is not: MAX objectives cannot carry targetValue. Publication
  -- must validate the deep merge used by the snapshot and reject it.
  perform public.matrix_v2_admin_save(
    'SCENARIO_STRATEGY',null,jsonb_build_object(
      'scenarioId',v_parent_scenario,'strategyId',v_strategy,
      'sortOrder',910,'active',true,
      'objectiveOverrides',jsonb_build_object(
        'TOTAL_COST',jsonb_build_object('direction','MAXIMIZE')
      ),'solverOverrides',jsonb_build_object()
    )
  );
  perform public.matrix_v2_admin_save(
    'SCENARIO_STRATEGY',null,jsonb_build_object(
      'scenarioId',v_scenario,'strategyId',v_strategy,
      'sortOrder',910,'active',true,
      'objectiveOverrides',jsonb_build_object(
        'TOTAL_COST',jsonb_build_object(
          'weight',2,'parameters',jsonb_build_object('targetValue',100)
        )
      ),'solverOverrides',jsonb_build_object('maxTimeSeconds',120)
    )
  );
  begin
    perform public.matrix_v2_publish_draft(v_publish_from);
  exception when others then
    if position('INVALID_RESOLVED_SCENARIO_OBJECTIVE' in sqlerrm)=0 then
      raise;
    end if;
    v_rejected:=true;
  end;
  if not v_rejected then
    raise exception 'INVALID_INHERITED_OBJECTIVE_WAS_PUBLISHED';
  end if;
  perform public.matrix_v2_admin_save(
    'SCENARIO_STRATEGY',null,jsonb_build_object(
      'scenarioId',v_parent_scenario,'strategyId',v_strategy,
      'sortOrder',910,'active',false,
      'objectiveOverrides',jsonb_build_object(),
      'solverOverrides',jsonb_build_object()
    )
  );
  perform public.matrix_v2_admin_save(
    'SCENARIO_STRATEGY',null,jsonb_build_object(
      'scenarioId',v_scenario,'strategyId',v_strategy,
      'sortOrder',910,'active',true,
      'objectiveOverrides',jsonb_build_object(
        'TOTAL_COST',jsonb_build_object('weight',2)
      ),'solverOverrides',jsonb_build_object('maxTimeSeconds',120)
    )
  );

  perform public.matrix_v2_admin_save('PAY_RULE',null,jsonb_build_object(
    'code','SEASONAL_VIP_DUTY_UAT','name','Dodatek VIP sezonowy UAT',
    'calculationMethod','FIXED_PER_SHIFT','amountMinor',2500,
    'currency',v_currency,'priority',20,'stackingGroup','SEASONAL_VIP_UAT',
    'stackingMode','STACK','days',jsonb_build_array(1,2,3,4,5,6,7),
    'roleIds',jsonb_build_array(v_role),'dutyIds',jsonb_build_array(v_duty),
    'locationIds',jsonb_build_array(v_location),
    'shiftIds',jsonb_build_array(v_shift),'active',true
  ));
  perform public.matrix_v2_admin_save('SCENARIO_BUDGET',null,jsonb_build_object(
    'scenarioId',v_scenario,'budgetMonth',v_request_month,
    'locationId',v_location,'roleId',v_role,'dutyId',v_duty,
    'operation','SET','amountMinor',500000000,'currency',v_currency,
    'hardLimit',true,'warningPercent',90,
    'sourceMetadata',jsonb_build_object('test','dynamic-matrix-v2')
  ));

  perform public.matrix_v2_publish_draft(v_publish_from);
  -- The disposable transaction explicitly enables SHADOW. In production the
  -- same RPC remains blocked while DEFAULT_ENGINE is ALPHA15.
  perform public.solver_feature_flag_set(
    'SHADOW',jsonb_build_object(
      'test','dynamic-matrix-v2-uat','solverVersion','0.1.0'
    )
  );
  v_run:=public.optimizer_request_v2(
    v_request_month,v_scenario,'COMPANY',null,
    'Dynamic Matrix v2 UAT','dynamic-matrix-v2-uat-20260801'
  );
  if coalesce(v_run->'run'->>'status','')<>'QUEUED' then
    raise exception 'DYNAMIC_MATRIX_RUN_NOT_QUEUED: %',v_run;
  end if;
end;
$$;

reset role;

do $$
declare
  v_snapshot jsonb;
  v_strategy_count integer;
begin
  select snapshot into v_snapshot
  from solver_private.optimization_snapshots_v2 snapshot_row
  join public.optimization_runs_v2 run_row on run_row.id=snapshot_row.run_id
  where run_row.idempotency_key='dynamic-matrix-v2-uat-20260801';
  if v_snapshot is null then raise exception 'DYNAMIC_MATRIX_SNAPSHOT_MISSING'; end if;
  if coalesce(v_snapshot->>'matrixContentHash','') !~ '^[0-9a-f]{64}$'
    or coalesce(v_snapshot->>'workforceHash','') !~ '^[0-9a-f]{64}$' then
    raise exception 'PUBLISHED_MATRIX_HASHES_MISSING_FROM_SNAPSHOT';
  end if;

  v_strategy_count:=jsonb_array_length(v_snapshot->'strategies');
  if v_strategy_count<4 then
    raise exception 'DYNAMIC_STRATEGY_COUNT_TOO_LOW: %',v_strategy_count;
  end if;
  if not exists(
    select 1 from jsonb_array_elements(v_snapshot->'strategies') strategy
    cross join lateral jsonb_array_elements(strategy.value->'objectiveTerms') objective
    where strategy.value->>'code'='SEASONAL_SERVICE_UAT'
      and objective.value->>'metric'='TOTAL_COST'
      and (objective.value->>'weight')::integer=2
      and (strategy.value->>'timeLimitSeconds')::integer=120
  ) then raise exception 'SCENARIO_STRATEGY_OVERRIDE_NOT_RESOLVED'; end if;
  if not exists(
    select 1 from jsonb_array_elements(v_snapshot->'roles') item
    where item.value->>'code'='SEASONAL_CONCIERGE'
  ) then raise exception 'DYNAMIC_ROLE_MISSING_FROM_SNAPSHOT'; end if;
  if not exists(
    select 1 from jsonb_array_elements(v_snapshot->'duties') item
    where item.value->>'code'='VIP_HOST'
  ) then raise exception 'DYNAMIC_DUTY_MISSING_FROM_SNAPSHOT'; end if;
  if not exists(
    select 1 from jsonb_array_elements(v_snapshot->'locations') item
    where item.value->>'code'='ROOFTOP_UAT'
  ) then raise exception 'DYNAMIC_LOCATION_MISSING_FROM_SNAPSHOT'; end if;
  if not exists(
    select 1 from jsonb_array_elements(v_snapshot->'slots') item
    where item.value->>'roleId'=(
      select role_row.id::text from public.matrix_roles_v2 role_row
      join public.matrix_versions matrix_row on matrix_row.id=role_row.matrix_version_id
      where matrix_row.status='ACTIVE' and role_row.code='SEASONAL_CONCIERGE'
    ) and item.value->'dutyIds' ? (
      select duty_row.id::text from public.matrix_duties_v2 duty_row
      join public.matrix_versions matrix_row on matrix_row.id=duty_row.matrix_version_id
      where matrix_row.status='ACTIVE' and duty_row.code='VIP_HOST'
    )
  ) then raise exception 'SEASONAL_STAFFING_SLOTS_MISSING'; end if;
  if not exists(
    select 1 from jsonb_array_elements(v_snapshot->'payRules') item
    where item.value->>'id'=(
      select pay_row.id::text from public.matrix_pay_rules_v2 pay_row
      join public.matrix_versions matrix_row on matrix_row.id=pay_row.matrix_version_id
      where matrix_row.status='ACTIVE' and pay_row.code='SEASONAL_VIP_DUTY_UAT'
    )
  ) then raise exception 'SCOPED_PAY_RULE_MISSING'; end if;
  if not exists(
    select 1 from jsonb_array_elements(v_snapshot->'budgets') item
    where item.value->>'roleId' is not null
      and item.value->>'locationId' is not null
      and item.value->>'dutyId' is not null
      and (item.value->>'hard')::boolean
  ) then raise exception 'SCOPED_SEASONAL_BUDGET_MISSING'; end if;
end;
$$;

rollback;
