-- Contract-aware employee availability for Matrix v2.
-- A range is expanded into independent local days so an all-day declaration
-- never creates accidental overnight availability between consecutive days.

create or replace function public.employee_availability_bulk_save_v2(
  p_from date,
  p_to date,
  p_kind text,
  p_all_day boolean default true,
  p_local_start time default null,
  p_local_end time default null,
  p_preferred_location_id uuid default null,
  p_note text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_employee_id uuid;
  v_kind text := upper(trim(coalesce(p_kind,'')));
  v_timezone text;
  v_day date;
  v_start timestamptz;
  v_end timestamptz;
  v_count integer := 0;
  v_source_key text;
  v_location_logical_id uuid;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select employee.id into v_employee_id
  from public.employees employee
  where employee.auth_user_id=v_actor and employee.active
  order by employee.created_at limit 1;
  if v_employee_id is null then raise exception 'EMPLOYEE_PROFILE_REQUIRED'; end if;
  if p_from is null or p_to is null or p_to<p_from or p_to-p_from>62 then
    raise exception 'INVALID_DATE_RANGE';
  end if;
  if v_kind not in ('AVAILABLE','PREFER_NOT_TO_WORK','CANNOT_WORK') then
    raise exception 'INVALID_AVAILABILITY_KIND';
  end if;
  if not coalesce(p_all_day,false)
    and (p_local_start is null or p_local_end is null or p_local_end=p_local_start) then
    raise exception 'HOURS_REQUIRED';
  end if;

  select nullif(version.settings->>'timezone','') into v_timezone
  from public.matrix_versions version
  where version.status in ('ACTIVE','DRAFT')
    and version.effective_from<=p_to
    and (version.effective_to is null or version.effective_to>=p_from)
  order by (version.status='ACTIVE') desc,version.version desc limit 1;
  if v_timezone is null then raise exception 'MATRIX_TIMEZONE_REQUIRED'; end if;

  if p_preferred_location_id is not null then
    select location.logical_id into v_location_logical_id
    from public.matrix_locations_v2 location
    join public.matrix_versions version on version.id=location.matrix_version_id
    where location.id=p_preferred_location_id and location.active
      and version.status in ('ACTIVE','DRAFT');
    if v_location_logical_id is null then
      raise exception 'PREFERRED_LOCATION_NOT_FOUND';
    end if;
  end if;

  if v_kind='PREFER_NOT_TO_WORK' then
    insert into public.employee_preferences(
      employee_id,valid_from,valid_to,preference_type,preference_value,
      status
    ) values(
      v_employee_id,p_from,p_to,'OTHER',jsonb_strip_nulls(jsonb_build_object(
        'kind','DAY_OFF','strength','SOFT','note',nullif(trim(p_note),''),
        'locationId',p_preferred_location_id
      )),'ACTIVE'
    );
    v_count := p_to-p_from+1;
  else
    for v_day in select generate_series(p_from,p_to,interval '1 day')::date loop
      if coalesce(p_all_day,false) then
        v_start := v_day::timestamp at time zone v_timezone;
        v_end := (v_day+1)::timestamp at time zone v_timezone;
      else
        v_start := (v_day+p_local_start)::timestamp at time zone v_timezone;
        v_end := case when p_local_end>p_local_start
          then (v_day+p_local_end)::timestamp at time zone v_timezone
          else (v_day+1+p_local_end)::timestamp at time zone v_timezone end;
      end if;
      v_source_key := 'self-bulk:'||v_employee_id::text||':'||v_kind||':'
        ||v_start::text||':'||v_end::text;
      insert into public.employee_time_constraints_v2(
        employee_id,constraint_kind,time_range,location_logical_id,source,
        source_record_key,priority,editable_by_employee,status,note,created_by
      ) values(
        v_employee_id,
        case when v_kind='AVAILABLE' then 'AVAILABLE_WINDOW' else 'UNAVAILABLE' end,
        tstzrange(v_start,v_end,'[)'),v_location_logical_id,'GRAFIK_PRO',
        v_source_key,100,true,'ACTIVE',nullif(trim(p_note),''),v_actor
      ) on conflict (source,source_record_key)
        where source_record_key is not null
        do update set status='ACTIVE',revoked_at=null,updated_at=now(),
          note=excluded.note,location_logical_id=excluded.location_logical_id;
      v_count := v_count+1;
    end loop;
  end if;

  if p_preferred_location_id is not null then
    insert into public.employee_preferences(
      employee_id,valid_from,valid_to,preference_type,preference_value,
      status
    ) values(
      v_employee_id,p_from,p_to,'PREFERRED_LOCATION',
      jsonb_build_object('locationId',p_preferred_location_id),
      'ACTIVE'
    );
  end if;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'employee_availability_v2',v_employee_id::text,'BULK_SAVE',
    jsonb_build_object('from',p_from,'to',p_to,'kind',v_kind,
      'allDay',p_all_day,'days',v_count,
      'preferredLocationId',p_preferred_location_id));
  return jsonb_build_object('employeeId',v_employee_id,'savedDays',v_count,
    'kind',v_kind);
end;
$$;

revoke all on function public.employee_availability_bulk_save_v2(
  date,date,text,boolean,time,time,uuid,text
) from public,anon,authenticated;
grant execute on function public.employee_availability_bulk_save_v2(
  date,date,text,boolean,time,time,uuid,text
) to authenticated;

comment on function public.employee_availability_bulk_save_v2(
  date,date,text,boolean,time,time,uuid,text
) is 'Saves employee availability for a date range: AVAILABLE, soft PREFER_NOT_TO_WORK, or hard CANNOT_WORK. Hours and preferred location are optional.';

