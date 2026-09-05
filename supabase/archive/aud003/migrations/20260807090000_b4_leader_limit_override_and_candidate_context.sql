-- B4 UAT: profile limits are one source of truth for every contract type.
-- The automatic solver must respect them; a leader may exceed only weekly or
-- monthly limits through an explicit, audited exception in a leader copy.

create or replace function solver_private.materialized_variant_payload_v2(
  p_variant_ids uuid[],p_snapshot jsonb,p_strategy_id uuid
) returns jsonb language sql stable security definer set search_path=''
as $$
  with requested as (
    select distinct x.variant_id from unnest(coalesce(p_variant_ids,'{}'::uuid[])) x(variant_id)
  ), assignment_rows as (
    select pa.id,pa.slot_key as slot_id,pa.employee_id,coalesce(pa.explanation,'{}'::jsonb) explanation
    from public.plan_assignments_v2 pa join requested r on r.variant_id=pa.variant_id
  ), assignment_payload as (
    select ar.slot_id as slot_key,ar.employee_id,ar.explanation,
      coalesce((select sum((c.calculation_basis->>'costUnits')::bigint)
        from solver_private.plan_assignment_cost_components_v2 c where c.assignment_id=ar.id),0)::bigint cost_units,
      coalesce((select jsonb_agg(jsonb_build_object(
        'ruleId',coalesce(c.pay_rule_id::text,'BASE'),'calculationType',c.component_code,
        'costUnits',(c.calculation_basis->>'costUnits')::bigint) order by c.id)
        from solver_private.plan_assignment_cost_components_v2 c where c.assignment_id=ar.id),'[]'::jsonb) cost_components
    from assignment_rows ar
  ), snapshot_slots as (
    select s.value->>'slotId' slot_id from jsonb_array_elements(coalesce(p_snapshot->'slots','[]'::jsonb)) s
  ), selected_map as (
    select jsonb_object_agg(s.slot_id,to_jsonb(a.employee_id) order by s.slot_id) payload
    from snapshot_slots s left join assignment_rows a using(slot_id)
  )
  select jsonb_build_object(
    'schemaVersion',2,'strategyId',p_strategy_id,
    'solutionHash',(select encode(extensions.digest(convert_to(
      solver_private.canonical_json_v2(m.payload),'UTF8'),'sha256'),'hex') from selected_map m),
    'assignments',coalesce((select jsonb_agg(jsonb_build_object(
      'slotId',a.slot_key,'employeeId',a.employee_id,'costUnits',a.cost_units,
      'costComponents',a.cost_components,
      'limitOverride',coalesce((a.explanation->>'limitOverride')::boolean,false),
      'limitOverrideDetails',coalesce(a.explanation->'limitOverrideDetails','[]'::jsonb)
    ) order by a.slot_key,a.employee_id) from assignment_payload a),'[]'::jsonb),
    'unfilledSlotIds',coalesce((select jsonb_agg(s.value->>'slotId' order by s.ordinality)
      from jsonb_array_elements(coalesce(p_snapshot->'slots','[]'::jsonb)) with ordinality s(value,ordinality)
      where not exists(select 1 from assignment_rows a where a.slot_id=s.value->>'slotId')),'[]'::jsonb),
    'metrics',jsonb_build_object(
      'UNFILLED',(select count(*) from snapshot_slots s where not exists(
        select 1 from assignment_rows a where a.slot_id=s.slot_id)),
      'TOTAL_COST',coalesce((select sum(a.cost_units) from assignment_payload a),0)),
    'stageObjectives','[]'::jsonb,'optimal',false
  );
$$;

alter function solver_private.validate_variant_v2(jsonb,jsonb)
  rename to validate_variant_before_leader_limit_override_v2;

