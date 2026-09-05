-- AUD review follow-up: fail closed at exact role/resource boundaries.
-- This migration does not broaden any application role or location scope.
begin;

do $guard$
begin
  if not exists (
    select 1
    from public.uat_environment_controls control
    where control.control_key='ISOLATED_UAT_DESTRUCTIVE_TOOLS'
      and control.enabled is true
      and control.config->>'environment'='ISOLATED_UAT'
      and control.config->>'projectRef'='nhthrtpkfpmufmrmdyjg'
  ) then
    raise exception 'AUD_RVW_WRONG_SUPABASE_PROJECT';
  end if;
end;
$guard$;

-- Preserve the legacy response only as an internal implementation.  The public
-- wrapper below removes company-wide data for every non-global application role.
alter function public.complete_workspace(date)
  rename to complete_workspace_before_aud_rvw_scoped_authorization_uat_v1;

revoke all on function
  public.complete_workspace_before_aud_rvw_scoped_authorization_uat_v1(date)
  from public,anon,authenticated,service_role;
grant execute on function
  public.complete_workspace_before_aud_rvw_scoped_authorization_uat_v1(date)
  to postgres;

create function public.complete_workspace(p_month date default current_date)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $function$
declare
  v_payload jsonb;
  v_employee jsonb;
  v_employee_id uuid;
  v_visible_employees jsonb:='[]'::jsonb;
  v_active_count integer:=0;
  v_archived_count integer:=0;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;

  v_payload:=public.complete_workspace_before_aud_rvw_scoped_authorization_uat_v1(
    p_month
  );
  if public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE') then
    return v_payload;
  end if;

  for v_employee in
    select item.value
    from jsonb_array_elements(coalesce(v_payload->'employees','[]'::jsonb)) item
  loop
    begin
      v_employee_id:=(v_employee->>'id')::uuid;
    exception when others then
      v_employee_id:=null;
    end;
    if v_employee_id is not null and (
      exists(
        select 1 from public.employees employee
        where employee.id=v_employee_id and employee.auth_user_id=auth.uid()
      )
      or public.matrix_v2_can_manage_resource_uat_v1(
        null,null,v_employee_id
      )
    ) then
      v_visible_employees:=v_visible_employees
        ||jsonb_build_array(v_employee-'hr'-'finance');
      if coalesce((v_employee->>'active')::boolean,false) then
        v_active_count:=v_active_count+1;
      else
        v_archived_count:=v_archived_count+1;
      end if;
    end if;
  end loop;

  return jsonb_build_object(
    'counts',jsonb_build_object(
      'employees',v_active_count,
      'archivedEmployees',v_archived_count,
      'roleManagers',0,
      'locations',0
    ),
    'employees',v_visible_employees,
    'activeMatrix',null,
    'draftMatrix',null,
    'roles','[]'::jsonb,
    'functions','[]'::jsonb,
    'locations','[]'::jsonb,
    'shifts','[]'::jsonb,
    'demand','[]'::jsonb,
    'sections','[]'::jsonb,
    'plan',null,
    'budget','{}'::jsonb,
    'preferences','[]'::jsonb,
    'integrationRuns','[]'::jsonb,
    'timeRecords','[]'::jsonb
  );
end;
$function$;

revoke all on function public.complete_workspace(date)
  from public,anon,authenticated,service_role;
grant execute on function public.complete_workspace(date)
  to authenticated,postgres,service_role;

-- An operational issue is manageable only when it belongs to the requested
-- published schedule and the caller has an exact, non-null grant for its role.
-- LOCATION_MANAGER deliberately remains denied: the solver has no accepted
-- location-scoped issue contract.
create or replace function solver_private.aud_rvw_can_manage_schedule_issue_uat_v1(
  p_schedule_id uuid,
  p_issue_id bigint
) returns boolean
language sql
stable
security definer
set search_path=''
as $function$
  select p_schedule_id is not null and p_issue_id is not null and (
    public.has_app_role('OWNER')
    or public.has_app_role('ADMIN')
    or public.has_app_role('VERIFIER')
    or exists(
      select 1
      from public.published_schedules_v2 schedule
      join public.published_schedule_variants_v2 link
        on link.schedule_id=schedule.id
      join public.plan_issues_v2 issue
        on issue.variant_id=link.variant_id and issue.id=p_issue_id
      join public.matrix_roles_v2 role
        on role.id=issue.role_id
          and role.matrix_version_id=schedule.matrix_version_id
      join public.matrix_scope_grants_v2 grant_row
        on grant_row.auth_user_id=auth.uid()
          and grant_row.active
          and grant_row.app_role='ROLE_MANAGER'
          and grant_row.role_logical_id is not null
          and grant_row.role_logical_id=role.logical_id
      where schedule.id=p_schedule_id
        and schedule.status='PUBLISHED'
    )
  )
