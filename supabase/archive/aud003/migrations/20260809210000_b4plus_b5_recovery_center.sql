-- B4 Plus B5: one auditable recovery workflow for structural shortages,
-- post-publication incidents, offers, ad-hoc workers and temporary overrides.
-- UAT only: nhthrtpkfpmufmrmdyjg.

-- B4F-13: the persisted Matrix colour is the canonical source for every view
-- and for workbook round-trips.  Give existing UAT rows distinct, stable values.
do $$
declare v_owner uuid;
begin
  select permission.auth_user_id into v_owner
  from public.user_permissions permission
  where permission.app_role='OWNER'
  order by permission.auth_user_id limit 1;
  if v_owner is null then raise exception 'B4_B5_OWNER_REQUIRED'; end if;
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  perform public.matrix_v2_create_draft('B4+B5 — trwałe kolory i centrum napraw');
end;
$$;

with palette(ordinal, colour) as (values
  (1,'#6D4BEF'),(2,'#168A80'),(3,'#D14D72'),(4,'#C08A13'),
  (5,'#2879BD'),(6,'#8B5A2B'),(7,'#8052A6'),(8,'#2D7D5E')
), ranked as (
  select role.id, row_number() over(partition by role.matrix_version_id order by role.sort_order,role.code,role.id) ordinal
  from public.matrix_roles_v2 role
  join public.matrix_versions version on version.id=role.matrix_version_id and version.status='DRAFT'
)
update public.matrix_roles_v2 role
set color=palette.colour,updated_at=now()
from ranked join palette on palette.ordinal=((ranked.ordinal-1)%8)+1
where role.id=ranked.id and role.color is distinct from palette.colour;

with palette(ordinal, colour) as (values
  (1,'#756135'),(2,'#2F6F69'),(3,'#7A4E88'),(4,'#8A5135'),
  (5,'#3F5F8A'),(6,'#A04D68'),(7,'#497A3D'),(8,'#8B681F')
), ranked as (
  select duty.id, row_number() over(partition by duty.matrix_version_id order by duty.sort_order,duty.code,duty.id) ordinal
  from public.matrix_duties_v2 duty
  join public.matrix_versions version on version.id=duty.matrix_version_id and version.status='DRAFT'
)
update public.matrix_duties_v2 duty
set color=palette.colour,updated_at=now()
from ranked join palette on palette.ordinal=((ranked.ordinal-1)%8)+1
where duty.id=ranked.id and duty.color is distinct from palette.colour;

do $$
declare v_owner uuid;
begin
  select permission.auth_user_id into v_owner
  from public.user_permissions permission
  where permission.app_role='OWNER'
  order by permission.auth_user_id limit 1;
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  perform public.matrix_v2_publish_draft(current_date);
end;
$$;

create table if not exists public.recovery_month_revisions_v2 (
  month date primary key check(date_trunc('month',month)::date=month),
  revision integer not null default 0 check(revision>=0),
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);

create table if not exists public.recovery_incidents_v2 (
  id uuid primary key default gen_random_uuid(),
  month date not null check(date_trunc('month',month)::date=month),
  schedule_id uuid references public.published_schedules_v2(id),
  employee_id uuid references public.employees(id),
  role_id uuid references public.matrix_roles_v2(id),
  location_id uuid references public.matrix_locations_v2(id),
  incident_type text not null check(incident_type in (
    'SICKNESS','LEAVE','DEPARTURE','CONTRACT_WITHDRAWAL','STRUCTURAL_SHORTAGE','OTHER'
  )),
  starts_on date not null,
  ends_on date not null,
  status text not null default 'DRAFT' check(status in (
    'DRAFT','PROPOSED','OFFERING','READY','APPLIED','CANCELLED'
  )),
  repair_mode text not null default 'PROPOSE' check(repair_mode in (
    'PROPOSE','SEND_OFFERS','AUTO_DRAFT'
  )),
  contract_type_snapshot text,
  title text not null,
  notes text,
  base_revision integer not null,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_by uuid not null references auth.users(id),
  updated_at timestamptz not null default now(),
  check(ends_on>=starts_on),
  check(starts_on>=month and starts_on<(month+interval '1 month')::date),
  check(ends_on>=month and ends_on<(month+interval '1 month')::date)
);

