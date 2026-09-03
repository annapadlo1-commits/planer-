-- GRAFIK PRO UAT: planning categories + standard/backup role semantics.
-- A category is the user-facing generation scope. Roles and duties remain the
-- exact staffing requirements solved inside that scope.

create table if not exists public.matrix_role_categories_v2 (
  id uuid primary key default gen_random_uuid(),
  matrix_version_id uuid not null references public.matrix_versions(id) on delete cascade,
  logical_id uuid not null default gen_random_uuid(),
  code text not null check(length(trim(code)) between 1 and 80),
  name text not null check(length(trim(name)) between 1 and 160),
  description text,
  color text not null default '#7257d8' check(color ~ '^#[0-9A-Fa-f]{6}$'),
  sort_order integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(matrix_version_id,id),
  unique(matrix_version_id,logical_id),
  unique(matrix_version_id,code)
);

alter table public.matrix_roles_v2 add column if not exists category_id uuid;
do $$ begin
  if not exists(select 1 from pg_constraint where conname='matrix_roles_v2_category_fk') then
    alter table public.matrix_roles_v2 add constraint matrix_roles_v2_category_fk
      foreign key(matrix_version_id,category_id)
      references public.matrix_role_categories_v2(matrix_version_id,id) on delete restrict;
  end if;
end $$;

alter table public.matrix_employee_roles_v2
  add column if not exists assignment_mode text not null default 'STANDARD',
  add column if not exists backup_priority integer not null default 100;
do $$ begin
  if not exists(select 1 from pg_constraint where conname='matrix_employee_roles_v2_assignment_mode_check') then
    alter table public.matrix_employee_roles_v2 add constraint matrix_employee_roles_v2_assignment_mode_check
      check(assignment_mode in ('STANDARD','BACKUP'));
  end if;
  if not exists(select 1 from pg_constraint where conname='matrix_employee_roles_v2_backup_priority_check') then
    alter table public.matrix_employee_roles_v2 add constraint matrix_employee_roles_v2_backup_priority_check
      check(backup_priority between 1 and 999);
  end if;
  if not exists(select 1 from pg_constraint where conname='matrix_employee_roles_v2_primary_standard_check') then
    alter table public.matrix_employee_roles_v2 add constraint matrix_employee_roles_v2_primary_standard_check
      check(not is_primary or assignment_mode='STANDARD');
  end if;
end $$;

alter table public.matrix_employee_profiles_v2
  add column if not exists employment_stage text not null default 'REGULAR',
  add column if not exists probation_end date;
do $$ begin
  if not exists(select 1 from pg_constraint where conname='matrix_employee_profiles_v2_employment_stage_check') then
    alter table public.matrix_employee_profiles_v2 add constraint matrix_employee_profiles_v2_employment_stage_check
      check(employment_stage in ('PROBATION','REGULAR','NOTICE'));
  end if;
end $$;

insert into public.matrix_role_categories_v2(
  id,matrix_version_id,logical_id,code,name,description,color,sort_order,active
)
select public.matrix_v2_stable_uuid('ROLE_CATEGORY:'||mv.id::text||':'||seed.code),mv.id,
  public.matrix_v2_stable_uuid('ROLE_CATEGORY_LOGICAL:'||seed.code),seed.code,seed.name,
  seed.description,seed.color,seed.sort_order,true
from public.matrix_versions mv
cross join (values
  ('BAR','Bar','Barmani i wsparcie baru','#C9A51D',10),
  ('SALA','Sala','Kelnerzy, host i runnerzy','#7257D8',20),
  ('PIZZABAR','Pizzabar','Zespół pizzabaru','#C62BBE',30),
  ('ZMYWAK','Zmywak','Zespół zmywaka','#2F75B5',40),
  ('KUCHNIA','Kuchnia','Przygotowanie i kuchnia','#0F8F7A',50)
) seed(code,name,description,color,sort_order)
where mv.schema_version>=2
on conflict(matrix_version_id,code) do update set
  name=excluded.name,description=excluded.description,color=excluded.color,
  sort_order=excluded.sort_order,active=true,updated_at=now();

