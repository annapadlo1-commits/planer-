-- B4F-170 UAT: 70% / 30 p.p. is a desired quality target, never a
-- feasibility condition. Historical Matrix v21 remains immutable; v22
-- publishes the corrected contract and preserves deterministic attempts.

begin;

create temp table b4f170_prior_active on commit drop as
select mv.id,mv.version,mv.content_hash,
  public.matrix_v2_content_document(mv.id) content_document
from public.matrix_versions mv
where mv.status='ACTIVE' and mv.schema_version>=2
order by mv.version desc
limit 1;

do $$
begin
  if (select count(*) from b4f170_prior_active)<>1 then
    raise exception 'B4F170_ACTIVE_MATRIX_REQUIRED';
  end if;
  if exists(
    select 1 from public.matrix_versions mv
    where mv.status='DRAFT' and mv.schema_version>=2
  ) then
    raise exception 'B4F170_EXISTING_DRAFT_REQUIRES_OWNER_DECISION';
  end if;
end;
$$;

create or replace function solver_private.validate_strategy_semantics_b4f170(
  p_matrix_version_id uuid
)
returns void
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  v_legacy_guards constant jsonb :=
    '["HARD_CONSTRAINTS","COVERAGE","ROLE_BACKUP","OVERTIME","ZERO_HOURS","PRIMARY_ROLE","MAX_MIN_FAIRNESS","FAIRNESS_SPREAD"]'::jsonb;
  v_gate_guards constant jsonb :=
    '["HARD_CONSTRAINTS","COVERAGE","ROLE_BACKUP","OVERTIME","ZERO_HOURS","PRIMARY_ROLE","MAX_MIN_FAIRNESS","FAIRNESS_SPREAD","FAIRNESS_QUALITY_GATE"]'::jsonb;
  v_target_guards constant jsonb :=
    '["HARD_CONSTRAINTS","COVERAGE","ROLE_BACKUP","OVERTIME","ZERO_HOURS","PRIMARY_ROLE","MAX_MIN_FAIRNESS","FAIRNESS_SPREAD","FAIRNESS_QUALITY_TARGET"]'::jsonb;
  v_settings jsonb;
  v_quality jsonb;
  v_semantics_version text;
