-- Audited employee shift-swap board.  Every acceptance is revalidated against
-- the same role, location, duty, availability and rest invariants before a
-- manager can make it operational.

create table public.shift_swap_requests_v2 (
  id uuid primary key default gen_random_uuid(),
  month date not null check(date_trunc('month',month)::date=month),
  matrix_version_id uuid not null references public.matrix_versions(id),
  original_assignment_id uuid not null references public.plan_assignments_v2(id),
  role_id uuid not null references public.matrix_roles_v2(id),
  proposer_employee_id uuid not null references public.employees(id),
  target_employee_id uuid references public.employees(id),
  accepted_by_employee_id uuid references public.employees(id),
  message text,
  status text not null default 'OPEN' check(status in (
    'OPEN','EMPLOYEE_ACCEPTED','EMPLOYEE_REJECTED','LEADER_APPROVED',
    'LEADER_REJECTED','CANCELLED'
  )),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  employee_decided_at timestamptz,
  leader_decided_by uuid references auth.users(id),
  leader_decided_at timestamptz,
  leader_reason text,
  replacement_id uuid references public.operational_assignment_replacements_v2(id),
  check(target_employee_id is null or target_employee_id<>proposer_employee_id),
  check(accepted_by_employee_id is null
    or accepted_by_employee_id<>proposer_employee_id)
);

create unique index shift_swap_one_active_per_assignment_v2
  on public.shift_swap_requests_v2(original_assignment_id)
  where status in ('OPEN','EMPLOYEE_ACCEPTED');
create index shift_swap_board_month_role_v2
  on public.shift_swap_requests_v2(month,role_id,status,created_at desc);

