-- Isolated-UAT-only MASTER persona tools. They ship disabled and require both
-- an OWNER session and a service-role switch in uat_environment_controls.

insert into public.uat_environment_controls(control_key,enabled,config)
values('ISOLATED_UAT_MASTER_PERSONA',false,'{}'::jsonb)
on conflict(control_key) do nothing;

create or replace function solver_private.assert_uat_master_persona_v2()
returns void language plpgsql stable security definer set search_path=''
as $$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.has_app_role('OWNER') then raise exception 'FORBIDDEN'; end if;
  if not exists(select 1 from public.uat_environment_controls control
    where control.control_key='ISOLATED_UAT_MASTER_PERSONA' and control.enabled)
  then raise exception 'UAT_MASTER_DISABLED'; end if;
end;
$$;

create or replace function public.uat_master_persona_preview_v2()
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_enabled boolean:=false; v_matrix uuid; v_version integer;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.has_app_role('OWNER') then raise exception 'FORBIDDEN'; end if;
  select control.enabled into v_enabled from public.uat_environment_controls control
    where control.control_key='ISOLATED_UAT_MASTER_PERSONA';
  select matrix.id,matrix.version into v_matrix,v_version
  from public.matrix_versions matrix where matrix.status='ACTIVE'
    and matrix.schema_version>=2 order by matrix.effective_from desc,matrix.version desc limit 1;
  return jsonb_build_object(
    'enabled',coalesce(v_enabled,false),'matrixVersionId',v_matrix,'matrixVersion',v_version,
    'personas',jsonb_build_array('EMPLOYEE','ROLE_MANAGER','HR','FINANCE','OWNER'),
    'employees',coalesce((select jsonb_agg(jsonb_build_object(
      'id',profile.employee_id,'employeeNo',profile.employee_no,
      'name',profile.first_name||' '||profile.last_name,
      'roleId',role.id,'roleName',role.name,'roleCode',role.code
    ) order by profile.last_name,profile.first_name,profile.employee_no)
      from public.matrix_employee_profiles_v2 profile
      left join public.matrix_employee_roles_v2 grant_row
        on grant_row.matrix_version_id=v_matrix and grant_row.employee_id=profile.employee_id
        and grant_row.active and grant_row.is_primary
      left join public.matrix_roles_v2 role on role.id=grant_row.role_id
      where profile.matrix_version_id=v_matrix and profile.active
        and profile.archived_at is null),'[]'::jsonb)
  );
end;
$$;

create or replace function public.uat_master_persona_select_v2(
  p_persona text,p_employee_id uuid default null
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_persona text:=upper(trim(coalesce(p_persona,''))); v_employee_name text;
begin
  perform solver_private.assert_uat_master_persona_v2();
  if v_persona not in ('EMPLOYEE','ROLE_MANAGER','HR','FINANCE','OWNER') then
    raise exception 'INVALID_UAT_PERSONA';
  end if;
  if v_persona in ('EMPLOYEE','ROLE_MANAGER') then
    select employee.first_name||' '||employee.last_name into v_employee_name
    from public.employees employee where employee.id=p_employee_id and employee.active
      and employee.archived_at is null;
    if v_employee_name is null then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  end if;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'uat_master_persona',coalesce(p_employee_id::text,v_persona),'SELECT',
    jsonb_build_object('persona',v_persona,'employeeId',p_employee_id,
      'employeeName',v_employee_name,'securityMode','OWNER_AUDITED_UAT_SIMULATION'));
  return jsonb_build_object('persona',v_persona,'employeeId',p_employee_id,
    'employeeName',v_employee_name);
end;
$$;

