-- B4F-101: finance visibility is a server-side data boundary, not only a UI choice.

create or replace function solver_private.redact_workspace_finance_uat_v1(
  p_payload jsonb,
  p_visibility text default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_visibility text:=coalesce(p_visibility,public.application_finance_visibility_current_uat_v1());
  v_result jsonb:=coalesce(p_payload,'{}'::jsonb);
  v_finance jsonb:=v_result->'finance';
  v_shift jsonb;
  v_assignment jsonb;
  v_shifts jsonb:='[]'::jsonb;
  v_assignments jsonb;
  v_variant jsonb;
  v_variants jsonb:='[]'::jsonb;
  v_budget_status jsonb;
begin
  if v_visibility not in ('NONE','BUDGET_ONLY','AGGREGATE','FULL') then
    v_visibility:='NONE';
  end if;
  if v_visibility='FULL' then return v_result; end if;

  for v_shift in select value from jsonb_array_elements(coalesce(v_result->'shifts','[]'::jsonb)) loop
    v_assignments:='[]'::jsonb;
    for v_assignment in select value from jsonb_array_elements(coalesce(v_shift->'assignments','[]'::jsonb)) loop
      v_assignments:=v_assignments||jsonb_build_array(v_assignment-'costMinor'-'cost_minor');
    end loop;
    v_shifts:=v_shifts||jsonb_build_array(jsonb_set(v_shift,'{assignments}',v_assignments,true));
  end loop;
  v_result:=jsonb_set(v_result,'{shifts}',v_shifts,true);

  for v_variant in select value from jsonb_array_elements(coalesce(v_result->'variants','[]'::jsonb)) loop
    if v_visibility='AGGREGATE' then
      v_variants:=v_variants||jsonb_build_array(v_variant);
    else
      v_variants:=v_variants||jsonb_build_array(v_variant-'finance'-'totalCostMinor'-'budgetMinor'-'currency');
    end if;
  end loop;
  v_result:=jsonb_set(v_result,'{variants}',v_variants,true);

  if v_visibility='AGGREGATE' then return v_result-'budgetStatus'; end if;
  if v_visibility='BUDGET_ONLY' then
    v_budget_status:=jsonb_build_object(
      'configured',v_finance is not null and v_finance->'budgetMinor' is not null
        and jsonb_typeof(v_finance->'budgetMinor')<>'null',
      'withinBudget',case
        when v_finance is null or v_finance->'budgetMinor' is null
          or jsonb_typeof(v_finance->'budgetMinor')='null' then null
        else (v_finance->>'totalCostMinor')::numeric <= (v_finance->>'budgetMinor')::numeric
      end
    );
    return jsonb_set(v_result-'finance','{budgetStatus}',v_budget_status,true);
  end if;
  return (v_result-'finance'-'budgetStatus');
end;
$$;

revoke all on function solver_private.redact_workspace_finance_uat_v1(jsonb,text)
  from public,anon,authenticated;

create or replace function public.optimizer_variant_workspace_uat_v2(p_variant_id uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_run uuid; v_context jsonb; v_workspace jsonb; v_visibility text;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select run.id,jsonb_build_object('type','VARIANT_PREVIEW','runId',run.id,
    'engine',run.request_engine,'requestEngine',run.request_engine,'month',run.month,
    'name',variant.name,'scenario',jsonb_build_object('id',scenario.id,'name',scenario.name),
    'matrixVersionId',run.matrix_version_id)
  into v_run,v_context from public.plan_variants_v2 variant
  join public.optimization_runs_v2 run on run.id=variant.run_id
  join public.matrix_scenarios_v2 scenario on scenario.id=run.scenario_id
  where variant.id=p_variant_id;
  if v_run is null or not solver_private.can_access_run_v2(v_run) then raise exception 'VARIANT_NOT_FOUND'; end if;
  v_visibility:=public.application_finance_visibility_current_uat_v1();
  v_workspace:=solver_private.variant_set_workspace_v2(array[p_variant_id],v_context,v_visibility<>'NONE');
  v_workspace:=solver_private.alpha16_enrich_workspace_issues_v2(v_workspace,array[p_variant_id]);
  return solver_private.redact_workspace_finance_uat_v1(v_workspace,v_visibility);
end;
$$;

create or replace function public.optimizer_leader_variant_workspace_uat_v1(p_variant_id uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_variant public.plan_variants_v2%rowtype; v_context jsonb; v_workspace jsonb; v_visibility text;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select variant.* into v_variant from public.plan_variants_v2 variant
  where variant.id=p_variant_id and variant.variant_kind='LEADER_COPY';
  if v_variant.id is null or not solver_private.can_access_run_v2(v_variant.run_id) then raise exception 'LEADER_VARIANT_NOT_FOUND'; end if;
  select jsonb_build_object('type','LEADER_VARIANT','runId',run.id,'engine',run.request_engine,
    'month',run.month,'name',v_variant.name,'scenario',jsonb_build_object('id',scenario.id,'name',scenario.name),
    'matrixVersionId',run.matrix_version_id,'variantKind','LEADER_COPY','sourceVariantId',v_variant.source_variant_id,
    'revision',v_variant.revision,'lastEditedAt',v_variant.last_edited_at)
  into v_context from public.optimization_runs_v2 run
  join public.matrix_scenarios_v2 scenario on scenario.id=run.scenario_id where run.id=v_variant.run_id;
  v_visibility:=public.application_finance_visibility_current_uat_v1();
  v_workspace:=solver_private.variant_set_workspace_v2(array[p_variant_id],v_context,v_visibility<>'NONE');
  v_workspace:=solver_private.alpha16_enrich_workspace_issues_v2(v_workspace,array[p_variant_id]);
  return solver_private.redact_workspace_finance_uat_v1(v_workspace,v_visibility);
end;
$$;

create or replace function public.optimizer_selected_variant_workspace_v2(p_run_id uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_variant_id uuid; v_visibility text; v_context jsonb; v_workspace jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not solver_private.can_access_run_v2(p_run_id) then raise exception 'RUN_NOT_FOUND'; end if;
  select v.id,jsonb_build_object('type','SELECTED_VARIANT','runId',r.id,'engine',r.request_engine,
    'requestEngine',r.request_engine,'month',r.month,'name',r.name,
    'scenario',jsonb_build_object('id',s.id,'name',s.name),'matrixVersionId',r.matrix_version_id)
  into v_variant_id,v_context from public.optimization_runs_v2 r
  join public.plan_variants_v2 v on v.run_id=r.id and v.selected
  join public.matrix_scenarios_v2 s on s.id=r.scenario_id where r.id=p_run_id;
  if v_variant_id is null then raise exception 'SELECTED_VARIANT_NOT_FOUND'; end if;
  v_visibility:=public.application_finance_visibility_current_uat_v1();
  v_workspace:=solver_private.variant_set_workspace_v2(array[v_variant_id],v_context,v_visibility<>'NONE');
  return solver_private.redact_workspace_finance_uat_v1(v_workspace,v_visibility);
end;
$$;

create or replace function public.optimizer_published_schedule_v2(p_schedule_id uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_schedule public.published_schedules_v2%rowtype; v_variant_ids uuid[]; v_context jsonb;
  v_visibility text; v_workspace jsonb; v_finance jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE')
    or public.has_app_role('VERIFIER')) then raise exception 'FORBIDDEN'; end if;
  select * into v_schedule from public.published_schedules_v2 s where s.id=p_schedule_id;
  if v_schedule.id is null then raise exception 'PUBLISHED_SCHEDULE_NOT_FOUND'; end if;
  select array_agg(sv.variant_id order by sv.ordinal) into v_variant_ids
  from public.published_schedule_variants_v2 sv where sv.schedule_id=v_schedule.id;
  if coalesce(cardinality(v_variant_ids),0)=0 then raise exception 'PUBLISHED_SCHEDULE_EMPTY'; end if;
  select jsonb_build_object('type','PUBLISHED_SCHEDULE','scheduleId',v_schedule.id,
    'sourceType',v_schedule.source_type,'name',v_schedule.name,'status',v_schedule.status,
    'month',v_schedule.month,'scenario',jsonb_build_object('id',s.id,'name',s.name),
    'matrixVersionId',v_schedule.matrix_version_id,'publishedAt',v_schedule.published_at,
    'archivedAt',v_schedule.archived_at)
  into v_context from public.matrix_scenarios_v2 s where s.id=v_schedule.scenario_id;
  v_visibility:=public.application_finance_visibility_current_uat_v1();
  v_workspace:=solver_private.variant_set_workspace_v2(v_variant_ids,v_context,v_visibility<>'NONE');
  if v_visibility<>'NONE' then
    select jsonb_build_object('baseCostMinor',f.base_cost_minor,'additionsCostMinor',f.additions_cost_minor,
      'totalCostMinor',f.total_cost_minor,'currency',f.currency,'budgetMinor',f.budget_minor)
    into v_finance from solver_private.published_schedule_finance_v2 f where f.schedule_id=v_schedule.id;
    v_workspace:=jsonb_set(v_workspace,'{finance}',coalesce(v_finance,'null'::jsonb),true);
  end if;
  return solver_private.redact_workspace_finance_uat_v1(v_workspace,v_visibility);
end;
$$;

revoke all on function public.optimizer_variant_workspace_uat_v2(uuid),
  public.optimizer_leader_variant_workspace_uat_v1(uuid),
  public.optimizer_selected_variant_workspace_v2(uuid),
  public.optimizer_published_schedule_v2(uuid) from public,anon,authenticated;
grant execute on function public.optimizer_variant_workspace_uat_v2(uuid),
  public.optimizer_leader_variant_workspace_uat_v1(uuid),
  public.optimizer_selected_variant_workspace_v2(uuid),
  public.optimizer_published_schedule_v2(uuid) to authenticated;

comment on function solver_private.redact_workspace_finance_uat_v1(jsonb,text) is
  'B4F-101 server-side redaction for NONE, BUDGET_ONLY, AGGREGATE and FULL finance visibility.';

create or replace function public.optimizer_variants_v2(p_run_id uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_visibility text; v_variants jsonb;
begin
  if not solver_private.can_access_run_v2(p_run_id) then raise exception 'RUN_NOT_FOUND'; end if;
  v_visibility:=public.application_finance_visibility_current_uat_v1();
  select coalesce(jsonb_agg(
    case
      when v_visibility in ('FULL','AGGREGATE') then item
      when v_visibility='BUDGET_ONLY' then
        item-'totalCostMinor'-'budgetMinor'-'currency'||jsonb_build_object('budgetStatus',jsonb_build_object(
          'configured',item->'budgetMinor' is not null and jsonb_typeof(item->'budgetMinor')<>'null',
          'withinBudget',case when item->'budgetMinor' is null or jsonb_typeof(item->'budgetMinor')='null' then null
            else (item->>'totalCostMinor')::numeric <= (item->>'budgetMinor')::numeric end))
      else item-'totalCostMinor'-'budgetMinor'-'currency'
    end order by ordinal
  ),'[]'::jsonb) into v_variants
  from (
    select run_strategy.ordinal,jsonb_build_object(
      'id',variant.id,'name',variant.name,
      'strategy',jsonb_build_object('id',strategy.id,'name',strategy.name,'description',strategy.description),
      'status',variant.status,'hardViolations',variant.hard_violations,
      'assignmentCount',variant.assignment_count,'unfilledCount',variant.unfilled_count,
      'totalCostMinor',finance.total_cost_minor,'budgetMinor',finance.budget_minor,'currency',finance.currency,
      'solverStatus',variant.solver_status,'recommended',variant.recommended,'selected',variant.selected,
      'equivalentToVariantId',variant.equivalent_to_variant_id,'metrics',variant.metrics) item
    from public.plan_variants_v2 variant
    join public.optimization_run_strategies_v2 run_strategy on run_strategy.id=variant.run_strategy_id
    join public.matrix_strategies_v2 strategy on strategy.id=variant.strategy_id
    left join solver_private.plan_variant_finance_v2 finance on finance.variant_id=variant.id
    where variant.run_id=p_run_id and variant.variant_kind='GENERATED'
  ) source;
  return jsonb_build_object('runId',p_run_id,'variants',v_variants);
end;
$$;

-- The run history was an additional route around the UI policy. Keep the old
-- authorization/query semantics, then remove money before the payload leaves SQL.
alter function public.optimizer_runs_catalog_alpha16(date,text,uuid)
  rename to optimizer_runs_catalog_before_b4f101_alpha16;

create function public.optimizer_runs_catalog_alpha16(
  p_month date,
  p_scope_type text default 'COMPANY',
  p_scope_role_id uuid default null
) returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_payload jsonb; v_visibility text; v_run jsonb; v_variant jsonb;
  v_runs jsonb:='[]'::jsonb; v_variants jsonb;
begin
  v_payload:=public.optimizer_runs_catalog_before_b4f101_alpha16(p_month,p_scope_type,p_scope_role_id);
  v_visibility:=public.application_finance_visibility_current_uat_v1();
  if v_visibility in ('FULL','AGGREGATE') then return v_payload; end if;
  for v_run in select value from jsonb_array_elements(coalesce(v_payload->'runs','[]'::jsonb)) loop
    v_variants:='[]'::jsonb;
    for v_variant in select value from jsonb_array_elements(coalesce(v_run->'variants','[]'::jsonb)) loop
      v_variants:=v_variants||jsonb_build_array(v_variant-'totalCostMinor'-'currency');
    end loop;
    v_runs:=v_runs||jsonb_build_array(jsonb_set(v_run,'{variants}',v_variants,true));
  end loop;
  return jsonb_set(v_payload,'{runs}',v_runs,true);
end;
$$;

revoke all on function public.optimizer_runs_catalog_before_b4f101_alpha16(date,text,uuid)
  from public,anon,authenticated;
revoke all on function public.optimizer_runs_catalog_alpha16(date,text,uuid),
  public.optimizer_variants_v2(uuid) from public,anon,authenticated;
grant execute on function public.optimizer_runs_catalog_alpha16(date,text,uuid),
  public.optimizer_variants_v2(uuid) to authenticated;
