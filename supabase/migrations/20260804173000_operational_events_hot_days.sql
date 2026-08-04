-- Matrix v2 operational calendar: business events, extra demand and HOT DAY
-- availability review.  These records are deliberately versioned against the
-- published Matrix and become immutable input to every later solver snapshot.

create table public.workforce_calendar_events_v2 (
  id uuid primary key default gen_random_uuid(),
  matrix_version_id uuid not null references public.matrix_versions(id),
  month date not null check(date_trunc('month',month)::date=month),
  event_date date not null,
  location_id uuid,
  event_kind text not null check(event_kind in ('EVENT','HOT_DAY')),
  title text not null check(length(trim(title)) between 3 and 160),
  description text,
  status text not null default 'ACTIVE' check(status in ('ACTIVE','CANCELLED')),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  cancelled_by uuid references auth.users(id),
  cancelled_at timestamptz,
  check(event_date>=month and event_date<(month+interval '1 month')::date),
  check((status='ACTIVE' and cancelled_at is null)
    or (status='CANCELLED' and cancelled_at is not null)),
  foreign key(matrix_version_id,location_id)
    references public.matrix_locations_v2(matrix_version_id,id)
);

create table public.workforce_event_demand_v2 (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.workforce_calendar_events_v2(id)
    on delete cascade,
  matrix_version_id uuid not null references public.matrix_versions(id),
  shift_template_id uuid not null,
  role_id uuid not null,
  duty_id uuid,
  additional_count integer not null check(additional_count between 1 and 500),
  created_at timestamptz not null default now(),
  unique nulls not distinct(event_id,shift_template_id,role_id,duty_id),
  foreign key(matrix_version_id,shift_template_id)
    references public.matrix_shift_templates_v2(matrix_version_id,id),
  foreign key(matrix_version_id,role_id)
    references public.matrix_roles_v2(matrix_version_id,id),
  foreign key(matrix_version_id,duty_id)
    references public.matrix_duties_v2(matrix_version_id,id)
);

create table public.workforce_hot_day_limits_v2 (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.workforce_calendar_events_v2(id)
    on delete cascade,
  matrix_version_id uuid not null references public.matrix_versions(id),
  role_id uuid not null,
  maximum_hard_unavailable integer not null
    check(maximum_hard_unavailable between 0 and 500),
  created_at timestamptz not null default now(),
  unique(event_id,role_id),
  foreign key(matrix_version_id,role_id)
    references public.matrix_roles_v2(matrix_version_id,id)
);

create table public.availability_exception_reviews_v2 (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id),
  matrix_version_id uuid not null references public.matrix_versions(id),
  hot_day_event_id uuid not null references public.workforce_calendar_events_v2(id),
  role_id uuid not null,
  work_date date not null,
  requested_range tstzrange not null,
  note text,
  status text not null default 'PENDING'
    check(status in ('PENDING','APPROVED','REJECTED','CANCELLED')),
  requested_by uuid not null references auth.users(id),
  requested_at timestamptz not null default now(),
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  review_reason text,
  constraint_id uuid references public.employee_time_constraints_v2(id),
  check(not isempty(requested_range)),
  check((status='PENDING' and reviewed_at is null)
    or (status<>'PENDING' and reviewed_at is not null))
);

create unique index availability_exception_one_pending_v2
  on public.availability_exception_reviews_v2(employee_id,work_date,role_id)
  where status='PENDING';
create index workforce_events_month_date_v2
  on public.workforce_calendar_events_v2(month,event_date,status);
create index availability_exception_role_date_v2
  on public.availability_exception_reviews_v2(role_id,work_date,status);

alter table public.workforce_calendar_events_v2 enable row level security;
alter table public.workforce_event_demand_v2 enable row level security;
alter table public.workforce_hot_day_limits_v2 enable row level security;
alter table public.availability_exception_reviews_v2 enable row level security;