create or replace function solver_private.uat_master_employee_constraints_v2(
  p_employee_id uuid,p_month date,p_matrix uuid,p_timezone text
) returns jsonb language sql stable security definer set search_path=''
as $$
  with bounds as (
    select p_month::timestamp at time zone p_timezone period_start,
      (p_month+interval '1 month')::timestamp at time zone p_timezone period_end
  ), entries as (
    select constraint_row.id,constraint_row.constraint_kind kind,
      lower(constraint_row.time_range) starts_at,upper(constraint_row.time_range) ends_at,
      constraint_row.source,constraint_row.source='GRAFIK_PRO'
        and constraint_row.editable_by_employee editable,constraint_row.note,
      (select location.id from public.matrix_locations_v2 location
       where location.matrix_version_id=p_matrix
         and location.logical_id=constraint_row.location_logical_id
       order by location.active desc,location.sort_order limit 1) preferred_location_id
    from public.employee_time_constraints_v2 constraint_row,bounds
    where constraint_row.employee_id=p_employee_id and constraint_row.status='ACTIVE'
      and constraint_row.time_range && tstzrange(bounds.period_start,bounds.period_end,'[)')
    union all
    select preference.id,
      case when preference.preference_type='OTHER' then 'PREFER_NOT_TO_WORK'
        else 'PREFERRED_LOCATION' end,
      preference.valid_from::timestamp at time zone p_timezone,
      (preference.valid_to+1)::timestamp at time zone p_timezone,
      preference.source,preference.source='GRAFIK_PRO' and preference.editable_by_employee,
      nullif(preference.preference_value->>'note',''),
      case when preference.preference_type='PREFERRED_LOCATION'
        and preference.preference_value->>'locationId'
          ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
        then (preference.preference_value->>'locationId')::uuid else null end
    from public.employee_preferences preference
    where preference.employee_id=p_employee_id and preference.status='ACTIVE'
      and preference.valid_from<p_month+interval '1 month' and preference.valid_to>=p_month
      and (preference.preference_type='PREFERRED_LOCATION' or
        (preference.preference_type='OTHER'
         and preference.preference_value->>'kind'='DAY_OFF'
         and preference.preference_value->>'strength'='SOFT'))
  )
  select jsonb_build_object('employeeId',p_employee_id,'timezone',p_timezone,
    'defaultAvailable',true,'constraints',coalesce(jsonb_agg(jsonb_strip_nulls(
      jsonb_build_object('id',entry.id,'kind',entry.kind,'startsAt',entry.starts_at,
        'endsAt',entry.ends_at,'source',entry.source,'editable',entry.editable,
        'note',entry.note,'preferredLocationId',entry.preferred_location_id))
      order by entry.starts_at,entry.ends_at,entry.id),'[]'::jsonb)) from entries entry
$$;

create or replace function public.uat_master_employee_portal_context_v2(
  p_employee_id uuid,p_month date
) returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_month date:=date_trunc('month',p_month)::date; v_matrix uuid; v_timezone text;
  v_profile public.matrix_employee_profiles_v2%rowtype; v_calendar jsonb; v_preferences jsonb;
begin
  perform solver_private.assert_uat_master_persona_v2();
  select matrix.id,matrix.settings->>'timezone' into v_matrix,v_timezone
  from public.matrix_versions matrix where matrix.status in ('ACTIVE','ARCHIVED')
    and matrix.schema_version>=2 and matrix.effective_from<=v_month
  order by matrix.effective_from desc,matrix.version desc limit 1;
  select * into v_profile from public.matrix_employee_profiles_v2 profile
  where profile.matrix_version_id=v_matrix and profile.employee_id=p_employee_id
    and profile.active and profile.archived_at is null;
  if v_profile.id is null then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  v_calendar:=public.published_company_calendar_uat_v2(v_month);
  v_preferences:=jsonb_build_object(
    'employeeId',p_employee_id,'month',v_month,
    'employee',jsonb_build_object(
      'MORNING',coalesce((select upper(preference.preference_value->>'level')
        from public.employee_preferences preference where preference.employee_id=p_employee_id
          and preference.status='ACTIVE' and preference.source='GRAFIK_PRO'
          and preference.preference_type='PREFERRED_SHIFT'
          and upper(preference.preference_value->>'period')='MORNING'
          and preference.valid_from<v_month+interval '1 month' and preference.valid_to>=v_month
        order by preference.created_at desc limit 1),'NEUTRAL'),
      'MIDDLE',coalesce((select upper(preference.preference_value->>'level')
        from public.employee_preferences preference where preference.employee_id=p_employee_id
          and preference.status='ACTIVE' and preference.source='GRAFIK_PRO'
          and preference.preference_type='PREFERRED_SHIFT'
          and upper(preference.preference_value->>'period')='MIDDLE'
          and preference.valid_from<v_month+interval '1 month' and preference.valid_to>=v_month
        order by preference.created_at desc limit 1),'NEUTRAL'),
      'EVENING',coalesce((select upper(preference.preference_value->>'level')
        from public.employee_preferences preference where preference.employee_id=p_employee_id
          and preference.status='ACTIVE' and preference.source='GRAFIK_PRO'
          and preference.preference_type='PREFERRED_SHIFT'
          and upper(preference.preference_value->>'period')='EVENING'
          and preference.valid_from<v_month+interval '1 month' and preference.valid_to>=v_month
        order by preference.created_at desc limit 1),'NEUTRAL')),
    'effective',coalesce(solver_private.alpha16_shift_rules_v2(p_employee_id,v_matrix,v_month)->'periods','{}'::jsonb),
    'managerOverrides','{}'::jsonb);
  return jsonb_build_object(
    'employee',jsonb_build_object('id',p_employee_id,'employeeNo',v_profile.employee_no,
      'firstName',v_profile.first_name,'lastName',v_profile.last_name,
      'primaryRole',coalesce((select role.name from public.matrix_employee_roles_v2 grant_row
        join public.matrix_roles_v2 role on role.id=grant_row.role_id
        where grant_row.matrix_version_id=v_matrix and grant_row.employee_id=p_employee_id
          and grant_row.active order by grant_row.is_primary desc,role.sort_order limit 1),'—'),
      'locations',coalesce((select jsonb_agg(jsonb_build_object('code',location.code,'name',location.name)
        order by location.sort_order) from public.matrix_employee_locations_v2 grant_row
        join public.matrix_locations_v2 location on location.id=grant_row.location_id
        where grant_row.matrix_version_id=v_matrix and grant_row.employee_id=p_employee_id
          and grant_row.active and (grant_row.standard_allowed or grant_row.overtime_allowed)),'[]'::jsonb)),
    'assignments',coalesce((select jsonb_agg(item.value order by item.value->>'startsAt')
      from jsonb_array_elements(coalesce(v_calendar->'assignments','[]'::jsonb)) item
      where item.value->>'employeeId'=p_employee_id::text),'[]'::jsonb),
    'standby',coalesce((select jsonb_agg(jsonb_build_object('id',standby.id,
      'date',standby.standby_date,'tier',standby.tier,'status',standby.status,
      'roleId',standby.role_id,'roleName',role.name,'activatedShiftId',standby.activated_shift_id)
      order by standby.standby_date,standby.tier)
      from public.published_standby_assignments_v2 standby
      join public.matrix_roles_v2 role on role.id=standby.role_id
      where standby.employee_id=p_employee_id and standby.month=v_month
        and standby.status in ('PLANNED','ACTIVATED','DECLINED')),'[]'::jsonb),
    'attendance','[]'::jsonb,
    'timeConstraints',solver_private.uat_master_employee_constraints_v2(
      p_employee_id,v_month,v_matrix,v_timezone),
    'shiftPreferences',v_preferences,
    'companyCalendar',v_calendar,
    'masterPersona',true
  );
