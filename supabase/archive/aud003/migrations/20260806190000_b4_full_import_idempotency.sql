-- B4: a full company workbook exposes capabilities twice on purpose:
-- convenient TAK/NIE columns in "Pracownicy" and the authoritative detailed
-- rows in "Kompetencje pracowników".  A round trip must never persist both
-- representations as separate capability grants.

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
        where upper(coalesce(detailed.value->>'employeeNo',''))=upper(coalesce(inline.value->>'employeeNo',''))
          and upper(coalesce(detailed.value->>'dutyCode',''))=upper(coalesce(inline.value->>'dutyCode',''))
      )
    ),'[]'::jsonb),
    true
  )
$$;

alter function public.matrix_v2_full_import_preview_uat_v1(jsonb,text)
  rename to matrix_v2_full_import_preview_raw_uat_v1;
alter function public.matrix_v2_full_import_apply_uat_v1(jsonb,text)
  rename to matrix_v2_full_import_apply_raw_uat_v1;

create function public.matrix_v2_full_import_preview_uat_v1(
  p_payload jsonb,
  p_mode text default 'UPDATE'
) returns jsonb
language sql
security definer
set search_path = ''
as $$
  select public.matrix_v2_full_import_preview_raw_uat_v1(
    jsonb_set(
      coalesce(p_payload,'{}'::jsonb),
      '{configuration}',
      solver_private.matrix_v2_full_import_configuration_uat_v2(coalesce(p_payload->'configuration','{}'::jsonb)),
      true
    ),
    p_mode
  )
$$;

create function public.matrix_v2_full_import_apply_uat_v1(
  p_payload jsonb,
  p_mode text default 'UPDATE'
) returns jsonb
language sql
security definer
set search_path = ''
as $$
  select public.matrix_v2_full_import_apply_raw_uat_v1(
    jsonb_set(
      coalesce(p_payload,'{}'::jsonb),
      '{configuration}',
      solver_private.matrix_v2_full_import_configuration_uat_v2(coalesce(p_payload->'configuration','{}'::jsonb)),
      true
    ),
    p_mode
  )
$$;

revoke all on function solver_private.matrix_v2_full_import_configuration_uat_v2(jsonb),
  public.matrix_v2_full_import_preview_raw_uat_v1(jsonb,text),
  public.matrix_v2_full_import_apply_raw_uat_v1(jsonb,text),
  public.matrix_v2_full_import_preview_uat_v1(jsonb,text),
  public.matrix_v2_full_import_apply_uat_v1(jsonb,text)
  from public,anon,authenticated;

grant execute on function public.matrix_v2_full_import_preview_uat_v1(jsonb,text),
  public.matrix_v2_full_import_apply_uat_v1(jsonb,text)
  to authenticated;

comment on function public.matrix_v2_full_import_preview_uat_v1(jsonb,text) is
  'UAT-only full company import preview. Detailed employee capability rows are authoritative over convenience columns.';
comment on function public.matrix_v2_full_import_apply_uat_v1(jsonb,text) is
  'UAT-only atomic full company import. Filters duplicate inline capability grants before applying the existing validated contract.';
