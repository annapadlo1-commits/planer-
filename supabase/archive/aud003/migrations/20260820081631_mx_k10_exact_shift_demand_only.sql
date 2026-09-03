-- MX-K10 / MX-K12: staffing demand belongs to an exact shift template.
--
-- UAT was audited immediately before this migration: no active or inactive
-- matrix_role_duties_v2 row carries REQUIRED/minimum/shift_obligation/period
-- metadata.  The precondition below deliberately fails if broad runtime data
-- appears between that audit and deployment.  We must never guess which of
-- several same-period shifts the owner meant.

create table if not exists solver_private.mx_k10_legacy_role_duty_archive (
  legacy_role_duty_id uuid primary key,
  matrix_version_id uuid not null,
  role_id uuid not null,
  duty_id uuid not null,
  assignment_mode text not null,
  minimum_count integer not null,
  shift_obligation boolean not null,
  shift_period text,
  active boolean not null,
  source_row jsonb not null,
  archived_at timestamptz not null default now()
);

alter table solver_private.mx_k10_legacy_role_duty_archive enable row level security;
revoke all on table solver_private.mx_k10_legacy_role_duty_archive
  from public,anon,authenticated;

do $$
declare
  v_count integer;
  v_ids text;
begin
  select count(*),string_agg(role_duty.id::text,',' order by role_duty.id::text)
  into v_count,v_ids
  from public.matrix_role_duties_v2 role_duty
  where role_duty.active and (
    role_duty.assignment_mode='REQUIRED'
    or role_duty.minimum_count>0
    or role_duty.shift_obligation
    or role_duty.shift_period is not null
  );

  if v_count>0 then
    raise exception using
      errcode='P0001',
      message=format(
        'MX_K10_EXACT_SHIFT_MAPPING_REQUIRED count=%s roleDutyIds=%s. Add exact matrix_staffing_rules_v2 rows before retrying; broad period demand was not changed.',
        v_count,coalesce(v_ids,'-')
      );
  end if;
end;
$$;

insert into solver_private.mx_k10_legacy_role_duty_archive(
  legacy_role_duty_id,matrix_version_id,role_id,duty_id,assignment_mode,
  minimum_count,shift_obligation,shift_period,active,source_row
)
select role_duty.id,role_duty.matrix_version_id,role_duty.role_id,
  role_duty.duty_id,role_duty.assignment_mode,role_duty.minimum_count,
  role_duty.shift_obligation,role_duty.shift_period,role_duty.active,
  to_jsonb(role_duty)
from public.matrix_role_duties_v2 role_duty
where role_duty.assignment_mode='REQUIRED'
  or role_duty.minimum_count>0
  or role_duty.shift_obligation
  or role_duty.shift_period is not null
on conflict(legacy_role_duty_id) do nothing;

-- Published Matrix rows are immutable to application traffic.  This is a
-- one-time schema/data migration after the fail-closed precondition and keeps
-- an audit snapshot above before canonicalising non-runtime legacy metadata.
alter table public.matrix_role_duties_v2
  disable trigger matrix_v2_immutable_guard;
drop trigger if exists matrix_role_duties_v2_alpha16_defaults
  on public.matrix_role_duties_v2;

update public.matrix_role_duties_v2 role_duty
set assignment_mode=case when role_duty.assignment_mode='EXTRA' then 'EXTRA' else 'OPTIONAL' end,
    minimum_count=0,
    shift_obligation=false,
    shift_period=null
where role_duty.assignment_mode='REQUIRED'
  or role_duty.minimum_count>0
  or role_duty.shift_obligation
  or role_duty.shift_period is not null;

alter table public.matrix_role_duties_v2
  enable trigger matrix_v2_immutable_guard;

drop function if exists solver_private.alpha16_role_duty_defaults_v2();

alter table public.matrix_role_duties_v2
  drop constraint if exists matrix_role_duties_v2_shift_period_check;
alter table public.matrix_role_duties_v2
  drop constraint if exists matrix_role_duties_v2_competency_only_check;
