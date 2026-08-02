-- GRAFIK PRO 3.0 — Matrix v2 / OR-Tools API.
-- Public RPCs expose only sanitized status and aggregate finance. Worker RPCs
-- are service-role-only and use compare-and-swap leases.

create or replace function solver_private.apply_integer_operations_v2(p_operations jsonb)
returns bigint
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_value bigint := 0;
  v_item jsonb;
  v_operation text;
begin
  for v_item in
    select value from jsonb_array_elements(coalesce(p_operations,'[]'::jsonb))
  loop
    v_operation := upper(v_item->>'operation');
    case v_operation
      when 'SET' then v_value := coalesce((v_item->>'value')::bigint,0);
      when 'ADD' then v_value := v_value + coalesce((v_item->>'value')::bigint,0);
      when 'MULTIPLY' then
        v_value := round(v_value * coalesce((v_item->>'basisPoints')::numeric,0) / 10000)::bigint;
      when 'REMOVE' then v_value := 0;
      else raise exception 'UNSUPPORTED_MATRIX_OPERATION:%',v_operation;
    end case;
  end loop;
  return greatest(v_value,0);
end;
$$;

create or replace function solver_private.canonical_json_v2(p_value jsonb)
returns text
language plpgsql
immutable
strict
set search_path = ''
as $$
declare v_type text := jsonb_typeof(p_value); v_result text;
begin
  if v_type='object' then
    select '{'||coalesce(string_agg(
      to_jsonb(e.key)::text||':'||solver_private.canonical_json_v2(e.value),
      ',' order by e.key collate "C"
    ),'')||'}' into v_result from jsonb_each(p_value) e;
    return v_result;
  elsif v_type='array' then
    select '['||coalesce(string_agg(
      solver_private.canonical_json_v2(a.value),',' order by a.ordinality
    ),'')||']' into v_result
    from jsonb_array_elements(p_value) with ordinality a(value,ordinality);
    return v_result;
  elsif v_type='number' then
    if p_value::text !~ '^-?[0-9]+(\.0+)?$' then
      raise exception 'NON_INTEGRAL_SNAPSHOT_NUMBER';
    end if;
    return ((p_value#>>'{}')::numeric::bigint)::text;
  end if;
  return p_value::text;
end;
$$;

create or replace function solver_private.assert_configuration_v2(
  p_condition boolean,p_error text
)
returns boolean
language plpgsql
stable
set search_path = ''
as $$
begin
  if not coalesce(p_condition,false) then
    raise exception '%',coalesce(nullif(p_error,''),'INVALID_SOLVER_CONFIGURATION');
  end if;
  return true;
end;
$$;

create or replace function solver_private.jsonb_deep_merge_v2(
  p_base jsonb,p_override jsonb
)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_result jsonb:=case when jsonb_typeof(p_base)='object'
    then p_base else '{}'::jsonb end;
  v_key text;
  v_value jsonb;
begin
  if p_override is null then return v_result; end if;
  if jsonb_typeof(p_override)<>'object' then return p_override; end if;
  for v_key,v_value in select e.key,e.value from jsonb_each(p_override) e
  loop
    if jsonb_typeof(v_result->v_key)='object'
      and jsonb_typeof(v_value)='object' then
      v_result:=jsonb_set(v_result,array[v_key],
        solver_private.jsonb_deep_merge_v2(v_result->v_key,v_value),true);
    else
      v_result:=jsonb_set(v_result,array[v_key],v_value,true);
    end if;
  end loop;
  return v_result;
end;
$$;

create or replace function solver_private.jsonb_deep_merge_array_v2(
  p_values jsonb[]
)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare v_result jsonb:='{}'::jsonb; v_value jsonb;
begin
  if p_values is null then return v_result; end if;
  foreach v_value in array p_values loop
    v_result:=solver_private.jsonb_deep_merge_v2(v_result,v_value);
  end loop;
  return v_result;
end;
$$;

create or replace function solver_private.resolved_demand_v2(
  p_month date,
  p_matrix_version_id uuid,
  p_scenario_id uuid,
  p_scope_role_id uuid default null
)
returns table(
  demand_id uuid,
  work_date date,
  shift_template_id uuid,
  location_id uuid,
  role_id uuid,
  duty_ids uuid[],
  required_count integer,
  starts_at timestamptz,
  ends_at timestamptz,
  duration_minutes integer
)
language sql
stable
security definer
set search_path = ''
as $$
with recursive scenario_chain as (
  select s.id,s.parent_scenario_id,s.valid_from,s.valid_to,0 as depth
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
  select d::date as work_date,st.id as shift_template_id,st.location_id,
    st.starts_at as local_start,st.ends_at as local_end,st.ends_next_day,l.timezone
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
  select o.work_date,o.shift_template_id,o.location_id,k.role_id,k.duty_id,
    solver_private.apply_integer_operations_v2(coalesce((
      select jsonb_agg(jsonb_build_object(
        'operation',sr.operation,
        'value',sr.count_value,
        'basisPoints',sr.multiplier_basis_points
      ) order by c.depth desc)
      from public.matrix_staffing_rules_v2 sr
      join scenario_chain c on c.id=sr.scenario_id
      where sr.matrix_version_id=p_matrix_version_id and sr.active
        and sr.shift_template_id=k.shift_template_id
        and sr.role_id=k.role_id
        and sr.duty_id is not distinct from k.duty_id
        and (c.valid_from is null or c.valid_from<=o.work_date)
        and (c.valid_to is null or c.valid_to>=o.work_date)
    ),'[]'::jsonb))::integer as required_count,
    ((o.work_date+o.local_start) at time zone o.timezone) as starts_at,
    (((o.work_date+case when o.ends_next_day then 1 else 0 end)+o.local_end)
      at time zone o.timezone) as ends_at
  from occurrences o
  join rule_keys k on k.shift_template_id=o.shift_template_id
), role_occurrences as (
  select e.work_date,e.shift_template_id,e.location_id,e.role_id,
    coalesce(sum(e.required_count) filter(where e.duty_id is null),0)::integer
      generic_count,
    min(e.starts_at) starts_at,max(e.ends_at) ends_at
  from evaluated e
  where e.required_count>0 and e.ends_at>e.starts_at
  group by e.work_date,e.shift_template_id,e.location_id,e.role_id
), explicit_counts as (
  select e.work_date,e.shift_template_id,e.location_id,e.role_id,e.duty_id,
    sum(e.required_count)::integer required_count
  from evaluated e
  where e.duty_id is not null and e.required_count>0 and e.ends_at>e.starts_at
  group by e.work_date,e.shift_template_id,e.location_id,e.role_id,e.duty_id
), minimum_requirements as (
  select ro.work_date,ro.shift_template_id,ro.location_id,ro.role_id,rd.duty_id,
    greatest(rd.minimum_count-coalesce(ec.required_count,0),0)::integer
      required_count
  from role_occurrences ro
  join public.matrix_role_duties_v2 rd
    on rd.matrix_version_id=p_matrix_version_id and rd.role_id=ro.role_id
    and rd.active and rd.assignment_mode='REQUIRED' and rd.minimum_count>0
  left join explicit_counts ec
    on ec.work_date=ro.work_date
    and ec.shift_template_id=ro.shift_template_id
    and ec.location_id=ro.location_id and ec.role_id=ro.role_id
    and ec.duty_id=rd.duty_id
), minimum_totals as (
  select mr.work_date,mr.shift_template_id,mr.location_id,mr.role_id,
    sum(mr.required_count)::integer minimum_count
  from minimum_requirements mr
  group by mr.work_date,mr.shift_template_id,mr.location_id,mr.role_id
), guard as (
  select coalesce(bool_and(
    coalesce(mt.minimum_count,0)<=ro.generic_count
  ),true) valid
  from role_occurrences ro
  left join minimum_totals mt
    on mt.work_date=ro.work_date
    and mt.shift_template_id=ro.shift_template_id
    and mt.location_id=ro.location_id and mt.role_id=ro.role_id
), expanded_raw as (
  -- An explicitly duty-scoped staffing rule makes every seat in that rule
  -- carry the duty. It first satisfies that duty's role minimum. Only the
  -- remaining minimum is carved out of generic role seats; all other generic
  -- seats stay duty-neutral.
  select e.work_date,e.shift_template_id,e.location_id,e.role_id,
    array[e.duty_id]::uuid[] duty_ids,e.required_count,e.starts_at,e.ends_at
  from evaluated e
  where e.duty_id is not null and e.required_count>0 and e.ends_at>e.starts_at
  union all
  select mr.work_date,mr.shift_template_id,mr.location_id,mr.role_id,
    array[mr.duty_id]::uuid[] duty_ids,mr.required_count,
    ro.starts_at,ro.ends_at
  from minimum_requirements mr
  join role_occurrences ro
    on ro.work_date=mr.work_date and ro.shift_template_id=mr.shift_template_id
    and ro.location_id=mr.location_id and ro.role_id=mr.role_id
  where mr.required_count>0
  union all
  select ro.work_date,ro.shift_template_id,ro.location_id,ro.role_id,
    '{}'::uuid[] duty_ids,
    ro.generic_count-coalesce(mt.minimum_count,0) required_count,
    ro.starts_at,ro.ends_at
  from role_occurrences ro
  left join minimum_totals mt
    on mt.work_date=ro.work_date
    and mt.shift_template_id=ro.shift_template_id
    and mt.location_id=ro.location_id and mt.role_id=ro.role_id
  where ro.generic_count>coalesce(mt.minimum_count,0)
), expanded as (
  -- Grouping makes slot-group identifiers unique even when an explicit rule
  -- and a residual role minimum address the same duty.
  select e.work_date,e.shift_template_id,e.location_id,e.role_id,e.duty_ids,
    sum(e.required_count)::integer required_count,
    min(e.starts_at) starts_at,max(e.ends_at) ends_at
  from expanded_raw e
  group by e.work_date,e.shift_template_id,e.location_id,e.role_id,e.duty_ids
)
select
  public.matrix_v2_stable_uuid(
    'DEMAND_V2:'||p_scenario_id::text||':'||e.work_date::text||':'||
    e.shift_template_id::text||':'||e.role_id::text||':'||
    coalesce(array_to_string(e.duty_ids,','),'-')
  ) as demand_id,
  e.work_date,e.shift_template_id,e.location_id,e.role_id,e.duty_ids,
  e.required_count,e.starts_at,e.ends_at,
  greatest(0,round(extract(epoch from (e.ends_at-e.starts_at))/60)::integer)
from expanded e
cross join guard g
where solver_private.assert_configuration_v2(
  g.valid,'ROLE_DUTY_MINIMUM_EXCEEDS_STAFFING'
)
order by e.starts_at,e.location_id,e.role_id,e.duty_ids;
$$;

create or replace function solver_private.resolve_budget_operations_v2(
  p_operations jsonb
)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_value bigint := 0;
  v_present boolean := false;
  v_item jsonb;
  v_operation text;
begin
  for v_item in
    select value from jsonb_array_elements(coalesce(p_operations,'[]'::jsonb))
  loop
    v_operation := upper(v_item->>'operation');
    case v_operation
      when 'SET' then
        v_value := coalesce((v_item->>'value')::bigint,0);
        v_present := true;
      when 'ADD' then
        v_value := case when v_present then v_value else 0 end
          +coalesce((v_item->>'value')::bigint,0);
        v_present := true;
      when 'MULTIPLY' then
        if v_present then
          v_value := round(
            v_value*coalesce((v_item->>'basisPoints')::numeric,0)/10000
          )::bigint;
        end if;
      when 'REMOVE' then
        v_value := 0;
        v_present := false;
      else raise exception 'UNSUPPORTED_MATRIX_OPERATION:%',v_operation;
    end case;
  end loop;
  return jsonb_build_object(
    'present',v_present,'amountMinor',greatest(v_value,0)
  );
end;
$$;

create or replace function solver_private.resolved_budgets_v2(
  p_month date,
  p_matrix_version_id uuid,
  p_scenario_id uuid,
  p_scope_role_id uuid default null
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
with recursive scenario_chain as (
  select s.id,s.parent_scenario_id,0 depth
  from public.matrix_scenarios_v2 s
  where s.id=p_scenario_id and s.matrix_version_id=p_matrix_version_id
  union all
  select parent.id,parent.parent_scenario_id,c.depth+1
  from public.matrix_scenarios_v2 parent
  join scenario_chain c on c.parent_scenario_id=parent.id
  where parent.matrix_version_id=p_matrix_version_id and c.depth<32
), applicable as (
  select b.*,c.depth
  from public.matrix_scenario_budgets_v2 b
  join scenario_chain c on c.id=b.scenario_id
  where b.matrix_version_id=p_matrix_version_id
    and (b.budget_month is null
      or b.budget_month=date_trunc('month',p_month)::date)
    and (p_scope_role_id is null or b.role_id is null or b.role_id=p_scope_role_id)
), grouped as (
  select a.location_id,a.role_id,a.duty_id,
    jsonb_agg(jsonb_build_object(
      'operation',a.operation,'value',a.amount_minor,
      'basisPoints',a.multiplier_basis_points
    ) order by a.depth desc,(a.budget_month is not null),a.id) operations,
    (array_agg(a.hard_limit order by a.depth asc,
      (a.budget_month is not null) desc,a.id desc)
      filter(where a.hard_limit is not null))[1] hard_limit,
    (array_agg(a.warning_percent order by a.depth asc,
      (a.budget_month is not null) desc,a.id desc)
      filter(where a.warning_percent is not null))[1] warning_percent,
    max(a.currency) currency
  from applicable a
  group by a.location_id,a.role_id,a.duty_id
), resolved as (
  select g.*,solver_private.resolve_budget_operations_v2(g.operations) state
  from grouped g
)
select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
  'id',public.matrix_v2_stable_uuid(
    'BUDGET_SCOPE_V2:'||p_matrix_version_id::text||':'||
    coalesce(r.location_id::text,'-')||':'||coalesce(r.role_id::text,'-')||':'||
    coalesce(r.duty_id::text,'-')
  ),
  'locationId',r.location_id,'roleId',r.role_id,'dutyId',r.duty_id,
  'amountMinor',(r.state->>'amountMinor')::bigint,
  'hard',coalesce(r.hard_limit,false),
  'warningPercent',r.warning_percent,'currency',r.currency
)) order by r.location_id nulls first,r.role_id nulls first,
  r.duty_id nulls first),'[]'::jsonb)
from resolved r
where coalesce((r.state->>'present')::boolean,false);
$$;

revoke all on function solver_private.apply_integer_operations_v2(jsonb)
  from public,anon,authenticated;
revoke all on function solver_private.canonical_json_v2(jsonb)
  from public,anon,authenticated;
revoke all on function solver_private.assert_configuration_v2(boolean,text)
  from public,anon,authenticated;
revoke all on function solver_private.jsonb_deep_merge_v2(jsonb,jsonb)
  from public,anon,authenticated;
revoke all on function solver_private.jsonb_deep_merge_array_v2(jsonb[])
  from public,anon,authenticated;
revoke all on function solver_private.resolved_demand_v2(date,uuid,uuid,uuid)
  from public,anon,authenticated;
revoke all on function solver_private.resolve_budget_operations_v2(jsonb)
  from public,anon,authenticated;
revoke all on function solver_private.resolved_budgets_v2(date,uuid,uuid,uuid)
  from public,anon,authenticated;
grant execute on function solver_private.apply_integer_operations_v2(jsonb) to service_role;
grant execute on function solver_private.canonical_json_v2(jsonb) to service_role;
grant execute on function solver_private.assert_configuration_v2(boolean,text)
  to service_role;
grant execute on function solver_private.jsonb_deep_merge_v2(jsonb,jsonb)
  to service_role;
grant execute on function solver_private.jsonb_deep_merge_array_v2(jsonb[])
  to service_role;
grant execute on function solver_private.resolved_demand_v2(date,uuid,uuid,uuid) to service_role;
grant execute on function solver_private.resolve_budget_operations_v2(jsonb)
  to service_role;
grant execute on function solver_private.resolved_budgets_v2(date,uuid,uuid,uuid)
  to service_role;

