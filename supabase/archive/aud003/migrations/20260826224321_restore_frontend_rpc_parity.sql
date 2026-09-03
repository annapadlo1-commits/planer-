-- TECH-AUD-2026-08-25-005 / Phase 4
-- Restore the approved bulk staffing operation that has remained reachable in
-- the configuration UI since 8f3a967 but was omitted from the UAT migration
-- history. The implementation is preserved from the canonical source contract.

create or replace function public.matrix_v2_staffing_bulk_adjust_uat_v2(
  p_scenario_id uuid,
  p_location_id uuid default null,
  p_shift_period text default null,
  p_role_id uuid default null,
  p_delta integer default 1
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_matrix uuid;
  v_scenario uuid;
  v_location uuid;
  v_role uuid;
  v_period text:=nullif(upper(trim(coalesce(p_shift_period,''))), '');
  v_matching integer:=0;
  v_eligible integer:=0;
  v_updated integer:=0;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if p_scenario_id is null then raise exception 'SCENARIO_REQUIRED'; end if;
  if coalesce(p_delta,0)=0 or abs(p_delta)>20 then
    raise exception 'INVALID_STAFFING_BULK_DELTA';
  end if;
  if v_period is not null and v_period not in ('MORNING','MIDDLE','EVENING') then
    raise exception 'INVALID_SHIFT_PERIOD';
  end if;

  v_matrix:=public.matrix_v2_create_draft(null);
  select target.id into v_scenario
  from public.matrix_scenarios_v2 source
  join public.matrix_scenarios_v2 target
    on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
  where source.id=p_scenario_id;
  if v_scenario is null then raise exception 'SCENARIO_NOT_IN_MATRIX_V2'; end if;

  if p_location_id is not null then
    select target.id into v_location
    from public.matrix_locations_v2 source
    join public.matrix_locations_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=p_location_id;
    if v_location is null then raise exception 'LOCATION_NOT_IN_MATRIX_V2'; end if;
  end if;
  if p_role_id is not null then
    select target.id into v_role
    from public.matrix_roles_v2 source
    join public.matrix_roles_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=p_role_id;
    if v_role is null then raise exception 'ROLE_NOT_IN_MATRIX_V2'; end if;
  end if;

  -- Lock and validate the complete target set before changing any row.  This
  -- preserves the established staffing contracts: active SET rules require at
  -- least one person and ADD rules cannot carry a negative count.  A single
  -- invalid result aborts the whole bulk operation instead of being clamped.
  perform rule.id
  from public.matrix_staffing_rules_v2 rule
  join public.matrix_shift_templates_v2 shift
    on shift.id=rule.shift_template_id
  where rule.matrix_version_id=v_matrix and rule.scenario_id=v_scenario
    and rule.active and rule.operation in ('SET','ADD')
    and (v_location is null or shift.location_id=v_location)
    and (v_period is null or shift.shift_period=v_period)
    and (v_role is null or rule.role_id=v_role)
  for update of rule;

  select count(*),count(*) filter(where rule.operation in ('SET','ADD'))
  into v_matching,v_eligible
  from public.matrix_staffing_rules_v2 rule
  join public.matrix_shift_templates_v2 shift
    on shift.id=rule.shift_template_id
  where rule.matrix_version_id=v_matrix and rule.scenario_id=v_scenario
    and rule.active
    and (v_location is null or shift.location_id=v_location)
    and (v_period is null or shift.shift_period=v_period)
    and (v_role is null or rule.role_id=v_role);
  if v_eligible<1 then raise exception 'STAFFING_TARGET_NOT_FOUND'; end if;

  if exists(
    select 1
    from public.matrix_staffing_rules_v2 rule
    join public.matrix_shift_templates_v2 shift
      on shift.id=rule.shift_template_id
    where rule.matrix_version_id=v_matrix and rule.scenario_id=v_scenario
      and rule.active and rule.operation in ('SET','ADD')
      and (v_location is null or shift.location_id=v_location)
      and (v_period is null or shift.shift_period=v_period)
      and (v_role is null or rule.role_id=v_role)
      and (
        (rule.operation='SET' and coalesce(rule.count_value,0)+p_delta<1)
        or (rule.operation='ADD' and coalesce(rule.count_value,0)+p_delta<0)
      )
  ) then
    raise exception 'STAFFING_COUNT_BELOW_MINIMUM';
  end if;

  update public.matrix_staffing_rules_v2 rule set
    count_value=coalesce(rule.count_value,0)+p_delta,
    updated_at=now()
  from public.matrix_shift_templates_v2 shift
  where shift.id=rule.shift_template_id
    and rule.matrix_version_id=v_matrix and rule.scenario_id=v_scenario
    and rule.active and rule.operation in ('SET','ADD')
    and (v_location is null or shift.location_id=v_location)
    and (v_period is null or shift.shift_period=v_period)
    and (v_role is null or rule.role_id=v_role);
  get diagnostics v_updated=row_count;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_version',v_matrix::text,'BULK_ADJUST_STAFFING',
    jsonb_build_object(
      'scenarioId',v_scenario,'locationId',v_location,'shiftPeriod',v_period,
      'roleId',v_role,'delta',p_delta,'updated',v_updated,
      'skipped',greatest(v_matching-v_updated,0)
    ));
  return jsonb_build_object(
    'matrixVersionId',v_matrix,'updated',v_updated,
    'skipped',greatest(v_matching-v_updated,0)
  );
end;
$$;

revoke all on function public.matrix_v2_staffing_bulk_adjust_uat_v2(
  uuid,uuid,text,uuid,integer
) from public,anon,authenticated;
grant execute on function public.matrix_v2_staffing_bulk_adjust_uat_v2(
  uuid,uuid,text,uuid,integer
) to authenticated;
