-- GRAFIK PRO 3.0 -- Alpha 16 workforce, Matrix and preference contracts.
--
-- This migration is additive. Historical Alpha 15 migrations stay in the
-- repository because Supabase migration history is immutable. Runtime reads
-- and writes are moved to Matrix/optimizer v2 by the application release.

alter table public.matrix_shift_templates_v2
  add column if not exists shift_period text;

-- Published Matrix rows are immutable to application traffic. A schema
-- migration may backfill only this newly introduced derived column; the
-- guard is restored before any new trigger or RPC is exposed.
alter table public.matrix_shift_templates_v2
  disable trigger matrix_v2_immutable_guard;
update public.matrix_shift_templates_v2 shift_row
set shift_period=case
  when shift_row.ends_next_day or shift_row.starts_at>=time '17:00' then 'EVENING'
  when shift_row.starts_at<time '11:00' then 'MORNING'
  else 'MIDDLE'
end
where shift_row.shift_period is null
  or shift_row.shift_period not in ('MORNING','MIDDLE','EVENING');
alter table public.matrix_shift_templates_v2
  enable trigger matrix_v2_immutable_guard;

alter table public.matrix_shift_templates_v2
  alter column shift_period set default 'MIDDLE',
  alter column shift_period set not null;

alter table public.matrix_shift_templates_v2
  drop constraint if exists matrix_shift_templates_v2_shift_period_check;
alter table public.matrix_shift_templates_v2
  add constraint matrix_shift_templates_v2_shift_period_check
  check (shift_period in ('MORNING','MIDDLE','EVENING'));

alter table public.matrix_role_duties_v2
  add column if not exists shift_obligation boolean not null default false,
  add column if not exists shift_period text;

alter table public.matrix_role_duties_v2
  drop constraint if exists matrix_role_duties_v2_shift_period_check;
alter table public.matrix_role_duties_v2
  add constraint matrix_role_duties_v2_shift_period_check check (
    (not shift_obligation and shift_period is null)
    or (shift_obligation and shift_period in ('MORNING','MIDDLE','EVENING'))
  );

create or replace function solver_private.alpha16_shift_period_default_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.shift_period:=coalesce(nullif(upper(trim(new.shift_period)),''),case
    when new.ends_next_day or new.starts_at>=time '17:00' then 'EVENING'
    when new.starts_at<time '11:00' then 'MORNING'
    else 'MIDDLE'
  end);
  return new;
end;
$$;

drop trigger if exists matrix_shift_templates_v2_alpha16_period
  on public.matrix_shift_templates_v2;
create trigger matrix_shift_templates_v2_alpha16_period
before insert or update of starts_at,ends_at,ends_next_day,shift_period
on public.matrix_shift_templates_v2
for each row execute function solver_private.alpha16_shift_period_default_v2();

-- matrix_create_draft_v2 predates the two role-duty metadata columns. This
-- trigger carries the values from the base Matrix without rewriting the old,
-- audited migration body.
create or replace function solver_private.alpha16_role_duty_defaults_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_base uuid;
begin
  new.shift_obligation:=coalesce(new.shift_obligation,false);
  new.shift_period:=nullif(upper(trim(new.shift_period)),'');
  select mv.base_version_id into v_base
  from public.matrix_versions mv where mv.id=new.matrix_version_id;
  if v_base is not null and not new.shift_obligation and new.shift_period is null then
    select source.shift_obligation,source.shift_period
    into new.shift_obligation,new.shift_period
    from public.matrix_role_duties_v2 source
    join public.matrix_roles_v2 source_role on source_role.id=source.role_id
    join public.matrix_roles_v2 target_role
      on target_role.id=new.role_id
      and target_role.logical_id=source_role.logical_id
    join public.matrix_duties_v2 source_duty on source_duty.id=source.duty_id
    join public.matrix_duties_v2 target_duty
      on target_duty.id=new.duty_id
      and target_duty.logical_id=source_duty.logical_id
    where source.matrix_version_id=v_base
    limit 1;
  end if;
  -- SELECT INTO clears its targets when a brand-new role/duty pair has no
  -- counterpart in the base Matrix. Keep the column's non-null invariant in
  -- that case instead of leaking NULL past the trigger.
  new.shift_obligation:=coalesce(new.shift_obligation,false);
  if not coalesce(new.shift_obligation,false) then new.shift_period:=null; end if;
  return new;
end;
$$;

drop trigger if exists matrix_role_duties_v2_alpha16_defaults
  on public.matrix_role_duties_v2;
create trigger matrix_role_duties_v2_alpha16_defaults
before insert or update of shift_obligation,shift_period
on public.matrix_role_duties_v2
for each row execute function solver_private.alpha16_role_duty_defaults_v2();

create or replace function solver_private.alpha16_preference_level_v2(
  p_employee_id uuid,
  p_matrix_version_id uuid,
  p_month date,
  p_period text
) returns text
language sql
stable
security definer
set search_path = ''
as $$
  select upper(coalesce(preference.preference_value->>'level','NEUTRAL'))
  from public.employee_preferences preference
  where preference.employee_id=p_employee_id
    and preference.status='ACTIVE'
    and preference.preference_type='PREFERRED_SHIFT'
    and upper(coalesce(
      preference.preference_value->>'period',
      preference.preference_value->>'shiftPeriod'
    ))=upper(p_period)
    and preference.valid_from<date_trunc('month',p_month)::date+interval '1 month'
    and preference.valid_to>=date_trunc('month',p_month)::date
    and (
      preference.source<>'MANAGER'
      or coalesce(preference.preference_value->>'matrixVersionId','')
        =p_matrix_version_id::text
    )
  order by case preference.source when 'MANAGER' then 0 else 1 end,
    preference.created_at desc,preference.id desc
  limit 1;
$$;

