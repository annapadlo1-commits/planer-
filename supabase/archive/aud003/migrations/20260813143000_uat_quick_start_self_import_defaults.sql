-- UAT-only repair: a full reset must leave a technically complete first-run
-- draft.  Business dictionaries and employees remain empty, while the BASE
-- scenario and three solver strategies are system-owned defaults.

create or replace function solver_private.matrix_v2_seed_required_defaults_uat_v1(
  p_matrix_version_id uuid
)
returns void
language plpgsql
volatile
security definer
set search_path=''
as $$
declare
  v_enabled boolean:=false;
begin
  select c.enabled into v_enabled
  from public.uat_environment_controls c
  where c.control_key='ISOLATED_UAT_DESTRUCTIVE_TOOLS';

  if not coalesce(v_enabled,false) then
    raise exception 'UAT_DESTRUCTIVE_TOOLS_DISABLED';
  end if;
  if not exists(
    select 1 from public.matrix_versions mv
    where mv.id=p_matrix_version_id and mv.status='DRAFT'
  ) then
    raise exception 'UAT_DRAFT_MATRIX_REQUIRED';
  end if;

  insert into public.matrix_scenarios_v2(
    id,matrix_version_id,logical_id,code,name,description,color,is_default,
    active,sort_order,settings_overrides
  )
  select gen_random_uuid(),p_matrix_version_id,
    public.matrix_v2_stable_uuid('SCENARIO:BASE'),
    'BASE','Bazowy','Standardowe zapotrzebowanie','#7457e8',
    not exists(
      select 1 from public.matrix_scenarios_v2 existing
      where existing.matrix_version_id=p_matrix_version_id
        and existing.active and existing.is_default
    ),true,1,'{}'::jsonb
  where not exists(
    select 1 from public.matrix_scenarios_v2 existing
    where existing.matrix_version_id=p_matrix_version_id and existing.code='BASE'
  );

  insert into public.matrix_strategies_v2(
    id,matrix_version_id,logical_id,code,name,description,solver_code,
    solver_options,legacy_weights,sort_order,active
  )
  select gen_random_uuid(),p_matrix_version_id,
    public.matrix_v2_stable_uuid('STRATEGY:'||defaults.code),defaults.code,
    defaults.name,defaults.description,'CP_SAT',
    '{"maxTimeSeconds":120,"randomSeed":0}'::jsonb,defaults.legacy_weights,
    defaults.sort_order,true
  from (values
    ('BALANCED','Zrównoważony',
      'Kompromis kosztu, preferencji i równego obciążenia. Dobry wariant startowy, gdy żaden z tych celów nie ma bezwzględnego pierwszeństwa.',
      '{"cost":1,"preference":80,"fairness":40,"nominal":30,"homeLocation":15,"weekendFairness":25,"overtime":250}'::jsonb,1),
    ('MIN_COST','Minimalny koszt',
      'Po zapewnieniu najlepszej możliwej obsady wybiera najniższy łączny koszt. Nadgodziny i pozostałe kryteria rozstrzygają dopiero przy takim samym koszcie.',
      '{"cost":4,"preference":30,"fairness":15,"nominal":20,"homeLocation":15,"weekendFairness":10,"overtime":500}'::jsonb,2),
    ('PREFERENCES','Preferencje i równy podział',
      'Po uzupełnieniu wymaganej obsady najpierw respektuje prośby pracowników, następnie minimalizuje różnicę obciążenia i odchylenia od celu godzinowego. Koszt rozstrzyga dopiero później.',
      '{"cost":0.5,"preference":250,"fairness":200,"nominal":150,"homeLocation":15,"weekendFairness":180,"overtime":100}'::jsonb,3)
  ) as defaults(code,name,description,legacy_weights,sort_order)
  where not exists(
    select 1 from public.matrix_strategies_v2 existing
    where existing.matrix_version_id=p_matrix_version_id
      and existing.code=defaults.code
  );

  with metric_catalog(metric_code,sort_order) as (values
    ('UNFILLED',1),('TOTAL_COST',2),('PREFERENCE_VIOLATIONS',3),
    ('OVERTIME_MINUTES',4),('NOMINAL_DEVIATION_MINUTES',5),
    ('LOAD_SPREAD_MINUTES',6),('WEEKEND_SPREAD',7),
    ('HOME_LOCATION_VIOLATIONS',8),('BASELINE_CHANGES',9)
  )
  insert into public.matrix_strategy_objectives_v2(
    id,matrix_version_id,strategy_id,tier,sort_order,metric_code,direction,
    weight,tolerance,parameters,active
  )
  select gen_random_uuid(),p_matrix_version_id,strategy.id,
    case
      when metric.metric_code='UNFILLED' then 1
      when strategy.code='BALANCED' then 2
      when strategy.code='MIN_COST' and metric.metric_code='TOTAL_COST' then 2
      when strategy.code='MIN_COST' and metric.metric_code in ('OVERTIME_MINUTES','HOME_LOCATION_VIOLATIONS') then 3
      when strategy.code='MIN_COST' and metric.metric_code='PREFERENCE_VIOLATIONS' then 4
      when strategy.code='MIN_COST' and metric.metric_code in ('WEEKEND_SPREAD','LOAD_SPREAD_MINUTES','NOMINAL_DEVIATION_MINUTES') then 5
      when strategy.code='PREFERENCES' and metric.metric_code='PREFERENCE_VIOLATIONS' then 2
      when strategy.code='PREFERENCES' and metric.metric_code='LOAD_SPREAD_MINUTES' then 3
      when strategy.code='PREFERENCES' and metric.metric_code='NOMINAL_DEVIATION_MINUTES' then 4
      when strategy.code='PREFERENCES' and metric.metric_code='WEEKEND_SPREAD' then 5
      when strategy.code='PREFERENCES' and metric.metric_code in ('TOTAL_COST','HOME_LOCATION_VIOLATIONS') then 6
      when strategy.code='PREFERENCES' then 7
      else 6
    end::smallint,
    metric.sort_order,metric.metric_code,'MINIMIZE',
    case strategy.code
      when 'BALANCED' then case metric.metric_code
        when 'UNFILLED' then 1000000 when 'TOTAL_COST' then 1000
        when 'PREFERENCE_VIOLATIONS' then 80000 when 'OVERTIME_MINUTES' then 250000
        when 'NOMINAL_DEVIATION_MINUTES' then 30000 when 'LOAD_SPREAD_MINUTES' then 40000
        when 'WEEKEND_SPREAD' then 25000 when 'HOME_LOCATION_VIOLATIONS' then 15000
        else 20000 end
      when 'MIN_COST' then case metric.metric_code
        when 'UNFILLED' then 1000000 when 'TOTAL_COST' then 10000
        when 'PREFERENCE_VIOLATIONS' then 30000 when 'OVERTIME_MINUTES' then 500000
        when 'NOMINAL_DEVIATION_MINUTES' then 20000 when 'LOAD_SPREAD_MINUTES' then 15000
        when 'WEEKEND_SPREAD' then 10000 when 'HOME_LOCATION_VIOLATIONS' then 15000
        else 10000 end
      else case metric.metric_code
        when 'UNFILLED' then 1000000 when 'TOTAL_COST' then 500
        when 'PREFERENCE_VIOLATIONS' then 250000 when 'OVERTIME_MINUTES' then 100000
        when 'NOMINAL_DEVIATION_MINUTES' then 150000 when 'LOAD_SPREAD_MINUTES' then 200000
        when 'WEEKEND_SPREAD' then 180000 when 'HOME_LOCATION_VIOLATIONS' then 15000
        else 10000 end
    end::bigint,
    0,'{}'::jsonb,true
  from public.matrix_strategies_v2 strategy
  cross join metric_catalog metric
  where strategy.matrix_version_id=p_matrix_version_id
    and strategy.code in ('BALANCED','MIN_COST','PREFERENCES')
    and not exists(
      select 1 from public.matrix_strategy_objectives_v2 objective
      where objective.strategy_id=strategy.id
        and objective.metric_code=metric.metric_code
    );

  insert into public.matrix_scenario_strategies_v2(
    id,matrix_version_id,scenario_id,strategy_id,sort_order,active,
    objective_overrides,solver_overrides
  )
  select gen_random_uuid(),p_matrix_version_id,scenario.id,strategy.id,
    strategy.sort_order,true,'{}'::jsonb,'{}'::jsonb
  from public.matrix_scenarios_v2 scenario
  join public.matrix_strategies_v2 strategy
    on strategy.matrix_version_id=scenario.matrix_version_id
   and strategy.code in ('BALANCED','MIN_COST','PREFERENCES')
  where scenario.matrix_version_id=p_matrix_version_id
    and scenario.code='BASE'
    and not exists(
      select 1 from public.matrix_scenario_strategies_v2 link
      where link.scenario_id=scenario.id and link.strategy_id=strategy.id
    );