create or replace function public.employee_availability_days_save_v2(
  p_dates date[],
  p_kind text,
  p_all_day boolean default true,
  p_local_start time default null,
  p_local_end time default null,
  p_preferred_location_id uuid default null,
  p_note text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dates date[];
  v_day date;
  v_result jsonb;
  v_saved integer:=0;
begin
  select array_agg(distinct day order by day) into v_dates
  from unnest(coalesce(p_dates,'{}'::date[])) day;
  if coalesce(cardinality(v_dates),0)=0 or cardinality(v_dates)>63 then
    raise exception 'INVALID_SELECTED_DAYS';
  end if;
  foreach v_day in array v_dates loop
    v_result:=public.employee_availability_bulk_save_v2(
      v_day,v_day,p_kind,p_all_day,p_local_start,p_local_end,
      p_preferred_location_id,p_note
    );
    v_saved:=v_saved+coalesce((v_result->>'savedDays')::integer,0);
  end loop;
  return jsonb_build_object('savedDays',v_saved,'selectedDays',cardinality(v_dates),
    'kind',upper(trim(p_kind)));
end;
$$;

revoke all on function public.employee_availability_days_save_v2(
  date[],text,boolean,time,time,uuid,text
) from public,anon,authenticated;
grant execute on function public.employee_availability_days_save_v2(
  date[],text,boolean,time,time,uuid,text
) to authenticated;

create or replace function solver_private.normalize_contract_type_v2(p_value text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case regexp_replace(upper(trim(coalesce(p_value,''))),'[^A-ZĄĆĘŁŃÓŚŹŻ0-9]+','','g')
    when 'UMOWAOPRACĘ' then 'UMOWA_O_PRACE'
    when 'UMOWAOPRACE' then 'UMOWA_O_PRACE'
    when 'UOP' then 'UMOWA_O_PRACE'
    when 'CZĘŚĆETATU' then 'CZESC_ETATU'
    when 'CZESCETATU' then 'CZESC_ETATU'
    when 'UMOWAZLECENIE' then 'ZLECENIE'
    when 'ZLECENIE' then 'ZLECENIE'
    when 'UZ' then 'ZLECENIE'
    when 'B2B' then 'B2B'
    else 'INNE'
  end
$$;

alter table public.matrix_employee_profiles_v2
  add column if not exists work_time_policy text not null default 'CONTRACT_DEFAULT'
  check(work_time_policy in ('CONTRACT_DEFAULT','CUSTOM'));

comment on column public.matrix_employee_profiles_v2.work_time_policy is
  'CONTRACT_DEFAULT applies employment-law caps only to employment contracts. CUSTOM makes the individually entered caps hard also for flexible contracts.';

create or replace function solver_private.seed_matrix_employee_profiles_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status='DRAFT' and new.schema_version>=2 and new.base_version_id is not null then
    insert into public.matrix_employee_profiles_v2(
      id,matrix_version_id,employee_id,employee_no,first_name,last_name,email,
      active,employment_start,employment_end,nominal_monthly_minutes,
      maximum_monthly_minutes,maximum_weekly_minutes,maximum_consecutive_days,
      minimum_rest_minutes,only_morning,only_evening,no_weekends,
      preferred_shift_code,work_time_policy,archived_at,archived_by,archive_reason,
      created_by,updated_by,created_at,updated_at
    )
    select gen_random_uuid(),new.id,profile.employee_id,profile.employee_no,
      profile.first_name,profile.last_name,profile.email,profile.active,
      profile.employment_start,profile.employment_end,
      profile.nominal_monthly_minutes,profile.maximum_monthly_minutes,
      profile.maximum_weekly_minutes,profile.maximum_consecutive_days,
      profile.minimum_rest_minutes,profile.only_morning,profile.only_evening,
      profile.no_weekends,profile.preferred_shift_code,profile.work_time_policy,
      profile.archived_at,profile.archived_by,profile.archive_reason,
      coalesce(new.created_by,profile.created_by),
      coalesce(new.created_by,profile.updated_by),now(),now()
    from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=new.base_version_id
    on conflict(matrix_version_id,employee_id) do nothing;
  end if;
  return new;
end;
$$;

alter function solver_private.build_snapshot_payload_v2(
  uuid,date,uuid,uuid,text,uuid
) rename to build_snapshot_payload_before_contract_uat_v2;

create or replace function solver_private.build_snapshot_payload_v2(
  p_run_id uuid,
  p_month date,
  p_matrix_version_id uuid,
  p_scenario_id uuid,
  p_scope_type text,
  p_scope_role_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_snapshot jsonb;
  v_employees jsonb:='[]'::jsonb;
  v_employee jsonb;
begin
  v_snapshot:=solver_private.build_snapshot_payload_before_contract_uat_v2(
    p_run_id,p_month,p_matrix_version_id,p_scenario_id,
    p_scope_type,p_scope_role_id
  );
  for v_employee in select employee.value
    from jsonb_array_elements(coalesce(v_snapshot->'employees','[]'::jsonb)) employee
  loop
    v_employee:=v_employee||jsonb_build_object(
      'workTimePolicy',coalesce((select profile.work_time_policy
        from public.matrix_employee_profiles_v2 profile
        where profile.matrix_version_id=p_matrix_version_id
          and profile.employee_id=(v_employee->>'id')::uuid
      ),'CONTRACT_DEFAULT')
    );
    v_employees:=v_employees||jsonb_build_array(v_employee);
  end loop;
  return jsonb_set(v_snapshot,'{employees}',v_employees,true);
end;
$$;

revoke all on function solver_private.seed_matrix_employee_profiles_v2(),
  solver_private.build_snapshot_payload_before_contract_uat_v2(
    uuid,date,uuid,uuid,text,uuid
  ),
  solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)
  from public,anon,authenticated;
grant execute on function solver_private.seed_matrix_employee_profiles_v2(),
  solver_private.build_snapshot_payload_before_contract_uat_v2(
    uuid,date,uuid,uuid,text,uuid
  ),
  solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)
  to service_role;

create or replace function public.matrix_v2_employee_save_uat_v2(
  p_employee_id uuid default null,
  p_data jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
  v_employee uuid;
  v_contract text;
  v_fraction numeric;
  v_policy text;
begin
  v_result := public.matrix_v2_employee_save_alpha16(p_employee_id,p_data);
  v_employee := (v_result->>'id')::uuid;
  if p_data ? 'contractType' then
    v_contract := solver_private.normalize_contract_type_v2(p_data->>'contractType');
    v_fraction := greatest(.01,least(1,coalesce(
      nullif(replace(p_data->>'employmentFraction',',','.'),'')::numeric,1
    )));
    insert into public.employee_hr_profiles(
      employee_id,contract_type,employment_fraction,updated_by,updated_at
    ) values(v_employee,v_contract,v_fraction,auth.uid(),now())
    on conflict(employee_id) do update set
      contract_type=excluded.contract_type,
      employment_fraction=excluded.employment_fraction,
      updated_by=auth.uid(),updated_at=now();
  end if;
  if p_data ? 'workTimePolicy' then
    v_policy:=case when upper(coalesce(p_data->>'workTimePolicy',''))='CUSTOM'
      then 'CUSTOM' else 'CONTRACT_DEFAULT' end;
  else
    select profile.work_time_policy into v_policy
    from public.matrix_employee_profiles_v2 profile
    where profile.employee_id=v_employee
      and profile.matrix_version_id=(select version.id
        from public.matrix_versions version
        where version.status='DRAFT' and version.schema_version>=2
        order by version.version desc limit 1);
    v_policy:=coalesce(v_policy,'CONTRACT_DEFAULT');
  end if;
  update public.matrix_employee_profiles_v2 profile set
    work_time_policy=v_policy,updated_by=auth.uid(),updated_at=now()
  where profile.employee_id=v_employee
    and profile.matrix_version_id=(select version.id
      from public.matrix_versions version
      where version.status='DRAFT' and version.schema_version>=2
      order by version.version desc limit 1);
  return v_result||jsonb_build_object('contractType',coalesce(v_contract,
    (select profile.contract_type from public.employee_hr_profiles profile
      where profile.employee_id=v_employee)),'workTimePolicy',v_policy);
end;
$$;

create or replace function public.matrix_v2_import_preview_uat_v2(p_payload jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_preview jsonb;
  v_errors jsonb;
  v_row jsonb;
  v_index integer;
  v_matrix uuid;
  v_duty_count integer;
begin
  v_preview := public.matrix_v2_import_preview_alpha16(p_payload);
  v_errors := coalesce(v_preview->'errors','[]'::jsonb);
  v_matrix := (v_preview->>'matrixVersionId')::uuid;
  if jsonb_typeof(coalesce(p_payload->'employeeDuties','[]'::jsonb))<>'array' then
    raise exception 'INVALID_EMPLOYEE_DUTIES_IMPORT';
  end if;
  for v_row,v_index in
    select row.value,row.ordinality::integer
    from jsonb_array_elements(coalesce(p_payload->'employeeDuties','[]'::jsonb))
      with ordinality row(value,ordinality)
  loop
    if not exists(
      select 1 from jsonb_array_elements(coalesce(p_payload->'employees','[]'::jsonb)) employee
      where (nullif(lower(trim(v_row->>'email')),'') is not null
          and lower(trim(employee.value->>'email'))=lower(trim(v_row->>'email')))
        or (nullif(trim(v_row->>'employeeNo'),'') is not null
          and upper(trim(employee.value->>'employeeNo'))=upper(trim(v_row->>'employeeNo')))
    ) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','BAZA_PRACOWNIKÓW','row',v_index+1,
        'code','EMPLOYEE_DUTY_EMPLOYEE_NOT_FOUND',
        'message','Funkcja pracownika nie wskazuje osoby z sekcji pracowników.'
      ));
    end if;
    if not exists(select 1 from public.matrix_duties_v2 duty
      where duty.matrix_version_id=v_matrix and duty.active
        and upper(duty.code)=upper(coalesce(v_row->>'dutyCode',''))) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','BAZA_PRACOWNIKÓW','row',v_index+1,
        'code','EMPLOYEE_DUTY_NOT_FOUND',
        'message','Kolumna funkcji nie odpowiada aktywnemu obowiązkowi w Matrixie.'
      ));
    end if;
  end loop;
  v_duty_count:=jsonb_array_length(coalesce(p_payload->'employeeDuties','[]'::jsonb));
  v_preview:=jsonb_set(v_preview,'{errors}',v_errors,true);
  v_preview:=jsonb_set(v_preview,'{valid}',to_jsonb(jsonb_array_length(v_errors)=0),true);
  v_preview:=jsonb_set(v_preview,'{summary,employeeDuties}',to_jsonb(v_duty_count),true);
  v_preview:=jsonb_set(v_preview,'{summary,total}',to_jsonb(
    coalesce((v_preview->'summary'->>'total')::integer,0)+v_duty_count
  ),true);
  return v_preview;
end;
$$;