create or replace function solver_private.alpha16_shift_rules_v2(
  p_employee_id uuid,
  p_matrix_version_id uuid,
  p_month date
) returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with periods(period) as (
    values ('MORNING'::text),('MIDDLE'::text),('EVENING'::text)
  ), effective as (
    select p.period,coalesce(
      solver_private.alpha16_preference_level_v2(
        p_employee_id,p_matrix_version_id,p_month,p.period
      ),
      case
        when profile.only_morning and p.period<>'MORNING' then 'BLOCKED'
        when profile.only_evening and p.period<>'EVENING' then 'BLOCKED'
        when upper(coalesce(profile.preferred_shift_code,''))=p.period then 'PREFERRED'
        else 'NEUTRAL'
      end
    ) level
    from periods p
    join public.matrix_employee_profiles_v2 profile
      on profile.matrix_version_id=p_matrix_version_id
      and profile.employee_id=p_employee_id
  )
  select jsonb_build_object(
    'periods',coalesce(jsonb_object_agg(period,level),'{}'::jsonb),
    'preferredShiftTemplateIds',coalesce((
      select jsonb_agg(template.id::text order by template.id::text)
      from public.matrix_shift_templates_v2 template
      join effective rule on rule.period=template.shift_period
      where template.matrix_version_id=p_matrix_version_id and template.active
        and rule.level='PREFERRED'
    ),'[]'::jsonb),
    'avoidedShiftTemplateIds',coalesce((
      select jsonb_agg(template.id::text order by template.id::text)
      from public.matrix_shift_templates_v2 template
      join effective rule on rule.period=template.shift_period
      where template.matrix_version_id=p_matrix_version_id and template.active
        and rule.level='AVOIDED'
    ),'[]'::jsonb),
    'blockedShiftTemplateIds',coalesce((
      select jsonb_agg(template.id::text order by template.id::text)
      from public.matrix_shift_templates_v2 template
      join effective rule on rule.period=template.shift_period
      where template.matrix_version_id=p_matrix_version_id and template.active
        and rule.level='BLOCKED'
    ),'[]'::jsonb)
  ) from effective limit 1;
$$;

-- Preserve the final pre-Alpha-16 builder and enrich its immutable payload.
-- This avoids editing historical migrations while keeping all prior guards.
alter function solver_private.build_snapshot_payload_v2(
  uuid,date,uuid,uuid,text,uuid
) rename to build_snapshot_payload_before_alpha16_v2;

