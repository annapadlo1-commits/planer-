-- Category snapshots start from the canonical company snapshot and then retain
-- only employees eligible for at least one role in the selected category.
-- Every employee-scoped array must follow that same boundary.  Otherwise the
-- worker rejects the whole request as INVALID_SNAPSHOT before optimization.

alter function solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)
  rename to build_snapshot_payload_before_category_employee_guard_uat_v1;

create function solver_private.build_snapshot_payload_v2(
  p_run_id uuid,
  p_month date,
  p_matrix_version_id uuid,
  p_scenario_id uuid,
  p_scope_type text,
  p_scope_role_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_snapshot jsonb;
  v_employee_ids jsonb;
  v_key text;
begin
  v_snapshot:=solver_private.build_snapshot_payload_before_category_employee_guard_uat_v1(
    p_run_id,p_month,p_matrix_version_id,p_scenario_id,p_scope_type,p_scope_role_id
  );

  if coalesce(v_snapshot->'scope'->>'type','')<>'CATEGORY' then
    return v_snapshot;
  end if;

  select coalesce(jsonb_agg(employee.value->>'id'),'[]'::jsonb)
  into v_employee_ids
  from jsonb_array_elements(coalesce(v_snapshot->'employees','[]'::jsonb)) employee;

  for v_key in
    select unnest(array[
      'availabilityWindows',
      'hardBlocks',
      'externalAssignments',
      'lockedAssignments',
      'baselineAssignments'
    ]::text[])
  loop
    v_snapshot:=jsonb_set(
      v_snapshot,
      array[v_key],
      coalesce((
        select jsonb_agg(item.value order by item.ordinality)
        from jsonb_array_elements(coalesce(v_snapshot->v_key,'[]'::jsonb))
          with ordinality item(value,ordinality)
        where item.value->>'employeeId' in (
          select jsonb_array_elements_text(v_employee_ids)
        )
      ),'[]'::jsonb),
      true
    );
  end loop;

  return v_snapshot;
end;
$$;

revoke all on function
  solver_private.build_snapshot_payload_before_category_employee_guard_uat_v1(uuid,date,uuid,uuid,text,uuid),
  solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)
  from public,anon,authenticated;
grant execute on function solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)
  to service_role;

notify pgrst,'reload schema';
