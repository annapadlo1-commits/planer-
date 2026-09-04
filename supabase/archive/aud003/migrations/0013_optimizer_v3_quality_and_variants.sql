-- GRAFIK PRO 3.0 Alpha 15
-- Quality gate for the checkpointed hybrid optimizer.
-- Every alternative is independently materialized and validated.

alter table public.optimization_candidates
  add column if not exists plan_id uuid references public.plans(id) on delete set null;

create index if not exists optimization_candidates_plan_id_idx
  on public.optimization_candidates(plan_id);

update public.optimizer_profiles
set population_size = greatest(population_size, 12),
    generations = greatest(generations, 32)
where active;

-- INIT requests do not advance the genetic generation counter. This separate
-- compare-and-swap guard prevents two concurrent INIT requests from silently
-- overwriting the same population checkpoint.
create or replace function public.optimizer_save_init_v4(
  p_run_id uuid,
  p_expected_cursor integer,
  p_checkpoint jsonb,
  p_metrics jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
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

create or replace function public.optimizer_prepare_v2(
  p_month date,
  p_profile_code text default 'BALANCED',
  p_scenario_code text default 'BASE',
  p_seed integer default null
) returns jsonb language plpgsql security definer set search_path=public as $$
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

create or replace function public.optimizer_materialize_candidate_v3(
  p_run_id uuid,
  p_name text,
  p_candidate jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
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

create or replace function public.optimizer_finalize_v3(
  p_run_id uuid,
  p_name text,
  p_candidates jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
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

create or replace function public.optimizer_variants_v3(p_month date)
returns jsonb language sql stable security definer set search_path=public as $$
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

revoke all on function public.optimizer_materialize_candidate_v3(uuid,text,jsonb) from public,anon,authenticated;
revoke all on function public.optimizer_finalize_v3(uuid,text,jsonb) from public,anon;
revoke all on function public.optimizer_variants_v3(date) from public,anon;
revoke all on function public.optimizer_save_init_v4(uuid,integer,jsonb,jsonb) from public,anon;
grant execute on function public.optimizer_finalize_v3(uuid,text,jsonb) to authenticated;
grant execute on function public.optimizer_variants_v3(date) to authenticated;
grant execute on function public.optimizer_save_init_v4(uuid,integer,jsonb,jsonb) to authenticated;
