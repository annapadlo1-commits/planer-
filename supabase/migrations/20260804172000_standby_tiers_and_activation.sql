-- GRAFIK PRO 3.0 — daily role stand-by Tier 1 / Tier 2.
-- Stand-by is intentionally separate from ordinary paid assignments.  It is
-- generated from a published variant, displayed separately, and becomes an
-- operational assignment only after an audited activation.

create table public.published_standby_assignments_v2 (
  id uuid primary key default gen_random_uuid(),
  month date not null check(date_trunc('month',month)::date=month),
  standby_date date not null,
  matrix_version_id uuid not null references public.matrix_versions(id),
  role_id uuid not null references public.matrix_roles_v2(id),
  employee_id uuid not null references public.employees(id),
  tier smallint not null check(tier in (1,2)),
  source_variant_id uuid not null references public.plan_variants_v2(id),
  source_schedule_id uuid references public.published_schedules_v2(id),
  source_role_schedule_id uuid references public.published_role_schedules_v2(id),
  status text not null default 'PLANNED'
    check(status in ('PLANNED','ACTIVATED','DECLINED','CANCELLED','SUPERSEDED')),
  activated_shift_id uuid references public.plan_shifts_v2(id),
  activated_assignment_id uuid references public.plan_assignments_v2(id),
  activated_at timestamptz,
  activated_by uuid references auth.users(id),
  activation_reason text,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  check(standby_date>=month and standby_date<(month+interval '1 month')::date),
  check((source_schedule_id is null)<>(source_role_schedule_id is null)),
  check((status='ACTIVATED')=(activated_at is not null))
);

create unique index published_standby_one_tier_role_day_v2
  on public.published_standby_assignments_v2(month,role_id,standby_date,tier)
  where status in ('PLANNED','ACTIVATED');
create unique index published_standby_one_role_per_employee_day_v2
  on public.published_standby_assignments_v2(month,employee_id,standby_date)
  where status in ('PLANNED','ACTIVATED');
create index published_standby_employee_month_v2
  on public.published_standby_assignments_v2(employee_id,month,standby_date);

create table public.operational_assignment_replacements_v2 (
  id uuid primary key default gen_random_uuid(),
  month date not null check(date_trunc('month',month)::date=month),
  original_assignment_id uuid not null references public.plan_assignments_v2(id),
  replacement_employee_id uuid not null references public.employees(id),
  standby_assignment_id uuid references public.published_standby_assignments_v2(id),
  status text not null default 'ACTIVE' check(status in ('ACTIVE','REVOKED','SUPERSEDED')),
  reason text not null check(length(trim(reason))>=3),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  revoked_by uuid references auth.users(id),
  revoked_at timestamptz,
  unique(original_assignment_id,status)
);

alter table public.published_standby_assignments_v2 enable row level security;
alter table public.operational_assignment_replacements_v2 enable row level security;

create policy published_standby_self_or_manager_read_v2
on public.published_standby_assignments_v2 for select to authenticated
using (
  employee_id in (select employee.id from public.employees employee
    where employee.auth_user_id=(select auth.uid()))
  or (select public.can_manage_plans())
  or (select public.has_app_role('HR_FINANCE'))
);
create policy operational_replacements_self_or_manager_read_v2
on public.operational_assignment_replacements_v2 for select to authenticated
using (
  (select public.can_manage_plans())
  or replacement_employee_id in (select employee.id from public.employees employee
    where employee.auth_user_id=(select auth.uid()))
  or original_assignment_id in (select assignment.id
    from public.plan_assignments_v2 assignment
    join public.employees employee on employee.id=assignment.employee_id
    where employee.auth_user_id=(select auth.uid()))
);

revoke all on table public.published_standby_assignments_v2,
  public.operational_assignment_replacements_v2 from public,anon,authenticated;
grant select on table public.published_standby_assignments_v2,
  public.operational_assignment_replacements_v2 to authenticated;
grant all on table public.published_standby_assignments_v2,
  public.operational_assignment_replacements_v2 to service_role;

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

create or replace function solver_private.generate_published_standby_trigger_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_schedule public.published_schedules_v2%rowtype;
  v_role uuid;