$function$;

revoke all on function
  solver_private.aud_rvw_can_manage_schedule_issue_uat_v1(uuid,bigint)
  from public,anon,authenticated,service_role;
grant execute on function
  solver_private.aud_rvw_can_manage_schedule_issue_uat_v1(uuid,bigint)
  to postgres;

alter function public.optimizer_candidate_diagnostics_before_primary_rules_alpha16(uuid,bigint)
  rename to optimizer_diag_before_aud_rvw_exact_issue_uat_v1;

revoke all on function
  public.optimizer_diag_before_aud_rvw_exact_issue_uat_v1(uuid,bigint)
  from public,anon,authenticated,service_role;
grant execute on function
  public.optimizer_diag_before_aud_rvw_exact_issue_uat_v1(uuid,bigint)
  to postgres;

create function public.optimizer_candidate_diagnostics_before_primary_rules_alpha16(
  p_schedule_id uuid,
  p_issue_id bigint
) returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $function$
declare
  v_payload jsonb;
  v_candidates jsonb;
  v_summary jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not solver_private.aud_rvw_can_manage_schedule_issue_uat_v1(
    p_schedule_id,p_issue_id
  ) then
    raise exception 'FORBIDDEN';
  end if;

  v_payload:=public.optimizer_diag_before_aud_rvw_exact_issue_uat_v1(
    p_schedule_id,p_issue_id
  );
  if public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('VERIFIER') then
    return v_payload;
  end if;

  select coalesce(jsonb_agg(candidate.value order by candidate.ordinality),'[]'::jsonb)
  into v_candidates
  from jsonb_array_elements(coalesce(v_payload->'candidates','[]'::jsonb))
    with ordinality candidate(value,ordinality)
  where not exists(
    select 1
    from jsonb_array_elements_text(
      coalesce(candidate.value->'hardReasons','[]'::jsonb)
    ) reason(value)
    where reason.value='ROLE_REQUIRED'
  );

  select jsonb_build_object(
    'considered',count(*),
    'eligible',count(*) filter(where item.value->>'classification'='ELIGIBLE'),
    'warning',count(*) filter(where item.value->>'classification'='WARNING'),
    'blocked',count(*) filter(where item.value->>'classification'='BLOCKED')
  ) into v_summary
  from jsonb_array_elements(v_candidates) item(value);

  return jsonb_set(
    jsonb_set(v_payload,'{candidates}',v_candidates,true),
    '{summary}',v_summary,true
  );
end;
$function$;

revoke all on function
  public.optimizer_candidate_diagnostics_before_primary_rules_alpha16(uuid,bigint)
  from public,anon,authenticated,service_role;
grant execute on function
  public.optimizer_candidate_diagnostics_before_primary_rules_alpha16(uuid,bigint)
  to postgres,service_role;

-- Defense in depth at the mutation boundary.  The preserved implementation
-- calls the guarded diagnostics function as well, so an out-of-role employee
-- cannot become a candidate and no override, notification or audit row is made.
alter function public.optimizer_emergency_assign_alpha16(
  uuid,bigint,uuid,boolean,text,boolean
) rename to optimizer_emergency_assign_before_aud_rvw_exact_issue_uat_v1;

revoke all on function
  public.optimizer_emergency_assign_before_aud_rvw_exact_issue_uat_v1(
    uuid,bigint,uuid,boolean,text,boolean
  ) from public,anon,authenticated,service_role;
grant execute on function
  public.optimizer_emergency_assign_before_aud_rvw_exact_issue_uat_v1(
    uuid,bigint,uuid,boolean,text,boolean
  ) to postgres;