create table if not exists public.recovery_actions_v2 (
  id uuid primary key default gen_random_uuid(),
  incident_id uuid not null references public.recovery_incidents_v2(id) on delete cascade,
  shift_id uuid references public.plan_shifts_v2(id),
  source_assignment_id uuid references public.plan_assignments_v2(id),
  source_issue_id bigint references public.plan_issues_v2(id),
  draft_variant_id uuid references public.plan_variants_v2(id),
  role_id uuid references public.matrix_roles_v2(id),
  duty_id uuid references public.matrix_duties_v2(id),
  action_type text not null check(action_type in (
    'REPLACE_ASSIGNMENT','FILL_SHORTAGE','ACTIVATE_STANDBY','SPLIT_SHIFT',
    'MOVE_LOCATION','REDUCE_STAFFING','SHORTEN_HOURS','AD_HOC_ASSIGNMENT'
  )),
  status text not null default 'PROPOSED' check(status in (
    'PROPOSED','OFFERED','ACCEPTED','REJECTED','DRAFT_READY','APPLIED','CANCELLED'
  )),
  selected_employee_id uuid references public.employees(id),
  candidate_snapshot jsonb not null default '[]'::jsonb,
  risk_level text not null default 'LOW' check(risk_level in ('LOW','MEDIUM','HIGH','CRITICAL')),
  rule_warnings jsonb not null default '[]'::jsonb,
  estimated_cost_delta_minor bigint,
  currency text,
  version integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.recovery_offer_responses_v2 (
  id uuid primary key default gen_random_uuid(),
  action_id uuid not null references public.recovery_actions_v2(id) on delete cascade,
  employee_id uuid not null references public.employees(id),
  status text not null default 'PENDING' check(status in ('PENDING','ACCEPTED','REJECTED','EXPIRED','WITHDRAWN')),
  offered_rate_minor bigint,
  currency text,
  message text,
  offered_at timestamptz not null default now(),
  responded_at timestamptz,
  unique(action_id,employee_id)
);

create table if not exists public.recovery_ad_hoc_pool_v2 (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid references public.employees(id),
  display_name text not null,
  email text,
  phone text,
  role_id uuid not null references public.matrix_roles_v2(id),
  contract_type text not null default 'ZLECENIE'
    check(contract_type in ('UMOWA_O_PRACE','CZESC_ETATU','ZLECENIE','B2B','INNE')),
  base_rate_minor bigint,
  currency text not null default 'PLN',
  available_from date,
  available_to date,
  active boolean not null default true,
  notes text,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(available_to is null or available_from is null or available_to>=available_from)
);

create table if not exists public.recovery_overrides_v2 (
  id uuid primary key default gen_random_uuid(),
  incident_id uuid not null references public.recovery_incidents_v2(id) on delete cascade,
  override_type text not null check(override_type in (
    'BUDGET_DELTA','WEEKLY_LIMIT','MONTHLY_LIMIT','STAFFING_MINIMUM','OPERATING_HOURS'
  )),
  employee_id uuid references public.employees(id),
  role_id uuid references public.matrix_roles_v2(id),
  starts_on date not null,
  ends_on date not null,
  numeric_value bigint not null,
  currency text,
  justification text not null check(length(trim(justification))>=10),
  employee_acknowledged boolean not null default false,
  compliance_confirmed boolean not null default false,
  status text not null default 'DRAFT' check(status in ('DRAFT','APPROVED','EXPIRED','CANCELLED')),
  approved_by uuid references auth.users(id),
  approved_at timestamptz,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  check(ends_on>=starts_on)
);

create index if not exists recovery_incidents_month_status_v2 on public.recovery_incidents_v2(month,status,starts_on);
create index if not exists recovery_actions_incident_status_v2 on public.recovery_actions_v2(incident_id,status);
create index if not exists recovery_offers_employee_status_v2 on public.recovery_offer_responses_v2(employee_id,status,offered_at desc);
create index if not exists recovery_ad_hoc_role_active_v2 on public.recovery_ad_hoc_pool_v2(role_id,active);

alter table public.recovery_month_revisions_v2 enable row level security;
alter table public.recovery_incidents_v2 enable row level security;
alter table public.recovery_actions_v2 enable row level security;
alter table public.recovery_offer_responses_v2 enable row level security;
alter table public.recovery_ad_hoc_pool_v2 enable row level security;
alter table public.recovery_overrides_v2 enable row level security;

create policy recovery_month_revisions_manage_v2 on public.recovery_month_revisions_v2
  for select to authenticated using((select public.can_manage_plans()));
create policy recovery_incidents_manage_v2 on public.recovery_incidents_v2
  for select to authenticated using((select public.can_manage_plans()));
create policy recovery_actions_manage_v2 on public.recovery_actions_v2
  for select to authenticated using((select public.can_manage_plans()));
create policy recovery_ad_hoc_manage_v2 on public.recovery_ad_hoc_pool_v2
  for select to authenticated using((select public.can_manage_plans()));
create policy recovery_overrides_manage_v2 on public.recovery_overrides_v2
  for select to authenticated using((select public.can_manage_plans()));
create policy recovery_offer_participant_v2 on public.recovery_offer_responses_v2
  for select to authenticated using(
    (select public.can_manage_plans()) or employee_id in (
      select employee.id from public.employees employee where employee.auth_user_id=(select auth.uid())
    )
  );

revoke all on public.recovery_month_revisions_v2,public.recovery_incidents_v2,
  public.recovery_actions_v2,public.recovery_offer_responses_v2,
  public.recovery_ad_hoc_pool_v2,public.recovery_overrides_v2
from public,anon,authenticated;
grant select on public.recovery_month_revisions_v2,public.recovery_incidents_v2,
  public.recovery_actions_v2,public.recovery_offer_responses_v2,
  public.recovery_ad_hoc_pool_v2,public.recovery_overrides_v2 to authenticated;
grant all on public.recovery_month_revisions_v2,public.recovery_incidents_v2,
  public.recovery_actions_v2,public.recovery_offer_responses_v2,
  public.recovery_ad_hoc_pool_v2,public.recovery_overrides_v2 to service_role;

create or replace function solver_private.recovery_can_manage_scope_uat_v1(
  p_role_id uuid,p_location_id uuid
)
returns boolean language sql stable security definer set search_path=''
as $$
  select auth.uid() is not null and (
    public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or exists(
      select 1 from public.matrix_scope_grants_v2 grant_row
      where grant_row.auth_user_id=auth.uid() and grant_row.active
        and (
          (grant_row.app_role='ROLE_MANAGER' and p_role_id is not null and grant_row.role_logical_id=(
            select role.logical_id from public.matrix_roles_v2 role where role.id=p_role_id
          ))
          or
          (grant_row.app_role='LOCATION_MANAGER' and p_location_id is not null and grant_row.location_logical_id=(
            select location.logical_id from public.matrix_locations_v2 location where location.id=p_location_id
          ))
        )
    )
  )
$$;

create or replace function solver_private.recovery_can_manage_role_uat_v1(p_role_id uuid)
returns boolean language sql stable security definer set search_path=''
as $$ select solver_private.recovery_can_manage_scope_uat_v1(p_role_id,null) $$;

create or replace function solver_private.recovery_published_variants_uat_v1(p_month date)
returns table(variant_id uuid)
language sql stable security definer set search_path=''
as $$
  with latest_company as (
    select schedule.id from public.published_schedules_v2 schedule
    where schedule.month=date_trunc('month',p_month)::date and schedule.status='PUBLISHED'
    order by schedule.published_at desc limit 1
  )
  select link.variant_id from latest_company
    join public.published_schedule_variants_v2 link on link.schedule_id=latest_company.id
  union all
  select publication.variant_id from public.published_role_schedules_v2 publication
  where not exists(select 1 from latest_company)
    and publication.month=date_trunc('month',p_month)::date
    and publication.status='PUBLISHED'
$$;

create or replace function solver_private.recovery_candidate_snapshot_uat_v1(
  p_month date,p_shift_id uuid,p_role_id uuid,p_duty_id uuid,p_excluded_employee_id uuid
) returns jsonb language sql stable security definer set search_path=''
as $$
  with target as (
    select shift.*,role.matrix_version_id
    from public.plan_shifts_v2 shift
    join public.matrix_roles_v2 role on role.id=p_role_id
    where shift.id=p_shift_id
  ), candidates as (
    select profile.employee_id,profile.employee_no,
      trim(concat(profile.first_name,' ',profile.last_name)) name,
      profile.nominal_monthly_minutes,profile.maximum_monthly_minutes,profile.maximum_weekly_minutes,
      coalesce(standby.tier,10) priority,standby.tier,
      standby.id is not null standby_candidate,
      exists(select 1 from public.matrix_employee_locations_v2 location_grant,target
        where location_grant.matrix_version_id=profile.matrix_version_id
          and location_grant.employee_id=profile.employee_id
          and location_grant.location_id=target.location_id and location_grant.active
          and location_grant.standard_allowed) location_ok,
      (p_duty_id is null or exists(select 1 from public.matrix_employee_duties_v2 duty_grant
        where duty_grant.matrix_version_id=profile.matrix_version_id
          and duty_grant.employee_id=profile.employee_id and duty_grant.duty_id=p_duty_id
          and duty_grant.active)) duty_ok,
      exists(select 1 from public.employee_time_constraints_v2 constraint_row,target
        where constraint_row.employee_id=profile.employee_id and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
          and constraint_row.time_range && tstzrange(target.starts_at,target.ends_at,'[)')) hard_blocked,
      exists(select 1 from public.plan_assignments_v2 existing
        join public.plan_shifts_v2 existing_shift on existing_shift.id=existing.shift_id
        join solver_private.recovery_published_variants_uat_v1(p_month) published on published.variant_id=existing.variant_id
        cross join target where existing.employee_id=profile.employee_id
          and tstzrange(existing_shift.starts_at,existing_shift.ends_at,'[)') && tstzrange(target.starts_at,target.ends_at,'[)')) has_overlap,
      coalesce((select sum(extract(epoch from (existing_shift.ends_at-existing_shift.starts_at))/60)::integer
        from public.plan_assignments_v2 existing join public.plan_shifts_v2 existing_shift on existing_shift.id=existing.shift_id
        join solver_private.recovery_published_variants_uat_v1(p_month) published on published.variant_id=existing.variant_id
        where existing.employee_id=profile.employee_id),0) month_minutes,
      coalesce((select sum(extract(epoch from (existing_shift.ends_at-existing_shift.starts_at))/60)::integer
        from public.plan_assignments_v2 existing join public.plan_shifts_v2 existing_shift on existing_shift.id=existing.shift_id
        join solver_private.recovery_published_variants_uat_v1(p_month) published on published.variant_id=existing.variant_id
        cross join target where existing.employee_id=profile.employee_id
          and extract(isoyear from existing_shift.shift_date)=extract(isoyear from target.shift_date)
          and extract(week from existing_shift.shift_date)=extract(week from target.shift_date)),0) week_minutes,
      coalesce((select rate.contract_type from public.employee_pay_rates_v2 rate,target
        where rate.employee_id=profile.employee_id and rate.active and rate.valid_from<=target.shift_date
          and (rate.valid_to is null or rate.valid_to>=target.shift_date)
        order by rate.valid_from desc limit 1),
        (select hr.contract_type from public.employee_hr_profiles hr
          where hr.employee_id=profile.employee_id),'INNE') contract_type
    from public.matrix_employee_profiles_v2 profile
    cross join target
    join public.matrix_employee_roles_v2 role_grant on role_grant.matrix_version_id=profile.matrix_version_id
      and role_grant.employee_id=profile.employee_id and role_grant.role_id=p_role_id and role_grant.active
    left join public.published_standby_assignments_v2 standby on standby.month=date_trunc('month',p_month)::date
      and standby.standby_date=target.shift_date and standby.role_id=p_role_id
      and standby.employee_id=profile.employee_id and standby.status='PLANNED'
    where profile.matrix_version_id=target.matrix_version_id and profile.active and profile.archived_at is null
      and (profile.employment_start is null or profile.employment_start<=target.shift_date)
      and (profile.employment_end is null or profile.employment_end>=target.shift_date)
      and profile.employee_id is distinct from p_excluded_employee_id
  ), evaluated as (
    select *,location_ok and duty_ok and not hard_blocked and not has_overlap eligible,
      to_jsonb(array_remove(array[
        case when not location_ok then 'Brak uprawnienia do lokalu' end,
        case when not duty_ok then 'Brak wymaganego obowiązku' end,
        case when hard_blocked then 'Twarda niedostępność, urlop lub L4' end,
        case when has_overlap then 'Ma już zmianę w tym czasie' end,
        case when maximum_weekly_minutes>0 and week_minutes>=maximum_weekly_minutes then
          case when contract_type in ('UMOWA_O_PRACE','CZESC_ETATU')
            then 'Osiągnięty limit tygodniowy UoP — wymaga zgody pracownika, potwierdzenia właściciela i kontroli zgodności czasu pracy'
            else 'Osiągnięty uzgodniony limit tygodniowy — wymaga świadomego wyjątku' end end,
        case when maximum_monthly_minutes>0 and month_minutes>=maximum_monthly_minutes then
          case when contract_type in ('UMOWA_O_PRACE','CZESC_ETATU')
            then 'Osiągnięty limit miesięczny UoP — wymaga zgody pracownika, potwierdzenia właściciela i kontroli zgodności czasu pracy'
            else 'Osiągnięty uzgodniony limit miesięczny — wymaga świadomego wyjątku' end end
      ]::text[],null)) reasons
    from candidates
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'employeeId',employee_id,'employeeNo',employee_no,'name',name,
    'source',case when standby_candidate then 'STANDBY' else 'ACTIVE_TEAM' end,
    'tier',tier,'priority',case when eligible then priority else 50 end,'eligible',eligible,
    'locationOk',location_ok,'dutyOk',duty_ok,'hardBlocked',hard_blocked,'overlaps',has_overlap,
    'reasons',reasons,'contractType',contract_type,
    'monthMinutes',month_minutes,'weekMinutes',week_minutes,
    'nominalMonthlyMinutes',nominal_monthly_minutes,'maximumMonthlyMinutes',maximum_monthly_minutes,
    'maximumWeeklyMinutes',maximum_weekly_minutes
  ) order by eligible desc,case when standby_candidate then tier else 10 end,
    abs(nominal_monthly_minutes-month_minutes),name),'[]'::jsonb)
  from (select * from evaluated order by eligible desc,priority,name limit 24) ranked
