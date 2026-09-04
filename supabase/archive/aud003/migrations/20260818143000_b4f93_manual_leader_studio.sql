-- B4F-93: leader studio can start from demand without running the optimizer.

create or replace function public.optimizer_create_manual_leader_studio_uat_v1(
  p_month date,
  p_scenario_id uuid,
  p_scope_type text,
  p_scope_role_id uuid,
  p_name text,
  p_solver_version text
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid:=auth.uid();
  v_month date:=date_trunc('month',p_month)::date;
  v_matrix_id uuid;
  v_run_id uuid:=gen_random_uuid();
  v_variant_id uuid:=gen_random_uuid();
  v_snapshot jsonb;
  v_snapshot_hash text;
  v_solution_hash text;
  v_strategy_id uuid;
  v_run_strategy_id uuid;
  v_name text:=trim(coalesce(p_name,''));
  v_unfilled integer;
  v_currency text;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_scope_type not in ('COMPANY','ROLE') then raise exception 'INVALID_SCOPE_TYPE'; end if;
  if (p_scope_type='ROLE') is distinct from (p_scope_role_id is not null) then
    raise exception 'INVALID_SCOPE_ROLE';
  end if;
  if length(v_name) not between 1 and 200 then raise exception 'INVALID_PLAN_NAME'; end if;
  if length(trim(coalesce(p_solver_version,''))) not between 1 and 200 then
    raise exception 'INVALID_SOLVER_VERSION';
  end if;

  select version.id into v_matrix_id
  from public.matrix_versions version
  where version.status in ('ACTIVE','ARCHIVED') and version.schema_version>=2
    and version.effective_from<=v_month
    and coalesce(version.content_hash,'') ~ '^[0-9a-f]{64}$'
    and coalesce(version.workforce_hash,'') ~ '^[0-9a-f]{64}$'
  order by version.effective_from desc,version.version desc limit 1;
  if v_matrix_id is null then raise exception 'MATRIX_V2_FOR_MONTH_NOT_FOUND'; end if;
  if not exists(select 1 from public.matrix_scenarios_v2 scenario
    where scenario.id=p_scenario_id and scenario.matrix_version_id=v_matrix_id and scenario.active)
  then raise exception 'SCENARIO_NOT_FOUND'; end if;

  if p_scope_type='COMPANY' and not (
    public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  ) then raise exception 'COMPANY_SCOPE_FORBIDDEN'; end if;
  if p_scope_type='ROLE' and not (
    public.has_app_role('OWNER') or public.has_app_role('ADMIN') or exists(
      select 1 from public.matrix_scope_grants_v2 grant_row
      join public.matrix_roles_v2 role on role.id=p_scope_role_id
      where grant_row.auth_user_id=v_actor and grant_row.active
        and grant_row.app_role='ROLE_MANAGER'
        and (grant_row.role_logical_id is null or grant_row.role_logical_id=role.logical_id)
    )
  ) then raise exception 'ROLE_SCOPE_FORBIDDEN'; end if;

  v_snapshot:=solver_private.build_snapshot_payload_v2(
    v_run_id,v_month,v_matrix_id,p_scenario_id,p_scope_type,p_scope_role_id
  );
  select (strategy.value->>'id')::uuid into v_strategy_id
  from jsonb_array_elements(coalesce(v_snapshot->'strategies','[]'::jsonb))
    with ordinality strategy(value,ordinality)
  order by strategy.ordinality limit 1;
  if v_strategy_id is null then raise exception 'SNAPSHOT_HAS_NO_STRATEGIES'; end if;
  v_unfilled:=jsonb_array_length(coalesce(v_snapshot->'slots','[]'::jsonb));
  v_currency:=coalesce(nullif(v_snapshot->>'currency',''),'PLN');
  v_snapshot_hash:=encode(extensions.digest(convert_to(
    solver_private.canonical_json_v2(v_snapshot),'UTF8'
  ),'sha256'),'hex');
  v_solution_hash:=encode(extensions.digest(convert_to(
    solver_private.canonical_json_v2(jsonb_build_object(
      'assignments','[]'::jsonb,
      'unfilledSlotIds',coalesce((select jsonb_agg(slot.value->>'slotId' order by slot.ordinality)
        from jsonb_array_elements(coalesce(v_snapshot->'slots','[]'::jsonb))
          with ordinality slot(value,ordinality)),'[]'::jsonb)
    )),'UTF8'
  ),'sha256'),'hex');

  insert into public.optimization_runs_v2(
    id,idempotency_key,month,matrix_version_id,scenario_id,scope_type,scope_role_id,
    name,status,phase,progress,requested_by,snapshot_hash,request_engine,solver_version,
    finished_at
  ) values(
    v_run_id,'manual-studio-'||v_run_id::text,v_month,v_matrix_id,p_scenario_id,
    p_scope_type,p_scope_role_id,v_name,'READY','MANUAL_STUDIO',100,v_actor,
    v_snapshot_hash,'ORTOOLS_V2',trim(p_solver_version),now()
  );
  insert into public.optimization_run_strategies_v2(
    run_id,strategy_id,ordinal,status,phase,progress,metrics,started_at,finished_at
  ) values(v_run_id,v_strategy_id,1,'READY','MANUAL_STUDIO',100,
    jsonb_build_object('manualStudio',true),now(),now()) returning id into v_run_strategy_id;
  insert into solver_private.optimization_snapshots_v2(run_id,schema_version,snapshot_hash,snapshot)
    values(v_run_id,2,v_snapshot_hash,v_snapshot);

  insert into public.plan_variants_v2(
    id,run_id,run_strategy_id,strategy_id,name,status,hard_violations,assignment_count,
    unfilled_count,solver_status,solution_hash,metrics,recommended,selected,snapshot_hash,
    selected_at,selected_by,variant_kind,revision,last_edited_at,last_edited_by
  ) values(
    v_variant_id,v_run_id,v_run_strategy_id,v_strategy_id,v_name,'SELECTED',0,0,
    v_unfilled,'FEASIBLE',v_solution_hash,jsonb_build_object('manualStudio',true,'UNFILLED',v_unfilled),
    false,true,v_snapshot_hash,now(),v_actor,'LEADER_COPY',0,now(),v_actor
  );
  insert into public.plan_shifts_v2(
    variant_id,slot_group_key,shift_template_id,location_id,shift_date,starts_at,ends_at,
    source_type,source_id
  ) select distinct on (slot.value->>'occurrenceId')
    v_variant_id,slot.value->>'occurrenceId',(slot.value->>'shiftTemplateId')::uuid,
    (slot.value->>'locationId')::uuid,(slot.value->>'date')::date,
    (slot.value->>'start')::timestamptz,(slot.value->>'end')::timestamptz,'MATRIX',
    nullif(slot.value->>'demandId','')::uuid
  from jsonb_array_elements(coalesce(v_snapshot->'slots','[]'::jsonb)) slot(value)
  order by slot.value->>'occurrenceId',slot.value->>'slotId';
  insert into public.plan_issues_v2(
    variant_id,shift_id,slot_key,issue_code,severity,role_id,duty_id,
    required_count,assigned_count,message,metadata
  ) select v_variant_id,shift.id,slot.value->>'slotId','UNFILLED_SLOT','WARNING',
    (slot.value->>'roleId')::uuid,
    case when jsonb_array_length(coalesce(slot.value->'dutyIds','[]'::jsonb))=1
      then (slot.value->'dutyIds'->>0)::uuid else null end,
    1,0,'Miejsce oczekuje na ręczną obsadę w Studio lidera.',
    jsonb_build_object('manualStudio',true,'demandId',slot.value->>'demandId')
  from jsonb_array_elements(coalesce(v_snapshot->'slots','[]'::jsonb)) slot(value)
  join public.plan_shifts_v2 shift on shift.variant_id=v_variant_id
    and shift.slot_group_key=slot.value->>'occurrenceId';
  insert into solver_private.plan_variant_finance_v2(
    variant_id,base_cost_units,additions_cost_units,total_cost_units,
    base_cost_minor,additions_cost_minor,total_cost_minor,currency,budget_minor,
    hard_budget_exceeded,breakdown
  ) values(v_variant_id,0,0,0,0,0,0,v_currency,null,false,
    jsonb_build_object('manualStudio',true,'currency',v_currency));
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'plan_variant_v2',v_variant_id::text,'CREATE_MANUAL_LEADER_STUDIO',
    jsonb_build_object('runId',v_run_id,'month',v_month,'scopeType',p_scope_type,
      'scopeRoleId',p_scope_role_id,'scenarioId',p_scenario_id,'unfilledCount',v_unfilled));
  return jsonb_build_object('runId',v_run_id,'variantId',v_variant_id,'name',v_name,
    'revision',0,'assignmentCount',0,'unfilledCount',v_unfilled);
end;
$$;

revoke all on function public.optimizer_create_manual_leader_studio_uat_v1(
  date,uuid,text,uuid,text,text
) from public,anon,authenticated;
grant execute on function public.optimizer_create_manual_leader_studio_uat_v1(
  date,uuid,text,uuid,text,text
) to authenticated;

comment on function public.optimizer_create_manual_leader_studio_uat_v1(date,uuid,text,uuid,text,text)
is 'B4F-93: creates an auditable leader working schedule from immutable demand without dispatching the optimizer.';
