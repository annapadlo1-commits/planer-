-- GRAFIK PRO 3.0 — versioned employee lifecycle for Matrix v2.
--
-- public.employees remains the stable identity/authentication anchor required
-- by legacy Alpha 15 foreign keys. Every scheduling and display attribute is
-- copied into an immutable Matrix-version profile. Draft edits therefore do
-- not affect the active workforce, while a newly published Matrix becomes the
-- source for future solver snapshots.

alter table public.employees
  alter column primary_role drop not null;

alter table public.matrix_versions
  add column if not exists workforce_hash text,
  add column if not exists workforce_count integer;

create table if not exists public.matrix_employee_profiles_v2 (
  id uuid primary key default gen_random_uuid(),
  matrix_version_id uuid not null
    references public.matrix_versions(id) on delete cascade,
  employee_id uuid not null
    references public.employees(id) on delete restrict,
  employee_no text not null check (length(trim(employee_no)) between 1 and 80),
  first_name text not null check (length(trim(first_name)) between 1 and 120),
  last_name text not null check (length(trim(last_name)) between 1 and 160),
  email text,
  active boolean not null default true,
  employment_start date,
  employment_end date,
  nominal_monthly_minutes integer not null
    check (nominal_monthly_minutes between 0 and 44640),
  maximum_monthly_minutes integer not null
    check (maximum_monthly_minutes between 0 and 44640),
  maximum_weekly_minutes integer not null
    check (maximum_weekly_minutes between 0 and 10080),
  maximum_consecutive_days integer not null
    check (maximum_consecutive_days between 1 and 31),
  minimum_rest_minutes integer check (minimum_rest_minutes between 0 and 2880),
  only_morning boolean not null default false,
  only_evening boolean not null default false,
  no_weekends boolean not null default false,
  preferred_shift_code text,
  archived_at timestamptz,
  archived_by uuid references auth.users(id) on delete set null,
  archive_reason text,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (matrix_version_id,employee_id),
  unique (matrix_version_id,employee_no),
  check (email is null or email=lower(trim(email))),
  check (maximum_monthly_minutes>=nominal_monthly_minutes),
  check (employment_end is null or employment_start is null
    or employment_end>=employment_start),
  check (not (only_morning and only_evening)),
  check (
    (active and archived_at is null and archived_by is null)
    or (not active and archived_at is not null)
  )
);

create unique index if not exists matrix_employee_profiles_v2_email_idx
  on public.matrix_employee_profiles_v2(matrix_version_id,lower(email))
  where email is not null;
create index if not exists matrix_employee_profiles_v2_status_idx
  on public.matrix_employee_profiles_v2(matrix_version_id,active,last_name,first_name);

-- Existing demonstration employees become the initial versioned workforce.
-- This is a compatibility backfill only; later edits always happen in drafts.
insert into public.matrix_employee_profiles_v2(
  matrix_version_id,employee_id,employee_no,first_name,last_name,email,active,
  employment_start,employment_end,nominal_monthly_minutes,
  maximum_monthly_minutes,maximum_weekly_minutes,maximum_consecutive_days,
  minimum_rest_minutes,only_morning,only_evening,no_weekends,
  preferred_shift_code,archived_at,archived_by,archive_reason,created_by,updated_by
)
select mv.id,e.id,e.employee_no,e.first_name,e.last_name,lower(e.email),
  e.active and e.archived_at is null,e.employment_start,e.employment_end,
  e.monthly_nominal_minutes,
  greatest(e.monthly_nominal_minutes,
    coalesce(e.max_monthly_minutes,e.monthly_nominal_minutes)),
  e.max_weekly_minutes,e.max_consecutive_days,e.minimum_rest_minutes,
  e.only_morning,e.only_evening,e.no_weekends,e.preferred_shift,
  case when e.active and e.archived_at is null then null
    else coalesce(e.archived_at,e.updated_at,now()) end,
  case when e.active and e.archived_at is null then null else e.archived_by end,
  e.archive_reason,mv.created_by,mv.created_by
from public.matrix_versions mv
cross join public.employees e
where mv.schema_version>=2
on conflict(matrix_version_id,employee_id) do nothing;

do $$
begin
  if not exists(select 1 from pg_constraint
      where conname='matrix_employee_roles_v2_profile_fk') then
    alter table public.matrix_employee_roles_v2
      add constraint matrix_employee_roles_v2_profile_fk
      foreign key(matrix_version_id,employee_id)
      references public.matrix_employee_profiles_v2(matrix_version_id,employee_id)
      on delete cascade;
  end if;
  if not exists(select 1 from pg_constraint
      where conname='matrix_employee_locations_v2_profile_fk') then
    alter table public.matrix_employee_locations_v2
      add constraint matrix_employee_locations_v2_profile_fk
      foreign key(matrix_version_id,employee_id)
      references public.matrix_employee_profiles_v2(matrix_version_id,employee_id)
      on delete cascade;
  end if;
  if not exists(select 1 from pg_constraint
      where conname='matrix_employee_duties_v2_profile_fk') then
    alter table public.matrix_employee_duties_v2
      add constraint matrix_employee_duties_v2_profile_fk
      foreign key(matrix_version_id,employee_id)
      references public.matrix_employee_profiles_v2(matrix_version_id,employee_id)
      on delete cascade;
  end if;
