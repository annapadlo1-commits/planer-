-- GRAFIK PRO 3.0 Alpha 12
-- Czytelny Matrix, scenariusze, miesięczna dostępność, edycja grafików ról
-- i bezpieczne rozdzielenie importu danych od uprawnień aplikacyjnych.
-- Migracja nie usuwa ani nie podmienia 76 pracowników z bazy Alpha 5.

alter table public.employee_availability
  add column if not exists source text not null default 'GRAFIK_PRO',
  add column if not exists updated_by uuid references auth.users(id),
  add column if not exists updated_at timestamptz not null default now();

create table if not exists public.employee_availability_history (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete cascade,
  work_date date not null,
  old_available boolean,
  new_available boolean not null,
  source text not null,
  note text,
  changed_by uuid references auth.users(id),
  changed_at timestamptz not null default now()
);

create table if not exists public.matrix_scenarios (
  id uuid primary key default gen_random_uuid(),
  matrix_version_id uuid not null references public.matrix_versions(id) on delete cascade,
  code text not null,
  name text not null,
  description text,
  color text not null default '#7457e8',
  active boolean not null default true,
  sort_order integer not null default 0,
  unique(matrix_version_id,code)
);

insert into public.matrix_scenarios(matrix_version_id,code,name,description,color,sort_order)
select mv.id,x.code,x.name,x.description,x.color,x.sort_order
from public.matrix_versions mv
cross join (values
 ('BASE','Bazowy','Standardowe zapotrzebowanie','#7457e8',1),
 ('LOW','Niski ruch','Obniżone zapotrzebowanie','#3aa69a',2),
 ('HIGH','Wysoki ruch','Zwiększone zapotrzebowanie','#e9635c',3),
 ('WEEKEND','Weekend','Obsada weekendowa','#f59e45',4),
 ('EVENT','Event','Obsada wydarzenia','#d94f9d',5),
 ('SUMMER','Sezon letni','Sezonowe zapotrzebowanie','#2f86c9',6),
 ('EMERGENCY','Awaryjny','Braki kadrowe i zastępstwa','#cf4a43',7)
) as x(code,name,description,color,sort_order)
where not exists(select 1 from public.matrix_scenarios s where s.matrix_version_id=mv.id and s.code=x.code);

