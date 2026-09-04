-- B4F-171 / UAT-065
-- Keep a usable company configuration after every supported lifecycle action,
-- separate access failures from missing workspace state, and make the full-UAT
-- reset explicitly end in an empty first-run configuration rather than imply
-- that a later import can roll the reset back.

create or replace function solver_private.matrix_v2_discard_decision_uat_v1(
  p_draft_count integer,
  p_active_count integer
)
returns text
language plpgsql
immutable
set search_path=''
as $$
begin
  if p_draft_count>1 then return 'MULTIPLE_DRAFTS'; end if;
  if p_draft_count=1 and p_active_count=0 then return 'PRESERVE_ONLY_DRAFT'; end if;
  if p_draft_count=1 and p_active_count>0 then return 'DISCARD_DRAFT'; end if;
  if p_draft_count=0 and p_active_count=0 then return 'ENSURE_FIRST_RUN'; end if;
  return 'NOOP_ACTIVE';
end;
$$;

revoke all on function solver_private.matrix_v2_discard_decision_uat_v1(integer,integer)
  from public,anon,authenticated,service_role;

create or replace function solver_private.matrix_v2_create_safe_first_run_uat_v1(
  p_actor uuid
)
returns uuid
language plpgsql
volatile
security definer
set search_path=''
as $$
declare
  v_draft uuid;
  v_version integer;
begin
  if p_actor is null or not exists(select 1 from auth.users u where u.id=p_actor) then
    raise exception 'B4F171_OWNER_REQUIRED';
  end if;
  if not exists(
    select 1 from public.uat_environment_controls c
    where c.control_key='ISOLATED_UAT_DESTRUCTIVE_TOOLS'
      and c.enabled
      and c.config->>'environment'='ISOLATED_UAT'
      and c.config->>'projectRef'='nhthrtpkfpmufmrmdyjg'
  ) then
    raise exception 'B4F171_ISOLATED_UAT_REQUIRED';
  end if;
  if exists(
    select 1 from public.matrix_versions mv
    where mv.status in ('DRAFT','ACTIVE')
  ) then
    raise exception 'B4F171_USABLE_MATRIX_ALREADY_EXISTS';
  end if;

  select coalesce(max(mv.version),0)+1 into v_version
  from public.matrix_versions mv;

  insert into public.matrix_versions(
    version,name,status,effective_from,settings,created_by,schema_version
  ) values(
    v_version,
    case when v_version=1 then 'Pierwsza konfiguracja firmy'
      else 'Bezpieczna konfiguracja firmy' end,
    'DRAFT',
    date_trunc('month',(now() at time zone 'Europe/Warsaw')::date)::date,
    jsonb_build_object(
      'currency','PLN','timezone','Europe/Warsaw','minimumRestMinutes',660,
      'maximumShiftsPerDay',1,'maxShiftsPerDay',1,
      'standbyTiersPerRoleDay',2,
      'missingAvailabilityMeansAvailable',true,'requireOptimal',false
    ),p_actor,2
  ) returning id into v_draft;

  perform solver_private.matrix_v2_seed_required_defaults_uat_v1(v_draft);

  if (select count(*) from public.matrix_scenarios_v2 s where s.matrix_version_id=v_draft)<>1
    or (select count(*) from public.matrix_strategies_v2 s where s.matrix_version_id=v_draft)<>3
    or (select count(*) from public.matrix_strategy_objectives_v2 o where o.matrix_version_id=v_draft)<>24
    or (select count(*) from public.matrix_scenario_strategies_v2 l where l.matrix_version_id=v_draft)<>3
    or exists(
      select 1 from public.matrix_strategy_objectives_v2 o
      where o.matrix_version_id=v_draft and o.metric_code='HOME_LOCATION_VIOLATIONS'
    ) then
    raise exception 'B4F171_FIRST_RUN_DEFAULTS_MISMATCH';
  end if;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(p_actor,'matrix_version',v_draft::text,'B4F171_SAFE_FIRST_RUN_CREATED',
    jsonb_build_object(
      'version',v_version,'scenarios',1,'strategies',3,'objectives',24,
      'scenarioStrategies',3,'projectRef','nhthrtpkfpmufmrmdyjg'
    ));

  return v_draft;
end;
$$;

revoke all on function solver_private.matrix_v2_create_safe_first_run_uat_v1(uuid)
  from public,anon,authenticated,service_role;