end;
$$;

revoke all on function solver_private.matrix_v2_seed_required_defaults_uat_v1(uuid)
  from public,anon,authenticated;

create or replace function public.uat_full_business_reset_v1(p_confirmation text)
returns jsonb language plpgsql volatile security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_enabled boolean:=false; v_email text;
  v_tables text; v_draft uuid;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.has_app_role('OWNER') then raise exception 'FORBIDDEN'; end if;
  select c.enabled into v_enabled from public.uat_environment_controls c
    where c.control_key='ISOLATED_UAT_DESTRUCTIVE_TOOLS';
  if not coalesce(v_enabled,false) then raise exception 'UAT_DESTRUCTIVE_TOOLS_DISABLED'; end if;
  if p_confirmation<>'WYCZYŚĆ CAŁĄ FIRMĘ UAT' then raise exception 'INVALID_CONFIRMATION'; end if;
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
  if v_tables is not null then execute 'truncate table '||v_tables||' restart identity cascade'; end if;
  delete from auth.users u where u.id<>v_actor;

  insert into public.user_permissions(auth_user_id,app_role,scope_role,scope_location)
  values(v_actor,'OWNER',null,null) on conflict do nothing;
  insert into public.application_access_directory_v1(
    email,app_role,auth_user_id,active,created_by
  ) values(v_email,'OWNER',v_actor,true,v_actor) on conflict do nothing;
  insert into public.matrix_scope_grants_v2(auth_user_id,app_role,active,created_by)
  values(v_actor,'OWNER',true,v_actor) on conflict do nothing;

  insert into public.matrix_versions(
    version,name,status,effective_from,settings,created_by,schema_version
  ) values(
    1,'Pierwsza konfiguracja firmy','DRAFT',
    (now() at time zone 'Europe/Warsaw')::date,
    jsonb_build_object(
      'currency','PLN','timezone','Europe/Warsaw','minimumRestMinutes',660,
      'maximumShiftsPerDay',1,'maxShiftsPerDay',1,'standbyTiersPerRoleDay',2,
      'missingAvailabilityMeansAvailable',true,'requireOptimal',false
    ),v_actor,2
  ) returning id into v_draft;

  perform solver_private.matrix_v2_seed_required_defaults_uat_v1(v_draft);

  return jsonb_build_object('ok',true,'draftMatrixVersionId',v_draft,
    'ownerEmail',v_email,'message','UAT_EMPTY_FIRST_RUN_READY');
end;
$$;

revoke all on function public.uat_full_business_reset_v1(text) from public,anon;
grant execute on function public.uat_full_business_reset_v1(text) to authenticated;

-- Repair the already reset UAT draft that produced a header-only workbook.
do $$
declare v_enabled boolean:=false; v_matrix uuid;
begin
  select c.enabled into v_enabled
  from public.uat_environment_controls c
  where c.control_key='ISOLATED_UAT_DESTRUCTIVE_TOOLS';
  if coalesce(v_enabled,false) then
    for v_matrix in
      select mv.id from public.matrix_versions mv
      where mv.status='DRAFT'
        and (
          not exists(select 1 from public.matrix_scenarios_v2 s where s.matrix_version_id=mv.id)
          or not exists(select 1 from public.matrix_strategies_v2 s where s.matrix_version_id=mv.id)
        )
    loop
      perform solver_private.matrix_v2_seed_required_defaults_uat_v1(v_matrix);
    end loop;
  end if;
end;
$$;
