-- UAT onboarding repair: validate a workbook against the structure contained in
-- that same workbook.  The previous TEAM preview created roles and locations
-- before validation, but not shift templates.  Staffing rows could therefore
-- report SHIFT_NOT_FOUND even though the shift was present in the uploaded file.

create or replace function solver_private.matrix_v2_team_import_configuration_uat_v2(
  p_configuration jsonb
) returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_set(
    solver_private.matrix_v2_team_configuration_uat_v1(coalesce(p_configuration,'{}'::jsonb)),
    '{staffingRules}',
    coalesce((
      select jsonb_agg(
        case when coalesce((row.value->>'active')::boolean,true) then row.value
          else row.value||jsonb_build_object('operation','SET','countValue','0') end
        order by row.ordinality
      )
      from jsonb_array_elements(coalesce(p_configuration->'staffingRules','[]'::jsonb))
        with ordinality row(value,ordinality)
    ),'[]'::jsonb),
    true
  )
$$;

create or replace function solver_private.matrix_v2_seed_import_shifts_uat_v1(
  p_configuration jsonb
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_matrix uuid;
  v_row jsonb;
  v_location uuid;
  v_existing uuid;
  v_saved integer:=0;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  v_matrix:=public.matrix_v2_create_draft(null);

  for v_row in
    select value
    from jsonb_array_elements(coalesce(p_configuration->'shifts','[]'::jsonb))
  loop
    -- Invalid identity/time/day data is deliberately left to the ordinary
    -- preview, which can return a precise sheet and row instead of an RPC error.
    if nullif(trim(v_row->>'code'),'') is null
      or nullif(trim(v_row->>'name'),'') is null
      or coalesce(v_row->>'startsAt','') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
      or coalesce(v_row->>'endsAt','') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
      or jsonb_typeof(coalesce(v_row->'days','[]'::jsonb))<>'array'
      or jsonb_array_length(coalesce(v_row->'days','[]'::jsonb))=0 then
      continue;
    end if;

    select location_row.id into v_location
    from public.matrix_locations_v2 location_row
    where location_row.matrix_version_id=v_matrix and location_row.active
      and upper(location_row.code)=upper(coalesce(v_row->>'locationCode',''))
    order by location_row.id limit 1;
    if v_location is null then continue; end if;

    select shift_row.id into v_existing
    from public.matrix_shift_templates_v2 shift_row
    where shift_row.matrix_version_id=v_matrix
      and shift_row.location_id=v_location
      and upper(shift_row.code)=upper(v_row->>'code')
    order by shift_row.id limit 1;

    -- Temporarily activate the row so staffing validation can resolve it.  The
    -- normal importer immediately restores the workbook's real active flag.
    perform public.matrix_v2_admin_save_alpha16(
      'SHIFT',v_existing,
      v_row||jsonb_build_object('locationId',v_location,'active',true)
    );
    v_saved:=v_saved+1;
  end loop;
  return v_saved;
end;
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
  v_configuration jsonb:=solver_private.matrix_v2_team_import_configuration_uat_v2(coalesce(p_configuration,'{}'::jsonb));
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
    perform solver_private.matrix_v2_seed_import_shifts_uat_v1(v_configuration);
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
  v_configuration jsonb:=solver_private.matrix_v2_team_import_configuration_uat_v2(coalesce(p_configuration,'{}'::jsonb));
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
  perform solver_private.matrix_v2_seed_import_shifts_uat_v1(v_configuration);
  v_result:=public.matrix_v2_import_apply_uat_v5(v_configuration_without_rates,p_mode);
  perform solver_private.matrix_v2_full_import_phase_uat_v1(v_configuration,'POST');
  return v_result||jsonb_build_object('atomic',true,'scope','TEAM_AND_STRUCTURE','financeDeferred',true,'validationOrder','STRUCTURE_THEN_RELATIONS');
exception when others then
  if sqlerrm like 'MATRIX_%' or sqlerrm like 'INVALID_%'
    or sqlerrm like 'EMPLOYEE_%' or sqlerrm like 'IMPORTED_%'
    or sqlerrm like 'FULL_IMPORT_%' then raise; end if;
  raise exception 'TEAM_IMPORT_APPLY_FAILED|%|%|%',gen_random_uuid(),sqlstate,sqlerrm;
end;
$$;

revoke all on function solver_private.matrix_v2_team_import_configuration_uat_v2(jsonb),
  solver_private.matrix_v2_seed_import_shifts_uat_v1(jsonb),
  public.matrix_v2_team_import_preview_uat_v1(jsonb,text),
  public.matrix_v2_team_import_apply_uat_v1(jsonb,text)
  from public,anon,authenticated;

grant execute on function public.matrix_v2_team_import_preview_uat_v1(jsonb,text),
  public.matrix_v2_team_import_apply_uat_v1(jsonb,text)
  to authenticated;

alter function public.matrix_v2_team_import_preview_uat_v1(jsonb,text) set statement_timeout to '60s';
alter function public.matrix_v2_team_import_apply_uat_v1(jsonb,text) set statement_timeout to '60s';

comment on function public.matrix_v2_team_import_preview_uat_v1(jsonb,text) is
  'UAT onboarding dry-run. Incoming dictionaries and shifts are staged in the same rolled-back transaction before employee and staffing validation.';
comment on function public.matrix_v2_team_import_apply_uat_v1(jsonb,text) is
  'UAT atomic onboarding in dependency order: dictionaries, shifts, workforce, relations and deferred finance.';

notify pgrst,'reload schema';
