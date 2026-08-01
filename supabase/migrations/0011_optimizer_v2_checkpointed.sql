-- GRAFIK PRO 3.0 Alpha 14
-- Checkpointed optimizer: full input snapshot, resumable generations and
-- lexicographic ranking (hard violations -> shortages -> soft objective).

alter table public.optimization_runs
  add column if not exists input_payload jsonb not null default '{}'::jsonb,
  add column if not exists checkpoint jsonb not null default '{}'::jsonb,
  add column if not exists current_generation integer not null default 0,
  add column if not exists target_generations integer not null default 40,
  add column if not exists heartbeat_at timestamptz;

create or replace function public.optimizer_prepare_v2(
  p_month date,
  p_profile_code text default 'BALANCED',
  p_scenario_code text default 'BASE',
  p_seed integer default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_payload jsonb; v_run uuid; v_baseline jsonb;
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  v_payload := public.optimizer_prepare(p_month,p_profile_code,p_scenario_code,p_seed);
  v_run := (v_payload->>'runId')::uuid;

  -- Hard absences are not preferences. They are injected into the dynamic
  -- availability matrix with their exact semantic status.
  v_payload := v_payload || jsonb_build_object(
    'hardBlocks',coalesce((select jsonb_agg(jsonb_build_object(
      'employeeId',ep.employee_id,'from',ep.valid_from,'to',ep.valid_to,
      'status',case ep.preference_type when 'LEAVE' then 'LEAVE' when 'SICKNESS' then 'SICKNESS' else 'UNAVAILABLE' end
    )) from public.employee_preferences ep
      where ep.status='ACTIVE' and ep.preference_type in ('UNAVAILABLE','LEAVE','SICKNESS')
        and ep.valid_from < date_trunc('month',p_month)::date + interval '1 month'
        and ep.valid_to >= date_trunc('month',p_month)::date),'[]'::jsonb),
    'budget',coalesce((select jsonb_build_object('amount',b.amount,'hardLimit',b.hard_limit)
      from public.monthly_budgets b where b.month=date_trunc('month',p_month)::date),
      '{"amount":0,"hardLimit":false}'::jsonb)
  );

  -- Best historical plan is a protected seed. It is revalidated by the engine;
  -- invalid assignments are repaired rather than trusted.
  select coalesce(jsonb_agg(jsonb_build_object(
    'employeeId',a.employee_id,'date',s.shift_date,'shiftCode',s.shift_code,
    'locationId',s.location_id,'role',a.assigned_role,'function',a.assigned_capability,
    'startsAt',s.starts_at,'endsAt',s.ends_at
  ) order by s.starts_at,a.id),'[]'::jsonb) into v_baseline
  from public.plans p
  join public.shifts s on s.plan_id=p.id
  join public.assignments a on a.shift_id=s.id
  where p.id=(select p2.id from public.plans p2
    where p2.month=date_trunc('month',p_month)::date and p2.status in ('READY','PUBLISHED','STALE')
    order by (select count(*) from public.plan_issues pi where pi.plan_id=p2.id and pi.resolved_at is null
      and pi.issue_type in ('SHORTAGE','CAPABILITY_MISSING')) asc,
      p2.score asc nulls last,p2.version desc limit 1);
  v_payload := v_payload || jsonb_build_object('baselineAssignments',coalesce(v_baseline,'[]'::jsonb));

  update public.optimization_runs set input_payload=v_payload,
    target_generations=greatest(8,least(100,coalesce((v_payload#>>'{profile,generations}')::integer,40))),
    heartbeat_at=now(), result_summary=jsonb_build_object('phase','STARTING','progress',0)
  where id=v_run and requested_by=auth.uid();
  return v_payload;
end $$;

create or replace function public.optimizer_checkpoint_v2(
  p_run_id uuid,p_expected_generation integer,p_checkpoint jsonb,p_metrics jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
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

create or replace function public.optimizer_run_state_v2(p_run_id uuid)
returns jsonb language sql stable security definer set search_path=public as $$
  select case when r.id is null then null else jsonb_build_object(
    'runId',r.id,'status',r.status,'generation',r.current_generation,
    'targetGenerations',r.target_generations,'input',r.input_payload,
    'checkpoint',r.checkpoint,'summary',r.result_summary
  ) end from public.optimization_runs r
  where r.id=p_run_id and r.requested_by=auth.uid() and public.can_manage_plans();
$$;

create or replace function public.optimizer_finalize_v2(p_run_id uuid,p_name text,p_candidates jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
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

revoke all on function public.optimizer_prepare_v2(date,text,text,integer) from public,anon;
revoke all on function public.optimizer_checkpoint_v2(uuid,integer,jsonb,jsonb) from public,anon;
revoke all on function public.optimizer_run_state_v2(uuid) from public,anon;
revoke all on function public.optimizer_finalize_v2(uuid,text,jsonb) from public,anon;
grant execute on function public.optimizer_prepare_v2(date,text,text,integer) to authenticated;
grant execute on function public.optimizer_checkpoint_v2(uuid,integer,jsonb,jsonb) to authenticated;
grant execute on function public.optimizer_run_state_v2(uuid) to authenticated;
grant execute on function public.optimizer_finalize_v2(uuid,text,jsonb) to authenticated;
