-- B4F-64 UAT: the deferred publication guard must validate every role stored
-- in a category variant's immutable scope, not only its stable anchor role.
create or replace function solver_private.role_composite_consistency_guard_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_schedule public.published_schedules_v2%rowtype;
begin
  select schedule.* into v_schedule
  from public.published_schedules_v2 schedule
  where schedule.id=coalesce(new.schedule_id,old.schedule_id);
  if v_schedule.source_type<>'ROLE_COMPOSITE' or v_schedule.status<>'PUBLISHED' then
    return null;
  end if;
  if exists(
    select 1 from public.published_schedule_variants_v2 link
    where link.schedule_id=v_schedule.id and (
      link.role_id is null or not exists(
        select 1 from public.published_role_schedules_v2 role_schedule
        where role_schedule.month=v_schedule.month
          and role_schedule.role_id=link.role_id
          and role_schedule.variant_id=link.variant_id
          and role_schedule.status='PUBLISHED'
      )
    )
  ) then
    raise exception 'ROLE_COMPOSITE_CONTAINS_NONCURRENT_ROLE_VARIANT';
  end if;
  if exists(
    select 1
    from (
      select distinct demand.role_id
      from solver_private.resolved_demand_v2(
        v_schedule.month,
        v_schedule.matrix_version_id,
        v_schedule.scenario_id,
        null
      ) demand
    ) demanded
    where not exists(
      select 1
      from public.published_schedule_variants_v2 link
      join public.plan_variants_v2 variant on variant.id=link.variant_id
      join public.optimization_runs_v2 run on run.id=variant.run_id
      join solver_private.optimization_snapshots_v2 run_snapshot on run_snapshot.run_id=run.id
      cross join lateral jsonb_array_elements_text(
        case
          when jsonb_typeof(run_snapshot.snapshot->'scope'->'roleIds')='array'
            and jsonb_array_length(run_snapshot.snapshot->'scope'->'roleIds')>0
            then run_snapshot.snapshot->'scope'->'roleIds'
          else jsonb_build_array(link.role_id::text)
        end
      ) covered_role(role_id)
      where link.schedule_id=v_schedule.id
        and covered_role.role_id=demanded.role_id::text
    )
  ) then
    raise exception 'ROLE_COMPOSITE_REQUIRES_EVERY_DEMANDED_ROLE';
  end if;
  return null;
end;
$function$;

comment on function solver_private.role_composite_consistency_guard_v2() is
  'Deferred ROLE_COMPOSITE guard: every demanded role must be covered by a current published category or role variant, using immutable snapshot scope roleIds.';
