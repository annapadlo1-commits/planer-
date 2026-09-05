-- B5: a recovery proposal becomes an auditable leader draft. It never silently
-- changes a published schedule. The leader must still validate and publish the
-- resulting role variant through the normal publication workflow.

create or replace function solver_private.recovery_clone_published_variant_uat_v1(
  p_source_variant_id uuid,
  p_name text
) returns uuid
language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid:=auth.uid();
  v_source public.plan_variants_v2%rowtype;
  v_run public.optimization_runs_v2%rowtype;
  v_id uuid:=gen_random_uuid();
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into v_source from public.plan_variants_v2 where id=p_source_variant_id for update;
  select * into v_run from public.optimization_runs_v2 where id=v_source.run_id for update;
  if v_source.id is null or v_run.id is null or v_run.scope_type<>'ROLE'
    or v_source.status not in ('READY','SELECTED','PUBLISHED')
    or v_source.hard_violations<>0 then raise exception 'VALID_ROLE_VARIANT_REQUIRED'; end if;
  if not solver_private.recovery_can_manage_scope_uat_v1(v_run.scope_role_id,null)
    then raise exception 'ROLE_SCOPE_FORBIDDEN'; end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-copy:'||v_run.id::text,0));

  update public.plan_variants_v2 set status='ARCHIVED',selected=false
  where run_id=v_run.id and variant_kind='LEADER_COPY' and status in ('READY','SELECTED');
  -- A published leader copy may still be the selected row for the run. The
  -- publication points to the variant by id, so moving only the editor
  -- selection flag to the new draft does not change the published schedule.
  update public.plan_variants_v2 set selected=false
  where run_id=v_run.id and selected;
  update public.plan_variants_v2 set selected=false,
    status=case when status='SELECTED' then 'READY' else status end
  where run_id=v_run.id and variant_kind='GENERATED';

  insert into public.plan_variants_v2(
    id,run_id,run_strategy_id,strategy_id,name,status,hard_violations,
    assignment_count,unfilled_count,solver_status,solution_hash,objective_bound,
    metrics,recommended,selected,equivalent_to_variant_id,snapshot_hash,
    selected_at,selected_by,variant_kind,source_variant_id,revision,last_edited_at,last_edited_by
  ) values(
    v_id,v_source.run_id,v_source.run_strategy_id,v_source.strategy_id,trim(p_name),'SELECTED',0,
    v_source.assignment_count,v_source.unfilled_count,v_source.solver_status,v_source.solution_hash,
    v_source.objective_bound,coalesce(v_source.metrics,'{}'::jsonb)||jsonb_build_object(
      'leaderCopy',true,'recoveryDraft',true,'recoverySourceVariantId',v_source.id),
    false,true,v_source.equivalent_to_variant_id,v_source.snapshot_hash,now(),v_actor,
    'LEADER_COPY',v_source.id,0,now(),v_actor
  );

  insert into public.plan_shifts_v2(
    id,variant_id,slot_group_key,shift_template_id,location_id,shift_date,
    starts_at,ends_at,source_type,source_id,created_at
  ) select public.matrix_v2_stable_uuid('LEADER_SHIFT:'||v_id::text||':'||source.id::text),
    v_id,source.slot_group_key,source.shift_template_id,source.location_id,source.shift_date,
    source.starts_at,source.ends_at,source.source_type,source.source_id,now()
  from public.plan_shifts_v2 source where source.variant_id=v_source.id;

  insert into public.plan_assignments_v2(
    id,variant_id,shift_id,slot_key,employee_id,role_id,locked,explanation,created_at
  ) select public.matrix_v2_stable_uuid('LEADER_ASSIGNMENT:'||v_id::text||':'||source.id::text),
    v_id,public.matrix_v2_stable_uuid('LEADER_SHIFT:'||v_id::text||':'||source.shift_id::text),
    source.slot_key,source.employee_id,source.role_id,source.locked,
    coalesce(source.explanation,'{}'::jsonb)||jsonb_build_object(
      'sourceVariantId',v_source.id,'sourceAssignmentId',source.id,'edited',false,'recoveryDraft',true),now()
  from public.plan_assignments_v2 source where source.variant_id=v_source.id;

  insert into public.plan_assignment_duties_v2(assignment_id,duty_id)
  select public.matrix_v2_stable_uuid('LEADER_ASSIGNMENT:'||v_id::text||':'||source.id::text),duty.duty_id
  from public.plan_assignments_v2 source join public.plan_assignment_duties_v2 duty on duty.assignment_id=source.id
  where source.variant_id=v_source.id;

  insert into public.plan_issues_v2(
    variant_id,shift_id,slot_key,issue_code,severity,role_id,duty_id,
    required_count,assigned_count,message,metadata,created_at
  ) select v_id,
    case when source.shift_id is null then null else
      public.matrix_v2_stable_uuid('LEADER_SHIFT:'||v_id::text||':'||source.shift_id::text) end,
    source.slot_key,source.issue_code,source.severity,source.role_id,source.duty_id,
    source.required_count,source.assigned_count,source.message,
    coalesce(source.metadata,'{}'::jsonb)||jsonb_build_object('sourceIssueId',source.id,'recoveryDraft',true),now()
  from public.plan_issues_v2 source where source.variant_id=v_source.id;

  insert into solver_private.plan_assignment_cost_components_v2(
    assignment_id,pay_rule_id,component_code,amount_minor,quantity_minutes,calculation_basis,created_at
  ) select public.matrix_v2_stable_uuid('LEADER_ASSIGNMENT:'||v_id::text||':'||assignment.id::text),
    component.pay_rule_id,component.component_code,component.amount_minor,component.quantity_minutes,
    component.calculation_basis,now()
  from public.plan_assignments_v2 assignment
  join solver_private.plan_assignment_cost_components_v2 component on component.assignment_id=assignment.id
  where assignment.variant_id=v_source.id;

  insert into solver_private.plan_variant_finance_v2(
    variant_id,base_cost_units,additions_cost_units,total_cost_units,base_cost_minor,
    additions_cost_minor,total_cost_minor,currency,budget_minor,hard_budget_exceeded,breakdown
  ) select v_id,finance.base_cost_units,finance.additions_cost_units,finance.total_cost_units,
    finance.base_cost_minor,finance.additions_cost_minor,finance.total_cost_minor,finance.currency,
    finance.budget_minor,finance.hard_budget_exceeded,
    coalesce(finance.breakdown,'{}'::jsonb)||jsonb_build_object('sourceVariantId',v_source.id,'recoveryDraft',true)
  from solver_private.plan_variant_finance_v2 finance where finance.variant_id=v_source.id;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'plan_variant_v2',v_id::text,'CREATE_RECOVERY_LEADER_COPY',
    jsonb_build_object('runId',v_run.id,'sourceVariantId',v_source.id,'name',trim(p_name)));
  return v_id;