create or replace function solver_private.build_snapshot_payload_v2(
  p_run_id uuid,
  p_month date,
  p_matrix_version_id uuid,
  p_scenario_id uuid,
  p_scope_type text,
  p_scope_role_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_snapshot jsonb;
  v_employees jsonb:='[]'::jsonb;
  v_templates jsonb:='[]'::jsonb;
  v_employee jsonb;
  v_template jsonb;
  v_rules jsonb;
begin
  v_snapshot:=solver_private.build_snapshot_payload_before_alpha16_v2(
    p_run_id,p_month,p_matrix_version_id,p_scenario_id,p_scope_type,p_scope_role_id
  );

  for v_template in
    select template.value
    from jsonb_array_elements(coalesce(v_snapshot->'shiftTemplates','[]'::jsonb)) template
  loop
    v_template:=v_template||jsonb_build_object(
      'shiftPeriod',(select row.shift_period
        from public.matrix_shift_templates_v2 row
        where row.id=(v_template->>'id')::uuid)
    );
    v_templates:=v_templates||jsonb_build_array(v_template);
  end loop;

  for v_employee in
    select employee.value
    from jsonb_array_elements(coalesce(v_snapshot->'employees','[]'::jsonb)) employee
  loop
    v_rules:=solver_private.alpha16_shift_rules_v2(
      (v_employee->>'id')::uuid,p_matrix_version_id,p_month
    );
    v_employee:=(v_employee-'preferredShiftTemplateIds'-'homeLocationIds')
      ||jsonb_build_object(
        'preferredShiftTemplateIds',coalesce(v_rules->'preferredShiftTemplateIds','[]'::jsonb),
        'avoidedShiftTemplateIds',coalesce(v_rules->'avoidedShiftTemplateIds','[]'::jsonb),
        'blockedShiftTemplateIds',coalesce(v_rules->'blockedShiftTemplateIds','[]'::jsonb),
        'shiftPeriodPreferences',coalesce(v_rules->'periods','{}'::jsonb),
        -- Work in every standard-allowed location belongs to the ordinary
        -- contract limit. A former home marker no longer creates a penalty.
        'homeLocationIds','[]'::jsonb
      );
    v_employees:=v_employees||jsonb_build_array(v_employee);
  end loop;

  v_snapshot:=jsonb_set(v_snapshot,'{shiftTemplates}',v_templates,true);
  v_snapshot:=jsonb_set(v_snapshot,'{employees}',v_employees,true);
  return v_snapshot;
end;
$$;

-- A shift-scoped duty applies only to the selected broad shift period. A
-- non-scoped REQUIRED duty keeps the previous all-shifts behaviour.
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
    and (not rd.shift_obligation or rd.shift_period=ro.shift_period)
  left join explicit_counts ec
    on ec.work_date=ro.work_date and ec.shift_template_id=ro.shift_template_id
    and ec.location_id=ro.location_id and ec.role_id=ro.role_id
    and ec.duty_id=rd.duty_id
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

create or replace function public.matrix_v2_next_employee_no_v2()
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_number integer:=1;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE')) then raise exception 'FORBIDDEN'; end if;
  while exists(
    select 1 from public.employees employee
    where upper(employee.employee_no)=upper('GP-'||lpad(v_number::text,3,'0'))
  ) loop
    v_number:=v_number+1;
  end loop;
  return 'GP-'||lpad(v_number::text,3,'0');
end;
$$;

create or replace function public.matrix_v2_employee_directory_alpha16(
  p_month date default current_date
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_directory jsonb;
  v_matrix uuid;
  v_month date:=date_trunc('month',coalesce(p_month,current_date))::date;
  v_employees jsonb;
begin
  v_directory:=public.matrix_v2_employee_directory_v2();
  v_matrix:=(v_directory->>'matrixVersionId')::uuid;
  select coalesce(jsonb_agg(
    employee.value || jsonb_build_object(
      'locationIds',coalesce((select jsonb_agg(location_grant.location_id::text
        order by location_grant.location_id::text)
        from public.matrix_employee_locations_v2 location_grant
        where location_grant.matrix_version_id=v_matrix
          and location_grant.employee_id=(employee.value->>'id')::uuid
          and location_grant.standard_allowed and location_grant.active
      ),'[]'::jsonb),
      'shiftPeriodPreferences',coalesce((select jsonb_object_agg(
        upper(preference.preference_value->>'period'),
        upper(preference.preference_value->>'level')
      ) from public.employee_preferences preference
        where preference.employee_id=(employee.value->>'id')::uuid
          and preference.preference_type='PREFERRED_SHIFT'
          and preference.source='MANAGER' and preference.status='ACTIVE'
          and preference.preference_value->>'matrixVersionId'=v_matrix::text
          and preference.valid_from<v_month+interval '1 month'
          and preference.valid_to>=v_month
      ),'{}'::jsonb)
    ) order by employee.ordinality
  ),'[]'::jsonb) into v_employees
  from jsonb_array_elements(coalesce(v_directory->'employees','[]'::jsonb))
    with ordinality employee(value,ordinality);
  return jsonb_set(v_directory,'{employees}',v_employees,true);
end;
$$;

create or replace function public.matrix_v2_employee_save_alpha16(
  p_employee_id uuid default null,
  p_data jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_matrix uuid;
  v_employee uuid:=p_employee_id;
  v_result jsonb;
  v_payload jsonb:=coalesce(p_data,'{}'::jsonb);
  v_employee_no text;
  v_location uuid;
  v_period text;
  v_level text;
  v_month date:=date_trunc('month',coalesce(
    nullif(v_payload->>'preferenceMonth','')::date,current_date
  ))::date;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE')) then raise exception 'FORBIDDEN'; end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  select mv.id into v_matrix from public.matrix_versions mv
  where mv.status='DRAFT' and mv.schema_version>=2
  order by mv.version desc limit 1 for update;
  if v_matrix is null then raise exception 'NO_MATRIX_V2_DRAFT'; end if;

  if v_employee is null then
    v_employee_no:=public.matrix_v2_next_employee_no_v2();
    v_payload:=jsonb_set(v_payload,'{employeeNo}',to_jsonb(v_employee_no),true);
  else
    select profile.employee_no into v_employee_no
    from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=v_matrix and profile.employee_id=v_employee;
    v_payload:=jsonb_set(v_payload,'{employeeNo}',to_jsonb(v_employee_no),true);
  end if;
  -- The compatibility field is explicitly cleared. Standard locations below
  -- are the only location source used by the solver.
  v_payload:=jsonb_set(v_payload,'{homeLocationId}','null'::jsonb,true);
  v_result:=public.matrix_v2_employee_save_v2(v_employee,v_payload);
  v_employee:=(v_result->>'id')::uuid;

  if v_payload ? 'locationIds' then
    if jsonb_typeof(v_payload->'locationIds')<>'array'
      or jsonb_array_length(v_payload->'locationIds')=0 then
      raise exception 'ACTIVE_EMPLOYEE_REQUIRES_STANDARD_LOCATION';
    end if;
    update public.matrix_employee_locations_v2 location_grant
    set standard_allowed=false,home_location=false,active=false
    where location_grant.matrix_version_id=v_matrix
      and location_grant.employee_id=v_employee;
    for v_location in
      select distinct item.value::text::uuid
      from jsonb_array_elements_text(v_payload->'locationIds') item(value)
    loop
      if not exists(select 1 from public.matrix_locations_v2 location_row
        where location_row.id=v_location and location_row.matrix_version_id=v_matrix
          and location_row.active) then raise exception 'LOCATION_NOT_IN_MATRIX_V2'; end if;
      insert into public.matrix_employee_locations_v2(
        matrix_version_id,employee_id,location_id,standard_allowed,
        overtime_allowed,home_location,active
      ) values(v_matrix,v_employee,v_location,true,false,false,true)
      on conflict(matrix_version_id,employee_id,location_id) do update set
        standard_allowed=true,home_location=false,active=true;
    end loop;
  end if;

  if v_payload ? 'shiftPeriodPreferences' then
    if jsonb_typeof(v_payload->'shiftPeriodPreferences')<>'object' then
      raise exception 'INVALID_SHIFT_PERIOD_PREFERENCES';
    end if;
    update public.employee_preferences preference
    set status='CANCELLED'
    where preference.employee_id=v_employee
      and preference.preference_type='PREFERRED_SHIFT'
      and preference.source='MANAGER'
      and coalesce(preference.preference_value->>'matrixVersionId','')=v_matrix::text
      and preference.status='ACTIVE';
    foreach v_period in array array['MORNING','MIDDLE','EVENING'] loop
      v_level:=upper(coalesce(
        v_payload->'shiftPeriodPreferences'->>v_period,'INHERIT'
      ));
      if v_level not in ('INHERIT','PREFERRED','NEUTRAL','AVOIDED','BLOCKED') then
        raise exception 'INVALID_SHIFT_PREFERENCE_LEVEL';
      end if;
      if v_level<>'INHERIT' then
        insert into public.employee_preferences(
          employee_id,valid_from,valid_to,preference_type,preference_value,
          source,editable_by_employee,status
        ) values(
          v_employee,v_month,(v_month+interval '1 month - 1 day')::date,
          'PREFERRED_SHIFT',jsonb_build_object(
            'period',v_period,'level',v_level,'matrixVersionId',v_matrix
          ),'MANAGER',false,'ACTIVE'
        );
      end if;
    end loop;
    update public.matrix_employee_profiles_v2 profile set
      only_morning=false,only_evening=false,preferred_shift_code=null,
      updated_by=auth.uid(),updated_at=now()
    where profile.matrix_version_id=v_matrix and profile.employee_id=v_employee;
  end if;

  return v_result||jsonb_build_object('employeeNo',v_employee_no);
end;
$$;

create or replace function public.matrix_v2_admin_save_alpha16(
  p_kind text,p_id uuid,p_data jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kind text:=upper(trim(p_kind));
  v_result jsonb;
  v_id uuid;
  v_period text;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  v_result:=public.matrix_v2_admin_save(v_kind,p_id,p_data);
  v_id:=(v_result->>'id')::uuid;
  if v_kind='SHIFT' then
    v_period:=upper(coalesce(p_data->>'shiftPeriod','MIDDLE'));
    if v_period not in ('MORNING','MIDDLE','EVENING') then
      raise exception 'INVALID_SHIFT_PERIOD';
    end if;
    update public.matrix_shift_templates_v2 set shift_period=v_period,
      updated_at=now() where id=v_id;
  elsif v_kind='ROLE_DUTY' then
    v_period:=nullif(upper(p_data->>'shiftPeriod'),'');
    if coalesce((p_data->>'shiftObligation')::boolean,false)
      and v_period not in ('MORNING','MIDDLE','EVENING') then
      raise exception 'SHIFT_PERIOD_REQUIRED';
    end if;
    update public.matrix_role_duties_v2 set
      shift_obligation=coalesce((p_data->>'shiftObligation')::boolean,false),
      shift_period=case when coalesce((p_data->>'shiftObligation')::boolean,false)
        then v_period else null end
    where id=v_id;
  end if;
  return v_result;
end;
$$;

create or replace function public.employee_shift_preferences_self_v2(p_month date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_employee uuid;
  v_matrix uuid;
  v_month date:=date_trunc('month',p_month)::date;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  select employee.id into v_employee from public.employees employee
  where employee.auth_user_id=auth.uid() and employee.active
    and employee.archived_at is null order by employee.id limit 1;
  if v_employee is null then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  select matrix.id into v_matrix from public.matrix_versions matrix
  where matrix.status in ('ACTIVE','ARCHIVED') and matrix.schema_version>=2
    and matrix.effective_from<=v_month
  order by matrix.effective_from desc,matrix.version desc limit 1;
  if v_matrix is null then raise exception 'MATRIX_V2_FOR_MONTH_NOT_FOUND'; end if;
  return jsonb_build_object(
    'employeeId',v_employee,'month',v_month,
    'employee',jsonb_build_object(
      'MORNING',coalesce((select upper(p.preference_value->>'level')
        from public.employee_preferences p where p.employee_id=v_employee
          and p.status='ACTIVE' and p.source='GRAFIK_PRO'
          and p.preference_type='PREFERRED_SHIFT'
          and upper(p.preference_value->>'period')='MORNING'
          and p.valid_from<v_month+interval '1 month' and p.valid_to>=v_month
        order by p.created_at desc limit 1),'NEUTRAL'),
      'MIDDLE',coalesce((select upper(p.preference_value->>'level')
        from public.employee_preferences p where p.employee_id=v_employee
          and p.status='ACTIVE' and p.source='GRAFIK_PRO'
          and p.preference_type='PREFERRED_SHIFT'
          and upper(p.preference_value->>'period')='MIDDLE'
          and p.valid_from<v_month+interval '1 month' and p.valid_to>=v_month
        order by p.created_at desc limit 1),'NEUTRAL'),
      'EVENING',coalesce((select upper(p.preference_value->>'level')
        from public.employee_preferences p where p.employee_id=v_employee
          and p.status='ACTIVE' and p.source='GRAFIK_PRO'
          and p.preference_type='PREFERRED_SHIFT'
          and upper(p.preference_value->>'period')='EVENING'
          and p.valid_from<v_month+interval '1 month' and p.valid_to>=v_month
        order by p.created_at desc limit 1),'NEUTRAL')
    ),
    'effective',coalesce(solver_private.alpha16_shift_rules_v2(
      v_employee,v_matrix,v_month
    )->'periods','{}'::jsonb),
    'managerOverrides',coalesce((select jsonb_object_agg(
      upper(p.preference_value->>'period'),upper(p.preference_value->>'level')
    ) from public.employee_preferences p
      where p.employee_id=v_employee and p.status='ACTIVE'
        and p.source='MANAGER' and p.preference_type='PREFERRED_SHIFT'
        and p.preference_value->>'matrixVersionId'=v_matrix::text
        and p.valid_from<v_month+interval '1 month' and p.valid_to>=v_month
    ),'{}'::jsonb)
  );
end;
$$;

create or replace function public.employee_shift_preferences_save_self_v2(
  p_month date,p_preferences jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_employee uuid;
  v_month date:=date_trunc('month',p_month)::date;
  v_period text;
  v_level text;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_month is null or jsonb_typeof(p_preferences)<>'object' then
    raise exception 'INVALID_SHIFT_PERIOD_PREFERENCES';
  end if;
  select employee.id into v_employee from public.employees employee
  where employee.auth_user_id=auth.uid() and employee.active
    and employee.archived_at is null order by employee.id limit 1 for update;
  if v_employee is null then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  update public.employee_preferences preference set status='CANCELLED'
  where preference.employee_id=v_employee and preference.status='ACTIVE'
    and preference.source='GRAFIK_PRO'
    and preference.preference_type='PREFERRED_SHIFT'
    and preference.valid_from<v_month+interval '1 month'
    and preference.valid_to>=v_month;
  foreach v_period in array array['MORNING','MIDDLE','EVENING'] loop
    v_level:=upper(coalesce(p_preferences->>v_period,'NEUTRAL'));
    if v_level not in ('PREFERRED','NEUTRAL','AVOIDED') then
      raise exception 'INVALID_EMPLOYEE_SHIFT_PREFERENCE_LEVEL';
    end if;
    insert into public.employee_preferences(
      employee_id,valid_from,valid_to,preference_type,preference_value,
      source,editable_by_employee,status
    ) values(
      v_employee,v_month,(v_month+interval '1 month - 1 day')::date,
      'PREFERRED_SHIFT',jsonb_build_object('period',v_period,'level',v_level),
      'GRAFIK_PRO',true,'ACTIVE'
    );
  end loop;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'employee_shift_preferences_v2',v_employee::text,'UPSERT',
    jsonb_build_object('month',v_month,'preferences',p_preferences));
  return jsonb_build_object('saved',3,'month',v_month);
end;
$$;

create or replace function public.matrix_v2_publication_readiness_alpha16(
  p_effective_from date default current_date
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_matrix uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  select mv.id into v_matrix from public.matrix_versions mv
  where mv.status='DRAFT' and mv.schema_version>=2
  order by mv.version desc limit 1;
  if v_matrix is null then raise exception 'NO_MATRIX_V2_DRAFT'; end if;
  return jsonb_build_object(
    'ready',not exists(
      select 1 from public.matrix_employee_profiles_v2 profile
      where profile.matrix_version_id=v_matrix and profile.active and (
        not exists(select 1 from public.employee_pay_rates_v2 rate
          where rate.employee_id=profile.employee_id and rate.active
            and rate.valid_from<=p_effective_from
            and (rate.valid_to is null or rate.valid_to>=p_effective_from))
        or not exists(select 1 from public.matrix_employee_roles_v2 role_grant
          where role_grant.matrix_version_id=v_matrix
            and role_grant.employee_id=profile.employee_id and role_grant.active)
        or not exists(select 1 from public.matrix_employee_locations_v2 location_grant
          where location_grant.matrix_version_id=v_matrix
            and location_grant.employee_id=profile.employee_id
            and location_grant.active and location_grant.standard_allowed)
      )
    ),
    'blockers',coalesce((
      select jsonb_agg(blocker order by blocker->>'employeeNo',blocker->>'code')
      from (
        select jsonb_build_object(
          'code','MISSING_PAY_RATE','employeeId',profile.employee_id,
          'employeeNo',profile.employee_no,
          'employeeName',profile.first_name||' '||profile.last_name,
          'message','Brak aktywnej stawki na dzień publikacji.'
        ) blocker
        from public.matrix_employee_profiles_v2 profile
        where profile.matrix_version_id=v_matrix and profile.active
          and not exists(select 1 from public.employee_pay_rates_v2 rate
            where rate.employee_id=profile.employee_id and rate.active
              and rate.valid_from<=p_effective_from
              and (rate.valid_to is null or rate.valid_to>=p_effective_from))
        union all
        select jsonb_build_object(
          'code','MISSING_ROLE','employeeId',profile.employee_id,
          'employeeNo',profile.employee_no,
          'employeeName',profile.first_name||' '||profile.last_name,
          'message','Brak aktywnej roli w Matrixie.'
        )
        from public.matrix_employee_profiles_v2 profile
        where profile.matrix_version_id=v_matrix and profile.active
          and not exists(select 1 from public.matrix_employee_roles_v2 role_grant
            where role_grant.matrix_version_id=v_matrix
              and role_grant.employee_id=profile.employee_id and role_grant.active)
        union all
        select jsonb_build_object(
          'code','MISSING_STANDARD_LOCATION','employeeId',profile.employee_id,
          'employeeNo',profile.employee_no,
          'employeeName',profile.first_name||' '||profile.last_name,
          'message','Brak co najmniej jednego lokalu pracy w zwykłym limicie.'
        )
        from public.matrix_employee_profiles_v2 profile
        where profile.matrix_version_id=v_matrix and profile.active
          and not exists(select 1 from public.matrix_employee_locations_v2 location_grant
            where location_grant.matrix_version_id=v_matrix
              and location_grant.employee_id=profile.employee_id
              and location_grant.active and location_grant.standard_allowed)
      ) problems
    ),'[]'::jsonb),
    'effectiveFrom',p_effective_from,'matrixVersionId',v_matrix
  );
end;
$$;

create or replace function public.matrix_v2_import_preview_alpha16(
  p_payload jsonb
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_matrix uuid;
  v_errors jsonb:='[]'::jsonb;
  v_warnings jsonb:='[]'::jsonb;
  v_row jsonb;
  v_index integer;
  v_total integer:=0;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if p_payload is null or jsonb_typeof(p_payload)<>'object' then
    raise exception 'INVALID_MATRIX_IMPORT_PAYLOAD';
  end if;
  select mv.id into v_matrix from public.matrix_versions mv
  where mv.status='DRAFT' and mv.schema_version>=2
  order by mv.version desc limit 1;
  if v_matrix is null then raise exception 'NO_MATRIX_V2_DRAFT'; end if;
  if jsonb_typeof(coalesce(p_payload->'employees','[]'::jsonb))<>'array'
    or jsonb_typeof(coalesce(p_payload->'shifts','[]'::jsonb))<>'array'
    or jsonb_typeof(coalesce(p_payload->'staffingRules','[]'::jsonb))<>'array'
    or jsonb_typeof(coalesce(p_payload->'roleDuties','[]'::jsonb))<>'array' then
    raise exception 'INVALID_MATRIX_IMPORT_SECTIONS';
  end if;
  v_total:=jsonb_array_length(coalesce(p_payload->'employees','[]'::jsonb))
    +jsonb_array_length(coalesce(p_payload->'shifts','[]'::jsonb))
    +jsonb_array_length(coalesce(p_payload->'staffingRules','[]'::jsonb))
    +jsonb_array_length(coalesce(p_payload->'roleDuties','[]'::jsonb));
  if v_total=0 then
    v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
      'sheet','PLIK','row',0,'code','EMPTY_IMPORT',
      'message','Plik nie zawiera obsługiwanych wierszy.'
    ));
  elsif v_total>5000 then
    v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
      'sheet','PLIK','row',0,'code','IMPORT_TOO_LARGE',
      'message','Jednorazowy import może zawierać najwyżej 5000 wierszy.'
    ));
  end if;

  for v_row,v_index in
    select row.value,row.ordinality::integer
    from jsonb_array_elements(coalesce(p_payload->'employees','[]'::jsonb))
      with ordinality row(value,ordinality)
  loop
    if nullif(trim(v_row->>'firstName'),'') is null
      or nullif(trim(v_row->>'lastName'),'') is null then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','EMPLOYEE_NAME_REQUIRED',
        'message','Podaj imię i nazwisko.'
      ));
    end if;
    if nullif(trim(v_row->>'employeeNo'),'') is not null
      and not exists(select 1 from public.matrix_employee_profiles_v2 profile
        where profile.matrix_version_id=v_matrix
          and upper(profile.employee_no)=upper(trim(v_row->>'employeeNo'))) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','EMPLOYEE_NUMBER_NOT_FOUND',
        'message','Podany numer nie istnieje. Dla nowej osoby pozostaw numer pusty — system nada go automatycznie.'
      ));
    end if;
    if nullif(lower(trim(v_row->>'email')),'') is not null
      and (select count(*) from jsonb_array_elements(
        coalesce(p_payload->'employees','[]'::jsonb)
      ) duplicate where lower(trim(duplicate.value->>'email'))=
        lower(trim(v_row->>'email'))) > 1 then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','DUPLICATE_EMPLOYEE_EMAIL',
        'message','Ten sam adres e-mail występuje w pliku więcej niż raz.'
      ));
    end if;
    if nullif(trim(v_row->>'employeeNo'),'') is not null
      and (select count(*) from jsonb_array_elements(
        coalesce(p_payload->'employees','[]'::jsonb)
      ) duplicate where upper(trim(duplicate.value->>'employeeNo'))=
        upper(trim(v_row->>'employeeNo'))) > 1 then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','DUPLICATE_EMPLOYEE_NUMBER',
        'message','Ten sam numer pracownika występuje w pliku więcej niż raz.'
      ));
    end if;
    if nullif(trim(v_row->>'employeeNo'),'') is not null
      and nullif(lower(trim(v_row->>'email')),'') is not null
      and exists(
        select 1
        from public.matrix_employee_profiles_v2 number_profile
        join public.matrix_employee_profiles_v2 email_profile
          on email_profile.matrix_version_id=number_profile.matrix_version_id
          and email_profile.employee_id<>number_profile.employee_id
          and lower(email_profile.email)=lower(trim(v_row->>'email'))
        where number_profile.matrix_version_id=v_matrix
          and upper(number_profile.employee_no)=upper(trim(v_row->>'employeeNo'))
      ) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','EMPLOYEE_IDENTITY_CONFLICT',
        'message','Numer pracownika i adres e-mail wskazują dwie różne osoby.'
      ));
    end if;
    if nullif(trim(v_row->>'primaryRoleCode'),'') is null
      or not exists(select 1 from public.matrix_roles_v2 role_row
        where role_row.matrix_version_id=v_matrix and role_row.active
          and upper(role_row.code)=upper(v_row->>'primaryRoleCode')) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','ROLE_NOT_FOUND',
        'message','Nie znaleziono aktywnej roli z kolumny primaryRoleCode.'
      ));
    end if;
    if jsonb_typeof(coalesce(v_row->'locationCodes','[]'::jsonb))<>'array'
      or jsonb_array_length(coalesce(v_row->'locationCodes','[]'::jsonb))=0 then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','LOCATION_REQUIRED',
        'message','Podaj co najmniej jeden zwykły lokal pracy.'
      ));
    elsif exists(
      select 1 from jsonb_array_elements_text(v_row->'locationCodes') code
      where not exists(select 1 from public.matrix_locations_v2 location_row
        where location_row.matrix_version_id=v_matrix and location_row.active
          and upper(location_row.code)=upper(code.value))
    ) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','LOCATION_NOT_FOUND',
        'message','Co najmniej jeden kod lokalu nie istnieje w Matrixie.'
      ));
    end if;
    if nullif(v_row->>'baseRate','') is null then
      v_warnings:=v_warnings||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','PAY_RATE_MISSING',
        'message','Brak stawki zablokuje późniejszą publikację Matrixa.'
      ));
    elsif (v_row->>'baseRate') !~ '^\d+([.,]\d{1,2})?$' then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','INVALID_PAY_RATE',
        'message','Stawka musi być nieujemną liczbą z maksymalnie dwoma miejscami po przecinku.'
      ));
    end if;
    if exists(select 1 from jsonb_each_text(coalesce(
      v_row->'shiftPeriodPreferences','{}'::jsonb
    )) preference where upper(preference.value) not in (
      'INHERIT','PREFERRED','NEUTRAL','AVOIDED','BLOCKED'
    )) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','PRACOWNICY','row',v_index+1,'code','INVALID_SHIFT_PREFERENCE',
        'message','Preferencja pory musi mieć wartość INHERIT, PREFERRED, NEUTRAL, AVOIDED albo BLOCKED.'
      ));
    end if;
  end loop;

  for v_row,v_index in
    select row.value,row.ordinality::integer
    from jsonb_array_elements(coalesce(p_payload->'shifts','[]'::jsonb))
      with ordinality row(value,ordinality)
  loop
    if nullif(trim(v_row->>'code'),'') is null
      or nullif(trim(v_row->>'name'),'') is null then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','ZMIANY','row',v_index+1,'code','SHIFT_IDENTITY_REQUIRED',
        'message','Podaj kod i nazwę bloku obsady.'
      ));
    end if;
    if upper(coalesce(v_row->>'shiftPeriod',''))
      not in ('MORNING','MIDDLE','EVENING') then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','ZMIANY','row',v_index+1,'code','INVALID_SHIFT_PERIOD',
        'message','Okres zmiany to MORNING, MIDDLE albo EVENING.'
      ));
    end if;
    if coalesce(v_row->>'startsAt','') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
      or coalesce(v_row->>'endsAt','') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','ZMIANY','row',v_index+1,'code','INVALID_SHIFT_TIME',
        'message','Godziny muszą mieć format HH:MM.'
      ));
    end if;
    if not exists(select 1 from public.matrix_locations_v2 location_row
      where location_row.matrix_version_id=v_matrix and location_row.active
        and upper(location_row.code)=upper(coalesce(v_row->>'locationCode',''))) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','ZMIANY','row',v_index+1,'code','LOCATION_NOT_FOUND',
        'message','Nie znaleziono lokalu dla bloku obsady.'
      ));
    end if;
    if jsonb_typeof(coalesce(v_row->'days','[]'::jsonb))<>'array'
      or jsonb_array_length(coalesce(v_row->'days','[]'::jsonb))=0
      or exists(select 1 from jsonb_array_elements_text(v_row->'days') day_value
        where day_value.value !~ '^[1-7]$') then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','ZMIANY','row',v_index+1,'code','INVALID_SHIFT_DAYS',
        'message','Podaj co najmniej jeden dzień od 1 do 7.'
      ));
    end if;
  end loop;

  for v_row,v_index in
    select row.value,row.ordinality::integer
    from jsonb_array_elements(coalesce(p_payload->'roleDuties','[]'::jsonb))
      with ordinality row(value,ordinality)
  loop
    if not exists(select 1 from public.matrix_roles_v2 role_row
      where role_row.matrix_version_id=v_matrix and role_row.active
        and upper(role_row.code)=upper(coalesce(v_row->>'roleCode',''))) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','ROLE-OBOWIĄZKI','row',v_index+1,'code','ROLE_NOT_FOUND',
        'message','Nie znaleziono aktywnej roli.'
      ));
    end if;
    if not exists(select 1 from public.matrix_duties_v2 duty_row
      where duty_row.matrix_version_id=v_matrix and duty_row.active
        and upper(duty_row.code)=upper(coalesce(v_row->>'dutyCode',''))) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','ROLE-OBOWIĄZKI','row',v_index+1,'code','DUTY_NOT_FOUND',
        'message','Nie znaleziono aktywnego obowiązku.'
      ));
    end if;
    if upper(coalesce(v_row->>'assignmentMode','OPTIONAL'))
      not in ('REQUIRED','OPTIONAL','EXTRA') then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','ROLE-OBOWIĄZKI','row',v_index+1,'code','INVALID_ASSIGNMENT_MODE',
        'message','Znaczenie to REQUIRED, OPTIONAL albo EXTRA.'
      ));
    end if;
    if coalesce((v_row->>'shiftObligation')::boolean,false)
      and upper(coalesce(v_row->>'shiftPeriod',''))
        not in ('MORNING','MIDDLE','EVENING') then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','ROLE-OBOWIĄZKI','row',v_index+1,'code','SHIFT_PERIOD_REQUIRED',
        'message','Obowiązek zmianowy wymaga pory MORNING, MIDDLE albo EVENING.'
      ));
    end if;
  end loop;

  for v_row,v_index in
    select row.value,row.ordinality::integer
    from jsonb_array_elements(coalesce(p_payload->'staffingRules','[]'::jsonb))
      with ordinality row(value,ordinality)
  loop
    if upper(coalesce(v_row->>'operation','SET')) not in ('SET','ADD','REMOVE') then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','OBSADA','row',v_index+1,'code','INVALID_OPERATION',
        'message','Import obsady obsługuje SET, ADD albo REMOVE.'
      ));
    end if;
    if upper(coalesce(v_row->>'operation','SET')) in ('SET','ADD')
      and (coalesce(v_row->>'countValue','') !~ '^\d+$'
        or (v_row->>'countValue')::integer<0) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','OBSADA','row',v_index+1,'code','INVALID_STAFFING_COUNT',
        'message','Liczba osób musi być nieujemną liczbą całkowitą.'
      ));
    end if;
    if not exists(select 1 from public.matrix_scenarios_v2 scenario
      where scenario.matrix_version_id=v_matrix and scenario.active
        and upper(scenario.code)=upper(coalesce(v_row->>'scenarioCode',''))) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','OBSADA','row',v_index+1,'code','SCENARIO_NOT_FOUND',
        'message','Nie znaleziono scenariusza.'
      ));
    end if;
    if not exists(select 1 from public.matrix_roles_v2 role_row
      where role_row.matrix_version_id=v_matrix and role_row.active
        and upper(role_row.code)=upper(coalesce(v_row->>'roleCode',''))) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','OBSADA','row',v_index+1,'code','ROLE_NOT_FOUND',
        'message','Nie znaleziono roli.'
      ));
    end if;
    if not exists(select 1 from public.matrix_shift_templates_v2 shift_row
      join public.matrix_locations_v2 location_row on location_row.id=shift_row.location_id
      where shift_row.matrix_version_id=v_matrix and shift_row.active
        and upper(shift_row.code)=upper(coalesce(v_row->>'shiftCode',''))
        and (nullif(v_row->>'locationCode','') is null
          or upper(location_row.code)=upper(v_row->>'locationCode'))) then
      v_errors:=v_errors||jsonb_build_array(jsonb_build_object(
        'sheet','OBSADA','row',v_index+1,'code','SHIFT_NOT_FOUND',
        'message','Nie znaleziono zmiany lub bloku obsady.'
      ));
    end if;
  end loop;

  return jsonb_build_object(
    'valid',jsonb_array_length(v_errors)=0,
    'errors',v_errors,'warnings',v_warnings,
    'summary',jsonb_build_object(
      'employees',jsonb_array_length(coalesce(p_payload->'employees','[]'::jsonb)),
      'shifts',jsonb_array_length(coalesce(p_payload->'shifts','[]'::jsonb)),
      'staffingRules',jsonb_array_length(coalesce(p_payload->'staffingRules','[]'::jsonb)),
      'roleDuties',jsonb_array_length(coalesce(p_payload->'roleDuties','[]'::jsonb)),
      'total',v_total
    ),
    'matrixVersionId',v_matrix
  );
