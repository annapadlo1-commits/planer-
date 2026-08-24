-- UAT-NFJOB-001: parallel Northflank Job runtime for the OR-Tools solver.
--
-- Safety invariants:
--   * the existing provider-neutral service claim remains unchanged;
--   * authenticated requests still default to SERVICE;
--   * JOB requests are explicit and remove their PGMQ message atomically;
--   * one durable outbox row is bound to one optimizer generation;
--   * target claims are capability-bound and never fall back to another run;
--   * immutable provenance values can only transition JSON null -> value.

create table solver_private.solver_runtime_builds_uat_v1 (
  solver_version text primary key,
  solver_commit text not null check (solver_commit ~ '^[0-9a-f]{40}$'),
  solver_image_digest text,
  solver_build_id text not null check (length(solver_build_id) between 1 and 200),
  created_at timestamptz not null default now(),
  check (
    solver_image_digest is null
    or solver_image_digest ~ '^sha256:[0-9a-f]{64}$'
  )
);

revoke all on table solver_private.solver_runtime_builds_uat_v1
  from public,anon,authenticated,service_role;

insert into solver_private.solver_runtime_builds_uat_v1(
  solver_version,solver_commit,solver_image_digest,solver_build_id
) values(
  'ORTOOLS_V2_2026_08_02',
  '86522fe6d701a14a5a2ec90d999f385739a4f212',
  null,
  'difficult-price-5668'
);

create table solver_private.solver_job_runtime_config_uat_v1 (
  singleton boolean primary key default true check (singleton),
  default_execution_mode text not null default 'SERVICE'
    check (default_execution_mode='SERVICE'),
  dispatcher_enabled boolean not null default false,
  global_active_jobs integer not null default 2
    check (global_active_jobs between 1 and 20),
  per_organization_active_jobs integer not null default 1
    check (per_organization_active_jobs between 1 and 20),
  generation_quota_per_user_hour integer not null default 25
    check (generation_quota_per_user_hour between 1 and 100),
  wall_timeout_seconds integer not null default 720
    check (wall_timeout_seconds between 60 and 3600),
  claim_watchdog_seconds integer not null default 300
    check (claim_watchdog_seconds between 60 and 1800),
  heartbeat_watchdog_seconds integer not null default 180
    check (heartbeat_watchdog_seconds between 60 and 1800),
  deployment_plan text not null default 'nf-compute-100-1',
  configured_vcpu numeric(6,3) not null default 1,
  configured_ram_mb integer not null default 1024,
  estimated_usd_per_hour numeric(12,8) not null default 0.025,
  updated_at timestamptz not null default now()
);

revoke all on table solver_private.solver_job_runtime_config_uat_v1
  from public,anon,authenticated,service_role;

insert into solver_private.solver_job_runtime_config_uat_v1(singleton)
values(true);

create table solver_private.solver_job_dispatch_outbox_uat_v1 (
  run_id uuid primary key references public.optimization_runs_v2(id)
    on delete cascade,
  organization_key uuid not null references public.matrix_versions(id),
  month date not null,
  scope_type text not null check (scope_type in ('COMPANY','ROLE')),
  scope_role_id uuid references public.matrix_roles_v2(id),
  dispatch_status text not null default 'PENDING' check (
    dispatch_status in (
      'PENDING','DISPATCHING','ACCEPTANCE_UNKNOWN','ACCEPTED','STARTING',
      'RUNNING','SUCCEEDED','FAILED','CANCELLED'
    )
  ),
  dispatch_attempt integer not null default 0 check (dispatch_attempt>=0),
  solver_retry_count integer not null default 0 check (solver_retry_count>=0),
  dispatch_nonce uuid not null default gen_random_uuid() unique,
  dispatcher_lease_token uuid,
  dispatcher_lease_expires_at timestamptz,
  northflank_run_id text unique,
  requested_at timestamptz not null,
  dispatch_started_at timestamptz,
  northflank_accepted_at timestamptz,
  container_started_at timestamptz,
  worker_claimed_at timestamptz,
  solver_started_at timestamptz,
  solver_finished_at timestamptz,
  result_saved_at timestamptz,
  ready_at timestamptz,
  job_finished_at timestamptz,
  next_dispatch_at timestamptz not null default now(),
  last_http_status integer,
  last_error_code text,
  last_error text,
  dispatcher_version text,
  configured_plan text not null default 'nf-compute-100-1',
  configured_vcpu numeric(6,3) not null default 1,
  configured_ram_mb integer not null default 1024,
  estimated_usd_per_hour numeric(12,8) not null default 0.025,
  peak_rss_mb numeric(12,3),
  average_rss_mb numeric(12,3),
  peak_cpu_percent numeric(12,3),
  billable_seconds numeric(14,3),
  estimated_compute_cost_usd numeric(14,8),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((scope_type='ROLE')=(scope_role_id is not null)),
  check (
    (dispatcher_lease_token is null and dispatcher_lease_expires_at is null)
    or
    (dispatcher_lease_token is not null and dispatcher_lease_expires_at is not null)
  )
);

comment on table solver_private.solver_job_dispatch_outbox_uat_v1 is
  'UAT-only durable 1:1 dispatch and telemetry record for a Northflank Job generation.';

revoke all on table solver_private.solver_job_dispatch_outbox_uat_v1
  from public,anon,authenticated,service_role;

create index solver_job_dispatch_pending_uat_v1_idx
  on solver_private.solver_job_dispatch_outbox_uat_v1(
    next_dispatch_at,requested_at,run_id
  ) where dispatch_status='PENDING';

create index solver_job_dispatch_active_org_uat_v1_idx
  on solver_private.solver_job_dispatch_outbox_uat_v1(
    organization_key,dispatch_status
  ) where dispatch_status in (
    'DISPATCHING','ACCEPTANCE_UNKNOWN','ACCEPTED','STARTING','RUNNING'
  );

create index solver_job_dispatch_scope_role_uat_v1_idx
  on solver_private.solver_job_dispatch_outbox_uat_v1(scope_role_id)
  where scope_role_id is not null;

create unique index solver_job_dispatch_one_schedule_uat_v1_idx
  on solver_private.solver_job_dispatch_outbox_uat_v1(
    organization_key,month,scope_type,
    coalesce(scope_role_id,'00000000-0000-0000-0000-000000000000'::uuid)
  ) where dispatch_status in (
    'PENDING','DISPATCHING','ACCEPTANCE_UNKNOWN','ACCEPTED','STARTING','RUNNING'
  );

create or replace function solver_private.strip_temporal_json_uat_v1(p_value jsonb)
returns jsonb
language plpgsql
immutable
set search_path=''
as $$
declare
  v_type text:=jsonb_typeof(p_value);
  v_result jsonb;
begin
  if v_type='object' then
    select coalesce(jsonb_object_agg(item.key,
      solver_private.strip_temporal_json_uat_v1(item.value)),'{}'::jsonb)
    into v_result
    from jsonb_each(p_value) item
    where item.key not in (
      'createdAt','created_at','updatedAt','updated_at','activatedAt',
      'activated_at','publishedAt','published_at','timestamp','generatedAt'
    );
    return v_result;
  elsif v_type='array' then
    select coalesce(jsonb_agg(
      solver_private.strip_temporal_json_uat_v1(item.value)
      order by item.ordinality
    ),'[]'::jsonb)
    into v_result
    from jsonb_array_elements(p_value) with ordinality item(value,ordinality);
    return v_result;
  end if;
  return p_value;
end;
$$;

revoke all on function solver_private.strip_temporal_json_uat_v1(jsonb)
  from public,anon,authenticated,service_role;

create or replace function solver_private.strategy_config_hash_uat_v1(
  p_snapshot jsonb
) returns text
language sql
immutable
set search_path=''
as $$
  select encode(extensions.digest(convert_to(
    coalesce((
      select jsonb_agg(
        solver_private.strip_temporal_json_uat_v1(item.value)
        order by item.value->>'code',item.value->>'id',item.ordinality
      )
      from jsonb_array_elements(coalesce(p_snapshot->'strategies','[]'::jsonb))
        with ordinality item(value,ordinality)
    ),'[]'::jsonb)::text,
    'UTF8'
  ),'sha256'),'hex')
$$;

revoke all on function solver_private.strategy_config_hash_uat_v1(jsonb)
  from public,anon,authenticated,service_role;

create or replace function solver_private.version_stamp_set_once_uat_v1(
  p_stamp jsonb,p_key text,p_value jsonb
) returns jsonb
language plpgsql
immutable
set search_path=''
as $$
declare v_existing jsonb:=coalesce(p_stamp,'{}'::jsonb)->p_key;
begin
  if p_key is null or p_key='' then raise exception 'VERSION_STAMP_KEY_INVALID'; end if;
  if v_existing is null or v_existing='null'::jsonb then
    return jsonb_set(coalesce(p_stamp,'{}'::jsonb),array[p_key],p_value,true);
  end if;
  if v_existing is distinct from p_value then
    raise exception 'VERSION_STAMP_IMMUTABLE_%',upper(p_key);
  end if;
  return coalesce(p_stamp,'{}'::jsonb);
end;
$$;

revoke all on function solver_private.version_stamp_set_once_uat_v1(
  jsonb,text,jsonb
) from public,anon,authenticated,service_role;

create or replace function solver_private.build_run_version_stamp_uat_v1(
  p_run_id uuid,p_frontend_commit text,p_execution_mode text
) returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  v_run public.optimization_runs_v2%rowtype;
  v_snapshot jsonb;
  v_build solver_private.solver_runtime_builds_uat_v1%rowtype;
  v_matrix_version integer;
  v_matrix_hash text;
  v_semantics text;
  v_strategy_hash text;