begin
  select mv.settings into v_settings
  from public.matrix_versions mv
  where mv.id=p_matrix_version_id;
  v_semantics_version:=v_settings->>'strategySemanticsVersion';
  v_quality:=case
    when v_semantics_version='B4F169_V1' then v_settings->'fairnessQualityGate'
    when v_semantics_version='B4F170_V1' then v_settings->'fairnessQualityTarget'
    else null
  end;

  if v_semantics_version is null
     or v_semantics_version not in (
      'B4F165_V1','B4F168_V1','B4F169_V1','B4F170_V1'
    )
    or v_settings->'mandatoryProductGuards'<>(case
      when v_semantics_version='B4F169_V1' then v_gate_guards
      when v_semantics_version='B4F170_V1' then v_target_guards
      else v_legacy_guards
    end)
    or coalesce(
      (v_settings->>'configurableObjectivesStartAfterMandatoryGuards')::boolean,
      false
    ) is not true then
    raise exception 'STRATEGY_SEMANTICS_MISMATCH: MATRIX_DECLARATION';
  end if;

  if v_semantics_version in ('B4F169_V1','B4F170_V1') then
    if jsonb_typeof(v_quality) is distinct from 'object'
      or (select count(*) from jsonb_object_keys(v_quality))<>3
      or exists(
        select 1 from jsonb_object_keys(v_quality) key
        where key not in (
          'minimumEstimatedAchievableTargetUtilizationBps',
          'maximumEstimatedAchievableTargetUtilizationSpreadBps',
          'maxAttempts'
        )
      ) then
      raise exception 'STRATEGY_SEMANTICS_MISMATCH: FAIRNESS_QUALITY_TARGET';
    end if;
    if coalesce(
      v_quality->>'minimumEstimatedAchievableTargetUtilizationBps',''
    ) !~ '^[0-9]+$'
      or coalesce(
        v_quality->>'maximumEstimatedAchievableTargetUtilizationSpreadBps',''
      ) !~ '^[0-9]+$'
      or coalesce(v_quality->>'maxAttempts','') !~ '^[0-9]+$'
      or (v_quality->>'minimumEstimatedAchievableTargetUtilizationBps')::integer
        not between 0 and 1000
      or (v_quality->>'maximumEstimatedAchievableTargetUtilizationSpreadBps')::integer
        not between 0 and 1000
      or (v_quality->>'maxAttempts')::integer not between 1 and 3 then
      raise exception 'STRATEGY_SEMANTICS_MISMATCH: FAIRNESS_QUALITY_TARGET';
    end if;
  end if;

  if (
    select count(distinct s.code)
    from public.matrix_strategies_v2 s
    where s.matrix_version_id=p_matrix_version_id and s.active
      and s.code in ('BALANCED','MIN_COST','PREFERENCES')
  )<>3 then
    raise exception 'STRATEGY_SEMANTICS_MISMATCH: BUILT_IN_STRATEGIES';
  end if;

  if v_semantics_version<>'B4F165_V1' and exists(
    select 1
    from public.matrix_strategy_objectives_v2 o
    where o.matrix_version_id=p_matrix_version_id
      and o.metric_code='HOME_LOCATION_VIOLATIONS'
  ) then
    raise exception
      'STRATEGY_SEMANTICS_MISMATCH: HOME_LOCATION_VIOLATIONS_IS_OBSOLETE';
  end if;

  if exists(
    with expected(strategy_code,metric_code,tier) as (values
      ('BALANCED','UNFILLED',1),
      ('BALANCED','TOTAL_COST',2),
      ('BALANCED','PREFERENCE_VIOLATIONS',2),
      ('BALANCED','OVERTIME_MINUTES',2),
      ('BALANCED','NOMINAL_DEVIATION_MINUTES',2),
      ('BALANCED','LOAD_SPREAD_MINUTES',2),
      ('BALANCED','WEEKEND_SPREAD',2),
      ('BALANCED','BASELINE_CHANGES',2),
      ('MIN_COST','UNFILLED',1),
      ('MIN_COST','TOTAL_COST',2),
      ('MIN_COST','OVERTIME_MINUTES',3),
      ('MIN_COST','PREFERENCE_VIOLATIONS',4),
      ('MIN_COST','NOMINAL_DEVIATION_MINUTES',5),
      ('MIN_COST','LOAD_SPREAD_MINUTES',5),
      ('MIN_COST','WEEKEND_SPREAD',5),
      ('MIN_COST','BASELINE_CHANGES',6),
      ('PREFERENCES','UNFILLED',1),
      ('PREFERENCES','LOAD_SPREAD_MINUTES',2),
      ('PREFERENCES','NOMINAL_DEVIATION_MINUTES',3),
      ('PREFERENCES','PREFERENCE_VIOLATIONS',4),
      ('PREFERENCES','WEEKEND_SPREAD',5),
      ('PREFERENCES','TOTAL_COST',6),
      ('PREFERENCES','OVERTIME_MINUTES',7),
      ('PREFERENCES','BASELINE_CHANGES',7)
    ), legacy_home(strategy_code,metric_code,tier) as (values
      ('BALANCED','HOME_LOCATION_VIOLATIONS',2),
      ('MIN_COST','HOME_LOCATION_VIOLATIONS',3),
      ('PREFERENCES','HOME_LOCATION_VIOLATIONS',6)
    ), versioned_expected as (
      select * from expected
      union all
      select * from legacy_home where v_semantics_version='B4F165_V1'
    )
    select 1
    from versioned_expected e
    left join public.matrix_strategies_v2 s
      on s.matrix_version_id=p_matrix_version_id and s.active
      and s.code=e.strategy_code
    left join public.matrix_strategy_objectives_v2 o
      on o.matrix_version_id=p_matrix_version_id and o.strategy_id=s.id
      and o.active and o.metric_code=e.metric_code
    where o.id is null or o.tier<>e.tier or o.weight<=0
      or upper(o.direction) not in ('MIN','MINIMIZE')
  ) then
    raise exception 'STRATEGY_SEMANTICS_MISMATCH: OBJECTIVE_TIERS';
  end if;
end;
$$;

create or replace function solver_private.validate_strategy_semantics_b4f165(
  p_matrix_version_id uuid
)
returns void
language plpgsql
stable
security definer
set search_path=''
as $$
begin
  perform solver_private.validate_strategy_semantics_b4f170(
    p_matrix_version_id
  );
end;
$$;

