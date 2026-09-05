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
-- Name: uat_matrix_workforce_reset_preview_v2(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."uat_matrix_workforce_reset_preview_v2"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_enabled boolean:=false; v_draft uuid; v_version integer;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.has_app_role('OWNER') then raise exception 'FORBIDDEN'; end if;
  select control.enabled into v_enabled from public.uat_environment_controls control
    where control.control_key='ISOLATED_UAT_DESTRUCTIVE_TOOLS';
  select version.id,version.version into v_draft,v_version
  from public.matrix_versions version where version.status='DRAFT'
    and version.schema_version>=2 order by version.version desc limit 1;
  return jsonb_build_object(
    'enabled',coalesce(v_enabled,false),'draftMatrixVersionId',v_draft,
    'draftVersion',v_version,'confirmation','WYCZYŚĆ ROBOCZY MATRIX UAT',
    'employees',coalesce((select count(*) from public.matrix_employee_profiles_v2
      where matrix_version_id=v_draft),0),
    'roleAssignments',coalesce((select count(*) from public.matrix_employee_roles_v2
      where matrix_version_id=v_draft),0),
    'locationAssignments',coalesce((select count(*) from public.matrix_employee_locations_v2
      where matrix_version_id=v_draft),0),
    'dutyAssignments',coalesce((select count(*) from public.matrix_employee_duties_v2
      where matrix_version_id=v_draft),0),
    'preserves',jsonb_build_array(
      'aktywny Matrix','opublikowane grafiki','historia wersji','audit trail',
      'globalne konta pracowników','chroniona historia stawek'
    )
  );
end;
$$;


ALTER FUNCTION "public"."uat_matrix_workforce_reset_preview_v2"() OWNER TO "postgres";

--
-- Name: uat_matrix_workforce_reset_v2("text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."uat_matrix_workforce_reset_v2"("p_confirmation" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_actor uuid:=auth.uid(); v_enabled boolean:=false; v_draft uuid;
  v_profiles integer:=0; v_roles integer:=0; v_locations integer:=0; v_duties integer:=0;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.has_app_role('OWNER') then raise exception 'FORBIDDEN'; end if;
  select control.enabled into v_enabled from public.uat_environment_controls control
    where control.control_key='ISOLATED_UAT_DESTRUCTIVE_TOOLS';
  if not coalesce(v_enabled,false) then raise exception 'UAT_RESET_DISABLED'; end if;
  if trim(coalesce(p_confirmation,''))<>'WYCZYŚĆ ROBOCZY MATRIX UAT' then
    raise exception 'UAT_RESET_CONFIRMATION_INVALID';
  end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  select version.id into v_draft from public.matrix_versions version
  where version.status='DRAFT' and version.schema_version>=2
  order by version.version desc limit 1 for update;
  if v_draft is null then raise exception 'MATRIX_DRAFT_REQUIRED'; end if;

  delete from public.matrix_employee_duties_v2 where matrix_version_id=v_draft;
  get diagnostics v_duties=row_count;
  delete from public.matrix_employee_locations_v2 where matrix_version_id=v_draft;
  get diagnostics v_locations=row_count;
  delete from public.matrix_employee_roles_v2 where matrix_version_id=v_draft;
  get diagnostics v_roles=row_count;
  delete from public.matrix_employee_profiles_v2 where matrix_version_id=v_draft;
  get diagnostics v_profiles=row_count;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'uat_matrix_reset',v_draft::text,'RESET_DRAFT_WORKFORCE',
    jsonb_build_object('profiles',v_profiles,'roles',v_roles,
      'locations',v_locations,'duties',v_duties,
      'activeMatrixPreserved',true,'publishedSchedulesPreserved',true));
  return jsonb_build_object('draftMatrixVersionId',v_draft,'profiles',v_profiles,
    'roles',v_roles,'locations',v_locations,'duties',v_duties);
end;
$$;


ALTER FUNCTION "public"."uat_matrix_workforce_reset_v2"("p_confirmation" "text") OWNER TO "postgres";

--
-- Name: workforce_calendar_context_base_b4f89("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."workforce_calendar_context_base_b4f89"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_base jsonb;
  v_matrix uuid;
  v_month date:=date_trunc('month',p_month)::date;
  v_scoped jsonb:='[]'::jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  v_base:=public.workforce_calendar_context_uat_v3(v_month);
  if not public.can_manage_plans() then
    return v_base||jsonb_build_object('availabilityScopedSummary','[]'::jsonb);
  end if;
  v_matrix:=nullif(v_base->>'matrixVersionId','')::uuid;

  with days as (
    select generate_series(v_month,(v_month+interval '1 month - 1 day')::date,
      interval '1 day')::date work_date
  ), scopes as (
    select distinct role.id role_id,role.name role_name,role.logical_id role_logical_id,
      category.id category_id,category.name category_name,
      location.id location_id,location.name location_name,location.logical_id location_logical_id,
      location.timezone
    from public.matrix_staffing_rules_v2 staffing
    join public.matrix_shift_templates_v2 template
      on template.id=staffing.shift_template_id and template.matrix_version_id=v_matrix
      and template.active
    join public.matrix_roles_v2 role on role.id=staffing.role_id
      and role.matrix_version_id=v_matrix and role.active
    join public.matrix_role_categories_v2 category on category.id=role.category_id
      and category.matrix_version_id=v_matrix and category.active
    join public.matrix_locations_v2 location on location.id=template.location_id
      and location.matrix_version_id=v_matrix and location.active
    where staffing.matrix_version_id=v_matrix and staffing.active
      and (public.has_app_role('OWNER') or public.has_app_role('ADMIN') or exists(
        select 1 from public.matrix_scope_grants_v2 scope_grant
        where scope_grant.auth_user_id=auth.uid() and scope_grant.active
          and scope_grant.app_role='ROLE_MANAGER'
          and (scope_grant.role_logical_id is null or scope_grant.role_logical_id=role.logical_id)
          and (scope_grant.location_logical_id is null or scope_grant.location_logical_id=location.logical_id)
      ))
  ), eligible as (
    select day.work_date,scope.*,profile.employee_id,
      profile.first_name||' '||profile.last_name employee_name,
      exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=profile.employee_id and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
          and constraint_row.time_range&&tstzrange(
            day.work_date::timestamp at time zone scope.timezone,
            (day.work_date+1)::timestamp at time zone scope.timezone,'[)')) hard_unavailable,
      exists(select 1 from public.employee_preferences preference
        where preference.employee_id=profile.employee_id and preference.status='ACTIVE'
          and preference.preference_type='OTHER'
          and preference.preference_value->>'kind'='DAY_OFF'
          and preference.preference_value->>'strength'='SOFT'
          and preference.valid_from<=day.work_date and preference.valid_to>=day.work_date) soft_unavailable,
      exists(select 1 from public.availability_exception_reviews_v2 review
        where review.matrix_version_id=v_matrix and review.employee_id=profile.employee_id
          and review.role_id=scope.role_id and review.work_date=day.work_date
          and review.status='PENDING') pending_review
    from days day cross join scopes scope
    left join public.matrix_employee_roles_v2 role_grant
      on role_grant.matrix_version_id=v_matrix and role_grant.role_id=scope.role_id
      and role_grant.active
      and (role_grant.valid_from is null or role_grant.valid_from<=day.work_date)
      and (role_grant.valid_to is null or role_grant.valid_to>=day.work_date)
    left join public.matrix_employee_locations_v2 location_grant
      on location_grant.matrix_version_id=v_matrix
      and location_grant.employee_id=role_grant.employee_id
      and location_grant.location_id=scope.location_id and location_grant.active
      and (location_grant.valid_from is null or location_grant.valid_from<=day.work_date)
      and (location_grant.valid_to is null or location_grant.valid_to>=day.work_date)
    left join public.matrix_employee_profiles_v2 profile
      on location_grant.employee_id is not null
      and profile.matrix_version_id=v_matrix and profile.employee_id=role_grant.employee_id
      and profile.active and profile.archived_at is null
      and (profile.employment_start is null or profile.employment_start<=day.work_date)
      and (profile.employment_end is null or profile.employment_end>=day.work_date)
  ), grouped as (
    select work_date,category_id,category_name,role_id,role_name,location_id,location_name,
      count(distinct employee_id) total_count,
      count(distinct employee_id) filter(where not hard_unavailable and not pending_review) available_count,
      count(distinct employee_id) filter(where hard_unavailable) hard_count,
      count(distinct employee_id) filter(where soft_unavailable) soft_count,
      count(distinct employee_id) filter(where pending_review) pending_count,
      count(distinct employee_id) filter(where hard_unavailable or soft_unavailable or pending_review) recorded_count,
      coalesce(to_jsonb(array_agg(distinct employee_name order by employee_name)
        filter(where hard_unavailable)),'[]'::jsonb) hard_employees,
      coalesce(to_jsonb(array_agg(distinct employee_name order by employee_name)
        filter(where soft_unavailable)),'[]'::jsonb) soft_employees,
      coalesce(to_jsonb(array_agg(distinct employee_name order by employee_name)
        filter(where pending_review)),'[]'::jsonb) pending_employees
    from eligible group by work_date,category_id,category_name,role_id,role_name,location_id,location_name
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'date',work_date,'categoryId',category_id,'categoryName',category_name,
    'roleId',role_id,'roleName',role_name,'locationId',location_id,'locationName',location_name,
    'totalCount',total_count,'availableCount',available_count,
    'recordedCount',recorded_count,
    'progressPercent',case when total_count=0 then 100 else round(recorded_count::numeric*100/total_count)::integer end,
    'hardCount',hard_count,'softCount',soft_count,'pendingCount',pending_count,
    'hardEmployees',hard_employees,'softEmployees',soft_employees,'pendingEmployees',pending_employees
  ) order by work_date,category_name,role_name,location_name),'[]'::jsonb)
  into v_scoped from grouped;

  return v_base||jsonb_build_object('availabilityScopedSummary',v_scoped);
end;
$$;


ALTER FUNCTION "public"."workforce_calendar_context_base_b4f89"("p_month" "date") OWNER TO "postgres";

--
-- Name: FUNCTION "workforce_calendar_context_base_b4f89"("p_month" "date"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."workforce_calendar_context_base_b4f89"("p_month" "date") IS 'B4F-83: permission-scoped availability by category, role, location and local work day.';


--
-- Name: workforce_calendar_context_base_uat006("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."workforce_calendar_context_base_uat006"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_base jsonb; v_month date:=date_trunc('month',p_month)::date;
  v_matrix uuid; v_timezone text; v_summary jsonb:='[]'::jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  v_base:=public.workforce_calendar_context_uat_v2(v_month);
  if not public.can_manage_plans() then
    return v_base||jsonb_build_object('availabilitySummary','[]'::jsonb);
  end if;
  v_matrix:=nullif(v_base->>'matrixVersionId','')::uuid;
  select coalesce(nullif(version.settings->>'timezone',''),'Europe/Warsaw')
  into v_timezone from public.matrix_versions version where version.id=v_matrix;

  with days as (
    select generate_series(v_month,
      (v_month+interval '1 month - 1 day')::date,interval '1 day')::date work_date
  ), grants as (
    select grant_row.employee_id,grant_row.role_id,
      profile.first_name||' '||profile.last_name employee_name
    from public.matrix_employee_roles_v2 grant_row
    join public.matrix_employee_profiles_v2 profile
      on profile.matrix_version_id=grant_row.matrix_version_id
      and profile.employee_id=grant_row.employee_id
    where grant_row.matrix_version_id=v_matrix and grant_row.active
      and profile.active and profile.archived_at is null
  ), facts as (
    select distinct day.work_date,grant_row.role_id,grant_row.employee_id,
      grant_row.employee_name,'HARD'::text fact_kind
    from days day join grants grant_row on true
    join public.employee_time_constraints_v2 constraint_row
      on constraint_row.employee_id=grant_row.employee_id
      and constraint_row.status='ACTIVE'
      and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
      and constraint_row.time_range && tstzrange(
        day.work_date::timestamp at time zone v_timezone,
        (day.work_date+1)::timestamp at time zone v_timezone,'[)')
    union all
    select distinct day.work_date,grant_row.role_id,grant_row.employee_id,
      grant_row.employee_name,'SOFT'::text
    from days day join grants grant_row on true
    join public.employee_preferences preference
      on preference.employee_id=grant_row.employee_id
      and preference.status='ACTIVE'
      and preference.preference_type='OTHER'
      and preference.preference_value->>'kind'='DAY_OFF'
      and preference.preference_value->>'strength'='SOFT'
      and preference.valid_from<=day.work_date
      and preference.valid_to>=day.work_date
    union all
    select distinct review.work_date,review.role_id,review.employee_id,
      profile.first_name||' '||profile.last_name,'PENDING'::text
    from public.availability_exception_reviews_v2 review
    join public.matrix_employee_profiles_v2 profile
      on profile.matrix_version_id=review.matrix_version_id
      and profile.employee_id=review.employee_id
    where review.matrix_version_id=v_matrix and review.status='PENDING'
      and review.work_date>=v_month
      and review.work_date<(v_month+interval '1 month')::date
  ), grouped as (
    select fact.work_date,fact.role_id,role.name role_name,
      count(distinct fact.employee_id) filter(where fact.fact_kind='HARD') hard_count,
      count(distinct fact.employee_id) filter(where fact.fact_kind='SOFT') soft_count,
      count(distinct fact.employee_id) filter(where fact.fact_kind='PENDING') pending_count,
      coalesce(to_jsonb(array_agg(distinct fact.employee_name order by fact.employee_name)
        filter(where fact.fact_kind='HARD')),'[]'::jsonb) hard_employees,
      coalesce(to_jsonb(array_agg(distinct fact.employee_name order by fact.employee_name)
        filter(where fact.fact_kind='SOFT')),'[]'::jsonb) soft_employees,
      coalesce(to_jsonb(array_agg(distinct fact.employee_name order by fact.employee_name)
        filter(where fact.fact_kind='PENDING')),'[]'::jsonb) pending_employees
    from facts fact join public.matrix_roles_v2 role on role.id=fact.role_id
    group by fact.work_date,fact.role_id,role.name
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'date',grouped.work_date,'roleId',grouped.role_id,'roleName',grouped.role_name,
    'hardCount',grouped.hard_count,'softCount',grouped.soft_count,
    'pendingCount',grouped.pending_count,'hardEmployees',grouped.hard_employees,
    'softEmployees',grouped.soft_employees,'pendingEmployees',grouped.pending_employees
  ) order by grouped.work_date,grouped.role_name),'[]'::jsonb)
  into v_summary from grouped;

  return v_base||jsonb_build_object('availabilitySummary',v_summary);
end;
$$;


ALTER FUNCTION "public"."workforce_calendar_context_base_uat006"("p_month" "date") OWNER TO "postgres";

--
-- Name: workforce_calendar_context_uat_v2("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."workforce_calendar_context_uat_v2"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_month date:=date_trunc('month',p_month)::date;
  v_matrix uuid;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select matrix.id into v_matrix from public.matrix_versions matrix
  where matrix.status='ACTIVE' and matrix.schema_version>=2
    and solver_private.matrix_covers_planning_month_uat_v1(matrix.effective_from,v_month)
    and (matrix.effective_to is null
      or matrix.effective_to>=(v_month+interval '1 month - 1 day')::date)
  order by matrix.effective_from desc,matrix.version desc limit 1;
  select jsonb_build_object(
    'month',v_month,'matrixVersionId',v_matrix,
    'canManage',public.can_manage_plans(),
    'roles',coalesce((select jsonb_agg(jsonb_build_object(
      'id',role.id,'name',role.name,'code',role.code
    ) order by role.sort_order,role.name) from public.matrix_roles_v2 role
      where role.matrix_version_id=v_matrix and role.active),'[]'::jsonb),
    'locations',coalesce((select jsonb_agg(jsonb_build_object(
      'id',location.id,'name',location.name,'code',location.code
    ) order by location.sort_order,location.name)
      from public.matrix_locations_v2 location
      where location.matrix_version_id=v_matrix and location.active),'[]'::jsonb),
    'shiftTemplates',coalesce((select jsonb_agg(jsonb_build_object(
      'id',shift.id,'name',shift.name,'code',shift.code,
      'locationId',shift.location_id,'startsAt',shift.starts_at,
      'endsAt',shift.ends_at,'endsNextDay',shift.ends_next_day,
      'dayMask',to_jsonb(shift.day_mask)
    ) order by location.sort_order,shift.sort_order,shift.name)
      from public.matrix_shift_templates_v2 shift
      join public.matrix_locations_v2 location on location.id=shift.location_id
      where shift.matrix_version_id=v_matrix and shift.active and location.active),'[]'::jsonb),
    'events',coalesce((select jsonb_agg(jsonb_build_object(
      'id',event.id,'date',event.event_date,'kind',event.event_kind,
      'title',event.title,'description',event.description,
      'locationId',event.location_id,'locationName',location.name,
      'demands',coalesce((select jsonb_agg(jsonb_build_object(
        'id',demand.id,'shiftTemplateId',demand.shift_template_id,
        'shiftName',shift.name,'roleId',demand.role_id,'roleName',role.name,
        'dutyId',demand.duty_id,'additionalCount',demand.additional_count
      ) order by shift.sort_order,role.sort_order) from public.workforce_event_demand_v2 demand
        join public.matrix_shift_templates_v2 shift on shift.id=demand.shift_template_id
        join public.matrix_roles_v2 role on role.id=demand.role_id
        where demand.event_id=event.id),'[]'::jsonb),
      'hotLimits',coalesce((select jsonb_agg(jsonb_build_object(
        'roleId',hot.role_id,'roleName',role.name,
        'maximumHardUnavailable',hot.maximum_hard_unavailable
      ) order by role.sort_order) from public.workforce_hot_day_limits_v2 hot
        join public.matrix_roles_v2 role on role.id=hot.role_id
        where hot.event_id=event.id),'[]'::jsonb)
    ) order by event.event_date,event.title)
      from public.workforce_calendar_events_v2 event
      left join public.matrix_locations_v2 location on location.id=event.location_id
      where event.month=v_month and event.status='ACTIVE'),'[]'::jsonb),
    'pendingReviews',coalesce((select jsonb_agg(jsonb_build_object(
      'id',review.id,'employeeId',review.employee_id,
      'employeeName',profile.first_name||' '||profile.last_name,
      'employeeNo',profile.employee_no,'date',review.work_date,
      'roleId',review.role_id,'roleName',role.name,'status',review.status,
      'note',review.note,'requestedAt',review.requested_at
    ) order by review.work_date,profile.last_name,profile.first_name)
      from public.availability_exception_reviews_v2 review
      join public.matrix_employee_profiles_v2 profile
        on profile.matrix_version_id=review.matrix_version_id
        and profile.employee_id=review.employee_id
      join public.matrix_roles_v2 role on role.id=review.role_id
      where review.work_date>=v_month
        and review.work_date<(v_month+interval '1 month')::date
        and (review.requested_by=auth.uid() or public.can_manage_plans())
        and review.status='PENDING'),'[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;


ALTER FUNCTION "public"."workforce_calendar_context_uat_v2"("p_month" "date") OWNER TO "postgres";

--
-- Name: workforce_calendar_context_uat_v3("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."workforce_calendar_context_uat_v3"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_base jsonb; v_matrix uuid; v_timezone text; v_summary jsonb;
begin
  v_base:=public.workforce_calendar_context_base_uat006(p_month);
  if not public.can_manage_plans() then return v_base; end if;
  v_matrix:=nullif(v_base->>'matrixVersionId','')::uuid;
  select coalesce(nullif(version.settings->>'timezone',''),'Europe/Warsaw')
    into v_timezone from public.matrix_versions version where version.id=v_matrix;
  with items as (
    select value item,(value->>'date')::date work_date,
      (value->>'roleId')::uuid role_id
    from jsonb_array_elements(coalesce(v_base->'availabilitySummary','[]'::jsonb))
  ), enriched as (
    select items.*,
      (select count(distinct grant_row.employee_id)
        from public.matrix_employee_roles_v2 grant_row
        join public.matrix_employee_profiles_v2 profile
          on profile.matrix_version_id=grant_row.matrix_version_id
          and profile.employee_id=grant_row.employee_id
        where grant_row.matrix_version_id=v_matrix and grant_row.role_id=items.role_id
          and grant_row.active and profile.active and profile.archived_at is null
          and (grant_row.valid_from is null or grant_row.valid_from<=items.work_date)
          and (grant_row.valid_to is null or grant_row.valid_to>=items.work_date)
          and (profile.employment_start is null or profile.employment_start<=items.work_date)
          and (profile.employment_end is null or profile.employment_end>=items.work_date)
      ) total_count,
      (select count(distinct signal.employee_id) from (
        select constraint_row.employee_id
        from public.employee_time_constraints_v2 constraint_row
        where constraint_row.status='ACTIVE'
          and constraint_row.time_range&&tstzrange(
            items.work_date::timestamp at time zone v_timezone,
            (items.work_date+1)::timestamp at time zone v_timezone,'[)')
        union
        select preference.employee_id from public.employee_preferences preference
        where preference.status='ACTIVE' and preference.valid_from<=items.work_date
          and preference.valid_to>=items.work_date
        union
        select review.employee_id from public.availability_exception_reviews_v2 review
        where review.work_date=items.work_date and review.role_id=items.role_id
          and review.status='PENDING'
      ) signal join public.matrix_employee_roles_v2 grant_row
        on grant_row.matrix_version_id=v_matrix
        and grant_row.employee_id=signal.employee_id
        and grant_row.role_id=items.role_id and grant_row.active
      ) recorded_count,
      (select max(stamp) from (
        select max(constraint_row.updated_at) stamp
        from public.employee_time_constraints_v2 constraint_row
        where constraint_row.status='ACTIVE'
          and constraint_row.time_range&&tstzrange(
            items.work_date::timestamp at time zone v_timezone,
            (items.work_date+1)::timestamp at time zone v_timezone,'[)')
        union all
        select max(preference.created_at) from public.employee_preferences preference
        where preference.status='ACTIVE' and preference.valid_from<=items.work_date
          and preference.valid_to>=items.work_date
        union all
        select max(review.requested_at) from public.availability_exception_reviews_v2 review
        where review.work_date=items.work_date and review.role_id=items.role_id
      ) stamps) last_updated_at
    from items
  )
  select coalesce(jsonb_agg(item||jsonb_build_object(
    'totalCount',total_count,
    'availableCount',greatest(total_count-coalesce((item->>'hardCount')::integer,0)
      -coalesce((item->>'pendingCount')::integer,0),0),
    'recordedCount',recorded_count,
    'progressPercent',case when total_count=0 then 100
      else round(recorded_count::numeric*100/total_count)::integer end,
    'lastUpdatedAt',last_updated_at
  ) order by work_date,item->>'roleName'),'[]'::jsonb)
  into v_summary from enriched;
  return jsonb_set(v_base,'{availabilitySummary}',v_summary,true);
end;
$$;


ALTER FUNCTION "public"."workforce_calendar_context_uat_v3"("p_month" "date") OWNER TO "postgres";

--
-- Name: workforce_calendar_context_uat_v4("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."workforce_calendar_context_uat_v4"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_result jsonb;
  v_matrix uuid;
  v_templates jsonb:='[]'::jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  v_result:=public.workforce_calendar_context_base_b4f89(p_month);
  v_matrix:=nullif(v_result->>'matrixVersionId','')::uuid;

  select coalesce(jsonb_agg(
    template.value||jsonb_build_object(
      'roleIds',coalesce((select jsonb_agg(distinct staffing.role_id order by staffing.role_id)
        from public.matrix_staffing_rules_v2 staffing
        where staffing.matrix_version_id=v_matrix and staffing.active
          and staffing.shift_template_id=(template.value->>'id')::uuid),'[]'::jsonb),
      'roleNames',coalesce((select jsonb_agg(distinct role.name order by role.name)
        from public.matrix_staffing_rules_v2 staffing
        join public.matrix_roles_v2 role on role.id=staffing.role_id
          and role.matrix_version_id=v_matrix and role.active
        where staffing.matrix_version_id=v_matrix and staffing.active
          and staffing.shift_template_id=(template.value->>'id')::uuid),'[]'::jsonb)
    ) order by template.ordinality
  ),'[]'::jsonb)
  into v_templates
  from jsonb_array_elements(coalesce(v_result->'shiftTemplates','[]'::jsonb))
    with ordinality as template(value,ordinality);

  return jsonb_set(v_result,'{shiftTemplates}',v_templates,true);
end;
$$;


ALTER FUNCTION "public"."workforce_calendar_context_uat_v4"("p_month" "date") OWNER TO "postgres";

--
-- Name: FUNCTION "workforce_calendar_context_uat_v4"("p_month" "date"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."workforce_calendar_context_uat_v4"("p_month" "date") IS 'B4F-89: scoped workforce calendar with role-aware event shift templates.';


--
-- Name: workforce_calendar_event_range_save_before_phase1_uat_v1("date", "date", "date", "text", "text", "text", "uuid", "jsonb", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."workforce_calendar_event_range_save_before_phase1_uat_v1"("p_month" "date", "p_start_date" "date", "p_end_date" "date", "p_event_kind" "text", "p_title" "text", "p_description" "text", "p_location_id" "uuid", "p_demands" "jsonb" DEFAULT '[]'::"jsonb", "p_hot_limits" "jsonb" DEFAULT '[]'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_date date;
  v_result jsonb;
  v_rows jsonb:='[]'::jsonb;
  v_day_demands jsonb;
  v_matrix uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  if p_start_date is null or p_end_date is null or p_end_date<p_start_date then
    raise exception 'INVALID_DATE_RANGE';
  end if;
  if p_start_date<date_trunc('month',p_month)::date
    or p_end_date>=(date_trunc('month',p_month)+interval '1 month')::date then
    raise exception 'EVENT_RANGE_OUTSIDE_MONTH';
  end if;
  if p_end_date-p_start_date>30 then raise exception 'EVENT_RANGE_TOO_LONG'; end if;

  select matrix.id into v_matrix from public.matrix_versions matrix
  where matrix.status='ACTIVE' and matrix.schema_version>=2
    and matrix.effective_from<=date_trunc('month',p_month)::date
    and (matrix.effective_to is null or matrix.effective_to>=(date_trunc('month',p_month)+interval '1 month - 1 day')::date)
  order by matrix.effective_from desc,matrix.version desc limit 1;

  for v_date in select generate_series(p_start_date,p_end_date,interval '1 day')::date loop
    if p_event_kind='EVENT' then
      select coalesce(jsonb_agg(demand.value order by demand.ordinality),'[]'::jsonb)
      into v_day_demands
      from jsonb_array_elements(coalesce(p_demands,'[]'::jsonb))
        with ordinality as demand(value,ordinality)
      join public.matrix_shift_templates_v2 template
        on template.id=(demand.value->>'shiftTemplateId')::uuid
        and template.matrix_version_id=v_matrix and template.active
        and template.location_id=p_location_id
        and extract(isodow from v_date)::integer=any(template.day_mask)
      where exists(select 1 from public.matrix_staffing_rules_v2 staffing
        where staffing.matrix_version_id=v_matrix and staffing.active
          and staffing.shift_template_id=template.id
          and staffing.role_id=(demand.value->>'roleId')::uuid);
      if jsonb_array_length(v_day_demands)=0 then continue; end if;
    else
      v_day_demands:='[]'::jsonb;
    end if;

    v_result:=public.workforce_calendar_event_save_uat_v2(
      null,p_month,v_date,p_event_kind,p_title,p_description,p_location_id,
      v_day_demands,p_hot_limits
    );
    v_rows:=v_rows||jsonb_build_array(jsonb_build_object(
      'date',v_date,'id',v_result->>'id','saved',true,
      'demandCount',jsonb_array_length(v_day_demands)
    ));
  end loop;

  if p_event_kind='EVENT' and jsonb_array_length(v_rows)=0 then
    raise exception 'EVENT_HAS_NO_ACTIVE_ROLE_SHIFTS';
  end if;
  return jsonb_build_object('saved',true,'startDate',p_start_date,'endDate',p_end_date,
    'count',jsonb_array_length(v_rows),'events',v_rows);
end;
$$;


ALTER FUNCTION "public"."workforce_calendar_event_range_save_before_phase1_uat_v1"("p_month" "date", "p_start_date" "date", "p_end_date" "date", "p_event_kind" "text", "p_title" "text", "p_description" "text", "p_location_id" "uuid", "p_demands" "jsonb", "p_hot_limits" "jsonb") OWNER TO "postgres";

--
-- Name: workforce_calendar_event_range_save_uat_v2("date", "date", "date", "text", "text", "text", "uuid", "jsonb", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."workforce_calendar_event_range_save_uat_v2"("p_month" "date", "p_start_date" "date", "p_end_date" "date", "p_event_kind" "text", "p_title" "text", "p_description" "text", "p_location_id" "uuid", "p_demands" "jsonb" DEFAULT '[]'::"jsonb", "p_hot_limits" "jsonb" DEFAULT '[]'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if not authorization_private.calendar_payload_allowed_uat_v1(
    p_location_id,p_demands,p_hot_limits
  ) then raise exception 'RESOURCE_SCOPE_FORBIDDEN'; end if;
  perform authorization_private.enter_resource_scope_uat_v1();
  return public.workforce_calendar_event_range_save_before_phase1_uat_v1(
    p_month,p_start_date,p_end_date,p_event_kind,p_title,p_description,
    p_location_id,p_demands,p_hot_limits
  );
end;
$$;


ALTER FUNCTION "public"."workforce_calendar_event_range_save_uat_v2"("p_month" "date", "p_start_date" "date", "p_end_date" "date", "p_event_kind" "text", "p_title" "text", "p_description" "text", "p_location_id" "uuid", "p_demands" "jsonb", "p_hot_limits" "jsonb") OWNER TO "postgres";

--
-- Name: workforce_calendar_event_save_before_phase1_uat_v1("uuid", "date", "date", "text", "text", "text", "uuid", "jsonb", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."workforce_calendar_event_save_before_phase1_uat_v1"("p_event_id" "uuid", "p_month" "date", "p_event_date" "date", "p_event_kind" "text", "p_title" "text", "p_description" "text", "p_location_id" "uuid", "p_demands" "jsonb" DEFAULT '[]'::"jsonb", "p_hot_limits" "jsonb" DEFAULT '[]'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid();
  v_matrix uuid;
  v_id uuid:=coalesce(p_event_id,gen_random_uuid());
  v_kind text:=upper(trim(coalesce(p_event_kind,'')));
  v_item jsonb;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  if p_month is null or p_event_date is null
    or p_event_date<date_trunc('month',p_month)::date
    or p_event_date>=(date_trunc('month',p_month)+interval '1 month')::date then
    raise exception 'EVENT_DATE_OUTSIDE_MONTH';
  end if;
  if v_kind not in ('EVENT','HOT_DAY') then raise exception 'INVALID_EVENT_KIND'; end if;
  if length(trim(coalesce(p_title,'')))<3 then raise exception 'EVENT_TITLE_REQUIRED'; end if;
  select matrix.id into v_matrix from public.matrix_versions matrix
  where matrix.status='ACTIVE' and matrix.schema_version>=2
    and matrix.effective_from<=p_event_date
    and (matrix.effective_to is null or matrix.effective_to>=p_event_date)
  order by matrix.effective_from desc,matrix.version desc limit 1;
  if v_matrix is null then raise exception 'MATRIX_V2_FOR_MONTH_NOT_FOUND'; end if;

  insert into public.workforce_calendar_events_v2(
    id,matrix_version_id,month,event_date,location_id,event_kind,title,
    description,created_by
  ) values(v_id,v_matrix,date_trunc('month',p_month)::date,p_event_date,
    p_location_id,v_kind,trim(p_title),nullif(trim(p_description),''),v_actor)
  on conflict(id) do update set event_date=excluded.event_date,
    location_id=excluded.location_id,event_kind=excluded.event_kind,
    title=excluded.title,description=excluded.description,updated_at=now();

  delete from public.workforce_event_demand_v2 where event_id=v_id;
  delete from public.workforce_hot_day_limits_v2 where event_id=v_id;
  for v_item in select value from jsonb_array_elements(coalesce(p_demands,'[]'::jsonb)) loop
    if v_kind<>'EVENT' then raise exception 'DEMAND_REQUIRES_EVENT'; end if;
    insert into public.workforce_event_demand_v2(
      event_id,matrix_version_id,shift_template_id,role_id,duty_id,additional_count
    ) values(v_id,v_matrix,(v_item->>'shiftTemplateId')::uuid,
      (v_item->>'roleId')::uuid,nullif(v_item->>'dutyId','')::uuid,
      (v_item->>'additionalCount')::integer);
  end loop;
  for v_item in select value from jsonb_array_elements(coalesce(p_hot_limits,'[]'::jsonb)) loop
    if v_kind<>'HOT_DAY' then raise exception 'HOT_LIMIT_REQUIRES_HOT_DAY'; end if;
    insert into public.workforce_hot_day_limits_v2(
      event_id,matrix_version_id,role_id,maximum_hard_unavailable
    ) values(v_id,v_matrix,(v_item->>'roleId')::uuid,
      (v_item->>'maximumHardUnavailable')::integer);
  end loop;
  if v_kind='EVENT' and not exists(select 1 from public.workforce_event_demand_v2
      where event_id=v_id) then raise exception 'EVENT_DEMAND_REQUIRED'; end if;
  if v_kind='HOT_DAY' and not exists(select 1 from public.workforce_hot_day_limits_v2
      where event_id=v_id) then raise exception 'HOT_DAY_LIMIT_REQUIRED'; end if;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'workforce_calendar_event_v2',v_id::text,
    case when p_event_id is null then 'CREATE' else 'UPDATE' end,
    jsonb_build_object('month',date_trunc('month',p_month)::date,
      'date',p_event_date,'kind',v_kind,'title',trim(p_title),
      'demands',coalesce(p_demands,'[]'::jsonb),
      'hotLimits',coalesce(p_hot_limits,'[]'::jsonb)));
  return jsonb_build_object('id',v_id,'saved',true);
end;
$$;


ALTER FUNCTION "public"."workforce_calendar_event_save_before_phase1_uat_v1"("p_event_id" "uuid", "p_month" "date", "p_event_date" "date", "p_event_kind" "text", "p_title" "text", "p_description" "text", "p_location_id" "uuid", "p_demands" "jsonb", "p_hot_limits" "jsonb") OWNER TO "postgres";

--
-- Name: workforce_calendar_event_save_uat_v2("uuid", "date", "date", "text", "text", "text", "uuid", "jsonb", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."workforce_calendar_event_save_uat_v2"("p_event_id" "uuid", "p_month" "date", "p_event_date" "date", "p_event_kind" "text", "p_title" "text", "p_description" "text", "p_location_id" "uuid", "p_demands" "jsonb" DEFAULT '[]'::"jsonb", "p_hot_limits" "jsonb" DEFAULT '[]'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if p_event_id is not null
    and not authorization_private.calendar_event_allowed_uat_v1(p_event_id)
    then raise exception 'RESOURCE_SCOPE_FORBIDDEN'; end if;
  if not authorization_private.calendar_payload_allowed_uat_v1(
    p_location_id,p_demands,p_hot_limits
  ) then raise exception 'RESOURCE_SCOPE_FORBIDDEN'; end if;
  perform authorization_private.enter_resource_scope_uat_v1();
  return public.workforce_calendar_event_save_before_phase1_uat_v1(
    p_event_id,p_month,p_event_date,p_event_kind,p_title,p_description,
    p_location_id,p_demands,p_hot_limits
  );
end;
$$;


ALTER FUNCTION "public"."workforce_calendar_event_save_uat_v2"("p_event_id" "uuid", "p_month" "date", "p_event_date" "date", "p_event_kind" "text", "p_title" "text", "p_description" "text", "p_location_id" "uuid", "p_demands" "jsonb", "p_hot_limits" "jsonb") OWNER TO "postgres";

--
-- Name: activate_matrix_employee_profiles_v2(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."activate_matrix_employee_profiles_v2"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_document jsonb;
begin
  if old.status='DRAFT' and new.status='ACTIVE' and new.schema_version>=2 then
    if exists(select 1 from public.matrix_employee_profiles_v2 p
      where p.matrix_version_id=new.id and p.active and (
        not exists(select 1 from public.matrix_employee_roles_v2 er
          where er.matrix_version_id=new.id and er.employee_id=p.employee_id
            and er.active)
        or not exists(select 1 from public.matrix_employee_locations_v2 el
          where el.matrix_version_id=new.id and el.employee_id=p.employee_id
            and el.active and (el.standard_allowed or el.overtime_allowed))
      )) then raise exception 'ACTIVE_EMPLOYEE_REQUIRES_ROLE_AND_LOCATION'; end if;

    update public.employees e set
      employee_no=p.employee_no,first_name=p.first_name,last_name=p.last_name,
      email=p.email,monthly_nominal_minutes=p.nominal_monthly_minutes,
      max_monthly_minutes=p.maximum_monthly_minutes,
      max_weekly_minutes=p.maximum_weekly_minutes,
      max_consecutive_days=p.maximum_consecutive_days,
      minimum_rest_minutes=p.minimum_rest_minutes,
      only_morning=p.only_morning,only_evening=p.only_evening,
      no_weekends=p.no_weekends,preferred_shift=p.preferred_shift_code,
      employment_start=p.employment_start,employment_end=p.employment_end,
      active=p.active,archived_at=p.archived_at,archived_by=p.archived_by,
      archive_reason=p.archive_reason,
      primary_role=(
        select case when exists(
          select 1 from unnest(enum_range(null::public.employee_role)) legacy(value)
          where legacy.value::text=r.code
        ) then r.code::public.employee_role else null end
        from public.matrix_employee_roles_v2 er
        join public.matrix_roles_v2 r on r.id=er.role_id
        where er.matrix_version_id=new.id and er.employee_id=p.employee_id
          and er.active and er.is_primary
        order by er.created_at limit 1
      ),
      updated_at=now()
    from public.matrix_employee_profiles_v2 p
    where p.matrix_version_id=new.id and e.id=p.employee_id;

    select coalesce(jsonb_agg(
      to_jsonb(p)-array['id','matrix_version_id','created_at','updated_at',
        'created_by','updated_by'] order by p.employee_id),'[]'::jsonb)
    into v_document
    from public.matrix_employee_profiles_v2 p where p.matrix_version_id=new.id;
    new.workforce_hash:=encode(extensions.digest(
      convert_to(v_document::text,'UTF8'),'sha256'),'hex');
    new.workforce_count:=jsonb_array_length(v_document);
  end if;
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."activate_matrix_employee_profiles_v2"() OWNER TO "postgres";

--
-- Name: active_ortools_solver_version_v2(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."active_ortools_solver_version_v2"() RETURNS "text"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_engine text;
  v_enabled boolean;
  v_solver_version text;
begin
  select flag.engine,flag.enabled,
    nullif(trim(flag.config->>'solverVersion'),'')
  into v_engine,v_enabled,v_solver_version
  from public.solver_feature_flags flag
  where flag.flag_key='DEFAULT_ENGINE';

  if v_enabled is distinct from true
    or v_engine is distinct from 'ORTOOLS_V2' then
    raise exception 'ORTOOLS_ACTIVE_SOLVER_VERSION_REQUIRED';
  end if;
  if length(coalesce(v_solver_version,'')) not between 1 and 200 then
    raise exception 'SOLVER_VERSION_CONFIGURATION_REQUIRED';
  end if;
  return v_solver_version;
end;
$$;


ALTER FUNCTION "solver_private"."active_ortools_solver_version_v2"() OWNER TO "postgres";

--
-- Name: FUNCTION "active_ortools_solver_version_v2"(); Type: COMMENT; Schema: solver_private; Owner: postgres
--

COMMENT ON FUNCTION "solver_private"."active_ortools_solver_version_v2"() IS 'Fail-closed source of the enabled DEFAULT_ENGINE ORTOOLS_V2 solverVersion.';


--
-- Name: alpha16_can_manage_schedule_v2("uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."alpha16_can_manage_schedule_v2"("p_schedule_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select p_schedule_id is not null and (
    public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('VERIFIER')
    or exists(
      select 1
      from public.published_schedule_variants_v2 link
      join public.plan_variants_v2 variant on variant.id=link.variant_id
      join public.optimization_runs_v2 run on run.id=variant.run_id
      join public.matrix_roles_v2 role on role.id=run.scope_role_id
      join public.matrix_scope_grants_v2 grant_row
        on grant_row.auth_user_id=auth.uid() and grant_row.active
        and grant_row.app_role='ROLE_MANAGER'
        and (grant_row.role_logical_id is null
          or grant_row.role_logical_id=role.logical_id)
      where link.schedule_id=p_schedule_id
    )
  );
$$;


ALTER FUNCTION "solver_private"."alpha16_can_manage_schedule_v2"("p_schedule_id" "uuid") OWNER TO "postgres";

--
-- Name: alpha16_enrich_workspace_issues_v2("jsonb", "uuid"[]); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."alpha16_enrich_workspace_issues_v2"("p_workspace" "jsonb", "p_variant_ids" "uuid"[]) RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select jsonb_set(
    coalesce(p_workspace,'{}'::jsonb),
    '{issues}',
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',issue.id,
        'variantId',issue.variant_id,
        'slotKey',issue.slot_key,
        'code',issue.issue_code,
        'severity',issue.severity,
        'message',issue.message,
        'requiredCount',issue.required_count,
        'assignedCount',issue.assigned_count,
        'metadata',issue.metadata,
        'role',case when role.id is null then null else
          jsonb_build_object('id',role.id,'name',role.name) end,
        'duty',case when duty.id is null then null else
          jsonb_build_object('id',duty.id,'name',duty.name) end,
        'shift',case when shift_row.id is null then null else
          jsonb_build_object(
            'id',shift_row.id,
            'date',shift_row.shift_date,
            'startsAt',shift_row.starts_at,
            'endsAt',shift_row.ends_at,
            'location',jsonb_build_object(
              'id',location.id,'name',location.name,'timezone',location.timezone
            ),
            'shiftTemplate',jsonb_build_object(
              'id',template.id,'name',template.name,'shiftPeriod',template.shift_period
            )
          ) end
      ) order by shift_row.starts_at nulls last,issue.severity desc,issue.id)
      from public.plan_issues_v2 issue
      left join public.plan_shifts_v2 shift_row on shift_row.id=issue.shift_id
      left join public.matrix_locations_v2 location on location.id=shift_row.location_id
      left join public.matrix_shift_templates_v2 template
        on template.id=shift_row.shift_template_id
      left join public.matrix_roles_v2 role on role.id=issue.role_id
      left join public.matrix_duties_v2 duty on duty.id=issue.duty_id
      where issue.variant_id=any(coalesce(p_variant_ids,'{}'::uuid[]))
    ),'[]'::jsonb),
    true
  );
$$;


ALTER FUNCTION "solver_private"."alpha16_enrich_workspace_issues_v2"("p_workspace" "jsonb", "p_variant_ids" "uuid"[]) OWNER TO "postgres";

--
-- Name: alpha16_preference_level_v2("uuid", "uuid", "date", "text"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."alpha16_preference_level_v2"("p_employee_id" "uuid", "p_matrix_version_id" "uuid", "p_month" "date", "p_period" "text") RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select upper(coalesce(preference.preference_value->>'level','NEUTRAL'))
  from public.employee_preferences preference
  where preference.employee_id=p_employee_id
    and preference.status='ACTIVE'
    and preference.preference_type='PREFERRED_SHIFT'
    and upper(coalesce(
      preference.preference_value->>'period',
      preference.preference_value->>'shiftPeriod'
    ))=upper(p_period)
    and preference.valid_from<date_trunc('month',p_month)::date+interval '1 month'
    and preference.valid_to>=date_trunc('month',p_month)::date
    and (
      preference.source<>'MANAGER'
      or coalesce(preference.preference_value->>'matrixVersionId','')
        =p_matrix_version_id::text
    )
  order by case preference.source when 'MANAGER' then 0 else 1 end,
    preference.created_at desc,preference.id desc
  limit 1;
$$;


ALTER FUNCTION "solver_private"."alpha16_preference_level_v2"("p_employee_id" "uuid", "p_matrix_version_id" "uuid", "p_month" "date", "p_period" "text") OWNER TO "postgres";

--
-- Name: alpha16_shift_period_default_v2(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."alpha16_shift_period_default_v2"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  new.shift_period := case
    when new.starts_at < time '12:00' then 'MORNING'
    when new.starts_at < time '17:00' then 'MIDDLE'
    else 'EVENING'
  end;
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."alpha16_shift_period_default_v2"() OWNER TO "postgres";

--
-- Name: alpha16_shift_rules_v2("uuid", "uuid", "date"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."alpha16_shift_rules_v2"("p_employee_id" "uuid", "p_matrix_version_id" "uuid", "p_month" "date") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  with periods(period) as (
    values ('MORNING'::text),('MIDDLE'::text),('EVENING'::text)
  ), effective as (
    select p.period,coalesce(
      solver_private.alpha16_preference_level_v2(
        p_employee_id,p_matrix_version_id,p_month,p.period
      ),
      case
        when profile.only_morning and p.period<>'MORNING' then 'BLOCKED'
        when profile.only_evening and p.period<>'EVENING' then 'BLOCKED'
        when upper(coalesce(profile.preferred_shift_code,''))=p.period then 'PREFERRED'
        else 'NEUTRAL'
      end
    ) level
    from periods p
    join public.matrix_employee_profiles_v2 profile
      on profile.matrix_version_id=p_matrix_version_id
      and profile.employee_id=p_employee_id
  )
  select jsonb_build_object(
    'periods',coalesce(jsonb_object_agg(period,level),'{}'::jsonb),
    'preferredShiftTemplateIds',coalesce((
      select jsonb_agg(template.id::text order by template.id::text)
      from public.matrix_shift_templates_v2 template
      join effective rule on rule.period=template.shift_period
      where template.matrix_version_id=p_matrix_version_id and template.active
        and rule.level='PREFERRED'
    ),'[]'::jsonb),
    'avoidedShiftTemplateIds',coalesce((
      select jsonb_agg(template.id::text order by template.id::text)
      from public.matrix_shift_templates_v2 template
      join effective rule on rule.period=template.shift_period
      where template.matrix_version_id=p_matrix_version_id and template.active
        and rule.level='AVOIDED'
    ),'[]'::jsonb),
    'blockedShiftTemplateIds',coalesce((
      select jsonb_agg(template.id::text order by template.id::text)
      from public.matrix_shift_templates_v2 template
      join effective rule on rule.period=template.shift_period
      where template.matrix_version_id=p_matrix_version_id and template.active
        and rule.level='BLOCKED'
    ),'[]'::jsonb)
  ) from effective limit 1;
$$;


ALTER FUNCTION "solver_private"."alpha16_shift_rules_v2"("p_employee_id" "uuid", "p_matrix_version_id" "uuid", "p_month" "date") OWNER TO "postgres";

--
-- Name: apply_integer_operations_v2("jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."apply_integer_operations_v2"("p_operations" "jsonb") RETURNS bigint
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
declare
  v_value bigint := 0;
  v_item jsonb;
  v_operation text;
begin
  for v_item in
    select value from jsonb_array_elements(coalesce(p_operations,'[]'::jsonb))
  loop
    v_operation := upper(v_item->>'operation');
    case v_operation
      when 'SET' then v_value := coalesce((v_item->>'value')::bigint,0);
      when 'ADD' then v_value := v_value + coalesce((v_item->>'value')::bigint,0);
      when 'MULTIPLY' then
        v_value := round(v_value * coalesce((v_item->>'basisPoints')::numeric,0) / 10000)::bigint;
      when 'REMOVE' then v_value := 0;
      else raise exception 'UNSUPPORTED_MATRIX_OPERATION:%',v_operation;
    end case;
  end loop;
  return greatest(v_value,0);
end;
$$;


ALTER FUNCTION "solver_private"."apply_integer_operations_v2"("p_operations" "jsonb") OWNER TO "postgres";

--
-- Name: apply_strategy_semantics_b4f165("uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."apply_strategy_semantics_b4f165"("p_matrix_version_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  update public.matrix_versions mv
  set settings=coalesce(mv.settings,'{}'::jsonb)||jsonb_build_object(
      'strategySemanticsVersion','B4F165_V1',
      'mandatoryProductGuards',jsonb_build_array(
        'HARD_CONSTRAINTS','COVERAGE','ROLE_BACKUP','OVERTIME','ZERO_HOURS',
        'PRIMARY_ROLE','MAX_MIN_FAIRNESS','FAIRNESS_SPREAD'
      ),
      'configurableObjectivesStartAfterMandatoryGuards',true
    )
  where mv.id=p_matrix_version_id;

  update public.matrix_strategies_v2 s
  set description=case s.code
      when 'BALANCED' then
        'Po zapewnieniu wymaganej obsady, zasad czasu pracy, minimalnych nadgodzin i podstawowego wyrównania zespołu łączy koszt, preferencje pracowników i dalszą równowagę obciążenia.'
      when 'MIN_COST' then
        'Minimalizuje koszt wśród grafików spełniających pełną obsadę, zasady czasu pracy, minimalne nadgodziny i podstawowe wymagania sprawiedliwego podziału.'
      when 'PREFERENCES' then
        'Najpierw sprawiedliwie rozdziela pracę względem celów i możliwości pracowników. Następnie wśród podobnie sprawiedliwych grafików możliwie najlepiej uwzględnia preferowane dni, zmiany i lokalizacje.'
    end,
    updated_at=now()
  where s.matrix_version_id=p_matrix_version_id and s.active
    and s.code in ('BALANCED','MIN_COST','PREFERENCES');

  update public.matrix_strategy_objectives_v2 o
  set tier=case s.code
      when 'BALANCED' then case o.metric_code
        when 'UNFILLED' then 1 else 2 end
      when 'MIN_COST' then case o.metric_code
        when 'UNFILLED' then 1
        when 'TOTAL_COST' then 2
        when 'OVERTIME_MINUTES' then 3
        when 'HOME_LOCATION_VIOLATIONS' then 3
        when 'PREFERENCE_VIOLATIONS' then 4
        when 'NOMINAL_DEVIATION_MINUTES' then 5
        when 'LOAD_SPREAD_MINUTES' then 5
        when 'WEEKEND_SPREAD' then 5
        else 6 end
      when 'PREFERENCES' then case o.metric_code
        when 'UNFILLED' then 1
        when 'LOAD_SPREAD_MINUTES' then 2
        when 'NOMINAL_DEVIATION_MINUTES' then 3
        when 'PREFERENCE_VIOLATIONS' then 4
        when 'WEEKEND_SPREAD' then 5
        when 'TOTAL_COST' then 6
        when 'HOME_LOCATION_VIOLATIONS' then 6
        else 7 end
      else o.tier
    end
  from public.matrix_strategies_v2 s
  where o.matrix_version_id=p_matrix_version_id
    and s.matrix_version_id=p_matrix_version_id and s.id=o.strategy_id
    and s.active and o.active
    and s.code in ('BALANCED','MIN_COST','PREFERENCES');

  perform solver_private.validate_strategy_semantics_b4f165(p_matrix_version_id);
end;
$$;


ALTER FUNCTION "solver_private"."apply_strategy_semantics_b4f165"("p_matrix_version_id" "uuid") OWNER TO "postgres";

--
-- Name: apply_strategy_semantics_b4f168("uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."apply_strategy_semantics_b4f168"("p_matrix_version_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  -- Reuse the already tested hierarchy/descriptions, then remove only the
  -- unsupported objective from the new draft.
  perform solver_private.apply_strategy_semantics_b4f165(p_matrix_version_id);

  delete from public.matrix_strategy_objectives_v2 o
  where o.matrix_version_id=p_matrix_version_id
    and o.metric_code='HOME_LOCATION_VIOLATIONS';

  update public.matrix_versions mv
  set settings=coalesce(mv.settings,'{}'::jsonb)||jsonb_build_object(
    'strategySemanticsVersion','B4F168_V1'
  )
  where mv.id=p_matrix_version_id;

  perform solver_private.validate_strategy_semantics_b4f168(
    p_matrix_version_id
  );
end;
$$;


ALTER FUNCTION "solver_private"."apply_strategy_semantics_b4f168"("p_matrix_version_id" "uuid") OWNER TO "postgres";

--
-- Name: apply_strategy_semantics_b4f169("uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."apply_strategy_semantics_b4f169"("p_matrix_version_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  -- The draft already inherits the active B4F168 contract. Re-applying the
  -- older B4F165 base would temporarily require the HOME objective that v20
  -- intentionally removed, so validate the inherited state and advance it.
  perform solver_private.validate_strategy_semantics_b4f168(
    p_matrix_version_id
  );

  -- B4F-169 derives seeds from the immutable business snapshot. Remove any
  -- inherited technical seed from this new Matrix version only.
  update public.matrix_strategies_v2 s
  set solver_options=coalesce(s.solver_options,'{}'::jsonb)-'randomSeed'
  where s.matrix_version_id=p_matrix_version_id;

  update public.matrix_scenario_strategies_v2 ss
  set solver_overrides=coalesce(ss.solver_overrides,'{}'::jsonb)-'randomSeed'
  where ss.matrix_version_id=p_matrix_version_id;

  update public.matrix_versions mv
  set settings=(coalesce(mv.settings,'{}'::jsonb)-'randomSeed')
    ||jsonb_build_object(
      'strategySemanticsVersion','B4F169_V1',
      'mandatoryProductGuards',jsonb_build_array(
        'HARD_CONSTRAINTS','COVERAGE','ROLE_BACKUP','OVERTIME','ZERO_HOURS',
        'PRIMARY_ROLE','MAX_MIN_FAIRNESS','FAIRNESS_SPREAD',
        'FAIRNESS_QUALITY_GATE'
      ),
      'fairnessQualityGate',jsonb_build_object(
        'minimumEstimatedAchievableTargetUtilizationBps',700,
        'maximumEstimatedAchievableTargetUtilizationSpreadBps',300,
        'maxAttempts',3
      )
    )
  where mv.id=p_matrix_version_id;

  perform solver_private.validate_strategy_semantics_b4f169(
    p_matrix_version_id
  );
end;
$$;


ALTER FUNCTION "solver_private"."apply_strategy_semantics_b4f169"("p_matrix_version_id" "uuid") OWNER TO "postgres";

--
-- Name: apply_strategy_semantics_b4f170("uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."apply_strategy_semantics_b4f170"("p_matrix_version_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  perform solver_private.validate_strategy_semantics_b4f169(
    p_matrix_version_id
  );

  update public.matrix_versions mv
  set settings=(coalesce(mv.settings,'{}'::jsonb)-'fairnessQualityGate')
    ||jsonb_build_object(
      'strategySemanticsVersion','B4F170_V1',
      'mandatoryProductGuards',jsonb_build_array(
        'HARD_CONSTRAINTS','COVERAGE','ROLE_BACKUP','OVERTIME','ZERO_HOURS',
        'PRIMARY_ROLE','MAX_MIN_FAIRNESS','FAIRNESS_SPREAD',
        'FAIRNESS_QUALITY_TARGET'
      ),
      'fairnessQualityTarget',jsonb_build_object(
        'minimumEstimatedAchievableTargetUtilizationBps',700,
        'maximumEstimatedAchievableTargetUtilizationSpreadBps',300,
        'maxAttempts',3
      )
    )
  where mv.id=p_matrix_version_id;

  perform solver_private.validate_strategy_semantics_b4f170(
    p_matrix_version_id
  );
end;
$$;


ALTER FUNCTION "solver_private"."apply_strategy_semantics_b4f170"("p_matrix_version_id" "uuid") OWNER TO "postgres";

--
-- Name: archive_current_publication_v2("date", "uuid"[], "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."archive_current_publication_v2"("p_month" "date", "p_keep_variant_ids" "uuid"[], "p_actor" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_archived_ids uuid[];
begin
  with archived as (
    update public.published_schedules_v2 s
    set status='ARCHIVED',archived_at=now(),archived_by=p_actor
    where s.month=p_month and s.status='PUBLISHED'
    returning s.id
  )
  select coalesce(array_agg(a.id),'{}'::uuid[]) into v_archived_ids
  from archived a;

  update public.plan_variants_v2 v
  set status=case when v.selected then 'SELECTED' else 'READY' end,
    published_at=null
  where v.status='PUBLISHED'
    and exists(
      select 1 from public.published_schedule_variants_v2 sv
      where sv.schedule_id=any(v_archived_ids) and sv.variant_id=v.id
    )
    and not (v.id=any(coalesce(p_keep_variant_ids,'{}'::uuid[])));
end;
$$;


ALTER FUNCTION "solver_private"."archive_current_publication_v2"("p_month" "date", "p_keep_variant_ids" "uuid"[], "p_actor" "uuid") OWNER TO "postgres";

--
-- Name: assert_configuration_v2(boolean, "text"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."assert_configuration_v2"("p_condition" boolean, "p_error" "text") RETURNS boolean
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO ''
    AS $$
begin
  if not coalesce(p_condition,false) then
    raise exception '%',coalesce(nullif(p_error,''),'INVALID_SOLVER_CONFIGURATION');
  end if;
  return true;
end;
$$;


ALTER FUNCTION "solver_private"."assert_configuration_v2"("p_condition" boolean, "p_error" "text") OWNER TO "postgres";

--
-- Name: assert_employment_pay_rate_period_uat_v1("uuid", "date", "date", "date", "date"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."assert_employment_pay_rate_period_uat_v1"("p_employee_id" "uuid", "p_employment_start" "date", "p_employment_end" "date", "p_rate_valid_from" "date", "p_rate_valid_to" "date") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if p_employee_id is null then
    raise exception 'EMPLOYEE_REQUIRED';
  end if;

  -- A non-null rate start selects the rate -> employment direction.
  if p_rate_valid_from is not null then
    if (p_employment_start is not null
        and p_rate_valid_from < p_employment_start)
      or (p_employment_end is not null and (
        p_rate_valid_from > p_employment_end
        or p_rate_valid_to is null
        or p_rate_valid_to > p_employment_end
      )) then
      raise exception 'PAY_RATE_OUTSIDE_EMPLOYMENT';
    end if;
    return;
  end if;

  -- A null rate start selects the employment -> all stored rates direction.
  -- Inactive rows are deliberate history and must remain internally valid too.
  if exists(
    select 1
    from public.employee_pay_rates_v2 rate
    where rate.employee_id = p_employee_id
      and (
        (p_employment_start is not null
          and rate.valid_from < p_employment_start)
        or (p_employment_end is not null and (
          rate.valid_from > p_employment_end
          or rate.valid_to is null
          or rate.valid_to > p_employment_end
        ))
      )
  ) then
    raise exception 'EMPLOYMENT_DATES_CONFLICT_PAY_RATES';
  end if;
end;
$$;


ALTER FUNCTION "solver_private"."assert_employment_pay_rate_period_uat_v1"("p_employee_id" "uuid", "p_employment_start" "date", "p_employment_end" "date", "p_rate_valid_from" "date", "p_rate_valid_to" "date") OWNER TO "postgres";

--
-- Name: assert_materialized_variant_metadata_v2("uuid", "jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."assert_materialized_variant_metadata_v2"("p_variant_id" "uuid", "p_snapshot" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_invalid bigint;
begin
  with slots as (
    select s.value item,s.value->>'slotId' slot_id
    from jsonb_array_elements(coalesce(p_snapshot->'slots','[]'::jsonb)) s
  )
  select count(*) into v_invalid
  from public.plan_assignments_v2 pa
  left join slots slot on slot.slot_id=pa.slot_key
  left join public.plan_shifts_v2 sh on sh.id=pa.shift_id
  where pa.variant_id=p_variant_id and (
    slot.slot_id is null
    or sh.id is null
    or sh.variant_id is distinct from pa.variant_id
    or sh.slot_group_key is distinct from slot.item->>'occurrenceId'
    or sh.shift_template_id is distinct from
      nullif(slot.item->>'shiftTemplateId','')::uuid
    or sh.location_id is distinct from nullif(slot.item->>'locationId','')::uuid
    or sh.shift_date is distinct from nullif(slot.item->>'date','')::date
    or sh.starts_at is distinct from nullif(slot.item->>'start','')::timestamptz
    or sh.ends_at is distinct from nullif(slot.item->>'end','')::timestamptz
    or pa.role_id is distinct from nullif(slot.item->>'roleId','')::uuid
    or array(
      select ad.duty_id::text
      from public.plan_assignment_duties_v2 ad
      where ad.assignment_id=pa.id
      order by ad.duty_id::text
    ) is distinct from array(
      select duty.value
      from jsonb_array_elements_text(
        coalesce(slot.item->'dutyIds','[]'::jsonb)
      ) duty(value)
      order by duty.value
    )
  );
  if v_invalid>0 then
    raise exception 'VARIANT_MATERIALIZATION_METADATA_MISMATCH';
  end if;

  with slots as (
    select s.value item
    from jsonb_array_elements(coalesce(p_snapshot->'slots','[]'::jsonb)) s
  )
  select count(*) into v_invalid
  from public.plan_shifts_v2 sh
  where sh.variant_id=p_variant_id and not exists(
    select 1 from slots slot
    where sh.slot_group_key=slot.item->>'occurrenceId'
      and sh.shift_template_id=nullif(slot.item->>'shiftTemplateId','')::uuid
      and sh.location_id=nullif(slot.item->>'locationId','')::uuid
      and sh.shift_date=nullif(slot.item->>'date','')::date
      and sh.starts_at=nullif(slot.item->>'start','')::timestamptz
      and sh.ends_at=nullif(slot.item->>'end','')::timestamptz
  );
  if v_invalid>0 then
    raise exception 'VARIANT_MATERIALIZATION_METADATA_MISMATCH';
  end if;

  with expected as (
    select distinct s.value->>'occurrenceId' slot_group_key,
      nullif(s.value->>'shiftTemplateId','')::uuid shift_template_id,
      nullif(s.value->>'locationId','')::uuid location_id,
      nullif(s.value->>'date','')::date shift_date,
      nullif(s.value->>'start','')::timestamptz starts_at,
      nullif(s.value->>'end','')::timestamptz ends_at
    from jsonb_array_elements(coalesce(p_snapshot->'slots','[]'::jsonb)) s
  )
  select count(*) into v_invalid
  from expected e
  where not exists(
    select 1 from public.plan_shifts_v2 sh
    where sh.variant_id=p_variant_id
      and sh.slot_group_key=e.slot_group_key
      and sh.shift_template_id=e.shift_template_id
      and sh.location_id=e.location_id
      and sh.shift_date=e.shift_date
      and sh.starts_at=e.starts_at
      and sh.ends_at=e.ends_at
  );
  if v_invalid>0 then
    raise exception 'VARIANT_MATERIALIZATION_METADATA_MISMATCH';
  end if;
end;
$$;


ALTER FUNCTION "solver_private"."assert_materialized_variant_metadata_v2"("p_variant_id" "uuid", "p_snapshot" "jsonb") OWNER TO "postgres";

--
-- Name: assert_uat_master_persona_v2(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."assert_uat_master_persona_v2"() RETURNS "void"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.has_app_role('OWNER') then raise exception 'FORBIDDEN'; end if;
  if not exists(select 1 from public.uat_environment_controls control
    where control.control_key='ISOLATED_UAT_MASTER_PERSONA' and control.enabled)
  then raise exception 'UAT_MASTER_DISABLED'; end if;
end;
$$;


ALTER FUNCTION "solver_private"."assert_uat_master_persona_v2"() OWNER TO "postgres";

--
-- Name: assignment_is_currently_published_v2("uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."assignment_is_currently_published_v2"("p_assignment_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select exists(
    select 1 from public.plan_assignments_v2 assignment
    where assignment.id=p_assignment_id and (
      exists(select 1 from public.published_role_schedules_v2 publication
        where publication.variant_id=assignment.variant_id
          and publication.status='PUBLISHED')
      or exists(select 1 from public.published_schedule_variants_v2 link
        join public.published_schedules_v2 schedule
          on schedule.id=link.schedule_id and schedule.status='PUBLISHED'
        where link.variant_id=assignment.variant_id)
    )
  );
$$;


ALTER FUNCTION "solver_private"."assignment_is_currently_published_v2"("p_assignment_id" "uuid") OWNER TO "postgres";

--
-- Name: build_run_version_stamp_uat_v1("uuid", "text", "text"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."build_run_version_stamp_uat_v1"("p_run_id" "uuid", "p_frontend_commit" "text", "p_execution_mode" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_run public.optimization_runs_v2%rowtype;
  v_snapshot jsonb;
  v_build solver_private.solver_runtime_builds_uat_v1%rowtype;
  v_matrix_version integer;
  v_matrix_hash text;
  v_semantics text;
  v_strategy_hash text;
begin
  if p_execution_mode not in ('SERVICE','JOB') then
    raise exception 'EXECUTION_MODE_INVALID';
  end if;
  if length(coalesce(p_frontend_commit,'')) not between 1 and 500
    or p_frontend_commit !~ '^[A-Za-z0-9][A-Za-z0-9._:@/-]*$' then
    raise exception 'FRONTEND_VERSION_INVALID';
  end if;

  select r.* into v_run
  from public.optimization_runs_v2 r
  where r.id=p_run_id;
  if v_run.id is null then raise exception 'RUN_NOT_FOUND'; end if;

  select s.snapshot,mv.version,mv.content_hash,
    mv.settings->>'strategySemanticsVersion'
  into v_snapshot,v_matrix_version,v_matrix_hash,v_semantics
  from solver_private.optimization_snapshots_v2 s
  join public.matrix_versions mv on mv.id=v_run.matrix_version_id
  where s.run_id=v_run.id;

  select * into v_build
  from solver_private.solver_runtime_builds_uat_v1 b
  where b.solver_version=v_run.solver_version
    and b.execution_mode=p_execution_mode;
  if v_build.solver_version is null then
    if p_execution_mode='JOB' then
      raise exception 'JOB_RUNTIME_PROVENANCE_MISSING';
    end if;
    raise exception 'SERVICE_RUNTIME_PROVENANCE_MISSING';
  end if;
  v_strategy_hash:=solver_private.strategy_config_hash_uat_v1(v_snapshot);

  return jsonb_build_object(
    'schemaVersion',1,
    'frontendCommit',p_frontend_commit,
    'solverCommit',v_build.solver_commit,
    'solverImageDigest',v_build.solver_image_digest,
    'solverBuildId',v_build.solver_build_id,
    'gatewayVersion',null,
    'strategyConfigVersion',v_strategy_hash,
    'databaseMigrationVersion','20260824215911_uat_northflank_job_mode_provenance',
    'snapshotSchemaVersion',v_run.snapshot_schema_version,
    'executionMode',p_execution_mode,
    'northflankRunId',null,
    'dispatcherVersion',null,
    'frontend',jsonb_build_object('buildId',p_frontend_commit),
    'solver',jsonb_build_object(
      'configuredVersion',v_run.solver_version,
      'commit',v_build.solver_commit,
      'buildId',v_build.solver_build_id,
      'imageDigest',v_build.solver_image_digest
    ),
    'gateway',jsonb_build_object('deploymentId',null),
    'database',jsonb_build_object(
      'schemaVersion','20260824215911_uat_northflank_job_mode_provenance'
    ),
    'strategyConfig',jsonb_build_object(
      'matrixVersionId',v_run.matrix_version_id,
      'matrixVersion',v_matrix_version,
      'contentHash',v_matrix_hash,
      'strategySemanticsVersion',v_semantics,
      'snapshotHash',v_strategy_hash
    ),
    'snapshot',jsonb_build_object(
      'schemaVersion',v_run.snapshot_schema_version,
      'snapshotHash',v_run.snapshot_hash
    )
  );
end;
$_$;


ALTER FUNCTION "solver_private"."build_run_version_stamp_uat_v1"("p_run_id" "uuid", "p_frontend_commit" "text", "p_execution_mode" "text") OWNER TO "postgres";

--
-- Name: build_snapshot_payload_before_alpha16_v2("uuid", "date", "uuid", "uuid", "text", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."build_snapshot_payload_before_alpha16_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_month date := date_trunc('month',p_month)::date;
  v_period_end date := (date_trunc('month',p_month)+interval '1 month - 1 day')::date;
  v_matrix public.matrix_versions%rowtype;
  v_settings jsonb := '{}'::jsonb;
  v_snapshot jsonb;
  v_scenario record;
  v_seed integer;
  v_currency text;
  v_timezone text;
  v_budgets jsonb := '[]'::jsonb;
  v_external jsonb := '[]'::jsonb;
  v_baseline jsonb := '[]'::jsonb;
  v_locked jsonb := '[]'::jsonb;
  v_slot_count bigint:=0;
  v_employee_count bigint:=0;
begin
  select * into v_matrix
  from public.matrix_versions mv
  where mv.id=p_matrix_version_id and mv.schema_version>=2;
  if v_matrix.id is null then raise exception 'MATRIX_V2_NOT_FOUND'; end if;
  if coalesce(v_matrix.content_hash,'') !~ '^[0-9a-f]{64}$'
    or coalesce(v_matrix.workforce_hash,'') !~ '^[0-9a-f]{64}$' then
    raise exception 'MATRIX_V2_NOT_PUBLISHED';
  end if;

  v_currency := upper(coalesce(v_matrix.settings->>'currency',''));
  if not public.matrix_v2_is_iso_4217_currency(v_currency) then
    raise exception 'INVALID_MATRIX_CURRENCY';
  end if;
  if exists(
    select 1 from public.matrix_pay_rules_v2 p
    where p.matrix_version_id=p_matrix_version_id and p.active
      and p.currency<>v_currency
  ) or exists(
    select 1 from public.matrix_scenario_budgets_v2 b
    where b.matrix_version_id=p_matrix_version_id and b.currency<>v_currency
  ) or exists(
    select 1
    from public.employee_pay_rates_v2 r
    join public.matrix_employee_profiles_v2 profile
      on profile.matrix_version_id=p_matrix_version_id
      and profile.employee_id=r.employee_id
      and profile.active and profile.archived_at is null
      and (profile.employment_start is null or profile.employment_start<=v_period_end)
      and (profile.employment_end is null or profile.employment_end>=v_month)
    where r.active and r.valid_from<=v_period_end
      and (r.valid_to is null or r.valid_to>=v_month)
      and (p_scope_role_id is null or exists(
        select 1 from public.matrix_employee_roles_v2 role_grant
        where role_grant.matrix_version_id=p_matrix_version_id
          and role_grant.employee_id=profile.employee_id
          and role_grant.role_id=p_scope_role_id and role_grant.active
          and (role_grant.valid_from is null or role_grant.valid_from<=v_period_end)
          and (role_grant.valid_to is null or role_grant.valid_to>=v_month)
      ))
      and r.currency<>v_currency
  ) then raise exception 'MIXED_CURRENCIES_UNSUPPORTED'; end if;

  v_settings := coalesce(v_matrix.settings,'{}'::jsonb);
  for v_scenario in
    with recursive chain as (
      select s.id,s.parent_scenario_id,s.settings_overrides,0 depth
      from public.matrix_scenarios_v2 s
      where s.id=p_scenario_id and s.matrix_version_id=p_matrix_version_id
      union all
      select p.id,p.parent_scenario_id,p.settings_overrides,c.depth+1
      from public.matrix_scenarios_v2 p join chain c on c.parent_scenario_id=p.id
      where p.matrix_version_id=p_matrix_version_id and c.depth<32
    )
    select * from chain order by depth desc
  loop
    v_settings := v_settings||coalesce(v_scenario.settings_overrides,'{}'::jsonb);
  end loop;
  v_settings := (v_settings-'currency')||jsonb_build_object('currency',v_currency);
  v_timezone := nullif(v_settings->>'timezone','');
  if not exists(select 1 from pg_timezone_names where name=v_timezone) then
    raise exception 'INVALID_MATRIX_TIMEZONE';
  end if;
  if coalesce(v_settings->>'minimumRestMinutes','') !~ '^[0-9]+$'
    or (v_settings->>'minimumRestMinutes')::integer<0
    or coalesce(v_settings->>'maximumShiftsPerDay','') !~ '^[0-9]+$'
    or (v_settings->>'maximumShiftsPerDay')::integer not between 1 and 24
    or jsonb_typeof(v_settings->'missingAvailabilityMeansAvailable')<>'boolean'
    or jsonb_typeof(v_settings->'requireOptimal')<>'boolean'
  then raise exception 'INVALID_MATRIX_SETTINGS'; end if;
  if exists(
    select 1
    from public.matrix_employee_profiles_v2 profile
    cross join lateral generate_series(
      greatest(v_month,coalesce(profile.employment_start,v_month)),
      least(v_period_end,coalesce(profile.employment_end,v_period_end)),
      interval '1 day'
    ) work_day
    where profile.matrix_version_id=p_matrix_version_id
      and profile.active and profile.archived_at is null
      and (p_scope_role_id is null or exists(
        select 1 from public.matrix_employee_roles_v2 role_grant
        where role_grant.matrix_version_id=p_matrix_version_id
          and role_grant.employee_id=profile.employee_id
          and role_grant.role_id=p_scope_role_id and role_grant.active
          and (role_grant.valid_from is null
            or role_grant.valid_from<=work_day::date)
          and (role_grant.valid_to is null or role_grant.valid_to>=work_day::date)
      ))
      and not exists(
        select 1 from public.employee_pay_rates_v2 rate
        where rate.employee_id=profile.employee_id and rate.active
          and rate.valid_from<=work_day::date
          and (rate.valid_to is null or rate.valid_to>=work_day::date)
      )
  ) then raise exception 'EMPLOYEE_PAY_RATE_COVERAGE_GAP'; end if;
  v_budgets := solver_private.resolved_budgets_v2(
    v_month,p_matrix_version_id,p_scenario_id,p_scope_role_id
  );

  select coalesce(sum(d.required_count),0) into v_slot_count
  from solver_private.resolved_demand_v2(
    v_month,p_matrix_version_id,p_scenario_id,p_scope_role_id
  ) d;
  select count(*) into v_employee_count
  from public.matrix_employee_profiles_v2 profile
  where profile.matrix_version_id=p_matrix_version_id
    and profile.active and profile.archived_at is null
    and (profile.employment_start is null or profile.employment_start<=v_period_end)
    and (profile.employment_end is null or profile.employment_end>=v_month)
    and (p_scope_role_id is null or exists(
      select 1 from public.matrix_employee_roles_v2 role_grant
      where role_grant.matrix_version_id=p_matrix_version_id
        and role_grant.employee_id=profile.employee_id
        and role_grant.role_id=p_scope_role_id and role_grant.active
        and (role_grant.valid_from is null or role_grant.valid_from<=v_period_end)
        and (role_grant.valid_to is null or role_grant.valid_to>=v_month)
    ));
  if v_slot_count>25000 then raise exception 'SOLVER_CAPACITY_SLOT_LIMIT'; end if;
  if v_employee_count>5000 then raise exception 'SOLVER_CAPACITY_EMPLOYEE_LIMIT'; end if;
  if v_slot_count*v_employee_count>2000000 then
    raise exception 'SOLVER_CAPACITY_VARIABLE_LIMIT';
  end if;

  v_seed := coalesce(
    nullif(v_settings->>'randomSeed','')::integer,
    (abs(hashtextextended(p_run_id::text,0))%2147483647)::integer
  );

  select jsonb_build_object(
    'schemaVersion',2,
    'runId',p_run_id,
    'matrixVersionId',p_matrix_version_id,
    'matrixContentHash',v_matrix.content_hash,
    'workforceHash',v_matrix.workforce_hash,
    'scenarioId',p_scenario_id,
    'currency',v_currency,
    'periodStart',v_month,
    'periodEnd',v_period_end,
    'scope',jsonb_build_object('type',p_scope_type,'roleId',p_scope_role_id),
    'settings',jsonb_build_object(
      'timezone',v_timezone,
      'missingAvailabilityMeansAvailable',(v_settings->>'missingAvailabilityMeansAvailable')::boolean,
      'defaultMinimumRestMinutes',(v_settings->>'minimumRestMinutes')::integer,
      'maximumShiftsPerDay',(v_settings->>'maximumShiftsPerDay')::integer,
      'onlyMorningBeforeMinute',nullif(v_settings->>'onlyMorningBeforeMinute','')::integer,
      'onlyEveningAfterMinute',nullif(v_settings->>'onlyEveningAfterMinute','')::integer,
      'requireOptimal',(v_settings->>'requireOptimal')::boolean,
      'randomSeed',v_seed
    ),
    'strategies',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',s.id,'code',s.code,'label',s.name,'description',s.description,
        'sortOrder',ss.sort_order,
        'timeLimitSeconds',coalesce(
          nullif(ss.solver_overrides->>'maxTimeSeconds','')::integer,
          nullif(s.solver_options->>'maxTimeSeconds','')::integer,300
        ),
        'randomSeed',coalesce(
          nullif(ss.solver_overrides->>'randomSeed','')::integer,
          nullif(s.solver_options->>'randomSeed','')::integer,v_seed
        ),
        'objectiveTerms',coalesce((
          select jsonb_agg(jsonb_build_object(
            'tier',coalesce(nullif(cfg.value->>'tier','')::smallint,o.tier),
            'metric',o.metric_code,
            'weight',coalesce(nullif(cfg.value->>'weight','')::bigint,o.weight),
            'direction',case upper(coalesce(cfg.value->>'direction',o.direction))
              when 'MAXIMIZE' then 'MAX' when 'MAX' then 'MAX' else 'MIN' end,
            'tolerance',coalesce(
              nullif(cfg.value->>'tolerance','')::bigint,o.tolerance
            ),
            'parameters',o.parameters||coalesce(cfg.value->'parameters','{}'::jsonb)
          ) order by
            coalesce(nullif(cfg.value->>'tier','')::smallint,o.tier),
            o.sort_order,o.metric_code)
          from public.matrix_strategy_objectives_v2 o
          cross join lateral (select coalesce(
            ss.objective_overrides->upper(o.metric_code),'{}'::jsonb
          ) value) cfg
          where o.strategy_id=s.id and o.matrix_version_id=p_matrix_version_id
            and o.active and coalesce((cfg.value->>'active')::boolean,true)
        ),'[]'::jsonb)
      ) order by ss.sort_order,s.sort_order,s.code)
      from (
        with recursive scenario_chain as (
          select sc.id,sc.parent_scenario_id,0 depth
          from public.matrix_scenarios_v2 sc
          where sc.id=p_scenario_id and sc.matrix_version_id=p_matrix_version_id
          union all
          select parent.id,parent.parent_scenario_id,chain.depth+1
          from public.matrix_scenarios_v2 parent
          join scenario_chain chain on chain.parent_scenario_id=parent.id
          where parent.matrix_version_id=p_matrix_version_id and chain.depth<32
        ), raw_links as (
          select link.id,link.strategy_id,link.sort_order,link.active,
            link.objective_overrides,link.solver_overrides,chain.depth
          from scenario_chain chain
          join public.matrix_scenario_strategies_v2 link
            on link.scenario_id=chain.id
          where link.matrix_version_id=p_matrix_version_id
        )
        select link.strategy_id,
          (array_agg(link.sort_order order by link.depth,link.id))[1] sort_order,
          (array_agg(link.active order by link.depth,link.id))[1] active,
          solver_private.jsonb_deep_merge_array_v2(array_agg(
            link.objective_overrides order by link.depth desc,link.id
          )) objective_overrides,
          solver_private.jsonb_deep_merge_array_v2(array_agg(
            link.solver_overrides order by link.depth desc,link.id
          )) solver_overrides
        from raw_links link
        group by link.strategy_id
      ) ss
      join public.matrix_strategies_v2 s
        on s.id=ss.strategy_id and s.matrix_version_id=p_matrix_version_id
      where ss.active and s.active
    ),'[]'::jsonb),
    'roles',coalesce((
      select jsonb_agg(jsonb_build_object('id',r.id,'code',r.code,'label',r.name)
        order by r.sort_order,r.code)
      from public.matrix_roles_v2 r
      where r.matrix_version_id=p_matrix_version_id and r.active
    ),'[]'::jsonb),
    'duties',coalesce((
      select jsonb_agg(jsonb_build_object('id',d.id,'code',d.code,'label',d.name)
        order by d.sort_order,d.code)
      from public.matrix_duties_v2 d
      where d.matrix_version_id=p_matrix_version_id and d.active
    ),'[]'::jsonb),
    'locations',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',l.id,'code',l.code,'label',l.name,'timezone',l.timezone
      ) order by l.sort_order,l.code)
      from public.matrix_locations_v2 l
      where l.matrix_version_id=p_matrix_version_id and l.active
    ),'[]'::jsonb),
    'shiftTemplates',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',st.id,'locationId',st.location_id,'code',st.code,'label',st.name,
        'startTime',to_char(st.starts_at,'HH24:MI'),
        'endTime',to_char(st.ends_at,'HH24:MI'),
        'endsNextDay',st.ends_next_day,'weekdays',to_jsonb(st.day_mask)
      ) order by st.sort_order,st.code)
      from public.matrix_shift_templates_v2 st
      join public.matrix_locations_v2 l on l.id=st.location_id and l.active
      where st.matrix_version_id=p_matrix_version_id and st.active
    ),'[]'::jsonb),
    'demand',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',d.demand_id,'shiftTemplateId',d.shift_template_id,
        'roleId',d.role_id,'dutyIds',to_jsonb(d.duty_ids),
        'requiredCount',d.required_count,'dates',jsonb_build_array(d.work_date)
      ) order by d.starts_at,d.location_id,d.role_id,d.demand_id)
      from solver_private.resolved_demand_v2(
        v_month,p_matrix_version_id,p_scenario_id,p_scope_role_id
      ) d
    ),'[]'::jsonb),
    'slots',coalesce((
      select jsonb_agg(jsonb_build_object(
        'slotId',d.work_date::text||'|'||d.shift_template_id::text||'|'||
          d.role_id::text||'|'||coalesce(array_to_string(d.duty_ids,','),'-')||'|'||
          d.demand_id::text||'|'||seat.seat_index::text,
        'demandId',d.demand_id,
        'occurrenceId',d.work_date::text||'|'||d.shift_template_id::text,
        'seatIndex',seat.seat_index,'date',d.work_date,
        'shiftTemplateId',d.shift_template_id,'locationId',d.location_id,
        'roleId',d.role_id,'dutyIds',to_jsonb(d.duty_ids),
        'start',d.starts_at,'end',d.ends_at,'durationMinutes',d.duration_minutes
      ) order by d.starts_at,d.location_id,d.role_id,
        d.work_date::text||'|'||d.shift_template_id::text||'|'||d.role_id::text||'|'||
        coalesce(array_to_string(d.duty_ids,','),'-')||'|'||d.demand_id::text||'|'||seat.seat_index::text)
      from solver_private.resolved_demand_v2(
        v_month,p_matrix_version_id,p_scenario_id,p_scope_role_id
      ) d
      cross join lateral generate_series(1,d.required_count) seat(seat_index)
    ),'[]'::jsonb),
    'employees',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',profile.employee_id,
        'roleIds',coalesce((select jsonb_agg(er.role_id::text order by er.role_id::text)
          from public.matrix_employee_roles_v2 er
          where er.matrix_version_id=p_matrix_version_id
            and er.employee_id=profile.employee_id and er.active
            and (er.valid_from is null or er.valid_from<=v_period_end)
            and (er.valid_to is null or er.valid_to>=v_month)),'[]'::jsonb),
        'roleGrants',coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'roleId',er.role_id,'validFrom',er.valid_from,'validTo',er.valid_to
          )) order by er.role_id::text,er.valid_from nulls first,er.id)
          from public.matrix_employee_roles_v2 er
          where er.matrix_version_id=p_matrix_version_id
            and er.employee_id=profile.employee_id and er.active
            and (er.valid_from is null or er.valid_from<=v_period_end)
            and (er.valid_to is null or er.valid_to>=v_month)),'[]'::jsonb),
        'dutyIds',coalesce((select jsonb_agg(distinct ed.duty_id::text order by ed.duty_id::text)
          from public.matrix_employee_duties_v2 ed
          where ed.matrix_version_id=p_matrix_version_id
            and ed.employee_id=profile.employee_id and ed.active
            and ed.role_id is null and ed.location_id is null
            and (ed.valid_from is null or ed.valid_from<=v_period_end)
            and (ed.valid_to is null or ed.valid_to>=v_month)),'[]'::jsonb),
        'dutyGrants',coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'dutyId',ed.duty_id,'roleId',ed.role_id,'locationId',ed.location_id,
            'validFrom',ed.valid_from,'validTo',ed.valid_to
          )) order by ed.duty_id::text,ed.role_id::text nulls first,
            ed.location_id::text nulls first,ed.valid_from nulls first,ed.id)
          from public.matrix_employee_duties_v2 ed
          where ed.matrix_version_id=p_matrix_version_id
            and ed.employee_id=profile.employee_id and ed.active
            and (ed.valid_from is null or ed.valid_from<=v_period_end)
            and (ed.valid_to is null or ed.valid_to>=v_month)),'[]'::jsonb),
        'locationIds',coalesce((select jsonb_agg(el.location_id::text order by el.location_id::text)
          from public.matrix_employee_locations_v2 el
          where el.matrix_version_id=p_matrix_version_id
            and el.employee_id=profile.employee_id and el.active
            and el.standard_allowed
            and (el.valid_from is null or el.valid_from<=v_period_end)
            and (el.valid_to is null or el.valid_to>=v_month)),'[]'::jsonb),
        'locationGrants',coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'locationId',el.location_id,'standardAllowed',el.standard_allowed,
            'overtimeAllowed',el.overtime_allowed,'validFrom',el.valid_from,
            'validTo',el.valid_to
          )) order by el.location_id::text,el.valid_from nulls first,el.id)
          from public.matrix_employee_locations_v2 el
          where el.matrix_version_id=p_matrix_version_id
            and el.employee_id=profile.employee_id and el.active
            and (el.valid_from is null or el.valid_from<=v_period_end)
            and (el.valid_to is null or el.valid_to>=v_month)),'[]'::jsonb),
        'homeLocationIds',coalesce((select jsonb_agg(el.location_id::text order by el.location_id::text)
          from public.matrix_employee_locations_v2 el
          where el.matrix_version_id=p_matrix_version_id
            and el.employee_id=profile.employee_id
            and el.active and el.home_location),'[]'::jsonb),
        -- Legacy fields are only a compatibility fallback when no dated v2
        -- period covers a slot; they must never borrow a future period's rate.
        'baseHourlyRateMinor',round(e.hourly_rate*100)::bigint,
        'contractCode',coalesce(hr.contract_type,'OTHER'),
        'payRatePeriods',coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'validFrom',pr.valid_from,'validTo',pr.valid_to,
            'baseRateMinor',pr.base_rate_minor,
            'contractCode',coalesce(pr.contract_type,hr.contract_type,'OTHER')
          )) order by pr.valid_from,pr.id)
          from public.employee_pay_rates_v2 pr
          where pr.employee_id=profile.employee_id and pr.active
            and pr.valid_from<=v_period_end
            and (pr.valid_to is null or pr.valid_to>=v_month)),'[]'::jsonb),
        'employmentStart',profile.employment_start,
        'employmentEnd',profile.employment_end,
        'nominalMonthlyMinutes',profile.nominal_monthly_minutes,
        'maximumMonthlyMinutes',profile.maximum_monthly_minutes,
        'maximumWeeklyMinutes',profile.maximum_weekly_minutes,
        'maximumShiftsPerDay',(v_settings->>'maximumShiftsPerDay')::integer,
        'maximumConsecutiveDays',profile.maximum_consecutive_days,
        'minimumRestMinutes',coalesce(
          profile.minimum_rest_minutes,(v_settings->>'minimumRestMinutes')::integer
        ),
        'noWeekends',profile.no_weekends,
        'onlyMorningBeforeMinute',case when profile.only_morning then
          nullif(v_settings->>'onlyMorningBeforeMinute','')::integer else null end,
        'onlyEveningAfterMinute',case when profile.only_evening then
          nullif(v_settings->>'onlyEveningAfterMinute','')::integer else null end,
        'preferredShiftTemplateIds',coalesce((
          select jsonb_agg(st.id::text order by st.id::text)
          from public.matrix_shift_templates_v2 st
          where st.matrix_version_id=p_matrix_version_id and st.active
            and profile.preferred_shift_code is not null
            and st.code=profile.preferred_shift_code
        ),'[]'::jsonb),
        'preferredLocationIds',coalesce((
          select jsonb_agg(preferred.location_id order by preferred.location_id)
          from (
            select distinct ml.id::text location_id
            from public.employee_preferences ep
            join public.matrix_locations_v2 ml
              on ml.matrix_version_id=p_matrix_version_id and ml.active
              and (
                ml.id=case
                  when coalesce(
                    ep.preference_value->>'locationId',
                    ep.preference_value->>'location_id'
                  ) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
                  then coalesce(
                    ep.preference_value->>'locationId',
                    ep.preference_value->>'location_id'
                  )::uuid
                  else null
                end
                or upper(ml.code)=upper(coalesce(
                  ep.preference_value->>'locationCode',
                  ep.preference_value->>'location',
                  ep.preference_value->>'code'
                ))
              )
            where ep.employee_id=profile.employee_id and ep.status='ACTIVE'
              and ep.preference_type='PREFERRED_LOCATION'
              and ep.valid_from<=v_period_end and ep.valid_to>=v_month
          ) preferred
        ),'[]'::jsonb),
        'softDayOffDates',coalesce((
          select jsonb_agg(gs::date order by gs::date)
          from public.employee_preferences ep
          cross join lateral generate_series(ep.valid_from,ep.valid_to,interval '1 day') gs
          where ep.employee_id=profile.employee_id and ep.status='ACTIVE'
            and ep.preference_type='OTHER'
            and ep.preference_value->>'kind'='DAY_OFF'
            and ep.valid_from<=v_period_end and ep.valid_to>=v_month
        ),'[]'::jsonb)
      ) order by profile.employee_no)
      from public.matrix_employee_profiles_v2 profile
      join public.employees e on e.id=profile.employee_id
      left join public.employee_hr_profiles hr
        on hr.employee_id=profile.employee_id
      where profile.matrix_version_id=p_matrix_version_id
        and profile.active and profile.archived_at is null
        and (profile.employment_start is null
          or profile.employment_start<=v_period_end)
        and (profile.employment_end is null or profile.employment_end>=v_month)
        and (p_scope_role_id is null or exists(
          select 1 from public.matrix_employee_roles_v2 er
          where er.matrix_version_id=p_matrix_version_id
            and er.employee_id=profile.employee_id
            and er.role_id=p_scope_role_id and er.active
            and (er.valid_from is null or er.valid_from<=v_period_end)
            and (er.valid_to is null or er.valid_to>=v_month)
        ))
    ),'[]'::jsonb),
    'availabilityWindows',coalesce((
      select jsonb_agg(jsonb_build_object(
        'employeeId',c.employee_id,'start',lower(c.time_range),'end',upper(c.time_range)
      ) order by c.employee_id,lower(c.time_range))
      from public.employee_time_constraints_v2 c
      where c.status='ACTIVE' and c.constraint_kind='AVAILABLE_WINDOW'
        and c.time_range && tstzrange(v_month::timestamp at time zone v_timezone,
          (v_period_end+1)::timestamp at time zone v_timezone,'[)')
        and exists(
          select 1 from public.matrix_employee_profiles_v2 profile
          where profile.matrix_version_id=p_matrix_version_id
            and profile.employee_id=c.employee_id
            and profile.active and profile.archived_at is null
            and (profile.employment_start is null or profile.employment_start<=v_period_end)
            and (profile.employment_end is null or profile.employment_end>=v_month)
            and (p_scope_role_id is null or exists(
              select 1 from public.matrix_employee_roles_v2 role_grant
              where role_grant.matrix_version_id=p_matrix_version_id
                and role_grant.employee_id=profile.employee_id
                and role_grant.role_id=p_scope_role_id and role_grant.active
                and (role_grant.valid_from is null or role_grant.valid_from<=v_period_end)
                and (role_grant.valid_to is null or role_grant.valid_to>=v_month)
            ))
        )
    ),'[]'::jsonb),
    'hardBlocks',coalesce((
      select jsonb_agg(jsonb_build_object(
        'employeeId',c.employee_id,'start',lower(c.time_range),'end',upper(c.time_range),
        'kind',c.constraint_kind,'source',c.source
      ) order by c.employee_id,lower(c.time_range))
      from public.employee_time_constraints_v2 c
      where c.status='ACTIVE' and c.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
        and c.time_range && tstzrange(v_month::timestamp at time zone v_timezone,
          (v_period_end+1)::timestamp at time zone v_timezone,'[)')
        and exists(
          select 1 from public.matrix_employee_profiles_v2 profile
          where profile.matrix_version_id=p_matrix_version_id
            and profile.employee_id=c.employee_id
            and profile.active and profile.archived_at is null
            and (profile.employment_start is null or profile.employment_start<=v_period_end)
            and (profile.employment_end is null or profile.employment_end>=v_month)
            and (p_scope_role_id is null or exists(
              select 1 from public.matrix_employee_roles_v2 role_grant
              where role_grant.matrix_version_id=p_matrix_version_id
                and role_grant.employee_id=profile.employee_id
                and role_grant.role_id=p_scope_role_id and role_grant.active
                and (role_grant.valid_from is null or role_grant.valid_from<=v_period_end)
                and (role_grant.valid_to is null or role_grant.valid_to>=v_month)
            ))
        )
    ),'[]'::jsonb),
    'externalAssignments','[]'::jsonb,
    'lockedAssignments','[]'::jsonb,
    'baselineAssignments','[]'::jsonb,
    'payRules',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',pr.id,'calculationType',pr.calculation_method,
        'currency',pr.currency,
        'values',jsonb_strip_nulls(jsonb_build_object(
          'amountMinor',coalesce(ov.amount_minor,pr.amount_minor),
          'rateMinorPerHour',coalesce(ov.rate_minor_per_hour,pr.rate_minor_per_hour),
          'percentBasisPoints',coalesce(ov.percent_basis_points,pr.percent_basis_points),
          'multiplierBasisPoints',coalesce(ov.multiplier_basis_points,pr.multiplier_basis_points),
          'thresholdMinutes',pr.threshold_minutes
        )),
        'conditions',coalesce(pr.condition_expression->'conditions','[]'::jsonb)
          ||coalesce((select jsonb_build_array(jsonb_build_object(
              'field','role_id','operator','IN','value',jsonb_agg(x.role_id::text order by x.role_id::text)
            )) from public.matrix_pay_rule_roles_v2 x where x.pay_rule_id=pr.id
              having count(*)>0),'[]'::jsonb)
          ||coalesce((select jsonb_build_array(jsonb_build_object(
              'field','duty_ids','operator',
              case when bool_or(x.match_mode='ALL') then 'CONTAINS_ALL' else 'CONTAINS_ANY' end,
              'value',jsonb_agg(x.duty_id::text order by x.duty_id::text)
            )) from public.matrix_pay_rule_duties_v2 x where x.pay_rule_id=pr.id
              having count(*)>0),'[]'::jsonb)
          ||coalesce((select jsonb_build_array(jsonb_build_object(
              'field','location_id','operator','IN',
              'value',jsonb_agg(x.location_id::text order by x.location_id::text)
            )) from public.matrix_pay_rule_locations_v2 x where x.pay_rule_id=pr.id
              having count(*)>0),'[]'::jsonb)
          ||coalesce((select jsonb_build_array(jsonb_build_object(
              'field','shift_template_id','operator','IN',
              'value',jsonb_agg(x.shift_template_id::text order by x.shift_template_id::text)
            )) from public.matrix_pay_rule_shifts_v2 x where x.pay_rule_id=pr.id
              having count(*)>0),'[]'::jsonb),
        'stackingGroup',pr.stacking_group,'stackingMode',pr.stacking_mode,
        'priority',pr.priority,'active',pr.active and coalesce(ov.enabled,true),
        'effectiveFrom',pr.valid_from,'effectiveTo',pr.valid_to,
        'dayMask',to_jsonb(pr.day_mask),'localStart',pr.local_start,'localEnd',pr.local_end,
        'roleIds',coalesce((select jsonb_agg(x.role_id::text order by x.role_id::text)
          from public.matrix_pay_rule_roles_v2 x where x.pay_rule_id=pr.id),'[]'::jsonb),
        'dutyIds',coalesce((select jsonb_agg(x.duty_id::text order by x.duty_id::text)
          from public.matrix_pay_rule_duties_v2 x where x.pay_rule_id=pr.id),'[]'::jsonb),
        'locationIds',coalesce((select jsonb_agg(x.location_id::text order by x.location_id::text)
          from public.matrix_pay_rule_locations_v2 x where x.pay_rule_id=pr.id),'[]'::jsonb),
        'shiftTemplateIds',coalesce((select jsonb_agg(x.shift_template_id::text order by x.shift_template_id::text)
          from public.matrix_pay_rule_shifts_v2 x where x.pay_rule_id=pr.id),'[]'::jsonb)
      ) order by pr.priority,pr.code)
      from public.matrix_pay_rules_v2 pr
      left join lateral (
        with recursive scenario_chain as (
          select sc.id,sc.parent_scenario_id,0 depth
          from public.matrix_scenarios_v2 sc
          where sc.id=p_scenario_id and sc.matrix_version_id=p_matrix_version_id
          union all
          select parent.id,parent.parent_scenario_id,chain.depth+1
          from public.matrix_scenarios_v2 parent
          join scenario_chain chain on chain.parent_scenario_id=parent.id
          where parent.matrix_version_id=p_matrix_version_id and chain.depth<32
        )
        select
          (array_agg(override.enabled order by chain.depth,override.id))[1]
            enabled,
          (array_agg(override.amount_minor order by chain.depth,override.id)
            filter(where override.amount_minor is not null))[1] amount_minor,
          (array_agg(override.rate_minor_per_hour order by chain.depth,override.id)
            filter(where override.rate_minor_per_hour is not null))[1]
            rate_minor_per_hour,
          (array_agg(override.percent_basis_points order by chain.depth,override.id)
            filter(where override.percent_basis_points is not null))[1]
            percent_basis_points,
          (array_agg(override.multiplier_basis_points order by chain.depth,override.id)
            filter(where override.multiplier_basis_points is not null))[1]
            multiplier_basis_points
        from scenario_chain chain
        join public.matrix_scenario_pay_rule_overrides_v2 override
          on override.scenario_id=chain.id and override.pay_rule_id=pr.id
        where override.matrix_version_id=p_matrix_version_id
      ) ov on true
      where pr.matrix_version_id=p_matrix_version_id and pr.active
    ),'[]'::jsonb),
    'budgets',v_budgets,
    'budget',coalesce((
      select jsonb_build_object(
        'amountMinor',(b.value->>'amountMinor')::bigint,
        'hard',coalesce((b.value->>'hard')::boolean,false),
        'currency',v_currency
      )
      from jsonb_array_elements(v_budgets) b
      where nullif(b.value->>'locationId','') is null
        and nullif(b.value->>'roleId','') is null
        and nullif(b.value->>'dutyId','') is null
      limit 1
    ),jsonb_build_object(
      'amountMinor',null,'hard',false,'currency',v_currency
    ))
  ) into v_snapshot;
  if jsonb_array_length(v_snapshot->'strategies')>32 then
    raise exception 'SOLVER_CAPACITY_STRATEGY_LIMIT';
  end if;

  -- Previous selected v2 assignments and the latest legacy plan are projected
  -- onto deterministic slot IDs. They remain soft baseline hints unless they
  -- were explicitly locked. For ROLE runs, assignments owned by other roles
  -- are hard external time blocks and prevent cross-role collisions.
  with chosen_legacy_plan as (
    select p.id from public.plans p where p.month=v_month
    order by case p.status when 'PUBLISHED' then 1 when 'READY' then 2 else 3 end,
      p.version desc,p.created_at desc limit 1
  ), legacy_numbered as (
    select a.employee_id,a.locked,sh.starts_at,sh.ends_at,sh.shift_date,
      mt.id shift_template_id,mr.id role_id,
      row_number() over(
        partition by sh.shift_date,mt.id,mr.id order by a.locked desc,a.id
      ) seat_number
    from chosen_legacy_plan cp
    join public.shifts sh on sh.plan_id=cp.id
    join public.assignments a on a.shift_id=sh.id
    join public.locations old_location on old_location.id=sh.location_id
    join public.matrix_locations_v2 ml
      on ml.matrix_version_id=p_matrix_version_id and ml.code=old_location.code::text
    join public.matrix_shift_templates_v2 mt
      on mt.matrix_version_id=p_matrix_version_id and mt.location_id=ml.id
      and mt.code=sh.shift_code
    join public.matrix_roles_v2 mr
      on mr.matrix_version_id=p_matrix_version_id and mr.code=a.assigned_role::text
  ), snapshot_slots as (
    select slot.value->>'slotId' slot_id,(slot.value->>'date')::date shift_date,
      (slot.value->>'shiftTemplateId')::uuid shift_template_id,
      (slot.value->>'roleId')::uuid role_id,
      row_number() over(
        partition by (slot.value->>'date')::date,
          (slot.value->>'shiftTemplateId')::uuid,(slot.value->>'roleId')::uuid
        order by (slot.value->>'seatIndex')::integer,slot.value->>'slotId'
      ) seat_number
    from jsonb_array_elements(v_snapshot->'slots') slot
  ), legacy_projection as (
    select ss.slot_id,l.employee_id,l.locked,1 source_priority
    from legacy_numbered l join snapshot_slots ss
      on ss.shift_date=l.shift_date and ss.shift_template_id=l.shift_template_id
      and ss.role_id=l.role_id and ss.seat_number=l.seat_number
  ), selected_v2 as (
    select pa.slot_key slot_id,pa.employee_id,pa.locked,2 source_priority,
      coalesce(v.selected_at,v.created_at) selected_at
    from public.plan_assignments_v2 pa
    join public.plan_variants_v2 v on v.id=pa.variant_id and v.selected
    join public.optimization_runs_v2 r on r.id=v.run_id
    where r.month=v_month and r.matrix_version_id=p_matrix_version_id
      and r.request_engine='ORTOOLS_V2'
      and exists(select 1 from snapshot_slots ss where ss.slot_id=pa.slot_key)
  ), combined as (
    select slot_id,employee_id,locked,source_priority,null::timestamptz selected_at
    from legacy_projection
    union all
    select slot_id,employee_id,locked,source_priority,selected_at from selected_v2
  ), deduplicated as (
    select distinct on (slot_id) slot_id,employee_id,locked
    from combined order by slot_id,source_priority desc,selected_at desc nulls last
  ), scoped_baseline as (
    select d.*,exists(
      select 1 from jsonb_array_elements(v_snapshot->'employees') employee
      where employee.value->>'id'=d.employee_id::text
    ) employee_present
    from deduplicated d
  )
  select
    coalesce(jsonb_agg(jsonb_build_object('slotId',slot_id,'employeeId',employee_id)
      order by slot_id) filter(where employee_present),'[]'::jsonb),
    coalesce(jsonb_agg(jsonb_build_object('slotId',slot_id,'employeeId',employee_id)
      order by slot_id) filter(where locked),'[]'::jsonb)
  into v_baseline,v_locked from scoped_baseline;
  if exists(
    select 1 from jsonb_array_elements(v_locked) lock_item
    where not exists(
      select 1 from jsonb_array_elements(v_snapshot->'employees') employee
      where employee.value->>'id'=lock_item.value->>'employeeId'
    )
  ) then raise exception 'LOCKED_ASSIGNMENT_EMPLOYEE_OUTSIDE_SNAPSHOT'; end if;

  -- Assignments outside the generated scope stay hard. For ROLE runs that
  -- means the other roles in the same month. For every scope it also includes
  -- adjacent-month assignments, so rest and consecutive-day rules are not
  -- accidentally reset at midnight on the first/last day of the month.
  with target_role as (
    select code from public.matrix_roles_v2 where id=p_scope_role_id
  ), ranked_legacy_plans as (
    select p.id,p.month,row_number() over(
      partition by p.month
      order by case p.status when 'PUBLISHED' then 1 when 'READY' then 2 else 3 end,
        p.version desc,p.created_at desc
    ) plan_rank
    from public.plans p
    where p.month between (v_month-interval '1 month')::date
      and (v_month+interval '1 month')::date
  ), latest_selected_role_variants as (
    select ranked.variant_id
    from (
      select v.id variant_id,
        row_number() over(
          partition by r.scope_role_id
          order by coalesce(v.selected_at,v.created_at) desc,v.id desc
        ) selection_rank
      from public.plan_variants_v2 v
      join public.optimization_runs_v2 r on r.id=v.run_id
      where p_scope_type='ROLE'
        and r.month=v_month
        and r.matrix_version_id=p_matrix_version_id
        and r.scenario_id=p_scenario_id
        and r.request_engine='ORTOOLS_V2'
        and r.scope_type='ROLE'
        and r.scope_role_id is distinct from p_scope_role_id
        and v.selected
    ) ranked
    where ranked.selection_rank=1
  ), blocks as (
    select a.employee_id,sh.starts_at,sh.ends_at
    from ranked_legacy_plans cp
    join public.shifts sh on sh.plan_id=cp.id
    join public.assignments a on a.shift_id=sh.id
    left join target_role tr on true
    where cp.plan_rank=1 and (
      sh.shift_date<v_month
      or sh.shift_date>v_period_end
      or (p_scope_type='ROLE' and a.assigned_role::text<>tr.code)
    )
    union
    select pa.employee_id,ps.starts_at,ps.ends_at
    from public.plan_assignments_v2 pa
    join public.plan_shifts_v2 ps on ps.id=pa.shift_id
    join public.plan_variants_v2 v on v.id=pa.variant_id
    join public.optimization_runs_v2 r on r.id=v.run_id
    where r.month between (v_month-interval '1 month')::date
        and (v_month+interval '1 month')::date
      and (
        (
          v.status='PUBLISHED'
          and (
            ps.shift_date<v_month
            or ps.shift_date>v_period_end
          )
        )
        or (
          p_scope_type='ROLE'
          and r.month=v_month
          and v.id in (select x.variant_id from latest_selected_role_variants x)
          and pa.role_id is distinct from p_scope_role_id
        )
      )
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'employeeId',block.employee_id,'start',block.starts_at,'end',block.ends_at
  ) order by block.employee_id,block.starts_at,block.ends_at),'[]'::jsonb)
  into v_external
  from blocks block
  where exists(
    select 1 from jsonb_array_elements(v_snapshot->'employees') employee
    where employee.value->>'id'=block.employee_id::text
  );
  v_snapshot := jsonb_set(v_snapshot,'{baselineAssignments}',v_baseline,true);
  v_snapshot := jsonb_set(v_snapshot,'{lockedAssignments}',v_locked,true);
  v_snapshot := jsonb_set(v_snapshot,'{externalAssignments}',v_external,true);

  return v_snapshot;
end;
$_$;


ALTER FUNCTION "solver_private"."build_snapshot_payload_before_alpha16_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") OWNER TO "postgres";

--
-- Name: build_snapshot_payload_before_authoritative_external_uat_v1("uuid", "date", "uuid", "uuid", "text", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."build_snapshot_payload_before_authoritative_external_uat_v1"("p_matrix_version_id" "uuid", "p_month" "date", "p_scenario_id" "uuid", "p_scope_role_id" "uuid", "p_scope_type" "text", "p_actor" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'solver_private', 'pg_temp'
    AS $$
declare v_snapshot jsonb;v_end date:=(p_month+interval '1 month - 1 day')::date;v_rules jsonb;
begin
  v_snapshot:=solver_private.build_snapshot_payload_before_b4f88_uat_v1(p_matrix_version_id,p_month,p_scenario_id,p_scope_role_id,p_scope_type,p_actor);
  select coalesce(jsonb_agg(rule_payload),'[]'::jsonb) into v_rules from (
    select jsonb_build_object('id','employer-cost:'||c.id,'calculationType',c.calculation_method,
      'values',jsonb_strip_nulls(jsonb_build_object('percentBasisPoints',c.percent_basis_points,'rateMinorPerHour',c.rate_minor_per_hour,'amountMinor',c.amount_minor)),
      'conditions',case when c.contract_type is null then '[]'::jsonb else jsonb_build_array(jsonb_build_object('field','contract_code','operator','EQ','value',c.contract_type)) end,
      'stackingGroup','employer-cost:'||c.logical_id,'stackingMode','STACK','priority',100,'active',true,
      'effectiveFrom',c.valid_from,'effectiveTo',c.valid_to,'costCategory','EMPLOYER_ONCOST') rule_payload
    from public.employer_cost_components_v2 c where c.active and c.valid_from<=v_end and coalesce(c.valid_to,'infinity'::date)>=p_month
    union all
    select jsonb_build_object('id','incident-rate:'||r.id,'calculationType','BASE_RATE_OVERRIDE',
      'values',jsonb_build_object('rateMinorPerHour',r.approved_rate_minor),
      'conditions',jsonb_build_array(jsonb_build_object('field','employee_id','operator','EQ','value',r.employee_id::text)),
      'stackingGroup','incident-rate:'||r.employee_id,'stackingMode','FIRST','priority',0,'active',true,
      'effectiveFrom',greatest(r.valid_from,p_month),'effectiveTo',least(r.valid_to,v_end),'costCategory','WAGE')
    from public.recovery_incident_rate_revisions_v2 r join public.recovery_incidents_v2 i on i.id=r.incident_id
    where r.status='APPROVED' and i.month=p_month and r.valid_from<=v_end and r.valid_to>=p_month
  ) payloads;
  return jsonb_set(v_snapshot,'{payRules}',coalesce(v_snapshot->'payRules','[]'::jsonb)||v_rules,true);
end $$;


ALTER FUNCTION "solver_private"."build_snapshot_payload_before_authoritative_external_uat_v1"("p_matrix_version_id" "uuid", "p_month" "date", "p_scenario_id" "uuid", "p_scope_role_id" "uuid", "p_scope_type" "text", "p_actor" "uuid") OWNER TO "postgres";

--
-- Name: build_snapshot_payload_before_b4_settings_v2("uuid", "date", "uuid", "uuid", "text", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."build_snapshot_payload_before_b4_settings_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_snapshot jsonb;
  v_slots jsonb;
begin
  v_snapshot:=solver_private.build_snapshot_payload_before_occurrence_id_v2(
    p_run_id,p_month,p_matrix_version_id,p_scenario_id,
    p_scope_type,p_scope_role_id
  );

  select coalesce(jsonb_agg(
    slot.value||jsonb_build_object(
      'occurrenceId',concat_ws('|',
        slot.value->>'date',slot.value->>'shiftTemplateId'
      )
    ) order by slot.ordinality
  ),'[]'::jsonb)
  into v_slots
  from jsonb_array_elements(coalesce(v_snapshot->'slots','[]'::jsonb))
    with ordinality slot(value,ordinality);

  return jsonb_set(v_snapshot,'{slots}',v_slots,true);
end;
$$;


ALTER FUNCTION "solver_private"."build_snapshot_payload_before_b4_settings_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") OWNER TO "postgres";

--
-- Name: build_snapshot_payload_before_b4f165("uuid", "date", "uuid", "uuid", "text", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."build_snapshot_payload_before_b4f165"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_snapshot jsonb;
  v_month date := date_trunc('month',p_month)::date;
  v_period_end date := (date_trunc('month',p_month)+interval '1 month - 1 day')::date;
  v_external jsonb := '[]'::jsonb;
begin
  v_snapshot := solver_private.build_snapshot_payload_before_authoritative_external_uat_v1(
    p_run_id,p_month,p_matrix_version_id,p_scenario_id,p_scope_type,p_scope_role_id
  );

  with raw as (
    select value->>'employeeId' employee_id,
      (value->>'start')::timestamptz starts_at,
      (value->>'end')::timestamptz ends_at
    from jsonb_array_elements(coalesce(v_snapshot->'externalAssignments','[]'::jsonb))
  ), authoritative as (
    select distinct raw.employee_id,raw.starts_at,raw.ends_at
    from raw
    where raw.starts_at::date between v_month-6 and v_period_end+6
      and (
        raw.starts_at::date between v_month and v_period_end
        or exists (
          select 1
          from public.published_role_schedules_v2 publication
          join public.plan_assignments_v2 assignment
            on assignment.variant_id=publication.variant_id
          join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
          where publication.status='PUBLISHED'
            and assignment.employee_id::text=raw.employee_id
            and shift_row.starts_at=raw.starts_at and shift_row.ends_at=raw.ends_at
        )
        or exists (
          select 1
          from public.published_schedules_v2 publication
          join public.published_schedule_variants_v2 member
            on member.schedule_id=publication.id
          join public.plan_assignments_v2 assignment
            on assignment.variant_id=member.variant_id
          join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
          where publication.status='PUBLISHED'
            and assignment.employee_id::text=raw.employee_id
            and shift_row.starts_at=raw.starts_at and shift_row.ends_at=raw.ends_at
        )
        or exists (
          select 1
          from public.plans plan_row
          join public.shifts shift_row on shift_row.plan_id=plan_row.id
          join public.assignments assignment on assignment.shift_id=shift_row.id
          where plan_row.status='PUBLISHED'
            and assignment.employee_id::text=raw.employee_id
            and shift_row.starts_at=raw.starts_at and shift_row.ends_at=raw.ends_at
        )
      )
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'employeeId',employee_id,'start',starts_at,'end',ends_at
  ) order by employee_id,starts_at,ends_at),'[]'::jsonb)
  into v_external from authoritative;

  return jsonb_set(v_snapshot,'{externalAssignments}',v_external,true);
end;
$$;


ALTER FUNCTION "solver_private"."build_snapshot_payload_before_b4f165"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") OWNER TO "postgres";

--
-- Name: FUNCTION "build_snapshot_payload_before_b4f165"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid"); Type: COMMENT; Schema: solver_private; Owner: postgres
--

COMMENT ON FUNCTION "solver_private"."build_snapshot_payload_before_b4f165"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") IS 'Builds solver snapshots with current-month cross-category blocks and only authoritative adjacent-month publications; archived variants never constrain a new studio.';


--
-- Name: build_snapshot_payload_before_b4f169("uuid", "date", "uuid", "uuid", "text", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."build_snapshot_payload_before_b4f169"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_snapshot jsonb;
  v_strategies jsonb;
  v_settings jsonb;
begin
  v_snapshot:=solver_private.build_snapshot_payload_before_b4f165(
    p_run_id,p_month,p_matrix_version_id,p_scenario_id,p_scope_type,p_scope_role_id
  );
  select mv.settings into v_settings
  from public.matrix_versions mv
  where mv.id=p_matrix_version_id;

  select coalesce(jsonb_agg(
    item.value||jsonb_strip_nulls(jsonb_build_object(
      'strategySemanticsVersion',v_settings->>'strategySemanticsVersion',
      'mandatoryProductGuards',v_settings->'mandatoryProductGuards'
    )) order by item.ordinality
  ),'[]'::jsonb)
  into v_strategies
  from jsonb_array_elements(v_snapshot->'strategies')
    with ordinality item(value,ordinality)
  ;

  return jsonb_set(v_snapshot,'{strategies}',v_strategies,true);
end;
$$;


ALTER FUNCTION "solver_private"."build_snapshot_payload_before_b4f169"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") OWNER TO "postgres";

--
-- Name: build_snapshot_payload_before_b4f170("uuid", "date", "uuid", "uuid", "text", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."build_snapshot_payload_before_b4f170"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_snapshot jsonb;
  v_seed_document jsonb;
  v_seed_strategies jsonb;
  v_runtime_strategies jsonb;
  v_matrix_settings jsonb;
  v_semantics_version text;
  v_business_seed integer;
begin
  v_snapshot:=solver_private.build_snapshot_payload_before_b4f169(
    p_run_id,p_month,p_matrix_version_id,p_scenario_id,p_scope_type,p_scope_role_id
  );
  select mv.settings into v_matrix_settings
  from public.matrix_versions mv
  where mv.id=p_matrix_version_id;
  v_semantics_version:=v_matrix_settings->>'strategySemanticsVersion';

  select coalesce(jsonb_agg(item.value-'randomSeed' order by item.ordinality),'[]'::jsonb)
  into v_seed_strategies
  from jsonb_array_elements(v_snapshot->'strategies')
    with ordinality item(value,ordinality);

  v_seed_document:=v_snapshot-'runId';
  v_seed_document:=jsonb_set(
    v_seed_document,
    '{settings}',
    coalesce(v_seed_document->'settings','{}'::jsonb)-'randomSeed',
    true
  );
  v_seed_document:=jsonb_set(
    v_seed_document,'{strategies}',v_seed_strategies,true
  );
  v_business_seed:=(
    hashtextextended(v_seed_document::text,169) & 2147483647
  )::integer;

  v_snapshot:=jsonb_set(
    v_snapshot,
    '{settings}',
    coalesce(v_snapshot->'settings','{}'::jsonb)||jsonb_build_object(
      'randomSeed',v_business_seed,
      'randomSeedSource','BUSINESS_SNAPSHOT_B4F169_V1'
    ),
    true
  );

  if v_semantics_version='B4F169_V1' then
    perform solver_private.validate_strategy_semantics_b4f169(
      p_matrix_version_id
    );
    select coalesce(jsonb_agg(
      jsonb_set(
        item.value,'{randomSeed}',to_jsonb(v_business_seed),true
      ) order by item.ordinality
    ),'[]'::jsonb)
    into v_runtime_strategies
    from jsonb_array_elements(v_snapshot->'strategies')
      with ordinality item(value,ordinality);
    v_snapshot:=jsonb_set(
      v_snapshot,'{strategies}',v_runtime_strategies,true
    );
    v_snapshot:=jsonb_set(
      v_snapshot,
      '{settings,fairnessQualityGate}',
      v_matrix_settings->'fairnessQualityGate',
      true
    );
  end if;

  return v_snapshot;
end;
$$;


ALTER FUNCTION "solver_private"."build_snapshot_payload_before_b4f170"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") OWNER TO "postgres";

--
-- Name: build_snapshot_payload_before_b4f88_uat_v1("uuid", "date", "uuid", "uuid", "text", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."build_snapshot_payload_before_b4f88_uat_v1"("p_matrix_version_id" "uuid", "p_month" "date", "p_scenario_id" "uuid", "p_scope_role_id" "uuid", "p_scope_type" "text", "p_actor" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_snapshot jsonb;v_period_end date:=(p_month+interval '1 month - 1 day')::date;
begin
  v_snapshot:=solver_private.build_snapshot_payload_before_b4f91_uat_v1(p_matrix_version_id,p_month,p_scenario_id,p_scope_role_id,p_scope_type,p_actor);
  return jsonb_set(v_snapshot,'{workPatterns}',coalesce((select jsonb_agg(jsonb_build_object(
    'id',p.id,'employeeId',p.employee_id,'weekday',p.weekday,'localStart',p.local_start,
    'localEnd',p.local_end,'roleId',p.role_id,'locationId',p.location_id,
    'enforcement',p.enforcement,'validFrom',p.valid_from,'validTo',p.valid_to
  ) order by p.employee_id,p.weekday,p.local_start)
  from public.employee_weekly_work_patterns_v2 p
  where p.active and p.valid_from<=v_period_end and (p.valid_to is null or p.valid_to>=p_month)
    and exists(select 1 from jsonb_array_elements(coalesce(v_snapshot->'employees','[]'::jsonb)) e where e->>'id'=p.employee_id::text)),'[]'::jsonb),true);
end;$$;


ALTER FUNCTION "solver_private"."build_snapshot_payload_before_b4f88_uat_v1"("p_matrix_version_id" "uuid", "p_month" "date", "p_scenario_id" "uuid", "p_scope_role_id" "uuid", "p_scope_type" "text", "p_actor" "uuid") OWNER TO "postgres";

--
-- Name: build_snapshot_payload_before_b4f91_uat_v1("uuid", "date", "uuid", "uuid", "text", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."build_snapshot_payload_before_b4f91_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_snapshot jsonb;
  v_employees jsonb := '[]'::jsonb;
  v_employee jsonb;
  v_grants jsonb;
begin
  v_snapshot := solver_private.build_snapshot_payload_before_explicit_roles_uat_v1(
    p_run_id,
    p_month,
    p_matrix_version_id,
    p_scenario_id,
    p_scope_type,
    p_scope_role_id
  );

  for v_employee in
    select value
    from jsonb_array_elements(coalesce(v_snapshot->'employees','[]'::jsonb))
  loop
    select coalesce(jsonb_agg(grant_row.value order by grant_row.ordinality),'[]'::jsonb)
    into v_grants
    from jsonb_array_elements(coalesce(v_employee->'roleGrants','[]'::jsonb))
      with ordinality grant_row(value,ordinality)
    where not (grant_row.value ? 'sourceDutyId');

    if jsonb_array_length(v_grants) > 0 then
      v_employee := jsonb_set(v_employee,'{roleGrants}',v_grants,true);
      v_employee := jsonb_set(
        v_employee,
        '{roleIds}',
        coalesce((
          select jsonb_agg(distinct grant_row.value->>'roleId')
          from jsonb_array_elements(v_grants) grant_row(value)
        ),'[]'::jsonb),
        true
      );
      v_employees := v_employees || jsonb_build_array(v_employee);
    end if;
  end loop;

  return jsonb_set(v_snapshot,'{employees}',v_employees,true);
end;
$$;


ALTER FUNCTION "solver_private"."build_snapshot_payload_before_b4f91_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") OWNER TO "postgres";

--
-- Name: FUNCTION "build_snapshot_payload_before_b4f91_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid"); Type: COMMENT; Schema: solver_private; Owner: postgres
--

COMMENT ON FUNCTION "solver_private"."build_snapshot_payload_before_b4f91_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") IS 'UAT snapshot: role eligibility comes only from explicit employee role grants; duties remain capabilities.';


--
-- Name: build_snapshot_payload_before_categories_uat_v1("uuid", "date", "uuid", "uuid", "text", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."build_snapshot_payload_before_categories_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_snapshot jsonb; v_tiers integer; v_employees jsonb;
begin
  v_snapshot:=solver_private.build_snapshot_payload_before_b4_settings_v2(
    p_run_id,p_month,p_matrix_version_id,p_scenario_id,p_scope_type,p_scope_role_id);
  select greatest(0,least(2,coalesce((matrix.settings->>'standbyTiersPerRoleDay')::integer,2)))
    into v_tiers from public.matrix_versions matrix where matrix.id=p_matrix_version_id;
  select coalesce(jsonb_agg(employee.value||jsonb_build_object(
    'nominalMonthlyMinutes',coalesce(profile.nominal_monthly_minutes,0),
    'maximumMonthlyMinutes',coalesce(profile.maximum_monthly_minutes,0),
    'maximumWeeklyMinutes',coalesce(profile.maximum_weekly_minutes,0),
    'maximumConsecutiveDays',coalesce(profile.maximum_consecutive_days,31),
    'minimumRestMinutes',coalesce(profile.minimum_rest_minutes,
      nullif(matrix.settings->>'minimumRestMinutes','')::integer,0)
  ) order by employee.ordinality),'[]'::jsonb) into v_employees
  from jsonb_array_elements(coalesce(v_snapshot->'employees','[]'::jsonb))
    with ordinality employee(value,ordinality)
  join public.matrix_employee_profiles_v2 profile
    on profile.matrix_version_id=p_matrix_version_id
   and profile.employee_id=(employee.value->>'id')::uuid
  join public.matrix_versions matrix on matrix.id=p_matrix_version_id;
  v_snapshot:=jsonb_set(v_snapshot,'{employees}',v_employees,true);
  return jsonb_set(v_snapshot,'{settings,standbyTiersPerRoleDay}',to_jsonb(coalesce(v_tiers,2)),true);
end;
$$;


ALTER FUNCTION "solver_private"."build_snapshot_payload_before_categories_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") OWNER TO "postgres";

--
-- Name: build_snapshot_payload_before_category_employee_guard_uat_v1("uuid", "date", "uuid", "uuid", "text", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."build_snapshot_payload_before_category_employee_guard_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_snapshot jsonb;
  v_employees jsonb := '[]'::jsonb;
  v_employee jsonb;
begin
  v_snapshot := solver_private.build_snapshot_payload_before_overtime_uat_v1(
    p_run_id, p_month, p_matrix_version_id, p_scenario_id,
    p_scope_type, p_scope_role_id
  );
  for v_employee in
    select value from jsonb_array_elements(coalesce(v_snapshot->'employees', '[]'::jsonb))
  loop
    v_employee := v_employee || jsonb_build_object(
      'overtimePolicy', coalesce((
        select profile.overtime_policy
        from public.matrix_employee_profiles_v2 profile
        where profile.matrix_version_id = p_matrix_version_id
          and profile.employee_id = (v_employee->>'id')::uuid
      ), 'NEVER')
    );
    v_employees := v_employees || jsonb_build_array(v_employee);
  end loop;
  v_snapshot:=jsonb_set(v_snapshot, '{employees}', v_employees, true);
  if exists(select 1 from jsonb_array_elements(v_employees) employee
      where employee.value->>'overtimePolicy' in ('ALLOWED','APPROVAL_REQUIRED'))
    and not exists(select 1 from jsonb_array_elements(coalesce(v_snapshot->'payRules','[]'::jsonb)) rule
      where upper(rule.value->>'calculationType')='MONTHLY_THRESHOLD_PER_HOUR'
        and rule.value->'values'->>'thresholdSource'='EMPLOYEE_NOMINAL') then
    raise exception 'OVERTIME_PAY_RULE_MISSING';
  end if;
  return v_snapshot;
end;
$$;


ALTER FUNCTION "solver_private"."build_snapshot_payload_before_category_employee_guard_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") OWNER TO "postgres";

--
-- Name: build_snapshot_payload_before_explicit_roles_uat_v1("uuid", "date", "uuid", "uuid", "text", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."build_snapshot_payload_before_explicit_roles_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_snapshot jsonb;
  v_employee_ids jsonb;
  v_key text;
begin
  v_snapshot:=solver_private.build_snapshot_payload_before_category_employee_guard_uat_v1(
    p_run_id,p_month,p_matrix_version_id,p_scenario_id,p_scope_type,p_scope_role_id
  );

  if coalesce(v_snapshot->'scope'->>'type','')<>'CATEGORY' then
    return v_snapshot;
  end if;

  select coalesce(jsonb_agg(employee.value->>'id'),'[]'::jsonb)
  into v_employee_ids
  from jsonb_array_elements(coalesce(v_snapshot->'employees','[]'::jsonb)) employee;

  for v_key in
    select unnest(array[
      'availabilityWindows',
      'hardBlocks',
      'externalAssignments',
      'lockedAssignments',
      'baselineAssignments'
    ]::text[])
  loop
    v_snapshot:=jsonb_set(
      v_snapshot,
      array[v_key],
      coalesce((
        select jsonb_agg(item.value order by item.ordinality)
        from jsonb_array_elements(coalesce(v_snapshot->v_key,'[]'::jsonb))
          with ordinality item(value,ordinality)
        where item.value->>'employeeId' in (
          select jsonb_array_elements_text(v_employee_ids)
        )
      ),'[]'::jsonb),
      true
    );
  end loop;

  return v_snapshot;
end;
$$;


ALTER FUNCTION "solver_private"."build_snapshot_payload_before_explicit_roles_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") OWNER TO "postgres";

--
-- Name: build_snapshot_payload_before_final_contract_v2("uuid", "date", "uuid", "uuid", "text", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."build_snapshot_payload_before_final_contract_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_snapshot jsonb;
  v_slots jsonb:='[]'::jsonb;
  v_slot_ids jsonb:='{}'::jsonb;
  v_baseline jsonb:='[]'::jsonb;
  v_locked jsonb:='[]'::jsonb;
begin
  v_snapshot:=solver_private.build_snapshot_payload_before_final_slot_contract_v2(
    p_run_id,p_month,p_matrix_version_id,p_scenario_id,
    p_scope_type,p_scope_role_id
  );

  with normalized_slots as (
    select slot.ordinality,slot.value,
      case
        when jsonb_array_length(coalesce(slot.value->'dutyIds','[]'::jsonb))=0
        then concat_ws('|',
          slot.value->>'date',
          slot.value->>'shiftTemplateId',
          slot.value->>'roleId',
          '-',
          slot.value->>'demandId',
          slot.value->>'seatIndex'
        )
        else slot.value->>'slotId'
      end canonical_slot_id
    from jsonb_array_elements(coalesce(v_snapshot->'slots','[]'::jsonb))
      with ordinality slot(value,ordinality)
  )
  select
    coalesce(jsonb_agg(
      jsonb_set(value,'{slotId}',to_jsonb(canonical_slot_id),true)
      order by ordinality
    ),'[]'::jsonb),
    coalesce(jsonb_object_agg(value->>'slotId',canonical_slot_id),'{}'::jsonb)
  into v_slots,v_slot_ids
  from normalized_slots;

  if exists(
    select 1 from jsonb_array_elements(v_slots) slot
    group by slot.value->>'slotId' having count(*)>1
  ) then
    raise exception 'DUPLICATE_CANONICAL_SLOT_ID';
  end if;

  select coalesce(jsonb_agg(
    jsonb_set(
      assignment.value,'{slotId}',
      to_jsonb(coalesce(
        v_slot_ids->>(assignment.value->>'slotId'),
        assignment.value->>'slotId'
      )),true
    ) order by assignment.ordinality
  ),'[]'::jsonb)
  into v_baseline
  from jsonb_array_elements(coalesce(
    v_snapshot->'baselineAssignments','[]'::jsonb
  )) with ordinality assignment(value,ordinality);

  select coalesce(jsonb_agg(
    jsonb_set(
      assignment.value,'{slotId}',
      to_jsonb(coalesce(
        v_slot_ids->>(assignment.value->>'slotId'),
        assignment.value->>'slotId'
      )),true
    ) order by assignment.ordinality
  ),'[]'::jsonb)
  into v_locked
  from jsonb_array_elements(coalesce(
    v_snapshot->'lockedAssignments','[]'::jsonb
  )) with ordinality assignment(value,ordinality);

  v_snapshot:=jsonb_set(v_snapshot,'{slots}',v_slots,true);
  v_snapshot:=jsonb_set(v_snapshot,'{baselineAssignments}',v_baseline,true);
  v_snapshot:=jsonb_set(v_snapshot,'{lockedAssignments}',v_locked,true);
  return v_snapshot;
end;
$$;


ALTER FUNCTION "solver_private"."build_snapshot_payload_before_final_contract_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") OWNER TO "postgres";

--
-- Name: build_snapshot_payload_before_final_slot_contract_v2("uuid", "date", "uuid", "uuid", "text", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."build_snapshot_payload_before_final_slot_contract_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_month date := date_trunc('month',p_month)::date;
  v_period_end date := (date_trunc('month',p_month)+interval '1 month - 1 day')::date;
  v_matrix public.matrix_versions%rowtype;
  v_settings jsonb := '{}'::jsonb;
  v_snapshot jsonb;
  v_scenario record;
  v_seed integer;
  v_currency text;
  v_timezone text;
  v_budgets jsonb := '[]'::jsonb;
  v_external jsonb := '[]'::jsonb;
  v_baseline jsonb := '[]'::jsonb;
  v_locked jsonb := '[]'::jsonb;
  v_slot_count bigint:=0;
  v_employee_count bigint:=0;
begin
  select * into v_matrix
  from public.matrix_versions mv
  where mv.id=p_matrix_version_id and mv.schema_version>=2;
  if v_matrix.id is null then raise exception 'MATRIX_V2_NOT_FOUND'; end if;
  if coalesce(v_matrix.content_hash,'') !~ '^[0-9a-f]{64}$'
    or coalesce(v_matrix.workforce_hash,'') !~ '^[0-9a-f]{64}$' then
    raise exception 'MATRIX_V2_NOT_PUBLISHED';
  end if;

  v_currency := upper(coalesce(v_matrix.settings->>'currency',''));
  if not public.matrix_v2_is_iso_4217_currency(v_currency) then
    raise exception 'INVALID_MATRIX_CURRENCY';
  end if;
  if exists(
    select 1 from public.matrix_pay_rules_v2 p
    where p.matrix_version_id=p_matrix_version_id and p.active
      and p.currency<>v_currency
  ) or exists(
    select 1 from public.matrix_scenario_budgets_v2 b
    where b.matrix_version_id=p_matrix_version_id and b.currency<>v_currency
  ) or exists(
    select 1
    from public.employee_pay_rates_v2 r
    join public.matrix_employee_profiles_v2 profile
      on profile.matrix_version_id=p_matrix_version_id
      and profile.employee_id=r.employee_id
      and profile.active and profile.archived_at is null
      and (profile.employment_start is null or profile.employment_start<=v_period_end)
      and (profile.employment_end is null or profile.employment_end>=v_month)
    where r.active and r.valid_from<=v_period_end
      and (r.valid_to is null or r.valid_to>=v_month)
      and (p_scope_role_id is null or exists(
        select 1 from public.matrix_employee_roles_v2 role_grant
        where role_grant.matrix_version_id=p_matrix_version_id
          and role_grant.employee_id=profile.employee_id
          and role_grant.role_id=p_scope_role_id and role_grant.active
          and (role_grant.valid_from is null or role_grant.valid_from<=v_period_end)
          and (role_grant.valid_to is null or role_grant.valid_to>=v_month)
      ))
      and r.currency<>v_currency
  ) then raise exception 'MIXED_CURRENCIES_UNSUPPORTED'; end if;

  v_settings := coalesce(v_matrix.settings,'{}'::jsonb);
  for v_scenario in
    with recursive chain as (
      select s.id,s.parent_scenario_id,s.settings_overrides,0 depth
      from public.matrix_scenarios_v2 s
      where s.id=p_scenario_id and s.matrix_version_id=p_matrix_version_id
      union all
      select p.id,p.parent_scenario_id,p.settings_overrides,c.depth+1
      from public.matrix_scenarios_v2 p join chain c on c.parent_scenario_id=p.id
      where p.matrix_version_id=p_matrix_version_id and c.depth<32
    )
    select * from chain order by depth desc
  loop
    v_settings := v_settings||coalesce(v_scenario.settings_overrides,'{}'::jsonb);
  end loop;
  v_settings := (v_settings-'currency')||jsonb_build_object('currency',v_currency);
  v_timezone := nullif(v_settings->>'timezone','');
  if not exists(select 1 from pg_timezone_names where name=v_timezone) then
    raise exception 'INVALID_MATRIX_TIMEZONE';
  end if;
  if coalesce(v_settings->>'minimumRestMinutes','') !~ '^[0-9]+$'
    or (v_settings->>'minimumRestMinutes')::integer<0
    or coalesce(v_settings->>'maximumShiftsPerDay','') !~ '^[0-9]+$'
    or (v_settings->>'maximumShiftsPerDay')::integer not between 1 and 24
    or jsonb_typeof(v_settings->'missingAvailabilityMeansAvailable')<>'boolean'
    or jsonb_typeof(v_settings->'requireOptimal')<>'boolean'
  then raise exception 'INVALID_MATRIX_SETTINGS'; end if;
  if exists(
    select 1
    from public.matrix_employee_profiles_v2 profile
    cross join lateral generate_series(
      greatest(v_month,coalesce(profile.employment_start,v_month)),
      least(v_period_end,coalesce(profile.employment_end,v_period_end)),
      interval '1 day'
    ) work_day
    where profile.matrix_version_id=p_matrix_version_id
      and profile.active and profile.archived_at is null
      and (p_scope_role_id is null or exists(
        select 1 from public.matrix_employee_roles_v2 role_grant
        where role_grant.matrix_version_id=p_matrix_version_id
          and role_grant.employee_id=profile.employee_id
          and role_grant.role_id=p_scope_role_id and role_grant.active
          and (role_grant.valid_from is null
            or role_grant.valid_from<=work_day::date)
          and (role_grant.valid_to is null or role_grant.valid_to>=work_day::date)
      ))
      and not exists(
        select 1 from public.employee_pay_rates_v2 rate
        where rate.employee_id=profile.employee_id and rate.active
          and rate.valid_from<=work_day::date
          and (rate.valid_to is null or rate.valid_to>=work_day::date)
      )
  ) then raise exception 'EMPLOYEE_PAY_RATE_COVERAGE_GAP'; end if;
  v_budgets := solver_private.resolved_budgets_v2(
    v_month,p_matrix_version_id,p_scenario_id,p_scope_role_id
  );

  select coalesce(sum(d.required_count),0) into v_slot_count
  from solver_private.resolved_demand_v2(
    v_month,p_matrix_version_id,p_scenario_id,p_scope_role_id
  ) d;
  select count(*) into v_employee_count
  from public.matrix_employee_profiles_v2 profile
  where profile.matrix_version_id=p_matrix_version_id
    and profile.active and profile.archived_at is null
    and (profile.employment_start is null or profile.employment_start<=v_period_end)
    and (profile.employment_end is null or profile.employment_end>=v_month)
    and (p_scope_role_id is null or exists(
      select 1 from public.matrix_employee_roles_v2 role_grant
      where role_grant.matrix_version_id=p_matrix_version_id
        and role_grant.employee_id=profile.employee_id
        and role_grant.role_id=p_scope_role_id and role_grant.active
        and (role_grant.valid_from is null or role_grant.valid_from<=v_period_end)
        and (role_grant.valid_to is null or role_grant.valid_to>=v_month)
    ));
  if v_slot_count>25000 then raise exception 'SOLVER_CAPACITY_SLOT_LIMIT'; end if;
  if v_employee_count>5000 then raise exception 'SOLVER_CAPACITY_EMPLOYEE_LIMIT'; end if;
  if v_slot_count*v_employee_count>2000000 then
    raise exception 'SOLVER_CAPACITY_VARIABLE_LIMIT';
  end if;

  v_seed := coalesce(
    nullif(v_settings->>'randomSeed','')::integer,
    (abs(hashtextextended(p_run_id::text,0))%2147483647)::integer
  );

  select jsonb_build_object(
    'schemaVersion',2,
    'runId',p_run_id,
    'matrixVersionId',p_matrix_version_id,
    'matrixContentHash',v_matrix.content_hash,
    'workforceHash',v_matrix.workforce_hash,
    'scenarioId',p_scenario_id,
    'currency',v_currency,
    'periodStart',v_month,
    'periodEnd',v_period_end,
    'scope',jsonb_build_object('type',p_scope_type,'roleId',p_scope_role_id),
    'settings',jsonb_build_object(
      'timezone',v_timezone,
      'missingAvailabilityMeansAvailable',(v_settings->>'missingAvailabilityMeansAvailable')::boolean,
      'defaultMinimumRestMinutes',(v_settings->>'minimumRestMinutes')::integer,
      'maximumShiftsPerDay',(v_settings->>'maximumShiftsPerDay')::integer,
      'onlyMorningBeforeMinute',nullif(v_settings->>'onlyMorningBeforeMinute','')::integer,
      'onlyEveningAfterMinute',nullif(v_settings->>'onlyEveningAfterMinute','')::integer,
      'standbyTiersPerRoleDay',2,
      'requireOptimal',(v_settings->>'requireOptimal')::boolean,
      'randomSeed',v_seed
    ),
    'strategies',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',s.id,'code',s.code,'label',s.name,'description',s.description,
        'sortOrder',ss.sort_order,
        'timeLimitSeconds',coalesce(
          nullif(ss.solver_overrides->>'maxTimeSeconds','')::integer,
          nullif(s.solver_options->>'maxTimeSeconds','')::integer,300
        ),
        'randomSeed',coalesce(
          nullif(ss.solver_overrides->>'randomSeed','')::integer,
          nullif(s.solver_options->>'randomSeed','')::integer,v_seed
        ),
        'objectiveTerms',coalesce((
          select jsonb_agg(jsonb_build_object(
            'tier',coalesce(nullif(cfg.value->>'tier','')::smallint,o.tier),
            'metric',o.metric_code,
            'weight',coalesce(nullif(cfg.value->>'weight','')::bigint,o.weight),
            'direction',case upper(coalesce(cfg.value->>'direction',o.direction))
              when 'MAXIMIZE' then 'MAX' when 'MAX' then 'MAX' else 'MIN' end,
            'tolerance',coalesce(
              nullif(cfg.value->>'tolerance','')::bigint,o.tolerance
            ),
            'parameters',o.parameters||coalesce(cfg.value->'parameters','{}'::jsonb)
          ) order by
            coalesce(nullif(cfg.value->>'tier','')::smallint,o.tier),
            o.sort_order,o.metric_code)
          from public.matrix_strategy_objectives_v2 o
          cross join lateral (select coalesce(
            ss.objective_overrides->upper(o.metric_code),'{}'::jsonb
          ) value) cfg
          where o.strategy_id=s.id and o.matrix_version_id=p_matrix_version_id
            and o.active and coalesce((cfg.value->>'active')::boolean,true)
        ),'[]'::jsonb)
      ) order by ss.sort_order,s.sort_order,s.code)
      from (
        with recursive scenario_chain as (
          select sc.id,sc.parent_scenario_id,0 depth
          from public.matrix_scenarios_v2 sc
          where sc.id=p_scenario_id and sc.matrix_version_id=p_matrix_version_id
          union all
          select parent.id,parent.parent_scenario_id,chain.depth+1
          from public.matrix_scenarios_v2 parent
          join scenario_chain chain on chain.parent_scenario_id=parent.id
          where parent.matrix_version_id=p_matrix_version_id and chain.depth<32
        ), raw_links as (
          select link.id,link.strategy_id,link.sort_order,link.active,
            link.objective_overrides,link.solver_overrides,chain.depth
          from scenario_chain chain
          join public.matrix_scenario_strategies_v2 link
            on link.scenario_id=chain.id
          where link.matrix_version_id=p_matrix_version_id
        )
        select link.strategy_id,
          (array_agg(link.sort_order order by link.depth,link.id))[1] sort_order,
          (array_agg(link.active order by link.depth,link.id))[1] active,
          solver_private.jsonb_deep_merge_array_v2(array_agg(
            link.objective_overrides order by link.depth desc,link.id
          )) objective_overrides,
          solver_private.jsonb_deep_merge_array_v2(array_agg(
            link.solver_overrides order by link.depth desc,link.id
          )) solver_overrides
        from raw_links link
        group by link.strategy_id
      ) ss
      join public.matrix_strategies_v2 s
        on s.id=ss.strategy_id and s.matrix_version_id=p_matrix_version_id
      where ss.active and s.active
    ),'[]'::jsonb),
    'roles',coalesce((
      select jsonb_agg(jsonb_build_object('id',r.id,'code',r.code,'label',r.name)
        order by r.sort_order,r.code)
      from public.matrix_roles_v2 r
      where r.matrix_version_id=p_matrix_version_id and r.active
    ),'[]'::jsonb),
    'duties',coalesce((
      select jsonb_agg(jsonb_build_object('id',d.id,'code',d.code,'label',d.name)
        order by d.sort_order,d.code)
      from public.matrix_duties_v2 d
      where d.matrix_version_id=p_matrix_version_id and d.active
    ),'[]'::jsonb),
    'locations',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',l.id,'code',l.code,'label',l.name,'timezone',l.timezone
      ) order by l.sort_order,l.code)
      from public.matrix_locations_v2 l
      where l.matrix_version_id=p_matrix_version_id and l.active
    ),'[]'::jsonb),
    'shiftTemplates',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',st.id,'locationId',st.location_id,'code',st.code,'label',st.name,
        'startTime',to_char(st.starts_at,'HH24:MI'),
        'endTime',to_char(st.ends_at,'HH24:MI'),
        'endsNextDay',st.ends_next_day,'weekdays',to_jsonb(st.day_mask)
      ) order by st.sort_order,st.code)
      from public.matrix_shift_templates_v2 st
      join public.matrix_locations_v2 l on l.id=st.location_id and l.active
      where st.matrix_version_id=p_matrix_version_id and st.active
    ),'[]'::jsonb),
    'demand',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',d.demand_id,'shiftTemplateId',d.shift_template_id,
        'roleId',d.role_id,'dutyIds',to_jsonb(d.duty_ids),
        'requiredCount',d.required_count,'dates',jsonb_build_array(d.work_date)
      ) order by d.starts_at,d.location_id,d.role_id,d.demand_id)
      from solver_private.resolved_demand_v2(
        v_month,p_matrix_version_id,p_scenario_id,p_scope_role_id
      ) d
    ),'[]'::jsonb),
    'slots',coalesce((
      select jsonb_agg(jsonb_build_object(
        'slotId',d.work_date::text||'|'||d.shift_template_id::text||'|'||
          d.role_id::text||'|'||coalesce(array_to_string(d.duty_ids,','),'-')||'|'||
          d.demand_id::text||'|'||seat.seat_index::text,
        'demandId',d.demand_id,
        'occurrenceId',d.work_date::text||'|'||d.shift_template_id::text,
        'seatIndex',seat.seat_index,'date',d.work_date,
        'shiftTemplateId',d.shift_template_id,'locationId',d.location_id,
        'roleId',d.role_id,'dutyIds',to_jsonb(d.duty_ids),
        'start',d.starts_at,'end',d.ends_at,'durationMinutes',d.duration_minutes
      ) order by d.starts_at,d.location_id,d.role_id,
        d.work_date::text||'|'||d.shift_template_id::text||'|'||d.role_id::text||'|'||
        coalesce(array_to_string(d.duty_ids,','),'-')||'|'||d.demand_id::text||'|'||seat.seat_index::text)
      from solver_private.resolved_demand_v2(
        v_month,p_matrix_version_id,p_scenario_id,p_scope_role_id
      ) d
      cross join lateral generate_series(1,d.required_count) seat(seat_index)
    ),'[]'::jsonb),
    'employees',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',profile.employee_id,
        'roleIds',coalesce((select jsonb_agg(er.role_id::text order by er.role_id::text)
          from public.matrix_employee_roles_v2 er
          where er.matrix_version_id=p_matrix_version_id
            and er.employee_id=profile.employee_id and er.active
            and (er.valid_from is null or er.valid_from<=v_period_end)
            and (er.valid_to is null or er.valid_to>=v_month)),'[]'::jsonb),
        'roleGrants',coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'roleId',er.role_id,'validFrom',er.valid_from,'validTo',er.valid_to
          )) order by er.role_id::text,er.valid_from nulls first,er.id)
          from public.matrix_employee_roles_v2 er
          where er.matrix_version_id=p_matrix_version_id
            and er.employee_id=profile.employee_id and er.active
            and (er.valid_from is null or er.valid_from<=v_period_end)
            and (er.valid_to is null or er.valid_to>=v_month)),'[]'::jsonb),
        'dutyIds',coalesce((select jsonb_agg(distinct ed.duty_id::text order by ed.duty_id::text)
          from public.matrix_employee_duties_v2 ed
          where ed.matrix_version_id=p_matrix_version_id
            and ed.employee_id=profile.employee_id and ed.active
            and ed.role_id is null and ed.location_id is null
            and (ed.valid_from is null or ed.valid_from<=v_period_end)
            and (ed.valid_to is null or ed.valid_to>=v_month)),'[]'::jsonb),
        'dutyGrants',coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'dutyId',ed.duty_id,'roleId',ed.role_id,'locationId',ed.location_id,
            'validFrom',ed.valid_from,'validTo',ed.valid_to
          )) order by ed.duty_id::text,ed.role_id::text nulls first,
            ed.location_id::text nulls first,ed.valid_from nulls first,ed.id)
          from public.matrix_employee_duties_v2 ed
          where ed.matrix_version_id=p_matrix_version_id
            and ed.employee_id=profile.employee_id and ed.active
            and (ed.valid_from is null or ed.valid_from<=v_period_end)
            and (ed.valid_to is null or ed.valid_to>=v_month)),'[]'::jsonb),
        'locationIds',coalesce((select jsonb_agg(el.location_id::text order by el.location_id::text)
          from public.matrix_employee_locations_v2 el
          where el.matrix_version_id=p_matrix_version_id
            and el.employee_id=profile.employee_id and el.active
            and el.standard_allowed
            and (el.valid_from is null or el.valid_from<=v_period_end)
            and (el.valid_to is null or el.valid_to>=v_month)),'[]'::jsonb),
        'locationGrants',coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'locationId',el.location_id,'standardAllowed',el.standard_allowed,
            'overtimeAllowed',el.overtime_allowed,'validFrom',el.valid_from,
            'validTo',el.valid_to
          )) order by el.location_id::text,el.valid_from nulls first,el.id)
          from public.matrix_employee_locations_v2 el
          where el.matrix_version_id=p_matrix_version_id
            and el.employee_id=profile.employee_id and el.active
            and (el.valid_from is null or el.valid_from<=v_period_end)
            and (el.valid_to is null or el.valid_to>=v_month)),'[]'::jsonb),
        'homeLocationIds',coalesce((select jsonb_agg(el.location_id::text order by el.location_id::text)
          from public.matrix_employee_locations_v2 el
          where el.matrix_version_id=p_matrix_version_id
            and el.employee_id=profile.employee_id
            and el.active and el.home_location),'[]'::jsonb),
        -- Legacy fields are only a compatibility fallback when no dated v2
        -- period covers a slot; they must never borrow a future period's rate.
        'baseHourlyRateMinor',round(e.hourly_rate*100)::bigint,
        'contractCode',coalesce(hr.contract_type,'OTHER'),
        'payRatePeriods',coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'validFrom',pr.valid_from,'validTo',pr.valid_to,
            'baseRateMinor',pr.base_rate_minor,
            'contractCode',coalesce(pr.contract_type,hr.contract_type,'OTHER')
          )) order by pr.valid_from,pr.id)
          from public.employee_pay_rates_v2 pr
          where pr.employee_id=profile.employee_id and pr.active
            and pr.valid_from<=v_period_end
            and (pr.valid_to is null or pr.valid_to>=v_month)),'[]'::jsonb),
        'employmentStart',profile.employment_start,
        'employmentEnd',profile.employment_end,
        'nominalMonthlyMinutes',profile.nominal_monthly_minutes,
        'maximumMonthlyMinutes',profile.maximum_monthly_minutes,
        'maximumWeeklyMinutes',profile.maximum_weekly_minutes,
        'maximumShiftsPerDay',(v_settings->>'maximumShiftsPerDay')::integer,
        'maximumConsecutiveDays',profile.maximum_consecutive_days,
        'minimumRestMinutes',coalesce(
          profile.minimum_rest_minutes,(v_settings->>'minimumRestMinutes')::integer
        ),
        'noWeekends',profile.no_weekends,
        'onlyMorningBeforeMinute',case when profile.only_morning then
          nullif(v_settings->>'onlyMorningBeforeMinute','')::integer else null end,
        'onlyEveningAfterMinute',case when profile.only_evening then
          nullif(v_settings->>'onlyEveningAfterMinute','')::integer else null end,
        'preferredShiftTemplateIds',coalesce((
          select jsonb_agg(st.id::text order by st.id::text)
          from public.matrix_shift_templates_v2 st
          where st.matrix_version_id=p_matrix_version_id and st.active
            and profile.preferred_shift_code is not null
            and st.code=profile.preferred_shift_code
        ),'[]'::jsonb),
        'preferredLocationIds',coalesce((
          select jsonb_agg(preferred.location_id order by preferred.location_id)
          from (
            select distinct ml.id::text location_id
            from public.employee_preferences ep
            join public.matrix_locations_v2 ml
              on ml.matrix_version_id=p_matrix_version_id and ml.active
              and (
                ml.id=case
                  when coalesce(
                    ep.preference_value->>'locationId',
                    ep.preference_value->>'location_id'
                  ) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
                  then coalesce(
                    ep.preference_value->>'locationId',
                    ep.preference_value->>'location_id'
                  )::uuid
                  else null
                end
                or upper(ml.code)=upper(coalesce(
                  ep.preference_value->>'locationCode',
                  ep.preference_value->>'location',
                  ep.preference_value->>'code'
                ))
              )
            where ep.employee_id=profile.employee_id and ep.status='ACTIVE'
              and ep.preference_type='PREFERRED_LOCATION'
              and ep.valid_from<=v_period_end and ep.valid_to>=v_month
          ) preferred
        ),'[]'::jsonb),
        'softDayOffDates',coalesce((
          select jsonb_agg(gs::date order by gs::date)
          from public.employee_preferences ep
          cross join lateral generate_series(ep.valid_from,ep.valid_to,interval '1 day') gs
          where ep.employee_id=profile.employee_id and ep.status='ACTIVE'
            and ep.preference_type='OTHER'
            and ep.preference_value->>'kind'='DAY_OFF'
            and ep.valid_from<=v_period_end and ep.valid_to>=v_month
        ),'[]'::jsonb)
      ) order by profile.employee_no)
      from public.matrix_employee_profiles_v2 profile
      join public.employees e on e.id=profile.employee_id
      left join public.employee_hr_profiles hr
        on hr.employee_id=profile.employee_id
      where profile.matrix_version_id=p_matrix_version_id
        and profile.active and profile.archived_at is null
        and (profile.employment_start is null
          or profile.employment_start<=v_period_end)
        and (profile.employment_end is null or profile.employment_end>=v_month)
        and (p_scope_role_id is null or exists(
          select 1 from public.matrix_employee_roles_v2 er
          where er.matrix_version_id=p_matrix_version_id
            and er.employee_id=profile.employee_id
            and er.role_id=p_scope_role_id and er.active
            and (er.valid_from is null or er.valid_from<=v_period_end)
            and (er.valid_to is null or er.valid_to>=v_month)
        ))
    ),'[]'::jsonb),
    'availabilityWindows',coalesce((
      select jsonb_agg(jsonb_build_object(
        'employeeId',c.employee_id,'start',lower(c.time_range),'end',upper(c.time_range)
      ) order by c.employee_id,lower(c.time_range))
      from public.employee_time_constraints_v2 c
      where c.status='ACTIVE' and c.constraint_kind='AVAILABLE_WINDOW'
        and c.time_range && tstzrange(v_month::timestamp at time zone v_timezone,
          (v_period_end+1)::timestamp at time zone v_timezone,'[)')
        and exists(
          select 1 from public.matrix_employee_profiles_v2 profile
          where profile.matrix_version_id=p_matrix_version_id
            and profile.employee_id=c.employee_id
            and profile.active and profile.archived_at is null
            and (profile.employment_start is null or profile.employment_start<=v_period_end)
            and (profile.employment_end is null or profile.employment_end>=v_month)
            and (p_scope_role_id is null or exists(
              select 1 from public.matrix_employee_roles_v2 role_grant
              where role_grant.matrix_version_id=p_matrix_version_id
                and role_grant.employee_id=profile.employee_id
                and role_grant.role_id=p_scope_role_id and role_grant.active
                and (role_grant.valid_from is null or role_grant.valid_from<=v_period_end)
                and (role_grant.valid_to is null or role_grant.valid_to>=v_month)
            ))
        )
    ),'[]'::jsonb),
    'hardBlocks',coalesce((
      select jsonb_agg(jsonb_build_object(
        'employeeId',c.employee_id,'start',lower(c.time_range),'end',upper(c.time_range),
        'kind',c.constraint_kind,'source',c.source
      ) order by c.employee_id,lower(c.time_range))
      from public.employee_time_constraints_v2 c
      where c.status='ACTIVE' and c.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
        and c.time_range && tstzrange(v_month::timestamp at time zone v_timezone,
          (v_period_end+1)::timestamp at time zone v_timezone,'[)')
        and exists(
          select 1 from public.matrix_employee_profiles_v2 profile
          where profile.matrix_version_id=p_matrix_version_id
            and profile.employee_id=c.employee_id
            and profile.active and profile.archived_at is null
            and (profile.employment_start is null or profile.employment_start<=v_period_end)
            and (profile.employment_end is null or profile.employment_end>=v_month)
            and (p_scope_role_id is null or exists(
              select 1 from public.matrix_employee_roles_v2 role_grant
              where role_grant.matrix_version_id=p_matrix_version_id
                and role_grant.employee_id=profile.employee_id
                and role_grant.role_id=p_scope_role_id and role_grant.active
                and (role_grant.valid_from is null or role_grant.valid_from<=v_period_end)
                and (role_grant.valid_to is null or role_grant.valid_to>=v_month)
            ))
        )
    ),'[]'::jsonb),
    'externalAssignments','[]'::jsonb,
    'lockedAssignments','[]'::jsonb,
    'baselineAssignments','[]'::jsonb,
    'payRules',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',pr.id,'calculationType',pr.calculation_method,
        'currency',pr.currency,
        'values',jsonb_strip_nulls(jsonb_build_object(
          'amountMinor',coalesce(ov.amount_minor,pr.amount_minor),
          'rateMinorPerHour',coalesce(ov.rate_minor_per_hour,pr.rate_minor_per_hour),
          'percentBasisPoints',coalesce(ov.percent_basis_points,pr.percent_basis_points),
          'multiplierBasisPoints',coalesce(ov.multiplier_basis_points,pr.multiplier_basis_points),
          'thresholdMinutes',pr.threshold_minutes
        )),
        'conditions',coalesce(pr.condition_expression->'conditions','[]'::jsonb)
          ||coalesce((select jsonb_build_array(jsonb_build_object(
              'field','role_id','operator','IN','value',jsonb_agg(x.role_id::text order by x.role_id::text)
            )) from public.matrix_pay_rule_roles_v2 x where x.pay_rule_id=pr.id
              having count(*)>0),'[]'::jsonb)
          ||coalesce((select jsonb_build_array(jsonb_build_object(
              'field','duty_ids','operator',
              case when bool_or(x.match_mode='ALL') then 'CONTAINS_ALL' else 'CONTAINS_ANY' end,
              'value',jsonb_agg(x.duty_id::text order by x.duty_id::text)
            )) from public.matrix_pay_rule_duties_v2 x where x.pay_rule_id=pr.id
              having count(*)>0),'[]'::jsonb)
          ||coalesce((select jsonb_build_array(jsonb_build_object(
              'field','location_id','operator','IN',
              'value',jsonb_agg(x.location_id::text order by x.location_id::text)
            )) from public.matrix_pay_rule_locations_v2 x where x.pay_rule_id=pr.id
              having count(*)>0),'[]'::jsonb)
          ||coalesce((select jsonb_build_array(jsonb_build_object(
              'field','shift_template_id','operator','IN',
              'value',jsonb_agg(x.shift_template_id::text order by x.shift_template_id::text)
            )) from public.matrix_pay_rule_shifts_v2 x where x.pay_rule_id=pr.id
              having count(*)>0),'[]'::jsonb),
        'stackingGroup',pr.stacking_group,'stackingMode',pr.stacking_mode,
        'priority',pr.priority,'active',pr.active and coalesce(ov.enabled,true),
        'effectiveFrom',pr.valid_from,'effectiveTo',pr.valid_to,
        'dayMask',to_jsonb(pr.day_mask),'localStart',pr.local_start,'localEnd',pr.local_end,
        'roleIds',coalesce((select jsonb_agg(x.role_id::text order by x.role_id::text)
          from public.matrix_pay_rule_roles_v2 x where x.pay_rule_id=pr.id),'[]'::jsonb),
        'dutyIds',coalesce((select jsonb_agg(x.duty_id::text order by x.duty_id::text)
          from public.matrix_pay_rule_duties_v2 x where x.pay_rule_id=pr.id),'[]'::jsonb),
        'locationIds',coalesce((select jsonb_agg(x.location_id::text order by x.location_id::text)
          from public.matrix_pay_rule_locations_v2 x where x.pay_rule_id=pr.id),'[]'::jsonb),
        'shiftTemplateIds',coalesce((select jsonb_agg(x.shift_template_id::text order by x.shift_template_id::text)
          from public.matrix_pay_rule_shifts_v2 x where x.pay_rule_id=pr.id),'[]'::jsonb)
      ) order by pr.priority,pr.code)
      from public.matrix_pay_rules_v2 pr
      left join lateral (
        with recursive scenario_chain as (
          select sc.id,sc.parent_scenario_id,0 depth
          from public.matrix_scenarios_v2 sc
          where sc.id=p_scenario_id and sc.matrix_version_id=p_matrix_version_id
          union all
          select parent.id,parent.parent_scenario_id,chain.depth+1
          from public.matrix_scenarios_v2 parent
          join scenario_chain chain on chain.parent_scenario_id=parent.id
          where parent.matrix_version_id=p_matrix_version_id and chain.depth<32
        )
        select
          (array_agg(override.enabled order by chain.depth,override.id))[1]
            enabled,
          (array_agg(override.amount_minor order by chain.depth,override.id)
            filter(where override.amount_minor is not null))[1] amount_minor,
          (array_agg(override.rate_minor_per_hour order by chain.depth,override.id)
            filter(where override.rate_minor_per_hour is not null))[1]
            rate_minor_per_hour,
          (array_agg(override.percent_basis_points order by chain.depth,override.id)
            filter(where override.percent_basis_points is not null))[1]
            percent_basis_points,
          (array_agg(override.multiplier_basis_points order by chain.depth,override.id)
            filter(where override.multiplier_basis_points is not null))[1]
            multiplier_basis_points
        from scenario_chain chain
        join public.matrix_scenario_pay_rule_overrides_v2 override
          on override.scenario_id=chain.id and override.pay_rule_id=pr.id
        where override.matrix_version_id=p_matrix_version_id
      ) ov on true
      where pr.matrix_version_id=p_matrix_version_id and pr.active
    ),'[]'::jsonb),
    'budgets',v_budgets,
    'budget',coalesce((
      select jsonb_build_object(
        'amountMinor',(b.value->>'amountMinor')::bigint,
        'hard',coalesce((b.value->>'hard')::boolean,false),
        'currency',v_currency
      )
      from jsonb_array_elements(v_budgets) b
      where nullif(b.value->>'locationId','') is null
        and nullif(b.value->>'roleId','') is null
        and nullif(b.value->>'dutyId','') is null
      limit 1
    ),jsonb_build_object(
      'amountMinor',null,'hard',false,'currency',v_currency
    ))
  ) into v_snapshot;
  if jsonb_array_length(v_snapshot->'strategies')>32 then
    raise exception 'SOLVER_CAPACITY_STRATEGY_LIMIT';
  end if;

  -- Previous selected v2 assignments and the latest legacy plan are projected
  -- onto deterministic slot IDs. They remain soft baseline hints unless they
  -- were explicitly locked. For ROLE runs, assignments owned by other roles
  -- are hard external time blocks and prevent cross-role collisions.
  with chosen_legacy_plan as (
    select p.id from public.plans p where p.month=v_month
    order by case p.status when 'PUBLISHED' then 1 when 'READY' then 2 else 3 end,
      p.version desc,p.created_at desc limit 1
  ), legacy_numbered as (
    select a.employee_id,a.locked,sh.starts_at,sh.ends_at,sh.shift_date,
      mt.id shift_template_id,mr.id role_id,
      row_number() over(
        partition by sh.shift_date,mt.id,mr.id order by a.locked desc,a.id
      ) seat_number
    from chosen_legacy_plan cp
    join public.shifts sh on sh.plan_id=cp.id
    join public.assignments a on a.shift_id=sh.id
    join public.locations old_location on old_location.id=sh.location_id
    join public.matrix_locations_v2 ml
      on ml.matrix_version_id=p_matrix_version_id and ml.code=old_location.code::text
    join public.matrix_shift_templates_v2 mt
      on mt.matrix_version_id=p_matrix_version_id and mt.location_id=ml.id
      and mt.code=sh.shift_code
    join public.matrix_roles_v2 mr
      on mr.matrix_version_id=p_matrix_version_id and mr.code=a.assigned_role::text
  ), snapshot_slots as (
    select slot.value->>'slotId' slot_id,(slot.value->>'date')::date shift_date,
      (slot.value->>'shiftTemplateId')::uuid shift_template_id,
      (slot.value->>'roleId')::uuid role_id,
      row_number() over(
        partition by (slot.value->>'date')::date,
          (slot.value->>'shiftTemplateId')::uuid,(slot.value->>'roleId')::uuid
        order by (slot.value->>'seatIndex')::integer,slot.value->>'slotId'
      ) seat_number
    from jsonb_array_elements(v_snapshot->'slots') slot
  ), legacy_projection as (
    select ss.slot_id,l.employee_id,l.locked,1 source_priority
    from legacy_numbered l join snapshot_slots ss
      on ss.shift_date=l.shift_date and ss.shift_template_id=l.shift_template_id
      and ss.role_id=l.role_id and ss.seat_number=l.seat_number
  ), selected_v2 as (
    select pa.slot_key slot_id,pa.employee_id,pa.locked,2 source_priority,
      coalesce(v.selected_at,v.created_at) selected_at
    from public.plan_assignments_v2 pa
    join public.plan_variants_v2 v on v.id=pa.variant_id and v.selected
    join public.optimization_runs_v2 r on r.id=v.run_id
    where r.month=v_month and r.matrix_version_id=p_matrix_version_id
      and r.request_engine='ORTOOLS_V2'
      and exists(select 1 from snapshot_slots ss where ss.slot_id=pa.slot_key)
  ), combined as (
    select slot_id,employee_id,locked,source_priority,null::timestamptz selected_at
    from legacy_projection
    union all
    select slot_id,employee_id,locked,source_priority,selected_at from selected_v2
  ), deduplicated as (
    select distinct on (slot_id) slot_id,employee_id,locked
    from combined order by slot_id,source_priority desc,selected_at desc nulls last
  ), scoped_baseline as (
    select d.*,exists(
      select 1 from jsonb_array_elements(v_snapshot->'employees') employee
      where employee.value->>'id'=d.employee_id::text
    ) employee_present
    from deduplicated d
  )
  select
    coalesce(jsonb_agg(jsonb_build_object('slotId',slot_id,'employeeId',employee_id)
      order by slot_id) filter(where employee_present),'[]'::jsonb),
    coalesce(jsonb_agg(jsonb_build_object('slotId',slot_id,'employeeId',employee_id)
      order by slot_id) filter(where locked),'[]'::jsonb)
  into v_baseline,v_locked from scoped_baseline;
  if exists(
    select 1 from jsonb_array_elements(v_locked) lock_item
    where not exists(
      select 1 from jsonb_array_elements(v_snapshot->'employees') employee
      where employee.value->>'id'=lock_item.value->>'employeeId'
    )
  ) then raise exception 'LOCKED_ASSIGNMENT_EMPLOYEE_OUTSIDE_SNAPSHOT'; end if;

  -- Assignments outside the generated scope stay hard. For ROLE runs that
  -- means the other roles in the same month. For every scope it also includes
  -- adjacent-month assignments, so rest and consecutive-day rules are not
  -- accidentally reset at midnight on the first/last day of the month.
  with target_role as (
    select code from public.matrix_roles_v2 where id=p_scope_role_id
  ), ranked_legacy_plans as (
    select p.id,p.month,row_number() over(
      partition by p.month
      order by case p.status when 'PUBLISHED' then 1 when 'READY' then 2 else 3 end,
        p.version desc,p.created_at desc
    ) plan_rank
    from public.plans p
    where p.month between (v_month-interval '1 month')::date
      and (v_month+interval '1 month')::date
  ), latest_selected_role_variants as (
    select ranked.variant_id
    from (
      select v.id variant_id,
        row_number() over(
          partition by r.scope_role_id
          order by coalesce(v.selected_at,v.created_at) desc,v.id desc
        ) selection_rank
      from public.plan_variants_v2 v
      join public.optimization_runs_v2 r on r.id=v.run_id
      where p_scope_type='ROLE'
        and r.month=v_month
        and r.matrix_version_id=p_matrix_version_id
        and r.scenario_id=p_scenario_id
        and r.request_engine='ORTOOLS_V2'
        and r.scope_type='ROLE'
        and r.scope_role_id is distinct from p_scope_role_id
        and v.selected
    ) ranked
    where ranked.selection_rank=1
  ), blocks as (
    select a.employee_id,sh.starts_at,sh.ends_at
    from ranked_legacy_plans cp
    join public.shifts sh on sh.plan_id=cp.id
    join public.assignments a on a.shift_id=sh.id
    left join target_role tr on true
    where cp.plan_rank=1 and (
      sh.shift_date<v_month
      or sh.shift_date>v_period_end
      or (p_scope_type='ROLE' and a.assigned_role::text<>tr.code)
    )
    union
    select pa.employee_id,ps.starts_at,ps.ends_at
    from public.plan_assignments_v2 pa
    join public.plan_shifts_v2 ps on ps.id=pa.shift_id
    join public.plan_variants_v2 v on v.id=pa.variant_id
    join public.optimization_runs_v2 r on r.id=v.run_id
    where r.month between (v_month-interval '1 month')::date
        and (v_month+interval '1 month')::date
      and (
        (
          v.status='PUBLISHED'
          and (
            ps.shift_date<v_month
            or ps.shift_date>v_period_end
          )
        )
        or (
          p_scope_type='ROLE'
          and r.month=v_month
          and v.id in (select x.variant_id from latest_selected_role_variants x)
          and pa.role_id is distinct from p_scope_role_id
        )
      )
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'employeeId',block.employee_id,'start',block.starts_at,'end',block.ends_at
  ) order by block.employee_id,block.starts_at,block.ends_at),'[]'::jsonb)
  into v_external
  from blocks block
  where exists(
    select 1 from jsonb_array_elements(v_snapshot->'employees') employee
    where employee.value->>'id'=block.employee_id::text
  );
  v_snapshot := jsonb_set(v_snapshot,'{baselineAssignments}',v_baseline,true);
  v_snapshot := jsonb_set(v_snapshot,'{lockedAssignments}',v_locked,true);
  v_snapshot := jsonb_set(v_snapshot,'{externalAssignments}',v_external,true);

  return v_snapshot;
end;
$_$;


ALTER FUNCTION "solver_private"."build_snapshot_payload_before_final_slot_contract_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") OWNER TO "postgres";

--
-- Name: build_snapshot_payload_before_monthly_budget_uat_v1("uuid", "date", "uuid", "uuid", "text", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."build_snapshot_payload_before_monthly_budget_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_snapshot jsonb;
  v_category uuid;
  v_role_ids jsonb;
  v_slot_ids jsonb;
  v_employees jsonb:='[]'::jsonb;
  v_employee jsonb;
  v_grants jsonb;
  v_external jsonb;
  v_employee_id uuid;
begin
  if p_scope_type<>'ROLE' or p_scope_role_id is null then
    return solver_private.build_snapshot_payload_before_categories_uat_v1(
      p_run_id,p_month,p_matrix_version_id,p_scenario_id,p_scope_type,p_scope_role_id);
  end if;
  select category_id into v_category from public.matrix_roles_v2
    where id=p_scope_role_id and matrix_version_id=p_matrix_version_id and active;
  if v_category is null then raise exception 'SCOPE_CATEGORY_NOT_FOUND'; end if;
  select jsonb_agg(id::text) into v_role_ids from public.matrix_roles_v2
    where matrix_version_id=p_matrix_version_id and category_id=v_category and active;
  v_snapshot:=solver_private.build_snapshot_payload_before_categories_uat_v1(
    p_run_id,p_month,p_matrix_version_id,p_scenario_id,'COMPANY',null);
  v_snapshot:=jsonb_set(v_snapshot,'{roles}',coalesce((select jsonb_agg(value order by ordinality)
    from jsonb_array_elements(coalesce(v_snapshot->'roles','[]'::jsonb)) with ordinality
    where value->>'id' in(select jsonb_array_elements_text(v_role_ids))),'[]'::jsonb),true);
  v_snapshot:=jsonb_set(v_snapshot,'{demand}',coalesce((select jsonb_agg(value order by ordinality)
    from jsonb_array_elements(coalesce(v_snapshot->'demand','[]'::jsonb)) with ordinality
    where value->>'roleId' in(select jsonb_array_elements_text(v_role_ids))),'[]'::jsonb),true);
  v_snapshot:=jsonb_set(v_snapshot,'{slots}',coalesce((select jsonb_agg(value order by ordinality)
    from jsonb_array_elements(coalesce(v_snapshot->'slots','[]'::jsonb)) with ordinality
    where value->>'roleId' in(select jsonb_array_elements_text(v_role_ids))),'[]'::jsonb),true);
  select coalesce(jsonb_agg(value->>'slotId'),'[]'::jsonb) into v_slot_ids
    from jsonb_array_elements(coalesce(v_snapshot->'slots','[]'::jsonb));
  v_snapshot:=jsonb_set(v_snapshot,'{baselineAssignments}',coalesce((select jsonb_agg(value order by ordinality)
    from jsonb_array_elements(coalesce(v_snapshot->'baselineAssignments','[]'::jsonb)) with ordinality
    where value->>'slotId' in(select jsonb_array_elements_text(v_slot_ids))),'[]'::jsonb),true);
  v_snapshot:=jsonb_set(v_snapshot,'{lockedAssignments}',coalesce((select jsonb_agg(value order by ordinality)
    from jsonb_array_elements(coalesce(v_snapshot->'lockedAssignments','[]'::jsonb)) with ordinality
    where value->>'slotId' in(select jsonb_array_elements_text(v_slot_ids))),'[]'::jsonb),true);

  for v_employee in select value from jsonb_array_elements(coalesce(v_snapshot->'employees','[]'::jsonb)) loop
    v_employee_id:=(v_employee->>'id')::uuid;
    select coalesce(jsonb_agg(grant_row order by grant_row->>'assignmentMode',grant_row->>'backupPriority',grant_row->>'roleId'),'[]'::jsonb)
    into v_grants from (
      select jsonb_strip_nulls(jsonb_build_object(
        'roleId',employee_role.role_id,'validFrom',employee_role.valid_from,'validTo',employee_role.valid_to,
        'assignmentMode',employee_role.assignment_mode,'backupPriority',employee_role.backup_priority
      )) grant_row
      from public.matrix_employee_roles_v2 employee_role
      where employee_role.matrix_version_id=p_matrix_version_id and employee_role.employee_id=v_employee_id
        and employee_role.active and employee_role.role_id in(select value::uuid from jsonb_array_elements_text(v_role_ids))
      union
      select jsonb_build_object(
        'roleId',fallback_role.id,'assignmentMode','BACKUP','backupPriority',100,'sourceDutyId',employee_duty.duty_id
      )
      from public.matrix_employee_duties_v2 employee_duty
      join public.matrix_duties_v2 duty on duty.id=employee_duty.duty_id and duty.matrix_version_id=p_matrix_version_id and duty.active
      join public.matrix_roles_v2 fallback_role on fallback_role.matrix_version_id=p_matrix_version_id
        and fallback_role.category_id=v_category and fallback_role.active and upper(fallback_role.code)=upper(duty.code)
      where employee_duty.matrix_version_id=p_matrix_version_id and employee_duty.employee_id=v_employee_id and employee_duty.active
        and exists(select 1 from public.matrix_employee_roles_v2 base_role
          join public.matrix_roles_v2 configured_role on configured_role.id=base_role.role_id and configured_role.category_id=v_category
          where base_role.matrix_version_id=p_matrix_version_id and base_role.employee_id=v_employee_id and base_role.active)
    ) grants;
    if jsonb_array_length(v_grants)>0 then
      v_employee:=jsonb_set(v_employee,'{roleGrants}',v_grants,true);
      v_employee:=jsonb_set(v_employee,'{roleIds}',coalesce((select jsonb_agg(distinct value->>'roleId') from jsonb_array_elements(v_grants)),'[]'::jsonb),true);
      v_employees:=v_employees||jsonb_build_array(v_employee);
    end if;
  end loop;
  v_snapshot:=jsonb_set(v_snapshot,'{employees}',v_employees,true);
  -- A category is generated as one atomic unit, while already selected plans
  -- from other categories remain hard time blocks for the same employees.
  with ranked as (
    select variant.id,
      row_number() over(partition by anchor.category_id order by
        coalesce(variant.selected_at,variant.created_at) desc,variant.id desc) selection_rank
    from public.plan_variants_v2 variant
    join public.optimization_runs_v2 run on run.id=variant.run_id
    join public.matrix_roles_v2 anchor on anchor.id=run.scope_role_id
    where run.month=date_trunc('month',p_month)::date
      and run.matrix_version_id=p_matrix_version_id and run.scenario_id=p_scenario_id
      and run.request_engine='ORTOOLS_V2' and run.scope_type='ROLE'
      and anchor.category_id is distinct from v_category and variant.selected
  ), blocks as (
    select assignment.employee_id,shift.starts_at,shift.ends_at
    from ranked
    join public.plan_assignments_v2 assignment on assignment.variant_id=ranked.id
    join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
    where ranked.selection_rank=1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'employeeId',blocks.employee_id,'start',blocks.starts_at,'end',blocks.ends_at
  ) order by blocks.employee_id,blocks.starts_at),'[]'::jsonb) into v_external
  from blocks where exists(select 1 from jsonb_array_elements(v_employees) employee
    where employee.value->>'id'=blocks.employee_id::text);
  v_snapshot:=jsonb_set(v_snapshot,'{externalAssignments}',
    coalesce(v_snapshot->'externalAssignments','[]'::jsonb)||coalesce(v_external,'[]'::jsonb),true);
  v_snapshot:=jsonb_set(v_snapshot,'{scope}',jsonb_build_object(
    'type','CATEGORY','roleId',p_scope_role_id,'categoryId',v_category,
    'roleIds',v_role_ids,'categoryName',(select name from public.matrix_role_categories_v2 where id=v_category)
  ),true);
  return v_snapshot;
end;
$$;


ALTER FUNCTION "solver_private"."build_snapshot_payload_before_monthly_budget_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") OWNER TO "postgres";

--
-- Name: build_snapshot_payload_before_occurrence_id_v2("uuid", "date", "uuid", "uuid", "text", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."build_snapshot_payload_before_occurrence_id_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_snapshot jsonb;
  v_templates jsonb;
begin
  v_snapshot:=solver_private.build_snapshot_payload_before_primary_shift_invariants_v2(
    p_run_id,p_month,p_matrix_version_id,p_scenario_id,
    p_scope_type,p_scope_role_id
  );

  -- Preserve the explicit business sequence from Matrix.  The worker uses
  -- this only to identify last(D) -> first(D+1); it is never an employee
  -- daily-assignment limit.
  select coalesce(jsonb_agg(
    template.value||jsonb_build_object(
      'sequenceOrder',shift_template.sort_order,
      'shiftPeriod',shift_template.shift_period
    ) order by template.ordinality
  ),'[]'::jsonb)
  into v_templates
  from jsonb_array_elements(coalesce(v_snapshot->'shiftTemplates','[]'::jsonb))
    with ordinality template(value,ordinality)
  join public.matrix_shift_templates_v2 shift_template
    on shift_template.matrix_version_id=p_matrix_version_id
    and shift_template.id=(template.value->>'id')::uuid;

  return jsonb_set(v_snapshot,'{shiftTemplates}',v_templates,true);
end;
$$;


ALTER FUNCTION "solver_private"."build_snapshot_payload_before_occurrence_id_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") OWNER TO "postgres";

--
-- Name: build_snapshot_payload_before_overtime_pricing_uat_v1("uuid", "date", "uuid", "uuid", "text", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."build_snapshot_payload_before_overtime_pricing_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_snapshot jsonb; v_revision uuid; v_budgets jsonb;
  v_strategies jsonb:='[]'::jsonb; v_strategy jsonb; v_terms jsonb; v_max_tier integer;
begin
  v_snapshot:=solver_private.build_snapshot_payload_before_monthly_budget_uat_v1(
    p_run_id,p_month,p_matrix_version_id,p_scenario_id,p_scope_type,p_scope_role_id);
  select id into v_revision from public.monthly_budget_revisions_v2
    where budget_month=date_trunc('month',p_month)::date and status='ACTIVE';
  if v_revision is null then return v_snapshot; end if;
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
    'id',line.id,'metricType',line.metric_type,'enforcement',line.enforcement,
    'amountMinor',case when line.metric_type='COST' then round(line.limit_value*100)::bigint
      when line.metric_type='LABOR_PERCENT' and line.reference_value is not null
        then round(line.reference_value*100*line.limit_value/100)::bigint else null end,
    'limitMinutes',case when line.metric_type='HOURS' then round(line.limit_value*60)::bigint else null end,
    'limitBps',case when line.metric_type='LABOR_PERCENT' then round(line.limit_value*100)::bigint else null end,
    'referenceAmountMinor',case when line.reference_value is not null then round(line.reference_value*100)::bigint else null end,
    'hard',line.enforcement='HARD',
    'locationId',location_row.id,
    'roleIds',case when line.role_logical_id is not null then coalesce((
      select jsonb_agg(role_row.id) from public.matrix_roles_v2 role_row
      where role_row.matrix_version_id=p_matrix_version_id
        and role_row.logical_id=line.role_logical_id and role_row.active
    ),'[]'::jsonb) when line.category_logical_id is null then '[]'::jsonb else coalesce((
      select jsonb_agg(role_row.id) from public.matrix_role_categories_v2 category
      join public.matrix_roles_v2 role_row on role_row.category_id=category.id and role_row.active
      where category.matrix_version_id=p_matrix_version_id
        and category.logical_id=line.category_logical_id and category.active
    ),'[]'::jsonb) end
  ))),'[]'::jsonb) into v_budgets
  from public.monthly_budget_lines_v2 line
  left join public.matrix_locations_v2 location_row
    on location_row.matrix_version_id=p_matrix_version_id
   and location_row.logical_id=line.location_logical_id and location_row.active
  where line.revision_id=v_revision;
  v_snapshot:=jsonb_set(v_snapshot,'{budgets}',v_budgets,true);
  v_snapshot:=jsonb_set(v_snapshot,'{budgetRevisionId}',to_jsonb(v_revision),true);
  if exists(select 1 from public.monthly_budget_lines_v2 line where line.revision_id=v_revision and line.enforcement='TARGET') then
    for v_strategy in select value from jsonb_array_elements(coalesce(v_snapshot->'strategies','[]'::jsonb)) loop
      v_terms:=coalesce(v_strategy->'objectiveTerms','[]'::jsonb);
      select coalesce(max((term.value->>'tier')::integer),0) into v_max_tier
        from jsonb_array_elements(v_terms) term(value);
      v_terms:=v_terms||jsonb_build_array(jsonb_build_object(
        'tier',v_max_tier+1,'metric','BUDGET_TARGET_EXCESS','weight',1,'direction','MIN'
      ));
      v_strategies:=v_strategies||jsonb_build_array(jsonb_set(v_strategy,'{objectiveTerms}',v_terms,true));
    end loop;
    v_snapshot:=jsonb_set(v_snapshot,'{strategies}',v_strategies,true);
  end if;
  return v_snapshot;
end; $$;


ALTER FUNCTION "solver_private"."build_snapshot_payload_before_overtime_pricing_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") OWNER TO "postgres";

--
-- Name: build_snapshot_payload_before_overtime_uat_v1("uuid", "date", "uuid", "uuid", "text", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."build_snapshot_payload_before_overtime_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_snapshot jsonb; v_rules jsonb:='[]'::jsonb; v_rule jsonb; v_formula jsonb;
begin
  v_snapshot:=solver_private.build_snapshot_payload_before_overtime_pricing_uat_v1(
    p_run_id,p_month,p_matrix_version_id,p_scenario_id,p_scope_type,p_scope_role_id);
  for v_rule in select value from jsonb_array_elements(coalesce(v_snapshot->'payRules','[]'::jsonb)) loop
    select coalesce(rule.formula_expression,'{}'::jsonb) into v_formula
      from public.matrix_pay_rules_v2 rule where rule.id=(v_rule->>'id')::uuid;
    if upper(coalesce(v_rule->>'calculationType',''))='MONTHLY_THRESHOLD_PER_HOUR' then
      v_rule:=jsonb_set(v_rule,'{values}',coalesce(v_rule->'values','{}'::jsonb)||jsonb_build_object(
        'thresholdSource',coalesce(nullif(v_formula->>'thresholdSource',''),'FIXED')
      ),true);
    end if;
    v_rules:=v_rules||jsonb_build_array(v_rule);
  end loop;
  v_snapshot:=jsonb_set(v_snapshot,'{payRules}',v_rules,true);
  if exists(select 1 from jsonb_array_elements(coalesce(v_snapshot->'employees','[]'::jsonb)) employee
      where employee.value->>'overtimePolicy' in ('ALLOWED','APPROVAL_REQUIRED'))
    and not exists(select 1 from jsonb_array_elements(v_rules) rule
      where upper(rule.value->>'calculationType')='MONTHLY_THRESHOLD_PER_HOUR'
        and rule.value->'values'->>'thresholdSource'='EMPLOYEE_NOMINAL') then
    raise exception 'OVERTIME_PAY_RULE_MISSING';
  end if;
  return v_snapshot;
end; $$;


ALTER FUNCTION "solver_private"."build_snapshot_payload_before_overtime_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") OWNER TO "postgres";

--
-- Name: build_snapshot_payload_before_primary_shift_invariants_v2("uuid", "date", "uuid", "uuid", "text", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."build_snapshot_payload_before_primary_shift_invariants_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_snapshot jsonb;
  v_employees jsonb := '[]'::jsonb;
begin
  v_snapshot:=solver_private.build_snapshot_payload_before_final_contract_v2(
    p_run_id,p_month,p_matrix_version_id,p_scenario_id,
    p_scope_type,p_scope_role_id
  );

  select coalesce(jsonb_agg(
    case
      when upper(coalesce(rate.value->>'contractCode',employee.value->>'contractCode','OTHER'))
          in ('ZLECENIE','B2B')
        and coalesce(profile.work_time_policy,'CONTRACT_DEFAULT')<>'CUSTOM'
      then employee.value||jsonb_build_object(
        'contractCode',upper(coalesce(
          rate.value->>'contractCode',employee.value->>'contractCode','OTHER'
        )),
        'workTimePolicy','CONTRACT_DEFAULT',
        'baseHourlyRateMinor',coalesce(
          nullif(rate.value->>'baseRateMinor','')::bigint,
          nullif(employee.value->>'baseHourlyRateMinor','')::bigint,
          0
        ),
        'nominalMonthlyMinutes',0,
        'maximumMonthlyMinutes',0,
        'maximumWeeklyMinutes',0,
        'maximumConsecutiveDays',31,
        'minimumRestMinutes',0
      )
      else employee.value||jsonb_build_object(
        'contractCode',upper(coalesce(
          rate.value->>'contractCode',employee.value->>'contractCode','OTHER'
        )),
        'workTimePolicy',coalesce(profile.work_time_policy,'CONTRACT_DEFAULT'),
        'baseHourlyRateMinor',coalesce(
          nullif(rate.value->>'baseRateMinor','')::bigint,
          nullif(employee.value->>'baseHourlyRateMinor','')::bigint,
          0
        )
      )
    end
    order by employee.ordinality
  ),'[]'::jsonb)
  into v_employees
  from jsonb_array_elements(coalesce(v_snapshot->'employees','[]'::jsonb))
    with ordinality employee(value,ordinality)
  left join public.matrix_employee_profiles_v2 profile
    on profile.matrix_version_id=p_matrix_version_id
    and profile.employee_id=(employee.value->>'id')::uuid
  left join lateral (
    select period.value
    from jsonb_array_elements(coalesce(employee.value->'payRatePeriods','[]'::jsonb)) period
    where p_month>=(period.value->>'validFrom')::date
      and (nullif(period.value->>'validTo','') is null
        or p_month<=(period.value->>'validTo')::date)
    order by (period.value->>'validFrom')::date desc
    limit 1
  ) rate on true;

  return jsonb_set(v_snapshot,'{employees}',v_employees,true);
end;
$$;


ALTER FUNCTION "solver_private"."build_snapshot_payload_before_primary_shift_invariants_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") OWNER TO "postgres";

--
-- Name: build_snapshot_payload_before_slot_contract_fix_v2("uuid", "date", "uuid", "uuid", "text", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."build_snapshot_payload_before_slot_contract_fix_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_snapshot jsonb;
  v_employees jsonb:='[]'::jsonb;
  v_templates jsonb:='[]'::jsonb;
  v_employee jsonb;
  v_template jsonb;
  v_rules jsonb;
begin
  v_snapshot:=solver_private.build_snapshot_payload_before_alpha16_v2(
    p_run_id,p_month,p_matrix_version_id,p_scenario_id,p_scope_type,p_scope_role_id
  );

  for v_template in
    select template.value
    from jsonb_array_elements(coalesce(v_snapshot->'shiftTemplates','[]'::jsonb)) template
  loop
    v_template:=v_template||jsonb_build_object(
      'shiftPeriod',(select row.shift_period
        from public.matrix_shift_templates_v2 row
        where row.id=(v_template->>'id')::uuid)
    );
    v_templates:=v_templates||jsonb_build_array(v_template);
  end loop;

  for v_employee in
    select employee.value
    from jsonb_array_elements(coalesce(v_snapshot->'employees','[]'::jsonb)) employee
  loop
    v_rules:=solver_private.alpha16_shift_rules_v2(
      (v_employee->>'id')::uuid,p_matrix_version_id,p_month
    );
    v_employee:=(v_employee-'preferredShiftTemplateIds'-'homeLocationIds')
      ||jsonb_build_object(
        'preferredShiftTemplateIds',coalesce(v_rules->'preferredShiftTemplateIds','[]'::jsonb),
        'avoidedShiftTemplateIds',coalesce(v_rules->'avoidedShiftTemplateIds','[]'::jsonb),
        'blockedShiftTemplateIds',coalesce(v_rules->'blockedShiftTemplateIds','[]'::jsonb),
        'shiftPeriodPreferences',coalesce(v_rules->'periods','{}'::jsonb),
        -- Work in every standard-allowed location belongs to the ordinary
        -- contract limit. A former home marker no longer creates a penalty.
        'homeLocationIds','[]'::jsonb
      );
    v_employees:=v_employees||jsonb_build_array(v_employee);
  end loop;

  v_snapshot:=jsonb_set(v_snapshot,'{shiftTemplates}',v_templates,true);
  v_snapshot:=jsonb_set(v_snapshot,'{employees}',v_employees,true);
  return v_snapshot;
end;
$$;


ALTER FUNCTION "solver_private"."build_snapshot_payload_before_slot_contract_fix_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") OWNER TO "postgres";

--
-- Name: build_snapshot_payload_v2("uuid", "date", "uuid", "uuid", "text", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."build_snapshot_payload_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_snapshot jsonb;
  v_matrix_settings jsonb;
  v_runtime_strategies jsonb;
  v_business_seed integer;
begin
  v_snapshot:=solver_private.build_snapshot_payload_before_b4f170(
    p_run_id,p_month,p_matrix_version_id,p_scenario_id,p_scope_type,p_scope_role_id
  );
  select mv.settings into v_matrix_settings
  from public.matrix_versions mv
  where mv.id=p_matrix_version_id;

  if v_matrix_settings->>'strategySemanticsVersion'='B4F170_V1' then
    perform solver_private.validate_strategy_semantics_b4f170(
      p_matrix_version_id
    );
    v_business_seed:=(v_snapshot#>>'{settings,randomSeed}')::integer;
    select coalesce(jsonb_agg(
      jsonb_set(item.value,'{randomSeed}',to_jsonb(v_business_seed),true)
      order by item.ordinality
    ),'[]'::jsonb)
    into v_runtime_strategies
    from jsonb_array_elements(v_snapshot->'strategies')
      with ordinality item(value,ordinality);
    v_snapshot:=jsonb_set(
      v_snapshot,'{strategies}',v_runtime_strategies,true
    );
    v_snapshot:=jsonb_set(
      v_snapshot,
      '{settings}',
      (coalesce(v_snapshot->'settings','{}'::jsonb)-'fairnessQualityGate')
        ||jsonb_build_object(
          'fairnessQualityTarget',v_matrix_settings->'fairnessQualityTarget',
          'randomSeedSource','BUSINESS_SNAPSHOT_B4F170_V1'
        ),
      true
    );
  end if;

  return v_snapshot;
end;
$$;


ALTER FUNCTION "solver_private"."build_snapshot_payload_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") OWNER TO "postgres";

--
-- Name: bump_planning_revision_v2(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."bump_planning_revision_v2"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  update solver_private.planning_data_revision_v2
  set revision=revision+1,updated_at=clock_timestamp()
  where singleton;
  return null;
end;
$$;


ALTER FUNCTION "solver_private"."bump_planning_revision_v2"() OWNER TO "postgres";

--
-- Name: FUNCTION "bump_planning_revision_v2"(); Type: COMMENT; Schema: solver_private; Owner: postgres
--

COMMENT ON FUNCTION "solver_private"."bump_planning_revision_v2"() IS 'Statement trigger that increments the planning revision while holding its transaction lock.';


--
-- Name: can_access_run_v2("uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."can_access_run_v2"("p_run_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select exists(
    select 1 from public.optimization_runs_v2 r
    where r.id=p_run_id and (
      r.requested_by=(select auth.uid())
      or public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    )
  );
$$;


ALTER FUNCTION "solver_private"."can_access_run_v2"("p_run_id" "uuid") OWNER TO "postgres";

--
-- Name: can_edit_leader_variant_uat_v1("uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."can_edit_leader_variant_uat_v1"("p_variant_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select exists(
    select 1
    from public.plan_variants_v2 variant
    join public.optimization_runs_v2 run on run.id=variant.run_id
    left join public.matrix_roles_v2 role on role.id=run.scope_role_id
    where variant.id=p_variant_id
      and variant.variant_kind='LEADER_COPY'
      and variant.status in ('READY','SELECTED')
      and auth.uid() is not null
      and (
        public.has_app_role('OWNER') or public.has_app_role('ADMIN')
        or (
          run.scope_type='ROLE'
          and exists(
            select 1 from public.matrix_scope_grants_v2 grant_row
            where grant_row.auth_user_id=auth.uid()
              and grant_row.active
              and grant_row.app_role='ROLE_MANAGER'
              and (grant_row.role_logical_id is null
                or grant_row.role_logical_id=role.logical_id)
          )
        )
      )
  );
$$;


ALTER FUNCTION "solver_private"."can_edit_leader_variant_uat_v1"("p_variant_id" "uuid") OWNER TO "postgres";

--
-- Name: canonical_json_v2("jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."canonical_json_v2"("p_value" "jsonb") RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE STRICT
    SET "search_path" TO ''
    AS $_$
declare v_type text := jsonb_typeof(p_value); v_result text;
begin
  if v_type='object' then
    select '{'||coalesce(string_agg(
      to_jsonb(e.key)::text||':'||solver_private.canonical_json_v2(e.value),
      ',' order by e.key collate "C"
    ),'')||'}' into v_result from jsonb_each(p_value) e;
    return v_result;
  elsif v_type='array' then
    select '['||coalesce(string_agg(
      solver_private.canonical_json_v2(a.value),',' order by a.ordinality
    ),'')||']' into v_result
    from jsonb_array_elements(p_value) with ordinality a(value,ordinality);
    return v_result;
  elsif v_type='number' then
    if p_value::text !~ '^-?[0-9]+(\.0+)?$' then
      raise exception 'NON_INTEGRAL_SNAPSHOT_NUMBER';
    end if;
    return ((p_value#>>'{}')::numeric::bigint)::text;
  end if;
  return p_value::text;
end;
$_$;


ALTER FUNCTION "solver_private"."canonical_json_v2"("p_value" "jsonb") OWNER TO "postgres";

--
-- Name: capture_leader_variant_history_v2(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."capture_leader_variant_history_v2"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if new.variant_kind<>'LEADER_COPY'
    or coalesce(current_setting('solver_private.history_restore',true),'')='on' then return new; end if;
  if tg_op='INSERT' then
    if not exists(select 1 from solver_private.leader_variant_history_v2 where variant_id=new.id) then
      perform solver_private.record_leader_variant_history_v2(new.id,new.revision,'Punkt startowy',new.last_edited_by);
    end if;
  elsif new.revision is distinct from old.revision then
    perform solver_private.record_leader_variant_history_v2(new.id,new.revision,'Rewizja '||new.revision,new.last_edited_by);
  end if;
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."capture_leader_variant_history_v2"() OWNER TO "postgres";

--
-- Name: changed_variant_employees_uat_v1("uuid"[], "uuid"[]); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."changed_variant_employees_uat_v1"("p_old_variant_ids" "uuid"[], "p_new_variant_ids" "uuid"[]) RETURNS TABLE("employee_id" "uuid", "before_assignment_count" integer, "after_assignment_count" integer, "before_schedule" "jsonb", "after_schedule" "jsonb")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  with old_items as (
    select assignment.employee_id,shift.shift_date,shift.starts_at,shift.ends_at,
      location.logical_id location_logical_id,role.logical_id role_logical_id,
      jsonb_build_object(
        'date',shift.shift_date,
        'startsAt',shift.starts_at,
        'endsAt',shift.ends_at,
        'locationLogicalId',location.logical_id,
        'roleLogicalId',role.logical_id,
        'duties',coalesce((
          select jsonb_agg(to_jsonb(duty.logical_id) order by duty.logical_id::text)
          from public.plan_assignment_duties_v2 assignment_duty
          join public.matrix_duties_v2 duty on duty.id=assignment_duty.duty_id
          where assignment_duty.assignment_id=assignment.id
        ),'[]'::jsonb)
      ) item
    from public.plan_assignments_v2 assignment
    join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
    join public.matrix_locations_v2 location on location.id=shift.location_id
    join public.matrix_roles_v2 role on role.id=assignment.role_id
    where coalesce(cardinality(p_old_variant_ids),0)>0
      and assignment.variant_id=any(p_old_variant_ids)
  ), old_schedules as (
    select item.employee_id,count(*)::integer assignment_count,
      jsonb_agg(item.item order by item.shift_date,item.starts_at,item.ends_at,
        item.location_logical_id::text,item.role_logical_id::text,item.item::text) schedule
    from old_items item group by item.employee_id
  ), new_items as (
    select assignment.employee_id,shift.shift_date,shift.starts_at,shift.ends_at,
      location.logical_id location_logical_id,role.logical_id role_logical_id,
      jsonb_build_object(
        'date',shift.shift_date,
        'startsAt',shift.starts_at,
        'endsAt',shift.ends_at,
        'locationLogicalId',location.logical_id,
        'roleLogicalId',role.logical_id,
        'duties',coalesce((
          select jsonb_agg(to_jsonb(duty.logical_id) order by duty.logical_id::text)
          from public.plan_assignment_duties_v2 assignment_duty
          join public.matrix_duties_v2 duty on duty.id=assignment_duty.duty_id
          where assignment_duty.assignment_id=assignment.id
        ),'[]'::jsonb)
      ) item
    from public.plan_assignments_v2 assignment
    join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
    join public.matrix_locations_v2 location on location.id=shift.location_id
    join public.matrix_roles_v2 role on role.id=assignment.role_id
    where coalesce(cardinality(p_new_variant_ids),0)>0
      and assignment.variant_id=any(p_new_variant_ids)
  ), new_schedules as (
    select item.employee_id,count(*)::integer assignment_count,
      jsonb_agg(item.item order by item.shift_date,item.starts_at,item.ends_at,
        item.location_logical_id::text,item.role_logical_id::text,item.item::text) schedule
    from new_items item group by item.employee_id
  )
  select coalesce(old_row.employee_id,new_row.employee_id),
    coalesce(old_row.assignment_count,0),coalesce(new_row.assignment_count,0),
    coalesce(old_row.schedule,'[]'::jsonb),coalesce(new_row.schedule,'[]'::jsonb)
  from old_schedules old_row
  full join new_schedules new_row on new_row.employee_id=old_row.employee_id
  where coalesce(old_row.schedule,'[]'::jsonb)
    is distinct from coalesce(new_row.schedule,'[]'::jsonb);
$$;


ALTER FUNCTION "solver_private"."changed_variant_employees_uat_v1"("p_old_variant_ids" "uuid"[], "p_new_variant_ids" "uuid"[]) OWNER TO "postgres";

--
-- Name: employee_for_slot_v2("jsonb", "jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."employee_for_slot_v2"("p_employee" "jsonb", "p_slot" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  select case
    when p_employee ? 'payRatePeriods' and rate.value is not null
    then p_employee||jsonb_build_object(
      'baseHourlyRateMinor',rate.value->>'baseRateMinor',
      'contractCode',rate.value->>'contractCode'
    )
    else p_employee
  end
  from (select 1) anchor
  left join lateral (
    select period.value
    from jsonb_array_elements(coalesce(p_employee->'payRatePeriods','[]'::jsonb)) period
    where (p_slot->>'date')::date>=(period.value->>'validFrom')::date
      and (nullif(period.value->>'validTo','') is null
        or (p_slot->>'date')::date<=(period.value->>'validTo')::date)
    order by (period.value->>'validFrom')::date desc
    limit 1
  ) rate on true;
$$;


ALTER FUNCTION "solver_private"."employee_for_slot_v2"("p_employee" "jsonb", "p_slot" "jsonb") OWNER TO "postgres";

--
-- Name: employee_pay_rate_covers_period_v2("uuid", "date", "date"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."employee_pay_rate_covers_period_v2"("p_employee_id" "uuid", "p_from" "date", "p_to" "date") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select p_from is not null and p_to is not null and p_to>=p_from
    and not exists(
      select 1
      from pg_catalog.generate_series(p_from,p_to,interval '1 day') covered_day
      where not exists(
        select 1 from public.employee_pay_rates_v2 rate
        where rate.employee_id=p_employee_id and rate.active
          and rate.valid_from<=covered_day::date
          and (rate.valid_to is null or rate.valid_to>=covered_day::date)
      )
    );
$$;


ALTER FUNCTION "solver_private"."employee_pay_rate_covers_period_v2"("p_employee_id" "uuid", "p_from" "date", "p_to" "date") OWNER TO "postgres";

--
-- Name: employee_scope_eligible_v2("jsonb", "jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."employee_scope_eligible_v2"("p_employee" "jsonb", "p_slot" "jsonb") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  select
    case when p_employee ? 'roleGrants' then exists(
      select 1
      from jsonb_array_elements(coalesce(p_employee->'roleGrants','[]'::jsonb)) g
      where g.value->>'roleId'=p_slot->>'roleId'
        and (nullif(g.value->>'validFrom','') is null
          or (p_slot->>'date')::date>=(g.value->>'validFrom')::date)
        and (nullif(g.value->>'validTo','') is null
          or (p_slot->>'date')::date<=(g.value->>'validTo')::date)
    ) else coalesce(p_employee->'roleIds','[]'::jsonb) ? (p_slot->>'roleId') end
    and
    case when p_employee ? 'locationGrants' then exists(
      select 1
      from jsonb_array_elements(coalesce(p_employee->'locationGrants','[]'::jsonb)) g
      where g.value->>'locationId'=p_slot->>'locationId'
        and coalesce((g.value->>'standardAllowed')::boolean,false)
        and (nullif(g.value->>'validFrom','') is null
          or (p_slot->>'date')::date>=(g.value->>'validFrom')::date)
        and (nullif(g.value->>'validTo','') is null
          or (p_slot->>'date')::date<=(g.value->>'validTo')::date)
    ) else coalesce(p_employee->'locationIds','[]'::jsonb) ? (p_slot->>'locationId') end
    and not exists(
      select 1
      from jsonb_array_elements_text(coalesce(p_slot->'dutyIds','[]'::jsonb)) duty
      where not case when p_employee ? 'dutyGrants' then exists(
        select 1
        from jsonb_array_elements(coalesce(p_employee->'dutyGrants','[]'::jsonb)) g
        where g.value->>'dutyId'=duty.value
          and (nullif(g.value->>'roleId','') is null
            or g.value->>'roleId'=p_slot->>'roleId')
          and (nullif(g.value->>'locationId','') is null
            or g.value->>'locationId'=p_slot->>'locationId')
          and (nullif(g.value->>'validFrom','') is null
            or (p_slot->>'date')::date>=(g.value->>'validFrom')::date)
          and (nullif(g.value->>'validTo','') is null
            or (p_slot->>'date')::date<=(g.value->>'validTo')::date)
      ) else coalesce(p_employee->'dutyIds','[]'::jsonb) ? duty.value end
    );
$$;


ALTER FUNCTION "solver_private"."employee_scope_eligible_v2"("p_employee" "jsonb", "p_slot" "jsonb") OWNER TO "postgres";

--
-- Name: employee_weekly_pattern_allows_uat_v1("uuid", "date", timestamp with time zone, timestamp with time zone, "uuid", "uuid", "text"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."employee_weekly_pattern_allows_uat_v1"("p_employee_id" "uuid", "p_shift_date" "date", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_role_id" "uuid", "p_location_id" "uuid", "p_timezone" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  with active_hard as (
    select p.* from public.employee_weekly_work_patterns_v2 p
    where p.employee_id=p_employee_id and p.active and p.enforcement='HARD'
      and p.valid_from<=p_shift_date and (p.valid_to is null or p.valid_to>=p_shift_date)
  ), local_shift as (
    select extract(isodow from p_shift_date)::integer weekday,
      (p_starts_at at time zone p_timezone)::time start_time,
      (p_ends_at at time zone p_timezone)::time end_time,
      (p_ends_at at time zone p_timezone)::date>(p_starts_at at time zone p_timezone)::date overnight
  )
  select not exists(select 1 from active_hard) or exists(
    select 1 from active_hard p cross join local_shift s
    where p.weekday=s.weekday and (p.role_id is null or p.role_id=p_role_id)
      and (p.location_id is null or p.location_id=p_location_id)
      and p.local_start<=s.start_time
      and case when p.local_end<=p.local_start then
        (s.overnight and s.end_time<=p.local_end) or (not s.overnight and s.end_time>=p.local_start)
      else not s.overnight and s.end_time<=p.local_end end
  );
$$;


ALTER FUNCTION "solver_private"."employee_weekly_pattern_allows_uat_v1"("p_employee_id" "uuid", "p_shift_date" "date", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_role_id" "uuid", "p_location_id" "uuid", "p_timezone" "text") OWNER TO "postgres";

--
-- Name: enforce_run_version_stamp_uat_v1(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."enforce_run_version_stamp_uat_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $_$
declare
  v_key text;
  v_old jsonb;
  v_new jsonb;
  v_mode text;
  v_northflank_run_id text;
  v_dispatcher_version text;
  v_phase text;
begin
  if new.version_stamp is null or jsonb_typeof(new.version_stamp)<>'object' then
    raise exception 'VERSION_STAMP_INVALID';
  end if;
  if tg_op='UPDATE' then
    foreach v_key in array array[
      'schemaVersion','frontendCommit','solverCommit','solverImageDigest',
      'solverBuildId','gatewayVersion','strategyConfigVersion',
      'databaseMigrationVersion','snapshotSchemaVersion','executionMode',
      'northflankRunId','dispatcherVersion'
    ] loop
      v_old:=old.version_stamp->v_key;
      v_new:=new.version_stamp->v_key;
      if v_old is not null and v_old<>'null'::jsonb
        and v_new is distinct from v_old then
        raise exception 'VERSION_STAMP_IMMUTABLE_%',upper(v_key);
      end if;
    end loop;
  end if;

  if new.version_stamp ? 'executionMode' then
    v_mode:=new.version_stamp->>'executionMode';
    v_northflank_run_id:=new.version_stamp->>'northflankRunId';
    v_dispatcher_version:=new.version_stamp->>'dispatcherVersion';
    v_phase:=coalesce(to_jsonb(new)->>'phase','READY');
    if coalesce((new.version_stamp->>'schemaVersion')::integer,0)<>1
      or v_mode not in ('SERVICE','JOB')
      or coalesce(new.version_stamp->>'frontendCommit','')=''
      or coalesce(new.version_stamp->>'solverCommit','') !~ '^[0-9a-f]{40}$'
      or coalesce(new.version_stamp->>'solverBuildId','')=''
      or coalesce(new.version_stamp->>'strategyConfigVersion','')
        !~ '^[0-9a-f]{64}$'
      or coalesce(new.version_stamp->>'databaseMigrationVersion','')=''
      or coalesce((new.version_stamp->>'snapshotSchemaVersion')::integer,0)<=0
    then raise exception 'VERSION_STAMP_INCOMPLETE'; end if;

    if v_mode='SERVICE' and (
      v_northflank_run_id is not null or v_dispatcher_version is not null
    ) then
      raise exception 'SERVICE_VERSION_STAMP_JOB_PROVENANCE_FORBIDDEN';
    end if;
    if v_mode='JOB'
      and v_phase in ('STARTING','RUNNING','SOLVING','VALIDATING','READY')
      and v_northflank_run_id is null then
      raise exception 'JOB_VERSION_STAMP_NORTHFLANK_RUN_ID_REQUIRED';
    end if;
  end if;
  return new;
end;
$_$;


ALTER FUNCTION "solver_private"."enforce_run_version_stamp_uat_v1"() OWNER TO "postgres";

--
-- Name: expected_pay_components_v2("jsonb", "jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."expected_pay_components_v2"("p_snapshot" "jsonb", "p_variant" "jsonb") RETURNS TABLE("slot_id" "text", "employee_id" "text", "rule_id" "text", "calculation_type" "text", "cost_units" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
with submitted as (
  select a.value->>'slotId' slot_id,a.value->>'employeeId' employee_id
  from jsonb_array_elements(p_variant->'assignments') a
), pairs as (
  select a.slot_id,a.employee_id,s.value slot,
    solver_private.employee_for_slot_v2(e.value,s.value) employee,
    (s.value->>'durationMinutes')::bigint duration_minutes,
    (solver_private.employee_for_slot_v2(e.value,s.value)->>'baseHourlyRateMinor')::bigint
      base_rate_minor,
    (solver_private.employee_for_slot_v2(e.value,s.value)->>'baseHourlyRateMinor')::bigint
      *(s.value->>'durationMinutes')::bigint base_units
  from submitted a
  join jsonb_array_elements(p_snapshot->'slots') s on s.value->>'slotId'=a.slot_id
  join jsonb_array_elements(p_snapshot->'employees') e on e.value->>'id'=a.employee_id
), static_matched as (
  select p.*,r.value rule,billable.minutes billable_minutes,
    upper(r.value->>'calculationType') calculation,
    coalesce(nullif(r.value->>'stackingGroup',''),r.value->>'id') stacking_group,
    upper(coalesce(nullif(r.value->>'stackingMode',''),'STACK')) stacking_mode,
    coalesce((r.value->>'priority')::integer,0) priority,
    case upper(r.value->>'calculationType')
      when 'FIXED_PER_SHIFT' then (r.value->'values'->>'amountMinor')::bigint*60
      when 'PER_HOUR' then (r.value->'values'->>'rateMinorPerHour')::bigint*billable.minutes
      when 'PERCENT_BASE' then round(
        p.base_rate_minor*billable.minutes
          *(r.value->'values'->>'percentBasisPoints')::numeric/10000
      )::bigint
      when 'MULTIPLIER' then round(
        p.base_rate_minor*billable.minutes
          *((r.value->'values'->>'multiplierBasisPoints')::numeric-10000)/10000
      )::bigint
      when 'SHIFT_DURATION_THRESHOLD_PER_HOUR' then
        greatest(billable.minutes-(r.value->'values'->>'thresholdMinutes')::bigint,0)
          *(r.value->'values'->>'rateMinorPerHour')::bigint
    end calculated_units
  from pairs p cross join jsonb_array_elements(coalesce(p_snapshot->'payRules','[]'::jsonb)) r
  cross join lateral (
    select solver_private.pay_rule_billable_minutes_v2(
      p_snapshot,r.value,p.slot
    ) minutes
  ) billable
  where upper(r.value->>'calculationType') in (
    'FIXED_PER_SHIFT','PER_HOUR','PERCENT_BASE','MULTIPLIER',
    'SHIFT_DURATION_THRESHOLD_PER_HOUR'
  ) and solver_private.pay_rule_matches_v2(p_snapshot,r.value,p.employee,p.slot)
), static_ranked as (
  select m.*,
    row_number() over(
      partition by slot_id,stacking_group order by priority,(rule->>'id')
    ) first_rank,
    row_number() over(
      partition by slot_id,stacking_group
      order by calculated_units desc,priority,(rule->>'id') desc
    ) max_rank
  from static_matched m
), dynamic_matched as (
  select p.*,r.value rule,
    (r.value->'values'->>'thresholdMinutes')::bigint threshold_minutes,
    (r.value->'values'->>'rateMinorPerHour')::bigint rate_minor_per_hour
  from pairs p cross join jsonb_array_elements(coalesce(p_snapshot->'payRules','[]'::jsonb)) r
  where upper(r.value->>'calculationType')='MONTHLY_THRESHOLD_PER_HOUR'
    and solver_private.pay_rule_matches_v2(p_snapshot,r.value,p.employee,p.slot)
), dynamic_ordered as (
  select d.*,coalesce(sum(duration_minutes) over(
    partition by employee_id,(rule->>'id')
    order by (slot->>'start')::timestamptz,slot_id
    rows between unbounded preceding and 1 preceding
  ),0)::bigint prior_minutes
  from dynamic_matched d
), expected as (
  select p.slot_id,p.employee_id,'BASE'::text rule_id,
    'BASE_HOURLY'::text calculation_type,p.base_units cost_units
  from pairs p
  union all
  select s.slot_id,s.employee_id,s.rule->>'id',s.calculation,s.calculated_units
  from static_ranked s
  where s.stacking_mode='STACK'
    or (s.stacking_mode='FIRST' and s.first_rank=1)
    or (s.stacking_mode='MAX' and s.max_rank=1)
  union all
  select d.slot_id,d.employee_id,d.rule->>'id','MONTHLY_THRESHOLD_PER_HOUR',
    (greatest(d.prior_minutes+d.duration_minutes-d.threshold_minutes,0)
      -greatest(d.prior_minutes-d.threshold_minutes,0))*d.rate_minor_per_hour
  from dynamic_ordered d
  where greatest(d.prior_minutes+d.duration_minutes-d.threshold_minutes,0)
    >greatest(d.prior_minutes-d.threshold_minutes,0)
)
select e.slot_id,e.employee_id,e.rule_id,e.calculation_type,e.cost_units
from expected e;
$$;


ALTER FUNCTION "solver_private"."expected_pay_components_v2"("p_snapshot" "jsonb", "p_variant" "jsonb") OWNER TO "postgres";

--
-- Name: generate_published_standby_trigger_v2(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."generate_published_standby_trigger_v2"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_schedule public.published_schedules_v2%rowtype;
  v_role uuid;
begin
  if tg_table_name='published_role_schedules_v2' then
    if exists(
      select 1
      from public.plan_assignments_v2 assignment
      join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
      join public.published_standby_assignments_v2 standby
        on standby.employee_id=assignment.employee_id
       and standby.standby_date=shift_row.shift_date
       and standby.month=new.month
       and standby.status in ('PLANNED','ACTIVATED')
      where assignment.variant_id=new.variant_id
    ) then
      raise exception 'ROLE_PUBLICATION_CONFLICTS_WITH_EXISTING_STANDBY';
    end if;
    perform solver_private.generate_standby_for_variant_uat_v2(
      new.variant_id,new.month,new.matrix_version_id,new.role_id,null,new.id
    );
    return new;
  end if;
  select schedule.* into v_schedule
  from public.published_schedules_v2 schedule where schedule.id=new.schedule_id;
  if v_schedule.source_type='COMPANY' then
    if exists(
      select 1
      from public.plan_assignments_v2 assignment
      join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
      join public.published_standby_assignments_v2 standby
        on standby.employee_id=assignment.employee_id
       and standby.standby_date=shift_row.shift_date
       and standby.month=v_schedule.month
       and standby.status in ('PLANNED','ACTIVATED')
      where assignment.variant_id=new.variant_id
    ) then
      raise exception 'COMPANY_PUBLICATION_CONFLICTS_WITH_EXISTING_STANDBY';
    end if;
    for v_role in
      select distinct source.role_id from (
        select assignment.role_id from public.plan_assignments_v2 assignment
        where assignment.variant_id=new.variant_id
        union select issue.role_id from public.plan_issues_v2 issue
        where issue.variant_id=new.variant_id and issue.role_id is not null
      ) source
    loop
      perform solver_private.generate_standby_for_variant_uat_v2(
        new.variant_id,v_schedule.month,v_schedule.matrix_version_id,v_role,
        v_schedule.id,null
      );
    end loop;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."generate_published_standby_trigger_v2"() OWNER TO "postgres";

--
-- Name: generate_standby_before_shortage_guard_uat_v1("uuid", "date", "uuid", "uuid", "uuid", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."generate_standby_before_shortage_guard_uat_v1"("p_variant_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_role_id" "uuid", "p_source_schedule_id" "uuid", "p_source_role_schedule_id" "uuid") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_date date; v_tier integer; v_employee uuid; v_created integer:=0; v_requested_tiers integer:=0;
begin
  if (p_source_schedule_id is null)=(p_source_role_schedule_id is null) then raise exception 'STANDBY_SOURCE_REQUIRED'; end if;
  select least(2,greatest(0,coalesce((matrix.settings->>'standbyTiersPerRoleDay')::integer,0)))
    into v_requested_tiers from public.matrix_versions matrix where matrix.id=p_matrix_version_id;
  if v_requested_tiers is null then raise exception 'MATRIX_VERSION_NOT_FOUND'; end if;
  update public.published_standby_assignments_v2 standby set status='SUPERSEDED'
  where standby.month=p_month and standby.role_id=p_role_id and standby.status='PLANNED'
    and (standby.source_schedule_id is distinct from p_source_schedule_id
      or standby.source_role_schedule_id is distinct from p_source_role_schedule_id);
  if v_requested_tiers=0 then return 0; end if;
  for v_date in select distinct source.shift_date from (
    select shift_row.shift_date from public.plan_assignments_v2 assignment
      join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
      where assignment.variant_id=p_variant_id and assignment.role_id=p_role_id
    union
    select shift_row.shift_date from public.plan_issues_v2 issue
      join public.plan_shifts_v2 shift_row on shift_row.id=issue.shift_id
      where issue.variant_id=p_variant_id and issue.role_id=p_role_id
  ) source order by source.shift_date loop
    for v_tier in 1..v_requested_tiers loop
      if v_tier=2 and exists(select 1 from public.plan_issues_v2 issue
        join public.plan_shifts_v2 shift_row on shift_row.id=issue.shift_id
        where issue.variant_id=p_variant_id and issue.role_id=p_role_id
          and issue.issue_code='UNFILLED_SLOT' and shift_row.shift_date=v_date) then
        continue;
      end if;
      select candidate.employee_id into v_employee
      from solver_private.standby_candidates_for_role_day_uat_v3(
        p_variant_id,p_matrix_version_id,p_month,p_role_id,v_date) candidate
      order by
        (select count(*) from public.published_standby_assignments_v2 history
          where history.month=p_month and history.role_id=p_role_id
            and history.employee_id=candidate.employee_id and history.tier=v_tier
            and history.status not in ('CANCELLED','SUPERSEDED')),
        (select count(*) from public.published_standby_assignments_v2 history
          where history.month=p_month and history.role_id=p_role_id
            and history.employee_id=candidate.employee_id
            and history.status not in ('CANCELLED','SUPERSEDED')),
        (select count(*) from public.published_standby_assignments_v2 history
          where history.month=p_month and history.employee_id=candidate.employee_id
            and history.status not in ('CANCELLED','SUPERSEDED')),
        candidate.employee_no,candidate.employee_id limit 1;
      if v_employee is null then exit; end if;
      insert into public.published_standby_assignments_v2(
        month,standby_date,matrix_version_id,role_id,employee_id,tier,
        source_variant_id,source_schedule_id,source_role_schedule_id,created_by
      ) values(p_month,v_date,p_matrix_version_id,p_role_id,v_employee,v_tier,
        p_variant_id,p_source_schedule_id,p_source_role_schedule_id,auth.uid());
      v_created:=v_created+1;
    end loop;
  end loop;
  return v_created;
end;
$$;


ALTER FUNCTION "solver_private"."generate_standby_before_shortage_guard_uat_v1"("p_variant_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_role_id" "uuid", "p_source_schedule_id" "uuid", "p_source_role_schedule_id" "uuid") OWNER TO "postgres";

--
-- Name: generate_standby_for_variant_before_b4_default_uat_v2("uuid", "date", "uuid", "uuid", "uuid", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."generate_standby_for_variant_before_b4_default_uat_v2"("p_variant_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_role_id" "uuid", "p_source_schedule_id" "uuid", "p_source_role_schedule_id" "uuid") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "solver_private"."generate_standby_for_variant_before_b4_default_uat_v2"("p_variant_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_role_id" "uuid", "p_source_schedule_id" "uuid", "p_source_role_schedule_id" "uuid") OWNER TO "postgres";

--
-- Name: generate_standby_for_variant_uat_v2("uuid", "date", "uuid", "uuid", "uuid", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."generate_standby_for_variant_uat_v2"("p_variant_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_role_id" "uuid", "p_source_schedule_id" "uuid", "p_source_role_schedule_id" "uuid") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_group jsonb;v_groups jsonb;v_role_ids uuid[];v_canonical uuid;v_input_category text;
  v_date date;v_tier integer;v_candidate record;v_created integer:=0;
begin
  if (p_source_schedule_id is null)=(p_source_role_schedule_id is null) then raise exception 'STANDBY_SOURCE_REQUIRED'; end if;
  select coalesce(matrix.settings->'standbyGroups','[]'::jsonb) into v_groups
    from public.matrix_versions matrix where matrix.id=p_matrix_version_id;
  select category.code into v_input_category from public.matrix_roles_v2 role_row
    join public.matrix_role_categories_v2 category on category.id=role_row.category_id where role_row.id=p_role_id;
  for v_group in select value from jsonb_array_elements(v_groups) loop
    select array_agg(role_row.id order by role_code.ordinality)
    into v_role_ids from jsonb_array_elements_text(v_group->'roleCodes') with ordinality role_code(value,ordinality)
    join public.matrix_roles_v2 role_row on role_row.matrix_version_id=p_matrix_version_id
      and role_row.active and upper(role_row.code)=upper(role_code.value);
    v_canonical:=v_role_ids[1];
    if p_source_role_schedule_id is not null then
      if upper(v_group->>'categoryCode') is distinct from upper(v_input_category) then continue; end if;
    elsif v_canonical is distinct from p_role_id then continue;
    end if;
    update public.published_standby_assignments_v2 standby set status='SUPERSEDED'
    where standby.month=p_month and standby.standby_group_code=v_group->>'code' and standby.status='PLANNED'
      and (standby.source_schedule_id is distinct from p_source_schedule_id
        or standby.source_role_schedule_id is distinct from p_source_role_schedule_id);
    for v_date in select distinct source.shift_date from (
      select shift_row.shift_date from public.plan_assignments_v2 assignment
        join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
        where assignment.variant_id=p_variant_id and assignment.role_id=any(v_role_ids)
      union
      select shift_row.shift_date from public.plan_issues_v2 issue
        join public.plan_shifts_v2 shift_row on shift_row.id=issue.shift_id
        where issue.variant_id=p_variant_id and issue.role_id=any(v_role_ids)
    ) source order by source.shift_date loop
      if exists(select 1 from public.plan_issues_v2 issue join public.plan_shifts_v2 shift_row on shift_row.id=issue.shift_id
        where issue.variant_id=p_variant_id and issue.role_id=any(v_role_ids)
          and issue.issue_code='UNFILLED_SLOT' and shift_row.shift_date=v_date) then continue; end if;
      for v_tier in 1..least(2,greatest(1,(v_group->>'tiers')::integer)) loop
        v_candidate:=null;
        select candidate.employee_id,candidate.employee_no,candidate.eligible_role_ids into v_candidate
        from solver_private.standby_candidates_for_group_day_uat_v1(
          p_variant_id,p_matrix_version_id,p_month,v_role_ids,v_date) candidate
        order by
          (select count(*) from public.published_standby_assignments_v2 history
            where history.month=p_month and history.standby_group_code=v_group->>'code'
              and history.employee_id=candidate.employee_id and history.tier=v_tier
              and history.status not in ('CANCELLED','SUPERSEDED')),
          (select count(*) from public.published_standby_assignments_v2 history
            where history.month=p_month and history.standby_group_code=v_group->>'code'
              and history.employee_id=candidate.employee_id and history.status not in ('CANCELLED','SUPERSEDED')),
          (select count(*) from public.published_standby_assignments_v2 history
            where history.month=p_month and history.employee_id=candidate.employee_id
              and history.status not in ('CANCELLED','SUPERSEDED')),
          candidate.employee_no,candidate.employee_id limit 1;
        if v_candidate.employee_id is null then exit; end if;
        insert into public.published_standby_assignments_v2(
          month,standby_date,matrix_version_id,role_id,employee_id,tier,
          source_variant_id,source_schedule_id,source_role_schedule_id,created_by,
          standby_group_code,standby_group_name,standby_category_code,eligible_role_ids
        ) values(
          p_month,v_date,p_matrix_version_id,v_canonical,v_candidate.employee_id,v_tier,
          p_variant_id,p_source_schedule_id,p_source_role_schedule_id,auth.uid(),
          v_group->>'code',v_group->>'name',v_group->>'categoryCode',v_candidate.eligible_role_ids
        );
        v_created:=v_created+1;
      end loop;
    end loop;
  end loop;
  return v_created;
end;
$$;


ALTER FUNCTION "solver_private"."generate_standby_for_variant_uat_v2"("p_variant_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_role_id" "uuid", "p_source_schedule_id" "uuid", "p_source_role_schedule_id" "uuid") OWNER TO "postgres";

--
-- Name: guard_active_variant_selection_v2(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."guard_active_variant_selection_v2"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_active_solver_version text;
  v_request_engine text;
  v_run_solver_version text;
begin
  if not new.selected
    or (tg_op='UPDATE' and old.selected is true) then
    return new;
  end if;

  v_active_solver_version :=
    solver_private.active_ortools_solver_version_v2();
  select run.request_engine,run.solver_version
  into v_request_engine,v_run_solver_version
  from public.optimization_runs_v2 run
  where run.id=new.run_id;

  if v_request_engine is distinct from 'ORTOOLS_V2' then
    raise exception 'SHADOW_RUN_NOT_SELECTABLE';
  end if;
  if v_run_solver_version is distinct from v_active_solver_version then
    raise exception 'RUN_SOLVER_VERSION_NOT_ACTIVE';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."guard_active_variant_selection_v2"() OWNER TO "postgres";

--
-- Name: guard_employee_pay_rate_employment_uat_v1(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."guard_employee_pay_rate_employment_uat_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_employment_start date;
  v_employment_end date;
begin
  if new.valid_from < current_date - interval '50 years'
    or new.valid_from > current_date + interval '2 years' then
    raise exception 'PAY_RATE_DATE_OUTSIDE_ALLOWED_HORIZON';
  end if;
  if new.valid_to is not null and (
    new.valid_to < new.valid_from
    or new.valid_to > current_date + interval '10 years'
  ) then
    raise exception 'PAY_RATE_END_OUTSIDE_ALLOWED_HORIZON';
  end if;

  -- Both directions serialize on the stable employee identity.  This prevents
  -- a concurrent rate write and employment-date edit from passing on stale
  -- observations of each other.
  perform 1
  from public.employees employee
  where employee.id = new.employee_id
  for update;
  if not found then raise exception 'EMPLOYEE_NOT_FOUND'; end if;

  select profile.employment_start, profile.employment_end
  into v_employment_start, v_employment_end
  from public.matrix_employee_profiles_v2 profile
  join public.matrix_versions version
    on version.id = profile.matrix_version_id
  where profile.employee_id = new.employee_id
  order by case version.status
    when 'DRAFT' then 0
    when 'ACTIVE' then 1
    else 2
  end, version.version desc
  limit 1;
  if not found then raise exception 'EMPLOYEE_PROFILE_REQUIRED'; end if;

  perform solver_private.assert_employment_pay_rate_period_uat_v1(
    new.employee_id,
    v_employment_start,
    v_employment_end,
    new.valid_from,
    new.valid_to
  );
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."guard_employee_pay_rate_employment_uat_v1"() OWNER TO "postgres";

--
-- Name: guard_employee_profile_pay_rates_uat_v1(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."guard_employee_profile_pay_rates_uat_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if new.employment_start is not null and (
    new.employment_start < current_date - interval '50 years'
    or new.employment_start > current_date + interval '2 years'
  ) then
    raise exception 'EMPLOYMENT_START_OUTSIDE_ALLOWED_HORIZON';
  end if;
  if new.employment_end is not null and (
    new.employment_end < coalesce(new.employment_start,new.employment_end)
    or new.employment_end > current_date + interval '10 years'
  ) then
    raise exception 'EMPLOYMENT_END_OUTSIDE_ALLOWED_HORIZON';
  end if;

  perform 1
  from public.employees employee
  where employee.id = new.employee_id
  for update;
  if not found then raise exception 'EMPLOYEE_NOT_FOUND'; end if;

  perform solver_private.assert_employment_pay_rate_period_uat_v1(
    new.employee_id,
    new.employment_start,
    new.employment_end,
    null,
    null
  );
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."guard_employee_profile_pay_rates_uat_v1"() OWNER TO "postgres";

--
-- Name: guard_leader_variant_publication_uat_v1(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."guard_leader_variant_publication_uat_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if new.variant_kind='LEADER_COPY'
    and new.status='PUBLISHED'
    and old.status is distinct from 'PUBLISHED'
    and old.leader_workflow_status is distinct from 'READY_TO_MERGE' then
    raise exception 'LEADER_VARIANT_NOT_READY_TO_PUBLISH';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."guard_leader_variant_publication_uat_v1"() OWNER TO "postgres";

--
-- Name: FUNCTION "guard_leader_variant_publication_uat_v1"(); Type: COMMENT; Schema: solver_private; Owner: postgres
--

COMMENT ON FUNCTION "solver_private"."guard_leader_variant_publication_uat_v1"() IS 'B4F-101: blocks every publication route for a leader copy until the audited workflow reached READY_TO_MERGE.';


--
-- Name: guard_legacy_plan_publication_v2(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."guard_legacy_plan_publication_v2"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_engine text;
  v_becomes_published boolean;
begin
  if tg_op='INSERT' then
    v_becomes_published := new.status='PUBLISHED';
  else
    v_becomes_published := new.status='PUBLISHED'
      and old.status is distinct from new.status;
  end if;

  if not v_becomes_published then
    return new;
  end if;

  select flag.engine into v_engine
  from public.solver_feature_flags flag
  where flag.flag_key='DEFAULT_ENGINE';

  if v_engine='ORTOOLS_V2' then
    raise exception 'LEGACY_PUBLICATION_DISABLED';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."guard_legacy_plan_publication_v2"() OWNER TO "postgres";

--
-- Name: FUNCTION "guard_legacy_plan_publication_v2"(); Type: COMMENT; Schema: solver_private; Owner: postgres
--

COMMENT ON FUNCTION "solver_private"."guard_legacy_plan_publication_v2"() IS 'Blocks legacy Alpha 15 plan publication only after the explicit ORTOOLS_V2 cutover.';


--
-- Name: guard_matrix_child_immutable_v2(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."guard_matrix_child_immutable_v2"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_matrix_id uuid;
  v_status text;
begin
  if tg_op='UPDATE' and old.matrix_version_id<>new.matrix_version_id then
    raise exception 'MATRIX_VERSION_REPARENT_FORBIDDEN';
  end if;

  v_matrix_id:=case when tg_op='DELETE'
    then old.matrix_version_id else new.matrix_version_id end;

  select mv.status into v_status
  from public.matrix_versions mv
  where mv.id=v_matrix_id
  for share;

  if v_status is null then
    -- A parent DELETE with ON DELETE CASCADE reaches child triggers after the
    -- parent row is no longer visible. Direct orphaning remains impossible by
    -- foreign keys; INSERT and UPDATE keep failing closed below.
    if tg_op='DELETE' then return old; end if;
    raise exception 'MATRIX_VERSION_NOT_FOUND';
  end if;

  if v_status<>'DRAFT' then raise exception 'MATRIX_VERSION_IMMUTABLE'; end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."guard_matrix_child_immutable_v2"() OWNER TO "postgres";

--
-- Name: FUNCTION "guard_matrix_child_immutable_v2"(); Type: COMMENT; Schema: solver_private; Owner: postgres
--

COMMENT ON FUNCTION "solver_private"."guard_matrix_child_immutable_v2"() IS 'Protects immutable published matrix children and permits FK cascade deletes of draft children.';


--
-- Name: guard_matrix_employee_profile_v2(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."guard_matrix_employee_profile_v2"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_matrix_id uuid:=case when tg_op='DELETE'
    then old.matrix_version_id else new.matrix_version_id end;
  v_status text;
begin
  select mv.status into v_status
  from public.matrix_versions mv
  where mv.id=v_matrix_id;

  if v_status is null then
    -- A parent DELETE with ON DELETE CASCADE reaches this trigger after the
    -- parent row disappears. Foreign keys still prevent a direct orphan.
    if tg_op='DELETE' then return old; end if;
    raise exception 'MATRIX_WORKFORCE_VERSION_NOT_FOUND';
  end if;

  if v_status<>'DRAFT' then
    raise exception 'MATRIX_WORKFORCE_VERSION_IMMUTABLE';
  end if;

  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."guard_matrix_employee_profile_v2"() OWNER TO "postgres";

--
-- Name: FUNCTION "guard_matrix_employee_profile_v2"(); Type: COMMENT; Schema: solver_private; Owner: postgres
--

COMMENT ON FUNCTION "solver_private"."guard_matrix_employee_profile_v2"() IS 'Protects immutable workforce profiles and permits FK cascade deletes of draft profiles.';


--
-- Name: guard_matrix_version_immutable_v2(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."guard_matrix_version_immutable_v2"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if tg_op='DELETE' then
    if old.status<>'DRAFT' then raise exception 'MATRIX_VERSION_IMMUTABLE'; end if;
    return old;
  end if;
  if old.status='ARCHIVED' then raise exception 'MATRIX_VERSION_IMMUTABLE'; end if;
  if old.status='ACTIVE' then
    if new.status<>'ARCHIVED'
      or to_jsonb(new)-array['status','effective_to']
        <>to_jsonb(old)-array['status','effective_to'] then
      raise exception 'INVALID_MATRIX_VERSION_TRANSITION';
    end if;
    return new;
  end if;
  if old.status='DRAFT' and new.status='ARCHIVED' and
    to_jsonb(new)-array['status','effective_to']
      <>to_jsonb(old)-array['status','effective_to'] then
    raise exception 'INVALID_MATRIX_VERSION_TRANSITION';
  end if;
  if old.status='DRAFT' and new.status not in ('DRAFT','ACTIVE','ARCHIVED') then
    raise exception 'INVALID_MATRIX_VERSION_TRANSITION';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."guard_matrix_version_immutable_v2"() OWNER TO "postgres";

--
-- Name: guard_production_variant_link_v2(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."guard_production_variant_link_v2"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_active_solver_version text;
  v_request_engine text;
  v_run_solver_version text;
begin
  v_active_solver_version :=
    solver_private.active_ortools_solver_version_v2();
  select run.request_engine,run.solver_version
  into v_request_engine,v_run_solver_version
  from public.plan_variants_v2 variant
  join public.optimization_runs_v2 run on run.id=variant.run_id
  where variant.id=new.variant_id;

  if v_request_engine is distinct from 'ORTOOLS_V2' then
    raise exception 'SHADOW_RUN_NOT_PUBLISHABLE';
  end if;
  if v_run_solver_version is distinct from v_active_solver_version then
    raise exception 'RUN_SOLVER_VERSION_NOT_ACTIVE';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."guard_production_variant_link_v2"() OWNER TO "postgres";

--
-- Name: guard_publication_variant_link_v2(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."guard_publication_variant_link_v2"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  raise exception 'PUBLISHED_SCHEDULE_VARIANT_LINK_IMMUTABLE';
end;
$$;


ALTER FUNCTION "solver_private"."guard_publication_variant_link_v2"() OWNER TO "postgres";

--
-- Name: guard_published_variant_assignment_child_v2(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."guard_published_variant_assignment_child_v2"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_assignment_id uuid;
  v_variant_id uuid;
begin
  if tg_op<>'INSERT' then
    v_assignment_id := nullif(to_jsonb(old)->>'assignment_id','')::uuid;
    select pa.variant_id into v_variant_id
    from public.plan_assignments_v2 pa where pa.id=v_assignment_id;
    if solver_private.published_variant_is_frozen_v2(v_variant_id) then
      raise exception 'PUBLISHED_VARIANT_CONTENT_IMMUTABLE';
    end if;
  end if;
  if tg_op<>'DELETE' then
    v_assignment_id := nullif(to_jsonb(new)->>'assignment_id','')::uuid;
    select pa.variant_id into v_variant_id
    from public.plan_assignments_v2 pa where pa.id=v_assignment_id;
    if solver_private.published_variant_is_frozen_v2(v_variant_id) then
      raise exception 'PUBLISHED_VARIANT_CONTENT_IMMUTABLE';
    end if;
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."guard_published_variant_assignment_child_v2"() OWNER TO "postgres";

--
-- Name: guard_published_variant_direct_child_v2(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."guard_published_variant_direct_child_v2"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_old_variant_id uuid;
  v_new_variant_id uuid;
begin
  if tg_op<>'INSERT' then
    v_old_variant_id := nullif(to_jsonb(old)->>'variant_id','')::uuid;
    if solver_private.published_variant_is_frozen_v2(v_old_variant_id) then
      raise exception 'PUBLISHED_VARIANT_CONTENT_IMMUTABLE';
    end if;
  end if;
  if tg_op<>'DELETE' then
    v_new_variant_id := nullif(to_jsonb(new)->>'variant_id','')::uuid;
    if solver_private.published_variant_is_frozen_v2(v_new_variant_id) then
      raise exception 'PUBLISHED_VARIANT_CONTENT_IMMUTABLE';
    end if;
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."guard_published_variant_direct_child_v2"() OWNER TO "postgres";

--
-- Name: guard_published_variant_row_v2(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."guard_published_variant_row_v2"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if tg_op='DELETE' and solver_private.published_variant_is_frozen_v2(old.id) then
    raise exception 'PUBLISHED_VARIANT_IMMUTABLE';
  end if;
  if tg_op='UPDATE'
    and solver_private.published_variant_is_frozen_v2(old.id)
    and (
      to_jsonb(new)-array[
        'status','selected','selected_at','selected_by','published_at'
      ]::text[]
    ) is distinct from (
      to_jsonb(old)-array[
        'status','selected','selected_at','selected_by','published_at'
      ]::text[]
    ) then
    raise exception 'PUBLISHED_VARIANT_CONTENT_IMMUTABLE';
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."guard_published_variant_row_v2"() OWNER TO "postgres";

--
-- Name: guard_run_provenance_v2(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."guard_run_provenance_v2"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  if new.request_engine is distinct from old.request_engine then
    raise exception 'RUN_REQUEST_ENGINE_IMMUTABLE';
  end if;
  if new.solver_version is distinct from old.solver_version then
    raise exception 'RUN_SOLVER_VERSION_IMMUTABLE';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."guard_run_provenance_v2"() OWNER TO "postgres";

--
-- Name: guard_strategy_semantics_b4f165(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."guard_strategy_semantics_b4f165"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if new.status='ACTIVE' then
    perform solver_private.validate_strategy_semantics_b4f165(new.id);
  end if;
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."guard_strategy_semantics_b4f165"() OWNER TO "postgres";

--
-- Name: inherit_employee_overtime_policy_uat_v1(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."inherit_employee_overtime_policy_uat_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  select previous.overtime_policy into new.overtime_policy
  from public.matrix_employee_profiles_v2 previous
  join public.matrix_versions version_row on version_row.id = previous.matrix_version_id
  where previous.employee_id = new.employee_id
    and previous.matrix_version_id <> new.matrix_version_id
  order by case version_row.status when 'ACTIVE' then 0 when 'ARCHIVED' then 1 else 2 end,
    version_row.effective_from desc nulls last, version_row.version desc
  limit 1;
  new.overtime_policy := coalesce(new.overtime_policy, 'NEVER');
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."inherit_employee_overtime_policy_uat_v1"() OWNER TO "postgres";

--
-- Name: jsonb_deep_merge_array_v2("jsonb"[]); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."jsonb_deep_merge_array_v2"("p_values" "jsonb"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
declare
  v_result jsonb:='{}'::jsonb;
  v_value jsonb;
begin
  if p_values is null then return v_result; end if;
  foreach v_value in array p_values loop
    v_result:=solver_private.jsonb_deep_merge_v2(v_result,v_value);
  end loop;
  return v_result;
end;
$$;


ALTER FUNCTION "solver_private"."jsonb_deep_merge_array_v2"("p_values" "jsonb"[]) OWNER TO "postgres";

--
-- Name: jsonb_deep_merge_v2("jsonb", "jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."jsonb_deep_merge_v2"("p_base" "jsonb", "p_override" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
declare
  v_result jsonb:=case when jsonb_typeof(p_base)='object'
    then p_base else '{}'::jsonb end;
  v_key text;
  v_value jsonb;
begin
  if p_override is null then return v_result; end if;
  if jsonb_typeof(p_override)<>'object' then return p_override; end if;
  for v_key,v_value in select entry.key,entry.value
    from jsonb_each(p_override) entry
  loop
    if jsonb_typeof(v_result->v_key)='object'
      and jsonb_typeof(v_value)='object' then
      v_result:=jsonb_set(
        v_result,array[v_key],
        solver_private.jsonb_deep_merge_v2(v_result->v_key,v_value),true
      );
    else
      v_result:=jsonb_set(v_result,array[v_key],v_value,true);
    end if;
  end loop;
  return v_result;
end;
$$;


ALTER FUNCTION "solver_private"."jsonb_deep_merge_v2"("p_base" "jsonb", "p_override" "jsonb") OWNER TO "postgres";

--
-- Name: leader_overtime_candidate_uat_v1("uuid", "uuid", bigint, "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."leader_overtime_candidate_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_variant public.plan_variants_v2%rowtype;
  v_run public.optimization_runs_v2%rowtype;
  v_assignment public.plan_assignments_v2%rowtype;
  v_issue public.plan_issues_v2%rowtype;
  v_shift public.plan_shifts_v2%rowtype;
  v_profile public.matrix_employee_profiles_v2%rowtype;
  v_snapshot jsonb;
  v_payload jsonb;
  v_current_quote jsonb;
  v_projected_quote jsonb;
  v_assignments jsonb;
  v_unfilled jsonb;
  v_slot_key text;
  v_duration integer;
  v_current_monthly integer := 0;
  v_nominal integer := 0;
  v_overtime_before integer := 0;
  v_overtime_after integer := 0;
  v_current_cost_minor bigint := 0;
  v_projected_cost_minor bigint := 0;
  v_currency text := 'PLN';
begin
  if (p_assignment_id is null) = (p_issue_id is null) then
    raise exception 'ASSIGNMENT_OR_ISSUE_REQUIRED';
  end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then
    raise exception 'LEADER_VARIANT_NOT_EDITABLE';
  end if;

  select variant.* into v_variant
  from public.plan_variants_v2 variant
  where variant.id = p_variant_id and variant.variant_kind = 'LEADER_COPY';
  select run.* into v_run
  from public.optimization_runs_v2 run
  where run.id = v_variant.run_id;
  select snapshot into v_snapshot
  from solver_private.optimization_snapshots_v2
  where run_id = v_run.id;

  if p_assignment_id is not null then
    select assignment.* into v_assignment
    from public.plan_assignments_v2 assignment
    where assignment.id = p_assignment_id and assignment.variant_id = p_variant_id;
    if v_assignment.id is null then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
    select shift_row.* into v_shift from public.plan_shifts_v2 shift_row where shift_row.id = v_assignment.shift_id;
    v_slot_key := v_assignment.slot_key;
  else
    select issue.* into v_issue
    from public.plan_issues_v2 issue
    where issue.id = p_issue_id and issue.variant_id = p_variant_id and issue.issue_code = 'UNFILLED_SLOT';
    if v_issue.id is null then raise exception 'UNFILLED_ISSUE_NOT_FOUND'; end if;
    select shift_row.* into v_shift from public.plan_shifts_v2 shift_row where shift_row.id = v_issue.shift_id;
    v_slot_key := v_issue.slot_key;
  end if;

  select profile.* into v_profile
  from public.matrix_employee_profiles_v2 profile
  where profile.matrix_version_id = v_run.matrix_version_id
    and profile.employee_id = p_employee_id
    and profile.active and profile.archived_at is null;
  if v_profile.id is null then raise exception 'VARIANT_EMPLOYEE_ELIGIBILITY_INVALID'; end if;

  v_duration := extract(epoch from (v_shift.ends_at - v_shift.starts_at)) / 60;
  select coalesce(sum(extract(epoch from (shift_row.ends_at - shift_row.starts_at)) / 60), 0)::integer
  into v_current_monthly
  from public.plan_assignments_v2 assignment
  join public.plan_shifts_v2 shift_row on shift_row.id = assignment.shift_id
  where assignment.variant_id = p_variant_id
    and assignment.employee_id = p_employee_id
    and assignment.id is distinct from p_assignment_id
    and shift_row.shift_date >= v_run.month
    and shift_row.shift_date < (v_run.month + interval '1 month')::date;

  v_nominal := greatest(coalesce(v_profile.nominal_monthly_minutes, 0), 0);
  v_overtime_before := greatest(v_current_monthly - v_nominal, 0);
  v_overtime_after := greatest(v_current_monthly + v_duration - v_nominal, 0);
  v_currency := coalesce(nullif(v_snapshot->>'currency', ''), 'PLN');

  v_payload := solver_private.materialized_variant_payload_v2(
    array[p_variant_id], v_snapshot, v_variant.strategy_id
  );
  v_current_quote := solver_private.requote_variant_payload_v2(v_snapshot, v_payload);

  select coalesce(jsonb_agg(
    case when assignment.value->>'slotId' = v_slot_key then
      (assignment.value - 'costUnits' - 'costComponents')
        || jsonb_build_object('employeeId', p_employee_id)
    else assignment.value end
    order by assignment.ordinality
  ), '[]'::jsonb)
  into v_assignments
  from jsonb_array_elements(coalesce(v_payload->'assignments', '[]'::jsonb))
    with ordinality assignment(value, ordinality);

  if p_issue_id is not null then
    v_assignments := v_assignments || jsonb_build_array(jsonb_build_object(
      'slotId', v_slot_key, 'employeeId', p_employee_id
    ));
  end if;
  select coalesce(jsonb_agg(slot.value order by slot.ordinality), '[]'::jsonb)
  into v_unfilled
  from jsonb_array_elements(coalesce(v_payload->'unfilledSlotIds', '[]'::jsonb))
    with ordinality slot(value, ordinality)
  where slot.value#>>'{}' is distinct from v_slot_key;

  v_payload := jsonb_set(v_payload, '{assignments}', v_assignments, true);
  v_payload := jsonb_set(v_payload, '{unfilledSlotIds}', v_unfilled, true);
  v_projected_quote := solver_private.requote_variant_payload_v2(v_snapshot, v_payload);

  select coalesce(sum((assignment.value->>'costUnits')::bigint), 0)
  into v_current_cost_minor
  from jsonb_array_elements(coalesce(v_current_quote->'assignments', '[]'::jsonb)) assignment(value);
  select coalesce(sum((assignment.value->>'costUnits')::bigint), 0)
  into v_projected_cost_minor
  from jsonb_array_elements(coalesce(v_projected_quote->'assignments', '[]'::jsonb)) assignment(value);
  v_current_cost_minor := round(v_current_cost_minor::numeric / 60);
  v_projected_cost_minor := round(v_projected_cost_minor::numeric / 60);

  return jsonb_build_object(
    'overtimePolicy', coalesce(v_profile.overtime_policy, 'NEVER'),
    'nominalMonthlyMinutes', v_nominal,
    'currentMonthlyMinutes', v_current_monthly,
    'projectedMonthlyMinutes', v_current_monthly + v_duration,
    'overtimeBeforeMinutes', v_overtime_before,
    'overtimeAfterMinutes', v_overtime_after,
    'addedOvertimeMinutes', greatest(v_overtime_after - v_overtime_before, 0),
    'currentTotalCostMinor', v_current_cost_minor,
    'projectedTotalCostMinor', v_projected_cost_minor,
    'addedCostMinor', v_projected_cost_minor - v_current_cost_minor,
    'currency', v_currency,
    'overtimeApprovalRequired', coalesce(v_profile.overtime_policy, 'NEVER') = 'APPROVAL_REQUIRED'
      and v_overtime_after > v_overtime_before,
    'overtimeBlocked', coalesce(v_profile.overtime_policy, 'NEVER') = 'NEVER'
      and v_overtime_after > v_overtime_before
  );
end;
$$;


ALTER FUNCTION "solver_private"."leader_overtime_candidate_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid") OWNER TO "postgres";

--
-- Name: leader_variant_snapshot_v2("uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."leader_variant_snapshot_v2"("p_variant_id" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select jsonb_build_object(
    'assignments',coalesce((select jsonb_agg(to_jsonb(a) order by a.id)
      from public.plan_assignments_v2 a where a.variant_id=p_variant_id),'[]'::jsonb),
    'duties',coalesce((select jsonb_agg(to_jsonb(d) order by d.assignment_id,d.duty_id)
      from public.plan_assignment_duties_v2 d
      join public.plan_assignments_v2 a on a.id=d.assignment_id
      where a.variant_id=p_variant_id),'[]'::jsonb),
    'issues',coalesce((select jsonb_agg(to_jsonb(i) order by i.id)
      from public.plan_issues_v2 i where i.variant_id=p_variant_id),'[]'::jsonb)
  );
$$;


ALTER FUNCTION "solver_private"."leader_variant_snapshot_v2"("p_variant_id" "uuid") OWNER TO "postgres";

--
-- Name: lease_is_live_v2("uuid", "uuid", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."lease_is_live_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select exists(
    select 1
    from public.optimization_runs_v2 r
    join solver_private.optimization_attempts_v2 a
      on a.run_id=r.id and a.id=p_attempt_id
    where r.id=p_run_id and r.lease_token=p_lease_token
      and r.lease_expires_at>now() and a.lease_token=p_lease_token
      and a.status='RUNNING' and r.status in ('RUNNING','VALIDATING','CANCEL_REQUESTED')
  );
$$;


ALTER FUNCTION "solver_private"."lease_is_live_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid") OWNER TO "postgres";

--
-- Name: lock_planning_revision_v2(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."lock_planning_revision_v2"() RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_revision bigint;
begin
  select r.revision
  into strict v_revision
  from solver_private.planning_data_revision_v2 r
  where r.singleton
  for update;
  return v_revision;
end;
$$;


ALTER FUNCTION "solver_private"."lock_planning_revision_v2"() OWNER TO "postgres";

--
-- Name: FUNCTION "lock_planning_revision_v2"(); Type: COMMENT; Schema: solver_private; Owner: postgres
--

COMMENT ON FUNCTION "solver_private"."lock_planning_revision_v2"() IS 'Takes the exclusive transaction-scoped planning revision lock and returns the current revision.';


--
-- Name: materialized_variant_payload_v2("uuid"[], "jsonb", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."materialized_variant_payload_v2"("p_variant_ids" "uuid"[], "p_snapshot" "jsonb", "p_strategy_id" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  with requested as (
    select distinct x.variant_id from unnest(coalesce(p_variant_ids,'{}'::uuid[])) x(variant_id)
  ), assignment_rows as (
    select pa.id,pa.slot_key as slot_id,pa.employee_id,coalesce(pa.explanation,'{}'::jsonb) explanation
    from public.plan_assignments_v2 pa join requested r on r.variant_id=pa.variant_id
  ), assignment_payload as (
    select ar.slot_id as slot_key,ar.employee_id,ar.explanation,
      coalesce((select sum((c.calculation_basis->>'costUnits')::bigint)
        from solver_private.plan_assignment_cost_components_v2 c where c.assignment_id=ar.id),0)::bigint cost_units,
      coalesce((select jsonb_agg(jsonb_build_object(
        'ruleId',coalesce(c.pay_rule_id::text,'BASE'),'calculationType',c.component_code,
        'costUnits',(c.calculation_basis->>'costUnits')::bigint) order by c.id)
        from solver_private.plan_assignment_cost_components_v2 c where c.assignment_id=ar.id),'[]'::jsonb) cost_components
    from assignment_rows ar
  ), snapshot_slots as (
    select s.value->>'slotId' slot_id from jsonb_array_elements(coalesce(p_snapshot->'slots','[]'::jsonb)) s
  ), selected_map as (
    select jsonb_object_agg(s.slot_id,to_jsonb(a.employee_id) order by s.slot_id) payload
    from snapshot_slots s left join assignment_rows a using(slot_id)
  )
  select jsonb_build_object(
    'schemaVersion',2,'strategyId',p_strategy_id,
    'solutionHash',(select encode(extensions.digest(convert_to(
      solver_private.canonical_json_v2(m.payload),'UTF8'),'sha256'),'hex') from selected_map m),
    'assignments',coalesce((select jsonb_agg(jsonb_build_object(
      'slotId',a.slot_key,'employeeId',a.employee_id,'costUnits',a.cost_units,
      'costComponents',a.cost_components,
      'limitOverride',coalesce((a.explanation->>'limitOverride')::boolean,false),
      'limitOverrideDetails',coalesce(a.explanation->'limitOverrideDetails','[]'::jsonb),
      'overtimeDecision',nullif(a.explanation->>'overtimeDecision',''),
      'overtimeApprovedBy',nullif(a.explanation->>'overtimeApprovedBy',''),
      'overtimeApprovedAt',nullif(a.explanation->>'overtimeApprovedAt',''),
      'overtimeQuote',coalesce(a.explanation->'overtimeQuote','{}'::jsonb)
    ) order by a.slot_key,a.employee_id) from assignment_payload a),'[]'::jsonb),
    'unfilledSlotIds',coalesce((select jsonb_agg(s.value->>'slotId' order by s.ordinality)
      from jsonb_array_elements(coalesce(p_snapshot->'slots','[]'::jsonb)) with ordinality s(value,ordinality)
      where not exists(select 1 from assignment_rows a where a.slot_id=s.value->>'slotId')),'[]'::jsonb),
    'metrics',jsonb_build_object(
      'UNFILLED',(select count(*) from snapshot_slots s where not exists(
        select 1 from assignment_rows a where a.slot_id=s.slot_id)),
      'TOTAL_COST',coalesce((select sum(a.cost_units) from assignment_payload a),0)),
    'stageObjectives','[]'::jsonb,'optimal',false
  );
$$;


ALTER FUNCTION "solver_private"."materialized_variant_payload_v2"("p_variant_ids" "uuid"[], "p_snapshot" "jsonb", "p_strategy_id" "uuid") OWNER TO "postgres";

--
-- Name: matrix_covers_planning_month_uat_v1("date", "date"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."matrix_covers_planning_month_uat_v1"("p_effective_from" "date", "p_month" "date") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
  select p_effective_from<=date_trunc('month',p_month)::date
    or (
      p_effective_from<(date_trunc('month',p_month)+interval '1 month')::date
      and not exists(
        select 1 from public.matrix_versions prior_matrix
        where prior_matrix.status in ('ACTIVE','ARCHIVED')
          and prior_matrix.schema_version>=2
          and prior_matrix.effective_from<=date_trunc('month',p_month)::date
          and coalesce(prior_matrix.content_hash,'') ~ '^[0-9a-f]{64}$'
          and coalesce(prior_matrix.workforce_hash,'') ~ '^[0-9a-f]{64}$'
      )
    );
$_$;


ALTER FUNCTION "solver_private"."matrix_covers_planning_month_uat_v1"("p_effective_from" "date", "p_month" "date") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_covers_planning_month_uat_v1"("p_effective_from" "date", "p_month" "date"); Type: COMMENT; Schema: solver_private; Owner: postgres
--

COMMENT ON FUNCTION "solver_private"."matrix_covers_planning_month_uat_v1"("p_effective_from" "date", "p_month" "date") IS 'UAT first-run fallback: resolves the first immutable configuration published inside a month only when no earlier configuration covered that month start.';


--
-- Name: matrix_duty_deactivation_guard_uat006(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."matrix_duty_deactivation_guard_uat006"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if old.active and not new.active and (
    exists(select 1 from public.matrix_role_duties_v2 link
      where link.matrix_version_id=old.matrix_version_id and link.duty_id=old.id and link.active)
    or exists(select 1 from public.matrix_employee_duties_v2 link
      where link.matrix_version_id=old.matrix_version_id and link.duty_id=old.id and link.active)
    or exists(select 1 from public.matrix_staffing_rules_v2 rule
      where rule.matrix_version_id=old.matrix_version_id and rule.duty_id=old.id and rule.active)
    or exists(select 1 from public.matrix_pay_rule_duties_v2 link
      where link.matrix_version_id=old.matrix_version_id and link.duty_id=old.id)
  ) then
    raise exception 'DUTY_ARCHIVE_REQUIRES_AUDITED_RPC';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."matrix_duty_deactivation_guard_uat006"() OWNER TO "postgres";

--
-- Name: matrix_employee_role_semantics_uat_v1(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."matrix_employee_role_semantics_uat_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  if new.is_primary then
    new.assignment_mode := 'STANDARD';
    new.backup_priority := greatest(1, least(999, coalesce(new.backup_priority, 100)));
  else
    new.assignment_mode := 'BACKUP';
    new.backup_priority := greatest(1, least(999, coalesce(new.backup_priority, 100)));
  end if;
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."matrix_employee_role_semantics_uat_v1"() OWNER TO "postgres";

--
-- Name: matrix_role_category_inherit_uat_v1(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."matrix_role_category_inherit_uat_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_source record; v_category uuid;
begin
  if new.category_id is not null then return new; end if;
  select category.logical_id,category.code,category.name,category.description,
    category.color,category.sort_order,category.active
  into v_source
  from public.matrix_roles_v2 source_role
  join public.matrix_role_categories_v2 category on category.id=source_role.category_id
  where source_role.logical_id=new.logical_id and source_role.matrix_version_id<>new.matrix_version_id
  order by source_role.updated_at desc limit 1;
  if v_source.code is null then return new; end if;
  insert into public.matrix_role_categories_v2(
    matrix_version_id,logical_id,code,name,description,color,sort_order,active
  ) values(
    new.matrix_version_id,v_source.logical_id,v_source.code,v_source.name,
    v_source.description,v_source.color,v_source.sort_order,v_source.active
  ) on conflict(matrix_version_id,code) do update set
    name=excluded.name,description=excluded.description,color=excluded.color,
    sort_order=excluded.sort_order,active=excluded.active,updated_at=now()
  returning id into v_category;
  new.category_id:=v_category;
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."matrix_role_category_inherit_uat_v1"() OWNER TO "postgres";

--
-- Name: matrix_v2_assert_workbook_identity_uat_v1("jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."matrix_v2_assert_workbook_identity_uat_v1"("p_configuration" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_workbook jsonb:=coalesce(p_configuration->'_workbook','{}'::jsonb);
  v_mode text:=coalesce(v_workbook->>'mode','');
  v_contract text:=coalesce(v_workbook->>'contractVersion','');
  v_source text:=coalesce(v_workbook->>'sourceMatrixVersionId','');
  v_draft uuid;
  v_draft_count integer;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
  if jsonb_typeof(p_configuration)<>'object' then raise exception 'INVALID_TEAM_IMPORT_PAYLOAD'; end if;
  if v_workbook ? 'organizationId' or v_workbook ? 'tenantId' then
    raise exception 'WORKBOOK_SCOPE_IDENTIFIER_FORBIDDEN';
  end if;
  if v_contract<>'2' then raise exception 'WORKBOOK_CONTRACT_UNSUPPORTED'; end if;
  if v_mode not in ('EMPTY_TEMPLATE','CURRENT_CONFIG_EXPORT') then
    raise exception 'WORKBOOK_METADATA_REQUIRED';
  end if;

  select count(*) into v_draft_count
  from public.matrix_versions
  where status='DRAFT' and schema_version>=2;
  if v_draft_count<>1 then raise exception 'MATRIX_V2_SINGLE_DRAFT_REQUIRED'; end if;
  select id into v_draft from public.matrix_versions where status='DRAFT' and schema_version>=2 limit 1;

  if v_mode='EMPTY_TEMPLATE' then
    if v_source<>'' then raise exception 'WORKBOOK_SOURCE_MATRIX_INVALID'; end if;
  else
    if v_source!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
      raise exception 'WORKBOOK_SOURCE_MATRIX_INVALID';
    end if;
    if v_source::uuid<>v_draft then raise exception 'WORKBOOK_SOURCE_MATRIX_STALE'; end if;
  end if;
  return jsonb_build_object('mode',v_mode,'contractVersion',v_contract,'currentDraftId',v_draft);
end;
$_$;


ALTER FUNCTION "solver_private"."matrix_v2_assert_workbook_identity_uat_v1"("p_configuration" "jsonb") OWNER TO "postgres";

--
-- Name: matrix_v2_discard_decision_uat_v1(integer, integer); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."matrix_v2_discard_decision_uat_v1"("p_draft_count" integer, "p_active_count" integer) RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
begin
  if p_draft_count>1 then return 'MULTIPLE_DRAFTS'; end if;
  if p_draft_count=1 and p_active_count=0 then return 'PRESERVE_ONLY_DRAFT'; end if;
  if p_draft_count=1 and p_active_count>0 then return 'DISCARD_DRAFT'; end if;
  if p_draft_count=0 and p_active_count=0 then return 'ENSURE_FIRST_RUN'; end if;
  return 'NOOP_ACTIVE';
end;
$$;


ALTER FUNCTION "solver_private"."matrix_v2_discard_decision_uat_v1"("p_draft_count" integer, "p_active_count" integer) OWNER TO "postgres";

--
-- Name: matrix_v2_full_finance_payload_uat_v1("jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."matrix_v2_full_finance_payload_uat_v1"("p_finance" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select jsonb_set(coalesce(p_finance,'{}'::jsonb),'{payRates}',coalesce((
    select jsonb_agg(case
      when nullif(value->>'rateId','') is not null
        and pg_catalog.pg_input_is_valid(value->>'rateId','uuid')
        and not exists(select 1 from public.employee_pay_rates_v2 rate where rate.id=(value->>'rateId')::uuid)
      then value||jsonb_build_object('rateId','') else value end order by (value->>'sourceRow')::integer)
    from jsonb_array_elements(coalesce(p_finance->'payRates','[]'::jsonb))
  ),'[]'::jsonb),true);
$$;


ALTER FUNCTION "solver_private"."matrix_v2_full_finance_payload_uat_v1"("p_finance" "jsonb") OWNER TO "postgres";

--
-- Name: matrix_v2_full_import_configuration_uat_v2("jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."matrix_v2_full_import_configuration_uat_v2"("p_configuration" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "solver_private"."matrix_v2_full_import_configuration_uat_v2"("p_configuration" "jsonb") OWNER TO "postgres";

--
-- Name: matrix_v2_full_import_phase_before_categories_uat_v1("jsonb", "text"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."matrix_v2_full_import_phase_before_categories_uat_v1"("p_configuration" "jsonb", "p_phase" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "solver_private"."matrix_v2_full_import_phase_before_categories_uat_v1"("p_configuration" "jsonb", "p_phase" "text") OWNER TO "postgres";

--
-- Name: matrix_v2_full_import_phase_before_empty_dictionary_guard_uat_v("jsonb", "text"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."matrix_v2_full_import_phase_before_empty_dictionary_guard_uat_v"("p_configuration" "jsonb", "p_phase" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_result jsonb;
  v_matrix uuid;
  v_item jsonb;
  v_category uuid;
  v_role uuid;
  v_payload jsonb;
  v_configuration jsonb:=coalesce(p_configuration,'{}'::jsonb);
begin
  if upper(trim(coalesce(p_phase,'')))='PRE' then
    select id into v_matrix from public.matrix_versions
    where status='DRAFT' and schema_version>=2
    order by version desc limit 1;
    if v_matrix is null then raise exception 'MATRIX_V2_DRAFT_NOT_FOUND'; end if;

    for v_item in
      select value from jsonb_array_elements(coalesce(v_configuration->'roleCategories','[]'::jsonb))
    loop
      if length(trim(coalesce(v_item->>'code','')))=0
         or length(trim(coalesce(v_item->>'name','')))=0 then
        raise exception 'INVALID_ROLE_CATEGORY';
      end if;
      insert into public.matrix_role_categories_v2(
        matrix_version_id,logical_id,code,name,description,color,sort_order,active
      ) values(
        v_matrix,
        public.matrix_v2_stable_uuid('ROLE_CATEGORY_LOGICAL:'||upper(trim(v_item->>'code'))),
        upper(trim(v_item->>'code')),
        trim(v_item->>'name'),
        nullif(trim(v_item->>'description'),''),
        coalesce(nullif(trim(v_item->>'color'),''),'#7257d8'),
        coalesce(nullif(v_item->>'sortOrder','')::integer,0),
        coalesce((v_item->>'active')::boolean,true)
      ) on conflict(matrix_version_id,code) do update set
        name=excluded.name,
        description=excluded.description,
        color=excluded.color,
        sort_order=excluded.sort_order,
        active=excluded.active,
        updated_at=now();
    end loop;

    for v_item in
      select value from jsonb_array_elements(coalesce(v_configuration->'roles','[]'::jsonb))
    loop
      select id into v_category from public.matrix_role_categories_v2
      where matrix_version_id=v_matrix
        and code=upper(trim(coalesce(nullif(v_item->>'categoryCode',''),v_item->>'code')))
        and active;
      if v_category is null then
        raise exception 'ROLE_CATEGORY_NOT_FOUND|%|%',
          coalesce(v_item->>'code',''),coalesce(v_item->>'categoryCode','');
      end if;

      select id into v_role from public.matrix_roles_v2
      where matrix_version_id=v_matrix and code=upper(trim(v_item->>'code'));
      v_payload:=v_item||jsonb_build_object('categoryId',v_category);
      perform public.matrix_v2_admin_save_alpha16('ROLE',v_role,v_payload);
    end loop;

    v_configuration:=jsonb_set(
      jsonb_set(v_configuration,'{roleCategories}','[]'::jsonb,true),
      '{roles}','[]'::jsonb,true
    );
  end if;

  v_result:=solver_private.matrix_v2_full_import_phase_before_explicit_roles_uat_v1(
    v_configuration,p_phase
  );
  return v_result||jsonb_build_object('rolesAppliedBeforeEmployees',true);
end;
$$;


ALTER FUNCTION "solver_private"."matrix_v2_full_import_phase_before_empty_dictionary_guard_uat_v"("p_configuration" "jsonb", "p_phase" "text") OWNER TO "postgres";

--
-- Name: matrix_v2_full_import_phase_before_explicit_roles_uat_v1("jsonb", "text"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."matrix_v2_full_import_phase_before_explicit_roles_uat_v1"("p_configuration" "jsonb", "p_phase" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_result jsonb;
  v_matrix uuid;
  v_item jsonb;
  v_category uuid;
  v_employee uuid;
  v_role uuid;
  v_role_code text;
  v_mode text;
  v_priority integer;
  v_count integer:=0;
begin
  select id into v_matrix from public.matrix_versions
  where status='DRAFT' and schema_version>=2 order by version desc limit 1;
  if v_matrix is null then raise exception 'MATRIX_V2_DRAFT_NOT_FOUND'; end if;

  if upper(trim(coalesce(p_phase,'')))='PRE' then
    for v_item in select value from jsonb_array_elements(coalesce(p_configuration->'roleCategories','[]'::jsonb)) loop
      if length(trim(coalesce(v_item->>'code','')))=0 or length(trim(coalesce(v_item->>'name','')))=0 then
        raise exception 'INVALID_ROLE_CATEGORY';
      end if;
      insert into public.matrix_role_categories_v2(
        matrix_version_id,logical_id,code,name,description,color,sort_order,active
      ) values(
        v_matrix,public.matrix_v2_stable_uuid('ROLE_CATEGORY_LOGICAL:'||upper(trim(v_item->>'code'))),
        upper(trim(v_item->>'code')),trim(v_item->>'name'),nullif(trim(v_item->>'description'),''),
        coalesce(nullif(trim(v_item->>'color'),''),'#7257d8'),
        coalesce(nullif(v_item->>'sortOrder','')::integer,0),coalesce((v_item->>'active')::boolean,true)
      ) on conflict(matrix_version_id,code) do update set
        name=excluded.name,description=excluded.description,color=excluded.color,
        sort_order=excluded.sort_order,active=excluded.active,updated_at=now();
    end loop;
  end if;

  v_result:=solver_private.matrix_v2_full_import_phase_before_categories_uat_v1(p_configuration,p_phase);

  if upper(trim(coalesce(p_phase,'')))='PRE' then
    for v_item in select value from jsonb_array_elements(coalesce(p_configuration->'roles','[]'::jsonb)) loop
      select id into v_role from public.matrix_roles_v2
      where matrix_version_id=v_matrix and code=upper(trim(v_item->>'code'));
      select id into v_category from public.matrix_role_categories_v2
      where matrix_version_id=v_matrix and code=upper(trim(coalesce(nullif(v_item->>'categoryCode',''),v_item->>'code')));
      if v_role is null then raise exception 'ROLE_NOT_FOUND|%',coalesce(v_item->>'code',''); end if;
      if v_category is null then raise exception 'ROLE_CATEGORY_NOT_FOUND|%|%',coalesce(v_item->>'code',''),coalesce(v_item->>'categoryCode',''); end if;
      update public.matrix_roles_v2 set category_id=v_category,updated_at=now() where id=v_role;
    end loop;
  end if;

  if upper(trim(coalesce(p_phase,'')))='POST' then
    for v_item in select value from jsonb_array_elements(coalesce(p_configuration->'employees','[]'::jsonb)) loop
      select e.id into v_employee from public.employees e
      where (nullif(trim(v_item->>'employeeNo'),'') is not null and e.employee_no=trim(v_item->>'employeeNo'))
        or (nullif(trim(v_item->>'email'),'') is not null and lower(e.email)=lower(trim(v_item->>'email')))
      order by e.active desc limit 1;
      if v_employee is null then continue; end if;
      update public.matrix_employee_profiles_v2 set
        employment_stage=case upper(coalesce(nullif(v_item->>'employmentStage',''),'REGULAR'))
          when 'PROBATION' then 'PROBATION' when 'NOTICE' then 'NOTICE' else 'REGULAR' end,
        probation_end=nullif(v_item->>'probationEnd','')::date,
        updated_at=now(),updated_by=auth.uid()
      where matrix_version_id=v_matrix and employee_id=v_employee;

      for v_role_code,v_priority in
        select upper(trim(x.value->>'roleCode')),coalesce(nullif(x.value->>'priority','')::integer,100)
        from jsonb_array_elements(coalesce(v_item->'backupRoles','[]'::jsonb)) x
      loop
        select id into v_role from public.matrix_roles_v2
        where matrix_version_id=v_matrix and code=v_role_code and active;
        if v_role is null then raise exception 'ROLE_NOT_FOUND|%',v_role_code; end if;
        insert into public.matrix_employee_roles_v2(
          matrix_version_id,employee_id,role_id,is_primary,can_lead,active,
          assignment_mode,backup_priority,created_by,updated_by
        ) values(v_matrix,v_employee,v_role,false,false,true,'BACKUP',greatest(1,least(999,v_priority)),auth.uid(),auth.uid())
        on conflict(matrix_version_id,employee_id,role_id) do update set
          is_primary=false,active=true,assignment_mode='BACKUP',
          backup_priority=excluded.backup_priority,updated_by=auth.uid(),updated_at=now();
      end loop;
    end loop;

    for v_item in select value from jsonb_array_elements(coalesce(p_configuration->'employeeRoles','[]'::jsonb)) loop
      select e.id into v_employee from public.employees e where e.employee_no=trim(v_item->>'employeeNo');
      select r.id into v_role from public.matrix_roles_v2 r
        where r.matrix_version_id=v_matrix and r.code=upper(trim(v_item->>'roleCode'));
      v_mode:=case upper(coalesce(nullif(v_item->>'assignmentMode',''),'STANDARD')) when 'BACKUP' then 'BACKUP' else 'STANDARD' end;
      v_priority:=greatest(1,least(999,coalesce(nullif(v_item->>'backupPriority','')::integer,100)));
      if v_employee is not null and v_role is not null then
        update public.matrix_employee_roles_v2 set
          assignment_mode=case when is_primary then 'STANDARD' else v_mode end,
          backup_priority=v_priority,updated_by=auth.uid(),updated_at=now()
        where matrix_version_id=v_matrix and employee_id=v_employee and role_id=v_role;
      end if;
    end loop;

    if p_configuration ? 'adHocWorkers' then
      delete from public.recovery_ad_hoc_pool_v2 where true;
      for v_item in select value from jsonb_array_elements(coalesce(p_configuration->'adHocWorkers','[]'::jsonb)) loop
        select id into v_role from public.matrix_roles_v2
        where matrix_version_id=v_matrix and code=upper(trim(v_item->>'roleCode')) and active;
        if v_role is null then raise exception 'ROLE_NOT_FOUND|%',coalesce(v_item->>'roleCode',''); end if;
        insert into public.recovery_ad_hoc_pool_v2(
          display_name,email,phone,role_id,contract_type,base_rate_minor,currency,
          available_from,available_to,active,notes,created_by
        ) values(
          trim(v_item->>'displayName'),nullif(lower(trim(v_item->>'email')),''),nullif(trim(v_item->>'phone'),''),v_role,
          upper(coalesce(nullif(v_item->>'contractType',''),'ZLECENIE')),
          nullif(v_item->>'baseRateMinor','')::bigint,upper(coalesce(nullif(v_item->>'currency',''),'PLN')),
          nullif(v_item->>'availableFrom','')::date,nullif(v_item->>'availableTo','')::date,
          coalesce((v_item->>'active')::boolean,true),nullif(trim(v_item->>'notes'),''),auth.uid()
        );
        v_count:=v_count+1;
      end loop;
    end if;
  end if;
  return v_result||jsonb_build_object('roleCategoriesApplied',true,'adHocWorkersApplied',v_count);
end;
$$;


ALTER FUNCTION "solver_private"."matrix_v2_full_import_phase_before_explicit_roles_uat_v1"("p_configuration" "jsonb", "p_phase" "text") OWNER TO "postgres";

--
-- Name: matrix_v2_full_import_phase_before_overtime_uat_v1("jsonb", "text"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."matrix_v2_full_import_phase_before_overtime_uat_v1"("p_configuration" "jsonb", "p_phase" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_configuration jsonb:=coalesce(p_configuration,'{}'::jsonb);
  v_key text;
  v_sheet text;
  v_invalid jsonb;
begin
  if upper(trim(coalesce(p_phase,'')))='PRE' then
    foreach v_key in array array['roleCategories','roles','locations','duties'] loop
      v_sheet:=case v_key
        when 'roleCategories' then 'Kategorie grafików'
        when 'roles' then 'Role'
        when 'locations' then 'Lokale'
        else 'Obowiązki'
      end;

      select item.value into v_invalid
      from jsonb_array_elements(coalesce(v_configuration->v_key,'[]'::jsonb)) item(value)
      where nullif(trim(item.value->>'code'),'') is not null
        and nullif(trim(item.value->>'name'),'') is null
      limit 1;

      if v_invalid is not null then
        raise exception 'FULL_IMPORT_DICTIONARY_VALUE_REQUIRED|%|%|Nazwa',
          v_sheet,coalesce(nullif(v_invalid->>'sourceRow',''),'nieznany');
      end if;

      v_configuration:=jsonb_set(
        v_configuration,
        array[v_key],
        coalesce((
          select jsonb_agg(item.value order by item.ordinality)
          from jsonb_array_elements(coalesce(v_configuration->v_key,'[]'::jsonb))
            with ordinality item(value,ordinality)
          where nullif(trim(item.value->>'code'),'') is not null
             or nullif(trim(item.value->>'name'),'') is not null
        ),'[]'::jsonb),
        true
      );
    end loop;
  end if;

  return solver_private.matrix_v2_full_import_phase_before_empty_dictionary_guard_uat_v1(
    v_configuration,p_phase
  )||jsonb_build_object('emptyDictionaryRowsIgnored',true);
end;
$$;


ALTER FUNCTION "solver_private"."matrix_v2_full_import_phase_before_overtime_uat_v1"("p_configuration" "jsonb", "p_phase" "text") OWNER TO "postgres";

--
-- Name: matrix_v2_full_import_phase_raw_uat_v1("jsonb", "text"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."matrix_v2_full_import_phase_raw_uat_v1"("p_configuration" "jsonb", "p_phase" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_phase text:=upper(trim(coalesce(p_phase,'')));
  v_matrix uuid;
  v_row jsonb;
  v_existing uuid;
  v_employee uuid;
  v_role uuid;
  v_location uuid;
  v_duty uuid;
  v_scenario uuid;
  v_strategy uuid;
  v_pay_rule uuid;
  v_parent uuid;
  v_constraint uuid;
  v_role_ids jsonb;
  v_duty_ids jsonb;
  v_location_ids jsonb;
  v_shift_ids jsonb;
  v_applied integer:=0;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if p_configuration is null or jsonb_typeof(p_configuration)<>'object' then
    raise exception 'INVALID_FULL_IMPORT_CONFIGURATION';
  end if;
  if v_phase not in ('PRE','POST') then raise exception 'INVALID_FULL_IMPORT_PHASE'; end if;
  v_matrix:=public.matrix_v2_create_draft(null);

  if v_phase='PRE' then
    if jsonb_typeof(p_configuration->'settings')='object' then
      perform public.matrix_v2_admin_save_alpha16('MATRIX_SETTINGS',null,p_configuration->'settings');
      v_applied:=v_applied+1;
    end if;

    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'roles','[]'::jsonb)) loop
      select item.id into v_existing from public.matrix_roles_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'code');
      perform public.matrix_v2_admin_save_alpha16('ROLE',v_existing,v_row);
      v_applied:=v_applied+1;
    end loop;
    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'locations','[]'::jsonb)) loop
      select item.id into v_existing from public.matrix_locations_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'code');
      perform public.matrix_v2_admin_save_alpha16('LOCATION',v_existing,v_row);
      v_applied:=v_applied+1;
    end loop;
    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'duties','[]'::jsonb)) loop
      select item.id into v_existing from public.matrix_duties_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'code');
      perform public.matrix_v2_admin_save_alpha16('DUTY',v_existing,v_row);
      v_applied:=v_applied+1;
    end loop;

    -- Root scenarios are created first so child rows can resolve their parent code.
    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'scenarios','[]'::jsonb))
      where nullif(trim(value->>'parentScenarioCode'),'') is null loop
      select item.id into v_existing from public.matrix_scenarios_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'code');
      perform public.matrix_v2_admin_save_alpha16('SCENARIO',v_existing,
        v_row||jsonb_build_object('parentScenarioId',null));
      v_applied:=v_applied+1;
    end loop;
    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'scenarios','[]'::jsonb)) loop
      v_parent:=null;
      if nullif(trim(v_row->>'parentScenarioCode'),'') is not null then
        select item.id into v_parent from public.matrix_scenarios_v2 item
        where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'parentScenarioCode');
        if v_parent is null then raise exception 'FULL_IMPORT_PARENT_SCENARIO_NOT_FOUND|%',v_row->>'parentScenarioCode'; end if;
      end if;
      select item.id into v_existing from public.matrix_scenarios_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'code');
      perform public.matrix_v2_admin_save_alpha16('SCENARIO',v_existing,
        v_row||jsonb_build_object('parentScenarioId',v_parent));
    end loop;
    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'strategies','[]'::jsonb)) loop
      select item.id into v_existing from public.matrix_strategies_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'code');
      perform public.matrix_v2_admin_save_alpha16('STRATEGY',v_existing,v_row);
      v_applied:=v_applied+1;
    end loop;
  else
    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'strategyObjectives','[]'::jsonb)) loop
      select item.id into v_strategy from public.matrix_strategies_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'strategyCode');
      if v_strategy is null then raise exception 'FULL_IMPORT_STRATEGY_NOT_FOUND|%',v_row->>'strategyCode'; end if;
      perform public.matrix_v2_admin_save_alpha16('OBJECTIVE',null,
        v_row||jsonb_build_object('strategyId',v_strategy));
      v_applied:=v_applied+1;
    end loop;
    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'scenarioStrategies','[]'::jsonb)) loop
      select item.id into v_scenario from public.matrix_scenarios_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'scenarioCode');
      select item.id into v_strategy from public.matrix_strategies_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'strategyCode');
      if v_scenario is null or v_strategy is null then
        raise exception 'FULL_IMPORT_SCENARIO_STRATEGY_NOT_FOUND|%|%',v_row->>'scenarioCode',v_row->>'strategyCode';
      end if;
      perform public.matrix_v2_admin_save_alpha16('SCENARIO_STRATEGY',null,
        v_row||jsonb_build_object('scenarioId',v_scenario,'strategyId',v_strategy));
      v_applied:=v_applied+1;
    end loop;

    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'payRules','[]'::jsonb)) loop
      select item.id into v_existing from public.matrix_pay_rules_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'code');
      select coalesce(jsonb_agg(item.id::text),'[]'::jsonb) into v_role_ids
      from public.matrix_roles_v2 item where item.matrix_version_id=v_matrix
        and upper(item.code) in (select upper(value) from jsonb_array_elements_text(coalesce(v_row->'roleCodes','[]'::jsonb)));
      select coalesce(jsonb_agg(item.id::text),'[]'::jsonb) into v_duty_ids
      from public.matrix_duties_v2 item where item.matrix_version_id=v_matrix
        and upper(item.code) in (select upper(value) from jsonb_array_elements_text(coalesce(v_row->'dutyCodes','[]'::jsonb)));
      select coalesce(jsonb_agg(item.id::text),'[]'::jsonb) into v_location_ids
      from public.matrix_locations_v2 item where item.matrix_version_id=v_matrix
        and upper(item.code) in (select upper(value) from jsonb_array_elements_text(coalesce(v_row->'locationCodes','[]'::jsonb)));
      select coalesce(jsonb_agg(item.id::text),'[]'::jsonb) into v_shift_ids
      from public.matrix_shift_templates_v2 item where item.matrix_version_id=v_matrix
        and upper(item.code) in (select upper(value) from jsonb_array_elements_text(coalesce(v_row->'shiftCodes','[]'::jsonb)));
      perform public.matrix_v2_admin_save_alpha16('PAY_RULE',v_existing,v_row||jsonb_build_object(
        'roleIds',v_role_ids,'dutyIds',v_duty_ids,'locationIds',v_location_ids,'shiftIds',v_shift_ids));
      v_applied:=v_applied+1;
    end loop;
    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'scenarioPayRuleOverrides','[]'::jsonb)) loop
      select item.id into v_scenario from public.matrix_scenarios_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'scenarioCode');
      select item.id into v_pay_rule from public.matrix_pay_rules_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'payRuleCode');
      if v_scenario is null or v_pay_rule is null then
        raise exception 'FULL_IMPORT_SCENARIO_PAY_RULE_NOT_FOUND|%|%',v_row->>'scenarioCode',v_row->>'payRuleCode';
      end if;
      perform public.matrix_v2_admin_save_alpha16('SCENARIO_PAY_RULE',null,
        v_row||jsonb_build_object('scenarioId',v_scenario,'payRuleId',v_pay_rule));
      v_applied:=v_applied+1;
    end loop;
    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'scenarioBudgets','[]'::jsonb)) loop
      select item.id into v_scenario from public.matrix_scenarios_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'scenarioCode');
      select item.id into v_location from public.matrix_locations_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(nullif(v_row->>'locationCode',''));
      select item.id into v_role from public.matrix_roles_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(nullif(v_row->>'roleCode',''));
      select item.id into v_duty from public.matrix_duties_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(nullif(v_row->>'dutyCode',''));
      if v_scenario is null then raise exception 'FULL_IMPORT_SCENARIO_NOT_FOUND|%',v_row->>'scenarioCode'; end if;
      perform public.matrix_v2_admin_save_alpha16('SCENARIO_BUDGET',null,v_row||jsonb_build_object(
        'scenarioId',v_scenario,'locationId',v_location,'roleId',v_role,'dutyId',v_duty));
      v_applied:=v_applied+1;
    end loop;

    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'employeeRoles','[]'::jsonb)) loop
      select item.employee_id into v_employee from public.matrix_employee_profiles_v2 item
      where item.matrix_version_id=v_matrix and upper(item.employee_no)=upper(v_row->>'employeeNo');
      select item.id into v_role from public.matrix_roles_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'roleCode');
      if v_employee is null or v_role is null then raise exception 'FULL_IMPORT_EMPLOYEE_ROLE_NOT_FOUND|%|%',v_row->>'employeeNo',v_row->>'roleCode'; end if;
      perform public.matrix_v2_admin_save_alpha16('EMPLOYEE_ROLE',null,
        v_row||jsonb_build_object('employeeId',v_employee,'roleId',v_role));
      v_applied:=v_applied+1;
    end loop;
    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'employeeLocationsDetailed','[]'::jsonb)) loop
      select item.employee_id into v_employee from public.matrix_employee_profiles_v2 item
      where item.matrix_version_id=v_matrix and upper(item.employee_no)=upper(v_row->>'employeeNo');
      select item.id into v_location from public.matrix_locations_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'locationCode');
      if v_employee is null or v_location is null then raise exception 'FULL_IMPORT_EMPLOYEE_LOCATION_NOT_FOUND|%|%',v_row->>'employeeNo',v_row->>'locationCode'; end if;
      perform public.matrix_v2_admin_save_alpha16('EMPLOYEE_LOCATION',null,
        v_row||jsonb_build_object('employeeId',v_employee,'locationId',v_location));
      v_applied:=v_applied+1;
    end loop;
    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'employeeCapabilities','[]'::jsonb)) loop
      select item.employee_id into v_employee from public.matrix_employee_profiles_v2 item
      where item.matrix_version_id=v_matrix and upper(item.employee_no)=upper(v_row->>'employeeNo');
      select item.id into v_duty from public.matrix_duties_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(v_row->>'dutyCode');
      select item.id into v_role from public.matrix_roles_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(nullif(v_row->>'roleCode',''));
      select item.id into v_location from public.matrix_locations_v2 item
      where item.matrix_version_id=v_matrix and upper(item.code)=upper(nullif(v_row->>'locationCode',''));
      if v_employee is null or v_duty is null then raise exception 'FULL_IMPORT_EMPLOYEE_DUTY_NOT_FOUND|%|%',v_row->>'employeeNo',v_row->>'dutyCode'; end if;
      perform public.matrix_v2_admin_save_alpha16('EMPLOYEE_DUTY',null,v_row||jsonb_build_object(
        'employeeId',v_employee,'dutyId',v_duty,'roleId',v_role,'locationId',v_location));
      v_applied:=v_applied+1;
    end loop;

    for v_row in select value from jsonb_array_elements(coalesce(p_configuration->'timeConstraints','[]'::jsonb))
      where coalesce((value->>'active')::boolean,true) loop
      select item.employee_id into v_employee from public.matrix_employee_profiles_v2 item
      where item.matrix_version_id=v_matrix and upper(item.employee_no)=upper(v_row->>'employeeNo');
      if v_employee is null then raise exception 'FULL_IMPORT_EMPLOYEE_NOT_FOUND|%',v_row->>'employeeNo'; end if;
      v_constraint:=case when pg_catalog.pg_input_is_valid(coalesce(v_row->>'constraintId',''),'uuid')
        then (v_row->>'constraintId')::uuid else null end;
      if v_constraint is not null and not exists(select 1 from public.employee_time_constraints_v2 item where item.id=v_constraint) then
        v_constraint:=null;
      end if;
      if v_constraint is null then
        select item.id into v_existing from public.employee_time_constraints_v2 item
        where item.employee_id=v_employee and item.status='ACTIVE'
          and item.constraint_kind=upper(v_row->>'kind')
          and lower(item.time_range)=(v_row->>'startsAt')::timestamptz
          and upper(item.time_range)=(v_row->>'endsAt')::timestamptz
          and coalesce(item.note,'')=coalesce(v_row->>'note','') limit 1;
        if v_existing is not null then continue; end if;
      end if;
      perform public.employee_time_constraint_save_v2(v_constraint,v_employee,v_row->>'kind',
        (v_row->>'startsAt')::timestamptz,(v_row->>'endsAt')::timestamptz,nullif(v_row->>'note',''));
      v_applied:=v_applied+1;
    end loop;
  end if;
  return jsonb_build_object('phase',v_phase,'appliedRows',v_applied,'matrixVersionId',v_matrix);
end;
$$;


ALTER FUNCTION "solver_private"."matrix_v2_full_import_phase_raw_uat_v1"("p_configuration" "jsonb", "p_phase" "text") OWNER TO "postgres";

--
-- Name: matrix_v2_full_import_phase_uat_v1("jsonb", "text"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."matrix_v2_full_import_phase_uat_v1"("p_configuration" "jsonb", "p_phase" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_result jsonb; v_matrix uuid; v_item jsonb; v_policy text; v_employee uuid;
begin
  v_result:=solver_private.matrix_v2_full_import_phase_before_overtime_uat_v1(p_configuration,p_phase);
  if upper(trim(coalesce(p_phase,'')))<>'POST' then return v_result; end if;
  select id into v_matrix from public.matrix_versions where status='DRAFT' and schema_version>=2 order by version desc limit 1;
  for v_item in select value from jsonb_array_elements(coalesce(p_configuration->'employees','[]'::jsonb)) loop
    v_policy:=upper(coalesce(nullif(v_item->>'overtimePolicy',''),'NEVER'));
    if v_policy not in ('NEVER','APPROVAL_REQUIRED','ALLOWED') then raise exception 'INVALID_OVERTIME_POLICY'; end if;
    select profile.employee_id into v_employee from public.matrix_employee_profiles_v2 profile
      where profile.matrix_version_id=v_matrix and (
        (nullif(trim(v_item->>'employeeNo'),'') is not null and upper(profile.employee_no)=upper(trim(v_item->>'employeeNo')))
        or (nullif(trim(v_item->>'email'),'') is not null and lower(profile.email)=lower(trim(v_item->>'email')))
      ) order by case when upper(profile.employee_no)=upper(trim(v_item->>'employeeNo')) then 0 else 1 end limit 1;
    if v_employee is not null then update public.matrix_employee_profiles_v2 set overtime_policy=v_policy,updated_by=auth.uid(),updated_at=now()
      where matrix_version_id=v_matrix and employee_id=v_employee; end if;
  end loop;
  return v_result;
end; $$;


ALTER FUNCTION "solver_private"."matrix_v2_full_import_phase_uat_v1"("p_configuration" "jsonb", "p_phase" "text") OWNER TO "postgres";

--
-- Name: matrix_v2_import_normalize_uat_v3("jsonb", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."matrix_v2_import_normalize_uat_v3"("p_payload" "jsonb", "p_matrix_version_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
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
$_$;


ALTER FUNCTION "solver_private"."matrix_v2_import_normalize_uat_v3"("p_payload" "jsonb", "p_matrix_version_id" "uuid") OWNER TO "postgres";

--
-- Name: matrix_v2_reconnect_preserved_profiles_uat_v1("jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."matrix_v2_reconnect_preserved_profiles_uat_v1"("p_configuration" "jsonb") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "solver_private"."matrix_v2_reconnect_preserved_profiles_uat_v1"("p_configuration" "jsonb") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_reconnect_preserved_profiles_uat_v1"("p_configuration" "jsonb"); Type: COMMENT; Schema: solver_private; Owner: postgres
--

COMMENT ON FUNCTION "solver_private"."matrix_v2_reconnect_preserved_profiles_uat_v1"("p_configuration" "jsonb") IS 'Internal UAT bridge between preserved global employee identities and an empty/reset Matrix draft.';


--
-- Name: matrix_v2_seed_import_shifts_uat_v1("jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."matrix_v2_seed_import_shifts_uat_v1"("p_configuration" "jsonb") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
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
$_$;


ALTER FUNCTION "solver_private"."matrix_v2_seed_import_shifts_uat_v1"("p_configuration" "jsonb") OWNER TO "postgres";

--
-- Name: matrix_v2_seed_required_defaults_before_b4f165("uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."matrix_v2_seed_required_defaults_before_b4f165"("p_matrix_version_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_enabled boolean:=false;
begin
  select c.enabled into v_enabled
  from public.uat_environment_controls c
  where c.control_key='ISOLATED_UAT_DESTRUCTIVE_TOOLS';

  if not coalesce(v_enabled,false) then
    raise exception 'UAT_DESTRUCTIVE_TOOLS_DISABLED';
  end if;
  if not exists(
    select 1 from public.matrix_versions mv
    where mv.id=p_matrix_version_id and mv.status='DRAFT'
  ) then
    raise exception 'UAT_DRAFT_MATRIX_REQUIRED';
  end if;

  insert into public.matrix_scenarios_v2(
    id,matrix_version_id,logical_id,code,name,description,color,is_default,
    active,sort_order,settings_overrides
  )
  select gen_random_uuid(),p_matrix_version_id,
    public.matrix_v2_stable_uuid('SCENARIO:BASE'),
    'BASE','Bazowy','Standardowe zapotrzebowanie','#7457e8',
    not exists(
      select 1 from public.matrix_scenarios_v2 existing
      where existing.matrix_version_id=p_matrix_version_id
        and existing.active and existing.is_default
    ),true,1,'{}'::jsonb
  where not exists(
    select 1 from public.matrix_scenarios_v2 existing
    where existing.matrix_version_id=p_matrix_version_id and existing.code='BASE'
  );

  insert into public.matrix_strategies_v2(
    id,matrix_version_id,logical_id,code,name,description,solver_code,
    solver_options,legacy_weights,sort_order,active
  )
  select gen_random_uuid(),p_matrix_version_id,
    public.matrix_v2_stable_uuid('STRATEGY:'||defaults.code),defaults.code,
    defaults.name,defaults.description,'CP_SAT',
    '{"maxTimeSeconds":120,"randomSeed":0}'::jsonb,defaults.legacy_weights,
    defaults.sort_order,true
  from (values
    ('BALANCED','Zrównoważony',
      'Kompromis kosztu, preferencji i równego obciążenia. Dobry wariant startowy, gdy żaden z tych celów nie ma bezwzględnego pierwszeństwa.',
      '{"cost":1,"preference":80,"fairness":40,"nominal":30,"homeLocation":15,"weekendFairness":25,"overtime":250}'::jsonb,1),
    ('MIN_COST','Minimalny koszt',
      'Po zapewnieniu najlepszej możliwej obsady wybiera najniższy łączny koszt. Nadgodziny i pozostałe kryteria rozstrzygają dopiero przy takim samym koszcie.',
      '{"cost":4,"preference":30,"fairness":15,"nominal":20,"homeLocation":15,"weekendFairness":10,"overtime":500}'::jsonb,2),
    ('PREFERENCES','Preferencje i równy podział',
      'Po uzupełnieniu wymaganej obsady najpierw respektuje prośby pracowników, następnie minimalizuje różnicę obciążenia i odchylenia od celu godzinowego. Koszt rozstrzyga dopiero później.',
      '{"cost":0.5,"preference":250,"fairness":200,"nominal":150,"homeLocation":15,"weekendFairness":180,"overtime":100}'::jsonb,3)
  ) as defaults(code,name,description,legacy_weights,sort_order)
  where not exists(
    select 1 from public.matrix_strategies_v2 existing
    where existing.matrix_version_id=p_matrix_version_id
      and existing.code=defaults.code
  );

  with metric_catalog(metric_code,sort_order) as (values
    ('UNFILLED',1),('TOTAL_COST',2),('PREFERENCE_VIOLATIONS',3),
    ('OVERTIME_MINUTES',4),('NOMINAL_DEVIATION_MINUTES',5),
    ('LOAD_SPREAD_MINUTES',6),('WEEKEND_SPREAD',7),
    ('HOME_LOCATION_VIOLATIONS',8),('BASELINE_CHANGES',9)
  )
  insert into public.matrix_strategy_objectives_v2(
    id,matrix_version_id,strategy_id,tier,sort_order,metric_code,direction,
    weight,tolerance,parameters,active
  )
  select gen_random_uuid(),p_matrix_version_id,strategy.id,
    case
      when metric.metric_code='UNFILLED' then 1
      when strategy.code='BALANCED' then 2
      when strategy.code='MIN_COST' and metric.metric_code='TOTAL_COST' then 2
      when strategy.code='MIN_COST' and metric.metric_code in ('OVERTIME_MINUTES','HOME_LOCATION_VIOLATIONS') then 3
      when strategy.code='MIN_COST' and metric.metric_code='PREFERENCE_VIOLATIONS' then 4
      when strategy.code='MIN_COST' and metric.metric_code in ('WEEKEND_SPREAD','LOAD_SPREAD_MINUTES','NOMINAL_DEVIATION_MINUTES') then 5
      when strategy.code='PREFERENCES' and metric.metric_code='PREFERENCE_VIOLATIONS' then 2
      when strategy.code='PREFERENCES' and metric.metric_code='LOAD_SPREAD_MINUTES' then 3
      when strategy.code='PREFERENCES' and metric.metric_code='NOMINAL_DEVIATION_MINUTES' then 4
      when strategy.code='PREFERENCES' and metric.metric_code='WEEKEND_SPREAD' then 5
      when strategy.code='PREFERENCES' and metric.metric_code in ('TOTAL_COST','HOME_LOCATION_VIOLATIONS') then 6
      when strategy.code='PREFERENCES' then 7
      else 6
    end::smallint,
    metric.sort_order,metric.metric_code,'MINIMIZE',
    case strategy.code
      when 'BALANCED' then case metric.metric_code
        when 'UNFILLED' then 1000000 when 'TOTAL_COST' then 1000
        when 'PREFERENCE_VIOLATIONS' then 80000 when 'OVERTIME_MINUTES' then 250000
        when 'NOMINAL_DEVIATION_MINUTES' then 30000 when 'LOAD_SPREAD_MINUTES' then 40000
        when 'WEEKEND_SPREAD' then 25000 when 'HOME_LOCATION_VIOLATIONS' then 15000
        else 20000 end
      when 'MIN_COST' then case metric.metric_code
        when 'UNFILLED' then 1000000 when 'TOTAL_COST' then 10000
        when 'PREFERENCE_VIOLATIONS' then 30000 when 'OVERTIME_MINUTES' then 500000
        when 'NOMINAL_DEVIATION_MINUTES' then 20000 when 'LOAD_SPREAD_MINUTES' then 15000
        when 'WEEKEND_SPREAD' then 10000 when 'HOME_LOCATION_VIOLATIONS' then 15000
        else 10000 end
      else case metric.metric_code
        when 'UNFILLED' then 1000000 when 'TOTAL_COST' then 500
        when 'PREFERENCE_VIOLATIONS' then 250000 when 'OVERTIME_MINUTES' then 100000
        when 'NOMINAL_DEVIATION_MINUTES' then 150000 when 'LOAD_SPREAD_MINUTES' then 200000
        when 'WEEKEND_SPREAD' then 180000 when 'HOME_LOCATION_VIOLATIONS' then 15000
        else 10000 end
    end::bigint,
    0,'{}'::jsonb,true
  from public.matrix_strategies_v2 strategy
  cross join metric_catalog metric
  where strategy.matrix_version_id=p_matrix_version_id
    and strategy.code in ('BALANCED','MIN_COST','PREFERENCES')
    and not exists(
      select 1 from public.matrix_strategy_objectives_v2 objective
      where objective.strategy_id=strategy.id
        and objective.metric_code=metric.metric_code
    );

  insert into public.matrix_scenario_strategies_v2(
    id,matrix_version_id,scenario_id,strategy_id,sort_order,active,
    objective_overrides,solver_overrides
  )
  select gen_random_uuid(),p_matrix_version_id,scenario.id,strategy.id,
    strategy.sort_order,true,'{}'::jsonb,'{}'::jsonb
  from public.matrix_scenarios_v2 scenario
  join public.matrix_strategies_v2 strategy
    on strategy.matrix_version_id=scenario.matrix_version_id
   and strategy.code in ('BALANCED','MIN_COST','PREFERENCES')
  where scenario.matrix_version_id=p_matrix_version_id
    and scenario.code='BASE'
    and not exists(
      select 1 from public.matrix_scenario_strategies_v2 link
      where link.scenario_id=scenario.id and link.strategy_id=strategy.id
    );
end;
$$;


ALTER FUNCTION "solver_private"."matrix_v2_seed_required_defaults_before_b4f165"("p_matrix_version_id" "uuid") OWNER TO "postgres";

--
-- Name: matrix_v2_seed_required_defaults_before_b4f168("uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."matrix_v2_seed_required_defaults_before_b4f168"("p_matrix_version_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  perform solver_private.matrix_v2_seed_required_defaults_before_b4f165(
    p_matrix_version_id
  );
  perform solver_private.apply_strategy_semantics_b4f165(p_matrix_version_id);
end;
$$;


ALTER FUNCTION "solver_private"."matrix_v2_seed_required_defaults_before_b4f168"("p_matrix_version_id" "uuid") OWNER TO "postgres";

--
-- Name: matrix_v2_seed_required_defaults_before_b4f169("uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."matrix_v2_seed_required_defaults_before_b4f169"("p_matrix_version_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  perform solver_private.matrix_v2_seed_required_defaults_before_b4f168(
    p_matrix_version_id
  );
  perform solver_private.apply_strategy_semantics_b4f168(p_matrix_version_id);
end;
$$;


ALTER FUNCTION "solver_private"."matrix_v2_seed_required_defaults_before_b4f169"("p_matrix_version_id" "uuid") OWNER TO "postgres";

--
-- Name: matrix_v2_seed_required_defaults_before_b4f170("uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."matrix_v2_seed_required_defaults_before_b4f170"("p_matrix_version_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  perform solver_private.matrix_v2_seed_required_defaults_before_b4f169(
    p_matrix_version_id
  );
  perform solver_private.apply_strategy_semantics_b4f169(p_matrix_version_id);
end;
$$;


ALTER FUNCTION "solver_private"."matrix_v2_seed_required_defaults_before_b4f170"("p_matrix_version_id" "uuid") OWNER TO "postgres";

--
-- Name: matrix_v2_seed_required_defaults_uat_v1("uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."matrix_v2_seed_required_defaults_uat_v1"("p_matrix_version_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  perform solver_private.matrix_v2_seed_required_defaults_before_b4f170(
    p_matrix_version_id
  );
  perform solver_private.apply_strategy_semantics_b4f170(p_matrix_version_id);
end;
$$;


ALTER FUNCTION "solver_private"."matrix_v2_seed_required_defaults_uat_v1"("p_matrix_version_id" "uuid") OWNER TO "postgres";

--
-- Name: matrix_v2_team_configuration_uat_v1("jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."matrix_v2_team_configuration_uat_v1"("p_configuration" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "solver_private"."matrix_v2_team_configuration_uat_v1"("p_configuration" "jsonb") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_team_configuration_uat_v1"("p_configuration" "jsonb"); Type: COMMENT; Schema: solver_private; Owner: postgres
--

COMMENT ON FUNCTION "solver_private"."matrix_v2_team_configuration_uat_v1"("p_configuration" "jsonb") IS 'Quick-start UAT payload: retain detailed employee relations only when their GP number exists in the submitted employee list; consolidated blank-number rows are resolved by e-mail.';


--
-- Name: matrix_v2_team_import_configuration_uat_v2("jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."matrix_v2_team_import_configuration_uat_v2"("p_configuration" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "solver_private"."matrix_v2_team_import_configuration_uat_v2"("p_configuration" "jsonb") OWNER TO "postgres";

--
-- Name: mx_k10_legacy_role_duty_payload_v1("jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."mx_k10_legacy_role_duty_payload_v1"("p_row" "jsonb") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $_$
  select
    upper(coalesce(nullif(trim(p_row->>'assignmentMode'),''),'OPTIONAL'))
      not in ('OPTIONAL','EXTRA')
    or coalesce(nullif(trim(p_row->>'minimumCount'),''),'0') !~ '^\d+$'
    or case
      when coalesce(nullif(trim(p_row->>'minimumCount'),''),'0') ~ '^\d+$'
      then coalesce(nullif(trim(p_row->>'minimumCount'),''),'0')::integer
      else 1
    end<>0
    or lower(coalesce(p_row->>'shiftObligation','false')) in ('true','t','1','yes')
    or nullif(trim(p_row->>'shiftPeriod'),'') is not null;
$_$;


ALTER FUNCTION "solver_private"."mx_k10_legacy_role_duty_payload_v1"("p_row" "jsonb") OWNER TO "postgres";

--
-- Name: normalize_contract_type_v2("text"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."normalize_contract_type_v2"("p_value" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "solver_private"."normalize_contract_type_v2"("p_value" "text") OWNER TO "postgres";

--
-- Name: normalize_initial_matrix_month_uat_v1(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."normalize_initial_matrix_month_uat_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if new.version=1
    and new.status='DRAFT'
    and new.name='Pierwsza konfiguracja firmy'
    and not exists(select 1 from public.matrix_versions)
  then
    new.effective_from:=date_trunc('month',new.effective_from)::date;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."normalize_initial_matrix_month_uat_v1"() OWNER TO "postgres";

--
-- Name: FUNCTION "normalize_initial_matrix_month_uat_v1"(); Type: COMMENT; Schema: solver_private; Owner: postgres
--

COMMENT ON FUNCTION "solver_private"."normalize_initial_matrix_month_uat_v1"() IS 'UAT first-run guard: normalizes the initial reset draft to the first day of its planning month so monthly optimizer lookup and Settings use the same configuration.';


--
-- Name: normalize_personal_notification_v1(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."normalize_personal_notification_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if new.title like 'Zmieniono Twój grafik%' then
    new.kind:='SCHEDULE_PUBLISHED';
    new.action_route:=coalesce(nullif(new.action_route,''),'/my-schedule');
  elsif new.title='Propozycja zamiany zmiany' then
    if tg_op='INSERT' and new.context_id is null and exists(
      select 1 from public.notifications existing
      where existing.recipient_id=new.recipient_id
        and existing.title=new.title
        and existing.context_type='SHIFT_SWAP'
        and existing.created_at>=transaction_timestamp()
    ) then return null; end if;
    new.kind:='ACTION_REQUIRED';
    new.action_required:=true;
    new.action_route:=coalesce(nullif(new.action_route,''),'/swaps');
  elsif new.title='Zamiana czeka na akceptację' then
    if tg_op='INSERT' and new.context_id is null and exists(
      select 1 from public.notifications existing
      where existing.recipient_id=new.recipient_id
        and existing.title=new.title
        and existing.context_type='SHIFT_SWAP'
        and existing.created_at>=transaction_timestamp()
    ) then return null; end if;
    new.kind:='ACTION_REQUIRED';
    new.action_required:=true;
    new.action_route:=coalesce(nullif(new.action_route,''),'/swaps');
  elsif new.title='Decyzja lidera o zamianie' then
    new.kind:='DECISION';
    new.action_route:=coalesce(nullif(new.action_route,''),'/swaps');
  elsif new.title like 'Nowe wydarzenie:%' then
    new.kind:='INFORMATION';
    new.action_route:=coalesce(nullif(new.action_route,''),'/my-schedule');
  end if;
  new.sent_at:=coalesce(new.sent_at,now());
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."normalize_personal_notification_v1"() OWNER TO "postgres";

--
-- Name: optimizer_publish_company_variant_pre_version_fence_v2("uuid", "uuid", "text", "text"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."optimizer_publish_company_variant_pre_version_fence_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_actor uuid := auth.uid();
  v_run public.optimization_runs_v2%rowtype;
  v_variant public.plan_variants_v2%rowtype;
  v_existing public.published_schedules_v2%rowtype;
  v_schedule_id uuid := gen_random_uuid();
  v_month date;
  v_validation jsonb;
  v_publication_hash text;
  v_base_units bigint;
  v_total_units bigint;
  v_currency text;
  v_engine text;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select flag.engine into v_engine
  from public.solver_feature_flags flag
  where flag.flag_key='DEFAULT_ENGINE' and flag.enabled;
  if v_engine is null then raise exception 'SOLVER_ENGINE_CONFIGURATION_MISSING'; end if;
  if v_engine<>'ORTOOLS_V2' then raise exception 'ORTOOLS_PUBLICATION_DISABLED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'COMPANY_PUBLICATION_FORBIDDEN';
  end if;
  if length(coalesce(p_idempotency_key,'')) not between 8 and 200 then
    raise exception 'INVALID_IDEMPOTENCY_KEY';
  end if;
  if length(trim(coalesce(p_name,''))) not between 1 and 200 then
    raise exception 'INVALID_PLAN_NAME';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'publish-v2-key:'||v_actor::text||':'||p_idempotency_key,0
  ));
  select * into v_existing
  from public.published_schedules_v2 s
  where s.created_by=v_actor and s.idempotency_key=p_idempotency_key;
  if v_existing.id is not null then
    if v_existing.source_type<>'COMPANY'
      or v_existing.name<>trim(p_name)
      or not exists(
      select 1
      from public.published_schedule_variants_v2 sv
      join public.plan_variants_v2 v on v.id=sv.variant_id
      where sv.schedule_id=v_existing.id and sv.variant_id=p_variant_id
        and v.run_id=p_run_id
    ) then raise exception 'IDEMPOTENCY_KEY_REUSED'; end if;
    return jsonb_build_object(
      'scheduleId',v_existing.id,'status',v_existing.status,
      'sourceType',v_existing.source_type,'reused',true
    );
  end if;

  select r.month into v_month
  from public.optimization_runs_v2 r
  where r.id=p_run_id;
  if v_month is null then raise exception 'RUN_NOT_FOUND'; end if;

  -- Every code path that combines the planning-revision lock with run or
  -- variant locks uses this order. This prevents a concurrent selection,
  -- worker validation and publication from forming an advisory-lock cycle.
  perform solver_private.lock_planning_revision_v2();
  perform pg_advisory_xact_lock(hashtextextended(
    'publish-v2-month:'||v_month::text,0
  ));
  perform pg_advisory_xact_lock(hashtextextended(
    'select-v2:'||p_run_id::text,0
  ));

  select * into v_run
  from public.optimization_runs_v2 r
  where r.id=p_run_id
  for update;
  if v_run.id is null then raise exception 'RUN_NOT_FOUND'; end if;
  if v_run.month<>v_month then raise exception 'RUN_MONTH_CHANGED'; end if;
  if v_run.request_engine<>'ORTOOLS_V2' then
    raise exception 'SHADOW_RUN_NOT_PUBLISHABLE';
  end if;
  if v_run.status<>'READY' or v_run.scope_type<>'COMPANY' then
    raise exception 'COMPANY_RUN_NOT_READY';
  end if;
  select * into v_variant
  from public.plan_variants_v2 v
  where v.id=p_variant_id and v.run_id=v_run.id
  for update;
  if v_variant.id is null or not v_variant.selected
    or v_variant.hard_violations<>0
    or v_variant.status not in ('SELECTED','PUBLISHED') then
    raise exception 'SELECTED_COMPANY_VARIANT_REQUIRED';
  end if;

  v_validation := solver_private.revalidate_materialized_variant_v2(v_variant.id,false);
  v_currency := upper(nullif(v_validation->>'currency',''));
  if v_currency is null or v_currency !~ '^[A-Z]{3}$' then
    raise exception 'SNAPSHOT_CURRENCY_REQUIRED';
  end if;
  v_publication_hash := encode(extensions.digest(convert_to(
    solver_private.canonical_json_v2(jsonb_build_object(
      'sourceType','COMPANY','month',v_run.month,
      'matrixVersionId',v_run.matrix_version_id,
      'scenarioId',v_run.scenario_id,
      'variantId',v_variant.id,'solutionHash',v_variant.solution_hash
    )),'UTF8'
  ),'sha256'),'hex');

  perform solver_private.archive_current_publication_v2(
    v_run.month,array[v_variant.id],v_actor
  );
  insert into public.published_schedules_v2(
    id,idempotency_key,month,matrix_version_id,scenario_id,source_type,
    name,status,publication_hash,validation_snapshot_hash,
    validation_summary,created_by
  ) values(
    v_schedule_id,p_idempotency_key,v_run.month,v_run.matrix_version_id,
    v_run.scenario_id,'COMPANY',trim(p_name),'PUBLISHED',v_publication_hash,
    v_validation->>'validationSnapshotHash',
    v_validation-'totalCostUnits'-'budgetMinor'-'validationSnapshotHash'-'variantId',
    v_actor
  );
  insert into public.published_schedule_variants_v2(
    schedule_id,variant_id,role_id,ordinal
  ) values(v_schedule_id,v_variant.id,null,1);
  select coalesce(sum((c.calculation_basis->>'costUnits')::bigint),0)
  into v_base_units
  from public.plan_assignments_v2 a
  join solver_private.plan_assignment_cost_components_v2 c
    on c.assignment_id=a.id and c.pay_rule_id is null
  where a.variant_id=v_variant.id;
  v_total_units := (v_validation->>'totalCostUnits')::bigint;
  insert into solver_private.published_schedule_finance_v2(
    schedule_id,base_cost_units,additions_cost_units,total_cost_units,
    base_cost_minor,additions_cost_minor,total_cost_minor,currency,
    budget_minor,hard_budget
  ) values(
    v_schedule_id,v_base_units,greatest(v_total_units-v_base_units,0),v_total_units,
    round(v_base_units::numeric/60)::bigint,
    round(v_total_units::numeric/60)::bigint
      -round(v_base_units::numeric/60)::bigint,
    round(v_total_units::numeric/60)::bigint,
    v_currency,
    nullif(v_validation->>'budgetMinor','')::bigint,
    coalesce((v_validation->>'hardBudget')::boolean,false)
  );
  update public.plan_variants_v2
  set status='PUBLISHED',published_at=now()
  where id=v_variant.id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'published_schedule_v2',v_schedule_id::text,
    'PUBLISH_COMPANY',jsonb_build_object(
      'month',v_run.month,'scenarioId',v_run.scenario_id,
      'matrixVersionId',v_run.matrix_version_id,'variantId',v_variant.id,
      'publicationHash',v_publication_hash
    ));
  return jsonb_build_object(
    'scheduleId',v_schedule_id,'status','PUBLISHED',
    'sourceType','COMPANY','reused',false
  );
end;
$_$;


ALTER FUNCTION "solver_private"."optimizer_publish_company_variant_pre_version_fence_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_publish_company_variant_pre_version_fence_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text"); Type: COMMENT; Schema: solver_private; Owner: postgres
--

COMMENT ON FUNCTION "solver_private"."optimizer_publish_company_variant_pre_version_fence_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text") IS 'OWNER/ADMIN-only, idempotent publication of a selected COMPANY variant after fresh database validation.';


--
-- Name: optimizer_publish_role_composite_pre_version_fence_v2("date", "uuid", "uuid"[], "text", "text"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."optimizer_publish_role_composite_pre_version_fence_v2"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[], "p_name" "text", "p_idempotency_key" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_actor uuid := auth.uid();
  v_month date := date_trunc('month',p_month)::date;
  v_variant_ids uuid[];
  v_existing public.published_schedules_v2%rowtype;
  v_existing_ids uuid[];
  v_schedule_id uuid := gen_random_uuid();
  v_matrix_ids uuid[];
  v_scenario_ids uuid[];
  v_months date[];
  v_count integer;
  v_role_count integer;
  v_matrix_version_id uuid;
  v_validation_run_id uuid;
  v_strategy_id uuid;
  v_company_snapshot jsonb;
  v_combined_payload jsonb;
  v_combined_validation jsonb;
  v_validation jsonb;
  v_publication_hash text;
  v_variant_id uuid;
  v_base_units bigint;
  v_total_units bigint;
  v_currency text;
  v_engine text;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select flag.engine into v_engine
  from public.solver_feature_flags flag
  where flag.flag_key='DEFAULT_ENGINE' and flag.enabled;
  if v_engine is null then raise exception 'SOLVER_ENGINE_CONFIGURATION_MISSING'; end if;
  if v_engine<>'ORTOOLS_V2' then raise exception 'ORTOOLS_PUBLICATION_DISABLED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'COMPOSITE_PUBLICATION_FORBIDDEN';
  end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  if p_scenario_id is null then raise exception 'SCENARIO_REQUIRED'; end if;
  if length(coalesce(p_idempotency_key,'')) not between 8 and 200 then
    raise exception 'INVALID_IDEMPOTENCY_KEY';
  end if;
  if length(trim(coalesce(p_name,''))) not between 1 and 200 then
    raise exception 'INVALID_PLAN_NAME';
  end if;
  if coalesce(cardinality(p_variant_ids),0)=0
    or cardinality(p_variant_ids)>200 then
    raise exception 'INVALID_VARIANT_SET';
  end if;
  select array_agg(x.variant_id order by x.variant_id::text)
  into v_variant_ids
  from (select distinct unnest(p_variant_ids) variant_id) x;
  if cardinality(v_variant_ids)<>cardinality(p_variant_ids)
    or array_position(v_variant_ids,null) is not null then
    raise exception 'DUPLICATE_OR_NULL_VARIANT';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'publish-v2-key:'||v_actor::text||':'||p_idempotency_key,0
  ));
  select * into v_existing
  from public.published_schedules_v2 s
  where s.created_by=v_actor and s.idempotency_key=p_idempotency_key;
  if v_existing.id is not null then
    select array_agg(sv.variant_id order by sv.variant_id::text)
    into v_existing_ids
    from public.published_schedule_variants_v2 sv
    where sv.schedule_id=v_existing.id;
    if v_existing.source_type<>'ROLE_COMPOSITE'
      or v_existing.month<>v_month
      or v_existing.scenario_id<>p_scenario_id
      or v_existing.name<>trim(p_name)
      or v_existing_ids is distinct from v_variant_ids then
      raise exception 'IDEMPOTENCY_KEY_REUSED';
    end if;
    return jsonb_build_object(
      'scheduleId',v_existing.id,'status',v_existing.status,
      'sourceType',v_existing.source_type,'reused',true
    );
  end if;

  perform solver_private.lock_planning_revision_v2();
  perform pg_advisory_xact_lock(hashtextextended(
    'publish-v2-month:'||v_month::text,0
  ));
  for v_validation_run_id in
    select distinct v.run_id
    from public.plan_variants_v2 v
    where v.id=any(v_variant_ids)
    order by v.run_id
  loop
    perform pg_advisory_xact_lock(hashtextextended(
      'select-v2:'||v_validation_run_id::text,0
    ));
  end loop;

  perform 1
  from public.plan_variants_v2 v
  join public.optimization_runs_v2 r on r.id=v.run_id
  where v.id=any(v_variant_ids)
  order by v.id::text
  for update of v,r;

  if exists(
    select 1
    from public.plan_variants_v2 v
    join public.optimization_runs_v2 r on r.id=v.run_id
    where v.id=any(v_variant_ids)
      and r.request_engine<>'ORTOOLS_V2'
  ) then raise exception 'SHADOW_RUN_NOT_PUBLISHABLE'; end if;

  select count(*),count(distinct r.scope_role_id),
    array_agg(distinct r.matrix_version_id),
    array_agg(distinct r.scenario_id),
    array_agg(distinct r.month)
  into v_count,v_role_count,v_matrix_ids,v_scenario_ids,v_months
  from public.plan_variants_v2 v
  join public.optimization_runs_v2 r on r.id=v.run_id
  where v.id=any(v_variant_ids)
    and v.selected and v.hard_violations=0
    and v.status in ('SELECTED','PUBLISHED')
    and r.status='READY' and r.scope_type='ROLE';
  if v_count<>cardinality(v_variant_ids)
    or v_role_count<>cardinality(v_variant_ids) then
    raise exception 'ONE_SELECTED_ROLE_VARIANT_PER_ROLE_REQUIRED';
  end if;
  if cardinality(v_matrix_ids)<>1 or cardinality(v_scenario_ids)<>1
    or cardinality(v_months)<>1
    or v_months[1]<>v_month or v_scenario_ids[1]<>p_scenario_id then
    raise exception 'ROLE_VARIANTS_SCOPE_MISMATCH';
  end if;
  v_matrix_version_id := v_matrix_ids[1];
  select v.run_id into v_validation_run_id
  from public.plan_variants_v2 v
  where v.id=any(v_variant_ids)
  order by v.run_id::text limit 1;

  foreach v_variant_id in array v_variant_ids loop
    v_validation := solver_private.revalidate_materialized_variant_v2(
      v_variant_id,true,false
    );
  end loop;

  v_company_snapshot := solver_private.build_snapshot_payload_v2(
    v_validation_run_id,v_month,v_matrix_version_id,p_scenario_id,'COMPANY',null
  );
  v_company_snapshot := jsonb_set(
    v_company_snapshot,'{baselineAssignments}','[]'::jsonb,true
  );
  v_currency := upper(nullif(v_company_snapshot->>'currency',''));
  if v_currency is null or v_currency !~ '^[A-Z]{3}$' then
    raise exception 'SNAPSHOT_CURRENCY_REQUIRED';
  end if;

  -- A category run is still stored with one stable anchor role in
  -- optimization_runs_v2.scope_role_id. Its immutable snapshot is the
  -- authoritative record of every role covered by that variant.
  if exists(
    select slot.value->>'roleId'
    from jsonb_array_elements(coalesce(v_company_snapshot->'slots','[]'::jsonb)) slot
    group by slot.value->>'roleId'
    except
    select covered_role.role_id
    from public.plan_variants_v2 variant
    join public.optimization_runs_v2 run on run.id=variant.run_id
    join solver_private.optimization_snapshots_v2 run_snapshot on run_snapshot.run_id=run.id
    cross join lateral jsonb_array_elements_text(
      case
        when jsonb_typeof(run_snapshot.snapshot->'scope'->'roleIds')='array'
          and jsonb_array_length(run_snapshot.snapshot->'scope'->'roleIds')>0
          then run_snapshot.snapshot->'scope'->'roleIds'
        else jsonb_build_array(run.scope_role_id::text)
      end
    ) covered_role(role_id)
    where variant.id=any(v_variant_ids)
    group by covered_role.role_id
  ) then raise exception 'ALL_DEMANDED_ROLES_REQUIRED'; end if;

  -- Category scopes may not overlap: otherwise the same role could be
  -- materialized twice in the company schedule.
  if (
    select count(*)<>count(distinct covered_role.role_id)
    from public.plan_variants_v2 variant
    join public.optimization_runs_v2 run on run.id=variant.run_id
    join solver_private.optimization_snapshots_v2 run_snapshot on run_snapshot.run_id=run.id
    cross join lateral jsonb_array_elements_text(
      case
        when jsonb_typeof(run_snapshot.snapshot->'scope'->'roleIds')='array'
          and jsonb_array_length(run_snapshot.snapshot->'scope'->'roleIds')>0
          then run_snapshot.snapshot->'scope'->'roleIds'
        else jsonb_build_array(run.scope_role_id::text)
      end
    ) covered_role(role_id)
    where variant.id=any(v_variant_ids)
  ) then raise exception 'OVERLAPPING_CATEGORY_VARIANTS'; end if;

  v_strategy_id := nullif(v_company_snapshot->'strategies'->0->>'id','')::uuid;
  if v_strategy_id is null then raise exception 'SCENARIO_HAS_NO_STRATEGIES'; end if;
  v_publication_hash := encode(extensions.digest(convert_to(
    solver_private.canonical_json_v2(jsonb_build_object(
      'sourceType','ROLE_COMPOSITE','month',v_month,
      'matrixVersionId',v_matrix_version_id,'scenarioId',p_scenario_id,
      'variants',(
        select jsonb_agg(jsonb_build_object(
          'variantId',v.id,'solutionHash',v.solution_hash,
          'roleId',r.scope_role_id,
          'roleIds',coalesce(
            run_snapshot.snapshot->'scope'->'roleIds',
            jsonb_build_array(r.scope_role_id::text)
          )
        ) order by r.scope_role_id::text,v.id::text)
        from public.plan_variants_v2 v
        join public.optimization_runs_v2 r on r.id=v.run_id
        join solver_private.optimization_snapshots_v2 run_snapshot on run_snapshot.run_id=r.id
        where v.id=any(v_variant_ids)
      )
    )),'UTF8'
  ),'sha256'),'hex');
  v_combined_payload := solver_private.materialized_variant_payload_v2(
    v_variant_ids,v_company_snapshot,v_strategy_id
  );
  v_combined_payload := solver_private.requote_variant_payload_v2(
    v_company_snapshot,v_combined_payload
  );
  v_combined_validation := solver_private.validate_variant_v2(
    v_company_snapshot,v_combined_payload
  );

  perform solver_private.archive_current_publication_v2(
    v_month,v_variant_ids,v_actor
  );
  insert into public.published_schedules_v2(
    id,idempotency_key,month,matrix_version_id,scenario_id,source_type,
    name,status,publication_hash,validation_snapshot_hash,
    validation_summary,created_by
  ) values(
    v_schedule_id,p_idempotency_key,v_month,v_matrix_version_id,p_scenario_id,
    'ROLE_COMPOSITE',trim(p_name),'PUBLISHED',v_publication_hash,
    solver_private.publication_snapshot_hash_v2(v_company_snapshot),
    v_combined_validation-'totalCostUnits'-'budgetMinor',v_actor
  );
  insert into public.published_schedule_variants_v2(
    schedule_id,variant_id,role_id,ordinal
  )
  select v_schedule_id,v.id,r.scope_role_id,
    (row_number() over(order by role.sort_order,role.name,r.scope_role_id::text))::integer
  from public.plan_variants_v2 v
  join public.optimization_runs_v2 r on r.id=v.run_id
  join public.matrix_roles_v2 role on role.id=r.scope_role_id
  where v.id=any(v_variant_ids)
  order by role.sort_order,role.name,r.scope_role_id::text;
  select
    coalesce((
      select sum((component.value->>'costUnits')::bigint)
      from jsonb_array_elements(
        coalesce(v_combined_payload->'assignments','[]'::jsonb)
      ) assignment
      cross join lateral jsonb_array_elements(
        coalesce(assignment.value->'costComponents','[]'::jsonb)
      ) component
      where component.value->>'ruleId'='BASE'
    ),0),
    coalesce((
      select sum((assignment.value->>'costUnits')::bigint)
      from jsonb_array_elements(
        coalesce(v_combined_payload->'assignments','[]'::jsonb)
      ) assignment
    ),0)
  into v_base_units,v_total_units;
  insert into solver_private.published_schedule_finance_v2(
    schedule_id,base_cost_units,additions_cost_units,total_cost_units,
    base_cost_minor,additions_cost_minor,total_cost_minor,currency,
    budget_minor,hard_budget
  ) values(
    v_schedule_id,v_base_units,greatest(v_total_units-v_base_units,0),v_total_units,
    round(v_base_units::numeric/60)::bigint,
    round(v_total_units::numeric/60)::bigint
      -round(v_base_units::numeric/60)::bigint,
    round(v_total_units::numeric/60)::bigint,
    v_currency,
    nullif(v_combined_validation->>'budgetMinor','')::bigint,
    coalesce((v_combined_validation->>'hardBudget')::boolean,false)
  );
  update public.plan_variants_v2
  set status='PUBLISHED',published_at=now()
  where id=any(v_variant_ids);
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'published_schedule_v2',v_schedule_id::text,
    'PUBLISH_ROLE_COMPOSITE',jsonb_build_object(
      'month',v_month,'scenarioId',p_scenario_id,
      'matrixVersionId',v_matrix_version_id,
      'variantIds',to_jsonb(v_variant_ids),
      'publicationHash',v_publication_hash,
      'categoryAware',true
    ));
  return jsonb_build_object(
    'scheduleId',v_schedule_id,'status','PUBLISHED',
    'sourceType','ROLE_COMPOSITE','variantCount',cardinality(v_variant_ids),
    'categoryAware',true,'reused',false
  );
end;
$_$;


ALTER FUNCTION "solver_private"."optimizer_publish_role_composite_pre_version_fence_v2"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[], "p_name" "text", "p_idempotency_key" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_publish_role_composite_pre_version_fence_v2"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[], "p_name" "text", "p_idempotency_key" "text"); Type: COMMENT; Schema: solver_private; Owner: postgres
--

COMMENT ON FUNCTION "solver_private"."optimizer_publish_role_composite_pre_version_fence_v2"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[], "p_name" "text", "p_idempotency_key" "text") IS 'Publishes one validated variant per disjoint role or category scope and proves that their immutable roleIds cover every demanded company role.';


--
-- Name: optimizer_request_stamped_uat_v1("date", "uuid", "text", "uuid", "text", "text", "text", "text"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."optimizer_request_stamped_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_frontend_version" "text", "p_execution_mode" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_result jsonb;
  v_run_id uuid;
  v_run public.optimization_runs_v2%rowtype;
  v_stamp jsonb;
  v_user_id uuid:=auth.uid();
  v_quota integer;
begin
  if v_user_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_execution_mode not in ('SERVICE','JOB') then
    raise exception 'EXECUTION_MODE_INVALID';
  end if;

  select c.generation_quota_per_user_hour into v_quota
  from solver_private.solver_job_runtime_config_uat_v1 c where c.singleton;
  if not exists(
      select 1 from public.optimization_runs_v2 r
      where r.requested_by=v_user_id and r.idempotency_key=p_idempotency_key
    ) and (
      select count(*) from public.optimization_runs_v2 r
      where r.requested_by=v_user_id
        and r.created_at>=now()-interval '1 hour'
    )>=v_quota
  then raise exception 'GENERATION_QUOTA_HARD_STOP'; end if;

  v_result:=public.optimizer_request_before_nfjob_uat_v1(
    p_month,p_scenario_id,p_scope_type,p_scope_role_id,p_name,
    p_idempotency_key,p_frontend_version
  );
  v_run_id:=nullif(v_result#>>'{run,id}','')::uuid;
  if v_run_id is null then raise exception 'RUN_ID_MISSING'; end if;

  select * into v_run from public.optimization_runs_v2 where id=v_run_id;
  perform pg_advisory_xact_lock(hashtextextended(
    v_run.matrix_version_id::text||'|'||v_run.month::text||'|'||
    v_run.scope_type||'|'||coalesce(v_run.scope_role_id::text,'COMPANY'),0
  ));
  if exists(
    select 1 from public.optimization_runs_v2 other
    where other.id<>v_run.id
      and other.matrix_version_id=v_run.matrix_version_id
      and other.month=v_run.month
      and other.scope_type=v_run.scope_type
      and other.scope_role_id is not distinct from v_run.scope_role_id
      and other.status in ('QUEUED','RUNNING','VALIDATING','CANCEL_REQUESTED')
  ) then raise exception 'SCHEDULE_GENERATION_ACTIVE'; end if;

  v_stamp:=solver_private.build_run_version_stamp_uat_v1(
    v_run_id,p_frontend_version,p_execution_mode
  );
  update public.optimization_runs_v2
  set version_stamp=v_stamp,updated_at=now()
  where id=v_run_id;
  return jsonb_set(v_result,'{versionStamp}',v_stamp,true);
end;
$$;


ALTER FUNCTION "solver_private"."optimizer_request_stamped_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_frontend_version" "text", "p_execution_mode" "text") OWNER TO "postgres";

--
-- Name: optimizer_select_variant_pre_version_fence_v2("uuid", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."optimizer_select_variant_pre_version_fence_v2"("p_run_id" "uuid", "p_variant_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_variant public.plan_variants_v2%rowtype;
  v_engine text;
begin
  select flag.engine into v_engine
  from public.solver_feature_flags flag
  where flag.flag_key='DEFAULT_ENGINE' and flag.enabled;
  if v_engine is null then raise exception 'SOLVER_ENGINE_CONFIGURATION_MISSING'; end if;
  if v_engine<>'ORTOOLS_V2' then raise exception 'ORTOOLS_SELECTION_DISABLED'; end if;
  if not solver_private.can_access_run_v2(p_run_id) then
    raise exception 'RUN_NOT_FOUND';
  end if;
  perform solver_private.lock_planning_revision_v2();
  perform pg_advisory_xact_lock(hashtextextended('select-v2:'||p_run_id::text,0));
  if not exists(
    select 1 from public.optimization_runs_v2 r
    where r.id=p_run_id and r.status='READY'
      and r.request_engine='ORTOOLS_V2'
  ) then raise exception 'RUN_NOT_READY'; end if;
  select * into v_variant
  from public.plan_variants_v2 v
  where v.id=p_variant_id and v.run_id=p_run_id and v.hard_violations=0
  for update;
  if v_variant.id is null then raise exception 'VARIANT_NOT_SELECTABLE'; end if;

  update public.plan_variants_v2 v
  set selected=false,
    status=case when exists(
      select 1
      from public.published_schedule_variants_v2 sv
      join public.published_schedules_v2 s
        on s.id=sv.schedule_id and s.status='PUBLISHED'
      where sv.variant_id=v.id
    ) then 'PUBLISHED'
    when v.status in ('SELECTED','PUBLISHED') then 'READY'
    else v.status end,
    selected_at=null,selected_by=null
  where v.run_id=p_run_id and v.selected;

  update public.plan_variants_v2 v
  set selected=true,
    status=case when exists(
      select 1
      from public.published_schedule_variants_v2 sv
      join public.published_schedules_v2 s
        on s.id=sv.schedule_id and s.status='PUBLISHED'
      where sv.variant_id=v.id
    ) then 'PUBLISHED' else 'SELECTED' end,
    selected_at=now(),selected_by=auth.uid()
  where v.id=p_variant_id;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'optimization_run_v2',p_run_id::text,'SELECT_VARIANT',
    jsonb_build_object('variantId',p_variant_id));
  return jsonb_build_object(
    'runId',p_run_id,'variantId',p_variant_id,'selected',true,'planId',null
  );
end;
$$;


ALTER FUNCTION "solver_private"."optimizer_select_variant_pre_version_fence_v2"("p_run_id" "uuid", "p_variant_id" "uuid") OWNER TO "postgres";

--
-- Name: pay_condition_matches_v2("jsonb", "jsonb", "jsonb", "jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."pay_condition_matches_v2"("p_condition" "jsonb", "p_snapshot" "jsonb", "p_employee" "jsonb", "p_slot" "jsonb") RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_field text := lower(coalesce(p_condition->>'field',''));
  v_operator text := upper(coalesce(p_condition->>'operator',''));
  v_expected jsonb := p_condition->'value';
  v_actual jsonb;
  v_timezone text := solver_private.slot_timezone_v2(p_snapshot,p_slot);
  v_rule_start integer;
  v_rule_end integer;
  v_slot_start integer;
  v_slot_end integer;
begin
  v_actual := case v_field
    when 'role_id' then to_jsonb(p_slot->>'roleId')
    when 'duty_ids' then coalesce(p_slot->'dutyIds','[]'::jsonb)
    when 'location_id' then to_jsonb(p_slot->>'locationId')
    when 'shift_template_id' then to_jsonb(p_slot->>'shiftTemplateId')
    when 'weekday' then to_jsonb(extract(isodow from (p_slot->>'date')::date)::integer)
    when 'scenario_id' then to_jsonb(p_snapshot->>'scenarioId')
    when 'employee_id' then to_jsonb(p_employee->>'id')
    when 'contract_code' then to_jsonb(p_employee->>'contractCode')
    when 'duration_minutes' then to_jsonb((p_slot->>'durationMinutes')::integer)
    when 'local_time' then to_jsonb(p_slot->>'start')
    else null
  end;
  if v_field not in (
    'role_id','duty_ids','location_id','shift_template_id','weekday',
    'scenario_id','employee_id','contract_code','duration_minutes','local_time'
  ) then raise exception 'UNSUPPORTED_PAY_CONDITION_FIELD:%',v_field; end if;

  if v_operator='OVERLAPS_TIME' then
    if v_field<>'local_time' or jsonb_typeof(v_expected)<>'object'
      or nullif(v_expected->>'start','') is null
      or nullif(v_expected->>'end','') is null then
      raise exception 'PAY_TIME_CONDITION_INVALID';
    end if;
    v_rule_start := extract(hour from (v_expected->>'start')::time)::integer*60
      +extract(minute from (v_expected->>'start')::time)::integer;
    v_rule_end := extract(hour from (v_expected->>'end')::time)::integer*60
      +extract(minute from (v_expected->>'end')::time)::integer;
    if v_rule_end<=v_rule_start then v_rule_end:=v_rule_end+1440; end if;
    v_slot_start := extract(hour from ((p_slot->>'start')::timestamptz at time zone v_timezone))::integer*60
      +extract(minute from ((p_slot->>'start')::timestamptz at time zone v_timezone))::integer;
    v_slot_end := extract(hour from ((p_slot->>'end')::timestamptz at time zone v_timezone))::integer*60
      +extract(minute from ((p_slot->>'end')::timestamptz at time zone v_timezone))::integer;
    if (((p_slot->>'end')::timestamptz at time zone v_timezone)::date
        >((p_slot->>'start')::timestamptz at time zone v_timezone)::date)
      or v_slot_end<=v_slot_start then v_slot_end:=v_slot_end+1440; end if;
    return (v_slot_start<v_rule_end-1440 and v_rule_start-1440<v_slot_end)
      or (v_slot_start<v_rule_end and v_rule_start<v_slot_end)
      or (v_slot_start<v_rule_end+1440 and v_rule_start+1440<v_slot_end);
  elsif v_operator='EQ' then
    return v_actual=v_expected;
  elsif v_operator='NE' then
    return v_actual<>v_expected;
  elsif v_operator in ('IN','NOT_IN') then
    if jsonb_typeof(v_expected)<>'array' then raise exception 'PAY_CONDITION_ARRAY_REQUIRED'; end if;
    return case when v_operator='IN' then exists(
      select 1 from jsonb_array_elements(v_expected) x where x.value=v_actual
    ) else not exists(
      select 1 from jsonb_array_elements(v_expected) x where x.value=v_actual
    ) end;
  elsif v_operator='CONTAINS' then
    if jsonb_typeof(v_actual)<>'array' then raise exception 'PAY_CONDITION_FACT_ARRAY_REQUIRED'; end if;
    return exists(select 1 from jsonb_array_elements(v_actual) x where x.value=v_expected);
  elsif v_operator in ('CONTAINS_ANY','CONTAINS_ALL') then
    if jsonb_typeof(v_actual)<>'array' or jsonb_typeof(v_expected)<>'array' then
      raise exception 'PAY_CONDITION_ARRAY_REQUIRED';
    end if;
    return case when v_operator='CONTAINS_ANY' then exists(
      select 1 from jsonb_array_elements(v_expected) e
      join jsonb_array_elements(v_actual) a on a.value=e.value
    ) else not exists(
      select 1 from jsonb_array_elements(v_expected) e
      where not exists(select 1 from jsonb_array_elements(v_actual) a where a.value=e.value)
    ) end;
  elsif v_operator='GTE' then
    return (v_actual#>>'{}')::numeric >= (v_expected#>>'{}')::numeric;
  elsif v_operator='LTE' then
    return (v_actual#>>'{}')::numeric <= (v_expected#>>'{}')::numeric;
  end if;
  raise exception 'UNSUPPORTED_PAY_CONDITION_OPERATOR:%',v_operator;
end;
$$;


ALTER FUNCTION "solver_private"."pay_condition_matches_v2"("p_condition" "jsonb", "p_snapshot" "jsonb", "p_employee" "jsonb", "p_slot" "jsonb") OWNER TO "postgres";

--
-- Name: pay_rule_billable_minutes_v2("jsonb", "jsonb", "jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."pay_rule_billable_minutes_v2"("p_snapshot" "jsonb", "p_rule" "jsonb", "p_slot" "jsonb") RETURNS bigint
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_condition jsonb;
  v_window jsonb;
  v_window_count integer:=0;
  v_start time;
  v_end time;
  v_timezone text:=solver_private.slot_timezone_v2(p_snapshot,p_slot);
  v_slot_start timestamptz:=(p_slot->>'start')::timestamptz;
  v_slot_end timestamptz:=(p_slot->>'end')::timestamptz;
  v_minutes bigint;
begin
  for v_condition in
    select value
    from jsonb_array_elements(coalesce(p_rule->'conditions','[]'::jsonb))
  loop
    if lower(coalesce(v_condition->>'field',''))='local_time'
      and upper(coalesce(v_condition->>'operator',''))='OVERLAPS_TIME' then
      v_window_count:=v_window_count+1;
      v_window:=v_condition->'value';
    end if;
  end loop;
  if nullif(p_rule->>'localStart','') is not null then
    v_window_count:=v_window_count+1;
    v_window:=jsonb_build_object(
      'start',p_rule->>'localStart','end',p_rule->>'localEnd'
    );
  end if;
  if v_window_count=0 then return (p_slot->>'durationMinutes')::bigint; end if;
  if v_window_count<>1 or jsonb_typeof(v_window)<>'object'
    or nullif(v_window->>'start','') is null
    or nullif(v_window->>'end','') is null then
    raise exception 'PAY_RULE_TIME_WINDOW_AMBIGUOUS';
  end if;
  v_start:=(v_window->>'start')::time;
  v_end:=(v_window->>'end')::time;

  select coalesce(sum(floor(extract(epoch from
    least(v_slot_end,window_end)-greatest(v_slot_start,window_start)
  )/60)) filter(where window_end>v_slot_start and window_start<v_slot_end),0)::bigint
  into v_minutes
  from generate_series(
    (v_slot_start at time zone v_timezone)::date-1,
    (v_slot_end at time zone v_timezone)::date+1,
    interval '1 day'
  ) day_anchor
  cross join lateral (
    select
      ((day_anchor::date+v_start) at time zone v_timezone) window_start,
      ((day_anchor::date+case when v_end<=v_start then 1 else 0 end+v_end)
        at time zone v_timezone) window_end
  ) window_bounds;
  return greatest(v_minutes,0);
end;
$$;


ALTER FUNCTION "solver_private"."pay_rule_billable_minutes_v2"("p_snapshot" "jsonb", "p_rule" "jsonb", "p_slot" "jsonb") OWNER TO "postgres";

--
-- Name: pay_rule_matches_v2("jsonb", "jsonb", "jsonb", "jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."pay_rule_matches_v2"("p_snapshot" "jsonb", "p_rule" "jsonb", "p_employee" "jsonb", "p_slot" "jsonb") RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_condition jsonb;
begin
  if not coalesce((p_rule->>'active')::boolean,true) then return false; end if;
  if nullif(p_rule->>'effectiveFrom','') is not null
    and (p_slot->>'date')::date<(p_rule->>'effectiveFrom')::date then return false; end if;
  if nullif(p_rule->>'effectiveTo','') is not null
    and (p_slot->>'date')::date>(p_rule->>'effectiveTo')::date then return false; end if;
  for v_condition in select value from jsonb_array_elements(coalesce(p_rule->'conditions','[]'::jsonb))
  loop
    if not solver_private.pay_condition_matches_v2(v_condition,p_snapshot,p_employee,p_slot)
      then return false; end if;
  end loop;
  if jsonb_array_length(coalesce(p_rule->'roleIds','[]'::jsonb))>0
    and not (p_rule->'roleIds' ? (p_slot->>'roleId')) then return false; end if;
  if jsonb_array_length(coalesce(p_rule->'dutyIds','[]'::jsonb))>0
    and not exists(
      select 1 from jsonb_array_elements_text(p_rule->'dutyIds') d
      where coalesce(p_slot->'dutyIds','[]'::jsonb) ? d
    ) then return false; end if;
  if jsonb_array_length(coalesce(p_rule->'locationIds','[]'::jsonb))>0
    and not (p_rule->'locationIds' ? (p_slot->>'locationId')) then return false; end if;
  if jsonb_array_length(coalesce(p_rule->'shiftTemplateIds','[]'::jsonb))>0
    and not (p_rule->'shiftTemplateIds' ? (p_slot->>'shiftTemplateId')) then return false; end if;
  if jsonb_array_length(coalesce(p_rule->'dayMask','[]'::jsonb))>0
    and not exists(
      select 1 from jsonb_array_elements(p_rule->'dayMask') d
      where (d.value#>>'{}')::integer=extract(isodow from (p_slot->>'date')::date)::integer
    ) then return false; end if;
  if (nullif(p_rule->>'localStart','') is null)<>(nullif(p_rule->>'localEnd','') is null)
    then raise exception 'PAY_RULE_LOCAL_TIME_INVALID'; end if;
  if nullif(p_rule->>'localStart','') is not null and not solver_private.pay_condition_matches_v2(
    jsonb_build_object('field','local_time','operator','OVERLAPS_TIME','value',
      jsonb_build_object('start',p_rule->>'localStart','end',p_rule->>'localEnd')),
    p_snapshot,p_employee,p_slot
  ) then return false; end if;
  return true;
end;
$$;


ALTER FUNCTION "solver_private"."pay_rule_matches_v2"("p_snapshot" "jsonb", "p_rule" "jsonb", "p_employee" "jsonb", "p_slot" "jsonb") OWNER TO "postgres";

--
-- Name: publication_authority_guard_v2(); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."publication_authority_guard_v2"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_company public.published_schedules_v2%rowtype;
begin
  if tg_table_name='published_schedules_v2' and new.status='PUBLISHED' then
    if new.source_type='COMPANY' and exists(
      select 1 from public.published_role_schedules_v2 role_schedule
      where role_schedule.month=new.month and role_schedule.status='PUBLISHED'
    ) then
      raise exception 'COMPANY_PUBLICATION_CONFLICTS_WITH_PUBLISHED_ROLES';
    end if;
    return new;
  end if;

  if tg_table_name='published_role_schedules_v2' and new.status='PUBLISHED' then
    select schedule.* into v_company
    from public.published_schedules_v2 schedule
    where schedule.month=new.month and schedule.status='PUBLISHED'
    order by schedule.published_at desc,schedule.id desc limit 1
    for update;
    if v_company.id is not null and v_company.source_type='COMPANY' then
      raise exception 'ROLE_PUBLICATION_CONFLICTS_WITH_COMPANY_SCHEDULE';
    end if;
    -- Replacing one role invalidates a previously assembled composite.  Keep
    -- its immutable history, but do not let owners and employees read two
    -- different effective revisions while a new composite is pending.
    if v_company.id is not null and v_company.source_type='ROLE_COMPOSITE' and not exists(
      select 1 from public.published_schedule_variants_v2 link
      where link.schedule_id=v_company.id and link.role_id=new.role_id
        and link.variant_id=new.variant_id
    ) then
      update public.published_schedules_v2 schedule set
        status='ARCHIVED',archived_at=now(),archived_by=auth.uid()
      where schedule.id=v_company.id;
      insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
      values(auth.uid(),'published_schedule_v2',v_company.id::text,
        'ARCHIVE_STALE_ROLE_COMPOSITE',jsonb_build_object(
          'roleId',new.role_id,'replacementVariantId',new.variant_id
        ));
    end if;
    return new;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "solver_private"."publication_authority_guard_v2"() OWNER TO "postgres";

--
-- Name: publication_snapshot_basis_v2("jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."publication_snapshot_basis_v2"("p_snapshot" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" IMMUTABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select jsonb_set(
    coalesce(p_snapshot,'{}'::jsonb)
      -'runId'-'baselineAssignments',
    '{settings}',
    coalesce(p_snapshot->'settings','{}'::jsonb)-'randomSeed',
    true
  );
$$;


ALTER FUNCTION "solver_private"."publication_snapshot_basis_v2"("p_snapshot" "jsonb") OWNER TO "postgres";

--
-- Name: publication_snapshot_hash_v2("jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."publication_snapshot_hash_v2"("p_snapshot" "jsonb") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select encode(extensions.digest(convert_to(
    solver_private.canonical_json_v2(
      solver_private.publication_snapshot_basis_v2(p_snapshot)
    ),
    'UTF8'
  ),'sha256'),'hex');
$$;


ALTER FUNCTION "solver_private"."publication_snapshot_hash_v2"("p_snapshot" "jsonb") OWNER TO "postgres";

--
-- Name: publication_static_input_hash_v2("jsonb"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."publication_static_input_hash_v2"("p_snapshot" "jsonb") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select encode(extensions.digest(convert_to(
    solver_private.canonical_json_v2(
      solver_private.publication_snapshot_basis_v2(p_snapshot)
        -'externalAssignments'
    ),
    'UTF8'
  ),'sha256'),'hex');
$$;


ALTER FUNCTION "solver_private"."publication_static_input_hash_v2"("p_snapshot" "jsonb") OWNER TO "postgres";

--
-- Name: published_variant_is_frozen_v2("uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."published_variant_is_frozen_v2"("p_variant_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select p_variant_id is not null and exists(
    select 1
    from public.published_schedule_variants_v2 sv
    where sv.variant_id=p_variant_id
  );
$$;


ALTER FUNCTION "solver_private"."published_variant_is_frozen_v2"("p_variant_id" "uuid") OWNER TO "postgres";

--
-- Name: rebuild_standby_month_v2("date"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."rebuild_standby_month_v2"("p_month" "date") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_month date:=date_trunc('month',p_month)::date;
  v_role_schedule public.published_role_schedules_v2%rowtype;
  v_schedule public.published_schedules_v2%rowtype;
  v_link record;
  v_created integer:=0;
begin
  update public.published_standby_assignments_v2 standby set status='SUPERSEDED'
  where standby.month=v_month and standby.status='PLANNED';
  for v_role_schedule in
    select publication.* from public.published_role_schedules_v2 publication
    where publication.month=v_month and publication.status='PUBLISHED'
    order by publication.role_id
  loop
    v_created:=v_created+solver_private.generate_standby_for_variant_uat_v2(
      v_role_schedule.variant_id,v_month,v_role_schedule.matrix_version_id,
      v_role_schedule.role_id,null,v_role_schedule.id
    );
  end loop;
  if v_created=0 then
    select schedule.* into v_schedule from public.published_schedules_v2 schedule
    where schedule.month=v_month and schedule.status='PUBLISHED'
      and schedule.source_type='COMPANY'
    order by schedule.published_at desc,schedule.id desc limit 1;
    if v_schedule.id is not null then
      for v_link in
        select distinct on (source.role_id) link.variant_id,source.role_id
        from public.published_schedule_variants_v2 link
        cross join lateral (
          select distinct assignment.role_id
          from public.plan_assignments_v2 assignment
          where assignment.variant_id=link.variant_id
        ) source
        where link.schedule_id=v_schedule.id
        order by source.role_id,link.ordinal
      loop
        v_created:=v_created+solver_private.generate_standby_for_variant_uat_v2(
          v_link.variant_id,v_month,v_schedule.matrix_version_id,v_link.role_id,
          v_schedule.id,null
        );
      end loop;
    end if;
  end if;
  return v_created;
end;
$$;


ALTER FUNCTION "solver_private"."rebuild_standby_month_v2"("p_month" "date") OWNER TO "postgres";

--
-- Name: record_leader_variant_history_v2("uuid", integer, "text", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."record_leader_variant_history_v2"("p_variant_id" "uuid", "p_revision" integer, "p_label" "text", "p_actor" "uuid") RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_cursor bigint; v_seq bigint;
begin
  select current_seq into v_cursor
  from solver_private.leader_variant_history_cursor_v2 where variant_id=p_variant_id for update;
  if v_cursor is not null then
    delete from solver_private.leader_variant_history_v2
      where variant_id=p_variant_id and seq>v_cursor;
  end if;
  insert into solver_private.leader_variant_history_v2(variant_id,revision,label,snapshot,created_by)
  values(p_variant_id,p_revision,left(coalesce(nullif(trim(p_label),''),'Zmiana w Studio'),240),
    solver_private.leader_variant_snapshot_v2(p_variant_id),p_actor)
  returning seq into v_seq;
  insert into solver_private.leader_variant_history_cursor_v2(variant_id,current_seq,updated_by)
  values(p_variant_id,v_seq,p_actor)
  on conflict(variant_id) do update set current_seq=excluded.current_seq,
    updated_at=now(),updated_by=excluded.updated_by;
  return v_seq;
end;
$$;


ALTER FUNCTION "solver_private"."record_leader_variant_history_v2"("p_variant_id" "uuid", "p_revision" integer, "p_label" "text", "p_actor" "uuid") OWNER TO "postgres";

--
-- Name: recover_expired_solver_runs_v2(integer); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."recover_expired_solver_runs_v2"("p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_run public.optimization_runs_v2%rowtype;
  v_message_id bigint;
  v_requeued integer:=0;
  v_failed integer:=0;
  v_cancelled integer:=0;
begin
  if coalesce(p_limit,0) not between 1 and 100 then
    raise exception 'INVALID_RECOVERY_LIMIT';
  end if;

  perform solver_private.lock_planning_revision_v2();
  for v_run in
    select run_row.*
    from public.optimization_runs_v2 run_row
    where run_row.status in ('RUNNING','VALIDATING','CANCEL_REQUESTED')
      and run_row.lease_expires_at is not null
      and run_row.lease_expires_at<=now()
    order by run_row.lease_expires_at,run_row.id
    for update skip locked
    limit p_limit
  loop
    update solver_private.optimization_attempts_v2
    set status='LEASE_LOST',finished_at=now(),heartbeat_at=now(),
      error_code='LEASE_EXPIRED',
      error_message='Worker nie odnowił dzierżawy w wymaganym czasie.'
    where run_id=v_run.id and status='RUNNING';

    if v_run.status='CANCEL_REQUESTED' then
      delete from public.plan_variants_v2 where run_id=v_run.id;
      update public.optimization_run_strategies_v2
      set status='CANCELLED',phase='CANCELLED',progress=0,
        metrics='{}'::jsonb,finished_at=now(),updated_at=now()
      where run_id=v_run.id;
      update public.optimization_runs_v2
      set status='CANCELLED',phase='CANCELLED',progress=0,
        queue_message_id=null,lease_owner=null,lease_token=null,
        lease_expires_at=null,worker_execution_name=null,heartbeat_at=null,
        finished_at=now(),updated_at=now()
      where id=v_run.id;
      v_cancelled:=v_cancelled+1;
    elsif v_run.attempt_count<v_run.max_attempts then
      perform solver_private.reset_retry_outputs_v2(v_run.id);
      select pgmq.send('schedule_optimizer_v2',jsonb_build_object(
        'schemaVersion',2,'runId',v_run.id,'retry',true,
        'reason','LEASE_EXPIRED','solverVersion',v_run.solver_version
      )) into v_message_id;
      update public.optimization_runs_v2
      set status='QUEUED',phase='RETRY_QUEUED',progress=0,
        queue_message_id=v_message_id,lease_owner=null,lease_token=null,
        lease_expires_at=null,worker_execution_name=null,heartbeat_at=null,
        started_at=null,finished_at=null,failure_code='LEASE_EXPIRED',
        failure_message='Przerwana próba została automatycznie dodana do kolejki.',
        updated_at=now()
      where id=v_run.id;
      v_requeued:=v_requeued+1;
    else
      delete from public.plan_variants_v2 where run_id=v_run.id;
      update public.optimization_run_strategies_v2
      set status='FAILED',phase='FAILED',progress=0,metrics='{}'::jsonb,
        failure_code='MAX_ATTEMPTS',finished_at=now(),updated_at=now()
      where run_id=v_run.id;
      update public.optimization_runs_v2
      set status='FAILED',phase='FAILED',progress=0,queue_message_id=null,
        lease_owner=null,lease_token=null,lease_expires_at=null,
        worker_execution_name=null,heartbeat_at=null,
        failure_code='MAX_ATTEMPTS',
        failure_message='Solver nie zakończył pracy po maksymalnej liczbie prób.',
        finished_at=now(),updated_at=now()
      where id=v_run.id;
      v_failed:=v_failed+1;
    end if;
  end loop;

  return jsonb_build_object(
    'requeued',v_requeued,'failed',v_failed,'cancelled',v_cancelled,
    'checkedAt',now()
  );
end;
$$;


ALTER FUNCTION "solver_private"."recover_expired_solver_runs_v2"("p_limit" integer) OWNER TO "postgres";

--
-- Name: FUNCTION "recover_expired_solver_runs_v2"("p_limit" integer); Type: COMMENT; Schema: solver_private; Owner: postgres
--

COMMENT ON FUNCTION "solver_private"."recover_expired_solver_runs_v2"("p_limit" integer) IS 'Requeues expired provider-neutral solver leases and finalizes cancelled or exhausted runs.';


--
-- Name: recovery_can_manage_role_uat_v1("uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."recovery_can_manage_role_uat_v1"("p_role_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$ select solver_private.recovery_can_manage_scope_uat_v1(p_role_id,null) $$;


ALTER FUNCTION "solver_private"."recovery_can_manage_role_uat_v1"("p_role_id" "uuid") OWNER TO "postgres";

--
-- Name: recovery_can_manage_scope_uat_v1("uuid", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."recovery_can_manage_scope_uat_v1"("p_role_id" "uuid", "p_location_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select public.matrix_v2_can_manage_resource_uat_v1(p_role_id,p_location_id,null)
$$;


ALTER FUNCTION "solver_private"."recovery_can_manage_scope_uat_v1"("p_role_id" "uuid", "p_location_id" "uuid") OWNER TO "postgres";

--
-- Name: recovery_candidate_snapshot_uat_v1("date", "uuid", "uuid", "uuid", "uuid"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."recovery_candidate_snapshot_uat_v1"("p_month" "date", "p_shift_id" "uuid", "p_role_id" "uuid", "p_duty_id" "uuid", "p_excluded_employee_id" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  with target as (
    select shift.*,role.matrix_version_id
    from public.plan_shifts_v2 shift
    join public.matrix_roles_v2 role on role.id=p_role_id
    where shift.id=p_shift_id
  ), candidates as (
    select profile.employee_id,profile.employee_no,
      trim(concat(profile.first_name,' ',profile.last_name)) name,
      profile.nominal_monthly_minutes,profile.maximum_monthly_minutes,profile.maximum_weekly_minutes,
      coalesce(standby.tier,10) priority,standby.tier,
      standby.id is not null standby_candidate,
      exists(select 1 from public.matrix_employee_locations_v2 location_grant,target
        where location_grant.matrix_version_id=profile.matrix_version_id
          and location_grant.employee_id=profile.employee_id
          and location_grant.location_id=target.location_id and location_grant.active
          and location_grant.standard_allowed) location_ok,
      (p_duty_id is null or exists(select 1 from public.matrix_employee_duties_v2 duty_grant
        where duty_grant.matrix_version_id=profile.matrix_version_id
          and duty_grant.employee_id=profile.employee_id and duty_grant.duty_id=p_duty_id
          and duty_grant.active)) duty_ok,
      exists(select 1 from public.employee_time_constraints_v2 constraint_row,target
        where constraint_row.employee_id=profile.employee_id and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
          and constraint_row.time_range && tstzrange(target.starts_at,target.ends_at,'[)')) hard_blocked,
      exists(select 1 from public.plan_assignments_v2 existing
        join public.plan_shifts_v2 existing_shift on existing_shift.id=existing.shift_id
        join solver_private.recovery_published_variants_uat_v1(p_month) published on published.variant_id=existing.variant_id
        cross join target where existing.employee_id=profile.employee_id
          and tstzrange(existing_shift.starts_at,existing_shift.ends_at,'[)') && tstzrange(target.starts_at,target.ends_at,'[)')) has_overlap,
      solver_private.variant_primary_conflict_reasons_uat_v2(
        target.variant_id,profile.employee_id,target.id
      ) primary_conflicts,
      coalesce((select sum(extract(epoch from (existing_shift.ends_at-existing_shift.starts_at))/60)::integer
        from public.plan_assignments_v2 existing join public.plan_shifts_v2 existing_shift on existing_shift.id=existing.shift_id
        join solver_private.recovery_published_variants_uat_v1(p_month) published on published.variant_id=existing.variant_id
        where existing.employee_id=profile.employee_id),0) month_minutes,
      coalesce((select sum(extract(epoch from (existing_shift.ends_at-existing_shift.starts_at))/60)::integer
        from public.plan_assignments_v2 existing join public.plan_shifts_v2 existing_shift on existing_shift.id=existing.shift_id
        join solver_private.recovery_published_variants_uat_v1(p_month) published on published.variant_id=existing.variant_id
        cross join target where existing.employee_id=profile.employee_id
          and extract(isoyear from existing_shift.shift_date)=extract(isoyear from target.shift_date)
          and extract(week from existing_shift.shift_date)=extract(week from target.shift_date)),0) week_minutes,
      coalesce((select rate.contract_type from public.employee_pay_rates_v2 rate,target
        where rate.employee_id=profile.employee_id and rate.active and rate.valid_from<=target.shift_date
          and (rate.valid_to is null or rate.valid_to>=target.shift_date)
        order by rate.valid_from desc limit 1),
        (select hr.contract_type from public.employee_hr_profiles hr
          where hr.employee_id=profile.employee_id),'INNE') contract_type
    from public.matrix_employee_profiles_v2 profile
    cross join target
    join public.matrix_employee_roles_v2 role_grant on role_grant.matrix_version_id=profile.matrix_version_id
      and role_grant.employee_id=profile.employee_id and role_grant.role_id=p_role_id and role_grant.active
    left join public.published_standby_assignments_v2 standby on standby.month=date_trunc('month',p_month)::date
      and standby.standby_date=target.shift_date and standby.role_id=p_role_id
      and standby.employee_id=profile.employee_id and standby.status='PLANNED'
    where profile.matrix_version_id=target.matrix_version_id and profile.active and profile.archived_at is null
      and (profile.employment_start is null or profile.employment_start<=target.shift_date)
      and (profile.employment_end is null or profile.employment_end>=target.shift_date)
      and profile.employee_id is distinct from p_excluded_employee_id
  ), evaluated as (
    select *,location_ok and duty_ok and not hard_blocked and not has_overlap
      and not (primary_conflicts && array['ONE_PRIMARY_SHIFT_PER_DAY','CONSECUTIVE_SHIFT_SEQUENCE']::text[]) eligible,
      to_jsonb(array_remove(array[
        case when not location_ok then 'Brak uprawnienia do lokalu' end,
        case when not duty_ok then 'Brak wymaganego obowiązku' end,
        case when hard_blocked then 'Twarda niedostępność, urlop lub L4' end,
        case when has_overlap then 'Ma już zmianę w tym czasie' end,
        case when 'ONE_PRIMARY_SHIFT_PER_DAY'=any(primary_conflicts) then
          'Osiągnięty dzienny limit zmian z konfiguracji firmy' end,
        case when 'CONSECUTIVE_SHIFT_SEQUENCE'=any(primary_conflicts) then
          'Niedozwolona sekwencja ostatnia zmiana dnia → pierwsza zmiana następnego dnia' end,
        case when maximum_weekly_minutes>0 and week_minutes>=maximum_weekly_minutes then
          case when contract_type in ('UMOWA_O_PRACE','CZESC_ETATU')
            then 'Osiągnięty limit tygodniowy UoP — wymaga zgody pracownika, potwierdzenia właściciela i kontroli zgodności czasu pracy'
            else 'Osiągnięty uzgodniony limit tygodniowy — wymaga świadomego wyjątku' end end,
        case when maximum_monthly_minutes>0 and month_minutes>=maximum_monthly_minutes then
          case when contract_type in ('UMOWA_O_PRACE','CZESC_ETATU')
            then 'Osiągnięty limit miesięczny UoP — wymaga zgody pracownika, potwierdzenia właściciela i kontroli zgodności czasu pracy'
            else 'Osiągnięty uzgodniony limit miesięczny — wymaga świadomego wyjątku' end end
      ]::text[],null)) reasons
    from candidates
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'employeeId',employee_id,'employeeNo',employee_no,'name',name,
    'source',case when standby_candidate then 'STANDBY' else 'ACTIVE_TEAM' end,
    'tier',tier,'priority',case when eligible then priority else 50 end,'eligible',eligible,
    'locationOk',location_ok,'dutyOk',duty_ok,'hardBlocked',hard_blocked,'overlaps',has_overlap,
    'primaryConflicts',to_jsonb(primary_conflicts),'reasons',reasons,'contractType',contract_type,
    'monthMinutes',month_minutes,'weekMinutes',week_minutes,
    'nominalMonthlyMinutes',nominal_monthly_minutes,'maximumMonthlyMinutes',maximum_monthly_minutes,
    'maximumWeeklyMinutes',maximum_weekly_minutes
  ) order by eligible desc,case when standby_candidate then tier else 10 end,
    abs(nominal_monthly_minutes-month_minutes),name),'[]'::jsonb)
  from (select * from evaluated order by eligible desc,priority,name limit 24) ranked
$$;


ALTER FUNCTION "solver_private"."recovery_candidate_snapshot_uat_v1"("p_month" "date", "p_shift_id" "uuid", "p_role_id" "uuid", "p_duty_id" "uuid", "p_excluded_employee_id" "uuid") OWNER TO "postgres";

--
-- Name: FUNCTION "recovery_candidate_snapshot_uat_v1"("p_month" "date", "p_shift_id" "uuid", "p_role_id" "uuid", "p_duty_id" "uuid", "p_excluded_employee_id" "uuid"); Type: COMMENT; Schema: solver_private; Owner: postgres
--

COMMENT ON FUNCTION "solver_private"."recovery_candidate_snapshot_uat_v1"("p_month" "date", "p_shift_id" "uuid", "p_role_id" "uuid", "p_duty_id" "uuid", "p_excluded_employee_id" "uuid") IS 'Recovery candidate snapshot with the same daily and adjacent-sequence hard rules as leader-variant validation.';


--
-- Name: recovery_clone_published_variant_uat_v1("uuid", "text"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."recovery_clone_published_variant_uat_v1"("p_source_variant_id" "uuid", "p_name" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid();
  v_source public.plan_variants_v2%rowtype;
  v_run public.optimization_runs_v2%rowtype;
  v_id uuid:=gen_random_uuid();
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into v_source from public.plan_variants_v2 where id=p_source_variant_id for update;
  select * into v_run from public.optimization_runs_v2 where id=v_source.run_id for update;
  if v_source.id is null or v_run.id is null or v_run.scope_type<>'ROLE'
    or v_source.status not in ('READY','SELECTED','PUBLISHED')
    or v_source.hard_violations<>0 then raise exception 'VALID_ROLE_VARIANT_REQUIRED'; end if;
  if not solver_private.recovery_can_manage_scope_uat_v1(v_run.scope_role_id,null)
    then raise exception 'ROLE_SCOPE_FORBIDDEN'; end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-copy:'||v_run.id::text,0));

  update public.plan_variants_v2 set status='ARCHIVED',selected=false
  where run_id=v_run.id and variant_kind='LEADER_COPY' and status in ('READY','SELECTED');
  update public.plan_variants_v2 set selected=false
  where run_id=v_run.id and selected;
  update public.plan_variants_v2 set
    status=case when status='SELECTED' then 'READY' else status end
  where run_id=v_run.id and variant_kind='GENERATED';

  insert into public.plan_variants_v2(
    id,run_id,run_strategy_id,strategy_id,name,status,hard_violations,
    assignment_count,unfilled_count,solver_status,solution_hash,objective_bound,
    metrics,recommended,selected,equivalent_to_variant_id,snapshot_hash,
    selected_at,selected_by,variant_kind,source_variant_id,revision,last_edited_at,last_edited_by
  ) values(
    v_id,v_source.run_id,v_source.run_strategy_id,v_source.strategy_id,trim(p_name),'SELECTED',0,
    v_source.assignment_count,v_source.unfilled_count,v_source.solver_status,v_source.solution_hash,
    v_source.objective_bound,coalesce(v_source.metrics,'{}'::jsonb)||jsonb_build_object(
      'leaderCopy',true,'recoveryDraft',true,'recoverySourceVariantId',v_source.id),
    false,true,v_source.equivalent_to_variant_id,v_source.snapshot_hash,now(),v_actor,
    'LEADER_COPY',v_source.id,0,now(),v_actor
  );

  insert into public.plan_shifts_v2(
    id,variant_id,slot_group_key,shift_template_id,location_id,shift_date,
    starts_at,ends_at,source_type,source_id,created_at
  ) select public.matrix_v2_stable_uuid('LEADER_SHIFT:'||v_id::text||':'||source.id::text),
    v_id,source.slot_group_key,source.shift_template_id,source.location_id,source.shift_date,
    source.starts_at,source.ends_at,source.source_type,source.source_id,now()
  from public.plan_shifts_v2 source where source.variant_id=v_source.id;

  insert into public.plan_assignments_v2(
    id,variant_id,shift_id,slot_key,employee_id,role_id,locked,explanation,created_at
  ) select public.matrix_v2_stable_uuid('LEADER_ASSIGNMENT:'||v_id::text||':'||source.id::text),
    v_id,public.matrix_v2_stable_uuid('LEADER_SHIFT:'||v_id::text||':'||source.shift_id::text),
    source.slot_key,source.employee_id,source.role_id,source.locked,
    coalesce(source.explanation,'{}'::jsonb)||jsonb_build_object(
      'sourceVariantId',v_source.id,'sourceAssignmentId',source.id,'edited',false,'recoveryDraft',true),now()
  from public.plan_assignments_v2 source where source.variant_id=v_source.id;

  insert into public.plan_assignment_duties_v2(assignment_id,duty_id)
  select public.matrix_v2_stable_uuid('LEADER_ASSIGNMENT:'||v_id::text||':'||source.id::text),duty.duty_id
  from public.plan_assignments_v2 source
  join public.plan_assignment_duties_v2 duty on duty.assignment_id=source.id
  where source.variant_id=v_source.id;

  insert into public.plan_issues_v2(
    variant_id,shift_id,slot_key,issue_code,severity,role_id,duty_id,
    required_count,assigned_count,message,metadata,created_at
  ) select v_id,
    case when source.shift_id is null then null else
      public.matrix_v2_stable_uuid('LEADER_SHIFT:'||v_id::text||':'||source.shift_id::text) end,
    source.slot_key,source.issue_code,source.severity,source.role_id,source.duty_id,
    source.required_count,source.assigned_count,source.message,
    coalesce(source.metadata,'{}'::jsonb)||jsonb_build_object('sourceIssueId',source.id,'recoveryDraft',true),now()
  from public.plan_issues_v2 source where source.variant_id=v_source.id;

  insert into solver_private.plan_assignment_cost_components_v2(
    assignment_id,pay_rule_id,component_code,amount_minor,quantity_minutes,calculation_basis,created_at
  ) select public.matrix_v2_stable_uuid('LEADER_ASSIGNMENT:'||v_id::text||':'||assignment.id::text),
    component.pay_rule_id,component.component_code,component.amount_minor,component.quantity_minutes,
    component.calculation_basis,now()
  from public.plan_assignments_v2 assignment
  join solver_private.plan_assignment_cost_components_v2 component on component.assignment_id=assignment.id
  where assignment.variant_id=v_source.id;

  insert into solver_private.plan_variant_finance_v2(
    variant_id,base_cost_units,additions_cost_units,total_cost_units,base_cost_minor,
    additions_cost_minor,total_cost_minor,currency,budget_minor,hard_budget_exceeded,breakdown
  ) select v_id,finance.base_cost_units,finance.additions_cost_units,finance.total_cost_units,
    finance.base_cost_minor,finance.additions_cost_minor,finance.total_cost_minor,finance.currency,
    finance.budget_minor,finance.hard_budget_exceeded,
    coalesce(finance.breakdown,'{}'::jsonb)||jsonb_build_object('sourceVariantId',v_source.id,'recoveryDraft',true)
  from solver_private.plan_variant_finance_v2 finance where finance.variant_id=v_source.id;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'plan_variant_v2',v_id::text,'CREATE_RECOVERY_LEADER_COPY',
    jsonb_build_object('runId',v_run.id,'sourceVariantId',v_source.id,'name',trim(p_name),
      'publishedScheduleChanged',false));
  return v_id;
end;
$$;


ALTER FUNCTION "solver_private"."recovery_clone_published_variant_uat_v1"("p_source_variant_id" "uuid", "p_name" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "recovery_clone_published_variant_uat_v1"("p_source_variant_id" "uuid", "p_name" "text"); Type: COMMENT; Schema: solver_private; Owner: postgres
--

COMMENT ON FUNCTION "solver_private"."recovery_clone_published_variant_uat_v1"("p_source_variant_id" "uuid", "p_name" "text") IS 'Clones a published role variant into the sole selected leader draft without changing any published schedule reference.';


--
-- Name: recovery_published_variants_uat_v1("date"); Type: FUNCTION; Schema: solver_private; Owner: postgres
--

CREATE FUNCTION "solver_private"."recovery_published_variants_uat_v1"("p_month" "date") RETURNS TABLE("variant_id" "uuid")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  with latest_company as (
    select schedule.id from public.published_schedules_v2 schedule
    where schedule.month=date_trunc('month',p_month)::date and schedule.status='PUBLISHED'
    order by schedule.published_at desc limit 1
  )
  select link.variant_id from latest_company
    join public.published_schedule_variants_v2 link on link.schedule_id=latest_company.id
  union all
  select publication.variant_id from public.published_role_schedules_v2 publication
  where not exists(select 1 from latest_company)
    and publication.month=date_trunc('month',p_month)::date
    and publication.status='PUBLISHED'
$$;


ALTER FUNCTION "solver_private"."recovery_published_variants_uat_v1"("p_month" "date") OWNER TO "postgres";

