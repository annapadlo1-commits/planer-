-- GRAFIK PRO 3.0 -- durable optional push-dispatcher contract.
--
-- The dispatcher owns only the short transaction that takes one PGMQ message
-- and starts an external worker. The solver owns the existing worker lease. Keeping
-- those leases separate prevents a dispatcher reservation from blocking
-- solver_claim_v2.

alter table public.optimization_runs_v2
  add column dispatch_owner text,
  add column dispatch_token uuid,
  add column dispatch_message_id bigint,
  add column dispatch_reserved_at timestamptz,
  add column dispatch_expires_at timestamptz,
  add column dispatched_at timestamptz,
  add column dispatch_attempt_count integer not null default 0;

alter table public.optimization_runs_v2
  add constraint optimization_runs_v2_dispatch_attempt_count_check
    check (dispatch_attempt_count >= 0),
  add constraint optimization_runs_v2_dispatch_lease_check check (
    (
      dispatch_owner is null
      and dispatch_token is null
      and dispatch_message_id is null
      and dispatch_reserved_at is null
      and dispatch_expires_at is null
    )
    or
    (
      dispatch_owner is not null
      and dispatch_token is not null
      and dispatch_message_id is not null
      and dispatch_reserved_at is not null
      and dispatch_expires_at is not null
      and dispatch_expires_at > dispatch_reserved_at
    )
  );

create unique index optimization_runs_v2_worker_execution_name_uidx
  on public.optimization_runs_v2(worker_execution_name)
  where worker_execution_name is not null;

create index optimization_runs_v2_dispatch_pending_idx
  on public.optimization_runs_v2(status,phase,dispatch_reserved_at)
  where status='QUEUED' and dispatch_token is not null;

-- A solver retry writes a new queue message. Any reservation for the previous
-- message is stale at that point and must not block the retry.
create or replace function solver_private.reset_stale_dispatch_v2()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.status='QUEUED'
    and new.queue_message_id is distinct from old.queue_message_id
  then
    new.dispatch_owner := null;
    new.dispatch_token := null;
    new.dispatch_message_id := null;
    new.dispatch_reserved_at := null;
    new.dispatch_expires_at := null;
  end if;
  return new;
end;
$$;

create trigger optimization_runs_v2_reset_stale_dispatch
before update of queue_message_id on public.optimization_runs_v2
for each row execute function solver_private.reset_stale_dispatch_v2();

revoke all on function solver_private.reset_stale_dispatch_v2()
  from public,anon,authenticated;
grant execute on function solver_private.reset_stale_dispatch_v2()
  to service_role;

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
  v_token uuid;
  v_scan_count integer := 0;