create table if not exists public.matrix_import_runs (
  id uuid primary key default gen_random_uuid(),
  file_name text not null,
  matrix_version_id uuid references public.matrix_versions(id),
  status text not null check(status in ('VALIDATED','IMPORTED','REJECTED')),
  summary jsonb not null default '{}'::jsonb,
  requested_permissions jsonb not null default '[]'::jsonb,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

alter table public.employee_availability_history enable row level security;
alter table public.matrix_scenarios enable row level security;
alter table public.matrix_import_runs enable row level security;

drop policy if exists availability_history_read on public.employee_availability_history;
create policy availability_history_read on public.employee_availability_history for select to authenticated using(
  public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('ROLE_MANAGER')
  or exists(select 1 from public.employees e where e.id=employee_id and e.auth_user_id=auth.uid())
);
drop policy if exists matrix_scenarios_read on public.matrix_scenarios;
create policy matrix_scenarios_read on public.matrix_scenarios for select to authenticated using(true);
drop policy if exists matrix_scenarios_write on public.matrix_scenarios;
create policy matrix_scenarios_write on public.matrix_scenarios for all to authenticated
using(public.has_app_role('OWNER') or public.has_app_role('ADMIN'))
with check(public.has_app_role('OWNER') or public.has_app_role('ADMIN'));
drop policy if exists matrix_import_runs_owner on public.matrix_import_runs;
create policy matrix_import_runs_owner on public.matrix_import_runs for all to authenticated
using(public.has_app_role('OWNER') or public.has_app_role('ADMIN'))
with check(public.has_app_role('OWNER') or public.has_app_role('ADMIN'));

create or replace function public.log_availability_change()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_op='INSERT' or old.available is distinct from new.available or old.note is distinct from new.note then
    insert into employee_availability_history(employee_id,work_date,old_available,new_available,source,note,changed_by)
    values(new.employee_id,new.work_date,case when tg_op='INSERT' then null else old.available end,new.available,new.source,new.note,coalesce(new.updated_by,auth.uid()));
  end if;
  return new;
end $$;

drop trigger if exists employee_availability_history_trigger on public.employee_availability;
create trigger employee_availability_history_trigger after insert or update on public.employee_availability
for each row execute function public.log_availability_change();

create or replace function public.employee_availability_save_month(
  p_month date,p_entries jsonb,p_default_remaining_available boolean default false
) returns jsonb language plpgsql security definer set search_path=public as $$
declare e uuid; d date; item jsonb; saved integer:=0; defaulted integer:=0; begin
  select id into e from employees where auth_user_id=auth.uid() and active limit 1;
  if e is null then raise exception 'EMPLOYEE_ACCOUNT_NOT_LINKED'; end if;
  if date_trunc('month',p_month)::date<>p_month then raise exception 'MONTH_REQUIRED'; end if;
  for item in select value from jsonb_array_elements(coalesce(p_entries,'[]'::jsonb)) loop
    d:=(item->>'date')::date;
    if date_trunc('month',d)::date<>p_month then raise exception 'DATE_OUTSIDE_MONTH'; end if;
    insert into employee_availability(employee_id,work_date,available,note,source,updated_by,updated_at)
    values(e,d,(item->>'status')='AVAILABLE',nullif(item->>'note',''),'GRAFIK_PRO',auth.uid(),now())
    on conflict(employee_id,work_date) do update set available=excluded.available,note=excluded.note,
      source='GRAFIK_PRO',updated_by=auth.uid(),updated_at=now();
    saved:=saved+1;
  end loop;
  if p_default_remaining_available then
    insert into employee_availability(employee_id,work_date,available,source,updated_by,updated_at)
    select e,g::date,true,'GRAFIK_PRO',auth.uid(),now()
    from generate_series(p_month,(p_month+interval '1 month-1 day')::date,interval '1 day') g
    where not exists(select 1 from employee_availability a where a.employee_id=e and a.work_date=g::date)
    on conflict(employee_id,work_date) do nothing;
    get diagnostics defaulted=row_count;
  end if;
  return jsonb_build_object('saved',saved,'defaultedAvailable',defaulted);
end $$;

create or replace function public.role_plan_refresh_conflicts(p_section_id uuid)
returns integer language plpgsql security definer set search_path=public as $$
declare n integer; role_code text; begin
  select mr.code into role_code from role_plan_sections rs join matrix_roles mr on mr.id=rs.role_id where rs.id=p_section_id;
  if role_code is null then raise exception 'SECTION_NOT_FOUND'; end if;
  if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN') or exists(
    select 1 from user_permissions up where up.auth_user_id=auth.uid() and up.app_role='ROLE_MANAGER' and up.scope_role::text=role_code
  )) then raise exception 'ROLE_SCOPE_FORBIDDEN'; end if;
  delete from matrix_conflicts where role_plan_section_id=p_section_id and status='OPEN';
  insert into matrix_conflicts(role_plan_section_id,employee_id,conflict_type,severity,work_date,message)
  select p_section_id,a.employee_id,'UNAVAILABLE','CRITICAL',s.shift_date,
    e.first_name||' '||e.last_name||' jest niedostępny/a tego dnia ('||coalesce(av.source,'GRAFIK_PRO')||').'
  from role_plan_assignments rpa join assignments a on a.id=rpa.assignment_id
  join shifts s on s.id=a.shift_id join employees e on e.id=a.employee_id
  join employee_availability av on av.employee_id=e.id and av.work_date=s.shift_date and not av.available
  where rpa.role_plan_section_id=p_section_id;
  insert into matrix_conflicts(role_plan_section_id,employee_id,conflict_type,severity,work_date,message)
  select distinct p_section_id,a1.employee_id,'OVERLAP','CRITICAL',s1.shift_date,
    e.first_name||' '||e.last_name||' ma nakładające się przydziały.'
  from role_plan_assignments r1 join assignments a1 on a1.id=r1.assignment_id join shifts s1 on s1.id=a1.shift_id
  join role_plan_assignments r2 on r2.role_plan_section_id=p_section_id join assignments a2 on a2.id=r2.assignment_id join shifts s2 on s2.id=a2.shift_id
  join employees e on e.id=a1.employee_id
  where r1.role_plan_section_id=p_section_id and a1.id<a2.id and a1.employee_id=a2.employee_id
    and tstzrange(s1.starts_at,s1.ends_at,'[)') && tstzrange(s2.starts_at,s2.ends_at,'[)');
  select count(*) into n from matrix_conflicts where role_plan_section_id=p_section_id and status='OPEN';
  return n;
