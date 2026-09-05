-- UAT only: create role categories before the legacy import creates roles.
-- This keeps a freshly downloaded quick-start workbook self-importing after a full reset.
create or replace function solver_private.matrix_v2_full_import_phase_uat_v1(
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
  v_employee uuid;
  v_role uuid;
  v_role_code text;
  v_mode text;
  v_priority integer;
  v_count integer:=0;
begin
  select id into v_matrix from public.matrix_versions
  where status='DRAFT' and schema_version>=2 order by version desc limit 1;
  if v_matrix is null then raise exception 'MATRIX_V2_DRAFT_NOT_FOUND'; end if;

  if upper(trim(coalesce(p_phase,'')))='PRE' then
    for v_item in select value from jsonb_array_elements(coalesce(p_configuration->'roleCategories','[]'::jsonb)) loop
      if length(trim(coalesce(v_item->>'code','')))=0 or length(trim(coalesce(v_item->>'name','')))=0 then
        raise exception 'INVALID_ROLE_CATEGORY';
      end if;
      insert into public.matrix_role_categories_v2(
        matrix_version_id,logical_id,code,name,description,color,sort_order,active
      ) values(
        v_matrix,public.matrix_v2_stable_uuid('ROLE_CATEGORY_LOGICAL:'||upper(trim(v_item->>'code'))),
        upper(trim(v_item->>'code')),trim(v_item->>'name'),nullif(trim(v_item->>'description'),''),
        coalesce(nullif(trim(v_item->>'color'),''),'#7257d8'),
        coalesce(nullif(v_item->>'sortOrder','')::integer,0),coalesce((v_item->>'active')::boolean,true)
      ) on conflict(matrix_version_id,code) do update set
        name=excluded.name,description=excluded.description,color=excluded.color,
        sort_order=excluded.sort_order,active=excluded.active,updated_at=now();
    end loop;
  end if;

  -- The wrapped importer creates roles in PRE, so categories must already exist.
  v_result:=solver_private.matrix_v2_full_import_phase_before_categories_uat_v1(p_configuration,p_phase);

  if upper(trim(coalesce(p_phase,'')))='PRE' then
    for v_item in select value from jsonb_array_elements(coalesce(p_configuration->'roles','[]'::jsonb)) loop
      select id into v_role from public.matrix_roles_v2
      where matrix_version_id=v_matrix and code=upper(trim(v_item->>'code'));
      select id into v_category from public.matrix_role_categories_v2
      where matrix_version_id=v_matrix and code=upper(trim(coalesce(nullif(v_item->>'categoryCode',''),v_item->>'code')));
      if v_role is null then raise exception 'ROLE_NOT_FOUND|%',coalesce(v_item->>'code',''); end if;
      if v_category is null then raise exception 'ROLE_CATEGORY_NOT_FOUND|%|%',coalesce(v_item->>'code',''),coalesce(v_item->>'categoryCode',''); end if;
      update public.matrix_roles_v2 set category_id=v_category,updated_at=now() where id=v_role;
    end loop;
  end if;

  if upper(trim(coalesce(p_phase,'')))='POST' then
    for v_item in select value from jsonb_array_elements(coalesce(p_configuration->'employees','[]'::jsonb)) loop
      select e.id into v_employee from public.employees e
      where (nullif(trim(v_item->>'employeeNo'),'') is not null and e.employee_no=trim(v_item->>'employeeNo'))
        or (nullif(trim(v_item->>'email'),'') is not null and lower(e.email)=lower(trim(v_item->>'email')))
      order by e.active desc limit 1;
      if v_employee is null then continue; end if;
      update public.matrix_employee_profiles_v2 set
        employment_stage=case upper(coalesce(nullif(v_item->>'employmentStage',''),'REGULAR'))
          when 'PROBATION' then 'PROBATION' when 'NOTICE' then 'NOTICE' else 'REGULAR' end,
        probation_end=nullif(v_item->>'probationEnd','')::date,
        updated_at=now(),updated_by=auth.uid()
      where matrix_version_id=v_matrix and employee_id=v_employee;

      for v_role_code,v_priority in
        select upper(trim(x.value->>'roleCode')),coalesce(nullif(x.value->>'priority','')::integer,100)
        from jsonb_array_elements(coalesce(v_item->'backupRoles','[]'::jsonb)) x
      loop
        select id into v_role from public.matrix_roles_v2
        where matrix_version_id=v_matrix and code=v_role_code and active;
        if v_role is null then raise exception 'ROLE_NOT_FOUND|%',v_role_code; end if;
        insert into public.matrix_employee_roles_v2(
          matrix_version_id,employee_id,role_id,is_primary,can_lead,active,
          assignment_mode,backup_priority,created_by,updated_by
        ) values(v_matrix,v_employee,v_role,false,false,true,'BACKUP',greatest(1,least(999,v_priority)),auth.uid(),auth.uid())
        on conflict(matrix_version_id,employee_id,role_id) do update set
          is_primary=false,active=true,assignment_mode='BACKUP',
          backup_priority=excluded.backup_priority,updated_by=auth.uid(),updated_at=now();
      end loop;
    end loop;

    for v_item in select value from jsonb_array_elements(coalesce(p_configuration->'employeeRoles','[]'::jsonb)) loop
      select e.id into v_employee from public.employees e where e.employee_no=trim(v_item->>'employeeNo');
      select r.id into v_role from public.matrix_roles_v2 r
        where r.matrix_version_id=v_matrix and r.code=upper(trim(v_item->>'roleCode'));
      v_mode:=case upper(coalesce(nullif(v_item->>'assignmentMode',''),'STANDARD')) when 'BACKUP' then 'BACKUP' else 'STANDARD' end;
      v_priority:=greatest(1,least(999,coalesce(nullif(v_item->>'backupPriority','')::integer,100)));
      if v_employee is not null and v_role is not null then
        update public.matrix_employee_roles_v2 set
          assignment_mode=case when is_primary then 'STANDARD' else v_mode end,
          backup_priority=v_priority,updated_by=auth.uid(),updated_at=now()
        where matrix_version_id=v_matrix and employee_id=v_employee and role_id=v_role;
      end if;
    end loop;

    if p_configuration ? 'adHocWorkers' then
      delete from public.recovery_ad_hoc_pool_v2;
      for v_item in select value from jsonb_array_elements(coalesce(p_configuration->'adHocWorkers','[]'::jsonb)) loop
        select id into v_role from public.matrix_roles_v2
        where matrix_version_id=v_matrix and code=upper(trim(v_item->>'roleCode')) and active;
        if v_role is null then raise exception 'ROLE_NOT_FOUND|%',coalesce(v_item->>'roleCode',''); end if;
        insert into public.recovery_ad_hoc_pool_v2(
          display_name,email,phone,role_id,contract_type,base_rate_minor,currency,
          available_from,available_to,active,notes,created_by
        ) values(
          trim(v_item->>'displayName'),nullif(lower(trim(v_item->>'email')),''),nullif(trim(v_item->>'phone'),''),v_role,
          upper(coalesce(nullif(v_item->>'contractType',''),'ZLECENIE')),
          nullif(v_item->>'baseRateMinor','')::bigint,upper(coalesce(nullif(v_item->>'currency',''),'PLN')),
          nullif(v_item->>'availableFrom','')::date,nullif(v_item->>'availableTo','')::date,
          coalesce((v_item->>'active')::boolean,true),nullif(trim(v_item->>'notes'),''),auth.uid()
        );
        v_count:=v_count+1;
      end loop;
    end if;
  end if;
  return v_result||jsonb_build_object('roleCategoriesApplied',true,'adHocWorkersApplied',v_count);
end;
$$;

revoke all on function solver_private.matrix_v2_full_import_phase_uat_v1(jsonb,text) from public,anon,authenticated;
grant execute on function solver_private.matrix_v2_full_import_phase_uat_v1(jsonb,text) to service_role;

notify pgrst,'reload schema';
