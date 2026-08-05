-- UAT-006 critical workflow repairs. This migration is scoped to the isolated
-- UAT branch and does not publish a Matrix or a schedule by itself.

-- A required role duty with a zero minimum is contradictory. Keep historical
-- rows readable, while blocking every new insert/update that would repeat it.
alter table public.matrix_role_duties_v2
  add constraint matrix_role_duties_required_positive_uat006
  check (assignment_mode <> 'REQUIRED' or minimum_count >= 1) not valid;

-- If an active staffing rule already names a duty for a role in the draft,
-- expose that relationship in the role-duty source of truth. Existing active
-- and archived Matrix versions remain immutable.
insert into public.matrix_role_duties_v2(
  matrix_version_id,role_id,duty_id,assignment_mode,minimum_count,active
)
select distinct rule.matrix_version_id,rule.role_id,rule.duty_id,'OPTIONAL',0,true
from public.matrix_staffing_rules_v2 rule
join public.matrix_versions version on version.id=rule.matrix_version_id
where version.status='DRAFT' and rule.active and rule.duty_id is not null
  and not exists(
    select 1 from public.matrix_role_duties_v2 link
    where link.matrix_version_id=rule.matrix_version_id
      and link.role_id=rule.role_id and link.duty_id=rule.duty_id
  )
on conflict do nothing;

create or replace function solver_private.staffing_duty_link_guard_uat006()
returns trigger language plpgsql security definer set search_path=''
as $$
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

drop trigger if exists staffing_duty_link_guard_uat006
  on public.matrix_staffing_rules_v2;
create trigger staffing_duty_link_guard_uat006
before insert or update of matrix_version_id,role_id,duty_id,active
on public.matrix_staffing_rules_v2 for each row
execute function solver_private.staffing_duty_link_guard_uat006();

create or replace function public.matrix_v2_duty_archive_preview_uat_v2(
  p_duty_id uuid
) returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_matrix uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  select duty.matrix_version_id into v_matrix
  from public.matrix_duties_v2 duty where duty.id=p_duty_id;
  if v_matrix is null then raise exception 'DUTY_NOT_FOUND'; end if;
  return jsonb_build_object(
    'dutyId',p_duty_id,
    'roleDuties',(select count(*) from public.matrix_role_duties_v2 link
      where link.matrix_version_id=v_matrix and link.duty_id=p_duty_id and link.active),
    'employeeDuties',(select count(*) from public.matrix_employee_duties_v2 link
      where link.matrix_version_id=v_matrix and link.duty_id=p_duty_id and link.active),
    'staffingRules',(select count(*) from public.matrix_staffing_rules_v2 rule
      where rule.matrix_version_id=v_matrix and rule.duty_id=p_duty_id and rule.active),
    'payRules',(select count(*) from public.matrix_pay_rule_duties_v2 link
      where link.matrix_version_id=v_matrix and link.duty_id=p_duty_id)
  );
end;
$$;

-- Extend the existing publication preflight without duplicating its employee,
-- pay-rate and shift checks.
alter function public.matrix_v2_publication_readiness_uat_v2(date,date)
  rename to matrix_v2_publication_readiness_base_uat006;

create function public.matrix_v2_publication_readiness_uat_v2(
  p_effective_from date,p_schedule_month date
) returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_base jsonb; v_matrix uuid; v_extra jsonb:='[]'::jsonb;
  v_base_blockers jsonb:='[]'::jsonb; v_all_blockers jsonb:='[]'::jsonb;
