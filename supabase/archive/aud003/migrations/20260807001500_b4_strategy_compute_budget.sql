-- B4 UAT: devote the configurable compute budget to the business promise of
-- each variant.  These are Matrix data, not worker constants.  Coverage keeps
-- its own fair share of the global run budget in the solver.
update public.matrix_strategies_v2 s
set solver_options = jsonb_set(
      coalesce(s.solver_options, '{}'::jsonb),
      '{maxTimeSeconds}',
      to_jsonb(
        case s.code
          when 'BALANCED' then 90
          when 'MIN_COST' then 60
          when 'PREFERENCES' then 240
          else coalesce((s.solver_options ->> 'maxTimeSeconds')::integer, 120)
        end
      ),
      true
    ),
    updated_at = timezone('utc', now())
from public.matrix_versions v
where v.id = s.matrix_version_id
  and v.status = 'DRAFT'
  and s.code in ('BALANCED', 'MIN_COST', 'PREFERENCES');
