-- UAT: application access is independent from schedule employees.  The same
-- migration also exposes an OWNER-only, explicitly enabled full business-data
-- reset used to verify the genuine first-run journey in the isolated UAT.

create table if not exists public.application_access_directory_v1 (
  id uuid primary key default gen_random_uuid(),
  email text not null check (position('@' in email) > 1),
  app_role public.app_role not null,
  role_logical_id uuid,
  location_logical_id uuid,
  auth_user_id uuid references auth.users(id) on delete set null,
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique nulls not distinct (email,app_role,role_logical_id,location_logical_id)
);
create unique index if not exists application_access_directory_v1_identity_idx
  on public.application_access_directory_v1(
    lower(email),app_role,
    coalesce(role_logical_id,'00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(location_logical_id,'00000000-0000-0000-0000-000000000000'::uuid)
  );
alter table public.application_access_directory_v1 enable row level security;
revoke all on table public.application_access_directory_v1 from public,anon,authenticated;
grant all on table public.application_access_directory_v1 to service_role;

insert into public.application_access_directory_v1(
  email,app_role,auth_user_id,active,created_by
)
select lower(u.email),p.app_role,u.id,true,u.id
from public.user_permissions p
join auth.users u on u.id=p.auth_user_id
where u.email is not null
  and p.scope_role is null and p.scope_location is null
on conflict do nothing;

create or replace function public.application_access_materialize_uat_v1(
  p_email text,p_auth_user_id uuid
) returns void language plpgsql volatile security definer set search_path=''
as $$
declare v_entry record;
begin
  for v_entry in
    select * from public.application_access_directory_v1 d
    where lower(d.email)=lower(trim(p_email)) and d.active
  loop
    update public.application_access_directory_v1
      set auth_user_id=p_auth_user_id,updated_at=now()
      where id=v_entry.id;

    insert into public.matrix_scope_grants_v2(
      auth_user_id,app_role,role_logical_id,location_logical_id,active,created_by
    ) values(
      p_auth_user_id,v_entry.app_role,v_entry.role_logical_id,
      v_entry.location_logical_id,true,v_entry.created_by
    ) on conflict(auth_user_id,app_role,role_logical_id,location_logical_id,duty_logical_id)
      do update set active=true,updated_at=now();

    if v_entry.app_role in ('OWNER','ADMIN','HR_FINANCE','VERIFIER','EMPLOYEE') then
      insert into public.user_permissions(auth_user_id,app_role,scope_role,scope_location)
      values(p_auth_user_id,v_entry.app_role,null,null)
      on conflict do nothing;
    end if;
  end loop;

  if exists(
    select 1 from public.application_access_directory_v1 d
    where lower(d.email)=lower(trim(p_email)) and d.active and d.app_role='EMPLOYEE'
  ) then
    update public.employees e set auth_user_id=p_auth_user_id,updated_at=now()
    where lower(coalesce(e.email,''))=lower(trim(p_email))
      and (e.auth_user_id is null or e.auth_user_id=p_auth_user_id);
  end if;
end;
$$;
revoke all on function public.application_access_materialize_uat_v1(text,uuid)
  from public,anon,authenticated;
grant execute on function public.application_access_materialize_uat_v1(text,uuid)
  to service_role;

create or replace function public.current_user_access_v2()
returns jsonb language plpgsql volatile security definer set search_path=''
as $$
declare v_user uuid:=auth.uid(); v_email text; v_roles jsonb; v_employee jsonb;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  select lower(u.email) into v_email from auth.users u where u.id=v_user;
  if v_email is not null then
    perform public.application_access_materialize_uat_v1(v_email,v_user);
  end if;

  select coalesce(jsonb_agg(item order by item->>'app_role'),'[]'::jsonb)
  into v_roles from (
    select distinct jsonb_build_object(
      'app_role',x.app_role::text,
      'scope_role',x.scope_role,
      'scope_location',x.scope_location,
      'role_logical_id',x.role_logical_id,
      'location_logical_id',x.location_logical_id
    ) item
    from (
      select p.app_role,p.scope_role::text scope_role,p.scope_location::text scope_location,
        null::uuid role_logical_id,null::uuid location_logical_id
      from public.user_permissions p where p.auth_user_id=v_user
      union all
      select g.app_role,r.code,l.code,g.role_logical_id,g.location_logical_id
      from public.matrix_scope_grants_v2 g
      left join lateral (
        select mr.code from public.matrix_roles_v2 mr
        join public.matrix_versions mv on mv.id=mr.matrix_version_id
        where mr.logical_id=g.role_logical_id and mv.status in ('DRAFT','ACTIVE')
        order by (mv.status='DRAFT') desc,mv.version desc limit 1
      ) r on true
      left join lateral (
        select ml.code from public.matrix_locations_v2 ml
        join public.matrix_versions mv on mv.id=ml.matrix_version_id
        where ml.logical_id=g.location_logical_id and mv.status in ('DRAFT','ACTIVE')
        order by (mv.status='DRAFT') desc,mv.version desc limit 1
      ) l on true
      where g.auth_user_id=v_user and g.active
    ) x
  ) roles;

  select jsonb_build_object(
    'id',e.id,'employee_no',e.employee_no,'first_name',e.first_name,
    'last_name',e.last_name,'primary_role',e.primary_role
  ) into v_employee from public.employees e where e.auth_user_id=v_user limit 1;

  return jsonb_build_object(
    'auth_user_id',v_user,'email',v_email,'roles',v_roles,'employee',v_employee
  );
end;
$$;
revoke all on function public.current_user_access_v2() from public,anon;
grant execute on function public.current_user_access_v2() to authenticated;

create or replace function public.application_access_directory_uat_v1()
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_matrix uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  select mv.id into v_matrix from public.matrix_versions mv
    where mv.schema_version>=2 and mv.status in ('DRAFT','ACTIVE')
    order by (mv.status='DRAFT') desc,mv.version desc limit 1;
  return jsonb_build_object(
    'entries',coalesce((select jsonb_agg(jsonb_build_object(
      'id',d.id,'email',d.email,'appRole',d.app_role,'active',d.active,
      'authUserId',d.auth_user_id,
      'status',case when d.auth_user_id is null then 'PENDING' else 'ACTIVE' end,
      'roleLogicalId',d.role_logical_id,'roleName',r.name,
      'locationLogicalId',d.location_logical_id,'locationName',l.name
    ) order by lower(d.email),d.app_role::text)
    from public.application_access_directory_v1 d
    left join public.matrix_roles_v2 r on r.matrix_version_id=v_matrix and r.logical_id=d.role_logical_id
    left join public.matrix_locations_v2 l on l.matrix_version_id=v_matrix and l.logical_id=d.location_logical_id),'[]'::jsonb),
    'roles',coalesce((select jsonb_agg(jsonb_build_object(
      'rowId',r.id,'logicalId',r.logical_id,'name',r.name,'code',r.code
    ) order by r.sort_order,r.name) from public.matrix_roles_v2 r
      where r.matrix_version_id=v_matrix and r.active),'[]'::jsonb),
    'locations',coalesce((select jsonb_agg(jsonb_build_object(
      'rowId',l.id,'logicalId',l.logical_id,'name',l.name,'code',l.code
    ) order by l.sort_order,l.name) from public.matrix_locations_v2 l
      where l.matrix_version_id=v_matrix and l.active),'[]'::jsonb)
  );
end;
$$;
revoke all on function public.application_access_directory_uat_v1() from public,anon;
grant execute on function public.application_access_directory_uat_v1() to authenticated;

create or replace function public.application_access_save_uat_v1(
  p_email text,p_app_role text,p_role_id uuid default null,
  p_location_id uuid default null,p_active boolean default true
) returns jsonb language plpgsql volatile security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_email text:=lower(trim(p_email));
  v_role public.app_role; v_role_logical uuid; v_location_logical uuid;
  v_auth uuid; v_id uuid;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
    raise exception 'INVALID_ACCESS_EMAIL';
  end if;
  begin v_role:=upper(trim(p_app_role))::public.app_role;
  exception when others then raise exception 'INVALID_APP_ROLE'; end;

  if p_role_id is not null then
    select r.logical_id into v_role_logical from public.matrix_roles_v2 r where r.id=p_role_id;
  end if;
  if p_location_id is not null then
    select l.logical_id into v_location_logical from public.matrix_locations_v2 l where l.id=p_location_id;
  end if;
  if v_role='ROLE_MANAGER' and v_role_logical is null then raise exception 'ROLE_SCOPE_REQUIRED'; end if;
  if v_role='LOCATION_MANAGER' and v_location_logical is null then raise exception 'LOCATION_SCOPE_REQUIRED'; end if;
  if v_role not in ('ROLE_MANAGER','LOCATION_MANAGER') then
    v_role_logical:=null;v_location_logical:=null;
  elsif v_role='ROLE_MANAGER' then v_location_logical:=null;
  elsif v_role='LOCATION_MANAGER' then v_role_logical:=null;
  end if;

  select u.id into v_auth from auth.users u where lower(u.email)=v_email limit 1;
  insert into public.application_access_directory_v1(
    email,app_role,role_logical_id,location_logical_id,auth_user_id,active,created_by
  ) values(v_email,v_role,v_role_logical,v_location_logical,v_auth,p_active,v_actor)
  on conflict(email,app_role,role_logical_id,location_logical_id)
  do update set auth_user_id=excluded.auth_user_id,active=excluded.active,
    updated_at=now()
  returning id into v_id;

  if v_auth is not null then
    if p_active then
      perform public.application_access_materialize_uat_v1(v_email,v_auth);
    else
      delete from public.matrix_scope_grants_v2 g
        where g.auth_user_id=v_auth and g.app_role=v_role
          and g.role_logical_id is not distinct from v_role_logical
          and g.location_logical_id is not distinct from v_location_logical;
      if v_role in ('OWNER','ADMIN','HR_FINANCE','VERIFIER','EMPLOYEE') then
        if v_role='OWNER' and v_auth=v_actor then raise exception 'CANNOT_REMOVE_OWN_OWNER_ACCESS'; end if;
        delete from public.user_permissions p where p.auth_user_id=v_auth and p.app_role=v_role;
      end if;
    end if;
  end if;
  return jsonb_build_object('id',v_id,'email',v_email,'appRole',v_role,
    'active',p_active,'status',case when v_auth is null then 'PENDING' else 'ACTIVE' end);
end;
$$;
revoke all on function public.application_access_save_uat_v1(text,text,uuid,uuid,boolean)
  from public,anon;
grant execute on function public.application_access_save_uat_v1(text,text,uuid,uuid,boolean)
  to authenticated;

create or replace function public.uat_full_business_reset_preview_v1()
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_enabled boolean:=false;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.has_app_role('OWNER') then raise exception 'FORBIDDEN'; end if;
  select c.enabled into v_enabled from public.uat_environment_controls c
    where c.control_key='ISOLATED_UAT_DESTRUCTIVE_TOOLS';
  return jsonb_build_object(
    'enabled',coalesce(v_enabled,false),'confirmation','WYCZYŚĆ CAŁĄ FIRMĘ UAT',
    'employees',(select count(*) from public.employees),
    'matrixVersions',(select count(*) from public.matrix_versions),
    'publishedSchedules',(select count(*) from public.published_role_schedules_v2),
    'otherUsers',(select count(*) from auth.users where id<>auth.uid()),
    'preserves',jsonb_build_array('Twoje konto właściciela','flagi środowiska UAT','schemat i migracje')
  );
end;
$$;
revoke all on function public.uat_full_business_reset_preview_v1() from public,anon;
grant execute on function public.uat_full_business_reset_preview_v1() to authenticated;

create or replace function public.uat_full_business_reset_v1(p_confirmation text)
returns jsonb language plpgsql volatile security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_enabled boolean:=false; v_email text;
  v_tables text; v_draft uuid;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.has_app_role('OWNER') then raise exception 'FORBIDDEN'; end if;
  select c.enabled into v_enabled from public.uat_environment_controls c
    where c.control_key='ISOLATED_UAT_DESTRUCTIVE_TOOLS';
  if not coalesce(v_enabled,false) then raise exception 'UAT_DESTRUCTIVE_TOOLS_DISABLED'; end if;
  if p_confirmation<>'WYCZYŚĆ CAŁĄ FIRMĘ UAT' then raise exception 'INVALID_CONFIRMATION'; end if;
  select lower(u.email) into v_email from auth.users u where u.id=v_actor;

  select string_agg(format('%I.%I',t.schemaname,t.tablename),',') into v_tables
  from pg_tables t
  where t.schemaname='public'
    and t.tablename not in ('uat_environment_controls','solver_feature_flags')
    and not exists(
      select 1 from pg_depend d
      join pg_class c on c.oid=d.objid
      join pg_extension e on e.oid=d.refobjid
      where d.deptype='e' and c.relname=t.tablename
    );
  if v_tables is not null then execute 'truncate table '||v_tables||' restart identity cascade'; end if;
  delete from auth.users u where u.id<>v_actor;

  insert into public.user_permissions(auth_user_id,app_role,scope_role,scope_location)
  values(v_actor,'OWNER',null,null) on conflict do nothing;
  insert into public.application_access_directory_v1(
    email,app_role,auth_user_id,active,created_by
  ) values(v_email,'OWNER',v_actor,true,v_actor) on conflict do nothing;
  insert into public.matrix_scope_grants_v2(auth_user_id,app_role,active,created_by)
  values(v_actor,'OWNER',true,v_actor) on conflict do nothing;

  insert into public.matrix_versions(
    version,name,status,effective_from,settings,created_by,schema_version
  ) values(
    1,'Pierwsza konfiguracja firmy','DRAFT',
    (now() at time zone 'Europe/Warsaw')::date,
    jsonb_build_object(
      'currency','PLN','timezone','Europe/Warsaw','minimumRestMinutes',660,
      'maximumShiftsPerDay',1,'maxShiftsPerDay',1,'standbyTiersPerRoleDay',2,
      'missingAvailabilityMeansAvailable',true,'requireOptimal',false
    ),v_actor,2
  ) returning id into v_draft;

  return jsonb_build_object('ok',true,'draftMatrixVersionId',v_draft,
    'ownerEmail',v_email,'message','UAT_EMPTY_FIRST_RUN_READY');
end;
$$;
revoke all on function public.uat_full_business_reset_v1(text) from public,anon;
grant execute on function public.uat_full_business_reset_v1(text) to authenticated;
