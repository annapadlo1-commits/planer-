create table if not exists public.employee_weekly_work_patterns_v2 (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete cascade,
  weekday smallint not null check (weekday between 1 and 7),
  local_start time not null,
  local_end time not null,
  role_id uuid references public.matrix_roles_v2(id) on delete restrict,
  location_id uuid references public.matrix_locations_v2(id) on delete restrict,
  enforcement text not null check (enforcement in ('HARD','PREFERENCE')),
  valid_from date not null,
  valid_to date,
  active boolean not null default true,
  revision integer not null default 1 check (revision > 0),
  supersedes_id uuid references public.employee_weekly_work_patterns_v2(id) on delete set null,
  reason text not null,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  check (valid_to is null or valid_to >= valid_from),
  check (length(trim(reason)) >= 3)
);

create index if not exists employee_weekly_work_patterns_active_idx
  on public.employee_weekly_work_patterns_v2(employee_id, valid_from, valid_to)
  where active;

alter table public.employee_weekly_work_patterns_v2 enable row level security;
revoke all on table public.employee_weekly_work_patterns_v2 from public, anon;
grant select on table public.employee_weekly_work_patterns_v2 to authenticated;

drop policy if exists employee_weekly_work_patterns_read on public.employee_weekly_work_patterns_v2;
create policy employee_weekly_work_patterns_read
on public.employee_weekly_work_patterns_v2 for select to authenticated
using (public.can_manage_plans() or public.matrix_v2_can_manage_employee(employee_id));

create or replace function public.employee_weekly_work_patterns_workspace_uat_v1(
  p_employee_id uuid,
  p_on_date date default current_date
) returns jsonb
language plpgsql stable security definer set search_path=''
as $$
begin
  if not (public.can_manage_plans() or public.matrix_v2_can_manage_employee(p_employee_id)) then raise exception 'FORBIDDEN'; end if;
  return jsonb_build_object(
      'employeeId',p_employee_id,
      'onDate',p_on_date,
      'canEdit',public.can_manage_plans(),
      'patterns',coalesce((select jsonb_agg(jsonb_build_object(
        'id',p.id,'weekday',p.weekday,'localStart',p.local_start,'localEnd',p.local_end,
        'roleId',p.role_id,'locationId',p.location_id,'enforcement',p.enforcement,
        'validFrom',p.valid_from,'validTo',p.valid_to,'revision',p.revision,
        'reason',p.reason,'active',p.active
      ) order by p.weekday,p.local_start,p.created_at)
      from public.employee_weekly_work_patterns_v2 p
      where p.employee_id=p_employee_id and p.active
        and p.valid_from<=p_on_date and (p.valid_to is null or p.valid_to>=p_on_date)),'[]'::jsonb)
    );
end;
$$;

