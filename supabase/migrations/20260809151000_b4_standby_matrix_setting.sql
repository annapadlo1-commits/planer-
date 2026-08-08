-- B4 UAT: standby is an explicit Matrix setting shared by the editor,
-- full-company workbook, solver preview and publication. Existing v2 versions
-- receive the previously documented two-tier policy as visible stored data.

alter table public.matrix_versions disable trigger zz_matrix_version_immutable_v2;
update public.matrix_versions
set settings=jsonb_set(coalesce(settings,'{}'::jsonb),'{standbyTiersPerRoleDay}','2'::jsonb,true)
where schema_version>=2 and not coalesce(settings,'{}'::jsonb) ? 'standbyTiersPerRoleDay';
alter table public.matrix_versions enable trigger zz_matrix_version_immutable_v2;

alter function public.matrix_v2_admin_save(text,uuid,jsonb)
  rename to matrix_v2_admin_save_before_standby_setting;

create function public.matrix_v2_admin_save(p_kind text,p_id uuid,p_data jsonb)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_result jsonb;v_tiers integer;
begin
  if upper(trim(p_kind))='MATRIX_SETTINGS' then
    if coalesce(p_data->>'standbyTiersPerRoleDay','') !~ '^[0-2]$' then
      raise exception 'INVALID_STANDBY_TIERS';
    end if;
    v_tiers:=(p_data->>'standbyTiersPerRoleDay')::integer;
  end if;
  v_result:=public.matrix_v2_admin_save_before_standby_setting(p_kind,p_id,p_data);
  if upper(trim(p_kind))='MATRIX_SETTINGS' then
    update public.matrix_versions
    set settings=jsonb_set(coalesce(settings,'{}'::jsonb),'{standbyTiersPerRoleDay}',to_jsonb(v_tiers),true)
    where id=(v_result->>'id')::uuid;
  end if;
  return v_result;
end;
$$;

revoke all on function public.matrix_v2_admin_save(text,uuid,jsonb) from public,anon;
grant execute on function public.matrix_v2_admin_save(text,uuid,jsonb) to authenticated;
