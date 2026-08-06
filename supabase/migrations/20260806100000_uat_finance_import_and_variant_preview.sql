-- GRAFIK PRO UAT: bulk employee finance import and per-variant workspace preview.
-- The finance flow is intentionally separate from the general configuration
-- importer: pay periods are historical records with stricter permissions.

create or replace function public.matrix_v2_finance_import_preview_uat_v1(
  p_payload jsonb
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_matrix public.matrix_versions%rowtype;
  v_currency text;
  v_rows jsonb:=coalesce(p_payload->'payRates','[]'::jsonb);
  v_row jsonb;
  v_other jsonb;
  v_errors jsonb:='[]'::jsonb;
  v_warnings jsonb:='[]'::jsonb;
  v_normalized jsonb:='[]'::jsonb;
  v_source_row integer;
  v_rate_id_text text;
  v_rate_id uuid;
  v_employee_no text;
  v_profile public.matrix_employee_profiles_v2%rowtype;
  v_existing public.employee_pay_rates_v2%rowtype;
  v_valid_from date;
  v_valid_to date;
  v_base_rate_text text;
  v_base_rate_minor bigint;
  v_row_currency text;
  v_contract_type text;
  v_active boolean;
  v_action text;
  v_employee_count integer:=0;
  v_create integer:=0;
  v_update integer:=0;
  v_deactivate integer:=0;
  v_unchanged integer:=0;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE')) then raise exception 'FORBIDDEN'; end if;
  if p_payload is null or jsonb_typeof(p_payload)<>'object'
    or jsonb_typeof(v_rows)<>'array' then raise exception 'INVALID_FINANCE_IMPORT_PAYLOAD'; end if;
  if jsonb_array_length(v_rows)=0 then raise exception 'FINANCE_IMPORT_EMPTY'; end if;
  if jsonb_array_length(v_rows)>1000 then raise exception 'FINANCE_IMPORT_TOO_LARGE'; end if;

  select matrix.* into v_matrix
  from public.matrix_versions matrix
  where matrix.status='DRAFT' and matrix.schema_version>=2
  order by matrix.version desc limit 1;
  if v_matrix.id is null then raise exception 'NO_MATRIX_V2_DRAFT'; end if;
  v_currency:=upper(trim(coalesce(v_matrix.settings->>'currency','')));

  for v_row in select value from jsonb_array_elements(v_rows) loop
    v_source_row:=case when pg_catalog.pg_input_is_valid(coalesce(v_row->>'sourceRow',''),'integer')
      then (v_row->>'sourceRow')::integer else 0 end;
    v_rate_id_text:=trim(coalesce(v_row->>'rateId',''));
    v_employee_no:=upper(trim(coalesce(v_row->>'employeeNo','')));
    v_valid_from:=case when pg_catalog.pg_input_is_valid(coalesce(v_row->>'validFrom',''),'date')
      then (v_row->>'validFrom')::date else null end;
    v_valid_to:=case when nullif(trim(coalesce(v_row->>'validTo','')),'') is null then null
      when pg_catalog.pg_input_is_valid(v_row->>'validTo','date') then (v_row->>'validTo')::date
      else null end;
    v_base_rate_text:=replace(trim(coalesce(v_row->>'baseRate','')),',','.');
    v_base_rate_minor:=case when v_base_rate_text~'^\d+(\.\d{1,2})?$'
      then round(v_base_rate_text::numeric*100)::bigint else null end;
    v_row_currency:=upper(trim(coalesce(v_row->>'currency','')));
    v_contract_type:=upper(trim(coalesce(v_row->>'contractType','')));
    v_active:=case lower(trim(coalesce(v_row->>'active','true')))
      when 'true' then true when 't' then true when '1' then true
      when 'yes' then true when 'on' then true
      when 'false' then false when 'f' then false when '0' then false
      when 'no' then false when 'off' then false
      else null end;
    v_rate_id:=case when pg_catalog.pg_input_is_valid(v_rate_id_text,'uuid')
      then v_rate_id_text::uuid else null end;

    select profile.* into v_profile
    from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=v_matrix.id and profile.active
      and upper(profile.employee_no)=v_employee_no
    limit 1;

    if v_source_row<2 then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object('sheet','Finanse pracowników','row',v_source_row,'code','INVALID_SOURCE_ROW','message','Nie udało się ustalić numeru wiersza. Pobierz świeży szablon i spróbuj ponownie.'));
    end if;
    if v_profile.employee_id is null then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object('sheet','Finanse pracowników','row',v_source_row,'code','EMPLOYEE_NOT_FOUND','message',format('Nie znaleziono aktywnego pracownika o numerze %s.',coalesce(nullif(v_employee_no,''),'—'))));
    end if;
    if v_valid_from is null then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object('sheet','Finanse pracowników','row',v_source_row,'code','INVALID_VALID_FROM','message','Podaj prawidłową datę w polu „Obowiązuje od”.'));
    end if;
    if nullif(trim(coalesce(v_row->>'validTo','')),'') is not null and v_valid_to is null then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object('sheet','Finanse pracowników','row',v_source_row,'code','INVALID_VALID_TO','message','Data „Obowiązuje do” ma nieprawidłowy format.'));
    elsif v_valid_from is not null and v_valid_to is not null and v_valid_to<v_valid_from then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object('sheet','Finanse pracowników','row',v_source_row,'code','INVALID_RATE_PERIOD','message','Koniec okresu stawki nie może być wcześniejszy niż jego początek.'));
    end if;
    if v_base_rate_minor is null or v_base_rate_minor<0 then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object('sheet','Finanse pracowników','row',v_source_row,'code','INVALID_BASE_RATE','message','Podaj nieujemną stawkę godzinową z dokładnością do dwóch miejsc po przecinku.'));
    end if;
    if v_row_currency<>v_currency then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object('sheet','Finanse pracowników','row',v_source_row,'code','INVALID_CURRENCY','message',format('Waluta musi być zgodna z konfiguracją firmy: %s.',v_currency))));
    end if;
    if v_contract_type not in ('UMOWA_O_PRACE','ZLECENIE','CZESC_ETATU','B2B','INNE') then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object('sheet','Finanse pracowników','row',v_source_row,'code','INVALID_CONTRACT_TYPE','message','Wybierz rodzaj umowy z arkusza „Słowniki”.'));
    end if;
    if v_active is null then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object('sheet','Finanse pracowników','row',v_source_row,'code','INVALID_ACTIVE_VALUE','message','Pole „Aktywna” musi mieć wartość TAK albo NIE.'));
    end if;
    if v_rate_id_text<>'' and v_rate_id is null then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object('sheet','Finanse pracowników','row',v_source_row,'code','INVALID_RATE_ID','message','ID stawki ma nieprawidłowy format. Nie zmieniaj identyfikatorów pobranych z szablonu.'));
    end if;
    if not v_active and v_rate_id is null then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object('sheet','Finanse pracowników','row',v_source_row,'code','NEW_INACTIVE_RATE','message','Nowy, nieaktywny wiersz nie ma skutku. Usuń go albo ustaw „Aktywna” na TAK.'));
    end if;

    select rate.* into v_existing from public.employee_pay_rates_v2 rate
    where rate.id=v_rate_id;
    if v_rate_id is not null and (v_existing.id is null
      or v_existing.employee_id is distinct from v_profile.employee_id) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object('sheet','Finanse pracowników','row',v_source_row,'code','RATE_NOT_OWNED_BY_EMPLOYEE','message','ID stawki nie należy do wskazanego pracownika. Pobierz świeży plik i nie przenoś ID między osobami.'));
    end if;
    if v_profile.employee_id is not null and v_valid_from is not null and (
      (v_profile.employment_start is not null and v_valid_from<v_profile.employment_start)
      or (v_profile.employment_end is not null and (v_valid_from>v_profile.employment_end
        or v_valid_to is null or v_valid_to>v_profile.employment_end))
    ) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object('sheet','Finanse pracowników','row',v_source_row,'code','RATE_OUTSIDE_EMPLOYMENT','message','Okres stawki wykracza poza daty zatrudnienia tej osoby.'));
    end if;

    if v_profile.employee_id is not null and v_valid_from is not null
      and v_base_rate_minor is not null and v_row_currency=v_currency
      and v_contract_type in ('UMOWA_O_PRACE','ZLECENIE','CZESC_ETATU','B2B','INNE')
      and v_active is not null
      and (v_rate_id is null or v_existing.id is not null) then
      v_action:=case
        when v_rate_id is null then 'CREATE'
        when not v_active and v_existing.active then 'DEACTIVATE'
        when not v_active and not v_existing.active then 'UNCHANGED'
        when v_existing.active=v_active and v_existing.valid_from=v_valid_from
          and v_existing.valid_to is not distinct from v_valid_to
          and v_existing.base_rate_minor=v_base_rate_minor
          and upper(v_existing.currency)=v_row_currency
          and upper(coalesce(v_existing.contract_type,''))=v_contract_type then 'UNCHANGED'
        else 'UPDATE' end;
      v_normalized:=v_normalized||jsonb_build_array(jsonb_build_object(
        'sourceRow',v_source_row,'rateId',coalesce(v_rate_id::text,''),
        'employeeId',v_profile.employee_id,'employeeNo',v_profile.employee_no,
        'employeeName',trim(concat(v_profile.first_name,' ',v_profile.last_name)),
        'validFrom',v_valid_from,'validTo',v_valid_to,
        'baseRateMinor',v_base_rate_minor,'currency',v_row_currency,
        'contractType',v_contract_type,'active',v_active,'action',v_action
      ));
    end if;
  end loop;

  for v_row in select value from jsonb_array_elements(v_normalized) loop
    if nullif(v_row->>'rateId','') is not null and exists(
      select 1 from jsonb_array_elements(v_normalized) duplicate
      where duplicate.value->>'rateId'=v_row->>'rateId'
        and (duplicate.value->>'sourceRow')::integer<>(v_row->>'sourceRow')::integer
    ) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object('sheet','Finanse pracowników','row',(v_row->>'sourceRow')::integer,'code','DUPLICATE_RATE_ID','message','To samo ID stawki występuje w pliku więcej niż raz.'));
    end if;
    if (v_row->>'active')::boolean and exists(
      select 1 from jsonb_array_elements(v_normalized) other
      where other.value->>'employeeId'=v_row->>'employeeId'
        and (other.value->>'active')::boolean
        and (other.value->>'sourceRow')::integer<>(v_row->>'sourceRow')::integer
        and daterange((other.value->>'validFrom')::date,
          case when nullif(other.value->>'validTo','') is null then null else (other.value->>'validTo')::date+1 end,'[)')
          && daterange((v_row->>'validFrom')::date,
          case when nullif(v_row->>'validTo','') is null then null else (v_row->>'validTo')::date+1 end,'[)')
    ) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object('sheet','Finanse pracowników','row',(v_row->>'sourceRow')::integer,'code','OVERLAPPING_IMPORTED_RATE','message','Ten okres nakłada się na inny aktywny okres tej samej osoby w pliku.'));
    end if;
    if (v_row->>'active')::boolean and exists(
      select 1 from public.employee_pay_rates_v2 rate
      where rate.employee_id=(v_row->>'employeeId')::uuid and rate.active
        and not exists(select 1 from jsonb_array_elements(v_normalized) supplied
          where nullif(supplied.value->>'rateId','')=rate.id::text)
        and daterange(rate.valid_from,case when rate.valid_to is null then null else rate.valid_to+1 end,'[)')
          && daterange((v_row->>'validFrom')::date,
          case when nullif(v_row->>'validTo','') is null then null else (v_row->>'validTo')::date+1 end,'[)')
    ) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object('sheet','Finanse pracowników','row',(v_row->>'sourceRow')::integer,'code','OVERLAPPING_EXISTING_RATE','message','Ten okres nakłada się na istniejącą aktywną stawkę tej osoby, której nie ma w pliku. Pobierz świeży szablon.'));
    end if;
  end loop;

  select count(distinct value->>'employeeId'),
    count(*) filter(where value->>'action'='CREATE'),
    count(*) filter(where value->>'action'='UPDATE'),
    count(*) filter(where value->>'action'='DEACTIVATE'),
    count(*) filter(where value->>'action'='UNCHANGED')
  into v_employee_count,v_create,v_update,v_deactivate,v_unchanged
  from jsonb_array_elements(v_normalized);

  return jsonb_build_object(
    'valid',jsonb_array_length(v_errors)=0,'matrixVersionId',v_matrix.id,
    'errors',v_errors,'warnings',v_warnings,'normalizedRows',v_normalized,
    'summary',jsonb_build_object('rows',jsonb_array_length(v_rows),
      'employees',coalesce(v_employee_count,0),'create',coalesce(v_create,0),
      'update',coalesce(v_update,0),'deactivate',coalesce(v_deactivate,0),
      'unchanged',coalesce(v_unchanged,0))
  );
