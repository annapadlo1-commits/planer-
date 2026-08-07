-- Separate Matrix shift-template capacity from employee assignment rules.
-- A Matrix may define any number of shifts.  Every employee is nevertheless
-- limited by the company setting per calendar day and may not work the last
-- configured shift of one day followed by the first shift of the next day.

alter function solver_private.build_snapshot_payload_v2(
  uuid,date,uuid,uuid,text,uuid
) rename to build_snapshot_payload_before_primary_shift_invariants_v2;

create function solver_private.build_snapshot_payload_v2(
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
  v_templates jsonb;
begin
  v_snapshot:=solver_private.build_snapshot_payload_before_primary_shift_invariants_v2(
    p_run_id,p_month,p_matrix_version_id,p_scenario_id,
    p_scope_type,p_scope_role_id
  );

  -- Preserve the explicit business sequence from Matrix.  The worker uses
  -- this only to identify last(D) -> first(D+1); it is never an employee
  -- daily-assignment limit.
  select coalesce(jsonb_agg(
    template.value||jsonb_build_object(
      'sequenceOrder',shift_template.sort_order,
      'shiftPeriod',shift_template.shift_period
    ) order by template.ordinality
  ),'[]'::jsonb)
  into v_templates
  from jsonb_array_elements(coalesce(v_snapshot->'shiftTemplates','[]'::jsonb))
    with ordinality template(value,ordinality)
  join public.matrix_shift_templates_v2 shift_template
    on shift_template.matrix_version_id=p_matrix_version_id
    and shift_template.id=(template.value->>'id')::uuid;

  return jsonb_set(v_snapshot,'{shiftTemplates}',v_templates,true);
end;
$$;

alter function solver_private.validate_variant_v2(jsonb,jsonb)
  rename to validate_variant_before_primary_shift_invariants_v2;

create function solver_private.validate_variant_v2(
  p_snapshot jsonb,
  p_variant jsonb
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_invalid bigint:=0;
  v_maximum_shifts_per_day integer:=coalesce(
    nullif(p_snapshot->'settings'->>'maximumShiftsPerDay','')::integer,1
  );
  v_timezone text:=coalesce(
    nullif(p_snapshot->'settings'->>'timezone',''),'Europe/Warsaw'
  );
begin
  -- Apply the configured daily limit to shift occurrences rather than
  -- staffing seats, including already published external work.
  with submitted as (
    select assignment.value->>'employeeId' employee_id,
      (slot.value->>'date')::date work_date,
      'ASSIGNED:'||coalesce(
        nullif(slot.value->>'occurrenceId',''),
        concat_ws('|',slot.value->>'date',slot.value->>'shiftTemplateId')
      ) item_key
    from jsonb_array_elements(coalesce(p_variant->'assignments','[]'::jsonb)) assignment
    join jsonb_array_elements(coalesce(p_snapshot->'slots','[]'::jsonb)) slot
      on slot.value->>'slotId'=assignment.value->>'slotId'
    union all
    select external.value->>'employeeId',
      ((external.value->>'start')::timestamptz at time zone v_timezone)::date,
      'EXTERNAL:'||external.ordinality::text
    from jsonb_array_elements(coalesce(
      p_snapshot->'externalAssignments','[]'::jsonb
    )) with ordinality external(value,ordinality)
  )
  select count(*) into v_invalid
  from (
    select employee_id,work_date
    from submitted
    group by employee_id,work_date
    having count(distinct item_key)>v_maximum_shifts_per_day
  ) violation;
  if v_invalid>0 then
    raise exception 'VARIANT_MULTIPLE_PRIMARY_SHIFTS_PER_DAY_INVALID';
  end if;

  -- Use the explicit Matrix order for each location and weekday.  For older
  -- immutable snapshots without sequenceOrder, local start time is the safe
  -- deterministic fallback.
  with template_days as (
    select template.value->>'id' template_id,
      template.value->>'locationId' location_id,
      weekday.value::integer weekday,
      coalesce(
        nullif(template.value->>'sequenceOrder','')::integer,
        split_part(template.value->>'startTime',':',1)::integer*60+
          split_part(template.value->>'startTime',':',2)::integer
      ) sequence_order,
      template.value->>'startTime' start_time
    from jsonb_array_elements(coalesce(
      p_snapshot->'shiftTemplates','[]'::jsonb
    )) template
    cross join lateral jsonb_array_elements_text(coalesce(
      template.value->'weekdays','[]'::jsonb
    )) weekday(value)
  ), ranked as (
    select template_days.*,
      row_number() over(
        partition by location_id,weekday
        order by sequence_order,start_time,template_id
      ) first_rank,
      row_number() over(
        partition by location_id,weekday
        order by sequence_order desc,start_time desc,template_id desc
      ) last_rank,
      count(*) over(partition by location_id,weekday) template_count
    from template_days
  ), assigned as (
    select distinct assignment.value->>'employeeId' employee_id,
      (slot.value->>'date')::date work_date,
      slot.value->>'shiftTemplateId' template_id,
      slot.value->>'locationId' location_id
    from jsonb_array_elements(coalesce(p_variant->'assignments','[]'::jsonb)) assignment
    join jsonb_array_elements(coalesce(p_snapshot->'slots','[]'::jsonb)) slot
      on slot.value->>'slotId'=assignment.value->>'slotId'
  ), sequenced as (
    select assigned.*,ranked.first_rank,ranked.last_rank,ranked.template_count
    from assigned
    join ranked on ranked.template_id=assigned.template_id
      and ranked.location_id=assigned.location_id
      and ranked.weekday=extract(isodow from assigned.work_date)::integer
  )
  select count(*) into v_invalid
  from sequenced previous_day
  join sequenced next_day
    on next_day.employee_id=previous_day.employee_id
      and next_day.work_date=previous_day.work_date+1
    and previous_day.template_count>1
    and next_day.template_count>1
    and previous_day.last_rank=1
    and next_day.first_rank=1;
  if v_invalid>0 then
    raise exception 'VARIANT_CONSECUTIVE_SHIFT_SEQUENCE_INVALID';
  end if;

  return solver_private.validate_variant_before_primary_shift_invariants_v2(
    p_snapshot,p_variant
  );
end;
$$;

revoke all on function solver_private.build_snapshot_payload_before_primary_shift_invariants_v2(
  uuid,date,uuid,uuid,text,uuid
) from public,anon,authenticated;
revoke all on function solver_private.build_snapshot_payload_v2(
  uuid,date,uuid,uuid,text,uuid
) from public,anon,authenticated;
revoke all on function solver_private.validate_variant_before_primary_shift_invariants_v2(
  jsonb,jsonb
) from public,anon,authenticated;
revoke all on function solver_private.validate_variant_v2(
  jsonb,jsonb
) from public,anon,authenticated;

grant execute on function solver_private.build_snapshot_payload_before_primary_shift_invariants_v2(
  uuid,date,uuid,uuid,text,uuid
) to service_role;
grant execute on function solver_private.build_snapshot_payload_v2(
  uuid,date,uuid,uuid,text,uuid
) to service_role;
grant execute on function solver_private.validate_variant_before_primary_shift_invariants_v2(
  jsonb,jsonb
) to service_role;
grant execute on function solver_private.validate_variant_v2(
  jsonb,jsonb
) to service_role;
