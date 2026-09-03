-- B4 UAT: a role composite must cover every role demanded by the selected
-- month/scenario, not every active role in the company configuration.
create or replace function solver_private.role_composite_consistency_guard_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
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
      where link.schedule_id=v_schedule.id
        and link.role_id=demanded.role_id
    )
  ) then
    raise exception 'ROLE_COMPOSITE_REQUIRES_EVERY_DEMANDED_ROLE';
  end if;
  return null;
end;
$$;
