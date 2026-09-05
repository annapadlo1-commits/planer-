\set ON_ERROR_STOP on

-- This benchmark is intentionally executable only through a local Unix socket
-- (the companion runner uses `docker exec ... psql`). It never persists rows:
-- all tables/functions are temporary and the outer transaction is rolled back.
begin;

do $local_only$
begin
  if inet_client_addr() is not null then
    raise exception 'AUD014_LOCAL_DOCKER_ONLY';
  end if;
end;
$local_only$;

create temporary table aud014_benchmark_results (
  scenario text not null,
  row_scale bigint not null,
  phase text not null check (phase in ('before','after')),
  operation text not null check (operation in ('read','delete','write')),
  repetition integer not null,
  elapsed_ms numeric not null,
  evidence_rows bigint not null
) on commit drop;

create temporary table aud014_benchmark_plans (
  scenario text not null,
  row_scale bigint not null,
  phase text not null check (phase in ('before','after')),
  read_plan jsonb not null
) on commit drop;

create or replace function pg_temp.aud014_uuid(value bigint)
returns uuid
language sql
immutable
strict
as $function$
  select ('00000000-0000-0000-0000-' || lpad(value::text,12,'0'))::uuid
$function$;

create or replace procedure pg_temp.aud014_run_case(
  p_scenario text,
  p_column text,
  p_delete_action text,
  p_scale bigint
)
language plpgsql
as $procedure$
declare
  v_phase text;
  v_repetition integer;
  v_started timestamptz;
  v_elapsed numeric;
  v_rows bigint;
  v_read_target uuid;
  v_delete_target uuid;
  v_plan jsonb;
begin
  if p_scenario not in (
    'application_access_directory_v1_auth_user_id_fkey',
    'audit_log_actor_id_fkey',
    'employee_preferences_employee_id_fkey'
  ) then
    raise exception 'AUD014_UNKNOWN_SCENARIO';
  end if;
  if p_scale not in (1000,100000,1000000) then
    raise exception 'AUD014_UNSUPPORTED_SCALE';
  end if;

  execute 'drop table if exists pg_temp.aud014_child';
  execute 'drop table if exists pg_temp.aud014_parent';
  execute 'create temporary table aud014_parent (id uuid primary key) on commit drop';
  execute format(
    'create temporary table aud014_child (%1$I uuid, payload text not null, constraint aud014_fk foreign key (%1$I) references aud014_parent(id) on delete %2$s) on commit drop',
    p_column,
    p_delete_action
  );

  execute 'insert into aud014_parent(id) select pg_temp.aud014_uuid(value) from generate_series(1,2001) series(value)';
  execute format(
    'insert into aud014_child(%1$I,payload) select pg_temp.aud014_uuid(mod(value-1,1000)+1),repeat(''x'',32) from generate_series(1,$1) series(value)',
    p_column
  ) using p_scale;
  execute 'analyze aud014_parent';
  execute 'analyze aud014_child';

  -- NO ACTION measures the parent-side integrity check for an unreferenced
  -- parent. SET NULL/CASCADE measure their actual referenced-row actions.
  v_read_target:=pg_temp.aud014_uuid(42);
  v_delete_target:=pg_temp.aud014_uuid(
    case when p_scenario='audit_log_actor_id_fkey' then 2001 else 42 end
  );

  foreach v_phase in array array['before','after'] loop
    if v_phase='after' then
      execute format('create index aud014_child_fk_idx on aud014_child (%I)',p_column);
      execute 'analyze aud014_child';
    end if;

    execute format(
      'explain (format json) select count(*) from aud014_child where %I=$1',
      p_column
    ) into v_plan using v_read_target;
    insert into aud014_benchmark_plans(
      scenario,row_scale,phase,read_plan
    ) values(p_scenario,p_scale,v_phase,v_plan);

    execute format(
      'select count(*) from aud014_child where %I=$1',p_column
    ) into v_rows using v_read_target;
    for v_repetition in 1..5 loop
      v_started:=clock_timestamp();
      execute format(
        'select count(*) from aud014_child where %I=$1',p_column
      ) into v_rows using v_read_target;
      v_elapsed:=extract(epoch from clock_timestamp()-v_started)*1000;
      insert into aud014_benchmark_results values(
        p_scenario,p_scale,v_phase,'read',v_repetition,v_elapsed,v_rows
      );
    end loop;

    execute format(
      'select count(*) from aud014_child where %I=$1',p_column
    ) into v_rows using v_delete_target;
    for v_repetition in 1..5 loop
      v_started:=clock_timestamp();
      begin
        execute 'delete from aud014_parent where id=$1' using v_delete_target;
        raise exception 'AUD014_ROLLBACK_DELETE_SAMPLE';
      exception when raise_exception then
        null;
      end;
      v_elapsed:=extract(epoch from clock_timestamp()-v_started)*1000;
      insert into aud014_benchmark_results values(
        p_scenario,p_scale,v_phase,'delete',v_repetition,v_elapsed,v_rows
      );
    end loop;

    for v_repetition in 1..5 loop
      v_started:=clock_timestamp();
      begin
        execute format(
          'insert into aud014_child(%1$I,payload) select pg_temp.aud014_uuid(1),repeat(''w'',32) from generate_series(1,1000)',
          p_column
        );
        raise exception 'AUD014_ROLLBACK_WRITE_SAMPLE';
      exception when raise_exception then
        null;
      end;
      v_elapsed:=extract(epoch from clock_timestamp()-v_started)*1000;
      insert into aud014_benchmark_results values(
        p_scenario,p_scale,v_phase,'write',v_repetition,v_elapsed,1000
      );
    end loop;
  end loop;