create or replace function solver_private.apply_strategy_semantics_b4f170(
  p_matrix_version_id uuid
)
returns void
language plpgsql
volatile
security definer
set search_path=''
as $$
begin
  perform solver_private.validate_strategy_semantics_b4f169(
    p_matrix_version_id
  );

  update public.matrix_versions mv
  set settings=(coalesce(mv.settings,'{}'::jsonb)-'fairnessQualityGate')
    ||jsonb_build_object(
      'strategySemanticsVersion','B4F170_V1',
      'mandatoryProductGuards',jsonb_build_array(
        'HARD_CONSTRAINTS','COVERAGE','ROLE_BACKUP','OVERTIME','ZERO_HOURS',
        'PRIMARY_ROLE','MAX_MIN_FAIRNESS','FAIRNESS_SPREAD',
        'FAIRNESS_QUALITY_TARGET'
      ),
      'fairnessQualityTarget',jsonb_build_object(
        'minimumEstimatedAchievableTargetUtilizationBps',700,
        'maximumEstimatedAchievableTargetUtilizationSpreadBps',300,
        'maxAttempts',3
      )
    )
  where mv.id=p_matrix_version_id;

  perform solver_private.validate_strategy_semantics_b4f170(
    p_matrix_version_id
  );
end;
$$;

alter function solver_private.matrix_v2_seed_required_defaults_uat_v1(uuid)
  rename to matrix_v2_seed_required_defaults_before_b4f170;

create function solver_private.matrix_v2_seed_required_defaults_uat_v1(
  p_matrix_version_id uuid
)
returns void
language plpgsql
volatile
security definer
set search_path=''
as $$
begin
  perform solver_private.matrix_v2_seed_required_defaults_before_b4f170(
    p_matrix_version_id
  );
  perform solver_private.apply_strategy_semantics_b4f170(p_matrix_version_id);
end;
$$;

alter function solver_private.build_snapshot_payload_v2(
  uuid,date,uuid,uuid,text,uuid
) rename to build_snapshot_payload_before_b4f170;

create function solver_private.build_snapshot_payload_v2(
  p_run_id uuid,
  p_month date,
  p_matrix_version_id uuid,
  p_scenario_id uuid,
  p_scope_type text,
  p_scope_role_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  v_snapshot jsonb;
  v_matrix_settings jsonb;
  v_runtime_strategies jsonb;
  v_business_seed integer;
begin
  v_snapshot:=solver_private.build_snapshot_payload_before_b4f170(
    p_run_id,p_month,p_matrix_version_id,p_scenario_id,p_scope_type,p_scope_role_id
  );
  select mv.settings into v_matrix_settings
  from public.matrix_versions mv
  where mv.id=p_matrix_version_id;

  if v_matrix_settings->>'strategySemanticsVersion'='B4F170_V1' then
    perform solver_private.validate_strategy_semantics_b4f170(
      p_matrix_version_id
    );
    v_business_seed:=(v_snapshot#>>'{settings,randomSeed}')::integer;
    select coalesce(jsonb_agg(
      jsonb_set(item.value,'{randomSeed}',to_jsonb(v_business_seed),true)
      order by item.ordinality
    ),'[]'::jsonb)
    into v_runtime_strategies
    from jsonb_array_elements(v_snapshot->'strategies')
      with ordinality item(value,ordinality);
    v_snapshot:=jsonb_set(
      v_snapshot,'{strategies}',v_runtime_strategies,true
    );
    v_snapshot:=jsonb_set(
      v_snapshot,
      '{settings}',
      (coalesce(v_snapshot->'settings','{}'::jsonb)-'fairnessQualityGate')
        ||jsonb_build_object(
          'fairnessQualityTarget',v_matrix_settings->'fairnessQualityTarget',
          'randomSeedSource','BUSINESS_SNAPSHOT_B4F170_V1'
        ),
      true
    );
  end if;

  return v_snapshot;
end;
$$;

revoke all on function
  solver_private.validate_strategy_semantics_b4f170(uuid),
  solver_private.validate_strategy_semantics_b4f165(uuid),
  solver_private.apply_strategy_semantics_b4f170(uuid),
  solver_private.matrix_v2_seed_required_defaults_before_b4f170(uuid),
  solver_private.matrix_v2_seed_required_defaults_uat_v1(uuid),
  solver_private.build_snapshot_payload_before_b4f170(uuid,date,uuid,uuid,text,uuid),
  solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)
from public,anon,authenticated,service_role;

grant execute on function solver_private.build_snapshot_payload_v2(
  uuid,date,uuid,uuid,text,uuid
) to service_role;

do $$
declare
  v_owner uuid;
  v_draft uuid;
begin
  select up.auth_user_id into v_owner
  from public.user_permissions up
  where up.app_role='OWNER'
  order by up.auth_user_id
  limit 1;
  if v_owner is null then raise exception 'B4F170_OWNER_REQUIRED'; end if;
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  v_draft:=public.matrix_v2_create_draft(
    'B4F-170 — fairness jako cel jakości z najlepszym legalnym fallbackiem'
  );
  perform solver_private.apply_strategy_semantics_b4f170(v_draft);
  perform public.matrix_v2_publish_draft(current_date);
end;
$$;

do $$
declare
  v_active public.matrix_versions%rowtype;
  v_prior b4f170_prior_active%rowtype;
begin
  select * into v_prior from b4f170_prior_active;
  select * into v_active
  from public.matrix_versions mv
  where mv.status='ACTIVE' and mv.schema_version>=2
  order by mv.version desc
  limit 1;

  if v_active.id is null
    or v_active.base_version_id<>v_prior.id
    or v_active.version<>v_prior.version+1 then
    raise exception 'B4F170_NEW_ACTIVE_MATRIX_NOT_PUBLISHED';
  end if;
  perform solver_private.validate_strategy_semantics_b4f170(v_active.id);
  if v_active.settings->'fairnessQualityTarget'<>jsonb_build_object(
    'minimumEstimatedAchievableTargetUtilizationBps',700,
    'maximumEstimatedAchievableTargetUtilizationSpreadBps',300,
    'maxAttempts',3
  ) or v_active.settings ? 'fairnessQualityGate' then
    raise exception 'B4F170_QUALITY_TARGET_MISMATCH';
  end if;
  if (select mv.content_hash from public.matrix_versions mv where mv.id=v_prior.id)
      is distinct from v_prior.content_hash
    or public.matrix_v2_content_document(v_prior.id)
      is distinct from v_prior.content_document then
    raise exception 'B4F170_HISTORICAL_MATRIX_CONTENT_CHANGED';
  end if;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_v2',v_active.id::text,
    'B4F170_FAIRNESS_QUALITY_TARGET_PUBLISHED',jsonb_build_object(
      'baseVersionId',v_prior.id,
      'baseVersion',v_prior.version,
      'newVersion',v_active.version,
      'strategySemanticsVersion','B4F170_V1',
      'minimumEstimatedAchievableTargetUtilizationBps',700,
      'maximumEstimatedAchievableTargetUtilizationSpreadBps',300,
      'maxAttempts',3,
      'fallback','BEST_VALID_FAIRNESS_FALLBACK',
      'historicalMatrixPreserved',true
    ));
