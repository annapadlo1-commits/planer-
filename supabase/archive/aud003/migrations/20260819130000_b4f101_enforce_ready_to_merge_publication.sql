create or replace function solver_private.guard_leader_variant_publication_uat_v1()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.variant_kind='LEADER_COPY'
    and new.status='PUBLISHED'
    and old.status is distinct from 'PUBLISHED'
    and old.leader_workflow_status is distinct from 'READY_TO_MERGE' then
    raise exception 'LEADER_VARIANT_NOT_READY_TO_PUBLISH';
  end if;
  return new;
end;
$$;

drop trigger if exists guard_leader_variant_publication_uat_v1
  on public.plan_variants_v2;
create trigger guard_leader_variant_publication_uat_v1
before update of status on public.plan_variants_v2
for each row
execute function solver_private.guard_leader_variant_publication_uat_v1();

revoke all on function solver_private.guard_leader_variant_publication_uat_v1()
  from public,anon,authenticated;

comment on function solver_private.guard_leader_variant_publication_uat_v1()
is 'B4F-101: blocks every publication route for a leader copy until the audited workflow reached READY_TO_MERGE.';

create or replace function solver_private.changed_variant_employees_uat_v1(
  p_old_variant_ids uuid[],
  p_new_variant_ids uuid[]
) returns table(
  employee_id uuid,
  before_assignment_count integer,
  after_assignment_count integer,
  before_schedule jsonb,
  after_schedule jsonb
)
language sql
stable
security definer
set search_path = ''
as $$
  with old_items as (
    select assignment.employee_id,shift.shift_date,shift.starts_at,shift.ends_at,
      location.logical_id location_logical_id,role.logical_id role_logical_id,
      jsonb_build_object(
        'date',shift.shift_date,
        'startsAt',shift.starts_at,
        'endsAt',shift.ends_at,
        'locationLogicalId',location.logical_id,
        'roleLogicalId',role.logical_id,
        'duties',coalesce((
          select jsonb_agg(to_jsonb(duty.logical_id) order by duty.logical_id::text)
          from public.plan_assignment_duties_v2 assignment_duty
          join public.matrix_duties_v2 duty on duty.id=assignment_duty.duty_id
          where assignment_duty.assignment_id=assignment.id
        ),'[]'::jsonb)
      ) item
    from public.plan_assignments_v2 assignment
    join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
    join public.matrix_locations_v2 location on location.id=shift.location_id
    join public.matrix_roles_v2 role on role.id=assignment.role_id
    where coalesce(cardinality(p_old_variant_ids),0)>0
      and assignment.variant_id=any(p_old_variant_ids)
  ), old_schedules as (
    select item.employee_id,count(*)::integer assignment_count,
      jsonb_agg(item.item order by item.shift_date,item.starts_at,item.ends_at,
        item.location_logical_id::text,item.role_logical_id::text,item.item::text) schedule
    from old_items item group by item.employee_id
  ), new_items as (
    select assignment.employee_id,shift.shift_date,shift.starts_at,shift.ends_at,
      location.logical_id location_logical_id,role.logical_id role_logical_id,
      jsonb_build_object(
        'date',shift.shift_date,
        'startsAt',shift.starts_at,
        'endsAt',shift.ends_at,
        'locationLogicalId',location.logical_id,
        'roleLogicalId',role.logical_id,
        'duties',coalesce((
          select jsonb_agg(to_jsonb(duty.logical_id) order by duty.logical_id::text)
          from public.plan_assignment_duties_v2 assignment_duty
          join public.matrix_duties_v2 duty on duty.id=assignment_duty.duty_id
          where assignment_duty.assignment_id=assignment.id
        ),'[]'::jsonb)
      ) item
    from public.plan_assignments_v2 assignment
    join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
    join public.matrix_locations_v2 location on location.id=shift.location_id
    join public.matrix_roles_v2 role on role.id=assignment.role_id
    where coalesce(cardinality(p_new_variant_ids),0)>0
      and assignment.variant_id=any(p_new_variant_ids)
  ), new_schedules as (
    select item.employee_id,count(*)::integer assignment_count,
      jsonb_agg(item.item order by item.shift_date,item.starts_at,item.ends_at,
        item.location_logical_id::text,item.role_logical_id::text,item.item::text) schedule
    from new_items item group by item.employee_id
  )
  select coalesce(old_row.employee_id,new_row.employee_id),
    coalesce(old_row.assignment_count,0),coalesce(new_row.assignment_count,0),
    coalesce(old_row.schedule,'[]'::jsonb),coalesce(new_row.schedule,'[]'::jsonb)
  from old_schedules old_row
  full join new_schedules new_row on new_row.employee_id=old_row.employee_id
  where coalesce(old_row.schedule,'[]'::jsonb)
    is distinct from coalesce(new_row.schedule,'[]'::jsonb);
