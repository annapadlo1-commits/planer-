-- GRAFIK PRO 3.0 Alpha 11 — naprawa spójnego przepływu planowania.
-- Nie zmienia danych źródłowych 76 pracowników ani ustalonych godzin Alpha 5.

-- Plany techniczne utworzone przez wadliwy generator roli nie mogą być aktywnym
-- grafikiem operacyjnym. Zachowujemy je, ponieważ sekcje roli wskazują ich dane.
update public.plans p set status='ARCHIVED'
where exists(select 1 from public.role_plan_sections rp where rp.legacy_plan_id=p.id);

create or replace function public.generate_role_plan(p_month date,p_role_id uuid,p_name text,p_scenario text default 'BASE',p_mode text default 'BALANCED',p_staffing text default 'OPTIMAL')
returns jsonb language plpgsql security definer set search_path=public as $$
declare generated jsonb; v_plan_id uuid; section_id uuid; role_code text; cnt integer; begin
 if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
 select code into role_code from matrix_roles where id=p_role_id and active;
 if role_code is null then raise exception 'ROLE_NOT_FOUND'; end if;
 generated:=public.generate_plan(p_month,'Źródło roli '||role_code||' • '||coalesce(p_name,''),p_scenario,p_mode,p_staffing);
 v_plan_id:=(generated->>'plan_id')::uuid;
 section_id:=public.create_role_plan_section(p_month,p_role_id,p_name,p_scenario,p_mode,p_staffing);
 update role_plan_sections set legacy_plan_id=v_plan_id,status='READY',updated_at=now() where id=section_id;
 insert into role_plan_assignments(role_plan_section_id,assignment_id)
 select section_id,a.id from assignments a join shifts s on s.id=a.shift_id
 where s.plan_id=v_plan_id and a.assigned_role::text=role_code;
 get diagnostics cnt=row_count;
 -- Kluczowa izolacja: źródło roli nigdy nie trafia do Centrum dowodzenia.
 update plans set status='ARCHIVED' where id=v_plan_id;
 return jsonb_build_object('sectionId',section_id,'assignments',cnt,
   'issues',(select count(*) from plan_issues pi where pi.plan_id=v_plan_id and pi.role::text=role_code));
exception when others then
 if v_plan_id is not null then update plans set status='FAILED' where id=v_plan_id; end if;
 raise;
end $$;

