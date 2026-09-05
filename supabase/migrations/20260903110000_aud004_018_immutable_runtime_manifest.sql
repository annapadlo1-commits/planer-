-- AUD-2026-09-01-004 and AUD-2026-09-01-018.
-- Future deployment target: UAT nhthrtpkfpmufmrmdyjg only; never production.
-- Safe rollout order: gateway, this migration, then worker. A legacy worker may
-- still claim during rollout, but cannot save READY output without a manifest.

begin;

alter table solver_private.optimization_attempts_v2
  add column if not exists worker_build_manifest jsonb;

create or replace function public.solver_claim_next_v3(
  p_worker_id text,
  p_worker_version text,
  p_worker_build_manifest jsonb,
  p_task_attempt integer,
  p_lease_seconds integer
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_result jsonb;
  v_attempt_id uuid;
begin
  if jsonb_typeof(p_worker_build_manifest) is distinct from 'object'
    or (select count(*) from jsonb_object_keys(p_worker_build_manifest))<>4
    or exists(
      select 1 from jsonb_object_keys(p_worker_build_manifest) key
      where key not in (
        'contractVersion','sourceSha','imageDigest','buildTimestamp'
      )
    )
    or coalesce(p_worker_build_manifest->>'contractVersion','')
      !~ '^[A-Z][A-Z0-9_]{2,99}$'
    or coalesce(p_worker_build_manifest->>'sourceSha','')
      !~ '^[0-9a-f]{40}$'
    or coalesce(p_worker_build_manifest->>'imageDigest','')
      !~ '^sha256:[0-9a-f]{64}$'
    or coalesce(p_worker_build_manifest->>'buildTimestamp','')
      !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
  then
    raise exception 'WORKER_BUILD_MANIFEST_INVALID';
  end if;

  v_result:=public.solver_claim_next_v2(
    p_worker_id,p_worker_version,p_task_attempt,p_lease_seconds
  );
  if coalesce((v_result->>'claimed')::boolean,false) then
    v_attempt_id:=nullif(v_result->>'attemptId','')::uuid;
    update solver_private.optimization_attempts_v2
    set worker_build_manifest=p_worker_build_manifest
    where id=v_attempt_id and run_id=nullif(v_result->>'runId','')::uuid
      and worker_version=trim(p_worker_version);
    if not found then raise exception 'WORKER_BUILD_MANIFEST_NOT_BOUND'; end if;
  end if;
  return v_result;
end;
$$;

alter function public.solver_save_variant_v2(uuid,uuid,uuid,jsonb,text)
  rename to solver_save_variant_before_aud004_018;

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
declare
  v_result jsonb;
  v_variant_id uuid;
  v_version_stamp jsonb;
  v_worker_manifest jsonb;
  v_gateway_deployment_id text;
  v_gateway_source_sha text;
  v_ledger_sha256 text;
  v_ledger_row_count bigint;
  v_ledger_max_version text;
begin
  select a.worker_build_manifest into v_worker_manifest
  from solver_private.optimization_attempts_v2 a
  where a.id=p_attempt_id and a.run_id=p_run_id
    and a.lease_token=p_lease_token and a.status='RUNNING';
  if v_worker_manifest is null then
    raise exception 'WORKER_BUILD_MANIFEST_MISSING';
  end if;
  if coalesce(p_gateway_version,'')
    !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}@[0-9a-f]{40}$'
  then
    raise exception 'GATEWAY_BUILD_MANIFEST_INVALID';
  end if;
  v_gateway_deployment_id:=split_part(p_gateway_version,'@',1);
  v_gateway_source_sha:=split_part(p_gateway_version,'@',2);

  select
    encode(extensions.digest(convert_to(coalesce(string_agg(
      ledger.row_document,E'\n' order by ledger.version
    ),''),'UTF8'),'sha256'),'hex'),
    count(*),
    max(ledger.version)
  into v_ledger_sha256,v_ledger_row_count,v_ledger_max_version
  from (
    select
      coalesce(to_jsonb(sm)->>'version','') as version,
      jsonb_build_object(
        'version',coalesce(to_jsonb(sm)->>'version',''),
        'name',coalesce(to_jsonb(sm)->>'name',''),
        'statements',coalesce(to_jsonb(sm)->'statements','[]'::jsonb)
      )::text as row_document
    from supabase_migrations.schema_migrations sm
  ) ledger;
  if v_ledger_row_count<1 or v_ledger_max_version is null
    or v_ledger_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'MIGRATION_LEDGER_MANIFEST_INVALID';
  end if;

  v_result:=public.solver_save_variant_before_aud004_018(
    p_run_id,p_attempt_id,p_lease_token,p_variant,p_gateway_version
  );
  v_variant_id:=nullif(v_result->>'variantId','')::uuid;
  if v_variant_id is null then raise exception 'VARIANT_ID_MISSING'; end if;
  select v.version_stamp into v_version_stamp
  from public.plan_variants_v2 v
  where v.id=v_variant_id and v.run_id=p_run_id;
  if v_version_stamp is null then raise exception 'VERSION_STAMP_MISSING'; end if;

  v_version_stamp:=jsonb_set(
    jsonb_set(
      jsonb_set(
        v_version_stamp,
        '{solver}',
        coalesce(v_version_stamp->'solver','{}'::jsonb)||v_worker_manifest,
        true
      ),
      '{gateway}',
      jsonb_build_object(
        'deploymentId',v_gateway_deployment_id,
        'gatewaySourceSha',v_gateway_source_sha
      ),
      true
    ),
    '{database}',
    jsonb_build_object(
      'schemaVersion',v_ledger_max_version,
      'ledgerSha256',v_ledger_sha256,
      'ledgerRowCount',v_ledger_row_count
    ),
    true
  );
  update public.plan_variants_v2 v
  set version_stamp=v_version_stamp
  where v.id=v_variant_id and v.run_id=p_run_id;
  if not found then raise exception 'VARIANT_NOT_FOUND'; end if;
  update public.optimization_runs_v2 r
  set version_stamp=v_version_stamp,updated_at=now()
  where r.id=p_run_id;
  return jsonb_set(v_result,'{versionStamp}',v_version_stamp,true);
end;
$$;

alter function public.solver_claim_next_v3(text,text,jsonb,integer,integer)
  owner to postgres;
alter function public.solver_save_variant_v2(uuid,uuid,uuid,jsonb,text)
  owner to postgres;

revoke all on function public.solver_claim_next_v3(
  text,text,jsonb,integer,integer
) from public,anon,authenticated,service_role;
grant execute on function public.solver_claim_next_v3(
  text,text,jsonb,integer,integer
) to service_role;
revoke all on function public.solver_save_variant_before_aud004_018(
  uuid,uuid,uuid,jsonb,text
) from public,anon,authenticated,service_role;
revoke all on function public.solver_save_variant_v2(
  uuid,uuid,uuid,jsonb,text
) from public,anon,authenticated,service_role;
grant execute on function public.solver_save_variant_v2(
  uuid,uuid,uuid,jsonb,text
) to service_role;

comment on function public.solver_claim_next_v3(
  text,text,jsonb,integer,integer
) is 'Claims work and binds the immutable solver contract, source, image and build time.';
comment on column solver_private.optimization_attempts_v2.worker_build_manifest
  is 'Immutable solver artifact identity supplied by solver_claim_next_v3.';

notify pgrst,'reload schema';

commit;
