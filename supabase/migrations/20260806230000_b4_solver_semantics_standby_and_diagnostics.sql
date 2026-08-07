-- B4 UAT: one source of truth for standby, human-readable diagnostics and
-- transparent publication conflicts. UAT project only.

alter function solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)
  rename to build_snapshot_payload_before_b4_settings_v2;

create function solver_private.build_snapshot_payload_v2(
  p_run_id uuid,p_month date,p_matrix_version_id uuid,p_scenario_id uuid,
  p_scope_type text,p_scope_role_id uuid
) returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_snapshot jsonb; v_tiers integer; v_employees jsonb;
begin
  v_snapshot:=solver_private.build_snapshot_payload_before_b4_settings_v2(
    p_run_id,p_month,p_matrix_version_id,p_scenario_id,p_scope_type,p_scope_role_id);
  select greatest(0,least(2,coalesce((matrix.settings->>'standbyTiersPerRoleDay')::integer,2)))
    into v_tiers from public.matrix_versions matrix where matrix.id=p_matrix_version_id;
  select coalesce(jsonb_agg(employee.value||jsonb_build_object(
    'nominalMonthlyMinutes',coalesce(profile.nominal_monthly_minutes,0),
    'maximumMonthlyMinutes',coalesce(profile.maximum_monthly_minutes,0),
    'maximumWeeklyMinutes',coalesce(profile.maximum_weekly_minutes,0),
    'maximumConsecutiveDays',coalesce(profile.maximum_consecutive_days,31),
    'minimumRestMinutes',coalesce(profile.minimum_rest_minutes,
      nullif(matrix.settings->>'minimumRestMinutes','')::integer,0)
  ) order by employee.ordinality),'[]'::jsonb) into v_employees
  from jsonb_array_elements(coalesce(v_snapshot->'employees','[]'::jsonb))
    with ordinality employee(value,ordinality)
  join public.matrix_employee_profiles_v2 profile
    on profile.matrix_version_id=p_matrix_version_id
   and profile.employee_id=(employee.value->>'id')::uuid
  join public.matrix_versions matrix on matrix.id=p_matrix_version_id;
  v_snapshot:=jsonb_set(v_snapshot,'{employees}',v_employees,true);
  return jsonb_set(v_snapshot,'{settings,standbyTiersPerRoleDay}',to_jsonb(coalesce(v_tiers,2)),true);
end;
$$;
revoke all on function solver_private.build_snapshot_payload_before_b4_settings_v2(uuid,date,uuid,uuid,text,uuid) from public,anon,authenticated;
revoke all on function solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid) from public,anon,authenticated;
grant execute on function solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid) to service_role;