create policy workforce_events_authenticated_read_v2
on public.workforce_calendar_events_v2 for select to authenticated using(true);
create policy workforce_event_demand_authenticated_read_v2
on public.workforce_event_demand_v2 for select to authenticated using(true);
create policy workforce_hot_limits_authenticated_read_v2
on public.workforce_hot_day_limits_v2 for select to authenticated using(true);
create policy availability_exception_self_or_manager_read_v2
on public.availability_exception_reviews_v2 for select to authenticated
using (
  employee_id in (select employee.id from public.employees employee
    where employee.auth_user_id=(select auth.uid()))
  or (select public.can_manage_plans())
  or (select public.has_app_role('HR_FINANCE'))
);

revoke all on public.workforce_calendar_events_v2,
  public.workforce_event_demand_v2,public.workforce_hot_day_limits_v2,
  public.availability_exception_reviews_v2 from public,anon,authenticated;
grant select on public.workforce_calendar_events_v2,
  public.workforce_event_demand_v2,public.workforce_hot_day_limits_v2,
  public.availability_exception_reviews_v2 to authenticated;
grant all on public.workforce_calendar_events_v2,
  public.workforce_event_demand_v2,public.workforce_hot_day_limits_v2,
  public.availability_exception_reviews_v2 to service_role;

-- Preserve the canonical Matrix demand resolver as the base calculation and
-- layer dated event demand over it.  The snapshot builder already calls this
-- resolver for capacity checks, demand payload and slots, so event staffing is
-- a real solver requirement rather than a visual annotation.
alter function solver_private.resolved_demand_v2(date,uuid,uuid,uuid)
  rename to resolved_matrix_demand_v2;

create function solver_private.resolved_demand_v2(
  p_month date,
  p_matrix_version_id uuid,
  p_scenario_id uuid,
  p_scope_role_id uuid default null
) returns table(
  demand_id uuid,work_date date,shift_template_id uuid,location_id uuid,
  role_id uuid,duty_ids uuid[],required_count integer,starts_at timestamptz,
  ends_at timestamptz,duration_minutes integer
)
language sql stable security definer set search_path=''
as $$
  select base.demand_id,base.work_date,base.shift_template_id,base.location_id,
    base.role_id,base.duty_ids,base.required_count,base.starts_at,base.ends_at,
    base.duration_minutes
  from solver_private.resolved_matrix_demand_v2(
    p_month,p_matrix_version_id,p_scenario_id,p_scope_role_id
  ) base
  union all
  select public.matrix_v2_stable_uuid(
      'EVENT_DEMAND_V2:'||demand.id::text||':'||event.event_date::text
    ),event.event_date,shift.id,shift.location_id,demand.role_id,
    case when demand.duty_id is null then '{}'::uuid[]
      else array[demand.duty_id]::uuid[] end,
    demand.additional_count,
    ((event.event_date+shift.starts_at) at time zone location.timezone),
    (((event.event_date+case when shift.ends_next_day then 1 else 0 end)
      +shift.ends_at) at time zone location.timezone),
    greatest(0,round(extract(epoch from (
      (((event.event_date+case when shift.ends_next_day then 1 else 0 end)
        +shift.ends_at) at time zone location.timezone)
      -((event.event_date+shift.starts_at) at time zone location.timezone)
    ))/60)::integer)
  from public.workforce_event_demand_v2 demand
  join public.workforce_calendar_events_v2 event on event.id=demand.event_id
    and event.status='ACTIVE' and event.event_kind='EVENT'
  join public.matrix_shift_templates_v2 shift
    on shift.id=demand.shift_template_id and shift.active
  join public.matrix_locations_v2 location
    on location.id=shift.location_id and location.active
  where event.matrix_version_id=p_matrix_version_id
    and event.month=date_trunc('month',p_month)::date
    and demand.matrix_version_id=p_matrix_version_id
    and (p_scope_role_id is null or demand.role_id=p_scope_role_id)
  order by starts_at,location_id,role_id,duty_ids;
$$;

