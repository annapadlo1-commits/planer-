-- B4: preserve the three mathematical proposals and let a leader publish an
-- independently validated working copy.  Also gives the UI an explicit model
-- for month-wide baselines versus dated demand profiles.

alter table public.plan_variants_v2
  add column if not exists variant_kind text not null default 'GENERATED',
  add column if not exists source_variant_id uuid references public.plan_variants_v2(id) on delete restrict,
  add column if not exists revision integer not null default 0,
  add column if not exists last_edited_at timestamptz,
  add column if not exists last_edited_by uuid references auth.users(id);

alter table public.plan_variants_v2
  drop constraint if exists plan_variants_v2_variant_kind_check;
alter table public.plan_variants_v2
  add constraint plan_variants_v2_variant_kind_check
  check(variant_kind in ('GENERATED','LEADER_COPY'));

alter table public.plan_variants_v2
  drop constraint if exists plan_variants_v2_run_id_strategy_id_key;
alter table public.plan_variants_v2
  drop constraint if exists plan_variants_v2_run_strategy_id_key;

create unique index if not exists plan_variants_generated_run_strategy_v2
  on public.plan_variants_v2(run_id,strategy_id)
  where variant_kind='GENERATED';
create unique index if not exists plan_variants_generated_run_strategy_row_v2
  on public.plan_variants_v2(run_strategy_id)
  where variant_kind='GENERATED';
create index if not exists plan_variants_source_variant_v2
  on public.plan_variants_v2(source_variant_id)
  where source_variant_id is not null;

create or replace function solver_private.can_edit_leader_variant_uat_v1(
  p_variant_id uuid
) returns boolean
language sql stable security definer set search_path=''
as $$
  select exists(
    select 1
    from public.plan_variants_v2 variant
    join public.optimization_runs_v2 run on run.id=variant.run_id
    left join public.matrix_roles_v2 role on role.id=run.scope_role_id
    where variant.id=p_variant_id
      and variant.variant_kind='LEADER_COPY'
      and variant.status in ('READY','SELECTED')
      and auth.uid() is not null
      and (
        public.has_app_role('OWNER') or public.has_app_role('ADMIN')
        or (
          run.scope_type='ROLE'
          and exists(
            select 1 from public.matrix_scope_grants_v2 grant_row
            where grant_row.auth_user_id=auth.uid()
              and grant_row.active
              and grant_row.app_role='ROLE_MANAGER'
              and (grant_row.role_logical_id is null
                or grant_row.role_logical_id=role.logical_id)
          )
        )
      )
  );
$$;

