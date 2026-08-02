-- Move dispatcher reservation credentials out of the requester-readable run
-- table and bind every optional push-worker claim to a one-time launch token.

create table if not exists solver_private.optimization_dispatch_v2 (
  run_id uuid primary key references public.optimization_runs_v2(id) on delete cascade,
  dispatch_owner text,
  dispatch_token uuid,
  dispatch_message_id bigint,
  dispatch_reserved_at timestamptz,
  dispatch_expires_at timestamptz,
  worker_launch_token uuid,
  dispatched_at timestamptz,
  dispatch_attempt_count integer not null default 0 check (dispatch_attempt_count>=0),
  check (
    (
      dispatch_owner is null and dispatch_token is null
      and dispatch_message_id is null and dispatch_reserved_at is null
      and dispatch_expires_at is null
    )
    or
    (
      dispatch_owner is not null and dispatch_token is not null
      and dispatch_message_id is not null and dispatch_reserved_at is not null
      and dispatch_expires_at is not null
      and dispatch_expires_at>dispatch_reserved_at
    )
  )
);

-- Upgrade an already-installed test branch without exposing the copied token
-- for longer than this migration transaction.
insert into solver_private.optimization_dispatch_v2(
  run_id,dispatch_owner,dispatch_token,dispatch_message_id,
  dispatch_reserved_at,dispatch_expires_at,worker_launch_token,
  dispatched_at,dispatch_attempt_count
)
select r.id,r.dispatch_owner,r.dispatch_token,r.dispatch_message_id,
  r.dispatch_reserved_at,r.dispatch_expires_at,r.dispatch_token,
  r.dispatched_at,r.dispatch_attempt_count
from public.optimization_runs_v2 r
where r.dispatch_attempt_count>0 or r.dispatch_token is not null
on conflict(run_id) do update set
  dispatch_owner=excluded.dispatch_owner,
  dispatch_token=excluded.dispatch_token,
  dispatch_message_id=excluded.dispatch_message_id,
  dispatch_reserved_at=excluded.dispatch_reserved_at,
  dispatch_expires_at=excluded.dispatch_expires_at,
  worker_launch_token=coalesce(
    solver_private.optimization_dispatch_v2.worker_launch_token,
    excluded.worker_launch_token
  ),
  dispatched_at=coalesce(
    solver_private.optimization_dispatch_v2.dispatched_at,
    excluded.dispatched_at
  ),
  dispatch_attempt_count=greatest(
    solver_private.optimization_dispatch_v2.dispatch_attempt_count,
    excluded.dispatch_attempt_count
  );

create index if not exists optimization_dispatch_v2_pending_idx
  on solver_private.optimization_dispatch_v2(dispatch_reserved_at)
  where dispatch_token is not null or worker_launch_token is not null;

create or replace function solver_private.reset_stale_dispatch_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status='QUEUED'
    and new.queue_message_id is distinct from old.queue_message_id
  then
    -- worker_execution_name denotes the currently dispatched attempt. The old
    -- value remains preserved on optimization_attempts_v2, while the retried
    -- run must accept a different external execution name.
    new.worker_execution_name := null;
    update solver_private.optimization_dispatch_v2
    set dispatch_owner=null,dispatch_token=null,dispatch_message_id=null,
      dispatch_reserved_at=null,dispatch_expires_at=null,
      worker_launch_token=null,dispatched_at=null
    where run_id=new.id;
  end if;
  return new;
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
  v_scan_count integer := 0;
