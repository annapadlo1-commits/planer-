-- B4F-131..138: one personal workspace for every authenticated account,
-- auditable employee absence workflows and a universal action centre.

create table if not exists public.user_profiles_v1 (
  auth_user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  avatar_mode text not null default 'INITIALS'
    check (avatar_mode in ('INITIALS','CAT','PHOTO')),
  cat_avatar_key text,
  note_color text not null default '#E8E1D6',
  photo_path text,
  ui_preferences jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (display_name is null or length(trim(display_name)) between 1 and 80),
  check (cat_avatar_key is null or cat_avatar_key ~ '^CAT_(0[1-9]|[1-4][0-9]|50)$'),
  check (note_color in (
    '#1A1A1A','#2A2A28','#E8E1D6','#F2EDE4','#A6B3A0','#879681',
    '#55665A','#C4D2C4','#D9987E','#C96F54','#B85F3F','#CBBFAE',
    '#9C9184','#F7F3EC','#33443B','#B85E58','#BBC3B7','#9AAA8F',
    '#2B3A32','#C98274','#E6B39C','#B8A994','#756D65','#D7D0C7'
  )),
  check (
    (avatar_mode='CAT' and cat_avatar_key is not null and photo_path is null)
    or (avatar_mode='PHOTO' and photo_path is not null and cat_avatar_key is null)
    or (avatar_mode='INITIALS' and cat_avatar_key is null and photo_path is null)
  ),
  check (jsonb_typeof(ui_preferences)='object')
);

alter table public.notifications
  add column if not exists kind text not null default 'INFORMATION',
  add column if not exists context_type text,
  add column if not exists context_id text,
  add column if not exists action_route text,
  add column if not exists action_required boolean not null default false,
  add column if not exists resolved_at timestamptz,
  add column if not exists resolution text;

alter table public.notifications drop constraint if exists notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('INFORMATION','ACTION_REQUIRED','DECISION','SCHEDULE_PUBLISHED','MESSAGE'));

create table if not exists public.employee_requests_v1 (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete cascade,
  requested_by uuid not null references auth.users(id) on delete cascade,
  request_type text not null
    check (request_type in ('LEAVE','SICKNESS','HARD_UNAVAILABLE')),
  date_from date not null,
  date_to date not null,
  requested_range tstzrange not null,
  status text not null
    check (status in ('PENDING','APPLIED','AUTO_APPLIED','APPROVED','REJECTED','CANCELLED','ACKNOWLEDGED')),
  requires_decision boolean not null default false,
  note text,
  constraint_id uuid references public.employee_time_constraints_v2(id) on delete set null,
  legacy_review_id uuid references public.availability_exception_reviews_v2(id) on delete set null,
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  review_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (date_to>=date_from),
  check (not isempty(requested_range)),
  check (lower(requested_range) is not null and upper(requested_range) is not null),
  check ((status='PENDING' and reviewed_at is null) or status<>'PENDING')
);

create index if not exists notifications_action_center_v1_idx
  on public.notifications(recipient_id,action_required,resolved_at,read_at,created_at desc);
create index if not exists notifications_context_v1_idx
  on public.notifications(context_type,context_id,recipient_id);
create index if not exists employee_requests_employee_v1_idx
  on public.employee_requests_v1(employee_id,status,date_from,created_at desc);
create index if not exists employee_requests_action_v1_idx
  on public.employee_requests_v1(status,requires_decision,created_at desc)
  where status in ('PENDING','APPLIED');

alter table public.user_profiles_v1 enable row level security;
alter table public.employee_requests_v1 enable row level security;

drop policy if exists user_profiles_self_read_v1 on public.user_profiles_v1;
create policy user_profiles_self_read_v1 on public.user_profiles_v1
  for select to authenticated using (auth_user_id=(select auth.uid()));
drop policy if exists user_profiles_self_insert_v1 on public.user_profiles_v1;
create policy user_profiles_self_insert_v1 on public.user_profiles_v1
  for insert to authenticated with check (auth_user_id=(select auth.uid()));
drop policy if exists user_profiles_self_update_v1 on public.user_profiles_v1;
create policy user_profiles_self_update_v1 on public.user_profiles_v1
  for update to authenticated using (auth_user_id=(select auth.uid()))
  with check (auth_user_id=(select auth.uid()));

drop policy if exists employee_requests_self_or_manager_read_v1 on public.employee_requests_v1;
create policy employee_requests_self_or_manager_read_v1 on public.employee_requests_v1
  for select to authenticated using (
    requested_by=(select auth.uid())
    or public.matrix_v2_can_manage_employee(employee_id)
  );

revoke all on table public.user_profiles_v1,public.employee_requests_v1
  from public,anon,authenticated;
grant select on table public.user_profiles_v1,public.employee_requests_v1 to authenticated;
grant all on table public.user_profiles_v1,public.employee_requests_v1 to service_role;

-- Existing notification producers continue to work. Users only read their own
-- rows through RLS; all writes remain behind audited SECURITY DEFINER RPCs.
drop policy if exists user_reads_own_notifications on public.notifications;
create policy user_reads_own_notifications on public.notifications
  for select to authenticated using (recipient_id=(select auth.uid()));
