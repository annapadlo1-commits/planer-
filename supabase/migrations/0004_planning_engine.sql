-- GRAFIK PRO 3.0 Alpha 5
-- Transakcyjny silnik planowania, wyjątki operacyjne, budżet i odczyty aplikacji.

alter table public.employees
  add column if not exists hourly_rate numeric(10,2) not null default 30,
  add column if not exists preferred_shift text,
  add column if not exists max_monthly_minutes integer;

update public.employees
set hourly_rate = case primary_role
  when 'KELNER' then 31
  when 'BARMAN' then 34
  when 'PIZZABAR' then 33
  when 'PREP' then 32
  when 'POMOC' then 29
end
where hourly_rate = 30;

update public.employees
set max_monthly_minutes = greatest(monthly_nominal_minutes, round(monthly_nominal_minutes * 1.25))
where max_monthly_minutes is null;

create table if not exists public.monthly_budgets (
  month date primary key check (date_trunc('month', month)::date = month),
  amount numeric(14,2) not null check (amount >= 0),
  warning_percent integer not null default 90 check (warning_percent between 1 and 100),
  hard_limit boolean not null default false,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);

create table if not exists public.employee_availability (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete cascade,
  work_date date not null,
  available boolean not null default true,
  earliest_start time,
  latest_end time,
  preferred_shift_code text,
  note text,
  unique (employee_id, work_date)
);

