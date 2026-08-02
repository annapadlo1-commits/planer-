-- GRAFIK PRO 3.0 -- provider-neutral pull worker and automatic recovery.
--
-- Supabase remains the durable authority for requests, immutable snapshots,
-- leases, retries and results. A long-lived OR-Tools container pulls work
-- through the narrow solver gateway. No cloud-provider launcher or browser
-- loop is required.

create extension if not exists pg_cron with schema pg_catalog;

-- Remove the optional push-dispatcher boundary before dropping its private
-- reservation table. These objects were never required by Alpha 15.
drop trigger if exists optimization_runs_v2_reset_stale_dispatch
  on public.optimization_runs_v2;
drop function if exists solver_private.reset_stale_dispatch_v2();

drop function if exists public.solver_claim_v2(
  uuid,uuid,text,text,integer,integer
);
drop function if exists public.solver_claim_v2(
  uuid,uuid,text,integer,integer
);
drop function if exists public.solver_dispatch_next_v2(text,integer);
drop function if exists public.solver_mark_dispatched_v2(uuid,uuid,text);
drop function if exists public.solver_release_dispatch_v2(uuid,uuid,text);
drop function if exists public.solver_reconcile_stale_v2(
  text,text,integer,integer,uuid,text,uuid,integer,integer,text,text
);
drop function if exists public.solver_interrupt_v2(uuid,uuid,uuid,text);
drop function if exists public.solver_fail_attempt_v2(
  uuid,uuid,uuid,text,text,boolean
);
drop table if exists solver_private.optimization_dispatch_v2;

drop function if exists public.solver_claim_next_v2(text,integer,integer);
drop function if exists public.solver_claim_next_v2(
  text,text,integer,integer
);

alter table solver_private.optimization_attempts_v2
  add column if not exists worker_version text;
update solver_private.optimization_attempts_v2 attempt_row
set worker_version=run_row.solver_version
from public.optimization_runs_v2 run_row
where run_row.id=attempt_row.run_id
  and attempt_row.worker_version is null;
alter table solver_private.optimization_attempts_v2
  alter column worker_version set not null;

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

revoke all on function solver_private.reset_retry_outputs_v2(uuid)
  from public,anon,authenticated,service_role;

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
begin
  if length(trim(coalesce(p_worker_id,''))) not between 3 and 200
    or trim(p_worker_id) !~ '^[A-Za-z0-9._:@/-]+$'
  then raise exception 'INVALID_WORKER_ID'; end if;
  if length(coalesce(p_worker_version,'')) not between 1 and 200
    or p_worker_version !~ '^[A-Za-z0-9._:+/-]+$'
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

    select queue_message.msg_id,queue_message.message
    into v_message_id,v_message
    from pgmq.read('schedule_optimizer_v2',p_lease_seconds,1) queue_message
    limit 1;

    if v_message_id is null then
      return jsonb_build_object('claimed',false,'status','EMPTY');
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

    -- Raising rolls back pgmq.read as well, so the matching worker image can
    -- immediately consume the still-visible message.
    if v_run.solver_version is distinct from p_worker_version then
      raise exception 'SOLVER_VERSION_MISMATCH';
    end if;

    if v_run.status='CANCEL_REQUESTED' then
      perform pgmq.archive('schedule_optimizer_v2',v_message_id);
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
      if v_scan_count<20 then continue; end if;
      return jsonb_build_object('claimed',false,'status','EMPTY');
    end if;

    if v_run.attempt_count>=v_run.max_attempts then
      perform pgmq.archive('schedule_optimizer_v2',v_message_id);
      delete from public.plan_variants_v2 where run_id=v_run.id;
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

    update solver_private.optimization_attempts_v2
    set status='LEASE_LOST',finished_at=now(),heartbeat_at=now(),
      error_code='LEASE_EXPIRED',
      error_message='Poprzednia próba utraciła dzierżawę.'
    where run_id=v_run.id and status='RUNNING';
    delete from public.plan_variants_v2 where run_id=v_run.id;

    v_attempt_id:=gen_random_uuid();
    v_lease_token:=gen_random_uuid();
    v_attempt_number:=v_run.attempt_count+1;
    v_lease_expires_at:=now()+make_interval(secs=>p_lease_seconds);
    v_execution_name:=left(
      trim(p_worker_id)||':'||v_run.id::text||':'||v_attempt_number::text,
      500
    );

    insert into solver_private.optimization_attempts_v2(
      id,run_id,attempt_number,task_attempt,worker_id,worker_version,
      worker_execution_name,lease_token,status
    ) values(
      v_attempt_id,v_run.id,v_attempt_number,p_task_attempt,trim(p_worker_id),
      p_worker_version,v_execution_name,v_lease_token,'RUNNING'
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
      'leaseExpiresAt',v_lease_expires_at,'snapshotHash',v_run.snapshot_hash,
      'solverVersion',v_run.solver_version
    );
  end loop;
end;
$$;

revoke all on function public.solver_claim_next_v2(
  text,text,integer,integer
) from public,anon,authenticated;
grant execute on function public.solver_claim_next_v2(
  text,text,integer,integer
) to service_role;

comment on function public.solver_claim_next_v2(
  text,text,integer,integer
) is 'Atomically consumes one PGMQ message and creates a version-bound provider-neutral solver lease.';

create or replace function solver_private.recover_expired_solver_runs_v2(
  p_limit integer default 20
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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

revoke all on function solver_private.recover_expired_solver_runs_v2(integer)
  from public,anon,authenticated,service_role;

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
$$;

revoke all on function public.solver_interrupt_v2(uuid,uuid,uuid,text)
  from public,anon,authenticated;
revoke all on function public.solver_fail_attempt_v2(
  uuid,uuid,uuid,text,text,boolean
) from public,anon,authenticated;
grant execute on function public.solver_interrupt_v2(uuid,uuid,uuid,text)
  to service_role;
grant execute on function public.solver_fail_attempt_v2(
  uuid,uuid,uuid,text,text,boolean
) to service_role;

do $$
declare
  v_job_id bigint;
begin
  for v_job_id in
    select jobid from cron.job
    where jobname='grafik-pro-solver-v2-recovery'
  loop
    perform cron.unschedule(v_job_id);
  end loop;
end;
$$;

select cron.schedule(
  'grafik-pro-solver-v2-recovery',
  '* * * * *',
  'select solver_private.recover_expired_solver_runs_v2(20);'
);

comment on function solver_private.recover_expired_solver_runs_v2(integer) is
  'Requeues expired provider-neutral solver leases and finalizes cancelled or exhausted runs.';