end;
$$;

create or replace function public.matrix_v2_import_apply_alpha16(
  p_payload jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_preview jsonb;
  v_matrix uuid;
  v_row jsonb;
  v_location_ids jsonb;
  v_role uuid;
  v_location uuid;
  v_shift uuid;
  v_scenario uuid;
  v_duty uuid;
  v_existing uuid;
  v_result jsonb;
  v_employee uuid;
  v_rate_id uuid;
  v_currency text;
  v_effective date;
  v_applied integer:=0;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  v_preview:=public.matrix_v2_import_preview_alpha16(p_payload);
  if not (v_preview->>'valid')::boolean then
    raise exception 'MATRIX_IMPORT_HAS_ERRORS:%',v_preview->'errors';
  end if;
  v_matrix:=(v_preview->>'matrixVersionId')::uuid;
  select upper(mv.settings->>'currency'),coalesce(mv.effective_from,current_date)
  into v_currency,v_effective from public.matrix_versions mv where mv.id=v_matrix;

  for v_row in select value from jsonb_array_elements(
    coalesce(p_payload->'employees','[]'::jsonb)
  ) loop
    select profile.employee_id into v_existing
    from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=v_matrix and (
      (nullif(trim(v_row->>'employeeNo'),'') is not null
        and upper(profile.employee_no)=upper(trim(v_row->>'employeeNo')))
      or (nullif(lower(trim(v_row->>'email')),'') is not null
        and lower(profile.email)=lower(trim(v_row->>'email')))
    ) order by profile.employee_id limit 1;
    select role_row.id into v_role from public.matrix_roles_v2 role_row
    where role_row.matrix_version_id=v_matrix and role_row.active
      and upper(role_row.code)=upper(v_row->>'primaryRoleCode');
    select coalesce(jsonb_agg(location_row.id order by location_row.sort_order,
      location_row.code),'[]'::jsonb) into v_location_ids
    from public.matrix_locations_v2 location_row
    join jsonb_array_elements_text(v_row->'locationCodes') code
      on upper(code.value)=upper(location_row.code)
    where location_row.matrix_version_id=v_matrix and location_row.active;
    v_result:=public.matrix_v2_employee_save_alpha16(v_existing,jsonb_build_object(
      'firstName',trim(v_row->>'firstName'),
      'lastName',trim(v_row->>'lastName'),
      'email',nullif(lower(trim(v_row->>'email')),''),
      'primaryRoleId',v_role,'locationIds',v_location_ids,
      'employmentStart',nullif(v_row->>'employmentStart',''),
      'employmentEnd',nullif(v_row->>'employmentEnd',''),
      'nominalMonthlyMinutes',round(coalesce(nullif(replace(v_row->>'nominalHours',',','.'),'')::numeric,168)*60),
      'maximumMonthlyMinutes',round(coalesce(nullif(replace(v_row->>'maximumMonthlyHours',',','.'),'')::numeric,210)*60),
      'maximumWeeklyMinutes',round(coalesce(nullif(replace(v_row->>'maximumWeeklyHours',',','.'),'')::numeric,40)*60),
      'maximumConsecutiveDays',coalesce(nullif(v_row->>'maximumConsecutiveDays','')::integer,6),
      'minimumRestMinutes',case when nullif(v_row->>'minimumRestHours','') is null
        then null else round(replace(v_row->>'minimumRestHours',',','.')::numeric*60) end,
      'preferenceMonth',coalesce(nullif(v_row->>'preferenceMonth','')::date,v_effective),
      'shiftPeriodPreferences',coalesce(v_row->'shiftPeriodPreferences','{}'::jsonb)
    ));
    v_employee:=(v_result->>'id')::uuid;
    if nullif(v_row->>'baseRate','') is not null then
      select rate.id into v_rate_id from public.employee_pay_rates_v2 rate
      where rate.employee_id=v_employee and rate.active
        and rate.valid_from<=v_effective
        and (rate.valid_to is null or rate.valid_to>=v_effective)
      order by rate.valid_from desc limit 1;
      perform public.employee_pay_rate_save_v2(
        v_rate_id,v_employee,v_effective,null,
        round(replace(v_row->>'baseRate',',','.')::numeric*100)::bigint,
        v_currency,nullif(v_row->>'contractType',''),true
      );
    end if;
    v_applied:=v_applied+1;
  end loop;

  for v_row in select value from jsonb_array_elements(
    coalesce(p_payload->'shifts','[]'::jsonb)
  ) loop
    select location_row.id into v_location from public.matrix_locations_v2 location_row
    where location_row.matrix_version_id=v_matrix and location_row.active
      and upper(location_row.code)=upper(v_row->>'locationCode');
    select shift_row.id into v_existing from public.matrix_shift_templates_v2 shift_row
    where shift_row.matrix_version_id=v_matrix and shift_row.location_id=v_location
      and upper(shift_row.code)=upper(v_row->>'code');
    perform public.matrix_v2_admin_save_alpha16('SHIFT',v_existing,jsonb_build_object(
      'locationId',v_location,'code',upper(v_row->>'code'),'name',trim(v_row->>'name'),
      'startsAt',v_row->>'startsAt','endsAt',v_row->>'endsAt',
      'endsNextDay',coalesce((v_row->>'endsNextDay')::boolean,false),
      'days',coalesce(v_row->'days','[1,2,3,4,5,6,7]'::jsonb),
      'sortOrder',coalesce(nullif(v_row->>'sortOrder','')::integer,0),
      'active',coalesce((v_row->>'active')::boolean,true),
      'shiftPeriod',upper(v_row->>'shiftPeriod')
    ));
    v_applied:=v_applied+1;
  end loop;

  for v_row in select value from jsonb_array_elements(
    coalesce(p_payload->'roleDuties','[]'::jsonb)
  ) loop
    select role_row.id into v_role from public.matrix_roles_v2 role_row
    where role_row.matrix_version_id=v_matrix
      and upper(role_row.code)=upper(v_row->>'roleCode');
    select duty_row.id into v_duty from public.matrix_duties_v2 duty_row
    where duty_row.matrix_version_id=v_matrix
      and upper(duty_row.code)=upper(v_row->>'dutyCode');
    select link.id into v_existing from public.matrix_role_duties_v2 link
    where link.matrix_version_id=v_matrix and link.role_id=v_role and link.duty_id=v_duty;
    perform public.matrix_v2_admin_save_alpha16('ROLE_DUTY',v_existing,jsonb_build_object(
      'roleId',v_role,'dutyId',v_duty,
      'assignmentMode',upper(coalesce(v_row->>'assignmentMode','OPTIONAL')),
      'minimumCount',coalesce(nullif(v_row->>'minimumCount','')::integer,0),
      'active',coalesce((v_row->>'active')::boolean,true),
      'shiftObligation',coalesce((v_row->>'shiftObligation')::boolean,false),
      'shiftPeriod',nullif(upper(v_row->>'shiftPeriod'),'')
    ));
    v_applied:=v_applied+1;
  end loop;

  for v_row in select value from jsonb_array_elements(
    coalesce(p_payload->'staffingRules','[]'::jsonb)
  ) loop
    select scenario.id into v_scenario from public.matrix_scenarios_v2 scenario
    where scenario.matrix_version_id=v_matrix
      and upper(scenario.code)=upper(v_row->>'scenarioCode');
    select role_row.id into v_role from public.matrix_roles_v2 role_row
    where role_row.matrix_version_id=v_matrix
      and upper(role_row.code)=upper(v_row->>'roleCode');
    select shift_row.id into v_shift from public.matrix_shift_templates_v2 shift_row
    join public.matrix_locations_v2 location_row on location_row.id=shift_row.location_id
    where shift_row.matrix_version_id=v_matrix
      and upper(shift_row.code)=upper(v_row->>'shiftCode')
      and (nullif(v_row->>'locationCode','') is null
        or upper(location_row.code)=upper(v_row->>'locationCode'))
    order by shift_row.id limit 1;
    v_duty:=null;
    if nullif(v_row->>'dutyCode','') is not null then
      select duty_row.id into v_duty from public.matrix_duties_v2 duty_row
      where duty_row.matrix_version_id=v_matrix
        and upper(duty_row.code)=upper(v_row->>'dutyCode');
    end if;
    select rule.id into v_existing from public.matrix_staffing_rules_v2 rule
    where rule.matrix_version_id=v_matrix and rule.scenario_id=v_scenario
      and rule.shift_template_id=v_shift and rule.role_id=v_role
      and rule.duty_id is not distinct from v_duty;
    perform public.matrix_v2_admin_save_alpha16('STAFFING_RULE',v_existing,
      jsonb_build_object(
        'scenarioId',v_scenario,'shiftTemplateId',v_shift,'roleId',v_role,
        'dutyId',v_duty,'operation',upper(coalesce(v_row->>'operation','SET')),
        'countValue',case when upper(coalesce(v_row->>'operation','SET')) in ('SET','ADD')
          then coalesce(nullif(v_row->>'countValue','')::integer,0) else null end,
        'multiplierBasisPoints',null,'active',coalesce((v_row->>'active')::boolean,true),
        'sourceMetadata',jsonb_build_object('source','EXCEL_ALPHA16')
      )
    );
    v_applied:=v_applied+1;
  end loop;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_v2_import',v_matrix::text,'APPLY',jsonb_build_object(
    'appliedRows',v_applied,'summary',v_preview->'summary'
  ));
  return jsonb_build_object('appliedRows',v_applied,'summary',v_preview->'summary');