$$;

revoke all on function solver_private.changed_variant_employees_uat_v1(uuid[],uuid[])
  from public,anon,authenticated;
grant execute on function solver_private.changed_variant_employees_uat_v1(uuid[],uuid[])
  to service_role;

create or replace function public.optimizer_publication_change_preview_uat_v1(
  p_variant_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor uuid:=auth.uid();
  v_run public.optimization_runs_v2%rowtype;
  v_old_variant_ids uuid[];
  v_baseline_type text;
  v_people jsonb:='[]'::jsonb;
  v_changed_count integer:=0;
  v_notification_count integer:=0;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select run.* into v_run
  from public.plan_variants_v2 variant
  join public.optimization_runs_v2 run on run.id=variant.run_id
  where variant.id=p_variant_id;
  if v_run.id is null or not solver_private.can_access_run_v2(v_run.id) then
    raise exception 'VARIANT_NOT_FOUND';
  end if;

  if v_run.scope_type='ROLE' and v_run.scope_role_id is not null then
    select array_agg(publication.variant_id order by publication.published_at,publication.id)
    into v_old_variant_ids
    from public.published_role_schedules_v2 publication
    where publication.month=v_run.month
      and publication.role_id=v_run.scope_role_id
      and publication.status='PUBLISHED';
    v_baseline_type:='ROLE';
  else
    select array_agg(publication.variant_id order by publication.role_id,publication.published_at)
    into v_old_variant_ids
    from public.published_role_schedules_v2 publication
    where publication.month=v_run.month and publication.status='PUBLISHED';
    if coalesce(cardinality(v_old_variant_ids),0)>0 then
      v_baseline_type:='ROLE_PUBLICATIONS';
    else
      select array_agg(link.variant_id order by link.ordinal)
      into v_old_variant_ids
      from public.published_schedules_v2 schedule
      join public.published_schedule_variants_v2 link on link.schedule_id=schedule.id
      where schedule.id=(
        select current_schedule.id
        from public.published_schedules_v2 current_schedule
        where current_schedule.month=v_run.month and current_schedule.status='PUBLISHED'
        order by current_schedule.published_at desc,current_schedule.id desc limit 1
      );
      v_baseline_type:='COMPANY';
    end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'employeeId',employee.id,
      'employeeNo',employee.employee_no,
      'name',trim(employee.first_name||' '||employee.last_name),
      'changeType',case when change.before_assignment_count=0 then 'ADDED'
        when change.after_assignment_count=0 then 'REMOVED' else 'CHANGED' end,
      'beforeAssignmentCount',change.before_assignment_count,
      'afterAssignmentCount',change.after_assignment_count,
      'willNotify',employee.auth_user_id is not null
    ) order by employee.last_name,employee.first_name,employee.employee_no),'[]'::jsonb),
    count(*)::integer,
    count(*) filter(where employee.auth_user_id is not null)::integer
  into v_people,v_changed_count,v_notification_count
  from solver_private.changed_variant_employees_uat_v1(
    coalesce(v_old_variant_ids,'{}'::uuid[]),array[p_variant_id]
  ) change
  join public.employees employee on employee.id=change.employee_id;

  return jsonb_build_object(
    'variantId',p_variant_id,
    'baselineType',v_baseline_type,
    'baselineFound',coalesce(cardinality(v_old_variant_ids),0)>0,
    'changedCount',v_changed_count,
    'notificationCount',v_notification_count,
    'people',v_people
  );
