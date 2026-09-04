-- GRAFIK PRO 3.0 -- one-shot Cloud Run dispatch, version-bound claims and
-- provider-observed recovery. This supersedes the neutralized pull-worker
-- experiment without changing the durable PGMQ source of truth.

-- Remove only the obsolete named recovery schedule. Never remove pg_cron.
do $$
declare
  v_job_id bigint;
begin
  if to_regclass('cron.job') is not null then
    for v_job_id in execute
      'select jobid from cron.job where jobname=$1'
      using 'grafik-pro-solver-v2-recovery'
    loop
      execute 'select cron.unschedule($1)' using v_job_id;
    end loop;
  end if;
end;
$$;

drop function if exists public.solver_claim_next_v2(text,integer,integer);
drop function if exists solver_private.recover_expired_solver_runs_v2(integer);
drop trigger if exists optimization_runs_v2_cleanup_retry_variants
  on public.optimization_runs_v2;
drop function if exists solver_private.cleanup_retry_variants_v2();

drop function if exists public.solver_claim_v2(uuid,uuid,text,integer,integer);

create or replace function public.solver_claim_v2(
  p_run_id uuid,
  p_dispatch_token uuid,
  p_worker_id text,
  p_worker_version text,
  p_task_attempt integer,
  p_lease_seconds integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run public.optimization_runs_v2%rowtype;
  v_dispatch solver_private.optimization_dispatch_v2%rowtype;
  v_attempt_id uuid:=gen_random_uuid();
  v_lease_token uuid:=gen_random_uuid();
  v_attempt_number integer;
  v_lease_expires_at timestamptz;
  v_message_id bigint;
begin
  if length(trim(coalesce(p_worker_id,''))) not between 3 and 200
    or trim(p_worker_id) !~ '^[A-Za-z0-9._:@/-]+$'
  then raise exception 'INVALID_WORKER_ID'; end if;
  if length(coalesce(p_worker_version,'')) not between 1 and 200
    or p_worker_version ~ '[[:space:][:cntrl:]]'
  then raise exception 'INVALID_WORKER_VERSION'; end if;
  if coalesce(p_task_attempt,0) not between 1 and 20 then
    raise exception 'INVALID_TASK_ATTEMPT';
  end if;
  if coalesce(p_lease_seconds,0) not between 30 and 900 then
    raise exception 'INVALID_LEASE_SECONDS';
  end if;

  perform solver_private.lock_planning_revision_v2();
  select * into v_run
  from public.optimization_runs_v2
  where id=p_run_id
  for update;
  if v_run.id is null then raise exception 'RUN_NOT_FOUND'; end if;
  select * into v_dispatch
  from solver_private.optimization_dispatch_v2
  where run_id=p_run_id
  for update;

  -- The image/version fence is deliberately checked before the single-use
  -- launch token can be consumed.
  if v_run.solver_version is distinct from p_worker_version then
    raise exception 'SOLVER_VERSION_MISMATCH';
  end if;
  if p_dispatch_token is null
    or v_dispatch.worker_launch_token is distinct from p_dispatch_token
  then raise exception 'DISPATCH_TOKEN_MISMATCH'; end if;

  v_message_id:=coalesce(v_dispatch.dispatch_message_id,v_run.queue_message_id);
  if v_run.status='CANCEL_REQUESTED' then
    if v_message_id is not null then
      perform pgmq.archive('schedule_optimizer_v2',v_message_id);
    end if;
    delete from public.plan_variants_v2 where run_id=p_run_id;
    update public.optimization_run_strategies_v2
    set status='CANCELLED',phase='CANCELLED',progress=0,
      metrics='{}'::jsonb,finished_at=now(),updated_at=now()
    where run_id=p_run_id;
    update solver_private.optimization_dispatch_v2
    set dispatch_owner=null,dispatch_token=null,dispatch_message_id=null,
      dispatch_reserved_at=null,dispatch_expires_at=null,
      worker_launch_token=null,dispatched_at=null
    where run_id=p_run_id;
    update public.optimization_runs_v2
    set status='CANCELLED',phase='CANCELLED',progress=0,
      queue_message_id=null,lease_owner=null,lease_token=null,
      lease_expires_at=null,worker_execution_name=null,
      finished_at=now(),updated_at=now()
    where id=p_run_id;
    return jsonb_build_object('claimed',false,'status','CANCELLED');
  end if;
  if v_run.status not in ('QUEUED','RUNNING') then
    update solver_private.optimization_dispatch_v2
    set worker_launch_token=null where run_id=p_run_id;
    return jsonb_build_object('claimed',false,'status',v_run.status);
  end if;
  if v_run.lease_expires_at is not null and v_run.lease_expires_at>now() then
    return jsonb_build_object(
      'claimed',false,'status',v_run.status,'leaseBusy',true
    );
  end if;
  if v_run.attempt_count>=v_run.max_attempts then
    if v_message_id is not null then
      perform pgmq.archive('schedule_optimizer_v2',v_message_id);
    end if;
    delete from public.plan_variants_v2 where run_id=p_run_id;
    update public.optimization_run_strategies_v2
    set status='FAILED',phase='FAILED',progress=0,metrics='{}'::jsonb,
      failure_code='MAX_ATTEMPTS',finished_at=now(),updated_at=now()
    where run_id=p_run_id;
    update solver_private.optimization_dispatch_v2
    set dispatch_owner=null,dispatch_token=null,dispatch_message_id=null,
      dispatch_reserved_at=null,dispatch_expires_at=null,
      worker_launch_token=null,dispatched_at=null
    where run_id=p_run_id;
    update public.optimization_runs_v2
    set status='FAILED',phase='FAILED',queue_message_id=null,
      failure_code='MAX_ATTEMPTS',
      failure_message='Przekroczono limit prób solvera.',
      lease_owner=null,lease_token=null,lease_expires_at=null,
      worker_execution_name=null,finished_at=now(),updated_at=now()
    where id=p_run_id;
    return jsonb_build_object('claimed',false,'status','FAILED');
  end if;

  update solver_private.optimization_attempts_v2
  set status='LEASE_LOST',finished_at=now(),heartbeat_at=now(),
    error_code='LEASE_EXPIRED',
    error_message='Poprzednia próba utraciła dzierżawę.'
  where run_id=p_run_id and status='RUNNING';
  delete from public.plan_variants_v2 where run_id=p_run_id;

  v_attempt_number:=v_run.attempt_count+1;
  v_lease_expires_at:=now()+make_interval(secs=>p_lease_seconds);
  insert into solver_private.optimization_attempts_v2(
    id,run_id,attempt_number,task_attempt,worker_id,
    worker_execution_name,lease_token,status
  ) values(
    v_attempt_id,p_run_id,v_attempt_number,p_task_attempt,trim(p_worker_id),
    v_run.worker_execution_name,v_lease_token,'RUNNING'
  );
  update solver_private.optimization_dispatch_v2
  set worker_launch_token=null
  where run_id=p_run_id;
  update public.optimization_runs_v2
  set status='RUNNING',phase='CLAIMED',progress=greatest(progress,1),
    attempt_count=v_attempt_number,queue_message_id=null,
    lease_owner=trim(p_worker_id),lease_token=v_lease_token,
    lease_expires_at=v_lease_expires_at,heartbeat_at=now(),
    started_at=coalesce(started_at,now()),finished_at=null,
    failure_code=null,failure_message=null,updated_at=now()
  where id=p_run_id;
  update public.optimization_run_strategies_v2
  set status='RUNNING',phase='CLAIMED',progress=1,metrics='{}'::jsonb,
    started_at=coalesce(started_at,now()),finished_at=null,
    failure_code=null,updated_at=now()
  where run_id=p_run_id;
  if v_message_id is not null then
    perform pgmq.archive('schedule_optimizer_v2',v_message_id);
  end if;

  return jsonb_build_object(
    'claimed',true,'runId',p_run_id,'attemptId',v_attempt_id,
    'attemptNumber',v_attempt_number,'leaseToken',v_lease_token,
    'leaseExpiresAt',v_lease_expires_at,'snapshotHash',v_run.snapshot_hash,
    'solverVersion',v_run.solver_version
  );
end;
$$;

create or replace function public.solver_dispatch_next_v2(
  p_dispatcher_id text,
  p_lease_seconds integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_message_id bigint;
  v_message jsonb;
  v_run_id uuid;
  v_run public.optimization_runs_v2%rowtype;
  v_dispatch solver_private.optimization_dispatch_v2%rowtype;
  v_token uuid;
  v_scan_count integer:=0;
begin
  if length(trim(coalesce(p_dispatcher_id,''))) not between 3 and 200
    or trim(p_dispatcher_id) !~ '^[A-Za-z0-9._:@/-]+$'
  then raise exception 'INVALID_DISPATCHER_ID'; end if;
  if coalesce(p_lease_seconds,0) not between 15 and 300 then
    raise exception 'INVALID_DISPATCH_LEASE_SECONDS';
  end if;

  -- A worker may claim between Run API success and dispatcher acknowledgement.
  select r.id into v_run_id
  from public.optimization_runs_v2 r
  join solver_private.optimization_dispatch_v2 d on d.run_id=r.id
  where r.status='RUNNING' and r.phase='CLAIMED'
    and r.worker_execution_name is null
    and d.dispatch_token is not null and d.worker_launch_token is null
    and d.dispatched_at is null
  order by d.dispatch_reserved_at,r.id
  limit 1;
  if v_run_id is not null then
    perform solver_private.lock_planning_revision_v2();
    select * into v_run from public.optimization_runs_v2
    where id=v_run_id for update;
    select * into v_dispatch from solver_private.optimization_dispatch_v2
    where run_id=v_run_id for update;
    if v_run.status='RUNNING' and v_run.phase='CLAIMED'
      and v_run.worker_execution_name is null
      and v_dispatch.dispatch_token is not null
      and v_dispatch.worker_launch_token is null
      and v_dispatch.dispatched_at is null
    then
      return jsonb_build_object(
        'found',false,'dispatchInFlight',true,
        'claimedUnacknowledged',true,'runId',v_run_id
      );
    end if;
  end if;

  loop
    v_scan_count:=v_scan_count+1;
    v_message_id:=null;
    v_message:=null;
    select q.msg_id,q.message into v_message_id,v_message
    from pgmq.read('schedule_optimizer_v2',p_lease_seconds,1) q
    limit 1;
    if v_message_id is null then return jsonb_build_object('found',false); end if;
    if coalesce(v_message->>'runId','') !~*
      '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    then
      perform pgmq.archive('schedule_optimizer_v2',v_message_id);
      if v_scan_count<20 then continue; end if;
      return jsonb_build_object('found',false,'staleMessages',v_scan_count);
    end if;

    v_run_id:=(v_message->>'runId')::uuid;
    perform solver_private.lock_planning_revision_v2();
    select * into v_run from public.optimization_runs_v2
    where id=v_run_id for update;
    if v_run.id is null or v_run.status<>'QUEUED'
      or v_run.queue_message_id is distinct from v_message_id
    then
      perform pgmq.archive('schedule_optimizer_v2',v_message_id);
      if v_scan_count<20 then continue; end if;
      return jsonb_build_object('found',false,'staleMessages',v_scan_count);
    end if;
    select * into v_dispatch from solver_private.optimization_dispatch_v2
    where run_id=v_run_id for update;
    if v_dispatch.dispatch_token is not null
      or v_dispatch.worker_launch_token is not null
    then
      perform pgmq.set_vt('schedule_optimizer_v2',v_message_id,p_lease_seconds);
      return jsonb_build_object(
        'found',false,'dispatchInFlight',true,
        'claimedUnacknowledged',false,'runId',v_run_id
      );
    end if;
    if coalesce(v_dispatch.dispatch_attempt_count,0)>=20 then
      perform pgmq.archive('schedule_optimizer_v2',v_message_id);
      delete from public.plan_variants_v2 where run_id=v_run_id;
      update public.optimization_run_strategies_v2
      set status='FAILED',phase='FAILED',progress=0,metrics='{}'::jsonb,
        failure_code='DISPATCH_ATTEMPTS_EXHAUSTED',
        finished_at=now(),updated_at=now()
      where run_id=v_run_id;
      update solver_private.optimization_dispatch_v2
      set dispatch_owner=null,dispatch_token=null,dispatch_message_id=null,
        dispatch_reserved_at=null,dispatch_expires_at=null,
        worker_launch_token=null,dispatched_at=null
      where run_id=v_run_id;
      update public.optimization_runs_v2
      set status='FAILED',phase='FAILED',progress=0,queue_message_id=null,
        failure_code='DISPATCH_ATTEMPTS_EXHAUSTED',
        failure_message='Przekroczono limit prób uruchomienia workera.',
        finished_at=now(),updated_at=now()
      where id=v_run_id;
      return jsonb_build_object(
        'found',false,'terminal',true,'runId',v_run_id,
        'reason','DISPATCH_ATTEMPTS_EXHAUSTED'
      );
    end if;

    v_token:=gen_random_uuid();
    insert into solver_private.optimization_dispatch_v2 as d(
      run_id,dispatch_owner,dispatch_token,dispatch_message_id,
      dispatch_reserved_at,dispatch_expires_at,worker_launch_token,
      dispatched_at,dispatch_attempt_count
    ) values(
      v_run_id,trim(p_dispatcher_id),v_token,v_message_id,now(),
      now()+make_interval(secs=>p_lease_seconds),v_token,null,1
    ) on conflict(run_id) do update set
      dispatch_owner=excluded.dispatch_owner,
      dispatch_token=excluded.dispatch_token,
      dispatch_message_id=excluded.dispatch_message_id,
      dispatch_reserved_at=excluded.dispatch_reserved_at,
      dispatch_expires_at=excluded.dispatch_expires_at,
      worker_launch_token=excluded.worker_launch_token,
      dispatched_at=null,
      dispatch_attempt_count=d.dispatch_attempt_count+1
    returning * into v_dispatch;
    update public.optimization_runs_v2
    set phase='DISPATCHING',updated_at=now()
    where id=v_run_id;
    return jsonb_build_object(
      'found',true,'runId',v_run_id,'dispatchToken',v_token,
      'queueMessageId',v_message_id,
      'dispatchAttempt',v_dispatch.dispatch_attempt_count,
      'solverVersion',v_run.solver_version
    );
  end loop;
end;
$$;

create or replace function public.solver_mark_dispatched_v2(
  p_run_id uuid,
  p_dispatch_token uuid,
  p_execution_name text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run public.optimization_runs_v2%rowtype;
  v_dispatch solver_private.optimization_dispatch_v2%rowtype;
  v_message_id bigint;
begin
  if coalesce(p_execution_name,'') !~
    '^projects/[^/]+/locations/[^/]+/jobs/[^/]+/executions/[^/]+$'
  then raise exception 'INVALID_EXECUTION_NAME'; end if;
  perform solver_private.lock_planning_revision_v2();
  select * into v_run from public.optimization_runs_v2
  where id=p_run_id for update;
  if v_run.id is null then raise exception 'RUN_NOT_FOUND'; end if;
  select * into v_dispatch from solver_private.optimization_dispatch_v2
  where run_id=p_run_id for update;

  if v_run.worker_execution_name=p_execution_name
    and v_dispatch.dispatch_token is null
  then
    return jsonb_build_object(
      'marked',true,'reused',true,'runId',p_run_id,
      'executionName',p_execution_name
    );
  end if;
  if v_dispatch.dispatch_token is distinct from p_dispatch_token then
    raise exception 'DISPATCH_TOKEN_MISMATCH';
  end if;
  if v_run.worker_execution_name is not null
    and v_run.worker_execution_name<>p_execution_name
  then raise exception 'RUN_ALREADY_DISPATCHED'; end if;

  v_message_id:=v_dispatch.dispatch_message_id;
  update public.optimization_runs_v2
  set worker_execution_name=p_execution_name,
    phase=case when status='QUEUED' then 'DISPATCHED' else phase end,
    updated_at=now()
  where id=p_run_id;
  update solver_private.optimization_dispatch_v2
  set dispatched_at=coalesce(dispatched_at,now()),
    dispatch_owner=null,dispatch_token=null,dispatch_message_id=null,
    dispatch_reserved_at=null,dispatch_expires_at=null
  where run_id=p_run_id;
  update solver_private.optimization_attempts_v2
  set worker_execution_name=p_execution_name,heartbeat_at=now()
  where run_id=p_run_id and status='RUNNING'
    and attempt_number=v_run.attempt_count;
  if v_message_id is not null then
    perform pgmq.archive('schedule_optimizer_v2',v_message_id);
  end if;
  return jsonb_build_object(
    'marked',true,'reused',false,'runId',p_run_id,
    'executionName',p_execution_name
  );
end;
$$;

create or replace function public.solver_release_dispatch_v2(
  p_run_id uuid,
  p_dispatch_token uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run public.optimization_runs_v2%rowtype;
  v_dispatch solver_private.optimization_dispatch_v2%rowtype;
  v_message_id bigint;
begin
  perform solver_private.lock_planning_revision_v2();
  select * into v_run from public.optimization_runs_v2
  where id=p_run_id for update;
  if v_run.id is null then raise exception 'RUN_NOT_FOUND'; end if;
  select * into v_dispatch from solver_private.optimization_dispatch_v2
  where run_id=p_run_id for update;
  if v_dispatch.dispatch_token is null
    and v_run.status='QUEUED' and v_run.worker_execution_name is null
  then return jsonb_build_object('released',true,'reused',true,'runId',p_run_id);
  end if;
  if v_dispatch.dispatch_token is distinct from p_dispatch_token then
    raise exception 'DISPATCH_TOKEN_MISMATCH';
  end if;
  if v_run.worker_execution_name is not null then
    raise exception 'DISPATCH_ALREADY_ACKNOWLEDGED';
  end if;
  if v_run.status<>'QUEUED' then raise exception 'RUN_NOT_QUEUED'; end if;

  v_message_id:=v_dispatch.dispatch_message_id;
  update solver_private.optimization_dispatch_v2
  set dispatch_owner=null,dispatch_token=null,dispatch_message_id=null,
    dispatch_reserved_at=null,dispatch_expires_at=null,
    worker_launch_token=null,dispatched_at=null
  where run_id=p_run_id;
  update public.optimization_runs_v2
  set phase='RETRY_QUEUED',
    failure_code=case when p_reason is null then failure_code
      else 'DISPATCH_REJECTED' end,
    failure_message=case when p_reason is null then failure_message
      else left('Nie udało się uruchomić workera: '||p_reason,1000) end,
    updated_at=now()
  where id=p_run_id;
  if v_message_id is not null then
    perform pgmq.set_vt('schedule_optimizer_v2',v_message_id,0);
  end if;
  return jsonb_build_object('released',true,'reused',false,'runId',p_run_id);
end;
$$;

create or replace function public.solver_reconcile_stale_v2(
  p_dispatcher_id text,
  p_mode text,
  p_limit integer,
  p_launch_grace_seconds integer,
  p_run_id uuid,
  p_kind text,
  p_dispatch_token uuid,
  p_dispatch_attempt integer,
  p_attempt_number integer,
  p_execution_name text,
  p_observed_state text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_candidates jsonb:='[]'::jsonb;
  v_candidate record;
  v_run public.optimization_runs_v2%rowtype;
  v_dispatch solver_private.optimization_dispatch_v2%rowtype;
  v_attempt solver_private.optimization_attempts_v2%rowtype;
  v_old_message_id bigint;
  v_new_message_id bigint;
  v_retry boolean;
  v_valid boolean:=false;
  v_outcome text;
begin
  if length(trim(coalesce(p_dispatcher_id,''))) not between 3 and 200
    or trim(p_dispatcher_id) !~ '^[A-Za-z0-9._:@/-]+$'
  then raise exception 'INVALID_DISPATCHER_ID'; end if;
  if coalesce(p_launch_grace_seconds,0) not between 30 and 3600 then
    raise exception 'INVALID_LAUNCH_GRACE_SECONDS';
  end if;

  if upper(coalesce(p_mode,''))='SCAN' then
    if coalesce(p_limit,0) not between 1 and 100 then
      raise exception 'INVALID_RECOVERY_LIMIT';
    end if;
    for v_candidate in
      select candidate.*
      from (
        select r.id as run_id,'RESERVATION_EXPIRED'::text as kind,
          d.dispatch_attempt_count as dispatch_attempt,
          d.dispatch_token,d.dispatch_expires_at as stale_at,
          null::integer as attempt_number,null::text as execution_name,
          r.solver_version
        from public.optimization_runs_v2 r
        join solver_private.optimization_dispatch_v2 d on d.run_id=r.id
        where r.status='QUEUED' and r.phase='DISPATCHING'
          and r.worker_execution_name is null
          and d.dispatch_token is not null
          and d.worker_launch_token is not null
          and d.dispatched_at is null
          and d.dispatch_expires_at is not null
          and d.dispatch_expires_at<=now()
          and d.dispatch_attempt_count between 1 and 20
        union all
        select r.id,'CLAIMED_UNACKNOWLEDGED',d.dispatch_attempt_count,
          d.dispatch_token,r.lease_expires_at,a.attempt_number,null::text,
          r.solver_version
        from public.optimization_runs_v2 r
        join solver_private.optimization_dispatch_v2 d on d.run_id=r.id
        join solver_private.optimization_attempts_v2 a
          on a.run_id=r.id and a.attempt_number=r.attempt_count
          and a.status='RUNNING'
        where r.status='RUNNING' and r.phase='CLAIMED'
          and r.worker_execution_name is null
          and r.lease_expires_at is not null and r.lease_expires_at<=now()
          and d.dispatch_token is not null
          and d.worker_launch_token is null and d.dispatched_at is null
          and d.dispatch_attempt_count between 1 and 20
        union all
        select r.id,'LAUNCH_EXPIRED',d.dispatch_attempt_count,
          null::uuid,d.dispatched_at,null::integer,r.worker_execution_name,
          r.solver_version
        from public.optimization_runs_v2 r
        join solver_private.optimization_dispatch_v2 d on d.run_id=r.id
        where r.status='QUEUED' and r.phase='DISPATCHED'
          and r.worker_execution_name is not null
          and d.dispatch_token is null and d.dispatched_at is not null
          and d.dispatched_at<=now()-make_interval(secs=>p_launch_grace_seconds)
          and d.dispatch_attempt_count between 1 and 20
        union all
        select r.id,'LEASE_EXPIRED',d.dispatch_attempt_count,
          null::uuid,r.lease_expires_at,a.attempt_number,
          r.worker_execution_name,r.solver_version
        from public.optimization_runs_v2 r
        join solver_private.optimization_dispatch_v2 d on d.run_id=r.id
        join solver_private.optimization_attempts_v2 a
          on a.run_id=r.id and a.attempt_number=r.attempt_count
          and a.status='RUNNING'
        where r.status in ('RUNNING','VALIDATING','CANCEL_REQUESTED')
          and r.worker_execution_name is not null
          and r.lease_expires_at is not null and r.lease_expires_at<=now()
          and d.dispatch_token is null and d.dispatched_at is not null
          and d.dispatch_attempt_count between 1 and 20
      ) candidate
      order by candidate.stale_at,candidate.run_id,candidate.kind
      limit p_limit
    loop
      v_candidates:=v_candidates||jsonb_build_array(jsonb_build_object(
        'runId',v_candidate.run_id,'kind',v_candidate.kind,
        'dispatchAttempt',v_candidate.dispatch_attempt,
        'dispatchToken',v_candidate.dispatch_token,
        'attemptNumber',v_candidate.attempt_number,
        'executionName',v_candidate.execution_name,
        'solverVersion',v_candidate.solver_version
      ));
    end loop;
    return jsonb_build_object('candidates',v_candidates,'checkedAt',now());
  end if;

  if upper(coalesce(p_mode,''))<>'APPLY' then
    raise exception 'INVALID_RECOVERY_MODE';
  end if;
  if p_kind not in (
    'RESERVATION_EXPIRED','CLAIMED_UNACKNOWLEDGED',
    'LAUNCH_EXPIRED','LEASE_EXPIRED'
  ) then raise exception 'INVALID_RECOVERY_KIND'; end if;
  if coalesce(p_dispatch_attempt,0) not between 1 and 20 then
    raise exception 'INVALID_DISPATCH_ATTEMPT';
  end if;
  if p_observed_state not in (
    'SUCCEEDED','FAILED','CANCELLED','TERMINAL_UNKNOWN','NOT_FOUND'
  ) then raise exception 'RECOVERY_STATE_NOT_CONCLUSIVE'; end if;
  if p_kind='CLAIMED_UNACKNOWLEDGED'
    and p_observed_state<>'NOT_FOUND'
  then raise exception 'CLAIMED_RECOVERY_REQUIRES_NOT_FOUND'; end if;
  if p_kind in ('LAUNCH_EXPIRED','LEASE_EXPIRED')
    and p_execution_name is null
  then raise exception 'RECOVERY_EXECUTION_REQUIRED'; end if;
  if p_kind in ('RESERVATION_EXPIRED','CLAIMED_UNACKNOWLEDGED')
    and p_observed_state='NOT_FOUND' and p_execution_name is not null
  then raise exception 'RECOVERY_EXECUTION_MUST_BE_NULL'; end if;

  perform solver_private.lock_planning_revision_v2();
  select * into v_run from public.optimization_runs_v2
  where id=p_run_id for update;
  if v_run.id is null then
    return jsonb_build_object('applied',false,'outcome','STALE');
  end if;
  select * into v_dispatch from solver_private.optimization_dispatch_v2
  where run_id=p_run_id for update;
  if v_dispatch.run_id is null
    or v_dispatch.dispatch_attempt_count is distinct from p_dispatch_attempt
  then return jsonb_build_object('applied',false,'outcome','STALE'); end if;
  if p_attempt_number is not null then
    select * into v_attempt
    from solver_private.optimization_attempts_v2
    where run_id=p_run_id and attempt_number=p_attempt_number
    for update;
  end if;

  if p_kind='RESERVATION_EXPIRED' then
    v_valid:=v_run.status='QUEUED' and v_run.phase='DISPATCHING'
      and v_run.worker_execution_name is null
      and v_dispatch.dispatch_token is not distinct from p_dispatch_token
      and v_dispatch.worker_launch_token is not distinct from p_dispatch_token
      and v_dispatch.dispatched_at is null
      and v_dispatch.dispatch_expires_at is not null
      and v_dispatch.dispatch_expires_at<=now()
      and p_attempt_number is null;
  elsif p_kind='CLAIMED_UNACKNOWLEDGED' then
    v_valid:=v_run.status='RUNNING' and v_run.phase='CLAIMED'
      and v_run.worker_execution_name is null
      and v_run.lease_expires_at is not null and v_run.lease_expires_at<=now()
      and v_dispatch.dispatch_token is not distinct from p_dispatch_token
      and v_dispatch.worker_launch_token is null
      and v_dispatch.dispatched_at is null
      and v_attempt.id is not null and v_attempt.status='RUNNING'
      and v_attempt.worker_execution_name is null;
  elsif p_kind='LAUNCH_EXPIRED' then
    v_valid:=v_run.status='QUEUED' and v_run.phase='DISPATCHED'
      and v_run.worker_execution_name is not distinct from p_execution_name
      and p_dispatch_token is null and p_attempt_number is null
      and v_dispatch.dispatch_token is null
      and v_dispatch.dispatched_at is not null
      and v_dispatch.dispatched_at<=now()-make_interval(secs=>p_launch_grace_seconds);
  else
    v_valid:=v_run.status in ('RUNNING','VALIDATING','CANCEL_REQUESTED')
      and v_run.worker_execution_name is not distinct from p_execution_name
      and v_run.lease_expires_at is not null and v_run.lease_expires_at<=now()
      and p_dispatch_token is null and v_dispatch.dispatch_token is null
      and v_dispatch.dispatched_at is not null
      and v_attempt.id is not null and v_attempt.status='RUNNING'
      and v_attempt.worker_execution_name is not distinct from p_execution_name;
  end if;
  if not coalesce(v_valid,false) then
    return jsonb_build_object('applied',false,'outcome','STALE');
  end if;

  v_old_message_id:=coalesce(
    v_dispatch.dispatch_message_id,v_run.queue_message_id
  );
  if v_old_message_id is not null then
    perform pgmq.archive('schedule_optimizer_v2',v_old_message_id);
  end if;
  if p_attempt_number is not null then
    update solver_private.optimization_attempts_v2
    set status='LEASE_LOST',finished_at=now(),heartbeat_at=now(),
      error_code=p_kind,
      error_message='Próba została zakończona przez uzgodniony recovery Cloud Run.'
    where id=v_attempt.id and status='RUNNING';
  end if;

  if v_run.status='CANCEL_REQUESTED' then
    v_outcome:='CANCELLED';
  elsif v_run.attempt_count>=v_run.max_attempts then
    v_outcome:='FAILED';
  else
    v_outcome:='REQUEUED';
  end if;

  delete from public.plan_variants_v2 where run_id=p_run_id;
  if v_outcome='REQUEUED' then
    select pgmq.send('schedule_optimizer_v2',jsonb_build_object(
      'schemaVersion',2,'runId',p_run_id,'retry',true,
      'reason',p_kind,'solverVersion',v_run.solver_version
    )) into v_new_message_id;
    update public.optimization_run_strategies_v2
    set status='QUEUED',phase='RETRY_QUEUED',progress=0,
      metrics='{}'::jsonb,failure_code=null,
      started_at=null,finished_at=null,updated_at=now()
    where run_id=p_run_id;
    update public.optimization_runs_v2
    set status='QUEUED',phase='RETRY_QUEUED',progress=0,
      queue_message_id=v_new_message_id,
      lease_owner=null,lease_token=null,lease_expires_at=null,
      worker_execution_name=null,heartbeat_at=null,started_at=null,
      finished_at=null,failure_code=p_kind,
      failure_message='Próba została bezpiecznie ponownie dodana do kolejki.',
      updated_at=now()
    where id=p_run_id;
  elsif v_outcome='CANCELLED' then
    update public.optimization_run_strategies_v2
    set status='CANCELLED',phase='CANCELLED',progress=0,
      metrics='{}'::jsonb,failure_code=null,
      finished_at=now(),updated_at=now()
    where run_id=p_run_id;
    update public.optimization_runs_v2
    set status='CANCELLED',phase='CANCELLED',progress=0,
      queue_message_id=null,lease_owner=null,lease_token=null,
      lease_expires_at=null,worker_execution_name=null,
      finished_at=now(),updated_at=now()
    where id=p_run_id;
  else
    update public.optimization_run_strategies_v2
    set status='FAILED',phase='FAILED',progress=0,
      metrics='{}'::jsonb,failure_code='MAX_ATTEMPTS',
      finished_at=now(),updated_at=now()
    where run_id=p_run_id;
    update public.optimization_runs_v2
    set status='FAILED',phase='FAILED',progress=0,
      queue_message_id=null,lease_owner=null,lease_token=null,
      lease_expires_at=null,worker_execution_name=null,
      failure_code='MAX_ATTEMPTS',
      failure_message='Solver nie zakończył pracy po maksymalnej liczbie prób.',
      finished_at=now(),updated_at=now()
    where id=p_run_id;
  end if;
  update solver_private.optimization_dispatch_v2
  set dispatch_owner=null,dispatch_token=null,dispatch_message_id=null,
    dispatch_reserved_at=null,dispatch_expires_at=null,
    worker_launch_token=null,dispatched_at=null
  where run_id=p_run_id;

  if v_outcome='REQUEUED' then
    return jsonb_build_object(
      'applied',true,'outcome',v_outcome,
      'queueMessageId',v_new_message_id
    );
  end if;
  return jsonb_build_object('applied',true,'outcome',v_outcome);
end;
$$;

create or replace function solver_private.reset_retry_outputs_v2(p_run_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.plan_variants_v2 where run_id=p_run_id;
  update public.optimization_run_strategies_v2
  set status='QUEUED',phase='RETRY_QUEUED',progress=0,
    metrics='{}'::jsonb,failure_code=null,
    started_at=null,finished_at=null,updated_at=now()
  where run_id=p_run_id;
end;
$$;

create or replace function public.solver_interrupt_v2(
  p_run_id uuid,p_attempt_id uuid,p_lease_token uuid,p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run public.optimization_runs_v2%rowtype;
  v_dispatch solver_private.optimization_dispatch_v2%rowtype;
  v_retry boolean;
  v_message_id bigint;
  v_old_message_id bigint;
begin
  perform solver_private.lock_planning_revision_v2();
  if not solver_private.lease_is_live_v2(
    p_run_id,p_attempt_id,p_lease_token
  ) then raise exception 'LEASE_LOST'; end if;
  select * into v_run from public.optimization_runs_v2
  where id=p_run_id for update;
  select * into v_dispatch from solver_private.optimization_dispatch_v2
  where run_id=p_run_id for update;
  v_old_message_id:=coalesce(
    v_dispatch.dispatch_message_id,v_run.queue_message_id
  );

  update solver_private.optimization_attempts_v2
  set status='INTERRUPTED',error_code='INTERRUPTED',
    error_message=left(coalesce(p_reason,'INTERRUPTED'),1000),
    finished_at=now(),heartbeat_at=now()
  where id=p_attempt_id;

  if v_run.status='CANCEL_REQUESTED'
    or upper(coalesce(p_reason,''))='CANCEL_REQUESTED'
  then
    delete from public.plan_variants_v2 where run_id=p_run_id;
    update public.optimization_run_strategies_v2
    set status='CANCELLED',phase='CANCELLED',progress=0,
      metrics='{}'::jsonb,finished_at=now(),updated_at=now()
    where run_id=p_run_id;
    update public.optimization_runs_v2
    set status='CANCELLED',phase='CANCELLED',progress=0,
      queue_message_id=null,lease_owner=null,lease_token=null,
      lease_expires_at=null,worker_execution_name=null,
      finished_at=now(),updated_at=now()
    where id=p_run_id;
    update solver_private.optimization_dispatch_v2
    set dispatch_owner=null,dispatch_token=null,dispatch_message_id=null,
      dispatch_reserved_at=null,dispatch_expires_at=null,
      worker_launch_token=null,dispatched_at=null
    where run_id=p_run_id;
    return jsonb_build_object('status','CANCELLED','retry',false);
  end if;

  v_retry:=v_run.attempt_count<v_run.max_attempts;
  if v_retry then
    if v_old_message_id is not null then
      perform pgmq.archive('schedule_optimizer_v2',v_old_message_id);
    end if;
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
  else
    delete from public.plan_variants_v2 where run_id=p_run_id;
    update public.optimization_run_strategies_v2
    set status='FAILED',phase='FAILED',progress=0,metrics='{}'::jsonb,
      failure_code='INTERRUPTED',finished_at=now(),updated_at=now()
    where run_id=p_run_id;
    update public.optimization_runs_v2
    set status='FAILED',phase='FAILED',progress=0,queue_message_id=null,
      lease_owner=null,lease_token=null,lease_expires_at=null,
      worker_execution_name=null,failure_code='INTERRUPTED',
      failure_message='Solver został przerwany.',finished_at=now(),
      updated_at=now()
    where id=p_run_id;
  end if;
  update solver_private.optimization_dispatch_v2
  set dispatch_owner=null,dispatch_token=null,dispatch_message_id=null,
    dispatch_reserved_at=null,dispatch_expires_at=null,
    worker_launch_token=null,dispatched_at=null
  where run_id=p_run_id;
  return jsonb_build_object(
    'status',case when v_retry then 'QUEUED' else 'FAILED' end,
    'retry',v_retry
  );
end;
$$;

create or replace function public.solver_fail_attempt_v2(
  p_run_id uuid,p_attempt_id uuid,p_lease_token uuid,p_error_code text,
  p_error_message text,p_retryable boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run public.optimization_runs_v2%rowtype;
  v_dispatch solver_private.optimization_dispatch_v2%rowtype;
  v_retry boolean;
  v_message_id bigint;
  v_old_message_id bigint;
  v_outcome text;
begin
  perform solver_private.lock_planning_revision_v2();
  if not solver_private.lease_is_live_v2(
    p_run_id,p_attempt_id,p_lease_token
  ) then raise exception 'LEASE_LOST'; end if;
  select * into v_run from public.optimization_runs_v2
  where id=p_run_id for update;
  select * into v_dispatch from solver_private.optimization_dispatch_v2
  where run_id=p_run_id for update;
  v_old_message_id:=coalesce(
    v_dispatch.dispatch_message_id,v_run.queue_message_id
  );
  v_retry:=coalesce(p_retryable,false)
    and v_run.attempt_count<v_run.max_attempts
    and v_run.status<>'CANCEL_REQUESTED';

  update solver_private.optimization_attempts_v2
  set status='FAILED',
    error_code=left(coalesce(p_error_code,'WORKER_ERROR'),100),
    error_message=left(coalesce(p_error_message,'Nieznany błąd workera.'),1000),
    finished_at=now(),heartbeat_at=now()
  where id=p_attempt_id;

  if v_retry then
    if v_old_message_id is not null then
      perform pgmq.archive('schedule_optimizer_v2',v_old_message_id);
    end if;
    perform solver_private.reset_retry_outputs_v2(p_run_id);
    select pgmq.send('schedule_optimizer_v2',jsonb_build_object(
      'schemaVersion',2,'runId',p_run_id,'retry',true,
      'reason',left(coalesce(p_error_code,'WORKER_ERROR'),100),
      'solverVersion',v_run.solver_version
    )) into v_message_id;
    update public.optimization_runs_v2
    set status='QUEUED',phase='RETRY_QUEUED',progress=0,
      queue_message_id=v_message_id,lease_owner=null,lease_token=null,
      lease_expires_at=null,worker_execution_name=null,heartbeat_at=null,
      started_at=null,finished_at=null,
      failure_code=left(coalesce(p_error_code,'WORKER_ERROR'),100),
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
      failure_code=left(coalesce(p_error_code,'WORKER_ERROR'),100),
      finished_at=now(),updated_at=now()
    where run_id=p_run_id;
    update public.optimization_runs_v2
    set status=v_outcome,phase=v_outcome,progress=0,queue_message_id=null,
      lease_owner=null,lease_token=null,lease_expires_at=null,
      worker_execution_name=null,
      failure_code=left(coalesce(p_error_code,'WORKER_ERROR'),100),
      failure_message=left(coalesce(p_error_message,'Nieznany błąd workera.'),1000),
      finished_at=now(),updated_at=now()
    where id=p_run_id;
  end if;
  update solver_private.optimization_dispatch_v2
  set dispatch_owner=null,dispatch_token=null,dispatch_message_id=null,
    dispatch_reserved_at=null,dispatch_expires_at=null,
    worker_launch_token=null,dispatched_at=null
  where run_id=p_run_id;
  return jsonb_build_object('status',v_outcome,'retry',v_retry);
end;
$$;

revoke all on function solver_private.reset_retry_outputs_v2(uuid)
  from public,anon,authenticated,service_role;

revoke all on function public.solver_claim_v2(
  uuid,uuid,text,text,integer,integer
) from public,anon,authenticated;
revoke all on function public.solver_dispatch_next_v2(text,integer)
  from public,anon,authenticated;
revoke all on function public.solver_mark_dispatched_v2(uuid,uuid,text)
  from public,anon,authenticated;
revoke all on function public.solver_release_dispatch_v2(uuid,uuid,text)
  from public,anon,authenticated;
revoke all on function public.solver_reconcile_stale_v2(
  text,text,integer,integer,uuid,text,uuid,integer,integer,text,text
) from public,anon,authenticated;
revoke all on function public.solver_interrupt_v2(uuid,uuid,uuid,text)
  from public,anon,authenticated;
revoke all on function public.solver_fail_attempt_v2(
  uuid,uuid,uuid,text,text,boolean
) from public,anon,authenticated;

grant execute on function public.solver_claim_v2(
  uuid,uuid,text,text,integer,integer
) to service_role;
grant execute on function public.solver_dispatch_next_v2(text,integer)
  to service_role;
grant execute on function public.solver_mark_dispatched_v2(uuid,uuid,text)
  to service_role;
grant execute on function public.solver_release_dispatch_v2(uuid,uuid,text)
  to service_role;
grant execute on function public.solver_reconcile_stale_v2(
  text,text,integer,integer,uuid,text,uuid,integer,integer,text,text
) to service_role;
grant execute on function public.solver_interrupt_v2(uuid,uuid,uuid,text)
  to service_role;
grant execute on function public.solver_fail_attempt_v2(
  uuid,uuid,uuid,text,text,boolean
) to service_role;

comment on function public.solver_claim_v2(
  uuid,uuid,text,text,integer,integer
) is 'Consumes one Cloud Run launch token only when the immutable solver version matches.';
comment on function public.solver_reconcile_stale_v2(
  text,text,integer,integer,uuid,text,uuid,integer,integer,text,text
) is 'Two-phase SCAN/APPLY recovery; only conclusive provider observations can mutate a run.';