create or replace function public.matrix_v2_import_apply_uat_v2(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
  v_matrix uuid;
  v_row jsonb;
  v_employee uuid;
  v_contract text;
  v_fraction numeric;
  v_duty uuid;
  v_role uuid;
  v_existing uuid;
begin
  if not (public.matrix_v2_import_preview_uat_v2(p_payload)->>'valid')::boolean then
    raise exception 'MATRIX_IMPORT_HAS_ERRORS';
  end if;
  v_result := public.matrix_v2_import_apply_alpha16(p_payload);
  select version.id into v_matrix from public.matrix_versions version
  where version.status='DRAFT' and version.schema_version>=2
  order by version.version desc limit 1;
  for v_row in select value from jsonb_array_elements(
    coalesce(p_payload->'employees','[]'::jsonb)
  ) loop
    select profile.employee_id into v_employee
    from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=v_matrix and (
      (nullif(trim(v_row->>'employeeNo'),'') is not null
        and upper(profile.employee_no)=upper(trim(v_row->>'employeeNo')))
      or (nullif(lower(trim(v_row->>'email')),'') is not null
        and lower(profile.email)=lower(trim(v_row->>'email')))
    ) order by profile.employee_id limit 1;
    if v_employee is null then raise exception 'IMPORTED_EMPLOYEE_NOT_FOUND'; end if;
    v_contract := solver_private.normalize_contract_type_v2(v_row->>'contractType');
    v_fraction := greatest(.01,least(1,coalesce(
      nullif(replace(v_row->>'employmentFraction',',','.'),'')::numeric,1
    )));
    insert into public.employee_hr_profiles(
      employee_id,contract_type,employment_fraction,updated_by,updated_at
    ) values(v_employee,v_contract,v_fraction,auth.uid(),now())
    on conflict(employee_id) do update set
      contract_type=excluded.contract_type,
      employment_fraction=excluded.employment_fraction,
      updated_by=auth.uid(),updated_at=now();
    update public.matrix_employee_profiles_v2 profile set
      work_time_policy=case when upper(coalesce(v_row->>'workTimePolicy',''))='CUSTOM'
        then 'CUSTOM' else 'CONTRACT_DEFAULT' end,
      updated_by=auth.uid(),updated_at=now()
    where profile.matrix_version_id=v_matrix
      and profile.employee_id=v_employee;
  end loop;
  for v_row in select value from jsonb_array_elements(
    coalesce(p_payload->'employeeDuties','[]'::jsonb)
  ) loop
    select profile.employee_id into v_employee
    from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=v_matrix and (
      (nullif(trim(v_row->>'employeeNo'),'') is not null
        and upper(profile.employee_no)=upper(trim(v_row->>'employeeNo')))
      or (nullif(lower(trim(v_row->>'email')),'') is not null
        and lower(profile.email)=lower(trim(v_row->>'email')))
    ) order by profile.employee_id limit 1;
    select duty.id into v_duty from public.matrix_duties_v2 duty
    where duty.matrix_version_id=v_matrix
      and upper(duty.code)=upper(v_row->>'dutyCode');
    select role.id into v_role from public.matrix_roles_v2 role
    where role.matrix_version_id=v_matrix
      and upper(role.code)=upper(v_row->>'roleCode');
    select capability.id into v_existing
    from public.matrix_employee_duties_v2 capability
    where capability.matrix_version_id=v_matrix
      and capability.employee_id=v_employee and capability.duty_id=v_duty
      and capability.role_id is not distinct from v_role
      and capability.location_id is null;
    perform public.matrix_v2_admin_save_alpha16(
      'EMPLOYEE_DUTY',v_existing,jsonb_build_object(
        'employeeId',v_employee,'dutyId',v_duty,'roleId',v_role,
        'locationId',null,'active',coalesce((v_row->>'active')::boolean,true)
      )
    );
  end loop;
  return v_result;
end;
$$;

create or replace function public.matrix_v2_employee_directory_alpha16(
  p_month date default current_date
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_directory jsonb;
  v_matrix uuid;
  v_month date:=date_trunc('month',coalesce(p_month,current_date))::date;
  v_employees jsonb;
begin
  v_directory:=public.matrix_v2_employee_directory_v2();
  v_matrix:=(v_directory->>'matrixVersionId')::uuid;
  select coalesce(jsonb_agg(
    employee.value || jsonb_build_object(
      'contractType',coalesce((select hr.contract_type
        from public.employee_hr_profiles hr
        where hr.employee_id=(employee.value->>'id')::uuid),'INNE'),
      'employmentFraction',coalesce((select hr.employment_fraction
        from public.employee_hr_profiles hr
        where hr.employee_id=(employee.value->>'id')::uuid),1),
      'workTimePolicy',coalesce((select profile.work_time_policy
        from public.matrix_employee_profiles_v2 profile
        where profile.matrix_version_id=v_matrix
          and profile.employee_id=(employee.value->>'id')::uuid
      ),'CONTRACT_DEFAULT'),
      'locationIds',coalesce((select jsonb_agg(location_grant.location_id::text
        order by location_grant.location_id::text)
        from public.matrix_employee_locations_v2 location_grant
        where location_grant.matrix_version_id=v_matrix
          and location_grant.employee_id=(employee.value->>'id')::uuid
          and location_grant.standard_allowed and location_grant.active
      ),'[]'::jsonb),
      'shiftPeriodPreferences',coalesce((select jsonb_object_agg(
        upper(preference.preference_value->>'period'),
        upper(preference.preference_value->>'level')
      ) from public.employee_preferences preference
        where preference.employee_id=(employee.value->>'id')::uuid
          and preference.preference_type='PREFERRED_SHIFT'
          and preference.source='MANAGER' and preference.status='ACTIVE'
          and preference.preference_value->>'matrixVersionId'=v_matrix::text
          and preference.valid_from<v_month+interval '1 month'
          and preference.valid_to>=v_month
      ),'{}'::jsonb)
    ) order by employee.ordinality
  ),'[]'::jsonb) into v_employees
  from jsonb_array_elements(coalesce(v_directory->'employees','[]'::jsonb))
    with ordinality employee(value,ordinality);
  return jsonb_set(v_directory,'{employees}',v_employees,true);
end;
$$;

revoke all on function solver_private.normalize_contract_type_v2(text)
  from public,anon,authenticated;
revoke all on function public.matrix_v2_employee_save_uat_v2(uuid,jsonb),
  public.matrix_v2_import_preview_uat_v2(jsonb),
  public.matrix_v2_import_apply_uat_v2(jsonb) from public,anon,authenticated;
grant execute on function public.matrix_v2_employee_save_uat_v2(uuid,jsonb),
  public.matrix_v2_import_preview_uat_v2(jsonb),
  public.matrix_v2_import_apply_uat_v2(jsonb) to authenticated;
grant execute on function solver_private.normalize_contract_type_v2(text)
  to service_role;

create or replace function public.optimizer_variant_workspace_uat_v2(
  p_variant_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_run uuid;
  v_context jsonb;
  v_workspace jsonb;
  v_can_view_finance boolean;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select run.id,jsonb_build_object(
    'type','VARIANT_PREVIEW','runId',run.id,'engine',run.request_engine,
    'requestEngine',run.request_engine,'month',run.month,'name',variant.name,
    'scenario',jsonb_build_object('id',scenario.id,'name',scenario.name),
    'matrixVersionId',run.matrix_version_id
  ) into v_run,v_context
  from public.plan_variants_v2 variant
  join public.optimization_runs_v2 run on run.id=variant.run_id
  join public.matrix_scenarios_v2 scenario on scenario.id=run.scenario_id
  where variant.id=p_variant_id;
  if v_run is null or not solver_private.can_access_run_v2(v_run) then
    raise exception 'VARIANT_NOT_FOUND';
  end if;
  v_can_view_finance:=public.has_app_role('OWNER')
    or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE');
  v_workspace:=solver_private.variant_set_workspace_v2(
    array[p_variant_id],v_context,v_can_view_finance
  );
  return solver_private.alpha16_enrich_workspace_issues_v2(
    v_workspace,array[p_variant_id]
  );
end;
$$;

revoke all on function public.optimizer_variant_workspace_uat_v2(uuid)
  from public,anon,authenticated;
grant execute on function public.optimizer_variant_workspace_uat_v2(uuid)
  to authenticated;

create table public.published_role_schedules_v2 (
  id uuid primary key default gen_random_uuid(),
  idempotency_key text not null check(length(idempotency_key) between 8 and 200),
  month date not null check(date_trunc('month',month)::date=month),
  matrix_version_id uuid not null references public.matrix_versions(id),
  scenario_id uuid not null references public.matrix_scenarios_v2(id),
  role_id uuid not null references public.matrix_roles_v2(id),
  variant_id uuid not null references public.plan_variants_v2(id),
  name text not null check(length(trim(name)) between 1 and 200),
  status text not null default 'PUBLISHED' check(status in ('PUBLISHED','ARCHIVED')),
  publication_hash text not null check(publication_hash ~ '^[0-9a-f]{64}$'),
  created_by uuid not null references auth.users(id),
  published_at timestamptz not null default now(),
  archived_at timestamptz,
  archived_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  unique(created_by,idempotency_key),
  check((status='PUBLISHED' and archived_at is null and archived_by is null)
    or (status='ARCHIVED' and archived_at is not null))
);

create unique index published_role_schedules_v2_current_role_month
  on public.published_role_schedules_v2(month,role_id)
  where status='PUBLISHED';
create index published_role_schedules_v2_variant_idx
  on public.published_role_schedules_v2(variant_id);

alter table public.published_role_schedules_v2 enable row level security;
create policy published_role_schedules_v2_manager_read
on public.published_role_schedules_v2 for select to authenticated
using (
  (select public.has_app_role('OWNER'))
  or (select public.has_app_role('ADMIN'))
  or exists(
    select 1 from public.matrix_roles_v2 role
    join public.matrix_scope_grants_v2 grant_row
      on grant_row.role_logical_id is null
      or grant_row.role_logical_id=role.logical_id
    where role.id=published_role_schedules_v2.role_id
      and grant_row.auth_user_id=(select auth.uid())
      and grant_row.active and grant_row.app_role='ROLE_MANAGER'
  )
);

revoke all on table public.published_role_schedules_v2
  from public,anon,authenticated;
grant select on table public.published_role_schedules_v2 to authenticated;
grant all on table public.published_role_schedules_v2 to service_role;

create or replace function public.optimizer_publish_role_variant_uat_v2(
  p_run_id uuid,
  p_variant_id uuid,
  p_name text,
  p_idempotency_key text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid:=auth.uid();
  v_run public.optimization_runs_v2%rowtype;
  v_variant public.plan_variants_v2%rowtype;
  v_role_logical_id uuid;
  v_existing public.published_role_schedules_v2%rowtype;
  v_id uuid:=gen_random_uuid();
  v_validation jsonb;
  v_month date;
  v_notified integer:=0;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if length(coalesce(p_idempotency_key,'')) not between 8 and 200 then
    raise exception 'INVALID_IDEMPOTENCY_KEY';
  end if;
  if length(trim(coalesce(p_name,''))) not between 1 and 200 then
    raise exception 'INVALID_PLAN_NAME';
  end if;
  select run.month into v_month
  from public.optimization_runs_v2 run where run.id=p_run_id;
  if v_month is null then raise exception 'VARIANT_NOT_FOUND'; end if;

  -- Keep the same lock order as company publication and variant selection.
  -- This serializes a team publication with any company-wide publication for
  -- the same month and avoids an advisory/row-lock cycle.
  perform solver_private.lock_planning_revision_v2();
  perform pg_advisory_xact_lock(hashtextextended(
    'publish-v2-month:'||v_month::text,0
  ));
  perform pg_advisory_xact_lock(hashtextextended(
    'select-v2:'||p_run_id::text,0
  ));

  select * into v_run from public.optimization_runs_v2 run
  where run.id=p_run_id for update;
  select * into v_variant from public.plan_variants_v2 variant
  where variant.id=p_variant_id and variant.run_id=p_run_id for update;
  if v_run.id is null or v_variant.id is null then raise exception 'VARIANT_NOT_FOUND'; end if;
  if v_run.month<>v_month then raise exception 'RUN_MONTH_CHANGED'; end if;
  if v_run.scope_type<>'ROLE' or v_run.scope_role_id is null then
    raise exception 'ROLE_VARIANT_REQUIRED';
  end if;
  if v_run.request_engine<>'ORTOOLS_V2' then raise exception 'SHADOW_RUN_NOT_PUBLISHABLE'; end if;
  if v_run.status<>'READY' or not v_variant.selected
    or v_variant.hard_violations<>0
    or v_variant.status not in ('SELECTED','PUBLISHED') then
    raise exception 'SELECTED_VALID_ROLE_VARIANT_REQUIRED';
  end if;
  select role.logical_id into v_role_logical_id
  from public.matrix_roles_v2 role where role.id=v_run.scope_role_id;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN'))
    and not exists(select 1 from public.matrix_scope_grants_v2 grant_row
      where grant_row.auth_user_id=v_actor and grant_row.active
        and grant_row.app_role='ROLE_MANAGER'
        and (grant_row.role_logical_id is null
          or grant_row.role_logical_id=v_role_logical_id)) then
    raise exception 'ROLE_PUBLICATION_FORBIDDEN';
  end if;
  select * into v_existing from public.published_role_schedules_v2 publication
  where publication.created_by=v_actor
    and publication.idempotency_key=p_idempotency_key;
  if v_existing.id is not null then
    if v_existing.variant_id<>p_variant_id or v_existing.name<>trim(p_name) then
      raise exception 'IDEMPOTENCY_KEY_REUSED';
    end if;
    return jsonb_build_object('roleScheduleId',v_existing.id,
      'status',v_existing.status,'reused',true,'notified',0);
  end if;
  -- A standalone team publication has no later company-level validation step,
  -- so it must execute the complete hard-rule revalidation here.
  v_validation:=solver_private.revalidate_materialized_variant_v2(
    p_variant_id,false
  );
  update public.published_role_schedules_v2 publication set
    status='ARCHIVED',archived_at=now(),archived_by=v_actor
  where publication.month=v_run.month
    and publication.role_id=v_run.scope_role_id
    and publication.status='PUBLISHED';
  insert into public.published_role_schedules_v2(
    id,idempotency_key,month,matrix_version_id,scenario_id,role_id,
    variant_id,name,publication_hash,created_by
  ) values(
    v_id,p_idempotency_key,v_run.month,v_run.matrix_version_id,v_run.scenario_id,
    v_run.scope_role_id,p_variant_id,trim(p_name),v_variant.solution_hash,v_actor
  );
  insert into public.notifications(recipient_id,channel,title,body)
  select distinct employee.auth_user_id,'IN_APP','Opublikowano grafik Twojego zespołu',
    trim(p_name)||' jest już dostępny w Portalu pracownika.'
  from public.plan_assignments_v2 assignment
  join public.employees employee on employee.id=assignment.employee_id
  where assignment.variant_id=p_variant_id and employee.auth_user_id is not null;
  get diagnostics v_notified=row_count;
  update public.plan_variants_v2
  set status='PUBLISHED',published_at=now()
  where id=p_variant_id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'published_role_schedule_v2',v_id::text,'PUBLISH',
    jsonb_build_object('runId',p_run_id,'variantId',p_variant_id,
      'roleId',v_run.scope_role_id,'notified',v_notified,
      'validation',v_validation));
  return jsonb_build_object('roleScheduleId',v_id,'status','PUBLISHED',
    'reused',false,'notified',v_notified);
end;
$$;

revoke all on function public.optimizer_publish_role_variant_uat_v2(
  uuid,uuid,text,text
) from public,anon,authenticated;
grant execute on function public.optimizer_publish_role_variant_uat_v2(
  uuid,uuid,text,text
) to authenticated;

create or replace function public.optimizer_employee_schedule_uat_v2(
  p_month date
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_engine text;
  v_employee_id uuid;
  v_schedule_id uuid;
  v_month date:=date_trunc('month',p_month)::date;
  v_variant_ids uuid[];
  v_role_schedule_ids jsonb:='[]'::jsonb;
  v_source_type text;
  v_assignments jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  select flag.engine into v_engine
  from public.solver_feature_flags flag
  where flag.flag_key='DEFAULT_ENGINE' and flag.enabled;
  if v_engine is null then raise exception 'SOLVER_ENGINE_CONFIGURATION_MISSING'; end if;
  if v_engine not in ('ALPHA15','SHADOW','ORTOOLS_V2') then
    raise exception 'SOLVER_ENGINE_CONFIGURATION_INVALID';
  end if;
  if v_engine<>'ORTOOLS_V2' then return null; end if;

  select employee.id into v_employee_id
  from public.employees employee
  where employee.auth_user_id=auth.uid()
    and employee.active and employee.archived_at is null
  order by employee.employee_no limit 1;
  if v_employee_id is null then raise exception 'EMPLOYEE_ACCOUNT_NOT_LINKED'; end if;

  -- A separately published team schedule is immediately authoritative for
  -- members of that team. It does not wait for a company-wide publication.
  select array_agg(distinct publication.variant_id order by publication.variant_id),
    jsonb_agg(distinct to_jsonb(publication.id))
  into v_variant_ids,v_role_schedule_ids
  from public.published_role_schedules_v2 publication
  where publication.month=v_month and publication.status='PUBLISHED'
    and exists(
      select 1 from public.plan_assignments_v2 assignment
      where assignment.variant_id=publication.variant_id
        and assignment.employee_id=v_employee_id
    );

  if coalesce(cardinality(v_variant_ids),0)>0 then
    v_source_type:='ROLE';
  else
    select schedule.id into v_schedule_id
    from public.published_schedules_v2 schedule
    where schedule.month=v_month and schedule.status='PUBLISHED'
    order by schedule.published_at desc,schedule.id desc limit 1;
    if v_schedule_id is not null then
      select array_agg(link.variant_id order by link.ordinal)
      into v_variant_ids
      from public.published_schedule_variants_v2 link
      where link.schedule_id=v_schedule_id;
      v_source_type:='COMPANY';
    end if;
  end if;

  if coalesce(cardinality(v_variant_ids),0)=0 then
    return jsonb_build_object(
      'engine','ORTOOLS_V2','sourceType',null,'scheduleId',null,
      'roleScheduleIds','[]'::jsonb,'assignments','[]'::jsonb
    );
  end if;

  with own_assignments as (
    select assignment.id,assignment.employee_id,assignment.role_id,
      assignment.shift_id,shift.slot_group_key,shift.shift_date,
      shift.starts_at,shift.ends_at,shift.location_id,
      shift.shift_template_id
    from public.plan_assignments_v2 assignment
    join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
    where assignment.variant_id=any(v_variant_ids)
      and assignment.employee_id=v_employee_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',own.id,
    'shiftId',own.slot_group_key,
    'date',own.shift_date,
    'startsAt',own.starts_at,
    'endsAt',own.ends_at,
    'shiftCode',shift_template.code,
    'shiftName',shift_template.name,
    'location',location.name,
    'locationCode',location.code,
    'locationTimezone',location.timezone,
    'role',role.name,
    'roleCode',role.code,
    'capability',coalesce((
      select string_agg(duty.name,', ' order by duty.sort_order,duty.name)
      from public.plan_assignment_duties_v2 assignment_duty
      join public.matrix_duties_v2 duty on duty.id=assignment_duty.duty_id
      where assignment_duty.assignment_id=own.id
    ),''),
    'coworkers',coalesce((
      select jsonb_agg(jsonb_build_object(
        'name',coworker.first_name||' '||coworker.last_name,
        'role',coworker_role.name,
        'capability',coalesce((
          select string_agg(duty.name,', ' order by duty.sort_order,duty.name)
          from public.plan_assignment_duties_v2 assignment_duty
          join public.matrix_duties_v2 duty on duty.id=assignment_duty.duty_id
          where assignment_duty.assignment_id=coworker_assignment.id
        ),'')
      ) order by coworker.last_name,coworker.first_name,
        coworker_assignment.id)
      from public.plan_assignments_v2 coworker_assignment
      join public.plan_shifts_v2 coworker_shift
        on coworker_shift.id=coworker_assignment.shift_id
      join public.employees coworker
        on coworker.id=coworker_assignment.employee_id
      join public.matrix_roles_v2 coworker_role
        on coworker_role.id=coworker_assignment.role_id
      where coworker_assignment.variant_id=any(v_variant_ids)
        and coworker_assignment.employee_id<>v_employee_id
        and coworker_shift.slot_group_key=own.slot_group_key
        and coworker_shift.location_id=own.location_id
        and coworker_shift.starts_at=own.starts_at
        and coworker_shift.ends_at=own.ends_at
    ),'[]'::jsonb)
  ) order by own.starts_at,own.id),'[]'::jsonb)
  into v_assignments
  from own_assignments own
  join public.matrix_locations_v2 location on location.id=own.location_id
  join public.matrix_shift_templates_v2 shift_template
    on shift_template.id=own.shift_template_id
  join public.matrix_roles_v2 role on role.id=own.role_id;

  return jsonb_build_object(
    'engine','ORTOOLS_V2','sourceType',v_source_type,
    'scheduleId',v_schedule_id,'roleScheduleIds',v_role_schedule_ids,
    'assignments',v_assignments
  );
end;
$$;

revoke all on function public.optimizer_employee_schedule_uat_v2(date)
  from public,anon,authenticated;
grant execute on function public.optimizer_employee_schedule_uat_v2(date)
  to authenticated;

create or replace function public.matrix_v2_staffing_bulk_adjust_uat_v2(
  p_scenario_id uuid,
  p_location_id uuid default null,
  p_shift_period text default null,
  p_role_id uuid default null,
  p_delta integer default 1
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_matrix uuid;
  v_scenario uuid;
  v_location uuid;
  v_role uuid;
  v_period text:=nullif(upper(trim(coalesce(p_shift_period,''))), '');
  v_matching integer:=0;
  v_updated integer:=0;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if p_scenario_id is null then raise exception 'SCENARIO_REQUIRED'; end if;
  if coalesce(p_delta,0)=0 or abs(p_delta)>20 then
    raise exception 'INVALID_STAFFING_BULK_DELTA';
  end if;
  if v_period is not null and v_period not in ('MORNING','MIDDLE','EVENING') then
    raise exception 'INVALID_SHIFT_PERIOD';
  end if;

  v_matrix:=public.matrix_v2_create_draft(null);
  select target.id into v_scenario
  from public.matrix_scenarios_v2 source
  join public.matrix_scenarios_v2 target
    on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
  where source.id=p_scenario_id;
  if v_scenario is null then raise exception 'SCENARIO_NOT_IN_MATRIX_V2'; end if;

  if p_location_id is not null then
    select target.id into v_location
    from public.matrix_locations_v2 source
    join public.matrix_locations_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=p_location_id;
    if v_location is null then raise exception 'LOCATION_NOT_IN_MATRIX_V2'; end if;
  end if;
  if p_role_id is not null then
    select target.id into v_role
    from public.matrix_roles_v2 source
    join public.matrix_roles_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=p_role_id;
    if v_role is null then raise exception 'ROLE_NOT_IN_MATRIX_V2'; end if;
  end if;

  select count(*) into v_matching
  from public.matrix_staffing_rules_v2 rule
  join public.matrix_shift_templates_v2 shift
    on shift.id=rule.shift_template_id
  where rule.matrix_version_id=v_matrix and rule.scenario_id=v_scenario
    and rule.active
    and (v_location is null or shift.location_id=v_location)
    and (v_period is null or shift.shift_period=v_period)
    and (v_role is null or rule.role_id=v_role);

  update public.matrix_staffing_rules_v2 rule set
    count_value=greatest(0,coalesce(rule.count_value,0)+p_delta),
    updated_at=now()
  from public.matrix_shift_templates_v2 shift
  where shift.id=rule.shift_template_id
    and rule.matrix_version_id=v_matrix and rule.scenario_id=v_scenario
    and rule.active and rule.operation in ('SET','ADD')
    and (v_location is null or shift.location_id=v_location)
    and (v_period is null or shift.shift_period=v_period)
    and (v_role is null or rule.role_id=v_role);
  get diagnostics v_updated=row_count;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_version',v_matrix::text,'BULK_ADJUST_STAFFING',
    jsonb_build_object(
      'scenarioId',v_scenario,'locationId',v_location,'shiftPeriod',v_period,
      'roleId',v_role,'delta',p_delta,'updated',v_updated,
      'skipped',greatest(v_matching-v_updated,0)
    ));
  return jsonb_build_object(
    'matrixVersionId',v_matrix,'updated',v_updated,
    'skipped',greatest(v_matching-v_updated,0)
  );
end;
$$;

revoke all on function public.matrix_v2_staffing_bulk_adjust_uat_v2(
  uuid,uuid,text,uuid,integer
) from public,anon,authenticated;
grant execute on function public.matrix_v2_staffing_bulk_adjust_uat_v2(
  uuid,uuid,text,uuid,integer
) to authenticated;

create or replace function public.optimizer_variant_issue_diagnostics_uat_v2(
  p_variant_id uuid,
  p_issue_id bigint
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_variant public.plan_variants_v2%rowtype;
  v_run public.optimization_runs_v2%rowtype;
  v_issue public.plan_issues_v2%rowtype;
  v_shift public.plan_shifts_v2%rowtype;
  v_shift_period text;
  v_timezone text;
  v_default_rest integer;
  v_default_missing boolean;
  v_summary jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into v_variant from public.plan_variants_v2 variant
  where variant.id=p_variant_id;
  if v_variant.id is null then raise exception 'VARIANT_NOT_FOUND'; end if;
  select * into v_run from public.optimization_runs_v2 run
  where run.id=v_variant.run_id;
  if v_run.id is null or not solver_private.can_access_run_v2(v_run.id) then
    raise exception 'VARIANT_NOT_FOUND';
  end if;
  select * into v_issue from public.plan_issues_v2 issue
  where issue.id=p_issue_id and issue.variant_id=p_variant_id
    and issue.issue_code='UNFILLED_SLOT';
  if v_issue.id is null then raise exception 'UNFILLED_ISSUE_NOT_FOUND'; end if;
  select * into v_shift from public.plan_shifts_v2 shift
  where shift.id=v_issue.shift_id;
  if v_shift.id is null then raise exception 'SHIFT_NOT_FOUND'; end if;
  select template.shift_period,location.timezone
  into v_shift_period,v_timezone
  from public.matrix_shift_templates_v2 template
  join public.matrix_locations_v2 location on location.id=template.location_id
  where template.id=v_shift.shift_template_id;
  select coalesce((matrix.settings->>'minimumRestMinutes')::integer,660),
    coalesce((matrix.settings->>'missingAvailabilityMeansAvailable')::boolean,true)
  into v_default_rest,v_default_missing
  from public.matrix_versions matrix where matrix.id=v_run.matrix_version_id;

  with scheduled as (
    select assignment.employee_id,shift.starts_at,shift.ends_at,shift.shift_date
    from public.plan_assignments_v2 assignment
    join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
    where assignment.variant_id=p_variant_id
  ), profiles as (
    select profile.*,coalesce(hr.contract_type,'INNE') contract_type,
      case when coalesce(hr.contract_type,'INNE') in ('ZLECENIE','B2B')
        and profile.work_time_policy<>'CUSTOM'
        then 0 else coalesce(profile.minimum_rest_minutes,v_default_rest) end rest_minutes
    from public.matrix_employee_profiles_v2 profile
    left join public.employee_hr_profiles hr on hr.employee_id=profile.employee_id
    where profile.matrix_version_id=v_run.matrix_version_id
      and profile.active and profile.archived_at is null
  ), evaluated as (
    select profile.*,
      exists(select 1 from public.matrix_employee_roles_v2 grant_row
        where grant_row.matrix_version_id=v_run.matrix_version_id
          and grant_row.employee_id=profile.employee_id
          and grant_row.role_id=v_issue.role_id and grant_row.active
          and (grant_row.valid_from is null or grant_row.valid_from<=v_shift.shift_date)
          and (grant_row.valid_to is null or grant_row.valid_to>=v_shift.shift_date)) role_ok,
      exists(select 1 from public.matrix_employee_locations_v2 grant_row
        where grant_row.matrix_version_id=v_run.matrix_version_id
          and grant_row.employee_id=profile.employee_id
          and grant_row.location_id=v_shift.location_id
          and grant_row.active and grant_row.standard_allowed
          and (grant_row.valid_from is null or grant_row.valid_from<=v_shift.shift_date)
          and (grant_row.valid_to is null or grant_row.valid_to>=v_shift.shift_date)) location_ok,
      v_issue.duty_id is null or exists(
        select 1 from public.matrix_employee_duties_v2 grant_row
        where grant_row.matrix_version_id=v_run.matrix_version_id
          and grant_row.employee_id=profile.employee_id
          and grant_row.duty_id=v_issue.duty_id and grant_row.active
          and (grant_row.role_id is null or grant_row.role_id=v_issue.role_id)
          and (grant_row.location_id is null or grant_row.location_id=v_shift.location_id)
          and (grant_row.valid_from is null or grant_row.valid_from<=v_shift.shift_date)
          and (grant_row.valid_to is null or grant_row.valid_to>=v_shift.shift_date)) duty_ok,
      exists(select 1 from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and tstzrange(assignment.starts_at,assignment.ends_at,'[)')
            && tstzrange(v_shift.starts_at,v_shift.ends_at,'[)')) overlap,
      exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=profile.employee_id
          and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
          and constraint_row.time_range
            && tstzrange(v_shift.starts_at,v_shift.ends_at,'[)')) blocked_time,
      exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=profile.employee_id
          and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind='AVAILABLE_WINDOW'
          and constraint_row.time_range && tstzrange(
            v_shift.shift_date::timestamp at time zone v_timezone,
            (v_shift.shift_date+1)::timestamp at time zone v_timezone,'[)')) has_day_window,
      exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=profile.employee_id
          and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind='AVAILABLE_WINDOW'
          and lower(constraint_row.time_range)<=v_shift.starts_at
          and upper(constraint_row.time_range)>=v_shift.ends_at) covers_window,
      coalesce((select sum(extract(epoch from
        (assignment.ends_at-assignment.starts_at))/60)::integer
        from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and assignment.shift_date>=v_run.month
          and assignment.shift_date<(v_run.month+interval '1 month')::date),0)
        monthly_minutes,
      coalesce((select sum(extract(epoch from
        (assignment.ends_at-assignment.starts_at))/60)::integer
        from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and assignment.shift_date>=date_trunc('week',v_shift.shift_date)::date
          and assignment.shift_date<date_trunc('week',v_shift.shift_date)::date+7),0)
        weekly_minutes,
      (select max(assignment.ends_at) from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and assignment.ends_at<=v_shift.starts_at) previous_end,
      (select min(assignment.starts_at) from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and assignment.starts_at>=v_shift.ends_at) next_start,
      coalesce((select min(day_offset.value)-1
        from generate_series(1,31) day_offset(value)
        where not exists(select 1 from scheduled assignment
          where assignment.employee_id=profile.employee_id
            and assignment.shift_date=v_shift.shift_date-day_offset.value)),31)
        consecutive_before,
      coalesce((select min(day_offset.value)-1
        from generate_series(1,31) day_offset(value)
        where not exists(select 1 from scheduled assignment
          where assignment.employee_id=profile.employee_id
            and assignment.shift_date=v_shift.shift_date+day_offset.value)),31)
        consecutive_after,
      coalesce(solver_private.alpha16_preference_level_v2(
        profile.employee_id,v_run.matrix_version_id,v_run.month,v_shift_period
      ),'NEUTRAL') preference_level
    from profiles profile
  ), classified as (
    select candidate.employee_id,array_remove(array[
      case when candidate.employment_start is not null
        and candidate.employment_start>v_shift.shift_date
        or candidate.employment_end is not null
        and candidate.employment_end<v_shift.shift_date then 'OUTSIDE_EMPLOYMENT' end,
      case when not candidate.role_ok then 'ROLE_REQUIRED' end,
      case when not candidate.location_ok then 'LOCATION_NOT_ALLOWED' end,
      case when not candidate.duty_ok then 'DUTY_REQUIRED' end,
      case when candidate.no_weekends and extract(isodow from v_shift.shift_date) in (6,7)
        then 'WEEKEND_BLOCKED' end,
      case when candidate.only_morning and v_shift_period<>'MORNING'
        or candidate.only_evening and v_shift_period<>'EVENING'
        or candidate.preference_level='BLOCKED' then 'MANAGER_SHIFT_BLOCK' end,
      case when candidate.blocked_time then 'DECLARED_UNAVAILABLE' end,
      case when candidate.has_day_window and not candidate.covers_window
        then 'OUTSIDE_AVAILABILITY_WINDOW' end,
      case when not candidate.has_day_window
        and (candidate.contract_type in ('ZLECENIE','B2B') or not v_default_missing)
        then 'MISSING_AVAILABILITY' end,
      case when candidate.overlap then 'SHIFT_OVERLAP' end,
      case when candidate.previous_end is not null and extract(epoch from
        (v_shift.starts_at-candidate.previous_end))/60<candidate.rest_minutes
        then 'REST_AFTER_PREVIOUS_SHIFT' end,
      case when candidate.next_start is not null and extract(epoch from
        (candidate.next_start-v_shift.ends_at))/60<candidate.rest_minutes
        then 'REST_BEFORE_NEXT_SHIFT' end,
      case when (candidate.contract_type not in ('ZLECENIE','B2B')
          or candidate.work_time_policy='CUSTOM')
        and candidate.monthly_minutes
          +extract(epoch from (v_shift.ends_at-v_shift.starts_at))/60
          >candidate.maximum_monthly_minutes then 'MONTHLY_LIMIT' end,
      case when (candidate.contract_type not in ('ZLECENIE','B2B')
          or candidate.work_time_policy='CUSTOM')
        and candidate.weekly_minutes
          +extract(epoch from (v_shift.ends_at-v_shift.starts_at))/60
          >candidate.maximum_weekly_minutes then 'WEEKLY_LIMIT' end,
      case when (candidate.contract_type not in ('ZLECENIE','B2B')
          or candidate.work_time_policy='CUSTOM')
        and candidate.consecutive_before+1+candidate.consecutive_after
          >candidate.maximum_consecutive_days then 'MAX_CONSECUTIVE_DAYS' end
    ]::text[],null) reasons
    from evaluated candidate
  )
  select jsonb_build_object(
    'considered',count(*),
    'eligible',count(*) filter(where cardinality(candidate.reasons)=0),
    'blocked',count(*) filter(where cardinality(candidate.reasons)>0),
    'reasons',coalesce((select jsonb_agg(jsonb_build_object(
      'code',reason_count.reason,'count',reason_count.amount
    ) order by reason_count.amount desc,reason_count.reason)
      from (select reason,count(*) amount
        from classified item
        cross join lateral unnest(item.reasons) reason
        group by reason) reason_count),'[]'::jsonb)
  ) into v_summary
  from classified candidate;

  return jsonb_build_object(
    'variantId',p_variant_id,
    'issueId',p_issue_id,
    'shift',jsonb_build_object(
      'date',v_shift.shift_date,'startsAt',v_shift.starts_at,
      'endsAt',v_shift.ends_at,'shiftPeriod',v_shift_period
    ),
    'summary',v_summary
  );