begin
  if length(trim(coalesce(p_dispatcher_id,''))) not between 3 and 200 then
    raise exception 'INVALID_DISPATCHER_ID';
  end if;
  if coalesce(p_lease_seconds,0) not between 15 and 300 then
    raise exception 'INVALID_DISPATCH_LEASE_SECONDS';
  end if;

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
      if v_run.id is not null then
        update solver_private.optimization_dispatch_v2
        set dispatch_owner=null,dispatch_token=null,dispatch_message_id=null,
          dispatch_reserved_at=null,dispatch_expires_at=null,
          worker_launch_token=null
        where run_id=v_run.id;
      end if;
      perform pgmq.archive('schedule_optimizer_v2',v_message_id);
      if v_scan_count<20 then continue; end if;
      return jsonb_build_object('found',false,'staleMessages',v_scan_count);
    end if;

    select * into v_dispatch
    from solver_private.optimization_dispatch_v2 d
    where d.run_id=v_run.id
    for update;
    if v_dispatch.dispatch_token is not null
      or v_dispatch.worker_launch_token is not null
    then
      perform pgmq.set_vt('schedule_optimizer_v2',v_message_id,p_lease_seconds);
      return jsonb_build_object(
        'found',false,'dispatchInFlight',true,'runId',v_run.id,
        'reservedAt',v_dispatch.dispatch_reserved_at
      );
    end if;

    v_token := gen_random_uuid();
    insert into solver_private.optimization_dispatch_v2 as dispatch_row(
      run_id,dispatch_owner,dispatch_token,dispatch_message_id,
      dispatch_reserved_at,dispatch_expires_at,worker_launch_token,
      dispatch_attempt_count
    ) values(
      v_run.id,trim(p_dispatcher_id),v_token,v_message_id,now(),
      now()+make_interval(secs=>p_lease_seconds),v_token,1
    )
    on conflict(run_id) do update set
      dispatch_owner=excluded.dispatch_owner,
      dispatch_token=excluded.dispatch_token,
      dispatch_message_id=excluded.dispatch_message_id,
      dispatch_reserved_at=excluded.dispatch_reserved_at,
      dispatch_expires_at=excluded.dispatch_expires_at,
      worker_launch_token=excluded.worker_launch_token,
      dispatched_at=null,
      dispatch_attempt_count=dispatch_row.dispatch_attempt_count+1
    returning * into v_dispatch;

    update public.optimization_runs_v2
    set phase='DISPATCHING',updated_at=now()
    where id=v_run.id;

    return jsonb_build_object(
      'found',true,'runId',v_run.id,'dispatchToken',v_token,
      'queueMessageId',v_message_id,'snapshotHash',v_run.snapshot_hash,
      'dispatchAttempt',v_dispatch.dispatch_attempt_count
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

  select * into v_run
  from public.optimization_runs_v2
  where id=p_run_id
  for update;
  if v_run.id is null then raise exception 'RUN_NOT_FOUND'; end if;
  select * into v_dispatch
  from solver_private.optimization_dispatch_v2 d
  where d.run_id=p_run_id
  for update;

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

  v_message_id := v_dispatch.dispatch_message_id;
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
  set worker_execution_name=p_execution_name
  where run_id=p_run_id and worker_execution_name is null;

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
  select * into v_run
  from public.optimization_runs_v2
  where id=p_run_id
  for update;
  if v_run.id is null then raise exception 'RUN_NOT_FOUND'; end if;
  select * into v_dispatch
  from solver_private.optimization_dispatch_v2 d
  where d.run_id=p_run_id
  for update;

  if v_dispatch.dispatch_token is null
    and v_run.status='QUEUED'
    and v_run.worker_execution_name is null
  then
    return jsonb_build_object('released',true,'reused',true,'runId',p_run_id);
  end if;
  if v_dispatch.dispatch_token is distinct from p_dispatch_token then
    raise exception 'DISPATCH_TOKEN_MISMATCH';
  end if;
  if v_run.worker_execution_name is not null then
    raise exception 'DISPATCH_ALREADY_ACKNOWLEDGED';
  end if;
  if v_run.status<>'QUEUED' then raise exception 'RUN_NOT_QUEUED'; end if;

  v_message_id := v_dispatch.dispatch_message_id;
  update solver_private.optimization_dispatch_v2
  set dispatch_owner=null,dispatch_token=null,dispatch_message_id=null,
    dispatch_reserved_at=null,dispatch_expires_at=null,
    worker_launch_token=null
  where run_id=p_run_id;
  update public.optimization_runs_v2
  set phase='RETRY_QUEUED',
    failure_code=case when p_reason is null then failure_code else 'DISPATCH_REJECTED' end,
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

drop index if exists public.optimization_runs_v2_dispatch_pending_idx;
alter table public.optimization_runs_v2
  drop constraint if exists optimization_runs_v2_dispatch_attempt_count_check,
  drop constraint if exists optimization_runs_v2_dispatch_lease_check,
  drop column if exists dispatch_owner,
  drop column if exists dispatch_token,
  drop column if exists dispatch_message_id,
  drop column if exists dispatch_reserved_at,
  drop column if exists dispatch_expires_at,
  drop column if exists dispatched_at,
  drop column if exists dispatch_attempt_count;

revoke all on table solver_private.optimization_dispatch_v2
  from public,anon,authenticated;
grant all on table solver_private.optimization_dispatch_v2 to service_role;

revoke all on function public.solver_dispatch_next_v2(text,integer)
  from public,anon,authenticated;
revoke all on function public.solver_mark_dispatched_v2(uuid,uuid,text)
  from public,anon,authenticated;
revoke all on function public.solver_release_dispatch_v2(uuid,uuid,text)
  from public,anon,authenticated;
grant execute on function public.solver_dispatch_next_v2(text,integer) to service_role;
grant execute on function public.solver_mark_dispatched_v2(uuid,uuid,text) to service_role;
grant execute on function public.solver_release_dispatch_v2(uuid,uuid,text) to service_role;

comment on table solver_private.optimization_dispatch_v2 is
  'Private dispatcher reservation and single-use external worker launch token.';