end $$;

create or replace function public.role_plan_assignment_save(p_section_id uuid,p_assignment_id uuid,p_data jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare sec role_plan_sections; r matrix_roles; loc locations; emp employees; old_shift shifts; target_shift uuid; ass uuid;
  work_day date; start_time time; end_time time; start_at timestamptz; end_at timestamptz; begin
  select * into sec from role_plan_sections where id=p_section_id;
  if sec.id is null then raise exception 'SECTION_NOT_FOUND'; end if;
  select * into r from matrix_roles where id=sec.role_id;
  if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN') or exists(
    select 1 from user_permissions up where up.auth_user_id=auth.uid() and up.app_role='ROLE_MANAGER' and up.scope_role::text=r.code
  )) then raise exception 'ROLE_SCOPE_FORBIDDEN'; end if;
  if sec.status not in ('DRAFT','READY','SUBMITTED') then raise exception 'SECTION_NOT_EDITABLE'; end if;
  select * into emp from employees where id=(p_data->>'employeeId')::uuid and active;
  if emp.id is null then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  if emp.primary_role::text<>r.code and not exists(select 1 from matrix_employee_roles mer where mer.employee_id=emp.id and mer.role_id=sec.role_id) then raise exception 'EMPLOYEE_ROLE_MISMATCH'; end if;
  select * into loc from locations where code::text=p_data->>'locationCode' and active;
  if loc.id is null then raise exception 'LOCATION_NOT_FOUND'; end if;
  work_day:=(p_data->>'date')::date; start_time:=(p_data->>'startsAt')::time; end_time:=(p_data->>'endsAt')::time;
  start_at:=((work_day+start_time) at time zone loc.timezone);
  end_at:=(((work_day+case when end_time<=start_time then 1 else 0 end)+end_time) at time zone loc.timezone);
  if p_assignment_id is not null then
    select s.* into old_shift from role_plan_assignments rp join assignments a on a.id=rp.assignment_id join shifts s on s.id=a.shift_id
    where rp.role_plan_section_id=p_section_id and a.id=p_assignment_id;
  end if;
  if old_shift.id is not null and old_shift.shift_date=work_day and old_shift.location_id=loc.id and old_shift.starts_at=start_at and old_shift.ends_at=end_at then
    target_shift:=old_shift.id;
  else
    insert into shifts(plan_id,location_id,shift_date,shift_code,starts_at,ends_at,status)
    values(sec.legacy_plan_id,loc.id,work_day,coalesce(nullif(p_data->>'shiftCode',''),'MANUAL'),start_at,end_at,'PLANNED') returning id into target_shift;
  end if;
  if p_assignment_id is null then
    insert into assignments(shift_id,employee_id,assigned_role,assigned_capability,assignment_type,cost,explanation)
    values(target_shift,emp.id,r.code::employee_role,nullif(p_data->>'capability',''),'MANUAL',round(emp.hourly_rate*public.shift_minutes(start_at,end_at)/60,2),jsonb_build_object('source','ROLE_MANAGER')) returning id into ass;
    insert into role_plan_assignments(role_plan_section_id,assignment_id) values(p_section_id,ass);
  else
    update assignments set shift_id=target_shift,employee_id=emp.id,assigned_capability=nullif(p_data->>'capability',''),assignment_type='MANUAL',
      cost=round(emp.hourly_rate*public.shift_minutes(start_at,end_at)/60,2),explanation=explanation||jsonb_build_object('editedBy',auth.uid(),'editedAt',now())
    where id=p_assignment_id returning id into ass;
  end if;
  update role_plan_sections set status='READY',updated_at=now() where id=p_section_id;
  insert into audit_log(actor_id,entity_type,entity_id,action,new_data) values(auth.uid(),'role_plan_assignment',ass::text,case when p_assignment_id is null then 'CREATE' else 'UPDATE' end,p_data);
  perform role_plan_refresh_conflicts(p_section_id);
  return jsonb_build_object('assignmentId',ass,'conflicts',(select count(*) from matrix_conflicts where role_plan_section_id=p_section_id and status='OPEN'));
