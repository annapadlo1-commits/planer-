-- GRAFIK PRO 3.0 Alpha 6
-- Dynamiczny, wersjonowany Matrix oraz zespolowe planowanie per rola.

create table if not exists public.matrix_versions (
  id uuid primary key default gen_random_uuid(),
  version integer not null unique,
  name text not null,
  status text not null default 'DRAFT' check (status in ('DRAFT','ACTIVE','ARCHIVED')),
  effective_from date not null,
  effective_to date,
  settings jsonb not null default '{"minimumRestMinutes":660,"maxShiftsPerDay":7}'::jsonb,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  activated_at timestamptz,
  check (effective_to is null or effective_to >= effective_from)
);

create table if not exists public.matrix_roles (
  id uuid primary key default gen_random_uuid(),
  matrix_version_id uuid not null references public.matrix_versions(id) on delete cascade,
  code text not null,
  name text not null,
  color text not null default '#7257d8',
  sort_order integer not null default 0,
  active boolean not null default true,
  unique(matrix_version_id, code)
);

create table if not exists public.matrix_locations (
  id uuid primary key default gen_random_uuid(),
  matrix_version_id uuid not null references public.matrix_versions(id) on delete cascade,
  code text not null,
  name text not null,
  active boolean not null default true,
  unique(matrix_version_id, code)
);

create table if not exists public.matrix_shift_templates (
  id uuid primary key default gen_random_uuid(),
  matrix_version_id uuid not null references public.matrix_versions(id) on delete cascade,
  location_id uuid not null references public.matrix_locations(id) on delete cascade,
  code text not null,
  name text not null,
  starts_at time not null,
  ends_at time not null,
  day_mask smallint[] not null default array[1,2,3,4,5,6,7]::smallint[],
  sort_order integer not null default 0,
  active boolean not null default true,
  unique(matrix_version_id, location_id, code)
);

create table if not exists public.matrix_functions (
  id uuid primary key default gen_random_uuid(),
  matrix_version_id uuid not null references public.matrix_versions(id) on delete cascade,
  code text not null,
  name text not null,
  description text,
  active boolean not null default true,
  unique(matrix_version_id, code)
);

create table if not exists public.matrix_role_functions (
  role_id uuid not null references public.matrix_roles(id) on delete cascade,
  function_id uuid not null references public.matrix_functions(id) on delete cascade,
  assignment_mode text not null default 'OPTIONAL' check (assignment_mode in ('REQUIRED','OPTIONAL','EXTRA')),
  primary key(role_id,function_id)
);

create table if not exists public.matrix_demand (
  id uuid primary key default gen_random_uuid(),
  shift_template_id uuid not null references public.matrix_shift_templates(id) on delete cascade,
  role_id uuid not null references public.matrix_roles(id) on delete cascade,
  function_id uuid references public.matrix_functions(id) on delete set null,
  scenario_code text not null default 'BASE',
  required_count integer not null default 1 check(required_count >= 0),
  unique nulls not distinct(shift_template_id,role_id,function_id,scenario_code)
);