$$;

create or replace function public.recovery_center_workspace_uat_v1(p_month date)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare
  v_month date:=date_trunc('month',p_month)::date;
  v_revision integer;
  v_schedule jsonb;
  v_shortages jsonb;
  v_incidents jsonb;
  v_ad_hoc jsonb;
  v_budget jsonb;
  v_scopes jsonb;
  v_location_scopes jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  select coalesce(revision,0) into v_revision from public.recovery_month_revisions_v2 where month=v_month;
  select coalesce(jsonb_build_object('id',schedule.id,'name',schedule.name,'status',schedule.status,
    'publishedAt',schedule.published_at,'validation',schedule.validation_summary),'null'::jsonb)
  into v_schedule from public.published_schedules_v2 schedule
  where schedule.month=v_month and schedule.status='PUBLISHED'
  order by schedule.published_at desc limit 1;

  with published as (select variant_id from solver_private.recovery_published_variants_uat_v1(v_month)),
  gaps as (
    select issue.role_id,shift.location_id,shift.shift_date,
      to_char(shift.starts_at at time zone coalesce(location.timezone,'Europe/Warsaw'),'HH24:MI') starts_at,
      to_char(shift.ends_at at time zone coalesce(location.timezone,'Europe/Warsaw'),'HH24:MI') ends_at,
      greatest(coalesce(issue.required_count,0)-coalesce(issue.assigned_count,0),0) missing,
      extract(epoch from (shift.ends_at-shift.starts_at))/60 duration_minutes,
      role.name role_name,role.color role_color,location.name location_name
    from published join public.plan_issues_v2 issue on issue.variant_id=published.variant_id
    join public.plan_shifts_v2 shift on shift.id=issue.shift_id
    join public.matrix_roles_v2 role on role.id=issue.role_id
    join public.matrix_locations_v2 location on location.id=shift.location_id
    where issue.issue_code='UNFILLED_SLOT'
      and greatest(coalesce(issue.required_count,0)-coalesce(issue.assigned_count,0),0)>0
      and solver_private.recovery_can_manage_scope_uat_v1(issue.role_id,shift.location_id)
  ), grouped as (
    select role_id,location_id,starts_at,ends_at,min(role_name) role_name,min(role_color) role_color,
      min(location_name) location_name,count(distinct shift_date) affected_days,
      min(shift_date) first_date,max(shift_date) last_date,sum(missing) missing_slots,
      round(sum(missing*duration_minutes)/60.0,1) missing_hours,
      array_agg(distinct shift_date order by shift_date) dates
    from gaps group by role_id,location_id,starts_at,ends_at
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'roleId',role_id,'roleName',role_name,'roleColor',role_color,'locationId',location_id,
    'locationName',location_name,'startsAt',starts_at,'endsAt',ends_at,
    'affectedDays',affected_days,'firstDate',first_date,'lastDate',last_date,
    'missingSlots',missing_slots,'missingHours',missing_hours,'dates',to_jsonb(dates),
    'structural',affected_days>=2,
    'actions',jsonb_build_array('Dodatkowa osoba lub pula ad-hoc','Zwiększenie wymiaru za zgodą',
      'Przeniesienie między lokalami','Zmiana minimum obsady lub godzin działalności')
  ) order by missing_hours desc),'[]'::jsonb) into v_shortages from grouped;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',incident.id,'type',incident.incident_type,'title',incident.title,'status',incident.status,
    'mode',incident.repair_mode,'startsOn',incident.starts_on,'endsOn',incident.ends_on,
    'employeeId',incident.employee_id,'employeeName',trim(concat(employee.first_name,' ',employee.last_name)),
    'roleId',incident.role_id,'roleName',role.name,'roleColor',role.color,
    'locationId',incident.location_id,'locationName',incident_location.name,'notes',incident.notes,
    'baseRevision',incident.base_revision,'updatedAt',incident.updated_at,
    'actionCount',(select count(*) from public.recovery_actions_v2 action where action.incident_id=incident.id),
    'offerCount',(select count(*) from public.recovery_offer_responses_v2 response join public.recovery_actions_v2 action on action.id=response.action_id where action.incident_id=incident.id)
  ) order by incident.created_at desc),'[]'::jsonb) into v_incidents
  from public.recovery_incidents_v2 incident
  left join public.employees employee on employee.id=incident.employee_id
  left join public.matrix_roles_v2 role on role.id=incident.role_id
  left join public.matrix_locations_v2 incident_location on incident_location.id=incident.location_id
  where incident.month=v_month
    and solver_private.recovery_can_manage_scope_uat_v1(incident.role_id,incident.location_id);

  select coalesce(jsonb_agg(jsonb_build_object('id',pool.id,'employeeId',pool.employee_id,
    'name',pool.display_name,'email',pool.email,'phone',pool.phone,'roleId',pool.role_id,
    'roleName',role.name,'roleColor',role.color,'contractType',pool.contract_type,
    'rateMinor',pool.base_rate_minor,'currency',pool.currency,'availableFrom',pool.available_from,
    'availableTo',pool.available_to,'active',pool.active,'notes',pool.notes)
    order by role.name,pool.display_name),'[]'::jsonb) into v_ad_hoc
  from public.recovery_ad_hoc_pool_v2 pool join public.matrix_roles_v2 role on role.id=pool.role_id
  where pool.active and (pool.available_from is null or pool.available_from<(v_month+interval '1 month')::date)
    and (pool.available_to is null or pool.available_to>=v_month)
    and solver_private.recovery_can_manage_scope_uat_v1(pool.role_id,null);

  select coalesce(jsonb_build_object('amount',budget.amount,'warningPercent',budget.warning_percent,
    'hardLimit',budget.hard_limit,'updatedAt',budget.updated_at),
    jsonb_build_object('amount',0,'warningPercent',90,'hardLimit',false))
  into v_budget from public.monthly_budgets budget where budget.month=v_month;

  select coalesce(jsonb_agg(jsonb_build_object('roleId',role.id,'roleName',role.name,'roleColor',role.color,
    'canManage',solver_private.recovery_can_manage_role_uat_v1(role.id)) order by role.sort_order),'[]'::jsonb)
  into v_scopes from public.matrix_roles_v2 role join public.matrix_versions matrix on matrix.id=role.matrix_version_id
  where matrix.status='ACTIVE' and role.active;

  select coalesce(jsonb_agg(jsonb_build_object('locationId',location.id,'locationName',location.name,
    'canManage',solver_private.recovery_can_manage_scope_uat_v1(null,location.id)) order by location.sort_order),'[]'::jsonb)
  into v_location_scopes from public.matrix_locations_v2 location
  join public.matrix_versions matrix on matrix.id=location.matrix_version_id
  where matrix.status='ACTIVE' and location.active;

  return jsonb_build_object('month',v_month,'revision',coalesce(v_revision,0),'schedule',v_schedule,
    'shortages',coalesce(v_shortages,'[]'::jsonb),'incidents',coalesce(v_incidents,'[]'::jsonb),
    'adHocPool',coalesce(v_ad_hoc,'[]'::jsonb),'budget',v_budget,
    'roleScopes',coalesce(v_scopes,'[]'::jsonb),'locationScopes',coalesce(v_location_scopes,'[]'::jsonb));
