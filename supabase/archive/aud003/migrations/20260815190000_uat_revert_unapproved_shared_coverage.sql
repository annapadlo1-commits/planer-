-- Local rollback candidate. Do not deploy without explicit product approval.
-- Restores independent staffing demand and removes the unapproved shared
-- cross-location coverage metadata introduced in the preceding UAT migration.

drop function if exists public.matrix_v2_shift_staffing_save_uat_v4(
  uuid,uuid[],uuid,uuid,text,integer,integer,boolean,jsonb
);

update public.matrix_staffing_rules_v2
set source_metadata=(coalesce(source_metadata,'{}'::jsonb)-'coverageMode'-'sharedCoverageGroup'),
    updated_at=now()
where coalesce(source_metadata,'{}'::jsonb) ?| array['coverageMode','sharedCoverageGroup'];

create or replace function solver_private.resolved_demand_v2(
  p_month date,
  p_matrix_version_id uuid,
  p_scenario_id uuid,
  p_scope_role_id uuid default null
)
returns table(
  demand_id uuid,work_date date,shift_template_id uuid,location_id uuid,
  role_id uuid,duty_ids uuid[],required_count integer,starts_at timestamptz,
  ends_at timestamptz,duration_minutes integer
)
language sql
stable
security definer
set search_path = ''
as $$
with recursive scenario_chain as (
  select s.id,s.parent_scenario_id,s.valid_from,s.valid_to,0 depth
  from public.matrix_scenarios_v2 s
  where s.id=p_scenario_id and s.matrix_version_id=p_matrix_version_id
  union all
  select parent.id,parent.parent_scenario_id,parent.valid_from,parent.valid_to,c.depth+1
  from public.matrix_scenarios_v2 parent
  join scenario_chain c on c.parent_scenario_id=parent.id
  where parent.matrix_version_id=p_matrix_version_id and c.depth<32
), rule_keys as (
  select distinct sr.shift_template_id,sr.role_id,sr.duty_id
  from public.matrix_staffing_rules_v2 sr
  join scenario_chain c on c.id=sr.scenario_id
  where sr.matrix_version_id=p_matrix_version_id and sr.active
    and (p_scope_role_id is null or sr.role_id=p_scope_role_id)
), occurrences as (
  select d::date work_date,st.id shift_template_id,st.location_id,
    st.shift_period,st.starts_at local_start,st.ends_at local_end,
    st.ends_next_day,l.timezone
  from public.matrix_shift_templates_v2 st
  join public.matrix_locations_v2 l
    on l.id=st.location_id and l.matrix_version_id=st.matrix_version_id
  cross join lateral generate_series(
    date_trunc('month',p_month)::date,
    (date_trunc('month',p_month)+interval '1 month - 1 day')::date,
    interval '1 day'
  ) d
  where st.matrix_version_id=p_matrix_version_id and st.active and l.active
    and extract(isodow from d)::smallint=any(st.day_mask)
), evaluated as (
  select o.work_date,o.shift_template_id,o.location_id,o.shift_period,
    k.role_id,k.duty_id,
    solver_private.apply_integer_operations_v2(coalesce((
      select jsonb_agg(jsonb_build_object(
        'operation',sr.operation,'value',sr.count_value,
        'basisPoints',sr.multiplier_basis_points
      ) order by c.depth desc)
      from public.matrix_staffing_rules_v2 sr
      join scenario_chain c on c.id=sr.scenario_id
      where sr.matrix_version_id=p_matrix_version_id and sr.active
        and sr.shift_template_id=k.shift_template_id and sr.role_id=k.role_id
        and sr.duty_id is not distinct from k.duty_id
        and (c.valid_from is null or c.valid_from<=o.work_date)
        and (c.valid_to is null or c.valid_to>=o.work_date)
    ),'[]'::jsonb))::integer required_count,
    ((o.work_date+o.local_start) at time zone o.timezone) starts_at,
    (((o.work_date+case when o.ends_next_day then 1 else 0 end)+o.local_end)
      at time zone o.timezone) ends_at
  from occurrences o join rule_keys k on k.shift_template_id=o.shift_template_id
), role_occurrences as (
  select e.work_date,e.shift_template_id,e.location_id,e.shift_period,e.role_id,
    coalesce(sum(e.required_count) filter(where e.duty_id is null),0)::integer generic_count,
    min(e.starts_at) starts_at,max(e.ends_at) ends_at
  from evaluated e where e.required_count>0 and e.ends_at>e.starts_at
  group by e.work_date,e.shift_template_id,e.location_id,e.shift_period,e.role_id
), explicit_counts as (
  select e.work_date,e.shift_template_id,e.location_id,e.role_id,e.duty_id,
    sum(e.required_count)::integer required_count
  from evaluated e
  where e.duty_id is not null and e.required_count>0 and e.ends_at>e.starts_at
  group by e.work_date,e.shift_template_id,e.location_id,e.role_id,e.duty_id
), minimum_requirements as (
  select ro.work_date,ro.shift_template_id,ro.location_id,ro.role_id,rd.duty_id,
    greatest(rd.minimum_count-coalesce(ec.required_count,0),0)::integer required_count
  from role_occurrences ro
  join public.matrix_role_duties_v2 rd
    on rd.matrix_version_id=p_matrix_version_id and rd.role_id=ro.role_id
    and rd.active and rd.assignment_mode='REQUIRED' and rd.minimum_count>0
    and rd.shift_obligation and rd.shift_period=ro.shift_period
  left join explicit_counts ec
    on ec.work_date=ro.work_date and ec.shift_template_id=ro.shift_template_id
    and ec.location_id=ro.location_id and ec.role_id=ro.role_id
    and ec.duty_id=rd.duty_id
  where ro.generic_count>0
), minimum_totals as (
  select mr.work_date,mr.shift_template_id,mr.location_id,mr.role_id,
    sum(mr.required_count)::integer minimum_count
  from minimum_requirements mr
  group by mr.work_date,mr.shift_template_id,mr.location_id,mr.role_id
), guard as (
  select coalesce(bool_and(coalesce(mt.minimum_count,0)<=ro.generic_count),true) valid
  from role_occurrences ro
  left join minimum_totals mt
    on mt.work_date=ro.work_date and mt.shift_template_id=ro.shift_template_id
    and mt.location_id=ro.location_id and mt.role_id=ro.role_id
), expanded_raw as (
  select e.work_date,e.shift_template_id,e.location_id,e.role_id,
    array[e.duty_id]::uuid[] duty_ids,e.required_count,e.starts_at,e.ends_at
  from evaluated e
  where e.duty_id is not null and e.required_count>0 and e.ends_at>e.starts_at
  union all
  select mr.work_date,mr.shift_template_id,mr.location_id,mr.role_id,
    array[mr.duty_id]::uuid[],mr.required_count,ro.starts_at,ro.ends_at
  from minimum_requirements mr
  join role_occurrences ro
    on ro.work_date=mr.work_date and ro.shift_template_id=mr.shift_template_id
    and ro.location_id=mr.location_id and ro.role_id=mr.role_id
  where mr.required_count>0
  union all
  select ro.work_date,ro.shift_template_id,ro.location_id,ro.role_id,
    '{}'::uuid[],ro.generic_count-coalesce(mt.minimum_count,0),ro.starts_at,ro.ends_at
  from role_occurrences ro
  left join minimum_totals mt
    on mt.work_date=ro.work_date and mt.shift_template_id=ro.shift_template_id
    and mt.location_id=ro.location_id and mt.role_id=ro.role_id
  where ro.generic_count>coalesce(mt.minimum_count,0)
), expanded as (
  select e.work_date,e.shift_template_id,e.location_id,e.role_id,e.duty_ids,
    sum(e.required_count)::integer required_count,
    min(e.starts_at) starts_at,max(e.ends_at) ends_at
  from expanded_raw e
  group by e.work_date,e.shift_template_id,e.location_id,e.role_id,e.duty_ids
)
select public.matrix_v2_stable_uuid(
    'DEMAND_V2:'||p_scenario_id::text||':'||e.work_date::text||':'||
    e.shift_template_id::text||':'||e.role_id::text||':'||
    coalesce(array_to_string(e.duty_ids,','),'-')
  ),e.work_date,e.shift_template_id,e.location_id,e.role_id,e.duty_ids,
  e.required_count,e.starts_at,e.ends_at,
  greatest(0,round(extract(epoch from (e.ends_at-e.starts_at))/60)::integer)
from expanded e cross join guard g
where solver_private.assert_configuration_v2(
  g.valid,'ROLE_DUTY_MINIMUM_EXCEEDS_STAFFING'
)
order by e.starts_at,e.location_id,e.role_id,e.duty_ids;
$$;

comment on function solver_private.resolved_demand_v2(date,uuid,uuid,uuid) is
  'Resolves independent monthly staffing demand. No cross-location demand collapsing is applied.';

notify pgrst,'reload schema';
