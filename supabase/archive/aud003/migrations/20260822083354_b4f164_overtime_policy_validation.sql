-- B4F-164 UAT: defense-in-depth overtime-policy validation.
-- Automatic results and ordinary saves may not exceed the contractual nominal
-- for NEVER or APPROVAL_REQUIRED.  APPROVAL_REQUIRED is permitted only when a
-- leader edit carries the existing explicit, audited approval decision.

create or replace function solver_private.materialized_variant_payload_v2(
  p_variant_ids uuid[],p_snapshot jsonb,p_strategy_id uuid
) returns jsonb language sql stable security definer set search_path=''
as $$
  with requested as (
    select distinct x.variant_id from unnest(coalesce(p_variant_ids,'{}'::uuid[])) x(variant_id)
  ), assignment_rows as (
    select pa.id,pa.slot_key as slot_id,pa.employee_id,coalesce(pa.explanation,'{}'::jsonb) explanation
    from public.plan_assignments_v2 pa join requested r on r.variant_id=pa.variant_id
  ), assignment_payload as (
    select ar.slot_id as slot_key,ar.employee_id,ar.explanation,
      coalesce((select sum((c.calculation_basis->>'costUnits')::bigint)
        from solver_private.plan_assignment_cost_components_v2 c where c.assignment_id=ar.id),0)::bigint cost_units,
      coalesce((select jsonb_agg(jsonb_build_object(
        'ruleId',coalesce(c.pay_rule_id::text,'BASE'),'calculationType',c.component_code,
        'costUnits',(c.calculation_basis->>'costUnits')::bigint) order by c.id)
        from solver_private.plan_assignment_cost_components_v2 c where c.assignment_id=ar.id),'[]'::jsonb) cost_components
    from assignment_rows ar
  ), snapshot_slots as (
    select s.value->>'slotId' slot_id from jsonb_array_elements(coalesce(p_snapshot->'slots','[]'::jsonb)) s
  ), selected_map as (
    select jsonb_object_agg(s.slot_id,to_jsonb(a.employee_id) order by s.slot_id) payload
    from snapshot_slots s left join assignment_rows a using(slot_id)
  )
  select jsonb_build_object(
    'schemaVersion',2,'strategyId',p_strategy_id,
    'solutionHash',(select encode(extensions.digest(convert_to(
      solver_private.canonical_json_v2(m.payload),'UTF8'),'sha256'),'hex') from selected_map m),
    'assignments',coalesce((select jsonb_agg(jsonb_build_object(
      'slotId',a.slot_key,'employeeId',a.employee_id,'costUnits',a.cost_units,
      'costComponents',a.cost_components,
      'limitOverride',coalesce((a.explanation->>'limitOverride')::boolean,false),
      'limitOverrideDetails',coalesce(a.explanation->'limitOverrideDetails','[]'::jsonb),
      'overtimeDecision',nullif(a.explanation->>'overtimeDecision',''),
      'overtimeApprovedBy',nullif(a.explanation->>'overtimeApprovedBy',''),
      'overtimeApprovedAt',nullif(a.explanation->>'overtimeApprovedAt',''),
      'overtimeQuote',coalesce(a.explanation->'overtimeQuote','{}'::jsonb)
    ) order by a.slot_key,a.employee_id) from assignment_payload a),'[]'::jsonb),
    'unfilledSlotIds',coalesce((select jsonb_agg(s.value->>'slotId' order by s.ordinality)
      from jsonb_array_elements(coalesce(p_snapshot->'slots','[]'::jsonb)) with ordinality s(value,ordinality)
      where not exists(select 1 from assignment_rows a where a.slot_id=s.value->>'slotId')),'[]'::jsonb),
    'metrics',jsonb_build_object(
      'UNFILLED',(select count(*) from snapshot_slots s where not exists(
        select 1 from assignment_rows a where a.slot_id=s.slot_id)),
      'TOTAL_COST',coalesce((select sum(a.cost_units) from assignment_payload a),0)),
    'stageObjectives','[]'::jsonb,'optimal',false
  );
$$;

alter function solver_private.validate_variant_v2(jsonb,jsonb)
  rename to validate_variant_before_b4f164_overtime_policy_uat_v1;

