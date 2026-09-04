-- B4F-141: the HOME action note must receive every employee-relevant update.
-- Existing producers use public.notifications, so normalize their legacy rows
-- at the database boundary and add the two missing swap events.

create or replace function public.employee_availability_publication_conflicts_uat_v2(
  p_employee_id uuid,
  p_dates date[],
  p_all_day boolean default true,
  p_local_start time default null,
  p_local_end time default null
) returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare v_actor uuid:=auth.uid();
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if coalesce(cardinality(p_dates),0)=0 then raise exception 'INVALID_DATE_SELECTION'; end if;
  if not coalesce(p_all_day,true) and (
    p_local_start is null or p_local_end is null or p_local_start=p_local_end
  ) then raise exception 'INVALID_LOCAL_TIME_RANGE'; end if;
  if not exists(select 1 from public.employees employee
      where employee.id=p_employee_id and employee.auth_user_id=v_actor)
     and not exists(select 1 from public.user_permissions permission
      where permission.auth_user_id=v_actor and permission.app_role in ('OWNER','ADMIN')) then
    perform solver_private.assert_uat_master_persona_v2();
  end if;
  return coalesce((
    select jsonb_agg(distinct jsonb_build_object(
      'scheduleId',schedule.id,'scheduleName',schedule.name,
      'publishedAt',schedule.published_at,'date',shift.shift_date,
      'shiftName',template.name,'locationName',location.name,'roleName',role.name,
      'startsAt',shift.starts_at,'endsAt',shift.ends_at
    ))
    from public.published_role_schedules_v2 schedule
    join public.plan_assignments_v2 assignment on assignment.variant_id=schedule.variant_id
      and assignment.employee_id=p_employee_id
    join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
    join public.matrix_shift_templates_v2 template on template.id=shift.shift_template_id
    join public.matrix_locations_v2 location on location.id=shift.location_id
    join public.matrix_roles_v2 role on role.id=assignment.role_id
    where schedule.status='PUBLISHED' and shift.shift_date=any(p_dates)
      and (coalesce(p_all_day,true) or tstzrange(shift.starts_at,shift.ends_at,'[)') &&
        tstzrange(
          (shift.shift_date+p_local_start)::timestamp at time zone location.timezone,
          (shift.shift_date+p_local_end
            +case when p_local_end<=p_local_start then interval '1 day' else interval '0 day' end
          )::timestamp at time zone location.timezone,
          '[)'
        )
      )
  ),'[]'::jsonb);
end;
$$;