create function public.optimizer_emergency_assign_alpha16(
  p_schedule_id uuid,
  p_issue_id bigint,
  p_employee_id uuid,
  p_allow_soft boolean default false,
  p_reason text default null,
  p_notify boolean default false
) returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  perform pg_advisory_xact_lock(hashtextextended(
    'operational-v2:'||coalesce(p_schedule_id::text,'')||':'
      ||coalesce(p_issue_id::text,''),0
  ));
  if not solver_private.aud_rvw_can_manage_schedule_issue_uat_v1(
    p_schedule_id,p_issue_id
  ) then
    raise exception 'FORBIDDEN';
  end if;
  return public.optimizer_emergency_assign_before_aud_rvw_exact_issue_uat_v1(
    p_schedule_id,p_issue_id,p_employee_id,p_allow_soft,p_reason,p_notify
  );
end;
$function$;

revoke all on function public.optimizer_emergency_assign_alpha16(
  uuid,bigint,uuid,boolean,text,boolean
) from public,anon,authenticated,service_role;
grant execute on function public.optimizer_emergency_assign_alpha16(
  uuid,bigint,uuid,boolean,text,boolean
) to authenticated,postgres,service_role;

-- A ROLE request expands to every active role in its category.  A scoped
-- manager therefore needs a separate exact grant for every included role.
-- Existing runs are always checked against their immutable matrix version.
create function solver_private.aud_rvw_can_request_optimizer_matrix_scope_uat_v1(
  p_matrix_version_id uuid,
  p_scope_type text,
  p_scope_role_id uuid
) returns boolean
language sql
stable
security definer
set search_path=''
as $function$
  with matrix as (
    select version.id
    from public.matrix_versions version
    where version.id=p_matrix_version_id
      and version.status in ('ACTIVE','ARCHIVED')
      and version.schema_version>=2
      and coalesce(version.content_hash,'') ~ '^[0-9a-f]{64}$'
      and coalesce(version.workforce_hash,'') ~ '^[0-9a-f]{64}$'
  ), scope_role as (
    select role.id,role.matrix_version_id,role.category_id
    from matrix
    join public.matrix_roles_v2 role
      on role.matrix_version_id=matrix.id
      and role.id=p_scope_role_id
      and role.active
  ), required_roles as (
    select member.logical_id
    from scope_role scope
    join public.matrix_roles_v2 member
      on member.matrix_version_id=scope.matrix_version_id
      and member.active
      and (
        (scope.category_id is null and member.id=scope.id)
        or (scope.category_id is not null and member.category_id=scope.category_id)
      )
  )
  select auth.uid() is not null and case upper(coalesce(p_scope_type,''))
    when 'COMPANY' then
      p_scope_role_id is null
      and exists(select 1 from matrix)
      and (public.has_app_role('OWNER') or public.has_app_role('ADMIN'))
    when 'ROLE' then
      p_scope_role_id is not null
      and exists(select 1 from scope_role)
      and (
        public.has_app_role('OWNER') or public.has_app_role('ADMIN')
        or (
          exists(select 1 from required_roles)
          and not exists(
            select 1
            from required_roles required
            where required.logical_id is null
              or not exists(
                select 1
                from public.matrix_scope_grants_v2 grant_row
                where grant_row.auth_user_id=auth.uid()
                  and grant_row.active
                  and grant_row.app_role='ROLE_MANAGER'
                  and grant_row.role_logical_id is not null
                  and grant_row.role_logical_id=required.logical_id
              )
          )
        )
      )
    else false
  end
$function$;

revoke all on function
  solver_private.aud_rvw_can_request_optimizer_matrix_scope_uat_v1(uuid,text,uuid)
  from public,anon,authenticated,service_role;
grant execute on function
  solver_private.aud_rvw_can_request_optimizer_matrix_scope_uat_v1(uuid,text,uuid)
  to postgres;

