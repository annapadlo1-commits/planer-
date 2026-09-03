-- Keep imported rates usable from the Matrix activation date.
--
-- The workbook's `preferenceMonth` describes employee shift preferences.  It
-- must not silently become the effective date of a newly imported pay rate.
-- Without this repair, importing a September workbook in August created all
-- rates from 1 September and the otherwise valid Matrix could not be
-- published in August for September planning.

create or replace function public.matrix_v2_import_preview_uat_v5(
  p_payload jsonb,
  p_mode text default 'UPDATE'
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return public.matrix_v2_import_preview_uat_v4(p_payload,p_mode);
end;
$$;

create or replace function public.matrix_v2_import_apply_uat_v5(
  p_payload jsonb,
  p_mode text default 'UPDATE'
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
  v_matrix public.matrix_versions%rowtype;
  v_normalized jsonb;
  v_row jsonb;
  v_profile public.matrix_employee_profiles_v2%rowtype;
  v_rate public.employee_pay_rates_v2%rowtype;
  v_required_start date;
  v_rate_amount bigint;
  v_currency text;
  v_anchored integer:=0;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;

  v_result:=public.matrix_v2_import_apply_uat_v4(p_payload,p_mode);

  select * into v_matrix
  from public.matrix_versions matrix
  where matrix.status='DRAFT' and matrix.schema_version>=2
  order by matrix.version desc limit 1;
  if v_matrix.id is null then raise exception 'NO_MATRIX_V2_DRAFT'; end if;

  v_normalized:=solver_private.matrix_v2_import_normalize_uat_v3(
    p_payload,v_matrix.id
  );
  v_currency:=upper(v_matrix.settings->>'currency');

  for v_row in
    select value from jsonb_array_elements(
      coalesce(v_normalized->'employees','[]'::jsonb)
    ) where nullif(value->>'baseRate','') is not null
  loop
    select profile.* into v_profile
    from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=v_matrix.id and (
      (nullif(trim(v_row->>'employeeNo'),'') is not null
        and upper(profile.employee_no)=upper(trim(v_row->>'employeeNo')))
      or (nullif(lower(trim(v_row->>'email')),'') is not null
        and lower(profile.email)=lower(trim(v_row->>'email')))
    ) order by profile.employee_id limit 1;
    if v_profile.employee_id is null then
      raise exception 'IMPORTED_EMPLOYEE_NOT_FOUND|%|%',
        coalesce(v_row->>'employeeNo',''),coalesce(v_row->>'email','');
    end if;

    v_required_start:=greatest(
      v_matrix.effective_from,
      coalesce(v_profile.employment_start,v_matrix.effective_from)
    );
    if v_profile.employment_end is not null
      and v_required_start>v_profile.employment_end then
      continue;
    end if;

    -- Existing historical coverage wins.  This only anchors the first rate of
    -- an employee created by the import; it never rewrites an established
    -- period or an intentional future pay change.
    if exists(
      select 1 from public.employee_pay_rates_v2 rate
      where rate.employee_id=v_profile.employee_id and rate.active
        and rate.valid_from<=v_required_start
        and (rate.valid_to is null or rate.valid_to>=v_required_start)
    ) then continue; end if;

    v_rate_amount:=round(replace(v_row->>'baseRate',',','.')::numeric*100)::bigint;
    select rate.* into v_rate
    from public.employee_pay_rates_v2 rate
    where rate.employee_id=v_profile.employee_id and rate.active
      and rate.valid_from>v_required_start
      and rate.base_rate_minor=v_rate_amount
      and upper(rate.currency)=v_currency
      and upper(coalesce(rate.contract_type,''))=
        upper(coalesce(nullif(v_row->>'contractType',''),''))
    order by rate.valid_from limit 1;
    if v_rate.id is null then
      raise exception 'IMPORTED_PAY_RATE_NOT_FOUND|%',v_profile.employee_no;
    end if;

    perform public.employee_pay_rate_save_v2(
      v_rate.id,v_profile.employee_id,v_required_start,v_rate.valid_to,
      v_rate.base_rate_minor,v_rate.currency,v_rate.contract_type,v_rate.active
    );
    v_anchored:=v_anchored+1;
  end loop;

  return v_result||jsonb_build_object('ratePeriodsAnchored',v_anchored);
exception when others then
  if sqlerrm like 'MATRIX_%' or sqlerrm like 'INVALID_%'
    or sqlerrm like 'EMPLOYEE_%' or sqlerrm like 'IMPORTED_%'
    or sqlerrm like 'PAY_RATE_%' or sqlerrm like 'OVERLAPPING_%' then raise; end if;
  raise exception 'MATRIX_IMPORT_APPLY_FAILED|%|%|%',
    gen_random_uuid(),sqlstate,sqlerrm;
end;
$$;

revoke all on function public.matrix_v2_import_preview_uat_v5(jsonb,text),
  public.matrix_v2_import_apply_uat_v5(jsonb,text)
  from public,anon,authenticated;
grant execute on function public.matrix_v2_import_preview_uat_v5(jsonb,text),
  public.matrix_v2_import_apply_uat_v5(jsonb,text)
  to authenticated;

comment on function public.matrix_v2_import_apply_uat_v5(jsonb,text) is
  'Atomic v4 import plus first-rate coverage from Matrix activation; preferenceMonth remains a shift-preference month only.';

notify pgrst,'reload schema';
