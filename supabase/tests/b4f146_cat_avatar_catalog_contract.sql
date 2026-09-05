-- B4F-146 executable contract. Every fixture and mutation is rolled back.

begin;

insert into auth.users(
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,is_super_admin,created_at,updated_at
) values (
  '00000000-0000-0000-0000-000000000000',
  'b4f10000-0000-4000-8000-000000000146',
  'authenticated','authenticated','cat-55@example.invalid','',now(),
  '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,false,now(),now()
);

insert into public.user_permissions(auth_user_id,app_role)
values('b4f10000-0000-4000-8000-000000000146','EMPLOYEE');

select set_config('request.jwt.claim.sub','b4f10000-0000-4000-8000-000000000146',true);
select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;

do $$
declare v_profile jsonb;
begin
  v_profile:=public.personal_profile_save_uat_v1(
    'Kot Kosmonauta','CAT','CAT_55','#A6B3A0',null,'{}'::jsonb
  );
  if v_profile->'profile'->>'catAvatarKey'<>'CAT_55' then
    raise exception 'CAT_55_ROUND_TRIP_FAILED: %',v_profile;
  end if;
  begin
    perform public.personal_profile_save_uat_v1(
      'Kot spoza katalogu','CAT','CAT_56','#A6B3A0',null,'{}'::jsonb
    );
    raise exception 'CAT_56_UNEXPECTEDLY_ACCEPTED';
  exception when others then
    if sqlerrm not like '%INVALID_CAT_AVATAR%' then raise; end if;
  end;
end;
$$;

reset role;

do $$
begin
  begin
    update public.user_profiles_v1 set cat_avatar_key='CAT_56'
    where auth_user_id='b4f10000-0000-4000-8000-000000000146';
    raise exception 'CAT_56_DIRECT_WRITE_UNEXPECTEDLY_ACCEPTED';
  exception when check_violation then null;
  end;
end;
$$;

select 'B4F-146 CAT_AVATAR_CATALOG_CONTRACT_PASS' as result;

rollback;