end $$;

alter table public.matrix_employee_profiles_v2 enable row level security;
revoke all privileges on table public.matrix_employee_profiles_v2
  from public,anon,authenticated;
grant all on table public.matrix_employee_profiles_v2 to service_role;

drop policy if exists matrix_employee_profiles_v2_read
  on public.matrix_employee_profiles_v2;
create policy matrix_employee_profiles_v2_read
on public.matrix_employee_profiles_v2 for select to authenticated
using (
  public.can_manage_plans() or public.has_app_role('HR_FINANCE')
  or exists(select 1 from public.employees e
    where e.id=employee_id and e.auth_user_id=(select auth.uid()))
);

-- Active and archived Matrix versions are immutable. Even a privileged
-- service cannot silently rewrite the workforce behind historical schedules.
create or replace function solver_private.guard_matrix_employee_profile_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_matrix_id uuid:=case when tg_op='DELETE'
    then old.matrix_version_id else new.matrix_version_id end;
  v_status text;
begin
  select mv.status into v_status
  from public.matrix_versions mv where mv.id=v_matrix_id;
  if v_status is distinct from 'DRAFT' then
    raise exception 'MATRIX_WORKFORCE_VERSION_IMMUTABLE';
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;

revoke all on function solver_private.guard_matrix_employee_profile_v2()
  from public,anon,authenticated;
grant execute on function solver_private.guard_matrix_employee_profile_v2()
  to service_role;

drop trigger if exists matrix_employee_profiles_v2_immutable
  on public.matrix_employee_profiles_v2;
create trigger matrix_employee_profiles_v2_immutable
before insert or update or delete on public.matrix_employee_profiles_v2
for each row execute function solver_private.guard_matrix_employee_profile_v2();

-- A future Matrix draft automatically receives a deep copy of the workforce
-- from its base version. The existing draft creator does not need hardcoded
-- knowledge of this new table.
create or replace function solver_private.seed_matrix_employee_profiles_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status='DRAFT' and new.schema_version>=2 and new.base_version_id is not null then
    insert into public.matrix_employee_profiles_v2(
      id,matrix_version_id,employee_id,employee_no,first_name,last_name,email,
      active,employment_start,employment_end,nominal_monthly_minutes,
      maximum_monthly_minutes,maximum_weekly_minutes,maximum_consecutive_days,
      minimum_rest_minutes,only_morning,only_evening,no_weekends,
      preferred_shift_code,archived_at,archived_by,archive_reason,
      created_by,updated_by,created_at,updated_at
    )
    select gen_random_uuid(),new.id,p.employee_id,p.employee_no,p.first_name,
      p.last_name,p.email,p.active,p.employment_start,p.employment_end,
      p.nominal_monthly_minutes,p.maximum_monthly_minutes,
      p.maximum_weekly_minutes,p.maximum_consecutive_days,
      p.minimum_rest_minutes,p.only_morning,p.only_evening,p.no_weekends,
      p.preferred_shift_code,p.archived_at,p.archived_by,p.archive_reason,
      coalesce(new.created_by,p.created_by),coalesce(new.created_by,p.updated_by),
      now(),now()
    from public.matrix_employee_profiles_v2 p
    where p.matrix_version_id=new.base_version_id
    on conflict(matrix_version_id,employee_id) do nothing;
  end if;
  return new;
end;
$$;

revoke all on function solver_private.seed_matrix_employee_profiles_v2()
  from public,anon,authenticated;
grant execute on function solver_private.seed_matrix_employee_profiles_v2()
  to service_role;

drop trigger if exists matrix_employee_profiles_v2_seed_draft
  on public.matrix_versions;
create trigger matrix_employee_profiles_v2_seed_draft
after insert on public.matrix_versions
for each row execute function solver_private.seed_matrix_employee_profiles_v2();

