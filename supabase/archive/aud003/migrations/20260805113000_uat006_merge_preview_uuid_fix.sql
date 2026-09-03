-- Runtime correction found by the deployed UAT-006 RPC smoke test.
-- PostgreSQL does not define min(uuid); location_id is already part of the
-- grouping key, so return it directly from the grouped row.

create or replace function public.matrix_v2_merge_equivalent_shifts_uat_v2(
  p_apply boolean default false
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_matrix uuid; v_groups integer:=0; v_duplicates integer:=0;
  v_blockers jsonb:='[]'::jsonb; v_preview jsonb:='[]'::jsonb;
  group_row record; rule_row public.matrix_staffing_rules_v2%rowtype;
  v_existing public.matrix_staffing_rules_v2%rowtype;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  select version.id into v_matrix from public.matrix_versions version
  where version.status='DRAFT' and version.schema_version>=2
  order by version.version desc limit 1;
  if v_matrix is null then raise exception 'NO_MATRIX_V2_DRAFT'; end if;

  with groups as (
    select min(shift.id::text)::uuid survivor_id,
      array_agg(shift.id order by shift.sort_order,shift.id) ids,
      min(shift.name) name,shift.location_id,
      min(shift.starts_at) starts_at,min(shift.ends_at) ends_at,
      count(*) amount
    from public.matrix_shift_templates_v2 shift
    where shift.matrix_version_id=v_matrix and shift.active
    group by shift.location_id,lower(trim(shift.name)),shift.starts_at,
      shift.ends_at,shift.ends_next_day
    having count(*)>1
  )
  select count(*),coalesce(sum(amount-1),0),coalesce(jsonb_agg(jsonb_build_object(
    'name',name,'locationId',location_id,'startsAt',starts_at,'endsAt',ends_at,
    'entries',amount,'survivorId',survivor_id,'ids',to_jsonb(ids)
  ) order by name),'[]'::jsonb)
  into v_groups,v_duplicates,v_preview from groups;

  with groups as (
    select (array_agg(shift.id order by shift.sort_order,shift.id))[1] survivor_id,
      (array_agg(shift.id order by shift.sort_order,shift.id))[2:] duplicate_ids
    from public.matrix_shift_templates_v2 shift
    where shift.matrix_version_id=v_matrix and shift.active
    group by shift.location_id,lower(trim(shift.name)),shift.starts_at,
      shift.ends_at,shift.ends_next_day having count(*)>1
  ), conflicts as (
    select jsonb_build_object('code','STAFFING_RULE_CONFLICT','message',
      'Powielone zmiany mają różne reguły obsady dla tego samego zakresu.') blocker
    from groups
    join public.matrix_staffing_rules_v2 duplicate
      on duplicate.shift_template_id=any(groups.duplicate_ids)
    join public.matrix_staffing_rules_v2 survivor
      on survivor.shift_template_id=groups.survivor_id
      and survivor.scenario_id=duplicate.scenario_id
      and survivor.role_id=duplicate.role_id
      and survivor.duty_id is not distinct from duplicate.duty_id
    where row(survivor.operation,survivor.count_value,
      survivor.multiplier_basis_points,survivor.active)
      is distinct from row(duplicate.operation,duplicate.count_value,
        duplicate.multiplier_basis_points,duplicate.active)
    union all
    select jsonb_build_object('code','EVENT_DEMAND_REFERENCE','message',
      'Co najmniej jeden powielony wpis jest używany przez aktywny event.')
    from groups join public.workforce_event_demand_v2 demand
      on demand.shift_template_id=any(groups.duplicate_ids)
    join public.workforce_calendar_events_v2 event on event.id=demand.event_id
    where event.status='ACTIVE'
  )
  select coalesce(jsonb_agg(distinct blocker),'[]'::jsonb)
    into v_blockers from conflicts;

  if not p_apply then return jsonb_build_object(
    'matrixVersionId',v_matrix,'groups',v_groups,'duplicates',v_duplicates,
    'items',v_preview,'blockers',v_blockers,'applied',false
  ); end if;
  if jsonb_array_length(v_blockers)>0 then
    raise exception 'SHIFT_MERGE_BLOCKED:%',v_blockers::text;
  end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));

  for group_row in
    select (array_agg(shift.id order by shift.sort_order,shift.id))[1] survivor_id,
      (array_agg(shift.id order by shift.sort_order,shift.id))[2:] duplicate_ids,
      array_agg(distinct day_value order by day_value)::smallint[] merged_days
    from public.matrix_shift_templates_v2 shift
    cross join lateral unnest(shift.day_mask) day_value
    where shift.matrix_version_id=v_matrix and shift.active
    group by shift.location_id,lower(trim(shift.name)),shift.starts_at,
      shift.ends_at,shift.ends_next_day having count(distinct shift.id)>1
  loop
    update public.matrix_shift_templates_v2 set day_mask=group_row.merged_days,
      shift_period=case when extract(hour from starts_at)<12 then 'MORNING'
        when extract(hour from starts_at)<17 then 'MIDDLE' else 'EVENING' end,
      updated_at=now() where id=group_row.survivor_id;

    for rule_row in select * from public.matrix_staffing_rules_v2
      where shift_template_id=any(group_row.duplicate_ids)
    loop
      select * into v_existing from public.matrix_staffing_rules_v2 existing
      where existing.shift_template_id=group_row.survivor_id
        and existing.scenario_id=rule_row.scenario_id
        and existing.role_id=rule_row.role_id
        and existing.duty_id is not distinct from rule_row.duty_id limit 1;
      if v_existing.id is null then
        update public.matrix_staffing_rules_v2
          set shift_template_id=group_row.survivor_id,updated_at=now()
        where id=rule_row.id;
      else
        delete from public.matrix_staffing_rules_v2 where id=rule_row.id;
      end if;
      v_existing:=null;
    end loop;

    insert into public.matrix_pay_rule_shifts_v2(
      matrix_version_id,pay_rule_id,shift_template_id
    ) select distinct mapping.matrix_version_id,mapping.pay_rule_id,
      group_row.survivor_id
    from public.matrix_pay_rule_shifts_v2 mapping
    where mapping.shift_template_id=any(group_row.duplicate_ids)
    on conflict do nothing;
    delete from public.matrix_pay_rule_shifts_v2 mapping
      where mapping.shift_template_id=any(group_row.duplicate_ids);
    update public.matrix_shift_templates_v2 set active=false,updated_at=now()
      where id=any(group_row.duplicate_ids);
  end loop;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_v2_shifts',v_matrix::text,'MERGE_EQUIVALENT_SHIFTS',
    jsonb_build_object('groups',v_groups,'duplicates',v_duplicates,'items',v_preview));
  return jsonb_build_object(
    'matrixVersionId',v_matrix,'groups',v_groups,'duplicates',v_duplicates,
    'items',v_preview,'blockers','[]'::jsonb,'applied',true
  );
end;
$$;

revoke all on function public.matrix_v2_merge_equivalent_shifts_uat_v2(boolean)
from public,anon,authenticated;
grant execute on function public.matrix_v2_merge_equivalent_shifts_uat_v2(boolean)
to authenticated;

notify pgrst,'reload schema';