end $$;

create or replace function public.role_plan_assignment_delete(p_section_id uuid,p_assignment_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare sec role_plan_sections; r matrix_roles; begin
  select * into sec from role_plan_sections where id=p_section_id; select * into r from matrix_roles where id=sec.role_id;
  if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN') or exists(select 1 from user_permissions up where up.auth_user_id=auth.uid() and up.app_role='ROLE_MANAGER' and up.scope_role::text=r.code)) then raise exception 'ROLE_SCOPE_FORBIDDEN'; end if;
  if not exists(select 1 from role_plan_assignments where role_plan_section_id=p_section_id and assignment_id=p_assignment_id) then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
  delete from assignments where id=p_assignment_id;
  update role_plan_sections set status='READY',updated_at=now() where id=p_section_id;
  insert into audit_log(actor_id,entity_type,entity_id,action) values(auth.uid(),'role_plan_assignment',p_assignment_id::text,'DELETE');
  perform role_plan_refresh_conflicts(p_section_id);
end $$;

create or replace function public.role_plan_workspace(p_section_id uuid)
returns jsonb language plpgsql volatile security definer set search_path=public as $$
declare result jsonb; begin
  perform role_plan_refresh_conflicts(p_section_id);
  select jsonb_build_object(
    'assignments',coalesce((select jsonb_agg(jsonb_build_object(
      'id',a.id,'employeeId',e.id,'employeeNo',e.employee_no,'employeeName',e.first_name||' '||e.last_name,
      'date',s.shift_date,'startsAt',s.starts_at,'endsAt',s.ends_at,'shiftCode',s.shift_code,
      'location',l.name,'locationCode',l.code,'capability',a.assigned_capability,'manual',a.assignment_type='MANUAL'
    ) order by s.starts_at,e.last_name) from role_plan_assignments rp join assignments a on a.id=rp.assignment_id
      join shifts s on s.id=a.shift_id join employees e on e.id=a.employee_id join locations l on l.id=s.location_id
      where rp.role_plan_section_id=p_section_id),'[]'::jsonb),
    'issues',coalesce((select jsonb_agg(x order by x->>'date') from (
      select jsonb_build_object('id',mc.id,'type',mc.conflict_type,'severity',mc.severity,'date',mc.work_date,'message',mc.message) x
      from matrix_conflicts mc where mc.role_plan_section_id=p_section_id and mc.status='OPEN'
      union all
      select jsonb_build_object('id',pi.id,'type',pi.issue_type,'severity',pi.severity,'date',s.shift_date,'message',pi.message,'required',pi.required_count,'assigned',pi.assigned_count,
        'unavailable',coalesce((select jsonb_agg(jsonb_build_object('name',ue.first_name||' '||ue.last_name,'source',ua.source) order by ue.last_name)
          from employee_availability ua join employees ue on ue.id=ua.employee_id
          where ua.work_date=s.shift_date and not ua.available and ue.active and ue.primary_role::text=mr.code),'[]'::jsonb))
      from role_plan_sections rs join plan_issues pi on pi.plan_id=rs.legacy_plan_id left join shifts s on s.id=pi.shift_id
      join matrix_roles mr on mr.id=rs.role_id where rs.id=p_section_id and (pi.role is null or pi.role::text=mr.code) and pi.resolved_at is null
    ) q),'[]'::jsonb)
  ) into result;
  return result;
end $$;

create or replace function public.employee_portal_workspace(p_month date default current_date)
returns jsonb language sql stable security definer set search_path=public as $$
with me as(select * from employees where auth_user_id=auth.uid() and active limit 1),
published as(select id from plans where month=date_trunc('month',p_month)::date and status='PUBLISHED' order by version desc limit 1)
select jsonb_build_object(
 'employee',(select jsonb_build_object('id',m.id,'employeeNo',m.employee_no,'firstName',m.first_name,'lastName',m.last_name,'primaryRole',m.primary_role,
   'locations',coalesce((select jsonb_agg(jsonb_build_object('code',l.code,'name',l.name)) from employee_locations el join locations l on l.id=el.location_id where el.employee_id=m.id and (el.standard_allowed or el.overtime_allowed or el.home_location)),'[]'::jsonb)) from me m),
 'preferences',coalesce((select jsonb_agg(to_jsonb(ep) order by ep.valid_from desc) from employee_preferences ep join me on me.id=ep.employee_id),'[]'::jsonb),
 'availability',coalesce((select jsonb_agg(jsonb_build_object('date',av.work_date,'status',case when av.available then 'AVAILABLE' else 'UNAVAILABLE' end,'source',av.source,'note',av.note) order by av.work_date) from employee_availability av join me on me.id=av.employee_id where date_trunc('month',av.work_date)::date=date_trunc('month',p_month)::date),'[]'::jsonb),
 'availabilityHistory',coalesce((select jsonb_agg(jsonb_build_object('date',h.work_date,'from',h.old_available,'to',h.new_available,'source',h.source,'changedAt',h.changed_at) order by h.changed_at desc) from employee_availability_history h join me on me.id=h.employee_id limit 100),'[]'::jsonb),
 'assignments',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'shiftId',s.id,'date',s.shift_date,'startsAt',s.starts_at,'endsAt',s.ends_at,'shiftCode',s.shift_code,'location',l.name,'locationCode',l.code,'role',a.assigned_role,'capability',a.assigned_capability,
   'coworkers',coalesce((select jsonb_agg(jsonb_build_object('name',ce.first_name||' '||ce.last_name,'role',ca.assigned_role,'capability',ca.assigned_capability) order by ce.last_name) from assignments ca join employees ce on ce.id=ca.employee_id where ca.shift_id=s.id and ca.employee_id<>a.employee_id),'[]'::jsonb)) order by s.starts_at)
   from assignments a join shifts s on s.id=a.shift_id join published p on p.id=s.plan_id join locations l on l.id=s.location_id join me on me.id=a.employee_id),'[]'::jsonb),
 'attendance',coalesce((select jsonb_agg(jsonb_build_object('id',ae.id,'action',ae.event_type,'occurredAt',ae.occurred_at,'location',l.name) order by ae.occurred_at desc)
   from attendance_events ae join locations l on l.id=ae.location_id join me on me.id=ae.employee_id where ae.occurred_at>=date_trunc('month',p_month)),'[]'::jsonb)
);
$$;

