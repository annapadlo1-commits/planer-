-- Make the three default business variants genuinely lexicographic instead of
-- relying only on weights inside one shared optimization tier.

update public.matrix_strategies_v2 strategy
set description=case strategy.code
  when 'BALANCED' then
    'Kompromis kosztu, preferencji i równego obciążenia. Dobry wariant startowy, gdy żaden z tych celów nie ma bezwzględnego pierwszeństwa.'
  when 'MIN_COST' then
    'Po uzupełnieniu wymaganej obsady najpierw ogranicza koszt i nadgodziny. Preferencje oraz równość rozstrzygają dopiero później.'
  when 'PREFERENCES' then
    'Po uzupełnieniu wymaganej obsady najpierw respektuje miękkie preferencje i wyrównuje obciążenie. Koszt rozstrzyga później.'
  else strategy.description
end,
updated_at=now()
where strategy.code in ('BALANCED','MIN_COST','PREFERENCES')
  and exists(
    select 1 from public.matrix_versions version
    where version.id=strategy.matrix_version_id
      and version.status='DRAFT'
      and version.schema_version>=2
  );

update public.matrix_strategy_objectives_v2 objective
set tier=case strategy.code
    when 'BALANCED' then case
      when objective.metric_code='UNFILLED' then 1
      when objective.metric_code='HOME_LOCATION_VIOLATIONS' then 2
      else 2
    end
    when 'MIN_COST' then case
      when objective.metric_code='UNFILLED' then 1
      when objective.metric_code in ('TOTAL_COST','OVERTIME_MINUTES') then 2
      when objective.metric_code='HOME_LOCATION_VIOLATIONS' then 2
      else 3
    end
    when 'PREFERENCES' then case
      when objective.metric_code='UNFILLED' then 1
      when objective.metric_code in (
        'PREFERENCE_VIOLATIONS','NOMINAL_DEVIATION_MINUTES',
        'LOAD_SPREAD_MINUTES','WEEKEND_SPREAD'
      ) then 2
      when objective.metric_code='HOME_LOCATION_VIOLATIONS' then 2
      else 3
    end
    else objective.tier
  end,
  weight=case strategy.code
    when 'BALANCED' then case objective.metric_code
      when 'UNFILLED' then 1000000
      when 'TOTAL_COST' then 1000
      when 'PREFERENCE_VIOLATIONS' then 80000
      when 'OVERTIME_MINUTES' then 250000
      when 'NOMINAL_DEVIATION_MINUTES' then 30000
      when 'LOAD_SPREAD_MINUTES' then 40000
      when 'WEEKEND_SPREAD' then 25000
      when 'HOME_LOCATION_VIOLATIONS' then 15000
      when 'BASELINE_CHANGES' then 20000
      else objective.weight end
    when 'MIN_COST' then case objective.metric_code
      when 'UNFILLED' then 1000000
      when 'TOTAL_COST' then 10000
      when 'OVERTIME_MINUTES' then 500000
      when 'PREFERENCE_VIOLATIONS' then 30000
      when 'NOMINAL_DEVIATION_MINUTES' then 20000
      when 'LOAD_SPREAD_MINUTES' then 15000
      when 'WEEKEND_SPREAD' then 10000
      when 'HOME_LOCATION_VIOLATIONS' then 15000
      when 'BASELINE_CHANGES' then 10000
      else objective.weight end
    when 'PREFERENCES' then case objective.metric_code
      when 'UNFILLED' then 1000000
      when 'TOTAL_COST' then 500
      when 'OVERTIME_MINUTES' then 100000
      when 'PREFERENCE_VIOLATIONS' then 250000
      when 'NOMINAL_DEVIATION_MINUTES' then 150000
      when 'LOAD_SPREAD_MINUTES' then 200000
      when 'WEEKEND_SPREAD' then 180000
      when 'HOME_LOCATION_VIOLATIONS' then 15000
      when 'BASELINE_CHANGES' then 10000
      else objective.weight end
    else objective.weight
  end
from public.matrix_strategies_v2 strategy
join public.matrix_versions version on version.id=strategy.matrix_version_id
where objective.strategy_id=strategy.id
  and objective.matrix_version_id=strategy.matrix_version_id
  and strategy.code in ('BALANCED','MIN_COST','PREFERENCES')
  and version.status='DRAFT'
  and version.schema_version>=2;

insert into public.audit_log(entity_type,entity_id,action,new_data)
select 'matrix_strategy_set',version.id::text,'BUSINESS_PRIORITIES_REPAIRED',
  jsonb_build_object(
    'matrixVersion',version.version,
    'variants',jsonb_build_array('BALANCED','MIN_COST','PREFERENCES'),
    'coverageTier',1,
    'businessPriorityTiers',jsonb_build_array(2,3)
  )
from public.matrix_versions version
where version.status='DRAFT' and version.schema_version>=2;

notify pgrst,'reload schema';
