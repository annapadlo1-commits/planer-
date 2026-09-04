-- GRAFIK PRO 3.0 -- Alpha 16 operational schedule, diagnostics and variants.

create table if not exists public.operational_assignment_overrides_v2 (
  id uuid primary key default gen_random_uuid(),
  schedule_id uuid not null
    references public.published_schedules_v2(id) on delete restrict,
  issue_id bigint not null references public.plan_issues_v2(id) on delete restrict,
  shift_id uuid not null references public.plan_shifts_v2(id) on delete restrict,
  slot_key text not null,
  employee_id uuid not null references public.employees(id) on delete restrict,
  role_id uuid not null references public.matrix_roles_v2(id) on delete restrict,
  status text not null default 'ACTIVE' check (status in ('ACTIVE','REVOKED')),
  assignment_class text not null
    check (assignment_class in ('ELIGIBLE','SOFT_OVERRIDE')),
  override_reason text,
  notify_employee boolean not null default false,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  revoked_by uuid references auth.users(id) on delete set null,
  revoked_at timestamptz,
  revoke_reason text,
  check (
    (status='ACTIVE' and revoked_at is null and revoked_by is null)
    or (status='REVOKED' and revoked_at is not null)
  ),
  check (assignment_class='ELIGIBLE' or length(trim(coalesce(override_reason,'')))>=3)
);

create unique index if not exists operational_assignment_overrides_v2_slot_active
  on public.operational_assignment_overrides_v2(schedule_id,slot_key)
  where status='ACTIVE';
create index if not exists operational_assignment_overrides_v2_employee_idx
  on public.operational_assignment_overrides_v2(employee_id,created_at desc);
create index if not exists operational_assignment_overrides_v2_issue_idx
  on public.operational_assignment_overrides_v2(issue_id);
create index if not exists operational_assignment_overrides_v2_shift_idx
  on public.operational_assignment_overrides_v2(shift_id);
create index if not exists operational_assignment_overrides_v2_role_idx
  on public.operational_assignment_overrides_v2(role_id);
create index if not exists operational_assignment_overrides_v2_created_by_idx
  on public.operational_assignment_overrides_v2(created_by);
create index if not exists operational_assignment_overrides_v2_revoked_by_idx
  on public.operational_assignment_overrides_v2(revoked_by)
  where revoked_by is not null;

alter table public.operational_assignment_overrides_v2 enable row level security;
drop policy if exists operational_assignment_overrides_v2_deny_direct
  on public.operational_assignment_overrides_v2;
create policy operational_assignment_overrides_v2_deny_direct
on public.operational_assignment_overrides_v2
for all to authenticated using(false) with check(false);
revoke all on table public.operational_assignment_overrides_v2
  from public,anon,authenticated;
grant all on table public.operational_assignment_overrides_v2 to service_role;

create or replace function solver_private.alpha16_can_manage_schedule_v2(
  p_schedule_id uuid
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_schedule_id is not null and (
    public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('VERIFIER')
    or exists(
      select 1
      from public.published_schedule_variants_v2 link
      join public.plan_variants_v2 variant on variant.id=link.variant_id
      join public.optimization_runs_v2 run on run.id=variant.run_id
      join public.matrix_roles_v2 role on role.id=run.scope_role_id
      join public.matrix_scope_grants_v2 grant_row
        on grant_row.auth_user_id=auth.uid() and grant_row.active
        and grant_row.app_role='ROLE_MANAGER'
        and (grant_row.role_logical_id is null
          or grant_row.role_logical_id=role.logical_id)
      where link.schedule_id=p_schedule_id
    )
  );
$$;

create or replace function solver_private.alpha16_enrich_workspace_issues_v2(
  p_workspace jsonb,
  p_variant_ids uuid[]
) returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_set(
    coalesce(p_workspace,'{}'::jsonb),
    '{issues}',
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',issue.id,
        'variantId',issue.variant_id,
        'slotKey',issue.slot_key,
        'code',issue.issue_code,
        'severity',issue.severity,
        'message',issue.message,
        'requiredCount',issue.required_count,
        'assignedCount',issue.assigned_count,
        'metadata',issue.metadata,
        'role',case when role.id is null then null else
          jsonb_build_object('id',role.id,'name',role.name) end,
        'duty',case when duty.id is null then null else
          jsonb_build_object('id',duty.id,'name',duty.name) end,
        'shift',case when shift_row.id is null then null else
          jsonb_build_object(
            'id',shift_row.id,
            'date',shift_row.shift_date,
            'startsAt',shift_row.starts_at,
            'endsAt',shift_row.ends_at,
            'location',jsonb_build_object(
              'id',location.id,'name',location.name,'timezone',location.timezone
            ),
            'shiftTemplate',jsonb_build_object(
              'id',template.id,'name',template.name,'shiftPeriod',template.shift_period
            )
          ) end
      ) order by shift_row.starts_at nulls last,issue.severity desc,issue.id)
      from public.plan_issues_v2 issue
      left join public.plan_shifts_v2 shift_row on shift_row.id=issue.shift_id
      left join public.matrix_locations_v2 location on location.id=shift_row.location_id
      left join public.matrix_shift_templates_v2 template
        on template.id=shift_row.shift_template_id
      left join public.matrix_roles_v2 role on role.id=issue.role_id
      left join public.matrix_duties_v2 duty on duty.id=issue.duty_id
      where issue.variant_id=any(coalesce(p_variant_ids,'{}'::uuid[]))
    ),'[]'::jsonb),
    true
  );
