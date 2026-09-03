-- B4 UAT: required staffing first, then a fair and explainable standby layer.

create or replace function solver_private.standby_candidates_for_role_day_uat_v3(
  p_variant_id uuid,p_matrix_version_id uuid,p_month date,p_role_id uuid,p_date date
) returns table(employee_id uuid,employee_no text)
language sql stable security definer set search_path=''
as $$
  with settings as (
    select coalesce((matrix.settings->>'missingAvailabilityMeansAvailable')::boolean,true) default_available,
      coalesce((matrix.settings->>'minimumRestMinutes')::integer,660) default_rest
    from public.matrix_versions matrix where matrix.id=p_matrix_version_id
  ), role_shifts as (
    select distinct shift_row.id,shift_row.location_id,shift_row.shift_template_id,
      shift_row.starts_at,shift_row.ends_at
    from public.plan_assignments_v2 assignment
    join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
    where assignment.variant_id=p_variant_id and assignment.role_id=p_role_id
      and shift_row.shift_date=p_date
    union
    select distinct shift_row.id,shift_row.location_id,shift_row.shift_template_id,
      shift_row.starts_at,shift_row.ends_at
    from public.plan_issues_v2 issue
    join public.plan_shifts_v2 shift_row on shift_row.id=issue.shift_id
    where issue.variant_id=p_variant_id and issue.role_id=p_role_id
      and shift_row.shift_date=p_date
  ), candidates as (
    select profile.employee_id,profile.employee_no,
      case when coalesce(hr.contract_type,'INNE') in ('ZLECENIE','B2B')
          and profile.work_time_policy<>'CUSTOM' then 0
        else coalesce(profile.minimum_rest_minutes,settings.default_rest,660)
      end rest_minutes
    from public.matrix_employee_profiles_v2 profile
    cross join settings
    left join public.employee_hr_profiles hr on hr.employee_id=profile.employee_id
    where profile.matrix_version_id=p_matrix_version_id
      and profile.active and profile.archived_at is null
      and (profile.employment_start is null or profile.employment_start<=p_date)
      and (profile.employment_end is null or profile.employment_end>=p_date)
      and (not profile.no_weekends or extract(isodow from p_date) not in (6,7))
      and (not profile.only_morning or not exists(
        select 1 from role_shifts role_shift
        join public.matrix_shift_templates_v2 template on template.id=role_shift.shift_template_id
        where template.shift_period<>'MORNING'))
      and (not profile.only_evening or not exists(
        select 1 from role_shifts role_shift
        join public.matrix_shift_templates_v2 template on template.id=role_shift.shift_template_id
        where template.shift_period<>'EVENING'))
      and exists(select 1 from public.matrix_employee_roles_v2 role_grant
        where role_grant.matrix_version_id=p_matrix_version_id
          and role_grant.employee_id=profile.employee_id and role_grant.role_id=p_role_id
          and role_grant.active
          and (role_grant.valid_from is null or role_grant.valid_from<=p_date)
          and (role_grant.valid_to is null or role_grant.valid_to>=p_date))
      and not exists(select 1 from public.plan_assignments_v2 assignment
        join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
        where assignment.variant_id=p_variant_id and assignment.employee_id=profile.employee_id
          and shift_row.shift_date=p_date)
      and not exists(select 1 from public.published_role_schedules_v2 publication
        join public.plan_assignments_v2 assignment on assignment.variant_id=publication.variant_id
        join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
        where publication.month=p_month and publication.status='PUBLISHED'
          and assignment.employee_id=profile.employee_id and shift_row.shift_date=p_date)
      and not exists(select 1 from public.published_standby_assignments_v2 standby
        where standby.month=p_month and standby.standby_date=p_date
          and standby.employee_id=profile.employee_id
          and standby.status in ('PLANNED','ACTIVATED'))
      and not exists(select 1 from role_shifts role_shift
        where not exists(select 1 from public.matrix_employee_locations_v2 location_grant
          where location_grant.matrix_version_id=p_matrix_version_id
            and location_grant.employee_id=profile.employee_id
            and location_grant.location_id=role_shift.location_id
            and location_grant.active and location_grant.standard_allowed
            and (location_grant.valid_from is null or location_grant.valid_from<=p_date)
            and (location_grant.valid_to is null or location_grant.valid_to>=p_date)))
      and not exists(select 1 from role_shifts role_shift
        join public.employee_time_constraints_v2 constraint_row
          on constraint_row.employee_id=profile.employee_id and constraint_row.status='ACTIVE'
         and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
         and constraint_row.time_range&&tstzrange(role_shift.starts_at,role_shift.ends_at,'[)'))
      and (settings.default_available or exists(select 1
        from public.employee_time_constraints_v2 window_row
        where window_row.employee_id=profile.employee_id and window_row.status='ACTIVE'
          and window_row.constraint_kind='AVAILABLE_WINDOW'
          and lower(window_row.time_range)<=(select min(starts_at) from role_shifts)
          and upper(window_row.time_range)>=(select max(ends_at) from role_shifts)))
  )
  select candidate.employee_id,candidate.employee_no from candidates candidate
  where not exists(select 1 from public.plan_assignments_v2 assignment
    join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
    where assignment.variant_id=p_variant_id and assignment.employee_id=candidate.employee_id
      and ((shift_row.ends_at<=(select min(starts_at) from role_shifts)
          and extract(epoch from ((select min(starts_at) from role_shifts)-shift_row.ends_at))/60<candidate.rest_minutes)
        or (shift_row.starts_at>=(select max(ends_at) from role_shifts)
          and extract(epoch from (shift_row.starts_at-(select max(ends_at) from role_shifts)))/60<candidate.rest_minutes)))
