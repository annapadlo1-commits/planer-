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
-- Name: optimizer_prepare("date", "text", "text", integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_prepare"("p_month" "date", "p_profile_code" "text" DEFAULT 'BALANCED'::"text", "p_scenario_code" "text" DEFAULT 'BASE'::"text", "p_seed" integer DEFAULT NULL::integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare mv public.matrix_versions; profile public.optimizer_profiles; run_id uuid; payload jsonb;
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  p_month:=date_trunc('month',p_month)::date;
  select * into mv from public.matrix_versions
   where status='ACTIVE' and effective_from<=p_month and (effective_to is null or effective_to>=p_month)
   order by version desc limit 1;
  if mv.id is null then raise exception 'ACTIVE_MATRIX_NOT_FOUND'; end if;
  select * into profile from public.optimizer_profiles
   where matrix_version_id=mv.id and code=upper(p_profile_code) and active limit 1;
  if profile.id is null then raise exception 'OPTIMIZER_PROFILE_NOT_FOUND'; end if;
  insert into public.optimization_runs(month,matrix_version_id,profile_id,scenario_code,status,seed,requested_by,started_at)
  values(p_month,mv.id,profile.id,upper(p_scenario_code),'RUNNING',coalesce(p_seed,(extract(epoch from clock_timestamp())::bigint%2147483647)::integer),auth.uid(),now())
  returning id into run_id;

  select jsonb_build_object(
    'runId',run_id,'month',p_month,'scenario',upper(p_scenario_code),'seed',(select seed from public.optimization_runs where id=run_id),
    'matrix',jsonb_build_object('id',mv.id,'version',mv.version,'settings',mv.settings),
    'profile',jsonb_build_object('id',profile.id,'code',profile.code,'weights',profile.weights,
      'populationSize',profile.population_size,'generations',profile.generations,'eliteCount',profile.elite_count,
      'mutationRate',profile.mutation_rate,'alternativesCount',profile.alternatives_count),
    'employees',coalesce((select jsonb_agg(jsonb_build_object(
      'id',e.id,'employeeNo',e.employee_no,'role',e.primary_role,'nominal',e.monthly_nominal_minutes,
      'maxMonthly',coalesce(e.max_monthly_minutes,e.monthly_nominal_minutes),'maxWeekly',e.max_weekly_minutes,
      'maxConsecutiveDays',e.max_consecutive_days,'minimumRest',coalesce(e.minimum_rest_minutes,(mv.settings->>'minimumRestMinutes')::integer,660),
      'onlyMorning',e.only_morning,'onlyEvening',e.only_evening,'noWeekends',e.no_weekends,
      'rate',e.hourly_rate,'preferredShift',e.preferred_shift,'employmentStart',e.employment_start,'employmentEnd',e.employment_end,
      'locations',coalesce((select jsonb_agg(jsonb_build_object('id',el.location_id,'home',el.home_location)) from public.employee_locations el where el.employee_id=e.id and (el.standard_allowed or el.overtime_allowed)),'[]'::jsonb),
      'roles',coalesce((select jsonb_agg(mr.code) from public.matrix_employee_roles mer join public.matrix_roles mr on mr.id=mer.role_id where mer.matrix_version_id=mv.id and mer.employee_id=e.id),jsonb_build_array(e.primary_role::text)),
      'capabilities',coalesce((select jsonb_agg(jsonb_build_object('code',ec.capability,'role',ec.scope_role,'location',ec.scope_location)) from public.employee_capabilities ec where ec.employee_id=e.id and ec.active),'[]'::jsonb)
    ) order by e.employee_no) from public.employees e where e.active and e.archived_at is null),'[]'::jsonb),
    'availability',coalesce((select jsonb_agg(jsonb_build_object('employeeId',a.employee_id,'date',a.work_date,'available',a.available,'earliestStart',a.earliest_start,'latestEnd',a.latest_end,'status',case when a.available then 'AVAILABLE' else 'UNAVAILABLE' end)) from public.employee_availability a where a.work_date>=p_month and a.work_date<p_month+interval '1 month'),'[]'::jsonb),
    'preferences',coalesce((select jsonb_agg(jsonb_build_object('employeeId',p.employee_id,'from',p.valid_from,'to',p.valid_to,'type',p.preference_type,'value',p.preference_value)) from public.employee_preferences p where p.status='ACTIVE' and p.valid_from<p_month+interval '1 month' and p.valid_to>=p_month),'[]'::jsonb),
    'templates',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'locationId',l.id,'locationCode',ml.code,'timezone',l.timezone,'code',s.code,'start',s.starts_at,'end',s.ends_at,'days',s.day_mask)) from public.matrix_shift_templates s join public.matrix_locations ml on ml.id=s.location_id join public.locations l on l.code::text=ml.code where s.matrix_version_id=mv.id and s.active and ml.active and l.active),'[]'::jsonb),
    'demand',coalesce((select jsonb_agg(jsonb_build_object('templateId',d.shift_template_id,'roleId',d.role_id,'role',r.code,'functionId',d.function_id,'function',f.code,'count',d.required_count,'scenario',d.scenario_code)) from public.matrix_demand d join public.matrix_shift_templates s on s.id=d.shift_template_id join public.matrix_roles r on r.id=d.role_id left join public.matrix_functions f on f.id=d.function_id where s.matrix_version_id=mv.id and d.scenario_code in ('BASE',upper(p_scenario_code))),'[]'::jsonb)
  ) into payload;
  update public.optimization_runs set input_snapshot=jsonb_build_object(
    'employeeCount',jsonb_array_length(payload->'employees'),'availabilityCount',jsonb_array_length(payload->'availability'),
    'preferenceCount',jsonb_array_length(payload->'preferences'),'templateCount',jsonb_array_length(payload->'templates'),
    'demandCount',jsonb_array_length(payload->'demand'),'matrixVersion',mv.version) where id=run_id;
  return payload;
end $$;


ALTER FUNCTION "public"."optimizer_prepare"("p_month" "date", "p_profile_code" "text", "p_scenario_code" "text", "p_seed" integer) OWNER TO "postgres";

--
-- Name: optimizer_prepare_v2("date", "text", "text", integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_prepare_v2"("p_month" "date", "p_profile_code" "text" DEFAULT 'BALANCED'::"text", "p_scenario_code" "text" DEFAULT 'BASE'::"text", "p_seed" integer DEFAULT NULL::integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_payload jsonb;
  v_run uuid;
  v_baseline jsonb;
  v_baseline_plan uuid;
  v_baseline_missing integer;
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  v_payload := public.optimizer_prepare(p_month,p_profile_code,p_scenario_code,p_seed);
  v_run := (v_payload->>'runId')::uuid;

  v_payload := v_payload || jsonb_build_object(
    'availability',coalesce((select jsonb_agg(jsonb_build_object(
      'employeeId',a.employee_id,'date',a.work_date,'available',a.available,
      'earliestStart',a.earliest_start,'latestEnd',a.latest_end,
      'preferredShiftCode',a.preferred_shift_code,
      'status',case when a.available then 'AVAILABLE' else 'UNAVAILABLE' end
    )) from public.employee_availability a
      where a.work_date>=date_trunc('month',p_month)::date
        and a.work_date<date_trunc('month',p_month)::date+interval '1 month'),'[]'::jsonb),
    'hardBlocks',coalesce((select jsonb_agg(jsonb_build_object(
      'employeeId',ep.employee_id,'from',ep.valid_from,'to',ep.valid_to,
      'status',case ep.preference_type
        when 'LEAVE' then 'LEAVE'
        when 'SICKNESS' then 'SICKNESS'
        else 'UNAVAILABLE' end
    )) from public.employee_preferences ep
      where ep.status='ACTIVE'
        and ep.preference_type in ('UNAVAILABLE','LEAVE','SICKNESS')
        and ep.valid_from < date_trunc('month',p_month)::date + interval '1 month'
        and ep.valid_to >= date_trunc('month',p_month)::date),'[]'::jsonb),
    'budget',coalesce((select jsonb_build_object('amount',b.amount,'hardLimit',b.hard_limit)
      from public.monthly_budgets b where b.month=date_trunc('month',p_month)::date),
      '{"amount":0,"hardLimit":false}'::jsonb)
  );

  -- Historical issue rows from older engines are not directly comparable with
  -- the current full Matrix. They only choose a seed; the Edge engine rebuilds
  -- and revalidates that seed against every current requirement.
  select p2.id,
         coalesce((select sum(greatest(coalesce(pi.required_count,1)-coalesce(pi.assigned_count,0),0))
           from public.plan_issues pi where pi.plan_id=p2.id and pi.resolved_at is null
             and pi.issue_type in ('SHORTAGE','CAPABILITY_MISSING')),0)::integer
    into v_baseline_plan,v_baseline_missing
  from public.plans p2
  where p2.month=date_trunc('month',p_month)::date
    and p2.status in ('READY','PUBLISHED','STALE')
  order by case when p2.status='PUBLISHED' then 0 else 1 end,
    coalesce((select sum(greatest(coalesce(pi.required_count,1)-coalesce(pi.assigned_count,0),0))
      from public.plan_issues pi where pi.plan_id=p2.id and pi.resolved_at is null
        and pi.issue_type in ('SHORTAGE','CAPABILITY_MISSING')),0) asc,
    p2.score asc nulls last,p2.version desc
  limit 1;

  select coalesce(jsonb_agg(jsonb_build_object(
    'employeeId',a.employee_id,'date',s.shift_date,'shiftCode',s.shift_code,
    'locationId',s.location_id,'role',a.assigned_role,'function',a.assigned_capability,
    'startsAt',s.starts_at,'endsAt',s.ends_at
  ) order by s.starts_at,a.id),'[]'::jsonb) into v_baseline
  from public.shifts s
  join public.assignments a on a.shift_id=s.id
  where s.plan_id=v_baseline_plan;

  v_payload := v_payload || jsonb_build_object(
    'baselineAssignments',coalesce(v_baseline,'[]'::jsonb),
    'baselinePlanId',v_baseline_plan,
    'baselineDeclaredMissingSeats',v_baseline_missing
  );

  update public.optimization_runs set
    input_payload=v_payload,
    target_generations=greatest(24,least(100,
      coalesce((v_payload#>>'{profile,generations}')::integer,32))),
    heartbeat_at=now(),
    result_summary=jsonb_build_object(
      'phase','STARTING','progress',0,
      'baselinePlanId',v_baseline_plan,
      'baselineDeclaredMissingSeats',v_baseline_missing)
  where id=v_run and requested_by=auth.uid();
  return v_payload;
end $$;


ALTER FUNCTION "public"."optimizer_prepare_v2"("p_month" "date", "p_profile_code" "text", "p_scenario_code" "text", "p_seed" integer) OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_prepare_v2"("p_month" "date", "p_profile_code" "text", "p_scenario_code" "text", "p_seed" integer); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_prepare_v2"("p_month" "date", "p_profile_code" "text", "p_scenario_code" "text", "p_seed" integer) IS 'Retired Alpha 15 Edge-function entrypoint; not the OR-Tools optimizer_request_v2 API.';


--
-- Name: optimizer_publication_attempt_alpha16("uuid", "uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_publication_attempt_alpha16"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_readiness jsonb;
begin
  v_readiness:=public.optimizer_publication_readiness_alpha16(
    p_run_id,p_variant_id
  );
  insert into public.audit_log(
    actor_id,entity_type,entity_id,action,new_data
  ) values(
    auth.uid(),'optimization_run_v2',p_run_id::text,'PUBLICATION_ATTEMPT',
    jsonb_build_object(
      'variantId',p_variant_id,'name',trim(coalesce(p_name,'')),
      'ready',coalesce((v_readiness->>'ready')::boolean,false),
      'blockers',coalesce(v_readiness->'blockers','{}'::jsonb),
      'unfilledCount',coalesce((v_readiness->'warnings'->>'unfilledCount')::integer,0)
    )
  );
  return v_readiness;
end;
$$;


ALTER FUNCTION "public"."optimizer_publication_attempt_alpha16"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text") OWNER TO "postgres";

--
-- Name: optimizer_publication_change_preview_uat_v1("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_publication_change_preview_uat_v1"("p_variant_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid();
  v_run public.optimization_runs_v2%rowtype;
  v_old_variant_ids uuid[];
  v_baseline_type text;
  v_people jsonb:='[]'::jsonb;
  v_changed_count integer:=0;
  v_notification_count integer:=0;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select run.* into v_run
  from public.plan_variants_v2 variant
  join public.optimization_runs_v2 run on run.id=variant.run_id
  where variant.id=p_variant_id;
  if v_run.id is null or not solver_private.can_access_run_v2(v_run.id) then
    raise exception 'VARIANT_NOT_FOUND';
  end if;

  if v_run.scope_type='ROLE' and v_run.scope_role_id is not null then
    select array_agg(publication.variant_id order by publication.published_at,publication.id)
    into v_old_variant_ids
    from public.published_role_schedules_v2 publication
    where publication.month=v_run.month
      and publication.role_id=v_run.scope_role_id
      and publication.status='PUBLISHED';
    v_baseline_type:='ROLE';
  else
    select array_agg(publication.variant_id order by publication.role_id,publication.published_at)
    into v_old_variant_ids
    from public.published_role_schedules_v2 publication
    where publication.month=v_run.month and publication.status='PUBLISHED';
    if coalesce(cardinality(v_old_variant_ids),0)>0 then
      v_baseline_type:='ROLE_PUBLICATIONS';
    else
      select array_agg(link.variant_id order by link.ordinal)
      into v_old_variant_ids
      from public.published_schedules_v2 schedule
      join public.published_schedule_variants_v2 link on link.schedule_id=schedule.id
      where schedule.id=(
        select current_schedule.id
        from public.published_schedules_v2 current_schedule
        where current_schedule.month=v_run.month and current_schedule.status='PUBLISHED'
        order by current_schedule.published_at desc,current_schedule.id desc limit 1
      );
      v_baseline_type:='COMPANY';
    end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'employeeId',employee.id,
      'employeeNo',employee.employee_no,
      'name',trim(employee.first_name||' '||employee.last_name),
      'changeType',case when change.before_assignment_count=0 then 'ADDED'
        when change.after_assignment_count=0 then 'REMOVED' else 'CHANGED' end,
      'beforeAssignmentCount',change.before_assignment_count,
      'afterAssignmentCount',change.after_assignment_count,
      'willNotify',employee.auth_user_id is not null
    ) order by employee.last_name,employee.first_name,employee.employee_no),'[]'::jsonb),
    count(*)::integer,
    count(*) filter(where employee.auth_user_id is not null)::integer
  into v_people,v_changed_count,v_notification_count
  from solver_private.changed_variant_employees_uat_v1(
    coalesce(v_old_variant_ids,'{}'::uuid[]),array[p_variant_id]
  ) change
  join public.employees employee on employee.id=change.employee_id;

  return jsonb_build_object(
    'variantId',p_variant_id,
    'baselineType',v_baseline_type,
    'baselineFound',coalesce(cardinality(v_old_variant_ids),0)>0,
    'changedCount',v_changed_count,
    'notificationCount',v_notification_count,
    'people',v_people
  );
end;
$$;


ALTER FUNCTION "public"."optimizer_publication_change_preview_uat_v1"("p_variant_id" "uuid") OWNER TO "postgres";

--
-- Name: optimizer_publication_readiness_alpha16("uuid", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_publication_readiness_alpha16"("p_run_id" "uuid", "p_variant_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_run public.optimization_runs_v2%rowtype;
  v_variant public.plan_variants_v2%rowtype;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not solver_private.can_access_run_v2(p_run_id) then raise exception 'RUN_NOT_FOUND'; end if;
  select * into v_run from public.optimization_runs_v2 run where run.id=p_run_id;
  select * into v_variant from public.plan_variants_v2 variant
  where variant.id=p_variant_id and variant.run_id=p_run_id;
  return jsonb_build_object(
    'ready',v_run.status='READY' and v_run.scope_type='COMPANY'
      and v_run.request_engine='ORTOOLS_V2' and v_variant.id is not null
      and v_variant.selected and v_variant.hard_violations=0
      and v_variant.status in ('SELECTED','PUBLISHED'),
    'blockers',jsonb_strip_nulls(jsonb_build_object(
      'run',case when v_run.status<>'READY' then jsonb_build_object(
        'code','RUN_NOT_READY','message','Generowanie nie zostało zakończone.',
        'status',v_run.status,'phase',v_run.phase) end,
      'scope',case when v_run.scope_type<>'COMPANY' then jsonb_build_object(
        'code','COMPANY_VARIANT_REQUIRED',
        'message','Publikacja wymaga wariantu całej firmy albo scalenia wszystkich ról.') end,
      'engine',case when v_run.request_engine<>'ORTOOLS_V2' then jsonb_build_object(
        'code','SHADOW_RESULT','message','Wynik testowy nie może zostać opublikowany.') end,
      'selection',case when v_variant.id is null or not coalesce(v_variant.selected,false)
        then jsonb_build_object('code','VARIANT_NOT_SELECTED',
          'message','Najpierw wybierz wariant do publikacji.') end,
      'hardRules',case when coalesce(v_variant.hard_violations,0)>0
        then jsonb_build_object('code','HARD_RULES_BROKEN',
          'message','Wariant narusza twarde reguły.',
          'count',v_variant.hard_violations) end
    )),
    'warnings',jsonb_build_object(
      'unfilledCount',coalesce(v_variant.unfilled_count,0),
      'message',case when coalesce(v_variant.unfilled_count,0)>0
        then 'Wariant zawiera braki obsady. Przejrzyj alerty przed publikacją.' end
    ),
    'issues',coalesce((select jsonb_agg(jsonb_build_object(
      'id',issue.id,'code',issue.issue_code,'severity',issue.severity,
      'message',issue.message,'date',shift_row.shift_date,
      'startsAt',shift_row.starts_at,'endsAt',shift_row.ends_at,
      'locationId',shift_row.location_id,'locationName',location.name,
      'shiftTemplateId',shift_row.shift_template_id,
      'shiftTemplateName',template.name,'roleId',issue.role_id,
      'roleName',role.name,'dutyId',issue.duty_id,'dutyName',duty.name,
      'requiredCount',issue.required_count,'assignedCount',issue.assigned_count,
      'slotKey',issue.slot_key
    ) order by shift_row.starts_at,issue.id)
      from public.plan_issues_v2 issue
      left join public.plan_shifts_v2 shift_row on shift_row.id=issue.shift_id
      left join public.matrix_locations_v2 location on location.id=shift_row.location_id
      left join public.matrix_shift_templates_v2 template
        on template.id=shift_row.shift_template_id
      left join public.matrix_roles_v2 role on role.id=issue.role_id
      left join public.matrix_duties_v2 duty on duty.id=issue.duty_id
      where issue.variant_id=p_variant_id),'[]'::jsonb)
  );
end;
$$;


ALTER FUNCTION "public"."optimizer_publication_readiness_alpha16"("p_run_id" "uuid", "p_variant_id" "uuid") OWNER TO "postgres";

--
-- Name: optimizer_publish_company_variant_alpha16("uuid", "uuid", "text", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_publish_company_variant_alpha16"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_warning_reason" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_readiness jsonb;
  v_unfilled integer;
  v_result jsonb;
begin
  v_readiness:=public.optimizer_publication_readiness_alpha16(
    p_run_id,p_variant_id
  );
  v_unfilled:=coalesce(
    (v_readiness->'warnings'->>'unfilledCount')::integer,0
  );
  if not coalesce((v_readiness->>'ready')::boolean,false) then
    insert into public.audit_log(
      actor_id,entity_type,entity_id,action,new_data
    ) values(
      auth.uid(),'optimization_run_v2',p_run_id::text,'PUBLICATION_BLOCKED',
      jsonb_build_object(
        'variantId',p_variant_id,'name',trim(coalesce(p_name,'')),
        'blockers',coalesce(v_readiness->'blockers','{}'::jsonb)
      )
    );
    return jsonb_build_object(
      'published',false,'code','PLAN_NOT_READY',
      'message','Grafik nie spełnia warunków publikacji.',
      'readiness',v_readiness
    );
  end if;
  if v_unfilled>0 and length(trim(coalesce(p_warning_reason,'')))<3 then
    insert into public.audit_log(
      actor_id,entity_type,entity_id,action,new_data
    ) values(
      auth.uid(),'optimization_run_v2',p_run_id::text,
      'PUBLICATION_WARNING_REASON_REQUIRED',jsonb_build_object(
        'variantId',p_variant_id,'name',trim(coalesce(p_name,'')),
        'unfilledCount',v_unfilled
      )
    );
    return jsonb_build_object(
      'published',false,'code','WARNING_REASON_REQUIRED',
      'message','Publikacja z brakami obsady wymaga podania powodu.',
      'readiness',v_readiness
    );
  end if;
  begin
    v_result:=public.optimizer_publish_company_variant_v2(
      p_run_id,p_variant_id,p_name,p_idempotency_key
    );
  exception when others then
    insert into public.audit_log(
      actor_id,entity_type,entity_id,action,new_data
    ) values(
      auth.uid(),'optimization_run_v2',p_run_id::text,'PUBLICATION_FAILED',
      jsonb_build_object(
        'variantId',p_variant_id,'name',trim(coalesce(p_name,'')),
        'error',sqlerrm
      )
    );
    return jsonb_build_object(
      'published',false,'code','PUBLICATION_FAILED',
      'message',sqlerrm,'readiness',v_readiness
    );
  end;
  insert into public.audit_log(
    actor_id,entity_type,entity_id,action,new_data
  ) values(
    auth.uid(),'optimization_run_v2',p_run_id::text,'PUBLICATION_COMPLETED',
    jsonb_build_object(
      'variantId',p_variant_id,
      'scheduleId',v_result->>'scheduleId',
      'unfilledCount',v_unfilled,
      'warningReason',case when v_unfilled>0
        then trim(p_warning_reason) else null end
    )
  );
  return v_result||jsonb_build_object(
    'published',true,
    'warningReason',case when v_unfilled>0 then trim(p_warning_reason) else null end
  );
end;
$$;


ALTER FUNCTION "public"."optimizer_publish_company_variant_alpha16"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_warning_reason" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_publish_company_variant_alpha16"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_warning_reason" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_publish_company_variant_alpha16"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_warning_reason" "text") IS 'Audited publication boundary; requires an explicit reason when soft staffing warnings remain.';


--
-- Name: optimizer_publish_company_variant_resolved_uat_v2("uuid", "uuid", "text", "text", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_publish_company_variant_resolved_uat_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_warning_reason" "text" DEFAULT NULL::"text", "p_role_replacement_reason" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid();
  v_run public.optimization_runs_v2%rowtype;
  v_previous_variant_ids uuid[];
  v_archived_role_schedules integer:=0;
  v_changed integer:=0;
  v_notified integer:=0;
  v_result jsonb;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'COMPANY_PUBLICATION_OWNER_REQUIRED';
  end if;

  select run.* into v_run
  from public.optimization_runs_v2 run
  where run.id=p_run_id
  for update;
  if v_run.id is null or not solver_private.can_access_run_v2(p_run_id) then
    raise exception 'RUN_NOT_FOUND';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'publish-v2-month:'||v_run.month::text,0
  ));

  select array_agg(publication.variant_id order by publication.role_id,publication.published_at)
  into v_previous_variant_ids
  from public.published_role_schedules_v2 publication
  where publication.month=v_run.month and publication.status='PUBLISHED';
  if coalesce(cardinality(v_previous_variant_ids),0)=0 then
    select array_agg(link.variant_id order by link.ordinal)
    into v_previous_variant_ids
    from public.published_schedules_v2 schedule
    join public.published_schedule_variants_v2 link on link.schedule_id=schedule.id
    where schedule.id=(
      select current_schedule.id
      from public.published_schedules_v2 current_schedule
      where current_schedule.month=v_run.month and current_schedule.status='PUBLISHED'
      order by current_schedule.published_at desc,current_schedule.id desc limit 1
    );
  end if;

  if exists(
    select 1 from public.published_role_schedules_v2 publication
    where publication.month=v_run.month and publication.status='PUBLISHED'
  ) then
    if length(trim(coalesce(p_role_replacement_reason,'')))<5 then
      raise exception 'ROLE_PUBLICATION_REPLACEMENT_REASON_REQUIRED';
    end if;
    update public.published_role_schedules_v2 publication set
      status='ARCHIVED',archived_at=now(),archived_by=v_actor
    where publication.month=v_run.month and publication.status='PUBLISHED';
    get diagnostics v_archived_role_schedules=row_count;
  end if;

  v_result:=public.optimizer_publish_company_variant_alpha16(
    p_run_id,p_variant_id,p_name,p_idempotency_key,p_warning_reason
  );
  if not coalesce((v_result->>'published')::boolean,false) then
    raise exception 'ATOMIC_COMPANY_PUBLICATION_FAILED: %',
      coalesce(v_result->>'message',v_result->>'code','UNKNOWN');
  end if;

  if not coalesce((v_result->>'reused')::boolean,false) then
    select count(*)::integer into v_changed
    from solver_private.changed_variant_employees_uat_v1(
      coalesce(v_previous_variant_ids,'{}'::uuid[]),array[p_variant_id]
    );
    insert into public.notifications(recipient_id,channel,title,body)
    select employee.auth_user_id,'IN_APP','Zmieniono Twój grafik',
      trim(p_name)||' zawiera zmianę Twoich przydziałów. Sprawdź aktualny grafik w Portalu pracownika.'
    from solver_private.changed_variant_employees_uat_v1(
      coalesce(v_previous_variant_ids,'{}'::uuid[]),array[p_variant_id]
    ) change
    join public.employees employee on employee.id=change.employee_id
    where employee.auth_user_id is not null;
    get diagnostics v_notified=row_count;
  end if;

  if v_archived_role_schedules>0 then
    insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
    values(v_actor,'schedule_publication_authority_v2',v_run.month::text,
      'REPLACE_ROLES_WITH_COMPANY',jsonb_build_object(
        'reason',trim(p_role_replacement_reason),
        'archivedRoleSchedules',v_archived_role_schedules,
        'scheduleId',v_result->>'scheduleId',
        'runId',p_run_id,'variantId',p_variant_id
      ));
  end if;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'published_schedule_v2',v_result->>'scheduleId','NOTIFY_CHANGED_EMPLOYEES',
    jsonb_build_object('previousVariantIds',coalesce(to_jsonb(v_previous_variant_ids),'[]'::jsonb),
      'variantId',p_variant_id,'changed',v_changed,'notified',v_notified));

  return v_result||jsonb_build_object(
    'archivedRoleSchedules',v_archived_role_schedules,
    'publicationAuthority','COMPANY',
    'changed',v_changed,
    'notified',v_notified
  );
end;
$$;


ALTER FUNCTION "public"."optimizer_publish_company_variant_resolved_uat_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_warning_reason" "text", "p_role_replacement_reason" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_publish_company_variant_resolved_uat_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_warning_reason" "text", "p_role_replacement_reason" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_publish_company_variant_resolved_uat_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_warning_reason" "text", "p_role_replacement_reason" "text") IS 'Atomically archives active role publications and publishes a company variant after an explicit audited owner decision.';


--
-- Name: optimizer_publish_company_variant_v2("uuid", "uuid", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_publish_company_variant_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_engine text;
  v_enabled boolean;
  v_active_solver_version text;
  v_request_engine text;
  v_run_solver_version text;
begin
  perform solver_private.lock_planning_revision_v2();
  select flag.engine,flag.enabled into v_engine,v_enabled
  from public.solver_feature_flags flag
  where flag.flag_key='DEFAULT_ENGINE';
  if v_enabled is distinct from true
    or v_engine is distinct from 'ORTOOLS_V2' then
    raise exception 'ORTOOLS_PUBLICATION_DISABLED';
  end if;
  v_active_solver_version :=
    solver_private.active_ortools_solver_version_v2();

  select run.request_engine,run.solver_version
  into v_request_engine,v_run_solver_version
  from public.optimization_runs_v2 run
  where run.id=p_run_id;
  if v_request_engine is not null
    and v_request_engine is distinct from 'ORTOOLS_V2' then
    raise exception 'SHADOW_RUN_NOT_PUBLISHABLE';
  end if;
  if v_request_engine is not null
    and v_run_solver_version is distinct from v_active_solver_version then
    raise exception 'RUN_SOLVER_VERSION_NOT_ACTIVE';
  end if;

  return
    solver_private.optimizer_publish_company_variant_pre_version_fence_v2(
      p_run_id,p_variant_id,p_name,p_idempotency_key
    );
end;
$$;


ALTER FUNCTION "public"."optimizer_publish_company_variant_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_publish_company_variant_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_publish_company_variant_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text") IS 'Internal Alpha 16 publication implementation. Clients must use the audited optimizer_publish_company_variant_alpha16 boundary.';


--
-- Name: optimizer_publish_role_composite_before_phase1_uat_v1("date", "uuid", "uuid"[], "text", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_publish_role_composite_before_phase1_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[], "p_name" "text", "p_idempotency_key" "text", "p_warning_reason" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid := auth.uid();
  v_month date := date_trunc('month', p_month)::date;
  v_preflight jsonb;
  v_gap_count integer;
  v_critical_count integer;
  v_result jsonb;
  v_schedule_id uuid;
  v_published_count integer;
  v_source_run_id uuid;
  v_temporarily_selected uuid[] := '{}'::uuid[];
  v_temporarily_deselected uuid[] := '{}'::uuid[];
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  if p_variant_ids is null or cardinality(p_variant_ids) = 0 then
    raise exception 'PUBLISHED_ROLE_VARIANTS_REQUIRED';
  end if;
  if cardinality(p_variant_ids) <> (
    select count(distinct variant_id)
    from unnest(p_variant_ids) as variant_id
  ) then
    raise exception 'DUPLICATE_ROLE_VARIANTS';
  end if;

  v_preflight := public.optimizer_role_composite_preflight_uat_v2(
    v_month, p_scenario_id, p_variant_ids
  );
  v_gap_count := coalesce((v_preflight->>'totalGaps')::integer, 0);
  v_critical_count := coalesce((v_preflight->>'criticalGaps')::integer, 0);
  if v_gap_count > 0 and length(trim(coalesce(p_warning_reason, ''))) < 10 then
    raise exception 'WARNING_REASON_REQUIRED';
  end if;

  select count(*)
  into v_published_count
  from public.published_role_schedules_v2 role_schedule
  where role_schedule.month = v_month
    and role_schedule.scenario_id = p_scenario_id
    and role_schedule.status = 'PUBLISHED'
    and role_schedule.variant_id = any(p_variant_ids);
  if v_published_count <> cardinality(p_variant_ids) then
    raise exception 'PUBLISHED_ROLE_VARIANTS_REQUIRED';
  end if;

  for v_source_run_id in
    select distinct variant.run_id
    from public.plan_variants_v2 variant
    where variant.id = any(p_variant_ids)
    order by variant.run_id
  loop
    perform pg_advisory_xact_lock(hashtextextended(
      'select-v2:' || v_source_run_id::text, 0
    ));
  end loop;

  select coalesce(array_agg(variant.id order by variant.id), '{}'::uuid[])
  into v_temporarily_deselected
  from public.plan_variants_v2 variant
  where variant.selected
    and variant.id <> all(p_variant_ids)
    and variant.run_id in (
      select source_variant.run_id
      from public.plan_variants_v2 source_variant
      where source_variant.id = any(p_variant_ids)
    );

  select coalesce(array_agg(variant.id order by variant.id), '{}'::uuid[])
  into v_temporarily_selected
  from public.plan_variants_v2 variant
  where variant.id = any(p_variant_ids)
    and not variant.selected;

  update public.plan_variants_v2 variant
  set selected = false
  where variant.id = any(v_temporarily_deselected);

  update public.plan_variants_v2 variant
  set selected = true
  where variant.id = any(p_variant_ids);

  v_result := public.optimizer_publish_role_composite_v2(
    v_month, p_scenario_id, p_variant_ids, p_name, p_idempotency_key
  );

  update public.plan_variants_v2 variant
  set selected = false
  where variant.id = any(v_temporarily_selected);

  update public.plan_variants_v2 variant
  set selected = true
  where variant.id = any(v_temporarily_deselected);

  v_schedule_id := coalesce(
    nullif(v_result->>'scheduleId', '')::uuid,
    nullif(v_result->>'schedule_id', '')::uuid
  );
  if v_schedule_id is null then raise exception 'SCHEDULE_ID_MISSING'; end if;

  update public.published_schedules_v2 schedule
  set validation_summary = coalesce(schedule.validation_summary, '{}'::jsonb)
    || jsonb_build_object(
      'gapAcceptance', jsonb_build_object(
        'accepted', v_gap_count > 0,
        'totalGaps', v_gap_count,
        'criticalGaps', v_critical_count,
        'reason', nullif(trim(coalesce(p_warning_reason, '')), ''),
        'acceptedBy', v_actor,
        'acceptedAt', now()
      ),
      'publishedSourceContinuity', jsonb_build_object(
        'scenarioId', p_scenario_id,
        'variantIds', to_jsonb(p_variant_ids),
        'leaderSelectionRestored', true
      )
    )
  where schedule.id = v_schedule_id;

  if v_gap_count > 0 then
    insert into public.audit_log(actor_id, entity_type, entity_id, action, new_data)
    values(v_actor, 'published_schedule_v2', v_schedule_id::text,
      'PUBLISH_WITH_GAPS_ACCEPTED', jsonb_build_object(
        'month', v_month,
        'scenarioId', p_scenario_id,
        'totalGaps', v_gap_count,
        'criticalGaps', v_critical_count,
        'reason', trim(p_warning_reason),
        'variantIds', to_jsonb(p_variant_ids)
      ));
  end if;

  return v_result || jsonb_build_object(
    'gapAcceptanceRequired', v_gap_count > 0,
    'totalGaps', v_gap_count,
    'criticalGaps', v_critical_count,
    'publishedSourceContinuity', true
  );
end;
$$;


ALTER FUNCTION "public"."optimizer_publish_role_composite_before_phase1_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[], "p_name" "text", "p_idempotency_key" "text", "p_warning_reason" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_publish_role_composite_before_phase1_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[], "p_name" "text", "p_idempotency_key" "text", "p_warning_reason" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_publish_role_composite_before_phase1_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[], "p_name" "text", "p_idempotency_key" "text", "p_warning_reason" "text") IS 'Publishes exactly the role variants currently exposed by published role schedules, temporarily restoring their selection only inside the transaction and restoring any newer leader selection afterwards.';


--
-- Name: optimizer_publish_role_composite_uat_v3("date", "uuid", "uuid"[], "text", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_publish_role_composite_uat_v3"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[], "p_name" "text", "p_idempotency_key" "text", "p_warning_reason" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_month date:=date_trunc('month',p_month)::date;
begin
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    if p_variant_ids is null or cardinality(p_variant_ids)=0 or exists(
      select 1
      from unnest(p_variant_ids) input(variant_id)
      left join public.published_role_schedules_v2 schedule
        on schedule.variant_id=input.variant_id
        and schedule.month=v_month
        and schedule.scenario_id=p_scenario_id
        and schedule.status='PUBLISHED'
      where schedule.id is null
        or schedule.role_id is null
        or not public.matrix_v2_scope_allows_resource_for_app_role_uat_v1(
          'ROLE_MANAGER',schedule.role_id,null,null
        )
    ) then raise exception 'RESOURCE_SCOPE_FORBIDDEN'; end if;
  end if;
  perform authorization_private.enter_resource_scope_uat_v1();
  return public.optimizer_publish_role_composite_before_phase1_uat_v1(
    p_month,p_scenario_id,p_variant_ids,p_name,p_idempotency_key,p_warning_reason
  );
end;
$$;


ALTER FUNCTION "public"."optimizer_publish_role_composite_uat_v3"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[], "p_name" "text", "p_idempotency_key" "text", "p_warning_reason" "text") OWNER TO "postgres";

--
-- Name: optimizer_publish_role_composite_v2("date", "uuid", "uuid"[], "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_publish_role_composite_v2"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[], "p_name" "text", "p_idempotency_key" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_engine text;
  v_enabled boolean;
  v_active_solver_version text;
begin
  perform solver_private.lock_planning_revision_v2();
  select flag.engine,flag.enabled into v_engine,v_enabled
  from public.solver_feature_flags flag
  where flag.flag_key='DEFAULT_ENGINE';
  if v_enabled is distinct from true
    or v_engine is distinct from 'ORTOOLS_V2' then
    raise exception 'ORTOOLS_PUBLICATION_DISABLED';
  end if;
  v_active_solver_version :=
    solver_private.active_ortools_solver_version_v2();

  if exists(
    select 1
    from public.plan_variants_v2 variant
    join public.optimization_runs_v2 run on run.id=variant.run_id
    where variant.id=any(p_variant_ids)
      and run.request_engine is distinct from 'ORTOOLS_V2'
  ) then raise exception 'SHADOW_RUN_NOT_PUBLISHABLE'; end if;
  if exists(
    select 1
    from public.plan_variants_v2 variant
    join public.optimization_runs_v2 run on run.id=variant.run_id
    where variant.id=any(p_variant_ids)
      and run.request_engine='ORTOOLS_V2'
      and run.solver_version is distinct from v_active_solver_version
  ) then raise exception 'RUN_SOLVER_VERSION_NOT_ACTIVE'; end if;

  return
    solver_private.optimizer_publish_role_composite_pre_version_fence_v2(
      p_month,p_scenario_id,p_variant_ids,p_name,p_idempotency_key
    );
end;
$$;


ALTER FUNCTION "public"."optimizer_publish_role_composite_v2"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[], "p_name" "text", "p_idempotency_key" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_publish_role_composite_v2"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[], "p_name" "text", "p_idempotency_key" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_publish_role_composite_v2"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[], "p_name" "text", "p_idempotency_key" "text") IS 'Publishes ROLE variants only when every run matches active solverVersion.';


--
-- Name: optimizer_publish_role_variant_before_b4f121_uat_v2("uuid", "uuid", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_publish_role_variant_before_b4f121_uat_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid();
  v_run public.optimization_runs_v2%rowtype;
  v_variant public.plan_variants_v2%rowtype;
  v_role_logical_id uuid;
  v_existing public.published_role_schedules_v2%rowtype;
  v_previous_variant_id uuid;
  v_id uuid:=gen_random_uuid();
  v_validation jsonb;
  v_month date;
  v_changed integer:=0;
  v_notified integer:=0;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if length(coalesce(p_idempotency_key,'')) not between 8 and 200 then
    raise exception 'INVALID_IDEMPOTENCY_KEY';
  end if;
  if length(trim(coalesce(p_name,''))) not between 1 and 200 then
    raise exception 'INVALID_PLAN_NAME';
  end if;
  select run.month into v_month
  from public.optimization_runs_v2 run where run.id=p_run_id;
  if v_month is null then raise exception 'VARIANT_NOT_FOUND'; end if;

  perform solver_private.lock_planning_revision_v2();
  perform pg_advisory_xact_lock(hashtextextended(
    'publish-v2-month:'||v_month::text,0
  ));
  perform pg_advisory_xact_lock(hashtextextended(
    'select-v2:'||p_run_id::text,0
  ));

  select * into v_run from public.optimization_runs_v2 run
  where run.id=p_run_id for update;
  select * into v_variant from public.plan_variants_v2 variant
  where variant.id=p_variant_id and variant.run_id=p_run_id for update;
  if v_run.id is null or v_variant.id is null then raise exception 'VARIANT_NOT_FOUND'; end if;
  if v_run.month<>v_month then raise exception 'RUN_MONTH_CHANGED'; end if;
  if v_run.scope_type<>'ROLE' or v_run.scope_role_id is null then
    raise exception 'ROLE_VARIANT_REQUIRED';
  end if;
  if v_run.request_engine<>'ORTOOLS_V2' then raise exception 'SHADOW_RUN_NOT_PUBLISHABLE'; end if;
  if v_run.status<>'READY' or not v_variant.selected
    or v_variant.hard_violations<>0
    or v_variant.status not in ('SELECTED','PUBLISHED') then
    raise exception 'SELECTED_VALID_ROLE_VARIANT_REQUIRED';
  end if;
  select role.logical_id into v_role_logical_id
  from public.matrix_roles_v2 role where role.id=v_run.scope_role_id;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN'))
    and not exists(select 1 from public.matrix_scope_grants_v2 grant_row
      where grant_row.auth_user_id=v_actor and grant_row.active
        and grant_row.app_role='ROLE_MANAGER'
        and (grant_row.role_logical_id is null
          or grant_row.role_logical_id=v_role_logical_id)) then
    raise exception 'ROLE_PUBLICATION_FORBIDDEN';
  end if;
  select * into v_existing from public.published_role_schedules_v2 publication
  where publication.created_by=v_actor
    and publication.idempotency_key=p_idempotency_key;
  if v_existing.id is not null then
    if v_existing.variant_id<>p_variant_id or v_existing.name<>trim(p_name) then
      raise exception 'IDEMPOTENCY_KEY_REUSED';
    end if;
    return jsonb_build_object('roleScheduleId',v_existing.id,
      'status',v_existing.status,'reused',true,'changed',0,'notified',0);
  end if;

  select publication.variant_id into v_previous_variant_id
  from public.published_role_schedules_v2 publication
  where publication.month=v_run.month
    and publication.role_id=v_run.scope_role_id
    and publication.status='PUBLISHED'
  order by publication.published_at desc,publication.id desc limit 1;

  v_validation:=solver_private.revalidate_materialized_variant_v2(
    p_variant_id,false
  );
  update public.published_role_schedules_v2 publication set
    status='ARCHIVED',archived_at=now(),archived_by=v_actor
  where publication.month=v_run.month
    and publication.role_id=v_run.scope_role_id
    and publication.status='PUBLISHED';
  insert into public.published_role_schedules_v2(
    id,idempotency_key,month,matrix_version_id,scenario_id,role_id,
    variant_id,name,publication_hash,created_by
  ) values(
    v_id,p_idempotency_key,v_run.month,v_run.matrix_version_id,v_run.scenario_id,
    v_run.scope_role_id,p_variant_id,trim(p_name),v_variant.solution_hash,v_actor
  );

  select count(*)::integer into v_changed
  from solver_private.changed_variant_employees_uat_v1(
    case when v_previous_variant_id is null then '{}'::uuid[] else array[v_previous_variant_id] end,
    array[p_variant_id]
  );
  insert into public.notifications(recipient_id,channel,title,body)
  select employee.auth_user_id,'IN_APP','Zmieniono Twój grafik zespołu',
    trim(p_name)||' zawiera zmianę Twoich przydziałów. Sprawdź aktualny grafik w Portalu pracownika.'
  from solver_private.changed_variant_employees_uat_v1(
    case when v_previous_variant_id is null then '{}'::uuid[] else array[v_previous_variant_id] end,
    array[p_variant_id]
  ) change
  join public.employees employee on employee.id=change.employee_id
  where employee.auth_user_id is not null;
  get diagnostics v_notified=row_count;

  update public.plan_variants_v2
  set status='PUBLISHED',published_at=now()
  where id=p_variant_id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'published_role_schedule_v2',v_id::text,'PUBLISH',
    jsonb_build_object('runId',p_run_id,'variantId',p_variant_id,
      'previousVariantId',v_previous_variant_id,
      'roleId',v_run.scope_role_id,'changed',v_changed,'notified',v_notified,
      'validation',v_validation));
  return jsonb_build_object('roleScheduleId',v_id,'status','PUBLISHED',
    'reused',false,'changed',v_changed,'notified',v_notified);
end;
$$;


ALTER FUNCTION "public"."optimizer_publish_role_variant_before_b4f121_uat_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_publish_role_variant_before_b4f121_uat_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_publish_role_variant_before_b4f121_uat_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text") IS 'B4F-121: private pre-atomic role publication implementation; callable only by the secured wrapper.';


--
-- Name: optimizer_publish_role_variant_uat_v2("uuid", "uuid", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_publish_role_variant_uat_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid();
  v_variant public.plan_variants_v2%rowtype;
  v_result jsonb;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;

  perform solver_private.lock_planning_revision_v2();
  perform pg_advisory_xact_lock(hashtextextended(
    'select-v2:'||p_run_id::text,0
  ));

  select variant.* into v_variant
  from public.plan_variants_v2 variant
  join public.optimization_runs_v2 run on run.id=variant.run_id
  where variant.id=p_variant_id and variant.run_id=p_run_id
    and run.status='READY' and run.scope_type='ROLE'
    and run.request_engine='ORTOOLS_V2'
  for update of variant;
  if v_variant.id is null then raise exception 'VARIANT_NOT_FOUND'; end if;

  if v_variant.variant_kind='LEADER_COPY' then
    if v_variant.hard_violations<>0
      or v_variant.leader_workflow_status not in ('READY_TO_MERGE','PUBLISHED') then
      raise exception 'LEADER_VARIANT_NOT_READY_TO_PUBLISH';
    end if;

    if v_variant.status<>'PUBLISHED' then
      update public.plan_variants_v2 variant set
        selected=false,
        status=case when variant.status='SELECTED' then 'READY' else variant.status end,
        selected_at=null,
        selected_by=null
      where variant.run_id=p_run_id and variant.selected and variant.id<>p_variant_id;

      update public.plan_variants_v2 variant set
        selected=true,
        status='SELECTED',
        selected_at=now(),
        selected_by=v_actor
      where variant.id=p_variant_id;

      insert into public.audit_log(
        actor_id,entity_type,entity_id,action,new_data
      ) values(
        v_actor,'optimization_run_v2',p_run_id::text,
        'SELECT_VARIANT_FOR_ATOMIC_ROLE_PUBLICATION',
        jsonb_build_object('variantId',p_variant_id)
      );
    end if;
  end if;

  v_result:=public.optimizer_publish_role_variant_before_b4f121_uat_v2(
    p_run_id,p_variant_id,p_name,p_idempotency_key
  );

  if v_variant.variant_kind='LEADER_COPY' then
    update public.plan_variants_v2 variant
    set leader_workflow_status='PUBLISHED'
    where variant.id=p_variant_id and variant.status='PUBLISHED';
  end if;
  return v_result;
end;
$$;


ALTER FUNCTION "public"."optimizer_publish_role_variant_uat_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_publish_role_variant_uat_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_publish_role_variant_uat_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text") IS 'B4F-121: atomically selects a READY_TO_MERGE leader copy and publishes that exact variant in one RPC.';


--
-- Name: optimizer_published_schedule_alpha16("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_published_schedule_alpha16"("p_schedule_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "public"."optimizer_published_schedule_alpha16"("p_schedule_id" "uuid") OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_published_schedule_alpha16"("p_schedule_id" "uuid"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_published_schedule_alpha16"("p_schedule_id" "uuid") IS 'Published OR-Tools schedule with exact issue context and an explicit engine marker required by the operational UI contract.';


--
-- Name: optimizer_published_schedule_v2("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_published_schedule_v2"("p_schedule_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_schedule public.published_schedules_v2%rowtype; v_variant_ids uuid[]; v_context jsonb;
  v_visibility text; v_workspace jsonb; v_finance jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE')
    or public.has_app_role('VERIFIER')) then raise exception 'FORBIDDEN'; end if;
  select * into v_schedule from public.published_schedules_v2 s where s.id=p_schedule_id;
  if v_schedule.id is null then raise exception 'PUBLISHED_SCHEDULE_NOT_FOUND'; end if;
  select array_agg(sv.variant_id order by sv.ordinal) into v_variant_ids
  from public.published_schedule_variants_v2 sv where sv.schedule_id=v_schedule.id;
  if coalesce(cardinality(v_variant_ids),0)=0 then raise exception 'PUBLISHED_SCHEDULE_EMPTY'; end if;
  select jsonb_build_object('type','PUBLISHED_SCHEDULE','scheduleId',v_schedule.id,
    'sourceType',v_schedule.source_type,'name',v_schedule.name,'status',v_schedule.status,
    'month',v_schedule.month,'scenario',jsonb_build_object('id',s.id,'name',s.name),
    'matrixVersionId',v_schedule.matrix_version_id,'publishedAt',v_schedule.published_at,
    'archivedAt',v_schedule.archived_at)
  into v_context from public.matrix_scenarios_v2 s where s.id=v_schedule.scenario_id;
  v_visibility:=public.application_finance_visibility_current_uat_v1();
  v_workspace:=solver_private.variant_set_workspace_v2(v_variant_ids,v_context,v_visibility<>'NONE');
  if v_visibility<>'NONE' then
    select jsonb_build_object('baseCostMinor',f.base_cost_minor,'additionsCostMinor',f.additions_cost_minor,
      'totalCostMinor',f.total_cost_minor,'currency',f.currency,'budgetMinor',f.budget_minor)
    into v_finance from solver_private.published_schedule_finance_v2 f where f.schedule_id=v_schedule.id;
    v_workspace:=jsonb_set(v_workspace,'{finance}',coalesce(v_finance,'null'::jsonb),true);
  end if;
  return solver_private.redact_workspace_finance_uat_v1(v_workspace,v_visibility);
end;
$$;


ALTER FUNCTION "public"."optimizer_published_schedule_v2"("p_schedule_id" "uuid") OWNER TO "postgres";

--
-- Name: optimizer_request_before_nfjob_uat_v1("date", "uuid", "text", "uuid", "text", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_request_before_nfjob_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_frontend_version" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_result jsonb;
  v_run_id uuid;
  v_existing_frontend_version text;
begin
  if length(coalesce(p_frontend_version,'')) not between 1 and 500
    or p_frontend_version !~ '^[A-Za-z0-9][A-Za-z0-9._:@/-]*$' then
    raise exception 'FRONTEND_VERSION_INVALID';
  end if;

  v_result := public.optimizer_request_v2(
    p_month,p_scenario_id,p_scope_type,p_scope_role_id,p_name,p_idempotency_key
  );
  v_run_id := nullif(v_result#>>'{run,id}','')::uuid;
  if v_run_id is null then raise exception 'RUN_ID_MISSING'; end if;

  select r.version_stamp#>>'{frontend,buildId}'
  into v_existing_frontend_version
  from public.optimization_runs_v2 r
  where r.id=v_run_id
  for update;
  if v_existing_frontend_version is not null
    and v_existing_frontend_version<>p_frontend_version then
    raise exception 'IDEMPOTENCY_KEY_REUSED';
  end if;

  update public.optimization_runs_v2 r
  set version_stamp=jsonb_set(
        r.version_stamp,
        '{frontend}',
        jsonb_build_object('buildId',p_frontend_version),
        true
      ),
      updated_at=now()
  where r.id=v_run_id;

  return v_result||jsonb_build_object(
    'versionStamp',jsonb_build_object(
      'schemaVersion',1,
      'frontend',jsonb_build_object('buildId',p_frontend_version)
    )
  );
end;
$_$;


ALTER FUNCTION "public"."optimizer_request_before_nfjob_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_frontend_version" "text") OWNER TO "postgres";

--
-- Name: optimizer_request_cancel_before_nfjob_uat_v1("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_request_cancel_before_nfjob_uat_v1"("p_run_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_run public.optimization_runs_v2%rowtype;
begin
  if not solver_private.can_access_run_v2(p_run_id) then raise exception 'RUN_NOT_FOUND'; end if;
  select * into v_run from public.optimization_runs_v2 where id=p_run_id for update;
  if v_run.status in ('READY','FAILED','CANCELLED','STALE_INPUT') then
    raise exception 'RUN_NOT_CANCELLABLE';
  end if;
  update public.optimization_runs_v2 set
    status=case when status='QUEUED' then 'CANCELLED' else 'CANCEL_REQUESTED' end,
    phase=case when status='QUEUED' then 'CANCELLED' else 'CANCEL_REQUESTED' end,
    cancel_requested_at=now(),finished_at=case when status='QUEUED' then now() else finished_at end,
    updated_at=now()
  where id=p_run_id;
  update public.optimization_run_strategies_v2 set
    status=case when status='QUEUED' then 'CANCELLED' else status end,
    phase=case when status='QUEUED' then 'CANCELLED' else phase end,
    finished_at=case when status='QUEUED' then now() else finished_at end,
    updated_at=now()
  where run_id=p_run_id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action)
  values(auth.uid(),'optimization_run_v2',p_run_id::text,'CANCEL_REQUEST');
  return solver_private.run_status_payload_v2(p_run_id);
end;
$$;


ALTER FUNCTION "public"."optimizer_request_cancel_before_nfjob_uat_v1"("p_run_id" "uuid") OWNER TO "postgres";

--
-- Name: optimizer_request_cancel_v2("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_request_cancel_v2"("p_run_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_result jsonb; v_status text;
begin
  v_result:=public.optimizer_request_cancel_before_nfjob_uat_v1(p_run_id);
  select status into v_status from public.optimization_runs_v2 where id=p_run_id;
  update solver_private.solver_job_dispatch_outbox_uat_v1
  set dispatch_status=case when v_status='CANCELLED' then 'CANCELLED'
        else dispatch_status end,
      last_error_code='CANCEL_REQUESTED',
      job_finished_at=case when v_status='CANCELLED' then now()
        else job_finished_at end,
      updated_at=now()
  where run_id=p_run_id;
  return v_result;
end;
$$;


ALTER FUNCTION "public"."optimizer_request_cancel_v2"("p_run_id" "uuid") OWNER TO "postgres";

--
-- Name: optimizer_request_job_uat_v1("date", "uuid", "text", "uuid", "text", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_request_job_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_frontend_version" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_result jsonb;
  v_run public.optimization_runs_v2%rowtype;
  v_config solver_private.solver_job_runtime_config_uat_v1%rowtype;
begin
  v_result:=solver_private.optimizer_request_stamped_uat_v1(
    p_month,p_scenario_id,p_scope_type,p_scope_role_id,p_name,
    p_idempotency_key,p_frontend_version,'JOB'
  );
  select * into v_run from public.optimization_runs_v2
  where id=nullif(v_result#>>'{run,id}','')::uuid for update;
  if v_run.id is null then raise exception 'RUN_ID_MISSING'; end if;
  select * into v_config
  from solver_private.solver_job_runtime_config_uat_v1 where singleton;

  if v_run.queue_message_id is not null then
    perform pgmq.archive('schedule_optimizer_v2',v_run.queue_message_id);
  end if;
  update public.optimization_runs_v2
  set queue_message_id=null,phase='DISPATCH_PENDING',updated_at=now()
  where id=v_run.id;

  insert into solver_private.solver_job_dispatch_outbox_uat_v1(
    run_id,organization_key,month,scope_type,scope_role_id,requested_at,
    configured_plan,configured_vcpu,configured_ram_mb,estimated_usd_per_hour
  ) values(
    v_run.id,v_run.matrix_version_id,v_run.month,v_run.scope_type,
    v_run.scope_role_id,v_run.queued_at,v_config.deployment_plan,
    v_config.configured_vcpu,v_config.configured_ram_mb,
    v_config.estimated_usd_per_hour
  ) on conflict(run_id) do nothing;

  return v_result||jsonb_build_object(
    'executionMode','JOB','dispatchStatus','PENDING'
  );
exception
  when unique_violation then
    raise exception 'SCHEDULE_GENERATION_ACTIVE';
end;
$$;


ALTER FUNCTION "public"."optimizer_request_job_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_frontend_version" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_request_job_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_frontend_version" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_request_job_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_frontend_version" "text") IS 'Explicit UAT-only JOB request. The default optimizer_request_v2 remains SERVICE.';


--
-- Name: optimizer_request_v2("date", "uuid", "text", "uuid", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_request_v2"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_idempotency_key" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_user uuid := auth.uid();
  v_month date := date_trunc('month',p_month)::date;
  v_period_end date := (date_trunc('month',p_month)+interval '1 month - 1 day')::date;
  v_matrix_id uuid;
  v_scenario public.matrix_scenarios_v2%rowtype;
  v_scope_logical_id uuid;
  v_run_id uuid;
  v_existing public.optimization_runs_v2%rowtype;
  v_snapshot jsonb;
  v_hash text;
  v_message_id bigint;
  v_engine text;
  v_solver_version text;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  select flag.engine,nullif(trim(flag.config->>'solverVersion'),'')
  into v_engine,v_solver_version
  from public.solver_feature_flags flag
  where flag.flag_key='DEFAULT_ENGINE' and flag.enabled;
  if v_engine is null then raise exception 'SOLVER_ENGINE_CONFIGURATION_MISSING'; end if;
  if v_engine not in ('ALPHA15','SHADOW','ORTOOLS_V2') then
    raise exception 'SOLVER_ENGINE_CONFIGURATION_INVALID';
  end if;
  if v_engine not in ('SHADOW','ORTOOLS_V2') then
    raise exception 'ORTOOLS_REQUEST_DISABLED';
  end if;
  if length(coalesce(v_solver_version,'')) not between 1 and 200 then
    raise exception 'SOLVER_VERSION_CONFIGURATION_REQUIRED';
  end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  p_scope_type := upper(coalesce(p_scope_type,'COMPANY'));
  if p_scope_type not in ('COMPANY','ROLE') then raise exception 'INVALID_SCOPE'; end if;
  if (p_scope_type='ROLE')<>(p_scope_role_id is not null) then
    raise exception 'INVALID_SCOPE_ROLE';
  end if;
  if length(coalesce(p_idempotency_key,'')) not between 8 and 200 then
    raise exception 'INVALID_IDEMPOTENCY_KEY';
  end if;
  if length(trim(coalesce(p_name,''))) not between 1 and 200 then
    raise exception 'INVALID_PLAN_NAME';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_user::text||':'||p_idempotency_key,0));
  select * into v_existing from public.optimization_runs_v2 r
  where r.requested_by=v_user and r.idempotency_key=p_idempotency_key;
  if v_existing.id is not null then
    if v_existing.month<>v_month
      or v_existing.scenario_id<>p_scenario_id
      or v_existing.scope_type<>p_scope_type
      or v_existing.scope_role_id is distinct from p_scope_role_id
      or v_existing.request_engine<>v_engine
      or v_existing.solver_version<>v_solver_version
      or v_existing.name<>trim(p_name) then
      raise exception 'IDEMPOTENCY_KEY_REUSED';
    end if;
    return solver_private.run_status_payload_v2(v_existing.id)
      ||jsonb_build_object('reused',true);
  end if;

  -- Serialize the immutable snapshot boundary with every planning-data write.
  -- The lock is released automatically when this request transaction commits.
  perform solver_private.lock_planning_revision_v2();

  -- A monthly run always uses the Matrix that was effective at the first day
  -- of that month. This keeps historical reruns reproducible and prevents a
  -- mid-month publication from rewriting rules for days already elapsed.
  select mv.id into v_matrix_id
  from public.matrix_versions mv
  where mv.status in ('ACTIVE','ARCHIVED') and mv.schema_version>=2
    and solver_private.matrix_covers_planning_month_uat_v1(mv.effective_from,v_month)
    and coalesce(mv.content_hash,'') ~ '^[0-9a-f]{64}$'
    and coalesce(mv.workforce_hash,'') ~ '^[0-9a-f]{64}$'
  order by mv.effective_from desc,mv.version desc limit 1;
  if v_matrix_id is null then raise exception 'MATRIX_V2_FOR_MONTH_NOT_FOUND'; end if;

  select * into v_scenario from public.matrix_scenarios_v2 s
  where s.id=p_scenario_id and s.matrix_version_id=v_matrix_id and s.active;
  if v_scenario.id is null then raise exception 'SCENARIO_NOT_FOUND'; end if;
  if v_scenario.valid_to is not null and v_scenario.valid_to<v_month then
    raise exception 'SCENARIO_OUTSIDE_PERIOD';
  end if;
  if v_scenario.valid_from is not null and v_scenario.valid_from>v_period_end then
    raise exception 'SCENARIO_OUTSIDE_PERIOD';
  end if;
  if p_scope_type='COMPANY' and not (
    public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  ) then raise exception 'COMPANY_SCOPE_FORBIDDEN'; end if;
  if p_scope_type='ROLE' then
    select r.logical_id into v_scope_logical_id
    from public.matrix_roles_v2 r
    where r.id=p_scope_role_id and r.matrix_version_id=v_matrix_id and r.active;
    if v_scope_logical_id is null then raise exception 'SCOPE_ROLE_NOT_FOUND'; end if;
    if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN'))
      and not exists(
        select 1 from public.matrix_scope_grants_v2 g
        where g.auth_user_id=v_user and g.active and g.app_role='ROLE_MANAGER'
          and (g.role_logical_id is null or g.role_logical_id=v_scope_logical_id)
      ) then raise exception 'ROLE_SCOPE_FORBIDDEN'; end if;
  end if;

  v_run_id := gen_random_uuid();
  v_snapshot := solver_private.build_snapshot_payload_v2(
    v_run_id,v_month,v_matrix_id,v_scenario.id,p_scope_type,p_scope_role_id
  );
  if jsonb_array_length(v_snapshot->'strategies')=0 then
    raise exception 'SNAPSHOT_HAS_NO_STRATEGIES';
  end if;
  v_hash := encode(extensions.digest(convert_to(
    solver_private.canonical_json_v2(v_snapshot),'UTF8'
  ),'sha256'),'hex');

  insert into public.optimization_runs_v2(
    id,idempotency_key,month,matrix_version_id,scenario_id,scope_type,
    scope_role_id,name,requested_by,snapshot_hash,request_engine,solver_version
  ) values(
    v_run_id,p_idempotency_key,v_month,v_matrix_id,v_scenario.id,p_scope_type,
    p_scope_role_id,trim(p_name),v_user,v_hash,v_engine,v_solver_version
  );

  insert into public.optimization_run_strategies_v2(
    run_id,strategy_id,ordinal,status,phase,progress
  )
  select v_run_id,(strategy.value->>'id')::uuid,strategy.ordinality::integer,
    'QUEUED','QUEUED',0
  from jsonb_array_elements(v_snapshot->'strategies')
    with ordinality strategy(value,ordinality)
  order by strategy.ordinality;

  insert into solver_private.optimization_snapshots_v2(
    run_id,schema_version,snapshot_hash,snapshot
  ) values(v_run_id,2,v_hash,v_snapshot);

  select pgmq.send('schedule_optimizer_v2',jsonb_build_object(
    'schemaVersion',2,'runId',v_run_id,'snapshotHash',v_hash
  )) into v_message_id;
  update public.optimization_runs_v2 set queue_message_id=v_message_id where id=v_run_id;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_user,'optimization_run_v2',v_run_id::text,'REQUEST',jsonb_build_object(
    'month',v_month,'matrixVersionId',v_matrix_id,'scenarioId',v_scenario.id,
    'scopeType',p_scope_type,'scopeRoleId',p_scope_role_id,'snapshotHash',v_hash,
    'requestEngine',v_engine,'solverVersion',v_solver_version
  ));

  return jsonb_build_object(
    'run',jsonb_build_object(
      'id',v_run_id,'status','QUEUED','phase','QUEUED','progress',0,
      'month',v_month,'scopeType',p_scope_type,'scopeRoleId',p_scope_role_id,
      'requestEngine',v_engine,'solverVersion',v_solver_version,
      'scenario',jsonb_build_object('id',v_scenario.id,'name',v_scenario.name),
      'createdAt',now()
    ),'reused',false
  );
end;
$_$;


ALTER FUNCTION "public"."optimizer_request_v2"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_idempotency_key" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_request_v2"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_idempotency_key" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_request_v2"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_idempotency_key" "text") IS 'Creates an immutable Matrix v2 snapshot and enqueues a dynamic OR-Tools run.';


--
-- Name: optimizer_request_v2("date", "uuid", "text", "uuid", "text", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_request_v2"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_frontend_version" "text") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select solver_private.optimizer_request_stamped_uat_v1(
    p_month,p_scenario_id,p_scope_type,p_scope_role_id,p_name,
    p_idempotency_key,p_frontend_version,'SERVICE'
  )
$$;


ALTER FUNCTION "public"."optimizer_request_v2"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_frontend_version" "text") OWNER TO "postgres";

--
-- Name: optimizer_role_categories_uat_v1("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_role_categories_uat_v1"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_matrix uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select id into v_matrix from public.matrix_versions
  where status in ('ACTIVE','ARCHIVED') and schema_version>=2
    and solver_private.matrix_covers_planning_month_uat_v1(
      effective_from,date_trunc('month',p_month)::date
    )
  order by effective_from desc,version desc limit 1;
  return jsonb_build_object('categories',coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',category.id,'code',category.code,'name',category.name,'color',category.color,
      'sortOrder',category.sort_order,'anchorRoleId',roles.anchor_role_id,
      'roleIds',roles.role_ids,'roleNames',roles.role_names
    ) order by category.sort_order,category.code)
    from public.matrix_role_categories_v2 category
    cross join lateral (
      select (array_agg(role_row.id order by
          case when exists(select 1 from public.matrix_staffing_rules_v2 staffing
            where staffing.matrix_version_id=v_matrix and staffing.role_id=role_row.id and staffing.active) then 0 else 1 end,
          role_row.sort_order,role_row.code))[1] anchor_role_id,
        jsonb_agg(role_row.id order by role_row.sort_order,role_row.code) role_ids,
        jsonb_agg(role_row.name order by role_row.sort_order,role_row.code) role_names
      from public.matrix_roles_v2 role_row
      where role_row.matrix_version_id=v_matrix and role_row.category_id=category.id and role_row.active
    ) roles
    where category.matrix_version_id=v_matrix and category.active and roles.anchor_role_id is not null
  ),'[]'::jsonb));
end;
$$;


ALTER FUNCTION "public"."optimizer_role_categories_uat_v1"("p_month" "date") OWNER TO "postgres";

--
-- Name: optimizer_role_colours_uat_v1("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_role_colours_uat_v1"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
  with matrix as (
    select matrix_version.id
    from public.matrix_versions matrix_version
    where matrix_version.status in ('ACTIVE','ARCHIVED') and matrix_version.schema_version>=2
      and matrix_version.effective_from<=date_trunc('month',p_month)::date
      and coalesce(matrix_version.content_hash,'') ~ '^[0-9a-f]{64}$'
      and coalesce(matrix_version.workforce_hash,'') ~ '^[0-9a-f]{64}$'
    order by matrix_version.effective_from desc,matrix_version.version desc limit 1
  )
  select jsonb_build_object('roles',coalesce(jsonb_agg(jsonb_build_object(
    'id',role.id,'logicalId',role.logical_id,'code',role.code,'name',role.name,'color',role.color
  ) order by role.sort_order,role.name),'[]'::jsonb))
  from matrix join public.matrix_roles_v2 role on role.matrix_version_id=matrix.id and role.active
  where auth.uid() is not null
$_$;


ALTER FUNCTION "public"."optimizer_role_colours_uat_v1"("p_month" "date") OWNER TO "postgres";

--
-- Name: optimizer_role_composite_candidates_before_categories_uat_v1("date", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_role_composite_candidates_before_categories_uat_v1"("p_month" "date", "p_scenario_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_month date;
  v_matrix_version_id uuid;
  v_scenario_name text;
  v_active_solver_version text;
  v_roles jsonb;
  v_missing_roles jsonb;
  v_variant_ids jsonb;
  v_demanded_count integer;
  v_candidate_count integer;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  if p_scenario_id is null then raise exception 'SCENARIO_REQUIRED'; end if;
  v_month := date_trunc('month',p_month)::date;
  v_active_solver_version :=
    solver_private.active_ortools_solver_version_v2();

  select scenario.matrix_version_id,scenario.name
  into v_matrix_version_id,v_scenario_name
  from public.matrix_scenarios_v2 scenario
  join public.matrix_versions matrix
    on matrix.id=scenario.matrix_version_id and matrix.schema_version>=2
  where scenario.id=p_scenario_id and scenario.active;
  if v_matrix_version_id is null then raise exception 'SCENARIO_NOT_FOUND'; end if;

  with demanded as (
    select demand.role_id,sum(demand.required_count)::bigint demand_slot_count
    from solver_private.resolved_demand_v2(
      v_month,v_matrix_version_id,p_scenario_id,null
    ) demand
    group by demand.role_id
  ), candidates as (
    select demanded.role_id,demanded.demand_slot_count,role.name role_name,
      role.color role_color,role.sort_order,
      candidate.run_id,candidate.run_created_at,candidate.run_finished_at,
      candidate.variant_id,candidate.variant_name,candidate.variant_status,
      candidate.assignment_count,candidate.unfilled_count,
      candidate.solver_status,candidate.selected_at,
      candidate.strategy_id,candidate.strategy_name,candidate.strategy_code
    from demanded
    join public.matrix_roles_v2 role
      on role.id=demanded.role_id
      and role.matrix_version_id=v_matrix_version_id
    left join lateral (
      select run.id run_id,run.created_at run_created_at,
        run.finished_at run_finished_at,variant.id variant_id,
        variant.name variant_name,variant.status variant_status,
        variant.assignment_count,variant.unfilled_count,
        variant.solver_status,variant.selected_at,
        strategy.id strategy_id,strategy.name strategy_name,
        strategy.code strategy_code
      from public.optimization_runs_v2 run
      join public.plan_variants_v2 variant
        on variant.run_id=run.id and variant.selected
        and variant.hard_violations=0
        and variant.status in ('SELECTED','PUBLISHED')
      join public.matrix_strategies_v2 strategy
        on strategy.id=variant.strategy_id
      where run.month=v_month
        and run.matrix_version_id=v_matrix_version_id
        and run.scenario_id=p_scenario_id
        and run.request_engine='ORTOOLS_V2'
        and run.solver_version=v_active_solver_version
        and run.scope_type='ROLE'
        and run.scope_role_id=demanded.role_id
        and run.status='READY'
      order by run.finished_at desc nulls last,run.created_at desc,
        variant.selected_at desc nulls last,variant.created_at desc,
        run.id desc,variant.id desc
      limit 1
    ) candidate on true
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'role',jsonb_build_object(
        'id',candidate.role_id,'name',candidate.role_name,
        'color',candidate.role_color,'sortOrder',candidate.sort_order
      ),
      'demandSlotCount',candidate.demand_slot_count,
      'run',case when candidate.run_id is null then null else jsonb_build_object(
        'id',candidate.run_id,'status','READY',
        'createdAt',candidate.run_created_at,
        'finishedAt',candidate.run_finished_at
      ) end,
      'variant',case when candidate.variant_id is null then null
        else jsonb_build_object(
          'id',candidate.variant_id,'name',candidate.variant_name,
          'status',candidate.variant_status,
          'assignmentCount',candidate.assignment_count,
          'unfilledCount',candidate.unfilled_count,
          'solverStatus',candidate.solver_status,
          'selectedAt',candidate.selected_at,
          'strategy',jsonb_build_object(
            'id',candidate.strategy_id,'name',candidate.strategy_name,
            'code',candidate.strategy_code
          )
        ) end,
      'ready',candidate.variant_id is not null
    ) order by candidate.sort_order,candidate.role_name,
      candidate.role_id::text),'[]'::jsonb),
    coalesce(jsonb_agg(jsonb_build_object(
      'id',candidate.role_id,'name',candidate.role_name
    ) order by candidate.sort_order,candidate.role_name,
      candidate.role_id::text)
      filter(where candidate.variant_id is null),'[]'::jsonb),
    coalesce(jsonb_agg(to_jsonb(candidate.variant_id)
      order by candidate.sort_order,candidate.role_name,
        candidate.role_id::text)
      filter(where candidate.variant_id is not null),'[]'::jsonb),
    count(*)::integer,count(candidate.variant_id)::integer
  into v_roles,v_missing_roles,v_variant_ids,
    v_demanded_count,v_candidate_count
  from candidates candidate;

  return jsonb_build_object(
    'month',v_month,
    'scenario',jsonb_build_object(
      'id',p_scenario_id,'name',v_scenario_name
    ),
    'matrixVersionId',v_matrix_version_id,
    'roles',v_roles,
    'missingRoles',v_missing_roles,
    'variantIds',v_variant_ids,
    'demandedRoleCount',v_demanded_count,
    'ready',v_demanded_count>0 and v_candidate_count=v_demanded_count
  );
end;
$$;


ALTER FUNCTION "public"."optimizer_role_composite_candidates_before_categories_uat_v1"("p_month" "date", "p_scenario_id" "uuid") OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_role_composite_candidates_before_categories_uat_v1"("p_month" "date", "p_scenario_id" "uuid"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_role_composite_candidates_before_categories_uat_v1"("p_month" "date", "p_scenario_id" "uuid") IS 'Returns selected ROLE candidates produced by the exact active solverVersion.';


--
-- Name: optimizer_role_composite_candidates_before_publication_fallback("date", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_role_composite_candidates_before_publication_fallback"("p_month" "date", "p_scenario_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_raw jsonb; v_matrix uuid; v_roles jsonb; v_missing jsonb;
begin
  v_raw:=public.optimizer_role_composite_candidates_before_categories_uat_v1(p_month,p_scenario_id);
  select id into v_matrix from public.matrix_versions where status in('ACTIVE','ARCHIVED') and schema_version>=2
    and effective_from<=date_trunc('month',p_month)::date order by effective_from desc,version desc limit 1;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',anchor.id,'name',category.name,'sortOrder',category.sort_order,
    'variant',coalesce((select item.value->'variant' from jsonb_array_elements(coalesce(v_raw->'roles','[]'::jsonb)) item where item.value->>'id'=anchor.id::text limit 1),'null'::jsonb)
  ) order by category.sort_order,category.code),'[]'::jsonb),
  coalesce(jsonb_agg(anchor.id) filter(where not exists(
    select 1 from jsonb_array_elements(coalesce(v_raw->'roles','[]'::jsonb)) item
    where item.value->>'id'=anchor.id::text and jsonb_typeof(item.value->'variant')='object'
  )),'[]'::jsonb)
  into v_roles,v_missing
  from public.matrix_role_categories_v2 category
  cross join lateral(select role_row.id from public.matrix_roles_v2 role_row
    where role_row.matrix_version_id=v_matrix and role_row.category_id=category.id and role_row.active
    order by case when exists(select 1 from public.matrix_staffing_rules_v2 staffing
      where staffing.matrix_version_id=v_matrix and staffing.role_id=role_row.id and staffing.active) then 0 else 1 end,
      role_row.sort_order,role_row.code limit 1) anchor
  where category.matrix_version_id=v_matrix and category.active
    and exists(select 1 from jsonb_array_elements(coalesce(v_raw->'roles','[]'::jsonb)) raw_role
      join public.matrix_roles_v2 demanded on demanded.id=(raw_role.value->>'id')::uuid
      where demanded.category_id=category.id);
  return jsonb_set(jsonb_set(jsonb_set(v_raw,'{roles}',v_roles,true),'{missingRoleIds}',v_missing,true),'{ready}',to_jsonb(jsonb_array_length(v_missing)=0 and jsonb_array_length(v_roles)>0),true);
end; $$;


ALTER FUNCTION "public"."optimizer_role_composite_candidates_before_publication_fallback"("p_month" "date", "p_scenario_id" "uuid") OWNER TO "postgres";

--
-- Name: optimizer_role_composite_candidates_v2("date", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_role_composite_candidates_v2"("p_month" "date", "p_scenario_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_raw jsonb;
  v_overview jsonb;
  v_roles jsonb;
begin
  v_raw := public.optimizer_role_composite_candidates_before_publication_fallback_uat_v1(
    p_month, p_scenario_id
  );
  if jsonb_array_length(coalesce(v_raw->'roles', '[]'::jsonb)) > 0 then
    return v_raw;
  end if;

  v_overview := public.optimizer_role_publication_overview_uat_v2(p_month);
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', item.value->'role'->>'id',
    'name', item.value->'role'->>'name',
    'sortOrder', item.ordinality,
    'variant', jsonb_build_object(
      'id', item.value->>'variantId',
      'name', coalesce(nullif(item.value->>'name', ''), 'Opublikowany wariant zespołu'),
      'strategy', jsonb_build_object(
        'id', 'PUBLISHED_ROLE_VARIANT',
        'name', 'Opublikowany wariant zespołu'
      ),
      'assignmentCount', coalesce((item.value->>'assignmentCount')::integer, 0),
      'unfilledCount', coalesce((item.value->>'unfilledCount')::integer, 0),
      'solverStatus', 'PUBLISHED'
    )
  ) order by item.ordinality), '[]'::jsonb)
  into v_roles
  from jsonb_array_elements(coalesce(v_overview->'roles', '[]'::jsonb))
    with ordinality item(value, ordinality)
  where item.value->'scenario'->>'id' = p_scenario_id::text
    and nullif(item.value->>'variantId', '') is not null;

  if jsonb_array_length(v_roles) = 0 then
    return v_raw;
  end if;

  return jsonb_set(
    jsonb_set(
      jsonb_set(v_raw, '{roles}', v_roles, true),
      '{missingRoleIds}', '[]'::jsonb, true
    ),
    '{ready}', 'true'::jsonb, true
  );
end;
$$;


ALTER FUNCTION "public"."optimizer_role_composite_candidates_v2"("p_month" "date", "p_scenario_id" "uuid") OWNER TO "postgres";

--
-- Name: optimizer_role_composite_preflight_uat_v2("date", "uuid", "uuid"[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_role_composite_preflight_uat_v2"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_month date := date_trunc('month', p_month)::date;
  v_total integer := 0;
  v_critical integer := 0;
  v_gaps jsonb := '[]'::jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  if p_scenario_id is null then raise exception 'SCENARIO_REQUIRED'; end if;
  if coalesce(cardinality(p_variant_ids), 0) = 0 then raise exception 'VARIANTS_REQUIRED'; end if;

  if exists (
    select 1
    from public.plan_variants_v2 variant
    join public.optimization_runs_v2 run on run.id = variant.run_id
    where variant.id = any(p_variant_ids)
      and (run.month <> v_month or run.scenario_id <> p_scenario_id)
  ) then raise exception 'ROLE_COMPOSITE_REFERENCE_MISMATCH'; end if;

  with issue_groups as (
    select min(issue.id)::text issue_id, issue.variant_id, issue.shift_id, issue.role_id,
      count(*)::integer missing_count,
      string_agg(distinct coalesce(issue.message, 'Nieobsadzone miejsce w wymaganej obsadzie.'), ' ') message
    from public.plan_issues_v2 issue
    where issue.variant_id = any(p_variant_ids)
      and issue.issue_code = 'UNFILLED_SLOT'
      and greatest(coalesce(issue.required_count, 0) - coalesce(issue.assigned_count, 0), 0) > 0
    group by issue.variant_id, issue.shift_id, issue.role_id
  ), gaps as (
    select grouped.issue_id, grouped.variant_id, shift.shift_date,
      to_char(shift.starts_at at time zone coalesce(location.timezone, 'Europe/Warsaw'), 'HH24:MI') starts_at,
      to_char(shift.ends_at at time zone coalesce(location.timezone, 'Europe/Warsaw'), 'HH24:MI') ends_at,
      coalesce(location.name, 'Lokal') location_name,
      coalesce(role.name, 'Rola') role_name,
      grouped.missing_count,
      assigned.assigned_count + grouped.missing_count required_count,
      assigned.assigned_count,
      assigned.assigned_count = 0 critical,
      grouped.message
    from issue_groups grouped
    join public.plan_shifts_v2 shift on shift.id = grouped.shift_id
    left join public.matrix_locations_v2 location on location.id = shift.location_id
    left join public.matrix_roles_v2 role on role.id = grouped.role_id
    cross join lateral (
      select count(*)::integer assigned_count
      from public.plan_assignments_v2 assignment
      where assignment.variant_id = grouped.variant_id
        and assignment.shift_id = grouped.shift_id
        and assignment.role_id = grouped.role_id
    ) assigned
  )
  select coalesce(sum(gap.missing_count), 0)::integer,
    coalesce(sum(gap.missing_count) filter (where gap.critical), 0)::integer,
    coalesce(jsonb_agg(jsonb_build_object(
      'issueId', gap.issue_id,
      'variantId', gap.variant_id,
      'date', gap.shift_date,
      'startsAt', gap.starts_at,
      'endsAt', gap.ends_at,
      'location', gap.location_name,
      'role', gap.role_name,
      'requiredCount', gap.required_count,
      'assignedCount', gap.assigned_count,
      'missingCount', gap.missing_count,
      'critical', gap.critical,
      'message', gap.message
    ) order by gap.shift_date, gap.starts_at, gap.location_name, gap.role_name), '[]'::jsonb)
  into v_total, v_critical, v_gaps
  from gaps gap;

  return jsonb_build_object(
    'month', v_month,
    'scenarioId', p_scenario_id,
    'totalGaps', v_total,
    'criticalGaps', v_critical,
    'gaps', v_gaps
  );
end;
$$;


ALTER FUNCTION "public"."optimizer_role_composite_preflight_uat_v2"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[]) OWNER TO "postgres";

--
-- Name: optimizer_role_publication_overview_before_categories_uat_v1("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_role_publication_overview_before_categories_uat_v1"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_month date:=date_trunc('month',p_month)::date;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  with role_rows as (
    select publication.id publication_id,publication.name,
      publication.published_at,role.id role_id,role.name role_name,
      scenario.id scenario_id,scenario.name scenario_name,
      variant.id variant_id,variant.assignment_count,variant.unfilled_count,
      coalesce((variant.metrics->>'OVERTIME_MINUTES')::bigint,0) overtime_minutes,
      coalesce(finance.total_cost_minor,0) total_cost_minor,
      coalesce(finance.currency,'PLN') currency,
      coalesce((select count(distinct assignment.employee_id)
        from public.plan_assignments_v2 assignment
        where assignment.variant_id=variant.id),0)::integer team_size,
      coalesce((select sum(extract(epoch from
        (shift.ends_at-shift.starts_at))/60)::bigint
        from public.plan_assignments_v2 assignment
        join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
        where assignment.variant_id=variant.id),0) scheduled_minutes
    from public.published_role_schedules_v2 publication
    join public.matrix_roles_v2 role on role.id=publication.role_id
    join public.matrix_scenarios_v2 scenario on scenario.id=publication.scenario_id
    join public.plan_variants_v2 variant on variant.id=publication.variant_id
    left join solver_private.plan_variant_finance_v2 finance
      on finance.variant_id=variant.id
    where publication.month=v_month and publication.status='PUBLISHED'
  ), totals as (
    select count(*)::integer published_roles,
      coalesce(sum(assignment_count),0)::bigint assignment_count,
      coalesce(sum(unfilled_count),0)::bigint unfilled_count,
      coalesce(sum(overtime_minutes),0)::bigint overtime_minutes,
      coalesce(sum(total_cost_minor),0)::bigint total_cost_minor,
      coalesce(sum(scheduled_minutes),0)::bigint scheduled_minutes
    from role_rows
  )
  select jsonb_build_object(
    'month',v_month,
    'totals',jsonb_build_object(
      'publishedRoles',totals.published_roles,
      'assignmentCount',totals.assignment_count,
      'unfilledCount',totals.unfilled_count,
      'overtimeMinutes',totals.overtime_minutes,
      'totalCostMinor',totals.total_cost_minor,
      'scheduledMinutes',totals.scheduled_minutes
    ),
    'roles',coalesce((select jsonb_agg(jsonb_build_object(
      'publicationId',row.publication_id,'name',row.name,
      'publishedAt',row.published_at,
      'role',jsonb_build_object('id',row.role_id,'name',row.role_name),
      'scenario',jsonb_build_object('id',row.scenario_id,'name',row.scenario_name),
      'variantId',row.variant_id,'assignmentCount',row.assignment_count,
      'unfilledCount',row.unfilled_count,'overtimeMinutes',row.overtime_minutes,
      'totalCostMinor',row.total_cost_minor,'currency',row.currency,
      'teamSize',row.team_size,'scheduledMinutes',row.scheduled_minutes
    ) order by row.role_name) from role_rows row),'[]'::jsonb)
  ) into v_result from totals;
  return v_result;
end;
$$;


ALTER FUNCTION "public"."optimizer_role_publication_overview_before_categories_uat_v1"("p_month" "date") OWNER TO "postgres";

--
-- Name: optimizer_role_publication_overview_uat_v2("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_role_publication_overview_uat_v2"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_raw jsonb; v_roles jsonb;
begin
  v_raw:=public.optimizer_role_publication_overview_before_categories_uat_v1(p_month);
  select coalesce(jsonb_agg(item.value||jsonb_build_object('role',jsonb_build_object(
    'id',role_row.id,'name',coalesce(category.name,role_row.name)
  )) order by item.ordinality),'[]'::jsonb) into v_roles
  from jsonb_array_elements(coalesce(v_raw->'roles','[]'::jsonb)) with ordinality item(value,ordinality)
  left join public.matrix_roles_v2 role_row on role_row.id=(item.value->'role'->>'id')::uuid
  left join public.matrix_role_categories_v2 category on category.id=role_row.category_id;
  return jsonb_set(v_raw,'{roles}',v_roles,true);
end; $$;


ALTER FUNCTION "public"."optimizer_role_publication_overview_uat_v2"("p_month" "date") OWNER TO "postgres";

--
-- Name: optimizer_run_state_v2("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_run_state_v2"("p_run_id" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select case when r.id is null then null else jsonb_build_object(
    'runId',r.id,'status',r.status,'generation',r.current_generation,
    'targetGenerations',r.target_generations,'input',r.input_payload,
    'checkpoint',r.checkpoint,'summary',r.result_summary
  ) end from public.optimization_runs r
  where r.id=p_run_id and r.requested_by=auth.uid() and public.can_manage_plans();
$$;


ALTER FUNCTION "public"."optimizer_run_state_v2"("p_run_id" "uuid") OWNER TO "postgres";

--
-- Name: optimizer_runs_catalog_alpha16("date", "text", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_runs_catalog_alpha16"("p_month" "date", "p_scope_type" "text" DEFAULT 'COMPANY'::"text", "p_scope_role_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_payload jsonb; v_visibility text; v_run jsonb; v_variant jsonb;
  v_runs jsonb:='[]'::jsonb; v_variants jsonb;
begin
  v_payload:=public.optimizer_runs_catalog_before_b4f101_alpha16(p_month,p_scope_type,p_scope_role_id);
  v_visibility:=public.application_finance_visibility_current_uat_v1();
  if v_visibility in ('FULL','AGGREGATE') then return v_payload; end if;
  for v_run in select value from jsonb_array_elements(coalesce(v_payload->'runs','[]'::jsonb)) loop
    v_variants:='[]'::jsonb;
    for v_variant in select value from jsonb_array_elements(coalesce(v_run->'variants','[]'::jsonb)) loop
      v_variants:=v_variants||jsonb_build_array(v_variant-'totalCostMinor'-'currency');
    end loop;
    v_runs:=v_runs||jsonb_build_array(jsonb_set(v_run,'{variants}',v_variants,true));
  end loop;
  return jsonb_set(v_payload,'{runs}',v_runs,true);
end;
$$;


ALTER FUNCTION "public"."optimizer_runs_catalog_alpha16"("p_month" "date", "p_scope_type" "text", "p_scope_role_id" "uuid") OWNER TO "postgres";

--
-- Name: optimizer_runs_catalog_before_b4f101_alpha16("date", "text", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_runs_catalog_before_b4f101_alpha16"("p_month" "date", "p_scope_type" "text" DEFAULT 'COMPANY'::"text", "p_scope_role_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_month date:=date_trunc('month',p_month)::date;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  return jsonb_build_object(
    'month',v_month,'scopeType',upper(coalesce(p_scope_type,'COMPANY')),
    'runs',coalesce((select jsonb_agg(jsonb_build_object(
      'id',run.id,'name',run.name,'status',run.status,'phase',run.phase,
      'progress',run.progress,'createdAt',run.created_at,'finishedAt',run.finished_at,
      'scenario',jsonb_build_object('id',scenario.id,'code',scenario.code,
        'name',scenario.name),
      'scope',jsonb_build_object('type',run.scope_type,'roleId',run.scope_role_id,
        'roleName',role.name),
      'variants',coalesce((select jsonb_agg(jsonb_build_object(
        'id',variant.id,'name',variant.name,'status',variant.status,
        'selected',variant.selected,'recommended',variant.recommended,
        'assignmentCount',variant.assignment_count,
        'unfilledCount',variant.unfilled_count,
        'hardViolations',variant.hard_violations,
        'solverStatus',variant.solver_status,
        'metrics',variant.metrics,
        'strategy',jsonb_build_object('id',strategy.id,'code',strategy.code,
          'name',strategy.name),
        'totalCostMinor',finance.total_cost_minor,'currency',finance.currency
      ) order by link.ordinal,variant.created_at)
        from public.plan_variants_v2 variant
        join public.optimization_run_strategies_v2 link
          on link.id=variant.run_strategy_id
        join public.matrix_strategies_v2 strategy on strategy.id=variant.strategy_id
        left join solver_private.plan_variant_finance_v2 finance
          on finance.variant_id=variant.id
        where variant.run_id=run.id),'[]'::jsonb)
    ) order by run.created_at desc,run.id desc)
      from public.optimization_runs_v2 run
      join public.matrix_scenarios_v2 scenario on scenario.id=run.scenario_id
      left join public.matrix_roles_v2 role on role.id=run.scope_role_id
      where run.month=v_month
        and run.scope_type=upper(coalesce(p_scope_type,'COMPANY'))
        and run.scope_role_id is not distinct from p_scope_role_id
        and (run.requested_by=auth.uid() or public.has_app_role('OWNER')
          or public.has_app_role('ADMIN'))
    ),'[]'::jsonb)
  );
end;
$$;


ALTER FUNCTION "public"."optimizer_runs_catalog_before_b4f101_alpha16"("p_month" "date", "p_scope_type" "text", "p_scope_role_id" "uuid") OWNER TO "postgres";

--
-- Name: optimizer_save_init_v4("uuid", integer, "jsonb", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_save_init_v4"("p_run_id" "uuid", "p_expected_cursor" integer, "p_checkpoint" "jsonb", "p_metrics" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_cursor integer;
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  update public.optimization_runs set
    checkpoint=coalesce(p_checkpoint,'{}'::jsonb),
    heartbeat_at=now(),
    result_summary=coalesce(result_summary,'{}'::jsonb)||coalesce(p_metrics,'{}'::jsonb)
  where id=p_run_id and requested_by=auth.uid() and status='RUNNING'
    and current_generation=0
    and coalesce((checkpoint->>'initCursor')::integer,0)=p_expected_cursor
  returning coalesce((checkpoint->>'initCursor')::integer,0) into v_cursor;
  if v_cursor is null then raise exception 'STALE_OR_FORBIDDEN_INIT_STATE'; end if;
  return jsonb_build_object('runId',p_run_id,'initCursor',v_cursor);
end $$;


ALTER FUNCTION "public"."optimizer_save_init_v4"("p_run_id" "uuid", "p_expected_cursor" integer, "p_checkpoint" "jsonb", "p_metrics" "jsonb") OWNER TO "postgres";

--
-- Name: optimizer_save_state_v3("uuid", integer, "jsonb", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_save_state_v3"("p_run_id" "uuid", "p_expected_generation" integer, "p_checkpoint" "jsonb", "p_metrics" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_generation integer;
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  update public.optimization_runs set
    checkpoint=coalesce(p_checkpoint,'{}'::jsonb),
    heartbeat_at=now(),
    result_summary=coalesce(result_summary,'{}'::jsonb)||coalesce(p_metrics,'{}'::jsonb)
  where id=p_run_id and requested_by=auth.uid() and status='RUNNING'
    and current_generation=p_expected_generation
  returning current_generation into v_generation;
  if v_generation is null then raise exception 'STALE_OR_FORBIDDEN_STATE'; end if;
  return jsonb_build_object('runId',p_run_id,'generation',v_generation);
end $$;


ALTER FUNCTION "public"."optimizer_save_state_v3"("p_run_id" "uuid", "p_expected_generation" integer, "p_checkpoint" "jsonb", "p_metrics" "jsonb") OWNER TO "postgres";

--
-- Name: optimizer_select_variant_v2("uuid", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_select_variant_v2"("p_run_id" "uuid", "p_variant_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_engine text;
  v_enabled boolean;
  v_active_solver_version text;
begin
  perform solver_private.lock_planning_revision_v2();
  select flag.engine,flag.enabled into v_engine,v_enabled
  from public.solver_feature_flags flag
  where flag.flag_key='DEFAULT_ENGINE';
  if v_enabled is distinct from true
    or v_engine is distinct from 'ORTOOLS_V2' then
    raise exception 'ORTOOLS_SELECTION_DISABLED';
  end if;
  v_active_solver_version :=
    solver_private.active_ortools_solver_version_v2();

  if not exists(
    select 1 from public.optimization_runs_v2 run
    where run.id=p_run_id
      and run.request_engine='ORTOOLS_V2'
      and run.solver_version=v_active_solver_version
  ) then raise exception 'RUN_SOLVER_VERSION_NOT_ACTIVE'; end if;

  return solver_private.optimizer_select_variant_pre_version_fence_v2(
    p_run_id,p_variant_id
  );
end;
$$;


ALTER FUNCTION "public"."optimizer_select_variant_v2"("p_run_id" "uuid", "p_variant_id" "uuid") OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_select_variant_v2"("p_run_id" "uuid", "p_variant_id" "uuid"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_select_variant_v2"("p_run_id" "uuid", "p_variant_id" "uuid") IS 'Selects only a READY variant produced by the currently active OR-Tools solver version.';


--
-- Name: optimizer_selected_variant_workspace_alpha16("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_selected_variant_workspace_alpha16"("p_run_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_workspace jsonb;
  v_variant_ids uuid[];
begin
  v_workspace:=public.optimizer_selected_variant_workspace_v2(p_run_id);
  select array_agg(variant.id order by variant.id)
  into v_variant_ids
  from public.plan_variants_v2 variant
  where variant.run_id=p_run_id and variant.selected;
  return solver_private.alpha16_enrich_workspace_issues_v2(
    v_workspace,v_variant_ids
  );
end;
$$;


ALTER FUNCTION "public"."optimizer_selected_variant_workspace_alpha16"("p_run_id" "uuid") OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_selected_variant_workspace_alpha16"("p_run_id" "uuid"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_selected_variant_workspace_alpha16"("p_run_id" "uuid") IS 'Selected solver variant with exact date, location, role, duty and staffing context for every issue.';


--
-- Name: optimizer_selected_variant_workspace_v2("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_selected_variant_workspace_v2"("p_run_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_variant_id uuid; v_visibility text; v_context jsonb; v_workspace jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not solver_private.can_access_run_v2(p_run_id) then raise exception 'RUN_NOT_FOUND'; end if;
  select v.id,jsonb_build_object('type','SELECTED_VARIANT','runId',r.id,'engine',r.request_engine,
    'requestEngine',r.request_engine,'month',r.month,'name',r.name,
    'scenario',jsonb_build_object('id',s.id,'name',s.name),'matrixVersionId',r.matrix_version_id)
  into v_variant_id,v_context from public.optimization_runs_v2 r
  join public.plan_variants_v2 v on v.run_id=r.id and v.selected
  join public.matrix_scenarios_v2 s on s.id=r.scenario_id where r.id=p_run_id;
  if v_variant_id is null then raise exception 'SELECTED_VARIANT_NOT_FOUND'; end if;
  v_visibility:=public.application_finance_visibility_current_uat_v1();
  v_workspace:=solver_private.variant_set_workspace_v2(array[v_variant_id],v_context,v_visibility<>'NONE');
  return solver_private.redact_workspace_finance_uat_v1(v_workspace,v_visibility);
end;
$$;


ALTER FUNCTION "public"."optimizer_selected_variant_workspace_v2"("p_run_id" "uuid") OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_selected_variant_workspace_v2"("p_run_id" "uuid"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_selected_variant_workspace_v2"("p_run_id" "uuid") IS 'Planner-only dynamic preview of the single consciously selected variant for a run.';


--
-- Name: optimizer_status_v2("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_status_v2"("p_run_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if not solver_private.can_access_run_v2(p_run_id) then raise exception 'RUN_NOT_FOUND'; end if;
  return solver_private.run_status_payload_v2(p_run_id);
end;
$$;


ALTER FUNCTION "public"."optimizer_status_v2"("p_run_id" "uuid") OWNER TO "postgres";

--
-- Name: optimizer_variant_issue_diagnostics_before_b4_details_uat_v2("uuid", bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_variant_issue_diagnostics_before_b4_details_uat_v2"("p_variant_id" "uuid", "p_issue_id" bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "public"."optimizer_variant_issue_diagnostics_before_b4_details_uat_v2"("p_variant_id" "uuid", "p_issue_id" bigint) OWNER TO "postgres";

--
-- Name: optimizer_variant_issue_diagnostics_before_capacity_context_uat("uuid", bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_variant_issue_diagnostics_before_capacity_context_uat"("p_variant_id" "uuid", "p_issue_id" bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_payload jsonb;
  v_candidates jsonb;
  v_summary jsonb;
begin
  v_payload:=public.optimizer_variant_issue_diagnostics_before_role_scope_uat_v2(
    p_variant_id,p_issue_id
  );
  select coalesce(jsonb_agg(case
    when coalesce((candidate.value->>'roleMatch')::boolean,false) then candidate.value
    else jsonb_set(candidate.value,'{reasons}','["ROLE_REQUIRED"]'::jsonb,true)
  end order by candidate.ordinality),'[]'::jsonb)
  into v_candidates
  from jsonb_array_elements(coalesce(v_payload->'candidates','[]'::jsonb))
    with ordinality candidate(value,ordinality);

  select jsonb_build_object(
    'considered',jsonb_array_length(v_candidates),
    'eligible',count(*) filter(where jsonb_array_length(candidate.value->'reasons')=0),
    'blocked',count(*) filter(where jsonb_array_length(candidate.value->'reasons')>0),
    'reasons',coalesce((
      select jsonb_agg(jsonb_build_object('code',grouped.reason,'count',grouped.amount)
        order by grouped.amount desc,grouped.reason)
      from (
        select reason,count(*) amount
        from jsonb_array_elements(v_candidates) item
        cross join lateral jsonb_array_elements_text(item.value->'reasons') reason
        group by reason
      ) grouped
    ),'[]'::jsonb)
  ) into v_summary
  from jsonb_array_elements(v_candidates) candidate;

  return jsonb_set(
    jsonb_set(v_payload,'{candidates}',v_candidates,true),
    '{summary}',v_summary,true
  );
end;
$$;


ALTER FUNCTION "public"."optimizer_variant_issue_diagnostics_before_capacity_context_uat"("p_variant_id" "uuid", "p_issue_id" bigint) OWNER TO "postgres";

--
-- Name: optimizer_variant_issue_diagnostics_before_primary_rules_uat_v2("uuid", bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_variant_issue_diagnostics_before_primary_rules_uat_v2"("p_variant_id" "uuid", "p_issue_id" bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_variant public.plan_variants_v2%rowtype;
  v_run public.optimization_runs_v2%rowtype;
  v_issue public.plan_issues_v2%rowtype;
  v_shift public.plan_shifts_v2%rowtype;
  v_shift_period text;
  v_timezone text;
  v_default_rest integer;
  v_default_missing boolean;
  v_summary jsonb;
  v_candidates jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into v_variant from public.plan_variants_v2 variant
  where variant.id=p_variant_id;
  if v_variant.id is null then raise exception 'VARIANT_NOT_FOUND'; end if;
  select * into v_run from public.optimization_runs_v2 run
  where run.id=v_variant.run_id;
  if v_run.id is null or not solver_private.can_access_run_v2(v_run.id) then
    raise exception 'VARIANT_NOT_FOUND';
  end if;
  select * into v_issue from public.plan_issues_v2 issue
  where issue.id=p_issue_id and issue.variant_id=p_variant_id
    and issue.issue_code='UNFILLED_SLOT';
  if v_issue.id is null then raise exception 'UNFILLED_ISSUE_NOT_FOUND'; end if;
  select * into v_shift from public.plan_shifts_v2 shift
  where shift.id=v_issue.shift_id;
  if v_shift.id is null then raise exception 'SHIFT_NOT_FOUND'; end if;
  select template.shift_period,location.timezone
  into v_shift_period,v_timezone
  from public.matrix_shift_templates_v2 template
  join public.matrix_locations_v2 location on location.id=template.location_id
  where template.id=v_shift.shift_template_id;
  select coalesce(
      (snapshot.snapshot->'settings'->>'minimumRestMinutes')::integer,
      (matrix.settings->>'minimumRestMinutes')::integer,660
    ),coalesce(
      (snapshot.snapshot->'settings'->>'missingAvailabilityMeansAvailable')::boolean,
      (matrix.settings->>'missingAvailabilityMeansAvailable')::boolean,true
    )
  into v_default_rest,v_default_missing
  from public.matrix_versions matrix
  left join solver_private.optimization_snapshots_v2 snapshot
    on snapshot.run_id=v_run.id
  where matrix.id=v_run.matrix_version_id;

  with scheduled as (
    select assignment.employee_id,shift.starts_at,shift.ends_at,shift.shift_date
    from public.plan_assignments_v2 assignment
    join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
    where assignment.variant_id=p_variant_id
  ), profiles as (
    select profile.*,coalesce(hr.contract_type,'INNE') contract_type,
      case when coalesce(hr.contract_type,'INNE') in ('ZLECENIE','B2B')
        and profile.work_time_policy<>'CUSTOM'
        then 0 else coalesce(profile.minimum_rest_minutes,v_default_rest) end rest_minutes
    from public.matrix_employee_profiles_v2 profile
    left join public.employee_hr_profiles hr on hr.employee_id=profile.employee_id
    where profile.matrix_version_id=v_run.matrix_version_id
      and profile.active and profile.archived_at is null
  ), evaluated as (
    select profile.*,
      exists(select 1 from public.matrix_employee_roles_v2 grant_row
        where grant_row.matrix_version_id=v_run.matrix_version_id
          and grant_row.employee_id=profile.employee_id
          and grant_row.role_id=v_issue.role_id and grant_row.active
          and (grant_row.valid_from is null or grant_row.valid_from<=v_shift.shift_date)
          and (grant_row.valid_to is null or grant_row.valid_to>=v_shift.shift_date)) role_ok,
      exists(select 1 from public.matrix_employee_locations_v2 grant_row
        where grant_row.matrix_version_id=v_run.matrix_version_id
          and grant_row.employee_id=profile.employee_id
          and grant_row.location_id=v_shift.location_id
          and grant_row.active and grant_row.standard_allowed
          and (grant_row.valid_from is null or grant_row.valid_from<=v_shift.shift_date)
          and (grant_row.valid_to is null or grant_row.valid_to>=v_shift.shift_date)) location_ok,
      v_issue.duty_id is null or exists(
        select 1 from public.matrix_employee_duties_v2 grant_row
        where grant_row.matrix_version_id=v_run.matrix_version_id
          and grant_row.employee_id=profile.employee_id
          and grant_row.duty_id=v_issue.duty_id and grant_row.active
          and (grant_row.role_id is null or grant_row.role_id=v_issue.role_id)
          and (grant_row.location_id is null or grant_row.location_id=v_shift.location_id)
          and (grant_row.valid_from is null or grant_row.valid_from<=v_shift.shift_date)
          and (grant_row.valid_to is null or grant_row.valid_to>=v_shift.shift_date)) duty_ok,
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
      exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=profile.employee_id
          and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind='AVAILABLE_WINDOW'
          and constraint_row.time_range && tstzrange(
            v_shift.shift_date::timestamp at time zone v_timezone,
            (v_shift.shift_date+1)::timestamp at time zone v_timezone,'[)')) has_day_window,
      exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=profile.employee_id
          and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind='AVAILABLE_WINDOW'
          and lower(constraint_row.time_range)<=v_shift.starts_at
          and upper(constraint_row.time_range)>=v_shift.ends_at) covers_window,
      coalesce((select sum(extract(epoch from
        (assignment.ends_at-assignment.starts_at))/60)::integer
        from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and assignment.shift_date>=v_run.month
          and assignment.shift_date<(v_run.month+interval '1 month')::date),0)
        monthly_minutes,
      coalesce((select sum(extract(epoch from
        (assignment.ends_at-assignment.starts_at))/60)::integer
        from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and assignment.shift_date>=date_trunc('week',v_shift.shift_date)::date
          and assignment.shift_date<date_trunc('week',v_shift.shift_date)::date+7),0)
        weekly_minutes,
      (select max(assignment.ends_at) from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and assignment.ends_at<=v_shift.starts_at) previous_end,
      (select min(assignment.starts_at) from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and assignment.starts_at>=v_shift.ends_at) next_start,
      coalesce((select min(day_offset.value)-1
        from generate_series(1,31) day_offset(value)
        where not exists(select 1 from scheduled assignment
          where assignment.employee_id=profile.employee_id
            and assignment.shift_date=v_shift.shift_date-day_offset.value)),31)
        consecutive_before,
      coalesce((select min(day_offset.value)-1
        from generate_series(1,31) day_offset(value)
        where not exists(select 1 from scheduled assignment
          where assignment.employee_id=profile.employee_id
            and assignment.shift_date=v_shift.shift_date+day_offset.value)),31)
        consecutive_after,
      coalesce(solver_private.alpha16_preference_level_v2(
        profile.employee_id,v_run.matrix_version_id,v_run.month,v_shift_period
      ),'NEUTRAL') preference_level
    from profiles profile
  ), classified as (
    select candidate.employee_id,candidate.employee_no,candidate.first_name,
      candidate.last_name,candidate.role_ok,candidate.location_ok,
      candidate.duty_ok,candidate.has_day_window,candidate.covers_window,
      array_remove(array[
        case when (candidate.employment_start is not null
          and candidate.employment_start>v_shift.shift_date)
          or (candidate.employment_end is not null
          and candidate.employment_end<v_shift.shift_date) then 'OUTSIDE_EMPLOYMENT' end,
        case when not candidate.role_ok then 'ROLE_REQUIRED' end,
        case when not candidate.location_ok then 'LOCATION_NOT_ALLOWED' end,
        case when not candidate.duty_ok then 'DUTY_REQUIRED' end,
        case when candidate.no_weekends and extract(isodow from v_shift.shift_date) in (6,7)
          then 'WEEKEND_BLOCKED' end,
        case when candidate.only_morning and v_shift_period<>'MORNING'
          or candidate.only_evening and v_shift_period<>'EVENING'
          or candidate.preference_level='BLOCKED' then 'MANAGER_SHIFT_BLOCK' end,
        case when candidate.blocked_time then 'DECLARED_UNAVAILABLE' end,
        case when candidate.has_day_window and not candidate.covers_window
          then 'OUTSIDE_AVAILABILITY_WINDOW' end,
        case when not candidate.has_day_window and not v_default_missing
          then 'MISSING_AVAILABILITY' end,
        case when candidate.overlap then 'SHIFT_OVERLAP' end,
        case when candidate.previous_end is not null and extract(epoch from
          (v_shift.starts_at-candidate.previous_end))/60<candidate.rest_minutes
          then 'REST_AFTER_PREVIOUS_SHIFT' end,
        case when candidate.next_start is not null and extract(epoch from
          (candidate.next_start-v_shift.ends_at))/60<candidate.rest_minutes
          then 'REST_BEFORE_NEXT_SHIFT' end,
        case when (candidate.contract_type not in ('ZLECENIE','B2B')
            or candidate.work_time_policy='CUSTOM')
          and candidate.monthly_minutes
            +extract(epoch from (v_shift.ends_at-v_shift.starts_at))/60
            >candidate.maximum_monthly_minutes then 'MONTHLY_LIMIT' end,
        case when (candidate.contract_type not in ('ZLECENIE','B2B')
            or candidate.work_time_policy='CUSTOM')
          and candidate.weekly_minutes
            +extract(epoch from (v_shift.ends_at-v_shift.starts_at))/60
            >candidate.maximum_weekly_minutes then 'WEEKLY_LIMIT' end,
        case when (candidate.contract_type not in ('ZLECENIE','B2B')
            or candidate.work_time_policy='CUSTOM')
          and candidate.consecutive_before+1+candidate.consecutive_after
            >candidate.maximum_consecutive_days then 'MAX_CONSECUTIVE_DAYS' end
      ]::text[],null) reasons
    from evaluated candidate
  )
  select jsonb_build_object(
      'considered',count(*),
      'eligible',count(*) filter(where cardinality(candidate.reasons)=0),
      'blocked',count(*) filter(where cardinality(candidate.reasons)>0),
      'reasons',coalesce((select jsonb_agg(jsonb_build_object(
        'code',reason_count.reason,'count',reason_count.amount
      ) order by reason_count.amount desc,reason_count.reason)
        from (select reason,count(*) amount
          from classified item
          cross join lateral unnest(item.reasons) reason
          group by reason) reason_count),'[]'::jsonb)
    ),
    coalesce(jsonb_agg(jsonb_build_object(
      'employeeId',candidate.employee_id,
      'employeeNo',candidate.employee_no,
      'employeeName',candidate.first_name||' '||candidate.last_name,
      'roleMatch',candidate.role_ok,
      'locationMatch',candidate.location_ok,
      'dutyMatch',candidate.duty_ok,
      'hasDeclaredWindow',candidate.has_day_window,
      'coversShift',candidate.covers_window,
      'reasons',to_jsonb(candidate.reasons)
    ) order by candidate.role_ok desc,candidate.location_ok desc,
      candidate.last_name,candidate.first_name),'[]'::jsonb)
  into v_summary,v_candidates
  from classified candidate;

  return jsonb_build_object(
    'variantId',p_variant_id,
    'issueId',p_issue_id,
    'shift',jsonb_build_object(
      'date',v_shift.shift_date,'startsAt',v_shift.starts_at,
      'endsAt',v_shift.ends_at,'shiftPeriod',v_shift_period
    ),
    'summary',v_summary,
    'candidates',v_candidates
  );
end;
$$;


ALTER FUNCTION "public"."optimizer_variant_issue_diagnostics_before_primary_rules_uat_v2"("p_variant_id" "uuid", "p_issue_id" bigint) OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_variant_issue_diagnostics_before_primary_rules_uat_v2"("p_variant_id" "uuid", "p_issue_id" bigint); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_variant_issue_diagnostics_before_primary_rules_uat_v2"("p_variant_id" "uuid", "p_issue_id" bigint) IS 'Explains every candidate for an unfilled slot using the same missing-availability default as the solver and returns role-matching employee details.';


--
-- Name: optimizer_variant_issue_diagnostics_before_profile_limits_uat_v("uuid", bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_variant_issue_diagnostics_before_profile_limits_uat_v"("p_variant_id" "uuid", "p_issue_id" bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_payload jsonb; v_shift public.plan_shifts_v2%rowtype;
  v_candidates jsonb:='[]'::jsonb; v_candidate jsonb; v_details jsonb;
begin
  v_payload:=public.optimizer_variant_issue_diagnostics_before_b4_details_uat_v2(p_variant_id,p_issue_id);
  select shift.* into v_shift from public.plan_issues_v2 issue
    join public.plan_shifts_v2 shift on shift.id=issue.shift_id
    where issue.id=p_issue_id and issue.variant_id=p_variant_id;
  for v_candidate in select candidate.value
    from jsonb_array_elements(coalesce(v_payload->'candidates','[]'::jsonb)) candidate(value)
  loop
    select coalesce(jsonb_agg(detail order by detail->>'startsAt'),'[]'::jsonb) into v_details from (
      select jsonb_build_object(
        'code','HARD_UNAVAILABLE',
        'label',case constraint_row.constraint_kind when 'LEAVE' then 'Urlop'
          when 'SICKNESS' then 'Zwolnienie lekarskie' else 'Twarda niedostępność' end,
        'startsAt',lower(constraint_row.time_range),'endsAt',upper(constraint_row.time_range),
        'note',constraint_row.note,'createdAt',constraint_row.created_at
      ) detail from public.employee_time_constraints_v2 constraint_row
      where constraint_row.employee_id=(v_candidate->>'employeeId')::uuid
        and constraint_row.status='ACTIVE'
        and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
        and constraint_row.time_range&&tstzrange(v_shift.starts_at,v_shift.ends_at,'[)')
      union all
      select jsonb_build_object(
        'code','DAILY_SHIFT_LIMIT','label','Ta osoba ma już przydział tego dnia',
        'shiftName',template.name,'locationName',location.name,
        'startsAt',other_shift.starts_at,'endsAt',other_shift.ends_at,'createdAt',other_assignment.created_at
      ) detail from public.plan_assignments_v2 other_assignment
      join public.plan_shifts_v2 other_shift on other_shift.id=other_assignment.shift_id
      join public.matrix_shift_templates_v2 template on template.id=other_shift.shift_template_id
      join public.matrix_locations_v2 location on location.id=other_shift.location_id
      where other_assignment.variant_id=p_variant_id
        and other_assignment.employee_id=(v_candidate->>'employeeId')::uuid
        and other_shift.shift_date=v_shift.shift_date and other_shift.id<>v_shift.id
    ) details;
    v_candidates:=v_candidates||jsonb_build_array(v_candidate||jsonb_build_object('blockingDetails',v_details));
  end loop;
  return jsonb_set(v_payload,'{candidates}',v_candidates,true);
end;
$$;


ALTER FUNCTION "public"."optimizer_variant_issue_diagnostics_before_profile_limits_uat_v"("p_variant_id" "uuid", "p_issue_id" bigint) OWNER TO "postgres";

--
-- Name: optimizer_variant_issue_diagnostics_before_role_scope_uat_v2("uuid", bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_variant_issue_diagnostics_before_role_scope_uat_v2"("p_variant_id" "uuid", "p_issue_id" bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_payload jsonb;
  v_candidates jsonb:='[]'::jsonb;
  v_candidate jsonb;
  v_reasons text[];
  v_extra text[];
  v_shift_id uuid;
  v_schedule_id uuid;
  v_summary jsonb;
begin
  v_payload:=public.optimizer_variant_issue_diagnostics_before_primary_rules_uat_v2(
    p_variant_id,p_issue_id
  );
  select issue.shift_id into v_shift_id
  from public.plan_issues_v2 issue
  where issue.id=p_issue_id and issue.variant_id=p_variant_id;
  select schedule.id into v_schedule_id
  from public.published_schedules_v2 schedule
  join public.published_schedule_variants_v2 link
    on link.schedule_id=schedule.id and link.variant_id=p_variant_id
  where schedule.status='PUBLISHED'
  order by schedule.published_at desc
  limit 1;

  for v_candidate in
    select candidate.value
    from jsonb_array_elements(coalesce(v_payload->'candidates','[]'::jsonb)) candidate
  loop
    select coalesce(array_agg(reason),array[]::text[]) into v_reasons
    from jsonb_array_elements_text(coalesce(v_candidate->'reasons','[]'::jsonb)) reason;
    v_extra:=solver_private.variant_primary_conflict_reasons_uat_v2(
      p_variant_id,(v_candidate->>'employeeId')::uuid,v_shift_id
    );
    if 'ONE_PRIMARY_SHIFT_PER_DAY'=any(v_extra) then
      v_reasons:=array_remove(v_reasons,'SHIFT_OVERLAP');
    end if;
    select coalesce(array_agg(distinct reason order by reason),array[]::text[])
    into v_reasons
    from unnest(v_reasons||v_extra) reason;
    v_candidate:=jsonb_set(v_candidate,'{reasons}',to_jsonb(v_reasons),true);
    v_candidates:=v_candidates||jsonb_build_array(v_candidate);
  end loop;

  select jsonb_build_object(
    'considered',jsonb_array_length(v_candidates),
    'eligible',count(*) filter(where jsonb_array_length(candidate.value->'reasons')=0),
    'blocked',count(*) filter(where jsonb_array_length(candidate.value->'reasons')>0),
    'reasons',coalesce((
      select jsonb_agg(jsonb_build_object('code',grouped.reason,'count',grouped.amount)
        order by grouped.amount desc,grouped.reason)
      from (
        select reason,count(*) amount
        from jsonb_array_elements(v_candidates) item
        cross join lateral jsonb_array_elements_text(item.value->'reasons') reason
        group by reason
      ) grouped
    ),'[]'::jsonb)
  ) into v_summary
  from jsonb_array_elements(v_candidates) candidate;

  return jsonb_set(
    jsonb_set(
      jsonb_set(v_payload,'{candidates}',v_candidates,true),
      '{summary}',v_summary,true
    ),
    '{publishedScheduleId}',coalesce(to_jsonb(v_schedule_id),'null'::jsonb),true
  );
end;
$$;


ALTER FUNCTION "public"."optimizer_variant_issue_diagnostics_before_role_scope_uat_v2"("p_variant_id" "uuid", "p_issue_id" bigint) OWNER TO "postgres";

--
-- Name: FUNCTION "optimizer_variant_issue_diagnostics_before_role_scope_uat_v2"("p_variant_id" "uuid", "p_issue_id" bigint); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."optimizer_variant_issue_diagnostics_before_role_scope_uat_v2"("p_variant_id" "uuid", "p_issue_id" bigint) IS 'Explains an unfilled variant slot with current hard assignment and published stand-by reasons; exposes an operational schedule only when a safe audited correction path exists.';


--
-- Name: optimizer_variant_issue_diagnostics_uat_v2("uuid", bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_variant_issue_diagnostics_uat_v2"("p_variant_id" "uuid", "p_issue_id" bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_payload jsonb; v_shift public.plan_shifts_v2%rowtype; v_matrix uuid; v_month date;
  v_duration integer; v_candidates jsonb:='[]'::jsonb; v_candidate jsonb; v_reasons text[];
  v_details jsonb; v_profile public.matrix_employee_profiles_v2%rowtype;
  v_monthly integer; v_weekly integer; v_daily integer; v_daily_limit integer; v_summary jsonb;
begin
  v_payload:=public.optimizer_variant_issue_diagnostics_before_profile_limits_uat_v2(p_variant_id,p_issue_id);
  select shift.* into v_shift
  from public.plan_issues_v2 issue
  join public.plan_shifts_v2 shift on shift.id=issue.shift_id
  join public.plan_variants_v2 variant on variant.id=issue.variant_id
  join public.optimization_runs_v2 run on run.id=variant.run_id
  where issue.id=p_issue_id and issue.variant_id=p_variant_id;
  if v_shift.id is null then raise exception 'UNFILLED_ISSUE_NOT_FOUND'; end if;
  select run.matrix_version_id,run.month into v_matrix,v_month
  from public.plan_variants_v2 variant
  join public.optimization_runs_v2 run on run.id=variant.run_id
  where variant.id=p_variant_id;
  v_duration:=extract(epoch from (v_shift.ends_at-v_shift.starts_at))/60;
  select greatest(1,coalesce(nullif(matrix.settings->>'maximumShiftsPerDay','')::integer,1))
    into v_daily_limit from public.matrix_versions matrix where matrix.id=v_matrix;

  for v_candidate in select candidate.value
    from jsonb_array_elements(coalesce(v_payload->'candidates','[]'::jsonb)) candidate(value)
  loop
    select * into v_profile from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=v_matrix
      and profile.employee_id=(v_candidate->>'employeeId')::uuid
      and profile.active and profile.archived_at is null;
    select coalesce(sum(extract(epoch from (shift.ends_at-shift.starts_at))/60),0)::integer,
      coalesce(sum(extract(epoch from (shift.ends_at-shift.starts_at))/60)
        filter(where shift.shift_date>=date_trunc('week',v_shift.shift_date)::date
          and shift.shift_date<date_trunc('week',v_shift.shift_date)::date+7),0)::integer,
      count(*) filter(where shift.shift_date=v_shift.shift_date)::integer
    into v_monthly,v_weekly,v_daily
    from public.plan_assignments_v2 assignment
    join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
    where assignment.variant_id=p_variant_id
      and assignment.employee_id=(v_candidate->>'employeeId')::uuid
      and shift.shift_date>=v_month and shift.shift_date<(v_month+interval '1 month')::date;
    select coalesce(array_agg(reason),array[]::text[]) into v_reasons
      from jsonb_array_elements_text(coalesce(v_candidate->'reasons','[]'::jsonb)) reason;
    if coalesce(v_profile.maximum_monthly_minutes,0)>0
      and v_monthly+v_duration>v_profile.maximum_monthly_minutes
      and not 'MONTHLY_LIMIT'=any(v_reasons) then v_reasons:=array_append(v_reasons,'MONTHLY_LIMIT'); end if;
    if coalesce(v_profile.maximum_weekly_minutes,0)>0
      and v_weekly+v_duration>v_profile.maximum_weekly_minutes
      and not 'WEEKLY_LIMIT'=any(v_reasons) then v_reasons:=array_append(v_reasons,'WEEKLY_LIMIT'); end if;
    select coalesce(jsonb_agg(detail.value),'[]'::jsonb) into v_details
    from jsonb_array_elements(coalesce(v_candidate->'blockingDetails','[]'::jsonb)) detail(value)
    where detail.value->>'code'<>'DAILY_SHIFT_LIMIT';
    if v_daily>=v_daily_limit then
      v_details:=v_details||jsonb_build_array(jsonb_build_object(
        'code','ONE_PRIMARY_SHIFT_PER_DAY','label',format(
          'Dzienny limit zmian: obecnie %s, limit %s',v_daily,v_daily_limit)));
    end if;
    if coalesce(v_profile.maximum_weekly_minutes,0)>0 and v_weekly+v_duration>v_profile.maximum_weekly_minutes then
      v_details:=v_details||jsonb_build_array(jsonb_build_object(
        'code','WEEKLY_LIMIT','label',format(
          'Limit tygodniowy: obecnie %s h + ta zmiana %s h = %s h, limit %s h',
          round(v_weekly/60.0,1),round(v_duration/60.0,1),round((v_weekly+v_duration)/60.0,1),
          round(v_profile.maximum_weekly_minutes/60.0,1))));
    end if;
    if coalesce(v_profile.maximum_monthly_minutes,0)>0 and v_monthly+v_duration>v_profile.maximum_monthly_minutes then
      v_details:=v_details||jsonb_build_array(jsonb_build_object(
        'code','MONTHLY_LIMIT','label',format(
          'Limit miesięczny: obecnie %s h + ta zmiana %s h = %s h, limit %s h',
          round(v_monthly/60.0,1),round(v_duration/60.0,1),round((v_monthly+v_duration)/60.0,1),
          round(v_profile.maximum_monthly_minutes/60.0,1))));
    end if;
    select coalesce(array_agg(distinct reason order by reason),array[]::text[]) into v_reasons
      from unnest(v_reasons) reason;
    v_candidate:=jsonb_set(v_candidate,'{reasons}',to_jsonb(v_reasons),true);
    v_candidate:=jsonb_set(v_candidate,'{blockingDetails}',v_details,true);
    v_candidates:=v_candidates||jsonb_build_array(v_candidate);
  end loop;
  select jsonb_build_object(
    'considered',jsonb_array_length(v_candidates),
    'eligible',count(*) filter(where jsonb_array_length(candidate.value->'reasons')=0),
    'blocked',count(*) filter(where jsonb_array_length(candidate.value->'reasons')>0),
    'reasons',coalesce((select jsonb_agg(jsonb_build_object('code',grouped.reason,'count',grouped.amount)
      order by grouped.amount desc,grouped.reason) from (
        select reason,count(*) amount from jsonb_array_elements(v_candidates) item
        cross join lateral jsonb_array_elements_text(item.value->'reasons') reason group by reason
      ) grouped),'[]'::jsonb)
  ) into v_summary from jsonb_array_elements(v_candidates) candidate;
  v_payload:=jsonb_set(jsonb_set(v_payload,'{candidates}',v_candidates,true),'{summary}',v_summary,true);
  if coalesce((v_summary->>'eligible')::integer,0)=0 then
    v_payload:=jsonb_set(v_payload,'{decisionContext}','null'::jsonb,true);
  end if;
  return v_payload;
end;
$$;


ALTER FUNCTION "public"."optimizer_variant_issue_diagnostics_uat_v2"("p_variant_id" "uuid", "p_issue_id" bigint) OWNER TO "postgres";

--
-- Name: optimizer_variant_standby_preview_before_shortage_guard_uat_v1("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_variant_standby_preview_before_shortage_guard_uat_v1"("p_variant_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_matrix uuid; v_scope text; v_tiers integer:=0; v_month date; v_role_day record;
  v_tier integer; v_candidate record; v_counts jsonb:='{}'::jsonb; v_tier_counts jsonb:='{}'::jsonb;
  v_selected jsonb:='{}'::jsonb; v_result jsonb:='[]'::jsonb; v_key text;
begin
  select run.matrix_version_id,run.scope_type,run.month,
    greatest(0,least(2,coalesce((matrix.settings->>'standbyTiersPerRoleDay')::integer,2)))
  into v_matrix,v_scope,v_month,v_tiers
  from public.plan_variants_v2 variant join public.optimization_runs_v2 run on run.id=variant.run_id
  join public.matrix_versions matrix on matrix.id=run.matrix_version_id where variant.id=p_variant_id;
  if v_matrix is null then raise exception 'VARIANT_NOT_FOUND'; end if;
  if auth.uid() is null or not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or (v_scope='ROLE' and exists(select 1 from public.matrix_scope_grants_v2 grant_row
      join public.optimization_runs_v2 run on run.scope_role_id is not null
      join public.matrix_roles_v2 role on role.id=run.scope_role_id
      join public.plan_variants_v2 variant on variant.run_id=run.id
      where variant.id=p_variant_id and grant_row.auth_user_id=auth.uid() and grant_row.active
        and grant_row.app_role='ROLE_MANAGER'
        and (grant_row.role_logical_id is null or grant_row.role_logical_id=role.logical_id))))
    then raise exception 'VARIANT_NOT_AVAILABLE'; end if;
  if v_tiers=0 then return v_result; end if;
  for v_role_day in select source.shift_date,source.role_id,role.name role_name,role.sort_order
    from (select distinct shift.shift_date,assignment.role_id from public.plan_assignments_v2 assignment
      join public.plan_shifts_v2 shift on shift.id=assignment.shift_id where assignment.variant_id=p_variant_id
      union select distinct shift.shift_date,issue.role_id from public.plan_issues_v2 issue
      join public.plan_shifts_v2 shift on shift.id=issue.shift_id
      where issue.variant_id=p_variant_id and issue.role_id is not null) source
    join public.matrix_roles_v2 role on role.id=source.role_id
    order by source.shift_date,role.sort_order,role.id
  loop
    for v_tier in 1..v_tiers loop
      if v_tier=2 and exists(select 1 from public.plan_issues_v2 issue
        join public.plan_shifts_v2 shift on shift.id=issue.shift_id
        where issue.variant_id=p_variant_id and issue.role_id=v_role_day.role_id
          and issue.issue_code='UNFILLED_SLOT' and shift.shift_date=v_role_day.shift_date) then continue; end if;
      v_candidate:=null;
      select candidate.employee_id,candidate.employee_no,employee.first_name,employee.last_name
      into v_candidate from solver_private.standby_candidates_for_role_day_uat_v3(
        p_variant_id,v_matrix,v_month,v_role_day.role_id,v_role_day.shift_date) candidate
      join public.employees employee on employee.id=candidate.employee_id
      where not coalesce((v_selected->>(v_role_day.shift_date::text||':'||candidate.employee_id::text))::boolean,false)
      order by coalesce((v_tier_counts->>(v_role_day.role_id::text||':'||v_tier::text||':'||candidate.employee_id::text))::integer,0),
        coalesce((v_counts->>(v_role_day.role_id::text||':'||candidate.employee_id::text))::integer,0),
        candidate.employee_no,candidate.employee_id limit 1;
      if v_candidate.employee_id is null then exit; end if;
      v_key:=v_role_day.role_id::text||':'||v_candidate.employee_id::text;
      v_counts:=jsonb_set(v_counts,array[v_key],to_jsonb(coalesce((v_counts->>v_key)::integer,0)+1),true);
      v_key:=v_role_day.role_id::text||':'||v_tier::text||':'||v_candidate.employee_id::text;
      v_tier_counts:=jsonb_set(v_tier_counts,array[v_key],to_jsonb(coalesce((v_tier_counts->>v_key)::integer,0)+1),true);
      v_selected:=jsonb_set(v_selected,array[v_role_day.shift_date::text||':'||v_candidate.employee_id::text],'true'::jsonb,true);
      v_result:=v_result||jsonb_build_array(jsonb_build_object(
        'id',md5(p_variant_id::text||v_role_day.shift_date::text||v_role_day.role_id::text||v_tier::text),
        'date',v_role_day.shift_date,'tier',v_tier,'status','PREVIEW','roleId',v_role_day.role_id,
        'roleName',v_role_day.role_name,'employeeId',v_candidate.employee_id,'employeeNo',v_candidate.employee_no,
        'employeeName',trim(v_candidate.first_name||' '||v_candidate.last_name),
        'sourceType',case when v_scope='ROLE' then 'ROLE' else 'COMPANY' end,'activatedShiftId',null));
    end loop;
  end loop;
  return v_result;
end;
$$;


ALTER FUNCTION "public"."optimizer_variant_standby_preview_before_shortage_guard_uat_v1"("p_variant_id" "uuid") OWNER TO "postgres";

--
-- Name: optimizer_variant_standby_preview_uat_v1("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_variant_standby_preview_uat_v1"("p_variant_id" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select coalesce(jsonb_agg(item.value order by item.ordinality),'[]'::jsonb)
  from jsonb_array_elements(public.optimizer_variant_standby_preview_before_shortage_guard_uat_v1(p_variant_id))
    with ordinality item(value,ordinality)
  where not exists(
    select 1 from public.plan_issues_v2 issue
    join public.plan_shifts_v2 shift_row on shift_row.id=issue.shift_id
    where issue.variant_id=p_variant_id and issue.role_id=(item.value->>'roleId')::uuid
      and issue.issue_code='UNFILLED_SLOT' and shift_row.shift_date=(item.value->>'date')::date
  );
$$;


ALTER FUNCTION "public"."optimizer_variant_standby_preview_uat_v1"("p_variant_id" "uuid") OWNER TO "postgres";

--
-- Name: optimizer_variant_standby_preview_uat_v2("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_variant_standby_preview_uat_v2"("p_variant_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_matrix uuid;
  v_scope text;
  v_month date;
  v_groups jsonb;
  v_group jsonb;
  v_role_ids uuid[];
  v_canonical uuid;
  v_date date;
  v_tier integer;
  v_candidate record;
  v_counts jsonb := '{}'::jsonb;
  v_selected jsonb := '{}'::jsonb;
  v_result jsonb := '[]'::jsonb;
  v_key text;
  v_role_names jsonb;
begin
  select
    run.matrix_version_id,
    run.scope_type,
    run.month,
    coalesce(matrix.settings->'standbyGroups', '[]'::jsonb)
  into v_matrix, v_scope, v_month, v_groups
  from public.plan_variants_v2 variant
  join public.optimization_runs_v2 run on run.id = variant.run_id
  join public.matrix_versions matrix on matrix.id = run.matrix_version_id
  where variant.id = p_variant_id;

  if v_matrix is null then
    raise exception 'VARIANT_NOT_FOUND';
  end if;
  if auth.uid() is null
    or not solver_private.can_access_run_v2((
      select run_id from public.plan_variants_v2 where id = p_variant_id
    )) then
    raise exception 'VARIANT_NOT_AVAILABLE';
  end if;

  for v_group in select value from jsonb_array_elements(v_groups) loop
    select array_agg(role_row.id order by role_code.ordinality)
    into v_role_ids
    from jsonb_array_elements_text(v_group->'roleCodes')
      with ordinality role_code(value, ordinality)
    join public.matrix_roles_v2 role_row
      on role_row.matrix_version_id = v_matrix
      and role_row.active
      and upper(role_row.code) = upper(role_code.value);

    v_canonical := v_role_ids[1];
    if not exists(
      select 1
      from public.plan_assignments_v2
      where variant_id = p_variant_id and role_id = any(v_role_ids)
      union all
      select 1
      from public.plan_issues_v2
      where variant_id = p_variant_id and role_id = any(v_role_ids)
    ) then
      continue;
    end if;

    for v_date in
      select distinct source.shift_date
      from (
        select shift_row.shift_date
        from public.plan_assignments_v2 assignment
        join public.plan_shifts_v2 shift_row on shift_row.id = assignment.shift_id
        where assignment.variant_id = p_variant_id
          and assignment.role_id = any(v_role_ids)
        union
        select shift_row.shift_date
        from public.plan_issues_v2 issue
        join public.plan_shifts_v2 shift_row on shift_row.id = issue.shift_id
        where issue.variant_id = p_variant_id
          and issue.role_id = any(v_role_ids)
      ) source
      order by source.shift_date
    loop
      if exists(
        select 1
        from public.plan_issues_v2 issue
        join public.plan_shifts_v2 shift_row on shift_row.id = issue.shift_id
        where issue.variant_id = p_variant_id
          and issue.role_id = any(v_role_ids)
          and issue.issue_code = 'UNFILLED_SLOT'
          and shift_row.shift_date = v_date
      ) then
        continue;
      end if;

      for v_tier in 1..least(2, greatest(1, (v_group->>'tiers')::integer)) loop
        v_candidate := null;
        select
          candidate.employee_id,
          candidate.employee_no,
          candidate.eligible_role_ids,
          employee.first_name,
          employee.last_name
        into v_candidate
        from solver_private.standby_candidates_for_group_day_uat_v1(
          p_variant_id,
          v_matrix,
          v_month,
          v_role_ids,
          v_date
        ) candidate
        join public.employees employee on employee.id = candidate.employee_id
        where not coalesce(
          (v_selected->>(v_date::text || ':' || candidate.employee_id::text))::boolean,
          false
        )
        order by
          coalesce((v_counts->>((v_group->>'code') || ':' || candidate.employee_id::text))::integer, 0),
          candidate.employee_no,
          candidate.employee_id
        limit 1;

        if v_candidate.employee_id is null then
          exit;
        end if;

        select coalesce(
          jsonb_agg(role_row.name order by role_row.sort_order, role_row.name),
          '[]'::jsonb
        )
        into v_role_names
        from public.matrix_roles_v2 role_row
        where role_row.id = any(v_candidate.eligible_role_ids);

        v_key := (v_group->>'code') || ':' || v_candidate.employee_id::text;
        v_counts := jsonb_set(
          v_counts,
          array[v_key],
          to_jsonb(coalesce((v_counts->>v_key)::integer, 0) + 1),
          true
        );
        v_selected := jsonb_set(
          v_selected,
          array[v_date::text || ':' || v_candidate.employee_id::text],
          'true'::jsonb,
          true
        );
        v_result := v_result || jsonb_build_array(jsonb_build_object(
          'id', md5(p_variant_id::text || v_date::text || (v_group->>'code') || v_tier::text),
          'date', v_date,
          'tier', v_tier,
          'status', 'PREVIEW',
          'roleId', v_canonical,
          'roleName', v_group->>'name',
          'groupCode', v_group->>'code',
          'groupName', v_group->>'name',
          'eligibleRoleIds', to_jsonb(v_candidate.eligible_role_ids),
          'eligibleRoleNames', v_role_names,
          'employeeId', v_candidate.employee_id,
          'employeeNo', v_candidate.employee_no,
          'employeeName', trim(v_candidate.first_name || ' ' || v_candidate.last_name),
          'sourceType', case when v_scope = 'ROLE' then 'ROLE' else 'COMPANY' end,
          'activatedShiftId', null
        ));
      end loop;
    end loop;
  end loop;

  return v_result;
end;
$$;


ALTER FUNCTION "public"."optimizer_variant_standby_preview_uat_v2"("p_variant_id" "uuid") OWNER TO "postgres";

--
-- Name: optimizer_variant_workload_distribution_uat_v1("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_variant_workload_distribution_uat_v1"("p_variant_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_run public.optimization_runs_v2%rowtype;
  v_scope_category uuid;
  v_timezone text;
  v_snapshot jsonb;
  v_variant_revision integer;
  v_finance_visibility text;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;

  select run.* into v_run
  from public.plan_variants_v2 variant
  join public.optimization_runs_v2 run on run.id=variant.run_id
  where variant.id=p_variant_id;
  if v_run.id is null or not solver_private.can_access_run_v2(v_run.id) then
    raise exception 'VARIANT_NOT_FOUND';
  end if;

  select variant.revision into v_variant_revision
  from public.plan_variants_v2 variant where variant.id=p_variant_id;
  select snapshot.snapshot into v_snapshot
  from solver_private.optimization_snapshots_v2 snapshot
  where snapshot.run_id=v_run.id;
  if v_snapshot is null then raise exception 'SNAPSHOT_NOT_FOUND'; end if;

  select coalesce(nullif(version.settings->>'timezone',''),'Europe/Warsaw')
    into v_timezone
  from public.matrix_versions version
  where version.id=v_run.matrix_version_id;
  v_finance_visibility:=public.application_finance_visibility_current_uat_v1();

  if v_run.scope_type='ROLE' and v_run.scope_role_id is not null then
    select role.category_id into v_scope_category
    from public.matrix_roles_v2 role
    where role.id=v_run.scope_role_id
      and role.matrix_version_id=v_run.matrix_version_id;
  end if;

  with roster as (
    select profile.employee_id,profile.employee_no,profile.first_name,profile.last_name,
      profile.nominal_monthly_minutes,profile.maximum_monthly_minutes,
      array_agg(distinct role.name order by role.name) role_names,
      coalesce((select array_agg(distinct location_grant.location_id order by location_grant.location_id)
        from public.matrix_employee_locations_v2 location_grant
        where location_grant.matrix_version_id=profile.matrix_version_id
          and location_grant.employee_id=profile.employee_id
          and location_grant.active and location_grant.standard_allowed),'{}'::uuid[]) eligible_location_ids
    from public.matrix_employee_profiles_v2 profile
    join public.matrix_employee_roles_v2 employee_role
      on employee_role.matrix_version_id=profile.matrix_version_id
     and employee_role.employee_id=profile.employee_id and employee_role.active
     and (employee_role.valid_from is null or employee_role.valid_from<(v_run.month+interval '1 month')::date)
     and (employee_role.valid_to is null or employee_role.valid_to>=v_run.month)
    join public.matrix_roles_v2 role on role.id=employee_role.role_id
    where profile.matrix_version_id=v_run.matrix_version_id
      and profile.active and profile.archived_at is null
      and (profile.employment_start is null or profile.employment_start<(v_run.month+interval '1 month')::date)
      and (profile.employment_end is null or profile.employment_end>=v_run.month)
      and (
        v_run.scope_type<>'ROLE'
        or (v_scope_category is not null and role.category_id=v_scope_category)
        or (v_scope_category is null and employee_role.role_id=v_run.scope_role_id)
      )
    group by profile.employee_id,profile.employee_no,profile.first_name,profile.last_name,
      profile.nominal_monthly_minutes,profile.maximum_monthly_minutes,profile.matrix_version_id
  ), snapshot_employees as (
    select employee.value employee
    from jsonb_array_elements(coalesce(v_snapshot->'employees','[]'::jsonb)) employee
  ), snapshot_slots as (
    select slot.value slot
    from jsonb_array_elements(coalesce(v_snapshot->'slots','[]'::jsonb)) slot
  ), assignment_source as (
    select assignment.id,assignment.employee_id,assignment.role_id,shift_row.location_id,
      extract(epoch from (shift_row.ends_at-shift_row.starts_at))/60 planned_minutes,
      coalesce(cost.cost_minor,0) cost_minor,
      employee.employee,slot.slot,
      (slot.slot->>'date')::date slot_date,
      (extract(epoch from (((slot.slot->>'start')::timestamptz at time zone v_timezone)::time))/60)::integer slot_start_minute,
      (extract(epoch from (((slot.slot->>'end')::timestamptz at time zone v_timezone)::time))/60)::integer
        + case when ((slot.slot->>'end')::timestamptz at time zone v_timezone)::date
          > ((slot.slot->>'start')::timestamptz at time zone v_timezone)::date then 1440 else 0 end slot_end_minute
    from public.plan_assignments_v2 assignment
    join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
    join snapshot_employees employee on employee.employee->>'id'=assignment.employee_id::text
    join snapshot_slots slot on slot.slot->>'slotId'=assignment.slot_key
    left join lateral (
      select coalesce(sum(component.amount_minor),0)::bigint cost_minor
      from solver_private.plan_assignment_cost_components_v2 component
      where component.assignment_id=assignment.id
    ) cost on true
    where assignment.variant_id=p_variant_id
  ), assignment_detail as (
    select source.*,
      (
        case when jsonb_array_length(coalesce(source.employee->'preferredShiftTemplateIds','[]'::jsonb))>0
          and not (coalesce(source.employee->'preferredShiftTemplateIds','[]'::jsonb) ? (source.slot->>'shiftTemplateId')) then 1 else 0 end
        + case when coalesce(source.employee->'avoidedShiftTemplateIds','[]'::jsonb) ? (source.slot->>'shiftTemplateId') then 1 else 0 end
        + case when jsonb_array_length(coalesce(source.employee->'preferredLocationIds','[]'::jsonb))>0
          and not (coalesce(source.employee->'preferredLocationIds','[]'::jsonb) ? (source.slot->>'locationId')) then 1 else 0 end
        + case when coalesce(source.employee->'softDayOffDates','[]'::jsonb) ? (source.slot->>'date') then 1 else 0 end
        + case when exists(
            select 1 from jsonb_array_elements(coalesce(v_snapshot->'workPatterns','[]'::jsonb)) pattern
            where pattern.value->>'employeeId'=source.employee_id::text
              and upper(coalesce(pattern.value->>'enforcement',''))='PREFERENCE'
              and (pattern.value->>'validFrom')::date<=source.slot_date
              and (nullif(pattern.value->>'validTo','') is null or (pattern.value->>'validTo')::date>=source.slot_date)
          ) and not exists(
            select 1 from jsonb_array_elements(coalesce(v_snapshot->'workPatterns','[]'::jsonb)) pattern
            where pattern.value->>'employeeId'=source.employee_id::text
              and upper(coalesce(pattern.value->>'enforcement',''))='PREFERENCE'
              and (pattern.value->>'validFrom')::date<=source.slot_date
              and (nullif(pattern.value->>'validTo','') is null or (pattern.value->>'validTo')::date>=source.slot_date)
              and (pattern.value->>'weekday')::integer=extract(isodow from source.slot_date)::integer
              and (nullif(pattern.value->>'roleId','') is null or (pattern.value->>'roleId')::uuid=source.role_id)
              and (nullif(pattern.value->>'locationId','') is null or (pattern.value->>'locationId')::uuid=source.location_id)
              and (extract(epoch from (pattern.value->>'localStart')::time)/60)::integer<=source.slot_start_minute
              and source.slot_end_minute<=
                (extract(epoch from (pattern.value->>'localEnd')::time)/60)::integer
                + case when (pattern.value->>'localEnd')::time<=(pattern.value->>'localStart')::time then 1440 else 0 end
          ) then 1 else 0 end
      )::integer preference_violations
    from assignment_source source
  ), assignment_stats as (
    select detail.employee_id,count(distinct detail.id)::integer shift_count,
      coalesce(sum(detail.planned_minutes),0)::integer planned_minutes,
      coalesce(sum(detail.cost_minor),0)::bigint cost_minor,
      coalesce(sum(detail.preference_violations),0)::integer preference_violations
    from assignment_detail detail group by detail.employee_id
  ), external_stats as (
    select (external.value->>'employeeId')::uuid employee_id,
      coalesce(sum(extract(epoch from ((external.value->>'end')::timestamptz-(external.value->>'start')::timestamptz))/60),0)::integer external_minutes
    from jsonb_array_elements(coalesce(v_snapshot->'externalAssignments','[]'::jsonb)) external
    where (((external.value->>'start')::timestamptz at time zone v_timezone)::date
      between v_run.month and (v_run.month+interval '1 month'-interval '1 day')::date)
    group by (external.value->>'employeeId')::uuid
  ), availability as (
    select roster.employee_id,
      coalesce((select count(distinct unavailable_day.day)::integer
        from public.employee_time_constraints_v2 constraint_row
        cross join lateral generate_series(
          greatest((lower(constraint_row.time_range) at time zone v_timezone)::date,v_run.month),
          least(((upper(constraint_row.time_range)-interval '1 microsecond') at time zone v_timezone)::date,
            (v_run.month+interval '1 month'-interval '1 day')::date),interval '1 day'
        ) unavailable_day(day)
        where constraint_row.employee_id=roster.employee_id
          and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
          and constraint_row.time_range&&tstzrange(v_run.month::timestamp at time zone v_timezone,
            (v_run.month+interval '1 month')::timestamp at time zone v_timezone,'[)')),0) hard_unavailable_days,
      coalesce((select count(distinct (lower(constraint_row.time_range) at time zone v_timezone)::date)::integer
        from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=roster.employee_id
          and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind='AVAILABLE_WINDOW'
          and constraint_row.time_range&&tstzrange(v_run.month::timestamp at time zone v_timezone,
            (v_run.month+interval '1 month')::timestamp at time zone v_timezone,'[)')),0) available_window_days
    from roster
  )
  select jsonb_build_object('variantId',p_variant_id,'revision',coalesce(v_variant_revision,0),'employees',coalesce(jsonb_agg(
    jsonb_build_object(
      'employeeId',roster.employee_id,'employeeNo',roster.employee_no,
      'employeeName',roster.first_name||' '||roster.last_name,
      'roleNames',to_jsonb(roster.role_names),
      'eligibleLocationIds',to_jsonb(roster.eligible_location_ids),
      'plannedMinutes',coalesce(stats.planned_minutes,0),
      'externalMinutes',coalesce(external.external_minutes,0),
      'totalMonthlyMinutes',coalesce(stats.planned_minutes,0)+coalesce(external.external_minutes,0),
      'overtimeMinutes',case when roster.nominal_monthly_minutes is null then 0 else
        greatest(0,coalesce(stats.planned_minutes,0)+coalesce(external.external_minutes,0)-roster.nominal_monthly_minutes) end,
      'shiftCount',coalesce(stats.shift_count,0),
      'nominalMonthlyMinutes',coalesce(roster.nominal_monthly_minutes,0),
      'maximumMonthlyMinutes',coalesce(roster.maximum_monthly_minutes,0),
      'differenceMinutes',coalesce(stats.planned_minutes,0)+coalesce(external.external_minutes,0)-coalesce(roster.nominal_monthly_minutes,0),
      'hardUnavailableDays',availability.hard_unavailable_days,
      'availableWindowDays',availability.available_window_days,
      'preferenceViolations',coalesce(stats.preference_violations,0),
      'costMinor',case when v_finance_visibility='FULL' then coalesce(stats.cost_minor,0) else null end,
      'assignmentImpacts',coalesce((select jsonb_agg(jsonb_build_object(
          'roleId',detail.role_id,'locationId',detail.location_id,
          'plannedMinutes',detail.planned_minutes,
          'costMinor',case when v_finance_visibility='FULL' then detail.cost_minor else null end,
          'preferenceViolations',detail.preference_violations
        ) order by detail.id)
        from assignment_detail detail where detail.employee_id=roster.employee_id),'[]'::jsonb),
      'reasonCode',case
        when coalesce(roster.nominal_monthly_minutes,0)=0 then 'TARGET_NOT_SET'
        when coalesce(roster.maximum_monthly_minutes,0)>0
          and coalesce(stats.planned_minutes,0)+coalesce(external.external_minutes,0)>=roster.maximum_monthly_minutes then 'MAXIMUM_REACHED'
        when coalesce(stats.planned_minutes,0)+coalesce(external.external_minutes,0)<roster.nominal_monthly_minutes
          and availability.hard_unavailable_days>0 then 'AVAILABILITY_LIMITED'
        when coalesce(stats.planned_minutes,0)+coalesce(external.external_minutes,0)<roster.nominal_monthly_minutes
          and availability.available_window_days>0 then 'AVAILABILITY_WINDOW_LIMITED'
        when coalesce(stats.planned_minutes,0)+coalesce(external.external_minutes,0)<roster.nominal_monthly_minutes then 'SOLVER_DISTRIBUTION'
        when coalesce(stats.planned_minutes,0)+coalesce(external.external_minutes,0)>roster.nominal_monthly_minutes then 'ABOVE_NOMINAL'
        else 'ON_TARGET' end,
      'locations',coalesce((select jsonb_agg(jsonb_build_object(
          'id',location.id,'name',location.name,'minutes',location_assignment.minutes,
          'shiftCount',location_assignment.shift_count
        ) order by location.name)
        from (
          select shift_row.location_id,count(distinct assignment.id)::integer shift_count,
            sum(extract(epoch from (shift_row.ends_at-shift_row.starts_at))/60)::integer minutes
          from public.plan_assignments_v2 assignment
          join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
          where assignment.variant_id=p_variant_id and assignment.employee_id=roster.employee_id
          group by shift_row.location_id
        ) location_assignment
        join public.matrix_locations_v2 location on location.id=location_assignment.location_id
      ),'[]'::jsonb)
    ) order by coalesce(stats.planned_minutes,0)+coalesce(external.external_minutes,0) desc,roster.last_name,roster.first_name
  ),'[]'::jsonb)) into v_result
  from roster
  left join assignment_stats stats on stats.employee_id=roster.employee_id
  left join external_stats external on external.employee_id=roster.employee_id
  join availability on availability.employee_id=roster.employee_id;
  return v_result;
end;
$$;


ALTER FUNCTION "public"."optimizer_variant_workload_distribution_uat_v1"("p_variant_id" "uuid") OWNER TO "postgres";

--
-- Name: optimizer_variant_workspace_uat_v2("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_variant_workspace_uat_v2"("p_variant_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_run uuid; v_context jsonb; v_workspace jsonb; v_visibility text;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select run.id,jsonb_build_object('type','VARIANT_PREVIEW','runId',run.id,
    'engine',run.request_engine,'requestEngine',run.request_engine,'month',run.month,
    'name',variant.name,'scenario',jsonb_build_object('id',scenario.id,'name',scenario.name),
    'matrixVersionId',run.matrix_version_id)
  into v_run,v_context from public.plan_variants_v2 variant
  join public.optimization_runs_v2 run on run.id=variant.run_id
  join public.matrix_scenarios_v2 scenario on scenario.id=run.scenario_id
  where variant.id=p_variant_id;
  if v_run is null or not solver_private.can_access_run_v2(v_run) then raise exception 'VARIANT_NOT_FOUND'; end if;
  v_visibility:=public.application_finance_visibility_current_uat_v1();
  v_workspace:=solver_private.variant_set_workspace_v2(array[p_variant_id],v_context,v_visibility<>'NONE');
  v_workspace:=solver_private.alpha16_enrich_workspace_issues_v2(v_workspace,array[p_variant_id]);
  return solver_private.redact_workspace_finance_uat_v1(v_workspace,v_visibility);
end;
$$;


ALTER FUNCTION "public"."optimizer_variant_workspace_uat_v2"("p_variant_id" "uuid") OWNER TO "postgres";

--
-- Name: optimizer_variants_before_b4f52_uat_v1("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_variants_before_b4f52_uat_v1"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  with latest_run as (
    select r.id from public.optimization_runs r
    where r.month=date_trunc('month',p_month)::date
      and r.status in ('SUCCEEDED','INFEASIBLE')
      and exists(select 1 from public.optimization_candidates c
        where c.run_id=r.id and c.plan_id is not null)
    order by r.finished_at desc nulls last,r.created_at desc limit 1
  )
  select case when not public.can_manage_plans() then '[]'::jsonb else coalesce(jsonb_agg(
    jsonb_build_object(
      'candidateId',c.id,'runId',c.run_id,'planId',c.plan_id,'rank',c.rank,
      'score',c.score,'hardViolations',c.hard_violations,'metrics',c.metrics,
      'selected',c.selected,
      'assignmentCount',jsonb_array_length(c.assignments)
    ) order by c.rank
  ),'[]'::jsonb) end
  from public.optimization_candidates c
  where c.run_id=(select id from latest_run);
$$;


ALTER FUNCTION "public"."optimizer_variants_before_b4f52_uat_v1"("p_month" "date") OWNER TO "postgres";

--
-- Name: optimizer_variants_v2("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_variants_v2"("p_run_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_visibility text; v_variants jsonb;
begin
  if not solver_private.can_access_run_v2(p_run_id) then raise exception 'RUN_NOT_FOUND'; end if;
  v_visibility:=public.application_finance_visibility_current_uat_v1();
  select coalesce(jsonb_agg(
    case
      when v_visibility in ('FULL','AGGREGATE') then item
      when v_visibility='BUDGET_ONLY' then
        item-'totalCostMinor'-'budgetMinor'-'currency'||jsonb_build_object('budgetStatus',jsonb_build_object(
          'configured',item->'budgetMinor' is not null and jsonb_typeof(item->'budgetMinor')<>'null',
          'withinBudget',case when item->'budgetMinor' is null or jsonb_typeof(item->'budgetMinor')='null' then null
            else (item->>'totalCostMinor')::numeric <= (item->>'budgetMinor')::numeric end))
      else item-'totalCostMinor'-'budgetMinor'-'currency'
    end order by ordinal
  ),'[]'::jsonb) into v_variants
  from (
    select run_strategy.ordinal,jsonb_build_object(
      'id',variant.id,'name',variant.name,
      'strategy',jsonb_build_object('id',strategy.id,'name',strategy.name,'description',strategy.description),
      'status',variant.status,'hardViolations',variant.hard_violations,
      'assignmentCount',variant.assignment_count,'unfilledCount',variant.unfilled_count,
      'totalCostMinor',finance.total_cost_minor,'budgetMinor',finance.budget_minor,'currency',finance.currency,
      'solverStatus',variant.solver_status,'recommended',variant.recommended,'selected',variant.selected,
      'equivalentToVariantId',variant.equivalent_to_variant_id,'metrics',variant.metrics,
      'stageProof',variant.stage_proof,'versionStamp',variant.version_stamp) item
    from public.plan_variants_v2 variant
    join public.optimization_run_strategies_v2 run_strategy on run_strategy.id=variant.run_strategy_id
    join public.matrix_strategies_v2 strategy on strategy.id=variant.strategy_id
    left join solver_private.plan_variant_finance_v2 finance on finance.variant_id=variant.id
    where variant.run_id=p_run_id and variant.variant_kind='GENERATED'
  ) source;
  return jsonb_build_object('runId',p_run_id,'variants',v_variants);
end;
$$;


ALTER FUNCTION "public"."optimizer_variants_v2"("p_run_id" "uuid") OWNER TO "postgres";

--
-- Name: optimizer_variants_v3("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."optimizer_variants_v3"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_payload jsonb:=public.optimizer_variants_before_b4f52_uat_v1(p_month);
  v_visibility text:=public.application_finance_visibility_current_uat_v1();
  v_variant jsonb;
  v_variants jsonb:='[]'::jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if v_visibility in ('FULL','AGGREGATE') then return v_payload; end if;
  for v_variant in select value from jsonb_array_elements(coalesce(v_payload,'[]'::jsonb)) loop
    v_variants:=v_variants||jsonb_build_array(v_variant-'score'-'metrics');
  end loop;
  return v_variants;
end;
$$;


ALTER FUNCTION "public"."optimizer_variants_v3"("p_month" "date") OWNER TO "postgres";

--
-- Name: personal_action_workspace_uat_v1(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."personal_action_workspace_uat_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid();
  v_result jsonb;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select jsonb_build_object(
    'unreadCount',(select count(*) from public.notifications notification
      where notification.recipient_id=v_actor and notification.read_at is null),
    'actionCount',(select count(*) from public.notifications notification
      where notification.recipient_id=v_actor and notification.action_required
        and notification.resolved_at is null),
    'notifications',coalesce((select jsonb_agg(jsonb_build_object(
      'id',notification.id,'kind',notification.kind,'title',notification.title,
      'body',notification.body,'actionRoute',notification.action_route,
      'actionRequired',notification.action_required,'readAt',notification.read_at,
      'resolvedAt',notification.resolved_at,'createdAt',notification.created_at
    ) order by notification.action_required desc,notification.created_at desc)
      from (select * from public.notifications own_notification
        where own_notification.recipient_id=v_actor
        order by own_notification.action_required desc,own_notification.created_at desc
        limit 40) notification),'[]'::jsonb),
    'managerInbox',coalesce((select jsonb_agg(jsonb_build_object(
      'id',request_row.id,'requestType',request_row.request_type,
      'employeeId',request_row.employee_id,
      'employeeName',employee.first_name||' '||employee.last_name,
      'employeeNo',employee.employee_no,'dateFrom',request_row.date_from,
      'dateTo',request_row.date_to,'status',request_row.status,
      'note',request_row.note,'createdAt',request_row.created_at
    ) order by request_row.created_at)
      from public.employee_requests_v1 request_row
      join public.employees employee on employee.id=request_row.employee_id
      where request_row.status in ('PENDING','APPLIED')
        and request_row.requires_decision
        and employee.auth_user_id is distinct from v_actor
        and public.matrix_v2_can_manage_employee(request_row.employee_id)),'[]'::jsonb),
    'myRequests',coalesce((select jsonb_agg(jsonb_build_object(
      'id',request_row.id,'requestType',request_row.request_type,
      'dateFrom',request_row.date_from,'dateTo',request_row.date_to,
      'status',request_row.status,'note',request_row.note,
      'reviewReason',request_row.review_reason,'createdAt',request_row.created_at
    ) order by request_row.created_at desc)
      from public.employee_requests_v1 request_row
      where request_row.requested_by=v_actor),'[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;


ALTER FUNCTION "public"."personal_action_workspace_uat_v1"() OWNER TO "postgres";

--
-- Name: personal_message_action_route_uat_v1("uuid", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."personal_message_action_route_uat_v1"("p_auth_user_id" "uuid", "p_conversation_id" "uuid") RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select case when
    exists(select 1 from public.user_permissions permission
      where permission.auth_user_id=p_auth_user_id
        and permission.app_role in ('OWNER','ADMIN','HR_FINANCE','ROLE_MANAGER','LOCATION_MANAGER','VERIFIER'))
    or exists(select 1 from public.matrix_scope_grants_v2 grant_row
      where grant_row.auth_user_id=p_auth_user_id and grant_row.active
        and grant_row.app_role in ('ROLE_MANAGER','LOCATION_MANAGER','VERIFIER'))
    then '/operations?view=wiadomosci&conversation='||p_conversation_id::text
    else '/messages?conversation='||p_conversation_id::text end;
$$;


ALTER FUNCTION "public"."personal_message_action_route_uat_v1"("p_auth_user_id" "uuid", "p_conversation_id" "uuid") OWNER TO "postgres";

--
-- Name: personal_notification_mark_read_uat_v1("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."personal_notification_mark_read_uat_v1"("p_notification_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_actor uuid:=auth.uid(); v_read timestamptz;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  update public.notifications set read_at=coalesce(read_at,now())
  where id=p_notification_id and recipient_id=v_actor returning read_at into v_read;
  if v_read is null then raise exception 'NOTIFICATION_NOT_FOUND'; end if;
  return jsonb_build_object('id',p_notification_id,'readAt',v_read);
end;
$$;


ALTER FUNCTION "public"."personal_notification_mark_read_uat_v1"("p_notification_id" "uuid") OWNER TO "postgres";

--
-- Name: personal_profile_save_uat_v1("text", "text", "text", "text", "text", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."personal_profile_save_uat_v1"("p_display_name" "text", "p_avatar_mode" "text", "p_cat_avatar_key" "text" DEFAULT NULL::"text", "p_note_color" "text" DEFAULT '#E8E1D6'::"text", "p_photo_path" "text" DEFAULT NULL::"text", "p_ui_preferences" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_actor uuid:=auth.uid();
  v_mode text:=upper(trim(coalesce(p_avatar_mode,'')));
  v_cat text:=upper(trim(coalesce(p_cat_avatar_key,'')));
  v_photo text:=nullif(trim(coalesce(p_photo_path,'')),'');
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if length(trim(coalesce(p_display_name,''))) not between 1 and 80 then
    raise exception 'INVALID_DISPLAY_NAME';
  end if;
  if v_mode not in ('INITIALS','CAT','PHOTO') then raise exception 'INVALID_AVATAR_MODE'; end if;
  if v_mode='CAT' and v_cat !~ '^CAT_(0[1-9]|[1-4][0-9]|5[0-5])$' then
    raise exception 'INVALID_CAT_AVATAR';
  end if;
  if v_mode='PHOTO' and (v_photo is null or v_photo not like v_actor::text||'/%') then
    raise exception 'INVALID_PROFILE_PHOTO_PATH';
  end if;
  if p_ui_preferences is null or jsonb_typeof(p_ui_preferences)<>'object' then
    raise exception 'INVALID_UI_PREFERENCES';
  end if;
  insert into public.user_profiles_v1(
    auth_user_id,display_name,avatar_mode,cat_avatar_key,note_color,photo_path,
    ui_preferences,updated_at
  ) values(
    v_actor,trim(p_display_name),v_mode,
    case when v_mode='CAT' then v_cat else null end,p_note_color,
    case when v_mode='PHOTO' then v_photo else null end,p_ui_preferences,now()
  ) on conflict(auth_user_id) do update set
    display_name=excluded.display_name,avatar_mode=excluded.avatar_mode,
    cat_avatar_key=excluded.cat_avatar_key,note_color=excluded.note_color,
    photo_path=excluded.photo_path,ui_preferences=excluded.ui_preferences,
    updated_at=now();
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'user_profile_v1',v_actor::text,'SAVE',jsonb_build_object(
    'avatarMode',v_mode,'catAvatarKey',case when v_mode='CAT' then v_cat else null end,
    'noteColor',p_note_color,'hasPhoto',v_mode='PHOTO'));
  return public.personal_profile_workspace_uat_v1();
end;
$_$;


ALTER FUNCTION "public"."personal_profile_save_uat_v1"("p_display_name" "text", "p_avatar_mode" "text", "p_cat_avatar_key" "text", "p_note_color" "text", "p_photo_path" "text", "p_ui_preferences" "jsonb") OWNER TO "postgres";

--
-- Name: personal_profile_workspace_uat_v1(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."personal_profile_workspace_uat_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid();
  v_result jsonb;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select jsonb_build_object(
    'profile',jsonb_build_object(
      'authUserId',v_actor,
      'displayName',coalesce(nullif(trim(profile.display_name),''),
        nullif(trim(concat_ws(' ',employee.first_name,employee.last_name)),''),
        split_part(auth_user.email,'@',1)),
      'avatarMode',coalesce(profile.avatar_mode,'INITIALS'),
      'catAvatarKey',profile.cat_avatar_key,
      'noteColor',coalesce(profile.note_color,'#E8E1D6'),
      'photoPath',profile.photo_path,
      'uiPreferences',coalesce(profile.ui_preferences,'{}'::jsonb)
    ),
    'employee',case when employee.id is null then null else jsonb_build_object(
      'id',employee.id,'employeeNo',employee.employee_no,
      'firstName',employee.first_name,'lastName',employee.last_name
    ) end,
    'appRoles',coalesce((select jsonb_agg(distinct role_name order by role_name)
      from (
        select permission.app_role::text role_name from public.user_permissions permission
          where permission.auth_user_id=v_actor
        union
        select grant_row.app_role::text from public.matrix_scope_grants_v2 grant_row
          where grant_row.auth_user_id=v_actor and grant_row.active
      ) roles),'[]'::jsonb)
  ) into v_result
  from auth.users auth_user
  left join public.user_profiles_v1 profile on profile.auth_user_id=v_actor
  left join public.employees employee on employee.auth_user_id=v_actor
    and employee.active and employee.archived_at is null
  where auth_user.id=v_actor;
  return coalesce(v_result,'{}'::jsonb);
end;
$$;


ALTER FUNCTION "public"."personal_profile_workspace_uat_v1"() OWNER TO "postgres";

--
-- Name: personal_request_manager_recipients_uat_v1("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."personal_request_manager_recipients_uat_v1"("p_employee_id" "uuid") RETURNS TABLE("auth_user_id" "uuid")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select distinct recipient.auth_user_id
  from (
    select permission.auth_user_id
    from public.user_permissions permission
    where permission.app_role in ('OWNER','ADMIN')
    union all
    select grant_row.auth_user_id
    from public.matrix_scope_grants_v2 grant_row
    where grant_row.active
      and grant_row.app_role in ('ROLE_MANAGER','LOCATION_MANAGER')
      and (grant_row.role_logical_id is null or exists(
        select 1
        from public.matrix_employee_roles_v2 employee_role
        join public.matrix_roles_v2 role_row on role_row.id=employee_role.role_id
        join public.matrix_versions matrix_row on matrix_row.id=employee_role.matrix_version_id
          and matrix_row.status='ACTIVE'
        where employee_role.employee_id=p_employee_id and employee_role.active
          and role_row.logical_id=grant_row.role_logical_id
      ))
      and (grant_row.location_logical_id is null or exists(
        select 1
        from public.matrix_employee_locations_v2 employee_location
        join public.matrix_locations_v2 location_row on location_row.id=employee_location.location_id
        join public.matrix_versions matrix_row on matrix_row.id=employee_location.matrix_version_id
          and matrix_row.status='ACTIVE'
        where employee_location.employee_id=p_employee_id and employee_location.active
          and location_row.logical_id=grant_row.location_logical_id
      ))
  ) recipient
  where recipient.auth_user_id is not null;
$$;


ALTER FUNCTION "public"."personal_request_manager_recipients_uat_v1"("p_employee_id" "uuid") OWNER TO "postgres";

--
-- Name: plan_workspace("date", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."plan_workspace"("p_month" "date" DEFAULT NULL::"date", "p_plan_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_payload jsonb:=public.plan_workspace_before_b4f52_uat_v1(p_month,p_plan_id);
  v_visibility text:=public.application_finance_visibility_current_uat_v1();
  v_assignment jsonb;
  v_assignments jsonb:='[]'::jsonb;
  v_plan jsonb:=coalesce(v_payload->'plan','{}'::jsonb);
  v_budget jsonb:=coalesce(v_payload->'budget','{}'::jsonb);
  v_total_cost numeric:=nullif(v_plan->>'total_cost','')::numeric;
  v_budget_amount numeric:=nullif(v_budget->>'amount','')::numeric;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if v_visibility='FULL' then
    return v_payload||jsonb_build_object('financeVisibility',v_visibility);
  end if;

  for v_assignment in
    select value from jsonb_array_elements(coalesce(v_payload->'assignments','[]'::jsonb))
  loop
    v_assignments:=v_assignments||jsonb_build_array(v_assignment-'cost');
  end loop;
  v_payload:=jsonb_set(v_payload,'{assignments}',v_assignments,true);

  if v_visibility='AGGREGATE' then
    return v_payload||jsonb_build_object('financeVisibility',v_visibility);
  end if;

  v_payload:=jsonb_set(v_payload,'{plan}',v_plan-'total_cost',true);
  if v_visibility='BUDGET_ONLY' then
    v_payload:=jsonb_set(v_payload,'{budget}',jsonb_build_object(
      'configured',v_budget_amount is not null and v_budget_amount>0,
      'withinBudget',case when v_total_cost is null or v_budget_amount is null or v_budget_amount<=0
        then null else v_total_cost<=v_budget_amount end,
      'hardLimit',case when v_budget='{}'::jsonb then null else v_budget->'hard_limit' end
    ),true);
    return v_payload||jsonb_build_object('financeVisibility',v_visibility);
  end if;

  return (v_payload-'budget')||jsonb_build_object('financeVisibility','NONE');
end;
$$;


ALTER FUNCTION "public"."plan_workspace"("p_month" "date", "p_plan_id" "uuid") OWNER TO "postgres";

--
-- Name: FUNCTION "plan_workspace"("p_month" "date", "p_plan_id" "uuid"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."plan_workspace"("p_month" "date", "p_plan_id" "uuid") IS 'B4F-52 legacy plan workspace with server-side finance visibility redaction.';


--
-- Name: plan_workspace_before_b4f52_uat_v1("date", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."plan_workspace_before_b4f52_uat_v1"("p_month" "date" DEFAULT NULL::"date", "p_plan_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
with chosen as (
  select p.* from public.plans p
  where (
    (p_plan_id is not null and p.id=p_plan_id)
    or (p_plan_id is null and p.month=date_trunc('month',coalesce(p_month,current_date))::date)
  ) and (public.can_manage_plans() or p.status='PUBLISHED')
  order by case p.status when 'PUBLISHED' then 0 when 'READY' then 1 else 2 end,p.version desc
  limit 1
), ass as (
  select a.*,s.plan_id,s.shift_date,s.shift_code,s.starts_at,s.ends_at,s.location_id,
    e.employee_no,e.first_name,e.last_name,e.monthly_nominal_minutes,e.primary_role,
    l.code location_code
  from public.assignments a
  join public.shifts s on s.id=a.shift_id
  join public.employees e on e.id=a.employee_id
  join public.locations l on l.id=s.location_id
  where s.plan_id=(select id from chosen)
    and public.can_view_assignment(e.id,a.assigned_role,l.code)
), totals as (
  select employee_id,sum(public.shift_minutes(starts_at,ends_at)) minutes
  from ass group by employee_id
)
select jsonb_build_object(
  'plan',(select to_jsonb(c) from chosen c),
  'budget',coalesce((select jsonb_build_object(
    'amount',b.amount,'warning_percent',b.warning_percent,'hard_limit',b.hard_limit
  ) from public.monthly_budgets b
    where b.month=date_trunc('month',coalesce(p_month,(select month from chosen),current_date))::date),
    jsonb_build_object('amount',0,'warning_percent',90,'hard_limit',false)),
  'shifts',coalesce((select jsonb_agg(to_jsonb(x) order by x.shift_date,x.location_code,x.starts_at)
    from (select s.id,s.shift_date,s.shift_code,s.starts_at,s.ends_at,l.code location_code,
      count(a.id) assignment_count
      from public.shifts s join public.locations l on l.id=s.location_id
      left join public.assignments a on a.shift_id=s.id
      where s.plan_id=(select id from chosen)
        and (public.can_manage_plans() or exists (
          select 1 from public.assignments va
          where va.shift_id=s.id and public.can_view_assignment(va.employee_id,va.assigned_role,l.code)
        ))
      group by s.id,l.code) x),'[]'::jsonb),
  'assignments',coalesce((select jsonb_agg(jsonb_build_object(
    'id',a.id,'shift_id',a.shift_id,'employee_id',a.employee_id,'employee_no',a.employee_no,
    'name',a.first_name||' '||a.last_name,'role',a.assigned_role,'capability',a.assigned_capability,
    'location',a.location_code,'date',a.shift_date,'shift_code',a.shift_code,
    'starts_at',a.starts_at,'ends_at',a.ends_at,'cost',a.cost,'locked',a.locked,
    'monthly_minutes',t.minutes,'nominal_minutes',a.monthly_nominal_minutes
  ) order by a.shift_date,a.location_code,a.starts_at,a.assigned_role,a.last_name)
    from ass a join totals t on t.employee_id=a.employee_id),'[]'::jsonb),
  'issues',coalesce((select jsonb_agg(to_jsonb(i) order by i.severity desc,i.created_at)
    from public.plan_issues i where i.plan_id=(select id from chosen) and i.resolved_at is null
      and public.can_manage_plans()),'[]'::jsonb),
  'events',coalesce((select jsonb_agg(jsonb_build_object(
    'id',oe.id,'title',oe.title,'event_type',oe.event_type,'status',oe.status,
    'starts_at',oe.starts_at,'ends_at',oe.ends_at,'location',l.code,'expected_guests',oe.expected_guests
  ) order by oe.starts_at)
    from public.operational_events oe join public.locations l on l.id=oe.location_id
    where date_trunc('month',oe.starts_at at time zone l.timezone)::date=
      date_trunc('month',coalesce(p_month,(select month from chosen),current_date))::date),'[]'::jsonb)
);
$$;


ALTER FUNCTION "public"."plan_workspace_before_b4f52_uat_v1"("p_month" "date", "p_plan_id" "uuid") OWNER TO "postgres";

--
-- Name: preference_save("uuid", "date", "date", "text", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."preference_save"("p_employee_id" "uuid", "p_from" "date", "p_to" "date", "p_type" "text", "p_value" "jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$ declare out_id uuid; begin
 if not(public.can_manage_plans() or exists(select 1 from employees e where e.id=p_employee_id and e.auth_user_id=auth.uid())) then raise exception 'FORBIDDEN'; end if;
 insert into employee_preferences(employee_id,valid_from,valid_to,preference_type,preference_value,source,status)
 values(p_employee_id,p_from,p_to,p_type,p_value,'GRAFIK_PRO','ACTIVE') returning id into out_id; return out_id;
end $$;


ALTER FUNCTION "public"."preference_save"("p_employee_id" "uuid", "p_from" "date", "p_to" "date", "p_type" "text", "p_value" "jsonb") OWNER TO "postgres";

--
-- Name: publish_plan("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."publish_plan"("p_plan_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_plan public.plans;
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  select * into v_plan from public.plans where id=p_plan_id;
  if v_plan.id is null then raise exception 'PLAN_NOT_FOUND'; end if;
  if v_plan.status not in ('READY','STALE') then raise exception 'PLAN_NOT_READY'; end if;
  update public.plans set status='ARCHIVED'
    where month=v_plan.month and status='PUBLISHED' and id<>p_plan_id;
  update public.plans set status='PUBLISHED',published_at=now() where id=p_plan_id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'plan',p_plan_id::text,'PUBLISH',jsonb_build_object('month',v_plan.month));
  return jsonb_build_object('plan_id',p_plan_id,'status','PUBLISHED');
end;
$$;


ALTER FUNCTION "public"."publish_plan"("p_plan_id" "uuid") OWNER TO "postgres";

--
-- Name: published_company_calendar_uat_v2("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."published_company_calendar_uat_v2"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_month date:=date_trunc('month',p_month)::date;
  v_status jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  v_status:=public.schedule_publication_status_uat_v2(v_month);
  if coalesce((v_status->>'conflict')::boolean,false) then
    raise exception 'SCHEDULE_PUBLICATION_CONFLICT_REQUIRES_OWNER_RESOLUTION';
  end if;
  return jsonb_build_object(
    'month',v_month,
    'publication',v_status,
    'assignments',coalesce((
      with company_variants as (
        select distinct link.variant_id
        from public.published_schedules_v2 schedule
        join public.published_schedule_variants_v2 link on link.schedule_id=schedule.id
        where schedule.month=v_month and schedule.status='PUBLISHED'
      ),
      latest_role_variants as (
        select distinct on(role.logical_id) publication.variant_id
        from public.published_role_schedules_v2 publication
        join public.matrix_roles_v2 role on role.id=publication.role_id
        where publication.month=v_month and publication.status='PUBLISHED'
        order by role.logical_id,publication.published_at desc nulls last,
          publication.created_at desc,publication.id desc
      ),
      current_variants as (
        select variant_id from company_variants
        union all
        select variant_id from latest_role_variants
        where not exists(select 1 from company_variants)
      )
      select jsonb_agg(jsonb_build_object(
        'id',assignment.id,'date',shift.shift_date,'startsAt',shift.starts_at,
        'endsAt',shift.ends_at,'locationId',location.logical_id,
        'locationName',location.name,'shiftName',template.name,
        'roleId',role.logical_id,'roleName',role.name,
        'employeeId',coalesce(replacement.replacement_employee_id,assignment.employee_id),
        'employeeName',coalesce(replacement_profile.first_name||' '||replacement_profile.last_name,
          profile.first_name||' '||profile.last_name),
        'employeeNo',coalesce(replacement_profile.employee_no,profile.employee_no),
        'isSwap',replacement.id is not null,'swapAuditId',swap_request.id
      ) order by shift.starts_at,location.name,role.name,profile.last_name)
      from public.plan_assignments_v2 assignment
      join current_variants current on current.variant_id=assignment.variant_id
      join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
      join public.matrix_locations_v2 location on location.id=shift.location_id
      join public.matrix_shift_templates_v2 template on template.id=shift.shift_template_id
      join public.matrix_roles_v2 role on role.id=assignment.role_id
      join public.matrix_employee_profiles_v2 profile
        on profile.matrix_version_id=role.matrix_version_id
        and profile.employee_id=assignment.employee_id
      left join public.operational_assignment_replacements_v2 replacement
        on replacement.original_assignment_id=assignment.id and replacement.status='ACTIVE'
      left join public.matrix_employee_profiles_v2 replacement_profile
        on replacement_profile.matrix_version_id=role.matrix_version_id
        and replacement_profile.employee_id=replacement.replacement_employee_id
      left join public.shift_swap_requests_v2 swap_request
        on swap_request.replacement_id=replacement.id
      where shift.shift_date>=v_month
        and shift.shift_date<(v_month+interval '1 month')::date
    ),'[]'::jsonb)
  );
end;
$$;


ALTER FUNCTION "public"."published_company_calendar_uat_v2"("p_month" "date") OWNER TO "postgres";

--
-- Name: published_employee_category_calendar_uat_v3("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."published_employee_category_calendar_uat_v3"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_month date:=date_trunc('month',p_month)::date;
  v_status jsonb;
  v_employee uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;

  select employee.id into v_employee
  from public.employees employee
  where employee.auth_user_id=auth.uid()
    and employee.active
    and employee.archived_at is null
  order by employee.employee_no
  limit 1;

  if v_employee is null then raise exception 'EMPLOYEE_ACCOUNT_NOT_LINKED'; end if;

  v_status:=public.schedule_publication_status_uat_v2(v_month);
  if coalesce((v_status->>'conflict')::boolean,false) then
    raise exception 'SCHEDULE_PUBLICATION_CONFLICT_REQUIRES_OWNER_RESOLUTION';
  end if;

  return (
    with company_variants as (
      select distinct link.variant_id
      from public.published_schedules_v2 schedule
      join public.published_schedule_variants_v2 link on link.schedule_id=schedule.id
      where schedule.month=v_month and schedule.status='PUBLISHED'
    ),
    latest_role_variants as (
      select distinct on(role.logical_id) publication.variant_id
      from public.published_role_schedules_v2 publication
      join public.matrix_roles_v2 role on role.id=publication.role_id
      where publication.month=v_month and publication.status='PUBLISHED'
      order by role.logical_id,publication.published_at desc nulls last,
        publication.created_at desc,publication.id desc
    ),
    current_variants as (
      select variant_id from company_variants
      union all
      select variant_id from latest_role_variants
      where not exists(select 1 from company_variants)
    ),
    scoped_rows as (
      select assignment.id,shift.shift_date,shift.starts_at,shift.ends_at,
        location.logical_id location_id,location.name location_name,
        template.name shift_name,role.logical_id role_id,role.name role_name,
        category.logical_id category_id,category.name category_name,
        coalesce(replacement.replacement_employee_id,assignment.employee_id) employee_id,
        coalesce(replacement_profile.first_name||' '||replacement_profile.last_name,
          profile.first_name||' '||profile.last_name) employee_name,
        coalesce(replacement_profile.employee_no,profile.employee_no) employee_no,
        replacement.id is not null is_swap,swap_request.id swap_audit_id
      from public.plan_assignments_v2 assignment
      join current_variants current on current.variant_id=assignment.variant_id
      join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
      join public.matrix_locations_v2 location on location.id=shift.location_id
      join public.matrix_shift_templates_v2 template on template.id=shift.shift_template_id
      join public.matrix_roles_v2 role on role.id=assignment.role_id
      join public.matrix_role_categories_v2 category on category.id=role.category_id
      join public.matrix_employee_profiles_v2 profile
        on profile.matrix_version_id=role.matrix_version_id
       and profile.employee_id=assignment.employee_id
      left join public.operational_assignment_replacements_v2 replacement
        on replacement.original_assignment_id=assignment.id and replacement.status='ACTIVE'
      left join public.matrix_employee_profiles_v2 replacement_profile
        on replacement_profile.matrix_version_id=role.matrix_version_id
       and replacement_profile.employee_id=replacement.replacement_employee_id
      left join public.shift_swap_requests_v2 swap_request
        on swap_request.replacement_id=replacement.id
      where shift.shift_date>=v_month
        and shift.shift_date<(v_month+interval '1 month')::date
        and exists(
          select 1
          from public.matrix_employee_roles_v2 viewer_grant
          join public.matrix_roles_v2 viewer_role on viewer_role.id=viewer_grant.role_id
          where viewer_grant.matrix_version_id=role.matrix_version_id
            and viewer_grant.employee_id=v_employee
            and viewer_grant.active
            and viewer_role.active
            and viewer_role.category_id=role.category_id
            and (viewer_grant.valid_from is null
              or viewer_grant.valid_from<(v_month+interval '1 month')::date)
            and (viewer_grant.valid_to is null or viewer_grant.valid_to>=v_month)
        )
    )
    select jsonb_build_object(
      'month',v_month,
      'publication',v_status,
      'employeeId',v_employee,
      'scopeCategories',coalesce((
        select jsonb_agg(category_item order by category_item->>'name')
        from (
          select distinct jsonb_build_object(
            'id',row_value.category_id,'name',row_value.category_name
          ) category_item
          from scoped_rows row_value
        ) categories
      ),'[]'::jsonb),
      'assignments',coalesce((
        select jsonb_agg(jsonb_build_object(
          'id',row_value.id,'date',row_value.shift_date,
          'startsAt',row_value.starts_at,'endsAt',row_value.ends_at,
          'locationId',row_value.location_id,'locationName',row_value.location_name,
          'shiftName',row_value.shift_name,
          'roleId',row_value.role_id,'roleName',row_value.role_name,
          'categoryId',row_value.category_id,'categoryName',row_value.category_name,
          'employeeId',row_value.employee_id,'employeeName',row_value.employee_name,
          'employeeNo',row_value.employee_no,'isSwap',row_value.is_swap,
          'swapAuditId',row_value.swap_audit_id
        ) order by row_value.starts_at,row_value.location_name,
          row_value.role_name,row_value.employee_name)
        from scoped_rows row_value
      ),'[]'::jsonb)
    )
  );
end;
$$;


ALTER FUNCTION "public"."published_employee_category_calendar_uat_v3"("p_month" "date") OWNER TO "postgres";

--
-- Name: FUNCTION "published_employee_category_calendar_uat_v3"("p_month" "date"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."published_employee_category_calendar_uat_v3"("p_month" "date") IS 'B4F-87: category-scoped coworker calendar for the signed-in employee; no finance or absence details.';


--
-- Name: recovery_action_select_candidate_uat_v1("uuid", "uuid", integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."recovery_action_select_candidate_uat_v1"("p_action_id" "uuid", "p_employee_id" "uuid", "p_expected_action_version" integer, "p_expected_revision" integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid(); v_action public.recovery_actions_v2%rowtype;
  v_incident public.recovery_incidents_v2%rowtype; v_revision integer;
  v_candidate jsonb;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into v_action from public.recovery_actions_v2 where id=p_action_id for update;
  select * into v_incident from public.recovery_incidents_v2 where id=v_action.incident_id for update;
  if v_action.id is null or v_incident.id is null then raise exception 'RECOVERY_ACTION_NOT_FOUND'; end if;
  if not solver_private.recovery_can_manage_scope_uat_v1(v_incident.role_id,v_incident.location_id)
    then raise exception 'ROLE_OR_LOCATION_SCOPE_FORBIDDEN'; end if;
  perform pg_advisory_xact_lock(hashtextextended('recovery:'||v_incident.month::text,0));
  select revision into v_revision from public.recovery_month_revisions_v2 where month=v_incident.month for update;
  if v_revision<>p_expected_revision then raise exception 'RECOVERY_REVISION_CONFLICT expected %, actual %',p_expected_revision,v_revision; end if;
  if v_action.version<>p_expected_action_version then raise exception 'RECOVERY_ACTION_CONFLICT'; end if;
  select candidate into v_candidate from jsonb_array_elements(v_action.candidate_snapshot) candidate
  where candidate->>'employeeId'=p_employee_id::text limit 1;
  if v_candidate is null then raise exception 'RECOVERY_CANDIDATE_NOT_FOUND'; end if;
  if not coalesce((v_candidate->>'eligible')::boolean,false)
    then raise exception 'RECOVERY_CANDIDATE_HARD_BLOCKED'; end if;
  update public.recovery_actions_v2 set selected_employee_id=p_employee_id,status='DRAFT_READY',
    version=version+1,updated_at=now() where id=v_action.id;
  update public.recovery_month_revisions_v2 set revision=revision+1,updated_by=v_actor,updated_at=now()
    where month=v_incident.month returning revision into v_revision;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'recovery_action_v2',v_action.id::text,'RECOVERY_CANDIDATE_SELECTED',
    jsonb_build_object('employeeId',p_employee_id,'previousEmployeeId',v_action.selected_employee_id,'revision',v_revision));
  return jsonb_build_object('saved',true,'revision',v_revision,'actionVersion',v_action.version+1);
end;
$$;


ALTER FUNCTION "public"."recovery_action_select_candidate_uat_v1"("p_action_id" "uuid", "p_employee_id" "uuid", "p_expected_action_version" integer, "p_expected_revision" integer) OWNER TO "postgres";

--
-- Name: recovery_ad_hoc_save_uat_v1("uuid", "uuid", "text", "text", "text", "uuid", "text", bigint, "text", "date", "date", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."recovery_ad_hoc_save_uat_v1"("p_id" "uuid", "p_employee_id" "uuid", "p_display_name" "text", "p_email" "text", "p_phone" "text", "p_role_id" "uuid", "p_contract_type" "text", "p_rate_minor" bigint, "p_currency" "text", "p_available_from" "date", "p_available_to" "date", "p_notes" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_actor uuid:=auth.uid(); v_id uuid:=coalesce(p_id,gen_random_uuid());
  v_contract text:=upper(trim(coalesce(p_contract_type,'ZLECENIE')));
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not solver_private.recovery_can_manage_role_uat_v1(p_role_id) then raise exception 'ROLE_SCOPE_FORBIDDEN'; end if;
  if length(trim(coalesce(p_display_name,'')))<3 then raise exception 'AD_HOC_NAME_REQUIRED'; end if;
  if v_contract not in ('UMOWA_O_PRACE','CZESC_ETATU','ZLECENIE','B2B','INNE') then
    raise exception 'INVALID_CONTRACT_TYPE';
  end if;
  insert into public.recovery_ad_hoc_pool_v2(id,employee_id,display_name,email,phone,role_id,contract_type,
    base_rate_minor,currency,available_from,available_to,active,notes,created_by)
  values(v_id,p_employee_id,trim(p_display_name),nullif(trim(coalesce(p_email,'')),''),nullif(trim(coalesce(p_phone,'')),''),p_role_id,
    v_contract,p_rate_minor,coalesce(nullif(trim(p_currency),''),'PLN'),
    p_available_from,p_available_to,true,nullif(trim(coalesce(p_notes,'')),''),v_actor)
  on conflict(id) do update set employee_id=excluded.employee_id,display_name=excluded.display_name,email=excluded.email,
    phone=excluded.phone,role_id=excluded.role_id,contract_type=excluded.contract_type,base_rate_minor=excluded.base_rate_minor,
    currency=excluded.currency,available_from=excluded.available_from,available_to=excluded.available_to,notes=excluded.notes,updated_at=now();
  return jsonb_build_object('saved',true,'id',v_id);
end;
$$;


ALTER FUNCTION "public"."recovery_ad_hoc_save_uat_v1"("p_id" "uuid", "p_employee_id" "uuid", "p_display_name" "text", "p_email" "text", "p_phone" "text", "p_role_id" "uuid", "p_contract_type" "text", "p_rate_minor" bigint, "p_currency" "text", "p_available_from" "date", "p_available_to" "date", "p_notes" "text") OWNER TO "postgres";

--
-- Name: recovery_center_workspace_before_b4f101_uat_v1("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."recovery_center_workspace_before_b4f101_uat_v1"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_month date:=date_trunc('month',p_month)::date;
  v_revision integer;
  v_schedule jsonb;
  v_shortages jsonb;
  v_incidents jsonb;
  v_ad_hoc jsonb;
  v_budget jsonb;
  v_scopes jsonb;
  v_location_scopes jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  select coalesce(revision,0) into v_revision from public.recovery_month_revisions_v2 where month=v_month;
  select coalesce(jsonb_build_object('id',schedule.id,'name',schedule.name,'status',schedule.status,
    'publishedAt',schedule.published_at,'validation',schedule.validation_summary),'null'::jsonb)
  into v_schedule from public.published_schedules_v2 schedule
  where schedule.month=v_month and schedule.status='PUBLISHED'
  order by schedule.published_at desc limit 1;

  with published as (select variant_id from solver_private.recovery_published_variants_uat_v1(v_month)),
  gaps as (
    select issue.role_id,shift.location_id,shift.shift_date,
      to_char(shift.starts_at at time zone coalesce(location.timezone,'Europe/Warsaw'),'HH24:MI') starts_at,
      to_char(shift.ends_at at time zone coalesce(location.timezone,'Europe/Warsaw'),'HH24:MI') ends_at,
      greatest(coalesce(issue.required_count,0)-coalesce(issue.assigned_count,0),0) missing,
      extract(epoch from (shift.ends_at-shift.starts_at))/60 duration_minutes,
      role.name role_name,role.color role_color,location.name location_name
    from published join public.plan_issues_v2 issue on issue.variant_id=published.variant_id
    join public.plan_shifts_v2 shift on shift.id=issue.shift_id
    join public.matrix_roles_v2 role on role.id=issue.role_id
    join public.matrix_locations_v2 location on location.id=shift.location_id
    where issue.issue_code='UNFILLED_SLOT'
      and greatest(coalesce(issue.required_count,0)-coalesce(issue.assigned_count,0),0)>0
      and solver_private.recovery_can_manage_scope_uat_v1(issue.role_id,shift.location_id)
  ), grouped as (
    select role_id,location_id,starts_at,ends_at,min(role_name) role_name,min(role_color) role_color,
      min(location_name) location_name,count(distinct shift_date) affected_days,
      min(shift_date) first_date,max(shift_date) last_date,sum(missing) missing_slots,
      round(sum(missing*duration_minutes)/60.0,1) missing_hours,
      array_agg(distinct shift_date order by shift_date) dates
    from gaps group by role_id,location_id,starts_at,ends_at
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'roleId',role_id,'roleName',role_name,'roleColor',role_color,'locationId',location_id,
    'locationName',location_name,'startsAt',starts_at,'endsAt',ends_at,
    'affectedDays',affected_days,'firstDate',first_date,'lastDate',last_date,
    'missingSlots',missing_slots,'missingHours',missing_hours,'dates',to_jsonb(dates),
    'structural',affected_days>=2,
    'actions',jsonb_build_array('Dodatkowa osoba lub pula ad-hoc','Zwiększenie wymiaru za zgodą',
      'Przeniesienie między lokalami','Zmiana minimum obsady lub godzin działalności')
  ) order by missing_hours desc),'[]'::jsonb) into v_shortages from grouped;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',incident.id,'type',incident.incident_type,'title',incident.title,'status',incident.status,
    'mode',incident.repair_mode,'startsOn',incident.starts_on,'endsOn',incident.ends_on,
    'employeeId',incident.employee_id,'employeeName',trim(concat(employee.first_name,' ',employee.last_name)),
    'roleId',incident.role_id,'roleName',role.name,'roleColor',role.color,
    'locationId',incident.location_id,'locationName',incident_location.name,'notes',incident.notes,
    'baseRevision',incident.base_revision,'updatedAt',incident.updated_at,
    'actionCount',(select count(*) from public.recovery_actions_v2 action where action.incident_id=incident.id),
    'offerCount',(select count(*) from public.recovery_offer_responses_v2 response join public.recovery_actions_v2 action on action.id=response.action_id where action.incident_id=incident.id)
  ) order by incident.created_at desc),'[]'::jsonb) into v_incidents
  from public.recovery_incidents_v2 incident
  left join public.employees employee on employee.id=incident.employee_id
  left join public.matrix_roles_v2 role on role.id=incident.role_id
  left join public.matrix_locations_v2 incident_location on incident_location.id=incident.location_id
  where incident.month=v_month
    and solver_private.recovery_can_manage_scope_uat_v1(incident.role_id,incident.location_id);

  select coalesce(jsonb_agg(jsonb_build_object('id',pool.id,'employeeId',pool.employee_id,
    'name',pool.display_name,'email',pool.email,'phone',pool.phone,'roleId',pool.role_id,
    'roleName',role.name,'roleColor',role.color,'contractType',pool.contract_type,
    'rateMinor',pool.base_rate_minor,'currency',pool.currency,'availableFrom',pool.available_from,
    'availableTo',pool.available_to,'active',pool.active,'notes',pool.notes)
    order by role.name,pool.display_name),'[]'::jsonb) into v_ad_hoc
  from public.recovery_ad_hoc_pool_v2 pool join public.matrix_roles_v2 role on role.id=pool.role_id
  where pool.active and (pool.available_from is null or pool.available_from<(v_month+interval '1 month')::date)
    and (pool.available_to is null or pool.available_to>=v_month)
    and solver_private.recovery_can_manage_scope_uat_v1(pool.role_id,null);

  select coalesce(jsonb_build_object('amount',budget.amount,'warningPercent',budget.warning_percent,
    'hardLimit',budget.hard_limit,'updatedAt',budget.updated_at),
    jsonb_build_object('amount',0,'warningPercent',90,'hardLimit',false))
  into v_budget from public.monthly_budgets budget where budget.month=v_month;

  select coalesce(jsonb_agg(jsonb_build_object('roleId',role.id,'roleName',role.name,'roleColor',role.color,
    'canManage',solver_private.recovery_can_manage_role_uat_v1(role.id)) order by role.sort_order),'[]'::jsonb)
  into v_scopes from public.matrix_roles_v2 role join public.matrix_versions matrix on matrix.id=role.matrix_version_id
  where matrix.status='ACTIVE' and role.active;

  select coalesce(jsonb_agg(jsonb_build_object('locationId',location.id,'locationName',location.name,
    'canManage',solver_private.recovery_can_manage_scope_uat_v1(null,location.id)) order by location.sort_order),'[]'::jsonb)
  into v_location_scopes from public.matrix_locations_v2 location
  join public.matrix_versions matrix on matrix.id=location.matrix_version_id
  where matrix.status='ACTIVE' and location.active;

  return jsonb_build_object('month',v_month,'revision',coalesce(v_revision,0),'schedule',v_schedule,
    'shortages',coalesce(v_shortages,'[]'::jsonb),'incidents',coalesce(v_incidents,'[]'::jsonb),
    'adHocPool',coalesce(v_ad_hoc,'[]'::jsonb),'budget',v_budget,
    'roleScopes',coalesce(v_scopes,'[]'::jsonb),'locationScopes',coalesce(v_location_scopes,'[]'::jsonb));
end;
$$;


ALTER FUNCTION "public"."recovery_center_workspace_before_b4f101_uat_v1"("p_month" "date") OWNER TO "postgres";

--
-- Name: recovery_center_workspace_before_phase1_uat_v1("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."recovery_center_workspace_before_phase1_uat_v1"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_payload jsonb:=public.recovery_center_workspace_before_b4f101_uat_v1(p_month);
  v_visibility text:=public.application_finance_visibility_current_uat_v1();
  v_person jsonb;
  v_people jsonb:='[]'::jsonb;
  v_budget jsonb;
begin
  if v_visibility='FULL' then return v_payload||jsonb_build_object('financeVisibility',v_visibility); end if;
  for v_person in select value from jsonb_array_elements(coalesce(v_payload->'adHocPool','[]'::jsonb)) loop
    v_people:=v_people||jsonb_build_array(v_person-'rateMinor'-'currency');
  end loop;
  v_payload:=jsonb_set(v_payload,'{adHocPool}',v_people,true);
  if v_visibility='AGGREGATE' then return v_payload||jsonb_build_object('financeVisibility',v_visibility); end if;
  if v_visibility='BUDGET_ONLY' then
    v_budget:=v_payload->'budget';
    v_payload:=jsonb_set(v_payload,'{budget}',jsonb_build_object(
      'configured',v_budget is not null and coalesce((v_budget->>'amount')::numeric,0)>0,
      'hardLimit',v_budget->'hardLimit'
    ),true);
  else
    v_payload:=v_payload-'budget';
  end if;
  return v_payload||jsonb_build_object('financeVisibility',v_visibility);
end;
$$;


ALTER FUNCTION "public"."recovery_center_workspace_before_phase1_uat_v1"("p_month" "date") OWNER TO "postgres";

--
-- Name: recovery_center_workspace_uat_v1("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."recovery_center_workspace_uat_v1"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if not public.matrix_v2_has_any_manager_scope_uat_v1()
    then raise exception 'RESOURCE_SCOPE_FORBIDDEN'; end if;
  perform authorization_private.enter_resource_scope_uat_v1();
  return public.recovery_center_workspace_before_phase1_uat_v1(p_month);
end;
$$;


ALTER FUNCTION "public"."recovery_center_workspace_uat_v1"("p_month" "date") OWNER TO "postgres";

--
-- Name: recovery_employee_offers_uat_v1("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."recovery_employee_offers_uat_v1"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_employee uuid; v_rows jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select id into v_employee from public.employees where auth_user_id=auth.uid() and active limit 1;
  if v_employee is null then return jsonb_build_object('offers','[]'::jsonb); end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',response.id,'actionId',action.id,'incidentId',incident.id,
    'title',incident.title,'status',response.status,'rateMinor',response.offered_rate_minor,'currency',response.currency,
    'message',response.message,'offeredAt',response.offered_at,'shiftDate',shift.shift_date,
    'startsAt',shift.starts_at,'endsAt',shift.ends_at,'locationName',location.name,'roleName',role.name)
    order by shift.shift_date,shift.starts_at),'[]'::jsonb) into v_rows
  from public.recovery_offer_responses_v2 response
  join public.recovery_actions_v2 action on action.id=response.action_id
  join public.recovery_incidents_v2 incident on incident.id=action.incident_id
  left join public.plan_shifts_v2 shift on shift.id=action.shift_id
  left join public.matrix_locations_v2 location on location.id=shift.location_id
  left join public.plan_assignments_v2 assignment on assignment.id=action.source_assignment_id
  left join public.matrix_roles_v2 role on role.id=coalesce(action.role_id,assignment.role_id)
  where response.employee_id=v_employee and incident.month=date_trunc('month',p_month)::date;
  return jsonb_build_object('offers',coalesce(v_rows,'[]'::jsonb));
end;
$$;


ALTER FUNCTION "public"."recovery_employee_offers_uat_v1"("p_month" "date") OWNER TO "postgres";

--
-- Name: recovery_incident_apply_draft_uat_v1("uuid", integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."recovery_incident_apply_draft_uat_v1"("p_incident_id" "uuid", "p_expected_revision" integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid(); v_incident public.recovery_incidents_v2%rowtype;
  v_revision integer; v_source_variant uuid; v_draft_variant uuid; v_action record;
  v_target_assignment uuid; v_target_issue bigint; v_current_snapshot jsonb;
  v_allow_limit_override boolean; v_result jsonb; v_drafts jsonb:='[]'::jsonb; v_applied integer:=0;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into v_incident from public.recovery_incidents_v2 where id=p_incident_id for update;
  if v_incident.id is null then raise exception 'INCIDENT_NOT_FOUND'; end if;
  if not solver_private.recovery_can_manage_scope_uat_v1(v_incident.role_id,v_incident.location_id)
    then raise exception 'ROLE_OR_LOCATION_SCOPE_FORBIDDEN'; end if;
  perform pg_advisory_xact_lock(hashtextextended('recovery:'||v_incident.month::text,0));
  select revision into v_revision from public.recovery_month_revisions_v2 where month=v_incident.month for update;
  if v_revision<>p_expected_revision then raise exception 'RECOVERY_REVISION_CONFLICT expected %, actual %',p_expected_revision,v_revision; end if;
  if not exists(select 1 from public.recovery_actions_v2 where incident_id=v_incident.id and selected_employee_id is not null)
    then raise exception 'RECOVERY_CANDIDATE_SELECTION_REQUIRED'; end if;

  for v_source_variant in
    select distinct coalesce(source_assignment.variant_id,source_issue.variant_id)
    from public.recovery_actions_v2 action
    left join public.plan_assignments_v2 source_assignment on source_assignment.id=action.source_assignment_id
    left join public.plan_issues_v2 source_issue on source_issue.id=action.source_issue_id
    where action.incident_id=v_incident.id and action.selected_employee_id is not null
  loop
    v_draft_variant:=solver_private.recovery_clone_published_variant_uat_v1(
      v_source_variant,'Naprawa • '||v_incident.title||' • '||v_incident.month::text
    );
    for v_action in
      select action.* from public.recovery_actions_v2 action
      left join public.plan_assignments_v2 source_assignment on source_assignment.id=action.source_assignment_id
      left join public.plan_issues_v2 source_issue on source_issue.id=action.source_issue_id
      where action.incident_id=v_incident.id and action.selected_employee_id is not null
        and coalesce(source_assignment.variant_id,source_issue.variant_id)=v_source_variant
      order by action.created_at,action.id
    loop
      v_current_snapshot:=solver_private.recovery_candidate_snapshot_uat_v1(
        v_incident.month,v_action.shift_id,v_action.role_id,v_action.duty_id,
        case when v_action.source_assignment_id is null then null else
          (select employee_id from public.plan_assignments_v2 where id=v_action.source_assignment_id) end
      );
      if not exists(select 1 from jsonb_array_elements(v_current_snapshot) candidate
        where candidate->>'employeeId'=v_action.selected_employee_id::text
          and coalesce((candidate->>'eligible')::boolean,false)) then
        raise exception 'RECOVERY_CANDIDATE_CHANGED:%',v_action.selected_employee_id;
      end if;
      v_target_assignment:=case when v_action.source_assignment_id is null then null else
        public.matrix_v2_stable_uuid('LEADER_ASSIGNMENT:'||v_draft_variant::text||':'||v_action.source_assignment_id::text) end;
      v_target_issue:=null;
      select issue.id into v_target_issue from public.plan_issues_v2 issue
      where issue.variant_id=v_draft_variant
        and issue.metadata->>'sourceIssueId'=v_action.source_issue_id::text limit 1;
      v_allow_limit_override:=exists(
        select 1 from public.recovery_overrides_v2 override_row
        where override_row.incident_id=v_incident.id and override_row.status='APPROVED'
          and override_row.override_type in ('WEEKLY_LIMIT','MONTHLY_LIMIT')
          and override_row.employee_id=v_action.selected_employee_id
          and (select shift_date from public.plan_shifts_v2 where id=v_action.shift_id)
            between override_row.starts_on and override_row.ends_on
      );
      v_result:=public.optimizer_leader_assignment_save_uat_v2(
        v_draft_variant,v_target_assignment,v_target_issue,v_action.selected_employee_id,
        'Naprawa incydentu: '||v_incident.title,v_allow_limit_override,null
      );
      update public.recovery_actions_v2 set status='APPLIED',draft_variant_id=v_draft_variant,
        version=version+1,updated_at=now() where id=v_action.id;
      v_applied:=v_applied+1;
    end loop;
    v_drafts:=v_drafts||jsonb_build_array(jsonb_build_object(
      'variantId',v_draft_variant,'sourceVariantId',v_source_variant,
      'runId',(select run_id from public.plan_variants_v2 where id=v_draft_variant),
      'roleId',(select run.scope_role_id from public.plan_variants_v2 variant
        join public.optimization_runs_v2 run on run.id=variant.run_id where variant.id=v_draft_variant),
      'status','SELECTED'
    ));
  end loop;
  update public.recovery_incidents_v2 set status='APPLIED',updated_by=v_actor,updated_at=now()
    where id=v_incident.id;
  update public.recovery_month_revisions_v2 set revision=revision+1,updated_by=v_actor,updated_at=now()
    where month=v_incident.month returning revision into v_revision;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'recovery_incident_v2',v_incident.id::text,'RECOVERY_DRAFTS_CREATED',
    jsonb_build_object('drafts',v_drafts,'appliedActions',v_applied,'revision',v_revision,
      'publishedScheduleChanged',false));
  return jsonb_build_object('created',true,'drafts',v_drafts,'appliedActions',v_applied,
    'revision',v_revision,'publishedScheduleChanged',false);
end;
$$;


ALTER FUNCTION "public"."recovery_incident_apply_draft_uat_v1"("p_incident_id" "uuid", "p_expected_revision" integer) OWNER TO "postgres";

--
-- Name: FUNCTION "recovery_incident_apply_draft_uat_v1"("p_incident_id" "uuid", "p_expected_revision" integer); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."recovery_incident_apply_draft_uat_v1"("p_incident_id" "uuid", "p_expected_revision" integer) IS 'Creates validated role-scoped leader drafts from recovery decisions; never mutates or republishes the active schedule.';


--
-- Name: recovery_incident_detail_before_b4f101_uat_v1("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."recovery_incident_detail_before_b4f101_uat_v1"("p_incident_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare v_detail jsonb;
begin
  v_detail:=public.recovery_incident_detail_before_b4f88_uat_v1(p_incident_id);
  return jsonb_set(v_detail,'{incidentRates}',coalesce((select jsonb_agg(jsonb_build_object(
    'id',r.id,'employeeId',r.employee_id,'employeeName',trim(concat(e.first_name,' ',e.last_name)),
    'revision',r.revision,'proposedRateMinor',r.proposed_rate_minor,'approvedRateMinor',r.approved_rate_minor,
    'currency',r.currency,'validFrom',r.valid_from,'validTo',r.valid_to,'status',r.status,
    'proposalReason',r.proposal_reason,'decisionReason',r.decision_reason
  ) order by r.revision desc) from public.recovery_incident_rate_revisions_v2 r join public.employees e on e.id=r.employee_id where r.incident_id=p_incident_id),'[]'::jsonb),true);
end $$;


ALTER FUNCTION "public"."recovery_incident_detail_before_b4f101_uat_v1"("p_incident_id" "uuid") OWNER TO "postgres";

--
-- Name: recovery_incident_detail_before_b4f88_uat_v1("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."recovery_incident_detail_before_b4f88_uat_v1"("p_incident_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_incident public.recovery_incidents_v2%rowtype; v_actions jsonb; v_overrides jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  select * into v_incident from public.recovery_incidents_v2 where id=p_incident_id;
  if v_incident.id is null then raise exception 'INCIDENT_NOT_FOUND'; end if;
  if not solver_private.recovery_can_manage_scope_uat_v1(v_incident.role_id,v_incident.location_id) then raise exception 'ROLE_OR_LOCATION_SCOPE_FORBIDDEN'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',action.id,'type',action.action_type,'status',action.status,
    'shiftId',action.shift_id,'assignmentId',action.source_assignment_id,'issueId',action.source_issue_id,
    'draftVariantId',action.draft_variant_id,'selectedEmployeeId',action.selected_employee_id,
    'candidates',action.candidate_snapshot,'risk',action.risk_level,'warnings',action.rule_warnings,
    'costDeltaMinor',action.estimated_cost_delta_minor,'currency',action.currency,'version',action.version,
    'shiftDate',shift.shift_date,'startsAt',shift.starts_at,'endsAt',shift.ends_at,
    'locationName',location.name,'roleName',role.name,'roleColor',role.color)
    order by shift.shift_date,shift.starts_at),'[]'::jsonb) into v_actions
  from public.recovery_actions_v2 action left join public.plan_shifts_v2 shift on shift.id=action.shift_id
  left join public.matrix_locations_v2 location on location.id=shift.location_id
  left join public.plan_assignments_v2 assignment on assignment.id=action.source_assignment_id
  left join public.matrix_roles_v2 role on role.id=coalesce(action.role_id,assignment.role_id)
  where action.incident_id=v_incident.id;
  select coalesce(jsonb_agg(to_jsonb(override_row) order by override_row.starts_on),'[]'::jsonb) into v_overrides
  from public.recovery_overrides_v2 override_row where override_row.incident_id=v_incident.id;
  return jsonb_build_object('id',v_incident.id,'month',v_incident.month,'title',v_incident.title,
    'type',v_incident.incident_type,'status',v_incident.status,'mode',v_incident.repair_mode,
    'startsOn',v_incident.starts_on,'endsOn',v_incident.ends_on,'employeeId',v_incident.employee_id,
    'roleId',v_incident.role_id,'locationId',v_incident.location_id,
    'contractType',v_incident.contract_type_snapshot,'notes',v_incident.notes,
    'actions',coalesce(v_actions,'[]'::jsonb),'overrides',coalesce(v_overrides,'[]'::jsonb));
end;
$$;


ALTER FUNCTION "public"."recovery_incident_detail_before_b4f88_uat_v1"("p_incident_id" "uuid") OWNER TO "postgres";

--
-- Name: recovery_incident_detail_before_phase1_uat_v1("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."recovery_incident_detail_before_phase1_uat_v1"("p_incident_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_payload jsonb:=public.recovery_incident_detail_before_b4f101_uat_v1(p_incident_id);
  v_visibility text:=public.application_finance_visibility_current_uat_v1();
  v_rate jsonb;
  v_rates jsonb:='[]'::jsonb;
begin
  if v_visibility='FULL' then return v_payload||jsonb_build_object('financeVisibility',v_visibility); end if;
  for v_rate in select value from jsonb_array_elements(coalesce(v_payload->'incidentRates','[]'::jsonb)) loop
    v_rates:=v_rates||jsonb_build_array(v_rate-'proposedRateMinor'-'approvedRateMinor'-'currency');
  end loop;
  return jsonb_set(v_payload,'{incidentRates}',v_rates,true)
    ||jsonb_build_object('financeVisibility',v_visibility);
end;
$$;


ALTER FUNCTION "public"."recovery_incident_detail_before_phase1_uat_v1"("p_incident_id" "uuid") OWNER TO "postgres";

--
-- Name: recovery_incident_detail_uat_v1("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."recovery_incident_detail_uat_v1"("p_incident_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_incident public.recovery_incidents_v2%rowtype;
begin
  select * into v_incident from public.recovery_incidents_v2 where id=p_incident_id;
  if v_incident.id is null then raise exception 'INCIDENT_NOT_FOUND'; end if;
  if not public.matrix_v2_can_manage_resource_uat_v1(
    v_incident.role_id,v_incident.location_id,v_incident.employee_id
  ) then raise exception 'RESOURCE_SCOPE_FORBIDDEN'; end if;
  perform authorization_private.enter_resource_scope_uat_v1();
  return public.recovery_incident_detail_before_phase1_uat_v1(p_incident_id);
end;
$$;


ALTER FUNCTION "public"."recovery_incident_detail_uat_v1"("p_incident_id" "uuid") OWNER TO "postgres";

--
-- Name: recovery_incident_prepare_before_phase1_uat_v1("uuid", integer, "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."recovery_incident_prepare_before_phase1_uat_v1"("p_incident_id" "uuid", "p_expected_revision" integer, "p_mode" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid(); v_incident public.recovery_incidents_v2%rowtype;
  v_revision integer; v_actions integer:=0; v_offers integer:=0;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  select * into v_incident from public.recovery_incidents_v2 where id=p_incident_id for update;
  if v_incident.id is null then raise exception 'INCIDENT_NOT_FOUND'; end if;
  if p_mode not in ('PROPOSE','SEND_OFFERS','AUTO_DRAFT') then raise exception 'INVALID_RECOVERY_MODE'; end if;
  if not solver_private.recovery_can_manage_scope_uat_v1(v_incident.role_id,v_incident.location_id) then raise exception 'ROLE_OR_LOCATION_SCOPE_FORBIDDEN'; end if;
  perform pg_advisory_xact_lock(hashtextextended('recovery:'||v_incident.month::text,0));
  select revision into v_revision from public.recovery_month_revisions_v2 where month=v_incident.month for update;
  if v_revision<>p_expected_revision then raise exception 'RECOVERY_REVISION_CONFLICT expected %, actual %',p_expected_revision,v_revision; end if;
  delete from public.recovery_actions_v2 where incident_id=v_incident.id and status in ('PROPOSED','OFFERED','DRAFT_READY');

  insert into public.recovery_actions_v2(incident_id,shift_id,source_assignment_id,role_id,duty_id,action_type,status,
    candidate_snapshot,risk_level,rule_warnings,currency)
  select v_incident.id,shift.id,assignment.id,assignment.role_id,
    (select duty.duty_id from public.plan_assignment_duties_v2 duty where duty.assignment_id=assignment.id order by duty.duty_id limit 1),
    'REPLACE_ASSIGNMENT',
    case when p_mode='SEND_OFFERS' then 'OFFERED' when p_mode='AUTO_DRAFT' then 'DRAFT_READY' else 'PROPOSED' end,
    solver_private.recovery_candidate_snapshot_uat_v1(v_incident.month,shift.id,assignment.role_id,
      (select duty.duty_id from public.plan_assignment_duties_v2 duty where duty.assignment_id=assignment.id order by duty.duty_id limit 1),
      assignment.employee_id),
    'MEDIUM',jsonb_build_array(jsonb_build_object('code','FINAL_SERVER_VALIDATION_REQUIRED','message','Przed publikacją serwer ponownie sprawdzi cały miesiąc, odpoczynek, limity i obowiązki.')),
    coalesce((select rate.currency from public.employee_pay_rates_v2 rate where rate.employee_id=assignment.employee_id and rate.active order by rate.valid_from desc limit 1),'PLN')
  from solver_private.recovery_published_variants_uat_v1(v_incident.month) published
  join public.plan_assignments_v2 assignment on assignment.variant_id=published.variant_id
  join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
  where v_incident.employee_id is not null and assignment.employee_id=v_incident.employee_id
    and shift.shift_date between v_incident.starts_on and v_incident.ends_on;
  get diagnostics v_actions=row_count;

  if v_incident.employee_id is null then
    insert into public.recovery_actions_v2(incident_id,shift_id,source_issue_id,role_id,duty_id,action_type,status,
      candidate_snapshot,risk_level,rule_warnings,currency)
    select v_incident.id,shift.id,issue.id,issue.role_id,issue.duty_id,'FILL_SHORTAGE',
      case when p_mode='SEND_OFFERS' then 'OFFERED' when p_mode='AUTO_DRAFT' then 'DRAFT_READY' else 'PROPOSED' end,
      solver_private.recovery_candidate_snapshot_uat_v1(v_incident.month,shift.id,issue.role_id,issue.duty_id,null),
      case when coalesce(issue.assigned_count,0)=0 then 'CRITICAL' else 'HIGH' end,
      jsonb_build_array(jsonb_build_object('code','PUBLISHED_SHORTAGE','message',
        case when coalesce(issue.assigned_count,0)=0
          then 'Na tej zmianie nie ma ani jednej osoby w wymaganej roli. Publikacja wymaga jawnej decyzji właściciela.'
          else 'Grafik pozostaje niekompletny. Każda propozycja przejdzie końcową kontrolę całego miesiąca.' end)),
      'PLN'
    from solver_private.recovery_published_variants_uat_v1(v_incident.month) published
    join public.plan_issues_v2 issue on issue.variant_id=published.variant_id and issue.issue_code='UNFILLED_SLOT'
    join public.plan_shifts_v2 shift on shift.id=issue.shift_id
    cross join lateral generate_series(1,greatest(coalesce(issue.required_count,0)-coalesce(issue.assigned_count,0),0)) missing_slot
    where shift.shift_date between v_incident.starts_on and v_incident.ends_on
      and (v_incident.role_id is null or issue.role_id=v_incident.role_id)
      and (v_incident.location_id is null or shift.location_id=v_incident.location_id)
      and solver_private.recovery_can_manage_scope_uat_v1(issue.role_id,shift.location_id);
    get diagnostics v_actions=row_count;
  end if;

  if p_mode='AUTO_DRAFT' then
    update public.recovery_actions_v2 action
    set selected_employee_id=(select (candidate->>'employeeId')::uuid
        from jsonb_array_elements(action.candidate_snapshot) candidate
        where coalesce((candidate->>'eligible')::boolean,false)
        order by (candidate->>'priority')::integer,candidate->>'name' limit 1),
      updated_at=now()
    where action.incident_id=v_incident.id and action.status='DRAFT_READY';
  end if;

  if p_mode='SEND_OFFERS' then
    insert into public.recovery_offer_responses_v2(action_id,employee_id,status,currency)
    select action.id,(candidate->>'employeeId')::uuid,'PENDING',action.currency
    from public.recovery_actions_v2 action cross join lateral jsonb_array_elements(action.candidate_snapshot) candidate
    where action.incident_id=v_incident.id and action.status='OFFERED'
      and coalesce((candidate->>'eligible')::boolean,false)
    on conflict(action_id,employee_id) do nothing;
    get diagnostics v_offers=row_count;
    insert into public.notifications(recipient_id,channel,title,body,sent_at)
    select employee.auth_user_id,'IN_APP','Propozycja dodatkowej zmiany',
      'Lider wysłał propozycję zastępstwa. Otwórz zakładkę Zamiany, aby odpowiedzieć.',now()
    from public.recovery_offer_responses_v2 response
    join public.employees employee on employee.id=response.employee_id
    join public.recovery_actions_v2 action on action.id=response.action_id
    where action.incident_id=v_incident.id and response.status='PENDING' and employee.auth_user_id is not null;
  end if;
  update public.recovery_incidents_v2 set status=case when p_mode='SEND_OFFERS' then 'OFFERING' else 'READY' end,
    repair_mode=p_mode,updated_by=v_actor,updated_at=now() where id=v_incident.id;
  update public.recovery_month_revisions_v2 set revision=revision+1,updated_by=v_actor,updated_at=now() where month=v_incident.month returning revision into v_revision;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'recovery_incident_v2',v_incident.id::text,'RECOVERY_PLAN_PREPARED',jsonb_build_object('mode',p_mode,'actions',v_actions,'offers',v_offers,'revision',v_revision));
  return jsonb_build_object('prepared',true,'actions',v_actions,'offers',v_offers,'revision',v_revision);
end;
$$;


ALTER FUNCTION "public"."recovery_incident_prepare_before_phase1_uat_v1"("p_incident_id" "uuid", "p_expected_revision" integer, "p_mode" "text") OWNER TO "postgres";

--
-- Name: recovery_incident_prepare_uat_v1("uuid", integer, "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."recovery_incident_prepare_uat_v1"("p_incident_id" "uuid", "p_expected_revision" integer, "p_mode" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_incident public.recovery_incidents_v2%rowtype;
begin
  select * into v_incident from public.recovery_incidents_v2 where id=p_incident_id;
  if v_incident.id is null then raise exception 'INCIDENT_NOT_FOUND'; end if;
  if not public.matrix_v2_can_manage_resource_uat_v1(
    v_incident.role_id,v_incident.location_id,v_incident.employee_id
  ) then raise exception 'RESOURCE_SCOPE_FORBIDDEN'; end if;
  perform authorization_private.enter_resource_scope_uat_v1();
  return public.recovery_incident_prepare_before_phase1_uat_v1(
    p_incident_id,p_expected_revision,p_mode
  );
end;
$$;


ALTER FUNCTION "public"."recovery_incident_prepare_uat_v1"("p_incident_id" "uuid", "p_expected_revision" integer, "p_mode" "text") OWNER TO "postgres";

--
-- Name: recovery_incident_rate_decide_uat_v1("uuid", boolean, bigint, "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."recovery_incident_rate_decide_uat_v1"("p_rate_id" "uuid", "p_approve" boolean, "p_approved_rate_minor" bigint, "p_reason" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare v_actor uuid:=auth.uid();v_rate public.recovery_incident_rate_revisions_v2%rowtype;
begin
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
  select * into v_rate from public.recovery_incident_rate_revisions_v2 where id=p_rate_id for update;
  if v_rate.id is null or v_rate.status<>'PROPOSED' then raise exception 'RATE_PROPOSAL_NOT_PENDING'; end if;
  if length(trim(coalesce(p_reason,'')))<5 then raise exception 'DECISION_REASON_REQUIRED'; end if;
  if p_approve and coalesce(p_approved_rate_minor,v_rate.proposed_rate_minor)<0 then raise exception 'INVALID_APPROVED_RATE'; end if;
  update public.recovery_incident_rate_revisions_v2 set status=case when p_approve then 'APPROVED' else 'REJECTED' end,
    approved_rate_minor=case when p_approve then coalesce(p_approved_rate_minor,proposed_rate_minor) end,
    approved_by=case when p_approve then v_actor end,approved_at=case when p_approve then now() end,decision_reason=trim(p_reason)
  where id=p_rate_id;
end $$;


ALTER FUNCTION "public"."recovery_incident_rate_decide_uat_v1"("p_rate_id" "uuid", "p_approve" boolean, "p_approved_rate_minor" bigint, "p_reason" "text") OWNER TO "postgres";

--
-- Name: recovery_incident_rate_propose_before_phase1_uat_v1("uuid", "uuid", bigint, "text", "date", "date", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."recovery_incident_rate_propose_before_phase1_uat_v1"("p_incident_id" "uuid", "p_employee_id" "uuid", "p_rate_minor" bigint, "p_currency" "text", "p_valid_from" "date", "p_valid_to" "date", "p_reason" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare v_actor uuid:=auth.uid();v_previous public.recovery_incident_rate_revisions_v2%rowtype;v_id uuid:=gen_random_uuid();v_revision integer:=1;
begin
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('ROLE_MANAGER') or public.has_app_role('LOCATION_MANAGER')) then raise exception 'FORBIDDEN'; end if;
  if p_rate_minor<0 or p_valid_to<p_valid_from or length(trim(coalesce(p_reason,'')))<5 then raise exception 'INVALID_RATE_PROPOSAL'; end if;
  select * into v_previous from public.recovery_incident_rate_revisions_v2 where incident_id=p_incident_id and employee_id=p_employee_id and status in ('PROPOSED','APPROVED') order by revision desc limit 1 for update;
  if v_previous.id is not null then update public.recovery_incident_rate_revisions_v2 set status='SUPERSEDED' where id=v_previous.id;v_revision:=v_previous.revision+1;end if;
  insert into public.recovery_incident_rate_revisions_v2(id,incident_id,employee_id,revision,supersedes_id,proposed_rate_minor,currency,valid_from,valid_to,proposal_reason,proposed_by)
  values(v_id,p_incident_id,p_employee_id,v_revision,v_previous.id,p_rate_minor,upper(p_currency),p_valid_from,p_valid_to,trim(p_reason),v_actor);
  return v_id;
end $$;


ALTER FUNCTION "public"."recovery_incident_rate_propose_before_phase1_uat_v1"("p_incident_id" "uuid", "p_employee_id" "uuid", "p_rate_minor" bigint, "p_currency" "text", "p_valid_from" "date", "p_valid_to" "date", "p_reason" "text") OWNER TO "postgres";

--
-- Name: recovery_incident_rate_propose_uat_v1("uuid", "uuid", bigint, "text", "date", "date", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."recovery_incident_rate_propose_uat_v1"("p_incident_id" "uuid", "p_employee_id" "uuid", "p_rate_minor" bigint, "p_currency" "text", "p_valid_from" "date", "p_valid_to" "date", "p_reason" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_incident public.recovery_incidents_v2%rowtype;
begin
  select * into v_incident from public.recovery_incidents_v2 where id=p_incident_id;
  if v_incident.id is null then raise exception 'INCIDENT_NOT_FOUND'; end if;
  if not public.matrix_v2_can_manage_resource_uat_v1(
    v_incident.role_id,v_incident.location_id,v_incident.employee_id
  ) or not public.matrix_v2_can_manage_resource_uat_v1(null,null,p_employee_id)
    then raise exception 'RESOURCE_SCOPE_FORBIDDEN'; end if;
  return public.recovery_incident_rate_propose_before_phase1_uat_v1(
    p_incident_id,p_employee_id,p_rate_minor,p_currency,p_valid_from,p_valid_to,p_reason
  );
end;
$$;


ALTER FUNCTION "public"."recovery_incident_rate_propose_uat_v1"("p_incident_id" "uuid", "p_employee_id" "uuid", "p_rate_minor" bigint, "p_currency" "text", "p_valid_from" "date", "p_valid_to" "date", "p_reason" "text") OWNER TO "postgres";

--
-- Name: recovery_incident_save_before_phase1_uat_v1("date", integer, "uuid", "uuid", "uuid", "uuid", "text", "date", "date", "text", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."recovery_incident_save_before_phase1_uat_v1"("p_month" "date", "p_expected_revision" integer, "p_incident_id" "uuid", "p_employee_id" "uuid", "p_role_id" "uuid", "p_location_id" "uuid", "p_incident_type" "text", "p_starts_on" "date", "p_ends_on" "date", "p_title" "text", "p_notes" "text", "p_mode" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid(); v_month date:=date_trunc('month',p_month)::date;
  v_revision integer; v_id uuid:=coalesce(p_incident_id,gen_random_uuid()); v_contract text;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  if not solver_private.recovery_can_manage_scope_uat_v1(p_role_id,p_location_id) then raise exception 'ROLE_OR_LOCATION_SCOPE_FORBIDDEN'; end if;
  if p_starts_on is null or p_ends_on is null or p_ends_on<p_starts_on
    or p_starts_on<v_month or p_ends_on>=(v_month+interval '1 month')::date then raise exception 'INVALID_INCIDENT_RANGE'; end if;
  if length(trim(coalesce(p_title,'')))<3 then raise exception 'INCIDENT_TITLE_REQUIRED'; end if;
  perform pg_advisory_xact_lock(hashtextextended('recovery:'||v_month::text,0));
  insert into public.recovery_month_revisions_v2(month,revision,updated_by)
    values(v_month,0,v_actor) on conflict(month) do nothing;
  select revision into v_revision from public.recovery_month_revisions_v2 where month=v_month for update;
  if v_revision<>coalesce(p_expected_revision,-1) then raise exception 'RECOVERY_REVISION_CONFLICT expected %, actual %',p_expected_revision,v_revision; end if;
  select rate.contract_type into v_contract from public.employee_pay_rates_v2 rate
    where rate.employee_id=p_employee_id and rate.active and rate.valid_from<=p_starts_on
      and (rate.valid_to is null or rate.valid_to>=p_starts_on) order by rate.valid_from desc limit 1;
  insert into public.recovery_incidents_v2(id,month,schedule_id,employee_id,role_id,location_id,incident_type,
    starts_on,ends_on,status,repair_mode,contract_type_snapshot,title,notes,base_revision,created_by,updated_by)
  values(v_id,v_month,(select id from public.published_schedules_v2 where month=v_month and status='PUBLISHED' order by published_at desc limit 1),
    p_employee_id,p_role_id,p_location_id,p_incident_type,p_starts_on,p_ends_on,'PROPOSED',p_mode,v_contract,trim(p_title),nullif(trim(coalesce(p_notes,'')),''),v_revision,v_actor,v_actor)
  on conflict(id) do update set employee_id=excluded.employee_id,role_id=excluded.role_id,location_id=excluded.location_id,
    incident_type=excluded.incident_type,starts_on=excluded.starts_on,ends_on=excluded.ends_on,
    repair_mode=excluded.repair_mode,title=excluded.title,notes=excluded.notes,
    contract_type_snapshot=excluded.contract_type_snapshot,updated_by=v_actor,updated_at=now();
  update public.recovery_month_revisions_v2 set revision=revision+1,updated_by=v_actor,updated_at=now() where month=v_month returning revision into v_revision;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'recovery_incident_v2',v_id::text,'RECOVERY_INCIDENT_SAVED',jsonb_build_object('month',v_month,'revision',v_revision,'mode',p_mode));
  return jsonb_build_object('saved',true,'id',v_id,'revision',v_revision);
end;
$$;


ALTER FUNCTION "public"."recovery_incident_save_before_phase1_uat_v1"("p_month" "date", "p_expected_revision" integer, "p_incident_id" "uuid", "p_employee_id" "uuid", "p_role_id" "uuid", "p_location_id" "uuid", "p_incident_type" "text", "p_starts_on" "date", "p_ends_on" "date", "p_title" "text", "p_notes" "text", "p_mode" "text") OWNER TO "postgres";

--
-- Name: recovery_incident_save_uat_v1("date", integer, "uuid", "uuid", "uuid", "uuid", "text", "date", "date", "text", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."recovery_incident_save_uat_v1"("p_month" "date", "p_expected_revision" integer, "p_incident_id" "uuid", "p_employee_id" "uuid", "p_role_id" "uuid", "p_location_id" "uuid", "p_incident_type" "text", "p_starts_on" "date", "p_ends_on" "date", "p_title" "text", "p_notes" "text", "p_mode" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_incident public.recovery_incidents_v2%rowtype;
begin
  if p_incident_id is not null then
    select * into v_incident from public.recovery_incidents_v2 where id=p_incident_id;
    if v_incident.id is null then raise exception 'INCIDENT_NOT_FOUND'; end if;
    if not public.matrix_v2_can_manage_resource_uat_v1(
      v_incident.role_id,v_incident.location_id,v_incident.employee_id
    ) then raise exception 'RESOURCE_SCOPE_FORBIDDEN'; end if;
  end if;
  if not public.matrix_v2_can_manage_resource_uat_v1(p_role_id,p_location_id,p_employee_id)
    then raise exception 'RESOURCE_SCOPE_FORBIDDEN'; end if;
  perform authorization_private.enter_resource_scope_uat_v1();
  return public.recovery_incident_save_before_phase1_uat_v1(
    p_month,p_expected_revision,p_incident_id,p_employee_id,p_role_id,p_location_id,
    p_incident_type,p_starts_on,p_ends_on,p_title,p_notes,p_mode
  );
end;
$$;


ALTER FUNCTION "public"."recovery_incident_save_uat_v1"("p_month" "date", "p_expected_revision" integer, "p_incident_id" "uuid", "p_employee_id" "uuid", "p_role_id" "uuid", "p_location_id" "uuid", "p_incident_type" "text", "p_starts_on" "date", "p_ends_on" "date", "p_title" "text", "p_notes" "text", "p_mode" "text") OWNER TO "postgres";

--
-- Name: recovery_month_budget_save_uat_v1("date", numeric, integer, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."recovery_month_budget_save_uat_v1"("p_month" "date", "p_amount" numeric, "p_warning_percent" integer, "p_hard_limit" boolean) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_actor uuid:=auth.uid(); v_month date:=date_trunc('month',p_month)::date;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'OWNER_REQUIRED'; end if;
  if p_amount<0 or p_warning_percent not between 1 and 100 then raise exception 'INVALID_BUDGET'; end if;
  insert into public.monthly_budgets(month,amount,warning_percent,hard_limit,updated_by,updated_at)
  values(v_month,p_amount,p_warning_percent,p_hard_limit,v_actor,now())
  on conflict(month) do update set amount=excluded.amount,warning_percent=excluded.warning_percent,
    hard_limit=excluded.hard_limit,updated_by=v_actor,updated_at=now();
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'monthly_budget',v_month::text,'MONTHLY_BUDGET_SAVED',jsonb_build_object('amount',p_amount,'warningPercent',p_warning_percent,'hardLimit',p_hard_limit));
  return jsonb_build_object('saved',true,'month',v_month);
end;
$$;


ALTER FUNCTION "public"."recovery_month_budget_save_uat_v1"("p_month" "date", "p_amount" numeric, "p_warning_percent" integer, "p_hard_limit" boolean) OWNER TO "postgres";

--
-- Name: recovery_offer_respond_uat_v1("uuid", boolean, "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."recovery_offer_respond_uat_v1"("p_response_id" "uuid", "p_accept" boolean, "p_message" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_actor uuid:=auth.uid(); v_employee uuid; v_response public.recovery_offer_responses_v2%rowtype;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select id into v_employee from public.employees where auth_user_id=v_actor and active limit 1;
  select * into v_response from public.recovery_offer_responses_v2 where id=p_response_id for update;
  if v_response.id is null or v_response.employee_id<>v_employee then raise exception 'OFFER_FORBIDDEN'; end if;
  if v_response.status<>'PENDING' then raise exception 'OFFER_ALREADY_DECIDED'; end if;
  update public.recovery_offer_responses_v2 set status=case when p_accept then 'ACCEPTED' else 'REJECTED' end,
    message=nullif(trim(coalesce(p_message,'')),''),responded_at=now() where id=v_response.id;
  if p_accept then update public.recovery_actions_v2 set selected_employee_id=v_employee,status='ACCEPTED',version=version+1,updated_at=now() where id=v_response.action_id and status='OFFERED'; end if;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'recovery_offer_v2',v_response.id::text,case when p_accept then 'OFFER_ACCEPTED' else 'OFFER_REJECTED' end,jsonb_build_object('message',p_message));
  return jsonb_build_object('saved',true,'accepted',p_accept);
end;
$$;


ALTER FUNCTION "public"."recovery_offer_respond_uat_v1"("p_response_id" "uuid", "p_accept" boolean, "p_message" "text") OWNER TO "postgres";

--
-- Name: recovery_override_save_uat_v1("uuid", "text", "uuid", "uuid", "date", "date", bigint, "text", "text", boolean, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."recovery_override_save_uat_v1"("p_incident_id" "uuid", "p_override_type" "text", "p_employee_id" "uuid", "p_role_id" "uuid", "p_starts_on" "date", "p_ends_on" "date", "p_numeric_value" bigint, "p_currency" "text", "p_justification" "text", "p_employee_acknowledged" boolean, "p_compliance_confirmed" boolean) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_actor uuid:=auth.uid(); v_incident public.recovery_incidents_v2%rowtype; v_id uuid:=gen_random_uuid();
  v_contract text;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into v_incident from public.recovery_incidents_v2 where id=p_incident_id;
  if v_incident.id is null then raise exception 'INCIDENT_NOT_FOUND'; end if;
  if not solver_private.recovery_can_manage_scope_uat_v1(coalesce(p_role_id,v_incident.role_id),v_incident.location_id) then raise exception 'ROLE_OR_LOCATION_SCOPE_FORBIDDEN'; end if;
  if p_ends_on<p_starts_on or p_starts_on<v_incident.starts_on or p_ends_on>v_incident.ends_on
    or length(trim(coalesce(p_justification,'')))<10 then raise exception 'INVALID_OVERRIDE'; end if;
  if p_override_type in ('WEEKLY_LIMIT','MONTHLY_LIMIT') and not coalesce(p_employee_acknowledged,false)
    then raise exception 'EMPLOYEE_ACKNOWLEDGEMENT_REQUIRED'; end if;
  if p_override_type in ('WEEKLY_LIMIT','MONTHLY_LIMIT') and p_employee_id is not null then
    select coalesce((select rate.contract_type from public.employee_pay_rates_v2 rate
      where rate.employee_id=p_employee_id and rate.active and rate.valid_from<=p_starts_on
        and (rate.valid_to is null or rate.valid_to>=p_starts_on)
      order by rate.valid_from desc limit 1),
      (select hr.contract_type from public.employee_hr_profiles hr where hr.employee_id=p_employee_id),'INNE')
    into v_contract;
    if v_contract in ('UMOWA_O_PRACE','CZESC_ETATU') and not coalesce(p_compliance_confirmed,false) then
      raise exception 'EMPLOYMENT_COMPLIANCE_CONFIRMATION_REQUIRED';
    end if;
  end if;
  insert into public.recovery_overrides_v2(id,incident_id,override_type,employee_id,role_id,starts_on,ends_on,
    numeric_value,currency,justification,employee_acknowledged,compliance_confirmed,status,approved_by,approved_at,created_by)
  values(v_id,p_incident_id,p_override_type,p_employee_id,p_role_id,p_starts_on,p_ends_on,p_numeric_value,p_currency,
    trim(p_justification),coalesce(p_employee_acknowledged,false),coalesce(p_compliance_confirmed,false),'APPROVED',v_actor,now(),v_actor);
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'recovery_override_v2',v_id::text,'TEMPORARY_OVERRIDE_APPROVED',jsonb_build_object('type',p_override_type,'value',p_numeric_value,'startsOn',p_starts_on,'endsOn',p_ends_on,'employeeAcknowledged',p_employee_acknowledged,'contractType',v_contract,'complianceConfirmed',p_compliance_confirmed));
  return jsonb_build_object('saved',true,'id',v_id);
end;
$$;


ALTER FUNCTION "public"."recovery_override_save_uat_v1"("p_incident_id" "uuid", "p_override_type" "text", "p_employee_id" "uuid", "p_role_id" "uuid", "p_starts_on" "date", "p_ends_on" "date", "p_numeric_value" bigint, "p_currency" "text", "p_justification" "text", "p_employee_acknowledged" boolean, "p_compliance_confirmed" boolean) OWNER TO "postgres";

--
-- Name: role_plan_assignment_delete("uuid", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."role_plan_assignment_delete"("p_section_id" "uuid", "p_assignment_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare sec role_plan_sections; r matrix_roles; begin
  select * into sec from role_plan_sections where id=p_section_id; select * into r from matrix_roles where id=sec.role_id;
  if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN') or exists(select 1 from user_permissions up where up.auth_user_id=auth.uid() and up.app_role='ROLE_MANAGER' and up.scope_role::text=r.code)) then raise exception 'ROLE_SCOPE_FORBIDDEN'; end if;
  if not exists(select 1 from role_plan_assignments where role_plan_section_id=p_section_id and assignment_id=p_assignment_id) then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
  delete from assignments where id=p_assignment_id;
  update role_plan_sections set status='READY',updated_at=now() where id=p_section_id;
  insert into audit_log(actor_id,entity_type,entity_id,action) values(auth.uid(),'role_plan_assignment',p_assignment_id::text,'DELETE');
  perform role_plan_refresh_conflicts(p_section_id);
end $$;


ALTER FUNCTION "public"."role_plan_assignment_delete"("p_section_id" "uuid", "p_assignment_id" "uuid") OWNER TO "postgres";

--
-- Name: role_plan_assignment_save("uuid", "uuid", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."role_plan_assignment_save"("p_section_id" "uuid", "p_assignment_id" "uuid", "p_data" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare sec role_plan_sections; r matrix_roles; loc locations; emp employees; old_shift shifts; target_shift uuid; ass uuid;
  work_day date; start_time time; end_time time; start_at timestamptz; end_at timestamptz; begin
  select * into sec from role_plan_sections where id=p_section_id;
  if sec.id is null then raise exception 'SECTION_NOT_FOUND'; end if;
  select * into r from matrix_roles where id=sec.role_id;
  if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN') or exists(
    select 1 from user_permissions up where up.auth_user_id=auth.uid() and up.app_role='ROLE_MANAGER' and up.scope_role::text=r.code
  )) then raise exception 'ROLE_SCOPE_FORBIDDEN'; end if;
  if sec.status not in ('DRAFT','READY','SUBMITTED') then raise exception 'SECTION_NOT_EDITABLE'; end if;
  select * into emp from employees where id=(p_data->>'employeeId')::uuid and active;
  if emp.id is null then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  if emp.primary_role::text<>r.code and not exists(select 1 from matrix_employee_roles mer where mer.employee_id=emp.id and mer.role_id=sec.role_id) then raise exception 'EMPLOYEE_ROLE_MISMATCH'; end if;
  select * into loc from locations where code::text=p_data->>'locationCode' and active;
  if loc.id is null then raise exception 'LOCATION_NOT_FOUND'; end if;
  work_day:=(p_data->>'date')::date; start_time:=(p_data->>'startsAt')::time; end_time:=(p_data->>'endsAt')::time;
  start_at:=((work_day+start_time) at time zone loc.timezone);
  end_at:=(((work_day+case when end_time<=start_time then 1 else 0 end)+end_time) at time zone loc.timezone);
  if p_assignment_id is not null then
    select s.* into old_shift from role_plan_assignments rp join assignments a on a.id=rp.assignment_id join shifts s on s.id=a.shift_id
    where rp.role_plan_section_id=p_section_id and a.id=p_assignment_id;
  end if;
  if old_shift.id is not null and old_shift.shift_date=work_day and old_shift.location_id=loc.id and old_shift.starts_at=start_at and old_shift.ends_at=end_at then
    target_shift:=old_shift.id;
  else
    insert into shifts(plan_id,location_id,shift_date,shift_code,starts_at,ends_at,status)
    values(sec.legacy_plan_id,loc.id,work_day,coalesce(nullif(p_data->>'shiftCode',''),'MANUAL'),start_at,end_at,'PLANNED') returning id into target_shift;
  end if;
  if p_assignment_id is null then
    insert into assignments(shift_id,employee_id,assigned_role,assigned_capability,assignment_type,cost,explanation)
    values(target_shift,emp.id,r.code::employee_role,nullif(p_data->>'capability',''),'MANUAL',round(emp.hourly_rate*public.shift_minutes(start_at,end_at)/60,2),jsonb_build_object('source','ROLE_MANAGER')) returning id into ass;
    insert into role_plan_assignments(role_plan_section_id,assignment_id) values(p_section_id,ass);
  else
    update assignments set shift_id=target_shift,employee_id=emp.id,assigned_capability=nullif(p_data->>'capability',''),assignment_type='MANUAL',
      cost=round(emp.hourly_rate*public.shift_minutes(start_at,end_at)/60,2),explanation=explanation||jsonb_build_object('editedBy',auth.uid(),'editedAt',now())
    where id=p_assignment_id returning id into ass;
  end if;
  update role_plan_sections set status='READY',updated_at=now() where id=p_section_id;
  insert into audit_log(actor_id,entity_type,entity_id,action,new_data) values(auth.uid(),'role_plan_assignment',ass::text,case when p_assignment_id is null then 'CREATE' else 'UPDATE' end,p_data);
  perform role_plan_refresh_conflicts(p_section_id);
  return jsonb_build_object('assignmentId',ass,'conflicts',(select count(*) from matrix_conflicts where role_plan_section_id=p_section_id and status='OPEN'));
end $$;


ALTER FUNCTION "public"."role_plan_assignment_save"("p_section_id" "uuid", "p_assignment_id" "uuid", "p_data" "jsonb") OWNER TO "postgres";

--
-- Name: role_plan_refresh_conflicts("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."role_plan_refresh_conflicts"("p_section_id" "uuid") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare n integer; role_code text; begin
  select mr.code into role_code from role_plan_sections rs join matrix_roles mr on mr.id=rs.role_id where rs.id=p_section_id;
  if role_code is null then raise exception 'SECTION_NOT_FOUND'; end if;
  if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN') or exists(
    select 1 from user_permissions up where up.auth_user_id=auth.uid() and up.app_role='ROLE_MANAGER' and up.scope_role::text=role_code
  )) then raise exception 'ROLE_SCOPE_FORBIDDEN'; end if;
  delete from matrix_conflicts where role_plan_section_id=p_section_id and status='OPEN';
  insert into matrix_conflicts(role_plan_section_id,employee_id,conflict_type,severity,work_date,message)
  select p_section_id,a.employee_id,'UNAVAILABLE','CRITICAL',s.shift_date,
    e.first_name||' '||e.last_name||' jest niedostępny/a tego dnia ('||coalesce(av.source,'GRAFIK_PRO')||').'
  from role_plan_assignments rpa join assignments a on a.id=rpa.assignment_id
  join shifts s on s.id=a.shift_id join employees e on e.id=a.employee_id
  join employee_availability av on av.employee_id=e.id and av.work_date=s.shift_date and not av.available
  where rpa.role_plan_section_id=p_section_id;
  insert into matrix_conflicts(role_plan_section_id,employee_id,conflict_type,severity,work_date,message)
  select distinct p_section_id,a1.employee_id,'OVERLAP','CRITICAL',s1.shift_date,
    e.first_name||' '||e.last_name||' ma nakładające się przydziały.'
  from role_plan_assignments r1 join assignments a1 on a1.id=r1.assignment_id join shifts s1 on s1.id=a1.shift_id
  join role_plan_assignments r2 on r2.role_plan_section_id=p_section_id join assignments a2 on a2.id=r2.assignment_id join shifts s2 on s2.id=a2.shift_id
  join employees e on e.id=a1.employee_id
  where r1.role_plan_section_id=p_section_id and a1.id<a2.id and a1.employee_id=a2.employee_id
    and tstzrange(s1.starts_at,s1.ends_at,'[)') && tstzrange(s2.starts_at,s2.ends_at,'[)');
  select count(*) into n from matrix_conflicts where role_plan_section_id=p_section_id and status='OPEN';
  return n;
end $$;


ALTER FUNCTION "public"."role_plan_refresh_conflicts"("p_section_id" "uuid") OWNER TO "postgres";

--
-- Name: role_plan_workspace("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."role_plan_workspace"("p_section_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare result jsonb; begin
  perform role_plan_refresh_conflicts(p_section_id);
  select jsonb_build_object(
    'assignments',coalesce((select jsonb_agg(jsonb_build_object(
      'id',a.id,'employeeId',e.id,'employeeNo',e.employee_no,'employeeName',e.first_name||' '||e.last_name,
      'date',s.shift_date,'startsAt',s.starts_at,'endsAt',s.ends_at,'shiftCode',s.shift_code,
      'location',l.name,'locationCode',l.code,'capability',a.assigned_capability,'manual',a.assignment_type='MANUAL'
    ) order by s.starts_at,e.last_name) from role_plan_assignments rp join assignments a on a.id=rp.assignment_id
      join shifts s on s.id=a.shift_id join employees e on e.id=a.employee_id join locations l on l.id=s.location_id
      where rp.role_plan_section_id=p_section_id),'[]'::jsonb),
    'issues',coalesce((select jsonb_agg(x order by x->>'date') from (
      select jsonb_build_object('id',mc.id,'type',mc.conflict_type,'severity',mc.severity,'date',mc.work_date,'message',mc.message) x
      from matrix_conflicts mc where mc.role_plan_section_id=p_section_id and mc.status='OPEN'
      union all
      select jsonb_build_object('id',pi.id,'type',pi.issue_type,'severity',pi.severity,'date',s.shift_date,'message',pi.message,'required',pi.required_count,'assigned',pi.assigned_count,
        'unavailable',coalesce((select jsonb_agg(jsonb_build_object('name',ue.first_name||' '||ue.last_name,'source',ua.source) order by ue.last_name)
          from employee_availability ua join employees ue on ue.id=ua.employee_id
          where ua.work_date=s.shift_date and not ua.available and ue.active and ue.primary_role::text=mr.code),'[]'::jsonb))
      from role_plan_sections rs join plan_issues pi on pi.plan_id=rs.legacy_plan_id left join shifts s on s.id=pi.shift_id
      join matrix_roles mr on mr.id=rs.role_id where rs.id=p_section_id and (pi.role is null or pi.role::text=mr.code) and pi.resolved_at is null
    ) q),'[]'::jsonb)
  ) into result;
  return result;
end $$;


ALTER FUNCTION "public"."role_plan_workspace"("p_section_id" "uuid") OWNER TO "postgres";

--
-- Name: schedule_publication_resolve_uat_v2("date", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."schedule_publication_resolve_uat_v2"("p_month" "date", "p_keep_source" "text", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_actor uuid:=auth.uid();
  v_month date:=date_trunc('month',p_month)::date;
  v_keep text:=upper(trim(coalesce(p_keep_source,'')));
  v_archived_company integer:=0;
  v_archived_roles integer:=0;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'PUBLICATION_RESOLUTION_OWNER_REQUIRED';
  end if;
  if v_keep not in ('COMPANY','ROLES') then
    raise exception 'INVALID_PUBLICATION_RESOLUTION';
  end if;
  if length(trim(coalesce(p_reason,'')))<5 then
    raise exception 'PUBLICATION_RESOLUTION_REASON_REQUIRED';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(
    'publish-v2-month:'||v_month::text,0
  ));
  if v_keep='COMPANY' then
    update public.published_role_schedules_v2 publication set
      status='ARCHIVED',archived_at=now(),archived_by=v_actor
    where publication.month=v_month and publication.status='PUBLISHED';
    get diagnostics v_archived_roles=row_count;
    if not exists(select 1 from public.published_schedules_v2 schedule
      where schedule.month=v_month and schedule.status='PUBLISHED') then
      raise exception 'COMPANY_PUBLICATION_NOT_FOUND';
    end if;
  else
    update public.published_schedules_v2 schedule set
      status='ARCHIVED',archived_at=now(),archived_by=v_actor
    where schedule.month=v_month and schedule.status='PUBLISHED';
    get diagnostics v_archived_company=row_count;
    if not exists(select 1 from public.published_role_schedules_v2 publication
      where publication.month=v_month and publication.status='PUBLISHED') then
      raise exception 'ROLE_PUBLICATIONS_NOT_FOUND';
    end if;
  end if;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'schedule_publication_authority_v2',v_month::text,'RESOLVE',
    jsonb_build_object(
      'keptSource',v_keep,'reason',trim(p_reason),
      'archivedCompanySchedules',v_archived_company,
      'archivedRoleSchedules',v_archived_roles
    ));
  return public.schedule_publication_status_uat_v2(v_month)||jsonb_build_object(
    'resolved',true,'keptSource',v_keep,
    'archivedCompanySchedules',v_archived_company,
    'archivedRoleSchedules',v_archived_roles
  );
end;
$$;


ALTER FUNCTION "public"."schedule_publication_resolve_uat_v2"("p_month" "date", "p_keep_source" "text", "p_reason" "text") OWNER TO "postgres";

--
-- Name: schedule_publication_resolve_with_standby_uat_v2("date", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."schedule_publication_resolve_with_standby_uat_v2"("p_month" "date", "p_keep_source" "text", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_result jsonb;
  v_standby integer;
begin
  v_result:=public.schedule_publication_resolve_uat_v2(
    p_month,p_keep_source,p_reason
  );
  v_standby:=solver_private.rebuild_standby_month_v2(p_month);
  return v_result||jsonb_build_object('standbyAssignments',v_standby);
end;
$$;


ALTER FUNCTION "public"."schedule_publication_resolve_with_standby_uat_v2"("p_month" "date", "p_keep_source" "text", "p_reason" "text") OWNER TO "postgres";

--
-- Name: schedule_publication_status_uat_v2("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."schedule_publication_status_uat_v2"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_month date:=date_trunc('month',p_month)::date;
  v_company public.published_schedules_v2%rowtype;
  v_conflicts jsonb:='[]'::jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select schedule.* into v_company
  from public.published_schedules_v2 schedule
  where schedule.month=v_month and schedule.status='PUBLISHED'
  order by schedule.published_at desc,schedule.id desc limit 1;
  if v_company.id is not null then
    select coalesce(jsonb_agg(jsonb_build_object(
      'roleId',role_schedule.role_id,'roleName',role.name,
      'roleScheduleId',role_schedule.id,'roleVariantId',role_schedule.variant_id,
      'companyScheduleId',v_company.id,'companySourceType',v_company.source_type,
      'reason',case
        when v_company.source_type='COMPANY' then 'COMPANY_AND_ROLE_ACTIVE'
        when not exists(select 1 from public.published_schedule_variants_v2 link
          where link.schedule_id=v_company.id and link.role_id=role_schedule.role_id
            and link.variant_id=role_schedule.variant_id)
          then 'ROLE_VARIANT_DIFFERS_FROM_COMPOSITE'
        else null end
    ) order by role.sort_order,role.name),'[]'::jsonb) into v_conflicts
    from public.published_role_schedules_v2 role_schedule
    join public.matrix_roles_v2 role on role.id=role_schedule.role_id
    where role_schedule.month=v_month and role_schedule.status='PUBLISHED'
      and (v_company.source_type='COMPANY' or not exists(
        select 1 from public.published_schedule_variants_v2 link
        where link.schedule_id=v_company.id and link.role_id=role_schedule.role_id
          and link.variant_id=role_schedule.variant_id
      ));
  end if;
  return jsonb_build_object(
    'month',v_month,'conflict',jsonb_array_length(v_conflicts)>0,
    'conflicts',v_conflicts,
    'company',case when v_company.id is null then null else jsonb_build_object(
      'id',v_company.id,'name',v_company.name,'sourceType',v_company.source_type,
      'publishedAt',v_company.published_at
    ) end,
    'roles',coalesce((select jsonb_agg(jsonb_build_object(
      'id',role_schedule.id,'roleId',role_schedule.role_id,
      'roleName',role.name,'variantId',role_schedule.variant_id,
      'name',role_schedule.name,'publishedAt',role_schedule.published_at
    ) order by role.sort_order,role.name)
      from public.published_role_schedules_v2 role_schedule
      join public.matrix_roles_v2 role on role.id=role_schedule.role_id
      where role_schedule.month=v_month and role_schedule.status='PUBLISHED'
    ),'[]'::jsonb)
  );
end;
$$;


ALTER FUNCTION "public"."schedule_publication_status_uat_v2"("p_month" "date") OWNER TO "postgres";

--
-- Name: FUNCTION "schedule_publication_status_uat_v2"("p_month" "date"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."schedule_publication_status_uat_v2"("p_month" "date") IS 'Reports competing publication sources; no timestamp or UI view silently chooses a winner.';


--
-- Name: shift_candidates("uuid", "public"."employee_role"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."shift_candidates"("p_shift_id" "uuid", "p_role" "public"."employee_role") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
with target as (
  select s.*,l.code location_code
  from public.shifts s join public.locations l on l.id=s.location_id
  where s.id=p_shift_id
), candidates as (
  select e.id,e.employee_no,e.first_name,e.last_name,e.primary_role,e.hourly_rate,
    el.standard_allowed,el.overtime_allowed,
    exists(select 1 from public.employee_capabilities ec
      where ec.employee_id=e.id and ec.active and ec.capability='CLOSE_SHIFT') can_close,
    not exists(select 1 from public.assignments a join public.shifts s on s.id=a.shift_id
      where a.employee_id=e.id and s.plan_id=(select plan_id from target)
        and tstzrange(s.starts_at,s.ends_at,'[)') &&
          tstzrange((select starts_at from target),(select ends_at from target),'[)')) no_overlap
  from public.employees e
  join public.employee_locations el on el.employee_id=e.id
    and el.location_id=(select location_id from target)
    and (el.standard_allowed or el.overtime_allowed)
  where e.active and e.primary_role=p_role
    and not exists(select 1 from public.assignments a
      where a.shift_id=p_shift_id and a.employee_id=e.id)
)
select coalesce(jsonb_agg(jsonb_build_object(
  'id',id,'employee_no',employee_no,'name',first_name||' '||last_name,
  'role',primary_role,'hourly_rate',hourly_rate,'can_close',can_close,
  'eligible',no_overlap,'overtime_only',(not standard_allowed and overtime_allowed)
) order by no_overlap desc,standard_allowed desc,employee_no),'[]'::jsonb)
from candidates
where public.can_manage_plans();
$$;


ALTER FUNCTION "public"."shift_candidates"("p_shift_id" "uuid", "p_role" "public"."employee_role") OWNER TO "postgres";

--
-- Name: shift_minutes(timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."shift_minutes"("p_start" timestamp with time zone, "p_end" timestamp with time zone) RETURNS integer
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$ select greatest(0, round(extract(epoch from (p_end - p_start)) / 60)::integer); $$;


ALTER FUNCTION "public"."shift_minutes"("p_start" timestamp with time zone, "p_end" timestamp with time zone) OWNER TO "postgres";

--
-- Name: shift_swap_board_uat_v2("date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."shift_swap_board_uat_v2"("p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_actor uuid:=auth.uid(); v_employee uuid;
  v_month date:=date_trunc('month',p_month)::date;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select employee.id into v_employee from public.employees employee
  where employee.auth_user_id=v_actor and employee.active
    and employee.archived_at is null order by employee.employee_no limit 1;
  return jsonb_build_object(
    'employeeId',v_employee,'month',v_month,'canManage',public.can_manage_plans(),
    'requests',coalesce((select jsonb_agg(jsonb_build_object(
      'id',request.id,'status',request.status,'message',request.message,
      'assignmentId',assignment.id,'date',shift.shift_date,
      'startsAt',shift.starts_at,'endsAt',shift.ends_at,
      'locationName',location.name,'shiftName',template.name,
      'roleId',request.role_id,'roleName',role.name,
      'proposerEmployeeId',request.proposer_employee_id,
      'proposerName',proposer.first_name||' '||proposer.last_name,
      'targetEmployeeId',request.target_employee_id,
      'targetName',case when target.id is null then null
        else target.first_name||' '||target.last_name end,
      'acceptedByEmployeeId',request.accepted_by_employee_id,
      'acceptedByName',case when accepted.id is null then null
        else accepted.first_name||' '||accepted.last_name end,
      'eligible',case when v_employee is null then false else cardinality(
        solver_private.swap_candidate_reasons_uat_v2(request.id,v_employee))=0 end,
      'ineligibilityReasons',case when v_employee is null then '[]'::jsonb
        else to_jsonb(solver_private.swap_candidate_reasons_uat_v2(
          request.id,v_employee)) end,
      'isMine',request.proposer_employee_id=v_employee,
      'requiresLeaderDecision',request.status='EMPLOYEE_ACCEPTED',
      'history',coalesce((select jsonb_agg(jsonb_build_object(
        'id',history.id,'action',history.action,'details',history.details,
        'createdAt',history.created_at,'actorName',coalesce(
          nullif(concat_ws(' ',actor_employee.first_name,actor_employee.last_name),''),
          actor_user.email,'System')
      ) order by history.created_at,history.id)
        from public.shift_swap_history_v2 history
        left join public.employees actor_employee
          on actor_employee.auth_user_id=history.actor_id
        left join auth.users actor_user on actor_user.id=history.actor_id
        where history.request_id=request.id),'[]'::jsonb)
    ) order by shift.starts_at,request.created_at)
      from public.shift_swap_requests_v2 request
      join public.plan_assignments_v2 assignment
        on assignment.id=request.original_assignment_id
      join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
      join public.matrix_locations_v2 location on location.id=shift.location_id
      join public.matrix_shift_templates_v2 template
        on template.id=shift.shift_template_id
      join public.matrix_roles_v2 role on role.id=request.role_id
      join public.matrix_employee_profiles_v2 proposer
        on proposer.matrix_version_id=request.matrix_version_id
        and proposer.employee_id=request.proposer_employee_id
      left join public.matrix_employee_profiles_v2 target
        on target.matrix_version_id=request.matrix_version_id
        and target.employee_id=request.target_employee_id
      left join public.matrix_employee_profiles_v2 accepted
        on accepted.matrix_version_id=request.matrix_version_id
        and accepted.employee_id=request.accepted_by_employee_id
      where request.month=v_month and (
        request.proposer_employee_id=v_employee
        or request.target_employee_id=v_employee
        or request.accepted_by_employee_id=v_employee
        or (request.status='OPEN' and v_employee is not null and cardinality(
          solver_private.swap_candidate_reasons_uat_v2(request.id,v_employee))=0)
        or public.can_manage_plans()
      )),'[]'::jsonb)
  );
end;
$$;


ALTER FUNCTION "public"."shift_swap_board_uat_v2"("p_month" "date") OWNER TO "postgres";

--
-- Name: shift_swap_candidates_uat_v2("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."shift_swap_candidates_uat_v2"("p_assignment_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_actor uuid:=auth.uid(); v_employee uuid;
  v_assignment public.plan_assignments_v2%rowtype;
  v_shift public.plan_shifts_v2%rowtype; v_matrix uuid;
  v_request_id uuid; v_preview boolean:=false; v_result jsonb;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select employee.id into v_employee from public.employees employee
  where employee.auth_user_id=v_actor and employee.active
    and employee.archived_at is null order by employee.employee_no limit 1;
  select * into v_assignment from public.plan_assignments_v2
    where id=p_assignment_id;
  if v_assignment.id is null then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
  if v_assignment.employee_id<>v_employee then raise exception 'NOT_OWN_ASSIGNMENT'; end if;
  if not solver_private.assignment_is_currently_published_v2(v_assignment.id)
    then raise exception 'ASSIGNMENT_NOT_PUBLISHED'; end if;
  select * into v_shift from public.plan_shifts_v2 where id=v_assignment.shift_id;
  if v_shift.starts_at<=now() then raise exception 'SHIFT_ALREADY_STARTED'; end if;
  select run.matrix_version_id into v_matrix from public.plan_variants_v2 variant
  join public.optimization_runs_v2 run on run.id=variant.run_id
  where variant.id=v_assignment.variant_id;
  select request.id into v_request_id from public.shift_swap_requests_v2 request
  where request.original_assignment_id=v_assignment.id
    and request.status in ('OPEN','EMPLOYEE_ACCEPTED') limit 1;
  if v_request_id is null then
    v_request_id:=gen_random_uuid(); v_preview:=true;
    insert into public.shift_swap_requests_v2(
      id,month,matrix_version_id,original_assignment_id,role_id,
      proposer_employee_id,created_by
    ) values(v_request_id,date_trunc('month',v_shift.shift_date)::date,v_matrix,
      v_assignment.id,v_assignment.role_id,v_employee,v_actor);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'employeeId',profile.employee_id,'employeeNo',profile.employee_no,
    'name',profile.first_name||' '||profile.last_name,
    'eligible',cardinality(candidate.reasons)=0,
    'reasons',to_jsonb(candidate.reasons)
  ) order by (cardinality(candidate.reasons)=0) desc,
    profile.last_name,profile.first_name),'[]'::jsonb)
  into v_result
  from public.matrix_employee_profiles_v2 profile
  join public.matrix_employee_roles_v2 role_grant
    on role_grant.matrix_version_id=profile.matrix_version_id
    and role_grant.employee_id=profile.employee_id
    and role_grant.role_id=v_assignment.role_id and role_grant.active
  cross join lateral (select solver_private.swap_candidate_reasons_uat_v2(
    v_request_id,profile.employee_id
  ) reasons) candidate
  where profile.matrix_version_id=v_matrix and profile.active
    and profile.archived_at is null;
  if v_preview then delete from public.shift_swap_requests_v2 where id=v_request_id; end if;
  return v_result;
end;
$$;


ALTER FUNCTION "public"."shift_swap_candidates_uat_v2"("p_assignment_id" "uuid") OWNER TO "postgres";

--
-- Name: shift_swap_employee_decide_uat_v2("uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."shift_swap_employee_decide_uat_v2"("p_request_id" "uuid", "p_decision" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_actor uuid:=auth.uid(); v_employee uuid; v_request public.shift_swap_requests_v2%rowtype;
  v_decision text:=upper(trim(coalesce(p_decision,''))); v_reasons text[];
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if v_decision not in ('ACCEPT','REJECT') then raise exception 'INVALID_SWAP_DECISION'; end if;
  select employee.id into v_employee from public.employees employee
  where employee.auth_user_id=v_actor and employee.active and employee.archived_at is null
  order by employee.employee_no limit 1;
  select * into v_request from public.shift_swap_requests_v2 where id=p_request_id for update;
  if v_request.id is null then raise exception 'SWAP_REQUEST_NOT_FOUND'; end if;
  if v_request.status<>'OPEN' then raise exception 'SWAP_REQUEST_NOT_OPEN'; end if;
  if v_request.target_employee_id is not null and v_request.target_employee_id<>v_employee
    then raise exception 'NOT_REQUEST_TARGET'; end if;
  if v_decision='REJECT' and v_request.target_employee_id is null
    then raise exception 'OPEN_BOARD_REQUEST_CANNOT_BE_REJECTED'; end if;
  if v_decision='ACCEPT' then
    v_reasons:=solver_private.swap_candidate_reasons_uat_v2(p_request_id,v_employee);
    if cardinality(v_reasons)>0 then raise exception 'SWAP_CANDIDATE_NOT_ELIGIBLE:%',
      array_to_string(v_reasons,','); end if;
    update public.shift_swap_requests_v2 set status='EMPLOYEE_ACCEPTED',
      accepted_by_employee_id=v_employee,employee_decided_at=now()
    where id=p_request_id;
    insert into public.notifications(recipient_id,title,body)
    select distinct recipient.auth_user_id,'Zamiana czeka na akceptację',
      'Pracownicy uzgodnili zamianę. Sprawdź ją i zaakceptuj albo odrzuć.'
    from (
      select grant_row.auth_user_id from public.matrix_scope_grants_v2 grant_row
      join public.matrix_roles_v2 role on role.logical_id=grant_row.role_logical_id
      where grant_row.active and grant_row.app_role='ROLE_MANAGER'
        and role.id=v_request.role_id
      union
      select permission.auth_user_id from public.user_permissions permission
      where permission.app_role in ('OWNER','ADMIN')
    ) recipient where recipient.auth_user_id is not null;
  else
    update public.shift_swap_requests_v2 set status='EMPLOYEE_REJECTED',
      employee_decided_at=now() where id=p_request_id;
  end if;
  insert into public.shift_swap_history_v2(request_id,actor_id,action)
  values(p_request_id,v_actor,v_decision);
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'shift_swap_v2',p_request_id::text,v_decision,
    jsonb_build_object('employeeId',v_employee));
  return jsonb_build_object('id',p_request_id,'status',
    case when v_decision='ACCEPT' then 'EMPLOYEE_ACCEPTED' else 'EMPLOYEE_REJECTED' end);
end;
$$;


ALTER FUNCTION "public"."shift_swap_employee_decide_uat_v2"("p_request_id" "uuid", "p_decision" "text") OWNER TO "postgres";

--
-- Name: shift_swap_leader_decide_before_phase1_uat_v1("uuid", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."shift_swap_leader_decide_before_phase1_uat_v1"("p_request_id" "uuid", "p_decision" "text", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_actor uuid:=auth.uid(); v_request public.shift_swap_requests_v2%rowtype;
  v_decision text:=upper(trim(coalesce(p_decision,''))); v_reasons text[];
  v_replacement uuid;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  if v_decision not in ('APPROVE','REJECT') then raise exception 'INVALID_SWAP_DECISION'; end if;
  if length(trim(coalesce(p_reason,'')))<3 then raise exception 'SWAP_REASON_REQUIRED'; end if;
  select * into v_request from public.shift_swap_requests_v2 where id=p_request_id for update;
  if v_request.id is null then raise exception 'SWAP_REQUEST_NOT_FOUND'; end if;
  if v_request.status<>'EMPLOYEE_ACCEPTED' then raise exception 'SWAP_NOT_READY_FOR_LEADER'; end if;
  if v_decision='APPROVE' then
    v_reasons:=solver_private.swap_candidate_reasons_uat_v2(
      p_request_id,v_request.accepted_by_employee_id);
    if cardinality(v_reasons)>0 then raise exception 'SWAP_REVALIDATION_FAILED:%',
      array_to_string(v_reasons,','); end if;
    v_replacement:=gen_random_uuid();
    insert into public.operational_assignment_replacements_v2(
      id,month,original_assignment_id,replacement_employee_id,reason,created_by
    ) values(v_replacement,v_request.month,v_request.original_assignment_id,
      v_request.accepted_by_employee_id,'Zamiana: '||trim(p_reason),v_actor);
    update public.shift_swap_requests_v2 set status='LEADER_APPROVED',
      leader_decided_by=v_actor,leader_decided_at=now(),leader_reason=trim(p_reason),
      replacement_id=v_replacement where id=p_request_id;
  else
    update public.shift_swap_requests_v2 set status='LEADER_REJECTED',
      leader_decided_by=v_actor,leader_decided_at=now(),leader_reason=trim(p_reason)
    where id=p_request_id;
  end if;
  insert into public.shift_swap_history_v2(request_id,actor_id,action,details)
  values(p_request_id,v_actor,'LEADER_'||v_decision,
    jsonb_build_object('reason',trim(p_reason),'replacementId',v_replacement));
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'shift_swap_v2',p_request_id::text,'LEADER_'||v_decision,
    jsonb_build_object('reason',trim(p_reason),'replacementId',v_replacement));
  insert into public.notifications(recipient_id,title,body)
  select distinct employee.auth_user_id,'Decyzja lidera o zamianie',
    case when v_decision='APPROVE' then 'Zamiana została zaakceptowana i jest widoczna w grafiku.'
      else 'Zamiana została odrzucona: '||trim(p_reason) end
  from public.employees employee where employee.id in (
    v_request.proposer_employee_id,v_request.accepted_by_employee_id)
    and employee.auth_user_id is not null;
  return jsonb_build_object('id',p_request_id,'status','LEADER_'||
    case when v_decision='APPROVE' then 'APPROVED' else 'REJECTED' end,
    'replacementId',v_replacement);
end;
$$;


ALTER FUNCTION "public"."shift_swap_leader_decide_before_phase1_uat_v1"("p_request_id" "uuid", "p_decision" "text", "p_reason" "text") OWNER TO "postgres";

--
-- Name: shift_swap_leader_decide_uat_v2("uuid", "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."shift_swap_leader_decide_uat_v2"("p_request_id" "uuid", "p_decision" "text", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_role uuid;v_location uuid;
begin
  select request.role_id,shift.location_id into v_role,v_location
  from public.shift_swap_requests_v2 request
  join public.plan_assignments_v2 assignment on assignment.id=request.original_assignment_id
  join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
  where request.id=p_request_id;
  if v_role is null or v_location is null then raise exception 'SWAP_REQUEST_NOT_FOUND'; end if;
  if not public.matrix_v2_can_manage_resource_uat_v1(v_role,v_location,null)
    then raise exception 'RESOURCE_SCOPE_FORBIDDEN'; end if;
  perform authorization_private.enter_resource_scope_uat_v1();
  return public.shift_swap_leader_decide_before_phase1_uat_v1(p_request_id,p_decision,p_reason);
end;
$$;


ALTER FUNCTION "public"."shift_swap_leader_decide_uat_v2"("p_request_id" "uuid", "p_decision" "text", "p_reason" "text") OWNER TO "postgres";

--
-- Name: shift_swap_request_create_uat_v2("uuid", "uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."shift_swap_request_create_uat_v2"("p_assignment_id" "uuid", "p_target_employee_id" "uuid" DEFAULT NULL::"uuid", "p_message" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_actor uuid:=auth.uid(); v_employee uuid; v_assignment public.plan_assignments_v2%rowtype;
  v_shift public.plan_shifts_v2%rowtype; v_matrix uuid; v_id uuid:=gen_random_uuid();
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select employee.id into v_employee from public.employees employee
  where employee.auth_user_id=v_actor and employee.active and employee.archived_at is null
  order by employee.employee_no limit 1;
  select * into v_assignment from public.plan_assignments_v2 where id=p_assignment_id;
  if v_assignment.id is null then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
  if v_assignment.employee_id<>v_employee then raise exception 'NOT_OWN_ASSIGNMENT'; end if;
  if not solver_private.assignment_is_currently_published_v2(v_assignment.id)
    then raise exception 'ASSIGNMENT_NOT_PUBLISHED'; end if;
  select * into v_shift from public.plan_shifts_v2 where id=v_assignment.shift_id;
  if v_shift.starts_at<=now() then raise exception 'SHIFT_ALREADY_STARTED'; end if;
  select run.matrix_version_id into v_matrix from public.plan_variants_v2 variant
  join public.optimization_runs_v2 run on run.id=variant.run_id
  where variant.id=v_assignment.variant_id;
  if p_target_employee_id is not null and cardinality(
      solver_private.swap_candidate_reasons_uat_v2(v_id,p_target_employee_id))>0 then
    -- Candidate validation runs after inserting the request below; this guard
    -- is intentionally completed after the insert.
    null;
  end if;
  insert into public.shift_swap_requests_v2(
    id,month,matrix_version_id,original_assignment_id,role_id,
    proposer_employee_id,target_employee_id,message,created_by
  ) values(v_id,date_trunc('month',v_shift.shift_date)::date,v_matrix,
    v_assignment.id,v_assignment.role_id,v_employee,p_target_employee_id,
    nullif(trim(p_message),''),v_actor);
  if p_target_employee_id is not null and cardinality(
      solver_private.swap_candidate_reasons_uat_v2(v_id,p_target_employee_id))>0 then
    raise exception 'SWAP_TARGET_NOT_ELIGIBLE:%',array_to_string(
      solver_private.swap_candidate_reasons_uat_v2(v_id,p_target_employee_id),',');
  end if;
  insert into public.shift_swap_history_v2(request_id,actor_id,action,details)
  values(v_id,v_actor,'CREATED',jsonb_build_object('targetEmployeeId',p_target_employee_id));
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'shift_swap_v2',v_id::text,'CREATE',jsonb_build_object(
    'assignmentId',v_assignment.id,'targetEmployeeId',p_target_employee_id));
  if p_target_employee_id is not null then
    insert into public.notifications(recipient_id,title,body)
    select target.auth_user_id,'Propozycja zamiany zmiany',
      'Otrzymujesz propozycję przejęcia zmiany '||v_shift.shift_date::text||'.'
    from public.employees target where target.id=p_target_employee_id
      and target.auth_user_id is not null;
  end if;
  return v_id;
end;
$$;


ALTER FUNCTION "public"."shift_swap_request_create_uat_v2"("p_assignment_id" "uuid", "p_target_employee_id" "uuid", "p_message" "text") OWNER TO "postgres";

--
-- Name: solver_claim_next_v2("text", "text", integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."solver_claim_next_v2"("p_worker_id" "text", "p_worker_version" "text", "p_task_attempt" integer, "p_lease_seconds" integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_message_id bigint;
  v_message jsonb;
  v_run_id uuid;
  v_run public.optimization_runs_v2%rowtype;
  v_attempt_id uuid;
  v_lease_token uuid;
  v_attempt_number integer;
  v_lease_expires_at timestamptz;
  v_execution_name text;
  v_scan_count integer:=0;
  v_version_mismatch boolean:=false;
begin
  if length(trim(coalesce(p_worker_id,''))) not between 3 and 200
    or trim(p_worker_id) !~ '^[A-Za-z0-9._:@/-]+$'
  then raise exception 'INVALID_WORKER_ID'; end if;
  if length(trim(coalesce(p_worker_version,''))) not between 1 and 200
    or trim(p_worker_version) !~ '^[A-Za-z0-9._:+/-]+$'
  then raise exception 'INVALID_WORKER_VERSION'; end if;
  if coalesce(p_task_attempt,0) not between 1 and 20 then
    raise exception 'INVALID_TASK_ATTEMPT';
  end if;
  if coalesce(p_lease_seconds,0) not between 30 and 900 then
    raise exception 'INVALID_LEASE_SECONDS';
  end if;

  perform solver_private.lock_planning_revision_v2();

  loop
    v_scan_count:=v_scan_count+1;
    v_message_id:=null;
    v_message:=null;

    select queue_row.msg_id,queue_row.message
    into v_message_id,v_message
    from pgmq.read('schedule_optimizer_v2',p_lease_seconds,1) queue_row
    limit 1;

    if v_message_id is null then
      return jsonb_build_object(
        'claimed',false,
        'status',case when v_version_mismatch
          then 'VERSION_MISMATCH' else 'EMPTY' end
      );
    end if;
    if coalesce(v_message->>'runId','') !~*
      '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    then
      perform pgmq.archive('schedule_optimizer_v2',v_message_id);
      if v_scan_count<20 then continue; end if;
      return jsonb_build_object('claimed',false,'status','EMPTY');
    end if;

    v_run_id:=(v_message->>'runId')::uuid;
    select * into v_run
    from public.optimization_runs_v2
    where id=v_run_id
    for update;

    if v_run.id is null
      or v_run.status not in ('QUEUED','CANCEL_REQUESTED')
      or v_run.queue_message_id is distinct from v_message_id
    then
      perform pgmq.archive('schedule_optimizer_v2',v_message_id);
      if v_scan_count<20 then continue; end if;
      return jsonb_build_object('claimed',false,'status','EMPTY');
    end if;

    if v_run.solver_version is distinct from trim(p_worker_version) then
      perform pgmq.set_vt('schedule_optimizer_v2',v_message_id,60);
      v_version_mismatch:=true;
      if v_scan_count<20 then continue; end if;
      return jsonb_build_object(
        'claimed',false,'status','VERSION_MISMATCH'
      );
    end if;

    if v_run.status='CANCEL_REQUESTED' then
      perform pgmq.archive('schedule_optimizer_v2',v_message_id);
      perform solver_private.reset_retry_outputs_v2(v_run.id);
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
      if v_scan_count<20 then continue; end if;
      return jsonb_build_object('claimed',false,'status','EMPTY');
    end if;

    if v_run.attempt_count>=v_run.max_attempts then
      perform pgmq.archive('schedule_optimizer_v2',v_message_id);
      perform solver_private.reset_retry_outputs_v2(v_run.id);
      update public.optimization_run_strategies_v2
      set status='FAILED',phase='FAILED',progress=0,metrics='{}'::jsonb,
        failure_code='MAX_ATTEMPTS',finished_at=now(),updated_at=now()
      where run_id=v_run.id;
      update public.optimization_runs_v2
      set status='FAILED',phase='FAILED',progress=0,queue_message_id=null,
        failure_code='MAX_ATTEMPTS',
        failure_message='Przekroczono limit prób solvera.',
        lease_owner=null,lease_token=null,lease_expires_at=null,
        worker_execution_name=null,heartbeat_at=null,
        finished_at=now(),updated_at=now()
      where id=v_run.id;
      if v_scan_count<20 then continue; end if;
      return jsonb_build_object('claimed',false,'status','EMPTY');
    end if;

    perform solver_private.reset_retry_outputs_v2(v_run.id);
    update solver_private.optimization_attempts_v2
    set status='LEASE_LOST',finished_at=now(),heartbeat_at=now(),
      error_code='LEASE_EXPIRED',
      error_message='Poprzednia próba utraciła dzierżawę.'
    where run_id=v_run.id and status='RUNNING';

    v_attempt_id:=gen_random_uuid();
    v_lease_token:=gen_random_uuid();
    v_attempt_number:=v_run.attempt_count+1;
    v_lease_expires_at:=now()+make_interval(secs=>p_lease_seconds);
    v_execution_name:=left(
      'pull/'||trim(p_worker_id)||'/'||v_run.id::text||'/'||
        v_attempt_number::text,
      500
    );

    insert into solver_private.optimization_attempts_v2(
      id,run_id,attempt_number,task_attempt,worker_id,worker_version,
      worker_execution_name,lease_token,status
    ) values(
      v_attempt_id,v_run.id,v_attempt_number,p_task_attempt,trim(p_worker_id),
      trim(p_worker_version),v_execution_name,v_lease_token,'RUNNING'
    );

    update public.optimization_runs_v2
    set status='RUNNING',phase='CLAIMED',progress=greatest(progress,1),
      attempt_count=v_attempt_number,queue_message_id=null,
      lease_owner=trim(p_worker_id),lease_token=v_lease_token,
      lease_expires_at=v_lease_expires_at,
      worker_execution_name=v_execution_name,heartbeat_at=now(),
      started_at=coalesce(started_at,now()),finished_at=null,
      failure_code=null,failure_message=null,updated_at=now()
    where id=v_run.id;
    update public.optimization_run_strategies_v2
    set status='RUNNING',phase='CLAIMED',progress=1,metrics='{}'::jsonb,
      started_at=coalesce(started_at,now()),finished_at=null,
      failure_code=null,updated_at=now()
    where run_id=v_run.id;

    perform pgmq.archive('schedule_optimizer_v2',v_message_id);
    return jsonb_build_object(
      'claimed',true,'runId',v_run.id,'attemptId',v_attempt_id,
      'attemptNumber',v_attempt_number,'leaseToken',v_lease_token,
      'leaseExpiresAt',v_lease_expires_at,
      'snapshotHash',v_run.snapshot_hash,
      'solverVersion',v_run.solver_version
    );
  end loop;
end;
$_$;


ALTER FUNCTION "public"."solver_claim_next_v2"("p_worker_id" "text", "p_worker_version" "text", "p_task_attempt" integer, "p_lease_seconds" integer) OWNER TO "postgres";

--
-- Name: FUNCTION "solver_claim_next_v2"("p_worker_id" "text", "p_worker_version" "text", "p_task_attempt" integer, "p_lease_seconds" integer); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."solver_claim_next_v2"("p_worker_id" "text", "p_worker_version" "text", "p_task_attempt" integer, "p_lease_seconds" integer) IS 'Atomically claims one version-compatible PGMQ run for a provider-neutral worker.';


--
-- Name: solver_claim_run_v2("uuid", "uuid", "text", "text", integer, integer, "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."solver_claim_run_v2"("p_target_run_id" "uuid", "p_dispatch_nonce" "uuid", "p_worker_id" "text", "p_worker_version" "text", "p_task_attempt" integer, "p_lease_seconds" integer, "p_gateway_version" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_run public.optimization_runs_v2%rowtype;
  v_outbox solver_private.solver_job_dispatch_outbox_uat_v1%rowtype;
  v_attempt_id uuid;
  v_lease_token uuid;
  v_attempt_number integer;
  v_lease_expires_at timestamptz;
  v_execution_name text;
  v_stamp jsonb;
begin
  if length(trim(coalesce(p_worker_id,''))) not between 3 and 200
    or trim(p_worker_id) !~ '^[A-Za-z0-9._:@/-]+$' then
    raise exception 'INVALID_WORKER_ID';
  end if;
  if length(trim(coalesce(p_worker_version,''))) not between 1 and 200
    or trim(p_worker_version) !~ '^[A-Za-z0-9._:+/-]+$' then
    raise exception 'INVALID_WORKER_VERSION';
  end if;
  if coalesce(p_task_attempt,0) not between 1 and 20 then
    raise exception 'INVALID_TASK_ATTEMPT';
  end if;
  if coalesce(p_lease_seconds,0) not between 30 and 900 then
    raise exception 'INVALID_LEASE_SECONDS';
  end if;
  if length(coalesce(p_gateway_version,'')) not between 1 and 500
    or p_gateway_version !~ '^[A-Za-z0-9][A-Za-z0-9._:@/-]*$' then
    raise exception 'GATEWAY_VERSION_INVALID';
  end if;

  perform solver_private.lock_planning_revision_v2();
  select * into v_outbox
  from solver_private.solver_job_dispatch_outbox_uat_v1
  where run_id=p_target_run_id for update;
  if v_outbox.run_id is null then
    return jsonb_build_object('claimed',false,'status','TARGET_NOT_FOUND');
  end if;
  if v_outbox.dispatch_nonce is distinct from p_dispatch_nonce then
    raise exception 'TARGET_CAPABILITY_INVALID';
  end if;
  select * into v_run from public.optimization_runs_v2
  where id=p_target_run_id for update;
  if v_run.id is null then
    return jsonb_build_object('claimed',false,'status','TARGET_NOT_FOUND');
  end if;
  if v_run.status in ('READY','FAILED','CANCELLED','STALE_INPUT') then
    return jsonb_build_object(
      'claimed',false,'status','TARGET_TERMINAL','runStatus',v_run.status
    );
  end if;
  if v_outbox.dispatch_status not in (
    'ACCEPTANCE_UNKNOWN','ACCEPTED','STARTING','RUNNING'
  ) then
    return jsonb_build_object('claimed',false,'status','TARGET_NOT_DISPATCHED');
  end if;
  if v_run.status='RUNNING' and v_run.lease_expires_at>now() then
    return jsonb_build_object('claimed',false,'status','CONFLICT');
  end if;
  if v_run.solver_version is distinct from trim(p_worker_version) then
    return jsonb_build_object('claimed',false,'status','VERSION_MISMATCH');
  end if;
  if v_run.status='CANCEL_REQUESTED' then
    if v_run.queue_message_id is not null then
      perform pgmq.archive('schedule_optimizer_v2',v_run.queue_message_id);
    end if;
    perform solver_private.reset_retry_outputs_v2(v_run.id);
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
    update solver_private.solver_job_dispatch_outbox_uat_v1
    set dispatch_status='CANCELLED',job_finished_at=now(),updated_at=now()
    where run_id=v_run.id;
    return jsonb_build_object('claimed',false,'status','CANCELLED');
  end if;
  if v_run.attempt_count>=v_run.max_attempts then
    update public.optimization_runs_v2
    set status='FAILED',phase='FAILED',failure_code='MAX_ATTEMPTS',
      failure_message='Przekroczono limit prób solvera.',
      finished_at=now(),updated_at=now()
    where id=v_run.id;
    update solver_private.solver_job_dispatch_outbox_uat_v1
    set dispatch_status='FAILED',last_error_code='MAX_ATTEMPTS',
      job_finished_at=now(),updated_at=now()
    where run_id=v_run.id;
    return jsonb_build_object('claimed',false,'status','MAX_ATTEMPTS');
  end if;

  if v_run.queue_message_id is not null then
    perform pgmq.archive('schedule_optimizer_v2',v_run.queue_message_id);
  end if;
  perform solver_private.reset_retry_outputs_v2(v_run.id);
  update solver_private.optimization_attempts_v2
  set status='LEASE_LOST',finished_at=now(),heartbeat_at=now(),
    error_code='LEASE_EXPIRED',
    error_message='Poprzednia próba utraciła dzierżawę.'
  where run_id=v_run.id and status='RUNNING';

  v_attempt_id:=gen_random_uuid();
  v_lease_token:=gen_random_uuid();
  v_attempt_number:=v_run.attempt_count+1;
  v_lease_expires_at:=now()+make_interval(secs=>p_lease_seconds);
  v_execution_name:=left(
    'northflank-job/'||trim(p_worker_id)||'/'||v_run.id::text||'/'||
      v_attempt_number::text,500
  );
  insert into solver_private.optimization_attempts_v2(
    id,run_id,attempt_number,task_attempt,worker_id,worker_version,
    worker_execution_name,lease_token,status
  ) values(
    v_attempt_id,v_run.id,v_attempt_number,p_task_attempt,trim(p_worker_id),
    trim(p_worker_version),v_execution_name,v_lease_token,'RUNNING'
  );

  v_stamp:=solver_private.version_stamp_set_once_uat_v1(
    v_run.version_stamp,'gatewayVersion',to_jsonb(p_gateway_version)
  );
  v_stamp:=jsonb_set(
    v_stamp,'{gateway}',jsonb_build_object('deploymentId',p_gateway_version),true
  );
  update public.optimization_runs_v2
  set status='RUNNING',phase='CLAIMED',progress=greatest(progress,1),
    attempt_count=v_attempt_number,queue_message_id=null,
    lease_owner=trim(p_worker_id),lease_token=v_lease_token,
    lease_expires_at=v_lease_expires_at,
    worker_execution_name=v_execution_name,heartbeat_at=now(),
    started_at=coalesce(started_at,now()),finished_at=null,
    failure_code=null,failure_message=null,version_stamp=v_stamp,updated_at=now()
  where id=v_run.id;
  update public.optimization_run_strategies_v2
  set status='RUNNING',phase='CLAIMED',progress=1,metrics='{}'::jsonb,
    started_at=coalesce(started_at,now()),finished_at=null,
    failure_code=null,updated_at=now()
  where run_id=v_run.id;
  update solver_private.solver_job_dispatch_outbox_uat_v1
  set dispatch_status='RUNNING',
    container_started_at=coalesce(container_started_at,now()),
    worker_claimed_at=coalesce(worker_claimed_at,now()),updated_at=now()
  where run_id=v_run.id;

  return jsonb_build_object(
    'claimed',true,'runId',v_run.id,'attemptId',v_attempt_id,
    'attemptNumber',v_attempt_number,'leaseToken',v_lease_token,
    'leaseExpiresAt',v_lease_expires_at,'snapshotHash',v_run.snapshot_hash,
    'solverVersion',v_run.solver_version,'executionMode','JOB'
  );
end;
$_$;


ALTER FUNCTION "public"."solver_claim_run_v2"("p_target_run_id" "uuid", "p_dispatch_nonce" "uuid", "p_worker_id" "text", "p_worker_version" "text", "p_task_attempt" integer, "p_lease_seconds" integer, "p_gateway_version" "text") OWNER TO "postgres";

--
-- Name: FUNCTION "solver_claim_run_v2"("p_target_run_id" "uuid", "p_dispatch_nonce" "uuid", "p_worker_id" "text", "p_worker_version" "text", "p_task_attempt" integer, "p_lease_seconds" integer, "p_gateway_version" "text"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."solver_claim_run_v2"("p_target_run_id" "uuid", "p_dispatch_nonce" "uuid", "p_worker_id" "text", "p_worker_version" "text", "p_task_attempt" integer, "p_lease_seconds" integer, "p_gateway_version" "text") IS 'Capability-bound atomic target claim for one Northflank Job generation; never scans or falls back.';


--
-- Name: solver_contract_parity_probe_uat_v1("jsonb", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."solver_contract_parity_probe_uat_v1"("p_variant_templates" "jsonb", "p_gateway_version" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_source_run public.optimization_runs_v2%rowtype;
  v_source_snapshot jsonb;
  v_snapshot jsonb;
  v_snapshot_hash text;
  v_solution_hash text;
  v_run_id uuid:=gen_random_uuid();
  v_attempt_id uuid:=gen_random_uuid();
  v_lease_token uuid:=gen_random_uuid();
  v_strategy jsonb;
  v_template jsonb;
  v_variant jsonb;
  v_results jsonb:='[]'::jsonb;
  v_saved jsonb;
  v_index integer:=0;
  v_slot_ids jsonb;
  v_slot_count integer;
  v_stamp jsonb;
  v_rolled_back boolean:=false;
begin
  if jsonb_typeof(p_variant_templates)<>'array'
    or jsonb_array_length(p_variant_templates)<>3 then
    raise exception 'CONTRACT_VARIANT_TEMPLATES_REQUIRED';
  end if;
  if length(coalesce(p_gateway_version,'')) not between 1 and 500 then
    raise exception 'GATEWAY_VERSION_INVALID';
  end if;

  begin
    select r.* into v_source_run
    from public.optimization_runs_v2 r
    join solver_private.optimization_snapshots_v2 s on s.run_id=r.id
    where jsonb_array_length(coalesce(s.snapshot->'strategies','[]'::jsonb))=3
      and jsonb_array_length(coalesce(s.snapshot->'slots','[]'::jsonb))>0
    order by r.created_at desc limit 1;
    if v_source_run.id is null then raise exception 'CONTRACT_SOURCE_MISSING'; end if;

    select s.snapshot into v_source_snapshot
    from solver_private.optimization_snapshots_v2 s
    where s.run_id=v_source_run.id;

    v_snapshot:=jsonb_set(
      v_source_snapshot,'{runId}',to_jsonb(v_run_id::text),true
    );
    -- The result is fully synthetic: no employee is assigned and every slot is
    -- explicitly unfilled. Structural Matrix identifiers are only borrowed so
    -- the real FK/materialization boundary is exercised before rollback.
    v_snapshot:=jsonb_set(v_snapshot,'{employees}','[]'::jsonb,true);
    v_snapshot:=jsonb_set(v_snapshot,'{baselineAssignments}','[]'::jsonb,true);
    v_snapshot:=jsonb_set(v_snapshot,'{lockedAssignments}','[]'::jsonb,true);
    v_snapshot_hash:=encode(extensions.digest(convert_to(
      solver_private.canonical_json_v2(v_snapshot),'UTF8'
    ),'sha256'),'hex');
    select jsonb_agg(to_jsonb(slot.value->>'slotId') order by slot.ordinality),
      count(*)
    into v_slot_ids,v_slot_count
    from jsonb_array_elements(v_snapshot->'slots')
      with ordinality slot(value,ordinality);

    with slots as (
      select value->>'slotId' slot_id
      from jsonb_array_elements(v_snapshot->'slots')
    ), selected_map as (
      select jsonb_object_agg(
        slot_id,to_jsonb(null::text) order by slot_id
      ) payload from slots
    )
    select encode(extensions.digest(convert_to(
      solver_private.canonical_json_v2(payload),'UTF8'
    ),'sha256'),'hex') into v_solution_hash
    from selected_map;

    insert into public.optimization_runs_v2(
      id,idempotency_key,month,matrix_version_id,scenario_id,scope_type,
      scope_role_id,name,status,phase,progress,requested_by,
      snapshot_schema_version,snapshot_hash,solver_version,request_engine,
      attempt_count,max_attempts,lease_owner,lease_token,lease_expires_at,
      worker_execution_name,heartbeat_at,started_at
    ) values(
      v_run_id,'contract-'||v_run_id::text,v_source_run.month,
      v_source_run.matrix_version_id,v_source_run.scenario_id,
      v_source_run.scope_type,v_source_run.scope_role_id,
      'Synthetic contract parity rollback','RUNNING','CLAIMED',1,
      v_source_run.requested_by,v_source_run.snapshot_schema_version,
      v_snapshot_hash,v_source_run.solver_version,'ORTOOLS_V2',1,3,
      'contract-parity-worker',v_lease_token,now()+interval '5 minutes',
      'contract-parity/'||v_run_id::text,now(),now()
    );
    insert into solver_private.optimization_snapshots_v2(
      run_id,schema_version,snapshot_hash,snapshot
    ) values(
      v_run_id,v_source_run.snapshot_schema_version,v_snapshot_hash,v_snapshot
    );
    insert into solver_private.optimization_attempts_v2(
      id,run_id,attempt_number,task_attempt,worker_id,worker_version,
      worker_execution_name,lease_token,status
    ) values(
      v_attempt_id,v_run_id,1,1,'contract-parity-worker',
      v_source_run.solver_version,'contract-parity/'||v_run_id::text,
      v_lease_token,'RUNNING'
    );
    insert into public.optimization_run_strategies_v2(
      run_id,strategy_id,ordinal,status,phase,progress,started_at
    )
    select v_run_id,(item.value->>'id')::uuid,item.ordinality,
      'RUNNING','CLAIMED',1,now()
    from jsonb_array_elements(v_snapshot->'strategies')
      with ordinality item(value,ordinality);

    v_stamp:=solver_private.build_run_version_stamp_uat_v1(
      v_run_id,'contract-parity-synthetic','SERVICE'
    );
    update public.optimization_runs_v2
    set version_stamp=v_stamp where id=v_run_id;

    for v_strategy in
      select item.value
      from jsonb_array_elements(v_snapshot->'strategies')
        with ordinality item(value,ordinality)
      order by item.ordinality
    loop
      v_index:=v_index+1;
      v_template:=p_variant_templates->(v_index-1);
      v_variant:=v_template||jsonb_build_object(
        'schemaVersion',2,
        'strategyId',v_strategy->>'id',
        'strategyCode',v_strategy->>'code',
        'label',coalesce(v_strategy->>'label',v_strategy->>'code'),
        'sortOrder',coalesce((v_strategy->>'sortOrder')::integer,v_index),
        'assignments','[]'::jsonb,
        'unfilledSlotIds',coalesce(v_slot_ids,'[]'::jsonb),
        'metrics',coalesce(v_template->'metrics','{}'::jsonb)||
          jsonb_build_object('UNFILLED',v_slot_count,'TOTAL_COST',0),
        'solutionHash',v_solution_hash,
        'equivalentToStrategyId',null
      );
      v_saved:=public.solver_save_variant_v2(
        v_run_id,v_attempt_id,v_lease_token,v_variant,p_gateway_version
      );
      v_results:=v_results||jsonb_build_array(jsonb_build_object(
        'strategyCode',v_strategy->>'code',
        'variantId',v_saved->>'variantId',
        'stageCount',v_saved->'stageCount',
        'versionStamp',v_saved->'versionStamp',
        'cost',(
          select jsonb_build_object(
            'totalCostMinor',f.total_cost_minor,
            'budgetMinor',f.budget_minor,'currency',f.currency
          )
          from solver_private.plan_variant_finance_v2 f
          where f.variant_id=(v_saved->>'variantId')::uuid
        ),
        'metrics',(
          select pv.metrics from public.plan_variants_v2 pv
          where pv.id=(v_saved->>'variantId')::uuid
        ),
        'stageProof',(
          select pv.stage_proof from public.plan_variants_v2 pv
          where pv.id=(v_saved->>'variantId')::uuid
        )
      ));
    end loop;
    if jsonb_array_length(v_results)<>3 then
      raise exception 'CONTRACT_VARIANT_COUNT_INVALID';
    end if;
    raise exception 'CONTRACT_PARITY_ROLLBACK';
  exception
    when raise_exception then
      if sqlerrm<>'CONTRACT_PARITY_ROLLBACK' then raise; end if;
      v_rolled_back:=true;
  end;

  if exists(select 1 from public.optimization_runs_v2 where id=v_run_id) then
    raise exception 'CONTRACT_ROLLBACK_FAILED';
  end if;
  return jsonb_build_object(
    'passed',v_rolled_back,'rolledBack',v_rolled_back,
    'syntheticRunId',v_run_id,'variants',v_results
  );
end;
$$;


ALTER FUNCTION "public"."solver_contract_parity_probe_uat_v1"("p_variant_templates" "jsonb", "p_gateway_version" "text") OWNER TO "postgres";

--
-- Name: solver_dispatch_inspect_uat_v1("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."solver_dispatch_inspect_uat_v1"("p_run_id" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select coalesce((
    select jsonb_build_object(
      'runId',o.run_id,'dispatchStatus',o.dispatch_status,
      'northflankRunId',o.northflank_run_id,
      'requestedAt',o.requested_at,
      'northflankAcceptedAt',o.northflank_accepted_at,
      'containerStartedAt',o.container_started_at,
      'jobFinishedAt',o.job_finished_at
    )
    from solver_private.solver_job_dispatch_outbox_uat_v1 o
    where o.run_id=p_run_id
  ),jsonb_build_object('runId',p_run_id,'dispatchStatus','NOT_FOUND'))
$$;


ALTER FUNCTION "public"."solver_dispatch_inspect_uat_v1"("p_run_id" "uuid") OWNER TO "postgres";

--
-- Name: solver_dispatch_reserve_uat_v1("text", integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."solver_dispatch_reserve_uat_v1"("p_dispatcher_version" "text", "p_lease_seconds" integer DEFAULT 60) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_config solver_private.solver_job_runtime_config_uat_v1%rowtype;
  v_item solver_private.solver_job_dispatch_outbox_uat_v1%rowtype;
  v_run public.optimization_runs_v2%rowtype;
  v_active integer;
  v_lease_token uuid:=gen_random_uuid();
  v_stamp jsonb;
begin
  if length(coalesce(p_dispatcher_version,'')) not between 1 and 500
    or p_dispatcher_version !~ '^[A-Za-z0-9][A-Za-z0-9._:@/-]*$' then
    raise exception 'DISPATCHER_VERSION_INVALID';
  end if;
  if coalesce(p_lease_seconds,0) not between 15 and 300 then
    raise exception 'DISPATCH_LEASE_INVALID';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('solver-job-dispatch-uat-v1',0));
  select * into v_config
  from solver_private.solver_job_runtime_config_uat_v1
  where singleton for update;
  if not v_config.dispatcher_enabled then
    return jsonb_build_object('reserved',false,'status','DISABLED');
  end if;

  select count(*) into v_active
  from solver_private.solver_job_dispatch_outbox_uat_v1 o
  where o.dispatch_status in (
    'DISPATCHING','ACCEPTANCE_UNKNOWN','ACCEPTED','STARTING','RUNNING'
  );
  if v_active>=v_config.global_active_jobs then
    return jsonb_build_object('reserved',false,'status','GLOBAL_LIMIT');
  end if;

  select candidate.* into v_item
  from solver_private.solver_job_dispatch_outbox_uat_v1 candidate
  join public.optimization_runs_v2 r on r.id=candidate.run_id
  where candidate.dispatch_status='PENDING'
    and candidate.next_dispatch_at<=now()
    and r.status='QUEUED'
    and not exists(
      select 1
      from solver_private.solver_job_dispatch_outbox_uat_v1 active
      where active.run_id<>candidate.run_id
        and active.organization_key=candidate.organization_key
        and active.dispatch_status in (
          'DISPATCHING','ACCEPTANCE_UNKNOWN','ACCEPTED','STARTING','RUNNING'
        )
    )
    and not exists(
      select 1
      from solver_private.solver_job_dispatch_outbox_uat_v1 active
      where active.run_id<>candidate.run_id
        and active.organization_key=candidate.organization_key
        and active.month=candidate.month
        and active.scope_type=candidate.scope_type
        and active.scope_role_id is not distinct from candidate.scope_role_id
        and active.dispatch_status in (
          'DISPATCHING','ACCEPTANCE_UNKNOWN','ACCEPTED','STARTING','RUNNING'
        )
    )
  order by candidate.requested_at,candidate.run_id
  for update of candidate skip locked
  limit 1;

  if v_item.run_id is null then
    return jsonb_build_object('reserved',false,'status','ORGANIZATION_LIMIT');
  end if;
  select * into v_run from public.optimization_runs_v2
  where id=v_item.run_id for update;

  v_stamp:=solver_private.version_stamp_set_once_uat_v1(
    v_run.version_stamp,'dispatcherVersion',to_jsonb(p_dispatcher_version)
  );
  update public.optimization_runs_v2
  set phase='DISPATCHING',version_stamp=v_stamp,updated_at=now()
  where id=v_run.id;
  update solver_private.solver_job_dispatch_outbox_uat_v1
  set dispatch_status='DISPATCHING',
      dispatch_attempt=dispatch_attempt+1,
      dispatch_started_at=now(),
      dispatcher_lease_token=v_lease_token,
      dispatcher_lease_expires_at=now()+make_interval(secs=>p_lease_seconds),
      dispatcher_version=p_dispatcher_version,
      last_http_status=null,last_error_code=null,last_error=null,
      updated_at=now()
  where run_id=v_item.run_id;

  return jsonb_build_object(
    'reserved',true,
    'status','DISPATCHING',
    'runId',v_item.run_id,
    'dispatchNonce',v_item.dispatch_nonce,
    'dispatchLeaseToken',v_lease_token,
    'dispatchAttempt',v_item.dispatch_attempt+1,
    'solverVersion',v_run.solver_version,
    'solverCommit',v_stamp->>'solverCommit',
    'solverBuildId',v_stamp->>'solverBuildId',
    'strategyConfigVersion',v_stamp->>'strategyConfigVersion',
    'configuredPlan',v_item.configured_plan,
    'configuredVcpu',v_item.configured_vcpu,
    'configuredRamMb',v_item.configured_ram_mb,
    'wallTimeoutSeconds',v_config.wall_timeout_seconds
  );
end;
$_$;


ALTER FUNCTION "public"."solver_dispatch_reserve_uat_v1"("p_dispatcher_version" "text", "p_lease_seconds" integer) OWNER TO "postgres";

--
-- Name: solver_dispatch_result_uat_v1("uuid", "uuid", "text", "text", integer, "text", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."solver_dispatch_result_uat_v1"("p_run_id" "uuid", "p_dispatch_lease_token" "uuid", "p_outcome" "text", "p_northflank_run_id" "text" DEFAULT NULL::"text", "p_http_status" integer DEFAULT NULL::integer, "p_error_code" "text" DEFAULT NULL::"text", "p_error_message" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_item solver_private.solver_job_dispatch_outbox_uat_v1%rowtype;
  v_run public.optimization_runs_v2%rowtype;
  v_stamp jsonb;
  v_delay integer;
begin
  if p_outcome not in (
    'ACCEPTED','RETRYABLE_REJECTED','ACCEPTANCE_UNKNOWN','PERMANENT_FAILURE'
  ) then raise exception 'DISPATCH_OUTCOME_INVALID'; end if;
  select * into v_item
  from solver_private.solver_job_dispatch_outbox_uat_v1
  where run_id=p_run_id for update;
  if v_item.run_id is null then raise exception 'DISPATCH_NOT_FOUND'; end if;
  if v_item.dispatch_status<>'DISPATCHING'
    or v_item.dispatcher_lease_token is distinct from p_dispatch_lease_token
    or v_item.dispatcher_lease_expires_at<now() then
    raise exception 'DISPATCH_LEASE_LOST';
  end if;
  select * into v_run from public.optimization_runs_v2
  where id=p_run_id for update;

  if p_outcome='ACCEPTED' then
    if length(coalesce(p_northflank_run_id,'')) not between 1 and 200 then
      raise exception 'NORTHFLANK_RUN_ID_INVALID';
    end if;
    v_stamp:=solver_private.version_stamp_set_once_uat_v1(
      v_run.version_stamp,'northflankRunId',to_jsonb(p_northflank_run_id)
    );
    update public.optimization_runs_v2
    set phase='STARTING',version_stamp=v_stamp,updated_at=now()
    where id=p_run_id;
    update solver_private.solver_job_dispatch_outbox_uat_v1
    set dispatch_status='ACCEPTED',
        northflank_run_id=p_northflank_run_id,
        northflank_accepted_at=now(),
        dispatcher_lease_token=null,dispatcher_lease_expires_at=null,
        last_http_status=p_http_status,last_error_code=null,last_error=null,
        updated_at=now()
    where run_id=p_run_id;
  elsif p_outcome='RETRYABLE_REJECTED' then
    v_delay:=least(300,15*(2^least(v_item.dispatch_attempt-1,4))::integer);
    update public.optimization_runs_v2
    set phase='DISPATCH_PENDING',updated_at=now()
    where id=p_run_id;
    update solver_private.solver_job_dispatch_outbox_uat_v1
    set dispatch_status='PENDING',next_dispatch_at=now()+make_interval(secs=>v_delay),
        dispatcher_lease_token=null,dispatcher_lease_expires_at=null,
        last_http_status=p_http_status,last_error_code=left(p_error_code,100),
        last_error=left(p_error_message,1000),updated_at=now()
    where run_id=p_run_id;
  elsif p_outcome='ACCEPTANCE_UNKNOWN' then
    update public.optimization_runs_v2
    set phase='DISPATCH_UNCERTAIN',updated_at=now()
    where id=p_run_id;
    update solver_private.solver_job_dispatch_outbox_uat_v1
    set dispatch_status='ACCEPTANCE_UNKNOWN',
        dispatcher_lease_token=null,dispatcher_lease_expires_at=null,
        last_http_status=p_http_status,
        last_error_code=coalesce(left(p_error_code,100),'NORTHFLANK_ACCEPTANCE_UNKNOWN'),
        last_error=left(p_error_message,1000),updated_at=now()
    where run_id=p_run_id;
  else
    update public.optimization_runs_v2
    set status='FAILED',phase='FAILED',progress=0,
        failure_code=coalesce(left(p_error_code,100),'DISPATCH_FAILED'),
        failure_message='Nie udało się uruchomić zadania generatora.',
        finished_at=now(),updated_at=now()
    where id=p_run_id and status='QUEUED';
    update public.optimization_run_strategies_v2
    set status='FAILED',phase='FAILED',progress=0,
        failure_code=coalesce(left(p_error_code,100),'DISPATCH_FAILED'),
        finished_at=now(),updated_at=now()
    where run_id=p_run_id and status='QUEUED';
    update solver_private.solver_job_dispatch_outbox_uat_v1
    set dispatch_status='FAILED',
        dispatcher_lease_token=null,dispatcher_lease_expires_at=null,
        last_http_status=p_http_status,
        last_error_code=coalesce(left(p_error_code,100),'DISPATCH_FAILED'),
        last_error=left(p_error_message,1000),job_finished_at=now(),updated_at=now()
    where run_id=p_run_id;
  end if;
  return jsonb_build_object('runId',p_run_id,'outcome',p_outcome);
end;
$$;


ALTER FUNCTION "public"."solver_dispatch_result_uat_v1"("p_run_id" "uuid", "p_dispatch_lease_token" "uuid", "p_outcome" "text", "p_northflank_run_id" "text", "p_http_status" integer, "p_error_code" "text", "p_error_message" "text") OWNER TO "postgres";

--
-- Name: solver_fail_attempt_before_nfjob_uat_v1("uuid", "uuid", "uuid", "text", "text", boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."solver_fail_attempt_before_nfjob_uat_v1"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_error_code" "text", "p_error_message" "text", "p_retryable" boolean) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_run public.optimization_runs_v2%rowtype;
  v_retry boolean;
  v_message_id bigint;
  v_outcome text;
begin
  if coalesce(p_error_code,'') !~ '^[A-Z][A-Z0-9_:-]{0,99}$' then
    raise exception 'INVALID_ERROR_CODE';
  end if;
  if length(coalesce(p_error_message,'')) not between 1 and 1000 then
    raise exception 'INVALID_ERROR_MESSAGE';
  end if;
  perform solver_private.lock_planning_revision_v2();
  if not solver_private.lease_is_live_v2(
    p_run_id,p_attempt_id,p_lease_token
  ) then raise exception 'LEASE_LOST'; end if;
  select * into v_run
  from public.optimization_runs_v2
  where id=p_run_id
  for update;
  v_retry:=coalesce(p_retryable,false)
    and v_run.attempt_count<v_run.max_attempts
    and v_run.status<>'CANCEL_REQUESTED';

  update solver_private.optimization_attempts_v2
  set status='FAILED',error_code=p_error_code,
    error_message=p_error_message,finished_at=now(),heartbeat_at=now()
  where id=p_attempt_id;

  if v_retry then
    perform solver_private.reset_retry_outputs_v2(p_run_id);
    select pgmq.send('schedule_optimizer_v2',jsonb_build_object(
      'schemaVersion',2,'runId',p_run_id,'retry',true,
      'reason',p_error_code,'solverVersion',v_run.solver_version
    )) into v_message_id;
    update public.optimization_runs_v2
    set status='QUEUED',phase='RETRY_QUEUED',progress=0,
      queue_message_id=v_message_id,lease_owner=null,lease_token=null,
      lease_expires_at=null,worker_execution_name=null,heartbeat_at=null,
      started_at=null,finished_at=null,failure_code=p_error_code,
      failure_message='Próba solvera nie powiodła się; zadanie oczekuje na ponowienie.',
      updated_at=now()
    where id=p_run_id;
    v_outcome:='QUEUED';
  else
    delete from public.plan_variants_v2 where run_id=p_run_id;
    v_outcome:=case when v_run.status='CANCEL_REQUESTED'
      then 'CANCELLED' else 'FAILED' end;
    update public.optimization_run_strategies_v2
    set status=v_outcome,phase=v_outcome,progress=0,metrics='{}'::jsonb,
      failure_code=p_error_code,finished_at=now(),updated_at=now()
    where run_id=p_run_id;
    update public.optimization_runs_v2
    set status=v_outcome,phase=v_outcome,progress=0,queue_message_id=null,
      lease_owner=null,lease_token=null,lease_expires_at=null,
      worker_execution_name=null,heartbeat_at=null,
      failure_code=p_error_code,failure_message=p_error_message,
      finished_at=now(),updated_at=now()
    where id=p_run_id;
  end if;
  return jsonb_build_object('status',v_outcome,'retry',v_retry);
end;
$_$;


ALTER FUNCTION "public"."solver_fail_attempt_before_nfjob_uat_v1"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_error_code" "text", "p_error_message" "text", "p_retryable" boolean) OWNER TO "postgres";

--
-- Name: solver_fail_attempt_v2("uuid", "uuid", "uuid", "text", "text", boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."solver_fail_attempt_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_error_code" "text", "p_error_message" "text", "p_retryable" boolean) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_result jsonb;
  v_retryable boolean:=coalesce(p_retryable,false);
  v_queue_message_id bigint;
  v_is_job boolean;
begin
  select exists(
    select 1 from solver_private.solver_job_dispatch_outbox_uat_v1
    where run_id=p_run_id
  ) into v_is_job;
  if upper(coalesce(p_error_code,'')) in (
    'INVALID_SNAPSHOT','INVALID_VARIANT','OPTIMIZATION_ERROR',
    'OPTIMIZATION_INCOMPLETE','FAIRNESS_QUALITY_GATE_FAILED',
    'TENANT_MISMATCH','AUTH_FAILURE','PROBLEM_SIZE_EXCEEDED',
    'HARD_GUARDRAIL','JOB_WALL_TIMEOUT'
  ) then v_retryable:=false; end if;

  v_result:=public.solver_fail_attempt_before_nfjob_uat_v1(
    p_run_id,p_attempt_id,p_lease_token,p_error_code,p_error_message,v_retryable
  );
  if not v_is_job then return v_result; end if;

  if coalesce((v_result->>'retry')::boolean,false) then
    select queue_message_id into v_queue_message_id
    from public.optimization_runs_v2 where id=p_run_id for update;
    if v_queue_message_id is not null then
      perform pgmq.archive('schedule_optimizer_v2',v_queue_message_id);
    end if;
    update public.optimization_runs_v2
    set queue_message_id=null,phase='JOB_RETRY_WAIT',updated_at=now()
    where id=p_run_id;
    update solver_private.solver_job_dispatch_outbox_uat_v1
    set dispatch_status='RUNNING',solver_retry_count=solver_retry_count+1,
      last_error_code=left(p_error_code,100),
      last_error=left(p_error_message,1000),updated_at=now()
    where run_id=p_run_id;
  else
    update solver_private.solver_job_dispatch_outbox_uat_v1
    set dispatch_status=case
        when (select status from public.optimization_runs_v2 where id=p_run_id)
          ='CANCELLED' then 'CANCELLED' else 'FAILED' end,
      last_error_code=left(p_error_code,100),
      last_error=left(p_error_message,1000),updated_at=now()
    where run_id=p_run_id;
  end if;
  return v_result;
end;
$$;


ALTER FUNCTION "public"."solver_fail_attempt_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_error_code" "text", "p_error_message" "text", "p_retryable" boolean) OWNER TO "postgres";

--
-- Name: solver_feature_flag_set("text", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."solver_feature_flag_set"("p_engine" "text", "p_config" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_engine text:=upper(trim(p_engine)); v_result jsonb;
begin
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if v_engine not in ('ALPHA15','ORTOOLS_V2','SHADOW') then
    raise exception 'INVALID_SOLVER_ENGINE';
  end if;
  if p_config is null or jsonb_typeof(p_config)<>'object' then
    raise exception 'OBJECT_CONFIG_REQUIRED';
  end if;
  if v_engine in ('SHADOW','ORTOOLS_V2') and (
    length(trim(coalesce(p_config->>'solverVersion',''))) not between 1 and 200
  ) then
    raise exception 'SOLVER_VERSION_CONFIGURATION_REQUIRED';
  end if;
  insert into public.solver_feature_flags(flag_key,engine,enabled,config,updated_by,updated_at)
  values('DEFAULT_ENGINE',v_engine,true,p_config,auth.uid(),now())
  on conflict(flag_key) do update set engine=excluded.engine,enabled=true,
    config=excluded.config,updated_by=auth.uid(),updated_at=now()
  returning to_jsonb(solver_feature_flags.*) into v_result;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'solver_feature_flag','DEFAULT_ENGINE','SET',jsonb_build_object(
    'engine',v_engine,'config',p_config));
  return v_result;
end;
$$;


ALTER FUNCTION "public"."solver_feature_flag_set"("p_engine" "text", "p_config" "jsonb") OWNER TO "postgres";

--
-- Name: solver_finalize_before_nfjob_uat_v1("uuid", "uuid", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."solver_finalize_before_nfjob_uat_v1"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_run public.optimization_runs_v2%rowtype;
  v_stored jsonb;
  v_current jsonb;
  v_current_hash text;
  v_expected integer;
  v_ready integer;
  v_require_optimal boolean;
  v_message text;
begin
  perform solver_private.lock_planning_revision_v2();
  select * into v_run from public.optimization_runs_v2 where id=p_run_id for update;
  if v_run.id is null then raise exception 'RUN_NOT_FOUND'; end if;

  -- A lost HTTP response may cause the same worker to retry finalization after
  -- the first transaction already committed and released its lease.
  if v_run.status='READY' then
    return jsonb_build_object('status','READY','runId',p_run_id,'reused',true,
      'variantCount',(select count(*) from public.plan_variants_v2 where run_id=p_run_id));
  end if;
  if not solver_private.lease_is_live_v2(p_run_id,p_attempt_id,p_lease_token) then
    raise exception 'LEASE_LOST';
  end if;

  if v_run.status='CANCEL_REQUESTED' then
    delete from public.plan_variants_v2 where run_id=p_run_id;
    update public.optimization_runs_v2 set status='CANCELLED',phase='CANCELLED',
      finished_at=now(),updated_at=now(),lease_owner=null,lease_token=null,lease_expires_at=null
    where id=p_run_id;
    update solver_private.optimization_attempts_v2 set status='INTERRUPTED',
      finished_at=now(),error_code='CANCEL_REQUESTED' where id=p_attempt_id;
    return jsonb_build_object('status','CANCELLED');
  end if;

  update public.optimization_runs_v2 set status='VALIDATING',phase='DATABASE_VALIDATION',
    progress=99,updated_at=now() where id=p_run_id;
  select snapshot into v_stored
  from solver_private.optimization_snapshots_v2 where run_id=p_run_id;
  if v_stored is null then raise exception 'SNAPSHOT_NOT_FOUND'; end if;
  v_current:=solver_private.build_snapshot_payload_v2(
    p_run_id,v_run.month,v_run.matrix_version_id,v_run.scenario_id,
    v_run.scope_type,v_run.scope_role_id
  );
  v_current_hash:=encode(extensions.digest(convert_to(
    solver_private.canonical_json_v2(v_current),'UTF8'
  ),'sha256'),'hex');
  if v_current_hash<>v_run.snapshot_hash then
    update public.plan_variants_v2 set status='ARCHIVED' where run_id=p_run_id;
    update public.optimization_run_strategies_v2 set status='STALE_INPUT',
      phase='STALE_INPUT',updated_at=now() where run_id=p_run_id;
    update public.optimization_runs_v2 set status='STALE_INPUT',phase='STALE_INPUT',
      failure_code='SNAPSHOT_CHANGED',
      failure_message='Dane Matrixa lub pracowników zmieniły się podczas optymalizacji.',
      finished_at=now(),updated_at=now(),lease_owner=null,lease_token=null,lease_expires_at=null
    where id=p_run_id;
    update solver_private.optimization_attempts_v2 set status='FAILED',finished_at=now(),
      error_code='SNAPSHOT_CHANGED' where id=p_attempt_id;
    return jsonb_build_object('status','STALE_INPUT','errorCode','SNAPSHOT_CHANGED',
      'currentSnapshotHash',v_current_hash);
  end if;

  -- The persisted variant is authoritative evidence that this strategy reached
  -- SAVED.  This repairs an interrupted status update without rerunning OR-Tools.
  update public.optimization_run_strategies_v2 strategy set
    status='READY',phase='SAVED',progress=100,
    started_at=coalesce(strategy.started_at,now()),
    finished_at=coalesce(strategy.finished_at,now()),updated_at=now()
  where strategy.run_id=p_run_id and exists(
    select 1 from public.plan_variants_v2 variant
    where variant.run_strategy_id=strategy.id and variant.hard_violations=0
      and variant.status='READY'
  );

  select count(*) into v_expected from public.optimization_run_strategies_v2
  where run_id=p_run_id;
  select count(distinct strategy.id) into v_ready
  from public.optimization_run_strategies_v2 strategy
  join public.plan_variants_v2 variant on variant.run_strategy_id=strategy.id
  where strategy.run_id=p_run_id and strategy.status='READY'
    and variant.status='READY' and variant.hard_violations=0;
  if v_expected=0 or v_ready<>v_expected then
    v_message:=format('Końcowa kontrola zapisała %s z %s wymaganych wariantów.',v_ready,v_expected);
    update public.optimization_run_strategies_v2 strategy set
      status='FAILED',phase='FAILED',failure_code='RUN_VARIANT_MISSING',
      finished_at=now(),updated_at=now()
    where strategy.run_id=p_run_id and not exists(
      select 1 from public.plan_variants_v2 variant
      where variant.run_strategy_id=strategy.id and variant.status='READY'
        and variant.hard_violations=0
    );
    update public.optimization_runs_v2 set status='FAILED',phase='FAILED',
      failure_code='RUN_VARIANTS_INCOMPLETE',failure_message=v_message,
      finished_at=now(),updated_at=now(),lease_owner=null,lease_token=null,lease_expires_at=null
    where id=p_run_id;
    update solver_private.optimization_attempts_v2 set status='FAILED',finished_at=now(),
      error_code='RUN_VARIANTS_INCOMPLETE',error_message=v_message where id=p_attempt_id;
    insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
    values(v_run.requested_by,'optimization_run_v2',p_run_id::text,'FINALIZE_FAILED',
      jsonb_build_object('errorCode','RUN_VARIANTS_INCOMPLETE','ready',v_ready,'expected',v_expected));
    return jsonb_build_object('status','FAILED','errorCode','RUN_VARIANTS_INCOMPLETE',
      'readyVariantCount',v_ready,'expectedVariantCount',v_expected);
  end if;

  v_require_optimal:=coalesce((v_stored->'settings'->>'requireOptimal')::boolean,true);
  if v_require_optimal and exists(
    select 1 from public.plan_variants_v2
    where run_id=p_run_id and status='READY' and solver_status<>'OPTIMAL'
  ) then
    v_message:='Matrix wymaga dowodu matematycznego optimum, a co najmniej jeden zapisany wariant jest tylko poprawnym rozwiązaniem.';
    update public.optimization_runs_v2 set status='FAILED',phase='FAILED',
      failure_code='RUN_REQUIRES_OPTIMAL_VARIANTS',failure_message=v_message,
      finished_at=now(),updated_at=now(),lease_owner=null,lease_token=null,lease_expires_at=null
    where id=p_run_id;
    update solver_private.optimization_attempts_v2 set status='FAILED',finished_at=now(),
      error_code='RUN_REQUIRES_OPTIMAL_VARIANTS',error_message=v_message where id=p_attempt_id;
    return jsonb_build_object('status','FAILED','errorCode','RUN_REQUIRES_OPTIMAL_VARIANTS');
  end if;

  update public.plan_variants_v2 set recommended=false where run_id=p_run_id;
  update public.plan_variants_v2 variant set recommended=true
  where variant.id=(
    select candidate.id from public.plan_variants_v2 candidate
    join public.optimization_run_strategies_v2 strategy on strategy.id=candidate.run_strategy_id
    where candidate.run_id=p_run_id and candidate.status='READY'
    order by strategy.ordinal limit 1
  );
  update public.optimization_runs_v2 set status='READY',phase='READY',progress=100,
    failure_code=null,failure_message=null,finished_at=now(),updated_at=now(),heartbeat_at=now(),
    lease_owner=null,lease_token=null,lease_expires_at=null
  where id=p_run_id;
  update solver_private.optimization_attempts_v2 set status='SUCCEEDED',
    heartbeat_at=now(),finished_at=now(),error_code=null,error_message=null
  where id=p_attempt_id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_run.requested_by,'optimization_run_v2',p_run_id::text,'READY',
    jsonb_build_object('variantCount',v_ready,'snapshotHash',v_run.snapshot_hash));
  return jsonb_build_object('status','READY','runId',p_run_id,'variantCount',v_ready);
end;
$$;


ALTER FUNCTION "public"."solver_finalize_before_nfjob_uat_v1"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid") OWNER TO "postgres";

--
-- Name: solver_finalize_v2("uuid", "uuid", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."solver_finalize_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_result jsonb; v_status text;
begin
  v_result:=public.solver_finalize_before_nfjob_uat_v1(
    p_run_id,p_attempt_id,p_lease_token
  );
  v_status:=upper(coalesce(v_result->>'status','READY'));
  update solver_private.solver_job_dispatch_outbox_uat_v1
  set dispatch_status=case
        when v_status='READY' then 'SUCCEEDED'
        when v_status='CANCELLED' then 'CANCELLED'
        else 'FAILED' end,
      solver_finished_at=coalesce(solver_finished_at,now()),
      result_saved_at=coalesce(result_saved_at,now()),
      ready_at=case when v_status='READY' then now() else ready_at end,
      last_error_code=case when v_status in ('READY','CANCELLED')
        then last_error_code else v_status end,
      updated_at=now()
  where run_id=p_run_id;
  return v_result;
end;
$$;


ALTER FUNCTION "public"."solver_finalize_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid") OWNER TO "postgres";

--
-- Name: solver_heartbeat_before_nfjob_uat_v1("uuid", "uuid", "uuid", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."solver_heartbeat_before_nfjob_uat_v1"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_progress" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_progress integer := greatest(1,least(99,coalesce((p_progress->>'progress')::integer,1)));
  v_phase text := left(coalesce(nullif(p_progress->>'phase',''),'SOLVING'),80);
  v_strategy_id uuid := nullif(p_progress->>'strategyId','')::uuid;
  v_cancel boolean;
begin
  if not solver_private.lease_is_live_v2(p_run_id,p_attempt_id,p_lease_token) then
    raise exception 'LEASE_LOST';
  end if;
  update public.optimization_runs_v2 set progress=greatest(progress,v_progress),phase=v_phase,
    heartbeat_at=now(),lease_expires_at=now()+interval '120 seconds',updated_at=now()
  where id=p_run_id and lease_token=p_lease_token;
  update solver_private.optimization_attempts_v2 set heartbeat_at=now()
  where id=p_attempt_id and lease_token=p_lease_token;
  if v_strategy_id is not null then
    update public.optimization_run_strategies_v2 set
      status='RUNNING',phase=v_phase,
      progress=greatest(progress,least(99,coalesce((p_progress->>'strategyProgress')::integer,v_progress))),
      started_at=coalesce(started_at,now()),updated_at=now()
    where run_id=p_run_id and strategy_id=v_strategy_id;
  end if;
  select status='CANCEL_REQUESTED' into v_cancel
  from public.optimization_runs_v2 where id=p_run_id;
  return jsonb_build_object('ok',true,'cancelRequested',coalesce(v_cancel,false),
    'leaseExpiresAt',now()+interval '120 seconds');
end;
$$;


ALTER FUNCTION "public"."solver_heartbeat_before_nfjob_uat_v1"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_progress" "jsonb") OWNER TO "postgres";

--
-- Name: solver_heartbeat_v2("uuid", "uuid", "uuid", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."solver_heartbeat_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_progress" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_result jsonb; v_phase text:=upper(coalesce(p_progress->>'phase',''));
begin
  v_result:=public.solver_heartbeat_before_nfjob_uat_v1(
    p_run_id,p_attempt_id,p_lease_token,p_progress
  );
  update solver_private.solver_job_dispatch_outbox_uat_v1 o
  set dispatch_status='RUNNING',
      solver_started_at=case
        when v_phase='SOLVING' then coalesce(o.solver_started_at,now())
        else o.solver_started_at end,
      solver_finished_at=case
        when v_phase in ('VALIDATING','SAVING','FINALIZING')
          then coalesce(o.solver_finished_at,now())
        else o.solver_finished_at end,
      updated_at=now()
  from public.optimization_runs_v2 r
  where o.run_id=p_run_id and r.id=o.run_id
    and r.lease_token=p_lease_token;
  return v_result;
end;
$$;


ALTER FUNCTION "public"."solver_heartbeat_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_progress" "jsonb") OWNER TO "postgres";

--
-- Name: solver_interrupt_before_nfjob_uat_v1("uuid", "uuid", "uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."solver_interrupt_before_nfjob_uat_v1"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_run public.optimization_runs_v2%rowtype;
  v_retry boolean;
  v_message_id bigint;
  v_outcome text;
begin
  if coalesce(p_reason,'') !~ '^[A-Z][A-Z0-9_:-]{0,99}$' then
    raise exception 'INVALID_INTERRUPT_REASON';
  end if;
  perform solver_private.lock_planning_revision_v2();
  if not solver_private.lease_is_live_v2(
    p_run_id,p_attempt_id,p_lease_token
  ) then raise exception 'LEASE_LOST'; end if;
  select * into v_run
  from public.optimization_runs_v2
  where id=p_run_id
  for update;

  update solver_private.optimization_attempts_v2
  set status='INTERRUPTED',
    error_code=case when v_run.status='CANCEL_REQUESTED'
      or p_reason='CANCEL_REQUESTED' then 'CANCELLED' else 'INTERRUPTED' end,
    error_message=left(p_reason,1000),finished_at=now(),heartbeat_at=now()
  where id=p_attempt_id;

  if v_run.status='CANCEL_REQUESTED' or p_reason='CANCEL_REQUESTED' then
    delete from public.plan_variants_v2 where run_id=p_run_id;
    update public.optimization_run_strategies_v2
    set status='CANCELLED',phase='CANCELLED',progress=0,
      metrics='{}'::jsonb,finished_at=now(),updated_at=now()
    where run_id=p_run_id;
    update public.optimization_runs_v2
    set status='CANCELLED',phase='CANCELLED',progress=0,
      queue_message_id=null,lease_owner=null,lease_token=null,
      lease_expires_at=null,worker_execution_name=null,heartbeat_at=null,
      finished_at=now(),updated_at=now()
    where id=p_run_id;
    return jsonb_build_object('status','CANCELLED','retry',false);
  end if;

  v_retry:=v_run.attempt_count<v_run.max_attempts;
  if v_retry then
    perform solver_private.reset_retry_outputs_v2(p_run_id);
    select pgmq.send('schedule_optimizer_v2',jsonb_build_object(
      'schemaVersion',2,'runId',p_run_id,'retry',true,
      'reason','INTERRUPTED','solverVersion',v_run.solver_version
    )) into v_message_id;
    update public.optimization_runs_v2
    set status='QUEUED',phase='RETRY_QUEUED',progress=0,
      queue_message_id=v_message_id,lease_owner=null,lease_token=null,
      lease_expires_at=null,worker_execution_name=null,heartbeat_at=null,
      started_at=null,finished_at=null,failure_code='INTERRUPTED',
      failure_message='Przerwana próba została ponownie dodana do kolejki.',
      updated_at=now()
    where id=p_run_id;
    v_outcome:='QUEUED';
  else
    delete from public.plan_variants_v2 where run_id=p_run_id;
    update public.optimization_run_strategies_v2
    set status='FAILED',phase='FAILED',progress=0,metrics='{}'::jsonb,
      failure_code='INTERRUPTED',finished_at=now(),updated_at=now()
    where run_id=p_run_id;
    update public.optimization_runs_v2
    set status='FAILED',phase='FAILED',progress=0,queue_message_id=null,
      lease_owner=null,lease_token=null,lease_expires_at=null,
      worker_execution_name=null,heartbeat_at=null,
      failure_code='INTERRUPTED',failure_message='Solver został przerwany.',
      finished_at=now(),updated_at=now()
    where id=p_run_id;
    v_outcome:='FAILED';
  end if;
  return jsonb_build_object('status',v_outcome,'retry',v_retry);
end;
$_$;


ALTER FUNCTION "public"."solver_interrupt_before_nfjob_uat_v1"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_reason" "text") OWNER TO "postgres";

--
-- Name: solver_interrupt_v2("uuid", "uuid", "uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."solver_interrupt_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_result jsonb;
begin
  v_result:=public.solver_interrupt_before_nfjob_uat_v1(
    p_run_id,p_attempt_id,p_lease_token,p_reason
  );
  update solver_private.solver_job_dispatch_outbox_uat_v1
  set dispatch_status=case when p_reason='CANCEL_REQUESTED'
        then 'CANCELLED' else 'FAILED' end,
      last_error_code=left(p_reason,100),updated_at=now()
  where run_id=p_run_id;
  return v_result;
end;
$$;


ALTER FUNCTION "public"."solver_interrupt_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_reason" "text") OWNER TO "postgres";

--
-- Name: solver_job_contract_probe_uat_v1(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."solver_job_contract_probe_uat_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_source public.optimization_runs_v2%rowtype;
  v_org_two uuid;
  v_run_a uuid:=gen_random_uuid();
  v_run_a_waiting uuid:=gen_random_uuid();
  v_run_b uuid:=gen_random_uuid();
  v_run_b_waiting uuid:=gen_random_uuid();
  v_run_same_schedule uuid:=gen_random_uuid();
  v_stamp jsonb;
  v_nonce_a uuid:=gen_random_uuid();
  v_nonce_a_waiting uuid:=gen_random_uuid();
  v_nonce_b uuid:=gen_random_uuid();
  v_nonce_b_waiting uuid:=gen_random_uuid();
  v_first jsonb;
  v_second jsonb;
  v_third jsonb;
  v_claim jsonb;
  v_duplicate_claim jsonb;
  v_missing_claim jsonb;
  v_duplicate_outbox_blocked boolean:=false;
  v_same_schedule_blocked boolean:=false;
  v_wrong_capability_blocked boolean:=false;
  v_stamp_change_blocked boolean:=false;
  v_schema_change_blocked boolean:=false;
  v_nf_change_blocked boolean:=false;
  v_per_organization_concurrency boolean:=false;
  v_dispatch_retry_separate boolean:=false;
  v_acceptance_unknown_safe boolean:=false;
  v_rolled_back boolean:=false;
  v_results jsonb;
begin
  begin
    select r.* into v_source
    from public.optimization_runs_v2 r
    where r.snapshot_schema_version=2
    order by r.created_at desc limit 1;
    if v_source.id is null then raise exception 'GATE_B_SOURCE_RUN_MISSING'; end if;
    select mv.id into v_org_two from public.matrix_versions mv
    where mv.id<>v_source.matrix_version_id
    order by mv.created_at desc limit 1;
    if v_org_two is null then raise exception 'GATE_B_SECOND_ORGANIZATION_KEY_MISSING'; end if;

    v_stamp:=jsonb_build_object(
      'schemaVersion',1,
      'frontendCommit','gate-b-synthetic',
      'solverCommit','86522fe6d701a14a5a2ec90d999f385739a4f212',
      'solverImageDigest',null,
      'solverBuildId','difficult-price-5668',
      'gatewayVersion',null,
      'strategyConfigVersion',repeat('a',64),
      'databaseMigrationVersion','20260824194000_uat_northflank_job_gate_b_probe',
      'snapshotSchemaVersion',2,
      'executionMode','JOB',
      'northflankRunId',null,
      'dispatcherVersion',null
    );

    insert into public.optimization_runs_v2(
      id,idempotency_key,month,matrix_version_id,scenario_id,scope_type,
      scope_role_id,name,status,phase,progress,requested_by,
      snapshot_schema_version,snapshot_hash,solver_version,request_engine,
      attempt_count,max_attempts,version_stamp,queued_at
    ) values
      (v_run_a,'gate-b-'||v_run_a,v_source.month,v_source.matrix_version_id,
       v_source.scenario_id,'COMPANY',null,'Gate B A','QUEUED','DISPATCH_PENDING',0,
       v_source.requested_by,2,repeat('1',64),v_source.solver_version,'ORTOOLS_V2',0,3,v_stamp,now()-interval '5 minutes'),
      (v_run_a_waiting,'gate-b-'||v_run_a_waiting,v_source.month+interval '1 month',v_source.matrix_version_id,
       v_source.scenario_id,'COMPANY',null,'Gate B A waiting','QUEUED','DISPATCH_PENDING',0,
       v_source.requested_by,2,repeat('2',64),v_source.solver_version,'ORTOOLS_V2',0,3,v_stamp,now()-interval '4 minutes'),
      (v_run_b,'gate-b-'||v_run_b,v_source.month,v_org_two,
       v_source.scenario_id,'COMPANY',null,'Gate B B','QUEUED','DISPATCH_PENDING',0,
       v_source.requested_by,2,repeat('3',64),v_source.solver_version,'ORTOOLS_V2',0,3,v_stamp,now()-interval '3 minutes'),
      (v_run_b_waiting,'gate-b-'||v_run_b_waiting,v_source.month+interval '1 month',v_org_two,
       v_source.scenario_id,'COMPANY',null,'Gate B B waiting','QUEUED','DISPATCH_PENDING',0,
       v_source.requested_by,2,repeat('4',64),v_source.solver_version,'ORTOOLS_V2',0,3,v_stamp,now()-interval '2 minutes'),
      (v_run_same_schedule,'gate-b-'||v_run_same_schedule,v_source.month,v_source.matrix_version_id,
       v_source.scenario_id,'COMPANY',null,'Gate B same schedule','QUEUED','DISPATCH_PENDING',0,
       v_source.requested_by,2,repeat('5',64),v_source.solver_version,'ORTOOLS_V2',0,3,v_stamp,now()-interval '1 minute');

    insert into solver_private.solver_job_dispatch_outbox_uat_v1(
      run_id,organization_key,month,scope_type,scope_role_id,requested_at,dispatch_nonce
    ) values
      (v_run_a,v_source.matrix_version_id,v_source.month,'COMPANY',null,now()-interval '5 minutes',v_nonce_a),
      (v_run_a_waiting,v_source.matrix_version_id,(v_source.month+interval '1 month')::date,'COMPANY',null,now()-interval '4 minutes',v_nonce_a_waiting),
      (v_run_b,v_org_two,v_source.month,'COMPANY',null,now()-interval '3 minutes',v_nonce_b),
      (v_run_b_waiting,v_org_two,(v_source.month+interval '1 month')::date,'COMPANY',null,now()-interval '2 minutes',v_nonce_b_waiting);

    begin
      insert into solver_private.solver_job_dispatch_outbox_uat_v1(
        run_id,organization_key,month,scope_type,scope_role_id,requested_at
      ) values(v_run_a,v_source.matrix_version_id,v_source.month,'COMPANY',null,now());
    exception when unique_violation then v_duplicate_outbox_blocked:=true; end;

    begin
      insert into solver_private.solver_job_dispatch_outbox_uat_v1(
        run_id,organization_key,month,scope_type,scope_role_id,requested_at
      ) values(v_run_same_schedule,v_source.matrix_version_id,v_source.month,'COMPANY',null,now());
    exception when unique_violation then v_same_schedule_blocked:=true; end;

    update solver_private.solver_job_runtime_config_uat_v1
    set dispatcher_enabled=true where singleton;
    v_first:=public.solver_dispatch_reserve_uat_v1('gate-b-dispatcher',60);
    v_second:=public.solver_dispatch_reserve_uat_v1('gate-b-dispatcher',60);
    v_third:=public.solver_dispatch_reserve_uat_v1('gate-b-dispatcher',60);
    if v_first->>'runId'<>v_run_a::text
      or v_second->>'runId'<>v_run_b::text
      or v_third->>'status'<>'GLOBAL_LIMIT' then
      raise exception 'GATE_B_CONCURRENCY_INVALID';
    end if;
    select v_first->>'runId'=v_run_a::text
      and v_second->>'runId'=v_run_b::text
      and (select dispatch_status='PENDING'
        from solver_private.solver_job_dispatch_outbox_uat_v1
        where run_id=v_run_a_waiting)
      and (select dispatch_status='PENDING'
        from solver_private.solver_job_dispatch_outbox_uat_v1
        where run_id=v_run_b_waiting)
    into v_per_organization_concurrency;

    perform public.solver_dispatch_result_uat_v1(
      v_run_a,(v_first->>'dispatchLeaseToken')::uuid,'ACCEPTED',
      'gate-b-northflank-a',201,null,null
    );
    v_claim:=public.solver_claim_run_v2(
      v_run_a,v_nonce_a,'gate-b-worker',v_source.solver_version,1,90,'gate-b-gateway'
    );
    v_duplicate_claim:=public.solver_claim_run_v2(
      v_run_a,v_nonce_a,'gate-b-worker-duplicate',v_source.solver_version,1,90,'gate-b-gateway'
    );
    v_missing_claim:=public.solver_claim_run_v2(
      gen_random_uuid(),gen_random_uuid(),'gate-b-worker-missing',v_source.solver_version,1,90,'gate-b-gateway'
    );
    if coalesce((v_claim->>'claimed')::boolean,false) is not true
      or v_duplicate_claim->>'status'<>'CONFLICT'
      or v_missing_claim->>'status'<>'TARGET_NOT_FOUND' then
      raise exception 'GATE_B_TARGET_CLAIM_INVALID';
    end if;
    begin
      perform public.solver_claim_run_v2(
        v_run_a_waiting,v_nonce_a,'gate-b-worker-wrong',v_source.solver_version,1,90,'gate-b-gateway'
      );
    exception when others then
      if sqlerrm='TARGET_CAPABILITY_INVALID' then v_wrong_capability_blocked:=true;
      else raise; end if;
    end;

    perform public.solver_dispatch_result_uat_v1(
      v_run_b,(v_second->>'dispatchLeaseToken')::uuid,'RETRYABLE_REJECTED',
      null,429,'NORTHFLANK_RATE_LIMIT','proven rejection'
    );
    select dispatch_status='PENDING' and dispatch_attempt=1 and solver_retry_count=0
    into v_dispatch_retry_separate
    from solver_private.solver_job_dispatch_outbox_uat_v1 where run_id=v_run_b;
    update solver_private.solver_job_dispatch_outbox_uat_v1
    set next_dispatch_at=now() where run_id=v_run_b;
    v_second:=public.solver_dispatch_reserve_uat_v1('gate-b-dispatcher',60);
    if v_second->>'runId'<>v_run_b::text then
      raise exception 'GATE_B_RETRY_TARGET_CHANGED';
    end if;
    perform public.solver_dispatch_result_uat_v1(
      v_run_b,(v_second->>'dispatchLeaseToken')::uuid,'ACCEPTANCE_UNKNOWN',
      null,null,'NORTHFLANK_ACCEPTANCE_UNKNOWN','response lost'
    );
    select dispatch_status='ACCEPTANCE_UNKNOWN' and dispatch_attempt=2
      and solver_retry_count=0
    into v_acceptance_unknown_safe
    from solver_private.solver_job_dispatch_outbox_uat_v1 where run_id=v_run_b;

    update public.optimization_runs_v2 set version_stamp=version_stamp where id=v_run_a;
    begin
      update public.optimization_runs_v2
      set version_stamp=jsonb_set(version_stamp,'{solverBuildId}','"changed"'::jsonb)
      where id=v_run_a;
    exception when others then
      if sqlerrm like 'VERSION_STAMP_IMMUTABLE_%' then v_stamp_change_blocked:=true;
      else raise; end if;
    end;
    begin
      update public.optimization_runs_v2
      set version_stamp=jsonb_set(version_stamp,'{schemaVersion}','2'::jsonb)
      where id=v_run_a;
    exception when others then
      if sqlerrm like 'VERSION_STAMP_IMMUTABLE_%' then v_schema_change_blocked:=true;
      else raise; end if;
    end;
    begin
      update public.optimization_runs_v2
      set version_stamp=jsonb_set(version_stamp,'{northflankRunId}','"other-run"'::jsonb)
      where id=v_run_a;
    exception when others then
      if sqlerrm like 'VERSION_STAMP_IMMUTABLE_%' then v_nf_change_blocked:=true;
      else raise; end if;
    end;

    v_results:=jsonb_build_object(
      'outboxOneToOne',v_duplicate_outbox_blocked,
      'sameScheduleBlocked',v_same_schedule_blocked,
      'globalConcurrency',v_third->>'status'='GLOBAL_LIMIT',
      'perOrganizationConcurrency',v_per_organization_concurrency,
      'targetClaim',coalesce((v_claim->>'claimed')::boolean,false),
      'duplicateClaimNoOp',v_duplicate_claim->>'status'='CONFLICT',
      'missingTargetNoFallback',v_missing_claim->>'status'='TARGET_NOT_FOUND',
      'wrongCapabilityBlocked',v_wrong_capability_blocked,
      'dispatchRetrySeparate',v_dispatch_retry_separate,
      'acceptanceUnknownNoRetry',v_acceptance_unknown_safe,
      'stampChangeBlocked',v_stamp_change_blocked,
      'schemaChangeBlocked',v_schema_change_blocked,
      'northflankRunChangeBlocked',v_nf_change_blocked
    );
    if exists(
      select 1 from jsonb_each(v_results) item where item.value<>'true'::jsonb
    ) then raise exception 'GATE_B_ASSERTION_FAILED: %',v_results; end if;
    raise exception 'GATE_B_ROLLBACK';
  exception when raise_exception then
    if sqlerrm<>'GATE_B_ROLLBACK' then raise; end if;
    v_rolled_back:=true;
  end;

  if exists(select 1 from public.optimization_runs_v2 where id in(
    v_run_a,v_run_a_waiting,v_run_b,v_run_b_waiting,v_run_same_schedule
  )) then raise exception 'GATE_B_ROLLBACK_FAILED'; end if;
  return v_results||jsonb_build_object('passed',v_rolled_back,'rolledBack',v_rolled_back);
end;
$$;


ALTER FUNCTION "public"."solver_job_contract_probe_uat_v1"() OWNER TO "postgres";

--
-- Name: solver_job_dispatcher_control_uat_v1(boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."solver_job_dispatcher_control_uat_v1"("p_enabled" boolean) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  update solver_private.solver_job_runtime_config_uat_v1
  set dispatcher_enabled=coalesce(p_enabled,false),updated_at=now()
  where singleton;
  return jsonb_build_object(
    'dispatcherEnabled',coalesce(p_enabled,false),
    'defaultExecutionMode','SERVICE'
  );
end;
$$;


ALTER FUNCTION "public"."solver_job_dispatcher_control_uat_v1"("p_enabled" boolean) OWNER TO "postgres";

--
-- Name: solver_job_reconcile_candidates_uat_v1(integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."solver_job_reconcile_candidates_uat_v1"("p_limit" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'runId',candidate.run_id,
    'northflankRunId',candidate.northflank_run_id,
    'dispatchStatus',candidate.dispatch_status
  ) order by candidate.updated_at,candidate.run_id),'[]'::jsonb)
  from (
    select o.run_id,o.northflank_run_id,o.dispatch_status,o.updated_at
    from solver_private.solver_job_dispatch_outbox_uat_v1 o
    where o.northflank_run_id is not null
      and o.dispatch_status in ('ACCEPTED','STARTING','RUNNING','SUCCEEDED')
      and (o.dispatch_status<>'SUCCEEDED' or o.job_finished_at is null)
    order by o.updated_at,o.run_id
    limit greatest(1,least(coalesce(p_limit,20),100))
  ) candidate
$$;


ALTER FUNCTION "public"."solver_job_reconcile_candidates_uat_v1"("p_limit" integer) OWNER TO "postgres";

--
-- Name: solver_job_reconcile_uat_v1("uuid", "text", "text", timestamp with time zone, timestamp with time zone, numeric, numeric, numeric, "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."solver_job_reconcile_uat_v1"("p_run_id" "uuid", "p_northflank_run_id" "text", "p_northflank_status" "text", "p_container_started_at" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_job_finished_at" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_peak_rss_mb" numeric DEFAULT NULL::numeric, "p_average_rss_mb" numeric DEFAULT NULL::numeric, "p_peak_cpu_percent" numeric DEFAULT NULL::numeric, "p_failure_code" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_item solver_private.solver_job_dispatch_outbox_uat_v1%rowtype;
  v_run_status text;
  v_status text:=upper(coalesce(p_northflank_status,''));
  v_billable numeric;
begin
  if v_status not in ('QUEUED','PENDING','STARTING','RUNNING','SUCCESS','FAILED')
  then raise exception 'NORTHFLANK_STATUS_INVALID'; end if;
  select * into v_item
  from solver_private.solver_job_dispatch_outbox_uat_v1
  where run_id=p_run_id for update;
  if v_item.run_id is null then raise exception 'DISPATCH_NOT_FOUND'; end if;
  if v_item.northflank_run_id is distinct from p_northflank_run_id then
    raise exception 'NORTHFLANK_RUN_ID_MISMATCH';
  end if;
  if p_container_started_at>now()+interval '5 minutes'
    or (p_job_finished_at is not null and p_container_started_at is not null
      and p_job_finished_at<p_container_started_at) then
    raise exception 'NORTHFLANK_TIMESTAMPS_INVALID';
  end if;
  select status into v_run_status
  from public.optimization_runs_v2 where id=p_run_id for update;
  if p_container_started_at is not null then
    v_billable:=extract(epoch from (
      coalesce(p_job_finished_at,now())-p_container_started_at
    ));
  end if;

  update solver_private.solver_job_dispatch_outbox_uat_v1
  set dispatch_status=case
        when v_status in ('QUEUED','PENDING','STARTING')
          and worker_claimed_at is null then 'STARTING'
        when v_status='RUNNING' and worker_claimed_at is null then 'STARTING'
        when v_status='RUNNING' then 'RUNNING'
        when v_status='SUCCESS' and v_run_status='READY' then 'SUCCEEDED'
        when v_status='SUCCESS' and v_run_status='CANCELLED' then 'CANCELLED'
        when v_status='SUCCESS' then 'FAILED'
        else 'FAILED' end,
      container_started_at=coalesce(
        solver_job_dispatch_outbox_uat_v1.container_started_at,
        p_container_started_at
      ),
      job_finished_at=coalesce(p_job_finished_at,job_finished_at),
      peak_rss_mb=coalesce(p_peak_rss_mb,peak_rss_mb),
      average_rss_mb=coalesce(p_average_rss_mb,average_rss_mb),
      peak_cpu_percent=coalesce(p_peak_cpu_percent,peak_cpu_percent),
      billable_seconds=case when v_billable is null then billable_seconds
        else greatest(v_billable,0) end,
      estimated_compute_cost_usd=case when v_billable is null
        then estimated_compute_cost_usd
        else greatest(v_billable,0)/3600*estimated_usd_per_hour end,
      last_error_code=case
        when v_status='FAILED' then coalesce(left(p_failure_code,100),'JOB_RUNTIME_FAILED')
        when v_status='SUCCESS' and v_run_status<>'READY'
          then 'JOB_EXITED_WITHOUT_READY'
        else last_error_code end,
      updated_at=now()
  where run_id=p_run_id;

  if v_status='FAILED' and v_run_status not in (
    'READY','FAILED','CANCELLED','STALE_INPUT'
  ) then
    update public.optimization_runs_v2
    set status='FAILED',phase='FAILED',
      failure_code=coalesce(left(p_failure_code,100),'JOB_RUNTIME_FAILED'),
      failure_message='Zadanie generatora zakończyło się przed zapisaniem wyniku.',
      lease_owner=null,lease_token=null,lease_expires_at=null,
      worker_execution_name=null,finished_at=now(),updated_at=now()
    where id=p_run_id;
    update public.optimization_run_strategies_v2
    set status='FAILED',phase='FAILED',
      failure_code=coalesce(left(p_failure_code,100),'JOB_RUNTIME_FAILED'),
      finished_at=now(),updated_at=now()
    where run_id=p_run_id and status<>'READY';
  end if;
  return jsonb_build_object(
    'runId',p_run_id,'northflankStatus',v_status,
    'runStatus',(select status from public.optimization_runs_v2 where id=p_run_id)
  );
end;
$$;


ALTER FUNCTION "public"."solver_job_reconcile_uat_v1"("p_run_id" "uuid", "p_northflank_run_id" "text", "p_northflank_status" "text", "p_container_started_at" timestamp with time zone, "p_job_finished_at" timestamp with time zone, "p_peak_rss_mb" numeric, "p_average_rss_mb" numeric, "p_peak_cpu_percent" numeric, "p_failure_code" "text") OWNER TO "postgres";

--
-- Name: solver_job_watchdog_uat_v1(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."solver_job_watchdog_uat_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_config solver_private.solver_job_runtime_config_uat_v1%rowtype;
  v_result jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended('solver-job-watchdog-uat-v1',0));
  select * into v_config
  from solver_private.solver_job_runtime_config_uat_v1 where singleton;

  update solver_private.solver_job_dispatch_outbox_uat_v1 o
  set dispatch_status='ACCEPTANCE_UNKNOWN',
      dispatcher_lease_token=null,dispatcher_lease_expires_at=null,
      last_error_code='DISPATCH_LEASE_EXPIRED_UNKNOWN',
      last_error='Dispatcher utracił lease po rozpoczęciu wywołania Northflank; automatyczny ponowny POST jest zablokowany.',
      updated_at=now()
  where o.dispatch_status='DISPATCHING'
    and o.dispatcher_lease_expires_at<now();

  with expired as (
    select o.run_id,o.northflank_run_id,
      case
        when o.dispatch_status='ACCEPTANCE_UNKNOWN'
          and o.dispatch_started_at<now()-make_interval(secs=>v_config.wall_timeout_seconds)
          then 'DISPATCH_ACCEPTANCE_UNRESOLVED'
        when o.dispatch_status in ('ACCEPTED','STARTING')
          and o.worker_claimed_at is null
          and o.northflank_accepted_at<now()-make_interval(secs=>v_config.claim_watchdog_seconds)
          then 'JOB_CLAIM_TIMEOUT'
        when o.dispatch_status='RUNNING'
          and r.status='RUNNING'
          and r.heartbeat_at<now()-make_interval(secs=>v_config.heartbeat_watchdog_seconds)
          then 'JOB_HEARTBEAT_TIMEOUT'
        else null
      end as failure_code
    from solver_private.solver_job_dispatch_outbox_uat_v1 o
    join public.optimization_runs_v2 r on r.id=o.run_id
  ), failed as (
    update solver_private.solver_job_dispatch_outbox_uat_v1 o
    set dispatch_status='FAILED',last_error_code=e.failure_code,
      last_error='Watchdog zatrzymał przebieg po przekroczeniu limitu czasu.',
      job_finished_at=coalesce(job_finished_at,now()),updated_at=now()
    from expired e
    where o.run_id=e.run_id and e.failure_code is not null
    returning o.run_id,o.northflank_run_id,e.failure_code
  ), failed_runs as (
    update public.optimization_runs_v2 r
    set status='FAILED',phase='FAILED',failure_code=f.failure_code,
      failure_message='Zadanie generatora przekroczyło limit czasu uruchomienia lub heartbeat.',
      lease_owner=null,lease_token=null,lease_expires_at=null,
      worker_execution_name=null,finished_at=now(),updated_at=now()
    from failed f
    where r.id=f.run_id
      and r.status not in ('READY','FAILED','CANCELLED','STALE_INPUT')
    returning r.id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'runId',f.run_id,'northflankRunId',f.northflank_run_id,
    'failureCode',f.failure_code,'abortRequired',f.northflank_run_id is not null
  ) order by f.run_id),'[]'::jsonb)
  into v_result from failed f;
  return jsonb_build_object('expired',coalesce(v_result,'[]'::jsonb));
end;
$$;


ALTER FUNCTION "public"."solver_job_watchdog_uat_v1"() OWNER TO "postgres";

--
-- Name: solver_load_snapshot_v2("uuid", "uuid", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."solver_load_snapshot_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_snapshot solver_private.optimization_snapshots_v2%rowtype;
begin
  if not solver_private.lease_is_live_v2(p_run_id,p_attempt_id,p_lease_token) then
    raise exception 'LEASE_LOST';
  end if;
  select * into v_snapshot from solver_private.optimization_snapshots_v2 where run_id=p_run_id;
  if v_snapshot.run_id is null then raise exception 'SNAPSHOT_NOT_FOUND'; end if;
  return jsonb_build_object(
    'runId',p_run_id,'snapshotHash',v_snapshot.snapshot_hash,'snapshot',v_snapshot.snapshot
  );
end;
$$;


ALTER FUNCTION "public"."solver_load_snapshot_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid") OWNER TO "postgres";

--
-- Name: solver_save_variant_before_b4f168("uuid", "uuid", "uuid", "jsonb", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."solver_save_variant_before_b4f168"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_variant" "jsonb", "p_gateway_version" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_result jsonb;
  v_variant_id uuid;
  v_frontend_version text;
  v_solver_version text;
  v_snapshot_schema_version integer;
  v_snapshot_hash text;
  v_matrix_version_id uuid;
  v_matrix_version integer;
  v_matrix_content_hash text;
  v_strategy_semantics_version text;
  v_worker_id text;
  v_worker_version text;
  v_worker_execution_name text;
  v_version_stamp jsonb;
  v_existing_stamp jsonb;
begin
  if p_gateway_version is null
    or p_gateway_version !~ '^[A-Za-z0-9][A-Za-z0-9._:@/-]*$' then
    raise exception 'GATEWAY_VERSION_INVALID';
  end if;
  perform solver_private.validate_stage_proof_b4f166(p_variant->'stageObjectives');

  select
    r.version_stamp#>>'{frontend,buildId}',r.solver_version,
    r.snapshot_schema_version,r.snapshot_hash,r.matrix_version_id,
    mv.version,mv.content_hash,mv.settings->>'strategySemanticsVersion',
    a.worker_id,a.worker_version,a.worker_execution_name,r.version_stamp
  into
    v_frontend_version,v_solver_version,v_snapshot_schema_version,
    v_snapshot_hash,v_matrix_version_id,v_matrix_version,
    v_matrix_content_hash,v_strategy_semantics_version,v_worker_id,
    v_worker_version,v_worker_execution_name,v_existing_stamp
  from public.optimization_runs_v2 r
  join solver_private.optimization_attempts_v2 a
    on a.id=p_attempt_id and a.run_id=r.id
  join public.matrix_versions mv on mv.id=r.matrix_version_id
  where r.id=p_run_id;

  if v_frontend_version is null then
    raise exception 'FRONTEND_VERSION_STAMP_MISSING';
  end if;
  if v_solver_version is null or v_worker_version is null
    or v_matrix_content_hash is null or v_strategy_semantics_version is null then
    raise exception 'RUNTIME_VERSION_STAMP_INCOMPLETE';
  end if;
  if not coalesce(v_existing_stamp,'{}'::jsonb) ? 'executionMode' then
    v_existing_stamp:=solver_private.build_run_version_stamp_uat_v1(
      p_run_id,v_frontend_version,'SERVICE'
    )||coalesce(v_existing_stamp,'{}'::jsonb);
  end if;

  v_version_stamp:=v_existing_stamp||jsonb_build_object(
    'frontend',jsonb_build_object('buildId',v_frontend_version),
    'solver',jsonb_strip_nulls(jsonb_build_object(
      'configuredVersion',v_solver_version,
      'workerVersion',v_worker_version,
      'workerId',v_worker_id,
      'workerExecutionName',v_worker_execution_name,
      'commit',v_existing_stamp->>'solverCommit',
      'buildId',v_existing_stamp->>'solverBuildId',
      'imageDigest',v_existing_stamp->'solverImageDigest'
    )),
    'gateway',jsonb_build_object('deploymentId',p_gateway_version),
    'database',jsonb_build_object(
      'schemaVersion','20260824163743_uat_northflank_job_runtime'
    ),
    'strategyConfig',jsonb_build_object(
      'matrixVersionId',v_matrix_version_id,
      'matrixVersion',v_matrix_version,
      'contentHash',v_matrix_content_hash,
      'strategySemanticsVersion',v_strategy_semantics_version,
      'snapshotHash',v_existing_stamp->>'strategyConfigVersion'
    ),
    'snapshot',jsonb_build_object(
      'schemaVersion',v_snapshot_schema_version,
      'snapshotHash',v_snapshot_hash
    )
  );
  v_version_stamp:=solver_private.version_stamp_set_once_uat_v1(
    v_version_stamp,'gatewayVersion',to_jsonb(p_gateway_version)
  );

  v_result:=public.solver_save_variant_v2(
    p_run_id,p_attempt_id,p_lease_token,p_variant
  );
  v_variant_id:=nullif(v_result->>'variantId','')::uuid;
  if v_variant_id is null then raise exception 'VARIANT_ID_MISSING'; end if;

  update public.plan_variants_v2 v
  set stage_proof=p_variant->'stageObjectives',version_stamp=v_version_stamp
  where v.id=v_variant_id and v.run_id=p_run_id;
  if not found then raise exception 'VARIANT_NOT_FOUND'; end if;
  update public.optimization_runs_v2 r
  set version_stamp=v_version_stamp,updated_at=now()
  where r.id=p_run_id;

  return v_result||jsonb_build_object(
    'stageCount',jsonb_array_length(p_variant->'stageObjectives'),
    'versionStamp',v_version_stamp
  );
end;
$_$;


ALTER FUNCTION "public"."solver_save_variant_before_b4f168"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_variant" "jsonb", "p_gateway_version" "text") OWNER TO "postgres";

--
-- Name: solver_save_variant_before_b4f169("uuid", "uuid", "uuid", "jsonb", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."solver_save_variant_before_b4f169"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_variant" "jsonb", "p_gateway_version" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_result jsonb;
  v_variant_id uuid;
  v_version_stamp jsonb;
begin
  v_result:=public.solver_save_variant_before_b4f168(
    p_run_id,p_attempt_id,p_lease_token,p_variant,p_gateway_version
  );
  v_variant_id:=nullif(v_result->>'variantId','')::uuid;
  if v_variant_id is null then raise exception 'VARIANT_ID_MISSING'; end if;

  select v.version_stamp into v_version_stamp
  from public.plan_variants_v2 v
  where v.id=v_variant_id and v.run_id=p_run_id;
  if v_version_stamp is null then raise exception 'VERSION_STAMP_MISSING'; end if;

  v_version_stamp:=jsonb_set(
    v_version_stamp,
    '{database,schemaVersion}',
    to_jsonb('20260822203000_b4f168_database_stamp'::text),
    true
  );

  update public.plan_variants_v2 v
  set version_stamp=v_version_stamp
  where v.id=v_variant_id and v.run_id=p_run_id;

  update public.optimization_runs_v2 r
  set version_stamp=v_version_stamp,
      updated_at=now()
  where r.id=p_run_id;

  return jsonb_set(v_result,'{versionStamp}',v_version_stamp,true);
end;
$$;


ALTER FUNCTION "public"."solver_save_variant_before_b4f169"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_variant" "jsonb", "p_gateway_version" "text") OWNER TO "postgres";

--
-- Name: solver_save_variant_before_b4f170("uuid", "uuid", "uuid", "jsonb", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."solver_save_variant_before_b4f170"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_variant" "jsonb", "p_gateway_version" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_result jsonb;
begin
  v_result:=public.solver_save_variant_before_nfjob_uat_v1(
    p_run_id,p_attempt_id,p_lease_token,p_variant,p_gateway_version
  );
  update solver_private.solver_job_dispatch_outbox_uat_v1
  set solver_finished_at=coalesce(solver_finished_at,now()),
      result_saved_at=now(),updated_at=now()
  where run_id=p_run_id;
  return v_result;
end;
$$;


ALTER FUNCTION "public"."solver_save_variant_before_b4f170"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_variant" "jsonb", "p_gateway_version" "text") OWNER TO "postgres";

--
-- Name: solver_save_variant_before_nfjob_uat_v1("uuid", "uuid", "uuid", "jsonb", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."solver_save_variant_before_nfjob_uat_v1"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_variant" "jsonb", "p_gateway_version" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_result jsonb;
  v_variant_id uuid;
  v_version_stamp jsonb;
begin
  v_result:=public.solver_save_variant_before_b4f169(
    p_run_id,p_attempt_id,p_lease_token,p_variant,p_gateway_version
  );
  v_variant_id:=nullif(v_result->>'variantId','')::uuid;
  if v_variant_id is null then raise exception 'VARIANT_ID_MISSING'; end if;

  select v.version_stamp into v_version_stamp
  from public.plan_variants_v2 v
  where v.id=v_variant_id and v.run_id=p_run_id;
  if v_version_stamp is null then raise exception 'VERSION_STAMP_MISSING'; end if;
  v_version_stamp:=jsonb_set(
    v_version_stamp,
    '{database,schemaVersion}',
    to_jsonb('20260822220000_b4f169_deterministic_fairness_quality_gate'::text),
    true
  );
  update public.plan_variants_v2 v
  set version_stamp=v_version_stamp
  where v.id=v_variant_id and v.run_id=p_run_id;
  update public.optimization_runs_v2 r
  set version_stamp=v_version_stamp,updated_at=now()
  where r.id=p_run_id;
  return jsonb_set(v_result,'{versionStamp}',v_version_stamp,true);
end;
$$;


ALTER FUNCTION "public"."solver_save_variant_before_nfjob_uat_v1"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_variant" "jsonb", "p_gateway_version" "text") OWNER TO "postgres";

--
-- Name: solver_save_variant_v2("uuid", "uuid", "uuid", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."solver_save_variant_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_variant" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_snapshot jsonb;
  v_snapshot_hash text;
  v_strategy_id uuid := nullif(p_variant->>'strategyId','')::uuid;
  v_run_strategy public.optimization_run_strategies_v2%rowtype;
  v_existing public.plan_variants_v2%rowtype;
  v_variant_id uuid := gen_random_uuid();
  v_validation jsonb;
  v_assignment_count integer;
  v_unfilled_count integer;
  v_total_units bigint;
  v_base_units bigint;
  v_total_minor bigint;
  v_base_minor bigint;
  v_budget_minor bigint;
  v_equivalent_id uuid;
  v_objective_bound bigint;
begin
  perform solver_private.lock_planning_revision_v2();
  if not solver_private.lease_is_live_v2(p_run_id,p_attempt_id,p_lease_token) then
    raise exception 'LEASE_LOST';
  end if;
  select s.snapshot,s.snapshot_hash into v_snapshot,v_snapshot_hash
  from solver_private.optimization_snapshots_v2 s where s.run_id=p_run_id;
  if v_snapshot is null then raise exception 'SNAPSHOT_NOT_FOUND'; end if;
  select * into v_run_strategy
  from public.optimization_run_strategies_v2 rs
  where rs.run_id=p_run_id and rs.strategy_id=v_strategy_id for update;
  if v_run_strategy.id is null then raise exception 'RUN_STRATEGY_NOT_FOUND'; end if;
  select * into v_existing from public.plan_variants_v2 v
  where v.run_strategy_id=v_run_strategy.id;
  if v_existing.id is not null then
    if v_existing.solution_hash=p_variant->>'solutionHash' then
      return jsonb_build_object('variantId',v_existing.id,'reused',true);
    end if;
    raise exception 'RUN_STRATEGY_VARIANT_ALREADY_SAVED';
  end if;

  v_validation := solver_private.validate_variant_v2(v_snapshot,p_variant);
  v_assignment_count := (v_validation->>'assignmentCount')::integer;
  v_unfilled_count := (v_validation->>'unfilledCount')::integer;
  v_total_units := (v_validation->>'totalCostUnits')::bigint;
  v_budget_minor := nullif(v_validation->>'budgetMinor','')::bigint;
  select v.id into v_equivalent_id from public.plan_variants_v2 v
  where v.run_id=p_run_id and v.solution_hash=p_variant->>'solutionHash'
  order by v.created_at limit 1;
  select nullif(x.value->>'bestBound','')::numeric::bigint into v_objective_bound
  from jsonb_array_elements(coalesce(p_variant->'stageObjectives','[]'::jsonb))
    with ordinality x(value,ordinality)
  where x.value ? 'bestBound' order by x.ordinality desc limit 1;

  insert into public.plan_variants_v2(
    id,run_id,run_strategy_id,strategy_id,name,status,hard_violations,
    assignment_count,unfilled_count,solver_status,solution_hash,objective_bound,
    metrics,recommended,selected,equivalent_to_variant_id,snapshot_hash
  ) values(
    v_variant_id,p_run_id,v_run_strategy.id,v_strategy_id,
    coalesce(nullif(p_variant->>'label',''),(select name from public.matrix_strategies_v2 where id=v_strategy_id)),
    'READY',0,v_assignment_count,v_unfilled_count,
    case when coalesce((p_variant->>'optimal')::boolean,false) then 'OPTIMAL' else 'FEASIBLE' end,
    p_variant->>'solutionHash',v_objective_bound,
    (coalesce(p_variant->'metrics','{}'::jsonb)-'TOTAL_COST'-'TOTAL_COST_MINOR'),
    false,false,v_equivalent_id,v_snapshot_hash
  );

  insert into public.plan_shifts_v2(
    variant_id,slot_group_key,shift_template_id,location_id,shift_date,
    starts_at,ends_at,source_type,source_id
  )
  select distinct on (slot->>'occurrenceId')
    v_variant_id,slot->>'occurrenceId',(slot->>'shiftTemplateId')::uuid,
    (slot->>'locationId')::uuid,(slot->>'date')::date,
    (slot->>'start')::timestamptz,(slot->>'end')::timestamptz,'MATRIX',
    (slot->>'demandId')::uuid
  from jsonb_array_elements(v_snapshot->'slots') slot
  order by slot->>'occurrenceId',slot->>'slotId';

  insert into public.plan_assignments_v2(
    variant_id,shift_id,slot_key,employee_id,role_id,locked,explanation
  )
  select v_variant_id,sh.id,a.value->>'slotId',(a.value->>'employeeId')::uuid,
    (slot.value->>'roleId')::uuid,
    exists(select 1 from jsonb_array_elements(coalesce(v_snapshot->'lockedAssignments','[]'::jsonb)) l
      where l.value->>'slotId'=a.value->>'slotId'),
    jsonb_build_object('strategyId',v_strategy_id,'solver','ORTOOLS_V2')
  from jsonb_array_elements(p_variant->'assignments') a
  join jsonb_array_elements(v_snapshot->'slots') slot
    on slot.value->>'slotId'=a.value->>'slotId'
  join public.plan_shifts_v2 sh
    on sh.variant_id=v_variant_id and sh.slot_group_key=slot.value->>'occurrenceId';

  insert into public.plan_assignment_duties_v2(assignment_id,duty_id)
  select pa.id,(d.value#>>'{}')::uuid
  from public.plan_assignments_v2 pa
  join jsonb_array_elements(v_snapshot->'slots') slot on slot.value->>'slotId'=pa.slot_key
  cross join lateral jsonb_array_elements(coalesce(slot.value->'dutyIds','[]'::jsonb)) d
  where pa.variant_id=v_variant_id;

  insert into public.plan_issues_v2(
    variant_id,shift_id,slot_key,issue_code,severity,role_id,duty_id,
    required_count,assigned_count,message,metadata
  )
  select v_variant_id,sh.id,u.value#>>'{}','UNFILLED_SLOT','WARNING',
    (slot.value->>'roleId')::uuid,
    case when jsonb_array_length(coalesce(slot.value->'dutyIds','[]'::jsonb))=1
      then (slot.value->'dutyIds'->>0)::uuid else null end,
    1,0,'Nieobsadzone miejsce wymagane przez Matrix.',
    jsonb_build_object('demandId',slot.value->>'demandId')
  from jsonb_array_elements(p_variant->'unfilledSlotIds') u
  join jsonb_array_elements(v_snapshot->'slots') slot
    on slot.value->>'slotId'=u.value#>>'{}'
  join public.plan_shifts_v2 sh
    on sh.variant_id=v_variant_id and sh.slot_group_key=slot.value->>'occurrenceId';

  insert into solver_private.plan_assignment_cost_components_v2(
    assignment_id,pay_rule_id,component_code,amount_minor,quantity_minutes,calculation_basis
  )
  select pa.id,
    case when c.value->>'ruleId'='BASE' then null else (c.value->>'ruleId')::uuid end,
    coalesce(nullif(c.value->>'calculationType',''),'UNKNOWN'),
    round((c.value->>'costUnits')::numeric/60)::bigint,
    (slot.value->>'durationMinutes')::integer,
    jsonb_build_object('costUnits',(c.value->>'costUnits')::bigint)
  from jsonb_array_elements(p_variant->'assignments') a
  join public.plan_assignments_v2 pa
    on pa.variant_id=v_variant_id and pa.slot_key=a.value->>'slotId'
  join jsonb_array_elements(v_snapshot->'slots') slot
    on slot.value->>'slotId'=a.value->>'slotId'
  cross join lateral jsonb_array_elements(coalesce(a.value->'costComponents','[]'::jsonb)) c;

  select coalesce(sum((c.value->>'costUnits')::bigint),0) into v_base_units
  from jsonb_array_elements(p_variant->'assignments') a
  cross join lateral jsonb_array_elements(coalesce(a.value->'costComponents','[]'::jsonb)) c
  where c.value->>'ruleId'='BASE';
  v_base_minor := round(v_base_units::numeric/60)::bigint;
  v_total_minor := round(v_total_units::numeric/60)::bigint;
  insert into solver_private.plan_variant_finance_v2(
    variant_id,base_cost_units,additions_cost_units,total_cost_units,
    base_cost_minor,additions_cost_minor,total_cost_minor,currency,budget_minor,
    hard_budget_exceeded,breakdown
  ) values(
    v_variant_id,v_base_units,greatest(v_total_units-v_base_units,0),v_total_units,
    v_base_minor,greatest(v_total_minor-v_base_minor,0),v_total_minor,
    v_snapshot->>'currency',v_budget_minor,
    coalesce((v_snapshot->'budget'->>'hard')::boolean,false)
      and v_budget_minor is not null and v_total_units>v_budget_minor*60,
    jsonb_build_object(
      'costScale','60 units = 1 minor currency unit',
      'currency',v_snapshot->>'currency',
      'budgets',coalesce(v_snapshot->'budgets','[]'::jsonb)
    )
  );

  update public.optimization_run_strategies_v2 set
    status='READY',phase='SAVED',progress=100,
    metrics=(coalesce(p_variant->'metrics','{}'::jsonb)-'TOTAL_COST'-'TOTAL_COST_MINOR'),
    started_at=coalesce(started_at,now()),finished_at=now(),updated_at=now()
  where id=v_run_strategy.id;
  update public.optimization_runs_v2 r set
    phase='SAVING_VARIANTS',
    progress=greatest(r.progress,least(99,(
      select floor(90.0*count(*)/greatest((select count(*) from public.optimization_run_strategies_v2 all_s where all_s.run_id=p_run_id),1))::integer+5
      from public.optimization_run_strategies_v2 ready_s where ready_s.run_id=p_run_id and ready_s.status='READY'
    ))),heartbeat_at=now(),lease_expires_at=now()+interval '120 seconds',updated_at=now()
  where r.id=p_run_id and r.lease_token=p_lease_token;
  return jsonb_build_object('variantId',v_variant_id,'reused',false,
    'assignmentCount',v_assignment_count,'unfilledCount',v_unfilled_count);
end;
$$;


ALTER FUNCTION "public"."solver_save_variant_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_variant" "jsonb") OWNER TO "postgres";

--
-- Name: FUNCTION "solver_save_variant_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_variant" "jsonb"); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION "public"."solver_save_variant_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_variant" "jsonb") IS 'Service-role-only, set-based variant validation and materialization.';


--
-- Name: solver_save_variant_v2("uuid", "uuid", "uuid", "jsonb", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."solver_save_variant_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_variant" "jsonb", "p_gateway_version" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_result jsonb;
  v_variant_id uuid;
  v_version_stamp jsonb;
begin
  v_result:=public.solver_save_variant_before_b4f170(
    p_run_id,p_attempt_id,p_lease_token,p_variant,p_gateway_version
  );
  v_variant_id:=nullif(v_result->>'variantId','')::uuid;
  if v_variant_id is null then raise exception 'VARIANT_ID_MISSING'; end if;

  select v.version_stamp into v_version_stamp
  from public.plan_variants_v2 v
  where v.id=v_variant_id and v.run_id=p_run_id;
  if v_version_stamp is null then raise exception 'VERSION_STAMP_MISSING'; end if;
  v_version_stamp:=jsonb_set(
    v_version_stamp,
    '{database,schemaVersion}',
    to_jsonb('20260824160525_b4f170_fairness_target_best_valid_fallback'::text),
    true
  );
  update public.plan_variants_v2 v
  set version_stamp=v_version_stamp
  where v.id=v_variant_id and v.run_id=p_run_id;
  update public.optimization_runs_v2 r
  set version_stamp=v_version_stamp,updated_at=now()
  where r.id=p_run_id;
  return jsonb_set(v_result,'{versionStamp}',v_version_stamp,true);
end;
$$;


ALTER FUNCTION "public"."solver_save_variant_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_variant" "jsonb", "p_gateway_version" "text") OWNER TO "postgres";

--
-- Name: standby_activate_before_phase1_uat_v1("uuid", "uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."standby_activate_before_phase1_uat_v1"("p_standby_id" "uuid", "p_original_assignment_id" "uuid", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "public"."standby_activate_before_phase1_uat_v1"("p_standby_id" "uuid", "p_original_assignment_id" "uuid", "p_reason" "text") OWNER TO "postgres";

--
-- Name: standby_activate_uat_v2("uuid", "uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."standby_activate_uat_v2"("p_standby_id" "uuid", "p_original_assignment_id" "uuid", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_role uuid;v_location uuid;
begin
  select standby.role_id,shift.location_id into v_role,v_location
  from public.published_standby_assignments_v2 standby
  join public.plan_assignments_v2 assignment on assignment.id=p_original_assignment_id
  join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
  where standby.id=p_standby_id;
  if v_role is null or v_location is null then raise exception 'STANDBY_RESOURCE_NOT_FOUND'; end if;
  if not public.matrix_v2_can_manage_resource_uat_v1(v_role,v_location,null)
    then raise exception 'RESOURCE_SCOPE_FORBIDDEN'; end if;
  perform authorization_private.enter_resource_scope_uat_v1();
  return public.standby_activate_before_phase1_uat_v1(p_standby_id,p_original_assignment_id,p_reason);
end;
$$;


ALTER FUNCTION "public"."standby_activate_uat_v2"("p_standby_id" "uuid", "p_original_assignment_id" "uuid", "p_reason" "text") OWNER TO "postgres";

--
-- Name: standby_activate_uat_v3("uuid", "uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."standby_activate_uat_v3"("p_standby_id" "uuid", "p_original_assignment_id" "uuid", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_standby public.published_standby_assignments_v2%rowtype;v_assignment public.plan_assignments_v2%rowtype;
begin
  select * into v_standby from public.published_standby_assignments_v2 where id=p_standby_id for update;
  select * into v_assignment from public.plan_assignments_v2 where id=p_original_assignment_id;
  if v_standby.id is null or v_assignment.id is null or not (v_assignment.role_id=any(coalesce(v_standby.eligible_role_ids,array[v_standby.role_id]))) then
    raise exception 'STANDBY_TARGET_ROLE_NOT_COVERED';
  end if;
  if v_standby.tier=2 and exists(select 1 from public.published_standby_assignments_v2 tier1
    where tier1.month=v_standby.month and tier1.standby_date=v_standby.standby_date
      and coalesce(tier1.standby_group_code,tier1.role_id::text)=coalesce(v_standby.standby_group_code,v_standby.role_id::text)
      and tier1.tier=1 and tier1.status='PLANNED') then
    raise exception 'STANDBY_TIER_1_MUST_BE_USED_OR_DECLINED_FIRST';
  end if;
  update public.published_standby_assignments_v2 set role_id=v_assignment.role_id where id=p_standby_id;
  return public.standby_activate_uat_v2(p_standby_id,p_original_assignment_id,p_reason);
end;
$$;


ALTER FUNCTION "public"."standby_activate_uat_v3"("p_standby_id" "uuid", "p_original_assignment_id" "uuid", "p_reason" "text") OWNER TO "postgres";

--
-- Name: standby_decline_self_uat_v2("uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."standby_decline_self_uat_v2"("p_standby_id" "uuid", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_employee uuid;
begin
  select employee.id into v_employee from public.employees employee
  where employee.auth_user_id=auth.uid() and employee.active;
  update public.published_standby_assignments_v2 standby set
    status='DECLINED',activation_reason=trim(p_reason)
  where standby.id=p_standby_id and standby.employee_id=v_employee
    and standby.status='PLANNED';
  if not found then raise exception 'STANDBY_NOT_DECLINABLE'; end if;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'standby_assignment_v2',p_standby_id::text,'DECLINE',
    jsonb_build_object('reason',trim(p_reason)));
  return jsonb_build_object('id',p_standby_id,'status','DECLINED');
end;
$$;


ALTER FUNCTION "public"."standby_decline_self_uat_v2"("p_standby_id" "uuid", "p_reason" "text") OWNER TO "postgres";

--
-- Name: transition_role_plan("uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."transition_role_plan"("p_section_id" "uuid", "p_status" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_old text; begin
 if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
 if p_status not in ('DRAFT','READY','SUBMITTED','CHANGES_REQUESTED','APPROVED','LOCKED','ARCHIVED') then raise exception 'INVALID_STATUS'; end if;
 select status into v_old from role_plan_sections where id=p_section_id for update;
 if v_old is null then raise exception 'SECTION_NOT_FOUND'; end if;
 update role_plan_sections set status=p_status,updated_at=now(),submitted_at=case when p_status='SUBMITTED' then now() else submitted_at end,approved_at=case when p_status='APPROVED' then now() else approved_at end,approved_by=case when p_status='APPROVED' then auth.uid() else approved_by end where id=p_section_id;
 return jsonb_build_object('id',p_section_id,'from',v_old,'to',p_status);
end $$;


ALTER FUNCTION "public"."transition_role_plan"("p_section_id" "uuid", "p_status" "text") OWNER TO "postgres";

--
-- Name: uat_master_employee_availability_days_save_v2("uuid", "date"[], "text", boolean, time without time zone, time without time zone, "uuid", "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."uat_master_employee_availability_days_save_v2"("p_employee_id" "uuid", "p_dates" "date"[], "p_kind" "text", "p_all_day" boolean DEFAULT true, "p_local_start" time without time zone DEFAULT NULL::time without time zone, "p_local_end" time without time zone DEFAULT NULL::time without time zone, "p_preferred_location_id" "uuid" DEFAULT NULL::"uuid", "p_note" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_actor uuid:=auth.uid(); v_day date; v_kind text:=upper(trim(coalesce(p_kind,'')));
  v_saved integer:=0; v_role uuid; v_hot_limit integer; v_existing_hard integer;
  v_pending integer:=0; v_event uuid; v_matrix uuid; v_timezone text;
  v_day_start timestamptz; v_day_end timestamptz;
begin
  perform solver_private.assert_uat_master_persona_v2();
  if not exists(select 1 from public.employees employee where employee.id=p_employee_id
    and employee.active and employee.archived_at is null) then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  if v_kind not in ('AVAILABLE','PREFER_NOT_TO_WORK','CANNOT_WORK')
    or coalesce(cardinality(p_dates),0)=0 or cardinality(p_dates)>62 then
    raise exception 'INVALID_AVAILABILITY_REQUEST';
  end if;
  select matrix.id,matrix.settings->>'timezone' into v_matrix,v_timezone
  from public.matrix_versions matrix where matrix.status='ACTIVE' and matrix.schema_version>=2
  order by matrix.effective_from desc,matrix.version desc limit 1;
  if v_matrix is null or v_timezone is null then raise exception 'MATRIX_V2_NOT_FOUND'; end if;
  foreach v_day in array p_dates loop
    if v_day is null then raise exception 'INVALID_DATE_RANGE'; end if;
    v_day_start:=v_day::timestamp at time zone v_timezone;
    v_day_end:=(v_day+1)::timestamp at time zone v_timezone;
    select grant_row.role_id into v_role from public.matrix_employee_roles_v2 grant_row
    where grant_row.matrix_version_id=v_matrix and grant_row.employee_id=p_employee_id
      and grant_row.active order by grant_row.is_primary desc,grant_row.id limit 1;
    if v_kind='CANNOT_WORK' then
      select event.id,limit_row.maximum_hard_unavailable into v_event,v_hot_limit
      from public.workforce_calendar_events_v2 event
      join public.workforce_hot_day_limits_v2 limit_row on limit_row.event_id=event.id
      where event.status='ACTIVE' and event.event_kind='HOT_DAY'
        and event.event_date=v_day and event.matrix_version_id=v_matrix
        and limit_row.role_id=v_role limit 1;
      if v_hot_limit is not null then
        select count(distinct constraint_row.employee_id) into v_existing_hard
        from public.employee_time_constraints_v2 constraint_row
        where constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
          and constraint_row.employee_id<>p_employee_id
          and constraint_row.time_range && tstzrange(v_day_start,v_day_end,'[)');
        if v_existing_hard>=v_hot_limit then
          insert into public.availability_exception_reviews_v2(
            employee_id,matrix_version_id,hot_day_event_id,role_id,work_date,
            requested_range,note,status,requested_by
          ) values(
            p_employee_id,v_matrix,v_event,v_role,v_day,tstzrange(v_day_start,v_day_end,'[)'),
            nullif(trim(p_note),''),'PENDING',v_actor
          ) on conflict(employee_id,work_date,role_id) where status='PENDING'
          do update set note=excluded.note,requested_range=excluded.requested_range,
            requested_at=now(),requested_by=v_actor;
          v_pending:=v_pending+1;
          continue;
        end if;
      end if;
    else
      update public.availability_exception_reviews_v2 set status='CANCELLED',
        reviewed_at=now(),reviewed_by=v_actor,review_reason='Anulowano w trybie MASTER UAT.'
      where employee_id=p_employee_id and work_date=v_day and status='PENDING';
    end if;
    perform solver_private.uat_master_save_employee_day_v2(v_actor,p_employee_id,v_day,v_kind,
      p_all_day,p_local_start,p_local_end,p_preferred_location_id,p_note);
    v_saved:=v_saved+1;
  end loop;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'employee_availability_v2',p_employee_id::text,'UAT_MASTER_SET_DAYS',
    jsonb_build_object('dates',p_dates,'kind',v_kind,'savedDays',v_saved,
      'pendingReviewDays',v_pending,'actingAsEmployeeId',p_employee_id));
  return jsonb_build_object('employeeId',p_employee_id,'savedDays',v_saved,
    'pendingReviewDays',v_pending,'kind',v_kind);
end;
$$;


ALTER FUNCTION "public"."uat_master_employee_availability_days_save_v2"("p_employee_id" "uuid", "p_dates" "date"[], "p_kind" "text", "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone, "p_preferred_location_id" "uuid", "p_note" "text") OWNER TO "postgres";

--
-- Name: uat_master_employee_portal_context_v2("uuid", "date"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."uat_master_employee_portal_context_v2"("p_employee_id" "uuid", "p_month" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_month date:=date_trunc('month',p_month)::date; v_matrix uuid; v_timezone text;
  v_profile public.matrix_employee_profiles_v2%rowtype; v_calendar jsonb; v_preferences jsonb;
  v_publication_conflict boolean:=false;
begin
  perform solver_private.assert_uat_master_persona_v2();
  select matrix.id,matrix.settings->>'timezone' into v_matrix,v_timezone
  from public.matrix_versions matrix where matrix.status in ('ACTIVE','ARCHIVED')
    and matrix.schema_version>=2 and solver_private.matrix_covers_planning_month_uat_v1(matrix.effective_from,v_month)
  order by matrix.effective_from desc,matrix.version desc limit 1;
  select * into v_profile from public.matrix_employee_profiles_v2 profile
  where profile.matrix_version_id=v_matrix and profile.employee_id=p_employee_id
    and profile.active and profile.archived_at is null;
  if v_profile.id is null then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  begin
    v_calendar:=public.published_company_calendar_uat_v2(v_month);
  exception when others then
    if sqlerrm='SCHEDULE_PUBLICATION_CONFLICT_REQUIRES_OWNER_RESOLUTION' then
      v_publication_conflict:=true;
      v_calendar:=jsonb_build_object('month',v_month,'assignments','[]'::jsonb,
        'conflict',true);
    else raise;
    end if;
  end;
  v_preferences:=jsonb_build_object(
    'employeeId',p_employee_id,'month',v_month,
    'employee',jsonb_build_object(
      'MORNING',coalesce((select upper(preference.preference_value->>'level')
        from public.employee_preferences preference where preference.employee_id=p_employee_id
          and preference.status='ACTIVE' and preference.source='GRAFIK_PRO'
          and preference.preference_type='PREFERRED_SHIFT'
          and upper(preference.preference_value->>'period')='MORNING'
          and preference.valid_from<v_month+interval '1 month' and preference.valid_to>=v_month
        order by preference.created_at desc limit 1),'NEUTRAL'),
      'MIDDLE',coalesce((select upper(preference.preference_value->>'level')
        from public.employee_preferences preference where preference.employee_id=p_employee_id
          and preference.status='ACTIVE' and preference.source='GRAFIK_PRO'
          and preference.preference_type='PREFERRED_SHIFT'
          and upper(preference.preference_value->>'period')='MIDDLE'
          and preference.valid_from<v_month+interval '1 month' and preference.valid_to>=v_month
        order by preference.created_at desc limit 1),'NEUTRAL'),
      'EVENING',coalesce((select upper(preference.preference_value->>'level')
        from public.employee_preferences preference where preference.employee_id=p_employee_id
          and preference.status='ACTIVE' and preference.source='GRAFIK_PRO'
          and preference.preference_type='PREFERRED_SHIFT'
          and upper(preference.preference_value->>'period')='EVENING'
          and preference.valid_from<v_month+interval '1 month' and preference.valid_to>=v_month
        order by preference.created_at desc limit 1),'NEUTRAL')),
    'effective',coalesce(solver_private.alpha16_shift_rules_v2(p_employee_id,v_matrix,v_month)->'periods','{}'::jsonb),
    'managerOverrides','{}'::jsonb);
  return jsonb_build_object(
    'employee',jsonb_build_object('id',p_employee_id,'employeeNo',v_profile.employee_no,
      'firstName',v_profile.first_name,'lastName',v_profile.last_name,
      'primaryRole',coalesce((select role.name from public.matrix_employee_roles_v2 grant_row
        join public.matrix_roles_v2 role on role.id=grant_row.role_id
        where grant_row.matrix_version_id=v_matrix and grant_row.employee_id=p_employee_id
          and grant_row.active order by grant_row.is_primary desc,role.sort_order limit 1),'—'),
      'locations',coalesce((select jsonb_agg(jsonb_build_object('code',location.code,'name',location.name)
        order by location.sort_order) from public.matrix_employee_locations_v2 grant_row
        join public.matrix_locations_v2 location on location.id=grant_row.location_id
        where grant_row.matrix_version_id=v_matrix and grant_row.employee_id=p_employee_id
          and grant_row.active and (grant_row.standard_allowed or grant_row.overtime_allowed)),'[]'::jsonb)),
    'assignments',coalesce((select jsonb_agg(item.value order by item.value->>'startsAt')
      from jsonb_array_elements(coalesce(v_calendar->'assignments','[]'::jsonb)) item
      where item.value->>'employeeId'=p_employee_id::text),'[]'::jsonb),
    'standby',coalesce((select jsonb_agg(jsonb_build_object('id',standby.id,
      'date',standby.standby_date,'tier',standby.tier,'status',standby.status,
      'roleId',standby.role_id,'roleName',role.name,'activatedShiftId',standby.activated_shift_id)
      order by standby.standby_date,standby.tier)
      from public.published_standby_assignments_v2 standby
      join public.matrix_roles_v2 role on role.id=standby.role_id
      where standby.employee_id=p_employee_id and standby.month=v_month
        and standby.status in ('PLANNED','ACTIVATED','DECLINED')),'[]'::jsonb),
    'attendance','[]'::jsonb,
    'timeConstraints',solver_private.uat_master_employee_constraints_v2(
      p_employee_id,v_month,v_matrix,v_timezone),
    'shiftPreferences',v_preferences,'companyCalendar',v_calendar,
    'publicationConflict',v_publication_conflict,'masterPersona',true
  );
end;
$$;


ALTER FUNCTION "public"."uat_master_employee_portal_context_v2"("p_employee_id" "uuid", "p_month" "date") OWNER TO "postgres";

--
-- Name: uat_master_employee_shift_preferences_save_v2("uuid", "date", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."uat_master_employee_shift_preferences_save_v2"("p_employee_id" "uuid", "p_month" "date", "p_preferences" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_month date:=date_trunc('month',p_month)::date; v_period text; v_level text;
begin
  perform solver_private.assert_uat_master_persona_v2();
  if p_month is null or jsonb_typeof(p_preferences)<>'object' then
    raise exception 'INVALID_SHIFT_PERIOD_PREFERENCES';
  end if;
  update public.employee_preferences preference set status='CANCELLED'
  where preference.employee_id=p_employee_id and preference.status='ACTIVE'
    and preference.source='GRAFIK_PRO' and preference.preference_type='PREFERRED_SHIFT'
    and preference.valid_from<v_month+interval '1 month' and preference.valid_to>=v_month;
  foreach v_period in array array['MORNING','MIDDLE','EVENING'] loop
    v_level:=upper(coalesce(p_preferences->>v_period,'NEUTRAL'));
    if v_level not in ('PREFERRED','NEUTRAL','AVOIDED') then
      raise exception 'INVALID_EMPLOYEE_SHIFT_PREFERENCE_LEVEL';
    end if;
    insert into public.employee_preferences(employee_id,valid_from,valid_to,preference_type,
      preference_value,source,editable_by_employee,status)
    values(p_employee_id,v_month,(v_month+interval '1 month - 1 day')::date,
      'PREFERRED_SHIFT',jsonb_build_object('period',v_period,'level',v_level),
      'GRAFIK_PRO',true,'ACTIVE');
  end loop;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'employee_shift_preferences_v2',p_employee_id::text,'UAT_MASTER_UPSERT',
    jsonb_build_object('month',v_month,'preferences',p_preferences,'actingAsEmployeeId',p_employee_id));
  return jsonb_build_object('saved',3,'month',v_month,'employeeId',p_employee_id);
end;
$$;


ALTER FUNCTION "public"."uat_master_employee_shift_preferences_save_v2"("p_employee_id" "uuid", "p_month" "date", "p_preferences" "jsonb") OWNER TO "postgres";

--
-- Name: uat_master_persona_preview_v2(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."uat_master_persona_preview_v2"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_enabled boolean:=false; v_matrix uuid; v_version integer;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.has_app_role('OWNER') then raise exception 'FORBIDDEN'; end if;
  select control.enabled into v_enabled from public.uat_environment_controls control
    where control.control_key='ISOLATED_UAT_MASTER_PERSONA';
  select matrix.id,matrix.version into v_matrix,v_version
  from public.matrix_versions matrix where matrix.status='ACTIVE'
    and matrix.schema_version>=2 order by matrix.effective_from desc,matrix.version desc limit 1;
  return jsonb_build_object(
    'enabled',coalesce(v_enabled,false),'matrixVersionId',v_matrix,'matrixVersion',v_version,
    'personas',jsonb_build_array('EMPLOYEE','ROLE_MANAGER','HR','FINANCE','OWNER'),
    'employees',coalesce((select jsonb_agg(jsonb_build_object(
      'id',profile.employee_id,'employeeNo',profile.employee_no,
      'name',profile.first_name||' '||profile.last_name,
      'roleId',role.id,'roleName',role.name,'roleCode',role.code
    ) order by profile.last_name,profile.first_name,profile.employee_no)
      from public.matrix_employee_profiles_v2 profile
      left join public.matrix_employee_roles_v2 grant_row
        on grant_row.matrix_version_id=v_matrix and grant_row.employee_id=profile.employee_id
        and grant_row.active and grant_row.is_primary
      left join public.matrix_roles_v2 role on role.id=grant_row.role_id
      where profile.matrix_version_id=v_matrix and profile.active
        and profile.archived_at is null),'[]'::jsonb)
  );
end;
$$;


ALTER FUNCTION "public"."uat_master_persona_preview_v2"() OWNER TO "postgres";

--
-- Name: uat_master_persona_select_v2("text", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION "public"."uat_master_persona_select_v2"("p_persona" "text", "p_employee_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_persona text:=upper(trim(coalesce(p_persona,''))); v_employee_name text;
begin
  perform solver_private.assert_uat_master_persona_v2();
  if v_persona not in ('EMPLOYEE','ROLE_MANAGER','HR','FINANCE','OWNER') then
    raise exception 'INVALID_UAT_PERSONA';
  end if;
  if v_persona in ('EMPLOYEE','ROLE_MANAGER') then
    select employee.first_name||' '||employee.last_name into v_employee_name
    from public.employees employee where employee.id=p_employee_id and employee.active
      and employee.archived_at is null;
    if v_employee_name is null then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  end if;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'uat_master_persona',coalesce(p_employee_id::text,v_persona),'SELECT',
    jsonb_build_object('persona',v_persona,'employeeId',p_employee_id,
      'employeeName',v_employee_name,'securityMode','OWNER_AUDITED_UAT_SIMULATION'));
  return jsonb_build_object('persona',v_persona,'employeeId',p_employee_id,
    'employeeName',v_employee_name);
end;
$$;


ALTER FUNCTION "public"."uat_master_persona_select_v2"("p_persona" "text", "p_employee_id" "uuid") OWNER TO "postgres";