create function solver_private.validate_variant_v2(
  p_snapshot jsonb,
  p_variant jsonb
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
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

create or replace function public.optimizer_leader_assignment_save_uat_v3(
  p_variant_id uuid,
  p_assignment_id uuid,
  p_issue_id bigint,
  p_employee_id uuid,
  p_reason text,
  p_allow_limit_override boolean default false,
  p_duty_transfer_assignment_id uuid default null,
  p_approve_overtime boolean default false
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_overtime jsonb;
  v_result jsonb;
  v_policy text;
  v_added integer;
  v_assignment_id uuid;
  v_overtime_assignment_id uuid;
  v_snapshot jsonb;
  v_strategy_id uuid;
  v_payload jsonb;
  v_validation jsonb;
  v_transient_approval boolean := false;
begin
  v_overtime := solver_private.leader_overtime_candidate_uat_v1(
    p_variant_id, p_assignment_id, p_issue_id, p_employee_id
  );
  v_policy := coalesce(v_overtime->>'overtimePolicy', 'NEVER');
  v_added := coalesce((v_overtime->>'addedOvertimeMinutes')::integer, 0);

  if v_added > 0 and v_policy = 'NEVER' then
    raise exception 'LEADER_OVERTIME_NOT_ALLOWED:%', v_overtime::text;
  end if;
  if v_added > 0 and v_policy = 'APPROVAL_REQUIRED' and not p_approve_overtime then
    raise exception 'LEADER_OVERTIME_APPROVAL_REQUIRED:%', v_overtime::text;
  end if;
  if v_added > 0 and v_policy = 'APPROVAL_REQUIRED' and p_approve_overtime then
    if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
    v_transient_approval := true;
    perform set_config(
      'solver_private.b4f164_overtime_approval_employee',p_employee_id::text,true
    );
    perform set_config(
      'solver_private.b4f164_overtime_approval_actor',v_actor::text,true
    );
    perform set_config(
      'solver_private.b4f164_overtime_approval_quote',v_overtime::text,true
    );
  end if;

  v_result := public.optimizer_leader_assignment_save_uat_v2(
    p_variant_id, p_assignment_id, p_issue_id, p_employee_id, p_reason,
    p_allow_limit_override, p_duty_transfer_assignment_id
  );
  v_assignment_id := nullif(v_result->>'assignmentId', '')::uuid;
  v_overtime_assignment_id := coalesce(
    nullif(v_result->>'dutyTransferAssignmentId','')::uuid,v_assignment_id
  );

  if v_added > 0 and v_overtime_assignment_id is not null then
    update public.plan_assignments_v2
    set explanation = coalesce(explanation, '{}'::jsonb) || jsonb_build_object(
      'overtimeDecision', case when v_policy = 'APPROVAL_REQUIRED' then 'LEADER_APPROVED' else 'POLICY_ALLOWED' end,
      'overtimeApprovedBy', case when v_policy = 'APPROVAL_REQUIRED' then v_actor else null end,
      'overtimeApprovedAt', case when v_policy = 'APPROVAL_REQUIRED' then now() else null end,
      'overtimeQuote', v_overtime
    )
    where id = v_overtime_assignment_id;
    insert into public.audit_log(actor_id, entity_type, entity_id, action, new_data)
    values(
      v_actor, 'plan_assignment_v2', v_overtime_assignment_id::text,
      case when v_policy = 'APPROVAL_REQUIRED' then 'APPROVE_OVERTIME' else 'ASSIGN_OVERTIME_ALLOWED' end,
      jsonb_build_object('reason', trim(coalesce(p_reason, '')), 'quote', v_overtime)
    );
  end if;

  if v_transient_approval then
    select snapshot.snapshot,variant.strategy_id
    into v_snapshot,v_strategy_id
    from public.plan_variants_v2 variant
    join solver_private.optimization_snapshots_v2 snapshot on snapshot.run_id=variant.run_id
    where variant.id=p_variant_id;
    v_payload:=solver_private.materialized_variant_payload_v2(
      array[p_variant_id],v_snapshot,v_strategy_id
    );
    v_validation:=solver_private.validate_variant_v2(v_snapshot,v_payload);
    perform set_config('solver_private.b4f164_overtime_approval_employee','',true);
    perform set_config('solver_private.b4f164_overtime_approval_actor','',true);
    perform set_config('solver_private.b4f164_overtime_approval_quote','',true);
    v_result:=v_result||jsonb_build_object('validation',v_validation);
  end if;

  return v_result || jsonb_build_object(
    'overtimePolicy', v_policy,
    'overtimeApproved', v_added > 0 and (v_policy = 'ALLOWED' or p_approve_overtime),
    'overtimeApprovalAssignmentId',v_overtime_assignment_id,
    'overtimeQuote', v_overtime
  );
end;
$$;

revoke all on function solver_private.validate_variant_before_b4f164_overtime_policy_uat_v1(
  jsonb,jsonb
),solver_private.validate_variant_v2(jsonb,jsonb) from public,anon,authenticated;
grant execute on function solver_private.validate_variant_before_b4f164_overtime_policy_uat_v1(
  jsonb,jsonb
),solver_private.validate_variant_v2(jsonb,jsonb) to service_role;

revoke all on function public.optimizer_leader_assignment_save_uat_v3(
  uuid,uuid,bigint,uuid,text,boolean,uuid,boolean
) from public,anon,authenticated;
grant execute on function public.optimizer_leader_assignment_save_uat_v3(
  uuid,uuid,bigint,uuid,text,boolean,uuid,boolean
) to authenticated;

comment on function solver_private.validate_variant_v2(jsonb,jsonb) is
  'B4F-164: validates internal plus external monthly minutes against overtime policy; APPROVAL_REQUIRED needs an audited leader approval covering the submitted total.';
comment on function public.optimizer_leader_assignment_save_uat_v3(
  uuid,uuid,bigint,uuid,text,boolean,uuid,boolean
) is 'B4F-164: leader edit persists explicit overtime approval before the final full-variant validation.';

notify pgrst,'reload schema';