end;
$$;

revoke all on function public.optimizer_variant_issue_diagnostics_uat_v2(
  uuid,bigint
) from public,anon,authenticated;
grant execute on function public.optimizer_variant_issue_diagnostics_uat_v2(
  uuid,bigint
) to authenticated;

create or replace function public.employee_time_constraints_self_v2(
  p_month date
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_month date:=date_trunc('month',p_month)::date;
  v_employee_id uuid;
  v_timezone text;
  v_period_start timestamptz;
  v_period_end timestamptz;
  v_constraints jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  select employee.id into v_employee_id
  from public.employees employee
  where employee.auth_user_id=auth.uid() and employee.active
    and employee.archived_at is null
  order by employee.id limit 1;
  if v_employee_id is null then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  select nullif(matrix.settings->>'timezone','') into v_timezone
  from public.matrix_versions matrix
  where matrix.status in ('ACTIVE','ARCHIVED') and matrix.schema_version>=2
    and matrix.effective_from<=v_month
    and coalesce(matrix.content_hash,'') ~ '^[0-9a-f]{64}$'
    and coalesce(matrix.workforce_hash,'') ~ '^[0-9a-f]{64}$'
  order by matrix.effective_from desc,matrix.version desc limit 1;
  if v_timezone is null then raise exception 'MATRIX_V2_FOR_MONTH_NOT_FOUND'; end if;
  v_period_start:=v_month::timestamp at time zone v_timezone;
  v_period_end:=(v_month+interval '1 month')::timestamp at time zone v_timezone;

  with entries as (
    select constraint_row.id,constraint_row.constraint_kind kind,
      lower(constraint_row.time_range) starts_at,
      upper(constraint_row.time_range) ends_at,
      constraint_row.source,
      constraint_row.source='GRAFIK_PRO'
        and constraint_row.editable_by_employee editable,
      constraint_row.note
    from public.employee_time_constraints_v2 constraint_row
    where constraint_row.employee_id=v_employee_id
      and constraint_row.status='ACTIVE'
      and constraint_row.time_range
        && tstzrange(v_period_start,v_period_end,'[)')
    union all
    select preference.id,
      case when preference.preference_type='OTHER'
        then 'PREFER_NOT_TO_WORK' else 'PREFERRED_LOCATION' end,
      preference.valid_from::timestamp at time zone v_timezone,
      (preference.valid_to+1)::timestamp at time zone v_timezone,
      preference.source,
      preference.source='GRAFIK_PRO' and preference.editable_by_employee,
      case when preference.preference_type='OTHER'
        then nullif(preference.preference_value->>'note','')
        else coalesce((select 'Preferowany lokal: '||location.name
          from public.matrix_locations_v2 location
          where location.id=case
            when preference.preference_value->>'locationId'
              ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
            then (preference.preference_value->>'locationId')::uuid
            else null end limit 1),'Preferowany lokal') end
    from public.employee_preferences preference
    where preference.employee_id=v_employee_id
      and preference.status='ACTIVE'
      and preference.valid_from<v_month+interval '1 month'
      and preference.valid_to>=v_month
      and (preference.preference_type='PREFERRED_LOCATION'
        or (preference.preference_type='OTHER'
          and preference.preference_value->>'kind'='DAY_OFF'
          and preference.preference_value->>'strength'='SOFT'))
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',entry.id,'kind',entry.kind,'startsAt',entry.starts_at,
    'endsAt',entry.ends_at,'source',entry.source,
    'editable',entry.editable,'note',entry.note
  ) order by entry.starts_at,entry.ends_at,entry.id),'[]'::jsonb)
  into v_constraints from entries entry;
  return jsonb_build_object(
    'employeeId',v_employee_id,'timezone',v_timezone,
    'constraints',v_constraints
  );