-- Public admin API. It changes only the current draft. A new employee receives
-- a stable identity immediately, but remains hidden from Alpha 15 until the
-- Matrix draft is published.
create or replace function public.matrix_v2_employee_save_v2(
  p_employee_id uuid default null,
  p_data jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_matrix uuid;
  v_profile public.matrix_employee_profiles_v2%rowtype;
  v_employee_id uuid:=p_employee_id;
  v_employee_no text;
  v_first_name text;
  v_last_name text;
  v_email text;
  v_start date;
  v_end date;
  v_nominal integer;
  v_max_monthly integer;
  v_max_weekly integer;
  v_max_consecutive integer;
  v_minimum_rest integer;
  v_only_morning boolean;
  v_only_evening boolean;
  v_no_weekends boolean;
  v_preferred_shift text;
  v_primary_role uuid;
  v_home_location uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE')) then raise exception 'FORBIDDEN'; end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  if p_data is null or jsonb_typeof(p_data)<>'object' then
    raise exception 'INVALID_EMPLOYEE_PAYLOAD';
  end if;

  select mv.id into v_matrix
  from public.matrix_versions mv
  where mv.status='DRAFT' and mv.schema_version>=2
  order by mv.version desc limit 1 for update;
  if v_matrix is null then raise exception 'NO_MATRIX_V2_DRAFT'; end if;

  if v_employee_id is not null then
    select * into v_profile
    from public.matrix_employee_profiles_v2 p
    where p.matrix_version_id=v_matrix and p.employee_id=v_employee_id
    for update;
    if v_profile.id is null then raise exception 'MATRIX_EMPLOYEE_NOT_FOUND'; end if;
  end if;

  v_employee_no:=coalesce(nullif(trim(p_data->>'employeeNo'),''),v_profile.employee_no);
  v_first_name:=coalesce(nullif(trim(p_data->>'firstName'),''),v_profile.first_name);
  v_last_name:=coalesce(nullif(trim(p_data->>'lastName'),''),v_profile.last_name);
  v_email:=case when p_data ? 'email'
    then nullif(lower(trim(p_data->>'email')),'') else v_profile.email end;
  v_start:=case when p_data ? 'employmentStart'
    then nullif(p_data->>'employmentStart','')::date else v_profile.employment_start end;
  v_end:=case when p_data ? 'employmentEnd'
    then nullif(p_data->>'employmentEnd','')::date else v_profile.employment_end end;
  v_nominal:=coalesce(nullif(p_data->>'nominalMonthlyMinutes','')::integer,
    v_profile.nominal_monthly_minutes);
  v_max_monthly:=coalesce(nullif(p_data->>'maximumMonthlyMinutes','')::integer,
    v_profile.maximum_monthly_minutes);
  v_max_weekly:=coalesce(nullif(p_data->>'maximumWeeklyMinutes','')::integer,
    v_profile.maximum_weekly_minutes);
  v_max_consecutive:=coalesce(
    nullif(p_data->>'maximumConsecutiveDays','')::integer,
    v_profile.maximum_consecutive_days
  );
  v_minimum_rest:=case when p_data ? 'minimumRestMinutes'
    then nullif(p_data->>'minimumRestMinutes','')::integer
    else v_profile.minimum_rest_minutes end;
  v_only_morning:=case when p_data ? 'onlyMorning'
    then (p_data->>'onlyMorning')::boolean else coalesce(v_profile.only_morning,false) end;
  v_only_evening:=case when p_data ? 'onlyEvening'
    then (p_data->>'onlyEvening')::boolean else coalesce(v_profile.only_evening,false) end;
  v_no_weekends:=case when p_data ? 'noWeekends'
    then (p_data->>'noWeekends')::boolean else coalesce(v_profile.no_weekends,false) end;
  v_preferred_shift:=case when p_data ? 'preferredShiftCode'
    then nullif(trim(p_data->>'preferredShiftCode'),'') else v_profile.preferred_shift_code end;
  v_primary_role:=nullif(p_data->>'primaryRoleId','')::uuid;
  v_home_location:=nullif(p_data->>'homeLocationId','')::uuid;

  if v_employee_no is null or v_first_name is null or v_last_name is null then
    raise exception 'EMPLOYEE_IDENTITY_REQUIRED';
  end if;
  if v_end is not null and v_start is not null and v_end<v_start then
    raise exception 'INVALID_EMPLOYMENT_DATES';
  end if;
  if v_nominal is null or v_max_monthly is null or v_max_weekly is null
    or v_max_consecutive is null
    or v_nominal not between 0 and 44640
    or v_max_monthly not between v_nominal and 44640
    or v_max_weekly not between 0 and 10080
    or v_max_consecutive not between 1 and 31
    or (v_minimum_rest is not null and v_minimum_rest not between 0 and 2880)
    or (v_only_morning and v_only_evening) then
    raise exception 'INVALID_EMPLOYEE_LIMITS';
  end if;
  if exists(select 1 from public.employees e
      where e.employee_no=v_employee_no and e.id is distinct from v_employee_id) then
    raise exception 'EMPLOYEE_NUMBER_ALREADY_EXISTS';
  end if;
  if v_email is not null and exists(select 1 from public.employees e
      where lower(e.email)=v_email and e.id is distinct from v_employee_id) then
    raise exception 'EMPLOYEE_EMAIL_ALREADY_EXISTS';
  end if;

  if v_employee_id is null then
    insert into public.employees(
      employee_no,first_name,last_name,email,primary_role,
      monthly_nominal_minutes,max_weekly_minutes,max_monthly_minutes,
      max_consecutive_days,minimum_rest_minutes,only_morning,only_evening,
      no_weekends,preferred_shift,active,employment_start,employment_end
    ) values(
      v_employee_no,v_first_name,v_last_name,v_email,null,
      v_nominal,v_max_weekly,v_max_monthly,v_max_consecutive,v_minimum_rest,
      v_only_morning,v_only_evening,v_no_weekends,v_preferred_shift,false,
      v_start,v_end
    ) returning id into v_employee_id;

    insert into public.matrix_employee_profiles_v2(
      matrix_version_id,employee_id,employee_no,first_name,last_name,email,
      active,employment_start,employment_end,nominal_monthly_minutes,
      maximum_monthly_minutes,maximum_weekly_minutes,maximum_consecutive_days,
      minimum_rest_minutes,only_morning,only_evening,no_weekends,
      preferred_shift_code,created_by,updated_by
    ) values(
      v_matrix,v_employee_id,v_employee_no,v_first_name,v_last_name,v_email,
      true,v_start,v_end,v_nominal,v_max_monthly,v_max_weekly,v_max_consecutive,
      v_minimum_rest,v_only_morning,v_only_evening,v_no_weekends,
      v_preferred_shift,auth.uid(),auth.uid()
    ) returning * into v_profile;
  else
    update public.matrix_employee_profiles_v2 set
      employee_no=v_employee_no,first_name=v_first_name,last_name=v_last_name,
      email=v_email,employment_start=v_start,employment_end=v_end,
      nominal_monthly_minutes=v_nominal,maximum_monthly_minutes=v_max_monthly,
      maximum_weekly_minutes=v_max_weekly,
      maximum_consecutive_days=v_max_consecutive,
      minimum_rest_minutes=v_minimum_rest,only_morning=v_only_morning,
      only_evening=v_only_evening,no_weekends=v_no_weekends,
      preferred_shift_code=v_preferred_shift,updated_by=auth.uid(),updated_at=now()
    where id=v_profile.id returning * into v_profile;
  end if;

  if p_data ? 'primaryRoleId' then
    update public.matrix_employee_roles_v2 set is_primary=false
    where matrix_version_id=v_matrix and employee_id=v_employee_id and is_primary;
    if v_primary_role is not null then
      if not exists(select 1 from public.matrix_roles_v2 r
          where r.id=v_primary_role and r.matrix_version_id=v_matrix and r.active) then
        raise exception 'ROLE_NOT_IN_MATRIX_V2';
      end if;
      insert into public.matrix_employee_roles_v2(
        matrix_version_id,employee_id,role_id,is_primary,can_lead,active
      ) values(v_matrix,v_employee_id,v_primary_role,true,false,true)
      on conflict(matrix_version_id,employee_id,role_id) do update set
        is_primary=true,active=true;
    end if;
  end if;

  if p_data ? 'homeLocationId' then
    update public.matrix_employee_locations_v2 set home_location=false
    where matrix_version_id=v_matrix and employee_id=v_employee_id and home_location;
    if v_home_location is not null then
      if not exists(select 1 from public.matrix_locations_v2 l
          where l.id=v_home_location and l.matrix_version_id=v_matrix and l.active) then
        raise exception 'LOCATION_NOT_IN_MATRIX_V2';
      end if;
      insert into public.matrix_employee_locations_v2(
        matrix_version_id,employee_id,location_id,standard_allowed,
        overtime_allowed,home_location,active
      ) values(v_matrix,v_employee_id,v_home_location,true,false,true,true)
      on conflict(matrix_version_id,employee_id,location_id) do update set
        standard_allowed=true,home_location=true,active=true;
    end if;
  end if;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_v2_employee',v_employee_id::text,'UPSERT',
    jsonb_build_object('matrixVersionId',v_matrix,'employeeNo',v_employee_no,
      'active',v_profile.active,'employmentStart',v_start,'employmentEnd',v_end));
  return jsonb_build_object('id',v_employee_id,'profileId',v_profile.id,
    'matrixVersionId',v_matrix);