create function public.workforce_calendar_event_save_uat_v2(
  p_event_id uuid,
  p_month date,
  p_event_date date,
  p_event_kind text,
  p_title text,
  p_description text,
  p_location_id uuid,
  p_demands jsonb default '[]'::jsonb,
  p_hot_limits jsonb default '[]'::jsonb
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid:=auth.uid();
  v_matrix uuid;
  v_id uuid:=coalesce(p_event_id,gen_random_uuid());
  v_kind text:=upper(trim(coalesce(p_event_kind,'')));
  v_item jsonb;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  if p_month is null or p_event_date is null
    or p_event_date<date_trunc('month',p_month)::date
    or p_event_date>=(date_trunc('month',p_month)+interval '1 month')::date then
    raise exception 'EVENT_DATE_OUTSIDE_MONTH';
  end if;
  if v_kind not in ('EVENT','HOT_DAY') then raise exception 'INVALID_EVENT_KIND'; end if;
  if length(trim(coalesce(p_title,'')))<3 then raise exception 'EVENT_TITLE_REQUIRED'; end if;
  select matrix.id into v_matrix from public.matrix_versions matrix
  where matrix.status='ACTIVE' and matrix.schema_version>=2
    and matrix.effective_from<=p_event_date
    and (matrix.effective_to is null or matrix.effective_to>=p_event_date)
  order by matrix.effective_from desc,matrix.version desc limit 1;
  if v_matrix is null then raise exception 'MATRIX_V2_FOR_MONTH_NOT_FOUND'; end if;

  insert into public.workforce_calendar_events_v2(
    id,matrix_version_id,month,event_date,location_id,event_kind,title,
    description,created_by
  ) values(v_id,v_matrix,date_trunc('month',p_month)::date,p_event_date,
    p_location_id,v_kind,trim(p_title),nullif(trim(p_description),''),v_actor)
  on conflict(id) do update set event_date=excluded.event_date,
    location_id=excluded.location_id,event_kind=excluded.event_kind,
    title=excluded.title,description=excluded.description,updated_at=now();

  delete from public.workforce_event_demand_v2 where event_id=v_id;
  delete from public.workforce_hot_day_limits_v2 where event_id=v_id;
  for v_item in select value from jsonb_array_elements(coalesce(p_demands,'[]'::jsonb)) loop
    if v_kind<>'EVENT' then raise exception 'DEMAND_REQUIRES_EVENT'; end if;
    insert into public.workforce_event_demand_v2(
      event_id,matrix_version_id,shift_template_id,role_id,duty_id,additional_count
    ) values(v_id,v_matrix,(v_item->>'shiftTemplateId')::uuid,
      (v_item->>'roleId')::uuid,nullif(v_item->>'dutyId','')::uuid,
      (v_item->>'additionalCount')::integer);
  end loop;
  for v_item in select value from jsonb_array_elements(coalesce(p_hot_limits,'[]'::jsonb)) loop
    if v_kind<>'HOT_DAY' then raise exception 'HOT_LIMIT_REQUIRES_HOT_DAY'; end if;
    insert into public.workforce_hot_day_limits_v2(
      event_id,matrix_version_id,role_id,maximum_hard_unavailable
    ) values(v_id,v_matrix,(v_item->>'roleId')::uuid,
      (v_item->>'maximumHardUnavailable')::integer);
  end loop;
  if v_kind='EVENT' and not exists(select 1 from public.workforce_event_demand_v2
      where event_id=v_id) then raise exception 'EVENT_DEMAND_REQUIRED'; end if;
  if v_kind='HOT_DAY' and not exists(select 1 from public.workforce_hot_day_limits_v2
      where event_id=v_id) then raise exception 'HOT_DAY_LIMIT_REQUIRED'; end if;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'workforce_calendar_event_v2',v_id::text,
    case when p_event_id is null then 'CREATE' else 'UPDATE' end,
    jsonb_build_object('month',date_trunc('month',p_month)::date,
      'date',p_event_date,'kind',v_kind,'title',trim(p_title),
      'demands',coalesce(p_demands,'[]'::jsonb),
      'hotLimits',coalesce(p_hot_limits,'[]'::jsonb)));
  return jsonb_build_object('id',v_id,'saved',true);
end;
$$;