end;
$$;

revoke all on function solver_private.alpha16_shift_period_default_v2(),
  solver_private.alpha16_role_duty_defaults_v2(),
  solver_private.alpha16_preference_level_v2(uuid,uuid,date,text),
  solver_private.alpha16_shift_rules_v2(uuid,uuid,date),
  solver_private.build_snapshot_payload_before_alpha16_v2(uuid,date,uuid,uuid,text,uuid),
  solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid),
  solver_private.resolved_demand_v2(date,uuid,uuid,uuid)
  from public,anon,authenticated;

grant execute on function solver_private.alpha16_shift_period_default_v2(),
  solver_private.alpha16_role_duty_defaults_v2(),
  solver_private.alpha16_preference_level_v2(uuid,uuid,date,text),
  solver_private.alpha16_shift_rules_v2(uuid,uuid,date),
  solver_private.build_snapshot_payload_before_alpha16_v2(uuid,date,uuid,uuid,text,uuid),
  solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid),
  solver_private.resolved_demand_v2(date,uuid,uuid,uuid)
  to service_role;

revoke all on function public.matrix_v2_next_employee_no_v2(),
  public.matrix_v2_employee_directory_alpha16(date),
  public.matrix_v2_employee_save_alpha16(uuid,jsonb),
  public.matrix_v2_admin_save_alpha16(text,uuid,jsonb),
  public.employee_shift_preferences_self_v2(date),
  public.employee_shift_preferences_save_self_v2(date,jsonb),
  public.matrix_v2_publication_readiness_alpha16(date),
  public.matrix_v2_import_preview_alpha16(jsonb),
  public.matrix_v2_import_apply_alpha16(jsonb)
  from public,anon,authenticated;