create or replace function public.optimizer_create_leader_variant_uat_v1(
  p_run_id uuid,
  p_source_variant_id uuid,
  p_name text
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid:=auth.uid();
  v_source public.plan_variants_v2%rowtype;
  v_run public.optimization_runs_v2%rowtype;
  v_id uuid:=gen_random_uuid();
  v_name text:=trim(coalesce(p_name,''));
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if length(v_name) not between 1 and 200 then raise exception 'INVALID_PLAN_NAME'; end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-copy:'||p_run_id::text,0));
  select * into v_run from public.optimization_runs_v2 where id=p_run_id for update;
  select * into v_source from public.plan_variants_v2
    where id=p_source_variant_id and run_id=p_run_id and variant_kind='GENERATED'
    for update;
  if v_run.id is null or v_source.id is null then raise exception 'VARIANT_NOT_FOUND'; end if;
  if v_run.status<>'READY' or v_source.status not in ('READY','SELECTED','PUBLISHED')
    or v_source.hard_violations<>0 then raise exception 'VALID_GENERATED_VARIANT_REQUIRED'; end if;
  if not (
    public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or (v_run.scope_type='ROLE' and exists(
      select 1 from public.matrix_scope_grants_v2 grant_row
      join public.matrix_roles_v2 role on role.id=v_run.scope_role_id
      where grant_row.auth_user_id=v_actor and grant_row.active
        and grant_row.app_role='ROLE_MANAGER'
        and (grant_row.role_logical_id is null or grant_row.role_logical_id=role.logical_id)
    ))
  ) then raise exception 'LEADER_VARIANT_FORBIDDEN'; end if;

  update public.plan_variants_v2
    set status='ARCHIVED',selected=false
    where run_id=p_run_id and variant_kind='LEADER_COPY'
      and status in ('READY','SELECTED');
  update public.plan_variants_v2
    set selected=false,status=case when status='SELECTED' then 'READY' else status end
    where run_id=p_run_id and variant_kind='GENERATED';

  insert into public.plan_variants_v2(
    id,run_id,run_strategy_id,strategy_id,name,status,hard_violations,
    assignment_count,unfilled_count,solver_status,solution_hash,objective_bound,
    metrics,recommended,selected,equivalent_to_variant_id,snapshot_hash,
    selected_at,selected_by,variant_kind,source_variant_id,revision,last_edited_at,last_edited_by
  ) values(
    v_id,v_source.run_id,v_source.run_strategy_id,v_source.strategy_id,v_name,
    'SELECTED',0,v_source.assignment_count,v_source.unfilled_count,
    v_source.solver_status,v_source.solution_hash,v_source.objective_bound,
    v_source.metrics||jsonb_build_object('leaderCopy',true),false,true,
    v_source.equivalent_to_variant_id,v_source.snapshot_hash,now(),v_actor,
    'LEADER_COPY',v_source.id,0,now(),v_actor
  );

  insert into public.plan_shifts_v2(
    id,variant_id,slot_group_key,shift_template_id,location_id,shift_date,
    starts_at,ends_at,source_type,source_id,created_at
  )
  select public.matrix_v2_stable_uuid('LEADER_SHIFT:'||v_id::text||':'||source.id::text),
    v_id,source.slot_group_key,source.shift_template_id,source.location_id,
    source.shift_date,source.starts_at,source.ends_at,source.source_type,
    source.source_id,now()
  from public.plan_shifts_v2 source where source.variant_id=v_source.id;

  insert into public.plan_assignments_v2(
    id,variant_id,shift_id,slot_key,employee_id,role_id,locked,explanation,created_at
  )
  select public.matrix_v2_stable_uuid('LEADER_ASSIGNMENT:'||v_id::text||':'||source.id::text),
    v_id,public.matrix_v2_stable_uuid('LEADER_SHIFT:'||v_id::text||':'||source.shift_id::text),
    source.slot_key,source.employee_id,source.role_id,source.locked,
    coalesce(source.explanation,'{}'::jsonb)||jsonb_build_object(
      'sourceVariantId',v_source.id,'sourceAssignmentId',source.id,'edited',false
    ),now()
  from public.plan_assignments_v2 source where source.variant_id=v_source.id;

  insert into public.plan_assignment_duties_v2(assignment_id,duty_id)
  select public.matrix_v2_stable_uuid('LEADER_ASSIGNMENT:'||v_id::text||':'||source.id::text),duty.duty_id
  from public.plan_assignments_v2 source
  join public.plan_assignment_duties_v2 duty on duty.assignment_id=source.id
  where source.variant_id=v_source.id;

  insert into public.plan_issues_v2(
    variant_id,shift_id,slot_key,issue_code,severity,role_id,duty_id,
    required_count,assigned_count,message,metadata,created_at
  )
  select v_id,
    case when source.shift_id is null then null else
      public.matrix_v2_stable_uuid('LEADER_SHIFT:'||v_id::text||':'||source.shift_id::text) end,
    source.slot_key,source.issue_code,source.severity,source.role_id,source.duty_id,
    source.required_count,source.assigned_count,source.message,
    coalesce(source.metadata,'{}'::jsonb)||jsonb_build_object('sourceIssueId',source.id),now()
  from public.plan_issues_v2 source where source.variant_id=v_source.id;

  insert into solver_private.plan_assignment_cost_components_v2(
    assignment_id,pay_rule_id,component_code,amount_minor,quantity_minutes,
    calculation_basis,created_at
  )
  select public.matrix_v2_stable_uuid('LEADER_ASSIGNMENT:'||v_id::text||':'||assignment.id::text),
    component.pay_rule_id,component.component_code,component.amount_minor,
    component.quantity_minutes,component.calculation_basis,now()
  from public.plan_assignments_v2 assignment
  join solver_private.plan_assignment_cost_components_v2 component
    on component.assignment_id=assignment.id
  where assignment.variant_id=v_source.id;

  insert into solver_private.plan_variant_finance_v2(
    variant_id,base_cost_units,additions_cost_units,total_cost_units,
    base_cost_minor,additions_cost_minor,total_cost_minor,currency,budget_minor,
    hard_budget_exceeded,breakdown
  )
  select v_id,finance.base_cost_units,finance.additions_cost_units,finance.total_cost_units,
    finance.base_cost_minor,finance.additions_cost_minor,finance.total_cost_minor,
    finance.currency,finance.budget_minor,finance.hard_budget_exceeded,
    finance.breakdown||jsonb_build_object('sourceVariantId',v_source.id)
  from solver_private.plan_variant_finance_v2 finance where finance.variant_id=v_source.id;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'plan_variant_v2',v_id::text,'CREATE_LEADER_COPY',
    jsonb_build_object('runId',p_run_id,'sourceVariantId',v_source.id,'name',v_name));
  return jsonb_build_object('variantId',v_id,'sourceVariantId',v_source.id,
    'name',v_name,'revision',0,'variantKind','LEADER_COPY');