begin
  v_base:=public.matrix_v2_publication_readiness_base_uat006(
    p_effective_from,p_schedule_month
  );
  v_matrix:=nullif(v_base->>'matrixVersionId','')::uuid;
  select coalesce(jsonb_agg(value),'[]'::jsonb) into v_base_blockers
  from jsonb_array_elements(coalesce(v_base->'blockers','[]'::jsonb))
  where value->>'code'<>'SHIFT_PERIOD_MISMATCH';
  select coalesce(jsonb_agg(problem),'[]'::jsonb) into v_extra from (
    select jsonb_build_object(
      'code','REQUIRED_DUTY_WITH_ZERO_MINIMUM','roleId',link.role_id,
      'dutyId',link.duty_id,'message',
      'Obowiązek wymagany musi mieć minimalną liczbę co najmniej 1.'
    ) problem
    from public.matrix_role_duties_v2 link
    where link.matrix_version_id=v_matrix and link.active
      and link.assignment_mode='REQUIRED' and link.minimum_count<1
    union all
    select jsonb_build_object(
      'code','STAFFING_DUTY_NOT_LINKED_TO_ROLE','roleId',rule.role_id,
      'dutyId',rule.duty_id,'shiftTemplateId',rule.shift_template_id,
      'message','Reguła obsady używa obowiązku nieprzypisanego do tej roli.'
    )
    from public.matrix_staffing_rules_v2 rule
    where rule.matrix_version_id=v_matrix and rule.active and rule.duty_id is not null
      and not exists(select 1 from public.matrix_role_duties_v2 link
        where link.matrix_version_id=rule.matrix_version_id
          and link.role_id=rule.role_id and link.duty_id=rule.duty_id and link.active)
    union all
    select jsonb_build_object(
      'code','INACTIVE_DUTY_HAS_ACTIVE_DEPENDENCIES','dutyId',duty.id,
      'message','Wyłączony obowiązek nadal ma aktywne zależności.'
    )
    from public.matrix_duties_v2 duty
    where duty.matrix_version_id=v_matrix and not duty.active and (
      exists(select 1 from public.matrix_role_duties_v2 link
        where link.matrix_version_id=v_matrix and link.duty_id=duty.id and link.active)
      or exists(select 1 from public.matrix_employee_duties_v2 link
        where link.matrix_version_id=v_matrix and link.duty_id=duty.id and link.active)
      or exists(select 1 from public.matrix_staffing_rules_v2 rule
        where rule.matrix_version_id=v_matrix and rule.duty_id=duty.id and rule.active)
    )
    union all
    select jsonb_build_object(
      'code','SHIFT_PERIOD_FROM_TIME_MISMATCH','shiftTemplateId',shift_row.id,
      'shiftName',shift_row.name,'shiftCode',shift_row.code,
      'message','Automatyczna klasyfikacja zmiany jest niespójna z godziną rozpoczęcia.'
    )
    from public.matrix_shift_templates_v2 shift_row
    where shift_row.matrix_version_id=v_matrix and shift_row.active
      and shift_row.shift_period is distinct from case
        when extract(hour from shift_row.starts_at)<12 then 'MORNING'
        when extract(hour from shift_row.starts_at)<17 then 'MIDDLE'
        else 'EVENING' end
  ) problems;
  v_all_blockers:=v_base_blockers||v_extra;
  return v_base||jsonb_build_object(
    'ready',jsonb_array_length(v_all_blockers)=0,
    'blockers',v_all_blockers
  );
end;
$$;

create or replace function public.matrix_v2_normalize_shift_periods_uat_v2()
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_matrix uuid; v_updated integer:=0; v_recognized integer:=0;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  v_matrix:=public.matrix_v2_create_draft(null);
  select count(*) into v_recognized from public.matrix_shift_templates_v2 shift_row
  where shift_row.matrix_version_id=v_matrix and shift_row.active;
  update public.matrix_shift_templates_v2 shift_row set
    shift_period=case when extract(hour from shift_row.starts_at)<12 then 'MORNING'
      when extract(hour from shift_row.starts_at)<17 then 'MIDDLE' else 'EVENING' end,
    updated_at=now()
  where shift_row.matrix_version_id=v_matrix and shift_row.active
    and shift_row.shift_period is distinct from case
      when extract(hour from shift_row.starts_at)<12 then 'MORNING'
      when extract(hour from shift_row.starts_at)<17 then 'MIDDLE' else 'EVENING' end;
  get diagnostics v_updated=row_count;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_v2_shift_periods',v_matrix::text,'NORMALIZE_FROM_START_TIME',
    jsonb_build_object('recognized',v_recognized,'updated',v_updated,
      'morningBefore','12:00','middleBefore','17:00'));
  return jsonb_build_object('matrixVersionId',v_matrix,
    'recognized',v_recognized,'updated',v_updated);