create or replace function public.matrix_save_shift(p_id uuid,p_data jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare d uuid; out_id uuid; loc uuid; begin
 if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
 d:=matrix_create_draft(null);
 loc:=(p_data->>'locationId')::uuid;
 if not exists(select 1 from matrix_locations where id=loc and matrix_version_id=d) then raise exception 'LOCATION_NOT_IN_DRAFT'; end if;
 if p_id is null then
   insert into matrix_shift_templates(matrix_version_id,location_id,code,name,starts_at,ends_at,day_mask,sort_order,active)
   values(d,loc,upper(p_data->>'code'),p_data->>'name',(p_data->>'startsAt')::time,(p_data->>'endsAt')::time,
     string_to_array(p_data->>'days',',')::smallint[],coalesce((p_data->>'sortOrder')::integer,99),true) returning id into out_id;
 else
   update matrix_shift_templates set location_id=loc,code=upper(coalesce(nullif(p_data->>'code',''),code)),
     name=coalesce(nullif(p_data->>'name',''),name),starts_at=coalesce((p_data->>'startsAt')::time,starts_at),
     ends_at=coalesce((p_data->>'endsAt')::time,ends_at),day_mask=coalesce(string_to_array(nullif(p_data->>'days',''),',')::smallint[],day_mask),
     active=coalesce((p_data->>'active')::boolean,active)
   where id=p_id and matrix_version_id=d returning id into out_id;
 end if;
 if out_id is null then raise exception 'ITEM_NOT_IN_DRAFT'; end if;
 return out_id;
end $$;

create or replace function public.matrix_save_demand(p_shift_id uuid,p_role_id uuid,p_required integer,p_scenario text default 'BASE')
returns uuid language plpgsql security definer set search_path=public as $$
declare d uuid; out_id uuid; begin
 if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
 select id into d from matrix_versions where status='DRAFT' order by version desc limit 1;
 if d is null then raise exception 'NO_DRAFT'; end if;
 if not exists(select 1 from matrix_shift_templates where id=p_shift_id and matrix_version_id=d) then raise exception 'SHIFT_NOT_IN_DRAFT'; end if;
 if not exists(select 1 from matrix_roles where id=p_role_id and matrix_version_id=d) then raise exception 'ROLE_NOT_IN_DRAFT'; end if;
 update matrix_demand set required_count=greatest(p_required,0)
 where shift_template_id=p_shift_id and role_id=p_role_id and function_id is null and scenario_code=p_scenario
 returning id into out_id;
 if out_id is null then
   insert into matrix_demand(shift_template_id,role_id,scenario_code,required_count)
   values(p_shift_id,p_role_id,p_scenario,greatest(p_required,0)) returning id into out_id;
 end if;
 return out_id;
end $$;

create or replace function public.assemble_role_plans(p_month date,p_name text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare new_plan uuid; new_version integer; sec_count integer; ass_count integer; begin
 if not(public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
 select count(*) into sec_count from role_plan_sections rp
 where rp.month=date_trunc('month',p_month)::date and rp.status='APPROVED'
   and rp.version=(select max(x.version) from role_plan_sections x where x.month=rp.month and x.role_id=rp.role_id);
 if sec_count=0 then raise exception 'NO_APPROVED_ROLE_PLANS'; end if;
 select coalesce(max(version),0)+1 into new_version from plans where month=date_trunc('month',p_month)::date;
 insert into plans(month,name,scenario_code,optimization_mode,staffing_level,status,version,created_by)
 values(date_trunc('month',p_month)::date,coalesce(nullif(trim(p_name),''),'Grafik operacyjny'),
   'MERGED','ROLE_PLANS','APPROVED','DRAFT',new_version,auth.uid()) returning id into new_plan;
 insert into shifts(plan_id,location_id,shift_date,shift_code,starts_at,ends_at,status)
 select distinct new_plan,s.location_id,s.shift_date,s.shift_code,s.starts_at,s.ends_at,'PLANNED'
 from role_plan_sections rp join role_plan_assignments rpa on rpa.role_plan_section_id=rp.id
 join assignments a on a.id=rpa.assignment_id join shifts s on s.id=a.shift_id
 where rp.month=date_trunc('month',p_month)::date and rp.status='APPROVED'
   and rp.version=(select max(x.version) from role_plan_sections x where x.month=rp.month and x.role_id=rp.role_id);
 insert into assignments(shift_id,employee_id,assigned_role,assigned_capability,assignment_type,cost,locked,explanation)
 select ns.id,a.employee_id,a.assigned_role,a.assigned_capability,a.assignment_type,a.cost,a.locked,
   a.explanation||jsonb_build_object('source','ROLE_PLAN','sourceAssignment',a.id)
 from role_plan_sections rp join role_plan_assignments rpa on rpa.role_plan_section_id=rp.id
 join assignments a on a.id=rpa.assignment_id join shifts os on os.id=a.shift_id
 join shifts ns on ns.plan_id=new_plan and ns.location_id=os.location_id and ns.shift_date=os.shift_date
   and ns.shift_code=os.shift_code and ns.starts_at=os.starts_at and ns.ends_at=os.ends_at
 where rp.month=date_trunc('month',p_month)::date and rp.status='APPROVED'
   and rp.version=(select max(x.version) from role_plan_sections x where x.month=rp.month and x.role_id=rp.role_id)
 on conflict do nothing;
 get diagnostics ass_count=row_count;
 update plans set status='READY',generated_at=now(),total_cost=(select coalesce(sum(cost),0) from assignments a join shifts s on s.id=a.shift_id where s.plan_id=new_plan) where id=new_plan;
 insert into composite_schedules(month,matrix_version_id,version,name,status,section_ids,created_by)
 select date_trunc('month',p_month)::date,(select id from matrix_versions where status='ACTIVE' order by version desc limit 1),
   coalesce((select max(version)+1 from composite_schedules where month=date_trunc('month',p_month)::date),1),p_name,'READY',
   array_agg(id),auth.uid() from role_plan_sections rp where rp.month=date_trunc('month',p_month)::date and rp.status='APPROVED'
   and rp.version=(select max(x.version) from role_plan_sections x where x.month=rp.month and x.role_id=rp.role_id);
 return jsonb_build_object('planId',new_plan,'sections',sec_count,'assignments',ass_count,'version',new_version);
end $$;

create or replace function public.attendance_clock(p_action text,p_location text,p_latitude numeric default null,p_longitude numeric default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e employees; l locations; out_id uuid; last_type text; begin
 select * into e from employees where auth_user_id=auth.uid() and active;
 if e.id is null then raise exception 'EMPLOYEE_ACCOUNT_NOT_LINKED'; end if;
 select * into l from locations where code::text=p_location and active;
 if l.id is null then raise exception 'LOCATION_NOT_FOUND'; end if;
 if not exists(select 1 from employee_locations el where el.employee_id=e.id and el.location_id=l.id and (el.standard_allowed or el.overtime_allowed or el.home_location)) then raise exception 'LOCATION_NOT_ALLOWED'; end if;
 select event_type::text into last_type from attendance_events where employee_id=e.id order by occurred_at desc limit 1;
 if p_action='CHECK_IN' and last_type='CHECK_IN' then raise exception 'ALREADY_CLOCKED_IN'; end if;
 if p_action='CHECK_OUT' and coalesce(last_type,'')<>'CHECK_IN' then raise exception 'NOT_CLOCKED_IN'; end if;
 if p_action not in ('CHECK_IN','CHECK_OUT') then raise exception 'INVALID_ACTION'; end if;
 insert into attendance_events(employee_id,location_id,event_type,verification_method,latitude,longitude,created_by)
 values(e.id,l.id,p_action::attendance_event_type,'GEOLOCATION',p_latitude,p_longitude,auth.uid()) returning id into out_id;
 return jsonb_build_object('id',out_id,'action',p_action,'occurredAt',now(),'location',l.name);
end $$;

create or replace function public.employee_portal_workspace(p_month date default current_date)
returns jsonb language sql stable security definer set search_path=public as $$
with me as(select * from employees where auth_user_id=auth.uid() and active limit 1),
published as(select id from plans where month=date_trunc('month',p_month)::date and status='PUBLISHED' order by version desc limit 1)
select jsonb_build_object(
 'employee',(select jsonb_build_object('id',m.id,'employeeNo',m.employee_no,'firstName',m.first_name,'lastName',m.last_name,'primaryRole',m.primary_role,
   'locations',coalesce((select jsonb_agg(jsonb_build_object('code',l.code,'name',l.name)) from employee_locations el join locations l on l.id=el.location_id where el.employee_id=m.id and (el.standard_allowed or el.overtime_allowed or el.home_location)),'[]'::jsonb)) from me m),
 'preferences',coalesce((select jsonb_agg(to_jsonb(ep) order by ep.valid_from desc) from employee_preferences ep join me on me.id=ep.employee_id),'[]'::jsonb),
 'assignments',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'date',s.shift_date,'startsAt',s.starts_at,'endsAt',s.ends_at,'location',l.name,'role',a.assigned_role,'capability',a.assigned_capability) order by s.starts_at)
   from assignments a join shifts s on s.id=a.shift_id join published p on p.id=s.plan_id join locations l on l.id=s.location_id join me on me.id=a.employee_id),'[]'::jsonb),
 'attendance',coalesce((select jsonb_agg(jsonb_build_object('id',ae.id,'action',ae.event_type,'occurredAt',ae.occurred_at,'location',l.name) order by ae.occurred_at desc)
   from attendance_events ae join locations l on l.id=ae.location_id join me on me.id=ae.employee_id where ae.occurred_at>=date_trunc('month',p_month)),'[]'::jsonb)
);
$$;

grant execute on function public.matrix_save_shift(uuid,jsonb) to authenticated;
grant execute on function public.matrix_save_demand(uuid,uuid,integer,text) to authenticated;
grant execute on function public.assemble_role_plans(date,text) to authenticated;
grant execute on function public.attendance_clock(text,text,numeric,numeric) to authenticated;
grant execute on function public.employee_portal_workspace(date) to authenticated;
