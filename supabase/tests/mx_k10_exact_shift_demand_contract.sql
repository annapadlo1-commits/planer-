-- MX-K10/MX-K12: required counts belong to one exact shift_template_id.
-- Safe to run repeatedly: the fixture and every mutation are rolled back.

begin;

do $$
declare
  v_definition text;
begin
  v_definition:=pg_get_functiondef(
    'solver_private.resolved_demand_v2(date,uuid,uuid,uuid)'::regprocedure
  );
  if position('public.matrix_staffing_rules_v2' in v_definition)=0
    or position(
      'staffing.shift_template_id=key.shift_template_id'
      in replace(v_definition,' ','')
    )=0 then
    raise exception 'MX_K10_EXACT_SHIFT_RUNTIME_SOURCE_MISSING';
  end if;
  if position('matrix_role_duties_v2' in v_definition)>0
    or position('minimum_requirements' in v_definition)>0
    or position('shift_period' in v_definition)>0 then
    raise exception 'MX_K10_BROAD_PERIOD_RUNTIME_BRANCH_STILL_PRESENT';
  end if;
  if not exists(
    select 1
    from pg_catalog.pg_constraint constraint_row
    where constraint_row.conrelid='public.matrix_role_duties_v2'::regclass
      and constraint_row.conname='matrix_role_duties_v2_competency_only_check'
      and constraint_row.convalidated
  ) then
    raise exception 'MX_K12_ROLE_DUTY_COMPETENCY_CONSTRAINT_MISSING';
  end if;
end;
$$;

do $$
declare
  v_matrix uuid:=gen_random_uuid();
  v_category uuid:=gen_random_uuid();
  v_location uuid:=gen_random_uuid();
  v_role uuid:=gen_random_uuid();
  v_scenario uuid:=gen_random_uuid();
  v_shift_selected uuid:=gen_random_uuid();
  v_shift_same_period uuid:=gen_random_uuid();
  v_month date:=date '2026-09-01';
  v_month_days integer:=extract(day from (
    date_trunc('month',date '2026-09-01')+interval '1 month - 1 day'
  ))::integer;
  v_selected_rows integer;
  v_selected_total integer;
  v_other_rows integer;
begin
  insert into public.matrix_versions(
    id,version,name,status,effective_from,settings,schema_version
  ) values(
    v_matrix,
    (select coalesce(max(version),0)+1000000 from public.matrix_versions),
    'MX-K10 exact-shift demand contract','DRAFT',v_month,
    '{"currency":"PLN","timezone":"Europe/Warsaw"}'::jsonb,2
  );

  insert into public.matrix_role_categories_v2(
    id,matrix_version_id,logical_id,code,name,color,active
  ) values(
    v_category,v_matrix,gen_random_uuid(),'MXK10_SALA','MX-K10 Sala','#7257D8',true
  );
  insert into public.matrix_locations_v2(
    id,matrix_version_id,logical_id,code,name,timezone,active
  ) values(
    v_location,v_matrix,gen_random_uuid(),'MXK10_LOC','MX-K10 Lokal','Europe/Warsaw',true
  );
  insert into public.matrix_roles_v2(
    id,matrix_version_id,logical_id,category_id,code,name,color,active
  ) values(
    v_role,v_matrix,gen_random_uuid(),v_category,'MXK10_KELNER','MX-K10 Kelner','#7257D8',true
  );
  insert into public.matrix_scenarios_v2(
    id,matrix_version_id,logical_id,code,name,is_default,active
  ) values(
    v_scenario,v_matrix,gen_random_uuid(),'MXK10_BASE','MX-K10 Bazowy',true,true
  );
  insert into public.matrix_shift_templates_v2(
    id,matrix_version_id,logical_id,location_id,code,name,starts_at,ends_at,
    ends_next_day,day_mask,shift_period,active
  ) values
    (v_shift_selected,v_matrix,gen_random_uuid(),v_location,'MXK10_MIDDLE_A',
      'MX-K10 Środek A',time '12:00',time '14:00',false,
      array[1,2,3,4,5,6,7]::smallint[],'MIDDLE',true),
    (v_shift_same_period,v_matrix,gen_random_uuid(),v_location,'MXK10_MIDDLE_B',
      'MX-K10 Środek B',time '15:00',time '16:30',false,
      array[1,2,3,4,5,6,7]::smallint[],'MIDDLE',true);

  if (select count(*) from public.matrix_shift_templates_v2 shift_row
      where shift_row.id in (v_shift_selected,v_shift_same_period)
        and shift_row.shift_period='MIDDLE')<>2 then
    raise exception 'MX_K10_TWO_MIDDLE_SHIFT_FIXTURE_INVALID';
  end if;

  insert into public.matrix_staffing_rules_v2(
    matrix_version_id,scenario_id,shift_template_id,role_id,duty_id,
    operation,count_value,active,source_metadata
  ) values(
    v_matrix,v_scenario,v_shift_selected,v_role,null,
    'ADD',1,true,'{"test":"MX-K10 exact +1"}'::jsonb
  );

  select
    count(*) filter(where demand.shift_template_id=v_shift_selected),
    coalesce(sum(demand.required_count)
      filter(where demand.shift_template_id=v_shift_selected),0),
    count(*) filter(where demand.shift_template_id=v_shift_same_period)
  into v_selected_rows,v_selected_total,v_other_rows
  from solver_private.resolved_demand_v2(
    v_month,v_matrix,v_scenario,v_role
  ) demand;

  if v_selected_rows<>v_month_days or v_selected_total<>v_month_days then
    raise exception
      'MX_K10_EXACT_SELECTED_SHIFT_DEMAND_WRONG rows=% total=% expected=%',
      v_selected_rows,v_selected_total,v_month_days;
  end if;
  if v_other_rows<>0 then
    raise exception 'MX_K10_DEMAND_LEAKED_TO_SECOND_MIDDLE_SHIFT rows=%',
      v_other_rows;
  end if;
end;
$$;

rollback;
