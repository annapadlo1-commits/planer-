-- B4 UAT: explainable swap suggestions with availability and an atomic duty
-- hand-off to another qualified employee already working the same shift.

create or replace function public.optimizer_leader_assignment_context_uat_v2(
  p_variant_id uuid,p_assignment_id uuid default null,p_issue_id bigint default null
) returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_variant public.plan_variants_v2%rowtype; v_run public.optimization_runs_v2%rowtype;
  v_shift public.plan_shifts_v2%rowtype; v_assignment public.plan_assignments_v2%rowtype;
  v_issue public.plan_issues_v2%rowtype; v_role_id uuid; v_slot_key text; v_duty_id uuid;
  v_default_available boolean:=true; v_daily_limit integer:=1;
begin
  if (p_assignment_id is null)=(p_issue_id is null) then raise exception 'ASSIGNMENT_OR_ISSUE_REQUIRED'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then raise exception 'LEADER_VARIANT_NOT_EDITABLE'; end if;
  select * into v_variant from public.plan_variants_v2 where id=p_variant_id;
  select * into v_run from public.optimization_runs_v2 where id=v_variant.run_id;
  select coalesce((settings->>'missingAvailabilityMeansAvailable')::boolean,true)
    into v_default_available from public.matrix_versions where id=v_run.matrix_version_id;
  select greatest(1,coalesce(nullif(settings->>'maximumShiftsPerDay','')::integer,1))
    into v_daily_limit from public.matrix_versions where id=v_run.matrix_version_id;
  if p_assignment_id is not null then
    select * into v_assignment from public.plan_assignments_v2 where id=p_assignment_id and variant_id=p_variant_id;
    if v_assignment.id is null then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
    select * into v_shift from public.plan_shifts_v2 where id=v_assignment.shift_id;
    v_role_id:=v_assignment.role_id;v_slot_key:=v_assignment.slot_key;
    select duty_id into v_duty_id from public.plan_assignment_duties_v2
      where assignment_id=v_assignment.id order by duty_id limit 1;
  else
    select * into v_issue from public.plan_issues_v2
      where id=p_issue_id and variant_id=p_variant_id and issue_code='UNFILLED_SLOT';
    if v_issue.id is null then raise exception 'UNFILLED_ISSUE_NOT_FOUND'; end if;
    select * into v_shift from public.plan_shifts_v2 where id=v_issue.shift_id;
    v_role_id:=v_issue.role_id;v_slot_key:=v_issue.slot_key;v_duty_id:=v_issue.duty_id;
  end if;
  return jsonb_build_object(
    'variantId',p_variant_id,'assignmentId',p_assignment_id,'issueId',p_issue_id,
    'slotKey',v_slot_key,'currentEmployeeId',v_assignment.employee_id,
    'role',jsonb_build_object('id',role.id,'name',role.name),
    'duty',case when duty.id is null then null else jsonb_build_object('id',duty.id,'name',duty.name) end,
    'shift',jsonb_build_object('id',v_shift.id,'date',v_shift.shift_date,'startsAt',v_shift.starts_at,
      'endsAt',v_shift.ends_at,'locationId',v_shift.location_id,'locationName',location.name,'shiftName',template.name),
    'candidates',coalesce((select jsonb_agg(jsonb_build_object(
      'employeeId',candidate.employee_id,'employeeNo',candidate.employee_no,'employeeName',candidate.employee_name,
      'current',candidate.employee_id=v_assignment.employee_id,'roleName',role.name,'locationName',location.name,
      'dutyName',case when candidate.duty_match then duty.name else null end,
      'dutyMatch',candidate.duty_match,'dutyCoverageMode',case when v_duty_id is null or candidate.duty_match then 'DIRECT'
        when transfer.assignment_id is not null then 'TRANSFER' else 'NOT_COVERED' end,
      'dutyTransferAssignmentId',transfer.assignment_id,'dutyTransferEmployeeId',transfer.employee_id,
      'dutyTransferEmployeeName',transfer.employee_name,
      'availabilityStatus',candidate.availability_status,
      'suggestionEligible',candidate.availability_status in ('AVAILABLE','SOFT_AVOID')
        and (v_duty_id is null or candidate.duty_match or transfer.assignment_id is not null)
    ) order by (candidate.availability_status in ('AVAILABLE','SOFT_AVOID')
        and (v_duty_id is null or candidate.duty_match or transfer.assignment_id is not null)) desc,
      candidate.last_name,candidate.first_name,candidate.employee_no)
      from (
        select employee.id employee_id,employee.employee_no,employee.first_name,employee.last_name,
          trim(employee.first_name||' '||employee.last_name) employee_name,
          (v_duty_id is null or exists(select 1 from public.matrix_employee_duties_v2 grant_row
            where grant_row.matrix_version_id=v_run.matrix_version_id and grant_row.employee_id=employee.id
              and grant_row.duty_id=v_duty_id and grant_row.active
              and (grant_row.role_id is null or grant_row.role_id=v_role_id)
              and (grant_row.location_id is null or grant_row.location_id=v_shift.location_id)
              and (grant_row.valid_from is null or grant_row.valid_from<=v_shift.shift_date)
              and (grant_row.valid_to is null or grant_row.valid_to>=v_shift.shift_date))) duty_match,
          case
            when exists(select 1 from public.employee_time_constraints_v2 constraint_row
              where constraint_row.employee_id=employee.id and constraint_row.status='ACTIVE'
                and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
                and constraint_row.time_range&&tstzrange(v_shift.starts_at,v_shift.ends_at,'[)')) then 'HARD_UNAVAILABLE'
            when exists(select 1 from public.plan_assignments_v2 occupied
              join public.plan_shifts_v2 occupied_shift on occupied_shift.id=occupied.shift_id
              where occupied.variant_id=p_variant_id and occupied.employee_id=employee.id
                and occupied.id is distinct from p_assignment_id
                and tstzrange(occupied_shift.starts_at,occupied_shift.ends_at,'[)')
                  &&tstzrange(v_shift.starts_at,v_shift.ends_at,'[)')) then 'SHIFT_CONFLICT'
            when (select count(*) from public.plan_assignments_v2 occupied
              join public.plan_shifts_v2 occupied_shift on occupied_shift.id=occupied.shift_id
              where occupied.variant_id=p_variant_id and occupied.employee_id=employee.id
                and occupied.id is distinct from p_assignment_id
                and occupied_shift.shift_date=v_shift.shift_date)>=v_daily_limit then 'DAILY_LIMIT'
            when not v_default_available and not exists(select 1 from public.employee_time_constraints_v2 window_row
              where window_row.employee_id=employee.id and window_row.status='ACTIVE'
                and window_row.constraint_kind='AVAILABLE_WINDOW'
                and lower(window_row.time_range)<=v_shift.starts_at and upper(window_row.time_range)>=v_shift.ends_at) then 'OUTSIDE_AVAILABLE_WINDOW'
            when exists(select 1 from public.employee_time_constraints_v2 preference
              where preference.employee_id=employee.id and preference.status='ACTIVE'
                and preference.constraint_kind='PREFER_NOT_TO_WORK'
                and preference.time_range&&tstzrange(v_shift.starts_at,v_shift.ends_at,'[)')) then 'SOFT_AVOID'
            else 'AVAILABLE' end availability_status
        from public.employees employee
        where employee.active and employee.archived_at is null
          and (employee.employment_start is null or employee.employment_start<=v_shift.shift_date)
          and (employee.employment_end is null or employee.employment_end>=v_shift.shift_date)
          and exists(select 1 from public.matrix_employee_roles_v2 grant_row
            where grant_row.matrix_version_id=v_run.matrix_version_id and grant_row.employee_id=employee.id
              and grant_row.role_id=v_role_id and grant_row.active
              and (grant_row.valid_from is null or grant_row.valid_from<=v_shift.shift_date)
              and (grant_row.valid_to is null or grant_row.valid_to>=v_shift.shift_date))
          and exists(select 1 from public.matrix_employee_locations_v2 grant_row
            where grant_row.matrix_version_id=v_run.matrix_version_id and grant_row.employee_id=employee.id
              and grant_row.location_id=v_shift.location_id and grant_row.active and grant_row.standard_allowed
              and (grant_row.valid_from is null or grant_row.valid_from<=v_shift.shift_date)
              and (grant_row.valid_to is null or grant_row.valid_to>=v_shift.shift_date))
      ) candidate
      left join lateral (
        select transfer_assignment.id assignment_id,transfer_employee.id employee_id,
          trim(transfer_employee.first_name||' '||transfer_employee.last_name) employee_name
        from public.plan_assignments_v2 transfer_assignment
        join public.employees transfer_employee on transfer_employee.id=transfer_assignment.employee_id
        where v_duty_id is not null and not candidate.duty_match
          and transfer_assignment.variant_id=p_variant_id and transfer_assignment.shift_id=v_shift.id
          and transfer_assignment.id is distinct from p_assignment_id and transfer_assignment.role_id=v_role_id
          and transfer_assignment.employee_id<>candidate.employee_id
          and exists(select 1 from public.matrix_employee_duties_v2 grant_row
            where grant_row.matrix_version_id=v_run.matrix_version_id
              and grant_row.employee_id=transfer_assignment.employee_id and grant_row.duty_id=v_duty_id
              and grant_row.active and (grant_row.role_id is null or grant_row.role_id=v_role_id)
              and (grant_row.location_id is null or grant_row.location_id=v_shift.location_id)
              and (grant_row.valid_from is null or grant_row.valid_from<=v_shift.shift_date)
              and (grant_row.valid_to is null or grant_row.valid_to>=v_shift.shift_date))
          and not exists(select 1 from public.plan_assignment_duties_v2 transfer_duty
            where transfer_duty.assignment_id=transfer_assignment.id and not exists(
              select 1 from public.matrix_employee_duties_v2 candidate_grant
              where candidate_grant.matrix_version_id=v_run.matrix_version_id
                and candidate_grant.employee_id=candidate.employee_id and candidate_grant.duty_id=transfer_duty.duty_id
                and candidate_grant.active
                and (candidate_grant.role_id is null or candidate_grant.role_id=transfer_assignment.role_id)
                and (candidate_grant.location_id is null or candidate_grant.location_id=v_shift.location_id)))
        order by transfer_employee.last_name,transfer_employee.first_name,transfer_assignment.id limit 1
      ) transfer on true),'[]'::jsonb),
    'suggestionContract',jsonb_build_object('availabilityChecked',true,'dutyTransferChecked',true,'fullMonthCheckedOnSave',true)
  )
  from public.matrix_roles_v2 role
  join public.matrix_locations_v2 location on location.id=v_shift.location_id
  join public.matrix_shift_templates_v2 template on template.id=v_shift.shift_template_id
  left join public.matrix_duties_v2 duty on duty.id=v_duty_id
  where role.id=v_role_id;