end;
$$;

create or replace function solver_private.refresh_leader_variant_uat_v1(
  p_variant_id uuid,
  p_actor uuid,
  p_reason text
) returns jsonb
language plpgsql security definer set search_path=''
as $$
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

create or replace function public.optimizer_leader_assignment_context_uat_v1(
  p_variant_id uuid,
  p_assignment_id uuid default null,
  p_issue_id bigint default null
) returns jsonb
language plpgsql stable security definer set search_path=''
as $$
declare
  v_variant public.plan_variants_v2%rowtype;
  v_run public.optimization_runs_v2%rowtype;
  v_shift public.plan_shifts_v2%rowtype;
  v_assignment public.plan_assignments_v2%rowtype;
  v_issue public.plan_issues_v2%rowtype;
  v_role_id uuid;
  v_slot_key text;
  v_duty_id uuid;
begin
  if (p_assignment_id is null)=(p_issue_id is null) then
    raise exception 'ASSIGNMENT_OR_ISSUE_REQUIRED';
  end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then
    raise exception 'LEADER_VARIANT_NOT_EDITABLE';
  end if;
  select * into v_variant from public.plan_variants_v2 where id=p_variant_id;
  select * into v_run from public.optimization_runs_v2 where id=v_variant.run_id;
  if p_assignment_id is not null then
    select * into v_assignment from public.plan_assignments_v2
      where id=p_assignment_id and variant_id=p_variant_id;
    if v_assignment.id is null then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
    select * into v_shift from public.plan_shifts_v2 where id=v_assignment.shift_id;
    v_role_id:=v_assignment.role_id; v_slot_key:=v_assignment.slot_key;
    select duty_id into v_duty_id from public.plan_assignment_duties_v2
      where assignment_id=v_assignment.id order by duty_id limit 1;
  else
    select * into v_issue from public.plan_issues_v2
      where id=p_issue_id and variant_id=p_variant_id and issue_code='UNFILLED_SLOT';
    if v_issue.id is null then raise exception 'UNFILLED_ISSUE_NOT_FOUND'; end if;
    select * into v_shift from public.plan_shifts_v2 where id=v_issue.shift_id;
    v_role_id:=v_issue.role_id; v_slot_key:=v_issue.slot_key; v_duty_id:=v_issue.duty_id;
  end if;
  return jsonb_build_object(
    'variantId',p_variant_id,'assignmentId',p_assignment_id,'issueId',p_issue_id,
    'slotKey',v_slot_key,'currentEmployeeId',v_assignment.employee_id,
    'role',jsonb_build_object('id',role.id,'name',role.name),
    'shift',jsonb_build_object('id',v_shift.id,'date',v_shift.shift_date,
      'startsAt',v_shift.starts_at,'endsAt',v_shift.ends_at,
      'locationId',v_shift.location_id,'locationName',location.name,
      'shiftName',template.name),
    'candidates',coalesce((
      select jsonb_agg(jsonb_build_object(
        'employeeId',employee.id,'employeeNo',employee.employee_no,
        'employeeName',trim(employee.first_name||' '||employee.last_name),
        'current',employee.id=v_assignment.employee_id
      ) order by employee.last_name,employee.first_name)
      from public.employees employee
      where employee.active
        and (employee.employment_start is null or employee.employment_start<=v_shift.shift_date)
        and (employee.employment_end is null or employee.employment_end>=v_shift.shift_date)
        and exists(select 1 from public.matrix_employee_roles_v2 er
          where er.matrix_version_id=v_run.matrix_version_id and er.employee_id=employee.id
            and er.role_id=v_role_id and er.active
            and (er.valid_from is null or er.valid_from<=v_shift.shift_date)
            and (er.valid_to is null or er.valid_to>=v_shift.shift_date))
        and exists(select 1 from public.matrix_employee_locations_v2 el
          where el.matrix_version_id=v_run.matrix_version_id and el.employee_id=employee.id
            and el.location_id=v_shift.location_id and el.active and el.standard_allowed
            and (el.valid_from is null or el.valid_from<=v_shift.shift_date)
            and (el.valid_to is null or el.valid_to>=v_shift.shift_date))
        and (v_duty_id is null or exists(select 1 from public.matrix_employee_duties_v2 ed
          where ed.matrix_version_id=v_run.matrix_version_id and ed.employee_id=employee.id
            and ed.duty_id=v_duty_id and ed.active
            and (ed.role_id is null or ed.role_id=v_role_id)
            and (ed.location_id is null or ed.location_id=v_shift.location_id)
            and (ed.valid_from is null or ed.valid_from<=v_shift.shift_date)
            and (ed.valid_to is null or ed.valid_to>=v_shift.shift_date)))
    ),'[]'::jsonb)
  )
  from public.matrix_roles_v2 role,public.matrix_locations_v2 location,
    public.matrix_shift_templates_v2 template
  where role.id=v_role_id and location.id=v_shift.location_id
    and template.id=v_shift.shift_template_id;