end;
$$;

create or replace function public.matrix_v2_employee_archive_v2(
  p_employee_id uuid,
  p_reason text default null,
  p_archive boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_matrix uuid;
  v_profile public.matrix_employee_profiles_v2%rowtype;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE')) then raise exception 'FORBIDDEN'; end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  if p_employee_id is null then raise exception 'EMPLOYEE_REQUIRED'; end if;
  select mv.id into v_matrix
  from public.matrix_versions mv
  where mv.status='DRAFT' and mv.schema_version>=2
  order by mv.version desc limit 1 for update;
  if v_matrix is null then raise exception 'NO_MATRIX_V2_DRAFT'; end if;
  select * into v_profile from public.matrix_employee_profiles_v2 p
  where p.matrix_version_id=v_matrix and p.employee_id=p_employee_id for update;
  if v_profile.id is null then raise exception 'MATRIX_EMPLOYEE_NOT_FOUND'; end if;

  update public.matrix_employee_profiles_v2 set
    active=not p_archive,
    archived_at=case when p_archive then now() else null end,
    archived_by=case when p_archive then auth.uid() else null end,
    archive_reason=case when p_archive then nullif(trim(p_reason),'') else null end,
    updated_by=auth.uid(),updated_at=now()
  where id=v_profile.id returning * into v_profile;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_v2_employee',p_employee_id::text,
    case when p_archive then 'ARCHIVE' else 'RESTORE' end,
    jsonb_build_object('matrixVersionId',v_matrix,'reason',
      case when p_archive then nullif(trim(p_reason),'') else null end));
  return jsonb_build_object('id',p_employee_id,'active',v_profile.active,
    'matrixVersionId',v_matrix);
