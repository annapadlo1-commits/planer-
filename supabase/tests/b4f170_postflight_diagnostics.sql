-- Read-only diagnostics for B4F-170 on UAT nhthrtpkfpmufmrmdyjg.

select jsonb_pretty(jsonb_build_object(
  'activeMatrix',(
    select jsonb_build_object(
      'id',mv.id,
      'version',mv.version,
      'status',mv.status,
      'baseVersionId',mv.base_version_id,
      'semantics',mv.settings->>'strategySemanticsVersion',
      'qualityTarget',mv.settings->'fairnessQualityTarget',
      'hasLegacyGate',mv.settings ? 'fairnessQualityGate',
      'contentHash',mv.content_hash
    )
    from public.matrix_versions mv
    where mv.status='ACTIVE' and mv.schema_version>=2
    order by mv.version desc
    limit 1
  ),
  'historicalV21',(
    select jsonb_build_object(
      'id',mv.id,
      'version',mv.version,
      'status',mv.status,
      'semantics',mv.settings->>'strategySemanticsVersion',
      'qualityGate',mv.settings->'fairnessQualityGate',
      'contentHash',mv.content_hash
    )
    from public.matrix_versions mv
    where mv.settings->>'strategySemanticsVersion'='B4F169_V1'
    order by mv.version desc
    limit 1
  ),
  'migrationRecorded',exists(
    select 1 from supabase_migrations.schema_migrations sm
    where sm.version='20260824160525'
  ),
  'finalizer',(
    select jsonb_build_object(
      'mentionsFairnessTarget',definition like '%FAIRNESS_TARGET%'
        or definition like '%fairnessQuality%',
      'mentionsHardViolations',definition like '%hard_violations%',
      'definition',definition
    )
    from (select pg_get_functiondef(
      'public.solver_finalize_v2(uuid,uuid,uuid)'::regprocedure
    ) definition) source
  ),
  'finalizerPrior',pg_get_functiondef(
    'public.solver_finalize_before_nfjob_uat_v1(uuid,uuid,uuid)'::regprocedure
  ),
  'saveCurrent',pg_get_functiondef(
    'public.solver_save_variant_v2(uuid,uuid,uuid,jsonb,text)'::regprocedure
  ),
  'savePrior',pg_get_functiondef(
    'public.solver_save_variant_before_b4f170(uuid,uuid,uuid,jsonb,text)'::regprocedure
  ),
  'saveBeforeNorthflank',pg_get_functiondef(
    'public.solver_save_variant_before_nfjob_uat_v1(uuid,uuid,uuid,jsonb,text)'::regprocedure
  ),
  'serviceRoleCanSave',has_function_privilege(
    'service_role',
    'public.solver_save_variant_v2(uuid,uuid,uuid,jsonb,text)',
    'EXECUTE'
  ),
  'authenticatedCanSave',has_function_privilege(
    'authenticated',
    'public.solver_save_variant_v2(uuid,uuid,uuid,jsonb,text)',
    'EXECUTE'
  )
)) as b4f170_postflight;