end;
$$;

create or replace function public.optimizer_leader_assignment_save_uat_v1(
  p_variant_id uuid,
  p_assignment_id uuid,
  p_issue_id bigint,
  p_employee_id uuid,
  p_reason text
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid:=auth.uid();
  v_assignment public.plan_assignments_v2%rowtype;
  v_issue public.plan_issues_v2%rowtype;
  v_snapshot jsonb;
  v_slot jsonb;
  v_assignment_id uuid;
  v_reason text:=trim(coalesce(p_reason,''));
begin
  if length(v_reason)<3 then raise exception 'EDIT_REASON_REQUIRED'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then
    raise exception 'LEADER_VARIANT_NOT_EDITABLE';
  end if;
  if (p_assignment_id is null)=(p_issue_id is null) then
    raise exception 'ASSIGNMENT_OR_ISSUE_REQUIRED';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-edit:'||p_variant_id::text,0));
  select snapshot into v_snapshot from solver_private.optimization_snapshots_v2 snapshot
    join public.plan_variants_v2 variant on variant.run_id=snapshot.run_id
    where variant.id=p_variant_id;
  if p_assignment_id is not null then
    select * into v_assignment from public.plan_assignments_v2
      where id=p_assignment_id and variant_id=p_variant_id for update;
    if v_assignment.id is null then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
    update public.plan_assignments_v2 set employee_id=p_employee_id,
      explanation=coalesce(explanation,'{}'::jsonb)||jsonb_build_object(
        'edited',true,'editedBy',v_actor,'editedAt',now(),'reason',v_reason
      ) where id=v_assignment.id;
    v_assignment_id:=v_assignment.id;
  else
    select * into v_issue from public.plan_issues_v2
      where id=p_issue_id and variant_id=p_variant_id and issue_code='UNFILLED_SLOT'
      for update;
    if v_issue.id is null then raise exception 'UNFILLED_ISSUE_NOT_FOUND'; end if;
    insert into public.plan_assignments_v2(
      variant_id,shift_id,slot_key,employee_id,role_id,locked,explanation
    ) values(
      p_variant_id,v_issue.shift_id,v_issue.slot_key,p_employee_id,v_issue.role_id,false,
      jsonb_build_object('edited',true,'editedBy',v_actor,'editedAt',now(),
        'reason',v_reason,'filledIssueId',v_issue.id)
    ) returning id into v_assignment_id;
    select slot.value into v_slot
    from jsonb_array_elements(coalesce(v_snapshot->'slots','[]'::jsonb)) slot
    where slot.value->>'slotId'=v_issue.slot_key;
    insert into public.plan_assignment_duties_v2(assignment_id,duty_id)
    select v_assignment_id,(duty.value#>>'{}')::uuid
    from jsonb_array_elements(coalesce(v_slot->'dutyIds','[]'::jsonb)) duty;
    delete from public.plan_issues_v2 where id=v_issue.id;
  end if;
  return solver_private.refresh_leader_variant_uat_v1(p_variant_id,v_actor,v_reason)
    ||jsonb_build_object('assignmentId',v_assignment_id);
end;
$$;

create or replace function public.optimizer_leader_assignment_remove_uat_v1(
  p_variant_id uuid,
  p_assignment_id uuid,
  p_reason text
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid:=auth.uid();
  v_assignment public.plan_assignments_v2%rowtype;
  v_duty_id uuid;
  v_reason text:=trim(coalesce(p_reason,''));
begin
  if length(v_reason)<3 then raise exception 'EDIT_REASON_REQUIRED'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then
    raise exception 'LEADER_VARIANT_NOT_EDITABLE';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-edit:'||p_variant_id::text,0));
  select * into v_assignment from public.plan_assignments_v2
    where id=p_assignment_id and variant_id=p_variant_id for update;
  if v_assignment.id is null then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
  if v_assignment.locked then raise exception 'LOCKED_ASSIGNMENT_CANNOT_BE_REMOVED'; end if;
  select duty_id into v_duty_id from public.plan_assignment_duties_v2
    where assignment_id=v_assignment.id order by duty_id limit 1;
  insert into public.plan_issues_v2(
    variant_id,shift_id,slot_key,issue_code,severity,role_id,duty_id,
    required_count,assigned_count,message,metadata
  ) values(
    p_variant_id,v_assignment.shift_id,v_assignment.slot_key,'UNFILLED_SLOT','WARNING',
    v_assignment.role_id,v_duty_id,1,0,
    'Miejsce pozostawione do uzupełnienia w wersji lidera.',
    jsonb_build_object('removedAssignmentId',v_assignment.id,'reason',v_reason)
  );
  delete from public.plan_assignments_v2 where id=v_assignment.id;
  return solver_private.refresh_leader_variant_uat_v1(p_variant_id,v_actor,v_reason);
end;
$$;

create or replace function public.optimizer_leader_variant_workspace_uat_v1(
  p_variant_id uuid
) returns jsonb
language plpgsql stable security definer set search_path=''
as $$
declare
  v_variant public.plan_variants_v2%rowtype;
  v_context jsonb;
  v_workspace jsonb;
  v_can_view_finance boolean;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select variant.* into v_variant from public.plan_variants_v2 variant
  where variant.id=p_variant_id and variant.variant_kind='LEADER_COPY';
  if v_variant.id is null or not solver_private.can_access_run_v2(v_variant.run_id) then
    raise exception 'LEADER_VARIANT_NOT_FOUND';
  end if;
  select jsonb_build_object(
    'type','LEADER_VARIANT','runId',run.id,'engine',run.request_engine,
    'month',run.month,'name',v_variant.name,
    'scenario',jsonb_build_object('id',scenario.id,'name',scenario.name),
    'matrixVersionId',run.matrix_version_id,'variantKind','LEADER_COPY',
    'sourceVariantId',v_variant.source_variant_id,'revision',v_variant.revision,
    'lastEditedAt',v_variant.last_edited_at
  ) into v_context
  from public.optimization_runs_v2 run
  join public.matrix_scenarios_v2 scenario on scenario.id=run.scenario_id
  where run.id=v_variant.run_id;
  v_can_view_finance:=public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE');
  v_workspace:=solver_private.variant_set_workspace_v2(
    array[p_variant_id],v_context,v_can_view_finance
  );
  return solver_private.alpha16_enrich_workspace_issues_v2(v_workspace,array[p_variant_id]);
end;
$$;

create or replace function public.optimizer_leader_variant_for_run_uat_v1(
  p_run_id uuid
) returns jsonb
language plpgsql stable security definer set search_path=''
as $$
declare v_variant public.plan_variants_v2%rowtype;
begin
  if not solver_private.can_access_run_v2(p_run_id) then raise exception 'RUN_NOT_FOUND'; end if;
  select * into v_variant from public.plan_variants_v2
    where run_id=p_run_id and variant_kind='LEADER_COPY'
      and status in ('READY','SELECTED','PUBLISHED')
    order by created_at desc limit 1;
  if v_variant.id is null then return jsonb_build_object('variant',null); end if;
  return jsonb_build_object('variant',jsonb_build_object(
    'id',v_variant.id,'sourceVariantId',v_variant.source_variant_id,
    'name',v_variant.name,'status',v_variant.status,'revision',v_variant.revision,
    'assignmentCount',v_variant.assignment_count,'unfilledCount',v_variant.unfilled_count,
    'lastEditedAt',v_variant.last_edited_at
  ));
end;
$$;

create or replace function public.optimizer_demand_profiles_uat_v1(p_month date)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare
  v_month date:=date_trunc('month',p_month)::date;
  v_matrix_id uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select matrix_version.id into v_matrix_id
  from public.matrix_versions matrix_version
  where matrix_version.status in ('ACTIVE','ARCHIVED')
    and matrix_version.schema_version>=2
    and matrix_version.effective_from<=v_month
    and coalesce(matrix_version.content_hash,'') ~ '^[0-9a-f]{64}$'
    and coalesce(matrix_version.workforce_hash,'') ~ '^[0-9a-f]{64}$'
  order by matrix_version.effective_from desc,matrix_version.version desc limit 1;
  if v_matrix_id is null then raise exception 'MATRIX_V2_FOR_MONTH_NOT_FOUND'; end if;
  return jsonb_build_object('matrixVersionId',v_matrix_id,'profiles',coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',scenario.id,'validFrom',scenario.valid_from,'validTo',scenario.valid_to,
      'profileMode',case
        when scenario.is_default then 'BASELINE'
        when scenario.valid_from is not null or scenario.valid_to is not null then 'PERIOD'
        else 'UNDATED_LEGACY' end
    ) order by scenario.sort_order,scenario.name)
    from public.matrix_scenarios_v2 scenario
    where scenario.matrix_version_id=v_matrix_id and scenario.active
  ),'[]'::jsonb));
