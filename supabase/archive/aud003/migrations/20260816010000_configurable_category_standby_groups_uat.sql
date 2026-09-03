-- UAT: replace the global per-role reserve switch with explicit groups per
-- category. Omitted roles never create standby. Required coverage always wins.

alter table public.matrix_versions disable trigger zz_matrix_version_immutable_v2;
update public.matrix_versions
set settings = jsonb_set(
  jsonb_set(coalesce(settings,'{}'::jsonb),'{standbyTiersPerRoleDay}','0'::jsonb,true),
  '{standbyGroups}',coalesce(settings->'standbyGroups','[]'::jsonb),true
)
where schema_version >= 2;
alter table public.matrix_versions enable trigger zz_matrix_version_immutable_v2;

alter function public.matrix_v2_admin_save_alpha16(text,uuid,jsonb)
  rename to matrix_v2_admin_save_before_standby_groups_uat_v1;

create function public.matrix_v2_admin_save_alpha16(
  p_kind text,p_id uuid,p_data jsonb
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare
  v_payload jsonb:=coalesce(p_data,'{}'::jsonb);
  v_groups jsonb:='[]'::jsonb;
  v_group jsonb;
  v_matrix uuid;
  v_category uuid;
  v_result jsonb;
begin
  if upper(trim(p_kind))='MATRIX_SETTINGS' then
    v_groups:=coalesce(v_payload->'standbyGroups','[]'::jsonb);
    if jsonb_typeof(v_groups)<>'array' then raise exception 'INVALID_STANDBY_GROUPS'; end if;
    select id into v_matrix from public.matrix_versions
    where status='DRAFT' and schema_version>=2 order by version desc limit 1;
    if v_matrix is null then raise exception 'MATRIX_V2_DRAFT_NOT_FOUND'; end if;
    if exists(
      select 1 from jsonb_array_elements(v_groups) item
      where coalesce(item.value->>'code','') !~ '^[A-Za-z0-9_\-]{1,80}$'
        or length(trim(coalesce(item.value->>'name',''))) < 1
        or coalesce(item.value->>'categoryCode','') = ''
        or jsonb_typeof(coalesce(item.value->'roleCodes','null'::jsonb)) <> 'array'
        or jsonb_array_length(coalesce(item.value->'roleCodes','[]'::jsonb)) = 0
        or coalesce(item.value->>'tiers','') !~ '^[12]$'
    ) then raise exception 'INVALID_STANDBY_GROUP'; end if;
    for v_group in select value from jsonb_array_elements(v_groups) loop
      select category.id into v_category from public.matrix_role_categories_v2 category
      where category.matrix_version_id=v_matrix and category.active
        and upper(category.code)=upper(v_group->>'categoryCode');
      if v_category is null then raise exception 'STANDBY_GROUP_CATEGORY_NOT_FOUND:%',v_group->>'categoryCode'; end if;
      if exists(
        select 1 from jsonb_array_elements_text(v_group->'roleCodes') role_code
        where not exists(select 1 from public.matrix_roles_v2 role_row
          where role_row.matrix_version_id=v_matrix and role_row.active
            and role_row.category_id=v_category and upper(role_row.code)=upper(role_code.value))
      ) then raise exception 'STANDBY_GROUP_ROLE_NOT_FOUND_OR_WRONG_CATEGORY:%',v_group->>'code'; end if;
    end loop;
    if exists(
      select upper(role_code.value)
      from jsonb_array_elements(v_groups) item
      cross join lateral jsonb_array_elements_text(item.value->'roleCodes') role_code
      group by upper(role_code.value) having count(*)>1
    ) then raise exception 'STANDBY_ROLE_USED_IN_MULTIPLE_GROUPS'; end if;
    v_payload:=v_payload||jsonb_build_object('standbyTiersPerRoleDay',0,'standbyGroups',v_groups);
  end if;
  v_result:=public.matrix_v2_admin_save_before_standby_groups_uat_v1(p_kind,p_id,v_payload);
  if upper(trim(p_kind))='MATRIX_SETTINGS' then
    update public.matrix_versions set settings=jsonb_set(
      jsonb_set(coalesce(settings,'{}'::jsonb),'{standbyTiersPerRoleDay}','0'::jsonb,true),
      '{standbyGroups}',v_groups,true
    ) where id=(v_result->>'id')::uuid;
  end if;
  return v_result;
end;
$$;

alter table public.published_standby_assignments_v2
  add column if not exists standby_group_code text,
  add column if not exists standby_group_name text,
  add column if not exists standby_category_code text,
  add column if not exists eligible_role_ids uuid[];

update public.published_standby_assignments_v2 standby
set standby_group_code=coalesce(standby_group_code,'LEGACY_'||role_id::text),
  standby_group_name=coalesce(standby_group_name,(select role.name from public.matrix_roles_v2 role where role.id=standby.role_id)),
  eligible_role_ids=coalesce(eligible_role_ids,array[role_id]);

create or replace function solver_private.standby_candidates_for_group_day_uat_v1(
  p_variant_id uuid,p_matrix_version_id uuid,p_month date,p_role_ids uuid[],p_date date
) returns table(employee_id uuid,employee_no text,eligible_role_ids uuid[])
language sql stable security definer set search_path=''
as $$
  with settings as (
    select coalesce((matrix.settings->>'missingAvailabilityMeansAvailable')::boolean,true) default_available,
      coalesce((matrix.settings->>'minimumRestMinutes')::integer,660) default_rest
    from public.matrix_versions matrix where matrix.id=p_matrix_version_id
  ), group_shifts as (
    select distinct shift_row.id,shift_row.location_id,shift_row.shift_template_id,shift_row.starts_at,shift_row.ends_at
    from public.plan_assignments_v2 assignment join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
    where assignment.variant_id=p_variant_id and assignment.role_id=any(p_role_ids) and shift_row.shift_date=p_date
    union
    select distinct shift_row.id,shift_row.location_id,shift_row.shift_template_id,shift_row.starts_at,shift_row.ends_at
    from public.plan_issues_v2 issue join public.plan_shifts_v2 shift_row on shift_row.id=issue.shift_id
    where issue.variant_id=p_variant_id and issue.role_id=any(p_role_ids) and shift_row.shift_date=p_date
  ), candidates as (
    select profile.employee_id,profile.employee_no,
      array_agg(distinct role_grant.role_id order by role_grant.role_id) eligible_roles,
      case when coalesce(hr.contract_type,'INNE') in ('ZLECENIE','B2B') and profile.work_time_policy<>'CUSTOM' then 0
        else coalesce(profile.minimum_rest_minutes,settings.default_rest,660) end rest_minutes
    from public.matrix_employee_profiles_v2 profile
    cross join settings
    left join public.employee_hr_profiles hr on hr.employee_id=profile.employee_id
    join public.matrix_employee_roles_v2 role_grant
      on role_grant.matrix_version_id=p_matrix_version_id and role_grant.employee_id=profile.employee_id
     and role_grant.role_id=any(p_role_ids) and role_grant.active
     and (role_grant.valid_from is null or role_grant.valid_from<=p_date)
     and (role_grant.valid_to is null or role_grant.valid_to>=p_date)
    where profile.matrix_version_id=p_matrix_version_id and profile.active and profile.archived_at is null
      and (profile.employment_start is null or profile.employment_start<=p_date)
      and (profile.employment_end is null or profile.employment_end>=p_date)
      and (not profile.no_weekends or extract(isodow from p_date) not in (6,7))
      and (not profile.only_morning or not exists(select 1 from group_shifts group_shift
        join public.matrix_shift_templates_v2 template on template.id=group_shift.shift_template_id where template.shift_period<>'MORNING'))
      and (not profile.only_evening or not exists(select 1 from group_shifts group_shift
        join public.matrix_shift_templates_v2 template on template.id=group_shift.shift_template_id where template.shift_period<>'EVENING'))
      and not exists(select 1 from public.plan_assignments_v2 assignment
        join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
        where assignment.variant_id=p_variant_id and assignment.employee_id=profile.employee_id and shift_row.shift_date=p_date)
      and not exists(select 1 from public.published_role_schedules_v2 publication
        join public.plan_assignments_v2 assignment on assignment.variant_id=publication.variant_id
        join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
        where publication.month=p_month and publication.status='PUBLISHED'
          and assignment.employee_id=profile.employee_id and shift_row.shift_date=p_date)
      and not exists(select 1 from public.published_standby_assignments_v2 standby
        where standby.month=p_month and standby.standby_date=p_date and standby.employee_id=profile.employee_id
          and standby.status in ('PLANNED','ACTIVATED'))
      and not exists(select 1 from group_shifts group_shift where not exists(
        select 1 from public.matrix_employee_locations_v2 location_grant
        where location_grant.matrix_version_id=p_matrix_version_id and location_grant.employee_id=profile.employee_id
          and location_grant.location_id=group_shift.location_id and location_grant.active and location_grant.standard_allowed
          and (location_grant.valid_from is null or location_grant.valid_from<=p_date)
          and (location_grant.valid_to is null or location_grant.valid_to>=p_date)))
      and not exists(select 1 from group_shifts group_shift join public.employee_time_constraints_v2 constraint_row
        on constraint_row.employee_id=profile.employee_id and constraint_row.status='ACTIVE'
       and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
       and constraint_row.time_range&&tstzrange(group_shift.starts_at,group_shift.ends_at,'[)'))
      and (settings.default_available or exists(select 1 from public.employee_time_constraints_v2 window_row
        where window_row.employee_id=profile.employee_id and window_row.status='ACTIVE'
          and window_row.constraint_kind='AVAILABLE_WINDOW'
          and lower(window_row.time_range)<=(select min(starts_at) from group_shifts)
          and upper(window_row.time_range)>=(select max(ends_at) from group_shifts)))
    group by profile.employee_id,profile.employee_no,hr.contract_type,profile.work_time_policy,
      profile.minimum_rest_minutes,settings.default_rest
  )
  select candidate.employee_id,candidate.employee_no,candidate.eligible_roles from candidates candidate
  where not exists(select 1 from public.plan_assignments_v2 assignment
    join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
    where assignment.variant_id=p_variant_id and assignment.employee_id=candidate.employee_id
      and ((shift_row.ends_at<=(select min(starts_at) from group_shifts)
          and extract(epoch from ((select min(starts_at) from group_shifts)-shift_row.ends_at))/60<candidate.rest_minutes)
        or (shift_row.starts_at>=(select max(ends_at) from group_shifts)
          and extract(epoch from (shift_row.starts_at-(select max(ends_at) from group_shifts)))/60<candidate.rest_minutes)))
$$;

create or replace function solver_private.generate_standby_for_variant_uat_v2(
  p_variant_id uuid,p_month date,p_matrix_version_id uuid,p_role_id uuid,
  p_source_schedule_id uuid,p_source_role_schedule_id uuid
) returns integer language plpgsql security definer set search_path=''
as $$
declare
  v_group jsonb;v_groups jsonb;v_role_ids uuid[];v_canonical uuid;v_input_category text;
  v_date date;v_tier integer;v_candidate record;v_created integer:=0;
begin
  if (p_source_schedule_id is null)=(p_source_role_schedule_id is null) then raise exception 'STANDBY_SOURCE_REQUIRED'; end if;
  select coalesce(matrix.settings->'standbyGroups','[]'::jsonb) into v_groups
    from public.matrix_versions matrix where matrix.id=p_matrix_version_id;
  select category.code into v_input_category from public.matrix_roles_v2 role_row
    join public.matrix_role_categories_v2 category on category.id=role_row.category_id where role_row.id=p_role_id;
  for v_group in select value from jsonb_array_elements(v_groups) loop
    select array_agg(role_row.id order by role_code.ordinality)
    into v_role_ids from jsonb_array_elements_text(v_group->'roleCodes') with ordinality role_code(value,ordinality)
    join public.matrix_roles_v2 role_row on role_row.matrix_version_id=p_matrix_version_id
      and role_row.active and upper(role_row.code)=upper(role_code.value);
    v_canonical:=v_role_ids[1];
    if p_source_role_schedule_id is not null then
      if upper(v_group->>'categoryCode') is distinct from upper(v_input_category) then continue; end if;
    elsif v_canonical is distinct from p_role_id then continue;
    end if;
    update public.published_standby_assignments_v2 standby set status='SUPERSEDED'
    where standby.month=p_month and standby.standby_group_code=v_group->>'code' and standby.status='PLANNED'
      and (standby.source_schedule_id is distinct from p_source_schedule_id
        or standby.source_role_schedule_id is distinct from p_source_role_schedule_id);
    for v_date in select distinct source.shift_date from (
      select shift_row.shift_date from public.plan_assignments_v2 assignment
        join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
        where assignment.variant_id=p_variant_id and assignment.role_id=any(v_role_ids)
      union
      select shift_row.shift_date from public.plan_issues_v2 issue
        join public.plan_shifts_v2 shift_row on shift_row.id=issue.shift_id
        where issue.variant_id=p_variant_id and issue.role_id=any(v_role_ids)
    ) source order by source.shift_date loop
      if exists(select 1 from public.plan_issues_v2 issue join public.plan_shifts_v2 shift_row on shift_row.id=issue.shift_id
        where issue.variant_id=p_variant_id and issue.role_id=any(v_role_ids)
          and issue.issue_code='UNFILLED_SLOT' and shift_row.shift_date=v_date) then continue; end if;
      for v_tier in 1..least(2,greatest(1,(v_group->>'tiers')::integer)) loop
        v_candidate:=null;
        select candidate.employee_id,candidate.employee_no,candidate.eligible_role_ids into v_candidate
        from solver_private.standby_candidates_for_group_day_uat_v1(
          p_variant_id,p_matrix_version_id,p_month,v_role_ids,v_date) candidate
        order by
          (select count(*) from public.published_standby_assignments_v2 history
            where history.month=p_month and history.standby_group_code=v_group->>'code'
              and history.employee_id=candidate.employee_id and history.tier=v_tier
              and history.status not in ('CANCELLED','SUPERSEDED')),
          (select count(*) from public.published_standby_assignments_v2 history
            where history.month=p_month and history.standby_group_code=v_group->>'code'
              and history.employee_id=candidate.employee_id and history.status not in ('CANCELLED','SUPERSEDED')),
          (select count(*) from public.published_standby_assignments_v2 history
            where history.month=p_month and history.employee_id=candidate.employee_id
              and history.status not in ('CANCELLED','SUPERSEDED')),
          candidate.employee_no,candidate.employee_id limit 1;
        if v_candidate.employee_id is null then exit; end if;
        insert into public.published_standby_assignments_v2(
          month,standby_date,matrix_version_id,role_id,employee_id,tier,
          source_variant_id,source_schedule_id,source_role_schedule_id,created_by,
          standby_group_code,standby_group_name,standby_category_code,eligible_role_ids
        ) values(
          p_month,v_date,p_matrix_version_id,v_canonical,v_candidate.employee_id,v_tier,
          p_variant_id,p_source_schedule_id,p_source_role_schedule_id,auth.uid(),
          v_group->>'code',v_group->>'name',v_group->>'categoryCode',v_candidate.eligible_role_ids
        );
        v_created:=v_created+1;
      end loop;
    end loop;
  end loop;
  return v_created;
end;
$$;

create or replace function public.optimizer_variant_standby_preview_uat_v2(p_variant_id uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare
  v_matrix uuid;v_scope text;v_month date;v_groups jsonb;v_group jsonb;v_role_ids uuid[];v_canonical uuid;
  v_date date;v_tier integer;v_candidate record;v_counts jsonb:='{}'::jsonb;v_selected jsonb:='{}'::jsonb;
  v_result jsonb:='[]'::jsonb;v_key text;v_role_names jsonb;
begin
  select run.matrix_version_id,run.scope_type,run.month,coalesce(matrix.settings->'standbyGroups','[]'::jsonb)
  into v_matrix,v_scope,v_month,v_groups
  from public.plan_variants_v2 variant join public.optimization_runs_v2 run on run.id=variant.run_id
  join public.matrix_versions matrix on matrix.id=run.matrix_version_id where variant.id=p_variant_id;
  if v_matrix is null then raise exception 'VARIANT_NOT_FOUND'; end if;
  if auth.uid() is null or not solver_private.can_access_run_v2((select run_id from public.plan_variants_v2 where id=p_variant_id))
    then raise exception 'VARIANT_NOT_AVAILABLE'; end if;
  for v_group in select value from jsonb_array_elements(v_groups) loop
    select array_agg(role_row.id order by role_code.ordinality)
    into v_role_ids from jsonb_array_elements_text(v_group->'roleCodes') with ordinality role_code(value,ordinality)
    join public.matrix_roles_v2 role_row on role_row.matrix_version_id=v_matrix and role_row.active
      and upper(role_row.code)=upper(role_code.value);
    v_canonical:=v_role_ids[1];
    if not exists(select 1 from public.plan_assignments_v2 where variant_id=p_variant_id and role_id=any(v_role_ids)
      union all select 1 from public.plan_issues_v2 where variant_id=p_variant_id and role_id=any(v_role_ids)) then continue; end if;
    for v_date in select distinct source.shift_date from (
      select shift_row.shift_date from public.plan_assignments_v2 assignment join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
        where assignment.variant_id=p_variant_id and assignment.role_id=any(v_role_ids)
      union select shift_row.shift_date from public.plan_issues_v2 issue join public.plan_shifts_v2 shift_row on shift_row.id=issue.shift_id
        where issue.variant_id=p_variant_id and issue.role_id=any(v_role_ids)
    ) source order by source.shift_date loop
      if exists(select 1 from public.plan_issues_v2 issue join public.plan_shifts_v2 shift_row on shift_row.id=issue.shift_id
        where issue.variant_id=p_variant_id and issue.role_id=any(v_role_ids)
          and issue.issue_code='UNFILLED_SLOT' and shift_row.shift_date=v_date) then continue; end if;
      for v_tier in 1..least(2,greatest(1,(v_group->>'tiers')::integer)) loop
        v_candidate:=null;
        select candidate.employee_id,candidate.employee_no,candidate.eligible_role_ids,employee.first_name,employee.last_name
        into v_candidate from solver_private.standby_candidates_for_group_day_uat_v1(
          p_variant_id,v_matrix,v_month,v_role_ids,v_date) candidate
        join public.employees employee on employee.id=candidate.employee_id
        where not coalesce((v_selected->>(v_date::text||':'||candidate.employee_id::text))::boolean,false)
        order by coalesce((v_counts->>(v_group->>'code'||':'||candidate.employee_id::text))::integer,0),
          candidate.employee_no,candidate.employee_id limit 1;
        if v_candidate.employee_id is null then exit; end if;
        select coalesce(jsonb_agg(role_row.name order by role_row.sort_order,role_row.name),'[]'::jsonb)
        into v_role_names from public.matrix_roles_v2 role_row
        where role_row.id=any(v_candidate.eligible_role_ids);
        v_key:=v_group->>'code'||':'||v_candidate.employee_id::text;
        v_counts:=jsonb_set(v_counts,array[v_key],to_jsonb(coalesce((v_counts->>v_key)::integer,0)+1),true);
        v_selected:=jsonb_set(v_selected,array[v_date::text||':'||v_candidate.employee_id::text],'true'::jsonb,true);
        v_result:=v_result||jsonb_build_array(jsonb_build_object(
          'id',md5(p_variant_id::text||v_date::text||v_group->>'code'||v_tier::text),
          'date',v_date,'tier',v_tier,'status','PREVIEW','roleId',v_canonical,
          'roleName',v_group->>'name','groupCode',v_group->>'code','groupName',v_group->>'name',
          'eligibleRoleIds',to_jsonb(v_candidate.eligible_role_ids),'eligibleRoleNames',v_role_names,
          'employeeId',v_candidate.employee_id,'employeeNo',v_candidate.employee_no,
          'employeeName',trim(v_candidate.first_name||' '||v_candidate.last_name),
          'sourceType',case when v_scope='ROLE' then 'ROLE' else 'COMPANY' end,'activatedShiftId',null));
      end loop;
    end loop;
  end loop;
  return v_result;
end;
$$;

create or replace function public.manager_standby_month_uat_v3(
  p_month date,p_scope_role_id uuid default null
) returns jsonb language plpgsql stable security invoker set search_path=''
as $$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id',standby.id,'date',standby.standby_date,'tier',standby.tier,'status',standby.status,
    'roleId',standby.role_id,'roleName',coalesce(standby.standby_group_name,role.name),
    'groupCode',standby.standby_group_code,'groupName',standby.standby_group_name,
    'eligibleRoleIds',to_jsonb(coalesce(standby.eligible_role_ids,array[standby.role_id])),
    'eligibleRoleNames',coalesce((select jsonb_agg(group_role.name order by group_role.sort_order,group_role.name)
      from public.matrix_roles_v2 group_role where group_role.id=any(coalesce(standby.eligible_role_ids,array[standby.role_id]))),'[]'::jsonb),
    'employeeId',standby.employee_id,'employeeNo',employee.employee_no,
    'employeeName',concat_ws(' ',employee.first_name,employee.last_name),
    'sourceType',case when standby.source_role_schedule_id is null then 'COMPANY' else 'ROLE' end,
    'activatedShiftId',standby.activated_shift_id
  ) order by standby.standby_date,coalesce(standby.standby_group_name,role.name),standby.tier)
  from public.published_standby_assignments_v2 standby
  join public.matrix_roles_v2 role on role.id=standby.role_id
  join public.employees employee on employee.id=standby.employee_id
  where standby.month=date_trunc('month',p_month)::date and standby.status in ('PLANNED','ACTIVATED','DECLINED')
    and (p_scope_role_id is null or standby.role_id=p_scope_role_id
      or p_scope_role_id=any(coalesce(standby.eligible_role_ids,'{}'::uuid[]))
      or standby.standby_category_code=(select category.code from public.matrix_roles_v2 scope_role
        join public.matrix_role_categories_v2 category on category.id=scope_role.category_id where scope_role.id=p_scope_role_id)
    )),'[]'::jsonb);
