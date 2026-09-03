-- UAT: expose non-sensitive queue timing in the authenticated status payload.
-- This prevents a healthy queued run from looking like a broken 0% generator.
create or replace function solver_private.run_status_payload_v2(p_run_id uuid)
returns jsonb
language sql
stable
security definer
set search_path=''
as $$
  select jsonb_build_object(
    'run',jsonb_build_object(
      'id',r.id,'status',r.status,'phase',r.phase,'progress',r.progress,
      'month',r.month,'scopeType',r.scope_type,'scopeRoleId',r.scope_role_id,
      'requestEngine',r.request_engine,'solverVersion',r.solver_version,
      'failureMessage',r.failure_message,
      'createdAt',r.created_at,'queuedAt',r.queued_at,'startedAt',r.started_at,
      'heartbeatAt',r.heartbeat_at,'updatedAt',r.updated_at,
      'queuePosition',case when r.status='QUEUED' then 1+(
        select count(*) from public.optimization_runs_v2 ahead
        where ahead.status='QUEUED'
          and (ahead.queued_at,ahead.id)<(r.queued_at,r.id)
      ) else null end,
      'waitingSeconds',greatest(0,floor(extract(epoch from (coalesce(r.started_at,now())-r.queued_at))))::integer,
      'runningSeconds',case when r.started_at is null then null else
        greatest(0,floor(extract(epoch from (coalesce(r.finished_at,now())-r.started_at))))::integer end
    ),
    'strategies',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',s.id,'strategyId',s.strategy_id,'name',ms.name,
        'status',s.status,'phase',s.phase,'progress',s.progress
      ) order by s.ordinal)
      from public.optimization_run_strategies_v2 s
      join public.matrix_strategies_v2 ms on ms.id=s.strategy_id
      where s.run_id=r.id
    ),'[]'::jsonb)
  )
  from public.optimization_runs_v2 r where r.id=p_run_id;
$$;

revoke all on function solver_private.run_status_payload_v2(uuid) from public,anon,authenticated;
grant execute on function solver_private.run_status_payload_v2(uuid) to service_role;

comment on function solver_private.run_status_payload_v2(uuid) is
  'Internal optimizer status payload with safe queue position and elapsed-time metadata for UAT progress UX.';