end;
$$;

-- The generated-comparison endpoint deliberately excludes the leader's copy,
-- so the three mathematical proposals remain visible and immutable.
create or replace function public.optimizer_variants_v2(p_run_id uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_can_view_finance boolean;
begin
  if not solver_private.can_access_run_v2(p_run_id) then raise exception 'RUN_NOT_FOUND'; end if;
  v_can_view_finance:=public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE');
  return jsonb_build_object('runId',p_run_id,'variants',coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',variant.id,'name',variant.name,
      'strategy',jsonb_build_object('id',strategy.id,'name',strategy.name,'description',strategy.description),
      'status',variant.status,'hardViolations',variant.hard_violations,
      'assignmentCount',variant.assignment_count,'unfilledCount',variant.unfilled_count,
      'totalCostMinor',case when v_can_view_finance then finance.total_cost_minor else null end,
      'budgetMinor',case when v_can_view_finance then finance.budget_minor else null end,
      'currency',case when v_can_view_finance then finance.currency else null end,
      'solverStatus',variant.solver_status,'recommended',variant.recommended,
      'selected',variant.selected,'equivalentToVariantId',variant.equivalent_to_variant_id,
      'metrics',variant.metrics
    ) order by run_strategy.ordinal)
    from public.plan_variants_v2 variant
    join public.optimization_run_strategies_v2 run_strategy
      on run_strategy.id=variant.run_strategy_id
    join public.matrix_strategies_v2 strategy on strategy.id=variant.strategy_id
    left join solver_private.plan_variant_finance_v2 finance on finance.variant_id=variant.id
    where variant.run_id=p_run_id and variant.variant_kind='GENERATED'
  ),'[]'::jsonb));