revoke insert,update,delete on table public.notifications from authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('profile-avatars','profile-avatars',false,5242880,
  array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists profile_avatars_self_select_v1 on storage.objects;
create policy profile_avatars_self_select_v1 on storage.objects
  for select to authenticated using (
    bucket_id='profile-avatars'
    and (storage.foldername(name))[1]=(select auth.uid())::text
  );
drop policy if exists profile_avatars_self_insert_v1 on storage.objects;
create policy profile_avatars_self_insert_v1 on storage.objects
  for insert to authenticated with check (
    bucket_id='profile-avatars'
    and (storage.foldername(name))[1]=(select auth.uid())::text
  );
drop policy if exists profile_avatars_self_update_v1 on storage.objects;
create policy profile_avatars_self_update_v1 on storage.objects
  for update to authenticated using (
    bucket_id='profile-avatars'
    and (storage.foldername(name))[1]=(select auth.uid())::text
  ) with check (
    bucket_id='profile-avatars'
    and (storage.foldername(name))[1]=(select auth.uid())::text
  );
drop policy if exists profile_avatars_self_delete_v1 on storage.objects;
create policy profile_avatars_self_delete_v1 on storage.objects
  for delete to authenticated using (
    bucket_id='profile-avatars'
    and (storage.foldername(name))[1]=(select auth.uid())::text
  );

create or replace function public.personal_request_manager_recipients_uat_v1(
  p_employee_id uuid
) returns table(auth_user_id uuid)
language sql stable security definer set search_path=''
as $$
  select distinct recipient.auth_user_id
  from (
    select permission.auth_user_id
    from public.user_permissions permission
    where permission.app_role in ('OWNER','ADMIN')
    union all
    select grant_row.auth_user_id
    from public.matrix_scope_grants_v2 grant_row
    where grant_row.active
      and grant_row.app_role in ('ROLE_MANAGER','LOCATION_MANAGER')
      and (grant_row.role_logical_id is null or exists(
        select 1
        from public.matrix_employee_roles_v2 employee_role
        join public.matrix_roles_v2 role_row on role_row.id=employee_role.role_id
        join public.matrix_versions matrix_row on matrix_row.id=employee_role.matrix_version_id
          and matrix_row.status='ACTIVE'
        where employee_role.employee_id=p_employee_id and employee_role.active
          and role_row.logical_id=grant_row.role_logical_id
      ))
      and (grant_row.location_logical_id is null or exists(
        select 1
        from public.matrix_employee_locations_v2 employee_location
        join public.matrix_locations_v2 location_row on location_row.id=employee_location.location_id
        join public.matrix_versions matrix_row on matrix_row.id=employee_location.matrix_version_id
          and matrix_row.status='ACTIVE'
        where employee_location.employee_id=p_employee_id and employee_location.active
          and location_row.logical_id=grant_row.location_logical_id
      ))
  ) recipient
  where recipient.auth_user_id is not null;
$$;

create or replace function public.personal_profile_workspace_uat_v1()
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare
  v_actor uuid:=auth.uid();
  v_result jsonb;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select jsonb_build_object(
    'profile',jsonb_build_object(
      'authUserId',v_actor,
      'displayName',coalesce(nullif(trim(profile.display_name),''),
        nullif(trim(concat_ws(' ',employee.first_name,employee.last_name)),''),
        split_part(auth_user.email,'@',1)),
      'avatarMode',coalesce(profile.avatar_mode,'INITIALS'),
      'catAvatarKey',profile.cat_avatar_key,
      'noteColor',coalesce(profile.note_color,'#E8E1D6'),
      'photoPath',profile.photo_path,
      'uiPreferences',coalesce(profile.ui_preferences,'{}'::jsonb)
    ),
    'employee',case when employee.id is null then null else jsonb_build_object(
      'id',employee.id,'employeeNo',employee.employee_no,
      'firstName',employee.first_name,'lastName',employee.last_name
    ) end,
    'appRoles',coalesce((select jsonb_agg(distinct role_name order by role_name)
      from (
        select permission.app_role::text role_name from public.user_permissions permission
          where permission.auth_user_id=v_actor
        union
        select grant_row.app_role::text from public.matrix_scope_grants_v2 grant_row
          where grant_row.auth_user_id=v_actor and grant_row.active
      ) roles),'[]'::jsonb)
  ) into v_result
  from auth.users auth_user
  left join public.user_profiles_v1 profile on profile.auth_user_id=v_actor
  left join public.employees employee on employee.auth_user_id=v_actor
    and employee.active and employee.archived_at is null
  where auth_user.id=v_actor;
  return coalesce(v_result,'{}'::jsonb);
end;
$$;

create or replace function public.personal_profile_save_uat_v1(
  p_display_name text,
  p_avatar_mode text,
  p_cat_avatar_key text default null,
  p_note_color text default '#E8E1D6',
  p_photo_path text default null,
  p_ui_preferences jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid:=auth.uid();
  v_mode text:=upper(trim(coalesce(p_avatar_mode,'')));
  v_cat text:=upper(trim(coalesce(p_cat_avatar_key,'')));
  v_photo text:=nullif(trim(coalesce(p_photo_path,'')),'');
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if length(trim(coalesce(p_display_name,''))) not between 1 and 80 then
    raise exception 'INVALID_DISPLAY_NAME';
  end if;
  if v_mode not in ('INITIALS','CAT','PHOTO') then raise exception 'INVALID_AVATAR_MODE'; end if;
  if v_mode='CAT' and v_cat !~ '^CAT_(0[1-9]|[1-4][0-9]|50)$' then
    raise exception 'INVALID_CAT_AVATAR';
  end if;
  if v_mode='PHOTO' and (v_photo is null or v_photo not like v_actor::text||'/%') then
    raise exception 'INVALID_PROFILE_PHOTO_PATH';
  end if;
  if p_ui_preferences is null or jsonb_typeof(p_ui_preferences)<>'object' then
    raise exception 'INVALID_UI_PREFERENCES';
  end if;
  insert into public.user_profiles_v1(
    auth_user_id,display_name,avatar_mode,cat_avatar_key,note_color,photo_path,
    ui_preferences,updated_at
  ) values(
    v_actor,trim(p_display_name),v_mode,
    case when v_mode='CAT' then v_cat else null end,p_note_color,
    case when v_mode='PHOTO' then v_photo else null end,p_ui_preferences,now()
  ) on conflict(auth_user_id) do update set
    display_name=excluded.display_name,avatar_mode=excluded.avatar_mode,
    cat_avatar_key=excluded.cat_avatar_key,note_color=excluded.note_color,
    photo_path=excluded.photo_path,ui_preferences=excluded.ui_preferences,
    updated_at=now();
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'user_profile_v1',v_actor::text,'SAVE',jsonb_build_object(
    'avatarMode',v_mode,'catAvatarKey',case when v_mode='CAT' then v_cat else null end,
    'noteColor',p_note_color,'hasPhoto',v_mode='PHOTO'));
  return public.personal_profile_workspace_uat_v1();
end;
$$;

create or replace function public.employee_request_submit_uat_v1(
  p_request_type text,
  p_dates date[],
  p_all_day boolean default true,
  p_local_start time default null,
  p_local_end time default null,
  p_note text default null
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid:=auth.uid();
  v_employee uuid;
  v_type text:=upper(trim(coalesce(p_request_type,'')));
  v_first date;
  v_last date;
  v_day date;
  v_timezone text;
  v_start timestamptz;
  v_end timestamptz;
  v_id uuid;
  v_constraint uuid;
  v_legacy uuid;
  v_result jsonb;
  v_saved integer:=0;
  v_pending integer:=0;
  v_request_ids jsonb:='[]'::jsonb;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if v_type not in ('LEAVE','SICKNESS','HARD_UNAVAILABLE') then
    raise exception 'INVALID_EMPLOYEE_REQUEST_TYPE';
  end if;
  if coalesce(cardinality(p_dates),0)=0 or cardinality(p_dates)>63 then
    raise exception 'INVALID_DATE_SELECTION';
  end if;
  select min(day_value),max(day_value) into v_first,v_last
  from unnest(p_dates) day_value;
  if (select count(distinct day_value) from unnest(p_dates) day_value)<>cardinality(p_dates) then
    raise exception 'DUPLICATE_DATES';
  end if;
  if v_type in ('LEAVE','HARD_UNAVAILABLE') and v_first<current_date then
    raise exception 'ABSENCE_DATE_IN_PAST';
  end if;
  if v_type in ('LEAVE','SICKNESS') and cardinality(p_dates)<>(v_last-v_first+1) then
    raise exception 'REQUEST_RANGE_MUST_BE_CONTIGUOUS';
  end if;
  if not coalesce(p_all_day,true) and (
    p_local_start is null or p_local_end is null or p_local_start=p_local_end
  ) then raise exception 'INVALID_LOCAL_TIME_RANGE'; end if;
  select employee.id into v_employee from public.employees employee
  where employee.auth_user_id=v_actor and employee.active
    and employee.archived_at is null order by employee.created_at limit 1;
  if v_employee is null then raise exception 'EMPLOYEE_PROFILE_REQUIRED'; end if;

  if v_type in ('LEAVE','SICKNESS') then
    select coalesce(matrix_row.settings->>'timezone','Europe/Warsaw') into v_timezone
    from public.matrix_versions matrix_row
    where matrix_row.status='ACTIVE' and matrix_row.schema_version>=2
      and matrix_row.effective_from<=v_first
      and (matrix_row.effective_to is null or matrix_row.effective_to>=v_first)
    order by matrix_row.effective_from desc,matrix_row.version desc limit 1;
    if v_timezone is null then raise exception 'MATRIX_V2_FOR_MONTH_NOT_FOUND'; end if;
    v_start:=case when coalesce(p_all_day,true)
      then v_first::timestamp at time zone v_timezone
      else (v_first+p_local_start)::timestamp at time zone v_timezone end;
    v_end:=case when coalesce(p_all_day,true)
      then (v_last+1)::timestamp at time zone v_timezone
      when p_local_end>p_local_start
        then (v_last+p_local_end)::timestamp at time zone v_timezone
      else (v_last+1+p_local_end)::timestamp at time zone v_timezone end;
    v_id:=gen_random_uuid();
    if v_type='SICKNESS' then
      v_constraint:=gen_random_uuid();
      insert into public.employee_time_constraints_v2(
        id,employee_id,constraint_kind,time_range,source,source_record_key,
        priority,editable_by_employee,status,note,created_by
      ) values(v_constraint,v_employee,'SICKNESS',tstzrange(v_start,v_end,'[)'),
        'EMPLOYEE_SICKNESS','employee-request:'||v_id::text,500,false,'ACTIVE',
        nullif(trim(p_note),''),v_actor);
    end if;
    insert into public.employee_requests_v1(
      id,employee_id,requested_by,request_type,date_from,date_to,requested_range,
      status,requires_decision,note,constraint_id
    ) values(v_id,v_employee,v_actor,v_type,v_first,v_last,tstzrange(v_start,v_end,'[)'),
      case when v_type='LEAVE' then 'PENDING' else 'APPLIED' end,true,
      nullif(trim(p_note),''),v_constraint);
    insert into public.notifications(
      recipient_id,title,body,kind,context_type,context_id,action_route,action_required
    ) select recipient.auth_user_id,
      case when v_type='LEAVE' then 'Nowy wniosek urlopowy' else 'Zgłoszone L4' end,
      case when v_type='LEAVE'
        then 'Pracownik prosi o urlop '||v_first::text||'–'||v_last::text||'. Otwórz sprawę i podejmij decyzję.'
        else 'Pracownik zgłosił L4 '||v_first::text||'–'||v_last::text||'. Nie można go odrzucić — potwierdź odbiór i zorganizuj zastępstwo.' end,
      'ACTION_REQUIRED','EMPLOYEE_REQUEST',v_id::text,'/profile?tab=inbox',true
    from public.personal_request_manager_recipients_uat_v1(v_employee) recipient;
    v_request_ids:=jsonb_build_array(v_id);
    v_saved:=1;
  else
    foreach v_day in array p_dates loop
      v_result:=public.employee_availability_days_save_uat_v3(
        array[v_day],'CANNOT_WORK',p_all_day,p_local_start,p_local_end,null,p_note);
      select coalesce(matrix_row.settings->>'timezone','Europe/Warsaw') into v_timezone
      from public.matrix_versions matrix_row
      where matrix_row.status='ACTIVE' and matrix_row.schema_version>=2
        and matrix_row.effective_from<=v_day
        and (matrix_row.effective_to is null or matrix_row.effective_to>=v_day)
      order by matrix_row.effective_from desc,matrix_row.version desc limit 1;
      v_start:=case when coalesce(p_all_day,true)
        then v_day::timestamp at time zone v_timezone
        else (v_day+p_local_start)::timestamp at time zone v_timezone end;
      v_end:=case when coalesce(p_all_day,true)
        then (v_day+1)::timestamp at time zone v_timezone
        when p_local_end>p_local_start
          then (v_day+p_local_end)::timestamp at time zone v_timezone
        else (v_day+1+p_local_end)::timestamp at time zone v_timezone end;
      v_id:=gen_random_uuid();v_constraint:=null;v_legacy:=null;
      if coalesce((v_result->>'pendingReviewDays')::integer,0)>0 then
        select review.id into v_legacy from public.availability_exception_reviews_v2 review
        where review.employee_id=v_employee and review.work_date=v_day
          and review.status='PENDING' order by review.requested_at desc limit 1;
      else
        select constraint_row.id into v_constraint
        from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=v_employee and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind='UNAVAILABLE'
          and constraint_row.source='GRAFIK_PRO'
          and constraint_row.time_range && tstzrange(v_start,v_end,'[)')
        order by constraint_row.created_at desc limit 1;
      end if;
      insert into public.employee_requests_v1(
        id,employee_id,requested_by,request_type,date_from,date_to,requested_range,
        status,requires_decision,note,constraint_id,legacy_review_id
      ) values(v_id,v_employee,v_actor,v_type,v_day,v_day,tstzrange(v_start,v_end,'[)'),
        case when v_legacy is null then 'AUTO_APPLIED' else 'PENDING' end,
        v_legacy is not null,nullif(trim(p_note),''),v_constraint,v_legacy);
      if v_legacy is not null then
        delete from public.notifications notification
        where notification.title='HOT DAY: prośba o niedostępność'
          and notification.body='Pracownik zgłosił twardą niedostępność na '||v_day::text||'. Limit dla roli został osiągnięty.'
          and notification.created_at>=transaction_timestamp();
        insert into public.notifications(
          recipient_id,title,body,kind,context_type,context_id,action_route,action_required
        ) select recipient.auth_user_id,'Limit nieobecności przekroczony',
          'Twarda nieobecność na '||v_day::text||' przekracza limit. Otwórz sprawę i podejmij decyzję.',
          'ACTION_REQUIRED','EMPLOYEE_REQUEST',v_id::text,'/profile?tab=inbox',true
        from public.personal_request_manager_recipients_uat_v1(v_employee) recipient;
        v_pending:=v_pending+1;
      else
        v_saved:=v_saved+1;
      end if;
      v_request_ids:=v_request_ids||jsonb_build_array(v_id);
    end loop;
  end if;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'employee_request_v1',v_employee::text,'SUBMIT',jsonb_build_object(
    'requestType',v_type,'dates',to_jsonb(p_dates),'requestIds',v_request_ids,
    'saved',v_saved,'pending',v_pending));
  return jsonb_build_object('requestType',v_type,'requestIds',v_request_ids,
    'saved',v_saved,'pending',v_pending);
end;
$$;

create or replace function public.employee_request_review_uat_v1(
  p_request_id uuid,p_decision text,p_reason text default null
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid:=auth.uid();
  v_request public.employee_requests_v1%rowtype;
  v_decision text:=upper(trim(coalesce(p_decision,'')));
  v_constraint uuid;
  v_status text;
  v_employee_user uuid;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into v_request from public.employee_requests_v1 request_row
  where request_row.id=p_request_id for update;
  if v_request.id is null then raise exception 'EMPLOYEE_REQUEST_NOT_FOUND'; end if;
  select employee.auth_user_id into v_employee_user from public.employees employee
  where employee.id=v_request.employee_id;
  if v_employee_user=v_actor or not public.matrix_v2_can_manage_employee(v_request.employee_id) then
    raise exception 'FORBIDDEN';
  end if;
  if v_request.request_type='SICKNESS' then
    if v_request.status<>'APPLIED' then raise exception 'REQUEST_ALREADY_RESOLVED'; end if;
    if v_decision<>'ACKNOWLEDGE' then raise exception 'SICKNESS_CANNOT_BE_REJECTED'; end if;
    v_status:='ACKNOWLEDGED';
  else
    if v_request.status<>'PENDING' then raise exception 'REQUEST_ALREADY_RESOLVED'; end if;
    if v_decision not in ('APPROVE','REJECT') then raise exception 'INVALID_REVIEW_DECISION'; end if;
    if v_decision='REJECT' and length(trim(coalesce(p_reason,'')))<3 then
      raise exception 'REVIEW_REASON_REQUIRED';
    end if;
    v_status:=case when v_decision='APPROVE' then 'APPROVED' else 'REJECTED' end;
    if v_request.request_type='LEAVE' and v_decision='APPROVE' then
      v_constraint:=gen_random_uuid();
      insert into public.employee_time_constraints_v2(
        id,employee_id,constraint_kind,time_range,source,source_record_key,
        priority,editable_by_employee,status,note,created_by
      ) values(v_constraint,v_request.employee_id,'LEAVE',v_request.requested_range,
        'EMPLOYEE_LEAVE_REQUEST','employee-request:'||v_request.id::text,500,false,
        'ACTIVE',v_request.note,v_actor);
    elsif v_request.request_type='HARD_UNAVAILABLE' then
      if v_request.legacy_review_id is null then raise exception 'HARD_REVIEW_NOT_FOUND'; end if;
      if v_decision='APPROVE' then
        v_constraint:=gen_random_uuid();
        insert into public.employee_time_constraints_v2(
          id,employee_id,constraint_kind,time_range,source,source_record_key,
          priority,editable_by_employee,status,note,created_by
        ) values(v_constraint,v_request.employee_id,'UNAVAILABLE',v_request.requested_range,
          'HOT_DAY_APPROVED','hot-day-review:'||v_request.legacy_review_id::text,100,false,
          'ACTIVE',v_request.note,v_actor);
      end if;
      update public.availability_exception_reviews_v2 set
        status=case when v_decision='APPROVE' then 'APPROVED' else 'REJECTED' end,
        reviewed_by=v_actor,reviewed_at=now(),review_reason=coalesce(nullif(trim(p_reason),''),'Decyzja lidera'),
        constraint_id=v_constraint
      where id=v_request.legacy_review_id and status='PENDING';
      if not found then raise exception 'HARD_REVIEW_ALREADY_RESOLVED'; end if;
    end if;
  end if;
  update public.employee_requests_v1 set status=v_status,reviewed_by=v_actor,
    reviewed_at=now(),review_reason=nullif(trim(p_reason),''),
    constraint_id=coalesce(v_constraint,constraint_id),updated_at=now()
  where id=v_request.id;
  update public.notifications set resolved_at=now(),resolution=v_status
  where context_type='EMPLOYEE_REQUEST'
    and context_id=v_request.id::text and resolved_at is null;
  if v_employee_user is not null then
    insert into public.notifications(
      recipient_id,title,body,kind,context_type,context_id,action_route,action_required
    ) values(v_employee_user,
      case when v_request.request_type='SICKNESS' then 'L4 przyjęte do wiadomości'
        else 'Decyzja dotycząca nieobecności' end,
      case when v_request.request_type='SICKNESS' then 'Lider potwierdził odbiór zgłoszenia L4.'
        when v_status='APPROVED' then 'Twoja nieobecność została zaakceptowana.'
        else 'Twoja prośba nie została zaakceptowana: '||coalesce(nullif(trim(p_reason),''),'bez dodatkowego uzasadnienia') end,
      'DECISION','EMPLOYEE_REQUEST',v_request.id::text,
      '/my-schedule?month='||to_char(v_request.date_from,'YYYY-MM'),false);
  end if;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'employee_request_v1',v_request.id::text,v_decision,jsonb_build_object(
    'employeeId',v_request.employee_id,'requestType',v_request.request_type,
    'status',v_status,'reason',nullif(trim(p_reason),''),'constraintId',v_constraint));
  return jsonb_build_object('id',v_request.id,'status',v_status,'constraintId',v_constraint);
end;
$$;

create or replace function public.personal_action_workspace_uat_v1()
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare
  v_actor uuid:=auth.uid();
  v_result jsonb;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select jsonb_build_object(
    'unreadCount',(select count(*) from public.notifications notification
      where notification.recipient_id=v_actor and notification.read_at is null),
    'actionCount',(select count(*) from public.notifications notification
      where notification.recipient_id=v_actor and notification.action_required
        and notification.resolved_at is null),
    'notifications',coalesce((select jsonb_agg(jsonb_build_object(
      'id',notification.id,'kind',notification.kind,'title',notification.title,
      'body',notification.body,'actionRoute',notification.action_route,
      'actionRequired',notification.action_required,'readAt',notification.read_at,
      'resolvedAt',notification.resolved_at,'createdAt',notification.created_at
    ) order by notification.action_required desc,notification.created_at desc)
      from (select * from public.notifications own_notification
        where own_notification.recipient_id=v_actor
        order by own_notification.action_required desc,own_notification.created_at desc
        limit 40) notification),'[]'::jsonb),
    'managerInbox',coalesce((select jsonb_agg(jsonb_build_object(
      'id',request_row.id,'requestType',request_row.request_type,
      'employeeId',request_row.employee_id,
      'employeeName',employee.first_name||' '||employee.last_name,
      'employeeNo',employee.employee_no,'dateFrom',request_row.date_from,
      'dateTo',request_row.date_to,'status',request_row.status,
      'note',request_row.note,'createdAt',request_row.created_at
    ) order by request_row.created_at)
      from public.employee_requests_v1 request_row
      join public.employees employee on employee.id=request_row.employee_id
      where request_row.status in ('PENDING','APPLIED')
        and request_row.requires_decision
        and employee.auth_user_id is distinct from v_actor
        and public.matrix_v2_can_manage_employee(request_row.employee_id)),'[]'::jsonb),
    'myRequests',coalesce((select jsonb_agg(jsonb_build_object(
      'id',request_row.id,'requestType',request_row.request_type,
      'dateFrom',request_row.date_from,'dateTo',request_row.date_to,
      'status',request_row.status,'note',request_row.note,
      'reviewReason',request_row.review_reason,'createdAt',request_row.created_at
    ) order by request_row.created_at desc)
      from public.employee_requests_v1 request_row
      where request_row.requested_by=v_actor),'[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

create or replace function public.personal_notification_mark_read_uat_v1(p_notification_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_read timestamptz;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  update public.notifications set read_at=coalesce(read_at,now())
  where id=p_notification_id and recipient_id=v_actor returning read_at into v_read;
  if v_read is null then raise exception 'NOTIFICATION_NOT_FOUND'; end if;
  return jsonb_build_object('id',p_notification_id,'readAt',v_read);
end;
$$;

-- The chosen cat follows the user into team conversations.  Photo objects stay
-- private to their owner; messages expose only the safe avatar mode and cat key.
create or replace function public.message_display_name_uat_v1(p_auth_user_id uuid)
returns text language sql stable security definer set search_path=''
as $$
  select coalesce(
    (select nullif(trim(profile.display_name),'') from public.user_profiles_v1 profile
      where profile.auth_user_id=p_auth_user_id),
    (select nullif(trim(employee.first_name||' '||employee.last_name),'')
      from public.employees employee where employee.auth_user_id=p_auth_user_id limit 1),
    (select auth_user.email from auth.users auth_user where auth_user.id=p_auth_user_id),
    'Użytkownik SZAFUNEK'
  );
$$;

create or replace function public.personal_message_action_route_uat_v1(
  p_auth_user_id uuid,p_conversation_id uuid
) returns text language sql stable security definer set search_path=''
as $$
  select case when
    exists(select 1 from public.user_permissions permission
      where permission.auth_user_id=p_auth_user_id
        and permission.app_role in ('OWNER','ADMIN','HR_FINANCE','ROLE_MANAGER','LOCATION_MANAGER','VERIFIER'))
    or exists(select 1 from public.matrix_scope_grants_v2 grant_row
      where grant_row.auth_user_id=p_auth_user_id and grant_row.active
        and grant_row.app_role in ('ROLE_MANAGER','LOCATION_MANAGER','VERIFIER'))
    then '/operations?view=wiadomosci&conversation='||p_conversation_id::text
    else '/messages?conversation='||p_conversation_id::text end;
$$;

create or replace function public.message_center_workspace_uat_v1()
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_user uuid:=auth.uid();
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  return jsonb_build_object(
    'currentUserId',v_user,
    'contacts',coalesce((
      select jsonb_agg(jsonb_build_object(
        'authUserId',source.auth_user_id,'employeeId',source.employee_id,
        'name',source.display_name,'email',source.email,
        'employeeNo',source.employee_no,'roleName',source.role_name,
        'avatarMode',source.avatar_mode,'catAvatarKey',source.cat_avatar_key
      ) order by source.display_name)
      from (
        select distinct on (directory.auth_user_id) directory.auth_user_id,
          employee.id employee_id,
          coalesce(nullif(trim(profile.display_name),''),
            nullif(trim(employee.first_name||' '||employee.last_name),''),directory.email) display_name,
          directory.email,employee.employee_no,coalesce(role_row.name,directory.app_role::text) role_name,
          coalesce(profile.avatar_mode,'INITIALS') avatar_mode,profile.cat_avatar_key
        from public.application_access_directory_v1 directory
        left join public.employees employee on employee.auth_user_id=directory.auth_user_id
        left join public.user_profiles_v1 profile on profile.auth_user_id=directory.auth_user_id
        left join lateral (
          select role_item.name from public.matrix_employee_roles_v2 employee_role
          join public.matrix_roles_v2 role_item on role_item.id=employee_role.role_id
          where employee_role.employee_id=employee.id and employee_role.active
          order by employee_role.is_primary desc limit 1
        ) role_row on true
        where directory.active and directory.auth_user_id is not null
          and directory.auth_user_id<>v_user
        order by directory.auth_user_id,(employee.id is not null) desc,directory.app_role::text
      ) source
    ),'[]'::jsonb),
    'conversations',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',conversation.id,'subject',conversation.subject,'kind',conversation.kind,
        'contextType',conversation.context_type,'contextId',conversation.context_id,
        'updatedAt',conversation.updated_at,
        'unreadCount',(select count(*) from public.team_messages_v1 unread
          where unread.conversation_id=conversation.id and unread.sender_user_id<>v_user
            and unread.created_at>coalesce(own_member.last_read_at,'epoch'::timestamptz)),
        'lastMessage',(select message.body from public.team_messages_v1 message
          where message.conversation_id=conversation.id order by message.created_at desc limit 1),
        'members',(select coalesce(jsonb_agg(jsonb_build_object(
          'authUserId',member.auth_user_id,
          'name',public.message_display_name_uat_v1(member.auth_user_id),
          'avatarMode',coalesce(profile.avatar_mode,'INITIALS'),
          'catAvatarKey',profile.cat_avatar_key
        ) order by public.message_display_name_uat_v1(member.auth_user_id)),'[]'::jsonb)
          from public.team_conversation_members_v1 member
          left join public.user_profiles_v1 profile on profile.auth_user_id=member.auth_user_id
          where member.conversation_id=conversation.id)
      ) order by conversation.updated_at desc)
      from public.team_conversation_members_v1 own_member
      join public.team_conversations_v1 conversation on conversation.id=own_member.conversation_id
      where own_member.auth_user_id=v_user
    ),'[]'::jsonb),
    'messages',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',message.id,'conversationId',message.conversation_id,
        'senderUserId',message.sender_user_id,
        'senderName',public.message_display_name_uat_v1(message.sender_user_id),
        'senderAvatarMode',coalesce(profile.avatar_mode,'INITIALS'),
        'senderCatAvatarKey',profile.cat_avatar_key,
        'body',message.body,'createdAt',message.created_at
      ) order by message.created_at)
      from public.team_messages_v1 message
      left join public.user_profiles_v1 profile on profile.auth_user_id=message.sender_user_id
      where exists(select 1 from public.team_conversation_members_v1 member
        where member.conversation_id=message.conversation_id and member.auth_user_id=v_user)
    ),'[]'::jsonb)
  );
