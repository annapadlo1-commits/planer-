-- UAT critical follow-up: the reset intentionally preserves global identities,
-- but the Matrix importer validates employee numbers inside the current draft.
-- Seed a draft profile for a preserved identity before preview/apply, then let
-- the existing importer validate and update it normally.

create or replace function solver_private.matrix_v2_reconnect_preserved_profiles_uat_v1(
  p_configuration jsonb
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_matrix uuid;
  v_row jsonb;
  v_employee public.employees%rowtype;
  v_prior public.matrix_employee_profiles_v2%rowtype;
  v_nominal integer;
  v_maximum_monthly integer;
  v_inserted integer:=0;
begin
  select matrix.id into v_matrix
  from public.matrix_versions matrix
  where matrix.status='DRAFT' and matrix.schema_version>=2
  order by matrix.version desc
  limit 1;
  if v_matrix is null then raise exception 'NO_MATRIX_V2_DRAFT'; end if;

  for v_row in
    select value
    from jsonb_array_elements(coalesce(p_configuration->'employees','[]'::jsonb))
  loop
    v_employee.id:=null;
    select employee.* into v_employee
    from public.employees employee
    where
      (nullif(trim(v_row->>'employeeNo'),'') is not null
        and upper(employee.employee_no)=upper(trim(v_row->>'employeeNo')))
      or (nullif(lower(trim(v_row->>'email')),'') is not null
        and lower(coalesce(employee.email,''))=lower(trim(v_row->>'email')))
    order by employee.active desc,employee.created_at,employee.id
    limit 1;
    if v_employee.id is null or exists(
      select 1 from public.matrix_employee_profiles_v2 profile
      where profile.matrix_version_id=v_matrix and profile.employee_id=v_employee.id
    ) then
      continue;
    end if;

    v_prior.id:=null;
    select profile.* into v_prior
    from public.matrix_employee_profiles_v2 profile
    join public.matrix_versions matrix on matrix.id=profile.matrix_version_id
    where profile.employee_id=v_employee.id
    order by matrix.version desc,profile.updated_at desc
    limit 1;

    v_nominal:=coalesce(v_prior.nominal_monthly_minutes,v_employee.monthly_nominal_minutes,0);
    v_maximum_monthly:=greatest(
      v_nominal,
      coalesce(v_prior.maximum_monthly_minutes,v_employee.max_monthly_minutes,v_nominal)
    );

    insert into public.matrix_employee_profiles_v2(
      matrix_version_id,employee_id,employee_no,first_name,last_name,email,
      active,employment_start,employment_end,nominal_monthly_minutes,
      maximum_monthly_minutes,maximum_weekly_minutes,maximum_consecutive_days,
      minimum_rest_minutes,only_morning,only_evening,no_weekends,
      preferred_shift_code,created_by,updated_by,work_time_policy
    ) values(
      v_matrix,v_employee.id,v_employee.employee_no,v_employee.first_name,
      v_employee.last_name,lower(v_employee.email),true,
      coalesce(v_prior.employment_start,v_employee.employment_start),
      coalesce(v_prior.employment_end,v_employee.employment_end),
      v_nominal,v_maximum_monthly,
      coalesce(v_prior.maximum_weekly_minutes,v_employee.max_weekly_minutes,0),
      coalesce(v_prior.maximum_consecutive_days,v_employee.max_consecutive_days,31),
      coalesce(v_prior.minimum_rest_minutes,v_employee.minimum_rest_minutes),
      coalesce(v_prior.only_morning,v_employee.only_morning,false),
      coalesce(v_prior.only_evening,v_employee.only_evening,false),
      coalesce(v_prior.no_weekends,v_employee.no_weekends,false),
      coalesce(v_prior.preferred_shift_code,v_employee.preferred_shift),
      auth.uid(),auth.uid(),coalesce(v_prior.work_time_policy,'CONTRACT_DEFAULT')
    ) on conflict(matrix_version_id,employee_id) do nothing;
    if found then v_inserted:=v_inserted+1; end if;
  end loop;
  return v_inserted;
end;
$$;

alter function solver_private.matrix_v2_full_import_phase_uat_v1(jsonb,text)
  rename to matrix_v2_full_import_phase_raw_uat_v1;

create function solver_private.matrix_v2_full_import_phase_uat_v1(
  p_configuration jsonb,
  p_phase text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
  v_reconnected integer:=0;
begin
  v_result:=solver_private.matrix_v2_full_import_phase_raw_uat_v1(p_configuration,p_phase);
  if upper(trim(coalesce(p_phase,'')))='PRE' then
    v_reconnected:=solver_private.matrix_v2_reconnect_preserved_profiles_uat_v1(p_configuration);
  end if;
  return v_result||jsonb_build_object('reconnectedProfiles',v_reconnected);
end;
$$;

revoke all on function solver_private.matrix_v2_reconnect_preserved_profiles_uat_v1(jsonb),
  solver_private.matrix_v2_full_import_phase_raw_uat_v1(jsonb,text),
  solver_private.matrix_v2_full_import_phase_uat_v1(jsonb,text)
  from public,anon,authenticated;

comment on function solver_private.matrix_v2_reconnect_preserved_profiles_uat_v1(jsonb) is
  'Internal UAT bridge between preserved global employee identities and an empty/reset Matrix draft.';

notify pgrst,'reload schema';
