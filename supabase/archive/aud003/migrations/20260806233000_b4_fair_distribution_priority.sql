-- B4: make the user-facing "Preferencje i równy podział" promise explicit
-- in Matrix data. The solver continues to consume tiers from the published
-- Matrix; no strategy code or fixed employee-hour target is embedded in it.

update public.matrix_strategy_objectives_v2 objective
set tier = case objective.metric_code
    when 'UNFILLED' then 1
    when 'PREFERENCE_VIOLATIONS' then 2
    when 'LOAD_SPREAD_MINUTES' then 3
    when 'NOMINAL_DEVIATION_MINUTES' then 4
    when 'WEEKEND_SPREAD' then 5
    when 'HOME_LOCATION_VIOLATIONS' then 5
    else 6
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
  || 'następnie minimalizuje różnicę obciążenia i odchylenia od wymiaru. '
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
    join public.matrix_strategies_v2 strategy on strategy.id = objective.strategy_id
    join public.matrix_versions version on version.id = objective.matrix_version_id
    where version.status = 'DRAFT'
      and version.schema_version >= 2
      and strategy.code = 'PREFERENCES'
      and objective.active
      and objective.tier <> case objective.metric_code
        when 'UNFILLED' then 1
        when 'PREFERENCE_VIOLATIONS' then 2
        when 'LOAD_SPREAD_MINUTES' then 3
        when 'NOMINAL_DEVIATION_MINUTES' then 4
        when 'WEEKEND_SPREAD' then 5
        when 'HOME_LOCATION_VIOLATIONS' then 5
        else 6
      end
  ) then
    raise exception 'B4_FAIR_DISTRIBUTION_PRIORITY_FAILED';
  end if;
end;
$$;