grant execute on function public.matrix_v2_next_employee_no_v2(),
  public.matrix_v2_employee_directory_alpha16(date),
  public.matrix_v2_employee_save_alpha16(uuid,jsonb),
  public.matrix_v2_admin_save_alpha16(text,uuid,jsonb),
  public.employee_shift_preferences_self_v2(date),
  public.employee_shift_preferences_save_self_v2(date,jsonb),
  public.matrix_v2_publication_readiness_alpha16(date),
  public.matrix_v2_import_preview_alpha16(jsonb),
  public.matrix_v2_import_apply_alpha16(jsonb)
  to authenticated,service_role;

comment on function public.matrix_v2_publication_readiness_alpha16(date) is
  'Polish, actionable Matrix publication preflight; does not mutate data.';
comment on function public.matrix_v2_employee_save_alpha16(uuid,jsonb) is
  'Draft-only employee source of truth with automatic employee number, ordinary multi-location grants and manager preference precedence.';
comment on function public.employee_shift_preferences_save_self_v2(date,jsonb) is
  'Employee self-service preference for morning, middle and evening; manager Matrix rows remain authoritative.';
comment on function public.matrix_v2_import_preview_alpha16(jsonb) is
  'Read-only validation of normalized Excel Matrix sheets before an atomic apply.';
comment on function public.matrix_v2_import_apply_alpha16(jsonb) is
  'Atomic OWNER/ADMIN Matrix import after the same database validation used by preview.';