end;
$$;

create or replace function public.standby_activate_uat_v3(
  p_standby_id uuid,p_original_assignment_id uuid,p_reason text
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_standby public.published_standby_assignments_v2%rowtype;v_assignment public.plan_assignments_v2%rowtype;
begin
  select * into v_standby from public.published_standby_assignments_v2 where id=p_standby_id for update;
  select * into v_assignment from public.plan_assignments_v2 where id=p_original_assignment_id;
  if v_standby.id is null or v_assignment.id is null or not (v_assignment.role_id=any(coalesce(v_standby.eligible_role_ids,array[v_standby.role_id]))) then
    raise exception 'STANDBY_TARGET_ROLE_NOT_COVERED';
  end if;
  if v_standby.tier=2 and exists(select 1 from public.published_standby_assignments_v2 tier1
    where tier1.month=v_standby.month and tier1.standby_date=v_standby.standby_date
      and coalesce(tier1.standby_group_code,tier1.role_id::text)=coalesce(v_standby.standby_group_code,v_standby.role_id::text)
      and tier1.tier=1 and tier1.status='PLANNED') then
    raise exception 'STANDBY_TIER_1_MUST_BE_USED_OR_DECLINED_FIRST';
  end if;
  update public.published_standby_assignments_v2 set role_id=v_assignment.role_id where id=p_standby_id;
  return public.standby_activate_uat_v2(p_standby_id,p_original_assignment_id,p_reason);
end;
$$;

revoke all on function public.matrix_v2_admin_save_alpha16(text,uuid,jsonb),
  public.optimizer_variant_standby_preview_uat_v2(uuid),public.manager_standby_month_uat_v3(date,uuid),
  public.standby_activate_uat_v3(uuid,uuid,text) from public,anon;
grant execute on function public.matrix_v2_admin_save_alpha16(text,uuid,jsonb),
  public.optimizer_variant_standby_preview_uat_v2(uuid),public.manager_standby_month_uat_v3(date,uuid),
  public.standby_activate_uat_v3(uuid,uuid,text) to authenticated;
revoke all on function solver_private.standby_candidates_for_group_day_uat_v1(uuid,uuid,date,uuid[],date),
  solver_private.generate_standby_for_variant_uat_v2(uuid,date,uuid,uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function solver_private.standby_candidates_for_group_day_uat_v1(uuid,uuid,date,uuid[],date),
  solver_private.generate_standby_for_variant_uat_v2(uuid,date,uuid,uuid,uuid,uuid) to service_role;

notify pgrst,'reload schema';