create or replace function solver_private.build_snapshot_payload_v2(
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
set search_path = ''
as $$
declare
  v_month date := date_trunc('month',p_month)::date;
  v_period_end date := (date_trunc('month',p_month)+interval '1 month - 1 day')::date;
  v_matrix public.matrix_versions%rowtype;
  v_settings jsonb := '{}'::jsonb;
  v_snapshot jsonb;
  v_scenario record;
  v_seed integer;
  v_currency text;
  v_timezone text;
  v_budgets jsonb := '[]'::jsonb;
  v_external jsonb := '[]'::jsonb;
  v_baseline jsonb := '[]'::jsonb;
  v_locked jsonb := '[]'::jsonb;
  v_slot_count bigint:=0;
  v_employee_count bigint:=0;
begin
  select * into v_matrix
  from public.matrix_versions mv
  where mv.id=p_matrix_version_id and mv.schema_version>=2;
  if v_matrix.id is null then raise exception 'MATRIX_V2_NOT_FOUND'; end if;
  if coalesce(v_matrix.content_hash,'') !~ '^[0-9a-f]{64}$'
    or coalesce(v_matrix.workforce_hash,'') !~ '^[0-9a-f]{64}$' then
    raise exception 'MATRIX_V2_NOT_PUBLISHED';
  end if;

  v_currency := upper(coalesce(v_matrix.settings->>'currency',''));
  if not public.matrix_v2_is_iso_4217_currency(v_currency) then
    raise exception 'INVALID_MATRIX_CURRENCY';
  end if;
  if exists(
    select 1 from public.matrix_pay_rules_v2 p
    where p.matrix_version_id=p_matrix_version_id and p.active
      and p.currency<>v_currency
  ) or exists(
    select 1 from public.matrix_scenario_budgets_v2 b
    where b.matrix_version_id=p_matrix_version_id and b.currency<>v_currency
  ) or exists(
    select 1
    from public.employee_pay_rates_v2 r
    join public.matrix_employee_profiles_v2 profile
      on profile.matrix_version_id=p_matrix_version_id
      and profile.employee_id=r.employee_id
      and profile.active and profile.archived_at is null
      and (profile.employment_start is null or profile.employment_start<=v_period_end)
      and (profile.employment_end is null or profile.employment_end>=v_month)
    where r.active and r.valid_from<=v_period_end
      and (r.valid_to is null or r.valid_to>=v_month)
      and (p_scope_role_id is null or exists(
        select 1 from public.matrix_employee_roles_v2 role_grant
        where role_grant.matrix_version_id=p_matrix_version_id
          and role_grant.employee_id=profile.employee_id
          and role_grant.role_id=p_scope_role_id and role_grant.active
          and (role_grant.valid_from is null or role_grant.valid_from<=v_period_end)
          and (role_grant.valid_to is null or role_grant.valid_to>=v_month)
      ))
      and r.currency<>v_currency
  ) then raise exception 'MIXED_CURRENCIES_UNSUPPORTED'; end if;

  v_settings := coalesce(v_matrix.settings,'{}'::jsonb);
  for v_scenario in
    with recursive chain as (
      select s.id,s.parent_scenario_id,s.settings_overrides,0 depth
      from public.matrix_scenarios_v2 s
      where s.id=p_scenario_id and s.matrix_version_id=p_matrix_version_id
      union all
      select p.id,p.parent_scenario_id,p.settings_overrides,c.depth+1
      from public.matrix_scenarios_v2 p join chain c on c.parent_scenario_id=p.id
      where p.matrix_version_id=p_matrix_version_id and c.depth<32
    )
    select * from chain order by depth desc
  loop
    v_settings := v_settings||coalesce(v_scenario.settings_overrides,'{}'::jsonb);
  end loop;
  v_settings := (v_settings-'currency')||jsonb_build_object('currency',v_currency);
  v_timezone := nullif(v_settings->>'timezone','');
  if not exists(select 1 from pg_timezone_names where name=v_timezone) then
    raise exception 'INVALID_MATRIX_TIMEZONE';
  end if;
  if coalesce(v_settings->>'minimumRestMinutes','') !~ '^[0-9]+$'
    or (v_settings->>'minimumRestMinutes')::integer<0
    or coalesce(v_settings->>'maximumShiftsPerDay','') !~ '^[0-9]+$'
    or (v_settings->>'maximumShiftsPerDay')::integer not between 1 and 24
    or jsonb_typeof(v_settings->'missingAvailabilityMeansAvailable')<>'boolean'
    or jsonb_typeof(v_settings->'requireOptimal')<>'boolean'
  then raise exception 'INVALID_MATRIX_SETTINGS'; end if;
  if exists(
    select 1
    from public.matrix_employee_profiles_v2 profile
    cross join lateral generate_series(
      greatest(v_month,coalesce(profile.employment_start,v_month)),
      least(v_period_end,coalesce(profile.employment_end,v_period_end)),
      interval '1 day'
    ) work_day
    where profile.matrix_version_id=p_matrix_version_id
      and profile.active and profile.archived_at is null
      and (p_scope_role_id is null or exists(
        select 1 from public.matrix_employee_roles_v2 role_grant
        where role_grant.matrix_version_id=p_matrix_version_id
          and role_grant.employee_id=profile.employee_id
          and role_grant.role_id=p_scope_role_id and role_grant.active
          and (role_grant.valid_from is null
            or role_grant.valid_from<=work_day::date)
          and (role_grant.valid_to is null or role_grant.valid_to>=work_day::date)
      ))
      and not exists(
        select 1 from public.employee_pay_rates_v2 rate
        where rate.employee_id=profile.employee_id and rate.active
          and rate.valid_from<=work_day::date
          and (rate.valid_to is null or rate.valid_to>=work_day::date)
      )
  ) then raise exception 'EMPLOYEE_PAY_RATE_COVERAGE_GAP'; end if;
  v_budgets := solver_private.resolved_budgets_v2(
    v_month,p_matrix_version_id,p_scenario_id,p_scope_role_id
  );

  select coalesce(sum(d.required_count),0) into v_slot_count
  from solver_private.resolved_demand_v2(
    v_month,p_matrix_version_id,p_scenario_id,p_scope_role_id
  ) d;
  select count(*) into v_employee_count
  from public.matrix_employee_profiles_v2 profile
  where profile.matrix_version_id=p_matrix_version_id
    and profile.active and profile.archived_at is null
    and (profile.employment_start is null or profile.employment_start<=v_period_end)
    and (profile.employment_end is null or profile.employment_end>=v_month)
    and (p_scope_role_id is null or exists(
      select 1 from public.matrix_employee_roles_v2 role_grant
      where role_grant.matrix_version_id=p_matrix_version_id
        and role_grant.employee_id=profile.employee_id
        and role_grant.role_id=p_scope_role_id and role_grant.active
        and (role_grant.valid_from is null or role_grant.valid_from<=v_period_end)
        and (role_grant.valid_to is null or role_grant.valid_to>=v_month)
    ));
  if v_slot_count>25000 then raise exception 'SOLVER_CAPACITY_SLOT_LIMIT'; end if;
  if v_employee_count>5000 then raise exception 'SOLVER_CAPACITY_EMPLOYEE_LIMIT'; end if;
  if v_slot_count*v_employee_count>2000000 then
    raise exception 'SOLVER_CAPACITY_VARIABLE_LIMIT';
  end if;

  v_seed := coalesce(
    nullif(v_settings->>'randomSeed','')::integer,
    (abs(hashtextextended(p_run_id::text,0))%2147483647)::integer
  );

  select jsonb_build_object(
    'schemaVersion',2,
    'runId',p_run_id,
    'matrixVersionId',p_matrix_version_id,
    'matrixContentHash',v_matrix.content_hash,
    'workforceHash',v_matrix.workforce_hash,
    'scenarioId',p_scenario_id,
    'currency',v_currency,
    'periodStart',v_month,
    'periodEnd',v_period_end,
    'scope',jsonb_build_object('type',p_scope_type,'roleId',p_scope_role_id),
    'settings',jsonb_build_object(
      'timezone',v_timezone,
      'missingAvailabilityMeansAvailable',(v_settings->>'missingAvailabilityMeansAvailable')::boolean,
      'defaultMinimumRestMinutes',(v_settings->>'minimumRestMinutes')::integer,
      'maximumShiftsPerDay',(v_settings->>'maximumShiftsPerDay')::integer,
      'onlyMorningBeforeMinute',nullif(v_settings->>'onlyMorningBeforeMinute','')::integer,
      'onlyEveningAfterMinute',nullif(v_settings->>'onlyEveningAfterMinute','')::integer,
      'requireOptimal',(v_settings->>'requireOptimal')::boolean,
      'randomSeed',v_seed
    ),
    'strategies',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',s.id,'code',s.code,'label',s.name,'description',s.description,
        'sortOrder',ss.sort_order,
        'timeLimitSeconds',coalesce(
          nullif(ss.solver_overrides->>'maxTimeSeconds','')::integer,
          nullif(s.solver_options->>'maxTimeSeconds','')::integer,300
        ),
        'randomSeed',coalesce(
          nullif(ss.solver_overrides->>'randomSeed','')::integer,
          nullif(s.solver_options->>'randomSeed','')::integer,v_seed
        ),
        'objectiveTerms',coalesce((
          select jsonb_agg(jsonb_build_object(
            'tier',coalesce(nullif(cfg.value->>'tier','')::smallint,o.tier),
            'metric',o.metric_code,
            'weight',coalesce(nullif(cfg.value->>'weight','')::bigint,o.weight),
            'direction',case upper(coalesce(cfg.value->>'direction',o.direction))
              when 'MAXIMIZE' then 'MAX' when 'MAX' then 'MAX' else 'MIN' end,
            'tolerance',coalesce(
              nullif(cfg.value->>'tolerance','')::bigint,o.tolerance
            ),
            'parameters',o.parameters||coalesce(cfg.value->'parameters','{}'::jsonb)
          ) order by
            coalesce(nullif(cfg.value->>'tier','')::smallint,o.tier),
            o.sort_order,o.metric_code)
          from public.matrix_strategy_objectives_v2 o
          cross join lateral (select coalesce(
            ss.objective_overrides->upper(o.metric_code),'{}'::jsonb
          ) value) cfg
          where o.strategy_id=s.id and o.matrix_version_id=p_matrix_version_id
            and o.active and coalesce((cfg.value->>'active')::boolean,true)
        ),'[]'::jsonb)
      ) order by ss.sort_order,s.sort_order,s.code)
      from (
        with recursive scenario_chain as (
          select sc.id,sc.parent_scenario_id,0 depth
          from public.matrix_scenarios_v2 sc
          where sc.id=p_scenario_id and sc.matrix_version_id=p_matrix_version_id
          union all
          select parent.id,parent.parent_scenario_id,chain.depth+1
          from public.matrix_scenarios_v2 parent
          join scenario_chain chain on chain.parent_scenario_id=parent.id
          where parent.matrix_version_id=p_matrix_version_id and chain.depth<32
        ), raw_links as (
          select link.id,link.strategy_id,link.sort_order,link.active,
            link.objective_overrides,link.solver_overrides,chain.depth
          from scenario_chain chain
          join public.matrix_scenario_strategies_v2 link
            on link.scenario_id=chain.id
          where link.matrix_version_id=p_matrix_version_id
        )
        select link.strategy_id,
          (array_agg(link.sort_order order by link.depth,link.id))[1] sort_order,
          (array_agg(link.active order by link.depth,link.id))[1] active,
          solver_private.jsonb_deep_merge_array_v2(array_agg(
            link.objective_overrides order by link.depth desc,link.id
          )) objective_overrides,
          solver_private.jsonb_deep_merge_array_v2(array_agg(
            link.solver_overrides order by link.depth desc,link.id
          )) solver_overrides
        from raw_links link
        group by link.strategy_id
      ) ss
      join public.matrix_strategies_v2 s
        on s.id=ss.strategy_id and s.matrix_version_id=p_matrix_version_id
      where ss.active and s.active
    ),'[]'::jsonb),
    'roles',coalesce((
      select jsonb_agg(jsonb_build_object('id',r.id,'code',r.code,'label',r.name)
        order by r.sort_order,r.code)
      from public.matrix_roles_v2 r
      where r.matrix_version_id=p_matrix_version_id and r.active
    ),'[]'::jsonb),
    'duties',coalesce((
      select jsonb_agg(jsonb_build_object('id',d.id,'code',d.code,'label',d.name)
        order by d.sort_order,d.code)
      from public.matrix_duties_v2 d
      where d.matrix_version_id=p_matrix_version_id and d.active
    ),'[]'::jsonb),
    'locations',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',l.id,'code',l.code,'label',l.name,'timezone',l.timezone
      ) order by l.sort_order,l.code)
      from public.matrix_locations_v2 l
      where l.matrix_version_id=p_matrix_version_id and l.active
    ),'[]'::jsonb),
    'shiftTemplates',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',st.id,'locationId',st.location_id,'code',st.code,'label',st.name,
        'startTime',to_char(st.starts_at,'HH24:MI'),
        'endTime',to_char(st.ends_at,'HH24:MI'),
        'endsNextDay',st.ends_next_day,'weekdays',to_jsonb(st.day_mask)
      ) order by st.sort_order,st.code)
      from public.matrix_shift_templates_v2 st
      join public.matrix_locations_v2 l on l.id=st.location_id and l.active
      where st.matrix_version_id=p_matrix_version_id and st.active
    ),'[]'::jsonb),
    'demand',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',d.demand_id,'shiftTemplateId',d.shift_template_id,
        'roleId',d.role_id,'dutyIds',to_jsonb(d.duty_ids),
        'requiredCount',d.required_count,'dates',jsonb_build_array(d.work_date)
      ) order by d.starts_at,d.location_id,d.role_id,d.demand_id)
      from solver_private.resolved_demand_v2(
        v_month,p_matrix_version_id,p_scenario_id,p_scope_role_id
      ) d
    ),'[]'::jsonb),
    'slots',coalesce((
      select jsonb_agg(jsonb_build_object(
        'slotId',d.work_date::text||'|'||d.shift_template_id::text||'|'||
          d.role_id::text||'|'||coalesce(array_to_string(d.duty_ids,','),'-')||'|'||
          d.demand_id::text||'|'||seat.seat_index::text,
        'demandId',d.demand_id,
        'occurrenceId',d.work_date::text||'|'||d.shift_template_id::text,
        'seatIndex',seat.seat_index,'date',d.work_date,
        'shiftTemplateId',d.shift_template_id,'locationId',d.location_id,
        'roleId',d.role_id,'dutyIds',to_jsonb(d.duty_ids),
        'start',d.starts_at,'end',d.ends_at,'durationMinutes',d.duration_minutes
      ) order by d.starts_at,d.location_id,d.role_id,
        d.work_date::text||'|'||d.shift_template_id::text||'|'||d.role_id::text||'|'||
        coalesce(array_to_string(d.duty_ids,','),'-')||'|'||d.demand_id::text||'|'||seat.seat_index::text)
      from solver_private.resolved_demand_v2(
        v_month,p_matrix_version_id,p_scenario_id,p_scope_role_id
      ) d
      cross join lateral generate_series(1,d.required_count) seat(seat_index)
    ),'[]'::jsonb),
    'employees',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',profile.employee_id,
        'roleIds',coalesce((select jsonb_agg(er.role_id::text order by er.role_id::text)
          from public.matrix_employee_roles_v2 er
          where er.matrix_version_id=p_matrix_version_id
            and er.employee_id=profile.employee_id and er.active
            and (er.valid_from is null or er.valid_from<=v_period_end)
            and (er.valid_to is null or er.valid_to>=v_month)),'[]'::jsonb),
        'roleGrants',coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'roleId',er.role_id,'validFrom',er.valid_from,'validTo',er.valid_to
          )) order by er.role_id::text,er.valid_from nulls first,er.id)
          from public.matrix_employee_roles_v2 er
          where er.matrix_version_id=p_matrix_version_id
            and er.employee_id=profile.employee_id and er.active
            and (er.valid_from is null or er.valid_from<=v_period_end)
            and (er.valid_to is null or er.valid_to>=v_month)),'[]'::jsonb),
        'dutyIds',coalesce((select jsonb_agg(distinct ed.duty_id::text order by ed.duty_id::text)
          from public.matrix_employee_duties_v2 ed
          where ed.matrix_version_id=p_matrix_version_id
            and ed.employee_id=profile.employee_id and ed.active
            and ed.role_id is null and ed.location_id is null
            and (ed.valid_from is null or ed.valid_from<=v_period_end)
            and (ed.valid_to is null or ed.valid_to>=v_month)),'[]'::jsonb),
        'dutyGrants',coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'dutyId',ed.duty_id,'roleId',ed.role_id,'locationId',ed.location_id,
            'validFrom',ed.valid_from,'validTo',ed.valid_to
          )) order by ed.duty_id::text,ed.role_id::text nulls first,
            ed.location_id::text nulls first,ed.valid_from nulls first,ed.id)
          from public.matrix_employee_duties_v2 ed
          where ed.matrix_version_id=p_matrix_version_id
            and ed.employee_id=profile.employee_id and ed.active
            and (ed.valid_from is null or ed.valid_from<=v_period_end)
            and (ed.valid_to is null or ed.valid_to>=v_month)),'[]'::jsonb),
        'locationIds',coalesce((select jsonb_agg(el.location_id::text order by el.location_id::text)
          from public.matrix_employee_locations_v2 el
          where el.matrix_version_id=p_matrix_version_id
            and el.employee_id=profile.employee_id and el.active
            and el.standard_allowed
            and (el.valid_from is null or el.valid_from<=v_period_end)
            and (el.valid_to is null or el.valid_to>=v_month)),'[]'::jsonb),
        'locationGrants',coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'locationId',el.location_id,'standardAllowed',el.standard_allowed,
            'overtimeAllowed',el.overtime_allowed,'validFrom',el.valid_from,
            'validTo',el.valid_to
          )) order by el.location_id::text,el.valid_from nulls first,el.id)
          from public.matrix_employee_locations_v2 el
          where el.matrix_version_id=p_matrix_version_id
            and el.employee_id=profile.employee_id and el.active
            and (el.valid_from is null or el.valid_from<=v_period_end)
            and (el.valid_to is null or el.valid_to>=v_month)),'[]'::jsonb),
        'homeLocationIds',coalesce((select jsonb_agg(el.location_id::text order by el.location_id::text)
          from public.matrix_employee_locations_v2 el
          where el.matrix_version_id=p_matrix_version_id
            and el.employee_id=profile.employee_id
            and el.active and el.home_location),'[]'::jsonb),
        -- Legacy fields are only a compatibility fallback when no dated v2
        -- period covers a slot; they must never borrow a future period's rate.
        'baseHourlyRateMinor',round(e.hourly_rate*100)::bigint,
        'contractCode',coalesce(hr.contract_type,'OTHER'),
        'payRatePeriods',coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'validFrom',pr.valid_from,'validTo',pr.valid_to,
            'baseRateMinor',pr.base_rate_minor,
            'contractCode',coalesce(pr.contract_type,hr.contract_type,'OTHER')
          )) order by pr.valid_from,pr.id)
          from public.employee_pay_rates_v2 pr
          where pr.employee_id=profile.employee_id and pr.active
            and pr.valid_from<=v_period_end
            and (pr.valid_to is null or pr.valid_to>=v_month)),'[]'::jsonb),
        'employmentStart',profile.employment_start,
        'employmentEnd',profile.employment_end,
        'nominalMonthlyMinutes',profile.nominal_monthly_minutes,
        'maximumMonthlyMinutes',profile.maximum_monthly_minutes,
        'maximumWeeklyMinutes',profile.maximum_weekly_minutes,
        'maximumShiftsPerDay',(v_settings->>'maximumShiftsPerDay')::integer,
        'maximumConsecutiveDays',profile.maximum_consecutive_days,
        'minimumRestMinutes',coalesce(
          profile.minimum_rest_minutes,(v_settings->>'minimumRestMinutes')::integer
        ),
        'noWeekends',profile.no_weekends,
        'onlyMorningBeforeMinute',case when profile.only_morning then
          nullif(v_settings->>'onlyMorningBeforeMinute','')::integer else null end,
        'onlyEveningAfterMinute',case when profile.only_evening then
          nullif(v_settings->>'onlyEveningAfterMinute','')::integer else null end,
        'preferredShiftTemplateIds',coalesce((
          select jsonb_agg(st.id::text order by st.id::text)
          from public.matrix_shift_templates_v2 st
          where st.matrix_version_id=p_matrix_version_id and st.active
            and profile.preferred_shift_code is not null
            and st.code=profile.preferred_shift_code
        ),'[]'::jsonb),
        'preferredLocationIds',coalesce((
          select jsonb_agg(preferred.location_id order by preferred.location_id)
          from (
            select distinct ml.id::text location_id
            from public.employee_preferences ep
            join public.matrix_locations_v2 ml
              on ml.matrix_version_id=p_matrix_version_id and ml.active
              and (
                ml.id=case
                  when coalesce(
                    ep.preference_value->>'locationId',
                    ep.preference_value->>'location_id'
                  ) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
                  then coalesce(
                    ep.preference_value->>'locationId',
                    ep.preference_value->>'location_id'
                  )::uuid
                  else null
                end
                or upper(ml.code)=upper(coalesce(
                  ep.preference_value->>'locationCode',
                  ep.preference_value->>'location',
                  ep.preference_value->>'code'
                ))
              )
            where ep.employee_id=profile.employee_id and ep.status='ACTIVE'
              and ep.preference_type='PREFERRED_LOCATION'
              and ep.valid_from<=v_period_end and ep.valid_to>=v_month
          ) preferred
        ),'[]'::jsonb),
        'softDayOffDates',coalesce((
          select jsonb_agg(gs::date order by gs::date)
          from public.employee_preferences ep
          cross join lateral generate_series(ep.valid_from,ep.valid_to,interval '1 day') gs
          where ep.employee_id=profile.employee_id and ep.status='ACTIVE'
            and ep.preference_type='OTHER'
            and ep.preference_value->>'kind'='DAY_OFF'
            and ep.valid_from<=v_period_end and ep.valid_to>=v_month
        ),'[]'::jsonb)
      ) order by profile.employee_no)
      from public.matrix_employee_profiles_v2 profile
      join public.employees e on e.id=profile.employee_id
      left join public.employee_hr_profiles hr
        on hr.employee_id=profile.employee_id
      where profile.matrix_version_id=p_matrix_version_id
        and profile.active and profile.archived_at is null
        and (profile.employment_start is null
          or profile.employment_start<=v_period_end)
        and (profile.employment_end is null or profile.employment_end>=v_month)
        and (p_scope_role_id is null or exists(
          select 1 from public.matrix_employee_roles_v2 er
          where er.matrix_version_id=p_matrix_version_id
            and er.employee_id=profile.employee_id
            and er.role_id=p_scope_role_id and er.active
            and (er.valid_from is null or er.valid_from<=v_period_end)
            and (er.valid_to is null or er.valid_to>=v_month)
        ))
    ),'[]'::jsonb),
    'availabilityWindows',coalesce((
      select jsonb_agg(jsonb_build_object(
        'employeeId',c.employee_id,'start',lower(c.time_range),'end',upper(c.time_range)
      ) order by c.employee_id,lower(c.time_range))
      from public.employee_time_constraints_v2 c
      where c.status='ACTIVE' and c.constraint_kind='AVAILABLE_WINDOW'
        and c.time_range && tstzrange(v_month::timestamp at time zone v_timezone,
          (v_period_end+1)::timestamp at time zone v_timezone,'[)')
        and exists(
          select 1 from public.matrix_employee_profiles_v2 profile
          where profile.matrix_version_id=p_matrix_version_id
            and profile.employee_id=c.employee_id
            and profile.active and profile.archived_at is null
            and (profile.employment_start is null or profile.employment_start<=v_period_end)
            and (profile.employment_end is null or profile.employment_end>=v_month)
            and (p_scope_role_id is null or exists(
              select 1 from public.matrix_employee_roles_v2 role_grant
              where role_grant.matrix_version_id=p_matrix_version_id
                and role_grant.employee_id=profile.employee_id
                and role_grant.role_id=p_scope_role_id and role_grant.active
                and (role_grant.valid_from is null or role_grant.valid_from<=v_period_end)
                and (role_grant.valid_to is null or role_grant.valid_to>=v_month)
            ))
        )
    ),'[]'::jsonb),
    'hardBlocks',coalesce((
      select jsonb_agg(jsonb_build_object(
        'employeeId',c.employee_id,'start',lower(c.time_range),'end',upper(c.time_range),
        'kind',c.constraint_kind,'source',c.source
      ) order by c.employee_id,lower(c.time_range))
      from public.employee_time_constraints_v2 c
      where c.status='ACTIVE' and c.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
        and c.time_range && tstzrange(v_month::timestamp at time zone v_timezone,
          (v_period_end+1)::timestamp at time zone v_timezone,'[)')
        and exists(
          select 1 from public.matrix_employee_profiles_v2 profile
          where profile.matrix_version_id=p_matrix_version_id
            and profile.employee_id=c.employee_id
            and profile.active and profile.archived_at is null
            and (profile.employment_start is null or profile.employment_start<=v_period_end)
            and (profile.employment_end is null or profile.employment_end>=v_month)
            and (p_scope_role_id is null or exists(
              select 1 from public.matrix_employee_roles_v2 role_grant
              where role_grant.matrix_version_id=p_matrix_version_id
                and role_grant.employee_id=profile.employee_id
                and role_grant.role_id=p_scope_role_id and role_grant.active
                and (role_grant.valid_from is null or role_grant.valid_from<=v_period_end)
                and (role_grant.valid_to is null or role_grant.valid_to>=v_month)
            ))
        )
    ),'[]'::jsonb),
    'externalAssignments','[]'::jsonb,
    'lockedAssignments','[]'::jsonb,
    'baselineAssignments','[]'::jsonb,
    'payRules',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',pr.id,'calculationType',pr.calculation_method,
        'currency',pr.currency,
        'values',jsonb_strip_nulls(jsonb_build_object(
          'amountMinor',coalesce(ov.amount_minor,pr.amount_minor),
          'rateMinorPerHour',coalesce(ov.rate_minor_per_hour,pr.rate_minor_per_hour),
          'percentBasisPoints',coalesce(ov.percent_basis_points,pr.percent_basis_points),
          'multiplierBasisPoints',coalesce(ov.multiplier_basis_points,pr.multiplier_basis_points),
          'thresholdMinutes',pr.threshold_minutes
        )),
        'conditions',coalesce(pr.condition_expression->'conditions','[]'::jsonb)
          ||coalesce((select jsonb_build_array(jsonb_build_object(
              'field','role_id','operator','IN','value',jsonb_agg(x.role_id::text order by x.role_id::text)
            )) from public.matrix_pay_rule_roles_v2 x where x.pay_rule_id=pr.id
              having count(*)>0),'[]'::jsonb)
          ||coalesce((select jsonb_build_array(jsonb_build_object(
              'field','duty_ids','operator',
              case when bool_or(x.match_mode='ALL') then 'CONTAINS_ALL' else 'CONTAINS_ANY' end,
              'value',jsonb_agg(x.duty_id::text order by x.duty_id::text)
            )) from public.matrix_pay_rule_duties_v2 x where x.pay_rule_id=pr.id
              having count(*)>0),'[]'::jsonb)
          ||coalesce((select jsonb_build_array(jsonb_build_object(
              'field','location_id','operator','IN',
              'value',jsonb_agg(x.location_id::text order by x.location_id::text)
            )) from public.matrix_pay_rule_locations_v2 x where x.pay_rule_id=pr.id
              having count(*)>0),'[]'::jsonb)
          ||coalesce((select jsonb_build_array(jsonb_build_object(
              'field','shift_template_id','operator','IN',
              'value',jsonb_agg(x.shift_template_id::text order by x.shift_template_id::text)
            )) from public.matrix_pay_rule_shifts_v2 x where x.pay_rule_id=pr.id
              having count(*)>0),'[]'::jsonb),
        'stackingGroup',pr.stacking_group,'stackingMode',pr.stacking_mode,
        'priority',pr.priority,'active',pr.active and coalesce(ov.enabled,true),
        'effectiveFrom',pr.valid_from,'effectiveTo',pr.valid_to,
        'dayMask',to_jsonb(pr.day_mask),'localStart',pr.local_start,'localEnd',pr.local_end,
        'roleIds',coalesce((select jsonb_agg(x.role_id::text order by x.role_id::text)
          from public.matrix_pay_rule_roles_v2 x where x.pay_rule_id=pr.id),'[]'::jsonb),
        'dutyIds',coalesce((select jsonb_agg(x.duty_id::text order by x.duty_id::text)
          from public.matrix_pay_rule_duties_v2 x where x.pay_rule_id=pr.id),'[]'::jsonb),
        'locationIds',coalesce((select jsonb_agg(x.location_id::text order by x.location_id::text)
          from public.matrix_pay_rule_locations_v2 x where x.pay_rule_id=pr.id),'[]'::jsonb),
        'shiftTemplateIds',coalesce((select jsonb_agg(x.shift_template_id::text order by x.shift_template_id::text)
          from public.matrix_pay_rule_shifts_v2 x where x.pay_rule_id=pr.id),'[]'::jsonb)
      ) order by pr.priority,pr.code)
      from public.matrix_pay_rules_v2 pr
      left join lateral (
        with recursive scenario_chain as (
          select sc.id,sc.parent_scenario_id,0 depth
          from public.matrix_scenarios_v2 sc
          where sc.id=p_scenario_id and sc.matrix_version_id=p_matrix_version_id
          union all
          select parent.id,parent.parent_scenario_id,chain.depth+1
          from public.matrix_scenarios_v2 parent
          join scenario_chain chain on chain.parent_scenario_id=parent.id
          where parent.matrix_version_id=p_matrix_version_id and chain.depth<32
        )
        select
          (array_agg(override.enabled order by chain.depth,override.id))[1]
            enabled,
          (array_agg(override.amount_minor order by chain.depth,override.id)
            filter(where override.amount_minor is not null))[1] amount_minor,
          (array_agg(override.rate_minor_per_hour order by chain.depth,override.id)
            filter(where override.rate_minor_per_hour is not null))[1]
            rate_minor_per_hour,
          (array_agg(override.percent_basis_points order by chain.depth,override.id)
            filter(where override.percent_basis_points is not null))[1]
            percent_basis_points,
          (array_agg(override.multiplier_basis_points order by chain.depth,override.id)
            filter(where override.multiplier_basis_points is not null))[1]
            multiplier_basis_points
        from scenario_chain chain
        join public.matrix_scenario_pay_rule_overrides_v2 override
          on override.scenario_id=chain.id and override.pay_rule_id=pr.id
        where override.matrix_version_id=p_matrix_version_id
      ) ov on true
      where pr.matrix_version_id=p_matrix_version_id and pr.active
    ),'[]'::jsonb),
    'budgets',v_budgets,
    'budget',coalesce((
      select jsonb_build_object(
        'amountMinor',(b.value->>'amountMinor')::bigint,
        'hard',coalesce((b.value->>'hard')::boolean,false),
        'currency',v_currency
      )
      from jsonb_array_elements(v_budgets) b
      where nullif(b.value->>'locationId','') is null
        and nullif(b.value->>'roleId','') is null
        and nullif(b.value->>'dutyId','') is null
      limit 1
    ),jsonb_build_object(
      'amountMinor',null,'hard',false,'currency',v_currency
    ))
  ) into v_snapshot;
  if jsonb_array_length(v_snapshot->'strategies')>32 then
    raise exception 'SOLVER_CAPACITY_STRATEGY_LIMIT';
  end if;

  -- Previous selected v2 assignments and the latest legacy plan are projected
  -- onto deterministic slot IDs. They remain soft baseline hints unless they
  -- were explicitly locked. For ROLE runs, assignments owned by other roles
  -- are hard external time blocks and prevent cross-role collisions.
  with chosen_legacy_plan as (
    select p.id from public.plans p where p.month=v_month
    order by case p.status when 'PUBLISHED' then 1 when 'READY' then 2 else 3 end,
      p.version desc,p.created_at desc limit 1
  ), legacy_numbered as (
    select a.employee_id,a.locked,sh.starts_at,sh.ends_at,sh.shift_date,
      mt.id shift_template_id,mr.id role_id,
      row_number() over(
        partition by sh.shift_date,mt.id,mr.id order by a.locked desc,a.id
      ) seat_number
    from chosen_legacy_plan cp
    join public.shifts sh on sh.plan_id=cp.id
    join public.assignments a on a.shift_id=sh.id
    join public.locations old_location on old_location.id=sh.location_id
    join public.matrix_locations_v2 ml
      on ml.matrix_version_id=p_matrix_version_id and ml.code=old_location.code::text
    join public.matrix_shift_templates_v2 mt
      on mt.matrix_version_id=p_matrix_version_id and mt.location_id=ml.id
      and mt.code=sh.shift_code
    join public.matrix_roles_v2 mr
      on mr.matrix_version_id=p_matrix_version_id and mr.code=a.assigned_role::text
  ), snapshot_slots as (
    select slot.value->>'slotId' slot_id,(slot.value->>'date')::date shift_date,
      (slot.value->>'shiftTemplateId')::uuid shift_template_id,
      (slot.value->>'roleId')::uuid role_id,
      row_number() over(
        partition by (slot.value->>'date')::date,
          (slot.value->>'shiftTemplateId')::uuid,(slot.value->>'roleId')::uuid
        order by (slot.value->>'seatIndex')::integer,slot.value->>'slotId'
      ) seat_number
    from jsonb_array_elements(v_snapshot->'slots') slot
  ), legacy_projection as (
    select ss.slot_id,l.employee_id,l.locked,1 source_priority
    from legacy_numbered l join snapshot_slots ss
      on ss.shift_date=l.shift_date and ss.shift_template_id=l.shift_template_id
      and ss.role_id=l.role_id and ss.seat_number=l.seat_number
  ), selected_v2 as (
    select pa.slot_key slot_id,pa.employee_id,pa.locked,2 source_priority,
      coalesce(v.selected_at,v.created_at) selected_at
    from public.plan_assignments_v2 pa
    join public.plan_variants_v2 v on v.id=pa.variant_id and v.selected
    join public.optimization_runs_v2 r on r.id=v.run_id
    where r.month=v_month and r.matrix_version_id=p_matrix_version_id
      and r.request_engine='ORTOOLS_V2'
      and exists(select 1 from snapshot_slots ss where ss.slot_id=pa.slot_key)
  ), combined as (
    select slot_id,employee_id,locked,source_priority,null::timestamptz selected_at
    from legacy_projection
    union all
    select slot_id,employee_id,locked,source_priority,selected_at from selected_v2
  ), deduplicated as (
    select distinct on (slot_id) slot_id,employee_id,locked
    from combined order by slot_id,source_priority desc,selected_at desc nulls last
  ), scoped_baseline as (
    select d.*,exists(
      select 1 from jsonb_array_elements(v_snapshot->'employees') employee
      where employee.value->>'id'=d.employee_id::text
    ) employee_present
    from deduplicated d
  )
  select
    coalesce(jsonb_agg(jsonb_build_object('slotId',slot_id,'employeeId',employee_id)
      order by slot_id) filter(where employee_present),'[]'::jsonb),
    coalesce(jsonb_agg(jsonb_build_object('slotId',slot_id,'employeeId',employee_id)
      order by slot_id) filter(where locked),'[]'::jsonb)
  into v_baseline,v_locked from scoped_baseline;
  if exists(
    select 1 from jsonb_array_elements(v_locked) lock_item
    where not exists(
      select 1 from jsonb_array_elements(v_snapshot->'employees') employee
      where employee.value->>'id'=lock_item.value->>'employeeId'
    )
  ) then raise exception 'LOCKED_ASSIGNMENT_EMPLOYEE_OUTSIDE_SNAPSHOT'; end if;

  -- Assignments outside the generated scope stay hard. For ROLE runs that
  -- means the other roles in the same month. For every scope it also includes
  -- adjacent-month assignments, so rest and consecutive-day rules are not
  -- accidentally reset at midnight on the first/last day of the month.
  with target_role as (
    select code from public.matrix_roles_v2 where id=p_scope_role_id
  ), ranked_legacy_plans as (
    select p.id,p.month,row_number() over(
      partition by p.month
      order by case p.status when 'PUBLISHED' then 1 when 'READY' then 2 else 3 end,
        p.version desc,p.created_at desc
    ) plan_rank
    from public.plans p
    where p.month between (v_month-interval '1 month')::date
      and (v_month+interval '1 month')::date
  ), latest_selected_role_variants as (
    select ranked.variant_id
    from (
      select v.id variant_id,
        row_number() over(
          partition by r.scope_role_id
          order by coalesce(v.selected_at,v.created_at) desc,v.id desc
        ) selection_rank
      from public.plan_variants_v2 v
      join public.optimization_runs_v2 r on r.id=v.run_id
      where p_scope_type='ROLE'
        and r.month=v_month
        and r.matrix_version_id=p_matrix_version_id
        and r.scenario_id=p_scenario_id
        and r.request_engine='ORTOOLS_V2'
        and r.scope_type='ROLE'
        and r.scope_role_id is distinct from p_scope_role_id
        and v.selected
    ) ranked
    where ranked.selection_rank=1
  ), blocks as (
    select a.employee_id,sh.starts_at,sh.ends_at
    from ranked_legacy_plans cp
    join public.shifts sh on sh.plan_id=cp.id
    join public.assignments a on a.shift_id=sh.id
    left join target_role tr on true
    where cp.plan_rank=1 and (
      sh.shift_date<v_month
      or sh.shift_date>v_period_end
      or (p_scope_type='ROLE' and a.assigned_role::text<>tr.code)
    )
    union
    select pa.employee_id,ps.starts_at,ps.ends_at
    from public.plan_assignments_v2 pa
    join public.plan_shifts_v2 ps on ps.id=pa.shift_id
    join public.plan_variants_v2 v on v.id=pa.variant_id
    join public.optimization_runs_v2 r on r.id=v.run_id
    where r.month between (v_month-interval '1 month')::date
        and (v_month+interval '1 month')::date
      and (
        (
          v.status='PUBLISHED'
          and (
            ps.shift_date<v_month
            or ps.shift_date>v_period_end
          )
        )
        or (
          p_scope_type='ROLE'
          and r.month=v_month
          and v.id in (select x.variant_id from latest_selected_role_variants x)
          and pa.role_id is distinct from p_scope_role_id
        )
      )
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'employeeId',block.employee_id,'start',block.starts_at,'end',block.ends_at
  ) order by block.employee_id,block.starts_at,block.ends_at),'[]'::jsonb)
  into v_external
  from blocks block
  where exists(
    select 1 from jsonb_array_elements(v_snapshot->'employees') employee
    where employee.value->>'id'=block.employee_id::text
  );
  v_snapshot := jsonb_set(v_snapshot,'{baselineAssignments}',v_baseline,true);
  v_snapshot := jsonb_set(v_snapshot,'{lockedAssignments}',v_locked,true);
  v_snapshot := jsonb_set(v_snapshot,'{externalAssignments}',v_external,true);

  return v_snapshot;