create or replace function public.matrix_v2_ensure_first_run_uat_v1()
returns jsonb
language plpgsql
volatile
security definer
set search_path=''
as $$
declare
  v_actor uuid:=auth.uid();
  v_matrix uuid;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;

  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));

  select mv.id into v_matrix
  from public.matrix_versions mv
  where mv.status in ('DRAFT','ACTIVE')
  order by (mv.status='DRAFT') desc,mv.version desc
  limit 1;

  if v_matrix is not null then
    return jsonb_build_object(
      'created',false,'matrixVersionId',v_matrix,'reason','USABLE_MATRIX_EXISTS'
    );
  end if;

  v_matrix:=solver_private.matrix_v2_create_safe_first_run_uat_v1(v_actor);
  return jsonb_build_object(
    'created',true,'matrixVersionId',v_matrix,'reason','SAFE_FIRST_RUN_CREATED'
  );
end;
$$;

revoke all on function public.matrix_v2_ensure_first_run_uat_v1()
  from public,anon;
grant execute on function public.matrix_v2_ensure_first_run_uat_v1()
  to authenticated;

create or replace function public.matrix_v2_prevent_last_usable_delete_uat_v1()
returns trigger
language plpgsql
security invoker
set search_path=''
as $$
begin
  if old.status in ('DRAFT','ACTIVE') and not exists(
    select 1 from public.matrix_versions mv
    where mv.id<>old.id and mv.status in ('DRAFT','ACTIVE')
  ) then
    raise exception 'MATRIX_LAST_USABLE_VERSION_REQUIRED';
  end if;
  return old;
end;
$$;

revoke all on function public.matrix_v2_prevent_last_usable_delete_uat_v1()
  from public,anon,authenticated,service_role;

drop trigger if exists matrix_v2_prevent_last_usable_delete_uat_v1
  on public.matrix_versions;
create trigger matrix_v2_prevent_last_usable_delete_uat_v1
before delete on public.matrix_versions
for each row execute function public.matrix_v2_prevent_last_usable_delete_uat_v1();

create or replace function public.matrix_v2_discard_current_draft_uat_v2()
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_draft public.matrix_versions%rowtype;
  v_active uuid;
  v_draft_count integer;
  v_active_count integer;
  v_decision text;
  v_ensured jsonb;
  v_ad_hoc_reconnected integer:=0;
  v_ad_hoc_removed integer:=0;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;

  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));

  select count(*)::integer into v_draft_count
  from public.matrix_versions where status='DRAFT';
  select count(*)::integer into v_active_count
  from public.matrix_versions where status='ACTIVE';
  v_decision:=solver_private.matrix_v2_discard_decision_uat_v1(
    v_draft_count,v_active_count
  );

  if v_decision='MULTIPLE_DRAFTS' then
    raise exception 'MULTIPLE_MATRIX_DRAFTS_FOUND';
  end if;

  select * into v_draft
  from public.matrix_versions
  where status='DRAFT'
  order by version desc
  limit 1
  for update;

  select id into v_active
  from public.matrix_versions
  where status='ACTIVE'
  order by effective_from desc nulls last,version desc
  limit 1;

  if v_decision='ENSURE_FIRST_RUN' then
    v_ensured:=public.matrix_v2_ensure_first_run_uat_v1();
    return jsonb_build_object(
      'discarded',null,'alreadyDiscarded',true,
      'ensuredFirstRun',true,
      'activeMatrixVersionId',null,
      'draftMatrixVersionId',v_ensured->>'matrixVersionId'
    );
  end if;

  if v_decision='NOOP_ACTIVE' then
    return jsonb_build_object(
      'discarded',null,'alreadyDiscarded',true,
      'ensuredFirstRun',false,'activeMatrixVersionId',v_active
    );
  end if;

  if v_decision='PRESERVE_ONLY_DRAFT' then
    insert into public.audit_log(actor_id,entity_type,entity_id,action,old_data)
    values(auth.uid(),'matrix_version',v_draft.id::text,
      'B4F171_PRESERVE_ONLY_DRAFT',jsonb_build_object(
        'version',v_draft.version,'name',v_draft.name,
        'reason','NO_ACTIVE_CONFIGURATION'
      ));
    return jsonb_build_object(
      'discarded',null,'alreadyDiscarded',false,
      'preservedOnlyDraft',true,'ensuredFirstRun',false,
      'activeMatrixVersionId',null,'draftMatrixVersionId',v_draft.id
    );
  end if;

  if exists(
    select 1 from public.optimization_runs_v2 r
    where r.matrix_version_id=v_draft.id
  ) then
    raise exception 'DRAFT_ALREADY_USED_BY_GENERATOR';
  end if;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,old_data)
  values(
    auth.uid(),'matrix_version',v_draft.id::text,'DISCARD_DRAFT',
    jsonb_build_object('version',v_draft.version,'name',v_draft.name)
  );

  update public.recovery_ad_hoc_pool_v2 pool
  set role_id=active_role.id,updated_at=now()
  from public.matrix_roles_v2 draft_role
  join public.matrix_roles_v2 active_role
    on active_role.matrix_version_id=v_active
   and active_role.logical_id=draft_role.logical_id
  where pool.role_id=draft_role.id
    and draft_role.matrix_version_id=v_draft.id;
  get diagnostics v_ad_hoc_reconnected=row_count;

  delete from public.recovery_ad_hoc_pool_v2 pool
  using public.matrix_roles_v2 draft_role
  where pool.role_id=draft_role.id
    and draft_role.matrix_version_id=v_draft.id;
  get diagnostics v_ad_hoc_removed=row_count;

  delete from public.matrix_versions where id=v_draft.id;

  if not exists(
    select 1 from public.matrix_versions mv
    where mv.status in ('DRAFT','ACTIVE')
  ) then
    raise exception 'B4F171_USABLE_MATRIX_REQUIRED_AFTER_DISCARD';
  end if;

  return jsonb_build_object(
    'discarded',v_draft.id,'alreadyDiscarded',false,
    'preservedOnlyDraft',false,'ensuredFirstRun',false,
    'activeMatrixVersionId',v_active,
    'adHocRowsReconnected',v_ad_hoc_reconnected,
    'adHocRowsRemoved',v_ad_hoc_removed
  );