create function solver_private.validate_variant_v2(p_snapshot jsonb,p_variant jsonb)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_snapshot jsonb:=p_snapshot; v_employees jsonb;
begin
  if exists(select 1 from jsonb_array_elements(coalesce(p_variant->'assignments','[]'::jsonb)) assignment
      where coalesce((assignment.value->>'limitOverride')::boolean,false)) then
    select coalesce(jsonb_agg(case when exists(
      select 1 from jsonb_array_elements(coalesce(p_variant->'assignments','[]'::jsonb)) assignment
      where coalesce((assignment.value->>'limitOverride')::boolean,false)
        and assignment.value->>'employeeId'=employee.value->>'id'
    ) then employee.value||jsonb_build_object(
      'maximumMonthlyMinutes',2147483647,'maximumWeeklyMinutes',2147483647
    ) else employee.value end order by employee.ordinality),'[]'::jsonb)
    into v_employees
    from jsonb_array_elements(coalesce(p_snapshot->'employees','[]'::jsonb))
      with ordinality employee(value,ordinality);
    v_snapshot:=jsonb_set(v_snapshot,'{employees}',v_employees,true);
  end if;
  return solver_private.validate_variant_before_leader_limit_override_v2(v_snapshot,p_variant);
end;
$$;

alter function public.optimizer_variant_issue_diagnostics_uat_v2(uuid,bigint)
  rename to optimizer_variant_issue_diagnostics_before_profile_limits_uat_v2;

create function public.optimizer_variant_issue_diagnostics_uat_v2(p_variant_id uuid,p_issue_id bigint)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_payload jsonb; v_shift public.plan_shifts_v2%rowtype; v_matrix uuid; v_month date;
  v_duration integer; v_candidates jsonb:='[]'::jsonb; v_candidate jsonb; v_reasons text[];
  v_details jsonb; v_profile public.matrix_employee_profiles_v2%rowtype;
  v_monthly integer; v_weekly integer; v_daily integer; v_daily_limit integer; v_summary jsonb;