end;
$$;

create or replace function public.optimizer_employee_availability_month_uat_v1(
  p_variant_id uuid,p_employee_ids uuid[]
) returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_run public.optimization_runs_v2%rowtype;v_default_available boolean:=true;
begin
  select run.* into v_run from public.plan_variants_v2 variant
    join public.optimization_runs_v2 run on run.id=variant.run_id where variant.id=p_variant_id;
  if v_run.id is null or not solver_private.can_access_run_v2(v_run.id) then raise exception 'VARIANT_NOT_FOUND'; end if;
  if coalesce(array_length(p_employee_ids,1),0)=0 or array_length(p_employee_ids,1)>2 then
    raise exception 'ONE_OR_TWO_EMPLOYEES_REQUIRED';end if;
  select coalesce((settings->>'missingAvailabilityMeansAvailable')::boolean,true)
    into v_default_available from public.matrix_versions where id=v_run.matrix_version_id;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'employeeId',employee.id,'date',day_value.day_date::date,'scheduled',exists(
      select 1 from public.plan_assignments_v2 assignment join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
      where assignment.variant_id=p_variant_id and assignment.employee_id=employee.id and shift.shift_date=day_value.day_date),
    'status',case
      when exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=employee.id and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
          and lower(constraint_row.time_range)::date<=day_value.day_date
          and (upper(constraint_row.time_range)-interval '1 microsecond')::date>=day_value.day_date) then 'HARD_UNAVAILABLE'
      when exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=employee.id and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind='PREFER_NOT_TO_WORK'
          and lower(constraint_row.time_range)::date<=day_value.day_date
          and (upper(constraint_row.time_range)-interval '1 microsecond')::date>=day_value.day_date) then 'SOFT_AVOID'
      when exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=employee.id and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind='AVAILABLE_WINDOW'
          and lower(constraint_row.time_range)::date<=day_value.day_date
          and (upper(constraint_row.time_range)-interval '1 microsecond')::date>=day_value.day_date) then 'AVAILABLE_WINDOW'
      when v_default_available then 'DEFAULT_AVAILABLE' else 'NO_AVAILABLE_WINDOW' end,
    'label',case
      when exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=employee.id and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
          and lower(constraint_row.time_range)::date<=day_value.day_date
          and (upper(constraint_row.time_range)-interval '1 microsecond')::date>=day_value.day_date) then 'Nie może pracować'
      when exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=employee.id and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind='PREFER_NOT_TO_WORK'
          and lower(constraint_row.time_range)::date<=day_value.day_date
          and (upper(constraint_row.time_range)-interval '1 microsecond')::date>=day_value.day_date) then 'Woli nie pracować'
      when exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=employee.id and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind='AVAILABLE_WINDOW'
          and lower(constraint_row.time_range)::date<=day_value.day_date
          and (upper(constraint_row.time_range)-interval '1 microsecond')::date>=day_value.day_date) then 'Dostępny w podanych godzinach'
      when v_default_available then 'Dostępny domyślnie' else 'Brak zgłoszonego okna' end
  ) order by employee.id,day_value.day_date) from public.employees employee
  cross join lateral generate_series(v_run.month,(v_run.month+interval '1 month'-interval '1 day')::date,interval '1 day') day_value(day_date)
  where employee.id=any(p_employee_ids)),'[]'::jsonb);