create table if not exists public.matrix_employee_roles (
  matrix_version_id uuid not null references public.matrix_versions(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  role_id uuid not null references public.matrix_roles(id) on delete cascade,
  is_primary boolean not null default false,
  can_lead boolean not null default false,
  primary key(matrix_version_id,employee_id,role_id)
);

create unique index if not exists matrix_employee_one_primary
  on public.matrix_employee_roles(matrix_version_id,employee_id) where is_primary;

create table if not exists public.role_plan_sections (
  id uuid primary key default gen_random_uuid(),
  month date not null check(date_trunc('month',month)::date=month),
  matrix_version_id uuid not null references public.matrix_versions(id),
  role_id uuid not null references public.matrix_roles(id),
  version integer not null default 1,
  status text not null default 'DRAFT' check(status in ('DRAFT','GENERATING','READY','SUBMITTED','CHANGES_REQUESTED','APPROVED','LOCKED','ARCHIVED')),
  name text not null,
  scenario_code text not null default 'BASE',
  optimization_mode text not null default 'BALANCED',
  staffing_level text not null default 'OPTIMAL',
  legacy_plan_id uuid references public.plans(id) on delete set null,
  created_by uuid references auth.users(id),
  submitted_at timestamptz,
  approved_at timestamptz,
  approved_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(month,role_id,version)
);

create table if not exists public.composite_schedules (
  id uuid primary key default gen_random_uuid(),
  month date not null,
  matrix_version_id uuid not null references public.matrix_versions(id),
  version integer not null default 1,
  name text not null,
  status text not null default 'DRAFT' check(status in ('DRAFT','VALIDATING','READY','PUBLISHED','STALE','ARCHIVED')),
  section_ids uuid[] not null default '{}',
  created_by uuid references auth.users(id),
  published_at timestamptz,
  created_at timestamptz not null default now(),
  unique(month,version)
);

create table if not exists public.matrix_conflicts (
  id uuid primary key default gen_random_uuid(),
  composite_schedule_id uuid references public.composite_schedules(id) on delete cascade,
  role_plan_section_id uuid references public.role_plan_sections(id) on delete cascade,
  employee_id uuid references public.employees(id) on delete cascade,
  conflict_type text not null,
  severity text not null check(severity in ('INFO','WARNING','CRITICAL')),
  work_date date,
  message text not null,
  status text not null default 'OPEN' check(status in ('OPEN','ACKNOWLEDGED','RESOLVED','WAIVED')),
  resolution_note text,
  resolved_by uuid references auth.users(id),
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.employee_preferences (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete cascade,
  valid_from date not null,
  valid_to date not null,
  preference_type text not null check(preference_type in ('AVAILABLE','UNAVAILABLE','PREFERRED_SHIFT','PREFERRED_LOCATION','LEAVE','SICKNESS','OTHER')),
  preference_value jsonb not null default '{}'::jsonb,
  source text not null default 'GRAFIK_PRO' check(source in ('GRAFIK_PRO','KADROMIERZ','MANAGER','SYSTEM')),
  editable_by_employee boolean not null default true,
  status text not null default 'ACTIVE' check(status in ('DRAFT','ACTIVE','REJECTED','CANCELLED')),
  created_at timestamptz not null default now(),
  check(valid_to>=valid_from)
);

create table if not exists public.integration_runs (
  id uuid primary key default gen_random_uuid(),
  integration text not null,
  direction text not null check(direction in ('IMPORT','EXPORT')),
  entity_type text not null,
  status text not null check(status in ('QUEUED','RUNNING','SUCCESS','PARTIAL','FAILED')),
  file_name text,
  summary jsonb not null default '{}'::jsonb,
  executed_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.time_records (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete cascade,
  work_date date not null,
  planned_start timestamptz,
  planned_end timestamptz,
  actual_start timestamptz,
  actual_end timestamptz,
  break_minutes integer not null default 0,
  source text not null default 'GRAFIK_PRO',
  status text not null default 'OPEN' check(status in ('OPEN','RECORDED','CORRECTED','APPROVED','LOCKED')),
  approved_by uuid references auth.users(id),
  unique(employee_id,work_date,planned_start)
);

insert into public.matrix_versions(version,name,status,effective_from,settings)
select 1,'Matrix startowy Alpha 6','ACTIVE','2026-07-01','{"minimumRestMinutes":660,"maxShiftsPerDay":7}'::jsonb
where not exists(select 1 from public.matrix_versions);

insert into public.matrix_roles(matrix_version_id,code,name,sort_order)
select mv.id,x.code,x.name,x.ord from public.matrix_versions mv
cross join (values ('KELNER','Kelner',1),('BARMAN','Barman',2),('PIZZABAR','Pizzabar',3),('PREP','Prep',4),('POMOC','Pomoc',5)) x(code,name,ord)
where mv.status='ACTIVE' on conflict do nothing;

insert into public.matrix_locations(matrix_version_id,code,name)
select mv.id,x.code,x.name from public.matrix_versions mv
cross join(values('KRUCZA','Krucza'),('PAWILONY','Pawilony')) x(code,name)
where mv.status='ACTIVE' on conflict do nothing;

insert into public.matrix_functions(matrix_version_id,code,name,description)
select mv.id,x.code,x.name,x.description from public.matrix_versions mv
cross join(values
 ('HOST','Host','Dodatkowa funkcja pracownika, bez zmiany roli podstawowej'),
 ('RUNNER','Runner','Wsparcie sali jako funkcja dodatkowa'),
 ('CLOSE_SHIFT','Zamknięcie zmiany','Uprawnienie do zamknięcia lokalu'),
 ('ROLE_LEAD','Lider zespołu','Tworzy i przekazuje grafik swojej roli')) x(code,name,description)
where mv.status='ACTIVE' on conflict do nothing;

alter table public.matrix_versions enable row level security;
alter table public.matrix_roles enable row level security;
alter table public.matrix_locations enable row level security;
alter table public.matrix_shift_templates enable row level security;
alter table public.matrix_functions enable row level security;
alter table public.matrix_role_functions enable row level security;
alter table public.matrix_demand enable row level security;
alter table public.matrix_employee_roles enable row level security;
alter table public.role_plan_sections enable row level security;
alter table public.composite_schedules enable row level security;
alter table public.matrix_conflicts enable row level security;
alter table public.employee_preferences enable row level security;
alter table public.integration_runs enable row level security;
alter table public.time_records enable row level security;

do $$ declare t text; begin
  foreach t in array array['matrix_versions','matrix_roles','matrix_locations','matrix_shift_templates','matrix_functions','matrix_role_functions','matrix_demand'] loop
    execute format('drop policy if exists matrix_read on public.%I',t);
    execute format('create policy matrix_read on public.%I for select to authenticated using(true)',t);
    execute format('drop policy if exists matrix_owner_write on public.%I',t);
    execute format('create policy matrix_owner_write on public.%I for all to authenticated using(public.has_app_role(''OWNER'') or public.has_app_role(''ADMIN'')) with check(public.has_app_role(''OWNER'') or public.has_app_role(''ADMIN''))',t);
  end loop;
end $$;

create or replace function public.matrix_workspace(p_month date default null)
returns jsonb language sql stable security definer set search_path=public as $$
with mv as (select * from matrix_versions where status='ACTIVE' order by version desc limit 1)
select jsonb_build_object(
 'version',(select to_jsonb(mv) from mv),
 'roles',coalesce((select jsonb_agg(to_jsonb(r) order by r.sort_order,r.name) from matrix_roles r join mv on mv.id=r.matrix_version_id),'[]'::jsonb),
 'locations',coalesce((select jsonb_agg(to_jsonb(l) order by l.name) from matrix_locations l join mv on mv.id=l.matrix_version_id),'[]'::jsonb),
 'functions',coalesce((select jsonb_agg(to_jsonb(f) order by f.name) from matrix_functions f join mv on mv.id=f.matrix_version_id),'[]'::jsonb),
 'shifts',coalesce((select jsonb_agg(to_jsonb(s) order by s.sort_order,s.name) from matrix_shift_templates s join mv on mv.id=s.matrix_version_id),'[]'::jsonb),
 'demand',coalesce((select jsonb_agg(to_jsonb(d)) from matrix_demand d join matrix_shift_templates s on s.id=d.shift_template_id join mv on mv.id=s.matrix_version_id),'[]'::jsonb),
 'sections',coalesce((select jsonb_agg(jsonb_build_object('id',rp.id,'month',rp.month,'role_id',rp.role_id,'role_code',r.code,'role_name',r.name,'version',rp.version,'status',rp.status,'name',rp.name,'updated_at',rp.updated_at) order by r.sort_order) from role_plan_sections rp join matrix_roles r on r.id=rp.role_id join mv on mv.id=rp.matrix_version_id where rp.month=coalesce(date_trunc('month',p_month)::date,date_trunc('month',current_date)::date)),'[]'::jsonb),
 'conflicts',coalesce((select jsonb_agg(to_jsonb(c) order by c.severity,c.created_at desc) from matrix_conflicts c where c.status='OPEN'),'[]'::jsonb)
);
$$;

create or replace function public.create_role_plan_section(p_month date,p_role_id uuid,p_name text,p_scenario text default 'BASE',p_mode text default 'BALANCED',p_staffing text default 'OPTIMAL')
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_version integer; v_mv uuid; begin
 if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
 select matrix_version_id into v_mv from matrix_roles where id=p_role_id and active;
 if v_mv is null then raise exception 'ROLE_NOT_FOUND'; end if;
 if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN') or exists(select 1 from user_permissions up join matrix_roles r on r.code=up.scope_role::text where up.auth_user_id=auth.uid() and up.app_role='ROLE_MANAGER' and r.id=p_role_id)) then raise exception 'ROLE_SCOPE_FORBIDDEN'; end if;
 select coalesce(max(version),0)+1 into v_version from role_plan_sections where month=date_trunc('month',p_month)::date and role_id=p_role_id;
 insert into role_plan_sections(month,matrix_version_id,role_id,version,name,scenario_code,optimization_mode,staffing_level,created_by)
 values(date_trunc('month',p_month)::date,v_mv,p_role_id,v_version,p_name,p_scenario,p_mode,p_staffing,auth.uid()) returning id into v_id;
 return v_id;
end $$;

create or replace function public.transition_role_plan(p_section_id uuid,p_status text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_old text; begin
 if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
 if p_status not in ('DRAFT','READY','SUBMITTED','CHANGES_REQUESTED','APPROVED','LOCKED','ARCHIVED') then raise exception 'INVALID_STATUS'; end if;
 select status into v_old from role_plan_sections where id=p_section_id for update;
 if v_old is null then raise exception 'SECTION_NOT_FOUND'; end if;
 update role_plan_sections set status=p_status,updated_at=now(),submitted_at=case when p_status='SUBMITTED' then now() else submitted_at end,approved_at=case when p_status='APPROVED' then now() else approved_at end,approved_by=case when p_status='APPROVED' then auth.uid() else approved_by end where id=p_section_id;
 return jsonb_build_object('id',p_section_id,'from',v_old,'to',p_status);
end $$;

grant execute on function public.matrix_workspace(date) to authenticated;
grant execute on function public.create_role_plan_section(date,uuid,text,text,text,text) to authenticated;
grant execute on function public.transition_role_plan(uuid,text) to authenticated;
