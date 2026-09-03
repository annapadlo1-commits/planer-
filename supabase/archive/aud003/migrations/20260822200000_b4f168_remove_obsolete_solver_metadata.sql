-- B4F-168 UAT: publish a new Matrix without the obsolete home-location
-- objective. Historical Matrix versions remain immutable and the worker keeps
-- read compatibility with the B4F165_V1 contract.

create temp table b4f168_prior_active on commit drop as
select mv.id,mv.version,mv.content_hash,
  public.matrix_v2_content_document(mv.id) content_document
from public.matrix_versions mv
where mv.status='ACTIVE' and mv.schema_version>=2
order by mv.version desc
limit 1;

do $$
begin
  if (select count(*) from b4f168_prior_active)<>1 then
    raise exception 'B4F168_ACTIVE_MATRIX_REQUIRED';
  end if;
  if exists(
    select 1 from public.matrix_versions mv
    where mv.status='DRAFT' and mv.schema_version>=2
  ) then
    raise exception 'B4F168_EXISTING_DRAFT_REQUIRES_OWNER_DECISION';
  end if;
end;
$$;

create or replace function solver_private.validate_strategy_semantics_b4f168(
  p_matrix_version_id uuid
)
returns void
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  v_expected_guards constant jsonb :=
    '["HARD_CONSTRAINTS","COVERAGE","ROLE_BACKUP","OVERTIME","ZERO_HOURS","PRIMARY_ROLE","MAX_MIN_FAIRNESS","FAIRNESS_SPREAD"]'::jsonb;
  v_settings jsonb;
  v_semantics_version text;
begin
  select mv.settings into v_settings
  from public.matrix_versions mv
  where mv.id=p_matrix_version_id;
  v_semantics_version:=v_settings->>'strategySemanticsVersion';

  if v_semantics_version not in ('B4F165_V1','B4F168_V1')
    or v_settings->'mandatoryProductGuards'<>v_expected_guards
    or coalesce(
      (v_settings->>'configurableObjectivesStartAfterMandatoryGuards')::boolean,
      false
    ) is not true then
    raise exception 'STRATEGY_SEMANTICS_MISMATCH: MATRIX_DECLARATION';
  end if;

  if (
    select count(distinct s.code)
    from public.matrix_strategies_v2 s
    where s.matrix_version_id=p_matrix_version_id and s.active
      and s.code in ('BALANCED','MIN_COST','PREFERENCES')
  )<>3 then
    raise exception 'STRATEGY_SEMANTICS_MISMATCH: BUILT_IN_STRATEGIES';
  end if;

  if v_semantics_version='B4F168_V1' and exists(
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

-- Keep the trigger/function name introduced by B4F-165 stable while extending
-- its validator to the new contract and retaining historical read support.
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
  perform solver_private.validate_strategy_semantics_b4f168(
    p_matrix_version_id
  );
end;
$$;

create or replace function solver_private.apply_strategy_semantics_b4f168(
  p_matrix_version_id uuid
)
returns void
language plpgsql
volatile
security definer
set search_path=''
as $$
begin
  -- Reuse the already tested hierarchy/descriptions, then remove only the
  -- unsupported objective from the new draft.
  perform solver_private.apply_strategy_semantics_b4f165(p_matrix_version_id);

  delete from public.matrix_strategy_objectives_v2 o
  where o.matrix_version_id=p_matrix_version_id
    and o.metric_code='HOME_LOCATION_VIOLATIONS';

  update public.matrix_versions mv
  set settings=coalesce(mv.settings,'{}'::jsonb)||jsonb_build_object(
    'strategySemanticsVersion','B4F168_V1'
  )
  where mv.id=p_matrix_version_id;

  perform solver_private.validate_strategy_semantics_b4f168(
    p_matrix_version_id
  );
end;
$$;

-- Every future empty-UAT seed receives the current semantics. The B4F-165
-- helper remains available as the backward-compatible base layer.
alter function solver_private.matrix_v2_seed_required_defaults_uat_v1(uuid)
  rename to matrix_v2_seed_required_defaults_before_b4f168;

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
  perform solver_private.matrix_v2_seed_required_defaults_before_b4f168(
    p_matrix_version_id
  );
  perform solver_private.apply_strategy_semantics_b4f168(p_matrix_version_id);
end;
$$;

revoke all on function
  solver_private.validate_strategy_semantics_b4f168(uuid),
  solver_private.validate_strategy_semantics_b4f165(uuid),
  solver_private.apply_strategy_semantics_b4f168(uuid),
  solver_private.matrix_v2_seed_required_defaults_before_b4f168(uuid),
  solver_private.matrix_v2_seed_required_defaults_uat_v1(uuid)
from public,anon,authenticated;

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
  if v_owner is null then raise exception 'B4F168_OWNER_REQUIRED'; end if;
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  v_draft:=public.matrix_v2_create_draft(
    'B4F-168 — aktywne kryteria generatora'
  );
  perform solver_private.apply_strategy_semantics_b4f168(v_draft);
  perform public.matrix_v2_publish_draft(current_date);
end;
$$;

do $$
declare
  v_active public.matrix_versions%rowtype;
  v_prior b4f168_prior_active%rowtype;
begin
  select * into v_prior from b4f168_prior_active;
  select * into v_active
  from public.matrix_versions mv
  where mv.status='ACTIVE' and mv.schema_version>=2
  order by mv.version desc
  limit 1;

  if v_active.id is null
    or v_active.base_version_id<>v_prior.id
    or v_active.version<>v_prior.version+1 then
    raise exception 'B4F168_NEW_ACTIVE_MATRIX_NOT_PUBLISHED';
  end if;
  perform solver_private.validate_strategy_semantics_b4f168(v_active.id);
  if exists(
    select 1 from public.matrix_strategy_objectives_v2 o
    where o.matrix_version_id=v_active.id
      and o.metric_code='HOME_LOCATION_VIOLATIONS'
  ) then
    raise exception 'B4F168_OBSOLETE_OBJECTIVE_REMAINS';
  end if;
  if (select mv.content_hash from public.matrix_versions mv where mv.id=v_prior.id)
      is distinct from v_prior.content_hash
    or public.matrix_v2_content_document(v_prior.id)
      is distinct from v_prior.content_document then
    raise exception 'B4F168_HISTORICAL_MATRIX_CONTENT_CHANGED';
  end if;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_v2',v_active.id::text,
    'B4F168_OBSOLETE_SOLVER_METADATA_REMOVED',jsonb_build_object(
      'baseVersionId',v_prior.id,
      'baseVersion',v_prior.version,
      'newVersion',v_active.version,
      'strategySemanticsVersion','B4F168_V1',
      'removedObjective','HOME_LOCATION_VIOLATIONS',
      'historicalMatrixPreserved',true
    ));
end;
$$;

notify pgrst,'reload schema';