end;
$$;

create or replace function public.optimizer_leader_assignment_save_uat_v2(
  p_variant_id uuid,p_assignment_id uuid,p_issue_id bigint,p_employee_id uuid,p_reason text,
  p_allow_limit_override boolean default false,p_duty_transfer_assignment_id uuid default null
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid();v_assignment public.plan_assignments_v2%rowtype;
  v_issue public.plan_issues_v2%rowtype;v_shift public.plan_shifts_v2%rowtype;
  v_run public.optimization_runs_v2%rowtype;v_profile public.matrix_employee_profiles_v2%rowtype;
  v_transfer public.plan_assignments_v2%rowtype;v_duty_id uuid;v_snapshot jsonb;v_slot jsonb;
  v_assignment_id uuid;v_reason text:=trim(coalesce(p_reason,''));v_duration integer;
  v_monthly integer;v_weekly integer;v_limit_details jsonb:='[]'::jsonb;v_explanation jsonb;v_limit_message text;
  v_direct_duty boolean:=true;
begin
  if length(v_reason)<3 then raise exception 'EDIT_REASON_REQUIRED'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then raise exception 'LEADER_VARIANT_NOT_EDITABLE'; end if;
  if (p_assignment_id is null)=(p_issue_id is null) then raise exception 'ASSIGNMENT_OR_ISSUE_REQUIRED'; end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-edit:'||p_variant_id::text,0));
  select run.* into v_run from public.plan_variants_v2 variant
    join public.optimization_runs_v2 run on run.id=variant.run_id where variant.id=p_variant_id;
  select snapshot into v_snapshot from solver_private.optimization_snapshots_v2 where run_id=v_run.id;
  if p_assignment_id is not null then
    select * into v_assignment from public.plan_assignments_v2 where id=p_assignment_id and variant_id=p_variant_id for update;
    if v_assignment.id is null then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
    select * into v_shift from public.plan_shifts_v2 where id=v_assignment.shift_id;
    select duty_id into v_duty_id from public.plan_assignment_duties_v2 where assignment_id=v_assignment.id order by duty_id limit 1;
  else
    select * into v_issue from public.plan_issues_v2 where id=p_issue_id and variant_id=p_variant_id and issue_code='UNFILLED_SLOT' for update;
    if v_issue.id is null then raise exception 'UNFILLED_ISSUE_NOT_FOUND'; end if;
    select * into v_shift from public.plan_shifts_v2 where id=v_issue.shift_id;v_duty_id:=v_issue.duty_id;
  end if;
  select * into v_profile from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=v_run.matrix_version_id and profile.employee_id=p_employee_id
      and profile.active and profile.archived_at is null;
  if v_profile.id is null then raise exception 'VARIANT_EMPLOYEE_ELIGIBILITY_INVALID'; end if;
  if v_duty_id is not null then
    select exists(select 1 from public.matrix_employee_duties_v2 grant_row
      where grant_row.matrix_version_id=v_run.matrix_version_id and grant_row.employee_id=p_employee_id
        and grant_row.duty_id=v_duty_id and grant_row.active
        and (grant_row.role_id is null or grant_row.role_id=coalesce(v_assignment.role_id,v_issue.role_id))
        and (grant_row.location_id is null or grant_row.location_id=v_shift.location_id)) into v_direct_duty;
  end if;
  if not v_direct_duty then
    if p_duty_transfer_assignment_id is null then raise exception 'DUTY_TRANSFER_REQUIRED'; end if;
    select * into v_transfer from public.plan_assignments_v2
      where id=p_duty_transfer_assignment_id and variant_id=p_variant_id and shift_id=v_shift.id
        and id is distinct from p_assignment_id and role_id=coalesce(v_assignment.role_id,v_issue.role_id) for update;
    if v_transfer.id is null then raise exception 'DUTY_TRANSFER_ASSIGNMENT_INVALID'; end if;
    if not exists(select 1 from public.matrix_employee_duties_v2 grant_row
      where grant_row.matrix_version_id=v_run.matrix_version_id and grant_row.employee_id=v_transfer.employee_id
        and grant_row.duty_id=v_duty_id and grant_row.active
        and (grant_row.role_id is null or grant_row.role_id=v_transfer.role_id)
        and (grant_row.location_id is null or grant_row.location_id=v_shift.location_id)) then
      raise exception 'DUTY_TRANSFER_EMPLOYEE_INVALID';
    end if;
    if exists(select 1 from public.plan_assignment_duties_v2 transfer_duty
      where transfer_duty.assignment_id=v_transfer.id and not exists(select 1
        from public.matrix_employee_duties_v2 candidate_grant
        where candidate_grant.matrix_version_id=v_run.matrix_version_id
          and candidate_grant.employee_id=p_employee_id and candidate_grant.duty_id=transfer_duty.duty_id
          and candidate_grant.active and (candidate_grant.role_id is null or candidate_grant.role_id=v_transfer.role_id)
          and (candidate_grant.location_id is null or candidate_grant.location_id=v_shift.location_id))) then
      raise exception 'DUTY_TRANSFER_TARGET_SLOT_INVALID';
    end if;
  end if;
  v_duration:=extract(epoch from (v_shift.ends_at-v_shift.starts_at))/60;
  select coalesce(sum(extract(epoch from (shift.ends_at-shift.starts_at))/60),0)::integer,
    coalesce(sum(extract(epoch from (shift.ends_at-shift.starts_at))/60) filter(
      where shift.shift_date>=date_trunc('week',v_shift.shift_date)::date
        and shift.shift_date<date_trunc('week',v_shift.shift_date)::date+7),0)::integer
  into v_monthly,v_weekly from public.plan_assignments_v2 assignment
  join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
  where assignment.variant_id=p_variant_id and assignment.employee_id=p_employee_id
    and assignment.id is distinct from p_assignment_id and assignment.id is distinct from p_duty_transfer_assignment_id
    and shift.shift_date>=v_run.month and shift.shift_date<(v_run.month+interval '1 month')::date;
  if coalesce(v_profile.maximum_weekly_minutes,0)>0 and v_weekly+v_duration>v_profile.maximum_weekly_minutes then
    v_limit_details:=v_limit_details||jsonb_build_array(jsonb_build_object('code','WEEKLY_LIMIT','currentMinutes',v_weekly,
      'shiftMinutes',v_duration,'projectedMinutes',v_weekly+v_duration,'limitMinutes',v_profile.maximum_weekly_minutes));end if;
  if coalesce(v_profile.maximum_monthly_minutes,0)>0 and v_monthly+v_duration>v_profile.maximum_monthly_minutes then
    v_limit_details:=v_limit_details||jsonb_build_array(jsonb_build_object('code','MONTHLY_LIMIT','currentMinutes',v_monthly,
      'shiftMinutes',v_duration,'projectedMinutes',v_monthly+v_duration,'limitMinutes',v_profile.maximum_monthly_minutes));end if;
  if jsonb_array_length(v_limit_details)>0 and not p_allow_limit_override then
    select string_agg(format('%s: %s h + %s h = %s h przy limicie %s h.',
      case detail.value->>'code' when 'WEEKLY_LIMIT' then 'Tydzień' else 'Miesiąc' end,
      round((detail.value->>'currentMinutes')::numeric/60,1),round((detail.value->>'shiftMinutes')::numeric/60,1),
      round((detail.value->>'projectedMinutes')::numeric/60,1),round((detail.value->>'limitMinutes')::numeric/60,1)),' ')
      into v_limit_message from jsonb_array_elements(v_limit_details) detail(value);
    raise exception 'LEADER_LIMIT_OVERRIDE_REQUIRED:%',v_limit_message;
  end if;
  v_explanation:=jsonb_build_object('edited',true,'editedBy',v_actor,'editedAt',now(),'reason',v_reason,
    'limitOverride',jsonb_array_length(v_limit_details)>0 and p_allow_limit_override,
    'limitOverrideDetails',v_limit_details,'dutyTransferAssignmentId',p_duty_transfer_assignment_id);
  if p_assignment_id is not null then
    if v_direct_duty then
      update public.plan_assignments_v2 set employee_id=p_employee_id,
        explanation=(coalesce(explanation,'{}'::jsonb)-'limitOverride'-'limitOverrideDetails')||v_explanation
        where id=v_assignment.id returning id into v_assignment_id;
    else
      update public.plan_assignments_v2 set employee_id=v_transfer.employee_id,
        explanation=coalesce(explanation,'{}'::jsonb)||v_explanation||jsonb_build_object('dutyTransferredFrom',v_transfer.id)
        where id=v_assignment.id returning id into v_assignment_id;
      update public.plan_assignments_v2 set employee_id=p_employee_id,
        explanation=coalesce(explanation,'{}'::jsonb)||v_explanation||jsonb_build_object('dutyTransferredTo',v_assignment.id)
        where id=v_transfer.id;
    end if;
  else
    insert into public.plan_assignments_v2(variant_id,shift_id,slot_key,employee_id,role_id,locked,explanation)
    values(p_variant_id,v_issue.shift_id,v_issue.slot_key,case when v_direct_duty then p_employee_id else v_transfer.employee_id end,
      v_issue.role_id,false,v_explanation||jsonb_build_object('filledIssueId',v_issue.id)) returning id into v_assignment_id;
    select slot.value into v_slot from jsonb_array_elements(coalesce(v_snapshot->'slots','[]'::jsonb)) slot
      where slot.value->>'slotId'=v_issue.slot_key;
    insert into public.plan_assignment_duties_v2(assignment_id,duty_id)
      select v_assignment_id,(duty.value#>>'{}')::uuid from jsonb_array_elements(coalesce(v_slot->'dutyIds','[]'::jsonb)) duty;
    if not v_direct_duty then update public.plan_assignments_v2 set employee_id=p_employee_id,
      explanation=coalesce(explanation,'{}'::jsonb)||v_explanation||jsonb_build_object('dutyTransferredTo',v_assignment_id)
      where id=v_transfer.id;end if;
    delete from public.plan_issues_v2 where id=v_issue.id;
  end if;
  return solver_private.refresh_leader_variant_uat_v1(p_variant_id,v_actor,v_reason)
    ||jsonb_build_object('assignmentId',v_assignment_id,'limitOverride',jsonb_array_length(v_limit_details)>0 and p_allow_limit_override,
      'limitOverrideDetails',v_limit_details,'dutyTransferAssignmentId',p_duty_transfer_assignment_id);
end;
$$;

revoke all on function public.optimizer_leader_assignment_context_uat_v2(uuid,uuid,bigint),
  public.optimizer_leader_assignment_save_uat_v2(uuid,uuid,bigint,uuid,text,boolean,uuid),
  public.optimizer_employee_availability_month_uat_v1(uuid,uuid[]) from public,anon,authenticated;
grant execute on function public.optimizer_leader_assignment_context_uat_v2(uuid,uuid,bigint),
  public.optimizer_leader_assignment_save_uat_v2(uuid,uuid,bigint,uuid,text,boolean,uuid),
  public.optimizer_employee_availability_month_uat_v1(uuid,uuid[]) to authenticated;
comment on function public.optimizer_leader_assignment_save_uat_v2(uuid,uuid,bigint,uuid,text,boolean,uuid) is
  'Atomic leader assignment with full variant validation, explicit limit override and optional same-shift duty hand-off.';
notify pgrst,'reload schema';