end;
$$;

create or replace function public.optimizer_role_colours_uat_v1(p_month date)
returns jsonb language sql stable security definer set search_path=''
as $$
  with matrix as (
    select matrix_version.id
    from public.matrix_versions matrix_version
    where matrix_version.status in ('ACTIVE','ARCHIVED') and matrix_version.schema_version>=2
      and matrix_version.effective_from<=date_trunc('month',p_month)::date
      and coalesce(matrix_version.content_hash,'') ~ '^[0-9a-f]{64}$'
      and coalesce(matrix_version.workforce_hash,'') ~ '^[0-9a-f]{64}$'
    order by matrix_version.effective_from desc,matrix_version.version desc limit 1
  )
  select jsonb_build_object('roles',coalesce(jsonb_agg(jsonb_build_object(
    'id',role.id,'logicalId',role.logical_id,'code',role.code,'name',role.name,'color',role.color
  ) order by role.sort_order,role.name),'[]'::jsonb))
  from matrix join public.matrix_roles_v2 role on role.matrix_version_id=matrix.id and role.active
  where auth.uid() is not null
$$;

create or replace function public.recovery_incident_save_uat_v1(
  p_month date,p_expected_revision integer,p_incident_id uuid,p_employee_id uuid,p_role_id uuid,p_location_id uuid,
  p_incident_type text,p_starts_on date,p_ends_on date,p_title text,p_notes text,p_mode text
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid:=auth.uid(); v_month date:=date_trunc('month',p_month)::date;
  v_revision integer; v_id uuid:=coalesce(p_incident_id,gen_random_uuid()); v_contract text;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  if not solver_private.recovery_can_manage_scope_uat_v1(p_role_id,p_location_id) then raise exception 'ROLE_OR_LOCATION_SCOPE_FORBIDDEN'; end if;
  if p_starts_on is null or p_ends_on is null or p_ends_on<p_starts_on
    or p_starts_on<v_month or p_ends_on>=(v_month+interval '1 month')::date then raise exception 'INVALID_INCIDENT_RANGE'; end if;
  if length(trim(coalesce(p_title,'')))<3 then raise exception 'INCIDENT_TITLE_REQUIRED'; end if;
  perform pg_advisory_xact_lock(hashtextextended('recovery:'||v_month::text,0));
  insert into public.recovery_month_revisions_v2(month,revision,updated_by)
    values(v_month,0,v_actor) on conflict(month) do nothing;
  select revision into v_revision from public.recovery_month_revisions_v2 where month=v_month for update;
  if v_revision<>coalesce(p_expected_revision,-1) then raise exception 'RECOVERY_REVISION_CONFLICT expected %, actual %',p_expected_revision,v_revision; end if;
  select rate.contract_type into v_contract from public.employee_pay_rates_v2 rate
    where rate.employee_id=p_employee_id and rate.active and rate.valid_from<=p_starts_on
      and (rate.valid_to is null or rate.valid_to>=p_starts_on) order by rate.valid_from desc limit 1;
  insert into public.recovery_incidents_v2(id,month,schedule_id,employee_id,role_id,location_id,incident_type,
    starts_on,ends_on,status,repair_mode,contract_type_snapshot,title,notes,base_revision,created_by,updated_by)
  values(v_id,v_month,(select id from public.published_schedules_v2 where month=v_month and status='PUBLISHED' order by published_at desc limit 1),
    p_employee_id,p_role_id,p_location_id,p_incident_type,p_starts_on,p_ends_on,'PROPOSED',p_mode,v_contract,trim(p_title),nullif(trim(coalesce(p_notes,'')),''),v_revision,v_actor,v_actor)
  on conflict(id) do update set employee_id=excluded.employee_id,role_id=excluded.role_id,location_id=excluded.location_id,
    incident_type=excluded.incident_type,starts_on=excluded.starts_on,ends_on=excluded.ends_on,
    repair_mode=excluded.repair_mode,title=excluded.title,notes=excluded.notes,
    contract_type_snapshot=excluded.contract_type_snapshot,updated_by=v_actor,updated_at=now();
  update public.recovery_month_revisions_v2 set revision=revision+1,updated_by=v_actor,updated_at=now() where month=v_month returning revision into v_revision;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'recovery_incident_v2',v_id::text,'RECOVERY_INCIDENT_SAVED',jsonb_build_object('month',v_month,'revision',v_revision,'mode',p_mode));
  return jsonb_build_object('saved',true,'id',v_id,'revision',v_revision);
