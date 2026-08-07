-- Repair identity matching in the v3 Matrix importer.
-- Apps Script workbooks identify existing and new employees by e-mail when
-- no GP-### number is supplied. Every post-import phase must use the same
-- identity rule as preview/apply; otherwise a valid atomic import rolls back.

alter table public.matrix_employee_duties_v2
  add column if not exists updated_at timestamptz not null default now();

create or replace function public.matrix_v2_import_apply_uat_v3(
  p_payload jsonb,
  p_mode text default 'UPDATE'
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_mode text:=upper(trim(coalesce(p_mode,'UPDATE')));
  v_preview jsonb;
  v_normalized jsonb;
  v_result jsonb;
  v_matrix uuid;
  v_apply_payload jsonb;
  v_profile public.matrix_employee_profiles_v2%rowtype;
  v_row jsonb;
  v_employee uuid;
  v_existing_rate public.employee_pay_rates_v2%rowtype;
  v_rate_start date;
  v_rate_end date;
  v_employment_end date;
  v_next_rate_start date;
  v_rate_amount bigint;
  v_effective date;
  v_currency text;
  v_archived integer:=0;
  v_location uuid;
  v_location_grant jsonb;
  v_profile_active boolean;
  v_desired_active boolean;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  v_preview:=public.matrix_v2_import_preview_uat_v3(p_payload,v_mode);
  if not (v_preview->>'valid')::boolean then raise exception 'MATRIX_IMPORT_HAS_ERRORS'; end if;
  v_matrix:=(v_preview->>'matrixVersionId')::uuid;
  v_normalized:=solver_private.matrix_v2_import_normalize_uat_v3(p_payload,v_matrix);
  -- Rates are saved below with the later of the workbook month (when present),
  -- the Matrix effective date and the employee's start date.  The older
  -- importer used only the Matrix date and could create a rate before
  -- employment or in a technical draft month unrelated to the schedule.
  select coalesce(jsonb_agg(
    (source.value-'baseRate')||jsonb_build_object('baseRate','')
    order by source.ordinality
  ),'[]'::jsonb) into v_apply_payload
  from jsonb_array_elements(coalesce(v_normalized->'employees','[]'::jsonb))
    with ordinality source(value,ordinality);
  v_apply_payload:=jsonb_set(v_normalized,'{employees}',v_apply_payload,true);
  v_result:=public.matrix_v2_import_apply_uat_v2(v_apply_payload);
  select matrix.effective_from,upper(matrix.settings->>'currency')
  into v_effective,v_currency
  from public.matrix_versions matrix where matrix.id=v_matrix;

  -- The v2 importer predates the Apps Script columns that distinguish normal
  -- and overtime location access and therefore deliberately cannot persist
  -- them.  Apply those explicit grants, employee shift limits and active state
  -- only when the workbook actually contains the corresponding fields.
  for v_row in select value from jsonb_array_elements(
    coalesce(v_normalized->'employees','[]'::jsonb)
  ) loop
    select profile.employee_id,profile.active into v_employee,v_profile_active
    from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=v_matrix and (
      (nullif(trim(v_row->>'employeeNo'),'') is not null
        and upper(profile.employee_no)=upper(trim(v_row->>'employeeNo')))
      or (nullif(lower(trim(v_row->>'email')),'') is not null
        and lower(profile.email)=lower(trim(v_row->>'email')))
    ) order by profile.employee_id limit 1;
    if v_employee is null then
      raise exception 'IMPORTED_EMPLOYEE_NOT_FOUND|%|%',
        coalesce(v_row->>'employeeNo',''),coalesce(v_row->>'email','');
    end if;

    if v_row ? 'onlyMorning' or v_row ? 'onlyEvening' or v_row ? 'noWeekends' then
      update public.matrix_employee_profiles_v2 profile set
        only_morning=case when v_row ? 'onlyMorning'
          then (v_row->>'onlyMorning')::boolean else profile.only_morning end,
        only_evening=case when v_row ? 'onlyEvening'
          then (v_row->>'onlyEvening')::boolean else profile.only_evening end,
        no_weekends=case when v_row ? 'noWeekends'
          then (v_row->>'noWeekends')::boolean else profile.no_weekends end,
        updated_by=auth.uid(),updated_at=now()
      where profile.matrix_version_id=v_matrix and profile.employee_id=v_employee;
    end if;

    if v_row ? 'locationGrants' then
      update public.matrix_employee_locations_v2 location_grant set
        standard_allowed=false,overtime_allowed=false,home_location=false,active=false
      where location_grant.matrix_version_id=v_matrix
        and location_grant.employee_id=v_employee;
      for v_location_grant in select value from jsonb_array_elements(v_row->'locationGrants')
      loop
        select location_row.id into v_location
        from public.matrix_locations_v2 location_row
        where location_row.matrix_version_id=v_matrix and location_row.active
          and upper(location_row.code)=upper(v_location_grant->>'code');
        if v_location is null then raise exception 'LOCATION_NOT_IN_MATRIX_V2'; end if;
        insert into public.matrix_employee_locations_v2(
          matrix_version_id,employee_id,location_id,standard_allowed,
          overtime_allowed,home_location,active
        ) values(
          v_matrix,v_employee,v_location,
          coalesce((v_location_grant->>'standardAllowed')::boolean,false),
          coalesce((v_location_grant->>'overtimeAllowed')::boolean,false),
          coalesce((v_location_grant->>'homeLocation')::boolean,false),true
        ) on conflict(matrix_version_id,employee_id,location_id) do update set
          standard_allowed=excluded.standard_allowed,
          overtime_allowed=excluded.overtime_allowed,
          home_location=excluded.home_location,active=true;
      end loop;
    end if;

    -- When the workbook carries a duty dictionary, its employee columns are a
    -- complete statement for those duties: TAK activates the capability and a
    -- blank/NIE cell withdraws it.  Without this step an unchecked Excel cell
    -- could never remove an obsolete capability.
    if v_row ? 'dutyCodes' and jsonb_typeof(v_row->'dutyCodes')='array' then
      update public.matrix_employee_duties_v2 capability set
        active=false,updated_at=now()
      from public.matrix_duties_v2 duty
      where capability.matrix_version_id=v_matrix
        and capability.employee_id=v_employee
        and capability.duty_id=duty.id
        and duty.matrix_version_id=v_matrix
        and upper(duty.code) in (
          select upper(code.value)
          from jsonb_array_elements_text(v_row->'dutyCodes') code
        )
        and not exists(
          select 1
          from jsonb_array_elements(coalesce(v_normalized->'employeeDuties','[]'::jsonb)) imported
          where (
              (nullif(trim(v_row->>'employeeNo'),'') is not null
                and upper(coalesce(imported.value->>'employeeNo',''))=upper(trim(v_row->>'employeeNo')))
              or (nullif(lower(trim(v_row->>'email')),'') is not null
                and lower(coalesce(imported.value->>'email',''))=lower(trim(v_row->>'email')))
            )
            and upper(coalesce(imported.value->>'dutyCode',''))=upper(duty.code)
            and coalesce((imported.value->>'active')::boolean,true)
        );
    end if;

    if v_row ? 'active' then
      v_desired_active:=(v_row->>'active')::boolean;
      if v_desired_active is distinct from v_profile_active then
        perform public.matrix_v2_employee_archive_v2(
          v_employee,
          case when v_desired_active then null
            else 'Archiwizacja zgodna z polem AKTYWNY w imporcie Matrixa.' end,
          not v_desired_active
        );
      end if;
    end if;
  end loop;

  for v_row in select value from jsonb_array_elements(
    coalesce(v_normalized->'employees','[]'::jsonb)
  ) where nullif(value->>'baseRate','') is not null
  loop
    select profile.employee_id,greatest(
      coalesce(nullif(v_row->>'preferenceMonth','')::date,v_effective),
      coalesce(profile.employment_start,
        coalesce(nullif(v_row->>'preferenceMonth','')::date,v_effective))
    ),profile.employment_end into v_employee,v_rate_start,v_employment_end
    from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=v_matrix and (
      (nullif(trim(v_row->>'employeeNo'),'') is not null
        and upper(profile.employee_no)=upper(trim(v_row->>'employeeNo')))
      or (nullif(lower(trim(v_row->>'email')),'') is not null
        and lower(profile.email)=lower(trim(v_row->>'email')))
    ) order by profile.employee_id limit 1;
    if v_employee is null then
      raise exception 'IMPORTED_EMPLOYEE_NOT_FOUND|%|%',
        coalesce(v_row->>'employeeNo',''),coalesce(v_row->>'email','');
    end if;
    select min(rate.valid_from) into v_next_rate_start
    from public.employee_pay_rates_v2 rate
    where rate.employee_id=v_employee and rate.active
      and rate.valid_from>v_rate_start;
    v_rate_end:=case
      when v_next_rate_start is null then v_employment_end
      when v_employment_end is null then v_next_rate_start-1
      else least(v_employment_end,v_next_rate_start-1)
    end;
    select * into v_existing_rate
    from public.employee_pay_rates_v2 rate
    where rate.employee_id=v_employee and rate.active
      and rate.valid_from<=v_rate_start
      and (rate.valid_to is null or rate.valid_to>=v_rate_start)
    order by rate.valid_from desc,rate.id limit 1;
    v_rate_amount:=round(replace(v_row->>'baseRate',',','.')::numeric*100)::bigint;
    -- Re-importing an unchanged workbook is idempotent.  Do not split a rate
    -- period merely because the same amount and contract were supplied again.
    if v_existing_rate.id is not null
      and v_existing_rate.base_rate_minor=v_rate_amount
      and upper(coalesce(v_existing_rate.currency,''))=upper(coalesce(v_currency,''))
      and upper(coalesce(v_existing_rate.contract_type,''))=
        upper(coalesce(nullif(v_row->>'contractType',''),'')) then
      continue;
    end if;
    if v_existing_rate.id is not null and v_existing_rate.valid_from<v_rate_start then
      perform public.employee_pay_rate_save_v2(
        v_existing_rate.id,v_employee,v_existing_rate.valid_from,v_rate_start-1,
        v_existing_rate.base_rate_minor,v_existing_rate.currency,
        v_existing_rate.contract_type,v_existing_rate.active
      );
      v_existing_rate.id:=null;
    end if;
    perform public.employee_pay_rate_save_v2(
      v_existing_rate.id,v_employee,v_rate_start,v_rate_end,v_rate_amount,
      v_currency,nullif(v_row->>'contractType',''),true
    );
  end loop;

  if v_mode='REPLACE' then
    for v_profile in
      select profile.* from public.matrix_employee_profiles_v2 profile
      where profile.matrix_version_id=v_matrix and profile.active
        and not exists(
          select 1 from jsonb_array_elements(coalesce(v_normalized->'employees','[]'::jsonb)) imported
          where (nullif(trim(imported.value->>'employeeNo'),'') is not null
              and upper(profile.employee_no)=upper(trim(imported.value->>'employeeNo')))
            or (nullif(lower(trim(imported.value->>'email')),'') is not null
              and lower(profile.email)=lower(trim(imported.value->>'email')))
        )
      for update
    loop
      perform public.matrix_v2_employee_archive_v2(
        v_profile.employee_id,
        'Archiwizacja automatyczna: pracownik nie wystąpił w imporcie zastępującym bazę.',
        true
      );
      v_archived:=v_archived+1;
    end loop;
  end if;
  return v_result||jsonb_build_object('mode',v_mode,'archivedEmployees',v_archived);
end;
$$;

revoke all on function public.matrix_v2_import_apply_uat_v3(jsonb,text)
  from public,anon,authenticated;
grant execute on function public.matrix_v2_import_apply_uat_v3(jsonb,text)
  to authenticated;