create table public.shift_swap_history_v2 (
  id bigint generated always as identity primary key,
  request_id uuid not null references public.shift_swap_requests_v2(id),
  actor_id uuid not null references auth.users(id),
  action text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.shift_swap_requests_v2 enable row level security;
alter table public.shift_swap_history_v2 enable row level security;
create policy shift_swap_visible_participants_v2
on public.shift_swap_requests_v2 for select to authenticated
using (
  proposer_employee_id in (select employee.id from public.employees employee
    where employee.auth_user_id=(select auth.uid()))
  or target_employee_id in (select employee.id from public.employees employee
    where employee.auth_user_id=(select auth.uid()))
  or accepted_by_employee_id in (select employee.id from public.employees employee
    where employee.auth_user_id=(select auth.uid()))
  or status='OPEN'
  or (select public.can_manage_plans())
);
create policy shift_swap_history_visible_participants_v2
on public.shift_swap_history_v2 for select to authenticated
using(exists(select 1 from public.shift_swap_requests_v2 request
  where request.id=request_id));

revoke all on public.shift_swap_requests_v2,public.shift_swap_history_v2
  from public,anon,authenticated;
grant select on public.shift_swap_requests_v2,public.shift_swap_history_v2
  to authenticated;
grant all on public.shift_swap_requests_v2,public.shift_swap_history_v2
  to service_role;

create function solver_private.assignment_is_currently_published_v2(
  p_assignment_id uuid
) returns boolean language sql stable security definer set search_path=''
as $$
  select exists(
    select 1 from public.plan_assignments_v2 assignment
    where assignment.id=p_assignment_id and (
      exists(select 1 from public.published_role_schedules_v2 publication
        where publication.variant_id=assignment.variant_id
          and publication.status='PUBLISHED')
      or exists(select 1 from public.published_schedule_variants_v2 link
        join public.published_schedules_v2 schedule
          on schedule.id=link.schedule_id and schedule.status='PUBLISHED'
        where link.variant_id=assignment.variant_id)
    )
  );
$$;

create function solver_private.swap_candidate_reasons_uat_v2(
  p_request_id uuid,p_employee_id uuid
) returns text[] language plpgsql stable security definer set search_path=''
as $$
declare
  v_request public.shift_swap_requests_v2%rowtype;
  v_assignment public.plan_assignments_v2%rowtype;
  v_shift public.plan_shifts_v2%rowtype;
  v_profile public.matrix_employee_profiles_v2%rowtype;
  v_reasons text[]:='{}'::text[];
  v_minutes integer; v_month_minutes integer; v_week_minutes integer;
  v_rest integer;
begin
  select * into v_request from public.shift_swap_requests_v2 where id=p_request_id;
  if v_request.id is null then return array['SWAP_REQUEST_NOT_FOUND']; end if;
  select * into v_assignment from public.plan_assignments_v2
    where id=v_request.original_assignment_id;
  select * into v_shift from public.plan_shifts_v2 where id=v_assignment.shift_id;
  select * into v_profile from public.matrix_employee_profiles_v2 profile
  where profile.matrix_version_id=v_request.matrix_version_id
    and profile.employee_id=p_employee_id and profile.active
    and profile.archived_at is null;
  if v_profile.id is null then v_reasons:=array_append(v_reasons,'EMPLOYEE_NOT_ACTIVE'); end if;
  if p_employee_id=v_request.proposer_employee_id then
    v_reasons:=array_append(v_reasons,'CANNOT_SWAP_WITH_SELF');
  end if;
  if v_request.target_employee_id is not null
    and v_request.target_employee_id<>p_employee_id then
    v_reasons:=array_append(v_reasons,'NOT_REQUEST_TARGET');
  end if;
  if not solver_private.assignment_is_currently_published_v2(v_assignment.id) then
    v_reasons:=array_append(v_reasons,'ASSIGNMENT_NOT_PUBLISHED');
  end if;
  if v_shift.starts_at<=now() then v_reasons:=array_append(v_reasons,'SHIFT_ALREADY_STARTED'); end if;
  if not exists(select 1 from public.matrix_employee_roles_v2 role_grant
      where role_grant.matrix_version_id=v_request.matrix_version_id
        and role_grant.employee_id=p_employee_id and role_grant.role_id=v_assignment.role_id
        and role_grant.active
        and (role_grant.valid_from is null or role_grant.valid_from<=v_shift.shift_date)
        and (role_grant.valid_to is null or role_grant.valid_to>=v_shift.shift_date)) then
    v_reasons:=array_append(v_reasons,'ROLE_REQUIRED');
  end if;
  if not exists(select 1 from public.matrix_employee_locations_v2 location_grant
      where location_grant.matrix_version_id=v_request.matrix_version_id
        and location_grant.employee_id=p_employee_id
        and location_grant.location_id=v_shift.location_id
        and location_grant.active and location_grant.standard_allowed
        and (location_grant.valid_from is null or location_grant.valid_from<=v_shift.shift_date)
        and (location_grant.valid_to is null or location_grant.valid_to>=v_shift.shift_date)) then
    v_reasons:=array_append(v_reasons,'LOCATION_NOT_ALLOWED');
  end if;
  if exists(select 1 from public.plan_assignment_duties_v2 required_duty
      where required_duty.assignment_id=v_assignment.id and not exists(
        select 1 from public.matrix_employee_duties_v2 employee_duty
        where employee_duty.matrix_version_id=v_request.matrix_version_id
          and employee_duty.employee_id=p_employee_id
          and employee_duty.duty_id=required_duty.duty_id and employee_duty.active
          and (employee_duty.role_id is null or employee_duty.role_id=v_assignment.role_id)
          and (employee_duty.location_id is null or employee_duty.location_id=v_shift.location_id)
          and (employee_duty.valid_from is null or employee_duty.valid_from<=v_shift.shift_date)
          and (employee_duty.valid_to is null or employee_duty.valid_to>=v_shift.shift_date)
      )) then v_reasons:=array_append(v_reasons,'DUTY_REQUIRED'); end if;
  if exists(select 1 from public.employee_time_constraints_v2 constraint_row
      where constraint_row.employee_id=p_employee_id and constraint_row.status='ACTIVE'
        and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
        and constraint_row.time_range && tstzrange(v_shift.starts_at,v_shift.ends_at,'[)')) then
    v_reasons:=array_append(v_reasons,'HARD_UNAVAILABLE');
  end if;
  if exists(select 1 from public.published_standby_assignments_v2 standby
      where standby.employee_id=p_employee_id and standby.standby_date=v_shift.shift_date
        and standby.status in ('PLANNED','ACTIVATED')) then
    v_reasons:=array_append(v_reasons,'STANDBY_CONFLICT');
  end if;
  if coalesce(v_profile.no_weekends,false)
    and extract(isodow from v_shift.shift_date) in (6,7) then
    v_reasons:=array_append(v_reasons,'NO_WEEKENDS');
  end if;
  if v_profile.employment_start is not null and v_profile.employment_start>v_shift.shift_date
    or v_profile.employment_end is not null and v_profile.employment_end<v_shift.shift_date then
    v_reasons:=array_append(v_reasons,'OUTSIDE_EMPLOYMENT');
  end if;
  if coalesce(v_profile.only_morning,false) and extract(hour from v_shift.starts_at at time zone
      coalesce((select location.timezone from public.matrix_locations_v2 location
        where location.id=v_shift.location_id),'Europe/Warsaw'))>=15 then
    v_reasons:=array_append(v_reasons,'ONLY_MORNING');
  end if;
  if coalesce(v_profile.only_evening,false) and extract(hour from v_shift.starts_at at time zone
      coalesce((select location.timezone from public.matrix_locations_v2 location
        where location.id=v_shift.location_id),'Europe/Warsaw'))<15 then
    v_reasons:=array_append(v_reasons,'ONLY_EVENING');
  end if;

  v_rest:=coalesce(v_profile.minimum_rest_minutes,0);
  if exists(
    select 1 from public.plan_assignments_v2 other_assignment
    join public.plan_shifts_v2 other_shift on other_shift.id=other_assignment.shift_id
    where other_assignment.employee_id=p_employee_id
      and other_assignment.id<>v_assignment.id
      and solver_private.assignment_is_currently_published_v2(other_assignment.id)
      and other_shift.ends_at+(v_rest*interval '1 minute')>v_shift.starts_at
      and v_shift.ends_at+(v_rest*interval '1 minute')>other_shift.starts_at
  ) or exists(
    select 1 from public.operational_assignment_replacements_v2 replacement
    join public.plan_assignments_v2 original on original.id=replacement.original_assignment_id
    join public.plan_shifts_v2 other_shift on other_shift.id=original.shift_id
    where replacement.replacement_employee_id=p_employee_id and replacement.status='ACTIVE'
      and other_shift.ends_at+(v_rest*interval '1 minute')>v_shift.starts_at
      and v_shift.ends_at+(v_rest*interval '1 minute')>other_shift.starts_at
  ) then v_reasons:=array_append(v_reasons,'SHIFT_OR_REST_CONFLICT'); end if;

  v_minutes:=greatest(0,round(extract(epoch from(v_shift.ends_at-v_shift.starts_at))/60)::integer);
  select coalesce(sum(round(extract(epoch from(other_shift.ends_at-other_shift.starts_at))/60)),0)::integer
  into v_month_minutes
  from public.plan_assignments_v2 other_assignment
  join public.plan_shifts_v2 other_shift on other_shift.id=other_assignment.shift_id
  where other_assignment.employee_id=p_employee_id
    and other_shift.shift_date>=v_request.month
    and other_shift.shift_date<(v_request.month+interval '1 month')::date
    and solver_private.assignment_is_currently_published_v2(other_assignment.id);
  select coalesce(sum(round(extract(epoch from(other_shift.ends_at-other_shift.starts_at))/60)),0)::integer
  into v_week_minutes
  from public.plan_assignments_v2 other_assignment
  join public.plan_shifts_v2 other_shift on other_shift.id=other_assignment.shift_id
  where other_assignment.employee_id=p_employee_id
    and date_trunc('week',other_shift.shift_date)=date_trunc('week',v_shift.shift_date)
    and solver_private.assignment_is_currently_published_v2(other_assignment.id);
  if v_profile.maximum_monthly_minutes>0
    and v_month_minutes+v_minutes>v_profile.maximum_monthly_minutes then
    v_reasons:=array_append(v_reasons,'MAXIMUM_MONTHLY_HOURS');
  end if;
  if v_profile.maximum_weekly_minutes>0
    and v_week_minutes+v_minutes>v_profile.maximum_weekly_minutes then
    v_reasons:=array_append(v_reasons,'MAXIMUM_WEEKLY_HOURS');
  end if;
  return v_reasons;
end;
$$;

create function public.shift_swap_request_create_uat_v2(
  p_assignment_id uuid,p_target_employee_id uuid default null,p_message text default null
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_employee uuid; v_assignment public.plan_assignments_v2%rowtype;
  v_shift public.plan_shifts_v2%rowtype; v_matrix uuid; v_id uuid:=gen_random_uuid();
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select employee.id into v_employee from public.employees employee
  where employee.auth_user_id=v_actor and employee.active and employee.archived_at is null
  order by employee.employee_no limit 1;
  select * into v_assignment from public.plan_assignments_v2 where id=p_assignment_id;
  if v_assignment.id is null then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
  if v_assignment.employee_id<>v_employee then raise exception 'NOT_OWN_ASSIGNMENT'; end if;
  if not solver_private.assignment_is_currently_published_v2(v_assignment.id)
    then raise exception 'ASSIGNMENT_NOT_PUBLISHED'; end if;
  select * into v_shift from public.plan_shifts_v2 where id=v_assignment.shift_id;
  if v_shift.starts_at<=now() then raise exception 'SHIFT_ALREADY_STARTED'; end if;
  select run.matrix_version_id into v_matrix from public.plan_variants_v2 variant
  join public.optimization_runs_v2 run on run.id=variant.run_id
  where variant.id=v_assignment.variant_id;
  if p_target_employee_id is not null and cardinality(
      solver_private.swap_candidate_reasons_uat_v2(v_id,p_target_employee_id))>0 then
    -- Candidate validation runs after inserting the request below; this guard
    -- is intentionally completed after the insert.
    null;
  end if;
  insert into public.shift_swap_requests_v2(
    id,month,matrix_version_id,original_assignment_id,role_id,
    proposer_employee_id,target_employee_id,message,created_by
  ) values(v_id,date_trunc('month',v_shift.shift_date)::date,v_matrix,
    v_assignment.id,v_assignment.role_id,v_employee,p_target_employee_id,
    nullif(trim(p_message),''),v_actor);
  if p_target_employee_id is not null and cardinality(
      solver_private.swap_candidate_reasons_uat_v2(v_id,p_target_employee_id))>0 then
    raise exception 'SWAP_TARGET_NOT_ELIGIBLE:%',array_to_string(
      solver_private.swap_candidate_reasons_uat_v2(v_id,p_target_employee_id),',');
  end if;
  insert into public.shift_swap_history_v2(request_id,actor_id,action,details)
  values(v_id,v_actor,'CREATED',jsonb_build_object('targetEmployeeId',p_target_employee_id));
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'shift_swap_v2',v_id::text,'CREATE',jsonb_build_object(
    'assignmentId',v_assignment.id,'targetEmployeeId',p_target_employee_id));
  if p_target_employee_id is not null then
    insert into public.notifications(recipient_id,title,body)
    select target.auth_user_id,'Propozycja zamiany zmiany',
      'Otrzymujesz propozycję przejęcia zmiany '||v_shift.shift_date::text||'.'
    from public.employees target where target.id=p_target_employee_id
      and target.auth_user_id is not null;
  end if;
  return v_id;
end;
$$;

create function public.shift_swap_employee_decide_uat_v2(
  p_request_id uuid,p_decision text
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_employee uuid; v_request public.shift_swap_requests_v2%rowtype;
  v_decision text:=upper(trim(coalesce(p_decision,''))); v_reasons text[];
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if v_decision not in ('ACCEPT','REJECT') then raise exception 'INVALID_SWAP_DECISION'; end if;
  select employee.id into v_employee from public.employees employee
  where employee.auth_user_id=v_actor and employee.active and employee.archived_at is null
  order by employee.employee_no limit 1;
  select * into v_request from public.shift_swap_requests_v2 where id=p_request_id for update;
  if v_request.id is null then raise exception 'SWAP_REQUEST_NOT_FOUND'; end if;
  if v_request.status<>'OPEN' then raise exception 'SWAP_REQUEST_NOT_OPEN'; end if;
  if v_request.target_employee_id is not null and v_request.target_employee_id<>v_employee
    then raise exception 'NOT_REQUEST_TARGET'; end if;
  if v_decision='REJECT' and v_request.target_employee_id is null
    then raise exception 'OPEN_BOARD_REQUEST_CANNOT_BE_REJECTED'; end if;
  if v_decision='ACCEPT' then
    v_reasons:=solver_private.swap_candidate_reasons_uat_v2(p_request_id,v_employee);
    if cardinality(v_reasons)>0 then raise exception 'SWAP_CANDIDATE_NOT_ELIGIBLE:%',
      array_to_string(v_reasons,','); end if;
    update public.shift_swap_requests_v2 set status='EMPLOYEE_ACCEPTED',
      accepted_by_employee_id=v_employee,employee_decided_at=now()
    where id=p_request_id;
    insert into public.notifications(recipient_id,title,body)
    select distinct recipient.auth_user_id,'Zamiana czeka na akceptację',
      'Pracownicy uzgodnili zamianę. Sprawdź ją i zaakceptuj albo odrzuć.'
    from (
      select grant_row.auth_user_id from public.matrix_scope_grants_v2 grant_row
      join public.matrix_roles_v2 role on role.logical_id=grant_row.role_logical_id
      where grant_row.active and grant_row.app_role='ROLE_MANAGER'
        and role.id=v_request.role_id
      union
      select permission.auth_user_id from public.user_permissions permission
      where permission.app_role in ('OWNER','ADMIN')
    ) recipient where recipient.auth_user_id is not null;
  else
    update public.shift_swap_requests_v2 set status='EMPLOYEE_REJECTED',
      employee_decided_at=now() where id=p_request_id;
  end if;
  insert into public.shift_swap_history_v2(request_id,actor_id,action)
  values(p_request_id,v_actor,v_decision);
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'shift_swap_v2',p_request_id::text,v_decision,
    jsonb_build_object('employeeId',v_employee));
  return jsonb_build_object('id',p_request_id,'status',
    case when v_decision='ACCEPT' then 'EMPLOYEE_ACCEPTED' else 'EMPLOYEE_REJECTED' end);
end;
$$;

create function public.shift_swap_leader_decide_uat_v2(
  p_request_id uuid,p_decision text,p_reason text
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_request public.shift_swap_requests_v2%rowtype;
  v_decision text:=upper(trim(coalesce(p_decision,''))); v_reasons text[];
  v_replacement uuid;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  if v_decision not in ('APPROVE','REJECT') then raise exception 'INVALID_SWAP_DECISION'; end if;
  if length(trim(coalesce(p_reason,'')))<3 then raise exception 'SWAP_REASON_REQUIRED'; end if;
  select * into v_request from public.shift_swap_requests_v2 where id=p_request_id for update;
  if v_request.id is null then raise exception 'SWAP_REQUEST_NOT_FOUND'; end if;
  if v_request.status<>'EMPLOYEE_ACCEPTED' then raise exception 'SWAP_NOT_READY_FOR_LEADER'; end if;
  if v_decision='APPROVE' then
    v_reasons:=solver_private.swap_candidate_reasons_uat_v2(
      p_request_id,v_request.accepted_by_employee_id);
    if cardinality(v_reasons)>0 then raise exception 'SWAP_REVALIDATION_FAILED:%',
      array_to_string(v_reasons,','); end if;
    v_replacement:=gen_random_uuid();
    insert into public.operational_assignment_replacements_v2(
      id,month,original_assignment_id,replacement_employee_id,reason,created_by
    ) values(v_replacement,v_request.month,v_request.original_assignment_id,
      v_request.accepted_by_employee_id,'Zamiana: '||trim(p_reason),v_actor);
    update public.shift_swap_requests_v2 set status='LEADER_APPROVED',
      leader_decided_by=v_actor,leader_decided_at=now(),leader_reason=trim(p_reason),
      replacement_id=v_replacement where id=p_request_id;
  else
    update public.shift_swap_requests_v2 set status='LEADER_REJECTED',
      leader_decided_by=v_actor,leader_decided_at=now(),leader_reason=trim(p_reason)
    where id=p_request_id;
  end if;
  insert into public.shift_swap_history_v2(request_id,actor_id,action,details)
  values(p_request_id,v_actor,'LEADER_'||v_decision,
    jsonb_build_object('reason',trim(p_reason),'replacementId',v_replacement));
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'shift_swap_v2',p_request_id::text,'LEADER_'||v_decision,
    jsonb_build_object('reason',trim(p_reason),'replacementId',v_replacement));
  insert into public.notifications(recipient_id,title,body)
  select distinct employee.auth_user_id,'Decyzja lidera o zamianie',
    case when v_decision='APPROVE' then 'Zamiana została zaakceptowana i jest widoczna w grafiku.'
      else 'Zamiana została odrzucona: '||trim(p_reason) end
  from public.employees employee where employee.id in (
    v_request.proposer_employee_id,v_request.accepted_by_employee_id)
    and employee.auth_user_id is not null;
  return jsonb_build_object('id',p_request_id,'status','LEADER_'||
    case when v_decision='APPROVE' then 'APPROVED' else 'REJECTED' end,
    'replacementId',v_replacement);
end;
$$;

create function public.shift_swap_board_uat_v2(p_month date)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_employee uuid; v_month date:=date_trunc('month',p_month)::date;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select employee.id into v_employee from public.employees employee
  where employee.auth_user_id=v_actor and employee.active and employee.archived_at is null
  order by employee.employee_no limit 1;
  return jsonb_build_object(
    'employeeId',v_employee,'month',v_month,
    'requests',coalesce((select jsonb_agg(jsonb_build_object(
      'id',request.id,'status',request.status,'message',request.message,
      'assignmentId',assignment.id,'date',shift.shift_date,
      'startsAt',shift.starts_at,'endsAt',shift.ends_at,
      'locationName',location.name,'shiftName',template.name,
      'roleId',request.role_id,'roleName',role.name,
      'proposerEmployeeId',request.proposer_employee_id,
      'proposerName',proposer.first_name||' '||proposer.last_name,
      'targetEmployeeId',request.target_employee_id,
      'acceptedByEmployeeId',request.accepted_by_employee_id,
      'eligible',cardinality(solver_private.swap_candidate_reasons_uat_v2(
        request.id,v_employee))=0,
      'ineligibilityReasons',to_jsonb(solver_private.swap_candidate_reasons_uat_v2(
        request.id,v_employee)),
      'isMine',request.proposer_employee_id=v_employee,
      'requiresLeaderDecision',request.status='EMPLOYEE_ACCEPTED'
    ) order by shift.starts_at,request.created_at)
      from public.shift_swap_requests_v2 request
      join public.plan_assignments_v2 assignment on assignment.id=request.original_assignment_id
      join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
      join public.matrix_locations_v2 location on location.id=shift.location_id
      join public.matrix_shift_templates_v2 template on template.id=shift.shift_template_id
      join public.matrix_roles_v2 role on role.id=request.role_id
      join public.matrix_employee_profiles_v2 proposer
        on proposer.matrix_version_id=request.matrix_version_id
        and proposer.employee_id=request.proposer_employee_id
      where request.month=v_month and (
        request.proposer_employee_id=v_employee
        or request.target_employee_id=v_employee
        or request.accepted_by_employee_id=v_employee
        or (request.status='OPEN' and cardinality(
          solver_private.swap_candidate_reasons_uat_v2(request.id,v_employee))=0)
        or public.can_manage_plans()
      )),'[]'::jsonb)
  );
end;
$$;

create function public.published_company_calendar_uat_v2(p_month date)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_month date:=date_trunc('month',p_month)::date; v_status jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  v_status:=public.schedule_publication_status_uat_v2(v_month);
  if coalesce((v_status->>'conflict')::boolean,false) then
    raise exception 'SCHEDULE_PUBLICATION_CONFLICT_REQUIRES_OWNER_RESOLUTION';
  end if;
  return jsonb_build_object('month',v_month,'publication',v_status,
    'assignments',coalesce((select jsonb_agg(jsonb_build_object(
      'id',assignment.id,'date',shift.shift_date,'startsAt',shift.starts_at,
      'endsAt',shift.ends_at,'locationId',shift.location_id,
      'locationName',location.name,'shiftName',template.name,
      'roleId',assignment.role_id,'roleName',role.name,
      'employeeId',coalesce(replacement.replacement_employee_id,assignment.employee_id),
      'employeeName',coalesce(replacement_profile.first_name||' '||replacement_profile.last_name,
        profile.first_name||' '||profile.last_name),
      'employeeNo',coalesce(replacement_profile.employee_no,profile.employee_no),
      'isSwap',replacement.id is not null,'swapAuditId',swap_request.id
    ) order by shift.starts_at,location.name,role.name,profile.last_name)
      from public.plan_assignments_v2 assignment
      join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
      join public.matrix_locations_v2 location on location.id=shift.location_id
      join public.matrix_shift_templates_v2 template on template.id=shift.shift_template_id
      join public.matrix_roles_v2 role on role.id=assignment.role_id
      join public.matrix_employee_profiles_v2 profile
        on profile.matrix_version_id=role.matrix_version_id
        and profile.employee_id=assignment.employee_id
      left join public.operational_assignment_replacements_v2 replacement
        on replacement.original_assignment_id=assignment.id and replacement.status='ACTIVE'
      left join public.matrix_employee_profiles_v2 replacement_profile
        on replacement_profile.matrix_version_id=role.matrix_version_id
        and replacement_profile.employee_id=replacement.replacement_employee_id
      left join public.shift_swap_requests_v2 swap_request
        on swap_request.replacement_id=replacement.id
      where shift.shift_date>=v_month
        and shift.shift_date<(v_month+interval '1 month')::date
        and solver_private.assignment_is_currently_published_v2(assignment.id)
    ),'[]'::jsonb));
end;
$$;

revoke all on function solver_private.assignment_is_currently_published_v2(uuid),
  solver_private.swap_candidate_reasons_uat_v2(uuid,uuid)
  from public,anon,authenticated;
grant execute on function solver_private.assignment_is_currently_published_v2(uuid),
  solver_private.swap_candidate_reasons_uat_v2(uuid,uuid) to service_role;
revoke all on function public.shift_swap_request_create_uat_v2(uuid,uuid,text),
  public.shift_swap_employee_decide_uat_v2(uuid,text),
  public.shift_swap_leader_decide_uat_v2(uuid,text,text),
  public.shift_swap_board_uat_v2(date),public.published_company_calendar_uat_v2(date)
  from public,anon,authenticated;
grant execute on function public.shift_swap_request_create_uat_v2(uuid,uuid,text),
  public.shift_swap_employee_decide_uat_v2(uuid,text),
  public.shift_swap_leader_decide_uat_v2(uuid,text,text),
  public.shift_swap_board_uat_v2(date),public.published_company_calendar_uat_v2(date)
  to authenticated;

notify pgrst,'reload schema';