end;
$$;

create or replace function public.matrix_v2_merge_equivalent_shifts_uat_v2(
  p_apply boolean default false
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_matrix uuid; v_groups integer:=0; v_duplicates integer:=0;
  v_blockers jsonb:='[]'::jsonb; v_preview jsonb:='[]'::jsonb;
  group_row record; rule_row public.matrix_staffing_rules_v2%rowtype;
  v_existing public.matrix_staffing_rules_v2%rowtype;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  select version.id into v_matrix from public.matrix_versions version
  where version.status='DRAFT' and version.schema_version>=2
  order by version.version desc limit 1;
  if v_matrix is null then raise exception 'NO_MATRIX_V2_DRAFT'; end if;

  with groups as (
    select min(shift.id::text)::uuid survivor_id,
      array_agg(shift.id order by shift.sort_order,shift.id) ids,
      min(shift.name) name,min(shift.location_id) location_id,
      min(shift.starts_at) starts_at,min(shift.ends_at) ends_at,
      count(*) amount
    from public.matrix_shift_templates_v2 shift
    where shift.matrix_version_id=v_matrix and shift.active
    group by shift.location_id,lower(trim(shift.name)),shift.starts_at,
      shift.ends_at,shift.ends_next_day
    having count(*)>1
  )
  select count(*),coalesce(sum(amount-1),0),coalesce(jsonb_agg(jsonb_build_object(
    'name',name,'locationId',location_id,'startsAt',starts_at,'endsAt',ends_at,
    'entries',amount,'survivorId',survivor_id,'ids',to_jsonb(ids)
  ) order by name),'[]'::jsonb)
  into v_groups,v_duplicates,v_preview from groups;

  with groups as (
    select (array_agg(shift.id order by shift.sort_order,shift.id))[1] survivor_id,
      (array_agg(shift.id order by shift.sort_order,shift.id))[2:] duplicate_ids
    from public.matrix_shift_templates_v2 shift
    where shift.matrix_version_id=v_matrix and shift.active
    group by shift.location_id,lower(trim(shift.name)),shift.starts_at,
      shift.ends_at,shift.ends_next_day having count(*)>1
  ), conflicts as (
    select jsonb_build_object('code','STAFFING_RULE_CONFLICT','message',
      'Powielone zmiany mają różne reguły obsady dla tego samego zakresu.') blocker
    from groups
    join public.matrix_staffing_rules_v2 duplicate
      on duplicate.shift_template_id=any(groups.duplicate_ids)
    join public.matrix_staffing_rules_v2 survivor
      on survivor.shift_template_id=groups.survivor_id
      and survivor.scenario_id=duplicate.scenario_id
      and survivor.role_id=duplicate.role_id
      and survivor.duty_id is not distinct from duplicate.duty_id
    where row(survivor.operation,survivor.count_value,
      survivor.multiplier_basis_points,survivor.active)
      is distinct from row(duplicate.operation,duplicate.count_value,
        duplicate.multiplier_basis_points,duplicate.active)
    union all
    select jsonb_build_object('code','EVENT_DEMAND_REFERENCE','message',
      'Co najmniej jeden powielony wpis jest używany przez aktywny event.')
    from groups join public.workforce_event_demand_v2 demand
      on demand.shift_template_id=any(groups.duplicate_ids)
    join public.workforce_calendar_events_v2 event on event.id=demand.event_id
    where event.status='ACTIVE'
  )
  select coalesce(jsonb_agg(distinct blocker),'[]'::jsonb)
    into v_blockers from conflicts;

  if not p_apply then return jsonb_build_object(
    'matrixVersionId',v_matrix,'groups',v_groups,'duplicates',v_duplicates,
    'items',v_preview,'blockers',v_blockers,'applied',false
  ); end if;
  if jsonb_array_length(v_blockers)>0 then
    raise exception 'SHIFT_MERGE_BLOCKED:%',v_blockers::text;
  end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));

  for group_row in
    select (array_agg(shift.id order by shift.sort_order,shift.id))[1] survivor_id,
      (array_agg(shift.id order by shift.sort_order,shift.id))[2:] duplicate_ids,
      array_agg(distinct day_value order by day_value)::smallint[] merged_days
    from public.matrix_shift_templates_v2 shift
    cross join lateral unnest(shift.day_mask) day_value
    where shift.matrix_version_id=v_matrix and shift.active
    group by shift.location_id,lower(trim(shift.name)),shift.starts_at,
      shift.ends_at,shift.ends_next_day having count(distinct shift.id)>1
  loop
    update public.matrix_shift_templates_v2 set day_mask=group_row.merged_days,
      shift_period=case when extract(hour from starts_at)<12 then 'MORNING'
        when extract(hour from starts_at)<17 then 'MIDDLE' else 'EVENING' end,
      updated_at=now() where id=group_row.survivor_id;

    for rule_row in select * from public.matrix_staffing_rules_v2
      where shift_template_id=any(group_row.duplicate_ids)
    loop
      select * into v_existing from public.matrix_staffing_rules_v2 existing
      where existing.shift_template_id=group_row.survivor_id
        and existing.scenario_id=rule_row.scenario_id
        and existing.role_id=rule_row.role_id
        and existing.duty_id is not distinct from rule_row.duty_id limit 1;
      if v_existing.id is null then
        update public.matrix_staffing_rules_v2
          set shift_template_id=group_row.survivor_id,updated_at=now()
        where id=rule_row.id;
      else
        delete from public.matrix_staffing_rules_v2 where id=rule_row.id;
      end if;
      v_existing:=null;
    end loop;

    insert into public.matrix_pay_rule_shifts_v2(
      matrix_version_id,pay_rule_id,shift_template_id
    ) select distinct mapping.matrix_version_id,mapping.pay_rule_id,
      group_row.survivor_id
    from public.matrix_pay_rule_shifts_v2 mapping
    where mapping.shift_template_id=any(group_row.duplicate_ids)
    on conflict do nothing;
    delete from public.matrix_pay_rule_shifts_v2 mapping
      where mapping.shift_template_id=any(group_row.duplicate_ids);
    update public.matrix_shift_templates_v2 set active=false,updated_at=now()
      where id=any(group_row.duplicate_ids);
  end loop;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_v2_shifts',v_matrix::text,'MERGE_EQUIVALENT_SHIFTS',
    jsonb_build_object('groups',v_groups,'duplicates',v_duplicates,'items',v_preview));
  return jsonb_build_object(
    'matrixVersionId',v_matrix,'groups',v_groups,'duplicates',v_duplicates,
    'items',v_preview,'blockers','[]'::jsonb,'applied',true
  );
