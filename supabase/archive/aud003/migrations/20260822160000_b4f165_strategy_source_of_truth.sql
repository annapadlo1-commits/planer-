-- B4F-165 UAT: make the published Matrix the single source of truth for
-- built-in strategy semantics.  The previous ACTIVE version remains immutable;
-- this migration clones it, repairs only the DRAFT and publishes a new version.

create temp table b4f165_prior_active on commit drop as
select mv.id,mv.version,mv.content_hash,
  public.matrix_v2_content_document(mv.id) content_document
from public.matrix_versions mv
where mv.status='ACTIVE' and mv.schema_version>=2
order by mv.version desc
limit 1;

do $$
begin
  if (select count(*) from b4f165_prior_active)<>1 then
    raise exception 'B4F165_ACTIVE_MATRIX_REQUIRED';
  end if;
  if exists(
    select 1 from public.matrix_versions mv
    where mv.status='DRAFT' and mv.schema_version>=2
  ) then
    raise exception 'B4F165_EXISTING_DRAFT_REQUIRES_OWNER_DECISION';
  end if;
end;
$$;

create or replace function solver_private.validate_strategy_semantics_b4f165(
  p_matrix_version_id uuid
)
returns void
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  v_expected_guards constant jsonb :=
    '["HARD_CONSTRAINTS","COVERAGE","ROLE_BACKUP","OVERTIME","ZERO_HOURS","PRIMARY_ROLE","MAX_MIN_FAIRNESS","FAIRNESS_SPREAD"]'::jsonb;
  v_settings jsonb;
begin
  select mv.settings into v_settings
  from public.matrix_versions mv
  where mv.id=p_matrix_version_id;
  if v_settings->>'strategySemanticsVersion'<>'B4F165_V1'
    or v_settings->'mandatoryProductGuards'<>v_expected_guards
    or coalesce(
      (v_settings->>'configurableObjectivesStartAfterMandatoryGuards')::boolean,
      false
    ) is not true then
    raise exception 'STRATEGY_SEMANTICS_MISMATCH: MATRIX_DECLARATION';
  end if;

  if (
    select count(distinct s.code)
    from public.matrix_strategies_v2 s
    where s.matrix_version_id=p_matrix_version_id and s.active
      and s.code in ('BALANCED','MIN_COST','PREFERENCES')
  )<>3 then
    raise exception 'STRATEGY_SEMANTICS_MISMATCH: BUILT_IN_STRATEGIES';
  end if;

  if exists(
    select 1
    from public.matrix_strategies_v2 s
    where s.matrix_version_id=p_matrix_version_id and s.active
      and s.code in ('BALANCED','MIN_COST','PREFERENCES')
      and (
        s.description<>case s.code
          when 'BALANCED' then
            'Po zapewnieniu wymaganej obsady, zasad czasu pracy, minimalnych nadgodzin i podstawowego wyrównania zespołu łączy koszt, preferencje pracowników i dalszą równowagę obciążenia.'
          when 'MIN_COST' then
            'Minimalizuje koszt wśród grafików spełniających pełną obsadę, zasady czasu pracy, minimalne nadgodziny i podstawowe wymagania sprawiedliwego podziału.'
          when 'PREFERENCES' then
            'Najpierw sprawiedliwie rozdziela pracę względem celów i możliwości pracowników. Następnie wśród podobnie sprawiedliwych grafików możliwie najlepiej uwzględnia preferowane dni, zmiany i lokalizacje.'
        end
      )
  ) then
    raise exception 'STRATEGY_SEMANTICS_MISMATCH: DECLARATION';
  end if;

  if exists(
    with expected(strategy_code,metric_code,tier) as (values
      ('BALANCED','UNFILLED',1),
      ('BALANCED','TOTAL_COST',2),
      ('BALANCED','PREFERENCE_VIOLATIONS',2),
      ('BALANCED','OVERTIME_MINUTES',2),
      ('BALANCED','NOMINAL_DEVIATION_MINUTES',2),
      ('BALANCED','LOAD_SPREAD_MINUTES',2),
      ('BALANCED','WEEKEND_SPREAD',2),
      ('BALANCED','HOME_LOCATION_VIOLATIONS',2),
      ('BALANCED','BASELINE_CHANGES',2),
      ('MIN_COST','UNFILLED',1),
      ('MIN_COST','TOTAL_COST',2),
      ('MIN_COST','OVERTIME_MINUTES',3),
      ('MIN_COST','HOME_LOCATION_VIOLATIONS',3),
      ('MIN_COST','PREFERENCE_VIOLATIONS',4),
      ('MIN_COST','NOMINAL_DEVIATION_MINUTES',5),
      ('MIN_COST','LOAD_SPREAD_MINUTES',5),
      ('MIN_COST','WEEKEND_SPREAD',5),
      ('MIN_COST','BASELINE_CHANGES',6),
      ('PREFERENCES','UNFILLED',1),
      ('PREFERENCES','LOAD_SPREAD_MINUTES',2),
      ('PREFERENCES','NOMINAL_DEVIATION_MINUTES',3),
      ('PREFERENCES','PREFERENCE_VIOLATIONS',4),
      ('PREFERENCES','WEEKEND_SPREAD',5),
      ('PREFERENCES','TOTAL_COST',6),
      ('PREFERENCES','HOME_LOCATION_VIOLATIONS',6),
      ('PREFERENCES','OVERTIME_MINUTES',7),
      ('PREFERENCES','BASELINE_CHANGES',7)
    )
    select 1
    from expected e
    left join public.matrix_strategies_v2 s
      on s.matrix_version_id=p_matrix_version_id and s.active
      and s.code=e.strategy_code
    left join public.matrix_strategy_objectives_v2 o
      on o.matrix_version_id=p_matrix_version_id and o.strategy_id=s.id
      and o.active and o.metric_code=e.metric_code
    where o.id is null or o.tier<>e.tier or o.weight<=0
      or upper(o.direction) not in ('MIN','MINIMIZE')
  ) then
    raise exception 'STRATEGY_SEMANTICS_MISMATCH: OBJECTIVE_TIERS';
  end if;