end;
$$;

create or replace function public.recovery_incident_prepare_uat_v1(
  p_incident_id uuid,p_expected_revision integer,p_mode text
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid:=auth.uid(); v_incident public.recovery_incidents_v2%rowtype;
  v_revision integer; v_actions integer:=0; v_offers integer:=0;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  select * into v_incident from public.recovery_incidents_v2 where id=p_incident_id for update;
  if v_incident.id is null then raise exception 'INCIDENT_NOT_FOUND'; end if;
  if p_mode not in ('PROPOSE','SEND_OFFERS','AUTO_DRAFT') then raise exception 'INVALID_RECOVERY_MODE'; end if;
  if not solver_private.recovery_can_manage_scope_uat_v1(v_incident.role_id,v_incident.location_id) then raise exception 'ROLE_OR_LOCATION_SCOPE_FORBIDDEN'; end if;
  perform pg_advisory_xact_lock(hashtextextended('recovery:'||v_incident.month::text,0));
  select revision into v_revision from public.recovery_month_revisions_v2 where month=v_incident.month for update;
  if v_revision<>p_expected_revision then raise exception 'RECOVERY_REVISION_CONFLICT expected %, actual %',p_expected_revision,v_revision; end if;
  delete from public.recovery_actions_v2 where incident_id=v_incident.id and status in ('PROPOSED','OFFERED','DRAFT_READY');

  insert into public.recovery_actions_v2(incident_id,shift_id,source_assignment_id,role_id,duty_id,action_type,status,
    candidate_snapshot,risk_level,rule_warnings,currency)
  select v_incident.id,shift.id,assignment.id,assignment.role_id,
    (select duty.duty_id from public.plan_assignment_duties_v2 duty where duty.assignment_id=assignment.id order by duty.duty_id limit 1),
    'REPLACE_ASSIGNMENT',
    case when p_mode='SEND_OFFERS' then 'OFFERED' when p_mode='AUTO_DRAFT' then 'DRAFT_READY' else 'PROPOSED' end,
    solver_private.recovery_candidate_snapshot_uat_v1(v_incident.month,shift.id,assignment.role_id,
      (select duty.duty_id from public.plan_assignment_duties_v2 duty where duty.assignment_id=assignment.id order by duty.duty_id limit 1),
      assignment.employee_id),
    'MEDIUM',jsonb_build_array(jsonb_build_object('code','FINAL_SERVER_VALIDATION_REQUIRED','message','Przed publikacją serwer ponownie sprawdzi cały miesiąc, odpoczynek, limity i obowiązki.')),
    coalesce((select rate.currency from public.employee_pay_rates_v2 rate where rate.employee_id=assignment.employee_id and rate.active order by rate.valid_from desc limit 1),'PLN')
  from solver_private.recovery_published_variants_uat_v1(v_incident.month) published
  join public.plan_assignments_v2 assignment on assignment.variant_id=published.variant_id
  join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
  where v_incident.employee_id is not null and assignment.employee_id=v_incident.employee_id
    and shift.shift_date between v_incident.starts_on and v_incident.ends_on;
  get diagnostics v_actions=row_count;

  if v_incident.employee_id is null then
    insert into public.recovery_actions_v2(incident_id,shift_id,source_issue_id,role_id,duty_id,action_type,status,
      candidate_snapshot,risk_level,rule_warnings,currency)
    select v_incident.id,shift.id,issue.id,issue.role_id,issue.duty_id,'FILL_SHORTAGE',
      case when p_mode='SEND_OFFERS' then 'OFFERED' when p_mode='AUTO_DRAFT' then 'DRAFT_READY' else 'PROPOSED' end,
      solver_private.recovery_candidate_snapshot_uat_v1(v_incident.month,shift.id,issue.role_id,issue.duty_id,null),
      case when coalesce(issue.assigned_count,0)=0 then 'CRITICAL' else 'HIGH' end,
      jsonb_build_array(jsonb_build_object('code','PUBLISHED_SHORTAGE','message',
        case when coalesce(issue.assigned_count,0)=0
          then 'Na tej zmianie nie ma ani jednej osoby w wymaganej roli. Publikacja wymaga jawnej decyzji właściciela.'
          else 'Grafik pozostaje niekompletny. Każda propozycja przejdzie końcową kontrolę całego miesiąca.' end)),
      'PLN'
    from solver_private.recovery_published_variants_uat_v1(v_incident.month) published
    join public.plan_issues_v2 issue on issue.variant_id=published.variant_id and issue.issue_code='UNFILLED_SLOT'
    join public.plan_shifts_v2 shift on shift.id=issue.shift_id
    cross join lateral generate_series(1,greatest(coalesce(issue.required_count,0)-coalesce(issue.assigned_count,0),0)) missing_slot
    where shift.shift_date between v_incident.starts_on and v_incident.ends_on
      and (v_incident.role_id is null or issue.role_id=v_incident.role_id)
      and (v_incident.location_id is null or shift.location_id=v_incident.location_id)
      and solver_private.recovery_can_manage_scope_uat_v1(issue.role_id,shift.location_id);
    get diagnostics v_actions=row_count;
  end if;

  if p_mode='AUTO_DRAFT' then
    update public.recovery_actions_v2 action
    set selected_employee_id=(select (candidate->>'employeeId')::uuid
        from jsonb_array_elements(action.candidate_snapshot) candidate
        where coalesce((candidate->>'eligible')::boolean,false)
        order by (candidate->>'priority')::integer,candidate->>'name' limit 1),
      updated_at=now()
    where action.incident_id=v_incident.id and action.status='DRAFT_READY';
  end if;

  if p_mode='SEND_OFFERS' then
    insert into public.recovery_offer_responses_v2(action_id,employee_id,status,currency)
    select action.id,(candidate->>'employeeId')::uuid,'PENDING',action.currency
    from public.recovery_actions_v2 action cross join lateral jsonb_array_elements(action.candidate_snapshot) candidate
    where action.incident_id=v_incident.id and action.status='OFFERED'
      and coalesce((candidate->>'eligible')::boolean,false)
    on conflict(action_id,employee_id) do nothing;
    get diagnostics v_offers=row_count;
    insert into public.notifications(recipient_id,channel,title,body,sent_at)
    select employee.auth_user_id,'IN_APP','Propozycja dodatkowej zmiany',
      'Lider wysłał propozycję zastępstwa. Otwórz zakładkę Zamiany, aby odpowiedzieć.',now()
    from public.recovery_offer_responses_v2 response
    join public.employees employee on employee.id=response.employee_id
    join public.recovery_actions_v2 action on action.id=response.action_id
    where action.incident_id=v_incident.id and response.status='PENDING' and employee.auth_user_id is not null;
  end if;
  update public.recovery_incidents_v2 set status=case when p_mode='SEND_OFFERS' then 'OFFERING' else 'READY' end,
    repair_mode=p_mode,updated_by=v_actor,updated_at=now() where id=v_incident.id;
  update public.recovery_month_revisions_v2 set revision=revision+1,updated_by=v_actor,updated_at=now() where month=v_incident.month returning revision into v_revision;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'recovery_incident_v2',v_incident.id::text,'RECOVERY_PLAN_PREPARED',jsonb_build_object('mode',p_mode,'actions',v_actions,'offers',v_offers,'revision',v_revision));
  return jsonb_build_object('prepared',true,'actions',v_actions,'offers',v_offers,'revision',v_revision);
