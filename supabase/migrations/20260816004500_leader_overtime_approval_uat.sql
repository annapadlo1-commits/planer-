-- UAT: explicit, priced leader approval for APPROVAL_REQUIRED overtime.
-- Automatic generation still treats every policy except ALLOWED as a hard
-- nominal cap. This migration only governs a conscious edit of the leader copy.

create or replace function solver_private.leader_overtime_candidate_uat_v1(
  p_variant_id uuid,
  p_assignment_id uuid,
  p_issue_id bigint,
  p_employee_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_variant public.plan_variants_v2%rowtype;
  v_run public.optimization_runs_v2%rowtype;
  v_assignment public.plan_assignments_v2%rowtype;
  v_issue public.plan_issues_v2%rowtype;
  v_shift public.plan_shifts_v2%rowtype;
  v_profile public.matrix_employee_profiles_v2%rowtype;
  v_snapshot jsonb;
  v_payload jsonb;
  v_current_quote jsonb;
  v_projected_quote jsonb;
  v_assignments jsonb;
  v_unfilled jsonb;
  v_slot_key text;
  v_duration integer;
  v_current_monthly integer := 0;
  v_nominal integer := 0;
  v_overtime_before integer := 0;
  v_overtime_after integer := 0;
  v_current_cost_minor bigint := 0;
  v_projected_cost_minor bigint := 0;
  v_currency text := 'PLN';
begin
  if (p_assignment_id is null) = (p_issue_id is null) then
    raise exception 'ASSIGNMENT_OR_ISSUE_REQUIRED';
  end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then
    raise exception 'LEADER_VARIANT_NOT_EDITABLE';
  end if;

  select variant.* into v_variant
  from public.plan_variants_v2 variant
  where variant.id = p_variant_id and variant.variant_kind = 'LEADER_COPY';
  select run.* into v_run
  from public.optimization_runs_v2 run
  where run.id = v_variant.run_id;
  select snapshot into v_snapshot
  from solver_private.optimization_snapshots_v2
  where run_id = v_run.id;

  if p_assignment_id is not null then
    select assignment.* into v_assignment
    from public.plan_assignments_v2 assignment
    where assignment.id = p_assignment_id and assignment.variant_id = p_variant_id;
    if v_assignment.id is null then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
    select shift_row.* into v_shift from public.plan_shifts_v2 shift_row where shift_row.id = v_assignment.shift_id;
    v_slot_key := v_assignment.slot_key;
  else
    select issue.* into v_issue
    from public.plan_issues_v2 issue
    where issue.id = p_issue_id and issue.variant_id = p_variant_id and issue.issue_code = 'UNFILLED_SLOT';
    if v_issue.id is null then raise exception 'UNFILLED_ISSUE_NOT_FOUND'; end if;
    select shift_row.* into v_shift from public.plan_shifts_v2 shift_row where shift_row.id = v_issue.shift_id;
    v_slot_key := v_issue.slot_key;
  end if;

  select profile.* into v_profile
  from public.matrix_employee_profiles_v2 profile
  where profile.matrix_version_id = v_run.matrix_version_id
    and profile.employee_id = p_employee_id
    and profile.active and profile.archived_at is null;
  if v_profile.id is null then raise exception 'VARIANT_EMPLOYEE_ELIGIBILITY_INVALID'; end if;

  v_duration := extract(epoch from (v_shift.ends_at - v_shift.starts_at)) / 60;
  select coalesce(sum(extract(epoch from (shift_row.ends_at - shift_row.starts_at)) / 60), 0)::integer
  into v_current_monthly
  from public.plan_assignments_v2 assignment
  join public.plan_shifts_v2 shift_row on shift_row.id = assignment.shift_id
  where assignment.variant_id = p_variant_id
    and assignment.employee_id = p_employee_id
    and assignment.id is distinct from p_assignment_id
    and shift_row.shift_date >= v_run.month
    and shift_row.shift_date < (v_run.month + interval '1 month')::date;

  v_nominal := greatest(coalesce(v_profile.nominal_monthly_minutes, 0), 0);
  v_overtime_before := greatest(v_current_monthly - v_nominal, 0);
  v_overtime_after := greatest(v_current_monthly + v_duration - v_nominal, 0);
  v_currency := coalesce(nullif(v_snapshot->>'currency', ''), 'PLN');

  v_payload := solver_private.materialized_variant_payload_v2(
    array[p_variant_id], v_snapshot, v_variant.strategy_id
  );
  v_current_quote := solver_private.requote_variant_payload_v2(v_snapshot, v_payload);

  select coalesce(jsonb_agg(
    case when assignment.value->>'slotId' = v_slot_key then
      (assignment.value - 'costUnits' - 'costComponents')
        || jsonb_build_object('employeeId', p_employee_id)
    else assignment.value end
    order by assignment.ordinality
  ), '[]'::jsonb)
  into v_assignments
  from jsonb_array_elements(coalesce(v_payload->'assignments', '[]'::jsonb))
    with ordinality assignment(value, ordinality);

  if p_issue_id is not null then
    v_assignments := v_assignments || jsonb_build_array(jsonb_build_object(
      'slotId', v_slot_key, 'employeeId', p_employee_id
    ));
  end if;
  select coalesce(jsonb_agg(slot.value order by slot.ordinality), '[]'::jsonb)
  into v_unfilled
  from jsonb_array_elements(coalesce(v_payload->'unfilledSlotIds', '[]'::jsonb))
    with ordinality slot(value, ordinality)
  where slot.value#>>'{}' is distinct from v_slot_key;

  v_payload := jsonb_set(v_payload, '{assignments}', v_assignments, true);
  v_payload := jsonb_set(v_payload, '{unfilledSlotIds}', v_unfilled, true);
  v_projected_quote := solver_private.requote_variant_payload_v2(v_snapshot, v_payload);

  select coalesce(sum((assignment.value->>'costUnits')::bigint), 0)
  into v_current_cost_minor
  from jsonb_array_elements(coalesce(v_current_quote->'assignments', '[]'::jsonb)) assignment(value);
  select coalesce(sum((assignment.value->>'costUnits')::bigint), 0)
  into v_projected_cost_minor
  from jsonb_array_elements(coalesce(v_projected_quote->'assignments', '[]'::jsonb)) assignment(value);
  v_current_cost_minor := round(v_current_cost_minor::numeric / 60);
  v_projected_cost_minor := round(v_projected_cost_minor::numeric / 60);

  return jsonb_build_object(
    'overtimePolicy', coalesce(v_profile.overtime_policy, 'NEVER'),
    'nominalMonthlyMinutes', v_nominal,
    'currentMonthlyMinutes', v_current_monthly,
    'projectedMonthlyMinutes', v_current_monthly + v_duration,
    'overtimeBeforeMinutes', v_overtime_before,
    'overtimeAfterMinutes', v_overtime_after,
    'addedOvertimeMinutes', greatest(v_overtime_after - v_overtime_before, 0),
    'currentTotalCostMinor', v_current_cost_minor,
    'projectedTotalCostMinor', v_projected_cost_minor,
    'addedCostMinor', v_projected_cost_minor - v_current_cost_minor,
    'currency', v_currency,
    'overtimeApprovalRequired', coalesce(v_profile.overtime_policy, 'NEVER') = 'APPROVAL_REQUIRED'
      and v_overtime_after > v_overtime_before,
    'overtimeBlocked', coalesce(v_profile.overtime_policy, 'NEVER') = 'NEVER'
      and v_overtime_after > v_overtime_before
  );
end;
$$;

create or replace function public.optimizer_leader_assignment_context_uat_v3(
  p_variant_id uuid,
  p_assignment_id uuid default null,
  p_issue_id bigint default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_payload jsonb;
  v_candidates jsonb := '[]'::jsonb;
  v_candidate jsonb;
  v_overtime jsonb;
begin
  v_payload := public.optimizer_leader_assignment_context_uat_v2(
    p_variant_id, p_assignment_id, p_issue_id
  );
  for v_candidate in
    select candidate.value
    from jsonb_array_elements(coalesce(v_payload->'candidates', '[]'::jsonb)) candidate(value)
  loop
    v_overtime := solver_private.leader_overtime_candidate_uat_v1(
      p_variant_id, p_assignment_id, p_issue_id, (v_candidate->>'employeeId')::uuid
    );
    v_candidate := v_candidate || v_overtime || jsonb_build_object(
      'suggestionEligible', coalesce((v_candidate->>'suggestionEligible')::boolean, false)
        and not coalesce((v_overtime->>'overtimeBlocked')::boolean, false)
    );
    v_candidates := v_candidates || jsonb_build_array(v_candidate);
  end loop;
  return jsonb_set(v_payload, '{candidates}', v_candidates, true);
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

  v_result := public.optimizer_leader_assignment_save_uat_v2(
    p_variant_id, p_assignment_id, p_issue_id, p_employee_id, p_reason,
    p_allow_limit_override, p_duty_transfer_assignment_id
  );
  v_assignment_id := nullif(v_result->>'assignmentId', '')::uuid;

  if v_added > 0 and v_assignment_id is not null then
    update public.plan_assignments_v2
    set explanation = coalesce(explanation, '{}'::jsonb) || jsonb_build_object(
      'overtimeDecision', case when v_policy = 'APPROVAL_REQUIRED' then 'LEADER_APPROVED' else 'POLICY_ALLOWED' end,
      'overtimeApprovedBy', case when v_policy = 'APPROVAL_REQUIRED' then v_actor else null end,
      'overtimeApprovedAt', case when v_policy = 'APPROVAL_REQUIRED' then now() else null end,
      'overtimeQuote', v_overtime
    )
    where id = v_assignment_id;
    insert into public.audit_log(actor_id, entity_type, entity_id, action, new_data)
    values(
      v_actor, 'plan_assignment_v2', v_assignment_id::text,
      case when v_policy = 'APPROVAL_REQUIRED' then 'APPROVE_OVERTIME' else 'ASSIGN_OVERTIME_ALLOWED' end,
      jsonb_build_object('reason', trim(coalesce(p_reason, '')), 'quote', v_overtime)
    );
  end if;

  return v_result || jsonb_build_object(
    'overtimePolicy', v_policy,
    'overtimeApproved', v_added > 0 and (v_policy = 'ALLOWED' or p_approve_overtime),
    'overtimeQuote', v_overtime
  );
end;
$$;

revoke all on function solver_private.leader_overtime_candidate_uat_v1(uuid,uuid,bigint,uuid)
  from public, anon, authenticated;
grant execute on function solver_private.leader_overtime_candidate_uat_v1(uuid,uuid,bigint,uuid)
  to service_role;

revoke all on function public.optimizer_leader_assignment_context_uat_v3(uuid,uuid,bigint),
  public.optimizer_leader_assignment_save_uat_v3(uuid,uuid,bigint,uuid,text,boolean,uuid,boolean)
  from public, anon, authenticated;
grant execute on function public.optimizer_leader_assignment_context_uat_v3(uuid,uuid,bigint),
  public.optimizer_leader_assignment_save_uat_v3(uuid,uuid,bigint,uuid,text,boolean,uuid,boolean)
  to authenticated;

comment on function public.optimizer_leader_assignment_save_uat_v3(uuid,uuid,bigint,uuid,text,boolean,uuid,boolean) is
  'Leader-copy edit with a separate audited overtime decision and an exact full-variant pay quote.';

notify pgrst, 'reload schema';
