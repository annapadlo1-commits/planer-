-- Keep the immutable slot identifier contract aligned with the Python worker.
-- PostgreSQL array_to_string('{}'::uuid[], ',') returns an empty string, not
-- NULL. The pre-Alpha-16 builder therefore emitted `||` for demand without a
-- duty, while the worker deliberately uses `|-|` as the canonical empty-duty
-- sentinel. Normalize the final Alpha-16 payload and every slot reference.

create or replace function solver_private.build_snapshot_payload_v2(
  p_run_id uuid,
  p_month date,
  p_matrix_version_id uuid,
  p_scenario_id uuid,
  p_scope_type text,
  p_scope_role_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_snapshot jsonb;
  v_employees jsonb:='[]'::jsonb;
  v_templates jsonb:='[]'::jsonb;
  v_slots jsonb:='[]'::jsonb;
  v_slot_ids jsonb:='{}'::jsonb;
  v_baseline jsonb:='[]'::jsonb;
  v_locked jsonb:='[]'::jsonb;
  v_employee jsonb;
  v_template jsonb;
  v_rules jsonb;
begin
  v_snapshot:=solver_private.build_snapshot_payload_before_alpha16_v2(
    p_run_id,p_month,p_matrix_version_id,p_scenario_id,p_scope_type,p_scope_role_id
  );

  for v_template in
    select template.value
    from jsonb_array_elements(coalesce(v_snapshot->'shiftTemplates','[]'::jsonb)) template
  loop
    v_template:=v_template||jsonb_build_object(
      'shiftPeriod',(select row.shift_period
        from public.matrix_shift_templates_v2 row
        where row.id=(v_template->>'id')::uuid)
    );
    v_templates:=v_templates||jsonb_build_array(v_template);
  end loop;

  for v_employee in
    select employee.value
    from jsonb_array_elements(coalesce(v_snapshot->'employees','[]'::jsonb)) employee
  loop
    v_rules:=solver_private.alpha16_shift_rules_v2(
      (v_employee->>'id')::uuid,p_matrix_version_id,p_month
    );
    v_employee:=(v_employee-'preferredShiftTemplateIds'-'homeLocationIds')
      ||jsonb_build_object(
        'preferredShiftTemplateIds',coalesce(v_rules->'preferredShiftTemplateIds','[]'::jsonb),
        'avoidedShiftTemplateIds',coalesce(v_rules->'avoidedShiftTemplateIds','[]'::jsonb),
        'blockedShiftTemplateIds',coalesce(v_rules->'blockedShiftTemplateIds','[]'::jsonb),
        'shiftPeriodPreferences',coalesce(v_rules->'periods','{}'::jsonb),
        'homeLocationIds','[]'::jsonb
      );
    v_employees:=v_employees||jsonb_build_array(v_employee);
  end loop;

  with normalized_slots as (
    select
      slot.ordinality,
      slot.value,
      case
        when jsonb_array_length(coalesce(slot.value->'dutyIds','[]'::jsonb))=0
        then concat_ws('|',
          slot.value->>'date',
          slot.value->>'shiftTemplateId',
          slot.value->>'roleId',
          '-',
          slot.value->>'demandId',
          slot.value->>'seatIndex'
        )
        else slot.value->>'slotId'
      end canonical_slot_id
    from jsonb_array_elements(coalesce(v_snapshot->'slots','[]'::jsonb))
      with ordinality slot(value,ordinality)
  )
  select
    coalesce(jsonb_agg(
      jsonb_set(value,'{slotId}',to_jsonb(canonical_slot_id),true)
      order by ordinality
    ),'[]'::jsonb),
    coalesce(jsonb_object_agg(value->>'slotId',canonical_slot_id),'{}'::jsonb)
  into v_slots,v_slot_ids
  from normalized_slots;

  if exists(
    select 1
    from jsonb_array_elements(v_slots) slot
    group by slot.value->>'slotId'
    having count(*)>1
  ) then
    raise exception 'DUPLICATE_CANONICAL_SLOT_ID';
  end if;

  select coalesce(jsonb_agg(
    jsonb_set(
      assignment.value,
      '{slotId}',
      to_jsonb(coalesce(
        v_slot_ids->>(assignment.value->>'slotId'),
        assignment.value->>'slotId'
      )),
      true
    ) order by assignment.ordinality
  ),'[]'::jsonb)
  into v_baseline
  from jsonb_array_elements(coalesce(
    v_snapshot->'baselineAssignments','[]'::jsonb
  )) with ordinality assignment(value,ordinality);

  select coalesce(jsonb_agg(
    jsonb_set(
      assignment.value,
      '{slotId}',
      to_jsonb(coalesce(
        v_slot_ids->>(assignment.value->>'slotId'),
        assignment.value->>'slotId'
      )),
      true
    ) order by assignment.ordinality
  ),'[]'::jsonb)
  into v_locked
  from jsonb_array_elements(coalesce(
    v_snapshot->'lockedAssignments','[]'::jsonb
  )) with ordinality assignment(value,ordinality);

  v_snapshot:=jsonb_set(v_snapshot,'{shiftTemplates}',v_templates,true);
  v_snapshot:=jsonb_set(v_snapshot,'{employees}',v_employees,true);
  v_snapshot:=jsonb_set(v_snapshot,'{slots}',v_slots,true);
  v_snapshot:=jsonb_set(v_snapshot,'{baselineAssignments}',v_baseline,true);
  v_snapshot:=jsonb_set(v_snapshot,'{lockedAssignments}',v_locked,true);
  return v_snapshot;
end;
$$;

revoke all on function solver_private.build_snapshot_payload_v2(
  uuid,date,uuid,uuid,text,uuid
) from public,anon,authenticated;
grant execute on function solver_private.build_snapshot_payload_v2(
  uuid,date,uuid,uuid,text,uuid
) to service_role;