end;
$$;

create or replace function public.recovery_incident_detail_uat_v1(p_incident_id uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_incident public.recovery_incidents_v2%rowtype; v_actions jsonb; v_overrides jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  select * into v_incident from public.recovery_incidents_v2 where id=p_incident_id;
  if v_incident.id is null then raise exception 'INCIDENT_NOT_FOUND'; end if;
  if not solver_private.recovery_can_manage_scope_uat_v1(v_incident.role_id,v_incident.location_id) then raise exception 'ROLE_OR_LOCATION_SCOPE_FORBIDDEN'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',action.id,'type',action.action_type,'status',action.status,
    'shiftId',action.shift_id,'assignmentId',action.source_assignment_id,'issueId',action.source_issue_id,
    'draftVariantId',action.draft_variant_id,'selectedEmployeeId',action.selected_employee_id,
    'candidates',action.candidate_snapshot,'risk',action.risk_level,'warnings',action.rule_warnings,
    'costDeltaMinor',action.estimated_cost_delta_minor,'currency',action.currency,'version',action.version,
    'shiftDate',shift.shift_date,'startsAt',shift.starts_at,'endsAt',shift.ends_at,
    'locationName',location.name,'roleName',role.name,'roleColor',role.color)
    order by shift.shift_date,shift.starts_at),'[]'::jsonb) into v_actions
  from public.recovery_actions_v2 action left join public.plan_shifts_v2 shift on shift.id=action.shift_id
  left join public.matrix_locations_v2 location on location.id=shift.location_id
  left join public.plan_assignments_v2 assignment on assignment.id=action.source_assignment_id
  left join public.matrix_roles_v2 role on role.id=coalesce(action.role_id,assignment.role_id)
  where action.incident_id=v_incident.id;
  select coalesce(jsonb_agg(to_jsonb(override_row) order by override_row.starts_on),'[]'::jsonb) into v_overrides
  from public.recovery_overrides_v2 override_row where override_row.incident_id=v_incident.id;
  return jsonb_build_object('id',v_incident.id,'month',v_incident.month,'title',v_incident.title,
    'type',v_incident.incident_type,'status',v_incident.status,'mode',v_incident.repair_mode,
    'startsOn',v_incident.starts_on,'endsOn',v_incident.ends_on,'employeeId',v_incident.employee_id,
    'roleId',v_incident.role_id,'locationId',v_incident.location_id,
    'contractType',v_incident.contract_type_snapshot,'notes',v_incident.notes,
    'actions',coalesce(v_actions,'[]'::jsonb),'overrides',coalesce(v_overrides,'[]'::jsonb));
