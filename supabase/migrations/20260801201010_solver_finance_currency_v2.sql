-- Matrix v2 uses one explicit settlement currency per immutable snapshot.
-- This additive migration also upgrades branches where the runtime tables
-- were created before the currency column was introduced.

alter table solver_private.plan_variant_finance_v2
  add column if not exists currency text;

update solver_private.plan_variant_finance_v2 f
set currency=upper(coalesce(
  nullif(s.snapshot->>'currency',''),
  nullif(mv.settings->>'currency','')
))
from public.plan_variants_v2 v
join public.optimization_runs_v2 r on r.id=v.run_id
join public.matrix_versions mv on mv.id=r.matrix_version_id
left join solver_private.optimization_snapshots_v2 s on s.run_id=r.id
where f.variant_id=v.id and f.currency is null;

do $$
begin
  if exists(
    select 1 from solver_private.plan_variant_finance_v2 f
    where f.currency is null
      or not public.matrix_v2_is_iso_4217_currency(f.currency)
  ) then
    raise exception 'MATRIX_CURRENCY_REQUIRED_FOR_FINANCE_BACKFILL';
  end if;
end;
$$;

update solver_private.plan_variant_finance_v2
set base_cost_minor=round(base_cost_units::numeric/60)::bigint,
  total_cost_minor=round(total_cost_units::numeric/60)::bigint,
  additions_cost_minor=greatest(
    round(total_cost_units::numeric/60)::bigint
      -round(base_cost_units::numeric/60)::bigint,
    0
  ),
  additions_cost_units=greatest(total_cost_units-base_cost_units,0);

alter table solver_private.plan_variant_finance_v2
  alter column currency set not null;

do $$
begin
  if not exists(
    select 1 from pg_constraint
    where conrelid='solver_private.plan_variant_finance_v2'::regclass
      and conname='plan_variant_finance_v2_currency_check'
  ) then
    alter table solver_private.plan_variant_finance_v2
      add constraint plan_variant_finance_v2_currency_check
      check (public.matrix_v2_is_iso_4217_currency(currency));
  end if;
  if not exists(
    select 1 from pg_constraint
    where conrelid='solver_private.plan_variant_finance_v2'::regclass
      and conname='plan_variant_finance_v2_units_sum_check'
  ) then
    alter table solver_private.plan_variant_finance_v2
      add constraint plan_variant_finance_v2_units_sum_check
      check (base_cost_units+additions_cost_units=total_cost_units);
  end if;
  if not exists(
    select 1 from pg_constraint
    where conrelid='solver_private.plan_variant_finance_v2'::regclass
      and conname='plan_variant_finance_v2_minor_sum_check'
  ) then
    alter table solver_private.plan_variant_finance_v2
      add constraint plan_variant_finance_v2_minor_sum_check
      check (base_cost_minor+additions_cost_minor=total_cost_minor);
  end if;
end;
$$;
