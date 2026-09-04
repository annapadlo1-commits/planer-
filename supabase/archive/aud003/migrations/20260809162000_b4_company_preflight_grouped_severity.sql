-- Classify a critical gap only when a shift has zero people in the required role.
-- Multiple empty seats on one shift are presented as one decision with a missing count.
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

  with issue_groups as (
    select min(issue.id)::text issue_id, issue.variant_id, issue.shift_id, issue.role_id,
      count(*)::integer missing_count,
      string_agg(distinct coalesce(issue.message, 'Nieobsadzone miejsce w wymaganej obsadzie.'), ' ') message
    from public.plan_issues_v2 issue
    where issue.variant_id = any(p_variant_ids)
      and issue.issue_code = 'UNFILLED_SLOT'
      and greatest(coalesce(issue.required_count, 0) - coalesce(issue.assigned_count, 0), 0) > 0
    group by issue.variant_id, issue.shift_id, issue.role_id
  ), gaps as (
    select grouped.issue_id, grouped.variant_id, shift.shift_date,
      to_char(shift.starts_at at time zone coalesce(location.timezone, 'Europe/Warsaw'), 'HH24:MI') starts_at,
      to_char(shift.ends_at at time zone coalesce(location.timezone, 'Europe/Warsaw'), 'HH24:MI') ends_at,
      coalesce(location.name, 'Lokal') location_name,
      coalesce(role.name, 'Rola') role_name,
      grouped.missing_count,
      assigned.assigned_count + grouped.missing_count required_count,
      assigned.assigned_count,
      assigned.assigned_count = 0 critical,
      grouped.message
    from issue_groups grouped
    join public.plan_shifts_v2 shift on shift.id = grouped.shift_id
    left join public.matrix_locations_v2 location on location.id = shift.location_id
    left join public.matrix_roles_v2 role on role.id = grouped.role_id
    cross join lateral (
      select count(*)::integer assigned_count
      from public.plan_assignments_v2 assignment
      where assignment.variant_id = grouped.variant_id
        and assignment.shift_id = grouped.shift_id
        and assignment.role_id = grouped.role_id
    ) assigned
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

revoke all on function public.optimizer_role_composite_preflight_uat_v2(date, uuid, uuid[]) from public;
grant execute on function public.optimizer_role_composite_preflight_uat_v2(date, uuid, uuid[]) to authenticated, service_role;
