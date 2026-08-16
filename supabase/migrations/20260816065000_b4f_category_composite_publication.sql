-- B4F-64 UAT: category runs contain every role in one solver variant. The
-- legacy company publisher compared demanded roles only with each run's
-- anchor role, so five complete category publications were rejected as if
-- the remaining roles had never been generated.
create or replace function solver_private.optimizer_publish_role_composite_pre_version_fence_v2(
  p_month date,
  p_scenario_id uuid,
  p_variant_ids uuid[],
  p_name text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actor uuid := auth.uid();
  v_month date := date_trunc('month',p_month)::date;
  v_variant_ids uuid[];
  v_existing public.published_schedules_v2%rowtype;
  v_existing_ids uuid[];
  v_schedule_id uuid := gen_random_uuid();
  v_matrix_ids uuid[];
  v_scenario_ids uuid[];
  v_months date[];
  v_count integer;
  v_role_count integer;
  v_matrix_version_id uuid;
  v_validation_run_id uuid;
  v_strategy_id uuid;
  v_company_snapshot jsonb;
  v_combined_payload jsonb;
  v_combined_validation jsonb;
  v_validation jsonb;
  v_publication_hash text;
  v_variant_id uuid;
  v_base_units bigint;
  v_total_units bigint;
  v_currency text;
  v_engine text;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select flag.engine into v_engine
  from public.solver_feature_flags flag
  where flag.flag_key='DEFAULT_ENGINE' and flag.enabled;
  if v_engine is null then raise exception 'SOLVER_ENGINE_CONFIGURATION_MISSING'; end if;
  if v_engine<>'ORTOOLS_V2' then raise exception 'ORTOOLS_PUBLICATION_DISABLED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'COMPOSITE_PUBLICATION_FORBIDDEN';
  end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  if p_scenario_id is null then raise exception 'SCENARIO_REQUIRED'; end if;
  if length(coalesce(p_idempotency_key,'')) not between 8 and 200 then
    raise exception 'INVALID_IDEMPOTENCY_KEY';
  end if;
  if length(trim(coalesce(p_name,''))) not between 1 and 200 then
    raise exception 'INVALID_PLAN_NAME';
  end if;
  if coalesce(cardinality(p_variant_ids),0)=0
    or cardinality(p_variant_ids)>200 then
    raise exception 'INVALID_VARIANT_SET';
  end if;
  select array_agg(x.variant_id order by x.variant_id::text)
  into v_variant_ids
  from (select distinct unnest(p_variant_ids) variant_id) x;
  if cardinality(v_variant_ids)<>cardinality(p_variant_ids)
    or array_position(v_variant_ids,null) is not null then
    raise exception 'DUPLICATE_OR_NULL_VARIANT';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'publish-v2-key:'||v_actor::text||':'||p_idempotency_key,0
  ));
  select * into v_existing
  from public.published_schedules_v2 s
  where s.created_by=v_actor and s.idempotency_key=p_idempotency_key;
  if v_existing.id is not null then
    select array_agg(sv.variant_id order by sv.variant_id::text)
    into v_existing_ids
    from public.published_schedule_variants_v2 sv
    where sv.schedule_id=v_existing.id;
    if v_existing.source_type<>'ROLE_COMPOSITE'
      or v_existing.month<>v_month
      or v_existing.scenario_id<>p_scenario_id
      or v_existing.name<>trim(p_name)
      or v_existing_ids is distinct from v_variant_ids then
      raise exception 'IDEMPOTENCY_KEY_REUSED';
    end if;
    return jsonb_build_object(
      'scheduleId',v_existing.id,'status',v_existing.status,
      'sourceType',v_existing.source_type,'reused',true
    );
  end if;

  perform solver_private.lock_planning_revision_v2();
  perform pg_advisory_xact_lock(hashtextextended(
    'publish-v2-month:'||v_month::text,0
  ));
  for v_validation_run_id in
    select distinct v.run_id
    from public.plan_variants_v2 v
    where v.id=any(v_variant_ids)
    order by v.run_id
  loop
    perform pg_advisory_xact_lock(hashtextextended(
      'select-v2:'||v_validation_run_id::text,0
    ));
  end loop;

  perform 1
  from public.plan_variants_v2 v
  join public.optimization_runs_v2 r on r.id=v.run_id
  where v.id=any(v_variant_ids)
  order by v.id::text
  for update of v,r;

  if exists(
    select 1
    from public.plan_variants_v2 v
    join public.optimization_runs_v2 r on r.id=v.run_id
    where v.id=any(v_variant_ids)
      and r.request_engine<>'ORTOOLS_V2'
  ) then raise exception 'SHADOW_RUN_NOT_PUBLISHABLE'; end if;

  select count(*),count(distinct r.scope_role_id),
    array_agg(distinct r.matrix_version_id),
    array_agg(distinct r.scenario_id),
    array_agg(distinct r.month)
  into v_count,v_role_count,v_matrix_ids,v_scenario_ids,v_months
  from public.plan_variants_v2 v
  join public.optimization_runs_v2 r on r.id=v.run_id
  where v.id=any(v_variant_ids)
    and v.selected and v.hard_violations=0
    and v.status in ('SELECTED','PUBLISHED')
    and r.status='READY' and r.scope_type='ROLE';
  if v_count<>cardinality(v_variant_ids)
    or v_role_count<>cardinality(v_variant_ids) then
    raise exception 'ONE_SELECTED_ROLE_VARIANT_PER_ROLE_REQUIRED';
  end if;
  if cardinality(v_matrix_ids)<>1 or cardinality(v_scenario_ids)<>1
    or cardinality(v_months)<>1
    or v_months[1]<>v_month or v_scenario_ids[1]<>p_scenario_id then
    raise exception 'ROLE_VARIANTS_SCOPE_MISMATCH';
  end if;
  v_matrix_version_id := v_matrix_ids[1];
  select v.run_id into v_validation_run_id
  from public.plan_variants_v2 v
  where v.id=any(v_variant_ids)
  order by v.run_id::text limit 1;

  foreach v_variant_id in array v_variant_ids loop
    v_validation := solver_private.revalidate_materialized_variant_v2(
      v_variant_id,true,false
    );
  end loop;

  v_company_snapshot := solver_private.build_snapshot_payload_v2(
    v_validation_run_id,v_month,v_matrix_version_id,p_scenario_id,'COMPANY',null
  );
  v_company_snapshot := jsonb_set(
    v_company_snapshot,'{baselineAssignments}','[]'::jsonb,true
  );
  v_currency := upper(nullif(v_company_snapshot->>'currency',''));
  if v_currency is null or v_currency !~ '^[A-Z]{3}$' then
    raise exception 'SNAPSHOT_CURRENCY_REQUIRED';
  end if;

  -- A category run is still stored with one stable anchor role in
  -- optimization_runs_v2.scope_role_id. Its immutable snapshot is the
  -- authoritative record of every role covered by that variant.
  if exists(
    select slot.value->>'roleId'
    from jsonb_array_elements(coalesce(v_company_snapshot->'slots','[]'::jsonb)) slot
    group by slot.value->>'roleId'
    except
    select covered_role.role_id
    from public.plan_variants_v2 variant
    join public.optimization_runs_v2 run on run.id=variant.run_id
    join solver_private.optimization_snapshots_v2 run_snapshot on run_snapshot.run_id=run.id
    cross join lateral jsonb_array_elements_text(
      case
        when jsonb_typeof(run_snapshot.snapshot->'scope'->'roleIds')='array'
          and jsonb_array_length(run_snapshot.snapshot->'scope'->'roleIds')>0
          then run_snapshot.snapshot->'scope'->'roleIds'
        else jsonb_build_array(run.scope_role_id::text)
      end
    ) covered_role(role_id)
    where variant.id=any(v_variant_ids)
    group by covered_role.role_id
  ) then raise exception 'ALL_DEMANDED_ROLES_REQUIRED'; end if;

  -- Category scopes may not overlap: otherwise the same role could be
  -- materialized twice in the company schedule.
  if (
    select count(*)<>count(distinct covered_role.role_id)
    from public.plan_variants_v2 variant
    join public.optimization_runs_v2 run on run.id=variant.run_id
    join solver_private.optimization_snapshots_v2 run_snapshot on run_snapshot.run_id=run.id
    cross join lateral jsonb_array_elements_text(
      case
        when jsonb_typeof(run_snapshot.snapshot->'scope'->'roleIds')='array'
          and jsonb_array_length(run_snapshot.snapshot->'scope'->'roleIds')>0
          then run_snapshot.snapshot->'scope'->'roleIds'
        else jsonb_build_array(run.scope_role_id::text)
      end
    ) covered_role(role_id)
    where variant.id=any(v_variant_ids)
  ) then raise exception 'OVERLAPPING_CATEGORY_VARIANTS'; end if;

  v_strategy_id := nullif(v_company_snapshot->'strategies'->0->>'id','')::uuid;
  if v_strategy_id is null then raise exception 'SCENARIO_HAS_NO_STRATEGIES'; end if;
  v_publication_hash := encode(extensions.digest(convert_to(
    solver_private.canonical_json_v2(jsonb_build_object(
      'sourceType','ROLE_COMPOSITE','month',v_month,
      'matrixVersionId',v_matrix_version_id,'scenarioId',p_scenario_id,
      'variants',(
        select jsonb_agg(jsonb_build_object(
          'variantId',v.id,'solutionHash',v.solution_hash,
          'roleId',r.scope_role_id,
          'roleIds',coalesce(
            run_snapshot.snapshot->'scope'->'roleIds',
            jsonb_build_array(r.scope_role_id::text)
          )
        ) order by r.scope_role_id::text,v.id::text)
        from public.plan_variants_v2 v
        join public.optimization_runs_v2 r on r.id=v.run_id
        join solver_private.optimization_snapshots_v2 run_snapshot on run_snapshot.run_id=r.id
        where v.id=any(v_variant_ids)
      )
    )),'UTF8'
  ),'sha256'),'hex');
  v_combined_payload := solver_private.materialized_variant_payload_v2(
    v_variant_ids,v_company_snapshot,v_strategy_id
  );
  v_combined_payload := solver_private.requote_variant_payload_v2(
    v_company_snapshot,v_combined_payload
  );
  v_combined_validation := solver_private.validate_variant_v2(
    v_company_snapshot,v_combined_payload
  );

  perform solver_private.archive_current_publication_v2(
    v_month,v_variant_ids,v_actor
  );
  insert into public.published_schedules_v2(
    id,idempotency_key,month,matrix_version_id,scenario_id,source_type,
    name,status,publication_hash,validation_snapshot_hash,
    validation_summary,created_by
  ) values(
    v_schedule_id,p_idempotency_key,v_month,v_matrix_version_id,p_scenario_id,
    'ROLE_COMPOSITE',trim(p_name),'PUBLISHED',v_publication_hash,
    solver_private.publication_snapshot_hash_v2(v_company_snapshot),
    v_combined_validation-'totalCostUnits'-'budgetMinor',v_actor
  );
  insert into public.published_schedule_variants_v2(
    schedule_id,variant_id,role_id,ordinal
  )
  select v_schedule_id,v.id,r.scope_role_id,
    (row_number() over(order by role.sort_order,role.name,r.scope_role_id::text))::integer
  from public.plan_variants_v2 v
  join public.optimization_runs_v2 r on r.id=v.run_id
  join public.matrix_roles_v2 role on role.id=r.scope_role_id
  where v.id=any(v_variant_ids)
  order by role.sort_order,role.name,r.scope_role_id::text;
  select
    coalesce((
      select sum((component.value->>'costUnits')::bigint)
      from jsonb_array_elements(
        coalesce(v_combined_payload->'assignments','[]'::jsonb)
      ) assignment
      cross join lateral jsonb_array_elements(
        coalesce(assignment.value->'costComponents','[]'::jsonb)
      ) component
      where component.value->>'ruleId'='BASE'
    ),0),
    coalesce((
      select sum((assignment.value->>'costUnits')::bigint)
      from jsonb_array_elements(
        coalesce(v_combined_payload->'assignments','[]'::jsonb)
      ) assignment
    ),0)
  into v_base_units,v_total_units;
  insert into solver_private.published_schedule_finance_v2(
    schedule_id,base_cost_units,additions_cost_units,total_cost_units,
    base_cost_minor,additions_cost_minor,total_cost_minor,currency,
    budget_minor,hard_budget
  ) values(
    v_schedule_id,v_base_units,greatest(v_total_units-v_base_units,0),v_total_units,
    round(v_base_units::numeric/60)::bigint,
    round(v_total_units::numeric/60)::bigint
      -round(v_base_units::numeric/60)::bigint,
    round(v_total_units::numeric/60)::bigint,
    v_currency,
    nullif(v_combined_validation->>'budgetMinor','')::bigint,
    coalesce((v_combined_validation->>'hardBudget')::boolean,false)
  );
  update public.plan_variants_v2
  set status='PUBLISHED',published_at=now()
  where id=any(v_variant_ids);
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'published_schedule_v2',v_schedule_id::text,
    'PUBLISH_ROLE_COMPOSITE',jsonb_build_object(
      'month',v_month,'scenarioId',p_scenario_id,
      'matrixVersionId',v_matrix_version_id,
      'variantIds',to_jsonb(v_variant_ids),
      'publicationHash',v_publication_hash,
      'categoryAware',true
    ));
  return jsonb_build_object(
    'scheduleId',v_schedule_id,'status','PUBLISHED',
    'sourceType','ROLE_COMPOSITE','variantCount',cardinality(v_variant_ids),
    'categoryAware',true,'reused',false
  );
end;
$function$;

comment on function solver_private.optimizer_publish_role_composite_pre_version_fence_v2(
  date,uuid,uuid[],text,text
) is 'Publishes one validated variant per disjoint role or category scope and proves that their immutable roleIds cover every demanded company role.';