$$;

create or replace function solver_private.generate_standby_for_variant_uat_v2(
  p_variant_id uuid,p_month date,p_matrix_version_id uuid,p_role_id uuid,
  p_source_schedule_id uuid,p_source_role_schedule_id uuid
) returns integer language plpgsql security definer set search_path=''
as $$
declare v_date date; v_tier integer; v_employee uuid; v_created integer:=0; v_requested_tiers integer:=0;
begin
  if (p_source_schedule_id is null)=(p_source_role_schedule_id is null) then raise exception 'STANDBY_SOURCE_REQUIRED'; end if;
  select least(2,greatest(0,coalesce((matrix.settings->>'standbyTiersPerRoleDay')::integer,0)))
    into v_requested_tiers from public.matrix_versions matrix where matrix.id=p_matrix_version_id;
  if v_requested_tiers is null then raise exception 'MATRIX_VERSION_NOT_FOUND'; end if;
  update public.published_standby_assignments_v2 standby set status='SUPERSEDED'
  where standby.month=p_month and standby.role_id=p_role_id and standby.status='PLANNED'
    and (standby.source_schedule_id is distinct from p_source_schedule_id
      or standby.source_role_schedule_id is distinct from p_source_role_schedule_id);
  if v_requested_tiers=0 then return 0; end if;
  for v_date in select distinct source.shift_date from (
    select shift_row.shift_date from public.plan_assignments_v2 assignment
      join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
      where assignment.variant_id=p_variant_id and assignment.role_id=p_role_id
    union
    select shift_row.shift_date from public.plan_issues_v2 issue
      join public.plan_shifts_v2 shift_row on shift_row.id=issue.shift_id
      where issue.variant_id=p_variant_id and issue.role_id=p_role_id
  ) source order by source.shift_date loop
    for v_tier in 1..v_requested_tiers loop
      if v_tier=2 and exists(select 1 from public.plan_issues_v2 issue
        join public.plan_shifts_v2 shift_row on shift_row.id=issue.shift_id
        where issue.variant_id=p_variant_id and issue.role_id=p_role_id
          and issue.issue_code='UNFILLED_SLOT' and shift_row.shift_date=v_date) then
        continue;
      end if;
      select candidate.employee_id into v_employee
      from solver_private.standby_candidates_for_role_day_uat_v3(
        p_variant_id,p_matrix_version_id,p_month,p_role_id,v_date) candidate
      order by
        (select count(*) from public.published_standby_assignments_v2 history
          where history.month=p_month and history.role_id=p_role_id
            and history.employee_id=candidate.employee_id and history.tier=v_tier
            and history.status not in ('CANCELLED','SUPERSEDED')),
        (select count(*) from public.published_standby_assignments_v2 history
          where history.month=p_month and history.role_id=p_role_id
            and history.employee_id=candidate.employee_id
            and history.status not in ('CANCELLED','SUPERSEDED')),
        (select count(*) from public.published_standby_assignments_v2 history
          where history.month=p_month and history.employee_id=candidate.employee_id
            and history.status not in ('CANCELLED','SUPERSEDED')),
        candidate.employee_no,candidate.employee_id limit 1;
      if v_employee is null then exit; end if;
      insert into public.published_standby_assignments_v2(
        month,standby_date,matrix_version_id,role_id,employee_id,tier,
        source_variant_id,source_schedule_id,source_role_schedule_id,created_by
      ) values(p_month,v_date,p_matrix_version_id,p_role_id,v_employee,v_tier,
        p_variant_id,p_source_schedule_id,p_source_role_schedule_id,auth.uid());
      v_created:=v_created+1;
    end loop;
  end loop;
  return v_created;
end;
$$;

create or replace function public.optimizer_variant_standby_preview_uat_v1(p_variant_id uuid)
returns jsonb language plpgsql volatile security definer set search_path=''
as $$
declare v_matrix uuid; v_scope text; v_tiers integer:=0; v_month date; v_role_day record;
  v_tier integer; v_candidate record; v_counts jsonb:='{}'::jsonb; v_tier_counts jsonb:='{}'::jsonb;
  v_selected jsonb:='{}'::jsonb; v_result jsonb:='[]'::jsonb; v_key text;