begin
  if p_execution_mode not in ('SERVICE','JOB') then
    raise exception 'EXECUTION_MODE_INVALID';
  end if;
  if length(coalesce(p_frontend_commit,'')) not between 1 and 500
    or p_frontend_commit !~ '^[A-Za-z0-9][A-Za-z0-9._:@/-]*$' then
    raise exception 'FRONTEND_VERSION_INVALID';
  end if;

  select r.* into v_run
  from public.optimization_runs_v2 r
  where r.id=p_run_id;
  if v_run.id is null then raise exception 'RUN_NOT_FOUND'; end if;

  select s.snapshot,mv.version,mv.content_hash,
    mv.settings->>'strategySemanticsVersion'
  into v_snapshot,v_matrix_version,v_matrix_hash,v_semantics
  from solver_private.optimization_snapshots_v2 s
  join public.matrix_versions mv on mv.id=v_run.matrix_version_id
  where s.run_id=v_run.id;

  select * into v_build
  from solver_private.solver_runtime_builds_uat_v1 b
  where b.solver_version=v_run.solver_version;
  if v_build.solver_version is null then
    raise exception 'SOLVER_RUNTIME_PROVENANCE_MISSING';
  end if;
  v_strategy_hash:=solver_private.strategy_config_hash_uat_v1(v_snapshot);

  return jsonb_build_object(
    'schemaVersion',1,
    'frontendCommit',p_frontend_commit,
    'solverCommit',v_build.solver_commit,
    'solverImageDigest',v_build.solver_image_digest,
    'solverBuildId',v_build.solver_build_id,
    'gatewayVersion',null,
    'strategyConfigVersion',v_strategy_hash,
    'databaseMigrationVersion','20260824163743_uat_northflank_job_runtime',
    'snapshotSchemaVersion',v_run.snapshot_schema_version,
    'executionMode',p_execution_mode,
    'northflankRunId',null,
    'dispatcherVersion',null,
    -- Retain the B4F-166 nested envelope for backward-compatible UI readers.
    'frontend',jsonb_build_object('buildId',p_frontend_commit),
    'solver',jsonb_build_object(
      'configuredVersion',v_run.solver_version,
      'commit',v_build.solver_commit,
      'buildId',v_build.solver_build_id,
      'imageDigest',v_build.solver_image_digest
    ),
    'gateway',jsonb_build_object('deploymentId',null),
    'database',jsonb_build_object(
      'schemaVersion','20260824163743_uat_northflank_job_runtime'
    ),
    'strategyConfig',jsonb_build_object(
      'matrixVersionId',v_run.matrix_version_id,
      'matrixVersion',v_matrix_version,
      'contentHash',v_matrix_hash,
      'strategySemanticsVersion',v_semantics,
      'snapshotHash',v_strategy_hash
    ),
    'snapshot',jsonb_build_object(
      'schemaVersion',v_run.snapshot_schema_version,
      'snapshotHash',v_run.snapshot_hash
    )
  );
end;
$$;

revoke all on function solver_private.build_run_version_stamp_uat_v1(
  uuid,text,text
) from public,anon,authenticated,service_role;

create or replace function solver_private.enforce_run_version_stamp_uat_v1()
returns trigger
language plpgsql
set search_path=''
as $$
declare
  v_key text;
  v_old jsonb;
  v_new jsonb;
begin
  if new.version_stamp is null or jsonb_typeof(new.version_stamp)<>'object' then
    raise exception 'VERSION_STAMP_INVALID';
  end if;
  if tg_op='UPDATE' then
    foreach v_key in array array[
      'schemaVersion','frontendCommit','solverCommit','solverImageDigest','solverBuildId',
      'gatewayVersion','strategyConfigVersion','databaseMigrationVersion',
      'snapshotSchemaVersion','executionMode','northflankRunId',
      'dispatcherVersion'
    ] loop
      v_old:=old.version_stamp->v_key;
      v_new:=new.version_stamp->v_key;
      if v_old is not null and v_old<>'null'::jsonb
        and v_new is distinct from v_old then
        raise exception 'VERSION_STAMP_IMMUTABLE_%',upper(v_key);
      end if;
    end loop;
  end if;

  if new.version_stamp ? 'executionMode' then
    if coalesce((new.version_stamp->>'schemaVersion')::integer,0)<>1
      or new.version_stamp->>'executionMode' not in ('SERVICE','JOB')
      or coalesce(new.version_stamp->>'frontendCommit','')=''
      or coalesce(new.version_stamp->>'solverCommit','') !~ '^[0-9a-f]{40}$'
      or coalesce(new.version_stamp->>'solverBuildId','')=''
      or coalesce(new.version_stamp->>'strategyConfigVersion','')
        !~ '^[0-9a-f]{64}$'
      or coalesce(new.version_stamp->>'databaseMigrationVersion','')=''
      or coalesce((new.version_stamp->>'snapshotSchemaVersion')::integer,0)<=0
    then raise exception 'VERSION_STAMP_INCOMPLETE'; end if;
  end if;
  return new;
end;
$$;

revoke all on function solver_private.enforce_run_version_stamp_uat_v1()
  from public,anon,authenticated,service_role;

-- Replace the seven-argument request boundary while retaining its exact public
-- signature. The original function remains private and is called in the same
-- transaction, so snapshot creation, schedule locking and outbox creation are
-- atomic.
alter function public.optimizer_request_v2(
  date,uuid,text,uuid,text,text,text
) rename to optimizer_request_before_nfjob_uat_v1;

revoke all on function public.optimizer_request_before_nfjob_uat_v1(
  date,uuid,text,uuid,text,text,text
) from public,anon,authenticated,service_role;