alter table public.matrix_role_duties_v2
  add constraint matrix_role_duties_v2_competency_only_check check (
    assignment_mode in ('OPTIONAL','EXTRA')
    and minimum_count=0
    and not shift_obligation
    and shift_period is null
  );

comment on table solver_private.mx_k10_legacy_role_duty_archive is
  'MX-K10 audit snapshot. A role-duty link is competency metadata; staffing demand must use an exact matrix_staffing_rules_v2.shift_template_id.';
comment on constraint matrix_role_duties_v2_competency_only_check
  on public.matrix_role_duties_v2 is
  'Role-duty rows never create demand. Exact shift demand lives in matrix_staffing_rules_v2.';

-- Keep the public RPC name stable, but reject the retired payload before the
-- older implementation can write anything.
alter function public.matrix_v2_admin_save_alpha16(text,uuid,jsonb)
  rename to matrix_v2_admin_save_before_mx_k10;

create function public.matrix_v2_admin_save_alpha16(
  p_kind text,p_id uuid,p_data jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_mode text:=upper(coalesce(nullif(trim(p_data->>'assignmentMode'),''),'OPTIONAL'));
  v_minimum_text text:=coalesce(nullif(trim(p_data->>'minimumCount'),''),'0');
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if upper(trim(p_kind))='ROLE_DUTY' and (
    v_mode not in ('OPTIONAL','EXTRA')
    or v_minimum_text !~ '^\d+$'
    or case when v_minimum_text ~ '^\d+$' then v_minimum_text::integer else 1 end<>0
    or lower(coalesce(p_data->>'shiftObligation','false')) in ('true','t','1','yes')
    or nullif(trim(p_data->>'shiftPeriod'),'') is not null
  ) then
    raise exception 'ROLE_DUTY_COMPETENCY_ONLY_USE_EXACT_SHIFT_STAFFING';
  end if;
  return public.matrix_v2_admin_save_before_mx_k10(
    p_kind,p_id,
    case when upper(trim(p_kind))='ROLE_DUTY' then
      p_data||jsonb_build_object(
        'assignmentMode',case when v_mode='EXTRA' then 'EXTRA' else 'OPTIONAL' end,
        'minimumCount',0,'shiftObligation',false,'shiftPeriod',null
      )
    else p_data end
  );
end;
$$;

revoke all on function public.matrix_v2_admin_save_before_mx_k10(text,uuid,jsonb)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_v2_admin_save_alpha16(text,uuid,jsonb)
  from public,anon,authenticated;
grant execute on function public.matrix_v2_admin_save_alpha16(text,uuid,jsonb)
  to authenticated,service_role;

comment on function public.matrix_v2_admin_save_alpha16(text,uuid,jsonb) is
  'MX-K10: role-duty is competency-only. Use exact shift staffing for every required count.';

create or replace function solver_private.mx_k10_legacy_role_duty_payload_v1(
  p_row jsonb
) returns boolean
language sql
immutable
set search_path = ''
as $$
  select
    upper(coalesce(nullif(trim(p_row->>'assignmentMode'),''),'OPTIONAL'))
      not in ('OPTIONAL','EXTRA')
    or coalesce(nullif(trim(p_row->>'minimumCount'),''),'0') !~ '^\d+$'
    or case
      when coalesce(nullif(trim(p_row->>'minimumCount'),''),'0') ~ '^\d+$'
      then coalesce(nullif(trim(p_row->>'minimumCount'),''),'0')::integer
      else 1
    end<>0
    or lower(coalesce(p_row->>'shiftObligation','false')) in ('true','t','1','yes')
    or nullif(trim(p_row->>'shiftPeriod'),'') is not null;
$$;

revoke all on function solver_private.mx_k10_legacy_role_duty_payload_v1(jsonb)
  from public,anon,authenticated;

alter function public.matrix_v2_import_preview_alpha16(jsonb)
  rename to matrix_v2_import_preview_before_mx_k10;

create function public.matrix_v2_import_preview_alpha16(
  p_payload jsonb
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
  v_legacy_errors jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  v_result:=public.matrix_v2_import_preview_before_mx_k10(p_payload);
  select coalesce(jsonb_agg(jsonb_build_object(
    'sheet','ROLE-OBOWIĄZKI','row',legacy.ordinality+1,
    'column','Znaczenie / Minimum / Pora',
    'code','LEGACY_PERIOD_DEMAND_REJECTED',
    'message','Stary szeroki wymóg rola–obowiązek jest wycofany. W arkuszu Obsada wskaż dokładny Kod zmiany, Kod roli, opcjonalny Kod obowiązku i Liczbę osób.'
  ) order by legacy.ordinality),'[]'::jsonb)
  into v_legacy_errors
  from jsonb_array_elements(coalesce(p_payload->'roleDuties','[]'::jsonb))
    with ordinality legacy(value,ordinality)
  where solver_private.mx_k10_legacy_role_duty_payload_v1(legacy.value);

  if jsonb_array_length(v_legacy_errors)>0 then
    v_result:=jsonb_set(v_result,'{valid}','false'::jsonb,true);
    v_result:=jsonb_set(
      v_result,'{errors}',coalesce(v_result->'errors','[]'::jsonb)||v_legacy_errors,true
    );
  end if;
  return v_result;
end;
$$;

revoke all on function public.matrix_v2_import_preview_before_mx_k10(jsonb)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_v2_import_preview_alpha16(jsonb)
  from public,anon,authenticated;
grant execute on function public.matrix_v2_import_preview_alpha16(jsonb)
  to authenticated,service_role;

alter function public.matrix_v2_import_apply_alpha16(jsonb)
  rename to matrix_v2_import_apply_before_mx_k10;

create function public.matrix_v2_import_apply_alpha16(
  p_payload jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_legacy_rows text;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  select string_agg((legacy.ordinality+1)::text,',' order by legacy.ordinality)
  into v_legacy_rows
  from jsonb_array_elements(coalesce(p_payload->'roleDuties','[]'::jsonb))
    with ordinality legacy(value,ordinality)
  where solver_private.mx_k10_legacy_role_duty_payload_v1(legacy.value);
  if v_legacy_rows is not null then
    raise exception 'LEGACY_PERIOD_DEMAND_REJECTED rows=%: move required counts to exact shifts in OBSADA',v_legacy_rows;
  end if;
  return public.matrix_v2_import_apply_before_mx_k10(p_payload);
end;
$$;

revoke all on function public.matrix_v2_import_apply_before_mx_k10(jsonb)
  from public,anon,authenticated,service_role;
revoke all on function public.matrix_v2_import_apply_alpha16(jsonb)
  from public,anon,authenticated;
grant execute on function public.matrix_v2_import_apply_alpha16(jsonb)
  to authenticated,service_role;

comment on function public.matrix_v2_import_preview_alpha16(jsonb) is
  'MX-K10: previews reject broad role-duty periods/minimums and direct the owner to exact shift staffing.';
comment on function public.matrix_v2_import_apply_alpha16(jsonb) is
  'MX-K10: import apply is fail-closed for retired broad role-duty demand fields.';

-- Runtime demand now comes only from matrix_staffing_rules_v2 rows whose
-- shift_template_id is exact.  shift_period remains an internal preference /
-- diagnostics attribute of a shift; it is never a demand join key.
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
  select scenario.id,scenario.parent_scenario_id,scenario.valid_from,
    scenario.valid_to,0 depth
  from public.matrix_scenarios_v2 scenario
  where scenario.id=p_scenario_id
    and scenario.matrix_version_id=p_matrix_version_id
  union all
  select parent.id,parent.parent_scenario_id,parent.valid_from,parent.valid_to,
    chain.depth+1
  from public.matrix_scenarios_v2 parent
  join scenario_chain chain on chain.parent_scenario_id=parent.id
  where parent.matrix_version_id=p_matrix_version_id and chain.depth<32
), rule_keys as (
  select distinct staffing.shift_template_id,staffing.role_id,staffing.duty_id
  from public.matrix_staffing_rules_v2 staffing
  join scenario_chain chain on chain.id=staffing.scenario_id
  where staffing.matrix_version_id=p_matrix_version_id and staffing.active
    and (p_scope_role_id is null or staffing.role_id=p_scope_role_id)
), occurrences as (
  select day_value::date work_date,shift_template.id shift_template_id,
    shift_template.location_id,shift_template.starts_at local_start,
    shift_template.ends_at local_end,shift_template.ends_next_day,location.timezone
  from public.matrix_shift_templates_v2 shift_template
  join public.matrix_locations_v2 location
    on location.id=shift_template.location_id
    and location.matrix_version_id=shift_template.matrix_version_id
  cross join lateral generate_series(
    date_trunc('month',p_month)::date,
    (date_trunc('month',p_month)+interval '1 month - 1 day')::date,
    interval '1 day'
  ) day_value
  where shift_template.matrix_version_id=p_matrix_version_id
    and shift_template.active and location.active
    and extract(isodow from day_value)::smallint=any(shift_template.day_mask)
), evaluated as (
  select occurrence.work_date,occurrence.shift_template_id,
    occurrence.location_id,key.role_id,key.duty_id,
    solver_private.apply_integer_operations_v2(coalesce((
      select jsonb_agg(jsonb_build_object(
        'operation',staffing.operation,'value',staffing.count_value,
        'basisPoints',staffing.multiplier_basis_points
      ) order by chain.depth desc)
      from public.matrix_staffing_rules_v2 staffing
      join scenario_chain chain on chain.id=staffing.scenario_id
      where staffing.matrix_version_id=p_matrix_version_id and staffing.active
        and staffing.shift_template_id=key.shift_template_id
        and staffing.role_id=key.role_id
        and staffing.duty_id is not distinct from key.duty_id
        and (chain.valid_from is null or chain.valid_from<=occurrence.work_date)
        and (chain.valid_to is null or chain.valid_to>=occurrence.work_date)
    ),'[]'::jsonb))::integer required_count,
    ((occurrence.work_date+occurrence.local_start) at time zone occurrence.timezone) starts_at,
    (((occurrence.work_date+case when occurrence.ends_next_day then 1 else 0 end)
      +occurrence.local_end) at time zone occurrence.timezone) ends_at
  from occurrences occurrence
  join rule_keys key on key.shift_template_id=occurrence.shift_template_id
), exact_demand as (
  select evaluated.work_date,evaluated.shift_template_id,evaluated.location_id,
    evaluated.role_id,
    case when evaluated.duty_id is null then '{}'::uuid[]
      else array[evaluated.duty_id]::uuid[] end duty_ids,
    sum(evaluated.required_count)::integer required_count,
    min(evaluated.starts_at) starts_at,max(evaluated.ends_at) ends_at
  from evaluated
  where evaluated.required_count>0 and evaluated.ends_at>evaluated.starts_at
  group by evaluated.work_date,evaluated.shift_template_id,
    evaluated.location_id,evaluated.role_id,evaluated.duty_id
)
select public.matrix_v2_stable_uuid(
    'DEMAND_V2:'||p_scenario_id::text||':'||demand_row.work_date::text||':'||
    demand_row.shift_template_id::text||':'||demand_row.role_id::text||':'||
    coalesce(array_to_string(demand_row.duty_ids,','),'-')
  ),demand_row.work_date,demand_row.shift_template_id,demand_row.location_id,
  demand_row.role_id,demand_row.duty_ids,demand_row.required_count,
  demand_row.starts_at,demand_row.ends_at,
  greatest(0,round(extract(epoch from (
    demand_row.ends_at-demand_row.starts_at
  ))/60)::integer)
from exact_demand demand_row
order by demand_row.starts_at,demand_row.location_id,
  demand_row.role_id,demand_row.duty_ids;
$$;

revoke all on function solver_private.resolved_demand_v2(date,uuid,uuid,uuid)
  from public,anon,authenticated;
grant execute on function solver_private.resolved_demand_v2(date,uuid,uuid,uuid)
  to service_role;

comment on function solver_private.resolved_demand_v2(date,uuid,uuid,uuid) is
  'MX-K10: resolves demand exclusively from exact matrix_staffing_rules_v2.shift_template_id keys; no broad shift-period role-duty branch exists.';

notify pgrst,'reload schema';
