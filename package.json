create extension if not exists pgcrypto;

create type public.app_role as enum (
  'OWNER', 'ADMIN', 'HR_FINANCE', 'ROLE_MANAGER',
  'LOCATION_MANAGER', 'VERIFIER', 'EMPLOYEE'
);
create type public.employee_role as enum ('KELNER', 'BARMAN', 'PIZZABAR', 'PREP', 'POMOC');
create type public.location_code as enum ('KRUCZA', 'PAWILONY');
create type public.plan_status as enum ('DRAFT', 'GENERATING', 'READY', 'PUBLISHED', 'STALE', 'ARCHIVED', 'FAILED');
create type public.event_status as enum ('DRAFT', 'NEEDS_VERIFICATION', 'CONFIRMED', 'CANCELLED');
create type public.task_status as enum ('NEW', 'IN_PROGRESS', 'APPROVED', 'REJECTED', 'CHANGES_REQUESTED', 'DONE');
create type public.attendance_event_type as enum ('CHECK_IN', 'CHECK_OUT', 'BREAK_START', 'BREAK_END', 'MANAGER_CORRECTION');

create table public.locations (
  id uuid primary key default gen_random_uuid(),
  code location_code not null unique,
  name text not null,
  timezone text not null default 'Europe/Warsaw',
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.roles (
  id uuid primary key default gen_random_uuid(),
  code employee_role not null unique,
  name text not null,
  active boolean not null default true
);

create table public.employees (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid unique references auth.users(id) on delete set null,
  employee_no text not null unique,
  first_name text not null,
  last_name text not null,
  email text unique,
  primary_role employee_role not null,
  monthly_nominal_minutes integer not null check (monthly_nominal_minutes >= 0),
  max_weekly_minutes integer not null default 2400 check (max_weekly_minutes between 0 and 10080),
  active boolean not null default true,
  employment_start date,
  employment_end date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (employment_end is null or employment_start is null or employment_end >= employment_start)
);

create table public.employee_locations (
  employee_id uuid not null references public.employees(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete cascade,
  standard_allowed boolean not null default false,
  overtime_allowed boolean not null default false,
  home_location boolean not null default false,
  primary key (employee_id, location_id),
  check (standard_allowed or overtime_allowed or home_location)
);

create table public.employee_capabilities (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete cascade,
  capability text not null check (capability in (
    'HOST', 'CLOSE_SHIFT', 'ROLE_MANAGER', 'LOCATION_MANAGER',
    'STANDBY', 'ROTATIONAL', 'OPEN_SHIFT'
  )),
  scope_role employee_role,
  scope_location location_code,
  active boolean not null default true,
  unique nulls not distinct (employee_id, capability, scope_role, scope_location)
);

create table public.user_permissions (
  auth_user_id uuid not null references auth.users(id) on delete cascade,
  app_role app_role not null,
  scope_role employee_role,
  scope_location location_code,
  primary key (auth_user_id, app_role, scope_role, scope_location)
);

create table public.shift_definitions (
  id uuid primary key default gen_random_uuid(),
  location_id uuid not null references public.locations(id),
  code text not null,
  name text not null,
  day_of_week smallint not null check (day_of_week between 0 and 6),
  start_time time not null,
  end_time time not null,
  ends_next_day boolean not null default false,
  active boolean not null default true,
  unique (location_id, code, day_of_week)
);

create table public.demand_rules (
  id uuid primary key default gen_random_uuid(),
  location_id uuid not null references public.locations(id),
  shift_definition_id uuid not null references public.shift_definitions(id),
  role employee_role not null,
  required_count integer not null check (required_count >= 0),
  required_capability text,
  scenario_code text not null default 'BASE',
  valid_from date,
  valid_to date,
  unique (shift_definition_id, role, required_capability, scenario_code)
);

create table public.operational_events (
  id uuid primary key default gen_random_uuid(),
  location_id uuid not null references public.locations(id),
  event_type text not null check (event_type in (
    'EVENT', 'CLEANING', 'INVENTORY', 'TRAINING', 'DELIVERY',
    'ADDITIONAL_SHIFT', 'HOURS_CHANGE', 'CLOSURE', 'OTHER'
  )),
  title text not null,
  description text,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  expected_guests integer check (expected_guests is null or expected_guests >= 0),
  status event_status not null default 'DRAFT',
  verifier_user_id uuid references auth.users(id),
  verification_due_at timestamptz,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at > starts_at)
);

create table public.event_demand_changes (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.operational_events(id) on delete cascade,
  role employee_role not null,
  shift_code text,
  additional_count integer not null default 0,
  custom_start timestamptz,
  custom_end timestamptz,
  required_capability text
);

create table public.plans (
  id uuid primary key default gen_random_uuid(),
  month date not null check (date_trunc('month', month)::date = month),
  name text not null,
  scenario_code text not null,
  optimization_mode text not null,
  staffing_level text not null,
  status plan_status not null default 'DRAFT',
  version integer not null default 1,
  parent_plan_id uuid references public.plans(id),
  score numeric(7,2),
  total_cost numeric(14,2),
  generated_at timestamptz,
  published_at timestamptz,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  unique (month, name, version)
);

create table public.shifts (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references public.plans(id) on delete cascade,
  location_id uuid not null references public.locations(id),
  shift_date date not null,
  shift_code text not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  source_event_id uuid references public.operational_events(id),
  status text not null default 'PLANNED',
  check (ends_at > starts_at)
);

create table public.assignments (
  id uuid primary key default gen_random_uuid(),
  shift_id uuid not null references public.shifts(id) on delete cascade,
  employee_id uuid not null references public.employees(id),
  assigned_role employee_role not null,
  assigned_capability text,
  assignment_type text not null default 'STANDARD',
  cost numeric(12,2) not null default 0,
  locked boolean not null default false,
  explanation jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (shift_id, employee_id, assigned_role, assigned_capability)
);

create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  source_event_id uuid references public.operational_events(id) on delete cascade,
  assigned_to uuid not null references auth.users(id),
  title text not null,
  description text,
  priority text not null default 'NORMAL',
  due_at timestamptz,
  status task_status not null default 'NEW',
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references auth.users(id) on delete cascade,
  task_id uuid references public.tasks(id) on delete cascade,
  channel text not null default 'IN_APP',
  title text not null,
  body text not null,
  read_at timestamptz,
  sent_at timestamptz,
  retry_count integer not null default 0,
  created_at timestamptz not null default now()
);

