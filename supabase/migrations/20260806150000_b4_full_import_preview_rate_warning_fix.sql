-- B4 UAT: a full round trip stores rate periods in the dedicated finance
-- sheet.  Do not report the removed legacy inline employee rate as missing
-- when a matching active finance row is present.

create or replace function public.matrix_v2_full_import_preview_uat_v1(
  p_payload jsonb,
  p_mode text default 'UPDATE'
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_configuration jsonb:=coalesce(p_payload->'configuration','{}'::jsonb);
  v_configuration_without_rates jsonb;
  v_finance jsonb:=coalesce(p_payload->'finance','{}'::jsonb);
  v_configuration_preview jsonb;
  v_finance_preview jsonb;
  v_result jsonb;
  v_extra integer;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
  if jsonb_typeof(p_payload)<>'object' then raise exception 'INVALID_FULL_IMPORT_PAYLOAD'; end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  v_configuration_without_rates:=jsonb_set(v_configuration,'{employees}',coalesce((
    select jsonb_agg(value-'baseRate') from jsonb_array_elements(coalesce(v_configuration->'employees','[]'::jsonb))
  ),'[]'::jsonb),true);

  begin
    perform solver_private.matrix_v2_full_import_phase_uat_v1(v_configuration,'PRE');
    v_configuration_preview:=public.matrix_v2_import_preview_uat_v5(v_configuration_without_rates,p_mode);
    if coalesce((v_configuration_preview->>'valid')::boolean,false) then
      perform public.matrix_v2_import_apply_uat_v5(v_configuration_without_rates,p_mode);
      perform solver_private.matrix_v2_full_import_phase_uat_v1(v_configuration,'POST');
      v_finance_preview:=public.matrix_v2_finance_import_preview_uat_v1(
        solver_private.matrix_v2_full_finance_payload_uat_v1(v_finance));
    else
      v_finance_preview:=jsonb_build_object('valid',false,'errors','[]'::jsonb,'warnings','[]'::jsonb,
        'normalizedRows','[]'::jsonb,'summary',jsonb_build_object('rows',jsonb_array_length(coalesce(v_finance->'payRates','[]'::jsonb)),
          'employees',0,'create',0,'update',0,'deactivate',0,'unchanged',0));
    end if;

    v_configuration_preview:=jsonb_set(v_configuration_preview,'{warnings}',coalesce((
      select jsonb_agg(
        case when warning.value->>'code'='PAY_RATE_MISSING' then
          jsonb_set(warning.value,'{message}',to_jsonb('Brak stawki zablokuje późniejszą publikację konfiguracji firmy.'::text),true)
        else warning.value end
        order by warning.ordinality
      )
      from jsonb_array_elements(coalesce(v_configuration_preview->'warnings','[]'::jsonb))
        with ordinality warning(value,ordinality)
      where warning.value->>'code'<>'PAY_RATE_MISSING'
        or not exists(
          select 1
          from jsonb_array_elements(coalesce(v_configuration->'employees','[]'::jsonb))
            with ordinality employee(value,ordinality)
          join jsonb_array_elements(coalesce(v_finance->'payRates','[]'::jsonb)) rate(value)
            on upper(rate.value->>'employeeNo')=upper(employee.value->>'employeeNo')
          where pg_catalog.pg_input_is_valid(warning.value->>'row','integer')
            and employee.ordinality+1=(warning.value->>'row')::integer
            and nullif(rate.value->>'baseRate','') is not null
            and coalesce(nullif(rate.value->>'active','')::boolean,true)
        )
    ),'[]'::jsonb),true);

    v_extra:=jsonb_array_length(coalesce(v_configuration->'roles','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'locations','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'duties','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'scenarios','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'strategies','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'strategyObjectives','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'scenarioStrategies','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'payRules','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'scenarioPayRuleOverrides','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'scenarioBudgets','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'employeeRoles','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'employeeLocationsDetailed','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'employeeCapabilities','[]'::jsonb))
      +jsonb_array_length(coalesce(v_configuration->'timeConstraints','[]'::jsonb));
    v_result:=jsonb_build_object(
      'valid',coalesce((v_configuration_preview->>'valid')::boolean,false)
        and coalesce((v_finance_preview->>'valid')::boolean,false),
      'errors',coalesce(v_configuration_preview->'errors','[]'::jsonb)||coalesce(v_finance_preview->'errors','[]'::jsonb),
      'warnings',coalesce(v_configuration_preview->'warnings','[]'::jsonb)||coalesce(v_finance_preview->'warnings','[]'::jsonb),
      'configuration',v_configuration_preview,'finance',v_finance_preview,
      'summary',coalesce(v_configuration_preview->'summary','{}'::jsonb)||jsonb_build_object(
        'total',coalesce((v_configuration_preview#>>'{summary,total}')::integer,0)+v_extra,
        'financeRows',coalesce((v_finance_preview#>>'{summary,rows}')::integer,0),
        'financeEmployees',coalesce((v_finance_preview#>>'{summary,employees}')::integer,0),
        'financeChanges',coalesce((v_finance_preview#>>'{summary,create}')::integer,0)
          +coalesce((v_finance_preview#>>'{summary,update}')::integer,0)
          +coalesce((v_finance_preview#>>'{summary,deactivate}')::integer,0),
        'roles',jsonb_array_length(coalesce(v_configuration->'roles','[]'::jsonb)),
        'locations',jsonb_array_length(coalesce(v_configuration->'locations','[]'::jsonb)),
        'duties',jsonb_array_length(coalesce(v_configuration->'duties','[]'::jsonb)),
        'scenarios',jsonb_array_length(coalesce(v_configuration->'scenarios','[]'::jsonb)),
        'strategies',jsonb_array_length(coalesce(v_configuration->'strategies','[]'::jsonb)),
        'payRules',jsonb_array_length(coalesce(v_configuration->'payRules','[]'::jsonb)),
        'timeConstraints',jsonb_array_length(coalesce(v_configuration->'timeConstraints','[]'::jsonb))
      ));
    raise sqlstate 'GPF01' using message='FULL_IMPORT_DRY_RUN_COMPLETE';
  exception when sqlstate 'GPF01' then
    return v_result;
  end;
end;
$$;

revoke all on function public.matrix_v2_full_import_preview_uat_v1(jsonb,text) from public,anon;
grant execute on function public.matrix_v2_full_import_preview_uat_v1(jsonb,text) to authenticated;

comment on function public.matrix_v2_full_import_preview_uat_v1(jsonb,text) is
  'UAT-only atomic preview for the full company workbook; dedicated finance rows satisfy rate readiness without duplicate legacy warnings.';