end;
$$;

-- The directory is exposed only through a security-definer RPC. It selects
-- exactly the same draft/active Matrix boundary as matrix_v2_workspace.
create or replace function public.matrix_v2_employee_directory_v2()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_matrix uuid;
  v_manage boolean;
  v_owner_admin boolean;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  v_owner_admin:=public.has_app_role('OWNER') or public.has_app_role('ADMIN');
  v_manage:=v_owner_admin or public.has_app_role('HR_FINANCE');
  if v_owner_admin then
    select mv.id into v_matrix from public.matrix_versions mv
    where mv.status='DRAFT' and mv.schema_version>=2
    order by mv.version desc limit 1;
  end if;
  if v_matrix is null then
    select mv.id into v_matrix from public.matrix_versions mv
    where mv.status='ACTIVE' and mv.schema_version>=2
    order by mv.version desc limit 1;
  end if;
  if v_matrix is null then raise exception 'MATRIX_V2_NOT_FOUND'; end if;

  return jsonb_build_object(
    'matrixVersionId',v_matrix,
    'workforceHash',(select mv.workforce_hash from public.matrix_versions mv
      where mv.id=v_matrix),
    'activeCount',(select count(*) from public.matrix_employee_profiles_v2 p
      where p.matrix_version_id=v_matrix and p.active),
    'archivedCount',(select count(*) from public.matrix_employee_profiles_v2 p
      where p.matrix_version_id=v_matrix and not p.active),
    'employees',coalesce((select jsonb_agg(jsonb_build_object(
      'id',p.employee_id,'profileId',p.id,'employeeNo',p.employee_no,
      'firstName',p.first_name,'lastName',p.last_name,
      'email',case when v_manage or e.auth_user_id=auth.uid() then p.email else null end,
      'active',p.active,'employmentStart',p.employment_start,
      'employmentEnd',p.employment_end,
      'nominalMonthlyMinutes',p.nominal_monthly_minutes,
      'maximumMonthlyMinutes',p.maximum_monthly_minutes,
      'maximumWeeklyMinutes',p.maximum_weekly_minutes,
      'maximumConsecutiveDays',p.maximum_consecutive_days,
      'minimumRestMinutes',p.minimum_rest_minutes,
      'onlyMorning',p.only_morning,'onlyEvening',p.only_evening,
      'noWeekends',p.no_weekends,'preferredShiftCode',p.preferred_shift_code,
      'archivedAt',p.archived_at,'archiveReason',p.archive_reason,
      'primaryRoleId',(select er.role_id from public.matrix_employee_roles_v2 er
        where er.matrix_version_id=v_matrix and er.employee_id=p.employee_id
          and er.is_primary and er.active order by er.created_at limit 1),
      'homeLocationId',(select el.location_id from public.matrix_employee_locations_v2 el
        where el.matrix_version_id=v_matrix and el.employee_id=p.employee_id
          and el.home_location and el.active order by el.created_at limit 1)
    ) order by p.active desc,p.last_name,p.first_name,p.employee_no)
    from public.matrix_employee_profiles_v2 p
    join public.employees e on e.id=p.employee_id
    where p.matrix_version_id=v_matrix
      and (v_manage or e.auth_user_id=auth.uid())),'[]'::jsonb)
  );
end;
$$;

revoke all on function public.matrix_v2_employee_save_v2(uuid,jsonb)
  from public,anon,authenticated;
revoke all on function public.matrix_v2_employee_archive_v2(uuid,text,boolean)
  from public,anon,authenticated;
revoke all on function public.matrix_v2_employee_directory_v2()
  from public,anon,authenticated;
grant execute on function public.matrix_v2_employee_save_v2(uuid,jsonb)
  to authenticated;
grant execute on function public.matrix_v2_employee_archive_v2(uuid,text,boolean)
  to authenticated;
grant execute on function public.matrix_v2_employee_directory_v2()
  to authenticated;
grant execute on function public.matrix_v2_employee_save_v2(uuid,jsonb),
  public.matrix_v2_employee_archive_v2(uuid,text,boolean),
  public.matrix_v2_employee_directory_v2() to service_role;

