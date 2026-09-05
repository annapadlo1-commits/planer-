-- B4F-164: automatic/ordinary validation rejects NEVER and unapproved
-- APPROVAL_REQUIRED overtime, accepts ALLOWED, and accepts only a persisted
-- leader approval whose quote covers the submitted monthly total.

begin;

do $$
declare
  v_snapshot jsonb;
  v_variant jsonb;
  v_test_snapshot jsonb;
  v_approved_variant jsonb;
  v_variant_id uuid;
  v_strategy_id uuid;
  v_employee_id text;
  v_total integer;
  v_failed boolean;
begin
  if has_function_privilege(
    'authenticated','solver_private.validate_variant_v2(jsonb,jsonb)','execute'
  ) or has_function_privilege(
    'anon','solver_private.validate_variant_v2(jsonb,jsonb)','execute'
  ) then raise exception 'B4F164_PRIVATE_VALIDATOR_EXPOSED'; end if;

  if position('OVERTIME_POLICY_LIMIT' in pg_get_functiondef(
    'solver_private.validate_variant_v2(jsonb,jsonb)'::regprocedure
  ))=0 or position('externalAssignments' in pg_get_functiondef(
    'solver_private.validate_variant_v2(jsonb,jsonb)'::regprocedure
  ))=0 then raise exception 'B4F164_VALIDATOR_CONTRACT_MISSING'; end if;

  if position('b4f164_overtime_approval_employee' in pg_get_functiondef(
    'public.optimizer_leader_assignment_save_uat_v3(uuid,uuid,bigint,uuid,text,boolean,uuid,boolean)'::regprocedure
  ))=0 or position('LEADER_APPROVED' in pg_get_functiondef(
    'public.optimizer_leader_assignment_save_uat_v3(uuid,uuid,bigint,uuid,text,boolean,uuid,boolean)'::regprocedure
  ))=0 then raise exception 'B4F164_LEADER_APPROVAL_PATH_MISSING'; end if;

  select variant.id,variant.strategy_id,snapshot.snapshot
  into v_variant_id,v_strategy_id,v_snapshot
  from public.plan_variants_v2 variant
  join solver_private.optimization_snapshots_v2 snapshot on snapshot.run_id=variant.run_id
  where variant.variant_kind='GENERATED'
    and variant.status in ('READY','SELECTED','PUBLISHED')
    and exists(select 1 from public.plan_assignments_v2 assignment
      where assignment.variant_id=variant.id)
  order by variant.created_at desc
  limit 1;
  if v_variant_id is null then raise exception 'B4F164_TEST_VARIANT_MISSING'; end if;

  v_variant:=solver_private.materialized_variant_payload_v2(
    array[v_variant_id],v_snapshot,v_strategy_id
  );

  with internal_minutes as (
    select assignment.value->>'employeeId' employee_id,
      sum((slot.value->>'durationMinutes')::integer)::integer minutes
    from jsonb_array_elements(v_variant->'assignments') assignment(value)
    join jsonb_array_elements(v_snapshot->'slots') slot(value)
      on slot.value->>'slotId'=assignment.value->>'slotId'
    group by assignment.value->>'employeeId'
  ), external_minutes as (
    select external.value->>'employeeId' employee_id,
      sum(extract(epoch from (
        (external.value->>'end')::timestamptz-
        (external.value->>'start')::timestamptz
      ))/60)::integer minutes
    from jsonb_array_elements(coalesce(v_snapshot->'externalAssignments','[]'::jsonb)) external(value)
    where ((external.value->>'start')::timestamptz at time zone coalesce(
      nullif(v_snapshot->'settings'->>'timezone',''),'Europe/Warsaw'
    ))::date between (v_snapshot->>'periodStart')::date and (v_snapshot->>'periodEnd')::date
    group by external.value->>'employeeId'
  )
  select employee_id,sum(minutes)::integer into v_employee_id,v_total
  from (
    select * from internal_minutes
    union all
    select * from external_minutes
  ) combined
  group by employee_id
  having sum(minutes)>0
  order by employee_id
  limit 1;
  if v_employee_id is null or v_total<1 then raise exception 'B4F164_TEST_EMPLOYEE_MISSING'; end if;

  select jsonb_set(v_snapshot,'{employees}',jsonb_agg(
    case when employee.value->>'id'=v_employee_id then
      employee.value||jsonb_build_object(
        'overtimePolicy','ALLOWED','nominalMonthlyMinutes',v_total-1
      )
    else employee.value end order by employee.ordinality
  ),true) into v_test_snapshot
  from jsonb_array_elements(v_snapshot->'employees') with ordinality employee(value,ordinality);
  perform solver_private.validate_variant_v2(v_test_snapshot,v_variant);

  v_test_snapshot:=jsonb_set(v_test_snapshot,'{employees}',(
    select jsonb_agg(case when employee.value->>'id'=v_employee_id then
      employee.value||jsonb_build_object('overtimePolicy','NEVER')
    else employee.value end order by employee.ordinality)
    from jsonb_array_elements(v_test_snapshot->'employees') with ordinality employee(value,ordinality)
  ),true);
  v_failed:=false;
  begin
    perform solver_private.validate_variant_v2(v_test_snapshot,v_variant);
  exception when others then
    if sqlerrm not like 'OVERTIME_POLICY_LIMIT:%:NEVER:%' then raise; end if;
    v_failed:=true;
  end;
  if not v_failed then raise exception 'B4F164_NEVER_ACCEPTED'; end if;

  v_test_snapshot:=jsonb_set(v_test_snapshot,'{employees}',(
    select jsonb_agg(case when employee.value->>'id'=v_employee_id then
      employee.value||jsonb_build_object('overtimePolicy','APPROVAL_REQUIRED')
    else employee.value end order by employee.ordinality)
    from jsonb_array_elements(v_test_snapshot->'employees') with ordinality employee(value,ordinality)
  ),true);
  v_failed:=false;
  begin
    perform solver_private.validate_variant_v2(v_test_snapshot,v_variant);
  exception when others then
    if sqlerrm not like 'OVERTIME_POLICY_LIMIT:%:APPROVAL_REQUIRED:%' then raise; end if;
    v_failed:=true;
  end;
  if not v_failed then raise exception 'B4F164_UNAPPROVED_ACCEPTED'; end if;

  select jsonb_set(v_variant,'{assignments}',jsonb_agg(
    case when assignment.value->>'employeeId'=v_employee_id then
      assignment.value||jsonb_build_object(
        'overtimeDecision','LEADER_APPROVED',
        'overtimeApprovedBy','00000000-0000-0000-0000-000000000001',
        'overtimeApprovedAt','2026-08-22T00:00:00Z',
        'overtimeQuote',jsonb_build_object('projectedMonthlyMinutes',v_total)
      )
    else assignment.value end order by assignment.ordinality
  ),true) into v_approved_variant
  from jsonb_array_elements(v_variant->'assignments') with ordinality assignment(value,ordinality);
  perform solver_private.validate_variant_v2(v_test_snapshot,v_approved_variant);
end;
$$;

rollback;
