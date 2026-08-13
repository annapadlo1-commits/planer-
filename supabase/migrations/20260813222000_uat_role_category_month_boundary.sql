-- UAT: categories use the same first-run month resolver as the optimizer.
-- The first immutable configuration may be published after day one only when
-- there was no earlier company configuration for that planning month.

create or replace function public.optimizer_role_categories_uat_v1(p_month date)
returns jsonb
language plpgsql stable security definer set search_path=''
as $$
declare v_matrix uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select id into v_matrix from public.matrix_versions
  where status in ('ACTIVE','ARCHIVED') and schema_version>=2
    and solver_private.matrix_covers_planning_month_uat_v1(
      effective_from,date_trunc('month',p_month)::date
    )
  order by effective_from desc,version desc limit 1;
  return jsonb_build_object('categories',coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',category.id,'code',category.code,'name',category.name,'color',category.color,
      'sortOrder',category.sort_order,'anchorRoleId',roles.anchor_role_id,
      'roleIds',roles.role_ids,'roleNames',roles.role_names
    ) order by category.sort_order,category.code)
    from public.matrix_role_categories_v2 category
    cross join lateral (
      select (array_agg(role_row.id order by
          case when exists(select 1 from public.matrix_staffing_rules_v2 staffing
            where staffing.matrix_version_id=v_matrix and staffing.role_id=role_row.id and staffing.active) then 0 else 1 end,
          role_row.sort_order,role_row.code))[1] anchor_role_id,
        jsonb_agg(role_row.id order by role_row.sort_order,role_row.code) role_ids,
        jsonb_agg(role_row.name order by role_row.sort_order,role_row.code) role_names
      from public.matrix_roles_v2 role_row
      where role_row.matrix_version_id=v_matrix and role_row.category_id=category.id and role_row.active
    ) roles
    where category.matrix_version_id=v_matrix and category.active and roles.anchor_role_id is not null
  ),'[]'::jsonb));
end;
$$;

revoke all on function public.optimizer_role_categories_uat_v1(date) from public,anon;
grant execute on function public.optimizer_role_categories_uat_v1(date) to authenticated;

notify pgrst,'reload schema';
