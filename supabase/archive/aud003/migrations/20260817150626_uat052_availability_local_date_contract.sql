-- B4F-79: render availability days in the Matrix timezone. PostgreSQL sessions
-- stay in UTC; casting timestamptz directly to date shifted Europe/Warsaw
-- all-day ranges to the previous calendar day.
create or replace function public.optimizer_employee_availability_month_uat_v1(
  p_variant_id uuid,p_employee_ids uuid[]
) returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_run public.optimization_runs_v2%rowtype;v_default_available boolean:=true;
  v_timezone text;
begin
  select run.* into v_run from public.plan_variants_v2 variant
    join public.optimization_runs_v2 run on run.id=variant.run_id where variant.id=p_variant_id;
  if v_run.id is null or not solver_private.can_access_run_v2(v_run.id) then raise exception 'VARIANT_NOT_FOUND'; end if;
  if coalesce(array_length(p_employee_ids,1),0)=0 or array_length(p_employee_ids,1)>2 then
    raise exception 'ONE_OR_TWO_EMPLOYEES_REQUIRED';end if;
  select coalesce((settings->>'missingAvailabilityMeansAvailable')::boolean,true),
    coalesce(nullif(settings->>'timezone',''),'UTC')
    into v_default_available,v_timezone from public.matrix_versions where id=v_run.matrix_version_id;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'employeeId',employee.id,'date',day_value.day_date::date,'scheduled',exists(
      select 1 from public.plan_assignments_v2 assignment join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
      where assignment.variant_id=p_variant_id and assignment.employee_id=employee.id and shift.shift_date=day_value.day_date),
    'status',case
      when exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=employee.id and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
          and (lower(constraint_row.time_range) at time zone v_timezone)::date<=day_value.day_date
          and ((upper(constraint_row.time_range)-interval '1 microsecond') at time zone v_timezone)::date>=day_value.day_date) then 'HARD_UNAVAILABLE'
      when exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=employee.id and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind='PREFER_NOT_TO_WORK'
          and (lower(constraint_row.time_range) at time zone v_timezone)::date<=day_value.day_date
          and ((upper(constraint_row.time_range)-interval '1 microsecond') at time zone v_timezone)::date>=day_value.day_date) then 'SOFT_AVOID'
      when exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=employee.id and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind='AVAILABLE_WINDOW'
          and (lower(constraint_row.time_range) at time zone v_timezone)::date<=day_value.day_date
          and ((upper(constraint_row.time_range)-interval '1 microsecond') at time zone v_timezone)::date>=day_value.day_date) then 'AVAILABLE_WINDOW'
      when v_default_available then 'DEFAULT_AVAILABLE' else 'NO_AVAILABLE_WINDOW' end,
    'label',case
      when exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=employee.id and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
          and (lower(constraint_row.time_range) at time zone v_timezone)::date<=day_value.day_date
          and ((upper(constraint_row.time_range)-interval '1 microsecond') at time zone v_timezone)::date>=day_value.day_date) then 'Nie może pracować'
      when exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=employee.id and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind='PREFER_NOT_TO_WORK'
          and (lower(constraint_row.time_range) at time zone v_timezone)::date<=day_value.day_date
          and ((upper(constraint_row.time_range)-interval '1 microsecond') at time zone v_timezone)::date>=day_value.day_date) then 'Woli nie pracować'
      when exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=employee.id and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind='AVAILABLE_WINDOW'
          and (lower(constraint_row.time_range) at time zone v_timezone)::date<=day_value.day_date
          and ((upper(constraint_row.time_range)-interval '1 microsecond') at time zone v_timezone)::date>=day_value.day_date) then 'Dostępny w podanych godzinach'
      when v_default_available then 'Dostępny domyślnie' else 'Brak zgłoszonego okna' end
  ) order by employee.id,day_value.day_date) from public.employees employee
  cross join lateral generate_series(v_run.month,(v_run.month+interval '1 month'-interval '1 day')::date,interval '1 day') day_value(day_date)
  where employee.id=any(p_employee_ids)),'[]'::jsonb);
end;
$$;

revoke all on function public.optimizer_employee_availability_month_uat_v1(uuid,uuid[])
  from public,anon,authenticated;
grant execute on function public.optimizer_employee_availability_month_uat_v1(uuid,uuid[])
  to authenticated;

notify pgrst,'reload schema';