$$;

create or replace function public.optimizer_selected_variant_workspace_alpha16(
  p_run_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_workspace jsonb;
  v_variant_ids uuid[];
begin
  v_workspace:=public.optimizer_selected_variant_workspace_v2(p_run_id);
  select array_agg(variant.id order by variant.id)
  into v_variant_ids
  from public.plan_variants_v2 variant
  where variant.run_id=p_run_id and variant.selected;
  return solver_private.alpha16_enrich_workspace_issues_v2(
    v_workspace,v_variant_ids
  );
end;
$$;

create or replace function public.optimizer_published_schedule_alpha16(
  p_schedule_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_workspace jsonb;
  v_variant_ids uuid[];
begin
  v_workspace:=public.optimizer_published_schedule_v2(p_schedule_id);
  select array_agg(link.variant_id order by link.ordinal)
  into v_variant_ids
  from public.published_schedule_variants_v2 link
  where link.schedule_id=p_schedule_id;
  return solver_private.alpha16_enrich_workspace_issues_v2(
    v_workspace,v_variant_ids
  );
end;
$$;

create or replace function public.optimizer_candidate_diagnostics_alpha16(
  p_schedule_id uuid,
  p_issue_id bigint
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_schedule public.published_schedules_v2%rowtype;
  v_issue public.plan_issues_v2%rowtype;
  v_shift public.plan_shifts_v2%rowtype;
  v_shift_period text;
  v_timezone text;
  v_minimum_rest integer;
  v_candidates jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not solver_private.alpha16_can_manage_schedule_v2(p_schedule_id) then
    raise exception 'FORBIDDEN';
  end if;
  select * into v_schedule from public.published_schedules_v2 schedule
  where schedule.id=p_schedule_id and schedule.status='PUBLISHED';
  if v_schedule.id is null then raise exception 'PUBLISHED_SCHEDULE_NOT_FOUND'; end if;
  select issue.* into v_issue
  from public.plan_issues_v2 issue
  join public.published_schedule_variants_v2 link
    on link.schedule_id=v_schedule.id and link.variant_id=issue.variant_id
  where issue.id=p_issue_id and issue.issue_code='UNFILLED_SLOT';
  if v_issue.id is null then raise exception 'UNFILLED_ISSUE_NOT_FOUND'; end if;
  select shift_row.* into v_shift from public.plan_shifts_v2 shift_row
  where shift_row.id=v_issue.shift_id;
  if v_shift.id is null then raise exception 'SHIFT_NOT_FOUND'; end if;
  select template.shift_period,location.timezone into v_shift_period,v_timezone
  from public.matrix_shift_templates_v2 template
  join public.matrix_locations_v2 location on location.id=template.location_id
  where template.id=v_shift.shift_template_id;
  select coalesce((matrix.settings->>'minimumRestMinutes')::integer,660)
  into v_minimum_rest
  from public.matrix_versions matrix where matrix.id=v_schedule.matrix_version_id;

  with schedule_variants as (
    select link.variant_id
    from public.published_schedule_variants_v2 link
    where link.schedule_id=v_schedule.id
  ), scheduled as (
    select assignment.employee_id,shift_row.starts_at,shift_row.ends_at,
      shift_row.shift_date
    from public.plan_assignments_v2 assignment
    join schedule_variants variant on variant.variant_id=assignment.variant_id
    join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
    union all
    select override_row.employee_id,shift_row.starts_at,shift_row.ends_at,
      shift_row.shift_date
    from public.operational_assignment_overrides_v2 override_row
    join public.plan_shifts_v2 shift_row on shift_row.id=override_row.shift_id
    where override_row.schedule_id=v_schedule.id and override_row.status='ACTIVE'
  ), profiles as (
    select profile.*,
      coalesce(profile.minimum_rest_minutes,v_minimum_rest) rest_minutes
    from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=v_schedule.matrix_version_id
      and profile.active and profile.archived_at is null
      and (profile.employment_start is null
        or profile.employment_start<=v_shift.shift_date)
      and (profile.employment_end is null
        or profile.employment_end>=v_shift.shift_date)
  ), candidate_base as (
    select profile.*,
      exists(select 1 from public.matrix_employee_roles_v2 grant_row
        where grant_row.matrix_version_id=v_schedule.matrix_version_id
          and grant_row.employee_id=profile.employee_id
          and grant_row.role_id=v_issue.role_id and grant_row.active
          and (grant_row.valid_from is null or grant_row.valid_from<=v_shift.shift_date)
          and (grant_row.valid_to is null or grant_row.valid_to>=v_shift.shift_date)
      ) role_ok,
      exists(select 1 from public.matrix_employee_locations_v2 grant_row
        where grant_row.matrix_version_id=v_schedule.matrix_version_id
          and grant_row.employee_id=profile.employee_id
          and grant_row.location_id=v_shift.location_id and grant_row.active
          and grant_row.standard_allowed
          and (grant_row.valid_from is null or grant_row.valid_from<=v_shift.shift_date)
          and (grant_row.valid_to is null or grant_row.valid_to>=v_shift.shift_date)
      ) location_ok,
      v_issue.duty_id is null or exists(
        select 1 from public.matrix_employee_duties_v2 grant_row
        where grant_row.matrix_version_id=v_schedule.matrix_version_id
          and grant_row.employee_id=profile.employee_id
          and grant_row.duty_id=v_issue.duty_id and grant_row.active
          and (grant_row.role_id is null or grant_row.role_id=v_issue.role_id)
          and (grant_row.location_id is null or grant_row.location_id=v_shift.location_id)
          and (grant_row.valid_from is null or grant_row.valid_from<=v_shift.shift_date)
          and (grant_row.valid_to is null or grant_row.valid_to>=v_shift.shift_date)
      ) duty_ok,
      exists(select 1 from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and tstzrange(assignment.starts_at,assignment.ends_at,'[)')
            && tstzrange(v_shift.starts_at,v_shift.ends_at,'[)')) overlap,
      exists(select 1 from public.employee_time_constraints_v2 constraint_row
        where constraint_row.employee_id=profile.employee_id
          and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
          and constraint_row.time_range
            && tstzrange(v_shift.starts_at,v_shift.ends_at,'[)')) blocked_time,
      (
        exists(select 1 from public.employee_time_constraints_v2 constraint_row
          where constraint_row.employee_id=profile.employee_id
            and constraint_row.status='ACTIVE'
            and constraint_row.constraint_kind='AVAILABLE_WINDOW'
            and lower(constraint_row.time_range)<(v_shift.shift_date+1)::timestamp
              at time zone v_timezone
            and upper(constraint_row.time_range)>v_shift.shift_date::timestamp
              at time zone v_timezone)
        and not exists(select 1 from public.employee_time_constraints_v2 constraint_row
          where constraint_row.employee_id=profile.employee_id
            and constraint_row.status='ACTIVE'
            and constraint_row.constraint_kind='AVAILABLE_WINDOW'
            and lower(constraint_row.time_range)<=v_shift.starts_at
            and upper(constraint_row.time_range)>=v_shift.ends_at)
      ) outside_available_window,
      coalesce(solver_private.alpha16_preference_level_v2(
        profile.employee_id,v_schedule.matrix_version_id,v_schedule.month,v_shift_period
      ),case
        when profile.only_morning and v_shift_period<>'MORNING' then 'BLOCKED'
        when profile.only_evening and v_shift_period<>'EVENING' then 'BLOCKED'
        else 'NEUTRAL' end) preference_level,
      coalesce((select sum(extract(epoch from
        (assignment.ends_at-assignment.starts_at))/60)::integer
        from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and assignment.shift_date>=v_schedule.month
          and assignment.shift_date<(v_schedule.month+interval '1 month')::date),0)
        monthly_minutes,
      coalesce((select count(*) from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and assignment.shift_date>=v_schedule.month
          and assignment.shift_date<(v_schedule.month+interval '1 month')::date),0)
        monthly_shifts,
      coalesce((select sum(extract(epoch from
        (assignment.ends_at-assignment.starts_at))/60)::integer
        from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and assignment.shift_date>=date_trunc('week',v_shift.shift_date)::date
          and assignment.shift_date<date_trunc('week',v_shift.shift_date)::date+7),0)
        weekly_minutes,
      (select jsonb_build_object('date',assignment.shift_date,
          'startsAt',assignment.starts_at,'endsAt',assignment.ends_at)
        from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and assignment.ends_at<=v_shift.starts_at
        order by assignment.ends_at desc limit 1) previous_shift,
      (select jsonb_build_object('date',assignment.shift_date,
          'startsAt',assignment.starts_at,'endsAt',assignment.ends_at)
        from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and assignment.starts_at>=v_shift.ends_at
        order by assignment.starts_at limit 1) next_shift,
      exists(select 1 from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and assignment.shift_date=v_shift.shift_date-1) works_previous_day,
      exists(select 1 from scheduled assignment
        where assignment.employee_id=profile.employee_id
          and assignment.shift_date=v_shift.shift_date+1) works_next_day,
      coalesce((select min(day_offset.value)-1
        from generate_series(1,31) day_offset(value)
        where not exists(select 1 from scheduled assignment
          where assignment.employee_id=profile.employee_id
            and assignment.shift_date=v_shift.shift_date-day_offset.value)),31)
        consecutive_days_before,
      coalesce((select min(day_offset.value)-1
        from generate_series(1,31) day_offset(value)
        where not exists(select 1 from scheduled assignment
          where assignment.employee_id=profile.employee_id
            and assignment.shift_date=v_shift.shift_date+day_offset.value)),31)
        consecutive_days_after
    from profiles profile
  ), evaluated as (
    select candidate.*,
      extract(epoch from (v_shift.ends_at-v_shift.starts_at))/60 target_minutes,
      candidate.consecutive_days_before+1+candidate.consecutive_days_after
        projected_consecutive_days,
      candidate.previous_shift is not null and
        extract(epoch from (v_shift.starts_at-
          (candidate.previous_shift->>'endsAt')::timestamptz))/60
          <candidate.rest_minutes previous_rest_conflict,
      candidate.next_shift is not null and
        extract(epoch from ((candidate.next_shift->>'startsAt')::timestamptz-
          v_shift.ends_at))/60<candidate.rest_minutes next_rest_conflict
    from candidate_base candidate
  ), classified as (
    select candidate.*,
      array_remove(array[
        case when not candidate.role_ok then 'ROLE_REQUIRED' end,
        case when not candidate.location_ok then 'LOCATION_NOT_ALLOWED' end,
        case when not candidate.duty_ok then 'DUTY_REQUIRED' end,
        case when candidate.overlap then 'SHIFT_OVERLAP' end,
        case when candidate.blocked_time then 'DECLARED_UNAVAILABLE' end,
        case when candidate.outside_available_window then 'OUTSIDE_AVAILABILITY_WINDOW' end,
        case when candidate.previous_rest_conflict then 'REST_AFTER_PREVIOUS_SHIFT' end,
        case when candidate.next_rest_conflict then 'REST_BEFORE_NEXT_SHIFT' end,
        case when candidate.monthly_minutes+candidate.target_minutes>
          candidate.maximum_monthly_minutes then 'MONTHLY_LIMIT' end,
        case when candidate.weekly_minutes+candidate.target_minutes>
          candidate.maximum_weekly_minutes then 'WEEKLY_LIMIT' end,
        case when candidate.projected_consecutive_days>
          candidate.maximum_consecutive_days then 'MAX_CONSECUTIVE_DAYS' end,
        case when candidate.preference_level='BLOCKED' then 'MANAGER_SHIFT_BLOCK' end
      ]::text[],null) hard_reasons,
      array_remove(array[
        case when candidate.preference_level='AVOIDED' then 'SHIFT_PREFERENCE_AVOIDED' end,
        case when candidate.monthly_minutes+candidate.target_minutes>
          candidate.nominal_monthly_minutes then 'OVERTIME_AFTER_ASSIGNMENT' end
      ]::text[],null) soft_reasons
    from evaluated candidate
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'employeeId',candidate.employee_id,
    'employeeNo',candidate.employee_no,
    'name',candidate.first_name||' '||candidate.last_name,
    'classification',case
      when cardinality(candidate.hard_reasons)>0 then 'BLOCKED'
      when cardinality(candidate.soft_reasons)>0 then 'WARNING'
      else 'ELIGIBLE' end,
    'hardReasons',to_jsonb(candidate.hard_reasons),
    'softReasons',to_jsonb(candidate.soft_reasons),
    'preferenceLevel',candidate.preference_level,
    'monthlyShifts',candidate.monthly_shifts,
    'monthlyMinutes',candidate.monthly_minutes,
    'nominalMonthlyMinutes',candidate.nominal_monthly_minutes,
    'maximumMonthlyMinutes',candidate.maximum_monthly_minutes,
    'weeklyMinutes',candidate.weekly_minutes,
    'maximumWeeklyMinutes',candidate.maximum_weekly_minutes,
    'consecutiveDaysBefore',candidate.consecutive_days_before,
    'consecutiveDaysAfter',candidate.consecutive_days_after,
    'projectedConsecutiveDays',candidate.projected_consecutive_days,
    'maximumConsecutiveDays',candidate.maximum_consecutive_days,
    'declaredUnavailable',candidate.blocked_time,
    'outsideAvailableWindow',candidate.outside_available_window,
    'worksPreviousDay',candidate.works_previous_day,
    'worksNextDay',candidate.works_next_day,
    'previousShift',candidate.previous_shift,
    'nextShift',candidate.next_shift
  ) order by
    case when cardinality(candidate.hard_reasons)=0
      and cardinality(candidate.soft_reasons)=0 then 0
      when cardinality(candidate.hard_reasons)=0 then 1 else 2 end,
    candidate.monthly_minutes,candidate.last_name,candidate.first_name
  ),'[]'::jsonb) into v_candidates
  from classified candidate;

  return jsonb_build_object(
    'scheduleId',v_schedule.id,
    'issue',jsonb_build_object(
      'id',v_issue.id,'code',v_issue.issue_code,'message',v_issue.message,
      'slotKey',v_issue.slot_key,'roleId',v_issue.role_id,'dutyId',v_issue.duty_id
    ),
    'shift',jsonb_build_object(
      'id',v_shift.id,'slotGroupKey',v_shift.slot_group_key,
      'date',v_shift.shift_date,'startsAt',v_shift.starts_at,
      'endsAt',v_shift.ends_at,'locationId',v_shift.location_id,
      'shiftTemplateId',v_shift.shift_template_id,'shiftPeriod',v_shift_period
    ),
    'candidates',v_candidates,
    'summary',jsonb_build_object(
      'considered',jsonb_array_length(v_candidates),
      'eligible',(select count(*) from jsonb_array_elements(v_candidates) row
        where row.value->>'classification'='ELIGIBLE'),
      'warning',(select count(*) from jsonb_array_elements(v_candidates) row
        where row.value->>'classification'='WARNING'),
      'blocked',(select count(*) from jsonb_array_elements(v_candidates) row
        where row.value->>'classification'='BLOCKED')
    )
  );
end;
$$;

create or replace function public.optimizer_operational_workspace_alpha16(
  p_month date
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_month date:=date_trunc('month',p_month)::date;
  v_schedule uuid;
  v_workspace jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select schedule.id into v_schedule
  from public.published_schedules_v2 schedule
  where schedule.month=v_month and schedule.status='PUBLISHED'
  order by schedule.published_at desc limit 1;
  if v_schedule is null then
    return jsonb_build_object('scheduleId',null,'workspace',null,'overrides','[]'::jsonb);
  end if;
  if not solver_private.alpha16_can_manage_schedule_v2(v_schedule) then
    raise exception 'FORBIDDEN';
  end if;
  v_workspace:=public.optimizer_published_schedule_alpha16(v_schedule);
  return jsonb_build_object(
    'scheduleId',v_schedule,'workspace',v_workspace,
    'overrides',coalesce((select jsonb_agg(jsonb_build_object(
      'id',override_row.id,'issueId',override_row.issue_id,
      'variantId',issue.variant_id,
      'slotKey',override_row.slot_key,'shiftId',override_row.shift_id,
      'slotGroupKey',shift_row.slot_group_key,
      'classification',override_row.assignment_class,
      'reason',override_row.override_reason,
      'createdAt',override_row.created_at,
      'employee',jsonb_build_object(
        'id',profile.employee_id,'employeeNo',profile.employee_no,
        'firstName',profile.first_name,'lastName',profile.last_name,
        'nominalMonthlyMinutes',profile.nominal_monthly_minutes
      ),
      'role',jsonb_build_object('id',role.id,'name',role.name),
      'duties',case when issue.duty_id is null then '[]'::jsonb else
        jsonb_build_array(jsonb_build_object('id',duty.id,'name',duty.name)) end
    ) order by override_row.created_at,override_row.id)
      from public.operational_assignment_overrides_v2 override_row
      join public.plan_shifts_v2 shift_row on shift_row.id=override_row.shift_id
      join public.matrix_employee_profiles_v2 profile
        on profile.matrix_version_id=(select schedule.matrix_version_id
          from public.published_schedules_v2 schedule where schedule.id=v_schedule)
        and profile.employee_id=override_row.employee_id
      join public.matrix_roles_v2 role on role.id=override_row.role_id
      join public.plan_issues_v2 issue on issue.id=override_row.issue_id
      left join public.matrix_duties_v2 duty on duty.id=issue.duty_id
      where override_row.schedule_id=v_schedule and override_row.status='ACTIVE'
    ),'[]'::jsonb)
  );
end;
$$;

create or replace function public.optimizer_emergency_assign_alpha16(
  p_schedule_id uuid,
  p_issue_id bigint,
  p_employee_id uuid,
  p_allow_soft boolean default false,
  p_reason text default null,
  p_notify boolean default false
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_diagnostics jsonb;
  v_candidate jsonb;
  v_issue public.plan_issues_v2%rowtype;
  v_id uuid;
  v_class text;
  v_auth_user uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not solver_private.alpha16_can_manage_schedule_v2(p_schedule_id) then
    raise exception 'FORBIDDEN';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(
    'operational-v2:'||p_schedule_id::text||':'||p_issue_id::text,0
  ));
  v_diagnostics:=public.optimizer_candidate_diagnostics_alpha16(
    p_schedule_id,p_issue_id
  );
  select candidate.value into v_candidate
  from jsonb_array_elements(v_diagnostics->'candidates') candidate
  where candidate.value->>'employeeId'=p_employee_id::text;
  if v_candidate is null then raise exception 'CANDIDATE_NOT_FOUND'; end if;
  v_class:=v_candidate->>'classification';
  if v_class='BLOCKED' then
    raise exception 'EMERGENCY_ASSIGNMENT_HARD_BLOCK:%',
      coalesce(v_candidate->'hardReasons','[]'::jsonb)::text;
  end if;
  if v_class='WARNING' and (
    not coalesce(p_allow_soft,false)
    or length(trim(coalesce(p_reason,'')))<3
  ) then raise exception 'SOFT_OVERRIDE_REASON_REQUIRED'; end if;
  select issue.* into v_issue from public.plan_issues_v2 issue
  where issue.id=p_issue_id;
  if exists(select 1 from public.operational_assignment_overrides_v2 existing
    where existing.schedule_id=p_schedule_id and existing.slot_key=v_issue.slot_key
      and existing.status='ACTIVE') then raise exception 'SLOT_ALREADY_FILLED'; end if;
  insert into public.operational_assignment_overrides_v2(
    schedule_id,issue_id,shift_id,slot_key,employee_id,role_id,
    assignment_class,override_reason,notify_employee,created_by
  ) values(
    p_schedule_id,p_issue_id,v_issue.shift_id,v_issue.slot_key,p_employee_id,
    v_issue.role_id,case when v_class='WARNING' then 'SOFT_OVERRIDE' else 'ELIGIBLE' end,
    case when v_class='WARNING' then trim(p_reason) else null end,
    coalesce(p_notify,false),auth.uid()
  ) returning id into v_id;
  select employee.auth_user_id into v_auth_user
  from public.employees employee where employee.id=p_employee_id;
  if coalesce(p_notify,false) and v_auth_user is not null then
    insert into public.notifications(recipient_id,channel,title,body)
    values(v_auth_user,'IN_APP','Awaryjna zmiana',
      'Dopisano Cię do zmiany dnia '||
      (v_diagnostics->'shift'->>'date')||'.');
  end if;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'operational_assignment_override_v2',v_id::text,'CREATE',
    jsonb_build_object(
      'scheduleId',p_schedule_id,'issueId',p_issue_id,
      'employeeId',p_employee_id,'classification',v_class,
      'reason',case when v_class='WARNING' then trim(p_reason) else null end,
      'notified',coalesce(p_notify,false) and v_auth_user is not null
    ));
  return jsonb_build_object(
    'id',v_id,'scheduleId',p_schedule_id,'issueId',p_issue_id,
    'employeeId',p_employee_id,'classification',v_class,
    'notified',coalesce(p_notify,false) and v_auth_user is not null
  );
end;
$$;

create or replace function public.optimizer_publication_readiness_alpha16(
  p_run_id uuid,p_variant_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_run public.optimization_runs_v2%rowtype;
  v_variant public.plan_variants_v2%rowtype;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not solver_private.can_access_run_v2(p_run_id) then raise exception 'RUN_NOT_FOUND'; end if;
  select * into v_run from public.optimization_runs_v2 run where run.id=p_run_id;
  select * into v_variant from public.plan_variants_v2 variant
  where variant.id=p_variant_id and variant.run_id=p_run_id;
  return jsonb_build_object(
    'ready',v_run.status='READY' and v_run.scope_type='COMPANY'
      and v_run.request_engine='ORTOOLS_V2' and v_variant.id is not null
      and v_variant.selected and v_variant.hard_violations=0
      and v_variant.status in ('SELECTED','PUBLISHED'),
    'blockers',jsonb_strip_nulls(jsonb_build_object(
      'run',case when v_run.status<>'READY' then jsonb_build_object(
        'code','RUN_NOT_READY','message','Generowanie nie zostało zakończone.',
        'status',v_run.status,'phase',v_run.phase) end,
      'scope',case when v_run.scope_type<>'COMPANY' then jsonb_build_object(
        'code','COMPANY_VARIANT_REQUIRED',
        'message','Publikacja wymaga wariantu całej firmy albo scalenia wszystkich ról.') end,
      'engine',case when v_run.request_engine<>'ORTOOLS_V2' then jsonb_build_object(
        'code','SHADOW_RESULT','message','Wynik testowy nie może zostać opublikowany.') end,
      'selection',case when v_variant.id is null or not coalesce(v_variant.selected,false)
        then jsonb_build_object('code','VARIANT_NOT_SELECTED',
          'message','Najpierw wybierz wariant do publikacji.') end,
      'hardRules',case when coalesce(v_variant.hard_violations,0)>0
        then jsonb_build_object('code','HARD_RULES_BROKEN',
          'message','Wariant narusza twarde reguły.',
          'count',v_variant.hard_violations) end
    )),
    'warnings',jsonb_build_object(
      'unfilledCount',coalesce(v_variant.unfilled_count,0),
      'message',case when coalesce(v_variant.unfilled_count,0)>0
        then 'Wariant zawiera braki obsady. Przejrzyj alerty przed publikacją.' end
    ),
    'issues',coalesce((select jsonb_agg(jsonb_build_object(
      'id',issue.id,'code',issue.issue_code,'severity',issue.severity,
      'message',issue.message,'date',shift_row.shift_date,
      'startsAt',shift_row.starts_at,'endsAt',shift_row.ends_at,
      'locationId',shift_row.location_id,'locationName',location.name,
      'shiftTemplateId',shift_row.shift_template_id,
      'shiftTemplateName',template.name,'roleId',issue.role_id,
      'roleName',role.name,'dutyId',issue.duty_id,'dutyName',duty.name,
      'requiredCount',issue.required_count,'assignedCount',issue.assigned_count,
      'slotKey',issue.slot_key
    ) order by shift_row.starts_at,issue.id)
      from public.plan_issues_v2 issue
      left join public.plan_shifts_v2 shift_row on shift_row.id=issue.shift_id
      left join public.matrix_locations_v2 location on location.id=shift_row.location_id
      left join public.matrix_shift_templates_v2 template
        on template.id=shift_row.shift_template_id
      left join public.matrix_roles_v2 role on role.id=issue.role_id
      left join public.matrix_duties_v2 duty on duty.id=issue.duty_id
      where issue.variant_id=p_variant_id),'[]'::jsonb)
  );
end;
$$;

create or replace function public.optimizer_publication_attempt_alpha16(
  p_run_id uuid,
  p_variant_id uuid,
  p_name text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_readiness jsonb;
begin
  v_readiness:=public.optimizer_publication_readiness_alpha16(
    p_run_id,p_variant_id
  );
  insert into public.audit_log(
    actor_id,entity_type,entity_id,action,new_data
  ) values(
    auth.uid(),'optimization_run_v2',p_run_id::text,'PUBLICATION_ATTEMPT',
    jsonb_build_object(
      'variantId',p_variant_id,'name',trim(coalesce(p_name,'')),
      'ready',coalesce((v_readiness->>'ready')::boolean,false),
      'blockers',coalesce(v_readiness->'blockers','{}'::jsonb),
      'unfilledCount',coalesce((v_readiness->'warnings'->>'unfilledCount')::integer,0)
    )
  );
  return v_readiness;
end;
$$;

create or replace function public.optimizer_publish_company_variant_alpha16(
  p_run_id uuid,
  p_variant_id uuid,
  p_name text,
  p_idempotency_key text,
  p_warning_reason text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_readiness jsonb;
  v_unfilled integer;
  v_result jsonb;
begin
  v_readiness:=public.optimizer_publication_readiness_alpha16(
    p_run_id,p_variant_id
  );
  v_unfilled:=coalesce(
    (v_readiness->'warnings'->>'unfilledCount')::integer,0
  );
  if not coalesce((v_readiness->>'ready')::boolean,false) then
    insert into public.audit_log(
      actor_id,entity_type,entity_id,action,new_data
    ) values(
      auth.uid(),'optimization_run_v2',p_run_id::text,'PUBLICATION_BLOCKED',
      jsonb_build_object(
        'variantId',p_variant_id,'name',trim(coalesce(p_name,'')),
        'blockers',coalesce(v_readiness->'blockers','{}'::jsonb)
      )
    );
    return jsonb_build_object(
      'published',false,'code','PLAN_NOT_READY',
      'message','Grafik nie spełnia warunków publikacji.',
      'readiness',v_readiness
    );
  end if;
  if v_unfilled>0 and length(trim(coalesce(p_warning_reason,'')))<3 then
    insert into public.audit_log(
      actor_id,entity_type,entity_id,action,new_data
    ) values(
      auth.uid(),'optimization_run_v2',p_run_id::text,
      'PUBLICATION_WARNING_REASON_REQUIRED',jsonb_build_object(
        'variantId',p_variant_id,'name',trim(coalesce(p_name,'')),
        'unfilledCount',v_unfilled
      )
    );
    return jsonb_build_object(
      'published',false,'code','WARNING_REASON_REQUIRED',
      'message','Publikacja z brakami obsady wymaga podania powodu.',
      'readiness',v_readiness
    );
  end if;
  begin
    v_result:=public.optimizer_publish_company_variant_v2(
      p_run_id,p_variant_id,p_name,p_idempotency_key
    );
  exception when others then
    insert into public.audit_log(
      actor_id,entity_type,entity_id,action,new_data
    ) values(
      auth.uid(),'optimization_run_v2',p_run_id::text,'PUBLICATION_FAILED',
      jsonb_build_object(
        'variantId',p_variant_id,'name',trim(coalesce(p_name,'')),
        'error',sqlerrm
      )
    );
    return jsonb_build_object(
      'published',false,'code','PUBLICATION_FAILED',
      'message',sqlerrm,'readiness',v_readiness
    );
  end;
  insert into public.audit_log(
    actor_id,entity_type,entity_id,action,new_data
  ) values(
    auth.uid(),'optimization_run_v2',p_run_id::text,'PUBLICATION_COMPLETED',
    jsonb_build_object(
      'variantId',p_variant_id,
      'scheduleId',v_result->>'scheduleId',
      'unfilledCount',v_unfilled,
      'warningReason',case when v_unfilled>0
        then trim(p_warning_reason) else null end
    )
  );
  return v_result||jsonb_build_object(
    'published',true,
    'warningReason',case when v_unfilled>0 then trim(p_warning_reason) else null end
  );
end;
$$;

create or replace function public.optimizer_runs_catalog_alpha16(
  p_month date,p_scope_type text default 'COMPANY',p_scope_role_id uuid default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_month date:=date_trunc('month',p_month)::date;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  return jsonb_build_object(
    'month',v_month,'scopeType',upper(coalesce(p_scope_type,'COMPANY')),
    'runs',coalesce((select jsonb_agg(jsonb_build_object(
      'id',run.id,'name',run.name,'status',run.status,'phase',run.phase,
      'progress',run.progress,'createdAt',run.created_at,'finishedAt',run.finished_at,
      'scenario',jsonb_build_object('id',scenario.id,'code',scenario.code,
        'name',scenario.name),
      'scope',jsonb_build_object('type',run.scope_type,'roleId',run.scope_role_id,
        'roleName',role.name),
      'variants',coalesce((select jsonb_agg(jsonb_build_object(
        'id',variant.id,'name',variant.name,'status',variant.status,
        'selected',variant.selected,'recommended',variant.recommended,
        'assignmentCount',variant.assignment_count,
        'unfilledCount',variant.unfilled_count,
        'hardViolations',variant.hard_violations,
        'solverStatus',variant.solver_status,
        'metrics',variant.metrics,
        'strategy',jsonb_build_object('id',strategy.id,'code',strategy.code,
          'name',strategy.name),
        'totalCostMinor',finance.total_cost_minor,'currency',finance.currency
      ) order by link.ordinal,variant.created_at)
        from public.plan_variants_v2 variant
        join public.optimization_run_strategies_v2 link
          on link.id=variant.run_strategy_id
        join public.matrix_strategies_v2 strategy on strategy.id=variant.strategy_id
        left join solver_private.plan_variant_finance_v2 finance
          on finance.variant_id=variant.id
        where variant.run_id=run.id),'[]'::jsonb)
    ) order by run.created_at desc,run.id desc)
      from public.optimization_runs_v2 run
      join public.matrix_scenarios_v2 scenario on scenario.id=run.scenario_id
      left join public.matrix_roles_v2 role on role.id=run.scope_role_id
      where run.month=v_month
        and run.scope_type=upper(coalesce(p_scope_type,'COMPANY'))
        and run.scope_role_id is not distinct from p_scope_role_id
        and (run.requested_by=auth.uid() or public.has_app_role('OWNER')
          or public.has_app_role('ADMIN'))
    ),'[]'::jsonb)
  );
end;
$$;

revoke all on function solver_private.alpha16_can_manage_schedule_v2(uuid)
  from public,anon,authenticated;
revoke all on function solver_private.alpha16_enrich_workspace_issues_v2(jsonb,uuid[])
  from public,anon,authenticated;
grant execute on function solver_private.alpha16_can_manage_schedule_v2(uuid)
  to service_role;
grant execute on function solver_private.alpha16_enrich_workspace_issues_v2(jsonb,uuid[])
  to service_role;

revoke all on function public.optimizer_candidate_diagnostics_alpha16(uuid,bigint),
  public.optimizer_selected_variant_workspace_alpha16(uuid),
  public.optimizer_published_schedule_alpha16(uuid),
  public.optimizer_operational_workspace_alpha16(date),
  public.optimizer_emergency_assign_alpha16(uuid,bigint,uuid,boolean,text,boolean),
  public.optimizer_publication_readiness_alpha16(uuid,uuid),
  public.optimizer_publication_attempt_alpha16(uuid,uuid,text),
  public.optimizer_publish_company_variant_alpha16(uuid,uuid,text,text,text),
  public.optimizer_runs_catalog_alpha16(date,text,uuid)
  from public,anon,authenticated;

grant execute on function public.optimizer_candidate_diagnostics_alpha16(uuid,bigint),
  public.optimizer_selected_variant_workspace_alpha16(uuid),
  public.optimizer_published_schedule_alpha16(uuid),
  public.optimizer_operational_workspace_alpha16(date),
  public.optimizer_emergency_assign_alpha16(uuid,bigint,uuid,boolean,text,boolean),
  public.optimizer_publication_readiness_alpha16(uuid,uuid),
  public.optimizer_publication_attempt_alpha16(uuid,uuid,text),
  public.optimizer_publish_company_variant_alpha16(uuid,uuid,text,text,text),
  public.optimizer_runs_catalog_alpha16(date,text,uuid)
  to authenticated,service_role;

comment on table public.operational_assignment_overrides_v2 is
  'Mutable operational overlay; published solver variants remain immutable.';
comment on function public.optimizer_candidate_diagnostics_alpha16(uuid,bigint) is
  'Explains every candidate rejection and returns workload, adjacent shifts and preference data.';
comment on function public.optimizer_selected_variant_workspace_alpha16(uuid) is
  'Selected solver variant with exact date, location, role, duty and staffing context for every issue.';
comment on function public.optimizer_published_schedule_alpha16(uuid) is
  'Published schedule workspace with the same detailed issue contract as generator and operations.';
comment on function public.optimizer_publish_company_variant_alpha16(uuid,uuid,text,text,text) is
  'Audited publication boundary; requires an explicit reason when soft staffing warnings remain.';
comment on function public.optimizer_emergency_assign_alpha16(uuid,bigint,uuid,boolean,text,boolean) is
  'Atomic operational assignment with hard-block enforcement, explicit soft override reason, audit and post-commit notification row.';