end;
$$;

create or replace function solver_private.uat_master_save_employee_day_v2(
  p_actor uuid,p_employee_id uuid,p_day date,p_kind text,p_all_day boolean,
  p_local_start time,p_local_end time,p_preferred_location_id uuid,p_note text
) returns void language plpgsql security definer set search_path=''
as $$
declare v_timezone text; v_start timestamptz; v_end timestamptz;
  v_location_logical_id uuid; v_preference public.employee_preferences%rowtype;
  v_constraint public.employee_time_constraints_v2%rowtype;
begin
  select matrix.settings->>'timezone' into v_timezone from public.matrix_versions matrix
  where matrix.status='ACTIVE' and matrix.schema_version>=2
  order by matrix.effective_from desc,matrix.version desc limit 1;
  if v_timezone is null then raise exception 'MATRIX_TIMEZONE_REQUIRED'; end if;
  v_start:=p_day::timestamp at time zone v_timezone;
  v_end:=(p_day+1)::timestamp at time zone v_timezone;
  if not p_all_day then
    if p_local_start is null or p_local_end is null or p_local_end=p_local_start then
      raise exception 'HOURS_REQUIRED';
    end if;
    v_start:=(p_day+p_local_start)::timestamp at time zone v_timezone;
    v_end:=case when p_local_end>p_local_start
      then (p_day+p_local_end)::timestamp at time zone v_timezone
      else (p_day+1+p_local_end)::timestamp at time zone v_timezone end;
  end if;
  if p_preferred_location_id is not null then
    select location.logical_id into v_location_logical_id
    from public.matrix_locations_v2 location join public.matrix_versions matrix
      on matrix.id=location.matrix_version_id
    where location.id=p_preferred_location_id and location.active and matrix.status='ACTIVE';
    if v_location_logical_id is null then raise exception 'PREFERRED_LOCATION_NOT_FOUND'; end if;
  end if;
  for v_preference in select preference.* from public.employee_preferences preference
    where preference.employee_id=p_employee_id and preference.status='ACTIVE'
      and preference.source='GRAFIK_PRO' and preference.editable_by_employee
      and preference.preference_type in ('OTHER','PREFERRED_LOCATION')
      and preference.valid_from<=p_day and preference.valid_to>=p_day for update
  loop
    update public.employee_preferences set status='CANCELLED' where id=v_preference.id;
    if v_preference.valid_from<p_day then
      insert into public.employee_preferences(employee_id,valid_from,valid_to,preference_type,
        preference_value,source,editable_by_employee,status)
      values(p_employee_id,v_preference.valid_from,p_day-1,v_preference.preference_type,
        v_preference.preference_value,'GRAFIK_PRO',true,'ACTIVE');
    end if;
    if v_preference.valid_to>p_day then
      insert into public.employee_preferences(employee_id,valid_from,valid_to,preference_type,
        preference_value,source,editable_by_employee,status)
      values(p_employee_id,p_day+1,v_preference.valid_to,v_preference.preference_type,
        v_preference.preference_value,'GRAFIK_PRO',true,'ACTIVE');
    end if;
  end loop;
  for v_constraint in select constraint_row.* from public.employee_time_constraints_v2 constraint_row
    where constraint_row.employee_id=p_employee_id and constraint_row.status='ACTIVE'
      and constraint_row.source='GRAFIK_PRO' and constraint_row.editable_by_employee
      and constraint_row.time_range && tstzrange(
        p_day::timestamp at time zone v_timezone,(p_day+1)::timestamp at time zone v_timezone,'[)')
    for update
  loop
    update public.employee_time_constraints_v2 set status='REVOKED',revoked_at=now(),updated_at=now()
    where id=v_constraint.id;
  end loop;
  if upper(p_kind)='PREFER_NOT_TO_WORK' then
    insert into public.employee_preferences(employee_id,valid_from,valid_to,preference_type,
      preference_value,source,editable_by_employee,status)
    values(p_employee_id,p_day,p_day,'OTHER',jsonb_strip_nulls(jsonb_build_object(
      'kind','DAY_OFF','strength','SOFT','note',nullif(trim(p_note),''))),
      'GRAFIK_PRO',true,'ACTIVE');
  elsif upper(p_kind)='CANNOT_WORK' or not p_all_day then
    insert into public.employee_time_constraints_v2(employee_id,constraint_kind,time_range,
      location_logical_id,source,source_record_key,priority,editable_by_employee,status,note,created_by)
    values(p_employee_id,case when upper(p_kind)='AVAILABLE' then 'AVAILABLE_WINDOW' else 'UNAVAILABLE' end,
      tstzrange(v_start,v_end,'[)'),v_location_logical_id,'GRAFIK_PRO',
      'uat-master-day:'||p_employee_id||':'||p_day||':'||upper(p_kind),100,true,'ACTIVE',
      nullif(trim(p_note),''),p_actor)
    on conflict(source,source_record_key) where source_record_key is not null do update
      set constraint_kind=excluded.constraint_kind,time_range=excluded.time_range,
        location_logical_id=excluded.location_logical_id,status='ACTIVE',revoked_at=null,
        note=excluded.note,updated_at=now();
  end if;
  if p_preferred_location_id is not null then
    insert into public.employee_preferences(employee_id,valid_from,valid_to,preference_type,
      preference_value,source,editable_by_employee,status)
    values(p_employee_id,p_day,p_day,'PREFERRED_LOCATION',
      jsonb_build_object('locationId',p_preferred_location_id),'GRAFIK_PRO',true,'ACTIVE');
  end if;