begin
  if tg_table_name='published_role_schedules_v2' then
    if exists(
      select 1
      from public.plan_assignments_v2 assignment
      join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
      join public.published_standby_assignments_v2 standby
        on standby.employee_id=assignment.employee_id
       and standby.standby_date=shift_row.shift_date
       and standby.month=new.month
       and standby.status in ('PLANNED','ACTIVATED')
      where assignment.variant_id=new.variant_id
    ) then
      raise exception 'ROLE_PUBLICATION_CONFLICTS_WITH_EXISTING_STANDBY';
    end if;
    perform solver_private.generate_standby_for_variant_uat_v2(
      new.variant_id,new.month,new.matrix_version_id,new.role_id,null,new.id
    );
    return new;
  end if;
  select schedule.* into v_schedule
  from public.published_schedules_v2 schedule where schedule.id=new.schedule_id;
  if v_schedule.source_type='COMPANY' then
    if exists(
      select 1
      from public.plan_assignments_v2 assignment
      join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
      join public.published_standby_assignments_v2 standby
        on standby.employee_id=assignment.employee_id
       and standby.standby_date=shift_row.shift_date
       and standby.month=v_schedule.month
       and standby.status in ('PLANNED','ACTIVATED')
      where assignment.variant_id=new.variant_id
    ) then
      raise exception 'COMPANY_PUBLICATION_CONFLICTS_WITH_EXISTING_STANDBY';
    end if;
    for v_role in
      select distinct source.role_id from (
        select assignment.role_id from public.plan_assignments_v2 assignment
        where assignment.variant_id=new.variant_id
        union select issue.role_id from public.plan_issues_v2 issue
        where issue.variant_id=new.variant_id and issue.role_id is not null
      ) source
    loop
      perform solver_private.generate_standby_for_variant_uat_v2(
        new.variant_id,v_schedule.month,v_schedule.matrix_version_id,v_role,
        v_schedule.id,null
      );
    end loop;
  end if;
  return new;
end;
$$;

create or replace function solver_private.supersede_standby_with_source_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.status='PUBLISHED' and new.status='ARCHIVED' then
    if tg_table_name='published_role_schedules_v2' then
      update public.published_standby_assignments_v2 standby set status='SUPERSEDED'
      where standby.source_role_schedule_id=new.id and standby.status='PLANNED';
    else
      update public.published_standby_assignments_v2 standby set status='SUPERSEDED'
      where standby.source_schedule_id=new.id and standby.status='PLANNED';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists published_role_generate_standby_v2
  on public.published_role_schedules_v2;
create trigger published_role_generate_standby_v2
after insert on public.published_role_schedules_v2
for each row execute function solver_private.generate_published_standby_trigger_v2();
drop trigger if exists published_company_generate_standby_v2
  on public.published_schedule_variants_v2;
create trigger published_company_generate_standby_v2
after insert on public.published_schedule_variants_v2
for each row execute function solver_private.generate_published_standby_trigger_v2();

drop trigger if exists published_role_supersede_standby_v2
  on public.published_role_schedules_v2;
create trigger published_role_supersede_standby_v2
after update of status on public.published_role_schedules_v2
for each row execute function solver_private.supersede_standby_with_source_v2();
drop trigger if exists published_company_supersede_standby_v2
  on public.published_schedules_v2;
create trigger published_company_supersede_standby_v2
after update of status on public.published_schedules_v2
for each row execute function solver_private.supersede_standby_with_source_v2();

create or replace function solver_private.rebuild_standby_month_v2(p_month date)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_month date:=date_trunc('month',p_month)::date;
  v_role_schedule public.published_role_schedules_v2%rowtype;
  v_schedule public.published_schedules_v2%rowtype;
  v_link record;
  v_created integer:=0;
begin
  update public.published_standby_assignments_v2 standby set status='SUPERSEDED'
  where standby.month=v_month and standby.status='PLANNED';
  for v_role_schedule in
    select publication.* from public.published_role_schedules_v2 publication
    where publication.month=v_month and publication.status='PUBLISHED'
    order by publication.role_id
  loop
    v_created:=v_created+solver_private.generate_standby_for_variant_uat_v2(
      v_role_schedule.variant_id,v_month,v_role_schedule.matrix_version_id,
      v_role_schedule.role_id,null,v_role_schedule.id
    );
  end loop;
  if v_created=0 then
    select schedule.* into v_schedule from public.published_schedules_v2 schedule
    where schedule.month=v_month and schedule.status='PUBLISHED'
      and schedule.source_type='COMPANY'
    order by schedule.published_at desc,schedule.id desc limit 1;
    if v_schedule.id is not null then
      for v_link in
        select distinct on (source.role_id) link.variant_id,source.role_id
        from public.published_schedule_variants_v2 link
        cross join lateral (
          select distinct assignment.role_id
          from public.plan_assignments_v2 assignment
          where assignment.variant_id=link.variant_id
        ) source
        where link.schedule_id=v_schedule.id
        order by source.role_id,link.ordinal
      loop
        v_created:=v_created+solver_private.generate_standby_for_variant_uat_v2(
          v_link.variant_id,v_month,v_schedule.matrix_version_id,v_link.role_id,
          v_schedule.id,null
        );
      end loop;
    end if;
  end if;
  return v_created;
end;
$$;

