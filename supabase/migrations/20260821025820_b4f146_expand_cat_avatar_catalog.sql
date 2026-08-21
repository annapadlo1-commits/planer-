-- B4F-146: extend the personal avatar catalogue from CAT_01..CAT_50 to CAT_01..CAT_55.

alter table public.user_profiles_v1
  drop constraint if exists user_profiles_v1_cat_avatar_key_check;

alter table public.user_profiles_v1
  add constraint user_profiles_v1_cat_avatar_key_check
  check (cat_avatar_key is null or cat_avatar_key ~ '^CAT_(0[1-9]|[1-4][0-9]|5[0-5])$');

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
  if v_mode='CAT' and v_cat !~ '^CAT_(0[1-9]|[1-4][0-9]|5[0-5])$' then
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

revoke all on function public.personal_profile_save_uat_v1(text,text,text,text,text,jsonb) from public,anon;
grant execute on function public.personal_profile_save_uat_v1(text,text,text,text,text,jsonb) to authenticated,service_role;
