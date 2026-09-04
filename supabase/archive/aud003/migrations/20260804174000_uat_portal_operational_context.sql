-- UI contracts for the operational calendar and swap board.

create or replace function public.workforce_calendar_context_uat_v2(p_month date)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare
  v_month date:=date_trunc('month',p_month)::date;
  v_matrix uuid;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select matrix.id into v_matrix from public.matrix_versions matrix
  where matrix.status='ACTIVE' and matrix.schema_version>=2
    and matrix.effective_from<=v_month
    and (matrix.effective_to is null
      or matrix.effective_to>=(v_month+interval '1 month - 1 day')::date)
  order by matrix.effective_from desc,matrix.version desc limit 1;
  select jsonb_build_object(
    'month',v_month,'matrixVersionId',v_matrix,
    'canManage',public.can_manage_plans(),
    'roles',coalesce((select jsonb_agg(jsonb_build_object(
      'id',role.id,'name',role.name,'code',role.code
    ) order by role.sort_order,role.name) from public.matrix_roles_v2 role
      where role.matrix_version_id=v_matrix and role.active),'[]'::jsonb),
    'locations',coalesce((select jsonb_agg(jsonb_build_object(
      'id',location.id,'name',location.name,'code',location.code
    ) order by location.sort_order,location.name)
      from public.matrix_locations_v2 location
      where location.matrix_version_id=v_matrix and location.active),'[]'::jsonb),
    'shiftTemplates',coalesce((select jsonb_agg(jsonb_build_object(
      'id',shift.id,'name',shift.name,'code',shift.code,
      'locationId',shift.location_id,'startsAt',shift.starts_at,
      'endsAt',shift.ends_at,'endsNextDay',shift.ends_next_day,
      'dayMask',to_jsonb(shift.day_mask)
    ) order by location.sort_order,shift.sort_order,shift.name)
      from public.matrix_shift_templates_v2 shift
      join public.matrix_locations_v2 location on location.id=shift.location_id
      where shift.matrix_version_id=v_matrix and shift.active and location.active),'[]'::jsonb),
    'events',coalesce((select jsonb_agg(jsonb_build_object(
      'id',event.id,'date',event.event_date,'kind',event.event_kind,
      'title',event.title,'description',event.description,
      'locationId',event.location_id,'locationName',location.name,
      'demands',coalesce((select jsonb_agg(jsonb_build_object(
        'id',demand.id,'shiftTemplateId',demand.shift_template_id,
        'shiftName',shift.name,'roleId',demand.role_id,'roleName',role.name,
        'dutyId',demand.duty_id,'additionalCount',demand.additional_count
      ) order by shift.sort_order,role.sort_order) from public.workforce_event_demand_v2 demand
        join public.matrix_shift_templates_v2 shift on shift.id=demand.shift_template_id
        join public.matrix_roles_v2 role on role.id=demand.role_id
        where demand.event_id=event.id),'[]'::jsonb),
      'hotLimits',coalesce((select jsonb_agg(jsonb_build_object(
        'roleId',hot.role_id,'roleName',role.name,
        'maximumHardUnavailable',hot.maximum_hard_unavailable
      ) order by role.sort_order) from public.workforce_hot_day_limits_v2 hot
        join public.matrix_roles_v2 role on role.id=hot.role_id
        where hot.event_id=event.id),'[]'::jsonb)
    ) order by event.event_date,event.title)
      from public.workforce_calendar_events_v2 event
      left join public.matrix_locations_v2 location on location.id=event.location_id
      where event.month=v_month and event.status='ACTIVE'),'[]'::jsonb),
    'pendingReviews',coalesce((select jsonb_agg(jsonb_build_object(
      'id',review.id,'employeeId',review.employee_id,
      'employeeName',profile.first_name||' '||profile.last_name,
      'employeeNo',profile.employee_no,'date',review.work_date,
      'roleId',review.role_id,'roleName',role.name,'status',review.status,
      'note',review.note,'requestedAt',review.requested_at
    ) order by review.work_date,profile.last_name,profile.first_name)
      from public.availability_exception_reviews_v2 review
      join public.matrix_employee_profiles_v2 profile
        on profile.matrix_version_id=review.matrix_version_id
        and profile.employee_id=review.employee_id
      join public.matrix_roles_v2 role on role.id=review.role_id
      where review.work_date>=v_month
        and review.work_date<(v_month+interval '1 month')::date
        and (review.requested_by=auth.uid() or public.can_manage_plans())
        and review.status='PENDING'),'[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

create or replace function public.shift_swap_board_uat_v2(p_month date)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_employee uuid; v_month date:=date_trunc('month',p_month)::date;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select employee.id into v_employee from public.employees employee
  where employee.auth_user_id=v_actor and employee.active and employee.archived_at is null
  order by employee.employee_no limit 1;
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
      'acceptedByEmployeeId',request.accepted_by_employee_id,
      'eligible',case when v_employee is null then false else cardinality(
        solver_private.swap_candidate_reasons_uat_v2(request.id,v_employee))=0 end,
      'ineligibilityReasons',case when v_employee is null then '[]'::jsonb
        else to_jsonb(solver_private.swap_candidate_reasons_uat_v2(request.id,v_employee)) end,
      'isMine',request.proposer_employee_id=v_employee,
      'requiresLeaderDecision',request.status='EMPLOYEE_ACCEPTED'
    ) order by shift.starts_at,request.created_at)
      from public.shift_swap_requests_v2 request
      join public.plan_assignments_v2 assignment on assignment.id=request.original_assignment_id
      join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
      join public.matrix_locations_v2 location on location.id=shift.location_id
      join public.matrix_shift_templates_v2 template on template.id=shift.shift_template_id
      join public.matrix_roles_v2 role on role.id=request.role_id
      join public.matrix_employee_profiles_v2 proposer
        on proposer.matrix_version_id=request.matrix_version_id
        and proposer.employee_id=request.proposer_employee_id
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

notify pgrst,'reload schema';