end;
$$;

create or replace function public.recovery_employee_offers_uat_v1(p_month date)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_employee uuid; v_rows jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select id into v_employee from public.employees where auth_user_id=auth.uid() and active limit 1;
  if v_employee is null then return jsonb_build_object('offers','[]'::jsonb); end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',response.id,'actionId',action.id,'incidentId',incident.id,
    'title',incident.title,'status',response.status,'rateMinor',response.offered_rate_minor,'currency',response.currency,
    'message',response.message,'offeredAt',response.offered_at,'shiftDate',shift.shift_date,
    'startsAt',shift.starts_at,'endsAt',shift.ends_at,'locationName',location.name,'roleName',role.name)
    order by shift.shift_date,shift.starts_at),'[]'::jsonb) into v_rows
  from public.recovery_offer_responses_v2 response
  join public.recovery_actions_v2 action on action.id=response.action_id
  join public.recovery_incidents_v2 incident on incident.id=action.incident_id
  left join public.plan_shifts_v2 shift on shift.id=action.shift_id
  left join public.matrix_locations_v2 location on location.id=shift.location_id
  left join public.plan_assignments_v2 assignment on assignment.id=action.source_assignment_id
  left join public.matrix_roles_v2 role on role.id=coalesce(action.role_id,assignment.role_id)
  where response.employee_id=v_employee and incident.month=date_trunc('month',p_month)::date;
  return jsonb_build_object('offers',coalesce(v_rows,'[]'::jsonb));
end;
$$;

create or replace function public.recovery_offer_respond_uat_v1(p_response_id uuid,p_accept boolean,p_message text)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_employee uuid; v_response public.recovery_offer_responses_v2%rowtype;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select id into v_employee from public.employees where auth_user_id=v_actor and active limit 1;
  select * into v_response from public.recovery_offer_responses_v2 where id=p_response_id for update;
  if v_response.id is null or v_response.employee_id<>v_employee then raise exception 'OFFER_FORBIDDEN'; end if;
  if v_response.status<>'PENDING' then raise exception 'OFFER_ALREADY_DECIDED'; end if;
  update public.recovery_offer_responses_v2 set status=case when p_accept then 'ACCEPTED' else 'REJECTED' end,
    message=nullif(trim(coalesce(p_message,'')),''),responded_at=now() where id=v_response.id;
  if p_accept then update public.recovery_actions_v2 set selected_employee_id=v_employee,status='ACCEPTED',version=version+1,updated_at=now() where id=v_response.action_id and status='OFFERED'; end if;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'recovery_offer_v2',v_response.id::text,case when p_accept then 'OFFER_ACCEPTED' else 'OFFER_REJECTED' end,jsonb_build_object('message',p_message));
  return jsonb_build_object('saved',true,'accepted',p_accept);
end;
$$;

