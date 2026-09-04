-- B4F-100: keep the authenticated standby preview callable and retire an
-- obsolete employee-save wrapper which depended on a removed v2 function.

create or replace function public.optimizer_variant_standby_preview_uat_v2(p_variant_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_matrix uuid;
  v_scope text;
  v_month date;
  v_groups jsonb;
  v_group jsonb;
  v_role_ids uuid[];
  v_canonical uuid;
  v_date date;
  v_tier integer;
  v_candidate record;
  v_counts jsonb := '{}'::jsonb;
  v_selected jsonb := '{}'::jsonb;
  v_result jsonb := '[]'::jsonb;
  v_key text;
  v_role_names jsonb;
begin
  select
    run.matrix_version_id,
    run.scope_type,
    run.month,
    coalesce(matrix.settings->'standbyGroups', '[]'::jsonb)
  into v_matrix, v_scope, v_month, v_groups
  from public.plan_variants_v2 variant
  join public.optimization_runs_v2 run on run.id = variant.run_id
  join public.matrix_versions matrix on matrix.id = run.matrix_version_id
  where variant.id = p_variant_id;

  if v_matrix is null then
    raise exception 'VARIANT_NOT_FOUND';
  end if;
  if auth.uid() is null
    or not solver_private.can_access_run_v2((
      select run_id from public.plan_variants_v2 where id = p_variant_id
    )) then
    raise exception 'VARIANT_NOT_AVAILABLE';
  end if;

  for v_group in select value from jsonb_array_elements(v_groups) loop
    select array_agg(role_row.id order by role_code.ordinality)
    into v_role_ids
    from jsonb_array_elements_text(v_group->'roleCodes')
      with ordinality role_code(value, ordinality)
    join public.matrix_roles_v2 role_row
      on role_row.matrix_version_id = v_matrix
      and role_row.active
      and upper(role_row.code) = upper(role_code.value);

    v_canonical := v_role_ids[1];
    if not exists(
      select 1
      from public.plan_assignments_v2
      where variant_id = p_variant_id and role_id = any(v_role_ids)
      union all
      select 1
      from public.plan_issues_v2
      where variant_id = p_variant_id and role_id = any(v_role_ids)
    ) then
      continue;
    end if;

    for v_date in
      select distinct source.shift_date
      from (
        select shift_row.shift_date
        from public.plan_assignments_v2 assignment
        join public.plan_shifts_v2 shift_row on shift_row.id = assignment.shift_id
        where assignment.variant_id = p_variant_id
          and assignment.role_id = any(v_role_ids)
        union
        select shift_row.shift_date
        from public.plan_issues_v2 issue
        join public.plan_shifts_v2 shift_row on shift_row.id = issue.shift_id
        where issue.variant_id = p_variant_id
          and issue.role_id = any(v_role_ids)
      ) source
      order by source.shift_date
    loop
      if exists(
        select 1
        from public.plan_issues_v2 issue
        join public.plan_shifts_v2 shift_row on shift_row.id = issue.shift_id
        where issue.variant_id = p_variant_id
          and issue.role_id = any(v_role_ids)
          and issue.issue_code = 'UNFILLED_SLOT'
          and shift_row.shift_date = v_date
      ) then
        continue;
      end if;

      for v_tier in 1..least(2, greatest(1, (v_group->>'tiers')::integer)) loop
        v_candidate := null;
        select
          candidate.employee_id,
          candidate.employee_no,
          candidate.eligible_role_ids,
          employee.first_name,
          employee.last_name
        into v_candidate
        from solver_private.standby_candidates_for_group_day_uat_v1(
          p_variant_id,
          v_matrix,
          v_month,
          v_role_ids,
          v_date
        ) candidate
        join public.employees employee on employee.id = candidate.employee_id
        where not coalesce(
          (v_selected->>(v_date::text || ':' || candidate.employee_id::text))::boolean,
          false
        )
        order by
          coalesce((v_counts->>((v_group->>'code') || ':' || candidate.employee_id::text))::integer, 0),
          candidate.employee_no,
          candidate.employee_id
        limit 1;

        if v_candidate.employee_id is null then
          exit;
        end if;

        select coalesce(
          jsonb_agg(role_row.name order by role_row.sort_order, role_row.name),
          '[]'::jsonb
        )
        into v_role_names
        from public.matrix_roles_v2 role_row
        where role_row.id = any(v_candidate.eligible_role_ids);

        v_key := (v_group->>'code') || ':' || v_candidate.employee_id::text;
        v_counts := jsonb_set(
          v_counts,
          array[v_key],
          to_jsonb(coalesce((v_counts->>v_key)::integer, 0) + 1),
          true
        );
        v_selected := jsonb_set(
          v_selected,
          array[v_date::text || ':' || v_candidate.employee_id::text],
          'true'::jsonb,
          true
        );
        v_result := v_result || jsonb_build_array(jsonb_build_object(
          'id', md5(p_variant_id::text || v_date::text || (v_group->>'code') || v_tier::text),
          'date', v_date,
          'tier', v_tier,
          'status', 'PREVIEW',
          'roleId', v_canonical,
          'roleName', v_group->>'name',
          'groupCode', v_group->>'code',
          'groupName', v_group->>'name',
          'eligibleRoleIds', to_jsonb(v_candidate.eligible_role_ids),
          'eligibleRoleNames', v_role_names,
          'employeeId', v_candidate.employee_id,
          'employeeNo', v_candidate.employee_no,
          'employeeName', trim(v_candidate.first_name || ' ' || v_candidate.last_name),
          'sourceType', case when v_scope = 'ROLE' then 'ROLE' else 'COMPANY' end,
          'activatedShiftId', null
        ));
      end loop;
    end loop;
  end loop;

  return v_result;
end;
$$;

revoke all on function public.optimizer_variant_standby_preview_uat_v2(uuid)
  from public, anon;
grant execute on function public.optimizer_variant_standby_preview_uat_v2(uuid)
  to authenticated;

-- The application uses matrix_v2_employee_save_uat_v4. v3 is a remote-only
-- compatibility wrapper whose v2 dependency no longer exists.
revoke all on function public.matrix_v2_employee_save_uat_v3(uuid, jsonb)
  from public, anon, authenticated;

notify pgrst, 'reload schema';