-- This is a one-time structural backfill. Published versions normally stay
-- immutable, but their existing role rows must receive the new category FK.
-- The guard is restored immediately after both deterministic backfills.
drop trigger if exists matrix_v2_immutable_guard on public.matrix_roles_v2;

update public.matrix_roles_v2 role_row set category_id=category.id
from public.matrix_role_categories_v2 category
where category.matrix_version_id=role_row.matrix_version_id
  and category.code=case
    when upper(role_row.code) in ('BARMAN','BARBACK') then 'BAR'
    when upper(role_row.code) in ('KELNER','HOST','RUNNER') then 'SALA'
    when upper(role_row.code) in ('PIZZABAR','PIZZAIOLO') then 'PIZZABAR'
    when upper(role_row.code)='ZMYWAK' then 'ZMYWAK'
    when upper(role_row.code)='PREP' then 'KUCHNIA'
    else '' end
  and role_row.category_id is null;

-- Preserve every custom role by creating a configurable singleton category.
insert into public.matrix_role_categories_v2(
  id,matrix_version_id,logical_id,code,name,color,sort_order,active
)
select public.matrix_v2_stable_uuid('ROLE_CATEGORY:'||role_row.matrix_version_id::text||':'||role_row.code),
  role_row.matrix_version_id,public.matrix_v2_stable_uuid('ROLE_CATEGORY_LOGICAL:'||role_row.code),
  role_row.code,role_row.name,role_row.color,role_row.sort_order,true
from public.matrix_roles_v2 role_row
where role_row.category_id is null
on conflict(matrix_version_id,code) do nothing;

update public.matrix_roles_v2 role_row set category_id=category.id
from public.matrix_role_categories_v2 category
where category.matrix_version_id=role_row.matrix_version_id
  and category.code=role_row.code and role_row.category_id is null;

create trigger matrix_v2_immutable_guard
before insert or update or delete on public.matrix_roles_v2
for each row execute function solver_private.guard_matrix_child_immutable_v2();

-- matrix_v2_create_draft clones roles generically. Inherit their category at
-- insert time so every later draft keeps exactly the same planning hierarchy.
create or replace function solver_private.matrix_role_category_inherit_uat_v1()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_source record; v_category uuid;
begin
  if new.category_id is not null then return new; end if;
  select category.logical_id,category.code,category.name,category.description,
    category.color,category.sort_order,category.active
  into v_source
  from public.matrix_roles_v2 source_role
  join public.matrix_role_categories_v2 category on category.id=source_role.category_id
  where source_role.logical_id=new.logical_id and source_role.matrix_version_id<>new.matrix_version_id
  order by source_role.updated_at desc limit 1;
  if v_source.code is null then return new; end if;
  insert into public.matrix_role_categories_v2(
    matrix_version_id,logical_id,code,name,description,color,sort_order,active
  ) values(
    new.matrix_version_id,v_source.logical_id,v_source.code,v_source.name,
    v_source.description,v_source.color,v_source.sort_order,v_source.active
  ) on conflict(matrix_version_id,code) do update set
    name=excluded.name,description=excluded.description,color=excluded.color,
    sort_order=excluded.sort_order,active=excluded.active,updated_at=now()
  returning id into v_category;
  new.category_id:=v_category;
  return new;
end;
$$;
drop trigger if exists matrix_role_category_inherit_uat_v1 on public.matrix_roles_v2;
create trigger matrix_role_category_inherit_uat_v1 before insert on public.matrix_roles_v2
for each row execute function solver_private.matrix_role_category_inherit_uat_v1();

alter table public.matrix_role_categories_v2 enable row level security;
drop policy if exists matrix_role_categories_v2_select on public.matrix_role_categories_v2;
create policy matrix_role_categories_v2_select on public.matrix_role_categories_v2
  for select to authenticated using(
    public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('ROLE_MANAGER') or public.has_app_role('HR_FINANCE')
  );