end;
$$;

revoke all on function public.optimizer_publication_change_preview_uat_v1(uuid)
  from public,anon,authenticated;
grant execute on function public.optimizer_publication_change_preview_uat_v1(uuid)
  to authenticated;

create or replace function public.optimizer_publish_role_variant_uat_v2(
  p_run_id uuid,
  p_variant_id uuid,
  p_name text,
  p_idempotency_key text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid:=auth.uid();
  v_run public.optimization_runs_v2%rowtype;
  v_variant public.plan_variants_v2%rowtype;
  v_role_logical_id uuid;
  v_existing public.published_role_schedules_v2%rowtype;
  v_previous_variant_id uuid;
  v_id uuid:=gen_random_uuid();
  v_validation jsonb;
  v_month date;
  v_changed integer:=0;
  v_notified integer:=0;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if length(coalesce(p_idempotency_key,'')) not between 8 and 200 then
    raise exception 'INVALID_IDEMPOTENCY_KEY';
  end if;
  if length(trim(coalesce(p_name,''))) not between 1 and 200 then
    raise exception 'INVALID_PLAN_NAME';
  end if;
  select run.month into v_month
  from public.optimization_runs_v2 run where run.id=p_run_id;
  if v_month is null then raise exception 'VARIANT_NOT_FOUND'; end if;

  perform solver_private.lock_planning_revision_v2();
  perform pg_advisory_xact_lock(hashtextextended(
    'publish-v2-month:'||v_month::text,0
  ));
  perform pg_advisory_xact_lock(hashtextextended(
    'select-v2:'||p_run_id::text,0
  ));

  select * into v_run from public.optimization_runs_v2 run
  where run.id=p_run_id for update;
  select * into v_variant from public.plan_variants_v2 variant
  where variant.id=p_variant_id and variant.run_id=p_run_id for update;
  if v_run.id is null or v_variant.id is null then raise exception 'VARIANT_NOT_FOUND'; end if;
  if v_run.month<>v_month then raise exception 'RUN_MONTH_CHANGED'; end if;
  if v_run.scope_type<>'ROLE' or v_run.scope_role_id is null then
    raise exception 'ROLE_VARIANT_REQUIRED';
  end if;
  if v_run.request_engine<>'ORTOOLS_V2' then raise exception 'SHADOW_RUN_NOT_PUBLISHABLE'; end if;
  if v_run.status<>'READY' or not v_variant.selected
    or v_variant.hard_violations<>0
    or v_variant.status not in ('SELECTED','PUBLISHED') then
    raise exception 'SELECTED_VALID_ROLE_VARIANT_REQUIRED';
  end if;
  select role.logical_id into v_role_logical_id
  from public.matrix_roles_v2 role where role.id=v_run.scope_role_id;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN'))
    and not exists(select 1 from public.matrix_scope_grants_v2 grant_row
      where grant_row.auth_user_id=v_actor and grant_row.active
        and grant_row.app_role='ROLE_MANAGER'
        and (grant_row.role_logical_id is null
          or grant_row.role_logical_id=v_role_logical_id)) then
    raise exception 'ROLE_PUBLICATION_FORBIDDEN';
  end if;
  select * into v_existing from public.published_role_schedules_v2 publication
  where publication.created_by=v_actor
    and publication.idempotency_key=p_idempotency_key;
  if v_existing.id is not null then
    if v_existing.variant_id<>p_variant_id or v_existing.name<>trim(p_name) then
      raise exception 'IDEMPOTENCY_KEY_REUSED';
    end if;
    return jsonb_build_object('roleScheduleId',v_existing.id,
      'status',v_existing.status,'reused',true,'changed',0,'notified',0);
  end if;

  select publication.variant_id into v_previous_variant_id
  from public.published_role_schedules_v2 publication
  where publication.month=v_run.month
    and publication.role_id=v_run.scope_role_id
    and publication.status='PUBLISHED'
  order by publication.published_at desc,publication.id desc limit 1;

  v_validation:=solver_private.revalidate_materialized_variant_v2(
    p_variant_id,false
  );
  update public.published_role_schedules_v2 publication set
    status='ARCHIVED',archived_at=now(),archived_by=v_actor
  where publication.month=v_run.month
    and publication.role_id=v_run.scope_role_id
    and publication.status='PUBLISHED';
  insert into public.published_role_schedules_v2(
    id,idempotency_key,month,matrix_version_id,scenario_id,role_id,
    variant_id,name,publication_hash,created_by
  ) values(
    v_id,p_idempotency_key,v_run.month,v_run.matrix_version_id,v_run.scenario_id,
    v_run.scope_role_id,p_variant_id,trim(p_name),v_variant.solution_hash,v_actor
  );

  select count(*)::integer into v_changed
  from solver_private.changed_variant_employees_uat_v1(
    case when v_previous_variant_id is null then '{}'::uuid[] else array[v_previous_variant_id] end,
    array[p_variant_id]
  );
  insert into public.notifications(recipient_id,channel,title,body)
  select employee.auth_user_id,'IN_APP','Zmieniono Twój grafik zespołu',
    trim(p_name)||' zawiera zmianę Twoich przydziałów. Sprawdź aktualny grafik w Portalu pracownika.'
  from solver_private.changed_variant_employees_uat_v1(
    case when v_previous_variant_id is null then '{}'::uuid[] else array[v_previous_variant_id] end,
    array[p_variant_id]
  ) change
  join public.employees employee on employee.id=change.employee_id
  where employee.auth_user_id is not null;
  get diagnostics v_notified=row_count;

  update public.plan_variants_v2
  set status='PUBLISHED',published_at=now()
  where id=p_variant_id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'published_role_schedule_v2',v_id::text,'PUBLISH',
    jsonb_build_object('runId',p_run_id,'variantId',p_variant_id,
      'previousVariantId',v_previous_variant_id,
      'roleId',v_run.scope_role_id,'changed',v_changed,'notified',v_notified,
      'validation',v_validation));
  return jsonb_build_object('roleScheduleId',v_id,'status','PUBLISHED',
    'reused',false,'changed',v_changed,'notified',v_notified);
