-- UAT follow-up: bulk access management, reversible draft lifecycle,
-- shared cross-location staffing and non-blocking normal solver mode.

create or replace function public.application_access_bulk_apply_uat_v1(p_rows jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path=''
as $$
declare
  v_row jsonb;
  v_count integer:=0;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if jsonb_typeof(p_rows)<>'array' then raise exception 'ACCESS_ROWS_MUST_BE_ARRAY'; end if;
  if jsonb_array_length(p_rows)<1 or jsonb_array_length(p_rows)>1000 then
    raise exception 'ACCESS_ROWS_COUNT_OUT_OF_RANGE';
  end if;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    perform public.application_access_save_uat_v1(
      v_row->>'email',
      v_row->>'appRole',
      nullif(v_row->>'roleId','')::uuid,
      nullif(v_row->>'locationId','')::uuid,
      coalesce((v_row->>'active')::boolean,true)
    );
    v_count:=v_count+1;
  end loop;
  return jsonb_build_object('applied',v_count);
end;
$$;
revoke all on function public.application_access_bulk_apply_uat_v1(jsonb) from public,anon;
grant execute on function public.application_access_bulk_apply_uat_v1(jsonb) to authenticated;

create or replace function public.matrix_v2_discard_draft_uat_v1(p_matrix_version_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path=''
as $$
declare
  v_draft public.matrix_versions%rowtype;
  v_active uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  select * into v_draft from public.matrix_versions
    where id=p_matrix_version_id for update;
  if v_draft.id is null then raise exception 'MATRIX_VERSION_NOT_FOUND'; end if;
  if v_draft.status<>'DRAFT' then raise exception 'ONLY_DRAFT_CAN_BE_DISCARDED'; end if;
  if exists(select 1 from public.optimization_runs_v2 r where r.matrix_version_id=v_draft.id) then
    raise exception 'DRAFT_ALREADY_USED_BY_GENERATOR';
  end if;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,old_data)
  values(auth.uid(),'matrix_version',v_draft.id::text,'DISCARD_DRAFT',
    jsonb_build_object('version',v_draft.version,'name',v_draft.name));
  delete from public.matrix_versions where id=v_draft.id;
  select id into v_active from public.matrix_versions
    where status='ACTIVE' order by effective_from desc nulls last,version desc limit 1;
  return jsonb_build_object('discarded',v_draft.id,'activeMatrixVersionId',v_active);
end;
$$;
revoke all on function public.matrix_v2_discard_draft_uat_v1(uuid) from public,anon;
grant execute on function public.matrix_v2_discard_draft_uat_v1(uuid) to authenticated;

create or replace function public.matrix_v2_shift_staffing_save_uat_v4(
  p_scenario_id uuid,
  p_shift_template_ids uuid[],
  p_role_id uuid,
  p_duty_id uuid,
  p_operation text,
  p_count_value integer,
  p_multiplier_basis_points integer,
  p_active boolean,
  p_source_metadata jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
volatile
security definer
set search_path=''
as $$
declare
  v_result jsonb;
  v_matrix uuid;
  v_mode text:=upper(coalesce(p_source_metadata->>'coverageMode','INDEPENDENT'));
  v_group text:=trim(coalesce(p_source_metadata->>'sharedCoverageGroup',''));
begin
  if jsonb_typeof(coalesce(p_source_metadata,'{}'::jsonb))<>'object' then
    raise exception 'SOURCE_METADATA_MUST_BE_OBJECT';
  end if;
  if v_mode not in ('INDEPENDENT','SHARED_ROTATION') then
    raise exception 'INVALID_COVERAGE_MODE';
  end if;
  if v_mode='SHARED_ROTATION' and v_group='' then
    raise exception 'SHARED_COVERAGE_GROUP_REQUIRED';
  end if;
  if v_mode='SHARED_ROTATION' and (
    select count(distinct (st.starts_at,st.ends_at,st.ends_next_day))
    from public.matrix_shift_templates_v2 st
    where st.id=any(coalesce(p_shift_template_ids,array[]::uuid[]))
  )<>1 then
    raise exception 'SHARED_COVERAGE_REQUIRES_MATCHING_HOURS';
  end if;

  v_result:=public.matrix_v2_shift_staffing_save_uat_v3(
    p_scenario_id,p_shift_template_ids,p_role_id,p_duty_id,p_operation,
    p_count_value,p_multiplier_basis_points,p_active
  );
  v_matrix:=(v_result->>'matrixVersionId')::uuid;

  update public.matrix_staffing_rules_v2 rule set
    source_metadata=coalesce(p_source_metadata,'{}'::jsonb)
      ||jsonb_build_object('source','UNIFIED_SHIFT_STAFFING_UI'),
    updated_at=now()
  from public.matrix_scenarios_v2 target_scenario,
       public.matrix_scenarios_v2 source_scenario,
       public.matrix_roles_v2 target_role,
       public.matrix_roles_v2 source_role,
       public.matrix_shift_templates_v2 target_shift,
       public.matrix_shift_templates_v2 source_shift
  where source_scenario.id=p_scenario_id
    and target_scenario.matrix_version_id=v_matrix
    and target_scenario.logical_id=source_scenario.logical_id
    and source_role.id=p_role_id
    and target_role.matrix_version_id=v_matrix
    and target_role.logical_id=source_role.logical_id
    and source_shift.id=any(p_shift_template_ids)
    and target_shift.matrix_version_id=v_matrix
    and target_shift.logical_id=source_shift.logical_id
    and rule.matrix_version_id=v_matrix
    and rule.scenario_id=target_scenario.id
    and rule.role_id=target_role.id
    and rule.shift_template_id=target_shift.id
    and (
      (p_duty_id is null and rule.duty_id is null)
      or rule.duty_id=(select target_duty.id
        from public.matrix_duties_v2 source_duty
        join public.matrix_duties_v2 target_duty
          on target_duty.matrix_version_id=v_matrix
         and target_duty.logical_id=source_duty.logical_id
        where source_duty.id=p_duty_id)
    );

  return v_result||jsonb_build_object('coverageMode',v_mode,'sharedCoverageGroup',nullif(v_group,''));
end;
$$;
revoke all on function public.matrix_v2_shift_staffing_save_uat_v4(
  uuid,uuid[],uuid,uuid,text,integer,integer,boolean,jsonb
) from public,anon;
grant execute on function public.matrix_v2_shift_staffing_save_uat_v4(
  uuid,uuid[],uuid,uuid,text,integer,integer,boolean,jsonb
) to authenticated;

-- Resolve ordinary demand exactly as before, then collapse explicitly tagged
-- same-time rules to one rotating cross-location seat. The representative
-- shift remains stable for publication; source metadata preserves the group.
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
  join public.matrix_locations_v2 l on l.id=st.location_id and l.matrix_version_id=st.matrix_version_id
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
    (((o.work_date+case when o.ends_next_day then 1 else 0 end)+o.local_end) at time zone o.timezone) ends_at
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
  from evaluated e where e.duty_id is not null and e.required_count>0 and e.ends_at>e.starts_at
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
    and ec.location_id=ro.location_id and ec.role_id=ro.role_id and ec.duty_id=rd.duty_id
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
  from evaluated e where e.duty_id is not null and e.required_count>0 and e.ends_at>e.starts_at
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
    sum(e.required_count)::integer required_count,min(e.starts_at) starts_at,max(e.ends_at) ends_at
  from expanded_raw e
  group by e.work_date,e.shift_template_id,e.location_id,e.role_id,e.duty_ids
), resolved_raw as (
  select public.matrix_v2_stable_uuid(
      'DEMAND_V2:'||p_scenario_id::text||':'||e.work_date::text||':'||
      e.shift_template_id::text||':'||e.role_id::text||':'||coalesce(array_to_string(e.duty_ids,','),'-')
    ) demand_id,e.work_date,e.shift_template_id,e.location_id,e.role_id,e.duty_ids,
    e.required_count,e.starts_at,e.ends_at,
    greatest(0,round(extract(epoch from (e.ends_at-e.starts_at))/60)::integer) duration_minutes
  from expanded e cross join guard g
  where solver_private.assert_configuration_v2(g.valid,'ROLE_DUTY_MINIMUM_EXCEEDS_STAFFING')
), tagged as (
  select r.*,coalesce((
    select nullif(trim(sr.source_metadata->>'sharedCoverageGroup'),'')
    from public.matrix_staffing_rules_v2 sr
    join scenario_chain c on c.id=sr.scenario_id
    where sr.matrix_version_id=p_matrix_version_id and sr.active
      and sr.shift_template_id=r.shift_template_id and sr.role_id=r.role_id
      and sr.duty_id is not distinct from case when cardinality(r.duty_ids)=1 then r.duty_ids[1] else null end
      and upper(coalesce(sr.source_metadata->>'coverageMode',''))='SHARED_ROTATION'
      and (c.valid_from is null or c.valid_from<=r.work_date)
      and (c.valid_to is null or c.valid_to>=r.work_date)
    order by c.depth asc limit 1
  ),'') shared_group
  from resolved_raw r
), shared as (
  select public.matrix_v2_stable_uuid(
      'SHARED_DEMAND_V2:'||p_scenario_id::text||':'||t.work_date::text||':'||
      t.role_id::text||':'||coalesce(array_to_string(t.duty_ids,','),'-')||':'||t.shared_group
    ) demand_id,t.work_date,
    (array_agg(t.shift_template_id order by t.shift_template_id::text))[1] shift_template_id,
    (array_agg(t.location_id order by t.shift_template_id::text))[1] location_id,
    t.role_id,t.duty_ids,max(t.required_count)::integer required_count,
    min(t.starts_at) starts_at,max(t.ends_at) ends_at,max(t.duration_minutes)::integer duration_minutes
  from tagged t where t.shared_group<>''
  group by t.work_date,t.role_id,t.duty_ids,t.starts_at,t.ends_at,t.shared_group
)
select t.demand_id,t.work_date,t.shift_template_id,t.location_id,t.role_id,t.duty_ids,
  t.required_count,t.starts_at,t.ends_at,t.duration_minutes
from tagged t where t.shared_group=''
union all
select s.demand_id,s.work_date,s.shift_template_id,s.location_id,s.role_id,s.duty_ids,
  s.required_count,s.starts_at,s.ends_at,s.duration_minutes
from shared s
order by starts_at,location_id,role_id,duty_ids;
$$;

comment on function solver_private.resolved_demand_v2(date,uuid,uuid,uuid) is
  'Resolves monthly demand and collapses explicitly tagged same-time cross-location staffing into one shared rotating seat.';

