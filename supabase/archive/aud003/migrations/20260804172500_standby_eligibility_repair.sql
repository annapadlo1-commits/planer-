-- Align stand-by selection and activation with the same Matrix hard rules
-- used by the solver: weekday/period restrictions and required duties.

create or replace function solver_private.generate_standby_for_variant_uat_v2(
  p_variant_id uuid,
  p_month date,
  p_matrix_version_id uuid,
  p_role_id uuid,
  p_source_schedule_id uuid,
  p_source_role_schedule_id uuid
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_date date;
  v_employee uuid;
  v_tier integer;
  v_created integer:=0;
  v_timezone text;
  v_default_available boolean;
begin
  if (p_source_schedule_id is null)=(p_source_role_schedule_id is null) then
    raise exception 'STANDBY_SOURCE_REQUIRED';
  end if;
  select coalesce(matrix.settings->>'timezone','Europe/Warsaw'),
    coalesce((matrix.settings->>'missingAvailabilityMeansAvailable')::boolean,true)
  into v_timezone,v_default_available
  from public.matrix_versions matrix where matrix.id=p_matrix_version_id;
  if v_timezone is null then raise exception 'MATRIX_VERSION_NOT_FOUND'; end if;

  update public.published_standby_assignments_v2 standby set status='SUPERSEDED'
  where standby.month=p_month and standby.role_id=p_role_id
    and standby.status='PLANNED'
    and (standby.source_schedule_id is distinct from p_source_schedule_id
      or standby.source_role_schedule_id is distinct from p_source_role_schedule_id);

  for v_date in
    select distinct source.shift_date from (
      select shift_row.shift_date
      from public.plan_assignments_v2 assignment
      join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
      where assignment.variant_id=p_variant_id and assignment.role_id=p_role_id
      union
      select shift_row.shift_date
      from public.plan_issues_v2 issue
      join public.plan_shifts_v2 shift_row on shift_row.id=issue.shift_id
      where issue.variant_id=p_variant_id and issue.role_id=p_role_id
    ) source order by source.shift_date
  loop
    for v_tier in 1..2 loop
      v_employee:=null;
      with role_shifts as (
        select distinct shift_row.id,shift_row.location_id,shift_row.shift_template_id,
          shift_row.starts_at,shift_row.ends_at
        from public.plan_assignments_v2 assignment
        join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
        where assignment.variant_id=p_variant_id and assignment.role_id=p_role_id
          and shift_row.shift_date=v_date
        union
        select distinct shift_row.id,shift_row.location_id,shift_row.shift_template_id,
          shift_row.starts_at,shift_row.ends_at
        from public.plan_issues_v2 issue
        join public.plan_shifts_v2 shift_row on shift_row.id=issue.shift_id
        where issue.variant_id=p_variant_id and issue.role_id=p_role_id
          and shift_row.shift_date=v_date
      ), candidates as (
        select profile.employee_id,profile.employee_no,
          case when coalesce(hr.contract_type,'INNE') in ('ZLECENIE','B2B')
              and profile.work_time_policy<>'CUSTOM' then 0
            else coalesce(profile.minimum_rest_minutes,
              (select (matrix.settings->>'minimumRestMinutes')::integer
               from public.matrix_versions matrix where matrix.id=p_matrix_version_id),660)
          end rest_minutes
        from public.matrix_employee_profiles_v2 profile
        left join public.employee_hr_profiles hr on hr.employee_id=profile.employee_id
        where profile.matrix_version_id=p_matrix_version_id
          and profile.active and profile.archived_at is null
          and (profile.employment_start is null or profile.employment_start<=v_date)
          and (profile.employment_end is null or profile.employment_end>=v_date)
          and (not profile.no_weekends or extract(isodow from v_date) not in (6,7))
          and (not profile.only_morning or not exists(
            select 1 from role_shifts role_shift
            join public.matrix_shift_templates_v2 template
              on template.id=role_shift.shift_template_id
            where template.shift_period<>'MORNING'
          ))
          and (not profile.only_evening or not exists(
            select 1 from role_shifts role_shift
            join public.matrix_shift_templates_v2 template
              on template.id=role_shift.shift_template_id
            where template.shift_period<>'EVENING'
          ))
          and exists(select 1 from public.matrix_employee_roles_v2 role_grant
            where role_grant.matrix_version_id=p_matrix_version_id
              and role_grant.employee_id=profile.employee_id
              and role_grant.role_id=p_role_id and role_grant.active
              and (role_grant.valid_from is null or role_grant.valid_from<=v_date)
              and (role_grant.valid_to is null or role_grant.valid_to>=v_date))
          and not exists(select 1 from public.plan_assignments_v2 assignment
            join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
            where assignment.variant_id=p_variant_id
              and assignment.employee_id=profile.employee_id
              and shift_row.shift_date=v_date)
          and not exists(select 1 from public.published_role_schedules_v2 publication
            join public.plan_assignments_v2 assignment
              on assignment.variant_id=publication.variant_id
            join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
            where publication.month=p_month and publication.status='PUBLISHED'
              and assignment.employee_id=profile.employee_id
              and shift_row.shift_date=v_date)
          and not exists(select 1 from public.published_standby_assignments_v2 standby
            where standby.month=p_month and standby.standby_date=v_date
              and standby.employee_id=profile.employee_id
              and standby.status in ('PLANNED','ACTIVATED'))
          and not exists(select 1 from role_shifts role_shift
            where not exists(select 1 from public.matrix_employee_locations_v2 location_grant
              where location_grant.matrix_version_id=p_matrix_version_id
                and location_grant.employee_id=profile.employee_id
                and location_grant.location_id=role_shift.location_id
                and location_grant.active and location_grant.standard_allowed
                and (location_grant.valid_from is null or location_grant.valid_from<=v_date)
                and (location_grant.valid_to is null or location_grant.valid_to>=v_date)))
          and not exists(select 1 from role_shifts role_shift
            join public.employee_time_constraints_v2 constraint_row
              on constraint_row.employee_id=profile.employee_id
             and constraint_row.status='ACTIVE'
             and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
             and constraint_row.time_range
               && tstzrange(role_shift.starts_at,role_shift.ends_at,'[)'))
          and (v_default_available or exists(select 1
            from public.employee_time_constraints_v2 window_row
            where window_row.employee_id=profile.employee_id
              and window_row.status='ACTIVE'
              and window_row.constraint_kind='AVAILABLE_WINDOW'
              and lower(window_row.time_range)<=
                (select min(role_shift.starts_at) from role_shifts role_shift)
              and upper(window_row.time_range)>=
                (select max(role_shift.ends_at) from role_shifts role_shift)))
      ), ranked as (
        select candidate.employee_id,candidate.employee_no,
          (select count(*) from public.published_standby_assignments_v2 history
            where history.employee_id=candidate.employee_id and history.month=p_month
              and history.status not in ('CANCELLED','SUPERSEDED')) previous_standby
        from candidates candidate
        where not exists(select 1 from public.plan_assignments_v2 assignment
          join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
          where assignment.variant_id=p_variant_id
            and assignment.employee_id=candidate.employee_id
            and ((shift_row.ends_at<=(select min(starts_at) from role_shifts)
                and extract(epoch from ((select min(starts_at) from role_shifts)-shift_row.ends_at))/60<candidate.rest_minutes)
              or (shift_row.starts_at>=(select max(ends_at) from role_shifts)
                and extract(epoch from (shift_row.starts_at-(select max(ends_at) from role_shifts)))/60<candidate.rest_minutes)))
      )
      select ranked.employee_id into v_employee from ranked
      order by ranked.previous_standby,ranked.employee_no,ranked.employee_id limit 1;
      if v_employee is null then
        raise exception 'STANDBY_COVERAGE_INSUFFICIENT|%|%|TIER_%',
          p_role_id,v_date,v_tier;
      end if;
      insert into public.published_standby_assignments_v2(
        month,standby_date,matrix_version_id,role_id,employee_id,tier,
        source_variant_id,source_schedule_id,source_role_schedule_id,created_by
      ) values(
        p_month,v_date,p_matrix_version_id,p_role_id,v_employee,v_tier,
        p_variant_id,p_source_schedule_id,p_source_role_schedule_id,auth.uid()
      );
      v_created:=v_created+1;
    end loop;
  end loop;
  return v_created;
end;
$$;

create or replace function public.standby_activate_uat_v2(
  p_standby_id uuid,
  p_original_assignment_id uuid,
  p_reason text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_standby public.published_standby_assignments_v2%rowtype;
  v_assignment public.plan_assignments_v2%rowtype;
  v_shift public.plan_shifts_v2%rowtype;
  v_id uuid:=gen_random_uuid();
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  if length(trim(coalesce(p_reason,'')))<3 then raise exception 'ACTIVATION_REASON_REQUIRED'; end if;
  select standby.* into v_standby
  from public.published_standby_assignments_v2 standby
  where standby.id=p_standby_id for update;
  if v_standby.id is null or v_standby.status<>'PLANNED' then
    raise exception 'STANDBY_NOT_ACTIVATABLE';
  end if;
  if v_standby.tier=2 and exists(select 1
    from public.published_standby_assignments_v2 tier1
    where tier1.month=v_standby.month and tier1.standby_date=v_standby.standby_date
      and tier1.role_id=v_standby.role_id and tier1.tier=1
      and tier1.status='PLANNED') then
    raise exception 'STANDBY_TIER_1_MUST_BE_USED_OR_DECLINED_FIRST';
  end if;
  select assignment.* into v_assignment
  from public.plan_assignments_v2 assignment
  where assignment.id=p_original_assignment_id;
  select shift_row.* into v_shift from public.plan_shifts_v2 shift_row
  where shift_row.id=v_assignment.shift_id;
  if v_assignment.id is null or v_assignment.role_id<>v_standby.role_id
    or v_shift.shift_date<>v_standby.standby_date then
    raise exception 'STANDBY_TARGET_ASSIGNMENT_MISMATCH';
  end if;
  if exists(select 1 from public.employee_time_constraints_v2 constraint_row
    where constraint_row.employee_id=v_standby.employee_id
      and constraint_row.status='ACTIVE'
      and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
      and constraint_row.time_range&&tstzrange(v_shift.starts_at,v_shift.ends_at,'[)')) then
    raise exception 'STANDBY_REVALIDATION_HARD_BLOCK';
  end if;
  if exists(
    select 1 from public.plan_assignment_duties_v2 required_duty
    where required_duty.assignment_id=v_assignment.id
      and not exists(
        select 1 from public.matrix_employee_duties_v2 capability
        where capability.matrix_version_id=v_standby.matrix_version_id
          and capability.employee_id=v_standby.employee_id
          and capability.duty_id=required_duty.duty_id
          and capability.active
          and (capability.role_id is null or capability.role_id=v_standby.role_id)
          and (capability.location_id is null
            or capability.location_id=v_shift.location_id)
          and (capability.valid_from is null
            or capability.valid_from<=v_standby.standby_date)
          and (capability.valid_to is null
            or capability.valid_to>=v_standby.standby_date)
      )
  ) then
    raise exception 'STANDBY_REVALIDATION_DUTY_MISMATCH';
  end if;
  if exists(select 1 from public.operational_assignment_replacements_v2 replacement
    where replacement.original_assignment_id=p_original_assignment_id
      and replacement.status='ACTIVE') then
    raise exception 'ASSIGNMENT_ALREADY_REPLACED';
  end if;
  insert into public.operational_assignment_replacements_v2(
    id,month,original_assignment_id,replacement_employee_id,
    standby_assignment_id,reason,created_by
  ) values(
    v_id,v_standby.month,p_original_assignment_id,v_standby.employee_id,
    v_standby.id,trim(p_reason),auth.uid()
  );
  update public.published_standby_assignments_v2 standby set
    status='ACTIVATED',activated_shift_id=v_shift.id,
    activated_assignment_id=p_original_assignment_id,
    activated_at=now(),activated_by=auth.uid(),activation_reason=trim(p_reason)
  where standby.id=v_standby.id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'standby_assignment_v2',v_standby.id::text,'ACTIVATE',
    jsonb_build_object('replacementId',v_id,'originalAssignmentId',p_original_assignment_id,
      'tier',v_standby.tier,'reason',trim(p_reason)));
  return jsonb_build_object('standbyId',v_standby.id,'replacementId',v_id,
    'status','ACTIVATED','tier',v_standby.tier);
end;
$$;

-- Add separately displayed stand-by data and activated replacements to the

revoke all on function solver_private.generate_standby_for_variant_uat_v2(
  uuid,date,uuid,uuid,uuid,uuid
),public.standby_activate_uat_v2(uuid,uuid,text)
  from public,anon,authenticated;
grant execute on function public.standby_activate_uat_v2(uuid,uuid,text)
  to authenticated;
