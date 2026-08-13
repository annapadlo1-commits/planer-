-- B6: post-publication operational events and the INVETORY PRO bridge.
-- UAT-only deployment target: nhthrtpkfpmufmrmdyjg.

create table if not exists public.business_app_integrations_v1 (
  id uuid primary key default gen_random_uuid(),
  product_code text not null unique check (product_code ~ '^[A-Z0-9_]{2,80}$'),
  display_name text not null check (length(trim(display_name)) between 2 and 120),
  base_url text,
  launch_path_template text not null default '/sessions/new?eventId={eventId}',
  connection_status text not null default 'DISCONNECTED'
    check (connection_status in ('DISCONNECTED','CONFIGURED','READY','ERROR')),
  active boolean not null default false,
  configuration jsonb not null default '{}'::jsonb,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (base_url is null or base_url ~ '^https?://')
);

insert into public.business_app_integrations_v1(product_code,display_name)
values('INVETORY_PRO','INVETORY PRO')
on conflict(product_code) do nothing;

create table if not exists public.operational_program_events_v1 (
  id uuid primary key default gen_random_uuid(),
  event_type text not null check(event_type in (
    'MEETING','CLEANING','INVENTORY','TRAINING','ONBOARDING','OTHER'
  )),
  title text not null check(length(trim(title)) between 2 and 180),
  description text,
  location_id uuid references public.matrix_locations_v2(id) on delete restrict,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status text not null default 'DRAFT'
    check(status in ('DRAFT','ANALYSIS','PUBLISHED','COMPLETED','CANCELLED')),
  audience_mode text not null default 'NEED_COUNT'
    check(audience_mode in ('ALL_SCOPE','SELECTED','NEED_COUNT')),
  required_count integer check(required_count between 1 and 500),
  inventory_type text check(inventory_type in ('FULL','PARTIAL','CONTROL','SELECTED_GROUPS')),
  inventory_groups text[] not null default '{}',
  private_note text,
  published_note text,
  agenda text,
  version_no integer not null default 1 check(version_no > 0),
  parent_event_id uuid references public.operational_program_events_v1(id) on delete set null,
  cancellation_reason text,
  created_by uuid not null references auth.users(id) on delete restrict,
  published_by uuid references auth.users(id) on delete set null,
  published_at timestamptz,
  cancelled_by uuid references auth.users(id) on delete set null,
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(ends_at > starts_at),
  check(event_type='INVENTORY' or inventory_type is null),
  check(audience_mode<>'NEED_COUNT' or required_count is not null),
  check(
    (status='PUBLISHED' and published_at is not null)
    or status<>'PUBLISHED'
  ),
  check(
    (status='CANCELLED' and cancelled_at is not null and length(trim(cancellation_reason))>=3)
    or status<>'CANCELLED'
  )
);

create table if not exists public.operational_program_audience_rules_v1 (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.operational_program_events_v1(id) on delete cascade,
  rule_mode text not null check(rule_mode in ('INCLUDE','EXCLUDE')),
  scope_type text not null check(scope_type in (
    'ALL_ACTIVE','CATEGORY','ROLE','APP_ROLE','EMPLOYEE','LOCATION'
  )),
  scope_uuid uuid,
  scope_code text,
  created_at timestamptz not null default now(),
  check(scope_uuid is not null or length(trim(coalesce(scope_code,'')))>0)
);

create table if not exists public.operational_program_participants_v1 (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.operational_program_events_v1(id) on delete cascade,
  employee_id uuid references public.employees(id) on delete restrict,
  auth_user_id uuid references auth.users(id) on delete set null,
  selection_source text not null default 'MANAGER'
    check(selection_source in ('SCOPE','SUGGESTION','MANAGER','INVITATION')),
  candidate_status text not null default 'SAFE'
    check(candidate_status in ('SAFE','WARNING','BLOCKED')),
  reasons text[] not null default '{}',
  assignment_status text not null default 'CONFIRMED'
    check(assignment_status in (
      'PROPOSED','INVITED','CONFIRMED','DECLINED','CANCELLED','ATTENDED','ABSENT'
    )),
  override_reason text,
  acknowledged_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(employee_id is not null or auth_user_id is not null)
);
create unique index if not exists operational_program_participant_employee_idx
  on public.operational_program_participants_v1(event_id,employee_id)
  where employee_id is not null;