create function solver_private.aud_rvw_can_request_optimizer_scope_uat_v1(
  p_month date,
  p_scope_type text,
  p_scope_role_id uuid
) returns boolean
language sql
stable
security definer
set search_path=''
as $function$
  select coalesce((
    select solver_private.aud_rvw_can_request_optimizer_matrix_scope_uat_v1(
      version.id,p_scope_type,p_scope_role_id
    )
    from public.matrix_versions version
    where version.status in ('ACTIVE','ARCHIVED')
      and version.schema_version>=2
      and solver_private.matrix_covers_planning_month_uat_v1(
        version.effective_from,date_trunc('month',p_month)::date
      )
      and coalesce(version.content_hash,'') ~ '^[0-9a-f]{64}$'
      and coalesce(version.workforce_hash,'') ~ '^[0-9a-f]{64}$'
    order by version.effective_from desc,version.version desc
    limit 1
  ),false)
$function$;

revoke all on function
  solver_private.aud_rvw_can_request_optimizer_scope_uat_v1(date,text,uuid)
  from public,anon,authenticated,service_role;
grant execute on function
  solver_private.aud_rvw_can_request_optimizer_scope_uat_v1(date,text,uuid)
  to postgres;

alter function public.optimizer_request_before_nfjob_uat_v1(
  date,uuid,text,uuid,text,text,text
) rename to optimizer_request_before_aud_rvw_category_scope_uat_v1;

revoke all on function
  public.optimizer_request_before_aud_rvw_category_scope_uat_v1(
    date,uuid,text,uuid,text,text,text
  ) from public,anon,authenticated,service_role;
grant execute on function
  public.optimizer_request_before_aud_rvw_category_scope_uat_v1(
    date,uuid,text,uuid,text,text,text
  ) to postgres;