end;
$$;

create or replace function public.message_conversation_create_uat_v1(
  p_recipient_auth_user_id uuid,p_subject text,p_message text,
  p_context_type text default null,p_context_id uuid default null
) returns jsonb language plpgsql volatile security definer set search_path=''
as $$
declare
  v_user uuid:=auth.uid();v_conversation uuid;v_employee uuid;
  v_subject text:=coalesce(nullif(trim(p_subject),''),'Rozmowa zespołu');
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_recipient_auth_user_id is null or p_recipient_auth_user_id=v_user then
    raise exception 'RECIPIENT_NOT_FOUND';
  end if;
  if nullif(trim(p_message),'') is null then raise exception 'EMPTY_MESSAGE'; end if;
  if not exists(select 1 from public.application_access_directory_v1 directory
    where directory.auth_user_id=p_recipient_auth_user_id and directory.active) then
    raise exception 'RECIPIENT_NOT_FOUND';
  end if;
  insert into public.team_conversations_v1(kind,subject,context_type,context_id,created_by)
  values(case when p_context_type='SWAP' then 'SWAP' else 'DIRECT' end,
    v_subject,p_context_type,p_context_id,v_user) returning id into v_conversation;
  select employee.id into v_employee from public.employees employee
    where employee.auth_user_id=v_user limit 1;
  insert into public.team_conversation_members_v1(conversation_id,auth_user_id,employee_id,last_read_at)
  values(v_conversation,v_user,v_employee,now());
  select employee.id into v_employee from public.employees employee
    where employee.auth_user_id=p_recipient_auth_user_id limit 1;
  insert into public.team_conversation_members_v1(conversation_id,auth_user_id,employee_id)
  values(v_conversation,p_recipient_auth_user_id,v_employee);
  insert into public.team_messages_v1(conversation_id,sender_user_id,body)
  values(v_conversation,v_user,trim(p_message));
  insert into public.notifications(
    recipient_id,title,body,kind,context_type,context_id,action_route,action_required
  ) values(
    p_recipient_auth_user_id,
    'Nowa wiadomość od '||public.message_display_name_uat_v1(v_user),
    v_subject||': '||left(trim(p_message),240),'MESSAGE','TEAM_CONVERSATION',
    v_conversation::text,
    public.personal_message_action_route_uat_v1(p_recipient_auth_user_id,v_conversation),false
  );
  return jsonb_build_object('conversationId',v_conversation);