end;
$$;

create or replace function public.recovery_action_select_candidate_uat_v1(
  p_action_id uuid,p_employee_id uuid,p_expected_action_version integer,p_expected_revision integer
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid:=auth.uid(); v_action public.recovery_actions_v2%rowtype;
  v_incident public.recovery_incidents_v2%rowtype; v_revision integer;
  v_candidate jsonb;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into v_action from public.recovery_actions_v2 where id=p_action_id for update;
  select * into v_incident from public.recovery_incidents_v2 where id=v_action.incident_id for update;
  if v_action.id is null or v_incident.id is null then raise exception 'RECOVERY_ACTION_NOT_FOUND'; end if;
  if not solver_private.recovery_can_manage_scope_uat_v1(v_incident.role_id,v_incident.location_id)
    then raise exception 'ROLE_OR_LOCATION_SCOPE_FORBIDDEN'; end if;
  perform pg_advisory_xact_lock(hashtextextended('recovery:'||v_incident.month::text,0));
  select revision into v_revision from public.recovery_month_revisions_v2 where month=v_incident.month for update;
  if v_revision<>p_expected_revision then raise exception 'RECOVERY_REVISION_CONFLICT expected %, actual %',p_expected_revision,v_revision; end if;
  if v_action.version<>p_expected_action_version then raise exception 'RECOVERY_ACTION_CONFLICT'; end if;
  select candidate into v_candidate from jsonb_array_elements(v_action.candidate_snapshot) candidate
  where candidate->>'employeeId'=p_employee_id::text limit 1;
  if v_candidate is null then raise exception 'RECOVERY_CANDIDATE_NOT_FOUND'; end if;
  if not coalesce((v_candidate->>'eligible')::boolean,false)
    then raise exception 'RECOVERY_CANDIDATE_HARD_BLOCKED'; end if;
  update public.recovery_actions_v2 set selected_employee_id=p_employee_id,status='DRAFT_READY',
    version=version+1,updated_at=now() where id=v_action.id;
  update public.recovery_month_revisions_v2 set revision=revision+1,updated_by=v_actor,updated_at=now()
    where month=v_incident.month returning revision into v_revision;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'recovery_action_v2',v_action.id::text,'RECOVERY_CANDIDATE_SELECTED',
    jsonb_build_object('employeeId',p_employee_id,'previousEmployeeId',v_action.selected_employee_id,'revision',v_revision));
  return jsonb_build_object('saved',true,'revision',v_revision,'actionVersion',v_action.version+1);