end;
$$;

-- Preserve the original complete candidate validator, then add the approved
-- alternate-duty coverage rule: a missing duty may be covered by another
-- effective employee who remains on the same shift.
alter function solver_private.swap_candidate_reasons_uat_v2(uuid,uuid)
  rename to swap_candidate_reasons_direct_uat_v2;

create function solver_private.swap_alternate_duty_coverage_uat_v2(
  p_request_id uuid,p_employee_id uuid
) returns jsonb language plpgsql stable security definer set search_path=''
as $$
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

create function solver_private.swap_candidate_reasons_uat_v2(
  p_request_id uuid,p_employee_id uuid
) returns text[] language plpgsql stable security definer set search_path=''
as $$
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

create or replace function public.shift_swap_candidates_uat_v2(
  p_assignment_id uuid
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_employee uuid;
  v_assignment public.plan_assignments_v2%rowtype;
  v_shift public.plan_shifts_v2%rowtype; v_matrix uuid;
  v_request_id uuid; v_preview boolean:=false; v_result jsonb;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select employee.id into v_employee from public.employees employee
  where employee.auth_user_id=v_actor and employee.active
    and employee.archived_at is null order by employee.employee_no limit 1;
  select * into v_assignment from public.plan_assignments_v2
    where id=p_assignment_id;
  if v_assignment.id is null then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
  if v_assignment.employee_id<>v_employee then raise exception 'NOT_OWN_ASSIGNMENT'; end if;
  if not solver_private.assignment_is_currently_published_v2(v_assignment.id)
    then raise exception 'ASSIGNMENT_NOT_PUBLISHED'; end if;
  select * into v_shift from public.plan_shifts_v2 where id=v_assignment.shift_id;
  if v_shift.starts_at<=now() then raise exception 'SHIFT_ALREADY_STARTED'; end if;
  select run.matrix_version_id into v_matrix from public.plan_variants_v2 variant
  join public.optimization_runs_v2 run on run.id=variant.run_id
  where variant.id=v_assignment.variant_id;
  select request.id into v_request_id from public.shift_swap_requests_v2 request
  where request.original_assignment_id=v_assignment.id
    and request.status in ('OPEN','EMPLOYEE_ACCEPTED') limit 1;
  if v_request_id is null then
    v_request_id:=gen_random_uuid(); v_preview:=true;
    insert into public.shift_swap_requests_v2(
      id,month,matrix_version_id,original_assignment_id,role_id,
      proposer_employee_id,created_by
    ) values(v_request_id,date_trunc('month',v_shift.shift_date)::date,v_matrix,
      v_assignment.id,v_assignment.role_id,v_employee,v_actor);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'employeeId',profile.employee_id,'employeeNo',profile.employee_no,
    'name',profile.first_name||' '||profile.last_name,
    'eligible',cardinality(candidate.reasons)=0,
    'reasons',to_jsonb(candidate.reasons)
  ) order by (cardinality(candidate.reasons)=0) desc,
    profile.last_name,profile.first_name),'[]'::jsonb)
  into v_result
  from public.matrix_employee_profiles_v2 profile
  join public.matrix_employee_roles_v2 role_grant
    on role_grant.matrix_version_id=profile.matrix_version_id
    and role_grant.employee_id=profile.employee_id
    and role_grant.role_id=v_assignment.role_id and role_grant.active
  cross join lateral (select solver_private.swap_candidate_reasons_uat_v2(
    v_request_id,profile.employee_id
  ) reasons) candidate
  where profile.matrix_version_id=v_matrix and profile.active
    and profile.archived_at is null;
  if v_preview then delete from public.shift_swap_requests_v2 where id=v_request_id; end if;
  return v_result;
