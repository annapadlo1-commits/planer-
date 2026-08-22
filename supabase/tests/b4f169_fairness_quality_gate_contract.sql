begin;

do $$
declare
  v_active public.matrix_versions%rowtype;
  v_snapshot_function text;
  v_save_function text;
begin
  select * into v_active
  from public.matrix_versions mv
  where mv.status='ACTIVE' and mv.schema_version>=2
  order by mv.version desc
  limit 1;

  if v_active.settings->>'strategySemanticsVersion'<>'B4F169_V1' then
    raise exception 'B4F169_ACTIVE_MATRIX_SEMANTICS_MISMATCH';
  end if;
  if v_active.settings->'fairnessQualityGate'<>jsonb_build_object(
    'minimumEstimatedAchievableTargetUtilizationBps',700,
    'maximumEstimatedAchievableTargetUtilizationSpreadBps',300,
    'maxAttempts',3
  ) then
    raise exception 'B4F169_ACTIVE_MATRIX_GATE_MISMATCH';
  end if;
  if not (v_active.settings->'mandatoryProductGuards'
    ? 'FAIRNESS_QUALITY_GATE') then
    raise exception 'B4F169_MATRIX_GATE_NOT_DECLARED';
  end if;
  if not exists(
    select 1 from public.matrix_versions mv
    where mv.settings->>'strategySemanticsVersion'='B4F168_V1'
      and mv.status<>'ACTIVE'
  ) then
    raise exception 'B4F169_HISTORICAL_B4F168_MATRIX_MISSING';
  end if;

  perform solver_private.validate_strategy_semantics_b4f169(v_active.id);
  select pg_get_functiondef(
    'solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)'::regprocedure
  ) into v_snapshot_function;
  if v_snapshot_function like '%hashtextextended(p_run_id::text%'
    or v_snapshot_function !~
      'v_seed_document\s*:=\s*v_snapshot\s*-\s*''runId'''
    or v_snapshot_function not like '%BUSINESS_SNAPSHOT_B4F169_V1%'
    or v_snapshot_function not like '%fairnessQualityGate%'
  then
    raise exception 'B4F169_STABLE_SNAPSHOT_SEED_CONTRACT_MISMATCH';
  end if;

  select pg_get_functiondef(
    'public.solver_save_variant_v2(uuid,uuid,uuid,jsonb,text)'::regprocedure
  ) into v_save_function;
  if v_save_function not like
    '%20260822220000_b4f169_deterministic_fairness_quality_gate%'
  then
    raise exception 'B4F169_DATABASE_STAMP_MISMATCH';
  end if;

  if has_function_privilege(
    'service_role',
    'solver_private.build_snapshot_payload_before_b4f169(uuid,date,uuid,uuid,text,uuid)',
    'EXECUTE'
  ) then
    raise exception 'B4F169_PRIOR_SNAPSHOT_BUILDER_EXPOSED';
  end if;
end;
$$;

rollback;
