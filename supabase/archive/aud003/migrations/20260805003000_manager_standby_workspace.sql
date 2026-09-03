-- Consolidated manager/leader read model for published daily stand-by tiers.
create or replace function public.manager_standby_month_uat_v2(
  p_month date,
  p_scope_role_id uuid default null
) returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',standby.id,
      'date',standby.standby_date,
      'tier',standby.tier,
      'status',standby.status,
      'roleId',standby.role_id,
      'roleName',role.name,
      'employeeId',standby.employee_id,
      'employeeNo',employee.employee_no,
      'employeeName',concat_ws(' ',employee.first_name,employee.last_name),
      'sourceType',case when standby.source_role_schedule_id is null then 'COMPANY' else 'ROLE' end,
      'activatedShiftId',standby.activated_shift_id
    ) order by standby.standby_date,role.name,standby.tier)
    from public.published_standby_assignments_v2 standby
    join public.matrix_roles_v2 role on role.id=standby.role_id
    join public.employees employee on employee.id=standby.employee_id
    where standby.month=date_trunc('month',p_month)::date
      and (p_scope_role_id is null or standby.role_id=p_scope_role_id)
      and standby.status in ('PLANNED','ACTIVATED','DECLINED')
  ),'[]'::jsonb);
end;
$$;

revoke all on function public.manager_standby_month_uat_v2(date,uuid)
  from public,anon,authenticated;
grant execute on function public.manager_standby_month_uat_v2(date,uuid)
  to authenticated;