end;
$$;

-- Add participant names and the immutable request history to the board result.
create or replace function public.shift_swap_board_uat_v2(p_month date)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_employee uuid;
  v_month date:=date_trunc('month',p_month)::date;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select employee.id into v_employee from public.employees employee
  where employee.auth_user_id=v_actor and employee.active
    and employee.archived_at is null order by employee.employee_no limit 1;
  return jsonb_build_object(
    'employeeId',v_employee,'month',v_month,'canManage',public.can_manage_plans(),
    'requests',coalesce((select jsonb_agg(jsonb_build_object(
      'id',request.id,'status',request.status,'message',request.message,
      'assignmentId',assignment.id,'date',shift.shift_date,
      'startsAt',shift.starts_at,'endsAt',shift.ends_at,
      'locationName',location.name,'shiftName',template.name,
      'roleId',request.role_id,'roleName',role.name,
      'proposerEmployeeId',request.proposer_employee_id,
      'proposerName',proposer.first_name||' '||proposer.last_name,
      'targetEmployeeId',request.target_employee_id,
      'targetName',case when target.id is null then null
        else target.first_name||' '||target.last_name end,
      'acceptedByEmployeeId',request.accepted_by_employee_id,
      'acceptedByName',case when accepted.id is null then null
        else accepted.first_name||' '||accepted.last_name end,
      'eligible',case when v_employee is null then false else cardinality(
        solver_private.swap_candidate_reasons_uat_v2(request.id,v_employee))=0 end,
      'ineligibilityReasons',case when v_employee is null then '[]'::jsonb
        else to_jsonb(solver_private.swap_candidate_reasons_uat_v2(
          request.id,v_employee)) end,
      'isMine',request.proposer_employee_id=v_employee,
      'requiresLeaderDecision',request.status='EMPLOYEE_ACCEPTED',
      'history',coalesce((select jsonb_agg(jsonb_build_object(
        'id',history.id,'action',history.action,'details',history.details,
        'createdAt',history.created_at,'actorName',coalesce(
          nullif(concat_ws(' ',actor_employee.first_name,actor_employee.last_name),''),
          actor_user.email,'System')
      ) order by history.created_at,history.id)
        from public.shift_swap_history_v2 history
        left join public.employees actor_employee
          on actor_employee.auth_user_id=history.actor_id
        left join auth.users actor_user on actor_user.id=history.actor_id
        where history.request_id=request.id),'[]'::jsonb)
    ) order by shift.starts_at,request.created_at)
      from public.shift_swap_requests_v2 request
      join public.plan_assignments_v2 assignment
        on assignment.id=request.original_assignment_id
      join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
      join public.matrix_locations_v2 location on location.id=shift.location_id
      join public.matrix_shift_templates_v2 template
        on template.id=shift.shift_template_id
      join public.matrix_roles_v2 role on role.id=request.role_id
      join public.matrix_employee_profiles_v2 proposer
        on proposer.matrix_version_id=request.matrix_version_id
        and proposer.employee_id=request.proposer_employee_id
      left join public.matrix_employee_profiles_v2 target
        on target.matrix_version_id=request.matrix_version_id
        and target.employee_id=request.target_employee_id
      left join public.matrix_employee_profiles_v2 accepted
        on accepted.matrix_version_id=request.matrix_version_id
        and accepted.employee_id=request.accepted_by_employee_id
      where request.month=v_month and (
        request.proposer_employee_id=v_employee
        or request.target_employee_id=v_employee
        or request.accepted_by_employee_id=v_employee
        or (request.status='OPEN' and v_employee is not null and cardinality(
          solver_private.swap_candidate_reasons_uat_v2(request.id,v_employee))=0)
        or public.can_manage_plans()
      )),'[]'::jsonb)
  );