end;
$$;

revoke all on function solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)
  from public,anon,authenticated;
grant execute on function solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)
  to service_role;

create or replace function public.optimizer_configuration_v2(p_month date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_month date:=date_trunc('month',p_month)::date;
  v_period_end date:=(date_trunc('month',p_month)+interval '1 month - 1 day')::date;
  v_engine text;
  v_enabled boolean;
  v_solver_version text;
  v_matrix public.matrix_versions%rowtype;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  select flag.engine,flag.enabled,nullif(trim(flag.config->>'solverVersion'),'')
  into v_engine,v_enabled,v_solver_version
  from public.solver_feature_flags flag
  where flag.flag_key='DEFAULT_ENGINE';
  if v_engine is null then raise exception 'SOLVER_ENGINE_CONFIGURATION_MISSING'; end if;
  if not coalesce(v_enabled,false) then raise exception 'SOLVER_DISABLED'; end if;
  if v_engine not in ('ALPHA15','SHADOW','ORTOOLS_V2') then
    raise exception 'SOLVER_ENGINE_CONFIGURATION_INVALID';
  end if;
  if v_engine='ALPHA15' then
    return jsonb_build_object('engine',v_engine,'enabled',true);
  end if;
  if length(coalesce(v_solver_version,'')) not between 1 and 200 then
    raise exception 'SOLVER_VERSION_CONFIGURATION_REQUIRED';
  end if;

  select * into v_matrix
  from public.matrix_versions matrix_version
  where matrix_version.status in ('ACTIVE','ARCHIVED')
    and matrix_version.schema_version>=2
    and matrix_version.effective_from<=v_month
    and coalesce(matrix_version.content_hash,'') ~ '^[0-9a-f]{64}$'
    and coalesce(matrix_version.workforce_hash,'') ~ '^[0-9a-f]{64}$'
  order by matrix_version.effective_from desc,matrix_version.version desc
  limit 1;
  if v_matrix.id is null then raise exception 'MATRIX_V2_FOR_MONTH_NOT_FOUND'; end if;

  return jsonb_build_object(
    'engine',v_engine,'enabled',true,'solverVersion',v_solver_version,
    'matrixVersion',jsonb_build_object(
      'id',v_matrix.id,'schemaVersion',v_matrix.schema_version,
      'effectiveFrom',v_matrix.effective_from,'settings',v_matrix.settings,
      'contentHash',v_matrix.content_hash,'workforceHash',v_matrix.workforce_hash
    ),
    'scenarios',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',scenario.id,'code',scenario.code,'name',scenario.name,
        'description',scenario.description,'isDefault',scenario.is_default,
        'sortOrder',scenario.sort_order,'parentScenarioId',scenario.parent_scenario_id,
        'available',(
          (scenario.valid_from is null or scenario.valid_from<=v_period_end)
          and (scenario.valid_to is null or scenario.valid_to>=v_month)
        )
      ) order by scenario.sort_order,scenario.name)
      from public.matrix_scenarios_v2 scenario
      where scenario.matrix_version_id=v_matrix.id and scenario.active
    ),'[]'::jsonb),
    'roles',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',role_row.id,'code',role_row.code,'name',role_row.name,
        'sortOrder',role_row.sort_order
      ) order by role_row.sort_order,role_row.name)
      from public.matrix_roles_v2 role_row
      where role_row.matrix_version_id=v_matrix.id and role_row.active
    ),'[]'::jsonb),
    'locations',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',location_row.id,'code',location_row.code,'name',location_row.name,
        'sortOrder',location_row.sort_order,'timezone',location_row.timezone
      ) order by location_row.sort_order,location_row.name)
      from public.matrix_locations_v2 location_row
      where location_row.matrix_version_id=v_matrix.id and location_row.active
    ),'[]'::jsonb),
    'strategies',coalesce((
      select jsonb_agg(jsonb_build_object('id',strategy.id) order by strategy.id)
      from public.matrix_strategies_v2 strategy
      where strategy.matrix_version_id=v_matrix.id and strategy.active
    ),'[]'::jsonb),
    'scenarioStrategies',coalesce((
      select jsonb_agg(jsonb_build_object(
        'scenarioId',link.scenario_id,'strategyId',link.strategy_id,
        'active',link.active
      ) order by link.scenario_id,link.sort_order,link.id)
      from public.matrix_scenario_strategies_v2 link
      where link.matrix_version_id=v_matrix.id
    ),'[]'::jsonb)
  );
