-- Align MASTER availability writes with the exact HOT DAY review schema.

create or replace function public.uat_master_employee_availability_days_save_v2(
  p_employee_id uuid,p_dates date[],p_kind text,p_all_day boolean default true,
  p_local_start time default null,p_local_end time default null,
  p_preferred_location_id uuid default null,p_note text default null
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_day date; v_kind text:=upper(trim(coalesce(p_kind,'')));
  v_saved integer:=0; v_role uuid; v_hot_limit integer; v_existing_hard integer;
  v_pending integer:=0; v_event uuid; v_matrix uuid; v_timezone text;
  v_day_start timestamptz; v_day_end timestamptz;
begin
  perform solver_private.assert_uat_master_persona_v2();
  if not exists(select 1 from public.employees employee where employee.id=p_employee_id
    and employee.active and employee.archived_at is null) then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  if v_kind not in ('AVAILABLE','PREFER_NOT_TO_WORK','CANNOT_WORK')
    or coalesce(cardinality(p_dates),0)=0 or cardinality(p_dates)>62 then
    raise exception 'INVALID_AVAILABILITY_REQUEST';
  end if;
  select matrix.id,matrix.settings->>'timezone' into v_matrix,v_timezone
  from public.matrix_versions matrix where matrix.status='ACTIVE' and matrix.schema_version>=2
  order by matrix.effective_from desc,matrix.version desc limit 1;
  if v_matrix is null or v_timezone is null then raise exception 'MATRIX_V2_NOT_FOUND'; end if;
  foreach v_day in array p_dates loop
    if v_day is null then raise exception 'INVALID_DATE_RANGE'; end if;
    v_day_start:=v_day::timestamp at time zone v_timezone;
    v_day_end:=(v_day+1)::timestamp at time zone v_timezone;
    select grant_row.role_id into v_role from public.matrix_employee_roles_v2 grant_row
    where grant_row.matrix_version_id=v_matrix and grant_row.employee_id=p_employee_id
      and grant_row.active order by grant_row.is_primary desc,grant_row.id limit 1;
    if v_kind='CANNOT_WORK' then
      select event.id,limit_row.maximum_hard_unavailable into v_event,v_hot_limit
      from public.workforce_calendar_events_v2 event
      join public.workforce_hot_day_limits_v2 limit_row on limit_row.event_id=event.id
      where event.status='ACTIVE' and event.event_kind='HOT_DAY'
        and event.event_date=v_day and event.matrix_version_id=v_matrix
        and limit_row.role_id=v_role limit 1;
      if v_hot_limit is not null then
        select count(distinct constraint_row.employee_id) into v_existing_hard
        from public.employee_time_constraints_v2 constraint_row
        where constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
          and constraint_row.employee_id<>p_employee_id
          and constraint_row.time_range && tstzrange(v_day_start,v_day_end,'[)');
        if v_existing_hard>=v_hot_limit then
          insert into public.availability_exception_reviews_v2(
            employee_id,matrix_version_id,hot_day_event_id,role_id,work_date,
            requested_range,note,status,requested_by
          ) values(
            p_employee_id,v_matrix,v_event,v_role,v_day,tstzrange(v_day_start,v_day_end,'[)'),
            nullif(trim(p_note),''),'PENDING',v_actor
          ) on conflict(employee_id,work_date,role_id) where status='PENDING'
          do update set note=excluded.note,requested_range=excluded.requested_range,
            requested_at=now(),requested_by=v_actor;
          v_pending:=v_pending+1;
          continue;
        end if;
      end if;
    else
      update public.availability_exception_reviews_v2 set status='CANCELLED',
        reviewed_at=now(),reviewed_by=v_actor,review_reason='Anulowano w trybie MASTER UAT.'
      where employee_id=p_employee_id and work_date=v_day and status='PENDING';
    end if;
    perform solver_private.uat_master_save_employee_day_v2(v_actor,p_employee_id,v_day,v_kind,
      p_all_day,p_local_start,p_local_end,p_preferred_location_id,p_note);
    v_saved:=v_saved+1;
  end loop;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'employee_availability_v2',p_employee_id::text,'UAT_MASTER_SET_DAYS',
    jsonb_build_object('dates',p_dates,'kind',v_kind,'savedDays',v_saved,
      'pendingReviewDays',v_pending,'actingAsEmployeeId',p_employee_id));
  return jsonb_build_object('employeeId',p_employee_id,'savedDays',v_saved,
    'pendingReviewDays',v_pending,'kind',v_kind);
end;
$$;

revoke all on function public.uat_master_employee_availability_days_save_v2(
  uuid,date[],text,boolean,time,time,uuid,text
) from public,anon,authenticated;
grant execute on function public.uat_master_employee_availability_days_save_v2(
  uuid,date[],text,boolean,time,time,uuid,text
) to authenticated;

notify pgrst,'reload schema';