create or replace function public.employee_request_submit_uat_v2(
  p_request_type text,
  p_dates date[],
  p_all_day boolean default true,
  p_local_start time default null,
  p_local_end time default null,
  p_note text default null
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_day date;
  v_result jsonb;
  v_request_ids jsonb:='[]'::jsonb;
  v_saved integer:=0;
  v_pending integer:=0;
begin
  if coalesce(cardinality(p_dates),0)=0 or cardinality(p_dates)>63 then
    raise exception 'INVALID_DATE_SELECTION';
  end if;
  if coalesce(p_all_day,true) or cardinality(p_dates)=1
    or upper(trim(coalesce(p_request_type,'')))='HARD_UNAVAILABLE' then
    return public.employee_request_submit_uat_v1(
      p_request_type,p_dates,p_all_day,p_local_start,p_local_end,p_note
    );
  end if;
  foreach v_day in array p_dates loop
    v_result:=public.employee_request_submit_uat_v1(
      p_request_type,array[v_day],false,p_local_start,p_local_end,p_note
    );
    v_request_ids:=v_request_ids||coalesce(v_result->'requestIds','[]'::jsonb);
    v_saved:=v_saved+coalesce((v_result->>'saved')::integer,0);
    v_pending:=v_pending+coalesce((v_result->>'pending')::integer,0);
  end loop;
  return jsonb_build_object(
    'requestType',upper(trim(coalesce(p_request_type,''))),
    'requestIds',v_request_ids,'saved',v_saved,'pending',v_pending
  );
end;
$$;

create or replace function solver_private.normalize_personal_notification_v1()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  if new.title like 'Zmieniono Twój grafik%' then
    new.kind:='SCHEDULE_PUBLISHED';
    new.action_route:=coalesce(nullif(new.action_route,''),'/my-schedule');
  elsif new.title='Propozycja zamiany zmiany' then
    if tg_op='INSERT' and new.context_id is null and exists(
      select 1 from public.notifications existing
      where existing.recipient_id=new.recipient_id
        and existing.title=new.title
        and existing.context_type='SHIFT_SWAP'
        and existing.created_at>=transaction_timestamp()
    ) then return null; end if;
    new.kind:='ACTION_REQUIRED';
    new.action_required:=true;
    new.action_route:=coalesce(nullif(new.action_route,''),'/swaps');
  elsif new.title='Zamiana czeka na akceptację' then
    if tg_op='INSERT' and new.context_id is null and exists(
      select 1 from public.notifications existing
      where existing.recipient_id=new.recipient_id
        and existing.title=new.title
        and existing.context_type='SHIFT_SWAP'
        and existing.created_at>=transaction_timestamp()
    ) then return null; end if;
    new.kind:='ACTION_REQUIRED';
    new.action_required:=true;
    new.action_route:=coalesce(nullif(new.action_route,''),'/swaps');
  elsif new.title='Decyzja lidera o zamianie' then
    new.kind:='DECISION';
    new.action_route:=coalesce(nullif(new.action_route,''),'/swaps');
  elsif new.title like 'Nowe wydarzenie:%' then
    new.kind:='INFORMATION';
    new.action_route:=coalesce(nullif(new.action_route,''),'/my-schedule');
  end if;
  new.sent_at:=coalesce(new.sent_at,now());
  return new;
end;
$$;

drop trigger if exists notifications_personal_normalize_v1 on public.notifications;
create trigger notifications_personal_normalize_v1
before insert or update of title,body,action_route on public.notifications
for each row execute function solver_private.normalize_personal_notification_v1();

create or replace function solver_private.shift_swap_personal_notifications_v1()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  if tg_op='INSERT' then
    if new.target_employee_id is null then
      insert into public.notifications(
        recipient_id,channel,title,body,kind,action_required,action_route,
        context_type,context_id,sent_at
      )
      select employee.auth_user_id,'IN_APP','Nowa oferta na tablicy zmian',
        'Możesz sprawdzić zmianę '||shift.shift_date::text||' • '
          ||location.name||' • '||role.name||'.',
        'INFORMATION',false,'/swaps','SHIFT_SWAP',new.id::text,now()
      from public.employees employee
      join public.plan_assignments_v2 assignment
        on assignment.id=new.original_assignment_id
      join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
      join public.matrix_locations_v2 location on location.id=shift.location_id
      join public.matrix_roles_v2 role on role.id=new.role_id
      where employee.active and employee.archived_at is null
        and employee.auth_user_id is not null
        and employee.id<>new.proposer_employee_id
        and cardinality(solver_private.swap_candidate_reasons_uat_v2(new.id,employee.id))=0
        and not exists(
          select 1 from public.notifications notification
          where notification.recipient_id=employee.auth_user_id
            and notification.context_type='SHIFT_SWAP'
            and notification.context_id=new.id::text
            and notification.title='Nowa oferta na tablicy zmian'
        );
    else
      insert into public.notifications(
        recipient_id,channel,title,body,kind,action_required,action_route,
        context_type,context_id,sent_at
      )
      select target.auth_user_id,'IN_APP','Propozycja zamiany zmiany',
        'Otrzymujesz propozycję przejęcia zmiany '||shift.shift_date::text||'.',
        'ACTION_REQUIRED',true,'/swaps','SHIFT_SWAP',new.id::text,now()
      from public.employees target
      join public.plan_assignments_v2 assignment
        on assignment.id=new.original_assignment_id
      join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
      where target.id=new.target_employee_id and target.auth_user_id is not null;
    end if;
  elsif tg_op='UPDATE' and old.status='OPEN' and new.status='EMPLOYEE_ACCEPTED' then
    update public.notifications set resolved_at=now(),resolution='TAKEN'
    where context_type='SHIFT_SWAP' and context_id=new.id::text
      and resolved_at is null and title in (
        'Nowa oferta na tablicy zmian','Propozycja zamiany zmiany'
      );
    insert into public.notifications(
      recipient_id,channel,title,body,kind,action_required,action_route,
      context_type,context_id,sent_at
    )
    select proposer.auth_user_id,'IN_APP','Ktoś przyjął Twoją propozycję zmiany',
      accepted.first_name||' '||accepted.last_name
        ||' chce przejąć Twoją zmianę. Teraz decyzję podejmuje lider.',
      'DECISION',false,'/swaps','SHIFT_SWAP',new.id::text,now()
    from public.employees proposer
    join public.employees accepted on accepted.id=new.accepted_by_employee_id
    where proposer.id=new.proposer_employee_id
      and proposer.auth_user_id is not null
      and not exists(
        select 1 from public.notifications notification
        where notification.recipient_id=proposer.auth_user_id
          and notification.context_type='SHIFT_SWAP'
          and notification.context_id=new.id::text
          and notification.title='Ktoś przyjął Twoją propozycję zmiany'
      );
    insert into public.notifications(
      recipient_id,channel,title,body,kind,action_required,action_route,
      context_type,context_id,sent_at
    )
    select distinct recipient.auth_user_id,'IN_APP','Zamiana czeka na akceptację',
      'Pracownicy uzgodnili zamianę. Sprawdź ją i zaakceptuj albo odrzuć.',
      'ACTION_REQUIRED',true,'/swaps','SHIFT_SWAP',new.id::text,now()
    from (
      select grant_row.auth_user_id from public.matrix_scope_grants_v2 grant_row
      join public.matrix_roles_v2 role on role.logical_id=grant_row.role_logical_id
      where grant_row.active and grant_row.app_role='ROLE_MANAGER'
        and role.id=new.role_id
      union
      select permission.auth_user_id from public.user_permissions permission
      where permission.app_role in ('OWNER','ADMIN')
    ) recipient where recipient.auth_user_id is not null;
  elsif tg_op='UPDATE' and old.status='OPEN' and new.status='EMPLOYEE_REJECTED' then
    update public.notifications set resolved_at=now(),resolution='REJECTED'
    where context_type='SHIFT_SWAP' and context_id=new.id::text
      and resolved_at is null and action_required;
    insert into public.notifications(
      recipient_id,channel,title,body,kind,action_required,action_route,
      context_type,context_id,sent_at
    )
    select proposer.auth_user_id,'IN_APP','Odrzucono Twoją propozycję zmiany',
      coalesce(target.first_name||' '||target.last_name,'Wybrana osoba')
        ||' nie przyjęła propozycji. Możesz opublikować nowe ogłoszenie.',
      'DECISION',false,'/swaps','SHIFT_SWAP',new.id::text,now()
    from public.employees proposer
    left join public.employees target on target.id=new.target_employee_id
    where proposer.id=new.proposer_employee_id
      and proposer.auth_user_id is not null
      and not exists(
        select 1 from public.notifications notification
        where notification.recipient_id=proposer.auth_user_id
          and notification.context_type='SHIFT_SWAP'
          and notification.context_id=new.id::text
          and notification.title='Odrzucono Twoją propozycję zmiany'
      );
  elsif tg_op='UPDATE' and old.status='EMPLOYEE_ACCEPTED'
      and new.status in ('LEADER_APPROVED','LEADER_REJECTED','CANCELLED') then
    update public.notifications
    set resolved_at=now(),resolution=new.status
    where context_type='SHIFT_SWAP' and context_id=new.id::text
      and resolved_at is null and action_required;
  end if;
  return new;
end;
$$;

drop trigger if exists shift_swap_personal_notifications_v1
  on public.shift_swap_requests_v2;
create trigger shift_swap_personal_notifications_v1
after insert or update of status on public.shift_swap_requests_v2
for each row execute function solver_private.shift_swap_personal_notifications_v1();

-- Normalize still-open, unread legacy notifications without changing history.
update public.notifications
set title=title
where read_at is null and resolved_at is null and (
  title like 'Zmieniono Twój grafik%'
  or title in ('Propozycja zamiany zmiany','Zamiana czeka na akceptację',
    'Decyzja lidera o zamianie')
  or title like 'Nowe wydarzenie:%'
);

-- Existing open public offers become visible on the action note immediately.
insert into public.notifications(
  recipient_id,channel,title,body,kind,action_required,action_route,
  context_type,context_id,sent_at
)
select employee.auth_user_id,'IN_APP','Nowa oferta na tablicy zmian',
  'Możesz sprawdzić zmianę '||shift.shift_date::text||' • '
    ||location.name||' • '||role.name||'.',
  'INFORMATION',false,'/swaps','SHIFT_SWAP',request.id::text,now()
from public.shift_swap_requests_v2 request
join public.plan_assignments_v2 assignment
  on assignment.id=request.original_assignment_id
join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
join public.matrix_locations_v2 location on location.id=shift.location_id
join public.matrix_roles_v2 role on role.id=request.role_id
join public.employees employee on employee.active and employee.archived_at is null
  and employee.auth_user_id is not null
  and employee.id<>request.proposer_employee_id
where request.status='OPEN' and request.target_employee_id is null
  and cardinality(solver_private.swap_candidate_reasons_uat_v2(request.id,employee.id))=0
  and not exists(
    select 1 from public.notifications notification
    where notification.recipient_id=employee.auth_user_id
      and notification.context_type='SHIFT_SWAP'
      and notification.context_id=request.id::text
      and notification.title='Nowa oferta na tablicy zmian'
  );

insert into public.notifications(
  recipient_id,channel,title,body,kind,action_required,action_route,
  context_type,context_id,sent_at
)
select target.auth_user_id,'IN_APP','Propozycja zamiany zmiany',
  'Otrzymujesz propozycję przejęcia zmiany '||shift.shift_date::text||'.',
  'ACTION_REQUIRED',true,'/swaps','SHIFT_SWAP',request.id::text,now()
from public.shift_swap_requests_v2 request
join public.plan_assignments_v2 assignment
  on assignment.id=request.original_assignment_id
join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
join public.employees target on target.id=request.target_employee_id
where request.status='OPEN' and request.target_employee_id is not null
  and target.auth_user_id is not null
  and not exists(
    select 1 from public.notifications notification
    where notification.recipient_id=target.auth_user_id
      and notification.context_type='SHIFT_SWAP'
      and notification.context_id=request.id::text
      and notification.title='Propozycja zamiany zmiany'
  );

insert into public.notifications(
  recipient_id,channel,title,body,kind,action_required,action_route,
  context_type,context_id,sent_at
)
select distinct recipient.auth_user_id,'IN_APP','Zamiana czeka na akceptację',
  'Pracownicy uzgodnili zamianę. Sprawdź ją i zaakceptuj albo odrzuć.',
  'ACTION_REQUIRED',true,'/swaps','SHIFT_SWAP',request.id::text,now()
from public.shift_swap_requests_v2 request
join lateral (
  select grant_row.auth_user_id from public.matrix_scope_grants_v2 grant_row
  join public.matrix_roles_v2 role on role.logical_id=grant_row.role_logical_id
  where grant_row.active and grant_row.app_role='ROLE_MANAGER'
    and role.id=request.role_id
  union
  select permission.auth_user_id from public.user_permissions permission
  where permission.app_role in ('OWNER','ADMIN')
) recipient on true
where request.status='EMPLOYEE_ACCEPTED' and recipient.auth_user_id is not null
  and not exists(
    select 1 from public.notifications notification
    where notification.recipient_id=recipient.auth_user_id
      and notification.context_type='SHIFT_SWAP'
      and notification.context_id=request.id::text
      and notification.title='Zamiana czeka na akceptację'
  );

update public.notifications legacy
set resolved_at=coalesce(legacy.resolved_at,now()),resolution='MIGRATED'
where legacy.context_id is null and legacy.resolved_at is null
  and legacy.title in ('Propozycja zamiany zmiany','Zamiana czeka na akceptację');

revoke all on function solver_private.normalize_personal_notification_v1()
  from public,anon,authenticated;
revoke all on function solver_private.shift_swap_personal_notifications_v1()
  from public,anon,authenticated;
revoke all on function public.employee_availability_publication_conflicts_uat_v2(
  uuid,date[],boolean,time,time
) from public,anon,authenticated;
revoke all on function public.employee_request_submit_uat_v2(
  text,date[],boolean,time,time,text
) from public,anon,authenticated;
grant execute on function public.employee_availability_publication_conflicts_uat_v2(
  uuid,date[],boolean,time,time
) to authenticated;
grant execute on function public.employee_request_submit_uat_v2(
  text,date[],boolean,time,time,text
) to authenticated;

notify pgrst,'reload schema';
