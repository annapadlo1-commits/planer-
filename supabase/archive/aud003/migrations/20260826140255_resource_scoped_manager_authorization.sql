-- Phase 1: resource-aware manager authorization.
-- This migration intentionally does not introduce organization/tenant semantics.

create schema if not exists authorization_private;
revoke all on schema authorization_private from public, anon, authenticated;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'matrix_scope_grants_v2_role_manager_requires_role'
      and conrelid = 'public.matrix_scope_grants_v2'::regclass
  ) then
    alter table public.matrix_scope_grants_v2
      add constraint matrix_scope_grants_v2_role_manager_requires_role
      check (app_role <> 'ROLE_MANAGER' or role_logical_id is not null);
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'matrix_scope_grants_v2_location_manager_requires_location'
      and conrelid = 'public.matrix_scope_grants_v2'::regclass
  ) then
    alter table public.matrix_scope_grants_v2
      add constraint matrix_scope_grants_v2_location_manager_requires_location
      check (app_role <> 'LOCATION_MANAGER' or location_logical_id is not null);
  end if;
end;
$$;

create or replace function public.matrix_v2_scope_allows_resource_for_app_role_uat_v1(
  p_manager_role public.app_role,
  p_role_id uuid default null,
  p_location_id uuid default null,
  p_employee_id uuid default null
) returns boolean
language sql stable security definer set search_path=''
as $$
  with resource as (
    select
      (select role.logical_id from public.matrix_roles_v2 role where role.id=p_role_id) role_logical_id,
      (select location.logical_id from public.matrix_locations_v2 location where location.id=p_location_id) location_logical_id
  )
  select auth.uid() is not null
    and p_manager_role in ('ROLE_MANAGER','LOCATION_MANAGER')
    and public.has_app_role(p_manager_role)
    and exists(
      select 1
      from public.matrix_scope_grants_v2 grant_row
      cross join resource
      where grant_row.auth_user_id=auth.uid()
        and grant_row.active
        and grant_row.app_role=p_manager_role
        and (
          p_manager_role<>'ROLE_MANAGER'
          or (
            grant_row.role_logical_id is not null
            and (
              (p_role_id is not null and resource.role_logical_id=grant_row.role_logical_id)
              or (p_role_id is null and p_employee_id is not null and exists(
                select 1
                from public.matrix_employee_roles_v2 employee_role
                join public.matrix_roles_v2 role on role.id=employee_role.role_id
                join public.matrix_versions matrix on matrix.id=employee_role.matrix_version_id
                where employee_role.employee_id=p_employee_id
                  and employee_role.active and role.active and matrix.status='ACTIVE'
                  and role.logical_id=grant_row.role_logical_id
              ))
            )
          )
        )
        and (
          p_manager_role<>'LOCATION_MANAGER'
          or (
            grant_row.location_logical_id is not null
            and (
              (p_location_id is not null and resource.location_logical_id=grant_row.location_logical_id)
              or (p_location_id is null and p_employee_id is not null and exists(
                select 1
                from public.matrix_employee_locations_v2 employee_location
                join public.matrix_locations_v2 location on location.id=employee_location.location_id
                join public.matrix_versions matrix on matrix.id=employee_location.matrix_version_id
                where employee_location.employee_id=p_employee_id
                  and employee_location.active and location.active and matrix.status='ACTIVE'
                  and location.logical_id=grant_row.location_logical_id
              ))
            )
          )
        )
        and (
          grant_row.role_logical_id is null
          or p_manager_role='ROLE_MANAGER'
          or (p_role_id is not null and resource.role_logical_id=grant_row.role_logical_id)
          or (p_role_id is null and p_employee_id is not null and exists(
            select 1
            from public.matrix_employee_roles_v2 employee_role
            join public.matrix_roles_v2 role on role.id=employee_role.role_id
            join public.matrix_versions matrix on matrix.id=employee_role.matrix_version_id
            where employee_role.employee_id=p_employee_id
              and employee_role.active and role.active and matrix.status='ACTIVE'
              and role.logical_id=grant_row.role_logical_id
          ))
        )
        and (
          grant_row.location_logical_id is null
          or p_manager_role='LOCATION_MANAGER'
          or (p_location_id is not null and resource.location_logical_id=grant_row.location_logical_id)
          or (p_location_id is null and p_employee_id is not null and exists(
            select 1
            from public.matrix_employee_locations_v2 employee_location
            join public.matrix_locations_v2 location on location.id=employee_location.location_id
            join public.matrix_versions matrix on matrix.id=employee_location.matrix_version_id
            where employee_location.employee_id=p_employee_id
              and employee_location.active and location.active and matrix.status='ACTIVE'
              and location.logical_id=grant_row.location_logical_id
          ))
        )
        and (
          grant_row.duty_logical_id is null
          or (p_employee_id is not null and exists(
            select 1
            from public.matrix_employee_duties_v2 employee_duty
            join public.matrix_duties_v2 duty on duty.id=employee_duty.duty_id
            join public.matrix_versions matrix on matrix.id=employee_duty.matrix_version_id
            where employee_duty.employee_id=p_employee_id
              and employee_duty.active and duty.active and matrix.status='ACTIVE'
              and duty.logical_id=grant_row.duty_logical_id
          ))
        )
        and (
          p_employee_id is null
          or (p_manager_role='ROLE_MANAGER' and exists(
            select 1
            from public.matrix_employee_roles_v2 employee_role
            join public.matrix_roles_v2 role on role.id=employee_role.role_id
            join public.matrix_versions matrix on matrix.id=employee_role.matrix_version_id
            where employee_role.employee_id=p_employee_id
              and employee_role.active and role.active and matrix.status='ACTIVE'
              and role.logical_id=grant_row.role_logical_id
          ))
          or (p_manager_role='LOCATION_MANAGER' and exists(
            select 1
            from public.matrix_employee_locations_v2 employee_location
            join public.matrix_locations_v2 location on location.id=employee_location.location_id
            join public.matrix_versions matrix on matrix.id=employee_location.matrix_version_id
            where employee_location.employee_id=p_employee_id
              and employee_location.active and location.active and matrix.status='ACTIVE'
              and location.logical_id=grant_row.location_logical_id
          ))
        )
    );