end;
$$;

-- Keep the per-run database stamp aligned with the corrected contract.
alter function public.solver_save_variant_v2(uuid,uuid,uuid,jsonb,text)
  rename to solver_save_variant_before_b4f170;

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
begin
  v_result:=public.solver_save_variant_before_b4f170(
    p_run_id,p_attempt_id,p_lease_token,p_variant,p_gateway_version
  );
  v_variant_id:=nullif(v_result->>'variantId','')::uuid;
  if v_variant_id is null then raise exception 'VARIANT_ID_MISSING'; end if;

  select v.version_stamp into v_version_stamp
  from public.plan_variants_v2 v
  where v.id=v_variant_id and v.run_id=p_run_id;
  if v_version_stamp is null then raise exception 'VERSION_STAMP_MISSING'; end if;
  v_version_stamp:=jsonb_set(
    v_version_stamp,
    '{database,schemaVersion}',
    to_jsonb('20260824160525_b4f170_fairness_target_best_valid_fallback'::text),
    true
  );
  update public.plan_variants_v2 v
  set version_stamp=v_version_stamp
  where v.id=v_variant_id and v.run_id=p_run_id;
  update public.optimization_runs_v2 r
  set version_stamp=v_version_stamp,updated_at=now()
  where r.id=p_run_id;
  return jsonb_set(v_result,'{versionStamp}',v_version_stamp,true);
end;
$$;

revoke all on function public.solver_save_variant_before_b4f170(
  uuid,uuid,uuid,jsonb,text
) from public,anon,authenticated,service_role;
revoke all on function public.solver_save_variant_v2(
  uuid,uuid,uuid,jsonb,text
) from public,anon,authenticated,service_role;
grant execute on function public.solver_save_variant_v2(
  uuid,uuid,uuid,jsonb,text
) to service_role;

notify pgrst,'reload schema';

commit;
