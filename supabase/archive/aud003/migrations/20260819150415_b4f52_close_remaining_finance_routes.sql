-- B4F-52/B4F-101: finish the server-side finance boundary for legacy RPCs.
-- The application policy is authoritative even when a caller invokes an old
-- workspace or optimizer function directly through PostgREST.

begin;

alter function public.plan_workspace(date,uuid)
  rename to plan_workspace_before_b4f52_uat_v1;

create function public.plan_workspace(
  p_month date default null,
  p_plan_id uuid default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_payload jsonb:=public.plan_workspace_before_b4f52_uat_v1(p_month,p_plan_id);
  v_visibility text:=public.application_finance_visibility_current_uat_v1();
  v_assignment jsonb;
  v_assignments jsonb:='[]'::jsonb;
  v_plan jsonb:=coalesce(v_payload->'plan','{}'::jsonb);
  v_budget jsonb:=coalesce(v_payload->'budget','{}'::jsonb);
  v_total_cost numeric:=nullif(v_plan->>'total_cost','')::numeric;
  v_budget_amount numeric:=nullif(v_budget->>'amount','')::numeric;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if v_visibility='FULL' then
    return v_payload||jsonb_build_object('financeVisibility',v_visibility);
  end if;

  for v_assignment in
    select value from jsonb_array_elements(coalesce(v_payload->'assignments','[]'::jsonb))
  loop
    v_assignments:=v_assignments||jsonb_build_array(v_assignment-'cost');
  end loop;
  v_payload:=jsonb_set(v_payload,'{assignments}',v_assignments,true);

  if v_visibility='AGGREGATE' then
    return v_payload||jsonb_build_object('financeVisibility',v_visibility);
  end if;

  v_payload:=jsonb_set(v_payload,'{plan}',v_plan-'total_cost',true);
  if v_visibility='BUDGET_ONLY' then
    v_payload:=jsonb_set(v_payload,'{budget}',jsonb_build_object(
      'configured',v_budget_amount is not null and v_budget_amount>0,
      'withinBudget',case when v_total_cost is null or v_budget_amount is null or v_budget_amount<=0
        then null else v_total_cost<=v_budget_amount end,
      'hardLimit',case when v_budget='{}'::jsonb then null else v_budget->'hard_limit' end
    ),true);
    return v_payload||jsonb_build_object('financeVisibility',v_visibility);
  end if;

  return (v_payload-'budget')||jsonb_build_object('financeVisibility','NONE');
end;
$$;

alter function public.matrix_v2_workspace(date)
  rename to matrix_v2_workspace_before_b4f52_uat_v1;

create function public.matrix_v2_workspace(p_month date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_payload jsonb:=public.matrix_v2_workspace_before_b4f52_uat_v1(p_month);
  v_visibility text:=public.application_finance_visibility_current_uat_v1();
  v_worker jsonb;
  v_workers jsonb:='[]'::jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if v_visibility='FULL' then
    return v_payload||jsonb_build_object('financeVisibility',v_visibility,'financeVisible',true);
  end if;

  for v_worker in
    select value from jsonb_array_elements(coalesce(v_payload->'adHocWorkers','[]'::jsonb))
  loop
    v_workers:=v_workers||jsonb_build_array(
      v_worker-'base_rate_minor'-'rateMinor'-'approved_rate_minor'-'currency'
    );
  end loop;

  v_payload:=jsonb_set(v_payload,'{adHocWorkers}',v_workers,true);
  v_payload:=jsonb_set(v_payload,'{payRules}','[]'::jsonb,true);
  v_payload:=jsonb_set(v_payload,'{payRuleRoles}','[]'::jsonb,true);
  v_payload:=jsonb_set(v_payload,'{payRuleDuties}','[]'::jsonb,true);
  v_payload:=jsonb_set(v_payload,'{payRuleLocations}','[]'::jsonb,true);
  v_payload:=jsonb_set(v_payload,'{payRuleShifts}','[]'::jsonb,true);
  v_payload:=jsonb_set(v_payload,'{scenarioPayRuleOverrides}','[]'::jsonb,true);
  v_payload:=jsonb_set(v_payload,'{scenarioBudgets}','[]'::jsonb,true);
  v_payload:=jsonb_set(v_payload,'{employeePayRates}','[]'::jsonb,true);
  v_payload:=jsonb_set(v_payload,'{financeVisible}','false'::jsonb,true);
  return v_payload||jsonb_build_object('financeVisibility',v_visibility);
end;
$$;

alter function public.monthly_budgets_get_uat_v1(date)
  rename to monthly_budgets_get_before_b4f52_uat_v1;

create function public.monthly_budgets_get_uat_v1(p_month date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_payload jsonb:=public.monthly_budgets_get_before_b4f52_uat_v1(p_month);
  v_visibility text:=public.application_finance_visibility_current_uat_v1();
  v_configured boolean:=jsonb_array_length(coalesce(v_payload->'lines','[]'::jsonb))>0;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if v_visibility in ('FULL','AGGREGATE') then
    return v_payload||jsonb_build_object('financeVisibility',v_visibility);
  end if;
  if v_visibility='BUDGET_ONLY' then
    return jsonb_build_object(
      'month',date_trunc('month',p_month)::date,
      'canEdit',false,
      'revision',null,
      'lines','[]'::jsonb,
      'budgetStatus',jsonb_build_object('configured',v_configured),
      'financeVisibility',v_visibility
    );
  end if;
  return jsonb_build_object(
    'month',date_trunc('month',p_month)::date,
    'canEdit',false,
    'revision',null,
    'lines','[]'::jsonb,
    'financeVisibility','NONE'
  );
end;
$$;

alter function public.optimizer_variants_v3(date)
  rename to optimizer_variants_before_b4f52_uat_v1;

create function public.optimizer_variants_v3(p_month date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_payload jsonb:=public.optimizer_variants_before_b4f52_uat_v1(p_month);
  v_visibility text:=public.application_finance_visibility_current_uat_v1();
  v_variant jsonb;
  v_variants jsonb:='[]'::jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if v_visibility in ('FULL','AGGREGATE') then return v_payload; end if;
  for v_variant in select value from jsonb_array_elements(coalesce(v_payload,'[]'::jsonb)) loop
    v_variants:=v_variants||jsonb_build_array(v_variant-'score'-'metrics');
  end loop;
  return v_variants;
end;
$$;

-- The Alpha 15/V3 and resumable V4 mutation APIs are not used by the active
-- OR-Tools V2 application. Their responses include raw cost data, so leaving
-- them executable would be a policy bypass for an authenticated caller.
revoke all on function public.optimizer_prepare(date,text,text,integer),
  public.optimizer_commit(uuid,text,jsonb),
  public.optimizer_prepare_v2(date,text,text,integer),
  public.optimizer_checkpoint_v2(uuid,integer,jsonb,jsonb),
  public.optimizer_run_state_v2(uuid),
  public.optimizer_finalize_v2(uuid,text,jsonb),
  public.optimizer_finalize_v3(uuid,text,jsonb),
  public.optimizer_save_init_v4(uuid,integer,jsonb,jsonb),
  public.optimizer_begin_finalize_v4(uuid,text,jsonb),
  public.optimizer_materialize_next_v4(uuid),
  public.optimizer_complete_finalize_v4(uuid),
  public.optimizer_abort_finalize_v4(uuid,text)
from public,anon,authenticated;

revoke all on function public.plan_workspace_before_b4f52_uat_v1(date,uuid),
  public.matrix_v2_workspace_before_b4f52_uat_v1(date),
  public.monthly_budgets_get_before_b4f52_uat_v1(date),
  public.optimizer_variants_before_b4f52_uat_v1(date),
  public.plan_workspace(date,uuid),
  public.matrix_v2_workspace(date),
  public.monthly_budgets_get_uat_v1(date),
  public.optimizer_variants_v3(date)
from public,anon,authenticated;

grant execute on function public.plan_workspace(date,uuid),
  public.matrix_v2_workspace(date),
  public.monthly_budgets_get_uat_v1(date),
  public.optimizer_variants_v3(date)
to authenticated;

comment on function public.plan_workspace(date,uuid) is
  'B4F-52 legacy plan workspace with server-side finance visibility redaction.';
comment on function public.matrix_v2_workspace(date) is
  'B4F-52 configuration workspace exposes exact finance configuration only at FULL visibility.';
comment on function public.monthly_budgets_get_uat_v1(date) is
  'B4F-52 monthly budgets respect FULL, AGGREGATE, BUDGET_ONLY and NONE visibility.';

notify pgrst,'reload schema';

commit;