-- Workbook hook. Dictionaries are written in PRE; workforce semantics in POST.
alter function solver_private.matrix_v2_full_import_phase_uat_v1(jsonb,text)
  rename to matrix_v2_full_import_phase_before_categories_uat_v1;

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
  v_employee uuid;
  v_role uuid;
  v_role_code text;
  v_mode text;
  v_priority integer;
  v_count integer:=0;
begin
  v_result:=solver_private.matrix_v2_full_import_phase_before_categories_uat_v1(p_configuration,p_phase);
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

-- Workspace enrichment for the editor and complete workbook export.
alter function public.matrix_v2_workspace(date) rename to matrix_v2_workspace_before_categories_uat_v1;
create function public.matrix_v2_workspace(p_month date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_result jsonb; v_matrix uuid; v_employees jsonb; v_employee jsonb;
begin
  v_result:=public.matrix_v2_workspace_before_categories_uat_v1(p_month);
  v_matrix:=(v_result->'matrixVersion'->>'id')::uuid;
  v_result:=jsonb_set(v_result,'{roleCategories}',coalesce((select jsonb_agg(to_jsonb(category) order by category.sort_order,category.code)
    from public.matrix_role_categories_v2 category where category.matrix_version_id=v_matrix),'[]'::jsonb),true);
  v_result:=jsonb_set(v_result,'{roles}',coalesce((select jsonb_agg(to_jsonb(role_row) order by role_row.sort_order,role_row.code)
    from public.matrix_roles_v2 role_row where role_row.matrix_version_id=v_matrix),'[]'::jsonb),true);
  v_employees:='[]'::jsonb;
  for v_employee in select value from jsonb_array_elements(coalesce(v_result->'employees','[]'::jsonb)) loop
    v_employee:=v_employee||coalesce((select jsonb_build_object(
      'employmentStage',profile.employment_stage,'probationEnd',profile.probation_end
    ) from public.matrix_employee_profiles_v2 profile
      where profile.matrix_version_id=v_matrix and profile.employee_id=(v_employee->>'id')::uuid),'{}'::jsonb);
    v_employees:=v_employees||jsonb_build_array(v_employee);
  end loop;
  v_result:=jsonb_set(v_result,'{employees}',v_employees,true);
  v_result:=jsonb_set(v_result,'{adHocWorkers}',coalesce((select jsonb_agg(to_jsonb(pool) order by pool.display_name,pool.id)
    from public.recovery_ad_hoc_pool_v2 pool where pool.active),'[]'::jsonb),true);
  return v_result;
end;
$$;

create or replace function public.matrix_v2_employee_save_uat_v4(
  p_employee_id uuid default null,
  p_data jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_result jsonb; v_employee uuid; v_matrix uuid; v_stage text;
begin
  v_result:=public.matrix_v2_employee_save_uat_v2(p_employee_id,p_data);
  v_employee:=(v_result->>'id')::uuid;
  select id into v_matrix from public.matrix_versions where status='DRAFT' and schema_version>=2 order by version desc limit 1;
  v_stage:=case upper(coalesce(nullif(p_data->>'employmentStage',''),'REGULAR')) when 'PROBATION' then 'PROBATION' when 'NOTICE' then 'NOTICE' else 'REGULAR' end;
  update public.matrix_employee_profiles_v2 set employment_stage=v_stage,
    probation_end=nullif(p_data->>'probationEnd','')::date,updated_by=auth.uid(),updated_at=now()
  where matrix_version_id=v_matrix and employee_id=v_employee;
  return v_result||jsonb_build_object('employmentStage',v_stage,'probationEnd',nullif(p_data->>'probationEnd',''));
end;
$$;

-- Preserve the additional role/category semantics for direct edits in the
-- guided editor as well as for workbook imports.
alter function public.matrix_v2_admin_save_alpha16(text,uuid,jsonb)
  rename to matrix_v2_admin_save_before_categories_uat_v1;
create function public.matrix_v2_admin_save_alpha16(
  p_kind text,p_id uuid,p_data jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_result jsonb; v_id uuid; v_matrix uuid; v_category uuid; v_mode text; v_priority integer;
begin
  v_result:=public.matrix_v2_admin_save_before_categories_uat_v1(p_kind,p_id,p_data);
  v_id:=(v_result->>'id')::uuid;
  if upper(trim(p_kind))='ROLE' then
    select matrix_version_id into v_matrix from public.matrix_roles_v2 where id=v_id;
    v_category:=nullif(p_data->>'categoryId','')::uuid;
    if v_category is null or not exists(select 1 from public.matrix_role_categories_v2
      where id=v_category and matrix_version_id=v_matrix and active) then
      raise exception 'ROLE_CATEGORY_NOT_FOUND';
    end if;
    update public.matrix_roles_v2 set category_id=v_category,updated_at=now() where id=v_id;
  elsif upper(trim(p_kind))='EMPLOYEE_ROLE' then
    v_mode:=case upper(coalesce(nullif(p_data->>'assignmentMode',''),'STANDARD'))
      when 'BACKUP' then 'BACKUP' else 'STANDARD' end;
    v_priority:=greatest(1,least(999,coalesce(nullif(p_data->>'backupPriority','')::integer,100)));
    update public.matrix_employee_roles_v2 set
      assignment_mode=case when is_primary then 'STANDARD' else v_mode end,
      backup_priority=v_priority,updated_by=auth.uid(),updated_at=now()
    where id=v_id;
  end if;
  return v_result;
end;
$$;

-- Solver configuration exposes categories with one stable technical anchor.
create or replace function public.optimizer_role_categories_uat_v1(p_month date)
returns jsonb
language plpgsql stable security definer set search_path=''
as $$
declare v_matrix uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select id into v_matrix from public.matrix_versions
  where status in ('ACTIVE','ARCHIVED') and schema_version>=2
    and effective_from<=date_trunc('month',p_month)::date
  order by effective_from desc,version desc limit 1;
  return jsonb_build_object('categories',coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',category.id,'code',category.code,'name',category.name,'color',category.color,
      'sortOrder',category.sort_order,'anchorRoleId',roles.anchor_role_id,
      'roleIds',roles.role_ids,'roleNames',roles.role_names
    ) order by category.sort_order,category.code)
    from public.matrix_role_categories_v2 category
    cross join lateral (
      select (array_agg(role_row.id order by
          case when exists(select 1 from public.matrix_staffing_rules_v2 staffing
            where staffing.matrix_version_id=v_matrix and staffing.role_id=role_row.id and staffing.active) then 0 else 1 end,
          role_row.sort_order,role_row.code))[1] anchor_role_id,
        jsonb_agg(role_row.id order by role_row.sort_order,role_row.code) role_ids,
        jsonb_agg(role_row.name order by role_row.sort_order,role_row.code) role_names
      from public.matrix_roles_v2 role_row
      where role_row.matrix_version_id=v_matrix and role_row.category_id=category.id and role_row.active
    ) roles
    where category.matrix_version_id=v_matrix and category.active and roles.anchor_role_id is not null
  ),'[]'::jsonb));