-- On publication, the draft becomes the only live workforce used by future
-- snapshots. Legacy columns are synchronized as a compatibility projection;
-- no old Matrix profile is changed.
create or replace function solver_private.activate_matrix_employee_profiles_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_document jsonb;
begin
  if old.status='DRAFT' and new.status='ACTIVE' and new.schema_version>=2 then
    if exists(select 1 from public.matrix_employee_profiles_v2 p
      where p.matrix_version_id=new.id and p.active and (
        not exists(select 1 from public.matrix_employee_roles_v2 er
          where er.matrix_version_id=new.id and er.employee_id=p.employee_id
            and er.active)
        or not exists(select 1 from public.matrix_employee_locations_v2 el
          where el.matrix_version_id=new.id and el.employee_id=p.employee_id
            and el.active and (el.standard_allowed or el.overtime_allowed))
      )) then raise exception 'ACTIVE_EMPLOYEE_REQUIRES_ROLE_AND_LOCATION'; end if;

    update public.employees e set
      employee_no=p.employee_no,first_name=p.first_name,last_name=p.last_name,
      email=p.email,monthly_nominal_minutes=p.nominal_monthly_minutes,
      max_monthly_minutes=p.maximum_monthly_minutes,
      max_weekly_minutes=p.maximum_weekly_minutes,
      max_consecutive_days=p.maximum_consecutive_days,
      minimum_rest_minutes=p.minimum_rest_minutes,
      only_morning=p.only_morning,only_evening=p.only_evening,
      no_weekends=p.no_weekends,preferred_shift=p.preferred_shift_code,
      employment_start=p.employment_start,employment_end=p.employment_end,
      active=p.active,archived_at=p.archived_at,archived_by=p.archived_by,
      archive_reason=p.archive_reason,
      primary_role=(
        select case when exists(
          select 1 from unnest(enum_range(null::public.employee_role)) legacy(value)
          where legacy.value::text=r.code
        ) then r.code::public.employee_role else null end
        from public.matrix_employee_roles_v2 er
        join public.matrix_roles_v2 r on r.id=er.role_id
        where er.matrix_version_id=new.id and er.employee_id=p.employee_id
          and er.active and er.is_primary
        order by er.created_at limit 1
      ),
      updated_at=now()
    from public.matrix_employee_profiles_v2 p
    where p.matrix_version_id=new.id and e.id=p.employee_id;

    select coalesce(jsonb_agg(
      to_jsonb(p)-array['id','matrix_version_id','created_at','updated_at',
        'created_by','updated_by'] order by p.employee_id),'[]'::jsonb)
    into v_document
    from public.matrix_employee_profiles_v2 p where p.matrix_version_id=new.id;
    new.workforce_hash:=encode(extensions.digest(
      convert_to(v_document::text,'UTF8'),'sha256'),'hex');
    new.workforce_count:=jsonb_array_length(v_document);
  end if;
  return new;
end;
$$;

revoke all on function solver_private.activate_matrix_employee_profiles_v2()
  from public,anon,authenticated;
grant execute on function solver_private.activate_matrix_employee_profiles_v2()
  to service_role;

drop trigger if exists matrix_employee_profiles_v2_activate
  on public.matrix_versions;
create trigger matrix_employee_profiles_v2_activate
before update of status on public.matrix_versions
for each row execute function solver_private.activate_matrix_employee_profiles_v2();