end;
$procedure$;

do $matrix$
declare
  v_scale bigint;
begin
  foreach v_scale in array array[1000,100000,1000000]::bigint[] loop
    call pg_temp.aud014_run_case(
      'application_access_directory_v1_auth_user_id_fkey',
      'auth_user_id','set null',v_scale
    );
    call pg_temp.aud014_run_case(
      'audit_log_actor_id_fkey','actor_id','no action',v_scale
    );
    call pg_temp.aud014_run_case(
      'employee_preferences_employee_id_fkey',
      'employee_id','cascade',v_scale
    );
  end loop;
end;
$matrix$;

do $assertions$
begin
  if (select count(*) from aud014_benchmark_results)<>270 then
    raise exception 'AUD014_INCOMPLETE_BENCHMARK_MATRIX';
  end if;
  if exists (
    select 1 from aud014_benchmark_results
    where operation='read'
      and evidence_rows<>row_scale/1000
  ) then
    raise exception 'AUD014_READ_CARDINALITY_MISMATCH';
  end if;
  if exists (
    select 1 from aud014_benchmark_plans
    where phase='before' and read_plan::text like '%aud014_child_fk_idx%'
  ) then
    raise exception 'AUD014_BEFORE_PLAN_ALREADY_HAS_INDEX';
  end if;
  if exists (
    select 1 from aud014_benchmark_plans
    where phase='after' and row_scale>=100000
      and read_plan::text not like '%aud014_child_fk_idx%'
  ) then
    raise exception 'AUD014_AFTER_PLAN_DID_NOT_USE_INDEX';
  end if;
end;
$assertions$;

select jsonb_build_object(
  'scenario',result.scenario,
  'scale',result.row_scale,
  'phase',result.phase,
  'operation',result.operation,
  'repetitions',count(*),
  'medianMs',round(percentile_cont(0.5) within group(order by result.elapsed_ms)::numeric,3),
  'minMs',round(min(result.elapsed_ms),3),
  'maxMs',round(max(result.elapsed_ms),3),
  'evidenceRows',min(result.evidence_rows),
  'readPlan',case when result.operation='read' then min(plan.read_plan::text)::jsonb else null end
)::text
from aud014_benchmark_results result
join aud014_benchmark_plans plan using(scenario,row_scale,phase)
group by result.scenario,result.row_scale,result.phase,result.operation
order by result.scenario,result.row_scale,result.phase,result.operation;

rollback;