end;
$$;

create or replace function solver_private.apply_strategy_semantics_b4f165(
  p_matrix_version_id uuid
)
returns void
language plpgsql
volatile
security definer
set search_path=''
as $$
begin
  update public.matrix_versions mv
  set settings=coalesce(mv.settings,'{}'::jsonb)||jsonb_build_object(
      'strategySemanticsVersion','B4F165_V1',
      'mandatoryProductGuards',jsonb_build_array(
        'HARD_CONSTRAINTS','COVERAGE','ROLE_BACKUP','OVERTIME','ZERO_HOURS',
        'PRIMARY_ROLE','MAX_MIN_FAIRNESS','FAIRNESS_SPREAD'
      ),
      'configurableObjectivesStartAfterMandatoryGuards',true
    )
  where mv.id=p_matrix_version_id;

  update public.matrix_strategies_v2 s
  set description=case s.code
      when 'BALANCED' then
        'Po zapewnieniu wymaganej obsady, zasad czasu pracy, minimalnych nadgodzin i podstawowego wyrównania zespołu łączy koszt, preferencje pracowników i dalszą równowagę obciążenia.'
      when 'MIN_COST' then
        'Minimalizuje koszt wśród grafików spełniających pełną obsadę, zasady czasu pracy, minimalne nadgodziny i podstawowe wymagania sprawiedliwego podziału.'
      when 'PREFERENCES' then
        'Najpierw sprawiedliwie rozdziela pracę względem celów i możliwości pracowników. Następnie wśród podobnie sprawiedliwych grafików możliwie najlepiej uwzględnia preferowane dni, zmiany i lokalizacje.'
    end,
    updated_at=now()
  where s.matrix_version_id=p_matrix_version_id and s.active
    and s.code in ('BALANCED','MIN_COST','PREFERENCES');

  update public.matrix_strategy_objectives_v2 o
  set tier=case s.code
      when 'BALANCED' then case o.metric_code
        when 'UNFILLED' then 1 else 2 end
      when 'MIN_COST' then case o.metric_code
        when 'UNFILLED' then 1
        when 'TOTAL_COST' then 2
        when 'OVERTIME_MINUTES' then 3
        when 'HOME_LOCATION_VIOLATIONS' then 3
        when 'PREFERENCE_VIOLATIONS' then 4
        when 'NOMINAL_DEVIATION_MINUTES' then 5
        when 'LOAD_SPREAD_MINUTES' then 5
        when 'WEEKEND_SPREAD' then 5
        else 6 end
      when 'PREFERENCES' then case o.metric_code
        when 'UNFILLED' then 1
        when 'LOAD_SPREAD_MINUTES' then 2
        when 'NOMINAL_DEVIATION_MINUTES' then 3
        when 'PREFERENCE_VIOLATIONS' then 4
        when 'WEEKEND_SPREAD' then 5
        when 'TOTAL_COST' then 6
        when 'HOME_LOCATION_VIOLATIONS' then 6
        else 7 end
      else o.tier
    end
  from public.matrix_strategies_v2 s
  where o.matrix_version_id=p_matrix_version_id
    and s.matrix_version_id=p_matrix_version_id and s.id=o.strategy_id
    and s.active and o.active
    and s.code in ('BALANCED','MIN_COST','PREFERENCES');

  perform solver_private.validate_strategy_semantics_b4f165(p_matrix_version_id);
end;
$$;