end;
$$;

-- Build a category snapshot by filtering the canonical company snapshot. The
-- anchor role is only a backwards-compatible transport key in optimization_runs_v2.
alter function solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)
  rename to build_snapshot_payload_before_categories_uat_v1;
create function solver_private.build_snapshot_payload_v2(
  p_run_id uuid,p_month date,p_matrix_version_id uuid,p_scenario_id uuid,
  p_scope_type text,p_scope_role_id uuid
) returns jsonb
language plpgsql stable security definer set search_path=''
as $$
declare
  v_snapshot jsonb;
  v_category uuid;
  v_role_ids jsonb;
  v_slot_ids jsonb;
  v_employees jsonb:='[]'::jsonb;
  v_employee jsonb;
  v_grants jsonb;
  v_external jsonb;
  v_employee_id uuid;
begin
  if p_scope_type<>'ROLE' or p_scope_role_id is null then
    return solver_private.build_snapshot_payload_before_categories_uat_v1(
      p_run_id,p_month,p_matrix_version_id,p_scenario_id,p_scope_type,p_scope_role_id);
  end if;
  select category_id into v_category from public.matrix_roles_v2
    where id=p_scope_role_id and matrix_version_id=p_matrix_version_id and active;
  if v_category is null then raise exception 'SCOPE_CATEGORY_NOT_FOUND'; end if;
  select jsonb_agg(id::text) into v_role_ids from public.matrix_roles_v2
    where matrix_version_id=p_matrix_version_id and category_id=v_category and active;
  v_snapshot:=solver_private.build_snapshot_payload_before_categories_uat_v1(
    p_run_id,p_month,p_matrix_version_id,p_scenario_id,'COMPANY',null);
  v_snapshot:=jsonb_set(v_snapshot,'{roles}',coalesce((select jsonb_agg(value order by ordinality)
    from jsonb_array_elements(coalesce(v_snapshot->'roles','[]'::jsonb)) with ordinality
    where value->>'id' in(select jsonb_array_elements_text(v_role_ids))),'[]'::jsonb),true);
  v_snapshot:=jsonb_set(v_snapshot,'{demand}',coalesce((select jsonb_agg(value order by ordinality)
    from jsonb_array_elements(coalesce(v_snapshot->'demand','[]'::jsonb)) with ordinality
    where value->>'roleId' in(select jsonb_array_elements_text(v_role_ids))),'[]'::jsonb),true);
  v_snapshot:=jsonb_set(v_snapshot,'{slots}',coalesce((select jsonb_agg(value order by ordinality)
    from jsonb_array_elements(coalesce(v_snapshot->'slots','[]'::jsonb)) with ordinality
    where value->>'roleId' in(select jsonb_array_elements_text(v_role_ids))),'[]'::jsonb),true);
  select coalesce(jsonb_agg(value->>'slotId'),'[]'::jsonb) into v_slot_ids
    from jsonb_array_elements(coalesce(v_snapshot->'slots','[]'::jsonb));
  v_snapshot:=jsonb_set(v_snapshot,'{baselineAssignments}',coalesce((select jsonb_agg(value order by ordinality)
    from jsonb_array_elements(coalesce(v_snapshot->'baselineAssignments','[]'::jsonb)) with ordinality
    where value->>'slotId' in(select jsonb_array_elements_text(v_slot_ids))),'[]'::jsonb),true);
  v_snapshot:=jsonb_set(v_snapshot,'{lockedAssignments}',coalesce((select jsonb_agg(value order by ordinality)
    from jsonb_array_elements(coalesce(v_snapshot->'lockedAssignments','[]'::jsonb)) with ordinality
    where value->>'slotId' in(select jsonb_array_elements_text(v_slot_ids))),'[]'::jsonb),true);

  for v_employee in select value from jsonb_array_elements(coalesce(v_snapshot->'employees','[]'::jsonb)) loop
    v_employee_id:=(v_employee->>'id')::uuid;
    select coalesce(jsonb_agg(grant_row order by grant_row->>'assignmentMode',grant_row->>'backupPriority',grant_row->>'roleId'),'[]'::jsonb)
    into v_grants from (
      select jsonb_strip_nulls(jsonb_build_object(
        'roleId',employee_role.role_id,'validFrom',employee_role.valid_from,'validTo',employee_role.valid_to,
        'assignmentMode',employee_role.assignment_mode,'backupPriority',employee_role.backup_priority
      )) grant_row
      from public.matrix_employee_roles_v2 employee_role
      where employee_role.matrix_version_id=p_matrix_version_id and employee_role.employee_id=v_employee_id
        and employee_role.active and employee_role.role_id in(select value::uuid from jsonb_array_elements_text(v_role_ids))
      union
      select jsonb_build_object(
        'roleId',fallback_role.id,'assignmentMode','BACKUP','backupPriority',100,'sourceDutyId',employee_duty.duty_id
      )
      from public.matrix_employee_duties_v2 employee_duty
      join public.matrix_duties_v2 duty on duty.id=employee_duty.duty_id and duty.matrix_version_id=p_matrix_version_id and duty.active
      join public.matrix_roles_v2 fallback_role on fallback_role.matrix_version_id=p_matrix_version_id
        and fallback_role.category_id=v_category and fallback_role.active and upper(fallback_role.code)=upper(duty.code)
      where employee_duty.matrix_version_id=p_matrix_version_id and employee_duty.employee_id=v_employee_id and employee_duty.active
        and exists(select 1 from public.matrix_employee_roles_v2 base_role
          join public.matrix_roles_v2 configured_role on configured_role.id=base_role.role_id and configured_role.category_id=v_category
          where base_role.matrix_version_id=p_matrix_version_id and base_role.employee_id=v_employee_id and base_role.active)
    ) grants;
    if jsonb_array_length(v_grants)>0 then
      v_employee:=jsonb_set(v_employee,'{roleGrants}',v_grants,true);
      v_employee:=jsonb_set(v_employee,'{roleIds}',coalesce((select jsonb_agg(distinct value->>'roleId') from jsonb_array_elements(v_grants)),'[]'::jsonb),true);
      v_employees:=v_employees||jsonb_build_array(v_employee);
    end if;
  end loop;
  v_snapshot:=jsonb_set(v_snapshot,'{employees}',v_employees,true);
  -- A category is generated as one atomic unit, while already selected plans
  -- from other categories remain hard time blocks for the same employees.
  with ranked as (
    select variant.id,
      row_number() over(partition by anchor.category_id order by
        coalesce(variant.selected_at,variant.created_at) desc,variant.id desc) selection_rank
    from public.plan_variants_v2 variant
    join public.optimization_runs_v2 run on run.id=variant.run_id
    join public.matrix_roles_v2 anchor on anchor.id=run.scope_role_id
    where run.month=date_trunc('month',p_month)::date
      and run.matrix_version_id=p_matrix_version_id and run.scenario_id=p_scenario_id
      and run.request_engine='ORTOOLS_V2' and run.scope_type='ROLE'
      and anchor.category_id is distinct from v_category and variant.selected
  ), blocks as (
    select assignment.employee_id,shift.starts_at,shift.ends_at
    from ranked
    join public.plan_assignments_v2 assignment on assignment.variant_id=ranked.id
    join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
    where ranked.selection_rank=1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'employeeId',blocks.employee_id,'start',blocks.starts_at,'end',blocks.ends_at
  ) order by blocks.employee_id,blocks.starts_at),'[]'::jsonb) into v_external
  from blocks where exists(select 1 from jsonb_array_elements(v_employees) employee
    where employee.value->>'id'=blocks.employee_id::text);
  v_snapshot:=jsonb_set(v_snapshot,'{externalAssignments}',
    coalesce(v_snapshot->'externalAssignments','[]'::jsonb)||coalesce(v_external,'[]'::jsonb),true);
  v_snapshot:=jsonb_set(v_snapshot,'{scope}',jsonb_build_object(
    'type','CATEGORY','roleId',p_scope_role_id,'categoryId',v_category,
    'roleIds',v_role_ids,'categoryName',(select name from public.matrix_role_categories_v2 where id=v_category)
  ),true);
  return v_snapshot;