$$;

create or replace function public.matrix_v2_can_manage_resource_uat_v1(
  p_role_id uuid default null,
  p_location_id uuid default null,
  p_employee_id uuid default null
) returns boolean
language sql stable security definer set search_path=''
as $$
  select auth.uid() is not null and (
    public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.matrix_v2_scope_allows_resource_for_app_role_uat_v1(
      'ROLE_MANAGER',p_role_id,p_location_id,p_employee_id
    )
    or public.matrix_v2_scope_allows_resource_for_app_role_uat_v1(
      'LOCATION_MANAGER',p_role_id,p_location_id,p_employee_id
    )
  );
$$;

create or replace function public.matrix_v2_can_manage_employee(p_employee_id uuid)
returns boolean
language sql stable security definer set search_path=''
as $$
  select auth.uid() is not null and (
    public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE')
    or exists(
      select 1 from public.employees employee
      where employee.id=p_employee_id and employee.auth_user_id=auth.uid()
    )
    or public.matrix_v2_scope_allows_resource_for_app_role_uat_v1(
      'ROLE_MANAGER',null,null,p_employee_id
    )
    or public.matrix_v2_scope_allows_resource_for_app_role_uat_v1(
      'LOCATION_MANAGER',null,null,p_employee_id
    )
  );
$$;

create or replace function public.matrix_v2_has_any_manager_scope_uat_v1()
returns boolean
language sql stable security definer set search_path=''
as $$
  select auth.uid() is not null and (
    public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or exists(
      select 1 from public.matrix_scope_grants_v2 grant_row
      where grant_row.auth_user_id=auth.uid() and grant_row.active
        and (
          (grant_row.app_role='ROLE_MANAGER' and grant_row.role_logical_id is not null)
          or (grant_row.app_role='LOCATION_MANAGER' and grant_row.location_logical_id is not null)
        )
    )
  );
$$;

create or replace function authorization_private.enter_resource_scope_uat_v1()
returns void
language plpgsql volatile security definer set search_path=''
as $$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  perform set_config('szafunek.resource_scope_actor',auth.uid()::text,true);
end;
$$;

