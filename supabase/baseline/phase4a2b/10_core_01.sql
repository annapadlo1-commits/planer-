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
-- Name: authorization_private; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA "authorization_private";


ALTER SCHEMA "authorization_private" OWNER TO "postgres";

--
-- Name: SCHEMA "public"; Type: COMMENT; Schema: -; Owner: pg_database_owner
--

COMMENT ON SCHEMA "public" IS 'standard public schema';


--
-- Name: solver_private; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA "solver_private";


ALTER SCHEMA "solver_private" OWNER TO "postgres";

--
-- Name: app_role; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE "public"."app_role" AS ENUM (
    'OWNER',
    'ADMIN',
    'HR_FINANCE',
    'ROLE_MANAGER',
    'LOCATION_MANAGER',
    'VERIFIER',
    'EMPLOYEE'
);


ALTER TYPE "public"."app_role" OWNER TO "postgres";

--
-- Name: attendance_event_type; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE "public"."attendance_event_type" AS ENUM (
    'CHECK_IN',
    'CHECK_OUT',
    'BREAK_START',
    'BREAK_END',
    'MANAGER_CORRECTION'
);


ALTER TYPE "public"."attendance_event_type" OWNER TO "postgres";

--
-- Name: employee_role; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE "public"."employee_role" AS ENUM (
    'KELNER',
    'BARMAN',
    'PIZZABAR',
    'PREP',
    'POMOC'
);


ALTER TYPE "public"."employee_role" OWNER TO "postgres";

--
-- Name: event_status; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE "public"."event_status" AS ENUM (
    'DRAFT',
    'NEEDS_VERIFICATION',
    'CONFIRMED',
    'CANCELLED'
);


ALTER TYPE "public"."event_status" OWNER TO "postgres";

--
-- Name: location_code; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE "public"."location_code" AS ENUM (
    'KRUCZA',
    'PAWILONY'
);


ALTER TYPE "public"."location_code" OWNER TO "postgres";

--
-- Name: plan_status; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE "public"."plan_status" AS ENUM (
    'DRAFT',
    'GENERATING',
    'READY',
    'PUBLISHED',
    'STALE',
    'ARCHIVED',
    'FAILED'
);


ALTER TYPE "public"."plan_status" OWNER TO "postgres";

--
-- Name: task_status; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE "public"."task_status" AS ENUM (
    'NEW',
    'IN_PROGRESS',
    'APPROVED',
    'REJECTED',
    'CHANGES_REQUESTED',
    'DONE'
);


ALTER TYPE "public"."task_status" OWNER TO "postgres";

--
-- Name: calendar_event_allowed_uat_v1("uuid"); Type: FUNCTION; Schema: authorization_private; Owner: postgres
--

CREATE FUNCTION "authorization_private"."calendar_event_allowed_uat_v1"("p_event_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select exists(
    select 1
    from public.workforce_calendar_events_v2 event
    where event.id=p_event_id
      and authorization_private.calendar_payload_allowed_uat_v1(
        event.location_id,
        coalesce((select jsonb_agg(jsonb_build_object('roleId',demand.role_id))
          from public.workforce_event_demand_v2 demand where demand.event_id=event.id),'[]'::jsonb),
        coalesce((select jsonb_agg(jsonb_build_object('roleId',hot.role_id))
          from public.workforce_hot_day_limits_v2 hot where hot.event_id=event.id),'[]'::jsonb)
      )
  );
$$;


ALTER FUNCTION "authorization_private"."calendar_event_allowed_uat_v1"("p_event_id" "uuid") OWNER TO "postgres";

--
-- Name: calendar_payload_allowed_uat_v1("uuid", "jsonb", "jsonb"); Type: FUNCTION; Schema: authorization_private; Owner: postgres
--

CREATE FUNCTION "authorization_private"."calendar_payload_allowed_uat_v1"("p_location_id" "uuid", "p_demands" "jsonb", "p_hot_limits" "jsonb") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  with role_ids as (
    select nullif(item->>'roleId','')::uuid role_id
    from jsonb_array_elements(coalesce(p_demands,'[]'::jsonb)||coalesce(p_hot_limits,'[]'::jsonb)) item
  )
  select public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.matrix_v2_scope_allows_resource_for_app_role_uat_v1(
      'LOCATION_MANAGER',null,p_location_id,null
    )
    or (
      exists(select 1 from role_ids where role_id is not null)
      and not exists(
        select 1 from role_ids
        where role_id is null or not public.matrix_v2_scope_allows_resource_for_app_role_uat_v1(
          'ROLE_MANAGER',role_id,p_location_id,null
        )
      )
    );
$$;


ALTER FUNCTION "authorization_private"."calendar_payload_allowed_uat_v1"("p_location_id" "uuid", "p_demands" "jsonb", "p_hot_limits" "jsonb") OWNER TO "postgres";

--
-- Name: enter_resource_scope_uat_v1(); Type: FUNCTION; Schema: authorization_private; Owner: postgres
--

CREATE FUNCTION "authorization_private"."enter_resource_scope_uat_v1"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  perform set_config('szafunek.resource_scope_actor',auth.uid()::text,true);
end;
$$;


ALTER FUNCTION "authorization_private"."enter_resource_scope_uat_v1"() OWNER TO "postgres";

--
-- Name: matrix_v2_visible_employee_ids_uat_v1(); Type: FUNCTION; Schema: authorization_private; Owner: postgres
--

CREATE FUNCTION "authorization_private"."matrix_v2_visible_employee_ids_uat_v1"() RETURNS TABLE("employee_id" "uuid")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select employee.id
  from public.employees employee
  where public.matrix_v2_can_manage_employee(employee.id)
$$;


ALTER FUNCTION "authorization_private"."matrix_v2_visible_employee_ids_uat_v1"() OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_visible_employee_ids_uat_v1"(); Type: COMMENT; Schema: authorization_private; Owner: postgres
--

COMMENT ON FUNCTION "authorization_private"."matrix_v2_visible_employee_ids_uat_v1"() IS 'Canonical employee visibility set for matrix_v2_workspace, delegated to Phase 1 resource-aware authorization.';


--
-- Name: application_access_bulk_apply_uat_v1("jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."application_access_bulk_apply_uat_v1"("p_rows" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_row jsonb;
  v_count integer:=0;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if jsonb_typeof(p_rows)<>'array' then raise exception 'ACCESS_ROWS_MUST_BE_ARRAY'; end if;
  if jsonb_array_length(p_rows)<1 or jsonb_array_length(p_rows)>1000 then
    raise exception 'ACCESS_ROWS_COUNT_OUT_OF_RANGE';
  end if;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    perform public.application_access_save_uat_v1(
      v_row->>'email',
      v_row->>'appRole',
      nullif(v_row->>'roleId','')::uuid,
      nullif(v_row->>'locationId','')::uuid,
      coalesce((v_row->>'active')::boolean,true)
    );
    v_count:=v_count+1;
  end loop;
  return jsonb_build_object('applied',v_count);
end;
$$;


ALTER FUNCTION "public"."application_access_bulk_apply_uat_v1"("p_rows" "jsonb") OWNER TO "postgres";

--
-- Name: application_access_directory_uat_v1(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."application_access_directory_uat_v1"() RETURNS "jsonb"
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
    where mv.schema_version>=2 and mv.status in ('DRAFT','ACTIVE')
    order by (mv.status='DRAFT') desc,mv.version desc limit 1;
  return jsonb_build_object(
    'entries',coalesce((select jsonb_agg(jsonb_build_object(
      'id',d.id,'email',d.email,'appRole',d.app_role,'active',d.active,
      'authUserId',d.auth_user_id,
      'status',case when d.auth_user_id is null then 'PENDING' else 'ACTIVE' end,
      'roleLogicalId',d.role_logical_id,'roleName',r.name,
      'locationLogicalId',d.location_logical_id,'locationName',l.name
    ) order by lower(d.email),d.app_role::text)
    from public.application_access_directory_v1 d
    left join public.matrix_roles_v2 r on r.matrix_version_id=v_matrix and r.logical_id=d.role_logical_id
    left join public.matrix_locations_v2 l on l.matrix_version_id=v_matrix and l.logical_id=d.location_logical_id),'[]'::jsonb),
    'roles',coalesce((select jsonb_agg(jsonb_build_object(
      'rowId',r.id,'logicalId',r.logical_id,'name',r.name,'code',r.code
    ) order by r.sort_order,r.name) from public.matrix_roles_v2 r
      where r.matrix_version_id=v_matrix and r.active),'[]'::jsonb),
    'locations',coalesce((select jsonb_agg(jsonb_build_object(
      'rowId',l.id,'logicalId',l.logical_id,'name',l.name,'code',l.code
    ) order by l.sort_order,l.name) from public.matrix_locations_v2 l
      where l.matrix_version_id=v_matrix and l.active),'[]'::jsonb)
  );
end;
$$;


ALTER FUNCTION "public"."application_access_directory_uat_v1"() OWNER TO "postgres";

--
-- Name: application_access_materialize_uat_v1("text", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."application_access_materialize_uat_v1"("p_email" "text", "p_auth_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_entry record;
begin
  for v_entry in
    select * from public.application_access_directory_v1 d
    where lower(d.email)=lower(trim(p_email)) and d.active
  loop
    update public.application_access_directory_v1
      set auth_user_id=p_auth_user_id,updated_at=now()
      where id=v_entry.id;

    insert into public.matrix_scope_grants_v2(
      auth_user_id,app_role,role_logical_id,location_logical_id,active,created_by
    ) values(
      p_auth_user_id,v_entry.app_role,v_entry.role_logical_id,
      v_entry.location_logical_id,true,v_entry.created_by
    ) on conflict(auth_user_id,app_role,role_logical_id,location_logical_id,duty_logical_id)
      do update set active=true,updated_at=now();

    if v_entry.app_role in ('OWNER','ADMIN','HR_FINANCE','VERIFIER','EMPLOYEE') then
      insert into public.user_permissions(auth_user_id,app_role,scope_role,scope_location)
      values(p_auth_user_id,v_entry.app_role,null,null)
      on conflict do nothing;
    end if;
  end loop;

  if exists(
    select 1 from public.application_access_directory_v1 d
    where lower(d.email)=lower(trim(p_email)) and d.active and d.app_role='EMPLOYEE'
  ) then
    update public.employees e set auth_user_id=p_auth_user_id,updated_at=now()
    where lower(coalesce(e.email,''))=lower(trim(p_email))
      and (e.auth_user_id is null or e.auth_user_id=p_auth_user_id);
  end if;
end;
$$;


ALTER FUNCTION "public"."application_access_materialize_uat_v1"("p_email" "text", "p_auth_user_id" "uuid") OWNER TO "postgres";

--
-- Name: application_access_save_uat_v1("text", "text", "uuid", "uuid", boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."application_access_save_uat_v1"("p_email" "text", "p_app_role" "text", "p_role_id" "uuid" DEFAULT NULL::"uuid", "p_location_id" "uuid" DEFAULT NULL::"uuid", "p_active" boolean DEFAULT true) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare v_actor uuid:=auth.uid(); v_email text:=lower(trim(p_email));
  v_role public.app_role; v_role_logical uuid; v_location_logical uuid;
  v_auth uuid; v_id uuid;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
    raise exception 'INVALID_ACCESS_EMAIL';
  end if;
  begin v_role:=upper(trim(p_app_role))::public.app_role;
  exception when others then raise exception 'INVALID_APP_ROLE'; end;

  if p_role_id is not null then
    select r.logical_id into v_role_logical from public.matrix_roles_v2 r where r.id=p_role_id;
  end if;
  if p_location_id is not null then
    select l.logical_id into v_location_logical from public.matrix_locations_v2 l where l.id=p_location_id;
  end if;
  if v_role='ROLE_MANAGER' and v_role_logical is null then raise exception 'ROLE_SCOPE_REQUIRED'; end if;
  if v_role='LOCATION_MANAGER' and v_location_logical is null then raise exception 'LOCATION_SCOPE_REQUIRED'; end if;
  if v_role not in ('ROLE_MANAGER','LOCATION_MANAGER') then
    v_role_logical:=null;v_location_logical:=null;
  elsif v_role='ROLE_MANAGER' then v_location_logical:=null;
  elsif v_role='LOCATION_MANAGER' then v_role_logical:=null;
  end if;

  select u.id into v_auth from auth.users u where lower(u.email)=v_email limit 1;
  insert into public.application_access_directory_v1(
    email,app_role,role_logical_id,location_logical_id,auth_user_id,active,created_by
  ) values(v_email,v_role,v_role_logical,v_location_logical,v_auth,p_active,v_actor)
  on conflict(email,app_role,role_logical_id,location_logical_id)
  do update set auth_user_id=excluded.auth_user_id,active=excluded.active,
    updated_at=now()
  returning id into v_id;

  if v_auth is not null then
    if p_active then
      perform public.application_access_materialize_uat_v1(v_email,v_auth);
    else
      delete from public.matrix_scope_grants_v2 g
        where g.auth_user_id=v_auth and g.app_role=v_role
          and g.role_logical_id is not distinct from v_role_logical
          and g.location_logical_id is not distinct from v_location_logical;
      if v_role in ('OWNER','ADMIN','HR_FINANCE','VERIFIER','EMPLOYEE') then
        if v_role='OWNER' and v_auth=v_actor then raise exception 'CANNOT_REMOVE_OWN_OWNER_ACCESS'; end if;
        delete from public.user_permissions p where p.auth_user_id=v_auth and p.app_role=v_role;
      end if;
    end if;
  end if;
  return jsonb_build_object('id',v_id,'email',v_email,'appRole',v_role,
    'active',p_active,'status',case when v_auth is null then 'PENDING' else 'ACTIVE' end);
end;
$_$;


ALTER FUNCTION "public"."application_access_save_uat_v1"("p_email" "text", "p_app_role" "text", "p_role_id" "uuid", "p_location_id" "uuid", "p_active" boolean) OWNER TO "postgres";

--
-- Name: application_finance_visibility_current_uat_v1(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."application_finance_visibility_current_uat_v1"() RETURNS "text"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_actor uuid:=auth.uid(); v_visibility text;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select p.visibility into v_visibility
  from public.application_finance_visibility_policy_v1 p
  where p.app_role in (
    select up.app_role from public.user_permissions up where up.auth_user_id=v_actor
    union
    select grant_row.app_role from public.matrix_scope_grants_v2 grant_row where grant_row.auth_user_id=v_actor and grant_row.active
  )
  order by case p.visibility when 'FULL' then 4 when 'AGGREGATE' then 3 when 'BUDGET_ONLY' then 2 else 1 end desc
  limit 1;
  return coalesce(v_visibility,'NONE');
end;
$$;


ALTER FUNCTION "public"."application_finance_visibility_current_uat_v1"() OWNER TO "postgres";

--
-- Name: application_finance_visibility_policy_uat_v1(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."application_finance_visibility_policy_uat_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.has_app_role('OWNER') then raise exception 'ACCESS_POLICY_VIEW_FORBIDDEN'; end if;
  return jsonb_build_object('levels',jsonb_build_array('NONE','BUDGET_ONLY','AGGREGATE','FULL'),'policies',coalesce((select jsonb_agg(jsonb_build_object('appRole',p.app_role::text,'visibility',p.visibility,'updatedAt',p.updated_at) order by p.app_role::text) from public.application_finance_visibility_policy_v1 p),'[]'::jsonb));
end;
$$;


ALTER FUNCTION "public"."application_finance_visibility_policy_uat_v1"() OWNER TO "postgres";

--
-- Name: application_finance_visibility_save_uat_v1("text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."application_finance_visibility_save_uat_v1"("p_app_role" "text", "p_visibility" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_actor uuid:=auth.uid(); v_role public.app_role; v_visibility text:=upper(trim(coalesce(p_visibility,'')));
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.has_app_role('OWNER') then raise exception 'ACCESS_POLICY_EDIT_FORBIDDEN'; end if;
  begin v_role:=upper(trim(coalesce(p_app_role,'')))::public.app_role;
  exception when invalid_text_representation then raise exception 'INVALID_APPLICATION_ROLE'; end;
  if v_visibility not in ('NONE','BUDGET_ONLY','AGGREGATE','FULL') then raise exception 'INVALID_FINANCE_VISIBILITY'; end if;
  insert into public.application_finance_visibility_policy_v1(app_role,visibility,updated_by,updated_at)
  values(v_role,v_visibility,v_actor,now())
  on conflict(app_role) do update set visibility=excluded.visibility,updated_by=v_actor,updated_at=now();
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'application_finance_visibility_policy_v1',v_role::text,'VISIBILITY_CHANGED',jsonb_build_object('visibility',v_visibility));
  return jsonb_build_object('appRole',v_role::text,'visibility',v_visibility);
end;
$$;


ALTER FUNCTION "public"."application_finance_visibility_save_uat_v1"("p_app_role" "text", "p_visibility" "text") OWNER TO "postgres";

--
-- Name: assemble_role_plans("date", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."assemble_role_plans"("p_month" "date", "p_name" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare new_plan uuid; new_version integer; sec_count integer; ass_count integer; begin
 if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
 select count(*) into sec_count from role_plan_sections rp
 where rp.month=date_trunc('month',p_month)::date and rp.status='APPROVED'
   and rp.version=(select max(x.version) from role_plan_sections x where x.month=rp.month and x.role_id=rp.role_id);
 if sec_count=0 then raise exception 'NO_APPROVED_ROLE_PLANS'; end if;
 select coalesce(max(version),0)+1 into new_version from plans where month=date_trunc('month',p_month)::date;
 insert into plans(month,name,scenario_code,optimization_mode,staffing_level,status,version,created_by)
 values(date_trunc('month',p_month)::date,coalesce(nullif(trim(p_name),''),'Grafik operacyjny'),
   'MERGED','ROLE_PLANS','APPROVED','DRAFT',new_version,auth.uid()) returning id into new_plan;
 insert into shifts(plan_id,location_id,shift_date,shift_code,starts_at,ends_at,status)
 select distinct new_plan,s.location_id,s.shift_date,s.shift_code,s.starts_at,s.ends_at,'PLANNED'
 from role_plan_sections rp join role_plan_assignments rpa on rpa.role_plan_section_id=rp.id
 join assignments a on a.id=rpa.assignment_id join shifts s on s.id=a.shift_id
 where rp.month=date_trunc('month',p_month)::date and rp.status='APPROVED'
   and rp.version=(select max(x.version) from role_plan_sections x where x.month=rp.month and x.role_id=rp.role_id);
 insert into assignments(shift_id,employee_id,assigned_role,assigned_capability,assignment_type,cost,locked,explanation)
 select ns.id,a.employee_id,a.assigned_role,a.assigned_capability,a.assignment_type,a.cost,a.locked,
   a.explanation||jsonb_build_object('source','ROLE_PLAN','sourceAssignment',a.id)
 from role_plan_sections rp join role_plan_assignments rpa on rpa.role_plan_section_id=rp.id
 join assignments a on a.id=rpa.assignment_id join shifts os on os.id=a.shift_id
 join shifts ns on ns.plan_id=new_plan and ns.location_id=os.location_id and ns.shift_date=os.shift_date
   and ns.shift_code=os.shift_code and ns.starts_at=os.starts_at and ns.ends_at=os.ends_at
 where rp.month=date_trunc('month',p_month)::date and rp.status='APPROVED'
   and rp.version=(select max(x.version) from role_plan_sections x where x.month=rp.month and x.role_id=rp.role_id)
 on conflict do nothing;
 get diagnostics ass_count=row_count;
 update plans set status='READY',generated_at=now(),total_cost=(select coalesce(sum(cost),0) from assignments a join shifts s on s.id=a.shift_id where s.plan_id=new_plan) where id=new_plan;
 insert into composite_schedules(month,matrix_version_id,version,name,status,section_ids,created_by)
 select date_trunc('month',p_month)::date,(select id from matrix_versions where status='ACTIVE' order by version desc limit 1),
   coalesce((select max(version)+1 from composite_schedules where month=date_trunc('month',p_month)::date),1),p_name,'READY',
   array_agg(id),auth.uid() from role_plan_sections rp where rp.month=date_trunc('month',p_month)::date and rp.status='APPROVED'
   and rp.version=(select max(x.version) from role_plan_sections x where x.month=rp.month and x.role_id=rp.role_id);
 return jsonb_build_object('planId',new_plan,'sections',sec_count,'assignments',ass_count,'version',new_version);
end $$;


ALTER FUNCTION "public"."assemble_role_plans"("p_month" "date", "p_name" "text") OWNER TO "postgres";

--
-- Name: attendance_clock("text", "text", numeric, numeric); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."attendance_clock"("p_action" "text", "p_location" "text", "p_latitude" numeric DEFAULT NULL::numeric, "p_longitude" numeric DEFAULT NULL::numeric) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare e employees; l locations; out_id uuid; last_type text; begin
 select * into e from employees where auth_user_id=auth.uid() and active;
 if e.id is null then raise exception 'EMPLOYEE_ACCOUNT_NOT_LINKED'; end if;
 select * into l from locations where code::text=p_location and active;
 if l.id is null then raise exception 'LOCATION_NOT_FOUND'; end if;
 if not exists(select 1 from employee_locations el where el.employee_id=e.id and el.location_id=l.id and (el.standard_allowed or el.overtime_allowed or el.home_location)) then raise exception 'LOCATION_NOT_ALLOWED'; end if;
 select event_type::text into last_type from attendance_events where employee_id=e.id order by occurred_at desc limit 1;
 if p_action='CHECK_IN' and last_type='CHECK_IN' then raise exception 'ALREADY_CLOCKED_IN'; end if;
 if p_action='CHECK_OUT' and coalesce(last_type,'')<>'CHECK_IN' then raise exception 'NOT_CLOCKED_IN'; end if;
 if p_action not in ('CHECK_IN','CHECK_OUT') then raise exception 'INVALID_ACTION'; end if;
 insert into attendance_events(employee_id,location_id,event_type,verification_method,latitude,longitude,created_by)
 values(e.id,l.id,p_action::attendance_event_type,'GEOLOCATION',p_latitude,p_longitude,auth.uid()) returning id into out_id;
 return jsonb_build_object('id',out_id,'action',p_action,'occurredAt',now(),'location',l.name);
end $$;


ALTER FUNCTION "public"."attendance_clock"("p_action" "text", "p_location" "text", "p_latitude" numeric, "p_longitude" numeric) OWNER TO "postgres";

--
-- Name: availability_exception_review_before_phase1_uat_v1("uuid", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."availability_exception_review_before_phase1_uat_v1"("p_review_id" "uuid", "p_decision" "text", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_actor uuid:=auth.uid(); v_review public.availability_exception_reviews_v2%rowtype;
  v_decision text:=upper(trim(coalesce(p_decision,''))); v_constraint uuid;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  if v_decision not in ('APPROVE','REJECT') then raise exception 'INVALID_REVIEW_DECISION'; end if;
  if length(trim(coalesce(p_reason,'')))<3 then raise exception 'REVIEW_REASON_REQUIRED'; end if;
  select * into v_review from public.availability_exception_reviews_v2
  where id=p_review_id for update;
  if v_review.id is null then raise exception 'REVIEW_NOT_FOUND'; end if;
  if v_review.status<>'PENDING' then raise exception 'REVIEW_ALREADY_RESOLVED'; end if;
  if v_decision='APPROVE' then
    v_constraint:=gen_random_uuid();
    insert into public.employee_time_constraints_v2(
      id,employee_id,constraint_kind,time_range,source,source_record_key,
      priority,editable_by_employee,status,note,created_by
    ) values(v_constraint,v_review.employee_id,'UNAVAILABLE',v_review.requested_range,
      'HOT_DAY_APPROVED','hot-day-review:'||v_review.id::text,100,false,'ACTIVE',
      v_review.note,v_actor);
  end if;
  update public.availability_exception_reviews_v2 set
    status=case when v_decision='APPROVE' then 'APPROVED' else 'REJECTED' end,
    reviewed_by=v_actor,reviewed_at=now(),review_reason=trim(p_reason),
    constraint_id=v_constraint where id=v_review.id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'availability_exception_review_v2',v_review.id::text,v_decision,
    jsonb_build_object('employeeId',v_review.employee_id,'date',v_review.work_date,
      'roleId',v_review.role_id,'reason',trim(p_reason),'constraintId',v_constraint));
  insert into public.notifications(recipient_id,title,body)
  select employee.auth_user_id,'Decyzja dotycząca niedostępności',
    case when v_decision='APPROVE' then 'Niedostępność została zaakceptowana.'
      else 'Niedostępność nie została zaakceptowana: '||trim(p_reason) end
  from public.employees employee where employee.id=v_review.employee_id
    and employee.auth_user_id is not null;
  return jsonb_build_object('id',v_review.id,'status',
    case when v_decision='APPROVE' then 'APPROVED' else 'REJECTED' end,
    'constraintId',v_constraint);
end;
$$;


ALTER FUNCTION "public"."availability_exception_review_before_phase1_uat_v1"("p_review_id" "uuid", "p_decision" "text", "p_reason" "text") OWNER TO "postgres";

--
-- Name: availability_exception_review_uat_v2("uuid", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."availability_exception_review_uat_v2"("p_review_id" "uuid", "p_decision" "text", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_review public.availability_exception_reviews_v2%rowtype;
begin
  select * into v_review from public.availability_exception_reviews_v2 where id=p_review_id;
  if v_review.id is null then raise exception 'REVIEW_NOT_FOUND'; end if;
  if not public.matrix_v2_can_manage_resource_uat_v1(v_review.role_id,null,v_review.employee_id)
    then raise exception 'RESOURCE_SCOPE_FORBIDDEN'; end if;
  perform authorization_private.enter_resource_scope_uat_v1();
  return public.availability_exception_review_before_phase1_uat_v1(p_review_id,p_decision,p_reason);
end;
$$;


ALTER FUNCTION "public"."availability_exception_review_uat_v2"("p_review_id" "uuid", "p_decision" "text", "p_reason" "text") OWNER TO "postgres";

--
-- Name: budget_update("date", numeric, integer, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."budget_update"("p_month" "date", "p_amount" numeric, "p_warning_percent" integer, "p_hard_limit" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$ begin
 if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE')) then raise exception 'FORBIDDEN'; end if;
 insert into monthly_budgets(month,amount,warning_percent,hard_limit,updated_by,updated_at) values(date_trunc('month',p_month)::date,p_amount,p_warning_percent,p_hard_limit,auth.uid(),now())
 on conflict(month) do update set amount=excluded.amount,warning_percent=excluded.warning_percent,hard_limit=excluded.hard_limit,updated_by=auth.uid(),updated_at=now();
end $$;


ALTER FUNCTION "public"."budget_update"("p_month" "date", "p_amount" numeric, "p_warning_percent" integer, "p_hard_limit" boolean) OWNER TO "postgres";

--
-- Name: can_manage_plans(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."can_manage_plans"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select auth.uid() is not null and (
    public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or current_setting('szafunek.resource_scope_actor',true)=auth.uid()::text
  );
$$;


ALTER FUNCTION "public"."can_manage_plans"() OWNER TO "postgres";

--
-- Name: FUNCTION "can_manage_plans"(); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."can_manage_plans"() IS 'Global plan management is OWNER/ADMIN only. Scoped manager calls require a canonical resource guard.';


--
-- Name: can_view_assignment("uuid", "public"."employee_role", "public"."location_code"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."can_view_assignment"("p_employee_id" "uuid", "p_role" "public"."employee_role", "p_location" "public"."location_code") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or exists (select 1 from public.employees e where e.id=p_employee_id and e.auth_user_id=auth.uid())
    or exists (select 1 from public.user_permissions up where up.auth_user_id=auth.uid()
      and up.app_role='ROLE_MANAGER' and (up.scope_role is null or up.scope_role=p_role))
    or exists (select 1 from public.user_permissions up where up.auth_user_id=auth.uid()
      and up.app_role='LOCATION_MANAGER' and (up.scope_location is null or up.scope_location=p_location));
$$;


ALTER FUNCTION "public"."can_view_assignment"("p_employee_id" "uuid", "p_role" "public"."employee_role", "p_location" "public"."location_code") OWNER TO "postgres";

--
-- Name: claim_demo_owner(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."claim_demo_owner"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  current_user_id uuid := auth.uid();
  employee_id uuid;
begin
  if current_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if exists (
    select 1 from public.user_permissions
    where auth_user_id = current_user_id
  ) then
    return jsonb_build_object('claimed', false, 'reason', 'ALREADY_ASSIGNED');
  end if;

  if exists (
    select 1 from public.user_permissions where app_role = 'OWNER'
  ) then
    return jsonb_build_object('claimed', false, 'reason', 'OWNER_EXISTS');
  end if;

  insert into public.user_permissions (auth_user_id, app_role)
  values (current_user_id, 'OWNER');

  select id into employee_id
  from public.employees
  where employee_no = 'GP-001' and auth_user_id is null;

  if employee_id is not null then
    update public.employees
    set auth_user_id = current_user_id, updated_at = now()
    where id = employee_id;
  end if;

  return jsonb_build_object('claimed', true, 'role', 'OWNER', 'employee_no', 'GP-001');
end;
$$;


ALTER FUNCTION "public"."claim_demo_owner"() OWNER TO "postgres";

--
-- Name: complete_workspace("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."complete_workspace"("p_month" "date" DEFAULT CURRENT_DATE) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_payload jsonb;
  v_visibility text:=public.application_finance_visibility_current_uat_v1();
  v_employee jsonb;
  v_employees jsonb:='[]'::jsonb;
  v_budget jsonb;
begin
  v_payload:=public.complete_workspace_before_b4f101_uat_v1(p_month);
  if v_visibility='FULL' then return v_payload; end if;
  for v_employee in select value from jsonb_array_elements(coalesce(v_payload->'employees','[]'::jsonb)) loop
    v_employees:=v_employees||jsonb_build_array(v_employee-'finance');
  end loop;
  v_payload:=jsonb_set(v_payload,'{employees}',v_employees,true);
  if v_visibility='AGGREGATE' then return v_payload; end if;
  if v_visibility='BUDGET_ONLY' then
    v_budget:=v_payload->'budget';
    v_payload:=jsonb_set(v_payload,'{budget}',jsonb_build_object(
      'configured',v_budget is not null and v_budget<>'{}'::jsonb,
      'hardLimit',case when v_budget is null or v_budget='{}'::jsonb then null else v_budget->'hard_limit' end
    ),true);
    return v_payload;
  end if;
  return v_payload-'budget';
end;
$$;


ALTER FUNCTION "public"."complete_workspace"("p_month" "date") OWNER TO "postgres";

--
-- Name: FUNCTION "complete_workspace"("p_month" "date"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."complete_workspace"("p_month" "date") IS 'B4F-101 legacy workspace with server-side finance redaction.';


--
-- Name: complete_workspace_before_b4f101_uat_v1("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."complete_workspace_before_b4f101_uat_v1"("p_month" "date" DEFAULT CURRENT_DATE) RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
with target_month as (select date_trunc('month',p_month)::date as target_date),
active_matrix as (select * from matrix_versions where status='ACTIVE' order by version desc limit 1),
draft_matrix as (select * from matrix_versions where status='DRAFT' order by version desc limit 1),
chosen_plan as (
  select p.* from plans p,target_month t where p.month=t.target_date
  order by case p.status when 'PUBLISHED' then 1 when 'READY' then 2 else 3 end,p.version desc limit 1
)
select jsonb_build_object(
 'counts',jsonb_build_object(
   'employees',(select count(*) from employees where active),
   'archivedEmployees',(select count(*) from employees where not active),
   'roleManagers',(select count(distinct employee_id) from employee_capabilities where capability='ROLE_MANAGER' and active),
   'locations',(select count(*) from locations where active)
 ),
 'employees',coalesce((select jsonb_agg(jsonb_build_object(
   'id',e.id,'employeeNo',e.employee_no,'firstName',e.first_name,'lastName',e.last_name,'email',e.email,
   'primaryRole',e.primary_role,'nominalMinutes',e.monthly_nominal_minutes,'maxWeeklyMinutes',e.max_weekly_minutes,
   'maxMonthlyMinutes',e.max_monthly_minutes,'preferredShift',e.preferred_shift,'active',e.active,
   'archivedAt',e.archived_at,'archiveReason',e.archive_reason,
   'locations',coalesce((select jsonb_agg(jsonb_build_object('code',l.code,'name',l.name,'home',el.home_location,'standard',el.standard_allowed,'overtime',el.overtime_allowed) order by l.name) from employee_locations el join locations l on l.id=el.location_id where el.employee_id=e.id),'[]'::jsonb),
   'capabilities',coalesce((select jsonb_agg(jsonb_build_object('id',ec.id,'capability',ec.capability,'role',ec.scope_role,'location',ec.scope_location) order by ec.capability) from employee_capabilities ec where ec.employee_id=e.id and ec.active),'[]'::jsonb),
   'hr',case when public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE') then (select to_jsonb(h)-'employee_id' from employee_hr_profiles h where h.employee_id=e.id) else null end,
   'finance',case when public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE') then jsonb_build_object('hourlyRate',e.hourly_rate) else null end
 ) order by e.active desc,e.employee_no) from employees e where
   public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE')
   or public.has_app_role('ROLE_MANAGER') or public.has_app_role('LOCATION_MANAGER') or e.auth_user_id=auth.uid()),'[]'::jsonb),
 'activeMatrix',(select to_jsonb(a) from active_matrix a),
 'draftMatrix',(select to_jsonb(d) from draft_matrix d),
 'roles',coalesce((select jsonb_agg(to_jsonb(r) order by r.sort_order) from matrix_roles r where r.matrix_version_id=coalesce((select id from draft_matrix),(select id from active_matrix))),'[]'::jsonb),
 'functions',coalesce((select jsonb_agg(to_jsonb(f) order by f.name) from matrix_functions f where f.matrix_version_id=coalesce((select id from draft_matrix),(select id from active_matrix))),'[]'::jsonb),
 'locations',coalesce((select jsonb_agg(to_jsonb(l) order by l.name) from matrix_locations l where l.matrix_version_id=coalesce((select id from draft_matrix),(select id from active_matrix))),'[]'::jsonb),
 'shifts',coalesce((select jsonb_agg(to_jsonb(s) order by s.sort_order,s.name) from matrix_shift_templates s where s.matrix_version_id=coalesce((select id from draft_matrix),(select id from active_matrix))),'[]'::jsonb),
 'demand',coalesce((select jsonb_agg(to_jsonb(d)) from matrix_demand d join matrix_shift_templates s on s.id=d.shift_template_id where s.matrix_version_id=coalesce((select id from draft_matrix),(select id from active_matrix))),'[]'::jsonb),
 'sections',coalesce((select jsonb_agg(jsonb_build_object(
   'id',rp.id,'roleId',rp.role_id,'roleCode',r.code,'roleName',r.name,'version',rp.version,'status',rp.status,'name',rp.name,
   'createdAt',rp.created_at,'updatedAt',rp.updated_at,'planId',rp.legacy_plan_id,
   'assignmentCount',(select count(*) from role_plan_assignments ra where ra.role_plan_section_id=rp.id),
   'issueCount',(select count(*) from plan_issues pi where pi.plan_id=rp.legacy_plan_id and pi.role::text=r.code and pi.resolved_at is null)
 ) order by r.sort_order,rp.version desc) from role_plan_sections rp join matrix_roles r on r.id=rp.role_id,target_month t where rp.month=t.target_date),'[]'::jsonb),
 'plan',(select to_jsonb(p) from chosen_plan p),
 'budget',coalesce((select to_jsonb(b) from monthly_budgets b,target_month t where b.month=t.target_date),'{}'::jsonb),
 'preferences',coalesce((select jsonb_agg(to_jsonb(ep) order by ep.valid_from desc) from employee_preferences ep where ep.valid_to >= (select target_date from target_month)),'[]'::jsonb),
 'integrationRuns',coalesce((select jsonb_agg(to_jsonb(ir) order by ir.created_at desc) from integration_runs ir limit 20),'[]'::jsonb),
 'timeRecords',coalesce((select jsonb_agg(to_jsonb(tr) order by tr.work_date desc) from time_records tr,target_month t where date_trunc('month',tr.work_date)::date=t.target_date),'[]'::jsonb)
);
$$;


ALTER FUNCTION "public"."complete_workspace_before_b4f101_uat_v1"("p_month" "date") OWNER TO "postgres";

--
-- Name: create_operational_event("public"."location_code", "text", "text", "text", timestamp with time zone, timestamp with time zone, integer, "public"."event_status", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."create_operational_event"("p_location" "public"."location_code", "p_event_type" "text", "p_title" "text", "p_description" "text", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_expected_guests" integer DEFAULT NULL::integer, "p_status" "public"."event_status" DEFAULT 'DRAFT'::"public"."event_status", "p_demand" "jsonb" DEFAULT '[]'::"jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_event_id uuid;
  v_location_id uuid;
  v_item jsonb;
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  if p_ends_at <= p_starts_at then raise exception 'INVALID_EVENT_TIME'; end if;

  select id into v_location_id from public.locations where code = p_location and active;
  if v_location_id is null then raise exception 'LOCATION_NOT_FOUND'; end if;

  insert into public.operational_events(
    location_id, event_type, title, description, starts_at, ends_at,
    expected_guests, status, created_by
  ) values (
    v_location_id, p_event_type, p_title, nullif(p_description,''), p_starts_at, p_ends_at,
    p_expected_guests, p_status, auth.uid()
  ) returning id into v_event_id;

  for v_item in select * from jsonb_array_elements(coalesce(p_demand, '[]'::jsonb))
  loop
    insert into public.event_demand_changes(
      event_id, role, shift_code, additional_count, required_capability
    ) values (
      v_event_id,
      (v_item->>'role')::public.employee_role,
      nullif(v_item->>'shift_code',''),
      greatest(0, coalesce((v_item->>'additional_count')::integer, 0)),
      nullif(v_item->>'required_capability','')
    );
  end loop;

  update public.plans
  set status = 'STALE'
  where month = date_trunc('month', p_starts_at at time zone 'Europe/Warsaw')::date
    and status in ('READY','PUBLISHED');

  insert into public.audit_log(actor_id, entity_type, entity_id, action, new_data)
  values (auth.uid(), 'operational_event', v_event_id::text, 'CREATE',
    jsonb_build_object('title',p_title,'type',p_event_type,'status',p_status));
  return v_event_id;
end;
$$;


ALTER FUNCTION "public"."create_operational_event"("p_location" "public"."location_code", "p_event_type" "text", "p_title" "text", "p_description" "text", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_expected_guests" integer, "p_status" "public"."event_status", "p_demand" "jsonb") OWNER TO "postgres";

--
-- Name: create_role_plan_section("date", "uuid", "text", "text", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."create_role_plan_section"("p_month" "date", "p_role_id" "uuid", "p_name" "text", "p_scenario" "text" DEFAULT 'BASE'::"text", "p_mode" "text" DEFAULT 'BALANCED'::"text", "p_staffing" "text" DEFAULT 'OPTIMAL'::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_id uuid; v_version integer; v_mv uuid; begin
 if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
 select matrix_version_id into v_mv from matrix_roles where id=p_role_id and active;
 if v_mv is null then raise exception 'ROLE_NOT_FOUND'; end if;
 if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN') or exists(select 1 from user_permissions up join matrix_roles r on r.code=up.scope_role::text where up.auth_user_id=auth.uid() and up.app_role='ROLE_MANAGER' and r.id=p_role_id)) then raise exception 'ROLE_SCOPE_FORBIDDEN'; end if;
 select coalesce(max(version),0)+1 into v_version from role_plan_sections where month=date_trunc('month',p_month)::date and role_id=p_role_id;
 insert into role_plan_sections(month,matrix_version_id,role_id,version,name,scenario_code,optimization_mode,staffing_level,created_by)
 values(date_trunc('month',p_month)::date,v_mv,p_role_id,v_version,p_name,p_scenario,p_mode,p_staffing,auth.uid()) returning id into v_id;
 return v_id;
end $$;


ALTER FUNCTION "public"."create_role_plan_section"("p_month" "date", "p_role_id" "uuid", "p_name" "text", "p_scenario" "text", "p_mode" "text", "p_staffing" "text") OWNER TO "postgres";

--
-- Name: current_user_access(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."current_user_access"() RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select jsonb_build_object(
    'auth_user_id', auth.uid(),
    'roles', coalesce((
      select jsonb_agg(jsonb_build_object(
        'app_role', up.app_role,
        'scope_role', up.scope_role,
        'scope_location', up.scope_location
      ))
      from public.user_permissions up
      where up.auth_user_id = auth.uid()
    ), '[]'::jsonb),
    'employee', (
      select jsonb_build_object(
        'id', e.id,
        'employee_no', e.employee_no,
        'first_name', e.first_name,
        'last_name', e.last_name,
        'primary_role', e.primary_role
      )
      from public.employees e
      where e.auth_user_id = auth.uid()
      limit 1
    )
  );
$$;


ALTER FUNCTION "public"."current_user_access"() OWNER TO "postgres";

--
-- Name: current_user_access_v2(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."current_user_access_v2"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_user uuid:=auth.uid(); v_email text; v_roles jsonb; v_employee jsonb;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  select lower(u.email) into v_email from auth.users u where u.id=v_user;
  if v_email is not null then
    perform public.application_access_materialize_uat_v1(v_email,v_user);
  end if;

  select coalesce(jsonb_agg(item order by item->>'app_role'),'[]'::jsonb)
  into v_roles from (
    select distinct jsonb_build_object(
      'app_role',x.app_role::text,
      'scope_role',x.scope_role,
      'scope_location',x.scope_location,
      'role_logical_id',x.role_logical_id,
      'location_logical_id',x.location_logical_id
    ) item
    from (
      select p.app_role,p.scope_role::text scope_role,p.scope_location::text scope_location,
        null::uuid role_logical_id,null::uuid location_logical_id
      from public.user_permissions p where p.auth_user_id=v_user
      union all
      select g.app_role,r.code,l.code,g.role_logical_id,g.location_logical_id
      from public.matrix_scope_grants_v2 g
      left join lateral (
        select mr.code from public.matrix_roles_v2 mr
        join public.matrix_versions mv on mv.id=mr.matrix_version_id
        where mr.logical_id=g.role_logical_id and mv.status in ('DRAFT','ACTIVE')
        order by (mv.status='DRAFT') desc,mv.version desc limit 1
      ) r on true
      left join lateral (
        select ml.code from public.matrix_locations_v2 ml
        join public.matrix_versions mv on mv.id=ml.matrix_version_id
        where ml.logical_id=g.location_logical_id and mv.status in ('DRAFT','ACTIVE')
        order by (mv.status='DRAFT') desc,mv.version desc limit 1
      ) l on true
      where g.auth_user_id=v_user and g.active
    ) x
  ) roles;

  select jsonb_build_object(
    'id',e.id,'employee_no',e.employee_no,'first_name',e.first_name,
    'last_name',e.last_name,'primary_role',e.primary_role
  ) into v_employee from public.employees e where e.auth_user_id=v_user limit 1;

  return jsonb_build_object(
    'auth_user_id',v_user,'email',v_email,'roles',v_roles,'employee',v_employee
  );
end;
$$;


ALTER FUNCTION "public"."current_user_access_v2"() OWNER TO "postgres";

--
-- Name: emergency_assign("uuid", "uuid", "public"."employee_role", boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."emergency_assign"("p_shift_id" "uuid", "p_employee_id" "uuid", "p_role" "public"."employee_role", "p_notify" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_shift public.shifts;
  v_employee public.employees;
  v_minutes integer;
  v_assignment_id uuid;
  v_assigned integer;
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  select * into v_shift from public.shifts where id=p_shift_id;
  if v_shift.id is null then raise exception 'SHIFT_NOT_FOUND'; end if;
  select * into v_employee from public.employees where id=p_employee_id and active;
  if v_employee.id is null then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  if v_employee.primary_role<>p_role then raise exception 'ROLE_MISMATCH'; end if;
  if not exists(select 1 from public.employee_locations el
    where el.employee_id=p_employee_id and el.location_id=v_shift.location_id
      and (el.standard_allowed or el.overtime_allowed)) then
    raise exception 'LOCATION_NOT_ALLOWED';
  end if;
  if exists(select 1 from public.assignments a join public.shifts s on s.id=a.shift_id
    where a.employee_id=p_employee_id and s.plan_id=v_shift.plan_id
      and tstzrange(s.starts_at,s.ends_at,'[)') &&
        tstzrange(v_shift.starts_at,v_shift.ends_at,'[)')) then
    raise exception 'SHIFT_OVERLAP';
  end if;

  v_minutes:=public.shift_minutes(v_shift.starts_at,v_shift.ends_at);
  insert into public.assignments(
    shift_id,employee_id,assigned_role,assignment_type,cost,locked,explanation
  ) values (
    p_shift_id,p_employee_id,p_role,'EMERGENCY',
    round(v_employee.hourly_rate*v_minutes/60,2),true,
    jsonb_build_object('engine','MANUAL','reason','EMERGENCY_ASSIGNMENT','notify',p_notify)
  ) returning id into v_assignment_id;

  select count(*) into v_assigned from public.assignments
  where shift_id=p_shift_id and assigned_role=p_role;
  update public.plan_issues set resolved_at=now()
  where plan_id=v_shift.plan_id and shift_id=p_shift_id and role=p_role
    and issue_type='SHORTAGE' and required_count<=v_assigned and resolved_at is null;

  if p_notify and v_employee.auth_user_id is not null then
    insert into public.notifications(recipient_id,channel,title,body)
    values(v_employee.auth_user_id,'IN_APP','Awaryjna zmiana',
      'Dodano Cię do zmiany '||v_shift.shift_code||' dnia '||v_shift.shift_date);
  end if;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'assignment',v_assignment_id::text,'EMERGENCY_ASSIGN',
    jsonb_build_object('shift_id',p_shift_id,'employee_id',p_employee_id,'notify',p_notify));
  return jsonb_build_object('assignment_id',v_assignment_id,'status','ASSIGNED','notified',
    (p_notify and v_employee.auth_user_id is not null));
end;
$$;


ALTER FUNCTION "public"."emergency_assign"("p_shift_id" "uuid", "p_employee_id" "uuid", "p_role" "public"."employee_role", "p_notify" boolean) OWNER TO "postgres";

--
-- Name: FUNCTION "emergency_assign"("p_shift_id" "uuid", "p_employee_id" "uuid", "p_role" "public"."employee_role", "p_notify" boolean); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."emergency_assign"("p_shift_id" "uuid", "p_employee_id" "uuid", "p_role" "public"."employee_role", "p_notify" boolean) IS 'Retired Alpha 15 override. Use optimizer_emergency_assign_alpha16 with diagnostics.';


--
-- Name: employee_archive("uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."employee_archive"("p_employee_id" "uuid", "p_reason" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$ begin
 if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE')) then raise exception 'FORBIDDEN'; end if;
 update employees set active=false,archived_at=now(),archived_by=auth.uid(),archive_reason=nullif(trim(p_reason),'') where id=p_employee_id;
 if not found then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
 insert into audit_log(actor_id,entity_type,entity_id,action,new_data) values(auth.uid(),'employee',p_employee_id::text,'ARCHIVE',jsonb_build_object('reason',p_reason));
end $$;


ALTER FUNCTION "public"."employee_archive"("p_employee_id" "uuid", "p_reason" "text") OWNER TO "postgres";

--
-- Name: employee_availability_bulk_save_v2("date", "date", "text", boolean, time without time zone, time without time zone, "uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."employee_availability_bulk_save_v2"("p_from" "date", "p_to" "date", "p_kind" "text", "p_all_day" boolean DEFAULT true, "p_local_start" time without time zone DEFAULT NULL::time without time zone, "p_local_end" time without time zone DEFAULT NULL::time without time zone, "p_preferred_location_id" "uuid" DEFAULT NULL::"uuid", "p_note" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid := auth.uid();
  v_employee_id uuid;
  v_kind text := upper(trim(coalesce(p_kind,'')));
  v_timezone text;
  v_day date;
  v_start timestamptz;
  v_end timestamptz;
  v_count integer := 0;
  v_source_key text;
  v_location_logical_id uuid;
  v_preference public.employee_preferences%rowtype;
  v_constraint public.employee_time_constraints_v2%rowtype;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select employee.id into v_employee_id
  from public.employees employee
  where employee.auth_user_id=v_actor and employee.active
    and employee.archived_at is null
  order by employee.created_at limit 1;
  if v_employee_id is null then raise exception 'EMPLOYEE_PROFILE_REQUIRED'; end if;
  if p_from is null or p_to is null or p_to<p_from or p_to-p_from>62 then
    raise exception 'INVALID_DATE_RANGE';
  end if;
  if v_kind not in ('AVAILABLE','PREFER_NOT_TO_WORK','CANNOT_WORK') then
    raise exception 'INVALID_AVAILABILITY_KIND';
  end if;
  if not coalesce(p_all_day,false)
    and (p_local_start is null or p_local_end is null or p_local_end=p_local_start) then
    raise exception 'HOURS_REQUIRED';
  end if;

  select nullif(version.settings->>'timezone','') into v_timezone
  from public.matrix_versions version
  where version.status in ('ACTIVE','DRAFT')
    and (version.effective_from is null or version.effective_from<=p_to)
    and (version.effective_to is null or version.effective_to>=p_from)
  order by (version.status='ACTIVE') desc,version.version desc limit 1;
  if v_timezone is null then raise exception 'MATRIX_TIMEZONE_REQUIRED'; end if;

  if p_preferred_location_id is not null then
    select location.logical_id into v_location_logical_id
    from public.matrix_locations_v2 location
    join public.matrix_versions version on version.id=location.matrix_version_id
    where location.id=p_preferred_location_id and location.active
      and version.status in ('ACTIVE','DRAFT')
    order by (version.status='ACTIVE') desc,version.version desc limit 1;
    if v_location_logical_id is null then
      raise exception 'PREFERRED_LOCATION_NOT_FOUND';
    end if;
  end if;

  for v_day in select generate_series(p_from,p_to,interval '1 day')::date loop
    v_start := v_day::timestamp at time zone v_timezone;
    v_end := (v_day+1)::timestamp at time zone v_timezone;

    -- A day has one employee-controlled effective state. Protected HR/manager
    -- entries are deliberately excluded and remain authoritative.
    for v_preference in
      select preference.* from public.employee_preferences preference
      where preference.employee_id=v_employee_id
        and preference.status='ACTIVE'
        and preference.source='GRAFIK_PRO'
        and preference.editable_by_employee
        and preference.preference_type in ('OTHER','PREFERRED_LOCATION')
        and preference.valid_from<=v_day and preference.valid_to>=v_day
      for update
    loop
      update public.employee_preferences set status='CANCELLED'
      where id=v_preference.id;
      if v_preference.valid_from<v_day then
        insert into public.employee_preferences(
          employee_id,valid_from,valid_to,preference_type,preference_value,
          source,editable_by_employee,status
        ) values(
          v_preference.employee_id,v_preference.valid_from,v_day-1,
          v_preference.preference_type,v_preference.preference_value,
          v_preference.source,v_preference.editable_by_employee,'ACTIVE'
        );
      end if;
      if v_preference.valid_to>v_day then
        insert into public.employee_preferences(
          employee_id,valid_from,valid_to,preference_type,preference_value,
          source,editable_by_employee,status
        ) values(
          v_preference.employee_id,v_day+1,v_preference.valid_to,
          v_preference.preference_type,v_preference.preference_value,
          v_preference.source,v_preference.editable_by_employee,'ACTIVE'
        );
      end if;
    end loop;

    for v_constraint in
      select constraint_row.* from public.employee_time_constraints_v2 constraint_row
      where constraint_row.employee_id=v_employee_id
        and constraint_row.status='ACTIVE'
        and constraint_row.source='GRAFIK_PRO'
        and constraint_row.editable_by_employee
        and constraint_row.time_range && tstzrange(v_start,v_end,'[)')
      for update
    loop
      update public.employee_time_constraints_v2
      set status='REVOKED',revoked_at=now(),updated_at=now()
      where id=v_constraint.id;
      if lower(v_constraint.time_range)<v_start then
        insert into public.employee_time_constraints_v2(
          employee_id,constraint_kind,time_range,location_logical_id,source,
          source_record_key,priority,editable_by_employee,status,note,created_by
        ) values(
          v_employee_id,v_constraint.constraint_kind,
          tstzrange(lower(v_constraint.time_range),v_start,'[)'),
          v_constraint.location_logical_id,'GRAFIK_PRO',
          'self-split:left:'||gen_random_uuid()::text,v_constraint.priority,
          true,'ACTIVE',v_constraint.note,v_actor
        );
      end if;
      if upper(v_constraint.time_range)>v_end then
        insert into public.employee_time_constraints_v2(
          employee_id,constraint_kind,time_range,location_logical_id,source,
          source_record_key,priority,editable_by_employee,status,note,created_by
        ) values(
          v_employee_id,v_constraint.constraint_kind,
          tstzrange(v_end,upper(v_constraint.time_range),'[)'),
          v_constraint.location_logical_id,'GRAFIK_PRO',
          'self-split:right:'||gen_random_uuid()::text,v_constraint.priority,
          true,'ACTIVE',v_constraint.note,v_actor
        );
      end if;
    end loop;

    -- An all-day AVAILABLE entry without metadata is the baseline state and
    -- therefore needs no row. This keeps the calendar and solver consistent:
    -- green by default, with only exceptions persisted.
    if v_kind='PREFER_NOT_TO_WORK' then
      insert into public.employee_preferences(
        employee_id,valid_from,valid_to,preference_type,preference_value,
        source,editable_by_employee,status
      ) values(
        v_employee_id,v_day,v_day,'OTHER',jsonb_strip_nulls(jsonb_build_object(
          'kind','DAY_OFF','strength','SOFT','note',nullif(trim(p_note),''))),
        'GRAFIK_PRO',true,'ACTIVE'
      );
    elsif v_kind='CANNOT_WORK' or not coalesce(p_all_day,false) then
      if not coalesce(p_all_day,false) then
        v_start := (v_day+p_local_start)::timestamp at time zone v_timezone;
        v_end := case when p_local_end>p_local_start
          then (v_day+p_local_end)::timestamp at time zone v_timezone
          else (v_day+1+p_local_end)::timestamp at time zone v_timezone end;
      end if;
      v_source_key := 'self-day:'||v_employee_id::text||':'||v_kind||':'
        ||v_start::text||':'||v_end::text;
      insert into public.employee_time_constraints_v2(
        employee_id,constraint_kind,time_range,location_logical_id,source,
        source_record_key,priority,editable_by_employee,status,note,created_by
      ) values(
        v_employee_id,
        case when v_kind='AVAILABLE' then 'AVAILABLE_WINDOW' else 'UNAVAILABLE' end,
        tstzrange(v_start,v_end,'[)'),v_location_logical_id,'GRAFIK_PRO',
        v_source_key,100,true,'ACTIVE',nullif(trim(p_note),''),v_actor
      ) on conflict (source,source_record_key)
        where source_record_key is not null
        do update set status='ACTIVE',revoked_at=null,updated_at=now(),
          note=excluded.note,location_logical_id=excluded.location_logical_id;
    end if;

    if p_preferred_location_id is not null then
      insert into public.employee_preferences(
        employee_id,valid_from,valid_to,preference_type,preference_value,
        source,editable_by_employee,status
      ) values(
        v_employee_id,v_day,v_day,'PREFERRED_LOCATION',
        jsonb_build_object('locationId',p_preferred_location_id),
        'GRAFIK_PRO',true,'ACTIVE'
      );
    end if;
    v_count := v_count+1;
  end loop;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'employee_availability_v2',v_employee_id::text,'SET_DAYS',
    jsonb_build_object('from',p_from,'to',p_to,'kind',v_kind,
      'allDay',p_all_day,'days',v_count,
      'preferredLocationId',p_preferred_location_id));
  return jsonb_build_object('employeeId',v_employee_id,'savedDays',v_count,
    'kind',v_kind);
end;
$$;


ALTER FUNCTION "public"."employee_availability_bulk_save_v2"("p_from" "date", "p_to" "date", "p_kind" "text", "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone, "p_preferred_location_id" "uuid", "p_note" "text") OWNER TO "postgres";

--
-- Name: employee_availability_days_save_uat_v3("date"[], "text", boolean, time without time zone, time without time zone, "uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."employee_availability_days_save_uat_v3"("p_dates" "date"[], "p_kind" "text", "p_all_day" boolean DEFAULT true, "p_local_start" time without time zone DEFAULT NULL::time without time zone, "p_local_end" time without time zone DEFAULT NULL::time without time zone, "p_preferred_location_id" "uuid" DEFAULT NULL::"uuid", "p_note" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid(); v_employee uuid; v_day date; v_kind text;
  v_matrix uuid; v_timezone text; v_role uuid; v_event uuid; v_limit integer;
  v_current integer; v_pending integer:=0; v_saved integer:=0;
  v_start timestamptz; v_end timestamptz; v_result jsonb;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  v_kind:=upper(trim(coalesce(p_kind,'')));
  if v_kind not in ('AVAILABLE','PREFER_NOT_TO_WORK','CANNOT_WORK')
    then raise exception 'INVALID_AVAILABILITY_KIND'; end if;
  if coalesce(cardinality(p_dates),0)=0 or cardinality(p_dates)>63
    then raise exception 'INVALID_DATE_SELECTION'; end if;
  select employee.id into v_employee from public.employees employee
  where employee.auth_user_id=v_actor and employee.active
    and employee.archived_at is null order by employee.created_at limit 1;
  if v_employee is null then raise exception 'EMPLOYEE_PROFILE_REQUIRED'; end if;

  foreach v_day in array p_dates loop
    if v_day<current_date then raise exception 'AVAILABILITY_DATE_IN_PAST'; end if;
    select matrix.id,coalesce(matrix.settings->>'timezone','Europe/Warsaw')
    into v_matrix,v_timezone from public.matrix_versions matrix
    where matrix.status='ACTIVE' and matrix.schema_version>=2
      and matrix.effective_from<=v_day
      and (matrix.effective_to is null or matrix.effective_to>=v_day)
    order by matrix.effective_from desc,matrix.version desc limit 1;
    if v_matrix is null then raise exception 'MATRIX_V2_FOR_MONTH_NOT_FOUND'; end if;

    -- Selecting green/soft cancels a pending hard request for that day first.
    if v_kind<>'CANNOT_WORK' then
      update public.availability_exception_reviews_v2 set status='CANCELLED',
        reviewed_by=v_actor,reviewed_at=now(),review_reason='Zmiana przez pracownika'
      where employee_id=v_employee and work_date=v_day and status='PENDING';
    end if;

    v_role:=null; v_event:=null; v_limit:=null;
    if v_kind='CANNOT_WORK' then
      select role_grant.role_id,event.id,hot.maximum_hard_unavailable
      into v_role,v_event,v_limit
      from public.matrix_employee_roles_v2 role_grant
      join public.workforce_hot_day_limits_v2 hot
        on hot.matrix_version_id=role_grant.matrix_version_id
        and hot.role_id=role_grant.role_id
      join public.workforce_calendar_events_v2 event on event.id=hot.event_id
        and event.status='ACTIVE' and event.event_kind='HOT_DAY'
        and event.event_date=v_day
      where role_grant.matrix_version_id=v_matrix
        and role_grant.employee_id=v_employee and role_grant.active
        and (role_grant.valid_from is null or role_grant.valid_from<=v_day)
        and (role_grant.valid_to is null or role_grant.valid_to>=v_day)
      order by role_grant.is_primary desc,hot.maximum_hard_unavailable limit 1;
    end if;
    if v_event is not null then
      select count(distinct constraint_row.employee_id)::integer into v_current
      from public.employee_time_constraints_v2 constraint_row
      join public.matrix_employee_roles_v2 role_grant
        on role_grant.matrix_version_id=v_matrix
        and role_grant.employee_id=constraint_row.employee_id
        and role_grant.role_id=v_role and role_grant.active
      where constraint_row.status='ACTIVE'
        and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
        and constraint_row.time_range && tstzrange(
          v_day::timestamp at time zone v_timezone,
          (v_day+1)::timestamp at time zone v_timezone,'[)');
      if coalesce(v_current,0)>=v_limit then
        v_start:=case when coalesce(p_all_day,true)
          then v_day::timestamp at time zone v_timezone
          else (v_day+p_local_start)::timestamp at time zone v_timezone end;
        v_end:=case when coalesce(p_all_day,true)
          then (v_day+1)::timestamp at time zone v_timezone
          when p_local_end>p_local_start
            then (v_day+p_local_end)::timestamp at time zone v_timezone
          else (v_day+1+p_local_end)::timestamp at time zone v_timezone end;
        insert into public.availability_exception_reviews_v2(
          employee_id,matrix_version_id,hot_day_event_id,role_id,work_date,
          requested_range,note,requested_by
        ) values(v_employee,v_matrix,v_event,v_role,v_day,
          tstzrange(v_start,v_end,'[)'),nullif(trim(p_note),''),v_actor)
        on conflict(employee_id,work_date,role_id) where status='PENDING'
        do update set requested_range=excluded.requested_range,note=excluded.note,
          requested_at=now();
        v_pending:=v_pending+1;
        insert into public.notifications(recipient_id,title,body)
        select distinct recipient.auth_user_id,'HOT DAY: prośba o niedostępność',
          'Pracownik zgłosił twardą niedostępność na '||v_day::text||
          '. Limit dla roli został osiągnięty.'
        from (
          select grant_row.auth_user_id from public.matrix_scope_grants_v2 grant_row
          join public.matrix_roles_v2 role on role.logical_id=grant_row.role_logical_id
          where grant_row.active and grant_row.app_role='ROLE_MANAGER'
            and role.id=v_role
          union
          select permission.auth_user_id from public.user_permissions permission
          where permission.app_role in ('OWNER','ADMIN')
        ) recipient
        where recipient.auth_user_id is not null;
        continue;
      end if;
    end if;
    v_result:=public.employee_availability_bulk_save_v2(
      v_day,v_day,v_kind,p_all_day,p_local_start,p_local_end,
      p_preferred_location_id,p_note);
    v_saved:=v_saved+coalesce((v_result->>'savedDays')::integer,0);
  end loop;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'employee_availability_v2',v_employee::text,'SET_DAYS_REVIEW_AWARE',
    jsonb_build_object('dates',to_jsonb(p_dates),'kind',v_kind,
      'savedDays',v_saved,'pendingReviewDays',v_pending));
  return jsonb_build_object('employeeId',v_employee,'savedDays',v_saved,
    'pendingReviewDays',v_pending,'kind',v_kind);
end;
$$;


ALTER FUNCTION "public"."employee_availability_days_save_uat_v3"("p_dates" "date"[], "p_kind" "text", "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone, "p_preferred_location_id" "uuid", "p_note" "text") OWNER TO "postgres";

--
-- Name: employee_availability_publication_conflicts_uat_v1("uuid", "date"[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."employee_availability_publication_conflicts_uat_v1"("p_employee_id" "uuid", "p_dates" "date"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_actor uuid:=auth.uid();
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.employees employee
      where employee.id=p_employee_id and employee.auth_user_id=v_actor)
     and not exists(select 1 from public.user_permissions permission
      where permission.auth_user_id=v_actor and permission.app_role in ('OWNER','ADMIN')) then
    perform solver_private.assert_uat_master_persona_v2();
  end if;
  return coalesce((
    select jsonb_agg(distinct jsonb_build_object(
      'scheduleId',schedule.id,'scheduleName',schedule.name,
      'publishedAt',schedule.published_at,'date',shift.shift_date,
      'shiftName',template.name,'locationName',location.name,'roleName',role.name,
      'startsAt',shift.starts_at,'endsAt',shift.ends_at
    ))
    from public.published_role_schedules_v2 schedule
    join public.plan_assignments_v2 assignment on assignment.variant_id=schedule.variant_id and assignment.employee_id=p_employee_id
    join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
    join public.matrix_shift_templates_v2 template on template.id=shift.shift_template_id
    join public.matrix_locations_v2 location on location.id=shift.location_id
    join public.matrix_roles_v2 role on role.id=assignment.role_id
    where schedule.status='PUBLISHED' and shift.shift_date=any(p_dates)
  ),'[]'::jsonb);
end;
$$;


ALTER FUNCTION "public"."employee_availability_publication_conflicts_uat_v1"("p_employee_id" "uuid", "p_dates" "date"[]) OWNER TO "postgres";

--
-- Name: employee_availability_publication_conflicts_uat_v2("uuid", "date"[], boolean, time without time zone, time without time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."employee_availability_publication_conflicts_uat_v2"("p_employee_id" "uuid", "p_dates" "date"[], "p_all_day" boolean DEFAULT true, "p_local_start" time without time zone DEFAULT NULL::time without time zone, "p_local_end" time without time zone DEFAULT NULL::time without time zone) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_actor uuid:=auth.uid();
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if coalesce(cardinality(p_dates),0)=0 then raise exception 'INVALID_DATE_SELECTION'; end if;
  if not coalesce(p_all_day,true) and (
    p_local_start is null or p_local_end is null or p_local_start=p_local_end
  ) then raise exception 'INVALID_LOCAL_TIME_RANGE'; end if;
  if not exists(select 1 from public.employees employee
      where employee.id=p_employee_id and employee.auth_user_id=v_actor)
     and not exists(select 1 from public.user_permissions permission
      where permission.auth_user_id=v_actor and permission.app_role in ('OWNER','ADMIN')) then
    perform solver_private.assert_uat_master_persona_v2();
  end if;
  return coalesce((
    select jsonb_agg(distinct jsonb_build_object(
      'scheduleId',schedule.id,'scheduleName',schedule.name,
      'publishedAt',schedule.published_at,'date',shift.shift_date,
      'shiftName',template.name,'locationName',location.name,'roleName',role.name,
      'startsAt',shift.starts_at,'endsAt',shift.ends_at
    ))
    from public.published_role_schedules_v2 schedule
    join public.plan_assignments_v2 assignment on assignment.variant_id=schedule.variant_id
      and assignment.employee_id=p_employee_id
    join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
    join public.matrix_shift_templates_v2 template on template.id=shift.shift_template_id
    join public.matrix_locations_v2 location on location.id=shift.location_id
    join public.matrix_roles_v2 role on role.id=assignment.role_id
    where schedule.status='PUBLISHED' and shift.shift_date=any(p_dates)
      and (coalesce(p_all_day,true) or tstzrange(shift.starts_at,shift.ends_at,'[)') &&
        tstzrange(
          (shift.shift_date+p_local_start)::timestamp at time zone location.timezone,
          (shift.shift_date+p_local_end
            +case when p_local_end<=p_local_start then interval '1 day' else interval '0 day' end
          )::timestamp at time zone location.timezone,
          '[)'
        )
      )
  ),'[]'::jsonb);
end;
$$;


ALTER FUNCTION "public"."employee_availability_publication_conflicts_uat_v2"("p_employee_id" "uuid", "p_dates" "date"[], "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone) OWNER TO "postgres";

--
-- Name: employee_availability_save_month("date", "jsonb", boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."employee_availability_save_month"("p_month" "date", "p_entries" "jsonb", "p_default_remaining_available" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare e uuid; d date; item jsonb; saved integer:=0; defaulted integer:=0; begin
  select id into e from employees where auth_user_id=auth.uid() and active limit 1;
  if e is null then raise exception 'EMPLOYEE_ACCOUNT_NOT_LINKED'; end if;
  if date_trunc('month',p_month)::date<>p_month then raise exception 'MONTH_REQUIRED'; end if;
  for item in select value from jsonb_array_elements(coalesce(p_entries,'[]'::jsonb)) loop
    d:=(item->>'date')::date;
    if date_trunc('month',d)::date<>p_month then raise exception 'DATE_OUTSIDE_MONTH'; end if;
    insert into employee_availability(employee_id,work_date,available,note,source,updated_by,updated_at)
    values(e,d,(item->>'status')='AVAILABLE',nullif(item->>'note',''),'GRAFIK_PRO',auth.uid(),now())
    on conflict(employee_id,work_date) do update set available=excluded.available,note=excluded.note,
      source='GRAFIK_PRO',updated_by=auth.uid(),updated_at=now();
    saved:=saved+1;
  end loop;
  if p_default_remaining_available then
    insert into employee_availability(employee_id,work_date,available,source,updated_by,updated_at)
    select e,g::date,true,'GRAFIK_PRO',auth.uid(),now()
    from generate_series(p_month,(p_month+interval '1 month-1 day')::date,interval '1 day') g
    where not exists(select 1 from employee_availability a where a.employee_id=e and a.work_date=g::date)
    on conflict(employee_id,work_date) do nothing;
    get diagnostics defaulted=row_count;
  end if;
  return jsonb_build_object('saved',saved,'defaultedAvailable',defaulted);
end $$;


ALTER FUNCTION "public"."employee_availability_save_month"("p_month" "date", "p_entries" "jsonb", "p_default_remaining_available" boolean) OWNER TO "postgres";

--
-- Name: employee_pay_rate_save_v2("uuid", "uuid", "date", "date", bigint, "text", "text", boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."employee_pay_rate_save_v2"("p_id" "uuid", "p_employee_id" "uuid", "p_valid_from" "date", "p_valid_to" "date", "p_base_rate_minor" bigint, "p_currency" "text" DEFAULT NULL::"text", "p_contract_type" "text" DEFAULT NULL::"text", "p_active" boolean DEFAULT true) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_id uuid;
  v_currency text;
  v_employment_start date;
  v_employment_end date;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')
      or public.has_app_role('HR_FINANCE')) then
    raise exception 'FORBIDDEN';
  end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  if not exists(select 1 from public.employees e where e.id=p_employee_id) then
    raise exception 'EMPLOYEE_NOT_FOUND';
  end if;
  if p_valid_from is null or (p_valid_to is not null and p_valid_to<p_valid_from)
      or p_base_rate_minor is null or p_base_rate_minor<0 then
    raise exception 'INVALID_PAY_RATE';
  end if;
  if p_id is not null and not exists(
    select 1 from public.employee_pay_rates_v2 rate
    where rate.id=p_id and rate.employee_id=p_employee_id
  ) then raise exception 'PAY_RATE_NOT_FOUND'; end if;

  select profile.employment_start,profile.employment_end
  into v_employment_start,v_employment_end
  from public.matrix_employee_profiles_v2 profile
  join public.matrix_versions version on version.id=profile.matrix_version_id
  where profile.employee_id=p_employee_id
  order by (version.status='DRAFT') desc,version.version desc limit 1;
  if v_employment_start is not null and p_valid_from<v_employment_start then
    raise exception 'PAY_RATE_BEFORE_EMPLOYMENT';
  end if;
  if v_employment_end is not null
    and (p_valid_from>v_employment_end
      or p_valid_to is null or p_valid_to>v_employment_end) then
    raise exception 'PAY_RATE_OUTSIDE_EMPLOYMENT';
  end if;

  select upper(mv.settings->>'currency') into v_currency
  from public.matrix_versions mv
  where mv.status in ('DRAFT','ACTIVE') and mv.schema_version>=2
  order by (mv.status='DRAFT') desc,mv.version desc limit 1;
  v_currency:=coalesce(nullif(upper(trim(p_currency)),''),v_currency);
  if not public.matrix_v2_is_iso_4217_currency(v_currency) then
    raise exception 'INVALID_CURRENCY';
  end if;
  if coalesce(p_active,true) and exists(
    select 1 from public.employee_pay_rates_v2 x
    where x.employee_id=p_employee_id and x.active and x.id is distinct from p_id
      and daterange(x.valid_from,case when x.valid_to is null then null else x.valid_to+1 end,'[)')
        && daterange(p_valid_from,case when p_valid_to is null then null else p_valid_to+1 end,'[)')
  ) then raise exception 'OVERLAPPING_ACTIVE_PAY_RATE'; end if;

  if p_id is null then
    insert into public.employee_pay_rates_v2(
      employee_id,valid_from,valid_to,base_rate_minor,currency,contract_type,
      active,created_by,updated_by
    ) values(
      p_employee_id,p_valid_from,p_valid_to,p_base_rate_minor,v_currency,
      nullif(trim(p_contract_type),''),coalesce(p_active,true),auth.uid(),auth.uid()
    ) returning id into v_id;
  else
    update public.employee_pay_rates_v2 set employee_id=p_employee_id,
      valid_from=p_valid_from,valid_to=p_valid_to,base_rate_minor=p_base_rate_minor,
      currency=v_currency,contract_type=nullif(trim(p_contract_type),''),
      active=coalesce(p_active,true),updated_by=auth.uid(),updated_at=now()
    where id=p_id and employee_id=p_employee_id returning id into v_id;
    if v_id is null then raise exception 'PAY_RATE_NOT_FOUND'; end if;
  end if;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'employee_pay_rate_v2',v_id::text,'UPSERT',jsonb_build_object(
    'employeeId',p_employee_id,'validFrom',p_valid_from,'validTo',p_valid_to,
    'currency',v_currency,'active',coalesce(p_active,true)));
  return v_id;
end;
$$;


ALTER FUNCTION "public"."employee_pay_rate_save_v2"("p_id" "uuid", "p_employee_id" "uuid", "p_valid_from" "date", "p_valid_to" "date", "p_base_rate_minor" bigint, "p_currency" "text", "p_contract_type" "text", "p_active" boolean) OWNER TO "postgres";

--
-- Name: employee_portal_workspace("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."employee_portal_workspace"("p_month" "date" DEFAULT CURRENT_DATE) RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
with me as(select * from employees where auth_user_id=auth.uid() and active limit 1),
published as(select id from plans where month=date_trunc('month',p_month)::date and status='PUBLISHED' order by version desc limit 1)
select jsonb_build_object(
 'employee',(select jsonb_build_object('id',m.id,'employeeNo',m.employee_no,'firstName',m.first_name,'lastName',m.last_name,'primaryRole',m.primary_role,
   'locations',coalesce((select jsonb_agg(jsonb_build_object('code',l.code,'name',l.name)) from employee_locations el join locations l on l.id=el.location_id where el.employee_id=m.id and (el.standard_allowed or el.overtime_allowed or el.home_location)),'[]'::jsonb)) from me m),
 'preferences',coalesce((select jsonb_agg(to_jsonb(ep) order by ep.valid_from desc) from employee_preferences ep join me on me.id=ep.employee_id),'[]'::jsonb),
 'availability',coalesce((select jsonb_agg(jsonb_build_object('date',av.work_date,'status',case when av.available then 'AVAILABLE' else 'UNAVAILABLE' end,'source',av.source,'note',av.note) order by av.work_date) from employee_availability av join me on me.id=av.employee_id where date_trunc('month',av.work_date)::date=date_trunc('month',p_month)::date),'[]'::jsonb),
 'availabilityHistory',coalesce((select jsonb_agg(jsonb_build_object('date',h.work_date,'from',h.old_available,'to',h.new_available,'source',h.source,'changedAt',h.changed_at) order by h.changed_at desc) from employee_availability_history h join me on me.id=h.employee_id limit 100),'[]'::jsonb),
 'assignments',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'shiftId',s.id,'date',s.shift_date,'startsAt',s.starts_at,'endsAt',s.ends_at,'shiftCode',s.shift_code,'location',l.name,'locationCode',l.code,'role',a.assigned_role,'capability',a.assigned_capability,
   'coworkers',coalesce((select jsonb_agg(jsonb_build_object('name',ce.first_name||' '||ce.last_name,'role',ca.assigned_role,'capability',ca.assigned_capability) order by ce.last_name) from assignments ca join employees ce on ce.id=ca.employee_id where ca.shift_id=s.id and ca.employee_id<>a.employee_id),'[]'::jsonb)) order by s.starts_at)
   from assignments a join shifts s on s.id=a.shift_id join published p on p.id=s.plan_id join locations l on l.id=s.location_id join me on me.id=a.employee_id),'[]'::jsonb),
 'attendance',coalesce((select jsonb_agg(jsonb_build_object('id',ae.id,'action',ae.event_type,'occurredAt',ae.occurred_at,'location',l.name) order by ae.occurred_at desc)
   from attendance_events ae join locations l on l.id=ae.location_id join me on me.id=ae.employee_id where ae.occurred_at>=date_trunc('month',p_month)),'[]'::jsonb)
);
$$;


ALTER FUNCTION "public"."employee_portal_workspace"("p_month" "date") OWNER TO "postgres";

--
-- Name: employee_request_review_uat_v1("uuid", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."employee_request_review_uat_v1"("p_request_id" "uuid", "p_decision" "text", "p_reason" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid();
  v_request public.employee_requests_v1%rowtype;
  v_decision text:=upper(trim(coalesce(p_decision,'')));
  v_constraint uuid;
  v_status text;
  v_employee_user uuid;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into v_request from public.employee_requests_v1 request_row
  where request_row.id=p_request_id for update;
  if v_request.id is null then raise exception 'EMPLOYEE_REQUEST_NOT_FOUND'; end if;
  select employee.auth_user_id into v_employee_user from public.employees employee
  where employee.id=v_request.employee_id;
  if v_employee_user=v_actor or not public.matrix_v2_can_manage_employee(v_request.employee_id) then
    raise exception 'FORBIDDEN';
  end if;
  if v_request.request_type='SICKNESS' then
    if v_request.status<>'APPLIED' then raise exception 'REQUEST_ALREADY_RESOLVED'; end if;
    if v_decision<>'ACKNOWLEDGE' then raise exception 'SICKNESS_CANNOT_BE_REJECTED'; end if;
    v_status:='ACKNOWLEDGED';
  else
    if v_request.status<>'PENDING' then raise exception 'REQUEST_ALREADY_RESOLVED'; end if;
    if v_decision not in ('APPROVE','REJECT') then raise exception 'INVALID_REVIEW_DECISION'; end if;
    if v_decision='REJECT' and length(trim(coalesce(p_reason,'')))<3 then
      raise exception 'REVIEW_REASON_REQUIRED';
    end if;
    v_status:=case when v_decision='APPROVE' then 'APPROVED' else 'REJECTED' end;
    if v_request.request_type='LEAVE' and v_decision='APPROVE' then
      v_constraint:=gen_random_uuid();
      insert into public.employee_time_constraints_v2(
        id,employee_id,constraint_kind,time_range,source,source_record_key,
        priority,editable_by_employee,status,note,created_by
      ) values(v_constraint,v_request.employee_id,'LEAVE',v_request.requested_range,
        'EMPLOYEE_LEAVE_REQUEST','employee-request:'||v_request.id::text,500,false,
        'ACTIVE',v_request.note,v_actor);
    elsif v_request.request_type='HARD_UNAVAILABLE' then
      if v_request.legacy_review_id is null then raise exception 'HARD_REVIEW_NOT_FOUND'; end if;
      if v_decision='APPROVE' then
        v_constraint:=gen_random_uuid();
        insert into public.employee_time_constraints_v2(
          id,employee_id,constraint_kind,time_range,source,source_record_key,
          priority,editable_by_employee,status,note,created_by
        ) values(v_constraint,v_request.employee_id,'UNAVAILABLE',v_request.requested_range,
          'HOT_DAY_APPROVED','hot-day-review:'||v_request.legacy_review_id::text,100,false,
          'ACTIVE',v_request.note,v_actor);
      end if;
      update public.availability_exception_reviews_v2 set
        status=case when v_decision='APPROVE' then 'APPROVED' else 'REJECTED' end,
        reviewed_by=v_actor,reviewed_at=now(),review_reason=coalesce(nullif(trim(p_reason),''),'Decyzja lidera'),
        constraint_id=v_constraint
      where id=v_request.legacy_review_id and status='PENDING';
      if not found then raise exception 'HARD_REVIEW_ALREADY_RESOLVED'; end if;
    end if;
  end if;
  update public.employee_requests_v1 set status=v_status,reviewed_by=v_actor,
    reviewed_at=now(),review_reason=nullif(trim(p_reason),''),
    constraint_id=coalesce(v_constraint,constraint_id),updated_at=now()
  where id=v_request.id;
  update public.notifications set resolved_at=now(),resolution=v_status
  where context_type='EMPLOYEE_REQUEST'
    and context_id=v_request.id::text and resolved_at is null;
  if v_employee_user is not null then
    insert into public.notifications(
      recipient_id,title,body,kind,context_type,context_id,action_route,action_required
    ) values(v_employee_user,
      case when v_request.request_type='SICKNESS' then 'L4 przyjęte do wiadomości'
        else 'Decyzja dotycząca nieobecności' end,
      case when v_request.request_type='SICKNESS' then 'Lider potwierdził odbiór zgłoszenia L4.'
        when v_status='APPROVED' then 'Twoja nieobecność została zaakceptowana.'
        else 'Twoja prośba nie została zaakceptowana: '||coalesce(nullif(trim(p_reason),''),'bez dodatkowego uzasadnienia') end,
      'DECISION','EMPLOYEE_REQUEST',v_request.id::text,
      '/my-schedule?month='||to_char(v_request.date_from,'YYYY-MM'),false);
  end if;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'employee_request_v1',v_request.id::text,v_decision,jsonb_build_object(
    'employeeId',v_request.employee_id,'requestType',v_request.request_type,
    'status',v_status,'reason',nullif(trim(p_reason),''),'constraintId',v_constraint));
  return jsonb_build_object('id',v_request.id,'status',v_status,'constraintId',v_constraint);
end;
$$;


ALTER FUNCTION "public"."employee_request_review_uat_v1"("p_request_id" "uuid", "p_decision" "text", "p_reason" "text") OWNER TO "postgres";

--
-- Name: employee_request_submit_uat_v1("text", "date"[], boolean, time without time zone, time without time zone, "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."employee_request_submit_uat_v1"("p_request_type" "text", "p_dates" "date"[], "p_all_day" boolean DEFAULT true, "p_local_start" time without time zone DEFAULT NULL::time without time zone, "p_local_end" time without time zone DEFAULT NULL::time without time zone, "p_note" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid();
  v_employee uuid;
  v_type text:=upper(trim(coalesce(p_request_type,'')));
  v_first date;
  v_last date;
  v_day date;
  v_timezone text;
  v_start timestamptz;
  v_end timestamptz;
  v_id uuid;
  v_constraint uuid;
  v_legacy uuid;
  v_result jsonb;
  v_saved integer:=0;
  v_pending integer:=0;
  v_request_ids jsonb:='[]'::jsonb;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if v_type not in ('LEAVE','SICKNESS','HARD_UNAVAILABLE') then
    raise exception 'INVALID_EMPLOYEE_REQUEST_TYPE';
  end if;
  if coalesce(cardinality(p_dates),0)=0 or cardinality(p_dates)>63 then
    raise exception 'INVALID_DATE_SELECTION';
  end if;
  select min(day_value),max(day_value) into v_first,v_last
  from unnest(p_dates) day_value;
  if (select count(distinct day_value) from unnest(p_dates) day_value)<>cardinality(p_dates) then
    raise exception 'DUPLICATE_DATES';
  end if;
  if v_type in ('LEAVE','HARD_UNAVAILABLE') and v_first<current_date then
    raise exception 'ABSENCE_DATE_IN_PAST';
  end if;
  if v_type in ('LEAVE','SICKNESS') and cardinality(p_dates)<>(v_last-v_first+1) then
    raise exception 'REQUEST_RANGE_MUST_BE_CONTIGUOUS';
  end if;
  if not coalesce(p_all_day,true) and (
    p_local_start is null or p_local_end is null or p_local_start=p_local_end
  ) then raise exception 'INVALID_LOCAL_TIME_RANGE'; end if;
  select employee.id into v_employee from public.employees employee
  where employee.auth_user_id=v_actor and employee.active
    and employee.archived_at is null order by employee.created_at limit 1;
  if v_employee is null then raise exception 'EMPLOYEE_PROFILE_REQUIRED'; end if;

  if v_type in ('LEAVE','SICKNESS') then
    select coalesce(matrix_row.settings->>'timezone','Europe/Warsaw') into v_timezone
    from public.matrix_versions matrix_row
    where matrix_row.status='ACTIVE' and matrix_row.schema_version>=2
      and matrix_row.effective_from<=v_first
      and (matrix_row.effective_to is null or matrix_row.effective_to>=v_first)
    order by matrix_row.effective_from desc,matrix_row.version desc limit 1;
    if v_timezone is null then raise exception 'MATRIX_V2_FOR_MONTH_NOT_FOUND'; end if;
    v_start:=case when coalesce(p_all_day,true)
      then v_first::timestamp at time zone v_timezone
      else (v_first+p_local_start)::timestamp at time zone v_timezone end;
    v_end:=case when coalesce(p_all_day,true)
      then (v_last+1)::timestamp at time zone v_timezone
      when p_local_end>p_local_start
        then (v_last+p_local_end)::timestamp at time zone v_timezone
      else (v_last+1+p_local_end)::timestamp at time zone v_timezone end;
    v_id:=gen_random_uuid();
    if v_type='SICKNESS' then
      v_constraint:=gen_random_uuid();
      insert into public.employee_time_constraints_v2(
        id,employee_id,constraint_kind,time_range,source,source_record_key,
        priority,editable_by_employee,status,note,created_by
      ) values(v_constraint,v_employee,'SICKNESS',tstzrange(v_start,v_end,'[)'),
        'EMPLOYEE_SICKNESS','employee-request:'||v_id::text,500,false,'ACTIVE',
        nullif(trim(p_note),''),v_actor);
    end if;
    insert into public.employee_requests_v1(
      id,employee_id,requested_by,request_type,date_from,date_to,requested_range,
      status,requires_decision,note,constraint_id
    ) values(v_id,v_employee,v_actor,v_type,v_first,v_last,tstzrange(v_start,v_end,'[)'),
      case when v_type='LEAVE' then 'PENDING' else 'APPLIED' end,true,
      nullif(trim(p_note),''),v_constraint);
    insert into public.notifications(
      recipient_id,title,body,kind,context_type,context_id,action_route,action_required
    ) select recipient.auth_user_id,
      case when v_type='LEAVE' then 'Nowy wniosek urlopowy' else 'Zgłoszone L4' end,
      case when v_type='LEAVE'
        then 'Pracownik prosi o urlop '||v_first::text||'–'||v_last::text||'. Otwórz sprawę i podejmij decyzję.'
        else 'Pracownik zgłosił L4 '||v_first::text||'–'||v_last::text||'. Nie można go odrzucić — potwierdź odbiór i zorganizuj zastępstwo.' end,
      'ACTION_REQUIRED','EMPLOYEE_REQUEST',v_id::text,'/profile?tab=inbox',true
    from public.personal_request_manager_recipients_uat_v1(v_employee) recipient;
    v_request_ids:=jsonb_build_array(v_id);
    v_saved:=1;
  else
    foreach v_day in array p_dates loop
      v_result:=public.employee_availability_days_save_uat_v3(
        array[v_day],'CANNOT_WORK',p_all_day,p_local_start,p_local_end,null,p_note);
      select coalesce(matrix_row.settings->>'timezone','Europe/Warsaw') into v_timezone
      from public.matrix_versions matrix_row
      where matrix_row.status='ACTIVE' and matrix_row.schema_version>=2
        and matrix_row.effective_from<=v_day
        and (matrix_row.effective_to is null or matrix_row.effective_to>=v_day)
      order by matrix_row.effective_from desc,matrix_row.version desc limit 1;
      v_start:=case when coalesce(p_all_day,true)
        then v_day::timestamp at time zone v_timezone
        else (v_day+p_local_start)::timestamp at time zone v_timezone end;
      v_end:=case when coalesce(p_all_day,true)
        then (v_day+1)::timestamp at time zone v_timezone
        when p_local_end>p_local_start
          then (v_day+p_local_end)::timestamp at time zone v_timezone
        else (v_day+1+p_local_end)::timestamp at time zone v_timezone end;
      v_id:=gen_random_uuid();v_constraint:=null;v_legacy:=null;
      if coalesce((v_result->>'pendingReviewDays')::integer,0)>0 then
        select review.id into v_legacy from public.availability_exception_reviews_v2 review
        where review.employee_id=v_employee and review.work_date=v_day
          and review.status='PENDING' order by review.requested_at desc limit 1;
      else
        select constraint_row.id into v_constraint
        from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=v_employee and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind='UNAVAILABLE'
          and constraint_row.source='GRAFIK_PRO'
          and constraint_row.time_range && tstzrange(v_start,v_end,'[)')
        order by constraint_row.created_at desc limit 1;
      end if;
      insert into public.employee_requests_v1(
        id,employee_id,requested_by,request_type,date_from,date_to,requested_range,
        status,requires_decision,note,constraint_id,legacy_review_id
      ) values(v_id,v_employee,v_actor,v_type,v_day,v_day,tstzrange(v_start,v_end,'[)'),
        case when v_legacy is null then 'AUTO_APPLIED' else 'PENDING' end,
        v_legacy is not null,nullif(trim(p_note),''),v_constraint,v_legacy);
      if v_legacy is not null then
        delete from public.notifications notification
        where notification.title='HOT DAY: prośba o niedostępność'
          and notification.body='Pracownik zgłosił twardą niedostępność na '||v_day::text||'. Limit dla roli został osiągnięty.'
          and notification.created_at>=transaction_timestamp();
        insert into public.notifications(
          recipient_id,title,body,kind,context_type,context_id,action_route,action_required
        ) select recipient.auth_user_id,'Limit nieobecności przekroczony',
          'Twarda nieobecność na '||v_day::text||' przekracza limit. Otwórz sprawę i podejmij decyzję.',
          'ACTION_REQUIRED','EMPLOYEE_REQUEST',v_id::text,'/profile?tab=inbox',true
        from public.personal_request_manager_recipients_uat_v1(v_employee) recipient;
        v_pending:=v_pending+1;
      else
        v_saved:=v_saved+1;
      end if;
      v_request_ids:=v_request_ids||jsonb_build_array(v_id);
    end loop;
  end if;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'employee_request_v1',v_employee::text,'SUBMIT',jsonb_build_object(
    'requestType',v_type,'dates',to_jsonb(p_dates),'requestIds',v_request_ids,
    'saved',v_saved,'pending',v_pending));
  return jsonb_build_object('requestType',v_type,'requestIds',v_request_ids,
    'saved',v_saved,'pending',v_pending);
end;
$$;


ALTER FUNCTION "public"."employee_request_submit_uat_v1"("p_request_type" "text", "p_dates" "date"[], "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone, "p_note" "text") OWNER TO "postgres";

--
-- Name: employee_request_submit_uat_v2("text", "date"[], boolean, time without time zone, time without time zone, "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."employee_request_submit_uat_v2"("p_request_type" "text", "p_dates" "date"[], "p_all_day" boolean DEFAULT true, "p_local_start" time without time zone DEFAULT NULL::time without time zone, "p_local_end" time without time zone DEFAULT NULL::time without time zone, "p_note" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_day date;
  v_result jsonb;
  v_request_ids jsonb:='[]'::jsonb;
  v_saved integer:=0;
  v_pending integer:=0;
begin
  if coalesce(cardinality(p_dates),0)=0 or cardinality(p_dates)>63 then
    raise exception 'INVALID_DATE_SELECTION';
  end if;
  if coalesce(p_all_day,true) or cardinality(p_dates)=1
    or upper(trim(coalesce(p_request_type,'')))='HARD_UNAVAILABLE' then
    return public.employee_request_submit_uat_v1(
      p_request_type,p_dates,p_all_day,p_local_start,p_local_end,p_note
    );
  end if;
  foreach v_day in array p_dates loop
    v_result:=public.employee_request_submit_uat_v1(
      p_request_type,array[v_day],false,p_local_start,p_local_end,p_note
    );
    v_request_ids:=v_request_ids||coalesce(v_result->'requestIds','[]'::jsonb);
    v_saved:=v_saved+coalesce((v_result->>'saved')::integer,0);
    v_pending:=v_pending+coalesce((v_result->>'pending')::integer,0);
  end loop;
  return jsonb_build_object(
    'requestType',upper(trim(coalesce(p_request_type,''))),
    'requestIds',v_request_ids,'saved',v_saved,'pending',v_pending
  );
end;
$$;


ALTER FUNCTION "public"."employee_request_submit_uat_v2"("p_request_type" "text", "p_dates" "date"[], "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone, "p_note" "text") OWNER TO "postgres";

--
-- Name: employee_restore("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."employee_restore"("p_employee_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$ begin
 if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE')) then raise exception 'FORBIDDEN'; end if;
 update employees set active=true,archived_at=null,archived_by=null,archive_reason=null,employment_end=null where id=p_employee_id;
 if not found then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
 insert into audit_log(actor_id,entity_type,entity_id,action) values(auth.uid(),'employee',p_employee_id::text,'RESTORE');
end $$;


ALTER FUNCTION "public"."employee_restore"("p_employee_id" "uuid") OWNER TO "postgres";

--
-- Name: employee_shift_preferences_save_self_v2("date", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."employee_shift_preferences_save_self_v2"("p_month" "date", "p_preferences" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_employee uuid;
  v_month date:=date_trunc('month',p_month)::date;
  v_period text;
  v_level text;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_month is null or jsonb_typeof(p_preferences)<>'object' then
    raise exception 'INVALID_SHIFT_PERIOD_PREFERENCES';
  end if;
  select employee.id into v_employee from public.employees employee
  where employee.auth_user_id=auth.uid() and employee.active
    and employee.archived_at is null order by employee.id limit 1 for update;
  if v_employee is null then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  update public.employee_preferences preference set status='CANCELLED'
  where preference.employee_id=v_employee and preference.status='ACTIVE'
    and preference.source='GRAFIK_PRO'
    and preference.preference_type='PREFERRED_SHIFT'
    and preference.valid_from<v_month+interval '1 month'
    and preference.valid_to>=v_month;
  foreach v_period in array array['MORNING','MIDDLE','EVENING'] loop
    v_level:=upper(coalesce(p_preferences->>v_period,'NEUTRAL'));
    if v_level not in ('PREFERRED','NEUTRAL','AVOIDED') then
      raise exception 'INVALID_EMPLOYEE_SHIFT_PREFERENCE_LEVEL';
    end if;
    insert into public.employee_preferences(
      employee_id,valid_from,valid_to,preference_type,preference_value,
      source,editable_by_employee,status
    ) values(
      v_employee,v_month,(v_month+interval '1 month - 1 day')::date,
      'PREFERRED_SHIFT',jsonb_build_object('period',v_period,'level',v_level),
      'GRAFIK_PRO',true,'ACTIVE'
    );
  end loop;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'employee_shift_preferences_v2',v_employee::text,'UPSERT',
    jsonb_build_object('month',v_month,'preferences',p_preferences));
  return jsonb_build_object('saved',3,'month',v_month);
end;
$$;


ALTER FUNCTION "public"."employee_shift_preferences_save_self_v2"("p_month" "date", "p_preferences" "jsonb") OWNER TO "postgres";

--
-- Name: FUNCTION "employee_shift_preferences_save_self_v2"("p_month" "date", "p_preferences" "jsonb"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."employee_shift_preferences_save_self_v2"("p_month" "date", "p_preferences" "jsonb") IS 'Employee self-service preference for morning, middle and evening; manager Matrix rows remain authoritative.';


--
-- Name: employee_shift_preferences_self_v2("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."employee_shift_preferences_self_v2"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_employee uuid;
  v_matrix uuid;
  v_month date:=date_trunc('month',p_month)::date;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  select employee.id into v_employee from public.employees employee
  where employee.auth_user_id=auth.uid() and employee.active
    and employee.archived_at is null order by employee.id limit 1;
  if v_employee is null then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  select matrix.id into v_matrix from public.matrix_versions matrix
  where matrix.status in ('ACTIVE','ARCHIVED') and matrix.schema_version>=2
    and solver_private.matrix_covers_planning_month_uat_v1(matrix.effective_from,v_month)
  order by matrix.effective_from desc,matrix.version desc limit 1;
  if v_matrix is null then raise exception 'MATRIX_V2_FOR_MONTH_NOT_FOUND'; end if;
  return jsonb_build_object(
    'employeeId',v_employee,'month',v_month,
    'employee',jsonb_build_object(
      'MORNING',coalesce((select upper(p.preference_value->>'level')
        from public.employee_preferences p where p.employee_id=v_employee
          and p.status='ACTIVE' and p.source='GRAFIK_PRO'
          and p.preference_type='PREFERRED_SHIFT'
          and upper(p.preference_value->>'period')='MORNING'
          and p.valid_from<v_month+interval '1 month' and p.valid_to>=v_month
        order by p.created_at desc limit 1),'NEUTRAL'),
      'MIDDLE',coalesce((select upper(p.preference_value->>'level')
        from public.employee_preferences p where p.employee_id=v_employee
          and p.status='ACTIVE' and p.source='GRAFIK_PRO'
          and p.preference_type='PREFERRED_SHIFT'
          and upper(p.preference_value->>'period')='MIDDLE'
          and p.valid_from<v_month+interval '1 month' and p.valid_to>=v_month
        order by p.created_at desc limit 1),'NEUTRAL'),
      'EVENING',coalesce((select upper(p.preference_value->>'level')
        from public.employee_preferences p where p.employee_id=v_employee
          and p.status='ACTIVE' and p.source='GRAFIK_PRO'
          and p.preference_type='PREFERRED_SHIFT'
          and upper(p.preference_value->>'period')='EVENING'
          and p.valid_from<v_month+interval '1 month' and p.valid_to>=v_month
        order by p.created_at desc limit 1),'NEUTRAL')
    ),
    'effective',coalesce(solver_private.alpha16_shift_rules_v2(
      v_employee,v_matrix,v_month
    )->'periods','{}'::jsonb),
    'managerOverrides',coalesce((select jsonb_object_agg(
      upper(p.preference_value->>'period'),upper(p.preference_value->>'level')
    ) from public.employee_preferences p
      where p.employee_id=v_employee and p.status='ACTIVE'
        and p.source='MANAGER' and p.preference_type='PREFERRED_SHIFT'
        and p.preference_value->>'matrixVersionId'=v_matrix::text
        and p.valid_from<v_month+interval '1 month' and p.valid_to>=v_month
    ),'{}'::jsonb)
  );
end;
$$;


ALTER FUNCTION "public"."employee_shift_preferences_self_v2"("p_month" "date") OWNER TO "postgres";

--
-- Name: employee_time_constraint_revoke_v2("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."employee_time_constraint_revoke_v2"("p_id" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_row public.employee_time_constraints_v2%rowtype;
  v_self boolean;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into v_row from public.employee_time_constraints_v2 x
  where x.id=p_id for update;
  if v_row.id is null then raise exception 'TIME_CONSTRAINT_NOT_FOUND'; end if;
  if v_row.status<>'ACTIVE' then return v_row.id; end if;
  if not public.matrix_v2_can_manage_employee(v_row.employee_id) then
    raise exception 'FORBIDDEN';
  end if;
  select exists(select 1 from public.employees e
    where e.id=v_row.employee_id and e.auth_user_id=auth.uid()) into v_self;
  if v_self and (v_row.source<>'GRAFIK_PRO' or not v_row.editable_by_employee) then
    raise exception 'PROTECTED_TIME_CONSTRAINT';
  end if;
  update public.employee_time_constraints_v2 set status='REVOKED',
    revoked_at=now(),updated_at=now() where id=v_row.id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'employee_time_constraint_v2',v_row.id::text,'REVOKE',
    jsonb_build_object('employeeId',v_row.employee_id,'kind',v_row.constraint_kind));
  return v_row.id;
end;
$$;


ALTER FUNCTION "public"."employee_time_constraint_revoke_v2"("p_id" "uuid") OWNER TO "postgres";

--
-- Name: employee_time_constraint_save_v2("uuid", "uuid", "text", timestamp with time zone, timestamp with time zone, "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."employee_time_constraint_save_v2"("p_id" "uuid", "p_employee_id" "uuid", "p_kind" "text", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_note" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_kind text:=upper(trim(p_kind));
  v_old public.employee_time_constraints_v2%rowtype;
  v_id uuid;
  v_self boolean;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.employees e where e.id=p_employee_id) then
    raise exception 'EMPLOYEE_NOT_FOUND';
  end if;
  if not public.matrix_v2_can_manage_employee(p_employee_id) then
    raise exception 'FORBIDDEN';
  end if;
  select exists(select 1 from public.employees e
    where e.id=p_employee_id and e.auth_user_id=auth.uid()) into v_self;
  if v_kind not in ('AVAILABLE_WINDOW','UNAVAILABLE','LEAVE','SICKNESS') then
    raise exception 'INVALID_TIME_CONSTRAINT_KIND';
  end if;
  if v_self and v_kind not in ('AVAILABLE_WINDOW','UNAVAILABLE') then
    raise exception 'EMPLOYEE_CANNOT_CREATE_PROTECTED_ABSENCE';
  end if;
  if p_starts_at is null or p_ends_at is null or p_ends_at<=p_starts_at then
    raise exception 'INVALID_TIME_RANGE';
  end if;

  if p_id is not null then
    select * into v_old from public.employee_time_constraints_v2 x
    where x.id=p_id for update;
    if v_old.id is null then raise exception 'TIME_CONSTRAINT_NOT_FOUND'; end if;
    if v_old.employee_id<>p_employee_id then raise exception 'EMPLOYEE_MISMATCH'; end if;
    if v_old.status<>'ACTIVE' then raise exception 'TIME_CONSTRAINT_NOT_ACTIVE'; end if;
    if v_self and (v_old.source<>'GRAFIK_PRO' or not v_old.editable_by_employee) then
      raise exception 'PROTECTED_TIME_CONSTRAINT';
    end if;
    update public.employee_time_constraints_v2 set status='REVOKED',
      revoked_at=now(),updated_at=now() where id=v_old.id;
  end if;

  insert into public.employee_time_constraints_v2(
    employee_id,constraint_kind,time_range,source,priority,editable_by_employee,
    status,note,supersedes_id,created_by
  ) values(
    p_employee_id,v_kind,tstzrange(p_starts_at,p_ends_at,'[)'),
    case when v_self then 'GRAFIK_PRO' else 'MANAGER' end,
    case when v_self then 100 else 300 end,v_self,'ACTIVE',nullif(trim(p_note),''),
    v_old.id,auth.uid()
  ) returning id into v_id;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'employee_time_constraint_v2',v_id::text,
    case when p_id is null then 'CREATE' else 'SUPERSEDE' end,
    jsonb_build_object('employeeId',p_employee_id,'kind',v_kind,
      'startsAt',p_starts_at,'endsAt',p_ends_at,'supersedesId',v_old.id));
  return v_id;
end;
$$;


ALTER FUNCTION "public"."employee_time_constraint_save_v2"("p_id" "uuid", "p_employee_id" "uuid", "p_kind" "text", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_note" "text") OWNER TO "postgres";

--
-- Name: employee_time_constraints_self_v2("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."employee_time_constraints_self_v2"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_month date:=date_trunc('month',p_month)::date;
  v_employee_id uuid;
  v_matrix uuid;
  v_timezone text;
  v_default_available boolean;
  v_period_start timestamptz;
  v_period_end timestamptz;
  v_constraints jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  select employee.id into v_employee_id
  from public.employees employee
  where employee.auth_user_id=auth.uid() and employee.active
    and employee.archived_at is null
  order by employee.id limit 1;
  if v_employee_id is null then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  select matrix.id,nullif(matrix.settings->>'timezone',''),
    coalesce((matrix.settings->>'missingAvailabilityMeansAvailable')::boolean,true)
  into v_matrix,v_timezone,v_default_available
  from public.matrix_versions matrix
  where matrix.status in ('ACTIVE','ARCHIVED') and matrix.schema_version>=2
    and solver_private.matrix_covers_planning_month_uat_v1(matrix.effective_from,v_month)
    and coalesce(matrix.content_hash,'') ~ '^[0-9a-f]{64}$'
    and coalesce(matrix.workforce_hash,'') ~ '^[0-9a-f]{64}$'
  order by matrix.effective_from desc,matrix.version desc limit 1;
  if v_timezone is null then raise exception 'MATRIX_V2_FOR_MONTH_NOT_FOUND'; end if;
  v_period_start:=v_month::timestamp at time zone v_timezone;
  v_period_end:=(v_month+interval '1 month')::timestamp at time zone v_timezone;

  with entries as (
    select constraint_row.id,constraint_row.constraint_kind kind,
      lower(constraint_row.time_range) starts_at,
      upper(constraint_row.time_range) ends_at,
      constraint_row.source,
      constraint_row.source='GRAFIK_PRO'
        and constraint_row.editable_by_employee editable,
      constraint_row.note,
      (select location.id from public.matrix_locations_v2 location
        where location.matrix_version_id=v_matrix
          and location.logical_id=constraint_row.location_logical_id
        order by location.active desc,location.sort_order limit 1) preferred_location_id
    from public.employee_time_constraints_v2 constraint_row
    where constraint_row.employee_id=v_employee_id
      and constraint_row.status='ACTIVE'
      and constraint_row.time_range
        && tstzrange(v_period_start,v_period_end,'[)')
    union all
    select preference.id,
      case when preference.preference_type='OTHER'
        then 'PREFER_NOT_TO_WORK' else 'PREFERRED_LOCATION' end,
      preference.valid_from::timestamp at time zone v_timezone,
      (preference.valid_to+1)::timestamp at time zone v_timezone,
      preference.source,
      preference.source='GRAFIK_PRO' and preference.editable_by_employee,
      nullif(preference.preference_value->>'note',''),
      case when preference.preference_type='PREFERRED_LOCATION'
        and preference.preference_value->>'locationId'
          ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
        then (preference.preference_value->>'locationId')::uuid else null end
    from public.employee_preferences preference
    where preference.employee_id=v_employee_id
      and preference.status='ACTIVE'
      and preference.valid_from<v_month+interval '1 month'
      and preference.valid_to>=v_month
      and (preference.preference_type='PREFERRED_LOCATION'
        or (preference.preference_type='OTHER'
          and preference.preference_value->>'kind'='DAY_OFF'
          and preference.preference_value->>'strength'='SOFT'))
  )
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
    'id',entry.id,'kind',entry.kind,'startsAt',entry.starts_at,
    'endsAt',entry.ends_at,'source',entry.source,
    'editable',entry.editable,'note',entry.note,
    'preferredLocationId',entry.preferred_location_id
  )) order by entry.starts_at,entry.ends_at,entry.id),'[]'::jsonb)
  into v_constraints from entries entry;
  return jsonb_build_object(
    'employeeId',v_employee_id,'timezone',v_timezone,
    'defaultAvailable',v_default_available,
    'constraints',v_constraints
  );
end;
$_$;


ALTER FUNCTION "public"."employee_time_constraints_self_v2"("p_month" "date") OWNER TO "postgres";

--
-- Name: FUNCTION "employee_time_constraints_self_v2"("p_month" "date"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."employee_time_constraints_self_v2"("p_month" "date") IS 'Returns calendar-ready employee availability exceptions and the effective default availability for the selected month.';


--
-- Name: employee_update("uuid", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."employee_update"("p_employee_id" "uuid", "p_data" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$ begin
 if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE')) then raise exception 'FORBIDDEN'; end if;
 update employees set
   first_name=coalesce(nullif(trim(p_data->>'firstName'),''),first_name),last_name=coalesce(nullif(trim(p_data->>'lastName'),''),last_name),
   email=coalesce(nullif(trim(p_data->>'email'),''),email),primary_role=coalesce(nullif(p_data->>'primaryRole','')::employee_role,primary_role),
   monthly_nominal_minutes=coalesce((p_data->>'nominalMinutes')::integer,monthly_nominal_minutes),max_weekly_minutes=coalesce((p_data->>'maxWeeklyMinutes')::integer,max_weekly_minutes),
   max_monthly_minutes=coalesce((p_data->>'maxMonthlyMinutes')::integer,max_monthly_minutes),preferred_shift=coalesce(nullif(p_data->>'preferredShift',''),preferred_shift),
   hourly_rate=case when public.has_app_role('OWNER') or public.has_app_role('HR_FINANCE') then coalesce((p_data->>'hourlyRate')::numeric,hourly_rate) else hourly_rate end,
   updated_at=now() where id=p_employee_id;
 insert into employee_hr_profiles(employee_id,contract_type,employment_fraction,leave_days,hr_note,updated_by,updated_at)
 values(p_employee_id,coalesce(nullif(p_data->>'contractType',''),'UMOWA_O_PRACE'),coalesce((p_data->>'employmentFraction')::numeric,1),coalesce((p_data->>'leaveDays')::integer,0),nullif(p_data->>'hrNote',''),auth.uid(),now())
 on conflict(employee_id) do update set contract_type=excluded.contract_type,employment_fraction=excluded.employment_fraction,leave_days=excluded.leave_days,hr_note=excluded.hr_note,updated_by=auth.uid(),updated_at=now();
 insert into audit_log(actor_id,entity_type,entity_id,action,new_data) values(auth.uid(),'employee',p_employee_id::text,'UPDATE',p_data-'hourlyRate');
end $$;


ALTER FUNCTION "public"."employee_update"("p_employee_id" "uuid", "p_data" "jsonb") OWNER TO "postgres";

--
-- Name: employee_weekly_work_patterns_replace_before_phase1_uat_v1("uuid", "date", "date", "jsonb", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."employee_weekly_work_patterns_replace_before_phase1_uat_v1"("p_employee_id" "uuid", "p_valid_from" "date", "p_valid_to" "date", "p_patterns" "jsonb", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid();
  v_reason text:=trim(coalesce(p_reason,''));
  v_item jsonb;
  v_count integer:=0;
  v_revision integer;
  v_supersedes_id uuid;
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if length(v_reason)<3 then raise exception 'WORK_PATTERN_REASON_REQUIRED'; end if;
  if p_valid_to is not null and p_valid_to<p_valid_from then raise exception 'WORK_PATTERN_PERIOD_INVALID'; end if;
  if jsonb_typeof(coalesce(p_patterns,'[]'::jsonb))<>'array' then raise exception 'WORK_PATTERNS_ARRAY_REQUIRED'; end if;

  perform pg_advisory_xact_lock(hashtextextended('weekly-pattern:'||p_employee_id::text,0));
  select coalesce(max(revision),0)+1 into v_revision
  from public.employee_weekly_work_patterns_v2 where employee_id=p_employee_id;
  update public.employee_weekly_work_patterns_v2 set active=false,revoked_at=now()
  where employee_id=p_employee_id and active
    and daterange(valid_from,coalesce(valid_to,'infinity'::date),'[]') && daterange(p_valid_from,coalesce(p_valid_to,'infinity'::date),'[]');

  for v_item in select value from jsonb_array_elements(coalesce(p_patterns,'[]'::jsonb)) loop
    if coalesce((v_item->>'weekday')::integer,0) not between 1 and 7 then raise exception 'WORK_PATTERN_WEEKDAY_INVALID'; end if;
    if nullif(v_item->>'localStart','') is null or nullif(v_item->>'localEnd','') is null then raise exception 'WORK_PATTERN_TIME_REQUIRED'; end if;
    if upper(coalesce(v_item->>'enforcement','')) not in ('HARD','PREFERENCE') then raise exception 'WORK_PATTERN_ENFORCEMENT_INVALID'; end if;
    select p.id into v_supersedes_id
    from public.employee_weekly_work_patterns_v2 p
    where p.employee_id=p_employee_id and p.revision<v_revision
      and p.weekday=(v_item->>'weekday')::smallint
      and p.local_start=(v_item->>'localStart')::time
      and p.local_end=(v_item->>'localEnd')::time
      and p.role_id is not distinct from nullif(v_item->>'roleId','')::uuid
      and p.location_id is not distinct from nullif(v_item->>'locationId','')::uuid
      and p.enforcement=upper(v_item->>'enforcement')
    order by p.revision desc,p.created_at desc limit 1;
    insert into public.employee_weekly_work_patterns_v2(employee_id,weekday,local_start,local_end,role_id,location_id,enforcement,valid_from,valid_to,revision,supersedes_id,reason,created_by)
    values(p_employee_id,(v_item->>'weekday')::smallint,(v_item->>'localStart')::time,(v_item->>'localEnd')::time,
      nullif(v_item->>'roleId','')::uuid,nullif(v_item->>'locationId','')::uuid,upper(v_item->>'enforcement'),p_valid_from,p_valid_to,v_revision,v_supersedes_id,v_reason,v_actor);
    v_count:=v_count+1;
  end loop;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'employee_weekly_work_pattern_v2',p_employee_id::text,'REPLACE',jsonb_build_object('validFrom',p_valid_from,'validTo',p_valid_to,'count',v_count,'reason',v_reason));
  return jsonb_build_object('employeeId',p_employee_id,'count',v_count,'revision',v_revision,'validFrom',p_valid_from,'validTo',p_valid_to);
end;
$$;


ALTER FUNCTION "public"."employee_weekly_work_patterns_replace_before_phase1_uat_v1"("p_employee_id" "uuid", "p_valid_from" "date", "p_valid_to" "date", "p_patterns" "jsonb", "p_reason" "text") OWNER TO "postgres";

--
-- Name: employee_weekly_work_patterns_replace_uat_v1("uuid", "date", "date", "jsonb", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."employee_weekly_work_patterns_replace_uat_v1"("p_employee_id" "uuid", "p_valid_from" "date", "p_valid_to" "date", "p_patterns" "jsonb", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if not public.matrix_v2_can_manage_resource_uat_v1(null,null,p_employee_id)
    then raise exception 'RESOURCE_SCOPE_FORBIDDEN'; end if;
  if exists(
    select 1
    from jsonb_array_elements(coalesce(p_patterns,'[]'::jsonb)) pattern
    where (nullif(pattern->>'roleId','') is not null or nullif(pattern->>'locationId','') is not null)
      and not public.matrix_v2_can_manage_resource_uat_v1(
        nullif(pattern->>'roleId','')::uuid,
        nullif(pattern->>'locationId','')::uuid,
        p_employee_id
      )
  ) then raise exception 'WORK_PATTERN_RESOURCE_SCOPE_FORBIDDEN'; end if;
  perform authorization_private.enter_resource_scope_uat_v1();
  return public.employee_weekly_work_patterns_replace_before_phase1_uat_v1(
    p_employee_id,p_valid_from,p_valid_to,p_patterns,p_reason
  );
end;
$$;


ALTER FUNCTION "public"."employee_weekly_work_patterns_replace_uat_v1"("p_employee_id" "uuid", "p_valid_from" "date", "p_valid_to" "date", "p_patterns" "jsonb", "p_reason" "text") OWNER TO "postgres";

--
-- Name: employee_weekly_work_patterns_workspace_uat_v1("uuid", "date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."employee_weekly_work_patterns_workspace_uat_v1"("p_employee_id" "uuid", "p_on_date" "date" DEFAULT CURRENT_DATE) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if not (public.can_manage_plans() or public.matrix_v2_can_manage_employee(p_employee_id)) then raise exception 'FORBIDDEN'; end if;
  return jsonb_build_object(
      'employeeId',p_employee_id,
      'onDate',p_on_date,
      'canEdit',public.can_manage_plans(),
      'patterns',coalesce((select jsonb_agg(jsonb_build_object(
        'id',p.id,'weekday',p.weekday,'localStart',p.local_start,'localEnd',p.local_end,
        'roleId',p.role_id,'locationId',p.location_id,'enforcement',p.enforcement,
        'validFrom',p.valid_from,'validTo',p.valid_to,'revision',p.revision,
        'reason',p.reason,'active',p.active
      ) order by p.weekday,p.local_start,p.created_at)
      from public.employee_weekly_work_patterns_v2 p
      where p.employee_id=p_employee_id and p.active
        and p.valid_from<=p_on_date and (p.valid_to is null or p.valid_to>=p_on_date)),'[]'::jsonb)
    );
end;
$$;


ALTER FUNCTION "public"."employee_weekly_work_patterns_workspace_uat_v1"("p_employee_id" "uuid", "p_on_date" "date") OWNER TO "postgres";

--
-- Name: employer_cost_component_save_uat_v1("uuid", "text", "text", "text", bigint, "text", "date", "date", boolean, "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."employer_cost_component_save_uat_v1"("p_logical_id" "uuid", "p_code" "text", "p_name" "text", "p_calculation_method" "text", "p_value" bigint, "p_contract_type" "text", "p_valid_from" "date", "p_valid_to" "date", "p_active" boolean, "p_reason" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare v_actor uuid:=auth.uid();v_previous public.employer_cost_components_v2%rowtype;v_id uuid:=gen_random_uuid();v_logical uuid:=coalesce(p_logical_id,gen_random_uuid());v_revision integer:=1;
begin
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
  if p_calculation_method not in ('PERCENT_BASE','PER_HOUR','FIXED_PER_SHIFT') then raise exception 'INVALID_CALCULATION_METHOD'; end if;
  if p_value<0 or length(trim(coalesce(p_reason,'')))<5 then raise exception 'VALUE_AND_REASON_REQUIRED'; end if;
  select * into v_previous from public.employer_cost_components_v2 where logical_id=v_logical and active for update;
  if v_previous.id is not null then
    v_revision:=v_previous.revision+1;
    update public.employer_cost_components_v2 set active=false where id=v_previous.id;
  end if;
  insert into public.employer_cost_components_v2(id,logical_id,revision,supersedes_id,code,name,calculation_method,
    percent_basis_points,rate_minor_per_hour,amount_minor,contract_type,valid_from,valid_to,active,reason,created_by)
  values(v_id,v_logical,v_revision,v_previous.id,upper(trim(p_code)),trim(p_name),p_calculation_method,
    case when p_calculation_method='PERCENT_BASE' then p_value::integer end,
    case when p_calculation_method='PER_HOUR' then p_value end,
    case when p_calculation_method='FIXED_PER_SHIFT' then p_value end,
    nullif(trim(coalesce(p_contract_type,'')),''),p_valid_from,p_valid_to,p_active,trim(p_reason),v_actor);
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data) values(v_actor,'employer_cost_component_v2',v_id::text,'VERSION_SAVED',jsonb_build_object('logicalId',v_logical,'revision',v_revision));
  return v_id;
end $$;


ALTER FUNCTION "public"."employer_cost_component_save_uat_v1"("p_logical_id" "uuid", "p_code" "text", "p_name" "text", "p_calculation_method" "text", "p_value" bigint, "p_contract_type" "text", "p_valid_from" "date", "p_valid_to" "date", "p_active" boolean, "p_reason" "text") OWNER TO "postgres";

--
-- Name: employer_cost_workspace_before_b4f101_uat_v1("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."employer_cost_workspace_before_b4f101_uat_v1"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare v_month date:=date_trunc('month',p_month)::date;v_end date:=(date_trunc('month',p_month)+interval '1 month - 1 day')::date;
begin
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE') or public.has_app_role('ROLE_MANAGER') or public.has_app_role('LOCATION_MANAGER')) then raise exception 'FORBIDDEN'; end if;
  return jsonb_build_object('month',v_month,'components',coalesce((select jsonb_agg(jsonb_build_object(
    'id',c.id,'logicalId',c.logical_id,'revision',c.revision,'code',c.code,'name',c.name,
    'calculationMethod',c.calculation_method,'percentBasisPoints',c.percent_basis_points,
    'rateMinorPerHour',c.rate_minor_per_hour,'amountMinor',c.amount_minor,'contractType',c.contract_type,
    'validFrom',c.valid_from,'validTo',c.valid_to,'active',c.active,'reason',c.reason
  ) order by c.code,c.revision desc) from public.employer_cost_components_v2 c
    where c.active and c.valid_from<=v_end and coalesce(c.valid_to,'infinity'::date)>=v_month),'[]'::jsonb));
end $$;


ALTER FUNCTION "public"."employer_cost_workspace_before_b4f101_uat_v1"("p_month" "date") OWNER TO "postgres";

--
-- Name: employer_cost_workspace_uat_v1("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."employer_cost_workspace_uat_v1"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_visibility text:=public.application_finance_visibility_current_uat_v1();
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE')
    or public.has_app_role('ROLE_MANAGER') or public.has_app_role('LOCATION_MANAGER')) then raise exception 'FORBIDDEN'; end if;
  if v_visibility<>'FULL' then
    return jsonb_build_object('month',date_trunc('month',p_month)::date,
      'components','[]'::jsonb,'financeVisibility',v_visibility);
  end if;
  return public.employer_cost_workspace_before_b4f101_uat_v1(p_month)
    ||jsonb_build_object('financeVisibility',v_visibility);
end;
$$;


ALTER FUNCTION "public"."employer_cost_workspace_uat_v1"("p_month" "date") OWNER TO "postgres";

--
-- Name: FUNCTION "employer_cost_workspace_uat_v1"("p_month" "date"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."employer_cost_workspace_uat_v1"("p_month" "date") IS 'B4F-101 employer-cost configuration visible only with FULL finance permission.';


--
-- Name: generate_plan("date", "text", "text", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."generate_plan"("p_month" "date", "p_name" "text", "p_scenario_code" "text" DEFAULT 'BASE'::"text", "p_optimization_mode" "text" DEFAULT 'BALANCED'::"text", "p_staffing_level" "text" DEFAULT 'OPTIMAL'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_plan_id uuid;
  v_day date;
  v_last_day date;
  v_shift record;
  v_rule record;
  v_candidate record;
  v_shift_id uuid;
  v_shift_start timestamptz;
  v_shift_end timestamptz;
  v_location_code public.location_code;
  v_location_id uuid;
  v_shift_code text;
  v_required integer;
  v_assigned integer;
  v_minutes integer;
  v_multiplier numeric := (case upper(p_staffing_level)
    when 'MINIMAL' then 0.85 when 'FULL' then 1.10 else 1 end)
    * (case upper(p_scenario_code)
      when 'EVENT' then 1.05 when 'SAVINGS' then 0.90 else 1 end);
  v_cost numeric := 0;
  v_budget numeric;
  v_issue_count integer;
  v_assignment_count integer;
  v_version integer;
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  p_month := date_trunc('month', p_month)::date;
  v_last_day := (p_month + interval '1 month - 1 day')::date;
  select coalesce(max(version),0)+1 into v_version from public.plans where month=p_month;

  insert into public.plans(
    month,name,scenario_code,optimization_mode,staffing_level,status,version,created_by
  ) values (
    p_month,coalesce(nullif(trim(p_name),''),'Plan '||to_char(p_month,'YYYY-MM')),
    upper(p_scenario_code),upper(p_optimization_mode),upper(p_staffing_level),
    'GENERATING',v_version,auth.uid()
  ) returning id into v_plan_id;

  v_day := p_month;
  while v_day <= v_last_day loop
    for v_shift in
      select sd.*, l.code location_code,
        (v_day + sd.start_time) at time zone l.timezone starts_at_calc,
        ((v_day + case when sd.ends_next_day then 1 else 0 end) + sd.end_time)
          at time zone l.timezone ends_at_calc
      from public.shift_definitions sd
      join public.locations l on l.id=sd.location_id
      where sd.active and l.active and sd.day_of_week=extract(dow from v_day)::integer
        and not exists (
          select 1 from public.operational_events oe
          where oe.location_id=l.id and oe.status='CONFIRMED' and oe.event_type='CLOSURE'
            and (oe.starts_at at time zone l.timezone)::date=v_day
        )
      order by l.code, sd.start_time
    loop
      v_location_code := v_shift.location_code;
      v_location_id := v_shift.location_id;
      v_shift_code := v_shift.code;
      insert into public.shifts(
        plan_id,location_id,shift_date,shift_code,starts_at,ends_at,source_event_id
      ) values (
        v_plan_id,v_shift.location_id,v_day,v_shift.code,
        coalesce((
          select edc.custom_start from public.event_demand_changes edc
          join public.operational_events oe on oe.id=edc.event_id
          where oe.location_id=v_shift.location_id and oe.status='CONFIRMED'
            and (oe.starts_at at time zone 'Europe/Warsaw')::date=v_day
            and (edc.shift_code is null or edc.shift_code=v_shift.code)
            and edc.custom_start is not null limit 1
        ),v_shift.starts_at_calc),
        coalesce((
          select edc.custom_end from public.event_demand_changes edc
          join public.operational_events oe on oe.id=edc.event_id
          where oe.location_id=v_shift.location_id and oe.status='CONFIRMED'
            and (oe.starts_at at time zone 'Europe/Warsaw')::date=v_day
            and (edc.shift_code is null or edc.shift_code=v_shift.code)
            and edc.custom_end is not null limit 1
        ),v_shift.ends_at_calc),
        (select oe.id from public.operational_events oe
          where oe.location_id=v_shift.location_id and oe.status='CONFIRMED'
            and (oe.starts_at at time zone 'Europe/Warsaw')::date=v_day limit 1)
      ) returning id,starts_at,ends_at into v_shift_id,v_shift_start,v_shift_end;

      v_minutes := public.shift_minutes(v_shift_start,v_shift_end);

      -- Najpierw kompetencje twarde; osoba z kompetencją jednocześnie pokrywa podstawową rolę.
      for v_rule in
        select dr.role, dr.required_capability,
          greatest(0,dr.required_count)::integer required_count
        from public.demand_rules dr
        where dr.shift_definition_id in (
          select id from public.shift_definitions
          where location_id=v_location_id and code=v_shift_code
            and day_of_week=extract(dow from v_day)::integer
        ) and dr.scenario_code in ('BASE',upper(p_scenario_code))
          and dr.required_capability is not null
        order by dr.role
      loop
        v_required := v_rule.required_count;
        v_assigned := 0;
        for v_candidate in
          select e.*, el.home_location,
            coalesce((select sum(public.shift_minutes(s.starts_at,s.ends_at))
              from public.assignments a join public.shifts s on s.id=a.shift_id
              where a.employee_id=e.id and s.plan_id=v_plan_id),0) assigned_minutes
          from public.employees e
          join public.employee_locations el on el.employee_id=e.id
            and el.location_id=v_location_id
            and (el.standard_allowed or el.overtime_allowed)
          where e.active and e.primary_role=v_rule.role
            and exists (select 1 from public.employee_capabilities ec
              where ec.employee_id=e.id and ec.active and ec.capability=v_rule.required_capability
                and (ec.scope_role is null or ec.scope_role=v_rule.role)
                and (ec.scope_location is null or ec.scope_location=v_location_code))
            and not exists (select 1 from public.employee_availability av
              where av.employee_id=e.id and av.work_date=v_day and not av.available)
            and not exists (select 1 from public.assignments ax join public.shifts sx on sx.id=ax.shift_id
              where ax.employee_id=e.id and sx.plan_id=v_plan_id
                and tstzrange(sx.starts_at,sx.ends_at,'[)') && tstzrange(v_shift_start,v_shift_end,'[)'))
            and coalesce((select sum(public.shift_minutes(s.starts_at,s.ends_at))
              from public.assignments a join public.shifts s on s.id=a.shift_id
              where a.employee_id=e.id and s.plan_id=v_plan_id),0)+v_minutes
              <= coalesce(e.max_monthly_minutes,round(e.monthly_nominal_minutes*1.25))
            and coalesce((select sum(public.shift_minutes(s.starts_at,s.ends_at))
              from public.assignments a join public.shifts s on s.id=a.shift_id
              where a.employee_id=e.id and s.plan_id=v_plan_id
                and date_trunc('week',s.shift_date::timestamp)=date_trunc('week',v_day::timestamp)),0)+v_minutes
              <= e.max_weekly_minutes
            and not exists (select 1 from public.assignments ar join public.shifts sr on sr.id=ar.shift_id
              where ar.employee_id=e.id and sr.plan_id=v_plan_id
                and tstzrange(sr.starts_at-interval '11 hours',sr.ends_at+interval '11 hours','[)')
                  && tstzrange(v_shift_start,v_shift_end,'[)'))
          order by
            case when upper(p_optimization_mode)='MIN_COST' then e.hourly_rate else 0 end,
            coalesce((select sum(public.shift_minutes(s.starts_at,s.ends_at))
              from public.assignments a join public.shifts s on s.id=a.shift_id
              where a.employee_id=e.id and s.plan_id=v_plan_id),0)::numeric
              / greatest(e.monthly_nominal_minutes,1),
            el.home_location desc, e.employee_no
          limit v_required
        loop
          insert into public.assignments(
            shift_id,employee_id,assigned_role,assigned_capability,cost,explanation
          ) values (
            v_shift_id,v_candidate.id,v_rule.role,v_rule.required_capability,
            round(v_candidate.hourly_rate*v_minutes/60,2),
            jsonb_build_object('engine','ALPHA_5','reason','HARD_CAPABILITY','score_minutes',v_candidate.assigned_minutes)
          );
          v_assigned := v_assigned+1;
        end loop;
        if v_assigned < v_required then
          insert into public.plan_issues(plan_id,shift_id,issue_type,severity,role,capability,required_count,assigned_count,message)
          values(v_plan_id,v_shift_id,'CAPABILITY_MISSING','CRITICAL',v_rule.role,v_rule.required_capability,
            v_required,v_assigned,'Brak wymaganej kompetencji '||v_rule.required_capability);
        end if;
      end loop;

      -- Następnie uzupełnienie liczebności każdej roli.
      for v_rule in
        select dr.role,
          greatest(0,ceil((dr.required_count + coalesce((
            select sum(edc.additional_count)
            from public.event_demand_changes edc
            join public.operational_events oe on oe.id=edc.event_id
            where oe.location_id=v_location_id and oe.status='CONFIRMED'
              and (oe.starts_at at time zone 'Europe/Warsaw')::date=v_day
              and edc.role=dr.role
              and (edc.shift_code is null or edc.shift_code=v_shift_code)
              and edc.required_capability is null
          ),0))*v_multiplier))::integer required_count
        from public.demand_rules dr
        where dr.shift_definition_id in (
          select id from public.shift_definitions
          where location_id=v_location_id and code=v_shift_code
            and day_of_week=extract(dow from v_day)::integer
        ) and dr.scenario_code in ('BASE',upper(p_scenario_code))
          and dr.required_capability is null
        order by dr.role
      loop
        select count(*) into v_assigned from public.assignments
          where shift_id=v_shift_id and assigned_role=v_rule.role;
        v_required := greatest(0,v_rule.required_count-v_assigned);
        for v_candidate in
          select e.*, el.home_location,
            coalesce((select sum(public.shift_minutes(s.starts_at,s.ends_at))
              from public.assignments a join public.shifts s on s.id=a.shift_id
              where a.employee_id=e.id and s.plan_id=v_plan_id),0) assigned_minutes
          from public.employees e
          join public.employee_locations el on el.employee_id=e.id
            and el.location_id=v_location_id
            and (el.standard_allowed or el.overtime_allowed)
          where e.active and e.primary_role=v_rule.role
            and not exists (select 1 from public.employee_availability av
              where av.employee_id=e.id and av.work_date=v_day and not av.available)
            and not exists (select 1 from public.assignments ax join public.shifts sx on sx.id=ax.shift_id
              where ax.employee_id=e.id and sx.plan_id=v_plan_id
                and tstzrange(sx.starts_at,sx.ends_at,'[)') && tstzrange(v_shift_start,v_shift_end,'[)'))
            and coalesce((select sum(public.shift_minutes(s.starts_at,s.ends_at))
              from public.assignments a join public.shifts s on s.id=a.shift_id
              where a.employee_id=e.id and s.plan_id=v_plan_id),0)+v_minutes
              <= coalesce(e.max_monthly_minutes,round(e.monthly_nominal_minutes*1.25))
            and coalesce((select sum(public.shift_minutes(s.starts_at,s.ends_at))
              from public.assignments a join public.shifts s on s.id=a.shift_id
              where a.employee_id=e.id and s.plan_id=v_plan_id
                and date_trunc('week',s.shift_date::timestamp)=date_trunc('week',v_day::timestamp)),0)+v_minutes
              <= e.max_weekly_minutes
            and not exists (select 1 from public.assignments ar join public.shifts sr on sr.id=ar.shift_id
              where ar.employee_id=e.id and sr.plan_id=v_plan_id
                and tstzrange(sr.starts_at-interval '11 hours',sr.ends_at+interval '11 hours','[)')
                  && tstzrange(v_shift_start,v_shift_end,'[)'))
          order by
            case when upper(p_optimization_mode)='MIN_COST' then e.hourly_rate else 0 end,
            case when e.preferred_shift=v_shift_code then 0 else 1 end,
            coalesce((select sum(public.shift_minutes(s.starts_at,s.ends_at))
              from public.assignments a join public.shifts s on s.id=a.shift_id
              where a.employee_id=e.id and s.plan_id=v_plan_id),0)::numeric
              / greatest(e.monthly_nominal_minutes,1),
            el.home_location desc, e.employee_no
          limit v_required
        loop
          insert into public.assignments(shift_id,employee_id,assigned_role,cost,explanation)
          values(v_shift_id,v_candidate.id,v_rule.role,
            round(v_candidate.hourly_rate*v_minutes/60,2),
            jsonb_build_object('engine','ALPHA_5','reason','BALANCED_LOAD','score_minutes',v_candidate.assigned_minutes));
          v_assigned := v_assigned+1;
        end loop;
        if v_assigned < v_rule.required_count then
          insert into public.plan_issues(plan_id,shift_id,issue_type,severity,role,required_count,assigned_count,message)
          values(v_plan_id,v_shift_id,'SHORTAGE',
            case when v_assigned=0 then 'CRITICAL' else 'WARNING' end,
            v_rule.role,v_rule.required_count,v_assigned,
            'Brak '||(v_rule.required_count-v_assigned)||' os. dla roli '||v_rule.role::text);
        end if;
      end loop;
    end loop;
    v_day := v_day+1;
  end loop;

  select coalesce(sum(cost),0),count(*) into v_cost,v_assignment_count
  from public.assignments a join public.shifts s on s.id=a.shift_id where s.plan_id=v_plan_id;
  select amount into v_budget from public.monthly_budgets where month=p_month;
  if v_budget is not null and v_cost>v_budget then
    insert into public.plan_issues(plan_id,issue_type,severity,message)
    values(v_plan_id,'BUDGET_EXCEEDED','CRITICAL',
      'Koszt planu '||round(v_cost,2)||' przekracza budżet '||round(v_budget,2));
  end if;
  select count(*) into v_issue_count from public.plan_issues where plan_id=v_plan_id;

  update public.plans set status='READY',total_cost=v_cost,generated_at=now(),
    score=greatest(0,100-v_issue_count*2)
  where id=v_plan_id;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'plan',v_plan_id::text,'GENERATE',
    jsonb_build_object('assignments',v_assignment_count,'issues',v_issue_count,'cost',v_cost));
  return jsonb_build_object(
    'plan_id',v_plan_id,'status','READY','assignments',v_assignment_count,
    'issues',v_issue_count,'total_cost',v_cost
  );
exception when others then
  if v_plan_id is not null then
    update public.plans set status='FAILED' where id=v_plan_id;
  end if;
  raise;
end;
$$;


ALTER FUNCTION "public"."generate_plan"("p_month" "date", "p_name" "text", "p_scenario_code" "text", "p_optimization_mode" "text", "p_staffing_level" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "generate_plan"("p_month" "date", "p_name" "text", "p_scenario_code" "text", "p_optimization_mode" "text", "p_staffing_level" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."generate_plan"("p_month" "date", "p_name" "text", "p_scenario_code" "text", "p_optimization_mode" "text", "p_staffing_level" "text") IS 'Retired Alpha 15 write. Kept only for immutable migration history and owner-level rollback.';


--
-- Name: generate_role_plan("date", "uuid", "text", "text", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."generate_role_plan"("p_month" "date", "p_role_id" "uuid", "p_name" "text", "p_scenario" "text" DEFAULT 'BASE'::"text", "p_mode" "text" DEFAULT 'BALANCED'::"text", "p_staffing" "text" DEFAULT 'OPTIMAL'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare generated jsonb; v_plan_id uuid; section_id uuid; role_code text; cnt integer; begin
 if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
 select code into role_code from matrix_roles where id=p_role_id and active;
 if role_code is null then raise exception 'ROLE_NOT_FOUND'; end if;
 generated:=public.generate_plan(p_month,'Źródło roli '||role_code||' • '||coalesce(p_name,''),p_scenario,p_mode,p_staffing);
 v_plan_id:=(generated->>'plan_id')::uuid;
 section_id:=public.create_role_plan_section(p_month,p_role_id,p_name,p_scenario,p_mode,p_staffing);
 update role_plan_sections set legacy_plan_id=v_plan_id,status='READY',updated_at=now() where id=section_id;
 insert into role_plan_assignments(role_plan_section_id,assignment_id)
 select section_id,a.id from assignments a join shifts s on s.id=a.shift_id
 where s.plan_id=v_plan_id and a.assigned_role::text=role_code;
 get diagnostics cnt=row_count;
 -- Kluczowa izolacja: źródło roli nigdy nie trafia do Centrum dowodzenia.
 update plans set status='ARCHIVED' where id=v_plan_id;
 return jsonb_build_object('sectionId',section_id,'assignments',cnt,
   'issues',(select count(*) from plan_issues pi where pi.plan_id=v_plan_id and pi.role::text=role_code));
exception when others then
 if v_plan_id is not null then update plans set status='FAILED' where id=v_plan_id; end if;
 raise;
end $$;


ALTER FUNCTION "public"."generate_role_plan"("p_month" "date", "p_role_id" "uuid", "p_name" "text", "p_scenario" "text", "p_mode" "text", "p_staffing" "text") OWNER TO "postgres";

--
-- Name: has_app_role("public"."app_role"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."has_app_role"("required_role" "public"."app_role") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from public.user_permissions
    where auth_user_id = auth.uid() and app_role = required_role
  );
$$;


ALTER FUNCTION "public"."has_app_role"("required_role" "public"."app_role") OWNER TO "postgres";

--
-- Name: kadromierz_export("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."kadromierz_export"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
with chosen as (select id from plans where month=date_trunc('month',p_month)::date and status='PUBLISHED' order by version desc limit 1)
select coalesce(jsonb_agg(jsonb_build_object('numer_pracownika',e.employee_no,'pracownik',e.first_name||' '||e.last_name,'data',s.shift_date,'lokal',l.code,'zmiana',s.shift_code,'od',s.starts_at,'do',s.ends_at,'rola',a.assigned_role,'funkcja',a.assigned_capability) order by s.shift_date,e.employee_no),'[]'::jsonb)
from assignments a join shifts s on s.id=a.shift_id join chosen c on c.id=s.plan_id join employees e on e.id=a.employee_id join locations l on l.id=s.location_id where public.can_manage_plans();
$$;


ALTER FUNCTION "public"."kadromierz_export"("p_month" "date") OWNER TO "postgres";

--
-- Name: kadromierz_import_preferences("text", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."kadromierz_import_preferences"("p_file_name" "text", "p_rows" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare row jsonb; e_id uuid; imported integer:=0; skipped integer:=0; run_id uuid; from_day date; to_day date; typ text; begin
 if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
 insert into integration_runs(integration,direction,entity_type,status,file_name,executed_by) values('KADROMIERZ','IMPORT','DOSTEPNOSC_I_PREFERENCJE','RUNNING',p_file_name,auth.uid()) returning id into run_id;
 for row in select value from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) loop
   select id into e_id from employees where employee_no=coalesce(row->>'employee_no',row->>'numer_pracownika');
   from_day:=coalesce(row->>'date',row->>'data')::date; to_day:=coalesce(row->>'date_to',row->>'data_do',row->>'date',row->>'data')::date; typ:=upper(coalesce(nullif(row->>'type',''),'LEAVE'));
   if e_id is null or from_day is null then skipped:=skipped+1; continue; end if;
   insert into employee_preferences(employee_id,valid_from,valid_to,preference_type,preference_value,source,status)
   values(e_id,from_day,to_day,typ,jsonb_build_object('note',coalesce(row->>'note',row->>'uwagi','')),'KADROMIERZ','ACTIVE');
   if typ in ('UNAVAILABLE','LEAVE','SICKNESS') then
     insert into employee_availability(employee_id,work_date,available,note,source,updated_by,updated_at)
     select e_id,g::date,false,coalesce(row->>'note',row->>'uwagi',''),'KADROMIERZ',auth.uid(),now() from generate_series(from_day,to_day,interval '1 day') g
     on conflict(employee_id,work_date) do update set available=false,note=excluded.note,source='KADROMIERZ',updated_by=auth.uid(),updated_at=now();
   end if;
   imported:=imported+1;
 end loop;
 update integration_runs set status=case when skipped=0 then 'SUCCESS' else 'PARTIAL' end,summary=jsonb_build_object('imported',imported,'skipped',skipped,'unavailabilityApplied',true) where id=run_id;
 return jsonb_build_object('imported',imported,'skipped',skipped,'runId',run_id);
end $$;


ALTER FUNCTION "public"."kadromierz_import_preferences"("p_file_name" "text", "p_rows" "jsonb") OWNER TO "postgres";

--
-- Name: log_availability_change(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."log_availability_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if tg_op='INSERT' or old.available is distinct from new.available or old.note is distinct from new.note then
    insert into employee_availability_history(employee_id,work_date,old_available,new_available,source,note,changed_by)
    values(new.employee_id,new.work_date,case when tg_op='INSERT' then null else old.available end,new.available,new.source,new.note,coalesce(new.updated_by,auth.uid()));
  end if;
  return new;
end $$;


ALTER FUNCTION "public"."log_availability_change"() OWNER TO "postgres";

--
-- Name: manager_standby_month_uat_v2("date", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."manager_standby_month_uat_v2"("p_month" "date", "p_scope_role_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO ''
    AS $$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',standby.id,
      'date',standby.standby_date,
      'tier',standby.tier,
      'status',standby.status,
      'roleId',standby.role_id,
      'roleName',role.name,
      'employeeId',standby.employee_id,
      'employeeNo',employee.employee_no,
      'employeeName',concat_ws(' ',employee.first_name,employee.last_name),
      'sourceType',case when standby.source_role_schedule_id is null then 'COMPANY' else 'ROLE' end,
      'activatedShiftId',standby.activated_shift_id
    ) order by standby.standby_date,role.name,standby.tier)
    from public.published_standby_assignments_v2 standby
    join public.matrix_roles_v2 role on role.id=standby.role_id
    join public.employees employee on employee.id=standby.employee_id
    where standby.month=date_trunc('month',p_month)::date
      and (p_scope_role_id is null or standby.role_id=p_scope_role_id)
      and standby.status in ('PLANNED','ACTIVATED','DECLINED')
  ),'[]'::jsonb);
end;
$$;


ALTER FUNCTION "public"."manager_standby_month_uat_v2"("p_month" "date", "p_scope_role_id" "uuid") OWNER TO "postgres";

--
-- Name: manager_standby_month_uat_v3("date", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."manager_standby_month_uat_v3"("p_month" "date", "p_scope_role_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO ''
    AS $$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id',standby.id,'date',standby.standby_date,'tier',standby.tier,'status',standby.status,
    'roleId',standby.role_id,'roleName',coalesce(standby.standby_group_name,role.name),
    'groupCode',standby.standby_group_code,'groupName',standby.standby_group_name,
    'eligibleRoleIds',to_jsonb(coalesce(standby.eligible_role_ids,array[standby.role_id])),
    'eligibleRoleNames',coalesce((select jsonb_agg(group_role.name order by group_role.sort_order,group_role.name)
      from public.matrix_roles_v2 group_role where group_role.id=any(coalesce(standby.eligible_role_ids,array[standby.role_id]))),'[]'::jsonb),
    'employeeId',standby.employee_id,'employeeNo',employee.employee_no,
    'employeeName',concat_ws(' ',employee.first_name,employee.last_name),
    'sourceType',case when standby.source_role_schedule_id is null then 'COMPANY' else 'ROLE' end,
    'activatedShiftId',standby.activated_shift_id
  ) order by standby.standby_date,coalesce(standby.standby_group_name,role.name),standby.tier)
  from public.published_standby_assignments_v2 standby
  join public.matrix_roles_v2 role on role.id=standby.role_id
  join public.employees employee on employee.id=standby.employee_id
  where standby.month=date_trunc('month',p_month)::date and standby.status in ('PLANNED','ACTIVATED','DECLINED')
    and (p_scope_role_id is null or standby.role_id=p_scope_role_id
      or p_scope_role_id=any(coalesce(standby.eligible_role_ids,'{}'::uuid[]))
      or standby.standby_category_code=(select category.code from public.matrix_roles_v2 scope_role
        join public.matrix_role_categories_v2 category on category.id=scope_role.category_id where scope_role.id=p_scope_role_id)
    )),'[]'::jsonb);
end;
$$;


ALTER FUNCTION "public"."manager_standby_month_uat_v3"("p_month" "date", "p_scope_role_id" "uuid") OWNER TO "postgres";

--
-- Name: matrix_create_draft("text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_create_draft"("p_name" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare a matrix_versions; n uuid; v integer; begin
 if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
 select * into a from matrix_versions where status='ACTIVE' order by version desc limit 1;
 if exists(select 1 from matrix_versions where status='DRAFT') then return (select id from matrix_versions where status='DRAFT' order by version desc limit 1); end if;
 select coalesce(max(version),0)+1 into v from matrix_versions;
 insert into matrix_versions(version,name,status,effective_from,settings,created_by) values(v,coalesce(nullif(trim(p_name),''),'Matrix v'||v),'DRAFT',a.effective_from,a.settings,auth.uid()) returning id into n;
  insert into matrix_roles(matrix_version_id,code,name,color,sort_order,active) select n,code,name,color,sort_order,active from matrix_roles where matrix_version_id=a.id;
  insert into matrix_locations(matrix_version_id,code,name,active) select n,code,name,active from matrix_locations where matrix_version_id=a.id;
  insert into matrix_functions(matrix_version_id,code,name,description,active) select n,code,name,description,active from matrix_functions where matrix_version_id=a.id;
  insert into matrix_shift_templates(matrix_version_id,location_id,code,name,starts_at,ends_at,day_mask,sort_order,active)
  select n,nl.id,s.code,s.name,s.starts_at,s.ends_at,s.day_mask,s.sort_order,s.active
  from matrix_shift_templates s join matrix_locations ol on ol.id=s.location_id
  join matrix_locations nl on nl.matrix_version_id=n and nl.code=ol.code where s.matrix_version_id=a.id;
  insert into matrix_role_functions(role_id,function_id,assignment_mode)
  select nr.id,nf.id,rf.assignment_mode from matrix_role_functions rf
  join matrix_roles orr on orr.id=rf.role_id join matrix_functions ofn on ofn.id=rf.function_id
  join matrix_roles nr on nr.matrix_version_id=n and nr.code=orr.code
  join matrix_functions nf on nf.matrix_version_id=n and nf.code=ofn.code;
  insert into matrix_demand(shift_template_id,role_id,function_id,scenario_code,required_count)
  select ns.id,nr.id,nf.id,md.scenario_code,md.required_count from matrix_demand md
  join matrix_shift_templates os on os.id=md.shift_template_id join matrix_locations ol on ol.id=os.location_id
  join matrix_roles orr on orr.id=md.role_id left join matrix_functions ofn on ofn.id=md.function_id
  join matrix_locations nl on nl.matrix_version_id=n and nl.code=ol.code
  join matrix_shift_templates ns on ns.matrix_version_id=n and ns.location_id=nl.id and ns.code=os.code
  join matrix_roles nr on nr.matrix_version_id=n and nr.code=orr.code
  left join matrix_functions nf on nf.matrix_version_id=n and nf.code=ofn.code;
 return n;
end $$;


ALTER FUNCTION "public"."matrix_create_draft"("p_name" "text") OWNER TO "postgres";

--
-- Name: matrix_import_apply("text", "jsonb", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_import_apply"("p_file_name" "text", "p_payload" "jsonb", "p_requested_permissions" "jsonb" DEFAULT '[]'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare d uuid; row jsonb; loc uuid; sh uuid; ro uuid; imported_roles int:=0; imported_shifts int:=0; imported_demand int:=0; run_id uuid; begin
 if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
 d:=matrix_create_draft('Import z pliku '||p_file_name);
 for row in select value from jsonb_array_elements(coalesce(p_payload->'locations','[]'::jsonb)) loop
   insert into matrix_locations(matrix_version_id,code,name,active)
   values(d,upper(trim(row->>'KOD')),trim(row->>'NAZWA'),upper(coalesce(row->>'AKTYWNA','TAK'))<>'NIE')
   on conflict(matrix_version_id,code) do update set name=excluded.name,active=excluded.active;
 end loop;
 for row in select value from jsonb_array_elements(coalesce(p_payload->'roles','[]'::jsonb)) loop
   insert into matrix_roles(matrix_version_id,code,name,color,active)
   values(d,upper(trim(row->>'KOD')),trim(row->>'NAZWA'),coalesce(nullif(row->>'KOLOR',''),'#7257d8'),upper(coalesce(row->>'AKTYWNA','TAK'))<>'NIE')
   on conflict(matrix_version_id,code) do update set name=excluded.name,color=excluded.color,active=excluded.active;
   imported_roles:=imported_roles+1;
 end loop;
 for row in select value from jsonb_array_elements(coalesce(p_payload->'functions','[]'::jsonb)) loop
   insert into matrix_functions(matrix_version_id,code,name,description,active)
   values(d,upper(trim(row->>'KOD')),trim(row->>'NAZWA'),nullif(row->>'OPIS',''),upper(coalesce(row->>'AKTYWNA','TAK'))<>'NIE')
   on conflict(matrix_version_id,code) do update set name=excluded.name,description=excluded.description,active=excluded.active;
 end loop;
 for row in select value from jsonb_array_elements(coalesce(p_payload->'scenarios','[]'::jsonb)) loop
   insert into matrix_scenarios(matrix_version_id,code,name,active)
   values(d,upper(trim(row->>'KOD')),trim(row->>'NAZWA'),upper(coalesce(row->>'AKTYWNY','TAK'))<>'NIE')
   on conflict(matrix_version_id,code) do update set name=excluded.name,active=excluded.active;
 end loop;
 for row in select value from jsonb_array_elements(coalesce(p_payload->'shifts','[]'::jsonb)) loop
   select id into loc from matrix_locations where matrix_version_id=d and code=upper(trim(row->>'LOKAL'));
   if loc is null then raise exception 'IMPORT_UNKNOWN_LOCATION: %',row->>'LOKAL'; end if;
   insert into matrix_shift_templates(matrix_version_id,location_id,code,name,starts_at,ends_at,day_mask,active)
   values(d,loc,upper(trim(row->>'KOD')),trim(row->>'NAZWA'),(row->>'OD')::time,(row->>'DO')::time,string_to_array(row->>'DNI',',')::smallint[],upper(coalesce(row->>'AKTYWNA','TAK'))<>'NIE')
   on conflict(matrix_version_id,location_id,code) do update set name=excluded.name,starts_at=excluded.starts_at,ends_at=excluded.ends_at,day_mask=excluded.day_mask,active=excluded.active;
   imported_shifts:=imported_shifts+1;
 end loop;
 for row in select value from jsonb_array_elements(coalesce(p_payload->'demand','[]'::jsonb)) loop
   select ml.id into loc from matrix_locations ml where ml.matrix_version_id=d and ml.code=upper(trim(row->>'LOKAL'));
   select ms.id into sh from matrix_shift_templates ms where ms.matrix_version_id=d and ms.location_id=loc and ms.code=upper(trim(row->>'ZMIANA'));
   select mr.id into ro from matrix_roles mr where mr.matrix_version_id=d and mr.code=upper(trim(row->>'ROLA'));
   if sh is null or ro is null then raise exception 'IMPORT_UNKNOWN_SHIFT_OR_ROLE'; end if;
   insert into matrix_demand(shift_template_id,role_id,scenario_code,required_count)
   values(sh,ro,upper(coalesce(nullif(row->>'SCENARIUSZ',''),'BASE')),greatest((row->>'WYMAGANE')::integer,0))
   on conflict(shift_template_id,role_id,function_id,scenario_code) do update set required_count=excluded.required_count;
   imported_demand:=imported_demand+1;
 end loop;
 insert into matrix_import_runs(file_name,matrix_version_id,status,summary,requested_permissions,created_by)
 values(p_file_name,d,'IMPORTED',jsonb_build_object('roles',imported_roles,'shifts',imported_shifts,'demand',imported_demand),coalesce(p_requested_permissions,'[]'::jsonb),auth.uid()) returning id into run_id;
 insert into audit_log(actor_id,entity_type,entity_id,action,new_data) values(auth.uid(),'matrix_import',run_id::text,'IMPORT',jsonb_build_object('permissionsApplied',false));
 return jsonb_build_object('draftId',d,'roles',imported_roles,'shifts',imported_shifts,'demand',imported_demand,'permissionsApplied',false);
end $$;


ALTER FUNCTION "public"."matrix_import_apply"("p_file_name" "text", "p_payload" "jsonb", "p_requested_permissions" "jsonb") OWNER TO "postgres";

--
-- Name: matrix_publish_draft("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_publish_draft"("p_effective_from" "date") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$ declare d matrix_versions; begin
 if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
 select * into d from matrix_versions where status='DRAFT' order by version desc limit 1 for update;
 if d.id is null then raise exception 'NO_DRAFT'; end if;
 update matrix_versions set status='ARCHIVED',effective_to=p_effective_from-1 where status='ACTIVE';
 update matrix_versions set status='ACTIVE',effective_from=p_effective_from,activated_at=now() where id=d.id;
 return d.id;
end $$;


ALTER FUNCTION "public"."matrix_publish_draft"("p_effective_from" "date") OWNER TO "postgres";

--
-- Name: matrix_register_import("text", "jsonb", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_register_import"("p_file_name" "text", "p_summary" "jsonb", "p_requested_permissions" "jsonb" DEFAULT '[]'::"jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare out_id uuid; draft_id uuid; begin
 if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
 draft_id:=matrix_create_draft('Import z pliku '||p_file_name);
 insert into matrix_import_runs(file_name,matrix_version_id,status,summary,requested_permissions,created_by)
 values(p_file_name,draft_id,'VALIDATED',coalesce(p_summary,'{}'::jsonb),coalesce(p_requested_permissions,'[]'::jsonb),auth.uid()) returning id into out_id;
 return out_id;
end $$;


ALTER FUNCTION "public"."matrix_register_import"("p_file_name" "text", "p_summary" "jsonb", "p_requested_permissions" "jsonb") OWNER TO "postgres";

--
-- Name: matrix_save_demand("uuid", "uuid", integer, "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_save_demand"("p_shift_id" "uuid", "p_role_id" "uuid", "p_required" integer, "p_scenario" "text" DEFAULT 'BASE'::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare d uuid; out_id uuid; begin
 if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
 select id into d from matrix_versions where status='DRAFT' order by version desc limit 1;
 if d is null then raise exception 'NO_DRAFT'; end if;
 if not exists(select 1 from matrix_shift_templates where id=p_shift_id and matrix_version_id=d) then raise exception 'SHIFT_NOT_IN_DRAFT'; end if;
 if not exists(select 1 from matrix_roles where id=p_role_id and matrix_version_id=d) then raise exception 'ROLE_NOT_IN_DRAFT'; end if;
 update matrix_demand set required_count=greatest(p_required,0)
 where shift_template_id=p_shift_id and role_id=p_role_id and function_id is null and scenario_code=p_scenario
 returning id into out_id;
 if out_id is null then
   insert into matrix_demand(shift_template_id,role_id,scenario_code,required_count)
   values(p_shift_id,p_role_id,p_scenario,greatest(p_required,0)) returning id into out_id;
 end if;
 return out_id;
end $$;


ALTER FUNCTION "public"."matrix_save_demand"("p_shift_id" "uuid", "p_role_id" "uuid", "p_required" integer, "p_scenario" "text") OWNER TO "postgres";

--
-- Name: matrix_save_item("text", "uuid", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_save_item"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare d uuid; out_id uuid; begin
 if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
 d:=matrix_create_draft(null);
 if p_kind='ROLE' then
   if p_id is null then insert into matrix_roles(matrix_version_id,code,name,color,sort_order) values(d,upper(p_data->>'code'),p_data->>'name',coalesce(p_data->>'color','#7257d8'),coalesce((p_data->>'sortOrder')::integer,99)) returning id into out_id;
   else update matrix_roles set code=upper(coalesce(nullif(p_data->>'code',''),code)),name=coalesce(nullif(p_data->>'name',''),name),color=coalesce(nullif(p_data->>'color',''),color),active=coalesce((p_data->>'active')::boolean,active) where id=p_id and matrix_version_id=d returning id into out_id; end if;
 elsif p_kind='FUNCTION' then
   if p_id is null then insert into matrix_functions(matrix_version_id,code,name,description) values(d,upper(p_data->>'code'),p_data->>'name',p_data->>'description') returning id into out_id;
   else update matrix_functions set code=upper(coalesce(nullif(p_data->>'code',''),code)),name=coalesce(nullif(p_data->>'name',''),name),description=coalesce(p_data->>'description',description),active=coalesce((p_data->>'active')::boolean,active) where id=p_id and matrix_version_id=d returning id into out_id; end if;
 elsif p_kind='LOCATION' then
   if p_id is null then insert into matrix_locations(matrix_version_id,code,name) values(d,upper(p_data->>'code'),p_data->>'name') returning id into out_id;
   else update matrix_locations set code=upper(coalesce(nullif(p_data->>'code',''),code)),name=coalesce(nullif(p_data->>'name',''),name),active=coalesce((p_data->>'active')::boolean,active) where id=p_id and matrix_version_id=d returning id into out_id; end if;
 else raise exception 'INVALID_KIND'; end if;
 if out_id is null then raise exception 'ITEM_NOT_IN_DRAFT'; end if; return out_id;
end $$;


ALTER FUNCTION "public"."matrix_save_item"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_save_item"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_save_item"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") IS 'Retired Alpha 15 Matrix write. Matrix v2 is the only administrative source of truth.';


--
-- Name: matrix_save_shift("uuid", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_save_shift"("p_id" "uuid", "p_data" "jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare d uuid; out_id uuid; loc uuid; begin
 if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
 d:=matrix_create_draft(null);
 loc:=(p_data->>'locationId')::uuid;
 if not exists(select 1 from matrix_locations where id=loc and matrix_version_id=d) then raise exception 'LOCATION_NOT_IN_DRAFT'; end if;
 if p_id is null then
   insert into matrix_shift_templates(matrix_version_id,location_id,code,name,starts_at,ends_at,day_mask,sort_order,active)
   values(d,loc,upper(p_data->>'code'),p_data->>'name',(p_data->>'startsAt')::time,(p_data->>'endsAt')::time,
     string_to_array(p_data->>'days',',')::smallint[],coalesce((p_data->>'sortOrder')::integer,99),true) returning id into out_id;
 else
   update matrix_shift_templates set location_id=loc,code=upper(coalesce(nullif(p_data->>'code',''),code)),
     name=coalesce(nullif(p_data->>'name',''),name),starts_at=coalesce((p_data->>'startsAt')::time,starts_at),
     ends_at=coalesce((p_data->>'endsAt')::time,ends_at),day_mask=coalesce(string_to_array(nullif(p_data->>'days',''),',')::smallint[],day_mask),
     active=coalesce((p_data->>'active')::boolean,active)
   where id=p_id and matrix_version_id=d returning id into out_id;
 end if;
 if out_id is null then raise exception 'ITEM_NOT_IN_DRAFT'; end if;
 return out_id;
end $$;


ALTER FUNCTION "public"."matrix_save_shift"("p_id" "uuid", "p_data" "jsonb") OWNER TO "postgres";

--
-- Name: matrix_scope_grant_save_v2("uuid", "uuid", "public"."app_role", "uuid", "uuid", "uuid", boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_scope_grant_save_v2"("p_id" "uuid", "p_auth_user_id" "uuid", "p_app_role" "public"."app_role", "p_role_id" "uuid" DEFAULT NULL::"uuid", "p_location_id" "uuid" DEFAULT NULL::"uuid", "p_duty_id" "uuid" DEFAULT NULL::"uuid", "p_active" boolean DEFAULT true) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_id uuid;
  v_role_logical uuid;
  v_location_logical uuid;
  v_duty_logical uuid;
begin
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if p_auth_user_id is null then raise exception 'AUTH_USER_REQUIRED'; end if;
  if p_role_id is not null then
    select r.logical_id into v_role_logical from public.matrix_roles_v2 r where r.id=p_role_id;
    if v_role_logical is null then raise exception 'ROLE_NOT_FOUND'; end if;
  end if;
  if p_location_id is not null then
    select l.logical_id into v_location_logical from public.matrix_locations_v2 l where l.id=p_location_id;
    if v_location_logical is null then raise exception 'LOCATION_NOT_FOUND'; end if;
  end if;
  if p_duty_id is not null then
    select d.logical_id into v_duty_logical from public.matrix_duties_v2 d where d.id=p_duty_id;
    if v_duty_logical is null then raise exception 'DUTY_NOT_FOUND'; end if;
  end if;

  if p_id is null then
    insert into public.matrix_scope_grants_v2(
      auth_user_id,app_role,role_logical_id,location_logical_id,duty_logical_id,
      active,created_by
    ) values(
      p_auth_user_id,p_app_role,v_role_logical,v_location_logical,v_duty_logical,
      coalesce(p_active,true),auth.uid()
    ) on conflict(auth_user_id,app_role,role_logical_id,location_logical_id,duty_logical_id)
      do update set active=excluded.active,updated_at=now()
    returning id into v_id;
  else
    update public.matrix_scope_grants_v2 set auth_user_id=p_auth_user_id,
      app_role=p_app_role,role_logical_id=v_role_logical,
      location_logical_id=v_location_logical,duty_logical_id=v_duty_logical,
      active=coalesce(p_active,true),updated_at=now()
    where id=p_id returning id into v_id;
    if v_id is null then raise exception 'SCOPE_GRANT_NOT_FOUND'; end if;
  end if;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_scope_grant_v2',v_id::text,'UPSERT',jsonb_build_object(
    'authUserId',p_auth_user_id,'appRole',p_app_role,
    'roleLogicalId',v_role_logical,'locationLogicalId',v_location_logical,
    'dutyLogicalId',v_duty_logical,'active',coalesce(p_active,true)));
  return v_id;
end;
$$;


ALTER FUNCTION "public"."matrix_scope_grant_save_v2"("p_id" "uuid", "p_auth_user_id" "uuid", "p_app_role" "public"."app_role", "p_role_id" "uuid", "p_location_id" "uuid", "p_duty_id" "uuid", "p_active" boolean) OWNER TO "postgres";

--
-- Name: matrix_shift_color_preserve_on_clone_uat_v1(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_shift_color_preserve_on_clone_uat_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_source_color text;
begin
  select source_row.color into v_source_color
  from public.matrix_shift_templates_v2 source_row
  where source_row.logical_id=new.logical_id
  order by source_row.updated_at desc,source_row.created_at desc,source_row.id desc
  limit 1;
  if v_source_color is not null then new.color:=v_source_color; end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."matrix_shift_color_preserve_on_clone_uat_v1"() OWNER TO "postgres";

--
-- Name: matrix_v2_admin_save("text", "uuid", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_admin_save"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare v_result jsonb;v_tiers integer;
begin
  if upper(trim(p_kind))='MATRIX_SETTINGS' then
    if coalesce(p_data->>'standbyTiersPerRoleDay','') !~ '^[0-2]$' then
      raise exception 'INVALID_STANDBY_TIERS';
    end if;
    v_tiers:=(p_data->>'standbyTiersPerRoleDay')::integer;
  end if;
  v_result:=public.matrix_v2_admin_save_before_standby_setting(p_kind,p_id,p_data);
  if upper(trim(p_kind))='MATRIX_SETTINGS' then
    update public.matrix_versions
    set settings=jsonb_set(coalesce(settings,'{}'::jsonb),'{standbyTiersPerRoleDay}',to_jsonb(v_tiers),true)
    where id=(v_result->>'id')::uuid;
  end if;
  return v_result;
end;
$_$;


ALTER FUNCTION "public"."matrix_v2_admin_save"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") OWNER TO "postgres";

--
-- Name: matrix_v2_admin_save_alpha16("text", "uuid", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_admin_save_alpha16"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_result jsonb;
  v_color text;
begin
  v_result:=public.matrix_v2_admin_save_before_b4f118(p_kind,p_id,p_data);
  if upper(trim(p_kind))='SHIFT' and coalesce(trim(p_data->>'color'),'')<>'' then
    v_color:=upper(trim(p_data->>'color'));
    if v_color !~ '^#[0-9A-F]{6}$' then raise exception 'INVALID_SHIFT_COLOR'; end if;
    update public.matrix_shift_templates_v2
    set color=v_color,updated_at=now()
    where id=(v_result->>'id')::uuid;
  end if;
  return v_result;
end;
$_$;


ALTER FUNCTION "public"."matrix_v2_admin_save_alpha16"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") OWNER TO "postgres";

--
-- Name: matrix_v2_admin_save_before_b4f118("text", "uuid", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_admin_save_before_b4f118"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_mode text:=upper(coalesce(nullif(trim(p_data->>'assignmentMode'),''),'OPTIONAL'));
  v_minimum_text text:=coalesce(nullif(trim(p_data->>'minimumCount'),''),'0');
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if upper(trim(p_kind))='ROLE_DUTY' and (
    v_mode not in ('OPTIONAL','EXTRA')
    or v_minimum_text !~ '^\d+$'
    or case when v_minimum_text ~ '^\d+$' then v_minimum_text::integer else 1 end<>0
    or lower(coalesce(p_data->>'shiftObligation','false')) in ('true','t','1','yes')
    or nullif(trim(p_data->>'shiftPeriod'),'') is not null
  ) then
    raise exception 'ROLE_DUTY_COMPETENCY_ONLY_USE_EXACT_SHIFT_STAFFING';
  end if;
  return public.matrix_v2_admin_save_before_mx_k10(
    p_kind,p_id,
    case when upper(trim(p_kind))='ROLE_DUTY' then
      p_data||jsonb_build_object(
        'assignmentMode',case when v_mode='EXTRA' then 'EXTRA' else 'OPTIONAL' end,
        'minimumCount',0,'shiftObligation',false,'shiftPeriod',null
      )
    else p_data end
  );
end;
$_$;


ALTER FUNCTION "public"."matrix_v2_admin_save_before_b4f118"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_admin_save_before_b4f118"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_admin_save_before_b4f118"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") IS 'MX-K10: role-duty is competency-only. Use exact shift staffing for every required count.';


--
-- Name: matrix_v2_admin_save_before_categories_uat_v1("text", "uuid", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_admin_save_before_categories_uat_v1"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_kind text:=upper(trim(p_kind));
  v_result jsonb;
  v_id uuid;
  v_period text;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  v_result:=public.matrix_v2_admin_save(v_kind,p_id,p_data);
  v_id:=(v_result->>'id')::uuid;
  if v_kind='SHIFT' then
    v_period:=upper(coalesce(p_data->>'shiftPeriod','MIDDLE'));
    if v_period not in ('MORNING','MIDDLE','EVENING') then
      raise exception 'INVALID_SHIFT_PERIOD';
    end if;
    update public.matrix_shift_templates_v2 set shift_period=v_period,
      updated_at=now() where id=v_id;
  elsif v_kind='ROLE_DUTY' then
    v_period:=nullif(upper(p_data->>'shiftPeriod'),'');
    if coalesce((p_data->>'shiftObligation')::boolean,false)
      and v_period not in ('MORNING','MIDDLE','EVENING') then
      raise exception 'SHIFT_PERIOD_REQUIRED';
    end if;
    update public.matrix_role_duties_v2 set
      shift_obligation=coalesce((p_data->>'shiftObligation')::boolean,false),
      shift_period=case when coalesce((p_data->>'shiftObligation')::boolean,false)
        then v_period else null end
    where id=v_id;
  end if;
  return v_result;
end;
$$;


ALTER FUNCTION "public"."matrix_v2_admin_save_before_categories_uat_v1"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") OWNER TO "postgres";

--
-- Name: matrix_v2_admin_save_before_mx_k10("text", "uuid", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_admin_save_before_mx_k10"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_payload jsonb:=coalesce(p_data,'{}'::jsonb);
  v_groups jsonb:='[]'::jsonb;
  v_group jsonb;
  v_matrix uuid;
  v_category uuid;
  v_result jsonb;
begin
  if upper(trim(p_kind))='MATRIX_SETTINGS' then
    v_groups:=coalesce(v_payload->'standbyGroups','[]'::jsonb);
    if jsonb_typeof(v_groups)<>'array' then raise exception 'INVALID_STANDBY_GROUPS'; end if;
    select id into v_matrix from public.matrix_versions
    where status='DRAFT' and schema_version>=2 order by version desc limit 1;
    if v_matrix is null then raise exception 'MATRIX_V2_DRAFT_NOT_FOUND'; end if;
    if exists(
      select 1 from jsonb_array_elements(v_groups) item
      where coalesce(item.value->>'code','') !~ '^[A-Za-z0-9_\-]{1,80}$'
        or length(trim(coalesce(item.value->>'name',''))) < 1
        or coalesce(item.value->>'categoryCode','') = ''
        or jsonb_typeof(coalesce(item.value->'roleCodes','null'::jsonb)) <> 'array'
        or jsonb_array_length(coalesce(item.value->'roleCodes','[]'::jsonb)) = 0
        or coalesce(item.value->>'tiers','') !~ '^[12]$'
    ) then raise exception 'INVALID_STANDBY_GROUP'; end if;
    for v_group in select value from jsonb_array_elements(v_groups) loop
      select category.id into v_category from public.matrix_role_categories_v2 category
      where category.matrix_version_id=v_matrix and category.active
        and upper(category.code)=upper(v_group->>'categoryCode');
      if v_category is null then raise exception 'STANDBY_GROUP_CATEGORY_NOT_FOUND:%',v_group->>'categoryCode'; end if;
      if exists(
        select 1 from jsonb_array_elements_text(v_group->'roleCodes') role_code
        where not exists(select 1 from public.matrix_roles_v2 role_row
          where role_row.matrix_version_id=v_matrix and role_row.active
            and role_row.category_id=v_category and upper(role_row.code)=upper(role_code.value))
      ) then raise exception 'STANDBY_GROUP_ROLE_NOT_FOUND_OR_WRONG_CATEGORY:%',v_group->>'code'; end if;
    end loop;
    if exists(
      select upper(role_code.value)
      from jsonb_array_elements(v_groups) item
      cross join lateral jsonb_array_elements_text(item.value->'roleCodes') role_code
      group by upper(role_code.value) having count(*)>1
    ) then raise exception 'STANDBY_ROLE_USED_IN_MULTIPLE_GROUPS'; end if;
    v_payload:=v_payload||jsonb_build_object('standbyTiersPerRoleDay',0,'standbyGroups',v_groups);
  end if;
  v_result:=public.matrix_v2_admin_save_before_standby_groups_uat_v1(p_kind,p_id,v_payload);
  if upper(trim(p_kind))='MATRIX_SETTINGS' then
    update public.matrix_versions set settings=jsonb_set(
      jsonb_set(coalesce(settings,'{}'::jsonb),'{standbyTiersPerRoleDay}','0'::jsonb,true),
      '{standbyGroups}',v_groups,true
    ) where id=(v_result->>'id')::uuid;
  end if;
  return v_result;
end;
$_$;


ALTER FUNCTION "public"."matrix_v2_admin_save_before_mx_k10"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") OWNER TO "postgres";

--
-- Name: matrix_v2_admin_save_before_standby_groups_uat_v1("text", "uuid", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_admin_save_before_standby_groups_uat_v1"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_result jsonb;
  v_id uuid;
  v_matrix uuid;
  v_category uuid;
  v_category_code text;
  v_payload jsonb:=coalesce(p_data,'{}'::jsonb);
  v_mode text;
  v_priority integer;
begin
  if upper(trim(p_kind))='ROLE' then
    select id into v_matrix from public.matrix_versions
    where status='DRAFT' and schema_version>=2 order by version desc limit 1;
    if v_matrix is null then raise exception 'MATRIX_V2_DRAFT_NOT_FOUND'; end if;

    if pg_catalog.pg_input_is_valid(coalesce(v_payload->>'categoryId',''),'uuid') then
      v_category:=(v_payload->>'categoryId')::uuid;
    end if;
    v_category_code:=upper(trim(coalesce(nullif(v_payload->>'categoryCode',''),v_payload->>'code','')));
    if v_category is null then
      select id into v_category from public.matrix_role_categories_v2
      where matrix_version_id=v_matrix and code=v_category_code and active
      order by sort_order,id limit 1;
    end if;
    if v_category is null or not exists(
      select 1 from public.matrix_role_categories_v2
      where id=v_category and matrix_version_id=v_matrix and active
    ) then
      raise exception 'ROLE_CATEGORY_NOT_FOUND|%|%',coalesce(v_payload->>'code',''),v_category_code;
    end if;
    v_payload:=v_payload||jsonb_build_object('categoryId',v_category);
  end if;

  v_result:=public.matrix_v2_admin_save_before_categories_uat_v1(p_kind,p_id,v_payload);
  v_id:=(v_result->>'id')::uuid;

  if upper(trim(p_kind))='ROLE' then
    update public.matrix_roles_v2 set category_id=v_category,updated_at=now() where id=v_id;
  elsif upper(trim(p_kind))='EMPLOYEE_ROLE' then
    v_mode:=case upper(coalesce(nullif(v_payload->>'assignmentMode',''),'STANDARD'))
      when 'BACKUP' then 'BACKUP' else 'STANDARD' end;
    v_priority:=greatest(1,least(999,coalesce(nullif(v_payload->>'backupPriority','')::integer,100)));
    update public.matrix_employee_roles_v2 set
      assignment_mode=case when is_primary then 'STANDARD' else v_mode end,
      backup_priority=v_priority,updated_by=auth.uid(),updated_at=now()
    where id=v_id;
  end if;
  return v_result;
end;
$$;


ALTER FUNCTION "public"."matrix_v2_admin_save_before_standby_groups_uat_v1"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") OWNER TO "postgres";

--
-- Name: matrix_v2_admin_save_before_standby_setting("text", "uuid", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_admin_save_before_standby_setting"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_kind text:=upper(trim(p_kind));
  v_matrix uuid;
  v_id uuid;
  v_logical uuid;
  v_ref1 uuid;
  v_ref2 uuid;
  v_ref3 uuid;
  v_ref4 uuid;
begin
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if p_data is null or jsonb_typeof(p_data)<>'object' then
    raise exception 'OBJECT_PAYLOAD_REQUIRED';
  end if;
  v_matrix:=public.matrix_v2_create_draft(null);

  if v_kind='MATRIX_SETTINGS' then
    if not public.matrix_v2_is_iso_4217_currency(
      upper(trim(coalesce(p_data->>'currency','')))
    ) then
      raise exception 'INVALID_MATRIX_CURRENCY';
    end if;
    if nullif(p_data->>'timezone','') is null or not exists(
      select 1 from pg_catalog.pg_timezone_names tz
      where tz.name=p_data->>'timezone'
    ) then raise exception 'INVALID_MATRIX_TIMEZONE'; end if;
    if coalesce(p_data->>'minimumRestMinutes','') !~ '^[0-9]+$'
      or (p_data->>'minimumRestMinutes')::integer<0
      or coalesce(p_data->>'maximumShiftsPerDay','') !~ '^[0-9]+$'
      or (p_data->>'maximumShiftsPerDay')::integer not between 1 and 24
      or jsonb_typeof(p_data->'missingAvailabilityMeansAvailable')<>'boolean'
      or jsonb_typeof(p_data->'requireOptimal')<>'boolean' then
      raise exception 'INVALID_MATRIX_LIMITS';
    end if;
    update public.matrix_versions mv set settings=coalesce(mv.settings,'{}'::jsonb)
      ||jsonb_build_object(
        'currency',upper(trim(p_data->>'currency')),
        'timezone',p_data->>'timezone',
        'minimumRestMinutes',(p_data->>'minimumRestMinutes')::integer,
        'maximumShiftsPerDay',(p_data->>'maximumShiftsPerDay')::integer,
        'missingAvailabilityMeansAvailable',
          (p_data->>'missingAvailabilityMeansAvailable')::boolean,
        'requireOptimal',(p_data->>'requireOptimal')::boolean
      )
    where mv.id=v_matrix
    returning mv.id into v_id;

  elsif v_kind='ROLE' then
    if p_id is not null then
      select r.logical_id into v_logical from public.matrix_roles_v2 r where r.id=p_id;
      select r.id into v_id from public.matrix_roles_v2 r
        where r.matrix_version_id=v_matrix and r.logical_id=v_logical;
    end if;
    if v_id is null then
      insert into public.matrix_roles_v2(
        matrix_version_id,logical_id,code,name,color,sort_order,active
      ) values(
        v_matrix,gen_random_uuid(),upper(trim(p_data->>'code')),trim(p_data->>'name'),
        coalesce(nullif(p_data->>'color',''),'#7257d8'),
        coalesce((p_data->>'sortOrder')::integer,0),
        coalesce((p_data->>'active')::boolean,true)
      ) returning id into v_id;
    else
      update public.matrix_roles_v2 set
        code=upper(coalesce(nullif(trim(p_data->>'code'),''),code)),
        name=coalesce(nullif(trim(p_data->>'name'),''),name),
        color=coalesce(nullif(p_data->>'color',''),color),
        sort_order=coalesce((p_data->>'sortOrder')::integer,sort_order),
        active=coalesce((p_data->>'active')::boolean,active),updated_at=now()
      where id=v_id and matrix_version_id=v_matrix;
    end if;

  elsif v_kind='LOCATION' then
    if nullif(p_data->>'timezone','') is not null and not exists(
      select 1 from pg_catalog.pg_timezone_names tz
      where tz.name=p_data->>'timezone'
    ) then raise exception 'INVALID_LOCATION_TIMEZONE'; end if;
    if p_id is not null then
      select l.logical_id into v_logical from public.matrix_locations_v2 l where l.id=p_id;
      select l.id into v_id from public.matrix_locations_v2 l
        where l.matrix_version_id=v_matrix and l.logical_id=v_logical;
    end if;
    if v_id is null then
      insert into public.matrix_locations_v2(
        matrix_version_id,logical_id,code,name,timezone,sort_order,active
      ) values(
        v_matrix,gen_random_uuid(),upper(trim(p_data->>'code')),trim(p_data->>'name'),
        coalesce(
          nullif(p_data->>'timezone',''),
          (select nullif(mv.settings->>'timezone','')
            from public.matrix_versions mv where mv.id=v_matrix)
        ),
        coalesce((p_data->>'sortOrder')::integer,0),
        coalesce((p_data->>'active')::boolean,true)
      ) returning id into v_id;
    else
      update public.matrix_locations_v2 set
        code=upper(coalesce(nullif(trim(p_data->>'code'),''),code)),
        name=coalesce(nullif(trim(p_data->>'name'),''),name),
        timezone=coalesce(nullif(p_data->>'timezone',''),timezone),
        sort_order=coalesce((p_data->>'sortOrder')::integer,sort_order),
        active=coalesce((p_data->>'active')::boolean,active),updated_at=now()
      where id=v_id and matrix_version_id=v_matrix;
    end if;

  elsif v_kind='DUTY' then
    if p_id is not null then
      select d.logical_id into v_logical from public.matrix_duties_v2 d where d.id=p_id;
      select d.id into v_id from public.matrix_duties_v2 d
        where d.matrix_version_id=v_matrix and d.logical_id=v_logical;
    end if;
    if v_id is null then
      insert into public.matrix_duties_v2(
        matrix_version_id,logical_id,code,name,description,color,sort_order,active
      ) values(
        v_matrix,gen_random_uuid(),upper(trim(p_data->>'code')),trim(p_data->>'name'),
        nullif(p_data->>'description',''),coalesce(nullif(p_data->>'color',''),'#4a8d78'),
        coalesce((p_data->>'sortOrder')::integer,0),
        coalesce((p_data->>'active')::boolean,true)
      ) returning id into v_id;
    else
      update public.matrix_duties_v2 set
        code=upper(coalesce(nullif(trim(p_data->>'code'),''),code)),
        name=coalesce(nullif(trim(p_data->>'name'),''),name),
        description=case when p_data ? 'description' then nullif(p_data->>'description','') else description end,
        color=coalesce(nullif(p_data->>'color',''),color),
        sort_order=coalesce((p_data->>'sortOrder')::integer,sort_order),
        active=coalesce((p_data->>'active')::boolean,active),updated_at=now()
      where id=v_id and matrix_version_id=v_matrix;
    end if;

  elsif v_kind='SHIFT' then
    if nullif(p_data->>'locationId','') is not null then
      select target.id into v_ref1
      from public.matrix_locations_v2 source
      join public.matrix_locations_v2 target
        on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
      where source.id=(p_data->>'locationId')::uuid;
    elsif p_id is not null then
      select target.id into v_ref1
      from public.matrix_shift_templates_v2 source_shift
      join public.matrix_locations_v2 source on source.id=source_shift.location_id
      join public.matrix_locations_v2 target
        on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
      where source_shift.id=p_id;
    end if;
    if v_ref1 is null then raise exception 'LOCATION_NOT_IN_MATRIX_V2'; end if;
    if p_id is not null then
      select s.logical_id into v_logical from public.matrix_shift_templates_v2 s where s.id=p_id;
      select s.id into v_id from public.matrix_shift_templates_v2 s
        where s.matrix_version_id=v_matrix and s.logical_id=v_logical;
    end if;
    if v_id is null then
      insert into public.matrix_shift_templates_v2(
        matrix_version_id,logical_id,location_id,code,name,starts_at,ends_at,
        ends_next_day,day_mask,sort_order,active
      ) values(
        v_matrix,gen_random_uuid(),v_ref1,upper(trim(p_data->>'code')),trim(p_data->>'name'),
        (p_data->>'startsAt')::time,(p_data->>'endsAt')::time,
        coalesce((p_data->>'endsNextDay')::boolean,
          (p_data->>'endsAt')::time<=(p_data->>'startsAt')::time),
        case when p_data ? 'days' then
          array(select value::smallint from jsonb_array_elements_text(p_data->'days'))
          else array[1,2,3,4,5,6,7]::smallint[] end,
        coalesce((p_data->>'sortOrder')::integer,0),
        coalesce((p_data->>'active')::boolean,true)
      ) returning id into v_id;
    else
      update public.matrix_shift_templates_v2 set
        location_id=v_ref1,
        code=upper(coalesce(nullif(trim(p_data->>'code'),''),code)),
        name=coalesce(nullif(trim(p_data->>'name'),''),name),
        starts_at=coalesce((p_data->>'startsAt')::time,starts_at),
        ends_at=coalesce((p_data->>'endsAt')::time,ends_at),
        ends_next_day=coalesce((p_data->>'endsNextDay')::boolean,ends_next_day),
        day_mask=case when p_data ? 'days' then
          array(select value::smallint from jsonb_array_elements_text(p_data->'days'))
          else day_mask end,
        sort_order=coalesce((p_data->>'sortOrder')::integer,sort_order),
        active=coalesce((p_data->>'active')::boolean,active),updated_at=now()
      where id=v_id and matrix_version_id=v_matrix;
    end if;

  elsif v_kind='ROLE_DUTY' then
    select target.id into v_ref1 from public.matrix_roles_v2 source
    join public.matrix_roles_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=(p_data->>'roleId')::uuid;
    select target.id into v_ref2 from public.matrix_duties_v2 source
    join public.matrix_duties_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=(p_data->>'dutyId')::uuid;
    if v_ref1 is null or v_ref2 is null then raise exception 'ROLE_OR_DUTY_NOT_IN_MATRIX_V2'; end if;
    insert into public.matrix_role_duties_v2(
      id,matrix_version_id,role_id,duty_id,assignment_mode,minimum_count,active
    ) values(
      gen_random_uuid(),v_matrix,v_ref1,v_ref2,
      coalesce(nullif(upper(p_data->>'assignmentMode'),''),'OPTIONAL'),
      coalesce((p_data->>'minimumCount')::integer,0),
      coalesce((p_data->>'active')::boolean,true)
    ) on conflict(matrix_version_id,role_id,duty_id) do update set
      assignment_mode=excluded.assignment_mode,minimum_count=excluded.minimum_count,
      active=excluded.active
    returning id into v_id;

  elsif v_kind='SCENARIO' then
    if p_id is not null then
      select s.logical_id into v_logical from public.matrix_scenarios_v2 s where s.id=p_id;
      select s.id into v_id from public.matrix_scenarios_v2 s
        where s.matrix_version_id=v_matrix and s.logical_id=v_logical;
    end if;
    v_ref1:=null;
    if p_data ? 'parentScenarioId' then
      if nullif(p_data->>'parentScenarioId','') is not null then
        select target.id into v_ref1 from public.matrix_scenarios_v2 source
        join public.matrix_scenarios_v2 target
          on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
        where source.id=(p_data->>'parentScenarioId')::uuid;
        if v_ref1 is null then raise exception 'PARENT_SCENARIO_NOT_IN_MATRIX_V2'; end if;
      end if;
    elsif v_id is not null then
      select s.parent_scenario_id into v_ref1 from public.matrix_scenarios_v2 s
      where s.id=v_id;
    end if;
    if coalesce((p_data->>'isDefault')::boolean,false) then
      update public.matrix_scenarios_v2 set is_default=false,updated_at=now()
      where matrix_version_id=v_matrix and is_default;
    end if;
    if v_id is null then
      insert into public.matrix_scenarios_v2(
        matrix_version_id,logical_id,parent_scenario_id,code,name,description,color,
        is_default,active,sort_order,valid_from,valid_to,settings_overrides
      ) values(
        v_matrix,gen_random_uuid(),v_ref1,upper(trim(p_data->>'code')),trim(p_data->>'name'),
        nullif(p_data->>'description',''),coalesce(nullif(p_data->>'color',''),'#7457e8'),
        coalesce((p_data->>'isDefault')::boolean,false),
        coalesce((p_data->>'active')::boolean,true),
        coalesce((p_data->>'sortOrder')::integer,0),
        nullif(p_data->>'validFrom','')::date,nullif(p_data->>'validTo','')::date,
        coalesce(p_data->'settingsOverrides','{}'::jsonb)
      ) returning id into v_id;
    else
      update public.matrix_scenarios_v2 set
        parent_scenario_id=v_ref1,
        code=upper(coalesce(nullif(trim(p_data->>'code'),''),code)),
        name=coalesce(nullif(trim(p_data->>'name'),''),name),
        description=case when p_data ? 'description' then nullif(p_data->>'description','') else description end,
        color=coalesce(nullif(p_data->>'color',''),color),
        is_default=coalesce((p_data->>'isDefault')::boolean,is_default),
        active=coalesce((p_data->>'active')::boolean,active),
        sort_order=coalesce((p_data->>'sortOrder')::integer,sort_order),
        valid_from=case when p_data ? 'validFrom' then nullif(p_data->>'validFrom','')::date else valid_from end,
        valid_to=case when p_data ? 'validTo' then nullif(p_data->>'validTo','')::date else valid_to end,
        settings_overrides=coalesce(p_data->'settingsOverrides',settings_overrides),updated_at=now()
      where id=v_id and matrix_version_id=v_matrix;
    end if;

  elsif v_kind='STAFFING_RULE' then
    select target.id into v_ref1 from public.matrix_scenarios_v2 source
    join public.matrix_scenarios_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=(p_data->>'scenarioId')::uuid;
    select target.id into v_ref2 from public.matrix_shift_templates_v2 source
    join public.matrix_shift_templates_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=(p_data->>'shiftTemplateId')::uuid;
    select target.id into v_ref3 from public.matrix_roles_v2 source
    join public.matrix_roles_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=(p_data->>'roleId')::uuid;
    v_ref4:=null;
    if nullif(p_data->>'dutyId','') is not null then
      select target.id into v_ref4 from public.matrix_duties_v2 source
      join public.matrix_duties_v2 target
        on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
      where source.id=(p_data->>'dutyId')::uuid;
    end if;
    if v_ref1 is null or v_ref2 is null or v_ref3 is null then
      raise exception 'STAFFING_SCOPE_NOT_IN_MATRIX_V2';
    end if;
    insert into public.matrix_staffing_rules_v2(
      id,matrix_version_id,scenario_id,shift_template_id,role_id,duty_id,
      operation,count_value,multiplier_basis_points,active,source_metadata
    ) values(
      gen_random_uuid(),v_matrix,v_ref1,v_ref2,v_ref3,v_ref4,
      upper(p_data->>'operation'),nullif(p_data->>'countValue','')::integer,
      nullif(p_data->>'multiplierBasisPoints','')::integer,
      coalesce((p_data->>'active')::boolean,true),
      coalesce(p_data->'sourceMetadata','{}'::jsonb)
    ) on conflict(scenario_id,shift_template_id,role_id,duty_id) do update set
      operation=excluded.operation,count_value=excluded.count_value,
      multiplier_basis_points=excluded.multiplier_basis_points,
      active=excluded.active,source_metadata=excluded.source_metadata,updated_at=now()
    returning id into v_id;

  elsif v_kind='STRATEGY' then
    if p_id is not null then
      select s.logical_id into v_logical from public.matrix_strategies_v2 s where s.id=p_id;
      select s.id into v_id from public.matrix_strategies_v2 s
        where s.matrix_version_id=v_matrix and s.logical_id=v_logical;
    end if;
    if v_id is null then
      insert into public.matrix_strategies_v2(
        matrix_version_id,logical_id,code,name,description,solver_code,solver_options,
        sort_order,active
      ) values(
        v_matrix,gen_random_uuid(),upper(trim(p_data->>'code')),trim(p_data->>'name'),
        nullif(p_data->>'description',''),coalesce(nullif(p_data->>'solverCode',''),'CP_SAT'),
        coalesce(p_data->'solverOptions','{}'::jsonb),
        coalesce((p_data->>'sortOrder')::integer,0),
        coalesce((p_data->>'active')::boolean,true)
      ) returning id into v_id;
    else
      update public.matrix_strategies_v2 set
        code=upper(coalesce(nullif(trim(p_data->>'code'),''),code)),
        name=coalesce(nullif(trim(p_data->>'name'),''),name),
        description=case when p_data ? 'description' then nullif(p_data->>'description','') else description end,
        solver_code=coalesce(nullif(p_data->>'solverCode',''),solver_code),
        solver_options=coalesce(p_data->'solverOptions',solver_options),
        sort_order=coalesce((p_data->>'sortOrder')::integer,sort_order),
        active=coalesce((p_data->>'active')::boolean,active),updated_at=now()
      where id=v_id and matrix_version_id=v_matrix;
    end if;

  elsif v_kind='OBJECTIVE' then
    select target.id into v_ref1 from public.matrix_strategies_v2 source
    join public.matrix_strategies_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=(p_data->>'strategyId')::uuid;
    if v_ref1 is null then raise exception 'STRATEGY_NOT_IN_MATRIX_V2'; end if;
    insert into public.matrix_strategy_objectives_v2(
      id,matrix_version_id,strategy_id,tier,sort_order,metric_code,direction,
      weight,tolerance,parameters,active
    ) values(
      gen_random_uuid(),v_matrix,v_ref1,(p_data->>'tier')::smallint,
      coalesce((p_data->>'sortOrder')::integer,0),upper(trim(p_data->>'metricCode')),
      coalesce(nullif(upper(p_data->>'direction'),''),'MINIMIZE'),
      coalesce((p_data->>'weight')::bigint,1),coalesce((p_data->>'tolerance')::bigint,0),
      coalesce(p_data->'parameters','{}'::jsonb),coalesce((p_data->>'active')::boolean,true)
    ) on conflict(strategy_id,tier,metric_code) do update set
      sort_order=excluded.sort_order,direction=excluded.direction,weight=excluded.weight,
      tolerance=excluded.tolerance,parameters=excluded.parameters,active=excluded.active
    returning id into v_id;

  elsif v_kind='SCENARIO_STRATEGY' then
    select target.id into v_ref1 from public.matrix_scenarios_v2 source
    join public.matrix_scenarios_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=(p_data->>'scenarioId')::uuid;
    select target.id into v_ref2 from public.matrix_strategies_v2 source
    join public.matrix_strategies_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=(p_data->>'strategyId')::uuid;
    if v_ref1 is null or v_ref2 is null then raise exception 'SCENARIO_OR_STRATEGY_NOT_IN_MATRIX_V2'; end if;
    insert into public.matrix_scenario_strategies_v2(
      id,matrix_version_id,scenario_id,strategy_id,sort_order,active,
      objective_overrides,solver_overrides
    ) values(
      gen_random_uuid(),v_matrix,v_ref1,v_ref2,
      coalesce((p_data->>'sortOrder')::integer,0),
      coalesce((p_data->>'active')::boolean,true),
      coalesce(p_data->'objectiveOverrides','{}'::jsonb),
      coalesce(p_data->'solverOverrides','{}'::jsonb)
    ) on conflict(scenario_id,strategy_id) do update set
      sort_order=excluded.sort_order,active=excluded.active,
      objective_overrides=excluded.objective_overrides,
      solver_overrides=excluded.solver_overrides
    returning id into v_id;

  elsif v_kind='PAY_RULE' then
    if p_id is not null then
      select p.logical_id into v_logical from public.matrix_pay_rules_v2 p where p.id=p_id;
      select p.id into v_id from public.matrix_pay_rules_v2 p
        where p.matrix_version_id=v_matrix and p.logical_id=v_logical;
    end if;
    if v_id is null then
      insert into public.matrix_pay_rules_v2(
        matrix_version_id,logical_id,code,name,description,calculation_method,
        amount_minor,rate_minor_per_hour,percent_basis_points,multiplier_basis_points,
        threshold_minutes,currency,priority,stacking_group,stacking_mode,day_mask,
        local_start,local_end,ends_next_day,valid_from,valid_to,condition_expression,
        formula_expression,active
      ) values(
        v_matrix,gen_random_uuid(),upper(trim(p_data->>'code')),trim(p_data->>'name'),
        nullif(p_data->>'description',''),upper(p_data->>'calculationMethod'),
        nullif(p_data->>'amountMinor','')::bigint,
        nullif(p_data->>'rateMinorPerHour','')::bigint,
        nullif(p_data->>'percentBasisPoints','')::integer,
        nullif(p_data->>'multiplierBasisPoints','')::integer,
        nullif(p_data->>'thresholdMinutes','')::integer,
        coalesce(
          nullif(upper(p_data->>'currency'),''),
          (select upper(mv.settings->>'currency')
            from public.matrix_versions mv where mv.id=v_matrix)
        ),
        coalesce((p_data->>'priority')::integer,100),nullif(p_data->>'stackingGroup',''),
        coalesce(nullif(upper(p_data->>'stackingMode'),''),'STACK'),
        case when p_data ? 'days' then array(select value::smallint from jsonb_array_elements_text(p_data->'days'))
          else array[1,2,3,4,5,6,7]::smallint[] end,
        nullif(p_data->>'localStart','')::time,nullif(p_data->>'localEnd','')::time,
        coalesce((p_data->>'endsNextDay')::boolean,false),
        nullif(p_data->>'validFrom','')::date,nullif(p_data->>'validTo','')::date,
        coalesce(p_data->'conditionExpression','{}'::jsonb),
        coalesce(p_data->'formulaExpression','{}'::jsonb),
        coalesce((p_data->>'active')::boolean,true)
      ) returning id into v_id;
    else
      update public.matrix_pay_rules_v2 set
        code=upper(coalesce(nullif(trim(p_data->>'code'),''),code)),
        name=coalesce(nullif(trim(p_data->>'name'),''),name),
        description=case when p_data ? 'description' then nullif(p_data->>'description','') else description end,
        calculation_method=coalesce(nullif(upper(p_data->>'calculationMethod'),''),calculation_method),
        amount_minor=case when p_data ? 'amountMinor' then nullif(p_data->>'amountMinor','')::bigint else amount_minor end,
        rate_minor_per_hour=case when p_data ? 'rateMinorPerHour' then nullif(p_data->>'rateMinorPerHour','')::bigint else rate_minor_per_hour end,
        percent_basis_points=case when p_data ? 'percentBasisPoints' then nullif(p_data->>'percentBasisPoints','')::integer else percent_basis_points end,
        multiplier_basis_points=case when p_data ? 'multiplierBasisPoints' then nullif(p_data->>'multiplierBasisPoints','')::integer else multiplier_basis_points end,
        threshold_minutes=case when p_data ? 'thresholdMinutes' then nullif(p_data->>'thresholdMinutes','')::integer else threshold_minutes end,
        currency=coalesce(nullif(upper(p_data->>'currency'),''),currency),
        priority=coalesce((p_data->>'priority')::integer,priority),
        stacking_group=case when p_data ? 'stackingGroup' then nullif(p_data->>'stackingGroup','') else stacking_group end,
        stacking_mode=coalesce(nullif(upper(p_data->>'stackingMode'),''),stacking_mode),
        day_mask=case when p_data ? 'days' then array(select value::smallint from jsonb_array_elements_text(p_data->'days')) else day_mask end,
        local_start=case when p_data ? 'localStart' then nullif(p_data->>'localStart','')::time else local_start end,
        local_end=case when p_data ? 'localEnd' then nullif(p_data->>'localEnd','')::time else local_end end,
        ends_next_day=coalesce((p_data->>'endsNextDay')::boolean,ends_next_day),
        valid_from=case when p_data ? 'validFrom' then nullif(p_data->>'validFrom','')::date else valid_from end,
        valid_to=case when p_data ? 'validTo' then nullif(p_data->>'validTo','')::date else valid_to end,
        condition_expression=coalesce(p_data->'conditionExpression',condition_expression),
        formula_expression=coalesce(p_data->'formulaExpression',formula_expression),
        active=coalesce((p_data->>'active')::boolean,active),updated_at=now()
      where id=v_id and matrix_version_id=v_matrix;
    end if;

    if p_data ? 'roleIds' then
      delete from public.matrix_pay_rule_roles_v2 where pay_rule_id=v_id;
      insert into public.matrix_pay_rule_roles_v2(matrix_version_id,pay_rule_id,role_id)
      select distinct v_matrix,v_id,target.id
      from jsonb_array_elements_text(p_data->'roleIds') x(value)
      join public.matrix_roles_v2 source on source.id=x.value::uuid
      join public.matrix_roles_v2 target
        on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id;
    end if;
    if p_data ? 'dutyIds' then
      delete from public.matrix_pay_rule_duties_v2 where pay_rule_id=v_id;
      insert into public.matrix_pay_rule_duties_v2(matrix_version_id,pay_rule_id,duty_id)
      select distinct v_matrix,v_id,target.id
      from jsonb_array_elements_text(p_data->'dutyIds') x(value)
      join public.matrix_duties_v2 source on source.id=x.value::uuid
      join public.matrix_duties_v2 target
        on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id;
    end if;
    if p_data ? 'locationIds' then
      delete from public.matrix_pay_rule_locations_v2 where pay_rule_id=v_id;
      insert into public.matrix_pay_rule_locations_v2(matrix_version_id,pay_rule_id,location_id)
      select distinct v_matrix,v_id,target.id
      from jsonb_array_elements_text(p_data->'locationIds') x(value)
      join public.matrix_locations_v2 source on source.id=x.value::uuid
      join public.matrix_locations_v2 target
        on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id;
    end if;
    if p_data ? 'shiftIds' then
      delete from public.matrix_pay_rule_shifts_v2 where pay_rule_id=v_id;
      insert into public.matrix_pay_rule_shifts_v2(matrix_version_id,pay_rule_id,shift_template_id)
      select distinct v_matrix,v_id,target.id
      from jsonb_array_elements_text(p_data->'shiftIds') x(value)
      join public.matrix_shift_templates_v2 source on source.id=x.value::uuid
      join public.matrix_shift_templates_v2 target
        on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id;
    end if;

  elsif v_kind='SCENARIO_PAY_RULE' then
    select target.id into v_ref1 from public.matrix_scenarios_v2 source
    join public.matrix_scenarios_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=(p_data->>'scenarioId')::uuid;
    select target.id into v_ref2 from public.matrix_pay_rules_v2 source
    join public.matrix_pay_rules_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=(p_data->>'payRuleId')::uuid;
    if v_ref1 is null or v_ref2 is null then
      raise exception 'SCENARIO_OR_PAY_RULE_NOT_IN_MATRIX_V2';
    end if;
    insert into public.matrix_scenario_pay_rule_overrides_v2(
      id,matrix_version_id,scenario_id,pay_rule_id,enabled,amount_minor,
      rate_minor_per_hour,percent_basis_points,multiplier_basis_points,formula_expression
    ) values(
      gen_random_uuid(),v_matrix,v_ref1,v_ref2,
      coalesce((p_data->>'enabled')::boolean,true),
      nullif(p_data->>'amountMinor','')::bigint,
      nullif(p_data->>'rateMinorPerHour','')::bigint,
      nullif(p_data->>'percentBasisPoints','')::integer,
      nullif(p_data->>'multiplierBasisPoints','')::integer,
      case when p_data ? 'formulaExpression' then p_data->'formulaExpression' else null end
    ) on conflict(scenario_id,pay_rule_id) do update set
      enabled=excluded.enabled,amount_minor=excluded.amount_minor,
      rate_minor_per_hour=excluded.rate_minor_per_hour,
      percent_basis_points=excluded.percent_basis_points,
      multiplier_basis_points=excluded.multiplier_basis_points,
      formula_expression=excluded.formula_expression
    returning id into v_id;

  elsif v_kind='SCENARIO_BUDGET' then
    select target.id into v_ref1 from public.matrix_scenarios_v2 source
    join public.matrix_scenarios_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=(p_data->>'scenarioId')::uuid;
    if v_ref1 is null then raise exception 'SCENARIO_NOT_IN_MATRIX_V2'; end if;
    v_ref2:=null; v_ref3:=null; v_ref4:=null;
    if nullif(p_data->>'locationId','') is not null then
      select target.id into v_ref2 from public.matrix_locations_v2 source
      join public.matrix_locations_v2 target
        on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
      where source.id=(p_data->>'locationId')::uuid;
      if v_ref2 is null then raise exception 'LOCATION_NOT_IN_MATRIX_V2'; end if;
    end if;
    if nullif(p_data->>'roleId','') is not null then
      select target.id into v_ref3 from public.matrix_roles_v2 source
      join public.matrix_roles_v2 target
        on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
      where source.id=(p_data->>'roleId')::uuid;
      if v_ref3 is null then raise exception 'ROLE_NOT_IN_MATRIX_V2'; end if;
    end if;
    if nullif(p_data->>'dutyId','') is not null then
      select target.id into v_ref4 from public.matrix_duties_v2 source
      join public.matrix_duties_v2 target
        on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
      where source.id=(p_data->>'dutyId')::uuid;
      if v_ref4 is null then raise exception 'DUTY_NOT_IN_MATRIX_V2'; end if;
    end if;
    insert into public.matrix_scenario_budgets_v2(
      id,matrix_version_id,scenario_id,budget_month,location_id,role_id,duty_id,
      operation,amount_minor,multiplier_basis_points,currency,hard_limit,
      warning_percent,source_metadata
    ) values(
      gen_random_uuid(),v_matrix,v_ref1,
      nullif(p_data->>'budgetMonth','')::date,v_ref2,v_ref3,v_ref4,
      coalesce(nullif(upper(p_data->>'operation'),''),'SET'),
      nullif(p_data->>'amountMinor','')::bigint,
      nullif(p_data->>'multiplierBasisPoints','')::integer,
      coalesce(
        nullif(upper(p_data->>'currency'),''),
        (select upper(mv.settings->>'currency')
          from public.matrix_versions mv where mv.id=v_matrix)
      ),
      nullif(p_data->>'hardLimit','')::boolean,
      nullif(p_data->>'warningPercent','')::integer,
      coalesce(p_data->'sourceMetadata','{}'::jsonb)
    ) on conflict(scenario_id,budget_month,location_id,role_id,duty_id) do update set
      operation=excluded.operation,amount_minor=excluded.amount_minor,
      multiplier_basis_points=excluded.multiplier_basis_points,
      currency=excluded.currency,hard_limit=excluded.hard_limit,
      warning_percent=excluded.warning_percent,
      source_metadata=excluded.source_metadata,updated_at=now()
    returning id into v_id;

  elsif v_kind='EMPLOYEE_ROLE' then
    select target.id into v_ref1 from public.matrix_roles_v2 source
    join public.matrix_roles_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=(p_data->>'roleId')::uuid;
    if v_ref1 is null then raise exception 'ROLE_NOT_IN_MATRIX_V2'; end if;
    if coalesce((p_data->>'isPrimary')::boolean,false) then
      update public.matrix_employee_roles_v2 set is_primary=false
      where matrix_version_id=v_matrix and employee_id=(p_data->>'employeeId')::uuid and is_primary;
    end if;
    insert into public.matrix_employee_roles_v2(
      id,matrix_version_id,employee_id,role_id,is_primary,can_lead,active,valid_from,valid_to
    ) values(
      gen_random_uuid(),v_matrix,(p_data->>'employeeId')::uuid,v_ref1,
      coalesce((p_data->>'isPrimary')::boolean,false),
      coalesce((p_data->>'canLead')::boolean,false),
      coalesce((p_data->>'active')::boolean,true),
      nullif(p_data->>'validFrom','')::date,nullif(p_data->>'validTo','')::date
    ) on conflict(matrix_version_id,employee_id,role_id) do update set
      is_primary=excluded.is_primary,can_lead=excluded.can_lead,active=excluded.active,
      valid_from=excluded.valid_from,valid_to=excluded.valid_to
    returning id into v_id;

  elsif v_kind='EMPLOYEE_LOCATION' then
    select target.id into v_ref1 from public.matrix_locations_v2 source
    join public.matrix_locations_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=(p_data->>'locationId')::uuid;
    if v_ref1 is null then raise exception 'LOCATION_NOT_IN_MATRIX_V2'; end if;
    insert into public.matrix_employee_locations_v2(
      id,matrix_version_id,employee_id,location_id,standard_allowed,overtime_allowed,
      home_location,active,valid_from,valid_to
    ) values(
      gen_random_uuid(),v_matrix,(p_data->>'employeeId')::uuid,v_ref1,
      coalesce((p_data->>'standardAllowed')::boolean,false),
      coalesce((p_data->>'overtimeAllowed')::boolean,false),
      coalesce((p_data->>'homeLocation')::boolean,false),
      coalesce((p_data->>'active')::boolean,true),
      nullif(p_data->>'validFrom','')::date,nullif(p_data->>'validTo','')::date
    ) on conflict(matrix_version_id,employee_id,location_id) do update set
      standard_allowed=excluded.standard_allowed,overtime_allowed=excluded.overtime_allowed,
      home_location=excluded.home_location,active=excluded.active,
      valid_from=excluded.valid_from,valid_to=excluded.valid_to
    returning id into v_id;

  elsif v_kind='EMPLOYEE_DUTY' then
    select target.id into v_ref1 from public.matrix_duties_v2 source
    join public.matrix_duties_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=(p_data->>'dutyId')::uuid;
    if v_ref1 is null then raise exception 'DUTY_NOT_IN_MATRIX_V2'; end if;
    v_ref2:=null; v_ref3:=null;
    if nullif(p_data->>'roleId','') is not null then
      select target.id into v_ref2 from public.matrix_roles_v2 source
      join public.matrix_roles_v2 target
        on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
      where source.id=(p_data->>'roleId')::uuid;
      if v_ref2 is null then raise exception 'ROLE_NOT_IN_MATRIX_V2'; end if;
    end if;
    if nullif(p_data->>'locationId','') is not null then
      select target.id into v_ref3 from public.matrix_locations_v2 source
      join public.matrix_locations_v2 target
        on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
      where source.id=(p_data->>'locationId')::uuid;
      if v_ref3 is null then raise exception 'LOCATION_NOT_IN_MATRIX_V2'; end if;
    end if;
    insert into public.matrix_employee_duties_v2(
      id,matrix_version_id,employee_id,duty_id,role_id,location_id,active,
      valid_from,valid_to,source
    ) values(
      gen_random_uuid(),v_matrix,(p_data->>'employeeId')::uuid,v_ref1,
      v_ref2,v_ref3,coalesce((p_data->>'active')::boolean,true),
      nullif(p_data->>'validFrom','')::date,nullif(p_data->>'validTo','')::date,'MATRIX_V2_ADMIN'
    ) on conflict(matrix_version_id,employee_id,duty_id,role_id,location_id) do update set
      active=excluded.active,valid_from=excluded.valid_from,valid_to=excluded.valid_to,
      source=excluded.source
    returning id into v_id;

  else
    raise exception 'UNSUPPORTED_MATRIX_V2_KIND: %',v_kind;
  end if;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_v2_'||lower(v_kind),v_id::text,'UPSERT',
    jsonb_build_object('matrixVersionId',v_matrix,'data',
      case when v_kind in ('PAY_RULE','SCENARIO_PAY_RULE','SCENARIO_BUDGET') then
        p_data-array['amountMinor','rateMinorPerHour','percentBasisPoints',
          'multiplierBasisPoints','formulaExpression']
      else p_data end));
  return jsonb_build_object('id',v_id,'kind',v_kind,'matrixVersionId',v_matrix);
end;
$_$;


ALTER FUNCTION "public"."matrix_v2_admin_save_before_standby_setting"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") OWNER TO "postgres";

--
-- Name: matrix_v2_can_manage_employee("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_can_manage_employee"("p_employee_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select auth.uid() is not null and (
    public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE')
    or exists(
      select 1 from public.employees employee
      where employee.id=p_employee_id and employee.auth_user_id=auth.uid()
    )
    or public.matrix_v2_scope_allows_resource_for_app_role_uat_v1(
      'ROLE_MANAGER',null,null,p_employee_id
    )
    or public.matrix_v2_scope_allows_resource_for_app_role_uat_v1(
      'LOCATION_MANAGER',null,null,p_employee_id
    )
  );
$$;


ALTER FUNCTION "public"."matrix_v2_can_manage_employee"("p_employee_id" "uuid") OWNER TO "postgres";

--
-- Name: matrix_v2_can_manage_legacy_assignment_uat_v1("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_can_manage_legacy_assignment_uat_v1"("p_assignment_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_role_code text;
  v_employee_id uuid;
  v_location_id uuid;
begin
  if auth.uid() is null or p_assignment_id is null then return false; end if;

  select assignment.assigned_role::text,assignment.employee_id,shift.location_id
  into v_role_code,v_employee_id,v_location_id
  from public.assignments assignment
  join public.shifts shift on shift.id=assignment.shift_id
  where assignment.id=p_assignment_id;

  if v_role_code is null or v_employee_id is null or v_location_id is null then
    return false;
  end if;

  return public.matrix_v2_can_manage_legacy_resource_uat_v1(
    v_role_code,v_location_id,v_employee_id
  );
end;
$$;


ALTER FUNCTION "public"."matrix_v2_can_manage_legacy_assignment_uat_v1"("p_assignment_id" "uuid") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_can_manage_legacy_assignment_uat_v1"("p_assignment_id" "uuid"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_can_manage_legacy_assignment_uat_v1"("p_assignment_id" "uuid") IS 'Phase 4A trusted assignment resource resolver; reads the actual shift location before canonical scoped authorization.';


--
-- Name: matrix_v2_can_manage_legacy_plan_issue_uat_v1("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_can_manage_legacy_plan_issue_uat_v1"("p_issue_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_role_code text;
  v_location_id uuid;
begin
  if auth.uid() is null or p_issue_id is null then return false; end if;

  select issue.role::text,shift.location_id
  into v_role_code,v_location_id
  from public.plan_issues issue
  join public.shifts shift on shift.id=issue.shift_id
  where issue.id=p_issue_id;

  if v_role_code is null or v_location_id is null then return false; end if;

  return public.matrix_v2_can_manage_legacy_resource_uat_v1(
    v_role_code,v_location_id,null
  );
end;
$$;


ALTER FUNCTION "public"."matrix_v2_can_manage_legacy_plan_issue_uat_v1"("p_issue_id" "uuid") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_can_manage_legacy_plan_issue_uat_v1"("p_issue_id" "uuid"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_can_manage_legacy_plan_issue_uat_v1"("p_issue_id" "uuid") IS 'Phase 4A trusted plan-issue resource resolver; reads the actual shift location before canonical scoped authorization.';


--
-- Name: matrix_v2_can_manage_legacy_resource_uat_v1("text", "uuid", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_can_manage_legacy_resource_uat_v1"("p_role_code" "text" DEFAULT NULL::"text", "p_legacy_location_id" "uuid" DEFAULT NULL::"uuid", "p_employee_id" "uuid" DEFAULT NULL::"uuid") RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_matrix_id uuid;
  v_match_count integer;
  v_role_id uuid;
  v_location_id uuid;
begin
  if auth.uid() is null then return false; end if;

  select count(*),(array_agg(matrix.id))[1] into v_match_count,v_matrix_id
  from public.matrix_versions matrix
  where matrix.status='ACTIVE';
  if v_match_count<>1 then return false; end if;

  if nullif(trim(coalesce(p_role_code,'')),'') is not null then
    select count(*),(array_agg(role.id))[1] into v_match_count,v_role_id
    from public.matrix_roles_v2 role
    where role.matrix_version_id=v_matrix_id and role.active
      and upper(role.code)=upper(trim(p_role_code));
    if v_match_count<>1 then return false; end if;
  end if;

  if p_legacy_location_id is not null then
    select count(*),(array_agg(matrix_location.id))[1] into v_match_count,v_location_id
    from public.locations legacy_location
    join public.matrix_locations_v2 matrix_location
      on upper(matrix_location.code::text)=upper(legacy_location.code::text)
    where legacy_location.id=p_legacy_location_id
      and matrix_location.matrix_version_id=v_matrix_id
      and matrix_location.active;
    if v_match_count<>1 then return false; end if;
  end if;

  return public.matrix_v2_can_manage_resource_uat_v1(
    v_role_id,v_location_id,p_employee_id
  );
end;
$$;


ALTER FUNCTION "public"."matrix_v2_can_manage_legacy_resource_uat_v1"("p_role_code" "text", "p_legacy_location_id" "uuid", "p_employee_id" "uuid") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_can_manage_legacy_resource_uat_v1"("p_role_code" "text", "p_legacy_location_id" "uuid", "p_employee_id" "uuid"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_can_manage_legacy_resource_uat_v1"("p_role_code" "text", "p_legacy_location_id" "uuid", "p_employee_id" "uuid") IS 'Phase 4A fail-closed adapter from legacy role/location resources to canonical active-Matrix scoped authorization.';


--
-- Name: matrix_v2_can_manage_resource_uat_v1("uuid", "uuid", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_can_manage_resource_uat_v1"("p_role_id" "uuid" DEFAULT NULL::"uuid", "p_location_id" "uuid" DEFAULT NULL::"uuid", "p_employee_id" "uuid" DEFAULT NULL::"uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select auth.uid() is not null and (
    public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.matrix_v2_scope_allows_resource_for_app_role_uat_v1(
      'ROLE_MANAGER',p_role_id,p_location_id,p_employee_id
    )
    or public.matrix_v2_scope_allows_resource_for_app_role_uat_v1(
      'LOCATION_MANAGER',p_role_id,p_location_id,p_employee_id
    )
  );
$$;


ALTER FUNCTION "public"."matrix_v2_can_manage_resource_uat_v1"("p_role_id" "uuid", "p_location_id" "uuid", "p_employee_id" "uuid") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_can_manage_resource_uat_v1"("p_role_id" "uuid", "p_location_id" "uuid", "p_employee_id" "uuid"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_can_manage_resource_uat_v1"("p_role_id" "uuid", "p_location_id" "uuid", "p_employee_id" "uuid") IS 'Fail-closed canonical role/location/employee resource authorization for manager scope grants.';


--
-- Name: matrix_v2_compare_versions_uat_v2("uuid", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_compare_versions_uat_v2"("p_left_version_id" "uuid", "p_right_version_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_left jsonb;
  v_right jsonb;
  v_sections jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if p_left_version_id is null or p_right_version_id is null
    or p_left_version_id=p_right_version_id then
    raise exception 'TWO_DIFFERENT_MATRIX_VERSIONS_REQUIRED';
  end if;
  v_left:=public.matrix_v2_content_document(p_left_version_id);
  v_right:=public.matrix_v2_content_document(p_right_version_id);
  if v_left is null or v_right is null then raise exception 'MATRIX_V2_NOT_FOUND'; end if;
  v_left:=v_left||jsonb_build_object('employeeProfiles',coalesce((
    select jsonb_agg(to_jsonb(profile)-array[
      'id','matrix_version_id','created_at','updated_at','created_by','updated_by'
    ] order by profile.employee_no)
    from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=p_left_version_id
  ),'[]'::jsonb));
  v_right:=v_right||jsonb_build_object('employeeProfiles',coalesce((
    select jsonb_agg(to_jsonb(profile)-array[
      'id','matrix_version_id','created_at','updated_at','created_by','updated_by'
    ] order by profile.employee_no)
    from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=p_right_version_id
  ),'[]'::jsonb));

  select jsonb_agg(jsonb_build_object(
    'key',section.key,'label',section.label,
    'leftCount',jsonb_array_length(coalesce(v_left->section.key,'[]'::jsonb)),
    'rightCount',jsonb_array_length(coalesce(v_right->section.key,'[]'::jsonb)),
    'changed',(v_left->section.key) is distinct from (v_right->section.key)
  ) order by section.ordinal)
  into v_sections
  from (values
    (1,'roles','Role'),(2,'locations','Lokale'),(3,'duties','Obowiązki'),
    (4,'shifts','Zmiany'),(5,'roleDuties','Powiązania ról i obowiązków'),
    (6,'staffingRules','Wymagana obsada'),(7,'scenarios','Scenariusze'),
    (8,'strategies','Warianty biznesowe'),(9,'objectives','Priorytety wariantów'),
    (10,'employeeProfiles','Profile i limity pracowników'),
    (11,'employeeRoles','Role pracowników'),(12,'employeeLocations','Lokale pracowników'),
    (13,'employeeDuties','Kompetencje pracowników'),(14,'payRules','Reguły płacowe'),
    (15,'scenarioBudgets','Budżety')
  ) section(ordinal,key,label);
  return jsonb_build_object(
    'leftVersionId',p_left_version_id,'rightVersionId',p_right_version_id,
    'settingsChanged',(v_left->'settings') is distinct from (v_right->'settings'),
    'sections',v_sections
  );
end;
$$;


ALTER FUNCTION "public"."matrix_v2_compare_versions_uat_v2"("p_left_version_id" "uuid", "p_right_version_id" "uuid") OWNER TO "postgres";

--
-- Name: matrix_v2_content_document("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_content_document"("p_matrix_version_id" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select jsonb_build_object(
    'settings',mv.settings,
    'roles',coalesce((select jsonb_agg(
      to_jsonb(x)-array['id','matrix_version_id','created_at','updated_at'] order by x.logical_id)
      from public.matrix_roles_v2 x where x.matrix_version_id=mv.id),'[]'::jsonb),
    'locations',coalesce((select jsonb_agg(
      to_jsonb(x)-array['id','matrix_version_id','created_at','updated_at'] order by x.logical_id)
      from public.matrix_locations_v2 x where x.matrix_version_id=mv.id),'[]'::jsonb),
    'duties',coalesce((select jsonb_agg(
      to_jsonb(x)-array['id','matrix_version_id','created_at','updated_at'] order by x.logical_id)
      from public.matrix_duties_v2 x where x.matrix_version_id=mv.id),'[]'::jsonb),
    'shifts',coalesce((select jsonb_agg(
      (to_jsonb(x)-array['id','matrix_version_id','location_id','created_at','updated_at'])
        ||jsonb_build_object('locationLogicalId',l.logical_id) order by x.logical_id)
      from public.matrix_shift_templates_v2 x
      join public.matrix_locations_v2 l on l.id=x.location_id
      where x.matrix_version_id=mv.id),'[]'::jsonb),
    'roleDuties',coalesce((select jsonb_agg(
      (to_jsonb(x)-array['id','matrix_version_id','role_id','duty_id','created_at'])
        ||jsonb_build_object('roleLogicalId',r.logical_id,'dutyLogicalId',d.logical_id)
        order by r.logical_id,d.logical_id)
      from public.matrix_role_duties_v2 x
      join public.matrix_roles_v2 r on r.id=x.role_id
      join public.matrix_duties_v2 d on d.id=x.duty_id
      where x.matrix_version_id=mv.id),'[]'::jsonb),
    'scenarios',coalesce((select jsonb_agg(
      (to_jsonb(x)-array['id','matrix_version_id','parent_scenario_id','created_at','updated_at'])
        ||jsonb_build_object('parentLogicalId',p.logical_id) order by x.logical_id)
      from public.matrix_scenarios_v2 x
      left join public.matrix_scenarios_v2 p on p.id=x.parent_scenario_id
      where x.matrix_version_id=mv.id),'[]'::jsonb),
    'staffingRules',coalesce((select jsonb_agg(
      (to_jsonb(x)-array['id','matrix_version_id','scenario_id','shift_template_id',
        'role_id','duty_id','created_at','updated_at'])
        ||jsonb_build_object('scenarioLogicalId',sc.logical_id,
          'shiftLogicalId',sh.logical_id,'roleLogicalId',r.logical_id,
          'dutyLogicalId',d.logical_id)
        order by sc.logical_id,sh.logical_id,r.logical_id,d.logical_id)
      from public.matrix_staffing_rules_v2 x
      join public.matrix_scenarios_v2 sc on sc.id=x.scenario_id
      join public.matrix_shift_templates_v2 sh on sh.id=x.shift_template_id
      join public.matrix_roles_v2 r on r.id=x.role_id
      left join public.matrix_duties_v2 d on d.id=x.duty_id
      where x.matrix_version_id=mv.id),'[]'::jsonb),
    'strategies',coalesce((select jsonb_agg(
      to_jsonb(x)-array['id','matrix_version_id','legacy_optimizer_profile_id',
        'created_at','updated_at'] order by x.logical_id)
      from public.matrix_strategies_v2 x where x.matrix_version_id=mv.id),'[]'::jsonb),
    'objectives',coalesce((select jsonb_agg(
      (to_jsonb(x)-array['id','matrix_version_id','strategy_id','created_at'])
        ||jsonb_build_object('strategyLogicalId',s.logical_id)
        order by s.logical_id,x.tier,x.sort_order,x.metric_code)
      from public.matrix_strategy_objectives_v2 x
      join public.matrix_strategies_v2 s on s.id=x.strategy_id
      where x.matrix_version_id=mv.id),'[]'::jsonb),
    'scenarioStrategies',coalesce((select jsonb_agg(
      (to_jsonb(x)-array['id','matrix_version_id','scenario_id','strategy_id','created_at'])
        ||jsonb_build_object('scenarioLogicalId',sc.logical_id,
          'strategyLogicalId',st.logical_id)
        order by sc.logical_id,x.sort_order,st.logical_id)
      from public.matrix_scenario_strategies_v2 x
      join public.matrix_scenarios_v2 sc on sc.id=x.scenario_id
      join public.matrix_strategies_v2 st on st.id=x.strategy_id
      where x.matrix_version_id=mv.id),'[]'::jsonb),
    'employeeRoles',coalesce((select jsonb_agg(
      (to_jsonb(x)-array['id','matrix_version_id','role_id','created_at'])
        ||jsonb_build_object('roleLogicalId',r.logical_id)
        order by x.employee_id,r.logical_id)
      from public.matrix_employee_roles_v2 x
      join public.matrix_roles_v2 r on r.id=x.role_id
      where x.matrix_version_id=mv.id),'[]'::jsonb),
    'employeeLocations',coalesce((select jsonb_agg(
      (to_jsonb(x)-array['id','matrix_version_id','location_id','created_at'])
        ||jsonb_build_object('locationLogicalId',l.logical_id)
        order by x.employee_id,l.logical_id)
      from public.matrix_employee_locations_v2 x
      join public.matrix_locations_v2 l on l.id=x.location_id
      where x.matrix_version_id=mv.id),'[]'::jsonb),
    'employeeDuties',coalesce((select jsonb_agg(
      (to_jsonb(x)-array['id','matrix_version_id','duty_id','role_id','location_id','created_at'])
        ||jsonb_build_object('dutyLogicalId',d.logical_id,
          'roleLogicalId',r.logical_id,'locationLogicalId',l.logical_id)
        order by x.employee_id,d.logical_id,r.logical_id,l.logical_id)
      from public.matrix_employee_duties_v2 x
      join public.matrix_duties_v2 d on d.id=x.duty_id
      left join public.matrix_roles_v2 r on r.id=x.role_id
      left join public.matrix_locations_v2 l on l.id=x.location_id
      where x.matrix_version_id=mv.id),'[]'::jsonb),
    'payRules',coalesce((select jsonb_agg(
      to_jsonb(x)-array['id','matrix_version_id','created_at','updated_at']
        order by x.logical_id)
      from public.matrix_pay_rules_v2 x where x.matrix_version_id=mv.id),'[]'::jsonb),
    'payRuleRoles',coalesce((select jsonb_agg(jsonb_build_object(
        'payRuleLogicalId',p.logical_id,'roleLogicalId',r.logical_id)
        order by p.logical_id,r.logical_id)
      from public.matrix_pay_rule_roles_v2 x
      join public.matrix_pay_rules_v2 p on p.id=x.pay_rule_id
      join public.matrix_roles_v2 r on r.id=x.role_id
      where x.matrix_version_id=mv.id),'[]'::jsonb),
    'payRuleDuties',coalesce((select jsonb_agg(jsonb_build_object(
        'payRuleLogicalId',p.logical_id,'dutyLogicalId',d.logical_id,'matchMode',x.match_mode)
        order by p.logical_id,d.logical_id)
      from public.matrix_pay_rule_duties_v2 x
      join public.matrix_pay_rules_v2 p on p.id=x.pay_rule_id
      join public.matrix_duties_v2 d on d.id=x.duty_id
      where x.matrix_version_id=mv.id),'[]'::jsonb),
    'payRuleLocations',coalesce((select jsonb_agg(jsonb_build_object(
        'payRuleLogicalId',p.logical_id,'locationLogicalId',l.logical_id)
        order by p.logical_id,l.logical_id)
      from public.matrix_pay_rule_locations_v2 x
      join public.matrix_pay_rules_v2 p on p.id=x.pay_rule_id
      join public.matrix_locations_v2 l on l.id=x.location_id
      where x.matrix_version_id=mv.id),'[]'::jsonb),
    'payRuleShifts',coalesce((select jsonb_agg(jsonb_build_object(
        'payRuleLogicalId',p.logical_id,'shiftLogicalId',s.logical_id)
        order by p.logical_id,s.logical_id)
      from public.matrix_pay_rule_shifts_v2 x
      join public.matrix_pay_rules_v2 p on p.id=x.pay_rule_id
      join public.matrix_shift_templates_v2 s on s.id=x.shift_template_id
      where x.matrix_version_id=mv.id),'[]'::jsonb),
    'scenarioPayRuleOverrides',coalesce((select jsonb_agg(
      (to_jsonb(x)-array['id','matrix_version_id','scenario_id','pay_rule_id','created_at'])
        ||jsonb_build_object('scenarioLogicalId',sc.logical_id,
          'payRuleLogicalId',p.logical_id) order by sc.logical_id,p.logical_id)
      from public.matrix_scenario_pay_rule_overrides_v2 x
      join public.matrix_scenarios_v2 sc on sc.id=x.scenario_id
      join public.matrix_pay_rules_v2 p on p.id=x.pay_rule_id
      where x.matrix_version_id=mv.id),'[]'::jsonb),
    'scenarioBudgets',coalesce((select jsonb_agg(
      (to_jsonb(x)-array['id','matrix_version_id','scenario_id','location_id','role_id',
        'duty_id','created_at','updated_at'])
        ||jsonb_build_object('scenarioLogicalId',sc.logical_id,
          'locationLogicalId',l.logical_id,'roleLogicalId',r.logical_id,
          'dutyLogicalId',d.logical_id)
        order by sc.logical_id,x.budget_month,l.logical_id,r.logical_id,d.logical_id)
      from public.matrix_scenario_budgets_v2 x
      join public.matrix_scenarios_v2 sc on sc.id=x.scenario_id
      left join public.matrix_locations_v2 l on l.id=x.location_id
      left join public.matrix_roles_v2 r on r.id=x.role_id
      left join public.matrix_duties_v2 d on d.id=x.duty_id
      where x.matrix_version_id=mv.id),'[]'::jsonb)
  )
  from public.matrix_versions mv where mv.id=p_matrix_version_id;
$$;


ALTER FUNCTION "public"."matrix_v2_content_document"("p_matrix_version_id" "uuid") OWNER TO "postgres";

--
-- Name: matrix_v2_create_draft("text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_create_draft"("p_name" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_active public.matrix_versions%rowtype;
  v_draft_id uuid;
  v_version integer;
begin
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));

  select mv.id into v_draft_id
  from public.matrix_versions mv
  where mv.status='DRAFT' and mv.schema_version>=2
  order by mv.version desc limit 1;
  if v_draft_id is not null then return v_draft_id; end if;

  select * into v_active from public.matrix_versions mv
  where mv.status='ACTIVE' and mv.schema_version>=2
  order by mv.version desc limit 1;
  select coalesce(max(mv.version),0)+1 into v_version from public.matrix_versions mv;

  insert into public.matrix_versions(
    version,name,status,effective_from,settings,created_by,schema_version,base_version_id
  ) values(
    v_version,coalesce(nullif(trim(p_name),''),'Matrix v2 v'||v_version),'DRAFT',
    coalesce(v_active.effective_from,current_date),
    coalesce(v_active.settings,'{}'::jsonb),auth.uid(),2,v_active.id
  ) returning id into v_draft_id;

  if v_active.id is null then return v_draft_id; end if;

  -- Keep the last legacy-compatible projection beside Matrix v2. Until the
  -- feature flag leaves ALPHA15 this prevents publishing a v2 draft from
  -- activating a Matrix version with empty legacy tables.
  insert into public.matrix_roles(matrix_version_id,code,name,color,sort_order,active)
  select v_draft_id,r.code,r.name,r.color,r.sort_order,r.active
  from public.matrix_roles r where r.matrix_version_id=v_active.id;

  insert into public.matrix_locations(matrix_version_id,code,name,active)
  select v_draft_id,l.code,l.name,l.active
  from public.matrix_locations l where l.matrix_version_id=v_active.id;

  insert into public.matrix_functions(matrix_version_id,code,name,description,active)
  select v_draft_id,f.code,f.name,f.description,f.active
  from public.matrix_functions f where f.matrix_version_id=v_active.id;

  insert into public.matrix_shift_templates(
    matrix_version_id,location_id,code,name,starts_at,ends_at,day_mask,sort_order,active
  )
  select v_draft_id,nl.id,s.code,s.name,s.starts_at,s.ends_at,s.day_mask,
    s.sort_order,s.active
  from public.matrix_shift_templates s
  join public.matrix_locations old_location on old_location.id=s.location_id
  join public.matrix_locations nl
    on nl.matrix_version_id=v_draft_id and nl.code=old_location.code
  where s.matrix_version_id=v_active.id;

  insert into public.matrix_role_functions(role_id,function_id,assignment_mode)
  select nr.id,nf.id,rf.assignment_mode
  from public.matrix_role_functions rf
  join public.matrix_roles old_role on old_role.id=rf.role_id
  join public.matrix_functions old_function on old_function.id=rf.function_id
  join public.matrix_roles nr
    on nr.matrix_version_id=v_draft_id and nr.code=old_role.code
  join public.matrix_functions nf
    on nf.matrix_version_id=v_draft_id and nf.code=old_function.code
  where old_role.matrix_version_id=v_active.id
    and old_function.matrix_version_id=v_active.id;

  insert into public.matrix_demand(
    shift_template_id,role_id,function_id,scenario_code,required_count
  )
  select nsh.id,nr.id,nf.id,d.scenario_code,d.required_count
  from public.matrix_demand d
  join public.matrix_shift_templates old_shift on old_shift.id=d.shift_template_id
  join public.matrix_locations old_location on old_location.id=old_shift.location_id
  join public.matrix_roles old_role on old_role.id=d.role_id
  left join public.matrix_functions old_function on old_function.id=d.function_id
  join public.matrix_locations nl
    on nl.matrix_version_id=v_draft_id and nl.code=old_location.code
  join public.matrix_shift_templates nsh
    on nsh.matrix_version_id=v_draft_id and nsh.location_id=nl.id and nsh.code=old_shift.code
  join public.matrix_roles nr
    on nr.matrix_version_id=v_draft_id and nr.code=old_role.code
  left join public.matrix_functions nf
    on nf.matrix_version_id=v_draft_id and nf.code=old_function.code
  where old_shift.matrix_version_id=v_active.id
    and old_role.matrix_version_id=v_active.id
    and (old_function.id is null
      or old_function.matrix_version_id=v_active.id);

  insert into public.matrix_employee_roles(
    matrix_version_id,employee_id,role_id,is_primary,can_lead
  )
  select v_draft_id,er.employee_id,nr.id,er.is_primary,er.can_lead
  from public.matrix_employee_roles er
  join public.matrix_roles old_role on old_role.id=er.role_id
  join public.matrix_roles nr
    on nr.matrix_version_id=v_draft_id and nr.code=old_role.code
  where er.matrix_version_id=v_active.id;

  insert into public.matrix_scenarios(
    matrix_version_id,code,name,description,color,active,sort_order
  )
  select v_draft_id,s.code,s.name,s.description,s.color,s.active,s.sort_order
  from public.matrix_scenarios s where s.matrix_version_id=v_active.id;

  insert into public.optimizer_profiles(
    matrix_version_id,code,name,weights,population_size,generations,elite_count,
    mutation_rate,alternatives_count,active
  )
  select v_draft_id,p.code,p.name,p.weights,p.population_size,p.generations,
    p.elite_count,p.mutation_rate,p.alternatives_count,p.active
  from public.optimizer_profiles p where p.matrix_version_id=v_active.id;

  insert into public.matrix_roles_v2(
    id,matrix_version_id,logical_id,code,name,color,sort_order,active
  ) select gen_random_uuid(),v_draft_id,r.logical_id,r.code,r.name,r.color,r.sort_order,r.active
    from public.matrix_roles_v2 r where r.matrix_version_id=v_active.id;

  insert into public.matrix_locations_v2(
    id,matrix_version_id,logical_id,code,name,timezone,sort_order,active
  ) select gen_random_uuid(),v_draft_id,l.logical_id,l.code,l.name,l.timezone,l.sort_order,l.active
    from public.matrix_locations_v2 l where l.matrix_version_id=v_active.id;

  insert into public.matrix_duties_v2(
    id,matrix_version_id,logical_id,code,name,description,color,sort_order,active
  ) select gen_random_uuid(),v_draft_id,d.logical_id,d.code,d.name,d.description,d.color,d.sort_order,d.active
    from public.matrix_duties_v2 d where d.matrix_version_id=v_active.id;

  insert into public.matrix_shift_templates_v2(
    id,matrix_version_id,logical_id,location_id,code,name,starts_at,ends_at,
    ends_next_day,day_mask,sort_order,active
  )
  select gen_random_uuid(),v_draft_id,s.logical_id,nl.id,s.code,s.name,s.starts_at,s.ends_at,
    s.ends_next_day,s.day_mask,s.sort_order,s.active
  from public.matrix_shift_templates_v2 s
  join public.matrix_locations_v2 ol on ol.id=s.location_id
  join public.matrix_locations_v2 nl
    on nl.matrix_version_id=v_draft_id and nl.logical_id=ol.logical_id
  where s.matrix_version_id=v_active.id;

  insert into public.matrix_role_duties_v2(
    id,matrix_version_id,role_id,duty_id,assignment_mode,minimum_count,active
  )
  select gen_random_uuid(),v_draft_id,nr.id,nd.id,rd.assignment_mode,
    rd.minimum_count,rd.active
  from public.matrix_role_duties_v2 rd
  join public.matrix_roles_v2 orole on orole.id=rd.role_id
  join public.matrix_duties_v2 od on od.id=rd.duty_id
  join public.matrix_roles_v2 nr
    on nr.matrix_version_id=v_draft_id and nr.logical_id=orole.logical_id
  join public.matrix_duties_v2 nd
    on nd.matrix_version_id=v_draft_id and nd.logical_id=od.logical_id
  where rd.matrix_version_id=v_active.id;

  insert into public.matrix_scenarios_v2(
    id,matrix_version_id,logical_id,code,name,description,color,is_default,active,
    sort_order,valid_from,valid_to,settings_overrides
  )
  select gen_random_uuid(),v_draft_id,s.logical_id,s.code,s.name,s.description,s.color,
    s.is_default,s.active,s.sort_order,s.valid_from,s.valid_to,s.settings_overrides
  from public.matrix_scenarios_v2 s where s.matrix_version_id=v_active.id;

  update public.matrix_scenarios_v2 child
  set parent_scenario_id=np.id
  from public.matrix_scenarios_v2 old_child
  join public.matrix_scenarios_v2 old_parent on old_parent.id=old_child.parent_scenario_id
  join public.matrix_scenarios_v2 np
    on np.matrix_version_id=v_draft_id and np.logical_id=old_parent.logical_id
  where child.matrix_version_id=v_draft_id
    and child.logical_id=old_child.logical_id
    and old_child.matrix_version_id=v_active.id;

  insert into public.matrix_staffing_rules_v2(
    id,matrix_version_id,scenario_id,shift_template_id,role_id,duty_id,
    operation,count_value,multiplier_basis_points,active,source_metadata
  )
  select gen_random_uuid(),v_draft_id,nsc.id,nsh.id,nr.id,nd.id,sr.operation,
    sr.count_value,sr.multiplier_basis_points,sr.active,sr.source_metadata
  from public.matrix_staffing_rules_v2 sr
  join public.matrix_scenarios_v2 osc on osc.id=sr.scenario_id
  join public.matrix_shift_templates_v2 osh on osh.id=sr.shift_template_id
  join public.matrix_roles_v2 orole on orole.id=sr.role_id
  left join public.matrix_duties_v2 od on od.id=sr.duty_id
  join public.matrix_scenarios_v2 nsc
    on nsc.matrix_version_id=v_draft_id and nsc.logical_id=osc.logical_id
  join public.matrix_shift_templates_v2 nsh
    on nsh.matrix_version_id=v_draft_id and nsh.logical_id=osh.logical_id
  join public.matrix_roles_v2 nr
    on nr.matrix_version_id=v_draft_id and nr.logical_id=orole.logical_id
  left join public.matrix_duties_v2 nd
    on nd.matrix_version_id=v_draft_id and nd.logical_id=od.logical_id
  where sr.matrix_version_id=v_active.id;

  insert into public.matrix_strategies_v2(
    id,matrix_version_id,logical_id,code,name,description,solver_code,solver_options,
    legacy_weights,sort_order,active
  )
  select gen_random_uuid(),v_draft_id,s.logical_id,s.code,s.name,s.description,
    s.solver_code,s.solver_options-array[
      'legacyPopulationSize','legacyGenerations','legacyMutationRate'
    ],s.legacy_weights,s.sort_order,s.active
  from public.matrix_strategies_v2 s where s.matrix_version_id=v_active.id;

  insert into public.matrix_strategy_objectives_v2(
    id,matrix_version_id,strategy_id,tier,sort_order,metric_code,direction,
    weight,tolerance,parameters,active
  )
  select gen_random_uuid(),v_draft_id,ns.id,o.tier,o.sort_order,o.metric_code,
    o.direction,o.weight,o.tolerance,o.parameters,o.active
  from public.matrix_strategy_objectives_v2 o
  join public.matrix_strategies_v2 os on os.id=o.strategy_id
  join public.matrix_strategies_v2 ns
    on ns.matrix_version_id=v_draft_id and ns.logical_id=os.logical_id
  where o.matrix_version_id=v_active.id;

  insert into public.matrix_scenario_strategies_v2(
    id,matrix_version_id,scenario_id,strategy_id,sort_order,active,
    objective_overrides,solver_overrides
  )
  select gen_random_uuid(),v_draft_id,nsc.id,nst.id,ss.sort_order,ss.active,
    ss.objective_overrides,ss.solver_overrides
  from public.matrix_scenario_strategies_v2 ss
  join public.matrix_scenarios_v2 osc on osc.id=ss.scenario_id
  join public.matrix_strategies_v2 ost on ost.id=ss.strategy_id
  join public.matrix_scenarios_v2 nsc
    on nsc.matrix_version_id=v_draft_id and nsc.logical_id=osc.logical_id
  join public.matrix_strategies_v2 nst
    on nst.matrix_version_id=v_draft_id and nst.logical_id=ost.logical_id
  where ss.matrix_version_id=v_active.id;

  insert into public.matrix_employee_roles_v2(
    id,matrix_version_id,employee_id,role_id,is_primary,can_lead,active,valid_from,valid_to
  )
  select gen_random_uuid(),v_draft_id,er.employee_id,nr.id,er.is_primary,er.can_lead,
    er.active,er.valid_from,er.valid_to
  from public.matrix_employee_roles_v2 er
  join public.matrix_roles_v2 old_role on old_role.id=er.role_id
  join public.matrix_roles_v2 nr
    on nr.matrix_version_id=v_draft_id and nr.logical_id=old_role.logical_id
  where er.matrix_version_id=v_active.id;

  insert into public.matrix_employee_locations_v2(
    id,matrix_version_id,employee_id,location_id,standard_allowed,overtime_allowed,
    home_location,active,valid_from,valid_to
  )
  select gen_random_uuid(),v_draft_id,el.employee_id,nl.id,el.standard_allowed,
    el.overtime_allowed,el.home_location,el.active,el.valid_from,el.valid_to
  from public.matrix_employee_locations_v2 el
  join public.matrix_locations_v2 old_location on old_location.id=el.location_id
  join public.matrix_locations_v2 nl
    on nl.matrix_version_id=v_draft_id and nl.logical_id=old_location.logical_id
  where el.matrix_version_id=v_active.id;

  insert into public.matrix_employee_duties_v2(
    id,matrix_version_id,employee_id,duty_id,role_id,location_id,active,
    valid_from,valid_to,source
  )
  select gen_random_uuid(),v_draft_id,ed.employee_id,nd.id,nr.id,nl.id,ed.active,
    ed.valid_from,ed.valid_to,ed.source
  from public.matrix_employee_duties_v2 ed
  join public.matrix_duties_v2 old_duty on old_duty.id=ed.duty_id
  left join public.matrix_roles_v2 old_role on old_role.id=ed.role_id
  left join public.matrix_locations_v2 old_location on old_location.id=ed.location_id
  join public.matrix_duties_v2 nd
    on nd.matrix_version_id=v_draft_id and nd.logical_id=old_duty.logical_id
  left join public.matrix_roles_v2 nr
    on nr.matrix_version_id=v_draft_id and nr.logical_id=old_role.logical_id
  left join public.matrix_locations_v2 nl
    on nl.matrix_version_id=v_draft_id and nl.logical_id=old_location.logical_id
  where ed.matrix_version_id=v_active.id;

  insert into public.matrix_pay_rules_v2(
    id,matrix_version_id,logical_id,code,name,description,calculation_method,
    amount_minor,rate_minor_per_hour,percent_basis_points,multiplier_basis_points,
    threshold_minutes,currency,priority,stacking_group,stacking_mode,day_mask,
    local_start,local_end,ends_next_day,valid_from,valid_to,condition_expression,
    formula_expression,active
  )
  select gen_random_uuid(),v_draft_id,p.logical_id,p.code,p.name,p.description,
    p.calculation_method,p.amount_minor,p.rate_minor_per_hour,p.percent_basis_points,
    p.multiplier_basis_points,p.threshold_minutes,p.currency,p.priority,p.stacking_group,
    p.stacking_mode,p.day_mask,p.local_start,p.local_end,p.ends_next_day,p.valid_from,
    p.valid_to,p.condition_expression,p.formula_expression,p.active
  from public.matrix_pay_rules_v2 p where p.matrix_version_id=v_active.id;

  insert into public.matrix_pay_rule_roles_v2(matrix_version_id,pay_rule_id,role_id)
  select v_draft_id,np.id,nr.id
  from public.matrix_pay_rule_roles_v2 x
  join public.matrix_pay_rules_v2 op on op.id=x.pay_rule_id
  join public.matrix_roles_v2 old_role on old_role.id=x.role_id
  join public.matrix_pay_rules_v2 np
    on np.matrix_version_id=v_draft_id and np.logical_id=op.logical_id
  join public.matrix_roles_v2 nr
    on nr.matrix_version_id=v_draft_id and nr.logical_id=old_role.logical_id
  where x.matrix_version_id=v_active.id;

  insert into public.matrix_pay_rule_duties_v2(matrix_version_id,pay_rule_id,duty_id,match_mode)
  select v_draft_id,np.id,nd.id,x.match_mode
  from public.matrix_pay_rule_duties_v2 x
  join public.matrix_pay_rules_v2 op on op.id=x.pay_rule_id
  join public.matrix_duties_v2 old_duty on old_duty.id=x.duty_id
  join public.matrix_pay_rules_v2 np
    on np.matrix_version_id=v_draft_id and np.logical_id=op.logical_id
  join public.matrix_duties_v2 nd
    on nd.matrix_version_id=v_draft_id and nd.logical_id=old_duty.logical_id
  where x.matrix_version_id=v_active.id;

  insert into public.matrix_pay_rule_locations_v2(matrix_version_id,pay_rule_id,location_id)
  select v_draft_id,np.id,nl.id
  from public.matrix_pay_rule_locations_v2 x
  join public.matrix_pay_rules_v2 op on op.id=x.pay_rule_id
  join public.matrix_locations_v2 old_location on old_location.id=x.location_id
  join public.matrix_pay_rules_v2 np
    on np.matrix_version_id=v_draft_id and np.logical_id=op.logical_id
  join public.matrix_locations_v2 nl
    on nl.matrix_version_id=v_draft_id and nl.logical_id=old_location.logical_id
  where x.matrix_version_id=v_active.id;

  insert into public.matrix_pay_rule_shifts_v2(matrix_version_id,pay_rule_id,shift_template_id)
  select v_draft_id,np.id,nsh.id
  from public.matrix_pay_rule_shifts_v2 x
  join public.matrix_pay_rules_v2 op on op.id=x.pay_rule_id
  join public.matrix_shift_templates_v2 old_shift on old_shift.id=x.shift_template_id
  join public.matrix_pay_rules_v2 np
    on np.matrix_version_id=v_draft_id and np.logical_id=op.logical_id
  join public.matrix_shift_templates_v2 nsh
    on nsh.matrix_version_id=v_draft_id and nsh.logical_id=old_shift.logical_id
  where x.matrix_version_id=v_active.id;

  insert into public.matrix_scenario_pay_rule_overrides_v2(
    id,matrix_version_id,scenario_id,pay_rule_id,enabled,amount_minor,
    rate_minor_per_hour,percent_basis_points,multiplier_basis_points,formula_expression
  )
  select gen_random_uuid(),v_draft_id,nsc.id,np.id,x.enabled,x.amount_minor,
    x.rate_minor_per_hour,x.percent_basis_points,x.multiplier_basis_points,x.formula_expression
  from public.matrix_scenario_pay_rule_overrides_v2 x
  join public.matrix_scenarios_v2 osc on osc.id=x.scenario_id
  join public.matrix_pay_rules_v2 op on op.id=x.pay_rule_id
  join public.matrix_scenarios_v2 nsc
    on nsc.matrix_version_id=v_draft_id and nsc.logical_id=osc.logical_id
  join public.matrix_pay_rules_v2 np
    on np.matrix_version_id=v_draft_id and np.logical_id=op.logical_id
  where x.matrix_version_id=v_active.id;

  insert into public.matrix_scenario_budgets_v2(
    id,matrix_version_id,scenario_id,budget_month,location_id,role_id,duty_id,
    operation,amount_minor,multiplier_basis_points,currency,hard_limit,
    warning_percent,source_metadata
  )
  select gen_random_uuid(),v_draft_id,nsc.id,b.budget_month,nl.id,nr.id,nd.id,
    b.operation,b.amount_minor,b.multiplier_basis_points,b.currency,b.hard_limit,
    b.warning_percent,b.source_metadata
  from public.matrix_scenario_budgets_v2 b
  join public.matrix_scenarios_v2 osc on osc.id=b.scenario_id
  left join public.matrix_locations_v2 ol on ol.id=b.location_id
  left join public.matrix_roles_v2 orole on orole.id=b.role_id
  left join public.matrix_duties_v2 od on od.id=b.duty_id
  join public.matrix_scenarios_v2 nsc
    on nsc.matrix_version_id=v_draft_id and nsc.logical_id=osc.logical_id
  left join public.matrix_locations_v2 nl
    on nl.matrix_version_id=v_draft_id and nl.logical_id=ol.logical_id
  left join public.matrix_roles_v2 nr
    on nr.matrix_version_id=v_draft_id and nr.logical_id=orole.logical_id
  left join public.matrix_duties_v2 nd
    on nd.matrix_version_id=v_draft_id and nd.logical_id=od.logical_id
  where b.matrix_version_id=v_active.id;

  return v_draft_id;
end;
$$;


ALTER FUNCTION "public"."matrix_v2_create_draft"("p_name" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_create_draft"("p_name" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_create_draft"("p_name" "text") IS 'Creates one editable Matrix v2 draft by cloning only the selected active version.';


--
-- Name: matrix_v2_discard_current_draft_uat_v2(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_discard_current_draft_uat_v2"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_draft public.matrix_versions%rowtype;
  v_active uuid;
  v_draft_count integer;
  v_active_count integer;
  v_decision text;
  v_ensured jsonb;
  v_ad_hoc_reconnected integer:=0;
  v_ad_hoc_removed integer:=0;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;

  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));

  select count(*)::integer into v_draft_count
  from public.matrix_versions where status='DRAFT';
  select count(*)::integer into v_active_count
  from public.matrix_versions where status='ACTIVE';
  v_decision:=solver_private.matrix_v2_discard_decision_uat_v1(
    v_draft_count,v_active_count
  );

  if v_decision='MULTIPLE_DRAFTS' then
    raise exception 'MULTIPLE_MATRIX_DRAFTS_FOUND';
  end if;

  select * into v_draft
  from public.matrix_versions
  where status='DRAFT'
  order by version desc
  limit 1
  for update;

  select id into v_active
  from public.matrix_versions
  where status='ACTIVE'
  order by effective_from desc nulls last,version desc
  limit 1;

  if v_decision='ENSURE_FIRST_RUN' then
    v_ensured:=public.matrix_v2_ensure_first_run_uat_v1();
    return jsonb_build_object(
      'discarded',null,'alreadyDiscarded',true,
      'ensuredFirstRun',true,
      'activeMatrixVersionId',null,
      'draftMatrixVersionId',v_ensured->>'matrixVersionId'
    );
  end if;

  if v_decision='NOOP_ACTIVE' then
    return jsonb_build_object(
      'discarded',null,'alreadyDiscarded',true,
      'ensuredFirstRun',false,'activeMatrixVersionId',v_active
    );
  end if;

  if v_decision='PRESERVE_ONLY_DRAFT' then
    insert into public.audit_log(actor_id,entity_type,entity_id,action,old_data)
    values(auth.uid(),'matrix_version',v_draft.id::text,
      'B4F171_PRESERVE_ONLY_DRAFT',jsonb_build_object(
        'version',v_draft.version,'name',v_draft.name,
        'reason','NO_ACTIVE_CONFIGURATION'
      ));
    return jsonb_build_object(
      'discarded',null,'alreadyDiscarded',false,
      'preservedOnlyDraft',true,'ensuredFirstRun',false,
      'activeMatrixVersionId',null,'draftMatrixVersionId',v_draft.id
    );
  end if;

  if exists(
    select 1 from public.optimization_runs_v2 r
    where r.matrix_version_id=v_draft.id
  ) then
    raise exception 'DRAFT_ALREADY_USED_BY_GENERATOR';
  end if;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,old_data)
  values(
    auth.uid(),'matrix_version',v_draft.id::text,'DISCARD_DRAFT',
    jsonb_build_object('version',v_draft.version,'name',v_draft.name)
  );

  update public.recovery_ad_hoc_pool_v2 pool
  set role_id=active_role.id,updated_at=now()
  from public.matrix_roles_v2 draft_role
  join public.matrix_roles_v2 active_role
    on active_role.matrix_version_id=v_active
   and active_role.logical_id=draft_role.logical_id
  where pool.role_id=draft_role.id
    and draft_role.matrix_version_id=v_draft.id;
  get diagnostics v_ad_hoc_reconnected=row_count;

  delete from public.recovery_ad_hoc_pool_v2 pool
  using public.matrix_roles_v2 draft_role
  where pool.role_id=draft_role.id
    and draft_role.matrix_version_id=v_draft.id;
  get diagnostics v_ad_hoc_removed=row_count;

  delete from public.matrix_versions where id=v_draft.id;

  if not exists(
    select 1 from public.matrix_versions mv
    where mv.status in ('DRAFT','ACTIVE')
  ) then
    raise exception 'B4F171_USABLE_MATRIX_REQUIRED_AFTER_DISCARD';
  end if;

  return jsonb_build_object(
    'discarded',v_draft.id,'alreadyDiscarded',false,
    'preservedOnlyDraft',false,'ensuredFirstRun',false,
    'activeMatrixVersionId',v_active,
    'adHocRowsReconnected',v_ad_hoc_reconnected,
    'adHocRowsRemoved',v_ad_hoc_removed
  );
end;
$$;


ALTER FUNCTION "public"."matrix_v2_discard_current_draft_uat_v2"() OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_discard_current_draft_uat_v2"(); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_discard_current_draft_uat_v2"() IS 'UAT: discard a draft only when another usable Matrix remains; preserve the sole draft and recover a missing first-run Matrix.';


--
-- Name: matrix_v2_discard_draft_uat_v1("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_discard_draft_uat_v1"("p_matrix_version_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_draft public.matrix_versions%rowtype;
  v_active uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  select * into v_draft from public.matrix_versions
    where id=p_matrix_version_id for update;
  if v_draft.id is null then raise exception 'MATRIX_VERSION_NOT_FOUND'; end if;
  if v_draft.status<>'DRAFT' then raise exception 'ONLY_DRAFT_CAN_BE_DISCARDED'; end if;
  if exists(select 1 from public.optimization_runs_v2 r where r.matrix_version_id=v_draft.id) then
    raise exception 'DRAFT_ALREADY_USED_BY_GENERATOR';
  end if;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,old_data)
  values(auth.uid(),'matrix_version',v_draft.id::text,'DISCARD_DRAFT',
    jsonb_build_object('version',v_draft.version,'name',v_draft.name));
  delete from public.matrix_versions where id=v_draft.id;
  select id into v_active from public.matrix_versions
    where status='ACTIVE' order by effective_from desc nulls last,version desc limit 1;
  return jsonb_build_object('discarded',v_draft.id,'activeMatrixVersionId',v_active);
end;
$$;


ALTER FUNCTION "public"."matrix_v2_discard_draft_uat_v1"("p_matrix_version_id" "uuid") OWNER TO "postgres";

--
-- Name: matrix_v2_duty_archive_preview_uat_v2("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_duty_archive_preview_uat_v2"("p_duty_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_matrix uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  select duty.matrix_version_id into v_matrix
  from public.matrix_duties_v2 duty where duty.id=p_duty_id;
  if v_matrix is null then raise exception 'DUTY_NOT_FOUND'; end if;
  return jsonb_build_object(
    'dutyId',p_duty_id,
    'roleDuties',(select count(*) from public.matrix_role_duties_v2 link
      where link.matrix_version_id=v_matrix and link.duty_id=p_duty_id and link.active),
    'employeeDuties',(select count(*) from public.matrix_employee_duties_v2 link
      where link.matrix_version_id=v_matrix and link.duty_id=p_duty_id and link.active),
    'staffingRules',(select count(*) from public.matrix_staffing_rules_v2 rule
      where rule.matrix_version_id=v_matrix and rule.duty_id=p_duty_id and rule.active),
    'payRules',(select count(*) from public.matrix_pay_rule_duties_v2 link
      where link.matrix_version_id=v_matrix and link.duty_id=p_duty_id)
  );
end;
$$;


ALTER FUNCTION "public"."matrix_v2_duty_archive_preview_uat_v2"("p_duty_id" "uuid") OWNER TO "postgres";

--
-- Name: matrix_v2_duty_archive_uat_v2("uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_duty_archive_uat_v2"("p_duty_id" "uuid", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_duty public.matrix_duties_v2%rowtype;
  v_role_duties integer:=0; v_employee_duties integer:=0;
  v_staffing_rules integer:=0; v_pay_rules integer:=0;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if length(trim(coalesce(p_reason,'')))<5 then raise exception 'ARCHIVE_REASON_REQUIRED'; end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  select duty.* into v_duty from public.matrix_duties_v2 duty
  join public.matrix_versions version on version.id=duty.matrix_version_id
  where duty.id=p_duty_id and version.status='DRAFT' for update of duty;
  if v_duty.id is null then raise exception 'DRAFT_DUTY_NOT_FOUND'; end if;
  if not v_duty.active then raise exception 'DUTY_ALREADY_ARCHIVED'; end if;

  update public.matrix_role_duties_v2 set active=false
    where matrix_version_id=v_duty.matrix_version_id and duty_id=p_duty_id and active;
  get diagnostics v_role_duties=row_count;
  update public.matrix_employee_duties_v2 set active=false
    where matrix_version_id=v_duty.matrix_version_id and duty_id=p_duty_id and active;
  get diagnostics v_employee_duties=row_count;
  update public.matrix_staffing_rules_v2 set active=false
    where matrix_version_id=v_duty.matrix_version_id and duty_id=p_duty_id and active;
  get diagnostics v_staffing_rules=row_count;
  delete from public.matrix_pay_rule_duties_v2
    where matrix_version_id=v_duty.matrix_version_id and duty_id=p_duty_id;
  get diagnostics v_pay_rules=row_count;
  update public.matrix_duties_v2 set active=false where id=p_duty_id;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,old_data,new_data)
  values(auth.uid(),'matrix_v2_duty',p_duty_id::text,'ARCHIVE_WITH_DEPENDENCIES',
    to_jsonb(v_duty),jsonb_build_object('active',false,'reason',trim(p_reason),
      'roleDutiesDeactivated',v_role_duties,'employeeDutiesDeactivated',v_employee_duties,
      'staffingRulesDeactivated',v_staffing_rules,'payRuleLinksRemoved',v_pay_rules));
  return jsonb_build_object('dutyId',p_duty_id,'archived',true,
    'roleDutiesDeactivated',v_role_duties,'employeeDutiesDeactivated',v_employee_duties,
    'staffingRulesDeactivated',v_staffing_rules,'payRuleLinksRemoved',v_pay_rules);
end;
$$;


ALTER FUNCTION "public"."matrix_v2_duty_archive_uat_v2"("p_duty_id" "uuid", "p_reason" "text") OWNER TO "postgres";

--
-- Name: matrix_v2_employee_archive_v2("uuid", "text", boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_employee_archive_v2"("p_employee_id" "uuid", "p_reason" "text" DEFAULT NULL::"text", "p_archive" boolean DEFAULT true) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_matrix uuid;
  v_profile public.matrix_employee_profiles_v2%rowtype;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE')) then raise exception 'FORBIDDEN'; end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  if p_employee_id is null then raise exception 'EMPLOYEE_REQUIRED'; end if;
  select mv.id into v_matrix
  from public.matrix_versions mv
  where mv.status='DRAFT' and mv.schema_version>=2
  order by mv.version desc limit 1 for update;
  if v_matrix is null then raise exception 'NO_MATRIX_V2_DRAFT'; end if;
  select * into v_profile from public.matrix_employee_profiles_v2 p
  where p.matrix_version_id=v_matrix and p.employee_id=p_employee_id for update;
  if v_profile.id is null then raise exception 'MATRIX_EMPLOYEE_NOT_FOUND'; end if;

  update public.matrix_employee_profiles_v2 set
    active=not p_archive,
    archived_at=case when p_archive then now() else null end,
    archived_by=case when p_archive then auth.uid() else null end,
    archive_reason=case when p_archive then nullif(trim(p_reason),'') else null end,
    updated_by=auth.uid(),updated_at=now()
  where id=v_profile.id returning * into v_profile;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_v2_employee',p_employee_id::text,
    case when p_archive then 'ARCHIVE' else 'RESTORE' end,
    jsonb_build_object('matrixVersionId',v_matrix,'reason',
      case when p_archive then nullif(trim(p_reason),'') else null end));
  return jsonb_build_object('id',p_employee_id,'active',v_profile.active,
    'matrixVersionId',v_matrix);
end;
$$;


ALTER FUNCTION "public"."matrix_v2_employee_archive_v2"("p_employee_id" "uuid", "p_reason" "text", "p_archive" boolean) OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_employee_archive_v2"("p_employee_id" "uuid", "p_reason" "text", "p_archive" boolean); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_employee_archive_v2"("p_employee_id" "uuid", "p_reason" "text", "p_archive" boolean) IS 'Archives or restores a draft employee without deleting historical identity.';


--
-- Name: matrix_v2_employee_directory_alpha16("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_employee_directory_alpha16"("p_month" "date" DEFAULT CURRENT_DATE) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_directory jsonb;
  v_matrix uuid;
  v_month date:=date_trunc('month',coalesce(p_month,current_date))::date;
  v_employees jsonb;
begin
  v_directory:=public.matrix_v2_employee_directory_v2();
  v_matrix:=(v_directory->>'matrixVersionId')::uuid;
  select coalesce(jsonb_agg(
    employee.value || jsonb_build_object(
      'locationIds',coalesce((select jsonb_agg(location_grant.location_id::text
        order by location_grant.location_id::text)
        from public.matrix_employee_locations_v2 location_grant
        where location_grant.matrix_version_id=v_matrix
          and location_grant.employee_id=(employee.value->>'id')::uuid
          and location_grant.standard_allowed and location_grant.active
      ),'[]'::jsonb),
      'shiftPeriodPreferences',coalesce((select jsonb_object_agg(
        upper(preference.preference_value->>'period'),
        upper(preference.preference_value->>'level')
      ) from public.employee_preferences preference
        where preference.employee_id=(employee.value->>'id')::uuid
          and preference.preference_type='PREFERRED_SHIFT'
          and preference.source='MANAGER' and preference.status='ACTIVE'
          and preference.preference_value->>'matrixVersionId'=v_matrix::text
          and preference.valid_from<v_month+interval '1 month'
          and preference.valid_to>=v_month
      ),'{}'::jsonb)
    ) order by employee.ordinality
  ),'[]'::jsonb) into v_employees
  from jsonb_array_elements(coalesce(v_directory->'employees','[]'::jsonb))
    with ordinality employee(value,ordinality);
  return jsonb_set(v_directory,'{employees}',v_employees,true);
end;
$$;


ALTER FUNCTION "public"."matrix_v2_employee_directory_alpha16"("p_month" "date") OWNER TO "postgres";

--
-- Name: matrix_v2_employee_directory_v2(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_employee_directory_v2"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_matrix uuid;
  v_manage boolean;
  v_owner_admin boolean;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  v_owner_admin:=public.has_app_role('OWNER') or public.has_app_role('ADMIN');
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

  return jsonb_build_object(
    'matrixVersionId',v_matrix,
    'workforceHash',(select mv.workforce_hash from public.matrix_versions mv
      where mv.id=v_matrix),
    'activeCount',(select count(*) from public.matrix_employee_profiles_v2 p
      where p.matrix_version_id=v_matrix and p.active),
    'archivedCount',(select count(*) from public.matrix_employee_profiles_v2 p
      where p.matrix_version_id=v_matrix and not p.active),
    'employees',coalesce((select jsonb_agg(jsonb_build_object(
      'id',p.employee_id,'profileId',p.id,'employeeNo',p.employee_no,
      'firstName',p.first_name,'lastName',p.last_name,
      'email',case when v_manage or e.auth_user_id=auth.uid() then p.email else null end,
      'active',p.active,'employmentStart',p.employment_start,
      'employmentEnd',p.employment_end,
      'nominalMonthlyMinutes',p.nominal_monthly_minutes,
      'maximumMonthlyMinutes',p.maximum_monthly_minutes,
      'maximumWeeklyMinutes',p.maximum_weekly_minutes,
      'maximumConsecutiveDays',p.maximum_consecutive_days,
      'minimumRestMinutes',p.minimum_rest_minutes,
      'onlyMorning',p.only_morning,'onlyEvening',p.only_evening,
      'noWeekends',p.no_weekends,'preferredShiftCode',p.preferred_shift_code,
      'archivedAt',p.archived_at,'archiveReason',p.archive_reason,
      'primaryRoleId',(select er.role_id from public.matrix_employee_roles_v2 er
        where er.matrix_version_id=v_matrix and er.employee_id=p.employee_id
          and er.is_primary and er.active order by er.created_at limit 1),
      'homeLocationId',(select el.location_id from public.matrix_employee_locations_v2 el
        where el.matrix_version_id=v_matrix and el.employee_id=p.employee_id
          and el.home_location and el.active order by el.created_at limit 1)
    ) order by p.active desc,p.last_name,p.first_name,p.employee_no)
    from public.matrix_employee_profiles_v2 p
    join public.employees e on e.id=p.employee_id
    where p.matrix_version_id=v_matrix
      and (v_manage or e.auth_user_id=auth.uid())),'[]'::jsonb)
  );
end;
$$;


ALTER FUNCTION "public"."matrix_v2_employee_directory_v2"() OWNER TO "postgres";

--
-- Name: matrix_v2_employee_save_alpha16("uuid", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_employee_save_alpha16"("p_employee_id" "uuid" DEFAULT NULL::"uuid", "p_data" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_matrix uuid;
  v_employee uuid:=p_employee_id;
  v_result jsonb;
  v_payload jsonb:=coalesce(p_data,'{}'::jsonb);
  v_employee_no text;
  v_location uuid;
  v_period text;
  v_level text;
  v_month date:=date_trunc('month',coalesce(
    nullif(v_payload->>'preferenceMonth','')::date,current_date
  ))::date;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE')) then raise exception 'FORBIDDEN'; end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  select mv.id into v_matrix from public.matrix_versions mv
  where mv.status='DRAFT' and mv.schema_version>=2
  order by mv.version desc limit 1 for update;
  if v_matrix is null then raise exception 'NO_MATRIX_V2_DRAFT'; end if;

  if v_employee is null then
    v_employee_no:=public.matrix_v2_next_employee_no_v2();
    v_payload:=jsonb_set(v_payload,'{employeeNo}',to_jsonb(v_employee_no),true);
  else
    select profile.employee_no into v_employee_no
    from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=v_matrix and profile.employee_id=v_employee;
    v_payload:=jsonb_set(v_payload,'{employeeNo}',to_jsonb(v_employee_no),true);
  end if;
  -- The compatibility field is explicitly cleared. Standard locations below
  -- are the only location source used by the solver.
  v_payload:=jsonb_set(v_payload,'{homeLocationId}','null'::jsonb,true);
  v_result:=public.matrix_v2_employee_save_v2(v_employee,v_payload);
  v_employee:=(v_result->>'id')::uuid;

  if v_payload ? 'locationIds' then
    if jsonb_typeof(v_payload->'locationIds')<>'array'
      or jsonb_array_length(v_payload->'locationIds')=0 then
      raise exception 'ACTIVE_EMPLOYEE_REQUIRES_STANDARD_LOCATION';
    end if;
    update public.matrix_employee_locations_v2 location_grant
    set standard_allowed=false,home_location=false,active=false
    where location_grant.matrix_version_id=v_matrix
      and location_grant.employee_id=v_employee;
    for v_location in
      select distinct item.value::text::uuid
      from jsonb_array_elements_text(v_payload->'locationIds') item(value)
    loop
      if not exists(select 1 from public.matrix_locations_v2 location_row
        where location_row.id=v_location and location_row.matrix_version_id=v_matrix
          and location_row.active) then raise exception 'LOCATION_NOT_IN_MATRIX_V2'; end if;
      insert into public.matrix_employee_locations_v2(
        matrix_version_id,employee_id,location_id,standard_allowed,
        overtime_allowed,home_location,active
      ) values(v_matrix,v_employee,v_location,true,false,false,true)
      on conflict(matrix_version_id,employee_id,location_id) do update set
        standard_allowed=true,home_location=false,active=true;
    end loop;
  end if;

  if v_payload ? 'shiftPeriodPreferences' then
    if jsonb_typeof(v_payload->'shiftPeriodPreferences')<>'object' then
      raise exception 'INVALID_SHIFT_PERIOD_PREFERENCES';
    end if;
    update public.employee_preferences preference
    set status='CANCELLED'
    where preference.employee_id=v_employee
      and preference.preference_type='PREFERRED_SHIFT'
      and preference.source='MANAGER'
      and coalesce(preference.preference_value->>'matrixVersionId','')=v_matrix::text
      and preference.status='ACTIVE';
    foreach v_period in array array['MORNING','MIDDLE','EVENING'] loop
      v_level:=upper(coalesce(
        v_payload->'shiftPeriodPreferences'->>v_period,'INHERIT'
      ));
      if v_level not in ('INHERIT','PREFERRED','NEUTRAL','AVOIDED','BLOCKED') then
        raise exception 'INVALID_SHIFT_PREFERENCE_LEVEL';
      end if;
      if v_level<>'INHERIT' then
        insert into public.employee_preferences(
          employee_id,valid_from,valid_to,preference_type,preference_value,
          source,editable_by_employee,status
        ) values(
          v_employee,v_month,(v_month+interval '1 month - 1 day')::date,
          'PREFERRED_SHIFT',jsonb_build_object(
            'period',v_period,'level',v_level,'matrixVersionId',v_matrix
          ),'MANAGER',false,'ACTIVE'
        );
      end if;
    end loop;
    update public.matrix_employee_profiles_v2 profile set
      only_morning=false,only_evening=false,preferred_shift_code=null,
      updated_by=auth.uid(),updated_at=now()
    where profile.matrix_version_id=v_matrix and profile.employee_id=v_employee;
  end if;

  return v_result||jsonb_build_object('employeeNo',v_employee_no);
end;
$$;


ALTER FUNCTION "public"."matrix_v2_employee_save_alpha16"("p_employee_id" "uuid", "p_data" "jsonb") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_employee_save_alpha16"("p_employee_id" "uuid", "p_data" "jsonb"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_employee_save_alpha16"("p_employee_id" "uuid", "p_data" "jsonb") IS 'Internal legacy employee writer. Remote callers must use matrix_v2_employee_save_uat_v4; F4 employment/pay-rate integrity is enforced by table triggers.';


--
-- Name: matrix_v2_employee_save_uat_v3("uuid", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_employee_save_uat_v3"("p_employee_id" "uuid" DEFAULT NULL::"uuid", "p_data" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_start date;
  v_end date;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE')) then raise exception 'FORBIDDEN'; end if;
  if nullif(p_data->>'employmentStart','') is not null
    and not pg_catalog.pg_input_is_valid(p_data->>'employmentStart','date') then
    raise exception 'INVALID_EMPLOYMENT_DATES';
  end if;
  if nullif(p_data->>'employmentEnd','') is not null
    and not pg_catalog.pg_input_is_valid(p_data->>'employmentEnd','date') then
    raise exception 'INVALID_EMPLOYMENT_DATES';
  end if;
  v_start:=nullif(p_data->>'employmentStart','')::date;
  v_end:=nullif(p_data->>'employmentEnd','')::date;
  if v_end is not null and (v_start is null or v_end<v_start) then
    raise exception 'INVALID_EMPLOYMENT_DATES';
  end if;
  if p_employee_id is not null and exists(
    select 1 from public.employee_pay_rates_v2 rate
    where rate.employee_id=p_employee_id and (
      (v_start is not null and rate.valid_from<v_start)
      or (v_end is not null and (
        rate.valid_from>v_end or rate.valid_to is null or rate.valid_to>v_end
      ))
    )
  ) then raise exception 'EMPLOYMENT_DATES_CONFLICT_PAY_RATES'; end if;
  return public.matrix_v2_employee_save_uat_v2(p_employee_id,p_data);
end;
$$;


ALTER FUNCTION "public"."matrix_v2_employee_save_uat_v3"("p_employee_id" "uuid", "p_data" "jsonb") OWNER TO "postgres";

--
-- Name: matrix_v2_employee_save_uat_v4("uuid", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_employee_save_uat_v4"("p_employee_id" "uuid" DEFAULT NULL::"uuid", "p_data" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_result jsonb;
  v_employee uuid;
  v_matrix uuid;
  v_stage text;
  v_overtime_policy text;
  v_contract text;
  v_fraction numeric;
  v_work_time_policy text;
  v_start date;
  v_end date;
begin
  if nullif(p_data->>'employmentStart','') is not null
    and not pg_catalog.pg_input_is_valid(p_data->>'employmentStart','date') then
    raise exception 'INVALID_EMPLOYMENT_DATES';
  end if;
  if nullif(p_data->>'employmentEnd','') is not null
    and not pg_catalog.pg_input_is_valid(p_data->>'employmentEnd','date') then
    raise exception 'INVALID_EMPLOYMENT_DATES';
  end if;
  v_start:=nullif(p_data->>'employmentStart','')::date;
  v_end:=nullif(p_data->>'employmentEnd','')::date;
  if v_end is not null and (v_start is null or v_end<v_start) then
    raise exception 'INVALID_EMPLOYMENT_DATES';
  end if;
  if p_employee_id is not null and exists(
    select 1 from public.employee_pay_rates_v2 rate
    where rate.employee_id=p_employee_id and (
      (v_start is not null and rate.valid_from<v_start)
      or (v_end is not null and (
        rate.valid_from>v_end or rate.valid_to is null or rate.valid_to>v_end
      ))
    )
  ) then raise exception 'EMPLOYMENT_DATES_CONFLICT_PAY_RATES'; end if;
  v_result := public.matrix_v2_employee_save_alpha16(p_employee_id, p_data);
  v_employee := (v_result->>'id')::uuid;
  select id into v_matrix from public.matrix_versions
    where status = 'DRAFT' and schema_version >= 2
    order by version desc limit 1;
  v_stage := case upper(coalesce(nullif(p_data->>'employmentStage',''),'REGULAR'))
    when 'PROBATION' then 'PROBATION'
    when 'NOTICE' then 'NOTICE'
    else 'REGULAR' end;
  v_overtime_policy := upper(coalesce(nullif(p_data->>'overtimePolicy',''),'NEVER'));
  if v_overtime_policy not in ('NEVER','APPROVAL_REQUIRED','ALLOWED') then
    raise exception 'INVALID_OVERTIME_POLICY';
  end if;
  if p_data ? 'contractType' then
    v_contract:=solver_private.normalize_contract_type_v2(p_data->>'contractType');
    v_fraction:=greatest(.01,least(1,coalesce(
      nullif(replace(p_data->>'employmentFraction',',','.'),'')::numeric,1
    )));
    insert into public.employee_hr_profiles(
      employee_id,contract_type,employment_fraction,updated_by,updated_at
    ) values(v_employee,v_contract,v_fraction,auth.uid(),now())
    on conflict(employee_id) do update set
      contract_type=excluded.contract_type,
      employment_fraction=excluded.employment_fraction,
      updated_by=auth.uid(),updated_at=now();
  end if;
  if p_data ? 'workTimePolicy' then
    v_work_time_policy:=case when upper(coalesce(p_data->>'workTimePolicy',''))='CUSTOM'
      then 'CUSTOM' else 'CONTRACT_DEFAULT' end;
  else
    select profile.work_time_policy into v_work_time_policy
    from public.matrix_employee_profiles_v2 profile
    where profile.employee_id=v_employee and profile.matrix_version_id=v_matrix;
    v_work_time_policy:=coalesce(v_work_time_policy,'CONTRACT_DEFAULT');
  end if;
  update public.matrix_employee_profiles_v2 set
    employment_stage = v_stage,
    probation_end = nullif(p_data->>'probationEnd','')::date,
    overtime_policy = v_overtime_policy,
    work_time_policy = v_work_time_policy,
    updated_by = auth.uid(),
    updated_at = now()
  where matrix_version_id = v_matrix and employee_id = v_employee;
  return v_result || jsonb_build_object(
    'employmentStage', v_stage,
    'probationEnd', nullif(p_data->>'probationEnd',''),
    'overtimePolicy', v_overtime_policy,
    'contractType',coalesce(v_contract,(select profile.contract_type
      from public.employee_hr_profiles profile where profile.employee_id=v_employee)),
    'workTimePolicy',v_work_time_policy
  );
end;
$$;


ALTER FUNCTION "public"."matrix_v2_employee_save_uat_v4"("p_employee_id" "uuid", "p_data" "jsonb") OWNER TO "postgres";

--
-- Name: matrix_v2_employee_save_v2("uuid", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_employee_save_v2"("p_employee_id" "uuid" DEFAULT NULL::"uuid", "p_data" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_matrix uuid;
  v_profile public.matrix_employee_profiles_v2%rowtype;
  v_employee_id uuid:=p_employee_id;
  v_employee_no text;
  v_first_name text;
  v_last_name text;
  v_email text;
  v_start date;
  v_end date;
  v_nominal integer;
  v_max_monthly integer;
  v_max_weekly integer;
  v_max_consecutive integer;
  v_minimum_rest integer;
  v_only_morning boolean;
  v_only_evening boolean;
  v_no_weekends boolean;
  v_preferred_shift text;
  v_primary_role uuid;
  v_home_location uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE')) then raise exception 'FORBIDDEN'; end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  if p_data is null or jsonb_typeof(p_data)<>'object' then
    raise exception 'INVALID_EMPLOYEE_PAYLOAD';
  end if;

  select mv.id into v_matrix
  from public.matrix_versions mv
  where mv.status='DRAFT' and mv.schema_version>=2
  order by mv.version desc limit 1 for update;
  if v_matrix is null then raise exception 'NO_MATRIX_V2_DRAFT'; end if;

  if v_employee_id is not null then
    select * into v_profile
    from public.matrix_employee_profiles_v2 p
    where p.matrix_version_id=v_matrix and p.employee_id=v_employee_id
    for update;
    if v_profile.id is null then raise exception 'MATRIX_EMPLOYEE_NOT_FOUND'; end if;
  end if;

  v_employee_no:=coalesce(nullif(trim(p_data->>'employeeNo'),''),v_profile.employee_no);
  v_first_name:=coalesce(nullif(trim(p_data->>'firstName'),''),v_profile.first_name);
  v_last_name:=coalesce(nullif(trim(p_data->>'lastName'),''),v_profile.last_name);
  v_email:=case when p_data ? 'email'
    then nullif(lower(trim(p_data->>'email')),'') else v_profile.email end;
  v_start:=case when p_data ? 'employmentStart'
    then nullif(p_data->>'employmentStart','')::date else v_profile.employment_start end;
  v_end:=case when p_data ? 'employmentEnd'
    then nullif(p_data->>'employmentEnd','')::date else v_profile.employment_end end;
  v_nominal:=coalesce(nullif(p_data->>'nominalMonthlyMinutes','')::integer,
    v_profile.nominal_monthly_minutes);
  v_max_monthly:=coalesce(nullif(p_data->>'maximumMonthlyMinutes','')::integer,
    v_profile.maximum_monthly_minutes);
  v_max_weekly:=coalesce(nullif(p_data->>'maximumWeeklyMinutes','')::integer,
    v_profile.maximum_weekly_minutes);
  v_max_consecutive:=coalesce(
    nullif(p_data->>'maximumConsecutiveDays','')::integer,
    v_profile.maximum_consecutive_days
  );
  v_minimum_rest:=case when p_data ? 'minimumRestMinutes'
    then nullif(p_data->>'minimumRestMinutes','')::integer
    else v_profile.minimum_rest_minutes end;
  v_only_morning:=case when p_data ? 'onlyMorning'
    then (p_data->>'onlyMorning')::boolean else coalesce(v_profile.only_morning,false) end;
  v_only_evening:=case when p_data ? 'onlyEvening'
    then (p_data->>'onlyEvening')::boolean else coalesce(v_profile.only_evening,false) end;
  v_no_weekends:=case when p_data ? 'noWeekends'
    then (p_data->>'noWeekends')::boolean else coalesce(v_profile.no_weekends,false) end;
  v_preferred_shift:=case when p_data ? 'preferredShiftCode'
    then nullif(trim(p_data->>'preferredShiftCode'),'') else v_profile.preferred_shift_code end;
  v_primary_role:=nullif(p_data->>'primaryRoleId','')::uuid;
  v_home_location:=nullif(p_data->>'homeLocationId','')::uuid;

  if v_employee_no is null or v_first_name is null or v_last_name is null then
    raise exception 'EMPLOYEE_IDENTITY_REQUIRED';
  end if;
  if v_end is not null and v_start is not null and v_end<v_start then
    raise exception 'INVALID_EMPLOYMENT_DATES';
  end if;
  if v_nominal is null or v_max_monthly is null or v_max_weekly is null
    or v_max_consecutive is null
    or v_nominal not between 0 and 44640
    or v_max_monthly not between v_nominal and 44640
    or v_max_weekly not between 0 and 10080
    or v_max_consecutive not between 1 and 31
    or (v_minimum_rest is not null and v_minimum_rest not between 0 and 2880)
    or (v_only_morning and v_only_evening) then
    raise exception 'INVALID_EMPLOYEE_LIMITS';
  end if;
  if exists(select 1 from public.employees e
      where e.employee_no=v_employee_no and e.id is distinct from v_employee_id) then
    raise exception 'EMPLOYEE_NUMBER_ALREADY_EXISTS';
  end if;
  if v_email is not null and exists(select 1 from public.employees e
      where lower(e.email)=v_email and e.id is distinct from v_employee_id) then
    raise exception 'EMPLOYEE_EMAIL_ALREADY_EXISTS';
  end if;

  if v_employee_id is null then
    insert into public.employees(
      employee_no,first_name,last_name,email,primary_role,
      monthly_nominal_minutes,max_weekly_minutes,max_monthly_minutes,
      max_consecutive_days,minimum_rest_minutes,only_morning,only_evening,
      no_weekends,preferred_shift,active,employment_start,employment_end
    ) values(
      v_employee_no,v_first_name,v_last_name,v_email,null,
      v_nominal,v_max_weekly,v_max_monthly,v_max_consecutive,v_minimum_rest,
      v_only_morning,v_only_evening,v_no_weekends,v_preferred_shift,false,
      v_start,v_end
    ) returning id into v_employee_id;

    insert into public.matrix_employee_profiles_v2(
      matrix_version_id,employee_id,employee_no,first_name,last_name,email,
      active,employment_start,employment_end,nominal_monthly_minutes,
      maximum_monthly_minutes,maximum_weekly_minutes,maximum_consecutive_days,
      minimum_rest_minutes,only_morning,only_evening,no_weekends,
      preferred_shift_code,created_by,updated_by
    ) values(
      v_matrix,v_employee_id,v_employee_no,v_first_name,v_last_name,v_email,
      true,v_start,v_end,v_nominal,v_max_monthly,v_max_weekly,v_max_consecutive,
      v_minimum_rest,v_only_morning,v_only_evening,v_no_weekends,
      v_preferred_shift,auth.uid(),auth.uid()
    ) returning * into v_profile;
  else
    update public.matrix_employee_profiles_v2 set
      employee_no=v_employee_no,first_name=v_first_name,last_name=v_last_name,
      email=v_email,employment_start=v_start,employment_end=v_end,
      nominal_monthly_minutes=v_nominal,maximum_monthly_minutes=v_max_monthly,
      maximum_weekly_minutes=v_max_weekly,
      maximum_consecutive_days=v_max_consecutive,
      minimum_rest_minutes=v_minimum_rest,only_morning=v_only_morning,
      only_evening=v_only_evening,no_weekends=v_no_weekends,
      preferred_shift_code=v_preferred_shift,updated_by=auth.uid(),updated_at=now()
    where id=v_profile.id returning * into v_profile;
  end if;

  if p_data ? 'primaryRoleId' then
    update public.matrix_employee_roles_v2 set is_primary=false
    where matrix_version_id=v_matrix and employee_id=v_employee_id and is_primary;
    if v_primary_role is not null then
      if not exists(select 1 from public.matrix_roles_v2 r
          where r.id=v_primary_role and r.matrix_version_id=v_matrix and r.active) then
        raise exception 'ROLE_NOT_IN_MATRIX_V2';
      end if;
      insert into public.matrix_employee_roles_v2(
        matrix_version_id,employee_id,role_id,is_primary,can_lead,active
      ) values(v_matrix,v_employee_id,v_primary_role,true,false,true)
      on conflict(matrix_version_id,employee_id,role_id) do update set
        is_primary=true,active=true;
    end if;
  end if;

  if p_data ? 'homeLocationId' then
    update public.matrix_employee_locations_v2 set home_location=false
    where matrix_version_id=v_matrix and employee_id=v_employee_id and home_location;
    if v_home_location is not null then
      if not exists(select 1 from public.matrix_locations_v2 l
          where l.id=v_home_location and l.matrix_version_id=v_matrix and l.active) then
        raise exception 'LOCATION_NOT_IN_MATRIX_V2';
      end if;
      insert into public.matrix_employee_locations_v2(
        matrix_version_id,employee_id,location_id,standard_allowed,
        overtime_allowed,home_location,active
      ) values(v_matrix,v_employee_id,v_home_location,true,false,true,true)
      on conflict(matrix_version_id,employee_id,location_id) do update set
        standard_allowed=true,home_location=true,active=true;
    end if;
  end if;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_v2_employee',v_employee_id::text,'UPSERT',
    jsonb_build_object('matrixVersionId',v_matrix,'employeeNo',v_employee_no,
      'active',v_profile.active,'employmentStart',v_start,'employmentEnd',v_end));
  return jsonb_build_object('id',v_employee_id,'profileId',v_profile.id,
    'matrixVersionId',v_matrix);
end;
$$;


ALTER FUNCTION "public"."matrix_v2_employee_save_v2"("p_employee_id" "uuid", "p_data" "jsonb") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_employee_save_v2"("p_employee_id" "uuid", "p_data" "jsonb"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_employee_save_v2"("p_employee_id" "uuid", "p_data" "jsonb") IS 'Adds or edits an employee only inside the current Matrix v2 draft.';


--
-- Name: matrix_v2_ensure_first_run_uat_v1(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_ensure_first_run_uat_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid();
  v_matrix uuid;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;

  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));

  select mv.id into v_matrix
  from public.matrix_versions mv
  where mv.status in ('DRAFT','ACTIVE')
  order by (mv.status='DRAFT') desc,mv.version desc
  limit 1;

  if v_matrix is not null then
    return jsonb_build_object(
      'created',false,'matrixVersionId',v_matrix,'reason','USABLE_MATRIX_EXISTS'
    );
  end if;

  v_matrix:=solver_private.matrix_v2_create_safe_first_run_uat_v1(v_actor);
  return jsonb_build_object(
    'created',true,'matrixVersionId',v_matrix,'reason','SAFE_FIRST_RUN_CREATED'
  );
end;
$$;


ALTER FUNCTION "public"."matrix_v2_ensure_first_run_uat_v1"() OWNER TO "postgres";

--
-- Name: matrix_v2_finance_import_apply_uat_v1("jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_finance_import_apply_uat_v1"("p_payload" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '60s'
    SET "lock_timeout" TO '60s'
    AS $$
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


ALTER FUNCTION "public"."matrix_v2_finance_import_apply_uat_v1"("p_payload" "jsonb") OWNER TO "postgres";

--
-- Name: matrix_v2_finance_import_preview_uat_v1("jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_finance_import_preview_uat_v1"("p_payload" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '60s'
    SET "lock_timeout" TO '60s'
    AS $_$
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
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object('sheet','Finanse pracowników','row',v_source_row,'code','INVALID_CURRENCY','message',format('Waluta musi być zgodna z konfiguracją firmy: %s.',v_currency)));
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
$_$;


ALTER FUNCTION "public"."matrix_v2_finance_import_preview_uat_v1"("p_payload" "jsonb") OWNER TO "postgres";

--
-- Name: matrix_v2_finance_step_skip_uat_v2("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_finance_step_skip_uat_v2"("p_employee_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_matrix uuid;
  v_employee_no text;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE')) then raise exception 'FORBIDDEN'; end if;
  select profile.matrix_version_id,profile.employee_no
  into v_matrix,v_employee_no
  from public.matrix_employee_profiles_v2 profile
  join public.matrix_versions version on version.id=profile.matrix_version_id
  where profile.employee_id=p_employee_id and version.status='DRAFT'
  order by version.version desc limit 1;
  if v_matrix is null then raise exception 'MATRIX_EMPLOYEE_NOT_FOUND'; end if;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_v2_employee_finance',p_employee_id::text,
    'PAY_RATE_STEP_SKIPPED',jsonb_build_object(
      'matrixVersionId',v_matrix,'employeeNo',v_employee_no,
      'publicationRemainsBlocked',true
    ));
  return jsonb_build_object('employeeId',p_employee_id,'skipped',true);
end;
$$;


ALTER FUNCTION "public"."matrix_v2_finance_step_skip_uat_v2"("p_employee_id" "uuid") OWNER TO "postgres";

--
-- Name: matrix_v2_full_import_apply_raw_uat_v1("jsonb", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_full_import_apply_raw_uat_v1"("p_payload" "jsonb", "p_mode" "text" DEFAULT 'UPDATE'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_configuration jsonb:=coalesce(p_payload->'configuration','{}'::jsonb);
  v_configuration_without_rates jsonb;
  v_finance jsonb:=coalesce(p_payload->'finance','{}'::jsonb);
  v_configuration_result jsonb;
  v_finance_result jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  v_configuration_without_rates:=jsonb_set(v_configuration,'{employees}',coalesce((
    select jsonb_agg(value-'baseRate') from jsonb_array_elements(coalesce(v_configuration->'employees','[]'::jsonb))
  ),'[]'::jsonb),true);
  perform solver_private.matrix_v2_full_import_phase_uat_v1(v_configuration,'PRE');
  v_configuration_result:=public.matrix_v2_import_apply_uat_v5(v_configuration_without_rates,p_mode);
  perform solver_private.matrix_v2_full_import_phase_uat_v1(v_configuration,'POST');
  v_finance_result:=public.matrix_v2_finance_import_apply_uat_v1(
    solver_private.matrix_v2_full_finance_payload_uat_v1(v_finance));
  return v_configuration_result||jsonb_build_object('finance',v_finance_result,'atomic',true,'scope','FULL_COMPANY');
exception when others then
  if sqlerrm like 'FULL_IMPORT_%' or sqlerrm like 'MATRIX_%' or sqlerrm like 'INVALID_%'
    or sqlerrm like 'EMPLOYEE_%' or sqlerrm like 'PAY_RATE_%' or sqlerrm like 'OVERLAPPING_%'
    or sqlerrm like 'FINANCE_%' then raise; end if;
  raise exception 'FULL_IMPORT_APPLY_FAILED|%|%|%',gen_random_uuid(),sqlstate,sqlerrm;
end;
$$;


ALTER FUNCTION "public"."matrix_v2_full_import_apply_raw_uat_v1"("p_payload" "jsonb", "p_mode" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_full_import_apply_raw_uat_v1"("p_payload" "jsonb", "p_mode" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_full_import_apply_raw_uat_v1"("p_payload" "jsonb", "p_mode" "text") IS 'UAT-only atomic restore of every business input from one GRAFIK PRO workbook; strict OWNER/ADMIN boundary.';


--
-- Name: matrix_v2_full_import_apply_uat_v1("jsonb", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_full_import_apply_uat_v1"("p_payload" "jsonb", "p_mode" "text" DEFAULT 'UPDATE'::"text") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '60s'
    SET "lock_timeout" TO '60s'
    AS $$
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


ALTER FUNCTION "public"."matrix_v2_full_import_apply_uat_v1"("p_payload" "jsonb", "p_mode" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_full_import_apply_uat_v1"("p_payload" "jsonb", "p_mode" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_full_import_apply_uat_v1"("p_payload" "jsonb", "p_mode" "text") IS 'UAT-only atomic full company import. Filters duplicate inline capability grants before applying the existing validated contract.';


--
-- Name: matrix_v2_full_import_preview_raw_uat_v1("jsonb", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_full_import_preview_raw_uat_v1"("p_payload" "jsonb", "p_mode" "text" DEFAULT 'UPDATE'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "public"."matrix_v2_full_import_preview_raw_uat_v1"("p_payload" "jsonb", "p_mode" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_full_import_preview_raw_uat_v1"("p_payload" "jsonb", "p_mode" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_full_import_preview_raw_uat_v1"("p_payload" "jsonb", "p_mode" "text") IS 'UAT-only atomic preview for the full company workbook; dedicated finance rows satisfy rate readiness without duplicate legacy warnings.';


--
-- Name: matrix_v2_full_import_preview_uat_v1("jsonb", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_full_import_preview_uat_v1"("p_payload" "jsonb", "p_mode" "text" DEFAULT 'UPDATE'::"text") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    SET "statement_timeout" TO '60s'
    SET "lock_timeout" TO '60s'
    AS $$
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


ALTER FUNCTION "public"."matrix_v2_full_import_preview_uat_v1"("p_payload" "jsonb", "p_mode" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_full_import_preview_uat_v1"("p_payload" "jsonb", "p_mode" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_full_import_preview_uat_v1"("p_payload" "jsonb", "p_mode" "text") IS 'UAT-only full company import preview. Detailed employee capability rows are authoritative over convenience columns.';


--
-- Name: matrix_v2_has_any_manager_scope_uat_v1(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_has_any_manager_scope_uat_v1"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select auth.uid() is not null and (
    public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or exists(
      select 1 from public.matrix_scope_grants_v2 grant_row
      where grant_row.auth_user_id=auth.uid() and grant_row.active
        and (
          (grant_row.app_role='ROLE_MANAGER' and grant_row.role_logical_id is not null)
          or (grant_row.app_role='LOCATION_MANAGER' and grant_row.location_logical_id is not null)
        )
    )
  );
$$;


ALTER FUNCTION "public"."matrix_v2_has_any_manager_scope_uat_v1"() OWNER TO "postgres";

--
-- Name: matrix_v2_import_apply_alpha16("jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_import_apply_alpha16"("p_payload" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_legacy_rows text;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  select string_agg((legacy.ordinality+1)::text,',' order by legacy.ordinality)
  into v_legacy_rows
  from jsonb_array_elements(coalesce(p_payload->'roleDuties','[]'::jsonb))
    with ordinality legacy(value,ordinality)
  where solver_private.mx_k10_legacy_role_duty_payload_v1(legacy.value);
  if v_legacy_rows is not null then
    raise exception 'LEGACY_PERIOD_DEMAND_REJECTED rows=%: move required counts to exact shifts in OBSADA',v_legacy_rows;
  end if;
  return public.matrix_v2_import_apply_before_mx_k10(p_payload);
end;
$$;


ALTER FUNCTION "public"."matrix_v2_import_apply_alpha16"("p_payload" "jsonb") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_import_apply_alpha16"("p_payload" "jsonb"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_import_apply_alpha16"("p_payload" "jsonb") IS 'MX-K10: import apply is fail-closed for retired broad role-duty demand fields.';


--
-- Name: matrix_v2_import_apply_before_mx_k10("jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_import_apply_before_mx_k10"("p_payload" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_preview jsonb;
  v_matrix uuid;
  v_row jsonb;
  v_location_ids jsonb;
  v_role uuid;
  v_location uuid;
  v_shift uuid;
  v_scenario uuid;
  v_duty uuid;
  v_existing uuid;
  v_result jsonb;
  v_employee uuid;
  v_rate_id uuid;
  v_currency text;
  v_effective date;
  v_applied integer:=0;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  v_preview:=public.matrix_v2_import_preview_alpha16(p_payload);
  if not (v_preview->>'valid')::boolean then
    raise exception 'MATRIX_IMPORT_HAS_ERRORS:%',v_preview->'errors';
  end if;
  v_matrix:=(v_preview->>'matrixVersionId')::uuid;
  select upper(mv.settings->>'currency'),coalesce(mv.effective_from,current_date)
  into v_currency,v_effective from public.matrix_versions mv where mv.id=v_matrix;

  for v_row in select value from jsonb_array_elements(
    coalesce(p_payload->'employees','[]'::jsonb)
  ) loop
    select profile.employee_id into v_existing
    from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=v_matrix and (
      (nullif(trim(v_row->>'employeeNo'),'') is not null
        and upper(profile.employee_no)=upper(trim(v_row->>'employeeNo')))
      or (nullif(lower(trim(v_row->>'email')),'') is not null
        and lower(profile.email)=lower(trim(v_row->>'email')))
    ) order by profile.employee_id limit 1;
    select role_row.id into v_role from public.matrix_roles_v2 role_row
    where role_row.matrix_version_id=v_matrix and role_row.active
      and upper(role_row.code)=upper(v_row->>'primaryRoleCode');
    select coalesce(jsonb_agg(location_row.id order by location_row.sort_order,
      location_row.code),'[]'::jsonb) into v_location_ids
    from public.matrix_locations_v2 location_row
    join jsonb_array_elements_text(v_row->'locationCodes') code
      on upper(code.value)=upper(location_row.code)
    where location_row.matrix_version_id=v_matrix and location_row.active;
    v_result:=public.matrix_v2_employee_save_alpha16(v_existing,jsonb_build_object(
      'firstName',trim(v_row->>'firstName'),
      'lastName',trim(v_row->>'lastName'),
      'email',nullif(lower(trim(v_row->>'email')),''),
      'primaryRoleId',v_role,'locationIds',v_location_ids,
      'employmentStart',nullif(v_row->>'employmentStart',''),
      'employmentEnd',nullif(v_row->>'employmentEnd',''),
      'nominalMonthlyMinutes',round(coalesce(nullif(replace(v_row->>'nominalHours',',','.'),'')::numeric,168)*60),
      'maximumMonthlyMinutes',round(coalesce(nullif(replace(v_row->>'maximumMonthlyHours',',','.'),'')::numeric,210)*60),
      'maximumWeeklyMinutes',round(coalesce(nullif(replace(v_row->>'maximumWeeklyHours',',','.'),'')::numeric,40)*60),
      'maximumConsecutiveDays',coalesce(nullif(v_row->>'maximumConsecutiveDays','')::integer,6),
      'minimumRestMinutes',case when nullif(v_row->>'minimumRestHours','') is null
        then null else round(replace(v_row->>'minimumRestHours',',','.')::numeric*60) end,
      'preferenceMonth',coalesce(nullif(v_row->>'preferenceMonth','')::date,v_effective),
      'shiftPeriodPreferences',coalesce(v_row->'shiftPeriodPreferences','{}'::jsonb)
    ));
    v_employee:=(v_result->>'id')::uuid;
    if nullif(v_row->>'baseRate','') is not null then
      select rate.id into v_rate_id from public.employee_pay_rates_v2 rate
      where rate.employee_id=v_employee and rate.active
        and rate.valid_from<=v_effective
        and (rate.valid_to is null or rate.valid_to>=v_effective)
      order by rate.valid_from desc limit 1;
      perform public.employee_pay_rate_save_v2(
        v_rate_id,v_employee,v_effective,null,
        round(replace(v_row->>'baseRate',',','.')::numeric*100)::bigint,
        v_currency,nullif(v_row->>'contractType',''),true
      );
    end if;
    v_applied:=v_applied+1;
  end loop;

  for v_row in select value from jsonb_array_elements(
    coalesce(p_payload->'shifts','[]'::jsonb)
  ) loop
    select location_row.id into v_location from public.matrix_locations_v2 location_row
    where location_row.matrix_version_id=v_matrix and location_row.active
      and upper(location_row.code)=upper(v_row->>'locationCode');
    select shift_row.id into v_existing from public.matrix_shift_templates_v2 shift_row
    where shift_row.matrix_version_id=v_matrix and shift_row.location_id=v_location
      and upper(shift_row.code)=upper(v_row->>'code');
    perform public.matrix_v2_admin_save_alpha16('SHIFT',v_existing,jsonb_build_object(
      'locationId',v_location,'code',upper(v_row->>'code'),'name',trim(v_row->>'name'),
      'startsAt',v_row->>'startsAt','endsAt',v_row->>'endsAt',
      'endsNextDay',coalesce((v_row->>'endsNextDay')::boolean,false),
      'days',coalesce(v_row->'days','[1,2,3,4,5,6,7]'::jsonb),
      'sortOrder',coalesce(nullif(v_row->>'sortOrder','')::integer,0),
      'active',coalesce((v_row->>'active')::boolean,true),
      'shiftPeriod',upper(v_row->>'shiftPeriod')
    ));
    v_applied:=v_applied+1;
  end loop;

  for v_row in select value from jsonb_array_elements(
    coalesce(p_payload->'roleDuties','[]'::jsonb)
  ) loop
    select role_row.id into v_role from public.matrix_roles_v2 role_row
    where role_row.matrix_version_id=v_matrix
      and upper(role_row.code)=upper(v_row->>'roleCode');
    select duty_row.id into v_duty from public.matrix_duties_v2 duty_row
    where duty_row.matrix_version_id=v_matrix
      and upper(duty_row.code)=upper(v_row->>'dutyCode');
    select link.id into v_existing from public.matrix_role_duties_v2 link
    where link.matrix_version_id=v_matrix and link.role_id=v_role and link.duty_id=v_duty;
    perform public.matrix_v2_admin_save_alpha16('ROLE_DUTY',v_existing,jsonb_build_object(
      'roleId',v_role,'dutyId',v_duty,
      'assignmentMode',upper(coalesce(v_row->>'assignmentMode','OPTIONAL')),
      'minimumCount',coalesce(nullif(v_row->>'minimumCount','')::integer,0),
      'active',coalesce((v_row->>'active')::boolean,true),
      'shiftObligation',coalesce((v_row->>'shiftObligation')::boolean,false),
      'shiftPeriod',nullif(upper(v_row->>'shiftPeriod'),'')
    ));
    v_applied:=v_applied+1;
  end loop;

  for v_row in select value from jsonb_array_elements(
    coalesce(p_payload->'staffingRules','[]'::jsonb)
  ) loop
    select scenario.id into v_scenario from public.matrix_scenarios_v2 scenario
    where scenario.matrix_version_id=v_matrix
      and upper(scenario.code)=upper(v_row->>'scenarioCode');
    select role_row.id into v_role from public.matrix_roles_v2 role_row
    where role_row.matrix_version_id=v_matrix
      and upper(role_row.code)=upper(v_row->>'roleCode');
    select shift_row.id into v_shift from public.matrix_shift_templates_v2 shift_row
    join public.matrix_locations_v2 location_row on location_row.id=shift_row.location_id
    where shift_row.matrix_version_id=v_matrix
      and upper(shift_row.code)=upper(v_row->>'shiftCode')
      and (nullif(v_row->>'locationCode','') is null
        or upper(location_row.code)=upper(v_row->>'locationCode'))
    order by shift_row.id limit 1;
    v_duty:=null;
    if nullif(v_row->>'dutyCode','') is not null then
      select duty_row.id into v_duty from public.matrix_duties_v2 duty_row
      where duty_row.matrix_version_id=v_matrix
        and upper(duty_row.code)=upper(v_row->>'dutyCode');
    end if;
    select rule.id into v_existing from public.matrix_staffing_rules_v2 rule
    where rule.matrix_version_id=v_matrix and rule.scenario_id=v_scenario
      and rule.shift_template_id=v_shift and rule.role_id=v_role
      and rule.duty_id is not distinct from v_duty;
    perform public.matrix_v2_admin_save_alpha16('STAFFING_RULE',v_existing,
      jsonb_build_object(
        'scenarioId',v_scenario,'shiftTemplateId',v_shift,'roleId',v_role,
        'dutyId',v_duty,'operation',upper(coalesce(v_row->>'operation','SET')),
        'countValue',case when upper(coalesce(v_row->>'operation','SET')) in ('SET','ADD')
          then coalesce(nullif(v_row->>'countValue','')::integer,0) else null end,
        'multiplierBasisPoints',null,'active',coalesce((v_row->>'active')::boolean,true),
        'sourceMetadata',jsonb_build_object('source','EXCEL_ALPHA16')
      )
    );
    v_applied:=v_applied+1;
  end loop;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_v2_import',v_matrix::text,'APPLY',jsonb_build_object(
    'appliedRows',v_applied,'summary',v_preview->'summary'
  ));
  return jsonb_build_object('appliedRows',v_applied,'summary',v_preview->'summary');
end;
$$;


ALTER FUNCTION "public"."matrix_v2_import_apply_before_mx_k10"("p_payload" "jsonb") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_import_apply_before_mx_k10"("p_payload" "jsonb"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_import_apply_before_mx_k10"("p_payload" "jsonb") IS 'Atomic OWNER/ADMIN Matrix import after the same database validation used by preview.';


--
-- Name: matrix_v2_import_apply_uat_v2("jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_import_apply_uat_v2"("p_payload" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "public"."matrix_v2_import_apply_uat_v2"("p_payload" "jsonb") OWNER TO "postgres";

--
-- Name: matrix_v2_import_apply_uat_v3("jsonb", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_import_apply_uat_v3"("p_payload" "jsonb", "p_mode" "text" DEFAULT 'UPDATE'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_mode text:=upper(trim(coalesce(p_mode,'UPDATE')));
  v_preview jsonb;
  v_normalized jsonb;
  v_result jsonb;
  v_matrix uuid;
  v_apply_payload jsonb;
  v_profile public.matrix_employee_profiles_v2%rowtype;
  v_row jsonb;
  v_employee uuid;
  v_existing_rate public.employee_pay_rates_v2%rowtype;
  v_rate_start date;
  v_rate_end date;
  v_employment_end date;
  v_next_rate_start date;
  v_rate_amount bigint;
  v_effective date;
  v_currency text;
  v_archived integer:=0;
  v_location uuid;
  v_location_grant jsonb;
  v_profile_active boolean;
  v_desired_active boolean;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  v_preview:=public.matrix_v2_import_preview_uat_v3(p_payload,v_mode);
  if not (v_preview->>'valid')::boolean then raise exception 'MATRIX_IMPORT_HAS_ERRORS'; end if;
  v_matrix:=(v_preview->>'matrixVersionId')::uuid;
  v_normalized:=solver_private.matrix_v2_import_normalize_uat_v3(p_payload,v_matrix);
  -- Rates are saved below with the later of the workbook month (when present),
  -- the Matrix effective date and the employee's start date.  The older
  -- importer used only the Matrix date and could create a rate before
  -- employment or in a technical draft month unrelated to the schedule.
  select coalesce(jsonb_agg(
    (source.value-'baseRate')||jsonb_build_object('baseRate','')
    order by source.ordinality
  ),'[]'::jsonb) into v_apply_payload
  from jsonb_array_elements(coalesce(v_normalized->'employees','[]'::jsonb))
    with ordinality source(value,ordinality);
  v_apply_payload:=jsonb_set(v_normalized,'{employees}',v_apply_payload,true);
  v_result:=public.matrix_v2_import_apply_uat_v2(v_apply_payload);
  select matrix.effective_from,upper(matrix.settings->>'currency')
  into v_effective,v_currency
  from public.matrix_versions matrix where matrix.id=v_matrix;

  -- The v2 importer predates the Apps Script columns that distinguish normal
  -- and overtime location access and therefore deliberately cannot persist
  -- them.  Apply those explicit grants, employee shift limits and active state
  -- only when the workbook actually contains the corresponding fields.
  for v_row in select value from jsonb_array_elements(
    coalesce(v_normalized->'employees','[]'::jsonb)
  ) loop
    select profile.employee_id,profile.active into v_employee,v_profile_active
    from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=v_matrix and (
      (nullif(trim(v_row->>'employeeNo'),'') is not null
        and upper(profile.employee_no)=upper(trim(v_row->>'employeeNo')))
      or (nullif(lower(trim(v_row->>'email')),'') is not null
        and lower(profile.email)=lower(trim(v_row->>'email')))
    ) order by profile.employee_id limit 1;
    if v_employee is null then
      raise exception 'IMPORTED_EMPLOYEE_NOT_FOUND|%|%',
        coalesce(v_row->>'employeeNo',''),coalesce(v_row->>'email','');
    end if;

    if v_row ? 'onlyMorning' or v_row ? 'onlyEvening' or v_row ? 'noWeekends' then
      update public.matrix_employee_profiles_v2 profile set
        only_morning=case when v_row ? 'onlyMorning'
          then (v_row->>'onlyMorning')::boolean else profile.only_morning end,
        only_evening=case when v_row ? 'onlyEvening'
          then (v_row->>'onlyEvening')::boolean else profile.only_evening end,
        no_weekends=case when v_row ? 'noWeekends'
          then (v_row->>'noWeekends')::boolean else profile.no_weekends end,
        updated_by=auth.uid(),updated_at=now()
      where profile.matrix_version_id=v_matrix and profile.employee_id=v_employee;
    end if;

    if v_row ? 'locationGrants' then
      update public.matrix_employee_locations_v2 location_grant set
        standard_allowed=false,overtime_allowed=false,home_location=false,active=false
      where location_grant.matrix_version_id=v_matrix
        and location_grant.employee_id=v_employee;
      for v_location_grant in select value from jsonb_array_elements(v_row->'locationGrants')
      loop
        select location_row.id into v_location
        from public.matrix_locations_v2 location_row
        where location_row.matrix_version_id=v_matrix and location_row.active
          and upper(location_row.code)=upper(v_location_grant->>'code');
        if v_location is null then raise exception 'LOCATION_NOT_IN_MATRIX_V2'; end if;
        insert into public.matrix_employee_locations_v2(
          matrix_version_id,employee_id,location_id,standard_allowed,
          overtime_allowed,home_location,active
        ) values(
          v_matrix,v_employee,v_location,
          coalesce((v_location_grant->>'standardAllowed')::boolean,false),
          coalesce((v_location_grant->>'overtimeAllowed')::boolean,false),
          coalesce((v_location_grant->>'homeLocation')::boolean,false),true
        ) on conflict(matrix_version_id,employee_id,location_id) do update set
          standard_allowed=excluded.standard_allowed,
          overtime_allowed=excluded.overtime_allowed,
          home_location=excluded.home_location,active=true;
      end loop;
    end if;

    -- When the workbook carries a duty dictionary, its employee columns are a
    -- complete statement for those duties: TAK activates the capability and a
    -- blank/NIE cell withdraws it.  Without this step an unchecked Excel cell
    -- could never remove an obsolete capability.
    if v_row ? 'dutyCodes' and jsonb_typeof(v_row->'dutyCodes')='array' then
      update public.matrix_employee_duties_v2 capability set
        active=false,updated_at=now()
      from public.matrix_duties_v2 duty
      where capability.matrix_version_id=v_matrix
        and capability.employee_id=v_employee
        and capability.duty_id=duty.id
        and duty.matrix_version_id=v_matrix
        and upper(duty.code) in (
          select upper(code.value)
          from jsonb_array_elements_text(v_row->'dutyCodes') code
        )
        and not exists(
          select 1
          from jsonb_array_elements(coalesce(v_normalized->'employeeDuties','[]'::jsonb)) imported
          where (
              (nullif(trim(v_row->>'employeeNo'),'') is not null
                and upper(coalesce(imported.value->>'employeeNo',''))=upper(trim(v_row->>'employeeNo')))
              or (nullif(lower(trim(v_row->>'email')),'') is not null
                and lower(coalesce(imported.value->>'email',''))=lower(trim(v_row->>'email')))
            )
            and upper(coalesce(imported.value->>'dutyCode',''))=upper(duty.code)
            and coalesce((imported.value->>'active')::boolean,true)
        );
    end if;

    if v_row ? 'active' then
      v_desired_active:=(v_row->>'active')::boolean;
      if v_desired_active is distinct from v_profile_active then
        perform public.matrix_v2_employee_archive_v2(
          v_employee,
          case when v_desired_active then null
            else 'Archiwizacja zgodna z polem AKTYWNY w imporcie Matrixa.' end,
          not v_desired_active
        );
      end if;
    end if;
  end loop;

  for v_row in select value from jsonb_array_elements(
    coalesce(v_normalized->'employees','[]'::jsonb)
  ) where nullif(value->>'baseRate','') is not null
  loop
    select profile.employee_id,greatest(
      coalesce(nullif(v_row->>'preferenceMonth','')::date,v_effective),
      coalesce(profile.employment_start,
        coalesce(nullif(v_row->>'preferenceMonth','')::date,v_effective))
    ),profile.employment_end into v_employee,v_rate_start,v_employment_end
    from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=v_matrix and (
      (nullif(trim(v_row->>'employeeNo'),'') is not null
        and upper(profile.employee_no)=upper(trim(v_row->>'employeeNo')))
      or (nullif(lower(trim(v_row->>'email')),'') is not null
        and lower(profile.email)=lower(trim(v_row->>'email')))
    ) order by profile.employee_id limit 1;
    if v_employee is null then
      raise exception 'IMPORTED_EMPLOYEE_NOT_FOUND|%|%',
        coalesce(v_row->>'employeeNo',''),coalesce(v_row->>'email','');
    end if;
    select min(rate.valid_from) into v_next_rate_start
    from public.employee_pay_rates_v2 rate
    where rate.employee_id=v_employee and rate.active
      and rate.valid_from>v_rate_start;
    v_rate_end:=case
      when v_next_rate_start is null then v_employment_end
      when v_employment_end is null then v_next_rate_start-1
      else least(v_employment_end,v_next_rate_start-1)
    end;
    select * into v_existing_rate
    from public.employee_pay_rates_v2 rate
    where rate.employee_id=v_employee and rate.active
      and rate.valid_from<=v_rate_start
      and (rate.valid_to is null or rate.valid_to>=v_rate_start)
    order by rate.valid_from desc,rate.id limit 1;
    v_rate_amount:=round(replace(v_row->>'baseRate',',','.')::numeric*100)::bigint;
    -- Re-importing an unchanged workbook is idempotent.  Do not split a rate
    -- period merely because the same amount and contract were supplied again.
    if v_existing_rate.id is not null
      and v_existing_rate.base_rate_minor=v_rate_amount
      and upper(coalesce(v_existing_rate.currency,''))=upper(coalesce(v_currency,''))
      and upper(coalesce(v_existing_rate.contract_type,''))=
        upper(coalesce(nullif(v_row->>'contractType',''),'')) then
      continue;
    end if;
    if v_existing_rate.id is not null and v_existing_rate.valid_from<v_rate_start then
      perform public.employee_pay_rate_save_v2(
        v_existing_rate.id,v_employee,v_existing_rate.valid_from,v_rate_start-1,
        v_existing_rate.base_rate_minor,v_existing_rate.currency,
        v_existing_rate.contract_type,v_existing_rate.active
      );
      v_existing_rate.id:=null;
    end if;
    perform public.employee_pay_rate_save_v2(
      v_existing_rate.id,v_employee,v_rate_start,v_rate_end,v_rate_amount,
      v_currency,nullif(v_row->>'contractType',''),true
    );
  end loop;

  if v_mode='REPLACE' then
    for v_profile in
      select profile.* from public.matrix_employee_profiles_v2 profile
      where profile.matrix_version_id=v_matrix and profile.active
        and not exists(
          select 1 from jsonb_array_elements(coalesce(v_normalized->'employees','[]'::jsonb)) imported
          where (nullif(trim(imported.value->>'employeeNo'),'') is not null
              and upper(profile.employee_no)=upper(trim(imported.value->>'employeeNo')))
            or (nullif(lower(trim(imported.value->>'email')),'') is not null
              and lower(profile.email)=lower(trim(imported.value->>'email')))
        )
      for update
    loop
      perform public.matrix_v2_employee_archive_v2(
        v_profile.employee_id,
        'Archiwizacja automatyczna: pracownik nie wystąpił w imporcie zastępującym bazę.',
        true
      );
      v_archived:=v_archived+1;
    end loop;
  end if;
  return v_result||jsonb_build_object('mode',v_mode,'archivedEmployees',v_archived);
end;
$$;


ALTER FUNCTION "public"."matrix_v2_import_apply_uat_v3"("p_payload" "jsonb", "p_mode" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_import_apply_uat_v3"("p_payload" "jsonb", "p_mode" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_import_apply_uat_v3"("p_payload" "jsonb", "p_mode" "text") IS 'UPDATE upserts only workbook rows. REPLACE additionally archives draft employees absent from the workbook, preserving version and audit history.';


--
-- Name: matrix_v2_import_apply_uat_v4("jsonb", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_import_apply_uat_v4"("p_payload" "jsonb", "p_mode" "text" DEFAULT 'UPDATE'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "public"."matrix_v2_import_apply_uat_v4"("p_payload" "jsonb", "p_mode" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_import_apply_uat_v4"("p_payload" "jsonb", "p_mode" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_import_apply_uat_v4"("p_payload" "jsonb", "p_mode" "text") IS 'Atomic Matrix import boundary with explicit dependency checks and correlated unexpected errors.';


--
-- Name: matrix_v2_import_apply_uat_v5("jsonb", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_import_apply_uat_v5"("p_payload" "jsonb", "p_mode" "text" DEFAULT 'UPDATE'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "public"."matrix_v2_import_apply_uat_v5"("p_payload" "jsonb", "p_mode" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_import_apply_uat_v5"("p_payload" "jsonb", "p_mode" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_import_apply_uat_v5"("p_payload" "jsonb", "p_mode" "text") IS 'Atomic v4 import plus first-rate coverage from Matrix activation; preferenceMonth remains a shift-preference month only.';


--
-- Name: matrix_v2_import_preview_alpha16("jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_import_preview_alpha16"("p_payload" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_result jsonb;
  v_legacy_errors jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  v_result:=public.matrix_v2_import_preview_before_mx_k10(p_payload);
  select coalesce(jsonb_agg(jsonb_build_object(
    'sheet','ROLE-OBOWIĄZKI','row',legacy.ordinality+1,
    'column','Znaczenie / Minimum / Pora',
    'code','LEGACY_PERIOD_DEMAND_REJECTED',
    'message','Stary szeroki wymóg rola–obowiązek jest wycofany. W arkuszu Obsada wskaż dokładny Kod zmiany, Kod roli, opcjonalny Kod obowiązku i Liczbę osób.'
  ) order by legacy.ordinality),'[]'::jsonb)
  into v_legacy_errors
  from jsonb_array_elements(coalesce(p_payload->'roleDuties','[]'::jsonb))
    with ordinality legacy(value,ordinality)
  where solver_private.mx_k10_legacy_role_duty_payload_v1(legacy.value);

  if jsonb_array_length(v_legacy_errors)>0 then
    v_result:=jsonb_set(v_result,'{valid}','false'::jsonb,true);
    v_result:=jsonb_set(
      v_result,'{errors}',coalesce(v_result->'errors','[]'::jsonb)||v_legacy_errors,true
    );
  end if;
  return v_result;
end;
$$;


ALTER FUNCTION "public"."matrix_v2_import_preview_alpha16"("p_payload" "jsonb") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_import_preview_alpha16"("p_payload" "jsonb"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_import_preview_alpha16"("p_payload" "jsonb") IS 'MX-K10: previews reject broad role-duty periods/minimums and direct the owner to exact shift staffing.';


--
-- Name: matrix_v2_import_preview_before_mx_k10("jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_import_preview_before_mx_k10"("p_payload" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_matrix uuid;
  v_errors jsonb:='[]'::jsonb;
  v_warnings jsonb:='[]'::jsonb;
  v_row jsonb;
  v_index integer;
  v_total integer:=0;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if p_payload is null or jsonb_typeof(p_payload)<>'object' then
    raise exception 'INVALID_MATRIX_IMPORT_PAYLOAD';
  end if;
  select mv.id into v_matrix from public.matrix_versions mv
  where mv.status='DRAFT' and mv.schema_version>=2
  order by mv.version desc limit 1;
  if v_matrix is null then raise exception 'NO_MATRIX_V2_DRAFT'; end if;
  if jsonb_typeof(coalesce(p_payload->'employees','[]'::jsonb))<>'array'
    or jsonb_typeof(coalesce(p_payload->'shifts','[]'::jsonb))<>'array'
    or jsonb_typeof(coalesce(p_payload->'staffingRules','[]'::jsonb))<>'array'
    or jsonb_typeof(coalesce(p_payload->'roleDuties','[]'::jsonb))<>'array' then
    raise exception 'INVALID_MATRIX_IMPORT_SECTIONS';
  end if;
  v_total:=jsonb_array_length(coalesce(p_payload->'employees','[]'::jsonb))
    +jsonb_array_length(coalesce(p_payload->'shifts','[]'::jsonb))
    +jsonb_array_length(coalesce(p_payload->'staffingRules','[]'::jsonb))
    +jsonb_array_length(coalesce(p_payload->'roleDuties','[]'::jsonb));
  if v_total=0 then
    v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
      'sheet','PLIK','row',0,'code','EMPTY_IMPORT',
      'message','Plik nie zawiera obsługiwanych wierszy.'
    ));
  elsif v_total>5000 then
    v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
      'sheet','PLIK','row',0,'code','IMPORT_TOO_LARGE',
      'message','Jednorazowy import może zawierać najwyżej 5000 wierszy.'
    ));
  end if;

  for v_row,v_index in
    select row.value,row.ordinality::integer
    from jsonb_array_elements(coalesce(p_payload->'employees','[]'::jsonb))
      with ordinality row(value,ordinality)
  loop
    if nullif(trim(v_row->>'firstName'),'') is null
      or nullif(trim(v_row->>'lastName'),'') is null then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','EMPLOYEE_NAME_REQUIRED',
        'message','Podaj imię i nazwisko.'
      ));
    end if;
    if nullif(trim(v_row->>'employeeNo'),'') is not null
      and not exists(select 1 from public.matrix_employee_profiles_v2 profile
        where profile.matrix_version_id=v_matrix
          and upper(profile.employee_no)=upper(trim(v_row->>'employeeNo'))) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','EMPLOYEE_NUMBER_NOT_FOUND',
        'message','Podany numer nie istnieje. Dla nowej osoby pozostaw numer pusty — system nada go automatycznie.'
      ));
    end if;
    if nullif(lower(trim(v_row->>'email')),'') is not null
      and (select count(*) from jsonb_array_elements(
        coalesce(p_payload->'employees','[]'::jsonb)
      ) duplicate where lower(trim(duplicate.value->>'email'))=
        lower(trim(v_row->>'email'))) > 1 then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','DUPLICATE_EMPLOYEE_EMAIL',
        'message','Ten sam adres e-mail występuje w pliku więcej niż raz.'
      ));
    end if;
    if nullif(trim(v_row->>'employeeNo'),'') is not null
      and (select count(*) from jsonb_array_elements(
        coalesce(p_payload->'employees','[]'::jsonb)
      ) duplicate where upper(trim(duplicate.value->>'employeeNo'))=
        upper(trim(v_row->>'employeeNo'))) > 1 then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','DUPLICATE_EMPLOYEE_NUMBER',
        'message','Ten sam numer pracownika występuje w pliku więcej niż raz.'
      ));
    end if;
    if nullif(trim(v_row->>'employeeNo'),'') is not null
      and nullif(lower(trim(v_row->>'email')),'') is not null
      and exists(
        select 1
        from public.matrix_employee_profiles_v2 number_profile
        join public.matrix_employee_profiles_v2 email_profile
          on email_profile.matrix_version_id=number_profile.matrix_version_id
          and email_profile.employee_id<>number_profile.employee_id
          and lower(email_profile.email)=lower(trim(v_row->>'email'))
        where number_profile.matrix_version_id=v_matrix
          and upper(number_profile.employee_no)=upper(trim(v_row->>'employeeNo'))
      ) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','EMPLOYEE_IDENTITY_CONFLICT',
        'message','Numer pracownika i adres e-mail wskazują dwie różne osoby.'
      ));
    end if;
    if nullif(trim(v_row->>'primaryRoleCode'),'') is null
      or not exists(select 1 from public.matrix_roles_v2 role_row
        where role_row.matrix_version_id=v_matrix and role_row.active
          and upper(role_row.code)=upper(v_row->>'primaryRoleCode')) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','ROLE_NOT_FOUND',
        'message','Nie znaleziono aktywnej roli z kolumny primaryRoleCode.'
      ));
    end if;
    if jsonb_typeof(coalesce(v_row->'locationCodes','[]'::jsonb))<>'array'
      or jsonb_array_length(coalesce(v_row->'locationCodes','[]'::jsonb))=0 then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','LOCATION_REQUIRED',
        'message','Podaj co najmniej jeden zwykły lokal pracy.'
      ));
    elsif exists(
      select 1 from jsonb_array_elements_text(v_row->'locationCodes') code
      where not exists(select 1 from public.matrix_locations_v2 location_row
        where location_row.matrix_version_id=v_matrix and location_row.active
          and upper(location_row.code)=upper(code.value))
    ) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','LOCATION_NOT_FOUND',
        'message','Co najmniej jeden kod lokalu nie istnieje w Matrixie.'
      ));
    end if;
    if nullif(v_row->>'baseRate','') is null then
      v_warnings:=v_warnings||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','PAY_RATE_MISSING',
        'message','Brak stawki zablokuje późniejszą publikację Matrixa.'
      ));
    elsif (v_row->>'baseRate') !~ '^\d+([.,]\d{1,2})?$' then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','INVALID_PAY_RATE',
        'message','Stawka musi być nieujemną liczbą z maksymalnie dwoma miejscami po przecinku.'
      ));
    end if;
    if exists(select 1 from jsonb_each_text(coalesce(
      v_row->'shiftPeriodPreferences','{}'::jsonb
    )) preference where upper(preference.value) not in (
      'INHERIT','PREFERRED','NEUTRAL','AVOIDED','BLOCKED'
    )) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','INVALID_SHIFT_PREFERENCE',
        'message','Preferencja pory musi mieć wartość INHERIT, PREFERRED, NEUTRAL, AVOIDED albo BLOCKED.'
      ));
    end if;
  end loop;

  for v_row,v_index in
    select row.value,row.ordinality::integer
    from jsonb_array_elements(coalesce(p_payload->'shifts','[]'::jsonb))
      with ordinality row(value,ordinality)
  loop
    if nullif(trim(v_row->>'code'),'') is null
      or nullif(trim(v_row->>'name'),'') is null then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','ZMIANY','row',v_index+1,'code','SHIFT_IDENTITY_REQUIRED',
        'message','Podaj kod i nazwę bloku obsady.'
      ));
    end if;
    if upper(coalesce(v_row->>'shiftPeriod',''))
      not in ('MORNING','MIDDLE','EVENING') then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','ZMIANY','row',v_index+1,'code','INVALID_SHIFT_PERIOD',
        'message','Okres zmiany to MORNING, MIDDLE albo EVENING.'
      ));
    end if;
    if coalesce(v_row->>'startsAt','') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
      or coalesce(v_row->>'endsAt','') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','ZMIANY','row',v_index+1,'code','INVALID_SHIFT_TIME',
        'message','Godziny muszą mieć format HH:MM.'
      ));
    end if;
    if not exists(select 1 from public.matrix_locations_v2 location_row
      where location_row.matrix_version_id=v_matrix and location_row.active
        and upper(location_row.code)=upper(coalesce(v_row->>'locationCode',''))) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','ZMIANY','row',v_index+1,'code','LOCATION_NOT_FOUND',
        'message','Nie znaleziono lokalu dla bloku obsady.'
      ));
    end if;
    if jsonb_typeof(coalesce(v_row->'days','[]'::jsonb))<>'array'
      or jsonb_array_length(coalesce(v_row->'days','[]'::jsonb))=0
      or exists(select 1 from jsonb_array_elements_text(v_row->'days') day_value
        where day_value.value !~ '^[1-7]$') then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','ZMIANY','row',v_index+1,'code','INVALID_SHIFT_DAYS',
        'message','Podaj co najmniej jeden dzień od 1 do 7.'
      ));
    end if;
  end loop;

  for v_row,v_index in
    select row.value,row.ordinality::integer
    from jsonb_array_elements(coalesce(p_payload->'roleDuties','[]'::jsonb))
      with ordinality row(value,ordinality)
  loop
    if not exists(select 1 from public.matrix_roles_v2 role_row
      where role_row.matrix_version_id=v_matrix and role_row.active
        and upper(role_row.code)=upper(coalesce(v_row->>'roleCode',''))) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','ROLE-OBOWIĄZKI','row',v_index+1,'code','ROLE_NOT_FOUND',
        'message','Nie znaleziono aktywnej roli.'
      ));
    end if;
    if not exists(select 1 from public.matrix_duties_v2 duty_row
      where duty_row.matrix_version_id=v_matrix and duty_row.active
        and upper(duty_row.code)=upper(coalesce(v_row->>'dutyCode',''))) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','ROLE-OBOWIĄZKI','row',v_index+1,'code','DUTY_NOT_FOUND',
        'message','Nie znaleziono aktywnego obowiązku.'
      ));
    end if;
    if upper(coalesce(v_row->>'assignmentMode','OPTIONAL'))
      not in ('REQUIRED','OPTIONAL','EXTRA') then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','ROLE-OBOWIĄZKI','row',v_index+1,'code','INVALID_ASSIGNMENT_MODE',
        'message','Znaczenie to REQUIRED, OPTIONAL albo EXTRA.'
      ));
    end if;
    if coalesce((v_row->>'shiftObligation')::boolean,false)
      and upper(coalesce(v_row->>'shiftPeriod',''))
        not in ('MORNING','MIDDLE','EVENING') then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','ROLE-OBOWIĄZKI','row',v_index+1,'code','SHIFT_PERIOD_REQUIRED',
        'message','Obowiązek zmianowy wymaga pory MORNING, MIDDLE albo EVENING.'
      ));
    end if;
  end loop;

  for v_row,v_index in
    select row.value,row.ordinality::integer
    from jsonb_array_elements(coalesce(p_payload->'staffingRules','[]'::jsonb))
      with ordinality row(value,ordinality)
  loop
    if upper(coalesce(v_row->>'operation','SET')) not in ('SET','ADD','REMOVE') then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','OBSADA','row',v_index+1,'code','INVALID_OPERATION',
        'message','Import obsady obsługuje SET, ADD albo REMOVE.'
      ));
    end if;
    if upper(coalesce(v_row->>'operation','SET')) in ('SET','ADD')
      and (coalesce(v_row->>'countValue','') !~ '^\d+$'
        or (v_row->>'countValue')::integer<0) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','OBSADA','row',v_index+1,'code','INVALID_STAFFING_COUNT',
        'message','Liczba osób musi być nieujemną liczbą całkowitą.'
      ));
    end if;
    if not exists(select 1 from public.matrix_scenarios_v2 scenario
      where scenario.matrix_version_id=v_matrix and scenario.active
        and upper(scenario.code)=upper(coalesce(v_row->>'scenarioCode',''))) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','OBSADA','row',v_index+1,'code','SCENARIO_NOT_FOUND',
        'message','Nie znaleziono scenariusza.'
      ));
    end if;
    if not exists(select 1 from public.matrix_roles_v2 role_row
      where role_row.matrix_version_id=v_matrix and role_row.active
        and upper(role_row.code)=upper(coalesce(v_row->>'roleCode',''))) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','OBSADA','row',v_index+1,'code','ROLE_NOT_FOUND',
        'message','Nie znaleziono roli.'
      ));
    end if;
    if not exists(select 1 from public.matrix_shift_templates_v2 shift_row
      join public.matrix_locations_v2 location_row on location_row.id=shift_row.location_id
      where shift_row.matrix_version_id=v_matrix and shift_row.active
        and upper(shift_row.code)=upper(coalesce(v_row->>'shiftCode',''))
        and (nullif(v_row->>'locationCode','') is null
          or upper(location_row.code)=upper(v_row->>'locationCode'))) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','OBSADA','row',v_index+1,'code','SHIFT_NOT_FOUND',
        'message','Nie znaleziono zmiany lub bloku obsady.'
      ));
    end if;
  end loop;

  return jsonb_build_object(
    'valid',jsonb_array_length(v_errors)=0,
    'errors',v_errors,'warnings',v_warnings,
    'summary',jsonb_build_object(
      'employees',jsonb_array_length(coalesce(p_payload->'employees','[]'::jsonb)),
      'shifts',jsonb_array_length(coalesce(p_payload->'shifts','[]'::jsonb)),
      'staffingRules',jsonb_array_length(coalesce(p_payload->'staffingRules','[]'::jsonb)),
      'roleDuties',jsonb_array_length(coalesce(p_payload->'roleDuties','[]'::jsonb)),
      'total',v_total
    ),
    'matrixVersionId',v_matrix
  );
end;
$_$;


ALTER FUNCTION "public"."matrix_v2_import_preview_before_mx_k10"("p_payload" "jsonb") OWNER TO "postgres";

--
-- Name: FUNCTION "matrix_v2_import_preview_before_mx_k10"("p_payload" "jsonb"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."matrix_v2_import_preview_before_mx_k10"("p_payload" "jsonb") IS 'Read-only validation of normalized Excel Matrix sheets before an atomic apply.';


--
-- Name: matrix_v2_import_preview_uat_v2("jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_import_preview_uat_v2"("p_payload" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "public"."matrix_v2_import_preview_uat_v2"("p_payload" "jsonb") OWNER TO "postgres";

--
-- Name: matrix_v2_import_preview_uat_v3("jsonb", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_import_preview_uat_v3"("p_payload" "jsonb", "p_mode" "text" DEFAULT 'UPDATE'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_mode text:=upper(trim(coalesce(p_mode,'UPDATE')));
  v_preview jsonb;
  v_normalized jsonb;
  v_matrix uuid;
  v_updates integer;
  v_creates integer;
  v_archives integer:=0;
  v_archive_rows jsonb:='[]'::jsonb;
  v_errors jsonb;
  v_row jsonb;
  v_index integer;
  v_contract text;
  v_limits_invalid boolean;
  v_employee uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if v_mode not in ('UPDATE','REPLACE') then raise exception 'INVALID_IMPORT_MODE'; end if;
  v_preview:=public.matrix_v2_import_preview_uat_v2(p_payload);
  v_matrix:=(v_preview->>'matrixVersionId')::uuid;
  v_normalized:=solver_private.matrix_v2_import_normalize_uat_v3(p_payload,v_matrix);
  v_preview:=public.matrix_v2_import_preview_uat_v2(v_normalized);
  v_errors:=coalesce(v_preview->'errors','[]'::jsonb);
  for v_row,v_index in
    select source.value,source.ordinality::integer
    from jsonb_array_elements(coalesce(v_normalized->'employees','[]'::jsonb))
      with ordinality source(value,ordinality)
  loop
    v_contract:=solver_private.normalize_contract_type_v2(v_row->>'contractType');
    if nullif(trim(v_row->>'contractType'),'') is null then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','CONTRACT_TYPE_REQUIRED',
        'message','Wybierz formę współpracy. Import nie przypisuje umowy automatycznie.'
      ));
    end if;
    if (v_row ? 'active' and jsonb_typeof(v_row->'active')<>'boolean')
      or (v_row ? 'onlyMorning' and jsonb_typeof(v_row->'onlyMorning')<>'boolean')
      or (v_row ? 'onlyEvening' and jsonb_typeof(v_row->'onlyEvening')<>'boolean')
      or (v_row ? 'noWeekends' and jsonb_typeof(v_row->'noWeekends')<>'boolean') then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','INVALID_EMPLOYEE_BOOLEAN',
        'message','Pola aktywności i ograniczeń muszą mieć wartość TAK albo NIE.'
      ));
    elsif coalesce((v_row->>'onlyMorning')::boolean,false)
      and coalesce((v_row->>'onlyEvening')::boolean,false) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','CONFLICTING_SHIFT_LIMITS',
        'message','Pracownik nie może mieć jednocześnie ograniczenia tylko rano i tylko popołudnie.'
      ));
    end if;
    if v_row ? 'locationGrants' then
      if jsonb_typeof(v_row->'locationGrants')<>'array' then
        v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
          'sheet','PRACOWNICY','row',v_index+1,'code','INVALID_LOCATION_GRANTS',
          'message','Uprawnienia lokalowe muszą być listą lokali.'
        ));
      elsif exists(
        select 1 from jsonb_array_elements(v_row->'locationGrants') location_grant
        where jsonb_typeof(location_grant.value)<>'object'
          or nullif(trim(location_grant.value->>'code'),'') is null
          or not exists(select 1 from public.matrix_locations_v2 location_row
            where location_row.matrix_version_id=v_matrix and location_row.active
              and upper(location_row.code)=upper(location_grant.value->>'code'))
          or (location_grant.value ? 'standardAllowed'
            and jsonb_typeof(location_grant.value->'standardAllowed')<>'boolean')
          or (location_grant.value ? 'overtimeAllowed'
            and jsonb_typeof(location_grant.value->'overtimeAllowed')<>'boolean')
          or (location_grant.value ? 'homeLocation'
            and jsonb_typeof(location_grant.value->'homeLocation')<>'boolean')
          or not (
            case when jsonb_typeof(location_grant.value->'standardAllowed')='boolean'
              then (location_grant.value->>'standardAllowed')::boolean else false end
            or case when jsonb_typeof(location_grant.value->'overtimeAllowed')='boolean'
              then (location_grant.value->>'overtimeAllowed')::boolean else false end
            or case when jsonb_typeof(location_grant.value->'homeLocation')='boolean'
              then (location_grant.value->>'homeLocation')::boolean else false end
          )
          or (
            case when jsonb_typeof(location_grant.value->'homeLocation')='boolean'
              then (location_grant.value->>'homeLocation')::boolean else false end
            and not case when jsonb_typeof(location_grant.value->'standardAllowed')='boolean'
              then (location_grant.value->>'standardAllowed')::boolean else false end
          )
      ) or (
        select count(*) from jsonb_array_elements(v_row->'locationGrants') location_grant
        where case when jsonb_typeof(location_grant.value->'homeLocation')='boolean'
          then (location_grant.value->>'homeLocation')::boolean else false end
      )>1 or (
        select count(*) from jsonb_array_elements(v_row->'locationGrants') location_grant
      )<>(
        select count(distinct upper(trim(location_grant.value->>'code')))
        from jsonb_array_elements(v_row->'locationGrants') location_grant
      ) then
        v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
          'sheet','PRACOWNICY','row',v_index+1,'code','INVALID_LOCATION_GRANTS',
          'message','Sprawdź zwykłe, nadgodzinowe i bazowe uprawnienia do lokali. Każdy lokal może wystąpić tylko raz.'
        ));
      end if;
    end if;
    if v_row ? 'dutyCodes' then
      if jsonb_typeof(v_row->'dutyCodes')<>'array' or exists(
        select 1 from jsonb_array_elements_text(v_row->'dutyCodes') duty_code
        where not exists(
          select 1 from public.matrix_duties_v2 duty
          where duty.matrix_version_id=v_matrix and duty.active
            and upper(duty.code)=upper(duty_code.value)
        )
      ) then
        v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
          'sheet','PRACOWNICY','row',v_index+1,'code','INVALID_DUTY_COLUMNS',
          'message','Co najmniej jedna kolumna obowiązku nie odpowiada aktywnemu obowiązkowi w Matrixie.'
        ));
      end if;
    end if;
    if nullif(v_row->>'employmentStart','') is not null
      and not pg_catalog.pg_input_is_valid(v_row->>'employmentStart','date') then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','INVALID_EMPLOYMENT_START',
        'message','Data rozpoczęcia zatrudnienia jest nieprawidłowa.'
      ));
    end if;
    if nullif(v_row->>'employmentEnd','') is not null
      and not pg_catalog.pg_input_is_valid(v_row->>'employmentEnd','date') then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','INVALID_EMPLOYMENT_END',
        'message','Data zakończenia zatrudnienia jest nieprawidłowa.'
      ));
    elsif nullif(v_row->>'employmentEnd','') is not null
      and nullif(v_row->>'employmentStart','') is null then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','EMPLOYMENT_START_REQUIRED',
        'message','Data zakończenia wymaga daty rozpoczęcia zatrudnienia.'
      ));
    elsif nullif(v_row->>'employmentStart','') is not null
      and pg_catalog.pg_input_is_valid(v_row->>'employmentStart','date')
      and nullif(v_row->>'employmentEnd','') is not null
      and pg_catalog.pg_input_is_valid(v_row->>'employmentEnd','date')
      and (v_row->>'employmentEnd')::date<(v_row->>'employmentStart')::date then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','INVALID_EMPLOYMENT_DATES',
        'message','Data zakończenia nie może poprzedzać rozpoczęcia zatrudnienia.'
      ));
    end if;
    v_employee:=null;
    if (nullif(v_row->>'employmentStart','') is null
        or pg_catalog.pg_input_is_valid(v_row->>'employmentStart','date'))
      and (nullif(v_row->>'employmentEnd','') is null
        or pg_catalog.pg_input_is_valid(v_row->>'employmentEnd','date')) then
      select profile.employee_id into v_employee
      from public.matrix_employee_profiles_v2 profile
      where profile.matrix_version_id=v_matrix
        and nullif(trim(v_row->>'employeeNo'),'') is not null
        and upper(profile.employee_no)=upper(trim(v_row->>'employeeNo'));
      if v_employee is not null and exists(
        select 1 from public.employee_pay_rates_v2 rate
        where rate.employee_id=v_employee and (
          (nullif(v_row->>'employmentStart','') is not null
            and rate.valid_from<(v_row->>'employmentStart')::date)
          or (nullif(v_row->>'employmentEnd','') is not null and (
            rate.valid_from>(v_row->>'employmentEnd')::date
            or rate.valid_to is null
            or rate.valid_to>(v_row->>'employmentEnd')::date
          ))
        )
      ) then
        v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
          'sheet','PRACOWNICY','row',v_index+1,
          'code','EMPLOYMENT_DATES_CONFLICT_PAY_RATES',
          'message','Okres zatrudnienia jest sprzeczny z zapisaną historią stawek tego pracownika.'
        ));
      end if;
    end if;
    if v_contract in ('UMOWA_O_PRACE','CZESC_ETATU') and (
      nullif(v_row->>'nominalHours','') is null
      or nullif(v_row->>'maximumMonthlyHours','') is null
      or nullif(v_row->>'maximumWeeklyHours','') is null
      or nullif(v_row->>'maximumConsecutiveDays','') is null
    ) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','EMPLOYMENT_LIMITS_REQUIRED',
        'message','Dla umowy o pracę podaj nominał, limit miesięczny, limit tygodniowy i maksymalną liczbę kolejnych dni.'
      ));
    end if;
    v_limits_invalid:=coalesce(v_row->>'nominalHours','') !~ '^\d+([.,]\d+)?$'
      or coalesce(v_row->>'maximumMonthlyHours','') !~ '^\d+([.,]\d+)?$'
      or coalesce(v_row->>'maximumWeeklyHours','') !~ '^\d+([.,]\d+)?$'
      or coalesce(v_row->>'maximumConsecutiveDays','') !~ '^\d+$'
      or coalesce(v_row->>'employmentFraction','') !~ '^\d+([.,]\d+)?$'
      or (nullif(v_row->>'minimumRestHours','') is not null
        and (v_row->>'minimumRestHours') !~ '^\d+([.,]\d+)?$');
    if not v_limits_invalid then
      v_limits_invalid:=replace(v_row->>'maximumMonthlyHours',',','.')::numeric
        <replace(v_row->>'nominalHours',',','.')::numeric
        or replace(v_row->>'nominalHours',',','.')::numeric>744
        or replace(v_row->>'maximumMonthlyHours',',','.')::numeric>744
        or replace(v_row->>'maximumWeeklyHours',',','.')::numeric>168
        or (v_row->>'maximumConsecutiveDays')::integer not between 1 and 31
        or replace(v_row->>'employmentFraction',',','.')::numeric not between .01 and 1
        or (nullif(v_row->>'minimumRestHours','') is not null
          and replace(v_row->>'minimumRestHours',',','.')::numeric>48);
    end if;
    if v_limits_invalid then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','INVALID_EMPLOYEE_LIMITS',
        'message','Sprawdź nominał i limity. Limit miesięczny nie może być niższy od nominału.'
      ));
    end if;
    if nullif(v_row->>'preferenceMonth','') is not null
      and not pg_catalog.pg_input_is_valid(v_row->>'preferenceMonth','date') then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','INVALID_PREFERENCE_MONTH',
        'message','Miesiąc preferencji ma nieprawidłową datę.'
      ));
    end if;
    if upper(coalesce(v_row->>'workTimePolicy','CONTRACT_DEFAULT'))
      not in ('CONTRACT_DEFAULT','CUSTOM') then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','INVALID_WORK_TIME_POLICY',
        'message','Polityka czasu pracy to CONTRACT_DEFAULT albo CUSTOM.'
      ));
    end if;
  end loop;
  v_preview:=jsonb_set(v_preview,'{errors}',v_errors,true);
  v_preview:=jsonb_set(v_preview,'{valid}',to_jsonb(jsonb_array_length(v_errors)=0),true);

  select count(*) into v_updates
  from jsonb_array_elements(coalesce(v_normalized->'employees','[]'::jsonb)) imported
  where exists(select 1 from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=v_matrix and (
      (nullif(trim(imported.value->>'employeeNo'),'') is not null
        and upper(profile.employee_no)=upper(trim(imported.value->>'employeeNo')))
      or (nullif(lower(trim(imported.value->>'email')),'') is not null
        and lower(profile.email)=lower(trim(imported.value->>'email')))
    ));
  v_creates:=jsonb_array_length(coalesce(v_normalized->'employees','[]'::jsonb))-v_updates;
  if v_mode='REPLACE' then
    select count(*),coalesce(jsonb_agg(jsonb_build_object(
      'employeeId',profile.employee_id,'employeeNo',profile.employee_no,
      'employeeName',profile.first_name||' '||profile.last_name,
      'email',coalesce(profile.email,employee.email),
      'reason',case when exists(
        select 1 from jsonb_array_elements(coalesce(v_normalized->'employees','[]'::jsonb)) imported
        where nullif(lower(trim(imported.value->>'email')),'') is not null
          and lower(trim(imported.value->>'email')) in (
            lower(coalesce(profile.email,'')),lower(coalesce(employee.email,''))
          )
      ) then 'DUPLICATE_IDENTITY' else 'NOT_IN_FILE' end
    ) order by profile.employee_no),'[]'::jsonb)
    into v_archives,v_archive_rows
    from public.matrix_employee_profiles_v2 profile
    join public.employees employee on employee.id=profile.employee_id
    where profile.matrix_version_id=v_matrix and profile.active
      and not exists(
        select 1 from jsonb_array_elements(coalesce(v_normalized->'employees','[]'::jsonb)) imported
        where nullif(trim(imported.value->>'employeeNo'),'') is not null
          and upper(profile.employee_no)=upper(trim(imported.value->>'employeeNo'))
      );
  end if;
  v_preview:=jsonb_set(v_preview,'{summary,employeesToUpdate}',to_jsonb(v_updates),true);
  v_preview:=jsonb_set(v_preview,'{summary,employeesToCreate}',to_jsonb(v_creates),true);
  v_preview:=jsonb_set(v_preview,'{summary,employeesToArchive}',to_jsonb(v_archives),true);
  return v_preview||jsonb_build_object(
    'mode',v_mode,'employeesToArchive',v_archive_rows
  );
end;
$_$;


ALTER FUNCTION "public"."matrix_v2_import_preview_uat_v3"("p_payload" "jsonb", "p_mode" "text") OWNER TO "postgres";

--
-- Name: matrix_v2_import_preview_uat_v4("jsonb", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_import_preview_uat_v4"("p_payload" "jsonb", "p_mode" "text" DEFAULT 'UPDATE'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "public"."matrix_v2_import_preview_uat_v4"("p_payload" "jsonb", "p_mode" "text") OWNER TO "postgres";

--
-- Name: matrix_v2_import_preview_uat_v5("jsonb", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_import_preview_uat_v5"("p_payload" "jsonb", "p_mode" "text" DEFAULT 'UPDATE'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  return public.matrix_v2_import_preview_uat_v4(p_payload,p_mode);
end;
$$;


ALTER FUNCTION "public"."matrix_v2_import_preview_uat_v5"("p_payload" "jsonb", "p_mode" "text") OWNER TO "postgres";

--
-- Name: matrix_v2_is_iso_4217_currency("text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_is_iso_4217_currency"("p_currency" "text") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE STRICT
    SET "search_path" TO ''
    AS $_$
  select p_currency ~ '^[A-Z]{3}$' and position(
    ' '||p_currency||' ' in
    ' AED AFN ALL AMD ANG AOA ARS AUD AWG AZN BAM BBD BDT BGN BHD BIF BMD BND BOB BOV BRL BSD BTN BWP BYN BZD CAD CDF CHE CHF CHW CLF CLP CNY COP COU CRC CUC CUP CVE CZK DJF DKK DOP DZD EGP ERN ETB EUR FJD FKP GBP GEL GHS GIP GMD GNF GTQ GYD HKD HNL HTG HUF IDR ILS INR IQD IRR ISK JMD JOD JPY KES KGS KHR KMF KPW KRW KWD KYD KZT LAK LBP LKR LRD LSL LYD MAD MDL MGA MKD MMK MNT MOP MRU MUR MVR MWK MXN MXV MYR MZN NAD NGN NIO NOK NPR NZD OMR PAB PEN PGK PHP PKR PLN PYG QAR RON RSD RUB RWF SAR SBD SCR SDG SEK SGD SHP SLE SLL SOS SRD SSP STN SVC SYP SZL THB TJS TMT TND TOP TRY TTD TWD TZS UAH UGX USD USN UYI UYU UYW UZS VED VES VND VUV WST XAF XAG XAU XBA XBB XBC XBD XCD XDR XOF XPD XPF XPT XSU XTS XUA XXX YER ZAR ZMW ZWG ZWL '
  ) > 0;
$_$;


ALTER FUNCTION "public"."matrix_v2_is_iso_4217_currency"("p_currency" "text") OWNER TO "postgres";

--
-- Name: matrix_v2_is_supported_objective_config("text", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_is_supported_objective_config"("p_direction" "text", "p_parameters" "jsonb") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE STRICT
    SET "search_path" TO ''
    AS $_$
  select jsonb_typeof(p_parameters)='object'
    and p_parameters-array['target','targetValue']='{}'::jsonb
    and not (p_parameters ? 'target' and p_parameters ? 'targetValue')
    and (
      not (p_parameters ? 'target' or p_parameters ? 'targetValue')
      or (
        case upper(p_direction)
          when 'MIN' then 'MINIMIZE'
          when 'MAX' then 'MAXIMIZE'
          else upper(p_direction)
        end='MINIMIZE'
        and coalesce(p_parameters->>case
          when p_parameters ? 'targetValue' then 'targetValue'
          else 'target' end,'') ~ '^[0-9]+$'
      )
    );
$_$;


ALTER FUNCTION "public"."matrix_v2_is_supported_objective_config"("p_direction" "text", "p_parameters" "jsonb") OWNER TO "postgres";

--
-- Name: matrix_v2_is_supported_pay_condition("jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_is_supported_pay_condition"("p_condition" "jsonb") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE STRICT
    SET "search_path" TO ''
    AS $_$
  select case
    when jsonb_typeof(p_condition)<>'object'
      or p_condition-array['field','operator','value']<>'{}'::jsonb
      or not (p_condition ? 'field' and p_condition ? 'operator'
        and p_condition ? 'value')
      then false
    when lower(p_condition->>'field') in (
      'role_id','location_id','shift_template_id','scenario_id','employee_id'
    ) then case upper(p_condition->>'operator')
      when 'EQ' then jsonb_typeof(p_condition->'value')='string'
        and (p_condition->>'value')
          ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      when 'NE' then jsonb_typeof(p_condition->'value')='string'
        and (p_condition->>'value')
          ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      when 'IN' then jsonb_typeof(p_condition->'value')='array' and not exists(
        select 1 from jsonb_array_elements(p_condition->'value') item
        where jsonb_typeof(item.value)<>'string'
          or (item.value#>>'{}')
            !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      )
      when 'NOT_IN' then jsonb_typeof(p_condition->'value')='array' and not exists(
        select 1 from jsonb_array_elements(p_condition->'value') item
        where jsonb_typeof(item.value)<>'string'
          or (item.value#>>'{}')
            !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      )
      else false end
    when lower(p_condition->>'field')='duty_ids' then
      case upper(p_condition->>'operator')
        when 'CONTAINS' then jsonb_typeof(p_condition->'value')='string'
          and (p_condition->>'value')
            ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        when 'CONTAINS_ANY' then jsonb_typeof(p_condition->'value')='array'
          and not exists(
            select 1 from jsonb_array_elements(p_condition->'value') item
            where jsonb_typeof(item.value)<>'string'
              or (item.value#>>'{}')
                !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
          )
        when 'CONTAINS_ALL' then jsonb_typeof(p_condition->'value')='array'
          and not exists(
            select 1 from jsonb_array_elements(p_condition->'value') item
            where jsonb_typeof(item.value)<>'string'
              or (item.value#>>'{}')
                !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
          )
        else false end
    when lower(p_condition->>'field')='contract_code' then
      case upper(p_condition->>'operator')
        when 'EQ' then jsonb_typeof(p_condition->'value')='string'
          and length(p_condition->>'value')>0
        when 'NE' then jsonb_typeof(p_condition->'value')='string'
          and length(p_condition->>'value')>0
        when 'IN' then jsonb_typeof(p_condition->'value')='array'
          and not exists(
            select 1 from jsonb_array_elements(p_condition->'value') item
            where jsonb_typeof(item.value)<>'string'
              or length(item.value#>>'{}')=0
          )
        when 'NOT_IN' then jsonb_typeof(p_condition->'value')='array'
          and not exists(
            select 1 from jsonb_array_elements(p_condition->'value') item
            where jsonb_typeof(item.value)<>'string'
              or length(item.value#>>'{}')=0
          )
        else false end
    when lower(p_condition->>'field') in ('weekday','duration_minutes') then
      case upper(p_condition->>'operator')
        when 'EQ' then jsonb_typeof(p_condition->'value')='number'
          and (p_condition->'value'#>>'{}') ~ '^[0-9]+$'
          and (lower(p_condition->>'field')<>'weekday'
            or (p_condition->>'value')::integer between 1 and 7)
        when 'NE' then jsonb_typeof(p_condition->'value')='number'
          and (p_condition->'value'#>>'{}') ~ '^[0-9]+$'
          and (lower(p_condition->>'field')<>'weekday'
            or (p_condition->>'value')::integer between 1 and 7)
        when 'GTE' then jsonb_typeof(p_condition->'value')='number'
          and (p_condition->'value'#>>'{}') ~ '^[0-9]+$'
          and (lower(p_condition->>'field')<>'weekday'
            or (p_condition->>'value')::integer between 1 and 7)
        when 'LTE' then jsonb_typeof(p_condition->'value')='number'
          and (p_condition->'value'#>>'{}') ~ '^[0-9]+$'
          and (lower(p_condition->>'field')<>'weekday'
            or (p_condition->>'value')::integer between 1 and 7)
        when 'IN' then jsonb_typeof(p_condition->'value')='array'
          and not exists(
            select 1 from jsonb_array_elements(p_condition->'value') item
            where jsonb_typeof(item.value)<>'number'
              or (item.value#>>'{}') !~ '^[0-9]+$'
              or (lower(p_condition->>'field')='weekday'
                and (item.value#>>'{}')::integer not between 1 and 7)
          )
        when 'NOT_IN' then jsonb_typeof(p_condition->'value')='array'
          and not exists(
            select 1 from jsonb_array_elements(p_condition->'value') item
            where jsonb_typeof(item.value)<>'number'
              or (item.value#>>'{}') !~ '^[0-9]+$'
              or (lower(p_condition->>'field')='weekday'
                and (item.value#>>'{}')::integer not between 1 and 7)
          )
        else false end
    when lower(p_condition->>'field')='local_time' then
      upper(p_condition->>'operator')='OVERLAPS_TIME'
      and jsonb_typeof(p_condition->'value')='object'
      and (p_condition->'value')-array['start','end']<>'{}'::jsonb
      and coalesce(p_condition->'value'->>'start','')
        ~ '^([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?$'
      and coalesce(p_condition->'value'->>'end','')
        ~ '^([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?$'
    else false
  end;
$_$;


ALTER FUNCTION "public"."matrix_v2_is_supported_pay_condition"("p_condition" "jsonb") OWNER TO "postgres";

--
-- Name: matrix_v2_merge_equivalent_shifts_uat_v2(boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_merge_equivalent_shifts_uat_v2"("p_apply" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_matrix uuid; v_groups integer:=0; v_duplicates integer:=0;
  v_blockers jsonb:='[]'::jsonb; v_preview jsonb:='[]'::jsonb;
  group_row record; rule_row public.matrix_staffing_rules_v2%rowtype;
  v_existing public.matrix_staffing_rules_v2%rowtype;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  select version.id into v_matrix from public.matrix_versions version
  where version.status='DRAFT' and version.schema_version>=2
  order by version.version desc limit 1;
  if v_matrix is null then raise exception 'NO_MATRIX_V2_DRAFT'; end if;

  with groups as (
    select min(shift.id::text)::uuid survivor_id,
      array_agg(shift.id order by shift.sort_order,shift.id) ids,
      min(shift.name) name,shift.location_id,
      min(shift.starts_at) starts_at,min(shift.ends_at) ends_at,
      count(*) amount
    from public.matrix_shift_templates_v2 shift
    where shift.matrix_version_id=v_matrix and shift.active
    group by shift.location_id,lower(trim(shift.name)),shift.starts_at,
      shift.ends_at,shift.ends_next_day
    having count(*)>1
  )
  select count(*),coalesce(sum(amount-1),0),coalesce(jsonb_agg(jsonb_build_object(
    'name',name,'locationId',location_id,'startsAt',starts_at,'endsAt',ends_at,
    'entries',amount,'survivorId',survivor_id,'ids',to_jsonb(ids)
  ) order by name),'[]'::jsonb)
  into v_groups,v_duplicates,v_preview from groups;

  with groups as (
    select (array_agg(shift.id order by shift.sort_order,shift.id))[1] survivor_id,
      (array_agg(shift.id order by shift.sort_order,shift.id))[2:] duplicate_ids
    from public.matrix_shift_templates_v2 shift
    where shift.matrix_version_id=v_matrix and shift.active
    group by shift.location_id,lower(trim(shift.name)),shift.starts_at,
      shift.ends_at,shift.ends_next_day having count(*)>1
  ), conflicts as (
    select jsonb_build_object('code','STAFFING_RULE_CONFLICT','message',
      'Powielone zmiany mają różne reguły obsady dla tego samego zakresu.') blocker
    from groups
    join public.matrix_staffing_rules_v2 duplicate
      on duplicate.shift_template_id=any(groups.duplicate_ids)
    join public.matrix_staffing_rules_v2 survivor
      on survivor.shift_template_id=groups.survivor_id
      and survivor.scenario_id=duplicate.scenario_id
      and survivor.role_id=duplicate.role_id
      and survivor.duty_id is not distinct from duplicate.duty_id
    where row(survivor.operation,survivor.count_value,
      survivor.multiplier_basis_points,survivor.active)
      is distinct from row(duplicate.operation,duplicate.count_value,
        duplicate.multiplier_basis_points,duplicate.active)
    union all
    select jsonb_build_object('code','EVENT_DEMAND_REFERENCE','message',
      'Co najmniej jeden powielony wpis jest używany przez aktywny event.')
    from groups join public.workforce_event_demand_v2 demand
      on demand.shift_template_id=any(groups.duplicate_ids)
    join public.workforce_calendar_events_v2 event on event.id=demand.event_id
    where event.status='ACTIVE'
  )
  select coalesce(jsonb_agg(distinct blocker),'[]'::jsonb)
    into v_blockers from conflicts;

  if not p_apply then return jsonb_build_object(
    'matrixVersionId',v_matrix,'groups',v_groups,'duplicates',v_duplicates,
    'items',v_preview,'blockers',v_blockers,'applied',false
  ); end if;
  if jsonb_array_length(v_blockers)>0 then
    raise exception 'SHIFT_MERGE_BLOCKED:%',v_blockers::text;
  end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));

  for group_row in
    select (array_agg(shift.id order by shift.sort_order,shift.id))[1] survivor_id,
      (array_agg(shift.id order by shift.sort_order,shift.id))[2:] duplicate_ids,
      array_agg(distinct day_value order by day_value)::smallint[] merged_days
    from public.matrix_shift_templates_v2 shift
    cross join lateral unnest(shift.day_mask) day_value
    where shift.matrix_version_id=v_matrix and shift.active
    group by shift.location_id,lower(trim(shift.name)),shift.starts_at,
      shift.ends_at,shift.ends_next_day having count(distinct shift.id)>1
  loop
    update public.matrix_shift_templates_v2 set day_mask=group_row.merged_days,
      shift_period=case when extract(hour from starts_at)<12 then 'MORNING'
        when extract(hour from starts_at)<17 then 'MIDDLE' else 'EVENING' end,
      updated_at=now() where id=group_row.survivor_id;

    for rule_row in select * from public.matrix_staffing_rules_v2
      where shift_template_id=any(group_row.duplicate_ids)
    loop
      select * into v_existing from public.matrix_staffing_rules_v2 existing
      where existing.shift_template_id=group_row.survivor_id
        and existing.scenario_id=rule_row.scenario_id
        and existing.role_id=rule_row.role_id
        and existing.duty_id is not distinct from rule_row.duty_id limit 1;
      if v_existing.id is null then
        update public.matrix_staffing_rules_v2
          set shift_template_id=group_row.survivor_id,updated_at=now()
        where id=rule_row.id;
      else
        delete from public.matrix_staffing_rules_v2 where id=rule_row.id;
      end if;
      v_existing:=null;
    end loop;

    insert into public.matrix_pay_rule_shifts_v2(
      matrix_version_id,pay_rule_id,shift_template_id
    ) select distinct mapping.matrix_version_id,mapping.pay_rule_id,
      group_row.survivor_id
    from public.matrix_pay_rule_shifts_v2 mapping
    where mapping.shift_template_id=any(group_row.duplicate_ids)
    on conflict do nothing;
    delete from public.matrix_pay_rule_shifts_v2 mapping
      where mapping.shift_template_id=any(group_row.duplicate_ids);
    update public.matrix_shift_templates_v2 set active=false,updated_at=now()
      where id=any(group_row.duplicate_ids);
  end loop;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_v2_shifts',v_matrix::text,'MERGE_EQUIVALENT_SHIFTS',
    jsonb_build_object('groups',v_groups,'duplicates',v_duplicates,'items',v_preview));
  return jsonb_build_object(
    'matrixVersionId',v_matrix,'groups',v_groups,'duplicates',v_duplicates,
    'items',v_preview,'blockers','[]'::jsonb,'applied',true
  );
end;
$$;


ALTER FUNCTION "public"."matrix_v2_merge_equivalent_shifts_uat_v2"("p_apply" boolean) OWNER TO "postgres";

--
-- Name: matrix_v2_next_employee_no_v2(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_next_employee_no_v2"() RETURNS "text"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_number integer:=1;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE')) then raise exception 'FORBIDDEN'; end if;
  while exists(
    select 1 from public.employees employee
    where upper(employee.employee_no)=upper('GP-'||lpad(v_number::text,3,'0'))
  ) loop
    v_number:=v_number+1;
  end loop;
  return 'GP-'||lpad(v_number::text,3,'0');
end;
$$;


ALTER FUNCTION "public"."matrix_v2_next_employee_no_v2"() OWNER TO "postgres";

--
-- Name: matrix_v2_normalize_shift_periods_uat_v2(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_normalize_shift_periods_uat_v2"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_matrix uuid; v_updated integer:=0; v_recognized integer:=0;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  v_matrix:=public.matrix_v2_create_draft(null);
  select count(*) into v_recognized from public.matrix_shift_templates_v2 shift_row
  where shift_row.matrix_version_id=v_matrix and shift_row.active;
  update public.matrix_shift_templates_v2 shift_row set
    shift_period=case when extract(hour from shift_row.starts_at)<12 then 'MORNING'
      when extract(hour from shift_row.starts_at)<17 then 'MIDDLE' else 'EVENING' end,
    updated_at=now()
  where shift_row.matrix_version_id=v_matrix and shift_row.active
    and shift_row.shift_period is distinct from case
      when extract(hour from shift_row.starts_at)<12 then 'MORNING'
      when extract(hour from shift_row.starts_at)<17 then 'MIDDLE' else 'EVENING' end;
  get diagnostics v_updated=row_count;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_v2_shift_periods',v_matrix::text,'NORMALIZE_FROM_START_TIME',
    jsonb_build_object('recognized',v_recognized,'updated',v_updated,
      'morningBefore','12:00','middleBefore','17:00'));
  return jsonb_build_object('matrixVersionId',v_matrix,
    'recognized',v_recognized,'updated',v_updated);
end;
$$;


ALTER FUNCTION "public"."matrix_v2_normalize_shift_periods_uat_v2"() OWNER TO "postgres";

--
-- Name: matrix_v2_prevent_last_usable_delete_uat_v1(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."matrix_v2_prevent_last_usable_delete_uat_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  if old.status in ('DRAFT','ACTIVE') and not exists(
    select 1 from public.matrix_versions mv
    where mv.id<>old.id and mv.status in ('DRAFT','ACTIVE')
  ) then
    raise exception 'MATRIX_LAST_USABLE_VERSION_REQUIRED';
  end if;
  return old;
end;
$$;


ALTER FUNCTION "public"."matrix_v2_prevent_last_usable_delete_uat_v1"() OWNER TO "postgres";

