-- B4F-36 regression guard. Full-company workbooks may retain formatting and
-- technical defaults below the last business dictionary entry. Those rows do
-- not define roles, categories, locations or duties and must not reach the
-- legacy resolver as active records with an empty code.

alter function solver_private.matrix_v2_full_import_phase_uat_v1(jsonb,text)
  rename to matrix_v2_full_import_phase_before_empty_dictionary_guard_uat_v1;

create function solver_private.matrix_v2_full_import_phase_uat_v1(
  p_configuration jsonb,
  p_phase text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_configuration jsonb:=coalesce(p_configuration,'{}'::jsonb);
  v_key text;
  v_sheet text;
  v_invalid jsonb;
begin
  if upper(trim(coalesce(p_phase,'')))='PRE' then
    foreach v_key in array array['roleCategories','roles','locations','duties'] loop
      v_sheet:=case v_key
        when 'roleCategories' then 'Kategorie grafików'
        when 'roles' then 'Role'
        when 'locations' then 'Lokale'
        else 'Obowiązki'
      end;

      select item.value into v_invalid
      from jsonb_array_elements(coalesce(v_configuration->v_key,'[]'::jsonb)) item(value)
      where nullif(trim(item.value->>'code'),'') is not null
        and nullif(trim(item.value->>'name'),'') is null
      limit 1;

      if v_invalid is not null then
        raise exception 'FULL_IMPORT_DICTIONARY_VALUE_REQUIRED|%|%|Nazwa',
          v_sheet,coalesce(nullif(v_invalid->>'sourceRow',''),'nieznany');
      end if;

      v_configuration:=jsonb_set(
        v_configuration,
        array[v_key],
        coalesce((
          select jsonb_agg(item.value order by item.ordinality)
          from jsonb_array_elements(coalesce(v_configuration->v_key,'[]'::jsonb))
            with ordinality item(value,ordinality)
          where nullif(trim(item.value->>'code'),'') is not null
             or nullif(trim(item.value->>'name'),'') is not null
        ),'[]'::jsonb),
        true
      );
    end loop;
  end if;

  return solver_private.matrix_v2_full_import_phase_before_empty_dictionary_guard_uat_v1(
    v_configuration,p_phase
  )||jsonb_build_object('emptyDictionaryRowsIgnored',true);
end;
$$;

revoke all on function solver_private.matrix_v2_full_import_phase_uat_v1(jsonb,text)
  from public,anon,authenticated;
revoke all on function solver_private.matrix_v2_full_import_phase_before_empty_dictionary_guard_uat_v1(jsonb,text)
  from public,anon,authenticated;
grant execute on function solver_private.matrix_v2_full_import_phase_uat_v1(jsonb,text)
  to service_role;

notify pgrst,'reload schema';
