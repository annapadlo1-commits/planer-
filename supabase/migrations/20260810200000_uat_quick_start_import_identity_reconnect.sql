-- UAT critical repair: first-time setup and workforce replacement must work
-- after the draft workforce was reset. Historical employee/auth identities are
-- preserved and reconnected by e-mail; the quick-start flow defers finance to
-- a second, generated workbook after GP-### numbers have been assigned.

create or replace function solver_private.matrix_v2_import_normalize_uat_v3(
  p_payload jsonb,
  p_matrix_version_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_employees jsonb;
  v_employee_duties jsonb;
begin
  select coalesce(jsonb_agg(
    source.value || jsonb_strip_nulls(jsonb_build_object(
      'employeeNo',coalesce(nullif(trim(source.value->>'employeeNo'),''),match.employee_no),
      'contractType',coalesce(nullif(trim(source.value->>'contractType'),''),match.contract_type),
      'employmentFraction',case
        when nullif(trim(source.value->>'employmentFraction'),'') is not null
          then source.value->>'employmentFraction'
        when match.employment_fraction is not null then match.employment_fraction::text
        when nullif(trim(source.value->>'contractType'),'') is not null
          or match.contract_type is not null then '1'
        else null end,
      'workTimePolicy',case
        when nullif(trim(source.value->>'workTimePolicy'),'') is not null
          then source.value->>'workTimePolicy'
        when match.work_time_policy is not null then match.work_time_policy
        when nullif(trim(source.value->>'contractType'),'') is not null
          or match.contract_type is not null then 'CONTRACT_DEFAULT'
        else null end,
      'nominalHours',case
        when nullif(trim(source.value->>'nominalHours'),'') is not null
          then source.value->>'nominalHours'
        when solver_private.normalize_contract_type_v2(coalesce(
          nullif(source.value->>'contractType',''),match.contract_type
        )) in ('ZLECENIE','B2B')
          and upper(coalesce(nullif(source.value->>'workTimePolicy',''),
            match.work_time_policy,'CONTRACT_DEFAULT'))<>'CUSTOM' then '0'
        when match.nominal_monthly_minutes is not null
          then (match.nominal_monthly_minutes::numeric/60)::text
        else null end,
      'maximumMonthlyHours',case
        when nullif(trim(source.value->>'maximumMonthlyHours'),'') is not null
          then source.value->>'maximumMonthlyHours'
        when solver_private.normalize_contract_type_v2(coalesce(
          nullif(source.value->>'contractType',''),match.contract_type
        )) in ('ZLECENIE','B2B')
          and upper(coalesce(nullif(source.value->>'workTimePolicy',''),
            match.work_time_policy,'CONTRACT_DEFAULT'))<>'CUSTOM' then '0'
        when match.maximum_monthly_minutes is not null
          then (match.maximum_monthly_minutes::numeric/60)::text
        else null end,
      'maximumWeeklyHours',case
        when nullif(trim(source.value->>'maximumWeeklyHours'),'') is not null
          then source.value->>'maximumWeeklyHours'
        when solver_private.normalize_contract_type_v2(coalesce(
          nullif(source.value->>'contractType',''),match.contract_type
        )) in ('ZLECENIE','B2B')
          and upper(coalesce(nullif(source.value->>'workTimePolicy',''),
            match.work_time_policy,'CONTRACT_DEFAULT'))<>'CUSTOM' then '0'
        when match.maximum_weekly_minutes is not null
          then (match.maximum_weekly_minutes::numeric/60)::text
        else null end,
      'maximumConsecutiveDays',case
        when nullif(trim(source.value->>'maximumConsecutiveDays'),'') is not null
          then source.value->>'maximumConsecutiveDays'
        when solver_private.normalize_contract_type_v2(coalesce(
          nullif(source.value->>'contractType',''),match.contract_type
        )) in ('ZLECENIE','B2B')
          and upper(coalesce(nullif(source.value->>'workTimePolicy',''),
            match.work_time_policy,'CONTRACT_DEFAULT'))<>'CUSTOM' then '31'
        when match.maximum_consecutive_days is not null
          then match.maximum_consecutive_days::text
        else null end
    )) order by source.ordinality
  ),'[]'::jsonb) into v_employees
  from jsonb_array_elements(coalesce(p_payload->'employees','[]'::jsonb))
    with ordinality source(value,ordinality)
  left join lateral (
    select
      coalesce(profile.employee_no,employee.employee_no) employee_no,
      coalesce(profile.nominal_monthly_minutes,employee.monthly_nominal_minutes) nominal_monthly_minutes,
      coalesce(profile.maximum_monthly_minutes,employee.max_monthly_minutes) maximum_monthly_minutes,
      coalesce(profile.maximum_weekly_minutes,employee.max_weekly_minutes) maximum_weekly_minutes,
      coalesce(profile.maximum_consecutive_days,employee.max_consecutive_days) maximum_consecutive_days,
      profile.work_time_policy,
      hr.contract_type,
      hr.employment_fraction
    from public.employees employee
    left join public.matrix_employee_profiles_v2 profile
      on profile.employee_id=employee.id
      and profile.matrix_version_id=p_matrix_version_id
    left join public.employee_hr_profiles hr on hr.employee_id=employee.id
    where
      (nullif(trim(source.value->>'employeeNo'),'') is not null and (
        upper(coalesce(profile.employee_no,''))=upper(trim(source.value->>'employeeNo'))
        or upper(coalesce(employee.employee_no,''))=upper(trim(source.value->>'employeeNo'))
      ))
      or (nullif(lower(trim(source.value->>'email')),'') is not null and (
        lower(coalesce(profile.email,''))=lower(trim(source.value->>'email'))
        or lower(coalesce(employee.email,''))=lower(trim(source.value->>'email'))
      ))
    order by (profile.employee_id is not null) desc,employee.active desc,
      case when employee.employee_no~*'^GP-[0-9]+$'
        then substring(employee.employee_no from '[0-9]+$')::integer
        else 2147483647 end,
      employee.created_at,employee.id
    limit 1
  ) match on true;

  select coalesce(jsonb_agg(
    source.value || case when match.employee_no is null then '{}'::jsonb
      else jsonb_build_object('employeeNo',match.employee_no) end
    order by source.ordinality
  ),'[]'::jsonb) into v_employee_duties
  from jsonb_array_elements(coalesce(p_payload->'employeeDuties','[]'::jsonb))
    with ordinality source(value,ordinality)
  left join lateral (
    select coalesce(profile.employee_no,employee.employee_no) employee_no
    from public.employees employee
    left join public.matrix_employee_profiles_v2 profile
      on profile.employee_id=employee.id
      and profile.matrix_version_id=p_matrix_version_id
    where
      (nullif(trim(source.value->>'employeeNo'),'') is not null and (
        upper(coalesce(profile.employee_no,''))=upper(trim(source.value->>'employeeNo'))
        or upper(coalesce(employee.employee_no,''))=upper(trim(source.value->>'employeeNo'))
      ))
      or (nullif(lower(trim(source.value->>'email')),'') is not null and (
        lower(coalesce(profile.email,''))=lower(trim(source.value->>'email'))
        or lower(coalesce(employee.email,''))=lower(trim(source.value->>'email'))
      ))
    order by (profile.employee_id is not null) desc,employee.active desc,
      case when employee.employee_no~*'^GP-[0-9]+$'
        then substring(employee.employee_no from '[0-9]+$')::integer
        else 2147483647 end,
      employee.created_at,employee.id
    limit 1
  ) match on true;

  return jsonb_set(
    jsonb_set(p_payload,'{employees}',v_employees,true),
    '{employeeDuties}',v_employee_duties,true
  );
end;
$$;

create or replace function solver_private.matrix_v2_full_import_configuration_uat_v2(
  p_configuration jsonb
) returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_set(
    coalesce(p_configuration,'{}'::jsonb),
    '{employeeDuties}',
    coalesce((
      select jsonb_agg(inline.value order by inline.ordinality)
      from jsonb_array_elements(coalesce(p_configuration->'employeeDuties','[]'::jsonb))
        with ordinality inline(value,ordinality)
      where not exists (
        select 1
        from jsonb_array_elements(coalesce(p_configuration->'employeeCapabilities','[]'::jsonb)) detailed(value)
        where nullif(trim(detailed.value->>'employeeNo'),'') is not null
          and nullif(trim(inline.value->>'employeeNo'),'') is not null
          and upper(detailed.value->>'employeeNo')=upper(inline.value->>'employeeNo')
          and upper(coalesce(detailed.value->>'dutyCode',''))=upper(coalesce(inline.value->>'dutyCode',''))
      )
    ),'[]'::jsonb),
    true
  )
$$;

create or replace function solver_private.matrix_v2_team_configuration_uat_v1(
  p_configuration jsonb
) returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_set(
    jsonb_set(
      jsonb_set(
        jsonb_set(
          solver_private.matrix_v2_full_import_configuration_uat_v2(p_configuration),
          '{employeeRoles}',coalesce((select jsonb_agg(value)
            from jsonb_array_elements(coalesce(p_configuration->'employeeRoles','[]'::jsonb))
            where nullif(trim(value->>'employeeNo'),'') is not null),'[]'::jsonb),true
        ),
        '{employeeLocationsDetailed}',coalesce((select jsonb_agg(value)
          from jsonb_array_elements(coalesce(p_configuration->'employeeLocationsDetailed','[]'::jsonb))
          where nullif(trim(value->>'employeeNo'),'') is not null),'[]'::jsonb),true
      ),
      '{employeeCapabilities}',coalesce((select jsonb_agg(value)
        from jsonb_array_elements(coalesce(p_configuration->'employeeCapabilities','[]'::jsonb))
        where nullif(trim(value->>'employeeNo'),'') is not null),'[]'::jsonb),true
    ),
    '{timeConstraints}',coalesce((select jsonb_agg(value)
      from jsonb_array_elements(coalesce(p_configuration->'timeConstraints','[]'::jsonb))
      where nullif(trim(value->>'employeeNo'),'') is not null),'[]'::jsonb),true
  )
$$;

create or replace function public.matrix_v2_team_import_preview_uat_v1(
  p_configuration jsonb,
  p_mode text default 'UPDATE'
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_configuration jsonb:=solver_private.matrix_v2_team_configuration_uat_v1(coalesce(p_configuration,'{}'::jsonb));
  v_configuration_without_rates jsonb;
  v_preview jsonb;
  v_result jsonb;
  v_extra integer;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
  if jsonb_typeof(p_configuration)<>'object' then raise exception 'INVALID_TEAM_IMPORT_PAYLOAD'; end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  v_configuration_without_rates:=jsonb_set(v_configuration,'{employees}',coalesce((
    select jsonb_agg(value-'baseRate')
    from jsonb_array_elements(coalesce(v_configuration->'employees','[]'::jsonb))
  ),'[]'::jsonb),true);

  begin
    perform solver_private.matrix_v2_full_import_phase_uat_v1(v_configuration,'PRE');
    v_preview:=public.matrix_v2_import_preview_uat_v5(v_configuration_without_rates,p_mode);
    if coalesce((v_preview->>'valid')::boolean,false) then
      perform public.matrix_v2_import_apply_uat_v5(v_configuration_without_rates,p_mode);
      perform solver_private.matrix_v2_full_import_phase_uat_v1(v_configuration,'POST');
    end if;
    v_preview:=jsonb_set(v_preview,'{warnings}',coalesce((
      select jsonb_agg(case when warning.value->>'code'='PAY_RATE_MISSING'
        then jsonb_set(warning.value,'{message}',to_jsonb('Stawkę uzupełnisz w kroku 2 po nadaniu numeru GP-###; do tego czasu publikacja konfiguracji może być zablokowana.'::text),true)
        else warning.value end order by warning.ordinality)
      from jsonb_array_elements(coalesce(v_preview->'warnings','[]'::jsonb))
        with ordinality warning(value,ordinality)
    ),'[]'::jsonb),true);
    v_extra:=jsonb_array_length(coalesce(v_configuration->'roles','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'locations','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'duties','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'scenarios','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'strategies','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'strategyObjectives','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'scenarioStrategies','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'employeeRoles','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'employeeLocationsDetailed','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'employeeCapabilities','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'timeConstraints','[]'::jsonb));
    v_result:=jsonb_build_object(
      'valid',coalesce((v_preview->>'valid')::boolean,false),
      'errors',coalesce(v_preview->'errors','[]'::jsonb),
      'warnings',coalesce(v_preview->'warnings','[]'::jsonb),
      'configuration',v_preview,
      'finance',jsonb_build_object('valid',true,'errors','[]'::jsonb,'warnings','[]'::jsonb,
        'normalizedRows','[]'::jsonb,'summary',jsonb_build_object('rows',0,'employees',0,'create',0,'update',0,'deactivate',0,'unchanged',0)),
      'summary',coalesce(v_preview->'summary','{}'::jsonb)||jsonb_build_object(
        'total',coalesce((v_preview#>>'{summary,total}')::integer,0)+v_extra,
        'financeRows',0,'financeEmployees',0,'financeChanges',0,
        'roles',jsonb_array_length(coalesce(v_configuration->'roles','[]'::jsonb)),
        'locations',jsonb_array_length(coalesce(v_configuration->'locations','[]'::jsonb)),
        'duties',jsonb_array_length(coalesce(v_configuration->'duties','[]'::jsonb)),
        'scenarios',jsonb_array_length(coalesce(v_configuration->'scenarios','[]'::jsonb)),
        'strategies',jsonb_array_length(coalesce(v_configuration->'strategies','[]'::jsonb)),
        'timeConstraints',jsonb_array_length(coalesce(v_configuration->'timeConstraints','[]'::jsonb))
      )
    );
    raise sqlstate 'GPQ01' using message='TEAM_IMPORT_DRY_RUN_COMPLETE';
  exception when sqlstate 'GPQ01' then
    return v_result;
  end;
end;
$$;

create or replace function public.matrix_v2_team_import_apply_uat_v1(
  p_configuration jsonb,
  p_mode text default 'UPDATE'
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_configuration jsonb:=solver_private.matrix_v2_team_configuration_uat_v1(coalesce(p_configuration,'{}'::jsonb));
  v_configuration_without_rates jsonb;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
  if jsonb_typeof(p_configuration)<>'object' then raise exception 'INVALID_TEAM_IMPORT_PAYLOAD'; end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  v_configuration_without_rates:=jsonb_set(v_configuration,'{employees}',coalesce((
    select jsonb_agg(value-'baseRate')
    from jsonb_array_elements(coalesce(v_configuration->'employees','[]'::jsonb))
  ),'[]'::jsonb),true);
  perform solver_private.matrix_v2_full_import_phase_uat_v1(v_configuration,'PRE');
  v_result:=public.matrix_v2_import_apply_uat_v5(v_configuration_without_rates,p_mode);
  perform solver_private.matrix_v2_full_import_phase_uat_v1(v_configuration,'POST');
  return v_result||jsonb_build_object('atomic',true,'scope','TEAM_AND_STRUCTURE','financeDeferred',true);
exception when others then
  if sqlerrm like 'MATRIX_%' or sqlerrm like 'INVALID_%'
    or sqlerrm like 'EMPLOYEE_%' or sqlerrm like 'IMPORTED_%'
    or sqlerrm like 'FULL_IMPORT_%' then raise; end if;
  raise exception 'TEAM_IMPORT_APPLY_FAILED|%|%|%',gen_random_uuid(),sqlstate,sqlerrm;
end;
$$;

revoke all on function solver_private.matrix_v2_import_normalize_uat_v3(jsonb,uuid),
  solver_private.matrix_v2_full_import_configuration_uat_v2(jsonb),
  solver_private.matrix_v2_team_configuration_uat_v1(jsonb),
  public.matrix_v2_team_import_preview_uat_v1(jsonb,text),
  public.matrix_v2_team_import_apply_uat_v1(jsonb,text)
  from public,anon,authenticated;

grant execute on function public.matrix_v2_team_import_preview_uat_v1(jsonb,text),
  public.matrix_v2_team_import_apply_uat_v1(jsonb,text)
  to authenticated;

comment on function public.matrix_v2_team_import_preview_uat_v1(jsonb,text) is
  'UAT owner/admin dry-run for two-step onboarding: structure and workforce first, finance after assigned GP numbers.';
comment on function public.matrix_v2_team_import_apply_uat_v1(jsonb,text) is
  'UAT owner/admin atomic onboarding of structure and workforce. Existing global identities are reconnected by e-mail.';

notify pgrst,'reload schema';