create table public.attendance_events (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id),
  shift_id uuid references public.shifts(id),
  location_id uuid not null references public.locations(id),
  event_type attendance_event_type not null,
  occurred_at timestamptz not null default now(),
  verification_method text not null,
  qr_token_hash text,
  latitude numeric(9,6),
  longitude numeric(9,6),
  evidence_path text,
  device_fingerprint text,
  created_by uuid references auth.users(id),
  metadata jsonb not null default '{}'::jsonb
);

create table public.audit_log (
  id bigint generated always as identity primary key,
  actor_id uuid references auth.users(id),
  entity_type text not null,
  entity_id text not null,
  action text not null,
  old_data jsonb,
  new_data jsonb,
  created_at timestamptz not null default now()
);

create index assignments_employee_idx on public.assignments(employee_id);
create index shifts_plan_date_idx on public.shifts(plan_id, shift_date);
create index events_location_time_idx on public.operational_events(location_id, starts_at);
create index tasks_assignee_status_idx on public.tasks(assigned_to, status);
create index notifications_recipient_idx on public.notifications(recipient_id, read_at);
create index attendance_employee_time_idx on public.attendance_events(employee_id, occurred_at desc);

alter table public.employees enable row level security;
alter table public.plans enable row level security;
alter table public.shifts enable row level security;
alter table public.assignments enable row level security;
alter table public.operational_events enable row level security;
alter table public.tasks enable row level security;
alter table public.notifications enable row level security;
alter table public.attendance_events enable row level security;

create or replace function public.has_app_role(required_role app_role)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.user_permissions
    where auth_user_id = auth.uid() and app_role = required_role
  );
$$;

create policy employee_reads_self on public.employees
for select using (
  auth_user_id = auth.uid()
  or public.has_app_role('OWNER')
  or public.has_app_role('ADMIN')
  or public.has_app_role('HR_FINANCE')
  or public.has_app_role('ROLE_MANAGER')
  or public.has_app_role('LOCATION_MANAGER')
);

create policy employee_reads_own_assignments on public.assignments
for select using (
  exists (
    select 1 from public.employees e
    where e.id = assignments.employee_id and e.auth_user_id = auth.uid()
  )
  or public.has_app_role('OWNER')
  or public.has_app_role('ADMIN')
  or public.has_app_role('ROLE_MANAGER')
  or public.has_app_role('LOCATION_MANAGER')
);

create policy employee_reads_published_shifts on public.shifts
for select using (
  exists (select 1 from public.plans p where p.id = shifts.plan_id and p.status = 'PUBLISHED')
  or public.has_app_role('OWNER')
  or public.has_app_role('ADMIN')
  or public.has_app_role('ROLE_MANAGER')
  or public.has_app_role('LOCATION_MANAGER')
);

create policy user_reads_own_tasks on public.tasks
for select using (
  assigned_to = auth.uid()
  or public.has_app_role('OWNER')
  or public.has_app_role('ADMIN')
);

create policy user_reads_own_notifications on public.notifications
for select using (recipient_id = auth.uid());

create policy employee_reads_own_attendance on public.attendance_events
for select using (
  exists (
    select 1 from public.employees e
    where e.id = attendance_events.employee_id and e.auth_user_id = auth.uid()
  )
  or public.has_app_role('OWNER')
  or public.has_app_role('ADMIN')
  or public.has_app_role('HR_FINANCE')
  or public.has_app_role('LOCATION_MANAGER')
);