create or replace function public.employee_weekly_work_patterns_replace_uat_v1(
  p_employee_id uuid,
  p_valid_from date,
  p_valid_to date,
  p_patterns jsonb,
  p_reason text
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid:=auth.uid();
  v_reason text:=trim(coalesce(p_reason,''));
  v_item jsonb;
  v_count integer:=0;
  v_revision integer;
  v_supersedes_id uuid;
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if length(v_reason)<3 then raise exception 'WORK_PATTERN_REASON_REQUIRED'; end if;
  if p_valid_to is not null and p_valid_to<p_valid_from then raise exception 'WORK_PATTERN_PERIOD_INVALID'; end if;
  if jsonb_typeof(coalesce(p_patterns,'[]'::jsonb))<>'array' then raise exception 'WORK_PATTERNS_ARRAY_REQUIRED'; end if;

  perform pg_advisory_xact_lock(hashtextextended('weekly-pattern:'||p_employee_id::text,0));
  select coalesce(max(revision),0)+1 into v_revision
  from public.employee_weekly_work_patterns_v2 where employee_id=p_employee_id;
  update public.employee_weekly_work_patterns_v2 set active=false,revoked_at=now()
  where employee_id=p_employee_id and active
    and daterange(valid_from,coalesce(valid_to,'infinity'::date),'[]') && daterange(p_valid_from,coalesce(p_valid_to,'infinity'::date),'[]');

  for v_item in select value from jsonb_array_elements(coalesce(p_patterns,'[]'::jsonb)) loop
    if coalesce((v_item->>'weekday')::integer,0) not between 1 and 7 then raise exception 'WORK_PATTERN_WEEKDAY_INVALID'; end if;
    if nullif(v_item->>'localStart','') is null or nullif(v_item->>'localEnd','') is null then raise exception 'WORK_PATTERN_TIME_REQUIRED'; end if;
    if upper(coalesce(v_item->>'enforcement','')) not in ('HARD','PREFERENCE') then raise exception 'WORK_PATTERN_ENFORCEMENT_INVALID'; end if;
    select p.id into v_supersedes_id
    from public.employee_weekly_work_patterns_v2 p
    where p.employee_id=p_employee_id and p.revision<v_revision
      and p.weekday=(v_item->>'weekday')::smallint
      and p.local_start=(v_item->>'localStart')::time
      and p.local_end=(v_item->>'localEnd')::time
      and p.role_id is not distinct from nullif(v_item->>'roleId','')::uuid
      and p.location_id is not distinct from nullif(v_item->>'locationId','')::uuid
      and p.enforcement=upper(v_item->>'enforcement')
    order by p.revision desc,p.created_at desc limit 1;
    insert into public.employee_weekly_work_patterns_v2(employee_id,weekday,local_start,local_end,role_id,location_id,enforcement,valid_from,valid_to,revision,supersedes_id,reason,created_by)
    values(p_employee_id,(v_item->>'weekday')::smallint,(v_item->>'localStart')::time,(v_item->>'localEnd')::time,
      nullif(v_item->>'roleId','')::uuid,nullif(v_item->>'locationId','')::uuid,upper(v_item->>'enforcement'),p_valid_from,p_valid_to,v_revision,v_supersedes_id,v_reason,v_actor);
    v_count:=v_count+1;
  end loop;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'employee_weekly_work_pattern_v2',p_employee_id::text,'REPLACE',jsonb_build_object('validFrom',p_valid_from,'validTo',p_valid_to,'count',v_count,'reason',v_reason));
  return jsonb_build_object('employeeId',p_employee_id,'count',v_count,'revision',v_revision,'validFrom',p_valid_from,'validTo',p_valid_to);
end;
$$;

alter function solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)
  rename to build_snapshot_payload_before_b4f91_uat_v1;

create function solver_private.build_snapshot_payload_v2(
  p_matrix_version_id uuid,p_month date,p_scenario_id uuid,p_scope_role_id uuid,
  p_scope_type text,p_actor uuid
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_snapshot jsonb;v_period_end date:=(p_month+interval '1 month - 1 day')::date;
begin
  v_snapshot:=solver_private.build_snapshot_payload_before_b4f91_uat_v1(p_matrix_version_id,p_month,p_scenario_id,p_scope_role_id,p_scope_type,p_actor);
  return jsonb_set(v_snapshot,'{workPatterns}',coalesce((select jsonb_agg(jsonb_build_object(
    'id',p.id,'employeeId',p.employee_id,'weekday',p.weekday,'localStart',p.local_start,
    'localEnd',p.local_end,'roleId',p.role_id,'locationId',p.location_id,
    'enforcement',p.enforcement,'validFrom',p.valid_from,'validTo',p.valid_to
  ) order by p.employee_id,p.weekday,p.local_start)
  from public.employee_weekly_work_patterns_v2 p
  where p.active and p.valid_from<=v_period_end and (p.valid_to is null or p.valid_to>=p_month)
    and exists(select 1 from jsonb_array_elements(coalesce(v_snapshot->'employees','[]'::jsonb)) e where e->>'id'=p.employee_id::text)),'[]'::jsonb),true);
end;$$;

revoke all on function public.employee_weekly_work_patterns_workspace_uat_v1(uuid,date),
 public.employee_weekly_work_patterns_replace_uat_v1(uuid,date,date,jsonb,text) from public,anon,authenticated;
grant execute on function public.employee_weekly_work_patterns_workspace_uat_v1(uuid,date),
 public.employee_weekly_work_patterns_replace_uat_v1(uuid,date,date,jsonb,text) to authenticated;
revoke all on function solver_private.build_snapshot_payload_before_b4f91_uat_v1(uuid,date,uuid,uuid,text,uuid),
 solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid) from public,anon,authenticated;
