-- UAT critical repair: a quick-start workbook may intentionally clear every
-- GP-### number so that the application allocates fresh identities.  Hidden
-- round-trip sheets can still contain relations to the old GP numbers.  Those
-- stale rows must not be applied to the new workforce; relations supplied in
-- the consolidated employee sheet are resolved by e-mail after employee
-- creation.  Existing numbered employees retain only their own matching
-- detailed relations.

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
          '{employeeRoles}',coalesce((
            select jsonb_agg(relation.value order by relation.ordinality)
            from jsonb_array_elements(coalesce(p_configuration->'employeeRoles','[]'::jsonb))
              with ordinality relation(value,ordinality)
            where nullif(trim(relation.value->>'employeeNo'),'') is not null
              and exists (
                select 1
                from jsonb_array_elements(coalesce(p_configuration->'employees','[]'::jsonb)) employee(value)
                where nullif(trim(employee.value->>'employeeNo'),'') is not null
                  and upper(trim(employee.value->>'employeeNo'))=upper(trim(relation.value->>'employeeNo'))
              )
          ),'[]'::jsonb),true
        ),
        '{employeeLocationsDetailed}',coalesce((
          select jsonb_agg(relation.value order by relation.ordinality)
          from jsonb_array_elements(coalesce(p_configuration->'employeeLocationsDetailed','[]'::jsonb))
            with ordinality relation(value,ordinality)
          where nullif(trim(relation.value->>'employeeNo'),'') is not null
            and exists (
              select 1
              from jsonb_array_elements(coalesce(p_configuration->'employees','[]'::jsonb)) employee(value)
              where nullif(trim(employee.value->>'employeeNo'),'') is not null
                and upper(trim(employee.value->>'employeeNo'))=upper(trim(relation.value->>'employeeNo'))
            )
        ),'[]'::jsonb),true
      ),
      '{employeeCapabilities}',coalesce((
        select jsonb_agg(relation.value order by relation.ordinality)
        from jsonb_array_elements(coalesce(p_configuration->'employeeCapabilities','[]'::jsonb))
          with ordinality relation(value,ordinality)
        where nullif(trim(relation.value->>'employeeNo'),'') is not null
          and exists (
            select 1
            from jsonb_array_elements(coalesce(p_configuration->'employees','[]'::jsonb)) employee(value)
            where nullif(trim(employee.value->>'employeeNo'),'') is not null
              and upper(trim(employee.value->>'employeeNo'))=upper(trim(relation.value->>'employeeNo'))
          )
      ),'[]'::jsonb),true
    ),
    '{timeConstraints}',coalesce((
      select jsonb_agg(relation.value order by relation.ordinality)
      from jsonb_array_elements(coalesce(p_configuration->'timeConstraints','[]'::jsonb))
        with ordinality relation(value,ordinality)
      where nullif(trim(relation.value->>'employeeNo'),'') is not null
        and exists (
          select 1
          from jsonb_array_elements(coalesce(p_configuration->'employees','[]'::jsonb)) employee(value)
          where nullif(trim(employee.value->>'employeeNo'),'') is not null
            and upper(trim(employee.value->>'employeeNo'))=upper(trim(relation.value->>'employeeNo'))
        )
    ),'[]'::jsonb),true
  )
$$;

-- A full workforce round-trip legitimately exceeds the project-wide 8-second
-- authenticated statement timeout.  Keep that global guard unchanged and
-- grant only the six atomic import boundaries a bounded UAT exception.
alter function public.matrix_v2_team_import_preview_uat_v1(jsonb,text)
  set statement_timeout to '60s';
alter function public.matrix_v2_team_import_preview_uat_v1(jsonb,text)
  set lock_timeout to '60s';
alter function public.matrix_v2_team_import_apply_uat_v1(jsonb,text)
  set statement_timeout to '60s';
alter function public.matrix_v2_team_import_apply_uat_v1(jsonb,text)
  set lock_timeout to '60s';
alter function public.matrix_v2_full_import_preview_uat_v1(jsonb,text)
  set statement_timeout to '60s';
alter function public.matrix_v2_full_import_preview_uat_v1(jsonb,text)
  set lock_timeout to '60s';
alter function public.matrix_v2_full_import_apply_uat_v1(jsonb,text)
  set statement_timeout to '60s';
alter function public.matrix_v2_full_import_apply_uat_v1(jsonb,text)
  set lock_timeout to '60s';
alter function public.matrix_v2_finance_import_preview_uat_v1(jsonb)
  set statement_timeout to '60s';
alter function public.matrix_v2_finance_import_preview_uat_v1(jsonb)
  set lock_timeout to '60s';
alter function public.matrix_v2_finance_import_apply_uat_v1(jsonb)
  set statement_timeout to '60s';
alter function public.matrix_v2_finance_import_apply_uat_v1(jsonb)
  set lock_timeout to '60s';

comment on function solver_private.matrix_v2_team_configuration_uat_v1(jsonb) is
  'Quick-start UAT payload: retain detailed employee relations only when their GP number exists in the submitted employee list; consolidated blank-number rows are resolved by e-mail.';

notify pgrst,'reload schema';
