-- B4F-52/B4F-101: the owner decides what every application role can see.
-- The policy is intentionally separate from employment and schedule roles.

create table if not exists public.application_finance_visibility_policy_v1 (
  app_role public.app_role primary key,
  visibility text not null check (visibility in ('NONE','BUDGET_ONLY','AGGREGATE','FULL')),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

alter table public.application_finance_visibility_policy_v1 enable row level security;
revoke all on table public.application_finance_visibility_policy_v1 from public,anon,authenticated;
grant all on table public.application_finance_visibility_policy_v1 to service_role;

insert into public.application_finance_visibility_policy_v1(app_role,visibility)
values
  ('OWNER','FULL'),('ADMIN','AGGREGATE'),('HR_FINANCE','FULL'),
  ('ROLE_MANAGER','BUDGET_ONLY'),('LOCATION_MANAGER','BUDGET_ONLY'),
  ('VERIFIER','BUDGET_ONLY'),('EMPLOYEE','NONE')
on conflict(app_role) do nothing;

create or replace function public.application_finance_visibility_current_uat_v1()
returns text language plpgsql stable security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_visibility text;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select p.visibility into v_visibility
  from public.application_finance_visibility_policy_v1 p
  where p.app_role in (
    select up.app_role from public.user_permissions up where up.auth_user_id=v_actor
    union
    select grant_row.app_role from public.matrix_scope_grants_v2 grant_row
      where grant_row.auth_user_id=v_actor and grant_row.active
  )
  order by case p.visibility when 'FULL' then 4 when 'AGGREGATE' then 3 when 'BUDGET_ONLY' then 2 else 1 end desc
  limit 1;
  return coalesce(v_visibility,'NONE');
end;
$$;

create or replace function public.application_finance_visibility_policy_uat_v1()
returns jsonb language plpgsql stable security definer set search_path=''
as $$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.has_app_role('OWNER') then raise exception 'ACCESS_POLICY_VIEW_FORBIDDEN'; end if;
  return jsonb_build_object(
    'levels',jsonb_build_array('NONE','BUDGET_ONLY','AGGREGATE','FULL'),
    'policies',coalesce((select jsonb_agg(jsonb_build_object(
      'appRole',p.app_role::text,'visibility',p.visibility,'updatedAt',p.updated_at
    ) order by p.app_role::text) from public.application_finance_visibility_policy_v1 p),'[]'::jsonb)
  );
end;
$$;

create or replace function public.application_finance_visibility_save_uat_v1(
  p_app_role text,p_visibility text
) returns jsonb language plpgsql volatile security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_role public.app_role; v_visibility text:=upper(trim(coalesce(p_visibility,'')));
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.has_app_role('OWNER') then raise exception 'ACCESS_POLICY_EDIT_FORBIDDEN'; end if;
  begin v_role:=upper(trim(coalesce(p_app_role,'')))::public.app_role;
  exception when invalid_text_representation then raise exception 'INVALID_APPLICATION_ROLE'; end;
  if v_visibility not in ('NONE','BUDGET_ONLY','AGGREGATE','FULL') then raise exception 'INVALID_FINANCE_VISIBILITY'; end if;

  insert into public.application_finance_visibility_policy_v1(app_role,visibility,updated_by,updated_at)
  values(v_role,v_visibility,v_actor,now())
  on conflict(app_role) do update set visibility=excluded.visibility,updated_by=v_actor,updated_at=now();

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'application_finance_visibility_policy_v1',v_role::text,'VISIBILITY_CHANGED',jsonb_build_object('visibility',v_visibility));
  return jsonb_build_object('appRole',v_role::text,'visibility',v_visibility);
end;
$$;

revoke all on function public.application_finance_visibility_current_uat_v1() from public,anon;
revoke all on function public.application_finance_visibility_policy_uat_v1() from public,anon;
revoke all on function public.application_finance_visibility_save_uat_v1(text,text) from public,anon;
grant execute on function public.application_finance_visibility_current_uat_v1() to authenticated;
grant execute on function public.application_finance_visibility_policy_uat_v1() to authenticated;
grant execute on function public.application_finance_visibility_save_uat_v1(text,text) to authenticated;
