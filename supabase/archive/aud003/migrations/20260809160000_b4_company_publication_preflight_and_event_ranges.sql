-- B4/B5 UAT: auditable company publication with gaps and multi-day operational events.
-- UAT project only until the user explicitly accepts promotion.

create or replace function public.optimizer_role_composite_preflight_uat_v2(
  p_month date,
  p_scenario_id uuid,
  p_variant_ids uuid[]
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_month date := date_trunc('month', p_month)::date;
  v_total integer := 0;
  v_critical integer := 0;
  v_gaps jsonb := '[]'::jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  if p_scenario_id is null then raise exception 'SCENARIO_REQUIRED'; end if;
  if coalesce(cardinality(p_variant_ids), 0) = 0 then raise exception 'VARIANTS_REQUIRED'; end if;

  if exists (
    select 1
    from public.plan_variants_v2 variant
    join public.optimization_runs_v2 run on run.id = variant.run_id
    where variant.id = any(p_variant_ids)
      and (run.month <> v_month or run.scenario_id <> p_scenario_id)
  ) then raise exception 'ROLE_COMPOSITE_REFERENCE_MISMATCH'; end if;

  with gaps as (
    select issue.id issue_id, issue.variant_id, shift.shift_date,
      to_char(shift.starts_at at time zone coalesce(location.timezone, 'Europe/Warsaw'), 'HH24:MI') starts_at,
      to_char(shift.ends_at at time zone coalesce(location.timezone, 'Europe/Warsaw'), 'HH24:MI') ends_at,
      coalesce(location.name, 'Lokal') location_name,
      coalesce(role.name, 'Rola') role_name,
      greatest(coalesce(issue.required_count, 0) - coalesce(issue.assigned_count, 0), 0) missing_count,
      coalesce(issue.required_count, 0) required_count,
      coalesce(issue.assigned_count, 0) assigned_count,
      coalesce(issue.assigned_count, 0) = 0 critical,
      coalesce(issue.message, 'Nieobsadzone miejsce w wymaganej obsadzie.') message
    from public.plan_issues_v2 issue
    join public.plan_shifts_v2 shift on shift.id = issue.shift_id
    left join public.matrix_locations_v2 location on location.id = shift.location_id
    left join public.matrix_roles_v2 role on role.id = issue.role_id
    where issue.variant_id = any(p_variant_ids)
      and issue.issue_code = 'UNFILLED_SLOT'
      and greatest(coalesce(issue.required_count, 0) - coalesce(issue.assigned_count, 0), 0) > 0
  )
  select coalesce(sum(gap.missing_count), 0)::integer,
    coalesce(sum(gap.missing_count) filter (where gap.critical), 0)::integer,
    coalesce(jsonb_agg(jsonb_build_object(
      'issueId', gap.issue_id,
      'variantId', gap.variant_id,
      'date', gap.shift_date,
      'startsAt', gap.starts_at,
      'endsAt', gap.ends_at,
      'location', gap.location_name,
      'role', gap.role_name,
      'requiredCount', gap.required_count,
      'assignedCount', gap.assigned_count,
      'missingCount', gap.missing_count,
      'critical', gap.critical,
      'message', gap.message
    ) order by gap.shift_date, gap.starts_at, gap.location_name, gap.role_name), '[]'::jsonb)
  into v_total, v_critical, v_gaps
  from gaps gap;

  return jsonb_build_object(
    'month', v_month,
    'scenarioId', p_scenario_id,
    'totalGaps', v_total,
    'criticalGaps', v_critical,
    'gaps', v_gaps
  );
end;
$function$;

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
  v_preflight jsonb;
  v_gap_count integer;
  v_critical_count integer;
  v_result jsonb;
  v_schedule_id uuid;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;

  v_preflight := public.optimizer_role_composite_preflight_uat_v2(
    p_month, p_scenario_id, p_variant_ids
  );
  v_gap_count := coalesce((v_preflight->>'totalGaps')::integer, 0);
  v_critical_count := coalesce((v_preflight->>'criticalGaps')::integer, 0);
  if v_gap_count > 0 and length(trim(coalesce(p_warning_reason, ''))) < 10 then
    raise exception 'WARNING_REASON_REQUIRED';
  end if;

  v_result := public.optimizer_publish_role_composite_v2(
    p_month, p_scenario_id, p_variant_ids, p_name, p_idempotency_key
  );
  v_schedule_id := coalesce(
    nullif(v_result->>'scheduleId', '')::uuid,
    nullif(v_result->>'schedule_id', '')::uuid
  );
  if v_schedule_id is null then raise exception 'SCHEDULE_ID_MISSING'; end if;

  update public.published_schedules_v2 schedule
  set validation_summary = coalesce(schedule.validation_summary, '{}'::jsonb)
    || jsonb_build_object('gapAcceptance', jsonb_build_object(
      'accepted', v_gap_count > 0,
      'totalGaps', v_gap_count,
      'criticalGaps', v_critical_count,
      'reason', nullif(trim(coalesce(p_warning_reason, '')), ''),
      'acceptedBy', v_actor,
      'acceptedAt', now()
    ))
  where schedule.id = v_schedule_id;

  if v_gap_count > 0 then
    insert into public.audit_log(actor_id, entity_type, entity_id, action, new_data)
    values(v_actor, 'published_schedule_v2', v_schedule_id::text,
      'PUBLISH_WITH_GAPS_ACCEPTED', jsonb_build_object(
        'month', date_trunc('month', p_month)::date,
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
    'criticalGaps', v_critical_count
  );
end;
$function$;

create or replace function public.workforce_calendar_event_range_save_uat_v2(
  p_month date,
  p_start_date date,
  p_end_date date,
  p_event_kind text,
  p_title text,
  p_description text,
  p_location_id uuid,
  p_demands jsonb default '[]'::jsonb,
  p_hot_limits jsonb default '[]'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_date date;
  v_result jsonb;
  v_rows jsonb := '[]'::jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  if p_start_date is null or p_end_date is null or p_end_date < p_start_date then
    raise exception 'INVALID_DATE_RANGE';
  end if;
  if p_start_date < date_trunc('month', p_month)::date
    or p_end_date >= (date_trunc('month', p_month) + interval '1 month')::date then
    raise exception 'EVENT_RANGE_OUTSIDE_MONTH';
  end if;
  if p_end_date - p_start_date > 30 then raise exception 'EVENT_RANGE_TOO_LONG'; end if;

  for v_date in select generate_series(p_start_date, p_end_date, interval '1 day')::date loop
    v_result := public.workforce_calendar_event_save_uat_v2(
      null, p_month, v_date, p_event_kind, p_title, p_description,
      p_location_id, p_demands, p_hot_limits
    );
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'date', v_date, 'id', v_result->>'id', 'saved', true
    ));
  end loop;

  return jsonb_build_object(
    'saved', true,
    'startDate', p_start_date,
    'endDate', p_end_date,
    'count', jsonb_array_length(v_rows),
    'events', v_rows
  );
end;
$function$;

revoke all on function public.optimizer_role_composite_preflight_uat_v2(date, uuid, uuid[]) from public;
revoke all on function public.optimizer_publish_role_composite_uat_v3(date, uuid, uuid[], text, text, text) from public;
revoke all on function public.workforce_calendar_event_range_save_uat_v2(date, date, date, text, text, text, uuid, jsonb, jsonb) from public;
grant execute on function public.optimizer_role_composite_preflight_uat_v2(date, uuid, uuid[]) to authenticated, service_role;
grant execute on function public.optimizer_publish_role_composite_uat_v3(date, uuid, uuid[], text, text, text) to authenticated, service_role;
grant execute on function public.workforce_calendar_event_range_save_uat_v2(date, date, date, text, text, text, uuid, jsonb, jsonb) to authenticated, service_role;
