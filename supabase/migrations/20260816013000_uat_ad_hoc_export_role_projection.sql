-- B4F-58: a draft workspace contains cloned role row ids, while the global
-- ad-hoc pool can still point at the corresponding role row from the active
-- version. Project every pool row onto the workspace role with the same
-- logical identity so an exported workbook is safe to import into that draft.

alter function public.matrix_v2_workspace(date)
  rename to matrix_v2_workspace_before_ad_hoc_projection_uat_v1;

create function public.matrix_v2_workspace(p_month date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
  v_matrix uuid;
begin
  v_result := public.matrix_v2_workspace_before_ad_hoc_projection_uat_v1(p_month);
  v_matrix := nullif(v_result->'matrixVersion'->>'id', '')::uuid;

  v_result := jsonb_set(
    v_result,
    '{adHocWorkers}',
    coalesce((
      select jsonb_agg(
        (to_jsonb(pool) - 'role_id') || jsonb_build_object(
          'role_id', coalesce(workspace_role.id, pool.role_id),
          'roleCode', coalesce(workspace_role.code, source_role.code)
        )
        order by pool.display_name, pool.id
      )
      from public.recovery_ad_hoc_pool_v2 pool
      join public.matrix_roles_v2 source_role on source_role.id = pool.role_id
      left join public.matrix_roles_v2 workspace_role
        on workspace_role.matrix_version_id = v_matrix
       and workspace_role.logical_id = source_role.logical_id
      where pool.active
    ), '[]'::jsonb),
    true
  );

  return v_result;
end;
$$;

revoke all on function public.matrix_v2_workspace_before_ad_hoc_projection_uat_v1(date)
  from public, anon, authenticated;
revoke all on function public.matrix_v2_workspace(date) from public, anon;
grant execute on function public.matrix_v2_workspace(date) to authenticated;

