do $$
declare
  v_active public.matrix_versions%rowtype;
  v_v21 public.matrix_versions%rowtype;
  v_snapshot_function text;
  v_finalize_function text;
  v_save_function text;
  v_variants_function text;
begin
  select * into v_active
  from public.matrix_versions mv
  where mv.status='ACTIVE' and mv.schema_version>=2
  order by mv.version desc
  limit 1;
  if v_active.id is null
    or v_active.settings->>'strategySemanticsVersion'<>'B4F170_V1' then
    raise exception 'B4F170_ACTIVE_MATRIX_MISMATCH';
  end if;
  if v_active.settings->'fairnessQualityTarget'<>jsonb_build_object(
      'minimumEstimatedAchievableTargetUtilizationBps',700,
      'maximumEstimatedAchievableTargetUtilizationSpreadBps',300,
      'maxAttempts',3
    )
    or v_active.settings ? 'fairnessQualityGate'
    or not (v_active.settings->'mandatoryProductGuards'
      ? 'FAIRNESS_QUALITY_TARGET')
    or v_active.settings->'mandatoryProductGuards'
      ? 'FAIRNESS_QUALITY_GATE' then
    raise exception 'B4F170_TARGET_DECLARATION_MISMATCH';
  end if;

  select * into v_v21
  from public.matrix_versions mv
  where mv.settings->>'strategySemanticsVersion'='B4F169_V1'
  order by mv.version desc
  limit 1;
  if v_v21.id is null
    or v_v21.settings->'fairnessQualityGate'<>jsonb_build_object(
      'minimumEstimatedAchievableTargetUtilizationBps',700,
      'maximumEstimatedAchievableTargetUtilizationSpreadBps',300,
      'maxAttempts',3
    ) then
    raise exception 'B4F170_HISTORICAL_V21_NOT_PRESERVED';
  end if;

  v_snapshot_function:=pg_get_functiondef(
    'solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)'::regprocedure
  );
  if v_snapshot_function not like '%fairnessQualityTarget%'
    or v_snapshot_function not like '%BUSINESS_SNAPSHOT_B4F170_V1%' then
    raise exception 'B4F170_SNAPSHOT_TARGET_NOT_PRESERVED';
  end if;

  v_finalize_function:=pg_get_functiondef(
    'public.solver_finalize_v2(uuid,uuid,uuid)'::regprocedure
  );
  if to_regprocedure(
      'public.solver_finalize_before_nfjob_uat_v1(uuid,uuid,uuid)'
    ) is not null then
    v_finalize_function:=v_finalize_function||pg_get_functiondef(
      'public.solver_finalize_before_nfjob_uat_v1(uuid,uuid,uuid)'::regprocedure
    );
  end if;
  if v_finalize_function like '%FAIRNESS_TARGET%'
    or v_finalize_function like '%fairnessQuality%'
    or v_finalize_function not like '%variant.hard_violations=0%' then
    raise exception 'B4F170_FINALIZATION_MUST_ONLY_REQUIRE_VALID_VARIANTS';
  end if;

  v_save_function:=pg_get_functiondef(
    'public.solver_save_variant_v2(uuid,uuid,uuid,jsonb,text)'::regprocedure
  );
  if v_save_function not like
      '%20260824160525_b4f170_fairness_target_best_valid_fallback%' then
    raise exception 'B4F170_DATABASE_STAMP_MISSING';
  end if;

  v_variants_function:=pg_get_functiondef(
    'public.optimizer_variants_v2(uuid)'::regprocedure
  );
  if v_variants_function not like '%''metrics'',variant.metrics%'
    or v_variants_function not like '%''stageProof'',variant.stage_proof%' then
    raise exception 'B4F170_FRONTEND_DIAGNOSTICS_NOT_PRESERVED';
  end if;

  if has_function_privilege(
      'authenticated',
      'public.solver_save_variant_v2(uuid,uuid,uuid,jsonb,text)',
      'EXECUTE'
    )
    or not has_function_privilege(
      'service_role',
      'public.solver_save_variant_v2(uuid,uuid,uuid,jsonb,text)',
      'EXECUTE'
    ) then
    raise exception 'B4F170_SAVE_PRIVILEGES_INVALID';
  end if;

  raise notice 'B4F170_FAIRNESS_TARGET_FALLBACK_CONTRACT_PASS';
end;
$$;
