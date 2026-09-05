create or replace function public.matrix_v2_publication_readiness_uat_v2(
  p_effective_from date,
  p_schedule_month date
) returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_base jsonb;
  v_matrix uuid;
  v_extra jsonb := '[]'::jsonb;
  v_base_blockers jsonb := '[]'::jsonb;
  v_all_blockers jsonb := '[]'::jsonb;
begin
  v_base := public.matrix_v2_publication_readiness_base_uat006(
    p_effective_from,
    p_schedule_month
  );
  v_matrix := nullif(v_base->>'matrixVersionId','')::uuid;

  select coalesce(jsonb_agg(value),'[]'::jsonb)
    into v_base_blockers
  from jsonb_array_elements(coalesce(v_base->'blockers','[]'::jsonb))
  where value->>'code' <> 'SHIFT_PERIOD_MISMATCH';

  select coalesce(jsonb_agg(problem),'[]'::jsonb)
    into v_extra
  from (
    select jsonb_build_object(
      'code','REQUIRED_DUTY_WITH_ZERO_MINIMUM',
      'roleId',link.role_id,
      'dutyId',link.duty_id,
      'message','Obowiązek wymagany musi mieć minimalną liczbę co najmniej 1.'
    ) problem
    from public.matrix_role_duties_v2 link
    where link.matrix_version_id=v_matrix and link.active
      and link.assignment_mode='REQUIRED' and link.minimum_count<1

    union all
    select jsonb_build_object(
      'code','STAFFING_DUTY_NOT_LINKED_TO_ROLE',
      'roleId',rule.role_id,
      'dutyId',rule.duty_id,
      'shiftTemplateId',rule.shift_template_id,
      'message','Reguła obsady używa obowiązku nieprzypisanego do tej roli.'
    )
    from public.matrix_staffing_rules_v2 rule
    where rule.matrix_version_id=v_matrix and rule.active and rule.duty_id is not null
      and not exists(
        select 1 from public.matrix_role_duties_v2 link
        where link.matrix_version_id=rule.matrix_version_id
          and link.role_id=rule.role_id and link.duty_id=rule.duty_id and link.active
      )

    union all
    select jsonb_build_object(
      'code','INACTIVE_DUTY_HAS_ACTIVE_DEPENDENCIES',
      'dutyId',duty.id,
      'message','Wyłączony obowiązek nadal ma aktywne zależności.'
    )
    from public.matrix_duties_v2 duty
    where duty.matrix_version_id=v_matrix and not duty.active and (
      exists(select 1 from public.matrix_role_duties_v2 link where link.matrix_version_id=v_matrix and link.duty_id=duty.id and link.active)
      or exists(select 1 from public.matrix_employee_duties_v2 link where link.matrix_version_id=v_matrix and link.duty_id=duty.id and link.active)
      or exists(select 1 from public.matrix_staffing_rules_v2 rule where rule.matrix_version_id=v_matrix and rule.duty_id=duty.id and rule.active)
    )

    union all
    select jsonb_build_object(
      'code','SHIFT_PERIOD_FROM_TIME_MISMATCH',
      'shiftTemplateId',shift_row.id,
      'shiftName',shift_row.name,
      'shiftCode',shift_row.code,
      'message','Automatyczna klasyfikacja zmiany jest niespójna z godziną rozpoczęcia.'
    )
    from public.matrix_shift_templates_v2 shift_row
    where shift_row.matrix_version_id=v_matrix and shift_row.active
      and shift_row.shift_period is distinct from case
        when extract(hour from shift_row.starts_at)<12 then 'MORNING'
        when extract(hour from shift_row.starts_at)<17 then 'MIDDLE'
        else 'EVENING' end

    union all
    select jsonb_build_object(
      'code','SHIFT_OVERNIGHT_FLAG_INCONSISTENT',
      'shiftTemplateId',shift_row.id,
      'shiftCode',shift_row.code,
      'shiftName',shift_row.name,
      'locationId',shift_row.location_id,
      'startsAt',to_char(shift_row.starts_at,'HH24:MI'),
      'endsAt',to_char(shift_row.ends_at,'HH24:MI'),
      'endsNextDay',shift_row.ends_next_day,
      'expectedEndsNextDay',(shift_row.ends_at<=shift_row.starts_at),
      'message',format(
        '%s (%s–%s): pole „Następny dzień” powinno mieć wartość %s.',
        shift_row.name,
        to_char(shift_row.starts_at,'HH24:MI'),
        to_char(shift_row.ends_at,'HH24:MI'),
        case when shift_row.ends_at<=shift_row.starts_at then 'TAK' else 'NIE' end
      )
    )
    from public.matrix_shift_templates_v2 shift_row
    where shift_row.matrix_version_id=v_matrix and shift_row.active
      and shift_row.ends_next_day is distinct from (shift_row.ends_at<=shift_row.starts_at)
  ) problems;

  v_all_blockers := v_base_blockers || v_extra;
  return v_base || jsonb_build_object(
    'ready',jsonb_array_length(v_all_blockers)=0,
    'blockers',v_all_blockers
  );
end;
$function$;
