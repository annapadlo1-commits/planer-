-- Bind a worker lease to the one-time launch token reserved by the dispatcher.
-- This migration intentionally follows solver_dispatch_private_v2 because the
-- claim function's row type depends on that private table.

drop function if exists public.solver_claim_v2(uuid,text,integer,integer);

create or replace function public.solver_claim_v2(
  p_run_id uuid,p_dispatch_token uuid,p_worker_id text,
  p_task_attempt integer,p_lease_seconds integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run public.optimization_runs_v2%rowtype;
  v_dispatch solver_private.optimization_dispatch_v2%rowtype;
  v_attempt_id uuid := gen_random_uuid();
  v_token uuid := gen_random_uuid();
  v_attempt_number integer;
begin
  if length(trim(coalesce(p_worker_id,''))) not between 3 and 200 then
    raise exception 'INVALID_WORKER_ID';
  end if;
  if coalesce(p_task_attempt,-1)<0 then raise exception 'INVALID_TASK_ATTEMPT'; end if;
  if coalesce(p_lease_seconds,0) not between 30 and 900 then
    raise exception 'INVALID_LEASE_SECONDS';
  end if;

  select * into v_run
  from public.optimization_runs_v2
  where id=p_run_id
  for update;
  if v_run.id is null then raise exception 'RUN_NOT_FOUND'; end if;
  select * into v_dispatch
  from solver_private.optimization_dispatch_v2 d
  where d.run_id=p_run_id
  for update;
  if p_dispatch_token is null
    or v_dispatch.worker_launch_token is distinct from p_dispatch_token
  then raise exception 'DISPATCH_TOKEN_MISMATCH'; end if;

  if v_run.status='CANCEL_REQUESTED' then
    update solver_private.optimization_dispatch_v2
    set worker_launch_token=null where run_id=p_run_id;
    update public.optimization_runs_v2
    set status='CANCELLED',phase='CANCELLED',finished_at=now(),updated_at=now(),
      lease_owner=null,lease_token=null,lease_expires_at=null
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
    update solver_private.optimization_dispatch_v2
    set worker_launch_token=null where run_id=p_run_id;
    update public.optimization_runs_v2
    set status='FAILED',phase='FAILED',failure_code='MAX_ATTEMPTS',
      failure_message='Przekroczono limit prób solvera.',finished_at=now(),
      updated_at=now(),lease_owner=null,lease_token=null,lease_expires_at=null
    where id=p_run_id;
    return jsonb_build_object('claimed',false,'status','FAILED');
  end if;

  update solver_private.optimization_attempts_v2
  set status='LEASE_LOST',finished_at=now(),error_code='LEASE_EXPIRED'
  where run_id=p_run_id and status='RUNNING';
  update solver_private.optimization_dispatch_v2
  set worker_launch_token=null where run_id=p_run_id;

  v_attempt_number := v_run.attempt_count+1;
  insert into solver_private.optimization_attempts_v2(
    id,run_id,attempt_number,task_attempt,worker_id,worker_execution_name,lease_token
  ) values(
    v_attempt_id,p_run_id,v_attempt_number,p_task_attempt,trim(p_worker_id),
    v_run.worker_execution_name,v_token
  );
  update public.optimization_runs_v2
  set status='RUNNING',phase='CLAIMED',progress=greatest(progress,1),
    attempt_count=v_attempt_number,lease_owner=trim(p_worker_id),lease_token=v_token,
    lease_expires_at=now()+make_interval(secs=>p_lease_seconds),heartbeat_at=now(),
    started_at=coalesce(started_at,now()),updated_at=now(),failure_code=null,
    failure_message=null
  where id=p_run_id;

  return jsonb_build_object(
    'claimed',true,'runId',p_run_id,'attemptId',v_attempt_id,
    'attemptNumber',v_attempt_number,'leaseToken',v_token,
    'leaseExpiresAt',now()+make_interval(secs=>p_lease_seconds),
    'snapshotHash',v_run.snapshot_hash
  );
end;
$$;

revoke all on function public.solver_claim_v2(uuid,uuid,text,integer,integer)
  from public,anon,authenticated;
grant execute on function public.solver_claim_v2(uuid,uuid,text,integer,integer)
  to service_role;

comment on function public.solver_claim_v2(uuid,uuid,text,integer,integer) is
  'Consumes one dispatcher launch token and creates an idempotent solver lease.';