revoke all on function authorization_private.enter_resource_scope_uat_v1()
  from public,anon,authenticated,service_role;

create or replace function public.can_manage_plans()
returns boolean
language sql stable security definer set search_path=''
as $$
  select auth.uid() is not null and (
    public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or current_setting('szafunek.resource_scope_actor',true)=auth.uid()::text
  );
$$;

create or replace function solver_private.recovery_can_manage_scope_uat_v1(
  p_role_id uuid,p_location_id uuid
) returns boolean
language sql stable security definer set search_path=''
as $$
  select public.matrix_v2_can_manage_resource_uat_v1(p_role_id,p_location_id,null)
$$;

create or replace function authorization_private.calendar_payload_allowed_uat_v1(
  p_location_id uuid,p_demands jsonb,p_hot_limits jsonb
) returns boolean
language sql stable security definer set search_path=''
as $$
  with role_ids as (
    select nullif(item->>'roleId','')::uuid role_id
    from jsonb_array_elements(coalesce(p_demands,'[]'::jsonb)||coalesce(p_hot_limits,'[]'::jsonb)) item
  )
  select public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.matrix_v2_scope_allows_resource_for_app_role_uat_v1(
      'LOCATION_MANAGER',null,p_location_id,null
    )
    or (
      exists(select 1 from role_ids where role_id is not null)
      and not exists(
        select 1 from role_ids
        where role_id is null or not public.matrix_v2_scope_allows_resource_for_app_role_uat_v1(
          'ROLE_MANAGER',role_id,p_location_id,null
        )
      )
    );
$$;

create or replace function authorization_private.calendar_event_allowed_uat_v1(p_event_id uuid)
returns boolean
language sql stable security definer set search_path=''
as $$
  select exists(
    select 1
    from public.workforce_calendar_events_v2 event
    where event.id=p_event_id
      and authorization_private.calendar_payload_allowed_uat_v1(
        event.location_id,
        coalesce((select jsonb_agg(jsonb_build_object('roleId',demand.role_id))
          from public.workforce_event_demand_v2 demand where demand.event_id=event.id),'[]'::jsonb),
        coalesce((select jsonb_agg(jsonb_build_object('roleId',hot.role_id))
          from public.workforce_hot_day_limits_v2 hot where hot.event_id=event.id),'[]'::jsonb)
      )
  );
$$;

revoke all on function authorization_private.calendar_payload_allowed_uat_v1(uuid,jsonb,jsonb),
  authorization_private.calendar_event_allowed_uat_v1(uuid)
  from public,anon,authenticated,service_role;

-- Preserve the current implementations behind guarded, resource-aware RPC boundaries.
alter function public.availability_exception_review_uat_v2(uuid,text,text)
  rename to availability_exception_review_before_phase1_uat_v1;