end;
$$;

create or replace function solver_private.swap_history_coverage_uat006()
returns trigger language plpgsql security definer set search_path=''
as $$
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

drop trigger if exists shift_swap_history_coverage_uat006
  on public.shift_swap_history_v2;
create trigger shift_swap_history_coverage_uat006
before insert on public.shift_swap_history_v2 for each row
execute function solver_private.swap_history_coverage_uat006();

-- Enrich the leader summary with team size, remaining availability, progress
-- and the last signal timestamp while preserving the established v3 payload.
alter function public.workforce_calendar_context_uat_v3(date)
  rename to workforce_calendar_context_base_uat006;

create function public.workforce_calendar_context_uat_v3(p_month date)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_base jsonb; v_matrix uuid; v_timezone text; v_summary jsonb;
begin
  v_base:=public.workforce_calendar_context_base_uat006(p_month);
  if not public.can_manage_plans() then return v_base; end if;
  v_matrix:=nullif(v_base->>'matrixVersionId','')::uuid;
  select coalesce(nullif(version.settings->>'timezone',''),'Europe/Warsaw')
    into v_timezone from public.matrix_versions version where version.id=v_matrix;
  with items as (
    select value item,(value->>'date')::date work_date,
      (value->>'roleId')::uuid role_id
    from jsonb_array_elements(coalesce(v_base->'availabilitySummary','[]'::jsonb))
  ), enriched as (
    select items.*,
      (select count(distinct grant_row.employee_id)
        from public.matrix_employee_roles_v2 grant_row
        join public.matrix_employee_profiles_v2 profile
          on profile.matrix_version_id=grant_row.matrix_version_id
          and profile.employee_id=grant_row.employee_id
        where grant_row.matrix_version_id=v_matrix and grant_row.role_id=items.role_id
          and grant_row.active and profile.active and profile.archived_at is null
          and (grant_row.valid_from is null or grant_row.valid_from<=items.work_date)
          and (grant_row.valid_to is null or grant_row.valid_to>=items.work_date)
          and (profile.employment_start is null or profile.employment_start<=items.work_date)
          and (profile.employment_end is null or profile.employment_end>=items.work_date)
      ) total_count,
      (select count(distinct signal.employee_id) from (
        select constraint_row.employee_id
        from public.employee_time_constraints_v2 constraint_row
        where constraint_row.status='ACTIVE'
          and constraint_row.time_range&&tstzrange(
            items.work_date::timestamp at time zone v_timezone,
            (items.work_date+1)::timestamp at time zone v_timezone,'[)')
        union
        select preference.employee_id from public.employee_preferences preference
        where preference.status='ACTIVE' and preference.valid_from<=items.work_date
          and preference.valid_to>=items.work_date
        union
        select review.employee_id from public.availability_exception_reviews_v2 review
        where review.work_date=items.work_date and review.role_id=items.role_id
          and review.status='PENDING'
      ) signal join public.matrix_employee_roles_v2 grant_row
        on grant_row.matrix_version_id=v_matrix
        and grant_row.employee_id=signal.employee_id
        and grant_row.role_id=items.role_id and grant_row.active
      ) recorded_count,
      (select max(stamp) from (
        select max(constraint_row.updated_at) stamp
        from public.employee_time_constraints_v2 constraint_row
        where constraint_row.status='ACTIVE'
          and constraint_row.time_range&&tstzrange(
            items.work_date::timestamp at time zone v_timezone,
            (items.work_date+1)::timestamp at time zone v_timezone,'[)')
        union all
        select max(preference.created_at) from public.employee_preferences preference
        where preference.status='ACTIVE' and preference.valid_from<=items.work_date
          and preference.valid_to>=items.work_date
        union all
        select max(review.requested_at) from public.availability_exception_reviews_v2 review
        where review.work_date=items.work_date and review.role_id=items.role_id
      ) stamps) last_updated_at
    from items
  )
  select coalesce(jsonb_agg(item||jsonb_build_object(
    'totalCount',total_count,
    'availableCount',greatest(total_count-coalesce((item->>'hardCount')::integer,0)
      -coalesce((item->>'pendingCount')::integer,0),0),
    'recordedCount',recorded_count,
    'progressPercent',case when total_count=0 then 100
      else round(recorded_count::numeric*100/total_count)::integer end,
    'lastUpdatedAt',last_updated_at
  ) order by work_date,item->>'roleName'),'[]'::jsonb)
  into v_summary from enriched;
  return jsonb_set(v_base,'{availabilitySummary}',v_summary,true);
