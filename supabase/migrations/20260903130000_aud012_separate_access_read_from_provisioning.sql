-- AUD-2026-09-01-012: access reads must be pure. Linking a verified account
-- to pre-authorized directory rows is a separate, explicit and auditable RPC.

create or replace function public.application_access_materialize_uat_v1(
  p_email text,
  p_auth_user_id uuid
) returns void
language plpgsql
volatile
security definer
set search_path=''
as $$
declare
  v_email text:=lower(trim(p_email));
  v_entry record;
  v_employee_matches integer;
begin
  if p_auth_user_id is null or v_email is null then
    raise exception 'PROVISIONING_IDENTITY_REQUIRED';
  end if;
  if not exists(
    select 1 from auth.users auth_user
    where auth_user.id=p_auth_user_id and lower(auth_user.email)=v_email
  ) then
    raise exception 'PROVISIONING_IDENTITY_MISMATCH';
  end if;
  if exists(
    select 1 from public.application_access_directory_v1 directory
    where lower(directory.email)=v_email and directory.active
      and directory.auth_user_id is not null
      and directory.auth_user_id<>p_auth_user_id
  ) then
    raise exception 'PROVISIONING_DIRECTORY_LINK_CONFLICT';
  end if;
  if exists(
    select 1 from public.employees employee
    where lower(coalesce(employee.email,''))=v_email
      and employee.auth_user_id is not null
      and employee.auth_user_id<>p_auth_user_id
  ) then
    raise exception 'PROVISIONING_EMPLOYEE_LINK_CONFLICT';
  end if;
  select count(*) into v_employee_matches
  from public.employees employee
  where lower(coalesce(employee.email,''))=v_email
    and (employee.auth_user_id is null or employee.auth_user_id=p_auth_user_id);
  if v_employee_matches>1 then
    raise exception 'PROVISIONING_EMPLOYEE_AMBIGUOUS';
  end if;

  for v_entry in
    select directory.*
    from public.application_access_directory_v1 directory
    where lower(directory.email)=v_email and directory.active
      and (directory.auth_user_id is null or directory.auth_user_id=p_auth_user_id)
    order by directory.id
    for update
  loop
    update public.application_access_directory_v1 directory
    set auth_user_id=p_auth_user_id,updated_at=now()
    where directory.id=v_entry.id
      and directory.auth_user_id is distinct from p_auth_user_id;

    insert into public.matrix_scope_grants_v2(
      auth_user_id,app_role,role_logical_id,location_logical_id,active,created_by
    ) values(
      p_auth_user_id,v_entry.app_role,v_entry.role_logical_id,
      v_entry.location_logical_id,true,v_entry.created_by
    )
    on conflict(auth_user_id,app_role,role_logical_id,location_logical_id,duty_logical_id)
    do update set active=true,updated_at=now()
    where public.matrix_scope_grants_v2.active is distinct from true;

    if v_entry.app_role in ('OWNER','ADMIN','HR_FINANCE','VERIFIER','EMPLOYEE') then
      insert into public.user_permissions(auth_user_id,app_role,scope_role,scope_location)
      values(p_auth_user_id,v_entry.app_role,null,null)
      on conflict do nothing;
    end if;
  end loop;

  if exists(
    select 1 from public.application_access_directory_v1 directory
    where lower(directory.email)=v_email and directory.active
      and directory.app_role='EMPLOYEE' and directory.auth_user_id=p_auth_user_id
  ) then
    update public.employees employee
    set auth_user_id=p_auth_user_id,updated_at=now()
    where lower(coalesce(employee.email,''))=v_email
      and employee.auth_user_id is null;
  end if;
end;
$$;

revoke all on function public.application_access_materialize_uat_v1(text,uuid)
  from public,anon,authenticated;
grant execute on function public.application_access_materialize_uat_v1(text,uuid)
  to service_role;