end;
$$;

revoke all on function solver_private.can_edit_leader_variant_uat_v1(uuid),
  solver_private.refresh_leader_variant_uat_v1(uuid,uuid,text) from public,anon,authenticated;
revoke all on function public.optimizer_create_leader_variant_uat_v1(uuid,uuid,text),
  public.optimizer_leader_assignment_context_uat_v1(uuid,uuid,bigint),
  public.optimizer_leader_assignment_save_uat_v1(uuid,uuid,bigint,uuid,text),
  public.optimizer_leader_assignment_remove_uat_v1(uuid,uuid,text),
  public.optimizer_leader_variant_workspace_uat_v1(uuid),
  public.optimizer_leader_variant_for_run_uat_v1(uuid),
  public.optimizer_demand_profiles_uat_v1(date) from public,anon,authenticated;
grant execute on function public.optimizer_create_leader_variant_uat_v1(uuid,uuid,text),
  public.optimizer_leader_assignment_context_uat_v1(uuid,uuid,bigint),
  public.optimizer_leader_assignment_save_uat_v1(uuid,uuid,bigint,uuid,text),
  public.optimizer_leader_assignment_remove_uat_v1(uuid,uuid,text),
  public.optimizer_leader_variant_workspace_uat_v1(uuid),
  public.optimizer_leader_variant_for_run_uat_v1(uuid),
  public.optimizer_demand_profiles_uat_v1(date) to authenticated;

comment on column public.plan_variants_v2.variant_kind is
  'GENERATED proposals are immutable; LEADER_COPY is an independently validated pre-publication working copy.';