end;
$$;

revoke all on function public.optimizer_configuration_v2(date)
  from public,anon;
grant execute on function public.optimizer_configuration_v2(date)
  to authenticated;
comment on function public.optimizer_configuration_v2(date) is
  'Safe month-as-of solver configuration; no payroll or private workforce data.';

create or replace function solver_private.can_access_run_v2(p_run_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists(
    select 1 from public.optimization_runs_v2 r
    where r.id=p_run_id and (
      r.requested_by=(select auth.uid())
      or public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    )
  );
$$;

create or replace function solver_private.run_status_payload_v2(p_run_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'run',jsonb_build_object(
      'id',r.id,'status',r.status,'phase',r.phase,'progress',r.progress,
      'month',r.month,'scopeType',r.scope_type,'scopeRoleId',r.scope_role_id,
      'requestEngine',r.request_engine,'solverVersion',r.solver_version,
      'failureMessage',r.failure_message,'createdAt',r.created_at,'updatedAt',r.updated_at
    ),
    'strategies',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',s.id,'strategyId',s.strategy_id,'name',ms.name,
        'status',s.status,'phase',s.phase,'progress',s.progress
      ) order by s.ordinal)
      from public.optimization_run_strategies_v2 s
      join public.matrix_strategies_v2 ms on ms.id=s.strategy_id
      where s.run_id=r.id
    ),'[]'::jsonb)
  )
  from public.optimization_runs_v2 r where r.id=p_run_id;
$$;

revoke all on function solver_private.can_access_run_v2(uuid) from public,anon,authenticated;
revoke all on function solver_private.run_status_payload_v2(uuid) from public,anon,authenticated;
grant execute on function solver_private.can_access_run_v2(uuid) to service_role;
grant execute on function solver_private.run_status_payload_v2(uuid) to service_role;

create or replace function public.optimizer_request_v2(
  p_month date,
  p_scenario_id uuid,
  p_scope_type text,
  p_scope_role_id uuid,
  p_name text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_month date := date_trunc('month',p_month)::date;
  v_period_end date := (date_trunc('month',p_month)+interval '1 month - 1 day')::date;
  v_matrix_id uuid;
  v_scenario public.matrix_scenarios_v2%rowtype;
  v_scope_logical_id uuid;
  v_run_id uuid;
  v_existing public.optimization_runs_v2%rowtype;
  v_snapshot jsonb;
  v_hash text;
  v_message_id bigint;
  v_engine text;
  v_solver_version text;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  select flag.engine,nullif(trim(flag.config->>'solverVersion'),'')
  into v_engine,v_solver_version
  from public.solver_feature_flags flag
  where flag.flag_key='DEFAULT_ENGINE' and flag.enabled;
  if v_engine is null then raise exception 'SOLVER_ENGINE_CONFIGURATION_MISSING'; end if;
  if v_engine not in ('ALPHA15','SHADOW','ORTOOLS_V2') then
    raise exception 'SOLVER_ENGINE_CONFIGURATION_INVALID';
  end if;
  if v_engine not in ('SHADOW','ORTOOLS_V2') then
    raise exception 'ORTOOLS_REQUEST_DISABLED';
  end if;
  if length(coalesce(v_solver_version,'')) not between 1 and 200 then
    raise exception 'SOLVER_VERSION_CONFIGURATION_REQUIRED';
  end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  p_scope_type := upper(coalesce(p_scope_type,'COMPANY'));
  if p_scope_type not in ('COMPANY','ROLE') then raise exception 'INVALID_SCOPE'; end if;
  if (p_scope_type='ROLE')<>(p_scope_role_id is not null) then
    raise exception 'INVALID_SCOPE_ROLE';
  end if;
  if length(coalesce(p_idempotency_key,'')) not between 8 and 200 then
    raise exception 'INVALID_IDEMPOTENCY_KEY';
  end if;
  if length(trim(coalesce(p_name,''))) not between 1 and 200 then
    raise exception 'INVALID_PLAN_NAME';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_user::text||':'||p_idempotency_key,0));
  select * into v_existing from public.optimization_runs_v2 r
  where r.requested_by=v_user and r.idempotency_key=p_idempotency_key;
  if v_existing.id is not null then
    if v_existing.month<>v_month
      or v_existing.scenario_id<>p_scenario_id
      or v_existing.scope_type<>p_scope_type
      or v_existing.scope_role_id is distinct from p_scope_role_id
      or v_existing.request_engine<>v_engine
      or v_existing.solver_version<>v_solver_version
      or v_existing.name<>trim(p_name) then
      raise exception 'IDEMPOTENCY_KEY_REUSED';
    end if;
    return solver_private.run_status_payload_v2(v_existing.id)
      ||jsonb_build_object('reused',true);
  end if;

  -- Serialize the immutable snapshot boundary with every planning-data write.
  -- The lock is released automatically when this request transaction commits.
  perform solver_private.lock_planning_revision_v2();

  -- A monthly run always uses the Matrix that was effective at the first day
  -- of that month. This keeps historical reruns reproducible and prevents a
  -- mid-month publication from rewriting rules for days already elapsed.
  select mv.id into v_matrix_id
  from public.matrix_versions mv
  where mv.status in ('ACTIVE','ARCHIVED') and mv.schema_version>=2
    and mv.effective_from<=v_month
    and coalesce(mv.content_hash,'') ~ '^[0-9a-f]{64}$'
    and coalesce(mv.workforce_hash,'') ~ '^[0-9a-f]{64}$'
  order by mv.effective_from desc,mv.version desc limit 1;
  if v_matrix_id is null then raise exception 'MATRIX_V2_FOR_MONTH_NOT_FOUND'; end if;

  select * into v_scenario from public.matrix_scenarios_v2 s
  where s.id=p_scenario_id and s.matrix_version_id=v_matrix_id and s.active;
  if v_scenario.id is null then raise exception 'SCENARIO_NOT_FOUND'; end if;
  if v_scenario.valid_to is not null and v_scenario.valid_to<v_month then
    raise exception 'SCENARIO_OUTSIDE_PERIOD';
  end if;
  if v_scenario.valid_from is not null and v_scenario.valid_from>v_period_end then
    raise exception 'SCENARIO_OUTSIDE_PERIOD';
  end if;
  if p_scope_type='COMPANY' and not (
    public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  ) then raise exception 'COMPANY_SCOPE_FORBIDDEN'; end if;
  if p_scope_type='ROLE' then
    select r.logical_id into v_scope_logical_id
    from public.matrix_roles_v2 r
    where r.id=p_scope_role_id and r.matrix_version_id=v_matrix_id and r.active;
    if v_scope_logical_id is null then raise exception 'SCOPE_ROLE_NOT_FOUND'; end if;
    if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN'))
      and not exists(
        select 1 from public.matrix_scope_grants_v2 g
        where g.auth_user_id=v_user and g.active and g.app_role='ROLE_MANAGER'
          and (g.role_logical_id is null or g.role_logical_id=v_scope_logical_id)
      ) then raise exception 'ROLE_SCOPE_FORBIDDEN'; end if;
  end if;

  v_run_id := gen_random_uuid();
  v_snapshot := solver_private.build_snapshot_payload_v2(
    v_run_id,v_month,v_matrix_id,v_scenario.id,p_scope_type,p_scope_role_id
  );
  if jsonb_array_length(v_snapshot->'strategies')=0 then
    raise exception 'SNAPSHOT_HAS_NO_STRATEGIES';
  end if;
  v_hash := encode(extensions.digest(convert_to(
    solver_private.canonical_json_v2(v_snapshot),'UTF8'
  ),'sha256'),'hex');

  insert into public.optimization_runs_v2(
    id,idempotency_key,month,matrix_version_id,scenario_id,scope_type,
    scope_role_id,name,requested_by,snapshot_hash,request_engine,solver_version
  ) values(
    v_run_id,p_idempotency_key,v_month,v_matrix_id,v_scenario.id,p_scope_type,
    p_scope_role_id,trim(p_name),v_user,v_hash,v_engine,v_solver_version
  );

  insert into public.optimization_run_strategies_v2(
    run_id,strategy_id,ordinal,status,phase,progress
  )
  select v_run_id,(strategy.value->>'id')::uuid,strategy.ordinality::integer,
    'QUEUED','QUEUED',0
  from jsonb_array_elements(v_snapshot->'strategies')
    with ordinality strategy(value,ordinality)
  order by strategy.ordinality;

  insert into solver_private.optimization_snapshots_v2(
    run_id,schema_version,snapshot_hash,snapshot
  ) values(v_run_id,2,v_hash,v_snapshot);

  select pgmq.send('schedule_optimizer_v2',jsonb_build_object(
    'schemaVersion',2,'runId',v_run_id,'snapshotHash',v_hash
  )) into v_message_id;
  update public.optimization_runs_v2 set queue_message_id=v_message_id where id=v_run_id;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_user,'optimization_run_v2',v_run_id::text,'REQUEST',jsonb_build_object(
    'month',v_month,'matrixVersionId',v_matrix_id,'scenarioId',v_scenario.id,
    'scopeType',p_scope_type,'scopeRoleId',p_scope_role_id,'snapshotHash',v_hash,
    'requestEngine',v_engine,'solverVersion',v_solver_version
  ));

  return jsonb_build_object(
    'run',jsonb_build_object(
      'id',v_run_id,'status','QUEUED','phase','QUEUED','progress',0,
      'month',v_month,'scopeType',p_scope_type,'scopeRoleId',p_scope_role_id,
      'requestEngine',v_engine,'solverVersion',v_solver_version,
      'scenario',jsonb_build_object('id',v_scenario.id,'name',v_scenario.name),
      'createdAt',now()
    ),'reused',false
  );
end;
$$;