begin
  v_payload:=public.optimizer_variant_issue_diagnostics_before_profile_limits_uat_v2(p_variant_id,p_issue_id);
  select shift.* into v_shift
  from public.plan_issues_v2 issue
  join public.plan_shifts_v2 shift on shift.id=issue.shift_id
  join public.plan_variants_v2 variant on variant.id=issue.variant_id
  join public.optimization_runs_v2 run on run.id=variant.run_id
  where issue.id=p_issue_id and issue.variant_id=p_variant_id;
  if v_shift.id is null then raise exception 'UNFILLED_ISSUE_NOT_FOUND'; end if;
  select run.matrix_version_id,run.month into v_matrix,v_month
  from public.plan_variants_v2 variant
  join public.optimization_runs_v2 run on run.id=variant.run_id
  where variant.id=p_variant_id;
  v_duration:=extract(epoch from (v_shift.ends_at-v_shift.starts_at))/60;
  select greatest(1,coalesce(nullif(matrix.settings->>'maximumShiftsPerDay','')::integer,1))
    into v_daily_limit from public.matrix_versions matrix where matrix.id=v_matrix;

  for v_candidate in select candidate.value
    from jsonb_array_elements(coalesce(v_payload->'candidates','[]'::jsonb)) candidate(value)
  loop
    select * into v_profile from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=v_matrix
      and profile.employee_id=(v_candidate->>'employeeId')::uuid
      and profile.active and profile.archived_at is null;
    select coalesce(sum(extract(epoch from (shift.ends_at-shift.starts_at))/60),0)::integer,
      coalesce(sum(extract(epoch from (shift.ends_at-shift.starts_at))/60)
        filter(where shift.shift_date>=date_trunc('week',v_shift.shift_date)::date
          and shift.shift_date<date_trunc('week',v_shift.shift_date)::date+7),0)::integer,
      count(*) filter(where shift.shift_date=v_shift.shift_date)::integer
    into v_monthly,v_weekly,v_daily
    from public.plan_assignments_v2 assignment
    join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
    where assignment.variant_id=p_variant_id
      and assignment.employee_id=(v_candidate->>'employeeId')::uuid
      and shift.shift_date>=v_month and shift.shift_date<(v_month+interval '1 month')::date;
    select coalesce(array_agg(reason),array[]::text[]) into v_reasons
      from jsonb_array_elements_text(coalesce(v_candidate->'reasons','[]'::jsonb)) reason;
    if coalesce(v_profile.maximum_monthly_minutes,0)>0
      and v_monthly+v_duration>v_profile.maximum_monthly_minutes
      and not 'MONTHLY_LIMIT'=any(v_reasons) then v_reasons:=array_append(v_reasons,'MONTHLY_LIMIT'); end if;
    if coalesce(v_profile.maximum_weekly_minutes,0)>0
      and v_weekly+v_duration>v_profile.maximum_weekly_minutes
      and not 'WEEKLY_LIMIT'=any(v_reasons) then v_reasons:=array_append(v_reasons,'WEEKLY_LIMIT'); end if;
    select coalesce(jsonb_agg(detail.value),'[]'::jsonb) into v_details
    from jsonb_array_elements(coalesce(v_candidate->'blockingDetails','[]'::jsonb)) detail(value)
    where detail.value->>'code'<>'DAILY_SHIFT_LIMIT';
    if v_daily>=v_daily_limit then
      v_details:=v_details||jsonb_build_array(jsonb_build_object(
        'code','ONE_PRIMARY_SHIFT_PER_DAY','label',format(
          'Dzienny limit zmian: obecnie %s, limit %s',v_daily,v_daily_limit)));
    end if;
    if coalesce(v_profile.maximum_weekly_minutes,0)>0 and v_weekly+v_duration>v_profile.maximum_weekly_minutes then
      v_details:=v_details||jsonb_build_array(jsonb_build_object(
        'code','WEEKLY_LIMIT','label',format(
          'Limit tygodniowy: obecnie %s h + ta zmiana %s h = %s h, limit %s h',
          round(v_weekly/60.0,1),round(v_duration/60.0,1),round((v_weekly+v_duration)/60.0,1),
          round(v_profile.maximum_weekly_minutes/60.0,1))));
    end if;
    if coalesce(v_profile.maximum_monthly_minutes,0)>0 and v_monthly+v_duration>v_profile.maximum_monthly_minutes then
      v_details:=v_details||jsonb_build_array(jsonb_build_object(
        'code','MONTHLY_LIMIT','label',format(
          'Limit miesięczny: obecnie %s h + ta zmiana %s h = %s h, limit %s h',
          round(v_monthly/60.0,1),round(v_duration/60.0,1),round((v_monthly+v_duration)/60.0,1),
          round(v_profile.maximum_monthly_minutes/60.0,1))));
    end if;
    select coalesce(array_agg(distinct reason order by reason),array[]::text[]) into v_reasons
      from unnest(v_reasons) reason;
    v_candidate:=jsonb_set(v_candidate,'{reasons}',to_jsonb(v_reasons),true);
    v_candidate:=jsonb_set(v_candidate,'{blockingDetails}',v_details,true);
    v_candidates:=v_candidates||jsonb_build_array(v_candidate);
  end loop;
  select jsonb_build_object(
    'considered',jsonb_array_length(v_candidates),
    'eligible',count(*) filter(where jsonb_array_length(candidate.value->'reasons')=0),
    'blocked',count(*) filter(where jsonb_array_length(candidate.value->'reasons')>0),
    'reasons',coalesce((select jsonb_agg(jsonb_build_object('code',grouped.reason,'count',grouped.amount)
      order by grouped.amount desc,grouped.reason) from (
        select reason,count(*) amount from jsonb_array_elements(v_candidates) item
        cross join lateral jsonb_array_elements_text(item.value->'reasons') reason group by reason
      ) grouped),'[]'::jsonb)
  ) into v_summary from jsonb_array_elements(v_candidates) candidate;
  v_payload:=jsonb_set(jsonb_set(v_payload,'{candidates}',v_candidates,true),'{summary}',v_summary,true);
  if coalesce((v_summary->>'eligible')::integer,0)=0 then
    v_payload:=jsonb_set(v_payload,'{decisionContext}','null'::jsonb,true);
  end if;
  return v_payload;
end;
$$;

