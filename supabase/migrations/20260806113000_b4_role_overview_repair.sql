-- B4 UAT follow-up: restore the manager role-publication overview used by the
-- role-first schedule screen. The historical migration contains this RPC, but
-- the UAT schema drifted and PostgREST returned 404 for every overview refresh.

create or replace function public.optimizer_role_publication_overview_uat_v2(
  p_month date
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_month date:=date_trunc('month',p_month)::date;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  with role_rows as (
    select publication.id publication_id,publication.name,
      publication.published_at,role.id role_id,role.name role_name,
      scenario.id scenario_id,scenario.name scenario_name,
      variant.id variant_id,variant.assignment_count,variant.unfilled_count,
      coalesce((variant.metrics->>'OVERTIME_MINUTES')::bigint,0) overtime_minutes,
      coalesce(finance.total_cost_minor,0) total_cost_minor,
      coalesce(finance.currency,'PLN') currency,
      coalesce((select count(distinct assignment.employee_id)
        from public.plan_assignments_v2 assignment
        where assignment.variant_id=variant.id),0)::integer team_size,
      coalesce((select sum(extract(epoch from
        (shift.ends_at-shift.starts_at))/60)::bigint
        from public.plan_assignments_v2 assignment
        join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
        where assignment.variant_id=variant.id),0) scheduled_minutes
    from public.published_role_schedules_v2 publication
    join public.matrix_roles_v2 role on role.id=publication.role_id
    join public.matrix_scenarios_v2 scenario on scenario.id=publication.scenario_id
    join public.plan_variants_v2 variant on variant.id=publication.variant_id
    left join solver_private.plan_variant_finance_v2 finance
      on finance.variant_id=variant.id
    where publication.month=v_month and publication.status='PUBLISHED'
  ), totals as (
    select count(*)::integer published_roles,
      coalesce(sum(assignment_count),0)::bigint assignment_count,
      coalesce(sum(unfilled_count),0)::bigint unfilled_count,
      coalesce(sum(overtime_minutes),0)::bigint overtime_minutes,
      coalesce(sum(total_cost_minor),0)::bigint total_cost_minor,
      coalesce(sum(scheduled_minutes),0)::bigint scheduled_minutes
    from role_rows
  )
  select jsonb_build_object(
    'month',v_month,
    'totals',jsonb_build_object(
      'publishedRoles',totals.published_roles,
      'assignmentCount',totals.assignment_count,
      'unfilledCount',totals.unfilled_count,
      'overtimeMinutes',totals.overtime_minutes,
      'totalCostMinor',totals.total_cost_minor,
      'scheduledMinutes',totals.scheduled_minutes
    ),
    'roles',coalesce((select jsonb_agg(jsonb_build_object(
      'publicationId',row.publication_id,'name',row.name,
      'publishedAt',row.published_at,
      'role',jsonb_build_object('id',row.role_id,'name',row.role_name),
      'scenario',jsonb_build_object('id',row.scenario_id,'name',row.scenario_name),
      'variantId',row.variant_id,'assignmentCount',row.assignment_count,
      'unfilledCount',row.unfilled_count,'overtimeMinutes',row.overtime_minutes,
      'totalCostMinor',row.total_cost_minor,'currency',row.currency,
      'teamSize',row.team_size,'scheduledMinutes',row.scheduled_minutes
    ) order by row.role_name) from role_rows row),'[]'::jsonb)
  ) into v_result from totals;
  return v_result;
end;
$$;

revoke all on function public.optimizer_role_publication_overview_uat_v2(date)
  from public,anon,authenticated;
grant execute on function public.optimizer_role_publication_overview_uat_v2(date)
  to authenticated;
