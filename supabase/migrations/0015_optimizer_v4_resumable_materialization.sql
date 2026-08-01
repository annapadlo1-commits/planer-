-- Alpha 15 hotfix: resumable, set-based materialization under the authenticated
-- role's 8 second statement timeout. Each variant is independently validated
-- and materialized; partial GENERATING plans stay hidden and are deleted on error.

create or replace function public.optimizer_materialize_candidate_v4(
  p_run_id uuid,
  p_name text,
  p_candidate jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
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


create or replace function public.optimizer_materialize_next_v4(p_run_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
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

create or replace function public.optimizer_complete_finalize_v4(p_run_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
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

create or replace function public.optimizer_abort_finalize_v4(p_run_id uuid,p_error text)
returns jsonb language plpgsql security definer set search_path=public as $$
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

-- Preserve the full exported candidates, including unfilled slots, for the
-- three resumable materialization calls.
create or replace function public.optimizer_begin_finalize_v4(
  p_run_id uuid,p_name text,p_candidates jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
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

revoke all on function public.optimizer_materialize_candidate_v4(uuid,text,jsonb) from public,anon,authenticated;
revoke all on function public.optimizer_begin_finalize_v4(uuid,text,jsonb) from public,anon;
revoke all on function public.optimizer_materialize_next_v4(uuid) from public,anon;
revoke all on function public.optimizer_complete_finalize_v4(uuid) from public,anon;
revoke all on function public.optimizer_abort_finalize_v4(uuid,text) from public,anon;
grant execute on function public.optimizer_begin_finalize_v4(uuid,text,jsonb) to authenticated;
grant execute on function public.optimizer_materialize_next_v4(uuid) to authenticated;
grant execute on function public.optimizer_complete_finalize_v4(uuid) to authenticated;
grant execute on function public.optimizer_abort_finalize_v4(uuid,text) to authenticated;
