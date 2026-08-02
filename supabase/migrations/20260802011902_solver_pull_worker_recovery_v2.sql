/*
-- GRAFIK PRO 3.0 -- provider-neutral pull worker and automatic recovery.
--
-- Supabase remains the durable authority for requests, immutable snapshots,
-- leases, retries and results. A long-lived OR-Tools container pulls work
-- through the narrow solver gateway. No cloud-provider launcher or browser
-- loop is required.

create extension if not exists pg_cron with schema pg_catalog;

-- The disposable development branch previously used a provider-specific
-- column name. Keep the migration replayable there and on a clean database.
do $$
begin
  if exists(
    select 1 from information_schema.columns
    where table_schema='public' and table_name='optimization_runs_v2'
      and column_name='gcp_execution_name'
  ) and not exists(
    select 1 from information_schema.columns
    where table_schema='public' and table_name='optimization_runs_v2'
      and column_name='worker_execution_name'
  ) then
    alter table public.optimization_runs_v2
      rename column gcp_execution_name to worker_execution_name;
  end if;

  if exists(
    select 1 from information_schema.columns
    where table_schema='solver_private'
      and table_name='optimization_attempts_v2'
      and column_name='gcp_execution_name'
  ) and not exists(
    select 1 from information_schema.columns
    where table_schema='solver_private'
      and table_name='optimization_attempts_v2'
      and column_name='worker_execution_name'
  ) then
    alter table solver_private.optimization_attempts_v2
      rename column gcp_execution_name to worker_execution_name;
  end if;
end $$;

drop index if exists public.optimization_runs_v2_gcp_execution_name_uidx;
create unique index if not exists optimization_runs_v2_worker_execution_name_uidx
  on public.optimization_runs_v2(worker_execution_name)
  where worker_execution_name is not null;

-- A retry must never combine variants produced by different attempts.
create or replace function solver_private.cleanup_retry_variants_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status='QUEUED'
    and old.status in ('RUNNING','VALIDATING','CANCEL_REQUESTED')
  then
    delete from public.plan_variants_v2 where run_id=new.id;
    update public.optimization_run_strategies_v2
    set status='QUEUED',phase='RETRY_QUEUED',progress=0,metrics='{}'::jsonb,
      failure_code=null,started_at=null,finished_at=null,updated_at=now()
    where run_id=new.id;
  end if;
  return new;
end;
$$;

revoke all on function solver_private.cleanup_retry_variants_v2()
  from public,anon,authenticated,service_role;

drop trigger if exists optimization_runs_v2_cleanup_retry_variants
  on public.optimization_runs_v2;
create trigger optimization_runs_v2_cleanup_retry_variants
after update of status on public.optimization_runs_v2
for each row execute function solver_private.cleanup_retry_variants_v2();

create or replace function public.solver_claim_next_v2(
  p_worker_id text,
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
  v_execution_name text;
  v_scan_count integer:=0;
begin
  if length(trim(coalesce(p_worker_id,''))) not between 3 and 200
    or trim(p_worker_id) !~ '^[A-Za-z0-9._:@/-]+$'
  then raise exception 'INVALID_WORKER_ID'; end if;
  if coalesce(p_task_attempt,-1) not between 0 and 10000 then
    raise exception 'INVALID_TASK_ATTEMPT';
  end if;
  if coalesce(p_lease_seconds,0) not between 30 and 900 then
    raise exception 'INVALID_LEASE_SECONDS';
  end if;

  loop
    v_scan_count:=v_scan_count+1;
    v_message_id:=null;
    v_message:=null;

    select q.msg_id,q.message into v_message_id,v_message
    from pgmq.read('schedule_optimizer_v2',p_lease_seconds,1) q
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
    select * into v_run from public.optimization_runs_v2
    where id=v_run_id for update;

    if v_run.id is null
      or v_run.status<>'QUEUED'
      or v_run.queue_message_id is distinct from v_message_id
    then
      perform pgmq.archive('schedule_optimizer_v2',v_message_id);
      if v_scan_count<20 then continue; end if;
      return jsonb_build_object('claimed',false,'status','EMPTY');
    end if;

    if v_run.attempt_count>=v_run.max_attempts then
      perform pgmq.archive('schedule_optimizer_v2',v_message_id);
      delete from public.plan_variants_v2 where run_id=v_run.id;
      update public.optimization_runs_v2
      set status='FAILED',phase='FAILED',failure_code='MAX_ATTEMPTS',
        failure_message='Przekroczono limit prób solvera.',
        queue_message_id=null,finished_at=now(),updated_at=now()
      where id=v_run.id;
      update public.optimization_run_strategies_v2
      set status='FAILED',phase='FAILED',failure_code='MAX_ATTEMPTS',
        finished_at=now(),updated_at=now()
      where run_id=v_run.id;
      if v_scan_count<20 then continue; end if;
      return jsonb_build_object('claimed',false,'status','EMPTY');
    end if;

    delete from public.plan_variants_v2 where run_id=v_run.id;
    update solver_private.optimization_attempts_v2
    set status='LEASE_LOST',finished_at=now(),error_code='LEASE_EXPIRED',
      error_message='Poprzednia próba utraciła dzierżawę.'
    where run_id=v_run.id and status='RUNNING';

    v_attempt_id:=gen_random_uuid();
    v_lease_token:=gen_random_uuid();
    v_attempt_number:=v_run.attempt_count+1;
    v_execution_name:=left(
      trim(p_worker_id)||':'||v_run.id::text||':'||v_attempt_number::text,
      500
    );

    insert into solver_private.optimization_attempts_v2(
      id,run_id,attempt_number,task_attempt,worker_id,
      worker_execution_name,lease_token
    ) values(
      v_attempt_id,v_run.id,v_attempt_number,p_task_attempt,trim(p_worker_id),
      v_execution_name,v_lease_token
    );

    update public.optimization_runs_v2
    set status='RUNNING',phase='CLAIMED',progress=greatest(progress,1),
      attempt_count=v_attempt_number,queue_message_id=null,
      lease_owner=trim(p_worker_id),lease_token=v_lease_token,
      lease_expires_at=now()+make_interval(secs=>p_lease_seconds),
      worker_execution_name=v_execution_name,heartbeat_at=now(),
      started_at=coalesce(started_at,now()),finished_at=null,
      failure_code=null,failure_message=null,updated_at=now()
    where id=v_run.id;
    update public.optimization_run_strategies_v2
    set status='RUNNING',phase='CLAIMED',progress=1,
      started_at=coalesce(started_at,now()),finished_at=null,
      failure_code=null,updated_at=now()
    where run_id=v_run.id;

    perform pgmq.archive('schedule_optimizer_v2',v_message_id);
    return jsonb_build_object(
      'claimed',true,'runId',v_run.id,'attemptId',v_attempt_id,
      'attemptNumber',v_attempt_number,'leaseToken',v_lease_token,
      'leaseExpiresAt',now()+make_interval(secs=>p_lease_seconds),
      'snapshotHash',v_run.snapshot_hash
    );
  end loop;
end;
$$;

revoke all on function public.solver_claim_next_v2(text,integer,integer)
  from public,anon,authenticated;
grant execute on function public.solver_claim_next_v2(text,integer,integer)
  to service_role;

comment on function public.solver_claim_next_v2(text,integer,integer) is
  'Atomically consumes one PGMQ message and creates a provider-neutral solver lease.';

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

  for v_run in
    select r.* from public.optimization_runs_v2 r
    where r.status in ('RUNNING','VALIDATING','CANCEL_REQUESTED')
      and r.lease_expires_at is not null
      and r.lease_expires_at<=now()
    order by r.lease_expires_at,r.id
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
      update public.optimization_runs_v2
      set status='CANCELLED',phase='CANCELLED',progress=0,
        lease_owner=null,lease_token=null,lease_expires_at=null,
        finished_at=now(),updated_at=now()
      where id=v_run.id;
      update public.optimization_run_strategies_v2
      set status='CANCELLED',phase='CANCELLED',finished_at=now(),updated_at=now()
      where run_id=v_run.id;
      v_cancelled:=v_cancelled+1;
    elsif v_run.attempt_count<v_run.max_attempts then
      select pgmq.send('schedule_optimizer_v2',jsonb_build_object(
        'schemaVersion',2,'runId',v_run.id,'retry',true,
        'reason','LEASE_EXPIRED'
      )) into v_message_id;
      update public.optimization_runs_v2
      set status='QUEUED',phase='RETRY_QUEUED',progress=0,
        queue_message_id=v_message_id,lease_owner=null,lease_token=null,
        lease_expires_at=null,worker_execution_name=null,
        failure_code='LEASE_EXPIRED',
        failure_message='Przerwana próba została automatycznie dodana do kolejki.',
        updated_at=now()
      where id=v_run.id;
      v_requeued:=v_requeued+1;
    else
      delete from public.plan_variants_v2 where run_id=v_run.id;
      update public.optimization_runs_v2
      set status='FAILED',phase='FAILED',
        lease_owner=null,lease_token=null,lease_expires_at=null,
        failure_code='MAX_ATTEMPTS',
        failure_message='Solver nie zakończył pracy po maksymalnej liczbie prób.',
        finished_at=now(),updated_at=now()
      where id=v_run.id;
      update public.optimization_run_strategies_v2
      set status='FAILED',phase='FAILED',failure_code='MAX_ATTEMPTS',
        finished_at=now(),updated_at=now()
      where run_id=v_run.id and status<>'READY';
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

-- cron.schedule upserts by job name, so development replays stay singular.
select cron.schedule(
  'grafik-pro-solver-v2-recovery',
  '* * * * *',
  'select solver_private.recover_expired_solver_runs_v2(20);'
);

comment on function solver_private.recover_expired_solver_runs_v2(integer) is
  'Requeues expired leases and finalizes cancelled or exhausted solver runs.';
*/