create or replace function public.recovery_ad_hoc_save_uat_v1(
  p_id uuid,p_employee_id uuid,p_display_name text,p_email text,p_phone text,p_role_id uuid,
  p_contract_type text,p_rate_minor bigint,p_currency text,p_available_from date,p_available_to date,p_notes text
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_id uuid:=coalesce(p_id,gen_random_uuid());
  v_contract text:=upper(trim(coalesce(p_contract_type,'ZLECENIE')));
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not solver_private.recovery_can_manage_role_uat_v1(p_role_id) then raise exception 'ROLE_SCOPE_FORBIDDEN'; end if;
  if length(trim(coalesce(p_display_name,'')))<3 then raise exception 'AD_HOC_NAME_REQUIRED'; end if;
  if v_contract not in ('UMOWA_O_PRACE','CZESC_ETATU','ZLECENIE','B2B','INNE') then
    raise exception 'INVALID_CONTRACT_TYPE';
  end if;
  insert into public.recovery_ad_hoc_pool_v2(id,employee_id,display_name,email,phone,role_id,contract_type,
    base_rate_minor,currency,available_from,available_to,active,notes,created_by)
  values(v_id,p_employee_id,trim(p_display_name),nullif(trim(coalesce(p_email,'')),''),nullif(trim(coalesce(p_phone,'')),''),p_role_id,
    v_contract,p_rate_minor,coalesce(nullif(trim(p_currency),''),'PLN'),
    p_available_from,p_available_to,true,nullif(trim(coalesce(p_notes,'')),''),v_actor)
  on conflict(id) do update set employee_id=excluded.employee_id,display_name=excluded.display_name,email=excluded.email,
    phone=excluded.phone,role_id=excluded.role_id,contract_type=excluded.contract_type,base_rate_minor=excluded.base_rate_minor,
    currency=excluded.currency,available_from=excluded.available_from,available_to=excluded.available_to,notes=excluded.notes,updated_at=now();
  return jsonb_build_object('saved',true,'id',v_id);
end;
$$;

create or replace function public.recovery_override_save_uat_v1(
  p_incident_id uuid,p_override_type text,p_employee_id uuid,p_role_id uuid,p_starts_on date,p_ends_on date,
  p_numeric_value bigint,p_currency text,p_justification text,p_employee_acknowledged boolean,
  p_compliance_confirmed boolean
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_incident public.recovery_incidents_v2%rowtype; v_id uuid:=gen_random_uuid();
  v_contract text;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into v_incident from public.recovery_incidents_v2 where id=p_incident_id;
  if v_incident.id is null then raise exception 'INCIDENT_NOT_FOUND'; end if;
  if not solver_private.recovery_can_manage_scope_uat_v1(coalesce(p_role_id,v_incident.role_id),v_incident.location_id) then raise exception 'ROLE_OR_LOCATION_SCOPE_FORBIDDEN'; end if;
  if p_ends_on<p_starts_on or p_starts_on<v_incident.starts_on or p_ends_on>v_incident.ends_on
    or length(trim(coalesce(p_justification,'')))<10 then raise exception 'INVALID_OVERRIDE'; end if;
  if p_override_type in ('WEEKLY_LIMIT','MONTHLY_LIMIT') and not coalesce(p_employee_acknowledged,false)
    then raise exception 'EMPLOYEE_ACKNOWLEDGEMENT_REQUIRED'; end if;
  if p_override_type in ('WEEKLY_LIMIT','MONTHLY_LIMIT') and p_employee_id is not null then
    select coalesce((select rate.contract_type from public.employee_pay_rates_v2 rate
      where rate.employee_id=p_employee_id and rate.active and rate.valid_from<=p_starts_on
        and (rate.valid_to is null or rate.valid_to>=p_starts_on)
      order by rate.valid_from desc limit 1),
      (select hr.contract_type from public.employee_hr_profiles hr where hr.employee_id=p_employee_id),'INNE')
    into v_contract;
    if v_contract in ('UMOWA_O_PRACE','CZESC_ETATU') and not coalesce(p_compliance_confirmed,false) then
      raise exception 'EMPLOYMENT_COMPLIANCE_CONFIRMATION_REQUIRED';
    end if;
  end if;
  insert into public.recovery_overrides_v2(id,incident_id,override_type,employee_id,role_id,starts_on,ends_on,
    numeric_value,currency,justification,employee_acknowledged,compliance_confirmed,status,approved_by,approved_at,created_by)
  values(v_id,p_incident_id,p_override_type,p_employee_id,p_role_id,p_starts_on,p_ends_on,p_numeric_value,p_currency,
    trim(p_justification),coalesce(p_employee_acknowledged,false),coalesce(p_compliance_confirmed,false),'APPROVED',v_actor,now(),v_actor);
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'recovery_override_v2',v_id::text,'TEMPORARY_OVERRIDE_APPROVED',jsonb_build_object('type',p_override_type,'value',p_numeric_value,'startsOn',p_starts_on,'endsOn',p_ends_on,'employeeAcknowledged',p_employee_acknowledged,'contractType',v_contract,'complianceConfirmed',p_compliance_confirmed));
  return jsonb_build_object('saved',true,'id',v_id);
end;
$$;

create or replace function public.recovery_month_budget_save_uat_v1(
  p_month date,p_amount numeric,p_warning_percent integer,p_hard_limit boolean
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_month date:=date_trunc('month',p_month)::date;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'OWNER_REQUIRED'; end if;
  if p_amount<0 or p_warning_percent not between 1 and 100 then raise exception 'INVALID_BUDGET'; end if;
  insert into public.monthly_budgets(month,amount,warning_percent,hard_limit,updated_by,updated_at)
  values(v_month,p_amount,p_warning_percent,p_hard_limit,v_actor,now())
  on conflict(month) do update set amount=excluded.amount,warning_percent=excluded.warning_percent,
    hard_limit=excluded.hard_limit,updated_by=v_actor,updated_at=now();
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'monthly_budget',v_month::text,'MONTHLY_BUDGET_SAVED',jsonb_build_object('amount',p_amount,'warningPercent',p_warning_percent,'hardLimit',p_hard_limit));
  return jsonb_build_object('saved',true,'month',v_month);
end;
$$;

revoke all on function public.recovery_center_workspace_uat_v1(date) from public;
revoke all on function public.optimizer_role_colours_uat_v1(date) from public;
revoke all on function public.recovery_incident_save_uat_v1(date,integer,uuid,uuid,uuid,uuid,text,date,date,text,text,text) from public;
revoke all on function public.recovery_incident_prepare_uat_v1(uuid,integer,text) from public;
revoke all on function public.recovery_incident_detail_uat_v1(uuid) from public;
revoke all on function public.recovery_employee_offers_uat_v1(date) from public;
revoke all on function public.recovery_offer_respond_uat_v1(uuid,boolean,text) from public;
revoke all on function public.recovery_ad_hoc_save_uat_v1(uuid,uuid,text,text,text,uuid,text,bigint,text,date,date,text) from public;
revoke all on function public.recovery_override_save_uat_v1(uuid,text,uuid,uuid,date,date,bigint,text,text,boolean,boolean) from public;
revoke all on function public.recovery_month_budget_save_uat_v1(date,numeric,integer,boolean) from public;
grant execute on function public.recovery_center_workspace_uat_v1(date) to authenticated,service_role;
grant execute on function public.optimizer_role_colours_uat_v1(date) to authenticated,service_role;
grant execute on function public.recovery_incident_save_uat_v1(date,integer,uuid,uuid,uuid,uuid,text,date,date,text,text,text) to authenticated,service_role;
grant execute on function public.recovery_incident_prepare_uat_v1(uuid,integer,text) to authenticated,service_role;
grant execute on function public.recovery_incident_detail_uat_v1(uuid) to authenticated,service_role;
grant execute on function public.recovery_employee_offers_uat_v1(date) to authenticated,service_role;
grant execute on function public.recovery_offer_respond_uat_v1(uuid,boolean,text) to authenticated,service_role;
grant execute on function public.recovery_ad_hoc_save_uat_v1(uuid,uuid,text,text,text,uuid,text,bigint,text,date,date,text) to authenticated,service_role;
grant execute on function public.recovery_override_save_uat_v1(uuid,text,uuid,uuid,date,date,bigint,text,text,boolean,boolean) to authenticated,service_role;
grant execute on function public.recovery_month_budget_save_uat_v1(date,numeric,integer,boolean) to authenticated,service_role;

notify pgrst,'reload schema';
