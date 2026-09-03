-- Canonical provider-neutral pull claim.
--
-- A worker may only claim runs built for its exact immutable solver version.
-- Mismatched messages are temporarily hidden so another compatible run can
-- be claimed without destroying or starving the original queue entry.

create or replace function public.solver_claim_next_v2(
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
$$;

revoke all on function public.solver_claim_next_v2(
  text,text,integer,integer
) from public,anon,authenticated,service_role;
grant execute on function public.solver_claim_next_v2(
  text,text,integer,integer
) to service_role;

comment on function public.solver_claim_next_v2(
  text,text,integer,integer
) is
  'Atomically claims one version-compatible PGMQ run for a provider-neutral worker.';
