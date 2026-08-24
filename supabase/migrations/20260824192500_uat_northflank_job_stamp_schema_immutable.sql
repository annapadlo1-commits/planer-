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
      'schemaVersion','frontendCommit','solverCommit','solverImageDigest',
      'solverBuildId','gatewayVersion','strategyConfigVersion',
      'databaseMigrationVersion','snapshotSchemaVersion','executionMode',
      'northflankRunId','dispatcherVersion'
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
