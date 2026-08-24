create or replace function public.solver_job_contract_probe_uat_v1()
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_source public.optimization_runs_v2%rowtype;
  v_org_two uuid;
  v_run_a uuid:=gen_random_uuid();
  v_run_a_waiting uuid:=gen_random_uuid();
  v_run_b uuid:=gen_random_uuid();
  v_run_b_waiting uuid:=gen_random_uuid();
  v_run_same_schedule uuid:=gen_random_uuid();
  v_stamp jsonb;
  v_nonce_a uuid:=gen_random_uuid();
  v_nonce_a_waiting uuid:=gen_random_uuid();
  v_nonce_b uuid:=gen_random_uuid();
  v_nonce_b_waiting uuid:=gen_random_uuid();
  v_first jsonb;
  v_second jsonb;
  v_third jsonb;
  v_claim jsonb;
  v_duplicate_claim jsonb;
  v_missing_claim jsonb;
  v_duplicate_outbox_blocked boolean:=false;
  v_same_schedule_blocked boolean:=false;
  v_wrong_capability_blocked boolean:=false;
  v_stamp_change_blocked boolean:=false;
  v_schema_change_blocked boolean:=false;
  v_nf_change_blocked boolean:=false;
  v_per_organization_concurrency boolean:=false;
  v_dispatch_retry_separate boolean:=false;
  v_acceptance_unknown_safe boolean:=false;
  v_rolled_back boolean:=false;
  v_results jsonb;