end;
$$;

create or replace function public.employee_availability_entry_revoke_uat_v2(
  p_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_employee_id uuid;
  v_preference public.employee_preferences%rowtype;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select employee.id into v_employee_id
  from public.employees employee
  where employee.auth_user_id=auth.uid() and employee.active
    and employee.archived_at is null
  order by employee.id limit 1;
  if v_employee_id is null then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  select * into v_preference from public.employee_preferences preference
  where preference.id=p_id and preference.employee_id=v_employee_id
    and preference.status='ACTIVE' for update;
  if v_preference.id is not null then
    if v_preference.source<>'GRAFIK_PRO'
      or not v_preference.editable_by_employee then
      raise exception 'PREFERENCE_NOT_EDITABLE';
    end if;
    update public.employee_preferences set status='CANCELLED'
    where id=v_preference.id;
    insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
    values(auth.uid(),'employee_preference',v_preference.id::text,'CANCEL',
      jsonb_build_object('employeeId',v_employee_id,
        'preferenceType',v_preference.preference_type));
    return jsonb_build_object('id',v_preference.id,'status','CANCELLED',
      'entryType','PREFERENCE');
  end if;
  return jsonb_build_object(
    'id',public.employee_time_constraint_revoke_v2(p_id),
    'status','REVOKED','entryType','TIME_CONSTRAINT'
  );
end;
$$;

revoke all on function public.employee_time_constraints_self_v2(date),
  public.employee_availability_entry_revoke_uat_v2(uuid)
  from public,anon,authenticated;
grant execute on function public.employee_time_constraints_self_v2(date),
  public.employee_availability_entry_revoke_uat_v2(uuid)
  to authenticated;

create or replace function public.optimizer_role_composite_candidates_v2(
  p_month date,
  p_scenario_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_month date:=date_trunc('month',p_month)::date;
  v_matrix_version_id uuid;
  v_scenario_name text;
  v_solver_version text;
  v_roles jsonb;
  v_missing_roles jsonb;
  v_variant_ids jsonb;
  v_demanded_count integer;
  v_candidate_count integer;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  if p_scenario_id is null then raise exception 'SCENARIO_REQUIRED'; end if;
  v_solver_version:=solver_private.active_ortools_solver_version_v2();
  select scenario.matrix_version_id,scenario.name
  into v_matrix_version_id,v_scenario_name
  from public.matrix_scenarios_v2 scenario
  join public.matrix_versions matrix
    on matrix.id=scenario.matrix_version_id and matrix.schema_version>=2
  where scenario.id=p_scenario_id and scenario.active;
  if v_matrix_version_id is null then raise exception 'SCENARIO_NOT_FOUND'; end if;

  with demanded as (
    select demand.role_id,sum(demand.required_count)::bigint demand_slot_count
    from solver_private.resolved_demand_v2(
      v_month,v_matrix_version_id,p_scenario_id,null
    ) demand group by demand.role_id
  ), candidates as (
    select demanded.role_id,demanded.demand_slot_count,role.name role_name,
      role.color role_color,role.sort_order,
      candidate.run_id,candidate.variant_id,candidate.publication_name,
      candidate.assignment_count,candidate.unfilled_count,
      candidate.solver_status,candidate.published_at,
      candidate.strategy_id,candidate.strategy_name,candidate.strategy_code
    from demanded
    join public.matrix_roles_v2 role on role.id=demanded.role_id
      and role.matrix_version_id=v_matrix_version_id
    left join lateral (
      select run.id run_id,variant.id variant_id,
        publication.name publication_name,variant.assignment_count,
        variant.unfilled_count,variant.solver_status,publication.published_at,
        strategy.id strategy_id,strategy.name strategy_name,
        strategy.code strategy_code
      from public.published_role_schedules_v2 publication
      join public.plan_variants_v2 variant on variant.id=publication.variant_id
      join public.optimization_runs_v2 run on run.id=variant.run_id
      join public.matrix_strategies_v2 strategy on strategy.id=variant.strategy_id
      where publication.month=v_month and publication.status='PUBLISHED'
        and publication.matrix_version_id=v_matrix_version_id
        and publication.scenario_id=p_scenario_id
        and publication.role_id=demanded.role_id
        and run.request_engine='ORTOOLS_V2'
        and run.solver_version=v_solver_version
        and run.status='READY' and run.scope_type='ROLE'
        and run.scope_role_id=demanded.role_id
        and variant.selected and variant.hard_violations=0
        and variant.status='PUBLISHED'
      order by publication.published_at desc,publication.id desc limit 1
    ) candidate on true
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'role',jsonb_build_object('id',candidate.role_id,
        'name',candidate.role_name,'color',candidate.role_color,
        'sortOrder',candidate.sort_order),
      'demandSlotCount',candidate.demand_slot_count,
      'run',case when candidate.run_id is null then null
        else jsonb_build_object('id',candidate.run_id,'status','READY',
          'finishedAt',candidate.published_at) end,
      'variant',case when candidate.variant_id is null then null
        else jsonb_build_object('id',candidate.variant_id,
          'name',candidate.publication_name,'status','PUBLISHED',
          'assignmentCount',candidate.assignment_count,
          'unfilledCount',candidate.unfilled_count,
          'solverStatus',candidate.solver_status,
          'selectedAt',candidate.published_at,
          'strategy',jsonb_build_object('id',candidate.strategy_id,
            'name',candidate.strategy_name,'code',candidate.strategy_code)) end,
      'ready',candidate.variant_id is not null
    ) order by candidate.sort_order,candidate.role_name),'[]'::jsonb),
    coalesce(jsonb_agg(jsonb_build_object('id',candidate.role_id,
      'name',candidate.role_name) order by candidate.sort_order,candidate.role_name)
      filter(where candidate.variant_id is null),'[]'::jsonb),
    coalesce(jsonb_agg(to_jsonb(candidate.variant_id)
      order by candidate.sort_order,candidate.role_name)
      filter(where candidate.variant_id is not null),'[]'::jsonb),
    count(*)::integer,count(candidate.variant_id)::integer
  into v_roles,v_missing_roles,v_variant_ids,
    v_demanded_count,v_candidate_count
  from candidates candidate;
  return jsonb_build_object(
    'month',v_month,
    'scenario',jsonb_build_object('id',p_scenario_id,'name',v_scenario_name),
    'matrixVersionId',v_matrix_version_id,'roles',v_roles,
    'missingRoles',v_missing_roles,'variantIds',v_variant_ids,
    'demandedRoleCount',v_demanded_count,
    'ready',v_demanded_count>0 and v_candidate_count=v_demanded_count
  );