create function public.availability_exception_review_uat_v2(
  p_review_id uuid,p_decision text,p_reason text
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_review public.availability_exception_reviews_v2%rowtype;
begin
  select * into v_review from public.availability_exception_reviews_v2 where id=p_review_id;
  if v_review.id is null then raise exception 'REVIEW_NOT_FOUND'; end if;
  if not public.matrix_v2_can_manage_resource_uat_v1(v_review.role_id,null,v_review.employee_id)
    then raise exception 'RESOURCE_SCOPE_FORBIDDEN'; end if;
  perform authorization_private.enter_resource_scope_uat_v1();
  return public.availability_exception_review_before_phase1_uat_v1(p_review_id,p_decision,p_reason);
end;
$$;

alter function public.employee_weekly_work_patterns_replace_uat_v1(uuid,date,date,jsonb,text)
  rename to employee_weekly_work_patterns_replace_before_phase1_uat_v1;
create function public.employee_weekly_work_patterns_replace_uat_v1(
  p_employee_id uuid,p_valid_from date,p_valid_to date,p_patterns jsonb,p_reason text
) returns jsonb language plpgsql security definer set search_path=''
as $$
begin
  if not public.matrix_v2_can_manage_resource_uat_v1(null,null,p_employee_id)
    then raise exception 'RESOURCE_SCOPE_FORBIDDEN'; end if;
  if exists(
    select 1
    from jsonb_array_elements(coalesce(p_patterns,'[]'::jsonb)) pattern
    where (nullif(pattern->>'roleId','') is not null or nullif(pattern->>'locationId','') is not null)
      and not public.matrix_v2_can_manage_resource_uat_v1(
        nullif(pattern->>'roleId','')::uuid,
        nullif(pattern->>'locationId','')::uuid,
        p_employee_id
      )
  ) then raise exception 'WORK_PATTERN_RESOURCE_SCOPE_FORBIDDEN'; end if;
  perform authorization_private.enter_resource_scope_uat_v1();
  return public.employee_weekly_work_patterns_replace_before_phase1_uat_v1(
    p_employee_id,p_valid_from,p_valid_to,p_patterns,p_reason
  );
end;
$$;

alter function public.optimizer_publish_role_composite_uat_v3(
  date,uuid,uuid[],text,text,text
) rename to optimizer_publish_role_composite_before_phase1_uat_v1;
create function public.optimizer_publish_role_composite_uat_v3(
  p_month date,p_scenario_id uuid,p_variant_ids uuid[],p_name text,
  p_idempotency_key text,p_warning_reason text default null
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_month date:=date_trunc('month',p_month)::date;
begin
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    if p_variant_ids is null or cardinality(p_variant_ids)=0 or exists(
      select 1
      from unnest(p_variant_ids) input(variant_id)
      left join public.published_role_schedules_v2 schedule
        on schedule.variant_id=input.variant_id
        and schedule.month=v_month
        and schedule.scenario_id=p_scenario_id
        and schedule.status='PUBLISHED'
      where schedule.id is null
        or schedule.role_id is null
        or not public.matrix_v2_scope_allows_resource_for_app_role_uat_v1(
          'ROLE_MANAGER',schedule.role_id,null,null
        )
    ) then raise exception 'RESOURCE_SCOPE_FORBIDDEN'; end if;
  end if;
  perform authorization_private.enter_resource_scope_uat_v1();
  return public.optimizer_publish_role_composite_before_phase1_uat_v1(
    p_month,p_scenario_id,p_variant_ids,p_name,p_idempotency_key,p_warning_reason
  );
end;
$$;

alter function public.shift_swap_leader_decide_uat_v2(uuid,text,text)
  rename to shift_swap_leader_decide_before_phase1_uat_v1;
create function public.shift_swap_leader_decide_uat_v2(
  p_request_id uuid,p_decision text,p_reason text
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_role uuid;v_location uuid;
begin
  select request.role_id,shift.location_id into v_role,v_location
  from public.shift_swap_requests_v2 request
  join public.plan_assignments_v2 assignment on assignment.id=request.original_assignment_id
  join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
  where request.id=p_request_id;
  if v_role is null or v_location is null then raise exception 'SWAP_REQUEST_NOT_FOUND'; end if;
  if not public.matrix_v2_can_manage_resource_uat_v1(v_role,v_location,null)
    then raise exception 'RESOURCE_SCOPE_FORBIDDEN'; end if;
  perform authorization_private.enter_resource_scope_uat_v1();
  return public.shift_swap_leader_decide_before_phase1_uat_v1(p_request_id,p_decision,p_reason);
end;
$$;

alter function public.standby_activate_uat_v2(uuid,uuid,text)
  rename to standby_activate_before_phase1_uat_v1;
create function public.standby_activate_uat_v2(
  p_standby_id uuid,p_original_assignment_id uuid,p_reason text
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_role uuid;v_location uuid;
begin
  select standby.role_id,shift.location_id into v_role,v_location
  from public.published_standby_assignments_v2 standby
  join public.plan_assignments_v2 assignment on assignment.id=p_original_assignment_id
  join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
  where standby.id=p_standby_id;
  if v_role is null or v_location is null then raise exception 'STANDBY_RESOURCE_NOT_FOUND'; end if;
  if not public.matrix_v2_can_manage_resource_uat_v1(v_role,v_location,null)
    then raise exception 'RESOURCE_SCOPE_FORBIDDEN'; end if;
  perform authorization_private.enter_resource_scope_uat_v1();
  return public.standby_activate_before_phase1_uat_v1(p_standby_id,p_original_assignment_id,p_reason);
end;
$$;

alter function public.recovery_center_workspace_uat_v1(date)
  rename to recovery_center_workspace_before_phase1_uat_v1;
create function public.recovery_center_workspace_uat_v1(p_month date)
returns jsonb language plpgsql volatile security definer set search_path=''
as $$
begin
  if not public.matrix_v2_has_any_manager_scope_uat_v1()
    then raise exception 'RESOURCE_SCOPE_FORBIDDEN'; end if;
  perform authorization_private.enter_resource_scope_uat_v1();
  return public.recovery_center_workspace_before_phase1_uat_v1(p_month);
end;
$$;

alter function public.recovery_incident_detail_uat_v1(uuid)
  rename to recovery_incident_detail_before_phase1_uat_v1;
create function public.recovery_incident_detail_uat_v1(p_incident_id uuid)
returns jsonb language plpgsql volatile security definer set search_path=''
as $$
declare v_incident public.recovery_incidents_v2%rowtype;
begin
  select * into v_incident from public.recovery_incidents_v2 where id=p_incident_id;
  if v_incident.id is null then raise exception 'INCIDENT_NOT_FOUND'; end if;
  if not public.matrix_v2_can_manage_resource_uat_v1(
    v_incident.role_id,v_incident.location_id,v_incident.employee_id
  ) then raise exception 'RESOURCE_SCOPE_FORBIDDEN'; end if;
  perform authorization_private.enter_resource_scope_uat_v1();
  return public.recovery_incident_detail_before_phase1_uat_v1(p_incident_id);
end;
$$;

alter function public.recovery_incident_prepare_uat_v1(uuid,integer,text)
  rename to recovery_incident_prepare_before_phase1_uat_v1;
create function public.recovery_incident_prepare_uat_v1(
  p_incident_id uuid,p_expected_revision integer,p_mode text
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_incident public.recovery_incidents_v2%rowtype;
begin
  select * into v_incident from public.recovery_incidents_v2 where id=p_incident_id;
  if v_incident.id is null then raise exception 'INCIDENT_NOT_FOUND'; end if;
  if not public.matrix_v2_can_manage_resource_uat_v1(
    v_incident.role_id,v_incident.location_id,v_incident.employee_id
  ) then raise exception 'RESOURCE_SCOPE_FORBIDDEN'; end if;
  perform authorization_private.enter_resource_scope_uat_v1();
  return public.recovery_incident_prepare_before_phase1_uat_v1(
    p_incident_id,p_expected_revision,p_mode
  );
end;
$$;

alter function public.recovery_incident_save_uat_v1(
  date,integer,uuid,uuid,uuid,uuid,text,date,date,text,text,text
) rename to recovery_incident_save_before_phase1_uat_v1;
create function public.recovery_incident_save_uat_v1(
  p_month date,p_expected_revision integer,p_incident_id uuid,p_employee_id uuid,
  p_role_id uuid,p_location_id uuid,p_incident_type text,p_starts_on date,p_ends_on date,
  p_title text,p_notes text,p_mode text
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_incident public.recovery_incidents_v2%rowtype;
begin
  if p_incident_id is not null then
    select * into v_incident from public.recovery_incidents_v2 where id=p_incident_id;
    if v_incident.id is null then raise exception 'INCIDENT_NOT_FOUND'; end if;
    if not public.matrix_v2_can_manage_resource_uat_v1(
      v_incident.role_id,v_incident.location_id,v_incident.employee_id
    ) then raise exception 'RESOURCE_SCOPE_FORBIDDEN'; end if;
  end if;
  if not public.matrix_v2_can_manage_resource_uat_v1(p_role_id,p_location_id,p_employee_id)
    then raise exception 'RESOURCE_SCOPE_FORBIDDEN'; end if;
  perform authorization_private.enter_resource_scope_uat_v1();
  return public.recovery_incident_save_before_phase1_uat_v1(
    p_month,p_expected_revision,p_incident_id,p_employee_id,p_role_id,p_location_id,
    p_incident_type,p_starts_on,p_ends_on,p_title,p_notes,p_mode
  );
end;
$$;

alter function public.recovery_incident_rate_propose_uat_v1(
  uuid,uuid,bigint,text,date,date,text
) rename to recovery_incident_rate_propose_before_phase1_uat_v1;
create function public.recovery_incident_rate_propose_uat_v1(
  p_incident_id uuid,p_employee_id uuid,p_rate_minor bigint,p_currency text,
  p_valid_from date,p_valid_to date,p_reason text
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_incident public.recovery_incidents_v2%rowtype;
begin
  select * into v_incident from public.recovery_incidents_v2 where id=p_incident_id;
  if v_incident.id is null then raise exception 'INCIDENT_NOT_FOUND'; end if;
  if not public.matrix_v2_can_manage_resource_uat_v1(
    v_incident.role_id,v_incident.location_id,v_incident.employee_id
  ) or not public.matrix_v2_can_manage_resource_uat_v1(null,null,p_employee_id)
    then raise exception 'RESOURCE_SCOPE_FORBIDDEN'; end if;
  return public.recovery_incident_rate_propose_before_phase1_uat_v1(
    p_incident_id,p_employee_id,p_rate_minor,p_currency,p_valid_from,p_valid_to,p_reason
  );
end;
$$;

alter function public.workforce_calendar_event_save_uat_v2(
  uuid,date,date,text,text,text,uuid,jsonb,jsonb
) rename to workforce_calendar_event_save_before_phase1_uat_v1;
create function public.workforce_calendar_event_save_uat_v2(
  p_event_id uuid,p_month date,p_event_date date,p_event_kind text,p_title text,
  p_description text,p_location_id uuid,p_demands jsonb default '[]'::jsonb,
  p_hot_limits jsonb default '[]'::jsonb
) returns jsonb language plpgsql security definer set search_path=''
as $$
begin
  if p_event_id is not null
    and not authorization_private.calendar_event_allowed_uat_v1(p_event_id)
    then raise exception 'RESOURCE_SCOPE_FORBIDDEN'; end if;
  if not authorization_private.calendar_payload_allowed_uat_v1(
    p_location_id,p_demands,p_hot_limits
  ) then raise exception 'RESOURCE_SCOPE_FORBIDDEN'; end if;
  perform authorization_private.enter_resource_scope_uat_v1();
  return public.workforce_calendar_event_save_before_phase1_uat_v1(
    p_event_id,p_month,p_event_date,p_event_kind,p_title,p_description,
    p_location_id,p_demands,p_hot_limits
  );
end;
$$;

alter function public.workforce_calendar_event_range_save_uat_v2(
  date,date,date,text,text,text,uuid,jsonb,jsonb
) rename to workforce_calendar_event_range_save_before_phase1_uat_v1;
create function public.workforce_calendar_event_range_save_uat_v2(
  p_month date,p_start_date date,p_end_date date,p_event_kind text,p_title text,
  p_description text,p_location_id uuid,p_demands jsonb default '[]'::jsonb,
  p_hot_limits jsonb default '[]'::jsonb
) returns jsonb language plpgsql security definer set search_path=''
as $$
begin
  if not authorization_private.calendar_payload_allowed_uat_v1(
    p_location_id,p_demands,p_hot_limits
  ) then raise exception 'RESOURCE_SCOPE_FORBIDDEN'; end if;
  perform authorization_private.enter_resource_scope_uat_v1();
  return public.workforce_calendar_event_range_save_before_phase1_uat_v1(
    p_month,p_start_date,p_end_date,p_event_kind,p_title,p_description,
    p_location_id,p_demands,p_hot_limits
  );
end;
$$;

-- This Alpha-15 compatibility mutation was retired but accidentally retained an authenticated grant.
revoke all on function public.role_plan_refresh_conflicts(uuid) from public,anon,authenticated;

revoke all on function
  public.matrix_v2_scope_allows_resource_for_app_role_uat_v1(public.app_role,uuid,uuid,uuid),
  public.matrix_v2_can_manage_resource_uat_v1(uuid,uuid,uuid),
  public.matrix_v2_can_manage_employee(uuid),
  public.matrix_v2_has_any_manager_scope_uat_v1()
  from public,anon,authenticated;
grant execute on function
  public.matrix_v2_scope_allows_resource_for_app_role_uat_v1(public.app_role,uuid,uuid,uuid),
  public.matrix_v2_can_manage_resource_uat_v1(uuid,uuid,uuid),
  public.matrix_v2_can_manage_employee(uuid),
  public.matrix_v2_has_any_manager_scope_uat_v1()
  to authenticated,service_role;

revoke all on function
  public.availability_exception_review_before_phase1_uat_v1(uuid,text,text),
  public.employee_weekly_work_patterns_replace_before_phase1_uat_v1(uuid,date,date,jsonb,text),
  public.optimizer_publish_role_composite_before_phase1_uat_v1(date,uuid,uuid[],text,text,text),
  public.shift_swap_leader_decide_before_phase1_uat_v1(uuid,text,text),
  public.standby_activate_before_phase1_uat_v1(uuid,uuid,text),
  public.recovery_center_workspace_before_phase1_uat_v1(date),
  public.recovery_incident_detail_before_phase1_uat_v1(uuid),
  public.recovery_incident_prepare_before_phase1_uat_v1(uuid,integer,text),
  public.recovery_incident_save_before_phase1_uat_v1(date,integer,uuid,uuid,uuid,uuid,text,date,date,text,text,text),
  public.recovery_incident_rate_propose_before_phase1_uat_v1(uuid,uuid,bigint,text,date,date,text),
  public.workforce_calendar_event_save_before_phase1_uat_v1(uuid,date,date,text,text,text,uuid,jsonb,jsonb),
  public.workforce_calendar_event_range_save_before_phase1_uat_v1(date,date,date,text,text,text,uuid,jsonb,jsonb)
  from public,anon,authenticated;

revoke all on function
  public.availability_exception_review_uat_v2(uuid,text,text),
  public.employee_weekly_work_patterns_replace_uat_v1(uuid,date,date,jsonb,text),
  public.optimizer_publish_role_composite_uat_v3(date,uuid,uuid[],text,text,text),
  public.shift_swap_leader_decide_uat_v2(uuid,text,text),
  public.standby_activate_uat_v2(uuid,uuid,text),
  public.recovery_center_workspace_uat_v1(date),
  public.recovery_incident_detail_uat_v1(uuid),
  public.recovery_incident_prepare_uat_v1(uuid,integer,text),
  public.recovery_incident_save_uat_v1(date,integer,uuid,uuid,uuid,uuid,text,date,date,text,text,text),
  public.recovery_incident_rate_propose_uat_v1(uuid,uuid,bigint,text,date,date,text),
  public.workforce_calendar_event_save_uat_v2(uuid,date,date,text,text,text,uuid,jsonb,jsonb),
  public.workforce_calendar_event_range_save_uat_v2(date,date,date,text,text,text,uuid,jsonb,jsonb)
  from public,anon,authenticated;
grant execute on function
  public.availability_exception_review_uat_v2(uuid,text,text),
  public.employee_weekly_work_patterns_replace_uat_v1(uuid,date,date,jsonb,text),
  public.optimizer_publish_role_composite_uat_v3(date,uuid,uuid[],text,text,text),
  public.shift_swap_leader_decide_uat_v2(uuid,text,text),
  public.standby_activate_uat_v2(uuid,uuid,text),
  public.recovery_center_workspace_uat_v1(date),
  public.recovery_incident_detail_uat_v1(uuid),
  public.recovery_incident_prepare_uat_v1(uuid,integer,text),
  public.recovery_incident_save_uat_v1(date,integer,uuid,uuid,uuid,uuid,text,date,date,text,text,text),
  public.recovery_incident_rate_propose_uat_v1(uuid,uuid,bigint,text,date,date,text),
  public.workforce_calendar_event_save_uat_v2(uuid,date,date,text,text,text,uuid,jsonb,jsonb),
  public.workforce_calendar_event_range_save_uat_v2(date,date,date,text,text,text,uuid,jsonb,jsonb)
  to authenticated,service_role;

comment on function public.can_manage_plans() is
  'Global plan management is OWNER/ADMIN only. Scoped manager calls require a canonical resource guard.';
comment on function public.matrix_v2_can_manage_resource_uat_v1(uuid,uuid,uuid) is
  'Fail-closed canonical role/location/employee resource authorization for manager scope grants.';

notify pgrst,'reload schema';