create or replace function public.current_user_access_v2()
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  v_user uuid:=auth.uid();
  v_email text;
  v_roles jsonb;
  v_employee jsonb;
  v_provisioning_available boolean:=false;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  select lower(auth_user.email) into v_email
  from auth.users auth_user where auth_user.id=v_user;

  select coalesce(jsonb_agg(item order by item->>'app_role'),'[]'::jsonb)
  into v_roles from (
    select distinct jsonb_build_object(
      'app_role',scope.app_role::text,
      'scope_role',scope.scope_role,
      'scope_location',scope.scope_location,
      'role_logical_id',scope.role_logical_id,
      'location_logical_id',scope.location_logical_id
    ) item
    from (
      select permission.app_role,permission.scope_role::text scope_role,
        permission.scope_location::text scope_location,
        null::uuid role_logical_id,null::uuid location_logical_id
      from public.user_permissions permission where permission.auth_user_id=v_user
      union all
      select grant_row.app_role,role_row.code,location_row.code,
        grant_row.role_logical_id,grant_row.location_logical_id
      from public.matrix_scope_grants_v2 grant_row
      left join lateral (
        select role_item.code from public.matrix_roles_v2 role_item
        join public.matrix_versions matrix_version on matrix_version.id=role_item.matrix_version_id
        where role_item.logical_id=grant_row.role_logical_id
          and matrix_version.status in ('DRAFT','ACTIVE')
        order by (matrix_version.status='DRAFT') desc,matrix_version.version desc limit 1
      ) role_row on true
      left join lateral (
        select location_item.code from public.matrix_locations_v2 location_item
        join public.matrix_versions matrix_version on matrix_version.id=location_item.matrix_version_id
        where location_item.logical_id=grant_row.location_logical_id
          and matrix_version.status in ('DRAFT','ACTIVE')
        order by (matrix_version.status='DRAFT') desc,matrix_version.version desc limit 1
      ) location_row on true
      where grant_row.auth_user_id=v_user and grant_row.active
    ) scope
  ) roles;

  select jsonb_build_object(
    'id',employee.id,
    'employee_no',employee.employee_no,
    'first_name',employee.first_name,
    'last_name',employee.last_name,
    'primary_role',employee.primary_role,
    'active',employee.active
  ) into v_employee
  from public.employees employee
  where employee.auth_user_id=v_user
  order by employee.active desc,employee.id
  limit 1;

  select exists(
    select 1 from public.application_access_directory_v1 directory
    where lower(directory.email)=v_email and directory.active
      and (directory.auth_user_id is null or directory.auth_user_id=v_user)
  ) and not exists(
    select 1 from public.application_access_directory_v1 directory
    where lower(directory.email)=v_email and directory.active
      and directory.auth_user_id is not null and directory.auth_user_id<>v_user
  ) into v_provisioning_available;

  return jsonb_build_object(
    'auth_user_id',v_user,
    'email',v_email,
    'roles',v_roles,
    'employee',v_employee,
    'provisioning_available',v_provisioning_available
  );
end;
$$;

revoke all on function public.current_user_access_v2() from public,anon;
grant execute on function public.current_user_access_v2() to authenticated;

create or replace function public.application_access_provision_current_user_v1()
returns jsonb
language plpgsql
volatile
security definer
set search_path=''
as $$
declare
  v_user uuid:=auth.uid();
  v_email text;
  v_directory_count integer;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  select lower(auth_user.email) into v_email
  from auth.users auth_user where auth_user.id=v_user;
  if v_email is null then raise exception 'PROVISIONING_EMAIL_REQUIRED'; end if;

  select count(*) into v_directory_count
  from public.application_access_directory_v1 directory
  where lower(directory.email)=v_email and directory.active
    and (directory.auth_user_id is null or directory.auth_user_id=v_user);
  if v_directory_count=0 then raise exception 'PROVISIONING_ACCESS_NOT_GRANTED'; end if;

  perform public.application_access_materialize_uat_v1(v_email,v_user);
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(
    v_user,'application_access',v_user::text,'APPLICATION_ACCESS_PROVISION_SELF',
    jsonb_build_object('directoryEntries',v_directory_count,'requestedAt',now())
  );
  return jsonb_build_object('provisioned',true,'directoryEntries',v_directory_count);
end;
$$;

revoke all on function public.application_access_provision_current_user_v1()
  from public,anon;
grant execute on function public.application_access_provision_current_user_v1()
  to authenticated;