create function public.optimizer_request_before_nfjob_uat_v1(
  p_month date,
  p_scenario_id uuid,
  p_scope_type text,
  p_scope_role_id uuid,
  p_name text,
  p_idempotency_key text,
  p_frontend_version text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
begin
  if not solver_private.aud_rvw_can_request_optimizer_scope_uat_v1(
    p_month,p_scope_type,p_scope_role_id
  ) then
    raise exception 'OPTIMIZER_SCOPE_FORBIDDEN';
  end if;
  return public.optimizer_request_before_aud_rvw_category_scope_uat_v1(
    p_month,p_scenario_id,p_scope_type,p_scope_role_id,p_name,
    p_idempotency_key,p_frontend_version
  );
end;
$function$;

revoke all on function public.optimizer_request_before_nfjob_uat_v1(
  date,uuid,text,uuid,text,text,text
) from public,anon,authenticated,service_role;
grant execute on function public.optimizer_request_before_nfjob_uat_v1(
  date,uuid,text,uuid,text,text,text
) to postgres,service_role;

-- The same category boundary must protect every public route that creates or
-- edits a leader variant.  The preserved implementations retain all existing
-- validation and side effects; the wrappers add a fail-closed scope check.
alter function public.optimizer_create_manual_leader_studio_uat_v1(
  date,uuid,text,uuid,text,text
) rename to optimizer_create_manual_leader_studio_before_aud_rvw_uat_v1;

revoke all on function
  public.optimizer_create_manual_leader_studio_before_aud_rvw_uat_v1(
    date,uuid,text,uuid,text,text
  ) from public,anon,authenticated,service_role;
grant execute on function
  public.optimizer_create_manual_leader_studio_before_aud_rvw_uat_v1(
    date,uuid,text,uuid,text,text
  ) to postgres;

create function public.optimizer_create_manual_leader_studio_uat_v1(
  p_month date,
  p_scenario_id uuid,
  p_scope_type text,
  p_scope_role_id uuid,
  p_name text,
  p_solver_version text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
begin
  if not solver_private.aud_rvw_can_request_optimizer_scope_uat_v1(
    p_month,p_scope_type,p_scope_role_id
  ) then
    raise exception 'OPTIMIZER_SCOPE_FORBIDDEN';
  end if;
  return public.optimizer_create_manual_leader_studio_before_aud_rvw_uat_v1(
    p_month,p_scenario_id,p_scope_type,p_scope_role_id,p_name,p_solver_version
  );
end;
$function$;

revoke all on function public.optimizer_create_manual_leader_studio_uat_v1(
  date,uuid,text,uuid,text,text
) from public,anon,authenticated,service_role;
grant execute on function public.optimizer_create_manual_leader_studio_uat_v1(
  date,uuid,text,uuid,text,text
) to authenticated,postgres,service_role;

alter function public.optimizer_create_leader_variant_uat_v1(
  uuid,uuid,text
) rename to optimizer_create_leader_variant_before_aud_rvw_uat_v1;

revoke all on function
  public.optimizer_create_leader_variant_before_aud_rvw_uat_v1(
    uuid,uuid,text
  ) from public,anon,authenticated,service_role;
grant execute on function
  public.optimizer_create_leader_variant_before_aud_rvw_uat_v1(
    uuid,uuid,text
  ) to postgres;

create function public.optimizer_create_leader_variant_uat_v1(
  p_run_id uuid,
  p_source_variant_id uuid,
  p_name text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_run public.optimization_runs_v2%rowtype;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into v_run
  from public.optimization_runs_v2 run
  where run.id=p_run_id;
  if v_run.id is null then
    return public.optimizer_create_leader_variant_before_aud_rvw_uat_v1(
      p_run_id,p_source_variant_id,p_name
    );
  end if;
  if not solver_private.aud_rvw_can_request_optimizer_matrix_scope_uat_v1(
    v_run.matrix_version_id,v_run.scope_type,v_run.scope_role_id
  ) then
    raise exception 'LEADER_VARIANT_FORBIDDEN';
  end if;
  return public.optimizer_create_leader_variant_before_aud_rvw_uat_v1(
    p_run_id,p_source_variant_id,p_name
  );
end;
$function$;

revoke all on function public.optimizer_create_leader_variant_uat_v1(
  uuid,uuid,text
) from public,anon,authenticated,service_role;
grant execute on function public.optimizer_create_leader_variant_uat_v1(
  uuid,uuid,text
) to authenticated,postgres,service_role;

alter function solver_private.can_access_run_v2(uuid)
  rename to can_access_run_before_aud_rvw_uat_v1;

revoke all on function
  solver_private.can_access_run_before_aud_rvw_uat_v1(uuid)
  from public,anon,authenticated,service_role;
grant execute on function
  solver_private.can_access_run_before_aud_rvw_uat_v1(uuid)
  to postgres;

create function solver_private.can_access_run_v2(
  p_run_id uuid
) returns boolean
language sql
stable
security definer
set search_path=''
as $function$
  select
    solver_private.can_access_run_before_aud_rvw_uat_v1(p_run_id)
    and exists(
      select 1
      from public.optimization_runs_v2 run
      where run.id=p_run_id
        and solver_private.aud_rvw_can_request_optimizer_matrix_scope_uat_v1(
          run.matrix_version_id,run.scope_type,run.scope_role_id
        )
    )
$function$;

revoke all on function solver_private.can_access_run_v2(uuid)
  from public,anon,authenticated,service_role;
grant execute on function solver_private.can_access_run_v2(uuid)
  to postgres,service_role;

alter function solver_private.can_edit_leader_variant_uat_v1(uuid)
  rename to can_edit_leader_variant_before_aud_rvw_uat_v1;

revoke all on function
  solver_private.can_edit_leader_variant_before_aud_rvw_uat_v1(uuid)
  from public,anon,authenticated,service_role;
grant execute on function
  solver_private.can_edit_leader_variant_before_aud_rvw_uat_v1(uuid)
  to postgres;

create function solver_private.can_edit_leader_variant_uat_v1(
  p_variant_id uuid
) returns boolean
language sql
stable
security definer
set search_path=''
as $function$
  select
    solver_private.can_edit_leader_variant_before_aud_rvw_uat_v1(p_variant_id)
    and exists(
      select 1
      from public.plan_variants_v2 variant
      join public.optimization_runs_v2 run on run.id=variant.run_id
      where variant.id=p_variant_id
        and solver_private.aud_rvw_can_request_optimizer_matrix_scope_uat_v1(
          run.matrix_version_id,run.scope_type,run.scope_role_id
        )
    )
$function$;

revoke all on function solver_private.can_edit_leader_variant_uat_v1(uuid)
  from public,anon,authenticated,service_role;
grant execute on function solver_private.can_edit_leader_variant_uat_v1(uuid)
  to postgres;

commit;
