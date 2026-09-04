-- Keep the operational workspace RPC shape stable before the first monthly
-- publication.  The frontend must receive a canonical EMPTY ORTOOLS workspace,
-- not a null placeholder that is indistinguishable from a broken RPC contract.

create or replace function public.optimizer_operational_workspace_alpha16(
  p_month date
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_month date:=date_trunc('month',p_month)::date;
  v_schedule uuid;
  v_workspace jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;

  select schedule.id into v_schedule
  from public.published_schedules_v2 schedule
  where schedule.month=v_month and schedule.status='PUBLISHED'
  order by schedule.published_at desc limit 1;

  if v_schedule is null then
    v_workspace:=public.optimizer_active_workspace_v2(v_month);
    return jsonb_build_object(
      'scheduleId',null,
      'workspace',v_workspace,
      'overrides','[]'::jsonb
    );
  end if;

  if not solver_private.alpha16_can_manage_schedule_v2(v_schedule) then
    raise exception 'FORBIDDEN';
  end if;

  v_workspace:=public.optimizer_published_schedule_alpha16(v_schedule);
  return jsonb_build_object(
    'scheduleId',v_schedule,'workspace',v_workspace,
    'overrides',coalesce((select jsonb_agg(jsonb_build_object(
      'id',override_row.id,'issueId',override_row.issue_id,
      'variantId',issue.variant_id,
      'slotKey',override_row.slot_key,'shiftId',override_row.shift_id,
      'slotGroupKey',shift_row.slot_group_key,
      'classification',override_row.assignment_class,
      'reason',override_row.override_reason,
      'createdAt',override_row.created_at,
      'employee',jsonb_build_object(
        'id',profile.employee_id,'employeeNo',profile.employee_no,
        'firstName',profile.first_name,'lastName',profile.last_name,
        'nominalMonthlyMinutes',profile.nominal_monthly_minutes
      ),
      'role',jsonb_build_object('id',role.id,'name',role.name),
      'duties',case when issue.duty_id is null then '[]'::jsonb else
        jsonb_build_array(jsonb_build_object('id',duty.id,'name',duty.name)) end
    ) order by override_row.created_at,override_row.id)
      from public.operational_assignment_overrides_v2 override_row
      join public.plan_shifts_v2 shift_row on shift_row.id=override_row.shift_id
      join public.matrix_employee_profiles_v2 profile
        on profile.matrix_version_id=(select schedule.matrix_version_id
          from public.published_schedules_v2 schedule where schedule.id=v_schedule)
        and profile.employee_id=override_row.employee_id
      join public.matrix_roles_v2 role on role.id=override_row.role_id
      join public.plan_issues_v2 issue on issue.id=override_row.issue_id
      left join public.matrix_duties_v2 duty on duty.id=issue.duty_id
      where override_row.schedule_id=v_schedule and override_row.status='ACTIVE'
    ),'[]'::jsonb)
  );
end;
$$;

comment on function public.optimizer_operational_workspace_alpha16(date) is
  'Returns a stable operational workspace envelope; before the first monthly publication workspace is the canonical EMPTY ORTOOLS contract.';
