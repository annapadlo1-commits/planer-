-- GRAFIK PRO 3.0 — durable Matrix import contract repair.
--
-- The isolated UAT received the public v3 import entrypoints without the v2
-- helper functions they called.  Preview could therefore create a draft, but
-- apply failed at runtime with an undefined_function error.  Keep the helpers
-- in this migration so a partial historical migration ledger cannot produce a
-- callable but incomplete import API again.

-- The skipped historical migration also owned these two prerequisites.  They
-- are repeated here intentionally: a deployment must never expose v3/v4
-- entrypoints while leaving their data contract incomplete.
create or replace function solver_private.normalize_contract_type_v2(p_value text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case regexp_replace(
    upper(trim(coalesce(p_value,''))),
    '[^A-ZĄĆĘŁŃÓŚŹŻ0-9]+','','g'
  )
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
  add column if not exists work_time_policy text not null
    default 'CONTRACT_DEFAULT'
    check(work_time_policy in ('CONTRACT_DEFAULT','CUSTOM'));

comment on column public.matrix_employee_profiles_v2.work_time_policy is
  'CONTRACT_DEFAULT applies employment-law caps only to employment contracts. CUSTOM makes individually entered caps hard also for flexible contracts.';

do $$
begin
  if to_regprocedure('public.matrix_v2_import_preview_alpha16(jsonb)') is null
    or to_regprocedure('public.matrix_v2_import_apply_alpha16(jsonb)') is null
    or to_regprocedure('solver_private.normalize_contract_type_v2(text)') is null then
    raise exception 'MATRIX_IMPORT_PREREQUISITE_MISSING';
  end if;
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
        'sheet','PRACOWNICY','row',v_index+1,
        'code','EMPLOYEE_DUTY_EMPLOYEE_NOT_FOUND',
        'message','Funkcja pracownika nie wskazuje osoby z sekcji pracowników.'
      ));
    end if;
    if not exists(select 1 from public.matrix_duties_v2 duty
      where duty.matrix_version_id=v_matrix and duty.active
        and upper(duty.code)=upper(coalesce(v_row->>'dutyCode',''))) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,
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
    if v_employee is null then
      raise exception 'IMPORTED_EMPLOYEE_NOT_FOUND|%|%|%',
        coalesce(v_row->>'employeeNo',''),coalesce(v_row->>'email',''),v_matrix;
    end if;
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

-- Versioned public boundary used by the next frontend.  Unexpected failures
-- keep their database message and receive a correlation id so UAT can report a
-- useful error without showing a misleading form-validation fallback.
create or replace function public.matrix_v2_import_preview_uat_v4(
  p_payload jsonb,
  p_mode text default 'UPDATE'
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if to_regprocedure('public.matrix_v2_import_preview_uat_v3(jsonb,text)') is null
    or to_regprocedure('public.matrix_v2_import_apply_uat_v3(jsonb,text)') is null then
    raise exception 'MATRIX_IMPORT_CONTRACT_INCOMPLETE';
  end if;
  return public.matrix_v2_import_preview_uat_v3(p_payload,p_mode);
exception when others then
  if sqlerrm like 'MATRIX_%' or sqlerrm like 'INVALID_%' then raise; end if;
  raise exception 'MATRIX_IMPORT_PREVIEW_FAILED|%|%|%',gen_random_uuid(),sqlstate,sqlerrm;
end;
$$;

create or replace function public.matrix_v2_import_apply_uat_v4(
  p_payload jsonb,
  p_mode text default 'UPDATE'
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if to_regprocedure('public.matrix_v2_import_preview_uat_v3(jsonb,text)') is null
    or to_regprocedure('public.matrix_v2_import_apply_uat_v3(jsonb,text)') is null then
    raise exception 'MATRIX_IMPORT_CONTRACT_INCOMPLETE';
  end if;
  return public.matrix_v2_import_apply_uat_v3(p_payload,p_mode);
exception when others then
  if sqlerrm like 'MATRIX_%' or sqlerrm like 'INVALID_%'
    or sqlerrm like 'EMPLOYEE_%' or sqlerrm like 'PAY_RATE_%'
    or sqlerrm like 'OVERLAPPING_%' then raise; end if;
  raise exception 'MATRIX_IMPORT_APPLY_FAILED|%|%|%',gen_random_uuid(),sqlstate,sqlerrm;
end;
$$;

revoke all on function public.matrix_v2_import_preview_uat_v2(jsonb),
  public.matrix_v2_import_apply_uat_v2(jsonb),
  public.matrix_v2_import_preview_uat_v4(jsonb,text),
  public.matrix_v2_import_apply_uat_v4(jsonb,text)
  from public,anon,authenticated;
grant execute on function public.matrix_v2_import_preview_uat_v2(jsonb),
  public.matrix_v2_import_apply_uat_v2(jsonb),
  public.matrix_v2_import_preview_uat_v4(jsonb,text),
  public.matrix_v2_import_apply_uat_v4(jsonb,text)
  to authenticated;

comment on function public.matrix_v2_import_apply_uat_v4(jsonb,text) is
  'Atomic Matrix import boundary with explicit dependency checks and correlated unexpected errors.';
