-- GRAFIK PRO 3.0 — pełne moduły produktu na bazie ustalonych danych Alpha 5.
-- Migracja rozszerzająca: nie usuwa i nie podmienia 76 pracowników ani reguł obsady.

alter table public.employees
  add column if not exists archived_at timestamptz,
  add column if not exists archived_by uuid references auth.users(id),
  add column if not exists archive_reason text;

create table if not exists public.employee_hr_profiles (
  employee_id uuid primary key references public.employees(id) on delete cascade,
  contract_type text not null default 'UMOWA_O_PRACE' check(contract_type in ('UMOWA_O_PRACE','ZLECENIE','CZESC_ETATU','B2B','INNE')),
  position_name text,
  employment_fraction numeric(4,2) not null default 1 check(employment_fraction > 0 and employment_fraction <= 1),
  leave_days integer not null default 0 check(leave_days >= 0),
  medical_valid_to date,
  training_valid_to date,
  hr_note text,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);

insert into public.employee_hr_profiles(employee_id,contract_type,employment_fraction)
select id,case when monthly_nominal_minutes=5040 then 'CZESC_ETATU' else 'UMOWA_O_PRACE' end,
  case when monthly_nominal_minutes=5040 then .5 else 1 end
from public.employees on conflict(employee_id) do nothing;

-- Matrix v1 otrzymuje dokładne, istniejące definicje godzin i obsady z Alpha 5.
insert into public.matrix_shift_templates(matrix_version_id,location_id,code,name,starts_at,ends_at,day_mask,sort_order)
select mv.id,ml.id,sd.code||'_'||sd.day_of_week,sd.name,sd.start_time,sd.end_time,
  array[case when sd.day_of_week=0 then 7 else sd.day_of_week end]::smallint[],sd.day_of_week*10+
  case sd.code when 'RANO' then 1 when 'SRODEK' then 2 else 3 end
from public.matrix_versions mv join public.matrix_locations ml on ml.matrix_version_id=mv.id
join public.locations l on l.code::text=ml.code join public.shift_definitions sd on sd.location_id=l.id
where mv.status='ACTIVE' on conflict do nothing;

insert into public.matrix_demand(shift_template_id,role_id,function_id,scenario_code,required_count)
select ms.id,mr.id,mf.id,dr.scenario_code,dr.required_count
from public.matrix_versions mv join public.matrix_shift_templates ms on ms.matrix_version_id=mv.id
join public.matrix_locations ml on ml.id=ms.location_id join public.locations l on l.code::text=ml.code
join public.shift_definitions sd on sd.location_id=l.id and ms.code=sd.code||'_'||sd.day_of_week
join public.demand_rules dr on dr.shift_definition_id=sd.id
join public.matrix_roles mr on mr.matrix_version_id=mv.id and mr.code=dr.role::text
left join public.matrix_functions mf on mf.matrix_version_id=mv.id and mf.code=dr.required_capability
where mv.status='ACTIVE' on conflict do nothing;

insert into public.matrix_employee_roles(matrix_version_id,employee_id,role_id,is_primary,can_lead)
select mv.id,e.id,mr.id,true,exists(select 1 from employee_capabilities ec where ec.employee_id=e.id and ec.capability='ROLE_MANAGER' and ec.active)
from public.matrix_versions mv join public.employees e on true join public.matrix_roles mr on mr.matrix_version_id=mv.id and mr.code=e.primary_role::text
where mv.status='ACTIVE' on conflict do nothing;

create table if not exists public.role_plan_assignments (
  role_plan_section_id uuid not null references public.role_plan_sections(id) on delete cascade,
  assignment_id uuid not null references public.assignments(id) on delete cascade,
  primary key(role_plan_section_id,assignment_id)
);

alter table public.employee_hr_profiles enable row level security;
alter table public.role_plan_assignments enable row level security;