-- Historical workspaces resolve employee display data through the Matrix
-- version attached to each run, never through the mutable identity table.
create or replace function solver_private.variant_set_workspace_v2(
  p_variant_ids uuid[],
  p_context jsonb,
  p_can_view_finance boolean
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with requested as (
    select distinct x.variant_id
    from unnest(coalesce(p_variant_ids,'{}'::uuid[])) x(variant_id)
  ), grouped_shifts as (
    select ps.slot_group_key,ps.shift_template_id,ps.location_id,ps.shift_date,
      ps.starts_at,ps.ends_at
    from public.plan_shifts_v2 ps
    join requested r on r.variant_id=ps.variant_id
    group by ps.slot_group_key,ps.shift_template_id,ps.location_id,ps.shift_date,
      ps.starts_at,ps.ends_at
  )
  select jsonb_build_object(
    'context',coalesce(p_context,'{}'::jsonb),
    'variants',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',v.id,'runId',v.run_id,'name',v.name,'status',v.status,
        'recommended',v.recommended,'selected',v.selected,
        'strategy',jsonb_build_object('id',st.id,'name',st.name),
        'scope',jsonb_build_object('type',run.scope_type,
          'role',case when role.id is null then null else
            jsonb_build_object('id',role.id,'name',role.name) end),
        'assignmentCount',v.assignment_count,'unfilledCount',v.unfilled_count,
        'solverStatus',v.solver_status,
        'finance',case when p_can_view_finance then jsonb_build_object(
          'baseCostMinor',fin.base_cost_minor,
          'additionsCostMinor',fin.additions_cost_minor,
          'totalCostMinor',fin.total_cost_minor,
          'currency',nullif(snap.snapshot->>'currency',''),
          'budgetMinor',fin.budget_minor) else null end
      ) order by run.scope_type,coalesce(role.sort_order,0),rs.ordinal)
      from requested req
      join public.plan_variants_v2 v on v.id=req.variant_id
      join public.optimization_runs_v2 run on run.id=v.run_id
      join public.optimization_run_strategies_v2 rs on rs.id=v.run_strategy_id
      join public.matrix_strategies_v2 st on st.id=v.strategy_id
      left join public.matrix_roles_v2 role on role.id=run.scope_role_id
      left join solver_private.plan_variant_finance_v2 fin on fin.variant_id=v.id
      left join solver_private.optimization_snapshots_v2 snap on snap.run_id=run.id
    ),'[]'::jsonb),
    'shifts',coalesce((
      select jsonb_agg(jsonb_build_object(
        'slotGroupKey',sh.slot_group_key,'date',sh.shift_date,
        'startsAt',sh.starts_at,'endsAt',sh.ends_at,
        'location',jsonb_build_object('id',loc.id,'name',loc.name,
          'timezone',loc.timezone),
        'shiftTemplate',jsonb_build_object('id',tmpl.id,'name',tmpl.name),
        'assignments',coalesce((
          select jsonb_agg(jsonb_build_object(
            'id',pa.id,'slotKey',pa.slot_key,
            'employee',jsonb_build_object(
              'id',employee.employee_id,'employeeNo',employee.employee_no,
              'firstName',employee.first_name,'lastName',employee.last_name,
              'nominalMonthlyMinutes',employee.nominal_monthly_minutes),
            'role',jsonb_build_object('id',role.id,'name',role.name),
            'duties',coalesce((select jsonb_agg(jsonb_build_object(
                'id',d.id,'name',d.name) order by d.sort_order,d.name)
              from public.plan_assignment_duties_v2 ad
              join public.matrix_duties_v2 d on d.id=ad.duty_id
              where ad.assignment_id=pa.id),'[]'::jsonb),
            'locked',pa.locked,
            'costMinor',case when p_can_view_finance then coalesce((
              select sum(component.amount_minor)
              from solver_private.plan_assignment_cost_components_v2 component
              where component.assignment_id=pa.id
            ),0) else null end
          ) order by role.sort_order,role.name,employee.last_name,
            employee.first_name,pa.slot_key)
          from public.plan_assignments_v2 pa
          join requested assignment_request
            on assignment_request.variant_id=pa.variant_id
          join public.plan_variants_v2 assignment_variant
            on assignment_variant.id=pa.variant_id
          join public.optimization_runs_v2 assignment_run
            on assignment_run.id=assignment_variant.run_id
          join public.plan_shifts_v2 aps on aps.id=pa.shift_id
          join public.matrix_employee_profiles_v2 employee
            on employee.matrix_version_id=assignment_run.matrix_version_id
            and employee.employee_id=pa.employee_id
          join public.matrix_roles_v2 role on role.id=pa.role_id
          where aps.slot_group_key=sh.slot_group_key
            and aps.shift_template_id=sh.shift_template_id
            and aps.location_id=sh.location_id and aps.shift_date=sh.shift_date
            and aps.starts_at=sh.starts_at and aps.ends_at=sh.ends_at
        ),'[]'::jsonb)
      ) order by sh.starts_at,loc.sort_order,tmpl.sort_order,sh.slot_group_key)
      from grouped_shifts sh
      join public.matrix_locations_v2 loc on loc.id=sh.location_id
      join public.matrix_shift_templates_v2 tmpl on tmpl.id=sh.shift_template_id
    ),'[]'::jsonb),
    'issues',coalesce((select jsonb_agg(jsonb_build_object(
      'id',i.id,'variantId',i.variant_id,'slotKey',i.slot_key,'code',i.issue_code,
      'severity',i.severity,'message',i.message,
      'role',case when role.id is null then null else
        jsonb_build_object('id',role.id,'name',role.name) end,
      'duty',case when duty.id is null then null else
        jsonb_build_object('id',duty.id,'name',duty.name) end
    ) order by i.severity desc,i.id)
      from public.plan_issues_v2 i
      join requested r on r.variant_id=i.variant_id
      left join public.matrix_roles_v2 role on role.id=i.role_id
      left join public.matrix_duties_v2 duty on duty.id=i.duty_id
    ),'[]'::jsonb),
    'finance',case when p_can_view_finance then (
      select jsonb_build_object(
        'baseCostMinor',coalesce(sum(f.base_cost_minor),0),
        'additionsCostMinor',coalesce(sum(f.additions_cost_minor),0),
        'totalCostMinor',coalesce(sum(f.total_cost_minor),0),
        'currency',case when count(distinct snap.snapshot->>'currency')=1
          then min(snap.snapshot->>'currency') else null end,
        'budgetMinor',case when count(distinct f.budget_minor)=1
          then min(f.budget_minor) else null end)
      from requested r
      join public.plan_variants_v2 v on v.id=r.variant_id
      join solver_private.plan_variant_finance_v2 f on f.variant_id=r.variant_id
      join solver_private.optimization_snapshots_v2 snap on snap.run_id=v.run_id
    ) else null end
  );
$$;

