-- Read-only evidence for the latest OR-Tools run on UAT nhthrtpkfpmufmrmdyjg.

with latest_run as (
  select r.*
  from public.optimization_runs_v2 r
  where r.request_engine='ORTOOLS_V2'
  order by r.created_at desc
  limit 1
)
select jsonb_pretty(jsonb_build_object(
  'runId',r.id,
  'name',r.name,
  'status',r.status,
  'phase',r.phase,
  'failureCode',r.failure_code,
  'matrixVersionId',r.matrix_version_id,
  'createdAt',r.created_at,
  'startedAt',r.started_at,
  'finishedAt',r.finished_at,
  'versionStamp',r.version_stamp,
  'variants',coalesce((
    select jsonb_agg(jsonb_build_object(
      'variantId',v.id,
      'strategy',s.code,
      'status',v.status,
      'hardViolations',v.hard_violations,
      'assignments',v.assignment_count,
      'unfilled',v.unfilled_count,
      'solverStatus',v.solver_status,
      'fairnessTargetMet',v.metrics->'FAIRNESS_TARGET_MET',
      'actualMinimumBps',v.metrics->'FAIRNESS_TARGET_ACTUAL_MINIMUM_BPS',
      'actualSpreadBps',v.metrics->'FAIRNESS_TARGET_ACTUAL_SPREAD_BPS',
      'attemptCount',v.metrics->'FAIRNESS_TARGET_ATTEMPT_COUNT',
      'fallbackUsed',v.metrics->'FAIRNESS_TARGET_FALLBACK_USED',
      'provenUnattainable',v.metrics->'FAIRNESS_TARGET_PROVEN_UNATTAINABLE',
      'failureReasons',jsonb_build_object(
        'minimum',v.metrics->'FAIRNESS_TARGET_MINIMUM_NOT_MET',
        'spread',v.metrics->'FAIRNESS_TARGET_SPREAD_NOT_MET'
      ),
      'targetStage',(
        select stage
        from jsonb_array_elements(v.stage_proof) stage
        where stage->>'name'='FAIRNESS_QUALITY_TARGET'
        limit 1
      ),
      'versionStamp',v.version_stamp
    ) order by rs.ordinal)
    from public.plan_variants_v2 v
    join public.optimization_run_strategies_v2 rs
      on rs.id=v.run_strategy_id
    join public.matrix_strategies_v2 s on s.id=v.strategy_id
    where v.run_id=r.id
  ),'[]'::jsonb)
)) as b4f170_latest_run
from latest_run r;