begin
  select run.matrix_version_id,run.scope_type,run.month,
    greatest(0,least(2,coalesce((matrix.settings->>'standbyTiersPerRoleDay')::integer,2)))
  into v_matrix,v_scope,v_month,v_tiers
  from public.plan_variants_v2 variant join public.optimization_runs_v2 run on run.id=variant.run_id
  join public.matrix_versions matrix on matrix.id=run.matrix_version_id where variant.id=p_variant_id;
  if v_matrix is null then raise exception 'VARIANT_NOT_FOUND'; end if;
  if auth.uid() is null or not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or (v_scope='ROLE' and exists(select 1 from public.matrix_scope_grants_v2 grant_row
      join public.optimization_runs_v2 run on run.scope_role_id is not null
      join public.matrix_roles_v2 role on role.id=run.scope_role_id
      join public.plan_variants_v2 variant on variant.run_id=run.id
      where variant.id=p_variant_id and grant_row.auth_user_id=auth.uid() and grant_row.active
        and grant_row.app_role='ROLE_MANAGER'
        and (grant_row.role_logical_id is null or grant_row.role_logical_id=role.logical_id))))
    then raise exception 'VARIANT_NOT_AVAILABLE'; end if;
  if v_tiers=0 then return v_result; end if;
  for v_role_day in select source.shift_date,source.role_id,role.name role_name,role.sort_order
    from (select distinct shift.shift_date,assignment.role_id from public.plan_assignments_v2 assignment
      join public.plan_shifts_v2 shift on shift.id=assignment.shift_id where assignment.variant_id=p_variant_id
      union select distinct shift.shift_date,issue.role_id from public.plan_issues_v2 issue
      join public.plan_shifts_v2 shift on shift.id=issue.shift_id
      where issue.variant_id=p_variant_id and issue.role_id is not null) source
    join public.matrix_roles_v2 role on role.id=source.role_id
    order by source.shift_date,role.sort_order,role.id
  loop
    for v_tier in 1..v_tiers loop
      if v_tier=2 and exists(select 1 from public.plan_issues_v2 issue
        join public.plan_shifts_v2 shift on shift.id=issue.shift_id
        where issue.variant_id=p_variant_id and issue.role_id=v_role_day.role_id
          and issue.issue_code='UNFILLED_SLOT' and shift.shift_date=v_role_day.shift_date) then continue; end if;
      v_candidate:=null;
      select candidate.employee_id,candidate.employee_no,employee.first_name,employee.last_name
      into v_candidate from solver_private.standby_candidates_for_role_day_uat_v3(
        p_variant_id,v_matrix,v_month,v_role_day.role_id,v_role_day.shift_date) candidate
      join public.employees employee on employee.id=candidate.employee_id
      where not coalesce((v_selected->>(v_role_day.shift_date::text||':'||candidate.employee_id::text))::boolean,false)
      order by coalesce((v_tier_counts->>(v_role_day.role_id::text||':'||v_tier::text||':'||candidate.employee_id::text))::integer,0),
        coalesce((v_counts->>(v_role_day.role_id::text||':'||candidate.employee_id::text))::integer,0),
        candidate.employee_no,candidate.employee_id limit 1;
      if v_candidate.employee_id is null then exit; end if;
      v_key:=v_role_day.role_id::text||':'||v_candidate.employee_id::text;
      v_counts:=jsonb_set(v_counts,array[v_key],to_jsonb(coalesce((v_counts->>v_key)::integer,0)+1),true);
      v_key:=v_role_day.role_id::text||':'||v_tier::text||':'||v_candidate.employee_id::text;
      v_tier_counts:=jsonb_set(v_tier_counts,array[v_key],to_jsonb(coalesce((v_tier_counts->>v_key)::integer,0)+1),true);
      v_selected:=jsonb_set(v_selected,array[v_role_day.shift_date::text||':'||v_candidate.employee_id::text],'true'::jsonb,true);
      v_result:=v_result||jsonb_build_array(jsonb_build_object(
        'id',md5(p_variant_id::text||v_role_day.shift_date::text||v_role_day.role_id::text||v_tier::text),
        'date',v_role_day.shift_date,'tier',v_tier,'status','PREVIEW','roleId',v_role_day.role_id,
        'roleName',v_role_day.role_name,'employeeId',v_candidate.employee_id,'employeeNo',v_candidate.employee_no,
        'employeeName',trim(v_candidate.first_name||' '||v_candidate.last_name),
        'sourceType',case when v_scope='ROLE' then 'ROLE' else 'COMPANY' end,'activatedShiftId',null));
    end loop;
  end loop;
  return v_result;
end;
$$;

revoke all on function solver_private.standby_candidates_for_role_day_uat_v3(uuid,uuid,date,uuid,date),
  solver_private.generate_standby_for_variant_uat_v2(uuid,date,uuid,uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function solver_private.standby_candidates_for_role_day_uat_v3(uuid,uuid,date,uuid,date),
  solver_private.generate_standby_for_variant_uat_v2(uuid,date,uuid,uuid,uuid,uuid) to service_role;
revoke all on function public.optimizer_variant_standby_preview_uat_v1(uuid) from public,anon,authenticated;
grant execute on function public.optimizer_variant_standby_preview_uat_v1(uuid) to authenticated;
notify pgrst,'reload schema';
