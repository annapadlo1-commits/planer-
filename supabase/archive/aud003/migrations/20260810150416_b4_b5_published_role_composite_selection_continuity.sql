-- B4+B5 UAT: a published role schedule remains a valid merge source even when
-- a later leader copy is currently selected in the same optimization run.
create or replace function public.optimizer_publish_role_composite_uat_v3(
  p_month date,
  p_scenario_id uuid,
  p_variant_ids uuid[],
  p_name text,
  p_idempotency_key text,
  p_warning_reason text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actor uuid := auth.uid();
  v_month date := date_trunc('month', p_month)::date;
  v_preflight jsonb;
  v_gap_count integer;
  v_critical_count integer;
  v_result jsonb;
  v_schedule_id uuid;
  v_published_count integer;
  v_source_run_id uuid;
  v_temporarily_selected uuid[] := '{}'::uuid[];
  v_temporarily_deselected uuid[] := '{}'::uuid[];
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  if p_variant_ids is null or cardinality(p_variant_ids) = 0 then
    raise exception 'PUBLISHED_ROLE_VARIANTS_REQUIRED';
  end if;
  if cardinality(p_variant_ids) <> (
    select count(distinct variant_id)
    from unnest(p_variant_ids) as variant_id
  ) then
    raise exception 'DUPLICATE_ROLE_VARIANTS';
  end if;

  v_preflight := public.optimizer_role_composite_preflight_uat_v2(
    v_month, p_scenario_id, p_variant_ids
  );
  v_gap_count := coalesce((v_preflight->>'totalGaps')::integer, 0);
  v_critical_count := coalesce((v_preflight->>'criticalGaps')::integer, 0);
  if v_gap_count > 0 and length(trim(coalesce(p_warning_reason, ''))) < 10 then
    raise exception 'WARNING_REASON_REQUIRED';
  end if;

  -- Only variants that are the current published source of a role schedule may
  -- bypass the transient `selected` marker. This prevents arbitrary or stale
  -- drafts from entering the company publication.
  select count(*)
  into v_published_count
  from public.published_role_schedules_v2 role_schedule
  where role_schedule.month = v_month
    and role_schedule.scenario_id = p_scenario_id
    and role_schedule.status = 'PUBLISHED'
    and role_schedule.variant_id = any(p_variant_ids);
  if v_published_count <> cardinality(p_variant_ids) then
    raise exception 'PUBLISHED_ROLE_VARIANTS_REQUIRED';
  end if;

  -- Serialize with every normal selection operation for the affected runs.
  -- The old selection is restored after publication, so the leader's newer
  -- working copy remains current while the published role source is merged.
  for v_source_run_id in
    select distinct variant.run_id
    from public.plan_variants_v2 variant
    where variant.id = any(p_variant_ids)
    order by variant.run_id
  loop
    perform pg_advisory_xact_lock(hashtextextended(
      'select-v2:' || v_source_run_id::text, 0
    ));
  end loop;

  select coalesce(array_agg(variant.id order by variant.id), '{}'::uuid[])
  into v_temporarily_deselected
  from public.plan_variants_v2 variant
  where variant.selected
    and variant.id <> all(p_variant_ids)
    and variant.run_id in (
      select source_variant.run_id
      from public.plan_variants_v2 source_variant
      where source_variant.id = any(p_variant_ids)
    );

  select coalesce(array_agg(variant.id order by variant.id), '{}'::uuid[])
  into v_temporarily_selected
  from public.plan_variants_v2 variant
  where variant.id = any(p_variant_ids)
    and not variant.selected;

  update public.plan_variants_v2 variant
  set selected = false
  where variant.id = any(v_temporarily_deselected);

  update public.plan_variants_v2 variant
  set selected = true
  where variant.id = any(p_variant_ids);

  v_result := public.optimizer_publish_role_composite_v2(
    v_month, p_scenario_id, p_variant_ids, p_name, p_idempotency_key
  );

  update public.plan_variants_v2 variant
  set selected = false
  where variant.id = any(v_temporarily_selected);

  update public.plan_variants_v2 variant
  set selected = true
  where variant.id = any(v_temporarily_deselected);

  v_schedule_id := coalesce(
    nullif(v_result->>'scheduleId', '')::uuid,
    nullif(v_result->>'schedule_id', '')::uuid
  );
  if v_schedule_id is null then raise exception 'SCHEDULE_ID_MISSING'; end if;

  update public.published_schedules_v2 schedule
  set validation_summary = coalesce(schedule.validation_summary, '{}'::jsonb)
    || jsonb_build_object(
      'gapAcceptance', jsonb_build_object(
        'accepted', v_gap_count > 0,
        'totalGaps', v_gap_count,
        'criticalGaps', v_critical_count,
        'reason', nullif(trim(coalesce(p_warning_reason, '')), ''),
        'acceptedBy', v_actor,
        'acceptedAt', now()
      ),
      'publishedSourceContinuity', jsonb_build_object(
        'scenarioId', p_scenario_id,
        'variantIds', to_jsonb(p_variant_ids),
        'leaderSelectionRestored', true
      )
    )
  where schedule.id = v_schedule_id;

  if v_gap_count > 0 then
    insert into public.audit_log(actor_id, entity_type, entity_id, action, new_data)
    values(v_actor, 'published_schedule_v2', v_schedule_id::text,
      'PUBLISH_WITH_GAPS_ACCEPTED', jsonb_build_object(
        'month', v_month,
        'scenarioId', p_scenario_id,
        'totalGaps', v_gap_count,
        'criticalGaps', v_critical_count,
        'reason', trim(p_warning_reason),
        'variantIds', to_jsonb(p_variant_ids)
      ));
  end if;

  return v_result || jsonb_build_object(
    'gapAcceptanceRequired', v_gap_count > 0,
    'totalGaps', v_gap_count,
    'criticalGaps', v_critical_count,
    'publishedSourceContinuity', true
  );
end;
$function$;

revoke all on function public.optimizer_publish_role_composite_uat_v3(
  date, uuid, uuid[], text, text, text
) from public;
grant execute on function public.optimizer_publish_role_composite_uat_v3(
  date, uuid, uuid[], text, text, text
) to authenticated, service_role;

comment on function public.optimizer_publish_role_composite_uat_v3(
  date, uuid, uuid[], text, text, text
) is 'Publishes exactly the role variants currently exposed by published role schedules, temporarily restoring their selection only inside the transaction and restoring any newer leader selection afterwards.';
