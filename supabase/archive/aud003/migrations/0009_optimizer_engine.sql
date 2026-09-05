-- GRAFIK PRO 3.0 Alpha 13
-- Versioned Matrix-driven optimization engine: hard constraints, soft weights,
-- auditable runs and database-side validation of solver output.

alter table public.employees
  add column if not exists max_consecutive_days integer not null default 6,
  add column if not exists minimum_rest_minutes integer,
  add column if not exists only_morning boolean not null default false,
  add column if not exists only_evening boolean not null default false,
  add column if not exists no_weekends boolean not null default false;

create table if not exists public.optimizer_profiles (
  id uuid primary key default gen_random_uuid(),
  matrix_version_id uuid not null references public.matrix_versions(id) on delete cascade,
  code text not null,
  name text not null,
  weights jsonb not null default '{"shortage":1000000,"capability":1000000,"overtime":250,"cost":1,"preference":80,"fairness":40,"nominal":30,"homeLocation":15,"weekendFairness":25}'::jsonb,
  population_size integer not null default 32 check (population_size between 8 and 256),
  generations integer not null default 40 check (generations between 1 and 500),
  elite_count integer not null default 6 check (elite_count between 1 and 64),
  mutation_rate numeric not null default 0.08 check (mutation_rate between 0 and 1),
  alternatives_count integer not null default 3 check (alternatives_count between 1 and 10),
  active boolean not null default true,
  unique(matrix_version_id, code)
);

create table if not exists public.optimization_runs (
  id uuid primary key default gen_random_uuid(),
  month date not null check (date_trunc('month',month)::date=month),
  matrix_version_id uuid not null references public.matrix_versions(id),
  profile_id uuid not null references public.optimizer_profiles(id),
  scenario_code text not null default 'BASE',
  status text not null default 'QUEUED' check(status in ('QUEUED','RUNNING','SUCCEEDED','INFEASIBLE','FAILED')),
  seed integer not null,
  requested_by uuid not null references auth.users(id),
  started_at timestamptz,
  finished_at timestamptz,
  input_snapshot jsonb not null default '{}'::jsonb,
  result_summary jsonb not null default '{}'::jsonb,
  failure_message text,
  created_at timestamptz not null default now()
);

create table if not exists public.optimization_candidates (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references public.optimization_runs(id) on delete cascade,
  rank integer not null check(rank > 0),
  score numeric not null,
  hard_violations integer not null default 0,
  metrics jsonb not null,
  assignments jsonb not null,
  selected boolean not null default false,
  created_at timestamptz not null default now(),
  unique(run_id,rank)
);

create index if not exists optimization_runs_month_idx on public.optimization_runs(month,created_at desc);
create index if not exists optimization_candidates_run_idx on public.optimization_candidates(run_id,rank);

alter table public.optimizer_profiles enable row level security;
alter table public.optimization_runs enable row level security;
alter table public.optimization_candidates enable row level security;

drop policy if exists optimizer_profiles_read on public.optimizer_profiles;
create policy optimizer_profiles_read on public.optimizer_profiles for select to authenticated
using (public.can_manage_plans());
drop policy if exists optimizer_profiles_manage on public.optimizer_profiles;
create policy optimizer_profiles_manage on public.optimizer_profiles for all to authenticated
using (public.has_app_role('OWNER') or public.has_app_role('ADMIN'))
with check (public.has_app_role('OWNER') or public.has_app_role('ADMIN'));

drop policy if exists optimization_runs_read on public.optimization_runs;
create policy optimization_runs_read on public.optimization_runs for select to authenticated
using (public.can_manage_plans());
drop policy if exists optimization_candidates_read on public.optimization_candidates;
create policy optimization_candidates_read on public.optimization_candidates for select to authenticated
using (exists(select 1 from public.optimization_runs r where r.id=run_id and public.can_manage_plans()));

