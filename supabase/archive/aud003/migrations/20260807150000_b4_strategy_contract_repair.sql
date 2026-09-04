-- B4 UAT: make the user-facing strategy names enforceable contracts.
-- The worker still reads all priorities from the versioned company
-- configuration. The ACTIVE version is immutable, so the repair follows the
-- same audited lifecycle as the UI: clone ACTIVE -> edit DRAFT -> publish.

do $$
declare
  v_owner uuid;
begin
  select up.auth_user_id into v_owner
  from public.user_permissions up
  where up.app_role='OWNER'
  order by up.auth_user_id
  limit 1;
  if v_owner is null then raise exception 'B4_OWNER_REQUIRED'; end if;
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  perform public.matrix_v2_create_draft('B4 — strategie, równy podział i koszt');
end;
$$;

update public.matrix_strategy_objectives_v2 objective
set tier = case objective.metric_code
    when 'UNFILLED' then 1
    when 'TOTAL_COST' then 2
    when 'OVERTIME_MINUTES' then 3
    when 'HOME_LOCATION_VIOLATIONS' then 3
    when 'PREFERENCE_VIOLATIONS' then 4
    when 'WEEKEND_SPREAD' then 5
    when 'LOAD_SPREAD_MINUTES' then 5
    when 'NOMINAL_DEVIATION_MINUTES' then 5
    else 6
  end
from public.matrix_strategies_v2 strategy,
     public.matrix_versions version
where objective.strategy_id = strategy.id
  and objective.matrix_version_id = strategy.matrix_version_id
  and version.id = strategy.matrix_version_id
  and version.status = 'DRAFT'
  and version.schema_version >= 2
  and strategy.code = 'MIN_COST'
  and objective.active;

update public.matrix_strategies_v2 strategy
set description =
  'Po zapewnieniu najlepszej możliwej obsady wybiera najniższy łączny koszt. '
  || 'Nadgodziny i pozostałe kryteria rozstrzygają dopiero przy takim samym koszcie.',
  updated_at = now()
from public.matrix_versions version
where version.id = strategy.matrix_version_id
  and version.status = 'DRAFT'
  and version.schema_version >= 2
  and strategy.code = 'MIN_COST';

update public.matrix_strategy_objectives_v2 objective
set tier = case objective.metric_code
    when 'UNFILLED' then 1
    when 'PREFERENCE_VIOLATIONS' then 2
    when 'LOAD_SPREAD_MINUTES' then 3
    when 'NOMINAL_DEVIATION_MINUTES' then 4
    when 'WEEKEND_SPREAD' then 5
    when 'TOTAL_COST' then 6
    when 'HOME_LOCATION_VIOLATIONS' then 6
    else 7
  end
from public.matrix_strategies_v2 strategy,
     public.matrix_versions version
where objective.strategy_id = strategy.id
  and objective.matrix_version_id = strategy.matrix_version_id
  and version.id = strategy.matrix_version_id
  and version.status = 'DRAFT'
  and version.schema_version >= 2
  and strategy.code = 'PREFERENCES'
  and objective.active;

update public.matrix_strategies_v2 strategy
set description =
  'Po uzupełnieniu wymaganej obsady najpierw respektuje prośby pracowników, '
  || 'następnie minimalizuje różnicę obciążenia i odchylenia od celu godzinowego. '
  || 'Koszt rozstrzyga dopiero później.',
  updated_at = now()
from public.matrix_versions version
where version.id = strategy.matrix_version_id
  and version.status = 'DRAFT'
  and version.schema_version >= 2
  and strategy.code = 'PREFERENCES';

do $$
begin
  if exists (
    select 1
    from public.matrix_strategy_objectives_v2 objective
    join public.matrix_strategies_v2 strategy on strategy.id=objective.strategy_id
    join public.matrix_versions version on version.id=objective.matrix_version_id
    where version.status in ('DRAFT','ACTIVE') and version.schema_version>=2
      and objective.active and (
        (strategy.code='MIN_COST' and objective.metric_code='TOTAL_COST' and objective.tier<>2)
        or (strategy.code='PREFERENCES' and objective.metric_code='LOAD_SPREAD_MINUTES' and objective.tier<>3)
      )
  ) then
    raise exception 'B4_STRATEGY_CONTRACT_REPAIR_FAILED';
  end if;
end;
$$;

do $$
declare
  v_owner uuid;
begin
  select up.auth_user_id into v_owner
  from public.user_permissions up
  where up.app_role='OWNER'
  order by up.auth_user_id
  limit 1;
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  perform public.matrix_v2_publish_draft(current_date);
end;
$$;

notify pgrst,'reload schema';