create table if not exists public.plan_issues (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references public.plans(id) on delete cascade,
  shift_id uuid references public.shifts(id) on delete cascade,
  issue_type text not null check (issue_type in (
    'SHORTAGE', 'CAPABILITY_MISSING', 'BUDGET_EXCEEDED',
    'NO_MANAGER', 'OVERTIME_RISK', 'DATA_WARNING'
  )),
  severity text not null check (severity in ('INFO','WARNING','CRITICAL')),
  role public.employee_role,
  capability text,
  required_count integer,
  assigned_count integer,
  message text not null,
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists availability_employee_date_idx
  on public.employee_availability(employee_id, work_date);
create index if not exists plan_issues_plan_idx
  on public.plan_issues(plan_id, severity, resolved_at);
create unique index if not exists shifts_plan_location_date_code_unique
  on public.shifts(plan_id, location_id, shift_date, shift_code);

insert into public.monthly_budgets(month, amount)
values ('2026-07-01', 275000)
on conflict (month) do nothing;

alter table public.monthly_budgets enable row level security;
alter table public.employee_availability enable row level security;
alter table public.plan_issues enable row level security;

drop policy if exists authenticated_reads_budgets on public.monthly_budgets;
create policy authenticated_reads_budgets on public.monthly_budgets
for select to authenticated using (true);

drop policy if exists managers_manage_budgets on public.monthly_budgets;
create policy managers_manage_budgets on public.monthly_budgets
for all to authenticated
using (public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE'))
with check (public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE'));

drop policy if exists availability_read on public.employee_availability;
create policy availability_read on public.employee_availability
for select to authenticated using (
  public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  or public.has_app_role('ROLE_MANAGER') or public.has_app_role('LOCATION_MANAGER')
  or exists (
    select 1 from public.employees e
    where e.id = employee_availability.employee_id and e.auth_user_id = auth.uid()
  )
);

drop policy if exists availability_manage on public.employee_availability;
create policy availability_manage on public.employee_availability
for all to authenticated using (
  public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  or public.has_app_role('ROLE_MANAGER') or public.has_app_role('LOCATION_MANAGER')
  or exists (
    select 1 from public.employees e
    where e.id = employee_availability.employee_id and e.auth_user_id = auth.uid()
  )
) with check (
  public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  or public.has_app_role('ROLE_MANAGER') or public.has_app_role('LOCATION_MANAGER')
  or exists (
    select 1 from public.employees e
    where e.id = employee_availability.employee_id and e.auth_user_id = auth.uid()
  )
);

drop policy if exists plan_issues_read on public.plan_issues;
create policy plan_issues_read on public.plan_issues
for select to authenticated using (
  public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  or public.has_app_role('ROLE_MANAGER') or public.has_app_role('LOCATION_MANAGER')
);

create or replace function public.can_manage_plans()
returns boolean language sql stable security definer set search_path = public
as $$
  select public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('ROLE_MANAGER') or public.has_app_role('LOCATION_MANAGER');
$$;

create or replace function public.can_view_assignment(
  p_employee_id uuid, p_role public.employee_role, p_location public.location_code
)
returns boolean language sql stable security definer set search_path = public
as $$
  select public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or exists (select 1 from public.employees e where e.id=p_employee_id and e.auth_user_id=auth.uid())
    or exists (select 1 from public.user_permissions up where up.auth_user_id=auth.uid()
      and up.app_role='ROLE_MANAGER' and (up.scope_role is null or up.scope_role=p_role))
    or exists (select 1 from public.user_permissions up where up.auth_user_id=auth.uid()
      and up.app_role='LOCATION_MANAGER' and (up.scope_location is null or up.scope_location=p_location));
$$;

create or replace function public.shift_minutes(p_start timestamptz, p_end timestamptz)
returns integer language sql immutable
as $$ select greatest(0, round(extract(epoch from (p_end - p_start)) / 60)::integer); $$;

create or replace function public.create_operational_event(
  p_location public.location_code,
  p_event_type text,
  p_title text,
  p_description text,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_expected_guests integer default null,
  p_status public.event_status default 'DRAFT',
  p_demand jsonb default '[]'::jsonb
)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_event_id uuid;
  v_location_id uuid;
  v_item jsonb;
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  if p_ends_at <= p_starts_at then raise exception 'INVALID_EVENT_TIME'; end if;

  select id into v_location_id from public.locations where code = p_location and active;
  if v_location_id is null then raise exception 'LOCATION_NOT_FOUND'; end if;

  insert into public.operational_events(
    location_id, event_type, title, description, starts_at, ends_at,
    expected_guests, status, created_by
  ) values (
    v_location_id, p_event_type, p_title, nullif(p_description,''), p_starts_at, p_ends_at,
    p_expected_guests, p_status, auth.uid()
  ) returning id into v_event_id;

  for v_item in select * from jsonb_array_elements(coalesce(p_demand, '[]'::jsonb))
  loop
    insert into public.event_demand_changes(
      event_id, role, shift_code, additional_count, required_capability
    ) values (
      v_event_id,
      (v_item->>'role')::public.employee_role,
      nullif(v_item->>'shift_code',''),
      greatest(0, coalesce((v_item->>'additional_count')::integer, 0)),
      nullif(v_item->>'required_capability','')
    );
  end loop;

  update public.plans
  set status = 'STALE'
  where month = date_trunc('month', p_starts_at at time zone 'Europe/Warsaw')::date
    and status in ('READY','PUBLISHED');

  insert into public.audit_log(actor_id, entity_type, entity_id, action, new_data)
  values (auth.uid(), 'operational_event', v_event_id::text, 'CREATE',
    jsonb_build_object('title',p_title,'type',p_event_type,'status',p_status));
  return v_event_id;
end;
$$;

create or replace function public.generate_plan(
  p_month date,
  p_name text,
  p_scenario_code text default 'BASE',
  p_optimization_mode text default 'BALANCED',
  p_staffing_level text default 'OPTIMAL'
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_plan_id uuid;
  v_day date;
  v_last_day date;
  v_shift record;
  v_rule record;
  v_candidate record;
  v_shift_id uuid;
  v_shift_start timestamptz;
  v_shift_end timestamptz;
  v_location_code public.location_code;
  v_location_id uuid;
  v_shift_code text;
  v_required integer;
  v_assigned integer;
  v_minutes integer;
  v_multiplier numeric := (case upper(p_staffing_level)
    when 'MINIMAL' then 0.85 when 'FULL' then 1.10 else 1 end)
    * (case upper(p_scenario_code)
      when 'EVENT' then 1.05 when 'SAVINGS' then 0.90 else 1 end);
  v_cost numeric := 0;
  v_budget numeric;
  v_issue_count integer;
  v_assignment_count integer;
  v_version integer;
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  p_month := date_trunc('month', p_month)::date;
  v_last_day := (p_month + interval '1 month - 1 day')::date;
  select coalesce(max(version),0)+1 into v_version from public.plans where month=p_month;

  insert into public.plans(
    month,name,scenario_code,optimization_mode,staffing_level,status,version,created_by
  ) values (
    p_month,coalesce(nullif(trim(p_name),''),'Plan '||to_char(p_month,'YYYY-MM')),
    upper(p_scenario_code),upper(p_optimization_mode),upper(p_staffing_level),
    'GENERATING',v_version,auth.uid()
  ) returning id into v_plan_id;

  v_day := p_month;
  while v_day <= v_last_day loop
    for v_shift in
      select sd.*, l.code location_code,
        (v_day + sd.start_time) at time zone l.timezone starts_at_calc,
        ((v_day + case when sd.ends_next_day then 1 else 0 end) + sd.end_time)
          at time zone l.timezone ends_at_calc
      from public.shift_definitions sd
      join public.locations l on l.id=sd.location_id
      where sd.active and l.active and sd.day_of_week=extract(dow from v_day)::integer
        and not exists (
          select 1 from public.operational_events oe
          where oe.location_id=l.id and oe.status='CONFIRMED' and oe.event_type='CLOSURE'
            and (oe.starts_at at time zone l.timezone)::date=v_day
        )
      order by l.code, sd.start_time
    loop
      v_location_code := v_shift.location_code;
      v_location_id := v_shift.location_id;
      v_shift_code := v_shift.code;
      insert into public.shifts(
        plan_id,location_id,shift_date,shift_code,starts_at,ends_at,source_event_id
      ) values (
        v_plan_id,v_shift.location_id,v_day,v_shift.code,
        coalesce((
          select edc.custom_start from public.event_demand_changes edc
          join public.operational_events oe on oe.id=edc.event_id
          where oe.location_id=v_shift.location_id and oe.status='CONFIRMED'
            and (oe.starts_at at time zone 'Europe/Warsaw')::date=v_day
            and (edc.shift_code is null or edc.shift_code=v_shift.code)
            and edc.custom_start is not null limit 1
        ),v_shift.starts_at_calc),
        coalesce((
          select edc.custom_end from public.event_demand_changes edc
          join public.operational_events oe on oe.id=edc.event_id
          where oe.location_id=v_shift.location_id and oe.status='CONFIRMED'
            and (oe.starts_at at time zone 'Europe/Warsaw')::date=v_day
            and (edc.shift_code is null or edc.shift_code=v_shift.code)
            and edc.custom_end is not null limit 1
        ),v_shift.ends_at_calc),
        (select oe.id from public.operational_events oe
          where oe.location_id=v_shift.location_id and oe.status='CONFIRMED'
            and (oe.starts_at at time zone 'Europe/Warsaw')::date=v_day limit 1)
      ) returning id,starts_at,ends_at into v_shift_id,v_shift_start,v_shift_end;

      v_minutes := public.shift_minutes(v_shift_start,v_shift_end);

      -- Najpierw kompetencje twarde; osoba z kompetencją jednocześnie pokrywa podstawową rolę.
      for v_rule in
        select dr.role, dr.required_capability,
          greatest(0,dr.required_count)::integer required_count
        from public.demand_rules dr
        where dr.shift_definition_id in (
          select id from public.shift_definitions
          where location_id=v_location_id and code=v_shift_code
            and day_of_week=extract(dow from v_day)::integer
        ) and dr.scenario_code in ('BASE',upper(p_scenario_code))
          and dr.required_capability is not null
        order by dr.role
      loop
        v_required := v_rule.required_count;
        v_assigned := 0;
        for v_candidate in
          select e.*, el.home_location,
            coalesce((select sum(public.shift_minutes(s.starts_at,s.ends_at))
              from public.assignments a join public.shifts s on s.id=a.shift_id
              where a.employee_id=e.id and s.plan_id=v_plan_id),0) assigned_minutes
          from public.employees e
          join public.employee_locations el on el.employee_id=e.id
            and el.location_id=v_location_id
            and (el.standard_allowed or el.overtime_allowed)
          where e.active and e.primary_role=v_rule.role
            and exists (select 1 from public.employee_capabilities ec
              where ec.employee_id=e.id and ec.active and ec.capability=v_rule.required_capability
                and (ec.scope_role is null or ec.scope_role=v_rule.role)
                and (ec.scope_location is null or ec.scope_location=v_location_code))
            and not exists (select 1 from public.employee_availability av
              where av.employee_id=e.id and av.work_date=v_day and not av.available)
            and not exists (select 1 from public.assignments ax join public.shifts sx on sx.id=ax.shift_id
              where ax.employee_id=e.id and sx.plan_id=v_plan_id
                and tstzrange(sx.starts_at,sx.ends_at,'[)') && tstzrange(v_shift_start,v_shift_end,'[)'))
            and coalesce((select sum(public.shift_minutes(s.starts_at,s.ends_at))
              from public.assignments a join public.shifts s on s.id=a.shift_id
              where a.employee_id=e.id and s.plan_id=v_plan_id),0)+v_minutes
              <= coalesce(e.max_monthly_minutes,round(e.monthly_nominal_minutes*1.25))
            and coalesce((select sum(public.shift_minutes(s.starts_at,s.ends_at))
              from public.assignments a join public.shifts s on s.id=a.shift_id
              where a.employee_id=e.id and s.plan_id=v_plan_id
                and date_trunc('week',s.shift_date::timestamp)=date_trunc('week',v_day::timestamp)),0)+v_minutes
              <= e.max_weekly_minutes
            and not exists (select 1 from public.assignments ar join public.shifts sr on sr.id=ar.shift_id
              where ar.employee_id=e.id and sr.plan_id=v_plan_id
                and tstzrange(sr.starts_at-interval '11 hours',sr.ends_at+interval '11 hours','[)')
                  && tstzrange(v_shift_start,v_shift_end,'[)'))
          order by
            case when upper(p_optimization_mode)='MIN_COST' then e.hourly_rate else 0 end,
            coalesce((select sum(public.shift_minutes(s.starts_at,s.ends_at))
              from public.assignments a join public.shifts s on s.id=a.shift_id
              where a.employee_id=e.id and s.plan_id=v_plan_id),0)::numeric
              / greatest(e.monthly_nominal_minutes,1),
            el.home_location desc, e.employee_no
          limit v_required
        loop
          insert into public.assignments(
            shift_id,employee_id,assigned_role,assigned_capability,cost,explanation
          ) values (
            v_shift_id,v_candidate.id,v_rule.role,v_rule.required_capability,
            round(v_candidate.hourly_rate*v_minutes/60,2),
            jsonb_build_object('engine','ALPHA_5','reason','HARD_CAPABILITY','score_minutes',v_candidate.assigned_minutes)
          );
          v_assigned := v_assigned+1;
        end loop;
        if v_assigned < v_required then
          insert into public.plan_issues(plan_id,shift_id,issue_type,severity,role,capability,required_count,assigned_count,message)
          values(v_plan_id,v_shift_id,'CAPABILITY_MISSING','CRITICAL',v_rule.role,v_rule.required_capability,
            v_required,v_assigned,'Brak wymaganej kompetencji '||v_rule.required_capability);
        end if;
      end loop;

      -- Następnie uzupełnienie liczebności każdej roli.
      for v_rule in
        select dr.role,
          greatest(0,ceil((dr.required_count + coalesce((
            select sum(edc.additional_count)
            from public.event_demand_changes edc
            join public.operational_events oe on oe.id=edc.event_id
            where oe.location_id=v_location_id and oe.status='CONFIRMED'
              and (oe.starts_at at time zone 'Europe/Warsaw')::date=v_day
              and edc.role=dr.role
              and (edc.shift_code is null or edc.shift_code=v_shift_code)
              and edc.required_capability is null
          ),0))*v_multiplier))::integer required_count
        from public.demand_rules dr
        where dr.shift_definition_id in (
          select id from public.shift_definitions
          where location_id=v_location_id and code=v_shift_code
            and day_of_week=extract(dow from v_day)::integer
        ) and dr.scenario_code in ('BASE',upper(p_scenario_code))
          and dr.required_capability is null
        order by dr.role
      loop
        select count(*) into v_assigned from public.assignments
          where shift_id=v_shift_id and assigned_role=v_rule.role;
        v_required := greatest(0,v_rule.required_count-v_assigned);
        for v_candidate in
          select e.*, el.home_location,
            coalesce((select sum(public.shift_minutes(s.starts_at,s.ends_at))
              from public.assignments a join public.shifts s on s.id=a.shift_id
              where a.employee_id=e.id and s.plan_id=v_plan_id),0) assigned_minutes
          from public.employees e
          join public.employee_locations el on el.employee_id=e.id
            and el.location_id=v_location_id
            and (el.standard_allowed or el.overtime_allowed)
          where e.active and e.primary_role=v_rule.role
            and not exists (select 1 from public.employee_availability av
              where av.employee_id=e.id and av.work_date=v_day and not av.available)
            and not exists (select 1 from public.assignments ax join public.shifts sx on sx.id=ax.shift_id
              where ax.employee_id=e.id and sx.plan_id=v_plan_id
                and tstzrange(sx.starts_at,sx.ends_at,'[)') && tstzrange(v_shift_start,v_shift_end,'[)'))
            and coalesce((select sum(public.shift_minutes(s.starts_at,s.ends_at))
              from public.assignments a join public.shifts s on s.id=a.shift_id
              where a.employee_id=e.id and s.plan_id=v_plan_id),0)+v_minutes
              <= coalesce(e.max_monthly_minutes,round(e.monthly_nominal_minutes*1.25))
            and coalesce((select sum(public.shift_minutes(s.starts_at,s.ends_at))
              from public.assignments a join public.shifts s on s.id=a.shift_id
              where a.employee_id=e.id and s.plan_id=v_plan_id
                and date_trunc('week',s.shift_date::timestamp)=date_trunc('week',v_day::timestamp)),0)+v_minutes
              <= e.max_weekly_minutes
            and not exists (select 1 from public.assignments ar join public.shifts sr on sr.id=ar.shift_id
              where ar.employee_id=e.id and sr.plan_id=v_plan_id
                and tstzrange(sr.starts_at-interval '11 hours',sr.ends_at+interval '11 hours','[)')
                  && tstzrange(v_shift_start,v_shift_end,'[)'))
          order by
            case when upper(p_optimization_mode)='MIN_COST' then e.hourly_rate else 0 end,
            case when e.preferred_shift=v_shift_code then 0 else 1 end,
            coalesce((select sum(public.shift_minutes(s.starts_at,s.ends_at))
              from public.assignments a join public.shifts s on s.id=a.shift_id
              where a.employee_id=e.id and s.plan_id=v_plan_id),0)::numeric
              / greatest(e.monthly_nominal_minutes,1),
            el.home_location desc, e.employee_no
          limit v_required
        loop
          insert into public.assignments(shift_id,employee_id,assigned_role,cost,explanation)
          values(v_shift_id,v_candidate.id,v_rule.role,
            round(v_candidate.hourly_rate*v_minutes/60,2),
            jsonb_build_object('engine','ALPHA_5','reason','BALANCED_LOAD','score_minutes',v_candidate.assigned_minutes));
          v_assigned := v_assigned+1;
        end loop;
        if v_assigned < v_rule.required_count then
          insert into public.plan_issues(plan_id,shift_id,issue_type,severity,role,required_count,assigned_count,message)
          values(v_plan_id,v_shift_id,'SHORTAGE',
            case when v_assigned=0 then 'CRITICAL' else 'WARNING' end,
            v_rule.role,v_rule.required_count,v_assigned,
            'Brak '||(v_rule.required_count-v_assigned)||' os. dla roli '||v_rule.role::text);
        end if;
      end loop;
    end loop;
    v_day := v_day+1;
  end loop;

  select coalesce(sum(cost),0),count(*) into v_cost,v_assignment_count
  from public.assignments a join public.shifts s on s.id=a.shift_id where s.plan_id=v_plan_id;
  select amount into v_budget from public.monthly_budgets where month=p_month;
  if v_budget is not null and v_cost>v_budget then
    insert into public.plan_issues(plan_id,issue_type,severity,message)
    values(v_plan_id,'BUDGET_EXCEEDED','CRITICAL',
      'Koszt planu '||round(v_cost,2)||' przekracza budżet '||round(v_budget,2));
  end if;
  select count(*) into v_issue_count from public.plan_issues where plan_id=v_plan_id;

  update public.plans set status='READY',total_cost=v_cost,generated_at=now(),
    score=greatest(0,100-v_issue_count*2)
  where id=v_plan_id;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'plan',v_plan_id::text,'GENERATE',
    jsonb_build_object('assignments',v_assignment_count,'issues',v_issue_count,'cost',v_cost));
  return jsonb_build_object(
    'plan_id',v_plan_id,'status','READY','assignments',v_assignment_count,
    'issues',v_issue_count,'total_cost',v_cost
  );
exception when others then
  if v_plan_id is not null then
    update public.plans set status='FAILED' where id=v_plan_id;
  end if;
  raise;
end;
$$;

create or replace function public.publish_plan(p_plan_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_plan public.plans;
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  select * into v_plan from public.plans where id=p_plan_id;
  if v_plan.id is null then raise exception 'PLAN_NOT_FOUND'; end if;
  if v_plan.status not in ('READY','STALE') then raise exception 'PLAN_NOT_READY'; end if;
  update public.plans set status='ARCHIVED'
    where month=v_plan.month and status='PUBLISHED' and id<>p_plan_id;
  update public.plans set status='PUBLISHED',published_at=now() where id=p_plan_id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'plan',p_plan_id::text,'PUBLISH',jsonb_build_object('month',v_plan.month));
  return jsonb_build_object('plan_id',p_plan_id,'status','PUBLISHED');
end;
$$;

create or replace function public.shift_candidates(p_shift_id uuid, p_role public.employee_role)
returns jsonb
language sql stable security definer set search_path = public
as $$
with target as (
  select s.*,l.code location_code
  from public.shifts s join public.locations l on l.id=s.location_id
  where s.id=p_shift_id
), candidates as (
  select e.id,e.employee_no,e.first_name,e.last_name,e.primary_role,e.hourly_rate,
    el.standard_allowed,el.overtime_allowed,
    exists(select 1 from public.employee_capabilities ec
      where ec.employee_id=e.id and ec.active and ec.capability='CLOSE_SHIFT') can_close,
    not exists(select 1 from public.assignments a join public.shifts s on s.id=a.shift_id
      where a.employee_id=e.id and s.plan_id=(select plan_id from target)
        and tstzrange(s.starts_at,s.ends_at,'[)') &&
          tstzrange((select starts_at from target),(select ends_at from target),'[)')) no_overlap
  from public.employees e
  join public.employee_locations el on el.employee_id=e.id
    and el.location_id=(select location_id from target)
    and (el.standard_allowed or el.overtime_allowed)
  where e.active and e.primary_role=p_role
    and not exists(select 1 from public.assignments a
      where a.shift_id=p_shift_id and a.employee_id=e.id)
)
select coalesce(jsonb_agg(jsonb_build_object(
  'id',id,'employee_no',employee_no,'name',first_name||' '||last_name,
  'role',primary_role,'hourly_rate',hourly_rate,'can_close',can_close,
  'eligible',no_overlap,'overtime_only',(not standard_allowed and overtime_allowed)
) order by no_overlap desc,standard_allowed desc,employee_no),'[]'::jsonb)
from candidates
where public.can_manage_plans();
$$;

create or replace function public.emergency_assign(
  p_shift_id uuid,
  p_employee_id uuid,
  p_role public.employee_role,
  p_notify boolean default false
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_shift public.shifts;
  v_employee public.employees;
  v_minutes integer;
  v_assignment_id uuid;
  v_assigned integer;
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  select * into v_shift from public.shifts where id=p_shift_id;
  if v_shift.id is null then raise exception 'SHIFT_NOT_FOUND'; end if;
  select * into v_employee from public.employees where id=p_employee_id and active;
  if v_employee.id is null then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  if v_employee.primary_role<>p_role then raise exception 'ROLE_MISMATCH'; end if;
  if not exists(select 1 from public.employee_locations el
    where el.employee_id=p_employee_id and el.location_id=v_shift.location_id
      and (el.standard_allowed or el.overtime_allowed)) then
    raise exception 'LOCATION_NOT_ALLOWED';
  end if;
  if exists(select 1 from public.assignments a join public.shifts s on s.id=a.shift_id
    where a.employee_id=p_employee_id and s.plan_id=v_shift.plan_id
      and tstzrange(s.starts_at,s.ends_at,'[)') &&
        tstzrange(v_shift.starts_at,v_shift.ends_at,'[)')) then
    raise exception 'SHIFT_OVERLAP';
  end if;

  v_minutes:=public.shift_minutes(v_shift.starts_at,v_shift.ends_at);
  insert into public.assignments(
    shift_id,employee_id,assigned_role,assignment_type,cost,locked,explanation
  ) values (
    p_shift_id,p_employee_id,p_role,'EMERGENCY',
    round(v_employee.hourly_rate*v_minutes/60,2),true,
    jsonb_build_object('engine','MANUAL','reason','EMERGENCY_ASSIGNMENT','notify',p_notify)
  ) returning id into v_assignment_id;

  select count(*) into v_assigned from public.assignments
  where shift_id=p_shift_id and assigned_role=p_role;
  update public.plan_issues set resolved_at=now()
  where plan_id=v_shift.plan_id and shift_id=p_shift_id and role=p_role
    and issue_type='SHORTAGE' and required_count<=v_assigned and resolved_at is null;

  if p_notify and v_employee.auth_user_id is not null then
    insert into public.notifications(recipient_id,channel,title,body)
    values(v_employee.auth_user_id,'IN_APP','Awaryjna zmiana',
      'Dodano Cię do zmiany '||v_shift.shift_code||' dnia '||v_shift.shift_date);
  end if;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'assignment',v_assignment_id::text,'EMERGENCY_ASSIGN',
    jsonb_build_object('shift_id',p_shift_id,'employee_id',p_employee_id,'notify',p_notify));
  return jsonb_build_object('assignment_id',v_assignment_id,'status','ASSIGNED','notified',
    (p_notify and v_employee.auth_user_id is not null));
end;
$$;

create or replace function public.plan_workspace(p_month date default null, p_plan_id uuid default null)
returns jsonb
language sql stable security definer set search_path = public
as $$
with chosen as (
  select p.* from public.plans p
  where (
    (p_plan_id is not null and p.id=p_plan_id)
    or (p_plan_id is null and p.month=date_trunc('month',coalesce(p_month,current_date))::date)
  ) and (public.can_manage_plans() or p.status='PUBLISHED')
  order by case p.status when 'PUBLISHED' then 0 when 'READY' then 1 else 2 end,p.version desc
  limit 1
), ass as (
  select a.*,s.plan_id,s.shift_date,s.shift_code,s.starts_at,s.ends_at,s.location_id,
    e.employee_no,e.first_name,e.last_name,e.monthly_nominal_minutes,e.primary_role,
    l.code location_code
  from public.assignments a
  join public.shifts s on s.id=a.shift_id
  join public.employees e on e.id=a.employee_id
  join public.locations l on l.id=s.location_id
  where s.plan_id=(select id from chosen)
    and public.can_view_assignment(e.id,a.assigned_role,l.code)
), totals as (
  select employee_id,sum(public.shift_minutes(starts_at,ends_at)) minutes
  from ass group by employee_id
)
select jsonb_build_object(
  'plan',(select to_jsonb(c) from chosen c),
  'budget',coalesce((select jsonb_build_object(
    'amount',b.amount,'warning_percent',b.warning_percent,'hard_limit',b.hard_limit
  ) from public.monthly_budgets b
    where b.month=date_trunc('month',coalesce(p_month,(select month from chosen),current_date))::date),
    jsonb_build_object('amount',0,'warning_percent',90,'hard_limit',false)),
  'shifts',coalesce((select jsonb_agg(to_jsonb(x) order by x.shift_date,x.location_code,x.starts_at)
    from (select s.id,s.shift_date,s.shift_code,s.starts_at,s.ends_at,l.code location_code,
      count(a.id) assignment_count
      from public.shifts s join public.locations l on l.id=s.location_id
      left join public.assignments a on a.shift_id=s.id
      where s.plan_id=(select id from chosen)
        and (public.can_manage_plans() or exists (
          select 1 from public.assignments va
          where va.shift_id=s.id and public.can_view_assignment(va.employee_id,va.assigned_role,l.code)
        ))
      group by s.id,l.code) x),'[]'::jsonb),
  'assignments',coalesce((select jsonb_agg(jsonb_build_object(
    'id',a.id,'shift_id',a.shift_id,'employee_id',a.employee_id,'employee_no',a.employee_no,
    'name',a.first_name||' '||a.last_name,'role',a.assigned_role,'capability',a.assigned_capability,
    'location',a.location_code,'date',a.shift_date,'shift_code',a.shift_code,
    'starts_at',a.starts_at,'ends_at',a.ends_at,'cost',a.cost,'locked',a.locked,
    'monthly_minutes',t.minutes,'nominal_minutes',a.monthly_nominal_minutes
  ) order by a.shift_date,a.location_code,a.starts_at,a.assigned_role,a.last_name)
    from ass a join totals t on t.employee_id=a.employee_id),'[]'::jsonb),
  'issues',coalesce((select jsonb_agg(to_jsonb(i) order by i.severity desc,i.created_at)
    from public.plan_issues i where i.plan_id=(select id from chosen) and i.resolved_at is null
      and public.can_manage_plans()),'[]'::jsonb),
  'events',coalesce((select jsonb_agg(jsonb_build_object(
    'id',oe.id,'title',oe.title,'event_type',oe.event_type,'status',oe.status,
    'starts_at',oe.starts_at,'ends_at',oe.ends_at,'location',l.code,'expected_guests',oe.expected_guests
  ) order by oe.starts_at)
    from public.operational_events oe join public.locations l on l.id=oe.location_id
    where date_trunc('month',oe.starts_at at time zone l.timezone)::date=
      date_trunc('month',coalesce(p_month,(select month from chosen),current_date))::date),'[]'::jsonb)
);
$$;

grant execute on function public.create_operational_event(
  public.location_code,text,text,text,timestamptz,timestamptz,integer,public.event_status,jsonb
) to authenticated;
grant execute on function public.generate_plan(date,text,text,text,text) to authenticated;
grant execute on function public.publish_plan(uuid) to authenticated;
grant execute on function public.shift_candidates(uuid,public.employee_role) to authenticated;
grant execute on function public.emergency_assign(uuid,uuid,public.employee_role,boolean) to authenticated;
grant execute on function public.plan_workspace(date,uuid) to authenticated;