insert into public.optimizer_profiles(matrix_version_id,code,name)
select id,'BALANCED','Zbalansowany' from public.matrix_versions where status='ACTIVE'
on conflict(matrix_version_id,code) do nothing;
insert into public.optimizer_profiles(matrix_version_id,code,name,weights)
select id,'MIN_COST','Minimalny koszt','{"shortage":1000000,"capability":1000000,"overtime":500,"cost":4,"preference":30,"fairness":15,"nominal":20,"homeLocation":5,"weekendFairness":10}'::jsonb from public.matrix_versions where status='ACTIVE'
on conflict(matrix_version_id,code) do nothing;
insert into public.optimizer_profiles(matrix_version_id,code,name,weights)
select id,'FAIR','Równy podział','{"shortage":1000000,"capability":1000000,"overtime":300,"cost":0.5,"preference":100,"fairness":120,"nominal":90,"homeLocation":20,"weekendFairness":100}'::jsonb from public.matrix_versions where status='ACTIVE'
on conflict(matrix_version_id,code) do nothing;

create or replace function public.optimizer_prepare(
  p_month date,
  p_profile_code text default 'BALANCED',
  p_scenario_code text default 'BASE',
  p_seed integer default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare mv public.matrix_versions; profile public.optimizer_profiles; run_id uuid; payload jsonb;
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  p_month:=date_trunc('month',p_month)::date;
  select * into mv from public.matrix_versions
   where status='ACTIVE' and effective_from<=p_month and (effective_to is null or effective_to>=p_month)
   order by version desc limit 1;
  if mv.id is null then raise exception 'ACTIVE_MATRIX_NOT_FOUND'; end if;
  select * into profile from public.optimizer_profiles
   where matrix_version_id=mv.id and code=upper(p_profile_code) and active limit 1;
  if profile.id is null then raise exception 'OPTIMIZER_PROFILE_NOT_FOUND'; end if;
  insert into public.optimization_runs(month,matrix_version_id,profile_id,scenario_code,status,seed,requested_by,started_at)
  values(p_month,mv.id,profile.id,upper(p_scenario_code),'RUNNING',coalesce(p_seed,(extract(epoch from clock_timestamp())::bigint%2147483647)::integer),auth.uid(),now())
  returning id into run_id;

  select jsonb_build_object(
    'runId',run_id,'month',p_month,'scenario',upper(p_scenario_code),'seed',(select seed from public.optimization_runs where id=run_id),
    'matrix',jsonb_build_object('id',mv.id,'version',mv.version,'settings',mv.settings),
    'profile',jsonb_build_object('id',profile.id,'code',profile.code,'weights',profile.weights,
      'populationSize',profile.population_size,'generations',profile.generations,'eliteCount',profile.elite_count,
      'mutationRate',profile.mutation_rate,'alternativesCount',profile.alternatives_count),
    'employees',coalesce((select jsonb_agg(jsonb_build_object(
      'id',e.id,'employeeNo',e.employee_no,'role',e.primary_role,'nominal',e.monthly_nominal_minutes,
      'maxMonthly',coalesce(e.max_monthly_minutes,e.monthly_nominal_minutes),'maxWeekly',e.max_weekly_minutes,
      'maxConsecutiveDays',e.max_consecutive_days,'minimumRest',coalesce(e.minimum_rest_minutes,(mv.settings->>'minimumRestMinutes')::integer,660),
      'onlyMorning',e.only_morning,'onlyEvening',e.only_evening,'noWeekends',e.no_weekends,
      'rate',e.hourly_rate,'preferredShift',e.preferred_shift,'employmentStart',e.employment_start,'employmentEnd',e.employment_end,
      'locations',coalesce((select jsonb_agg(jsonb_build_object('id',el.location_id,'home',el.home_location)) from public.employee_locations el where el.employee_id=e.id and (el.standard_allowed or el.overtime_allowed)),'[]'::jsonb),
      'roles',coalesce((select jsonb_agg(mr.code) from public.matrix_employee_roles mer join public.matrix_roles mr on mr.id=mer.role_id where mer.matrix_version_id=mv.id and mer.employee_id=e.id),jsonb_build_array(e.primary_role::text)),
      'capabilities',coalesce((select jsonb_agg(jsonb_build_object('code',ec.capability,'role',ec.scope_role,'location',ec.scope_location)) from public.employee_capabilities ec where ec.employee_id=e.id and ec.active),'[]'::jsonb)
    ) order by e.employee_no) from public.employees e where e.active and e.archived_at is null),'[]'::jsonb),
    'availability',coalesce((select jsonb_agg(jsonb_build_object('employeeId',a.employee_id,'date',a.work_date,'available',a.available,'earliestStart',a.earliest_start,'latestEnd',a.latest_end,'status',case when a.available then 'AVAILABLE' else 'UNAVAILABLE' end)) from public.employee_availability a where a.work_date>=p_month and a.work_date<p_month+interval '1 month'),'[]'::jsonb),
    'preferences',coalesce((select jsonb_agg(jsonb_build_object('employeeId',p.employee_id,'from',p.valid_from,'to',p.valid_to,'type',p.preference_type,'value',p.preference_value)) from public.employee_preferences p where p.status='ACTIVE' and p.valid_from<p_month+interval '1 month' and p.valid_to>=p_month),'[]'::jsonb),
    'templates',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'locationId',l.id,'locationCode',ml.code,'timezone',l.timezone,'code',s.code,'start',s.starts_at,'end',s.ends_at,'days',s.day_mask)) from public.matrix_shift_templates s join public.matrix_locations ml on ml.id=s.location_id join public.locations l on l.code::text=ml.code where s.matrix_version_id=mv.id and s.active and ml.active and l.active),'[]'::jsonb),
    'demand',coalesce((select jsonb_agg(jsonb_build_object('templateId',d.shift_template_id,'roleId',d.role_id,'role',r.code,'functionId',d.function_id,'function',f.code,'count',d.required_count,'scenario',d.scenario_code)) from public.matrix_demand d join public.matrix_shift_templates s on s.id=d.shift_template_id join public.matrix_roles r on r.id=d.role_id left join public.matrix_functions f on f.id=d.function_id where s.matrix_version_id=mv.id and d.scenario_code in ('BASE',upper(p_scenario_code))),'[]'::jsonb)
  ) into payload;
  update public.optimization_runs set input_snapshot=jsonb_build_object(
    'employeeCount',jsonb_array_length(payload->'employees'),'availabilityCount',jsonb_array_length(payload->'availability'),
    'preferenceCount',jsonb_array_length(payload->'preferences'),'templateCount',jsonb_array_length(payload->'templates'),
    'demandCount',jsonb_array_length(payload->'demand'),'matrixVersion',mv.version) where id=run_id;
  return payload;