begin
  if length(trim(coalesce(p_dispatcher_id,''))) not between 3 and 200 then
    raise exception 'INVALID_DISPATCHER_ID';
  end if;
  if coalesce(p_lease_seconds,0) not between 15 and 300 then
    raise exception 'INVALID_DISPATCH_LEASE_SECONDS';
  end if;

  -- Scan a bounded number of stale messages so one bad historical message
  -- cannot starve the queue. pgmq.read is atomic and applies the visibility
  -- timeout inside this same transaction.
  loop
    v_scan_count := v_scan_count+1;
    v_message_id := null;
    v_message := null;

    select q.msg_id,q.message
      into v_message_id,v_message
    from pgmq.read('schedule_optimizer_v2',p_lease_seconds,1) q
    limit 1;

    if v_message_id is null then
      return jsonb_build_object('found',false);
    end if;

    if coalesce(v_message->>'runId','') !~*
      '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    then
      perform pgmq.archive('schedule_optimizer_v2',v_message_id);
      if v_scan_count<20 then continue; end if;
      return jsonb_build_object('found',false,'staleMessages',v_scan_count);
    end if;

    v_run_id := (v_message->>'runId')::uuid;
    select * into v_run
    from public.optimization_runs_v2
    where id=v_run_id
    for update;

    if v_run.id is null
      or v_run.status<>'QUEUED'
      or v_run.queue_message_id is distinct from v_message_id
    then
      perform pgmq.archive('schedule_optimizer_v2',v_message_id);
      if v_scan_count<20 then continue; end if;
      return jsonb_build_object('found',false,'staleMessages',v_scan_count);
    end if;

    -- Once an external launch might have happened, expiry alone is not enough
    -- evidence to launch again. A reconciler/operator must explicitly release
    -- an ambiguous reservation. This favors at-most-one external execution;
    -- solver_claim_v2 remains the final idempotency fence for solver work.
    if v_run.dispatch_token is not null then
      perform pgmq.set_vt('schedule_optimizer_v2',v_message_id,p_lease_seconds);
      return jsonb_build_object(
        'found',false,
        'dispatchInFlight',true,
        'runId',v_run.id,
        'reservedAt',v_run.dispatch_reserved_at
      );
    end if;

    v_token := gen_random_uuid();
    update public.optimization_runs_v2
    set phase='DISPATCHING',
      dispatch_owner=trim(p_dispatcher_id),
      dispatch_token=v_token,
      dispatch_message_id=v_message_id,
      dispatch_reserved_at=now(),
      dispatch_expires_at=now()+make_interval(secs=>p_lease_seconds),
      dispatch_attempt_count=dispatch_attempt_count+1,
      updated_at=now()
    where id=v_run.id;

    return jsonb_build_object(
      'found',true,
      'runId',v_run.id,
      'dispatchToken',v_token,
      'queueMessageId',v_message_id,
      'snapshotHash',v_run.snapshot_hash,
      'dispatchAttempt',v_run.dispatch_attempt_count+1
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
  v_message_id bigint;
begin
  if coalesce(p_execution_name,'') !~
    '^projects/[^/]+/locations/[^/]+/jobs/[^/]+/executions/[^/]+$'
  then
    raise exception 'INVALID_EXECUTION_NAME';
  end if;

  select * into v_run
  from public.optimization_runs_v2
  where id=p_run_id
  for update;
  if v_run.id is null then raise exception 'RUN_NOT_FOUND'; end if;

  -- Repeating the acknowledgement after a client-side timeout is safe.
  if v_run.dispatch_token is null
    and v_run.worker_execution_name=p_execution_name
  then
    return jsonb_build_object(
      'marked',true,'reused',true,'runId',p_run_id,
      'executionName',p_execution_name
    );
  end if;
  if v_run.dispatch_token is distinct from p_dispatch_token then
    raise exception 'DISPATCH_TOKEN_MISMATCH';
  end if;
  if v_run.worker_execution_name is not null
    and v_run.worker_execution_name<>p_execution_name
  then
    raise exception 'RUN_ALREADY_DISPATCHED';
  end if;

  v_message_id := v_run.dispatch_message_id;
  update public.optimization_runs_v2
  set worker_execution_name=p_execution_name,
    dispatched_at=coalesce(dispatched_at,now()),
    phase=case when status='QUEUED' then 'DISPATCHED' else phase end,
    dispatch_owner=null,
    dispatch_token=null,
    dispatch_message_id=null,
    dispatch_reserved_at=null,
    dispatch_expires_at=null,
    updated_at=now()
  where id=p_run_id;

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
  v_message_id bigint;
begin
  select * into v_run
  from public.optimization_runs_v2
  where id=p_run_id
  for update;
  if v_run.id is null then raise exception 'RUN_NOT_FOUND'; end if;

  if v_run.dispatch_token is null
    and v_run.status='QUEUED'
    and v_run.worker_execution_name is null
  then
    return jsonb_build_object('released',true,'reused',true,'runId',p_run_id);
  end if;
  if v_run.dispatch_token is distinct from p_dispatch_token then
    raise exception 'DISPATCH_TOKEN_MISMATCH';
  end if;
  if v_run.worker_execution_name is not null then
    raise exception 'DISPATCH_ALREADY_ACKNOWLEDGED';
  end if;
  if v_run.status<>'QUEUED' then
    raise exception 'RUN_NOT_QUEUED';
  end if;

  v_message_id := v_run.dispatch_message_id;
  update public.optimization_runs_v2
  set phase='RETRY_QUEUED',
    dispatch_owner=null,
    dispatch_token=null,
    dispatch_message_id=null,
    dispatch_reserved_at=null,
    dispatch_expires_at=null,
    failure_code=case
      when p_reason is null then failure_code else 'DISPATCH_REJECTED'
    end,
    failure_message=case
      when p_reason is null then failure_message
      else left('Nie udało się uruchomić workera: '||p_reason,1000)
    end,
    updated_at=now()
  where id=p_run_id;

  if v_message_id is not null then
    perform pgmq.set_vt('schedule_optimizer_v2',v_message_id,0);
  end if;

  return jsonb_build_object('released',true,'reused',false,'runId',p_run_id);
end;
$$;

revoke all on function public.solver_dispatch_next_v2(text,integer)
  from public,anon,authenticated;
revoke all on function public.solver_mark_dispatched_v2(uuid,uuid,text)
  from public,anon,authenticated;
revoke all on function public.solver_release_dispatch_v2(uuid,uuid,text)
  from public,anon,authenticated;

grant execute on function public.solver_dispatch_next_v2(text,integer)
  to service_role;
grant execute on function public.solver_mark_dispatched_v2(uuid,uuid,text)
  to service_role;
grant execute on function public.solver_release_dispatch_v2(uuid,uuid,text)
  to service_role;

comment on function public.solver_dispatch_next_v2(text,integer) is
  'Service-role-only PGMQ reservation for an optional push dispatcher.';
comment on function public.solver_mark_dispatched_v2(uuid,uuid,text) is
  'Acknowledges one external execution and archives its PGMQ message.';
comment on function public.solver_release_dispatch_v2(uuid,uuid,text) is
  'Releases only a definitively rejected external launch; ambiguous launches stay reserved.';