create or replace function public.optimizer_status_v2(p_run_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not solver_private.can_access_run_v2(p_run_id) then raise exception 'RUN_NOT_FOUND'; end if;
  return solver_private.run_status_payload_v2(p_run_id);
end;
$$;

create or replace function public.optimizer_request_cancel_v2(p_run_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_run public.optimization_runs_v2%rowtype;
begin
  if not solver_private.can_access_run_v2(p_run_id) then raise exception 'RUN_NOT_FOUND'; end if;
  select * into v_run from public.optimization_runs_v2 where id=p_run_id for update;
  if v_run.status in ('READY','FAILED','CANCELLED','STALE_INPUT') then
    raise exception 'RUN_NOT_CANCELLABLE';
  end if;
  update public.optimization_runs_v2 set
    status=case when status='QUEUED' then 'CANCELLED' else 'CANCEL_REQUESTED' end,
    phase=case when status='QUEUED' then 'CANCELLED' else 'CANCEL_REQUESTED' end,
    cancel_requested_at=now(),finished_at=case when status='QUEUED' then now() else finished_at end,
    updated_at=now()
  where id=p_run_id;
  update public.optimization_run_strategies_v2 set
    status=case when status='QUEUED' then 'CANCELLED' else status end,
    phase=case when status='QUEUED' then 'CANCELLED' else phase end,
    finished_at=case when status='QUEUED' then now() else finished_at end,
    updated_at=now()
  where run_id=p_run_id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action)
  values(auth.uid(),'optimization_run_v2',p_run_id::text,'CANCEL_REQUEST');
  return solver_private.run_status_payload_v2(p_run_id);
end;
$$;

create or replace function public.optimizer_variants_v2(p_run_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_can_view_finance boolean;
begin
  if not solver_private.can_access_run_v2(p_run_id) then raise exception 'RUN_NOT_FOUND'; end if;
  v_can_view_finance := public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE');
  return jsonb_build_object(
    'runId',p_run_id,
    'variants',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',v.id,'name',v.name,
        'strategy',jsonb_build_object('id',s.id,'name',s.name,'description',s.description),
        'status',v.status,'hardViolations',v.hard_violations,
        'assignmentCount',v.assignment_count,'unfilledCount',v.unfilled_count,
        'totalCostMinor',case when v_can_view_finance then f.total_cost_minor else null end,
        'budgetMinor',case when v_can_view_finance then f.budget_minor else null end,
        'currency',case when v_can_view_finance then f.currency else null end,
        'solverStatus',v.solver_status,'recommended',v.recommended,'selected',v.selected,
        'equivalentToVariantId',v.equivalent_to_variant_id,'metrics',v.metrics
      ) order by rs.ordinal)
      from public.plan_variants_v2 v
      join public.optimization_run_strategies_v2 rs on rs.id=v.run_strategy_id
      join public.matrix_strategies_v2 s on s.id=v.strategy_id
      left join solver_private.plan_variant_finance_v2 f on f.variant_id=v.id
      where v.run_id=p_run_id
    ),'[]'::jsonb)
  );
end;
$$;

create or replace function public.optimizer_select_variant_v2(
  p_run_id uuid,p_variant_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_variant public.plan_variants_v2%rowtype;
begin
  if not solver_private.can_access_run_v2(p_run_id) then raise exception 'RUN_NOT_FOUND'; end if;
  perform pg_advisory_xact_lock(hashtextextended('select-v2:'||p_run_id::text,0));
  if not exists(select 1 from public.optimization_runs_v2 r where r.id=p_run_id and r.status='READY') then
    raise exception 'RUN_NOT_READY';
  end if;
  select * into v_variant from public.plan_variants_v2 v
  where v.id=p_variant_id and v.run_id=p_run_id and v.hard_violations=0 for update;
  if v_variant.id is null then raise exception 'VARIANT_NOT_SELECTABLE'; end if;
  update public.plan_variants_v2 set selected=false,
    status=case when status='SELECTED' then 'READY' else status end,
    selected_at=null,selected_by=null
  where run_id=p_run_id and selected;
  update public.plan_variants_v2 set selected=true,status='SELECTED',
    selected_at=now(),selected_by=auth.uid() where id=p_variant_id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'optimization_run_v2',p_run_id::text,'SELECT_VARIANT',
    jsonb_build_object('variantId',p_variant_id));
  return jsonb_build_object(
    'runId',p_run_id,'variantId',p_variant_id,'selected',true,'planId',null
  );
end;
$$;

