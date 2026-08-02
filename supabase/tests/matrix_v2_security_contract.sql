-- Matrix v2 publication/security contract. The test is transactional and
-- exercises the fail-closed helpers and immutable ACTIVE boundary.

begin;

do $$
declare
  v_active uuid;
  v_role uuid;
  v_blocked boolean:=false;
  v_table text;
begin
  if not public.matrix_v2_is_iso_4217_currency('PLN')
    or public.matrix_v2_is_iso_4217_currency('ABC') then
    raise exception 'ISO_4217_CONTRACT_INVALID';
  end if;

  if not public.matrix_v2_is_supported_pay_condition(jsonb_build_object(
    'field','duty_ids','operator','CONTAINS','value',
    '00000000-0000-0000-0000-000000000001'
  )) then raise exception 'VALID_PAY_CONDITION_REJECTED'; end if;
  if public.matrix_v2_is_supported_pay_condition(jsonb_build_object(
    'field','duty_ids','operator','CONTAINS','value',jsonb_build_object()
  )) or public.matrix_v2_is_supported_pay_condition(jsonb_build_object(
    'field','contract_code','operator','EQ','value',''
  )) or public.matrix_v2_is_supported_pay_condition(jsonb_build_object(
    'field','duration_minutes','operator','GTE','value',1.5
  )) then raise exception 'INVALID_PAY_CONDITION_ACCEPTED'; end if;

  if not public.matrix_v2_is_supported_objective_config(
    'MINIMIZE','{"targetValue":100}'::jsonb
  ) or public.matrix_v2_is_supported_objective_config(
    'MAXIMIZE','{"targetValue":100}'::jsonb
  ) or public.matrix_v2_is_supported_objective_config(
    'MINIMIZE','{"target":100,"targetValue":100}'::jsonb
  ) then raise exception 'OBJECTIVE_OVERRIDE_CONTRACT_INVALID'; end if;

  if has_table_privilege('authenticated','public.matrix_versions','UPDATE')
    or has_table_privilege('authenticated','public.matrix_roles','INSERT')
    or has_table_privilege('authenticated','public.matrix_scenarios','DELETE')
    or has_table_privilege('authenticated','public.optimizer_profiles','UPDATE') then
    raise exception 'LEGACY_MATRIX_DIRECT_DML_STILL_GRANTED';
  end if;

  foreach v_table in array array[
    'matrix_versions','matrix_roles','matrix_locations','matrix_shift_templates',
    'matrix_functions','matrix_role_functions','matrix_demand',
    'matrix_scenarios','optimizer_profiles','matrix_employee_roles'
  ] loop
    if not exists(
      select 1 from pg_catalog.pg_policies policy
      where policy.schemaname='public' and policy.tablename=v_table
        and policy.cmd='SELECT' and position('ACTIVE' in policy.qual)>0
    ) then raise exception 'ACTIVE_ONLY_POLICY_MISSING:%',v_table; end if;
  end loop;

  select version.id into v_active
  from public.matrix_versions version
  where version.status='ACTIVE' and version.schema_version>=2
  order by version.version desc limit 1;
  if v_active is null then raise exception 'ACTIVE_MATRIX_V2_MISSING'; end if;

  select role_row.id into v_role
  from public.matrix_roles_v2 role_row
  where role_row.matrix_version_id=v_active
  order by role_row.sort_order,role_row.id limit 1;
  if v_role is null then raise exception 'ACTIVE_MATRIX_ROLE_MISSING'; end if;

  begin
    update public.matrix_roles_v2 set name=name where id=v_role;
  exception when others then
    if position('MATRIX_VERSION_IMMUTABLE' in sqlerrm)=0 then raise; end if;
    v_blocked:=true;
  end;
  if not v_blocked then raise exception 'ACTIVE_MATRIX_CHILD_MUTATION_ALLOWED'; end if;

  v_blocked:=false;
  begin
    update public.matrix_versions set settings=settings where id=v_active;
  exception when others then
    if position('INVALID_MATRIX_VERSION_TRANSITION' in sqlerrm)=0 then raise; end if;
    v_blocked:=true;
  end;
  if not v_blocked then raise exception 'ACTIVE_MATRIX_METADATA_MUTATION_ALLOWED'; end if;
end;
$$;

rollback;