end;
$$;

create or replace function public.recovery_incident_apply_draft_uat_v1(
  p_incident_id uuid,p_expected_revision integer
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid:=auth.uid(); v_incident public.recovery_incidents_v2%rowtype;
  v_revision integer; v_source_variant uuid; v_draft_variant uuid; v_action record;
  v_target_assignment uuid; v_target_issue bigint; v_current_snapshot jsonb;
  v_allow_limit_override boolean; v_result jsonb; v_drafts jsonb:='[]'::jsonb; v_applied integer:=0;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into v_incident from public.recovery_incidents_v2 where id=p_incident_id for update;
  if v_incident.id is null then raise exception 'INCIDENT_NOT_FOUND'; end if;
  if not solver_private.recovery_can_manage_scope_uat_v1(v_incident.role_id,v_incident.location_id)
    then raise exception 'ROLE_OR_LOCATION_SCOPE_FORBIDDEN'; end if;
  perform pg_advisory_xact_lock(hashtextextended('recovery:'||v_incident.month::text,0));
  select revision into v_revision from public.recovery_month_revisions_v2 where month=v_incident.month for update;
  if v_revision<>p_expected_revision then raise exception 'RECOVERY_REVISION_CONFLICT expected %, actual %',p_expected_revision,v_revision; end if;
  if not exists(select 1 from public.recovery_actions_v2 where incident_id=v_incident.id and selected_employee_id is not null)
    then raise exception 'RECOVERY_CANDIDATE_SELECTION_REQUIRED'; end if;

  for v_source_variant in
    select distinct coalesce(source_assignment.variant_id,source_issue.variant_id)
    from public.recovery_actions_v2 action
    left join public.plan_assignments_v2 source_assignment on source_assignment.id=action.source_assignment_id
    left join public.plan_issues_v2 source_issue on source_issue.id=action.source_issue_id
    where action.incident_id=v_incident.id and action.selected_employee_id is not null
  loop
    v_draft_variant:=solver_private.recovery_clone_published_variant_uat_v1(
      v_source_variant,'Naprawa • '||v_incident.title||' • '||v_incident.month::text
    );
    for v_action in
      select action.* from public.recovery_actions_v2 action
      left join public.plan_assignments_v2 source_assignment on source_assignment.id=action.source_assignment_id
      left join public.plan_issues_v2 source_issue on source_issue.id=action.source_issue_id
      where action.incident_id=v_incident.id and action.selected_employee_id is not null
        and coalesce(source_assignment.variant_id,source_issue.variant_id)=v_source_variant
      order by action.created_at,action.id
    loop
      v_current_snapshot:=solver_private.recovery_candidate_snapshot_uat_v1(
        v_incident.month,v_action.shift_id,v_action.role_id,v_action.duty_id,
        case when v_action.source_assignment_id is null then null else
          (select employee_id from public.plan_assignments_v2 where id=v_action.source_assignment_id) end
      );
      if not exists(select 1 from jsonb_array_elements(v_current_snapshot) candidate
        where candidate->>'employeeId'=v_action.selected_employee_id::text
          and coalesce((candidate->>'eligible')::boolean,false)) then
        raise exception 'RECOVERY_CANDIDATE_CHANGED:%',v_action.selected_employee_id;
      end if;
      v_target_assignment:=case when v_action.source_assignment_id is null then null else
        public.matrix_v2_stable_uuid('LEADER_ASSIGNMENT:'||v_draft_variant::text||':'||v_action.source_assignment_id::text) end;
      v_target_issue:=null;
      select issue.id into v_target_issue from public.plan_issues_v2 issue
      where issue.variant_id=v_draft_variant
        and issue.metadata->>'sourceIssueId'=v_action.source_issue_id::text limit 1;
      v_allow_limit_override:=exists(
        select 1 from public.recovery_overrides_v2 override_row
        where override_row.incident_id=v_incident.id and override_row.status='APPROVED'
          and override_row.override_type in ('WEEKLY_LIMIT','MONTHLY_LIMIT')
          and override_row.employee_id=v_action.selected_employee_id
          and (select shift_date from public.plan_shifts_v2 where id=v_action.shift_id)
            between override_row.starts_on and override_row.ends_on
      );
      v_result:=public.optimizer_leader_assignment_save_uat_v2(
        v_draft_variant,v_target_assignment,v_target_issue,v_action.selected_employee_id,
        'Naprawa incydentu: '||v_incident.title,v_allow_limit_override,null
      );
      update public.recovery_actions_v2 set status='APPLIED',draft_variant_id=v_draft_variant,
        version=version+1,updated_at=now() where id=v_action.id;
      v_applied:=v_applied+1;
    end loop;
    v_drafts:=v_drafts||jsonb_build_array(jsonb_build_object(
      'variantId',v_draft_variant,'sourceVariantId',v_source_variant,
      'runId',(select run_id from public.plan_variants_v2 where id=v_draft_variant),
      'roleId',(select run.scope_role_id from public.plan_variants_v2 variant
        join public.optimization_runs_v2 run on run.id=variant.run_id where variant.id=v_draft_variant),
      'status','SELECTED'
    ));
  end loop;
  update public.recovery_incidents_v2 set status='APPLIED',updated_by=v_actor,updated_at=now()
    where id=v_incident.id;
  update public.recovery_month_revisions_v2 set revision=revision+1,updated_by=v_actor,updated_at=now()
    where month=v_incident.month returning revision into v_revision;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'recovery_incident_v2',v_incident.id::text,'RECOVERY_DRAFTS_CREATED',
    jsonb_build_object('drafts',v_drafts,'appliedActions',v_applied,'revision',v_revision,
      'publishedScheduleChanged',false));
  return jsonb_build_object('created',true,'drafts',v_drafts,'appliedActions',v_applied,
    'revision',v_revision,'publishedScheduleChanged',false);
end;
$$;

revoke all on function solver_private.recovery_clone_published_variant_uat_v1(uuid,text)
  from public,anon,authenticated;
revoke all on function public.recovery_action_select_candidate_uat_v1(uuid,uuid,integer,integer),
  public.recovery_incident_apply_draft_uat_v1(uuid,integer) from public,anon,authenticated;
grant execute on function public.recovery_action_select_candidate_uat_v1(uuid,uuid,integer,integer),
  public.recovery_incident_apply_draft_uat_v1(uuid,integer) to authenticated;

comment on function public.recovery_incident_apply_draft_uat_v1(uuid,integer) is
  'Creates validated role-scoped leader drafts from recovery decisions; never mutates or republishes the active schedule.';
notify pgrst,'reload schema';