end;
$$;

revoke all on function public.matrix_v2_discard_current_draft_uat_v2()
  from public,anon;
grant execute on function public.matrix_v2_discard_current_draft_uat_v2()
  to authenticated;

comment on function public.matrix_v2_discard_current_draft_uat_v2() is
  'UAT: discard a draft only when another usable Matrix remains; preserve the sole draft and recover a missing first-run Matrix.';

create or replace function public.uat_full_business_reset_preview_v1()
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare v_enabled boolean:=false;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.has_app_role('OWNER') then raise exception 'FORBIDDEN'; end if;
  select c.enabled into v_enabled from public.uat_environment_controls c
    where c.control_key='ISOLATED_UAT_DESTRUCTIVE_TOOLS'
      and c.config->>'environment'='ISOLATED_UAT'
      and c.config->>'projectRef'='nhthrtpkfpmufmrmdyjg';
  return jsonb_build_object(
    'enabled',coalesce(v_enabled,false),
    'confirmation','WYCZYŚĆ UAT I POZOSTAĆ PRZY PUSTEJ KONFIGURACJI',
    'employees',(select count(*) from public.employees),
    'matrixVersions',(select count(*) from public.matrix_versions),
    'publishedSchedules',(select count(*) from public.published_role_schedules_v2),
    'otherUsers',(select count(*) from auth.users where id<>auth.uid()),
    'preserves',jsonb_build_array(
      'Twoje konto właściciela','flagi środowiska UAT','schemat i migracje',
      'bezpieczną pustą konfigurację pierwszego uruchomienia'
    ),
    'importRequiresPreview',true,
    'resetDoesNotRollbackImport',true
  );
end;
$$;

create or replace function public.uat_full_business_reset_v1(p_confirmation text)
returns jsonb
language plpgsql
volatile
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

  v_draft:=solver_private.matrix_v2_create_safe_first_run_uat_v1(v_actor);
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'matrix_version',v_draft::text,
    'B4F171_UAT_RESET_EMPTY_FIRST_RUN_COMMITTED',jsonb_build_object(
      'projectRef','nhthrtpkfpmufmrmdyjg',
      'endState','EMPTY_FIRST_RUN','importRequiresSeparatePreview',true,
      'cancelCannotRollbackReset',true
    ));

  return jsonb_build_object(
    'ok',true,'draftMatrixVersionId',v_draft,'ownerEmail',v_email,
    'message','UAT_EMPTY_FIRST_RUN_READY',
    'endState','EMPTY_FIRST_RUN','importRequiresSeparatePreview',true
  );
end;
$$;

revoke all on function public.uat_full_business_reset_preview_v1(),
  public.uat_full_business_reset_v1(text) from public,anon;
grant execute on function public.uat_full_business_reset_preview_v1(),
  public.uat_full_business_reset_v1(text) to authenticated;

notify pgrst,'reload schema';