end $$;

create or replace function public.optimizer_commit(
  p_run_id uuid,
  p_name text,
  p_candidates jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare r public.optimization_runs; best jsonb; c jsonb; a jsonb; plan_id uuid; shift_id uuid;
  plan_version integer; start_at timestamptz; end_at timestamptz; emp public.employees; loc public.locations;
  total_cost numeric:=0; assignment_count integer:=0; issue_count integer:=0; hard_count integer:=0;
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  select * into r from public.optimization_runs where id=p_run_id and requested_by=auth.uid() for update;
  if r.id is null or r.status<>'RUNNING' then raise exception 'OPTIMIZATION_RUN_NOT_WRITABLE'; end if;
  if jsonb_array_length(coalesce(p_candidates,'[]'::jsonb))=0 then raise exception 'NO_CANDIDATES'; end if;
  best:=p_candidates->0;
  if coalesce((best->>'hardViolations')::integer,0)>0 then raise exception 'BEST_CANDIDATE_HAS_HARD_VIOLATIONS'; end if;
  select coalesce(max(version),0)+1 into plan_version from public.plans where month=r.month;
  insert into public.plans(month,name,scenario_code,optimization_mode,staffing_level,status,version,score,total_cost,generated_at,created_by)
  values(r.month,coalesce(nullif(trim(p_name),''),'Plan optymalny '||to_char(r.month,'YYYY-MM')),r.scenario_code,
    (select code from public.optimizer_profiles where id=r.profile_id),'OPTIMAL','GENERATING',plan_version,
    (best->>'score')::numeric,0,now(),auth.uid()) returning id into plan_id;

  for a in select value from jsonb_array_elements(coalesce(best->'assignments','[]'::jsonb)) loop
    select * into emp from public.employees where id=(a->>'employeeId')::uuid and active and archived_at is null;
    select * into loc from public.locations where id=(a->>'locationId')::uuid and active;
    if emp.id is null or loc.id is null then raise exception 'INVALID_EMPLOYEE_OR_LOCATION'; end if;
    start_at:=(a->>'startsAt')::timestamptz; end_at:=(a->>'endsAt')::timestamptz;
    if end_at<=start_at or not exists(select 1 from public.employee_locations el where el.employee_id=emp.id and el.location_id=loc.id and (el.standard_allowed or el.overtime_allowed)) then raise exception 'HARD_CONSTRAINT_LOCATION_OR_TIME'; end if;
    if ((emp.employment_start is not null and (a->>'date')::date<emp.employment_start) or (emp.employment_end is not null and (a->>'date')::date>emp.employment_end)
      or (emp.no_weekends and extract(isodow from (a->>'date')::date) in (6,7))
      or (emp.only_morning and start_at::time>=time '15:00') or (emp.only_evening and start_at::time<time '14:00')) then raise exception 'HARD_CONSTRAINT_EMPLOYMENT_PATTERN'; end if;
    if not (emp.primary_role::text=a->>'role' or exists(select 1 from public.matrix_employee_roles mer join public.matrix_roles mr on mr.id=mer.role_id where mer.matrix_version_id=r.matrix_version_id and mer.employee_id=emp.id and mr.code=a->>'role')) then raise exception 'HARD_CONSTRAINT_ROLE'; end if;
    if nullif(a->>'function','') is not null and not exists(select 1 from public.employee_capabilities ec where ec.employee_id=emp.id and ec.active and ec.capability=a->>'function' and (ec.scope_role is null or ec.scope_role::text=a->>'role') and (ec.scope_location is null or ec.scope_location::text=loc.code::text)) then raise exception 'HARD_CONSTRAINT_CAPABILITY'; end if;
    if exists(select 1 from public.employee_availability av where av.employee_id=emp.id and av.work_date=(a->>'date')::date and (not av.available or (av.earliest_start is not null and start_at::time<av.earliest_start) or (av.latest_end is not null and end_at::time>av.latest_end))) then raise exception 'HARD_CONSTRAINT_AVAILABILITY'; end if;
    if exists(select 1 from public.assignments ax join public.shifts sx on sx.id=ax.shift_id where sx.plan_id=plan_id and ax.employee_id=emp.id and tstzrange(sx.starts_at,sx.ends_at,'[)') && tstzrange(start_at,end_at,'[)')) then raise exception 'HARD_CONSTRAINT_OVERLAP'; end if;
    if exists(select 1 from public.assignments ax join public.shifts sx on sx.id=ax.shift_id where sx.plan_id=plan_id and ax.employee_id=emp.id and tstzrange(sx.starts_at-coalesce(emp.minimum_rest_minutes,660)*interval '1 minute',sx.ends_at+coalesce(emp.minimum_rest_minutes,660)*interval '1 minute','[)') && tstzrange(start_at,end_at,'[)')) then raise exception 'HARD_CONSTRAINT_REST'; end if;
    if coalesce((select sum(public.shift_minutes(sx.starts_at,sx.ends_at)) from public.assignments ax join public.shifts sx on sx.id=ax.shift_id where sx.plan_id=plan_id and ax.employee_id=emp.id),0)+public.shift_minutes(start_at,end_at)>coalesce(emp.max_monthly_minutes,emp.monthly_nominal_minutes) then raise exception 'HARD_CONSTRAINT_MONTHLY_LIMIT'; end if;
    if coalesce((select sum(public.shift_minutes(sx.starts_at,sx.ends_at)) from public.assignments ax join public.shifts sx on sx.id=ax.shift_id where sx.plan_id=plan_id and ax.employee_id=emp.id and date_trunc('week',sx.shift_date::timestamp)=date_trunc('week',(a->>'date')::date::timestamp)),0)+public.shift_minutes(start_at,end_at)>emp.max_weekly_minutes then raise exception 'HARD_CONSTRAINT_WEEKLY_LIMIT'; end if;
    select s.id into shift_id from public.shifts s where s.plan_id=plan_id and s.location_id=loc.id and s.shift_date=(a->>'date')::date and s.shift_code=a->>'shiftCode';
    if shift_id is null then insert into public.shifts(plan_id,location_id,shift_date,shift_code,starts_at,ends_at,status) values(plan_id,loc.id,(a->>'date')::date,a->>'shiftCode',start_at,end_at,'PLANNED') returning id into shift_id; end if;
    insert into public.assignments(shift_id,employee_id,assigned_role,assigned_capability,cost,explanation)
    values(shift_id,emp.id,(a->>'role')::public.employee_role,nullif(a->>'function',''),round(emp.hourly_rate*public.shift_minutes(start_at,end_at)/60,2),jsonb_build_object('engine','ALPHA_13_GA','runId',r.id,'slotId',a->>'slotId'));
    total_cost:=total_cost+round(emp.hourly_rate*public.shift_minutes(start_at,end_at)/60,2); assignment_count:=assignment_count+1;
  end loop;

  for c in select value from jsonb_array_elements(p_candidates) loop
    insert into public.optimization_candidates(run_id,rank,score,hard_violations,metrics,assignments,selected)
    values(r.id,(c->>'rank')::integer,(c->>'score')::numeric,coalesce((c->>'hardViolations')::integer,0),coalesce(c->'metrics','{}'::jsonb),coalesce(c->'assignments','[]'::jsonb),(c->>'rank')::integer=1);
  end loop;
  for c in select value from jsonb_array_elements(coalesce(best->'unfilled','[]'::jsonb)) loop
    insert into public.plan_issues(plan_id,issue_type,severity,role,capability,required_count,assigned_count,message)
    values(plan_id,case when nullif(c->>'function','') is null then 'SHORTAGE' else 'CAPABILITY_MISSING' end,'CRITICAL',(c->>'role')::public.employee_role,nullif(c->>'function',''),1,0,
      'Nierozwiązywalny brak: '||(c->>'role')||coalesce(' / '||nullif(c->>'function',''),'')||' • '||(c->>'date')||' • '||(c->>'shiftCode'));
    issue_count:=issue_count+1;
  end loop;
  update public.plans set status='READY',total_cost=total_cost,generated_at=now() where id=plan_id;
  update public.optimization_runs set status=case when issue_count=0 then 'SUCCEEDED' else 'INFEASIBLE' end,finished_at=now(),
    result_summary=jsonb_build_object('planId',plan_id,'score',best->'score','assignments',assignment_count,'unfilled',issue_count,'alternatives',jsonb_array_length(p_candidates),'cost',total_cost)
    where id=r.id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data) values(auth.uid(),'optimization_run',r.id::text,'COMMIT',(select result_summary from public.optimization_runs where id=r.id));
  return jsonb_build_object('plan_id',plan_id,'run_id',r.id,'status',case when issue_count=0 then 'READY' else 'READY_WITH_EXCEPTIONS' end,'assignments',assignment_count,'issues',issue_count,'total_cost',total_cost,'score',best->'score','alternatives',jsonb_array_length(p_candidates));
exception when others then
  if r.id is not null then update public.optimization_runs set status='FAILED',finished_at=now(),failure_message=sqlerrm where id=r.id; end if;
  raise;
end $$;

revoke all on function public.optimizer_prepare(date,text,text,integer) from public,anon;
revoke all on function public.optimizer_commit(uuid,text,jsonb) from public,anon;
grant execute on function public.optimizer_prepare(date,text,text,integer) to authenticated;
grant execute on function public.optimizer_commit(uuid,text,jsonb) to authenticated;