end;
$$;

create or replace function public.message_send_uat_v1(p_conversation_id uuid,p_body text)
returns jsonb language plpgsql volatile security definer set search_path=''
as $$
declare
  v_user uuid:=auth.uid();v_message uuid;v_recipient uuid;v_subject text;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if nullif(trim(p_body),'') is null then raise exception 'EMPTY_MESSAGE'; end if;
  if not exists(select 1 from public.team_conversation_members_v1 member
    where member.conversation_id=p_conversation_id and member.auth_user_id=v_user) then
    raise exception 'CONVERSATION_FORBIDDEN';
  end if;
  insert into public.team_messages_v1(conversation_id,sender_user_id,body)
  values(p_conversation_id,v_user,trim(p_body)) returning id into v_message;
  update public.team_conversations_v1 set updated_at=now()
    where id=p_conversation_id returning subject into v_subject;
  update public.team_conversation_members_v1 set last_read_at=now()
    where conversation_id=p_conversation_id and auth_user_id=v_user;
  for v_recipient in select member.auth_user_id
    from public.team_conversation_members_v1 member
    where member.conversation_id=p_conversation_id and member.auth_user_id<>v_user
  loop
    update public.notifications set
      title='Nowa wiadomość od '||public.message_display_name_uat_v1(v_user),
      body=v_subject||': '||left(trim(p_body),240),kind='MESSAGE',
      action_route=public.personal_message_action_route_uat_v1(v_recipient,p_conversation_id),
      read_at=null,resolved_at=null,resolution=null,created_at=now()
    where recipient_id=v_recipient and context_type='TEAM_CONVERSATION'
      and context_id=p_conversation_id::text and resolved_at is null;
    if not found then
      insert into public.notifications(
        recipient_id,title,body,kind,context_type,context_id,action_route,action_required
      ) values(v_recipient,
        'Nowa wiadomość od '||public.message_display_name_uat_v1(v_user),
        v_subject||': '||left(trim(p_body),240),'MESSAGE','TEAM_CONVERSATION',
        p_conversation_id::text,
        public.personal_message_action_route_uat_v1(v_recipient,p_conversation_id),false);
    end if;
  end loop;
  return jsonb_build_object('messageId',v_message);