drop policy if exists hr_read on public.employee_hr_profiles;
create policy hr_read on public.employee_hr_profiles for select to authenticated using(
  public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE')
  or exists(select 1 from public.employees e where e.id=employee_id and e.auth_user_id=auth.uid())
);
drop policy if exists hr_write on public.employee_hr_profiles;
create policy hr_write on public.employee_hr_profiles for all to authenticated using(
  public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE')
) with check(public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE'));
drop policy if exists role_plan_assignments_read on public.role_plan_assignments;
create policy role_plan_assignments_read on public.role_plan_assignments for select to authenticated using(public.can_manage_plans());

create or replace function public.complete_workspace(p_month date default current_date)
returns jsonb language sql stable security definer set search_path=public as $$
with target_month as (select date_trunc('month',p_month)::date as target_date),
active_matrix as (select * from matrix_versions where status='ACTIVE' order by version desc limit 1),
draft_matrix as (select * from matrix_versions where status='DRAFT' order by version desc limit 1),
chosen_plan as (
  select p.* from plans p,target_month t where p.month=t.target_date
  order by case p.status when 'PUBLISHED' then 1 when 'READY' then 2 else 3 end,p.version desc limit 1
)
select jsonb_build_object(
 'counts',jsonb_build_object(
   'employees',(select count(*) from employees where active),
   'archivedEmployees',(select count(*) from employees where not active),
   'roleManagers',(select count(distinct employee_id) from employee_capabilities where capability='ROLE_MANAGER' and active),
   'locations',(select count(*) from locations where active)
 ),
 'employees',coalesce((select jsonb_agg(jsonb_build_object(
   'id',e.id,'employeeNo',e.employee_no,'firstName',e.first_name,'lastName',e.last_name,'email',e.email,
   'primaryRole',e.primary_role,'nominalMinutes',e.monthly_nominal_minutes,'maxWeeklyMinutes',e.max_weekly_minutes,
   'maxMonthlyMinutes',e.max_monthly_minutes,'preferredShift',e.preferred_shift,'active',e.active,
   'archivedAt',e.archived_at,'archiveReason',e.archive_reason,
   'locations',coalesce((select jsonb_agg(jsonb_build_object('code',l.code,'name',l.name,'home',el.home_location,'standard',el.standard_allowed,'overtime',el.overtime_allowed) order by l.name) from employee_locations el join locations l on l.id=el.location_id where el.employee_id=e.id),'[]'::jsonb),
   'capabilities',coalesce((select jsonb_agg(jsonb_build_object('id',ec.id,'capability',ec.capability,'role',ec.scope_role,'location',ec.scope_location) order by ec.capability) from employee_capabilities ec where ec.employee_id=e.id and ec.active),'[]'::jsonb),
   'hr',case when public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE') then (select to_jsonb(h)-'employee_id' from employee_hr_profiles h where h.employee_id=e.id) else null end,
   'finance',case when public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE') then jsonb_build_object('hourlyRate',e.hourly_rate) else null end
 ) order by e.active desc,e.employee_no) from employees e where
   public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE')
   or public.has_app_role('ROLE_MANAGER') or public.has_app_role('LOCATION_MANAGER') or e.auth_user_id=auth.uid()),'[]'::jsonb),
 'activeMatrix',(select to_jsonb(a) from active_matrix a),
 'draftMatrix',(select to_jsonb(d) from draft_matrix d),
 'roles',coalesce((select jsonb_agg(to_jsonb(r) order by r.sort_order) from matrix_roles r where r.matrix_version_id=coalesce((select id from draft_matrix),(select id from active_matrix))),'[]'::jsonb),
 'functions',coalesce((select jsonb_agg(to_jsonb(f) order by f.name) from matrix_functions f where f.matrix_version_id=coalesce((select id from draft_matrix),(select id from active_matrix))),'[]'::jsonb),
 'locations',coalesce((select jsonb_agg(to_jsonb(l) order by l.name) from matrix_locations l where l.matrix_version_id=coalesce((select id from draft_matrix),(select id from active_matrix))),'[]'::jsonb),
 'shifts',coalesce((select jsonb_agg(to_jsonb(s) order by s.sort_order,s.name) from matrix_shift_templates s where s.matrix_version_id=coalesce((select id from draft_matrix),(select id from active_matrix))),'[]'::jsonb),
 'demand',coalesce((select jsonb_agg(to_jsonb(d)) from matrix_demand d join matrix_shift_templates s on s.id=d.shift_template_id where s.matrix_version_id=coalesce((select id from draft_matrix),(select id from active_matrix))),'[]'::jsonb),
 'sections',coalesce((select jsonb_agg(jsonb_build_object(
   'id',rp.id,'roleId',rp.role_id,'roleCode',r.code,'roleName',r.name,'version',rp.version,'status',rp.status,'name',rp.name,
   'createdAt',rp.created_at,'updatedAt',rp.updated_at,'planId',rp.legacy_plan_id,
   'assignmentCount',(select count(*) from role_plan_assignments ra where ra.role_plan_section_id=rp.id),
   'issueCount',(select count(*) from plan_issues pi where pi.plan_id=rp.legacy_plan_id and pi.role::text=r.code and pi.resolved_at is null)
 ) order by r.sort_order,rp.version desc) from role_plan_sections rp join matrix_roles r on r.id=rp.role_id,target_month t where rp.month=t.target_date),'[]'::jsonb),
 'plan',(select to_jsonb(p) from chosen_plan p),
 'budget',coalesce((select to_jsonb(b) from monthly_budgets b,target_month t where b.month=t.target_date),'{}'::jsonb),
 'preferences',coalesce((select jsonb_agg(to_jsonb(ep) order by ep.valid_from desc) from employee_preferences ep where ep.valid_to >= (select target_date from target_month)),'[]'::jsonb),
 'integrationRuns',coalesce((select jsonb_agg(to_jsonb(ir) order by ir.created_at desc) from integration_runs ir limit 20),'[]'::jsonb),
 'timeRecords',coalesce((select jsonb_agg(to_jsonb(tr) order by tr.work_date desc) from time_records tr,target_month t where date_trunc('month',tr.work_date)::date=t.target_date),'[]'::jsonb)
);
$$;

create or replace function public.employee_archive(p_employee_id uuid,p_reason text default null)
returns void language plpgsql security definer set search_path=public as $$ begin
 if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE')) then raise exception 'FORBIDDEN'; end if;
 update employees set active=false,archived_at=now(),archived_by=auth.uid(),archive_reason=nullif(trim(p_reason),'') where id=p_employee_id;
 if not found then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
 insert into audit_log(actor_id,entity_type,entity_id,action,new_data) values(auth.uid(),'employee',p_employee_id::text,'ARCHIVE',jsonb_build_object('reason',p_reason));
end $$;

create or replace function public.employee_restore(p_employee_id uuid)
returns void language plpgsql security definer set search_path=public as $$ begin
 if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE')) then raise exception 'FORBIDDEN'; end if;
 update employees set active=true,archived_at=null,archived_by=null,archive_reason=null,employment_end=null where id=p_employee_id;
 if not found then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
 insert into audit_log(actor_id,entity_type,entity_id,action) values(auth.uid(),'employee',p_employee_id::text,'RESTORE');
end $$;

create or replace function public.employee_update(p_employee_id uuid,p_data jsonb)
returns void language plpgsql security definer set search_path=public as $$ begin
 if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE')) then raise exception 'FORBIDDEN'; end if;
 update employees set
   first_name=coalesce(nullif(trim(p_data->>'firstName'),''),first_name),last_name=coalesce(nullif(trim(p_data->>'lastName'),''),last_name),
   email=coalesce(nullif(trim(p_data->>'email'),''),email),primary_role=coalesce(nullif(p_data->>'primaryRole','')::employee_role,primary_role),
   monthly_nominal_minutes=coalesce((p_data->>'nominalMinutes')::integer,monthly_nominal_minutes),max_weekly_minutes=coalesce((p_data->>'maxWeeklyMinutes')::integer,max_weekly_minutes),
   max_monthly_minutes=coalesce((p_data->>'maxMonthlyMinutes')::integer,max_monthly_minutes),preferred_shift=coalesce(nullif(p_data->>'preferredShift',''),preferred_shift),
   hourly_rate=case when public.has_app_role('OWNER') or public.has_app_role('HR_FINANCE') then coalesce((p_data->>'hourlyRate')::numeric,hourly_rate) else hourly_rate end,
   updated_at=now() where id=p_employee_id;
 insert into employee_hr_profiles(employee_id,contract_type,employment_fraction,leave_days,hr_note,updated_by,updated_at)
 values(p_employee_id,coalesce(nullif(p_data->>'contractType',''),'UMOWA_O_PRACE'),coalesce((p_data->>'employmentFraction')::numeric,1),coalesce((p_data->>'leaveDays')::integer,0),nullif(p_data->>'hrNote',''),auth.uid(),now())
 on conflict(employee_id) do update set contract_type=excluded.contract_type,employment_fraction=excluded.employment_fraction,leave_days=excluded.leave_days,hr_note=excluded.hr_note,updated_by=auth.uid(),updated_at=now();
 insert into audit_log(actor_id,entity_type,entity_id,action,new_data) values(auth.uid(),'employee',p_employee_id::text,'UPDATE',p_data-'hourlyRate');
end $$;

create or replace function public.matrix_create_draft(p_name text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare a matrix_versions; n uuid; v integer; begin
 if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
 select * into a from matrix_versions where status='ACTIVE' order by version desc limit 1;
 if exists(select 1 from matrix_versions where status='DRAFT') then return (select id from matrix_versions where status='DRAFT' order by version desc limit 1); end if;
 select coalesce(max(version),0)+1 into v from matrix_versions;
 insert into matrix_versions(version,name,status,effective_from,settings,created_by) values(v,coalesce(nullif(trim(p_name),''),'Matrix v'||v),'DRAFT',a.effective_from,a.settings,auth.uid()) returning id into n;
  insert into matrix_roles(matrix_version_id,code,name,color,sort_order,active) select n,code,name,color,sort_order,active from matrix_roles where matrix_version_id=a.id;
  insert into matrix_locations(matrix_version_id,code,name,active) select n,code,name,active from matrix_locations where matrix_version_id=a.id;
  insert into matrix_functions(matrix_version_id,code,name,description,active) select n,code,name,description,active from matrix_functions where matrix_version_id=a.id;
  insert into matrix_shift_templates(matrix_version_id,location_id,code,name,starts_at,ends_at,day_mask,sort_order,active)
  select n,nl.id,s.code,s.name,s.starts_at,s.ends_at,s.day_mask,s.sort_order,s.active
  from matrix_shift_templates s join matrix_locations ol on ol.id=s.location_id
  join matrix_locations nl on nl.matrix_version_id=n and nl.code=ol.code where s.matrix_version_id=a.id;
  insert into matrix_role_functions(role_id,function_id,assignment_mode)
  select nr.id,nf.id,rf.assignment_mode from matrix_role_functions rf
  join matrix_roles orr on orr.id=rf.role_id join matrix_functions ofn on ofn.id=rf.function_id
  join matrix_roles nr on nr.matrix_version_id=n and nr.code=orr.code
  join matrix_functions nf on nf.matrix_version_id=n and nf.code=ofn.code;
  insert into matrix_demand(shift_template_id,role_id,function_id,scenario_code,required_count)
  select ns.id,nr.id,nf.id,md.scenario_code,md.required_count from matrix_demand md
  join matrix_shift_templates os on os.id=md.shift_template_id join matrix_locations ol on ol.id=os.location_id
  join matrix_roles orr on orr.id=md.role_id left join matrix_functions ofn on ofn.id=md.function_id
  join matrix_locations nl on nl.matrix_version_id=n and nl.code=ol.code
  join matrix_shift_templates ns on ns.matrix_version_id=n and ns.location_id=nl.id and ns.code=os.code
  join matrix_roles nr on nr.matrix_version_id=n and nr.code=orr.code
  left join matrix_functions nf on nf.matrix_version_id=n and nf.code=ofn.code;
 return n;
end $$;

create or replace function public.matrix_save_item(p_kind text,p_id uuid,p_data jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare d uuid; out_id uuid; begin
 if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
 d:=matrix_create_draft(null);
 if p_kind='ROLE' then
   if p_id is null then insert into matrix_roles(matrix_version_id,code,name,color,sort_order) values(d,upper(p_data->>'code'),p_data->>'name',coalesce(p_data->>'color','#7257d8'),coalesce((p_data->>'sortOrder')::integer,99)) returning id into out_id;
   else update matrix_roles set code=upper(coalesce(nullif(p_data->>'code',''),code)),name=coalesce(nullif(p_data->>'name',''),name),color=coalesce(nullif(p_data->>'color',''),color),active=coalesce((p_data->>'active')::boolean,active) where id=p_id and matrix_version_id=d returning id into out_id; end if;
 elsif p_kind='FUNCTION' then
   if p_id is null then insert into matrix_functions(matrix_version_id,code,name,description) values(d,upper(p_data->>'code'),p_data->>'name',p_data->>'description') returning id into out_id;
   else update matrix_functions set code=upper(coalesce(nullif(p_data->>'code',''),code)),name=coalesce(nullif(p_data->>'name',''),name),description=coalesce(p_data->>'description',description),active=coalesce((p_data->>'active')::boolean,active) where id=p_id and matrix_version_id=d returning id into out_id; end if;
 elsif p_kind='LOCATION' then
   if p_id is null then insert into matrix_locations(matrix_version_id,code,name) values(d,upper(p_data->>'code'),p_data->>'name') returning id into out_id;
   else update matrix_locations set code=upper(coalesce(nullif(p_data->>'code',''),code)),name=coalesce(nullif(p_data->>'name',''),name),active=coalesce((p_data->>'active')::boolean,active) where id=p_id and matrix_version_id=d returning id into out_id; end if;
 else raise exception 'INVALID_KIND'; end if;
 if out_id is null then raise exception 'ITEM_NOT_IN_DRAFT'; end if; return out_id;
end $$;

create or replace function public.matrix_publish_draft(p_effective_from date)
returns uuid language plpgsql security definer set search_path=public as $$ declare d matrix_versions; begin
 if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
 select * into d from matrix_versions where status='DRAFT' order by version desc limit 1 for update;
 if d.id is null then raise exception 'NO_DRAFT'; end if;
 update matrix_versions set status='ARCHIVED',effective_to=p_effective_from-1 where status='ACTIVE';
 update matrix_versions set status='ACTIVE',effective_from=p_effective_from,activated_at=now() where id=d.id;
 return d.id;
end $$;

create or replace function public.generate_role_plan(p_month date,p_role_id uuid,p_name text,p_scenario text default 'BASE',p_mode text default 'BALANCED',p_staffing text default 'OPTIMAL')
returns jsonb language plpgsql security definer set search_path=public as $$
declare generated jsonb; v_plan_id uuid; section_id uuid; role_code text; cnt integer; begin
 generated:=public.generate_plan(p_month,p_name,p_scenario,p_mode,p_staffing); v_plan_id:=(generated->>'plan_id')::uuid;
 section_id:=public.create_role_plan_section(p_month,p_role_id,p_name,p_scenario,p_mode,p_staffing);
 select code into role_code from matrix_roles where id=p_role_id;
 update role_plan_sections set legacy_plan_id=v_plan_id,status='READY',updated_at=now() where id=section_id;
 insert into role_plan_assignments(role_plan_section_id,assignment_id)
 select section_id,a.id from assignments a join shifts s on s.id=a.shift_id where s.plan_id=v_plan_id and a.assigned_role::text=role_code;
 get diagnostics cnt=row_count;
 return jsonb_build_object('sectionId',section_id,'planId',v_plan_id,'assignments',cnt,'issues',(select count(*) from plan_issues pi where pi.plan_id=v_plan_id and pi.role::text=role_code));
end $$;

create or replace function public.role_plan_workspace(p_section_id uuid)
returns jsonb language sql stable security definer set search_path=public as $$
select jsonb_build_object(
 'section',jsonb_build_object('id',rp.id,'name',rp.name,'status',rp.status,'version',rp.version,'roleCode',r.code,'roleName',r.name,'month',rp.month),
 'assignments',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'employeeId',e.id,'employeeNo',e.employee_no,'employeeName',e.first_name||' '||e.last_name,'date',s.shift_date,'location',l.code,'shiftCode',s.shift_code,'startsAt',s.starts_at,'endsAt',s.ends_at,'capability',a.assigned_capability) order by s.shift_date,s.starts_at,e.last_name) from role_plan_assignments ra join assignments a on a.id=ra.assignment_id join employees e on e.id=a.employee_id join shifts s on s.id=a.shift_id join locations l on l.id=s.location_id where ra.role_plan_section_id=rp.id),'[]'::jsonb),
 'issues',coalesce((select jsonb_agg(to_jsonb(pi) order by pi.severity desc,pi.created_at) from plan_issues pi where pi.plan_id=rp.legacy_plan_id and pi.role::text=r.code and pi.resolved_at is null),'[]'::jsonb)
) from role_plan_sections rp join matrix_roles r on r.id=rp.role_id where rp.id=p_section_id;
$$;