create function public.optimizer_leader_assignment_save_uat_v1(
  p_variant_id uuid,p_assignment_id uuid,p_issue_id bigint,p_employee_id uuid,
  p_reason text,p_allow_limit_override boolean
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_assignment public.plan_assignments_v2%rowtype;
  v_issue public.plan_issues_v2%rowtype; v_shift public.plan_shifts_v2%rowtype;
  v_run public.optimization_runs_v2%rowtype; v_profile public.matrix_employee_profiles_v2%rowtype;
  v_snapshot jsonb; v_slot jsonb; v_assignment_id uuid; v_reason text:=trim(coalesce(p_reason,''));
  v_duration integer; v_monthly integer; v_weekly integer; v_limit_details jsonb:='[]'::jsonb;
  v_explanation jsonb; v_limit_message text;
begin
  if length(v_reason)<3 then raise exception 'EDIT_REASON_REQUIRED'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then raise exception 'LEADER_VARIANT_NOT_EDITABLE'; end if;
  if (p_assignment_id is null)=(p_issue_id is null) then raise exception 'ASSIGNMENT_OR_ISSUE_REQUIRED'; end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-edit:'||p_variant_id::text,0));
  select run.* into v_run from public.plan_variants_v2 variant
    join public.optimization_runs_v2 run on run.id=variant.run_id where variant.id=p_variant_id;
  select snapshot into v_snapshot from solver_private.optimization_snapshots_v2 snapshot
    where snapshot.run_id=v_run.id;
  if p_assignment_id is not null then
    select * into v_assignment from public.plan_assignments_v2
      where id=p_assignment_id and variant_id=p_variant_id for update;
    if v_assignment.id is null then raise exception 'ASSIGNMENT_NOT_FOUND'; end if;
    select * into v_shift from public.plan_shifts_v2 where id=v_assignment.shift_id;
  else
    select * into v_issue from public.plan_issues_v2
      where id=p_issue_id and variant_id=p_variant_id and issue_code='UNFILLED_SLOT' for update;
    if v_issue.id is null then raise exception 'UNFILLED_ISSUE_NOT_FOUND'; end if;
    select * into v_shift from public.plan_shifts_v2 where id=v_issue.shift_id;
  end if;
  select * into v_profile from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=v_run.matrix_version_id and profile.employee_id=p_employee_id
      and profile.active and profile.archived_at is null;
  if v_profile.id is null then raise exception 'VARIANT_EMPLOYEE_ELIGIBILITY_INVALID'; end if;
  v_duration:=extract(epoch from (v_shift.ends_at-v_shift.starts_at))/60;
  select coalesce(sum(extract(epoch from (shift.ends_at-shift.starts_at))/60),0)::integer,
    coalesce(sum(extract(epoch from (shift.ends_at-shift.starts_at))/60)
      filter(where shift.shift_date>=date_trunc('week',v_shift.shift_date)::date
        and shift.shift_date<date_trunc('week',v_shift.shift_date)::date+7),0)::integer
  into v_monthly,v_weekly from public.plan_assignments_v2 assignment
  join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
  where assignment.variant_id=p_variant_id and assignment.employee_id=p_employee_id
    and (p_assignment_id is null or assignment.id<>p_assignment_id)
    and shift.shift_date>=v_run.month and shift.shift_date<(v_run.month+interval '1 month')::date;
  if coalesce(v_profile.maximum_weekly_minutes,0)>0 and v_weekly+v_duration>v_profile.maximum_weekly_minutes then
    v_limit_details:=v_limit_details||jsonb_build_array(jsonb_build_object(
      'code','WEEKLY_LIMIT','currentMinutes',v_weekly,'shiftMinutes',v_duration,
      'projectedMinutes',v_weekly+v_duration,'limitMinutes',v_profile.maximum_weekly_minutes));
  end if;
  if coalesce(v_profile.maximum_monthly_minutes,0)>0 and v_monthly+v_duration>v_profile.maximum_monthly_minutes then
    v_limit_details:=v_limit_details||jsonb_build_array(jsonb_build_object(
      'code','MONTHLY_LIMIT','currentMinutes',v_monthly,'shiftMinutes',v_duration,
      'projectedMinutes',v_monthly+v_duration,'limitMinutes',v_profile.maximum_monthly_minutes));
  end if;
  if jsonb_array_length(v_limit_details)>0 and not p_allow_limit_override then
    select string_agg(case detail.value->>'code'
      when 'WEEKLY_LIMIT' then format('Tydzień: %s h + %s h = %s h przy limicie %s h.',
        round((detail.value->>'currentMinutes')::numeric/60,1),round((detail.value->>'shiftMinutes')::numeric/60,1),
        round((detail.value->>'projectedMinutes')::numeric/60,1),round((detail.value->>'limitMinutes')::numeric/60,1))
      else format('Miesiąc: %s h + %s h = %s h przy limicie %s h.',
        round((detail.value->>'currentMinutes')::numeric/60,1),round((detail.value->>'shiftMinutes')::numeric/60,1),
        round((detail.value->>'projectedMinutes')::numeric/60,1),round((detail.value->>'limitMinutes')::numeric/60,1)) end,' ')
    into v_limit_message from jsonb_array_elements(v_limit_details) detail(value);
    raise exception 'LEADER_LIMIT_OVERRIDE_REQUIRED:%',v_limit_message;
  end if;
  v_explanation:=jsonb_build_object('edited',true,'editedBy',v_actor,'editedAt',now(),'reason',v_reason,
    'limitOverride',jsonb_array_length(v_limit_details)>0 and p_allow_limit_override,
    'limitOverrideDetails',v_limit_details);
  if p_assignment_id is not null then
    update public.plan_assignments_v2 set employee_id=p_employee_id,
      explanation=(coalesce(explanation,'{}'::jsonb)-'limitOverride'-'limitOverrideDetails')||v_explanation
      where id=v_assignment.id returning id into v_assignment_id;
  else
    insert into public.plan_assignments_v2(variant_id,shift_id,slot_key,employee_id,role_id,locked,explanation)
    values(p_variant_id,v_issue.shift_id,v_issue.slot_key,p_employee_id,v_issue.role_id,false,
      v_explanation||jsonb_build_object('filledIssueId',v_issue.id)) returning id into v_assignment_id;
    select slot.value into v_slot from jsonb_array_elements(coalesce(v_snapshot->'slots','[]'::jsonb)) slot
      where slot.value->>'slotId'=v_issue.slot_key;
    insert into public.plan_assignment_duties_v2(assignment_id,duty_id)
    select v_assignment_id,(duty.value#>>'{}')::uuid
      from jsonb_array_elements(coalesce(v_slot->'dutyIds','[]'::jsonb)) duty;
    delete from public.plan_issues_v2 where id=v_issue.id;
  end if;
  return solver_private.refresh_leader_variant_uat_v1(p_variant_id,v_actor,v_reason)
    ||jsonb_build_object('assignmentId',v_assignment_id,'limitOverride',
      jsonb_array_length(v_limit_details)>0 and p_allow_limit_override,'limitOverrideDetails',v_limit_details);
end;
$$;

revoke all on function solver_private.validate_variant_before_leader_limit_override_v2(jsonb,jsonb),
  solver_private.validate_variant_v2(jsonb,jsonb) from public,anon,authenticated;
grant execute on function solver_private.validate_variant_before_leader_limit_override_v2(jsonb,jsonb),
  solver_private.validate_variant_v2(jsonb,jsonb) to service_role;
revoke all on function public.optimizer_variant_issue_diagnostics_before_profile_limits_uat_v2(uuid,bigint),
  public.optimizer_variant_issue_diagnostics_uat_v2(uuid,bigint),
  public.optimizer_leader_assignment_save_uat_v1(uuid,uuid,bigint,uuid,text,boolean)
  from public,anon,authenticated;
grant execute on function public.optimizer_variant_issue_diagnostics_uat_v2(uuid,bigint),
  public.optimizer_leader_assignment_save_uat_v1(uuid,uuid,bigint,uuid,text),
  public.optimizer_leader_assignment_save_uat_v1(uuid,uuid,bigint,uuid,text,boolean) to authenticated;

comment on function public.optimizer_leader_assignment_save_uat_v1(uuid,uuid,bigint,uuid,text,boolean) is
  'Validates the complete leader copy. Weekly/monthly limits require an explicit audited override; all other hard rules remain non-overridable.';

notify pgrst,'reload schema';