end;
$$;

create or replace function public.message_mark_read_uat_v1(p_conversation_id uuid)
returns boolean language plpgsql volatile security definer set search_path=''
as $$
declare v_user uuid:=auth.uid();
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  update public.team_conversation_members_v1 set last_read_at=now()
  where conversation_id=p_conversation_id and auth_user_id=v_user;
  if not found then raise exception 'CONVERSATION_FORBIDDEN'; end if;
  update public.notifications set read_at=coalesce(read_at,now()),resolved_at=now(),resolution='READ'
  where recipient_id=v_user and context_type='TEAM_CONVERSATION'
    and context_id=p_conversation_id::text and resolved_at is null;
  return true;
end;
$$;

revoke all on function public.personal_request_manager_recipients_uat_v1(uuid),
  public.personal_message_action_route_uat_v1(uuid,uuid),
  public.personal_profile_workspace_uat_v1(),
  public.personal_profile_save_uat_v1(text,text,text,text,text,jsonb),
  public.employee_request_submit_uat_v1(text,date[],boolean,time,time,text),
  public.employee_request_review_uat_v1(uuid,text,text),
  public.personal_action_workspace_uat_v1(),
  public.personal_notification_mark_read_uat_v1(uuid)
  from public,anon,authenticated;
grant execute on function public.personal_profile_workspace_uat_v1(),
  public.personal_profile_save_uat_v1(text,text,text,text,text,jsonb),
  public.employee_request_submit_uat_v1(text,date[],boolean,time,time,text),
  public.employee_request_review_uat_v1(uuid,text,text),
  public.personal_action_workspace_uat_v1(),
  public.personal_notification_mark_read_uat_v1(uuid)
  to authenticated;

revoke all on function public.message_display_name_uat_v1(uuid),
  public.message_center_workspace_uat_v1(),
  public.message_conversation_create_uat_v1(uuid,text,text,text,uuid),
  public.message_send_uat_v1(uuid,text),
  public.message_mark_read_uat_v1(uuid)
  from public,anon,authenticated;
grant execute on function public.message_center_workspace_uat_v1(),
  public.message_conversation_create_uat_v1(uuid,text,text,text,uuid),
  public.message_send_uat_v1(uuid,text),
  public.message_mark_read_uat_v1(uuid)
  to authenticated;

notify pgrst,'reload schema';