create or replace function solver_private.lease_is_live_v2(
  p_run_id uuid,p_attempt_id uuid,p_lease_token uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists(
    select 1
    from public.optimization_runs_v2 r
    join solver_private.optimization_attempts_v2 a
      on a.run_id=r.id and a.id=p_attempt_id
    where r.id=p_run_id and r.lease_token=p_lease_token
      and r.lease_expires_at>now() and a.lease_token=p_lease_token
      and a.status='RUNNING' and r.status in ('RUNNING','VALIDATING','CANCEL_REQUESTED')
  );
$$;

create or replace function public.solver_load_snapshot_v2(
  p_run_id uuid,p_attempt_id uuid,p_lease_token uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_snapshot solver_private.optimization_snapshots_v2%rowtype;
begin
  if not solver_private.lease_is_live_v2(p_run_id,p_attempt_id,p_lease_token) then
    raise exception 'LEASE_LOST';
  end if;
  select * into v_snapshot from solver_private.optimization_snapshots_v2 where run_id=p_run_id;
  if v_snapshot.run_id is null then raise exception 'SNAPSHOT_NOT_FOUND'; end if;
  return jsonb_build_object(
    'runId',p_run_id,'snapshotHash',v_snapshot.snapshot_hash,'snapshot',v_snapshot.snapshot
  );
end;
$$;

create or replace function public.solver_heartbeat_v2(
  p_run_id uuid,p_attempt_id uuid,p_lease_token uuid,p_progress jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_progress integer := greatest(1,least(99,coalesce((p_progress->>'progress')::integer,1)));
  v_phase text := left(coalesce(nullif(p_progress->>'phase',''),'SOLVING'),80);
  v_strategy_id uuid := nullif(p_progress->>'strategyId','')::uuid;
  v_cancel boolean;
begin
  if not solver_private.lease_is_live_v2(p_run_id,p_attempt_id,p_lease_token) then
    raise exception 'LEASE_LOST';
  end if;
  update public.optimization_runs_v2 set progress=greatest(progress,v_progress),phase=v_phase,
    heartbeat_at=now(),lease_expires_at=now()+interval '120 seconds',updated_at=now()
  where id=p_run_id and lease_token=p_lease_token;
  update solver_private.optimization_attempts_v2 set heartbeat_at=now()
  where id=p_attempt_id and lease_token=p_lease_token;
  if v_strategy_id is not null then
    update public.optimization_run_strategies_v2 set
      status='RUNNING',phase=v_phase,
      progress=greatest(progress,least(99,coalesce((p_progress->>'strategyProgress')::integer,v_progress))),
      started_at=coalesce(started_at,now()),updated_at=now()
    where run_id=p_run_id and strategy_id=v_strategy_id;
  end if;
  select status='CANCEL_REQUESTED' into v_cancel
  from public.optimization_runs_v2 where id=p_run_id;
  return jsonb_build_object('ok',true,'cancelRequested',coalesce(v_cancel,false),
    'leaseExpiresAt',now()+interval '120 seconds');
end;
$$;

create or replace function solver_private.slot_timezone_v2(
  p_snapshot jsonb,p_slot jsonb
)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select l.value->>'timezone'
      from jsonb_array_elements(coalesce(p_snapshot->'locations','[]'::jsonb)) l
      where l.value->>'id'=p_slot->>'locationId' limit 1),
    nullif(p_snapshot->'settings'->>'timezone','')
  );
$$;

create or replace function solver_private.employee_scope_eligible_v2(
  p_employee jsonb,p_slot jsonb
)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select
    case when p_employee ? 'roleGrants' then exists(
      select 1
      from jsonb_array_elements(coalesce(p_employee->'roleGrants','[]'::jsonb)) g
      where g.value->>'roleId'=p_slot->>'roleId'
        and (nullif(g.value->>'validFrom','') is null
          or (p_slot->>'date')::date>=(g.value->>'validFrom')::date)
        and (nullif(g.value->>'validTo','') is null
          or (p_slot->>'date')::date<=(g.value->>'validTo')::date)
    ) else coalesce(p_employee->'roleIds','[]'::jsonb) ? (p_slot->>'roleId') end
    and
    case when p_employee ? 'locationGrants' then exists(
      select 1
      from jsonb_array_elements(coalesce(p_employee->'locationGrants','[]'::jsonb)) g
      where g.value->>'locationId'=p_slot->>'locationId'
        and coalesce((g.value->>'standardAllowed')::boolean,false)
        and (nullif(g.value->>'validFrom','') is null
          or (p_slot->>'date')::date>=(g.value->>'validFrom')::date)
        and (nullif(g.value->>'validTo','') is null
          or (p_slot->>'date')::date<=(g.value->>'validTo')::date)
    ) else coalesce(p_employee->'locationIds','[]'::jsonb) ? (p_slot->>'locationId') end
    and not exists(
      select 1
      from jsonb_array_elements_text(coalesce(p_slot->'dutyIds','[]'::jsonb)) duty
      where not case when p_employee ? 'dutyGrants' then exists(
        select 1
        from jsonb_array_elements(coalesce(p_employee->'dutyGrants','[]'::jsonb)) g
        where g.value->>'dutyId'=duty.value
          and (nullif(g.value->>'roleId','') is null
            or g.value->>'roleId'=p_slot->>'roleId')
          and (nullif(g.value->>'locationId','') is null
            or g.value->>'locationId'=p_slot->>'locationId')
          and (nullif(g.value->>'validFrom','') is null
            or (p_slot->>'date')::date>=(g.value->>'validFrom')::date)
          and (nullif(g.value->>'validTo','') is null
            or (p_slot->>'date')::date<=(g.value->>'validTo')::date)
      ) else coalesce(p_employee->'dutyIds','[]'::jsonb) ? duty.value end
    );
$$;

create or replace function solver_private.employee_for_slot_v2(
  p_employee jsonb,p_slot jsonb
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case
    when p_employee ? 'payRatePeriods' and rate.value is not null
    then p_employee||jsonb_build_object(
      'baseHourlyRateMinor',rate.value->>'baseRateMinor',
      'contractCode',rate.value->>'contractCode'
    )
    else p_employee
  end
  from (select 1) anchor
  left join lateral (
    select period.value
    from jsonb_array_elements(coalesce(p_employee->'payRatePeriods','[]'::jsonb)) period
    where (p_slot->>'date')::date>=(period.value->>'validFrom')::date
      and (nullif(period.value->>'validTo','') is null
        or (p_slot->>'date')::date<=(period.value->>'validTo')::date)
    order by (period.value->>'validFrom')::date desc
    limit 1
  ) rate on true;
$$;

create or replace function solver_private.pay_condition_matches_v2(
  p_condition jsonb,p_snapshot jsonb,p_employee jsonb,p_slot jsonb
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_field text := lower(coalesce(p_condition->>'field',''));
  v_operator text := upper(coalesce(p_condition->>'operator',''));
  v_expected jsonb := p_condition->'value';
  v_actual jsonb;
  v_timezone text := solver_private.slot_timezone_v2(p_snapshot,p_slot);
  v_rule_start integer;
  v_rule_end integer;
  v_slot_start integer;
  v_slot_end integer;
begin
  v_actual := case v_field
    when 'role_id' then to_jsonb(p_slot->>'roleId')
    when 'duty_ids' then coalesce(p_slot->'dutyIds','[]'::jsonb)
    when 'location_id' then to_jsonb(p_slot->>'locationId')
    when 'shift_template_id' then to_jsonb(p_slot->>'shiftTemplateId')
    when 'weekday' then to_jsonb(extract(isodow from (p_slot->>'date')::date)::integer)
    when 'scenario_id' then to_jsonb(p_snapshot->>'scenarioId')
    when 'employee_id' then to_jsonb(p_employee->>'id')
    when 'contract_code' then to_jsonb(p_employee->>'contractCode')
    when 'duration_minutes' then to_jsonb((p_slot->>'durationMinutes')::integer)
    when 'local_time' then to_jsonb(p_slot->>'start')
    else null
  end;
  if v_field not in (
    'role_id','duty_ids','location_id','shift_template_id','weekday',
    'scenario_id','employee_id','contract_code','duration_minutes','local_time'
  ) then raise exception 'UNSUPPORTED_PAY_CONDITION_FIELD:%',v_field; end if;

  if v_operator='OVERLAPS_TIME' then
    if v_field<>'local_time' or jsonb_typeof(v_expected)<>'object'
      or nullif(v_expected->>'start','') is null
      or nullif(v_expected->>'end','') is null then
      raise exception 'PAY_TIME_CONDITION_INVALID';
    end if;
    v_rule_start := extract(hour from (v_expected->>'start')::time)::integer*60
      +extract(minute from (v_expected->>'start')::time)::integer;
    v_rule_end := extract(hour from (v_expected->>'end')::time)::integer*60
      +extract(minute from (v_expected->>'end')::time)::integer;
    if v_rule_end<=v_rule_start then v_rule_end:=v_rule_end+1440; end if;
    v_slot_start := extract(hour from ((p_slot->>'start')::timestamptz at time zone v_timezone))::integer*60
      +extract(minute from ((p_slot->>'start')::timestamptz at time zone v_timezone))::integer;
    v_slot_end := extract(hour from ((p_slot->>'end')::timestamptz at time zone v_timezone))::integer*60
      +extract(minute from ((p_slot->>'end')::timestamptz at time zone v_timezone))::integer;
    if (((p_slot->>'end')::timestamptz at time zone v_timezone)::date
        >((p_slot->>'start')::timestamptz at time zone v_timezone)::date)
      or v_slot_end<=v_slot_start then v_slot_end:=v_slot_end+1440; end if;
    return (v_slot_start<v_rule_end-1440 and v_rule_start-1440<v_slot_end)
      or (v_slot_start<v_rule_end and v_rule_start<v_slot_end)
      or (v_slot_start<v_rule_end+1440 and v_rule_start+1440<v_slot_end);
  elsif v_operator='EQ' then
    return v_actual=v_expected;
  elsif v_operator='NE' then
    return v_actual<>v_expected;
  elsif v_operator in ('IN','NOT_IN') then
    if jsonb_typeof(v_expected)<>'array' then raise exception 'PAY_CONDITION_ARRAY_REQUIRED'; end if;
    return case when v_operator='IN' then exists(
      select 1 from jsonb_array_elements(v_expected) x where x.value=v_actual
    ) else not exists(
      select 1 from jsonb_array_elements(v_expected) x where x.value=v_actual
    ) end;
  elsif v_operator='CONTAINS' then
    if jsonb_typeof(v_actual)<>'array' then raise exception 'PAY_CONDITION_FACT_ARRAY_REQUIRED'; end if;
    return exists(select 1 from jsonb_array_elements(v_actual) x where x.value=v_expected);
  elsif v_operator in ('CONTAINS_ANY','CONTAINS_ALL') then
    if jsonb_typeof(v_actual)<>'array' or jsonb_typeof(v_expected)<>'array' then
      raise exception 'PAY_CONDITION_ARRAY_REQUIRED';
    end if;
    return case when v_operator='CONTAINS_ANY' then exists(
      select 1 from jsonb_array_elements(v_expected) e
      join jsonb_array_elements(v_actual) a on a.value=e.value
    ) else not exists(
      select 1 from jsonb_array_elements(v_expected) e
      where not exists(select 1 from jsonb_array_elements(v_actual) a where a.value=e.value)
    ) end;
  elsif v_operator='GTE' then
    return (v_actual#>>'{}')::numeric >= (v_expected#>>'{}')::numeric;
  elsif v_operator='LTE' then
    return (v_actual#>>'{}')::numeric <= (v_expected#>>'{}')::numeric;
  end if;
  raise exception 'UNSUPPORTED_PAY_CONDITION_OPERATOR:%',v_operator;
end;
$$;

create or replace function solver_private.pay_rule_matches_v2(
  p_snapshot jsonb,p_rule jsonb,p_employee jsonb,p_slot jsonb
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_condition jsonb;
begin
  if not coalesce((p_rule->>'active')::boolean,true) then return false; end if;
  if nullif(p_rule->>'effectiveFrom','') is not null
    and (p_slot->>'date')::date<(p_rule->>'effectiveFrom')::date then return false; end if;
  if nullif(p_rule->>'effectiveTo','') is not null
    and (p_slot->>'date')::date>(p_rule->>'effectiveTo')::date then return false; end if;
  for v_condition in select value from jsonb_array_elements(coalesce(p_rule->'conditions','[]'::jsonb))
  loop
    if not solver_private.pay_condition_matches_v2(v_condition,p_snapshot,p_employee,p_slot)
      then return false; end if;
  end loop;
  if jsonb_array_length(coalesce(p_rule->'roleIds','[]'::jsonb))>0
    and not (p_rule->'roleIds' ? (p_slot->>'roleId')) then return false; end if;
  if jsonb_array_length(coalesce(p_rule->'dutyIds','[]'::jsonb))>0
    and not exists(
      select 1 from jsonb_array_elements_text(p_rule->'dutyIds') d
      where coalesce(p_slot->'dutyIds','[]'::jsonb) ? d
    ) then return false; end if;
  if jsonb_array_length(coalesce(p_rule->'locationIds','[]'::jsonb))>0
    and not (p_rule->'locationIds' ? (p_slot->>'locationId')) then return false; end if;
  if jsonb_array_length(coalesce(p_rule->'shiftTemplateIds','[]'::jsonb))>0
    and not (p_rule->'shiftTemplateIds' ? (p_slot->>'shiftTemplateId')) then return false; end if;
  if jsonb_array_length(coalesce(p_rule->'dayMask','[]'::jsonb))>0
    and not exists(
      select 1 from jsonb_array_elements(p_rule->'dayMask') d
      where (d.value#>>'{}')::integer=extract(isodow from (p_slot->>'date')::date)::integer
    ) then return false; end if;
  if (nullif(p_rule->>'localStart','') is null)<>(nullif(p_rule->>'localEnd','') is null)
    then raise exception 'PAY_RULE_LOCAL_TIME_INVALID'; end if;
  if nullif(p_rule->>'localStart','') is not null and not solver_private.pay_condition_matches_v2(
    jsonb_build_object('field','local_time','operator','OVERLAPS_TIME','value',
      jsonb_build_object('start',p_rule->>'localStart','end',p_rule->>'localEnd')),
    p_snapshot,p_employee,p_slot
  ) then return false; end if;
  return true;
end;
$$;

create or replace function solver_private.pay_rule_billable_minutes_v2(
  p_snapshot jsonb,p_rule jsonb,p_slot jsonb
)
returns bigint
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_condition jsonb;
  v_window jsonb;
  v_window_count integer:=0;
  v_start time;
  v_end time;
  v_timezone text:=solver_private.slot_timezone_v2(p_snapshot,p_slot);
  v_slot_start timestamptz:=(p_slot->>'start')::timestamptz;
  v_slot_end timestamptz:=(p_slot->>'end')::timestamptz;
  v_minutes bigint;
begin
  for v_condition in
    select value from jsonb_array_elements(coalesce(p_rule->'conditions','[]'::jsonb))
  loop
    if lower(coalesce(v_condition->>'field',''))='local_time'
      and upper(coalesce(v_condition->>'operator',''))='OVERLAPS_TIME' then
      v_window_count:=v_window_count+1;
      v_window:=v_condition->'value';
    end if;
  end loop;
  if nullif(p_rule->>'localStart','') is not null then
    v_window_count:=v_window_count+1;
    v_window:=jsonb_build_object(
      'start',p_rule->>'localStart','end',p_rule->>'localEnd'
    );
  end if;
  if v_window_count=0 then return (p_slot->>'durationMinutes')::bigint; end if;
  if v_window_count<>1 or jsonb_typeof(v_window)<>'object'
    or nullif(v_window->>'start','') is null
    or nullif(v_window->>'end','') is null then
    raise exception 'PAY_RULE_TIME_WINDOW_AMBIGUOUS';
  end if;
  v_start:=(v_window->>'start')::time;
  v_end:=(v_window->>'end')::time;

  select coalesce(sum(floor(extract(epoch from
    least(v_slot_end,window_end)-greatest(v_slot_start,window_start)
  )/60)) filter(where window_end>v_slot_start and window_start<v_slot_end),0)::bigint
  into v_minutes
  from generate_series(
    (v_slot_start at time zone v_timezone)::date-1,
    (v_slot_end at time zone v_timezone)::date+1,
    interval '1 day'
  ) day_anchor
  cross join lateral (
    select
      ((day_anchor::date+v_start) at time zone v_timezone) window_start,
      ((day_anchor::date+case when v_end<=v_start then 1 else 0 end+v_end)
        at time zone v_timezone) window_end
  ) window_bounds;
  return greatest(v_minutes,0);
end;
$$;

revoke all on function solver_private.pay_rule_billable_minutes_v2(jsonb,jsonb,jsonb)
  from public,anon,authenticated;
grant execute on function solver_private.pay_rule_billable_minutes_v2(jsonb,jsonb,jsonb)
  to service_role;

create or replace function solver_private.expected_pay_components_v2(
  p_snapshot jsonb,p_variant jsonb
)
returns table(
  slot_id text,employee_id text,rule_id text,calculation_type text,cost_units bigint
)
language sql
stable
security definer
set search_path = ''
as $$
with submitted as (
  select a.value->>'slotId' slot_id,a.value->>'employeeId' employee_id
  from jsonb_array_elements(p_variant->'assignments') a
), pairs as (
  select a.slot_id,a.employee_id,s.value slot,
    solver_private.employee_for_slot_v2(e.value,s.value) employee,
    (s.value->>'durationMinutes')::bigint duration_minutes,
    (solver_private.employee_for_slot_v2(e.value,s.value)->>'baseHourlyRateMinor')::bigint
      base_rate_minor,
    (solver_private.employee_for_slot_v2(e.value,s.value)->>'baseHourlyRateMinor')::bigint
      *(s.value->>'durationMinutes')::bigint base_units
  from submitted a
  join jsonb_array_elements(p_snapshot->'slots') s on s.value->>'slotId'=a.slot_id
  join jsonb_array_elements(p_snapshot->'employees') e on e.value->>'id'=a.employee_id
), static_matched as (
  select p.*,r.value rule,billable.minutes billable_minutes,
    upper(r.value->>'calculationType') calculation,
    coalesce(nullif(r.value->>'stackingGroup',''),r.value->>'id') stacking_group,
    upper(coalesce(nullif(r.value->>'stackingMode',''),'STACK')) stacking_mode,
    coalesce((r.value->>'priority')::integer,0) priority,
    case upper(r.value->>'calculationType')
      when 'FIXED_PER_SHIFT' then (r.value->'values'->>'amountMinor')::bigint*60
      when 'PER_HOUR' then (r.value->'values'->>'rateMinorPerHour')::bigint*billable.minutes
      when 'PERCENT_BASE' then round(
        p.base_rate_minor*billable.minutes
          *(r.value->'values'->>'percentBasisPoints')::numeric/10000
      )::bigint
      when 'MULTIPLIER' then round(
        p.base_rate_minor*billable.minutes
          *((r.value->'values'->>'multiplierBasisPoints')::numeric-10000)/10000
      )::bigint
      when 'SHIFT_DURATION_THRESHOLD_PER_HOUR' then
        greatest(billable.minutes-(r.value->'values'->>'thresholdMinutes')::bigint,0)
          *(r.value->'values'->>'rateMinorPerHour')::bigint
    end calculated_units
  from pairs p cross join jsonb_array_elements(coalesce(p_snapshot->'payRules','[]'::jsonb)) r
  cross join lateral (
    select solver_private.pay_rule_billable_minutes_v2(
      p_snapshot,r.value,p.slot
    ) minutes
  ) billable
  where upper(r.value->>'calculationType') in (
    'FIXED_PER_SHIFT','PER_HOUR','PERCENT_BASE','MULTIPLIER',
    'SHIFT_DURATION_THRESHOLD_PER_HOUR'
  ) and solver_private.pay_rule_matches_v2(p_snapshot,r.value,p.employee,p.slot)
), static_ranked as (
  select m.*,
    row_number() over(
      partition by slot_id,stacking_group order by priority,(rule->>'id')
    ) first_rank,
    row_number() over(
      partition by slot_id,stacking_group
      order by calculated_units desc,priority,(rule->>'id') desc
    ) max_rank
  from static_matched m
), dynamic_matched as (
  select p.*,r.value rule,
    (r.value->'values'->>'thresholdMinutes')::bigint threshold_minutes,
    (r.value->'values'->>'rateMinorPerHour')::bigint rate_minor_per_hour
  from pairs p cross join jsonb_array_elements(coalesce(p_snapshot->'payRules','[]'::jsonb)) r
  where upper(r.value->>'calculationType')='MONTHLY_THRESHOLD_PER_HOUR'
    and solver_private.pay_rule_matches_v2(p_snapshot,r.value,p.employee,p.slot)
), dynamic_ordered as (
  select d.*,coalesce(sum(duration_minutes) over(
    partition by employee_id,(rule->>'id')
    order by (slot->>'start')::timestamptz,slot_id
    rows between unbounded preceding and 1 preceding
  ),0)::bigint prior_minutes
  from dynamic_matched d
), expected as (
  select p.slot_id,p.employee_id,'BASE'::text rule_id,
    'BASE_HOURLY'::text calculation_type,p.base_units cost_units
  from pairs p
  union all
  select s.slot_id,s.employee_id,s.rule->>'id',s.calculation,s.calculated_units
  from static_ranked s
  where s.stacking_mode='STACK'
    or (s.stacking_mode='FIRST' and s.first_rank=1)
    or (s.stacking_mode='MAX' and s.max_rank=1)
  union all
  select d.slot_id,d.employee_id,d.rule->>'id','MONTHLY_THRESHOLD_PER_HOUR',
    (greatest(d.prior_minutes+d.duration_minutes-d.threshold_minutes,0)
      -greatest(d.prior_minutes-d.threshold_minutes,0))*d.rate_minor_per_hour
  from dynamic_ordered d
  where greatest(d.prior_minutes+d.duration_minutes-d.threshold_minutes,0)
    >greatest(d.prior_minutes-d.threshold_minutes,0)
)
select e.slot_id,e.employee_id,e.rule_id,e.calculation_type,e.cost_units
from expected e;
$$;

revoke all on function solver_private.slot_timezone_v2(jsonb,jsonb)
  from public,anon,authenticated;
revoke all on function solver_private.pay_condition_matches_v2(jsonb,jsonb,jsonb,jsonb)
  from public,anon,authenticated;
revoke all on function solver_private.pay_rule_matches_v2(jsonb,jsonb,jsonb,jsonb)
  from public,anon,authenticated;
revoke all on function solver_private.expected_pay_components_v2(jsonb,jsonb)
  from public,anon,authenticated;
grant execute on function solver_private.slot_timezone_v2(jsonb,jsonb) to service_role;
grant execute on function solver_private.pay_condition_matches_v2(jsonb,jsonb,jsonb,jsonb)
  to service_role;
grant execute on function solver_private.pay_rule_matches_v2(jsonb,jsonb,jsonb,jsonb)
  to service_role;
grant execute on function solver_private.expected_pay_components_v2(jsonb,jsonb)
  to service_role;

create or replace function solver_private.validate_variant_v2(
  p_snapshot jsonb,p_variant jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_invalid bigint;
  v_slot_count integer := jsonb_array_length(coalesce(p_snapshot->'slots','[]'::jsonb));
  v_assignment_count integer := jsonb_array_length(coalesce(p_variant->'assignments','[]'::jsonb));
  v_unfilled_count integer := jsonb_array_length(coalesce(p_variant->'unfilledSlotIds','[]'::jsonb));
  v_cost_units bigint := 0;
  v_solution_hash text;
  v_budget_minor bigint := nullif(p_snapshot->'budget'->>'amountMinor','')::bigint;
  v_hard_budget boolean := coalesce((p_snapshot->'budget'->>'hard')::boolean,false);
  v_timezone text := nullif(p_snapshot->'settings'->>'timezone','');
  v_missing_available boolean :=
    (p_snapshot->'settings'->>'missingAvailabilityMeansAvailable')::boolean;
begin
  if p_variant->>'schemaVersion' is distinct from '2' then raise exception 'VARIANT_SCHEMA_INVALID'; end if;
  if v_timezone is null or not exists(
    select 1 from pg_catalog.pg_timezone_names tz where tz.name=v_timezone
  ) or v_missing_available is null then
    raise exception 'SNAPSHOT_SETTINGS_INVALID';
  end if;
  if not public.matrix_v2_is_iso_4217_currency(
    coalesce(p_snapshot->>'currency','')
  )
    or exists(
      select 1 from jsonb_array_elements(coalesce(p_snapshot->'payRules','[]'::jsonb)) r
      where coalesce(r.value->>'currency',p_snapshot->>'currency')
        <>p_snapshot->>'currency'
    ) or exists(
      select 1 from jsonb_array_elements(coalesce(p_snapshot->'budgets','[]'::jsonb)) b
      where coalesce(b.value->>'currency',p_snapshot->>'currency')
        <>p_snapshot->>'currency'
    ) then raise exception 'SNAPSHOT_CURRENCY_INVALID'; end if;
  if jsonb_typeof(p_variant->'assignments') is distinct from 'array'
    or jsonb_typeof(p_variant->'unfilledSlotIds') is distinct from 'array'
    or jsonb_typeof(p_variant->'metrics') is distinct from 'object' then
    raise exception 'VARIANT_ARRAYS_REQUIRED';
  end if;
  if coalesce(p_variant->>'solutionHash','') !~ '^[0-9a-f]{64}$' then
    raise exception 'VARIANT_SOLUTION_HASH_INVALID';
  end if;
  if not exists(
    select 1 from jsonb_array_elements(coalesce(p_snapshot->'strategies','[]'::jsonb)) s
    where s->>'id'=p_variant->>'strategyId'
  ) then raise exception 'VARIANT_STRATEGY_INVALID'; end if;

  with a as (
    select value->>'slotId' slot_id,value->>'employeeId' employee_id
    from jsonb_array_elements(p_variant->'assignments')
  ), u as (
    select value#>>'{}' slot_id from jsonb_array_elements(p_variant->'unfilledSlotIds')
  ), submitted as (
    select slot_id from a union all select slot_id from u
  ), slots as (
    select value->>'slotId' slot_id from jsonb_array_elements(p_snapshot->'slots')
  )
  select count(*) into v_invalid from (
    select slot_id from submitted group by slot_id having count(*)<>1
    union all
    select submitted.slot_id from submitted left join slots using(slot_id) where slots.slot_id is null
    union all
    select slots.slot_id from slots left join submitted using(slot_id) where submitted.slot_id is null
  ) bad;
  if v_invalid>0 or v_assignment_count+v_unfilled_count<>v_slot_count then
    raise exception 'VARIANT_SLOT_COVERAGE_INVALID';
  end if;
  with a as (
    select value->>'slotId' slot_id,value->>'employeeId' employee_id
    from jsonb_array_elements(p_variant->'assignments')
  ), slots as (
    select value->>'slotId' slot_id from jsonb_array_elements(p_snapshot->'slots')
  ), selected_map as (
    select jsonb_object_agg(s.slot_id,to_jsonb(a.employee_id) order by s.slot_id) payload
    from slots s left join a using(slot_id)
  )
  select encode(extensions.digest(convert_to(
    solver_private.canonical_json_v2(payload),'UTF8'
  ),'sha256'),'hex') into v_solution_hash from selected_map;
  if v_solution_hash is distinct from lower(p_variant->>'solutionHash') then
    raise exception 'VARIANT_SOLUTION_HASH_MISMATCH';
  end if;

  with a as (
    select value->>'slotId' slot_id,value->>'employeeId' employee_id
    from jsonb_array_elements(p_variant->'assignments')
  ), pairs as (
    select a.*,s.value slot,
      (select e.value from jsonb_array_elements(p_snapshot->'employees') e
       where e.value->>'id'=a.employee_id limit 1) employee,
      solver_private.slot_timezone_v2(p_snapshot,s.value) slot_timezone
    from a join jsonb_array_elements(p_snapshot->'slots') s
      on s.value->>'slotId'=a.slot_id
  )
  select count(*) into v_invalid from pairs p where
    p.employee is null
    or not solver_private.employee_scope_eligible_v2(p.employee,p.slot)
    or nullif(
      solver_private.employee_for_slot_v2(p.employee,p.slot)->>'baseHourlyRateMinor',''
    ) is null
    or ((p.employee->>'employmentStart') is not null
      and (p.slot->>'date')::date<(p.employee->>'employmentStart')::date)
    or ((p.employee->>'employmentEnd') is not null
      and (((p.slot->>'end')::timestamptz at time zone p.slot_timezone)::date
        >(p.employee->>'employmentEnd')::date))
    or (coalesce((p.employee->>'noWeekends')::boolean,false)
      and extract(isodow from ((p.slot->>'start')::timestamptz at time zone p.slot_timezone))>=6)
    or ((p.employee->>'onlyMorningBeforeMinute') is not null and
      extract(hour from ((p.slot->>'end')::timestamptz at time zone p.slot_timezone))*60+
      extract(minute from ((p.slot->>'end')::timestamptz at time zone p.slot_timezone))+
      case when ((p.slot->>'end')::timestamptz at time zone p.slot_timezone)::date
          >((p.slot->>'start')::timestamptz at time zone p.slot_timezone)::date
        then 1440 else 0 end>
      (p.employee->>'onlyMorningBeforeMinute')::integer)
    or ((p.employee->>'onlyEveningAfterMinute') is not null and
      extract(hour from ((p.slot->>'start')::timestamptz at time zone p.slot_timezone))*60+
      extract(minute from ((p.slot->>'start')::timestamptz at time zone p.slot_timezone))<
      (p.employee->>'onlyEveningAfterMinute')::integer);
  if v_invalid>0 then raise exception 'VARIANT_EMPLOYEE_ELIGIBILITY_INVALID'; end if;

  with a as (
    select value->>'slotId' slot_id,value->>'employeeId' employee_id
    from jsonb_array_elements(p_variant->'assignments')
  ), pairs as (
    select a.employee_id,s.value slot,
      solver_private.slot_timezone_v2(p_snapshot,s.value) slot_timezone
    from a join jsonb_array_elements(p_snapshot->'slots') s on s.value->>'slotId'=a.slot_id
  )
  select count(*) into v_invalid
  from pairs p
  where exists(
    select 1 from jsonb_array_elements(coalesce(p_snapshot->'hardBlocks','[]'::jsonb)) b
    where b->>'employeeId'=p.employee_id
      and tstzrange((p.slot->>'start')::timestamptz,(p.slot->>'end')::timestamptz,'[)')
        && tstzrange((b->>'start')::timestamptz,(b->>'end')::timestamptz,'[)')
  );
  if v_invalid>0 then raise exception 'VARIANT_HARD_BLOCK_INVALID'; end if;

  with a as (
    select value->>'slotId' slot_id,value->>'employeeId' employee_id
    from jsonb_array_elements(p_variant->'assignments')
  ), pairs as (
    select a.employee_id,s.value slot,
      solver_private.slot_timezone_v2(p_snapshot,s.value) slot_timezone
    from a join jsonb_array_elements(p_snapshot->'slots') s on s.value->>'slotId'=a.slot_id
  )
  select count(*) into v_invalid from pairs p
  where (
    exists(
      select 1 from jsonb_array_elements(coalesce(p_snapshot->'availabilityWindows','[]'::jsonb)) w
      where w->>'employeeId'=p.employee_id
        and tstzrange((w->>'start')::timestamptz,(w->>'end')::timestamptz,'[)')
          && tstzrange(
            (p.slot->>'date')::timestamp at time zone p.slot_timezone,
            ((p.slot->>'date')::date+1)::timestamp at time zone p.slot_timezone,'[)'
          )
    ) or not v_missing_available
  ) and not exists(
    select 1 from jsonb_array_elements(coalesce(p_snapshot->'availabilityWindows','[]'::jsonb)) w
    where w->>'employeeId'=p.employee_id
      and (w->>'start')::timestamptz<=(p.slot->>'start')::timestamptz
      and (w->>'end')::timestamptz>=(p.slot->>'end')::timestamptz
  );
  if v_invalid>0 then raise exception 'VARIANT_AVAILABILITY_INVALID'; end if;

  with a as (
    select value->>'slotId' slot_id,value->>'employeeId' employee_id
    from jsonb_array_elements(p_variant->'assignments')
  ), combined as (
    select a.employee_id,'ASSIGNED'::text source,a.slot_id item_key,
      (s.value->>'start')::timestamptz starts_at,
      (s.value->>'end')::timestamptz ends_at
    from a join jsonb_array_elements(p_snapshot->'slots') s on s.value->>'slotId'=a.slot_id
    union all
    select x.value->>'employeeId','EXTERNAL','external:'||x.ordinality::text,
      (x.value->>'start')::timestamptz,(x.value->>'end')::timestamptz
    from jsonb_array_elements(coalesce(p_snapshot->'externalAssignments','[]'::jsonb))
      with ordinality x(value,ordinality)
  ), paired as (
    select x.*,y.source other_source,y.item_key other_key,
      y.starts_at other_start,y.ends_at other_end,
      coalesce((e.value->>'minimumRestMinutes')::integer,
        (p_snapshot->'settings'->>'defaultMinimumRestMinutes')::integer,0) rest_minutes
    from combined x join combined y
      on y.employee_id=x.employee_id and y.item_key>x.item_key
    join jsonb_array_elements(p_snapshot->'employees') e on e.value->>'id'=x.employee_id
    where x.source='ASSIGNED' or y.source='ASSIGNED'
  )
  select count(*) into v_invalid from paired p
  where tstzrange(p.starts_at,p.ends_at,'[)')&&tstzrange(p.other_start,p.other_end,'[)')
    or case when p.starts_at<=p.other_start
      then p.other_start<p.ends_at+make_interval(mins=>p.rest_minutes)
      else p.starts_at<p.other_end+make_interval(mins=>p.rest_minutes) end;
  if v_invalid>0 then raise exception 'VARIANT_OVERLAP_OR_REST_INVALID'; end if;

  with a as (
    select value->>'slotId' slot_id,value->>'employeeId' employee_id
    from jsonb_array_elements(p_variant->'assignments')
  ), combined as (
    select a.employee_id,(s.value->>'date')::date work_date,
      (s.value->>'durationMinutes')::integer duration_minutes
    from a join jsonb_array_elements(p_snapshot->'slots') s on s.value->>'slotId'=a.slot_id
    union all
    select x.value->>'employeeId',
      ((x.value->>'start')::timestamptz at time zone v_timezone)::date,
      floor(extract(epoch from (
        (x.value->>'end')::timestamptz-(x.value->>'start')::timestamptz
      ))/60)::integer
    from jsonb_array_elements(coalesce(p_snapshot->'externalAssignments','[]'::jsonb)) x
  ), assigned as (
    select c.*,e.value employee from combined c
    join jsonb_array_elements(p_snapshot->'employees') e on e.value->>'id'=c.employee_id
    where c.work_date between (p_snapshot->>'periodStart')::date-6
      and (p_snapshot->>'periodEnd')::date+6
  ), violations as (
    select employee_id from assigned
    where work_date between (p_snapshot->>'periodStart')::date
      and (p_snapshot->>'periodEnd')::date
    group by employee_id,work_date,(employee->>'maximumShiftsPerDay')::integer
      having count(*)>(employee->>'maximumShiftsPerDay')::integer
    union all
    select employee_id from assigned
    where date_trunc('week',work_date)::date<=(p_snapshot->>'periodEnd')::date
      and (date_trunc('week',work_date)::date+6)>=(p_snapshot->>'periodStart')::date
    group by employee_id,date_trunc('week',work_date),(employee->>'maximumWeeklyMinutes')::integer
      having sum(duration_minutes)>(employee->>'maximumWeeklyMinutes')::integer
    union all
    select employee_id from assigned
    where work_date between (p_snapshot->>'periodStart')::date
      and (p_snapshot->>'periodEnd')::date
    group by employee_id,(employee->>'maximumMonthlyMinutes')::integer
      having sum(duration_minutes)>(employee->>'maximumMonthlyMinutes')::integer
  )
  select count(*) into v_invalid from violations;
  if v_invalid>0 then raise exception 'VARIANT_WORK_LIMIT_INVALID'; end if;

  with a as (
    select value->>'slotId' slot_id,value->>'employeeId' employee_id
    from jsonb_array_elements(p_variant->'assignments')
  ), combined as (
    select a.employee_id,(s.value->>'date')::date work_date
    from a join jsonb_array_elements(p_snapshot->'slots') s on s.value->>'slotId'=a.slot_id
    union
    select x.value->>'employeeId',
      ((x.value->>'start')::timestamptz at time zone v_timezone)::date
    from jsonb_array_elements(coalesce(p_snapshot->'externalAssignments','[]'::jsonb)) x
  ), days as (
    select distinct c.employee_id,c.work_date,
      (e.value->>'maximumConsecutiveDays')::integer maximum_days
    from combined c
    join jsonb_array_elements(p_snapshot->'employees') e on e.value->>'id'=c.employee_id
  ), numbered as (
    select *,work_date-(row_number() over(partition by employee_id order by work_date))::integer grp
    from days
  )
  select count(*) into v_invalid from (
    select employee_id,grp,maximum_days from numbered group by employee_id,grp,maximum_days
    having count(*)>maximum_days
      and max(work_date)>=(p_snapshot->>'periodStart')::date
      and min(work_date)<=(p_snapshot->>'periodEnd')::date
  ) x;
  if v_invalid>0 then raise exception 'VARIANT_CONSECUTIVE_DAYS_INVALID'; end if;

  with locked as (
    select value->>'slotId' slot_id,value->>'employeeId' employee_id
    from jsonb_array_elements(coalesce(p_snapshot->'lockedAssignments','[]'::jsonb))
  ), a as (
    select value->>'slotId' slot_id,value->>'employeeId' employee_id
    from jsonb_array_elements(p_variant->'assignments')
  )
  select count(*) into v_invalid from locked l
  left join a on a.slot_id=l.slot_id and a.employee_id=l.employee_id
  where a.slot_id is null;
  if v_invalid>0 then raise exception 'VARIANT_LOCKED_ASSIGNMENT_INVALID'; end if;

  select count(*) into v_invalid
  from jsonb_array_elements(coalesce(p_snapshot->'payRules','[]'::jsonb)) r
  where upper(coalesce(r.value->>'calculationType','')) not in (
      'FIXED_PER_SHIFT','PER_HOUR','PERCENT_BASE','MULTIPLIER',
      'SHIFT_DURATION_THRESHOLD_PER_HOUR','MONTHLY_THRESHOLD_PER_HOUR'
    )
    or upper(coalesce(nullif(r.value->>'stackingMode',''),'STACK')) not in ('STACK','FIRST','MAX')
    or (upper(r.value->>'calculationType')='MONTHLY_THRESHOLD_PER_HOUR'
      and upper(coalesce(nullif(r.value->>'stackingMode',''),'STACK'))<>'STACK')
    or (upper(r.value->>'calculationType')='FIXED_PER_SHIFT'
      and coalesce((r.value->'values'->>'amountMinor')::bigint,-1)<0)
    or (upper(r.value->>'calculationType') in (
        'PER_HOUR','SHIFT_DURATION_THRESHOLD_PER_HOUR','MONTHLY_THRESHOLD_PER_HOUR'
      ) and coalesce((r.value->'values'->>'rateMinorPerHour')::bigint,-1)<0)
    or (upper(r.value->>'calculationType') in (
        'SHIFT_DURATION_THRESHOLD_PER_HOUR','MONTHLY_THRESHOLD_PER_HOUR'
      ) and coalesce((r.value->'values'->>'thresholdMinutes')::bigint,-1)<0)
    or (upper(r.value->>'calculationType')='PERCENT_BASE'
      and coalesce((r.value->'values'->>'percentBasisPoints')::bigint,-1)<0)
    or (upper(r.value->>'calculationType')='MULTIPLIER'
      and coalesce((r.value->'values'->>'multiplierBasisPoints')::bigint,-1)<10000);
  if v_invalid>0 then raise exception 'SNAPSHOT_PAY_RULE_INVALID'; end if;
  select count(*) into v_invalid from (
    select coalesce(nullif(r.value->>'stackingGroup',''),r.value->>'id') stacking_group
    from jsonb_array_elements(coalesce(p_snapshot->'payRules','[]'::jsonb)) r
    group by coalesce(nullif(r.value->>'stackingGroup',''),r.value->>'id')
    having count(distinct upper(coalesce(nullif(r.value->>'stackingMode',''),'STACK')))>1
  ) inconsistent;
  if v_invalid>0 then raise exception 'SNAPSHOT_PAY_STACKING_INVALID'; end if;

  with a as (
    select value item from jsonb_array_elements(p_variant->'assignments')
  ), checked as (
    select item,
      coalesce((item->>'costUnits')::bigint,-1) cost_units,
      coalesce((select sum((c.value->>'costUnits')::bigint)
        from jsonb_array_elements(coalesce(item->'costComponents','[]'::jsonb)) c),0) component_units
    from a
  )
  select count(*) into v_invalid
  from checked where cost_units<0 or cost_units<>component_units;
  if v_invalid>0 then raise exception 'VARIANT_COST_COMPONENTS_INVALID'; end if;
  select coalesce(sum((value->>'costUnits')::bigint),0) into v_cost_units
  from jsonb_array_elements(p_variant->'assignments');

  with submitted as (
    select a.value->>'slotId' slot_id,a.value->>'employeeId' employee_id,
      c.value->>'ruleId' rule_id,c.value->>'calculationType' calculation_type,
      (c.value->>'costUnits')::bigint cost_units
    from jsonb_array_elements(p_variant->'assignments') a
    cross join lateral jsonb_array_elements(coalesce(a.value->'costComponents','[]'::jsonb)) c
  ), expected as (
    select * from solver_private.expected_pay_components_v2(p_snapshot,p_variant)
  )
  select count(*) into v_invalid from (
    (select * from submitted except all select * from expected)
    union all
    (select * from expected except all select * from submitted)
  ) differences;
  if v_invalid>0 then raise exception 'VARIANT_PAY_QUOTE_INVALID'; end if;
  if jsonb_array_length(coalesce(p_snapshot->'budgets','[]'::jsonb))>0 then
    with budgets as (
      select b.value
      from jsonb_array_elements(p_snapshot->'budgets') b
      where coalesce((b.value->>'hard')::boolean,false)
    ), assignment_costs as (
      select (a.value->>'costUnits')::bigint cost_units,s.value slot
      from jsonb_array_elements(p_variant->'assignments') a
      join jsonb_array_elements(p_snapshot->'slots') s
        on s.value->>'slotId'=a.value->>'slotId'
    )
    select count(*) into v_invalid
    from budgets b
    where nullif(b.value->>'amountMinor','') is null
      or (b.value->>'amountMinor')::bigint<0
      or coalesce((
        select sum(a.cost_units) from assignment_costs a
        where (nullif(b.value->>'locationId','') is null
            or a.slot->>'locationId'=b.value->>'locationId')
          and (nullif(b.value->>'roleId','') is null
            or a.slot->>'roleId'=b.value->>'roleId')
          and (nullif(b.value->>'dutyId','') is null
            or coalesce(a.slot->'dutyIds','[]'::jsonb) ? (b.value->>'dutyId'))
      ),0)>(b.value->>'amountMinor')::bigint*60;
    if v_invalid>0 then raise exception 'VARIANT_HARD_BUDGET_INVALID'; end if;
  elsif v_hard_budget and v_budget_minor is not null
    and v_cost_units>v_budget_minor*60 then
    raise exception 'VARIANT_HARD_BUDGET_INVALID';
  end if;
  if nullif(p_variant->'metrics'->>'UNFILLED','')::bigint is distinct from v_unfilled_count
    or nullif(p_variant->'metrics'->>'TOTAL_COST','')::bigint is distinct from v_cost_units then
    raise exception 'VARIANT_METRICS_INVALID';
  end if;

  return jsonb_build_object(
    'hardViolations',0,'slotCount',v_slot_count,'assignmentCount',v_assignment_count,
    'unfilledCount',v_unfilled_count,'totalCostUnits',v_cost_units,
    'budgetMinor',v_budget_minor,'hardBudget',v_hard_budget
  );
end;
$$;

revoke all on function solver_private.validate_variant_v2(jsonb,jsonb)
  from public,anon,authenticated;
grant execute on function solver_private.validate_variant_v2(jsonb,jsonb) to service_role;

create or replace function public.solver_save_variant_v2(
  p_run_id uuid,p_attempt_id uuid,p_lease_token uuid,p_variant jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_snapshot jsonb;
  v_snapshot_hash text;
  v_strategy_id uuid := nullif(p_variant->>'strategyId','')::uuid;
  v_run_strategy public.optimization_run_strategies_v2%rowtype;
  v_existing public.plan_variants_v2%rowtype;
  v_variant_id uuid := gen_random_uuid();
  v_validation jsonb;
  v_assignment_count integer;
  v_unfilled_count integer;
  v_total_units bigint;
  v_base_units bigint;
  v_total_minor bigint;
  v_base_minor bigint;
  v_budget_minor bigint;
  v_equivalent_id uuid;
  v_objective_bound bigint;
begin
  perform solver_private.lock_planning_revision_v2();
  if not solver_private.lease_is_live_v2(p_run_id,p_attempt_id,p_lease_token) then
    raise exception 'LEASE_LOST';
  end if;
  select s.snapshot,s.snapshot_hash into v_snapshot,v_snapshot_hash
  from solver_private.optimization_snapshots_v2 s where s.run_id=p_run_id;
  if v_snapshot is null then raise exception 'SNAPSHOT_NOT_FOUND'; end if;
  select * into v_run_strategy
  from public.optimization_run_strategies_v2 rs
  where rs.run_id=p_run_id and rs.strategy_id=v_strategy_id for update;
  if v_run_strategy.id is null then raise exception 'RUN_STRATEGY_NOT_FOUND'; end if;
  select * into v_existing from public.plan_variants_v2 v
  where v.run_strategy_id=v_run_strategy.id;
  if v_existing.id is not null then
    if v_existing.solution_hash=p_variant->>'solutionHash' then
      return jsonb_build_object('variantId',v_existing.id,'reused',true);
    end if;
    raise exception 'RUN_STRATEGY_VARIANT_ALREADY_SAVED';
  end if;

  v_validation := solver_private.validate_variant_v2(v_snapshot,p_variant);
  v_assignment_count := (v_validation->>'assignmentCount')::integer;
  v_unfilled_count := (v_validation->>'unfilledCount')::integer;
  v_total_units := (v_validation->>'totalCostUnits')::bigint;
  v_budget_minor := nullif(v_validation->>'budgetMinor','')::bigint;
  select v.id into v_equivalent_id from public.plan_variants_v2 v
  where v.run_id=p_run_id and v.solution_hash=p_variant->>'solutionHash'
  order by v.created_at limit 1;
  select nullif(x.value->>'bestBound','')::numeric::bigint into v_objective_bound
  from jsonb_array_elements(coalesce(p_variant->'stageObjectives','[]'::jsonb))
    with ordinality x(value,ordinality)
  where x.value ? 'bestBound' order by x.ordinality desc limit 1;

  insert into public.plan_variants_v2(
    id,run_id,run_strategy_id,strategy_id,name,status,hard_violations,
    assignment_count,unfilled_count,solver_status,solution_hash,objective_bound,
    metrics,recommended,selected,equivalent_to_variant_id,snapshot_hash
  ) values(
    v_variant_id,p_run_id,v_run_strategy.id,v_strategy_id,
    coalesce(nullif(p_variant->>'label',''),(select name from public.matrix_strategies_v2 where id=v_strategy_id)),
    'READY',0,v_assignment_count,v_unfilled_count,
    case when coalesce((p_variant->>'optimal')::boolean,false) then 'OPTIMAL' else 'FEASIBLE' end,
    p_variant->>'solutionHash',v_objective_bound,
    (coalesce(p_variant->'metrics','{}'::jsonb)-'TOTAL_COST'-'TOTAL_COST_MINOR'),
    false,false,v_equivalent_id,v_snapshot_hash
  );

  insert into public.plan_shifts_v2(
    variant_id,slot_group_key,shift_template_id,location_id,shift_date,
    starts_at,ends_at,source_type,source_id
  )
  select distinct on (slot->>'occurrenceId')
    v_variant_id,slot->>'occurrenceId',(slot->>'shiftTemplateId')::uuid,
    (slot->>'locationId')::uuid,(slot->>'date')::date,
    (slot->>'start')::timestamptz,(slot->>'end')::timestamptz,'MATRIX',
    (slot->>'demandId')::uuid
  from jsonb_array_elements(v_snapshot->'slots') slot
  order by slot->>'occurrenceId',slot->>'slotId';

  insert into public.plan_assignments_v2(
    variant_id,shift_id,slot_key,employee_id,role_id,locked,explanation
  )
  select v_variant_id,sh.id,a.value->>'slotId',(a.value->>'employeeId')::uuid,
    (slot.value->>'roleId')::uuid,
    exists(select 1 from jsonb_array_elements(coalesce(v_snapshot->'lockedAssignments','[]'::jsonb)) l
      where l.value->>'slotId'=a.value->>'slotId'),
    jsonb_build_object('strategyId',v_strategy_id,'solver','ORTOOLS_V2')
  from jsonb_array_elements(p_variant->'assignments') a
  join jsonb_array_elements(v_snapshot->'slots') slot
    on slot.value->>'slotId'=a.value->>'slotId'
  join public.plan_shifts_v2 sh
    on sh.variant_id=v_variant_id and sh.slot_group_key=slot.value->>'occurrenceId';

  insert into public.plan_assignment_duties_v2(assignment_id,duty_id)
  select pa.id,(d.value#>>'{}')::uuid
  from public.plan_assignments_v2 pa
  join jsonb_array_elements(v_snapshot->'slots') slot on slot.value->>'slotId'=pa.slot_key
  cross join lateral jsonb_array_elements(coalesce(slot.value->'dutyIds','[]'::jsonb)) d
  where pa.variant_id=v_variant_id;

  insert into public.plan_issues_v2(
    variant_id,shift_id,slot_key,issue_code,severity,role_id,duty_id,
    required_count,assigned_count,message,metadata
  )
  select v_variant_id,sh.id,u.value#>>'{}','UNFILLED_SLOT','WARNING',
    (slot.value->>'roleId')::uuid,
    case when jsonb_array_length(coalesce(slot.value->'dutyIds','[]'::jsonb))=1
      then (slot.value->'dutyIds'->>0)::uuid else null end,
    1,0,'Nieobsadzone miejsce wymagane przez Matrix.',
    jsonb_build_object('demandId',slot.value->>'demandId')
  from jsonb_array_elements(p_variant->'unfilledSlotIds') u
  join jsonb_array_elements(v_snapshot->'slots') slot
    on slot.value->>'slotId'=u.value#>>'{}'
  join public.plan_shifts_v2 sh
    on sh.variant_id=v_variant_id and sh.slot_group_key=slot.value->>'occurrenceId';

  insert into solver_private.plan_assignment_cost_components_v2(
    assignment_id,pay_rule_id,component_code,amount_minor,quantity_minutes,calculation_basis
  )
  select pa.id,
    case when c.value->>'ruleId'='BASE' then null else (c.value->>'ruleId')::uuid end,
    coalesce(nullif(c.value->>'calculationType',''),'UNKNOWN'),
    round((c.value->>'costUnits')::numeric/60)::bigint,
    (slot.value->>'durationMinutes')::integer,
    jsonb_build_object('costUnits',(c.value->>'costUnits')::bigint)
  from jsonb_array_elements(p_variant->'assignments') a
  join public.plan_assignments_v2 pa
    on pa.variant_id=v_variant_id and pa.slot_key=a.value->>'slotId'
  join jsonb_array_elements(v_snapshot->'slots') slot
    on slot.value->>'slotId'=a.value->>'slotId'
  cross join lateral jsonb_array_elements(coalesce(a.value->'costComponents','[]'::jsonb)) c;

  select coalesce(sum((c.value->>'costUnits')::bigint),0) into v_base_units
  from jsonb_array_elements(p_variant->'assignments') a
  cross join lateral jsonb_array_elements(coalesce(a.value->'costComponents','[]'::jsonb)) c
  where c.value->>'ruleId'='BASE';
  v_base_minor := round(v_base_units::numeric/60)::bigint;
  v_total_minor := round(v_total_units::numeric/60)::bigint;
  insert into solver_private.plan_variant_finance_v2(
    variant_id,base_cost_units,additions_cost_units,total_cost_units,
    base_cost_minor,additions_cost_minor,total_cost_minor,currency,budget_minor,
    hard_budget_exceeded,breakdown
  ) values(
    v_variant_id,v_base_units,greatest(v_total_units-v_base_units,0),v_total_units,
    v_base_minor,greatest(v_total_minor-v_base_minor,0),v_total_minor,
    v_snapshot->>'currency',v_budget_minor,
    coalesce((v_snapshot->'budget'->>'hard')::boolean,false)
      and v_budget_minor is not null and v_total_units>v_budget_minor*60,
    jsonb_build_object(
      'costScale','60 units = 1 minor currency unit',
      'currency',v_snapshot->>'currency',
      'budgets',coalesce(v_snapshot->'budgets','[]'::jsonb)
    )
  );

  update public.optimization_run_strategies_v2 set
    status='READY',phase='SAVED',progress=100,
    metrics=(coalesce(p_variant->'metrics','{}'::jsonb)-'TOTAL_COST'-'TOTAL_COST_MINOR'),
    started_at=coalesce(started_at,now()),finished_at=now(),updated_at=now()
  where id=v_run_strategy.id;
  update public.optimization_runs_v2 r set
    phase='SAVING_VARIANTS',
    progress=greatest(r.progress,least(99,(
      select floor(90.0*count(*)/greatest((select count(*) from public.optimization_run_strategies_v2 all_s where all_s.run_id=p_run_id),1))::integer+5
      from public.optimization_run_strategies_v2 ready_s where ready_s.run_id=p_run_id and ready_s.status='READY'
    ))),heartbeat_at=now(),lease_expires_at=now()+interval '120 seconds',updated_at=now()
  where r.id=p_run_id and r.lease_token=p_lease_token;
  return jsonb_build_object('variantId',v_variant_id,'reused',false,
    'assignmentCount',v_assignment_count,'unfilledCount',v_unfilled_count);
end;
$$;

create or replace function public.solver_finalize_v2(
  p_run_id uuid,p_attempt_id uuid,p_lease_token uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run public.optimization_runs_v2%rowtype;
  v_stored jsonb;
  v_current jsonb;
  v_current_hash text;
  v_expected integer;
  v_ready integer;
  v_require_optimal boolean;
begin
  perform solver_private.lock_planning_revision_v2();
  if not solver_private.lease_is_live_v2(p_run_id,p_attempt_id,p_lease_token) then
    raise exception 'LEASE_LOST';
  end if;
  select * into v_run from public.optimization_runs_v2 where id=p_run_id for update;
  if v_run.status='CANCEL_REQUESTED' then
    delete from public.plan_variants_v2 where run_id=p_run_id;
    update public.optimization_runs_v2 set status='CANCELLED',phase='CANCELLED',
      finished_at=now(),updated_at=now(),lease_owner=null,lease_token=null,lease_expires_at=null
    where id=p_run_id;
    update solver_private.optimization_attempts_v2 set status='INTERRUPTED',
      finished_at=now(),error_code='CANCEL_REQUESTED' where id=p_attempt_id;
    return jsonb_build_object('status','CANCELLED');
  end if;

  update public.optimization_runs_v2 set status='VALIDATING',phase='DATABASE_VALIDATION',
    progress=99,updated_at=now() where id=p_run_id;
  select snapshot into v_stored from solver_private.optimization_snapshots_v2 where run_id=p_run_id;
  v_current := solver_private.build_snapshot_payload_v2(
    p_run_id,v_run.month,v_run.matrix_version_id,v_run.scenario_id,
    v_run.scope_type,v_run.scope_role_id
  );
  v_current_hash := encode(extensions.digest(convert_to(
    solver_private.canonical_json_v2(v_current),'UTF8'
  ),'sha256'),'hex');
  if v_current_hash<>v_run.snapshot_hash then
    update public.plan_variants_v2 set status='ARCHIVED' where run_id=p_run_id;
    update public.optimization_run_strategies_v2 set status='STALE_INPUT',
      phase='STALE_INPUT',updated_at=now() where run_id=p_run_id;
    update public.optimization_runs_v2 set status='STALE_INPUT',phase='STALE_INPUT',
      failure_code='SNAPSHOT_CHANGED',
      failure_message='Dane Matrixa lub pracowników zmieniły się podczas optymalizacji.',
      finished_at=now(),updated_at=now(),lease_owner=null,lease_token=null,lease_expires_at=null
    where id=p_run_id;
    update solver_private.optimization_attempts_v2 set status='FAILED',finished_at=now(),
      error_code='SNAPSHOT_CHANGED' where id=p_attempt_id;
    return jsonb_build_object('status','STALE_INPUT','currentSnapshotHash',v_current_hash);
  end if;
  select count(*) into v_expected from public.optimization_run_strategies_v2
  where run_id=p_run_id;
  select count(*) into v_ready from public.optimization_run_strategies_v2 rs
  join public.plan_variants_v2 v on v.run_strategy_id=rs.id
  where rs.run_id=p_run_id and rs.status='READY' and v.hard_violations=0;
  if v_expected=0 or v_ready<>v_expected then raise exception 'RUN_VARIANTS_INCOMPLETE'; end if;
  v_require_optimal := coalesce((v_stored->'settings'->>'requireOptimal')::boolean,true);
  if v_require_optimal and exists(
    select 1 from public.plan_variants_v2 where run_id=p_run_id and solver_status<>'OPTIMAL'
  ) then raise exception 'RUN_REQUIRES_OPTIMAL_VARIANTS'; end if;

  update public.plan_variants_v2 set recommended=false where run_id=p_run_id;
  update public.plan_variants_v2 v set recommended=true
  where v.id=(
    select pv.id from public.plan_variants_v2 pv
    join public.optimization_run_strategies_v2 rs on rs.id=pv.run_strategy_id
    where pv.run_id=p_run_id order by rs.ordinal limit 1
  );
  update public.optimization_runs_v2 set status='READY',phase='READY',progress=100,
    finished_at=now(),updated_at=now(),heartbeat_at=now(),
    lease_owner=null,lease_token=null,lease_expires_at=null
  where id=p_run_id;
  update solver_private.optimization_attempts_v2 set status='SUCCEEDED',
    heartbeat_at=now(),finished_at=now() where id=p_attempt_id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_run.requested_by,'optimization_run_v2',p_run_id::text,'READY',
    jsonb_build_object('variantCount',v_ready,'snapshotHash',v_run.snapshot_hash));
  return jsonb_build_object('status','READY','runId',p_run_id,'variantCount',v_ready);
end;
$$;

create or replace function public.solver_interrupt_v2(
  p_run_id uuid,p_attempt_id uuid,p_lease_token uuid,p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run public.optimization_runs_v2%rowtype;
  v_retry boolean;
  v_message_id bigint;
begin
  perform solver_private.lock_planning_revision_v2();
  if not solver_private.lease_is_live_v2(p_run_id,p_attempt_id,p_lease_token) then
    raise exception 'LEASE_LOST';
  end if;
  select * into v_run from public.optimization_runs_v2 where id=p_run_id for update;
  if v_run.status='CANCEL_REQUESTED' or upper(coalesce(p_reason,''))='CANCEL_REQUESTED' then
    delete from public.plan_variants_v2 where run_id=p_run_id;
    update public.optimization_runs_v2 set status='CANCELLED',phase='CANCELLED',
      finished_at=now(),updated_at=now(),lease_owner=null,lease_token=null,lease_expires_at=null
    where id=p_run_id;
    update public.optimization_run_strategies_v2 set status='CANCELLED',phase='CANCELLED',
      finished_at=now(),updated_at=now() where run_id=p_run_id and status<>'READY';
    update solver_private.optimization_attempts_v2 set status='INTERRUPTED',
      error_code='CANCELLED',error_message=left(p_reason,1000),finished_at=now()
    where id=p_attempt_id;
    return jsonb_build_object('status','CANCELLED','retry',false);
  end if;
  v_retry := v_run.attempt_count<v_run.max_attempts;
  update solver_private.optimization_attempts_v2 set status='INTERRUPTED',
    error_code='INTERRUPTED',error_message=left(coalesce(p_reason,'INTERRUPTED'),1000),finished_at=now()
  where id=p_attempt_id;
  if v_retry then
    select pgmq.send('schedule_optimizer_v2',jsonb_build_object(
      'schemaVersion',2,'runId',p_run_id,'retry',true
    )) into v_message_id;
    update public.optimization_runs_v2 set status='QUEUED',phase='RETRY_QUEUED',
      queue_message_id=v_message_id,updated_at=now(),lease_owner=null,lease_token=null,
      lease_expires_at=null where id=p_run_id;
    update public.optimization_run_strategies_v2 set status='QUEUED',phase='RETRY_QUEUED',
      progress=0,updated_at=now() where run_id=p_run_id and status<>'READY';
  else
    delete from public.plan_variants_v2 where run_id=p_run_id;
    update public.optimization_runs_v2 set status='FAILED',phase='FAILED',
      failure_code='INTERRUPTED',failure_message='Solver został przerwany.',
      finished_at=now(),updated_at=now(),lease_owner=null,lease_token=null,lease_expires_at=null
    where id=p_run_id;
  end if;
  return jsonb_build_object('status',case when v_retry then 'QUEUED' else 'FAILED' end,
    'retry',v_retry);
end;
$$;

create or replace function public.solver_fail_attempt_v2(
  p_run_id uuid,p_attempt_id uuid,p_lease_token uuid,p_error_code text,
  p_error_message text,p_retryable boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run public.optimization_runs_v2%rowtype;
  v_retry boolean;
  v_message_id bigint;
begin
  perform solver_private.lock_planning_revision_v2();
  if not solver_private.lease_is_live_v2(p_run_id,p_attempt_id,p_lease_token) then
    raise exception 'LEASE_LOST';
  end if;
  select * into v_run from public.optimization_runs_v2 where id=p_run_id for update;
  v_retry := coalesce(p_retryable,false) and v_run.attempt_count<v_run.max_attempts
    and v_run.status<>'CANCEL_REQUESTED';
  update solver_private.optimization_attempts_v2 set status='FAILED',
    error_code=left(coalesce(p_error_code,'WORKER_ERROR'),100),
    error_message=left(coalesce(p_error_message,'Nieznany błąd workera.'),1000),finished_at=now()
  where id=p_attempt_id;
  if v_retry then
    select pgmq.send('schedule_optimizer_v2',jsonb_build_object(
      'schemaVersion',2,'runId',p_run_id,'retry',true
    )) into v_message_id;
    update public.optimization_runs_v2 set status='QUEUED',phase='RETRY_QUEUED',
      queue_message_id=v_message_id,failure_code=left(p_error_code,100),
      failure_message='Próba solvera nie powiodła się; zadanie oczekuje na ponowienie.',
      updated_at=now(),lease_owner=null,lease_token=null,lease_expires_at=null
    where id=p_run_id;
    update public.optimization_run_strategies_v2 set status='QUEUED',phase='RETRY_QUEUED',
      progress=0,updated_at=now() where run_id=p_run_id and status<>'READY';
  else
    delete from public.plan_variants_v2 where run_id=p_run_id;
    update public.optimization_runs_v2 set
      status=case when status='CANCEL_REQUESTED' then 'CANCELLED' else 'FAILED' end,
      phase=case when status='CANCEL_REQUESTED' then 'CANCELLED' else 'FAILED' end,
      failure_code=left(coalesce(p_error_code,'WORKER_ERROR'),100),
      failure_message=left(coalesce(p_error_message,'Nieznany błąd workera.'),1000),
      finished_at=now(),updated_at=now(),lease_owner=null,lease_token=null,lease_expires_at=null
    where id=p_run_id;
    update public.optimization_run_strategies_v2 set
      status=case when v_run.status='CANCEL_REQUESTED' then 'CANCELLED' else 'FAILED' end,
      phase=case when v_run.status='CANCEL_REQUESTED' then 'CANCELLED' else 'FAILED' end,
      failure_code=left(coalesce(p_error_code,'WORKER_ERROR'),100),finished_at=now(),updated_at=now()
    where run_id=p_run_id and status<>'READY';
  end if;
  return jsonb_build_object('status',case when v_retry then 'QUEUED'
    when v_run.status='CANCEL_REQUESTED' then 'CANCELLED' else 'FAILED' end,'retry',v_retry);
end;
$$;

revoke all on function public.optimizer_request_v2(date,uuid,text,uuid,text,text)
  from public,anon,authenticated;
revoke all on function public.optimizer_status_v2(uuid)
  from public,anon,authenticated;
revoke all on function public.optimizer_request_cancel_v2(uuid)
  from public,anon,authenticated;
revoke all on function public.optimizer_variants_v2(uuid)
  from public,anon,authenticated;
revoke all on function public.optimizer_select_variant_v2(uuid,uuid)
  from public,anon,authenticated;
grant execute on function public.optimizer_request_v2(date,uuid,text,uuid,text,text)
  to authenticated;
grant execute on function public.optimizer_status_v2(uuid) to authenticated;
grant execute on function public.optimizer_request_cancel_v2(uuid) to authenticated;
grant execute on function public.optimizer_variants_v2(uuid) to authenticated;
grant execute on function public.optimizer_select_variant_v2(uuid,uuid) to authenticated;

revoke all on function public.solver_load_snapshot_v2(uuid,uuid,uuid)
  from public,anon,authenticated;
revoke all on function public.solver_heartbeat_v2(uuid,uuid,uuid,jsonb)
  from public,anon,authenticated;
revoke all on function public.solver_save_variant_v2(uuid,uuid,uuid,jsonb)
  from public,anon,authenticated;
revoke all on function public.solver_finalize_v2(uuid,uuid,uuid)
  from public,anon,authenticated;
revoke all on function public.solver_interrupt_v2(uuid,uuid,uuid,text)
  from public,anon,authenticated;
revoke all on function public.solver_fail_attempt_v2(uuid,uuid,uuid,text,text,boolean)
  from public,anon,authenticated;
grant execute on function public.solver_load_snapshot_v2(uuid,uuid,uuid) to service_role;
grant execute on function public.solver_heartbeat_v2(uuid,uuid,uuid,jsonb) to service_role;
grant execute on function public.solver_save_variant_v2(uuid,uuid,uuid,jsonb) to service_role;
grant execute on function public.solver_finalize_v2(uuid,uuid,uuid) to service_role;
grant execute on function public.solver_interrupt_v2(uuid,uuid,uuid,text) to service_role;
grant execute on function public.solver_fail_attempt_v2(uuid,uuid,uuid,text,text,boolean)
  to service_role;

comment on function public.optimizer_request_v2(date,uuid,text,uuid,text,text) is
  'Creates an immutable Matrix v2 snapshot and enqueues a dynamic OR-Tools run.';
comment on function public.solver_save_variant_v2(uuid,uuid,uuid,jsonb) is
  'Service-role-only, set-based variant validation and materialization.';