begin
  begin
    select r.* into v_source
    from public.optimization_runs_v2 r
    where r.snapshot_schema_version=2
    order by r.created_at desc limit 1;
    if v_source.id is null then raise exception 'GATE_B_SOURCE_RUN_MISSING'; end if;
    select mv.id into v_org_two from public.matrix_versions mv
    where mv.id<>v_source.matrix_version_id
    order by mv.created_at desc limit 1;
    if v_org_two is null then raise exception 'GATE_B_SECOND_ORGANIZATION_KEY_MISSING'; end if;

    v_stamp:=jsonb_build_object(
      'schemaVersion',1,
      'frontendCommit','gate-b-synthetic',
      'solverCommit','86522fe6d701a14a5a2ec90d999f385739a4f212',
      'solverImageDigest',null,
      'solverBuildId','difficult-price-5668',
      'gatewayVersion',null,
      'strategyConfigVersion',repeat('a',64),
      'databaseMigrationVersion','20260824194000_uat_northflank_job_gate_b_probe',
      'snapshotSchemaVersion',2,
      'executionMode','JOB',
      'northflankRunId',null,
      'dispatcherVersion',null
    );

    insert into public.optimization_runs_v2(
      id,idempotency_key,month,matrix_version_id,scenario_id,scope_type,
      scope_role_id,name,status,phase,progress,requested_by,
      snapshot_schema_version,snapshot_hash,solver_version,request_engine,
      attempt_count,max_attempts,version_stamp,queued_at
    ) values
      (v_run_a,'gate-b-'||v_run_a,v_source.month,v_source.matrix_version_id,
       v_source.scenario_id,'COMPANY',null,'Gate B A','QUEUED','DISPATCH_PENDING',0,
       v_source.requested_by,2,repeat('1',64),v_source.solver_version,'ORTOOLS_V2',0,3,v_stamp,now()-interval '5 minutes'),
      (v_run_a_waiting,'gate-b-'||v_run_a_waiting,v_source.month+interval '1 month',v_source.matrix_version_id,
       v_source.scenario_id,'COMPANY',null,'Gate B A waiting','QUEUED','DISPATCH_PENDING',0,
       v_source.requested_by,2,repeat('2',64),v_source.solver_version,'ORTOOLS_V2',0,3,v_stamp,now()-interval '4 minutes'),
      (v_run_b,'gate-b-'||v_run_b,v_source.month,v_org_two,
       v_source.scenario_id,'COMPANY',null,'Gate B B','QUEUED','DISPATCH_PENDING',0,
       v_source.requested_by,2,repeat('3',64),v_source.solver_version,'ORTOOLS_V2',0,3,v_stamp,now()-interval '3 minutes'),
      (v_run_b_waiting,'gate-b-'||v_run_b_waiting,v_source.month+interval '1 month',v_org_two,
       v_source.scenario_id,'COMPANY',null,'Gate B B waiting','QUEUED','DISPATCH_PENDING',0,
       v_source.requested_by,2,repeat('4',64),v_source.solver_version,'ORTOOLS_V2',0,3,v_stamp,now()-interval '2 minutes'),
      (v_run_same_schedule,'gate-b-'||v_run_same_schedule,v_source.month,v_source.matrix_version_id,
       v_source.scenario_id,'COMPANY',null,'Gate B same schedule','QUEUED','DISPATCH_PENDING',0,
       v_source.requested_by,2,repeat('5',64),v_source.solver_version,'ORTOOLS_V2',0,3,v_stamp,now()-interval '1 minute');

    insert into solver_private.solver_job_dispatch_outbox_uat_v1(
      run_id,organization_key,month,scope_type,scope_role_id,requested_at,dispatch_nonce
    ) values
      (v_run_a,v_source.matrix_version_id,v_source.month,'COMPANY',null,now()-interval '5 minutes',v_nonce_a),
      (v_run_a_waiting,v_source.matrix_version_id,(v_source.month+interval '1 month')::date,'COMPANY',null,now()-interval '4 minutes',v_nonce_a_waiting),
      (v_run_b,v_org_two,v_source.month,'COMPANY',null,now()-interval '3 minutes',v_nonce_b),
      (v_run_b_waiting,v_org_two,(v_source.month+interval '1 month')::date,'COMPANY',null,now()-interval '2 minutes',v_nonce_b_waiting);

    begin
      insert into solver_private.solver_job_dispatch_outbox_uat_v1(
        run_id,organization_key,month,scope_type,scope_role_id,requested_at
      ) values(v_run_a,v_source.matrix_version_id,v_source.month,'COMPANY',null,now());
    exception when unique_violation then v_duplicate_outbox_blocked:=true; end;

    begin
      insert into solver_private.solver_job_dispatch_outbox_uat_v1(
        run_id,organization_key,month,scope_type,scope_role_id,requested_at
      ) values(v_run_same_schedule,v_source.matrix_version_id,v_source.month,'COMPANY',null,now());
    exception when unique_violation then v_same_schedule_blocked:=true; end;

    update solver_private.solver_job_runtime_config_uat_v1
    set dispatcher_enabled=true where singleton;
    v_first:=public.solver_dispatch_reserve_uat_v1('gate-b-dispatcher',60);
    v_second:=public.solver_dispatch_reserve_uat_v1('gate-b-dispatcher',60);
    v_third:=public.solver_dispatch_reserve_uat_v1('gate-b-dispatcher',60);
    if v_first->>'runId'<>v_run_a::text
      or v_second->>'runId'<>v_run_b::text
      or v_third->>'status'<>'GLOBAL_LIMIT' then
      raise exception 'GATE_B_CONCURRENCY_INVALID';
    end if;
    select v_first->>'runId'=v_run_a::text
      and v_second->>'runId'=v_run_b::text
      and (select dispatch_status='PENDING'
        from solver_private.solver_job_dispatch_outbox_uat_v1
        where run_id=v_run_a_waiting)
      and (select dispatch_status='PENDING'
        from solver_private.solver_job_dispatch_outbox_uat_v1
        where run_id=v_run_b_waiting)
    into v_per_organization_concurrency;

    perform public.solver_dispatch_result_uat_v1(
      v_run_a,(v_first->>'dispatchLeaseToken')::uuid,'ACCEPTED',
      'gate-b-northflank-a',201,null,null
    );
    v_claim:=public.solver_claim_run_v2(
      v_run_a,v_nonce_a,'gate-b-worker',v_source.solver_version,1,90,'gate-b-gateway'
    );
    v_duplicate_claim:=public.solver_claim_run_v2(
      v_run_a,v_nonce_a,'gate-b-worker-duplicate',v_source.solver_version,1,90,'gate-b-gateway'
    );
    v_missing_claim:=public.solver_claim_run_v2(
      gen_random_uuid(),gen_random_uuid(),'gate-b-worker-missing',v_source.solver_version,1,90,'gate-b-gateway'
    );
    if coalesce((v_claim->>'claimed')::boolean,false) is not true
      or v_duplicate_claim->>'status'<>'CONFLICT'
      or v_missing_claim->>'status'<>'TARGET_NOT_FOUND' then
      raise exception 'GATE_B_TARGET_CLAIM_INVALID';
    end if;
    begin
      perform public.solver_claim_run_v2(
        v_run_a_waiting,v_nonce_a,'gate-b-worker-wrong',v_source.solver_version,1,90,'gate-b-gateway'
      );
    exception when others then
      if sqlerrm='TARGET_CAPABILITY_INVALID' then v_wrong_capability_blocked:=true;
      else raise; end if;
    end;

    perform public.solver_dispatch_result_uat_v1(
      v_run_b,(v_second->>'dispatchLeaseToken')::uuid,'RETRYABLE_REJECTED',
      null,429,'NORTHFLANK_RATE_LIMIT','proven rejection'
    );
    select dispatch_status='PENDING' and dispatch_attempt=1 and solver_retry_count=0
    into v_dispatch_retry_separate
    from solver_private.solver_job_dispatch_outbox_uat_v1 where run_id=v_run_b;
    update solver_private.solver_job_dispatch_outbox_uat_v1
    set next_dispatch_at=now() where run_id=v_run_b;
    v_second:=public.solver_dispatch_reserve_uat_v1('gate-b-dispatcher',60);
    if v_second->>'runId'<>v_run_b::text then
      raise exception 'GATE_B_RETRY_TARGET_CHANGED';
    end if;
    perform public.solver_dispatch_result_uat_v1(
      v_run_b,(v_second->>'dispatchLeaseToken')::uuid,'ACCEPTANCE_UNKNOWN',
      null,null,'NORTHFLANK_ACCEPTANCE_UNKNOWN','response lost'
    );
    select dispatch_status='ACCEPTANCE_UNKNOWN' and dispatch_attempt=2
      and solver_retry_count=0
    into v_acceptance_unknown_safe
    from solver_private.solver_job_dispatch_outbox_uat_v1 where run_id=v_run_b;

    update public.optimization_runs_v2 set version_stamp=version_stamp where id=v_run_a;
    begin
      update public.optimization_runs_v2
      set version_stamp=jsonb_set(version_stamp,'{solverBuildId}','"changed"'::jsonb)
      where id=v_run_a;
    exception when others then
      if sqlerrm like 'VERSION_STAMP_IMMUTABLE_%' then v_stamp_change_blocked:=true;
      else raise; end if;
    end;
    begin
      update public.optimization_runs_v2
      set version_stamp=jsonb_set(version_stamp,'{schemaVersion}','2'::jsonb)
      where id=v_run_a;
    exception when others then
      if sqlerrm like 'VERSION_STAMP_IMMUTABLE_%' then v_schema_change_blocked:=true;
      else raise; end if;
    end;
    begin
      update public.optimization_runs_v2
      set version_stamp=jsonb_set(version_stamp,'{northflankRunId}','"other-run"'::jsonb)
      where id=v_run_a;
    exception when others then
      if sqlerrm like 'VERSION_STAMP_IMMUTABLE_%' then v_nf_change_blocked:=true;
      else raise; end if;
    end;

    v_results:=jsonb_build_object(
      'outboxOneToOne',v_duplicate_outbox_blocked,
      'sameScheduleBlocked',v_same_schedule_blocked,
      'globalConcurrency',v_third->>'status'='GLOBAL_LIMIT',
      'perOrganizationConcurrency',v_per_organization_concurrency,
      'targetClaim',coalesce((v_claim->>'claimed')::boolean,false),
      'duplicateClaimNoOp',v_duplicate_claim->>'status'='CONFLICT',
      'missingTargetNoFallback',v_missing_claim->>'status'='TARGET_NOT_FOUND',
      'wrongCapabilityBlocked',v_wrong_capability_blocked,
      'dispatchRetrySeparate',v_dispatch_retry_separate,
      'acceptanceUnknownNoRetry',v_acceptance_unknown_safe,
      'stampChangeBlocked',v_stamp_change_blocked,
      'schemaChangeBlocked',v_schema_change_blocked,
      'northflankRunChangeBlocked',v_nf_change_blocked
    );
    if exists(
      select 1 from jsonb_each(v_results) item where item.value<>'true'::jsonb
    ) then raise exception 'GATE_B_ASSERTION_FAILED: %',v_results; end if;
    raise exception 'GATE_B_ROLLBACK';
  exception when raise_exception then
    if sqlerrm<>'GATE_B_ROLLBACK' then raise; end if;
    v_rolled_back:=true;
  end;

  if exists(select 1 from public.optimization_runs_v2 where id in(
    v_run_a,v_run_a_waiting,v_run_b,v_run_b_waiting,v_run_same_schedule
  )) then raise exception 'GATE_B_ROLLBACK_FAILED'; end if;
  return v_results||jsonb_build_object('passed',v_rolled_back,'rolledBack',v_rolled_back);
end;
$$;

revoke all on function public.solver_job_contract_probe_uat_v1()
  from public,anon,authenticated,service_role;
grant execute on function public.solver_job_contract_probe_uat_v1()
  to service_role;

notify pgrst,'reload schema';
