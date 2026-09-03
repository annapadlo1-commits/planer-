-- Canonicalize a business shift occurrence independently of its staffing seats.
-- Several seats of one shift have different slotIds, but remain one employee
-- shift for the one-primary-shift-per-day invariant.

alter function solver_private.build_snapshot_payload_v2(
  uuid,date,uuid,uuid,text,uuid
) rename to build_snapshot_payload_before_occurrence_id_v2;

create function solver_private.build_snapshot_payload_v2(
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
  v_slots jsonb;
begin
  v_snapshot:=solver_private.build_snapshot_payload_before_occurrence_id_v2(
    p_run_id,p_month,p_matrix_version_id,p_scenario_id,
    p_scope_type,p_scope_role_id
  );

  select coalesce(jsonb_agg(
    slot.value||jsonb_build_object(
      'occurrenceId',concat_ws('|',
        slot.value->>'date',slot.value->>'shiftTemplateId'
      )
    ) order by slot.ordinality
  ),'[]'::jsonb)
  into v_slots
  from jsonb_array_elements(coalesce(v_snapshot->'slots','[]'::jsonb))
    with ordinality slot(value,ordinality);

  return jsonb_set(v_snapshot,'{slots}',v_slots,true);
end;
$$;

revoke all on function solver_private.build_snapshot_payload_before_occurrence_id_v2(
  uuid,date,uuid,uuid,text,uuid
) from public,anon,authenticated;
revoke all on function solver_private.build_snapshot_payload_v2(
  uuid,date,uuid,uuid,text,uuid
) from public,anon,authenticated;
grant execute on function solver_private.build_snapshot_payload_before_occurrence_id_v2(
  uuid,date,uuid,uuid,text,uuid
) to service_role;
grant execute on function solver_private.build_snapshot_payload_v2(
  uuid,date,uuid,uuid,text,uuid
) to service_role;
