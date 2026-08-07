-- Keep the explanation and manual-override path on exactly the same hard
-- assignment rules as the worker: configured daily shift limit, no last(D) ->
-- first(D+1), and no ordinary assignment while the employee is published as
-- Tier 1/Tier 2 stand-by.

create or replace function solver_private.shift_template_is_sequence_edge_uat_v2(
  p_matrix_version_id uuid,
  p_shift_template_id uuid,
  p_shift_date date,
  p_edge text
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  with target as (
    select template.*
    from public.matrix_shift_templates_v2 template
    where template.id=p_shift_template_id
      and template.matrix_version_id=p_matrix_version_id
      and template.active
  )
  select coalesce(case upper(p_edge)
    when 'FIRST' then not exists(
      select 1 from target
      join public.matrix_shift_templates_v2 other
        on other.matrix_version_id=target.matrix_version_id
       and other.location_id=target.location_id
       and other.active
       and extract(isodow from p_shift_date)::smallint=any(other.day_mask)
       and (other.sort_order,other.starts_at,other.id)
         < (target.sort_order,target.starts_at,target.id)
    )
    when 'LAST' then not exists(
      select 1 from target
      join public.matrix_shift_templates_v2 other
        on other.matrix_version_id=target.matrix_version_id
       and other.location_id=target.location_id
       and other.active
       and extract(isodow from p_shift_date)::smallint=any(other.day_mask)
       and (other.sort_order,other.starts_at,other.id)
         > (target.sort_order,target.starts_at,target.id)
    )
    else false end,false)
  from target;
$$;

create or replace function solver_private.variant_primary_conflict_reasons_uat_v2(
  p_variant_id uuid,
  p_employee_id uuid,
  p_shift_id uuid
) returns text[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_shift public.plan_shifts_v2%rowtype;
  v_matrix_version_id uuid;
  v_month date;
  v_reasons text[]:='{}'::text[];
  v_tier integer;
  v_maximum_shifts_per_day integer:=1;
begin
  select shift_row.* into v_shift
  from public.plan_shifts_v2 shift_row
  where shift_row.id=p_shift_id and shift_row.variant_id=p_variant_id;
  if v_shift.id is null then return array['SHIFT_NOT_FOUND']::text[]; end if;

  select run.matrix_version_id,run.month
  into v_matrix_version_id,v_month
  from public.plan_variants_v2 variant
  join public.optimization_runs_v2 run on run.id=variant.run_id
  where variant.id=p_variant_id;
  select coalesce(nullif(version.settings->>'maximumShiftsPerDay','')::integer,1)
  into v_maximum_shifts_per_day
  from public.matrix_versions_v2 version
  where version.id=v_matrix_version_id;

  if (
    select count(distinct assignment.shift_id)
    from public.plan_assignments_v2 assignment
    join public.plan_shifts_v2 assigned_shift on assigned_shift.id=assignment.shift_id
    where assignment.variant_id=p_variant_id
      and assignment.employee_id=p_employee_id
      and assigned_shift.shift_date=v_shift.shift_date
  )>=v_maximum_shifts_per_day then
    v_reasons:=array_append(v_reasons,'ONE_PRIMARY_SHIFT_PER_DAY');
  end if;

  if (
    solver_private.shift_template_is_sequence_edge_uat_v2(
      v_matrix_version_id,v_shift.shift_template_id,v_shift.shift_date,'FIRST'
    ) and exists(
      select 1
      from public.plan_assignments_v2 assignment
      join public.plan_shifts_v2 assigned_shift on assigned_shift.id=assignment.shift_id
      where assignment.variant_id=p_variant_id
        and assignment.employee_id=p_employee_id
        and assigned_shift.shift_date=v_shift.shift_date-1
        and solver_private.shift_template_is_sequence_edge_uat_v2(
          v_matrix_version_id,assigned_shift.shift_template_id,
          assigned_shift.shift_date,'LAST'
        )
    )
  ) or (
    solver_private.shift_template_is_sequence_edge_uat_v2(
      v_matrix_version_id,v_shift.shift_template_id,v_shift.shift_date,'LAST'
    ) and exists(
      select 1
      from public.plan_assignments_v2 assignment
      join public.plan_shifts_v2 assigned_shift on assigned_shift.id=assignment.shift_id
      where assignment.variant_id=p_variant_id
        and assignment.employee_id=p_employee_id
        and assigned_shift.shift_date=v_shift.shift_date+1
        and solver_private.shift_template_is_sequence_edge_uat_v2(
          v_matrix_version_id,assigned_shift.shift_template_id,
          assigned_shift.shift_date,'FIRST'
        )
    )
  ) then
    v_reasons:=array_append(v_reasons,'CONSECUTIVE_SHIFT_SEQUENCE');
  end if;

  select standby.tier into v_tier
  from public.published_standby_assignments_v2 standby
  where standby.month=v_month
    and standby.standby_date=v_shift.shift_date
    and standby.employee_id=p_employee_id
    and standby.status in ('PLANNED','ACTIVATED')
  order by standby.tier
  limit 1;
  if v_tier=1 then
    v_reasons:=array_append(v_reasons,'STANDBY_TIER_1_RESERVED');
  elsif v_tier=2 then
    v_reasons:=array_append(v_reasons,'STANDBY_TIER_2_RESERVED');
  end if;

  return v_reasons;
end;
$$;

create or replace function solver_private.schedule_primary_conflict_reasons_uat_v2(
  p_schedule_id uuid,
  p_employee_id uuid,
  p_shift_id uuid
) returns text[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_shift public.plan_shifts_v2%rowtype;
  v_matrix_version_id uuid;
  v_month date;
  v_reasons text[]:='{}'::text[];
  v_tier integer;
  v_maximum_shifts_per_day integer:=1;
begin
  select shift_row.* into v_shift
  from public.plan_shifts_v2 shift_row where shift_row.id=p_shift_id;
  select schedule.matrix_version_id,schedule.month
  into v_matrix_version_id,v_month
  from public.published_schedules_v2 schedule
  where schedule.id=p_schedule_id and schedule.status='PUBLISHED';
  select coalesce(nullif(version.settings->>'maximumShiftsPerDay','')::integer,1)
  into v_maximum_shifts_per_day
  from public.matrix_versions_v2 version
  where version.id=v_matrix_version_id;
  if v_shift.id is null or v_matrix_version_id is null then
    return array['SHIFT_NOT_FOUND']::text[];
  end if;

  if (
    with scheduled as (
      select assignment.employee_id,shift_row.shift_date,shift_row.id shift_id
      from public.published_schedule_variants_v2 link
      join public.plan_assignments_v2 assignment on assignment.variant_id=link.variant_id
      join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
      where link.schedule_id=p_schedule_id
      union all
      select override_row.employee_id,shift_row.shift_date,shift_row.id shift_id
      from public.operational_assignment_overrides_v2 override_row
      join public.plan_shifts_v2 shift_row on shift_row.id=override_row.shift_id
      where override_row.schedule_id=p_schedule_id and override_row.status='ACTIVE'
    )
    select count(distinct scheduled.shift_id) from scheduled
    where scheduled.employee_id=p_employee_id
      and scheduled.shift_date=v_shift.shift_date
  )>=v_maximum_shifts_per_day then
    v_reasons:=array_append(v_reasons,'ONE_PRIMARY_SHIFT_PER_DAY');
  end if;

  if (
    solver_private.shift_template_is_sequence_edge_uat_v2(
      v_matrix_version_id,v_shift.shift_template_id,v_shift.shift_date,'FIRST'
    ) and exists(
      with scheduled as (
        select assignment.employee_id,shift_row.shift_date,shift_row.shift_template_id
        from public.published_schedule_variants_v2 link
        join public.plan_assignments_v2 assignment on assignment.variant_id=link.variant_id
        join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
        where link.schedule_id=p_schedule_id
        union all
        select override_row.employee_id,shift_row.shift_date,shift_row.shift_template_id
        from public.operational_assignment_overrides_v2 override_row
        join public.plan_shifts_v2 shift_row on shift_row.id=override_row.shift_id
        where override_row.schedule_id=p_schedule_id and override_row.status='ACTIVE'
      )
      select 1 from scheduled
      where scheduled.employee_id=p_employee_id
        and scheduled.shift_date=v_shift.shift_date-1
        and solver_private.shift_template_is_sequence_edge_uat_v2(
          v_matrix_version_id,scheduled.shift_template_id,scheduled.shift_date,'LAST'
        )
    )
  ) or (
    solver_private.shift_template_is_sequence_edge_uat_v2(
      v_matrix_version_id,v_shift.shift_template_id,v_shift.shift_date,'LAST'
    ) and exists(
      with scheduled as (
        select assignment.employee_id,shift_row.shift_date,shift_row.shift_template_id
        from public.published_schedule_variants_v2 link
        join public.plan_assignments_v2 assignment on assignment.variant_id=link.variant_id
        join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
        where link.schedule_id=p_schedule_id
        union all
        select override_row.employee_id,shift_row.shift_date,shift_row.shift_template_id
        from public.operational_assignment_overrides_v2 override_row
        join public.plan_shifts_v2 shift_row on shift_row.id=override_row.shift_id
        where override_row.schedule_id=p_schedule_id and override_row.status='ACTIVE'
      )
      select 1 from scheduled
      where scheduled.employee_id=p_employee_id
        and scheduled.shift_date=v_shift.shift_date+1
        and solver_private.shift_template_is_sequence_edge_uat_v2(
          v_matrix_version_id,scheduled.shift_template_id,scheduled.shift_date,'FIRST'
        )
    )
  ) then
    v_reasons:=array_append(v_reasons,'CONSECUTIVE_SHIFT_SEQUENCE');
  end if;

  select standby.tier into v_tier
  from public.published_standby_assignments_v2 standby
  where standby.month=v_month
    and standby.standby_date=v_shift.shift_date
    and standby.employee_id=p_employee_id
    and standby.status in ('PLANNED','ACTIVATED')
  order by standby.tier
  limit 1;
  if v_tier=1 then
    v_reasons:=array_append(v_reasons,'STANDBY_TIER_1_RESERVED');
  elsif v_tier=2 then
    v_reasons:=array_append(v_reasons,'STANDBY_TIER_2_RESERVED');
  end if;

  return v_reasons;
end;
$$;

alter function public.optimizer_variant_issue_diagnostics_uat_v2(uuid,bigint)
  rename to optimizer_variant_issue_diagnostics_before_primary_rules_uat_v2;

create function public.optimizer_variant_issue_diagnostics_uat_v2(
  p_variant_id uuid,
  p_issue_id bigint
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_payload jsonb;
  v_candidates jsonb:='[]'::jsonb;
  v_candidate jsonb;
  v_reasons text[];
  v_extra text[];
  v_shift_id uuid;
  v_schedule_id uuid;
  v_summary jsonb;
begin
  v_payload:=public.optimizer_variant_issue_diagnostics_before_primary_rules_uat_v2(
    p_variant_id,p_issue_id
  );
  select issue.shift_id into v_shift_id
  from public.plan_issues_v2 issue
  where issue.id=p_issue_id and issue.variant_id=p_variant_id;
  select schedule.id into v_schedule_id
  from public.published_schedules_v2 schedule
  join public.published_schedule_variants_v2 link
    on link.schedule_id=schedule.id and link.variant_id=p_variant_id
  where schedule.status='PUBLISHED'
  order by schedule.published_at desc
  limit 1;

  for v_candidate in
    select candidate.value
    from jsonb_array_elements(coalesce(v_payload->'candidates','[]'::jsonb)) candidate
  loop
    select coalesce(array_agg(reason),array[]::text[]) into v_reasons
    from jsonb_array_elements_text(coalesce(v_candidate->'reasons','[]'::jsonb)) reason;
    v_extra:=solver_private.variant_primary_conflict_reasons_uat_v2(
      p_variant_id,(v_candidate->>'employeeId')::uuid,v_shift_id
    );
    if 'ONE_PRIMARY_SHIFT_PER_DAY'=any(v_extra) then
      v_reasons:=array_remove(v_reasons,'SHIFT_OVERLAP');
    end if;
    select coalesce(array_agg(distinct reason order by reason),array[]::text[])
    into v_reasons
    from unnest(v_reasons||v_extra) reason;
    v_candidate:=jsonb_set(v_candidate,'{reasons}',to_jsonb(v_reasons),true);
    v_candidates:=v_candidates||jsonb_build_array(v_candidate);
  end loop;

  select jsonb_build_object(
    'considered',jsonb_array_length(v_candidates),
    'eligible',count(*) filter(where jsonb_array_length(candidate.value->'reasons')=0),
    'blocked',count(*) filter(where jsonb_array_length(candidate.value->'reasons')>0),
    'reasons',coalesce((
      select jsonb_agg(jsonb_build_object('code',grouped.reason,'count',grouped.amount)
        order by grouped.amount desc,grouped.reason)
      from (
        select reason,count(*) amount
        from jsonb_array_elements(v_candidates) item
        cross join lateral jsonb_array_elements_text(item.value->'reasons') reason
        group by reason
      ) grouped
    ),'[]'::jsonb)
  ) into v_summary
  from jsonb_array_elements(v_candidates) candidate;

  return jsonb_set(
    jsonb_set(
      jsonb_set(v_payload,'{candidates}',v_candidates,true),
      '{summary}',v_summary,true
    ),
    '{publishedScheduleId}',coalesce(to_jsonb(v_schedule_id),'null'::jsonb),true
  );
end;
$$;

alter function public.optimizer_candidate_diagnostics_alpha16(uuid,bigint)
  rename to optimizer_candidate_diagnostics_before_primary_rules_alpha16;

create function public.optimizer_candidate_diagnostics_alpha16(
  p_schedule_id uuid,
  p_issue_id bigint
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_payload jsonb;
  v_candidates jsonb:='[]'::jsonb;
  v_candidate jsonb;
  v_hard text[];
  v_soft text[];
  v_extra text[];
  v_shift_id uuid;
  v_matrix_version_id uuid;
  v_contract text;
  v_policy text;
  v_classification text;
  v_summary jsonb;
begin
  v_payload:=public.optimizer_candidate_diagnostics_before_primary_rules_alpha16(
    p_schedule_id,p_issue_id
  );
  select issue.shift_id,schedule.matrix_version_id
  into v_shift_id,v_matrix_version_id
  from public.plan_issues_v2 issue
  join public.published_schedules_v2 schedule on schedule.id=p_schedule_id
  where issue.id=p_issue_id;

  for v_candidate in
    select candidate.value
    from jsonb_array_elements(coalesce(v_payload->'candidates','[]'::jsonb)) candidate
  loop
    select coalesce(array_agg(reason),array[]::text[]) into v_hard
    from jsonb_array_elements_text(coalesce(v_candidate->'hardReasons','[]'::jsonb)) reason;
    select coalesce(array_agg(reason),array[]::text[]) into v_soft
    from jsonb_array_elements_text(coalesce(v_candidate->'softReasons','[]'::jsonb)) reason;
    select coalesce(hr.contract_type,'INNE'),coalesce(profile.work_time_policy,'CONTRACT_DEFAULT')
    into v_contract,v_policy
    from public.matrix_employee_profiles_v2 profile
    left join public.employee_hr_profiles hr on hr.employee_id=profile.employee_id
    where profile.matrix_version_id=v_matrix_version_id
      and profile.employee_id=(v_candidate->>'employeeId')::uuid;
    if v_contract in ('ZLECENIE','B2B') and v_policy<>'CUSTOM' then
      v_hard:=array_remove(v_hard,'MONTHLY_LIMIT');
      v_hard:=array_remove(v_hard,'WEEKLY_LIMIT');
      v_hard:=array_remove(v_hard,'MAX_CONSECUTIVE_DAYS');
      v_hard:=array_remove(v_hard,'REST_AFTER_PREVIOUS_SHIFT');
      v_hard:=array_remove(v_hard,'REST_BEFORE_NEXT_SHIFT');
      v_soft:=array_remove(v_soft,'OVERTIME_AFTER_ASSIGNMENT');
    end if;
    v_extra:=solver_private.schedule_primary_conflict_reasons_uat_v2(
      p_schedule_id,(v_candidate->>'employeeId')::uuid,v_shift_id
    );
    if 'ONE_PRIMARY_SHIFT_PER_DAY'=any(v_extra) then
      v_hard:=array_remove(v_hard,'SHIFT_OVERLAP');
    end if;
    select coalesce(array_agg(distinct reason order by reason),array[]::text[])
    into v_hard from unnest(v_hard||v_extra) reason;
    v_classification:=case
      when cardinality(v_hard)>0 then 'BLOCKED'
      when cardinality(v_soft)>0 then 'WARNING'
      else 'ELIGIBLE'
    end;
    v_candidate:=jsonb_set(v_candidate,'{hardReasons}',to_jsonb(v_hard),true);
    v_candidate:=jsonb_set(v_candidate,'{softReasons}',to_jsonb(v_soft),true);
    v_candidate:=jsonb_set(v_candidate,'{classification}',to_jsonb(v_classification),true);
    v_candidates:=v_candidates||jsonb_build_array(v_candidate);
  end loop;

  select jsonb_build_object(
    'considered',jsonb_array_length(v_candidates),
    'eligible',count(*) filter(where candidate.value->>'classification'='ELIGIBLE'),
    'warning',count(*) filter(where candidate.value->>'classification'='WARNING'),
    'blocked',count(*) filter(where candidate.value->>'classification'='BLOCKED')
  ) into v_summary
  from jsonb_array_elements(v_candidates) candidate;

  return jsonb_set(
    jsonb_set(v_payload,'{candidates}',v_candidates,true),
    '{summary}',v_summary,true
  );
end;
$$;

revoke all on function solver_private.shift_template_is_sequence_edge_uat_v2(
  uuid,uuid,date,text
) from public,anon,authenticated;
revoke all on function solver_private.variant_primary_conflict_reasons_uat_v2(
  uuid,uuid,uuid
) from public,anon,authenticated;
revoke all on function solver_private.schedule_primary_conflict_reasons_uat_v2(
  uuid,uuid,uuid
) from public,anon,authenticated;
revoke all on function public.optimizer_variant_issue_diagnostics_before_primary_rules_uat_v2(
  uuid,bigint
) from public,anon,authenticated;
revoke all on function public.optimizer_candidate_diagnostics_before_primary_rules_alpha16(
  uuid,bigint
) from public,anon,authenticated;
revoke all on function public.optimizer_variant_issue_diagnostics_uat_v2(
  uuid,bigint
) from public,anon,authenticated;
revoke all on function public.optimizer_candidate_diagnostics_alpha16(
  uuid,bigint
) from public,anon,authenticated;
grant execute on function public.optimizer_variant_issue_diagnostics_uat_v2(
  uuid,bigint
) to authenticated;
grant execute on function public.optimizer_candidate_diagnostics_alpha16(
  uuid,bigint
) to authenticated;

comment on function public.optimizer_variant_issue_diagnostics_uat_v2(uuid,bigint) is
  'Explains an unfilled variant slot with current hard assignment and published stand-by reasons; exposes an operational schedule only when a safe audited correction path exists.';
comment on function public.optimizer_candidate_diagnostics_alpha16(uuid,bigint) is
  'Revalidates operational candidates with contract-aware limits, the configured daily shift limit, sequence order and stand-by reservations before any override.';
