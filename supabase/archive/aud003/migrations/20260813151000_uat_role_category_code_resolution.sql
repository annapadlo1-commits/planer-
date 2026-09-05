-- UAT only: workbook rows carry a business category code, not a database UUID.
-- Resolve that code before the shared role save validates category membership.
create or replace function public.matrix_v2_admin_save_alpha16(
  p_kind text,
  p_id uuid,
  p_data jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
  v_id uuid;
  v_matrix uuid;
  v_category uuid;
  v_category_code text;
  v_payload jsonb:=coalesce(p_data,'{}'::jsonb);
  v_mode text;
  v_priority integer;
begin
  if upper(trim(p_kind))='ROLE' then
    select id into v_matrix from public.matrix_versions
    where status='DRAFT' and schema_version>=2 order by version desc limit 1;
    if v_matrix is null then raise exception 'MATRIX_V2_DRAFT_NOT_FOUND'; end if;

    if pg_catalog.pg_input_is_valid(coalesce(v_payload->>'categoryId',''),'uuid') then
      v_category:=(v_payload->>'categoryId')::uuid;
    end if;
    v_category_code:=upper(trim(coalesce(nullif(v_payload->>'categoryCode',''),v_payload->>'code','')));
    if v_category is null then
      select id into v_category from public.matrix_role_categories_v2
      where matrix_version_id=v_matrix and code=v_category_code and active
      order by sort_order,id limit 1;
    end if;
    if v_category is null or not exists(
      select 1 from public.matrix_role_categories_v2
      where id=v_category and matrix_version_id=v_matrix and active
    ) then
      raise exception 'ROLE_CATEGORY_NOT_FOUND|%|%',coalesce(v_payload->>'code',''),v_category_code;
    end if;
    v_payload:=v_payload||jsonb_build_object('categoryId',v_category);
  end if;

  v_result:=public.matrix_v2_admin_save_before_categories_uat_v1(p_kind,p_id,v_payload);
  v_id:=(v_result->>'id')::uuid;

  if upper(trim(p_kind))='ROLE' then
    update public.matrix_roles_v2 set category_id=v_category,updated_at=now() where id=v_id;
  elsif upper(trim(p_kind))='EMPLOYEE_ROLE' then
    v_mode:=case upper(coalesce(nullif(v_payload->>'assignmentMode',''),'STANDARD'))
      when 'BACKUP' then 'BACKUP' else 'STANDARD' end;
    v_priority:=greatest(1,least(999,coalesce(nullif(v_payload->>'backupPriority','')::integer,100)));
    update public.matrix_employee_roles_v2 set
      assignment_mode=case when is_primary then 'STANDARD' else v_mode end,
      backup_priority=v_priority,updated_by=auth.uid(),updated_at=now()
    where id=v_id;
  end if;
  return v_result;
end;
$$;

revoke all on function public.matrix_v2_admin_save_alpha16(text,uuid,jsonb) from public,anon;
grant execute on function public.matrix_v2_admin_save_alpha16(text,uuid,jsonb) to authenticated,service_role;

notify pgrst,'reload schema';
