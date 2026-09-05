-- UAT-006: one guided Matrix workflow: shift -> role -> duty/competency -> headcount.
-- The migration changes only the draft Matrix through an authenticated RPC.

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname='matrix_staffing_active_set_positive_uat006'
      and conrelid='public.matrix_staffing_rules_v2'::regclass
  ) then
    alter table public.matrix_staffing_rules_v2
      add constraint matrix_staffing_active_set_positive_uat006
      check (not active or operation<>'SET' or count_value>=1) not valid;
  end if;
end;
$$;

create or replace function public.matrix_v2_shift_staffing_save_uat_v3(
  p_scenario_id uuid,
  p_shift_template_ids uuid[],
  p_role_id uuid,
  p_duty_id uuid,
  p_operation text,
  p_count_value integer,
  p_multiplier_basis_points integer,
  p_active boolean
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_matrix uuid;
  v_shifts uuid[];
  v_source_shift uuid;
  v_target_shift uuid;
  v_target_scenario uuid;
  v_target_role uuid;
  v_target_duty uuid;
  v_existing_rule uuid;
  v_operation text:=upper(trim(coalesce(p_operation,'')));
  v_saved integer:=0;
  v_role_duty_linked boolean:=false;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;

  select coalesce(array_agg(distinct shift_id),array[]::uuid[])
  into v_shifts
  from unnest(coalesce(p_shift_template_ids,array[]::uuid[])) shift_id;
  if cardinality(v_shifts)<1 then raise exception 'SHIFT_SELECTION_REQUIRED'; end if;
  if cardinality(v_shifts)>100 then raise exception 'TOO_MANY_SHIFTS_SELECTED'; end if;
  if p_scenario_id is null then raise exception 'SCENARIO_REQUIRED'; end if;
  if p_role_id is null then raise exception 'ROLE_REQUIRED'; end if;
  if v_operation not in ('SET','ADD','MULTIPLY','REMOVE') then
    raise exception 'INVALID_STAFFING_OPERATION';
  end if;
  if v_operation='SET' and coalesce(p_active,true) and coalesce(p_count_value,0)<1 then
    raise exception 'STAFFING_REQUIRED_COUNT_MUST_BE_POSITIVE';
  end if;
  if v_operation='ADD' and p_count_value is null then
    raise exception 'STAFFING_COUNT_REQUIRED';
  end if;
  if v_operation='MULTIPLY' and coalesce(p_multiplier_basis_points,-1)<0 then
    raise exception 'INVALID_STAFFING_MULTIPLIER';
  end if;

  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  v_matrix:=public.matrix_v2_create_draft(null);

  select target.id into v_target_scenario
  from public.matrix_scenarios_v2 source
  join public.matrix_scenarios_v2 target
    on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
  where source.id=p_scenario_id and target.active;
  if v_target_scenario is null then raise exception 'SCENARIO_NOT_IN_MATRIX_V2'; end if;

  select target.id into v_target_role
  from public.matrix_roles_v2 source
  join public.matrix_roles_v2 target
    on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
  where source.id=p_role_id and target.active;
  if v_target_role is null then raise exception 'ROLE_NOT_IN_MATRIX_V2'; end if;

  if p_duty_id is not null then
    select target.id into v_target_duty
    from public.matrix_duties_v2 source
    join public.matrix_duties_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=p_duty_id and target.active;
    if v_target_duty is null then raise exception 'DUTY_NOT_IN_MATRIX_V2'; end if;

    v_role_duty_linked:=not exists(
      select 1 from public.matrix_role_duties_v2 link
      where link.matrix_version_id=v_matrix
        and link.role_id=v_target_role and link.duty_id=v_target_duty and link.active
    );
    insert into public.matrix_role_duties_v2(
      matrix_version_id,role_id,duty_id,assignment_mode,minimum_count,active
    ) values(v_matrix,v_target_role,v_target_duty,'OPTIONAL',0,true)
    on conflict (matrix_version_id,role_id,duty_id)
    do update set active=true;
  end if;

  foreach v_source_shift in array v_shifts loop
    select target.id into v_target_shift
    from public.matrix_shift_templates_v2 source
    join public.matrix_shift_templates_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=v_source_shift and target.active;
    if v_target_shift is null then raise exception 'SHIFT_NOT_IN_MATRIX_V2'; end if;

    select rule.id into v_existing_rule
    from public.matrix_staffing_rules_v2 rule
    where rule.matrix_version_id=v_matrix
      and rule.scenario_id=v_target_scenario
      and rule.shift_template_id=v_target_shift
      and rule.role_id=v_target_role
      and rule.duty_id is not distinct from v_target_duty;

    perform public.matrix_v2_admin_save_alpha16(
      'STAFFING_RULE',v_existing_rule,
      jsonb_build_object(
        'scenarioId',v_target_scenario,
        'shiftTemplateId',v_target_shift,
        'roleId',v_target_role,
        'dutyId',v_target_duty,
        'operation',v_operation,
        'countValue',case when v_operation in ('SET','ADD') then p_count_value else null end,
        'multiplierBasisPoints',case when v_operation='MULTIPLY' then p_multiplier_basis_points else null end,
        'active',coalesce(p_active,true),
        'sourceMetadata',jsonb_build_object('source','UNIFIED_SHIFT_STAFFING_UI')
      )
    );
    v_saved:=v_saved+1;
  end loop;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_version',v_matrix::text,'SAVE_UNIFIED_SHIFT_STAFFING',
    jsonb_build_object(
      'scenarioId',v_target_scenario,'shiftTemplateIds',to_jsonb(v_shifts),
      'roleId',v_target_role,'dutyId',v_target_duty,
      'roleDutyLinked',v_role_duty_linked,'operation',v_operation,
      'countValue',p_count_value,'saved',v_saved
    ));

  return jsonb_build_object(
    'matrixVersionId',v_matrix,'saved',v_saved,
    'roleDutyLinked',v_role_duty_linked
  );
end;
$$;

revoke all on function public.matrix_v2_shift_staffing_save_uat_v3(
  uuid,uuid[],uuid,uuid,text,integer,integer,boolean
) from public,anon,authenticated;
grant execute on function public.matrix_v2_shift_staffing_save_uat_v3(
  uuid,uuid[],uuid,uuid,text,integer,integer,boolean
) to authenticated;

comment on function public.matrix_v2_shift_staffing_save_uat_v3(
  uuid,uuid[],uuid,uuid,text,integer,integer,boolean
) is 'Atomically saves exact shift staffing and links a selected duty to the role so the unified Matrix flow cannot silently ignore it.';
