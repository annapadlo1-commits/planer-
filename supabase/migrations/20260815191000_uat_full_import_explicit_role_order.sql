-- Local UAT fix candidate. Do not deploy without explicit approval.
-- A workbook can define new categories, roles and employees in one import.
-- Persist both dictionaries before the legacy phase starts resolving employees.

alter function solver_private.matrix_v2_full_import_phase_uat_v1(jsonb,text)
  rename to matrix_v2_full_import_phase_before_explicit_roles_uat_v1;

create function solver_private.matrix_v2_full_import_phase_uat_v1(
  p_configuration jsonb,
  p_phase text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
  v_matrix uuid;
  v_item jsonb;
  v_category uuid;
  v_role uuid;
  v_payload jsonb;
  v_configuration jsonb:=coalesce(p_configuration,'{}'::jsonb);
begin
  if upper(trim(coalesce(p_phase,'')))='PRE' then
    select id into v_matrix from public.matrix_versions
    where status='DRAFT' and schema_version>=2
    order by version desc limit 1;
    if v_matrix is null then raise exception 'MATRIX_V2_DRAFT_NOT_FOUND'; end if;

    for v_item in
      select value from jsonb_array_elements(coalesce(v_configuration->'roleCategories','[]'::jsonb))
    loop
      if length(trim(coalesce(v_item->>'code','')))=0
         or length(trim(coalesce(v_item->>'name','')))=0 then
        raise exception 'INVALID_ROLE_CATEGORY';
      end if;
      insert into public.matrix_role_categories_v2(
        matrix_version_id,logical_id,code,name,description,color,sort_order,active
      ) values(
        v_matrix,
        public.matrix_v2_stable_uuid('ROLE_CATEGORY_LOGICAL:'||upper(trim(v_item->>'code'))),
        upper(trim(v_item->>'code')),
        trim(v_item->>'name'),
        nullif(trim(v_item->>'description'),''),
        coalesce(nullif(trim(v_item->>'color'),''),'#7257d8'),
        coalesce(nullif(v_item->>'sortOrder','')::integer,0),
        coalesce((v_item->>'active')::boolean,true)
      ) on conflict(matrix_version_id,code) do update set
        name=excluded.name,
        description=excluded.description,
        color=excluded.color,
        sort_order=excluded.sort_order,
        active=excluded.active,
        updated_at=now();
    end loop;

    for v_item in
      select value from jsonb_array_elements(coalesce(v_configuration->'roles','[]'::jsonb))
    loop
      select id into v_category from public.matrix_role_categories_v2
      where matrix_version_id=v_matrix
        and code=upper(trim(coalesce(nullif(v_item->>'categoryCode',''),v_item->>'code')))
        and active;
      if v_category is null then
        raise exception 'ROLE_CATEGORY_NOT_FOUND|%|%',
          coalesce(v_item->>'code',''),coalesce(v_item->>'categoryCode','');
      end if;

      select id into v_role from public.matrix_roles_v2
      where matrix_version_id=v_matrix and code=upper(trim(v_item->>'code'));
      v_payload:=v_item||jsonb_build_object('categoryId',v_category);
      perform public.matrix_v2_admin_save_alpha16('ROLE',v_role,v_payload);
    end loop;

    v_configuration:=jsonb_set(
      jsonb_set(v_configuration,'{roleCategories}','[]'::jsonb,true),
      '{roles}','[]'::jsonb,true
    );
  end if;

  v_result:=solver_private.matrix_v2_full_import_phase_before_explicit_roles_uat_v1(
    v_configuration,p_phase
  );
  return v_result||jsonb_build_object('rolesAppliedBeforeEmployees',true);
end;
$$;

revoke all on function solver_private.matrix_v2_full_import_phase_uat_v1(jsonb,text)
  from public,anon,authenticated;
revoke all on function solver_private.matrix_v2_full_import_phase_before_explicit_roles_uat_v1(jsonb,text)
  from public,anon,authenticated;
grant execute on function solver_private.matrix_v2_full_import_phase_uat_v1(jsonb,text)
  to service_role;

notify pgrst,'reload schema';