grant execute on function solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid) to service_role;

alter function public.matrix_v2_workspace(date)
  rename to matrix_v2_workspace_before_b4f91_uat_v1;
create function public.matrix_v2_workspace(p_month date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare v_result jsonb;v_month_end date:=(p_month+interval '1 month - 1 day')::date;
begin
  v_result:=public.matrix_v2_workspace_before_b4f91_uat_v1(p_month);
  return v_result||jsonb_build_object('workPatterns',coalesce((select jsonb_agg(jsonb_build_object(
    'id',p.id,'employeeId',p.employee_id,'weekday',p.weekday,'localStart',p.local_start,
    'localEnd',p.local_end,'roleId',p.role_id,'locationId',p.location_id,
    'enforcement',p.enforcement,'validFrom',p.valid_from,'validTo',p.valid_to,
    'revision',p.revision,'reason',p.reason,'active',p.active
  ) order by p.employee_id,p.valid_from,p.weekday,p.local_start)
  from public.employee_weekly_work_patterns_v2 p where p.active and p.valid_from<=v_month_end
    and (p.valid_to is null or p.valid_to>=p_month)),'[]'::jsonb));
end;$$;
revoke all on function public.matrix_v2_workspace_before_b4f91_uat_v1(date),
 public.matrix_v2_workspace(date) from public,anon,authenticated;
grant execute on function public.matrix_v2_workspace(date) to authenticated;

create or replace function solver_private.employee_weekly_pattern_allows_uat_v1(
  p_employee_id uuid,p_shift_date date,p_starts_at timestamptz,p_ends_at timestamptz,
  p_role_id uuid,p_location_id uuid,p_timezone text
) returns boolean language sql stable security definer set search_path='' as $$
  with active_hard as (
    select p.* from public.employee_weekly_work_patterns_v2 p
    where p.employee_id=p_employee_id and p.active and p.enforcement='HARD'
      and p.valid_from<=p_shift_date and (p.valid_to is null or p.valid_to>=p_shift_date)
  ), local_shift as (
    select extract(isodow from p_shift_date)::integer weekday,
      (p_starts_at at time zone p_timezone)::time start_time,
      (p_ends_at at time zone p_timezone)::time end_time,
      (p_ends_at at time zone p_timezone)::date>(p_starts_at at time zone p_timezone)::date overnight
  )
  select not exists(select 1 from active_hard) or exists(
    select 1 from active_hard p cross join local_shift s
    where p.weekday=s.weekday and (p.role_id is null or p.role_id=p_role_id)
      and (p.location_id is null or p.location_id=p_location_id)
      and p.local_start<=s.start_time
      and case when p.local_end<=p.local_start then
        (s.overnight and s.end_time<=p.local_end) or (not s.overnight and s.end_time>=p.local_start)
      else not s.overnight and s.end_time<=p.local_end end
  );
$$;

create or replace function public.optimizer_leader_assignment_context_uat_v4(
  p_variant_id uuid,p_assignment_id uuid default null,p_issue_id bigint default null
) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare
  v_payload jsonb:=public.optimizer_leader_assignment_context_uat_v3(p_variant_id,p_assignment_id,p_issue_id);
  v_candidates jsonb:='[]'::jsonb;v_candidate jsonb;v_allowed boolean;v_timezone text;
begin
  select coalesce(version.settings->>'timezone','Europe/Warsaw') into v_timezone
  from public.plan_variants_v2 variant join public.optimization_runs_v2 run on run.id=variant.run_id
  join public.matrix_versions version on version.id=run.matrix_version_id where variant.id=p_variant_id;
  for v_candidate in select value from jsonb_array_elements(coalesce(v_payload->'candidates','[]'::jsonb)) loop
    v_allowed:=solver_private.employee_weekly_pattern_allows_uat_v1(
      (v_candidate->>'employeeId')::uuid,(v_payload#>>'{shift,date}')::date,
      (v_payload#>>'{shift,startsAt}')::timestamptz,(v_payload#>>'{shift,endsAt}')::timestamptz,
      (v_payload#>>'{role,id}')::uuid,(v_payload#>>'{shift,locationId}')::uuid,v_timezone);
    v_candidate:=v_candidate||jsonb_build_object(
      'workPatternAllowed',v_allowed,
      'availabilityStatus',case when v_allowed then v_candidate->>'availabilityStatus' else 'PERMANENT_WORK_PATTERN' end,
      'suggestionEligible',coalesce((v_candidate->>'suggestionEligible')::boolean,false) and v_allowed);
    v_candidates:=v_candidates||jsonb_build_array(v_candidate);
  end loop;
  return jsonb_set(v_payload,'{candidates}',v_candidates,true)
    ||jsonb_build_object('workPatternsChecked',true);
end;$$;

create or replace function public.optimizer_leader_assignment_save_uat_v4(
  p_variant_id uuid,p_assignment_id uuid,p_issue_id bigint,p_employee_id uuid,p_reason text,
  p_allow_limit_override boolean default false,p_duty_transfer_assignment_id uuid default null,
  p_approve_overtime boolean default false
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_context jsonb;v_candidate jsonb;
begin
  v_context:=public.optimizer_leader_assignment_context_uat_v4(p_variant_id,p_assignment_id,p_issue_id);
  select value into v_candidate from jsonb_array_elements(coalesce(v_context->'candidates','[]'::jsonb))
    where value->>'employeeId'=p_employee_id::text;
  if v_candidate is null then raise exception 'VARIANT_EMPLOYEE_ELIGIBILITY_INVALID'; end if;
  if not coalesce((v_candidate->>'workPatternAllowed')::boolean,false) then
    raise exception 'PERMANENT_WORK_PATTERN_BLOCK:%',jsonb_build_object(
      'employeeId',p_employee_id,'date',v_context#>>'{shift,date}',
      'message','Stały wzorzec pracy pracownika nie obejmuje tej zmiany.')::text;
  end if;
  return public.optimizer_leader_assignment_save_uat_v3(
    p_variant_id,p_assignment_id,p_issue_id,p_employee_id,p_reason,p_allow_limit_override,
    p_duty_transfer_assignment_id,p_approve_overtime);
end;$$;

create or replace function public.optimizer_leader_assignment_validate_uat_v2(
  p_variant_id uuid,p_assignment_id uuid,p_issue_id bigint,p_employee_id uuid,
  p_allow_limit_override boolean default false,p_duty_transfer_assignment_id uuid default null,
  p_approve_overtime boolean default false
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_result jsonb;v_rollback_marker constant text:='B4F95_DRY_RUN_ROLLBACK';
begin
  begin
    v_result:=public.optimizer_leader_assignment_save_uat_v4(
      p_variant_id,p_assignment_id,p_issue_id,p_employee_id,'Sprawdzenie przed zapisem',
      p_allow_limit_override,p_duty_transfer_assignment_id,p_approve_overtime);
    raise exception using errcode='P0001',message=v_rollback_marker;
  exception when raise_exception then
    if sqlerrm<>v_rollback_marker then raise; end if;
  end;
  return coalesce(v_result,'{}'::jsonb)||jsonb_build_object('valid',true,'mutated',false,'checkedAt',now());
end;$$;

revoke all on function solver_private.employee_weekly_pattern_allows_uat_v1(uuid,date,timestamptz,timestamptz,uuid,uuid,text),
 public.optimizer_leader_assignment_context_uat_v4(uuid,uuid,bigint),
 public.optimizer_leader_assignment_save_uat_v4(uuid,uuid,bigint,uuid,text,boolean,uuid,boolean),
 public.optimizer_leader_assignment_validate_uat_v2(uuid,uuid,bigint,uuid,boolean,uuid,boolean)
 from public,anon,authenticated;
grant execute on function public.optimizer_leader_assignment_context_uat_v4(uuid,uuid,bigint),
 public.optimizer_leader_assignment_save_uat_v4(uuid,uuid,bigint,uuid,text,boolean,uuid,boolean),
 public.optimizer_leader_assignment_validate_uat_v2(uuid,uuid,bigint,uuid,boolean,uuid,boolean)
 to authenticated;
notify pgrst,'reload schema';