end;
$$;

-- Category-aware wrappers keep the proven publication contract and replace
-- one-role rows with the category anchors used by the generator.
alter function public.optimizer_role_composite_candidates_v2(date,uuid)
  rename to optimizer_role_composite_candidates_before_categories_uat_v1;
create function public.optimizer_role_composite_candidates_v2(p_month date,p_scenario_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_raw jsonb; v_matrix uuid; v_roles jsonb; v_missing jsonb;
begin
  v_raw:=public.optimizer_role_composite_candidates_before_categories_uat_v1(p_month,p_scenario_id);
  select id into v_matrix from public.matrix_versions where status in('ACTIVE','ARCHIVED') and schema_version>=2
    and effective_from<=date_trunc('month',p_month)::date order by effective_from desc,version desc limit 1;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',anchor.id,'name',category.name,'sortOrder',category.sort_order,
    'variant',coalesce((select item.value->'variant' from jsonb_array_elements(coalesce(v_raw->'roles','[]'::jsonb)) item where item.value->>'id'=anchor.id::text limit 1),'null'::jsonb)
  ) order by category.sort_order,category.code),'[]'::jsonb),
  coalesce(jsonb_agg(anchor.id) filter(where not exists(
    select 1 from jsonb_array_elements(coalesce(v_raw->'roles','[]'::jsonb)) item
    where item.value->>'id'=anchor.id::text and jsonb_typeof(item.value->'variant')='object'
  )),'[]'::jsonb)
  into v_roles,v_missing
  from public.matrix_role_categories_v2 category
  cross join lateral(select role_row.id from public.matrix_roles_v2 role_row
    where role_row.matrix_version_id=v_matrix and role_row.category_id=category.id and role_row.active
    order by case when exists(select 1 from public.matrix_staffing_rules_v2 staffing
      where staffing.matrix_version_id=v_matrix and staffing.role_id=role_row.id and staffing.active) then 0 else 1 end,
      role_row.sort_order,role_row.code limit 1) anchor
  where category.matrix_version_id=v_matrix and category.active
    and exists(select 1 from jsonb_array_elements(coalesce(v_raw->'roles','[]'::jsonb)) raw_role
      join public.matrix_roles_v2 demanded on demanded.id=(raw_role.value->>'id')::uuid
      where demanded.category_id=category.id);
  return jsonb_set(jsonb_set(jsonb_set(v_raw,'{roles}',v_roles,true),'{missingRoleIds}',v_missing,true),'{ready}',to_jsonb(jsonb_array_length(v_missing)=0 and jsonb_array_length(v_roles)>0),true);