create or replace function solver_private.guard_strategy_semantics_b4f165()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  if new.status='ACTIVE' then
    perform solver_private.validate_strategy_semantics_b4f165(new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists guard_strategy_semantics_b4f165
  on public.matrix_versions;
create trigger guard_strategy_semantics_b4f165
before insert or update of status on public.matrix_versions
for each row execute function solver_private.guard_strategy_semantics_b4f165();

-- Preserve the reset helper while ensuring every future UAT first-run draft
-- receives the same declarations and objective tiers as the published Matrix.
alter function solver_private.matrix_v2_seed_required_defaults_uat_v1(uuid)
  rename to matrix_v2_seed_required_defaults_before_b4f165;

create function solver_private.matrix_v2_seed_required_defaults_uat_v1(
  p_matrix_version_id uuid
)
returns void
language plpgsql
volatile
security definer
set search_path=''
as $$
begin
  perform solver_private.matrix_v2_seed_required_defaults_before_b4f165(
    p_matrix_version_id
  );
  perform solver_private.apply_strategy_semantics_b4f165(p_matrix_version_id);
end;
$$;

-- Add the published declaration to immutable run snapshots without copying the
-- large, already-audited snapshot builder.  Existing stored snapshots remain
-- byte-for-byte unchanged.
alter function solver_private.build_snapshot_payload_v2(
  uuid,date,uuid,uuid,text,uuid
) rename to build_snapshot_payload_before_b4f165;

create function solver_private.build_snapshot_payload_v2(
  p_run_id uuid,
  p_month date,
  p_matrix_version_id uuid,
  p_scenario_id uuid,
  p_scope_type text,
  p_scope_role_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  v_snapshot jsonb;
  v_strategies jsonb;
  v_settings jsonb;
begin
  v_snapshot:=solver_private.build_snapshot_payload_before_b4f165(
    p_run_id,p_month,p_matrix_version_id,p_scenario_id,p_scope_type,p_scope_role_id
  );
  select mv.settings into v_settings
  from public.matrix_versions mv
  where mv.id=p_matrix_version_id;

  select coalesce(jsonb_agg(
    item.value||jsonb_strip_nulls(jsonb_build_object(
      'strategySemanticsVersion',v_settings->>'strategySemanticsVersion',
      'mandatoryProductGuards',v_settings->'mandatoryProductGuards'
    )) order by item.ordinality
  ),'[]'::jsonb)
  into v_strategies
  from jsonb_array_elements(v_snapshot->'strategies')
    with ordinality item(value,ordinality)
  ;

  return jsonb_set(v_snapshot,'{strategies}',v_strategies,true);
end;
$$;

revoke all on function
  solver_private.validate_strategy_semantics_b4f165(uuid),
  solver_private.apply_strategy_semantics_b4f165(uuid),
  solver_private.guard_strategy_semantics_b4f165(),
  solver_private.matrix_v2_seed_required_defaults_before_b4f165(uuid),
  solver_private.matrix_v2_seed_required_defaults_uat_v1(uuid),
  solver_private.build_snapshot_payload_before_b4f165(uuid,date,uuid,uuid,text,uuid),
  solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)
from public,anon,authenticated;

grant execute on function solver_private.build_snapshot_payload_v2(
  uuid,date,uuid,uuid,text,uuid
) to service_role;

do $$
declare
  v_owner uuid;
  v_draft uuid;
begin
  select up.auth_user_id into v_owner
  from public.user_permissions up
  where up.app_role='OWNER'
  order by up.auth_user_id
  limit 1;
  if v_owner is null then raise exception 'B4F165_OWNER_REQUIRED'; end if;
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  v_draft:=public.matrix_v2_create_draft(
    'B4F-165 — Matrix źródłem prawdy strategii'
  );
  perform solver_private.apply_strategy_semantics_b4f165(v_draft);
  perform public.matrix_v2_publish_draft(current_date);
end;
$$;

do $$
declare
  v_active public.matrix_versions%rowtype;
  v_prior b4f165_prior_active%rowtype;
begin
  select * into v_prior from b4f165_prior_active;
  select * into v_active
  from public.matrix_versions mv
  where mv.status='ACTIVE' and mv.schema_version>=2
  order by mv.version desc
  limit 1;

  if v_active.id is null
    or v_active.base_version_id<>v_prior.id
    or v_active.version<>v_prior.version+1 then
    raise exception 'B4F165_NEW_ACTIVE_MATRIX_NOT_PUBLISHED';
  end if;
  perform solver_private.validate_strategy_semantics_b4f165(v_active.id);
  if (select mv.content_hash from public.matrix_versions mv where mv.id=v_prior.id)
      is distinct from v_prior.content_hash
    or public.matrix_v2_content_document(v_prior.id)
      is distinct from v_prior.content_document then
    raise exception 'B4F165_HISTORICAL_MATRIX_CONTENT_CHANGED';
  end if;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_v2',v_active.id::text,
    'B4F165_STRATEGY_SEMANTICS_PUBLISHED',jsonb_build_object(
      'baseVersionId',v_prior.id,
      'baseVersion',v_prior.version,
      'newVersion',v_active.version,
      'strategySemanticsVersion','B4F165_V1',
      'mandatoryProductGuards',jsonb_build_array(
        'HARD_CONSTRAINTS','COVERAGE','ROLE_BACKUP','OVERTIME','ZERO_HOURS',
        'PRIMARY_ROLE','MAX_MIN_FAIRNESS','FAIRNESS_SPREAD'
      )
    ));
end;
$$;

notify pgrst,'reload schema';
