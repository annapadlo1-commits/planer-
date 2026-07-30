-- GRAFIK PRO 3.0 Alpha 4
-- Logowanie, bezpieczne uprawnienia oraz polityki odczytu dla aplikacji.

-- W pierwszej migracji zakresy uprawnienia były częścią PK, co wymuszało NOT NULL.
-- Zastępujemy je technicznym ID i unikatowością uwzględniającą wartości NULL.
alter table public.user_permissions
  drop constraint if exists user_permissions_pkey;

alter table public.user_permissions
  add column if not exists id uuid default gen_random_uuid();

update public.user_permissions set id = gen_random_uuid() where id is null;

alter table public.user_permissions
  alter column id set not null,
  alter column scope_role drop not null,
  alter column scope_location drop not null;

alter table public.user_permissions
  add constraint user_permissions_pkey primary key (id);

create unique index if not exists user_permissions_scope_unique
on public.user_permissions (
auth_user_id,
app_role,
scope_role,
scope_location
) nulls not distinct;


alter table public.locations enable row level security;
alter table public.roles enable row level security;
alter table public.employee_locations enable row level security;
alter table public.employee_capabilities enable row level security;
alter table public.user_permissions enable row level security;
alter table public.shift_definitions enable row level security;
alter table public.demand_rules enable row level security;
alter table public.event_demand_changes enable row level security;

create policy authenticated_reads_locations on public.locations
for select to authenticated using (true);

create policy authenticated_reads_roles on public.roles
for select to authenticated using (true);

create policy authenticated_reads_shift_definitions on public.shift_definitions
for select to authenticated using (true);

create policy authenticated_reads_demand_rules on public.demand_rules
for select to authenticated using (true);

create policy authenticated_reads_employee_locations on public.employee_locations
for select to authenticated using (
  public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  or public.has_app_role('ROLE_MANAGER') or public.has_app_role('LOCATION_MANAGER')
  or exists (
    select 1 from public.employees e
    where e.id = employee_locations.employee_id and e.auth_user_id = auth.uid()
  )
);

create policy authenticated_reads_employee_capabilities on public.employee_capabilities
for select to authenticated using (
  public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  or public.has_app_role('ROLE_MANAGER') or public.has_app_role('LOCATION_MANAGER')
  or exists (
    select 1 from public.employees e
    where e.id = employee_capabilities.employee_id and e.auth_user_id = auth.uid()
  )
);

create policy users_read_own_permissions on public.user_permissions
for select to authenticated using (
  auth_user_id = auth.uid()
  or public.has_app_role('OWNER')
  or public.has_app_role('ADMIN')
);

create policy authenticated_reads_events on public.operational_events
for select to authenticated using (true);

create policy managers_manage_events on public.operational_events
for all to authenticated using (
  public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  or public.has_app_role('LOCATION_MANAGER')
) with check (
  public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  or public.has_app_role('LOCATION_MANAGER')
);

create policy authenticated_reads_event_demand on public.event_demand_changes
for select to authenticated using (true);

create policy authenticated_reads_plans on public.plans
for select to authenticated using (
  status = 'PUBLISHED'
  or public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  or public.has_app_role('ROLE_MANAGER') or public.has_app_role('LOCATION_MANAGER')
);

-- Funkcja przeznaczona wyłącznie dla środowiska demonstracyjnego:
-- pierwszy zarejestrowany użytkownik staje się właścicielem demo.
create or replace function public.claim_demo_owner()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := auth.uid();
  employee_id uuid;
begin
  if current_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if exists (
    select 1 from public.user_permissions
    where auth_user_id = current_user_id
  ) then
    return jsonb_build_object('claimed', false, 'reason', 'ALREADY_ASSIGNED');
  end if;

  if exists (
    select 1 from public.user_permissions where app_role = 'OWNER'
  ) then
    return jsonb_build_object('claimed', false, 'reason', 'OWNER_EXISTS');
  end if;

  insert into public.user_permissions (auth_user_id, app_role)
  values (current_user_id, 'OWNER');

  select id into employee_id
  from public.employees
  where employee_no = 'GP-001' and auth_user_id is null;

  if employee_id is not null then
    update public.employees
    set auth_user_id = current_user_id, updated_at = now()
    where id = employee_id;
  end if;

  return jsonb_build_object('claimed', true, 'role', 'OWNER', 'employee_no', 'GP-001');
end;
$$;

revoke all on function public.claim_demo_owner() from public;
grant execute on function public.claim_demo_owner() to authenticated;

create or replace function public.current_user_access()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'auth_user_id', auth.uid(),
    'roles', coalesce((
      select jsonb_agg(jsonb_build_object(
        'app_role', up.app_role,
        'scope_role', up.scope_role,
        'scope_location', up.scope_location
      ))
      from public.user_permissions up
      where up.auth_user_id = auth.uid()
    ), '[]'::jsonb),
    'employee', (
      select jsonb_build_object(
        'id', e.id,
        'employee_no', e.employee_no,
        'first_name', e.first_name,
        'last_name', e.last_name,
        'primary_role', e.primary_role
      )
      from public.employees e
      where e.auth_user_id = auth.uid()
      limit 1
    )
  );
$$;

grant execute on function public.current_user_access() to authenticated;
