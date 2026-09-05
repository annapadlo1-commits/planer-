-- UAT-006 regression: an unpublished month must return a valid EMPTY ORTOOLS
-- workspace rather than `workspace: null`.  All fixture writes are rolled back.

begin;

do $$
declare
  v_definition text;
begin
  v_definition:=pg_get_functiondef(
    'public.optimizer_operational_workspace_alpha16(date)'::regprocedure
  );
  if position('optimizer_active_workspace_v2(v_month)' in v_definition)=0 then
    raise exception 'UAT006_OPERATIONAL_EMPTY_DELEGATION_MISSING';
  end if;
  if has_function_privilege(
      'anon','public.optimizer_operational_workspace_alpha16(date)','execute')
    or not has_function_privilege(
      'authenticated','public.optimizer_operational_workspace_alpha16(date)','execute') then
    raise exception 'UAT006_OPERATIONAL_WORKSPACE_GRANTS_INVALID';
  end if;
end;
$$;

insert into auth.users(
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,is_super_admin,created_at,updated_at
) values(
  '00000000-0000-0000-0000-000000000000',
  'a1600000-0000-4000-8000-000000000006',
  'authenticated','authenticated','uat006-empty-workspace@example.invalid','',now(),
  '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,false,now(),now()
);
insert into public.user_permissions(auth_user_id,app_role)
values('a1600000-0000-4000-8000-000000000006','OWNER');

select set_config(
  'request.jwt.claim.sub','a1600000-0000-4000-8000-000000000006',true
);
select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;

do $$
declare
  v_result jsonb;
  v_workspace jsonb;
begin
  v_result:=public.optimizer_operational_workspace_alpha16('2099-12-01'::date);
  v_workspace:=v_result->'workspace';
  if v_workspace is null or jsonb_typeof(v_workspace)<>'object' then
    raise exception 'UAT006_OPERATIONAL_WORKSPACE_NULL';
  end if;
  if v_workspace->>'engine'<>'ORTOOLS_V2'
    or v_workspace#>>'{context,type}'<>'PUBLISHED_SCHEDULE'
    or v_workspace#>>'{context,status}'<>'EMPTY'
    or v_workspace#>>'{context,month}'<>'2099-12-01' then
    raise exception 'UAT006_OPERATIONAL_EMPTY_CONTEXT_INVALID:%',v_workspace;
  end if;
  if v_workspace->'variants'<>'[]'::jsonb
    or v_workspace->'shifts'<>'[]'::jsonb
    or v_workspace->'issues'<>'[]'::jsonb
    or v_workspace->'finance'<>'null'::jsonb
    or v_result->'overrides'<>'[]'::jsonb then
    raise exception 'UAT006_OPERATIONAL_EMPTY_PAYLOAD_INVALID:%',v_result;
  end if;
end;
$$;

rollback;
