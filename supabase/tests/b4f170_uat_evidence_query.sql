-- Read-only UAT evidence for B4F-170. Execute only against project
-- nhthrtpkfpmufmrmdyjg after verifying the linked pooler hostname.

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

select jsonb_pretty(jsonb_build_object(
  'targetMetRun',(
    select jsonb_build_object(
      'runId',r.id,
      'createdAt',r.created_at,
      'minimumBps',coalesce(
        v.metrics->'FAIRNESS_TARGET_ACTUAL_MINIMUM_BPS',
        v.metrics->'MIN_ESTIMATED_ACHIEVABLE_TARGET_UTILIZATION_BPS'
      ),
      'spreadBps',coalesce(
        v.metrics->'FAIRNESS_TARGET_ACTUAL_SPREAD_BPS',
        v.metrics->'ESTIMATED_ACHIEVABLE_TARGET_UTILIZATION_SPREAD_BPS'
      )
    )
    from public.plan_variants_v2 v
    join public.optimization_runs_v2 r on r.id=v.run_id
    join public.matrix_strategies_v2 s on s.id=v.strategy_id
    where s.code='PREFERENCES'
      and r.status='READY'
      and v.hard_violations=0
      and coalesce(
        (v.metrics->>'FAIRNESS_TARGET_MET')::integer,
        (v.metrics->>'FAIRNESS_QUALITY_GATE_PASSED')::integer,
        0
      )=1
    order by r.created_at desc
    limit 1
  ),
  'targetNotMetRun',(
    select jsonb_build_object(
      'runId',r.id,
      'createdAt',r.created_at,
      'minimumBps',v.metrics->'FAIRNESS_TARGET_ACTUAL_MINIMUM_BPS',
      'spreadBps',v.metrics->'FAIRNESS_TARGET_ACTUAL_SPREAD_BPS',
      'attemptCount',v.metrics->'FAIRNESS_TARGET_ATTEMPT_COUNT',
      'fallbackUsed',v.metrics->'FAIRNESS_TARGET_FALLBACK_USED',
      'provenUnattainable',v.metrics->'FAIRNESS_TARGET_PROVEN_UNATTAINABLE',
      'variantCount',(
        select count(*)
        from public.plan_variants_v2 sibling
        where sibling.run_id=r.id
      ),
      'hardViolationCount',(
        select coalesce(sum(sibling.hard_violations),0)
        from public.plan_variants_v2 sibling
        where sibling.run_id=r.id
      )
    )
    from public.plan_variants_v2 v
    join public.optimization_runs_v2 r on r.id=v.run_id
    join public.matrix_strategies_v2 s on s.id=v.strategy_id
    where s.code='PREFERENCES'
      and r.status='READY'
      and v.hard_violations=0
      and coalesce(
        (v.metrics->>'FAIRNESS_TARGET_MET')::integer,
        (v.metrics->>'FAIRNESS_QUALITY_GATE_PASSED')::integer,
        1
      )=0
    order by r.created_at desc
    limit 1
  ),
  'trueInfeasibleRun',(
    select jsonb_build_object(
      'runId',r.id,
      'createdAt',r.created_at,
      'failureCode',r.failure_code,
      'failureMessage',r.failure_message
    )
    from public.optimization_runs_v2 r
    where r.status='FAILED'
      and (
        coalesce(r.failure_code,'') ilike '%INFEAS%'
        or coalesce(r.failure_message,'') ilike '%INFEAS%'
        or coalesce(r.failure_message,'') ilike '%legalnego rozwiązania%'
      )
    order by r.created_at desc
    limit 1
  )
)) as b4f170_reference_cases;