create function public.workforce_calendar_context_uat_v2(p_month date)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_month date:=date_trunc('month',p_month)::date; v_result jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select jsonb_build_object(
    'month',v_month,
    'events',coalesce((select jsonb_agg(jsonb_build_object(
      'id',event.id,'date',event.event_date,'kind',event.event_kind,
      'title',event.title,'description',event.description,
      'locationId',event.location_id,'locationName',location.name,
      'demands',coalesce((select jsonb_agg(jsonb_build_object(
        'id',demand.id,'shiftTemplateId',demand.shift_template_id,
        'shiftName',shift.name,'roleId',demand.role_id,'roleName',role.name,
        'dutyId',demand.duty_id,'additionalCount',demand.additional_count
      ) order by shift.sort_order,role.sort_order) from public.workforce_event_demand_v2 demand
        join public.matrix_shift_templates_v2 shift on shift.id=demand.shift_template_id
        join public.matrix_roles_v2 role on role.id=demand.role_id
        where demand.event_id=event.id),'[]'::jsonb),
      'hotLimits',coalesce((select jsonb_agg(jsonb_build_object(
        'roleId',hot.role_id,'roleName',role.name,
        'maximumHardUnavailable',hot.maximum_hard_unavailable
      ) order by role.sort_order) from public.workforce_hot_day_limits_v2 hot
        join public.matrix_roles_v2 role on role.id=hot.role_id
        where hot.event_id=event.id),'[]'::jsonb)
    ) order by event.event_date,event.title)
      from public.workforce_calendar_events_v2 event
      left join public.matrix_locations_v2 location on location.id=event.location_id
      where event.month=v_month and event.status='ACTIVE'),'[]'::jsonb),
    'pendingReviews',coalesce((select jsonb_agg(jsonb_build_object(
      'id',review.id,'employeeId',review.employee_id,
      'employeeName',profile.first_name||' '||profile.last_name,
      'employeeNo',profile.employee_no,'date',review.work_date,
      'roleId',review.role_id,'roleName',role.name,'status',review.status,
      'note',review.note,'requestedAt',review.requested_at
    ) order by review.work_date,profile.last_name,profile.first_name)
      from public.availability_exception_reviews_v2 review
      join public.matrix_employee_profiles_v2 profile
        on profile.matrix_version_id=review.matrix_version_id
        and profile.employee_id=review.employee_id
      join public.matrix_roles_v2 role on role.id=review.role_id
      where review.work_date>=v_month
        and review.work_date<(v_month+interval '1 month')::date
        and (review.requested_by=auth.uid() or public.can_manage_plans())
        and review.status='PENDING'),'[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

create function public.employee_availability_days_save_uat_v3(
  p_dates date[],p_kind text,p_all_day boolean default true,
  p_local_start time default null,p_local_end time default null,
  p_preferred_location_id uuid default null,p_note text default null
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid:=auth.uid(); v_employee uuid; v_day date; v_kind text;
  v_matrix uuid; v_timezone text; v_role uuid; v_event uuid; v_limit integer;
  v_current integer; v_pending integer:=0; v_saved integer:=0;
  v_start timestamptz; v_end timestamptz; v_result jsonb;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  v_kind:=upper(trim(coalesce(p_kind,'')));
  if v_kind not in ('AVAILABLE','PREFER_NOT_TO_WORK','CANNOT_WORK')
    then raise exception 'INVALID_AVAILABILITY_KIND'; end if;
  if coalesce(cardinality(p_dates),0)=0 or cardinality(p_dates)>63
    then raise exception 'INVALID_DATE_SELECTION'; end if;
  select employee.id into v_employee from public.employees employee
  where employee.auth_user_id=v_actor and employee.active
    and employee.archived_at is null order by employee.created_at limit 1;
  if v_employee is null then raise exception 'EMPLOYEE_PROFILE_REQUIRED'; end if;

  foreach v_day in array p_dates loop
    if v_day<current_date then raise exception 'AVAILABILITY_DATE_IN_PAST'; end if;
    select matrix.id,coalesce(matrix.settings->>'timezone','Europe/Warsaw')
    into v_matrix,v_timezone from public.matrix_versions matrix
    where matrix.status='ACTIVE' and matrix.schema_version>=2
      and matrix.effective_from<=v_day
      and (matrix.effective_to is null or matrix.effective_to>=v_day)
    order by matrix.effective_from desc,matrix.version desc limit 1;
    if v_matrix is null then raise exception 'MATRIX_V2_FOR_MONTH_NOT_FOUND'; end if;

    -- Selecting green/soft cancels a pending hard request for that day first.
    if v_kind<>'CANNOT_WORK' then
      update public.availability_exception_reviews_v2 set status='CANCELLED',
        reviewed_by=v_actor,reviewed_at=now(),review_reason='Zmiana przez pracownika'
      where employee_id=v_employee and work_date=v_day and status='PENDING';
    end if;

    v_role:=null; v_event:=null; v_limit:=null;
    if v_kind='CANNOT_WORK' then
      select role_grant.role_id,event.id,hot.maximum_hard_unavailable
      into v_role,v_event,v_limit
      from public.matrix_employee_roles_v2 role_grant
      join public.workforce_hot_day_limits_v2 hot
        on hot.matrix_version_id=role_grant.matrix_version_id
        and hot.role_id=role_grant.role_id
      join public.workforce_calendar_events_v2 event on event.id=hot.event_id
        and event.status='ACTIVE' and event.event_kind='HOT_DAY'
        and event.event_date=v_day
      where role_grant.matrix_version_id=v_matrix
        and role_grant.employee_id=v_employee and role_grant.active
        and (role_grant.valid_from is null or role_grant.valid_from<=v_day)
        and (role_grant.valid_to is null or role_grant.valid_to>=v_day)
      order by role_grant.is_primary desc,hot.maximum_hard_unavailable limit 1;
    end if;
    if v_event is not null then
      select count(distinct constraint_row.employee_id)::integer into v_current
      from public.employee_time_constraints_v2 constraint_row
      join public.matrix_employee_roles_v2 role_grant
        on role_grant.matrix_version_id=v_matrix
        and role_grant.employee_id=constraint_row.employee_id
        and role_grant.role_id=v_role and role_grant.active
      where constraint_row.status='ACTIVE'
        and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
        and constraint_row.time_range && tstzrange(
          v_day::timestamp at time zone v_timezone,
          (v_day+1)::timestamp at time zone v_timezone,'[)');
      if coalesce(v_current,0)>=v_limit then
        v_start:=case when coalesce(p_all_day,true)
          then v_day::timestamp at time zone v_timezone
          else (v_day+p_local_start)::timestamp at time zone v_timezone end;
        v_end:=case when coalesce(p_all_day,true)
          then (v_day+1)::timestamp at time zone v_timezone
          when p_local_end>p_local_start
            then (v_day+p_local_end)::timestamp at time zone v_timezone
          else (v_day+1+p_local_end)::timestamp at time zone v_timezone end;
        insert into public.availability_exception_reviews_v2(
          employee_id,matrix_version_id,hot_day_event_id,role_id,work_date,
          requested_range,note,requested_by
        ) values(v_employee,v_matrix,v_event,v_role,v_day,
          tstzrange(v_start,v_end,'[)'),nullif(trim(p_note),''),v_actor)
        on conflict(employee_id,work_date,role_id) where status='PENDING'
        do update set requested_range=excluded.requested_range,note=excluded.note,
          requested_at=now();
        v_pending:=v_pending+1;
        insert into public.notifications(recipient_id,title,body)
        select distinct recipient.auth_user_id,'HOT DAY: prośba o niedostępność',
          'Pracownik zgłosił twardą niedostępność na '||v_day::text||
          '. Limit dla roli został osiągnięty.'
        from (
          select grant_row.auth_user_id from public.matrix_scope_grants_v2 grant_row
          join public.matrix_roles_v2 role on role.logical_id=grant_row.role_logical_id
          where grant_row.active and grant_row.app_role='ROLE_MANAGER'
            and role.id=v_role
          union
          select permission.auth_user_id from public.user_permissions permission
          where permission.app_role in ('OWNER','ADMIN')
        ) recipient
        where recipient.auth_user_id is not null;
        continue;
      end if;
    end if;
    v_result:=public.employee_availability_bulk_save_v2(
      v_day,v_day,v_kind,p_all_day,p_local_start,p_local_end,
      p_preferred_location_id,p_note);
    v_saved:=v_saved+coalesce((v_result->>'savedDays')::integer,0);
  end loop;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'employee_availability_v2',v_employee::text,'SET_DAYS_REVIEW_AWARE',
    jsonb_build_object('dates',to_jsonb(p_dates),'kind',v_kind,
      'savedDays',v_saved,'pendingReviewDays',v_pending));
  return jsonb_build_object('employeeId',v_employee,'savedDays',v_saved,
    'pendingReviewDays',v_pending,'kind',v_kind);
end;
$$;

create function public.availability_exception_review_uat_v2(
  p_review_id uuid,p_decision text,p_reason text
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_review public.availability_exception_reviews_v2%rowtype;
  v_decision text:=upper(trim(coalesce(p_decision,''))); v_constraint uuid;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  if v_decision not in ('APPROVE','REJECT') then raise exception 'INVALID_REVIEW_DECISION'; end if;
  if length(trim(coalesce(p_reason,'')))<3 then raise exception 'REVIEW_REASON_REQUIRED'; end if;
  select * into v_review from public.availability_exception_reviews_v2
  where id=p_review_id for update;
  if v_review.id is null then raise exception 'REVIEW_NOT_FOUND'; end if;
  if v_review.status<>'PENDING' then raise exception 'REVIEW_ALREADY_RESOLVED'; end if;
  if v_decision='APPROVE' then
    v_constraint:=gen_random_uuid();
    insert into public.employee_time_constraints_v2(
      id,employee_id,constraint_kind,time_range,source,source_record_key,
      priority,editable_by_employee,status,note,created_by
    ) values(v_constraint,v_review.employee_id,'UNAVAILABLE',v_review.requested_range,
      'HOT_DAY_APPROVED','hot-day-review:'||v_review.id::text,100,false,'ACTIVE',
      v_review.note,v_actor);
  end if;
  update public.availability_exception_reviews_v2 set
    status=case when v_decision='APPROVE' then 'APPROVED' else 'REJECTED' end,
    reviewed_by=v_actor,reviewed_at=now(),review_reason=trim(p_reason),
    constraint_id=v_constraint where id=v_review.id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'availability_exception_review_v2',v_review.id::text,v_decision,
    jsonb_build_object('employeeId',v_review.employee_id,'date',v_review.work_date,
      'roleId',v_review.role_id,'reason',trim(p_reason),'constraintId',v_constraint));
  insert into public.notifications(recipient_id,title,body)
  select employee.auth_user_id,'Decyzja dotycząca niedostępności',
    case when v_decision='APPROVE' then 'Niedostępność została zaakceptowana.'
      else 'Niedostępność nie została zaakceptowana: '||trim(p_reason) end
  from public.employees employee where employee.id=v_review.employee_id
    and employee.auth_user_id is not null;
  return jsonb_build_object('id',v_review.id,'status',
    case when v_decision='APPROVE' then 'APPROVED' else 'REJECTED' end,
    'constraintId',v_constraint);
end;
$$;

revoke all on function solver_private.resolved_matrix_demand_v2(date,uuid,uuid,uuid),
  solver_private.resolved_demand_v2(date,uuid,uuid,uuid)
  from public,anon,authenticated;
grant execute on function solver_private.resolved_matrix_demand_v2(date,uuid,uuid,uuid),
  solver_private.resolved_demand_v2(date,uuid,uuid,uuid) to service_role;
revoke all on function public.workforce_calendar_event_save_uat_v2(
  uuid,date,date,text,text,text,uuid,jsonb,jsonb),
  public.workforce_calendar_context_uat_v2(date),
  public.employee_availability_days_save_uat_v3(
    date[],text,boolean,time,time,uuid,text),
  public.availability_exception_review_uat_v2(uuid,text,text)
  from public,anon,authenticated;
grant execute on function public.workforce_calendar_event_save_uat_v2(
  uuid,date,date,text,text,text,uuid,jsonb,jsonb),
  public.workforce_calendar_context_uat_v2(date),
  public.employee_availability_days_save_uat_v3(
    date[],text,boolean,time,time,uuid,text),
  public.availability_exception_review_uat_v2(uuid,text,text)
  to authenticated;

notify pgrst,'reload schema';
