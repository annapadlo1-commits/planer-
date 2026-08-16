-- UAT only: a duty/capability can never synthesize an employee role.
-- Role eligibility comes exclusively from matrix_employee_roles_v2.

alter function solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)
  rename to build_snapshot_payload_before_explicit_roles_uat_v1;

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
  v_employees jsonb := '[]'::jsonb;
  v_employee jsonb;
  v_grants jsonb;
begin
  v_snapshot := solver_private.build_snapshot_payload_before_explicit_roles_uat_v1(
    p_run_id,
    p_month,
    p_matrix_version_id,
    p_scenario_id,
    p_scope_type,
    p_scope_role_id
  );

  for v_employee in
    select value
    from jsonb_array_elements(coalesce(v_snapshot->'employees','[]'::jsonb))
  loop
    select coalesce(jsonb_agg(grant_row.value order by grant_row.ordinality),'[]'::jsonb)
    into v_grants
    from jsonb_array_elements(coalesce(v_employee->'roleGrants','[]'::jsonb))
      with ordinality grant_row(value,ordinality)
    where not (grant_row.value ? 'sourceDutyId');

    if jsonb_array_length(v_grants) > 0 then
      v_employee := jsonb_set(v_employee,'{roleGrants}',v_grants,true);
      v_employee := jsonb_set(
        v_employee,
        '{roleIds}',
        coalesce((
          select jsonb_agg(distinct grant_row.value->>'roleId')
          from jsonb_array_elements(v_grants) grant_row(value)
        ),'[]'::jsonb),
        true
      );
      v_employees := v_employees || jsonb_build_array(v_employee);
    end if;
  end loop;

  return jsonb_set(v_snapshot,'{employees}',v_employees,true);
end;
$$;

revoke all on function
  solver_private.build_snapshot_payload_before_explicit_roles_uat_v1(uuid,date,uuid,uuid,text,uuid)
  from public,anon,authenticated;
revoke all on function
  solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)
  from public,anon,authenticated;
grant execute on function
  solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)
  to service_role;

comment on function solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)
  is 'UAT snapshot: role eligibility comes only from explicit employee role grants; duties remain capabilities.';

notify pgrst, 'reload schema';