end;
$$;

revoke all on function public.matrix_v2_duty_archive_preview_uat_v2(uuid),
  public.matrix_v2_merge_equivalent_shifts_uat_v2(boolean),
  public.matrix_v2_normalize_shift_periods_uat_v2(),
  public.matrix_v2_publication_readiness_uat_v2(date,date),
  public.matrix_v2_publication_readiness_base_uat006(date,date),
  public.shift_swap_candidates_uat_v2(uuid),
  public.shift_swap_board_uat_v2(date),
  public.workforce_calendar_context_uat_v3(date),
  public.workforce_calendar_context_base_uat006(date)
from public,anon,authenticated;
grant execute on function public.matrix_v2_duty_archive_preview_uat_v2(uuid),
  public.matrix_v2_merge_equivalent_shifts_uat_v2(boolean),
  public.matrix_v2_normalize_shift_periods_uat_v2(),
  public.matrix_v2_publication_readiness_uat_v2(date,date),
  public.shift_swap_candidates_uat_v2(uuid),
  public.shift_swap_board_uat_v2(date),
  public.workforce_calendar_context_uat_v3(date)
to authenticated;

revoke all on function solver_private.staffing_duty_link_guard_uat006(),
  solver_private.swap_candidate_reasons_direct_uat_v2(uuid,uuid),
  solver_private.swap_candidate_reasons_uat_v2(uuid,uuid),
  solver_private.swap_alternate_duty_coverage_uat_v2(uuid,uuid),
  solver_private.swap_history_coverage_uat006()
from public,anon,authenticated;

notify pgrst,'reload schema';