-- Import danych organizacyjnych może tylko zapisać prośby o dostęp.
-- Nigdy nie modyfikuje public.user_permissions.
create or replace function public.matrix_register_import(p_file_name text,p_summary jsonb,p_requested_permissions jsonb default '[]'::jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare out_id uuid; draft_id uuid; begin
 if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
 draft_id:=matrix_create_draft('Import z pliku '||p_file_name);
 insert into matrix_import_runs(file_name,matrix_version_id,status,summary,requested_permissions,created_by)
 values(p_file_name,draft_id,'VALIDATED',coalesce(p_summary,'{}'::jsonb),coalesce(p_requested_permissions,'[]'::jsonb),auth.uid()) returning id into out_id;
 return out_id;
end $$;

create or replace function public.matrix_import_apply(p_file_name text,p_payload jsonb,p_requested_permissions jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare d uuid; row jsonb; loc uuid; sh uuid; ro uuid; imported_roles int:=0; imported_shifts int:=0; imported_demand int:=0; run_id uuid; begin
 if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
 d:=matrix_create_draft('Import z pliku '||p_file_name);
 for row in select value from jsonb_array_elements(coalesce(p_payload->'locations','[]'::jsonb)) loop
   insert into matrix_locations(matrix_version_id,code,name,active)
   values(d,upper(trim(row->>'KOD')),trim(row->>'NAZWA'),upper(coalesce(row->>'AKTYWNA','TAK'))<>'NIE')
   on conflict(matrix_version_id,code) do update set name=excluded.name,active=excluded.active;
 end loop;
 for row in select value from jsonb_array_elements(coalesce(p_payload->'roles','[]'::jsonb)) loop
   insert into matrix_roles(matrix_version_id,code,name,color,active)
   values(d,upper(trim(row->>'KOD')),trim(row->>'NAZWA'),coalesce(nullif(row->>'KOLOR',''),'#7257d8'),upper(coalesce(row->>'AKTYWNA','TAK'))<>'NIE')
   on conflict(matrix_version_id,code) do update set name=excluded.name,color=excluded.color,active=excluded.active;
   imported_roles:=imported_roles+1;
 end loop;
 for row in select value from jsonb_array_elements(coalesce(p_payload->'functions','[]'::jsonb)) loop
   insert into matrix_functions(matrix_version_id,code,name,description,active)
   values(d,upper(trim(row->>'KOD')),trim(row->>'NAZWA'),nullif(row->>'OPIS',''),upper(coalesce(row->>'AKTYWNA','TAK'))<>'NIE')
   on conflict(matrix_version_id,code) do update set name=excluded.name,description=excluded.description,active=excluded.active;
 end loop;
 for row in select value from jsonb_array_elements(coalesce(p_payload->'scenarios','[]'::jsonb)) loop
   insert into matrix_scenarios(matrix_version_id,code,name,active)
   values(d,upper(trim(row->>'KOD')),trim(row->>'NAZWA'),upper(coalesce(row->>'AKTYWNY','TAK'))<>'NIE')
   on conflict(matrix_version_id,code) do update set name=excluded.name,active=excluded.active;
 end loop;
 for row in select value from jsonb_array_elements(coalesce(p_payload->'shifts','[]'::jsonb)) loop
   select id into loc from matrix_locations where matrix_version_id=d and code=upper(trim(row->>'LOKAL'));
   if loc is null then raise exception 'IMPORT_UNKNOWN_LOCATION: %',row->>'LOKAL'; end if;
   insert into matrix_shift_templates(matrix_version_id,location_id,code,name,starts_at,ends_at,day_mask,active)
   values(d,loc,upper(trim(row->>'KOD')),trim(row->>'NAZWA'),(row->>'OD')::time,(row->>'DO')::time,string_to_array(row->>'DNI',',')::smallint[],upper(coalesce(row->>'AKTYWNA','TAK'))<>'NIE')
   on conflict(matrix_version_id,location_id,code) do update set name=excluded.name,starts_at=excluded.starts_at,ends_at=excluded.ends_at,day_mask=excluded.day_mask,active=excluded.active;
   imported_shifts:=imported_shifts+1;
 end loop;
 for row in select value from jsonb_array_elements(coalesce(p_payload->'demand','[]'::jsonb)) loop
   select ml.id into loc from matrix_locations ml where ml.matrix_version_id=d and ml.code=upper(trim(row->>'LOKAL'));
   select ms.id into sh from matrix_shift_templates ms where ms.matrix_version_id=d and ms.location_id=loc and ms.code=upper(trim(row->>'ZMIANA'));
   select mr.id into ro from matrix_roles mr where mr.matrix_version_id=d and mr.code=upper(trim(row->>'ROLA'));
   if sh is null or ro is null then raise exception 'IMPORT_UNKNOWN_SHIFT_OR_ROLE'; end if;
   insert into matrix_demand(shift_template_id,role_id,scenario_code,required_count)
   values(sh,ro,upper(coalesce(nullif(row->>'SCENARIUSZ',''),'BASE')),greatest((row->>'WYMAGANE')::integer,0))
   on conflict(shift_template_id,role_id,function_id,scenario_code) do update set required_count=excluded.required_count;
   imported_demand:=imported_demand+1;
 end loop;
 insert into matrix_import_runs(file_name,matrix_version_id,status,summary,requested_permissions,created_by)
 values(p_file_name,d,'IMPORTED',jsonb_build_object('roles',imported_roles,'shifts',imported_shifts,'demand',imported_demand),coalesce(p_requested_permissions,'[]'::jsonb),auth.uid()) returning id into run_id;
 insert into audit_log(actor_id,entity_type,entity_id,action,new_data) values(auth.uid(),'matrix_import',run_id::text,'IMPORT',jsonb_build_object('permissionsApplied',false));
 return jsonb_build_object('draftId',d,'roles',imported_roles,'shifts',imported_shifts,'demand',imported_demand,'permissionsApplied',false);
end $$;

create or replace function public.kadromierz_import_preferences(p_file_name text,p_rows jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare row jsonb; e_id uuid; imported integer:=0; skipped integer:=0; run_id uuid; from_day date; to_day date; typ text; begin
 if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
 insert into integration_runs(integration,direction,entity_type,status,file_name,executed_by) values('KADROMIERZ','IMPORT','DOSTEPNOSC_I_PREFERENCJE','RUNNING',p_file_name,auth.uid()) returning id into run_id;
 for row in select value from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) loop
   select id into e_id from employees where employee_no=coalesce(row->>'employee_no',row->>'numer_pracownika');
   from_day:=coalesce(row->>'date',row->>'data')::date; to_day:=coalesce(row->>'date_to',row->>'data_do',row->>'date',row->>'data')::date; typ:=upper(coalesce(nullif(row->>'type',''),'LEAVE'));
   if e_id is null or from_day is null then skipped:=skipped+1; continue; end if;
   insert into employee_preferences(employee_id,valid_from,valid_to,preference_type,preference_value,source,status)
   values(e_id,from_day,to_day,typ,jsonb_build_object('note',coalesce(row->>'note',row->>'uwagi','')),'KADROMIERZ','ACTIVE');
   if typ in ('UNAVAILABLE','LEAVE','SICKNESS') then
     insert into employee_availability(employee_id,work_date,available,note,source,updated_by,updated_at)
     select e_id,g::date,false,coalesce(row->>'note',row->>'uwagi',''),'KADROMIERZ',auth.uid(),now() from generate_series(from_day,to_day,interval '1 day') g
     on conflict(employee_id,work_date) do update set available=false,note=excluded.note,source='KADROMIERZ',updated_by=auth.uid(),updated_at=now();
   end if;
   imported:=imported+1;
 end loop;
 update integration_runs set status=case when skipped=0 then 'SUCCESS' else 'PARTIAL' end,summary=jsonb_build_object('imported',imported,'skipped',skipped,'unavailabilityApplied',true) where id=run_id;
 return jsonb_build_object('imported',imported,'skipped',skipped,'runId',run_id);
end $$;

grant execute on function public.employee_availability_save_month(date,jsonb,boolean) to authenticated;
grant execute on function public.role_plan_refresh_conflicts(uuid) to authenticated;
grant execute on function public.role_plan_assignment_save(uuid,uuid,jsonb) to authenticated;
grant execute on function public.role_plan_assignment_delete(uuid,uuid) to authenticated;
grant execute on function public.role_plan_workspace(uuid) to authenticated;
grant execute on function public.matrix_register_import(text,jsonb,jsonb) to authenticated;
grant execute on function public.matrix_import_apply(text,jsonb,jsonb) to authenticated;