end;
$$;

revoke all on function public.optimizer_publish_role_variant_uat_v2(
  uuid,uuid,text,text
) from public,anon,authenticated;
grant execute on function public.optimizer_publish_role_variant_uat_v2(
  uuid,uuid,text,text
) to authenticated;

create or replace function public.optimizer_publish_company_variant_resolved_uat_v2(
  p_run_id uuid,
  p_variant_id uuid,
  p_name text,
  p_idempotency_key text,
  p_warning_reason text default null,
  p_role_replacement_reason text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid:=auth.uid();
  v_run public.optimization_runs_v2%rowtype;
  v_previous_variant_ids uuid[];
  v_archived_role_schedules integer:=0;
  v_changed integer:=0;
  v_notified integer:=0;
  v_result jsonb;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'COMPANY_PUBLICATION_OWNER_REQUIRED';
  end if;

  select run.* into v_run
  from public.optimization_runs_v2 run
  where run.id=p_run_id
  for update;
  if v_run.id is null or not solver_private.can_access_run_v2(p_run_id) then
    raise exception 'RUN_NOT_FOUND';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'publish-v2-month:'||v_run.month::text,0
  ));

  select array_agg(publication.variant_id order by publication.role_id,publication.published_at)
  into v_previous_variant_ids
  from public.published_role_schedules_v2 publication
  where publication.month=v_run.month and publication.status='PUBLISHED';
  if coalesce(cardinality(v_previous_variant_ids),0)=0 then
    select array_agg(link.variant_id order by link.ordinal)
    into v_previous_variant_ids
    from public.published_schedules_v2 schedule
    join public.published_schedule_variants_v2 link on link.schedule_id=schedule.id
    where schedule.id=(
      select current_schedule.id
      from public.published_schedules_v2 current_schedule
      where current_schedule.month=v_run.month and current_schedule.status='PUBLISHED'
      order by current_schedule.published_at desc,current_schedule.id desc limit 1
    );
  end if;

  if exists(
    select 1 from public.published_role_schedules_v2 publication
    where publication.month=v_run.month and publication.status='PUBLISHED'
  ) then
    if length(trim(coalesce(p_role_replacement_reason,'')))<5 then
      raise exception 'ROLE_PUBLICATION_REPLACEMENT_REASON_REQUIRED';
    end if;
    update public.published_role_schedules_v2 publication set
      status='ARCHIVED',archived_at=now(),archived_by=v_actor
    where publication.month=v_run.month and publication.status='PUBLISHED';
    get diagnostics v_archived_role_schedules=row_count;
  end if;

  v_result:=public.optimizer_publish_company_variant_alpha16(
    p_run_id,p_variant_id,p_name,p_idempotency_key,p_warning_reason
  );
  if not coalesce((v_result->>'published')::boolean,false) then
    raise exception 'ATOMIC_COMPANY_PUBLICATION_FAILED: %',
      coalesce(v_result->>'message',v_result->>'code','UNKNOWN');
  end if;

  if not coalesce((v_result->>'reused')::boolean,false) then
    select count(*)::integer into v_changed
    from solver_private.changed_variant_employees_uat_v1(
      coalesce(v_previous_variant_ids,'{}'::uuid[]),array[p_variant_id]
    );
    insert into public.notifications(recipient_id,channel,title,body)
    select employee.auth_user_id,'IN_APP','Zmieniono Twój grafik',
      trim(p_name)||' zawiera zmianę Twoich przydziałów. Sprawdź aktualny grafik w Portalu pracownika.'
    from solver_private.changed_variant_employees_uat_v1(
      coalesce(v_previous_variant_ids,'{}'::uuid[]),array[p_variant_id]
    ) change
    join public.employees employee on employee.id=change.employee_id
    where employee.auth_user_id is not null;
    get diagnostics v_notified=row_count;
  end if;

  if v_archived_role_schedules>0 then
    insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
    values(v_actor,'schedule_publication_authority_v2',v_run.month::text,
      'REPLACE_ROLES_WITH_COMPANY',jsonb_build_object(
        'reason',trim(p_role_replacement_reason),
        'archivedRoleSchedules',v_archived_role_schedules,
        'scheduleId',v_result->>'scheduleId',
        'runId',p_run_id,'variantId',p_variant_id
      ));
  end if;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'published_schedule_v2',v_result->>'scheduleId','NOTIFY_CHANGED_EMPLOYEES',
    jsonb_build_object('previousVariantIds',coalesce(to_jsonb(v_previous_variant_ids),'[]'::jsonb),
      'variantId',p_variant_id,'changed',v_changed,'notified',v_notified));

  return v_result||jsonb_build_object(
    'archivedRoleSchedules',v_archived_role_schedules,
    'publicationAuthority','COMPANY',
    'changed',v_changed,
    'notified',v_notified
  );
end;
$$;

revoke all on function public.optimizer_publish_company_variant_resolved_uat_v2(
  uuid,uuid,text,text,text,text
) from public,anon,authenticated;
grant execute on function public.optimizer_publish_company_variant_resolved_uat_v2(
  uuid,uuid,text,text,text,text
) to authenticated;

notify pgrst,'reload schema';
