-- UAT next batch: private, auditable team communication. The Supabase CLI is
-- unavailable in the bundled workspace, so this timestamped migration follows
-- the existing repository convention and is applied only to the isolated UAT.

create table if not exists public.team_conversations_v1 (
  id uuid primary key default gen_random_uuid(),
  kind text not null default 'DIRECT' check (kind in ('DIRECT','SWAP','ANNOUNCEMENT')),
  subject text not null check (char_length(subject) between 1 and 160),
  context_type text,
  context_id uuid,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.team_conversation_members_v1 (
  conversation_id uuid not null references public.team_conversations_v1(id) on delete cascade,
  auth_user_id uuid not null references auth.users(id) on delete cascade,
  employee_id uuid references public.employees(id) on delete set null,
  joined_at timestamptz not null default now(),
  last_read_at timestamptz,
  primary key (conversation_id,auth_user_id)
);

create table if not exists public.team_messages_v1 (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.team_conversations_v1(id) on delete cascade,
  sender_user_id uuid not null references auth.users(id) on delete restrict,
  body text not null check (char_length(trim(body)) between 1 and 2000),
  created_at timestamptz not null default now(),
  edited_at timestamptz
);

create index if not exists team_conversation_members_v1_user_idx
  on public.team_conversation_members_v1(auth_user_id,conversation_id);
create index if not exists team_messages_v1_conversation_created_idx
  on public.team_messages_v1(conversation_id,created_at);

alter table public.team_conversations_v1 enable row level security;
alter table public.team_conversation_members_v1 enable row level security;
alter table public.team_messages_v1 enable row level security;

revoke all on table public.team_conversations_v1 from public,anon,authenticated;
revoke all on table public.team_conversation_members_v1 from public,anon,authenticated;
revoke all on table public.team_messages_v1 from public,anon,authenticated;
grant all on table public.team_conversations_v1 to service_role;
grant all on table public.team_conversation_members_v1 to service_role;
grant all on table public.team_messages_v1 to service_role;

-- No direct client policies are created deliberately.  The only application
-- boundary is the authenticated RPC layer below, which validates membership
-- for every read and write.  service_role retains maintenance access.

create or replace function public.message_display_name_uat_v1(p_auth_user_id uuid)
returns text language sql stable security definer set search_path=''
as $$
  select coalesce(
    (select nullif(trim(e.first_name||' '||e.last_name),'') from public.employees e where e.auth_user_id=p_auth_user_id limit 1),
    (select u.email from auth.users u where u.id=p_auth_user_id),
    'Użytkownik GRAFIK PRO'
  );
$$;
revoke all on function public.message_display_name_uat_v1(uuid) from public,anon,authenticated;
grant execute on function public.message_display_name_uat_v1(uuid) to service_role;

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
        'authUserId',source.auth_user_id,
        'employeeId',source.employee_id,
        'name',source.display_name,
        'email',source.email,
        'employeeNo',source.employee_no,
        'roleName',source.role_name
      ) order by source.display_name)
      from (
        select distinct on (d.auth_user_id) d.auth_user_id,e.id employee_id,
          coalesce(nullif(trim(e.first_name||' '||e.last_name),''),d.email) display_name,
          d.email,e.employee_no,coalesce(r.name,d.app_role::text) role_name
        from public.application_access_directory_v1 d
        left join public.employees e on e.auth_user_id=d.auth_user_id
        left join lateral (
          select role.name from public.matrix_employee_roles_v2 er
          join public.matrix_roles_v2 role on role.id=er.role_id
          where er.employee_id=e.id and er.active order by er.is_primary desc limit 1
        ) r on true
        where d.active and d.auth_user_id is not null and d.auth_user_id<>v_user
        order by d.auth_user_id,(e.id is not null) desc,d.app_role::text
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
          'authUserId',member.auth_user_id,'name',public.message_display_name_uat_v1(member.auth_user_id)
        ) order by public.message_display_name_uat_v1(member.auth_user_id)),'[]'::jsonb)
          from public.team_conversation_members_v1 member where member.conversation_id=conversation.id)
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
        'body',message.body,'createdAt',message.created_at
      ) order by message.created_at)
      from public.team_messages_v1 message
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
declare v_user uuid:=auth.uid(); v_conversation uuid; v_employee uuid;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_recipient_auth_user_id is null or p_recipient_auth_user_id=v_user then raise exception 'RECIPIENT_NOT_FOUND'; end if;
  if nullif(trim(p_message),'') is null then raise exception 'EMPTY_MESSAGE'; end if;
  if not exists(select 1 from public.application_access_directory_v1 d
    where d.auth_user_id=p_recipient_auth_user_id and d.active) then raise exception 'RECIPIENT_NOT_FOUND'; end if;
  insert into public.team_conversations_v1(kind,subject,context_type,context_id,created_by)
  values(case when p_context_type='SWAP' then 'SWAP' else 'DIRECT' end,
    coalesce(nullif(trim(p_subject),''),'Rozmowa zespołu'),p_context_type,p_context_id,v_user)
  returning id into v_conversation;
  select e.id into v_employee from public.employees e where e.auth_user_id=v_user limit 1;
  insert into public.team_conversation_members_v1(conversation_id,auth_user_id,employee_id,last_read_at)
  values(v_conversation,v_user,v_employee,now());
  select e.id into v_employee from public.employees e where e.auth_user_id=p_recipient_auth_user_id limit 1;
  insert into public.team_conversation_members_v1(conversation_id,auth_user_id,employee_id)
  values(v_conversation,p_recipient_auth_user_id,v_employee);
  insert into public.team_messages_v1(conversation_id,sender_user_id,body)
  values(v_conversation,v_user,trim(p_message));
  return jsonb_build_object('conversationId',v_conversation);
end;
$$;

create or replace function public.message_send_uat_v1(p_conversation_id uuid,p_body text)
returns jsonb language plpgsql volatile security definer set search_path=''
as $$
declare v_user uuid:=auth.uid(); v_message uuid;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if nullif(trim(p_body),'') is null then raise exception 'EMPTY_MESSAGE'; end if;
  if not exists(select 1 from public.team_conversation_members_v1 member
    where member.conversation_id=p_conversation_id and member.auth_user_id=v_user) then raise exception 'CONVERSATION_FORBIDDEN'; end if;
  insert into public.team_messages_v1(conversation_id,sender_user_id,body)
    values(p_conversation_id,v_user,trim(p_body)) returning id into v_message;
  update public.team_conversations_v1 set updated_at=now() where id=p_conversation_id;
  update public.team_conversation_members_v1 set last_read_at=now()
    where conversation_id=p_conversation_id and auth_user_id=v_user;
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
  return true;
end;
$$;

revoke all on function public.message_center_workspace_uat_v1() from public,anon;
revoke all on function public.message_conversation_create_uat_v1(uuid,text,text,text,uuid) from public,anon;
revoke all on function public.message_send_uat_v1(uuid,text) from public,anon;
revoke all on function public.message_mark_read_uat_v1(uuid) from public,anon;
grant execute on function public.message_center_workspace_uat_v1() to authenticated;
grant execute on function public.message_conversation_create_uat_v1(uuid,text,text,text,uuid) to authenticated;
grant execute on function public.message_send_uat_v1(uuid,text) to authenticated;
grant execute on function public.message_mark_read_uat_v1(uuid) to authenticated;

notify pgrst, 'reload schema';