create or replace function public.budget_update(p_month date,p_amount numeric,p_warning_percent integer,p_hard_limit boolean)
returns void language plpgsql security definer set search_path=public as $$ begin
 if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE')) then raise exception 'FORBIDDEN'; end if;
 insert into monthly_budgets(month,amount,warning_percent,hard_limit,updated_by,updated_at) values(date_trunc('month',p_month)::date,p_amount,p_warning_percent,p_hard_limit,auth.uid(),now())
 on conflict(month) do update set amount=excluded.amount,warning_percent=excluded.warning_percent,hard_limit=excluded.hard_limit,updated_by=auth.uid(),updated_at=now();
end $$;

create or replace function public.preference_save(p_employee_id uuid,p_from date,p_to date,p_type text,p_value jsonb)
returns uuid language plpgsql security definer set search_path=public as $$ declare out_id uuid; begin
 if not(public.can_manage_plans() or exists(select 1 from employees e where e.id=p_employee_id and e.auth_user_id=auth.uid())) then raise exception 'FORBIDDEN'; end if;
 insert into employee_preferences(employee_id,valid_from,valid_to,preference_type,preference_value,source,status)
 values(p_employee_id,p_from,p_to,p_type,p_value,'GRAFIK_PRO','ACTIVE') returning id into out_id; return out_id;
