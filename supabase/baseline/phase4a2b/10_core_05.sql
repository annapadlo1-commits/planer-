-- Generated Phase 4A.2B neutral schema baseline.
-- Apply only to a fresh, isolated Supabase project through the reviewed runner.

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: redact_workspace_finance_uat_v1("jsonb", "text"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."redact_workspace_finance_uat_v1"("p_payload" "jsonb", "p_visibility" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "solver_private"."redact_workspace_finance_uat_v1"("p_payload" "jsonb", "p_visibility" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "redact_workspace_finance_uat_v1"("p_payload" "jsonb", "p_visibility" "text"); Type: COMMENT; Schema: solver_private; Owner: postgres
--

COMMENT ON FUNCTION "solver_private"."redact_workspace_finance_uat_v1"("p_payload" "jsonb", "p_visibility" "text") IS 'B4F-101 server-side redaction for NONE, BUDGET_ONLY, AGGREGATE and FULL finance visibility.';


--
-- Name: refresh_leader_variant_uat_v1("uuid", "uuid", "text"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."refresh_leader_variant_uat_v1"("p_variant_id" "uuid", "p_actor" "uuid", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_variant public.plan_variants_v2%rowtype;
  v_run public.optimization_runs_v2%rowtype;
  v_snapshot jsonb;
  v_payload jsonb;
  v_quoted jsonb;
  v_validation jsonb;
  v_base_units bigint:=0;
  v_total_units bigint:=0;
  v_budget_minor bigint;
  v_currency text;
begin
  select * into v_variant from public.plan_variants_v2 where id=p_variant_id for update;
  if v_variant.id is null or v_variant.variant_kind<>'LEADER_COPY' then
    raise exception 'LEADER_VARIANT_NOT_FOUND';
  end if;
  select * into v_run from public.optimization_runs_v2 where id=v_variant.run_id;
  select snapshot into v_snapshot from solver_private.optimization_snapshots_v2
    where run_id=v_variant.run_id;
  if v_run.id is null or v_snapshot is null then raise exception 'SNAPSHOT_NOT_FOUND'; end if;

  delete from solver_private.plan_assignment_cost_components_v2 component
  using public.plan_assignments_v2 assignment
  where assignment.variant_id=p_variant_id and component.assignment_id=assignment.id;
  v_payload:=solver_private.materialized_variant_payload_v2(
    array[p_variant_id],v_snapshot,v_variant.strategy_id
  );
  v_quoted:=solver_private.requote_variant_payload_v2(v_snapshot,v_payload);
  insert into solver_private.plan_assignment_cost_components_v2(
    assignment_id,pay_rule_id,component_code,amount_minor,quantity_minutes,
    calculation_basis
  )
  select assignment.id,
    case when component.value->>'ruleId'='BASE' then null
      else (component.value->>'ruleId')::uuid end,
    coalesce(nullif(component.value->>'calculationType',''),'UNKNOWN'),
    round((component.value->>'costUnits')::numeric/60)::bigint,
    (slot.value->>'durationMinutes')::integer,
    jsonb_build_object('costUnits',(component.value->>'costUnits')::bigint)
  from jsonb_array_elements(coalesce(v_quoted->'assignments','[]'::jsonb)) quoted
  join public.plan_assignments_v2 assignment
    on assignment.variant_id=p_variant_id and assignment.slot_key=quoted.value->>'slotId'
  join jsonb_array_elements(coalesce(v_snapshot->'slots','[]'::jsonb)) slot
    on slot.value->>'slotId'=assignment.slot_key
  cross join lateral jsonb_array_elements(coalesce(quoted.value->'costComponents','[]'::jsonb)) component;

  select coalesce(sum((component.calculation_basis->>'costUnits')::bigint),0),
    coalesce(sum((component.calculation_basis->>'costUnits')::bigint)
      filter(where component.pay_rule_id is null),0)
  into v_total_units,v_base_units
  from solver_private.plan_assignment_cost_components_v2 component
  join public.plan_assignments_v2 assignment on assignment.id=component.assignment_id
  where assignment.variant_id=p_variant_id;
  select finance.budget_minor,finance.currency into v_budget_minor,v_currency
    from solver_private.plan_variant_finance_v2 finance where finance.variant_id=p_variant_id;
  v_currency:=coalesce(v_currency,nullif(v_snapshot->>'currency',''),'PLN');
  insert into solver_private.plan_variant_finance_v2(
    variant_id,base_cost_units,additions_cost_units,total_cost_units,
    base_cost_minor,additions_cost_minor,total_cost_minor,currency,budget_minor,
    hard_budget_exceeded,breakdown
  ) values(
    p_variant_id,v_base_units,greatest(v_total_units-v_base_units,0),v_total_units,
    round(v_base_units::numeric/60),round(greatest(v_total_units-v_base_units,0)::numeric/60),
    round(v_total_units::numeric/60),v_currency,v_budget_minor,
    coalesce((v_snapshot->'budget'->>'hard')::boolean,false)
      and v_budget_minor is not null and v_total_units>v_budget_minor*60,
    jsonb_build_object('editedByLeader',true,'currency',v_currency)
  ) on conflict(variant_id) do update set
    base_cost_units=excluded.base_cost_units,
    additions_cost_units=excluded.additions_cost_units,
    total_cost_units=excluded.total_cost_units,
    base_cost_minor=excluded.base_cost_minor,
    additions_cost_minor=excluded.additions_cost_minor,
    total_cost_minor=excluded.total_cost_minor,
    currency=excluded.currency,budget_minor=excluded.budget_minor,
    hard_budget_exceeded=excluded.hard_budget_exceeded,breakdown=excluded.breakdown;

  v_payload:=solver_private.materialized_variant_payload_v2(
    array[p_variant_id],v_snapshot,v_variant.strategy_id
  );
  update public.plan_variants_v2 variant set
    assignment_count=(select count(*) from public.plan_assignments_v2 where variant_id=p_variant_id),
    unfilled_count=(select count(*) from public.plan_issues_v2
      where variant_id=p_variant_id and issue_code='UNFILLED_SLOT'),
    solution_hash=v_payload->>'solutionHash',
    metrics=(coalesce(variant.metrics,'{}'::jsonb)||jsonb_build_object(
      'UNFILLED',(select count(*) from public.plan_issues_v2
        where variant_id=p_variant_id and issue_code='UNFILLED_SLOT'),
      'leaderEdited',true
    )),
    hard_violations=0,revision=variant.revision+1,
    last_edited_at=now(),last_edited_by=p_actor
  where variant.id=p_variant_id;
  v_payload:=solver_private.materialized_variant_payload_v2(
    array[p_variant_id],v_snapshot,v_variant.strategy_id
  );
  v_validation:=solver_private.validate_variant_v2(v_snapshot,v_payload);
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(p_actor,'plan_variant_v2',p_variant_id::text,'EDIT_LEADER_COPY',
    jsonb_build_object('reason',p_reason,'validation',v_validation));
  return jsonb_build_object('variantId',p_variant_id,'validation',v_validation,
    'assignmentCount',(select assignment_count from public.plan_variants_v2 where id=p_variant_id),
    'unfilledCount',(select unfilled_count from public.plan_variants_v2 where id=p_variant_id),
    'revision',(select revision from public.plan_variants_v2 where id=p_variant_id));
end;
$$;


ALTER FUNCTION "solver_private"."refresh_leader_variant_uat_v1"("p_variant_id" "uuid", "p_actor" "uuid", "p_reason" "text") OWNER TO "postgres";

--
-- Name: replace_time_constraint_v2("uuid", "text", "tstzrange", "text", "text", "text", "uuid", timestamp with time zone); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."replace_time_constraint_v2"("p_employee_id" "uuid", "p_kind" "text", "p_time_range" "tstzrange", "p_source" "text", "p_source_record_key" "text", "p_note" "text", "p_actor" "uuid", "p_updated_at" timestamp with time zone) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_existing public.employee_time_constraints_v2%rowtype;
begin
  select * into v_existing
  from public.employee_time_constraints_v2 c
  where c.source_record_key=p_source_record_key
  order by (c.status='ACTIVE') desc,c.created_at desc,c.id
  limit 1 for update;

  if p_kind is null then
    if v_existing.id is not null and v_existing.status='ACTIVE' then
      update public.employee_time_constraints_v2
      set status='REVOKED',revoked_at=coalesce(p_updated_at,now()),
        updated_at=coalesce(p_updated_at,now())
      where id=v_existing.id;
    end if;
    return;
  end if;

  if v_existing.id is not null and v_existing.status='ACTIVE'
    and v_existing.employee_id=p_employee_id
    and v_existing.constraint_kind=p_kind
    and v_existing.time_range=p_time_range
    and v_existing.source=coalesce(nullif(p_source,''),'GRAFIK_PRO')
    and v_existing.note is not distinct from nullif(p_note,'') then
    update public.employee_time_constraints_v2
    set updated_at=coalesce(p_updated_at,now()),created_by=coalesce(p_actor,created_by)
    where id=v_existing.id;
    return;
  end if;

  if v_existing.id is not null then
    update public.employee_time_constraints_v2
    set status='REVOKED',revoked_at=coalesce(p_updated_at,now()),
      updated_at=coalesce(p_updated_at,now()),
      source_record_key=p_source_record_key||':superseded:'||v_existing.id::text
    where id=v_existing.id;
  end if;

  insert into public.employee_time_constraints_v2(
    employee_id,constraint_kind,time_range,source,source_record_key,priority,
    editable_by_employee,status,note,supersedes_id,created_by,updated_at
  ) values(
    p_employee_id,p_kind,p_time_range,
    coalesce(nullif(p_source,''),'GRAFIK_PRO'),p_source_record_key,
    case when upper(coalesce(p_source,'')) in ('KADROMIERZ','MANAGER','SYSTEM')
      then 300 else 100 end,
    upper(coalesce(p_source,''))='GRAFIK_PRO','ACTIVE',nullif(p_note,''),
    v_existing.id,p_actor,coalesce(p_updated_at,now())
  );
end;
$$;


ALTER FUNCTION "solver_private"."replace_time_constraint_v2"("p_employee_id" "uuid", "p_kind" "text", "p_time_range" "tstzrange", "p_source" "text", "p_source_record_key" "text", "p_note" "text", "p_actor" "uuid", "p_updated_at" timestamp with time zone) OWNER TO "postgres";

--
-- Name: requote_variant_payload_v2("jsonb", "jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."requote_variant_payload_v2"("p_snapshot" "jsonb", "p_payload" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  with assignments as (
    select a.value item,a.ordinality
    from jsonb_array_elements(coalesce(p_payload->'assignments','[]'::jsonb))
      with ordinality a(value,ordinality)
  ), expected as (
    select * from solver_private.expected_pay_components_v2(p_snapshot,p_payload)
  ), quoted as (
    select a.ordinality,a.item||jsonb_build_object(
      'costUnits',coalesce(sum(e.cost_units),0),
      'costComponents',coalesce(jsonb_agg(jsonb_build_object(
        'ruleId',e.rule_id,
        'calculationType',e.calculation_type,
        'costUnits',e.cost_units
      ) order by e.rule_id,e.calculation_type)
        filter(where e.rule_id is not null),'[]'::jsonb)
    ) item,
    coalesce(sum(e.cost_units),0)::bigint cost_units
    from assignments a
    left join expected e
      on e.slot_id=a.item->>'slotId'
      and e.employee_id=a.item->>'employeeId'
    group by a.ordinality,a.item
  ), aggregate_payload as (
    select coalesce(jsonb_agg(q.item order by q.ordinality),'[]'::jsonb) assignments,
      coalesce(sum(q.cost_units),0)::bigint total_cost_units
    from quoted q
  )
  select jsonb_set(
    jsonb_set(p_payload,'{assignments}',a.assignments,true),
    '{metrics}',
    coalesce(p_payload->'metrics','{}'::jsonb)||jsonb_build_object(
      'UNFILLED',jsonb_array_length(coalesce(p_payload->'unfilledSlotIds','[]'::jsonb)),
      'TOTAL_COST',a.total_cost_units
    ),
    true
  )
  from aggregate_payload a;
$$;


ALTER FUNCTION "solver_private"."requote_variant_payload_v2"("p_snapshot" "jsonb", "p_payload" "jsonb") OWNER TO "postgres";

--
-- Name: reset_retry_outputs_v2("uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."reset_retry_outputs_v2"("p_run_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  delete from public.plan_variants_v2 where run_id=p_run_id;
  update public.optimization_run_strategies_v2
  set status='QUEUED',phase='RETRY_QUEUED',progress=0,
    metrics='{}'::jsonb,failure_code=null,
    started_at=null,finished_at=null,updated_at=now()
  where run_id=p_run_id;
end;
$$;


ALTER FUNCTION "solver_private"."reset_retry_outputs_v2"("p_run_id" "uuid") OWNER TO "postgres";

--
-- Name: resolve_budget_operations_v2("jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."resolve_budget_operations_v2"("p_operations" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
declare
  v_value bigint := 0;
  v_present boolean := false;
  v_item jsonb;
  v_operation text;
begin
  for v_item in
    select value from jsonb_array_elements(coalesce(p_operations,'[]'::jsonb))
  loop
    v_operation := upper(v_item->>'operation');
    case v_operation
      when 'SET' then
        v_value := coalesce((v_item->>'value')::bigint,0);
        v_present := true;
      when 'ADD' then
        v_value := case when v_present then v_value else 0 end
          +coalesce((v_item->>'value')::bigint,0);
        v_present := true;
      when 'MULTIPLY' then
        if v_present then
          v_value := round(
            v_value*coalesce((v_item->>'basisPoints')::numeric,0)/10000
          )::bigint;
        end if;
      when 'REMOVE' then
        v_value := 0;
        v_present := false;
      else raise exception 'UNSUPPORTED_MATRIX_OPERATION:%',v_operation;
    end case;
  end loop;
  return jsonb_build_object(
    'present',v_present,'amountMinor',greatest(v_value,0)
  );
end;
$$;


ALTER FUNCTION "solver_private"."resolve_budget_operations_v2"("p_operations" "jsonb") OWNER TO "postgres";

--
-- Name: resolved_budgets_v2("date", "uuid", "uuid", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."resolved_budgets_v2"("p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_role_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
with recursive scenario_chain as (
  select s.id,s.parent_scenario_id,0 depth
  from public.matrix_scenarios_v2 s
  where s.id=p_scenario_id and s.matrix_version_id=p_matrix_version_id
  union all
  select parent.id,parent.parent_scenario_id,c.depth+1
  from public.matrix_scenarios_v2 parent
  join scenario_chain c on c.parent_scenario_id=parent.id
  where parent.matrix_version_id=p_matrix_version_id and c.depth<32
), applicable as (
  select b.*,c.depth
  from public.matrix_scenario_budgets_v2 b
  join scenario_chain c on c.id=b.scenario_id
  where b.matrix_version_id=p_matrix_version_id
    and (b.budget_month is null
      or b.budget_month=date_trunc('month',p_month)::date)
    and (p_scope_role_id is null or b.role_id is null or b.role_id=p_scope_role_id)
), grouped as (
  select a.location_id,a.role_id,a.duty_id,
    jsonb_agg(jsonb_build_object(
      'operation',a.operation,'value',a.amount_minor,
      'basisPoints',a.multiplier_basis_points
    ) order by a.depth desc,(a.budget_month is not null),a.id) operations,
    (array_agg(a.hard_limit order by a.depth asc,
      (a.budget_month is not null) desc,a.id desc)
      filter(where a.hard_limit is not null))[1] hard_limit,
    (array_agg(a.warning_percent order by a.depth asc,
      (a.budget_month is not null) desc,a.id desc)
      filter(where a.warning_percent is not null))[1] warning_percent,
    max(a.currency) currency
  from applicable a
  group by a.location_id,a.role_id,a.duty_id
), resolved as (
  select g.*,solver_private.resolve_budget_operations_v2(g.operations) state
  from grouped g
)
select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
  'id',public.matrix_v2_stable_uuid(
    'BUDGET_SCOPE_V2:'||p_matrix_version_id::text||':'||
    coalesce(r.location_id::text,'-')||':'||coalesce(r.role_id::text,'-')||':'||
    coalesce(r.duty_id::text,'-')
  ),
  'locationId',r.location_id,'roleId',r.role_id,'dutyId',r.duty_id,
  'amountMinor',(r.state->>'amountMinor')::bigint,
  'hard',coalesce(r.hard_limit,false),
  'warningPercent',r.warning_percent,'currency',r.currency
)) order by r.location_id nulls first,r.role_id nulls first,
  r.duty_id nulls first),'[]'::jsonb)
from resolved r
where coalesce((r.state->>'present')::boolean,false);
$$;


ALTER FUNCTION "solver_private"."resolved_budgets_v2"("p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_role_id" "uuid") OWNER TO "postgres";

--
-- Name: resolved_demand_v2("date", "uuid", "uuid", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."resolved_demand_v2"("p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_role_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("demand_id" "uuid", "work_date" "date", "shift_template_id" "uuid", "location_id" "uuid", "role_id" "uuid", "duty_ids" "uuid"[], "required_count" integer, "starts_at" timestamp with time zone, "ends_at" timestamp with time zone, "duration_minutes" integer)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
with recursive scenario_chain as (
  select scenario.id,scenario.parent_scenario_id,scenario.valid_from,
    scenario.valid_to,0 depth
  from public.matrix_scenarios_v2 scenario
  where scenario.id=p_scenario_id
    and scenario.matrix_version_id=p_matrix_version_id
  union all
  select parent.id,parent.parent_scenario_id,parent.valid_from,parent.valid_to,
    chain.depth+1
  from public.matrix_scenarios_v2 parent
  join scenario_chain chain on chain.parent_scenario_id=parent.id
  where parent.matrix_version_id=p_matrix_version_id and chain.depth<32
), rule_keys as (
  select distinct staffing.shift_template_id,staffing.role_id,staffing.duty_id
  from public.matrix_staffing_rules_v2 staffing
  join scenario_chain chain on chain.id=staffing.scenario_id
  where staffing.matrix_version_id=p_matrix_version_id and staffing.active
    and (p_scope_role_id is null or staffing.role_id=p_scope_role_id)
), occurrences as (
  select day_value::date work_date,shift_template.id shift_template_id,
    shift_template.location_id,shift_template.starts_at local_start,
    shift_template.ends_at local_end,shift_template.ends_next_day,location.timezone
  from public.matrix_shift_templates_v2 shift_template
  join public.matrix_locations_v2 location
    on location.id=shift_template.location_id
    and location.matrix_version_id=shift_template.matrix_version_id
  cross join lateral generate_series(
    date_trunc('month',p_month)::date,
    (date_trunc('month',p_month)+interval '1 month - 1 day')::date,
    interval '1 day'
  ) day_value
  where shift_template.matrix_version_id=p_matrix_version_id
    and shift_template.active and location.active
    and extract(isodow from day_value)::smallint=any(shift_template.day_mask)
), evaluated as (
  select occurrence.work_date,occurrence.shift_template_id,
    occurrence.location_id,key.role_id,key.duty_id,
    solver_private.apply_integer_operations_v2(coalesce((
      select jsonb_agg(jsonb_build_object(
        'operation',staffing.operation,'value',staffing.count_value,
        'basisPoints',staffing.multiplier_basis_points
      ) order by chain.depth desc)
      from public.matrix_staffing_rules_v2 staffing
      join scenario_chain chain on chain.id=staffing.scenario_id
      where staffing.matrix_version_id=p_matrix_version_id and staffing.active
        and staffing.shift_template_id=key.shift_template_id
        and staffing.role_id=key.role_id
        and staffing.duty_id is not distinct from key.duty_id
        and (chain.valid_from is null or chain.valid_from<=occurrence.work_date)
        and (chain.valid_to is null or chain.valid_to>=occurrence.work_date)
    ),'[]'::jsonb))::integer required_count,
    ((occurrence.work_date+occurrence.local_start) at time zone occurrence.timezone) starts_at,
    (((occurrence.work_date+case when occurrence.ends_next_day then 1 else 0 end)
      +occurrence.local_end) at time zone occurrence.timezone) ends_at
  from occurrences occurrence
  join rule_keys key on key.shift_template_id=occurrence.shift_template_id
), exact_demand as (
  select evaluated.work_date,evaluated.shift_template_id,evaluated.location_id,
    evaluated.role_id,
    case when evaluated.duty_id is null then '{}'::uuid[]
      else array[evaluated.duty_id]::uuid[] end duty_ids,
    sum(evaluated.required_count)::integer required_count,
    min(evaluated.starts_at) starts_at,max(evaluated.ends_at) ends_at
  from evaluated
  where evaluated.required_count>0 and evaluated.ends_at>evaluated.starts_at
  group by evaluated.work_date,evaluated.shift_template_id,
    evaluated.location_id,evaluated.role_id,evaluated.duty_id
)
select public.matrix_v2_stable_uuid(
    'DEMAND_V2:'||p_scenario_id::text||':'||demand_row.work_date::text||':'||
    demand_row.shift_template_id::text||':'||demand_row.role_id::text||':'||
    coalesce(array_to_string(demand_row.duty_ids,','),'-')
  ),demand_row.work_date,demand_row.shift_template_id,demand_row.location_id,
  demand_row.role_id,demand_row.duty_ids,demand_row.required_count,
  demand_row.starts_at,demand_row.ends_at,
  greatest(0,round(extract(epoch from (
    demand_row.ends_at-demand_row.starts_at
  ))/60)::integer)
from exact_demand demand_row
order by demand_row.starts_at,demand_row.location_id,
  demand_row.role_id,demand_row.duty_ids;
$$;


ALTER FUNCTION "solver_private"."resolved_demand_v2"("p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_role_id" "uuid") OWNER TO "postgres";

--
-- Name: FUNCTION "resolved_demand_v2"("p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_role_id" "uuid"); Type: COMMENT; Schema: solver_private; Owner: postgres
--

COMMENT ON FUNCTION "solver_private"."resolved_demand_v2"("p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_role_id" "uuid") IS 'MX-K10: resolves demand exclusively from exact matrix_staffing_rules_v2.shift_template_id keys; no broad shift-period role-duty branch exists.';


--
-- Name: resolved_matrix_demand_v2("date", "uuid", "uuid", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."resolved_matrix_demand_v2"("p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_role_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("demand_id" "uuid", "work_date" "date", "shift_template_id" "uuid", "location_id" "uuid", "role_id" "uuid", "duty_ids" "uuid"[], "required_count" integer, "starts_at" timestamp with time zone, "ends_at" timestamp with time zone, "duration_minutes" integer)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
with recursive scenario_chain as (
  select s.id,s.parent_scenario_id,s.valid_from,s.valid_to,0 depth
  from public.matrix_scenarios_v2 s
  where s.id=p_scenario_id and s.matrix_version_id=p_matrix_version_id
  union all
  select parent.id,parent.parent_scenario_id,parent.valid_from,parent.valid_to,c.depth+1
  from public.matrix_scenarios_v2 parent
  join scenario_chain c on c.parent_scenario_id=parent.id
  where parent.matrix_version_id=p_matrix_version_id and c.depth<32
), rule_keys as (
  select distinct sr.shift_template_id,sr.role_id,sr.duty_id
  from public.matrix_staffing_rules_v2 sr
  join scenario_chain c on c.id=sr.scenario_id
  where sr.matrix_version_id=p_matrix_version_id and sr.active
    and (p_scope_role_id is null or sr.role_id=p_scope_role_id)
), occurrences as (
  select d::date work_date,st.id shift_template_id,st.location_id,
    st.shift_period,st.starts_at local_start,st.ends_at local_end,
    st.ends_next_day,l.timezone
  from public.matrix_shift_templates_v2 st
  join public.matrix_locations_v2 l
    on l.id=st.location_id and l.matrix_version_id=st.matrix_version_id
  cross join lateral generate_series(
    date_trunc('month',p_month)::date,
    (date_trunc('month',p_month)+interval '1 month - 1 day')::date,
    interval '1 day'
  ) d
  where st.matrix_version_id=p_matrix_version_id and st.active and l.active
    and extract(isodow from d)::smallint=any(st.day_mask)
), evaluated as (
  select o.work_date,o.shift_template_id,o.location_id,o.shift_period,
    k.role_id,k.duty_id,
    solver_private.apply_integer_operations_v2(coalesce((
      select jsonb_agg(jsonb_build_object(
        'operation',sr.operation,'value',sr.count_value,
        'basisPoints',sr.multiplier_basis_points
      ) order by c.depth desc)
      from public.matrix_staffing_rules_v2 sr
      join scenario_chain c on c.id=sr.scenario_id
      where sr.matrix_version_id=p_matrix_version_id and sr.active
        and sr.shift_template_id=k.shift_template_id and sr.role_id=k.role_id
        and sr.duty_id is not distinct from k.duty_id
        and (c.valid_from is null or c.valid_from<=o.work_date)
        and (c.valid_to is null or c.valid_to>=o.work_date)
    ),'[]'::jsonb))::integer required_count,
    ((o.work_date+o.local_start) at time zone o.timezone) starts_at,
    (((o.work_date+case when o.ends_next_day then 1 else 0 end)+o.local_end)
      at time zone o.timezone) ends_at
  from occurrences o join rule_keys k on k.shift_template_id=o.shift_template_id
), role_occurrences as (
  select e.work_date,e.shift_template_id,e.location_id,e.shift_period,e.role_id,
    coalesce(sum(e.required_count) filter(where e.duty_id is null),0)::integer generic_count,
    min(e.starts_at) starts_at,max(e.ends_at) ends_at
  from evaluated e where e.required_count>0 and e.ends_at>e.starts_at
  group by e.work_date,e.shift_template_id,e.location_id,e.shift_period,e.role_id
), explicit_counts as (
  select e.work_date,e.shift_template_id,e.location_id,e.role_id,e.duty_id,
    sum(e.required_count)::integer required_count
  from evaluated e
  where e.duty_id is not null and e.required_count>0 and e.ends_at>e.starts_at
  group by e.work_date,e.shift_template_id,e.location_id,e.role_id,e.duty_id
), minimum_requirements as (
  select ro.work_date,ro.shift_template_id,ro.location_id,ro.role_id,rd.duty_id,
    greatest(rd.minimum_count-coalesce(ec.required_count,0),0)::integer required_count
  from role_occurrences ro
  join public.matrix_role_duties_v2 rd
    on rd.matrix_version_id=p_matrix_version_id and rd.role_id=ro.role_id
    and rd.active and rd.assignment_mode='REQUIRED' and rd.minimum_count>0
    and (not rd.shift_obligation or rd.shift_period=ro.shift_period)
  left join explicit_counts ec
    on ec.work_date=ro.work_date and ec.shift_template_id=ro.shift_template_id
    and ec.location_id=ro.location_id and ec.role_id=ro.role_id
    and ec.duty_id=rd.duty_id
), minimum_totals as (
  select mr.work_date,mr.shift_template_id,mr.location_id,mr.role_id,
    sum(mr.required_count)::integer minimum_count
  from minimum_requirements mr
  group by mr.work_date,mr.shift_template_id,mr.location_id,mr.role_id
), guard as (
  select coalesce(bool_and(coalesce(mt.minimum_count,0)<=ro.generic_count),true) valid
  from role_occurrences ro
  left join minimum_totals mt
    on mt.work_date=ro.work_date and mt.shift_template_id=ro.shift_template_id
    and mt.location_id=ro.location_id and mt.role_id=ro.role_id
), expanded_raw as (
  select e.work_date,e.shift_template_id,e.location_id,e.role_id,
    array[e.duty_id]::uuid[] duty_ids,e.required_count,e.starts_at,e.ends_at
  from evaluated e
  where e.duty_id is not null and e.required_count>0 and e.ends_at>e.starts_at
  union all
  select mr.work_date,mr.shift_template_id,mr.location_id,mr.role_id,
    array[mr.duty_id]::uuid[],mr.required_count,ro.starts_at,ro.ends_at
  from minimum_requirements mr
  join role_occurrences ro
    on ro.work_date=mr.work_date and ro.shift_template_id=mr.shift_template_id
    and ro.location_id=mr.location_id and ro.role_id=mr.role_id
  where mr.required_count>0
  union all
  select ro.work_date,ro.shift_template_id,ro.location_id,ro.role_id,
    '{}'::uuid[],ro.generic_count-coalesce(mt.minimum_count,0),ro.starts_at,ro.ends_at
  from role_occurrences ro
  left join minimum_totals mt
    on mt.work_date=ro.work_date and mt.shift_template_id=ro.shift_template_id
    and mt.location_id=ro.location_id and mt.role_id=ro.role_id
  where ro.generic_count>coalesce(mt.minimum_count,0)
), expanded as (
  select e.work_date,e.shift_template_id,e.location_id,e.role_id,e.duty_ids,
    sum(e.required_count)::integer required_count,
    min(e.starts_at) starts_at,max(e.ends_at) ends_at
  from expanded_raw e
  group by e.work_date,e.shift_template_id,e.location_id,e.role_id,e.duty_ids
)
select public.matrix_v2_stable_uuid(
    'DEMAND_V2:'||p_scenario_id::text||':'||e.work_date::text||':'||
    e.shift_template_id::text||':'||e.role_id::text||':'||
    coalesce(array_to_string(e.duty_ids,','),'-')
  ),e.work_date,e.shift_template_id,e.location_id,e.role_id,e.duty_ids,
  e.required_count,e.starts_at,e.ends_at,
  greatest(0,round(extract(epoch from (e.ends_at-e.starts_at))/60)::integer)
from expanded e cross join guard g
where solver_private.assert_configuration_v2(
  g.valid,'ROLE_DUTY_MINIMUM_EXCEEDS_STAFFING'
)
order by e.starts_at,e.location_id,e.role_id,e.duty_ids;
$$;


ALTER FUNCTION "solver_private"."resolved_matrix_demand_v2"("p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_role_id" "uuid") OWNER TO "postgres";

--
-- Name: revalidate_materialized_variant_v2("uuid", boolean); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."revalidate_materialized_variant_v2"("p_variant_id" "uuid", "p_neutralize_external" boolean) RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
  select solver_private.revalidate_materialized_variant_v2($1,$2,true);
$_$;


ALTER FUNCTION "solver_private"."revalidate_materialized_variant_v2"("p_variant_id" "uuid", "p_neutralize_external" boolean) OWNER TO "postgres";

--
-- Name: revalidate_materialized_variant_v2("uuid", boolean, boolean); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."revalidate_materialized_variant_v2"("p_variant_id" "uuid", "p_neutralize_external" boolean, "p_validate_hard" boolean) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_variant public.plan_variants_v2%rowtype;
  v_run public.optimization_runs_v2%rowtype;
  v_stored jsonb;
  v_current jsonb;
  v_stored_basis_hash text;
  v_current_basis_hash text;
  v_payload jsonb;
  v_validation jsonb;
begin
  select * into v_variant
  from public.plan_variants_v2 v
  where v.id=p_variant_id;
  if v_variant.id is null then raise exception 'VARIANT_NOT_FOUND'; end if;
  if v_variant.hard_violations<>0 then
    raise exception 'VARIANT_HAS_HARD_VIOLATIONS';
  end if;

  select * into v_run
  from public.optimization_runs_v2 r
  where r.id=v_variant.run_id;
  if v_run.id is null or v_run.status<>'READY' then
    raise exception 'RUN_NOT_READY';
  end if;
  if v_variant.snapshot_hash<>v_run.snapshot_hash then
    raise exception 'VARIANT_SNAPSHOT_MISMATCH';
  end if;

  select s.snapshot into v_stored
  from solver_private.optimization_snapshots_v2 s
  where s.run_id=v_run.id;
  if v_stored is null then raise exception 'SNAPSHOT_NOT_FOUND'; end if;

  v_current := solver_private.build_snapshot_payload_v2(
    v_run.id,v_run.month,v_run.matrix_version_id,v_run.scenario_id,
    v_run.scope_type,v_run.scope_role_id
  );
  v_stored_basis_hash := solver_private.publication_static_input_hash_v2(v_stored);
  v_current_basis_hash := solver_private.publication_static_input_hash_v2(v_current);
  if v_current_basis_hash<>v_stored_basis_hash then
    raise exception 'PUBLICATION_INPUT_CHANGED';
  end if;

  if p_neutralize_external then
    v_current := jsonb_set(v_current,'{externalAssignments}','[]'::jsonb,true);
  end if;

  perform solver_private.assert_materialized_variant_metadata_v2(
    v_variant.id,v_current
  );
  v_payload := solver_private.materialized_variant_payload_v2(
    array[v_variant.id],v_current,v_variant.strategy_id
  );
  if lower(v_payload->>'solutionHash') is distinct from lower(v_variant.solution_hash) then
    raise exception 'VARIANT_MATERIALIZATION_HASH_MISMATCH';
  end if;
  if p_validate_hard then
    v_validation := solver_private.validate_variant_v2(v_current,v_payload);
  else
    v_validation := jsonb_build_object('hardValidationDeferred',true);
  end if;
  return v_validation||jsonb_build_object(
    'validationSnapshotHash',solver_private.publication_snapshot_hash_v2(v_current),
    'variantId',v_variant.id,
    'currency',nullif(v_current->>'currency','')
  );
end;
$$;


ALTER FUNCTION "solver_private"."revalidate_materialized_variant_v2"("p_variant_id" "uuid", "p_neutralize_external" boolean, "p_validate_hard" boolean) OWNER TO "postgres";

--
-- Name: role_composite_consistency_guard_v2(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."role_composite_consistency_guard_v2"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_schedule public.published_schedules_v2%rowtype;
begin
  select schedule.* into v_schedule
  from public.published_schedules_v2 schedule
  where schedule.id=coalesce(new.schedule_id,old.schedule_id);
  if v_schedule.source_type<>'ROLE_COMPOSITE' or v_schedule.status<>'PUBLISHED' then
    return null;
  end if;
  if exists(
    select 1 from public.published_schedule_variants_v2 link
    where link.schedule_id=v_schedule.id and (
      link.role_id is null or not exists(
        select 1 from public.published_role_schedules_v2 role_schedule
        where role_schedule.month=v_schedule.month
          and role_schedule.role_id=link.role_id
          and role_schedule.variant_id=link.variant_id
          and role_schedule.status='PUBLISHED'
      )
    )
  ) then
    raise exception 'ROLE_COMPOSITE_CONTAINS_NONCURRENT_ROLE_VARIANT';
  end if;
  if exists(
    select 1
    from (
      select distinct demand.role_id
      from solver_private.resolved_demand_v2(
        v_schedule.month,
        v_schedule.matrix_version_id,
        v_schedule.scenario_id,
        null
      ) demand
    ) demanded
    where not exists(
      select 1
      from public.published_schedule_variants_v2 link
      join public.plan_variants_v2 variant on variant.id=link.variant_id
      join public.optimization_runs_v2 run on run.id=variant.run_id
      join solver_private.optimization_snapshots_v2 run_snapshot on run_snapshot.run_id=run.id
      cross join lateral jsonb_array_elements_text(
        case
          when jsonb_typeof(run_snapshot.snapshot->'scope'->'roleIds')='array'
            and jsonb_array_length(run_snapshot.snapshot->'scope'->'roleIds')>0
            then run_snapshot.snapshot->'scope'->'roleIds'
          else jsonb_build_array(link.role_id::text)
        end
      ) covered_role(role_id)
      where link.schedule_id=v_schedule.id
        and covered_role.role_id=demanded.role_id::text
    )
  ) then
    raise exception 'ROLE_COMPOSITE_REQUIRES_EVERY_DEMANDED_ROLE';
  end if;
  return null;
end;
$$;


ALTER FUNCTION "solver_private"."role_composite_consistency_guard_v2"() OWNER TO "postgres";

--
-- Name: FUNCTION "role_composite_consistency_guard_v2"(); Type: COMMENT; Schema: solver_private; Owner: postgres
--

COMMENT ON FUNCTION "solver_private"."role_composite_consistency_guard_v2"() IS 'Deferred ROLE_COMPOSITE guard: every demanded role must be covered by a current published category or role variant, using immutable snapshot scope roleIds.';


--
-- Name: run_status_payload_v2("uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."run_status_payload_v2"("p_run_id" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select jsonb_build_object(
    'run',jsonb_build_object(
      'id',r.id,'status',r.status,'phase',r.phase,'progress',r.progress,
      'month',r.month,'scopeType',r.scope_type,'scopeRoleId',r.scope_role_id,
      'requestEngine',r.request_engine,'solverVersion',r.solver_version,
      'failureMessage',r.failure_message,
      'createdAt',r.created_at,'queuedAt',r.queued_at,'startedAt',r.started_at,
      'heartbeatAt',r.heartbeat_at,'updatedAt',r.updated_at,
      'queuePosition',case when r.status='QUEUED' then 1+(
        select count(*) from public.optimization_runs_v2 ahead
        where ahead.status='QUEUED'
          and (ahead.queued_at,ahead.id)<(r.queued_at,r.id)
      ) else null end,
      'waitingSeconds',greatest(0,floor(extract(epoch from (coalesce(r.started_at,now())-r.queued_at))))::integer,
      'runningSeconds',case when r.started_at is null then null else
        greatest(0,floor(extract(epoch from (coalesce(r.finished_at,now())-r.started_at))))::integer end
    ),
    'strategies',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',s.id,'strategyId',s.strategy_id,'name',ms.name,
        'status',s.status,'phase',s.phase,'progress',s.progress
      ) order by s.ordinal)
      from public.optimization_run_strategies_v2 s
      join public.matrix_strategies_v2 ms on ms.id=s.strategy_id
      where s.run_id=r.id
    ),'[]'::jsonb)
  )
  from public.optimization_runs_v2 r where r.id=p_run_id;
$$;


ALTER FUNCTION "solver_private"."run_status_payload_v2"("p_run_id" "uuid") OWNER TO "postgres";

--
-- Name: FUNCTION "run_status_payload_v2"("p_run_id" "uuid"); Type: COMMENT; Schema: solver_private; Owner: postgres
--

COMMENT ON FUNCTION "solver_private"."run_status_payload_v2"("p_run_id" "uuid") IS 'Internal optimizer status payload with safe queue position and elapsed-time metadata for UAT progress UX.';


--
-- Name: schedule_primary_conflict_reasons_uat_v2("uuid", "uuid", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."schedule_primary_conflict_reasons_uat_v2"("p_schedule_id" "uuid", "p_employee_id" "uuid", "p_shift_id" "uuid") RETURNS "text"[]
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_shift public.plan_shifts_v2%rowtype;
  v_matrix_version_id uuid;
  v_month date;
  v_reasons text[]:='{}'::text[];
  v_tier integer;
  v_maximum_shifts_per_day integer:=1;
begin
  select shift_row.* into v_shift
  from public.plan_shifts_v2 shift_row where shift_row.id=p_shift_id;
  select schedule.matrix_version_id,schedule.month
  into v_matrix_version_id,v_month
  from public.published_schedules_v2 schedule
  where schedule.id=p_schedule_id and schedule.status='PUBLISHED';
  select coalesce(nullif(version.settings->>'maximumShiftsPerDay','')::integer,1)
  into v_maximum_shifts_per_day
  from public.matrix_versions_v2 version
  where version.id=v_matrix_version_id;
  if v_shift.id is null or v_matrix_version_id is null then
    return array['SHIFT_NOT_FOUND']::text[];
  end if;

  if (
    with scheduled as (
      select assignment.employee_id,shift_row.shift_date,shift_row.id shift_id
      from public.published_schedule_variants_v2 link
      join public.plan_assignments_v2 assignment on assignment.variant_id=link.variant_id
      join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
      where link.schedule_id=p_schedule_id
      union all
      select override_row.employee_id,shift_row.shift_date,shift_row.id shift_id
      from public.operational_assignment_overrides_v2 override_row
      join public.plan_shifts_v2 shift_row on shift_row.id=override_row.shift_id
      where override_row.schedule_id=p_schedule_id and override_row.status='ACTIVE'
    )
    select count(distinct scheduled.shift_id) from scheduled
    where scheduled.employee_id=p_employee_id
      and scheduled.shift_date=v_shift.shift_date
  )>=v_maximum_shifts_per_day then
    v_reasons:=array_append(v_reasons,'ONE_PRIMARY_SHIFT_PER_DAY');
  end if;

  if (
    solver_private.shift_template_is_sequence_edge_uat_v2(
      v_matrix_version_id,v_shift.shift_template_id,v_shift.shift_date,'FIRST'
    ) and exists(
      with scheduled as (
        select assignment.employee_id,shift_row.shift_date,shift_row.shift_template_id
        from public.published_schedule_variants_v2 link
        join public.plan_assignments_v2 assignment on assignment.variant_id=link.variant_id
        join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
        where link.schedule_id=p_schedule_id
        union all
        select override_row.employee_id,shift_row.shift_date,shift_row.shift_template_id
        from public.operational_assignment_overrides_v2 override_row
        join public.plan_shifts_v2 shift_row on shift_row.id=override_row.shift_id
        where override_row.schedule_id=p_schedule_id and override_row.status='ACTIVE'
      )
      select 1 from scheduled
      where scheduled.employee_id=p_employee_id
        and scheduled.shift_date=v_shift.shift_date-1
        and solver_private.shift_template_is_sequence_edge_uat_v2(
          v_matrix_version_id,scheduled.shift_template_id,scheduled.shift_date,'LAST'
        )
    )
  ) or (
    solver_private.shift_template_is_sequence_edge_uat_v2(
      v_matrix_version_id,v_shift.shift_template_id,v_shift.shift_date,'LAST'
    ) and exists(
      with scheduled as (
        select assignment.employee_id,shift_row.shift_date,shift_row.shift_template_id
        from public.published_schedule_variants_v2 link
        join public.plan_assignments_v2 assignment on assignment.variant_id=link.variant_id
        join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
        where link.schedule_id=p_schedule_id
        union all
        select override_row.employee_id,shift_row.shift_date,shift_row.shift_template_id
        from public.operational_assignment_overrides_v2 override_row
        join public.plan_shifts_v2 shift_row on shift_row.id=override_row.shift_id
        where override_row.schedule_id=p_schedule_id and override_row.status='ACTIVE'
      )
      select 1 from scheduled
      where scheduled.employee_id=p_employee_id
        and scheduled.shift_date=v_shift.shift_date+1
        and solver_private.shift_template_is_sequence_edge_uat_v2(
          v_matrix_version_id,scheduled.shift_template_id,scheduled.shift_date,'FIRST'
        )
    )
  ) then
    v_reasons:=array_append(v_reasons,'CONSECUTIVE_SHIFT_SEQUENCE');
  end if;

  select standby.tier into v_tier
  from public.published_standby_assignments_v2 standby
  where standby.month=v_month
    and standby.standby_date=v_shift.shift_date
    and standby.employee_id=p_employee_id
    and standby.status in ('PLANNED','ACTIVATED')
  order by standby.tier
  limit 1;
  if v_tier=1 then
    v_reasons:=array_append(v_reasons,'STANDBY_TIER_1_RESERVED');
  elsif v_tier=2 then
    v_reasons:=array_append(v_reasons,'STANDBY_TIER_2_RESERVED');
  end if;

  return v_reasons;
end;
$$;


ALTER FUNCTION "solver_private"."schedule_primary_conflict_reasons_uat_v2"("p_schedule_id" "uuid", "p_employee_id" "uuid", "p_shift_id" "uuid") OWNER TO "postgres";

--
-- Name: seed_matrix_employee_profiles_v2(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."seed_matrix_employee_profiles_v2"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if new.status='DRAFT' and new.schema_version>=2 and new.base_version_id is not null then
    insert into public.matrix_employee_profiles_v2(
      id,matrix_version_id,employee_id,employee_no,first_name,last_name,email,
      active,employment_start,employment_end,nominal_monthly_minutes,
      maximum_monthly_minutes,maximum_weekly_minutes,maximum_consecutive_days,
      minimum_rest_minutes,only_morning,only_evening,no_weekends,
      preferred_shift_code,archived_at,archived_by,archive_reason,
      created_by,updated_by,created_at,updated_at
    )
    select gen_random_uuid(),new.id,p.employee_id,p.employee_no,p.first_name,
      p.last_name,p.email,p.active,p.employment_start,p.employment_end,
      p.nominal_monthly_minutes,p.maximum_monthly_minutes,
      p.maximum_weekly_minutes,p.maximum_consecutive_days,
      p.minimum_rest_minutes,p.only_morning,p.only_evening,p.no_weekends,
      p.preferred_shift_code,p.archived_at,p.archived_by,p.archive_reason,
      coalesce(new.created_by,p.created_by),coalesce(new.created_by,p.updated_by),
      now(),now()
    from public.matrix_employee_profiles_v2 p
    where p.matrix_version_id=new.base_version_id
    on conflict(matrix_version_id,employee_id) do nothing;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."seed_matrix_employee_profiles_v2"() OWNER TO "postgres";

--
-- Name: shift_swap_personal_notifications_v1(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."shift_swap_personal_notifications_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if tg_op='INSERT' then
    if new.target_employee_id is null then
      insert into public.notifications(
        recipient_id,channel,title,body,kind,action_required,action_route,
        context_type,context_id,sent_at
      )
      select employee.auth_user_id,'IN_APP','Nowa oferta na tablicy zmian',
        'Możesz sprawdzić zmianę '||shift.shift_date::text||' • '
          ||location.name||' • '||role.name||'.',
        'INFORMATION',false,'/swaps','SHIFT_SWAP',new.id::text,now()
      from public.employees employee
      join public.plan_assignments_v2 assignment
        on assignment.id=new.original_assignment_id
      join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
      join public.matrix_locations_v2 location on location.id=shift.location_id
      join public.matrix_roles_v2 role on role.id=new.role_id
      where employee.active and employee.archived_at is null
        and employee.auth_user_id is not null
        and employee.id<>new.proposer_employee_id
        and cardinality(solver_private.swap_candidate_reasons_uat_v2(new.id,employee.id))=0
        and not exists(
          select 1 from public.notifications notification
          where notification.recipient_id=employee.auth_user_id
            and notification.context_type='SHIFT_SWAP'
            and notification.context_id=new.id::text
            and notification.title='Nowa oferta na tablicy zmian'
        );
    else
      insert into public.notifications(
        recipient_id,channel,title,body,kind,action_required,action_route,
        context_type,context_id,sent_at
      )
      select target.auth_user_id,'IN_APP','Propozycja zamiany zmiany',
        'Otrzymujesz propozycję przejęcia zmiany '||shift.shift_date::text||'.',
        'ACTION_REQUIRED',true,'/swaps','SHIFT_SWAP',new.id::text,now()
      from public.employees target
      join public.plan_assignments_v2 assignment
        on assignment.id=new.original_assignment_id
      join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
      where target.id=new.target_employee_id and target.auth_user_id is not null;
    end if;
  elsif tg_op='UPDATE' and old.status='OPEN' and new.status='EMPLOYEE_ACCEPTED' then
    update public.notifications set resolved_at=now(),resolution='TAKEN'
    where context_type='SHIFT_SWAP' and context_id=new.id::text
      and resolved_at is null and title in (
        'Nowa oferta na tablicy zmian','Propozycja zamiany zmiany'
      );
    insert into public.notifications(
      recipient_id,channel,title,body,kind,action_required,action_route,
      context_type,context_id,sent_at
    )
    select proposer.auth_user_id,'IN_APP','Ktoś przyjął Twoją propozycję zmiany',
      accepted.first_name||' '||accepted.last_name
        ||' chce przejąć Twoją zmianę. Teraz decyzję podejmuje lider.',
      'DECISION',false,'/swaps','SHIFT_SWAP',new.id::text,now()
    from public.employees proposer
    join public.employees accepted on accepted.id=new.accepted_by_employee_id
    where proposer.id=new.proposer_employee_id
      and proposer.auth_user_id is not null
      and not exists(
        select 1 from public.notifications notification
        where notification.recipient_id=proposer.auth_user_id
          and notification.context_type='SHIFT_SWAP'
          and notification.context_id=new.id::text
          and notification.title='Ktoś przyjął Twoją propozycję zmiany'
      );
    insert into public.notifications(
      recipient_id,channel,title,body,kind,action_required,action_route,
      context_type,context_id,sent_at
    )
    select distinct recipient.auth_user_id,'IN_APP','Zamiana czeka na akceptację',
      'Pracownicy uzgodnili zamianę. Sprawdź ją i zaakceptuj albo odrzuć.',
      'ACTION_REQUIRED',true,'/swaps','SHIFT_SWAP',new.id::text,now()
    from (
      select grant_row.auth_user_id from public.matrix_scope_grants_v2 grant_row
      join public.matrix_roles_v2 role on role.logical_id=grant_row.role_logical_id
      where grant_row.active and grant_row.app_role='ROLE_MANAGER'
        and role.id=new.role_id
      union
      select permission.auth_user_id from public.user_permissions permission
      where permission.app_role in ('OWNER','ADMIN')
    ) recipient where recipient.auth_user_id is not null;
  elsif tg_op='UPDATE' and old.status='OPEN' and new.status='EMPLOYEE_REJECTED' then
    update public.notifications set resolved_at=now(),resolution='REJECTED'
    where context_type='SHIFT_SWAP' and context_id=new.id::text
      and resolved_at is null and action_required;
    insert into public.notifications(
      recipient_id,channel,title,body,kind,action_required,action_route,
      context_type,context_id,sent_at
    )
    select proposer.auth_user_id,'IN_APP','Odrzucono Twoją propozycję zmiany',
      coalesce(target.first_name||' '||target.last_name,'Wybrana osoba')
        ||' nie przyjęła propozycji. Możesz opublikować nowe ogłoszenie.',
      'DECISION',false,'/swaps','SHIFT_SWAP',new.id::text,now()
    from public.employees proposer
    left join public.employees target on target.id=new.target_employee_id
    where proposer.id=new.proposer_employee_id
      and proposer.auth_user_id is not null
      and not exists(
        select 1 from public.notifications notification
        where notification.recipient_id=proposer.auth_user_id
          and notification.context_type='SHIFT_SWAP'
          and notification.context_id=new.id::text
          and notification.title='Odrzucono Twoją propozycję zmiany'
      );
  elsif tg_op='UPDATE' and old.status='EMPLOYEE_ACCEPTED'
      and new.status in ('LEADER_APPROVED','LEADER_REJECTED','CANCELLED') then
    update public.notifications
    set resolved_at=now(),resolution=new.status
    where context_type='SHIFT_SWAP' and context_id=new.id::text
      and resolved_at is null and action_required;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."shift_swap_personal_notifications_v1"() OWNER TO "postgres";

--
-- Name: shift_template_is_sequence_edge_uat_v2("uuid", "uuid", "date", "text"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."shift_template_is_sequence_edge_uat_v2"("p_matrix_version_id" "uuid", "p_shift_template_id" "uuid", "p_shift_date" "date", "p_edge" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  with target as (
    select template.*
    from public.matrix_shift_templates_v2 template
    where template.id=p_shift_template_id
      and template.matrix_version_id=p_matrix_version_id
      and template.active
  )
  select coalesce(case upper(p_edge)
    when 'FIRST' then not exists(
      select 1 from target
      join public.matrix_shift_templates_v2 other
        on other.matrix_version_id=target.matrix_version_id
       and other.location_id=target.location_id
       and other.active
       and extract(isodow from p_shift_date)::smallint=any(other.day_mask)
       and (other.sort_order,other.starts_at,other.id)
         < (target.sort_order,target.starts_at,target.id)
    )
    when 'LAST' then not exists(
      select 1 from target
      join public.matrix_shift_templates_v2 other
        on other.matrix_version_id=target.matrix_version_id
       and other.location_id=target.location_id
       and other.active
       and extract(isodow from p_shift_date)::smallint=any(other.day_mask)
       and (other.sort_order,other.starts_at,other.id)
         > (target.sort_order,target.starts_at,target.id)
    )
    else false end,false)
  from target;
$$;


ALTER FUNCTION "solver_private"."shift_template_is_sequence_edge_uat_v2"("p_matrix_version_id" "uuid", "p_shift_template_id" "uuid", "p_shift_date" "date", "p_edge" "text") OWNER TO "postgres";

--
-- Name: slot_timezone_v2("jsonb", "jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."slot_timezone_v2"("p_snapshot" "jsonb", "p_slot" "jsonb") RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select coalesce(
    (select l.value->>'timezone'
      from jsonb_array_elements(coalesce(p_snapshot->'locations','[]'::jsonb)) l
      where l.value->>'id'=p_slot->>'locationId' limit 1),
    nullif(p_snapshot->'settings'->>'timezone','')
  );
$$;


ALTER FUNCTION "solver_private"."slot_timezone_v2"("p_snapshot" "jsonb", "p_slot" "jsonb") OWNER TO "postgres";

--
-- Name: staffing_duty_link_guard_uat006(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."staffing_duty_link_guard_uat006"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if new.active and new.duty_id is not null and not exists(
    select 1 from public.matrix_role_duties_v2 link
    where link.matrix_version_id=new.matrix_version_id
      and link.role_id=new.role_id and link.duty_id=new.duty_id and link.active
  ) then
    raise exception 'STAFFING_DUTY_NOT_LINKED_TO_ROLE';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."staffing_duty_link_guard_uat006"() OWNER TO "postgres";

--
-- Name: standby_activation_reasons_uat_v2("uuid", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."standby_activation_reasons_uat_v2"("p_standby_id" "uuid", "p_original_assignment_id" "uuid") RETURNS "text"[]
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_standby public.published_standby_assignments_v2%rowtype;
  v_assignment public.plan_assignments_v2%rowtype;
  v_shift public.plan_shifts_v2%rowtype;
  v_profile public.matrix_employee_profiles_v2%rowtype;
  v_reasons text[]:='{}'::text[];
  v_default_available boolean:=true;
  v_minutes integer:=0;
  v_month_minutes integer:=0;
  v_week_minutes integer:=0;
  v_rest integer:=0;
  v_before integer:=0;
  v_after integer:=0;
  v_enforce_work_time boolean:=true;
begin
  select * into v_standby from public.published_standby_assignments_v2
    where id=p_standby_id;
  if v_standby.id is null or v_standby.status<>'PLANNED' then
    return array['STANDBY_NOT_ACTIVATABLE'];
  end if;
  select * into v_assignment from public.plan_assignments_v2
    where id=p_original_assignment_id;
  select * into v_shift from public.plan_shifts_v2 where id=v_assignment.shift_id;
  if v_assignment.id is null or v_shift.id is null
    or v_assignment.role_id<>v_standby.role_id
    or v_shift.shift_date<>v_standby.standby_date then
    return array['STANDBY_TARGET_ASSIGNMENT_MISMATCH'];
  end if;
  select * into v_profile from public.matrix_employee_profiles_v2 profile
  where profile.matrix_version_id=v_standby.matrix_version_id
    and profile.employee_id=v_standby.employee_id
    and profile.active and profile.archived_at is null;
  if v_profile.id is null then
    v_reasons:=array_append(v_reasons,'EMPLOYEE_NOT_ACTIVE');
    return v_reasons;
  end if;
  select not (coalesce(hr.contract_type,'INNE') in ('ZLECENIE','B2B')
      and v_profile.work_time_policy<>'CUSTOM')
  into v_enforce_work_time
  from public.employee_hr_profiles hr
  where hr.employee_id=v_standby.employee_id;
  v_enforce_work_time:=coalesce(v_enforce_work_time,true);
  select coalesce((matrix.settings->>'missingAvailabilityMeansAvailable')::boolean,true)
  into v_default_available from public.matrix_versions matrix
  where matrix.id=v_standby.matrix_version_id;

  if not exists(select 1 from public.matrix_employee_roles_v2 role_grant
      where role_grant.matrix_version_id=v_standby.matrix_version_id
        and role_grant.employee_id=v_standby.employee_id
        and role_grant.role_id=v_assignment.role_id and role_grant.active
        and (role_grant.valid_from is null or role_grant.valid_from<=v_shift.shift_date)
        and (role_grant.valid_to is null or role_grant.valid_to>=v_shift.shift_date)) then
    v_reasons:=array_append(v_reasons,'ROLE_REQUIRED');
  end if;
  if not exists(select 1 from public.matrix_employee_locations_v2 location_grant
      where location_grant.matrix_version_id=v_standby.matrix_version_id
        and location_grant.employee_id=v_standby.employee_id
        and location_grant.location_id=v_shift.location_id
        and location_grant.active and location_grant.standard_allowed
        and (location_grant.valid_from is null or location_grant.valid_from<=v_shift.shift_date)
        and (location_grant.valid_to is null or location_grant.valid_to>=v_shift.shift_date)) then
    v_reasons:=array_append(v_reasons,'LOCATION_NOT_ALLOWED');
  end if;
  if exists(select 1 from public.plan_assignment_duties_v2 required_duty
      where required_duty.assignment_id=v_assignment.id and not exists(
        select 1 from public.matrix_employee_duties_v2 capability
        where capability.matrix_version_id=v_standby.matrix_version_id
          and capability.employee_id=v_standby.employee_id
          and capability.duty_id=required_duty.duty_id and capability.active
          and (capability.role_id is null or capability.role_id=v_standby.role_id)
          and (capability.location_id is null or capability.location_id=v_shift.location_id)
          and (capability.valid_from is null or capability.valid_from<=v_shift.shift_date)
          and (capability.valid_to is null or capability.valid_to>=v_shift.shift_date))) then
    v_reasons:=array_append(v_reasons,'DUTY_REQUIRED');
  end if;
  if exists(select 1 from public.employee_time_constraints_v2 constraint_row
      where constraint_row.employee_id=v_standby.employee_id
        and constraint_row.status='ACTIVE'
        and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
        and constraint_row.time_range&&tstzrange(v_shift.starts_at,v_shift.ends_at,'[)')) then
    v_reasons:=array_append(v_reasons,'HARD_UNAVAILABLE');
  end if;
  if not v_default_available and not exists(select 1
      from public.employee_time_constraints_v2 window_row
      where window_row.employee_id=v_standby.employee_id
        and window_row.status='ACTIVE'
        and window_row.constraint_kind='AVAILABLE_WINDOW'
        and lower(window_row.time_range)<=v_shift.starts_at
        and upper(window_row.time_range)>=v_shift.ends_at) then
    v_reasons:=array_append(v_reasons,'OUTSIDE_AVAILABILITY_WINDOW');
  end if;
  if (v_profile.employment_start is not null
      and v_profile.employment_start>v_shift.shift_date)
    or (v_profile.employment_end is not null
      and v_profile.employment_end<v_shift.shift_date) then
    v_reasons:=array_append(v_reasons,'OUTSIDE_EMPLOYMENT');
  end if;
  if v_profile.no_weekends and extract(isodow from v_shift.shift_date) in (6,7) then
    v_reasons:=array_append(v_reasons,'NO_WEEKENDS');
  end if;
  if v_profile.only_morning and exists(select 1
      from public.matrix_shift_templates_v2 template
      where template.id=v_shift.shift_template_id
        and template.shift_period<>'MORNING') then
    v_reasons:=array_append(v_reasons,'ONLY_MORNING');
  end if;
  if v_profile.only_evening and exists(select 1
      from public.matrix_shift_templates_v2 template
      where template.id=v_shift.shift_template_id
        and template.shift_period<>'EVENING') then
    v_reasons:=array_append(v_reasons,'ONLY_EVENING');
  end if;

  if exists(
    select 1 from public.plan_assignments_v2 other_assignment
    join public.plan_shifts_v2 other_shift on other_shift.id=other_assignment.shift_id
    left join public.operational_assignment_replacements_v2 replacement
      on replacement.original_assignment_id=other_assignment.id
     and replacement.status='ACTIVE'
    where other_assignment.employee_id=v_standby.employee_id
      and other_assignment.id<>v_assignment.id and replacement.id is null
      and other_shift.shift_date=v_shift.shift_date
      and solver_private.assignment_is_currently_published_v2(other_assignment.id)
    union all
    select 1 from public.operational_assignment_replacements_v2 replacement
    join public.plan_assignments_v2 original
      on original.id=replacement.original_assignment_id
    join public.plan_shifts_v2 other_shift on other_shift.id=original.shift_id
    where replacement.replacement_employee_id=v_standby.employee_id
      and replacement.status='ACTIVE' and original.id<>v_assignment.id
      and other_shift.shift_date=v_shift.shift_date
      and solver_private.assignment_is_currently_published_v2(original.id)
  ) then
    v_reasons:=array_append(v_reasons,'DAILY_SHIFT_LIMIT');
  end if;

  v_rest:=case when v_enforce_work_time
    then coalesce(v_profile.minimum_rest_minutes,0) else 0 end;
  if exists(
    with effective_shifts as (
      select other_assignment.id,other_shift.starts_at,other_shift.ends_at,
        other_shift.shift_date
      from public.plan_assignments_v2 other_assignment
      join public.plan_shifts_v2 other_shift on other_shift.id=other_assignment.shift_id
      left join public.operational_assignment_replacements_v2 replacement
        on replacement.original_assignment_id=other_assignment.id
       and replacement.status='ACTIVE'
      where other_assignment.employee_id=v_standby.employee_id
        and other_assignment.id<>v_assignment.id and replacement.id is null
        and solver_private.assignment_is_currently_published_v2(other_assignment.id)
      union all
      select original.id,other_shift.starts_at,other_shift.ends_at,
        other_shift.shift_date
      from public.operational_assignment_replacements_v2 replacement
      join public.plan_assignments_v2 original
        on original.id=replacement.original_assignment_id
      join public.plan_shifts_v2 other_shift on other_shift.id=original.shift_id
      where replacement.replacement_employee_id=v_standby.employee_id
        and replacement.status='ACTIVE' and original.id<>v_assignment.id
        and solver_private.assignment_is_currently_published_v2(original.id)
    )
    select 1 from effective_shifts other_shift
    where other_shift.ends_at+(v_rest*interval '1 minute')>v_shift.starts_at
      and v_shift.ends_at+(v_rest*interval '1 minute')>other_shift.starts_at
  ) then
    v_reasons:=array_append(v_reasons,'SHIFT_OR_REST_CONFLICT');
  end if;

  v_minutes:=greatest(0,round(extract(epoch from(v_shift.ends_at-v_shift.starts_at))/60)::integer);
  with effective_shifts as (
    select other_shift.shift_date,other_shift.starts_at,other_shift.ends_at
    from public.plan_assignments_v2 other_assignment
    join public.plan_shifts_v2 other_shift on other_shift.id=other_assignment.shift_id
    left join public.operational_assignment_replacements_v2 replacement
      on replacement.original_assignment_id=other_assignment.id
     and replacement.status='ACTIVE'
    where other_assignment.employee_id=v_standby.employee_id
      and other_assignment.id<>v_assignment.id and replacement.id is null
      and solver_private.assignment_is_currently_published_v2(other_assignment.id)
    union all
    select other_shift.shift_date,other_shift.starts_at,other_shift.ends_at
    from public.operational_assignment_replacements_v2 replacement
    join public.plan_assignments_v2 original
      on original.id=replacement.original_assignment_id
    join public.plan_shifts_v2 other_shift on other_shift.id=original.shift_id
    where replacement.replacement_employee_id=v_standby.employee_id
      and replacement.status='ACTIVE' and original.id<>v_assignment.id
      and solver_private.assignment_is_currently_published_v2(original.id)
  )
  select coalesce(sum(round(extract(epoch from(ends_at-starts_at))/60))
      filter(where shift_date>=v_standby.month
        and shift_date<(v_standby.month+interval '1 month')::date),0)::integer,
    coalesce(sum(round(extract(epoch from(ends_at-starts_at))/60))
      filter(where date_trunc('week',shift_date)=date_trunc('week',v_shift.shift_date)),0)::integer
  into v_month_minutes,v_week_minutes from effective_shifts;
  if v_enforce_work_time and v_profile.maximum_monthly_minutes>0
    and v_month_minutes+v_minutes>v_profile.maximum_monthly_minutes then
    v_reasons:=array_append(v_reasons,'MAXIMUM_MONTHLY_HOURS');
  end if;
  if v_enforce_work_time and v_profile.maximum_weekly_minutes>0
    and v_week_minutes+v_minutes>v_profile.maximum_weekly_minutes then
    v_reasons:=array_append(v_reasons,'MAXIMUM_WEEKLY_HOURS');
  end if;

  with recursive effective_days as (
    select distinct other_shift.shift_date
    from public.plan_assignments_v2 other_assignment
    join public.plan_shifts_v2 other_shift on other_shift.id=other_assignment.shift_id
    left join public.operational_assignment_replacements_v2 replacement
      on replacement.original_assignment_id=other_assignment.id
     and replacement.status='ACTIVE'
    where other_assignment.employee_id=v_standby.employee_id
      and other_assignment.id<>v_assignment.id and replacement.id is null
      and solver_private.assignment_is_currently_published_v2(other_assignment.id)
    union
    select distinct other_shift.shift_date
    from public.operational_assignment_replacements_v2 replacement
    join public.plan_assignments_v2 original
      on original.id=replacement.original_assignment_id
    join public.plan_shifts_v2 other_shift on other_shift.id=original.shift_id
    where replacement.replacement_employee_id=v_standby.employee_id
      and replacement.status='ACTIVE' and original.id<>v_assignment.id
      and solver_private.assignment_is_currently_published_v2(original.id)
  ), before_days(n,work_date) as (
    select 1,v_shift.shift_date-1
    where exists(select 1 from effective_days where shift_date=v_shift.shift_date-1)
    union all
    select before_days.n+1,before_days.work_date-1 from before_days
    where before_days.n<31 and exists(select 1 from effective_days
      where shift_date=before_days.work_date-1)
  ), after_days(n,work_date) as (
    select 1,v_shift.shift_date+1
    where exists(select 1 from effective_days where shift_date=v_shift.shift_date+1)
    union all
    select after_days.n+1,after_days.work_date+1 from after_days
    where after_days.n<31 and exists(select 1 from effective_days
      where shift_date=after_days.work_date+1)
  )
  select coalesce((select max(n) from before_days),0),
    coalesce((select max(n) from after_days),0)
  into v_before,v_after;
  if v_enforce_work_time and v_profile.maximum_consecutive_days>0
    and v_before+1+v_after>v_profile.maximum_consecutive_days then
    v_reasons:=array_append(v_reasons,'MAX_CONSECUTIVE_DAYS');
  end if;
  return v_reasons;
end;
$$;


ALTER FUNCTION "solver_private"."standby_activation_reasons_uat_v2"("p_standby_id" "uuid", "p_original_assignment_id" "uuid") OWNER TO "postgres";

--
-- Name: standby_candidates_for_group_day_uat_v1("uuid", "uuid", "date", "uuid"[], "date"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."standby_candidates_for_group_day_uat_v1"("p_variant_id" "uuid", "p_matrix_version_id" "uuid", "p_month" "date", "p_role_ids" "uuid"[], "p_date" "date") RETURNS TABLE("employee_id" "uuid", "employee_no" "text", "eligible_role_ids" "uuid"[])
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  with settings as (
    select coalesce((matrix.settings->>'missingAvailabilityMeansAvailable')::boolean,true) default_available,
      coalesce((matrix.settings->>'minimumRestMinutes')::integer,660) default_rest
    from public.matrix_versions matrix where matrix.id=p_matrix_version_id
  ), group_shifts as (
    select distinct shift_row.id,shift_row.location_id,shift_row.shift_template_id,shift_row.starts_at,shift_row.ends_at
    from public.plan_assignments_v2 assignment join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
    where assignment.variant_id=p_variant_id and assignment.role_id=any(p_role_ids) and shift_row.shift_date=p_date
    union
    select distinct shift_row.id,shift_row.location_id,shift_row.shift_template_id,shift_row.starts_at,shift_row.ends_at
    from public.plan_issues_v2 issue join public.plan_shifts_v2 shift_row on shift_row.id=issue.shift_id
    where issue.variant_id=p_variant_id and issue.role_id=any(p_role_ids) and shift_row.shift_date=p_date
  ), candidates as (
    select profile.employee_id,profile.employee_no,
      array_agg(distinct role_grant.role_id order by role_grant.role_id) eligible_roles,
      case when coalesce(hr.contract_type,'INNE') in ('ZLECENIE','B2B') and profile.work_time_policy<>'CUSTOM' then 0
        else coalesce(profile.minimum_rest_minutes,settings.default_rest,660) end rest_minutes
    from public.matrix_employee_profiles_v2 profile
    cross join settings
    left join public.employee_hr_profiles hr on hr.employee_id=profile.employee_id
    join public.matrix_employee_roles_v2 role_grant
      on role_grant.matrix_version_id=p_matrix_version_id and role_grant.employee_id=profile.employee_id
     and role_grant.role_id=any(p_role_ids) and role_grant.active
     and (role_grant.valid_from is null or role_grant.valid_from<=p_date)
     and (role_grant.valid_to is null or role_grant.valid_to>=p_date)
    where profile.matrix_version_id=p_matrix_version_id and profile.active and profile.archived_at is null
      and (profile.employment_start is null or profile.employment_start<=p_date)
      and (profile.employment_end is null or profile.employment_end>=p_date)
      and (not profile.no_weekends or extract(isodow from p_date) not in (6,7))
      and (not profile.only_morning or not exists(select 1 from group_shifts group_shift
        join public.matrix_shift_templates_v2 template on template.id=group_shift.shift_template_id where template.shift_period<>'MORNING'))
      and (not profile.only_evening or not exists(select 1 from group_shifts group_shift
        join public.matrix_shift_templates_v2 template on template.id=group_shift.shift_template_id where template.shift_period<>'EVENING'))
      and not exists(select 1 from public.plan_assignments_v2 assignment
        join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
        where assignment.variant_id=p_variant_id and assignment.employee_id=profile.employee_id and shift_row.shift_date=p_date)
      and not exists(select 1 from public.published_role_schedules_v2 publication
        join public.plan_assignments_v2 assignment on assignment.variant_id=publication.variant_id
        join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
        where publication.month=p_month and publication.status='PUBLISHED'
          and assignment.employee_id=profile.employee_id and shift_row.shift_date=p_date)
      and not exists(select 1 from public.published_standby_assignments_v2 standby
        where standby.month=p_month and standby.standby_date=p_date and standby.employee_id=profile.employee_id
          and standby.status in ('PLANNED','ACTIVATED'))
      and not exists(select 1 from group_shifts group_shift where not exists(
        select 1 from public.matrix_employee_locations_v2 location_grant
        where location_grant.matrix_version_id=p_matrix_version_id and location_grant.employee_id=profile.employee_id
          and location_grant.location_id=group_shift.location_id and location_grant.active and location_grant.standard_allowed
          and (location_grant.valid_from is null or location_grant.valid_from<=p_date)
          and (location_grant.valid_to is null or location_grant.valid_to>=p_date)))
      and not exists(select 1 from group_shifts group_shift join public.employee_time_constraints_v2 constraint_row
        on constraint_row.employee_id=profile.employee_id and constraint_row.status='ACTIVE'
       and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
       and constraint_row.time_range&&tstzrange(group_shift.starts_at,group_shift.ends_at,'[)'))
      and (settings.default_available or exists(select 1 from public.employee_time_constraints_v2 window_row
        where window_row.employee_id=profile.employee_id and window_row.status='ACTIVE'
          and window_row.constraint_kind='AVAILABLE_WINDOW'
          and lower(window_row.time_range)<=(select min(starts_at) from group_shifts)
          and upper(window_row.time_range)>=(select max(ends_at) from group_shifts)))
    group by profile.employee_id,profile.employee_no,hr.contract_type,profile.work_time_policy,
      profile.minimum_rest_minutes,settings.default_rest
  )
  select candidate.employee_id,candidate.employee_no,candidate.eligible_roles from candidates candidate
  where not exists(select 1 from public.plan_assignments_v2 assignment
    join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
    where assignment.variant_id=p_variant_id and assignment.employee_id=candidate.employee_id
      and ((shift_row.ends_at<=(select min(starts_at) from group_shifts)
          and extract(epoch from ((select min(starts_at) from group_shifts)-shift_row.ends_at))/60<candidate.rest_minutes)
        or (shift_row.starts_at>=(select max(ends_at) from group_shifts)
          and extract(epoch from (shift_row.starts_at-(select max(ends_at) from group_shifts)))/60<candidate.rest_minutes)))
$$;


ALTER FUNCTION "solver_private"."standby_candidates_for_group_day_uat_v1"("p_variant_id" "uuid", "p_matrix_version_id" "uuid", "p_month" "date", "p_role_ids" "uuid"[], "p_date" "date") OWNER TO "postgres";

--
-- Name: standby_candidates_for_role_day_uat_v3("uuid", "uuid", "date", "uuid", "date"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."standby_candidates_for_role_day_uat_v3"("p_variant_id" "uuid", "p_matrix_version_id" "uuid", "p_month" "date", "p_role_id" "uuid", "p_date" "date") RETURNS TABLE("employee_id" "uuid", "employee_no" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  with settings as (
    select coalesce((matrix.settings->>'missingAvailabilityMeansAvailable')::boolean,true) default_available,
      coalesce((matrix.settings->>'minimumRestMinutes')::integer,660) default_rest
    from public.matrix_versions matrix where matrix.id=p_matrix_version_id
  ), role_shifts as (
    select distinct shift_row.id,shift_row.location_id,shift_row.shift_template_id,
      shift_row.starts_at,shift_row.ends_at
    from public.plan_assignments_v2 assignment
    join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
    where assignment.variant_id=p_variant_id and assignment.role_id=p_role_id
      and shift_row.shift_date=p_date
    union
    select distinct shift_row.id,shift_row.location_id,shift_row.shift_template_id,
      shift_row.starts_at,shift_row.ends_at
    from public.plan_issues_v2 issue
    join public.plan_shifts_v2 shift_row on shift_row.id=issue.shift_id
    where issue.variant_id=p_variant_id and issue.role_id=p_role_id
      and shift_row.shift_date=p_date
  ), candidates as (
    select profile.employee_id,profile.employee_no,
      case when coalesce(hr.contract_type,'INNE') in ('ZLECENIE','B2B')
          and profile.work_time_policy<>'CUSTOM' then 0
        else coalesce(profile.minimum_rest_minutes,settings.default_rest,660)
      end rest_minutes
    from public.matrix_employee_profiles_v2 profile
    cross join settings
    left join public.employee_hr_profiles hr on hr.employee_id=profile.employee_id
    where profile.matrix_version_id=p_matrix_version_id
      and profile.active and profile.archived_at is null
      and (profile.employment_start is null or profile.employment_start<=p_date)
      and (profile.employment_end is null or profile.employment_end>=p_date)
      and (not profile.no_weekends or extract(isodow from p_date) not in (6,7))
      and (not profile.only_morning or not exists(
        select 1 from role_shifts role_shift
        join public.matrix_shift_templates_v2 template on template.id=role_shift.shift_template_id
        where template.shift_period<>'MORNING'))
      and (not profile.only_evening or not exists(
        select 1 from role_shifts role_shift
        join public.matrix_shift_templates_v2 template on template.id=role_shift.shift_template_id
        where template.shift_period<>'EVENING'))
      and exists(select 1 from public.matrix_employee_roles_v2 role_grant
        where role_grant.matrix_version_id=p_matrix_version_id
          and role_grant.employee_id=profile.employee_id and role_grant.role_id=p_role_id
          and role_grant.active
          and (role_grant.valid_from is null or role_grant.valid_from<=p_date)
          and (role_grant.valid_to is null or role_grant.valid_to>=p_date))
      and not exists(select 1 from public.plan_assignments_v2 assignment
        join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
        where assignment.variant_id=p_variant_id and assignment.employee_id=profile.employee_id
          and shift_row.shift_date=p_date)
      and not exists(select 1 from public.published_role_schedules_v2 publication
        join public.plan_assignments_v2 assignment on assignment.variant_id=publication.variant_id
        join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
        where publication.month=p_month and publication.status='PUBLISHED'
          and assignment.employee_id=profile.employee_id and shift_row.shift_date=p_date)
      and not exists(select 1 from public.published_standby_assignments_v2 standby
        where standby.month=p_month and standby.standby_date=p_date
          and standby.employee_id=profile.employee_id
          and standby.status in ('PLANNED','ACTIVATED'))
      and not exists(select 1 from role_shifts role_shift
        where not exists(select 1 from public.matrix_employee_locations_v2 location_grant
          where location_grant.matrix_version_id=p_matrix_version_id
            and location_grant.employee_id=profile.employee_id
            and location_grant.location_id=role_shift.location_id
            and location_grant.active and location_grant.standard_allowed
            and (location_grant.valid_from is null or location_grant.valid_from<=p_date)
            and (location_grant.valid_to is null or location_grant.valid_to>=p_date)))
      and not exists(select 1 from role_shifts role_shift
        join public.employee_time_constraints_v2 constraint_row
          on constraint_row.employee_id=profile.employee_id and constraint_row.status='ACTIVE'
         and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
         and constraint_row.time_range&&tstzrange(role_shift.starts_at,role_shift.ends_at,'[)'))
      and (settings.default_available or exists(select 1
        from public.employee_time_constraints_v2 window_row
        where window_row.employee_id=profile.employee_id and window_row.status='ACTIVE'
          and window_row.constraint_kind='AVAILABLE_WINDOW'
          and lower(window_row.time_range)<=(select min(starts_at) from role_shifts)
          and upper(window_row.time_range)>=(select max(ends_at) from role_shifts)))
  )
  select candidate.employee_id,candidate.employee_no from candidates candidate
  where not exists(select 1 from public.plan_assignments_v2 assignment
    join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
    where assignment.variant_id=p_variant_id and assignment.employee_id=candidate.employee_id
      and ((shift_row.ends_at<=(select min(starts_at) from role_shifts)
          and extract(epoch from ((select min(starts_at) from role_shifts)-shift_row.ends_at))/60<candidate.rest_minutes)
        or (shift_row.starts_at>=(select max(ends_at) from role_shifts)
          and extract(epoch from (shift_row.starts_at-(select max(ends_at) from role_shifts)))/60<candidate.rest_minutes)))
$$;


ALTER FUNCTION "solver_private"."standby_candidates_for_role_day_uat_v3"("p_variant_id" "uuid", "p_matrix_version_id" "uuid", "p_month" "date", "p_role_id" "uuid", "p_date" "date") OWNER TO "postgres";

--
-- Name: strategy_config_hash_uat_v1("jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."strategy_config_hash_uat_v1"("p_snapshot" "jsonb") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  select encode(extensions.digest(convert_to(
    coalesce((
      select jsonb_agg(
        solver_private.strip_temporal_json_uat_v1(item.value)
        order by item.value->>'code',item.value->>'id',item.ordinality
      )
      from jsonb_array_elements(coalesce(p_snapshot->'strategies','[]'::jsonb))
        with ordinality item(value,ordinality)
    ),'[]'::jsonb)::text,
    'UTF8'
  ),'sha256'),'hex')
$$;


ALTER FUNCTION "solver_private"."strategy_config_hash_uat_v1"("p_snapshot" "jsonb") OWNER TO "postgres";

--
-- Name: strip_temporal_json_uat_v1("jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."strip_temporal_json_uat_v1"("p_value" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
declare
  v_type text:=jsonb_typeof(p_value);
  v_result jsonb;
begin
  if v_type='object' then
    select coalesce(jsonb_object_agg(item.key,
      solver_private.strip_temporal_json_uat_v1(item.value)),'{}'::jsonb)
    into v_result
    from jsonb_each(p_value) item
    where item.key not in (
      'createdAt','created_at','updatedAt','updated_at','activatedAt',
      'activated_at','publishedAt','published_at','timestamp','generatedAt'
    );
    return v_result;
  elsif v_type='array' then
    select coalesce(jsonb_agg(
      solver_private.strip_temporal_json_uat_v1(item.value)
      order by item.ordinality
    ),'[]'::jsonb)
    into v_result
    from jsonb_array_elements(p_value) with ordinality item(value,ordinality);
    return v_result;
  end if;
  return p_value;
end;
$$;


ALTER FUNCTION "solver_private"."strip_temporal_json_uat_v1"("p_value" "jsonb") OWNER TO "postgres";

--
-- Name: supersede_previous_logical_role_schedule_uat_v2(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."supersede_previous_logical_role_schedule_uat_v2"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_logical_role_id uuid;
begin
  select role.logical_id into v_logical_role_id
  from public.matrix_roles_v2 role
  where role.id=new.role_id;
  if v_logical_role_id is null then
    raise exception 'ROLE_LOGICAL_ID_MISSING';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'publish-v2-logical-role:'||new.month::text||':'||v_logical_role_id::text,0
  ));

  update public.published_role_schedules_v2 publication
  set status='ARCHIVED',
      archived_at=now(),
      archived_by=coalesce(auth.uid(),new.created_by)
  from public.matrix_roles_v2 previous_role
  where publication.role_id=previous_role.id
    and publication.id<>new.id
    and publication.month=new.month
    and publication.status='PUBLISHED'
    and previous_role.logical_id=v_logical_role_id;
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."supersede_previous_logical_role_schedule_uat_v2"() OWNER TO "postgres";

--
-- Name: supersede_standby_with_source_v2(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."supersede_standby_with_source_v2"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if old.status='PUBLISHED' and new.status='ARCHIVED' then
    if tg_table_name='published_role_schedules_v2' then
      update public.published_standby_assignments_v2 standby set status='SUPERSEDED'
      where standby.source_role_schedule_id=new.id and standby.status='PLANNED';
    else
      update public.published_standby_assignments_v2 standby set status='SUPERSEDED'
      where standby.source_schedule_id=new.id and standby.status='PLANNED';
    end if;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."supersede_standby_with_source_v2"() OWNER TO "postgres";

--
-- Name: swap_alternate_duty_coverage_uat_v2("uuid", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."swap_alternate_duty_coverage_uat_v2"("p_request_id" "uuid", "p_employee_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_request public.shift_swap_requests_v2%rowtype;
  v_assignment public.plan_assignments_v2%rowtype;
begin
  select * into v_request from public.shift_swap_requests_v2 where id=p_request_id;
  select * into v_assignment from public.plan_assignments_v2
    where id=v_request.original_assignment_id;
  if v_request.id is null or v_assignment.id is null then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'dutyId',missing.duty_id,'dutyName',duty.name,
      'coveredByEmployeeId',coverage.employee_id,
      'coveredByEmployeeName',coverage.employee_name
    ) order by duty.name)
    from (
      select distinct required_duty.duty_id
      from public.plan_assignment_duties_v2 required_duty
      where required_duty.assignment_id=v_assignment.id
        and not exists(
          select 1 from public.matrix_employee_duties_v2 own_capability
          where own_capability.matrix_version_id=v_request.matrix_version_id
            and own_capability.employee_id=p_employee_id
            and own_capability.duty_id=required_duty.duty_id
            and own_capability.active
            and (own_capability.role_id is null
              or own_capability.role_id=v_assignment.role_id)
        )
    ) missing
    join public.matrix_duties_v2 duty on duty.id=missing.duty_id
    cross join lateral (
      select effective.employee_id,
        profile.first_name||' '||profile.last_name employee_name
      from public.plan_assignments_v2 other_assignment
      left join public.operational_assignment_replacements_v2 replacement
        on replacement.original_assignment_id=other_assignment.id
        and replacement.status='ACTIVE'
      cross join lateral (select coalesce(
        replacement.replacement_employee_id,other_assignment.employee_id
      ) employee_id) effective
      join public.matrix_employee_profiles_v2 profile
        on profile.matrix_version_id=v_request.matrix_version_id
        and profile.employee_id=effective.employee_id
      where other_assignment.shift_id=v_assignment.shift_id
        and other_assignment.id<>v_assignment.id
        and exists(
          select 1 from public.matrix_employee_duties_v2 capability
          where capability.matrix_version_id=v_request.matrix_version_id
            and capability.employee_id=effective.employee_id
            and capability.duty_id=missing.duty_id and capability.active
            and (capability.role_id is null
              or capability.role_id=other_assignment.role_id)
        )
      order by profile.employee_no limit 1
    ) coverage
  ),'[]'::jsonb);
end;
$$;


ALTER FUNCTION "solver_private"."swap_alternate_duty_coverage_uat_v2"("p_request_id" "uuid", "p_employee_id" "uuid") OWNER TO "postgres";

--
-- Name: swap_candidate_reasons_direct_uat_v2("uuid", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."swap_candidate_reasons_direct_uat_v2"("p_request_id" "uuid", "p_employee_id" "uuid") RETURNS "text"[]
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_request public.shift_swap_requests_v2%rowtype;
  v_assignment public.plan_assignments_v2%rowtype;
  v_shift public.plan_shifts_v2%rowtype;
  v_profile public.matrix_employee_profiles_v2%rowtype;
  v_reasons text[]:='{}'::text[];
  v_minutes integer; v_month_minutes integer; v_week_minutes integer;
  v_rest integer;
begin
  select * into v_request from public.shift_swap_requests_v2 where id=p_request_id;
  if v_request.id is null then return array['SWAP_REQUEST_NOT_FOUND']; end if;
  select * into v_assignment from public.plan_assignments_v2
    where id=v_request.original_assignment_id;
  select * into v_shift from public.plan_shifts_v2 where id=v_assignment.shift_id;
  select * into v_profile from public.matrix_employee_profiles_v2 profile
  where profile.matrix_version_id=v_request.matrix_version_id
    and profile.employee_id=p_employee_id and profile.active
    and profile.archived_at is null;
  if v_profile.id is null then v_reasons:=array_append(v_reasons,'EMPLOYEE_NOT_ACTIVE'); end if;
  if p_employee_id=v_request.proposer_employee_id then
    v_reasons:=array_append(v_reasons,'CANNOT_SWAP_WITH_SELF');
  end if;
  if v_request.target_employee_id is not null
    and v_request.target_employee_id<>p_employee_id then
    v_reasons:=array_append(v_reasons,'NOT_REQUEST_TARGET');
  end if;
  if not solver_private.assignment_is_currently_published_v2(v_assignment.id) then
    v_reasons:=array_append(v_reasons,'ASSIGNMENT_NOT_PUBLISHED');
  end if;
  if v_shift.starts_at<=now() then v_reasons:=array_append(v_reasons,'SHIFT_ALREADY_STARTED'); end if;
  if not exists(select 1 from public.matrix_employee_roles_v2 role_grant
      where role_grant.matrix_version_id=v_request.matrix_version_id
        and role_grant.employee_id=p_employee_id and role_grant.role_id=v_assignment.role_id
        and role_grant.active
        and (role_grant.valid_from is null or role_grant.valid_from<=v_shift.shift_date)
        and (role_grant.valid_to is null or role_grant.valid_to>=v_shift.shift_date)) then
    v_reasons:=array_append(v_reasons,'ROLE_REQUIRED');
  end if;
  if not exists(select 1 from public.matrix_employee_locations_v2 location_grant
      where location_grant.matrix_version_id=v_request.matrix_version_id
        and location_grant.employee_id=p_employee_id
        and location_grant.location_id=v_shift.location_id
        and location_grant.active and location_grant.standard_allowed
        and (location_grant.valid_from is null or location_grant.valid_from<=v_shift.shift_date)
        and (location_grant.valid_to is null or location_grant.valid_to>=v_shift.shift_date)) then
    v_reasons:=array_append(v_reasons,'LOCATION_NOT_ALLOWED');
  end if;
  if exists(select 1 from public.plan_assignment_duties_v2 required_duty
      where required_duty.assignment_id=v_assignment.id and not exists(
        select 1 from public.matrix_employee_duties_v2 employee_duty
        where employee_duty.matrix_version_id=v_request.matrix_version_id
          and employee_duty.employee_id=p_employee_id
          and employee_duty.duty_id=required_duty.duty_id and employee_duty.active
          and (employee_duty.role_id is null or employee_duty.role_id=v_assignment.role_id)
          and (employee_duty.location_id is null or employee_duty.location_id=v_shift.location_id)
          and (employee_duty.valid_from is null or employee_duty.valid_from<=v_shift.shift_date)
          and (employee_duty.valid_to is null or employee_duty.valid_to>=v_shift.shift_date)
      )) then v_reasons:=array_append(v_reasons,'DUTY_REQUIRED'); end if;
  if exists(select 1 from public.employee_time_constraints_v2 constraint_row
      where constraint_row.employee_id=p_employee_id and constraint_row.status='ACTIVE'
        and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
        and constraint_row.time_range && tstzrange(v_shift.starts_at,v_shift.ends_at,'[)')) then
    v_reasons:=array_append(v_reasons,'HARD_UNAVAILABLE');
  end if;
  if exists(select 1 from public.published_standby_assignments_v2 standby
      where standby.employee_id=p_employee_id and standby.standby_date=v_shift.shift_date
        and standby.status in ('PLANNED','ACTIVATED')) then
    v_reasons:=array_append(v_reasons,'STANDBY_CONFLICT');
  end if;
  if coalesce(v_profile.no_weekends,false)
    and extract(isodow from v_shift.shift_date) in (6,7) then
    v_reasons:=array_append(v_reasons,'NO_WEEKENDS');
  end if;
  if v_profile.employment_start is not null and v_profile.employment_start>v_shift.shift_date
    or v_profile.employment_end is not null and v_profile.employment_end<v_shift.shift_date then
    v_reasons:=array_append(v_reasons,'OUTSIDE_EMPLOYMENT');
  end if;
  if coalesce(v_profile.only_morning,false) and extract(hour from v_shift.starts_at at time zone
      coalesce((select location.timezone from public.matrix_locations_v2 location
        where location.id=v_shift.location_id),'Europe/Warsaw'))>=15 then
    v_reasons:=array_append(v_reasons,'ONLY_MORNING');
  end if;
  if coalesce(v_profile.only_evening,false) and extract(hour from v_shift.starts_at at time zone
      coalesce((select location.timezone from public.matrix_locations_v2 location
        where location.id=v_shift.location_id),'Europe/Warsaw'))<15 then
    v_reasons:=array_append(v_reasons,'ONLY_EVENING');
  end if;

  v_rest:=coalesce(v_profile.minimum_rest_minutes,0);
  if exists(
    select 1 from public.plan_assignments_v2 other_assignment
    join public.plan_shifts_v2 other_shift on other_shift.id=other_assignment.shift_id
    where other_assignment.employee_id=p_employee_id
      and other_assignment.id<>v_assignment.id
      and solver_private.assignment_is_currently_published_v2(other_assignment.id)
      and other_shift.ends_at+(v_rest*interval '1 minute')>v_shift.starts_at
      and v_shift.ends_at+(v_rest*interval '1 minute')>other_shift.starts_at
  ) or exists(
    select 1 from public.operational_assignment_replacements_v2 replacement
    join public.plan_assignments_v2 original on original.id=replacement.original_assignment_id
    join public.plan_shifts_v2 other_shift on other_shift.id=original.shift_id
    where replacement.replacement_employee_id=p_employee_id and replacement.status='ACTIVE'
      and other_shift.ends_at+(v_rest*interval '1 minute')>v_shift.starts_at
      and v_shift.ends_at+(v_rest*interval '1 minute')>other_shift.starts_at
  ) then v_reasons:=array_append(v_reasons,'SHIFT_OR_REST_CONFLICT'); end if;

  v_minutes:=greatest(0,round(extract(epoch from(v_shift.ends_at-v_shift.starts_at))/60)::integer);
  select coalesce(sum(round(extract(epoch from(other_shift.ends_at-other_shift.starts_at))/60)),0)::integer
  into v_month_minutes
  from public.plan_assignments_v2 other_assignment
  join public.plan_shifts_v2 other_shift on other_shift.id=other_assignment.shift_id
  where other_assignment.employee_id=p_employee_id
    and other_shift.shift_date>=v_request.month
    and other_shift.shift_date<(v_request.month+interval '1 month')::date
    and solver_private.assignment_is_currently_published_v2(other_assignment.id);
  select coalesce(sum(round(extract(epoch from(other_shift.ends_at-other_shift.starts_at))/60)),0)::integer
  into v_week_minutes
  from public.plan_assignments_v2 other_assignment
  join public.plan_shifts_v2 other_shift on other_shift.id=other_assignment.shift_id
  where other_assignment.employee_id=p_employee_id
    and date_trunc('week',other_shift.shift_date)=date_trunc('week',v_shift.shift_date)
    and solver_private.assignment_is_currently_published_v2(other_assignment.id);
  if v_profile.maximum_monthly_minutes>0
    and v_month_minutes+v_minutes>v_profile.maximum_monthly_minutes then
    v_reasons:=array_append(v_reasons,'MAXIMUM_MONTHLY_HOURS');
  end if;
  if v_profile.maximum_weekly_minutes>0
    and v_week_minutes+v_minutes>v_profile.maximum_weekly_minutes then
    v_reasons:=array_append(v_reasons,'MAXIMUM_WEEKLY_HOURS');
  end if;
  return v_reasons;
end;
$$;


ALTER FUNCTION "solver_private"."swap_candidate_reasons_direct_uat_v2"("p_request_id" "uuid", "p_employee_id" "uuid") OWNER TO "postgres";

--
-- Name: swap_candidate_reasons_uat_v2("uuid", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."swap_candidate_reasons_uat_v2"("p_request_id" "uuid", "p_employee_id" "uuid") RETURNS "text"[]
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_reasons text[];
  v_request public.shift_swap_requests_v2%rowtype;
  v_assignment public.plan_assignments_v2%rowtype;
  v_missing integer:=0; v_coverage jsonb;
begin
  v_reasons:=solver_private.swap_candidate_reasons_direct_uat_v2(
    p_request_id,p_employee_id
  );
  if 'DUTY_REQUIRED'=any(v_reasons) then
    select * into v_request from public.shift_swap_requests_v2 where id=p_request_id;
    select * into v_assignment from public.plan_assignments_v2
      where id=v_request.original_assignment_id;
    select count(distinct required_duty.duty_id) into v_missing
    from public.plan_assignment_duties_v2 required_duty
    where required_duty.assignment_id=v_assignment.id
      and not exists(
        select 1 from public.matrix_employee_duties_v2 capability
        where capability.matrix_version_id=v_request.matrix_version_id
          and capability.employee_id=p_employee_id
          and capability.duty_id=required_duty.duty_id and capability.active
          and (capability.role_id is null or capability.role_id=v_assignment.role_id)
      );
    v_coverage:=solver_private.swap_alternate_duty_coverage_uat_v2(
      p_request_id,p_employee_id
    );
    if v_missing>0 and jsonb_array_length(v_coverage)=v_missing then
      v_reasons:=array_remove(v_reasons,'DUTY_REQUIRED');
    end if;
  end if;
  return v_reasons;
end;
$$;


ALTER FUNCTION "solver_private"."swap_candidate_reasons_uat_v2"("p_request_id" "uuid", "p_employee_id" "uuid") OWNER TO "postgres";

--
-- Name: swap_history_coverage_uat006(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."swap_history_coverage_uat006"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_employee uuid;
begin
  if new.action='LEADER_APPROVE' then
    select request.accepted_by_employee_id into v_employee
    from public.shift_swap_requests_v2 request where request.id=new.request_id;
    new.details:=new.details||jsonb_build_object(
      'alternateDutyCoverage',
      solver_private.swap_alternate_duty_coverage_uat_v2(
        new.request_id,v_employee
      )
    );
  end if;
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."swap_history_coverage_uat006"() OWNER TO "postgres";

--
-- Name: sync_employee_availability_v2(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."sync_employee_availability_v2"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_row public.employee_availability%rowtype;
  v_timezone text;
  v_range tstzrange;
  v_kind text;
begin
  if tg_op='DELETE' then
    v_row:=old;
    perform solver_private.replace_time_constraint_v2(
      v_row.employee_id,null,null,v_row.source,'availability:'||v_row.id::text,
      v_row.note,v_row.updated_by,now()
    );
    return old;
  end if;
  v_row:=new;
  select nullif(mv.settings->>'timezone','') into v_timezone
  from public.matrix_versions mv
  where mv.status='ACTIVE' and mv.schema_version>=2
  order by mv.version desc limit 1;
  if v_timezone is null or not exists(
    select 1 from pg_catalog.pg_timezone_names tz where tz.name=v_timezone
  ) then raise exception 'INVALID_MATRIX_TIMEZONE'; end if;

  v_kind:=case when v_row.available then 'AVAILABLE_WINDOW' else 'UNAVAILABLE' end;
  v_range:=case when not v_row.available then
    tstzrange(
      v_row.work_date::timestamp at time zone v_timezone,
      (v_row.work_date+1)::timestamp at time zone v_timezone,'[)'
    )
  else
    tstzrange(
      (v_row.work_date+coalesce(v_row.earliest_start,time '00:00'))
        at time zone v_timezone,
      case
        when v_row.latest_end is null then
          (v_row.work_date+1)::timestamp at time zone v_timezone
        when v_row.latest_end<=coalesce(v_row.earliest_start,time '00:00') then
          ((v_row.work_date+1)+v_row.latest_end) at time zone v_timezone
        else (v_row.work_date+v_row.latest_end) at time zone v_timezone
      end,'[)'
    )
  end;
  perform solver_private.replace_time_constraint_v2(
    v_row.employee_id,v_kind,v_range,v_row.source,
    'availability:'||v_row.id::text,v_row.note,v_row.updated_by,v_row.updated_at
  );
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."sync_employee_availability_v2"() OWNER TO "postgres";

--
-- Name: sync_employee_preference_v2(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."sync_employee_preference_v2"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_row public.employee_preferences%rowtype;
  v_timezone text;
  v_kind text;
  v_range tstzrange;
begin
  v_row:=case when tg_op='DELETE' then old else new end;
  v_kind:=case
    when tg_op<>'DELETE' and v_row.status='ACTIVE'
      and v_row.preference_type in ('UNAVAILABLE','LEAVE','SICKNESS')
    then v_row.preference_type::text else null end;
  if v_kind is not null then
    select nullif(mv.settings->>'timezone','') into v_timezone
    from public.matrix_versions mv
    where mv.status='ACTIVE' and mv.schema_version>=2
    order by mv.version desc limit 1;
    if v_timezone is null or not exists(
      select 1 from pg_catalog.pg_timezone_names tz where tz.name=v_timezone
    ) then raise exception 'INVALID_MATRIX_TIMEZONE'; end if;
    v_range:=tstzrange(
      v_row.valid_from::timestamp at time zone v_timezone,
      (v_row.valid_to+1)::timestamp at time zone v_timezone,'[)'
    );
  end if;
  perform solver_private.replace_time_constraint_v2(
    v_row.employee_id,v_kind,v_range,v_row.source,
    'preference:'||v_row.id::text,v_row.preference_value->>'note',
    auth.uid(),coalesce(v_row.created_at,now())
  );
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."sync_employee_preference_v2"() OWNER TO "postgres";

--
-- Name: sync_leader_workflow_published_uat_v1(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."sync_leader_workflow_published_uat_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if new.variant_kind='LEADER_COPY' and new.status='PUBLISHED' then new.leader_workflow_status:='PUBLISHED'; end if;
  return new;
end;$$;


ALTER FUNCTION "solver_private"."sync_leader_workflow_published_uat_v1"() OWNER TO "postgres";

--
-- Name: uat_master_employee_constraints_v2("uuid", "date", "uuid", "text"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."uat_master_employee_constraints_v2"("p_employee_id" "uuid", "p_month" "date", "p_matrix" "uuid", "p_timezone" "text") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
  with bounds as (
    select p_month::timestamp at time zone p_timezone period_start,
      (p_month+interval '1 month')::timestamp at time zone p_timezone period_end
  ), entries as (
    select constraint_row.id,constraint_row.constraint_kind kind,
      lower(constraint_row.time_range) starts_at,upper(constraint_row.time_range) ends_at,
      constraint_row.source,constraint_row.source='GRAFIK_PRO'
        and constraint_row.editable_by_employee editable,constraint_row.note,
      (select location.id from public.matrix_locations_v2 location
       where location.matrix_version_id=p_matrix
         and location.logical_id=constraint_row.location_logical_id
       order by location.active desc,location.sort_order limit 1) preferred_location_id
    from public.employee_time_constraints_v2 constraint_row,bounds
    where constraint_row.employee_id=p_employee_id and constraint_row.status='ACTIVE'
      and constraint_row.time_range && tstzrange(bounds.period_start,bounds.period_end,'[)')
    union all
    select preference.id,
      case when preference.preference_type='OTHER' then 'PREFER_NOT_TO_WORK'
        else 'PREFERRED_LOCATION' end,
      preference.valid_from::timestamp at time zone p_timezone,
      (preference.valid_to+1)::timestamp at time zone p_timezone,
      preference.source,preference.source='GRAFIK_PRO' and preference.editable_by_employee,
      nullif(preference.preference_value->>'note',''),
      case when preference.preference_type='PREFERRED_LOCATION'
        and preference.preference_value->>'locationId'
          ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
        then (preference.preference_value->>'locationId')::uuid else null end
    from public.employee_preferences preference
    where preference.employee_id=p_employee_id and preference.status='ACTIVE'
      and preference.valid_from<p_month+interval '1 month' and preference.valid_to>=p_month
      and (preference.preference_type='PREFERRED_LOCATION' or
        (preference.preference_type='OTHER'
         and preference.preference_value->>'kind'='DAY_OFF'
         and preference.preference_value->>'strength'='SOFT'))
  )
  select jsonb_build_object('employeeId',p_employee_id,'timezone',p_timezone,
    'defaultAvailable',true,'constraints',coalesce(jsonb_agg(jsonb_strip_nulls(
      jsonb_build_object('id',entry.id,'kind',entry.kind,'startsAt',entry.starts_at,
        'endsAt',entry.ends_at,'source',entry.source,'editable',entry.editable,
        'note',entry.note,'preferredLocationId',entry.preferred_location_id))
      order by entry.starts_at,entry.ends_at,entry.id),'[]'::jsonb)) from entries entry
$_$;


ALTER FUNCTION "solver_private"."uat_master_employee_constraints_v2"("p_employee_id" "uuid", "p_month" "date", "p_matrix" "uuid", "p_timezone" "text") OWNER TO "postgres";

--
-- Name: uat_master_save_employee_day_v2("uuid", "uuid", "date", "text", boolean, time without time zone, time without time zone, "uuid", "text"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."uat_master_save_employee_day_v2"("p_actor" "uuid", "p_employee_id" "uuid", "p_day" "date", "p_kind" "text", "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone, "p_preferred_location_id" "uuid", "p_note" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_timezone text; v_start timestamptz; v_end timestamptz;
  v_location_logical_id uuid; v_preference public.employee_preferences%rowtype;
  v_constraint public.employee_time_constraints_v2%rowtype;
begin
  select matrix.settings->>'timezone' into v_timezone from public.matrix_versions matrix
  where matrix.status='ACTIVE' and matrix.schema_version>=2
  order by matrix.effective_from desc,matrix.version desc limit 1;
  if v_timezone is null then raise exception 'MATRIX_TIMEZONE_REQUIRED'; end if;
  v_start:=p_day::timestamp at time zone v_timezone;
  v_end:=(p_day+1)::timestamp at time zone v_timezone;
  if not p_all_day then
    if p_local_start is null or p_local_end is null or p_local_end=p_local_start then
      raise exception 'HOURS_REQUIRED';
    end if;
    v_start:=(p_day+p_local_start)::timestamp at time zone v_timezone;
    v_end:=case when p_local_end>p_local_start
      then (p_day+p_local_end)::timestamp at time zone v_timezone
      else (p_day+1+p_local_end)::timestamp at time zone v_timezone end;
  end if;
  if p_preferred_location_id is not null then
    select location.logical_id into v_location_logical_id
    from public.matrix_locations_v2 location join public.matrix_versions matrix
      on matrix.id=location.matrix_version_id
    where location.id=p_preferred_location_id and location.active and matrix.status='ACTIVE';
    if v_location_logical_id is null then raise exception 'PREFERRED_LOCATION_NOT_FOUND'; end if;
  end if;
  for v_preference in select preference.* from public.employee_preferences preference
    where preference.employee_id=p_employee_id and preference.status='ACTIVE'
      and preference.source='GRAFIK_PRO' and preference.editable_by_employee
      and preference.preference_type in ('OTHER','PREFERRED_LOCATION')
      and preference.valid_from<=p_day and preference.valid_to>=p_day for update
  loop
    update public.employee_preferences set status='CANCELLED' where id=v_preference.id;
    if v_preference.valid_from<p_day then
      insert into public.employee_preferences(employee_id,valid_from,valid_to,preference_type,
        preference_value,source,editable_by_employee,status)
      values(p_employee_id,v_preference.valid_from,p_day-1,v_preference.preference_type,
        v_preference.preference_value,'GRAFIK_PRO',true,'ACTIVE');
    end if;
    if v_preference.valid_to>p_day then
      insert into public.employee_preferences(employee_id,valid_from,valid_to,preference_type,
        preference_value,source,editable_by_employee,status)
      values(p_employee_id,p_day+1,v_preference.valid_to,v_preference.preference_type,
        v_preference.preference_value,'GRAFIK_PRO',true,'ACTIVE');
    end if;
  end loop;
  for v_constraint in select constraint_row.* from public.employee_time_constraints_v2 constraint_row
    where constraint_row.employee_id=p_employee_id and constraint_row.status='ACTIVE'
      and constraint_row.source='GRAFIK_PRO' and constraint_row.editable_by_employee
      and constraint_row.time_range && tstzrange(
        p_day::timestamp at time zone v_timezone,(p_day+1)::timestamp at time zone v_timezone,'[)')
    for update
  loop
    update public.employee_time_constraints_v2 set status='REVOKED',revoked_at=now(),updated_at=now()
    where id=v_constraint.id;
  end loop;
  if upper(p_kind)='PREFER_NOT_TO_WORK' then
    insert into public.employee_preferences(employee_id,valid_from,valid_to,preference_type,
      preference_value,source,editable_by_employee,status)
    values(p_employee_id,p_day,p_day,'OTHER',jsonb_strip_nulls(jsonb_build_object(
      'kind','DAY_OFF','strength','SOFT','note',nullif(trim(p_note),''))),
      'GRAFIK_PRO',true,'ACTIVE');
  elsif upper(p_kind)='CANNOT_WORK' or not p_all_day then
    insert into public.employee_time_constraints_v2(employee_id,constraint_kind,time_range,
      location_logical_id,source,source_record_key,priority,editable_by_employee,status,note,created_by)
    values(p_employee_id,case when upper(p_kind)='AVAILABLE' then 'AVAILABLE_WINDOW' else 'UNAVAILABLE' end,
      tstzrange(v_start,v_end,'[)'),v_location_logical_id,'GRAFIK_PRO',
      'uat-master-day:'||p_employee_id||':'||p_day||':'||upper(p_kind),100,true,'ACTIVE',
      nullif(trim(p_note),''),p_actor)
    on conflict(source,source_record_key) where source_record_key is not null do update
      set constraint_kind=excluded.constraint_kind,time_range=excluded.time_range,
        location_logical_id=excluded.location_logical_id,status='ACTIVE',revoked_at=null,
        note=excluded.note,updated_at=now();
  end if;
  if p_preferred_location_id is not null then
    insert into public.employee_preferences(employee_id,valid_from,valid_to,preference_type,
      preference_value,source,editable_by_employee,status)
    values(p_employee_id,p_day,p_day,'PREFERRED_LOCATION',
      jsonb_build_object('locationId',p_preferred_location_id),'GRAFIK_PRO',true,'ACTIVE');
  end if;
end;
$$;


ALTER FUNCTION "solver_private"."uat_master_save_employee_day_v2"("p_actor" "uuid", "p_employee_id" "uuid", "p_day" "date", "p_kind" "text", "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone, "p_preferred_location_id" "uuid", "p_note" "text") OWNER TO "postgres";

--
-- Name: validate_stage_proof_b4f166("jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."validate_stage_proof_b4f166"("p_stage_proof" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" IMMUTABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_stage jsonb;
begin
  if jsonb_typeof(p_stage_proof)<>'array'
    or jsonb_array_length(p_stage_proof) not between 1 and 1000 then
    raise exception 'STAGE_PROOF_REQUIRED';
  end if;

  for v_stage in select item.value from jsonb_array_elements(p_stage_proof) item(value)
  loop
    if jsonb_typeof(v_stage)<>'object'
      or not (v_stage ?& array[
        'tier','name','status','value','frozenUpperBound','tolerance',
        'timeBudgetSeconds','elapsedSeconds','usedFallback'
      ]) then
      raise exception 'STAGE_PROOF_INCOMPLETE';
    end if;
    if jsonb_typeof(v_stage->'tier')<>'number'
      or jsonb_typeof(v_stage->'name')<>'string'
      or length(v_stage->>'name') not between 1 and 100
      or jsonb_typeof(v_stage->'status')<>'string'
      or length(v_stage->>'status') not between 1 and 40
      or jsonb_typeof(v_stage->'value')<>'number'
      or jsonb_typeof(v_stage->'frozenUpperBound')<>'number'
      or jsonb_typeof(v_stage->'tolerance')<>'number'
      or (v_stage->>'tolerance')::numeric<0
      or jsonb_typeof(v_stage->'timeBudgetSeconds')<>'number'
      or (v_stage->>'timeBudgetSeconds')::numeric not between 0 and 86400
      or jsonb_typeof(v_stage->'elapsedSeconds')<>'number'
      or (v_stage->>'elapsedSeconds')::numeric not between 0 and 86400
      or jsonb_typeof(v_stage->'usedFallback')<>'boolean' then
      raise exception 'STAGE_PROOF_INVALID';
    end if;
  end loop;
end;
$$;


ALTER FUNCTION "solver_private"."validate_stage_proof_b4f166"("p_stage_proof" "jsonb") OWNER TO "postgres";

--
-- Name: validate_strategy_semantics_b4f165("uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."validate_strategy_semantics_b4f165"("p_matrix_version_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  perform solver_private.validate_strategy_semantics_b4f170(
    p_matrix_version_id
  );
end;
$$;


ALTER FUNCTION "solver_private"."validate_strategy_semantics_b4f165"("p_matrix_version_id" "uuid") OWNER TO "postgres";

--
-- Name: validate_strategy_semantics_b4f168("uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."validate_strategy_semantics_b4f168"("p_matrix_version_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_expected_guards constant jsonb :=
    '["HARD_CONSTRAINTS","COVERAGE","ROLE_BACKUP","OVERTIME","ZERO_HOURS","PRIMARY_ROLE","MAX_MIN_FAIRNESS","FAIRNESS_SPREAD"]'::jsonb;
  v_settings jsonb;
  v_semantics_version text;
begin
  select mv.settings into v_settings
  from public.matrix_versions mv
  where mv.id=p_matrix_version_id;
  v_semantics_version:=v_settings->>'strategySemanticsVersion';

  if v_semantics_version not in ('B4F165_V1','B4F168_V1')
    or v_settings->'mandatoryProductGuards'<>v_expected_guards
    or coalesce(
      (v_settings->>'configurableObjectivesStartAfterMandatoryGuards')::boolean,
      false
    ) is not true then
    raise exception 'STRATEGY_SEMANTICS_MISMATCH: MATRIX_DECLARATION';
  end if;

  if (
    select count(distinct s.code)
    from public.matrix_strategies_v2 s
    where s.matrix_version_id=p_matrix_version_id and s.active
      and s.code in ('BALANCED','MIN_COST','PREFERENCES')
  )<>3 then
    raise exception 'STRATEGY_SEMANTICS_MISMATCH: BUILT_IN_STRATEGIES';
  end if;

  if v_semantics_version='B4F168_V1' and exists(
    select 1
    from public.matrix_strategy_objectives_v2 o
    where o.matrix_version_id=p_matrix_version_id
      and o.metric_code='HOME_LOCATION_VIOLATIONS'
  ) then
    raise exception
      'STRATEGY_SEMANTICS_MISMATCH: HOME_LOCATION_VIOLATIONS_IS_OBSOLETE';
  end if;

  if exists(
    with expected(strategy_code,metric_code,tier) as (values
      ('BALANCED','UNFILLED',1),
      ('BALANCED','TOTAL_COST',2),
      ('BALANCED','PREFERENCE_VIOLATIONS',2),
      ('BALANCED','OVERTIME_MINUTES',2),
      ('BALANCED','NOMINAL_DEVIATION_MINUTES',2),
      ('BALANCED','LOAD_SPREAD_MINUTES',2),
      ('BALANCED','WEEKEND_SPREAD',2),
      ('BALANCED','BASELINE_CHANGES',2),
      ('MIN_COST','UNFILLED',1),
      ('MIN_COST','TOTAL_COST',2),
      ('MIN_COST','OVERTIME_MINUTES',3),
      ('MIN_COST','PREFERENCE_VIOLATIONS',4),
      ('MIN_COST','NOMINAL_DEVIATION_MINUTES',5),
      ('MIN_COST','LOAD_SPREAD_MINUTES',5),
      ('MIN_COST','WEEKEND_SPREAD',5),
      ('MIN_COST','BASELINE_CHANGES',6),
      ('PREFERENCES','UNFILLED',1),
      ('PREFERENCES','LOAD_SPREAD_MINUTES',2),
      ('PREFERENCES','NOMINAL_DEVIATION_MINUTES',3),
      ('PREFERENCES','PREFERENCE_VIOLATIONS',4),
      ('PREFERENCES','WEEKEND_SPREAD',5),
      ('PREFERENCES','TOTAL_COST',6),
      ('PREFERENCES','OVERTIME_MINUTES',7),
      ('PREFERENCES','BASELINE_CHANGES',7)
    ), legacy_home(strategy_code,metric_code,tier) as (values
      ('BALANCED','HOME_LOCATION_VIOLATIONS',2),
      ('MIN_COST','HOME_LOCATION_VIOLATIONS',3),
      ('PREFERENCES','HOME_LOCATION_VIOLATIONS',6)
    ), versioned_expected as (
      select * from expected
      union all
      select * from legacy_home where v_semantics_version='B4F165_V1'
    )
    select 1
    from versioned_expected e
    left join public.matrix_strategies_v2 s
      on s.matrix_version_id=p_matrix_version_id and s.active
      and s.code=e.strategy_code
    left join public.matrix_strategy_objectives_v2 o
      on o.matrix_version_id=p_matrix_version_id and o.strategy_id=s.id
      and o.active and o.metric_code=e.metric_code
    where o.id is null or o.tier<>e.tier or o.weight<=0
      or upper(o.direction) not in ('MIN','MINIMIZE')
  ) then
    raise exception 'STRATEGY_SEMANTICS_MISMATCH: OBJECTIVE_TIERS';
  end if;
end;
$$;


ALTER FUNCTION "solver_private"."validate_strategy_semantics_b4f168"("p_matrix_version_id" "uuid") OWNER TO "postgres";

--
-- Name: validate_strategy_semantics_b4f169("uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."validate_strategy_semantics_b4f169"("p_matrix_version_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_legacy_guards constant jsonb :=
    '["HARD_CONSTRAINTS","COVERAGE","ROLE_BACKUP","OVERTIME","ZERO_HOURS","PRIMARY_ROLE","MAX_MIN_FAIRNESS","FAIRNESS_SPREAD"]'::jsonb;
  v_current_guards constant jsonb :=
    '["HARD_CONSTRAINTS","COVERAGE","ROLE_BACKUP","OVERTIME","ZERO_HOURS","PRIMARY_ROLE","MAX_MIN_FAIRNESS","FAIRNESS_SPREAD","FAIRNESS_QUALITY_GATE"]'::jsonb;
  v_settings jsonb;
  v_gate jsonb;
  v_semantics_version text;
begin
  select mv.settings into v_settings
  from public.matrix_versions mv
  where mv.id=p_matrix_version_id;
  v_semantics_version:=v_settings->>'strategySemanticsVersion';
  v_gate:=v_settings->'fairnessQualityGate';

  if v_semantics_version not in ('B4F165_V1','B4F168_V1','B4F169_V1')
    or v_settings->'mandatoryProductGuards'<>(case
      when v_semantics_version='B4F169_V1' then v_current_guards
      else v_legacy_guards
    end)
    or coalesce(
      (v_settings->>'configurableObjectivesStartAfterMandatoryGuards')::boolean,
      false
    ) is not true then
    raise exception 'STRATEGY_SEMANTICS_MISMATCH: MATRIX_DECLARATION';
  end if;

  if v_semantics_version='B4F169_V1' then
    if jsonb_typeof(v_gate) is distinct from 'object' then
      raise exception 'STRATEGY_SEMANTICS_MISMATCH: FAIRNESS_QUALITY_GATE';
    end if;
    if (select count(*) from jsonb_object_keys(v_gate))<>3
      or exists(
      select 1 from jsonb_object_keys(v_gate) key
      where key not in (
        'minimumEstimatedAchievableTargetUtilizationBps',
        'maximumEstimatedAchievableTargetUtilizationSpreadBps',
        'maxAttempts'
      )
      ) then
      raise exception 'STRATEGY_SEMANTICS_MISMATCH: FAIRNESS_QUALITY_GATE';
    end if;
    if coalesce(
      v_gate->>'minimumEstimatedAchievableTargetUtilizationBps',''
    ) !~ '^[0-9]+$'
    or coalesce(
      v_gate->>'maximumEstimatedAchievableTargetUtilizationSpreadBps',''
    ) !~ '^[0-9]+$'
    or coalesce(v_gate->>'maxAttempts','') !~ '^[0-9]+$'
    then
      raise exception 'STRATEGY_SEMANTICS_MISMATCH: FAIRNESS_QUALITY_GATE';
    end if;
    if (v_gate->>'minimumEstimatedAchievableTargetUtilizationBps')::integer
        not between 0 and 1000
      or (v_gate->>'maximumEstimatedAchievableTargetUtilizationSpreadBps')::integer
        not between 0 and 1000
      or (v_gate->>'maxAttempts')::integer not between 1 and 3
    then
      raise exception 'STRATEGY_SEMANTICS_MISMATCH: FAIRNESS_QUALITY_GATE';
    end if;
  end if;

  if (
    select count(distinct s.code)
    from public.matrix_strategies_v2 s
    where s.matrix_version_id=p_matrix_version_id and s.active
      and s.code in ('BALANCED','MIN_COST','PREFERENCES')
  )<>3 then
    raise exception 'STRATEGY_SEMANTICS_MISMATCH: BUILT_IN_STRATEGIES';
  end if;

  if v_semantics_version in ('B4F168_V1','B4F169_V1') and exists(
    select 1
    from public.matrix_strategy_objectives_v2 o
    where o.matrix_version_id=p_matrix_version_id
      and o.metric_code='HOME_LOCATION_VIOLATIONS'
  ) then
    raise exception
      'STRATEGY_SEMANTICS_MISMATCH: HOME_LOCATION_VIOLATIONS_IS_OBSOLETE';
  end if;

  if exists(
    with expected(strategy_code,metric_code,tier) as (values
      ('BALANCED','UNFILLED',1),
      ('BALANCED','TOTAL_COST',2),
      ('BALANCED','PREFERENCE_VIOLATIONS',2),
      ('BALANCED','OVERTIME_MINUTES',2),
      ('BALANCED','NOMINAL_DEVIATION_MINUTES',2),
      ('BALANCED','LOAD_SPREAD_MINUTES',2),
      ('BALANCED','WEEKEND_SPREAD',2),
      ('BALANCED','BASELINE_CHANGES',2),
      ('MIN_COST','UNFILLED',1),
      ('MIN_COST','TOTAL_COST',2),
      ('MIN_COST','OVERTIME_MINUTES',3),
      ('MIN_COST','PREFERENCE_VIOLATIONS',4),
      ('MIN_COST','NOMINAL_DEVIATION_MINUTES',5),
      ('MIN_COST','LOAD_SPREAD_MINUTES',5),
      ('MIN_COST','WEEKEND_SPREAD',5),
      ('MIN_COST','BASELINE_CHANGES',6),
      ('PREFERENCES','UNFILLED',1),
      ('PREFERENCES','LOAD_SPREAD_MINUTES',2),
      ('PREFERENCES','NOMINAL_DEVIATION_MINUTES',3),
      ('PREFERENCES','PREFERENCE_VIOLATIONS',4),
      ('PREFERENCES','WEEKEND_SPREAD',5),
      ('PREFERENCES','TOTAL_COST',6),
      ('PREFERENCES','OVERTIME_MINUTES',7),
      ('PREFERENCES','BASELINE_CHANGES',7)
    ), legacy_home(strategy_code,metric_code,tier) as (values
      ('BALANCED','HOME_LOCATION_VIOLATIONS',2),
      ('MIN_COST','HOME_LOCATION_VIOLATIONS',3),
      ('PREFERENCES','HOME_LOCATION_VIOLATIONS',6)
    ), versioned_expected as (
      select * from expected
      union all
      select * from legacy_home where v_semantics_version='B4F165_V1'
    )
    select 1
    from versioned_expected e
    left join public.matrix_strategies_v2 s
      on s.matrix_version_id=p_matrix_version_id and s.active
      and s.code=e.strategy_code
    left join public.matrix_strategy_objectives_v2 o
      on o.matrix_version_id=p_matrix_version_id and o.strategy_id=s.id
      and o.active and o.metric_code=e.metric_code
    where o.id is null or o.tier<>e.tier or o.weight<=0
      or upper(o.direction) not in ('MIN','MINIMIZE')
  ) then
    raise exception 'STRATEGY_SEMANTICS_MISMATCH: OBJECTIVE_TIERS';
  end if;
end;
$_$;


ALTER FUNCTION "solver_private"."validate_strategy_semantics_b4f169"("p_matrix_version_id" "uuid") OWNER TO "postgres";

--
-- Name: validate_strategy_semantics_b4f170("uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."validate_strategy_semantics_b4f170"("p_matrix_version_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_legacy_guards constant jsonb :=
    '["HARD_CONSTRAINTS","COVERAGE","ROLE_BACKUP","OVERTIME","ZERO_HOURS","PRIMARY_ROLE","MAX_MIN_FAIRNESS","FAIRNESS_SPREAD"]'::jsonb;
  v_gate_guards constant jsonb :=
    '["HARD_CONSTRAINTS","COVERAGE","ROLE_BACKUP","OVERTIME","ZERO_HOURS","PRIMARY_ROLE","MAX_MIN_FAIRNESS","FAIRNESS_SPREAD","FAIRNESS_QUALITY_GATE"]'::jsonb;
  v_target_guards constant jsonb :=
    '["HARD_CONSTRAINTS","COVERAGE","ROLE_BACKUP","OVERTIME","ZERO_HOURS","PRIMARY_ROLE","MAX_MIN_FAIRNESS","FAIRNESS_SPREAD","FAIRNESS_QUALITY_TARGET"]'::jsonb;
  v_settings jsonb;
  v_quality jsonb;
  v_semantics_version text;
begin
  select mv.settings into v_settings
  from public.matrix_versions mv
  where mv.id=p_matrix_version_id;
  v_semantics_version:=v_settings->>'strategySemanticsVersion';
  v_quality:=case
    when v_semantics_version='B4F169_V1' then v_settings->'fairnessQualityGate'
    when v_semantics_version='B4F170_V1' then v_settings->'fairnessQualityTarget'
    else null
  end;

  if v_semantics_version is null
     or v_semantics_version not in (
      'B4F165_V1','B4F168_V1','B4F169_V1','B4F170_V1'
    )
    or v_settings->'mandatoryProductGuards'<>(case
      when v_semantics_version='B4F169_V1' then v_gate_guards
      when v_semantics_version='B4F170_V1' then v_target_guards
      else v_legacy_guards
    end)
    or coalesce(
      (v_settings->>'configurableObjectivesStartAfterMandatoryGuards')::boolean,
      false
    ) is not true then
    raise exception 'STRATEGY_SEMANTICS_MISMATCH: MATRIX_DECLARATION';
  end if;

  if v_semantics_version in ('B4F169_V1','B4F170_V1') then
    if jsonb_typeof(v_quality) is distinct from 'object'
      or (select count(*) from jsonb_object_keys(v_quality))<>3
      or exists(
        select 1 from jsonb_object_keys(v_quality) key
        where key not in (
          'minimumEstimatedAchievableTargetUtilizationBps',
          'maximumEstimatedAchievableTargetUtilizationSpreadBps',
          'maxAttempts'
        )
      ) then
      raise exception 'STRATEGY_SEMANTICS_MISMATCH: FAIRNESS_QUALITY_TARGET';
    end if;
    if coalesce(
      v_quality->>'minimumEstimatedAchievableTargetUtilizationBps',''
    ) !~ '^[0-9]+$'
      or coalesce(
        v_quality->>'maximumEstimatedAchievableTargetUtilizationSpreadBps',''
      ) !~ '^[0-9]+$'
      or coalesce(v_quality->>'maxAttempts','') !~ '^[0-9]+$'
      or (v_quality->>'minimumEstimatedAchievableTargetUtilizationBps')::integer
        not between 0 and 1000
      or (v_quality->>'maximumEstimatedAchievableTargetUtilizationSpreadBps')::integer
        not between 0 and 1000
      or (v_quality->>'maxAttempts')::integer not between 1 and 3 then
      raise exception 'STRATEGY_SEMANTICS_MISMATCH: FAIRNESS_QUALITY_TARGET';
    end if;
  end if;

  if (
    select count(distinct s.code)
    from public.matrix_strategies_v2 s
    where s.matrix_version_id=p_matrix_version_id and s.active
      and s.code in ('BALANCED','MIN_COST','PREFERENCES')
  )<>3 then
    raise exception 'STRATEGY_SEMANTICS_MISMATCH: BUILT_IN_STRATEGIES';
  end if;

  if v_semantics_version<>'B4F165_V1' and exists(
    select 1
    from public.matrix_strategy_objectives_v2 o
    where o.matrix_version_id=p_matrix_version_id
      and o.metric_code='HOME_LOCATION_VIOLATIONS'
  ) then
    raise exception
      'STRATEGY_SEMANTICS_MISMATCH: HOME_LOCATION_VIOLATIONS_IS_OBSOLETE';
  end if;

  if exists(
    with expected(strategy_code,metric_code,tier) as (values
      ('BALANCED','UNFILLED',1),
      ('BALANCED','TOTAL_COST',2),
      ('BALANCED','PREFERENCE_VIOLATIONS',2),
      ('BALANCED','OVERTIME_MINUTES',2),
      ('BALANCED','NOMINAL_DEVIATION_MINUTES',2),
      ('BALANCED','LOAD_SPREAD_MINUTES',2),
      ('BALANCED','WEEKEND_SPREAD',2),
      ('BALANCED','BASELINE_CHANGES',2),
      ('MIN_COST','UNFILLED',1),
      ('MIN_COST','TOTAL_COST',2),
      ('MIN_COST','OVERTIME_MINUTES',3),
      ('MIN_COST','PREFERENCE_VIOLATIONS',4),
      ('MIN_COST','NOMINAL_DEVIATION_MINUTES',5),
      ('MIN_COST','LOAD_SPREAD_MINUTES',5),
      ('MIN_COST','WEEKEND_SPREAD',5),
      ('MIN_COST','BASELINE_CHANGES',6),
      ('PREFERENCES','UNFILLED',1),
      ('PREFERENCES','LOAD_SPREAD_MINUTES',2),
      ('PREFERENCES','NOMINAL_DEVIATION_MINUTES',3),
      ('PREFERENCES','PREFERENCE_VIOLATIONS',4),
      ('PREFERENCES','WEEKEND_SPREAD',5),
      ('PREFERENCES','TOTAL_COST',6),
      ('PREFERENCES','OVERTIME_MINUTES',7),
      ('PREFERENCES','BASELINE_CHANGES',7)
    ), legacy_home(strategy_code,metric_code,tier) as (values
      ('BALANCED','HOME_LOCATION_VIOLATIONS',2),
      ('MIN_COST','HOME_LOCATION_VIOLATIONS',3),
      ('PREFERENCES','HOME_LOCATION_VIOLATIONS',6)
    ), versioned_expected as (
      select * from expected
      union all
      select * from legacy_home where v_semantics_version='B4F165_V1'
    )
    select 1
    from versioned_expected e
    left join public.matrix_strategies_v2 s
      on s.matrix_version_id=p_matrix_version_id and s.active
      and s.code=e.strategy_code
    left join public.matrix_strategy_objectives_v2 o
      on o.matrix_version_id=p_matrix_version_id and o.strategy_id=s.id
      and o.active and o.metric_code=e.metric_code
    where o.id is null or o.tier<>e.tier or o.weight<=0
      or upper(o.direction) not in ('MIN','MINIMIZE')
  ) then
    raise exception 'STRATEGY_SEMANTICS_MISMATCH: OBJECTIVE_TIERS';
  end if;
end;
$_$;


ALTER FUNCTION "solver_private"."validate_strategy_semantics_b4f170"("p_matrix_version_id" "uuid") OWNER TO "postgres";

--
-- Name: validate_variant_before_b4f164_overtime_policy_uat_v1("jsonb", "jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."validate_variant_before_b4f164_overtime_policy_uat_v1"("p_snapshot" "jsonb", "p_variant" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_invalid bigint:=0;
  v_maximum_shifts_per_day integer:=coalesce(
    nullif(p_snapshot->'settings'->>'maximumShiftsPerDay','')::integer,1
  );
  v_timezone text:=coalesce(
    nullif(p_snapshot->'settings'->>'timezone',''),'Europe/Warsaw'
  );
  v_period_start date:=(p_snapshot->>'periodStart')::date;
  v_period_end date:=(p_snapshot->>'periodEnd')::date;
begin
  with submitted as (
    select assignment.value->>'employeeId' employee_id,
      (slot.value->>'date')::date work_date,
      'ASSIGNED:'||coalesce(
        nullif(slot.value->>'occurrenceId',''),
        concat_ws('|',slot.value->>'date',slot.value->>'shiftTemplateId')
      ) item_key
    from jsonb_array_elements(coalesce(p_variant->'assignments','[]'::jsonb)) assignment
    join jsonb_array_elements(coalesce(p_snapshot->'slots','[]'::jsonb)) slot
      on slot.value->>'slotId'=assignment.value->>'slotId'
    union all
    select external.value->>'employeeId',
      ((external.value->>'start')::timestamptz at time zone v_timezone)::date,
      'EXTERNAL:'||external.ordinality::text
    from jsonb_array_elements(coalesce(
      p_snapshot->'externalAssignments','[]'::jsonb
    )) with ordinality external(value,ordinality)
    where ((external.value->>'start')::timestamptz at time zone v_timezone)::date
      between v_period_start and v_period_end
  )
  select count(*) into v_invalid
  from (
    select employee_id,work_date
    from submitted
    group by employee_id,work_date
    having count(distinct item_key)>v_maximum_shifts_per_day
  ) violation;
  if v_invalid>0 then
    raise exception 'VARIANT_MULTIPLE_PRIMARY_SHIFTS_PER_DAY_INVALID';
  end if;

  with template_days as (
    select template.value->>'id' template_id,
      template.value->>'locationId' location_id,
      weekday.value::integer weekday,
      coalesce(
        nullif(template.value->>'sequenceOrder','')::integer,
        split_part(template.value->>'startTime',':',1)::integer*60+
          split_part(template.value->>'startTime',':',2)::integer
      ) sequence_order,
      template.value->>'startTime' start_time
    from jsonb_array_elements(coalesce(
      p_snapshot->'shiftTemplates','[]'::jsonb
    )) template
    cross join lateral jsonb_array_elements_text(coalesce(
      template.value->'weekdays','[]'::jsonb
    )) weekday(value)
  ), ranked as (
    select template_days.*,
      row_number() over(
        partition by location_id,weekday
        order by sequence_order,start_time,template_id
      ) first_rank,
      row_number() over(
        partition by location_id,weekday
        order by sequence_order desc,start_time desc,template_id desc
      ) last_rank,
      count(*) over(partition by location_id,weekday) template_count
    from template_days
  ), assigned as (
    select distinct assignment.value->>'employeeId' employee_id,
      (slot.value->>'date')::date work_date,
      slot.value->>'shiftTemplateId' template_id,
      slot.value->>'locationId' location_id
    from jsonb_array_elements(coalesce(p_variant->'assignments','[]'::jsonb)) assignment
    join jsonb_array_elements(coalesce(p_snapshot->'slots','[]'::jsonb)) slot
      on slot.value->>'slotId'=assignment.value->>'slotId'
  ), sequenced as (
    select assigned.*,ranked.first_rank,ranked.last_rank,ranked.template_count
    from assigned
    join ranked on ranked.template_id=assigned.template_id
      and ranked.location_id=assigned.location_id
      and ranked.weekday=extract(isodow from assigned.work_date)::integer
  )
  select count(*) into v_invalid
  from sequenced previous_day
  join sequenced next_day
    on next_day.employee_id=previous_day.employee_id
      and next_day.work_date=previous_day.work_date+1
    and previous_day.template_count>1
    and next_day.template_count>1
    and previous_day.last_rank=1
    and next_day.first_rank=1;
  if v_invalid>0 then
    raise exception 'VARIANT_CONSECUTIVE_SHIFT_SEQUENCE_INVALID';
  end if;

  return solver_private.validate_variant_before_primary_shift_invariants_v2(
    p_snapshot,p_variant
  );
end;
$$;


ALTER FUNCTION "solver_private"."validate_variant_before_b4f164_overtime_policy_uat_v1"("p_snapshot" "jsonb", "p_variant" "jsonb") OWNER TO "postgres";

--
-- Name: validate_variant_before_daily_limit_period_guard_uat_v1("jsonb", "jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."validate_variant_before_daily_limit_period_guard_uat_v1"("p_snapshot" "jsonb", "p_variant" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_snapshot jsonb:=p_snapshot; v_employees jsonb;
begin
  if exists(select 1 from jsonb_array_elements(coalesce(p_variant->'assignments','[]'::jsonb)) assignment
      where coalesce((assignment.value->>'limitOverride')::boolean,false)) then
    select coalesce(jsonb_agg(case when exists(
      select 1 from jsonb_array_elements(coalesce(p_variant->'assignments','[]'::jsonb)) assignment
      where coalesce((assignment.value->>'limitOverride')::boolean,false)
        and assignment.value->>'employeeId'=employee.value->>'id'
    ) then employee.value||jsonb_build_object(
      'maximumMonthlyMinutes',2147483647,'maximumWeeklyMinutes',2147483647
    ) else employee.value end order by employee.ordinality),'[]'::jsonb)
    into v_employees
    from jsonb_array_elements(coalesce(p_snapshot->'employees','[]'::jsonb))
      with ordinality employee(value,ordinality);
    v_snapshot:=jsonb_set(v_snapshot,'{employees}',v_employees,true);
  end if;
  return solver_private.validate_variant_before_leader_limit_override_v2(v_snapshot,p_variant);
end;
$$;


ALTER FUNCTION "solver_private"."validate_variant_before_daily_limit_period_guard_uat_v1"("p_snapshot" "jsonb", "p_variant" "jsonb") OWNER TO "postgres";

--
-- Name: validate_variant_before_final_contract_v2("jsonb", "jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."validate_variant_before_final_contract_v2"("p_snapshot" "jsonb", "p_variant" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_invalid bigint;
  v_slot_count integer := jsonb_array_length(coalesce(p_snapshot->'slots','[]'::jsonb));
  v_assignment_count integer := jsonb_array_length(coalesce(p_variant->'assignments','[]'::jsonb));
  v_unfilled_count integer := jsonb_array_length(coalesce(p_variant->'unfilledSlotIds','[]'::jsonb));
  v_cost_units bigint := 0;
  v_solution_hash text;
  v_budget_minor bigint := nullif(p_snapshot->'budget'->>'amountMinor','')::bigint;
  v_hard_budget boolean := coalesce((p_snapshot->'budget'->>'hard')::boolean,false);
  v_timezone text := nullif(p_snapshot->'settings'->>'timezone','');
  v_missing_available boolean :=
    (p_snapshot->'settings'->>'missingAvailabilityMeansAvailable')::boolean;
begin
  if p_variant->>'schemaVersion' is distinct from '2' then raise exception 'VARIANT_SCHEMA_INVALID'; end if;
  if v_timezone is null or not exists(
    select 1 from pg_catalog.pg_timezone_names tz where tz.name=v_timezone
  ) or v_missing_available is null then
    raise exception 'SNAPSHOT_SETTINGS_INVALID';
  end if;
  if not public.matrix_v2_is_iso_4217_currency(
    coalesce(p_snapshot->>'currency','')
  )
    or exists(
      select 1 from jsonb_array_elements(coalesce(p_snapshot->'payRules','[]'::jsonb)) r
      where coalesce(r.value->>'currency',p_snapshot->>'currency')
        <>p_snapshot->>'currency'
    ) or exists(
      select 1 from jsonb_array_elements(coalesce(p_snapshot->'budgets','[]'::jsonb)) b
      where coalesce(b.value->>'currency',p_snapshot->>'currency')
        <>p_snapshot->>'currency'
    ) then raise exception 'SNAPSHOT_CURRENCY_INVALID'; end if;
  if jsonb_typeof(p_variant->'assignments') is distinct from 'array'
    or jsonb_typeof(p_variant->'unfilledSlotIds') is distinct from 'array'
    or jsonb_typeof(p_variant->'metrics') is distinct from 'object' then
    raise exception 'VARIANT_ARRAYS_REQUIRED';
  end if;
  if coalesce(p_variant->>'solutionHash','') !~ '^[0-9a-f]{64}$' then
    raise exception 'VARIANT_SOLUTION_HASH_INVALID';
  end if;
  if not exists(
    select 1 from jsonb_array_elements(coalesce(p_snapshot->'strategies','[]'::jsonb)) s
    where s->>'id'=p_variant->>'strategyId'
  ) then raise exception 'VARIANT_STRATEGY_INVALID'; end if;

  with a as (
    select value->>'slotId' slot_id,value->>'employeeId' employee_id
    from jsonb_array_elements(p_variant->'assignments')
  ), u as (
    select value#>>'{}' slot_id from jsonb_array_elements(p_variant->'unfilledSlotIds')
  ), submitted as (
    select slot_id from a union all select slot_id from u
  ), slots as (
    select value->>'slotId' slot_id from jsonb_array_elements(p_snapshot->'slots')
  )
  select count(*) into v_invalid from (
    select slot_id from submitted group by slot_id having count(*)<>1
    union all
    select submitted.slot_id from submitted left join slots using(slot_id) where slots.slot_id is null
    union all
    select slots.slot_id from slots left join submitted using(slot_id) where submitted.slot_id is null
  ) bad;
  if v_invalid>0 or v_assignment_count+v_unfilled_count<>v_slot_count then
    raise exception 'VARIANT_SLOT_COVERAGE_INVALID';
  end if;
  with a as (
    select value->>'slotId' slot_id,value->>'employeeId' employee_id
    from jsonb_array_elements(p_variant->'assignments')
  ), slots as (
    select value->>'slotId' slot_id from jsonb_array_elements(p_snapshot->'slots')
  ), selected_map as (
    select jsonb_object_agg(s.slot_id,to_jsonb(a.employee_id) order by s.slot_id) payload
    from slots s left join a using(slot_id)
  )
  select encode(extensions.digest(convert_to(
    solver_private.canonical_json_v2(payload),'UTF8'
  ),'sha256'),'hex') into v_solution_hash from selected_map;
  if v_solution_hash is distinct from lower(p_variant->>'solutionHash') then
    raise exception 'VARIANT_SOLUTION_HASH_MISMATCH';
  end if;

  with a as (
    select value->>'slotId' slot_id,value->>'employeeId' employee_id
    from jsonb_array_elements(p_variant->'assignments')
  ), pairs as (
    select a.*,s.value slot,
      (select e.value from jsonb_array_elements(p_snapshot->'employees') e
       where e.value->>'id'=a.employee_id limit 1) employee,
      solver_private.slot_timezone_v2(p_snapshot,s.value) slot_timezone
    from a join jsonb_array_elements(p_snapshot->'slots') s
      on s.value->>'slotId'=a.slot_id
  )
  select count(*) into v_invalid from pairs p where
    p.employee is null
    or not solver_private.employee_scope_eligible_v2(p.employee,p.slot)
    or nullif(
      solver_private.employee_for_slot_v2(p.employee,p.slot)->>'baseHourlyRateMinor',''
    ) is null
    or ((p.employee->>'employmentStart') is not null
      and (p.slot->>'date')::date<(p.employee->>'employmentStart')::date)
    or ((p.employee->>'employmentEnd') is not null
      and (((p.slot->>'end')::timestamptz at time zone p.slot_timezone)::date
        >(p.employee->>'employmentEnd')::date))
    or (coalesce((p.employee->>'noWeekends')::boolean,false)
      and extract(isodow from ((p.slot->>'start')::timestamptz at time zone p.slot_timezone))>=6)
    or ((p.employee->>'onlyMorningBeforeMinute') is not null and
      extract(hour from ((p.slot->>'end')::timestamptz at time zone p.slot_timezone))*60+
      extract(minute from ((p.slot->>'end')::timestamptz at time zone p.slot_timezone))+
      case when ((p.slot->>'end')::timestamptz at time zone p.slot_timezone)::date
          >((p.slot->>'start')::timestamptz at time zone p.slot_timezone)::date
        then 1440 else 0 end>
      (p.employee->>'onlyMorningBeforeMinute')::integer)
    or ((p.employee->>'onlyEveningAfterMinute') is not null and
      extract(hour from ((p.slot->>'start')::timestamptz at time zone p.slot_timezone))*60+
      extract(minute from ((p.slot->>'start')::timestamptz at time zone p.slot_timezone))<
      (p.employee->>'onlyEveningAfterMinute')::integer);
  if v_invalid>0 then raise exception 'VARIANT_EMPLOYEE_ELIGIBILITY_INVALID'; end if;

  with a as (
    select value->>'slotId' slot_id,value->>'employeeId' employee_id
    from jsonb_array_elements(p_variant->'assignments')
  ), pairs as (
    select a.employee_id,s.value slot,
      solver_private.slot_timezone_v2(p_snapshot,s.value) slot_timezone
    from a join jsonb_array_elements(p_snapshot->'slots') s on s.value->>'slotId'=a.slot_id
  )
  select count(*) into v_invalid
  from pairs p
  where exists(
    select 1 from jsonb_array_elements(coalesce(p_snapshot->'hardBlocks','[]'::jsonb)) b
    where b->>'employeeId'=p.employee_id
      and tstzrange((p.slot->>'start')::timestamptz,(p.slot->>'end')::timestamptz,'[)')
        && tstzrange((b->>'start')::timestamptz,(b->>'end')::timestamptz,'[)')
  );
  if v_invalid>0 then raise exception 'VARIANT_HARD_BLOCK_INVALID'; end if;

  with a as (
    select value->>'slotId' slot_id,value->>'employeeId' employee_id
    from jsonb_array_elements(p_variant->'assignments')
  ), pairs as (
    select a.employee_id,s.value slot,
      solver_private.slot_timezone_v2(p_snapshot,s.value) slot_timezone
    from a join jsonb_array_elements(p_snapshot->'slots') s on s.value->>'slotId'=a.slot_id
  )
  select count(*) into v_invalid from pairs p
  where (
    exists(
      select 1 from jsonb_array_elements(coalesce(p_snapshot->'availabilityWindows','[]'::jsonb)) w
      where w->>'employeeId'=p.employee_id
        and tstzrange((w->>'start')::timestamptz,(w->>'end')::timestamptz,'[)')
          && tstzrange(
            (p.slot->>'date')::timestamp at time zone p.slot_timezone,
            ((p.slot->>'date')::date+1)::timestamp at time zone p.slot_timezone,'[)'
          )
    ) or not v_missing_available
  ) and not exists(
    select 1 from jsonb_array_elements(coalesce(p_snapshot->'availabilityWindows','[]'::jsonb)) w
    where w->>'employeeId'=p.employee_id
      and (w->>'start')::timestamptz<=(p.slot->>'start')::timestamptz
      and (w->>'end')::timestamptz>=(p.slot->>'end')::timestamptz
  );
  if v_invalid>0 then raise exception 'VARIANT_AVAILABILITY_INVALID'; end if;

  with a as (
    select value->>'slotId' slot_id,value->>'employeeId' employee_id
    from jsonb_array_elements(p_variant->'assignments')
  ), combined as (
    select a.employee_id,'ASSIGNED'::text source,a.slot_id item_key,
      (s.value->>'start')::timestamptz starts_at,
      (s.value->>'end')::timestamptz ends_at
    from a join jsonb_array_elements(p_snapshot->'slots') s on s.value->>'slotId'=a.slot_id
    union all
    select x.value->>'employeeId','EXTERNAL','external:'||x.ordinality::text,
      (x.value->>'start')::timestamptz,(x.value->>'end')::timestamptz
    from jsonb_array_elements(coalesce(p_snapshot->'externalAssignments','[]'::jsonb))
      with ordinality x(value,ordinality)
  ), paired as (
    select x.*,y.source other_source,y.item_key other_key,
      y.starts_at other_start,y.ends_at other_end,
      coalesce((e.value->>'minimumRestMinutes')::integer,
        (p_snapshot->'settings'->>'defaultMinimumRestMinutes')::integer,0) rest_minutes
    from combined x join combined y
      on y.employee_id=x.employee_id and y.item_key>x.item_key
    join jsonb_array_elements(p_snapshot->'employees') e on e.value->>'id'=x.employee_id
    where x.source='ASSIGNED' or y.source='ASSIGNED'
  )
  select count(*) into v_invalid from paired p
  where tstzrange(p.starts_at,p.ends_at,'[)')&&tstzrange(p.other_start,p.other_end,'[)')
    or case when p.starts_at<=p.other_start
      then p.other_start<p.ends_at+make_interval(mins=>p.rest_minutes)
      else p.starts_at<p.other_end+make_interval(mins=>p.rest_minutes) end;
  if v_invalid>0 then raise exception 'VARIANT_OVERLAP_OR_REST_INVALID'; end if;

  with a as (
    select value->>'slotId' slot_id,value->>'employeeId' employee_id
    from jsonb_array_elements(p_variant->'assignments')
  ), combined as (
    select a.employee_id,(s.value->>'date')::date work_date,
      (s.value->>'durationMinutes')::integer duration_minutes
    from a join jsonb_array_elements(p_snapshot->'slots') s on s.value->>'slotId'=a.slot_id
    union all
    select x.value->>'employeeId',
      ((x.value->>'start')::timestamptz at time zone v_timezone)::date,
      floor(extract(epoch from (
        (x.value->>'end')::timestamptz-(x.value->>'start')::timestamptz
      ))/60)::integer
    from jsonb_array_elements(coalesce(p_snapshot->'externalAssignments','[]'::jsonb)) x
  ), assigned as (
    select c.*,e.value employee from combined c
    join jsonb_array_elements(p_snapshot->'employees') e on e.value->>'id'=c.employee_id
    where c.work_date between (p_snapshot->>'periodStart')::date-6
      and (p_snapshot->>'periodEnd')::date+6
  ), violations as (
    select employee_id from assigned
    where work_date between (p_snapshot->>'periodStart')::date
      and (p_snapshot->>'periodEnd')::date
    group by employee_id,work_date,(employee->>'maximumShiftsPerDay')::integer
      having count(*)>(employee->>'maximumShiftsPerDay')::integer
    union all
    select employee_id from assigned
    where date_trunc('week',work_date)::date<=(p_snapshot->>'periodEnd')::date
      and (date_trunc('week',work_date)::date+6)>=(p_snapshot->>'periodStart')::date
    group by employee_id,date_trunc('week',work_date),(employee->>'maximumWeeklyMinutes')::integer
      having sum(duration_minutes)>(employee->>'maximumWeeklyMinutes')::integer
    union all
    select employee_id from assigned
    where work_date between (p_snapshot->>'periodStart')::date
      and (p_snapshot->>'periodEnd')::date
    group by employee_id,(employee->>'maximumMonthlyMinutes')::integer
      having sum(duration_minutes)>(employee->>'maximumMonthlyMinutes')::integer
  )
  select count(*) into v_invalid from violations;
  if v_invalid>0 then raise exception 'VARIANT_WORK_LIMIT_INVALID'; end if;

  with a as (
    select value->>'slotId' slot_id,value->>'employeeId' employee_id
    from jsonb_array_elements(p_variant->'assignments')
  ), combined as (
    select a.employee_id,(s.value->>'date')::date work_date
    from a join jsonb_array_elements(p_snapshot->'slots') s on s.value->>'slotId'=a.slot_id
    union
    select x.value->>'employeeId',
      ((x.value->>'start')::timestamptz at time zone v_timezone)::date
    from jsonb_array_elements(coalesce(p_snapshot->'externalAssignments','[]'::jsonb)) x
  ), days as (
    select distinct c.employee_id,c.work_date,
      (e.value->>'maximumConsecutiveDays')::integer maximum_days
    from combined c
    join jsonb_array_elements(p_snapshot->'employees') e on e.value->>'id'=c.employee_id
  ), numbered as (
    select *,work_date-(row_number() over(partition by employee_id order by work_date))::integer grp
    from days
  )
  select count(*) into v_invalid from (
    select employee_id,grp,maximum_days from numbered group by employee_id,grp,maximum_days
    having count(*)>maximum_days
      and max(work_date)>=(p_snapshot->>'periodStart')::date
      and min(work_date)<=(p_snapshot->>'periodEnd')::date
  ) x;
  if v_invalid>0 then raise exception 'VARIANT_CONSECUTIVE_DAYS_INVALID'; end if;

  with locked as (
    select value->>'slotId' slot_id,value->>'employeeId' employee_id
    from jsonb_array_elements(coalesce(p_snapshot->'lockedAssignments','[]'::jsonb))
  ), a as (
    select value->>'slotId' slot_id,value->>'employeeId' employee_id
    from jsonb_array_elements(p_variant->'assignments')
  )
  select count(*) into v_invalid from locked l
  left join a on a.slot_id=l.slot_id and a.employee_id=l.employee_id
  where a.slot_id is null;
  if v_invalid>0 then raise exception 'VARIANT_LOCKED_ASSIGNMENT_INVALID'; end if;

  select count(*) into v_invalid
  from jsonb_array_elements(coalesce(p_snapshot->'payRules','[]'::jsonb)) r
  where upper(coalesce(r.value->>'calculationType','')) not in (
      'FIXED_PER_SHIFT','PER_HOUR','PERCENT_BASE','MULTIPLIER',
      'SHIFT_DURATION_THRESHOLD_PER_HOUR','MONTHLY_THRESHOLD_PER_HOUR'
    )
    or upper(coalesce(nullif(r.value->>'stackingMode',''),'STACK')) not in ('STACK','FIRST','MAX')
    or (upper(r.value->>'calculationType')='MONTHLY_THRESHOLD_PER_HOUR'
      and upper(coalesce(nullif(r.value->>'stackingMode',''),'STACK'))<>'STACK')
    or (upper(r.value->>'calculationType')='FIXED_PER_SHIFT'
      and coalesce((r.value->'values'->>'amountMinor')::bigint,-1)<0)
    or (upper(r.value->>'calculationType') in (
        'PER_HOUR','SHIFT_DURATION_THRESHOLD_PER_HOUR','MONTHLY_THRESHOLD_PER_HOUR'
      ) and coalesce((r.value->'values'->>'rateMinorPerHour')::bigint,-1)<0)
    or (upper(r.value->>'calculationType') in (
        'SHIFT_DURATION_THRESHOLD_PER_HOUR','MONTHLY_THRESHOLD_PER_HOUR'
      ) and coalesce((r.value->'values'->>'thresholdMinutes')::bigint,-1)<0)
    or (upper(r.value->>'calculationType')='PERCENT_BASE'
      and coalesce((r.value->'values'->>'percentBasisPoints')::bigint,-1)<0)
    or (upper(r.value->>'calculationType')='MULTIPLIER'
      and coalesce((r.value->'values'->>'multiplierBasisPoints')::bigint,-1)<10000);
  if v_invalid>0 then raise exception 'SNAPSHOT_PAY_RULE_INVALID'; end if;
  select count(*) into v_invalid from (
    select coalesce(nullif(r.value->>'stackingGroup',''),r.value->>'id') stacking_group
    from jsonb_array_elements(coalesce(p_snapshot->'payRules','[]'::jsonb)) r
    group by coalesce(nullif(r.value->>'stackingGroup',''),r.value->>'id')
    having count(distinct upper(coalesce(nullif(r.value->>'stackingMode',''),'STACK')))>1
  ) inconsistent;
  if v_invalid>0 then raise exception 'SNAPSHOT_PAY_STACKING_INVALID'; end if;

  with a as (
    select value item from jsonb_array_elements(p_variant->'assignments')
  ), checked as (
    select item,
      coalesce((item->>'costUnits')::bigint,-1) cost_units,
      coalesce((select sum((c.value->>'costUnits')::bigint)
        from jsonb_array_elements(coalesce(item->'costComponents','[]'::jsonb)) c),0) component_units
    from a
  )
  select count(*) into v_invalid
  from checked where cost_units<0 or cost_units<>component_units;
  if v_invalid>0 then raise exception 'VARIANT_COST_COMPONENTS_INVALID'; end if;
  select coalesce(sum((value->>'costUnits')::bigint),0) into v_cost_units
  from jsonb_array_elements(p_variant->'assignments');

  with submitted as (
    select a.value->>'slotId' slot_id,a.value->>'employeeId' employee_id,
      c.value->>'ruleId' rule_id,c.value->>'calculationType' calculation_type,
      (c.value->>'costUnits')::bigint cost_units
    from jsonb_array_elements(p_variant->'assignments') a
    cross join lateral jsonb_array_elements(coalesce(a.value->'costComponents','[]'::jsonb)) c
  ), expected as (
    select * from solver_private.expected_pay_components_v2(p_snapshot,p_variant)
  )
  select count(*) into v_invalid from (
    (select * from submitted except all select * from expected)
    union all
    (select * from expected except all select * from submitted)
  ) differences;
  if v_invalid>0 then raise exception 'VARIANT_PAY_QUOTE_INVALID'; end if;
  if jsonb_array_length(coalesce(p_snapshot->'budgets','[]'::jsonb))>0 then
    with budgets as (
      select b.value
      from jsonb_array_elements(p_snapshot->'budgets') b
      where coalesce((b.value->>'hard')::boolean,false)
    ), assignment_costs as (
      select (a.value->>'costUnits')::bigint cost_units,s.value slot
      from jsonb_array_elements(p_variant->'assignments') a
      join jsonb_array_elements(p_snapshot->'slots') s
        on s.value->>'slotId'=a.value->>'slotId'
    )
    select count(*) into v_invalid
    from budgets b
    where nullif(b.value->>'amountMinor','') is null
      or (b.value->>'amountMinor')::bigint<0
      or coalesce((
        select sum(a.cost_units) from assignment_costs a
        where (nullif(b.value->>'locationId','') is null
            or a.slot->>'locationId'=b.value->>'locationId')
          and (nullif(b.value->>'roleId','') is null
            or a.slot->>'roleId'=b.value->>'roleId')
          and (nullif(b.value->>'dutyId','') is null
            or coalesce(a.slot->'dutyIds','[]'::jsonb) ? (b.value->>'dutyId'))
      ),0)>(b.value->>'amountMinor')::bigint*60;
    if v_invalid>0 then raise exception 'VARIANT_HARD_BUDGET_INVALID'; end if;
  elsif v_hard_budget and v_budget_minor is not null
    and v_cost_units>v_budget_minor*60 then
    raise exception 'VARIANT_HARD_BUDGET_INVALID';
  end if;
  if nullif(p_variant->'metrics'->>'UNFILLED','')::bigint is distinct from v_unfilled_count
    or nullif(p_variant->'metrics'->>'TOTAL_COST','')::bigint is distinct from v_cost_units then
    raise exception 'VARIANT_METRICS_INVALID';
  end if;

  return jsonb_build_object(
    'hardViolations',0,'slotCount',v_slot_count,'assignmentCount',v_assignment_count,
    'unfilledCount',v_unfilled_count,'totalCostUnits',v_cost_units,
    'budgetMinor',v_budget_minor,'hardBudget',v_hard_budget
  );
end;
$_$;


ALTER FUNCTION "solver_private"."validate_variant_before_final_contract_v2"("p_snapshot" "jsonb", "p_variant" "jsonb") OWNER TO "postgres";

--
-- Name: validate_variant_before_leader_limit_override_v2("jsonb", "jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."validate_variant_before_leader_limit_override_v2"("p_snapshot" "jsonb", "p_variant" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_invalid bigint:=0;
  v_maximum_shifts_per_day integer:=coalesce(
    nullif(p_snapshot->'settings'->>'maximumShiftsPerDay','')::integer,1
  );
  v_timezone text:=coalesce(
    nullif(p_snapshot->'settings'->>'timezone',''),'Europe/Warsaw'
  );
begin
  -- Apply the configured daily limit to shift occurrences rather than
  -- staffing seats, including already published external work.
  with submitted as (
    select assignment.value->>'employeeId' employee_id,
      (slot.value->>'date')::date work_date,
      'ASSIGNED:'||coalesce(
        nullif(slot.value->>'occurrenceId',''),
        concat_ws('|',slot.value->>'date',slot.value->>'shiftTemplateId')
      ) item_key
    from jsonb_array_elements(coalesce(p_variant->'assignments','[]'::jsonb)) assignment
    join jsonb_array_elements(coalesce(p_snapshot->'slots','[]'::jsonb)) slot
      on slot.value->>'slotId'=assignment.value->>'slotId'
    union all
    select external.value->>'employeeId',
      ((external.value->>'start')::timestamptz at time zone v_timezone)::date,
      'EXTERNAL:'||external.ordinality::text
    from jsonb_array_elements(coalesce(
      p_snapshot->'externalAssignments','[]'::jsonb
    )) with ordinality external(value,ordinality)
  )
  select count(*) into v_invalid
  from (
    select employee_id,work_date
    from submitted
    group by employee_id,work_date
    having count(distinct item_key)>v_maximum_shifts_per_day
  ) violation;
  if v_invalid>0 then
    raise exception 'VARIANT_MULTIPLE_PRIMARY_SHIFTS_PER_DAY_INVALID';
  end if;

  -- Use the explicit Matrix order for each location and weekday.  For older
  -- immutable snapshots without sequenceOrder, local start time is the safe
  -- deterministic fallback.
  with template_days as (
    select template.value->>'id' template_id,
      template.value->>'locationId' location_id,
      weekday.value::integer weekday,
      coalesce(
        nullif(template.value->>'sequenceOrder','')::integer,
        split_part(template.value->>'startTime',':',1)::integer*60+
          split_part(template.value->>'startTime',':',2)::integer
      ) sequence_order,
      template.value->>'startTime' start_time
    from jsonb_array_elements(coalesce(
      p_snapshot->'shiftTemplates','[]'::jsonb
    )) template
    cross join lateral jsonb_array_elements_text(coalesce(
      template.value->'weekdays','[]'::jsonb
    )) weekday(value)
  ), ranked as (
    select template_days.*,
      row_number() over(
        partition by location_id,weekday
        order by sequence_order,start_time,template_id
      ) first_rank,
      row_number() over(
        partition by location_id,weekday
        order by sequence_order desc,start_time desc,template_id desc
      ) last_rank,
      count(*) over(partition by location_id,weekday) template_count
    from template_days
  ), assigned as (
    select distinct assignment.value->>'employeeId' employee_id,
      (slot.value->>'date')::date work_date,
      slot.value->>'shiftTemplateId' template_id,
      slot.value->>'locationId' location_id
    from jsonb_array_elements(coalesce(p_variant->'assignments','[]'::jsonb)) assignment
    join jsonb_array_elements(coalesce(p_snapshot->'slots','[]'::jsonb)) slot
      on slot.value->>'slotId'=assignment.value->>'slotId'
  ), sequenced as (
    select assigned.*,ranked.first_rank,ranked.last_rank,ranked.template_count
    from assigned
    join ranked on ranked.template_id=assigned.template_id
      and ranked.location_id=assigned.location_id
      and ranked.weekday=extract(isodow from assigned.work_date)::integer
  )
  select count(*) into v_invalid
  from sequenced previous_day
  join sequenced next_day
    on next_day.employee_id=previous_day.employee_id
      and next_day.work_date=previous_day.work_date+1
    and previous_day.template_count>1
    and next_day.template_count>1
    and previous_day.last_rank=1
    and next_day.first_rank=1;
  if v_invalid>0 then
    raise exception 'VARIANT_CONSECUTIVE_SHIFT_SEQUENCE_INVALID';
  end if;

  return solver_private.validate_variant_before_primary_shift_invariants_v2(
    p_snapshot,p_variant
  );
end;
$$;


ALTER FUNCTION "solver_private"."validate_variant_before_leader_limit_override_v2"("p_snapshot" "jsonb", "p_variant" "jsonb") OWNER TO "postgres";

--
-- Name: validate_variant_before_primary_shift_invariants_v2("jsonb", "jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."validate_variant_before_primary_shift_invariants_v2"("p_snapshot" "jsonb", "p_variant" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_snapshot jsonb:=p_snapshot;
  v_employees jsonb:='[]'::jsonb;
begin
  -- The legacy validator compares numeric limits literally.  Give flexible
  -- contracts defensive upper bounds for validation only; overlap, availability,
  -- role, location, duty and hard-block checks remain unchanged and mandatory.
  select coalesce(jsonb_agg(
    case
      when upper(coalesce(employee.value->>'contractCode','OTHER'))
          in ('ZLECENIE','B2B')
        and upper(coalesce(employee.value->>'workTimePolicy','CONTRACT_DEFAULT'))<>'CUSTOM'
      then employee.value||jsonb_build_object(
        'maximumMonthlyMinutes',2147483647,
        'maximumWeeklyMinutes',2147483647,
        'maximumConsecutiveDays',2147483647,
        'minimumRestMinutes',0
      )
      else employee.value
    end
    order by employee.ordinality
  ),'[]'::jsonb)
  into v_employees
  from jsonb_array_elements(coalesce(p_snapshot->'employees','[]'::jsonb))
    with ordinality employee(value,ordinality);

  v_snapshot:=jsonb_set(v_snapshot,'{employees}',v_employees,true);
  return solver_private.validate_variant_before_final_contract_v2(
    v_snapshot,p_variant
  );
end;
$$;


ALTER FUNCTION "solver_private"."validate_variant_before_primary_shift_invariants_v2"("p_snapshot" "jsonb", "p_variant" "jsonb") OWNER TO "postgres";

--
-- Name: validate_variant_v2("jsonb", "jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."validate_variant_v2"("p_snapshot" "jsonb", "p_variant" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_result jsonb;
  v_employee_id text;
  v_policy text;
  v_total_minutes integer;
  v_nominal_minutes integer;
begin
  v_result := solver_private.validate_variant_before_b4f164_overtime_policy_uat_v1(
    p_snapshot,p_variant
  );

  with internal_minutes as (
    select assignment.value->>'employeeId' employee_id,
      sum(coalesce(nullif(slot.value->>'durationMinutes','')::integer,0))::integer minutes
    from jsonb_array_elements(coalesce(p_variant->'assignments','[]'::jsonb)) assignment(value)
    join jsonb_array_elements(coalesce(p_snapshot->'slots','[]'::jsonb)) slot(value)
      on slot.value->>'slotId'=assignment.value->>'slotId'
    group by assignment.value->>'employeeId'
  ), external_minutes as (
    select external.value->>'employeeId' employee_id,
      sum(extract(epoch from (
        (external.value->>'end')::timestamptz-
        (external.value->>'start')::timestamptz
      ))/60)::integer minutes
    from jsonb_array_elements(coalesce(
      p_snapshot->'externalAssignments','[]'::jsonb
    )) external(value)
    where (
      (external.value->>'start')::timestamptz at time zone coalesce(
        nullif(p_snapshot->'settings'->>'timezone',''),'Europe/Warsaw'
      )
    )::date between (p_snapshot->>'periodStart')::date and (p_snapshot->>'periodEnd')::date
    group by external.value->>'employeeId'
  ), totals as (
    select employee_id,sum(minutes)::integer total_minutes
    from (
      select * from internal_minutes
      union all
      select * from external_minutes
    ) combined
    group by employee_id
  ), employees as (
    select employee.value,
      employee.value->>'id' employee_id,
      upper(coalesce(nullif(employee.value->>'overtimePolicy',''),'NEVER')) policy,
      nullif(employee.value->>'nominalMonthlyMinutes','')::integer nominal_minutes,
      coalesce(totals.total_minutes,0) total_minutes
    from jsonb_array_elements(coalesce(p_snapshot->'employees','[]'::jsonb)) employee(value)
    left join totals on totals.employee_id=employee.value->>'id'
  )
  select employee_id,policy,total_minutes,nominal_minutes
  into v_employee_id,v_policy,v_total_minutes,v_nominal_minutes
  from employees
  where nominal_minutes is not null
    and total_minutes>nominal_minutes
    and (
      policy='NEVER'
      or (
        policy='APPROVAL_REQUIRED'
        and not exists(
          select 1
          from jsonb_array_elements(coalesce(p_variant->'assignments','[]'::jsonb)) assignment(value)
          where assignment.value->>'employeeId'=employees.employee_id
            and assignment.value->>'overtimeDecision'='LEADER_APPROVED'
            and nullif(assignment.value->>'overtimeApprovedBy','') is not null
            and nullif(assignment.value->>'overtimeApprovedAt','') is not null
            and coalesce(nullif(
              assignment.value->'overtimeQuote'->>'projectedMonthlyMinutes',''
            )::integer,-1)>=employees.total_minutes
        )
        and not (
          nullif(current_setting(
            'solver_private.b4f164_overtime_approval_employee',true
          ),'')=employees.employee_id
          and nullif(current_setting(
            'solver_private.b4f164_overtime_approval_actor',true
          ),'') is not null
          and coalesce(((nullif(current_setting(
            'solver_private.b4f164_overtime_approval_quote',true
          ),'')::jsonb)->>'projectedMonthlyMinutes')::integer,-1)>=employees.total_minutes
        )
      )
    )
  order by employee_id
  limit 1;

  if v_employee_id is not null then
    raise exception 'OVERTIME_POLICY_LIMIT:%:%:%:%',
      v_employee_id,v_policy,v_total_minutes,v_nominal_minutes;
  end if;
  return v_result;
end;
$$;


ALTER FUNCTION "solver_private"."validate_variant_v2"("p_snapshot" "jsonb", "p_variant" "jsonb") OWNER TO "postgres";

--
-- Name: FUNCTION "validate_variant_v2"("p_snapshot" "jsonb", "p_variant" "jsonb"); Type: COMMENT; Schema: solver_private; Owner: postgres
--

COMMENT ON FUNCTION "solver_private"."validate_variant_v2"("p_snapshot" "jsonb", "p_variant" "jsonb") IS 'B4F-164: validates internal plus external monthly minutes against overtime policy; APPROVAL_REQUIRED needs an audited leader approval covering the submitted total.';


--
-- Name: variant_primary_conflict_reasons_uat_v2("uuid", "uuid", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."variant_primary_conflict_reasons_uat_v2"("p_variant_id" "uuid", "p_employee_id" "uuid", "p_shift_id" "uuid") RETURNS "text"[]
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_shift public.plan_shifts_v2%rowtype;
  v_matrix_version_id uuid;
  v_month date;
  v_reasons text[]:='{}'::text[];
  v_tier integer;
  v_maximum_shifts_per_day integer:=1;
begin
  select shift_row.* into v_shift
  from public.plan_shifts_v2 shift_row
  where shift_row.id=p_shift_id and shift_row.variant_id=p_variant_id;
  if v_shift.id is null then return array['SHIFT_NOT_FOUND']::text[]; end if;

  select run.matrix_version_id,run.month
  into v_matrix_version_id,v_month
  from public.plan_variants_v2 variant
  join public.optimization_runs_v2 run on run.id=variant.run_id
  where variant.id=p_variant_id;
  select coalesce(nullif(version.settings->>'maximumShiftsPerDay','')::integer,1)
  into v_maximum_shifts_per_day
  from public.matrix_versions version
  where version.id=v_matrix_version_id;

  if (
    select count(distinct assignment.shift_id)
    from public.plan_assignments_v2 assignment
    join public.plan_shifts_v2 assigned_shift on assigned_shift.id=assignment.shift_id
    where assignment.variant_id=p_variant_id
      and assignment.employee_id=p_employee_id
      and assigned_shift.shift_date=v_shift.shift_date
  )>=v_maximum_shifts_per_day then
    v_reasons:=array_append(v_reasons,'ONE_PRIMARY_SHIFT_PER_DAY');
  end if;

  if (
    solver_private.shift_template_is_sequence_edge_uat_v2(
      v_matrix_version_id,v_shift.shift_template_id,v_shift.shift_date,'FIRST'
    ) and exists(
      select 1
      from public.plan_assignments_v2 assignment
      join public.plan_shifts_v2 assigned_shift on assigned_shift.id=assignment.shift_id
      where assignment.variant_id=p_variant_id
        and assignment.employee_id=p_employee_id
        and assigned_shift.shift_date=v_shift.shift_date-1
        and solver_private.shift_template_is_sequence_edge_uat_v2(
          v_matrix_version_id,assigned_shift.shift_template_id,
          assigned_shift.shift_date,'LAST'
        )
    )
  ) or (
    solver_private.shift_template_is_sequence_edge_uat_v2(
      v_matrix_version_id,v_shift.shift_template_id,v_shift.shift_date,'LAST'
    ) and exists(
      select 1
      from public.plan_assignments_v2 assignment
      join public.plan_shifts_v2 assigned_shift on assigned_shift.id=assignment.shift_id
      where assignment.variant_id=p_variant_id
        and assignment.employee_id=p_employee_id
        and assigned_shift.shift_date=v_shift.shift_date+1
        and solver_private.shift_template_is_sequence_edge_uat_v2(
          v_matrix_version_id,assigned_shift.shift_template_id,
          assigned_shift.shift_date,'FIRST'
        )
    )
  ) then
    v_reasons:=array_append(v_reasons,'CONSECUTIVE_SHIFT_SEQUENCE');
  end if;

  select standby.tier into v_tier
  from public.published_standby_assignments_v2 standby
  where standby.month=v_month
    and standby.standby_date=v_shift.shift_date
    and standby.employee_id=p_employee_id
    and standby.status in ('PLANNED','ACTIVATED')
  order by standby.tier
  limit 1;
  if v_tier=1 then
    v_reasons:=array_append(v_reasons,'STANDBY_TIER_1_RESERVED');
  elsif v_tier=2 then
    v_reasons:=array_append(v_reasons,'STANDBY_TIER_2_RESERVED');
  end if;

  return v_reasons;
end;
$$;


ALTER FUNCTION "solver_private"."variant_primary_conflict_reasons_uat_v2"("p_variant_id" "uuid", "p_employee_id" "uuid", "p_shift_id" "uuid") OWNER TO "postgres";

--
-- Name: variant_set_workspace_v2("uuid"[], "jsonb", boolean); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."variant_set_workspace_v2"("p_variant_ids" "uuid"[], "p_context" "jsonb", "p_can_view_finance" boolean) RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  with requested as (
    select distinct x.variant_id
    from unnest(coalesce(p_variant_ids,'{}'::uuid[])) x(variant_id)
  ), grouped_shifts as (
    select ps.slot_group_key,ps.shift_template_id,ps.location_id,ps.shift_date,
      ps.starts_at,ps.ends_at
    from public.plan_shifts_v2 ps
    join requested r on r.variant_id=ps.variant_id
    group by ps.slot_group_key,ps.shift_template_id,ps.location_id,ps.shift_date,
      ps.starts_at,ps.ends_at
  )
  select jsonb_build_object(
    'context',coalesce(p_context,'{}'::jsonb),
    'variants',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',v.id,'runId',v.run_id,'name',v.name,'status',v.status,
        'recommended',v.recommended,'selected',v.selected,
        'strategy',jsonb_build_object('id',st.id,'name',st.name),
        'scope',jsonb_build_object('type',run.scope_type,
          'role',case when role.id is null then null else
            jsonb_build_object('id',role.id,'name',role.name) end),
        'assignmentCount',v.assignment_count,'unfilledCount',v.unfilled_count,
        'solverStatus',v.solver_status,
        'finance',case when p_can_view_finance then jsonb_build_object(
          'baseCostMinor',fin.base_cost_minor,
          'additionsCostMinor',fin.additions_cost_minor,
          'totalCostMinor',fin.total_cost_minor,
          'currency',nullif(snap.snapshot->>'currency',''),
          'budgetMinor',fin.budget_minor) else null end
      ) order by run.scope_type,coalesce(role.sort_order,0),rs.ordinal)
      from requested req
      join public.plan_variants_v2 v on v.id=req.variant_id
      join public.optimization_runs_v2 run on run.id=v.run_id
      join public.optimization_run_strategies_v2 rs on rs.id=v.run_strategy_id
      join public.matrix_strategies_v2 st on st.id=v.strategy_id
      left join public.matrix_roles_v2 role on role.id=run.scope_role_id
      left join solver_private.plan_variant_finance_v2 fin on fin.variant_id=v.id
      left join solver_private.optimization_snapshots_v2 snap on snap.run_id=run.id
    ),'[]'::jsonb),
    'shifts',coalesce((
      select jsonb_agg(jsonb_build_object(
        'slotGroupKey',sh.slot_group_key,'date',sh.shift_date,
        'startsAt',sh.starts_at,'endsAt',sh.ends_at,
        'location',jsonb_build_object('id',loc.id,'name',loc.name,
          'timezone',loc.timezone),
        'shiftTemplate',jsonb_build_object('id',tmpl.id,'name',tmpl.name),
        'assignments',coalesce((
          select jsonb_agg(jsonb_build_object(
            'id',pa.id,'slotKey',pa.slot_key,
            'employee',jsonb_build_object(
              'id',employee.employee_id,'employeeNo',employee.employee_no,
              'firstName',employee.first_name,'lastName',employee.last_name,
              'nominalMonthlyMinutes',employee.nominal_monthly_minutes),
            'role',jsonb_build_object('id',role.id,'name',role.name),
            'duties',coalesce((select jsonb_agg(jsonb_build_object(
                'id',d.id,'name',d.name) order by d.sort_order,d.name)
              from public.plan_assignment_duties_v2 ad
              join public.matrix_duties_v2 d on d.id=ad.duty_id
              where ad.assignment_id=pa.id),'[]'::jsonb),
            'locked',pa.locked,
            'costMinor',case when p_can_view_finance then coalesce((
              select sum(component.amount_minor)
              from solver_private.plan_assignment_cost_components_v2 component
              where component.assignment_id=pa.id
            ),0) else null end
          ) order by role.sort_order,role.name,employee.last_name,
            employee.first_name,pa.slot_key)
          from public.plan_assignments_v2 pa
          join requested assignment_request
            on assignment_request.variant_id=pa.variant_id
          join public.plan_variants_v2 assignment_variant
            on assignment_variant.id=pa.variant_id
          join public.optimization_runs_v2 assignment_run
            on assignment_run.id=assignment_variant.run_id
          join public.plan_shifts_v2 aps on aps.id=pa.shift_id
          join public.matrix_employee_profiles_v2 employee
            on employee.matrix_version_id=assignment_run.matrix_version_id
            and employee.employee_id=pa.employee_id
          join public.matrix_roles_v2 role on role.id=pa.role_id
          where aps.slot_group_key=sh.slot_group_key
            and aps.shift_template_id=sh.shift_template_id
            and aps.location_id=sh.location_id and aps.shift_date=sh.shift_date
            and aps.starts_at=sh.starts_at and aps.ends_at=sh.ends_at
        ),'[]'::jsonb)
      ) order by sh.starts_at,loc.sort_order,tmpl.sort_order,sh.slot_group_key)
      from grouped_shifts sh
      join public.matrix_locations_v2 loc on loc.id=sh.location_id
      join public.matrix_shift_templates_v2 tmpl on tmpl.id=sh.shift_template_id
    ),'[]'::jsonb),
    'issues',coalesce((select jsonb_agg(jsonb_build_object(
      'id',i.id,'variantId',i.variant_id,'slotKey',i.slot_key,'code',i.issue_code,
      'severity',i.severity,'message',i.message,
      'role',case when role.id is null then null else
        jsonb_build_object('id',role.id,'name',role.name) end,
      'duty',case when duty.id is null then null else
        jsonb_build_object('id',duty.id,'name',duty.name) end
    ) order by i.severity desc,i.id)
      from public.plan_issues_v2 i
      join requested r on r.variant_id=i.variant_id
      left join public.matrix_roles_v2 role on role.id=i.role_id
      left join public.matrix_duties_v2 duty on duty.id=i.duty_id
    ),'[]'::jsonb),
    'finance',case when p_can_view_finance then (
      select jsonb_build_object(
        'baseCostMinor',coalesce(sum(f.base_cost_minor),0),
        'additionsCostMinor',coalesce(sum(f.additions_cost_minor),0),
        'totalCostMinor',coalesce(sum(f.total_cost_minor),0),
        'currency',case when count(distinct snap.snapshot->>'currency')=1
          then min(snap.snapshot->>'currency') else null end,
        'budgetMinor',case when count(distinct f.budget_minor)=1
          then min(f.budget_minor) else null end)
      from requested r
      join public.plan_variants_v2 v on v.id=r.variant_id
      join solver_private.plan_variant_finance_v2 f on f.variant_id=r.variant_id
      join solver_private.optimization_snapshots_v2 snap on snap.run_id=v.run_id
    ) else null end
  );
$$;


ALTER FUNCTION "solver_private"."variant_set_workspace_v2"("p_variant_ids" "uuid"[], "p_context" "jsonb", "p_can_view_finance" boolean) OWNER TO "postgres";

--
-- Name: version_stamp_set_once_uat_v1("jsonb", "text", "jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."version_stamp_set_once_uat_v1"("p_stamp" "jsonb", "p_key" "text", "p_value" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
declare v_existing jsonb:=coalesce(p_stamp,'{}'::jsonb)->p_key;
begin
  if p_key is null or p_key='' then raise exception 'VERSION_STAMP_KEY_INVALID'; end if;
  if v_existing is null or v_existing='null'::jsonb then
    return jsonb_set(coalesce(p_stamp,'{}'::jsonb),array[p_key],p_value,true);
  end if;
  if v_existing is distinct from p_value then
    raise exception 'VERSION_STAMP_IMMUTABLE_%',upper(p_key);
  end if;
  return coalesce(p_stamp,'{}'::jsonb);
end;
$$;


ALTER FUNCTION "solver_private"."version_stamp_set_once_uat_v1"("p_stamp" "jsonb", "p_key" "text", "p_value" "jsonb") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";

--
-- Name: application_access_directory_v1; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."application_access_directory_v1" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "email" "text" NOT NULL,
    "app_role" "public"."app_role" NOT NULL,
    "role_logical_id" "uuid",
    "location_logical_id" "uuid",
    "auth_user_id" "uuid",
    "active" boolean DEFAULT true NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "application_access_directory_v1_email_check" CHECK ((POSITION(('@'::"text") IN ("email")) > 1))
);


ALTER TABLE "public"."application_access_directory_v1" OWNER TO "postgres";

--
-- Name: application_finance_visibility_policy_v1; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."application_finance_visibility_policy_v1" (
    "app_role" "public"."app_role" NOT NULL,
    "visibility" "text" NOT NULL,
    "updated_by" "uuid",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "application_finance_visibility_policy_v1_visibility_check" CHECK (("visibility" = ANY (ARRAY['NONE'::"text", 'BUDGET_ONLY'::"text", 'AGGREGATE'::"text", 'FULL'::"text"])))
);


ALTER TABLE "public"."application_finance_visibility_policy_v1" OWNER TO "postgres";

--
-- Name: assignments; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."assignments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "shift_id" "uuid" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "assigned_role" "public"."employee_role" NOT NULL,
    "assigned_capability" "text",
    "assignment_type" "text" DEFAULT 'STANDARD'::"text" NOT NULL,
    "cost" numeric(12,2) DEFAULT 0 NOT NULL,
    "locked" boolean DEFAULT false NOT NULL,
    "explanation" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."assignments" OWNER TO "postgres";

--
-- Name: attendance_events; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."attendance_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "shift_id" "uuid",
    "location_id" "uuid" NOT NULL,
    "event_type" "public"."attendance_event_type" NOT NULL,
    "occurred_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "verification_method" "text" NOT NULL,
    "qr_token_hash" "text",
    "latitude" numeric(9,6),
    "longitude" numeric(9,6),
    "evidence_path" "text",
    "device_fingerprint" "text",
    "created_by" "uuid",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL
);


ALTER TABLE "public"."attendance_events" OWNER TO "postgres";

--
-- Name: audit_log; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."audit_log" (
    "id" bigint NOT NULL,
    "actor_id" "uuid",
    "entity_type" "text" NOT NULL,
    "entity_id" "text" NOT NULL,
    "action" "text" NOT NULL,
    "old_data" "jsonb",
    "new_data" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."audit_log" OWNER TO "postgres";

--
-- Name: audit_log_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE "public"."audit_log" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."audit_log_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: availability_exception_reviews_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."availability_exception_reviews_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "hot_day_event_id" "uuid" NOT NULL,
    "role_id" "uuid" NOT NULL,
    "work_date" "date" NOT NULL,
    "requested_range" "tstzrange" NOT NULL,
    "note" "text",
    "status" "text" DEFAULT 'PENDING'::"text" NOT NULL,
    "requested_by" "uuid" NOT NULL,
    "requested_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "review_reason" "text",
    "constraint_id" "uuid",
    CONSTRAINT "availability_exception_reviews_v2_check" CHECK (((("status" = 'PENDING'::"text") AND ("reviewed_at" IS NULL)) OR (("status" <> 'PENDING'::"text") AND ("reviewed_at" IS NOT NULL)))),
    CONSTRAINT "availability_exception_reviews_v2_requested_range_check" CHECK ((NOT "isempty"("requested_range"))),
    CONSTRAINT "availability_exception_reviews_v2_status_check" CHECK (("status" = ANY (ARRAY['PENDING'::"text", 'APPROVED'::"text", 'REJECTED'::"text", 'CANCELLED'::"text"])))
);


ALTER TABLE "public"."availability_exception_reviews_v2" OWNER TO "postgres";

--
-- Name: business_app_integrations_v1; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."business_app_integrations_v1" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_code" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "base_url" "text",
    "launch_path_template" "text" DEFAULT '/sessions/new?eventId={eventId}'::"text" NOT NULL,
    "connection_status" "text" DEFAULT 'DISCONNECTED'::"text" NOT NULL,
    "active" boolean DEFAULT false NOT NULL,
    "configuration" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_by" "uuid",
    "updated_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "business_app_integrations_v1_base_url_check" CHECK ((("base_url" IS NULL) OR ("base_url" ~ '^https?://'::"text"))),
    CONSTRAINT "business_app_integrations_v1_connection_status_check" CHECK (("connection_status" = ANY (ARRAY['DISCONNECTED'::"text", 'CONFIGURED'::"text", 'READY'::"text", 'ERROR'::"text"]))),
    CONSTRAINT "business_app_integrations_v1_display_name_check" CHECK ((("length"(TRIM(BOTH FROM "display_name")) >= 2) AND ("length"(TRIM(BOTH FROM "display_name")) <= 120))),
    CONSTRAINT "business_app_integrations_v1_product_code_check" CHECK (("product_code" ~ '^[A-Z0-9_]{2,80}$'::"text"))
);


ALTER TABLE "public"."business_app_integrations_v1" OWNER TO "postgres";

--
-- Name: composite_schedules; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."composite_schedules" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "month" "date" NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "version" integer DEFAULT 1 NOT NULL,
    "name" "text" NOT NULL,
    "status" "text" DEFAULT 'DRAFT'::"text" NOT NULL,
    "section_ids" "uuid"[] DEFAULT '{}'::"uuid"[] NOT NULL,
    "created_by" "uuid",
    "published_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "composite_schedules_status_check" CHECK (("status" = ANY (ARRAY['DRAFT'::"text", 'VALIDATING'::"text", 'READY'::"text", 'PUBLISHED'::"text", 'STALE'::"text", 'ARCHIVED'::"text"])))
);


ALTER TABLE "public"."composite_schedules" OWNER TO "postgres";

--
-- Name: demand_rules; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."demand_rules" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "location_id" "uuid" NOT NULL,
    "shift_definition_id" "uuid" NOT NULL,
    "role" "public"."employee_role" NOT NULL,
    "required_count" integer NOT NULL,
    "required_capability" "text",
    "scenario_code" "text" DEFAULT 'BASE'::"text" NOT NULL,
    "valid_from" "date",
    "valid_to" "date",
    CONSTRAINT "demand_rules_required_count_check" CHECK (("required_count" >= 0))
);


ALTER TABLE "public"."demand_rules" OWNER TO "postgres";

--
-- Name: employee_availability; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."employee_availability" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "work_date" "date" NOT NULL,
    "available" boolean DEFAULT true NOT NULL,
    "earliest_start" time without time zone,
    "latest_end" time without time zone,
    "preferred_shift_code" "text",
    "note" "text",
    "source" "text" DEFAULT 'GRAFIK_PRO'::"text" NOT NULL,
    "updated_by" "uuid",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."employee_availability" OWNER TO "postgres";

--
-- Name: employee_availability_history; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."employee_availability_history" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "work_date" "date" NOT NULL,
    "old_available" boolean,
    "new_available" boolean NOT NULL,
    "source" "text" NOT NULL,
    "note" "text",
    "changed_by" "uuid",
    "changed_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."employee_availability_history" OWNER TO "postgres";

--
-- Name: employee_capabilities; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."employee_capabilities" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "capability" "text" NOT NULL,
    "scope_role" "public"."employee_role",
    "scope_location" "public"."location_code",
    "active" boolean DEFAULT true NOT NULL,
    CONSTRAINT "employee_capabilities_capability_check" CHECK (("capability" = ANY (ARRAY['HOST'::"text", 'CLOSE_SHIFT'::"text", 'ROLE_MANAGER'::"text", 'LOCATION_MANAGER'::"text", 'STANDBY'::"text", 'ROTATIONAL'::"text", 'OPEN_SHIFT'::"text"])))
);


ALTER TABLE "public"."employee_capabilities" OWNER TO "postgres";

--
-- Name: employee_hr_profiles; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."employee_hr_profiles" (
    "employee_id" "uuid" NOT NULL,
    "contract_type" "text" DEFAULT 'UMOWA_O_PRACE'::"text" NOT NULL,
    "position_name" "text",
    "employment_fraction" numeric(4,2) DEFAULT 1 NOT NULL,
    "leave_days" integer DEFAULT 0 NOT NULL,
    "medical_valid_to" "date",
    "training_valid_to" "date",
    "hr_note" "text",
    "updated_by" "uuid",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "employee_hr_profiles_contract_type_check" CHECK (("contract_type" = ANY (ARRAY['UMOWA_O_PRACE'::"text", 'ZLECENIE'::"text", 'CZESC_ETATU'::"text", 'B2B'::"text", 'INNE'::"text"]))),
    CONSTRAINT "employee_hr_profiles_employment_fraction_check" CHECK ((("employment_fraction" > (0)::numeric) AND ("employment_fraction" <= (1)::numeric))),
    CONSTRAINT "employee_hr_profiles_leave_days_check" CHECK (("leave_days" >= 0))
);


ALTER TABLE "public"."employee_hr_profiles" OWNER TO "postgres";

--
-- Name: employee_locations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."employee_locations" (
    "employee_id" "uuid" NOT NULL,
    "location_id" "uuid" NOT NULL,
    "standard_allowed" boolean DEFAULT false NOT NULL,
    "overtime_allowed" boolean DEFAULT false NOT NULL,
    "home_location" boolean DEFAULT false NOT NULL,
    CONSTRAINT "employee_locations_check" CHECK (("standard_allowed" OR "overtime_allowed" OR "home_location"))
);


ALTER TABLE "public"."employee_locations" OWNER TO "postgres";

--
-- Name: employee_pay_rates_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."employee_pay_rates_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "valid_from" "date" NOT NULL,
    "valid_to" "date",
    "base_rate_minor" bigint NOT NULL,
    "currency" "text" NOT NULL,
    "contract_type" "text",
    "active" boolean DEFAULT true NOT NULL,
    "created_by" "uuid",
    "updated_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "employee_pay_rates_v2_base_rate_minor_check" CHECK (("base_rate_minor" >= 0)),
    CONSTRAINT "employee_pay_rates_v2_check" CHECK ((("valid_to" IS NULL) OR ("valid_to" >= "valid_from"))),
    CONSTRAINT "employee_pay_rates_v2_currency_check" CHECK ("public"."matrix_v2_is_iso_4217_currency"("currency"))
);


ALTER TABLE "public"."employee_pay_rates_v2" OWNER TO "postgres";

--
-- Name: employee_preferences; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."employee_preferences" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "valid_from" "date" NOT NULL,
    "valid_to" "date" NOT NULL,
    "preference_type" "text" NOT NULL,
    "preference_value" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "source" "text" DEFAULT 'GRAFIK_PRO'::"text" NOT NULL,
    "editable_by_employee" boolean DEFAULT true NOT NULL,
    "status" "text" DEFAULT 'ACTIVE'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "employee_preferences_check" CHECK (("valid_to" >= "valid_from")),
    CONSTRAINT "employee_preferences_preference_type_check" CHECK (("preference_type" = ANY (ARRAY['AVAILABLE'::"text", 'UNAVAILABLE'::"text", 'PREFERRED_SHIFT'::"text", 'PREFERRED_LOCATION'::"text", 'LEAVE'::"text", 'SICKNESS'::"text", 'OTHER'::"text"]))),
    CONSTRAINT "employee_preferences_source_check" CHECK (("source" = ANY (ARRAY['GRAFIK_PRO'::"text", 'KADROMIERZ'::"text", 'MANAGER'::"text", 'SYSTEM'::"text"]))),
    CONSTRAINT "employee_preferences_status_check" CHECK (("status" = ANY (ARRAY['DRAFT'::"text", 'ACTIVE'::"text", 'REJECTED'::"text", 'CANCELLED'::"text"])))
);


ALTER TABLE "public"."employee_preferences" OWNER TO "postgres";

--
-- Name: employee_requests_v1; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."employee_requests_v1" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "requested_by" "uuid" NOT NULL,
    "request_type" "text" NOT NULL,
    "date_from" "date" NOT NULL,
    "date_to" "date" NOT NULL,
    "requested_range" "tstzrange" NOT NULL,
    "status" "text" NOT NULL,
    "requires_decision" boolean DEFAULT false NOT NULL,
    "note" "text",
    "constraint_id" "uuid",
    "legacy_review_id" "uuid",
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "review_reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "employee_requests_v1_check" CHECK (("date_to" >= "date_from")),
    CONSTRAINT "employee_requests_v1_check1" CHECK (((("status" = 'PENDING'::"text") AND ("reviewed_at" IS NULL)) OR ("status" <> 'PENDING'::"text"))),
    CONSTRAINT "employee_requests_v1_request_type_check" CHECK (("request_type" = ANY (ARRAY['LEAVE'::"text", 'SICKNESS'::"text", 'HARD_UNAVAILABLE'::"text"]))),
    CONSTRAINT "employee_requests_v1_requested_range_check" CHECK ((NOT "isempty"("requested_range"))),
    CONSTRAINT "employee_requests_v1_requested_range_check1" CHECK ((("lower"("requested_range") IS NOT NULL) AND ("upper"("requested_range") IS NOT NULL))),
    CONSTRAINT "employee_requests_v1_status_check" CHECK (("status" = ANY (ARRAY['PENDING'::"text", 'APPLIED'::"text", 'AUTO_APPLIED'::"text", 'APPROVED'::"text", 'REJECTED'::"text", 'CANCELLED'::"text", 'ACKNOWLEDGED'::"text"])))
);


ALTER TABLE "public"."employee_requests_v1" OWNER TO "postgres";

--
-- Name: employee_time_constraints_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."employee_time_constraints_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "constraint_kind" "text" NOT NULL,
    "time_range" "tstzrange" NOT NULL,
    "location_logical_id" "uuid",
    "source" "text" DEFAULT 'GRAFIK_PRO'::"text" NOT NULL,
    "source_record_key" "text",
    "priority" smallint DEFAULT 100 NOT NULL,
    "editable_by_employee" boolean DEFAULT true NOT NULL,
    "status" "text" DEFAULT 'ACTIVE'::"text" NOT NULL,
    "note" "text",
    "supersedes_id" "uuid",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "revoked_at" timestamp with time zone,
    CONSTRAINT "employee_time_constraints_v2_constraint_kind_check" CHECK (("constraint_kind" = ANY (ARRAY['AVAILABLE_WINDOW'::"text", 'UNAVAILABLE'::"text", 'LEAVE'::"text", 'SICKNESS'::"text"]))),
    CONSTRAINT "employee_time_constraints_v2_status_check" CHECK (("status" = ANY (ARRAY['ACTIVE'::"text", 'REVOKED'::"text"]))),
    CONSTRAINT "employee_time_constraints_v2_time_range_check" CHECK ((NOT "isempty"("time_range"))),
    CONSTRAINT "employee_time_constraints_v2_time_range_check1" CHECK ((("lower"("time_range") IS NOT NULL) AND ("upper"("time_range") IS NOT NULL)))
);


ALTER TABLE "public"."employee_time_constraints_v2" OWNER TO "postgres";

--
-- Name: employee_weekly_work_patterns_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."employee_weekly_work_patterns_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "weekday" smallint NOT NULL,
    "local_start" time without time zone NOT NULL,
    "local_end" time without time zone NOT NULL,
    "role_id" "uuid",
    "location_id" "uuid",
    "enforcement" "text" NOT NULL,
    "valid_from" "date" NOT NULL,
    "valid_to" "date",
    "active" boolean DEFAULT true NOT NULL,
    "revision" integer DEFAULT 1 NOT NULL,
    "supersedes_id" "uuid",
    "reason" "text" NOT NULL,
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "revoked_at" timestamp with time zone,
    CONSTRAINT "employee_weekly_work_patterns_v2_check" CHECK ((("valid_to" IS NULL) OR ("valid_to" >= "valid_from"))),
    CONSTRAINT "employee_weekly_work_patterns_v2_enforcement_check" CHECK (("enforcement" = ANY (ARRAY['HARD'::"text", 'PREFERENCE'::"text"]))),
    CONSTRAINT "employee_weekly_work_patterns_v2_reason_check" CHECK (("length"(TRIM(BOTH FROM "reason")) >= 3)),
    CONSTRAINT "employee_weekly_work_patterns_v2_revision_check" CHECK (("revision" > 0)),
    CONSTRAINT "employee_weekly_work_patterns_v2_weekday_check" CHECK ((("weekday" >= 1) AND ("weekday" <= 7)))
);


ALTER TABLE "public"."employee_weekly_work_patterns_v2" OWNER TO "postgres";

--
-- Name: employees; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."employees" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "auth_user_id" "uuid",
    "employee_no" "text" NOT NULL,
    "first_name" "text" NOT NULL,
    "last_name" "text" NOT NULL,
    "email" "text",
    "primary_role" "public"."employee_role",
    "monthly_nominal_minutes" integer NOT NULL,
    "max_weekly_minutes" integer DEFAULT 2400 NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "employment_start" "date",
    "employment_end" "date",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "hourly_rate" numeric(10,2) DEFAULT 30 NOT NULL,
    "preferred_shift" "text",
    "max_monthly_minutes" integer,
    "archived_at" timestamp with time zone,
    "archived_by" "uuid",
    "archive_reason" "text",
    "max_consecutive_days" integer DEFAULT 6 NOT NULL,
    "minimum_rest_minutes" integer,
    "only_morning" boolean DEFAULT false NOT NULL,
    "only_evening" boolean DEFAULT false NOT NULL,
    "no_weekends" boolean DEFAULT false NOT NULL,
    CONSTRAINT "employees_check" CHECK ((("employment_end" IS NULL) OR ("employment_start" IS NULL) OR ("employment_end" >= "employment_start"))),
    CONSTRAINT "employees_max_weekly_minutes_check" CHECK ((("max_weekly_minutes" >= 0) AND ("max_weekly_minutes" <= 10080))),
    CONSTRAINT "employees_monthly_nominal_minutes_check" CHECK (("monthly_nominal_minutes" >= 0))
);


ALTER TABLE "public"."employees" OWNER TO "postgres";

--
-- Name: employer_cost_components_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."employer_cost_components_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "logical_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "revision" integer DEFAULT 1 NOT NULL,
    "supersedes_id" "uuid",
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "calculation_method" "text" NOT NULL,
    "percent_basis_points" integer,
    "rate_minor_per_hour" bigint,
    "amount_minor" bigint,
    "contract_type" "text",
    "valid_from" "date" NOT NULL,
    "valid_to" "date",
    "active" boolean DEFAULT true NOT NULL,
    "reason" "text" NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "employer_cost_components_v2_amount_minor_check" CHECK (("amount_minor" >= 0)),
    CONSTRAINT "employer_cost_components_v2_calculation_method_check" CHECK (("calculation_method" = ANY (ARRAY['PERCENT_BASE'::"text", 'PER_HOUR'::"text", 'FIXED_PER_SHIFT'::"text"]))),
    CONSTRAINT "employer_cost_components_v2_check" CHECK ((("valid_to" IS NULL) OR ("valid_to" >= "valid_from"))),
    CONSTRAINT "employer_cost_components_v2_check1" CHECK (((("calculation_method" = 'PERCENT_BASE'::"text") AND ("percent_basis_points" IS NOT NULL) AND ("rate_minor_per_hour" IS NULL) AND ("amount_minor" IS NULL)) OR (("calculation_method" = 'PER_HOUR'::"text") AND ("rate_minor_per_hour" IS NOT NULL) AND ("percent_basis_points" IS NULL) AND ("amount_minor" IS NULL)) OR (("calculation_method" = 'FIXED_PER_SHIFT'::"text") AND ("amount_minor" IS NOT NULL) AND ("percent_basis_points" IS NULL) AND ("rate_minor_per_hour" IS NULL)))),
    CONSTRAINT "employer_cost_components_v2_code_check" CHECK ((("length"(TRIM(BOTH FROM "code")) >= 1) AND ("length"(TRIM(BOTH FROM "code")) <= 80))),
    CONSTRAINT "employer_cost_components_v2_name_check" CHECK ((("length"(TRIM(BOTH FROM "name")) >= 1) AND ("length"(TRIM(BOTH FROM "name")) <= 160))),
    CONSTRAINT "employer_cost_components_v2_percent_basis_points_check" CHECK (("percent_basis_points" >= 0)),
    CONSTRAINT "employer_cost_components_v2_rate_minor_per_hour_check" CHECK (("rate_minor_per_hour" >= 0)),
    CONSTRAINT "employer_cost_components_v2_reason_check" CHECK (("length"(TRIM(BOTH FROM "reason")) >= 5)),
    CONSTRAINT "employer_cost_components_v2_revision_check" CHECK (("revision" > 0))
);


ALTER TABLE "public"."employer_cost_components_v2" OWNER TO "postgres";

--
-- Name: event_demand_changes; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."event_demand_changes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "role" "public"."employee_role" NOT NULL,
    "shift_code" "text",
    "additional_count" integer DEFAULT 0 NOT NULL,
    "custom_start" timestamp with time zone,
    "custom_end" timestamp with time zone,
    "required_capability" "text"
);


ALTER TABLE "public"."event_demand_changes" OWNER TO "postgres";

--
-- Name: integration_runs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."integration_runs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "integration" "text" NOT NULL,
    "direction" "text" NOT NULL,
    "entity_type" "text" NOT NULL,
    "status" "text" NOT NULL,
    "file_name" "text",
    "summary" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "executed_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "integration_runs_direction_check" CHECK (("direction" = ANY (ARRAY['IMPORT'::"text", 'EXPORT'::"text"]))),
    CONSTRAINT "integration_runs_status_check" CHECK (("status" = ANY (ARRAY['QUEUED'::"text", 'RUNNING'::"text", 'SUCCESS'::"text", 'PARTIAL'::"text", 'FAILED'::"text"])))
);


ALTER TABLE "public"."integration_runs" OWNER TO "postgres";

--
-- Name: locations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."locations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "public"."location_code" NOT NULL,
    "name" "text" NOT NULL,
    "timezone" "text" DEFAULT 'Europe/Warsaw'::"text" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."locations" OWNER TO "postgres";

--
-- Name: matrix_conflicts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_conflicts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "composite_schedule_id" "uuid",
    "role_plan_section_id" "uuid",
    "employee_id" "uuid",
    "conflict_type" "text" NOT NULL,
    "severity" "text" NOT NULL,
    "work_date" "date",
    "message" "text" NOT NULL,
    "status" "text" DEFAULT 'OPEN'::"text" NOT NULL,
    "resolution_note" "text",
    "resolved_by" "uuid",
    "resolved_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "matrix_conflicts_severity_check" CHECK (("severity" = ANY (ARRAY['INFO'::"text", 'WARNING'::"text", 'CRITICAL'::"text"]))),
    CONSTRAINT "matrix_conflicts_status_check" CHECK (("status" = ANY (ARRAY['OPEN'::"text", 'ACKNOWLEDGED'::"text", 'RESOLVED'::"text", 'WAIVED'::"text"])))
);


ALTER TABLE "public"."matrix_conflicts" OWNER TO "postgres";

--
-- Name: matrix_demand; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_demand" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "shift_template_id" "uuid" NOT NULL,
    "role_id" "uuid" NOT NULL,
    "function_id" "uuid",
    "scenario_code" "text" DEFAULT 'BASE'::"text" NOT NULL,
    "required_count" integer DEFAULT 1 NOT NULL,
    CONSTRAINT "matrix_demand_required_count_check" CHECK (("required_count" >= 0))
);


ALTER TABLE "public"."matrix_demand" OWNER TO "postgres";

--
-- Name: matrix_duties_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_duties_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "logical_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "color" "text" DEFAULT '#4a8d78'::"text" NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "matrix_duties_v2_code_check" CHECK ((("length"(TRIM(BOTH FROM "code")) >= 1) AND ("length"(TRIM(BOTH FROM "code")) <= 80))),
    CONSTRAINT "matrix_duties_v2_name_check" CHECK ((("length"(TRIM(BOTH FROM "name")) >= 1) AND ("length"(TRIM(BOTH FROM "name")) <= 160)))
);


ALTER TABLE "public"."matrix_duties_v2" OWNER TO "postgres";

--
-- Name: matrix_employee_duties_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_employee_duties_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "duty_id" "uuid" NOT NULL,
    "role_id" "uuid",
    "location_id" "uuid",
    "active" boolean DEFAULT true NOT NULL,
    "valid_from" "date",
    "valid_to" "date",
    "source" "text" DEFAULT 'MATRIX'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "matrix_employee_duties_v2_check" CHECK ((("valid_to" IS NULL) OR ("valid_from" IS NULL) OR ("valid_to" >= "valid_from")))
);


ALTER TABLE "public"."matrix_employee_duties_v2" OWNER TO "postgres";

--
-- Name: matrix_employee_locations_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_employee_locations_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "location_id" "uuid" NOT NULL,
    "standard_allowed" boolean DEFAULT false NOT NULL,
    "overtime_allowed" boolean DEFAULT false NOT NULL,
    "home_location" boolean DEFAULT false NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "valid_from" "date",
    "valid_to" "date",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "matrix_employee_locations_v2_check" CHECK (((NOT "active") OR "standard_allowed" OR "overtime_allowed" OR "home_location")),
    CONSTRAINT "matrix_employee_locations_v2_check1" CHECK ((("valid_to" IS NULL) OR ("valid_from" IS NULL) OR ("valid_to" >= "valid_from")))
);


ALTER TABLE "public"."matrix_employee_locations_v2" OWNER TO "postgres";

--
-- Name: CONSTRAINT "matrix_employee_locations_v2_check" ON "matrix_employee_locations_v2"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON CONSTRAINT "matrix_employee_locations_v2_check" ON "public"."matrix_employee_locations_v2" IS 'Active grants require at least one capability; inactive versioned rows may retain no access.';


--
-- Name: matrix_employee_profiles_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_employee_profiles_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "employee_no" "text" NOT NULL,
    "first_name" "text" NOT NULL,
    "last_name" "text" NOT NULL,
    "email" "text",
    "active" boolean DEFAULT true NOT NULL,
    "employment_start" "date",
    "employment_end" "date",
    "nominal_monthly_minutes" integer NOT NULL,
    "maximum_monthly_minutes" integer NOT NULL,
    "maximum_weekly_minutes" integer NOT NULL,
    "maximum_consecutive_days" integer NOT NULL,
    "minimum_rest_minutes" integer,
    "only_morning" boolean DEFAULT false NOT NULL,
    "only_evening" boolean DEFAULT false NOT NULL,
    "no_weekends" boolean DEFAULT false NOT NULL,
    "preferred_shift_code" "text",
    "archived_at" timestamp with time zone,
    "archived_by" "uuid",
    "archive_reason" "text",
    "created_by" "uuid",
    "updated_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "work_time_policy" "text" DEFAULT 'CONTRACT_DEFAULT'::"text" NOT NULL,
    "employment_stage" "text" DEFAULT 'REGULAR'::"text" NOT NULL,
    "probation_end" "date",
    "overtime_policy" "text" DEFAULT 'NEVER'::"text" NOT NULL,
    CONSTRAINT "matrix_employee_profiles_v2_check" CHECK (("maximum_monthly_minutes" >= "nominal_monthly_minutes")),
    CONSTRAINT "matrix_employee_profiles_v2_check1" CHECK ((("employment_end" IS NULL) OR ("employment_start" IS NULL) OR ("employment_end" >= "employment_start"))),
    CONSTRAINT "matrix_employee_profiles_v2_check2" CHECK ((NOT ("only_morning" AND "only_evening"))),
    CONSTRAINT "matrix_employee_profiles_v2_check3" CHECK ((("active" AND ("archived_at" IS NULL) AND ("archived_by" IS NULL)) OR ((NOT "active") AND ("archived_at" IS NOT NULL)))),
    CONSTRAINT "matrix_employee_profiles_v2_email_check" CHECK ((("email" IS NULL) OR ("email" = "lower"(TRIM(BOTH FROM "email"))))),
    CONSTRAINT "matrix_employee_profiles_v2_employee_no_check" CHECK ((("length"(TRIM(BOTH FROM "employee_no")) >= 1) AND ("length"(TRIM(BOTH FROM "employee_no")) <= 80))),
    CONSTRAINT "matrix_employee_profiles_v2_employment_stage_check" CHECK (("employment_stage" = ANY (ARRAY['PROBATION'::"text", 'REGULAR'::"text", 'NOTICE'::"text"]))),
    CONSTRAINT "matrix_employee_profiles_v2_first_name_check" CHECK ((("length"(TRIM(BOTH FROM "first_name")) >= 1) AND ("length"(TRIM(BOTH FROM "first_name")) <= 120))),
    CONSTRAINT "matrix_employee_profiles_v2_last_name_check" CHECK ((("length"(TRIM(BOTH FROM "last_name")) >= 1) AND ("length"(TRIM(BOTH FROM "last_name")) <= 160))),
    CONSTRAINT "matrix_employee_profiles_v2_maximum_consecutive_days_check" CHECK ((("maximum_consecutive_days" >= 1) AND ("maximum_consecutive_days" <= 31))),
    CONSTRAINT "matrix_employee_profiles_v2_maximum_monthly_minutes_check" CHECK ((("maximum_monthly_minutes" >= 0) AND ("maximum_monthly_minutes" <= 44640))),
    CONSTRAINT "matrix_employee_profiles_v2_maximum_weekly_minutes_check" CHECK ((("maximum_weekly_minutes" >= 0) AND ("maximum_weekly_minutes" <= 10080))),
    CONSTRAINT "matrix_employee_profiles_v2_minimum_rest_minutes_check" CHECK ((("minimum_rest_minutes" >= 0) AND ("minimum_rest_minutes" <= 2880))),
    CONSTRAINT "matrix_employee_profiles_v2_nominal_monthly_minutes_check" CHECK ((("nominal_monthly_minutes" >= 0) AND ("nominal_monthly_minutes" <= 44640))),
    CONSTRAINT "matrix_employee_profiles_v2_overtime_policy_check" CHECK (("overtime_policy" = ANY (ARRAY['NEVER'::"text", 'APPROVAL_REQUIRED'::"text", 'ALLOWED'::"text"]))),
    CONSTRAINT "matrix_employee_profiles_v2_work_time_policy_check" CHECK (("work_time_policy" = ANY (ARRAY['CONTRACT_DEFAULT'::"text", 'CUSTOM'::"text"])))
);


ALTER TABLE "public"."matrix_employee_profiles_v2" OWNER TO "postgres";

--
-- Name: TABLE "matrix_employee_profiles_v2"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE "public"."matrix_employee_profiles_v2" IS 'Versioned employee scheduling profiles. Active and archived Matrix versions are immutable.';


--
-- Name: COLUMN "matrix_employee_profiles_v2"."work_time_policy"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN "public"."matrix_employee_profiles_v2"."work_time_policy" IS 'CONTRACT_DEFAULT applies employment-law caps only to employment contracts. CUSTOM makes individually entered caps hard also for flexible contracts.';


--
-- Name: matrix_employee_roles; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_employee_roles" (
    "matrix_version_id" "uuid" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "role_id" "uuid" NOT NULL,
    "is_primary" boolean DEFAULT false NOT NULL,
    "can_lead" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."matrix_employee_roles" OWNER TO "postgres";

--
-- Name: matrix_employee_roles_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_employee_roles_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "role_id" "uuid" NOT NULL,
    "is_primary" boolean DEFAULT false NOT NULL,
    "can_lead" boolean DEFAULT false NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "valid_from" "date",
    "valid_to" "date",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "assignment_mode" "text" DEFAULT 'STANDARD'::"text" NOT NULL,
    "backup_priority" integer DEFAULT 100 NOT NULL,
    "created_by" "uuid",
    "updated_by" "uuid",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "matrix_employee_roles_v2_assignment_mode_check" CHECK (("assignment_mode" = ANY (ARRAY['STANDARD'::"text", 'BACKUP'::"text"]))),
    CONSTRAINT "matrix_employee_roles_v2_backup_priority_check" CHECK ((("backup_priority" >= 1) AND ("backup_priority" <= 999))),
    CONSTRAINT "matrix_employee_roles_v2_check" CHECK ((("valid_to" IS NULL) OR ("valid_from" IS NULL) OR ("valid_to" >= "valid_from"))),
    CONSTRAINT "matrix_employee_roles_v2_primary_standard_check" CHECK (((NOT "is_primary") OR ("assignment_mode" = 'STANDARD'::"text")))
);


ALTER TABLE "public"."matrix_employee_roles_v2" OWNER TO "postgres";

--
-- Name: COLUMN "matrix_employee_roles_v2"."created_by"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN "public"."matrix_employee_roles_v2"."created_by" IS 'Actor who created the versioned employee-role assignment.';


--
-- Name: COLUMN "matrix_employee_roles_v2"."updated_by"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN "public"."matrix_employee_roles_v2"."updated_by" IS 'Actor who last changed the versioned employee-role assignment.';


--
-- Name: COLUMN "matrix_employee_roles_v2"."updated_at"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN "public"."matrix_employee_roles_v2"."updated_at" IS 'Timestamp of the latest employee-role assignment change.';


--
-- Name: matrix_functions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_functions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "active" boolean DEFAULT true NOT NULL
);


ALTER TABLE "public"."matrix_functions" OWNER TO "postgres";

--
-- Name: matrix_import_runs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_import_runs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "file_name" "text" NOT NULL,
    "matrix_version_id" "uuid",
    "status" "text" NOT NULL,
    "summary" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "requested_permissions" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "matrix_import_runs_status_check" CHECK (("status" = ANY (ARRAY['VALIDATED'::"text", 'IMPORTED'::"text", 'REJECTED'::"text"])))
);


ALTER TABLE "public"."matrix_import_runs" OWNER TO "postgres";

--
-- Name: matrix_locations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_locations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "active" boolean DEFAULT true NOT NULL
);


ALTER TABLE "public"."matrix_locations" OWNER TO "postgres";

--
-- Name: matrix_locations_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_locations_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "logical_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "timezone" "text" NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "matrix_locations_v2_code_check" CHECK ((("length"(TRIM(BOTH FROM "code")) >= 1) AND ("length"(TRIM(BOTH FROM "code")) <= 80))),
    CONSTRAINT "matrix_locations_v2_name_check" CHECK ((("length"(TRIM(BOTH FROM "name")) >= 1) AND ("length"(TRIM(BOTH FROM "name")) <= 160)))
);


ALTER TABLE "public"."matrix_locations_v2" OWNER TO "postgres";

--
-- Name: matrix_pay_rule_duties_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_pay_rule_duties_v2" (
    "matrix_version_id" "uuid" NOT NULL,
    "pay_rule_id" "uuid" NOT NULL,
    "duty_id" "uuid" NOT NULL,
    "match_mode" "text" DEFAULT 'ANY'::"text" NOT NULL,
    CONSTRAINT "matrix_pay_rule_duties_v2_match_mode_check" CHECK (("match_mode" = ANY (ARRAY['ANY'::"text", 'ALL'::"text"])))
);


ALTER TABLE "public"."matrix_pay_rule_duties_v2" OWNER TO "postgres";

--
-- Name: matrix_pay_rule_locations_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_pay_rule_locations_v2" (
    "matrix_version_id" "uuid" NOT NULL,
    "pay_rule_id" "uuid" NOT NULL,
    "location_id" "uuid" NOT NULL
);


ALTER TABLE "public"."matrix_pay_rule_locations_v2" OWNER TO "postgres";

--
-- Name: matrix_pay_rule_roles_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_pay_rule_roles_v2" (
    "matrix_version_id" "uuid" NOT NULL,
    "pay_rule_id" "uuid" NOT NULL,
    "role_id" "uuid" NOT NULL
);


ALTER TABLE "public"."matrix_pay_rule_roles_v2" OWNER TO "postgres";

--
-- Name: matrix_pay_rule_shifts_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_pay_rule_shifts_v2" (
    "matrix_version_id" "uuid" NOT NULL,
    "pay_rule_id" "uuid" NOT NULL,
    "shift_template_id" "uuid" NOT NULL
);


ALTER TABLE "public"."matrix_pay_rule_shifts_v2" OWNER TO "postgres";

--
-- Name: matrix_pay_rules_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_pay_rules_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "logical_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "calculation_method" "text" NOT NULL,
    "amount_minor" bigint,
    "rate_minor_per_hour" bigint,
    "percent_basis_points" integer,
    "multiplier_basis_points" integer,
    "threshold_minutes" integer,
    "currency" "text" NOT NULL,
    "priority" integer DEFAULT 100 NOT NULL,
    "stacking_group" "text",
    "stacking_mode" "text" DEFAULT 'STACK'::"text" NOT NULL,
    "day_mask" smallint[] DEFAULT ARRAY[(1)::smallint, (2)::smallint, (3)::smallint, (4)::smallint, (5)::smallint, (6)::smallint, (7)::smallint] NOT NULL,
    "local_start" time without time zone,
    "local_end" time without time zone,
    "ends_next_day" boolean DEFAULT false NOT NULL,
    "valid_from" "date",
    "valid_to" "date",
    "condition_expression" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "formula_expression" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "matrix_pay_rules_v2_amount_minor_check" CHECK ((("amount_minor" IS NULL) OR ("amount_minor" >= 0))),
    CONSTRAINT "matrix_pay_rules_v2_calculation_method_check" CHECK (("calculation_method" = ANY (ARRAY['FIXED_PER_SHIFT'::"text", 'PER_HOUR'::"text", 'PERCENT_BASE'::"text", 'MULTIPLIER'::"text", 'SHIFT_DURATION_THRESHOLD_PER_HOUR'::"text", 'MONTHLY_THRESHOLD_PER_HOUR'::"text"]))),
    CONSTRAINT "matrix_pay_rules_v2_check" CHECK ((("valid_to" IS NULL) OR ("valid_from" IS NULL) OR ("valid_to" >= "valid_from"))),
    CONSTRAINT "matrix_pay_rules_v2_check1" CHECK (((("calculation_method" = 'FIXED_PER_SHIFT'::"text") AND ("amount_minor" IS NOT NULL)) OR (("calculation_method" = 'PER_HOUR'::"text") AND ("rate_minor_per_hour" IS NOT NULL)) OR (("calculation_method" = 'PERCENT_BASE'::"text") AND ("percent_basis_points" IS NOT NULL)) OR (("calculation_method" = 'MULTIPLIER'::"text") AND ("multiplier_basis_points" IS NOT NULL)) OR (("calculation_method" = ANY (ARRAY['SHIFT_DURATION_THRESHOLD_PER_HOUR'::"text", 'MONTHLY_THRESHOLD_PER_HOUR'::"text"])) AND ("threshold_minutes" IS NOT NULL) AND ("rate_minor_per_hour" IS NOT NULL)))),
    CONSTRAINT "matrix_pay_rules_v2_code_check" CHECK ((("length"(TRIM(BOTH FROM "code")) >= 1) AND ("length"(TRIM(BOTH FROM "code")) <= 80))),
    CONSTRAINT "matrix_pay_rules_v2_currency_check" CHECK ("public"."matrix_v2_is_iso_4217_currency"("currency")),
    CONSTRAINT "matrix_pay_rules_v2_day_mask_check" CHECK ((("cardinality"("day_mask") >= 1) AND ("cardinality"("day_mask") <= 7))),
    CONSTRAINT "matrix_pay_rules_v2_day_mask_check1" CHECK (("day_mask" <@ ARRAY[(1)::smallint, (2)::smallint, (3)::smallint, (4)::smallint, (5)::smallint, (6)::smallint, (7)::smallint])),
    CONSTRAINT "matrix_pay_rules_v2_multiplier_basis_points_check" CHECK ((("multiplier_basis_points" IS NULL) OR ("multiplier_basis_points" >= 0))),
    CONSTRAINT "matrix_pay_rules_v2_name_check" CHECK ((("length"(TRIM(BOTH FROM "name")) >= 1) AND ("length"(TRIM(BOTH FROM "name")) <= 160))),
    CONSTRAINT "matrix_pay_rules_v2_percent_basis_points_check" CHECK ((("percent_basis_points" IS NULL) OR ("percent_basis_points" >= 0))),
    CONSTRAINT "matrix_pay_rules_v2_rate_minor_per_hour_check" CHECK ((("rate_minor_per_hour" IS NULL) OR ("rate_minor_per_hour" >= 0))),
    CONSTRAINT "matrix_pay_rules_v2_stacking_mode_check" CHECK (("stacking_mode" = ANY (ARRAY['STACK'::"text", 'MAX'::"text", 'FIRST'::"text"]))),
    CONSTRAINT "matrix_pay_rules_v2_threshold_minutes_check" CHECK ((("threshold_minutes" IS NULL) OR ("threshold_minutes" >= 0)))
);


ALTER TABLE "public"."matrix_pay_rules_v2" OWNER TO "postgres";

--
-- Name: matrix_role_categories_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_role_categories_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "logical_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "color" "text" DEFAULT '#7257d8'::"text" NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "matrix_role_categories_v2_code_check" CHECK ((("length"(TRIM(BOTH FROM "code")) >= 1) AND ("length"(TRIM(BOTH FROM "code")) <= 80))),
    CONSTRAINT "matrix_role_categories_v2_color_check" CHECK (("color" ~ '^#[0-9A-Fa-f]{6}$'::"text")),
    CONSTRAINT "matrix_role_categories_v2_name_check" CHECK ((("length"(TRIM(BOTH FROM "name")) >= 1) AND ("length"(TRIM(BOTH FROM "name")) <= 160)))
);


ALTER TABLE "public"."matrix_role_categories_v2" OWNER TO "postgres";

--
-- Name: matrix_role_duties_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_role_duties_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "role_id" "uuid" NOT NULL,
    "duty_id" "uuid" NOT NULL,
    "assignment_mode" "text" DEFAULT 'OPTIONAL'::"text" NOT NULL,
    "minimum_count" integer DEFAULT 0 NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "shift_obligation" boolean DEFAULT false NOT NULL,
    "shift_period" "text",
    CONSTRAINT "matrix_role_duties_required_positive_uat006" CHECK ((("assignment_mode" <> 'REQUIRED'::"text") OR ("minimum_count" >= 1))),
    CONSTRAINT "matrix_role_duties_v2_assignment_mode_check" CHECK (("assignment_mode" = ANY (ARRAY['REQUIRED'::"text", 'OPTIONAL'::"text", 'EXTRA'::"text"]))),
    CONSTRAINT "matrix_role_duties_v2_competency_only_check" CHECK ((("assignment_mode" = ANY (ARRAY['OPTIONAL'::"text", 'EXTRA'::"text"])) AND ("minimum_count" = 0) AND (NOT "shift_obligation") AND ("shift_period" IS NULL))),
    CONSTRAINT "matrix_role_duties_v2_minimum_count_check" CHECK (("minimum_count" >= 0))
);


ALTER TABLE "public"."matrix_role_duties_v2" OWNER TO "postgres";

--
-- Name: CONSTRAINT "matrix_role_duties_v2_competency_only_check" ON "matrix_role_duties_v2"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON CONSTRAINT "matrix_role_duties_v2_competency_only_check" ON "public"."matrix_role_duties_v2" IS 'Role-duty rows never create demand. Exact shift demand lives in matrix_staffing_rules_v2.';


--
-- Name: matrix_role_functions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_role_functions" (
    "role_id" "uuid" NOT NULL,
    "function_id" "uuid" NOT NULL,
    "assignment_mode" "text" DEFAULT 'OPTIONAL'::"text" NOT NULL,
    CONSTRAINT "matrix_role_functions_assignment_mode_check" CHECK (("assignment_mode" = ANY (ARRAY['REQUIRED'::"text", 'OPTIONAL'::"text", 'EXTRA'::"text"])))
);


ALTER TABLE "public"."matrix_role_functions" OWNER TO "postgres";

--
-- Name: matrix_roles; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_roles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "color" "text" DEFAULT '#7257d8'::"text" NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "active" boolean DEFAULT true NOT NULL
);


ALTER TABLE "public"."matrix_roles" OWNER TO "postgres";

--
-- Name: matrix_roles_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_roles_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "logical_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "color" "text" DEFAULT '#7257d8'::"text" NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "category_id" "uuid",
    CONSTRAINT "matrix_roles_v2_code_check" CHECK ((("length"(TRIM(BOTH FROM "code")) >= 1) AND ("length"(TRIM(BOTH FROM "code")) <= 80))),
    CONSTRAINT "matrix_roles_v2_name_check" CHECK ((("length"(TRIM(BOTH FROM "name")) >= 1) AND ("length"(TRIM(BOTH FROM "name")) <= 160)))
);


ALTER TABLE "public"."matrix_roles_v2" OWNER TO "postgres";

--
-- Name: matrix_scenario_budgets_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_scenario_budgets_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "scenario_id" "uuid" NOT NULL,
    "budget_month" "date",
    "location_id" "uuid",
    "role_id" "uuid",
    "duty_id" "uuid",
    "operation" "text" DEFAULT 'SET'::"text" NOT NULL,
    "amount_minor" bigint,
    "multiplier_basis_points" integer,
    "currency" "text" NOT NULL,
    "hard_limit" boolean,
    "warning_percent" integer,
    "source_metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "matrix_scenario_budgets_v2_budget_month_check" CHECK ((("budget_month" IS NULL) OR (("date_trunc"('month'::"text", ("budget_month")::timestamp with time zone))::"date" = "budget_month"))),
    CONSTRAINT "matrix_scenario_budgets_v2_check" CHECK (((("operation" = ANY (ARRAY['SET'::"text", 'ADD'::"text"])) AND ("amount_minor" IS NOT NULL) AND ("multiplier_basis_points" IS NULL)) OR (("operation" = 'MULTIPLY'::"text") AND ("multiplier_basis_points" IS NOT NULL) AND ("multiplier_basis_points" >= 0) AND ("amount_minor" IS NULL)) OR (("operation" = 'REMOVE'::"text") AND ("amount_minor" IS NULL) AND ("multiplier_basis_points" IS NULL)))),
    CONSTRAINT "matrix_scenario_budgets_v2_currency_check" CHECK ("public"."matrix_v2_is_iso_4217_currency"("currency")),
    CONSTRAINT "matrix_scenario_budgets_v2_operation_check" CHECK (("operation" = ANY (ARRAY['SET'::"text", 'ADD'::"text", 'MULTIPLY'::"text", 'REMOVE'::"text"]))),
    CONSTRAINT "matrix_scenario_budgets_v2_warning_percent_check" CHECK ((("warning_percent" >= 1) AND ("warning_percent" <= 100)))
);


ALTER TABLE "public"."matrix_scenario_budgets_v2" OWNER TO "postgres";

--
-- Name: matrix_scenario_pay_rule_overrides_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_scenario_pay_rule_overrides_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "scenario_id" "uuid" NOT NULL,
    "pay_rule_id" "uuid" NOT NULL,
    "enabled" boolean DEFAULT true NOT NULL,
    "amount_minor" bigint,
    "rate_minor_per_hour" bigint,
    "percent_basis_points" integer,
    "multiplier_basis_points" integer,
    "formula_expression" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "matrix_scenario_pay_rule_override_multiplier_basis_points_check" CHECK ((("multiplier_basis_points" IS NULL) OR ("multiplier_basis_points" >= 0))),
    CONSTRAINT "matrix_scenario_pay_rule_overrides_v2_amount_minor_check" CHECK ((("amount_minor" IS NULL) OR ("amount_minor" >= 0))),
    CONSTRAINT "matrix_scenario_pay_rule_overrides_v2_rate_minor_per_hour_check" CHECK ((("rate_minor_per_hour" IS NULL) OR ("rate_minor_per_hour" >= 0))),
    CONSTRAINT "matrix_scenario_pay_rule_overrides_v_percent_basis_points_check" CHECK ((("percent_basis_points" IS NULL) OR ("percent_basis_points" >= 0)))
);


ALTER TABLE "public"."matrix_scenario_pay_rule_overrides_v2" OWNER TO "postgres";

--
-- Name: matrix_scenario_strategies_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_scenario_strategies_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "scenario_id" "uuid" NOT NULL,
    "strategy_id" "uuid" NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "objective_overrides" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "solver_overrides" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."matrix_scenario_strategies_v2" OWNER TO "postgres";

--
-- Name: matrix_scenarios; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_scenarios" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "color" "text" DEFAULT '#7457e8'::"text" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."matrix_scenarios" OWNER TO "postgres";

--
-- Name: matrix_scenarios_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_scenarios_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "logical_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "parent_scenario_id" "uuid",
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "color" "text" DEFAULT '#7457e8'::"text" NOT NULL,
    "is_default" boolean DEFAULT false NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "valid_from" "date",
    "valid_to" "date",
    "settings_overrides" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "matrix_scenarios_v2_check" CHECK ((("valid_to" IS NULL) OR ("valid_from" IS NULL) OR ("valid_to" >= "valid_from"))),
    CONSTRAINT "matrix_scenarios_v2_code_check" CHECK ((("length"(TRIM(BOTH FROM "code")) >= 1) AND ("length"(TRIM(BOTH FROM "code")) <= 80))),
    CONSTRAINT "matrix_scenarios_v2_name_check" CHECK ((("length"(TRIM(BOTH FROM "name")) >= 1) AND ("length"(TRIM(BOTH FROM "name")) <= 160)))
);


ALTER TABLE "public"."matrix_scenarios_v2" OWNER TO "postgres";

--
-- Name: matrix_scope_grants_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_scope_grants_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "auth_user_id" "uuid" NOT NULL,
    "app_role" "public"."app_role" NOT NULL,
    "role_logical_id" "uuid",
    "location_logical_id" "uuid",
    "duty_logical_id" "uuid",
    "active" boolean DEFAULT true NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "matrix_scope_grants_v2_location_manager_requires_location" CHECK ((("app_role" <> 'LOCATION_MANAGER'::"public"."app_role") OR ("location_logical_id" IS NOT NULL))),
    CONSTRAINT "matrix_scope_grants_v2_role_manager_requires_role" CHECK ((("app_role" <> 'ROLE_MANAGER'::"public"."app_role") OR ("role_logical_id" IS NOT NULL)))
);


ALTER TABLE "public"."matrix_scope_grants_v2" OWNER TO "postgres";

--
-- Name: matrix_shift_templates; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_shift_templates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "location_id" "uuid" NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "starts_at" time without time zone NOT NULL,
    "ends_at" time without time zone NOT NULL,
    "day_mask" smallint[] DEFAULT ARRAY[(1)::smallint, (2)::smallint, (3)::smallint, (4)::smallint, (5)::smallint, (6)::smallint, (7)::smallint] NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "active" boolean DEFAULT true NOT NULL
);


ALTER TABLE "public"."matrix_shift_templates" OWNER TO "postgres";

--
-- Name: matrix_shift_templates_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_shift_templates_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "logical_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "location_id" "uuid" NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "starts_at" time without time zone NOT NULL,
    "ends_at" time without time zone NOT NULL,
    "ends_next_day" boolean DEFAULT false NOT NULL,
    "day_mask" smallint[] DEFAULT ARRAY[(1)::smallint, (2)::smallint, (3)::smallint, (4)::smallint, (5)::smallint, (6)::smallint, (7)::smallint] NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "shift_period" "text" DEFAULT 'MIDDLE'::"text" NOT NULL,
    "color" "text" DEFAULT '#879681'::"text" NOT NULL,
    CONSTRAINT "matrix_shift_templates_v2_code_check" CHECK ((("length"(TRIM(BOTH FROM "code")) >= 1) AND ("length"(TRIM(BOTH FROM "code")) <= 80))),
    CONSTRAINT "matrix_shift_templates_v2_color_hex_check" CHECK (("color" ~ '^#[0-9A-Fa-f]{6}$'::"text")),
    CONSTRAINT "matrix_shift_templates_v2_day_mask_check" CHECK ((("cardinality"("day_mask") >= 1) AND ("cardinality"("day_mask") <= 7))),
    CONSTRAINT "matrix_shift_templates_v2_day_mask_check1" CHECK (("day_mask" <@ ARRAY[(1)::smallint, (2)::smallint, (3)::smallint, (4)::smallint, (5)::smallint, (6)::smallint, (7)::smallint])),
    CONSTRAINT "matrix_shift_templates_v2_name_check" CHECK ((("length"(TRIM(BOTH FROM "name")) >= 1) AND ("length"(TRIM(BOTH FROM "name")) <= 160))),
    CONSTRAINT "matrix_shift_templates_v2_shift_period_check" CHECK (("shift_period" = ANY (ARRAY['MORNING'::"text", 'MIDDLE'::"text", 'EVENING'::"text"])))
);


ALTER TABLE "public"."matrix_shift_templates_v2" OWNER TO "postgres";

--
-- Name: COLUMN "matrix_shift_templates_v2"."color"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN "public"."matrix_shift_templates_v2"."color" IS 'B4F-118: versioned #RRGGBB marker shared by settings, exports and schedule UI.';


--
-- Name: matrix_staffing_rules_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_staffing_rules_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "scenario_id" "uuid" NOT NULL,
    "shift_template_id" "uuid" NOT NULL,
    "role_id" "uuid" NOT NULL,
    "duty_id" "uuid",
    "operation" "text" NOT NULL,
    "count_value" integer,
    "multiplier_basis_points" integer,
    "active" boolean DEFAULT true NOT NULL,
    "source_metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "matrix_staffing_rules_v2_check" CHECK (((("operation" = 'SET'::"text") AND ("count_value" IS NOT NULL) AND ("count_value" >= 0) AND ("multiplier_basis_points" IS NULL)) OR (("operation" = 'ADD'::"text") AND ("count_value" IS NOT NULL) AND ("multiplier_basis_points" IS NULL)) OR (("operation" = 'MULTIPLY'::"text") AND ("multiplier_basis_points" IS NOT NULL) AND ("multiplier_basis_points" >= 0) AND ("count_value" IS NULL)) OR (("operation" = 'REMOVE'::"text") AND ("count_value" IS NULL) AND ("multiplier_basis_points" IS NULL)))),
    CONSTRAINT "matrix_staffing_rules_v2_operation_check" CHECK (("operation" = ANY (ARRAY['SET'::"text", 'ADD'::"text", 'MULTIPLY'::"text", 'REMOVE'::"text"])))
);


ALTER TABLE "public"."matrix_staffing_rules_v2" OWNER TO "postgres";

--
-- Name: matrix_strategies_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_strategies_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "logical_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "legacy_optimizer_profile_id" "uuid",
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "solver_code" "text" DEFAULT 'CP_SAT'::"text" NOT NULL,
    "solver_options" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "legacy_weights" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "matrix_strategies_v2_code_check" CHECK ((("length"(TRIM(BOTH FROM "code")) >= 1) AND ("length"(TRIM(BOTH FROM "code")) <= 80))),
    CONSTRAINT "matrix_strategies_v2_name_check" CHECK ((("length"(TRIM(BOTH FROM "name")) >= 1) AND ("length"(TRIM(BOTH FROM "name")) <= 160)))
);


ALTER TABLE "public"."matrix_strategies_v2" OWNER TO "postgres";

--
-- Name: matrix_strategy_objectives_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_strategy_objectives_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "strategy_id" "uuid" NOT NULL,
    "tier" smallint NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "metric_code" "text" NOT NULL,
    "direction" "text" DEFAULT 'MINIMIZE'::"text" NOT NULL,
    "weight" bigint DEFAULT 1 NOT NULL,
    "tolerance" bigint DEFAULT 0 NOT NULL,
    "parameters" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "matrix_strategy_objectives_v2_direction_check" CHECK (("direction" = ANY (ARRAY['MINIMIZE'::"text", 'MAXIMIZE'::"text"]))),
    CONSTRAINT "matrix_strategy_objectives_v2_metric_code_check" CHECK ((("length"(TRIM(BOTH FROM "metric_code")) >= 1) AND ("length"(TRIM(BOTH FROM "metric_code")) <= 100))),
    CONSTRAINT "matrix_strategy_objectives_v2_tier_check" CHECK ((("tier" >= 1) AND ("tier" <= 100))),
    CONSTRAINT "matrix_strategy_objectives_v2_tolerance_check" CHECK (("tolerance" >= 0)),
    CONSTRAINT "matrix_strategy_objectives_v2_weight_check" CHECK (("weight" >= 0))
);


ALTER TABLE "public"."matrix_strategy_objectives_v2" OWNER TO "postgres";

--
-- Name: matrix_versions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."matrix_versions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "version" integer NOT NULL,
    "name" "text" NOT NULL,
    "status" "text" DEFAULT 'DRAFT'::"text" NOT NULL,
    "effective_from" "date" NOT NULL,
    "effective_to" "date",
    "settings" "jsonb" DEFAULT '{"maxShiftsPerDay": 7, "minimumRestMinutes": 660}'::"jsonb" NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "activated_at" timestamp with time zone,
    "schema_version" smallint DEFAULT 1 NOT NULL,
    "base_version_id" "uuid",
    "content_hash" "text",
    "workforce_hash" "text",
    "workforce_count" integer,
    "published_by" "uuid",
    "published_at" timestamp with time zone,
    CONSTRAINT "matrix_versions_check" CHECK ((("effective_to" IS NULL) OR ("effective_to" >= "effective_from"))),
    CONSTRAINT "matrix_versions_status_check" CHECK (("status" = ANY (ARRAY['DRAFT'::"text", 'ACTIVE'::"text", 'ARCHIVED'::"text"])))
);


ALTER TABLE "public"."matrix_versions" OWNER TO "postgres";

--
-- Name: TABLE "matrix_versions"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE "public"."matrix_versions" IS 'Legacy-compatible Matrix projection. Application writes are permitted only through Matrix v2 RPCs.';


--
-- Name: monthly_budget_lines_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."monthly_budget_lines_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "revision_id" "uuid" NOT NULL,
    "scope_type" "text" NOT NULL,
    "location_logical_id" "uuid",
    "category_logical_id" "uuid",
    "role_logical_id" "uuid",
    "metric_type" "text" NOT NULL,
    "enforcement" "text" NOT NULL,
    "limit_value" numeric(18,4) NOT NULL,
    "reference_value" numeric(18,4),
    "currency" "text",
    "cost_basis" "text",
    "distribution_mode" "text" DEFAULT 'MONTHLY'::"text" NOT NULL,
    "distribution" "jsonb",
    CONSTRAINT "monthly_budget_lines_v2_check" CHECK ((("scope_type" = ANY (ARRAY['LOCATION'::"text", 'LOCATION_CATEGORY'::"text"])) = ("location_logical_id" IS NOT NULL))),
    CONSTRAINT "monthly_budget_lines_v2_check1" CHECK ((("scope_type" = ANY (ARRAY['CATEGORY'::"text", 'LOCATION_CATEGORY'::"text"])) = ("category_logical_id" IS NOT NULL))),
    CONSTRAINT "monthly_budget_lines_v2_check2" CHECK ((("scope_type" = 'ROLE'::"text") = ("role_logical_id" IS NOT NULL))),
    CONSTRAINT "monthly_budget_lines_v2_check3" CHECK ((("metric_type" = 'COST'::"text") = ("currency" IS NOT NULL))),
    CONSTRAINT "monthly_budget_lines_v2_check4" CHECK ((("metric_type" <> 'LABOR_PERCENT'::"text") OR ("reference_value" IS NOT NULL) OR ("enforcement" = 'MONITORING'::"text"))),
    CONSTRAINT "monthly_budget_lines_v2_cost_basis_check" CHECK ((("cost_basis" IS NULL) OR ("cost_basis" = ANY (ARRAY['WAGES'::"text", 'FULL_EMPLOYER_COST'::"text"])))),
    CONSTRAINT "monthly_budget_lines_v2_currency_check" CHECK ((("currency" IS NULL) OR ("currency" ~ '^[A-Z]{3}$'::"text"))),
    CONSTRAINT "monthly_budget_lines_v2_distribution_mode_check" CHECK (("distribution_mode" = ANY (ARRAY['MONTHLY'::"text", 'AUTO'::"text", 'MANUAL'::"text"]))),
    CONSTRAINT "monthly_budget_lines_v2_enforcement_check" CHECK (("enforcement" = ANY (ARRAY['HARD'::"text", 'TARGET'::"text", 'MONITORING'::"text"]))),
    CONSTRAINT "monthly_budget_lines_v2_limit_value_check" CHECK (("limit_value" >= (0)::numeric)),
    CONSTRAINT "monthly_budget_lines_v2_metric_type_check" CHECK (("metric_type" = ANY (ARRAY['COST'::"text", 'HOURS'::"text", 'LABOR_PERCENT'::"text"]))),
    CONSTRAINT "monthly_budget_lines_v2_reference_value_check" CHECK ((("reference_value" IS NULL) OR ("reference_value" >= (0)::numeric))),
    CONSTRAINT "monthly_budget_lines_v2_scope_type_check" CHECK (("scope_type" = ANY (ARRAY['COMPANY'::"text", 'LOCATION'::"text", 'CATEGORY'::"text", 'LOCATION_CATEGORY'::"text", 'ROLE'::"text"])))
);


ALTER TABLE "public"."monthly_budget_lines_v2" OWNER TO "postgres";

--
-- Name: monthly_budget_revisions_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."monthly_budget_revisions_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "budget_month" "date" NOT NULL,
    "revision" integer NOT NULL,
    "status" "text" NOT NULL,
    "note" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "archived_at" timestamp with time zone,
    CONSTRAINT "monthly_budget_revisions_v2_budget_month_check" CHECK (("budget_month" = ("date_trunc"('month'::"text", ("budget_month")::timestamp with time zone))::"date")),
    CONSTRAINT "monthly_budget_revisions_v2_revision_check" CHECK (("revision" > 0)),
    CONSTRAINT "monthly_budget_revisions_v2_status_check" CHECK (("status" = ANY (ARRAY['ACTIVE'::"text", 'ARCHIVED'::"text"])))
);


ALTER TABLE "public"."monthly_budget_revisions_v2" OWNER TO "postgres";

--
-- Name: monthly_budgets; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."monthly_budgets" (
    "month" "date" NOT NULL,
    "amount" numeric(14,2) NOT NULL,
    "warning_percent" integer DEFAULT 90 NOT NULL,
    "hard_limit" boolean DEFAULT false NOT NULL,
    "updated_by" "uuid",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "monthly_budgets_amount_check" CHECK (("amount" >= (0)::numeric)),
    CONSTRAINT "monthly_budgets_month_check" CHECK ((("date_trunc"('month'::"text", ("month")::timestamp with time zone))::"date" = "month")),
    CONSTRAINT "monthly_budgets_warning_percent_check" CHECK ((("warning_percent" >= 1) AND ("warning_percent" <= 100)))
);


ALTER TABLE "public"."monthly_budgets" OWNER TO "postgres";

--
-- Name: notifications; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "recipient_id" "uuid" NOT NULL,
    "task_id" "uuid",
    "channel" "text" DEFAULT 'IN_APP'::"text" NOT NULL,
    "title" "text" NOT NULL,
    "body" "text" NOT NULL,
    "read_at" timestamp with time zone,
    "sent_at" timestamp with time zone,
    "retry_count" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "kind" "text" DEFAULT 'INFORMATION'::"text" NOT NULL,
    "context_type" "text",
    "context_id" "text",
    "action_route" "text",
    "action_required" boolean DEFAULT false NOT NULL,
    "resolved_at" timestamp with time zone,
    "resolution" "text",
    CONSTRAINT "notifications_kind_check" CHECK (("kind" = ANY (ARRAY['INFORMATION'::"text", 'ACTION_REQUIRED'::"text", 'DECISION'::"text", 'SCHEDULE_PUBLISHED'::"text", 'MESSAGE'::"text"])))
);


ALTER TABLE "public"."notifications" OWNER TO "postgres";

--
-- Name: operational_assignment_overrides_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."operational_assignment_overrides_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "schedule_id" "uuid" NOT NULL,
    "issue_id" bigint NOT NULL,
    "shift_id" "uuid" NOT NULL,
    "slot_key" "text" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "role_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'ACTIVE'::"text" NOT NULL,
    "assignment_class" "text" NOT NULL,
    "override_reason" "text",
    "notify_employee" boolean DEFAULT false NOT NULL,
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "revoked_by" "uuid",
    "revoked_at" timestamp with time zone,
    "revoke_reason" "text",
    CONSTRAINT "operational_assignment_overrides_v2_assignment_class_check" CHECK (("assignment_class" = ANY (ARRAY['ELIGIBLE'::"text", 'SOFT_OVERRIDE'::"text"]))),
    CONSTRAINT "operational_assignment_overrides_v2_check" CHECK (((("status" = 'ACTIVE'::"text") AND ("revoked_at" IS NULL) AND ("revoked_by" IS NULL)) OR (("status" = 'REVOKED'::"text") AND ("revoked_at" IS NOT NULL)))),
    CONSTRAINT "operational_assignment_overrides_v2_check1" CHECK ((("assignment_class" = 'ELIGIBLE'::"text") OR ("length"(TRIM(BOTH FROM COALESCE("override_reason", ''::"text"))) >= 3))),
    CONSTRAINT "operational_assignment_overrides_v2_status_check" CHECK (("status" = ANY (ARRAY['ACTIVE'::"text", 'REVOKED'::"text"])))
);


ALTER TABLE "public"."operational_assignment_overrides_v2" OWNER TO "postgres";

--
-- Name: TABLE "operational_assignment_overrides_v2"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE "public"."operational_assignment_overrides_v2" IS 'Mutable operational overlay; published solver variants remain immutable.';


--
-- Name: operational_assignment_replacements_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."operational_assignment_replacements_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "month" "date" NOT NULL,
    "original_assignment_id" "uuid" NOT NULL,
    "replacement_employee_id" "uuid" NOT NULL,
    "standby_assignment_id" "uuid",
    "status" "text" DEFAULT 'ACTIVE'::"text" NOT NULL,
    "reason" "text" NOT NULL,
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "revoked_by" "uuid",
    "revoked_at" timestamp with time zone,
    CONSTRAINT "operational_assignment_replacements_v2_month_check" CHECK ((("date_trunc"('month'::"text", ("month")::timestamp with time zone))::"date" = "month")),
    CONSTRAINT "operational_assignment_replacements_v2_reason_check" CHECK (("length"(TRIM(BOTH FROM "reason")) >= 3)),
    CONSTRAINT "operational_assignment_replacements_v2_status_check" CHECK (("status" = ANY (ARRAY['ACTIVE'::"text", 'REVOKED'::"text", 'SUPERSEDED'::"text"])))
);


ALTER TABLE "public"."operational_assignment_replacements_v2" OWNER TO "postgres";

--
-- Name: operational_events; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."operational_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "location_id" "uuid" NOT NULL,
    "event_type" "text" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "starts_at" timestamp with time zone NOT NULL,
    "ends_at" timestamp with time zone NOT NULL,
    "expected_guests" integer,
    "status" "public"."event_status" DEFAULT 'DRAFT'::"public"."event_status" NOT NULL,
    "verifier_user_id" "uuid",
    "verification_due_at" timestamp with time zone,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "operational_events_check" CHECK (("ends_at" > "starts_at")),
    CONSTRAINT "operational_events_event_type_check" CHECK (("event_type" = ANY (ARRAY['EVENT'::"text", 'CLEANING'::"text", 'INVENTORY'::"text", 'TRAINING'::"text", 'DELIVERY'::"text", 'ADDITIONAL_SHIFT'::"text", 'HOURS_CHANGE'::"text", 'CLOSURE'::"text", 'OTHER'::"text"]))),
    CONSTRAINT "operational_events_expected_guests_check" CHECK ((("expected_guests" IS NULL) OR ("expected_guests" >= 0)))
);


ALTER TABLE "public"."operational_events" OWNER TO "postgres";

--
-- Name: operational_program_audience_rules_v1; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."operational_program_audience_rules_v1" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "rule_mode" "text" NOT NULL,
    "scope_type" "text" NOT NULL,
    "scope_uuid" "uuid",
    "scope_code" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "operational_program_audience_rules_v1_check" CHECK ((("scope_uuid" IS NOT NULL) OR ("length"(TRIM(BOTH FROM COALESCE("scope_code", ''::"text"))) > 0))),
    CONSTRAINT "operational_program_audience_rules_v1_rule_mode_check" CHECK (("rule_mode" = ANY (ARRAY['INCLUDE'::"text", 'EXCLUDE'::"text"]))),
    CONSTRAINT "operational_program_audience_rules_v1_scope_type_check" CHECK (("scope_type" = ANY (ARRAY['ALL_ACTIVE'::"text", 'CATEGORY'::"text", 'ROLE'::"text", 'APP_ROLE'::"text", 'EMPLOYEE'::"text", 'LOCATION'::"text"])))
);


ALTER TABLE "public"."operational_program_audience_rules_v1" OWNER TO "postgres";

--
-- Name: operational_program_audit_v1; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."operational_program_audit_v1" (
    "id" bigint NOT NULL,
    "event_id" "uuid",
    "actor_id" "uuid",
    "action" "text" NOT NULL,
    "detail" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."operational_program_audit_v1" OWNER TO "postgres";

--
-- Name: operational_program_audit_v1_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE "public"."operational_program_audit_v1" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."operational_program_audit_v1_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: operational_program_checklist_items_v1; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."operational_program_checklist_items_v1" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "item_order" integer DEFAULT 0 NOT NULL,
    "label" "text" NOT NULL,
    "visibility" "text" DEFAULT 'ALL'::"text" NOT NULL,
    "visible_to" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "completed" boolean DEFAULT false NOT NULL,
    "completed_by" "uuid",
    "completed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "operational_program_checklist_items_v1_label_check" CHECK ((("length"(TRIM(BOTH FROM "label")) >= 2) AND ("length"(TRIM(BOTH FROM "label")) <= 240))),
    CONSTRAINT "operational_program_checklist_items_v1_visibility_check" CHECK (("visibility" = ANY (ARRAY['ORGANIZER'::"text", 'ALL'::"text", 'SELECTED'::"text"])))
);


ALTER TABLE "public"."operational_program_checklist_items_v1" OWNER TO "postgres";

--
-- Name: operational_program_events_v1; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."operational_program_events_v1" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_type" "text" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "location_id" "uuid",
    "starts_at" timestamp with time zone NOT NULL,
    "ends_at" timestamp with time zone NOT NULL,
    "status" "text" DEFAULT 'DRAFT'::"text" NOT NULL,
    "audience_mode" "text" DEFAULT 'NEED_COUNT'::"text" NOT NULL,
    "required_count" integer,
    "inventory_type" "text",
    "inventory_groups" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "private_note" "text",
    "published_note" "text",
    "agenda" "text",
    "version_no" integer DEFAULT 1 NOT NULL,
    "parent_event_id" "uuid",
    "cancellation_reason" "text",
    "created_by" "uuid" NOT NULL,
    "published_by" "uuid",
    "published_at" timestamp with time zone,
    "cancelled_by" "uuid",
    "cancelled_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "operational_program_events_v1_audience_mode_check" CHECK (("audience_mode" = ANY (ARRAY['ALL_SCOPE'::"text", 'SELECTED'::"text", 'NEED_COUNT'::"text"]))),
    CONSTRAINT "operational_program_events_v1_check" CHECK (("ends_at" > "starts_at")),
    CONSTRAINT "operational_program_events_v1_check1" CHECK ((("event_type" = 'INVENTORY'::"text") OR ("inventory_type" IS NULL))),
    CONSTRAINT "operational_program_events_v1_check2" CHECK ((("audience_mode" <> 'NEED_COUNT'::"text") OR ("required_count" IS NOT NULL))),
    CONSTRAINT "operational_program_events_v1_check3" CHECK (((("status" = 'PUBLISHED'::"text") AND ("published_at" IS NOT NULL)) OR ("status" <> 'PUBLISHED'::"text"))),
    CONSTRAINT "operational_program_events_v1_check4" CHECK (((("status" = 'CANCELLED'::"text") AND ("cancelled_at" IS NOT NULL) AND ("length"(TRIM(BOTH FROM "cancellation_reason")) >= 3)) OR ("status" <> 'CANCELLED'::"text"))),
    CONSTRAINT "operational_program_events_v1_event_type_check" CHECK (("event_type" = ANY (ARRAY['MEETING'::"text", 'CLEANING'::"text", 'INVENTORY'::"text", 'TRAINING'::"text", 'ONBOARDING'::"text", 'OTHER'::"text"]))),
    CONSTRAINT "operational_program_events_v1_inventory_type_check" CHECK (("inventory_type" = ANY (ARRAY['FULL'::"text", 'PARTIAL'::"text", 'CONTROL'::"text", 'SELECTED_GROUPS'::"text"]))),
    CONSTRAINT "operational_program_events_v1_required_count_check" CHECK ((("required_count" >= 1) AND ("required_count" <= 500))),
    CONSTRAINT "operational_program_events_v1_status_check" CHECK (("status" = ANY (ARRAY['DRAFT'::"text", 'ANALYSIS'::"text", 'PUBLISHED'::"text", 'COMPLETED'::"text", 'CANCELLED'::"text"]))),
    CONSTRAINT "operational_program_events_v1_title_check" CHECK ((("length"(TRIM(BOTH FROM "title")) >= 2) AND ("length"(TRIM(BOTH FROM "title")) <= 180))),
    CONSTRAINT "operational_program_events_v1_version_no_check" CHECK (("version_no" > 0))
);


ALTER TABLE "public"."operational_program_events_v1" OWNER TO "postgres";

--
-- Name: TABLE "operational_program_events_v1"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE "public"."operational_program_events_v1" IS 'Versioned operational events planned after schedule publication; GRAFIK PRO is the source of people, time and notifications.';


--
-- Name: operational_program_inventory_links_v1; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."operational_program_inventory_links_v1" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "integration_id" "uuid" NOT NULL,
    "external_session_id" "text",
    "external_session_url" "text",
    "sync_status" "text" DEFAULT 'WAITING_CONFIGURATION'::"text" NOT NULL,
    "payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "payload_hash" "text" NOT NULL,
    "attempt_count" integer DEFAULT 0 NOT NULL,
    "last_error" "text",
    "last_attempt_at" timestamp with time zone,
    "synced_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "operational_program_inventory_links_v1_attempt_count_check" CHECK (("attempt_count" >= 0)),
    CONSTRAINT "operational_program_inventory_links_v1_sync_status_check" CHECK (("sync_status" = ANY (ARRAY['WAITING_CONFIGURATION'::"text", 'QUEUED'::"text", 'READY'::"text", 'ERROR'::"text", 'CANCELLED'::"text", 'COMPLETED'::"text"])))
);


ALTER TABLE "public"."operational_program_inventory_links_v1" OWNER TO "postgres";

--
-- Name: TABLE "operational_program_inventory_links_v1"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE "public"."operational_program_inventory_links_v1" IS 'Idempotent INVETORY PRO integration outbox and deep-link state; stock results remain owned by INVETORY PRO.';


--
-- Name: operational_program_participants_v1; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."operational_program_participants_v1" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "employee_id" "uuid",
    "auth_user_id" "uuid",
    "selection_source" "text" DEFAULT 'MANAGER'::"text" NOT NULL,
    "candidate_status" "text" DEFAULT 'SAFE'::"text" NOT NULL,
    "reasons" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "assignment_status" "text" DEFAULT 'CONFIRMED'::"text" NOT NULL,
    "override_reason" "text",
    "acknowledged_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "operational_program_participants_v1_assignment_status_check" CHECK (("assignment_status" = ANY (ARRAY['PROPOSED'::"text", 'INVITED'::"text", 'CONFIRMED'::"text", 'DECLINED'::"text", 'CANCELLED'::"text", 'ATTENDED'::"text", 'ABSENT'::"text"]))),
    CONSTRAINT "operational_program_participants_v1_candidate_status_check" CHECK (("candidate_status" = ANY (ARRAY['SAFE'::"text", 'WARNING'::"text", 'BLOCKED'::"text"]))),
    CONSTRAINT "operational_program_participants_v1_check" CHECK ((("employee_id" IS NOT NULL) OR ("auth_user_id" IS NOT NULL))),
    CONSTRAINT "operational_program_participants_v1_selection_source_check" CHECK (("selection_source" = ANY (ARRAY['SCOPE'::"text", 'SUGGESTION'::"text", 'MANAGER'::"text", 'INVITATION'::"text"])))
);


ALTER TABLE "public"."operational_program_participants_v1" OWNER TO "postgres";

--
-- Name: optimization_candidates; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."optimization_candidates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "run_id" "uuid" NOT NULL,
    "rank" integer NOT NULL,
    "score" numeric NOT NULL,
    "hard_violations" integer DEFAULT 0 NOT NULL,
    "metrics" "jsonb" NOT NULL,
    "assignments" "jsonb" NOT NULL,
    "selected" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "plan_id" "uuid",
    CONSTRAINT "optimization_candidates_rank_check" CHECK (("rank" > 0))
);


ALTER TABLE "public"."optimization_candidates" OWNER TO "postgres";

--
-- Name: optimization_run_strategies_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."optimization_run_strategies_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "run_id" "uuid" NOT NULL,
    "strategy_id" "uuid" NOT NULL,
    "ordinal" integer NOT NULL,
    "status" "text" DEFAULT 'QUEUED'::"text" NOT NULL,
    "phase" "text" DEFAULT 'QUEUED'::"text" NOT NULL,
    "progress" smallint DEFAULT 0 NOT NULL,
    "metrics" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "failure_code" "text",
    "started_at" timestamp with time zone,
    "finished_at" timestamp with time zone,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "optimization_run_strategies_v2_ordinal_check" CHECK (("ordinal" > 0)),
    CONSTRAINT "optimization_run_strategies_v2_progress_check" CHECK ((("progress" >= 0) AND ("progress" <= 100))),
    CONSTRAINT "optimization_run_strategies_v2_status_check" CHECK (("status" = ANY (ARRAY['QUEUED'::"text", 'RUNNING'::"text", 'VALIDATING'::"text", 'READY'::"text", 'CANCELLED'::"text", 'FAILED'::"text", 'STALE_INPUT'::"text"])))
);


ALTER TABLE "public"."optimization_run_strategies_v2" OWNER TO "postgres";

--
-- Name: optimization_runs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."optimization_runs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "month" "date" NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "profile_id" "uuid" NOT NULL,
    "scenario_code" "text" DEFAULT 'BASE'::"text" NOT NULL,
    "status" "text" DEFAULT 'QUEUED'::"text" NOT NULL,
    "seed" integer NOT NULL,
    "requested_by" "uuid" NOT NULL,
    "started_at" timestamp with time zone,
    "finished_at" timestamp with time zone,
    "input_snapshot" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "result_summary" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "failure_message" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "input_payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "checkpoint" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "current_generation" integer DEFAULT 0 NOT NULL,
    "target_generations" integer DEFAULT 40 NOT NULL,
    "heartbeat_at" timestamp with time zone,
    CONSTRAINT "optimization_runs_month_check" CHECK ((("date_trunc"('month'::"text", ("month")::timestamp with time zone))::"date" = "month")),
    CONSTRAINT "optimization_runs_status_check" CHECK (("status" = ANY (ARRAY['QUEUED'::"text", 'RUNNING'::"text", 'SUCCEEDED'::"text", 'INFEASIBLE'::"text", 'FAILED'::"text"])))
);


ALTER TABLE "public"."optimization_runs" OWNER TO "postgres";

--
-- Name: optimization_runs_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."optimization_runs_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "idempotency_key" "text" NOT NULL,
    "month" "date" NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "scenario_id" "uuid" NOT NULL,
    "scope_type" "text" DEFAULT 'COMPANY'::"text" NOT NULL,
    "scope_role_id" "uuid",
    "name" "text" NOT NULL,
    "status" "text" DEFAULT 'QUEUED'::"text" NOT NULL,
    "phase" "text" DEFAULT 'QUEUED'::"text" NOT NULL,
    "progress" smallint DEFAULT 0 NOT NULL,
    "requested_by" "uuid" NOT NULL,
    "snapshot_schema_version" integer DEFAULT 2 NOT NULL,
    "snapshot_hash" "text" NOT NULL,
    "solver_version" "text" NOT NULL,
    "request_engine" "text" NOT NULL,
    "attempt_count" integer DEFAULT 0 NOT NULL,
    "max_attempts" integer DEFAULT 3 NOT NULL,
    "queue_message_id" bigint,
    "lease_owner" "text",
    "lease_token" "uuid",
    "lease_expires_at" timestamp with time zone,
    "worker_execution_name" "text",
    "heartbeat_at" timestamp with time zone,
    "cancel_requested_at" timestamp with time zone,
    "failure_code" "text",
    "failure_message" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "queued_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "started_at" timestamp with time zone,
    "finished_at" timestamp with time zone,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "version_stamp" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    CONSTRAINT "optimization_runs_v2_attempt_count_check" CHECK (("attempt_count" >= 0)),
    CONSTRAINT "optimization_runs_v2_check" CHECK ((("scope_type" = 'ROLE'::"text") = ("scope_role_id" IS NOT NULL))),
    CONSTRAINT "optimization_runs_v2_check1" CHECK (((("lease_owner" IS NULL) AND ("lease_token" IS NULL) AND ("lease_expires_at" IS NULL)) OR (("lease_owner" IS NOT NULL) AND ("lease_token" IS NOT NULL) AND ("lease_expires_at" IS NOT NULL)))),
    CONSTRAINT "optimization_runs_v2_idempotency_key_check" CHECK ((("length"("idempotency_key") >= 8) AND ("length"("idempotency_key") <= 200))),
    CONSTRAINT "optimization_runs_v2_max_attempts_check" CHECK ((("max_attempts" >= 1) AND ("max_attempts" <= 20))),
    CONSTRAINT "optimization_runs_v2_month_check" CHECK ((("date_trunc"('month'::"text", ("month")::timestamp with time zone))::"date" = "month")),
    CONSTRAINT "optimization_runs_v2_progress_check" CHECK ((("progress" >= 0) AND ("progress" <= 100))),
    CONSTRAINT "optimization_runs_v2_request_engine_check" CHECK (("request_engine" = ANY (ARRAY['SHADOW'::"text", 'ORTOOLS_V2'::"text"]))),
    CONSTRAINT "optimization_runs_v2_scope_type_check" CHECK (("scope_type" = ANY (ARRAY['COMPANY'::"text", 'ROLE'::"text"]))),
    CONSTRAINT "optimization_runs_v2_snapshot_hash_check" CHECK (("snapshot_hash" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "optimization_runs_v2_snapshot_schema_version_check" CHECK (("snapshot_schema_version" > 0)),
    CONSTRAINT "optimization_runs_v2_solver_version_check" CHECK ((("length"("solver_version") >= 1) AND ("length"("solver_version") <= 200))),
    CONSTRAINT "optimization_runs_v2_status_check" CHECK (("status" = ANY (ARRAY['QUEUED'::"text", 'RUNNING'::"text", 'VALIDATING'::"text", 'READY'::"text", 'CANCEL_REQUESTED'::"text", 'CANCELLED'::"text", 'FAILED'::"text", 'STALE_INPUT'::"text"]))),
    CONSTRAINT "optimization_runs_v2_version_stamp_object_b4f166" CHECK (("jsonb_typeof"("version_stamp") = 'object'::"text"))
);


ALTER TABLE "public"."optimization_runs_v2" OWNER TO "postgres";

--
-- Name: TABLE "optimization_runs_v2"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE "public"."optimization_runs_v2" IS 'Sanitized run status projection. Snapshot and pay data live in solver_private.';


--
-- Name: COLUMN "optimization_runs_v2"."version_stamp"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN "public"."optimization_runs_v2"."version_stamp" IS 'B4F-166 immutable runtime component identity for a solver run.';


--
-- Name: optimizer_profiles; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."optimizer_profiles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "weights" "jsonb" DEFAULT '{"cost": 1, "nominal": 30, "fairness": 40, "overtime": 250, "shortage": 1000000, "capability": 1000000, "preference": 80, "homeLocation": 15, "weekendFairness": 25}'::"jsonb" NOT NULL,
    "population_size" integer DEFAULT 32 NOT NULL,
    "generations" integer DEFAULT 40 NOT NULL,
    "elite_count" integer DEFAULT 6 NOT NULL,
    "mutation_rate" numeric DEFAULT 0.08 NOT NULL,
    "alternatives_count" integer DEFAULT 3 NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    CONSTRAINT "optimizer_profiles_alternatives_count_check" CHECK ((("alternatives_count" >= 1) AND ("alternatives_count" <= 10))),
    CONSTRAINT "optimizer_profiles_elite_count_check" CHECK ((("elite_count" >= 1) AND ("elite_count" <= 64))),
    CONSTRAINT "optimizer_profiles_generations_check" CHECK ((("generations" >= 1) AND ("generations" <= 500))),
    CONSTRAINT "optimizer_profiles_mutation_rate_check" CHECK ((("mutation_rate" >= (0)::numeric) AND ("mutation_rate" <= (1)::numeric))),
    CONSTRAINT "optimizer_profiles_population_size_check" CHECK ((("population_size" >= 8) AND ("population_size" <= 256)))
);


ALTER TABLE "public"."optimizer_profiles" OWNER TO "postgres";

--
-- Name: plan_assignment_duties_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."plan_assignment_duties_v2" (
    "assignment_id" "uuid" NOT NULL,
    "duty_id" "uuid" NOT NULL
);


ALTER TABLE "public"."plan_assignment_duties_v2" OWNER TO "postgres";

--
-- Name: plan_assignments_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."plan_assignments_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "variant_id" "uuid" NOT NULL,
    "shift_id" "uuid" NOT NULL,
    "slot_key" "text" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "role_id" "uuid" NOT NULL,
    "locked" boolean DEFAULT false NOT NULL,
    "explanation" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."plan_assignments_v2" OWNER TO "postgres";

--
-- Name: plan_issues; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."plan_issues" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "plan_id" "uuid" NOT NULL,
    "shift_id" "uuid",
    "issue_type" "text" NOT NULL,
    "severity" "text" NOT NULL,
    "role" "public"."employee_role",
    "capability" "text",
    "required_count" integer,
    "assigned_count" integer,
    "message" "text" NOT NULL,
    "resolved_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "plan_issues_issue_type_check" CHECK (("issue_type" = ANY (ARRAY['SHORTAGE'::"text", 'CAPABILITY_MISSING'::"text", 'BUDGET_EXCEEDED'::"text", 'NO_MANAGER'::"text", 'OVERTIME_RISK'::"text", 'DATA_WARNING'::"text"]))),
    CONSTRAINT "plan_issues_severity_check" CHECK (("severity" = ANY (ARRAY['INFO'::"text", 'WARNING'::"text", 'CRITICAL'::"text"])))
);


ALTER TABLE "public"."plan_issues" OWNER TO "postgres";

--
-- Name: plan_issues_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."plan_issues_v2" (
    "id" bigint NOT NULL,
    "variant_id" "uuid" NOT NULL,
    "shift_id" "uuid",
    "slot_key" "text",
    "issue_code" "text" NOT NULL,
    "severity" "text" NOT NULL,
    "role_id" "uuid",
    "duty_id" "uuid",
    "required_count" integer,
    "assigned_count" integer,
    "message" "text" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "plan_issues_v2_severity_check" CHECK (("severity" = ANY (ARRAY['INFO'::"text", 'WARNING'::"text", 'CRITICAL'::"text"])))
);


ALTER TABLE "public"."plan_issues_v2" OWNER TO "postgres";

--
-- Name: plan_issues_v2_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE "public"."plan_issues_v2" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."plan_issues_v2_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: plan_shifts_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."plan_shifts_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "variant_id" "uuid" NOT NULL,
    "slot_group_key" "text" NOT NULL,
    "shift_template_id" "uuid" NOT NULL,
    "location_id" "uuid" NOT NULL,
    "shift_date" "date" NOT NULL,
    "starts_at" timestamp with time zone NOT NULL,
    "ends_at" timestamp with time zone NOT NULL,
    "source_type" "text" DEFAULT 'MATRIX'::"text" NOT NULL,
    "source_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "plan_shifts_v2_check" CHECK (("ends_at" > "starts_at"))
);


ALTER TABLE "public"."plan_shifts_v2" OWNER TO "postgres";

--
-- Name: plan_variants_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."plan_variants_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "run_id" "uuid" NOT NULL,
    "run_strategy_id" "uuid" NOT NULL,
    "strategy_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "status" "text" DEFAULT 'READY'::"text" NOT NULL,
    "hard_violations" integer DEFAULT 0 NOT NULL,
    "assignment_count" integer DEFAULT 0 NOT NULL,
    "unfilled_count" integer DEFAULT 0 NOT NULL,
    "solver_status" "text" NOT NULL,
    "solution_hash" "text" NOT NULL,
    "objective_bound" bigint,
    "metrics" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "recommended" boolean DEFAULT false NOT NULL,
    "selected" boolean DEFAULT false NOT NULL,
    "equivalent_to_variant_id" "uuid",
    "snapshot_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "selected_at" timestamp with time zone,
    "selected_by" "uuid",
    "published_at" timestamp with time zone,
    "variant_kind" "text" DEFAULT 'GENERATED'::"text" NOT NULL,
    "source_variant_id" "uuid",
    "revision" integer DEFAULT 0 NOT NULL,
    "last_edited_at" timestamp with time zone,
    "last_edited_by" "uuid",
    "leader_workflow_status" "text" DEFAULT 'DRAFT'::"text" NOT NULL,
    "stage_proof" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "version_stamp" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    CONSTRAINT "plan_variants_v2_assignment_count_check" CHECK (("assignment_count" >= 0)),
    CONSTRAINT "plan_variants_v2_hard_violations_check" CHECK (("hard_violations" >= 0)),
    CONSTRAINT "plan_variants_v2_leader_workflow_status_check" CHECK (("leader_workflow_status" = ANY (ARRAY['DRAFT'::"text", 'REVIEW'::"text", 'LEADER_APPROVED'::"text", 'READY_TO_MERGE'::"text", 'PUBLISHED'::"text"]))),
    CONSTRAINT "plan_variants_v2_snapshot_hash_check" CHECK (("snapshot_hash" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "plan_variants_v2_solution_hash_check" CHECK (("solution_hash" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "plan_variants_v2_solver_status_check" CHECK (("solver_status" = ANY (ARRAY['OPTIMAL'::"text", 'FEASIBLE'::"text"]))),
    CONSTRAINT "plan_variants_v2_stage_proof_array_b4f166" CHECK (("jsonb_typeof"("stage_proof") = 'array'::"text")),
    CONSTRAINT "plan_variants_v2_status_check" CHECK (("status" = ANY (ARRAY['READY'::"text", 'SELECTED'::"text", 'PUBLISHED'::"text", 'ARCHIVED'::"text"]))),
    CONSTRAINT "plan_variants_v2_unfilled_count_check" CHECK (("unfilled_count" >= 0)),
    CONSTRAINT "plan_variants_v2_variant_kind_check" CHECK (("variant_kind" = ANY (ARRAY['GENERATED'::"text", 'LEADER_COPY'::"text"]))),
    CONSTRAINT "plan_variants_v2_version_stamp_object_b4f166" CHECK (("jsonb_typeof"("version_stamp") = 'object'::"text"))
);


ALTER TABLE "public"."plan_variants_v2" OWNER TO "postgres";

--
-- Name: COLUMN "plan_variants_v2"."variant_kind"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN "public"."plan_variants_v2"."variant_kind" IS 'GENERATED proposals are immutable; LEADER_COPY is an independently validated pre-publication working copy.';


--
-- Name: COLUMN "plan_variants_v2"."stage_proof"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN "public"."plan_variants_v2"."stage_proof" IS 'B4F-166 ordered CP-SAT stage proof: status, value, frozen bound, tolerance, budget, elapsed and fallback.';


--
-- Name: COLUMN "plan_variants_v2"."version_stamp"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN "public"."plan_variants_v2"."version_stamp" IS 'B4F-166 frontend, solver, gateway, database, Matrix strategy and snapshot identity used by this variant.';


--
-- Name: plans; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."plans" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "month" "date" NOT NULL,
    "name" "text" NOT NULL,
    "scenario_code" "text" NOT NULL,
    "optimization_mode" "text" NOT NULL,
    "staffing_level" "text" NOT NULL,
    "status" "public"."plan_status" DEFAULT 'DRAFT'::"public"."plan_status" NOT NULL,
    "version" integer DEFAULT 1 NOT NULL,
    "parent_plan_id" "uuid",
    "score" numeric(7,2),
    "total_cost" numeric(14,2),
    "generated_at" timestamp with time zone,
    "published_at" timestamp with time zone,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "plans_month_check" CHECK ((("date_trunc"('month'::"text", ("month")::timestamp with time zone))::"date" = "month"))
);


ALTER TABLE "public"."plans" OWNER TO "postgres";

--
-- Name: published_role_schedules_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."published_role_schedules_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "idempotency_key" "text" NOT NULL,
    "month" "date" NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "scenario_id" "uuid" NOT NULL,
    "role_id" "uuid" NOT NULL,
    "variant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "status" "text" DEFAULT 'PUBLISHED'::"text" NOT NULL,
    "publication_hash" "text" NOT NULL,
    "created_by" "uuid" NOT NULL,
    "published_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "archived_at" timestamp with time zone,
    "archived_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "published_role_schedules_v2_check" CHECK (((("status" = 'PUBLISHED'::"text") AND ("archived_at" IS NULL) AND ("archived_by" IS NULL)) OR (("status" = 'ARCHIVED'::"text") AND ("archived_at" IS NOT NULL)))),
    CONSTRAINT "published_role_schedules_v2_idempotency_key_check" CHECK ((("length"("idempotency_key") >= 8) AND ("length"("idempotency_key") <= 200))),
    CONSTRAINT "published_role_schedules_v2_month_check" CHECK (("month" = ("date_trunc"('month'::"text", ("month")::timestamp with time zone))::"date")),
    CONSTRAINT "published_role_schedules_v2_name_check" CHECK ((("length"(TRIM(BOTH FROM "name")) >= 1) AND ("length"(TRIM(BOTH FROM "name")) <= 200))),
    CONSTRAINT "published_role_schedules_v2_publication_hash_check" CHECK (("publication_hash" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "published_role_schedules_v2_status_check" CHECK (("status" = ANY (ARRAY['PUBLISHED'::"text", 'ARCHIVED'::"text"])))
);


ALTER TABLE "public"."published_role_schedules_v2" OWNER TO "postgres";

--
-- Name: published_schedule_variants_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."published_schedule_variants_v2" (
    "schedule_id" "uuid" NOT NULL,
    "variant_id" "uuid" NOT NULL,
    "role_id" "uuid",
    "ordinal" integer NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "published_schedule_variants_v2_ordinal_check" CHECK (("ordinal" > 0))
);


ALTER TABLE "public"."published_schedule_variants_v2" OWNER TO "postgres";

--
-- Name: TABLE "published_schedule_variants_v2"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE "public"."published_schedule_variants_v2" IS 'Exact solver variants composing a published Matrix v2 schedule; dynamic role IDs remain native.';


--
-- Name: published_schedules_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."published_schedules_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "idempotency_key" "text" NOT NULL,
    "month" "date" NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "scenario_id" "uuid" NOT NULL,
    "source_type" "text" NOT NULL,
    "name" "text" NOT NULL,
    "status" "text" DEFAULT 'PUBLISHED'::"text" NOT NULL,
    "publication_hash" "text" NOT NULL,
    "validation_snapshot_hash" "text" NOT NULL,
    "validation_summary" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_by" "uuid" NOT NULL,
    "published_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "archived_at" timestamp with time zone,
    "archived_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "published_schedules_v2_check" CHECK (((("status" = 'PUBLISHED'::"text") AND ("archived_at" IS NULL) AND ("archived_by" IS NULL)) OR (("status" = 'ARCHIVED'::"text") AND ("archived_at" IS NOT NULL)))),
    CONSTRAINT "published_schedules_v2_idempotency_key_check" CHECK ((("length"("idempotency_key") >= 8) AND ("length"("idempotency_key") <= 200))),
    CONSTRAINT "published_schedules_v2_month_check" CHECK ((("date_trunc"('month'::"text", ("month")::timestamp with time zone))::"date" = "month")),
    CONSTRAINT "published_schedules_v2_name_check" CHECK ((("length"(TRIM(BOTH FROM "name")) >= 1) AND ("length"(TRIM(BOTH FROM "name")) <= 200))),
    CONSTRAINT "published_schedules_v2_publication_hash_check" CHECK (("publication_hash" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "published_schedules_v2_source_type_check" CHECK (("source_type" = ANY (ARRAY['COMPANY'::"text", 'ROLE_COMPOSITE'::"text"]))),
    CONSTRAINT "published_schedules_v2_status_check" CHECK (("status" = ANY (ARRAY['PUBLISHED'::"text", 'ARCHIVED'::"text"]))),
    CONSTRAINT "published_schedules_v2_validation_snapshot_hash_check" CHECK (("validation_snapshot_hash" ~ '^[0-9a-f]{64}$'::"text"))
);


ALTER TABLE "public"."published_schedules_v2" OWNER TO "postgres";

--
-- Name: TABLE "published_schedules_v2"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE "public"."published_schedules_v2" IS 'Immutable authoritative schedule headers; mutations advance the global planning-data revision.';


--
-- Name: published_standby_assignments_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."published_standby_assignments_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "month" "date" NOT NULL,
    "standby_date" "date" NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "role_id" "uuid" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "tier" smallint NOT NULL,
    "source_variant_id" "uuid" NOT NULL,
    "source_schedule_id" "uuid",
    "source_role_schedule_id" "uuid",
    "status" "text" DEFAULT 'PLANNED'::"text" NOT NULL,
    "activated_shift_id" "uuid",
    "activated_assignment_id" "uuid",
    "activated_at" timestamp with time zone,
    "activated_by" "uuid",
    "activation_reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid",
    "standby_group_code" "text",
    "standby_group_name" "text",
    "standby_category_code" "text",
    "eligible_role_ids" "uuid"[],
    CONSTRAINT "published_standby_assignments_v2_check" CHECK ((("standby_date" >= "month") AND ("standby_date" < (("month" + '1 mon'::interval))::"date"))),
    CONSTRAINT "published_standby_assignments_v2_check1" CHECK ((("source_schedule_id" IS NULL) <> ("source_role_schedule_id" IS NULL))),
    CONSTRAINT "published_standby_assignments_v2_check2" CHECK ((("status" = 'ACTIVATED'::"text") = ("activated_at" IS NOT NULL))),
    CONSTRAINT "published_standby_assignments_v2_month_check" CHECK ((("date_trunc"('month'::"text", ("month")::timestamp with time zone))::"date" = "month")),
    CONSTRAINT "published_standby_assignments_v2_status_check" CHECK (("status" = ANY (ARRAY['PLANNED'::"text", 'ACTIVATED'::"text", 'DECLINED'::"text", 'CANCELLED'::"text", 'SUPERSEDED'::"text"]))),
    CONSTRAINT "published_standby_assignments_v2_tier_check" CHECK (("tier" = ANY (ARRAY[1, 2])))
);


ALTER TABLE "public"."published_standby_assignments_v2" OWNER TO "postgres";

--
-- Name: TABLE "published_standby_assignments_v2"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE "public"."published_standby_assignments_v2" IS 'Daily Tier 1/Tier 2 role readiness; not ordinary worked time until activation.';


--
-- Name: recovery_actions_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."recovery_actions_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "incident_id" "uuid" NOT NULL,
    "shift_id" "uuid",
    "source_assignment_id" "uuid",
    "source_issue_id" bigint,
    "draft_variant_id" "uuid",
    "role_id" "uuid",
    "duty_id" "uuid",
    "action_type" "text" NOT NULL,
    "status" "text" DEFAULT 'PROPOSED'::"text" NOT NULL,
    "selected_employee_id" "uuid",
    "candidate_snapshot" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "risk_level" "text" DEFAULT 'LOW'::"text" NOT NULL,
    "rule_warnings" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "estimated_cost_delta_minor" bigint,
    "currency" "text",
    "version" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "recovery_actions_v2_action_type_check" CHECK (("action_type" = ANY (ARRAY['REPLACE_ASSIGNMENT'::"text", 'FILL_SHORTAGE'::"text", 'ACTIVATE_STANDBY'::"text", 'SPLIT_SHIFT'::"text", 'MOVE_LOCATION'::"text", 'REDUCE_STAFFING'::"text", 'SHORTEN_HOURS'::"text", 'AD_HOC_ASSIGNMENT'::"text"]))),
    CONSTRAINT "recovery_actions_v2_risk_level_check" CHECK (("risk_level" = ANY (ARRAY['LOW'::"text", 'MEDIUM'::"text", 'HIGH'::"text", 'CRITICAL'::"text"]))),
    CONSTRAINT "recovery_actions_v2_status_check" CHECK (("status" = ANY (ARRAY['PROPOSED'::"text", 'OFFERED'::"text", 'ACCEPTED'::"text", 'REJECTED'::"text", 'DRAFT_READY'::"text", 'APPLIED'::"text", 'CANCELLED'::"text"])))
);


ALTER TABLE "public"."recovery_actions_v2" OWNER TO "postgres";

--
-- Name: recovery_ad_hoc_pool_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."recovery_ad_hoc_pool_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "employee_id" "uuid",
    "display_name" "text" NOT NULL,
    "email" "text",
    "phone" "text",
    "role_id" "uuid" NOT NULL,
    "contract_type" "text" DEFAULT 'ZLECENIE'::"text" NOT NULL,
    "base_rate_minor" bigint,
    "currency" "text" DEFAULT 'PLN'::"text" NOT NULL,
    "available_from" "date",
    "available_to" "date",
    "active" boolean DEFAULT true NOT NULL,
    "notes" "text",
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "recovery_ad_hoc_pool_v2_check" CHECK ((("available_to" IS NULL) OR ("available_from" IS NULL) OR ("available_to" >= "available_from"))),
    CONSTRAINT "recovery_ad_hoc_pool_v2_contract_type_check" CHECK (("contract_type" = ANY (ARRAY['UMOWA_O_PRACE'::"text", 'CZESC_ETATU'::"text", 'ZLECENIE'::"text", 'B2B'::"text", 'INNE'::"text"])))
);


ALTER TABLE "public"."recovery_ad_hoc_pool_v2" OWNER TO "postgres";

--
-- Name: recovery_incident_rate_revisions_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."recovery_incident_rate_revisions_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "incident_id" "uuid" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "revision" integer DEFAULT 1 NOT NULL,
    "supersedes_id" "uuid",
    "proposed_rate_minor" bigint NOT NULL,
    "approved_rate_minor" bigint,
    "currency" "text" DEFAULT 'PLN'::"text" NOT NULL,
    "valid_from" "date" NOT NULL,
    "valid_to" "date" NOT NULL,
    "status" "text" DEFAULT 'PROPOSED'::"text" NOT NULL,
    "proposal_reason" "text" NOT NULL,
    "decision_reason" "text",
    "proposed_by" "uuid",
    "approved_by" "uuid",
    "proposed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "approved_at" timestamp with time zone,
    CONSTRAINT "recovery_incident_rate_revisions_v2_approved_rate_minor_check" CHECK (("approved_rate_minor" >= 0)),
    CONSTRAINT "recovery_incident_rate_revisions_v2_check" CHECK (("valid_to" >= "valid_from")),
    CONSTRAINT "recovery_incident_rate_revisions_v2_check1" CHECK (((("status" = 'APPROVED'::"text") AND ("approved_rate_minor" IS NOT NULL) AND ("approved_by" IS NOT NULL) AND ("approved_at" IS NOT NULL)) OR ("status" <> 'APPROVED'::"text"))),
    CONSTRAINT "recovery_incident_rate_revisions_v2_proposal_reason_check" CHECK (("length"(TRIM(BOTH FROM "proposal_reason")) >= 5)),
    CONSTRAINT "recovery_incident_rate_revisions_v2_proposed_rate_minor_check" CHECK (("proposed_rate_minor" >= 0)),
    CONSTRAINT "recovery_incident_rate_revisions_v2_revision_check" CHECK (("revision" > 0)),
    CONSTRAINT "recovery_incident_rate_revisions_v2_status_check" CHECK (("status" = ANY (ARRAY['PROPOSED'::"text", 'APPROVED'::"text", 'REJECTED'::"text", 'SUPERSEDED'::"text"])))
);


ALTER TABLE "public"."recovery_incident_rate_revisions_v2" OWNER TO "postgres";

--
-- Name: recovery_incidents_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."recovery_incidents_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "month" "date" NOT NULL,
    "schedule_id" "uuid",
    "employee_id" "uuid",
    "role_id" "uuid",
    "location_id" "uuid",
    "incident_type" "text" NOT NULL,
    "starts_on" "date" NOT NULL,
    "ends_on" "date" NOT NULL,
    "status" "text" DEFAULT 'DRAFT'::"text" NOT NULL,
    "repair_mode" "text" DEFAULT 'PROPOSE'::"text" NOT NULL,
    "contract_type_snapshot" "text",
    "title" "text" NOT NULL,
    "notes" "text",
    "base_revision" integer NOT NULL,
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_by" "uuid" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "recovery_incidents_v2_check" CHECK (("ends_on" >= "starts_on")),
    CONSTRAINT "recovery_incidents_v2_check1" CHECK ((("starts_on" >= "month") AND ("starts_on" < (("month" + '1 mon'::interval))::"date"))),
    CONSTRAINT "recovery_incidents_v2_check2" CHECK ((("ends_on" >= "month") AND ("ends_on" < (("month" + '1 mon'::interval))::"date"))),
    CONSTRAINT "recovery_incidents_v2_incident_type_check" CHECK (("incident_type" = ANY (ARRAY['SICKNESS'::"text", 'LEAVE'::"text", 'DEPARTURE'::"text", 'CONTRACT_WITHDRAWAL'::"text", 'STRUCTURAL_SHORTAGE'::"text", 'OTHER'::"text"]))),
    CONSTRAINT "recovery_incidents_v2_month_check" CHECK ((("date_trunc"('month'::"text", ("month")::timestamp with time zone))::"date" = "month")),
    CONSTRAINT "recovery_incidents_v2_repair_mode_check" CHECK (("repair_mode" = ANY (ARRAY['PROPOSE'::"text", 'SEND_OFFERS'::"text", 'AUTO_DRAFT'::"text"]))),
    CONSTRAINT "recovery_incidents_v2_status_check" CHECK (("status" = ANY (ARRAY['DRAFT'::"text", 'PROPOSED'::"text", 'OFFERING'::"text", 'READY'::"text", 'APPLIED'::"text", 'CANCELLED'::"text"])))
);


ALTER TABLE "public"."recovery_incidents_v2" OWNER TO "postgres";

--
-- Name: recovery_month_revisions_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."recovery_month_revisions_v2" (
    "month" "date" NOT NULL,
    "revision" integer DEFAULT 0 NOT NULL,
    "updated_by" "uuid",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "recovery_month_revisions_v2_month_check" CHECK ((("date_trunc"('month'::"text", ("month")::timestamp with time zone))::"date" = "month")),
    CONSTRAINT "recovery_month_revisions_v2_revision_check" CHECK (("revision" >= 0))
);


ALTER TABLE "public"."recovery_month_revisions_v2" OWNER TO "postgres";

--
-- Name: recovery_offer_responses_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."recovery_offer_responses_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "action_id" "uuid" NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'PENDING'::"text" NOT NULL,
    "offered_rate_minor" bigint,
    "currency" "text",
    "message" "text",
    "offered_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "responded_at" timestamp with time zone,
    CONSTRAINT "recovery_offer_responses_v2_status_check" CHECK (("status" = ANY (ARRAY['PENDING'::"text", 'ACCEPTED'::"text", 'REJECTED'::"text", 'EXPIRED'::"text", 'WITHDRAWN'::"text"])))
);


ALTER TABLE "public"."recovery_offer_responses_v2" OWNER TO "postgres";

--
-- Name: recovery_overrides_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."recovery_overrides_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "incident_id" "uuid" NOT NULL,
    "override_type" "text" NOT NULL,
    "employee_id" "uuid",
    "role_id" "uuid",
    "starts_on" "date" NOT NULL,
    "ends_on" "date" NOT NULL,
    "numeric_value" bigint NOT NULL,
    "currency" "text",
    "justification" "text" NOT NULL,
    "employee_acknowledged" boolean DEFAULT false NOT NULL,
    "compliance_confirmed" boolean DEFAULT false NOT NULL,
    "status" "text" DEFAULT 'DRAFT'::"text" NOT NULL,
    "approved_by" "uuid",
    "approved_at" timestamp with time zone,
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "recovery_overrides_v2_check" CHECK (("ends_on" >= "starts_on")),
    CONSTRAINT "recovery_overrides_v2_justification_check" CHECK (("length"(TRIM(BOTH FROM "justification")) >= 10)),
    CONSTRAINT "recovery_overrides_v2_override_type_check" CHECK (("override_type" = ANY (ARRAY['BUDGET_DELTA'::"text", 'WEEKLY_LIMIT'::"text", 'MONTHLY_LIMIT'::"text", 'STAFFING_MINIMUM'::"text", 'OPERATING_HOURS'::"text"]))),
    CONSTRAINT "recovery_overrides_v2_status_check" CHECK (("status" = ANY (ARRAY['DRAFT'::"text", 'APPROVED'::"text", 'EXPIRED'::"text", 'CANCELLED'::"text"])))
);


ALTER TABLE "public"."recovery_overrides_v2" OWNER TO "postgres";

--
-- Name: role_plan_assignments; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."role_plan_assignments" (
    "role_plan_section_id" "uuid" NOT NULL,
    "assignment_id" "uuid" NOT NULL
);


ALTER TABLE "public"."role_plan_assignments" OWNER TO "postgres";

--
-- Name: role_plan_sections; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."role_plan_sections" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "month" "date" NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "role_id" "uuid" NOT NULL,
    "version" integer DEFAULT 1 NOT NULL,
    "status" "text" DEFAULT 'DRAFT'::"text" NOT NULL,
    "name" "text" NOT NULL,
    "scenario_code" "text" DEFAULT 'BASE'::"text" NOT NULL,
    "optimization_mode" "text" DEFAULT 'BALANCED'::"text" NOT NULL,
    "staffing_level" "text" DEFAULT 'OPTIMAL'::"text" NOT NULL,
    "legacy_plan_id" "uuid",
    "created_by" "uuid",
    "submitted_at" timestamp with time zone,
    "approved_at" timestamp with time zone,
    "approved_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "role_plan_sections_month_check" CHECK ((("date_trunc"('month'::"text", ("month")::timestamp with time zone))::"date" = "month")),
    CONSTRAINT "role_plan_sections_status_check" CHECK (("status" = ANY (ARRAY['DRAFT'::"text", 'GENERATING'::"text", 'READY'::"text", 'SUBMITTED'::"text", 'CHANGES_REQUESTED'::"text", 'APPROVED'::"text", 'LOCKED'::"text", 'ARCHIVED'::"text"])))
);


ALTER TABLE "public"."role_plan_sections" OWNER TO "postgres";

--
-- Name: roles; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."roles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "public"."employee_role" NOT NULL,
    "name" "text" NOT NULL,
    "active" boolean DEFAULT true NOT NULL
);


ALTER TABLE "public"."roles" OWNER TO "postgres";

--
-- Name: shift_definitions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."shift_definitions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "location_id" "uuid" NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "day_of_week" smallint NOT NULL,
    "start_time" time without time zone NOT NULL,
    "end_time" time without time zone NOT NULL,
    "ends_next_day" boolean DEFAULT false NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    CONSTRAINT "shift_definitions_day_of_week_check" CHECK ((("day_of_week" >= 0) AND ("day_of_week" <= 6)))
);


ALTER TABLE "public"."shift_definitions" OWNER TO "postgres";

--
-- Name: shift_swap_history_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."shift_swap_history_v2" (
    "id" bigint NOT NULL,
    "request_id" "uuid" NOT NULL,
    "actor_id" "uuid" NOT NULL,
    "action" "text" NOT NULL,
    "details" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."shift_swap_history_v2" OWNER TO "postgres";

--
-- Name: shift_swap_history_v2_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE "public"."shift_swap_history_v2" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."shift_swap_history_v2_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: shift_swap_requests_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."shift_swap_requests_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "month" "date" NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "original_assignment_id" "uuid" NOT NULL,
    "role_id" "uuid" NOT NULL,
    "proposer_employee_id" "uuid" NOT NULL,
    "target_employee_id" "uuid",
    "accepted_by_employee_id" "uuid",
    "message" "text",
    "status" "text" DEFAULT 'OPEN'::"text" NOT NULL,
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "employee_decided_at" timestamp with time zone,
    "leader_decided_by" "uuid",
    "leader_decided_at" timestamp with time zone,
    "leader_reason" "text",
    "replacement_id" "uuid",
    CONSTRAINT "shift_swap_requests_v2_check" CHECK ((("target_employee_id" IS NULL) OR ("target_employee_id" <> "proposer_employee_id"))),
    CONSTRAINT "shift_swap_requests_v2_check1" CHECK ((("accepted_by_employee_id" IS NULL) OR ("accepted_by_employee_id" <> "proposer_employee_id"))),
    CONSTRAINT "shift_swap_requests_v2_month_check" CHECK ((("date_trunc"('month'::"text", ("month")::timestamp with time zone))::"date" = "month")),
    CONSTRAINT "shift_swap_requests_v2_status_check" CHECK (("status" = ANY (ARRAY['OPEN'::"text", 'EMPLOYEE_ACCEPTED'::"text", 'EMPLOYEE_REJECTED'::"text", 'LEADER_APPROVED'::"text", 'LEADER_REJECTED'::"text", 'CANCELLED'::"text"])))
);


ALTER TABLE "public"."shift_swap_requests_v2" OWNER TO "postgres";

--
-- Name: shifts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."shifts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "plan_id" "uuid" NOT NULL,
    "location_id" "uuid" NOT NULL,
    "shift_date" "date" NOT NULL,
    "shift_code" "text" NOT NULL,
    "starts_at" timestamp with time zone NOT NULL,
    "ends_at" timestamp with time zone NOT NULL,
    "source_event_id" "uuid",
    "status" "text" DEFAULT 'PLANNED'::"text" NOT NULL,
    CONSTRAINT "shifts_check" CHECK (("ends_at" > "starts_at"))
);


ALTER TABLE "public"."shifts" OWNER TO "postgres";

--
-- Name: solver_feature_flags; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."solver_feature_flags" (
    "flag_key" "text" NOT NULL,
    "engine" "text" NOT NULL,
    "enabled" boolean DEFAULT true NOT NULL,
    "config" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "updated_by" "uuid",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "solver_feature_flags_engine_check" CHECK (("engine" = ANY (ARRAY['ALPHA15'::"text", 'ORTOOLS_V2'::"text", 'SHADOW'::"text"])))
);


ALTER TABLE "public"."solver_feature_flags" OWNER TO "postgres";

--
-- Name: tasks; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."tasks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "source_event_id" "uuid",
    "assigned_to" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "priority" "text" DEFAULT 'NORMAL'::"text" NOT NULL,
    "due_at" timestamp with time zone,
    "status" "public"."task_status" DEFAULT 'NEW'::"public"."task_status" NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "completed_at" timestamp with time zone
);


ALTER TABLE "public"."tasks" OWNER TO "postgres";

--
-- Name: team_conversation_members_v1; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."team_conversation_members_v1" (
    "conversation_id" "uuid" NOT NULL,
    "auth_user_id" "uuid" NOT NULL,
    "employee_id" "uuid",
    "joined_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_read_at" timestamp with time zone
);


ALTER TABLE "public"."team_conversation_members_v1" OWNER TO "postgres";

--
-- Name: team_conversations_v1; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."team_conversations_v1" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "kind" "text" DEFAULT 'DIRECT'::"text" NOT NULL,
    "subject" "text" NOT NULL,
    "context_type" "text",
    "context_id" "uuid",
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "team_conversations_v1_kind_check" CHECK (("kind" = ANY (ARRAY['DIRECT'::"text", 'SWAP'::"text", 'ANNOUNCEMENT'::"text"]))),
    CONSTRAINT "team_conversations_v1_subject_check" CHECK ((("char_length"("subject") >= 1) AND ("char_length"("subject") <= 160)))
);


ALTER TABLE "public"."team_conversations_v1" OWNER TO "postgres";

--
-- Name: team_messages_v1; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."team_messages_v1" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "conversation_id" "uuid" NOT NULL,
    "sender_user_id" "uuid" NOT NULL,
    "body" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "edited_at" timestamp with time zone,
    CONSTRAINT "team_messages_v1_body_check" CHECK ((("char_length"(TRIM(BOTH FROM "body")) >= 1) AND ("char_length"(TRIM(BOTH FROM "body")) <= 2000)))
);


ALTER TABLE "public"."team_messages_v1" OWNER TO "postgres";

--
-- Name: time_records; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."time_records" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "employee_id" "uuid" NOT NULL,
    "work_date" "date" NOT NULL,
    "planned_start" timestamp with time zone,
    "planned_end" timestamp with time zone,
    "actual_start" timestamp with time zone,
    "actual_end" timestamp with time zone,
    "break_minutes" integer DEFAULT 0 NOT NULL,
    "source" "text" DEFAULT 'GRAFIK_PRO'::"text" NOT NULL,
    "status" "text" DEFAULT 'OPEN'::"text" NOT NULL,
    "approved_by" "uuid",
    CONSTRAINT "time_records_status_check" CHECK (("status" = ANY (ARRAY['OPEN'::"text", 'RECORDED'::"text", 'CORRECTED'::"text", 'APPROVED'::"text", 'LOCKED'::"text"])))
);


ALTER TABLE "public"."time_records" OWNER TO "postgres";

--
-- Name: uat_environment_controls; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."uat_environment_controls" (
    "control_key" "text" NOT NULL,
    "enabled" boolean DEFAULT false NOT NULL,
    "config" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."uat_environment_controls" OWNER TO "postgres";

--
-- Name: user_permissions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."user_permissions" (
    "auth_user_id" "uuid" NOT NULL,
    "app_role" "public"."app_role" NOT NULL,
    "scope_role" "public"."employee_role",
    "scope_location" "public"."location_code",
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."user_permissions" OWNER TO "postgres";

--
-- Name: user_profiles_v1; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."user_profiles_v1" (
    "auth_user_id" "uuid" NOT NULL,
    "display_name" "text",
    "avatar_mode" "text" DEFAULT 'INITIALS'::"text" NOT NULL,
    "cat_avatar_key" "text",
    "note_color" "text" DEFAULT '#E8E1D6'::"text" NOT NULL,
    "photo_path" "text",
    "ui_preferences" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "user_profiles_v1_avatar_mode_check" CHECK (("avatar_mode" = ANY (ARRAY['INITIALS'::"text", 'CAT'::"text", 'PHOTO'::"text"]))),
    CONSTRAINT "user_profiles_v1_cat_avatar_key_check" CHECK ((("cat_avatar_key" IS NULL) OR ("cat_avatar_key" ~ '^CAT_(0[1-9]|[1-4][0-9]|5[0-5])$'::"text"))),
    CONSTRAINT "user_profiles_v1_check" CHECK (((("avatar_mode" = 'CAT'::"text") AND ("cat_avatar_key" IS NOT NULL) AND ("photo_path" IS NULL)) OR (("avatar_mode" = 'PHOTO'::"text") AND ("photo_path" IS NOT NULL) AND ("cat_avatar_key" IS NULL)) OR (("avatar_mode" = 'INITIALS'::"text") AND ("cat_avatar_key" IS NULL) AND ("photo_path" IS NULL)))),
    CONSTRAINT "user_profiles_v1_display_name_check" CHECK ((("display_name" IS NULL) OR (("length"(TRIM(BOTH FROM "display_name")) >= 1) AND ("length"(TRIM(BOTH FROM "display_name")) <= 80)))),
    CONSTRAINT "user_profiles_v1_note_color_check" CHECK (("note_color" = ANY (ARRAY['#1A1A1A'::"text", '#2A2A28'::"text", '#E8E1D6'::"text", '#F2EDE4'::"text", '#A6B3A0'::"text", '#879681'::"text", '#55665A'::"text", '#C4D2C4'::"text", '#D9987E'::"text", '#C96F54'::"text", '#B85F3F'::"text", '#CBBFAE'::"text", '#9C9184'::"text", '#F7F3EC'::"text", '#33443B'::"text", '#B85E58'::"text", '#BBC3B7'::"text", '#9AAA8F'::"text", '#2B3A32'::"text", '#C98274'::"text", '#E6B39C'::"text", '#B8A994'::"text", '#756D65'::"text", '#D7D0C7'::"text"]))),
    CONSTRAINT "user_profiles_v1_ui_preferences_check" CHECK (("jsonb_typeof"("ui_preferences") = 'object'::"text"))
);


ALTER TABLE "public"."user_profiles_v1" OWNER TO "postgres";

--
-- Name: workforce_calendar_events_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."workforce_calendar_events_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "month" "date" NOT NULL,
    "event_date" "date" NOT NULL,
    "location_id" "uuid",
    "event_kind" "text" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "status" "text" DEFAULT 'ACTIVE'::"text" NOT NULL,
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "cancelled_by" "uuid",
    "cancelled_at" timestamp with time zone,
    CONSTRAINT "workforce_calendar_events_v2_check" CHECK ((("event_date" >= "month") AND ("event_date" < (("month" + '1 mon'::interval))::"date"))),
    CONSTRAINT "workforce_calendar_events_v2_check1" CHECK (((("status" = 'ACTIVE'::"text") AND ("cancelled_at" IS NULL)) OR (("status" = 'CANCELLED'::"text") AND ("cancelled_at" IS NOT NULL)))),
    CONSTRAINT "workforce_calendar_events_v2_event_kind_check" CHECK (("event_kind" = ANY (ARRAY['EVENT'::"text", 'HOT_DAY'::"text"]))),
    CONSTRAINT "workforce_calendar_events_v2_month_check" CHECK ((("date_trunc"('month'::"text", ("month")::timestamp with time zone))::"date" = "month")),
    CONSTRAINT "workforce_calendar_events_v2_status_check" CHECK (("status" = ANY (ARRAY['ACTIVE'::"text", 'CANCELLED'::"text"]))),
    CONSTRAINT "workforce_calendar_events_v2_title_check" CHECK ((("length"(TRIM(BOTH FROM "title")) >= 3) AND ("length"(TRIM(BOTH FROM "title")) <= 160)))
);


ALTER TABLE "public"."workforce_calendar_events_v2" OWNER TO "postgres";

--
-- Name: workforce_event_demand_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."workforce_event_demand_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "shift_template_id" "uuid" NOT NULL,
    "role_id" "uuid" NOT NULL,
    "duty_id" "uuid",
    "additional_count" integer NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "workforce_event_demand_v2_additional_count_check" CHECK ((("additional_count" >= 1) AND ("additional_count" <= 500)))
);


ALTER TABLE "public"."workforce_event_demand_v2" OWNER TO "postgres";

--
-- Name: workforce_hot_day_limits_v2; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE "public"."workforce_hot_day_limits_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "role_id" "uuid" NOT NULL,
    "maximum_hard_unavailable" integer NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "workforce_hot_day_limits_v2_maximum_hard_unavailable_check" CHECK ((("maximum_hard_unavailable" >= 0) AND ("maximum_hard_unavailable" <= 500)))
);


ALTER TABLE "public"."workforce_hot_day_limits_v2" OWNER TO "postgres";

--
-- Name: leader_variant_history_cursor_v2; Type: TABLE; Schema: solver_private; Owner: postgres
--

CREATE TABLE "solver_private"."leader_variant_history_cursor_v2" (
    "variant_id" "uuid" NOT NULL,
    "current_seq" bigint NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_by" "uuid"
);


ALTER TABLE "solver_private"."leader_variant_history_cursor_v2" OWNER TO "postgres";

--
-- Name: leader_variant_history_v2; Type: TABLE; Schema: solver_private; Owner: postgres
--

CREATE TABLE "solver_private"."leader_variant_history_v2" (
    "seq" bigint NOT NULL,
    "variant_id" "uuid" NOT NULL,
    "revision" integer NOT NULL,
    "label" "text" NOT NULL,
    "snapshot" "jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid",
    "is_checkpoint" boolean DEFAULT false NOT NULL,
    "checkpoint_name" "text",
    CONSTRAINT "leader_variant_history_checkpoint_name_v2" CHECK ((((NOT "is_checkpoint") AND ("checkpoint_name" IS NULL)) OR ("is_checkpoint" AND (("length"(TRIM(BOTH FROM "checkpoint_name")) >= 3) AND ("length"(TRIM(BOTH FROM "checkpoint_name")) <= 120)))))
);


ALTER TABLE "solver_private"."leader_variant_history_v2" OWNER TO "postgres";

--
-- Name: leader_variant_history_v2_seq_seq; Type: SEQUENCE; Schema: solver_private; Owner: postgres
--

ALTER TABLE "solver_private"."leader_variant_history_v2" ALTER COLUMN "seq" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "solver_private"."leader_variant_history_v2_seq_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: mx_k10_legacy_role_duty_archive; Type: TABLE; Schema: solver_private; Owner: postgres
--

CREATE TABLE "solver_private"."mx_k10_legacy_role_duty_archive" (
    "legacy_role_duty_id" "uuid" NOT NULL,
    "matrix_version_id" "uuid" NOT NULL,
    "role_id" "uuid" NOT NULL,
    "duty_id" "uuid" NOT NULL,
    "assignment_mode" "text" NOT NULL,
    "minimum_count" integer NOT NULL,
    "shift_obligation" boolean NOT NULL,
    "shift_period" "text",
    "active" boolean NOT NULL,
    "source_row" "jsonb" NOT NULL,
    "archived_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "solver_private"."mx_k10_legacy_role_duty_archive" OWNER TO "postgres";

--
-- Name: TABLE "mx_k10_legacy_role_duty_archive"; Type: COMMENT; Schema: solver_private; Owner: postgres
--

COMMENT ON TABLE "solver_private"."mx_k10_legacy_role_duty_archive" IS 'MX-K10 audit snapshot. A role-duty link is competency metadata; staffing demand must use an exact matrix_staffing_rules_v2.shift_template_id.';


--
-- Name: optimization_attempts_v2; Type: TABLE; Schema: solver_private; Owner: postgres
--

CREATE TABLE "solver_private"."optimization_attempts_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "run_id" "uuid" NOT NULL,
    "attempt_number" integer NOT NULL,
    "task_attempt" integer DEFAULT 0 NOT NULL,
    "worker_id" "text" NOT NULL,
    "worker_execution_name" "text",
    "lease_token" "uuid" NOT NULL,
    "status" "text" DEFAULT 'RUNNING'::"text" NOT NULL,
    "started_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "heartbeat_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "finished_at" timestamp with time zone,
    "error_code" "text",
    "error_message" "text",
    "worker_version" "text" NOT NULL,
    CONSTRAINT "optimization_attempts_v2_attempt_number_check" CHECK (("attempt_number" > 0)),
    CONSTRAINT "optimization_attempts_v2_status_check" CHECK (("status" = ANY (ARRAY['RUNNING'::"text", 'SUCCEEDED'::"text", 'INTERRUPTED'::"text", 'FAILED'::"text", 'LEASE_LOST'::"text"]))),
    CONSTRAINT "optimization_attempts_v2_task_attempt_check" CHECK (("task_attempt" >= 0))
);


ALTER TABLE "solver_private"."optimization_attempts_v2" OWNER TO "postgres";

--
-- Name: optimization_snapshots_v2; Type: TABLE; Schema: solver_private; Owner: postgres
--

CREATE TABLE "solver_private"."optimization_snapshots_v2" (
    "run_id" "uuid" NOT NULL,
    "schema_version" integer NOT NULL,
    "snapshot_hash" "text" NOT NULL,
    "snapshot" "jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "immutable" boolean DEFAULT true NOT NULL,
    CONSTRAINT "optimization_snapshots_v2_schema_version_check" CHECK (("schema_version" > 0)),
    CONSTRAINT "optimization_snapshots_v2_snapshot_hash_check" CHECK (("snapshot_hash" ~ '^[0-9a-f]{64}$'::"text"))
);


ALTER TABLE "solver_private"."optimization_snapshots_v2" OWNER TO "postgres";

--
-- Name: TABLE "optimization_snapshots_v2"; Type: COMMENT; Schema: solver_private; Owner: postgres
--

COMMENT ON TABLE "solver_private"."optimization_snapshots_v2" IS 'Immutable, finance-bearing solver input. Never expose through the Data API or Realtime.';


--
-- Name: plan_assignment_cost_components_v2; Type: TABLE; Schema: solver_private; Owner: postgres
--

CREATE TABLE "solver_private"."plan_assignment_cost_components_v2" (
    "id" bigint NOT NULL,
    "assignment_id" "uuid" NOT NULL,
    "pay_rule_id" "uuid",
    "component_code" "text" NOT NULL,
    "amount_minor" bigint NOT NULL,
    "quantity_minutes" integer,
    "calculation_basis" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "solver_private"."plan_assignment_cost_components_v2" OWNER TO "postgres";

--
-- Name: plan_assignment_cost_components_v2_id_seq; Type: SEQUENCE; Schema: solver_private; Owner: postgres
--

ALTER TABLE "solver_private"."plan_assignment_cost_components_v2" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "solver_private"."plan_assignment_cost_components_v2_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: plan_variant_finance_v2; Type: TABLE; Schema: solver_private; Owner: postgres
--

CREATE TABLE "solver_private"."plan_variant_finance_v2" (
    "variant_id" "uuid" NOT NULL,
    "base_cost_units" bigint DEFAULT 0 NOT NULL,
    "additions_cost_units" bigint DEFAULT 0 NOT NULL,
    "total_cost_units" bigint DEFAULT 0 NOT NULL,
    "base_cost_minor" bigint DEFAULT 0 NOT NULL,
    "additions_cost_minor" bigint DEFAULT 0 NOT NULL,
    "total_cost_minor" bigint DEFAULT 0 NOT NULL,
    "currency" "text" NOT NULL,
    "budget_minor" bigint,
    "hard_budget_exceeded" boolean DEFAULT false NOT NULL,
    "breakdown" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    CONSTRAINT "plan_variant_finance_v2_additions_cost_minor_check" CHECK (("additions_cost_minor" >= 0)),
    CONSTRAINT "plan_variant_finance_v2_additions_cost_units_check" CHECK (("additions_cost_units" >= 0)),
    CONSTRAINT "plan_variant_finance_v2_base_cost_minor_check" CHECK (("base_cost_minor" >= 0)),
    CONSTRAINT "plan_variant_finance_v2_base_cost_units_check" CHECK (("base_cost_units" >= 0)),
    CONSTRAINT "plan_variant_finance_v2_budget_minor_check" CHECK ((("budget_minor" IS NULL) OR ("budget_minor" >= 0))),
    CONSTRAINT "plan_variant_finance_v2_check" CHECK ((("base_cost_units" + "additions_cost_units") = "total_cost_units")),
    CONSTRAINT "plan_variant_finance_v2_check1" CHECK ((("base_cost_minor" + "additions_cost_minor") = "total_cost_minor")),
    CONSTRAINT "plan_variant_finance_v2_currency_check" CHECK (("currency" ~ '^[A-Z]{3}$'::"text")),
    CONSTRAINT "plan_variant_finance_v2_minor_sum_check" CHECK ((("base_cost_minor" + "additions_cost_minor") = "total_cost_minor")),
    CONSTRAINT "plan_variant_finance_v2_total_cost_minor_check" CHECK (("total_cost_minor" >= 0)),
    CONSTRAINT "plan_variant_finance_v2_total_cost_units_check" CHECK (("total_cost_units" >= 0)),
    CONSTRAINT "plan_variant_finance_v2_units_sum_check" CHECK ((("base_cost_units" + "additions_cost_units") = "total_cost_units"))
);


ALTER TABLE "solver_private"."plan_variant_finance_v2" OWNER TO "postgres";

--
-- Name: planning_data_revision_v2; Type: TABLE; Schema: solver_private; Owner: postgres
--

CREATE TABLE "solver_private"."planning_data_revision_v2" (
    "singleton" boolean DEFAULT true NOT NULL,
    "revision" bigint DEFAULT 1 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "planning_data_revision_v2_revision_check" CHECK (("revision" > 0)),
    CONSTRAINT "planning_data_revision_v2_singleton_check" CHECK ("singleton")
);


ALTER TABLE "solver_private"."planning_data_revision_v2" OWNER TO "postgres";

--
-- Name: TABLE "planning_data_revision_v2"; Type: COMMENT; Schema: solver_private; Owner: postgres
--

COMMENT ON TABLE "solver_private"."planning_data_revision_v2" IS 'Transactional serialization boundary for Matrix, workforce and authoritative schedule inputs.';


--
-- Name: published_schedule_finance_v2; Type: TABLE; Schema: solver_private; Owner: postgres
--

CREATE TABLE "solver_private"."published_schedule_finance_v2" (
    "schedule_id" "uuid" NOT NULL,
    "base_cost_units" bigint NOT NULL,
    "additions_cost_units" bigint NOT NULL,
    "total_cost_units" bigint NOT NULL,
    "base_cost_minor" bigint NOT NULL,
    "additions_cost_minor" bigint NOT NULL,
    "total_cost_minor" bigint NOT NULL,
    "currency" "text" NOT NULL,
    "budget_minor" bigint,
    "hard_budget" boolean NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "published_schedule_finance_v2_additions_cost_minor_check" CHECK (("additions_cost_minor" >= 0)),
    CONSTRAINT "published_schedule_finance_v2_additions_cost_units_check" CHECK (("additions_cost_units" >= 0)),
    CONSTRAINT "published_schedule_finance_v2_base_cost_minor_check" CHECK (("base_cost_minor" >= 0)),
    CONSTRAINT "published_schedule_finance_v2_base_cost_units_check" CHECK (("base_cost_units" >= 0)),
    CONSTRAINT "published_schedule_finance_v2_budget_minor_check" CHECK ((("budget_minor" IS NULL) OR ("budget_minor" >= 0))),
    CONSTRAINT "published_schedule_finance_v2_check" CHECK ((("base_cost_units" + "additions_cost_units") = "total_cost_units")),
    CONSTRAINT "published_schedule_finance_v2_check1" CHECK ((("base_cost_minor" + "additions_cost_minor") = "total_cost_minor")),
    CONSTRAINT "published_schedule_finance_v2_currency_check" CHECK (("currency" ~ '^[A-Z]{3}$'::"text")),
    CONSTRAINT "published_schedule_finance_v2_total_cost_minor_check" CHECK (("total_cost_minor" >= 0)),
    CONSTRAINT "published_schedule_finance_v2_total_cost_units_check" CHECK (("total_cost_units" >= 0))
);


ALTER TABLE "solver_private"."published_schedule_finance_v2" OWNER TO "postgres";

--
-- Name: solver_job_dispatch_outbox_uat_v1; Type: TABLE; Schema: solver_private; Owner: postgres
--

CREATE TABLE "solver_private"."solver_job_dispatch_outbox_uat_v1" (
    "run_id" "uuid" NOT NULL,
    "organization_key" "uuid" NOT NULL,
    "month" "date" NOT NULL,
    "scope_type" "text" NOT NULL,
    "scope_role_id" "uuid",
    "dispatch_status" "text" DEFAULT 'PENDING'::"text" NOT NULL,
    "dispatch_attempt" integer DEFAULT 0 NOT NULL,
    "solver_retry_count" integer DEFAULT 0 NOT NULL,
    "dispatch_nonce" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "dispatcher_lease_token" "uuid",
    "dispatcher_lease_expires_at" timestamp with time zone,
    "northflank_run_id" "text",
    "requested_at" timestamp with time zone NOT NULL,
    "dispatch_started_at" timestamp with time zone,
    "northflank_accepted_at" timestamp with time zone,
    "container_started_at" timestamp with time zone,
    "worker_claimed_at" timestamp with time zone,
    "solver_started_at" timestamp with time zone,
    "solver_finished_at" timestamp with time zone,
    "result_saved_at" timestamp with time zone,
    "ready_at" timestamp with time zone,
    "job_finished_at" timestamp with time zone,
    "next_dispatch_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_http_status" integer,
    "last_error_code" "text",
    "last_error" "text",
    "dispatcher_version" "text",
    "configured_plan" "text" DEFAULT 'nf-compute-100-1'::"text" NOT NULL,
    "configured_vcpu" numeric(6,3) DEFAULT 1 NOT NULL,
    "configured_ram_mb" integer DEFAULT 1024 NOT NULL,
    "estimated_usd_per_hour" numeric(12,8) DEFAULT 0.025 NOT NULL,
    "peak_rss_mb" numeric(12,3),
    "average_rss_mb" numeric(12,3),
    "peak_cpu_percent" numeric(12,3),
    "billable_seconds" numeric(14,3),
    "estimated_compute_cost_usd" numeric(14,8),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "solver_job_dispatch_outbox_uat_v1_check" CHECK ((("scope_type" = 'ROLE'::"text") = ("scope_role_id" IS NOT NULL))),
    CONSTRAINT "solver_job_dispatch_outbox_uat_v1_check1" CHECK (((("dispatcher_lease_token" IS NULL) AND ("dispatcher_lease_expires_at" IS NULL)) OR (("dispatcher_lease_token" IS NOT NULL) AND ("dispatcher_lease_expires_at" IS NOT NULL)))),
    CONSTRAINT "solver_job_dispatch_outbox_uat_v1_dispatch_attempt_check" CHECK (("dispatch_attempt" >= 0)),
    CONSTRAINT "solver_job_dispatch_outbox_uat_v1_dispatch_status_check" CHECK (("dispatch_status" = ANY (ARRAY['PENDING'::"text", 'DISPATCHING'::"text", 'ACCEPTANCE_UNKNOWN'::"text", 'ACCEPTED'::"text", 'STARTING'::"text", 'RUNNING'::"text", 'SUCCEEDED'::"text", 'FAILED'::"text", 'CANCELLED'::"text"]))),
    CONSTRAINT "solver_job_dispatch_outbox_uat_v1_scope_type_check" CHECK (("scope_type" = ANY (ARRAY['COMPANY'::"text", 'ROLE'::"text"]))),
    CONSTRAINT "solver_job_dispatch_outbox_uat_v1_solver_retry_count_check" CHECK (("solver_retry_count" >= 0))
);


ALTER TABLE "solver_private"."solver_job_dispatch_outbox_uat_v1" OWNER TO "postgres";

--
-- Name: TABLE "solver_job_dispatch_outbox_uat_v1"; Type: COMMENT; Schema: solver_private; Owner: postgres
--

COMMENT ON TABLE "solver_private"."solver_job_dispatch_outbox_uat_v1" IS 'UAT-only durable 1:1 dispatch and telemetry record for a Northflank Job generation.';


--
-- Name: solver_job_runtime_config_uat_v1; Type: TABLE; Schema: solver_private; Owner: postgres
--

CREATE TABLE "solver_private"."solver_job_runtime_config_uat_v1" (
    "singleton" boolean DEFAULT true NOT NULL,
    "default_execution_mode" "text" DEFAULT 'SERVICE'::"text" NOT NULL,
    "dispatcher_enabled" boolean DEFAULT false NOT NULL,
    "global_active_jobs" integer DEFAULT 2 NOT NULL,
    "per_organization_active_jobs" integer DEFAULT 1 NOT NULL,
    "generation_quota_per_user_hour" integer DEFAULT 25 NOT NULL,
    "wall_timeout_seconds" integer DEFAULT 720 NOT NULL,
    "claim_watchdog_seconds" integer DEFAULT 300 NOT NULL,
    "heartbeat_watchdog_seconds" integer DEFAULT 180 NOT NULL,
    "deployment_plan" "text" DEFAULT 'nf-compute-100-1'::"text" NOT NULL,
    "configured_vcpu" numeric(6,3) DEFAULT 1 NOT NULL,
    "configured_ram_mb" integer DEFAULT 1024 NOT NULL,
    "estimated_usd_per_hour" numeric(12,8) DEFAULT 0.025 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "solver_job_runtime_config_ua_generation_quota_per_user_ho_check" CHECK ((("generation_quota_per_user_hour" >= 1) AND ("generation_quota_per_user_hour" <= 100))),
    CONSTRAINT "solver_job_runtime_config_ua_per_organization_active_jobs_check" CHECK ((("per_organization_active_jobs" >= 1) AND ("per_organization_active_jobs" <= 20))),
    CONSTRAINT "solver_job_runtime_config_uat__heartbeat_watchdog_seconds_check" CHECK ((("heartbeat_watchdog_seconds" >= 60) AND ("heartbeat_watchdog_seconds" <= 1800))),
    CONSTRAINT "solver_job_runtime_config_uat_v1_claim_watchdog_seconds_check" CHECK ((("claim_watchdog_seconds" >= 60) AND ("claim_watchdog_seconds" <= 1800))),
    CONSTRAINT "solver_job_runtime_config_uat_v1_default_execution_mode_check" CHECK (("default_execution_mode" = 'SERVICE'::"text")),
    CONSTRAINT "solver_job_runtime_config_uat_v1_global_active_jobs_check" CHECK ((("global_active_jobs" >= 1) AND ("global_active_jobs" <= 20))),
    CONSTRAINT "solver_job_runtime_config_uat_v1_singleton_check" CHECK ("singleton"),
    CONSTRAINT "solver_job_runtime_config_uat_v1_wall_timeout_seconds_check" CHECK ((("wall_timeout_seconds" >= 60) AND ("wall_timeout_seconds" <= 3600)))
);


ALTER TABLE "solver_private"."solver_job_runtime_config_uat_v1" OWNER TO "postgres";

--
-- Name: solver_runtime_builds_uat_v1; Type: TABLE; Schema: solver_private; Owner: postgres
--

CREATE TABLE "solver_private"."solver_runtime_builds_uat_v1" (
    "solver_version" "text" NOT NULL,
    "solver_commit" "text" NOT NULL,
    "solver_image_digest" "text",
    "solver_build_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "execution_mode" "text" NOT NULL,
    CONSTRAINT "solver_runtime_builds_uat_v1_execution_mode_check" CHECK (("execution_mode" = ANY (ARRAY['SERVICE'::"text", 'JOB'::"text"]))),
    CONSTRAINT "solver_runtime_builds_uat_v1_solver_build_id_check" CHECK ((("length"("solver_build_id") >= 1) AND ("length"("solver_build_id") <= 200))),
    CONSTRAINT "solver_runtime_builds_uat_v1_solver_commit_check" CHECK (("solver_commit" ~ '^[0-9a-f]{40}$'::"text")),
    CONSTRAINT "solver_runtime_builds_uat_v1_solver_image_digest_check" CHECK ((("solver_image_digest" IS NULL) OR ("solver_image_digest" ~ '^sha256:[0-9a-f]{64}$'::"text")))
);


ALTER TABLE "solver_private"."solver_runtime_builds_uat_v1" OWNER TO "postgres";

--
-- Name: TABLE "solver_runtime_builds_uat_v1"; Type: COMMENT; Schema: solver_private; Owner: postgres
--

COMMENT ON TABLE "solver_private"."solver_runtime_builds_uat_v1" IS 'UAT-only exact runtime provenance keyed by solver version and SERVICE/JOB execution mode. A JOB row may be inserted only after the corresponding paid build exists.';


--
-- Name: application_access_directory_v1 application_access_directory__email_app_role_role_logical_i_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."application_access_directory_v1"
    ADD CONSTRAINT "application_access_directory__email_app_role_role_logical_i_key" UNIQUE NULLS NOT DISTINCT ("email", "app_role", "role_logical_id", "location_logical_id");


--
-- Name: application_access_directory_v1 application_access_directory_v1_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."application_access_directory_v1"
    ADD CONSTRAINT "application_access_directory_v1_pkey" PRIMARY KEY ("id");


--
-- Name: application_finance_visibility_policy_v1 application_finance_visibility_policy_v1_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."application_finance_visibility_policy_v1"
    ADD CONSTRAINT "application_finance_visibility_policy_v1_pkey" PRIMARY KEY ("app_role");


--
-- Name: assignments assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."assignments"
    ADD CONSTRAINT "assignments_pkey" PRIMARY KEY ("id");


--
-- Name: assignments assignments_shift_id_employee_id_assigned_role_assigned_cap_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."assignments"
    ADD CONSTRAINT "assignments_shift_id_employee_id_assigned_role_assigned_cap_key" UNIQUE ("shift_id", "employee_id", "assigned_role", "assigned_capability");


--
-- Name: attendance_events attendance_events_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."attendance_events"
    ADD CONSTRAINT "attendance_events_pkey" PRIMARY KEY ("id");


--
-- Name: audit_log audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."audit_log"
    ADD CONSTRAINT "audit_log_pkey" PRIMARY KEY ("id");


--
-- Name: availability_exception_reviews_v2 availability_exception_reviews_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."availability_exception_reviews_v2"
    ADD CONSTRAINT "availability_exception_reviews_v2_pkey" PRIMARY KEY ("id");


--
-- Name: business_app_integrations_v1 business_app_integrations_v1_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."business_app_integrations_v1"
    ADD CONSTRAINT "business_app_integrations_v1_pkey" PRIMARY KEY ("id");


--
-- Name: business_app_integrations_v1 business_app_integrations_v1_product_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."business_app_integrations_v1"
    ADD CONSTRAINT "business_app_integrations_v1_product_code_key" UNIQUE ("product_code");


--
-- Name: composite_schedules composite_schedules_month_version_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."composite_schedules"
    ADD CONSTRAINT "composite_schedules_month_version_key" UNIQUE ("month", "version");


--
-- Name: composite_schedules composite_schedules_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."composite_schedules"
    ADD CONSTRAINT "composite_schedules_pkey" PRIMARY KEY ("id");


--
-- Name: demand_rules demand_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."demand_rules"
    ADD CONSTRAINT "demand_rules_pkey" PRIMARY KEY ("id");


--
-- Name: demand_rules demand_rules_shift_definition_id_role_required_capability_s_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."demand_rules"
    ADD CONSTRAINT "demand_rules_shift_definition_id_role_required_capability_s_key" UNIQUE ("shift_definition_id", "role", "required_capability", "scenario_code");


--
-- Name: employee_availability employee_availability_employee_id_work_date_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_availability"
    ADD CONSTRAINT "employee_availability_employee_id_work_date_key" UNIQUE ("employee_id", "work_date");


--
-- Name: employee_availability_history employee_availability_history_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_availability_history"
    ADD CONSTRAINT "employee_availability_history_pkey" PRIMARY KEY ("id");


--
-- Name: employee_availability employee_availability_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_availability"
    ADD CONSTRAINT "employee_availability_pkey" PRIMARY KEY ("id");


--
-- Name: employee_capabilities employee_capabilities_employee_id_capability_scope_role_sco_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_capabilities"
    ADD CONSTRAINT "employee_capabilities_employee_id_capability_scope_role_sco_key" UNIQUE NULLS NOT DISTINCT ("employee_id", "capability", "scope_role", "scope_location");


--
-- Name: employee_capabilities employee_capabilities_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_capabilities"
    ADD CONSTRAINT "employee_capabilities_pkey" PRIMARY KEY ("id");


--
-- Name: employee_hr_profiles employee_hr_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_hr_profiles"
    ADD CONSTRAINT "employee_hr_profiles_pkey" PRIMARY KEY ("employee_id");


--
-- Name: employee_locations employee_locations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_locations"
    ADD CONSTRAINT "employee_locations_pkey" PRIMARY KEY ("employee_id", "location_id");


--
-- Name: employee_pay_rates_v2 employee_pay_rates_v2_employee_id_valid_from_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_pay_rates_v2"
    ADD CONSTRAINT "employee_pay_rates_v2_employee_id_valid_from_key" UNIQUE ("employee_id", "valid_from");


--
-- Name: employee_pay_rates_v2 employee_pay_rates_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_pay_rates_v2"
    ADD CONSTRAINT "employee_pay_rates_v2_pkey" PRIMARY KEY ("id");


--
-- Name: employee_preferences employee_preferences_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_preferences"
    ADD CONSTRAINT "employee_preferences_pkey" PRIMARY KEY ("id");


--
-- Name: employee_requests_v1 employee_requests_v1_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_requests_v1"
    ADD CONSTRAINT "employee_requests_v1_pkey" PRIMARY KEY ("id");


--
-- Name: employee_time_constraints_v2 employee_time_constraints_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_time_constraints_v2"
    ADD CONSTRAINT "employee_time_constraints_v2_pkey" PRIMARY KEY ("id");


--
-- Name: employee_weekly_work_patterns_v2 employee_weekly_work_patterns_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_weekly_work_patterns_v2"
    ADD CONSTRAINT "employee_weekly_work_patterns_v2_pkey" PRIMARY KEY ("id");


--
-- Name: employees employees_auth_user_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employees"
    ADD CONSTRAINT "employees_auth_user_id_key" UNIQUE ("auth_user_id");


--
-- Name: employees employees_email_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employees"
    ADD CONSTRAINT "employees_email_key" UNIQUE ("email");


--
-- Name: employees employees_employee_no_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employees"
    ADD CONSTRAINT "employees_employee_no_key" UNIQUE ("employee_no");


--
-- Name: employees employees_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employees"
    ADD CONSTRAINT "employees_pkey" PRIMARY KEY ("id");


--
-- Name: employer_cost_components_v2 employer_cost_components_v2_logical_id_revision_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employer_cost_components_v2"
    ADD CONSTRAINT "employer_cost_components_v2_logical_id_revision_key" UNIQUE ("logical_id", "revision");


--
-- Name: employer_cost_components_v2 employer_cost_components_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employer_cost_components_v2"
    ADD CONSTRAINT "employer_cost_components_v2_pkey" PRIMARY KEY ("id");


--
-- Name: event_demand_changes event_demand_changes_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."event_demand_changes"
    ADD CONSTRAINT "event_demand_changes_pkey" PRIMARY KEY ("id");


--
-- Name: integration_runs integration_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."integration_runs"
    ADD CONSTRAINT "integration_runs_pkey" PRIMARY KEY ("id");


--
-- Name: locations locations_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."locations"
    ADD CONSTRAINT "locations_code_key" UNIQUE ("code");


--
-- Name: locations locations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."locations"
    ADD CONSTRAINT "locations_pkey" PRIMARY KEY ("id");


--
-- Name: matrix_conflicts matrix_conflicts_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_conflicts"
    ADD CONSTRAINT "matrix_conflicts_pkey" PRIMARY KEY ("id");


--
-- Name: matrix_demand matrix_demand_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_demand"
    ADD CONSTRAINT "matrix_demand_pkey" PRIMARY KEY ("id");


--
-- Name: matrix_demand matrix_demand_shift_template_id_role_id_function_id_scenari_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_demand"
    ADD CONSTRAINT "matrix_demand_shift_template_id_role_id_function_id_scenari_key" UNIQUE NULLS NOT DISTINCT ("shift_template_id", "role_id", "function_id", "scenario_code");


--
-- Name: matrix_duties_v2 matrix_duties_v2_matrix_version_id_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_duties_v2"
    ADD CONSTRAINT "matrix_duties_v2_matrix_version_id_code_key" UNIQUE ("matrix_version_id", "code");


--
-- Name: matrix_duties_v2 matrix_duties_v2_matrix_version_id_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_duties_v2"
    ADD CONSTRAINT "matrix_duties_v2_matrix_version_id_id_key" UNIQUE ("matrix_version_id", "id");


--
-- Name: matrix_duties_v2 matrix_duties_v2_matrix_version_id_logical_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_duties_v2"
    ADD CONSTRAINT "matrix_duties_v2_matrix_version_id_logical_id_key" UNIQUE ("matrix_version_id", "logical_id");


--
-- Name: matrix_duties_v2 matrix_duties_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_duties_v2"
    ADD CONSTRAINT "matrix_duties_v2_pkey" PRIMARY KEY ("id");


--
-- Name: matrix_employee_duties_v2 matrix_employee_duties_v2_matrix_version_id_employee_id_dut_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_duties_v2"
    ADD CONSTRAINT "matrix_employee_duties_v2_matrix_version_id_employee_id_dut_key" UNIQUE NULLS NOT DISTINCT ("matrix_version_id", "employee_id", "duty_id", "role_id", "location_id");


--
-- Name: matrix_employee_duties_v2 matrix_employee_duties_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_duties_v2"
    ADD CONSTRAINT "matrix_employee_duties_v2_pkey" PRIMARY KEY ("id");


--
-- Name: matrix_employee_locations_v2 matrix_employee_locations_v2_matrix_version_id_employee_id__key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_locations_v2"
    ADD CONSTRAINT "matrix_employee_locations_v2_matrix_version_id_employee_id__key" UNIQUE ("matrix_version_id", "employee_id", "location_id");


--
-- Name: matrix_employee_locations_v2 matrix_employee_locations_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_locations_v2"
    ADD CONSTRAINT "matrix_employee_locations_v2_pkey" PRIMARY KEY ("id");


--
-- Name: matrix_employee_profiles_v2 matrix_employee_profiles_v2_matrix_version_id_employee_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_profiles_v2"
    ADD CONSTRAINT "matrix_employee_profiles_v2_matrix_version_id_employee_id_key" UNIQUE ("matrix_version_id", "employee_id");


--
-- Name: matrix_employee_profiles_v2 matrix_employee_profiles_v2_matrix_version_id_employee_no_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_profiles_v2"
    ADD CONSTRAINT "matrix_employee_profiles_v2_matrix_version_id_employee_no_key" UNIQUE ("matrix_version_id", "employee_no");


--
-- Name: matrix_employee_profiles_v2 matrix_employee_profiles_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_profiles_v2"
    ADD CONSTRAINT "matrix_employee_profiles_v2_pkey" PRIMARY KEY ("id");


--
-- Name: matrix_employee_roles matrix_employee_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_roles"
    ADD CONSTRAINT "matrix_employee_roles_pkey" PRIMARY KEY ("matrix_version_id", "employee_id", "role_id");


--
-- Name: matrix_employee_roles_v2 matrix_employee_roles_v2_matrix_version_id_employee_id_role_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_roles_v2"
    ADD CONSTRAINT "matrix_employee_roles_v2_matrix_version_id_employee_id_role_key" UNIQUE ("matrix_version_id", "employee_id", "role_id");


--
-- Name: matrix_employee_roles_v2 matrix_employee_roles_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_roles_v2"
    ADD CONSTRAINT "matrix_employee_roles_v2_pkey" PRIMARY KEY ("id");


--
-- Name: matrix_employee_roles_v2 matrix_employee_roles_v2_primary_or_fallback_check; Type: CHECK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_employee_roles_v2"
    ADD CONSTRAINT "matrix_employee_roles_v2_primary_or_fallback_check" CHECK ((("is_primary" AND ("assignment_mode" = 'STANDARD'::"text")) OR ((NOT "is_primary") AND ("assignment_mode" = 'BACKUP'::"text")))) NOT VALID;


--
-- Name: CONSTRAINT "matrix_employee_roles_v2_primary_or_fallback_check" ON "matrix_employee_roles_v2"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON CONSTRAINT "matrix_employee_roles_v2_primary_or_fallback_check" ON "public"."matrix_employee_roles_v2" IS 'Primary role is STANDARD; every additional role is BACKUP. Added NOT VALID so published history remains immutable.';


--
-- Name: matrix_functions matrix_functions_matrix_version_id_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_functions"
    ADD CONSTRAINT "matrix_functions_matrix_version_id_code_key" UNIQUE ("matrix_version_id", "code");


--
-- Name: matrix_functions matrix_functions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_functions"
    ADD CONSTRAINT "matrix_functions_pkey" PRIMARY KEY ("id");


--
-- Name: matrix_import_runs matrix_import_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_import_runs"
    ADD CONSTRAINT "matrix_import_runs_pkey" PRIMARY KEY ("id");


--
-- Name: matrix_locations matrix_locations_matrix_version_id_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_locations"
    ADD CONSTRAINT "matrix_locations_matrix_version_id_code_key" UNIQUE ("matrix_version_id", "code");


--
-- Name: matrix_locations matrix_locations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_locations"
    ADD CONSTRAINT "matrix_locations_pkey" PRIMARY KEY ("id");


--
-- Name: matrix_locations_v2 matrix_locations_v2_matrix_version_id_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_locations_v2"
    ADD CONSTRAINT "matrix_locations_v2_matrix_version_id_code_key" UNIQUE ("matrix_version_id", "code");


--
-- Name: matrix_locations_v2 matrix_locations_v2_matrix_version_id_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_locations_v2"
    ADD CONSTRAINT "matrix_locations_v2_matrix_version_id_id_key" UNIQUE ("matrix_version_id", "id");


--
-- Name: matrix_locations_v2 matrix_locations_v2_matrix_version_id_logical_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_locations_v2"
    ADD CONSTRAINT "matrix_locations_v2_matrix_version_id_logical_id_key" UNIQUE ("matrix_version_id", "logical_id");


--
-- Name: matrix_locations_v2 matrix_locations_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_locations_v2"
    ADD CONSTRAINT "matrix_locations_v2_pkey" PRIMARY KEY ("id");


--
-- Name: matrix_pay_rule_duties_v2 matrix_pay_rule_duties_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_pay_rule_duties_v2"
    ADD CONSTRAINT "matrix_pay_rule_duties_v2_pkey" PRIMARY KEY ("pay_rule_id", "duty_id");


--
-- Name: matrix_pay_rule_locations_v2 matrix_pay_rule_locations_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_pay_rule_locations_v2"
    ADD CONSTRAINT "matrix_pay_rule_locations_v2_pkey" PRIMARY KEY ("pay_rule_id", "location_id");


--
-- Name: matrix_pay_rule_roles_v2 matrix_pay_rule_roles_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_pay_rule_roles_v2"
    ADD CONSTRAINT "matrix_pay_rule_roles_v2_pkey" PRIMARY KEY ("pay_rule_id", "role_id");


--
-- Name: matrix_pay_rule_shifts_v2 matrix_pay_rule_shifts_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_pay_rule_shifts_v2"
    ADD CONSTRAINT "matrix_pay_rule_shifts_v2_pkey" PRIMARY KEY ("pay_rule_id", "shift_template_id");


--
-- Name: matrix_pay_rules_v2 matrix_pay_rules_v2_matrix_version_id_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_pay_rules_v2"
    ADD CONSTRAINT "matrix_pay_rules_v2_matrix_version_id_code_key" UNIQUE ("matrix_version_id", "code");


--
-- Name: matrix_pay_rules_v2 matrix_pay_rules_v2_matrix_version_id_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_pay_rules_v2"
    ADD CONSTRAINT "matrix_pay_rules_v2_matrix_version_id_id_key" UNIQUE ("matrix_version_id", "id");


--
-- Name: matrix_pay_rules_v2 matrix_pay_rules_v2_matrix_version_id_logical_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_pay_rules_v2"
    ADD CONSTRAINT "matrix_pay_rules_v2_matrix_version_id_logical_id_key" UNIQUE ("matrix_version_id", "logical_id");


--
-- Name: matrix_pay_rules_v2 matrix_pay_rules_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_pay_rules_v2"
    ADD CONSTRAINT "matrix_pay_rules_v2_pkey" PRIMARY KEY ("id");


--
-- Name: matrix_role_categories_v2 matrix_role_categories_v2_matrix_version_id_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_role_categories_v2"
    ADD CONSTRAINT "matrix_role_categories_v2_matrix_version_id_code_key" UNIQUE ("matrix_version_id", "code");


--
-- Name: matrix_role_categories_v2 matrix_role_categories_v2_matrix_version_id_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_role_categories_v2"
    ADD CONSTRAINT "matrix_role_categories_v2_matrix_version_id_id_key" UNIQUE ("matrix_version_id", "id");


--
-- Name: matrix_role_categories_v2 matrix_role_categories_v2_matrix_version_id_logical_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_role_categories_v2"
    ADD CONSTRAINT "matrix_role_categories_v2_matrix_version_id_logical_id_key" UNIQUE ("matrix_version_id", "logical_id");


--
-- Name: matrix_role_categories_v2 matrix_role_categories_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_role_categories_v2"
    ADD CONSTRAINT "matrix_role_categories_v2_pkey" PRIMARY KEY ("id");


--
-- Name: matrix_role_duties_v2 matrix_role_duties_v2_matrix_version_id_role_id_duty_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_role_duties_v2"
    ADD CONSTRAINT "matrix_role_duties_v2_matrix_version_id_role_id_duty_id_key" UNIQUE ("matrix_version_id", "role_id", "duty_id");


--
-- Name: matrix_role_duties_v2 matrix_role_duties_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_role_duties_v2"
    ADD CONSTRAINT "matrix_role_duties_v2_pkey" PRIMARY KEY ("id");


--
-- Name: matrix_role_functions matrix_role_functions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_role_functions"
    ADD CONSTRAINT "matrix_role_functions_pkey" PRIMARY KEY ("role_id", "function_id");


--
-- Name: matrix_roles matrix_roles_matrix_version_id_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_roles"
    ADD CONSTRAINT "matrix_roles_matrix_version_id_code_key" UNIQUE ("matrix_version_id", "code");


--
-- Name: matrix_roles matrix_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_roles"
    ADD CONSTRAINT "matrix_roles_pkey" PRIMARY KEY ("id");


--
-- Name: matrix_roles_v2 matrix_roles_v2_matrix_version_id_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_roles_v2"
    ADD CONSTRAINT "matrix_roles_v2_matrix_version_id_code_key" UNIQUE ("matrix_version_id", "code");


--
-- Name: matrix_roles_v2 matrix_roles_v2_matrix_version_id_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_roles_v2"
    ADD CONSTRAINT "matrix_roles_v2_matrix_version_id_id_key" UNIQUE ("matrix_version_id", "id");


--
-- Name: matrix_roles_v2 matrix_roles_v2_matrix_version_id_logical_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_roles_v2"
    ADD CONSTRAINT "matrix_roles_v2_matrix_version_id_logical_id_key" UNIQUE ("matrix_version_id", "logical_id");


--
-- Name: matrix_roles_v2 matrix_roles_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_roles_v2"
    ADD CONSTRAINT "matrix_roles_v2_pkey" PRIMARY KEY ("id");


--
-- Name: matrix_scenario_budgets_v2 matrix_scenario_budgets_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scenario_budgets_v2"
    ADD CONSTRAINT "matrix_scenario_budgets_v2_pkey" PRIMARY KEY ("id");


--
-- Name: matrix_scenario_budgets_v2 matrix_scenario_budgets_v2_scenario_id_budget_month_locatio_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scenario_budgets_v2"
    ADD CONSTRAINT "matrix_scenario_budgets_v2_scenario_id_budget_month_locatio_key" UNIQUE NULLS NOT DISTINCT ("scenario_id", "budget_month", "location_id", "role_id", "duty_id");


--
-- Name: matrix_scenario_pay_rule_overrides_v2 matrix_scenario_pay_rule_overrides__scenario_id_pay_rule_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scenario_pay_rule_overrides_v2"
    ADD CONSTRAINT "matrix_scenario_pay_rule_overrides__scenario_id_pay_rule_id_key" UNIQUE ("scenario_id", "pay_rule_id");


--
-- Name: matrix_scenario_pay_rule_overrides_v2 matrix_scenario_pay_rule_overrides_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scenario_pay_rule_overrides_v2"
    ADD CONSTRAINT "matrix_scenario_pay_rule_overrides_v2_pkey" PRIMARY KEY ("id");


--
-- Name: matrix_scenario_strategies_v2 matrix_scenario_strategies_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scenario_strategies_v2"
    ADD CONSTRAINT "matrix_scenario_strategies_v2_pkey" PRIMARY KEY ("id");


--
-- Name: matrix_scenario_strategies_v2 matrix_scenario_strategies_v2_scenario_id_strategy_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scenario_strategies_v2"
    ADD CONSTRAINT "matrix_scenario_strategies_v2_scenario_id_strategy_id_key" UNIQUE ("scenario_id", "strategy_id");


--
-- Name: matrix_scenarios matrix_scenarios_matrix_version_id_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scenarios"
    ADD CONSTRAINT "matrix_scenarios_matrix_version_id_code_key" UNIQUE ("matrix_version_id", "code");


--
-- Name: matrix_scenarios matrix_scenarios_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scenarios"
    ADD CONSTRAINT "matrix_scenarios_pkey" PRIMARY KEY ("id");


--
-- Name: matrix_scenarios_v2 matrix_scenarios_v2_matrix_version_id_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scenarios_v2"
    ADD CONSTRAINT "matrix_scenarios_v2_matrix_version_id_code_key" UNIQUE ("matrix_version_id", "code");


--
-- Name: matrix_scenarios_v2 matrix_scenarios_v2_matrix_version_id_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scenarios_v2"
    ADD CONSTRAINT "matrix_scenarios_v2_matrix_version_id_id_key" UNIQUE ("matrix_version_id", "id");


--
-- Name: matrix_scenarios_v2 matrix_scenarios_v2_matrix_version_id_logical_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scenarios_v2"
    ADD CONSTRAINT "matrix_scenarios_v2_matrix_version_id_logical_id_key" UNIQUE ("matrix_version_id", "logical_id");


--
-- Name: matrix_scenarios_v2 matrix_scenarios_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scenarios_v2"
    ADD CONSTRAINT "matrix_scenarios_v2_pkey" PRIMARY KEY ("id");


--
-- Name: matrix_scope_grants_v2 matrix_scope_grants_v2_auth_user_id_app_role_role_logical_i_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scope_grants_v2"
    ADD CONSTRAINT "matrix_scope_grants_v2_auth_user_id_app_role_role_logical_i_key" UNIQUE NULLS NOT DISTINCT ("auth_user_id", "app_role", "role_logical_id", "location_logical_id", "duty_logical_id");


--
-- Name: matrix_scope_grants_v2 matrix_scope_grants_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scope_grants_v2"
    ADD CONSTRAINT "matrix_scope_grants_v2_pkey" PRIMARY KEY ("id");


--
-- Name: matrix_shift_templates matrix_shift_templates_matrix_version_id_location_id_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_shift_templates"
    ADD CONSTRAINT "matrix_shift_templates_matrix_version_id_location_id_code_key" UNIQUE ("matrix_version_id", "location_id", "code");


--
-- Name: matrix_shift_templates matrix_shift_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_shift_templates"
    ADD CONSTRAINT "matrix_shift_templates_pkey" PRIMARY KEY ("id");


--
-- Name: matrix_shift_templates_v2 matrix_shift_templates_v2_matrix_version_id_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_shift_templates_v2"
    ADD CONSTRAINT "matrix_shift_templates_v2_matrix_version_id_id_key" UNIQUE ("matrix_version_id", "id");


--
-- Name: matrix_shift_templates_v2 matrix_shift_templates_v2_matrix_version_id_location_id_cod_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_shift_templates_v2"
    ADD CONSTRAINT "matrix_shift_templates_v2_matrix_version_id_location_id_cod_key" UNIQUE ("matrix_version_id", "location_id", "code");


--
-- Name: matrix_shift_templates_v2 matrix_shift_templates_v2_matrix_version_id_logical_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_shift_templates_v2"
    ADD CONSTRAINT "matrix_shift_templates_v2_matrix_version_id_logical_id_key" UNIQUE ("matrix_version_id", "logical_id");


--
-- Name: matrix_shift_templates_v2 matrix_shift_templates_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_shift_templates_v2"
    ADD CONSTRAINT "matrix_shift_templates_v2_pkey" PRIMARY KEY ("id");


--
-- Name: matrix_staffing_rules_v2 matrix_staffing_active_set_positive_uat006; Type: CHECK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_staffing_rules_v2"
    ADD CONSTRAINT "matrix_staffing_active_set_positive_uat006" CHECK (((NOT "active") OR ("operation" <> 'SET'::"text") OR ("count_value" >= 1))) NOT VALID;


--
-- Name: matrix_staffing_rules_v2 matrix_staffing_rules_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_staffing_rules_v2"
    ADD CONSTRAINT "matrix_staffing_rules_v2_pkey" PRIMARY KEY ("id");


--
-- Name: matrix_staffing_rules_v2 matrix_staffing_rules_v2_scenario_id_shift_template_id_role_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_staffing_rules_v2"
    ADD CONSTRAINT "matrix_staffing_rules_v2_scenario_id_shift_template_id_role_key" UNIQUE NULLS NOT DISTINCT ("scenario_id", "shift_template_id", "role_id", "duty_id");


--
-- Name: matrix_strategies_v2 matrix_strategies_v2_matrix_version_id_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_strategies_v2"
    ADD CONSTRAINT "matrix_strategies_v2_matrix_version_id_code_key" UNIQUE ("matrix_version_id", "code");


--
-- Name: matrix_strategies_v2 matrix_strategies_v2_matrix_version_id_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_strategies_v2"
    ADD CONSTRAINT "matrix_strategies_v2_matrix_version_id_id_key" UNIQUE ("matrix_version_id", "id");


--
-- Name: matrix_strategies_v2 matrix_strategies_v2_matrix_version_id_logical_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_strategies_v2"
    ADD CONSTRAINT "matrix_strategies_v2_matrix_version_id_logical_id_key" UNIQUE ("matrix_version_id", "logical_id");


--
-- Name: matrix_strategies_v2 matrix_strategies_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_strategies_v2"
    ADD CONSTRAINT "matrix_strategies_v2_pkey" PRIMARY KEY ("id");


--
-- Name: matrix_strategy_objectives_v2 matrix_strategy_objectives_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_strategy_objectives_v2"
    ADD CONSTRAINT "matrix_strategy_objectives_v2_pkey" PRIMARY KEY ("id");


--
-- Name: matrix_strategy_objectives_v2 matrix_strategy_objectives_v2_strategy_id_tier_metric_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_strategy_objectives_v2"
    ADD CONSTRAINT "matrix_strategy_objectives_v2_strategy_id_tier_metric_code_key" UNIQUE ("strategy_id", "tier", "metric_code");


--
-- Name: matrix_versions matrix_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_versions"
    ADD CONSTRAINT "matrix_versions_pkey" PRIMARY KEY ("id");


--
-- Name: matrix_versions matrix_versions_version_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_versions"
    ADD CONSTRAINT "matrix_versions_version_key" UNIQUE ("version");


--
-- Name: monthly_budget_lines_v2 monthly_budget_lines_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."monthly_budget_lines_v2"
    ADD CONSTRAINT "monthly_budget_lines_v2_pkey" PRIMARY KEY ("id");


--
-- Name: monthly_budget_lines_v2 monthly_budget_lines_v2_revision_id_scope_type_location_log_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."monthly_budget_lines_v2"
    ADD CONSTRAINT "monthly_budget_lines_v2_revision_id_scope_type_location_log_key" UNIQUE NULLS NOT DISTINCT ("revision_id", "scope_type", "location_logical_id", "category_logical_id", "role_logical_id", "metric_type");


--
-- Name: monthly_budget_revisions_v2 monthly_budget_revisions_v2_budget_month_revision_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."monthly_budget_revisions_v2"
    ADD CONSTRAINT "monthly_budget_revisions_v2_budget_month_revision_key" UNIQUE ("budget_month", "revision");


--
-- Name: monthly_budget_revisions_v2 monthly_budget_revisions_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."monthly_budget_revisions_v2"
    ADD CONSTRAINT "monthly_budget_revisions_v2_pkey" PRIMARY KEY ("id");


--
-- Name: monthly_budgets monthly_budgets_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."monthly_budgets"
    ADD CONSTRAINT "monthly_budgets_pkey" PRIMARY KEY ("month");


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");


--
-- Name: operational_assignment_overrides_v2 operational_assignment_overrides_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_assignment_overrides_v2"
    ADD CONSTRAINT "operational_assignment_overrides_v2_pkey" PRIMARY KEY ("id");


--
-- Name: operational_assignment_replacements_v2 operational_assignment_replac_original_assignment_id_status_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_assignment_replacements_v2"
    ADD CONSTRAINT "operational_assignment_replac_original_assignment_id_status_key" UNIQUE ("original_assignment_id", "status");


--
-- Name: operational_assignment_replacements_v2 operational_assignment_replacements_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_assignment_replacements_v2"
    ADD CONSTRAINT "operational_assignment_replacements_v2_pkey" PRIMARY KEY ("id");


--
-- Name: operational_events operational_events_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_events"
    ADD CONSTRAINT "operational_events_pkey" PRIMARY KEY ("id");


--
-- Name: operational_program_audience_rules_v1 operational_program_audience_rules_v1_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_program_audience_rules_v1"
    ADD CONSTRAINT "operational_program_audience_rules_v1_pkey" PRIMARY KEY ("id");


--
-- Name: operational_program_audit_v1 operational_program_audit_v1_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_program_audit_v1"
    ADD CONSTRAINT "operational_program_audit_v1_pkey" PRIMARY KEY ("id");


--
-- Name: operational_program_checklist_items_v1 operational_program_checklist_items_v1_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_program_checklist_items_v1"
    ADD CONSTRAINT "operational_program_checklist_items_v1_pkey" PRIMARY KEY ("id");


--
-- Name: operational_program_events_v1 operational_program_events_v1_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_program_events_v1"
    ADD CONSTRAINT "operational_program_events_v1_pkey" PRIMARY KEY ("id");


--
-- Name: operational_program_inventory_links_v1 operational_program_inventory_links_v1_event_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_program_inventory_links_v1"
    ADD CONSTRAINT "operational_program_inventory_links_v1_event_id_key" UNIQUE ("event_id");


--
-- Name: operational_program_inventory_links_v1 operational_program_inventory_links_v1_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_program_inventory_links_v1"
    ADD CONSTRAINT "operational_program_inventory_links_v1_pkey" PRIMARY KEY ("id");


--
-- Name: operational_program_participants_v1 operational_program_participants_v1_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_program_participants_v1"
    ADD CONSTRAINT "operational_program_participants_v1_pkey" PRIMARY KEY ("id");


--
-- Name: optimization_candidates optimization_candidates_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."optimization_candidates"
    ADD CONSTRAINT "optimization_candidates_pkey" PRIMARY KEY ("id");


--
-- Name: optimization_candidates optimization_candidates_run_id_rank_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."optimization_candidates"
    ADD CONSTRAINT "optimization_candidates_run_id_rank_key" UNIQUE ("run_id", "rank");


--
-- Name: optimization_run_strategies_v2 optimization_run_strategies_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."optimization_run_strategies_v2"
    ADD CONSTRAINT "optimization_run_strategies_v2_pkey" PRIMARY KEY ("id");


--
-- Name: optimization_run_strategies_v2 optimization_run_strategies_v2_run_id_ordinal_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."optimization_run_strategies_v2"
    ADD CONSTRAINT "optimization_run_strategies_v2_run_id_ordinal_key" UNIQUE ("run_id", "ordinal");


--
-- Name: optimization_run_strategies_v2 optimization_run_strategies_v2_run_id_strategy_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."optimization_run_strategies_v2"
    ADD CONSTRAINT "optimization_run_strategies_v2_run_id_strategy_id_key" UNIQUE ("run_id", "strategy_id");


--
-- Name: optimization_runs optimization_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."optimization_runs"
    ADD CONSTRAINT "optimization_runs_pkey" PRIMARY KEY ("id");


--
-- Name: optimization_runs_v2 optimization_runs_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."optimization_runs_v2"
    ADD CONSTRAINT "optimization_runs_v2_pkey" PRIMARY KEY ("id");


--
-- Name: optimization_runs_v2 optimization_runs_v2_requested_by_idempotency_key_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."optimization_runs_v2"
    ADD CONSTRAINT "optimization_runs_v2_requested_by_idempotency_key_key" UNIQUE ("requested_by", "idempotency_key");


--
-- Name: optimizer_profiles optimizer_profiles_matrix_version_id_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."optimizer_profiles"
    ADD CONSTRAINT "optimizer_profiles_matrix_version_id_code_key" UNIQUE ("matrix_version_id", "code");


--
-- Name: optimizer_profiles optimizer_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."optimizer_profiles"
    ADD CONSTRAINT "optimizer_profiles_pkey" PRIMARY KEY ("id");


--
-- Name: plan_assignment_duties_v2 plan_assignment_duties_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_assignment_duties_v2"
    ADD CONSTRAINT "plan_assignment_duties_v2_pkey" PRIMARY KEY ("assignment_id", "duty_id");


--
-- Name: plan_assignments_v2 plan_assignments_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_assignments_v2"
    ADD CONSTRAINT "plan_assignments_v2_pkey" PRIMARY KEY ("id");


--
-- Name: plan_assignments_v2 plan_assignments_v2_shift_id_employee_id_role_id_slot_key_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_assignments_v2"
    ADD CONSTRAINT "plan_assignments_v2_shift_id_employee_id_role_id_slot_key_key" UNIQUE ("shift_id", "employee_id", "role_id", "slot_key");


--
-- Name: plan_assignments_v2 plan_assignments_v2_variant_id_slot_key_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_assignments_v2"
    ADD CONSTRAINT "plan_assignments_v2_variant_id_slot_key_key" UNIQUE ("variant_id", "slot_key");


--
-- Name: plan_issues plan_issues_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_issues"
    ADD CONSTRAINT "plan_issues_pkey" PRIMARY KEY ("id");


--
-- Name: plan_issues_v2 plan_issues_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_issues_v2"
    ADD CONSTRAINT "plan_issues_v2_pkey" PRIMARY KEY ("id");


--
-- Name: plan_shifts_v2 plan_shifts_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_shifts_v2"
    ADD CONSTRAINT "plan_shifts_v2_pkey" PRIMARY KEY ("id");


--
-- Name: plan_shifts_v2 plan_shifts_v2_variant_id_slot_group_key_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_shifts_v2"
    ADD CONSTRAINT "plan_shifts_v2_variant_id_slot_group_key_key" UNIQUE ("variant_id", "slot_group_key");


--
-- Name: plan_variants_v2 plan_variants_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_variants_v2"
    ADD CONSTRAINT "plan_variants_v2_pkey" PRIMARY KEY ("id");


--
-- Name: plans plans_month_name_version_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plans"
    ADD CONSTRAINT "plans_month_name_version_key" UNIQUE ("month", "name", "version");


--
-- Name: plans plans_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plans"
    ADD CONSTRAINT "plans_pkey" PRIMARY KEY ("id");


--
-- Name: published_role_schedules_v2 published_role_schedules_v2_created_by_idempotency_key_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_role_schedules_v2"
    ADD CONSTRAINT "published_role_schedules_v2_created_by_idempotency_key_key" UNIQUE ("created_by", "idempotency_key");


--
-- Name: published_role_schedules_v2 published_role_schedules_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_role_schedules_v2"
    ADD CONSTRAINT "published_role_schedules_v2_pkey" PRIMARY KEY ("id");


--
-- Name: published_role_schedules_v2 published_role_schedules_v2_variant_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_role_schedules_v2"
    ADD CONSTRAINT "published_role_schedules_v2_variant_id_key" UNIQUE ("variant_id");


--
-- Name: published_schedule_variants_v2 published_schedule_variants_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_schedule_variants_v2"
    ADD CONSTRAINT "published_schedule_variants_v2_pkey" PRIMARY KEY ("schedule_id", "variant_id");


--
-- Name: published_schedule_variants_v2 published_schedule_variants_v2_schedule_id_ordinal_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_schedule_variants_v2"
    ADD CONSTRAINT "published_schedule_variants_v2_schedule_id_ordinal_key" UNIQUE ("schedule_id", "ordinal");


--
-- Name: published_schedules_v2 published_schedules_v2_created_by_idempotency_key_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_schedules_v2"
    ADD CONSTRAINT "published_schedules_v2_created_by_idempotency_key_key" UNIQUE ("created_by", "idempotency_key");


--
-- Name: published_schedules_v2 published_schedules_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_schedules_v2"
    ADD CONSTRAINT "published_schedules_v2_pkey" PRIMARY KEY ("id");


--
-- Name: published_standby_assignments_v2 published_standby_assignments_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_standby_assignments_v2"
    ADD CONSTRAINT "published_standby_assignments_v2_pkey" PRIMARY KEY ("id");


--
-- Name: recovery_actions_v2 recovery_actions_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_actions_v2"
    ADD CONSTRAINT "recovery_actions_v2_pkey" PRIMARY KEY ("id");


--
-- Name: recovery_ad_hoc_pool_v2 recovery_ad_hoc_pool_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_ad_hoc_pool_v2"
    ADD CONSTRAINT "recovery_ad_hoc_pool_v2_pkey" PRIMARY KEY ("id");


--
-- Name: recovery_incident_rate_revisions_v2 recovery_incident_rate_revisi_incident_id_employee_id_revis_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_incident_rate_revisions_v2"
    ADD CONSTRAINT "recovery_incident_rate_revisi_incident_id_employee_id_revis_key" UNIQUE ("incident_id", "employee_id", "revision");


--
-- Name: recovery_incident_rate_revisions_v2 recovery_incident_rate_revisions_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_incident_rate_revisions_v2"
    ADD CONSTRAINT "recovery_incident_rate_revisions_v2_pkey" PRIMARY KEY ("id");


--
-- Name: recovery_incidents_v2 recovery_incidents_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_incidents_v2"
    ADD CONSTRAINT "recovery_incidents_v2_pkey" PRIMARY KEY ("id");


--
-- Name: recovery_month_revisions_v2 recovery_month_revisions_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_month_revisions_v2"
    ADD CONSTRAINT "recovery_month_revisions_v2_pkey" PRIMARY KEY ("month");


--
-- Name: recovery_offer_responses_v2 recovery_offer_responses_v2_action_id_employee_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_offer_responses_v2"
    ADD CONSTRAINT "recovery_offer_responses_v2_action_id_employee_id_key" UNIQUE ("action_id", "employee_id");


--
-- Name: recovery_offer_responses_v2 recovery_offer_responses_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_offer_responses_v2"
    ADD CONSTRAINT "recovery_offer_responses_v2_pkey" PRIMARY KEY ("id");


--
-- Name: recovery_overrides_v2 recovery_overrides_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_overrides_v2"
    ADD CONSTRAINT "recovery_overrides_v2_pkey" PRIMARY KEY ("id");


--
-- Name: role_plan_assignments role_plan_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."role_plan_assignments"
    ADD CONSTRAINT "role_plan_assignments_pkey" PRIMARY KEY ("role_plan_section_id", "assignment_id");


--
-- Name: role_plan_sections role_plan_sections_month_role_id_version_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."role_plan_sections"
    ADD CONSTRAINT "role_plan_sections_month_role_id_version_key" UNIQUE ("month", "role_id", "version");


--
-- Name: role_plan_sections role_plan_sections_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."role_plan_sections"
    ADD CONSTRAINT "role_plan_sections_pkey" PRIMARY KEY ("id");


--
-- Name: roles roles_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."roles"
    ADD CONSTRAINT "roles_code_key" UNIQUE ("code");


--
-- Name: roles roles_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."roles"
    ADD CONSTRAINT "roles_pkey" PRIMARY KEY ("id");


--
-- Name: shift_definitions shift_definitions_location_id_code_day_of_week_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."shift_definitions"
    ADD CONSTRAINT "shift_definitions_location_id_code_day_of_week_key" UNIQUE ("location_id", "code", "day_of_week");


--
-- Name: shift_definitions shift_definitions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."shift_definitions"
    ADD CONSTRAINT "shift_definitions_pkey" PRIMARY KEY ("id");


--
-- Name: shift_swap_history_v2 shift_swap_history_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."shift_swap_history_v2"
    ADD CONSTRAINT "shift_swap_history_v2_pkey" PRIMARY KEY ("id");


--
-- Name: shift_swap_requests_v2 shift_swap_requests_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."shift_swap_requests_v2"
    ADD CONSTRAINT "shift_swap_requests_v2_pkey" PRIMARY KEY ("id");


--
-- Name: shifts shifts_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."shifts"
    ADD CONSTRAINT "shifts_pkey" PRIMARY KEY ("id");


--
-- Name: solver_feature_flags solver_feature_flags_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."solver_feature_flags"
    ADD CONSTRAINT "solver_feature_flags_pkey" PRIMARY KEY ("flag_key");


--
-- Name: tasks tasks_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_pkey" PRIMARY KEY ("id");


--
-- Name: team_conversation_members_v1 team_conversation_members_v1_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."team_conversation_members_v1"
    ADD CONSTRAINT "team_conversation_members_v1_pkey" PRIMARY KEY ("conversation_id", "auth_user_id");


--
-- Name: team_conversations_v1 team_conversations_v1_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."team_conversations_v1"
    ADD CONSTRAINT "team_conversations_v1_pkey" PRIMARY KEY ("id");


--
-- Name: team_messages_v1 team_messages_v1_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."team_messages_v1"
    ADD CONSTRAINT "team_messages_v1_pkey" PRIMARY KEY ("id");


--
-- Name: time_records time_records_employee_id_work_date_planned_start_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."time_records"
    ADD CONSTRAINT "time_records_employee_id_work_date_planned_start_key" UNIQUE ("employee_id", "work_date", "planned_start");


--
-- Name: time_records time_records_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."time_records"
    ADD CONSTRAINT "time_records_pkey" PRIMARY KEY ("id");


--
-- Name: uat_environment_controls uat_environment_controls_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."uat_environment_controls"
    ADD CONSTRAINT "uat_environment_controls_pkey" PRIMARY KEY ("control_key");


--
-- Name: user_permissions user_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."user_permissions"
    ADD CONSTRAINT "user_permissions_pkey" PRIMARY KEY ("id");


--
-- Name: user_profiles_v1 user_profiles_v1_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."user_profiles_v1"
    ADD CONSTRAINT "user_profiles_v1_pkey" PRIMARY KEY ("auth_user_id");


--
-- Name: workforce_calendar_events_v2 workforce_calendar_events_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."workforce_calendar_events_v2"
    ADD CONSTRAINT "workforce_calendar_events_v2_pkey" PRIMARY KEY ("id");


--
-- Name: workforce_event_demand_v2 workforce_event_demand_v2_event_id_shift_template_id_role_i_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."workforce_event_demand_v2"
    ADD CONSTRAINT "workforce_event_demand_v2_event_id_shift_template_id_role_i_key" UNIQUE NULLS NOT DISTINCT ("event_id", "shift_template_id", "role_id", "duty_id");


--
-- Name: workforce_event_demand_v2 workforce_event_demand_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."workforce_event_demand_v2"
    ADD CONSTRAINT "workforce_event_demand_v2_pkey" PRIMARY KEY ("id");


--
-- Name: workforce_hot_day_limits_v2 workforce_hot_day_limits_v2_event_id_role_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."workforce_hot_day_limits_v2"
    ADD CONSTRAINT "workforce_hot_day_limits_v2_event_id_role_id_key" UNIQUE ("event_id", "role_id");


--
-- Name: workforce_hot_day_limits_v2 workforce_hot_day_limits_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."workforce_hot_day_limits_v2"
    ADD CONSTRAINT "workforce_hot_day_limits_v2_pkey" PRIMARY KEY ("id");


--
-- Name: leader_variant_history_cursor_v2 leader_variant_history_cursor_v2_pkey; Type: CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."leader_variant_history_cursor_v2"
    ADD CONSTRAINT "leader_variant_history_cursor_v2_pkey" PRIMARY KEY ("variant_id");


--
-- Name: leader_variant_history_v2 leader_variant_history_v2_pkey; Type: CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."leader_variant_history_v2"
    ADD CONSTRAINT "leader_variant_history_v2_pkey" PRIMARY KEY ("seq");


--
-- Name: mx_k10_legacy_role_duty_archive mx_k10_legacy_role_duty_archive_pkey; Type: CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."mx_k10_legacy_role_duty_archive"
    ADD CONSTRAINT "mx_k10_legacy_role_duty_archive_pkey" PRIMARY KEY ("legacy_role_duty_id");


--
-- Name: optimization_attempts_v2 optimization_attempts_v2_pkey; Type: CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."optimization_attempts_v2"
    ADD CONSTRAINT "optimization_attempts_v2_pkey" PRIMARY KEY ("id");


--
-- Name: optimization_attempts_v2 optimization_attempts_v2_run_id_attempt_number_key; Type: CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."optimization_attempts_v2"
    ADD CONSTRAINT "optimization_attempts_v2_run_id_attempt_number_key" UNIQUE ("run_id", "attempt_number");


--
-- Name: optimization_snapshots_v2 optimization_snapshots_v2_pkey; Type: CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."optimization_snapshots_v2"
    ADD CONSTRAINT "optimization_snapshots_v2_pkey" PRIMARY KEY ("run_id");


--
-- Name: plan_assignment_cost_components_v2 plan_assignment_cost_componen_assignment_id_pay_rule_id_com_key; Type: CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."plan_assignment_cost_components_v2"
    ADD CONSTRAINT "plan_assignment_cost_componen_assignment_id_pay_rule_id_com_key" UNIQUE ("assignment_id", "pay_rule_id", "component_code");


--
-- Name: plan_assignment_cost_components_v2 plan_assignment_cost_components_v2_pkey; Type: CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."plan_assignment_cost_components_v2"
    ADD CONSTRAINT "plan_assignment_cost_components_v2_pkey" PRIMARY KEY ("id");


--
-- Name: plan_variant_finance_v2 plan_variant_finance_v2_pkey; Type: CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."plan_variant_finance_v2"
    ADD CONSTRAINT "plan_variant_finance_v2_pkey" PRIMARY KEY ("variant_id");


--
-- Name: planning_data_revision_v2 planning_data_revision_v2_pkey; Type: CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."planning_data_revision_v2"
    ADD CONSTRAINT "planning_data_revision_v2_pkey" PRIMARY KEY ("singleton");


--
-- Name: published_schedule_finance_v2 published_schedule_finance_v2_pkey; Type: CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."published_schedule_finance_v2"
    ADD CONSTRAINT "published_schedule_finance_v2_pkey" PRIMARY KEY ("schedule_id");


--
-- Name: solver_job_dispatch_outbox_uat_v1 solver_job_dispatch_outbox_uat_v1_dispatch_nonce_key; Type: CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."solver_job_dispatch_outbox_uat_v1"
    ADD CONSTRAINT "solver_job_dispatch_outbox_uat_v1_dispatch_nonce_key" UNIQUE ("dispatch_nonce");


--
-- Name: solver_job_dispatch_outbox_uat_v1 solver_job_dispatch_outbox_uat_v1_northflank_run_id_key; Type: CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."solver_job_dispatch_outbox_uat_v1"
    ADD CONSTRAINT "solver_job_dispatch_outbox_uat_v1_northflank_run_id_key" UNIQUE ("northflank_run_id");


--
-- Name: solver_job_dispatch_outbox_uat_v1 solver_job_dispatch_outbox_uat_v1_pkey; Type: CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."solver_job_dispatch_outbox_uat_v1"
    ADD CONSTRAINT "solver_job_dispatch_outbox_uat_v1_pkey" PRIMARY KEY ("run_id");


--
-- Name: solver_job_runtime_config_uat_v1 solver_job_runtime_config_uat_v1_pkey; Type: CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."solver_job_runtime_config_uat_v1"
    ADD CONSTRAINT "solver_job_runtime_config_uat_v1_pkey" PRIMARY KEY ("singleton");


--
-- Name: solver_runtime_builds_uat_v1 solver_runtime_builds_uat_v1_pkey; Type: CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."solver_runtime_builds_uat_v1"
    ADD CONSTRAINT "solver_runtime_builds_uat_v1_pkey" PRIMARY KEY ("solver_version", "execution_mode");


--
-- Name: application_access_directory_v1_identity_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "application_access_directory_v1_identity_idx" ON "public"."application_access_directory_v1" USING "btree" ("lower"("email"), "app_role", COALESCE("role_logical_id", '00000000-0000-0000-0000-000000000000'::"uuid"), COALESCE("location_logical_id", '00000000-0000-0000-0000-000000000000'::"uuid"));


--
-- Name: assignments_employee_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "assignments_employee_idx" ON "public"."assignments" USING "btree" ("employee_id");


--
-- Name: attendance_employee_time_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "attendance_employee_time_idx" ON "public"."attendance_events" USING "btree" ("employee_id", "occurred_at" DESC);


--
-- Name: availability_employee_date_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "availability_employee_date_idx" ON "public"."employee_availability" USING "btree" ("employee_id", "work_date");


--
-- Name: availability_exception_one_pending_v2; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "availability_exception_one_pending_v2" ON "public"."availability_exception_reviews_v2" USING "btree" ("employee_id", "work_date", "role_id") WHERE ("status" = 'PENDING'::"text");


--
-- Name: availability_exception_role_date_v2; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "availability_exception_role_date_v2" ON "public"."availability_exception_reviews_v2" USING "btree" ("role_id", "work_date", "status");


--
-- Name: employee_pay_rates_v2_employee_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "employee_pay_rates_v2_employee_idx" ON "public"."employee_pay_rates_v2" USING "btree" ("employee_id", "active", "valid_from" DESC);


--
-- Name: employee_requests_action_v1_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "employee_requests_action_v1_idx" ON "public"."employee_requests_v1" USING "btree" ("status", "requires_decision", "created_at" DESC) WHERE ("status" = ANY (ARRAY['PENDING'::"text", 'APPLIED'::"text"]));


--
-- Name: employee_requests_employee_v1_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "employee_requests_employee_v1_idx" ON "public"."employee_requests_v1" USING "btree" ("employee_id", "status", "date_from", "created_at" DESC);


--
-- Name: employee_time_constraints_v2_employee_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "employee_time_constraints_v2_employee_idx" ON "public"."employee_time_constraints_v2" USING "btree" ("employee_id", "status", "updated_at" DESC);


--
-- Name: employee_time_constraints_v2_range_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "employee_time_constraints_v2_range_idx" ON "public"."employee_time_constraints_v2" USING "gist" ("time_range");


--
-- Name: employee_time_constraints_v2_source_record_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "employee_time_constraints_v2_source_record_idx" ON "public"."employee_time_constraints_v2" USING "btree" ("source", "source_record_key") WHERE ("source_record_key" IS NOT NULL);


--
-- Name: employee_weekly_work_patterns_active_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "employee_weekly_work_patterns_active_idx" ON "public"."employee_weekly_work_patterns_v2" USING "btree" ("employee_id", "valid_from", "valid_to") WHERE "active";


--
-- Name: employer_cost_components_current_v2; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "employer_cost_components_current_v2" ON "public"."employer_cost_components_v2" USING "btree" ("logical_id") WHERE "active";


--
-- Name: events_location_time_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "events_location_time_idx" ON "public"."operational_events" USING "btree" ("location_id", "starts_at");


--
-- Name: matrix_duties_v2_logical_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "matrix_duties_v2_logical_idx" ON "public"."matrix_duties_v2" USING "btree" ("logical_id", "matrix_version_id");


--
-- Name: matrix_employee_duties_v2_duty_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "matrix_employee_duties_v2_duty_idx" ON "public"."matrix_employee_duties_v2" USING "btree" ("matrix_version_id", "duty_id", "active");


--
-- Name: matrix_employee_duties_v2_employee_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "matrix_employee_duties_v2_employee_idx" ON "public"."matrix_employee_duties_v2" USING "btree" ("employee_id", "matrix_version_id", "active");


--
-- Name: matrix_employee_locations_v2_employee_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "matrix_employee_locations_v2_employee_idx" ON "public"."matrix_employee_locations_v2" USING "btree" ("employee_id", "matrix_version_id", "active");


--
-- Name: matrix_employee_locations_v2_home_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "matrix_employee_locations_v2_home_idx" ON "public"."matrix_employee_locations_v2" USING "btree" ("matrix_version_id", "employee_id") WHERE ("home_location" AND "active");


--
-- Name: matrix_employee_locations_v2_location_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "matrix_employee_locations_v2_location_idx" ON "public"."matrix_employee_locations_v2" USING "btree" ("matrix_version_id", "location_id", "active");


--
-- Name: matrix_employee_one_primary; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "matrix_employee_one_primary" ON "public"."matrix_employee_roles" USING "btree" ("matrix_version_id", "employee_id") WHERE "is_primary";


--
-- Name: matrix_employee_profiles_v2_email_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "matrix_employee_profiles_v2_email_idx" ON "public"."matrix_employee_profiles_v2" USING "btree" ("matrix_version_id", "lower"("email")) WHERE ("email" IS NOT NULL);


--
-- Name: matrix_employee_profiles_v2_status_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "matrix_employee_profiles_v2_status_idx" ON "public"."matrix_employee_profiles_v2" USING "btree" ("matrix_version_id", "active", "last_name", "first_name");


--
-- Name: matrix_employee_roles_v2_employee_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "matrix_employee_roles_v2_employee_idx" ON "public"."matrix_employee_roles_v2" USING "btree" ("employee_id", "matrix_version_id", "active");


--
-- Name: matrix_employee_roles_v2_one_primary_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "matrix_employee_roles_v2_one_primary_idx" ON "public"."matrix_employee_roles_v2" USING "btree" ("matrix_version_id", "employee_id") WHERE ("is_primary" AND "active");


--
-- Name: matrix_employee_roles_v2_role_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "matrix_employee_roles_v2_role_idx" ON "public"."matrix_employee_roles_v2" USING "btree" ("matrix_version_id", "role_id", "active");


--
-- Name: matrix_locations_v2_logical_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "matrix_locations_v2_logical_idx" ON "public"."matrix_locations_v2" USING "btree" ("logical_id", "matrix_version_id");


--
-- Name: matrix_pay_rule_duties_v2_duty_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "matrix_pay_rule_duties_v2_duty_idx" ON "public"."matrix_pay_rule_duties_v2" USING "btree" ("matrix_version_id", "duty_id");


--
-- Name: matrix_pay_rule_locations_v2_location_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "matrix_pay_rule_locations_v2_location_idx" ON "public"."matrix_pay_rule_locations_v2" USING "btree" ("matrix_version_id", "location_id");


--
-- Name: matrix_pay_rule_roles_v2_role_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "matrix_pay_rule_roles_v2_role_idx" ON "public"."matrix_pay_rule_roles_v2" USING "btree" ("matrix_version_id", "role_id");


--
-- Name: matrix_pay_rule_shifts_v2_shift_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "matrix_pay_rule_shifts_v2_shift_idx" ON "public"."matrix_pay_rule_shifts_v2" USING "btree" ("matrix_version_id", "shift_template_id");


--
-- Name: matrix_pay_rules_v2_active_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "matrix_pay_rules_v2_active_idx" ON "public"."matrix_pay_rules_v2" USING "btree" ("matrix_version_id", "active", "priority");


--
-- Name: matrix_role_duties_v2_duty_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "matrix_role_duties_v2_duty_idx" ON "public"."matrix_role_duties_v2" USING "btree" ("matrix_version_id", "duty_id");


--
-- Name: matrix_roles_v2_logical_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "matrix_roles_v2_logical_idx" ON "public"."matrix_roles_v2" USING "btree" ("logical_id", "matrix_version_id");


--
-- Name: matrix_scenario_budgets_v2_lookup_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "matrix_scenario_budgets_v2_lookup_idx" ON "public"."matrix_scenario_budgets_v2" USING "btree" ("matrix_version_id", "scenario_id", "budget_month");


--
-- Name: matrix_scenario_strategies_v2_scenario_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "matrix_scenario_strategies_v2_scenario_idx" ON "public"."matrix_scenario_strategies_v2" USING "btree" ("scenario_id", "active", "sort_order");


--
-- Name: matrix_scenarios_v2_one_default_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "matrix_scenarios_v2_one_default_idx" ON "public"."matrix_scenarios_v2" USING "btree" ("matrix_version_id") WHERE ("is_default" AND "active");


--
-- Name: matrix_scenarios_v2_parent_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "matrix_scenarios_v2_parent_idx" ON "public"."matrix_scenarios_v2" USING "btree" ("matrix_version_id", "parent_scenario_id");


--
-- Name: matrix_scope_grants_v2_user_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "matrix_scope_grants_v2_user_idx" ON "public"."matrix_scope_grants_v2" USING "btree" ("auth_user_id", "active", "app_role");


--
-- Name: matrix_shift_templates_v2_location_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "matrix_shift_templates_v2_location_idx" ON "public"."matrix_shift_templates_v2" USING "btree" ("matrix_version_id", "location_id", "active");


--
-- Name: matrix_staffing_rules_v2_scenario_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "matrix_staffing_rules_v2_scenario_idx" ON "public"."matrix_staffing_rules_v2" USING "btree" ("matrix_version_id", "scenario_id", "active");


--
-- Name: matrix_staffing_rules_v2_shift_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "matrix_staffing_rules_v2_shift_idx" ON "public"."matrix_staffing_rules_v2" USING "btree" ("matrix_version_id", "shift_template_id");


--
-- Name: matrix_strategies_v2_legacy_profile_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "matrix_strategies_v2_legacy_profile_idx" ON "public"."matrix_strategies_v2" USING "btree" ("matrix_version_id", "legacy_optimizer_profile_id") WHERE ("legacy_optimizer_profile_id" IS NOT NULL);


--
-- Name: matrix_strategy_objectives_v2_strategy_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "matrix_strategy_objectives_v2_strategy_idx" ON "public"."matrix_strategy_objectives_v2" USING "btree" ("strategy_id", "tier", "sort_order");


--
-- Name: monthly_budget_revisions_v2_one_active; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "monthly_budget_revisions_v2_one_active" ON "public"."monthly_budget_revisions_v2" USING "btree" ("budget_month") WHERE ("status" = 'ACTIVE'::"text");


--
-- Name: notifications_action_center_v1_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "notifications_action_center_v1_idx" ON "public"."notifications" USING "btree" ("recipient_id", "action_required", "resolved_at", "read_at", "created_at" DESC);


--
-- Name: notifications_context_v1_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "notifications_context_v1_idx" ON "public"."notifications" USING "btree" ("context_type", "context_id", "recipient_id");


--
-- Name: notifications_recipient_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "notifications_recipient_idx" ON "public"."notifications" USING "btree" ("recipient_id", "read_at");


--
-- Name: operational_assignment_overrides_v2_created_by_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "operational_assignment_overrides_v2_created_by_idx" ON "public"."operational_assignment_overrides_v2" USING "btree" ("created_by");


--
-- Name: operational_assignment_overrides_v2_employee_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "operational_assignment_overrides_v2_employee_idx" ON "public"."operational_assignment_overrides_v2" USING "btree" ("employee_id", "created_at" DESC);


--
-- Name: operational_assignment_overrides_v2_issue_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "operational_assignment_overrides_v2_issue_idx" ON "public"."operational_assignment_overrides_v2" USING "btree" ("issue_id");


--
-- Name: operational_assignment_overrides_v2_revoked_by_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "operational_assignment_overrides_v2_revoked_by_idx" ON "public"."operational_assignment_overrides_v2" USING "btree" ("revoked_by") WHERE ("revoked_by" IS NOT NULL);


--
-- Name: operational_assignment_overrides_v2_role_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "operational_assignment_overrides_v2_role_idx" ON "public"."operational_assignment_overrides_v2" USING "btree" ("role_id");


--
-- Name: operational_assignment_overrides_v2_shift_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "operational_assignment_overrides_v2_shift_idx" ON "public"."operational_assignment_overrides_v2" USING "btree" ("shift_id");


--
-- Name: operational_assignment_overrides_v2_slot_active; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "operational_assignment_overrides_v2_slot_active" ON "public"."operational_assignment_overrides_v2" USING "btree" ("schedule_id", "slot_key") WHERE ("status" = 'ACTIVE'::"text");


--
-- Name: operational_program_audience_event_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "operational_program_audience_event_idx" ON "public"."operational_program_audience_rules_v1" USING "btree" ("event_id", "rule_mode", "scope_type");


--
-- Name: operational_program_events_month_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "operational_program_events_month_idx" ON "public"."operational_program_events_v1" USING "btree" ("starts_at", "status", "event_type");


--
-- Name: operational_program_participant_employee_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "operational_program_participant_employee_idx" ON "public"."operational_program_participants_v1" USING "btree" ("event_id", "employee_id") WHERE ("employee_id" IS NOT NULL);


--
-- Name: operational_program_participant_user_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "operational_program_participant_user_idx" ON "public"."operational_program_participants_v1" USING "btree" ("event_id", "auth_user_id") WHERE (("employee_id" IS NULL) AND ("auth_user_id" IS NOT NULL));


--
-- Name: operational_program_participants_event_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "operational_program_participants_event_idx" ON "public"."operational_program_participants_v1" USING "btree" ("event_id", "assignment_status");


--
-- Name: optimization_candidates_plan_id_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "optimization_candidates_plan_id_idx" ON "public"."optimization_candidates" USING "btree" ("plan_id");


--
-- Name: optimization_candidates_run_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "optimization_candidates_run_idx" ON "public"."optimization_candidates" USING "btree" ("run_id", "rank");


--
-- Name: optimization_run_strategies_v2_run_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "optimization_run_strategies_v2_run_idx" ON "public"."optimization_run_strategies_v2" USING "btree" ("run_id", "ordinal");


--
-- Name: optimization_run_strategies_v2_strategy_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "optimization_run_strategies_v2_strategy_idx" ON "public"."optimization_run_strategies_v2" USING "btree" ("strategy_id");


--
-- Name: optimization_runs_month_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "optimization_runs_month_idx" ON "public"."optimization_runs" USING "btree" ("month", "created_at" DESC);


--
-- Name: optimization_runs_v2_matrix_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "optimization_runs_v2_matrix_idx" ON "public"."optimization_runs_v2" USING "btree" ("matrix_version_id");


--
-- Name: optimization_runs_v2_requester_month_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "optimization_runs_v2_requester_month_idx" ON "public"."optimization_runs_v2" USING "btree" ("requested_by", "month", "created_at" DESC);


--
-- Name: optimization_runs_v2_scenario_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "optimization_runs_v2_scenario_idx" ON "public"."optimization_runs_v2" USING "btree" ("scenario_id");


--
-- Name: optimization_runs_v2_scope_role_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "optimization_runs_v2_scope_role_idx" ON "public"."optimization_runs_v2" USING "btree" ("scope_role_id") WHERE ("scope_role_id" IS NOT NULL);


--
-- Name: optimization_runs_v2_status_queue_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "optimization_runs_v2_status_queue_idx" ON "public"."optimization_runs_v2" USING "btree" ("status", "queued_at") WHERE ("status" = ANY (ARRAY['QUEUED'::"text", 'RUNNING'::"text", 'CANCEL_REQUESTED'::"text"]));


--
-- Name: optimization_runs_v2_worker_execution_name_uidx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "optimization_runs_v2_worker_execution_name_uidx" ON "public"."optimization_runs_v2" USING "btree" ("worker_execution_name") WHERE ("worker_execution_name" IS NOT NULL);


--
-- Name: plan_assignment_duties_v2_duty_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "plan_assignment_duties_v2_duty_idx" ON "public"."plan_assignment_duties_v2" USING "btree" ("duty_id");


--
-- Name: plan_assignments_v2_employee_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "plan_assignments_v2_employee_idx" ON "public"."plan_assignments_v2" USING "btree" ("employee_id");


--
-- Name: plan_assignments_v2_role_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "plan_assignments_v2_role_idx" ON "public"."plan_assignments_v2" USING "btree" ("role_id");


--
-- Name: plan_assignments_v2_shift_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "plan_assignments_v2_shift_idx" ON "public"."plan_assignments_v2" USING "btree" ("shift_id");


--
-- Name: plan_assignments_v2_variant_employee_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "plan_assignments_v2_variant_employee_idx" ON "public"."plan_assignments_v2" USING "btree" ("variant_id", "employee_id");


--
-- Name: plan_issues_plan_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "plan_issues_plan_idx" ON "public"."plan_issues" USING "btree" ("plan_id", "severity", "resolved_at");


--
-- Name: plan_issues_v2_duty_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "plan_issues_v2_duty_idx" ON "public"."plan_issues_v2" USING "btree" ("duty_id") WHERE ("duty_id" IS NOT NULL);


--
-- Name: plan_issues_v2_role_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "plan_issues_v2_role_idx" ON "public"."plan_issues_v2" USING "btree" ("role_id") WHERE ("role_id" IS NOT NULL);


--
-- Name: plan_issues_v2_shift_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "plan_issues_v2_shift_idx" ON "public"."plan_issues_v2" USING "btree" ("shift_id") WHERE ("shift_id" IS NOT NULL);


--
-- Name: plan_issues_v2_variant_severity_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "plan_issues_v2_variant_severity_idx" ON "public"."plan_issues_v2" USING "btree" ("variant_id", "severity");


--
-- Name: plan_shifts_v2_location_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "plan_shifts_v2_location_idx" ON "public"."plan_shifts_v2" USING "btree" ("location_id");


--
-- Name: plan_shifts_v2_template_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "plan_shifts_v2_template_idx" ON "public"."plan_shifts_v2" USING "btree" ("shift_template_id");


--
-- Name: plan_shifts_v2_variant_date_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "plan_shifts_v2_variant_date_idx" ON "public"."plan_shifts_v2" USING "btree" ("variant_id", "shift_date", "starts_at");


--
-- Name: plan_variants_generated_run_strategy_row_v2; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "plan_variants_generated_run_strategy_row_v2" ON "public"."plan_variants_v2" USING "btree" ("run_strategy_id") WHERE ("variant_kind" = 'GENERATED'::"text");


--
-- Name: plan_variants_generated_run_strategy_v2; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "plan_variants_generated_run_strategy_v2" ON "public"."plan_variants_v2" USING "btree" ("run_id", "strategy_id") WHERE ("variant_kind" = 'GENERATED'::"text");


--
-- Name: plan_variants_source_variant_v2; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "plan_variants_source_variant_v2" ON "public"."plan_variants_v2" USING "btree" ("source_variant_id") WHERE ("source_variant_id" IS NOT NULL);


--
-- Name: plan_variants_v2_equivalent_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "plan_variants_v2_equivalent_idx" ON "public"."plan_variants_v2" USING "btree" ("equivalent_to_variant_id") WHERE ("equivalent_to_variant_id" IS NOT NULL);


--
-- Name: plan_variants_v2_one_recommended_per_run; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "plan_variants_v2_one_recommended_per_run" ON "public"."plan_variants_v2" USING "btree" ("run_id") WHERE "recommended";


--
-- Name: plan_variants_v2_one_selected_per_run; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "plan_variants_v2_one_selected_per_run" ON "public"."plan_variants_v2" USING "btree" ("run_id") WHERE "selected";


--
-- Name: plan_variants_v2_run_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "plan_variants_v2_run_idx" ON "public"."plan_variants_v2" USING "btree" ("run_id", "created_at");


--
-- Name: plan_variants_v2_selected_by_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "plan_variants_v2_selected_by_idx" ON "public"."plan_variants_v2" USING "btree" ("selected_by") WHERE ("selected_by" IS NOT NULL);


--
-- Name: plan_variants_v2_solution_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "plan_variants_v2_solution_idx" ON "public"."plan_variants_v2" USING "btree" ("run_id", "solution_hash");


--
-- Name: plan_variants_v2_strategy_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "plan_variants_v2_strategy_idx" ON "public"."plan_variants_v2" USING "btree" ("strategy_id");


--
-- Name: published_role_schedules_v2_archived_by_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "published_role_schedules_v2_archived_by_idx" ON "public"."published_role_schedules_v2" USING "btree" ("archived_by") WHERE ("archived_by" IS NOT NULL);


--
-- Name: published_role_schedules_v2_current_role_month; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "published_role_schedules_v2_current_role_month" ON "public"."published_role_schedules_v2" USING "btree" ("month", "role_id") WHERE ("status" = 'PUBLISHED'::"text");


--
-- Name: published_role_schedules_v2_matrix_version_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "published_role_schedules_v2_matrix_version_idx" ON "public"."published_role_schedules_v2" USING "btree" ("matrix_version_id");


--
-- Name: published_role_schedules_v2_role_month_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "published_role_schedules_v2_role_month_idx" ON "public"."published_role_schedules_v2" USING "btree" ("role_id", "month");


--
-- Name: published_role_schedules_v2_scenario_month_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "published_role_schedules_v2_scenario_month_idx" ON "public"."published_role_schedules_v2" USING "btree" ("scenario_id", "month");


--
-- Name: published_role_schedules_v2_variant_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "published_role_schedules_v2_variant_idx" ON "public"."published_role_schedules_v2" USING "btree" ("variant_id");


--
-- Name: published_schedule_variants_v2_one_role; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "published_schedule_variants_v2_one_role" ON "public"."published_schedule_variants_v2" USING "btree" ("schedule_id", "role_id") WHERE ("role_id" IS NOT NULL);


--
-- Name: published_schedule_variants_v2_variant_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "published_schedule_variants_v2_variant_idx" ON "public"."published_schedule_variants_v2" USING "btree" ("variant_id");


--
-- Name: published_schedules_v2_matrix_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "published_schedules_v2_matrix_idx" ON "public"."published_schedules_v2" USING "btree" ("matrix_version_id");


--
-- Name: published_schedules_v2_one_current_month; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "published_schedules_v2_one_current_month" ON "public"."published_schedules_v2" USING "btree" ("month") WHERE ("status" = 'PUBLISHED'::"text");


--
-- Name: published_schedules_v2_scenario_month_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "published_schedules_v2_scenario_month_idx" ON "public"."published_schedules_v2" USING "btree" ("scenario_id", "month", "created_at" DESC);


--
-- Name: published_standby_employee_month_v2; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "published_standby_employee_month_v2" ON "public"."published_standby_assignments_v2" USING "btree" ("employee_id", "month", "standby_date");


--
-- Name: published_standby_one_role_per_employee_day_v2; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "published_standby_one_role_per_employee_day_v2" ON "public"."published_standby_assignments_v2" USING "btree" ("month", "employee_id", "standby_date") WHERE ("status" = ANY (ARRAY['PLANNED'::"text", 'ACTIVATED'::"text"]));


--
-- Name: published_standby_one_tier_role_day_v2; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "published_standby_one_tier_role_day_v2" ON "public"."published_standby_assignments_v2" USING "btree" ("month", "role_id", "standby_date", "tier") WHERE ("status" = ANY (ARRAY['PLANNED'::"text", 'ACTIVATED'::"text"]));


--
-- Name: recovery_actions_incident_status_v2; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "recovery_actions_incident_status_v2" ON "public"."recovery_actions_v2" USING "btree" ("incident_id", "status");


--
-- Name: recovery_ad_hoc_role_active_v2; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "recovery_ad_hoc_role_active_v2" ON "public"."recovery_ad_hoc_pool_v2" USING "btree" ("role_id", "active");


--
-- Name: recovery_incidents_month_status_v2; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "recovery_incidents_month_status_v2" ON "public"."recovery_incidents_v2" USING "btree" ("month", "status", "starts_on");


--
-- Name: recovery_offers_employee_status_v2; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "recovery_offers_employee_status_v2" ON "public"."recovery_offer_responses_v2" USING "btree" ("employee_id", "status", "offered_at" DESC);


--
-- Name: shift_swap_board_month_role_v2; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "shift_swap_board_month_role_v2" ON "public"."shift_swap_requests_v2" USING "btree" ("month", "role_id", "status", "created_at" DESC);


--
-- Name: shift_swap_one_active_per_assignment_v2; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "shift_swap_one_active_per_assignment_v2" ON "public"."shift_swap_requests_v2" USING "btree" ("original_assignment_id") WHERE ("status" = ANY (ARRAY['OPEN'::"text", 'EMPLOYEE_ACCEPTED'::"text"]));


--
-- Name: shifts_plan_date_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "shifts_plan_date_idx" ON "public"."shifts" USING "btree" ("plan_id", "shift_date");


--
-- Name: shifts_plan_location_date_code_unique; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "shifts_plan_location_date_code_unique" ON "public"."shifts" USING "btree" ("plan_id", "location_id", "shift_date", "shift_code");