end;
$$;

revoke all on function public.optimizer_role_composite_candidates_v2(date,uuid)
  from public,anon,authenticated;
grant execute on function public.optimizer_role_composite_candidates_v2(date,uuid)
  to authenticated;

create or replace function public.optimizer_role_publication_overview_uat_v2(
  p_month date
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_month date:=date_trunc('month',p_month)::date;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  with role_rows as (
    select publication.id publication_id,publication.name,
      publication.published_at,role.id role_id,role.name role_name,
      scenario.id scenario_id,scenario.name scenario_name,
      variant.id variant_id,variant.assignment_count,variant.unfilled_count,
      coalesce((variant.metrics->>'OVERTIME_MINUTES')::bigint,0) overtime_minutes,
      coalesce(finance.total_cost_minor,0) total_cost_minor,
      coalesce(finance.currency,'PLN') currency,
      coalesce((select count(distinct assignment.employee_id)
        from public.plan_assignments_v2 assignment
        where assignment.variant_id=variant.id),0)::integer team_size,
      coalesce((select sum(extract(epoch from
        (shift.ends_at-shift.starts_at))/60)::bigint
        from public.plan_assignments_v2 assignment
        join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
        where assignment.variant_id=variant.id),0) scheduled_minutes
    from public.published_role_schedules_v2 publication
    join public.matrix_roles_v2 role on role.id=publication.role_id
    join public.matrix_scenarios_v2 scenario on scenario.id=publication.scenario_id
    join public.plan_variants_v2 variant on variant.id=publication.variant_id
    left join solver_private.plan_variant_finance_v2 finance
      on finance.variant_id=variant.id
    where publication.month=v_month and publication.status='PUBLISHED'
  ), totals as (
    select count(*)::integer published_roles,
      coalesce(sum(assignment_count),0)::bigint assignment_count,
      coalesce(sum(unfilled_count),0)::bigint unfilled_count,
      coalesce(sum(overtime_minutes),0)::bigint overtime_minutes,
      coalesce(sum(total_cost_minor),0)::bigint total_cost_minor,
      coalesce(sum(scheduled_minutes),0)::bigint scheduled_minutes
    from role_rows
  )
  select jsonb_build_object(
    'month',v_month,
    'totals',jsonb_build_object(
      'publishedRoles',totals.published_roles,
      'assignmentCount',totals.assignment_count,
      'unfilledCount',totals.unfilled_count,
      'overtimeMinutes',totals.overtime_minutes,
      'totalCostMinor',totals.total_cost_minor,
      'scheduledMinutes',totals.scheduled_minutes
    ),
    'roles',coalesce((select jsonb_agg(jsonb_build_object(
      'publicationId',row.publication_id,'name',row.name,
      'publishedAt',row.published_at,
      'role',jsonb_build_object('id',row.role_id,'name',row.role_name),
      'scenario',jsonb_build_object('id',row.scenario_id,'name',row.scenario_name),
      'variantId',row.variant_id,'assignmentCount',row.assignment_count,
      'unfilledCount',row.unfilled_count,'overtimeMinutes',row.overtime_minutes,
      'totalCostMinor',row.total_cost_minor,'currency',row.currency,
      'teamSize',row.team_size,'scheduledMinutes',row.scheduled_minutes
    ) order by row.role_name) from role_rows row),'[]'::jsonb)
  ) into v_result from totals;
  return v_result;
end;
$$;

revoke all on function public.optimizer_role_publication_overview_uat_v2(date)
  from public,anon,authenticated;
grant execute on function public.optimizer_role_publication_overview_uat_v2(date)
  to authenticated;

create or replace function solver_private.published_variant_is_frozen_v2(
  p_variant_id uuid
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_variant_id is not null and (
    exists(select 1 from public.published_schedule_variants_v2 link
      where link.variant_id=p_variant_id)
    or exists(select 1 from public.published_role_schedules_v2 publication
      where publication.variant_id=p_variant_id)
  );
$$;

revoke all on function solver_private.published_variant_is_frozen_v2(uuid)
  from public,anon,authenticated;
grant execute on function solver_private.published_variant_is_frozen_v2(uuid)
  to service_role;