end;
$$;

create or replace function public.uat_master_employee_availability_days_save_v2(
  p_employee_id uuid,p_dates date[],p_kind text,p_all_day boolean default true,
  p_local_start time default null,p_local_end time default null,
  p_preferred_location_id uuid default null,p_note text default null
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_day date; v_kind text:=upper(trim(coalesce(p_kind,'')));
  v_saved integer:=0; v_role uuid; v_hot_limit integer; v_existing_hard integer;
  v_pending integer:=0;
begin
  perform solver_private.assert_uat_master_persona_v2();
  if not exists(select 1 from public.employees employee where employee.id=p_employee_id
    and employee.active and employee.archived_at is null) then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  if v_kind not in ('AVAILABLE','PREFER_NOT_TO_WORK','CANNOT_WORK')
    or coalesce(cardinality(p_dates),0)=0 or cardinality(p_dates)>62 then
    raise exception 'INVALID_AVAILABILITY_REQUEST';
  end if;
  foreach v_day in array p_dates loop
    if v_day is null then raise exception 'INVALID_DATE_RANGE'; end if;
    select grant_row.role_id into v_role from public.matrix_employee_roles_v2 grant_row
    join public.matrix_versions matrix on matrix.id=grant_row.matrix_version_id
    where matrix.status='ACTIVE' and grant_row.employee_id=p_employee_id
      and grant_row.active order by grant_row.is_primary desc,grant_row.id limit 1;
    if v_kind='CANNOT_WORK' then
      select limit_row.maximum_hard_unavailable into v_hot_limit
      from public.workforce_calendar_events_v2 event
      join public.workforce_hot_day_limits_v2 limit_row on limit_row.event_id=event.id
      where event.status='ACTIVE' and event.event_kind='HOT_DAY'
        and event.event_date=v_day and limit_row.role_id=v_role limit 1;
      if v_hot_limit is not null then
        select count(distinct constraint_row.employee_id) into v_existing_hard
        from public.employee_time_constraints_v2 constraint_row
        where constraint_row.status='ACTIVE' and constraint_row.constraint_kind='UNAVAILABLE'
          and constraint_row.employee_id<>p_employee_id
          and constraint_row.time_range && tstzrange(v_day::timestamptz,(v_day+1)::timestamptz,'[)');
        if v_existing_hard>=v_hot_limit then
          insert into public.availability_exception_reviews_v2(employee_id,work_date,role_id,
            requested_kind,status,note,requested_by)
          values(p_employee_id,v_day,v_role,'CANNOT_WORK','PENDING',nullif(trim(p_note),''),v_actor)
          on conflict(employee_id,work_date,role_id) where status='PENDING'
          do update set note=excluded.note,requested_at=now(),requested_by=v_actor;
          v_pending:=v_pending+1;
          continue;
        end if;
      end if;
    else
      update public.availability_exception_reviews_v2 set status='CANCELLED',decided_at=now(),decided_by=v_actor
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

create or replace function public.uat_master_employee_shift_preferences_save_v2(
  p_employee_id uuid,p_month date,p_preferences jsonb
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_month date:=date_trunc('month',p_month)::date; v_period text; v_level text;
begin
  perform solver_private.assert_uat_master_persona_v2();
  if p_month is null or jsonb_typeof(p_preferences)<>'object' then
    raise exception 'INVALID_SHIFT_PERIOD_PREFERENCES';
  end if;
  update public.employee_preferences preference set status='CANCELLED'
  where preference.employee_id=p_employee_id and preference.status='ACTIVE'
    and preference.source='GRAFIK_PRO' and preference.preference_type='PREFERRED_SHIFT'
    and preference.valid_from<v_month+interval '1 month' and preference.valid_to>=v_month;
  foreach v_period in array array['MORNING','MIDDLE','EVENING'] loop
    v_level:=upper(coalesce(p_preferences->>v_period,'NEUTRAL'));
    if v_level not in ('PREFERRED','NEUTRAL','AVOIDED') then
      raise exception 'INVALID_EMPLOYEE_SHIFT_PREFERENCE_LEVEL';
    end if;
    insert into public.employee_preferences(employee_id,valid_from,valid_to,preference_type,
      preference_value,source,editable_by_employee,status)
    values(p_employee_id,v_month,(v_month+interval '1 month - 1 day')::date,
      'PREFERRED_SHIFT',jsonb_build_object('period',v_period,'level',v_level),
      'GRAFIK_PRO',true,'ACTIVE');
  end loop;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'employee_shift_preferences_v2',p_employee_id::text,'UAT_MASTER_UPSERT',
    jsonb_build_object('month',v_month,'preferences',p_preferences,'actingAsEmployeeId',p_employee_id));
  return jsonb_build_object('saved',3,'month',v_month,'employeeId',p_employee_id);
end;
$$;

revoke all on function solver_private.assert_uat_master_persona_v2(),
  solver_private.uat_master_employee_constraints_v2(uuid,date,uuid,text),
  solver_private.uat_master_save_employee_day_v2(uuid,uuid,date,text,boolean,time,time,uuid,text)
  from public,anon,authenticated;
revoke all on function public.uat_master_persona_preview_v2(),
  public.uat_master_persona_select_v2(text,uuid),
  public.uat_master_employee_portal_context_v2(uuid,date),
  public.uat_master_employee_availability_days_save_v2(uuid,date[],text,boolean,time,time,uuid,text),
  public.uat_master_employee_shift_preferences_save_v2(uuid,date,jsonb)
  from public,anon,authenticated;
grant execute on function public.uat_master_persona_preview_v2(),
  public.uat_master_persona_select_v2(text,uuid),
  public.uat_master_employee_portal_context_v2(uuid,date),
  public.uat_master_employee_availability_days_save_v2(uuid,date[],text,boolean,time,time,uuid,text),
  public.uat_master_employee_shift_preferences_save_v2(uuid,date,jsonb)
  to authenticated;

notify pgrst,'reload schema';