end $$;

create or replace function public.kadromierz_export(p_month date)
returns jsonb language sql stable security definer set search_path=public as $$
with chosen as (select id from plans where month=date_trunc('month',p_month)::date and status='PUBLISHED' order by version desc limit 1)
select coalesce(jsonb_agg(jsonb_build_object('numer_pracownika',e.employee_no,'pracownik',e.first_name||' '||e.last_name,'data',s.shift_date,'lokal',l.code,'zmiana',s.shift_code,'od',s.starts_at,'do',s.ends_at,'rola',a.assigned_role,'funkcja',a.assigned_capability) order by s.shift_date,e.employee_no),'[]'::jsonb)
from assignments a join shifts s on s.id=a.shift_id join chosen c on c.id=s.plan_id join employees e on e.id=a.employee_id join locations l on l.id=s.location_id where public.can_manage_plans();
$$;

create or replace function public.kadromierz_import_preferences(p_file_name text,p_rows jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$ declare row jsonb; e_id uuid; imported integer:=0; skipped integer:=0; run_id uuid; begin
 if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
 insert into integration_runs(integration,direction,entity_type,status,file_name,executed_by) values('KADROMIERZ','IMPORT','PREFERENCES','RUNNING',p_file_name,auth.uid()) returning id into run_id;
 for row in select * from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) loop
   select id into e_id from employees where employee_no=coalesce(row->>'employee_no',row->>'numer_pracownika');
   if e_id is null or coalesce(row->>'date',row->>'data') is null then skipped:=skipped+1; continue; end if;
   insert into employee_preferences(employee_id,valid_from,valid_to,preference_type,preference_value,source,status)
   values(e_id,coalesce(row->>'date',row->>'data')::date,coalesce(row->>'date_to',row->>'data_do',row->>'date',row->>'data')::date,
     coalesce(nullif(row->>'type',''),'LEAVE'),jsonb_build_object('note',coalesce(row->>'note',row->>'uwagi','')),'KADROMIERZ','ACTIVE'); imported:=imported+1;
 end loop;
 update integration_runs set status=case when skipped=0 then 'SUCCESS' else 'PARTIAL' end,summary=jsonb_build_object('imported',imported,'skipped',skipped) where id=run_id;
 return jsonb_build_object('imported',imported,'skipped',skipped,'runId',run_id);
end $$;

grant execute on function public.complete_workspace(date) to authenticated;
grant execute on function public.employee_archive(uuid,text) to authenticated;
grant execute on function public.employee_restore(uuid) to authenticated;
grant execute on function public.employee_update(uuid,jsonb) to authenticated;
grant execute on function public.matrix_create_draft(text) to authenticated;
grant execute on function public.matrix_save_item(text,uuid,jsonb) to authenticated;
grant execute on function public.matrix_publish_draft(date) to authenticated;
grant execute on function public.generate_role_plan(date,uuid,text,text,text,text) to authenticated;
grant execute on function public.role_plan_workspace(uuid) to authenticated;
grant execute on function public.budget_update(date,numeric,integer,boolean) to authenticated;
grant execute on function public.preference_save(uuid,date,date,text,jsonb) to authenticated;
grant execute on function public.kadromierz_export(date) to authenticated;
grant execute on function public.kadromierz_import_preferences(text,jsonb) to authenticated;
