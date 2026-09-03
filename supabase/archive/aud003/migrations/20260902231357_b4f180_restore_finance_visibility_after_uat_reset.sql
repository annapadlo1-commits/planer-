-- B4F-180: restore the B4F-52 finance visibility defaults erased by the
-- isolated UAT full reset, and keep every future B4F-171 reset complete.
-- Existing owner customisations are preserved outside a full reset.

insert into public.application_finance_visibility_policy_v1(app_role,visibility)
values
  ('OWNER','FULL'),
  ('ADMIN','AGGREGATE'),
  ('HR_FINANCE','FULL'),
  ('ROLE_MANAGER','BUDGET_ONLY'),
  ('LOCATION_MANAGER','BUDGET_ONLY'),
  ('VERIFIER','BUDGET_ONLY'),
  ('EMPLOYEE','NONE')
on conflict(app_role) do nothing;

create or replace function public.uat_full_business_reset_v1(p_confirmation text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_actor uuid:=auth.uid();
  v_enabled boolean:=false;
  v_email text;
  v_tables text;
  v_draft uuid;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.has_app_role('OWNER') then raise exception 'FORBIDDEN'; end if;
  select c.enabled into v_enabled from public.uat_environment_controls c
    where c.control_key='ISOLATED_UAT_DESTRUCTIVE_TOOLS'
      and c.config->>'environment'='ISOLATED_UAT'
      and c.config->>'projectRef'='nhthrtpkfpmufmrmdyjg';
  if not coalesce(v_enabled,false) then
    raise exception 'UAT_DESTRUCTIVE_TOOLS_DISABLED';
  end if;
  if p_confirmation<>'WYCZYŚĆ UAT I POZOSTAĆ PRZY PUSTEJ KONFIGURACJI' then
    raise exception 'INVALID_CONFIRMATION';
  end if;
  select lower(u.email) into v_email from auth.users u where u.id=v_actor;

  select string_agg(format('%I.%I',t.schemaname,t.tablename),',') into v_tables
  from pg_tables t
  where t.schemaname='public'
    and t.tablename not in ('uat_environment_controls','solver_feature_flags')
    and not exists(
      select 1 from pg_depend d
      join pg_class c on c.oid=d.objid
      join pg_extension e on e.oid=d.refobjid
      where d.deptype='e' and c.relname=t.tablename
    );
  if v_tables is not null then
    execute 'truncate table '||v_tables||' restart identity cascade';
  end if;
  delete from auth.users u where u.id<>v_actor;

  insert into public.user_permissions(auth_user_id,app_role,scope_role,scope_location)
  values(v_actor,'OWNER',null,null) on conflict do nothing;
  insert into public.application_access_directory_v1(
    email,app_role,auth_user_id,active,created_by
  ) values(v_email,'OWNER',v_actor,true,v_actor) on conflict do nothing;
  insert into public.matrix_scope_grants_v2(auth_user_id,app_role,active,created_by)
  values(v_actor,'OWNER',true,v_actor) on conflict do nothing;

  insert into public.application_finance_visibility_policy_v1(app_role,visibility)
  values
    ('OWNER','FULL'),
    ('ADMIN','AGGREGATE'),
    ('HR_FINANCE','FULL'),
    ('ROLE_MANAGER','BUDGET_ONLY'),
    ('LOCATION_MANAGER','BUDGET_ONLY'),
    ('VERIFIER','BUDGET_ONLY'),
    ('EMPLOYEE','NONE')
  on conflict(app_role) do nothing;

  v_draft:=solver_private.matrix_v2_create_safe_first_run_uat_v1(v_actor);
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'matrix_version',v_draft::text,
    'B4F171_UAT_RESET_EMPTY_FIRST_RUN_COMMITTED',jsonb_build_object(
      'projectRef','nhthrtpkfpmufmrmdyjg',
      'endState','EMPTY_FIRST_RUN','importRequiresSeparatePreview',true,
      'cancelCannotRollbackReset',true,
      'financeVisibilityDefaultsSeeded',true
    ));

  return jsonb_build_object(
    'ok',true,'draftMatrixVersionId',v_draft,'ownerEmail',v_email,
    'message','UAT_EMPTY_FIRST_RUN_READY',
    'endState','EMPTY_FIRST_RUN','importRequiresSeparatePreview',true,
    'financeVisibilityDefaultsSeeded',true
  );
end;
$$;

revoke all on function public.uat_full_business_reset_v1(text) from public,anon;
grant execute on function public.uat_full_business_reset_v1(text) to authenticated;

comment on function public.uat_full_business_reset_v1(text)
is 'B4F-171/B4F-180: isolated UAT full reset with idempotent restoration of owner access and all seven finance visibility defaults.';

notify pgrst,'reload schema';