end; $$;

alter function public.optimizer_role_publication_overview_uat_v2(date)
  rename to optimizer_role_publication_overview_before_categories_uat_v1;
create function public.optimizer_role_publication_overview_uat_v2(p_month date)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_raw jsonb; v_roles jsonb;
begin
  v_raw:=public.optimizer_role_publication_overview_before_categories_uat_v1(p_month);
  select coalesce(jsonb_agg(item.value||jsonb_build_object('role',jsonb_build_object(
    'id',role_row.id,'name',coalesce(category.name,role_row.name)
  )) order by item.ordinality),'[]'::jsonb) into v_roles
  from jsonb_array_elements(coalesce(v_raw->'roles','[]'::jsonb)) with ordinality item(value,ordinality)
  left join public.matrix_roles_v2 role_row on role_row.id=(item.value->'role'->>'id')::uuid
  left join public.matrix_role_categories_v2 category on category.id=role_row.category_id;
  return jsonb_set(v_raw,'{roles}',v_roles,true);
end; $$;

revoke all on table public.matrix_role_categories_v2 from anon;
grant select on table public.matrix_role_categories_v2 to authenticated;
revoke all on function public.matrix_v2_employee_save_uat_v4(uuid,jsonb),
  public.optimizer_role_categories_uat_v1(date),
  public.matrix_v2_admin_save_alpha16(text,uuid,jsonb) from public,anon;
grant execute on function public.matrix_v2_employee_save_uat_v4(uuid,jsonb),
  public.optimizer_role_categories_uat_v1(date),
  public.matrix_v2_admin_save_alpha16(text,uuid,jsonb),
  public.optimizer_role_composite_candidates_v2(date,uuid),
  public.optimizer_role_publication_overview_uat_v2(date) to authenticated;
revoke all on function solver_private.matrix_v2_full_import_phase_before_categories_uat_v1(jsonb,text),
  solver_private.build_snapshot_payload_before_categories_uat_v1(uuid,date,uuid,uuid,text,uuid)
  from public,anon,authenticated;
grant execute on function solver_private.matrix_v2_full_import_phase_uat_v1(jsonb,text),
  solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid) to service_role;

notify pgrst,'reload schema';