create unique index if not exists operational_program_participant_user_idx
  on public.operational_program_participants_v1(event_id,auth_user_id)
  where employee_id is null and auth_user_id is not null;

create table if not exists public.operational_program_checklist_items_v1 (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.operational_program_events_v1(id) on delete cascade,
  item_order integer not null default 0,
  label text not null check(length(trim(label)) between 2 and 240),
  visibility text not null default 'ALL' check(visibility in ('ORGANIZER','ALL','SELECTED')),
  visible_to jsonb not null default '[]'::jsonb,
  completed boolean not null default false,
  completed_by uuid references auth.users(id) on delete set null,
  completed_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.operational_program_inventory_links_v1 (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null unique references public.operational_program_events_v1(id) on delete cascade,
  integration_id uuid not null references public.business_app_integrations_v1(id) on delete restrict,
  external_session_id text,
  external_session_url text,
  sync_status text not null default 'WAITING_CONFIGURATION'
    check(sync_status in ('WAITING_CONFIGURATION','QUEUED','READY','ERROR','CANCELLED','COMPLETED')),
  payload jsonb not null default '{}'::jsonb,
  payload_hash text not null,
  attempt_count integer not null default 0 check(attempt_count>=0),
  last_error text,
  last_attempt_at timestamptz,
  synced_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.operational_program_audit_v1 (
  id bigint generated always as identity primary key,
  event_id uuid references public.operational_program_events_v1(id) on delete set null,
  actor_id uuid references auth.users(id) on delete set null,
  action text not null,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists operational_program_events_month_idx
  on public.operational_program_events_v1(starts_at,status,event_type);
create index if not exists operational_program_audience_event_idx
  on public.operational_program_audience_rules_v1(event_id,rule_mode,scope_type);
create index if not exists operational_program_participants_event_idx
  on public.operational_program_participants_v1(event_id,assignment_status);

alter table public.business_app_integrations_v1 enable row level security;
alter table public.operational_program_events_v1 enable row level security;
alter table public.operational_program_audience_rules_v1 enable row level security;
alter table public.operational_program_participants_v1 enable row level security;
alter table public.operational_program_checklist_items_v1 enable row level security;
alter table public.operational_program_inventory_links_v1 enable row level security;
alter table public.operational_program_audit_v1 enable row level security;

revoke all on table public.business_app_integrations_v1,
  public.operational_program_events_v1,public.operational_program_audience_rules_v1,
  public.operational_program_participants_v1,public.operational_program_checklist_items_v1,
  public.operational_program_inventory_links_v1,public.operational_program_audit_v1
  from public,anon,authenticated;
grant all on table public.business_app_integrations_v1,
  public.operational_program_events_v1,public.operational_program_audience_rules_v1,
  public.operational_program_participants_v1,public.operational_program_checklist_items_v1,
  public.operational_program_inventory_links_v1,public.operational_program_audit_v1
  to service_role;

create or replace function public.operational_program_can_manage_uat_v1()
returns boolean language sql stable security definer set search_path='' as $$
  select auth.uid() is not null and (
    public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('ROLE_MANAGER') or public.has_app_role('LOCATION_MANAGER')
  );
$$;

create or replace function public.operational_program_preview_uat_v1(
  p_month date,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_location_id uuid default null,
  p_category_ids uuid[] default '{}',
  p_role_ids uuid[] default '{}',
  p_employee_ids uuid[] default '{}',
  p_required_count integer default 1
) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare v_matrix uuid; v_month date:=date_trunc('month',p_month)::date;
begin
  if not public.operational_program_can_manage_uat_v1() then raise exception 'FORBIDDEN'; end if;
  if p_ends_at<=p_starts_at then raise exception 'INVALID_EVENT_RANGE'; end if;
  select id into v_matrix from public.matrix_versions
    where status in('ACTIVE','ARCHIVED') and schema_version>=2
      and effective_from<=v_month
    order by effective_from desc,version desc limit 1;
  if v_matrix is null then raise exception 'PUBLISHED_CONFIGURATION_NOT_FOUND'; end if;

  return jsonb_build_object(
    'requiredCount',greatest(1,coalesce(p_required_count,1)),
    'candidates',coalesce((
      with scoped as (
        select profile.employee_id,profile.employee_no,profile.first_name,profile.last_name,
          profile.nominal_monthly_minutes,profile.maximum_monthly_minutes,
          profile.maximum_weekly_minutes,coalesce(profile.minimum_rest_minutes,660) minimum_rest_minutes,
          employee.auth_user_id,
          exists(select 1 from public.matrix_employee_locations_v2 location_grant
            where location_grant.matrix_version_id=v_matrix
              and location_grant.employee_id=profile.employee_id and location_grant.active
              and (p_location_id is null or location_grant.location_id=p_location_id)) location_ok
        from public.matrix_employee_profiles_v2 profile
        join public.employees employee on employee.id=profile.employee_id
        where profile.matrix_version_id=v_matrix and profile.active
          and employee.active and employee.archived_at is null
          and (cardinality(p_employee_ids)=0 or profile.employee_id=any(p_employee_ids))
          and (cardinality(p_employee_ids)>0 or (
            cardinality(p_role_ids)=0 or exists(
              select 1 from public.matrix_employee_roles_v2 role_grant
              where role_grant.matrix_version_id=v_matrix and role_grant.employee_id=profile.employee_id
                and role_grant.role_id=any(p_role_ids) and role_grant.active
            )
          ))
          and (cardinality(p_employee_ids)>0 or cardinality(p_category_ids)=0 or exists(
            select 1 from public.matrix_employee_roles_v2 role_grant
            join public.matrix_roles_v2 role_row on role_row.id=role_grant.role_id
            where role_grant.matrix_version_id=v_matrix and role_grant.employee_id=profile.employee_id
              and role_grant.active and role_row.category_id=any(p_category_ids)
          ))
      ), evaluated as (
        select scoped.*,
          exists(select 1 from public.employee_time_constraints_v2 constraint_row
            where constraint_row.employee_id=scoped.employee_id and constraint_row.status='ACTIVE'
              and constraint_row.constraint_kind in('UNAVAILABLE','LEAVE','SICKNESS')
              and constraint_row.time_range && tstzrange(p_starts_at,p_ends_at,'[)')) unavailable,
          exists(select 1 from public.published_schedules_v2 schedule
            join public.published_schedule_variants_v2 link on link.schedule_id=schedule.id
            join public.plan_assignments_v2 assignment on assignment.variant_id=link.variant_id
            join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
            where schedule.month=v_month and schedule.status='PUBLISHED'
              and assignment.employee_id=scoped.employee_id
              and tstzrange(shift_row.starts_at,shift_row.ends_at,'[)') && tstzrange(p_starts_at,p_ends_at,'[)')) overlaps_shift,
          exists(select 1 from public.published_schedules_v2 schedule
            join public.published_schedule_variants_v2 link on link.schedule_id=schedule.id
            join public.plan_assignments_v2 assignment on assignment.variant_id=link.variant_id
            join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
            where schedule.month=v_month and schedule.status='PUBLISHED'
              and assignment.employee_id=scoped.employee_id
              and not (shift_row.ends_at<=p_starts_at-scoped.minimum_rest_minutes*interval '1 minute'
                or shift_row.starts_at>=p_ends_at+scoped.minimum_rest_minutes*interval '1 minute')) rest_risk,
          coalesce((select round(sum(extract(epoch from (shift_row.ends_at-shift_row.starts_at))/60))::integer
            from public.published_schedules_v2 schedule
            join public.published_schedule_variants_v2 link on link.schedule_id=schedule.id
            join public.plan_assignments_v2 assignment on assignment.variant_id=link.variant_id
            join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
            where schedule.month=v_month and schedule.status='PUBLISHED'
              and assignment.employee_id=scoped.employee_id),0) planned_minutes
        from scoped
      )
      select jsonb_agg(jsonb_build_object(
        'employeeId',employee_id,'employeeNo',employee_no,
        'name',first_name||' '||last_name,'authUserId',auth_user_id,
        'status',case when unavailable or overlaps_shift then 'BLOCKED'
          when not location_ok or rest_risk then 'WARNING' else 'SAFE' end,
        'reasons',to_jsonb(array_remove(array[
          case when unavailable then 'Twarda niedostępność, urlop albo L4' end,
          case when overlaps_shift then 'Ma już zmianę w tych godzinach' end,
          case when not location_ok then 'Brak przypisania do wybranego lokalu' end,
          case when rest_risk and not overlaps_shift then 'Ryzyko naruszenia odpoczynku' end
        ],null)),
        'plannedMinutes',planned_minutes,'nominalMinutes',nominal_monthly_minutes,
        'maximumMinutes',maximum_monthly_minutes
      ) order by
        case when unavailable or overlaps_shift then 3 when not location_ok or rest_risk then 2 else 1 end,
        abs(nominal_monthly_minutes-planned_minutes),last_name,first_name)
      from evaluated
    ),'[]'::jsonb)
  );
end;
$$;

create or replace function public.operational_program_workspace_uat_v1(p_month date)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_actor uuid:=auth.uid(); v_month date:=date_trunc('month',p_month)::date;
  v_matrix uuid; v_can_manage boolean; v_employee uuid;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  v_can_manage:=public.operational_program_can_manage_uat_v1();
  select id into v_matrix from public.matrix_versions
    where status in('ACTIVE','ARCHIVED') and schema_version>=2 and effective_from<=v_month
    order by effective_from desc,version desc limit 1;
  select id into v_employee from public.employees where auth_user_id=v_actor and active and archived_at is null limit 1;
  return jsonb_build_object(
    'canManage',v_can_manage,
    'canConfigureIntegration',public.has_app_role('OWNER') or public.has_app_role('ADMIN'),
    'integration',coalesce((select jsonb_build_object(
      'id',integration.id,'productCode',integration.product_code,'displayName',integration.display_name,
      'baseUrl',integration.base_url,'launchPathTemplate',integration.launch_path_template,
      'status',integration.connection_status,'active',integration.active
    ) from public.business_app_integrations_v1 integration where integration.product_code='INVETORY_PRO'),'null'::jsonb),
    'categories',coalesce((select jsonb_agg(jsonb_build_object(
      'id',category.id,'code',category.code,'name',category.name,'color',category.color
    ) order by category.sort_order,category.name) from public.matrix_role_categories_v2 category
      where category.matrix_version_id=v_matrix and category.active),'[]'::jsonb),
    'roles',coalesce((select jsonb_agg(jsonb_build_object(
      'id',role_row.id,'code',role_row.code,'name',role_row.name,'categoryId',role_row.category_id,'color',role_row.color
    ) order by role_row.sort_order,role_row.name) from public.matrix_roles_v2 role_row
      where role_row.matrix_version_id=v_matrix and role_row.active),'[]'::jsonb),
    'locations',coalesce((select jsonb_agg(jsonb_build_object(
      'id',location_row.id,'code',location_row.code,'name',location_row.name
    ) order by location_row.sort_order,location_row.name) from public.matrix_locations_v2 location_row
      where location_row.matrix_version_id=v_matrix and location_row.active),'[]'::jsonb),
    'employees',case when v_can_manage then coalesce((select jsonb_agg(jsonb_build_object(
      'id',profile.employee_id,'employeeNo',profile.employee_no,'name',profile.first_name||' '||profile.last_name,
      'email',profile.email
    ) order by profile.last_name,profile.first_name) from public.matrix_employee_profiles_v2 profile
      where profile.matrix_version_id=v_matrix and profile.active),'[]'::jsonb) else '[]'::jsonb end,
    'events',coalesce((select jsonb_agg(jsonb_build_object(
      'id',event_row.id,'type',event_row.event_type,'title',event_row.title,
      'description',event_row.description,'startsAt',event_row.starts_at,'endsAt',event_row.ends_at,
      'status',event_row.status,'audienceMode',event_row.audience_mode,'requiredCount',event_row.required_count,
      'locationId',event_row.location_id,'locationName',location_row.name,
      'publishedNote',event_row.published_note,'agenda',event_row.agenda,
      'inventoryType',event_row.inventory_type,'inventoryGroups',event_row.inventory_groups,
      'participants',coalesce((select jsonb_agg(jsonb_build_object(
        'employeeId',participant.employee_id,'name',coalesce(profile.first_name||' '||profile.last_name,user_row.email),
        'candidateStatus',participant.candidate_status,'status',participant.assignment_status,
        'reasons',participant.reasons
      ) order by coalesce(profile.last_name,user_row.email))
        from public.operational_program_participants_v1 participant
        left join public.matrix_employee_profiles_v2 profile on profile.matrix_version_id=v_matrix and profile.employee_id=participant.employee_id
        left join auth.users user_row on user_row.id=participant.auth_user_id
        where participant.event_id=event_row.id),'[]'::jsonb),
      'checklist',coalesce((select jsonb_agg(jsonb_build_object(
        'id',check_item.id,'label',check_item.label,'visibility',check_item.visibility,
        'completed',check_item.completed
      ) order by check_item.item_order,check_item.id)
        from public.operational_program_checklist_items_v1 check_item where check_item.event_id=event_row.id),'[]'::jsonb),
      'inventoryLink',(select jsonb_build_object(
        'status',inventory_link.sync_status,'url',inventory_link.external_session_url,
        'externalSessionId',inventory_link.external_session_id,'lastError',inventory_link.last_error
      ) from public.operational_program_inventory_links_v1 inventory_link where inventory_link.event_id=event_row.id)
    ) order by event_row.starts_at,event_row.title)
      from public.operational_program_events_v1 event_row
      left join public.matrix_locations_v2 location_row on location_row.id=event_row.location_id
      where event_row.starts_at>=v_month::timestamptz
        and event_row.starts_at<(v_month+interval '1 month')
        and (v_can_manage or exists(select 1 from public.operational_program_participants_v1 participant
          where participant.event_id=event_row.id and (participant.employee_id=v_employee or participant.auth_user_id=v_actor)))
    ),'[]'::jsonb)
  );
end;
$$;

create or replace function public.operational_program_save_uat_v1(
  p_event jsonb,
  p_audience jsonb default '[]'::jsonb,
  p_checklist jsonb default '[]'::jsonb,
  p_participant_ids uuid[] default '{}'
) returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare v_actor uuid:=auth.uid(); v_id uuid; v_item jsonb; v_preview jsonb; v_candidate jsonb;
  v_employee uuid; v_integration public.business_app_integrations_v1%rowtype; v_path text; v_url text;
  v_event public.operational_program_events_v1%rowtype;
begin
  if not public.operational_program_can_manage_uat_v1() then raise exception 'FORBIDDEN'; end if;
  if upper(coalesce(p_event->>'status','DRAFT')) not in('DRAFT','ANALYSIS','PUBLISHED') then
    raise exception 'INVALID_EVENT_STATUS';
  end if;
  insert into public.operational_program_events_v1(
    event_type,title,description,location_id,starts_at,ends_at,status,audience_mode,
    required_count,inventory_type,inventory_groups,private_note,published_note,agenda,
    created_by,published_by,published_at
  ) values(
    upper(trim(p_event->>'type')),trim(p_event->>'title'),nullif(trim(p_event->>'description'),''),
    nullif(p_event->>'locationId','')::uuid,(p_event->>'startsAt')::timestamptz,(p_event->>'endsAt')::timestamptz,
    upper(coalesce(p_event->>'status','DRAFT')),upper(coalesce(p_event->>'audienceMode','NEED_COUNT')),
    nullif(p_event->>'requiredCount','')::integer,
    case when upper(trim(p_event->>'type'))='INVENTORY' then upper(coalesce(p_event->>'inventoryType','FULL')) else null end,
    coalesce(array(select jsonb_array_elements_text(coalesce(p_event->'inventoryGroups','[]'::jsonb))),'{}'),
    nullif(p_event->>'privateNote',''),nullif(p_event->>'publishedNote',''),nullif(p_event->>'agenda',''),v_actor,
    case when upper(coalesce(p_event->>'status','DRAFT'))='PUBLISHED' then v_actor end,
    case when upper(coalesce(p_event->>'status','DRAFT'))='PUBLISHED' then now() end
  ) returning * into v_event;
  v_id:=v_event.id;

  for v_item in select value from jsonb_array_elements(coalesce(p_audience,'[]'::jsonb)) loop
    insert into public.operational_program_audience_rules_v1(
      event_id,rule_mode,scope_type,scope_uuid,scope_code
    ) values(v_id,upper(coalesce(v_item->>'mode','INCLUDE')),upper(v_item->>'type'),
      nullif(v_item->>'id','')::uuid,nullif(v_item->>'code',''));
  end loop;
  for v_item in select value from jsonb_array_elements(coalesce(p_checklist,'[]'::jsonb)) loop
    insert into public.operational_program_checklist_items_v1(event_id,item_order,label,visibility,visible_to)
    values(v_id,coalesce(nullif(v_item->>'order','')::integer,0),trim(v_item->>'label'),
      upper(coalesce(v_item->>'visibility','ALL')),coalesce(v_item->'visibleTo','[]'::jsonb));
  end loop;

  if cardinality(p_participant_ids)>0 then
    v_preview:=public.operational_program_preview_uat_v1(
      date_trunc('month',v_event.starts_at)::date,v_event.starts_at,v_event.ends_at,v_event.location_id,
      coalesce(array(select (x->>'id')::uuid from jsonb_array_elements(p_audience) x where upper(x->>'type')='CATEGORY' and upper(coalesce(x->>'mode','INCLUDE'))='INCLUDE'),'{}'),
      coalesce(array(select (x->>'id')::uuid from jsonb_array_elements(p_audience) x where upper(x->>'type')='ROLE' and upper(coalesce(x->>'mode','INCLUDE'))='INCLUDE'),'{}'),
      p_participant_ids,coalesce(v_event.required_count,cardinality(p_participant_ids)));
    foreach v_employee in array p_participant_ids loop
      select value into v_candidate from jsonb_array_elements(v_preview->'candidates')
        where value->>'employeeId'=v_employee::text limit 1;
      if v_candidate is null then raise exception 'PARTICIPANT_NOT_IN_ACTIVE_CONFIGURATION|%',v_employee; end if;
      if v_candidate->>'status'='BLOCKED' then raise exception 'PARTICIPANT_HARD_BLOCK|%|%',v_employee,v_candidate->'reasons'; end if;
      if v_candidate->>'status'='WARNING' and length(trim(coalesce(p_event->>'overrideReason','')))<5 then
        raise exception 'PARTICIPANT_WARNING_REQUIRES_REASON|%|%',v_employee,v_candidate->'reasons';
      end if;
      insert into public.operational_program_participants_v1(
        event_id,employee_id,auth_user_id,selection_source,candidate_status,reasons,
        assignment_status,override_reason
      ) select v_id,v_employee,employee.auth_user_id,
        case when upper(coalesce(p_event->>'audienceMode','NEED_COUNT'))='ALL_SCOPE' then 'SCOPE' else 'MANAGER' end,
        v_candidate->>'status',coalesce(array(select jsonb_array_elements_text(v_candidate->'reasons')),'{}'),
        'CONFIRMED',case when v_candidate->>'status'='WARNING' then trim(p_event->>'overrideReason') end
      from public.employees employee where employee.id=v_employee;
    end loop;
  end if;
  if v_event.audience_mode='NEED_COUNT' and cardinality(p_participant_ids)<coalesce(v_event.required_count,1)
    and v_event.status='PUBLISHED' then raise exception 'NOT_ENOUGH_PARTICIPANTS'; end if;

  if v_event.status='PUBLISHED' then
    insert into public.notifications(recipient_id,channel,title,body,sent_at)
    select distinct participant.auth_user_id,'IN_APP','Nowe wydarzenie: '||v_event.title,
      to_char(v_event.starts_at at time zone 'Europe/Warsaw','DD.MM.YYYY HH24:MI')||
        coalesce(' • '||v_event.published_note,''),now()
    from public.operational_program_participants_v1 participant
    where participant.event_id=v_id and participant.auth_user_id is not null;

    insert into public.time_records(employee_id,work_date,planned_start,planned_end,source,status)
    select participant.employee_id,(v_event.starts_at at time zone 'Europe/Warsaw')::date,
      v_event.starts_at,v_event.ends_at,'OPERATIONAL_EVENT:'||v_id::text,'OPEN'
    from public.operational_program_participants_v1 participant
    where participant.event_id=v_id and participant.employee_id is not null
    on conflict(employee_id,work_date,planned_start) do update set
      planned_end=excluded.planned_end,source=excluded.source;

    if v_event.event_type='INVENTORY' then
      select * into v_integration from public.business_app_integrations_v1 where product_code='INVETORY_PRO';
      v_path:=replace(v_integration.launch_path_template,'{eventId}',v_id::text);
      v_url:=case when v_integration.active and v_integration.base_url is not null
        then rtrim(v_integration.base_url,'/')||'/'||ltrim(v_path,'/') end;
      insert into public.operational_program_inventory_links_v1(
        event_id,integration_id,external_session_url,sync_status,payload,payload_hash
      ) values(v_id,v_integration.id,v_url,
        case when v_url is null then 'WAITING_CONFIGURATION' else 'QUEUED' end,
        jsonb_build_object('eventId',v_id,'title',v_event.title,'type',v_event.inventory_type,
          'groups',v_event.inventory_groups,'startsAt',v_event.starts_at,'endsAt',v_event.ends_at,
          'locationId',v_event.location_id,'participants',to_jsonb(p_participant_ids)),
        encode(extensions.digest((jsonb_build_object('eventId',v_id,'version',v_event.version_no))::text,'sha256'),'hex'));
    end if;
  end if;
  insert into public.operational_program_audit_v1(event_id,actor_id,action,detail)
    values(v_id,v_actor,case when v_event.status='PUBLISHED' then 'PUBLISH' else 'SAVE_DRAFT' end,
      jsonb_build_object('status',v_event.status,'participantCount',cardinality(p_participant_ids)));
  return jsonb_build_object('id',v_id,'status',v_event.status,'participantCount',cardinality(p_participant_ids));
end;
$$;

create or replace function public.operational_program_cancel_uat_v1(p_event_id uuid,p_reason text)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare v_actor uuid:=auth.uid(); v_event public.operational_program_events_v1%rowtype;
begin
  if not public.operational_program_can_manage_uat_v1() then raise exception 'FORBIDDEN'; end if;
  if length(trim(coalesce(p_reason,'')))<3 then raise exception 'CANCELLATION_REASON_REQUIRED'; end if;
  update public.operational_program_events_v1 set status='CANCELLED',cancellation_reason=trim(p_reason),
    cancelled_by=v_actor,cancelled_at=now(),updated_at=now()
    where id=p_event_id and status not in('CANCELLED','COMPLETED') returning * into v_event;
  if v_event.id is null then raise exception 'EVENT_NOT_CANCELLABLE'; end if;
  update public.operational_program_participants_v1 set assignment_status='CANCELLED',updated_at=now()
    where event_id=p_event_id;
  update public.operational_program_inventory_links_v1 set sync_status='CANCELLED',updated_at=now()
    where event_id=p_event_id;
  delete from public.time_records where source='OPERATIONAL_EVENT:'||p_event_id::text and status='OPEN';
  insert into public.notifications(recipient_id,channel,title,body,sent_at)
    select distinct participant.auth_user_id,'IN_APP','Anulowano: '||v_event.title,trim(p_reason),now()
    from public.operational_program_participants_v1 participant
    where participant.event_id=p_event_id and participant.auth_user_id is not null;
  insert into public.operational_program_audit_v1(event_id,actor_id,action,detail)
    values(p_event_id,v_actor,'CANCEL',jsonb_build_object('reason',trim(p_reason)));
  return jsonb_build_object('id',p_event_id,'status','CANCELLED');
end;
$$;

create or replace function public.operational_program_integration_save_uat_v1(
  p_base_url text,p_launch_path_template text default '/sessions/new?eventId={eventId}',p_active boolean default true
) returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare v_actor uuid:=auth.uid(); v_row public.business_app_integrations_v1%rowtype;
begin
  if v_actor is null or not(public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if trim(coalesce(p_base_url,'')) !~ '^https?://' then raise exception 'INVALID_INTEGRATION_URL'; end if;
  if position('{eventId}' in coalesce(p_launch_path_template,''))=0 then raise exception 'EVENT_ID_PLACEHOLDER_REQUIRED'; end if;
  update public.business_app_integrations_v1 set base_url=rtrim(trim(p_base_url),'/'),
    launch_path_template=trim(p_launch_path_template),active=p_active,
    connection_status=case when p_active then 'CONFIGURED' else 'DISCONNECTED' end,
    updated_by=v_actor,updated_at=now() where product_code='INVETORY_PRO' returning * into v_row;
  return jsonb_build_object('id',v_row.id,'status',v_row.connection_status,'active',v_row.active,'baseUrl',v_row.base_url);
end;
$$;

create or replace function public.operational_program_inventory_ack_uat_v1(
  p_event_id uuid,p_external_session_id text,p_external_session_url text,p_status text default 'READY',p_error text default null
) returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare v_actor uuid:=auth.uid(); v_status text:=upper(trim(p_status));
begin
  if not public.operational_program_can_manage_uat_v1() then raise exception 'FORBIDDEN'; end if;
  if v_status not in('READY','ERROR','COMPLETED') then raise exception 'INVALID_SYNC_STATUS'; end if;
  update public.operational_program_inventory_links_v1 set
    external_session_id=nullif(trim(p_external_session_id),''),
    external_session_url=coalesce(nullif(trim(p_external_session_url),''),external_session_url),
    sync_status=v_status,last_error=nullif(trim(p_error),''),attempt_count=attempt_count+1,
    last_attempt_at=now(),synced_at=case when v_status in('READY','COMPLETED') then now() else synced_at end,
    updated_at=now() where event_id=p_event_id;
  if not found then raise exception 'INVENTORY_LINK_NOT_FOUND'; end if;
  insert into public.operational_program_audit_v1(event_id,actor_id,action,detail)
    values(p_event_id,v_actor,'INVENTORY_SYNC',jsonb_build_object('status',v_status,'externalSessionId',p_external_session_id,'error',p_error));
  return jsonb_build_object('eventId',p_event_id,'status',v_status);
end;
$$;

revoke all on function public.operational_program_can_manage_uat_v1(),
  public.operational_program_preview_uat_v1(date,timestamptz,timestamptz,uuid,uuid[],uuid[],uuid[],integer),
  public.operational_program_workspace_uat_v1(date),
  public.operational_program_save_uat_v1(jsonb,jsonb,jsonb,uuid[]),
  public.operational_program_cancel_uat_v1(uuid,text),
  public.operational_program_integration_save_uat_v1(text,text,boolean),
  public.operational_program_inventory_ack_uat_v1(uuid,text,text,text,text)
  from public,anon;
grant execute on function public.operational_program_can_manage_uat_v1(),
  public.operational_program_preview_uat_v1(date,timestamptz,timestamptz,uuid,uuid[],uuid[],uuid[],integer),
  public.operational_program_workspace_uat_v1(date),
  public.operational_program_save_uat_v1(jsonb,jsonb,jsonb,uuid[]),
  public.operational_program_cancel_uat_v1(uuid,text),
  public.operational_program_integration_save_uat_v1(text,text,boolean),
  public.operational_program_inventory_ack_uat_v1(uuid,text,text,text,text)
  to authenticated;

comment on table public.operational_program_events_v1 is
  'Versioned operational events planned after schedule publication; GRAFIK PRO is the source of people, time and notifications.';
comment on table public.operational_program_inventory_links_v1 is
  'Idempotent INVETORY PRO integration outbox and deep-link state; stock results remain owned by INVETORY PRO.';
notify pgrst,'reload schema';