create or replace function public.optimizer_variant_standby_preview_uat_v1(p_variant_id uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_matrix uuid; v_scope text; v_tiers integer:=0; v_month date;
begin
  select run.matrix_version_id,run.scope_type,run.month,
    greatest(0,least(2,coalesce((matrix.settings->>'standbyTiersPerRoleDay')::integer,2)))
  into v_matrix,v_scope,v_month,v_tiers
  from public.plan_variants_v2 variant
  join public.optimization_runs_v2 run on run.id=variant.run_id
  join public.matrix_versions matrix on matrix.id=run.matrix_version_id
  where variant.id=p_variant_id;
  if v_matrix is null then raise exception 'VARIANT_NOT_FOUND'; end if;
  if auth.uid() is null or not (
    public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or (v_scope='ROLE' and exists(
      select 1 from public.matrix_scope_grants_v2 grant_row
      join public.optimization_runs_v2 run on run.scope_role_id is not null
      join public.matrix_roles_v2 role on role.id=run.scope_role_id
      join public.plan_variants_v2 variant on variant.run_id=run.id
      where variant.id=p_variant_id and grant_row.auth_user_id=auth.uid()
        and grant_row.active and grant_row.app_role='ROLE_MANAGER'
        and (grant_row.role_logical_id is null or grant_row.role_logical_id=role.logical_id)
    ))
  ) then raise exception 'VARIANT_NOT_AVAILABLE'; end if;
  if v_tiers=0 then return '[]'::jsonb; end if;

  return coalesce((
    with role_days as (
      select distinct shift.shift_date,assignment.role_id
      from public.plan_shifts_v2 shift
      join public.plan_assignments_v2 assignment on assignment.shift_id=shift.id
        and assignment.variant_id=p_variant_id
      where shift.variant_id=p_variant_id
    ), candidates as (
      select role_day.shift_date,role_day.role_id,employee.id employee_id,
        row_number() over(partition by role_day.shift_date,role_day.role_id
          order by coalesce(profile.nominal_monthly_minutes,0) desc,
            employee.last_name,employee.first_name,employee.id) tier
      from role_days role_day
      join public.matrix_employee_roles_v2 role_grant
        on role_grant.matrix_version_id=v_matrix and role_grant.role_id=role_day.role_id
       and role_grant.active
       and (role_grant.valid_from is null or role_grant.valid_from<=role_day.shift_date)
       and (role_grant.valid_to is null or role_grant.valid_to>=role_day.shift_date)
      join public.employees employee on employee.id=role_grant.employee_id
       and employee.active and employee.archived_at is null
      join public.matrix_employee_profiles_v2 profile
        on profile.matrix_version_id=v_matrix and profile.employee_id=employee.id
       and profile.active and profile.archived_at is null
      where not exists(
        select 1 from public.plan_assignments_v2 assigned
        join public.plan_shifts_v2 assigned_shift on assigned_shift.id=assigned.shift_id
        where assigned.variant_id=p_variant_id and assigned.employee_id=employee.id
          and assigned_shift.shift_date=role_day.shift_date)
        and not exists(
          select 1 from public.employee_time_constraints_v2 constraint_row
          join public.plan_shifts_v2 role_shift on role_shift.variant_id=p_variant_id
            and role_shift.shift_date=role_day.shift_date
          join public.plan_assignments_v2 role_assignment on role_assignment.shift_id=role_shift.id
            and role_assignment.variant_id=p_variant_id and role_assignment.role_id=role_day.role_id
          where constraint_row.employee_id=employee.id and constraint_row.status='ACTIVE'
            and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
            and constraint_row.time_range&&tstzrange(role_shift.starts_at,role_shift.ends_at,'[)'))
        and not exists(
          select 1 from public.plan_shifts_v2 role_shift
          join public.plan_assignments_v2 role_assignment on role_assignment.shift_id=role_shift.id
            and role_assignment.variant_id=p_variant_id and role_assignment.role_id=role_day.role_id
          where role_shift.variant_id=p_variant_id and role_shift.shift_date=role_day.shift_date
            and not exists(select 1 from public.matrix_employee_locations_v2 location_grant
              where location_grant.matrix_version_id=v_matrix
                and location_grant.employee_id=employee.id
                and location_grant.location_id=role_shift.location_id
                and location_grant.active and location_grant.standard_allowed
                and (location_grant.valid_from is null or location_grant.valid_from<=role_day.shift_date)
                and (location_grant.valid_to is null or location_grant.valid_to>=role_day.shift_date)))
    )
    select jsonb_agg(jsonb_build_object(
      'id',md5(p_variant_id::text||candidate.shift_date::text||candidate.role_id::text||candidate.tier::text),
      'date',candidate.shift_date,'tier',candidate.tier,'status','PREVIEW',
      'roleId',candidate.role_id,'roleName',role.name,
      'employeeId',candidate.employee_id,'employeeNo',employee.employee_no,
      'employeeName',trim(employee.first_name||' '||employee.last_name),
      'sourceType',case when v_scope='ROLE' then 'ROLE' else 'COMPANY' end,
      'activatedShiftId',null
    ) order by candidate.shift_date,role.sort_order,candidate.tier)
    from candidates candidate
    join public.employees employee on employee.id=candidate.employee_id
    join public.matrix_roles_v2 role on role.id=candidate.role_id
    where candidate.tier<=v_tiers
  ),'[]'::jsonb);
end;
$$;
revoke all on function public.optimizer_variant_standby_preview_uat_v1(uuid) from public,anon,authenticated;
grant execute on function public.optimizer_variant_standby_preview_uat_v1(uuid) to authenticated;

alter function solver_private.generate_standby_for_variant_uat_v2(uuid,date,uuid,uuid,uuid,uuid)
  rename to generate_standby_for_variant_before_b4_default_uat_v2;

create function solver_private.generate_standby_for_variant_uat_v2(
  p_variant_id uuid,p_month date,p_matrix_version_id uuid,p_role_id uuid,
  p_source_schedule_id uuid,p_source_role_schedule_id uuid
) returns integer language plpgsql security definer set search_path=''
as $$
declare v_created integer:=0; v_preview jsonb; v_item jsonb;
begin
  v_created:=solver_private.generate_standby_for_variant_before_b4_default_uat_v2(
    p_variant_id,p_month,p_matrix_version_id,p_role_id,p_source_schedule_id,p_source_role_schedule_id);
  if v_created>0 or exists(select 1 from public.matrix_versions matrix
      where matrix.id=p_matrix_version_id and matrix.settings ? 'standbyTiersPerRoleDay') then
    return v_created;
  end if;
  v_preview:=public.optimizer_variant_standby_preview_uat_v1(p_variant_id);
  for v_item in select item.value from jsonb_array_elements(v_preview) item(value)
    where (item.value->>'roleId')::uuid=p_role_id
  loop
    insert into public.published_standby_assignments_v2(
      month,standby_date,matrix_version_id,role_id,employee_id,tier,
      source_variant_id,source_schedule_id,source_role_schedule_id,created_by
    ) values(
      p_month,(v_item->>'date')::date,p_matrix_version_id,p_role_id,
      (v_item->>'employeeId')::uuid,(v_item->>'tier')::integer,
      p_variant_id,p_source_schedule_id,p_source_role_schedule_id,auth.uid()
    ) on conflict do nothing;
    if found then v_created:=v_created+1; end if;
  end loop;
  return v_created;
end;
$$;
revoke all on function solver_private.generate_standby_for_variant_before_b4_default_uat_v2(uuid,date,uuid,uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function solver_private.generate_standby_for_variant_uat_v2(uuid,date,uuid,uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function solver_private.generate_standby_for_variant_uat_v2(uuid,date,uuid,uuid,uuid,uuid) to service_role;

alter function public.optimizer_leader_assignment_context_uat_v1(uuid,uuid,bigint)
  rename to optimizer_leader_assignment_context_before_b4_details_uat_v1;

create function public.optimizer_leader_assignment_context_uat_v1(
  p_variant_id uuid,p_assignment_id uuid default null,p_issue_id bigint default null
) returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_payload jsonb; v_duty_id uuid; v_duty_name text; v_candidates jsonb;
begin
  v_payload:=public.optimizer_leader_assignment_context_before_b4_details_uat_v1(
    p_variant_id,p_assignment_id,p_issue_id);
  if p_issue_id is not null then
    select issue.duty_id into v_duty_id from public.plan_issues_v2 issue
      where issue.id=p_issue_id and issue.variant_id=p_variant_id;
  else
    select duty.duty_id into v_duty_id from public.plan_assignment_duties_v2 duty
      where duty.assignment_id=p_assignment_id order by duty.duty_id limit 1;
  end if;
  select duty.name into v_duty_name from public.matrix_duties_v2 duty where duty.id=v_duty_id;
  select coalesce(jsonb_agg(candidate.value||jsonb_build_object(
    'roleName',v_payload#>>'{role,name}',
    'locationName',v_payload#>>'{shift,locationName}',
    'dutyName',v_duty_name
  )),'[]'::jsonb) into v_candidates
  from jsonb_array_elements(coalesce(v_payload->'candidates','[]'::jsonb)) candidate(value);
  v_payload:=jsonb_set(v_payload,'{candidates}',v_candidates,true);
  return v_payload||jsonb_build_object('duty',case when v_duty_id is null then null
    else jsonb_build_object('id',v_duty_id,'name',v_duty_name) end);
end;
$$;
revoke all on function public.optimizer_leader_assignment_context_before_b4_details_uat_v1(uuid,uuid,bigint) from public,anon,authenticated;
revoke all on function public.optimizer_leader_assignment_context_uat_v1(uuid,uuid,bigint) from public,anon,authenticated;
grant execute on function public.optimizer_leader_assignment_context_uat_v1(uuid,uuid,bigint) to authenticated;

alter function public.optimizer_variant_issue_diagnostics_uat_v2(uuid,bigint)
  rename to optimizer_variant_issue_diagnostics_before_b4_details_uat_v2;

create function public.optimizer_variant_issue_diagnostics_uat_v2(p_variant_id uuid,p_issue_id bigint)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_payload jsonb; v_shift public.plan_shifts_v2%rowtype;
  v_candidates jsonb:='[]'::jsonb; v_candidate jsonb; v_details jsonb;
begin
  v_payload:=public.optimizer_variant_issue_diagnostics_before_b4_details_uat_v2(p_variant_id,p_issue_id);
  select shift.* into v_shift from public.plan_issues_v2 issue
    join public.plan_shifts_v2 shift on shift.id=issue.shift_id
    where issue.id=p_issue_id and issue.variant_id=p_variant_id;
  for v_candidate in select candidate.value
    from jsonb_array_elements(coalesce(v_payload->'candidates','[]'::jsonb)) candidate(value)
  loop
    select coalesce(jsonb_agg(detail order by detail->>'startsAt'),'[]'::jsonb) into v_details from (
      select jsonb_build_object(
        'code','HARD_UNAVAILABLE',
        'label',case constraint_row.constraint_kind when 'LEAVE' then 'Urlop'
          when 'SICKNESS' then 'Zwolnienie lekarskie' else 'Twarda niedostępność' end,
        'startsAt',lower(constraint_row.time_range),'endsAt',upper(constraint_row.time_range),
        'note',constraint_row.note,'createdAt',constraint_row.created_at
      ) detail from public.employee_time_constraints_v2 constraint_row
      where constraint_row.employee_id=(v_candidate->>'employeeId')::uuid
        and constraint_row.status='ACTIVE'
        and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
        and constraint_row.time_range&&tstzrange(v_shift.starts_at,v_shift.ends_at,'[)')
      union all
      select jsonb_build_object(
        'code','DAILY_SHIFT_LIMIT','label','Ta osoba ma już przydział tego dnia',
        'shiftName',template.name,'locationName',location.name,
        'startsAt',other_shift.starts_at,'endsAt',other_shift.ends_at,'createdAt',other_assignment.created_at
      ) detail from public.plan_assignments_v2 other_assignment
      join public.plan_shifts_v2 other_shift on other_shift.id=other_assignment.shift_id
      join public.matrix_shift_templates_v2 template on template.id=other_shift.shift_template_id
      join public.matrix_locations_v2 location on location.id=other_shift.location_id
      where other_assignment.variant_id=p_variant_id
        and other_assignment.employee_id=(v_candidate->>'employeeId')::uuid
        and other_shift.shift_date=v_shift.shift_date and other_shift.id<>v_shift.id
    ) details;
    v_candidates:=v_candidates||jsonb_build_array(v_candidate||jsonb_build_object('blockingDetails',v_details));
  end loop;
  return jsonb_set(v_payload,'{candidates}',v_candidates,true);
end;
$$;
revoke all on function public.optimizer_variant_issue_diagnostics_before_b4_details_uat_v2(uuid,bigint) from public,anon,authenticated;
revoke all on function public.optimizer_variant_issue_diagnostics_uat_v2(uuid,bigint) from public,anon,authenticated;
grant execute on function public.optimizer_variant_issue_diagnostics_uat_v2(uuid,bigint) to authenticated;

create or replace function public.employee_availability_publication_conflicts_uat_v1(
  p_employee_id uuid,p_dates date[]
) returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid();
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.employees employee
      where employee.id=p_employee_id and employee.auth_user_id=v_actor)
     and not exists(select 1 from public.user_permissions permission
      where permission.auth_user_id=v_actor and permission.app_role in ('OWNER','ADMIN')) then
    perform solver_private.assert_uat_master_persona_v2();
  end if;
  return coalesce((
    select jsonb_agg(distinct jsonb_build_object(
      'scheduleId',schedule.id,'scheduleName',schedule.name,
      'publishedAt',schedule.published_at,'date',shift.shift_date,
      'shiftName',template.name,'locationName',location.name,'roleName',role.name,
      'startsAt',shift.starts_at,'endsAt',shift.ends_at
    ))
    from public.published_role_schedules_v2 schedule
    join public.plan_assignments_v2 assignment on assignment.variant_id=schedule.variant_id
      and assignment.employee_id=p_employee_id
    join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
    join public.matrix_shift_templates_v2 template on template.id=shift.shift_template_id
    join public.matrix_locations_v2 location on location.id=shift.location_id
    join public.matrix_roles_v2 role on role.id=assignment.role_id
    where schedule.status='PUBLISHED' and shift.shift_date=any(p_dates)
  ),'[]'::jsonb);
end;
$$;
revoke all on function public.employee_availability_publication_conflicts_uat_v1(uuid,date[]) from public,anon,authenticated;
grant execute on function public.employee_availability_publication_conflicts_uat_v1(uuid,date[]) to authenticated;

notify pgrst,'reload schema';