create or replace function solver_private.optimizer_request_stamped_uat_v1(
  p_month date,
  p_scenario_id uuid,
  p_scope_type text,
  p_scope_role_id uuid,
  p_name text,
  p_idempotency_key text,
  p_frontend_version text,
  p_execution_mode text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_result jsonb;
  v_run_id uuid;
  v_run public.optimization_runs_v2%rowtype;
  v_stamp jsonb;
  v_user_id uuid:=auth.uid();
  v_quota integer;
begin
  if v_user_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_execution_mode not in ('SERVICE','JOB') then
    raise exception 'EXECUTION_MODE_INVALID';
  end if;

  select c.generation_quota_per_user_hour into v_quota
  from solver_private.solver_job_runtime_config_uat_v1 c where c.singleton;
  if not exists(
      select 1 from public.optimization_runs_v2 r
      where r.requested_by=v_user_id and r.idempotency_key=p_idempotency_key
    ) and (
      select count(*) from public.optimization_runs_v2 r
      where r.requested_by=v_user_id
        and r.created_at>=now()-interval '1 hour'
    )>=v_quota
  then raise exception 'GENERATION_QUOTA_HARD_STOP'; end if;

  v_result:=public.optimizer_request_before_nfjob_uat_v1(
    p_month,p_scenario_id,p_scope_type,p_scope_role_id,p_name,
    p_idempotency_key,p_frontend_version
  );
  v_run_id:=nullif(v_result#>>'{run,id}','')::uuid;
  if v_run_id is null then raise exception 'RUN_ID_MISSING'; end if;

  select * into v_run from public.optimization_runs_v2 where id=v_run_id;
  perform pg_advisory_xact_lock(hashtextextended(
    v_run.matrix_version_id::text||'|'||v_run.month::text||'|'||
    v_run.scope_type||'|'||coalesce(v_run.scope_role_id::text,'COMPANY'),0
  ));
  if exists(
    select 1 from public.optimization_runs_v2 other
    where other.id<>v_run.id
      and other.matrix_version_id=v_run.matrix_version_id
      and other.month=v_run.month
      and other.scope_type=v_run.scope_type
      and other.scope_role_id is not distinct from v_run.scope_role_id
      and other.status in ('QUEUED','RUNNING','VALIDATING','CANCEL_REQUESTED')
  ) then raise exception 'SCHEDULE_GENERATION_ACTIVE'; end if;

  v_stamp:=solver_private.build_run_version_stamp_uat_v1(
    v_run_id,p_frontend_version,p_execution_mode
  );
  update public.optimization_runs_v2
  set version_stamp=v_stamp,updated_at=now()
  where id=v_run_id;
  return jsonb_set(v_result,'{versionStamp}',v_stamp,true);
end;
$$;

revoke all on function solver_private.optimizer_request_stamped_uat_v1(
  date,uuid,text,uuid,text,text,text,text
) from public,anon,authenticated,service_role;

create function public.optimizer_request_v2(
  p_month date,
  p_scenario_id uuid,
  p_scope_type text,
  p_scope_role_id uuid,
  p_name text,
  p_idempotency_key text,
  p_frontend_version text
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select solver_private.optimizer_request_stamped_uat_v1(
    p_month,p_scenario_id,p_scope_type,p_scope_role_id,p_name,
    p_idempotency_key,p_frontend_version,'SERVICE'
  )
$$;

revoke all on function public.optimizer_request_v2(
  date,uuid,text,uuid,text,text,text
) from public,anon,authenticated,service_role;
grant execute on function public.optimizer_request_v2(
  date,uuid,text,uuid,text,text,text
) to authenticated;

create or replace function public.optimizer_request_job_uat_v1(
  p_month date,
  p_scenario_id uuid,
  p_scope_type text,
  p_scope_role_id uuid,
  p_name text,
  p_idempotency_key text,
  p_frontend_version text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_result jsonb;
  v_run public.optimization_runs_v2%rowtype;
  v_config solver_private.solver_job_runtime_config_uat_v1%rowtype;
begin
  v_result:=solver_private.optimizer_request_stamped_uat_v1(
    p_month,p_scenario_id,p_scope_type,p_scope_role_id,p_name,
    p_idempotency_key,p_frontend_version,'JOB'
  );
  select * into v_run from public.optimization_runs_v2
  where id=nullif(v_result#>>'{run,id}','')::uuid for update;
  if v_run.id is null then raise exception 'RUN_ID_MISSING'; end if;
  select * into v_config
  from solver_private.solver_job_runtime_config_uat_v1 where singleton;

  if v_run.queue_message_id is not null then
    perform pgmq.archive('schedule_optimizer_v2',v_run.queue_message_id);
  end if;
  update public.optimization_runs_v2
  set queue_message_id=null,phase='DISPATCH_PENDING',updated_at=now()
  where id=v_run.id;

  insert into solver_private.solver_job_dispatch_outbox_uat_v1(
    run_id,organization_key,month,scope_type,scope_role_id,requested_at,
    configured_plan,configured_vcpu,configured_ram_mb,estimated_usd_per_hour
  ) values(
    v_run.id,v_run.matrix_version_id,v_run.month,v_run.scope_type,
    v_run.scope_role_id,v_run.queued_at,v_config.deployment_plan,
    v_config.configured_vcpu,v_config.configured_ram_mb,
    v_config.estimated_usd_per_hour
  ) on conflict(run_id) do nothing;

  return v_result||jsonb_build_object(
    'executionMode','JOB','dispatchStatus','PENDING'
  );
exception
  when unique_violation then
    raise exception 'SCHEDULE_GENERATION_ACTIVE';
end;
$$;

revoke all on function public.optimizer_request_job_uat_v1(
  date,uuid,text,uuid,text,text,text
) from public,anon,authenticated,service_role;
grant execute on function public.optimizer_request_job_uat_v1(
  date,uuid,text,uuid,text,text,text
) to authenticated;

create trigger optimization_runs_v2_version_stamp_immutable_uat_v1
before update of version_stamp on public.optimization_runs_v2
for each row execute function solver_private.enforce_run_version_stamp_uat_v1();

create trigger plan_variants_v2_version_stamp_immutable_uat_v1
before update of version_stamp on public.plan_variants_v2
for each row execute function solver_private.enforce_run_version_stamp_uat_v1();

create or replace function public.solver_job_dispatcher_control_uat_v1(
  p_enabled boolean
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
begin
  update solver_private.solver_job_runtime_config_uat_v1
  set dispatcher_enabled=coalesce(p_enabled,false),updated_at=now()
  where singleton;
  return jsonb_build_object(
    'dispatcherEnabled',coalesce(p_enabled,false),
    'defaultExecutionMode','SERVICE'
  );
end;
$$;

revoke all on function public.solver_job_dispatcher_control_uat_v1(boolean)
  from public,anon,authenticated,service_role;
grant execute on function public.solver_job_dispatcher_control_uat_v1(boolean)
  to service_role;

create or replace function public.solver_dispatch_reserve_uat_v1(
  p_dispatcher_version text,
  p_lease_seconds integer default 60
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_config solver_private.solver_job_runtime_config_uat_v1%rowtype;
  v_item solver_private.solver_job_dispatch_outbox_uat_v1%rowtype;
  v_run public.optimization_runs_v2%rowtype;
  v_active integer;
  v_lease_token uuid:=gen_random_uuid();
  v_stamp jsonb;
begin
  if length(coalesce(p_dispatcher_version,'')) not between 1 and 500
    or p_dispatcher_version !~ '^[A-Za-z0-9][A-Za-z0-9._:@/-]*$' then
    raise exception 'DISPATCHER_VERSION_INVALID';
  end if;
  if coalesce(p_lease_seconds,0) not between 15 and 300 then
    raise exception 'DISPATCH_LEASE_INVALID';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('solver-job-dispatch-uat-v1',0));
  select * into v_config
  from solver_private.solver_job_runtime_config_uat_v1
  where singleton for update;
  if not v_config.dispatcher_enabled then
    return jsonb_build_object('reserved',false,'status','DISABLED');
  end if;

  select count(*) into v_active
  from solver_private.solver_job_dispatch_outbox_uat_v1 o
  where o.dispatch_status in (
    'DISPATCHING','ACCEPTANCE_UNKNOWN','ACCEPTED','STARTING','RUNNING'
  );
  if v_active>=v_config.global_active_jobs then
    return jsonb_build_object('reserved',false,'status','GLOBAL_LIMIT');
  end if;

  select candidate.* into v_item
  from solver_private.solver_job_dispatch_outbox_uat_v1 candidate
  join public.optimization_runs_v2 r on r.id=candidate.run_id
  where candidate.dispatch_status='PENDING'
    and candidate.next_dispatch_at<=now()
    and r.status='QUEUED'
    and not exists(
      select 1
      from solver_private.solver_job_dispatch_outbox_uat_v1 active
      where active.run_id<>candidate.run_id
        and active.organization_key=candidate.organization_key
        and active.dispatch_status in (
          'DISPATCHING','ACCEPTANCE_UNKNOWN','ACCEPTED','STARTING','RUNNING'
        )
    )
    and not exists(
      select 1
      from solver_private.solver_job_dispatch_outbox_uat_v1 active
      where active.run_id<>candidate.run_id
        and active.organization_key=candidate.organization_key
        and active.month=candidate.month
        and active.scope_type=candidate.scope_type
        and active.scope_role_id is not distinct from candidate.scope_role_id
        and active.dispatch_status in (
          'DISPATCHING','ACCEPTANCE_UNKNOWN','ACCEPTED','STARTING','RUNNING'
        )
    )
  order by candidate.requested_at,candidate.run_id
  for update of candidate skip locked
  limit 1;

  if v_item.run_id is null then
    return jsonb_build_object('reserved',false,'status','ORGANIZATION_LIMIT');
  end if;
  select * into v_run from public.optimization_runs_v2
  where id=v_item.run_id for update;

  v_stamp:=solver_private.version_stamp_set_once_uat_v1(
    v_run.version_stamp,'dispatcherVersion',to_jsonb(p_dispatcher_version)
  );
  update public.optimization_runs_v2
  set phase='DISPATCHING',version_stamp=v_stamp,updated_at=now()
  where id=v_run.id;
  update solver_private.solver_job_dispatch_outbox_uat_v1
  set dispatch_status='DISPATCHING',
      dispatch_attempt=dispatch_attempt+1,
      dispatch_started_at=now(),
      dispatcher_lease_token=v_lease_token,
      dispatcher_lease_expires_at=now()+make_interval(secs=>p_lease_seconds),
      dispatcher_version=p_dispatcher_version,
      last_http_status=null,last_error_code=null,last_error=null,
      updated_at=now()
  where run_id=v_item.run_id;

  return jsonb_build_object(
    'reserved',true,
    'status','DISPATCHING',
    'runId',v_item.run_id,
    'dispatchNonce',v_item.dispatch_nonce,
    'dispatchLeaseToken',v_lease_token,
    'dispatchAttempt',v_item.dispatch_attempt+1,
    'solverVersion',v_run.solver_version,
    'solverCommit',v_stamp->>'solverCommit',
    'solverBuildId',v_stamp->>'solverBuildId',
    'strategyConfigVersion',v_stamp->>'strategyConfigVersion',
    'configuredPlan',v_item.configured_plan,
    'configuredVcpu',v_item.configured_vcpu,
    'configuredRamMb',v_item.configured_ram_mb,
    'wallTimeoutSeconds',v_config.wall_timeout_seconds
  );
end;
$$;

revoke all on function public.solver_dispatch_reserve_uat_v1(text,integer)
  from public,anon,authenticated,service_role;
grant execute on function public.solver_dispatch_reserve_uat_v1(text,integer)
  to service_role;

create or replace function public.solver_dispatch_result_uat_v1(
  p_run_id uuid,
  p_dispatch_lease_token uuid,
  p_outcome text,
  p_northflank_run_id text default null,
  p_http_status integer default null,
  p_error_code text default null,
  p_error_message text default null
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_item solver_private.solver_job_dispatch_outbox_uat_v1%rowtype;
  v_run public.optimization_runs_v2%rowtype;
  v_stamp jsonb;
  v_delay integer;
begin
  if p_outcome not in (
    'ACCEPTED','RETRYABLE_REJECTED','ACCEPTANCE_UNKNOWN','PERMANENT_FAILURE'
  ) then raise exception 'DISPATCH_OUTCOME_INVALID'; end if;
  select * into v_item
  from solver_private.solver_job_dispatch_outbox_uat_v1
  where run_id=p_run_id for update;
  if v_item.run_id is null then raise exception 'DISPATCH_NOT_FOUND'; end if;
  if v_item.dispatch_status<>'DISPATCHING'
    or v_item.dispatcher_lease_token is distinct from p_dispatch_lease_token
    or v_item.dispatcher_lease_expires_at<now() then
    raise exception 'DISPATCH_LEASE_LOST';
  end if;
  select * into v_run from public.optimization_runs_v2
  where id=p_run_id for update;

  if p_outcome='ACCEPTED' then
    if length(coalesce(p_northflank_run_id,'')) not between 1 and 200 then
      raise exception 'NORTHFLANK_RUN_ID_INVALID';
    end if;
    v_stamp:=solver_private.version_stamp_set_once_uat_v1(
      v_run.version_stamp,'northflankRunId',to_jsonb(p_northflank_run_id)
    );
    update public.optimization_runs_v2
    set phase='STARTING',version_stamp=v_stamp,updated_at=now()
    where id=p_run_id;
    update solver_private.solver_job_dispatch_outbox_uat_v1
    set dispatch_status='ACCEPTED',
        northflank_run_id=p_northflank_run_id,
        northflank_accepted_at=now(),
        dispatcher_lease_token=null,dispatcher_lease_expires_at=null,
        last_http_status=p_http_status,last_error_code=null,last_error=null,
        updated_at=now()
    where run_id=p_run_id;
  elsif p_outcome='RETRYABLE_REJECTED' then
    v_delay:=least(300,15*(2^least(v_item.dispatch_attempt-1,4))::integer);
    update public.optimization_runs_v2
    set phase='DISPATCH_PENDING',updated_at=now()
    where id=p_run_id;
    update solver_private.solver_job_dispatch_outbox_uat_v1
    set dispatch_status='PENDING',next_dispatch_at=now()+make_interval(secs=>v_delay),
        dispatcher_lease_token=null,dispatcher_lease_expires_at=null,
        last_http_status=p_http_status,last_error_code=left(p_error_code,100),
        last_error=left(p_error_message,1000),updated_at=now()
    where run_id=p_run_id;
  elsif p_outcome='ACCEPTANCE_UNKNOWN' then
    update public.optimization_runs_v2
    set phase='DISPATCH_UNCERTAIN',updated_at=now()
    where id=p_run_id;
    update solver_private.solver_job_dispatch_outbox_uat_v1
    set dispatch_status='ACCEPTANCE_UNKNOWN',
        dispatcher_lease_token=null,dispatcher_lease_expires_at=null,
        last_http_status=p_http_status,
        last_error_code=coalesce(left(p_error_code,100),'NORTHFLANK_ACCEPTANCE_UNKNOWN'),
        last_error=left(p_error_message,1000),updated_at=now()
    where run_id=p_run_id;
  else
    update public.optimization_runs_v2
    set status='FAILED',phase='FAILED',progress=0,
        failure_code=coalesce(left(p_error_code,100),'DISPATCH_FAILED'),
        failure_message='Nie udało się uruchomić zadania generatora.',
        finished_at=now(),updated_at=now()
    where id=p_run_id and status='QUEUED';
    update public.optimization_run_strategies_v2
    set status='FAILED',phase='FAILED',progress=0,
        failure_code=coalesce(left(p_error_code,100),'DISPATCH_FAILED'),
        finished_at=now(),updated_at=now()
    where run_id=p_run_id and status='QUEUED';
    update solver_private.solver_job_dispatch_outbox_uat_v1
    set dispatch_status='FAILED',
        dispatcher_lease_token=null,dispatcher_lease_expires_at=null,
        last_http_status=p_http_status,
        last_error_code=coalesce(left(p_error_code,100),'DISPATCH_FAILED'),
        last_error=left(p_error_message,1000),job_finished_at=now(),updated_at=now()
    where run_id=p_run_id;
  end if;
  return jsonb_build_object('runId',p_run_id,'outcome',p_outcome);
end;
$$;

revoke all on function public.solver_dispatch_result_uat_v1(
  uuid,uuid,text,text,integer,text,text
) from public,anon,authenticated,service_role;
grant execute on function public.solver_dispatch_result_uat_v1(
  uuid,uuid,text,text,integer,text,text
) to service_role;

create or replace function public.solver_claim_run_v2(
  p_target_run_id uuid,
  p_dispatch_nonce uuid,
  p_worker_id text,
  p_worker_version text,
  p_task_attempt integer,
  p_lease_seconds integer,
  p_gateway_version text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_run public.optimization_runs_v2%rowtype;
  v_outbox solver_private.solver_job_dispatch_outbox_uat_v1%rowtype;
  v_attempt_id uuid;
  v_lease_token uuid;
  v_attempt_number integer;
  v_lease_expires_at timestamptz;
  v_execution_name text;
  v_stamp jsonb;
begin
  if length(trim(coalesce(p_worker_id,''))) not between 3 and 200
    or trim(p_worker_id) !~ '^[A-Za-z0-9._:@/-]+$' then
    raise exception 'INVALID_WORKER_ID';
  end if;
  if length(trim(coalesce(p_worker_version,''))) not between 1 and 200
    or trim(p_worker_version) !~ '^[A-Za-z0-9._:+/-]+$' then
    raise exception 'INVALID_WORKER_VERSION';
  end if;
  if coalesce(p_task_attempt,0) not between 1 and 20 then
    raise exception 'INVALID_TASK_ATTEMPT';
  end if;
  if coalesce(p_lease_seconds,0) not between 30 and 900 then
    raise exception 'INVALID_LEASE_SECONDS';
  end if;
  if length(coalesce(p_gateway_version,'')) not between 1 and 500
    or p_gateway_version !~ '^[A-Za-z0-9][A-Za-z0-9._:@/-]*$' then
    raise exception 'GATEWAY_VERSION_INVALID';
  end if;

  perform solver_private.lock_planning_revision_v2();
  select * into v_outbox
  from solver_private.solver_job_dispatch_outbox_uat_v1
  where run_id=p_target_run_id for update;
  if v_outbox.run_id is null then
    return jsonb_build_object('claimed',false,'status','TARGET_NOT_FOUND');
  end if;
  if v_outbox.dispatch_nonce is distinct from p_dispatch_nonce then
    raise exception 'TARGET_CAPABILITY_INVALID';
  end if;
  select * into v_run from public.optimization_runs_v2
  where id=p_target_run_id for update;
  if v_run.id is null then
    return jsonb_build_object('claimed',false,'status','TARGET_NOT_FOUND');
  end if;
  if v_run.status in ('READY','FAILED','CANCELLED','STALE_INPUT') then
    return jsonb_build_object(
      'claimed',false,'status','TARGET_TERMINAL','runStatus',v_run.status
    );
  end if;
  if v_outbox.dispatch_status not in (
    'ACCEPTANCE_UNKNOWN','ACCEPTED','STARTING','RUNNING'
  ) then
    return jsonb_build_object('claimed',false,'status','TARGET_NOT_DISPATCHED');
  end if;
  if v_run.status='RUNNING' and v_run.lease_expires_at>now() then
    return jsonb_build_object('claimed',false,'status','CONFLICT');
  end if;
  if v_run.solver_version is distinct from trim(p_worker_version) then
    return jsonb_build_object('claimed',false,'status','VERSION_MISMATCH');
  end if;
  if v_run.status='CANCEL_REQUESTED' then
    if v_run.queue_message_id is not null then
      perform pgmq.archive('schedule_optimizer_v2',v_run.queue_message_id);
    end if;
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
    update solver_private.solver_job_dispatch_outbox_uat_v1
    set dispatch_status='CANCELLED',job_finished_at=now(),updated_at=now()
    where run_id=v_run.id;
    return jsonb_build_object('claimed',false,'status','CANCELLED');
  end if;
  if v_run.attempt_count>=v_run.max_attempts then
    update public.optimization_runs_v2
    set status='FAILED',phase='FAILED',failure_code='MAX_ATTEMPTS',
      failure_message='Przekroczono limit prób solvera.',
      finished_at=now(),updated_at=now()
    where id=v_run.id;
    update solver_private.solver_job_dispatch_outbox_uat_v1
    set dispatch_status='FAILED',last_error_code='MAX_ATTEMPTS',
      job_finished_at=now(),updated_at=now()
    where run_id=v_run.id;
    return jsonb_build_object('claimed',false,'status','MAX_ATTEMPTS');
  end if;

  if v_run.queue_message_id is not null then
    perform pgmq.archive('schedule_optimizer_v2',v_run.queue_message_id);
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
    'northflank-job/'||trim(p_worker_id)||'/'||v_run.id::text||'/'||
      v_attempt_number::text,500
  );
  insert into solver_private.optimization_attempts_v2(
    id,run_id,attempt_number,task_attempt,worker_id,worker_version,
    worker_execution_name,lease_token,status
  ) values(
    v_attempt_id,v_run.id,v_attempt_number,p_task_attempt,trim(p_worker_id),
    trim(p_worker_version),v_execution_name,v_lease_token,'RUNNING'
  );

  v_stamp:=solver_private.version_stamp_set_once_uat_v1(
    v_run.version_stamp,'gatewayVersion',to_jsonb(p_gateway_version)
  );
  v_stamp:=jsonb_set(
    v_stamp,'{gateway}',jsonb_build_object('deploymentId',p_gateway_version),true
  );
  update public.optimization_runs_v2
  set status='RUNNING',phase='CLAIMED',progress=greatest(progress,1),
    attempt_count=v_attempt_number,queue_message_id=null,
    lease_owner=trim(p_worker_id),lease_token=v_lease_token,
    lease_expires_at=v_lease_expires_at,
    worker_execution_name=v_execution_name,heartbeat_at=now(),
    started_at=coalesce(started_at,now()),finished_at=null,
    failure_code=null,failure_message=null,version_stamp=v_stamp,updated_at=now()
  where id=v_run.id;
  update public.optimization_run_strategies_v2
  set status='RUNNING',phase='CLAIMED',progress=1,metrics='{}'::jsonb,
    started_at=coalesce(started_at,now()),finished_at=null,
    failure_code=null,updated_at=now()
  where run_id=v_run.id;
  update solver_private.solver_job_dispatch_outbox_uat_v1
  set dispatch_status='RUNNING',
    container_started_at=coalesce(container_started_at,now()),
    worker_claimed_at=coalesce(worker_claimed_at,now()),updated_at=now()
  where run_id=v_run.id;

  return jsonb_build_object(
    'claimed',true,'runId',v_run.id,'attemptId',v_attempt_id,
    'attemptNumber',v_attempt_number,'leaseToken',v_lease_token,
    'leaseExpiresAt',v_lease_expires_at,'snapshotHash',v_run.snapshot_hash,
    'solverVersion',v_run.solver_version,'executionMode','JOB'
  );
end;
$$;

revoke all on function public.solver_claim_run_v2(
  uuid,uuid,text,text,integer,integer,text
) from public,anon,authenticated,service_role;
grant execute on function public.solver_claim_run_v2(
  uuid,uuid,text,text,integer,integer,text
) to service_role;

-- B4F-166 is the point where the full legacy stamp is assembled. Replace only
-- this private predecessor so every later wrapper keeps the new flat immutable
-- fields while retaining the existing validator and materializer chain.
create or replace function public.solver_save_variant_before_b4f168(
  p_run_id uuid,
  p_attempt_id uuid,
  p_lease_token uuid,
  p_variant jsonb,
  p_gateway_version text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_result jsonb;
  v_variant_id uuid;
  v_frontend_version text;
  v_solver_version text;
  v_snapshot_schema_version integer;
  v_snapshot_hash text;
  v_matrix_version_id uuid;
  v_matrix_version integer;
  v_matrix_content_hash text;
  v_strategy_semantics_version text;
  v_worker_id text;
  v_worker_version text;
  v_worker_execution_name text;
  v_version_stamp jsonb;
  v_existing_stamp jsonb;
begin
  if length(coalesce(p_gateway_version,'')) not between 1 and 500
    or p_gateway_version !~ '^[A-Za-z0-9][A-Za-z0-9._:@/-]*$' then
    raise exception 'GATEWAY_VERSION_INVALID';
  end if;
  perform solver_private.validate_stage_proof_b4f166(p_variant->'stageObjectives');

  select
    r.version_stamp#>>'{frontend,buildId}',r.solver_version,
    r.snapshot_schema_version,r.snapshot_hash,r.matrix_version_id,
    mv.version,mv.content_hash,mv.settings->>'strategySemanticsVersion',
    a.worker_id,a.worker_version,a.worker_execution_name,r.version_stamp
  into
    v_frontend_version,v_solver_version,v_snapshot_schema_version,
    v_snapshot_hash,v_matrix_version_id,v_matrix_version,
    v_matrix_content_hash,v_strategy_semantics_version,v_worker_id,
    v_worker_version,v_worker_execution_name,v_existing_stamp
  from public.optimization_runs_v2 r
  join solver_private.optimization_attempts_v2 a
    on a.id=p_attempt_id and a.run_id=r.id
  join public.matrix_versions mv on mv.id=r.matrix_version_id
  where r.id=p_run_id;

  if v_frontend_version is null then
    raise exception 'FRONTEND_VERSION_STAMP_MISSING';
  end if;
  if v_solver_version is null or v_worker_version is null
    or v_matrix_content_hash is null or v_strategy_semantics_version is null then
    raise exception 'RUNTIME_VERSION_STAMP_INCOMPLETE';
  end if;
  if not coalesce(v_existing_stamp,'{}'::jsonb) ? 'executionMode' then
    v_existing_stamp:=solver_private.build_run_version_stamp_uat_v1(
      p_run_id,v_frontend_version,'SERVICE'
    )||coalesce(v_existing_stamp,'{}'::jsonb);
  end if;

  v_version_stamp:=v_existing_stamp||jsonb_build_object(
    'frontend',jsonb_build_object('buildId',v_frontend_version),
    'solver',jsonb_strip_nulls(jsonb_build_object(
      'configuredVersion',v_solver_version,
      'workerVersion',v_worker_version,
      'workerId',v_worker_id,
      'workerExecutionName',v_worker_execution_name,
      'commit',v_existing_stamp->>'solverCommit',
      'buildId',v_existing_stamp->>'solverBuildId',
      'imageDigest',v_existing_stamp->'solverImageDigest'
    )),
    'gateway',jsonb_build_object('deploymentId',p_gateway_version),
    'database',jsonb_build_object(
      'schemaVersion','20260824163743_uat_northflank_job_runtime'
    ),
    'strategyConfig',jsonb_build_object(
      'matrixVersionId',v_matrix_version_id,
      'matrixVersion',v_matrix_version,
      'contentHash',v_matrix_content_hash,
      'strategySemanticsVersion',v_strategy_semantics_version,
      'snapshotHash',v_existing_stamp->>'strategyConfigVersion'
    ),
    'snapshot',jsonb_build_object(
      'schemaVersion',v_snapshot_schema_version,
      'snapshotHash',v_snapshot_hash
    )
  );
  v_version_stamp:=solver_private.version_stamp_set_once_uat_v1(
    v_version_stamp,'gatewayVersion',to_jsonb(p_gateway_version)
  );

  v_result:=public.solver_save_variant_v2(
    p_run_id,p_attempt_id,p_lease_token,p_variant
  );
  v_variant_id:=nullif(v_result->>'variantId','')::uuid;
  if v_variant_id is null then raise exception 'VARIANT_ID_MISSING'; end if;

  update public.plan_variants_v2 v
  set stage_proof=p_variant->'stageObjectives',version_stamp=v_version_stamp
  where v.id=v_variant_id and v.run_id=p_run_id;
  if not found then raise exception 'VARIANT_NOT_FOUND'; end if;
  update public.optimization_runs_v2 r
  set version_stamp=v_version_stamp,updated_at=now()
  where r.id=p_run_id;

  return v_result||jsonb_build_object(
    'stageCount',jsonb_array_length(p_variant->'stageObjectives'),
    'versionStamp',v_version_stamp
  );
end;
$$;

revoke all on function public.solver_save_variant_before_b4f168(
  uuid,uuid,uuid,jsonb,text
) from public,anon,authenticated,service_role;

alter function public.solver_save_variant_v2(
  uuid,uuid,uuid,jsonb,text
) rename to solver_save_variant_before_nfjob_uat_v1;

revoke all on function public.solver_save_variant_before_nfjob_uat_v1(
  uuid,uuid,uuid,jsonb,text
) from public,anon,authenticated,service_role;

create function public.solver_save_variant_v2(
  p_run_id uuid,
  p_attempt_id uuid,
  p_lease_token uuid,
  p_variant jsonb,
  p_gateway_version text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare v_result jsonb;
begin
  v_result:=public.solver_save_variant_before_nfjob_uat_v1(
    p_run_id,p_attempt_id,p_lease_token,p_variant,p_gateway_version
  );
  update solver_private.solver_job_dispatch_outbox_uat_v1
  set solver_finished_at=coalesce(solver_finished_at,now()),
      result_saved_at=now(),updated_at=now()
  where run_id=p_run_id;
  return v_result;
end;
$$;

revoke all on function public.solver_save_variant_v2(
  uuid,uuid,uuid,jsonb,text
) from public,anon,authenticated,service_role;
grant execute on function public.solver_save_variant_v2(
  uuid,uuid,uuid,jsonb,text
) to service_role;

alter function public.solver_heartbeat_v2(uuid,uuid,uuid,jsonb)
  rename to solver_heartbeat_before_nfjob_uat_v1;
revoke all on function public.solver_heartbeat_before_nfjob_uat_v1(
  uuid,uuid,uuid,jsonb
) from public,anon,authenticated,service_role;

create function public.solver_heartbeat_v2(
  p_run_id uuid,p_attempt_id uuid,p_lease_token uuid,p_progress jsonb
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare v_result jsonb; v_phase text:=upper(coalesce(p_progress->>'phase',''));
begin
  v_result:=public.solver_heartbeat_before_nfjob_uat_v1(
    p_run_id,p_attempt_id,p_lease_token,p_progress
  );
  update solver_private.solver_job_dispatch_outbox_uat_v1 o
  set dispatch_status='RUNNING',
      solver_started_at=case
        when v_phase='SOLVING' then coalesce(o.solver_started_at,now())
        else o.solver_started_at end,
      solver_finished_at=case
        when v_phase in ('VALIDATING','SAVING','FINALIZING')
          then coalesce(o.solver_finished_at,now())
        else o.solver_finished_at end,
      updated_at=now()
  from public.optimization_runs_v2 r
  where o.run_id=p_run_id and r.id=o.run_id
    and r.lease_token=p_lease_token;
  return v_result;
end;
$$;

revoke all on function public.solver_heartbeat_v2(uuid,uuid,uuid,jsonb)
  from public,anon,authenticated,service_role;
grant execute on function public.solver_heartbeat_v2(uuid,uuid,uuid,jsonb)
  to service_role;

alter function public.solver_finalize_v2(uuid,uuid,uuid)
  rename to solver_finalize_before_nfjob_uat_v1;
revoke all on function public.solver_finalize_before_nfjob_uat_v1(uuid,uuid,uuid)
  from public,anon,authenticated,service_role;

create function public.solver_finalize_v2(
  p_run_id uuid,p_attempt_id uuid,p_lease_token uuid
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare v_result jsonb; v_status text;
begin
  v_result:=public.solver_finalize_before_nfjob_uat_v1(
    p_run_id,p_attempt_id,p_lease_token
  );
  v_status:=upper(coalesce(v_result->>'status','READY'));
  update solver_private.solver_job_dispatch_outbox_uat_v1
  set dispatch_status=case
        when v_status='READY' then 'SUCCEEDED'
        when v_status='CANCELLED' then 'CANCELLED'
        else 'FAILED' end,
      solver_finished_at=coalesce(solver_finished_at,now()),
      result_saved_at=coalesce(result_saved_at,now()),
      ready_at=case when v_status='READY' then now() else ready_at end,
      last_error_code=case when v_status in ('READY','CANCELLED')
        then last_error_code else v_status end,
      updated_at=now()
  where run_id=p_run_id;
  return v_result;
end;
$$;

revoke all on function public.solver_finalize_v2(uuid,uuid,uuid)
  from public,anon,authenticated,service_role;
grant execute on function public.solver_finalize_v2(uuid,uuid,uuid)
  to service_role;

alter function public.solver_interrupt_v2(uuid,uuid,uuid,text)
  rename to solver_interrupt_before_nfjob_uat_v1;
revoke all on function public.solver_interrupt_before_nfjob_uat_v1(
  uuid,uuid,uuid,text
) from public,anon,authenticated,service_role;

create function public.solver_interrupt_v2(
  p_run_id uuid,p_attempt_id uuid,p_lease_token uuid,p_reason text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare v_result jsonb;
begin
  v_result:=public.solver_interrupt_before_nfjob_uat_v1(
    p_run_id,p_attempt_id,p_lease_token,p_reason
  );
  update solver_private.solver_job_dispatch_outbox_uat_v1
  set dispatch_status=case when p_reason='CANCEL_REQUESTED'
        then 'CANCELLED' else 'FAILED' end,
      last_error_code=left(p_reason,100),updated_at=now()
  where run_id=p_run_id;
  return v_result;
end;
$$;

revoke all on function public.solver_interrupt_v2(uuid,uuid,uuid,text)
  from public,anon,authenticated,service_role;
grant execute on function public.solver_interrupt_v2(uuid,uuid,uuid,text)
  to service_role;

alter function public.solver_fail_attempt_v2(uuid,uuid,uuid,text,text,boolean)
  rename to solver_fail_attempt_before_nfjob_uat_v1;
revoke all on function public.solver_fail_attempt_before_nfjob_uat_v1(
  uuid,uuid,uuid,text,text,boolean
) from public,anon,authenticated,service_role;

create function public.solver_fail_attempt_v2(
  p_run_id uuid,p_attempt_id uuid,p_lease_token uuid,
  p_error_code text,p_error_message text,p_retryable boolean
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_result jsonb;
  v_retryable boolean:=coalesce(p_retryable,false);
  v_queue_message_id bigint;
  v_is_job boolean;
begin
  select exists(
    select 1 from solver_private.solver_job_dispatch_outbox_uat_v1
    where run_id=p_run_id
  ) into v_is_job;
  if upper(coalesce(p_error_code,'')) in (
    'INVALID_SNAPSHOT','INVALID_VARIANT','OPTIMIZATION_ERROR',
    'OPTIMIZATION_INCOMPLETE','FAIRNESS_QUALITY_GATE_FAILED',
    'TENANT_MISMATCH','AUTH_FAILURE','PROBLEM_SIZE_EXCEEDED',
    'HARD_GUARDRAIL','JOB_WALL_TIMEOUT'
  ) then v_retryable:=false; end if;

  v_result:=public.solver_fail_attempt_before_nfjob_uat_v1(
    p_run_id,p_attempt_id,p_lease_token,p_error_code,p_error_message,v_retryable
  );
  if not v_is_job then return v_result; end if;

  if coalesce((v_result->>'retry')::boolean,false) then
    select queue_message_id into v_queue_message_id
    from public.optimization_runs_v2 where id=p_run_id for update;
    if v_queue_message_id is not null then
      perform pgmq.archive('schedule_optimizer_v2',v_queue_message_id);
    end if;
    update public.optimization_runs_v2
    set queue_message_id=null,phase='JOB_RETRY_WAIT',updated_at=now()
    where id=p_run_id;
    update solver_private.solver_job_dispatch_outbox_uat_v1
    set dispatch_status='RUNNING',solver_retry_count=solver_retry_count+1,
      last_error_code=left(p_error_code,100),
      last_error=left(p_error_message,1000),updated_at=now()
    where run_id=p_run_id;
  else
    update solver_private.solver_job_dispatch_outbox_uat_v1
    set dispatch_status=case
        when (select status from public.optimization_runs_v2 where id=p_run_id)
          ='CANCELLED' then 'CANCELLED' else 'FAILED' end,
      last_error_code=left(p_error_code,100),
      last_error=left(p_error_message,1000),updated_at=now()
    where run_id=p_run_id;
  end if;
  return v_result;
end;
$$;

revoke all on function public.solver_fail_attempt_v2(
  uuid,uuid,uuid,text,text,boolean
) from public,anon,authenticated,service_role;
grant execute on function public.solver_fail_attempt_v2(
  uuid,uuid,uuid,text,text,boolean
) to service_role;

alter function public.optimizer_request_cancel_v2(uuid)
  rename to optimizer_request_cancel_before_nfjob_uat_v1;
revoke all on function public.optimizer_request_cancel_before_nfjob_uat_v1(uuid)
  from public,anon,authenticated,service_role;

create function public.optimizer_request_cancel_v2(p_run_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare v_result jsonb; v_status text;
begin
  v_result:=public.optimizer_request_cancel_before_nfjob_uat_v1(p_run_id);
  select status into v_status from public.optimization_runs_v2 where id=p_run_id;
  update solver_private.solver_job_dispatch_outbox_uat_v1
  set dispatch_status=case when v_status='CANCELLED' then 'CANCELLED'
        else dispatch_status end,
      last_error_code='CANCEL_REQUESTED',
      job_finished_at=case when v_status='CANCELLED' then now()
        else job_finished_at end,
      updated_at=now()
  where run_id=p_run_id;
  return v_result;
end;
$$;

revoke all on function public.optimizer_request_cancel_v2(uuid)
  from public,anon,authenticated,service_role;
grant execute on function public.optimizer_request_cancel_v2(uuid)
  to authenticated;

create or replace function public.solver_job_reconcile_uat_v1(
  p_run_id uuid,
  p_northflank_run_id text,
  p_northflank_status text,
  p_container_started_at timestamptz default null,
  p_job_finished_at timestamptz default null,
  p_peak_rss_mb numeric default null,
  p_average_rss_mb numeric default null,
  p_peak_cpu_percent numeric default null,
  p_failure_code text default null
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_item solver_private.solver_job_dispatch_outbox_uat_v1%rowtype;
  v_run_status text;
  v_status text:=upper(coalesce(p_northflank_status,''));
  v_billable numeric;
begin
  if v_status not in ('QUEUED','PENDING','STARTING','RUNNING','SUCCESS','FAILED')
  then raise exception 'NORTHFLANK_STATUS_INVALID'; end if;
  select * into v_item
  from solver_private.solver_job_dispatch_outbox_uat_v1
  where run_id=p_run_id for update;
  if v_item.run_id is null then raise exception 'DISPATCH_NOT_FOUND'; end if;
  if v_item.northflank_run_id is distinct from p_northflank_run_id then
    raise exception 'NORTHFLANK_RUN_ID_MISMATCH';
  end if;
  if p_container_started_at>now()+interval '5 minutes'
    or (p_job_finished_at is not null and p_container_started_at is not null
      and p_job_finished_at<p_container_started_at) then
    raise exception 'NORTHFLANK_TIMESTAMPS_INVALID';
  end if;
  select status into v_run_status
  from public.optimization_runs_v2 where id=p_run_id for update;
  if p_container_started_at is not null then
    v_billable:=extract(epoch from (
      coalesce(p_job_finished_at,now())-p_container_started_at
    ));
  end if;

  update solver_private.solver_job_dispatch_outbox_uat_v1
  set dispatch_status=case
        when v_status in ('QUEUED','PENDING','STARTING')
          and worker_claimed_at is null then 'STARTING'
        when v_status='RUNNING' and worker_claimed_at is null then 'STARTING'
        when v_status='RUNNING' then 'RUNNING'
        when v_status='SUCCESS' and v_run_status='READY' then 'SUCCEEDED'
        when v_status='SUCCESS' and v_run_status='CANCELLED' then 'CANCELLED'
        when v_status='SUCCESS' then 'FAILED'
        else 'FAILED' end,
      container_started_at=coalesce(
        solver_job_dispatch_outbox_uat_v1.container_started_at,
        p_container_started_at
      ),
      job_finished_at=coalesce(p_job_finished_at,job_finished_at),
      peak_rss_mb=coalesce(p_peak_rss_mb,peak_rss_mb),
      average_rss_mb=coalesce(p_average_rss_mb,average_rss_mb),
      peak_cpu_percent=coalesce(p_peak_cpu_percent,peak_cpu_percent),
      billable_seconds=case when v_billable is null then billable_seconds
        else greatest(v_billable,0) end,
      estimated_compute_cost_usd=case when v_billable is null
        then estimated_compute_cost_usd
        else greatest(v_billable,0)/3600*estimated_usd_per_hour end,
      last_error_code=case
        when v_status='FAILED' then coalesce(left(p_failure_code,100),'JOB_RUNTIME_FAILED')
        when v_status='SUCCESS' and v_run_status<>'READY'
          then 'JOB_EXITED_WITHOUT_READY'
        else last_error_code end,
      updated_at=now()
  where run_id=p_run_id;

  if v_status='FAILED' and v_run_status not in (
    'READY','FAILED','CANCELLED','STALE_INPUT'
  ) then
    update public.optimization_runs_v2
    set status='FAILED',phase='FAILED',
      failure_code=coalesce(left(p_failure_code,100),'JOB_RUNTIME_FAILED'),
      failure_message='Zadanie generatora zakończyło się przed zapisaniem wyniku.',
      lease_owner=null,lease_token=null,lease_expires_at=null,
      worker_execution_name=null,finished_at=now(),updated_at=now()
    where id=p_run_id;
    update public.optimization_run_strategies_v2
    set status='FAILED',phase='FAILED',
      failure_code=coalesce(left(p_failure_code,100),'JOB_RUNTIME_FAILED'),
      finished_at=now(),updated_at=now()
    where run_id=p_run_id and status<>'READY';
  end if;
  return jsonb_build_object(
    'runId',p_run_id,'northflankStatus',v_status,
    'runStatus',(select status from public.optimization_runs_v2 where id=p_run_id)
  );
end;
$$;

revoke all on function public.solver_job_reconcile_uat_v1(
  uuid,text,text,timestamptz,timestamptz,numeric,numeric,numeric,text
) from public,anon,authenticated,service_role;
grant execute on function public.solver_job_reconcile_uat_v1(
  uuid,text,text,timestamptz,timestamptz,numeric,numeric,numeric,text
) to service_role;

create or replace function public.solver_job_watchdog_uat_v1()
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_config solver_private.solver_job_runtime_config_uat_v1%rowtype;
  v_result jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended('solver-job-watchdog-uat-v1',0));
  select * into v_config
  from solver_private.solver_job_runtime_config_uat_v1 where singleton;

  update solver_private.solver_job_dispatch_outbox_uat_v1 o
  set dispatch_status='ACCEPTANCE_UNKNOWN',
      dispatcher_lease_token=null,dispatcher_lease_expires_at=null,
      last_error_code='DISPATCH_LEASE_EXPIRED_UNKNOWN',
      last_error='Dispatcher utracił lease po rozpoczęciu wywołania Northflank; automatyczny ponowny POST jest zablokowany.',
      updated_at=now()
  where o.dispatch_status='DISPATCHING'
    and o.dispatcher_lease_expires_at<now();

  with expired as (
    select o.run_id,o.northflank_run_id,
      case
        when o.dispatch_status='ACCEPTANCE_UNKNOWN'
          and o.dispatch_started_at<now()-make_interval(secs=>v_config.wall_timeout_seconds)
          then 'DISPATCH_ACCEPTANCE_UNRESOLVED'
        when o.dispatch_status in ('ACCEPTED','STARTING')
          and o.worker_claimed_at is null
          and o.northflank_accepted_at<now()-make_interval(secs=>v_config.claim_watchdog_seconds)
          then 'JOB_CLAIM_TIMEOUT'
        when o.dispatch_status='RUNNING'
          and r.status='RUNNING'
          and r.heartbeat_at<now()-make_interval(secs=>v_config.heartbeat_watchdog_seconds)
          then 'JOB_HEARTBEAT_TIMEOUT'
        else null
      end as failure_code
    from solver_private.solver_job_dispatch_outbox_uat_v1 o
    join public.optimization_runs_v2 r on r.id=o.run_id
  ), failed as (
    update solver_private.solver_job_dispatch_outbox_uat_v1 o
    set dispatch_status='FAILED',last_error_code=e.failure_code,
      last_error='Watchdog zatrzymał przebieg po przekroczeniu limitu czasu.',
      job_finished_at=coalesce(job_finished_at,now()),updated_at=now()
    from expired e
    where o.run_id=e.run_id and e.failure_code is not null
    returning o.run_id,o.northflank_run_id,e.failure_code
  ), failed_runs as (
    update public.optimization_runs_v2 r
    set status='FAILED',phase='FAILED',failure_code=f.failure_code,
      failure_message='Zadanie generatora przekroczyło limit czasu uruchomienia lub heartbeat.',
      lease_owner=null,lease_token=null,lease_expires_at=null,
      worker_execution_name=null,finished_at=now(),updated_at=now()
    from failed f
    where r.id=f.run_id
      and r.status not in ('READY','FAILED','CANCELLED','STALE_INPUT')
    returning r.id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'runId',f.run_id,'northflankRunId',f.northflank_run_id,
    'failureCode',f.failure_code,'abortRequired',f.northflank_run_id is not null
  ) order by f.run_id),'[]'::jsonb)
  into v_result from failed f;
  return jsonb_build_object('expired',coalesce(v_result,'[]'::jsonb));
end;
$$;

revoke all on function public.solver_job_watchdog_uat_v1()
  from public,anon,authenticated,service_role;
grant execute on function public.solver_job_watchdog_uat_v1()
  to service_role;

create or replace function public.optimizer_job_status_uat_v1(p_run_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare v_item solver_private.solver_job_dispatch_outbox_uat_v1%rowtype;
begin
  if not solver_private.can_access_run_v2(p_run_id) then
    raise exception 'RUN_NOT_FOUND';
  end if;
  select * into v_item
  from solver_private.solver_job_dispatch_outbox_uat_v1 where run_id=p_run_id;
  if v_item.run_id is null then
    return jsonb_build_object('runId',p_run_id,'executionMode','SERVICE');
  end if;
  return jsonb_build_object(
    'runId',p_run_id,'executionMode','JOB',
    'dispatchStatus',v_item.dispatch_status,
    'dispatchAttempt',v_item.dispatch_attempt,
    'solverRetryCount',v_item.solver_retry_count,
    'northflankRunId',v_item.northflank_run_id,
    'requestedAt',v_item.requested_at,
    'dispatchStartedAt',v_item.dispatch_started_at,
    'northflankAcceptedAt',v_item.northflank_accepted_at,
    'containerStartedAt',v_item.container_started_at,
    'workerClaimedAt',v_item.worker_claimed_at,
    'solverStartedAt',v_item.solver_started_at,
    'solverFinishedAt',v_item.solver_finished_at,
    'resultSavedAt',v_item.result_saved_at,
    'readyAt',v_item.ready_at,
    'jobFinishedAt',v_item.job_finished_at,
    'configuredVcpu',v_item.configured_vcpu,
    'configuredRamMb',v_item.configured_ram_mb,
    'peakRssMb',v_item.peak_rss_mb,
    'averageRssMb',v_item.average_rss_mb,
    'peakCpuPercent',v_item.peak_cpu_percent,
    'billableSeconds',v_item.billable_seconds,
    'estimatedComputeCostUsd',v_item.estimated_compute_cost_usd,
    'lastErrorCode',v_item.last_error_code,
    'durationsMs',jsonb_build_object(
      'requestToDispatch',case when v_item.dispatch_started_at is null then null
        else round(extract(epoch from(v_item.dispatch_started_at-v_item.requested_at))*1000) end,
      'dispatchToAccept',case when v_item.northflank_accepted_at is null then null
        else round(extract(epoch from(v_item.northflank_accepted_at-v_item.dispatch_started_at))*1000) end,
      'acceptToContainer',case when v_item.container_started_at is null then null
        else round(extract(epoch from(v_item.container_started_at-v_item.northflank_accepted_at))*1000) end,
      'containerToClaim',case when v_item.worker_claimed_at is null then null
        else round(extract(epoch from(v_item.worker_claimed_at-v_item.container_started_at))*1000) end,
      'claimToSolver',case when v_item.solver_started_at is null then null
        else round(extract(epoch from(v_item.solver_started_at-v_item.worker_claimed_at))*1000) end,
      'solverRuntime',case when v_item.solver_finished_at is null then null
        else round(extract(epoch from(v_item.solver_finished_at-v_item.solver_started_at))*1000) end,
      'postprocess',case when v_item.result_saved_at is null then null
        else round(extract(epoch from(v_item.result_saved_at-v_item.solver_finished_at))*1000) end,
      'resultToReady',case when v_item.ready_at is null then null
        else round(extract(epoch from(v_item.ready_at-v_item.result_saved_at))*1000) end,
      'total',case when coalesce(v_item.job_finished_at,v_item.ready_at) is null then null
        else round(extract(epoch from(coalesce(v_item.job_finished_at,v_item.ready_at)-v_item.requested_at))*1000) end
    )
  );
end;
$$;

revoke all on function public.optimizer_job_status_uat_v1(uuid)
  from public,anon,authenticated,service_role;
grant execute on function public.optimizer_job_status_uat_v1(uuid)
  to authenticated;

create or replace function public.optimizer_generation_quota_uat_v1()
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare v_user uuid:=auth.uid(); v_count integer; v_limit integer;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  select generation_quota_per_user_hour into v_limit
  from solver_private.solver_job_runtime_config_uat_v1 where singleton;
  select count(*) into v_count from public.optimization_runs_v2
  where requested_by=v_user and created_at>=now()-interval '1 hour';
  return jsonb_build_object(
    'requestsLastHour',v_count,'limit',v_limit,
    'level',case
      when v_count>=v_limit then 'HARD_STOP'
      when v_count>=greatest(v_limit-3,1) then 'ANOMALY'
      when v_count>=ceil(v_limit*0.60) then 'WARNING'
      else 'NORMAL' end
  );
end;
$$;

revoke all on function public.optimizer_generation_quota_uat_v1()
  from public,anon,authenticated,service_role;
grant execute on function public.optimizer_generation_quota_uat_v1()
  to authenticated;

create or replace function public.solver_contract_parity_probe_uat_v1(
  p_variant_templates jsonb,
  p_gateway_version text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_source_run public.optimization_runs_v2%rowtype;
  v_source_snapshot jsonb;
  v_snapshot jsonb;
  v_snapshot_hash text;
  v_solution_hash text;
  v_run_id uuid:=gen_random_uuid();
  v_attempt_id uuid:=gen_random_uuid();
  v_lease_token uuid:=gen_random_uuid();
  v_strategy jsonb;
  v_template jsonb;
  v_variant jsonb;
  v_results jsonb:='[]'::jsonb;
  v_saved jsonb;
  v_index integer:=0;
  v_slot_ids jsonb;
  v_slot_count integer;
  v_stamp jsonb;
  v_rolled_back boolean:=false;
begin
  if jsonb_typeof(p_variant_templates)<>'array'
    or jsonb_array_length(p_variant_templates)<>3 then
    raise exception 'CONTRACT_VARIANT_TEMPLATES_REQUIRED';
  end if;
  if length(coalesce(p_gateway_version,'')) not between 1 and 500 then
    raise exception 'GATEWAY_VERSION_INVALID';
  end if;

  begin
    select r.* into v_source_run
    from public.optimization_runs_v2 r
    join solver_private.optimization_snapshots_v2 s on s.run_id=r.id
    where jsonb_array_length(coalesce(s.snapshot->'strategies','[]'::jsonb))=3
      and jsonb_array_length(coalesce(s.snapshot->'slots','[]'::jsonb))>0
    order by r.created_at desc limit 1;
    if v_source_run.id is null then raise exception 'CONTRACT_SOURCE_MISSING'; end if;

    select s.snapshot into v_source_snapshot
    from solver_private.optimization_snapshots_v2 s
    where s.run_id=v_source_run.id;

    v_snapshot:=jsonb_set(
      v_source_snapshot,'{runId}',to_jsonb(v_run_id::text),true
    );
    -- The result is fully synthetic: no employee is assigned and every slot is
    -- explicitly unfilled. Structural Matrix identifiers are only borrowed so
    -- the real FK/materialization boundary is exercised before rollback.
    v_snapshot:=jsonb_set(v_snapshot,'{employees}','[]'::jsonb,true);
    v_snapshot:=jsonb_set(v_snapshot,'{baselineAssignments}','[]'::jsonb,true);
    v_snapshot:=jsonb_set(v_snapshot,'{lockedAssignments}','[]'::jsonb,true);
    v_snapshot_hash:=encode(extensions.digest(convert_to(
      solver_private.canonical_json_v2(v_snapshot),'UTF8'
    ),'sha256'),'hex');
    select jsonb_agg(to_jsonb(slot.value->>'slotId') order by slot.ordinality),
      count(*)
    into v_slot_ids,v_slot_count
    from jsonb_array_elements(v_snapshot->'slots')
      with ordinality slot(value,ordinality);

    with slots as (
      select value->>'slotId' slot_id
      from jsonb_array_elements(v_snapshot->'slots')
    ), selected_map as (
      select jsonb_object_agg(
        slot_id,to_jsonb(null::text) order by slot_id
      ) payload from slots
    )
    select encode(extensions.digest(convert_to(
      solver_private.canonical_json_v2(payload),'UTF8'
    ),'sha256'),'hex') into v_solution_hash
    from selected_map;

    insert into public.optimization_runs_v2(
      id,idempotency_key,month,matrix_version_id,scenario_id,scope_type,
      scope_role_id,name,status,phase,progress,requested_by,
      snapshot_schema_version,snapshot_hash,solver_version,request_engine,
      attempt_count,max_attempts,lease_owner,lease_token,lease_expires_at,
      worker_execution_name,heartbeat_at,started_at
    ) values(
      v_run_id,'contract-'||v_run_id::text,v_source_run.month,
      v_source_run.matrix_version_id,v_source_run.scenario_id,
      v_source_run.scope_type,v_source_run.scope_role_id,
      'Synthetic contract parity rollback','RUNNING','CLAIMED',1,
      v_source_run.requested_by,v_source_run.snapshot_schema_version,
      v_snapshot_hash,v_source_run.solver_version,'ORTOOLS_V2',1,3,
      'contract-parity-worker',v_lease_token,now()+interval '5 minutes',
      'contract-parity/'||v_run_id::text,now(),now()
    );
    insert into solver_private.optimization_snapshots_v2(
      run_id,schema_version,snapshot_hash,snapshot
    ) values(
      v_run_id,v_source_run.snapshot_schema_version,v_snapshot_hash,v_snapshot
    );
    insert into solver_private.optimization_attempts_v2(
      id,run_id,attempt_number,task_attempt,worker_id,worker_version,
      worker_execution_name,lease_token,status
    ) values(
      v_attempt_id,v_run_id,1,1,'contract-parity-worker',
      v_source_run.solver_version,'contract-parity/'||v_run_id::text,
      v_lease_token,'RUNNING'
    );
    insert into public.optimization_run_strategies_v2(
      run_id,strategy_id,ordinal,status,phase,progress,started_at
    )
    select v_run_id,(item.value->>'id')::uuid,item.ordinality,
      'RUNNING','CLAIMED',1,now()
    from jsonb_array_elements(v_snapshot->'strategies')
      with ordinality item(value,ordinality);

    v_stamp:=solver_private.build_run_version_stamp_uat_v1(
      v_run_id,'contract-parity-synthetic','SERVICE'
    );
    update public.optimization_runs_v2
    set version_stamp=v_stamp where id=v_run_id;

    for v_strategy in
      select item.value
      from jsonb_array_elements(v_snapshot->'strategies')
        with ordinality item(value,ordinality)
      order by item.ordinality
    loop
      v_index:=v_index+1;
      v_template:=p_variant_templates->(v_index-1);
      v_variant:=v_template||jsonb_build_object(
        'schemaVersion',2,
        'strategyId',v_strategy->>'id',
        'strategyCode',v_strategy->>'code',
        'label',coalesce(v_strategy->>'label',v_strategy->>'code'),
        'sortOrder',coalesce((v_strategy->>'sortOrder')::integer,v_index),
        'assignments','[]'::jsonb,
        'unfilledSlotIds',coalesce(v_slot_ids,'[]'::jsonb),
        'metrics',coalesce(v_template->'metrics','{}'::jsonb)||
          jsonb_build_object('UNFILLED',v_slot_count,'TOTAL_COST',0),
        'solutionHash',v_solution_hash,
        'equivalentToStrategyId',null
      );
      v_saved:=public.solver_save_variant_v2(
        v_run_id,v_attempt_id,v_lease_token,v_variant,p_gateway_version
      );
      v_results:=v_results||jsonb_build_array(jsonb_build_object(
        'strategyCode',v_strategy->>'code',
        'variantId',v_saved->>'variantId',
        'stageCount',v_saved->'stageCount',
        'versionStamp',v_saved->'versionStamp',
        'cost',(
          select jsonb_build_object(
            'totalCostMinor',f.total_cost_minor,
            'budgetMinor',f.budget_minor,'currency',f.currency
          )
          from solver_private.plan_variant_finance_v2 f
          where f.variant_id=(v_saved->>'variantId')::uuid
        ),
        'metrics',(
          select pv.metrics from public.plan_variants_v2 pv
          where pv.id=(v_saved->>'variantId')::uuid
        ),
        'stageProof',(
          select pv.stage_proof from public.plan_variants_v2 pv
          where pv.id=(v_saved->>'variantId')::uuid
        )
      ));
    end loop;
    if jsonb_array_length(v_results)<>3 then
      raise exception 'CONTRACT_VARIANT_COUNT_INVALID';
    end if;
    raise exception 'CONTRACT_PARITY_ROLLBACK';
  exception
    when raise_exception then
      if sqlerrm<>'CONTRACT_PARITY_ROLLBACK' then raise; end if;
      v_rolled_back:=true;
  end;

  if exists(select 1 from public.optimization_runs_v2 where id=v_run_id) then
    raise exception 'CONTRACT_ROLLBACK_FAILED';
  end if;
  return jsonb_build_object(
    'passed',v_rolled_back,'rolledBack',v_rolled_back,
    'syntheticRunId',v_run_id,'variants',v_results
  );
end;
$$;

revoke all on function public.solver_contract_parity_probe_uat_v1(jsonb,text)
  from public,anon,authenticated,service_role;
grant execute on function public.solver_contract_parity_probe_uat_v1(jsonb,text)
  to service_role;

create or replace function public.solver_dispatch_inspect_uat_v1(p_run_id uuid)
returns jsonb
language sql
stable
security definer
set search_path=''
as $$
  select coalesce((
    select jsonb_build_object(
      'runId',o.run_id,'dispatchStatus',o.dispatch_status,
      'northflankRunId',o.northflank_run_id,
      'requestedAt',o.requested_at,
      'northflankAcceptedAt',o.northflank_accepted_at,
      'containerStartedAt',o.container_started_at,
      'jobFinishedAt',o.job_finished_at
    )
    from solver_private.solver_job_dispatch_outbox_uat_v1 o
    where o.run_id=p_run_id
  ),jsonb_build_object('runId',p_run_id,'dispatchStatus','NOT_FOUND'))
$$;

revoke all on function public.solver_dispatch_inspect_uat_v1(uuid)
  from public,anon,authenticated,service_role;
grant execute on function public.solver_dispatch_inspect_uat_v1(uuid)
  to service_role;

create or replace function public.solver_job_reconcile_candidates_uat_v1(
  p_limit integer default 20
) returns jsonb
language sql
stable
security definer
set search_path=''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'runId',candidate.run_id,
    'northflankRunId',candidate.northflank_run_id,
    'dispatchStatus',candidate.dispatch_status
  ) order by candidate.updated_at,candidate.run_id),'[]'::jsonb)
  from (
    select o.run_id,o.northflank_run_id,o.dispatch_status,o.updated_at
    from solver_private.solver_job_dispatch_outbox_uat_v1 o
    where o.northflank_run_id is not null
      and o.dispatch_status in ('ACCEPTED','STARTING','RUNNING','SUCCEEDED')
      and (o.dispatch_status<>'SUCCEEDED' or o.job_finished_at is null)
    order by o.updated_at,o.run_id
    limit greatest(1,least(coalesce(p_limit,20),100))
  ) candidate
$$;

revoke all on function public.solver_job_reconcile_candidates_uat_v1(integer)
  from public,anon,authenticated,service_role;
grant execute on function public.solver_job_reconcile_candidates_uat_v1(integer)
  to service_role;

do $$
declare v_mode text; v_enabled boolean;
begin
  select default_execution_mode,dispatcher_enabled into v_mode,v_enabled
  from solver_private.solver_job_runtime_config_uat_v1 where singleton;
  if v_mode<>'SERVICE' or v_enabled then
    raise exception 'NFJOB_DEFAULT_MODE_NOT_SAFE';
  end if;
  if has_function_privilege(
    'authenticated',
    'public.solver_claim_run_v2(uuid,uuid,text,text,integer,integer,text)',
    'EXECUTE'
  ) then raise exception 'NFJOB_TARGET_CLAIM_EXPOSED'; end if;
  if not has_function_privilege(
    'service_role',
    'public.solver_claim_run_v2(uuid,uuid,text,text,integer,integer,text)',
    'EXECUTE'
  ) then raise exception 'NFJOB_TARGET_CLAIM_UNAVAILABLE'; end if;
  if has_table_privilege(
    'authenticated','solver_private.solver_job_dispatch_outbox_uat_v1','SELECT'
  ) then raise exception 'NFJOB_OUTBOX_EXPOSED'; end if;
  if not has_function_privilege(
    'authenticated',
    'public.optimizer_request_v2(date,uuid,text,uuid,text,text,text)',
    'EXECUTE'
  ) then raise exception 'NFJOB_SERVICE_REQUEST_UNAVAILABLE'; end if;
end;
$$;

comment on function public.solver_claim_run_v2(
  uuid,uuid,text,text,integer,integer,text
) is
  'Capability-bound atomic target claim for one Northflank Job generation; never scans or falls back.';
comment on function public.optimizer_request_job_uat_v1(
  date,uuid,text,uuid,text,text,text
) is
  'Explicit UAT-only JOB request. The default optimizer_request_v2 remains SERVICE.';

notify pgrst,'reload schema';