end;
$$;

create or replace function public.matrix_v2_finance_import_apply_uat_v1(
  p_payload jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_preview jsonb;
  v_row jsonb;
  v_rate_id uuid;
  v_applied integer:=0;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE')) then raise exception 'FORBIDDEN'; end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  v_preview:=public.matrix_v2_finance_import_preview_uat_v1(p_payload);
  if not coalesce((v_preview->>'valid')::boolean,false) then
    raise exception 'FINANCE_IMPORT_HAS_ERRORS';
  end if;

  -- Temporarily deactivate every changed existing row. This allows two
  -- adjacent periods to exchange dates without a transient overlap failure.
  update public.employee_pay_rates_v2 rate set active=false,updated_at=now(),updated_by=auth.uid()
  where rate.id in (
    select (value->>'rateId')::uuid from jsonb_array_elements(v_preview->'normalizedRows')
    where value->>'action' in ('UPDATE','DEACTIVATE')
      and nullif(value->>'rateId','') is not null
  );

  for v_row in select value from jsonb_array_elements(v_preview->'normalizedRows') loop
    if v_row->>'action'='UNCHANGED' then continue; end if;
    v_rate_id:=public.employee_pay_rate_save_v2(
      nullif(v_row->>'rateId','')::uuid,
      (v_row->>'employeeId')::uuid,
      (v_row->>'validFrom')::date,
      nullif(v_row->>'validTo','')::date,
      (v_row->>'baseRateMinor')::bigint,
      v_row->>'currency',v_row->>'contractType',(v_row->>'active')::boolean
    );
    v_applied:=v_applied+1;
  end loop;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_v2_employee_finance',v_preview->>'matrixVersionId',
    'BULK_IMPORT',jsonb_build_object('rows',v_applied,
      'employees',v_preview#>>'{summary,employees}',
      'created',v_preview#>>'{summary,create}',
      'updated',v_preview#>>'{summary,update}',
      'deactivated',v_preview#>>'{summary,deactivate}'));
  return jsonb_build_object('appliedRows',v_applied,'summary',v_preview->'summary');
end;
$$;

revoke all on function public.matrix_v2_finance_import_preview_uat_v1(jsonb),
  public.matrix_v2_finance_import_apply_uat_v1(jsonb)
  from public,anon,authenticated;
grant execute on function public.matrix_v2_finance_import_preview_uat_v1(jsonb),
  public.matrix_v2_finance_import_apply_uat_v1(jsonb)
  to authenticated;

-- Restore the per-variant workspace function required by the comparison UI.
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

-- Explain historical results in which the old solver deliberately left seats
-- empty to keep two people in reserve. Candidate-level checks alone correctly
-- show those people as eligible, so the collective model decision must be
-- exposed separately instead of pretending there is no explanation.
alter function public.optimizer_variant_issue_diagnostics_uat_v2(uuid,bigint)
  rename to optimizer_variant_issue_diagnostics_before_capacity_context_uat_v2;

create function public.optimizer_variant_issue_diagnostics_uat_v2(
  p_variant_id uuid,
  p_issue_id bigint
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_payload jsonb;
  v_run_id uuid;
  v_standby_tiers integer:=0;
begin
  v_payload:=public.optimizer_variant_issue_diagnostics_before_capacity_context_uat_v2(
    p_variant_id,p_issue_id
  );
  select variant.run_id into v_run_id
  from public.plan_variants_v2 variant where variant.id=p_variant_id;
  select coalesce((snapshot.snapshot->'settings'->>'standbyTiersPerRoleDay')::integer,0)
  into v_standby_tiers
  from solver_private.optimization_snapshots_v2 snapshot
  where snapshot.run_id=v_run_id;
  return jsonb_set(v_payload,'{decisionContext}',case
    when v_standby_tiers>0 and coalesce((v_payload#>>'{summary,eligible}')::integer,0)>0
      then jsonb_build_object(
        'code','STANDBY_RESERVE_REDUCED_CAPACITY',
        'standbyTiers',v_standby_tiers,
        'message',format('Poprzednia wersja silnika pozostawiła %s osoby jako rezerwę stand-by, mimo że powodowało to wakat. Kandydaci bez indywidualnej blokady mogli zostać przypisani.',v_standby_tiers)
      )
    else 'null'::jsonb end,true);
end;
$$;

revoke all on function public.optimizer_variant_issue_diagnostics_before_capacity_context_uat_v2(uuid,bigint),
  public.optimizer_variant_issue_diagnostics_uat_v2(uuid,bigint)
  from public,anon,authenticated;
grant execute on function public.optimizer_variant_issue_diagnostics_uat_v2(uuid,bigint)
  to authenticated;

-- The detailed published-workspace wrapper used by the manager UI previously
-- dropped the engine marker returned by optimizer_active_workspace_v2.  The
-- schedule existed, but the client correctly rejected the incomplete contract
-- and displayed a misleading "workspace not confirmed" error.
create or replace function public.optimizer_published_schedule_alpha16(
  p_schedule_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_workspace jsonb;
  v_variant_ids uuid[];
begin
  v_workspace:=public.optimizer_published_schedule_v2(p_schedule_id);
  select array_agg(link.variant_id order by link.ordinal)
  into v_variant_ids
  from public.published_schedule_variants_v2 link
  where link.schedule_id=p_schedule_id;
  return solver_private.alpha16_enrich_workspace_issues_v2(
    v_workspace,v_variant_ids
  )||jsonb_build_object('engine','ORTOOLS_V2');
end;
$$;

comment on function public.optimizer_published_schedule_alpha16(uuid) is
  'Published OR-Tools schedule with exact issue context and an explicit engine marker required by the operational UI contract.';

-- Required staffing always has priority over reserve coverage.  The previous
-- implementation unconditionally requested two standby employees for every
-- role/day and aborted publication when either tier was unavailable.  That
-- coupled an optional safety net to the required schedule and could make a
-- fully staffed role impossible to publish.  Generate up to the configured
-- number of tiers and stop gracefully when the eligible pool is exhausted.
create or replace function solver_private.generate_standby_for_variant_uat_v2(
  p_variant_id uuid,
  p_month date,
  p_matrix_version_id uuid,
  p_role_id uuid,
  p_source_schedule_id uuid,
  p_source_role_schedule_id uuid
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_date date;
  v_employee uuid;
  v_tier integer;
  v_created integer:=0;
  v_timezone text;
  v_default_available boolean;
  v_requested_tiers integer:=0;
begin
  if (p_source_schedule_id is null)=(p_source_role_schedule_id is null) then
    raise exception 'STANDBY_SOURCE_REQUIRED';
  end if;
  select coalesce(matrix.settings->>'timezone','Europe/Warsaw'),
    coalesce((matrix.settings->>'missingAvailabilityMeansAvailable')::boolean,true),
    least(2,greatest(0,coalesce(
      (matrix.settings->>'standbyTiersPerRoleDay')::integer,0)))
  into v_timezone,v_default_available,v_requested_tiers
  from public.matrix_versions matrix where matrix.id=p_matrix_version_id;
  if v_timezone is null then raise exception 'MATRIX_VERSION_NOT_FOUND'; end if;

  update public.published_standby_assignments_v2 standby set status='SUPERSEDED'
  where standby.month=p_month and standby.role_id=p_role_id
    and standby.status='PLANNED'
    and (standby.source_schedule_id is distinct from p_source_schedule_id
      or standby.source_role_schedule_id is distinct from p_source_role_schedule_id);
  if v_requested_tiers=0 then return 0; end if;

  for v_date in
    select distinct source.shift_date from (
      select shift_row.shift_date
      from public.plan_assignments_v2 assignment
      join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
      where assignment.variant_id=p_variant_id and assignment.role_id=p_role_id
      union
      select shift_row.shift_date
      from public.plan_issues_v2 issue
      join public.plan_shifts_v2 shift_row on shift_row.id=issue.shift_id
      where issue.variant_id=p_variant_id and issue.role_id=p_role_id
    ) source order by source.shift_date
  loop
    for v_tier in 1..v_requested_tiers loop
      v_employee:=null;
      with role_shifts as (
        select distinct shift_row.id,shift_row.location_id,shift_row.shift_template_id,
          shift_row.starts_at,shift_row.ends_at
        from public.plan_assignments_v2 assignment
        join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
        where assignment.variant_id=p_variant_id and assignment.role_id=p_role_id
          and shift_row.shift_date=v_date
        union
        select distinct shift_row.id,shift_row.location_id,shift_row.shift_template_id,
          shift_row.starts_at,shift_row.ends_at
        from public.plan_issues_v2 issue
        join public.plan_shifts_v2 shift_row on shift_row.id=issue.shift_id
        where issue.variant_id=p_variant_id and issue.role_id=p_role_id
          and shift_row.shift_date=v_date
      ), candidates as (
        select profile.employee_id,profile.employee_no,
          case when coalesce(hr.contract_type,'INNE') in ('ZLECENIE','B2B')
              and profile.work_time_policy<>'CUSTOM' then 0
            else coalesce(profile.minimum_rest_minutes,
              (select (matrix.settings->>'minimumRestMinutes')::integer
               from public.matrix_versions matrix where matrix.id=p_matrix_version_id),660)
          end rest_minutes
        from public.matrix_employee_profiles_v2 profile
        left join public.employee_hr_profiles hr on hr.employee_id=profile.employee_id
        where profile.matrix_version_id=p_matrix_version_id
          and profile.active and profile.archived_at is null
          and (profile.employment_start is null or profile.employment_start<=v_date)
          and (profile.employment_end is null or profile.employment_end>=v_date)
          and (not profile.no_weekends or extract(isodow from v_date) not in (6,7))
          and (not profile.only_morning or not exists(
            select 1 from role_shifts role_shift
            join public.matrix_shift_templates_v2 template
              on template.id=role_shift.shift_template_id
            where template.shift_period<>'MORNING'
          ))
          and (not profile.only_evening or not exists(
            select 1 from role_shifts role_shift
            join public.matrix_shift_templates_v2 template
              on template.id=role_shift.shift_template_id
            where template.shift_period<>'EVENING'
          ))
          and exists(select 1 from public.matrix_employee_roles_v2 role_grant
            where role_grant.matrix_version_id=p_matrix_version_id
              and role_grant.employee_id=profile.employee_id
              and role_grant.role_id=p_role_id and role_grant.active
              and (role_grant.valid_from is null or role_grant.valid_from<=v_date)
              and (role_grant.valid_to is null or role_grant.valid_to>=v_date))
          and not exists(select 1 from public.plan_assignments_v2 assignment
            join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
            where assignment.variant_id=p_variant_id
              and assignment.employee_id=profile.employee_id
              and shift_row.shift_date=v_date)
          and not exists(select 1 from public.published_role_schedules_v2 publication
            join public.plan_assignments_v2 assignment
              on assignment.variant_id=publication.variant_id
            join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
            where publication.month=p_month and publication.status='PUBLISHED'
              and assignment.employee_id=profile.employee_id
              and shift_row.shift_date=v_date)
          and not exists(select 1 from public.published_standby_assignments_v2 standby
            where standby.month=p_month and standby.standby_date=v_date
              and standby.employee_id=profile.employee_id
              and standby.status in ('PLANNED','ACTIVATED'))
          and not exists(select 1 from role_shifts role_shift
            where not exists(select 1 from public.matrix_employee_locations_v2 location_grant
              where location_grant.matrix_version_id=p_matrix_version_id
                and location_grant.employee_id=profile.employee_id
                and location_grant.location_id=role_shift.location_id
                and location_grant.active and location_grant.standard_allowed
                and (location_grant.valid_from is null or location_grant.valid_from<=v_date)
                and (location_grant.valid_to is null or location_grant.valid_to>=v_date)))
          and not exists(select 1 from role_shifts role_shift
            join public.employee_time_constraints_v2 constraint_row
              on constraint_row.employee_id=profile.employee_id
             and constraint_row.status='ACTIVE'
             and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
             and constraint_row.time_range
               && tstzrange(role_shift.starts_at,role_shift.ends_at,'[)'))
          and (v_default_available or exists(select 1
            from public.employee_time_constraints_v2 window_row
            where window_row.employee_id=profile.employee_id
              and window_row.status='ACTIVE'
              and window_row.constraint_kind='AVAILABLE_WINDOW'
              and lower(window_row.time_range)<=
                (select min(role_shift.starts_at) from role_shifts role_shift)
              and upper(window_row.time_range)>=
                (select max(role_shift.ends_at) from role_shifts role_shift)))
      ), ranked as (
        select candidate.employee_id,candidate.employee_no,
          (select count(*) from public.published_standby_assignments_v2 history
            where history.employee_id=candidate.employee_id and history.month=p_month
              and history.status not in ('CANCELLED','SUPERSEDED')) previous_standby
        from candidates candidate
        where not exists(select 1 from public.plan_assignments_v2 assignment
          join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
          where assignment.variant_id=p_variant_id
            and assignment.employee_id=candidate.employee_id
            and ((shift_row.ends_at<=(select min(starts_at) from role_shifts)
                and extract(epoch from ((select min(starts_at) from role_shifts)-shift_row.ends_at))/60<candidate.rest_minutes)
              or (shift_row.starts_at>=(select max(ends_at) from role_shifts)
                and extract(epoch from (shift_row.starts_at-(select max(ends_at) from role_shifts)))/60<candidate.rest_minutes)))
      )
      select ranked.employee_id into v_employee from ranked
      order by ranked.previous_standby,ranked.employee_no,ranked.employee_id limit 1;
      if v_employee is null then
        exit;
      end if;
      insert into public.published_standby_assignments_v2(
        month,standby_date,matrix_version_id,role_id,employee_id,tier,
        source_variant_id,source_schedule_id,source_role_schedule_id,created_by
      ) values(
        p_month,v_date,p_matrix_version_id,p_role_id,v_employee,v_tier,
        p_variant_id,p_source_schedule_id,p_source_role_schedule_id,auth.uid()
      );
      v_created:=v_created+1;
    end loop;
  end loop;
  return v_created;
end;
$$;

-- A standby decision is only safe if the employee still satisfies the hard
-- rules at the moment of activation.  Return all blockers so the operation is
-- atomic and the UI receives a precise, auditable failure instead of silently
-- replacing an assignment with an invalid one.
create or replace function solver_private.standby_activation_reasons_uat_v2(
  p_standby_id uuid,
  p_original_assignment_id uuid
) returns text[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_standby public.published_standby_assignments_v2%rowtype;
  v_assignment public.plan_assignments_v2%rowtype;
  v_shift public.plan_shifts_v2%rowtype;
  v_profile public.matrix_employee_profiles_v2%rowtype;
  v_reasons text[]:='{}'::text[];
  v_default_available boolean:=true;
  v_minutes integer:=0;
  v_month_minutes integer:=0;
  v_week_minutes integer:=0;
  v_rest integer:=0;
  v_before integer:=0;
  v_after integer:=0;
  v_enforce_work_time boolean:=true;
begin
  select * into v_standby from public.published_standby_assignments_v2
    where id=p_standby_id;
  if v_standby.id is null or v_standby.status<>'PLANNED' then
    return array['STANDBY_NOT_ACTIVATABLE'];
  end if;
  select * into v_assignment from public.plan_assignments_v2
    where id=p_original_assignment_id;
  select * into v_shift from public.plan_shifts_v2 where id=v_assignment.shift_id;
  if v_assignment.id is null or v_shift.id is null
    or v_assignment.role_id<>v_standby.role_id
    or v_shift.shift_date<>v_standby.standby_date then
    return array['STANDBY_TARGET_ASSIGNMENT_MISMATCH'];
  end if;
  select * into v_profile from public.matrix_employee_profiles_v2 profile
  where profile.matrix_version_id=v_standby.matrix_version_id
    and profile.employee_id=v_standby.employee_id
    and profile.active and profile.archived_at is null;
  if v_profile.id is null then
    v_reasons:=array_append(v_reasons,'EMPLOYEE_NOT_ACTIVE');
    return v_reasons;
  end if;
  select not (coalesce(hr.contract_type,'INNE') in ('ZLECENIE','B2B')
      and v_profile.work_time_policy<>'CUSTOM')
  into v_enforce_work_time
  from public.employee_hr_profiles hr
  where hr.employee_id=v_standby.employee_id;
  v_enforce_work_time:=coalesce(v_enforce_work_time,true);
  select coalesce((matrix.settings->>'missingAvailabilityMeansAvailable')::boolean,true)
  into v_default_available from public.matrix_versions matrix
  where matrix.id=v_standby.matrix_version_id;

  if not exists(select 1 from public.matrix_employee_roles_v2 role_grant
      where role_grant.matrix_version_id=v_standby.matrix_version_id
        and role_grant.employee_id=v_standby.employee_id
        and role_grant.role_id=v_assignment.role_id and role_grant.active
        and (role_grant.valid_from is null or role_grant.valid_from<=v_shift.shift_date)
        and (role_grant.valid_to is null or role_grant.valid_to>=v_shift.shift_date)) then
    v_reasons:=array_append(v_reasons,'ROLE_REQUIRED');
  end if;
  if not exists(select 1 from public.matrix_employee_locations_v2 location_grant
      where location_grant.matrix_version_id=v_standby.matrix_version_id
        and location_grant.employee_id=v_standby.employee_id
        and location_grant.location_id=v_shift.location_id
        and location_grant.active and location_grant.standard_allowed
        and (location_grant.valid_from is null or location_grant.valid_from<=v_shift.shift_date)
        and (location_grant.valid_to is null or location_grant.valid_to>=v_shift.shift_date)) then
    v_reasons:=array_append(v_reasons,'LOCATION_NOT_ALLOWED');
  end if;
  if exists(select 1 from public.plan_assignment_duties_v2 required_duty
      where required_duty.assignment_id=v_assignment.id and not exists(
        select 1 from public.matrix_employee_duties_v2 capability
        where capability.matrix_version_id=v_standby.matrix_version_id
          and capability.employee_id=v_standby.employee_id
          and capability.duty_id=required_duty.duty_id and capability.active
          and (capability.role_id is null or capability.role_id=v_standby.role_id)
          and (capability.location_id is null or capability.location_id=v_shift.location_id)
          and (capability.valid_from is null or capability.valid_from<=v_shift.shift_date)
          and (capability.valid_to is null or capability.valid_to>=v_shift.shift_date))) then
    v_reasons:=array_append(v_reasons,'DUTY_REQUIRED');
  end if;
  if exists(select 1 from public.employee_time_constraints_v2 constraint_row
      where constraint_row.employee_id=v_standby.employee_id
        and constraint_row.status='ACTIVE'
        and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
        and constraint_row.time_range&&tstzrange(v_shift.starts_at,v_shift.ends_at,'[)')) then
    v_reasons:=array_append(v_reasons,'HARD_UNAVAILABLE');
  end if;
  if not v_default_available and not exists(select 1
      from public.employee_time_constraints_v2 window_row
      where window_row.employee_id=v_standby.employee_id
        and window_row.status='ACTIVE'
        and window_row.constraint_kind='AVAILABLE_WINDOW'
        and lower(window_row.time_range)<=v_shift.starts_at
        and upper(window_row.time_range)>=v_shift.ends_at) then
    v_reasons:=array_append(v_reasons,'OUTSIDE_AVAILABILITY_WINDOW');
  end if;
  if (v_profile.employment_start is not null
      and v_profile.employment_start>v_shift.shift_date)
    or (v_profile.employment_end is not null
      and v_profile.employment_end<v_shift.shift_date) then
    v_reasons:=array_append(v_reasons,'OUTSIDE_EMPLOYMENT');
  end if;
  if v_profile.no_weekends and extract(isodow from v_shift.shift_date) in (6,7) then
    v_reasons:=array_append(v_reasons,'NO_WEEKENDS');
  end if;
  if v_profile.only_morning and exists(select 1
      from public.matrix_shift_templates_v2 template
      where template.id=v_shift.shift_template_id
        and template.shift_period<>'MORNING') then
    v_reasons:=array_append(v_reasons,'ONLY_MORNING');
  end if;
  if v_profile.only_evening and exists(select 1
      from public.matrix_shift_templates_v2 template
      where template.id=v_shift.shift_template_id
        and template.shift_period<>'EVENING') then
    v_reasons:=array_append(v_reasons,'ONLY_EVENING');
  end if;

  if exists(
    select 1 from public.plan_assignments_v2 other_assignment
    join public.plan_shifts_v2 other_shift on other_shift.id=other_assignment.shift_id
    left join public.operational_assignment_replacements_v2 replacement
      on replacement.original_assignment_id=other_assignment.id
     and replacement.status='ACTIVE'
    where other_assignment.employee_id=v_standby.employee_id
      and other_assignment.id<>v_assignment.id and replacement.id is null
      and other_shift.shift_date=v_shift.shift_date
      and solver_private.assignment_is_currently_published_v2(other_assignment.id)
    union all
    select 1 from public.operational_assignment_replacements_v2 replacement
    join public.plan_assignments_v2 original
      on original.id=replacement.original_assignment_id
    join public.plan_shifts_v2 other_shift on other_shift.id=original.shift_id
    where replacement.replacement_employee_id=v_standby.employee_id
      and replacement.status='ACTIVE' and original.id<>v_assignment.id
      and other_shift.shift_date=v_shift.shift_date
      and solver_private.assignment_is_currently_published_v2(original.id)
  ) then
    v_reasons:=array_append(v_reasons,'DAILY_SHIFT_LIMIT');
  end if;

  v_rest:=case when v_enforce_work_time
    then coalesce(v_profile.minimum_rest_minutes,0) else 0 end;
  if exists(
    with effective_shifts as (
      select other_assignment.id,other_shift.starts_at,other_shift.ends_at,
        other_shift.shift_date
      from public.plan_assignments_v2 other_assignment
      join public.plan_shifts_v2 other_shift on other_shift.id=other_assignment.shift_id
      left join public.operational_assignment_replacements_v2 replacement
        on replacement.original_assignment_id=other_assignment.id
       and replacement.status='ACTIVE'
      where other_assignment.employee_id=v_standby.employee_id
        and other_assignment.id<>v_assignment.id and replacement.id is null
        and solver_private.assignment_is_currently_published_v2(other_assignment.id)
      union all
      select original.id,other_shift.starts_at,other_shift.ends_at,
        other_shift.shift_date
      from public.operational_assignment_replacements_v2 replacement
      join public.plan_assignments_v2 original
        on original.id=replacement.original_assignment_id
      join public.plan_shifts_v2 other_shift on other_shift.id=original.shift_id
      where replacement.replacement_employee_id=v_standby.employee_id
        and replacement.status='ACTIVE' and original.id<>v_assignment.id
        and solver_private.assignment_is_currently_published_v2(original.id)
    )
    select 1 from effective_shifts other_shift
    where other_shift.ends_at+(v_rest*interval '1 minute')>v_shift.starts_at
      and v_shift.ends_at+(v_rest*interval '1 minute')>other_shift.starts_at
  ) then
    v_reasons:=array_append(v_reasons,'SHIFT_OR_REST_CONFLICT');
  end if;

  v_minutes:=greatest(0,round(extract(epoch from(v_shift.ends_at-v_shift.starts_at))/60)::integer);
  with effective_shifts as (
    select other_shift.shift_date,other_shift.starts_at,other_shift.ends_at
    from public.plan_assignments_v2 other_assignment
    join public.plan_shifts_v2 other_shift on other_shift.id=other_assignment.shift_id
    left join public.operational_assignment_replacements_v2 replacement
      on replacement.original_assignment_id=other_assignment.id
     and replacement.status='ACTIVE'
    where other_assignment.employee_id=v_standby.employee_id
      and other_assignment.id<>v_assignment.id and replacement.id is null
      and solver_private.assignment_is_currently_published_v2(other_assignment.id)
    union all
    select other_shift.shift_date,other_shift.starts_at,other_shift.ends_at
    from public.operational_assignment_replacements_v2 replacement
    join public.plan_assignments_v2 original
      on original.id=replacement.original_assignment_id
    join public.plan_shifts_v2 other_shift on other_shift.id=original.shift_id
    where replacement.replacement_employee_id=v_standby.employee_id
      and replacement.status='ACTIVE' and original.id<>v_assignment.id
      and solver_private.assignment_is_currently_published_v2(original.id)
  )
  select coalesce(sum(round(extract(epoch from(ends_at-starts_at))/60))
      filter(where shift_date>=v_standby.month
        and shift_date<(v_standby.month+interval '1 month')::date),0)::integer,
    coalesce(sum(round(extract(epoch from(ends_at-starts_at))/60))
      filter(where date_trunc('week',shift_date)=date_trunc('week',v_shift.shift_date)),0)::integer
  into v_month_minutes,v_week_minutes from effective_shifts;
  if v_enforce_work_time and v_profile.maximum_monthly_minutes>0
    and v_month_minutes+v_minutes>v_profile.maximum_monthly_minutes then
    v_reasons:=array_append(v_reasons,'MAXIMUM_MONTHLY_HOURS');
  end if;
  if v_enforce_work_time and v_profile.maximum_weekly_minutes>0
    and v_week_minutes+v_minutes>v_profile.maximum_weekly_minutes then
    v_reasons:=array_append(v_reasons,'MAXIMUM_WEEKLY_HOURS');
  end if;

  with recursive effective_days as (
    select distinct other_shift.shift_date
    from public.plan_assignments_v2 other_assignment
    join public.plan_shifts_v2 other_shift on other_shift.id=other_assignment.shift_id
    left join public.operational_assignment_replacements_v2 replacement
      on replacement.original_assignment_id=other_assignment.id
     and replacement.status='ACTIVE'
    where other_assignment.employee_id=v_standby.employee_id
      and other_assignment.id<>v_assignment.id and replacement.id is null
      and solver_private.assignment_is_currently_published_v2(other_assignment.id)
    union
    select distinct other_shift.shift_date
    from public.operational_assignment_replacements_v2 replacement
    join public.plan_assignments_v2 original
      on original.id=replacement.original_assignment_id
    join public.plan_shifts_v2 other_shift on other_shift.id=original.shift_id
    where replacement.replacement_employee_id=v_standby.employee_id
      and replacement.status='ACTIVE' and original.id<>v_assignment.id
      and solver_private.assignment_is_currently_published_v2(original.id)
  ), before_days(n,work_date) as (
    select 1,v_shift.shift_date-1
    where exists(select 1 from effective_days where shift_date=v_shift.shift_date-1)
    union all
    select before_days.n+1,before_days.work_date-1 from before_days
    where before_days.n<31 and exists(select 1 from effective_days
      where shift_date=before_days.work_date-1)
  ), after_days(n,work_date) as (
    select 1,v_shift.shift_date+1
    where exists(select 1 from effective_days where shift_date=v_shift.shift_date+1)
    union all
    select after_days.n+1,after_days.work_date+1 from after_days
    where after_days.n<31 and exists(select 1 from effective_days
      where shift_date=after_days.work_date+1)
  )
  select coalesce((select max(n) from before_days),0),
    coalesce((select max(n) from after_days),0)
  into v_before,v_after;
  if v_enforce_work_time and v_profile.maximum_consecutive_days>0
    and v_before+1+v_after>v_profile.maximum_consecutive_days then
    v_reasons:=array_append(v_reasons,'MAX_CONSECUTIVE_DAYS');
  end if;
  return v_reasons;
end;
$$;

create or replace function public.standby_activate_uat_v2(
  p_standby_id uuid,
  p_original_assignment_id uuid,
  p_reason text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_standby public.published_standby_assignments_v2%rowtype;
  v_assignment public.plan_assignments_v2%rowtype;
  v_shift public.plan_shifts_v2%rowtype;
  v_reasons text[];
  v_id uuid:=gen_random_uuid();
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  if length(trim(coalesce(p_reason,'')))<3 then raise exception 'ACTIVATION_REASON_REQUIRED'; end if;
  select * into v_standby from public.published_standby_assignments_v2
    where id=p_standby_id for update;
  if v_standby.id is null or v_standby.status<>'PLANNED' then
    raise exception 'STANDBY_NOT_ACTIVATABLE';
  end if;
  if v_standby.tier=2 and exists(select 1
    from public.published_standby_assignments_v2 tier1
    where tier1.month=v_standby.month and tier1.standby_date=v_standby.standby_date
      and tier1.role_id=v_standby.role_id and tier1.tier=1
      and tier1.status='PLANNED') then
    raise exception 'STANDBY_TIER_1_MUST_BE_USED_OR_DECLINED_FIRST';
  end if;
  select * into v_assignment from public.plan_assignments_v2
    where id=p_original_assignment_id;
  select * into v_shift from public.plan_shifts_v2 where id=v_assignment.shift_id;
  v_reasons:=solver_private.standby_activation_reasons_uat_v2(
    p_standby_id,p_original_assignment_id
  );
  if cardinality(v_reasons)>0 then
    raise exception 'STANDBY_REVALIDATION_FAILED:%',array_to_string(v_reasons,',');
  end if;
  if exists(select 1 from public.operational_assignment_replacements_v2 replacement
    where replacement.original_assignment_id=p_original_assignment_id
      and replacement.status='ACTIVE') then
    raise exception 'ASSIGNMENT_ALREADY_REPLACED';
  end if;
  insert into public.operational_assignment_replacements_v2(
    id,month,original_assignment_id,replacement_employee_id,
    standby_assignment_id,reason,created_by
  ) values(
    v_id,v_standby.month,p_original_assignment_id,v_standby.employee_id,
    v_standby.id,trim(p_reason),auth.uid()
  );
  update public.published_standby_assignments_v2 standby set
    status='ACTIVATED',activated_shift_id=v_shift.id,
    activated_assignment_id=p_original_assignment_id,
    activated_at=now(),activated_by=auth.uid(),activation_reason=trim(p_reason)
  where standby.id=v_standby.id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'standby_assignment_v2',v_standby.id::text,'ACTIVATE',
    jsonb_build_object('replacementId',v_id,'originalAssignmentId',p_original_assignment_id,
      'tier',v_standby.tier,'reason',trim(p_reason),'hardRulesRevalidated',true));
  return jsonb_build_object('standbyId',v_standby.id,'replacementId',v_id,
    'status','ACTIVATED','tier',v_standby.tier);
end;
$$;

revoke all on function solver_private.generate_standby_for_variant_uat_v2(
  uuid,date,uuid,uuid,uuid,uuid
),solver_private.standby_activation_reasons_uat_v2(uuid,uuid),
  public.standby_activate_uat_v2(uuid,uuid,text)
from public,anon,authenticated;
grant execute on function public.standby_activate_uat_v2(uuid,uuid,text)
to authenticated;

notify pgrst,'reload schema';
