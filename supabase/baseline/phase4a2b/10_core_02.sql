-- Generated Phase 4A.2B neutral schema baseline.
-- Apply only to a fresh, isolated Supabase project through the reviewed runner.

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: matrix_v2_publication_readiness_alpha16("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_publication_readiness_alpha16"("p_effective_from" "date" DEFAULT CURRENT_DATE) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_matrix uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  select mv.id into v_matrix from public.matrix_versions mv
  where mv.status='DRAFT' and mv.schema_version>=2
  order by mv.version desc limit 1;
  if v_matrix is null then raise exception 'NO_MATRIX_V2_DRAFT'; end if;
  return jsonb_build_object(
    'ready',not exists(
      select 1 from public.matrix_employee_profiles_v2 profile
      where profile.matrix_version_id=v_matrix and profile.active and (
        not exists(select 1 from public.employee_pay_rates_v2 rate
          where rate.employee_id=profile.employee_id and rate.active
            and rate.valid_from<=p_effective_from
            and (rate.valid_to is null or rate.valid_to>=p_effective_from))
        or not exists(select 1 from public.matrix_employee_roles_v2 role_grant
          where role_grant.matrix_version_id=v_matrix
            and role_grant.employee_id=profile.employee_id and role_grant.active)
        or not exists(select 1 from public.matrix_employee_locations_v2 location_grant
          where location_grant.matrix_version_id=v_matrix
            and location_grant.employee_id=profile.employee_id
            and location_grant.active and location_grant.standard_allowed)
      )
    ),
    'blockers',coalesce((
      select jsonb_agg(blocker order by blocker->>'employeeNo',blocker->>'code')
      from (
        select jsonb_build_object(
          'code','MISSING_PAY_RATE','employeeId',profile.employee_id,
          'employeeNo',profile.employee_no,
          'employeeName',profile.first_name||' '||profile.last_name,
          'message','Brak aktywnej stawki na dzień publikacji.'
        ) blocker
        from public.matrix_employee_profiles_v2 profile
        where profile.matrix_version_id=v_matrix and profile.active
          and not exists(select 1 from public.employee_pay_rates_v2 rate
            where rate.employee_id=profile.employee_id and rate.active
              and rate.valid_from<=p_effective_from
              and (rate.valid_to is null or rate.valid_to>=p_effective_from))
        union all
        select jsonb_build_object(
          'code','MISSING_ROLE','employeeId',profile.employee_id,
          'employeeNo',profile.employee_no,
          'employeeName',profile.first_name||' '||profile.last_name,
          'message','Brak aktywnej roli w Matrixie.'
        )
        from public.matrix_employee_profiles_v2 profile
        where profile.matrix_version_id=v_matrix and profile.active
          and not exists(select 1 from public.matrix_employee_roles_v2 role_grant
            where role_grant.matrix_version_id=v_matrix
              and role_grant.employee_id=profile.employee_id and role_grant.active)
        union all
        select jsonb_build_object(
          'code','MISSING_STANDARD_LOCATION','employeeId',profile.employee_id,
          'employeeNo',profile.employee_no,
          'employeeName',profile.first_name||' '||profile.last_name,
          'message','Brak co najmniej jednego lokalu pracy w zwykłym limicie.'
        )
        from public.matrix_employee_profiles_v2 profile
        where profile.matrix_version_id=v_matrix and profile.active
          and not exists(select 1 from public.matrix_employee_locations_v2 location_grant
            where location_grant.matrix_version_id=v_matrix
              and location_grant.employee_id=profile.employee_id
              and location_grant.active and location_grant.standard_allowed)
      ) problems
    ),'[]'::jsonb),
    'effectiveFrom',p_effective_from,'matrixVersionId',v_matrix
  );
end;
$$;


ALTER FUNCTION "public"."matrix_v2_publication_readiness_alpha16"("p_effective_from" "date") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_publication_readiness_alpha16"("p_effective_from" "date"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_publication_readiness_alpha16"("p_effective_from" "date") IS 'Polish, actionable Matrix publication preflight; does not mutate data.';


--
-- Name: matrix_v2_publication_readiness_base_uat006("date", "date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_publication_readiness_base_uat006"("p_effective_from" "date", "p_schedule_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_matrix uuid;
  v_month date:=date_trunc('month',coalesce(p_schedule_month,p_effective_from,current_date))::date;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  select mv.id into v_matrix from public.matrix_versions mv
  where mv.status='DRAFT' and mv.schema_version>=2
  order by mv.version desc limit 1;
  if v_matrix is null then raise exception 'NO_MATRIX_V2_DRAFT'; end if;

  return jsonb_build_object(
    'ready',not exists(
      select 1 from public.matrix_employee_profiles_v2 profile
      where profile.matrix_version_id=v_matrix and profile.active
        and coalesce(profile.employment_start,v_month)<v_month+interval '1 month'
        and coalesce(profile.employment_end,v_month)>=v_month
        and (
          not solver_private.employee_pay_rate_covers_period_v2(
            profile.employee_id,
            greatest(v_month,coalesce(profile.employment_start,v_month)),
            least((v_month+interval '1 month'-interval '1 day')::date,
              coalesce(profile.employment_end,(v_month+interval '1 month'-interval '1 day')::date))
          )
          or not exists(select 1 from public.matrix_employee_roles_v2 role_grant
            where role_grant.matrix_version_id=v_matrix
              and role_grant.employee_id=profile.employee_id and role_grant.active)
          or not exists(select 1 from public.matrix_employee_locations_v2 location_grant
            where location_grant.matrix_version_id=v_matrix
              and location_grant.employee_id=profile.employee_id
              and location_grant.active and location_grant.standard_allowed)
        )
    ) and not exists(
      select 1 from public.matrix_shift_templates_v2 shift_row
      where shift_row.matrix_version_id=v_matrix and shift_row.active
        and shift_row.shift_period is distinct from case
          when upper(shift_row.code) like 'RANO%' then 'MORNING'
          when upper(shift_row.code) like 'SRODEK%'
            or upper(shift_row.code) like 'ŚRODEK%' then 'MIDDLE'
          when upper(shift_row.code) like 'WIECZOR%'
            or upper(shift_row.code) like 'WIECZÓR%' then 'EVENING'
          else shift_row.shift_period
        end
    ),
    'blockers',coalesce((
      select jsonb_agg(blocker order by blocker->>'employeeNo',blocker->>'code')
      from (
        select jsonb_build_object(
          'code','MISSING_PAY_RATE','employeeId',profile.employee_id,
          'employeeNo',profile.employee_no,
          'employeeName',profile.first_name||' '||profile.last_name,
          'requiredFrom',greatest(v_month,coalesce(profile.employment_start,v_month)),
          'requiredTo',least((v_month+interval '1 month'-interval '1 day')::date,
            coalesce(profile.employment_end,(v_month+interval '1 month'-interval '1 day')::date)),
          'foundRates',coalesce((
            select jsonb_agg(jsonb_build_object(
              'validFrom',rate.valid_from,'validTo',rate.valid_to,
              'amountMinor',rate.base_rate_minor,'currency',rate.currency
            ) order by rate.valid_from)
            from public.employee_pay_rates_v2 rate
            where rate.employee_id=profile.employee_id and rate.active
          ),'[]'::jsonb),
          'message','Brak ciągłej aktywnej stawki dla całego okresu pracy w miesiącu grafiku.'
        ) blocker
        from public.matrix_employee_profiles_v2 profile
        where profile.matrix_version_id=v_matrix and profile.active
          and coalesce(profile.employment_start,v_month)<v_month+interval '1 month'
          and coalesce(profile.employment_end,v_month)>=v_month
          and not solver_private.employee_pay_rate_covers_period_v2(
            profile.employee_id,
            greatest(v_month,coalesce(profile.employment_start,v_month)),
            least((v_month+interval '1 month'-interval '1 day')::date,
              coalesce(profile.employment_end,(v_month+interval '1 month'-interval '1 day')::date))
          )
        union all
        select jsonb_build_object(
          'code','MISSING_ROLE','employeeId',profile.employee_id,
          'employeeNo',profile.employee_no,
          'employeeName',profile.first_name||' '||profile.last_name,
          'message','Brak aktywnej roli w Matrixie.'
        )
        from public.matrix_employee_profiles_v2 profile
        where profile.matrix_version_id=v_matrix and profile.active
          and coalesce(profile.employment_start,v_month)<v_month+interval '1 month'
          and coalesce(profile.employment_end,v_month)>=v_month
          and not exists(select 1 from public.matrix_employee_roles_v2 role_grant
            where role_grant.matrix_version_id=v_matrix
              and role_grant.employee_id=profile.employee_id and role_grant.active)
        union all
        select jsonb_build_object(
          'code','MISSING_STANDARD_LOCATION','employeeId',profile.employee_id,
          'employeeNo',profile.employee_no,
          'employeeName',profile.first_name||' '||profile.last_name,
          'message','Brak co najmniej jednego zwykłego lokalu pracy.'
        )
        from public.matrix_employee_profiles_v2 profile
        where profile.matrix_version_id=v_matrix and profile.active
          and coalesce(profile.employment_start,v_month)<v_month+interval '1 month'
          and coalesce(profile.employment_end,v_month)>=v_month
          and not exists(select 1 from public.matrix_employee_locations_v2 location_grant
            where location_grant.matrix_version_id=v_matrix
              and location_grant.employee_id=profile.employee_id
              and location_grant.active and location_grant.standard_allowed)
        union all
        select jsonb_build_object(
          'code','SHIFT_PERIOD_MISMATCH','shiftTemplateId',shift_row.id,
          'shiftName',shift_row.name,'shiftCode',shift_row.code,
          'storedPeriod',shift_row.shift_period,
          'expectedPeriod',case
            when upper(shift_row.code) like 'RANO%' then 'MORNING'
            when upper(shift_row.code) like 'SRODEK%'
              or upper(shift_row.code) like 'ŚRODEK%' then 'MIDDLE'
            when upper(shift_row.code) like 'WIECZOR%'
              or upper(shift_row.code) like 'WIECZÓR%' then 'EVENING'
          end,
          'message','Pora zmiany jest niespójna z jej jednoznacznym kodem.'
        )
        from public.matrix_shift_templates_v2 shift_row
        where shift_row.matrix_version_id=v_matrix and shift_row.active
          and shift_row.shift_period is distinct from case
            when upper(shift_row.code) like 'RANO%' then 'MORNING'
            when upper(shift_row.code) like 'SRODEK%'
              or upper(shift_row.code) like 'ŚRODEK%' then 'MIDDLE'
            when upper(shift_row.code) like 'WIECZOR%'
              or upper(shift_row.code) like 'WIECZÓR%' then 'EVENING'
            else shift_row.shift_period
          end
      ) problems
    ),'[]'::jsonb),
    'effectiveFrom',coalesce(p_effective_from,current_date),
    'scheduleMonth',v_month,
    'matrixVersionId',v_matrix
  );
end;
$$;


ALTER FUNCTION "public"."matrix_v2_publication_readiness_base_uat006"("p_effective_from" "date", "p_schedule_month" "date") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_publication_readiness_base_uat006"("p_effective_from" "date", "p_schedule_month" "date"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_publication_readiness_base_uat006"("p_effective_from" "date", "p_schedule_month" "date") IS 'Checks Matrix publication integrity against the schedule month, not the wall-clock publication day.';


--
-- Name: matrix_v2_publication_readiness_before_b4f115("date", "date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_publication_readiness_before_b4f115"("p_effective_from" "date", "p_schedule_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_base jsonb;
  v_matrix uuid;
  v_extra jsonb := '[]'::jsonb;
  v_blockers jsonb := '[]'::jsonb;
begin
  v_base := public.matrix_v2_publication_readiness_before_simple_roles_uat_v1(
    p_effective_from,
    p_schedule_month
  );
  v_matrix := nullif(v_base->>'matrixVersionId','')::uuid;

  select coalesce(jsonb_agg(problem order by employee_no),'[]'::jsonb)
  into v_extra
  from (
    select employee.employee_no,
      jsonb_build_object(
        'code','EMPLOYEE_PRIMARY_ROLE_REQUIRED',
        'employeeId',profile.employee_id,
        'employeeNo',employee.employee_no,
        'employeeName',trim(employee.first_name||' '||employee.last_name),
        'message',format(
          '%s (%s) nie ma dokładnie jednej aktywnej roli podstawowej. Przejdź do Zespół → Role i wybierz rolę podstawową.',
          trim(employee.first_name||' '||employee.last_name),
          employee.employee_no
        )
      ) problem
    from public.matrix_employee_profiles_v2 profile
    join public.employees employee on employee.id = profile.employee_id
    where profile.matrix_version_id = v_matrix
      and profile.active
      and profile.archived_at is null
      and (
        select count(*)
        from public.matrix_employee_roles_v2 role_link
        where role_link.matrix_version_id = profile.matrix_version_id
          and role_link.employee_id = profile.employee_id
          and role_link.active
          and role_link.is_primary
      ) <> 1
  ) invalid_profiles;

  v_blockers := coalesce(v_base->'blockers','[]'::jsonb) || v_extra;
  return v_base || jsonb_build_object(
    'ready',jsonb_array_length(v_blockers) = 0,
    'blockers',v_blockers
  );
end;
$$;


ALTER FUNCTION "public"."matrix_v2_publication_readiness_before_b4f115"("p_effective_from" "date", "p_schedule_month" "date") OWNER TO "postgres";

--
-- Name: matrix_v2_publication_readiness_before_simple_roles_uat_v1("date", "date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_publication_readiness_before_simple_roles_uat_v1"("p_effective_from" "date", "p_schedule_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_base jsonb;
  v_matrix uuid;
  v_extra jsonb := '[]'::jsonb;
  v_base_blockers jsonb := '[]'::jsonb;
  v_all_blockers jsonb := '[]'::jsonb;
begin
  v_base := public.matrix_v2_publication_readiness_base_uat006(p_effective_from,p_schedule_month);
  v_matrix := nullif(v_base->>'matrixVersionId','')::uuid;

  select coalesce(jsonb_agg(value),'[]'::jsonb) into v_base_blockers
  from jsonb_array_elements(coalesce(v_base->'blockers','[]'::jsonb))
  where value->>'code' <> 'SHIFT_PERIOD_MISMATCH';

  select coalesce(jsonb_agg(problem),'[]'::jsonb) into v_extra
  from (
    select jsonb_build_object(
      'code','REQUIRED_DUTY_WITH_ZERO_MINIMUM','roleId',link.role_id,
      'dutyId',link.duty_id,'message',
      'Obowiązek wymagany musi mieć minimalną liczbę co najmniej 1.'
    ) problem
    from public.matrix_role_duties_v2 link
    where link.matrix_version_id=v_matrix and link.active
      and link.assignment_mode='REQUIRED' and link.minimum_count<1
    union all
    select jsonb_build_object(
      'code','STAFFING_DUTY_NOT_LINKED_TO_ROLE','roleId',rule.role_id,
      'dutyId',rule.duty_id,'shiftTemplateId',rule.shift_template_id,
      'message','Reguła obsady używa obowiązku nieprzypisanego do tej roli.'
    )
    from public.matrix_staffing_rules_v2 rule
    where rule.matrix_version_id=v_matrix and rule.active and rule.duty_id is not null
      and not exists(select 1 from public.matrix_role_duties_v2 link
        where link.matrix_version_id=rule.matrix_version_id
          and link.role_id=rule.role_id and link.duty_id=rule.duty_id and link.active)
    union all
    select jsonb_build_object(
      'code','INACTIVE_DUTY_HAS_ACTIVE_DEPENDENCIES','dutyId',duty.id,
      'message','Wyłączony obowiązek nadal ma aktywne zależności.'
    )
    from public.matrix_duties_v2 duty
    where duty.matrix_version_id=v_matrix and not duty.active and (
      exists(select 1 from public.matrix_role_duties_v2 link where link.matrix_version_id=v_matrix and link.duty_id=duty.id and link.active)
      or exists(select 1 from public.matrix_employee_duties_v2 link where link.matrix_version_id=v_matrix and link.duty_id=duty.id and link.active)
      or exists(select 1 from public.matrix_staffing_rules_v2 rule where rule.matrix_version_id=v_matrix and rule.duty_id=duty.id and rule.active)
    )
    union all
    select jsonb_build_object(
      'code','SHIFT_PERIOD_FROM_TIME_MISMATCH','shiftTemplateId',shift_row.id,
      'shiftName',shift_row.name,'shiftCode',shift_row.code,
      'message','Automatyczna klasyfikacja zmiany jest niespójna z godziną rozpoczęcia.'
    )
    from public.matrix_shift_templates_v2 shift_row
    where shift_row.matrix_version_id=v_matrix and shift_row.active
      and shift_row.shift_period is distinct from case
        when extract(hour from shift_row.starts_at)<12 then 'MORNING'
        when extract(hour from shift_row.starts_at)<17 then 'MIDDLE'
        else 'EVENING' end
    union all
    select jsonb_build_object(
      'code','SHIFT_OVERNIGHT_FLAG_INCONSISTENT',
      'shiftTemplateId',shift_row.id,'shiftCode',shift_row.code,
      'shiftName',shift_row.name,'locationId',shift_row.location_id,
      'startsAt',to_char(shift_row.starts_at,'HH24:MI'),
      'endsAt',to_char(shift_row.ends_at,'HH24:MI'),
      'endsNextDay',shift_row.ends_next_day,
      'expectedEndsNextDay',(shift_row.ends_at<=shift_row.starts_at),
      'message',format(
        '%s (%s–%s): pole „Następny dzień” powinno mieć wartość %s.',
        shift_row.name,to_char(shift_row.starts_at,'HH24:MI'),
        to_char(shift_row.ends_at,'HH24:MI'),
        case when shift_row.ends_at<=shift_row.starts_at then 'TAK' else 'NIE' end
      )
    )
    from public.matrix_shift_templates_v2 shift_row
    where shift_row.matrix_version_id=v_matrix and shift_row.active
      and shift_row.ends_next_day is distinct from (shift_row.ends_at<=shift_row.starts_at)
  ) problems;

  v_all_blockers:=v_base_blockers||v_extra;
  return v_base||jsonb_build_object(
    'ready',jsonb_array_length(v_all_blockers)=0,
    'blockers',v_all_blockers
  );
end;
$$;


ALTER FUNCTION "public"."matrix_v2_publication_readiness_before_simple_roles_uat_v1"("p_effective_from" "date", "p_schedule_month" "date") OWNER TO "postgres";

--
-- Name: matrix_v2_publication_readiness_uat_v2("date", "date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_publication_readiness_uat_v2"("p_effective_from" "date", "p_schedule_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_base jsonb;
  v_matrix uuid;
  v_default_scenario uuid;
  v_shift_blockers jsonb:='[]'::jsonb;
  v_blockers jsonb:='[]'::jsonb;
begin
  v_base:=public.matrix_v2_publication_readiness_before_b4f115(p_effective_from,p_schedule_month);
  v_matrix:=nullif(v_base->>'matrixVersionId','')::uuid;
  select scenario.id into v_default_scenario
  from public.matrix_scenarios_v2 scenario
  where scenario.matrix_version_id=v_matrix and scenario.active and scenario.is_default
  order by scenario.sort_order,scenario.id limit 1;

  if v_default_scenario is not null then
    select coalesce(jsonb_agg(jsonb_build_object(
      'code','SHIFT_BASE_STAFFING_REQUIRED',
      'shiftTemplateId',shift_row.id,
      'shiftCode',shift_row.code,
      'shiftName',shift_row.name,
      'locationId',shift_row.location_id,
      'startsAt',to_char(shift_row.starts_at,'HH24:MI'),
      'endsAt',to_char(shift_row.ends_at,'HH24:MI'),
      'endsNextDay',shift_row.ends_next_day,
      'message',format('%s • %s • %s–%s: uzupełnij obsadę albo wyłącz zmianę.',location_row.name,shift_row.name,to_char(shift_row.starts_at,'HH24:MI'),to_char(shift_row.ends_at,'HH24:MI'))
    ) order by location_row.sort_order,shift_row.sort_order,shift_row.id),'[]'::jsonb)
    into v_shift_blockers
    from public.matrix_shift_templates_v2 shift_row
    join public.matrix_locations_v2 location_row
      on location_row.id=shift_row.location_id and location_row.matrix_version_id=shift_row.matrix_version_id
    where shift_row.matrix_version_id=v_matrix and shift_row.active
      and not exists(
        select 1 from public.matrix_staffing_rules_v2 staffing
        where staffing.matrix_version_id=v_matrix
          and staffing.scenario_id=v_default_scenario
          and staffing.shift_template_id=shift_row.id
          and staffing.active and staffing.operation='SET'
          and staffing.count_value>=1
      );
  end if;

  v_blockers:=coalesce(v_base->'blockers','[]'::jsonb)||v_shift_blockers;
  return v_base||jsonb_build_object('ready',jsonb_array_length(v_blockers)=0,'blockers',v_blockers);
end;
$$;


ALTER FUNCTION "public"."matrix_v2_publication_readiness_uat_v2"("p_effective_from" "date", "p_schedule_month" "date") OWNER TO "postgres";

--
-- Name: matrix_v2_publish_draft("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_publish_draft"("p_effective_from" "date" DEFAULT CURRENT_DATE) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_draft public.matrix_versions%rowtype;
  v_active public.matrix_versions%rowtype;
  v_default_count integer;
  v_cycle boolean;
  v_document jsonb;
  v_hash text;
  v_scenario record;
  v_active_strategy_count integer;
begin
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if p_effective_from is null then raise exception 'EFFECTIVE_FROM_REQUIRED'; end if;
  if p_effective_from>current_date then
    raise exception 'FUTURE_MATRIX_ACTIVATION_REQUIRES_SCHEDULER';
  end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));

  select * into v_draft from public.matrix_versions mv
  where mv.status='DRAFT' and mv.schema_version>=2
  order by mv.version desc limit 1 for update;
  if v_draft.id is null then raise exception 'NO_MATRIX_V2_DRAFT'; end if;
  select * into v_active from public.matrix_versions mv
  where mv.status='ACTIVE' order by mv.version desc limit 1 for update;
  if exists(select 1 from public.matrix_versions mv
      where mv.status='ACTIVE' and p_effective_from<mv.effective_from) then
    raise exception 'EFFECTIVE_FROM_PRECEDES_ACTIVE_MATRIX';
  end if;

  select count(*) into v_default_count from public.matrix_scenarios_v2 s
  where s.matrix_version_id=v_draft.id and s.active and s.is_default;
  if v_default_count<>1 then raise exception 'EXACTLY_ONE_ACTIVE_DEFAULT_SCENARIO_REQUIRED'; end if;
  if exists(select 1 from public.matrix_scenarios_v2 s
    where s.matrix_version_id=v_draft.id and s.active and s.is_default
      and s.parent_scenario_id is not null) then
    raise exception 'DEFAULT_SCENARIO_CANNOT_INHERIT';
  end if;

  if not exists(select 1 from public.matrix_roles_v2 x
      where x.matrix_version_id=v_draft.id and x.active)
    or not exists(select 1 from public.matrix_locations_v2 x
      where x.matrix_version_id=v_draft.id and x.active)
    or not exists(select 1 from public.matrix_shift_templates_v2 x
      where x.matrix_version_id=v_draft.id and x.active)
    or not exists(select 1 from public.matrix_strategies_v2 x
      where x.matrix_version_id=v_draft.id and x.active) then
    raise exception 'ACTIVE_ROLE_LOCATION_SHIFT_AND_STRATEGY_REQUIRED';
  end if;

  if exists(select 1 from public.matrix_locations_v2 l
    where l.matrix_version_id=v_draft.id
      and not exists(select 1 from pg_catalog.pg_timezone_names tz
        where tz.name=l.timezone)) then
    raise exception 'INVALID_LOCATION_TIMEZONE';
  end if;
  if exists(
    select 1 from public.matrix_shift_templates_v2 shift_row
    where shift_row.matrix_version_id=v_draft.id and shift_row.active
      and shift_row.ends_next_day is distinct from
        (shift_row.ends_at<=shift_row.starts_at)
  ) then raise exception 'SHIFT_OVERNIGHT_FLAG_INCONSISTENT'; end if;
  if not public.matrix_v2_is_iso_4217_currency(
    upper(coalesce(v_draft.settings->>'currency',''))
  ) then
    raise exception 'INVALID_MATRIX_CURRENCY';
  end if;
  if nullif(v_draft.settings->>'timezone','') is null or not exists(
    select 1 from pg_catalog.pg_timezone_names tz
    where tz.name=v_draft.settings->>'timezone'
  ) then raise exception 'INVALID_MATRIX_TIMEZONE'; end if;
  if coalesce(v_draft.settings->>'minimumRestMinutes','') !~ '^[0-9]+$'
    or (v_draft.settings->>'minimumRestMinutes')::integer<0
    or coalesce(v_draft.settings->>'maximumShiftsPerDay','') !~ '^[0-9]+$'
    or (v_draft.settings->>'maximumShiftsPerDay')::integer not between 1 and 24
    or jsonb_typeof(v_draft.settings->'missingAvailabilityMeansAvailable')<>'boolean'
    or jsonb_typeof(v_draft.settings->'requireOptimal')<>'boolean'
  then raise exception 'INVALID_MATRIX_SETTINGS'; end if;
  if exists(
    select 1 from public.matrix_scenarios_v2 s
    where s.matrix_version_id=v_draft.id and s.active and (
      jsonb_typeof(s.settings_overrides)<>'object'
      or s.settings_overrides-array[
        'timezone','minimumRestMinutes','maximumShiftsPerDay',
        'missingAvailabilityMeansAvailable','requireOptimal',
        'onlyMorningBeforeMinute','onlyEveningAfterMinute','randomSeed'
      ]<>'{}'::jsonb
      or (s.settings_overrides ? 'timezone' and (
        nullif(s.settings_overrides->>'timezone','') is null
        or not exists(select 1 from pg_catalog.pg_timezone_names tz
          where tz.name=s.settings_overrides->>'timezone')
      ))
      or (s.settings_overrides ? 'minimumRestMinutes' and (
        coalesce(s.settings_overrides->>'minimumRestMinutes','') !~ '^[0-9]+$'
        or (s.settings_overrides->>'minimumRestMinutes')::integer<0
      ))
      or (s.settings_overrides ? 'maximumShiftsPerDay' and (
        coalesce(s.settings_overrides->>'maximumShiftsPerDay','') !~ '^[0-9]+$'
        or (s.settings_overrides->>'maximumShiftsPerDay')::integer not between 1 and 24
      ))
      or (s.settings_overrides ? 'missingAvailabilityMeansAvailable'
        and jsonb_typeof(s.settings_overrides->'missingAvailabilityMeansAvailable')<>'boolean')
      or (s.settings_overrides ? 'requireOptimal'
        and jsonb_typeof(s.settings_overrides->'requireOptimal')<>'boolean')
      or (s.settings_overrides ? 'onlyMorningBeforeMinute' and (
        coalesce(s.settings_overrides->>'onlyMorningBeforeMinute','') !~ '^[0-9]+$'
        or (s.settings_overrides->>'onlyMorningBeforeMinute')::integer>2880
      ))
      or (s.settings_overrides ? 'onlyEveningAfterMinute' and (
        coalesce(s.settings_overrides->>'onlyEveningAfterMinute','') !~ '^[0-9]+$'
        or (s.settings_overrides->>'onlyEveningAfterMinute')::integer>2880
      ))
      or (s.settings_overrides ? 'randomSeed' and
        coalesce(s.settings_overrides->>'randomSeed','') !~ '^[0-9]+$')
    )
  ) then raise exception 'INVALID_SCENARIO_SETTINGS_OVERRIDE'; end if;
  if exists(
    select 1 from public.matrix_pay_rules_v2 p
    where p.matrix_version_id=v_draft.id and p.active
      and p.currency<>upper(v_draft.settings->>'currency')
  ) or exists(
    select 1 from public.matrix_scenario_budgets_v2 b
    where b.matrix_version_id=v_draft.id
      and b.currency<>upper(v_draft.settings->>'currency')
  ) or exists(
    select 1 from public.employee_pay_rates_v2 r
    join public.matrix_employee_profiles_v2 profile
      on profile.matrix_version_id=v_draft.id
      and profile.employee_id=r.employee_id and profile.active
    where r.active and r.valid_from<=p_effective_from
      and (r.valid_to is null or r.valid_to>=p_effective_from)
      and r.currency<>upper(v_draft.settings->>'currency')
  ) then raise exception 'MIXED_CURRENCIES_UNSUPPORTED'; end if;
  if exists(
    select 1 from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=v_draft.id and profile.active
      and not exists(
        select 1 from public.employee_pay_rates_v2 rate
        where rate.employee_id=profile.employee_id and rate.active
          and rate.valid_from<=p_effective_from
          and (rate.valid_to is null or rate.valid_to>=p_effective_from)
      )
  ) then raise exception 'ACTIVE_EMPLOYEE_REQUIRES_PAY_RATE'; end if;
  if exists(
    select 1 from public.matrix_pay_rules_v2 p
    where p.matrix_version_id=v_draft.id and p.active and (
      jsonb_typeof(p.condition_expression)<>'object'
      or p.condition_expression-array['conditions']<>'{}'::jsonb
      or (p.condition_expression ? 'conditions'
        and jsonb_typeof(p.condition_expression->'conditions')<>'array')
      or p.formula_expression<>'{}'::jsonb
      or (p.local_start is null)<>(p.local_end is null)
      or (
        case when p.local_start is null then 0 else 1 end
        +(select count(*) from jsonb_array_elements(
          coalesce(p.condition_expression->'conditions','[]'::jsonb)
        ) condition where lower(coalesce(condition.value->>'field',''))='local_time'
          and upper(coalesce(condition.value->>'operator',''))='OVERLAPS_TIME')
      )>1
      or (
        p.calculation_method in (
          'SHIFT_DURATION_THRESHOLD_PER_HOUR','MONTHLY_THRESHOLD_PER_HOUR'
        ) and (
          p.local_start is not null or exists(
            select 1 from jsonb_array_elements(
              coalesce(p.condition_expression->'conditions','[]'::jsonb)
            ) condition where lower(coalesce(condition.value->>'field',''))='local_time'
              and upper(coalesce(condition.value->>'operator',''))='OVERLAPS_TIME'
          )
        )
      )
      or (p.calculation_method='MULTIPLIER'
        and p.multiplier_basis_points<10000)
      or (p.calculation_method='FIXED_PER_SHIFT' and (
        p.rate_minor_per_hour is not null or p.percent_basis_points is not null
        or p.multiplier_basis_points is not null or p.threshold_minutes is not null
      ))
      or (p.calculation_method='PER_HOUR' and (
        p.amount_minor is not null or p.percent_basis_points is not null
        or p.multiplier_basis_points is not null or p.threshold_minutes is not null
      ))
      or (p.calculation_method='PERCENT_BASE' and (
        p.amount_minor is not null or p.rate_minor_per_hour is not null
        or p.multiplier_basis_points is not null or p.threshold_minutes is not null
      ))
      or (p.calculation_method='MULTIPLIER' and (
        p.amount_minor is not null or p.rate_minor_per_hour is not null
        or p.percent_basis_points is not null or p.threshold_minutes is not null
      ))
      or (p.calculation_method in (
        'SHIFT_DURATION_THRESHOLD_PER_HOUR','MONTHLY_THRESHOLD_PER_HOUR'
      ) and (
        p.amount_minor is not null or p.percent_basis_points is not null
        or p.multiplier_basis_points is not null
      ))
    )
  ) then raise exception 'INVALID_PAY_RULE_CONFIGURATION'; end if;
  if exists(
    select 1
    from public.matrix_pay_rules_v2 p
    cross join lateral jsonb_array_elements(
      coalesce(p.condition_expression->'conditions','[]'::jsonb)
    ) condition
    where p.matrix_version_id=v_draft.id and p.active
      and not public.matrix_v2_is_supported_pay_condition(condition.value)
  ) then raise exception 'UNSUPPORTED_PAY_RULE_CONDITION'; end if;
  if exists(
    select 1 from public.matrix_pay_rules_v2 left_rule
    join public.matrix_pay_rules_v2 right_rule
      on right_rule.matrix_version_id=left_rule.matrix_version_id
      and right_rule.id>left_rule.id and right_rule.active
      and coalesce(right_rule.stacking_group,right_rule.id::text)
        =coalesce(left_rule.stacking_group,left_rule.id::text)
      and right_rule.stacking_mode<>left_rule.stacking_mode
    where left_rule.matrix_version_id=v_draft.id and left_rule.active
  ) then raise exception 'INCONSISTENT_PAY_STACKING_GROUP'; end if;
  if exists(
    select 1 from public.matrix_scenario_pay_rule_overrides_v2 override
    join public.matrix_scenarios_v2 scenario
      on scenario.id=override.scenario_id and scenario.active
    join public.matrix_pay_rules_v2 rule
      on rule.id=override.pay_rule_id and rule.active
    where override.matrix_version_id=v_draft.id and (
      coalesce(override.formula_expression,'{}'::jsonb)<>'{}'::jsonb
      or (rule.calculation_method='FIXED_PER_SHIFT' and (
        override.rate_minor_per_hour is not null
        or override.percent_basis_points is not null
        or override.multiplier_basis_points is not null
      ))
      or (rule.calculation_method in (
        'PER_HOUR','SHIFT_DURATION_THRESHOLD_PER_HOUR',
        'MONTHLY_THRESHOLD_PER_HOUR'
      ) and (
        override.amount_minor is not null
        or override.percent_basis_points is not null
        or override.multiplier_basis_points is not null
      ))
      or (rule.calculation_method='PERCENT_BASE' and (
        override.amount_minor is not null or override.rate_minor_per_hour is not null
        or override.multiplier_basis_points is not null
      ))
      or (rule.calculation_method='MULTIPLIER' and (
        override.amount_minor is not null or override.rate_minor_per_hour is not null
        or override.percent_basis_points is not null
        or (override.multiplier_basis_points is not null
          and override.multiplier_basis_points<10000)
      ))
    )
  ) then raise exception 'INVALID_SCENARIO_PAY_RULE_OVERRIDE'; end if;
  if exists(select 1 from public.matrix_shift_templates_v2 s
    where s.matrix_version_id=v_draft.id
      and cardinality(s.day_mask)<>(select count(distinct d) from unnest(s.day_mask) d)) then
    raise exception 'SHIFT_DAY_MASK_CONTAINS_DUPLICATES';
  end if;

  with recursive walk(id,parent_scenario_id,path,cycle) as (
    select s.id,s.parent_scenario_id,array[s.id],false
    from public.matrix_scenarios_v2 s where s.matrix_version_id=v_draft.id
    union all
    select p.id,p.parent_scenario_id,w.path||p.id,p.id=any(w.path)
    from walk w join public.matrix_scenarios_v2 p on p.id=w.parent_scenario_id
    where not w.cycle
  ) select coalesce(bool_or(w.cycle),false) into v_cycle from walk w;
  if v_cycle then raise exception 'SCENARIO_INHERITANCE_CYCLE'; end if;
  if exists(
    with recursive chain as (
      select s.id,s.parent_scenario_id,0 depth
      from public.matrix_scenarios_v2 s
      where s.matrix_version_id=v_draft.id
      union all
      select parent.id,parent.parent_scenario_id,chain.depth+1
      from chain
      join public.matrix_scenarios_v2 parent
        on parent.id=chain.parent_scenario_id
        and parent.matrix_version_id=v_draft.id
      where chain.depth<32
    )
    select 1 from chain
    where chain.depth=32 and chain.parent_scenario_id is not null
  ) then raise exception 'SCENARIO_INHERITANCE_TOO_DEEP'; end if;
  if exists(select 1 from public.matrix_scenarios_v2 s
    join public.matrix_scenarios_v2 p on p.id=s.parent_scenario_id
    where s.matrix_version_id=v_draft.id and s.active and not p.active) then
    raise exception 'ACTIVE_SCENARIO_HAS_INACTIVE_PARENT';
  end if;

  if exists(
    select 1 from public.matrix_strategies_v2 s
    where s.matrix_version_id=v_draft.id and s.active and (
      upper(s.solver_code)<>'CP_SAT'
      or jsonb_typeof(s.solver_options)<>'object'
    )
  ) then raise exception 'UNSUPPORTED_STRATEGY_SOLVER_CONFIGURATION'; end if;
  if exists(
    select 1 from public.matrix_strategies_v2 s
    where s.matrix_version_id=v_draft.id and s.active and (
      s.solver_options-array['maxTimeSeconds','randomSeed']<>'{}'::jsonb
      or (s.solver_options ? 'maxTimeSeconds' and (
        coalesce(s.solver_options->>'maxTimeSeconds','') !~ '^[0-9]+$'
        or (s.solver_options->>'maxTimeSeconds')::integer not between 1 and 86400
      ))
      or (s.solver_options ? 'randomSeed' and (
        coalesce(s.solver_options->>'randomSeed','') !~ '^[0-9]+$'
        or (s.solver_options->>'randomSeed')::numeric>2147483647
      ))
    )
  ) then raise exception 'INVALID_STRATEGY_SOLVER_OPTIONS'; end if;

  if exists(
    select 1 from public.matrix_strategy_objectives_v2 o
    join public.matrix_strategies_v2 s on s.id=o.strategy_id and s.active
    where o.matrix_version_id=v_draft.id and o.active and (
      upper(o.metric_code) not in (
        'UNFILLED','TOTAL_COST','PREFERENCE_VIOLATIONS',
        'HOME_LOCATION_VIOLATIONS','NOMINAL_DEVIATION_MINUTES',
        'OVERTIME_MINUTES','LOAD_SPREAD_MINUTES','WEEKEND_SPREAD',
        'BASELINE_CHANGES','COST','TOTAL_COST_UNITS','PREFERENCES',
        'HOME_LOCATION','NOMINAL_DEVIATION','OVERTIME','LOAD_SPREAD',
        'BASELINE_CHANGES_COUNT','UNFILLED_SEATS','TOTAL_COST_MINOR',
        'WORKLOAD_VARIANCE','WEEKEND_VARIANCE','NON_HOME_LOCATION_COUNT'
      )
      or jsonb_typeof(o.parameters)<>'object'
    )
  ) then raise exception 'UNSUPPORTED_STRATEGY_OBJECTIVE'; end if;
  if exists(
    select 1 from public.matrix_strategy_objectives_v2 o
    join public.matrix_strategies_v2 s on s.id=o.strategy_id and s.active
    where o.matrix_version_id=v_draft.id and o.active and (
      o.parameters-array['target','targetValue']<>'{}'::jsonb
      or (o.parameters ? 'target' and o.parameters ? 'targetValue')
      or ((o.parameters ? 'target' or o.parameters ? 'targetValue') and (
        upper(o.direction)<>'MINIMIZE'
        or coalesce(o.parameters->>case when o.parameters ? 'targetValue'
          then 'targetValue' else 'target' end,'') !~ '^[0-9]+$'
      ))
    )
  ) then raise exception 'INVALID_STRATEGY_OBJECTIVE_PARAMETERS'; end if;

  if exists(
    select 1 from public.matrix_scenario_strategies_v2 ss
    join public.matrix_scenarios_v2 sc on sc.id=ss.scenario_id and sc.active
    join public.matrix_strategies_v2 st on st.id=ss.strategy_id and st.active
    where ss.matrix_version_id=v_draft.id and ss.active and (
      jsonb_typeof(ss.objective_overrides)<>'object'
      or jsonb_typeof(ss.solver_overrides)<>'object'
    )
  ) then raise exception 'INVALID_SCENARIO_STRATEGY_OVERRIDE'; end if;
  if exists(
    select 1
    from public.matrix_scenario_strategies_v2 ss
    join public.matrix_scenarios_v2 sc on sc.id=ss.scenario_id and sc.active
    join public.matrix_strategies_v2 st on st.id=ss.strategy_id and st.active
    cross join lateral jsonb_each(ss.objective_overrides) ov
    left join public.matrix_strategy_objectives_v2 objective
      on objective.strategy_id=ss.strategy_id
      and objective.metric_code=upper(ov.key) and objective.active
    where ss.matrix_version_id=v_draft.id and ss.active and (
      ov.key<>upper(ov.key)
      or objective.id is null
      or jsonb_typeof(ov.value)<>'object'
      or (ov.value ? 'parameters'
        and jsonb_typeof(ov.value->'parameters')<>'object')
    )
  ) then raise exception 'INVALID_SCENARIO_OBJECTIVE_OVERRIDE'; end if;
  if exists(
    select 1
    from public.matrix_scenario_strategies_v2 ss
    join public.matrix_scenarios_v2 sc on sc.id=ss.scenario_id and sc.active
    join public.matrix_strategies_v2 st on st.id=ss.strategy_id and st.active
    cross join lateral jsonb_each(ss.objective_overrides) ov
    join public.matrix_strategy_objectives_v2 objective
      on objective.strategy_id=ss.strategy_id
      and objective.metric_code=upper(ov.key) and objective.active
    where ss.matrix_version_id=v_draft.id and ss.active and (
      ov.value-array['active','tier','weight','direction','tolerance','parameters']
        <>'{}'::jsonb
      or (ov.value ? 'active' and jsonb_typeof(ov.value->'active')<>'boolean')
      or (ov.value ? 'tier' and (
        coalesce(ov.value->>'tier','') !~ '^[0-9]+$'
        or (ov.value->>'tier')::integer not between 1 and 100
      ))
      or (ov.value ? 'weight' and coalesce(ov.value->>'weight','') !~ '^[0-9]+$')
      or (ov.value ? 'tolerance'
        and coalesce(ov.value->>'tolerance','') !~ '^[0-9]+$')
      or (ov.value ? 'direction' and upper(ov.value->>'direction')
        not in ('MIN','MINIMIZE','MAX','MAXIMIZE'))
      or (
        (objective.parameters||coalesce(
          ov.value->'parameters','{}'::jsonb
        ))-array['target','targetValue']<>'{}'::jsonb
        or (
          (objective.parameters||coalesce(
            ov.value->'parameters','{}'::jsonb
          )) ? 'target'
          and (objective.parameters||coalesce(
            ov.value->'parameters','{}'::jsonb
          )) ? 'targetValue'
        )
        or (
          (
            (objective.parameters||coalesce(
              ov.value->'parameters','{}'::jsonb
            )) ? 'target'
            or (objective.parameters||coalesce(
              ov.value->'parameters','{}'::jsonb
            )) ? 'targetValue'
          ) and (
            case upper(coalesce(ov.value->>'direction',objective.direction))
              when 'MIN' then 'MINIMIZE'
              when 'MAX' then 'MAXIMIZE'
              else upper(coalesce(ov.value->>'direction',objective.direction))
            end <> 'MINIMIZE'
            or coalesce(
              (objective.parameters||coalesce(
                ov.value->'parameters','{}'::jsonb
              ))->>case when (objective.parameters||coalesce(
                ov.value->'parameters','{}'::jsonb
              )) ? 'targetValue' then 'targetValue' else 'target' end,
              ''
            ) !~ '^[0-9]+$'
          )
        )
      )
    )
  ) then raise exception 'INVALID_SCENARIO_OBJECTIVE_OVERRIDE'; end if;
  if exists(
    select 1 from public.matrix_scenario_strategies_v2 ss
    join public.matrix_scenarios_v2 sc on sc.id=ss.scenario_id and sc.active
    join public.matrix_strategies_v2 st on st.id=ss.strategy_id and st.active
    where ss.matrix_version_id=v_draft.id and ss.active and (
      ss.solver_overrides-array['maxTimeSeconds','randomSeed']<>'{}'::jsonb
      or (ss.solver_overrides ? 'maxTimeSeconds' and (
        coalesce(ss.solver_overrides->>'maxTimeSeconds','') !~ '^[0-9]+$'
        or (ss.solver_overrides->>'maxTimeSeconds')::integer not between 1 and 86400
      ))
      or (ss.solver_overrides ? 'randomSeed' and (
        coalesce(ss.solver_overrides->>'randomSeed','') !~ '^[0-9]+$'
        or (ss.solver_overrides->>'randomSeed')::numeric>2147483647
      ))
    )
  ) then raise exception 'INVALID_SCENARIO_SOLVER_OVERRIDE'; end if;

  -- Validate the exact inherited configuration emitted by the snapshot, not
  -- just each override row in isolation. A child may override direction while
  -- inheriting a target, or introduce the second target alias; both must fail
  -- at publication rather than in the worker.
  if exists(
    with recursive scenario_chain as (
      select scenario.id root_id,scenario.id,scenario.parent_scenario_id,0 depth
      from public.matrix_scenarios_v2 scenario
      where scenario.matrix_version_id=v_draft.id and scenario.active
      union all
      select chain.root_id,parent.id,parent.parent_scenario_id,chain.depth+1
      from scenario_chain chain
      join public.matrix_scenarios_v2 parent
        on parent.id=chain.parent_scenario_id
        and parent.matrix_version_id=v_draft.id
      where chain.depth<32
    ), raw_links as (
      select chain.root_id,chain.depth,link.id,link.strategy_id,
        link.active,link.objective_overrides
      from scenario_chain chain
      join public.matrix_scenario_strategies_v2 link
        on link.scenario_id=chain.id
        and link.matrix_version_id=v_draft.id
    ), resolved_links as (
      select link.root_id,link.strategy_id,
        (array_agg(link.active order by link.depth,link.id))[1] active,
        solver_private.jsonb_deep_merge_array_v2(array_agg(
          link.objective_overrides order by link.depth desc,link.id
        )) objective_overrides
      from raw_links link
      group by link.root_id,link.strategy_id
    )
    select 1
    from resolved_links resolved
    join public.matrix_strategies_v2 strategy
      on strategy.id=resolved.strategy_id and strategy.active
    join public.matrix_strategy_objectives_v2 objective
      on objective.strategy_id=resolved.strategy_id and objective.active
    cross join lateral (select coalesce(
      resolved.objective_overrides->upper(objective.metric_code),'{}'::jsonb
    ) value) override_config
    where resolved.active
      and coalesce((override_config.value->>'active')::boolean,true)
      and not public.matrix_v2_is_supported_objective_config(
        coalesce(override_config.value->>'direction',objective.direction),
        objective.parameters||coalesce(
          override_config.value->'parameters','{}'::jsonb
        )
      )
  ) then raise exception 'INVALID_RESOLVED_SCENARIO_OBJECTIVE'; end if;

  for v_scenario in
    select s.id from public.matrix_scenarios_v2 s
    where s.matrix_version_id=v_draft.id and s.active
  loop
    with recursive chain as (
      select s.id,s.parent_scenario_id,0 depth
      from public.matrix_scenarios_v2 s where s.id=v_scenario.id
      union all
      select parent.id,parent.parent_scenario_id,chain.depth+1
      from public.matrix_scenarios_v2 parent
      join chain on chain.parent_scenario_id=parent.id
      where parent.matrix_version_id=v_draft.id and chain.depth<32
    ), resolved as (
      select distinct on (ss.strategy_id) ss.strategy_id,ss.active,chain.depth
      from chain join public.matrix_scenario_strategies_v2 ss
        on ss.scenario_id=chain.id and ss.matrix_version_id=v_draft.id
      order by ss.strategy_id,chain.depth,ss.id
    )
    select count(*) into v_active_strategy_count
    from resolved r join public.matrix_strategies_v2 st
      on st.id=r.strategy_id and st.active
    where r.active;
    if v_active_strategy_count=0 then
      raise exception 'ACTIVE_SCENARIO_WITHOUT_ACTIVE_STRATEGY:%',v_scenario.id;
    end if;
  end loop;
  if exists(select 1 from public.matrix_strategies_v2 s
    where s.matrix_version_id=v_draft.id and s.active
      and not exists(select 1 from public.matrix_strategy_objectives_v2 o
        where o.strategy_id=s.id and o.active and o.tier=1 and o.metric_code='UNFILLED')) then
    raise exception 'ACTIVE_STRATEGY_REQUIRES_TIER1_UNFILLED_OBJECTIVE';
  end if;

  if exists(select 1 from public.matrix_staffing_rules_v2 x
    join public.matrix_scenarios_v2 sc on sc.id=x.scenario_id
    join public.matrix_shift_templates_v2 sh on sh.id=x.shift_template_id
    join public.matrix_roles_v2 r on r.id=x.role_id
    left join public.matrix_duties_v2 d on d.id=x.duty_id
    where x.matrix_version_id=v_draft.id and x.active
      and (not sc.active or not sh.active or not r.active
        or (x.duty_id is not null and not d.active))) then
    raise exception 'ACTIVE_STAFFING_RULE_REFERENCES_INACTIVE_SCOPE';
  end if;

  -- Publishing is the fail-closed boundary. Dormant rows may remain in a
  -- draft for editing history, but no active configuration may point at a
  -- role, duty, location or shift that the snapshot itself will omit.
  if exists(
    select 1 from public.matrix_shift_templates_v2 shift_row
    join public.matrix_locations_v2 location on location.id=shift_row.location_id
    where shift_row.matrix_version_id=v_draft.id and shift_row.active
      and not location.active
  ) then raise exception 'ACTIVE_SHIFT_REFERENCES_INACTIVE_LOCATION'; end if;
  if exists(
    select 1 from public.matrix_role_duties_v2 link
    join public.matrix_roles_v2 role on role.id=link.role_id
    join public.matrix_duties_v2 duty on duty.id=link.duty_id
    where link.matrix_version_id=v_draft.id and link.active
      and (not role.active or not duty.active)
  ) then raise exception 'ROLE_DUTY_REFERENCES_INACTIVE_SCOPE'; end if;
  if exists(
    select 1 from public.matrix_employee_roles_v2 grant_row
    join public.matrix_employee_profiles_v2 profile
      on profile.matrix_version_id=grant_row.matrix_version_id
      and profile.employee_id=grant_row.employee_id
    join public.matrix_roles_v2 role on role.id=grant_row.role_id
    where grant_row.matrix_version_id=v_draft.id and profile.active
      and grant_row.active and not role.active
  ) then raise exception 'EMPLOYEE_ROLE_REFERENCES_INACTIVE_ROLE'; end if;
  if exists(
    select 1 from public.matrix_employee_locations_v2 grant_row
    join public.matrix_employee_profiles_v2 profile
      on profile.matrix_version_id=grant_row.matrix_version_id
      and profile.employee_id=grant_row.employee_id
    join public.matrix_locations_v2 location on location.id=grant_row.location_id
    where grant_row.matrix_version_id=v_draft.id and profile.active
      and grant_row.active and not location.active
  ) then raise exception 'EMPLOYEE_LOCATION_REFERENCES_INACTIVE_LOCATION'; end if;
  if exists(
    select 1 from public.matrix_employee_duties_v2 grant_row
    join public.matrix_employee_profiles_v2 profile
      on profile.matrix_version_id=grant_row.matrix_version_id
      and profile.employee_id=grant_row.employee_id
    join public.matrix_duties_v2 duty on duty.id=grant_row.duty_id
    left join public.matrix_roles_v2 role on role.id=grant_row.role_id
    left join public.matrix_locations_v2 location on location.id=grant_row.location_id
    where grant_row.matrix_version_id=v_draft.id and profile.active
      and grant_row.active and (
        not duty.active
        or (grant_row.role_id is not null and not role.active)
        or (grant_row.location_id is not null and not location.active)
      )
  ) then raise exception 'EMPLOYEE_DUTY_REFERENCES_INACTIVE_SCOPE'; end if;
  if exists(
    select 1 from public.matrix_scenario_strategies_v2 link
    join public.matrix_scenarios_v2 scenario on scenario.id=link.scenario_id
    join public.matrix_strategies_v2 strategy on strategy.id=link.strategy_id
    where link.matrix_version_id=v_draft.id and scenario.active
      and link.active and not strategy.active
  ) then raise exception 'SCENARIO_REFERENCES_INACTIVE_STRATEGY'; end if;
  if exists(
    select 1 from public.matrix_pay_rules_v2 rule
    left join public.matrix_pay_rule_roles_v2 role_link on role_link.pay_rule_id=rule.id
    left join public.matrix_roles_v2 role on role.id=role_link.role_id
    left join public.matrix_pay_rule_duties_v2 duty_link on duty_link.pay_rule_id=rule.id
    left join public.matrix_duties_v2 duty on duty.id=duty_link.duty_id
    left join public.matrix_pay_rule_locations_v2 location_link
      on location_link.pay_rule_id=rule.id
    left join public.matrix_locations_v2 location on location.id=location_link.location_id
    left join public.matrix_pay_rule_shifts_v2 shift_link on shift_link.pay_rule_id=rule.id
    left join public.matrix_shift_templates_v2 shift_row
      on shift_row.id=shift_link.shift_template_id
    where rule.matrix_version_id=v_draft.id and rule.active and (
      (role_link.pay_rule_id is not null and not role.active)
      or (duty_link.pay_rule_id is not null and not duty.active)
      or (location_link.pay_rule_id is not null and not location.active)
      or (shift_link.pay_rule_id is not null and not shift_row.active)
    )
  ) then raise exception 'PAY_RULE_REFERENCES_INACTIVE_SCOPE'; end if;
  if exists(
    select 1 from public.matrix_scenario_budgets_v2 budget
    join public.matrix_scenarios_v2 scenario on scenario.id=budget.scenario_id
    left join public.matrix_locations_v2 location on location.id=budget.location_id
    left join public.matrix_roles_v2 role on role.id=budget.role_id
    left join public.matrix_duties_v2 duty on duty.id=budget.duty_id
    where budget.matrix_version_id=v_draft.id and scenario.active and (
      (budget.location_id is not null and not location.active)
      or (budget.role_id is not null and not role.active)
      or (budget.duty_id is not null and not duty.active)
    )
  ) then raise exception 'SCENARIO_BUDGET_REFERENCES_INACTIVE_SCOPE'; end if;

  v_document:=public.matrix_v2_content_document(v_draft.id);
  if v_document is null then raise exception 'MATRIX_V2_CONTENT_NOT_FOUND'; end if;
  v_hash:=encode(extensions.digest(v_document::text,'sha256'),'hex');

  update public.matrix_versions set status='ARCHIVED',
    effective_to=greatest(effective_from,p_effective_from)
  where status='DRAFT' and id<>v_draft.id;
  update public.matrix_versions set status='ARCHIVED',
    effective_to=greatest(effective_from,p_effective_from-1)
  where status='ACTIVE' and id<>v_draft.id;
  update public.matrix_versions set status='ACTIVE',effective_from=p_effective_from,
    effective_to=null,activated_at=now(),published_at=now(),published_by=auth.uid(),
    content_hash=v_hash,schema_version=2
  where id=v_draft.id;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_v2',v_draft.id::text,'PUBLISH',jsonb_build_object(
    'version',v_draft.version,'effectiveFrom',p_effective_from,
    'contentHash',v_hash,'solverEngine',(select f.engine
      from public.solver_feature_flags f where f.flag_key='DEFAULT_ENGINE')));
  return v_draft.id;
end;
$_$;


ALTER FUNCTION "public"."matrix_v2_publish_draft"("p_effective_from" "date") OWNER TO "postgres";

--
-- Name: matrix_v2_publish_draft_uat_v2("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_publish_draft_uat_v2"("p_effective_from" "date" DEFAULT NULL::"date") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_timezone text;
  v_effective_from date;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;

  select coalesce(nullif(version.settings->>'timezone',''),'UTC')
    into v_timezone
  from public.matrix_versions version
  where version.status='DRAFT' and version.schema_version>=2
  order by version.version desc
  limit 1;
  if v_timezone is null then raise exception 'NO_MATRIX_V2_DRAFT'; end if;
  if not exists(
    select 1 from pg_catalog.pg_timezone_names timezone_row
    where timezone_row.name=v_timezone
  ) then raise exception 'INVALID_MATRIX_TIMEZONE'; end if;

  perform pg_catalog.set_config('TimeZone',v_timezone,true);
  v_effective_from:=coalesce(
    p_effective_from,
    (pg_catalog.clock_timestamp() at time zone v_timezone)::date
  );
  return public.matrix_v2_publish_draft(v_effective_from);
end;
$$;


ALTER FUNCTION "public"."matrix_v2_publish_draft_uat_v2"("p_effective_from" "date") OWNER TO "postgres";

--
-- Name: matrix_v2_revision_history_uat_v2(integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_revision_history_uat_v2"("p_limit" integer DEFAULT 250) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_limit integer:=least(greatest(coalesce(p_limit,250),1),1000);
  v_versions jsonb;
  v_audit jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',version.id,'version',version.version,'name',version.name,
    'status',version.status,'effectiveFrom',version.effective_from,
    'effectiveTo',version.effective_to,'createdAt',version.created_at,
    'activatedAt',version.activated_at,'publishedAt',version.published_at,
    'baseVersionId',version.base_version_id,'contentHash',version.content_hash,
    'workforceHash',version.workforce_hash,
    'createdBy',coalesce(nullif(trim(coalesce(creator.raw_user_meta_data->>'full_name','')),''),creator.email,'System'),
    'publishedBy',coalesce(nullif(trim(coalesce(publisher.raw_user_meta_data->>'full_name','')),''),publisher.email),
    'counts',jsonb_build_object(
      'employees',(select count(*) from public.matrix_employee_profiles_v2 row_value where row_value.matrix_version_id=version.id and row_value.active),
      'roles',(select count(*) from public.matrix_roles_v2 row_value where row_value.matrix_version_id=version.id and row_value.active),
      'locations',(select count(*) from public.matrix_locations_v2 row_value where row_value.matrix_version_id=version.id and row_value.active),
      'duties',(select count(*) from public.matrix_duties_v2 row_value where row_value.matrix_version_id=version.id and row_value.active),
      'shifts',(select count(*) from public.matrix_shift_templates_v2 row_value where row_value.matrix_version_id=version.id and row_value.active),
      'staffingRules',(select count(*) from public.matrix_staffing_rules_v2 row_value where row_value.matrix_version_id=version.id and row_value.active),
      'scenarios',(select count(*) from public.matrix_scenarios_v2 row_value where row_value.matrix_version_id=version.id and row_value.active),
      'strategies',(select count(*) from public.matrix_strategies_v2 row_value where row_value.matrix_version_id=version.id and row_value.active)
    )
  ) order by version.version desc),'[]'::jsonb)
  into v_versions
  from public.matrix_versions version
  left join auth.users creator on creator.id=version.created_by
  left join auth.users publisher on publisher.id=version.published_by
  where version.schema_version>=2;

  with recent as (
    select log.*,
      coalesce(
        log.new_data->>'matrixVersionId',log.new_data->>'matrix_version_id',
        log.old_data->>'matrixVersionId',log.old_data->>'matrix_version_id',
        case when log.entity_type in ('matrix_v2','matrix_version') then log.entity_id end
      ) matrix_version_id,
      case
        when log.entity_type like '%employee%' then 'Pracownicy i umowy'
        when log.entity_type like '%staffing%' then 'Wymagana obsada'
        when log.entity_type like '%strategy%' or log.entity_type like '%scenario%' then 'Scenariusze i warianty'
        when log.entity_type like '%pay%' or log.entity_type like '%budget%' then 'Finanse'
        when log.entity_type like '%role%' or log.entity_type like '%location%'
          or log.entity_type like '%duty%' or log.entity_type like '%shift%' then 'Role, lokale i zmiany'
        when log.action like '%IMPORT%' or log.entity_type like '%import%' then 'Import Excel'
        when log.action='PUBLISH' then 'Publikacja'
        else 'Ustawienia Matrixa'
      end section
    from public.audit_log log
    where log.entity_type like 'matrix_v2%'
      or log.entity_type='matrix_version'
      or log.entity_type='employee_pay_rate_v2'
    order by log.created_at desc,log.id desc
    limit v_limit
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',recent.id,'createdAt',recent.created_at,
    'actorId',recent.actor_id,
    'actor',coalesce(nullif(trim(coalesce(actor.raw_user_meta_data->>'full_name','')),''),actor.email,'System'),
    'matrixVersionId',recent.matrix_version_id,'section',recent.section,
    'entityType',recent.entity_type,'entityId',recent.entity_id,
    'action',recent.action,'oldData',recent.old_data,'newData',recent.new_data
  ) order by recent.created_at desc,recent.id desc),'[]'::jsonb)
  into v_audit
  from recent
  left join auth.users actor on actor.id=recent.actor_id;

  return jsonb_build_object('versions',v_versions,'audit',v_audit);
end;
$$;


ALTER FUNCTION "public"."matrix_v2_revision_history_uat_v2"("p_limit" integer) OWNER TO "postgres";

--
-- Name: matrix_v2_scope_allows_resource_for_app_role_uat_v1("public"."app_role", "uuid", "uuid", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_scope_allows_resource_for_app_role_uat_v1"("p_manager_role" "public"."app_role", "p_role_id" "uuid" DEFAULT NULL::"uuid", "p_location_id" "uuid" DEFAULT NULL::"uuid", "p_employee_id" "uuid" DEFAULT NULL::"uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  with resource as (
    select
      (select role.logical_id from public.matrix_roles_v2 role where role.id=p_role_id) role_logical_id,
      (select location.logical_id from public.matrix_locations_v2 location where location.id=p_location_id) location_logical_id
  )
  select auth.uid() is not null
    and p_manager_role in ('ROLE_MANAGER','LOCATION_MANAGER')
    and public.has_app_role(p_manager_role)
    and exists(
      select 1
      from public.matrix_scope_grants_v2 grant_row
      cross join resource
      where grant_row.auth_user_id=auth.uid()
        and grant_row.active
        and grant_row.app_role=p_manager_role
        and (
          p_manager_role<>'ROLE_MANAGER'
          or (
            grant_row.role_logical_id is not null
            and (
              (p_role_id is not null and resource.role_logical_id=grant_row.role_logical_id)
              or (p_role_id is null and p_employee_id is not null and exists(
                select 1
                from public.matrix_employee_roles_v2 employee_role
                join public.matrix_roles_v2 role on role.id=employee_role.role_id
                join public.matrix_versions matrix on matrix.id=employee_role.matrix_version_id
                where employee_role.employee_id=p_employee_id
                  and employee_role.active and role.active and matrix.status='ACTIVE'
                  and role.logical_id=grant_row.role_logical_id
              ))
            )
          )
        )
        and (
          p_manager_role<>'LOCATION_MANAGER'
          or (
            grant_row.location_logical_id is not null
            and (
              (p_location_id is not null and resource.location_logical_id=grant_row.location_logical_id)
              or (p_location_id is null and p_employee_id is not null and exists(
                select 1
                from public.matrix_employee_locations_v2 employee_location
                join public.matrix_locations_v2 location on location.id=employee_location.location_id
                join public.matrix_versions matrix on matrix.id=employee_location.matrix_version_id
                where employee_location.employee_id=p_employee_id
                  and employee_location.active and location.active and matrix.status='ACTIVE'
                  and location.logical_id=grant_row.location_logical_id
              ))
            )
          )
        )
        and (
          grant_row.role_logical_id is null
          or p_manager_role='ROLE_MANAGER'
          or (p_role_id is not null and resource.role_logical_id=grant_row.role_logical_id)
          or (p_role_id is null and p_employee_id is not null and exists(
            select 1
            from public.matrix_employee_roles_v2 employee_role
            join public.matrix_roles_v2 role on role.id=employee_role.role_id
            join public.matrix_versions matrix on matrix.id=employee_role.matrix_version_id
            where employee_role.employee_id=p_employee_id
              and employee_role.active and role.active and matrix.status='ACTIVE'
              and role.logical_id=grant_row.role_logical_id
          ))
        )
        and (
          grant_row.location_logical_id is null
          or p_manager_role='LOCATION_MANAGER'
          or (p_location_id is not null and resource.location_logical_id=grant_row.location_logical_id)
          or (p_location_id is null and p_employee_id is not null and exists(
            select 1
            from public.matrix_employee_locations_v2 employee_location
            join public.matrix_locations_v2 location on location.id=employee_location.location_id
            join public.matrix_versions matrix on matrix.id=employee_location.matrix_version_id
            where employee_location.employee_id=p_employee_id
              and employee_location.active and location.active and matrix.status='ACTIVE'
              and location.logical_id=grant_row.location_logical_id
          ))
        )
        and (
          grant_row.duty_logical_id is null
          or (p_employee_id is not null and exists(
            select 1
            from public.matrix_employee_duties_v2 employee_duty
            join public.matrix_duties_v2 duty on duty.id=employee_duty.duty_id
            join public.matrix_versions matrix on matrix.id=employee_duty.matrix_version_id
            where employee_duty.employee_id=p_employee_id
              and employee_duty.active and duty.active and matrix.status='ACTIVE'
              and duty.logical_id=grant_row.duty_logical_id
          ))
        )
        and (
          p_employee_id is null
          or (p_manager_role='ROLE_MANAGER' and exists(
            select 1
            from public.matrix_employee_roles_v2 employee_role
            join public.matrix_roles_v2 role on role.id=employee_role.role_id
            join public.matrix_versions matrix on matrix.id=employee_role.matrix_version_id
            where employee_role.employee_id=p_employee_id
              and employee_role.active and role.active and matrix.status='ACTIVE'
              and role.logical_id=grant_row.role_logical_id
          ))
          or (p_manager_role='LOCATION_MANAGER' and exists(
            select 1
            from public.matrix_employee_locations_v2 employee_location
            join public.matrix_locations_v2 location on location.id=employee_location.location_id
            join public.matrix_versions matrix on matrix.id=employee_location.matrix_version_id
            where employee_location.employee_id=p_employee_id
              and employee_location.active and location.active and matrix.status='ACTIVE'
              and location.logical_id=grant_row.location_logical_id
          ))
        )
    );
$$;


ALTER FUNCTION "public"."matrix_v2_scope_allows_resource_for_app_role_uat_v1"("p_manager_role" "public"."app_role", "p_role_id" "uuid", "p_location_id" "uuid", "p_employee_id" "uuid") OWNER TO "postgres";

--
-- Name: matrix_v2_shift_staffing_save_uat_v3("uuid", "uuid"[], "uuid", "uuid", "text", integer, integer, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_shift_staffing_save_uat_v3"("p_scenario_id" "uuid", "p_shift_template_ids" "uuid"[], "p_role_id" "uuid", "p_duty_id" "uuid", "p_operation" "text", "p_count_value" integer, "p_multiplier_basis_points" integer, "p_active" boolean) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_matrix uuid;
  v_shifts uuid[];
  v_source_shift uuid;
  v_target_shift uuid;
  v_target_scenario uuid;
  v_target_role uuid;
  v_target_duty uuid;
  v_existing_rule uuid;
  v_operation text:=upper(trim(coalesce(p_operation,'')));
  v_saved integer:=0;
  v_role_duty_linked boolean:=false;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;

  select coalesce(array_agg(distinct shift_id),array[]::uuid[])
  into v_shifts
  from unnest(coalesce(p_shift_template_ids,array[]::uuid[])) shift_id;
  if cardinality(v_shifts)<1 then raise exception 'SHIFT_SELECTION_REQUIRED'; end if;
  if cardinality(v_shifts)>100 then raise exception 'TOO_MANY_SHIFTS_SELECTED'; end if;
  if p_scenario_id is null then raise exception 'SCENARIO_REQUIRED'; end if;
  if p_role_id is null then raise exception 'ROLE_REQUIRED'; end if;
  if v_operation not in ('SET','ADD','MULTIPLY','REMOVE') then
    raise exception 'INVALID_STAFFING_OPERATION';
  end if;
  if v_operation='SET' and coalesce(p_active,true) and coalesce(p_count_value,0)<1 then
    raise exception 'STAFFING_REQUIRED_COUNT_MUST_BE_POSITIVE';
  end if;
  if v_operation='ADD' and p_count_value is null then
    raise exception 'STAFFING_COUNT_REQUIRED';
  end if;
  if v_operation='MULTIPLY' and coalesce(p_multiplier_basis_points,-1)<0 then
    raise exception 'INVALID_STAFFING_MULTIPLIER';
  end if;

  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  v_matrix:=public.matrix_v2_create_draft(null);

  select target.id into v_target_scenario
  from public.matrix_scenarios_v2 source
  join public.matrix_scenarios_v2 target
    on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
  where source.id=p_scenario_id and target.active;
  if v_target_scenario is null then raise exception 'SCENARIO_NOT_IN_MATRIX_V2'; end if;

  select target.id into v_target_role
  from public.matrix_roles_v2 source
  join public.matrix_roles_v2 target
    on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
  where source.id=p_role_id and target.active;
  if v_target_role is null then raise exception 'ROLE_NOT_IN_MATRIX_V2'; end if;

  if p_duty_id is not null then
    select target.id into v_target_duty
    from public.matrix_duties_v2 source
    join public.matrix_duties_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=p_duty_id and target.active;
    if v_target_duty is null then raise exception 'DUTY_NOT_IN_MATRIX_V2'; end if;

    v_role_duty_linked:=not exists(
      select 1 from public.matrix_role_duties_v2 link
      where link.matrix_version_id=v_matrix
        and link.role_id=v_target_role and link.duty_id=v_target_duty and link.active
    );
    insert into public.matrix_role_duties_v2(
      matrix_version_id,role_id,duty_id,assignment_mode,minimum_count,active
    ) values(v_matrix,v_target_role,v_target_duty,'OPTIONAL',0,true)
    on conflict (matrix_version_id,role_id,duty_id)
    do update set active=true;
  end if;

  foreach v_source_shift in array v_shifts loop
    select target.id into v_target_shift
    from public.matrix_shift_templates_v2 source
    join public.matrix_shift_templates_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=v_source_shift and target.active;
    if v_target_shift is null then raise exception 'SHIFT_NOT_IN_MATRIX_V2'; end if;

    select rule.id into v_existing_rule
    from public.matrix_staffing_rules_v2 rule
    where rule.matrix_version_id=v_matrix
      and rule.scenario_id=v_target_scenario
      and rule.shift_template_id=v_target_shift
      and rule.role_id=v_target_role
      and rule.duty_id is not distinct from v_target_duty;

    perform public.matrix_v2_admin_save_alpha16(
      'STAFFING_RULE',v_existing_rule,
      jsonb_build_object(
        'scenarioId',v_target_scenario,
        'shiftTemplateId',v_target_shift,
        'roleId',v_target_role,
        'dutyId',v_target_duty,
        'operation',v_operation,
        'countValue',case when v_operation in ('SET','ADD') then p_count_value else null end,
        'multiplierBasisPoints',case when v_operation='MULTIPLY' then p_multiplier_basis_points else null end,
        'active',coalesce(p_active,true),
        'sourceMetadata',jsonb_build_object('source','UNIFIED_SHIFT_STAFFING_UI')
      )
    );
    v_saved:=v_saved+1;
  end loop;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_version',v_matrix::text,'SAVE_UNIFIED_SHIFT_STAFFING',
    jsonb_build_object(
      'scenarioId',v_target_scenario,'shiftTemplateIds',to_jsonb(v_shifts),
      'roleId',v_target_role,'dutyId',v_target_duty,
      'roleDutyLinked',v_role_duty_linked,'operation',v_operation,
      'countValue',p_count_value,'saved',v_saved
    ));

  return jsonb_build_object(
    'matrixVersionId',v_matrix,'saved',v_saved,
    'roleDutyLinked',v_role_duty_linked
  );
end;
$$;


ALTER FUNCTION "public"."matrix_v2_shift_staffing_save_uat_v3"("p_scenario_id" "uuid", "p_shift_template_ids" "uuid"[], "p_role_id" "uuid", "p_duty_id" "uuid", "p_operation" "text", "p_count_value" integer, "p_multiplier_basis_points" integer, "p_active" boolean) OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_shift_staffing_save_uat_v3"("p_scenario_id" "uuid", "p_shift_template_ids" "uuid"[], "p_role_id" "uuid", "p_duty_id" "uuid", "p_operation" "text", "p_count_value" integer, "p_multiplier_basis_points" integer, "p_active" boolean); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_shift_staffing_save_uat_v3"("p_scenario_id" "uuid", "p_shift_template_ids" "uuid"[], "p_role_id" "uuid", "p_duty_id" "uuid", "p_operation" "text", "p_count_value" integer, "p_multiplier_basis_points" integer, "p_active" boolean) IS 'Atomically saves exact shift staffing and links a selected duty to the role so the unified Matrix flow cannot silently ignore it.';


--
-- Name: matrix_v2_stable_uuid("text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_stable_uuid"("p_value" "text") RETURNS "uuid"
    LANGUAGE "sql" IMMUTABLE STRICT
    SET "search_path" TO ''
    AS $$
  select (
    substr(md5(p_value),1,8)||'-'||substr(md5(p_value),9,4)||'-'||
    substr(md5(p_value),13,4)||'-'||substr(md5(p_value),17,4)||'-'||
    substr(md5(p_value),21,12)
  )::uuid;
$$;


ALTER FUNCTION "public"."matrix_v2_stable_uuid"("p_value" "text") OWNER TO "postgres";

--
-- Name: matrix_v2_staffing_bulk_adjust_uat_v2("uuid", "uuid", "text", "uuid", integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_staffing_bulk_adjust_uat_v2"("p_scenario_id" "uuid", "p_location_id" "uuid" DEFAULT NULL::"uuid", "p_shift_period" "text" DEFAULT NULL::"text", "p_role_id" "uuid" DEFAULT NULL::"uuid", "p_delta" integer DEFAULT 1) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_matrix uuid;
  v_scenario uuid;
  v_location uuid;
  v_role uuid;
  v_period text:=nullif(upper(trim(coalesce(p_shift_period,''))), '');
  v_matching integer:=0;
  v_eligible integer:=0;
  v_updated integer:=0;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if p_scenario_id is null then raise exception 'SCENARIO_REQUIRED'; end if;
  if coalesce(p_delta,0)=0 or abs(p_delta)>20 then
    raise exception 'INVALID_STAFFING_BULK_DELTA';
  end if;
  if v_period is not null and v_period not in ('MORNING','MIDDLE','EVENING') then
    raise exception 'INVALID_SHIFT_PERIOD';
  end if;

  v_matrix:=public.matrix_v2_create_draft(null);
  select target.id into v_scenario
  from public.matrix_scenarios_v2 source
  join public.matrix_scenarios_v2 target
    on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
  where source.id=p_scenario_id;
  if v_scenario is null then raise exception 'SCENARIO_NOT_IN_MATRIX_V2'; end if;

  if p_location_id is not null then
    select target.id into v_location
    from public.matrix_locations_v2 source
    join public.matrix_locations_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=p_location_id;
    if v_location is null then raise exception 'LOCATION_NOT_IN_MATRIX_V2'; end if;
  end if;
  if p_role_id is not null then
    select target.id into v_role
    from public.matrix_roles_v2 source
    join public.matrix_roles_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=p_role_id;
    if v_role is null then raise exception 'ROLE_NOT_IN_MATRIX_V2'; end if;
  end if;

  -- Lock and validate the complete target set before changing any row.  This
  -- preserves the established staffing contracts: active SET rules require at
  -- least one person and ADD rules cannot carry a negative count.  A single
  -- invalid result aborts the whole bulk operation instead of being clamped.
  perform rule.id
  from public.matrix_staffing_rules_v2 rule
  join public.matrix_shift_templates_v2 shift
    on shift.id=rule.shift_template_id
  where rule.matrix_version_id=v_matrix and rule.scenario_id=v_scenario
    and rule.active and rule.operation in ('SET','ADD')
    and (v_location is null or shift.location_id=v_location)
    and (v_period is null or shift.shift_period=v_period)
    and (v_role is null or rule.role_id=v_role)
  for update of rule;

  select count(*),count(*) filter(where rule.operation in ('SET','ADD'))
  into v_matching,v_eligible
  from public.matrix_staffing_rules_v2 rule
  join public.matrix_shift_templates_v2 shift
    on shift.id=rule.shift_template_id
  where rule.matrix_version_id=v_matrix and rule.scenario_id=v_scenario
    and rule.active
    and (v_location is null or shift.location_id=v_location)
    and (v_period is null or shift.shift_period=v_period)
    and (v_role is null or rule.role_id=v_role);
  if v_eligible<1 then raise exception 'STAFFING_TARGET_NOT_FOUND'; end if;

  if exists(
    select 1
    from public.matrix_staffing_rules_v2 rule
    join public.matrix_shift_templates_v2 shift
      on shift.id=rule.shift_template_id
    where rule.matrix_version_id=v_matrix and rule.scenario_id=v_scenario
      and rule.active and rule.operation in ('SET','ADD')
      and (v_location is null or shift.location_id=v_location)
      and (v_period is null or shift.shift_period=v_period)
      and (v_role is null or rule.role_id=v_role)
      and (
        (rule.operation='SET' and coalesce(rule.count_value,0)+p_delta<1)
        or (rule.operation='ADD' and coalesce(rule.count_value,0)+p_delta<0)
      )
  ) then
    raise exception 'STAFFING_COUNT_BELOW_MINIMUM';
  end if;

  update public.matrix_staffing_rules_v2 rule set
    count_value=coalesce(rule.count_value,0)+p_delta,
    updated_at=now()
  from public.matrix_shift_templates_v2 shift
  where shift.id=rule.shift_template_id
    and rule.matrix_version_id=v_matrix and rule.scenario_id=v_scenario
    and rule.active and rule.operation in ('SET','ADD')
    and (v_location is null or shift.location_id=v_location)
    and (v_period is null or shift.shift_period=v_period)
    and (v_role is null or rule.role_id=v_role);
  get diagnostics v_updated=row_count;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_version',v_matrix::text,'BULK_ADJUST_STAFFING',
    jsonb_build_object(
      'scenarioId',v_scenario,'locationId',v_location,'shiftPeriod',v_period,
      'roleId',v_role,'delta',p_delta,'updated',v_updated,
      'skipped',greatest(v_matching-v_updated,0)
    ));
  return jsonb_build_object(
    'matrixVersionId',v_matrix,'updated',v_updated,
    'skipped',greatest(v_matching-v_updated,0)
  );
end;
$$;


ALTER FUNCTION "public"."matrix_v2_staffing_bulk_adjust_uat_v2"("p_scenario_id" "uuid", "p_location_id" "uuid", "p_shift_period" "text", "p_role_id" "uuid", "p_delta" integer) OWNER TO "postgres";

--
-- Name: matrix_v2_staffing_rules_bulk_save_uat_v2("uuid", "uuid"[], "uuid", "uuid", "text", integer, integer, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_staffing_rules_bulk_save_uat_v2"("p_scenario_id" "uuid", "p_shift_template_ids" "uuid"[], "p_role_id" "uuid", "p_duty_id" "uuid", "p_operation" "text", "p_count_value" integer, "p_multiplier_basis_points" integer, "p_active" boolean) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_matrix uuid;
  v_shifts uuid[];
  v_shift uuid;
  v_operation text:=upper(trim(coalesce(p_operation,'')));
  v_saved integer:=0;
  v_target_scenario uuid;
  v_target_role uuid;
  v_target_duty uuid;
  v_target_shift uuid;
  v_existing uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;

  select coalesce(array_agg(distinct shift_id),array[]::uuid[])
  into v_shifts
  from unnest(coalesce(p_shift_template_ids,array[]::uuid[])) shift_id;
  if cardinality(v_shifts)<1 then raise exception 'SHIFT_SELECTION_REQUIRED'; end if;
  if cardinality(v_shifts)>100 then raise exception 'TOO_MANY_SHIFTS_SELECTED'; end if;
  if p_scenario_id is null then raise exception 'SCENARIO_REQUIRED'; end if;
  if p_role_id is null then raise exception 'ROLE_REQUIRED'; end if;
  if v_operation not in ('SET','ADD','MULTIPLY','REMOVE') then
    raise exception 'INVALID_STAFFING_OPERATION';
  end if;
  if v_operation in ('SET','ADD') and p_count_value is null then
    raise exception 'STAFFING_COUNT_REQUIRED';
  end if;
  if v_operation in ('SET','ADD') and p_count_value<0 then
    raise exception 'STAFFING_COUNT_NEGATIVE';
  end if;
  if v_operation='MULTIPLY' and coalesce(p_multiplier_basis_points,-1)<0 then
    raise exception 'INVALID_STAFFING_MULTIPLIER';
  end if;

  v_matrix:=public.matrix_v2_create_draft(null);

  -- Validate every reference up front.  The following FOREACH loop therefore
  -- cannot partially apply a batch before discovering a bad final selection.
  select target.id into v_target_scenario
    from public.matrix_scenarios_v2 source
    join public.matrix_scenarios_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=p_scenario_id and target.active;
  if v_target_scenario is null then raise exception 'SCENARIO_NOT_IN_MATRIX_V2'; end if;
  select target.id into v_target_role
    from public.matrix_roles_v2 source
    join public.matrix_roles_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=p_role_id and target.active;
  if v_target_role is null then raise exception 'ROLE_NOT_IN_MATRIX_V2'; end if;
  if p_duty_id is not null then
    select target.id into v_target_duty
      from public.matrix_duties_v2 source
      join public.matrix_duties_v2 target
        on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
      where source.id=p_duty_id and target.active;
    if v_target_duty is null then raise exception 'DUTY_NOT_IN_MATRIX_V2'; end if;
  end if;
  if (
    select count(distinct selected.shift_id)
    from unnest(v_shifts) selected(shift_id)
    join public.matrix_shift_templates_v2 source on source.id=selected.shift_id
    join public.matrix_shift_templates_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where target.active
  )<>cardinality(v_shifts) then
    raise exception 'SHIFT_NOT_IN_MATRIX_V2';
  end if;

  foreach v_shift in array v_shifts loop
    select target.id into v_target_shift
    from public.matrix_shift_templates_v2 source
    join public.matrix_shift_templates_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=v_shift and target.active;
    if v_target_shift is null then raise exception 'SHIFT_NOT_IN_MATRIX_V2'; end if;
    select rule.id into v_existing
    from public.matrix_staffing_rules_v2 rule
    where rule.matrix_version_id=v_matrix
      and rule.scenario_id=v_target_scenario
      and rule.shift_template_id=v_target_shift
      and rule.role_id=v_target_role
      and rule.duty_id is not distinct from v_target_duty;
    perform public.matrix_v2_admin_save_alpha16(
      'STAFFING_RULE',v_existing,
      jsonb_build_object(
        'scenarioId',v_target_scenario,
        'shiftTemplateId',v_target_shift,
        'roleId',v_target_role,
        'dutyId',v_target_duty,
        'operation',v_operation,
        'countValue',case when v_operation in ('SET','ADD') then p_count_value else null end,
        'multiplierBasisPoints',case when v_operation='MULTIPLY' then p_multiplier_basis_points else null end,
        'active',coalesce(p_active,true),
        'sourceMetadata',jsonb_build_object(
          'source','MATRIX_BULK_UI','batchSize',cardinality(v_shifts)
        )
      )
    );
    v_saved:=v_saved+1;
  end loop;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_version',v_matrix::text,'BULK_SAVE_STAFFING',
    jsonb_build_object(
      'scenarioId',v_target_scenario,'roleId',v_target_role,
      'dutyId',v_target_duty,
      'operation',v_operation,'shiftTemplateIds',to_jsonb(v_shifts),'saved',v_saved
    ));
  return jsonb_build_object('matrixVersionId',v_matrix,'saved',v_saved);
end;
$$;


ALTER FUNCTION "public"."matrix_v2_staffing_rules_bulk_save_uat_v2"("p_scenario_id" "uuid", "p_shift_template_ids" "uuid"[], "p_role_id" "uuid", "p_duty_id" "uuid", "p_operation" "text", "p_count_value" integer, "p_multiplier_basis_points" integer, "p_active" boolean) OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_staffing_rules_bulk_save_uat_v2"("p_scenario_id" "uuid", "p_shift_template_ids" "uuid"[], "p_role_id" "uuid", "p_duty_id" "uuid", "p_operation" "text", "p_count_value" integer, "p_multiplier_basis_points" integer, "p_active" boolean); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_staffing_rules_bulk_save_uat_v2"("p_scenario_id" "uuid", "p_shift_template_ids" "uuid"[], "p_role_id" "uuid", "p_duty_id" "uuid", "p_operation" "text", "p_count_value" integer, "p_multiplier_basis_points" integer, "p_active" boolean) IS 'Atomically creates or replaces one staffing requirement across multiple selected shifts.';


--
-- Name: matrix_v2_team_import_apply_uat_v1("jsonb", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_team_import_apply_uat_v1"("p_configuration" "jsonb", "p_mode" "text" DEFAULT 'UPDATE'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '180s'
    AS $$
declare
  v_identity jsonb;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  v_identity:=solver_private.matrix_v2_assert_workbook_identity_uat_v1(p_configuration);
  v_result:=public.matrix_v2_team_import_apply_uat_v1_core_20260824(p_configuration,p_mode);
  return v_result||jsonb_build_object('workbookIdentity',v_identity);
end;
$$;


ALTER FUNCTION "public"."matrix_v2_team_import_apply_uat_v1"("p_configuration" "jsonb", "p_mode" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_team_import_apply_uat_v1"("p_configuration" "jsonb", "p_mode" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_team_import_apply_uat_v1"("p_configuration" "jsonb", "p_mode" "text") IS 'B4F-173 UAT atomic apply: revalidates v2 workbook identity under the lifecycle advisory lock before mutation.';


--
-- Name: matrix_v2_team_import_apply_uat_v1_core_20260824("jsonb", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_team_import_apply_uat_v1_core_20260824"("p_configuration" "jsonb", "p_mode" "text" DEFAULT 'UPDATE'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '180s'
    AS $$
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


ALTER FUNCTION "public"."matrix_v2_team_import_apply_uat_v1_core_20260824"("p_configuration" "jsonb", "p_mode" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_team_import_apply_uat_v1_core_20260824"("p_configuration" "jsonb", "p_mode" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_team_import_apply_uat_v1_core_20260824"("p_configuration" "jsonb", "p_mode" "text") IS 'UAT atomic onboarding in dependency order: dictionaries, shifts, workforce, relations and deferred finance.';


--
-- Name: matrix_v2_team_import_preview_uat_v1("jsonb", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_team_import_preview_uat_v1"("p_configuration" "jsonb", "p_mode" "text" DEFAULT 'UPDATE'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '180s'
    AS $$
declare
  v_identity jsonb;
  v_result jsonb;
begin
  v_identity:=solver_private.matrix_v2_assert_workbook_identity_uat_v1(p_configuration);
  v_result:=public.matrix_v2_team_import_preview_uat_v1_core_20260824(p_configuration,p_mode);
  return v_result||jsonb_build_object('workbookIdentity',v_identity);
end;
$$;


ALTER FUNCTION "public"."matrix_v2_team_import_preview_uat_v1"("p_configuration" "jsonb", "p_mode" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_team_import_preview_uat_v1"("p_configuration" "jsonb", "p_mode" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_team_import_preview_uat_v1"("p_configuration" "jsonb", "p_mode" "text") IS 'B4F-173 UAT preview: validates v2 workbook mode and current DRAFT identity before the existing dependency-ordered dry run.';


--
-- Name: matrix_v2_team_import_preview_uat_v1_core_20260814("jsonb", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_team_import_preview_uat_v1_core_20260814"("p_configuration" "jsonb", "p_mode" "text" DEFAULT 'UPDATE'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '180s'
    AS $$
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


ALTER FUNCTION "public"."matrix_v2_team_import_preview_uat_v1_core_20260814"("p_configuration" "jsonb", "p_mode" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_team_import_preview_uat_v1_core_20260814"("p_configuration" "jsonb", "p_mode" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_team_import_preview_uat_v1_core_20260814"("p_configuration" "jsonb", "p_mode" "text") IS 'UAT onboarding dry-run. Incoming dictionaries and shifts are staged in the same rolled-back transaction before employee and staffing validation.';


--
-- Name: matrix_v2_team_import_preview_uat_v1_core_20260824("jsonb", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_team_import_preview_uat_v1_core_20260824"("p_configuration" "jsonb", "p_mode" "text" DEFAULT 'UPDATE'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '180s'
    AS $$
begin
  return public.matrix_v2_team_import_preview_uat_v1_core_20260814(
    p_configuration,p_mode
  );
exception when others then
  if sqlerrm like 'MATRIX_%' or sqlerrm like 'INVALID_%'
    or sqlerrm like 'EMPLOYEE_%' or sqlerrm like 'IMPORTED_%'
    or sqlerrm like 'FULL_IMPORT_%' or sqlerrm like 'ROLE_%' then
    raise;
  end if;
  raise exception 'TEAM_IMPORT_PREVIEW_FAILED|%|%|%',
    gen_random_uuid(),sqlstate,sqlerrm;
end;
$$;


ALTER FUNCTION "public"."matrix_v2_team_import_preview_uat_v1_core_20260824"("p_configuration" "jsonb", "p_mode" "text") OWNER TO "postgres";

--
-- Name: matrix_v2_workspace("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_workspace"("p_month" "date" DEFAULT NULL::"date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_payload jsonb;
  v_matrix uuid;
  v_visible_employee_ids uuid[];
  v_employees jsonb;
  v_ad_hoc_workers jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;

  v_payload := public.matrix_v2_workspace_before_employee_privacy_uat_v1(p_month);
  v_matrix := nullif(v_payload->'matrixVersion'->>'id', '')::uuid;

  select coalesce(array_agg(visible.employee_id order by visible.employee_id), '{}'::uuid[])
  into v_visible_employee_ids
  from authorization_private.matrix_v2_visible_employee_ids_uat_v1() visible;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', employee.id,
      'employeeNo', employee.employee_no,
      'firstName', employee.first_name,
      'lastName', employee.last_name,
      'active', employee.active and employee.archived_at is null
    )
    || coalesce((
      select jsonb_build_object(
        'employmentStage', profile.employment_stage,
        'probationEnd', profile.probation_end
      )
      from public.matrix_employee_profiles_v2 profile
      where profile.matrix_version_id = v_matrix
        and profile.employee_id = employee.id
    ), '{}'::jsonb)
    || jsonb_build_object(
      'overtimePolicy', coalesce((
        select profile.overtime_policy
        from public.matrix_employee_profiles_v2 profile
        where profile.matrix_version_id = v_matrix
          and profile.employee_id = employee.id
      ), 'NEVER')
    )
    order by employee.active desc, employee.last_name, employee.first_name, employee.employee_no
  ), '[]'::jsonb)
  into v_employees
  from public.employees employee
  where employee.id = any(v_visible_employee_ids);
  v_payload := jsonb_set(v_payload, '{employees}', v_employees, true);

  select coalesce(jsonb_agg(item.value order by item.ordinality), '[]'::jsonb)
  into v_employees
  from jsonb_array_elements(coalesce(v_payload->'employeeRoles', '[]'::jsonb))
    with ordinality item(value, ordinality)
  where nullif(item.value->>'employee_id', '')::uuid = any(v_visible_employee_ids);
  v_payload := jsonb_set(v_payload, '{employeeRoles}', v_employees, true);

  select coalesce(jsonb_agg(item.value order by item.ordinality), '[]'::jsonb)
  into v_employees
  from jsonb_array_elements(coalesce(v_payload->'employeeLocations', '[]'::jsonb))
    with ordinality item(value, ordinality)
  where nullif(item.value->>'employee_id', '')::uuid = any(v_visible_employee_ids);
  v_payload := jsonb_set(v_payload, '{employeeLocations}', v_employees, true);

  select coalesce(jsonb_agg(item.value order by item.ordinality), '[]'::jsonb)
  into v_employees
  from jsonb_array_elements(coalesce(v_payload->'employeeDuties', '[]'::jsonb))
    with ordinality item(value, ordinality)
  where nullif(item.value->>'employee_id', '')::uuid = any(v_visible_employee_ids);
  v_payload := jsonb_set(v_payload, '{employeeDuties}', v_employees, true);

  select coalesce(jsonb_agg(item.value order by item.ordinality), '[]'::jsonb)
  into v_employees
  from jsonb_array_elements(coalesce(v_payload->'timeConstraints', '[]'::jsonb))
    with ordinality item(value, ordinality)
  where nullif(item.value->>'employeeId', '')::uuid = any(v_visible_employee_ids);
  v_payload := jsonb_set(v_payload, '{timeConstraints}', v_employees, true);

  select coalesce(jsonb_agg(item.value order by item.ordinality), '[]'::jsonb)
  into v_employees
  from jsonb_array_elements(coalesce(v_payload->'workPatterns', '[]'::jsonb))
    with ordinality item(value, ordinality)
  where nullif(item.value->>'employeeId', '')::uuid = any(v_visible_employee_ids);
  v_payload := jsonb_set(v_payload, '{workPatterns}', v_employees, true);

  select coalesce(jsonb_agg(item.value order by item.ordinality), '[]'::jsonb)
  into v_employees
  from jsonb_array_elements(coalesce(v_payload->'employeePayRates', '[]'::jsonb))
    with ordinality item(value, ordinality)
  where nullif(item.value->>'employee_id', '')::uuid = any(v_visible_employee_ids);
  v_payload := jsonb_set(v_payload, '{employeePayRates}', v_employees, true);

  -- An ad-hoc identity is a recovery resource. A linked employee must be visible
  -- and the recovery role/employee resource must be inside the caller's scope.
  -- A temporary identity has no employee or location relation, so it can only be
  -- resolved through its role scope. HR_FINANCE keeps its pre-existing full
  -- finance/recovery projection; field-level finance redaction already ran in
  -- the wrapped function and remains independent from person visibility.
  select coalesce(jsonb_agg(item.value order by item.ordinality), '[]'::jsonb)
  into v_ad_hoc_workers
  from jsonb_array_elements(coalesce(v_payload->'adHocWorkers', '[]'::jsonb))
    with ordinality item(value, ordinality)
  where (
      nullif(item.value->>'employee_id', '') is null
      or nullif(item.value->>'employee_id', '')::uuid = any(v_visible_employee_ids)
    )
    and (
      public.has_app_role('HR_FINANCE')
      or public.matrix_v2_can_manage_resource_uat_v1(
        nullif(item.value->>'role_id', '')::uuid,
        null,
        nullif(item.value->>'employee_id', '')::uuid
      )
    );
  v_payload := jsonb_set(v_payload, '{adHocWorkers}', v_ad_hoc_workers, true);

  return v_payload;
end;
$$;


ALTER FUNCTION "public"."matrix_v2_workspace"("p_month" "date") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_workspace"("p_month" "date"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_workspace"("p_month" "date") IS 'Employee-scoped configuration workspace with independent server-side finance redaction.';


--
-- Name: matrix_v2_workspace_before_ad_hoc_projection_uat_v1("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_workspace_before_ad_hoc_projection_uat_v1"("p_month" "date" DEFAULT NULL::"date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_result jsonb;
  v_matrix uuid;
  v_employees jsonb := '[]'::jsonb;
  v_employee jsonb;
  v_locations jsonb := '[]'::jsonb;
  v_location jsonb;
  v_categories jsonb := '[]'::jsonb;
  v_category jsonb;
  v_roles jsonb := '[]'::jsonb;
  v_role jsonb;
begin
  v_result := public.matrix_v2_workspace_before_overtime_uat_v1(p_month);
  v_matrix := nullif(v_result->'matrixVersion'->>'id', '')::uuid;
  for v_employee in
    select value from jsonb_array_elements(coalesce(v_result->'employees', '[]'::jsonb))
  loop
    v_employee := v_employee || jsonb_build_object(
      'overtimePolicy', coalesce((
        select profile.overtime_policy
        from public.matrix_employee_profiles_v2 profile
        where profile.matrix_version_id = v_matrix
          and profile.employee_id = (v_employee->>'id')::uuid
      ), 'NEVER')
    );
    v_employees := v_employees || jsonb_build_array(v_employee);
  end loop;
  v_result := jsonb_set(v_result, '{employees}', v_employees, true);
  for v_location in select value from jsonb_array_elements(coalesce(v_result->'locations','[]'::jsonb)) loop
    v_location := v_location || jsonb_build_object('logicalId',(
      select location_row.logical_id from public.matrix_locations_v2 location_row
      where location_row.id=(v_location->>'id')::uuid
    ));
    v_locations := v_locations || jsonb_build_array(v_location);
  end loop;
  v_result := jsonb_set(v_result, '{locations}', v_locations, true);
  for v_role in select value from jsonb_array_elements(coalesce(v_result->'roles','[]'::jsonb)) loop
    v_role := v_role || jsonb_build_object('logicalId',(
      select role_row.logical_id from public.matrix_roles_v2 role_row
      where role_row.id=(v_role->>'id')::uuid
    ));
    v_roles := v_roles || jsonb_build_array(v_role);
  end loop;
  v_result := jsonb_set(v_result, '{roles}', v_roles, true);
  for v_category in select value from jsonb_array_elements(coalesce(v_result->'roleCategories','[]'::jsonb)) loop
    v_category := v_category || jsonb_build_object('logicalId',(
      select category.logical_id from public.matrix_role_categories_v2 category
      where category.id=(v_category->>'id')::uuid
    ));
    v_categories := v_categories || jsonb_build_array(v_category);
  end loop;
  return jsonb_set(v_result, '{roleCategories}', v_categories, true);
end;
$$;


ALTER FUNCTION "public"."matrix_v2_workspace_before_ad_hoc_projection_uat_v1"("p_month" "date") OWNER TO "postgres";

--
-- Name: matrix_v2_workspace_before_b4f52_uat_v1("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_workspace_before_b4f52_uat_v1"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_result jsonb;v_month_end date:=(p_month+interval '1 month - 1 day')::date;
begin
  v_result:=public.matrix_v2_workspace_before_b4f91_uat_v1(p_month);
  return v_result||jsonb_build_object('workPatterns',coalesce((select jsonb_agg(jsonb_build_object(
    'id',p.id,'employeeId',p.employee_id,'weekday',p.weekday,'localStart',p.local_start,
    'localEnd',p.local_end,'roleId',p.role_id,'locationId',p.location_id,
    'enforcement',p.enforcement,'validFrom',p.valid_from,'validTo',p.valid_to,
    'revision',p.revision,'reason',p.reason,'active',p.active
  ) order by p.employee_id,p.valid_from,p.weekday,p.local_start)
  from public.employee_weekly_work_patterns_v2 p where p.active and p.valid_from<=v_month_end
    and (p.valid_to is null or p.valid_to>=p_month)),'[]'::jsonb));
end;$$;


ALTER FUNCTION "public"."matrix_v2_workspace_before_b4f52_uat_v1"("p_month" "date") OWNER TO "postgres";

--
-- Name: matrix_v2_workspace_before_b4f91_uat_v1("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_workspace_before_b4f91_uat_v1"("p_month" "date" DEFAULT NULL::"date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_result jsonb;
  v_matrix uuid;
begin
  v_result := public.matrix_v2_workspace_before_ad_hoc_projection_uat_v1(p_month);
  v_matrix := nullif(v_result->'matrixVersion'->>'id', '')::uuid;

  v_result := jsonb_set(
    v_result,
    '{adHocWorkers}',
    coalesce((
      select jsonb_agg(
        (to_jsonb(pool) - 'role_id') || jsonb_build_object(
          'role_id', coalesce(workspace_role.id, pool.role_id),
          'roleCode', coalesce(workspace_role.code, source_role.code)
        )
        order by pool.display_name, pool.id
      )
      from public.recovery_ad_hoc_pool_v2 pool
      join public.matrix_roles_v2 source_role on source_role.id = pool.role_id
      left join public.matrix_roles_v2 workspace_role
        on workspace_role.matrix_version_id = v_matrix
       and workspace_role.logical_id = source_role.logical_id
      where pool.active
    ), '[]'::jsonb),
    true
  );

  return v_result;
end;
$$;


ALTER FUNCTION "public"."matrix_v2_workspace_before_b4f91_uat_v1"("p_month" "date") OWNER TO "postgres";

--
-- Name: matrix_v2_workspace_before_categories_uat_v1("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_workspace_before_categories_uat_v1"("p_month" "date" DEFAULT NULL::"date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_matrix uuid;
  v_month date:=case when p_month is null then null
    else date_trunc('month',p_month)::date end;
  v_timezone text;
  v_finance boolean;
  v_manage boolean;
  v_owner_admin boolean;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  v_owner_admin:=public.has_app_role('OWNER') or public.has_app_role('ADMIN');
  v_finance:=v_owner_admin or public.has_app_role('HR_FINANCE');
  v_manage:=v_owner_admin or public.has_app_role('HR_FINANCE');

  if v_owner_admin then
    select mv.id into v_matrix from public.matrix_versions mv
    where mv.status='DRAFT' and mv.schema_version>=2
    order by mv.version desc limit 1;
  end if;
  if v_matrix is null then
    select mv.id into v_matrix from public.matrix_versions mv
    where mv.status='ACTIVE' and mv.schema_version>=2
    order by mv.version desc limit 1;
  end if;
  if v_matrix is null then raise exception 'MATRIX_V2_NOT_FOUND'; end if;
  select nullif(mv.settings->>'timezone','') into v_timezone
  from public.matrix_versions mv where mv.id=v_matrix;
  if v_timezone is null or not exists(
    select 1 from pg_catalog.pg_timezone_names tz where tz.name=v_timezone
  ) then raise exception 'INVALID_MATRIX_TIMEZONE'; end if;

  select jsonb_build_object(
    'matrixVersion',to_jsonb(mv),
    'month',v_month,
    'editable',mv.status='DRAFT' and v_owner_admin,
    'financeVisible',v_finance,
    'featureFlag',(select to_jsonb(f) from public.solver_feature_flags f
      where f.flag_key='DEFAULT_ENGINE'),
    'roles',coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order,x.code)
      from public.matrix_roles_v2 x where x.matrix_version_id=v_matrix),'[]'::jsonb),
    'locations',coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order,x.code)
      from public.matrix_locations_v2 x where x.matrix_version_id=v_matrix),'[]'::jsonb),
    'duties',coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order,x.code)
      from public.matrix_duties_v2 x where x.matrix_version_id=v_matrix),'[]'::jsonb),
    'shiftTemplates',coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order,x.code)
      from public.matrix_shift_templates_v2 x where x.matrix_version_id=v_matrix),'[]'::jsonb),
    'roleDuties',coalesce((select jsonb_agg(to_jsonb(x) order by x.role_id,x.duty_id)
      from public.matrix_role_duties_v2 x where x.matrix_version_id=v_matrix),'[]'::jsonb),
    'scenarios',coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order,x.code)
      from public.matrix_scenarios_v2 x where x.matrix_version_id=v_matrix),'[]'::jsonb),
    'staffingRules',coalesce((select jsonb_agg(to_jsonb(x)
        order by x.scenario_id,x.shift_template_id,x.role_id,x.duty_id)
      from public.matrix_staffing_rules_v2 x where x.matrix_version_id=v_matrix),'[]'::jsonb),
    'strategies',coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order,x.code)
      from public.matrix_strategies_v2 x where x.matrix_version_id=v_matrix),'[]'::jsonb),
    'strategyObjectives',coalesce((select jsonb_agg(to_jsonb(x)
        order by x.strategy_id,x.tier,x.sort_order,x.metric_code)
      from public.matrix_strategy_objectives_v2 x where x.matrix_version_id=v_matrix),'[]'::jsonb),
    'scenarioStrategies',coalesce((select jsonb_agg(to_jsonb(x)
        order by x.scenario_id,x.sort_order,x.strategy_id)
      from public.matrix_scenario_strategies_v2 x where x.matrix_version_id=v_matrix),'[]'::jsonb),
    'employees',coalesce((select jsonb_agg(jsonb_build_object(
        'id',e.id,'employeeNo',e.employee_no,'firstName',e.first_name,
        'lastName',e.last_name,'active',e.active and e.archived_at is null
      ) order by e.active desc,e.last_name,e.first_name,e.employee_no)
      from public.employees e
      where v_manage or e.auth_user_id=auth.uid()),'[]'::jsonb),
    'employeeRoles',coalesce((select jsonb_agg(to_jsonb(x) order by x.employee_id,x.role_id)
      from public.matrix_employee_roles_v2 x
      where x.matrix_version_id=v_matrix
        and (v_manage or public.matrix_v2_can_manage_employee(x.employee_id))),
      '[]'::jsonb),
    'employeeLocations',coalesce((select jsonb_agg(to_jsonb(x) order by x.employee_id,x.location_id)
      from public.matrix_employee_locations_v2 x
      where x.matrix_version_id=v_matrix
        and (v_manage or public.matrix_v2_can_manage_employee(x.employee_id))),
      '[]'::jsonb),
    'employeeDuties',coalesce((select jsonb_agg(to_jsonb(x) order by x.employee_id,x.duty_id)
      from public.matrix_employee_duties_v2 x
      where x.matrix_version_id=v_matrix
        and (v_manage or public.matrix_v2_can_manage_employee(x.employee_id))),
      '[]'::jsonb),
    'timeConstraints',coalesce((select jsonb_agg(jsonb_build_object(
        'id',x.id,'employeeId',x.employee_id,'kind',x.constraint_kind,
        'startsAt',lower(x.time_range),'endsAt',upper(x.time_range),
        'source',x.source,'editableByEmployee',x.editable_by_employee,
        'status',x.status,'note',x.note,'createdAt',x.created_at
      ) order by lower(x.time_range),x.id)
      from public.employee_time_constraints_v2 x
      where (v_manage or public.matrix_v2_can_manage_employee(x.employee_id))
        and x.status='ACTIVE'
        and (v_month is null or x.time_range && tstzrange(
          v_month::timestamp at time zone v_timezone,
          (v_month+interval '1 month')::timestamp at time zone v_timezone,'[)'))),'[]'::jsonb),
    'payRules',case when v_finance then coalesce((select jsonb_agg(to_jsonb(x)
        order by x.priority,x.code) from public.matrix_pay_rules_v2 x
      where x.matrix_version_id=v_matrix),'[]'::jsonb) else '[]'::jsonb end,
    'payRuleRoles',case when v_finance then coalesce((select jsonb_agg(to_jsonb(x)
      order by x.pay_rule_id,x.role_id) from public.matrix_pay_rule_roles_v2 x
      where x.matrix_version_id=v_matrix),'[]'::jsonb) else '[]'::jsonb end,
    'payRuleDuties',case when v_finance then coalesce((select jsonb_agg(to_jsonb(x)
      order by x.pay_rule_id,x.duty_id) from public.matrix_pay_rule_duties_v2 x
      where x.matrix_version_id=v_matrix),'[]'::jsonb) else '[]'::jsonb end,
    'payRuleLocations',case when v_finance then coalesce((select jsonb_agg(to_jsonb(x)
      order by x.pay_rule_id,x.location_id) from public.matrix_pay_rule_locations_v2 x
      where x.matrix_version_id=v_matrix),'[]'::jsonb) else '[]'::jsonb end,
    'payRuleShifts',case when v_finance then coalesce((select jsonb_agg(to_jsonb(x)
      order by x.pay_rule_id,x.shift_template_id) from public.matrix_pay_rule_shifts_v2 x
      where x.matrix_version_id=v_matrix),'[]'::jsonb) else '[]'::jsonb end,
    'scenarioPayRuleOverrides',case when v_finance then coalesce((select jsonb_agg(to_jsonb(x)
      order by x.scenario_id,x.pay_rule_id) from public.matrix_scenario_pay_rule_overrides_v2 x
      where x.matrix_version_id=v_matrix),'[]'::jsonb) else '[]'::jsonb end,
    'scenarioBudgets',case when v_finance then coalesce((select jsonb_agg(to_jsonb(x)
      order by x.scenario_id,x.budget_month,x.id) from public.matrix_scenario_budgets_v2 x
      where x.matrix_version_id=v_matrix
        and (v_month is null or x.budget_month is null or x.budget_month=v_month)),
      '[]'::jsonb) else '[]'::jsonb end,
    'employeePayRates',case when v_finance then coalesce((select jsonb_agg(to_jsonb(x)
      order by x.employee_id,x.valid_from desc) from public.employee_pay_rates_v2 x
      where v_month is null or (
        x.valid_from<(v_month+interval '1 month')::date
        and (x.valid_to is null or x.valid_to>=v_month))),
      '[]'::jsonb) else '[]'::jsonb end,
    'scopeGrants',coalesce((select jsonb_agg(to_jsonb(x)
      order by x.auth_user_id,x.app_role,x.id) from public.matrix_scope_grants_v2 x
      where v_owner_admin or x.auth_user_id=auth.uid()),'[]'::jsonb)
  ) into v_result
  from public.matrix_versions mv where mv.id=v_matrix;

  return v_result;
end;
$$;


ALTER FUNCTION "public"."matrix_v2_workspace_before_categories_uat_v1"("p_month" "date") OWNER TO "postgres";

--
-- Name: matrix_v2_workspace_before_employee_privacy_uat_v1("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_workspace_before_employee_privacy_uat_v1"("p_month" "date" DEFAULT NULL::"date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_payload jsonb:=public.matrix_v2_workspace_before_b4f52_uat_v1(p_month);
  v_visibility text:=public.application_finance_visibility_current_uat_v1();
  v_worker jsonb;
  v_workers jsonb:='[]'::jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if v_visibility='FULL' then
    return v_payload||jsonb_build_object('financeVisibility',v_visibility,'financeVisible',true);
  end if;

  for v_worker in
    select value from jsonb_array_elements(coalesce(v_payload->'adHocWorkers','[]'::jsonb))
  loop
    v_workers:=v_workers||jsonb_build_array(
      v_worker-'base_rate_minor'-'rateMinor'-'approved_rate_minor'-'currency'
    );
  end loop;

  v_payload:=jsonb_set(v_payload,'{adHocWorkers}',v_workers,true);
  v_payload:=jsonb_set(v_payload,'{payRules}','[]'::jsonb,true);
  v_payload:=jsonb_set(v_payload,'{payRuleRoles}','[]'::jsonb,true);
  v_payload:=jsonb_set(v_payload,'{payRuleDuties}','[]'::jsonb,true);
  v_payload:=jsonb_set(v_payload,'{payRuleLocations}','[]'::jsonb,true);
  v_payload:=jsonb_set(v_payload,'{payRuleShifts}','[]'::jsonb,true);
  v_payload:=jsonb_set(v_payload,'{scenarioPayRuleOverrides}','[]'::jsonb,true);
  v_payload:=jsonb_set(v_payload,'{scenarioBudgets}','[]'::jsonb,true);
  v_payload:=jsonb_set(v_payload,'{employeePayRates}','[]'::jsonb,true);
  v_payload:=jsonb_set(v_payload,'{financeVisible}','false'::jsonb,true);
  return v_payload||jsonb_build_object('financeVisibility',v_visibility);
end;
$$;


ALTER FUNCTION "public"."matrix_v2_workspace_before_employee_privacy_uat_v1"("p_month" "date") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_workspace_before_employee_privacy_uat_v1"("p_month" "date"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_workspace_before_employee_privacy_uat_v1"("p_month" "date") IS 'B4F-52 configuration workspace exposes exact finance configuration only at FULL visibility.';


--
-- Name: matrix_v2_workspace_before_overtime_uat_v1("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_workspace_before_overtime_uat_v1"("p_month" "date" DEFAULT NULL::"date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_result jsonb; v_matrix uuid; v_employees jsonb; v_employee jsonb;
begin
  v_result:=public.matrix_v2_workspace_before_categories_uat_v1(p_month);
  v_matrix:=(v_result->'matrixVersion'->>'id')::uuid;
  v_result:=jsonb_set(v_result,'{roleCategories}',coalesce((select jsonb_agg(to_jsonb(category) order by category.sort_order,category.code)
    from public.matrix_role_categories_v2 category where category.matrix_version_id=v_matrix),'[]'::jsonb),true);
  v_result:=jsonb_set(v_result,'{roles}',coalesce((select jsonb_agg(to_jsonb(role_row) order by role_row.sort_order,role_row.code)
    from public.matrix_roles_v2 role_row where role_row.matrix_version_id=v_matrix),'[]'::jsonb),true);
  v_employees:='[]'::jsonb;
  for v_employee in select value from jsonb_array_elements(coalesce(v_result->'employees','[]'::jsonb)) loop
    v_employee:=v_employee||coalesce((select jsonb_build_object(
      'employmentStage',profile.employment_stage,'probationEnd',profile.probation_end
    ) from public.matrix_employee_profiles_v2 profile
      where profile.matrix_version_id=v_matrix and profile.employee_id=(v_employee->>'id')::uuid),'{}'::jsonb);
    v_employees:=v_employees||jsonb_build_array(v_employee);
  end loop;
  v_result:=jsonb_set(v_result,'{employees}',v_employees,true);
  v_result:=jsonb_set(v_result,'{adHocWorkers}',coalesce((select jsonb_agg(to_jsonb(pool) order by pool.display_name,pool.id)
    from public.recovery_ad_hoc_pool_v2 pool where pool.active),'[]'::jsonb),true);
  return v_result;
end;
$$;


ALTER FUNCTION "public"."matrix_v2_workspace_before_overtime_uat_v1"("p_month" "date") OWNER TO "postgres";

--
-- Name: matrix_workspace("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_workspace"("p_month" "date" DEFAULT NULL::"date") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
with mv as (select * from matrix_versions where status='ACTIVE' order by version desc limit 1)
select jsonb_build_object(
 'version',(select to_jsonb(mv) from mv),
 'roles',coalesce((select jsonb_agg(to_jsonb(r) order by r.sort_order,r.name) from matrix_roles r join mv on mv.id=r.matrix_version_id),'[]'::jsonb),
 'locations',coalesce((select jsonb_agg(to_jsonb(l) order by l.name) from matrix_locations l join mv on mv.id=l.matrix_version_id),'[]'::jsonb),
 'functions',coalesce((select jsonb_agg(to_jsonb(f) order by f.name) from matrix_functions f join mv on mv.id=f.matrix_version_id),'[]'::jsonb),
 'shifts',coalesce((select jsonb_agg(to_jsonb(s) order by s.sort_order,s.name) from matrix_shift_templates s join mv on mv.id=s.matrix_version_id),'[]'::jsonb),
 'demand',coalesce((select jsonb_agg(to_jsonb(d)) from matrix_demand d join matrix_shift_templates s on s.id=d.shift_template_id join mv on mv.id=s.matrix_version_id),'[]'::jsonb),
 'sections',coalesce((select jsonb_agg(jsonb_build_object('id',rp.id,'month',rp.month,'role_id',rp.role_id,'role_code',r.code,'role_name',r.name,'version',rp.version,'status',rp.status,'name',rp.name,'updated_at',rp.updated_at) order by r.sort_order) from role_plan_sections rp join matrix_roles r on r.id=rp.role_id join mv on mv.id=rp.matrix_version_id where rp.month=coalesce(date_trunc('month',p_month)::date,date_trunc('month',current_date)::date)),'[]'::jsonb),
 'conflicts',coalesce((select jsonb_agg(to_jsonb(c) order by c.severity,c.created_at desc) from matrix_conflicts c where c.status='OPEN'),'[]'::jsonb)
);
$$;


ALTER FUNCTION "public"."matrix_workspace"("p_month" "date") OWNER TO "postgres";

--
-- Name: message_center_workspace_uat_v1(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."message_center_workspace_uat_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_user uuid:=auth.uid();
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  return jsonb_build_object(
    'currentUserId',v_user,
    'contacts',coalesce((
      select jsonb_agg(jsonb_build_object(
        'authUserId',source.auth_user_id,'employeeId',source.employee_id,
        'name',source.display_name,'email',source.email,
        'employeeNo',source.employee_no,'roleName',source.role_name,
        'avatarMode',source.avatar_mode,'catAvatarKey',source.cat_avatar_key
      ) order by source.display_name)
      from (
        select distinct on (directory.auth_user_id) directory.auth_user_id,
          employee.id employee_id,
          coalesce(nullif(trim(profile.display_name),''),
            nullif(trim(employee.first_name||' '||employee.last_name),''),directory.email) display_name,
          directory.email,employee.employee_no,coalesce(role_row.name,directory.app_role::text) role_name,
          coalesce(profile.avatar_mode,'INITIALS') avatar_mode,profile.cat_avatar_key
        from public.application_access_directory_v1 directory
        left join public.employees employee on employee.auth_user_id=directory.auth_user_id
        left join public.user_profiles_v1 profile on profile.auth_user_id=directory.auth_user_id
        left join lateral (
          select role_item.name from public.matrix_employee_roles_v2 employee_role
          join public.matrix_roles_v2 role_item on role_item.id=employee_role.role_id
          where employee_role.employee_id=employee.id and employee_role.active
          order by employee_role.is_primary desc limit 1
        ) role_row on true
        where directory.active and directory.auth_user_id is not null
          and directory.auth_user_id<>v_user
        order by directory.auth_user_id,(employee.id is not null) desc,directory.app_role::text
      ) source
    ),'[]'::jsonb),
    'conversations',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',conversation.id,'subject',conversation.subject,'kind',conversation.kind,
        'contextType',conversation.context_type,'contextId',conversation.context_id,
        'updatedAt',conversation.updated_at,
        'unreadCount',(select count(*) from public.team_messages_v1 unread
          where unread.conversation_id=conversation.id and unread.sender_user_id<>v_user
            and unread.created_at>coalesce(own_member.last_read_at,'epoch'::timestamptz)),
        'lastMessage',(select message.body from public.team_messages_v1 message
          where message.conversation_id=conversation.id order by message.created_at desc limit 1),
        'members',(select coalesce(jsonb_agg(jsonb_build_object(
          'authUserId',member.auth_user_id,
          'name',public.message_display_name_uat_v1(member.auth_user_id),
          'avatarMode',coalesce(profile.avatar_mode,'INITIALS'),
          'catAvatarKey',profile.cat_avatar_key
        ) order by public.message_display_name_uat_v1(member.auth_user_id)),'[]'::jsonb)
          from public.team_conversation_members_v1 member
          left join public.user_profiles_v1 profile on profile.auth_user_id=member.auth_user_id
          where member.conversation_id=conversation.id)
      ) order by conversation.updated_at desc)
      from public.team_conversation_members_v1 own_member
      join public.team_conversations_v1 conversation on conversation.id=own_member.conversation_id
      where own_member.auth_user_id=v_user
    ),'[]'::jsonb),
    'messages',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',message.id,'conversationId',message.conversation_id,
        'senderUserId',message.sender_user_id,
        'senderName',public.message_display_name_uat_v1(message.sender_user_id),
        'senderAvatarMode',coalesce(profile.avatar_mode,'INITIALS'),
        'senderCatAvatarKey',profile.cat_avatar_key,
        'body',message.body,'createdAt',message.created_at
      ) order by message.created_at)
      from public.team_messages_v1 message
      left join public.user_profiles_v1 profile on profile.auth_user_id=message.sender_user_id
      where exists(select 1 from public.team_conversation_members_v1 member
        where member.conversation_id=message.conversation_id and member.auth_user_id=v_user)
    ),'[]'::jsonb)
  );
end;
$$;


ALTER FUNCTION "public"."message_center_workspace_uat_v1"() OWNER TO "postgres";

--
-- Name: message_conversation_create_uat_v1("uuid", "text", "text", "text", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."message_conversation_create_uat_v1"("p_recipient_auth_user_id" "uuid", "p_subject" "text", "p_message" "text", "p_context_type" "text" DEFAULT NULL::"text", "p_context_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_user uuid:=auth.uid();v_conversation uuid;v_employee uuid;
  v_subject text:=coalesce(nullif(trim(p_subject),''),'Rozmowa zespołu');
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_recipient_auth_user_id is null or p_recipient_auth_user_id=v_user then
    raise exception 'RECIPIENT_NOT_FOUND';
  end if;
  if nullif(trim(p_message),'') is null then raise exception 'EMPTY_MESSAGE'; end if;
  if not exists(select 1 from public.application_access_directory_v1 directory
    where directory.auth_user_id=p_recipient_auth_user_id and directory.active) then
    raise exception 'RECIPIENT_NOT_FOUND';
  end if;
  insert into public.team_conversations_v1(kind,subject,context_type,context_id,created_by)
  values(case when p_context_type='SWAP' then 'SWAP' else 'DIRECT' end,
    v_subject,p_context_type,p_context_id,v_user) returning id into v_conversation;
  select employee.id into v_employee from public.employees employee
    where employee.auth_user_id=v_user limit 1;
  insert into public.team_conversation_members_v1(conversation_id,auth_user_id,employee_id,last_read_at)
  values(v_conversation,v_user,v_employee,now());
  select employee.id into v_employee from public.employees employee
    where employee.auth_user_id=p_recipient_auth_user_id limit 1;
  insert into public.team_conversation_members_v1(conversation_id,auth_user_id,employee_id)
  values(v_conversation,p_recipient_auth_user_id,v_employee);
  insert into public.team_messages_v1(conversation_id,sender_user_id,body)
  values(v_conversation,v_user,trim(p_message));
  insert into public.notifications(
    recipient_id,title,body,kind,context_type,context_id,action_route,action_required
  ) values(
    p_recipient_auth_user_id,
    'Nowa wiadomość od '||public.message_display_name_uat_v1(v_user),
    v_subject||': '||left(trim(p_message),240),'MESSAGE','TEAM_CONVERSATION',
    v_conversation::text,
    public.personal_message_action_route_uat_v1(p_recipient_auth_user_id,v_conversation),false
  );
  return jsonb_build_object('conversationId',v_conversation);
end;
$$;


ALTER FUNCTION "public"."message_conversation_create_uat_v1"("p_recipient_auth_user_id" "uuid", "p_subject" "text", "p_message" "text", "p_context_type" "text", "p_context_id" "uuid") OWNER TO "postgres";

--
-- Name: message_display_name_uat_v1("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."message_display_name_uat_v1"("p_auth_user_id" "uuid") RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select coalesce(
    (select nullif(trim(profile.display_name),'') from public.user_profiles_v1 profile
      where profile.auth_user_id=p_auth_user_id),
    (select nullif(trim(employee.first_name||' '||employee.last_name),'')
      from public.employees employee where employee.auth_user_id=p_auth_user_id limit 1),
    (select auth_user.email from auth.users auth_user where auth_user.id=p_auth_user_id),
    'Użytkownik SZAFUNEK'
  );
$$;


ALTER FUNCTION "public"."message_display_name_uat_v1"("p_auth_user_id" "uuid") OWNER TO "postgres";

--
-- Name: message_mark_read_uat_v1("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."message_mark_read_uat_v1"("p_conversation_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_user uuid:=auth.uid();
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  update public.team_conversation_members_v1 set last_read_at=now()
  where conversation_id=p_conversation_id and auth_user_id=v_user;
  if not found then raise exception 'CONVERSATION_FORBIDDEN'; end if;
  update public.notifications set read_at=coalesce(read_at,now()),resolved_at=now(),resolution='READ'
  where recipient_id=v_user and context_type='TEAM_CONVERSATION'
    and context_id=p_conversation_id::text and resolved_at is null;
  return true;
end;
$$;


ALTER FUNCTION "public"."message_mark_read_uat_v1"("p_conversation_id" "uuid") OWNER TO "postgres";

--
-- Name: message_send_uat_v1("uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."message_send_uat_v1"("p_conversation_id" "uuid", "p_body" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_user uuid:=auth.uid();v_message uuid;v_recipient uuid;v_subject text;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if nullif(trim(p_body),'') is null then raise exception 'EMPTY_MESSAGE'; end if;
  if not exists(select 1 from public.team_conversation_members_v1 member
    where member.conversation_id=p_conversation_id and member.auth_user_id=v_user) then
    raise exception 'CONVERSATION_FORBIDDEN';
  end if;
  insert into public.team_messages_v1(conversation_id,sender_user_id,body)
  values(p_conversation_id,v_user,trim(p_body)) returning id into v_message;
  update public.team_conversations_v1 set updated_at=now()
    where id=p_conversation_id returning subject into v_subject;
  update public.team_conversation_members_v1 set last_read_at=now()
    where conversation_id=p_conversation_id and auth_user_id=v_user;
  for v_recipient in select member.auth_user_id
    from public.team_conversation_members_v1 member
    where member.conversation_id=p_conversation_id and member.auth_user_id<>v_user
  loop
    update public.notifications set
      title='Nowa wiadomość od '||public.message_display_name_uat_v1(v_user),
      body=v_subject||': '||left(trim(p_body),240),kind='MESSAGE',
      action_route=public.personal_message_action_route_uat_v1(v_recipient,p_conversation_id),
      read_at=null,resolved_at=null,resolution=null,created_at=now()
    where recipient_id=v_recipient and context_type='TEAM_CONVERSATION'
      and context_id=p_conversation_id::text and resolved_at is null;
    if not found then
      insert into public.notifications(
        recipient_id,title,body,kind,context_type,context_id,action_route,action_required
      ) values(v_recipient,
        'Nowa wiadomość od '||public.message_display_name_uat_v1(v_user),
        v_subject||': '||left(trim(p_body),240),'MESSAGE','TEAM_CONVERSATION',
        p_conversation_id::text,
        public.personal_message_action_route_uat_v1(v_recipient,p_conversation_id),false);
    end if;
  end loop;
  return jsonb_build_object('messageId',v_message);
end;
$$;


ALTER FUNCTION "public"."message_send_uat_v1"("p_conversation_id" "uuid", "p_body" "text") OWNER TO "postgres";

--
-- Name: monthly_budgets_get_before_b4f52_uat_v1("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."monthly_budgets_get_before_b4f52_uat_v1"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_revision public.monthly_budget_revisions_v2%rowtype;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE')) then
    raise exception 'BUDGET_VIEW_FORBIDDEN';
  end if;
  select * into v_revision from public.monthly_budget_revisions_v2
    where budget_month = date_trunc('month', p_month)::date and status = 'ACTIVE';
  return jsonb_build_object(
    'month', date_trunc('month', p_month)::date,
    'canEdit', public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE'),
    'revision', case when v_revision.id is null then null else jsonb_build_object(
      'id', v_revision.id, 'number', v_revision.revision, 'note', v_revision.note,
      'createdAt', v_revision.created_at
    ) end,
    'lines', coalesce((select jsonb_agg(jsonb_build_object(
      'id', line.id, 'scopeType', line.scope_type,
      'locationLogicalId', line.location_logical_id,
      'categoryLogicalId', line.category_logical_id, 'roleLogicalId', line.role_logical_id,
      'metricType', line.metric_type, 'enforcement', line.enforcement,
      'limitValue', line.limit_value, 'referenceValue', line.reference_value,
      'currency', line.currency, 'costBasis', line.cost_basis,
      'distributionMode', line.distribution_mode, 'distribution', line.distribution
    ) order by line.scope_type, line.location_logical_id, line.category_logical_id, line.role_logical_id, line.metric_type)
    from public.monthly_budget_lines_v2 line where line.revision_id = v_revision.id), '[]'::jsonb)
  );
end;
$$;


ALTER FUNCTION "public"."monthly_budgets_get_before_b4f52_uat_v1"("p_month" "date") OWNER TO "postgres";

--
-- Name: monthly_budgets_get_uat_v1("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."monthly_budgets_get_uat_v1"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_payload jsonb:=public.monthly_budgets_get_before_b4f52_uat_v1(p_month);
  v_visibility text:=public.application_finance_visibility_current_uat_v1();
  v_configured boolean:=jsonb_array_length(coalesce(v_payload->'lines','[]'::jsonb))>0;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if v_visibility in ('FULL','AGGREGATE') then
    return v_payload||jsonb_build_object('financeVisibility',v_visibility);
  end if;
  if v_visibility='BUDGET_ONLY' then
    return jsonb_build_object(
      'month',date_trunc('month',p_month)::date,
      'canEdit',false,
      'revision',null,
      'lines','[]'::jsonb,
      'budgetStatus',jsonb_build_object('configured',v_configured),
      'financeVisibility',v_visibility
    );
  end if;
  return jsonb_build_object(
    'month',date_trunc('month',p_month)::date,
    'canEdit',false,
    'revision',null,
    'lines','[]'::jsonb,
    'financeVisibility','NONE'
  );
end;
$$;


ALTER FUNCTION "public"."monthly_budgets_get_uat_v1"("p_month" "date") OWNER TO "postgres";

--
-- Name: FUNCTION "monthly_budgets_get_uat_v1"("p_month" "date"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."monthly_budgets_get_uat_v1"("p_month" "date") IS 'B4F-52 monthly budgets respect FULL, AGGREGATE, BUDGET_ONLY and NONE visibility.';


--
-- Name: monthly_budgets_save_uat_v1("date", "jsonb", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."monthly_budgets_save_uat_v1"("p_month" "date", "p_lines" "jsonb", "p_note" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_month date := date_trunc('month', p_month)::date;
  v_revision_id uuid; v_revision integer; v_line jsonb; v_scope text;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE')) then
    raise exception 'BUDGET_EDIT_FORBIDDEN';
  end if;
  if jsonb_typeof(p_lines) <> 'array' then raise exception 'BUDGET_LINES_MUST_BE_ARRAY'; end if;
  perform pg_advisory_xact_lock(hashtext('monthly-budget:' || v_month::text));
  select coalesce(max(revision),0)+1 into v_revision from public.monthly_budget_revisions_v2 where budget_month=v_month;
  update public.monthly_budget_revisions_v2 set status='ARCHIVED', archived_at=now()
    where budget_month=v_month and status='ACTIVE';
  insert into public.monthly_budget_revisions_v2(budget_month,revision,status,note,created_by)
    values(v_month,v_revision,'ACTIVE',nullif(trim(p_note),''),auth.uid()) returning id into v_revision_id;
  for v_line in select value from jsonb_array_elements(p_lines) loop
    v_scope:=upper(coalesce(v_line->>'scopeType',''));
    if v_scope not in ('COMPANY','LOCATION','CATEGORY','LOCATION_CATEGORY','ROLE') then raise exception 'INVALID_BUDGET_SCOPE'; end if;
    insert into public.monthly_budget_lines_v2(
      revision_id,scope_type,location_logical_id,category_logical_id,role_logical_id,
      metric_type,enforcement,limit_value,reference_value,currency,cost_basis,
      distribution_mode,distribution
    ) values(
      v_revision_id,v_scope,coalesce(nullif(v_line->>'locationLogicalId','')::uuid,(
        select location_row.logical_id from public.matrix_locations_v2 location_row
        where location_row.id=nullif(v_line->>'locationId','')::uuid limit 1
      )),coalesce(nullif(v_line->>'categoryLogicalId','')::uuid,(
        select category.logical_id from public.matrix_role_categories_v2 category
        where category.id=nullif(v_line->>'categoryId','')::uuid limit 1
      )),coalesce(nullif(v_line->>'roleLogicalId','')::uuid,(
        select role_row.logical_id from public.matrix_roles_v2 role_row
        where role_row.id=nullif(v_line->>'roleId','')::uuid limit 1
      )),upper(coalesce(nullif(v_line->>'metricType',''),'COST')),
      upper(coalesce(nullif(v_line->>'enforcement',''),'TARGET')),
      coalesce((v_line->>'limitValue')::numeric,0),nullif(v_line->>'referenceValue','')::numeric,
      case when upper(coalesce(nullif(v_line->>'metricType',''),'COST'))='COST'
        then upper(coalesce(nullif(v_line->>'currency',''),'PLN')) else null end,
      case when upper(coalesce(nullif(v_line->>'metricType',''),'COST'))='COST'
        then upper(coalesce(nullif(v_line->>'costBasis',''),'WAGES')) else null end,
      upper(coalesce(nullif(v_line->>'distributionMode',''),'MONTHLY')),
      case when jsonb_typeof(v_line->'distribution')='object' then v_line->'distribution' else null end
    );
  end loop;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
    values(auth.uid(),'monthly_budget_revision',v_revision_id::text,'PUBLISH',
      jsonb_build_object('month',v_month,'revision',v_revision,'lineCount',jsonb_array_length(p_lines),'note',p_note));
  return public.monthly_budgets_get_uat_v1(v_month);
end;
$$;


ALTER FUNCTION "public"."monthly_budgets_save_uat_v1"("p_month" "date", "p_lines" "jsonb", "p_note" "text") OWNER TO "postgres";

--
-- Name: operational_program_can_manage_uat_v1(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."operational_program_can_manage_uat_v1"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select auth.uid() is not null and (
    public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('ROLE_MANAGER') or public.has_app_role('LOCATION_MANAGER')
  );
$$;


ALTER FUNCTION "public"."operational_program_can_manage_uat_v1"() OWNER TO "postgres";

--
-- Name: operational_program_cancel_uat_v1("uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."operational_program_cancel_uat_v1"("p_event_id" "uuid", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_actor uuid:=auth.uid(); v_event public.operational_program_events_v1%rowtype;
begin
  if not public.operational_program_can_manage_uat_v1() then raise exception 'FORBIDDEN'; end if;
  if length(trim(coalesce(p_reason,'')))<3 then raise exception 'CANCELLATION_REASON_REQUIRED'; end if;
  update public.operational_program_events_v1 set status='CANCELLED',cancellation_reason=trim(p_reason),
    cancelled_by=v_actor,cancelled_at=now(),updated_at=now()
    where id=p_event_id and status not in('CANCELLED','COMPLETED') returning * into v_event;
  if v_event.id is null then raise exception 'EVENT_NOT_CANCELLABLE'; end if;
  update public.operational_program_participants_v1 set assignment_status='CANCELLED',updated_at=now()
    where event_id=p_event_id;
  update public.operational_program_inventory_links_v1 set sync_status='CANCELLED',updated_at=now()
    where event_id=p_event_id;
  delete from public.time_records where source='OPERATIONAL_EVENT:'||p_event_id::text and status='OPEN';
  insert into public.notifications(recipient_id,channel,title,body,sent_at)
    select distinct participant.auth_user_id,'IN_APP','Anulowano: '||v_event.title,trim(p_reason),now()
    from public.operational_program_participants_v1 participant
    where participant.event_id=p_event_id and participant.auth_user_id is not null;
  insert into public.operational_program_audit_v1(event_id,actor_id,action,detail)
    values(p_event_id,v_actor,'CANCEL',jsonb_build_object('reason',trim(p_reason)));
  return jsonb_build_object('id',p_event_id,'status','CANCELLED');
end;
$$;


ALTER FUNCTION "public"."operational_program_cancel_uat_v1"("p_event_id" "uuid", "p_reason" "text") OWNER TO "postgres";

--
-- Name: operational_program_integration_save_uat_v1("text", "text", boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."operational_program_integration_save_uat_v1"("p_base_url" "text", "p_launch_path_template" "text" DEFAULT '/sessions/new?eventId={eventId}'::"text", "p_active" boolean DEFAULT true) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_actor uuid:=auth.uid(); v_row public.business_app_integrations_v1%rowtype;
begin
  if v_actor is null or not(public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if trim(coalesce(p_base_url,'')) !~ '^https?://' then raise exception 'INVALID_INTEGRATION_URL'; end if;
  if position('{eventId}' in coalesce(p_launch_path_template,''))=0 then raise exception 'EVENT_ID_PLACEHOLDER_REQUIRED'; end if;
  update public.business_app_integrations_v1 set base_url=rtrim(trim(p_base_url),'/'),
    launch_path_template=trim(p_launch_path_template),active=p_active,
    connection_status=case when p_active then 'CONFIGURED' else 'DISCONNECTED' end,
    updated_by=v_actor,updated_at=now() where product_code='INVETORY_PRO' returning * into v_row;
  return jsonb_build_object('id',v_row.id,'status',v_row.connection_status,'active',v_row.active,'baseUrl',v_row.base_url);
end;
$$;


ALTER FUNCTION "public"."operational_program_integration_save_uat_v1"("p_base_url" "text", "p_launch_path_template" "text", "p_active" boolean) OWNER TO "postgres";

--
-- Name: operational_program_inventory_ack_uat_v1("uuid", "text", "text", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."operational_program_inventory_ack_uat_v1"("p_event_id" "uuid", "p_external_session_id" "text", "p_external_session_url" "text", "p_status" "text" DEFAULT 'READY'::"text", "p_error" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_actor uuid:=auth.uid(); v_status text:=upper(trim(p_status));
begin
  if not public.operational_program_can_manage_uat_v1() then raise exception 'FORBIDDEN'; end if;
  if v_status not in('READY','ERROR','COMPLETED') then raise exception 'INVALID_SYNC_STATUS'; end if;
  update public.operational_program_inventory_links_v1 set
    external_session_id=nullif(trim(p_external_session_id),''),
    external_session_url=coalesce(nullif(trim(p_external_session_url),''),external_session_url),
    sync_status=v_status,last_error=nullif(trim(p_error),''),attempt_count=attempt_count+1,
    last_attempt_at=now(),synced_at=case when v_status in('READY','COMPLETED') then now() else synced_at end,
    updated_at=now() where event_id=p_event_id;
  if not found then raise exception 'INVENTORY_LINK_NOT_FOUND'; end if;
  insert into public.operational_program_audit_v1(event_id,actor_id,action,detail)
    values(p_event_id,v_actor,'INVENTORY_SYNC',jsonb_build_object('status',v_status,'externalSessionId',p_external_session_id,'error',p_error));
  return jsonb_build_object('eventId',p_event_id,'status',v_status);
end;
$$;


ALTER FUNCTION "public"."operational_program_inventory_ack_uat_v1"("p_event_id" "uuid", "p_external_session_id" "text", "p_external_session_url" "text", "p_status" "text", "p_error" "text") OWNER TO "postgres";

--
-- Name: operational_program_preview_uat_v1("date", timestamp with time zone, timestamp with time zone, "uuid", "uuid"[], "uuid"[], "uuid"[], integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."operational_program_preview_uat_v1"("p_month" "date", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_location_id" "uuid" DEFAULT NULL::"uuid", "p_category_ids" "uuid"[] DEFAULT '{}'::"uuid"[], "p_role_ids" "uuid"[] DEFAULT '{}'::"uuid"[], "p_employee_ids" "uuid"[] DEFAULT '{}'::"uuid"[], "p_required_count" integer DEFAULT 1) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_matrix uuid; v_month date:=date_trunc('month',p_month)::date;
begin
  if not public.operational_program_can_manage_uat_v1() then raise exception 'FORBIDDEN'; end if;
  if p_ends_at<=p_starts_at then raise exception 'INVALID_EVENT_RANGE'; end if;
  select id into v_matrix from public.matrix_versions
    where status in('ACTIVE','ARCHIVED') and schema_version>=2
      and effective_from<=v_month
    order by effective_from desc,version desc limit 1;
  if v_matrix is null then raise exception 'PUBLISHED_CONFIGURATION_NOT_FOUND'; end if;

  return jsonb_build_object(
    'requiredCount',greatest(1,coalesce(p_required_count,1)),
    'candidates',coalesce((
      with scoped as (
        select profile.employee_id,profile.employee_no,profile.first_name,profile.last_name,
          profile.nominal_monthly_minutes,profile.maximum_monthly_minutes,
          profile.maximum_weekly_minutes,coalesce(profile.minimum_rest_minutes,660) minimum_rest_minutes,
          employee.auth_user_id,
          exists(select 1 from public.matrix_employee_locations_v2 location_grant
            where location_grant.matrix_version_id=v_matrix
              and location_grant.employee_id=profile.employee_id and location_grant.active
              and (p_location_id is null or location_grant.location_id=p_location_id)) location_ok
        from public.matrix_employee_profiles_v2 profile
        join public.employees employee on employee.id=profile.employee_id
        where profile.matrix_version_id=v_matrix and profile.active
          and employee.active and employee.archived_at is null
          and (cardinality(p_employee_ids)=0 or profile.employee_id=any(p_employee_ids))
          and (cardinality(p_employee_ids)>0 or (
            cardinality(p_role_ids)=0 or exists(
              select 1 from public.matrix_employee_roles_v2 role_grant
              where role_grant.matrix_version_id=v_matrix and role_grant.employee_id=profile.employee_id
                and role_grant.role_id=any(p_role_ids) and role_grant.active
            )
          ))
          and (cardinality(p_employee_ids)>0 or cardinality(p_category_ids)=0 or exists(
            select 1 from public.matrix_employee_roles_v2 role_grant
            join public.matrix_roles_v2 role_row on role_row.id=role_grant.role_id
            where role_grant.matrix_version_id=v_matrix and role_grant.employee_id=profile.employee_id
              and role_grant.active and role_row.category_id=any(p_category_ids)
          ))
      ), evaluated as (
        select scoped.*,
          exists(select 1 from public.employee_time_constraints_v2 constraint_row
            where constraint_row.employee_id=scoped.employee_id and constraint_row.status='ACTIVE'
              and constraint_row.constraint_kind in('UNAVAILABLE','LEAVE','SICKNESS')
              and constraint_row.time_range && tstzrange(p_starts_at,p_ends_at,'[)')) unavailable,
          exists(select 1 from public.published_schedules_v2 schedule
            join public.published_schedule_variants_v2 link on link.schedule_id=schedule.id
            join public.plan_assignments_v2 assignment on assignment.variant_id=link.variant_id
            join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
            where schedule.month=v_month and schedule.status='PUBLISHED'
              and assignment.employee_id=scoped.employee_id
              and tstzrange(shift_row.starts_at,shift_row.ends_at,'[)') && tstzrange(p_starts_at,p_ends_at,'[)')) overlaps_shift,
          exists(select 1 from public.published_schedules_v2 schedule
            join public.published_schedule_variants_v2 link on link.schedule_id=schedule.id
            join public.plan_assignments_v2 assignment on assignment.variant_id=link.variant_id
            join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
            where schedule.month=v_month and schedule.status='PUBLISHED'
              and assignment.employee_id=scoped.employee_id
              and not (shift_row.ends_at<=p_starts_at-scoped.minimum_rest_minutes*interval '1 minute'
                or shift_row.starts_at>=p_ends_at+scoped.minimum_rest_minutes*interval '1 minute')) rest_risk,
          coalesce((select round(sum(extract(epoch from (shift_row.ends_at-shift_row.starts_at))/60))::integer
            from public.published_schedules_v2 schedule
            join public.published_schedule_variants_v2 link on link.schedule_id=schedule.id
            join public.plan_assignments_v2 assignment on assignment.variant_id=link.variant_id
            join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
            where schedule.month=v_month and schedule.status='PUBLISHED'
              and assignment.employee_id=scoped.employee_id),0) planned_minutes
        from scoped
      )
      select jsonb_agg(jsonb_build_object(
        'employeeId',employee_id,'employeeNo',employee_no,
        'name',first_name||' '||last_name,'authUserId',auth_user_id,
        'status',case when unavailable or overlaps_shift then 'BLOCKED'
          when not location_ok or rest_risk then 'WARNING' else 'SAFE' end,
        'reasons',to_jsonb(array_remove(array[
          case when unavailable then 'Twarda niedostępność, urlop albo L4' end,
          case when overlaps_shift then 'Ma już zmianę w tych godzinach' end,
          case when not location_ok then 'Brak przypisania do wybranego lokalu' end,
          case when rest_risk and not overlaps_shift then 'Ryzyko naruszenia odpoczynku' end
        ],null)),
        'plannedMinutes',planned_minutes,'nominalMinutes',nominal_monthly_minutes,
        'maximumMinutes',maximum_monthly_minutes
      ) order by
        case when unavailable or overlaps_shift then 3 when not location_ok or rest_risk then 2 else 1 end,
        abs(nominal_monthly_minutes-planned_minutes),last_name,first_name)
      from evaluated
    ),'[]'::jsonb)
  );
end;
$$;


ALTER FUNCTION "public"."operational_program_preview_uat_v1"("p_month" "date", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_location_id" "uuid", "p_category_ids" "uuid"[], "p_role_ids" "uuid"[], "p_employee_ids" "uuid"[], "p_required_count" integer) OWNER TO "postgres";

--
-- Name: operational_program_save_uat_v1("jsonb", "jsonb", "jsonb", "uuid"[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."operational_program_save_uat_v1"("p_event" "jsonb", "p_audience" "jsonb" DEFAULT '[]'::"jsonb", "p_checklist" "jsonb" DEFAULT '[]'::"jsonb", "p_participant_ids" "uuid"[] DEFAULT '{}'::"uuid"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_actor uuid:=auth.uid(); v_id uuid; v_item jsonb; v_preview jsonb; v_candidate jsonb;
  v_employee uuid; v_integration public.business_app_integrations_v1%rowtype; v_path text; v_url text;
  v_event public.operational_program_events_v1%rowtype;
begin
  if not public.operational_program_can_manage_uat_v1() then raise exception 'FORBIDDEN'; end if;
  if upper(coalesce(p_event->>'status','DRAFT')) not in('DRAFT','ANALYSIS','PUBLISHED') then
    raise exception 'INVALID_EVENT_STATUS';
  end if;
  insert into public.operational_program_events_v1(
    event_type,title,description,location_id,starts_at,ends_at,status,audience_mode,
    required_count,inventory_type,inventory_groups,private_note,published_note,agenda,
    created_by,published_by,published_at
  ) values(
    upper(trim(p_event->>'type')),trim(p_event->>'title'),nullif(trim(p_event->>'description'),''),
    nullif(p_event->>'locationId','')::uuid,(p_event->>'startsAt')::timestamptz,(p_event->>'endsAt')::timestamptz,
    upper(coalesce(p_event->>'status','DRAFT')),upper(coalesce(p_event->>'audienceMode','NEED_COUNT')),
    nullif(p_event->>'requiredCount','')::integer,
    case when upper(trim(p_event->>'type'))='INVENTORY' then upper(coalesce(p_event->>'inventoryType','FULL')) else null end,
    coalesce(array(select jsonb_array_elements_text(coalesce(p_event->'inventoryGroups','[]'::jsonb))),'{}'),
    nullif(p_event->>'privateNote',''),nullif(p_event->>'publishedNote',''),nullif(p_event->>'agenda',''),v_actor,
    case when upper(coalesce(p_event->>'status','DRAFT'))='PUBLISHED' then v_actor end,
    case when upper(coalesce(p_event->>'status','DRAFT'))='PUBLISHED' then now() end
  ) returning * into v_event;
  v_id:=v_event.id;

  for v_item in select value from jsonb_array_elements(coalesce(p_audience,'[]'::jsonb)) loop
    insert into public.operational_program_audience_rules_v1(
      event_id,rule_mode,scope_type,scope_uuid,scope_code
    ) values(v_id,upper(coalesce(v_item->>'mode','INCLUDE')),upper(v_item->>'type'),
      nullif(v_item->>'id','')::uuid,nullif(v_item->>'code',''));
  end loop;
  for v_item in select value from jsonb_array_elements(coalesce(p_checklist,'[]'::jsonb)) loop
    insert into public.operational_program_checklist_items_v1(event_id,item_order,label,visibility,visible_to)
    values(v_id,coalesce(nullif(v_item->>'order','')::integer,0),trim(v_item->>'label'),
      upper(coalesce(v_item->>'visibility','ALL')),coalesce(v_item->'visibleTo','[]'::jsonb));
  end loop;

  if cardinality(p_participant_ids)>0 then
    v_preview:=public.operational_program_preview_uat_v1(
      date_trunc('month',v_event.starts_at)::date,v_event.starts_at,v_event.ends_at,v_event.location_id,
      coalesce(array(select (x->>'id')::uuid from jsonb_array_elements(p_audience) x where upper(x->>'type')='CATEGORY' and upper(coalesce(x->>'mode','INCLUDE'))='INCLUDE'),'{}'),
      coalesce(array(select (x->>'id')::uuid from jsonb_array_elements(p_audience) x where upper(x->>'type')='ROLE' and upper(coalesce(x->>'mode','INCLUDE'))='INCLUDE'),'{}'),
      p_participant_ids,coalesce(v_event.required_count,cardinality(p_participant_ids)));
    foreach v_employee in array p_participant_ids loop
      select value into v_candidate from jsonb_array_elements(v_preview->'candidates')
        where value->>'employeeId'=v_employee::text limit 1;
      if v_candidate is null then raise exception 'PARTICIPANT_NOT_IN_ACTIVE_CONFIGURATION|%',v_employee; end if;
      if v_candidate->>'status'='BLOCKED' then raise exception 'PARTICIPANT_HARD_BLOCK|%|%',v_employee,v_candidate->'reasons'; end if;
      if v_candidate->>'status'='WARNING' and length(trim(coalesce(p_event->>'overrideReason','')))<5 then
        raise exception 'PARTICIPANT_WARNING_REQUIRES_REASON|%|%',v_employee,v_candidate->'reasons';
      end if;
      insert into public.operational_program_participants_v1(
        event_id,employee_id,auth_user_id,selection_source,candidate_status,reasons,
        assignment_status,override_reason
      ) select v_id,v_employee,employee.auth_user_id,
        case when upper(coalesce(p_event->>'audienceMode','NEED_COUNT'))='ALL_SCOPE' then 'SCOPE' else 'MANAGER' end,
        v_candidate->>'status',coalesce(array(select jsonb_array_elements_text(v_candidate->'reasons')),'{}'),
        'CONFIRMED',case when v_candidate->>'status'='WARNING' then trim(p_event->>'overrideReason') end
      from public.employees employee where employee.id=v_employee;
    end loop;
  end if;
  if v_event.audience_mode='NEED_COUNT' and cardinality(p_participant_ids)<coalesce(v_event.required_count,1)
    and v_event.status='PUBLISHED' then raise exception 'NOT_ENOUGH_PARTICIPANTS'; end if;

  if v_event.status='PUBLISHED' then
    insert into public.notifications(recipient_id,channel,title,body,sent_at)
    select distinct participant.auth_user_id,'IN_APP','Nowe wydarzenie: '||v_event.title,
      to_char(v_event.starts_at at time zone 'Europe/Warsaw','DD.MM.YYYY HH24:MI')||
        coalesce(' • '||v_event.published_note,''),now()
    from public.operational_program_participants_v1 participant
    where participant.event_id=v_id and participant.auth_user_id is not null;

    insert into public.time_records(employee_id,work_date,planned_start,planned_end,source,status)
    select participant.employee_id,(v_event.starts_at at time zone 'Europe/Warsaw')::date,
      v_event.starts_at,v_event.ends_at,'OPERATIONAL_EVENT:'||v_id::text,'OPEN'
    from public.operational_program_participants_v1 participant
    where participant.event_id=v_id and participant.employee_id is not null
    on conflict(employee_id,work_date,planned_start) do update set
      planned_end=excluded.planned_end,source=excluded.source;

    if v_event.event_type='INVENTORY' then
      select * into v_integration from public.business_app_integrations_v1 where product_code='INVETORY_PRO';
      v_path:=replace(v_integration.launch_path_template,'{eventId}',v_id::text);
      v_url:=case when v_integration.active and v_integration.base_url is not null
        then rtrim(v_integration.base_url,'/')||'/'||ltrim(v_path,'/') end;
      insert into public.operational_program_inventory_links_v1(
        event_id,integration_id,external_session_url,sync_status,payload,payload_hash
      ) values(v_id,v_integration.id,v_url,
        case when v_url is null then 'WAITING_CONFIGURATION' else 'QUEUED' end,
        jsonb_build_object('eventId',v_id,'title',v_event.title,'type',v_event.inventory_type,
          'groups',v_event.inventory_groups,'startsAt',v_event.starts_at,'endsAt',v_event.ends_at,
          'locationId',v_event.location_id,'participants',to_jsonb(p_participant_ids)),
        encode(extensions.digest((jsonb_build_object('eventId',v_id,'version',v_event.version_no))::text,'sha256'),'hex'));
    end if;
  end if;
  insert into public.operational_program_audit_v1(event_id,actor_id,action,detail)
    values(v_id,v_actor,case when v_event.status='PUBLISHED' then 'PUBLISH' else 'SAVE_DRAFT' end,
      jsonb_build_object('status',v_event.status,'participantCount',cardinality(p_participant_ids)));
  return jsonb_build_object('id',v_id,'status',v_event.status,'participantCount',cardinality(p_participant_ids));
end;
$$;


ALTER FUNCTION "public"."operational_program_save_uat_v1"("p_event" "jsonb", "p_audience" "jsonb", "p_checklist" "jsonb", "p_participant_ids" "uuid"[]) OWNER TO "postgres";

--
-- Name: operational_program_workspace_uat_v1("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."operational_program_workspace_uat_v1"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_actor uuid:=auth.uid(); v_month date:=date_trunc('month',p_month)::date;
  v_matrix uuid; v_can_manage boolean; v_employee uuid;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  v_can_manage:=public.operational_program_can_manage_uat_v1();
  select id into v_matrix from public.matrix_versions
    where status in('ACTIVE','ARCHIVED') and schema_version>=2 and effective_from<=v_month
    order by effective_from desc,version desc limit 1;
  select id into v_employee from public.employees where auth_user_id=v_actor and active and archived_at is null limit 1;
  return jsonb_build_object(
    'canManage',v_can_manage,
    'canConfigureIntegration',public.has_app_role('OWNER') or public.has_app_role('ADMIN'),
    'integration',coalesce((select jsonb_build_object(
      'id',integration.id,'productCode',integration.product_code,'displayName',integration.display_name,
      'baseUrl',integration.base_url,'launchPathTemplate',integration.launch_path_template,
      'status',integration.connection_status,'active',integration.active
    ) from public.business_app_integrations_v1 integration where integration.product_code='INVETORY_PRO'),'null'::jsonb),
    'categories',coalesce((select jsonb_agg(jsonb_build_object(
      'id',category.id,'code',category.code,'name',category.name,'color',category.color
    ) order by category.sort_order,category.name) from public.matrix_role_categories_v2 category
      where category.matrix_version_id=v_matrix and category.active),'[]'::jsonb),
    'roles',coalesce((select jsonb_agg(jsonb_build_object(
      'id',role_row.id,'code',role_row.code,'name',role_row.name,'categoryId',role_row.category_id,'color',role_row.color
    ) order by role_row.sort_order,role_row.name) from public.matrix_roles_v2 role_row
      where role_row.matrix_version_id=v_matrix and role_row.active),'[]'::jsonb),
    'locations',coalesce((select jsonb_agg(jsonb_build_object(
      'id',location_row.id,'code',location_row.code,'name',location_row.name
    ) order by location_row.sort_order,location_row.name) from public.matrix_locations_v2 location_row
      where location_row.matrix_version_id=v_matrix and location_row.active),'[]'::jsonb),
    'employees',case when v_can_manage then coalesce((select jsonb_agg(jsonb_build_object(
      'id',profile.employee_id,'employeeNo',profile.employee_no,'name',profile.first_name||' '||profile.last_name,
      'email',profile.email
    ) order by profile.last_name,profile.first_name) from public.matrix_employee_profiles_v2 profile
      where profile.matrix_version_id=v_matrix and profile.active),'[]'::jsonb) else '[]'::jsonb end,
    'events',coalesce((select jsonb_agg(jsonb_build_object(
      'id',event_row.id,'type',event_row.event_type,'title',event_row.title,
      'description',event_row.description,'startsAt',event_row.starts_at,'endsAt',event_row.ends_at,
      'status',event_row.status,'audienceMode',event_row.audience_mode,'requiredCount',event_row.required_count,
      'locationId',event_row.location_id,'locationName',location_row.name,
      'publishedNote',event_row.published_note,'agenda',event_row.agenda,
      'inventoryType',event_row.inventory_type,'inventoryGroups',event_row.inventory_groups,
      'participants',coalesce((select jsonb_agg(jsonb_build_object(
        'employeeId',participant.employee_id,'name',coalesce(profile.first_name||' '||profile.last_name,user_row.email),
        'candidateStatus',participant.candidate_status,'status',participant.assignment_status,
        'reasons',participant.reasons
      ) order by coalesce(profile.last_name,user_row.email))
        from public.operational_program_participants_v1 participant
        left join public.matrix_employee_profiles_v2 profile on profile.matrix_version_id=v_matrix and profile.employee_id=participant.employee_id
        left join auth.users user_row on user_row.id=participant.auth_user_id
        where participant.event_id=event_row.id),'[]'::jsonb),
      'checklist',coalesce((select jsonb_agg(jsonb_build_object(
        'id',check_item.id,'label',check_item.label,'visibility',check_item.visibility,
        'completed',check_item.completed
      ) order by check_item.item_order,check_item.id)
        from public.operational_program_checklist_items_v1 check_item where check_item.event_id=event_row.id),'[]'::jsonb),
      'inventoryLink',(select jsonb_build_object(
        'status',inventory_link.sync_status,'url',inventory_link.external_session_url,
        'externalSessionId',inventory_link.external_session_id,'lastError',inventory_link.last_error
      ) from public.operational_program_inventory_links_v1 inventory_link where inventory_link.event_id=event_row.id)
    ) order by event_row.starts_at,event_row.title)
      from public.operational_program_events_v1 event_row
      left join public.matrix_locations_v2 location_row on location_row.id=event_row.location_id
      where event_row.starts_at>=v_month::timestamptz
        and event_row.starts_at<(v_month+interval '1 month')
        and (v_can_manage or exists(select 1 from public.operational_program_participants_v1 participant
          where participant.event_id=event_row.id and (participant.employee_id=v_employee or participant.auth_user_id=v_actor)))
    ),'[]'::jsonb)
  );
end;
$$;


ALTER FUNCTION "public"."operational_program_workspace_uat_v1"("p_month" "date") OWNER TO "postgres";

--
-- Name: optimizer_abort_finalize_v4("uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_abort_finalize_v4"("p_run_id" "uuid", "p_error" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare r public.optimization_runs; v_plan_ids uuid[];
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  select * into r from public.optimization_runs
    where id=p_run_id and requested_by=auth.uid() for update;
  if r.id is null then return jsonb_build_object('runId',p_run_id,'aborted',false); end if;
  if r.status<>'RUNNING' then
    return jsonb_build_object('runId',r.id,'aborted',false,'status',r.status);
  end if;
  select coalesce(array_agg(plan_id) filter(where plan_id is not null),'{}'::uuid[])
    into v_plan_ids from public.optimization_candidates where run_id=r.id;
  delete from public.optimization_candidates where run_id=r.id;
  delete from public.plans where id=any(v_plan_ids);
  update public.optimization_runs set
    status='FAILED',finished_at=now(),heartbeat_at=now(),
    failure_message=left(coalesce(p_error,'UNKNOWN_ERROR'),2000),
    result_summary=result_summary||jsonb_build_object('phase','FAILED','progress',100)
  where id=r.id and status='RUNNING';
  return jsonb_build_object('runId',r.id,'aborted',true,'plansRemoved',cardinality(v_plan_ids));
end $$;


ALTER FUNCTION "public"."optimizer_abort_finalize_v4"("p_run_id" "uuid", "p_error" "text") OWNER TO "postgres";

--
-- Name: optimizer_active_workspace_v2("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_active_workspace_v2"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_engine text;
  v_schedule_id uuid;
  v_month date:=date_trunc('month',p_month)::date;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  select f.engine into v_engine
  from public.solver_feature_flags f
  where f.flag_key='DEFAULT_ENGINE' and f.enabled;
  if v_engine is null then raise exception 'SOLVER_ENGINE_CONFIGURATION_MISSING'; end if;
  if v_engine not in ('ALPHA15','SHADOW','ORTOOLS_V2') then
    raise exception 'SOLVER_ENGINE_CONFIGURATION_INVALID';
  end if;
  if v_engine<>'ORTOOLS_V2' then return null; end if;
  if not (
    public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE') or public.has_app_role('VERIFIER')
  ) then raise exception 'FORBIDDEN'; end if;
  select s.id into v_schedule_id
  from public.published_schedules_v2 s
  where s.month=v_month and s.status='PUBLISHED'
  order by s.published_at desc,s.id desc limit 1;
  if v_schedule_id is null then
    return jsonb_build_object(
      'engine','ORTOOLS_V2',
      'context',jsonb_build_object(
        'type','PUBLISHED_SCHEDULE','status','EMPTY','month',v_month,
        'name','Brak opublikowanego grafiku'
      ),
      'variants','[]'::jsonb,'shifts','[]'::jsonb,
      'issues','[]'::jsonb,'finance',null
    );
  end if;
  return public.optimizer_published_schedule_v2(v_schedule_id)
    ||jsonb_build_object('engine','ORTOOLS_V2');
end;
$$;


ALTER FUNCTION "public"."optimizer_active_workspace_v2"("p_month" "date") OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_active_workspace_v2"("p_month" "date"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_active_workspace_v2"("p_month" "date") IS 'Canonical operational read model for the currently published OR-Tools v2 schedule; returns null for explicit Alpha 15 or shadow mode.';


--
-- Name: optimizer_begin_finalize_v4("uuid", "text", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_begin_finalize_v4"("p_run_id" "uuid", "p_name" "text", "p_candidates" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  r public.optimization_runs;
  v_baseline jsonb;
  v_best jsonb;
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  select * into r from public.optimization_runs
    where id=p_run_id and requested_by=auth.uid() for update;
  if r.id is null or r.status<>'RUNNING' then raise exception 'OPTIMIZATION_RUN_NOT_WRITABLE'; end if;
  if r.result_summary->>'phase'='FINALIZING' then
    return jsonb_build_object('runId',r.id,'finalizing',true,
      'finalizeCursor',coalesce((r.checkpoint->>'finalizeCursor')::integer,0),'finalizeTarget',3);
  end if;
  if r.current_generation<r.target_generations then raise exception 'GENERATIONS_INCOMPLETE'; end if;
  if jsonb_array_length(coalesce(p_candidates,'[]'::jsonb))<>3 then raise exception 'THREE_VARIANTS_REQUIRED'; end if;
  if (select array_agg((x->>'rank')::integer order by (x->>'rank')::integer)
      from jsonb_array_elements(p_candidates) x)<>array[1,2,3]
    or exists(select 1 from jsonb_array_elements(p_candidates) x
      where coalesce((x->>'hardViolations')::integer,0)<>0)
    or (select count(distinct md5(coalesce(x->'assignments','[]'::jsonb)::text))
      from jsonb_array_elements(p_candidates) x)<>3
  then raise exception 'THREE_DISTINCT_HARD_VALID_VARIANTS_REQUIRED'; end if;
  v_baseline:=r.checkpoint->'baselineRanking';
  select x->'metrics'->'ranking' into v_best
  from jsonb_array_elements(p_candidates) x where (x->>'rank')::integer=1;
  if v_baseline is not null and (
    coalesce((v_best->>0)::numeric,0)>coalesce((v_baseline->>0)::numeric,0)
    or (coalesce((v_best->>0)::numeric,0)=coalesce((v_baseline->>0)::numeric,0)
      and coalesce((v_best->>1)::numeric,0)>coalesce((v_baseline->>1)::numeric,0))
    or (coalesce((v_best->>0)::numeric,0)=coalesce((v_baseline->>0)::numeric,0)
      and coalesce((v_best->>1)::numeric,0)=coalesce((v_baseline->>1)::numeric,0)
      and coalesce((v_best->>2)::numeric,0)>coalesce((v_baseline->>2)::numeric,0))
  ) then raise exception 'NO_REGRESSION_GUARD'; end if;
  delete from public.optimization_candidates where run_id=r.id;
  insert into public.optimization_candidates(
    run_id,rank,score,hard_violations,metrics,assignments,selected
  )
  select r.id,(x->>'rank')::integer,(x->>'score')::numeric,
    coalesce((x->>'hardViolations')::integer,0),coalesce(x->'metrics','{}'::jsonb),
    coalesce(x->'assignments','[]'::jsonb),(x->>'rank')::integer=1
  from jsonb_array_elements(p_candidates) x;
  update public.optimization_runs set
    checkpoint=checkpoint||jsonb_build_object(
      'finalizeCursor',0,'finalizeTarget',3,
      'finalizeName',coalesce(nullif(trim(p_name),''),'Plan optymalny'),
      'finalCandidates',p_candidates),
    heartbeat_at=now(),
    result_summary=result_summary||jsonb_build_object(
      'phase','FINALIZING','progress',90,'engineVersion','ALPHA_15_V4')
  where id=r.id;
  return jsonb_build_object('runId',r.id,'finalizing',true,'finalizeCursor',0,'finalizeTarget',3);
end $$;


ALTER FUNCTION "public"."optimizer_begin_finalize_v4"("p_run_id" "uuid", "p_name" "text", "p_candidates" "jsonb") OWNER TO "postgres";

--
-- Name: optimizer_candidate_diagnostics_alpha16("uuid", bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_candidate_diagnostics_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_payload jsonb;
  v_candidates jsonb:='[]'::jsonb;
  v_candidate jsonb;
  v_hard text[];
  v_classification text;
  v_summary jsonb;
begin
  v_payload:=public.optimizer_candidate_diagnostics_before_role_scope_alpha16(
    p_schedule_id,p_issue_id
  );
  for v_candidate in
    select candidate.value
    from jsonb_array_elements(coalesce(v_payload->'candidates','[]'::jsonb)) candidate
  loop
    select coalesce(array_agg(reason),array[]::text[]) into v_hard
    from jsonb_array_elements_text(coalesce(v_candidate->'hardReasons','[]'::jsonb)) reason;
    if 'ROLE_REQUIRED'=any(v_hard) then
      v_hard:=array_remove(v_hard,'STANDBY_TIER_1_RESERVED');
      v_hard:=array_remove(v_hard,'STANDBY_TIER_2_RESERVED');
    end if;
    v_classification:=case
      when cardinality(v_hard)>0 then 'BLOCKED'
      when jsonb_array_length(coalesce(v_candidate->'softReasons','[]'::jsonb))>0 then 'WARNING'
      else 'ELIGIBLE'
    end;
    v_candidate:=jsonb_set(v_candidate,'{hardReasons}',to_jsonb(v_hard),true);
    v_candidate:=jsonb_set(v_candidate,'{classification}',to_jsonb(v_classification),true);
    v_candidates:=v_candidates||jsonb_build_array(v_candidate);
  end loop;
  select jsonb_build_object(
    'considered',jsonb_array_length(v_candidates),
    'eligible',count(*) filter(where candidate.value->>'classification'='ELIGIBLE'),
    'warning',count(*) filter(where candidate.value->>'classification'='WARNING'),
    'blocked',count(*) filter(where candidate.value->>'classification'='BLOCKED')
  ) into v_summary
  from jsonb_array_elements(v_candidates) candidate;
  return jsonb_set(
    jsonb_set(v_payload,'{candidates}',v_candidates,true),
    '{summary}',v_summary,true
  );
end;
$$;


ALTER FUNCTION "public"."optimizer_candidate_diagnostics_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint) OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_candidate_diagnostics_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_candidate_diagnostics_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint) IS 'Revalidates operational candidates with contract-aware limits, the configured daily shift limit, sequence order and stand-by reservations before any override.';


--
-- Name: optimizer_candidate_diagnostics_before_primary_rules_alpha16("uuid", bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_candidate_diagnostics_before_primary_rules_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_schedule public.published_schedules_v2%rowtype;
  v_issue public.plan_issues_v2%rowtype;
  v_shift public.plan_shifts_v2%rowtype;
  v_shift_period text;
  v_timezone text;
  v_minimum_rest integer;
  v_candidates jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not solver_private.alpha16_can_manage_schedule_v2(p_schedule_id) then
    raise exception 'FORBIDDEN';
  end if;
  select * into v_schedule from public.published_schedules_v2 schedule
  where schedule.id=p_schedule_id and schedule.status='PUBLISHED';
  if v_schedule.id is null then raise exception 'PUBLISHED_SCHEDULE_NOT_FOUND'; end if;
  select issue.* into v_issue
  from public.plan_issues_v2 issue
  join public.published_schedule_variants_v2 link
    on link.schedule_id=v_schedule.id and link.variant_id=issue.variant_id
  where issue.id=p_issue_id and issue.issue_code='UNFILLED_SLOT';
  if v_issue.id is null then raise exception 'UNFILLED_ISSUE_NOT_FOUND'; end if;
  select shift_row.* into v_shift from public.plan_shifts_v2 shift_row
  where shift_row.id=v_issue.shift_id;
  if v_shift.id is null then raise exception 'SHIFT_NOT_FOUND'; end if;
  select template.shift_period,location.timezone into v_shift_period,v_timezone
  from public.matrix_shift_templates_v2 template
  join public.matrix_locations_v2 location on location.id=template.location_id
  where template.id=v_shift.shift_template_id;
  select coalesce((matrix.settings->>'minimumRestMinutes')::integer,660)
  into v_minimum_rest
  from public.matrix_versions matrix where matrix.id=v_schedule.matrix_version_id;

  with schedule_variants as (
    select link.variant_id
    from public.published_schedule_variants_v2 link
    where link.schedule_id=v_schedule.id
  ), scheduled as (
    select assignment.employee_id,shift_row.starts_at,shift_row.ends_at,
      shift_row.shift_date
    from public.plan_assignments_v2 assignment
    join schedule_variants variant on variant.variant_id=assignment.variant_id
    join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
    union all
    select override_row.employee_id,shift_row.starts_at,shift_row.ends_at,
      shift_row.shift_date
    from public.operational_assignment_overrides_v2 override_row
    join public.plan_shifts_v2 shift_row on shift_row.id=override_row.shift_id
    where override_row.schedule_id=v_schedule.id and override_row.status='ACTIVE'
  ), profiles as (
    select profile.*,
      coalesce(profile.minimum_rest_minutes,v_minimum_rest) rest_minutes
    from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=v_schedule.matrix_version_id
      and profile.active and profile.archived_at is null
      and (profile.employment_start is null
        or profile.employment_start<=v_shift.shift_date)
      and (profile.employment_end is null
        or profile.employment_end>=v_shift.shift_date)
  ), candidate_base as (
    select profile.*,
      exists(select 1 from public.matrix_employee_roles_v2 grant_row
        where grant_row.matrix_version_id=v_schedule.matrix_version_id
          and grant_row.employee_id=profile.employee_id
          and grant_row.role_id=v_issue.role_id and grant_row.active
          and (grant_row.valid_from is null or grant_row.valid_from<=v_shift.shift_date)
          and (grant_row.valid_to is null or grant_row.valid_to>=v_shift.shift_date)
      ) role_ok,
      exists(select 1 from public.matrix_employee_locations_v2 grant_row
        where grant_row.matrix_version_id=v_schedule.matrix_version_id
          and grant_row.employee_id=profile.employee_id
          and grant_row.location_id=v_shift.location_id and grant_row.active
          and grant_row.standard_allowed
          and (grant_row.valid_from is null or grant_row.valid_from<=v_shift.shift_date)
          and (grant_row.valid_to is null or grant_row.valid_to>=v_shift.shift_date)
      ) location_ok,
      v_issue.duty_id is null or exists(
        select 1 from public.matrix_employee_duties_v2 grant_row
        where grant_row.matrix_version_id=v_schedule.matrix_version_id
          and grant_row.employee_id=profile.employee_id
          and grant_row.duty_id=v_issue.duty_id and grant_row.active
          and (grant_row.role_id is null or grant_row.role_id=v_issue.role_id)
          and (grant_row.location_id is null or grant_row.location_id=v_shift.location_id)
          and (grant_row.valid_from is null or grant_row.valid_from<=v_shift.shift_date)
          and (grant_row.valid_to is null or grant_row.valid_to>=v_shift.shift_date)
      ) duty_ok,
      exists(select 1 from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and tstzrange(assignment.starts_at,assignment.ends_at,'[)')
            && tstzrange(v_shift.starts_at,v_shift.ends_at,'[)')) overlap,
      exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=profile.employee_id
          and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
          and constraint_row.time_range
            && tstzrange(v_shift.starts_at,v_shift.ends_at,'[)')) blocked_time,
      (
        exists(select 1 from public.employee_time_constraints_v2 constraint_row
          where constraint_row.employee_id=profile.employee_id
            and constraint_row.status='ACTIVE'
            and constraint_row.constraint_kind='AVAILABLE_WINDOW'
            and lower(constraint_row.time_range)<(v_shift.shift_date+1)::timestamp
              at time zone v_timezone
            and upper(constraint_row.time_range)>v_shift.shift_date::timestamp
              at time zone v_timezone)
        and not exists(select 1 from public.employee_time_constraints_v2 constraint_row
          where constraint_row.employee_id=profile.employee_id
            and constraint_row.status='ACTIVE'
            and constraint_row.constraint_kind='AVAILABLE_WINDOW'
            and lower(constraint_row.time_range)<=v_shift.starts_at
            and upper(constraint_row.time_range)>=v_shift.ends_at)
      ) outside_available_window,
      coalesce(solver_private.alpha16_preference_level_v2(
        profile.employee_id,v_schedule.matrix_version_id,v_schedule.month,v_shift_period
      ),case
        when profile.only_morning and v_shift_period<>'MORNING' then 'BLOCKED'
        when profile.only_evening and v_shift_period<>'EVENING' then 'BLOCKED'
        else 'NEUTRAL' end) preference_level,
      coalesce((select sum(extract(epoch from
        (assignment.ends_at-assignment.starts_at))/60)::integer
        from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and assignment.shift_date>=v_schedule.month
          and assignment.shift_date<(v_schedule.month+interval '1 month')::date),0)
        monthly_minutes,
      coalesce((select count(*) from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and assignment.shift_date>=v_schedule.month
          and assignment.shift_date<(v_schedule.month+interval '1 month')::date),0)
        monthly_shifts,
      coalesce((select sum(extract(epoch from
        (assignment.ends_at-assignment.starts_at))/60)::integer
        from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and assignment.shift_date>=date_trunc('week',v_shift.shift_date)::date
          and assignment.shift_date<date_trunc('week',v_shift.shift_date)::date+7),0)
        weekly_minutes,
      (select jsonb_build_object('date',assignment.shift_date,
          'startsAt',assignment.starts_at,'endsAt',assignment.ends_at)
        from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and assignment.ends_at<=v_shift.starts_at
        order by assignment.ends_at desc limit 1) previous_shift,
      (select jsonb_build_object('date',assignment.shift_date,
          'startsAt',assignment.starts_at,'endsAt',assignment.ends_at)
        from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and assignment.starts_at>=v_shift.ends_at
        order by assignment.starts_at limit 1) next_shift,
      exists(select 1 from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and assignment.shift_date=v_shift.shift_date-1) works_previous_day,
      exists(select 1 from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and assignment.shift_date=v_shift.shift_date+1) works_next_day,
      coalesce((select min(day_offset.value)-1
        from generate_series(1,31) day_offset(value)
        where not exists(select 1 from scheduled assignment
          where assignment.employee_id=profile.employee_id
            and assignment.shift_date=v_shift.shift_date-day_offset.value)),31)
        consecutive_days_before,
      coalesce((select min(day_offset.value)-1
        from generate_series(1,31) day_offset(value)
        where not exists(select 1 from scheduled assignment
          where assignment.employee_id=profile.employee_id
            and assignment.shift_date=v_shift.shift_date+day_offset.value)),31)
        consecutive_days_after
    from profiles profile
  ), evaluated as (
    select candidate.*,
      extract(epoch from (v_shift.ends_at-v_shift.starts_at))/60 target_minutes,
      candidate.consecutive_days_before+1+candidate.consecutive_days_after
        projected_consecutive_days,
      candidate.previous_shift is not null and
        extract(epoch from (v_shift.starts_at-
          (candidate.previous_shift->>'endsAt')::timestamptz))/60
          <candidate.rest_minutes previous_rest_conflict,
      candidate.next_shift is not null and
        extract(epoch from ((candidate.next_shift->>'startsAt')::timestamptz-
          v_shift.ends_at))/60<candidate.rest_minutes next_rest_conflict
    from candidate_base candidate
  ), classified as (
    select candidate.*,
      array_remove(array[
        case when not candidate.role_ok then 'ROLE_REQUIRED' end,
        case when not candidate.location_ok then 'LOCATION_NOT_ALLOWED' end,
        case when not candidate.duty_ok then 'DUTY_REQUIRED' end,
        case when candidate.overlap then 'SHIFT_OVERLAP' end,
        case when candidate.blocked_time then 'DECLARED_UNAVAILABLE' end,
        case when candidate.outside_available_window then 'OUTSIDE_AVAILABILITY_WINDOW' end,
        case when candidate.previous_rest_conflict then 'REST_AFTER_PREVIOUS_SHIFT' end,
        case when candidate.next_rest_conflict then 'REST_BEFORE_NEXT_SHIFT' end,
        case when candidate.monthly_minutes+candidate.target_minutes>
          candidate.maximum_monthly_minutes then 'MONTHLY_LIMIT' end,
        case when candidate.weekly_minutes+candidate.target_minutes>
          candidate.maximum_weekly_minutes then 'WEEKLY_LIMIT' end,
        case when candidate.projected_consecutive_days>
          candidate.maximum_consecutive_days then 'MAX_CONSECUTIVE_DAYS' end,
        case when candidate.preference_level='BLOCKED' then 'MANAGER_SHIFT_BLOCK' end
      ]::text[],null) hard_reasons,
      array_remove(array[
        case when candidate.preference_level='AVOIDED' then 'SHIFT_PREFERENCE_AVOIDED' end,
        case when candidate.monthly_minutes+candidate.target_minutes>
          candidate.nominal_monthly_minutes then 'OVERTIME_AFTER_ASSIGNMENT' end
      ]::text[],null) soft_reasons
    from evaluated candidate
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'employeeId',candidate.employee_id,
    'employeeNo',candidate.employee_no,
    'name',candidate.first_name||' '||candidate.last_name,
    'classification',case
      when cardinality(candidate.hard_reasons)>0 then 'BLOCKED'
      when cardinality(candidate.soft_reasons)>0 then 'WARNING'
      else 'ELIGIBLE' end,
    'hardReasons',to_jsonb(candidate.hard_reasons),
    'softReasons',to_jsonb(candidate.soft_reasons),
    'preferenceLevel',candidate.preference_level,
    'monthlyShifts',candidate.monthly_shifts,
    'monthlyMinutes',candidate.monthly_minutes,
    'nominalMonthlyMinutes',candidate.nominal_monthly_minutes,
    'maximumMonthlyMinutes',candidate.maximum_monthly_minutes,
    'weeklyMinutes',candidate.weekly_minutes,
    'maximumWeeklyMinutes',candidate.maximum_weekly_minutes,
    'consecutiveDaysBefore',candidate.consecutive_days_before,
    'consecutiveDaysAfter',candidate.consecutive_days_after,
    'projectedConsecutiveDays',candidate.projected_consecutive_days,
    'maximumConsecutiveDays',candidate.maximum_consecutive_days,
    'declaredUnavailable',candidate.blocked_time,
    'outsideAvailableWindow',candidate.outside_available_window,
    'worksPreviousDay',candidate.works_previous_day,
    'worksNextDay',candidate.works_next_day,
    'previousShift',candidate.previous_shift,
    'nextShift',candidate.next_shift
  ) order by
    case when cardinality(candidate.hard_reasons)=0
      and cardinality(candidate.soft_reasons)=0 then 0
      when cardinality(candidate.hard_reasons)=0 then 1 else 2 end,
    candidate.monthly_minutes,candidate.last_name,candidate.first_name
  ),'[]'::jsonb) into v_candidates
  from classified candidate;

  return jsonb_build_object(
    'scheduleId',v_schedule.id,
    'issue',jsonb_build_object(
      'id',v_issue.id,'code',v_issue.issue_code,'message',v_issue.message,
      'slotKey',v_issue.slot_key,'roleId',v_issue.role_id,'dutyId',v_issue.duty_id
    ),
    'shift',jsonb_build_object(
      'id',v_shift.id,'slotGroupKey',v_shift.slot_group_key,
      'date',v_shift.shift_date,'startsAt',v_shift.starts_at,
      'endsAt',v_shift.ends_at,'locationId',v_shift.location_id,
      'shiftTemplateId',v_shift.shift_template_id,'shiftPeriod',v_shift_period
    ),
    'candidates',v_candidates,
    'summary',jsonb_build_object(
      'considered',jsonb_array_length(v_candidates),
      'eligible',(select count(*) from jsonb_array_elements(v_candidates) row
        where row.value->>'classification'='ELIGIBLE'),
      'warning',(select count(*) from jsonb_array_elements(v_candidates) row
        where row.value->>'classification'='WARNING'),
      'blocked',(select count(*) from jsonb_array_elements(v_candidates) row
        where row.value->>'classification'='BLOCKED')
    )
  );
end;
$$;


ALTER FUNCTION "public"."optimizer_candidate_diagnostics_before_primary_rules_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint) OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_candidate_diagnostics_before_primary_rules_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_candidate_diagnostics_before_primary_rules_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint) IS 'Explains every candidate rejection and returns workload, adjacent shifts and preference data.';


--
-- Name: optimizer_candidate_diagnostics_before_role_scope_alpha16("uuid", bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_candidate_diagnostics_before_role_scope_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_payload jsonb;
  v_candidates jsonb:='[]'::jsonb;
  v_candidate jsonb;
  v_hard text[];
  v_soft text[];
  v_extra text[];
  v_shift_id uuid;
  v_matrix_version_id uuid;
  v_contract text;
  v_policy text;
  v_classification text;
  v_summary jsonb;
begin
  v_payload:=public.optimizer_candidate_diagnostics_before_primary_rules_alpha16(
    p_schedule_id,p_issue_id
  );
  select issue.shift_id,schedule.matrix_version_id
  into v_shift_id,v_matrix_version_id
  from public.plan_issues_v2 issue
  join public.published_schedules_v2 schedule on schedule.id=p_schedule_id
  where issue.id=p_issue_id;

  for v_candidate in
    select candidate.value
    from jsonb_array_elements(coalesce(v_payload->'candidates','[]'::jsonb)) candidate
  loop
    select coalesce(array_agg(reason),array[]::text[]) into v_hard
    from jsonb_array_elements_text(coalesce(v_candidate->'hardReasons','[]'::jsonb)) reason;
    select coalesce(array_agg(reason),array[]::text[]) into v_soft
    from jsonb_array_elements_text(coalesce(v_candidate->'softReasons','[]'::jsonb)) reason;
    select coalesce(hr.contract_type,'INNE'),coalesce(profile.work_time_policy,'CONTRACT_DEFAULT')
    into v_contract,v_policy
    from public.matrix_employee_profiles_v2 profile
    left join public.employee_hr_profiles hr on hr.employee_id=profile.employee_id
    where profile.matrix_version_id=v_matrix_version_id
      and profile.employee_id=(v_candidate->>'employeeId')::uuid;
    if v_contract in ('ZLECENIE','B2B') and v_policy<>'CUSTOM' then
      v_hard:=array_remove(v_hard,'MONTHLY_LIMIT');
      v_hard:=array_remove(v_hard,'WEEKLY_LIMIT');
      v_hard:=array_remove(v_hard,'MAX_CONSECUTIVE_DAYS');
      v_hard:=array_remove(v_hard,'REST_AFTER_PREVIOUS_SHIFT');
      v_hard:=array_remove(v_hard,'REST_BEFORE_NEXT_SHIFT');
      v_soft:=array_remove(v_soft,'OVERTIME_AFTER_ASSIGNMENT');
    end if;
    v_extra:=solver_private.schedule_primary_conflict_reasons_uat_v2(
      p_schedule_id,(v_candidate->>'employeeId')::uuid,v_shift_id
    );
    if 'ONE_PRIMARY_SHIFT_PER_DAY'=any(v_extra) then
      v_hard:=array_remove(v_hard,'SHIFT_OVERLAP');
    end if;
    select coalesce(array_agg(distinct reason order by reason),array[]::text[])
    into v_hard from unnest(v_hard||v_extra) reason;
    v_classification:=case
      when cardinality(v_hard)>0 then 'BLOCKED'
      when cardinality(v_soft)>0 then 'WARNING'
      else 'ELIGIBLE'
    end;
    v_candidate:=jsonb_set(v_candidate,'{hardReasons}',to_jsonb(v_hard),true);
    v_candidate:=jsonb_set(v_candidate,'{softReasons}',to_jsonb(v_soft),true);
    v_candidate:=jsonb_set(v_candidate,'{classification}',to_jsonb(v_classification),true);
    v_candidates:=v_candidates||jsonb_build_array(v_candidate);
  end loop;

  select jsonb_build_object(
    'considered',jsonb_array_length(v_candidates),
    'eligible',count(*) filter(where candidate.value->>'classification'='ELIGIBLE'),
    'warning',count(*) filter(where candidate.value->>'classification'='WARNING'),
    'blocked',count(*) filter(where candidate.value->>'classification'='BLOCKED')
  ) into v_summary
  from jsonb_array_elements(v_candidates) candidate;

  return jsonb_set(
    jsonb_set(v_payload,'{candidates}',v_candidates,true),
    '{summary}',v_summary,true
  );
end;
$$;


ALTER FUNCTION "public"."optimizer_candidate_diagnostics_before_role_scope_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint) OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_candidate_diagnostics_before_role_scope_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_candidate_diagnostics_before_role_scope_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint) IS 'Revalidates operational candidates with contract-aware limits, one shift per day, sequence order and stand-by reservations before any override.';


--
-- Name: optimizer_checkpoint_v2("uuid", integer, "jsonb", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_checkpoint_v2"("p_run_id" "uuid", "p_expected_generation" integer, "p_checkpoint" "jsonb", "p_metrics" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_generation integer;
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  update public.optimization_runs set
    checkpoint=coalesce(p_checkpoint,'{}'::jsonb),
    current_generation=current_generation+1,
    heartbeat_at=now(),
    result_summary=coalesce(result_summary,'{}'::jsonb)||coalesce(p_metrics,'{}'::jsonb)
      ||jsonb_build_object('phase','OPTIMIZING','progress',least(99,round(100.0*(current_generation+1)/greatest(target_generations,1))))
  where id=p_run_id and requested_by=auth.uid() and status='RUNNING'
    and current_generation=p_expected_generation
  returning current_generation into v_generation;
  if v_generation is null then raise exception 'STALE_OR_FORBIDDEN_CHECKPOINT'; end if;
  return jsonb_build_object('runId',p_run_id,'generation',v_generation);
end $$;


ALTER FUNCTION "public"."optimizer_checkpoint_v2"("p_run_id" "uuid", "p_expected_generation" integer, "p_checkpoint" "jsonb", "p_metrics" "jsonb") OWNER TO "postgres";

--
-- Name: optimizer_commit("uuid", "text", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_commit"("p_run_id" "uuid", "p_name" "text", "p_candidates" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare r public.optimization_runs; best jsonb; c jsonb; a jsonb; plan_id uuid; shift_id uuid;
  plan_version integer; start_at timestamptz; end_at timestamptz; emp public.employees; loc public.locations;
  total_cost numeric:=0; assignment_count integer:=0; issue_count integer:=0; hard_count integer:=0;
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  select * into r from public.optimization_runs where id=p_run_id and requested_by=auth.uid() for update;
  if r.id is null or r.status<>'RUNNING' then raise exception 'OPTIMIZATION_RUN_NOT_WRITABLE'; end if;
  if jsonb_array_length(coalesce(p_candidates,'[]'::jsonb))=0 then raise exception 'NO_CANDIDATES'; end if;
  best:=p_candidates->0;
  if coalesce((best->>'hardViolations')::integer,0)>0 then raise exception 'BEST_CANDIDATE_HAS_HARD_VIOLATIONS'; end if;
  select coalesce(max(version),0)+1 into plan_version from public.plans where month=r.month;
  insert into public.plans(month,name,scenario_code,optimization_mode,staffing_level,status,version,score,total_cost,generated_at,created_by)
  values(r.month,coalesce(nullif(trim(p_name),''),'Plan optymalny '||to_char(r.month,'YYYY-MM')),r.scenario_code,
    (select code from public.optimizer_profiles where id=r.profile_id),'OPTIMAL','GENERATING',plan_version,
    (best->>'score')::numeric,0,now(),auth.uid()) returning id into plan_id;

  for a in select value from jsonb_array_elements(coalesce(best->'assignments','[]'::jsonb)) loop
    select * into emp from public.employees where id=(a->>'employeeId')::uuid and active and archived_at is null;
    select * into loc from public.locations where id=(a->>'locationId')::uuid and active;
    if emp.id is null or loc.id is null then raise exception 'INVALID_EMPLOYEE_OR_LOCATION'; end if;
    start_at:=(a->>'startsAt')::timestamptz; end_at:=(a->>'endsAt')::timestamptz;
    if end_at<=start_at or not exists(select 1 from public.employee_locations el where el.employee_id=emp.id and el.location_id=loc.id and (el.standard_allowed or el.overtime_allowed)) then raise exception 'HARD_CONSTRAINT_LOCATION_OR_TIME'; end if;
    if ((emp.employment_start is not null and (a->>'date')::date<emp.employment_start) or (emp.employment_end is not null and (a->>'date')::date>emp.employment_end)
      or (emp.no_weekends and extract(isodow from (a->>'date')::date) in (6,7))
      or (emp.only_morning and start_at::time>=time '15:00') or (emp.only_evening and start_at::time<time '14:00')) then raise exception 'HARD_CONSTRAINT_EMPLOYMENT_PATTERN'; end if;
    if not (emp.primary_role::text=a->>'role' or exists(select 1 from public.matrix_employee_roles mer join public.matrix_roles mr on mr.id=mer.role_id where mer.matrix_version_id=r.matrix_version_id and mer.employee_id=emp.id and mr.code=a->>'role')) then raise exception 'HARD_CONSTRAINT_ROLE'; end if;
    if nullif(a->>'function','') is not null and not exists(select 1 from public.employee_capabilities ec where ec.employee_id=emp.id and ec.active and ec.capability=a->>'function' and (ec.scope_role is null or ec.scope_role::text=a->>'role') and (ec.scope_location is null or ec.scope_location::text=loc.code::text)) then raise exception 'HARD_CONSTRAINT_CAPABILITY'; end if;
    if exists(select 1 from public.employee_availability av where av.employee_id=emp.id and av.work_date=(a->>'date')::date and (not av.available or (av.earliest_start is not null and start_at::time<av.earliest_start) or (av.latest_end is not null and end_at::time>av.latest_end))) then raise exception 'HARD_CONSTRAINT_AVAILABILITY'; end if;
    if exists(select 1 from public.assignments ax join public.shifts sx on sx.id=ax.shift_id where sx.plan_id=plan_id and ax.employee_id=emp.id and tstzrange(sx.starts_at,sx.ends_at,'[)') && tstzrange(start_at,end_at,'[)')) then raise exception 'HARD_CONSTRAINT_OVERLAP'; end if;
    if exists(select 1 from public.assignments ax join public.shifts sx on sx.id=ax.shift_id where sx.plan_id=plan_id and ax.employee_id=emp.id and tstzrange(sx.starts_at-coalesce(emp.minimum_rest_minutes,660)*interval '1 minute',sx.ends_at+coalesce(emp.minimum_rest_minutes,660)*interval '1 minute','[)') && tstzrange(start_at,end_at,'[)')) then raise exception 'HARD_CONSTRAINT_REST'; end if;
    if coalesce((select sum(public.shift_minutes(sx.starts_at,sx.ends_at)) from public.assignments ax join public.shifts sx on sx.id=ax.shift_id where sx.plan_id=plan_id and ax.employee_id=emp.id),0)+public.shift_minutes(start_at,end_at)>coalesce(emp.max_monthly_minutes,emp.monthly_nominal_minutes) then raise exception 'HARD_CONSTRAINT_MONTHLY_LIMIT'; end if;
    if coalesce((select sum(public.shift_minutes(sx.starts_at,sx.ends_at)) from public.assignments ax join public.shifts sx on sx.id=ax.shift_id where sx.plan_id=plan_id and ax.employee_id=emp.id and date_trunc('week',sx.shift_date::timestamp)=date_trunc('week',(a->>'date')::date::timestamp)),0)+public.shift_minutes(start_at,end_at)>emp.max_weekly_minutes then raise exception 'HARD_CONSTRAINT_WEEKLY_LIMIT'; end if;
    select s.id into shift_id from public.shifts s where s.plan_id=plan_id and s.location_id=loc.id and s.shift_date=(a->>'date')::date and s.shift_code=a->>'shiftCode';
    if shift_id is null then insert into public.shifts(plan_id,location_id,shift_date,shift_code,starts_at,ends_at,status) values(plan_id,loc.id,(a->>'date')::date,a->>'shiftCode',start_at,end_at,'PLANNED') returning id into shift_id; end if;
    insert into public.assignments(shift_id,employee_id,assigned_role,assigned_capability,cost,explanation)
    values(shift_id,emp.id,(a->>'role')::public.employee_role,nullif(a->>'function',''),round(emp.hourly_rate*public.shift_minutes(start_at,end_at)/60,2),jsonb_build_object('engine','ALPHA_13_GA','runId',r.id,'slotId',a->>'slotId'));
    total_cost:=total_cost+round(emp.hourly_rate*public.shift_minutes(start_at,end_at)/60,2); assignment_count:=assignment_count+1;
  end loop;

  for c in select value from jsonb_array_elements(p_candidates) loop
    insert into public.optimization_candidates(run_id,rank,score,hard_violations,metrics,assignments,selected)
    values(r.id,(c->>'rank')::integer,(c->>'score')::numeric,coalesce((c->>'hardViolations')::integer,0),coalesce(c->'metrics','{}'::jsonb),coalesce(c->'assignments','[]'::jsonb),(c->>'rank')::integer=1);
  end loop;
  for c in select value from jsonb_array_elements(coalesce(best->'unfilled','[]'::jsonb)) loop
    insert into public.plan_issues(plan_id,issue_type,severity,role,capability,required_count,assigned_count,message)
    values(plan_id,case when nullif(c->>'function','') is null then 'SHORTAGE' else 'CAPABILITY_MISSING' end,'CRITICAL',(c->>'role')::public.employee_role,nullif(c->>'function',''),1,0,
      'Nierozwiązywalny brak: '||(c->>'role')||coalesce(' / '||nullif(c->>'function',''),'')||' • '||(c->>'date')||' • '||(c->>'shiftCode'));
    issue_count:=issue_count+1;
  end loop;
  update public.plans set status='READY',total_cost=total_cost,generated_at=now() where id=plan_id;
  update public.optimization_runs set status=case when issue_count=0 then 'SUCCEEDED' else 'INFEASIBLE' end,finished_at=now(),
    result_summary=jsonb_build_object('planId',plan_id,'score',best->'score','assignments',assignment_count,'unfilled',issue_count,'alternatives',jsonb_array_length(p_candidates),'cost',total_cost)
    where id=r.id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data) values(auth.uid(),'optimization_run',r.id::text,'COMMIT',(select result_summary from public.optimization_runs where id=r.id));
  return jsonb_build_object('plan_id',plan_id,'run_id',r.id,'status',case when issue_count=0 then 'READY' else 'READY_WITH_EXCEPTIONS' end,'assignments',assignment_count,'issues',issue_count,'total_cost',total_cost,'score',best->'score','alternatives',jsonb_array_length(p_candidates));
exception when others then
  if r.id is not null then update public.optimization_runs set status='FAILED',finished_at=now(),failure_message=sqlerrm where id=r.id; end if;
  raise;
end $$;


ALTER FUNCTION "public"."optimizer_commit"("p_run_id" "uuid", "p_name" "text", "p_candidates" "jsonb") OWNER TO "postgres";

--
-- Name: optimizer_complete_finalize_v4("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_complete_finalize_v4"("p_run_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  r public.optimization_runs;
  v_variants jsonb;
  v_winner jsonb;
  v_status text;
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  select * into r from public.optimization_runs
    where id=p_run_id and requested_by=auth.uid() for update;
  if r.id is null or r.status<>'RUNNING' or r.result_summary->>'phase'<>'FINALIZING'
    or coalesce((r.checkpoint->>'finalizeCursor')::integer,0)<>3
    or (select count(*) from public.optimization_candidates c
      where c.run_id=r.id and c.plan_id is not null)<>3
  then raise exception 'FINALIZATION_INCOMPLETE'; end if;

  update public.plans p set status='READY',generated_at=now()
  where p.id in (select c.plan_id from public.optimization_candidates c where c.run_id=r.id);

  select jsonb_agg(jsonb_build_object(
    'planId',p.id,'rank',c.rank,'score',c.score,
    'assignments',jsonb_array_length(c.assignments),
    'unfilled',coalesce((c.metrics->>'unfilled')::integer,0),
    'alertGroups',(select count(*) from public.plan_issues pi where pi.plan_id=p.id and pi.resolved_at is null),
    'totalCost',p.total_cost,'metrics',c.metrics
  ) order by c.rank) into v_variants
  from public.optimization_candidates c join public.plans p on p.id=c.plan_id
  where c.run_id=r.id;
  select x into v_winner from jsonb_array_elements(v_variants) x where (x->>'rank')::integer=1;
  v_status:=case when coalesce((v_winner->>'unfilled')::integer,0)=0 then 'SUCCEEDED' else 'INFEASIBLE' end;

  update public.optimization_runs set
    status=v_status,finished_at=now(),heartbeat_at=now(),
    result_summary=jsonb_build_object(
      'phase','DONE','progress',100,'ranking','LEXICOGRAPHIC','engineVersion','ALPHA_15_V4',
      'planId',v_winner->'planId','score',v_winner->'score',
      'assignments',v_winner->'assignments','unfilled',v_winner->'unfilled',
      'alertGroups',v_winner->'alertGroups','alternatives',3,
      'cost',v_winner->'totalCost','variants',v_variants,
      'baselineRanking',r.checkpoint->'baselineRanking')
  where id=r.id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'optimization_run',r.id::text,'COMMIT_V4',
    (select result_summary from public.optimization_runs where id=r.id));

  return jsonb_build_object(
    'plan_id',v_winner->'planId','run_id',r.id,
    'status',case when v_status='SUCCEEDED' then 'READY' else 'READY_WITH_EXCEPTIONS' end,
    'assignments',v_winner->'assignments','issues',v_winner->'unfilled',
    'alerts',v_winner->'alertGroups','total_cost',v_winner->'totalCost',
    'score',v_winner->'score','alternatives',3,'variants',v_variants,
    'engineVersion','ALPHA_15_V4','baselineRanking',r.checkpoint->'baselineRanking');
end $$;


ALTER FUNCTION "public"."optimizer_complete_finalize_v4"("p_run_id" "uuid") OWNER TO "postgres";

--
-- Name: optimizer_configuration_v2("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_configuration_v2"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_month date:=date_trunc('month',p_month)::date;
  v_period_end date:=(date_trunc('month',p_month)+interval '1 month - 1 day')::date;
  v_engine text;
  v_enabled boolean;
  v_solver_version text;
  v_matrix public.matrix_versions%rowtype;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  select flag.engine,flag.enabled,nullif(trim(flag.config->>'solverVersion'),'')
  into v_engine,v_enabled,v_solver_version
  from public.solver_feature_flags flag
  where flag.flag_key='DEFAULT_ENGINE';
  if v_engine is null then raise exception 'SOLVER_ENGINE_CONFIGURATION_MISSING'; end if;
  if not coalesce(v_enabled,false) then raise exception 'SOLVER_DISABLED'; end if;
  if v_engine not in ('ALPHA15','SHADOW','ORTOOLS_V2') then
    raise exception 'SOLVER_ENGINE_CONFIGURATION_INVALID';
  end if;
  if v_engine='ALPHA15' then
    return jsonb_build_object('engine',v_engine,'enabled',true);
  end if;
  if length(coalesce(v_solver_version,'')) not between 1 and 200 then
    raise exception 'SOLVER_VERSION_CONFIGURATION_REQUIRED';
  end if;

  select * into v_matrix
  from public.matrix_versions matrix_version
  where matrix_version.status in ('ACTIVE','ARCHIVED')
    and matrix_version.schema_version>=2
    and solver_private.matrix_covers_planning_month_uat_v1(matrix_version.effective_from,v_month)
    and coalesce(matrix_version.content_hash,'') ~ '^[0-9a-f]{64}$'
    and coalesce(matrix_version.workforce_hash,'') ~ '^[0-9a-f]{64}$'
  order by matrix_version.effective_from desc,matrix_version.version desc
  limit 1;
  if v_matrix.id is null then raise exception 'MATRIX_V2_FOR_MONTH_NOT_FOUND'; end if;

  return jsonb_build_object(
    'engine',v_engine,'enabled',true,'solverVersion',v_solver_version,
    'matrixVersion',jsonb_build_object(
      'id',v_matrix.id,'schemaVersion',v_matrix.schema_version,
      'effectiveFrom',v_matrix.effective_from,'settings',v_matrix.settings,
      'contentHash',v_matrix.content_hash,'workforceHash',v_matrix.workforce_hash
    ),
    'scenarios',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',scenario.id,'code',scenario.code,'name',scenario.name,
        'description',scenario.description,'isDefault',scenario.is_default,
        'sortOrder',scenario.sort_order,'parentScenarioId',scenario.parent_scenario_id,
        'available',(
          (scenario.valid_from is null or scenario.valid_from<=v_period_end)
          and (scenario.valid_to is null or scenario.valid_to>=v_month)
        )
      ) order by scenario.sort_order,scenario.name)
      from public.matrix_scenarios_v2 scenario
      where scenario.matrix_version_id=v_matrix.id and scenario.active
    ),'[]'::jsonb),
    'roles',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',role_row.id,'code',role_row.code,'name',role_row.name,
        'sortOrder',role_row.sort_order
      ) order by role_row.sort_order,role_row.name)
      from public.matrix_roles_v2 role_row
      where role_row.matrix_version_id=v_matrix.id and role_row.active
    ),'[]'::jsonb),
    'locations',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',location_row.id,'code',location_row.code,'name',location_row.name,
        'sortOrder',location_row.sort_order,'timezone',location_row.timezone
      ) order by location_row.sort_order,location_row.name)
      from public.matrix_locations_v2 location_row
      where location_row.matrix_version_id=v_matrix.id and location_row.active
    ),'[]'::jsonb),
    'strategies',coalesce((
      select jsonb_agg(jsonb_build_object('id',strategy.id) order by strategy.id)
      from public.matrix_strategies_v2 strategy
      where strategy.matrix_version_id=v_matrix.id and strategy.active
    ),'[]'::jsonb),
    'scenarioStrategies',coalesce((
      select jsonb_agg(jsonb_build_object(
        'scenarioId',link.scenario_id,'strategyId',link.strategy_id,
        'active',link.active
      ) order by link.scenario_id,link.sort_order,link.id)
      from public.matrix_scenario_strategies_v2 link
      where link.matrix_version_id=v_matrix.id
    ),'[]'::jsonb)
  );
end;
$_$;


ALTER FUNCTION "public"."optimizer_configuration_v2"("p_month" "date") OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_configuration_v2"("p_month" "date"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_configuration_v2"("p_month" "date") IS 'Safe month-as-of solver configuration; no payroll or private workforce data.';


--
-- Name: optimizer_create_leader_variant_uat_v1("uuid", "uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_create_leader_variant_uat_v1"("p_run_id" "uuid", "p_source_variant_id" "uuid", "p_name" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid();
  v_source public.plan_variants_v2%rowtype;
  v_run public.optimization_runs_v2%rowtype;
  v_id uuid:=gen_random_uuid();
  v_name text:=trim(coalesce(p_name,''));
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if length(v_name) not between 1 and 200 then raise exception 'INVALID_PLAN_NAME'; end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-copy:'||p_run_id::text,0));
  select * into v_run from public.optimization_runs_v2 where id=p_run_id for update;
  select * into v_source from public.plan_variants_v2
    where id=p_source_variant_id and run_id=p_run_id and variant_kind='GENERATED'
    for update;
  if v_run.id is null or v_source.id is null then raise exception 'VARIANT_NOT_FOUND'; end if;
  if v_run.status<>'READY' or v_source.status not in ('READY','SELECTED','PUBLISHED')
    or v_source.hard_violations<>0 then raise exception 'VALID_GENERATED_VARIANT_REQUIRED'; end if;
  if not (
    public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or (v_run.scope_type='ROLE' and exists(
      select 1 from public.matrix_scope_grants_v2 grant_row
      join public.matrix_roles_v2 role on role.id=v_run.scope_role_id
      where grant_row.auth_user_id=v_actor and grant_row.active
        and grant_row.app_role='ROLE_MANAGER'
        and (grant_row.role_logical_id is null or grant_row.role_logical_id=role.logical_id)
    ))
  ) then raise exception 'LEADER_VARIANT_FORBIDDEN'; end if;

  update public.plan_variants_v2
    set status='ARCHIVED',selected=false
    where run_id=p_run_id and variant_kind='LEADER_COPY'
      and status in ('READY','SELECTED');
  update public.plan_variants_v2
    set selected=false,status=case when status='SELECTED' then 'READY' else status end
    where run_id=p_run_id and variant_kind='GENERATED';

  insert into public.plan_variants_v2(
    id,run_id,run_strategy_id,strategy_id,name,status,hard_violations,
    assignment_count,unfilled_count,solver_status,solution_hash,objective_bound,
    metrics,recommended,selected,equivalent_to_variant_id,snapshot_hash,
    selected_at,selected_by,variant_kind,source_variant_id,revision,last_edited_at,last_edited_by
  ) values(
    v_id,v_source.run_id,v_source.run_strategy_id,v_source.strategy_id,v_name,
    'SELECTED',0,v_source.assignment_count,v_source.unfilled_count,
    v_source.solver_status,v_source.solution_hash,v_source.objective_bound,
    v_source.metrics||jsonb_build_object('leaderCopy',true),false,true,
    v_source.equivalent_to_variant_id,v_source.snapshot_hash,now(),v_actor,
    'LEADER_COPY',v_source.id,0,now(),v_actor
  );

  insert into public.plan_shifts_v2(
    id,variant_id,slot_group_key,shift_template_id,location_id,shift_date,
    starts_at,ends_at,source_type,source_id,created_at
  )
  select public.matrix_v2_stable_uuid('LEADER_SHIFT:'||v_id::text||':'||source.id::text),
    v_id,source.slot_group_key,source.shift_template_id,source.location_id,
    source.shift_date,source.starts_at,source.ends_at,source.source_type,
    source.source_id,now()
  from public.plan_shifts_v2 source where source.variant_id=v_source.id;

  insert into public.plan_assignments_v2(
    id,variant_id,shift_id,slot_key,employee_id,role_id,locked,explanation,created_at
  )
  select public.matrix_v2_stable_uuid('LEADER_ASSIGNMENT:'||v_id::text||':'||source.id::text),
    v_id,public.matrix_v2_stable_uuid('LEADER_SHIFT:'||v_id::text||':'||source.shift_id::text),
    source.slot_key,source.employee_id,source.role_id,source.locked,
    coalesce(source.explanation,'{}'::jsonb)||jsonb_build_object(
      'sourceVariantId',v_source.id,'sourceAssignmentId',source.id,'edited',false
    ),now()
  from public.plan_assignments_v2 source where source.variant_id=v_source.id;

  insert into public.plan_assignment_duties_v2(assignment_id,duty_id)
  select public.matrix_v2_stable_uuid('LEADER_ASSIGNMENT:'||v_id::text||':'||source.id::text),duty.duty_id
  from public.plan_assignments_v2 source
  join public.plan_assignment_duties_v2 duty on duty.assignment_id=source.id
  where source.variant_id=v_source.id;

  insert into public.plan_issues_v2(
    variant_id,shift_id,slot_key,issue_code,severity,role_id,duty_id,
    required_count,assigned_count,message,metadata,created_at
  )
  select v_id,
    case when source.shift_id is null then null else
      public.matrix_v2_stable_uuid('LEADER_SHIFT:'||v_id::text||':'||source.shift_id::text) end,
    source.slot_key,source.issue_code,source.severity,source.role_id,source.duty_id,
    source.required_count,source.assigned_count,source.message,
    coalesce(source.metadata,'{}'::jsonb)||jsonb_build_object('sourceIssueId',source.id),now()
  from public.plan_issues_v2 source where source.variant_id=v_source.id;

  insert into solver_private.plan_assignment_cost_components_v2(
    assignment_id,pay_rule_id,component_code,amount_minor,quantity_minutes,
    calculation_basis,created_at
  )
  select public.matrix_v2_stable_uuid('LEADER_ASSIGNMENT:'||v_id::text||':'||assignment.id::text),
    component.pay_rule_id,component.component_code,component.amount_minor,
    component.quantity_minutes,component.calculation_basis,now()
  from public.plan_assignments_v2 assignment
  join solver_private.plan_assignment_cost_components_v2 component
    on component.assignment_id=assignment.id
  where assignment.variant_id=v_source.id;

  insert into solver_private.plan_variant_finance_v2(
    variant_id,base_cost_units,additions_cost_units,total_cost_units,
    base_cost_minor,additions_cost_minor,total_cost_minor,currency,budget_minor,
    hard_budget_exceeded,breakdown
  )
  select v_id,finance.base_cost_units,finance.additions_cost_units,finance.total_cost_units,
    finance.base_cost_minor,finance.additions_cost_minor,finance.total_cost_minor,
    finance.currency,finance.budget_minor,finance.hard_budget_exceeded,
    finance.breakdown||jsonb_build_object('sourceVariantId',v_source.id)
  from solver_private.plan_variant_finance_v2 finance where finance.variant_id=v_source.id;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'plan_variant_v2',v_id::text,'CREATE_LEADER_COPY',
    jsonb_build_object('runId',p_run_id,'sourceVariantId',v_source.id,'name',v_name));
  return jsonb_build_object('variantId',v_id,'sourceVariantId',v_source.id,
    'name',v_name,'revision',0,'variantKind','LEADER_COPY');
end;
$$;


ALTER FUNCTION "public"."optimizer_create_leader_variant_uat_v1"("p_run_id" "uuid", "p_source_variant_id" "uuid", "p_name" "text") OWNER TO "postgres";

--
-- Name: optimizer_create_manual_leader_studio_uat_v1("date", "uuid", "text", "uuid", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_create_manual_leader_studio_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_solver_version" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare v_actor uuid:=auth.uid();v_month date:=date_trunc('month',p_month)::date;v_matrix_id uuid;v_run_id uuid:=gen_random_uuid();v_variant_id uuid:=gen_random_uuid();v_snapshot jsonb;v_snapshot_hash text;v_solution_hash text;v_strategy_id uuid;v_run_strategy_id uuid;v_name text:=trim(coalesce(p_name,''));v_unfilled integer;v_currency text;
begin
if v_actor is null then raise exception 'AUTH_REQUIRED';end if;
if p_scope_type not in ('COMPANY','ROLE') then raise exception 'INVALID_SCOPE_TYPE';end if;
if (p_scope_type='ROLE') is distinct from (p_scope_role_id is not null) then raise exception 'INVALID_SCOPE_ROLE';end if;
if length(v_name) not between 1 and 200 then raise exception 'INVALID_PLAN_NAME';end if;
if length(trim(coalesce(p_solver_version,''))) not between 1 and 200 then raise exception 'INVALID_SOLVER_VERSION';end if;
select version.id into v_matrix_id from public.matrix_versions version where version.status in ('ACTIVE','ARCHIVED') and version.schema_version>=2 and version.effective_from<=v_month and coalesce(version.content_hash,'')~'^[0-9a-f]{64}$' and coalesce(version.workforce_hash,'')~'^[0-9a-f]{64}$' order by version.effective_from desc,version.version desc limit 1;
if v_matrix_id is null then raise exception 'MATRIX_V2_FOR_MONTH_NOT_FOUND';end if;
if not exists(select 1 from public.matrix_scenarios_v2 scenario where scenario.id=p_scenario_id and scenario.matrix_version_id=v_matrix_id and scenario.active) then raise exception 'SCENARIO_NOT_FOUND';end if;
if p_scope_type='COMPANY' and not(public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'COMPANY_SCOPE_FORBIDDEN';end if;
if p_scope_type='ROLE' and not(public.has_app_role('OWNER') or public.has_app_role('ADMIN') or exists(select 1 from public.matrix_scope_grants_v2 grant_row join public.matrix_roles_v2 role on role.id=p_scope_role_id where grant_row.auth_user_id=v_actor and grant_row.active and grant_row.app_role='ROLE_MANAGER' and(grant_row.role_logical_id is null or grant_row.role_logical_id=role.logical_id))) then raise exception 'ROLE_SCOPE_FORBIDDEN';end if;
v_snapshot:=solver_private.build_snapshot_payload_v2(v_run_id,v_month,v_matrix_id,p_scenario_id,p_scope_type,p_scope_role_id);
select(strategy.value->>'id')::uuid into v_strategy_id from jsonb_array_elements(coalesce(v_snapshot->'strategies','[]'::jsonb)) with ordinality strategy(value,ordinality) order by strategy.ordinality limit 1;
if v_strategy_id is null then raise exception 'SNAPSHOT_HAS_NO_STRATEGIES';end if;
v_unfilled:=jsonb_array_length(coalesce(v_snapshot->'slots','[]'::jsonb));v_currency:=coalesce(nullif(v_snapshot->>'currency',''),'PLN');
v_snapshot_hash:=encode(extensions.digest(convert_to(solver_private.canonical_json_v2(v_snapshot),'UTF8'),'sha256'),'hex');
v_solution_hash:=encode(extensions.digest(convert_to(solver_private.canonical_json_v2(jsonb_build_object('assignments','[]'::jsonb,'unfilledSlotIds',coalesce((select jsonb_agg(slot.value->>'slotId' order by slot.ordinality) from jsonb_array_elements(coalesce(v_snapshot->'slots','[]'::jsonb)) with ordinality slot(value,ordinality)),'[]'::jsonb))),'UTF8'),'sha256'),'hex');
insert into public.optimization_runs_v2(id,idempotency_key,month,matrix_version_id,scenario_id,scope_type,scope_role_id,name,status,phase,progress,requested_by,snapshot_hash,request_engine,solver_version,finished_at) values(v_run_id,'manual-studio-'||v_run_id::text,v_month,v_matrix_id,p_scenario_id,p_scope_type,p_scope_role_id,v_name,'READY','MANUAL_STUDIO',100,v_actor,v_snapshot_hash,'ORTOOLS_V2',trim(p_solver_version),now());
insert into public.optimization_run_strategies_v2(run_id,strategy_id,ordinal,status,phase,progress,metrics,started_at,finished_at) values(v_run_id,v_strategy_id,1,'READY','MANUAL_STUDIO',100,jsonb_build_object('manualStudio',true),now(),now()) returning id into v_run_strategy_id;
insert into solver_private.optimization_snapshots_v2(run_id,schema_version,snapshot_hash,snapshot) values(v_run_id,2,v_snapshot_hash,v_snapshot);
insert into public.plan_variants_v2(id,run_id,run_strategy_id,strategy_id,name,status,hard_violations,assignment_count,unfilled_count,solver_status,solution_hash,metrics,recommended,selected,snapshot_hash,selected_at,selected_by,variant_kind,revision,last_edited_at,last_edited_by) values(v_variant_id,v_run_id,v_run_strategy_id,v_strategy_id,v_name,'SELECTED',0,0,v_unfilled,'FEASIBLE',v_solution_hash,jsonb_build_object('manualStudio',true,'UNFILLED',v_unfilled),false,true,v_snapshot_hash,now(),v_actor,'LEADER_COPY',0,now(),v_actor);
insert into public.plan_shifts_v2(variant_id,slot_group_key,shift_template_id,location_id,shift_date,starts_at,ends_at,source_type,source_id) select distinct on(slot.value->>'occurrenceId') v_variant_id,slot.value->>'occurrenceId',(slot.value->>'shiftTemplateId')::uuid,(slot.value->>'locationId')::uuid,(slot.value->>'date')::date,(slot.value->>'start')::timestamptz,(slot.value->>'end')::timestamptz,'MATRIX',nullif(slot.value->>'demandId','')::uuid from jsonb_array_elements(coalesce(v_snapshot->'slots','[]'::jsonb)) slot(value) order by slot.value->>'occurrenceId',slot.value->>'slotId';
insert into public.plan_issues_v2(variant_id,shift_id,slot_key,issue_code,severity,role_id,duty_id,required_count,assigned_count,message,metadata) select v_variant_id,shift.id,slot.value->>'slotId','UNFILLED_SLOT','WARNING',(slot.value->>'roleId')::uuid,case when jsonb_array_length(coalesce(slot.value->'dutyIds','[]'::jsonb))=1 then(slot.value->'dutyIds'->>0)::uuid else null end,1,0,'Miejsce oczekuje na ręczną obsadę w Studio lidera.',jsonb_build_object('manualStudio',true,'demandId',slot.value->>'demandId') from jsonb_array_elements(coalesce(v_snapshot->'slots','[]'::jsonb)) slot(value) join public.plan_shifts_v2 shift on shift.variant_id=v_variant_id and shift.slot_group_key=slot.value->>'occurrenceId';
insert into solver_private.plan_variant_finance_v2(variant_id,base_cost_units,additions_cost_units,total_cost_units,base_cost_minor,additions_cost_minor,total_cost_minor,currency,budget_minor,hard_budget_exceeded,breakdown) values(v_variant_id,0,0,0,0,0,0,v_currency,null,false,jsonb_build_object('manualStudio',true,'currency',v_currency));
insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data) values(v_actor,'plan_variant_v2',v_variant_id::text,'CREATE_MANUAL_LEADER_STUDIO',jsonb_build_object('runId',v_run_id,'month',v_month,'scopeType',p_scope_type,'scopeRoleId',p_scope_role_id,'scenarioId',p_scenario_id,'unfilledCount',v_unfilled));
return jsonb_build_object('runId',v_run_id,'variantId',v_variant_id,'name',v_name,'revision',0,'assignmentCount',0,'unfilledCount',v_unfilled);
end;$_$;


ALTER FUNCTION "public"."optimizer_create_manual_leader_studio_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_solver_version" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_create_manual_leader_studio_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_solver_version" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_create_manual_leader_studio_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_solver_version" "text") IS 'B4F-93: creates an auditable leader working schedule from immutable demand without dispatching the optimizer.';


--
-- Name: optimizer_demand_profiles_uat_v1("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_demand_profiles_uat_v1"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_month date:=date_trunc('month',p_month)::date;
  v_matrix_id uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select matrix_version.id into v_matrix_id
  from public.matrix_versions matrix_version
  where matrix_version.status in ('ACTIVE','ARCHIVED')
    and matrix_version.schema_version>=2
    and solver_private.matrix_covers_planning_month_uat_v1(matrix_version.effective_from,v_month)
    and coalesce(matrix_version.content_hash,'') ~ '^[0-9a-f]{64}$'
    and coalesce(matrix_version.workforce_hash,'') ~ '^[0-9a-f]{64}$'
  order by matrix_version.effective_from desc,matrix_version.version desc limit 1;
  if v_matrix_id is null then raise exception 'MATRIX_V2_FOR_MONTH_NOT_FOUND'; end if;
  return jsonb_build_object('matrixVersionId',v_matrix_id,'profiles',coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',scenario.id,'validFrom',scenario.valid_from,'validTo',scenario.valid_to,
      'profileMode',case
        when scenario.is_default then 'BASELINE'
        when scenario.valid_from is not null or scenario.valid_to is not null then 'PERIOD'
        else 'UNDATED_LEGACY' end
    ) order by scenario.sort_order,scenario.name)
    from public.matrix_scenarios_v2 scenario
    where scenario.matrix_version_id=v_matrix_id and scenario.active
  ),'[]'::jsonb));
end;
$_$;


ALTER FUNCTION "public"."optimizer_demand_profiles_uat_v1"("p_month" "date") OWNER TO "postgres";

--
-- Name: optimizer_emergency_assign_alpha16("uuid", bigint, "uuid", boolean, "text", boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_emergency_assign_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_allow_soft" boolean DEFAULT false, "p_reason" "text" DEFAULT NULL::"text", "p_notify" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_diagnostics jsonb;
  v_candidate jsonb;
  v_issue public.plan_issues_v2%rowtype;
  v_id uuid;
  v_class text;
  v_auth_user uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not solver_private.alpha16_can_manage_schedule_v2(p_schedule_id) then
    raise exception 'FORBIDDEN';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(
    'operational-v2:'||p_schedule_id::text||':'||p_issue_id::text,0
  ));
  v_diagnostics:=public.optimizer_candidate_diagnostics_alpha16(
    p_schedule_id,p_issue_id
  );
  select candidate.value into v_candidate
  from jsonb_array_elements(v_diagnostics->'candidates') candidate
  where candidate.value->>'employeeId'=p_employee_id::text;
  if v_candidate is null then raise exception 'CANDIDATE_NOT_FOUND'; end if;
  v_class:=v_candidate->>'classification';
  if v_class='BLOCKED' then
    raise exception 'EMERGENCY_ASSIGNMENT_HARD_BLOCK:%',
      coalesce(v_candidate->'hardReasons','[]'::jsonb)::text;
  end if;
  if v_class='WARNING' and (
    not coalesce(p_allow_soft,false)
    or length(trim(coalesce(p_reason,'')))<3
  ) then raise exception 'SOFT_OVERRIDE_REASON_REQUIRED'; end if;
  select issue.* into v_issue from public.plan_issues_v2 issue
  where issue.id=p_issue_id;
  if exists(select 1 from public.operational_assignment_overrides_v2 existing
    where existing.schedule_id=p_schedule_id and existing.slot_key=v_issue.slot_key
      and existing.status='ACTIVE') then raise exception 'SLOT_ALREADY_FILLED'; end if;
  insert into public.operational_assignment_overrides_v2(
    schedule_id,issue_id,shift_id,slot_key,employee_id,role_id,
    assignment_class,override_reason,notify_employee,created_by
  ) values(
    p_schedule_id,p_issue_id,v_issue.shift_id,v_issue.slot_key,p_employee_id,
    v_issue.role_id,case when v_class='WARNING' then 'SOFT_OVERRIDE' else 'ELIGIBLE' end,
    case when v_class='WARNING' then trim(p_reason) else null end,
    coalesce(p_notify,false),auth.uid()
  ) returning id into v_id;
  select employee.auth_user_id into v_auth_user
  from public.employees employee where employee.id=p_employee_id;
  if coalesce(p_notify,false) and v_auth_user is not null then
    insert into public.notifications(recipient_id,channel,title,body)
    values(v_auth_user,'IN_APP','Awaryjna zmiana',
      'Dopisano Cię do zmiany dnia '||
      (v_diagnostics->'shift'->>'date')||'.');
  end if;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'operational_assignment_override_v2',v_id::text,'CREATE',
    jsonb_build_object(
      'scheduleId',p_schedule_id,'issueId',p_issue_id,
      'employeeId',p_employee_id,'classification',v_class,
      'reason',case when v_class='WARNING' then trim(p_reason) else null end,
      'notified',coalesce(p_notify,false) and v_auth_user is not null
    ));
  return jsonb_build_object(
    'id',v_id,'scheduleId',p_schedule_id,'issueId',p_issue_id,
    'employeeId',p_employee_id,'classification',v_class,
    'notified',coalesce(p_notify,false) and v_auth_user is not null
  );
end;
$$;


ALTER FUNCTION "public"."optimizer_emergency_assign_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_allow_soft" boolean, "p_reason" "text", "p_notify" boolean) OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_emergency_assign_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_allow_soft" boolean, "p_reason" "text", "p_notify" boolean); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_emergency_assign_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_allow_soft" boolean, "p_reason" "text", "p_notify" boolean) IS 'Atomic operational assignment with hard-block enforcement, explicit soft override reason, audit and post-commit notification row.';


--
-- Name: optimizer_employee_availability_month_uat_v1("uuid", "uuid"[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_employee_availability_month_uat_v1"("p_variant_id" "uuid", "p_employee_ids" "uuid"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_run public.optimization_runs_v2%rowtype;v_default_available boolean:=true;
  v_timezone text;
begin
  select run.* into v_run from public.plan_variants_v2 variant
    join public.optimization_runs_v2 run on run.id=variant.run_id where variant.id=p_variant_id;
  if v_run.id is null or not solver_private.can_access_run_v2(v_run.id) then raise exception 'VARIANT_NOT_FOUND'; end if;
  if coalesce(array_length(p_employee_ids,1),0)=0 or array_length(p_employee_ids,1)>2 then
    raise exception 'ONE_OR_TWO_EMPLOYEES_REQUIRED';end if;
  select coalesce((settings->>'missingAvailabilityMeansAvailable')::boolean,true),
    coalesce(nullif(settings->>'timezone',''),'UTC')
    into v_default_available,v_timezone from public.matrix_versions where id=v_run.matrix_version_id;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'employeeId',employee.id,'date',day_value.day_date::date,'scheduled',exists(
      select 1 from public.plan_assignments_v2 assignment join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
      where assignment.variant_id=p_variant_id and assignment.employee_id=employee.id and shift.shift_date=day_value.day_date),
    'status',case
      when exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=employee.id and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
          and (lower(constraint_row.time_range) at time zone v_timezone)::date<=day_value.day_date
          and ((upper(constraint_row.time_range)-interval '1 microsecond') at time zone v_timezone)::date>=day_value.day_date) then 'HARD_UNAVAILABLE'
      when exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=employee.id and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind='PREFER_NOT_TO_WORK'
          and (lower(constraint_row.time_range) at time zone v_timezone)::date<=day_value.day_date
          and ((upper(constraint_row.time_range)-interval '1 microsecond') at time zone v_timezone)::date>=day_value.day_date) then 'SOFT_AVOID'
      when exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=employee.id and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind='AVAILABLE_WINDOW'
          and (lower(constraint_row.time_range) at time zone v_timezone)::date<=day_value.day_date
          and ((upper(constraint_row.time_range)-interval '1 microsecond') at time zone v_timezone)::date>=day_value.day_date) then 'AVAILABLE_WINDOW'
      when v_default_available then 'DEFAULT_AVAILABLE' else 'NO_AVAILABLE_WINDOW' end,
    'label',case
      when exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=employee.id and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
          and (lower(constraint_row.time_range) at time zone v_timezone)::date<=day_value.day_date
          and ((upper(constraint_row.time_range)-interval '1 microsecond') at time zone v_timezone)::date>=day_value.day_date) then 'Nie może pracować'
      when exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=employee.id and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind='PREFER_NOT_TO_WORK'
          and (lower(constraint_row.time_range) at time zone v_timezone)::date<=day_value.day_date
          and ((upper(constraint_row.time_range)-interval '1 microsecond') at time zone v_timezone)::date>=day_value.day_date) then 'Woli nie pracować'
      when exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=employee.id and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind='AVAILABLE_WINDOW'
          and (lower(constraint_row.time_range) at time zone v_timezone)::date<=day_value.day_date
          and ((upper(constraint_row.time_range)-interval '1 microsecond') at time zone v_timezone)::date>=day_value.day_date) then 'Dostępny w podanych godzinach'
      when v_default_available then 'Dostępny domyślnie' else 'Brak zgłoszonego okna' end
  ) order by employee.id,day_value.day_date) from public.employees employee
  cross join lateral generate_series(v_run.month,(v_run.month+interval '1 month'-interval '1 day')::date,interval '1 day') day_value(day_date)
  where employee.id=any(p_employee_ids)),'[]'::jsonb);
end;
$$;


ALTER FUNCTION "public"."optimizer_employee_availability_month_uat_v1"("p_variant_id" "uuid", "p_employee_ids" "uuid"[]) OWNER TO "postgres";

--
-- Name: optimizer_employee_published_schedule_v2("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_employee_published_schedule_v2"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_engine text;
  v_employee_id uuid;
  v_schedule_id uuid;
  v_matrix_version_id uuid;
  v_month date:=date_trunc('month',p_month)::date;
  v_assignments jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  select flag.engine into v_engine
  from public.solver_feature_flags flag
  where flag.flag_key='DEFAULT_ENGINE' and flag.enabled;
  if v_engine is null then raise exception 'SOLVER_ENGINE_CONFIGURATION_MISSING'; end if;
  if v_engine not in ('ALPHA15','SHADOW','ORTOOLS_V2') then
    raise exception 'SOLVER_ENGINE_CONFIGURATION_INVALID';
  end if;
  if v_engine<>'ORTOOLS_V2' then return null; end if;
  select employee.id into v_employee_id
  from public.employees employee
  where employee.auth_user_id=auth.uid()
    and employee.active and employee.archived_at is null
  order by employee.employee_no limit 1;
  if v_employee_id is null then
    raise exception 'EMPLOYEE_ACCOUNT_NOT_LINKED';
  end if;
  select schedule.id,schedule.matrix_version_id
  into v_schedule_id,v_matrix_version_id
  from public.published_schedules_v2 schedule
  where schedule.month=v_month and schedule.status='PUBLISHED'
  order by schedule.published_at desc,schedule.id desc limit 1;
  if v_schedule_id is null then
    return jsonb_build_object(
      'engine','ORTOOLS_V2','scheduleId',null,'assignments','[]'::jsonb
    );
  end if;

  with own_assignments as (
    select assignment.id,assignment.employee_id,assignment.role_id,
      assignment.shift_id,shift.slot_group_key,shift.shift_date,
      shift.starts_at,shift.ends_at,shift.location_id,
      shift.shift_template_id
    from public.published_schedule_variants_v2 link
    join public.plan_assignments_v2 assignment
      on assignment.variant_id=link.variant_id
    join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
    where link.schedule_id=v_schedule_id
      and assignment.employee_id=v_employee_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',own.id,
    'shiftId',own.slot_group_key,
    'date',own.shift_date,
    'startsAt',own.starts_at,
    'endsAt',own.ends_at,
    'shiftCode',shift_template.code,
    'shiftName',shift_template.name,
    'location',location.name,
    'locationCode',location.code,
    'locationTimezone',location.timezone,
    'role',role.name,
    'roleCode',role.code,
    'capability',coalesce((
      select string_agg(duty.name,', ' order by duty.sort_order,duty.name)
      from public.plan_assignment_duties_v2 assignment_duty
      join public.matrix_duties_v2 duty
        on duty.id=assignment_duty.duty_id
      where assignment_duty.assignment_id=own.id
    ),''),
    'coworkers',coalesce((
      select jsonb_agg(jsonb_build_object(
        'name',coworker.first_name||' '||coworker.last_name,
        'role',coworker_role.name,
        'capability',coalesce((
          select string_agg(
            duty.name,', ' order by duty.sort_order,duty.name
          )
          from public.plan_assignment_duties_v2 assignment_duty
          join public.matrix_duties_v2 duty
            on duty.id=assignment_duty.duty_id
          where assignment_duty.assignment_id=coworker_assignment.id
        ),'')
      ) order by coworker.last_name,coworker.first_name,
        coworker_assignment.id)
      from public.published_schedule_variants_v2 coworker_link
      join public.plan_assignments_v2 coworker_assignment
        on coworker_assignment.variant_id=coworker_link.variant_id
      join public.plan_shifts_v2 coworker_shift
        on coworker_shift.id=coworker_assignment.shift_id
      join public.matrix_employee_profiles_v2 coworker
        on coworker.matrix_version_id=v_matrix_version_id
        and coworker.employee_id=coworker_assignment.employee_id
      join public.matrix_roles_v2 coworker_role
        on coworker_role.id=coworker_assignment.role_id
      where coworker_link.schedule_id=v_schedule_id
        and coworker_assignment.employee_id<>v_employee_id
        and coworker_shift.slot_group_key=own.slot_group_key
        and coworker_shift.location_id=own.location_id
        and coworker_shift.starts_at=own.starts_at
        and coworker_shift.ends_at=own.ends_at
    ),'[]'::jsonb)
  ) order by own.starts_at,own.id),'[]'::jsonb)
  into v_assignments
  from own_assignments own
  join public.matrix_locations_v2 location
    on location.id=own.location_id
    and location.matrix_version_id=v_matrix_version_id
  join public.matrix_shift_templates_v2 shift_template
    on shift_template.id=own.shift_template_id
  join public.matrix_roles_v2 role on role.id=own.role_id;

  return jsonb_build_object(
    'engine','ORTOOLS_V2','scheduleId',v_schedule_id,
    'assignments',v_assignments
  );
end;
$$;


ALTER FUNCTION "public"."optimizer_employee_published_schedule_v2"("p_month" "date") OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_employee_published_schedule_v2"("p_month" "date"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_employee_published_schedule_v2"("p_month" "date") IS 'Returns employee assignments with the versioned Matrix locationTimezone.';


--
-- Name: optimizer_employee_schedule_uat_v2("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_employee_schedule_uat_v2"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
 v_engine text; v_employee_id uuid; v_schedule_id uuid;
 v_month date:=date_trunc('month',p_month)::date; v_variant_ids uuid[];
 v_role_schedule_ids jsonb:='[]'::jsonb; v_source_type text; v_assignments jsonb;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
 if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
 select flag.engine into v_engine from public.solver_feature_flags flag
  where flag.flag_key='DEFAULT_ENGINE' and flag.enabled;
 if v_engine is null then raise exception 'SOLVER_ENGINE_CONFIGURATION_MISSING'; end if;
 if v_engine not in ('ALPHA15','SHADOW','ORTOOLS_V2') then raise exception 'SOLVER_ENGINE_CONFIGURATION_INVALID'; end if;
 if v_engine<>'ORTOOLS_V2' then return null; end if;
 select employee.id into v_employee_id from public.employees employee
  where employee.auth_user_id=auth.uid() and employee.active and employee.archived_at is null
  order by employee.employee_no limit 1;
 if v_employee_id is null then raise exception 'EMPLOYEE_ACCOUNT_NOT_LINKED'; end if;
 select array_agg(distinct publication.variant_id order by publication.variant_id),
  jsonb_agg(distinct to_jsonb(publication.id))
 into v_variant_ids,v_role_schedule_ids
 from public.published_role_schedules_v2 publication
 where publication.month=v_month and publication.status='PUBLISHED'
  and exists(select 1 from public.plan_assignments_v2 assignment
   where assignment.variant_id=publication.variant_id and assignment.employee_id=v_employee_id);
 if coalesce(cardinality(v_variant_ids),0)>0 then v_source_type:='ROLE';
 else
  select schedule.id into v_schedule_id from public.published_schedules_v2 schedule
   where schedule.month=v_month and schedule.status='PUBLISHED'
   order by schedule.published_at desc,schedule.id desc limit 1;
  if v_schedule_id is not null then
   select array_agg(link.variant_id order by link.ordinal) into v_variant_ids
   from public.published_schedule_variants_v2 link where link.schedule_id=v_schedule_id;
   v_source_type:='COMPANY';
  end if;
 end if;
 if coalesce(cardinality(v_variant_ids),0)=0 then
  return jsonb_build_object('engine','ORTOOLS_V2','sourceType',null,'scheduleId',null,
   'roleScheduleIds','[]'::jsonb,'assignments','[]'::jsonb);
 end if;
 with own_assignments as (
  select assignment.id,assignment.employee_id,assignment.role_id,assignment.shift_id,
   shift.slot_group_key,shift.shift_date,shift.starts_at,shift.ends_at,shift.location_id,
   shift.shift_template_id
  from public.plan_assignments_v2 assignment
  join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
  where assignment.variant_id=any(v_variant_ids) and assignment.employee_id=v_employee_id
 )
 select coalesce(jsonb_agg(jsonb_build_object(
  'id',own.id,'shiftId',own.slot_group_key,'date',own.shift_date,
  'startsAt',own.starts_at,'endsAt',own.ends_at,
  'shiftCode',shift_template.code,'shiftName',shift_template.name,
  'location',location.name,'locationCode',location.code,
  'locationTimezone',location.timezone,'role',role.name,'roleCode',role.code,
  'capability',coalesce((select string_agg(duty.name,', ' order by duty.sort_order,duty.name)
   from public.plan_assignment_duties_v2 assignment_duty
   join public.matrix_duties_v2 duty on duty.id=assignment_duty.duty_id
   where assignment_duty.assignment_id=own.id),''),
  'coworkers',coalesce((select jsonb_agg(jsonb_build_object(
    'name',coworker.first_name||' '||coworker.last_name,'role',coworker_role.name,
    'capability',coalesce((select string_agg(duty.name,', ' order by duty.sort_order,duty.name)
     from public.plan_assignment_duties_v2 assignment_duty
     join public.matrix_duties_v2 duty on duty.id=assignment_duty.duty_id
     where assignment_duty.assignment_id=coworker_assignment.id),'')
   ) order by coworker.last_name,coworker.first_name,coworker_assignment.id)
   from public.plan_assignments_v2 coworker_assignment
   join public.plan_shifts_v2 coworker_shift on coworker_shift.id=coworker_assignment.shift_id
   join public.employees coworker on coworker.id=coworker_assignment.employee_id
   join public.matrix_roles_v2 coworker_role on coworker_role.id=coworker_assignment.role_id
   where coworker_assignment.variant_id=any(v_variant_ids)
    and coworker_assignment.employee_id<>v_employee_id
    and coworker_shift.slot_group_key=own.slot_group_key
    and coworker_shift.location_id=own.location_id
    and coworker_shift.starts_at=own.starts_at and coworker_shift.ends_at=own.ends_at
  ),'[]'::jsonb)
 ) order by own.starts_at,own.id),'[]'::jsonb)
 into v_assignments
 from own_assignments own
 join public.matrix_locations_v2 location on location.id=own.location_id
 join public.matrix_shift_templates_v2 shift_template on shift_template.id=own.shift_template_id
 join public.matrix_roles_v2 role on role.id=own.role_id;
 return jsonb_build_object('engine','ORTOOLS_V2','sourceType',v_source_type,
  'scheduleId',v_schedule_id,'roleScheduleIds',v_role_schedule_ids,'assignments',v_assignments);
end;$$;


ALTER FUNCTION "public"."optimizer_employee_schedule_uat_v2"("p_month" "date") OWNER TO "postgres";

--
-- Name: optimizer_employee_schedule_uat_v3("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_employee_schedule_uat_v3"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_status jsonb;
  v_result jsonb;
  v_employee uuid;
  v_month date:=date_trunc('month',p_month)::date;
  v_assignments jsonb;
  v_replacements jsonb;
begin
  v_status:=public.schedule_publication_status_uat_v2(v_month);
  if coalesce((v_status->>'conflict')::boolean,false) then
    raise exception 'SCHEDULE_PUBLICATION_CONFLICT_REQUIRES_OWNER_RESOLUTION';
  end if;
  select employee.id into v_employee from public.employees employee
  where employee.auth_user_id=auth.uid() and employee.active
  order by employee.employee_no limit 1;
  v_result:=public.optimizer_employee_schedule_uat_v2(v_month);
  v_assignments:=coalesce(v_result->'assignments','[]'::jsonb);
  select coalesce(jsonb_agg(item.value),'[]'::jsonb) into v_assignments
  from jsonb_array_elements(v_assignments) item
  where not exists(select 1 from public.operational_assignment_replacements_v2 replacement
    where replacement.original_assignment_id=(item.value->>'id')::uuid
      and replacement.status='ACTIVE');
  select coalesce(jsonb_agg(original.value||jsonb_build_object(
    'id',replacement.id,'replacementOfAssignmentId',replacement.original_assignment_id,
    'isReplacement',true
  ) order by original.value->>'startsAt'),'[]'::jsonb) into v_replacements
  from public.operational_assignment_replacements_v2 replacement
  cross join lateral jsonb_array_elements(
    public.optimizer_employee_schedule_uat_v2(v_month)->'assignments'
  ) original(value)
  where replacement.month=v_month and replacement.status='ACTIVE'
    and replacement.replacement_employee_id=v_employee
    and original.value->>'id'=replacement.original_assignment_id::text;
  return jsonb_set(
    jsonb_set(v_result,'{assignments}',v_assignments||v_replacements,true),
    '{standby}',coalesce((select jsonb_agg(jsonb_build_object(
      'id',standby.id,'date',standby.standby_date,'tier',standby.tier,
      'status',standby.status,'roleId',standby.role_id,'roleName',role.name,
      'activatedShiftId',standby.activated_shift_id
    ) order by standby.standby_date,standby.tier)
      from public.published_standby_assignments_v2 standby
      join public.matrix_roles_v2 role on role.id=standby.role_id
      where standby.employee_id=v_employee and standby.month=v_month
        and standby.status in ('PLANNED','ACTIVATED','DECLINED')
    ),'[]'::jsonb),true
  );
end;
$$;


ALTER FUNCTION "public"."optimizer_employee_schedule_uat_v3"("p_month" "date") OWNER TO "postgres";

--
-- Name: optimizer_fail_v3("uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_fail_v3"("p_run_id" "uuid", "p_error" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_changed integer;
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  update public.optimization_runs set
    status='FAILED', finished_at=now(), heartbeat_at=now(),
    failure_message=left(coalesce(p_error,'UNKNOWN_ERROR'),2000),
    result_summary=coalesce(result_summary,'{}'::jsonb)||jsonb_build_object('phase','FAILED','progress',100)
  where id=p_run_id and requested_by=auth.uid() and status='RUNNING';
  get diagnostics v_changed=row_count;
  return jsonb_build_object('runId',p_run_id,'failed',v_changed=1);
end $$;


ALTER FUNCTION "public"."optimizer_fail_v3"("p_run_id" "uuid", "p_error" "text") OWNER TO "postgres";

--
-- Name: optimizer_finalize_v2("uuid", "text", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_finalize_v2"("p_run_id" "uuid", "p_name" "text", "p_candidates" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_result jsonb; v_plan uuid;
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  if exists(select 1 from jsonb_array_elements(coalesce(p_candidates,'[]'::jsonb)) c
    where coalesce((c->>'hardViolations')::integer,0)<>0) then
    raise exception 'HARD_CONSTRAINT_VALIDATION_FAILED';
  end if;
  -- optimizer_commit performs a second database-side hard validation of every
  -- assignment. Candidates remain independently stored with their own metrics.
  v_result:=public.optimizer_commit(p_run_id,p_name,p_candidates);
  v_plan:=(v_result->>'plan_id')::uuid;

  -- One alert represents one staffing requirement group, not one empty seat.
  -- required_count preserves the actual number of missing people.
  delete from public.plan_issues where plan_id=v_plan
    and issue_type in ('SHORTAGE','CAPABILITY_MISSING');
  insert into public.plan_issues(plan_id,shift_id,issue_type,severity,role,capability,required_count,assigned_count,message)
  select v_plan,s.id,
    case when nullif(x.function_code,'') is null then 'SHORTAGE' else 'CAPABILITY_MISSING' end,
    'CRITICAL',x.role_code::public.employee_role,nullif(x.function_code,''),x.missing,0,
    'Brak obsady: '||x.missing||' os. • '||x.role_code||coalesce(' / '||nullif(x.function_code,''),'')||' • '||x.work_date||' • '||x.shift_code
  from (
    select u->>'date' work_date,u->>'shiftCode' shift_code,u->>'locationId' location_id,
      u->>'role' role_code,coalesce(u->>'fn','') function_code,count(*)::integer missing
    from jsonb_array_elements(coalesce(p_candidates->0->'unfilled','[]'::jsonb)) u
    group by 1,2,3,4,5
  ) x
  left join public.shifts s on s.plan_id=v_plan and s.shift_date=x.work_date::date
    and s.shift_code=x.shift_code and s.location_id=x.location_id::uuid;

  update public.optimization_runs set result_summary=result_summary||jsonb_build_object(
    'phase','DONE','progress',100,'ranking','LEXICOGRAPHIC','engineVersion','ALPHA_14_V2',
    'alertGroups',(select count(*) from public.plan_issues where plan_id=v_plan and resolved_at is null))
  where id=p_run_id;
  return v_result||jsonb_build_object('engineVersion','ALPHA_14_V2',
    'alerts',(select count(*) from public.plan_issues where plan_id=v_plan and resolved_at is null));
end $$;


ALTER FUNCTION "public"."optimizer_finalize_v2"("p_run_id" "uuid", "p_name" "text", "p_candidates" "jsonb") OWNER TO "postgres";

--
-- Name: optimizer_finalize_v3("uuid", "text", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_finalize_v3"("p_run_id" "uuid", "p_name" "text", "p_candidates" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  r public.optimization_runs;
  c jsonb;
  v_materialized jsonb;
  v_winner jsonb;
  v_variants jsonb:='[]'::jsonb;
  v_baseline jsonb;
  v_best jsonb;
  v_status text;
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  select * into r from public.optimization_runs
    where id=p_run_id and requested_by=auth.uid() for update;
  if r.id is null or r.status<>'RUNNING' then raise exception 'OPTIMIZATION_RUN_NOT_WRITABLE'; end if;
  if jsonb_array_length(coalesce(p_candidates,'[]'::jsonb))<>3 then
    raise exception 'THREE_VARIANTS_REQUIRED';
  end if;
  if (select array_agg((x->>'rank')::integer order by (x->>'rank')::integer)
      from jsonb_array_elements(p_candidates) x)<>array[1,2,3] then
    raise exception 'VARIANT_RANKS_MUST_BE_1_2_3';
  end if;
  if (select count(distinct md5(coalesce(x->'assignments','[]'::jsonb)::text))
      from jsonb_array_elements(p_candidates) x)<>3 then
    raise exception 'THREE_DISTINCT_VARIANTS_REQUIRED';
  end if;
  if exists(select 1 from jsonb_array_elements(p_candidates) x
    where coalesce((x->>'hardViolations')::integer,0)<>0) then
    raise exception 'HARD_CONSTRAINT_VALIDATION_FAILED';
  end if;

  v_baseline:=r.checkpoint->'baselineRanking';
  select x->'metrics'->'ranking' into v_best
  from jsonb_array_elements(p_candidates) x where (x->>'rank')::integer=1;
  if v_baseline is not null and (
    coalesce((v_best->>0)::numeric,0)>coalesce((v_baseline->>0)::numeric,0)
    or (coalesce((v_best->>0)::numeric,0)=coalesce((v_baseline->>0)::numeric,0)
      and coalesce((v_best->>1)::numeric,0)>coalesce((v_baseline->>1)::numeric,0))
    or (coalesce((v_best->>0)::numeric,0)=coalesce((v_baseline->>0)::numeric,0)
      and coalesce((v_best->>1)::numeric,0)=coalesce((v_baseline->>1)::numeric,0)
      and coalesce((v_best->>2)::numeric,0)>coalesce((v_baseline->>2)::numeric,0))
  ) then raise exception 'NO_REGRESSION_GUARD'; end if;

  -- Serialize plan version allocation for this month while the three variants
  -- are materialized in one transaction.
  perform pg_advisory_xact_lock(hashtext('optimizer-plan-version:'||r.month::text));

  -- Reverse order makes rank 1 the newest plan/version and therefore the
  -- default plan returned by the existing workspace RPC.
  for c in
    select value from jsonb_array_elements(p_candidates)
    order by (value->>'rank')::integer desc
  loop
    v_materialized:=public.optimizer_materialize_candidate_v3(p_run_id,p_name,c);
    insert into public.optimization_candidates(
      run_id,plan_id,rank,score,hard_violations,metrics,assignments,selected
    ) values(
      r.id,(v_materialized->>'planId')::uuid,(c->>'rank')::integer,(c->>'score')::numeric,
      coalesce((c->>'hardViolations')::integer,0),coalesce(c->'metrics','{}'::jsonb),
      coalesce(c->'assignments','[]'::jsonb),(c->>'rank')::integer=1
    );
    v_variants:=v_variants||jsonb_build_array(v_materialized);
    if (c->>'rank')::integer=1 then v_winner:=v_materialized; end if;
  end loop;

  select coalesce(jsonb_agg(x order by (x->>'rank')::integer),'[]'::jsonb)
    into v_variants from jsonb_array_elements(v_variants) x;
  v_status:=case when coalesce((v_winner->>'unfilled')::integer,0)=0
    then 'SUCCEEDED' else 'INFEASIBLE' end;

  update public.optimization_runs set
    status=v_status,finished_at=now(),heartbeat_at=now(),
    result_summary=jsonb_build_object(
      'phase','DONE','progress',100,'ranking','LEXICOGRAPHIC','engineVersion','ALPHA_15_V3',
      'planId',v_winner->'planId','score',v_winner->'score',
      'assignments',v_winner->'assignments','unfilled',v_winner->'unfilled',
      'alertGroups',v_winner->'alertGroups','alternatives',3,
      'cost',v_winner->'totalCost','variants',v_variants,
      'baselineRanking',v_baseline)
  where id=r.id;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'optimization_run',r.id::text,'COMMIT_V3',
    (select result_summary from public.optimization_runs where id=r.id));

  return jsonb_build_object(
    'plan_id',v_winner->'planId','run_id',r.id,
    'status',case when v_status='SUCCEEDED' then 'READY' else 'READY_WITH_EXCEPTIONS' end,
    'assignments',v_winner->'assignments','issues',v_winner->'unfilled',
    'alerts',v_winner->'alertGroups','total_cost',v_winner->'totalCost',
    'score',v_winner->'score','alternatives',3,'variants',v_variants,
    'engineVersion','ALPHA_15_V3','baselineRanking',v_baseline
  );
end $$;


ALTER FUNCTION "public"."optimizer_finalize_v3"("p_run_id" "uuid", "p_name" "text", "p_candidates" "jsonb") OWNER TO "postgres";

--
-- Name: optimizer_generation_quota_uat_v1(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_generation_quota_uat_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_user uuid:=auth.uid(); v_count integer; v_limit integer;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  select generation_quota_per_user_hour into v_limit
  from solver_private.solver_job_runtime_config_uat_v1 where singleton;
  select count(*) into v_count from public.optimization_runs_v2
  where requested_by=v_user and created_at>=now()-interval '1 hour';
  return jsonb_build_object(
    'requestsLastHour',v_count,'limit',v_limit,
    'level',case
      when v_count>=v_limit then 'HARD_STOP'
      when v_count>=greatest(v_limit-3,1) then 'ANOMALY'
      when v_count>=ceil(v_limit*0.60) then 'WARNING'
      else 'NORMAL' end
  );
end;
$$;


ALTER FUNCTION "public"."optimizer_generation_quota_uat_v1"() OWNER TO "postgres";

--
-- Name: optimizer_job_status_uat_v1("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_job_status_uat_v1"("p_run_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_item solver_private.solver_job_dispatch_outbox_uat_v1%rowtype;
begin
  if not solver_private.can_access_run_v2(p_run_id) then
    raise exception 'RUN_NOT_FOUND';
  end if;
  select * into v_item
  from solver_private.solver_job_dispatch_outbox_uat_v1 where run_id=p_run_id;
  if v_item.run_id is null then
    return jsonb_build_object('runId',p_run_id,'executionMode','SERVICE');
  end if;
  return jsonb_build_object(
    'runId',p_run_id,'executionMode','JOB',
    'dispatchStatus',v_item.dispatch_status,
    'dispatchAttempt',v_item.dispatch_attempt,
    'solverRetryCount',v_item.solver_retry_count,
    'northflankRunId',v_item.northflank_run_id,
    'requestedAt',v_item.requested_at,
    'dispatchStartedAt',v_item.dispatch_started_at,
    'northflankAcceptedAt',v_item.northflank_accepted_at,
    'containerStartedAt',v_item.container_started_at,
    'workerClaimedAt',v_item.worker_claimed_at,
    'solverStartedAt',v_item.solver_started_at,
    'solverFinishedAt',v_item.solver_finished_at,
    'resultSavedAt',v_item.result_saved_at,
    'readyAt',v_item.ready_at,
    'jobFinishedAt',v_item.job_finished_at,
    'configuredVcpu',v_item.configured_vcpu,
    'configuredRamMb',v_item.configured_ram_mb,
    'peakRssMb',v_item.peak_rss_mb,
    'averageRssMb',v_item.average_rss_mb,
    'peakCpuPercent',v_item.peak_cpu_percent,
    'billableSeconds',v_item.billable_seconds,
    'estimatedComputeCostUsd',v_item.estimated_compute_cost_usd,
    'lastErrorCode',v_item.last_error_code,
    'durationsMs',jsonb_build_object(
      'requestToDispatch',case when v_item.dispatch_started_at is null then null
        else round(extract(epoch from(v_item.dispatch_started_at-v_item.requested_at))*1000) end,
      'dispatchToAccept',case when v_item.northflank_accepted_at is null then null
        else round(extract(epoch from(v_item.northflank_accepted_at-v_item.dispatch_started_at))*1000) end,
      'acceptToContainer',case when v_item.container_started_at is null then null
        else round(extract(epoch from(v_item.container_started_at-v_item.northflank_accepted_at))*1000) end,
      'containerToClaim',case when v_item.worker_claimed_at is null then null
        else round(extract(epoch from(v_item.worker_claimed_at-v_item.container_started_at))*1000) end,
      'claimToSolver',case when v_item.solver_started_at is null then null
        else round(extract(epoch from(v_item.solver_started_at-v_item.worker_claimed_at))*1000) end,
      'solverRuntime',case when v_item.solver_finished_at is null then null
        else round(extract(epoch from(v_item.solver_finished_at-v_item.solver_started_at))*1000) end,
      'postprocess',case when v_item.result_saved_at is null then null
        else round(extract(epoch from(v_item.result_saved_at-v_item.solver_finished_at))*1000) end,
      'resultToReady',case when v_item.ready_at is null then null
        else round(extract(epoch from(v_item.ready_at-v_item.result_saved_at))*1000) end,
      'total',case when coalesce(v_item.job_finished_at,v_item.ready_at) is null then null
        else round(extract(epoch from(coalesce(v_item.job_finished_at,v_item.ready_at)-v_item.requested_at))*1000) end
    )
  );
end;
$$;


ALTER FUNCTION "public"."optimizer_job_status_uat_v1"("p_run_id" "uuid") OWNER TO "postgres";

--
-- Name: optimizer_kadromierz_export_v2("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_kadromierz_export_v2"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_engine text;
  v_schedule_id uuid;
  v_matrix_version_id uuid;
  v_month date:=date_trunc('month',p_month)::date;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  select f.engine into v_engine
  from public.solver_feature_flags f
  where f.flag_key='DEFAULT_ENGINE' and f.enabled;
  if v_engine is null then raise exception 'SOLVER_ENGINE_CONFIGURATION_MISSING'; end if;
  if v_engine not in ('ALPHA15','SHADOW','ORTOOLS_V2') then
    raise exception 'SOLVER_ENGINE_CONFIGURATION_INVALID';
  end if;
  if v_engine<>'ORTOOLS_V2' then return null; end if;
  if not (
    public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE')
  ) then raise exception 'FORBIDDEN'; end if;
  select s.id,s.matrix_version_id into v_schedule_id,v_matrix_version_id
  from public.published_schedules_v2 s
  where s.month=v_month and s.status='PUBLISHED'
  order by s.published_at desc,s.id desc limit 1;
  if v_schedule_id is null then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'numer_pracownika',employee.employee_no,
    'pracownik',employee.first_name||' '||employee.last_name,
    'data',shift.shift_date,'lokal',location.code,
    'zmiana',template.code,'od',shift.starts_at,'do',shift.ends_at,
    'rola',role.code,
    'obowiazki',coalesce((
      select string_agg(duty.code,',' order by duty.sort_order,duty.code)
      from public.plan_assignment_duties_v2 assignment_duty
      join public.matrix_duties_v2 duty on duty.id=assignment_duty.duty_id
      where assignment_duty.assignment_id=assignment.id
    ),'')
  ) order by shift.starts_at,employee.employee_no,assignment.id),'[]'::jsonb)
  into v_result
  from public.published_schedule_variants_v2 link
  join public.plan_assignments_v2 assignment on assignment.variant_id=link.variant_id
  join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
  join public.matrix_employee_profiles_v2 employee
    on employee.matrix_version_id=v_matrix_version_id
    and employee.employee_id=assignment.employee_id
  join public.matrix_locations_v2 location on location.id=shift.location_id
  join public.matrix_shift_templates_v2 template on template.id=shift.shift_template_id
  join public.matrix_roles_v2 role on role.id=assignment.role_id
  where link.schedule_id=v_schedule_id;
  return v_result;
end;
$$;


ALTER FUNCTION "public"."optimizer_kadromierz_export_v2"("p_month" "date") OWNER TO "postgres";

--
-- Name: optimizer_leader_assignment_context_before_b4_details_uat_v1("uuid", "uuid", bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_assignment_context_before_b4_details_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid" DEFAULT NULL::"uuid", "p_issue_id" bigint DEFAULT NULL::bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_variant public.plan_variants_v2%rowtype;
  v_run public.optimization_runs_v2%rowtype;
  v_shift public.plan_shifts_v2%rowtype;
  v_assignment public.plan_assignments_v2%rowtype;
  v_issue public.plan_issues_v2%rowtype;
  v_role_id uuid;
  v_slot_key text;
  v_duty_id uuid;
begin
  if (p_assignment_id is null)=(p_issue_id is null) then
    raise exception 'ASSIGNMENT_OR_ISSUE_REQUIRED';
  end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then
    raise exception 'LEADER_VARIANT_NOT_EDITABLE';
  end if;
  select * into v_variant from public.plan_variants_v2 where id=p_variant_id;
  select * into v_run from public.optimization_runs_v2 where id=v_variant.run_id;
  if p_assignment_id is not null then
    select * into v_assignment from public.plan_assignments_v2
      where id=p_assignment_id and variant_id=p_variant_id;
    if v_assignment.id is null then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
    select * into v_shift from public.plan_shifts_v2 where id=v_assignment.shift_id;
    v_role_id:=v_assignment.role_id; v_slot_key:=v_assignment.slot_key;
    select duty_id into v_duty_id from public.plan_assignment_duties_v2
      where assignment_id=v_assignment.id order by duty_id limit 1;
  else
    select * into v_issue from public.plan_issues_v2
      where id=p_issue_id and variant_id=p_variant_id and issue_code='UNFILLED_SLOT';
    if v_issue.id is null then raise exception 'UNFILLED_ISSUE_NOT_FOUND'; end if;
    select * into v_shift from public.plan_shifts_v2 where id=v_issue.shift_id;
    v_role_id:=v_issue.role_id; v_slot_key:=v_issue.slot_key; v_duty_id:=v_issue.duty_id;
  end if;
  return jsonb_build_object(
    'variantId',p_variant_id,'assignmentId',p_assignment_id,'issueId',p_issue_id,
    'slotKey',v_slot_key,'currentEmployeeId',v_assignment.employee_id,
    'role',jsonb_build_object('id',role.id,'name',role.name),
    'shift',jsonb_build_object('id',v_shift.id,'date',v_shift.shift_date,
      'startsAt',v_shift.starts_at,'endsAt',v_shift.ends_at,
      'locationId',v_shift.location_id,'locationName',location.name,
      'shiftName',template.name),
    'candidates',coalesce((
      select jsonb_agg(jsonb_build_object(
        'employeeId',employee.id,'employeeNo',employee.employee_no,
        'employeeName',trim(employee.first_name||' '||employee.last_name),
        'current',employee.id=v_assignment.employee_id
      ) order by employee.last_name,employee.first_name)
      from public.employees employee
      where employee.active
        and (employee.employment_start is null or employee.employment_start<=v_shift.shift_date)
        and (employee.employment_end is null or employee.employment_end>=v_shift.shift_date)
        and exists(select 1 from public.matrix_employee_roles_v2 er
          where er.matrix_version_id=v_run.matrix_version_id and er.employee_id=employee.id
            and er.role_id=v_role_id and er.active
            and (er.valid_from is null or er.valid_from<=v_shift.shift_date)
            and (er.valid_to is null or er.valid_to>=v_shift.shift_date))
        and exists(select 1 from public.matrix_employee_locations_v2 el
          where el.matrix_version_id=v_run.matrix_version_id and el.employee_id=employee.id
            and el.location_id=v_shift.location_id and el.active and el.standard_allowed
            and (el.valid_from is null or el.valid_from<=v_shift.shift_date)
            and (el.valid_to is null or el.valid_to>=v_shift.shift_date))
        and (v_duty_id is null or exists(select 1 from public.matrix_employee_duties_v2 ed
          where ed.matrix_version_id=v_run.matrix_version_id and ed.employee_id=employee.id
            and ed.duty_id=v_duty_id and ed.active
            and (ed.role_id is null or ed.role_id=v_role_id)
            and (ed.location_id is null or ed.location_id=v_shift.location_id)
            and (ed.valid_from is null or ed.valid_from<=v_shift.shift_date)
            and (ed.valid_to is null or ed.valid_to>=v_shift.shift_date)))
    ),'[]'::jsonb)
  )
  from public.matrix_roles_v2 role,public.matrix_locations_v2 location,
    public.matrix_shift_templates_v2 template
  where role.id=v_role_id and location.id=v_shift.location_id
    and template.id=v_shift.shift_template_id;
end;
$$;


ALTER FUNCTION "public"."optimizer_leader_assignment_context_before_b4_details_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint) OWNER TO "postgres";

--
-- Name: optimizer_leader_assignment_context_before_daily_limit_uat_v2("uuid", "uuid", bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_assignment_context_before_daily_limit_uat_v2"("p_variant_id" "uuid", "p_assignment_id" "uuid" DEFAULT NULL::"uuid", "p_issue_id" bigint DEFAULT NULL::bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_variant public.plan_variants_v2%rowtype; v_run public.optimization_runs_v2%rowtype;
  v_shift public.plan_shifts_v2%rowtype; v_assignment public.plan_assignments_v2%rowtype;
  v_issue public.plan_issues_v2%rowtype; v_role_id uuid; v_slot_key text; v_duty_id uuid;
  v_default_available boolean:=true;
begin
  if (p_assignment_id is null)=(p_issue_id is null) then raise exception 'ASSIGNMENT_OR_ISSUE_REQUIRED'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then raise exception 'LEADER_VARIANT_NOT_EDITABLE'; end if;
  select * into v_variant from public.plan_variants_v2 where id=p_variant_id;
  select * into v_run from public.optimization_runs_v2 where id=v_variant.run_id;
  select coalesce((settings->>'missingAvailabilityMeansAvailable')::boolean,true)
    into v_default_available from public.matrix_versions where id=v_run.matrix_version_id;
  if p_assignment_id is not null then
    select * into v_assignment from public.plan_assignments_v2 where id=p_assignment_id and variant_id=p_variant_id;
    if v_assignment.id is null then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
    select * into v_shift from public.plan_shifts_v2 where id=v_assignment.shift_id;
    v_role_id:=v_assignment.role_id;v_slot_key:=v_assignment.slot_key;
    select duty_id into v_duty_id from public.plan_assignment_duties_v2
      where assignment_id=v_assignment.id order by duty_id limit 1;
  else
    select * into v_issue from public.plan_issues_v2
      where id=p_issue_id and variant_id=p_variant_id and issue_code='UNFILLED_SLOT';
    if v_issue.id is null then raise exception 'UNFILLED_ISSUE_NOT_FOUND'; end if;
    select * into v_shift from public.plan_shifts_v2 where id=v_issue.shift_id;
    v_role_id:=v_issue.role_id;v_slot_key:=v_issue.slot_key;v_duty_id:=v_issue.duty_id;
  end if;
  return jsonb_build_object(
    'variantId',p_variant_id,'assignmentId',p_assignment_id,'issueId',p_issue_id,
    'slotKey',v_slot_key,'currentEmployeeId',v_assignment.employee_id,
    'role',jsonb_build_object('id',role.id,'name',role.name),
    'duty',case when duty.id is null then null else jsonb_build_object('id',duty.id,'name',duty.name) end,
    'shift',jsonb_build_object('id',v_shift.id,'date',v_shift.shift_date,'startsAt',v_shift.starts_at,
      'endsAt',v_shift.ends_at,'locationId',v_shift.location_id,'locationName',location.name,'shiftName',template.name),
    'candidates',coalesce((select jsonb_agg(jsonb_build_object(
      'employeeId',candidate.employee_id,'employeeNo',candidate.employee_no,'employeeName',candidate.employee_name,
      'current',candidate.employee_id=v_assignment.employee_id,'roleName',role.name,'locationName',location.name,
      'dutyName',case when candidate.duty_match then duty.name else null end,
      'dutyMatch',candidate.duty_match,'dutyCoverageMode',case when v_duty_id is null or candidate.duty_match then 'DIRECT'
        when transfer.assignment_id is not null then 'TRANSFER' else 'NOT_COVERED' end,
      'dutyTransferAssignmentId',transfer.assignment_id,'dutyTransferEmployeeId',transfer.employee_id,
      'dutyTransferEmployeeName',transfer.employee_name,
      'availabilityStatus',candidate.availability_status,
      'suggestionEligible',candidate.availability_status in ('AVAILABLE','SOFT_AVOID')
        and (v_duty_id is null or candidate.duty_match or transfer.assignment_id is not null)
    ) order by (candidate.availability_status in ('AVAILABLE','SOFT_AVOID')
        and (v_duty_id is null or candidate.duty_match or transfer.assignment_id is not null)) desc,
      candidate.last_name,candidate.first_name,candidate.employee_no)
      from (
        select employee.id employee_id,employee.employee_no,employee.first_name,employee.last_name,
          trim(employee.first_name||' '||employee.last_name) employee_name,
          (v_duty_id is null or exists(select 1 from public.matrix_employee_duties_v2 grant_row
            where grant_row.matrix_version_id=v_run.matrix_version_id and grant_row.employee_id=employee.id
              and grant_row.duty_id=v_duty_id and grant_row.active
              and (grant_row.role_id is null or grant_row.role_id=v_role_id)
              and (grant_row.location_id is null or grant_row.location_id=v_shift.location_id)
              and (grant_row.valid_from is null or grant_row.valid_from<=v_shift.shift_date)
              and (grant_row.valid_to is null or grant_row.valid_to>=v_shift.shift_date))) duty_match,
          case
            when exists(select 1 from public.employee_time_constraints_v2 constraint_row
              where constraint_row.employee_id=employee.id and constraint_row.status='ACTIVE'
                and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
                and constraint_row.time_range&&tstzrange(v_shift.starts_at,v_shift.ends_at,'[)')) then 'HARD_UNAVAILABLE'
            when exists(select 1 from public.plan_assignments_v2 occupied
              join public.plan_shifts_v2 occupied_shift on occupied_shift.id=occupied.shift_id
              where occupied.variant_id=p_variant_id and occupied.employee_id=employee.id
                and occupied.id is distinct from p_assignment_id
                and tstzrange(occupied_shift.starts_at,occupied_shift.ends_at,'[)')
                  &&tstzrange(v_shift.starts_at,v_shift.ends_at,'[)')) then 'SHIFT_CONFLICT'
            when not v_default_available and not exists(select 1 from public.employee_time_constraints_v2 window_row
              where window_row.employee_id=employee.id and window_row.status='ACTIVE'
                and window_row.constraint_kind='AVAILABLE_WINDOW'
                and lower(window_row.time_range)<=v_shift.starts_at and upper(window_row.time_range)>=v_shift.ends_at) then 'OUTSIDE_AVAILABLE_WINDOW'
            when exists(select 1 from public.employee_time_constraints_v2 preference
              where preference.employee_id=employee.id and preference.status='ACTIVE'
                and preference.constraint_kind='PREFER_NOT_TO_WORK'
                and preference.time_range&&tstzrange(v_shift.starts_at,v_shift.ends_at,'[)')) then 'SOFT_AVOID'
            else 'AVAILABLE' end availability_status
        from public.employees employee
        where employee.active and employee.archived_at is null
          and (employee.employment_start is null or employee.employment_start<=v_shift.shift_date)
          and (employee.employment_end is null or employee.employment_end>=v_shift.shift_date)
          and exists(select 1 from public.matrix_employee_roles_v2 grant_row
            where grant_row.matrix_version_id=v_run.matrix_version_id and grant_row.employee_id=employee.id
              and grant_row.role_id=v_role_id and grant_row.active
              and (grant_row.valid_from is null or grant_row.valid_from<=v_shift.shift_date)
              and (grant_row.valid_to is null or grant_row.valid_to>=v_shift.shift_date))
          and exists(select 1 from public.matrix_employee_locations_v2 grant_row
            where grant_row.matrix_version_id=v_run.matrix_version_id and grant_row.employee_id=employee.id
              and grant_row.location_id=v_shift.location_id and grant_row.active and grant_row.standard_allowed
              and (grant_row.valid_from is null or grant_row.valid_from<=v_shift.shift_date)
              and (grant_row.valid_to is null or grant_row.valid_to>=v_shift.shift_date))
      ) candidate
      left join lateral (
        select transfer_assignment.id assignment_id,transfer_employee.id employee_id,
          trim(transfer_employee.first_name||' '||transfer_employee.last_name) employee_name
        from public.plan_assignments_v2 transfer_assignment
        join public.employees transfer_employee on transfer_employee.id=transfer_assignment.employee_id
        where v_duty_id is not null and not candidate.duty_match
          and transfer_assignment.variant_id=p_variant_id and transfer_assignment.shift_id=v_shift.id
          and transfer_assignment.id is distinct from p_assignment_id and transfer_assignment.role_id=v_role_id
          and transfer_assignment.employee_id<>candidate.employee_id
          and exists(select 1 from public.matrix_employee_duties_v2 grant_row
            where grant_row.matrix_version_id=v_run.matrix_version_id
              and grant_row.employee_id=transfer_assignment.employee_id and grant_row.duty_id=v_duty_id
              and grant_row.active and (grant_row.role_id is null or grant_row.role_id=v_role_id)
              and (grant_row.location_id is null or grant_row.location_id=v_shift.location_id)
              and (grant_row.valid_from is null or grant_row.valid_from<=v_shift.shift_date)
              and (grant_row.valid_to is null or grant_row.valid_to>=v_shift.shift_date))
          and not exists(select 1 from public.plan_assignment_duties_v2 transfer_duty
            where transfer_duty.assignment_id=transfer_assignment.id and not exists(
              select 1 from public.matrix_employee_duties_v2 candidate_grant
              where candidate_grant.matrix_version_id=v_run.matrix_version_id
                and candidate_grant.employee_id=candidate.employee_id and candidate_grant.duty_id=transfer_duty.duty_id
                and candidate_grant.active
                and (candidate_grant.role_id is null or candidate_grant.role_id=transfer_assignment.role_id)
                and (candidate_grant.location_id is null or candidate_grant.location_id=v_shift.location_id)))
        order by transfer_employee.last_name,transfer_employee.first_name,transfer_assignment.id limit 1
      ) transfer on true),'[]'::jsonb),
    'suggestionContract',jsonb_build_object('availabilityChecked',true,'dutyTransferChecked',true,'fullMonthCheckedOnSave',true)
  )
  from public.matrix_roles_v2 role
  join public.matrix_locations_v2 location on location.id=v_shift.location_id
  join public.matrix_shift_templates_v2 template on template.id=v_shift.shift_template_id
  left join public.matrix_duties_v2 duty on duty.id=v_duty_id
  where role.id=v_role_id;
end;
$$;


ALTER FUNCTION "public"."optimizer_leader_assignment_context_before_daily_limit_uat_v2"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint) OWNER TO "postgres";

--
-- Name: optimizer_leader_assignment_context_uat_v1("uuid", "uuid", bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_assignment_context_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid" DEFAULT NULL::"uuid", "p_issue_id" bigint DEFAULT NULL::bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_payload jsonb; v_duty_id uuid; v_duty_name text; v_candidates jsonb;
begin
  v_payload:=public.optimizer_leader_assignment_context_before_b4_details_uat_v1(p_variant_id,p_assignment_id,p_issue_id);
  if p_issue_id is not null then
    select issue.duty_id into v_duty_id from public.plan_issues_v2 issue where issue.id=p_issue_id and issue.variant_id=p_variant_id;
  else
    select duty.duty_id into v_duty_id from public.plan_assignment_duties_v2 duty where duty.assignment_id=p_assignment_id order by duty.duty_id limit 1;
  end if;
  select duty.name into v_duty_name from public.matrix_duties_v2 duty where duty.id=v_duty_id;
  select coalesce(jsonb_agg(candidate.value||jsonb_build_object(
    'roleName',v_payload#>>'{role,name}','locationName',v_payload#>>'{shift,locationName}','dutyName',v_duty_name
  )),'[]'::jsonb) into v_candidates
  from jsonb_array_elements(coalesce(v_payload->'candidates','[]'::jsonb)) candidate(value);
  v_payload:=jsonb_set(v_payload,'{candidates}',v_candidates,true);
  return v_payload||jsonb_build_object('duty',case when v_duty_id is null then null else jsonb_build_object('id',v_duty_id,'name',v_duty_name) end);
end;
$$;


ALTER FUNCTION "public"."optimizer_leader_assignment_context_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint) OWNER TO "postgres";

--
-- Name: optimizer_leader_assignment_context_uat_v2("uuid", "uuid", bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_assignment_context_uat_v2"("p_variant_id" "uuid", "p_assignment_id" "uuid" DEFAULT NULL::"uuid", "p_issue_id" bigint DEFAULT NULL::bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_payload jsonb;v_matrix_version_id uuid;v_shift_date date;
  v_daily_limit integer:=1;v_candidates jsonb:='[]'::jsonb;
begin
  v_payload:=public.optimizer_leader_assignment_context_before_daily_limit_uat_v2(
    p_variant_id,p_assignment_id,p_issue_id);
  select run.matrix_version_id into v_matrix_version_id
  from public.plan_variants_v2 variant
  join public.optimization_runs_v2 run on run.id=variant.run_id
  where variant.id=p_variant_id;
  v_shift_date:=(v_payload#>>'{shift,date}')::date;
  select greatest(1,coalesce(nullif(settings->>'maximumShiftsPerDay','')::integer,1))
    into v_daily_limit from public.matrix_versions where id=v_matrix_version_id;
  select coalesce(jsonb_agg(case when candidate.value->>'availabilityStatus' in ('AVAILABLE','SOFT_AVOID')
      and (select count(*) from public.plan_assignments_v2 occupied
        join public.plan_shifts_v2 occupied_shift on occupied_shift.id=occupied.shift_id
        where occupied.variant_id=p_variant_id
          and occupied.employee_id=(candidate.value->>'employeeId')::uuid
          and occupied.id is distinct from p_assignment_id
          and occupied_shift.shift_date=v_shift_date)>=v_daily_limit
    then candidate.value||jsonb_build_object(
      'availabilityStatus','DAILY_LIMIT','suggestionEligible',false)
    else candidate.value end order by candidate.ordinality),'[]'::jsonb)
    into v_candidates
  from jsonb_array_elements(coalesce(v_payload->'candidates','[]'::jsonb))
    with ordinality candidate(value,ordinality);
  return jsonb_set(v_payload,'{candidates}',v_candidates,true);
end;
$$;


ALTER FUNCTION "public"."optimizer_leader_assignment_context_uat_v2"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint) OWNER TO "postgres";

--
-- Name: optimizer_leader_assignment_context_uat_v3("uuid", "uuid", bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_assignment_context_uat_v3"("p_variant_id" "uuid", "p_assignment_id" "uuid" DEFAULT NULL::"uuid", "p_issue_id" bigint DEFAULT NULL::bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_payload jsonb;
  v_candidates jsonb := '[]'::jsonb;
  v_candidate jsonb;
  v_overtime jsonb;
begin
  v_payload := public.optimizer_leader_assignment_context_uat_v2(
    p_variant_id, p_assignment_id, p_issue_id
  );
  for v_candidate in
    select candidate.value
    from jsonb_array_elements(coalesce(v_payload->'candidates', '[]'::jsonb)) candidate(value)
  loop
    v_overtime := solver_private.leader_overtime_candidate_uat_v1(
      p_variant_id, p_assignment_id, p_issue_id, (v_candidate->>'employeeId')::uuid
    );
    v_candidate := v_candidate || v_overtime || jsonb_build_object(
      'suggestionEligible', coalesce((v_candidate->>'suggestionEligible')::boolean, false)
        and not coalesce((v_overtime->>'overtimeBlocked')::boolean, false)
    );
    v_candidates := v_candidates || jsonb_build_array(v_candidate);
  end loop;
  return jsonb_set(v_payload, '{candidates}', v_candidates, true);
end;
$$;


ALTER FUNCTION "public"."optimizer_leader_assignment_context_uat_v3"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint) OWNER TO "postgres";

--
-- Name: optimizer_leader_assignment_context_uat_v4("uuid", "uuid", bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_assignment_context_uat_v4"("p_variant_id" "uuid", "p_assignment_id" "uuid" DEFAULT NULL::"uuid", "p_issue_id" bigint DEFAULT NULL::bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_payload jsonb:=public.optimizer_leader_assignment_context_uat_v3(p_variant_id,p_assignment_id,p_issue_id);
  v_candidates jsonb:='[]'::jsonb;v_candidate jsonb;v_allowed boolean;v_timezone text;
begin
  select coalesce(version.settings->>'timezone','Europe/Warsaw') into v_timezone
  from public.plan_variants_v2 variant join public.optimization_runs_v2 run on run.id=variant.run_id
  join public.matrix_versions version on version.id=run.matrix_version_id where variant.id=p_variant_id;
  for v_candidate in select value from jsonb_array_elements(coalesce(v_payload->'candidates','[]'::jsonb)) loop
    v_allowed:=solver_private.employee_weekly_pattern_allows_uat_v1(
      (v_candidate->>'employeeId')::uuid,(v_payload#>>'{shift,date}')::date,
      (v_payload#>>'{shift,startsAt}')::timestamptz,(v_payload#>>'{shift,endsAt}')::timestamptz,
      (v_payload#>>'{role,id}')::uuid,(v_payload#>>'{shift,locationId}')::uuid,v_timezone);
    v_candidate:=v_candidate||jsonb_build_object(
      'workPatternAllowed',v_allowed,
      'availabilityStatus',case when v_allowed then v_candidate->>'availabilityStatus' else 'PERMANENT_WORK_PATTERN' end,
      'suggestionEligible',coalesce((v_candidate->>'suggestionEligible')::boolean,false) and v_allowed);
    v_candidates:=v_candidates||jsonb_build_array(v_candidate);
  end loop;
  return jsonb_set(v_payload,'{candidates}',v_candidates,true)
    ||jsonb_build_object('workPatternsChecked',true);
end;$$;


ALTER FUNCTION "public"."optimizer_leader_assignment_context_uat_v4"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint) OWNER TO "postgres";

--
-- Name: optimizer_leader_assignment_drag_preview_uat_v1("uuid", "uuid", "uuid", bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_assignment_drag_preview_uat_v1"("p_variant_id" "uuid", "p_source_assignment_id" "uuid", "p_target_assignment_id" "uuid" DEFAULT NULL::"uuid", "p_target_issue_id" bigint DEFAULT NULL::bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_result jsonb;
  v_detail text;
  v_error text;
begin
  begin
    v_result:=public.optimizer_leader_assignment_drag_uat_v1(
      p_variant_id,
      p_source_assignment_id,
      p_target_assignment_id,
      p_target_issue_id,
      'Niemutująca kontrola przeciągnięcia w Studio lidera'
    );
    raise exception 'LEADER_DRAG_PREVIEW_ROLLBACK' using detail=v_result::text;
  exception when others then
    get stacked diagnostics v_error=message_text,v_detail=pg_exception_detail;
    if v_error='LEADER_DRAG_PREVIEW_ROLLBACK' then
      return coalesce(v_detail,'{}')::jsonb||jsonb_build_object('valid',true);
    end if;
    return jsonb_build_object('valid',false,'errorCode',v_error);
  end;
end;
$$;


ALTER FUNCTION "public"."optimizer_leader_assignment_drag_preview_uat_v1"("p_variant_id" "uuid", "p_source_assignment_id" "uuid", "p_target_assignment_id" "uuid", "p_target_issue_id" bigint) OWNER TO "postgres";

--
-- Name: optimizer_leader_assignment_drag_uat_v1("uuid", "uuid", "uuid", bigint, "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_assignment_drag_uat_v1"("p_variant_id" "uuid", "p_source_assignment_id" "uuid", "p_target_assignment_id" "uuid" DEFAULT NULL::"uuid", "p_target_issue_id" bigint DEFAULT NULL::bigint, "p_reason" "text" DEFAULT 'Przeciągnięcie w Studio lidera'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid();
  v_reason text:=trim(coalesce(p_reason,''));
  v_source public.plan_assignments_v2%rowtype;
  v_target public.plan_assignments_v2%rowtype;
  v_issue public.plan_issues_v2%rowtype;
  v_source_context jsonb;v_target_context jsonb;v_candidate jsonb;
  v_snapshot jsonb;v_slot jsonb;v_new_assignment_id uuid;v_source_duty_id uuid;
begin
  if length(v_reason)<3 then raise exception 'EDIT_REASON_REQUIRED'; end if;
  if (p_target_assignment_id is null)=(p_target_issue_id is null) then
    raise exception 'DRAG_TARGET_REQUIRED';
  end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then
    raise exception 'LEADER_VARIANT_NOT_EDITABLE';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-edit:'||p_variant_id::text,0));
  select * into v_source from public.plan_assignments_v2
    where id=p_source_assignment_id and variant_id=p_variant_id for update;
  if v_source.id is null then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
  if v_source.locked then raise exception 'LOCKED_ASSIGNMENT_CANNOT_BE_REMOVED'; end if;

  if p_target_assignment_id is not null then
    if p_target_assignment_id=p_source_assignment_id then raise exception 'DRAG_TARGET_UNCHANGED'; end if;
    select * into v_target from public.plan_assignments_v2
      where id=p_target_assignment_id and variant_id=p_variant_id for update;
    if v_target.id is null then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
    if v_target.locked then raise exception 'LOCKED_ASSIGNMENT_CANNOT_BE_REMOVED'; end if;
    v_target_context:=public.optimizer_leader_assignment_context_uat_v4(
      p_variant_id,p_target_assignment_id,null);
    select value into v_candidate from jsonb_array_elements(coalesce(v_target_context->'candidates','[]'::jsonb))
      where value->>'employeeId'=v_source.employee_id::text;
    if v_candidate is null or not coalesce((v_candidate->>'workPatternAllowed')::boolean,false)
      or coalesce(v_candidate->>'dutyCoverageMode','NOT_COVERED')<>'DIRECT' then
      raise exception 'VARIANT_EMPLOYEE_ELIGIBILITY_INVALID';
    end if;
    v_source_context:=public.optimizer_leader_assignment_context_uat_v4(
      p_variant_id,p_source_assignment_id,null);
    select value into v_candidate from jsonb_array_elements(coalesce(v_source_context->'candidates','[]'::jsonb))
      where value->>'employeeId'=v_target.employee_id::text;
    if v_candidate is null or not coalesce((v_candidate->>'workPatternAllowed')::boolean,false)
      or coalesce(v_candidate->>'dutyCoverageMode','NOT_COVERED')<>'DIRECT' then
      raise exception 'VARIANT_EMPLOYEE_ELIGIBILITY_INVALID';
    end if;
    update public.plan_assignments_v2 set employee_id=v_target.employee_id,
      explanation=coalesce(explanation,'{}'::jsonb)||jsonb_build_object(
        'edited',true,'editedBy',v_actor,'editedAt',now(),'reason',v_reason,
        'dragOperation','SWAP','pairedAssignmentId',v_target.id)
      where id=v_source.id;
    update public.plan_assignments_v2 set employee_id=v_source.employee_id,
      explanation=coalesce(explanation,'{}'::jsonb)||jsonb_build_object(
        'edited',true,'editedBy',v_actor,'editedAt',now(),'reason',v_reason,
        'dragOperation','SWAP','pairedAssignmentId',v_source.id)
      where id=v_target.id;
  else
    select * into v_issue from public.plan_issues_v2
      where id=p_target_issue_id and variant_id=p_variant_id and issue_code='UNFILLED_SLOT' for update;
    if v_issue.id is null then raise exception 'UNFILLED_ISSUE_NOT_FOUND'; end if;
    v_target_context:=public.optimizer_leader_assignment_context_uat_v4(
      p_variant_id,null,p_target_issue_id);
    select value into v_candidate from jsonb_array_elements(coalesce(v_target_context->'candidates','[]'::jsonb))
      where value->>'employeeId'=v_source.employee_id::text;
    if v_candidate is null or not coalesce((v_candidate->>'workPatternAllowed')::boolean,false)
      or coalesce(v_candidate->>'dutyCoverageMode','NOT_COVERED')<>'DIRECT' then
      raise exception 'VARIANT_EMPLOYEE_ELIGIBILITY_INVALID';
    end if;
    select snapshot into v_snapshot from solver_private.optimization_snapshots_v2 snapshot
      join public.plan_variants_v2 variant on variant.run_id=snapshot.run_id where variant.id=p_variant_id;
    insert into public.plan_assignments_v2(variant_id,shift_id,slot_key,employee_id,role_id,locked,explanation)
    values(p_variant_id,v_issue.shift_id,v_issue.slot_key,v_source.employee_id,v_issue.role_id,false,
      jsonb_build_object('edited',true,'editedBy',v_actor,'editedAt',now(),'reason',v_reason,
        'dragOperation','MOVE','sourceAssignmentId',v_source.id,'filledIssueId',v_issue.id))
    returning id into v_new_assignment_id;
    select slot.value into v_slot from jsonb_array_elements(coalesce(v_snapshot->'slots','[]'::jsonb)) slot
      where slot.value->>'slotId'=v_issue.slot_key;
    insert into public.plan_assignment_duties_v2(assignment_id,duty_id)
    select v_new_assignment_id,(duty.value#>>'{}')::uuid
      from jsonb_array_elements(coalesce(v_slot->'dutyIds','[]'::jsonb)) duty;
    delete from public.plan_issues_v2 where id=v_issue.id;
    select duty_id into v_source_duty_id from public.plan_assignment_duties_v2
      where assignment_id=v_source.id order by duty_id limit 1;
    insert into public.plan_issues_v2(variant_id,shift_id,slot_key,issue_code,severity,role_id,duty_id,
      required_count,assigned_count,message,metadata)
    values(p_variant_id,v_source.shift_id,v_source.slot_key,'UNFILLED_SLOT','WARNING',v_source.role_id,
      v_source_duty_id,1,0,'Miejsce zwolnione przez przeniesienie w Studio lidera.',
      jsonb_build_object('movedAssignmentId',v_source.id,'reason',v_reason));
    delete from public.plan_assignments_v2 where id=v_source.id;
  end if;
  return solver_private.refresh_leader_variant_uat_v1(p_variant_id,v_actor,v_reason)
    ||jsonb_build_object('operation',case when p_target_assignment_id is null then 'MOVE' else 'SWAP' end,
      'sourceAssignmentId',p_source_assignment_id,'targetAssignmentId',p_target_assignment_id,
      'targetIssueId',p_target_issue_id,'newAssignmentId',v_new_assignment_id);
end;
$$;


ALTER FUNCTION "public"."optimizer_leader_assignment_drag_uat_v1"("p_variant_id" "uuid", "p_source_assignment_id" "uuid", "p_target_assignment_id" "uuid", "p_target_issue_id" bigint, "p_reason" "text") OWNER TO "postgres";

--
-- Name: optimizer_leader_assignment_lock_uat_v1("uuid", "uuid", boolean, "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_assignment_lock_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_locked" boolean, "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_actor uuid:=auth.uid();v_assignment public.plan_assignments_v2%rowtype;
  v_reason text:=trim(coalesce(p_reason,''));v_result jsonb;
begin
  if length(v_reason)<3 then raise exception 'EDIT_REASON_REQUIRED'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then
    raise exception 'LEADER_VARIANT_NOT_EDITABLE';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-edit:'||p_variant_id::text,0));
  select * into v_assignment from public.plan_assignments_v2
    where id=p_assignment_id and variant_id=p_variant_id for update;
  if v_assignment.id is null then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
  update public.plan_assignments_v2 set locked=p_locked,
    explanation=coalesce(explanation,'{}'::jsonb)||jsonb_build_object(
      'edited',true,'editedBy',v_actor,'editedAt',now(),'reason',v_reason,
      'leaderLocked',p_locked)
    where id=p_assignment_id;
  v_result:=solver_private.refresh_leader_variant_uat_v1(p_variant_id,v_actor,v_reason);
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'plan_assignment_v2',p_assignment_id::text,
    case when p_locked then 'LEADER_LOCK' else 'LEADER_UNLOCK' end,
    jsonb_build_object('variantId',p_variant_id,'reason',v_reason));
  return v_result||jsonb_build_object('assignmentId',p_assignment_id,'locked',p_locked);
end;
$$;


ALTER FUNCTION "public"."optimizer_leader_assignment_lock_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_locked" boolean, "p_reason" "text") OWNER TO "postgres";

--
-- Name: optimizer_leader_assignment_remove_uat_v1("uuid", "uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_assignment_remove_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid();
  v_assignment public.plan_assignments_v2%rowtype;
  v_duty_id uuid;
  v_reason text:=trim(coalesce(p_reason,''));
begin
  if length(v_reason)<3 then raise exception 'EDIT_REASON_REQUIRED'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then
    raise exception 'LEADER_VARIANT_NOT_EDITABLE';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-edit:'||p_variant_id::text,0));
  select * into v_assignment from public.plan_assignments_v2
    where id=p_assignment_id and variant_id=p_variant_id for update;
  if v_assignment.id is null then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
  if v_assignment.locked then raise exception 'LOCKED_ASSIGNMENT_CANNOT_BE_REMOVED'; end if;
  select duty_id into v_duty_id from public.plan_assignment_duties_v2
    where assignment_id=v_assignment.id order by duty_id limit 1;
  insert into public.plan_issues_v2(
    variant_id,shift_id,slot_key,issue_code,severity,role_id,duty_id,
    required_count,assigned_count,message,metadata
  ) values(
    p_variant_id,v_assignment.shift_id,v_assignment.slot_key,'UNFILLED_SLOT','WARNING',
    v_assignment.role_id,v_duty_id,1,0,
    'Miejsce pozostawione do uzupełnienia w wersji lidera.',
    jsonb_build_object('removedAssignmentId',v_assignment.id,'reason',v_reason)
  );
  delete from public.plan_assignments_v2 where id=v_assignment.id;
  return solver_private.refresh_leader_variant_uat_v1(p_variant_id,v_actor,v_reason);
end;
$$;


ALTER FUNCTION "public"."optimizer_leader_assignment_remove_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_reason" "text") OWNER TO "postgres";

--
-- Name: optimizer_leader_assignment_save_uat_v1("uuid", "uuid", bigint, "uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_assignment_save_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid();
  v_assignment public.plan_assignments_v2%rowtype;
  v_issue public.plan_issues_v2%rowtype;
  v_snapshot jsonb;
  v_slot jsonb;
  v_assignment_id uuid;
  v_reason text:=trim(coalesce(p_reason,''));
begin
  if length(v_reason)<3 then raise exception 'EDIT_REASON_REQUIRED'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then
    raise exception 'LEADER_VARIANT_NOT_EDITABLE';
  end if;
  if (p_assignment_id is null)=(p_issue_id is null) then
    raise exception 'ASSIGNMENT_OR_ISSUE_REQUIRED';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-edit:'||p_variant_id::text,0));
  select snapshot into v_snapshot from solver_private.optimization_snapshots_v2 snapshot
    join public.plan_variants_v2 variant on variant.run_id=snapshot.run_id
    where variant.id=p_variant_id;
  if p_assignment_id is not null then
    select * into v_assignment from public.plan_assignments_v2
      where id=p_assignment_id and variant_id=p_variant_id for update;
    if v_assignment.id is null then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
    update public.plan_assignments_v2 set employee_id=p_employee_id,
      explanation=coalesce(explanation,'{}'::jsonb)||jsonb_build_object(
        'edited',true,'editedBy',v_actor,'editedAt',now(),'reason',v_reason
      ) where id=v_assignment.id;
    v_assignment_id:=v_assignment.id;
  else
    select * into v_issue from public.plan_issues_v2
      where id=p_issue_id and variant_id=p_variant_id and issue_code='UNFILLED_SLOT'
      for update;
    if v_issue.id is null then raise exception 'UNFILLED_ISSUE_NOT_FOUND'; end if;
    insert into public.plan_assignments_v2(
      variant_id,shift_id,slot_key,employee_id,role_id,locked,explanation
    ) values(
      p_variant_id,v_issue.shift_id,v_issue.slot_key,p_employee_id,v_issue.role_id,false,
      jsonb_build_object('edited',true,'editedBy',v_actor,'editedAt',now(),
        'reason',v_reason,'filledIssueId',v_issue.id)
    ) returning id into v_assignment_id;
    select slot.value into v_slot
    from jsonb_array_elements(coalesce(v_snapshot->'slots','[]'::jsonb)) slot
    where slot.value->>'slotId'=v_issue.slot_key;
    insert into public.plan_assignment_duties_v2(assignment_id,duty_id)
    select v_assignment_id,(duty.value#>>'{}')::uuid
    from jsonb_array_elements(coalesce(v_slot->'dutyIds','[]'::jsonb)) duty;
    delete from public.plan_issues_v2 where id=v_issue.id;
  end if;
  return solver_private.refresh_leader_variant_uat_v1(p_variant_id,v_actor,v_reason)
    ||jsonb_build_object('assignmentId',v_assignment_id);
end;
$$;


ALTER FUNCTION "public"."optimizer_leader_assignment_save_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text") OWNER TO "postgres";

--
-- Name: optimizer_leader_assignment_save_uat_v1("uuid", "uuid", bigint, "uuid", "text", boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_assignment_save_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_actor uuid:=auth.uid(); v_assignment public.plan_assignments_v2%rowtype;
  v_issue public.plan_issues_v2%rowtype; v_shift public.plan_shifts_v2%rowtype;
  v_run public.optimization_runs_v2%rowtype; v_profile public.matrix_employee_profiles_v2%rowtype;
  v_snapshot jsonb; v_slot jsonb; v_assignment_id uuid; v_reason text:=trim(coalesce(p_reason,''));
  v_duration integer; v_monthly integer; v_weekly integer; v_limit_details jsonb:='[]'::jsonb;
  v_explanation jsonb; v_limit_message text;
begin
  if length(v_reason)<3 then raise exception 'EDIT_REASON_REQUIRED'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then raise exception 'LEADER_VARIANT_NOT_EDITABLE'; end if;
  if (p_assignment_id is null)=(p_issue_id is null) then raise exception 'ASSIGNMENT_OR_ISSUE_REQUIRED'; end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-edit:'||p_variant_id::text,0));
  select run.* into v_run from public.plan_variants_v2 variant
    join public.optimization_runs_v2 run on run.id=variant.run_id where variant.id=p_variant_id;
  select snapshot into v_snapshot from solver_private.optimization_snapshots_v2 snapshot
    where snapshot.run_id=v_run.id;
  if p_assignment_id is not null then
    select * into v_assignment from public.plan_assignments_v2
      where id=p_assignment_id and variant_id=p_variant_id for update;
    if v_assignment.id is null then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
    select * into v_shift from public.plan_shifts_v2 where id=v_assignment.shift_id;
  else
    select * into v_issue from public.plan_issues_v2
      where id=p_issue_id and variant_id=p_variant_id and issue_code='UNFILLED_SLOT' for update;
    if v_issue.id is null then raise exception 'UNFILLED_ISSUE_NOT_FOUND'; end if;
    select * into v_shift from public.plan_shifts_v2 where id=v_issue.shift_id;
  end if;
  select * into v_profile from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=v_run.matrix_version_id and profile.employee_id=p_employee_id
      and profile.active and profile.archived_at is null;
  if v_profile.id is null then raise exception 'VARIANT_EMPLOYEE_ELIGIBILITY_INVALID'; end if;
  v_duration:=extract(epoch from (v_shift.ends_at-v_shift.starts_at))/60;
  select coalesce(sum(extract(epoch from (shift.ends_at-shift.starts_at))/60),0)::integer,
    coalesce(sum(extract(epoch from (shift.ends_at-shift.starts_at))/60)
      filter(where shift.shift_date>=date_trunc('week',v_shift.shift_date)::date
        and shift.shift_date<date_trunc('week',v_shift.shift_date)::date+7),0)::integer
  into v_monthly,v_weekly from public.plan_assignments_v2 assignment
  join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
  where assignment.variant_id=p_variant_id and assignment.employee_id=p_employee_id
    and (p_assignment_id is null or assignment.id<>p_assignment_id)
    and shift.shift_date>=v_run.month and shift.shift_date<(v_run.month+interval '1 month')::date;
  if coalesce(v_profile.maximum_weekly_minutes,0)>0 and v_weekly+v_duration>v_profile.maximum_weekly_minutes then
    v_limit_details:=v_limit_details||jsonb_build_array(jsonb_build_object(
      'code','WEEKLY_LIMIT','currentMinutes',v_weekly,'shiftMinutes',v_duration,
      'projectedMinutes',v_weekly+v_duration,'limitMinutes',v_profile.maximum_weekly_minutes));
  end if;
  if coalesce(v_profile.maximum_monthly_minutes,0)>0 and v_monthly+v_duration>v_profile.maximum_monthly_minutes then
    v_limit_details:=v_limit_details||jsonb_build_array(jsonb_build_object(
      'code','MONTHLY_LIMIT','currentMinutes',v_monthly,'shiftMinutes',v_duration,
      'projectedMinutes',v_monthly+v_duration,'limitMinutes',v_profile.maximum_monthly_minutes));
  end if;
  if jsonb_array_length(v_limit_details)>0 and not p_allow_limit_override then
    select string_agg(case detail.value->>'code'
      when 'WEEKLY_LIMIT' then format('Tydzień: %s h + %s h = %s h przy limicie %s h.',
        round((detail.value->>'currentMinutes')::numeric/60,1),round((detail.value->>'shiftMinutes')::numeric/60,1),
        round((detail.value->>'projectedMinutes')::numeric/60,1),round((detail.value->>'limitMinutes')::numeric/60,1))
      else format('Miesiąc: %s h + %s h = %s h przy limicie %s h.',
        round((detail.value->>'currentMinutes')::numeric/60,1),round((detail.value->>'shiftMinutes')::numeric/60,1),
        round((detail.value->>'projectedMinutes')::numeric/60,1),round((detail.value->>'limitMinutes')::numeric/60,1)) end,' ')
    into v_limit_message from jsonb_array_elements(v_limit_details) detail(value);
    raise exception 'LEADER_LIMIT_OVERRIDE_REQUIRED:%',v_limit_message;
  end if;
  v_explanation:=jsonb_build_object('edited',true,'editedBy',v_actor,'editedAt',now(),'reason',v_reason,
    'limitOverride',jsonb_array_length(v_limit_details)>0 and p_allow_limit_override,
    'limitOverrideDetails',v_limit_details);
  if p_assignment_id is not null then
    update public.plan_assignments_v2 set employee_id=p_employee_id,
      explanation=(coalesce(explanation,'{}'::jsonb)-'limitOverride'-'limitOverrideDetails')||v_explanation
      where id=v_assignment.id returning id into v_assignment_id;
  else
    insert into public.plan_assignments_v2(variant_id,shift_id,slot_key,employee_id,role_id,locked,explanation)
    values(p_variant_id,v_issue.shift_id,v_issue.slot_key,p_employee_id,v_issue.role_id,false,
      v_explanation||jsonb_build_object('filledIssueId',v_issue.id)) returning id into v_assignment_id;
    select slot.value into v_slot from jsonb_array_elements(coalesce(v_snapshot->'slots','[]'::jsonb)) slot
      where slot.value->>'slotId'=v_issue.slot_key;
    insert into public.plan_assignment_duties_v2(assignment_id,duty_id)
    select v_assignment_id,(duty.value#>>'{}')::uuid
      from jsonb_array_elements(coalesce(v_slot->'dutyIds','[]'::jsonb)) duty;
    delete from public.plan_issues_v2 where id=v_issue.id;
  end if;
  return solver_private.refresh_leader_variant_uat_v1(p_variant_id,v_actor,v_reason)
    ||jsonb_build_object('assignmentId',v_assignment_id,'limitOverride',
      jsonb_array_length(v_limit_details)>0 and p_allow_limit_override,'limitOverrideDetails',v_limit_details);
end;
$$;


ALTER FUNCTION "public"."optimizer_leader_assignment_save_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean) OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_leader_assignment_save_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_leader_assignment_save_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean) IS 'Validates the complete leader copy. Weekly/monthly limits require an explicit audited override; all other hard rules remain non-overridable.';


--
-- Name: optimizer_leader_assignment_save_uat_v2("uuid", "uuid", bigint, "uuid", "text", boolean, "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_assignment_save_uat_v2"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean DEFAULT false, "p_duty_transfer_assignment_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_actor uuid:=auth.uid();v_assignment public.plan_assignments_v2%rowtype;
  v_issue public.plan_issues_v2%rowtype;v_shift public.plan_shifts_v2%rowtype;
  v_run public.optimization_runs_v2%rowtype;v_profile public.matrix_employee_profiles_v2%rowtype;
  v_transfer public.plan_assignments_v2%rowtype;v_duty_id uuid;v_snapshot jsonb;v_slot jsonb;
  v_assignment_id uuid;v_reason text:=trim(coalesce(p_reason,''));v_duration integer;
  v_monthly integer;v_weekly integer;v_limit_details jsonb:='[]'::jsonb;v_explanation jsonb;v_limit_message text;
  v_direct_duty boolean:=true;
begin
  if length(v_reason)<3 then raise exception 'EDIT_REASON_REQUIRED'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then raise exception 'LEADER_VARIANT_NOT_EDITABLE'; end if;
  if (p_assignment_id is null)=(p_issue_id is null) then raise exception 'ASSIGNMENT_OR_ISSUE_REQUIRED'; end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-edit:'||p_variant_id::text,0));
  select run.* into v_run from public.plan_variants_v2 variant
    join public.optimization_runs_v2 run on run.id=variant.run_id where variant.id=p_variant_id;
  select snapshot into v_snapshot from solver_private.optimization_snapshots_v2 where run_id=v_run.id;
  if p_assignment_id is not null then
    select * into v_assignment from public.plan_assignments_v2 where id=p_assignment_id and variant_id=p_variant_id for update;
    if v_assignment.id is null then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
    select * into v_shift from public.plan_shifts_v2 where id=v_assignment.shift_id;
    select duty_id into v_duty_id from public.plan_assignment_duties_v2 where assignment_id=v_assignment.id order by duty_id limit 1;
  else
    select * into v_issue from public.plan_issues_v2 where id=p_issue_id and variant_id=p_variant_id and issue_code='UNFILLED_SLOT' for update;
    if v_issue.id is null then raise exception 'UNFILLED_ISSUE_NOT_FOUND'; end if;
    select * into v_shift from public.plan_shifts_v2 where id=v_issue.shift_id;v_duty_id:=v_issue.duty_id;
  end if;
  select * into v_profile from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=v_run.matrix_version_id and profile.employee_id=p_employee_id
      and profile.active and profile.archived_at is null;
  if v_profile.id is null then raise exception 'VARIANT_EMPLOYEE_ELIGIBILITY_INVALID'; end if;
  if v_duty_id is not null then
    select exists(select 1 from public.matrix_employee_duties_v2 grant_row
      where grant_row.matrix_version_id=v_run.matrix_version_id and grant_row.employee_id=p_employee_id
        and grant_row.duty_id=v_duty_id and grant_row.active
        and (grant_row.role_id is null or grant_row.role_id=coalesce(v_assignment.role_id,v_issue.role_id))
        and (grant_row.location_id is null or grant_row.location_id=v_shift.location_id)) into v_direct_duty;
  end if;
  if not v_direct_duty then
    if p_duty_transfer_assignment_id is null then raise exception 'DUTY_TRANSFER_REQUIRED'; end if;
    select * into v_transfer from public.plan_assignments_v2
      where id=p_duty_transfer_assignment_id and variant_id=p_variant_id and shift_id=v_shift.id
        and id is distinct from p_assignment_id and role_id=coalesce(v_assignment.role_id,v_issue.role_id) for update;
    if v_transfer.id is null then raise exception 'DUTY_TRANSFER_ASSIGNMENT_INVALID'; end if;
    if not exists(select 1 from public.matrix_employee_duties_v2 grant_row
      where grant_row.matrix_version_id=v_run.matrix_version_id and grant_row.employee_id=v_transfer.employee_id
        and grant_row.duty_id=v_duty_id and grant_row.active
        and (grant_row.role_id is null or grant_row.role_id=v_transfer.role_id)
        and (grant_row.location_id is null or grant_row.location_id=v_shift.location_id)) then
      raise exception 'DUTY_TRANSFER_EMPLOYEE_INVALID';
    end if;
    if exists(select 1 from public.plan_assignment_duties_v2 transfer_duty
      where transfer_duty.assignment_id=v_transfer.id and not exists(select 1
        from public.matrix_employee_duties_v2 candidate_grant
        where candidate_grant.matrix_version_id=v_run.matrix_version_id
          and candidate_grant.employee_id=p_employee_id and candidate_grant.duty_id=transfer_duty.duty_id
          and candidate_grant.active and (candidate_grant.role_id is null or candidate_grant.role_id=v_transfer.role_id)
          and (candidate_grant.location_id is null or candidate_grant.location_id=v_shift.location_id))) then
      raise exception 'DUTY_TRANSFER_TARGET_SLOT_INVALID';
    end if;
  end if;
  v_duration:=extract(epoch from (v_shift.ends_at-v_shift.starts_at))/60;
  select coalesce(sum(extract(epoch from (shift.ends_at-shift.starts_at))/60),0)::integer,
    coalesce(sum(extract(epoch from (shift.ends_at-shift.starts_at))/60) filter(
      where shift.shift_date>=date_trunc('week',v_shift.shift_date)::date
        and shift.shift_date<date_trunc('week',v_shift.shift_date)::date+7),0)::integer
  into v_monthly,v_weekly from public.plan_assignments_v2 assignment
  join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
  where assignment.variant_id=p_variant_id and assignment.employee_id=p_employee_id
    and assignment.id is distinct from p_assignment_id and assignment.id is distinct from p_duty_transfer_assignment_id
    and shift.shift_date>=v_run.month and shift.shift_date<(v_run.month+interval '1 month')::date;
  if coalesce(v_profile.maximum_weekly_minutes,0)>0 and v_weekly+v_duration>v_profile.maximum_weekly_minutes then
    v_limit_details:=v_limit_details||jsonb_build_array(jsonb_build_object('code','WEEKLY_LIMIT','currentMinutes',v_weekly,
      'shiftMinutes',v_duration,'projectedMinutes',v_weekly+v_duration,'limitMinutes',v_profile.maximum_weekly_minutes));end if;
  if coalesce(v_profile.maximum_monthly_minutes,0)>0 and v_monthly+v_duration>v_profile.maximum_monthly_minutes then
    v_limit_details:=v_limit_details||jsonb_build_array(jsonb_build_object('code','MONTHLY_LIMIT','currentMinutes',v_monthly,
      'shiftMinutes',v_duration,'projectedMinutes',v_monthly+v_duration,'limitMinutes',v_profile.maximum_monthly_minutes));end if;
  if jsonb_array_length(v_limit_details)>0 and not p_allow_limit_override then
    select string_agg(format('%s: %s h + %s h = %s h przy limicie %s h.',
      case detail.value->>'code' when 'WEEKLY_LIMIT' then 'Tydzień' else 'Miesiąc' end,
      round((detail.value->>'currentMinutes')::numeric/60,1),round((detail.value->>'shiftMinutes')::numeric/60,1),
      round((detail.value->>'projectedMinutes')::numeric/60,1),round((detail.value->>'limitMinutes')::numeric/60,1)),' ')
      into v_limit_message from jsonb_array_elements(v_limit_details) detail(value);
    raise exception 'LEADER_LIMIT_OVERRIDE_REQUIRED:%',v_limit_message;
  end if;
  v_explanation:=jsonb_build_object('edited',true,'editedBy',v_actor,'editedAt',now(),'reason',v_reason,
    'limitOverride',jsonb_array_length(v_limit_details)>0 and p_allow_limit_override,
    'limitOverrideDetails',v_limit_details,'dutyTransferAssignmentId',p_duty_transfer_assignment_id);
  if p_assignment_id is not null then
    if v_direct_duty then
      update public.plan_assignments_v2 set employee_id=p_employee_id,
        explanation=(coalesce(explanation,'{}'::jsonb)-'limitOverride'-'limitOverrideDetails')||v_explanation
        where id=v_assignment.id returning id into v_assignment_id;
    else
      update public.plan_assignments_v2 set employee_id=v_transfer.employee_id,
        explanation=coalesce(explanation,'{}'::jsonb)||v_explanation||jsonb_build_object('dutyTransferredFrom',v_transfer.id)
        where id=v_assignment.id returning id into v_assignment_id;
      update public.plan_assignments_v2 set employee_id=p_employee_id,
        explanation=coalesce(explanation,'{}'::jsonb)||v_explanation||jsonb_build_object('dutyTransferredTo',v_assignment.id)
        where id=v_transfer.id;
    end if;
  else
    insert into public.plan_assignments_v2(variant_id,shift_id,slot_key,employee_id,role_id,locked,explanation)
    values(p_variant_id,v_issue.shift_id,v_issue.slot_key,case when v_direct_duty then p_employee_id else v_transfer.employee_id end,
      v_issue.role_id,false,v_explanation||jsonb_build_object('filledIssueId',v_issue.id)) returning id into v_assignment_id;
    select slot.value into v_slot from jsonb_array_elements(coalesce(v_snapshot->'slots','[]'::jsonb)) slot
      where slot.value->>'slotId'=v_issue.slot_key;
    insert into public.plan_assignment_duties_v2(assignment_id,duty_id)
      select v_assignment_id,(duty.value#>>'{}')::uuid from jsonb_array_elements(coalesce(v_slot->'dutyIds','[]'::jsonb)) duty;
    if not v_direct_duty then update public.plan_assignments_v2 set employee_id=p_employee_id,
      explanation=coalesce(explanation,'{}'::jsonb)||v_explanation||jsonb_build_object('dutyTransferredTo',v_assignment_id)
      where id=v_transfer.id;end if;
    delete from public.plan_issues_v2 where id=v_issue.id;
  end if;
  return solver_private.refresh_leader_variant_uat_v1(p_variant_id,v_actor,v_reason)
    ||jsonb_build_object('assignmentId',v_assignment_id,'limitOverride',jsonb_array_length(v_limit_details)>0 and p_allow_limit_override,
      'limitOverrideDetails',v_limit_details,'dutyTransferAssignmentId',p_duty_transfer_assignment_id);
end;
$$;


ALTER FUNCTION "public"."optimizer_leader_assignment_save_uat_v2"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid") OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_leader_assignment_save_uat_v2"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_leader_assignment_save_uat_v2"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid") IS 'Atomic leader assignment with full variant validation, explicit limit override and optional same-shift duty hand-off.';


--
-- Name: optimizer_leader_assignment_save_uat_v3("uuid", "uuid", bigint, "uuid", "text", boolean, "uuid", boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_assignment_save_uat_v3"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean DEFAULT false, "p_duty_transfer_assignment_id" "uuid" DEFAULT NULL::"uuid", "p_approve_overtime" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid := auth.uid();
  v_overtime jsonb;
  v_result jsonb;
  v_policy text;
  v_added integer;
  v_assignment_id uuid;
  v_overtime_assignment_id uuid;
  v_snapshot jsonb;
  v_strategy_id uuid;
  v_payload jsonb;
  v_validation jsonb;
  v_transient_approval boolean := false;
begin
  v_overtime := solver_private.leader_overtime_candidate_uat_v1(
    p_variant_id, p_assignment_id, p_issue_id, p_employee_id
  );
  v_policy := coalesce(v_overtime->>'overtimePolicy', 'NEVER');
  v_added := coalesce((v_overtime->>'addedOvertimeMinutes')::integer, 0);

  if v_added > 0 and v_policy = 'NEVER' then
    raise exception 'LEADER_OVERTIME_NOT_ALLOWED:%', v_overtime::text;
  end if;
  if v_added > 0 and v_policy = 'APPROVAL_REQUIRED' and not p_approve_overtime then
    raise exception 'LEADER_OVERTIME_APPROVAL_REQUIRED:%', v_overtime::text;
  end if;
  if v_added > 0 and v_policy = 'APPROVAL_REQUIRED' and p_approve_overtime then
    if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
    v_transient_approval := true;
    perform set_config(
      'solver_private.b4f164_overtime_approval_employee',p_employee_id::text,true
    );
    perform set_config(
      'solver_private.b4f164_overtime_approval_actor',v_actor::text,true
    );
    perform set_config(
      'solver_private.b4f164_overtime_approval_quote',v_overtime::text,true
    );
  end if;

  v_result := public.optimizer_leader_assignment_save_uat_v2(
    p_variant_id, p_assignment_id, p_issue_id, p_employee_id, p_reason,
    p_allow_limit_override, p_duty_transfer_assignment_id
  );
  v_assignment_id := nullif(v_result->>'assignmentId', '')::uuid;
  v_overtime_assignment_id := coalesce(
    nullif(v_result->>'dutyTransferAssignmentId','')::uuid,v_assignment_id
  );

  if v_added > 0 and v_overtime_assignment_id is not null then
    update public.plan_assignments_v2
    set explanation = coalesce(explanation, '{}'::jsonb) || jsonb_build_object(
      'overtimeDecision', case when v_policy = 'APPROVAL_REQUIRED' then 'LEADER_APPROVED' else 'POLICY_ALLOWED' end,
      'overtimeApprovedBy', case when v_policy = 'APPROVAL_REQUIRED' then v_actor else null end,
      'overtimeApprovedAt', case when v_policy = 'APPROVAL_REQUIRED' then now() else null end,
      'overtimeQuote', v_overtime
    )
    where id = v_overtime_assignment_id;
    insert into public.audit_log(actor_id, entity_type, entity_id, action, new_data)
    values(
      v_actor, 'plan_assignment_v2', v_overtime_assignment_id::text,
      case when v_policy = 'APPROVAL_REQUIRED' then 'APPROVE_OVERTIME' else 'ASSIGN_OVERTIME_ALLOWED' end,
      jsonb_build_object('reason', trim(coalesce(p_reason, '')), 'quote', v_overtime)
    );
  end if;

  if v_transient_approval then
    select snapshot.snapshot,variant.strategy_id
    into v_snapshot,v_strategy_id
    from public.plan_variants_v2 variant
    join solver_private.optimization_snapshots_v2 snapshot on snapshot.run_id=variant.run_id
    where variant.id=p_variant_id;
    v_payload:=solver_private.materialized_variant_payload_v2(
      array[p_variant_id],v_snapshot,v_strategy_id
    );
    v_validation:=solver_private.validate_variant_v2(v_snapshot,v_payload);
    perform set_config('solver_private.b4f164_overtime_approval_employee','',true);
    perform set_config('solver_private.b4f164_overtime_approval_actor','',true);
    perform set_config('solver_private.b4f164_overtime_approval_quote','',true);
    v_result:=v_result||jsonb_build_object('validation',v_validation);
  end if;

  return v_result || jsonb_build_object(
    'overtimePolicy', v_policy,
    'overtimeApproved', v_added > 0 and (v_policy = 'ALLOWED' or p_approve_overtime),
    'overtimeApprovalAssignmentId',v_overtime_assignment_id,
    'overtimeQuote', v_overtime
  );
end;
$$;


ALTER FUNCTION "public"."optimizer_leader_assignment_save_uat_v3"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid", "p_approve_overtime" boolean) OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_leader_assignment_save_uat_v3"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid", "p_approve_overtime" boolean); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_leader_assignment_save_uat_v3"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid", "p_approve_overtime" boolean) IS 'B4F-164: leader edit persists explicit overtime approval before the final full-variant validation.';


--
-- Name: optimizer_leader_assignment_save_uat_v4("uuid", "uuid", bigint, "uuid", "text", boolean, "uuid", boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_assignment_save_uat_v4"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean DEFAULT false, "p_duty_transfer_assignment_id" "uuid" DEFAULT NULL::"uuid", "p_approve_overtime" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_context jsonb;v_candidate jsonb;
begin
  v_context:=public.optimizer_leader_assignment_context_uat_v4(p_variant_id,p_assignment_id,p_issue_id);
  select value into v_candidate from jsonb_array_elements(coalesce(v_context->'candidates','[]'::jsonb))
    where value->>'employeeId'=p_employee_id::text;
  if v_candidate is null then raise exception 'VARIANT_EMPLOYEE_ELIGIBILITY_INVALID'; end if;
  if not coalesce((v_candidate->>'workPatternAllowed')::boolean,false) then
    raise exception 'PERMANENT_WORK_PATTERN_BLOCK:%',jsonb_build_object(
      'employeeId',p_employee_id,'date',v_context#>>'{shift,date}',
      'message','Stały wzorzec pracy pracownika nie obejmuje tej zmiany.')::text;
  end if;
  return public.optimizer_leader_assignment_save_uat_v3(
    p_variant_id,p_assignment_id,p_issue_id,p_employee_id,p_reason,p_allow_limit_override,
    p_duty_transfer_assignment_id,p_approve_overtime);
end;$$;


ALTER FUNCTION "public"."optimizer_leader_assignment_save_uat_v4"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid", "p_approve_overtime" boolean) OWNER TO "postgres";

--
-- Name: optimizer_leader_assignment_validate_uat_v1("uuid", "uuid", bigint, "uuid", boolean, "uuid", boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_assignment_validate_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_allow_limit_override" boolean DEFAULT false, "p_duty_transfer_assignment_id" "uuid" DEFAULT NULL::"uuid", "p_approve_overtime" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_result jsonb;
  v_rollback_marker constant text := 'B4F95_DRY_RUN_ROLLBACK';
begin
  begin
    v_result := public.optimizer_leader_assignment_save_uat_v3(
      p_variant_id,
      p_assignment_id,
      p_issue_id,
      p_employee_id,
      'Walidacja przed zapisem',
      p_allow_limit_override,
      p_duty_transfer_assignment_id,
      p_approve_overtime
    );
    raise exception using errcode = 'P0001', message = v_rollback_marker;
  exception
    when raise_exception then
      if sqlerrm <> v_rollback_marker then
        raise;
      end if;
  end;

  return coalesce(v_result, '{}'::jsonb) || jsonb_build_object(
    'valid', true,
    'mutated', false,
    'checkedAt', now()
  );
end;
$$;


ALTER FUNCTION "public"."optimizer_leader_assignment_validate_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid", "p_approve_overtime" boolean) OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_leader_assignment_validate_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid", "p_approve_overtime" boolean); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_leader_assignment_validate_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid", "p_approve_overtime" boolean) IS 'B4F-95: runs the exact atomic leader-save validation inside a rolled-back subtransaction; it never persists assignments, issues, audit rows or counters.';


--
-- Name: optimizer_leader_assignment_validate_uat_v2("uuid", "uuid", bigint, "uuid", boolean, "uuid", boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_assignment_validate_uat_v2"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_allow_limit_override" boolean DEFAULT false, "p_duty_transfer_assignment_id" "uuid" DEFAULT NULL::"uuid", "p_approve_overtime" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_result jsonb;v_rollback_marker constant text:='B4F95_DRY_RUN_ROLLBACK';
begin
  begin
    v_result:=public.optimizer_leader_assignment_save_uat_v4(
      p_variant_id,p_assignment_id,p_issue_id,p_employee_id,'Sprawdzenie przed zapisem',
      p_allow_limit_override,p_duty_transfer_assignment_id,p_approve_overtime);
    raise exception using errcode='P0001',message=v_rollback_marker;
  exception when raise_exception then
    if sqlerrm<>v_rollback_marker then raise; end if;
  end;
  return coalesce(v_result,'{}'::jsonb)||jsonb_build_object('valid',true,'mutated',false,'checkedAt',now());
end;$$;


ALTER FUNCTION "public"."optimizer_leader_assignment_validate_uat_v2"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid", "p_approve_overtime" boolean) OWNER TO "postgres";

--
-- Name: optimizer_leader_assignments_bulk_uat_v1("uuid", "uuid"[], "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_assignments_bulk_uat_v1"("p_variant_id" "uuid", "p_assignment_ids" "uuid"[], "p_operation" "text", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid();v_operation text:=upper(trim(coalesce(p_operation,'')));
  v_expected integer;v_found integer;v_locked integer;v_result jsonb;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then raise exception 'LEADER_VARIANT_FORBIDDEN'; end if;
  if length(trim(coalesce(p_reason,'')))<3 then raise exception 'EDIT_REASON_REQUIRED'; end if;
  if v_operation not in ('LOCK','UNLOCK','REMOVE') then raise exception 'LEADER_BULK_OPERATION_INVALID'; end if;
  select count(distinct id) into v_expected from unnest(coalesce(p_assignment_ids,'{}'::uuid[])) id;
  if v_expected<1 or v_expected>1000 then raise exception 'LEADER_BULK_SELECTION_INVALID'; end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-edit:'||p_variant_id::text,0));
  perform 1 from public.plan_assignments_v2 assignment where assignment.variant_id=p_variant_id
    and assignment.id=any(p_assignment_ids) for update;
  select count(*),count(*) filter(where assignment.locked) into v_found,v_locked
  from public.plan_assignments_v2 assignment where assignment.variant_id=p_variant_id
    and assignment.id=any(p_assignment_ids);
  if v_found<>v_expected then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
  if v_operation='REMOVE' and v_locked>0 then raise exception 'LOCKED_ASSIGNMENT_CANNOT_BE_REMOVED'; end if;

  if v_operation in ('LOCK','UNLOCK') then
    update public.plan_assignments_v2 assignment set locked=v_operation='LOCK',
      explanation=coalesce(assignment.explanation,'{}'::jsonb)||jsonb_build_object(
        'edited',true,'editedBy',v_actor,'editedAt',now(),'reason',trim(p_reason),
        'bulkOperation',v_operation,'leaderLocked',v_operation='LOCK')
    where assignment.variant_id=p_variant_id and assignment.id=any(p_assignment_ids);
  else
    insert into public.plan_issues_v2(variant_id,shift_id,slot_key,issue_code,severity,role_id,duty_id,
      required_count,assigned_count,message,metadata)
    select assignment.variant_id,assignment.shift_id,assignment.slot_key,'UNFILLED_SLOT','WARNING',assignment.role_id,
      duty.duty_id,1,0,'Miejsce zwolnione przez operację zbiorczą w Studio lidera.',
      jsonb_build_object('removedAssignmentId',assignment.id,'reason',trim(p_reason),'bulkOperation','REMOVE')
    from public.plan_assignments_v2 assignment
    left join lateral(select link.duty_id from public.plan_assignment_duties_v2 link
      where link.assignment_id=assignment.id order by link.duty_id limit 1) duty on true
    where assignment.variant_id=p_variant_id and assignment.id=any(p_assignment_ids);
    delete from public.plan_assignments_v2 assignment where assignment.variant_id=p_variant_id
      and assignment.id=any(p_assignment_ids);
  end if;
  v_result:=solver_private.refresh_leader_variant_uat_v1(p_variant_id,v_actor,trim(p_reason));
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'plan_variant_v2',p_variant_id::text,'LEADER_BULK_'||v_operation,
    jsonb_build_object('assignmentIds',p_assignment_ids,'count',v_expected,'reason',trim(p_reason)));
  return v_result||jsonb_build_object('operation',v_operation,'affected',v_expected);
end;$$;


ALTER FUNCTION "public"."optimizer_leader_assignments_bulk_uat_v1"("p_variant_id" "uuid", "p_assignment_ids" "uuid"[], "p_operation" "text", "p_reason" "text") OWNER TO "postgres";

--
-- Name: optimizer_leader_checkpoint_create_uat_v1("uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_checkpoint_create_uat_v1"("p_variant_id" "uuid", "p_name" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid();
  v_variant public.plan_variants_v2%rowtype;
  v_seq bigint;
  v_name text:=trim(coalesce(p_name,''));
begin
  if length(v_name) not between 3 and 120 then raise exception 'CHECKPOINT_NAME_INVALID'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then
    raise exception 'LEADER_VARIANT_NOT_EDITABLE';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-edit:'||p_variant_id::text,0));
  select * into v_variant from public.plan_variants_v2 variant
  where variant.id=p_variant_id for update;
  if v_variant.leader_workflow_status<>'DRAFT' then raise exception 'LEADER_CHECKPOINT_DRAFT_REQUIRED'; end if;
  v_seq:=solver_private.record_leader_variant_history_v2(
    p_variant_id,v_variant.revision,'Punkt kontrolny: '||v_name,v_actor
  );
  update solver_private.leader_variant_history_v2
  set is_checkpoint=true,checkpoint_name=v_name
  where seq=v_seq and variant_id=p_variant_id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'plan_variant_v2',p_variant_id::text,'LEADER_CHECKPOINT_CREATE',
    jsonb_build_object('historySeq',v_seq,'revision',v_variant.revision,'name',v_name));
  return jsonb_build_object('variantId',p_variant_id,'historySeq',v_seq,
    'revision',v_variant.revision,'name',v_name);
end;
$$;


ALTER FUNCTION "public"."optimizer_leader_checkpoint_create_uat_v1"("p_variant_id" "uuid", "p_name" "text") OWNER TO "postgres";

--
-- Name: optimizer_leader_checkpoint_restore_uat_v1("uuid", bigint, "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_checkpoint_restore_uat_v1"("p_variant_id" "uuid", "p_history_seq" bigint, "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid();
  v_variant public.plan_variants_v2%rowtype;
  v_target solver_private.leader_variant_history_v2%rowtype;
  v_result jsonb;
begin
  if length(trim(coalesce(p_reason,'')))<3 then raise exception 'CHECKPOINT_RESTORE_REASON_REQUIRED'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then
    raise exception 'LEADER_VARIANT_NOT_EDITABLE';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-edit:'||p_variant_id::text,0));
  select * into v_variant from public.plan_variants_v2 variant
  where variant.id=p_variant_id for update;
  if v_variant.leader_workflow_status<>'DRAFT' then raise exception 'LEADER_CHECKPOINT_DRAFT_REQUIRED'; end if;
  select * into v_target from solver_private.leader_variant_history_v2 history
  where history.variant_id=p_variant_id and history.seq=p_history_seq
    and history.is_checkpoint for update;
  if v_target.seq is null then raise exception 'LEADER_CHECKPOINT_NOT_FOUND'; end if;

  perform set_config('solver_private.history_restore','on',true);
  delete from public.plan_assignments_v2 where variant_id=p_variant_id;
  delete from public.plan_issues_v2 where variant_id=p_variant_id;
  insert into public.plan_assignments_v2(
    id,variant_id,shift_id,slot_key,employee_id,role_id,locked,explanation,created_at
  )
  select id,variant_id,shift_id,slot_key,employee_id,role_id,locked,explanation,created_at
  from jsonb_populate_recordset(null::public.plan_assignments_v2,v_target.snapshot->'assignments');
  insert into public.plan_assignment_duties_v2(assignment_id,duty_id)
  select assignment_id,duty_id
  from jsonb_populate_recordset(null::public.plan_assignment_duties_v2,v_target.snapshot->'duties');
  insert into public.plan_issues_v2(
    id,variant_id,shift_id,slot_key,issue_code,severity,role_id,duty_id,
    required_count,assigned_count,message,metadata,created_at
  ) overriding system value
  select id,variant_id,shift_id,slot_key,issue_code,severity,role_id,duty_id,
    required_count,assigned_count,message,metadata,created_at
  from jsonb_populate_recordset(null::public.plan_issues_v2,v_target.snapshot->'issues');

  v_result:=solver_private.refresh_leader_variant_uat_v1(
    p_variant_id,v_actor,'Przywrócenie punktu kontrolnego: '||v_target.checkpoint_name
  );
  update solver_private.leader_variant_history_cursor_v2
  set current_seq=v_target.seq,updated_at=now(),updated_by=v_actor
  where variant_id=p_variant_id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'plan_variant_v2',p_variant_id::text,'LEADER_CHECKPOINT_RESTORE',
    jsonb_build_object('historySeq',v_target.seq,'checkpointRevision',v_target.revision,
      'name',v_target.checkpoint_name,'reason',trim(p_reason)));
  return v_result||jsonb_build_object('historySeq',v_target.seq,
    'checkpointRevision',v_target.revision,'checkpointName',v_target.checkpoint_name);
end;
$$;


ALTER FUNCTION "public"."optimizer_leader_checkpoint_restore_uat_v1"("p_variant_id" "uuid", "p_history_seq" bigint, "p_reason" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_leader_checkpoint_restore_uat_v1"("p_variant_id" "uuid", "p_history_seq" bigint, "p_reason" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_leader_checkpoint_restore_uat_v1"("p_variant_id" "uuid", "p_history_seq" bigint, "p_reason" "text") IS 'B4F-100: restores exact issue identities for named checkpoints using OVERRIDING SYSTEM VALUE.';


--
-- Name: optimizer_leader_draft_validate_uat_v1("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_draft_validate_uat_v1"("p_variant_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_variant public.plan_variants_v2%rowtype;
  v_snapshot jsonb;
  v_payload jsonb;
  v_validation jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then
    raise exception 'LEADER_VARIANT_FORBIDDEN';
  end if;
  select * into v_variant from public.plan_variants_v2
  where id=p_variant_id and variant_kind='LEADER_COPY';
  if v_variant.id is null then raise exception 'LEADER_VARIANT_NOT_FOUND'; end if;
  select snapshot into v_snapshot from solver_private.optimization_snapshots_v2
  where run_id=v_variant.run_id;
  if v_snapshot is null then raise exception 'SNAPSHOT_NOT_FOUND'; end if;
  v_payload:=solver_private.materialized_variant_payload_v2(
    array[p_variant_id],v_snapshot,v_variant.strategy_id);
  v_validation:=solver_private.validate_variant_v2(v_snapshot,v_payload);
  return jsonb_build_object(
    'variantId',p_variant_id,
    'revision',v_variant.revision,
    'valid',coalesce((v_validation->>'hardViolations')::integer,0)=0,
    'validation',v_validation,
    'warnings',jsonb_build_object(
      'unfilledCount',coalesce((v_validation->>'unfilledCount')::integer,0)
    )
  );
end;
$$;


ALTER FUNCTION "public"."optimizer_leader_draft_validate_uat_v1"("p_variant_id" "uuid") OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_leader_draft_validate_uat_v1"("p_variant_id" "uuid"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_leader_draft_validate_uat_v1"("p_variant_id" "uuid") IS 'Read-only full-draft validation. It never changes workflow status, assignments, audit history or publication.';


--
-- Name: optimizer_leader_history_move_uat_v1("uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_history_move_uat_v1"("p_variant_id" "uuid", "p_direction" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid();
  v_cursor bigint;
  v_target solver_private.leader_variant_history_v2%rowtype;
  v_result jsonb;
begin
  if p_direction not in ('UNDO','REDO') then raise exception 'INVALID_HISTORY_DIRECTION'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then
    raise exception 'LEADER_VARIANT_NOT_EDITABLE';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-edit:'||p_variant_id::text,0));
  select current_seq into v_cursor
  from solver_private.leader_variant_history_cursor_v2
  where variant_id=p_variant_id for update;
  if p_direction='UNDO' then
    select * into v_target from solver_private.leader_variant_history_v2
    where variant_id=p_variant_id and seq<v_cursor order by seq desc limit 1;
  else
    select * into v_target from solver_private.leader_variant_history_v2
    where variant_id=p_variant_id and seq>v_cursor order by seq limit 1;
  end if;
  if v_target.seq is null then raise exception 'HISTORY_STEP_NOT_AVAILABLE'; end if;

  perform set_config('solver_private.history_restore','on',true);
  delete from public.plan_assignments_v2 where variant_id=p_variant_id;
  delete from public.plan_issues_v2 where variant_id=p_variant_id;
  insert into public.plan_assignments_v2(
    id,variant_id,shift_id,slot_key,employee_id,role_id,locked,explanation,created_at
  )
  select id,variant_id,shift_id,slot_key,employee_id,role_id,locked,explanation,created_at
  from jsonb_populate_recordset(null::public.plan_assignments_v2,v_target.snapshot->'assignments');
  insert into public.plan_assignment_duties_v2(assignment_id,duty_id)
  select assignment_id,duty_id
  from jsonb_populate_recordset(null::public.plan_assignment_duties_v2,v_target.snapshot->'duties');
  insert into public.plan_issues_v2(
    id,variant_id,shift_id,slot_key,issue_code,severity,role_id,duty_id,
    required_count,assigned_count,message,metadata,created_at
  ) overriding system value
  select id,variant_id,shift_id,slot_key,issue_code,severity,role_id,duty_id,
    required_count,assigned_count,message,metadata,created_at
  from jsonb_populate_recordset(null::public.plan_issues_v2,v_target.snapshot->'issues');

  v_result:=solver_private.refresh_leader_variant_uat_v1(
    p_variant_id,v_actor,
    case when p_direction='UNDO' then 'Cofnięcie operacji' else 'Ponowienie operacji' end
  );
  update solver_private.leader_variant_history_cursor_v2
  set current_seq=v_target.seq,updated_at=now(),updated_by=v_actor
  where variant_id=p_variant_id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'plan_variant_v2',p_variant_id::text,'LEADER_HISTORY_'||p_direction,
    jsonb_build_object('historySeq',v_target.seq,'historyRevision',v_target.revision));
  return v_result||jsonb_build_object('historySeq',v_target.seq,'direction',p_direction);
end;
$$;


ALTER FUNCTION "public"."optimizer_leader_history_move_uat_v1"("p_variant_id" "uuid", "p_direction" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_leader_history_move_uat_v1"("p_variant_id" "uuid", "p_direction" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_leader_history_move_uat_v1"("p_variant_id" "uuid", "p_direction" "text") IS 'B4F-100: restores exact issue identities for undo/redo using OVERRIDING SYSTEM VALUE.';


--
-- Name: optimizer_leader_history_status_uat_v1("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_history_status_uat_v1"("p_variant_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_cursor bigint;
begin
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then
    raise exception 'LEADER_VARIANT_NOT_EDITABLE';
  end if;
  select current_seq into v_cursor from solver_private.leader_variant_history_cursor_v2
    where variant_id=p_variant_id;
  return jsonb_build_object(
    'canUndo',exists(select 1 from solver_private.leader_variant_history_v2 where variant_id=p_variant_id and seq<v_cursor),
    'canRedo',exists(select 1 from solver_private.leader_variant_history_v2 where variant_id=p_variant_id and seq>v_cursor),
    'entries',coalesce((select jsonb_agg(jsonb_build_object('seq',h.seq,'revision',h.revision,
      'label',h.label,'createdAt',h.created_at,'current',h.seq=v_cursor,
      'isCheckpoint',h.is_checkpoint,'checkpointName',h.checkpoint_name) order by h.seq desc)
      from solver_private.leader_variant_history_v2 h where h.variant_id=p_variant_id),'[]'::jsonb)
  );
end;
$$;


ALTER FUNCTION "public"."optimizer_leader_history_status_uat_v1"("p_variant_id" "uuid") OWNER TO "postgres";

--
-- Name: optimizer_leader_refill_apply_uat_v1("uuid", "uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_refill_apply_uat_v1"("p_leader_variant_id" "uuid", "p_source_variant_id" "uuid", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid();v_reason text:=trim(coalesce(p_reason,''));
  v_leader public.plan_variants_v2%rowtype;v_source public.plan_variants_v2%rowtype;
  v_source_snapshot jsonb;v_expected_revision integer;v_added integer:=0;v_result jsonb;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if length(v_reason)<3 then raise exception 'EDIT_REASON_REQUIRED'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_leader_variant_id) then raise exception 'LEADER_VARIANT_NOT_EDITABLE'; end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-edit:'||p_leader_variant_id::text,0));
  select * into v_leader from public.plan_variants_v2 where id=p_leader_variant_id for update;
  select * into v_source from public.plan_variants_v2 where id=p_source_variant_id
    and variant_kind='GENERATED' and status in ('READY','SELECTED') and hard_violations=0;
  if v_source.id is null then raise exception 'LEADER_REFILL_SOURCE_INVALID'; end if;
  select snapshot into v_source_snapshot from solver_private.optimization_snapshots_v2 where run_id=v_source.run_id;
  if v_source_snapshot->'leaderStudioRefill'->>'variantId' is distinct from p_leader_variant_id::text then
    raise exception 'LEADER_REFILL_SOURCE_MISMATCH';
  end if;
  v_expected_revision:=(v_source_snapshot->'leaderStudioRefill'->>'revision')::integer;
  if v_leader.revision<>v_expected_revision then raise exception 'LEADER_REFILL_DRAFT_CHANGED'; end if;
  insert into public.plan_assignments_v2(id,variant_id,shift_id,slot_key,employee_id,role_id,locked,explanation,created_at)
  select public.matrix_v2_stable_uuid('LEADER_REFILL:'||p_leader_variant_id::text||':'||source.id::text),
    p_leader_variant_id,issue.shift_id,source.slot_key,source.employee_id,source.role_id,false,
    jsonb_build_object('edited',true,'editedBy',v_actor,'editedAt',now(),'reason',v_reason,
      'refillSourceVariantId',p_source_variant_id,'refillSourceAssignmentId',source.id),now()
  from public.plan_assignments_v2 source
  join public.plan_issues_v2 issue on issue.variant_id=p_leader_variant_id
    and issue.issue_code='UNFILLED_SLOT' and issue.slot_key=source.slot_key
  where source.variant_id=p_source_variant_id on conflict do nothing;
  get diagnostics v_added=row_count;
  insert into public.plan_assignment_duties_v2(assignment_id,duty_id)
  select public.matrix_v2_stable_uuid('LEADER_REFILL:'||p_leader_variant_id::text||':'||source.id::text),duty.duty_id
  from public.plan_assignments_v2 source join public.plan_assignment_duties_v2 duty on duty.assignment_id=source.id
  join public.plan_issues_v2 issue on issue.variant_id=p_leader_variant_id
    and issue.issue_code='UNFILLED_SLOT' and issue.slot_key=source.slot_key
  where source.variant_id=p_source_variant_id on conflict do nothing;
  delete from public.plan_issues_v2 issue where issue.variant_id=p_leader_variant_id
    and issue.issue_code='UNFILLED_SLOT' and exists(select 1 from public.plan_assignments_v2 assignment
      where assignment.variant_id=p_leader_variant_id and assignment.slot_key=issue.slot_key);
  v_result:=solver_private.refresh_leader_variant_uat_v1(p_leader_variant_id,v_actor,v_reason);
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'plan_variant_v2',p_leader_variant_id::text,'APPLY_LEADER_REFILL',jsonb_build_object(
    'sourceVariantId',p_source_variant_id,'sourceRunId',v_source.run_id,'addedAssignments',v_added,'reason',v_reason));
  return v_result||jsonb_build_object('addedAssignments',v_added,'sourceVariantId',p_source_variant_id);
end;$$;


ALTER FUNCTION "public"."optimizer_leader_refill_apply_uat_v1"("p_leader_variant_id" "uuid", "p_source_variant_id" "uuid", "p_reason" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_leader_refill_apply_uat_v1"("p_leader_variant_id" "uuid", "p_source_variant_id" "uuid", "p_reason" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_leader_refill_apply_uat_v1"("p_leader_variant_id" "uuid", "p_source_variant_id" "uuid", "p_reason" "text") IS 'B4F-100: atomically applies only newly filled vacancies when the leader draft revision is unchanged.';


--
-- Name: optimizer_leader_refill_request_uat_v1("uuid", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_refill_request_uat_v1"("p_variant_id" "uuid", "p_reason" "text", "p_idempotency_key" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid();v_reason text:=trim(coalesce(p_reason,''));
  v_variant public.plan_variants_v2%rowtype;v_run public.optimization_runs_v2%rowtype;
  v_requested jsonb;v_refill_run_id uuid;v_snapshot jsonb;v_locked jsonb;v_hash text;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if length(v_reason)<3 then raise exception 'EDIT_REASON_REQUIRED'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then
    raise exception 'LEADER_VARIANT_NOT_EDITABLE';
  end if;
  select * into v_variant from public.plan_variants_v2 where id=p_variant_id for update;
  if v_variant.id is null then raise exception 'LEADER_VARIANT_NOT_FOUND'; end if;
  if v_variant.leader_workflow_status<>'DRAFT' then raise exception 'LEADER_REFILL_DRAFT_REQUIRED'; end if;
  select * into v_run from public.optimization_runs_v2 where id=v_variant.run_id;
  if v_run.id is null then raise exception 'LEADER_REFILL_BASE_RUN_NOT_FOUND'; end if;

  v_requested:=public.optimizer_request_v2(v_run.month,v_run.scenario_id,v_run.scope_type,
    v_run.scope_role_id,left('Uzupełnienie wakatów • '||v_variant.name,200),p_idempotency_key);
  v_refill_run_id:=coalesce(
    nullif(v_requested->>'runId',''),
    nullif(v_requested#>>'{run,id}','')
  )::uuid;
  if v_refill_run_id is null then raise exception 'RUN_ID_MISSING'; end if;

  select snapshot into v_snapshot from solver_private.optimization_snapshots_v2
    where run_id=v_refill_run_id for update;
  if v_snapshot is null then raise exception 'SNAPSHOT_NOT_FOUND'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('slotId',assignment.slot_key,
    'employeeId',assignment.employee_id) order by assignment.slot_key),'[]'::jsonb)
  into v_locked from public.plan_assignments_v2 assignment where assignment.variant_id=p_variant_id;
  v_snapshot:=jsonb_set(v_snapshot,'{lockedAssignments}',v_locked,true);
  v_snapshot:=jsonb_set(v_snapshot,'{baselineAssignments}',v_locked,true);
  v_snapshot:=jsonb_set(v_snapshot,'{leaderStudioRefill}',jsonb_build_object(
    'variantId',p_variant_id,'revision',v_variant.revision,'requestedBy',v_actor,
    'requestedAt',now(),'mode','FILL_REMAINING','reason',v_reason),true);
  v_hash:=encode(extensions.digest(convert_to(
    solver_private.canonical_json_v2(v_snapshot),'UTF8'
  ),'sha256'),'hex');
  update solver_private.optimization_snapshots_v2 set snapshot=v_snapshot,snapshot_hash=v_hash
    where run_id=v_refill_run_id;
  -- Deliberately do not replace optimization_runs_v2.snapshot_hash.  It is
  -- the base-input hash used by solver_finalize_v2 for stale-input detection.
  update public.optimization_run_strategies_v2 set metrics=coalesce(metrics,'{}'::jsonb)||
    jsonb_build_object('leaderRefillVariantId',p_variant_id,
      'leaderRefillRevision',v_variant.revision)
    where run_id=v_refill_run_id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'plan_variant_v2',p_variant_id::text,'REQUEST_LEADER_REFILL',jsonb_build_object(
    'runId',v_refill_run_id,'revision',v_variant.revision,
    'lockedAssignments',jsonb_array_length(v_locked),'reason',v_reason));
  return v_requested||jsonb_build_object(
    'runId',v_refill_run_id,'leaderVariantId',p_variant_id,'leaderRevision',v_variant.revision
  );
end;$$;


ALTER FUNCTION "public"."optimizer_leader_refill_request_uat_v1"("p_variant_id" "uuid", "p_reason" "text", "p_idempotency_key" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_leader_refill_request_uat_v1"("p_variant_id" "uuid", "p_reason" "text", "p_idempotency_key" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_leader_refill_request_uat_v1"("p_variant_id" "uuid", "p_reason" "text", "p_idempotency_key" "text") IS 'B4F-100: queues fill-only optimization while keeping stale-input validation bound to the published configuration hash.';


--
-- Name: optimizer_leader_reoptimization_apply_uat_v1("uuid", "uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_reoptimization_apply_uat_v1"("p_leader_variant_id" "uuid", "p_source_variant_id" "uuid", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid();v_reason text:=trim(coalesce(p_reason,''));
  v_leader public.plan_variants_v2%rowtype;v_source public.plan_variants_v2%rowtype;
  v_source_snapshot jsonb;v_expected_revision integer;v_mode text;
  v_locked_count integer:=0;v_expected_replaced_count integer:=0;
  v_replaced_count integer:=0;v_result jsonb;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if length(v_reason)<3 then raise exception 'EDIT_REASON_REQUIRED'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_leader_variant_id) then raise exception 'LEADER_VARIANT_NOT_EDITABLE'; end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-edit:'||p_leader_variant_id::text,0));
  select * into v_leader from public.plan_variants_v2 where id=p_leader_variant_id for update;
  if v_leader.leader_workflow_status<>'DRAFT' then raise exception 'LEADER_OPTIMIZATION_DRAFT_REQUIRED'; end if;
  select * into v_source from public.plan_variants_v2 where id=p_source_variant_id
    and variant_kind='GENERATED' and status in ('READY','SELECTED') and hard_violations=0;
  if v_source.id is null then raise exception 'LEADER_OPTIMIZATION_SOURCE_INVALID'; end if;
  select snapshot into v_source_snapshot from solver_private.optimization_snapshots_v2 where run_id=v_source.run_id;
  if v_source_snapshot->'leaderStudioOptimization'->>'variantId' is distinct from p_leader_variant_id::text then
    raise exception 'LEADER_OPTIMIZATION_SOURCE_MISMATCH';
  end if;
  v_expected_revision:=(v_source_snapshot->'leaderStudioOptimization'->>'revision')::integer;
  v_mode:=v_source_snapshot->'leaderStudioOptimization'->>'mode';
  if v_leader.revision<>v_expected_revision then raise exception 'LEADER_OPTIMIZATION_DRAFT_CHANGED'; end if;

  select count(*) into v_locked_count from public.plan_assignments_v2 assignment
  where assignment.variant_id=p_leader_variant_id and assignment.locked;
  if exists(
    select 1 from public.plan_assignments_v2 locked_assignment
    where locked_assignment.variant_id=p_leader_variant_id and locked_assignment.locked
      and not exists(select 1 from public.plan_assignments_v2 source_assignment
        where source_assignment.variant_id=p_source_variant_id
          and source_assignment.slot_key=locked_assignment.slot_key
          and source_assignment.employee_id=locked_assignment.employee_id)
  ) then raise exception 'LEADER_OPTIMIZATION_LOCK_NOT_PRESERVED'; end if;
  if exists(
    select 1 from public.plan_assignments_v2 source_assignment
    join public.plan_shifts_v2 source_shift on source_shift.id=source_assignment.shift_id
    where source_assignment.variant_id=p_source_variant_id
      and not exists(select 1 from public.plan_shifts_v2 leader_shift
        where leader_shift.variant_id=p_leader_variant_id
          and leader_shift.slot_group_key=source_shift.slot_group_key)
  ) or exists(
    select 1 from public.plan_issues_v2 source_issue
    join public.plan_shifts_v2 source_shift on source_shift.id=source_issue.shift_id
    where source_issue.variant_id=p_source_variant_id
      and not exists(select 1 from public.plan_shifts_v2 leader_shift
        where leader_shift.variant_id=p_leader_variant_id
          and leader_shift.slot_group_key=source_shift.slot_group_key)
  ) then raise exception 'LEADER_OPTIMIZATION_SHIFT_MAPPING_MISSING'; end if;

  select count(*) into v_expected_replaced_count
  from public.plan_assignments_v2 source_assignment
  where source_assignment.variant_id=p_source_variant_id
    and not exists(select 1 from public.plan_assignments_v2 locked_assignment
      where locked_assignment.variant_id=p_leader_variant_id and locked_assignment.locked
        and locked_assignment.slot_key=source_assignment.slot_key);

  delete from public.plan_assignments_v2 assignment
  where assignment.variant_id=p_leader_variant_id and not assignment.locked;
  delete from public.plan_issues_v2 where variant_id=p_leader_variant_id;

  insert into public.plan_assignments_v2(
    id,variant_id,shift_id,slot_key,employee_id,role_id,locked,explanation,created_at
  )
  select public.matrix_v2_stable_uuid('LEADER_REOPT:'||p_leader_variant_id::text||':'||source_assignment.id::text),
    p_leader_variant_id,leader_shift.id,source_assignment.slot_key,source_assignment.employee_id,
    source_assignment.role_id,false,jsonb_build_object('edited',true,'editedBy',v_actor,'editedAt',now(),
      'reason',v_reason,'optimizationMode',v_mode,'optimizationSourceVariantId',p_source_variant_id),now()
  from public.plan_assignments_v2 source_assignment
  join public.plan_shifts_v2 source_shift on source_shift.id=source_assignment.shift_id
  join public.plan_shifts_v2 leader_shift on leader_shift.variant_id=p_leader_variant_id
    and leader_shift.slot_group_key=source_shift.slot_group_key
  where source_assignment.variant_id=p_source_variant_id
    and not exists(select 1 from public.plan_assignments_v2 locked_assignment
      where locked_assignment.variant_id=p_leader_variant_id and locked_assignment.locked
        and locked_assignment.slot_key=source_assignment.slot_key)
  on conflict do nothing;
  get diagnostics v_replaced_count=row_count;
  if v_replaced_count<>v_expected_replaced_count then
    raise exception 'LEADER_OPTIMIZATION_ASSIGNMENT_COPY_INCOMPLETE';
  end if;

  insert into public.plan_assignment_duties_v2(assignment_id,duty_id)
  select public.matrix_v2_stable_uuid('LEADER_REOPT:'||p_leader_variant_id::text||':'||source_assignment.id::text),
    duty.duty_id
  from public.plan_assignments_v2 source_assignment
  join public.plan_assignment_duties_v2 duty on duty.assignment_id=source_assignment.id
  where source_assignment.variant_id=p_source_variant_id
    and exists(select 1 from public.plan_assignments_v2 leader_assignment
      where leader_assignment.id=public.matrix_v2_stable_uuid(
        'LEADER_REOPT:'||p_leader_variant_id::text||':'||source_assignment.id::text))
  on conflict do nothing;

  insert into public.plan_issues_v2(variant_id,shift_id,slot_key,issue_code,severity,role_id,duty_id,
    required_count,assigned_count,message,metadata,created_at)
  select p_leader_variant_id,leader_shift.id,source_issue.slot_key,source_issue.issue_code,
    source_issue.severity,source_issue.role_id,source_issue.duty_id,source_issue.required_count,
    source_issue.assigned_count,source_issue.message,coalesce(source_issue.metadata,'{}'::jsonb)||
      jsonb_build_object('optimizationMode',v_mode,'optimizationSourceVariantId',p_source_variant_id),now()
  from public.plan_issues_v2 source_issue
  left join public.plan_shifts_v2 source_shift on source_shift.id=source_issue.shift_id
  left join public.plan_shifts_v2 leader_shift on leader_shift.variant_id=p_leader_variant_id
    and leader_shift.slot_group_key=source_shift.slot_group_key
  where source_issue.variant_id=p_source_variant_id;

  v_result:=solver_private.refresh_leader_variant_uat_v1(p_leader_variant_id,v_actor,v_reason);
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'plan_variant_v2',p_leader_variant_id::text,'APPLY_LEADER_OPTIMIZATION',jsonb_build_object(
    'sourceVariantId',p_source_variant_id,'sourceRunId',v_source.run_id,'mode',v_mode,
    'lockedAssignments',v_locked_count,'replacedAssignments',v_replaced_count,'reason',v_reason));
  return v_result||jsonb_build_object('sourceVariantId',p_source_variant_id,'mode',v_mode,
    'lockedAssignments',v_locked_count,'replacedAssignments',v_replaced_count);
end;$$;


ALTER FUNCTION "public"."optimizer_leader_reoptimization_apply_uat_v1"("p_leader_variant_id" "uuid", "p_source_variant_id" "uuid", "p_reason" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_leader_reoptimization_apply_uat_v1"("p_leader_variant_id" "uuid", "p_source_variant_id" "uuid", "p_reason" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_leader_reoptimization_apply_uat_v1"("p_leader_variant_id" "uuid", "p_source_variant_id" "uuid", "p_reason" "text") IS 'B4F-100: atomically replaces only unlocked leader assignments when the draft revision is unchanged.';


--
-- Name: optimizer_leader_reoptimization_request_uat_v1("uuid", "text", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_reoptimization_request_uat_v1"("p_variant_id" "uuid", "p_mode" "text", "p_reason" "text", "p_idempotency_key" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid();v_mode text:=upper(trim(coalesce(p_mode,'')));
  v_reason text:=trim(coalesce(p_reason,''));v_variant public.plan_variants_v2%rowtype;
  v_run public.optimization_runs_v2%rowtype;v_requested jsonb;v_new_run_id uuid;
  v_snapshot jsonb;v_locked jsonb;v_baseline jsonb;v_hash text;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if v_mode not in ('COST','FAIRNESS','PROPOSE_ONLY') then raise exception 'LEADER_OPTIMIZATION_MODE_INVALID'; end if;
  if length(v_reason)<3 then raise exception 'EDIT_REASON_REQUIRED'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then raise exception 'LEADER_VARIANT_NOT_EDITABLE'; end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-edit:'||p_variant_id::text,0));
  select * into v_variant from public.plan_variants_v2 where id=p_variant_id for update;
  if v_variant.id is null then raise exception 'LEADER_VARIANT_NOT_FOUND'; end if;
  if v_variant.leader_workflow_status<>'DRAFT' then raise exception 'LEADER_OPTIMIZATION_DRAFT_REQUIRED'; end if;
  select * into v_run from public.optimization_runs_v2 where id=v_variant.run_id;
  if v_run.id is null then raise exception 'LEADER_OPTIMIZATION_BASE_RUN_NOT_FOUND'; end if;

  v_requested:=public.optimizer_request_v2(v_run.month,v_run.scenario_id,v_run.scope_type,
    v_run.scope_role_id,left(case v_mode when 'COST' then 'Optymalizacja kosztu • '
      when 'FAIRNESS' then 'Optymalizacja sprawiedliwości • ' else 'Propozycje zmian • ' end||v_variant.name,200),
    p_idempotency_key);
  v_new_run_id:=coalesce(nullif(v_requested->>'runId',''),nullif(v_requested#>>'{run,id}',''))::uuid;
  if v_new_run_id is null then raise exception 'RUN_ID_MISSING'; end if;
  select snapshot into v_snapshot from solver_private.optimization_snapshots_v2
    where run_id=v_new_run_id for update;
  if v_snapshot is null then raise exception 'SNAPSHOT_NOT_FOUND'; end if;

  select coalesce(jsonb_agg(jsonb_build_object('slotId',assignment.slot_key,
    'employeeId',assignment.employee_id) order by assignment.slot_key),'[]'::jsonb)
  into v_locked from public.plan_assignments_v2 assignment
  where assignment.variant_id=p_variant_id and assignment.locked;
  select coalesce(jsonb_agg(jsonb_build_object('slotId',assignment.slot_key,
    'employeeId',assignment.employee_id) order by assignment.slot_key),'[]'::jsonb)
  into v_baseline from public.plan_assignments_v2 assignment
  where assignment.variant_id=p_variant_id;

  v_snapshot:=jsonb_set(v_snapshot,'{lockedAssignments}',v_locked,true);
  v_snapshot:=jsonb_set(v_snapshot,'{baselineAssignments}',v_baseline,true);
  v_snapshot:=jsonb_set(v_snapshot,'{leaderStudioOptimization}',jsonb_build_object(
    'variantId',p_variant_id,'revision',v_variant.revision,'requestedBy',v_actor,
    'requestedAt',now(),'mode',v_mode,'reason',v_reason),true);
  v_hash:=encode(extensions.digest(convert_to(
    solver_private.canonical_json_v2(v_snapshot),'UTF8'
  ),'sha256'),'hex');
  update solver_private.optimization_snapshots_v2 set snapshot=v_snapshot,snapshot_hash=v_hash
    where run_id=v_new_run_id;
  -- Keep optimization_runs_v2.snapshot_hash on the published input.  The
  -- augmented hash remains on optimization_snapshots_v2 and every saved plan.
  update public.optimization_run_strategies_v2 set metrics=coalesce(metrics,'{}'::jsonb)||
    jsonb_build_object('leaderOptimizationVariantId',p_variant_id,
      'leaderOptimizationRevision',v_variant.revision,'leaderOptimizationMode',v_mode)
    where run_id=v_new_run_id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'plan_variant_v2',p_variant_id::text,'REQUEST_LEADER_OPTIMIZATION',jsonb_build_object(
    'runId',v_new_run_id,'revision',v_variant.revision,'mode',v_mode,
    'lockedAssignments',jsonb_array_length(v_locked),'baselineAssignments',jsonb_array_length(v_baseline),
    'reason',v_reason));
  return v_requested||jsonb_build_object('runId',v_new_run_id,'leaderVariantId',p_variant_id,
    'leaderRevision',v_variant.revision,'mode',v_mode,'lockedAssignments',jsonb_array_length(v_locked));
end;$$;


ALTER FUNCTION "public"."optimizer_leader_reoptimization_request_uat_v1"("p_variant_id" "uuid", "p_mode" "text", "p_reason" "text", "p_idempotency_key" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_leader_reoptimization_request_uat_v1"("p_variant_id" "uuid", "p_mode" "text", "p_reason" "text", "p_idempotency_key" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_leader_reoptimization_request_uat_v1"("p_variant_id" "uuid", "p_mode" "text", "p_reason" "text", "p_idempotency_key" "text") IS 'B4F-100: queues leader re-optimization while keeping stale-input validation bound to the published configuration hash.';


--
-- Name: optimizer_leader_variant_for_run_uat_v1("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_variant_for_run_uat_v1"("p_run_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_variant public.plan_variants_v2%rowtype;
begin
  if not solver_private.can_access_run_v2(p_run_id) then raise exception 'RUN_NOT_FOUND'; end if;
  select * into v_variant from public.plan_variants_v2
    where run_id=p_run_id and variant_kind='LEADER_COPY'
      and status in ('READY','SELECTED','PUBLISHED')
    order by created_at desc limit 1;
  if v_variant.id is null then return jsonb_build_object('variant',null); end if;
  return jsonb_build_object('variant',jsonb_build_object(
    'id',v_variant.id,'sourceVariantId',v_variant.source_variant_id,
    'name',v_variant.name,'status',v_variant.status,'revision',v_variant.revision,
    'assignmentCount',v_variant.assignment_count,'unfilledCount',v_variant.unfilled_count,
    'lastEditedAt',v_variant.last_edited_at
  ));
end;
$$;


ALTER FUNCTION "public"."optimizer_leader_variant_for_run_uat_v1"("p_run_id" "uuid") OWNER TO "postgres";

--
-- Name: optimizer_leader_variant_workspace_uat_v1("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_variant_workspace_uat_v1"("p_variant_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_variant public.plan_variants_v2%rowtype; v_context jsonb; v_workspace jsonb; v_visibility text;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select variant.* into v_variant from public.plan_variants_v2 variant
  where variant.id=p_variant_id and variant.variant_kind='LEADER_COPY';
  if v_variant.id is null or not solver_private.can_access_run_v2(v_variant.run_id) then raise exception 'LEADER_VARIANT_NOT_FOUND'; end if;
  select jsonb_build_object('type','LEADER_VARIANT','runId',run.id,'engine',run.request_engine,
    'month',run.month,'name',v_variant.name,'scenario',jsonb_build_object('id',scenario.id,'name',scenario.name),
    'matrixVersionId',run.matrix_version_id,'variantKind','LEADER_COPY','sourceVariantId',v_variant.source_variant_id,
    'revision',v_variant.revision,'lastEditedAt',v_variant.last_edited_at)
  into v_context from public.optimization_runs_v2 run
  join public.matrix_scenarios_v2 scenario on scenario.id=run.scenario_id where run.id=v_variant.run_id;
  v_visibility:=public.application_finance_visibility_current_uat_v1();
  v_workspace:=solver_private.variant_set_workspace_v2(array[p_variant_id],v_context,v_visibility<>'NONE');
  v_workspace:=solver_private.alpha16_enrich_workspace_issues_v2(v_workspace,array[p_variant_id]);
  return solver_private.redact_workspace_finance_uat_v1(v_workspace,v_visibility);
end;
$$;


ALTER FUNCTION "public"."optimizer_leader_variant_workspace_uat_v1"("p_variant_id" "uuid") OWNER TO "postgres";

--
-- Name: optimizer_leader_workflow_status_uat_v1("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_workflow_status_uat_v1"("p_variant_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_variant public.plan_variants_v2%rowtype;
begin
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id)
    and not exists(select 1 from public.plan_variants_v2 v join public.optimization_runs_v2 r on r.id=v.run_id
      where v.id=p_variant_id and r.requested_by=auth.uid()) then raise exception 'LEADER_VARIANT_FORBIDDEN'; end if;
  select * into v_variant from public.plan_variants_v2 where id=p_variant_id and variant_kind='LEADER_COPY';
  if v_variant.id is null then raise exception 'LEADER_VARIANT_NOT_FOUND'; end if;
  return jsonb_build_object('variantId',v_variant.id,'status',case when v_variant.status='PUBLISHED' then 'PUBLISHED' else v_variant.leader_workflow_status end,
    'published',v_variant.status='PUBLISHED');
end;$$;


ALTER FUNCTION "public"."optimizer_leader_workflow_status_uat_v1"("p_variant_id" "uuid") OWNER TO "postgres";

--
-- Name: optimizer_leader_workflow_transition_uat_v1("uuid", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_leader_workflow_transition_uat_v1"("p_variant_id" "uuid", "p_target_status" "text", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_actor uuid:=auth.uid();v_variant public.plan_variants_v2%rowtype;
  v_target text:=upper(trim(coalesce(p_target_status,'')));v_check jsonb;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if length(trim(coalesce(p_reason,'')))<3 then raise exception 'EDIT_REASON_REQUIRED'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then raise exception 'LEADER_VARIANT_FORBIDDEN'; end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-edit:'||p_variant_id::text,0));
  select * into v_variant from public.plan_variants_v2 where id=p_variant_id and variant_kind='LEADER_COPY' for update;
  if v_variant.id is null then raise exception 'LEADER_VARIANT_NOT_FOUND'; end if;
  if v_variant.status='PUBLISHED' or v_variant.leader_workflow_status='PUBLISHED' then raise exception 'LEADER_VARIANT_NOT_EDITABLE'; end if;
  if not ((v_variant.leader_workflow_status='DRAFT' and v_target='REVIEW') or
    (v_variant.leader_workflow_status='REVIEW' and v_target in ('DRAFT','LEADER_APPROVED')) or
    (v_variant.leader_workflow_status='LEADER_APPROVED' and v_target in ('DRAFT','READY_TO_MERGE')) or
    (v_variant.leader_workflow_status='READY_TO_MERGE' and v_target='DRAFT')) then
    raise exception 'LEADER_WORKFLOW_TRANSITION_INVALID';
  end if;
  if v_target='READY_TO_MERGE' and not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'LEADER_READY_TO_MERGE_FORBIDDEN';
  end if;
  if v_target in ('REVIEW','LEADER_APPROVED','READY_TO_MERGE') then
    v_check:=public.optimizer_leader_draft_validate_uat_v1(p_variant_id);
    if not coalesce((v_check->>'valid')::boolean,false) then
      raise exception 'VARIANT_HAS_HARD_VIOLATIONS';
    end if;
  end if;
  update public.plan_variants_v2 set leader_workflow_status=v_target,last_edited_at=now(),last_edited_by=v_actor
    where id=p_variant_id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,old_data,new_data)
  values(v_actor,'plan_variant_v2',p_variant_id::text,'LEADER_WORKFLOW_TRANSITION',
    jsonb_build_object('status',v_variant.leader_workflow_status),
    jsonb_build_object('status',v_target,'reason',trim(p_reason),'validation',v_check));
  return jsonb_build_object('variantId',p_variant_id,'status',v_target,'reason',trim(p_reason),'validation',v_check);
end;$$;


ALTER FUNCTION "public"."optimizer_leader_workflow_transition_uat_v1"("p_variant_id" "uuid", "p_target_status" "text", "p_reason" "text") OWNER TO "postgres";

--
-- Name: optimizer_materialize_candidate_v3("uuid", "text", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_materialize_candidate_v3"("p_run_id" "uuid", "p_name" "text", "p_candidate" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  r public.optimization_runs;
  a jsonb;
  v_unfilled_slot jsonb;
  v_plan_id uuid;
  v_shift_id uuid;
  v_plan_version integer;
  v_start_at timestamptz;
  v_end_at timestamptz;
  v_local_start time;
  v_local_end time;
  v_shift_start_min integer;
  v_shift_end_min integer;
  v_total_cost numeric:=0;
  v_assignment_count integer:=0;
  v_unfilled integer:=0;
  v_alert_groups integer:=0;
  v_rank integer:=coalesce((p_candidate->>'rank')::integer,1);
  emp public.employees;
  loc public.locations;
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  select * into r from public.optimization_runs
    where id=p_run_id and requested_by=auth.uid() for update;
  if r.id is null or r.status<>'RUNNING' then
    raise exception 'OPTIMIZATION_RUN_NOT_WRITABLE';
  end if;
  if coalesce((p_candidate->>'hardViolations')::integer,0)<>0 then
    raise exception 'CANDIDATE_HAS_HARD_VIOLATIONS';
  end if;

  select coalesce(max(version),0)+1 into v_plan_version
  from public.plans where month=r.month;
  insert into public.plans(
    month,name,scenario_code,optimization_mode,staffing_level,status,version,
    score,total_cost,generated_at,created_by
  ) values(
    r.month,
    coalesce(nullif(trim(p_name),''),'Plan optymalny '||to_char(r.month,'YYYY-MM'))||' · Wariant '||v_rank,
    r.scenario_code,
    (select code from public.optimizer_profiles where id=r.profile_id),
    'OPTIMAL','GENERATING',v_plan_version,(p_candidate->>'score')::numeric,0,now(),auth.uid()
  ) returning id into v_plan_id;

  for a in select value from jsonb_array_elements(coalesce(p_candidate->'assignments','[]'::jsonb)) loop
    select * into emp from public.employees
      where id=(a->>'employeeId')::uuid and active and archived_at is null;
    select * into loc from public.locations
      where id=(a->>'locationId')::uuid and active;
    if emp.id is null or loc.id is null then
      raise exception 'INVALID_EMPLOYEE_OR_LOCATION';
    end if;

    v_start_at:=(a->>'startsAt')::timestamptz;
    v_end_at:=(a->>'endsAt')::timestamptz;
    v_local_start:=coalesce(nullif(a->>'localStart','')::time,v_start_at::time);
    v_local_end:=coalesce(nullif(a->>'localEnd','')::time,v_end_at::time);
    v_shift_start_min:=extract(hour from v_local_start)::integer*60
      +extract(minute from v_local_start)::integer;
    v_shift_end_min:=extract(hour from v_local_end)::integer*60
      +extract(minute from v_local_end)::integer
      +case when v_local_end<=v_local_start then 1440 else 0 end;
    if v_end_at<=v_start_at or not exists(
      select 1 from public.employee_locations el
      where el.employee_id=emp.id and el.location_id=loc.id
        and (el.standard_allowed or el.overtime_allowed)
    ) then raise exception 'HARD_CONSTRAINT_LOCATION_OR_TIME'; end if;

    if (emp.employment_start is not null and (a->>'date')::date<emp.employment_start)
      or (emp.employment_end is not null and (a->>'date')::date>emp.employment_end)
      or (emp.no_weekends and extract(isodow from (a->>'date')::date) in (6,7))
      or (emp.only_morning and v_local_start>=time '15:00')
      or (emp.only_evening and v_local_start<time '14:00') then
      raise exception 'HARD_CONSTRAINT_EMPLOYMENT_PATTERN';
    end if;

    if not (emp.primary_role::text=a->>'role' or exists(
      select 1 from public.matrix_employee_roles mer
      join public.matrix_roles mr on mr.id=mer.role_id
      where mer.matrix_version_id=r.matrix_version_id and mer.employee_id=emp.id
        and mr.code=a->>'role'
    )) then raise exception 'HARD_CONSTRAINT_ROLE'; end if;

    if nullif(a->>'function','') is not null and not exists(
      select 1 from public.employee_capabilities ec
      where ec.employee_id=emp.id and ec.active and ec.capability=a->>'function'
        and (ec.scope_role is null or ec.scope_role::text=a->>'role')
        and (ec.scope_location is null or ec.scope_location::text=loc.code::text)
    ) then raise exception 'HARD_CONSTRAINT_CAPABILITY'; end if;

    if exists(
      select 1 from public.employee_availability av
      where av.employee_id=emp.id and av.work_date=(a->>'date')::date
        and (not av.available
          or (av.earliest_start is not null and v_shift_start_min<
            extract(hour from av.earliest_start)::integer*60
              +extract(minute from av.earliest_start)::integer)
          or (av.latest_end is not null and v_shift_end_min>
            extract(hour from av.latest_end)::integer*60
              +extract(minute from av.latest_end)::integer
              +case when av.earliest_start is not null and av.latest_end<=av.earliest_start
                then 1440 else 0 end))
    ) or exists(
      select 1 from public.employee_preferences ep
      where ep.employee_id=emp.id and ep.status='ACTIVE'
        and ep.preference_type in ('UNAVAILABLE','LEAVE','SICKNESS')
        and ep.valid_from<=(a->>'date')::date and ep.valid_to>=(a->>'date')::date
    ) then raise exception 'HARD_CONSTRAINT_AVAILABILITY'; end if;

    if exists(
      select 1 from public.assignments ax join public.shifts sx on sx.id=ax.shift_id
      where sx.plan_id=v_plan_id and ax.employee_id=emp.id
        and tstzrange(sx.starts_at,sx.ends_at,'[)') && tstzrange(v_start_at,v_end_at,'[)')
    ) then raise exception 'HARD_CONSTRAINT_OVERLAP'; end if;

    if exists(
      select 1 from public.assignments ax join public.shifts sx on sx.id=ax.shift_id
      where sx.plan_id=v_plan_id and ax.employee_id=emp.id
        and tstzrange(
          sx.starts_at-coalesce(emp.minimum_rest_minutes,660)*interval '1 minute',
          sx.ends_at+coalesce(emp.minimum_rest_minutes,660)*interval '1 minute','[)'
        ) && tstzrange(v_start_at,v_end_at,'[)')
    ) then raise exception 'HARD_CONSTRAINT_REST'; end if;

    if coalesce((select sum(public.shift_minutes(sx.starts_at,sx.ends_at))
      from public.assignments ax join public.shifts sx on sx.id=ax.shift_id
      where sx.plan_id=v_plan_id and ax.employee_id=emp.id),0)
      +public.shift_minutes(v_start_at,v_end_at)>coalesce(emp.max_monthly_minutes,emp.monthly_nominal_minutes)
    then raise exception 'HARD_CONSTRAINT_MONTHLY_LIMIT'; end if;

    if coalesce((select sum(public.shift_minutes(sx.starts_at,sx.ends_at))
      from public.assignments ax join public.shifts sx on sx.id=ax.shift_id
      where sx.plan_id=v_plan_id and ax.employee_id=emp.id
        and date_trunc('week',sx.shift_date::timestamp)=date_trunc('week',(a->>'date')::date::timestamp)),0)
      +public.shift_minutes(v_start_at,v_end_at)>emp.max_weekly_minutes
    then raise exception 'HARD_CONSTRAINT_WEEKLY_LIMIT'; end if;

    if (select count(*) from public.assignments ax join public.shifts sx on sx.id=ax.shift_id
      where sx.plan_id=v_plan_id and ax.employee_id=emp.id and sx.shift_date=(a->>'date')::date)
      >=coalesce((r.input_payload#>>'{matrix,settings,maxShiftsPerDay}')::integer,7)
    then raise exception 'HARD_CONSTRAINT_DAILY_SHIFT_LIMIT'; end if;

    select s.id into v_shift_id from public.shifts s
    where s.plan_id=v_plan_id and s.location_id=loc.id
      and s.shift_date=(a->>'date')::date and s.shift_code=a->>'shiftCode';
    if v_shift_id is null then
      insert into public.shifts(plan_id,location_id,shift_date,shift_code,starts_at,ends_at,status)
      values(v_plan_id,loc.id,(a->>'date')::date,a->>'shiftCode',v_start_at,v_end_at,'PLANNED')
      returning id into v_shift_id;
    end if;

    insert into public.assignments(
      shift_id,employee_id,assigned_role,assigned_capability,cost,explanation
    ) values(
      v_shift_id,emp.id,(a->>'role')::public.employee_role,nullif(a->>'function',''),
      round(emp.hourly_rate*public.shift_minutes(v_start_at,v_end_at)/60,2),
      jsonb_build_object('engine','ALPHA_15_V3','runId',r.id,'slotId',a->>'slotId','variantRank',v_rank)
    );
    v_total_cost:=v_total_cost+round(emp.hourly_rate*public.shift_minutes(v_start_at,v_end_at)/60,2);
    v_assignment_count:=v_assignment_count+1;
  end loop;

  if exists(
    with work_days as (
      select distinct ax.employee_id,s.shift_date
      from public.assignments ax join public.shifts s on s.id=ax.shift_id
      where s.plan_id=v_plan_id
    ), islands as (
      select employee_id,shift_date,
        shift_date-(row_number() over(partition by employee_id order by shift_date))::integer grp
      from work_days
    ), streaks as (
      select employee_id,count(*) days from islands group by employee_id,grp
    )
    select 1 from streaks x join public.employees e on e.id=x.employee_id
    where x.days>e.max_consecutive_days
  ) then raise exception 'HARD_CONSTRAINT_CONSECUTIVE_DAYS'; end if;

  if exists(select 1 from public.monthly_budgets b
    where b.month=r.month and b.hard_limit and b.amount>0 and v_total_cost>b.amount)
  then raise exception 'HARD_CONSTRAINT_BUDGET'; end if;

  for v_unfilled_slot in select value from jsonb_array_elements(coalesce(p_candidate->'unfilled','[]'::jsonb)) loop
    select s.id into v_shift_id from public.shifts s
    where s.plan_id=v_plan_id and s.location_id=(v_unfilled_slot->>'locationId')::uuid
      and s.shift_date=(v_unfilled_slot->>'date')::date and s.shift_code=v_unfilled_slot->>'shiftCode';
    if v_shift_id is null then
      insert into public.shifts(plan_id,location_id,shift_date,shift_code,starts_at,ends_at,status)
      values(v_plan_id,(v_unfilled_slot->>'locationId')::uuid,(v_unfilled_slot->>'date')::date,v_unfilled_slot->>'shiftCode',
        (v_unfilled_slot->>'startsAt')::timestamptz,(v_unfilled_slot->>'endsAt')::timestamptz,'PLANNED')
      returning id into v_shift_id;
    end if;
  end loop;

  insert into public.plan_issues(
    plan_id,shift_id,issue_type,severity,role,capability,required_count,assigned_count,message
  )
  select v_plan_id,s.id,
    case when nullif(x.function_code,'') is null then 'SHORTAGE' else 'CAPABILITY_MISSING' end,
    'CRITICAL',x.role_code::public.employee_role,nullif(x.function_code,''),x.missing,0,
    'Brak obsady: '||x.missing||' os. • '||x.role_code
      ||coalesce(' / '||nullif(x.function_code,''),'')||' • '||x.work_date||' • '||x.shift_code
  from (
    select missing_slot->>'date' work_date,missing_slot->>'shiftCode' shift_code,
      missing_slot->>'locationId' location_id,missing_slot->>'role' role_code,
      coalesce(missing_slot->>'fn','') function_code,count(*)::integer missing
    from jsonb_array_elements(coalesce(p_candidate->'unfilled','[]'::jsonb)) missing_slot
    group by 1,2,3,4,5
  ) x
  join public.shifts s on s.plan_id=v_plan_id and s.shift_date=x.work_date::date
    and s.shift_code=x.shift_code and s.location_id=x.location_id::uuid;

  select coalesce(sum(greatest(coalesce(required_count,1)-coalesce(assigned_count,0),0)),0)::integer,
         count(*)::integer
    into v_unfilled,v_alert_groups
  from public.plan_issues where plan_id=v_plan_id and resolved_at is null
    and issue_type in ('SHORTAGE','CAPABILITY_MISSING');

  update public.plans set status='READY',total_cost=v_total_cost,generated_at=now()
  where id=v_plan_id;
  return jsonb_build_object(
    'planId',v_plan_id,'rank',v_rank,'score',p_candidate->'score',
    'assignments',v_assignment_count,'unfilled',v_unfilled,
    'alertGroups',v_alert_groups,'totalCost',v_total_cost,
    'metrics',coalesce(p_candidate->'metrics','{}'::jsonb)
  );
end $$;


ALTER FUNCTION "public"."optimizer_materialize_candidate_v3"("p_run_id" "uuid", "p_name" "text", "p_candidate" "jsonb") OWNER TO "postgres";

--
-- Name: optimizer_materialize_candidate_v4("uuid", "text", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_materialize_candidate_v4"("p_run_id" "uuid", "p_name" "text", "p_candidate" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  r public.optimization_runs;
  v_plan_id uuid;
  v_plan_version integer;
  v_rank integer:=coalesce((p_candidate->>'rank')::integer,1);
  v_total_cost numeric:=0;
  v_assignment_count integer:=0;
  v_unfilled integer:=0;
  v_alert_groups integer:=0;
  v_invalid integer:=0;
  v_expected_slots integer:=coalesce((p_candidate#>>'{metrics,totalSlots}')::integer,-1);
  v_expected_unfilled integer:=coalesce((p_candidate#>>'{metrics,unfilled}')::integer,-1);
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  select * into r from public.optimization_runs
    where id=p_run_id and requested_by=auth.uid() for update;
  if r.id is null or r.status<>'RUNNING' then raise exception 'OPTIMIZATION_RUN_NOT_WRITABLE'; end if;
  if coalesce((p_candidate->>'hardViolations')::integer,0)<>0 then
    raise exception 'CANDIDATE_HAS_HARD_VIOLATIONS';
  end if;

  create temporary table alpha15_assignment_stage on commit drop as
  with raw as (
    select
      nullif(x->>'slotId','') slot_id,
      (x->>'employeeId')::uuid employee_id,
      (x->>'date')::date work_date,
      nullif(x->>'shiftCode','') shift_code,
      (x->>'startsAt')::timestamptz starts_at,
      (x->>'endsAt')::timestamptz ends_at,
      coalesce(nullif(x->>'localStart','')::time,(x->>'startsAt')::timestamptz::time) local_start,
      coalesce(nullif(x->>'localEnd','')::time,(x->>'endsAt')::timestamptz::time) local_end,
      (x->>'locationId')::uuid location_id,
      nullif(x->>'role','') role_code,
      nullif(x->>'function','') function_code
    from jsonb_array_elements(coalesce(p_candidate->'assignments','[]'::jsonb)) x
  )
  select raw.*,
    extract(hour from local_start)::integer*60+extract(minute from local_start)::integer start_min,
    extract(hour from local_end)::integer*60+extract(minute from local_end)::integer
      +case when local_end<=local_start then 1440 else 0 end end_min
  from raw;

  create temporary table alpha15_unfilled_stage on commit drop as
  select
    nullif(x->>'id','') slot_id,
    (x->>'date')::date work_date,
    nullif(x->>'shiftCode','') shift_code,
    (x->>'startsAt')::timestamptz starts_at,
    (x->>'endsAt')::timestamptz ends_at,
    (x->>'locationId')::uuid location_id,
    nullif(x->>'role','') role_code,
    nullif(x->>'fn','') function_code
  from jsonb_array_elements(coalesce(p_candidate->'unfilled','[]'::jsonb)) x;

  if v_expected_slots<0
    or (select count(*) from pg_temp.alpha15_assignment_stage)
      +(select count(*) from pg_temp.alpha15_unfilled_stage)<>v_expected_slots
    or (select count(*) from pg_temp.alpha15_unfilled_stage)<>v_expected_unfilled
    or (select count(*) from (
      select slot_id from pg_temp.alpha15_assignment_stage
      union all select slot_id from pg_temp.alpha15_unfilled_stage
    ) slots)<>(select count(distinct slot_id) from (
      select slot_id from pg_temp.alpha15_assignment_stage
      union all select slot_id from pg_temp.alpha15_unfilled_stage
    ) slots)
  then raise exception 'CANDIDATE_SLOT_ACCOUNTING_FAILED'; end if;

  select count(*) into v_invalid
  from pg_temp.alpha15_assignment_stage c
  left join public.employees e on e.id=c.employee_id and e.active and e.archived_at is null
  left join public.locations l on l.id=c.location_id and l.active
  where c.slot_id is null or c.shift_code is null or c.role_code is null
    or c.work_date<r.month or c.work_date>=r.month+interval '1 month'
    or c.ends_at<=c.starts_at or e.id is null or l.id is null
    or not exists(select 1 from public.employee_locations el
      where el.employee_id=c.employee_id and el.location_id=c.location_id
        and (el.standard_allowed or el.overtime_allowed))
    or (e.employment_start is not null and c.work_date<e.employment_start)
    or (e.employment_end is not null and c.work_date>e.employment_end)
    or (e.no_weekends and extract(isodow from c.work_date) in (6,7))
    or (e.only_morning and c.local_start>=time '15:00')
    or (e.only_evening and c.local_start<time '14:00')
    or not (e.primary_role::text=c.role_code or exists(
      select 1 from public.matrix_employee_roles mer
      join public.matrix_roles mr on mr.id=mer.role_id
      where mer.matrix_version_id=r.matrix_version_id and mer.employee_id=e.id
        and mr.code=c.role_code))
    or (c.function_code is not null and not exists(
      select 1 from public.employee_capabilities ec
      where ec.employee_id=e.id and ec.active and ec.capability=c.function_code
        and (ec.scope_role is null or ec.scope_role::text=c.role_code)
        and (ec.scope_location is null or ec.scope_location::text=l.code::text)))
    or exists(select 1 from public.employee_availability av
      where av.employee_id=e.id and av.work_date=c.work_date
        and (not av.available
          or (av.earliest_start is not null and c.start_min<
            extract(hour from av.earliest_start)::integer*60
              +extract(minute from av.earliest_start)::integer)
          or (av.latest_end is not null and c.end_min>
            extract(hour from av.latest_end)::integer*60
              +extract(minute from av.latest_end)::integer
              +case when av.earliest_start is not null and av.latest_end<=av.earliest_start
                then 1440 else 0 end)))
    or exists(select 1 from public.employee_preferences ep
      where ep.employee_id=e.id and ep.status='ACTIVE'
        and ep.preference_type in ('UNAVAILABLE','LEAVE','SICKNESS')
        and ep.valid_from<=c.work_date and ep.valid_to>=c.work_date);
  if v_invalid<>0 then raise exception 'HARD_CONSTRAINT_STATIC_OR_AVAILABILITY'; end if;

  if exists(
    select 1 from pg_temp.alpha15_assignment_stage a
    join pg_temp.alpha15_assignment_stage b
      on b.employee_id=a.employee_id and b.slot_id>a.slot_id
    join public.employees e on e.id=a.employee_id
    where b.starts_at<a.ends_at+coalesce(e.minimum_rest_minutes,660)*interval '1 minute'
      and b.ends_at>a.starts_at-coalesce(e.minimum_rest_minutes,660)*interval '1 minute'
  ) then raise exception 'HARD_CONSTRAINT_OVERLAP_OR_REST'; end if;

  if exists(
    select 1 from pg_temp.alpha15_assignment_stage c
    join public.employees e on e.id=c.employee_id
    group by c.employee_id,e.max_monthly_minutes,e.monthly_nominal_minutes
    having sum(public.shift_minutes(c.starts_at,c.ends_at))>
      coalesce(e.max_monthly_minutes,e.monthly_nominal_minutes)
  ) then raise exception 'HARD_CONSTRAINT_MONTHLY_LIMIT'; end if;

  if exists(
    select 1 from pg_temp.alpha15_assignment_stage c
    join public.employees e on e.id=c.employee_id
    group by c.employee_id,date_trunc('week',c.work_date::timestamp),e.max_weekly_minutes
    having sum(public.shift_minutes(c.starts_at,c.ends_at))>e.max_weekly_minutes
  ) then raise exception 'HARD_CONSTRAINT_WEEKLY_LIMIT'; end if;

  if exists(
    select 1 from pg_temp.alpha15_assignment_stage c
    group by c.employee_id,c.work_date
    having count(*)>coalesce((r.input_payload#>>'{matrix,settings,maxShiftsPerDay}')::integer,7)
  ) then raise exception 'HARD_CONSTRAINT_DAILY_SHIFT_LIMIT'; end if;

  if exists(
    with work_days as (
      select distinct employee_id,work_date from pg_temp.alpha15_assignment_stage
    ), islands as (
      select employee_id,work_date,
        work_date-(row_number() over(partition by employee_id order by work_date))::integer grp
      from work_days
    ), streaks as (
      select employee_id,count(*) days from islands group by employee_id,grp
    )
    select 1 from streaks x join public.employees e on e.id=x.employee_id
    where x.days>e.max_consecutive_days
  ) then raise exception 'HARD_CONSTRAINT_CONSECUTIVE_DAYS'; end if;

  select coalesce(sum(e.hourly_rate*public.shift_minutes(c.starts_at,c.ends_at)/60),0)
    into v_total_cost
  from pg_temp.alpha15_assignment_stage c join public.employees e on e.id=c.employee_id;
  if exists(select 1 from public.monthly_budgets b
    where b.month=r.month and b.hard_limit and b.amount>0 and v_total_cost>b.amount)
  then raise exception 'HARD_CONSTRAINT_BUDGET'; end if;

  if exists(
    select 1 from (
      select location_id,work_date,shift_code,starts_at,ends_at from pg_temp.alpha15_assignment_stage
      union all
      select location_id,work_date,shift_code,starts_at,ends_at from pg_temp.alpha15_unfilled_stage
    ) slots
    group by location_id,work_date,shift_code
    having count(distinct (starts_at,ends_at))>1
  ) then raise exception 'SHIFT_CODE_TIME_COLLISION'; end if;

  perform pg_advisory_xact_lock(hashtext('optimizer-plan-version:'||r.month::text));
  select coalesce(max(version),0)+1 into v_plan_version from public.plans where month=r.month;
  insert into public.plans(
    month,name,scenario_code,optimization_mode,staffing_level,status,version,
    score,total_cost,generated_at,created_by
  ) values(
    r.month,
    coalesce(nullif(trim(p_name),''),'Plan optymalny '||to_char(r.month,'YYYY-MM'))||' · Wariant '||v_rank,
    r.scenario_code,(select code from public.optimizer_profiles where id=r.profile_id),
    'OPTIMAL','GENERATING',v_plan_version,(p_candidate->>'score')::numeric,
    round(v_total_cost,2),now(),auth.uid()
  ) returning id into v_plan_id;

  insert into public.shifts(plan_id,location_id,shift_date,shift_code,starts_at,ends_at,status)
  select distinct on (location_id,work_date,shift_code)
    v_plan_id,location_id,work_date,shift_code,starts_at,ends_at,'PLANNED'
  from (
    select location_id,work_date,shift_code,starts_at,ends_at from pg_temp.alpha15_assignment_stage
    union all
    select location_id,work_date,shift_code,starts_at,ends_at from pg_temp.alpha15_unfilled_stage
  ) slots
  order by location_id,work_date,shift_code,starts_at,ends_at;

  insert into public.assignments(
    shift_id,employee_id,assigned_role,assigned_capability,cost,explanation
  )
  select s.id,c.employee_id,c.role_code::public.employee_role,c.function_code,
    round(e.hourly_rate*public.shift_minutes(c.starts_at,c.ends_at)/60,2),
    jsonb_build_object('engine','ALPHA_15_V4','runId',r.id,'slotId',c.slot_id,'variantRank',v_rank)
  from pg_temp.alpha15_assignment_stage c
  join public.shifts s on s.plan_id=v_plan_id and s.location_id=c.location_id
    and s.shift_date=c.work_date and s.shift_code=c.shift_code
  join public.employees e on e.id=c.employee_id;
  get diagnostics v_assignment_count=row_count;

  insert into public.plan_issues(
    plan_id,shift_id,issue_type,severity,role,capability,required_count,assigned_count,message
  )
  select v_plan_id,s.id,
    case when x.function_code is null then 'SHORTAGE' else 'CAPABILITY_MISSING' end,
    'CRITICAL',x.role_code::public.employee_role,x.function_code,x.missing,0,
    'Brak obsady: '||x.missing||' os. • '||x.role_code
      ||coalesce(' / '||x.function_code,'')||' • '||x.work_date||' • '||x.shift_code
  from (
    select work_date,shift_code,location_id,role_code,function_code,count(*)::integer missing
    from pg_temp.alpha15_unfilled_stage
    group by work_date,shift_code,location_id,role_code,function_code
  ) x
  join public.shifts s on s.plan_id=v_plan_id and s.shift_date=x.work_date
    and s.shift_code=x.shift_code and s.location_id=x.location_id;

  select coalesce(sum(greatest(coalesce(required_count,1)-coalesce(assigned_count,0),0)),0)::integer,
         count(*)::integer
    into v_unfilled,v_alert_groups
  from public.plan_issues where plan_id=v_plan_id and resolved_at is null
    and issue_type in ('SHORTAGE','CAPABILITY_MISSING');

  if v_assignment_count<>(select count(*) from pg_temp.alpha15_assignment_stage)
    or v_unfilled<>(select count(*) from pg_temp.alpha15_unfilled_stage)
  then raise exception 'MATERIALIZATION_COUNT_MISMATCH'; end if;

  return jsonb_build_object(
    'planId',v_plan_id,'rank',v_rank,'score',p_candidate->'score',
    'assignments',v_assignment_count,'unfilled',v_unfilled,
    'alertGroups',v_alert_groups,'totalCost',round(v_total_cost,2),
    'metrics',coalesce(p_candidate->'metrics','{}'::jsonb)
  );
end $$;


ALTER FUNCTION "public"."optimizer_materialize_candidate_v4"("p_run_id" "uuid", "p_name" "text", "p_candidate" "jsonb") OWNER TO "postgres";

--
-- Name: optimizer_materialize_next_v4("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_materialize_next_v4"("p_run_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  r public.optimization_runs;
  v_cursor integer;
  v_rank integer;
  v_candidate jsonb;
  v_result jsonb;
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  select * into r from public.optimization_runs
    where id=p_run_id and requested_by=auth.uid() for update;
  if r.id is null or r.status<>'RUNNING' or r.result_summary->>'phase'<>'FINALIZING'
  then raise exception 'RUN_NOT_FINALIZING'; end if;
  v_cursor:=coalesce((r.checkpoint->>'finalizeCursor')::integer,0);
  if v_cursor>=3 then return jsonb_build_object(
    'runId',r.id,'finalizing',true,'finalizeCursor',v_cursor,'finalizeTarget',3);
  end if;
  v_rank:=3-v_cursor;
  select jsonb_build_object(
    'rank',c.rank,'score',c.score,'hardViolations',c.hard_violations,
    'metrics',c.metrics,'assignments',c.assignments,
    'unfilled',coalesce((select p->'unfilled'
      from jsonb_array_elements(r.checkpoint->'finalCandidates') p
      where (p->>'rank')::integer=c.rank),'[]'::jsonb)
  ) into v_candidate
  from public.optimization_candidates c where c.run_id=r.id and c.rank=v_rank;
  if v_candidate is null then raise exception 'FINAL_CANDIDATE_NOT_FOUND'; end if;

  v_result:=public.optimizer_materialize_candidate_v4(
    r.id,r.checkpoint->>'finalizeName',v_candidate);
  update public.optimization_candidates
    set plan_id=(v_result->>'planId')::uuid where run_id=r.id and rank=v_rank;
  update public.optimization_runs set
    checkpoint=checkpoint||jsonb_build_object('finalizeCursor',v_cursor+1),
    heartbeat_at=now(),
    result_summary=result_summary||jsonb_build_object(
      'phase','FINALIZING','progress',90+((v_cursor+1)*3))
  where id=r.id;
  return jsonb_build_object(
    'runId',r.id,'finalizing',true,'finalizeCursor',v_cursor+1,'finalizeTarget',3,
    'materialized',v_result);
end $$;


ALTER FUNCTION "public"."optimizer_materialize_next_v4"("p_run_id" "uuid") OWNER TO "postgres";

--
-- Name: optimizer_operational_workspace_alpha16("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_operational_workspace_alpha16"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_month date:=date_trunc('month',p_month)::date;
  v_schedule uuid;
  v_workspace jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;

  select schedule.id into v_schedule
  from public.published_schedules_v2 schedule
  where schedule.month=v_month and schedule.status='PUBLISHED'
  order by schedule.published_at desc limit 1;

  if v_schedule is null then
    v_workspace:=public.optimizer_active_workspace_v2(v_month);
    return jsonb_build_object(
      'scheduleId',null,
      'workspace',v_workspace,
      'overrides','[]'::jsonb
    );
  end if;

  if not solver_private.alpha16_can_manage_schedule_v2(v_schedule) then
    raise exception 'FORBIDDEN';
  end if;

  v_workspace:=public.optimizer_published_schedule_alpha16(v_schedule);
  return jsonb_build_object(
    'scheduleId',v_schedule,'workspace',v_workspace,
    'overrides',coalesce((select jsonb_agg(jsonb_build_object(
      'id',override_row.id,'issueId',override_row.issue_id,
      'variantId',issue.variant_id,
      'slotKey',override_row.slot_key,'shiftId',override_row.shift_id,
      'slotGroupKey',shift_row.slot_group_key,
      'classification',override_row.assignment_class,
      'reason',override_row.override_reason,
      'createdAt',override_row.created_at,
      'employee',jsonb_build_object(
        'id',profile.employee_id,'employeeNo',profile.employee_no,
        'firstName',profile.first_name,'lastName',profile.last_name,
        'nominalMonthlyMinutes',profile.nominal_monthly_minutes
      ),
      'role',jsonb_build_object('id',role.id,'name',role.name),
      'duties',case when issue.duty_id is null then '[]'::jsonb else
        jsonb_build_array(jsonb_build_object('id',duty.id,'name',duty.name)) end
    ) order by override_row.created_at,override_row.id)
      from public.operational_assignment_overrides_v2 override_row
      join public.plan_shifts_v2 shift_row on shift_row.id=override_row.shift_id
      join public.matrix_employee_profiles_v2 profile
        on profile.matrix_version_id=(select schedule.matrix_version_id
          from public.published_schedules_v2 schedule where schedule.id=v_schedule)
        and profile.employee_id=override_row.employee_id
      join public.matrix_roles_v2 role on role.id=override_row.role_id
      join public.plan_issues_v2 issue on issue.id=override_row.issue_id
      left join public.matrix_duties_v2 duty on duty.id=issue.duty_id
      where override_row.schedule_id=v_schedule and override_row.status='ACTIVE'
    ),'[]'::jsonb)
  );
end;
$$;


ALTER FUNCTION "public"."optimizer_operational_workspace_alpha16"("p_month" "date") OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_operational_workspace_alpha16"("p_month" "date"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_operational_workspace_alpha16"("p_month" "date") IS 'Returns a stable operational workspace envelope; before the first monthly publication workspace is the canonical EMPTY ORTOOLS contract.';