create or replace function public.schedule_publication_resolve_with_standby_uat_v2(
  p_month date,
  p_keep_source text,
  p_reason text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
  v_standby integer;
begin
  v_result:=public.schedule_publication_resolve_uat_v2(
    p_month,p_keep_source,p_reason
  );
  v_standby:=solver_private.rebuild_standby_month_v2(p_month);
  return v_result||jsonb_build_object('standbyAssignments',v_standby);
end;
$$;

create or replace function public.standby_decline_self_uat_v2(
  p_standby_id uuid,
  p_reason text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_employee uuid;
begin
  select employee.id into v_employee from public.employees employee
  where employee.auth_user_id=auth.uid() and employee.active;
  update public.published_standby_assignments_v2 standby set
    status='DECLINED',activation_reason=trim(p_reason)
  where standby.id=p_standby_id and standby.employee_id=v_employee
    and standby.status='PLANNED';
  if not found then raise exception 'STANDBY_NOT_DECLINABLE'; end if;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'standby_assignment_v2',p_standby_id::text,'DECLINE',
    jsonb_build_object('reason',trim(p_reason)));
  return jsonb_build_object('id',p_standby_id,'status','DECLINED');
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
-- employee read model without counting PLANNED stand-by as worked hours.
create or replace function public.optimizer_employee_schedule_uat_v3(p_month date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_status jsonb;
  v_result jsonb;
  v_employee uuid;
  v_month date:=date_trunc('month',p_month)::date;
  v_assignments jsonb;
  v_replacements jsonb;
begin
  v_status:=public.schedule_publication_status_uat_v2(v_month);
  if coalesce((v_status->>'conflict')::boolean,false) then
    raise exception 'SCHEDULE_PUBLICATION_CONFLICT_REQUIRES_OWNER_RESOLUTION';
  end if;
  select employee.id into v_employee from public.employees employee
  where employee.auth_user_id=auth.uid() and employee.active
  order by employee.employee_no limit 1;
  v_result:=public.optimizer_employee_schedule_uat_v2(v_month);
  v_assignments:=coalesce(v_result->'assignments','[]'::jsonb);
  select coalesce(jsonb_agg(item.value),'[]'::jsonb) into v_assignments
  from jsonb_array_elements(v_assignments) item
  where not exists(select 1 from public.operational_assignment_replacements_v2 replacement
    where replacement.original_assignment_id=(item.value->>'id')::uuid
      and replacement.status='ACTIVE');
  select coalesce(jsonb_agg(original.value||jsonb_build_object(
    'id',replacement.id,'replacementOfAssignmentId',replacement.original_assignment_id,
    'isReplacement',true
  ) order by original.value->>'startsAt'),'[]'::jsonb) into v_replacements
  from public.operational_assignment_replacements_v2 replacement
  cross join lateral jsonb_array_elements(
    public.optimizer_employee_schedule_uat_v2(v_month)->'assignments'
  ) original(value)
  where replacement.month=v_month and replacement.status='ACTIVE'
    and replacement.replacement_employee_id=v_employee
    and original.value->>'id'=replacement.original_assignment_id::text;
  return jsonb_set(
    jsonb_set(v_result,'{assignments}',v_assignments||v_replacements,true),
    '{standby}',coalesce((select jsonb_agg(jsonb_build_object(
      'id',standby.id,'date',standby.standby_date,'tier',standby.tier,
      'status',standby.status,'roleId',standby.role_id,'roleName',role.name,
      'activatedShiftId',standby.activated_shift_id
    ) order by standby.standby_date,standby.tier)
      from public.published_standby_assignments_v2 standby
      join public.matrix_roles_v2 role on role.id=standby.role_id
      where standby.employee_id=v_employee and standby.month=v_month
        and standby.status in ('PLANNED','ACTIVATED','DECLINED')
    ),'[]'::jsonb),true
  );
end;
$$;

revoke all on function solver_private.generate_standby_for_variant_uat_v2(
  uuid,date,uuid,uuid,uuid,uuid
),solver_private.generate_published_standby_trigger_v2(),
  solver_private.supersede_standby_with_source_v2(),
  solver_private.rebuild_standby_month_v2(date)
  from public,anon,authenticated;
revoke all on function public.standby_decline_self_uat_v2(uuid,text),
  public.standby_activate_uat_v2(uuid,uuid,text),
  public.optimizer_employee_schedule_uat_v3(date),
  public.schedule_publication_resolve_with_standby_uat_v2(date,text,text)
  from public,anon,authenticated;
grant execute on function public.standby_decline_self_uat_v2(uuid,text),
  public.standby_activate_uat_v2(uuid,uuid,text),
  public.optimizer_employee_schedule_uat_v3(date),
  public.schedule_publication_resolve_with_standby_uat_v2(date,text,text)
  to authenticated;

comment on table public.published_standby_assignments_v2 is
  'Daily Tier 1/Tier 2 role readiness; not ordinary worked time until activation.';