revoke all on function solver_private.variant_set_workspace_v2(uuid[],jsonb,boolean)
  from public,anon,authenticated;
grant execute on function solver_private.variant_set_workspace_v2(uuid[],jsonb,boolean)
  to service_role;

-- Employee-profile writes are planning-input mutations and must invalidate a
-- snapshot attempt exactly like availability or Matrix structure changes.
drop trigger if exists planning_revision_v2_bump
  on public.matrix_employee_profiles_v2;
create trigger planning_revision_v2_bump
before insert or update or delete or truncate on public.matrix_employee_profiles_v2
for each statement execute function solver_private.bump_planning_revision_v2();

-- The row lock makes publication and every child-table mutation mutually
-- exclusive even for a privileged internal role. Once a version is ACTIVE or
-- ARCHIVED, its content can no longer drift away from content_hash.
create or replace function solver_private.guard_matrix_child_immutable_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_matrix_id uuid;
  v_status text;
begin
  if tg_op='UPDATE' and old.matrix_version_id<>new.matrix_version_id then
    raise exception 'MATRIX_VERSION_REPARENT_FORBIDDEN';
  end if;
  v_matrix_id:=case when tg_op='DELETE'
    then old.matrix_version_id else new.matrix_version_id end;
  select mv.status into v_status
  from public.matrix_versions mv
  where mv.id=v_matrix_id
  for share;
  if v_status is null then raise exception 'MATRIX_VERSION_NOT_FOUND'; end if;
  if v_status<>'DRAFT' then raise exception 'MATRIX_VERSION_IMMUTABLE'; end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;

revoke all on function solver_private.guard_matrix_child_immutable_v2()
  from public,anon,authenticated;
grant execute on function solver_private.guard_matrix_child_immutable_v2()
  to service_role;

do $$
declare t text;
begin
  foreach t in array array[
    'matrix_roles_v2','matrix_locations_v2','matrix_duties_v2',
    'matrix_shift_templates_v2','matrix_role_duties_v2','matrix_scenarios_v2',
    'matrix_staffing_rules_v2','matrix_strategies_v2',
    'matrix_strategy_objectives_v2','matrix_scenario_strategies_v2',
    'matrix_employee_profiles_v2','matrix_employee_roles_v2',
    'matrix_employee_locations_v2','matrix_employee_duties_v2',
    'matrix_pay_rules_v2','matrix_pay_rule_roles_v2',
    'matrix_pay_rule_duties_v2','matrix_pay_rule_locations_v2',
    'matrix_pay_rule_shifts_v2','matrix_scenario_pay_rule_overrides_v2',
    'matrix_scenario_budgets_v2'
  ] loop
    execute format(
      'drop trigger if exists matrix_v2_immutable_guard on public.%I',t
    );
    execute format(
      'create trigger matrix_v2_immutable_guard '
      ||'before insert or update or delete on public.%I for each row '
      ||'execute function solver_private.guard_matrix_child_immutable_v2()',t
    );
  end loop;
end $$;

create or replace function solver_private.guard_matrix_version_immutable_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op='DELETE' then
    if old.status<>'DRAFT' then raise exception 'MATRIX_VERSION_IMMUTABLE'; end if;
    return old;
  end if;
  if old.status='ARCHIVED' then raise exception 'MATRIX_VERSION_IMMUTABLE'; end if;
  if old.status='ACTIVE' then
    if new.status<>'ARCHIVED'
      or to_jsonb(new)-array['status','effective_to']
        <>to_jsonb(old)-array['status','effective_to'] then
      raise exception 'INVALID_MATRIX_VERSION_TRANSITION';
    end if;
    return new;
  end if;
  if old.status='DRAFT' and new.status='ARCHIVED' and
    to_jsonb(new)-array['status','effective_to']
      <>to_jsonb(old)-array['status','effective_to'] then
    raise exception 'INVALID_MATRIX_VERSION_TRANSITION';
  end if;
  if old.status='DRAFT' and new.status not in ('DRAFT','ACTIVE','ARCHIVED') then
    raise exception 'INVALID_MATRIX_VERSION_TRANSITION';
  end if;
  return new;
end;
$$;

revoke all on function solver_private.guard_matrix_version_immutable_v2()
  from public,anon,authenticated;
grant execute on function solver_private.guard_matrix_version_immutable_v2()
  to service_role;

drop trigger if exists zz_matrix_version_immutable_v2 on public.matrix_versions;
create trigger zz_matrix_version_immutable_v2
before update or delete on public.matrix_versions
for each row execute function solver_private.guard_matrix_version_immutable_v2();

comment on table public.matrix_employee_profiles_v2 is
  'Versioned employee scheduling profiles. Active and archived Matrix versions are immutable.';
comment on function public.matrix_v2_employee_save_v2(uuid,jsonb) is
  'Adds or edits an employee only inside the current Matrix v2 draft.';
comment on function public.matrix_v2_employee_archive_v2(uuid,text,boolean) is
  'Archives or restores a draft employee without deleting historical identity.';
