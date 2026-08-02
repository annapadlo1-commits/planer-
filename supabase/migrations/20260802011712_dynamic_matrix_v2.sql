-- GRAFIK PRO 3.0 — Matrix v2 foundation.
--
-- This migration is intentionally additive. Alpha 15 keeps using the legacy
-- role/location enums and the legacy assignment tables until the solver feature
-- flag is deliberately changed after shadow UAT. Matrix v2 uses UUID relations
-- end to end and therefore supports roles, locations, duties, scenarios,
-- strategies and pay rules that do not exist in application code.

create extension if not exists pgcrypto;

alter table public.matrix_versions
  add column if not exists schema_version smallint not null default 1,
  add column if not exists base_version_id uuid references public.matrix_versions(id) on delete set null,
  add column if not exists content_hash text,
  add column if not exists workforce_hash text,
  add column if not exists workforce_count integer,
  add column if not exists published_by uuid references auth.users(id) on delete set null,
  add column if not exists published_at timestamptz;

-- Legacy Alpha 15 keeps the enum projection, while Matrix v2 may publish a
-- role that has no enum counterpart. Existing legacy employees keep their
-- current value; only the compatibility column becomes nullable.
alter table public.employees alter column primary_role drop not null;

create or replace function public.matrix_v2_stable_uuid(p_value text)
returns uuid
language sql
immutable
strict
set search_path = ''
as $$
  select (
    substr(md5(p_value),1,8)||'-'||substr(md5(p_value),9,4)||'-'||
    substr(md5(p_value),13,4)||'-'||substr(md5(p_value),17,4)||'-'||
    substr(md5(p_value),21,12)
  )::uuid;
$$;

revoke all on function public.matrix_v2_stable_uuid(text) from public, anon, authenticated;

-- One explicit ISO 4217 contract is used by Matrix publication, finance rows
-- and immutable solver snapshots. A three-letter token alone is not a
-- currency: accepting an invented code would make a published Matrix pass the
-- database boundary and fail only after the worker starts.
create or replace function public.matrix_v2_is_iso_4217_currency(p_currency text)
returns boolean
language sql
immutable
strict
set search_path = ''
as $$
  select p_currency ~ '^[A-Z]{3}$' and position(
    ' '||p_currency||' ' in
    ' AED AFN ALL AMD ANG AOA ARS AUD AWG AZN BAM BBD BDT BGN BHD BIF BMD BND BOB BOV BRL BSD BTN BWP BYN BZD CAD CDF CHE CHF CHW CLF CLP CNY COP COU CRC CUC CUP CVE CZK DJF DKK DOP DZD EGP ERN ETB EUR FJD FKP GBP GEL GHS GIP GMD GNF GTQ GYD HKD HNL HTG HUF IDR ILS INR IQD IRR ISK JMD JOD JPY KES KGS KHR KMF KPW KRW KWD KYD KZT LAK LBP LKR LRD LSL LYD MAD MDL MGA MKD MMK MNT MOP MRU MUR MVR MWK MXN MXV MYR MZN NAD NGN NIO NOK NPR NZD OMR PAB PEN PGK PHP PKR PLN PYG QAR RON RSD RUB RWF SAR SBD SCR SDG SEK SGD SHP SLE SLL SOS SRD SSP STN SVC SYP SZL THB TJS TMT TND TOP TRY TTD TWD TZS UAH UGX USD USN UYI UYU UYW UZS VED VES VND VUV WST XAF XAG XAU XBA XBB XBC XBD XCD XDR XOF XPD XPF XPT XSU XTS XUA XXX YER ZAR ZMW ZWG ZWL '
  ) > 0;
$$;

revoke all on function public.matrix_v2_is_iso_4217_currency(text)
  from public, anon, authenticated;
grant execute on function public.matrix_v2_is_iso_4217_currency(text)
  to service_role;

-- Safe, closed condition DSL for pay additions. Identifier fields carry UUID
-- strings, array membership is homogeneous, and numeric facts are integral
-- because both PostgreSQL snapshot hashing and CP-SAT use integer semantics.
create or replace function public.matrix_v2_is_supported_pay_condition(
  p_condition jsonb
) returns boolean
language sql
immutable
strict
set search_path = ''
as $$
  select case
    when jsonb_typeof(p_condition)<>'object'
      or p_condition-array['field','operator','value']<>'{}'::jsonb
      or not (p_condition ? 'field' and p_condition ? 'operator'
        and p_condition ? 'value')
      then false
    when lower(p_condition->>'field') in (
      'role_id','location_id','shift_template_id','scenario_id','employee_id'
    ) then case upper(p_condition->>'operator')
      when 'EQ' then jsonb_typeof(p_condition->'value')='string'
        and (p_condition->>'value')
          ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      when 'NE' then jsonb_typeof(p_condition->'value')='string'
        and (p_condition->>'value')
          ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      when 'IN' then jsonb_typeof(p_condition->'value')='array' and not exists(
        select 1 from jsonb_array_elements(p_condition->'value') item
        where jsonb_typeof(item.value)<>'string'
          or (item.value#>>'{}')
            !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      )
      when 'NOT_IN' then jsonb_typeof(p_condition->'value')='array' and not exists(
        select 1 from jsonb_array_elements(p_condition->'value') item
        where jsonb_typeof(item.value)<>'string'
          or (item.value#>>'{}')
            !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      )
      else false end
    when lower(p_condition->>'field')='duty_ids' then
      case upper(p_condition->>'operator')
        when 'CONTAINS' then jsonb_typeof(p_condition->'value')='string'
          and (p_condition->>'value')
            ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        when 'CONTAINS_ANY' then jsonb_typeof(p_condition->'value')='array'
          and not exists(
            select 1 from jsonb_array_elements(p_condition->'value') item
            where jsonb_typeof(item.value)<>'string'
              or (item.value#>>'{}')
                !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
          )
        when 'CONTAINS_ALL' then jsonb_typeof(p_condition->'value')='array'
          and not exists(
            select 1 from jsonb_array_elements(p_condition->'value') item
            where jsonb_typeof(item.value)<>'string'
              or (item.value#>>'{}')
                !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
          )
        else false end
    when lower(p_condition->>'field')='contract_code' then
      case upper(p_condition->>'operator')
        when 'EQ' then jsonb_typeof(p_condition->'value')='string'
          and length(p_condition->>'value')>0
        when 'NE' then jsonb_typeof(p_condition->'value')='string'
          and length(p_condition->>'value')>0
        when 'IN' then jsonb_typeof(p_condition->'value')='array'
          and not exists(
            select 1 from jsonb_array_elements(p_condition->'value') item
            where jsonb_typeof(item.value)<>'string'
              or length(item.value#>>'{}')=0
          )
        when 'NOT_IN' then jsonb_typeof(p_condition->'value')='array'
          and not exists(
            select 1 from jsonb_array_elements(p_condition->'value') item
            where jsonb_typeof(item.value)<>'string'
              or length(item.value#>>'{}')=0
          )
        else false end
    when lower(p_condition->>'field') in ('weekday','duration_minutes') then
      case upper(p_condition->>'operator')
        when 'EQ' then jsonb_typeof(p_condition->'value')='number'
          and (p_condition->'value'#>>'{}') ~ '^[0-9]+$'
          and (lower(p_condition->>'field')<>'weekday'
            or (p_condition->>'value')::integer between 1 and 7)
        when 'NE' then jsonb_typeof(p_condition->'value')='number'
          and (p_condition->'value'#>>'{}') ~ '^[0-9]+$'
          and (lower(p_condition->>'field')<>'weekday'
            or (p_condition->>'value')::integer between 1 and 7)
        when 'GTE' then jsonb_typeof(p_condition->'value')='number'
          and (p_condition->'value'#>>'{}') ~ '^[0-9]+$'
          and (lower(p_condition->>'field')<>'weekday'
            or (p_condition->>'value')::integer between 1 and 7)
        when 'LTE' then jsonb_typeof(p_condition->'value')='number'
          and (p_condition->'value'#>>'{}') ~ '^[0-9]+$'
          and (lower(p_condition->>'field')<>'weekday'
            or (p_condition->>'value')::integer between 1 and 7)
        when 'IN' then jsonb_typeof(p_condition->'value')='array'
          and not exists(
            select 1 from jsonb_array_elements(p_condition->'value') item
            where jsonb_typeof(item.value)<>'number'
              or (item.value#>>'{}') !~ '^[0-9]+$'
              or (lower(p_condition->>'field')='weekday'
                and (item.value#>>'{}')::integer not between 1 and 7)
          )
        when 'NOT_IN' then jsonb_typeof(p_condition->'value')='array'
          and not exists(
            select 1 from jsonb_array_elements(p_condition->'value') item
            where jsonb_typeof(item.value)<>'number'
              or (item.value#>>'{}') !~ '^[0-9]+$'
              or (lower(p_condition->>'field')='weekday'
                and (item.value#>>'{}')::integer not between 1 and 7)
          )
        else false end
    when lower(p_condition->>'field')='local_time' then
      upper(p_condition->>'operator')='OVERLAPS_TIME'
      and jsonb_typeof(p_condition->'value')='object'
      and (p_condition->'value')-array['start','end']<>'{}'::jsonb
      and coalesce(p_condition->'value'->>'start','')
        ~ '^([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?$'
      and coalesce(p_condition->'value'->>'end','')
        ~ '^([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?$'
    else false
  end;
$$;

revoke all on function public.matrix_v2_is_supported_pay_condition(jsonb)
  from public, anon, authenticated;
grant execute on function public.matrix_v2_is_supported_pay_condition(jsonb)
  to service_role;

create or replace function public.matrix_v2_is_supported_objective_config(
  p_direction text,p_parameters jsonb
) returns boolean
language sql
immutable
strict
set search_path = ''
as $$
  select jsonb_typeof(p_parameters)='object'
    and p_parameters-array['target','targetValue']='{}'::jsonb
    and not (p_parameters ? 'target' and p_parameters ? 'targetValue')
    and (
      not (p_parameters ? 'target' or p_parameters ? 'targetValue')
      or (
        case upper(p_direction)
          when 'MIN' then 'MINIMIZE'
          when 'MAX' then 'MAXIMIZE'
          else upper(p_direction)
        end='MINIMIZE'
        and coalesce(p_parameters->>case
          when p_parameters ? 'targetValue' then 'targetValue'
          else 'target' end,'') ~ '^[0-9]+$'
      )
    );
$$;

revoke all on function public.matrix_v2_is_supported_objective_config(text,jsonb)
  from public,anon,authenticated;
grant execute on function public.matrix_v2_is_supported_objective_config(text,jsonb)
  to service_role;

create table if not exists public.matrix_roles_v2 (
  id uuid primary key default gen_random_uuid(),
  matrix_version_id uuid not null references public.matrix_versions(id) on delete cascade,
  logical_id uuid not null default gen_random_uuid(),
  code text not null check (length(trim(code)) between 1 and 80),
  name text not null check (length(trim(name)) between 1 and 160),
  color text not null default '#7257d8',
  sort_order integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (matrix_version_id,id),
  unique (matrix_version_id,logical_id),
  unique (matrix_version_id,code)
);

create table if not exists public.matrix_locations_v2 (
  id uuid primary key default gen_random_uuid(),
  matrix_version_id uuid not null references public.matrix_versions(id) on delete cascade,
  logical_id uuid not null default gen_random_uuid(),
  code text not null check (length(trim(code)) between 1 and 80),
  name text not null check (length(trim(name)) between 1 and 160),
  timezone text not null,
  sort_order integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (matrix_version_id,id),
  unique (matrix_version_id,logical_id),
  unique (matrix_version_id,code)
);

create table if not exists public.matrix_duties_v2 (
  id uuid primary key default gen_random_uuid(),
  matrix_version_id uuid not null references public.matrix_versions(id) on delete cascade,
  logical_id uuid not null default gen_random_uuid(),
  code text not null check (length(trim(code)) between 1 and 80),
  name text not null check (length(trim(name)) between 1 and 160),
  description text,
  color text not null default '#4a8d78',
  sort_order integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (matrix_version_id,id),
  unique (matrix_version_id,logical_id),
  unique (matrix_version_id,code)
);

create table if not exists public.matrix_shift_templates_v2 (
  id uuid primary key default gen_random_uuid(),
  matrix_version_id uuid not null references public.matrix_versions(id) on delete cascade,
  logical_id uuid not null default gen_random_uuid(),
  location_id uuid not null,
  code text not null check (length(trim(code)) between 1 and 80),
  name text not null check (length(trim(name)) between 1 and 160),
  starts_at time not null,
  ends_at time not null,
  ends_next_day boolean not null default false,
  day_mask smallint[] not null default array[1,2,3,4,5,6,7]::smallint[],
  sort_order integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (cardinality(day_mask) between 1 and 7),
  check (day_mask <@ array[1,2,3,4,5,6,7]::smallint[]),
  unique (matrix_version_id,id),
  unique (matrix_version_id,logical_id),
  unique (matrix_version_id,location_id,code),
  foreign key (matrix_version_id,location_id)
    references public.matrix_locations_v2(matrix_version_id,id) on delete cascade
);

create table if not exists public.matrix_role_duties_v2 (
  id uuid primary key default gen_random_uuid(),
  matrix_version_id uuid not null references public.matrix_versions(id) on delete cascade,
  role_id uuid not null,
  duty_id uuid not null,
  assignment_mode text not null default 'OPTIONAL'
    check (assignment_mode in ('REQUIRED','OPTIONAL','EXTRA')),
  minimum_count integer not null default 0 check (minimum_count >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (matrix_version_id,role_id,duty_id),
  foreign key (matrix_version_id,role_id)
    references public.matrix_roles_v2(matrix_version_id,id) on delete cascade,
  foreign key (matrix_version_id,duty_id)
    references public.matrix_duties_v2(matrix_version_id,id) on delete cascade
);

create table if not exists public.matrix_scenarios_v2 (
  id uuid primary key default gen_random_uuid(),
  matrix_version_id uuid not null references public.matrix_versions(id) on delete cascade,
  logical_id uuid not null default gen_random_uuid(),
  parent_scenario_id uuid,
  code text not null check (length(trim(code)) between 1 and 80),
  name text not null check (length(trim(name)) between 1 and 160),
  description text,
  color text not null default '#7457e8',
  is_default boolean not null default false,
  active boolean not null default true,
  sort_order integer not null default 0,
  valid_from date,
  valid_to date,
  settings_overrides jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (valid_to is null or valid_from is null or valid_to >= valid_from),
  unique (matrix_version_id,id),
  unique (matrix_version_id,logical_id),
  unique (matrix_version_id,code),
  foreign key (matrix_version_id,parent_scenario_id)
    references public.matrix_scenarios_v2(matrix_version_id,id) on delete restrict
);

create unique index if not exists matrix_scenarios_v2_one_default_idx
  on public.matrix_scenarios_v2(matrix_version_id) where is_default and active;

create table if not exists public.matrix_staffing_rules_v2 (
  id uuid primary key default gen_random_uuid(),
  matrix_version_id uuid not null references public.matrix_versions(id) on delete cascade,
  scenario_id uuid not null,
  shift_template_id uuid not null,
  role_id uuid not null,
  duty_id uuid,
  operation text not null check (operation in ('SET','ADD','MULTIPLY','REMOVE')),
  count_value integer,
  multiplier_basis_points integer,
  active boolean not null default true,
  source_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (operation='SET' and count_value is not null and count_value >= 0 and multiplier_basis_points is null)
    or (operation='ADD' and count_value is not null and multiplier_basis_points is null)
    or (operation='MULTIPLY' and multiplier_basis_points is not null and multiplier_basis_points >= 0 and count_value is null)
    or (operation='REMOVE' and count_value is null and multiplier_basis_points is null)
  ),
  unique nulls not distinct (scenario_id,shift_template_id,role_id,duty_id),
  foreign key (matrix_version_id,scenario_id)
    references public.matrix_scenarios_v2(matrix_version_id,id) on delete cascade,
  foreign key (matrix_version_id,shift_template_id)
    references public.matrix_shift_templates_v2(matrix_version_id,id) on delete cascade,
  foreign key (matrix_version_id,role_id)
    references public.matrix_roles_v2(matrix_version_id,id) on delete cascade,
  foreign key (matrix_version_id,duty_id)
    references public.matrix_duties_v2(matrix_version_id,id) on delete cascade
);

create table if not exists public.matrix_strategies_v2 (
  id uuid primary key default gen_random_uuid(),
  matrix_version_id uuid not null references public.matrix_versions(id) on delete cascade,
  logical_id uuid not null default gen_random_uuid(),
  legacy_optimizer_profile_id uuid references public.optimizer_profiles(id) on delete set null,
  code text not null check (length(trim(code)) between 1 and 80),
  name text not null check (length(trim(name)) between 1 and 160),
  description text,
  solver_code text not null default 'CP_SAT',
  solver_options jsonb not null default '{}'::jsonb,
  legacy_weights jsonb not null default '{}'::jsonb,
  sort_order integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (matrix_version_id,id),
  unique (matrix_version_id,logical_id),
  unique (matrix_version_id,code)
);

create unique index if not exists matrix_strategies_v2_legacy_profile_idx
  on public.matrix_strategies_v2(matrix_version_id,legacy_optimizer_profile_id)
  where legacy_optimizer_profile_id is not null;

create table if not exists public.matrix_strategy_objectives_v2 (
  id uuid primary key default gen_random_uuid(),
  matrix_version_id uuid not null references public.matrix_versions(id) on delete cascade,
  strategy_id uuid not null,
  tier smallint not null check (tier between 1 and 100),
  sort_order integer not null default 0,
  metric_code text not null check (length(trim(metric_code)) between 1 and 100),
  direction text not null default 'MINIMIZE' check (direction in ('MINIMIZE','MAXIMIZE')),
  weight bigint not null default 1 check (weight >= 0),
  tolerance bigint not null default 0 check (tolerance >= 0),
  parameters jsonb not null default '{}'::jsonb,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (strategy_id,tier,metric_code),
  foreign key (matrix_version_id,strategy_id)
    references public.matrix_strategies_v2(matrix_version_id,id) on delete cascade
);

create table if not exists public.matrix_scenario_strategies_v2 (
  id uuid primary key default gen_random_uuid(),
  matrix_version_id uuid not null references public.matrix_versions(id) on delete cascade,
  scenario_id uuid not null,
  strategy_id uuid not null,
  sort_order integer not null default 0,
  active boolean not null default true,
  objective_overrides jsonb not null default '{}'::jsonb,
  solver_overrides jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (scenario_id,strategy_id),
  foreign key (matrix_version_id,scenario_id)
    references public.matrix_scenarios_v2(matrix_version_id,id) on delete cascade,
  foreign key (matrix_version_id,strategy_id)
    references public.matrix_strategies_v2(matrix_version_id,id) on delete cascade
);

create table if not exists public.matrix_employee_roles_v2 (
  id uuid primary key default gen_random_uuid(),
  matrix_version_id uuid not null references public.matrix_versions(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  role_id uuid not null,
  is_primary boolean not null default false,
  can_lead boolean not null default false,
  active boolean not null default true,
  valid_from date,
  valid_to date,
  created_at timestamptz not null default now(),
  check (valid_to is null or valid_from is null or valid_to >= valid_from),
  unique (matrix_version_id,employee_id,role_id),
  foreign key (matrix_version_id,role_id)
    references public.matrix_roles_v2(matrix_version_id,id) on delete cascade
);

create unique index if not exists matrix_employee_roles_v2_one_primary_idx
  on public.matrix_employee_roles_v2(matrix_version_id,employee_id)
  where is_primary and active;

create table if not exists public.matrix_employee_locations_v2 (
  id uuid primary key default gen_random_uuid(),
  matrix_version_id uuid not null references public.matrix_versions(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  location_id uuid not null,
  standard_allowed boolean not null default false,
  overtime_allowed boolean not null default false,
  home_location boolean not null default false,
  active boolean not null default true,
  valid_from date,
  valid_to date,
  created_at timestamptz not null default now(),
  check (standard_allowed or overtime_allowed or home_location),
  check (valid_to is null or valid_from is null or valid_to >= valid_from),
  unique (matrix_version_id,employee_id,location_id),
  foreign key (matrix_version_id,location_id)
    references public.matrix_locations_v2(matrix_version_id,id) on delete cascade
);

create index if not exists matrix_employee_locations_v2_home_idx
  on public.matrix_employee_locations_v2(matrix_version_id,employee_id)
  where home_location and active;

create table if not exists public.matrix_employee_duties_v2 (
  id uuid primary key default gen_random_uuid(),
  matrix_version_id uuid not null references public.matrix_versions(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  duty_id uuid not null,
  role_id uuid,
  location_id uuid,
  active boolean not null default true,
  valid_from date,
  valid_to date,
  source text not null default 'MATRIX',
  created_at timestamptz not null default now(),
  check (valid_to is null or valid_from is null or valid_to >= valid_from),
  unique nulls not distinct (matrix_version_id,employee_id,duty_id,role_id,location_id),
  foreign key (matrix_version_id,duty_id)
    references public.matrix_duties_v2(matrix_version_id,id) on delete cascade,
  foreign key (matrix_version_id,role_id)
    references public.matrix_roles_v2(matrix_version_id,id) on delete cascade,
  foreign key (matrix_version_id,location_id)
    references public.matrix_locations_v2(matrix_version_id,id) on delete cascade
);

create table if not exists public.matrix_employee_profiles_v2 (
  id uuid primary key default gen_random_uuid(),
  matrix_version_id uuid not null
    references public.matrix_versions(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete restrict,
  employee_no text not null check (length(trim(employee_no)) between 1 and 80),
  first_name text not null check (length(trim(first_name)) between 1 and 120),
  last_name text not null check (length(trim(last_name)) between 1 and 160),
  email text,
  active boolean not null default true,
  employment_start date,
  employment_end date,
  nominal_monthly_minutes integer not null
    check (nominal_monthly_minutes between 0 and 44640),
  maximum_monthly_minutes integer not null
    check (maximum_monthly_minutes between 0 and 44640),
  maximum_weekly_minutes integer not null
    check (maximum_weekly_minutes between 0 and 10080),
  maximum_consecutive_days integer not null
    check (maximum_consecutive_days between 1 and 31),
  minimum_rest_minutes integer check (minimum_rest_minutes between 0 and 2880),
  only_morning boolean not null default false,
  only_evening boolean not null default false,
  no_weekends boolean not null default false,
  preferred_shift_code text,
  archived_at timestamptz,
  archived_by uuid references auth.users(id) on delete set null,
  archive_reason text,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (matrix_version_id,employee_id),
  unique (matrix_version_id,employee_no),
  check (email is null or email=lower(trim(email))),
  check (maximum_monthly_minutes>=nominal_monthly_minutes),
  check (employment_end is null or employment_start is null
    or employment_end>=employment_start),
  check (not (only_morning and only_evening)),
  check (
    (active and archived_at is null and archived_by is null)
    or (not active and archived_at is not null)
  )
);

create unique index if not exists matrix_employee_profiles_v2_email_idx
  on public.matrix_employee_profiles_v2(matrix_version_id,lower(email))
  where email is not null;
create index if not exists matrix_employee_profiles_v2_status_idx
  on public.matrix_employee_profiles_v2(
    matrix_version_id,active,last_name,first_name
  );

alter table public.matrix_employee_profiles_v2 enable row level security;
revoke all privileges on table public.matrix_employee_profiles_v2
  from public,anon,authenticated;
grant all on table public.matrix_employee_profiles_v2 to service_role;

create table if not exists public.employee_time_constraints_v2 (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete cascade,
  constraint_kind text not null
    check (constraint_kind in ('AVAILABLE_WINDOW','UNAVAILABLE','LEAVE','SICKNESS')),
  time_range tstzrange not null,
  location_logical_id uuid,
  source text not null default 'GRAFIK_PRO',
  source_record_key text,
  priority smallint not null default 100,
  editable_by_employee boolean not null default true,
  status text not null default 'ACTIVE' check (status in ('ACTIVE','REVOKED')),
  note text,
  supersedes_id uuid references public.employee_time_constraints_v2(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  revoked_at timestamptz,
  check (not isempty(time_range)),
  check (lower(time_range) is not null and upper(time_range) is not null)
);

create unique index if not exists employee_time_constraints_v2_source_record_idx
  on public.employee_time_constraints_v2(source,source_record_key)
  where source_record_key is not null;

create table if not exists public.matrix_pay_rules_v2 (
  id uuid primary key default gen_random_uuid(),
  matrix_version_id uuid not null references public.matrix_versions(id) on delete cascade,
  logical_id uuid not null default gen_random_uuid(),
  code text not null check (length(trim(code)) between 1 and 80),
  name text not null check (length(trim(name)) between 1 and 160),
  description text,
  calculation_method text not null check (calculation_method in (
    'FIXED_PER_SHIFT','PER_HOUR','PERCENT_BASE','MULTIPLIER',
    'SHIFT_DURATION_THRESHOLD_PER_HOUR','MONTHLY_THRESHOLD_PER_HOUR'
  )),
  amount_minor bigint,
  rate_minor_per_hour bigint,
  percent_basis_points integer,
  multiplier_basis_points integer,
  threshold_minutes integer,
  currency text not null check (public.matrix_v2_is_iso_4217_currency(currency)),
  priority integer not null default 100,
  stacking_group text,
  stacking_mode text not null default 'STACK' check (stacking_mode in ('STACK','MAX','FIRST')),
  day_mask smallint[] not null default array[1,2,3,4,5,6,7]::smallint[],
  local_start time,
  local_end time,
  ends_next_day boolean not null default false,
  valid_from date,
  valid_to date,
  condition_expression jsonb not null default '{}'::jsonb,
  formula_expression jsonb not null default '{}'::jsonb,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (cardinality(day_mask) between 1 and 7),
  check (day_mask <@ array[1,2,3,4,5,6,7]::smallint[]),
  check (valid_to is null or valid_from is null or valid_to >= valid_from),
  check (amount_minor is null or amount_minor >= 0),
  check (rate_minor_per_hour is null or rate_minor_per_hour >= 0),
  check (percent_basis_points is null or percent_basis_points >= 0),
  check (multiplier_basis_points is null or multiplier_basis_points >= 0),
  check (threshold_minutes is null or threshold_minutes >= 0),
  check (
    (calculation_method='FIXED_PER_SHIFT' and amount_minor is not null)
    or (calculation_method='PER_HOUR' and rate_minor_per_hour is not null)
    or (calculation_method='PERCENT_BASE' and percent_basis_points is not null)
    or (calculation_method='MULTIPLIER' and multiplier_basis_points is not null)
    or (calculation_method in (
      'SHIFT_DURATION_THRESHOLD_PER_HOUR','MONTHLY_THRESHOLD_PER_HOUR'
    ) and threshold_minutes is not null and rate_minor_per_hour is not null)
  ),
  unique (matrix_version_id,id),
  unique (matrix_version_id,logical_id),
  unique (matrix_version_id,code)
);

create table if not exists public.matrix_pay_rule_roles_v2 (
  matrix_version_id uuid not null references public.matrix_versions(id) on delete cascade,
  pay_rule_id uuid not null,
  role_id uuid not null,
  primary key (pay_rule_id,role_id),
  foreign key (matrix_version_id,pay_rule_id)
    references public.matrix_pay_rules_v2(matrix_version_id,id) on delete cascade,
  foreign key (matrix_version_id,role_id)
    references public.matrix_roles_v2(matrix_version_id,id) on delete cascade
);

create table if not exists public.matrix_pay_rule_duties_v2 (
  matrix_version_id uuid not null references public.matrix_versions(id) on delete cascade,
  pay_rule_id uuid not null,
  duty_id uuid not null,
  match_mode text not null default 'ANY' check (match_mode in ('ANY','ALL')),
  primary key (pay_rule_id,duty_id),
  foreign key (matrix_version_id,pay_rule_id)
    references public.matrix_pay_rules_v2(matrix_version_id,id) on delete cascade,
  foreign key (matrix_version_id,duty_id)
    references public.matrix_duties_v2(matrix_version_id,id) on delete cascade
);

create table if not exists public.matrix_pay_rule_locations_v2 (
  matrix_version_id uuid not null references public.matrix_versions(id) on delete cascade,
  pay_rule_id uuid not null,
  location_id uuid not null,
  primary key (pay_rule_id,location_id),
  foreign key (matrix_version_id,pay_rule_id)
    references public.matrix_pay_rules_v2(matrix_version_id,id) on delete cascade,
  foreign key (matrix_version_id,location_id)
    references public.matrix_locations_v2(matrix_version_id,id) on delete cascade
);

create table if not exists public.matrix_pay_rule_shifts_v2 (
  matrix_version_id uuid not null references public.matrix_versions(id) on delete cascade,
  pay_rule_id uuid not null,
  shift_template_id uuid not null,
  primary key (pay_rule_id,shift_template_id),
  foreign key (matrix_version_id,pay_rule_id)
    references public.matrix_pay_rules_v2(matrix_version_id,id) on delete cascade,
  foreign key (matrix_version_id,shift_template_id)
    references public.matrix_shift_templates_v2(matrix_version_id,id) on delete cascade
);

create table if not exists public.matrix_scenario_pay_rule_overrides_v2 (
  id uuid primary key default gen_random_uuid(),
  matrix_version_id uuid not null references public.matrix_versions(id) on delete cascade,
  scenario_id uuid not null,
  pay_rule_id uuid not null,
  enabled boolean not null default true,
  amount_minor bigint,
  rate_minor_per_hour bigint,
  percent_basis_points integer,
  multiplier_basis_points integer,
  formula_expression jsonb,
  created_at timestamptz not null default now(),
  check (amount_minor is null or amount_minor >= 0),
  check (rate_minor_per_hour is null or rate_minor_per_hour >= 0),
  check (percent_basis_points is null or percent_basis_points >= 0),
  check (multiplier_basis_points is null or multiplier_basis_points >= 0),
  unique (scenario_id,pay_rule_id),
  foreign key (matrix_version_id,scenario_id)
    references public.matrix_scenarios_v2(matrix_version_id,id) on delete cascade,
  foreign key (matrix_version_id,pay_rule_id)
    references public.matrix_pay_rules_v2(matrix_version_id,id) on delete cascade
);

create table if not exists public.matrix_scenario_budgets_v2 (
  id uuid primary key default gen_random_uuid(),
  matrix_version_id uuid not null references public.matrix_versions(id) on delete cascade,
  scenario_id uuid not null,
  budget_month date,
  location_id uuid,
  role_id uuid,
  duty_id uuid,
  operation text not null default 'SET' check (operation in ('SET','ADD','MULTIPLY','REMOVE')),
  amount_minor bigint,
  multiplier_basis_points integer,
  currency text not null check (public.matrix_v2_is_iso_4217_currency(currency)),
  hard_limit boolean,
  warning_percent integer check (warning_percent between 1 and 100),
  source_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (budget_month is null or date_trunc('month',budget_month)::date=budget_month),
  check (
    (operation in ('SET','ADD') and amount_minor is not null and multiplier_basis_points is null)
    or (operation='MULTIPLY' and multiplier_basis_points is not null and multiplier_basis_points >= 0 and amount_minor is null)
    or (operation='REMOVE' and amount_minor is null and multiplier_basis_points is null)
  ),
  unique nulls not distinct (scenario_id,budget_month,location_id,role_id,duty_id),
  foreign key (matrix_version_id,scenario_id)
    references public.matrix_scenarios_v2(matrix_version_id,id) on delete cascade,
  foreign key (matrix_version_id,location_id)
    references public.matrix_locations_v2(matrix_version_id,id) on delete cascade,
  foreign key (matrix_version_id,role_id)
    references public.matrix_roles_v2(matrix_version_id,id) on delete cascade,
  foreign key (matrix_version_id,duty_id)
    references public.matrix_duties_v2(matrix_version_id,id) on delete cascade
);

create table if not exists public.employee_pay_rates_v2 (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete cascade,
  valid_from date not null,
  valid_to date,
  base_rate_minor bigint not null check (base_rate_minor >= 0),
  currency text not null check (public.matrix_v2_is_iso_4217_currency(currency)),
  contract_type text,
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (valid_to is null or valid_to >= valid_from),
  unique (employee_id,valid_from)
);

create table if not exists public.matrix_scope_grants_v2 (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null references auth.users(id) on delete cascade,
  app_role public.app_role not null,
  role_logical_id uuid,
  location_logical_id uuid,
  duty_logical_id uuid,
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique nulls not distinct (
    auth_user_id,app_role,role_logical_id,location_logical_id,duty_logical_id
  )
);

create table if not exists public.solver_feature_flags (
  flag_key text primary key,
  engine text not null check (engine in ('ALPHA15','ORTOOLS_V2','SHADOW')),
  enabled boolean not null default true,
  config jsonb not null default '{}'::jsonb,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

insert into public.solver_feature_flags(flag_key,engine,enabled,config)
values('DEFAULT_ENGINE','ALPHA15',true,'{"reason":"Matrix v2 remains behind shadow UAT"}'::jsonb)
on conflict(flag_key) do nothing;

create index if not exists matrix_roles_v2_logical_idx
  on public.matrix_roles_v2(logical_id,matrix_version_id);
create index if not exists matrix_locations_v2_logical_idx
  on public.matrix_locations_v2(logical_id,matrix_version_id);
create index if not exists matrix_duties_v2_logical_idx
  on public.matrix_duties_v2(logical_id,matrix_version_id);
create index if not exists matrix_shift_templates_v2_location_idx
  on public.matrix_shift_templates_v2(matrix_version_id,location_id,active);
create index if not exists matrix_role_duties_v2_duty_idx
  on public.matrix_role_duties_v2(matrix_version_id,duty_id);
create index if not exists matrix_scenarios_v2_parent_idx
  on public.matrix_scenarios_v2(matrix_version_id,parent_scenario_id);
create index if not exists matrix_staffing_rules_v2_scenario_idx
  on public.matrix_staffing_rules_v2(matrix_version_id,scenario_id,active);
create index if not exists matrix_staffing_rules_v2_shift_idx
  on public.matrix_staffing_rules_v2(matrix_version_id,shift_template_id);
create index if not exists matrix_strategy_objectives_v2_strategy_idx
  on public.matrix_strategy_objectives_v2(strategy_id,tier,sort_order);
create index if not exists matrix_scenario_strategies_v2_scenario_idx
  on public.matrix_scenario_strategies_v2(scenario_id,active,sort_order);
create index if not exists matrix_employee_roles_v2_role_idx
  on public.matrix_employee_roles_v2(matrix_version_id,role_id,active);
create index if not exists matrix_employee_roles_v2_employee_idx
  on public.matrix_employee_roles_v2(employee_id,matrix_version_id,active);
create index if not exists matrix_employee_locations_v2_location_idx
  on public.matrix_employee_locations_v2(matrix_version_id,location_id,active);
create index if not exists matrix_employee_locations_v2_employee_idx
  on public.matrix_employee_locations_v2(employee_id,matrix_version_id,active);
create index if not exists matrix_employee_duties_v2_duty_idx
  on public.matrix_employee_duties_v2(matrix_version_id,duty_id,active);
create index if not exists matrix_employee_duties_v2_employee_idx
  on public.matrix_employee_duties_v2(employee_id,matrix_version_id,active);
create index if not exists employee_time_constraints_v2_employee_idx
  on public.employee_time_constraints_v2(employee_id,status,updated_at desc);
create index if not exists employee_time_constraints_v2_range_idx
  on public.employee_time_constraints_v2 using gist(time_range);
create index if not exists matrix_pay_rules_v2_active_idx
  on public.matrix_pay_rules_v2(matrix_version_id,active,priority);
create index if not exists matrix_pay_rule_roles_v2_role_idx
  on public.matrix_pay_rule_roles_v2(matrix_version_id,role_id);
create index if not exists matrix_pay_rule_duties_v2_duty_idx
  on public.matrix_pay_rule_duties_v2(matrix_version_id,duty_id);
create index if not exists matrix_pay_rule_locations_v2_location_idx
  on public.matrix_pay_rule_locations_v2(matrix_version_id,location_id);
create index if not exists matrix_pay_rule_shifts_v2_shift_idx
  on public.matrix_pay_rule_shifts_v2(matrix_version_id,shift_template_id);
create index if not exists matrix_scenario_budgets_v2_lookup_idx
  on public.matrix_scenario_budgets_v2(matrix_version_id,scenario_id,budget_month);
create index if not exists employee_pay_rates_v2_employee_idx
  on public.employee_pay_rates_v2(employee_id,active,valid_from desc);
create index if not exists matrix_scope_grants_v2_user_idx
  on public.matrix_scope_grants_v2(auth_user_id,active,app_role);

-- ---------------------------------------------------------------------------
-- Set-based compatibility backfill. Only ACTIVE and DRAFT Matrix versions are
-- mirrored. Legacy IDs are retained where a one-to-one source row exists;
-- logical IDs remain stable between versions and are used by authorization.
-- ---------------------------------------------------------------------------

update public.matrix_versions
set schema_version=greatest(schema_version,2),
  settings=coalesce(settings,'{}'::jsonb)||jsonb_build_object(
    'currency',coalesce(nullif(upper(settings->>'currency'),''),'PLN'),
    'timezone',coalesce(nullif(settings->>'timezone',''),'Europe/Warsaw'),
    'maximumShiftsPerDay',coalesce(
      nullif(settings->>'maximumShiftsPerDay','')::integer,
      nullif(settings->>'maxShiftsPerDay','')::integer,
      1
    ),
    'minimumRestMinutes',coalesce(
      nullif(settings->>'minimumRestMinutes','')::integer,660
    ),
    'missingAvailabilityMeansAvailable',coalesce(
      (settings->>'missingAvailabilityMeansAvailable')::boolean,true
    ),
    'requireOptimal',coalesce((settings->>'requireOptimal')::boolean,true)
  )
where status in ('ACTIVE','DRAFT');

insert into public.matrix_roles_v2(
  id,matrix_version_id,logical_id,code,name,color,sort_order,active
)
select r.id,r.matrix_version_id,
  public.matrix_v2_stable_uuid('ROLE:'||upper(trim(r.code))),
  upper(trim(r.code)),r.name,r.color,r.sort_order,r.active
from public.matrix_roles r
join public.matrix_versions mv on mv.id=r.matrix_version_id
where mv.status in ('ACTIVE','DRAFT')
on conflict do nothing;

insert into public.matrix_locations_v2(
  id,matrix_version_id,logical_id,code,name,timezone,sort_order,active
)
select ml.id,ml.matrix_version_id,
  public.matrix_v2_stable_uuid('LOCATION:'||upper(trim(ml.code))),
  upper(trim(ml.code)),ml.name,coalesce(l.timezone,'Europe/Warsaw'),0,ml.active
from public.matrix_locations ml
join public.matrix_versions mv on mv.id=ml.matrix_version_id
left join public.locations l on l.code::text=ml.code
where mv.status in ('ACTIVE','DRAFT')
on conflict do nothing;

insert into public.matrix_duties_v2(
  id,matrix_version_id,logical_id,code,name,description,sort_order,active
)
select f.id,f.matrix_version_id,
  public.matrix_v2_stable_uuid('DUTY:'||upper(trim(f.code))),
  upper(trim(f.code)),f.name,f.description,0,f.active
from public.matrix_functions f
join public.matrix_versions mv on mv.id=f.matrix_version_id
where mv.status in ('ACTIVE','DRAFT')
on conflict do nothing;

insert into public.matrix_shift_templates_v2(
  id,matrix_version_id,logical_id,location_id,code,name,starts_at,ends_at,
  ends_next_day,day_mask,sort_order,active
)
select s.id,s.matrix_version_id,
  public.matrix_v2_stable_uuid(
    'SHIFT:'||ml.logical_id::text||':'||upper(trim(s.code))
  ),s.location_id,upper(trim(s.code)),s.name,s.starts_at,s.ends_at,
  s.ends_at<=s.starts_at,s.day_mask,s.sort_order,s.active
from public.matrix_shift_templates s
join public.matrix_versions mv on mv.id=s.matrix_version_id
join public.matrix_locations_v2 ml
  on ml.matrix_version_id=s.matrix_version_id and ml.id=s.location_id
where mv.status in ('ACTIVE','DRAFT')
on conflict do nothing;

insert into public.matrix_role_duties_v2(
  id,matrix_version_id,role_id,duty_id,assignment_mode,minimum_count,active
)
select public.matrix_v2_stable_uuid('ROLE_DUTY:'||rf.role_id::text||':'||rf.function_id::text),
  r.matrix_version_id,rf.role_id,rf.function_id,rf.assignment_mode,
  case when rf.assignment_mode='REQUIRED' then 1 else 0 end,true
from public.matrix_role_functions rf
join public.matrix_roles_v2 r on r.id=rf.role_id
join public.matrix_duties_v2 d
  on d.id=rf.function_id and d.matrix_version_id=r.matrix_version_id
on conflict do nothing;

insert into public.matrix_scenarios_v2(
  id,matrix_version_id,logical_id,code,name,description,color,is_default,
  active,sort_order
)
select s.id,s.matrix_version_id,
  public.matrix_v2_stable_uuid('SCENARIO:'||upper(trim(s.code))),
  upper(trim(s.code)),s.name,s.description,s.color,upper(trim(s.code))='BASE',
  s.active,s.sort_order
from public.matrix_scenarios s
join public.matrix_versions mv on mv.id=s.matrix_version_id
where mv.status in ('ACTIVE','DRAFT')
on conflict do nothing;

with target_versions as (
  select id from public.matrix_versions where status in ('ACTIVE','DRAFT')
), scenario_catalog as (
  select distinct upper(trim(s.code)) code,s.name,s.description,s.color,s.sort_order
  from public.matrix_scenarios s
  union all
  select 'BASE','Bazowy','Standardowe zapotrzebowanie','#7457e8',1
), demanded as (
  select distinct st.matrix_version_id,upper(trim(d.scenario_code)) code
  from public.matrix_demand d
  join public.matrix_shift_templates st on st.id=d.shift_template_id
  join target_versions tv on tv.id=st.matrix_version_id
), wanted as (
  select tv.id matrix_version_id,c.code,c.name,c.description,c.color,c.sort_order
  from target_versions tv cross join scenario_catalog c
  union
  select d.matrix_version_id,d.code,d.code,null::text,'#7457e8',99 from demanded d
)
insert into public.matrix_scenarios_v2(
  id,matrix_version_id,logical_id,code,name,description,color,is_default,
  active,sort_order
)
select public.matrix_v2_stable_uuid('SCENARIO_ROW:'||w.matrix_version_id::text||':'||w.code),
  w.matrix_version_id,public.matrix_v2_stable_uuid('SCENARIO:'||w.code),
  w.code,max(w.name),max(w.description),max(w.color),w.code='BASE',true,min(w.sort_order)
from wanted w
where length(w.code)>0
group by w.matrix_version_id,w.code
on conflict do nothing;

update public.matrix_scenarios_v2 child
set parent_scenario_id=base.id,updated_at=now()
from public.matrix_scenarios_v2 base
where base.matrix_version_id=child.matrix_version_id
  and base.code='BASE' and base.active
  and child.code<>'BASE' and child.parent_scenario_id is null;

insert into public.matrix_staffing_rules_v2(
  id,matrix_version_id,scenario_id,shift_template_id,role_id,duty_id,
  operation,count_value,source_metadata
)
select d.id,st.matrix_version_id,sc.id,d.shift_template_id,d.role_id,d.function_id,
  case when upper(d.scenario_code)='BASE' then 'SET' else 'ADD' end,
  d.required_count,
  jsonb_build_object(
    'source','LEGACY_MATRIX_DEMAND',
    'legacyScenarioSemantics',case when upper(d.scenario_code)='BASE' then 'ABSOLUTE' else 'ADDITIVE' end
  )
from public.matrix_demand d
join public.matrix_shift_templates_v2 st on st.id=d.shift_template_id
join public.matrix_roles_v2 r
  on r.id=d.role_id and r.matrix_version_id=st.matrix_version_id
left join public.matrix_duties_v2 duty
  on duty.id=d.function_id and duty.matrix_version_id=st.matrix_version_id
join public.matrix_scenarios_v2 sc
  on sc.matrix_version_id=st.matrix_version_id
 and sc.code=upper(trim(d.scenario_code))
where d.function_id is null or duty.id is not null
on conflict do nothing;

insert into public.matrix_strategies_v2(
  id,matrix_version_id,logical_id,legacy_optimizer_profile_id,code,name,
  description,solver_code,solver_options,legacy_weights,sort_order,active
)
select p.id,p.matrix_version_id,
  public.matrix_v2_stable_uuid('STRATEGY:'||upper(trim(p.code))),p.id,
  upper(trim(p.code)),p.name,'Migracja z profilu Alpha 15','CP_SAT',
  jsonb_build_object('maxTimeSeconds',120,'randomSeed',0),p.weights,
  case upper(p.code) when 'BALANCED' then 1 when 'MIN_COST' then 2
    when 'PREFERENCES' then 3 else 99 end,p.active
from public.optimizer_profiles p
join public.matrix_versions mv on mv.id=p.matrix_version_id
where mv.status in ('ACTIVE','DRAFT')
on conflict do nothing;

with target_versions as (
  select id from public.matrix_versions where status in ('ACTIVE','DRAFT')
), defaults(code,name,weights,sort_order) as (values
  ('BALANCED','Zrównoważony',
    '{"cost":1,"preference":80,"fairness":40,"nominal":30,"homeLocation":15,"weekendFairness":25,"overtime":250}'::jsonb,1),
  ('MIN_COST','Minimalny koszt',
    '{"cost":4,"preference":30,"fairness":15,"nominal":20,"homeLocation":5,"weekendFairness":10,"overtime":500}'::jsonb,2),
  ('PREFERENCES','Preferencje i równy podział',
    '{"cost":0.5,"preference":100,"fairness":120,"nominal":90,"homeLocation":20,"weekendFairness":100,"overtime":300}'::jsonb,3)
)
insert into public.matrix_strategies_v2(
  id,matrix_version_id,logical_id,code,name,description,solver_code,
  solver_options,legacy_weights,sort_order,active
)
select public.matrix_v2_stable_uuid('STRATEGY_ROW:'||tv.id::text||':'||d.code),
  tv.id,public.matrix_v2_stable_uuid('STRATEGY:'||d.code),d.code,d.name,
  'Domyślna strategia po migracji Matrix v2','CP_SAT',
  '{"maxTimeSeconds":120,"randomSeed":0}'::jsonb,d.weights,d.sort_order,true
from target_versions tv cross join defaults d
on conflict do nothing;

insert into public.matrix_strategy_objectives_v2(
  id,matrix_version_id,strategy_id,tier,sort_order,metric_code,direction,
  weight,tolerance,parameters
)
select public.matrix_v2_stable_uuid(
    'OBJECTIVE:'||s.id::text||':'||x.tier::text||':'||x.metric_code
  ),s.matrix_version_id,s.id,x.tier,x.sort_order,x.metric_code,'MINIMIZE',
  greatest(0,round(x.weight_value*1000)::bigint),0,'{}'::jsonb
from public.matrix_strategies_v2 s
cross join lateral (values
  (1::smallint,1,'UNFILLED',1::numeric),
  (2::smallint,1,'TOTAL_COST',coalesce((s.legacy_weights->>'cost')::numeric,1)),
  (2::smallint,2,'PREFERENCE_VIOLATIONS',coalesce((s.legacy_weights->>'preference')::numeric,80)),
  (2::smallint,3,'OVERTIME_MINUTES',coalesce((s.legacy_weights->>'overtime')::numeric,250)),
  (2::smallint,4,'NOMINAL_DEVIATION_MINUTES',coalesce((s.legacy_weights->>'nominal')::numeric,30)),
  (2::smallint,5,'LOAD_SPREAD_MINUTES',coalesce((s.legacy_weights->>'fairness')::numeric,40)),
  (2::smallint,6,'WEEKEND_SPREAD',coalesce((s.legacy_weights->>'weekendFairness')::numeric,25)),
  (2::smallint,7,'HOME_LOCATION_VIOLATIONS',coalesce((s.legacy_weights->>'homeLocation')::numeric,15)),
  (2::smallint,8,'BASELINE_CHANGES',20::numeric)
) as x(tier,sort_order,metric_code,weight_value)
on conflict do nothing;

insert into public.matrix_scenario_strategies_v2(
  id,matrix_version_id,scenario_id,strategy_id,sort_order,active
)
select public.matrix_v2_stable_uuid('SCENARIO_STRATEGY:'||sc.id::text||':'||st.id::text),
  sc.matrix_version_id,sc.id,st.id,st.sort_order,true
from public.matrix_scenarios_v2 sc
join public.matrix_strategies_v2 st on st.matrix_version_id=sc.matrix_version_id
where sc.active and st.active
on conflict do nothing;

-- Capture the current legacy directory as the initial immutable workforce for
-- every v2 Matrix version. Later edits happen only in a draft profile.
insert into public.matrix_employee_profiles_v2(
  matrix_version_id,employee_id,employee_no,first_name,last_name,email,active,
  employment_start,employment_end,nominal_monthly_minutes,
  maximum_monthly_minutes,maximum_weekly_minutes,maximum_consecutive_days,
  minimum_rest_minutes,only_morning,only_evening,no_weekends,
  preferred_shift_code,archived_at,archived_by,archive_reason,
  created_by,updated_by
)
select mv.id,e.id,e.employee_no,e.first_name,e.last_name,lower(e.email),
  e.active and e.archived_at is null,e.employment_start,e.employment_end,
  e.monthly_nominal_minutes,
  greatest(e.monthly_nominal_minutes,
    coalesce(e.max_monthly_minutes,e.monthly_nominal_minutes)),
  e.max_weekly_minutes,e.max_consecutive_days,e.minimum_rest_minutes,
  e.only_morning,e.only_evening,e.no_weekends,e.preferred_shift,
  case when e.active and e.archived_at is null then null
    else coalesce(e.archived_at,e.updated_at,now()) end,
  case when e.active and e.archived_at is null then null else e.archived_by end,
  e.archive_reason,mv.created_by,mv.created_by
from public.matrix_versions mv
cross join public.employees e
where mv.schema_version>=2
on conflict(matrix_version_id,employee_id) do nothing;

insert into public.matrix_employee_roles_v2(
  id,matrix_version_id,employee_id,role_id,is_primary,can_lead,active
)
select public.matrix_v2_stable_uuid(
    'EMPLOYEE_ROLE:'||mer.matrix_version_id::text||':'||mer.employee_id::text||':'||mer.role_id::text
  ),mer.matrix_version_id,mer.employee_id,mer.role_id,mer.is_primary,mer.can_lead,true
from public.matrix_employee_roles mer
join public.matrix_versions mv on mv.id=mer.matrix_version_id
join public.matrix_roles_v2 r
  on r.matrix_version_id=mer.matrix_version_id and r.id=mer.role_id
where mv.status in ('ACTIVE','DRAFT')
on conflict(matrix_version_id,employee_id,role_id) do update
set is_primary=excluded.is_primary,can_lead=excluded.can_lead,active=true;

insert into public.matrix_employee_roles_v2(
  id,matrix_version_id,employee_id,role_id,is_primary,can_lead,active
)
select public.matrix_v2_stable_uuid(
    'EMPLOYEE_ROLE:'||r.matrix_version_id::text||':'||e.id::text||':'||r.id::text
  ),r.matrix_version_id,e.id,r.id,
  not exists(select 1 from public.matrix_employee_roles_v2 existing
    where existing.matrix_version_id=r.matrix_version_id
      and existing.employee_id=e.id and existing.is_primary and existing.active
      and existing.role_id<>r.id),
  exists(select 1 from public.employee_capabilities ec
    where ec.employee_id=e.id and ec.active and ec.capability='ROLE_MANAGER'),true
from public.employees e
join public.matrix_roles_v2 r on r.code=e.primary_role::text
join public.matrix_versions mv on mv.id=r.matrix_version_id
where mv.status in ('ACTIVE','DRAFT')
on conflict(matrix_version_id,employee_id,role_id) do update
set is_primary=excluded.is_primary,can_lead=excluded.can_lead,active=true;

insert into public.matrix_employee_locations_v2(
  id,matrix_version_id,employee_id,location_id,standard_allowed,
  overtime_allowed,home_location,active
)
select public.matrix_v2_stable_uuid(
    'EMPLOYEE_LOCATION:'||ml.matrix_version_id::text||':'||el.employee_id::text||':'||ml.id::text
  ),ml.matrix_version_id,el.employee_id,ml.id,el.standard_allowed,
  el.overtime_allowed,el.home_location,true
from public.employee_locations el
join public.locations l on l.id=el.location_id
join public.matrix_locations_v2 ml on ml.code=l.code::text
join public.matrix_versions mv on mv.id=ml.matrix_version_id
where mv.status in ('ACTIVE','DRAFT')
on conflict(matrix_version_id,employee_id,location_id) do update
set standard_allowed=excluded.standard_allowed,
    overtime_allowed=excluded.overtime_allowed,
    home_location=excluded.home_location,
    active=true;

-- Only capabilities with an explicit Matrix function are duties. Authorization
-- capabilities such as ROLE_MANAGER and LOCATION_MANAGER are intentionally not
-- transformed into operational duties merely because they exist in legacy data.
insert into public.matrix_employee_duties_v2(
  id,matrix_version_id,employee_id,duty_id,role_id,location_id,active,source
)
select public.matrix_v2_stable_uuid(
    'EMPLOYEE_DUTY:'||d.matrix_version_id::text||':'||ec.id::text
  ),d.matrix_version_id,ec.employee_id,d.id,r.id,l.id,ec.active,'LEGACY_CAPABILITY'
from public.employee_capabilities ec
join public.matrix_duties_v2 d on d.code=ec.capability
join public.matrix_versions mv on mv.id=d.matrix_version_id
left join public.matrix_roles_v2 r
  on r.matrix_version_id=d.matrix_version_id and r.code=ec.scope_role::text
left join public.matrix_locations_v2 l
  on l.matrix_version_id=d.matrix_version_id and l.code=ec.scope_location::text
where mv.status in ('ACTIVE','DRAFT')
  and (ec.scope_role is null or r.id is not null)
  and (ec.scope_location is null or l.id is not null)
on conflict do nothing;

insert into public.employee_pay_rates_v2(
  id,employee_id,valid_from,valid_to,base_rate_minor,currency,contract_type,active
)
select public.matrix_v2_stable_uuid('EMPLOYEE_PAY_RATE:'||e.id::text||':LEGACY'),
  e.id,coalesce(e.employment_start,date '1970-01-01'),e.employment_end,
  round(e.hourly_rate*100)::bigint,
  (select upper(mv.settings->>'currency') from public.matrix_versions mv
    where mv.status='ACTIVE' and mv.schema_version>=2
    order by mv.version desc limit 1),
  h.contract_type,e.active and e.archived_at is null
from public.employees e
left join public.employee_hr_profiles h on h.employee_id=e.id
on conflict(employee_id,valid_from) do nothing;

insert into public.employee_time_constraints_v2(
  id,employee_id,constraint_kind,time_range,source,source_record_key,priority,
  editable_by_employee,status,note,created_by,updated_at
)
select public.matrix_v2_stable_uuid('AVAILABILITY:'||a.id::text),a.employee_id,
  case when a.available then 'AVAILABLE_WINDOW' else 'UNAVAILABLE' end,
  case when not a.available then
    tstzrange(
      a.work_date::timestamp at time zone (
        select mv.settings->>'timezone' from public.matrix_versions mv
        where mv.status='ACTIVE' and mv.schema_version>=2
        order by mv.version desc limit 1
      ),
      (a.work_date+1)::timestamp at time zone (
        select mv.settings->>'timezone' from public.matrix_versions mv
        where mv.status='ACTIVE' and mv.schema_version>=2
        order by mv.version desc limit 1
      ),'[)'
    )
  else
    tstzrange(
      (a.work_date+coalesce(a.earliest_start,time '00:00')) at time zone (
        select mv.settings->>'timezone' from public.matrix_versions mv
        where mv.status='ACTIVE' and mv.schema_version>=2
        order by mv.version desc limit 1
      ),
      case
        when a.latest_end is null then
          (a.work_date+1)::timestamp at time zone (
            select mv.settings->>'timezone' from public.matrix_versions mv
            where mv.status='ACTIVE' and mv.schema_version>=2
            order by mv.version desc limit 1
          )
        when a.latest_end<=coalesce(a.earliest_start,time '00:00') then
          ((a.work_date+1)+a.latest_end) at time zone (
            select mv.settings->>'timezone' from public.matrix_versions mv
            where mv.status='ACTIVE' and mv.schema_version>=2
            order by mv.version desc limit 1
          )
        else (a.work_date+a.latest_end) at time zone (
          select mv.settings->>'timezone' from public.matrix_versions mv
          where mv.status='ACTIVE' and mv.schema_version>=2
          order by mv.version desc limit 1
        )
      end,'[)'
    )
  end,
  a.source,'availability:'||a.id::text,
  case when a.source in ('KADROMIERZ','MANAGER','SYSTEM') then 300 else 100 end,
  a.source='GRAFIK_PRO','ACTIVE',a.note,a.updated_by,a.updated_at
from public.employee_availability a
on conflict do nothing;

insert into public.employee_time_constraints_v2(
  id,employee_id,constraint_kind,time_range,source,source_record_key,priority,
  editable_by_employee,status,note,created_at,updated_at
)
select public.matrix_v2_stable_uuid('PREFERENCE_BLOCK:'||p.id::text),p.employee_id,
  p.preference_type,
  tstzrange(
    p.valid_from::timestamp at time zone (
      select mv.settings->>'timezone' from public.matrix_versions mv
      where mv.status='ACTIVE' and mv.schema_version>=2
      order by mv.version desc limit 1
    ),
    (p.valid_to+1)::timestamp at time zone (
      select mv.settings->>'timezone' from public.matrix_versions mv
      where mv.status='ACTIVE' and mv.schema_version>=2
      order by mv.version desc limit 1
    ),'[)'
  ),p.source,'preference:'||p.id::text,400,false,'ACTIVE',
  nullif(p.preference_value->>'note',''),p.created_at,p.created_at
from public.employee_preferences p
where p.status='ACTIVE' and p.preference_type in ('UNAVAILABLE','LEAVE','SICKNESS')
on conflict do nothing;

insert into public.matrix_scope_grants_v2(
  id,auth_user_id,app_role,role_logical_id,location_logical_id,active
)
select public.matrix_v2_stable_uuid('SCOPE_GRANT:'||up.id::text),up.auth_user_id,up.app_role,
  case when up.scope_role is null then null
    else public.matrix_v2_stable_uuid('ROLE:'||up.scope_role::text) end,
  case when up.scope_location is null then null
    else public.matrix_v2_stable_uuid('LOCATION:'||up.scope_location::text) end,
  true
from public.user_permissions up
on conflict do nothing;

insert into public.matrix_scenario_budgets_v2(
  id,matrix_version_id,scenario_id,budget_month,operation,amount_minor,currency,
  hard_limit,warning_percent,source_metadata
)
select public.matrix_v2_stable_uuid(
    'LEGACY_BUDGET:'||mv.id::text||':'||b.month::text
  ),mv.id,sc.id,b.month,'SET',round(b.amount*100)::bigint,
  upper(mv.settings->>'currency'),b.hard_limit,
  b.warning_percent,jsonb_build_object('source','LEGACY_MONTHLY_BUDGET')
from public.monthly_budgets b
join public.matrix_versions mv on mv.status in ('ACTIVE','DRAFT')
join public.matrix_scenarios_v2 sc
  on sc.matrix_version_id=mv.id and sc.code='BASE'
on conflict do nothing;

-- Keep every legacy availability/preference write visible to solver v2 during
-- the compatibility window. The legacy row remains the user-facing audit
-- source; the v2 constraint keeps its own supersession chain and is the only
-- representation read by immutable snapshots.
create schema if not exists solver_private;
revoke all on schema solver_private from public, anon, authenticated;

-- Scenario inheritance is deep for structured override objects. Defining the
-- primitive with the Matrix contract keeps publication validation and the
-- later snapshot builder on the same merge semantics.
create or replace function solver_private.jsonb_deep_merge_v2(
  p_base jsonb,p_override jsonb
)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_result jsonb:=case when jsonb_typeof(p_base)='object'
    then p_base else '{}'::jsonb end;
  v_key text;
  v_value jsonb;
begin
  if p_override is null then return v_result; end if;
  if jsonb_typeof(p_override)<>'object' then return p_override; end if;
  for v_key,v_value in select entry.key,entry.value
    from jsonb_each(p_override) entry
  loop
    if jsonb_typeof(v_result->v_key)='object'
      and jsonb_typeof(v_value)='object' then
      v_result:=jsonb_set(
        v_result,array[v_key],
        solver_private.jsonb_deep_merge_v2(v_result->v_key,v_value),true
      );
    else
      v_result:=jsonb_set(v_result,array[v_key],v_value,true);
    end if;
  end loop;
  return v_result;
end;
$$;

create or replace function solver_private.jsonb_deep_merge_array_v2(
  p_values jsonb[]
)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_result jsonb:='{}'::jsonb;
  v_value jsonb;
begin
  if p_values is null then return v_result; end if;
  foreach v_value in array p_values loop
    v_result:=solver_private.jsonb_deep_merge_v2(v_result,v_value);
  end loop;
  return v_result;
end;
$$;

revoke all on function solver_private.jsonb_deep_merge_v2(jsonb,jsonb),
  solver_private.jsonb_deep_merge_array_v2(jsonb[])
  from public,anon,authenticated;
grant execute on function solver_private.jsonb_deep_merge_v2(jsonb,jsonb),
  solver_private.jsonb_deep_merge_array_v2(jsonb[])
  to service_role;

create or replace function solver_private.replace_time_constraint_v2(
  p_employee_id uuid,
  p_kind text,
  p_time_range tstzrange,
  p_source text,
  p_source_record_key text,
  p_note text,
  p_actor uuid,
  p_updated_at timestamptz
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_existing public.employee_time_constraints_v2%rowtype;
begin
  select * into v_existing
  from public.employee_time_constraints_v2 c
  where c.source_record_key=p_source_record_key
  order by (c.status='ACTIVE') desc,c.created_at desc,c.id
  limit 1 for update;

  if p_kind is null then
    if v_existing.id is not null and v_existing.status='ACTIVE' then
      update public.employee_time_constraints_v2
      set status='REVOKED',revoked_at=coalesce(p_updated_at,now()),
        updated_at=coalesce(p_updated_at,now())
      where id=v_existing.id;
    end if;
    return;
  end if;

  if v_existing.id is not null and v_existing.status='ACTIVE'
    and v_existing.employee_id=p_employee_id
    and v_existing.constraint_kind=p_kind
    and v_existing.time_range=p_time_range
    and v_existing.source=coalesce(nullif(p_source,''),'GRAFIK_PRO')
    and v_existing.note is not distinct from nullif(p_note,'') then
    update public.employee_time_constraints_v2
    set updated_at=coalesce(p_updated_at,now()),created_by=coalesce(p_actor,created_by)
    where id=v_existing.id;
    return;
  end if;

  if v_existing.id is not null then
    update public.employee_time_constraints_v2
    set status='REVOKED',revoked_at=coalesce(p_updated_at,now()),
      updated_at=coalesce(p_updated_at,now()),
      source_record_key=p_source_record_key||':superseded:'||v_existing.id::text
    where id=v_existing.id;
  end if;

  insert into public.employee_time_constraints_v2(
    employee_id,constraint_kind,time_range,source,source_record_key,priority,
    editable_by_employee,status,note,supersedes_id,created_by,updated_at
  ) values(
    p_employee_id,p_kind,p_time_range,
    coalesce(nullif(p_source,''),'GRAFIK_PRO'),p_source_record_key,
    case when upper(coalesce(p_source,'')) in ('KADROMIERZ','MANAGER','SYSTEM')
      then 300 else 100 end,
    upper(coalesce(p_source,''))='GRAFIK_PRO','ACTIVE',nullif(p_note,''),
    v_existing.id,p_actor,coalesce(p_updated_at,now())
  );
end;
$$;

create or replace function solver_private.sync_employee_availability_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.employee_availability%rowtype;
  v_timezone text;
  v_range tstzrange;
  v_kind text;
begin
  if tg_op='DELETE' then
    v_row:=old;
    perform solver_private.replace_time_constraint_v2(
      v_row.employee_id,null,null,v_row.source,'availability:'||v_row.id::text,
      v_row.note,v_row.updated_by,now()
    );
    return old;
  end if;
  v_row:=new;
  select nullif(mv.settings->>'timezone','') into v_timezone
  from public.matrix_versions mv
  where mv.status='ACTIVE' and mv.schema_version>=2
  order by mv.version desc limit 1;
  if v_timezone is null or not exists(
    select 1 from pg_catalog.pg_timezone_names tz where tz.name=v_timezone
  ) then raise exception 'INVALID_MATRIX_TIMEZONE'; end if;

  v_kind:=case when v_row.available then 'AVAILABLE_WINDOW' else 'UNAVAILABLE' end;
  v_range:=case when not v_row.available then
    tstzrange(
      v_row.work_date::timestamp at time zone v_timezone,
      (v_row.work_date+1)::timestamp at time zone v_timezone,'[)'
    )
  else
    tstzrange(
      (v_row.work_date+coalesce(v_row.earliest_start,time '00:00'))
        at time zone v_timezone,
      case
        when v_row.latest_end is null then
          (v_row.work_date+1)::timestamp at time zone v_timezone
        when v_row.latest_end<=coalesce(v_row.earliest_start,time '00:00') then
          ((v_row.work_date+1)+v_row.latest_end) at time zone v_timezone
        else (v_row.work_date+v_row.latest_end) at time zone v_timezone
      end,'[)'
    )
  end;
  perform solver_private.replace_time_constraint_v2(
    v_row.employee_id,v_kind,v_range,v_row.source,
    'availability:'||v_row.id::text,v_row.note,v_row.updated_by,v_row.updated_at
  );
  return new;
end;
$$;

drop trigger if exists employee_availability_sync_v2 on public.employee_availability;
create trigger employee_availability_sync_v2
after insert or update or delete on public.employee_availability
for each row execute function solver_private.sync_employee_availability_v2();

create or replace function solver_private.sync_employee_preference_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.employee_preferences%rowtype;
  v_timezone text;
  v_kind text;
  v_range tstzrange;
begin
  v_row:=case when tg_op='DELETE' then old else new end;
  v_kind:=case
    when tg_op<>'DELETE' and v_row.status='ACTIVE'
      and v_row.preference_type in ('UNAVAILABLE','LEAVE','SICKNESS')
    then v_row.preference_type::text else null end;
  if v_kind is not null then
    select nullif(mv.settings->>'timezone','') into v_timezone
    from public.matrix_versions mv
    where mv.status='ACTIVE' and mv.schema_version>=2
    order by mv.version desc limit 1;
    if v_timezone is null or not exists(
      select 1 from pg_catalog.pg_timezone_names tz where tz.name=v_timezone
    ) then raise exception 'INVALID_MATRIX_TIMEZONE'; end if;
    v_range:=tstzrange(
      v_row.valid_from::timestamp at time zone v_timezone,
      (v_row.valid_to+1)::timestamp at time zone v_timezone,'[)'
    );
  end if;
  perform solver_private.replace_time_constraint_v2(
    v_row.employee_id,v_kind,v_range,v_row.source,
    'preference:'||v_row.id::text,v_row.preference_value->>'note',
    auth.uid(),coalesce(v_row.created_at,now())
  );
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;

drop trigger if exists employee_preference_sync_v2 on public.employee_preferences;
create trigger employee_preference_sync_v2
after insert or update or delete on public.employee_preferences
for each row execute function solver_private.sync_employee_preference_v2();

revoke all on function solver_private.replace_time_constraint_v2(
  uuid,text,tstzrange,text,text,text,uuid,timestamptz
) from public, anon, authenticated;
revoke all on function solver_private.sync_employee_availability_v2()
  from public, anon, authenticated;
revoke all on function solver_private.sync_employee_preference_v2()
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- RLS and explicit Data API grants.
-- ---------------------------------------------------------------------------

do $$
declare t text;
begin
  foreach t in array array[
    'matrix_roles_v2','matrix_locations_v2','matrix_duties_v2',
    'matrix_shift_templates_v2','matrix_role_duties_v2','matrix_scenarios_v2',
    'matrix_staffing_rules_v2','matrix_strategies_v2',
    'matrix_strategy_objectives_v2','matrix_scenario_strategies_v2',
    'matrix_employee_roles_v2','matrix_employee_locations_v2',
    'matrix_employee_duties_v2','employee_time_constraints_v2',
    'matrix_pay_rules_v2','matrix_pay_rule_roles_v2',
    'matrix_pay_rule_duties_v2','matrix_pay_rule_locations_v2',
    'matrix_pay_rule_shifts_v2','matrix_scenario_pay_rule_overrides_v2',
    'matrix_scenario_budgets_v2','employee_pay_rates_v2',
    'matrix_scope_grants_v2','solver_feature_flags'
  ] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all privileges on table public.%I from public, anon, authenticated',t);
    execute format('grant select on table public.%I to authenticated',t);
  end loop;
end $$;

do $$
declare t text;
begin
  foreach t in array array[
    'matrix_roles_v2','matrix_locations_v2','matrix_duties_v2',
    'matrix_shift_templates_v2','matrix_role_duties_v2','matrix_scenarios_v2',
    'matrix_staffing_rules_v2','matrix_strategies_v2',
    'matrix_strategy_objectives_v2','matrix_scenario_strategies_v2'
  ] loop
    execute format('drop policy if exists matrix_v2_read on public.%I',t);
    execute format(
      'create policy matrix_v2_read on public.%I for select to authenticated '
      ||'using (exists(select 1 from public.matrix_versions mv '
      ||'where mv.id=matrix_version_id and (mv.status=''ACTIVE'' '
      ||'or public.has_app_role(''OWNER'') or public.has_app_role(''ADMIN''))))',t
    );
    execute format('drop policy if exists matrix_v2_admin_write on public.%I',t);
    execute format(
      'create policy matrix_v2_admin_write on public.%I for all to authenticated '
      ||'using ((public.has_app_role(''OWNER'') or public.has_app_role(''ADMIN'')) '
      ||'and exists(select 1 from public.matrix_versions mv '
      ||'where mv.id=matrix_version_id and mv.status=''DRAFT'')) '
      ||'with check ((public.has_app_role(''OWNER'') or public.has_app_role(''ADMIN'')) '
      ||'and exists(select 1 from public.matrix_versions mv '
      ||'where mv.id=matrix_version_id and mv.status=''DRAFT''))',t
    );
  end loop;
end $$;

do $$
declare t text;
begin
  foreach t in array array[
    'matrix_employee_roles_v2','matrix_employee_locations_v2','matrix_employee_duties_v2'
  ] loop
    execute format('drop policy if exists workforce_v2_read on public.%I',t);
    execute format(
      'create policy workforce_v2_read on public.%I for select to authenticated '
      ||'using ((public.can_manage_plans() or public.has_app_role(''HR_FINANCE'') '
      ||'or exists(select 1 from public.employees e '
      ||'where e.id=employee_id and e.auth_user_id=(select auth.uid()))) '
      ||'and exists(select 1 from public.matrix_versions mv '
      ||'where mv.id=matrix_version_id and (mv.status=''ACTIVE'' '
      ||'or public.has_app_role(''OWNER'') or public.has_app_role(''ADMIN''))))',t
    );
    execute format('drop policy if exists workforce_v2_admin_write on public.%I',t);
    execute format(
      'create policy workforce_v2_admin_write on public.%I for all to authenticated '
      ||'using ((public.has_app_role(''OWNER'') or public.has_app_role(''ADMIN'') '
      ||'or public.has_app_role(''HR_FINANCE'')) '
      ||'and exists(select 1 from public.matrix_versions mv '
      ||'where mv.id=matrix_version_id and mv.status=''DRAFT'')) '
      ||'with check ((public.has_app_role(''OWNER'') or public.has_app_role(''ADMIN'') '
      ||'or public.has_app_role(''HR_FINANCE'')) '
      ||'and exists(select 1 from public.matrix_versions mv '
      ||'where mv.id=matrix_version_id and mv.status=''DRAFT''))',t
    );
  end loop;
end $$;

do $$
declare t text;
begin
  foreach t in array array[
    'matrix_pay_rules_v2','matrix_pay_rule_roles_v2','matrix_pay_rule_duties_v2',
    'matrix_pay_rule_locations_v2','matrix_pay_rule_shifts_v2',
    'matrix_scenario_pay_rule_overrides_v2','matrix_scenario_budgets_v2'
  ] loop
    execute format('drop policy if exists finance_matrix_v2_read on public.%I',t);
    execute format(
      'create policy finance_matrix_v2_read on public.%I for select to authenticated '
      ||'using ((public.has_app_role(''OWNER'') or public.has_app_role(''ADMIN'') '
      ||'or public.has_app_role(''HR_FINANCE'')) and exists('
      ||'select 1 from public.matrix_versions mv where mv.id=matrix_version_id '
      ||'and (mv.status=''ACTIVE'' or public.has_app_role(''OWNER'') '
      ||'or public.has_app_role(''ADMIN''))))',t
    );
    execute format('drop policy if exists finance_matrix_v2_write on public.%I',t);
    execute format(
      'create policy finance_matrix_v2_write on public.%I for all to authenticated '
      ||'using ((public.has_app_role(''OWNER'') or public.has_app_role(''ADMIN'') '
      ||'or public.has_app_role(''HR_FINANCE'')) '
      ||'and exists(select 1 from public.matrix_versions mv '
      ||'where mv.id=matrix_version_id and mv.status=''DRAFT'')) '
      ||'with check ((public.has_app_role(''OWNER'') or public.has_app_role(''ADMIN'') '
      ||'or public.has_app_role(''HR_FINANCE'')) '
      ||'and exists(select 1 from public.matrix_versions mv '
      ||'where mv.id=matrix_version_id and mv.status=''DRAFT''))',t
    );
  end loop;
end $$;

-- The legacy policy exposed DRAFT/ARCHIVED version metadata to every account.
-- Matrix v2 closes that direct REST path while keeping ACTIVE metadata readable.
drop policy if exists matrix_read on public.matrix_versions;
create policy matrix_read on public.matrix_versions for select to authenticated
using (
  status='ACTIVE' or public.has_app_role('OWNER') or public.has_app_role('ADMIN')
);

-- The compatibility projection must obey the same publication boundary as
-- Matrix v2. Legacy policies used USING(true), and the old owner policies also
-- allowed direct DML that bypassed validation, hashing and audit RPCs.
revoke insert, update, delete on table
  public.matrix_versions,
  public.matrix_roles,
  public.matrix_locations,
  public.matrix_shift_templates,
  public.matrix_functions,
  public.matrix_role_functions,
  public.matrix_demand,
  public.matrix_employee_roles,
  public.matrix_scenarios,
  public.optimizer_profiles
from public, anon, authenticated;

drop policy if exists matrix_owner_write on public.matrix_versions;
drop policy if exists matrix_scenarios_write on public.matrix_scenarios;
drop policy if exists optimizer_profiles_manage on public.optimizer_profiles;

do $$
declare t text;
begin
  foreach t in array array[
    'matrix_roles','matrix_locations','matrix_shift_templates','matrix_functions'
  ] loop
    execute format('drop policy if exists matrix_read on public.%I',t);
    execute format(
      'create policy matrix_read on public.%I for select to authenticated '
      ||'using (exists(select 1 from public.matrix_versions mv '
      ||'where mv.id=matrix_version_id and (mv.status=''ACTIVE'' '
      ||'or public.has_app_role(''OWNER'') or public.has_app_role(''ADMIN''))))',t
    );
    execute format('drop policy if exists matrix_owner_write on public.%I',t);
  end loop;
end $$;

drop policy if exists matrix_read on public.matrix_role_functions;
create policy matrix_read on public.matrix_role_functions
for select to authenticated using (
  exists(
    select 1 from public.matrix_roles role_row
    join public.matrix_versions mv on mv.id=role_row.matrix_version_id
    where role_row.id=role_id and (
      mv.status='ACTIVE' or public.has_app_role('OWNER')
      or public.has_app_role('ADMIN')
    )
  )
);
drop policy if exists matrix_owner_write on public.matrix_role_functions;

drop policy if exists matrix_read on public.matrix_demand;
create policy matrix_read on public.matrix_demand
for select to authenticated using (
  exists(
    select 1 from public.matrix_shift_templates shift_row
    join public.matrix_versions mv on mv.id=shift_row.matrix_version_id
    where shift_row.id=shift_template_id and (
      mv.status='ACTIVE' or public.has_app_role('OWNER')
      or public.has_app_role('ADMIN')
    )
  )
);
drop policy if exists matrix_owner_write on public.matrix_demand;

drop policy if exists matrix_scenarios_read on public.matrix_scenarios;
create policy matrix_scenarios_read on public.matrix_scenarios
for select to authenticated using (
  exists(
    select 1 from public.matrix_versions mv
    where mv.id=matrix_version_id and (
      mv.status='ACTIVE' or public.has_app_role('OWNER')
      or public.has_app_role('ADMIN')
    )
  )
);

drop policy if exists optimizer_profiles_read on public.optimizer_profiles;
create policy optimizer_profiles_read on public.optimizer_profiles
for select to authenticated using (
  public.can_manage_plans() and exists(
    select 1 from public.matrix_versions mv
    where mv.id=matrix_version_id and (
      mv.status='ACTIVE' or public.has_app_role('OWNER')
      or public.has_app_role('ADMIN')
    )
  )
);

drop policy if exists matrix_employee_roles_read on public.matrix_employee_roles;
create policy matrix_employee_roles_read on public.matrix_employee_roles
for select to authenticated using (
  (
    public.can_manage_plans()
    or exists(select 1 from public.employees employee
      where employee.id=employee_id
        and employee.auth_user_id=(select auth.uid()))
  ) and exists(
    select 1 from public.matrix_versions mv
    where mv.id=matrix_version_id and (
      mv.status='ACTIVE' or public.has_app_role('OWNER')
      or public.has_app_role('ADMIN')
    )
  )
);

drop policy if exists employee_time_constraints_v2_read
  on public.employee_time_constraints_v2;
create policy employee_time_constraints_v2_read
on public.employee_time_constraints_v2 for select to authenticated
using (
  public.can_manage_plans() or public.has_app_role('HR_FINANCE')
  or exists(select 1 from public.employees e
    where e.id=employee_id and e.auth_user_id=(select auth.uid()))
);

drop policy if exists employee_time_constraints_v2_insert
  on public.employee_time_constraints_v2;
create policy employee_time_constraints_v2_insert
on public.employee_time_constraints_v2 for insert to authenticated
with check (
  public.can_manage_plans() or public.has_app_role('HR_FINANCE')
  or (
    source='GRAFIK_PRO' and editable_by_employee
    and constraint_kind in ('AVAILABLE_WINDOW','UNAVAILABLE')
    and created_by=(select auth.uid())
    and exists(select 1 from public.employees e
      where e.id=employee_id and e.auth_user_id=(select auth.uid()))
  )
);

drop policy if exists employee_time_constraints_v2_update
  on public.employee_time_constraints_v2;
create policy employee_time_constraints_v2_update
on public.employee_time_constraints_v2 for update to authenticated
using (
  public.can_manage_plans() or public.has_app_role('HR_FINANCE')
  or (source='GRAFIK_PRO' and editable_by_employee and created_by=(select auth.uid())
    and exists(select 1 from public.employees e
      where e.id=employee_id and e.auth_user_id=(select auth.uid())))
)
with check (
  public.can_manage_plans() or public.has_app_role('HR_FINANCE')
  or (source='GRAFIK_PRO' and editable_by_employee and created_by=(select auth.uid())
    and constraint_kind in ('AVAILABLE_WINDOW','UNAVAILABLE')
    and exists(select 1 from public.employees e
      where e.id=employee_id and e.auth_user_id=(select auth.uid())))
);

drop policy if exists employee_pay_rates_v2_read on public.employee_pay_rates_v2;
create policy employee_pay_rates_v2_read
on public.employee_pay_rates_v2 for select to authenticated
using (
  public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  or public.has_app_role('HR_FINANCE')
);

drop policy if exists employee_pay_rates_v2_write on public.employee_pay_rates_v2;
create policy employee_pay_rates_v2_write
on public.employee_pay_rates_v2 for all to authenticated
using (
  public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  or public.has_app_role('HR_FINANCE')
)
with check (
  public.has_app_role('OWNER') or public.has_app_role('ADMIN')
  or public.has_app_role('HR_FINANCE')
);

drop policy if exists matrix_scope_grants_v2_read on public.matrix_scope_grants_v2;
create policy matrix_scope_grants_v2_read
on public.matrix_scope_grants_v2 for select to authenticated
using (
  auth_user_id=(select auth.uid())
  or public.has_app_role('OWNER') or public.has_app_role('ADMIN')
);

drop policy if exists matrix_scope_grants_v2_write on public.matrix_scope_grants_v2;
create policy matrix_scope_grants_v2_write
on public.matrix_scope_grants_v2 for all to authenticated
using (public.has_app_role('OWNER') or public.has_app_role('ADMIN'))
with check (public.has_app_role('OWNER') or public.has_app_role('ADMIN'));

drop policy if exists solver_feature_flags_read on public.solver_feature_flags;
create policy solver_feature_flags_read
on public.solver_feature_flags for select to authenticated using (true);

drop policy if exists solver_feature_flags_write on public.solver_feature_flags;
create policy solver_feature_flags_write
on public.solver_feature_flags for all to authenticated
using (public.has_app_role('OWNER') or public.has_app_role('ADMIN'))
with check (public.has_app_role('OWNER') or public.has_app_role('ADMIN'));

-- ---------------------------------------------------------------------------
-- Draft lifecycle. Every clone is set-based and preserves logical IDs.
-- ---------------------------------------------------------------------------

create or replace function public.matrix_v2_create_draft(p_name text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_active public.matrix_versions%rowtype;
  v_draft_id uuid;
  v_version integer;
begin
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));

  select mv.id into v_draft_id
  from public.matrix_versions mv
  where mv.status='DRAFT' and mv.schema_version>=2
  order by mv.version desc limit 1;
  if v_draft_id is not null then return v_draft_id; end if;

  select * into v_active from public.matrix_versions mv
  where mv.status='ACTIVE' and mv.schema_version>=2
  order by mv.version desc limit 1;
  select coalesce(max(mv.version),0)+1 into v_version from public.matrix_versions mv;

  insert into public.matrix_versions(
    version,name,status,effective_from,settings,created_by,schema_version,base_version_id
  ) values(
    v_version,coalesce(nullif(trim(p_name),''),'Matrix v2 v'||v_version),'DRAFT',
    coalesce(v_active.effective_from,current_date),
    coalesce(v_active.settings,'{}'::jsonb),auth.uid(),2,v_active.id
  ) returning id into v_draft_id;

  if v_active.id is null then return v_draft_id; end if;

  -- Keep the last legacy-compatible projection beside Matrix v2. Until the
  -- feature flag leaves ALPHA15 this prevents publishing a v2 draft from
  -- activating a Matrix version with empty legacy tables.
  insert into public.matrix_roles(matrix_version_id,code,name,color,sort_order,active)
  select v_draft_id,r.code,r.name,r.color,r.sort_order,r.active
  from public.matrix_roles r where r.matrix_version_id=v_active.id;

  insert into public.matrix_locations(matrix_version_id,code,name,active)
  select v_draft_id,l.code,l.name,l.active
  from public.matrix_locations l where l.matrix_version_id=v_active.id;

  insert into public.matrix_functions(matrix_version_id,code,name,description,active)
  select v_draft_id,f.code,f.name,f.description,f.active
  from public.matrix_functions f where f.matrix_version_id=v_active.id;

  insert into public.matrix_shift_templates(
    matrix_version_id,location_id,code,name,starts_at,ends_at,day_mask,sort_order,active
  )
  select v_draft_id,nl.id,s.code,s.name,s.starts_at,s.ends_at,s.day_mask,
    s.sort_order,s.active
  from public.matrix_shift_templates s
  join public.matrix_locations old_location on old_location.id=s.location_id
  join public.matrix_locations nl
    on nl.matrix_version_id=v_draft_id and nl.code=old_location.code
  where s.matrix_version_id=v_active.id;

  insert into public.matrix_role_functions(role_id,function_id,assignment_mode)
  select nr.id,nf.id,rf.assignment_mode
  from public.matrix_role_functions rf
  join public.matrix_roles old_role on old_role.id=rf.role_id
  join public.matrix_functions old_function on old_function.id=rf.function_id
  join public.matrix_roles nr
    on nr.matrix_version_id=v_draft_id and nr.code=old_role.code
  join public.matrix_functions nf
    on nf.matrix_version_id=v_draft_id and nf.code=old_function.code
  where old_role.matrix_version_id=v_active.id
    and old_function.matrix_version_id=v_active.id;

  insert into public.matrix_demand(
    shift_template_id,role_id,function_id,scenario_code,required_count
  )
  select nsh.id,nr.id,nf.id,d.scenario_code,d.required_count
  from public.matrix_demand d
  join public.matrix_shift_templates old_shift on old_shift.id=d.shift_template_id
  join public.matrix_locations old_location on old_location.id=old_shift.location_id
  join public.matrix_roles old_role on old_role.id=d.role_id
  left join public.matrix_functions old_function on old_function.id=d.function_id
  join public.matrix_locations nl
    on nl.matrix_version_id=v_draft_id and nl.code=old_location.code
  join public.matrix_shift_templates nsh
    on nsh.matrix_version_id=v_draft_id and nsh.location_id=nl.id and nsh.code=old_shift.code
  join public.matrix_roles nr
    on nr.matrix_version_id=v_draft_id and nr.code=old_role.code
  left join public.matrix_functions nf
    on nf.matrix_version_id=v_draft_id and nf.code=old_function.code
  where old_shift.matrix_version_id=v_active.id
    and old_role.matrix_version_id=v_active.id
    and (old_function.id is null
      or old_function.matrix_version_id=v_active.id);

  insert into public.matrix_employee_roles(
    matrix_version_id,employee_id,role_id,is_primary,can_lead
  )
  select v_draft_id,er.employee_id,nr.id,er.is_primary,er.can_lead
  from public.matrix_employee_roles er
  join public.matrix_roles old_role on old_role.id=er.role_id
  join public.matrix_roles nr
    on nr.matrix_version_id=v_draft_id and nr.code=old_role.code
  where er.matrix_version_id=v_active.id;

  insert into public.matrix_scenarios(
    matrix_version_id,code,name,description,color,active,sort_order
  )
  select v_draft_id,s.code,s.name,s.description,s.color,s.active,s.sort_order
  from public.matrix_scenarios s where s.matrix_version_id=v_active.id;

  insert into public.optimizer_profiles(
    matrix_version_id,code,name,weights,population_size,generations,elite_count,
    mutation_rate,alternatives_count,active
  )
  select v_draft_id,p.code,p.name,p.weights,p.population_size,p.generations,
    p.elite_count,p.mutation_rate,p.alternatives_count,p.active
  from public.optimizer_profiles p where p.matrix_version_id=v_active.id;

  insert into public.matrix_roles_v2(
    id,matrix_version_id,logical_id,code,name,color,sort_order,active
  ) select gen_random_uuid(),v_draft_id,r.logical_id,r.code,r.name,r.color,r.sort_order,r.active
    from public.matrix_roles_v2 r where r.matrix_version_id=v_active.id;

  insert into public.matrix_locations_v2(
    id,matrix_version_id,logical_id,code,name,timezone,sort_order,active
  ) select gen_random_uuid(),v_draft_id,l.logical_id,l.code,l.name,l.timezone,l.sort_order,l.active
    from public.matrix_locations_v2 l where l.matrix_version_id=v_active.id;

  insert into public.matrix_duties_v2(
    id,matrix_version_id,logical_id,code,name,description,color,sort_order,active
  ) select gen_random_uuid(),v_draft_id,d.logical_id,d.code,d.name,d.description,d.color,d.sort_order,d.active
    from public.matrix_duties_v2 d where d.matrix_version_id=v_active.id;

  insert into public.matrix_shift_templates_v2(
    id,matrix_version_id,logical_id,location_id,code,name,starts_at,ends_at,
    ends_next_day,day_mask,sort_order,active
  )
  select gen_random_uuid(),v_draft_id,s.logical_id,nl.id,s.code,s.name,s.starts_at,s.ends_at,
    s.ends_next_day,s.day_mask,s.sort_order,s.active
  from public.matrix_shift_templates_v2 s
  join public.matrix_locations_v2 ol on ol.id=s.location_id
  join public.matrix_locations_v2 nl
    on nl.matrix_version_id=v_draft_id and nl.logical_id=ol.logical_id
  where s.matrix_version_id=v_active.id;

  insert into public.matrix_role_duties_v2(
    id,matrix_version_id,role_id,duty_id,assignment_mode,minimum_count,active
  )
  select gen_random_uuid(),v_draft_id,nr.id,nd.id,rd.assignment_mode,
    rd.minimum_count,rd.active
  from public.matrix_role_duties_v2 rd
  join public.matrix_roles_v2 orole on orole.id=rd.role_id
  join public.matrix_duties_v2 od on od.id=rd.duty_id
  join public.matrix_roles_v2 nr
    on nr.matrix_version_id=v_draft_id and nr.logical_id=orole.logical_id
  join public.matrix_duties_v2 nd
    on nd.matrix_version_id=v_draft_id and nd.logical_id=od.logical_id
  where rd.matrix_version_id=v_active.id;

  insert into public.matrix_scenarios_v2(
    id,matrix_version_id,logical_id,code,name,description,color,is_default,active,
    sort_order,valid_from,valid_to,settings_overrides
  )
  select gen_random_uuid(),v_draft_id,s.logical_id,s.code,s.name,s.description,s.color,
    s.is_default,s.active,s.sort_order,s.valid_from,s.valid_to,s.settings_overrides
  from public.matrix_scenarios_v2 s where s.matrix_version_id=v_active.id;

  update public.matrix_scenarios_v2 child
  set parent_scenario_id=np.id
  from public.matrix_scenarios_v2 old_child
  join public.matrix_scenarios_v2 old_parent on old_parent.id=old_child.parent_scenario_id
  join public.matrix_scenarios_v2 np
    on np.matrix_version_id=v_draft_id and np.logical_id=old_parent.logical_id
  where child.matrix_version_id=v_draft_id
    and child.logical_id=old_child.logical_id
    and old_child.matrix_version_id=v_active.id;

  insert into public.matrix_staffing_rules_v2(
    id,matrix_version_id,scenario_id,shift_template_id,role_id,duty_id,
    operation,count_value,multiplier_basis_points,active,source_metadata
  )
  select gen_random_uuid(),v_draft_id,nsc.id,nsh.id,nr.id,nd.id,sr.operation,
    sr.count_value,sr.multiplier_basis_points,sr.active,sr.source_metadata
  from public.matrix_staffing_rules_v2 sr
  join public.matrix_scenarios_v2 osc on osc.id=sr.scenario_id
  join public.matrix_shift_templates_v2 osh on osh.id=sr.shift_template_id
  join public.matrix_roles_v2 orole on orole.id=sr.role_id
  left join public.matrix_duties_v2 od on od.id=sr.duty_id
  join public.matrix_scenarios_v2 nsc
    on nsc.matrix_version_id=v_draft_id and nsc.logical_id=osc.logical_id
  join public.matrix_shift_templates_v2 nsh
    on nsh.matrix_version_id=v_draft_id and nsh.logical_id=osh.logical_id
  join public.matrix_roles_v2 nr
    on nr.matrix_version_id=v_draft_id and nr.logical_id=orole.logical_id
  left join public.matrix_duties_v2 nd
    on nd.matrix_version_id=v_draft_id and nd.logical_id=od.logical_id
  where sr.matrix_version_id=v_active.id;

  insert into public.matrix_strategies_v2(
    id,matrix_version_id,logical_id,code,name,description,solver_code,solver_options,
    legacy_weights,sort_order,active
  )
  select gen_random_uuid(),v_draft_id,s.logical_id,s.code,s.name,s.description,
    s.solver_code,s.solver_options-array[
      'legacyPopulationSize','legacyGenerations','legacyMutationRate'
    ],s.legacy_weights,s.sort_order,s.active
  from public.matrix_strategies_v2 s where s.matrix_version_id=v_active.id;

  insert into public.matrix_strategy_objectives_v2(
    id,matrix_version_id,strategy_id,tier,sort_order,metric_code,direction,
    weight,tolerance,parameters,active
  )
  select gen_random_uuid(),v_draft_id,ns.id,o.tier,o.sort_order,o.metric_code,
    o.direction,o.weight,o.tolerance,o.parameters,o.active
  from public.matrix_strategy_objectives_v2 o
  join public.matrix_strategies_v2 os on os.id=o.strategy_id
  join public.matrix_strategies_v2 ns
    on ns.matrix_version_id=v_draft_id and ns.logical_id=os.logical_id
  where o.matrix_version_id=v_active.id;

  insert into public.matrix_scenario_strategies_v2(
    id,matrix_version_id,scenario_id,strategy_id,sort_order,active,
    objective_overrides,solver_overrides
  )
  select gen_random_uuid(),v_draft_id,nsc.id,nst.id,ss.sort_order,ss.active,
    ss.objective_overrides,ss.solver_overrides
  from public.matrix_scenario_strategies_v2 ss
  join public.matrix_scenarios_v2 osc on osc.id=ss.scenario_id
  join public.matrix_strategies_v2 ost on ost.id=ss.strategy_id
  join public.matrix_scenarios_v2 nsc
    on nsc.matrix_version_id=v_draft_id and nsc.logical_id=osc.logical_id
  join public.matrix_strategies_v2 nst
    on nst.matrix_version_id=v_draft_id and nst.logical_id=ost.logical_id
  where ss.matrix_version_id=v_active.id;

  insert into public.matrix_employee_roles_v2(
    id,matrix_version_id,employee_id,role_id,is_primary,can_lead,active,valid_from,valid_to
  )
  select gen_random_uuid(),v_draft_id,er.employee_id,nr.id,er.is_primary,er.can_lead,
    er.active,er.valid_from,er.valid_to
  from public.matrix_employee_roles_v2 er
  join public.matrix_roles_v2 old_role on old_role.id=er.role_id
  join public.matrix_roles_v2 nr
    on nr.matrix_version_id=v_draft_id and nr.logical_id=old_role.logical_id
  where er.matrix_version_id=v_active.id;

  insert into public.matrix_employee_locations_v2(
    id,matrix_version_id,employee_id,location_id,standard_allowed,overtime_allowed,
    home_location,active,valid_from,valid_to
  )
  select gen_random_uuid(),v_draft_id,el.employee_id,nl.id,el.standard_allowed,
    el.overtime_allowed,el.home_location,el.active,el.valid_from,el.valid_to
  from public.matrix_employee_locations_v2 el
  join public.matrix_locations_v2 old_location on old_location.id=el.location_id
  join public.matrix_locations_v2 nl
    on nl.matrix_version_id=v_draft_id and nl.logical_id=old_location.logical_id
  where el.matrix_version_id=v_active.id;

  insert into public.matrix_employee_duties_v2(
    id,matrix_version_id,employee_id,duty_id,role_id,location_id,active,
    valid_from,valid_to,source
  )
  select gen_random_uuid(),v_draft_id,ed.employee_id,nd.id,nr.id,nl.id,ed.active,
    ed.valid_from,ed.valid_to,ed.source
  from public.matrix_employee_duties_v2 ed
  join public.matrix_duties_v2 old_duty on old_duty.id=ed.duty_id
  left join public.matrix_roles_v2 old_role on old_role.id=ed.role_id
  left join public.matrix_locations_v2 old_location on old_location.id=ed.location_id
  join public.matrix_duties_v2 nd
    on nd.matrix_version_id=v_draft_id and nd.logical_id=old_duty.logical_id
  left join public.matrix_roles_v2 nr
    on nr.matrix_version_id=v_draft_id and nr.logical_id=old_role.logical_id
  left join public.matrix_locations_v2 nl
    on nl.matrix_version_id=v_draft_id and nl.logical_id=old_location.logical_id
  where ed.matrix_version_id=v_active.id;

  insert into public.matrix_pay_rules_v2(
    id,matrix_version_id,logical_id,code,name,description,calculation_method,
    amount_minor,rate_minor_per_hour,percent_basis_points,multiplier_basis_points,
    threshold_minutes,currency,priority,stacking_group,stacking_mode,day_mask,
    local_start,local_end,ends_next_day,valid_from,valid_to,condition_expression,
    formula_expression,active
  )
  select gen_random_uuid(),v_draft_id,p.logical_id,p.code,p.name,p.description,
    p.calculation_method,p.amount_minor,p.rate_minor_per_hour,p.percent_basis_points,
    p.multiplier_basis_points,p.threshold_minutes,p.currency,p.priority,p.stacking_group,
    p.stacking_mode,p.day_mask,p.local_start,p.local_end,p.ends_next_day,p.valid_from,
    p.valid_to,p.condition_expression,p.formula_expression,p.active
  from public.matrix_pay_rules_v2 p where p.matrix_version_id=v_active.id;

  insert into public.matrix_pay_rule_roles_v2(matrix_version_id,pay_rule_id,role_id)
  select v_draft_id,np.id,nr.id
  from public.matrix_pay_rule_roles_v2 x
  join public.matrix_pay_rules_v2 op on op.id=x.pay_rule_id
  join public.matrix_roles_v2 old_role on old_role.id=x.role_id
  join public.matrix_pay_rules_v2 np
    on np.matrix_version_id=v_draft_id and np.logical_id=op.logical_id
  join public.matrix_roles_v2 nr
    on nr.matrix_version_id=v_draft_id and nr.logical_id=old_role.logical_id
  where x.matrix_version_id=v_active.id;

  insert into public.matrix_pay_rule_duties_v2(matrix_version_id,pay_rule_id,duty_id,match_mode)
  select v_draft_id,np.id,nd.id,x.match_mode
  from public.matrix_pay_rule_duties_v2 x
  join public.matrix_pay_rules_v2 op on op.id=x.pay_rule_id
  join public.matrix_duties_v2 old_duty on old_duty.id=x.duty_id
  join public.matrix_pay_rules_v2 np
    on np.matrix_version_id=v_draft_id and np.logical_id=op.logical_id
  join public.matrix_duties_v2 nd
    on nd.matrix_version_id=v_draft_id and nd.logical_id=old_duty.logical_id
  where x.matrix_version_id=v_active.id;

  insert into public.matrix_pay_rule_locations_v2(matrix_version_id,pay_rule_id,location_id)
  select v_draft_id,np.id,nl.id
  from public.matrix_pay_rule_locations_v2 x
  join public.matrix_pay_rules_v2 op on op.id=x.pay_rule_id
  join public.matrix_locations_v2 old_location on old_location.id=x.location_id
  join public.matrix_pay_rules_v2 np
    on np.matrix_version_id=v_draft_id and np.logical_id=op.logical_id
  join public.matrix_locations_v2 nl
    on nl.matrix_version_id=v_draft_id and nl.logical_id=old_location.logical_id
  where x.matrix_version_id=v_active.id;

  insert into public.matrix_pay_rule_shifts_v2(matrix_version_id,pay_rule_id,shift_template_id)
  select v_draft_id,np.id,nsh.id
  from public.matrix_pay_rule_shifts_v2 x
  join public.matrix_pay_rules_v2 op on op.id=x.pay_rule_id
  join public.matrix_shift_templates_v2 old_shift on old_shift.id=x.shift_template_id
  join public.matrix_pay_rules_v2 np
    on np.matrix_version_id=v_draft_id and np.logical_id=op.logical_id
  join public.matrix_shift_templates_v2 nsh
    on nsh.matrix_version_id=v_draft_id and nsh.logical_id=old_shift.logical_id
  where x.matrix_version_id=v_active.id;

  insert into public.matrix_scenario_pay_rule_overrides_v2(
    id,matrix_version_id,scenario_id,pay_rule_id,enabled,amount_minor,
    rate_minor_per_hour,percent_basis_points,multiplier_basis_points,formula_expression
  )
  select gen_random_uuid(),v_draft_id,nsc.id,np.id,x.enabled,x.amount_minor,
    x.rate_minor_per_hour,x.percent_basis_points,x.multiplier_basis_points,x.formula_expression
  from public.matrix_scenario_pay_rule_overrides_v2 x
  join public.matrix_scenarios_v2 osc on osc.id=x.scenario_id
  join public.matrix_pay_rules_v2 op on op.id=x.pay_rule_id
  join public.matrix_scenarios_v2 nsc
    on nsc.matrix_version_id=v_draft_id and nsc.logical_id=osc.logical_id
  join public.matrix_pay_rules_v2 np
    on np.matrix_version_id=v_draft_id and np.logical_id=op.logical_id
  where x.matrix_version_id=v_active.id;

  insert into public.matrix_scenario_budgets_v2(
    id,matrix_version_id,scenario_id,budget_month,location_id,role_id,duty_id,
    operation,amount_minor,multiplier_basis_points,currency,hard_limit,
    warning_percent,source_metadata
  )
  select gen_random_uuid(),v_draft_id,nsc.id,b.budget_month,nl.id,nr.id,nd.id,
    b.operation,b.amount_minor,b.multiplier_basis_points,b.currency,b.hard_limit,
    b.warning_percent,b.source_metadata
  from public.matrix_scenario_budgets_v2 b
  join public.matrix_scenarios_v2 osc on osc.id=b.scenario_id
  left join public.matrix_locations_v2 ol on ol.id=b.location_id
  left join public.matrix_roles_v2 orole on orole.id=b.role_id
  left join public.matrix_duties_v2 od on od.id=b.duty_id
  join public.matrix_scenarios_v2 nsc
    on nsc.matrix_version_id=v_draft_id and nsc.logical_id=osc.logical_id
  left join public.matrix_locations_v2 nl
    on nl.matrix_version_id=v_draft_id and nl.logical_id=ol.logical_id
  left join public.matrix_roles_v2 nr
    on nr.matrix_version_id=v_draft_id and nr.logical_id=orole.logical_id
  left join public.matrix_duties_v2 nd
    on nd.matrix_version_id=v_draft_id and nd.logical_id=od.logical_id
  where b.matrix_version_id=v_active.id;

  return v_draft_id;
end;
$$;

create or replace function public.matrix_v2_can_manage_employee(p_employee_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE')
    or exists(select 1 from public.employees self
      where self.id=p_employee_id and self.auth_user_id=auth.uid())
    or exists(
      select 1
      from public.matrix_scope_grants_v2 g
      where g.auth_user_id=auth.uid() and g.active
        and g.app_role in ('ROLE_MANAGER','LOCATION_MANAGER')
        and (g.role_logical_id is null or exists(
          select 1 from public.matrix_employee_roles_v2 er
          join public.matrix_roles_v2 r on r.id=er.role_id
          join public.matrix_versions mv on mv.id=er.matrix_version_id and mv.status='ACTIVE'
          where er.employee_id=p_employee_id and er.active
            and r.logical_id=g.role_logical_id))
        and (g.location_logical_id is null or exists(
          select 1 from public.matrix_employee_locations_v2 el
          join public.matrix_locations_v2 l on l.id=el.location_id
          join public.matrix_versions mv on mv.id=el.matrix_version_id and mv.status='ACTIVE'
          where el.employee_id=p_employee_id and el.active
            and l.logical_id=g.location_logical_id))
        and (g.duty_logical_id is null or exists(
          select 1 from public.matrix_employee_duties_v2 ed
          join public.matrix_duties_v2 d on d.id=ed.duty_id
          join public.matrix_versions mv on mv.id=ed.matrix_version_id and mv.status='ACTIVE'
          where ed.employee_id=p_employee_id and ed.active
            and d.logical_id=g.duty_logical_id))
    );
$$;

revoke all on function public.matrix_v2_can_manage_employee(uuid)
  from public, anon;
grant execute on function public.matrix_v2_can_manage_employee(uuid) to authenticated;

create or replace function public.employee_time_constraint_save_v2(
  p_id uuid,
  p_employee_id uuid,
  p_kind text,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_note text default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kind text:=upper(trim(p_kind));
  v_old public.employee_time_constraints_v2%rowtype;
  v_id uuid;
  v_self boolean;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.employees e where e.id=p_employee_id) then
    raise exception 'EMPLOYEE_NOT_FOUND';
  end if;
  if not public.matrix_v2_can_manage_employee(p_employee_id) then
    raise exception 'FORBIDDEN';
  end if;
  select exists(select 1 from public.employees e
    where e.id=p_employee_id and e.auth_user_id=auth.uid()) into v_self;
  if v_kind not in ('AVAILABLE_WINDOW','UNAVAILABLE','LEAVE','SICKNESS') then
    raise exception 'INVALID_TIME_CONSTRAINT_KIND';
  end if;
  if v_self and v_kind not in ('AVAILABLE_WINDOW','UNAVAILABLE') then
    raise exception 'EMPLOYEE_CANNOT_CREATE_PROTECTED_ABSENCE';
  end if;
  if p_starts_at is null or p_ends_at is null or p_ends_at<=p_starts_at then
    raise exception 'INVALID_TIME_RANGE';
  end if;

  if p_id is not null then
    select * into v_old from public.employee_time_constraints_v2 x
    where x.id=p_id for update;
    if v_old.id is null then raise exception 'TIME_CONSTRAINT_NOT_FOUND'; end if;
    if v_old.employee_id<>p_employee_id then raise exception 'EMPLOYEE_MISMATCH'; end if;
    if v_old.status<>'ACTIVE' then raise exception 'TIME_CONSTRAINT_NOT_ACTIVE'; end if;
    if v_self and (v_old.source<>'GRAFIK_PRO' or not v_old.editable_by_employee) then
      raise exception 'PROTECTED_TIME_CONSTRAINT';
    end if;
    update public.employee_time_constraints_v2 set status='REVOKED',
      revoked_at=now(),updated_at=now() where id=v_old.id;
  end if;

  insert into public.employee_time_constraints_v2(
    employee_id,constraint_kind,time_range,source,priority,editable_by_employee,
    status,note,supersedes_id,created_by
  ) values(
    p_employee_id,v_kind,tstzrange(p_starts_at,p_ends_at,'[)'),
    case when v_self then 'GRAFIK_PRO' else 'MANAGER' end,
    case when v_self then 100 else 300 end,v_self,'ACTIVE',nullif(trim(p_note),''),
    v_old.id,auth.uid()
  ) returning id into v_id;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'employee_time_constraint_v2',v_id::text,
    case when p_id is null then 'CREATE' else 'SUPERSEDE' end,
    jsonb_build_object('employeeId',p_employee_id,'kind',v_kind,
      'startsAt',p_starts_at,'endsAt',p_ends_at,'supersedesId',v_old.id));
  return v_id;
end;
$$;

create or replace function public.employee_pay_rate_save_v2(
  p_id uuid,
  p_employee_id uuid,
  p_valid_from date,
  p_valid_to date,
  p_base_rate_minor bigint,
  p_currency text default null,
  p_contract_type text default null,
  p_active boolean default true
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_currency text;
begin
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')
      or public.has_app_role('HR_FINANCE')) then
    raise exception 'FORBIDDEN';
  end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  if not exists(select 1 from public.employees e where e.id=p_employee_id) then
    raise exception 'EMPLOYEE_NOT_FOUND';
  end if;
  if p_valid_from is null or (p_valid_to is not null and p_valid_to<p_valid_from)
      or p_base_rate_minor is null or p_base_rate_minor<0 then
    raise exception 'INVALID_PAY_RATE';
  end if;
  select upper(mv.settings->>'currency') into v_currency
  from public.matrix_versions mv
  where mv.status='ACTIVE' and mv.schema_version>=2
  order by mv.version desc limit 1;
  v_currency:=coalesce(nullif(upper(trim(p_currency)),''),v_currency);
  if not public.matrix_v2_is_iso_4217_currency(v_currency) then
    raise exception 'INVALID_CURRENCY';
  end if;
  if coalesce(p_active,true) and exists(
    select 1 from public.employee_pay_rates_v2 x
    where x.employee_id=p_employee_id and x.active and x.id is distinct from p_id
      and daterange(x.valid_from,case when x.valid_to is null then null else x.valid_to+1 end,'[)')
        && daterange(p_valid_from,case when p_valid_to is null then null else p_valid_to+1 end,'[)')
  ) then raise exception 'OVERLAPPING_ACTIVE_PAY_RATE'; end if;

  if p_id is null then
    insert into public.employee_pay_rates_v2(
      employee_id,valid_from,valid_to,base_rate_minor,currency,contract_type,
      active,created_by,updated_by
    ) values(
      p_employee_id,p_valid_from,p_valid_to,p_base_rate_minor,v_currency,
      nullif(trim(p_contract_type),''),coalesce(p_active,true),auth.uid(),auth.uid()
    ) returning id into v_id;
  else
    update public.employee_pay_rates_v2 set employee_id=p_employee_id,
      valid_from=p_valid_from,valid_to=p_valid_to,base_rate_minor=p_base_rate_minor,
      currency=v_currency,contract_type=nullif(trim(p_contract_type),''),
      active=coalesce(p_active,true),updated_by=auth.uid(),updated_at=now()
    where id=p_id returning id into v_id;
    if v_id is null then raise exception 'PAY_RATE_NOT_FOUND'; end if;
  end if;

  -- The audit trail deliberately omits the monetary value.
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'employee_pay_rate_v2',v_id::text,'UPSERT',jsonb_build_object(
    'employeeId',p_employee_id,'validFrom',p_valid_from,'validTo',p_valid_to,
    'currency',v_currency,'active',coalesce(p_active,true)));
  return v_id;
end;
$$;

create or replace function public.employee_time_constraint_revoke_v2(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.employee_time_constraints_v2%rowtype;
  v_self boolean;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into v_row from public.employee_time_constraints_v2 x
  where x.id=p_id for update;
  if v_row.id is null then raise exception 'TIME_CONSTRAINT_NOT_FOUND'; end if;
  if v_row.status<>'ACTIVE' then return v_row.id; end if;
  if not public.matrix_v2_can_manage_employee(v_row.employee_id) then
    raise exception 'FORBIDDEN';
  end if;
  select exists(select 1 from public.employees e
    where e.id=v_row.employee_id and e.auth_user_id=auth.uid()) into v_self;
  if v_self and (v_row.source<>'GRAFIK_PRO' or not v_row.editable_by_employee) then
    raise exception 'PROTECTED_TIME_CONSTRAINT';
  end if;
  update public.employee_time_constraints_v2 set status='REVOKED',
    revoked_at=now(),updated_at=now() where id=v_row.id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'employee_time_constraint_v2',v_row.id::text,'REVOKE',
    jsonb_build_object('employeeId',v_row.employee_id,'kind',v_row.constraint_kind));
  return v_row.id;
end;
$$;

create or replace function public.matrix_scope_grant_save_v2(
  p_id uuid,
  p_auth_user_id uuid,
  p_app_role public.app_role,
  p_role_id uuid default null,
  p_location_id uuid default null,
  p_duty_id uuid default null,
  p_active boolean default true
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_role_logical uuid;
  v_location_logical uuid;
  v_duty_logical uuid;
begin
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if p_auth_user_id is null then raise exception 'AUTH_USER_REQUIRED'; end if;
  if p_role_id is not null then
    select r.logical_id into v_role_logical from public.matrix_roles_v2 r where r.id=p_role_id;
    if v_role_logical is null then raise exception 'ROLE_NOT_FOUND'; end if;
  end if;
  if p_location_id is not null then
    select l.logical_id into v_location_logical from public.matrix_locations_v2 l where l.id=p_location_id;
    if v_location_logical is null then raise exception 'LOCATION_NOT_FOUND'; end if;
  end if;
  if p_duty_id is not null then
    select d.logical_id into v_duty_logical from public.matrix_duties_v2 d where d.id=p_duty_id;
    if v_duty_logical is null then raise exception 'DUTY_NOT_FOUND'; end if;
  end if;

  if p_id is null then
    insert into public.matrix_scope_grants_v2(
      auth_user_id,app_role,role_logical_id,location_logical_id,duty_logical_id,
      active,created_by
    ) values(
      p_auth_user_id,p_app_role,v_role_logical,v_location_logical,v_duty_logical,
      coalesce(p_active,true),auth.uid()
    ) on conflict(auth_user_id,app_role,role_logical_id,location_logical_id,duty_logical_id)
      do update set active=excluded.active,updated_at=now()
    returning id into v_id;
  else
    update public.matrix_scope_grants_v2 set auth_user_id=p_auth_user_id,
      app_role=p_app_role,role_logical_id=v_role_logical,
      location_logical_id=v_location_logical,duty_logical_id=v_duty_logical,
      active=coalesce(p_active,true),updated_at=now()
    where id=p_id returning id into v_id;
    if v_id is null then raise exception 'SCOPE_GRANT_NOT_FOUND'; end if;
  end if;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_scope_grant_v2',v_id::text,'UPSERT',jsonb_build_object(
    'authUserId',p_auth_user_id,'appRole',p_app_role,
    'roleLogicalId',v_role_logical,'locationLogicalId',v_location_logical,
    'dutyLogicalId',v_duty_logical,'active',coalesce(p_active,true)));
  return v_id;
end;
$$;

create or replace function public.solver_feature_flag_set(
  p_engine text,
  p_config jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_engine text:=upper(trim(p_engine)); v_result jsonb;
begin
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if v_engine not in ('ALPHA15','ORTOOLS_V2','SHADOW') then
    raise exception 'INVALID_SOLVER_ENGINE';
  end if;
  if p_config is null or jsonb_typeof(p_config)<>'object' then
    raise exception 'OBJECT_CONFIG_REQUIRED';
  end if;
  if v_engine in ('SHADOW','ORTOOLS_V2') and (
    length(trim(coalesce(p_config->>'solverVersion',''))) not between 1 and 200
  ) then
    raise exception 'SOLVER_VERSION_CONFIGURATION_REQUIRED';
  end if;
  insert into public.solver_feature_flags(flag_key,engine,enabled,config,updated_by,updated_at)
  values('DEFAULT_ENGINE',v_engine,true,p_config,auth.uid(),now())
  on conflict(flag_key) do update set engine=excluded.engine,enabled=true,
    config=excluded.config,updated_by=auth.uid(),updated_at=now()
  returning to_jsonb(solver_feature_flags.*) into v_result;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'solver_feature_flag','DEFAULT_ENGINE','SET',jsonb_build_object(
    'engine',v_engine,'config',p_config));
  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------
-- Matrix v2 workspace. SECURITY DEFINER is paired with explicit row filtering:
-- payroll and budgets are never serialized for non-finance callers, while
-- employee mappings and time constraints follow the same self/manager boundary
-- as their RLS policies.
-- ---------------------------------------------------------------------------

create or replace function public.matrix_v2_workspace(p_month date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_matrix uuid;
  v_month date:=case when p_month is null then null
    else date_trunc('month',p_month)::date end;
  v_timezone text;
  v_finance boolean;
  v_manage boolean;
  v_owner_admin boolean;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  v_owner_admin:=public.has_app_role('OWNER') or public.has_app_role('ADMIN');
  v_finance:=v_owner_admin or public.has_app_role('HR_FINANCE');
  v_manage:=v_owner_admin or public.has_app_role('HR_FINANCE');

  if v_owner_admin then
    select mv.id into v_matrix from public.matrix_versions mv
    where mv.status='DRAFT' and mv.schema_version>=2
    order by mv.version desc limit 1;
  end if;
  if v_matrix is null then
    select mv.id into v_matrix from public.matrix_versions mv
    where mv.status='ACTIVE' and mv.schema_version>=2
    order by mv.version desc limit 1;
  end if;
  if v_matrix is null then raise exception 'MATRIX_V2_NOT_FOUND'; end if;
  select nullif(mv.settings->>'timezone','') into v_timezone
  from public.matrix_versions mv where mv.id=v_matrix;
  if v_timezone is null or not exists(
    select 1 from pg_catalog.pg_timezone_names tz where tz.name=v_timezone
  ) then raise exception 'INVALID_MATRIX_TIMEZONE'; end if;

  select jsonb_build_object(
    'matrixVersion',to_jsonb(mv),
    'month',v_month,
    'editable',mv.status='DRAFT' and v_owner_admin,
    'financeVisible',v_finance,
    'featureFlag',(select to_jsonb(f) from public.solver_feature_flags f
      where f.flag_key='DEFAULT_ENGINE'),
    'roles',coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order,x.code)
      from public.matrix_roles_v2 x where x.matrix_version_id=v_matrix),'[]'::jsonb),
    'locations',coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order,x.code)
      from public.matrix_locations_v2 x where x.matrix_version_id=v_matrix),'[]'::jsonb),
    'duties',coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order,x.code)
      from public.matrix_duties_v2 x where x.matrix_version_id=v_matrix),'[]'::jsonb),
    'shiftTemplates',coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order,x.code)
      from public.matrix_shift_templates_v2 x where x.matrix_version_id=v_matrix),'[]'::jsonb),
    'roleDuties',coalesce((select jsonb_agg(to_jsonb(x) order by x.role_id,x.duty_id)
      from public.matrix_role_duties_v2 x where x.matrix_version_id=v_matrix),'[]'::jsonb),
    'scenarios',coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order,x.code)
      from public.matrix_scenarios_v2 x where x.matrix_version_id=v_matrix),'[]'::jsonb),
    'staffingRules',coalesce((select jsonb_agg(to_jsonb(x)
        order by x.scenario_id,x.shift_template_id,x.role_id,x.duty_id)
      from public.matrix_staffing_rules_v2 x where x.matrix_version_id=v_matrix),'[]'::jsonb),
    'strategies',coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order,x.code)
      from public.matrix_strategies_v2 x where x.matrix_version_id=v_matrix),'[]'::jsonb),
    'strategyObjectives',coalesce((select jsonb_agg(to_jsonb(x)
        order by x.strategy_id,x.tier,x.sort_order,x.metric_code)
      from public.matrix_strategy_objectives_v2 x where x.matrix_version_id=v_matrix),'[]'::jsonb),
    'scenarioStrategies',coalesce((select jsonb_agg(to_jsonb(x)
        order by x.scenario_id,x.sort_order,x.strategy_id)
      from public.matrix_scenario_strategies_v2 x where x.matrix_version_id=v_matrix),'[]'::jsonb),
    'employees',coalesce((select jsonb_agg(jsonb_build_object(
        'id',e.id,'employeeNo',e.employee_no,'firstName',e.first_name,
        'lastName',e.last_name,'active',e.active and e.archived_at is null
      ) order by e.active desc,e.last_name,e.first_name,e.employee_no)
      from public.employees e
      where v_manage or e.auth_user_id=auth.uid()),'[]'::jsonb),
    'employeeRoles',coalesce((select jsonb_agg(to_jsonb(x) order by x.employee_id,x.role_id)
      from public.matrix_employee_roles_v2 x
      where x.matrix_version_id=v_matrix
        and (v_manage or public.matrix_v2_can_manage_employee(x.employee_id))),
      '[]'::jsonb),
    'employeeLocations',coalesce((select jsonb_agg(to_jsonb(x) order by x.employee_id,x.location_id)
      from public.matrix_employee_locations_v2 x
      where x.matrix_version_id=v_matrix
        and (v_manage or public.matrix_v2_can_manage_employee(x.employee_id))),
      '[]'::jsonb),
    'employeeDuties',coalesce((select jsonb_agg(to_jsonb(x) order by x.employee_id,x.duty_id)
      from public.matrix_employee_duties_v2 x
      where x.matrix_version_id=v_matrix
        and (v_manage or public.matrix_v2_can_manage_employee(x.employee_id))),
      '[]'::jsonb),
    'timeConstraints',coalesce((select jsonb_agg(jsonb_build_object(
        'id',x.id,'employeeId',x.employee_id,'kind',x.constraint_kind,
        'startsAt',lower(x.time_range),'endsAt',upper(x.time_range),
        'source',x.source,'editableByEmployee',x.editable_by_employee,
        'status',x.status,'note',x.note,'createdAt',x.created_at
      ) order by lower(x.time_range),x.id)
      from public.employee_time_constraints_v2 x
      where (v_manage or public.matrix_v2_can_manage_employee(x.employee_id))
        and x.status='ACTIVE'
        and (v_month is null or x.time_range && tstzrange(
          v_month::timestamp at time zone v_timezone,
          (v_month+interval '1 month')::timestamp at time zone v_timezone,'[)'))),'[]'::jsonb),
    'payRules',case when v_finance then coalesce((select jsonb_agg(to_jsonb(x)
        order by x.priority,x.code) from public.matrix_pay_rules_v2 x
      where x.matrix_version_id=v_matrix),'[]'::jsonb) else '[]'::jsonb end,
    'payRuleRoles',case when v_finance then coalesce((select jsonb_agg(to_jsonb(x)
      order by x.pay_rule_id,x.role_id) from public.matrix_pay_rule_roles_v2 x
      where x.matrix_version_id=v_matrix),'[]'::jsonb) else '[]'::jsonb end,
    'payRuleDuties',case when v_finance then coalesce((select jsonb_agg(to_jsonb(x)
      order by x.pay_rule_id,x.duty_id) from public.matrix_pay_rule_duties_v2 x
      where x.matrix_version_id=v_matrix),'[]'::jsonb) else '[]'::jsonb end,
    'payRuleLocations',case when v_finance then coalesce((select jsonb_agg(to_jsonb(x)
      order by x.pay_rule_id,x.location_id) from public.matrix_pay_rule_locations_v2 x
      where x.matrix_version_id=v_matrix),'[]'::jsonb) else '[]'::jsonb end,
    'payRuleShifts',case when v_finance then coalesce((select jsonb_agg(to_jsonb(x)
      order by x.pay_rule_id,x.shift_template_id) from public.matrix_pay_rule_shifts_v2 x
      where x.matrix_version_id=v_matrix),'[]'::jsonb) else '[]'::jsonb end,
    'scenarioPayRuleOverrides',case when v_finance then coalesce((select jsonb_agg(to_jsonb(x)
      order by x.scenario_id,x.pay_rule_id) from public.matrix_scenario_pay_rule_overrides_v2 x
      where x.matrix_version_id=v_matrix),'[]'::jsonb) else '[]'::jsonb end,
    'scenarioBudgets',case when v_finance then coalesce((select jsonb_agg(to_jsonb(x)
      order by x.scenario_id,x.budget_month,x.id) from public.matrix_scenario_budgets_v2 x
      where x.matrix_version_id=v_matrix
        and (v_month is null or x.budget_month is null or x.budget_month=v_month)),
      '[]'::jsonb) else '[]'::jsonb end,
    'employeePayRates',case when v_finance then coalesce((select jsonb_agg(to_jsonb(x)
      order by x.employee_id,x.valid_from desc) from public.employee_pay_rates_v2 x
      where v_month is null or (
        x.valid_from<(v_month+interval '1 month')::date
        and (x.valid_to is null or x.valid_to>=v_month))),
      '[]'::jsonb) else '[]'::jsonb end,
    'scopeGrants',coalesce((select jsonb_agg(to_jsonb(x)
      order by x.auth_user_id,x.app_role,x.id) from public.matrix_scope_grants_v2 x
      where v_owner_admin or x.auth_user_id=auth.uid()),'[]'::jsonb)
  ) into v_result
  from public.matrix_versions mv where mv.id=v_matrix;

  return v_result;
end;
$$;

create or replace function public.matrix_v2_admin_save(
  p_kind text,
  p_id uuid,
  p_data jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kind text:=upper(trim(p_kind));
  v_matrix uuid;
  v_id uuid;
  v_logical uuid;
  v_ref1 uuid;
  v_ref2 uuid;
  v_ref3 uuid;
  v_ref4 uuid;
begin
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if p_data is null or jsonb_typeof(p_data)<>'object' then
    raise exception 'OBJECT_PAYLOAD_REQUIRED';
  end if;
  v_matrix:=public.matrix_v2_create_draft(null);

  if v_kind='MATRIX_SETTINGS' then
    if not public.matrix_v2_is_iso_4217_currency(
      upper(trim(coalesce(p_data->>'currency','')))
    ) then
      raise exception 'INVALID_MATRIX_CURRENCY';
    end if;
    if nullif(p_data->>'timezone','') is null or not exists(
      select 1 from pg_catalog.pg_timezone_names tz
      where tz.name=p_data->>'timezone'
    ) then raise exception 'INVALID_MATRIX_TIMEZONE'; end if;
    if coalesce(p_data->>'minimumRestMinutes','') !~ '^[0-9]+$'
      or (p_data->>'minimumRestMinutes')::integer<0
      or coalesce(p_data->>'maximumShiftsPerDay','') !~ '^[0-9]+$'
      or (p_data->>'maximumShiftsPerDay')::integer not between 1 and 24
      or jsonb_typeof(p_data->'missingAvailabilityMeansAvailable')<>'boolean'
      or jsonb_typeof(p_data->'requireOptimal')<>'boolean' then
      raise exception 'INVALID_MATRIX_LIMITS';
    end if;
    update public.matrix_versions mv set settings=coalesce(mv.settings,'{}'::jsonb)
      ||jsonb_build_object(
        'currency',upper(trim(p_data->>'currency')),
        'timezone',p_data->>'timezone',
        'minimumRestMinutes',(p_data->>'minimumRestMinutes')::integer,
        'maximumShiftsPerDay',(p_data->>'maximumShiftsPerDay')::integer,
        'missingAvailabilityMeansAvailable',
          (p_data->>'missingAvailabilityMeansAvailable')::boolean,
        'requireOptimal',(p_data->>'requireOptimal')::boolean
      )
    where mv.id=v_matrix
    returning mv.id into v_id;

  elsif v_kind='ROLE' then
    if p_id is not null then
      select r.logical_id into v_logical from public.matrix_roles_v2 r where r.id=p_id;
      select r.id into v_id from public.matrix_roles_v2 r
        where r.matrix_version_id=v_matrix and r.logical_id=v_logical;
    end if;
    if v_id is null then
      insert into public.matrix_roles_v2(
        matrix_version_id,logical_id,code,name,color,sort_order,active
      ) values(
        v_matrix,gen_random_uuid(),upper(trim(p_data->>'code')),trim(p_data->>'name'),
        coalesce(nullif(p_data->>'color',''),'#7257d8'),
        coalesce((p_data->>'sortOrder')::integer,0),
        coalesce((p_data->>'active')::boolean,true)
      ) returning id into v_id;
    else
      update public.matrix_roles_v2 set
        code=upper(coalesce(nullif(trim(p_data->>'code'),''),code)),
        name=coalesce(nullif(trim(p_data->>'name'),''),name),
        color=coalesce(nullif(p_data->>'color',''),color),
        sort_order=coalesce((p_data->>'sortOrder')::integer,sort_order),
        active=coalesce((p_data->>'active')::boolean,active),updated_at=now()
      where id=v_id and matrix_version_id=v_matrix;
    end if;

  elsif v_kind='LOCATION' then
    if nullif(p_data->>'timezone','') is not null and not exists(
      select 1 from pg_catalog.pg_timezone_names tz
      where tz.name=p_data->>'timezone'
    ) then raise exception 'INVALID_LOCATION_TIMEZONE'; end if;
    if p_id is not null then
      select l.logical_id into v_logical from public.matrix_locations_v2 l where l.id=p_id;
      select l.id into v_id from public.matrix_locations_v2 l
        where l.matrix_version_id=v_matrix and l.logical_id=v_logical;
    end if;
    if v_id is null then
      insert into public.matrix_locations_v2(
        matrix_version_id,logical_id,code,name,timezone,sort_order,active
      ) values(
        v_matrix,gen_random_uuid(),upper(trim(p_data->>'code')),trim(p_data->>'name'),
        coalesce(
          nullif(p_data->>'timezone',''),
          (select nullif(mv.settings->>'timezone','')
            from public.matrix_versions mv where mv.id=v_matrix)
        ),
        coalesce((p_data->>'sortOrder')::integer,0),
        coalesce((p_data->>'active')::boolean,true)
      ) returning id into v_id;
    else
      update public.matrix_locations_v2 set
        code=upper(coalesce(nullif(trim(p_data->>'code'),''),code)),
        name=coalesce(nullif(trim(p_data->>'name'),''),name),
        timezone=coalesce(nullif(p_data->>'timezone',''),timezone),
        sort_order=coalesce((p_data->>'sortOrder')::integer,sort_order),
        active=coalesce((p_data->>'active')::boolean,active),updated_at=now()
      where id=v_id and matrix_version_id=v_matrix;
    end if;

  elsif v_kind='DUTY' then
    if p_id is not null then
      select d.logical_id into v_logical from public.matrix_duties_v2 d where d.id=p_id;
      select d.id into v_id from public.matrix_duties_v2 d
        where d.matrix_version_id=v_matrix and d.logical_id=v_logical;
    end if;
    if v_id is null then
      insert into public.matrix_duties_v2(
        matrix_version_id,logical_id,code,name,description,color,sort_order,active
      ) values(
        v_matrix,gen_random_uuid(),upper(trim(p_data->>'code')),trim(p_data->>'name'),
        nullif(p_data->>'description',''),coalesce(nullif(p_data->>'color',''),'#4a8d78'),
        coalesce((p_data->>'sortOrder')::integer,0),
        coalesce((p_data->>'active')::boolean,true)
      ) returning id into v_id;
    else
      update public.matrix_duties_v2 set
        code=upper(coalesce(nullif(trim(p_data->>'code'),''),code)),
        name=coalesce(nullif(trim(p_data->>'name'),''),name),
        description=case when p_data ? 'description' then nullif(p_data->>'description','') else description end,
        color=coalesce(nullif(p_data->>'color',''),color),
        sort_order=coalesce((p_data->>'sortOrder')::integer,sort_order),
        active=coalesce((p_data->>'active')::boolean,active),updated_at=now()
      where id=v_id and matrix_version_id=v_matrix;
    end if;

  elsif v_kind='SHIFT' then
    if nullif(p_data->>'locationId','') is not null then
      select target.id into v_ref1
      from public.matrix_locations_v2 source
      join public.matrix_locations_v2 target
        on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
      where source.id=(p_data->>'locationId')::uuid;
    elsif p_id is not null then
      select target.id into v_ref1
      from public.matrix_shift_templates_v2 source_shift
      join public.matrix_locations_v2 source on source.id=source_shift.location_id
      join public.matrix_locations_v2 target
        on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
      where source_shift.id=p_id;
    end if;
    if v_ref1 is null then raise exception 'LOCATION_NOT_IN_MATRIX_V2'; end if;
    if p_id is not null then
      select s.logical_id into v_logical from public.matrix_shift_templates_v2 s where s.id=p_id;
      select s.id into v_id from public.matrix_shift_templates_v2 s
        where s.matrix_version_id=v_matrix and s.logical_id=v_logical;
    end if;
    if v_id is null then
      insert into public.matrix_shift_templates_v2(
        matrix_version_id,logical_id,location_id,code,name,starts_at,ends_at,
        ends_next_day,day_mask,sort_order,active
      ) values(
        v_matrix,gen_random_uuid(),v_ref1,upper(trim(p_data->>'code')),trim(p_data->>'name'),
        (p_data->>'startsAt')::time,(p_data->>'endsAt')::time,
        coalesce((p_data->>'endsNextDay')::boolean,
          (p_data->>'endsAt')::time<=(p_data->>'startsAt')::time),
        case when p_data ? 'days' then
          array(select value::smallint from jsonb_array_elements_text(p_data->'days'))
          else array[1,2,3,4,5,6,7]::smallint[] end,
        coalesce((p_data->>'sortOrder')::integer,0),
        coalesce((p_data->>'active')::boolean,true)
      ) returning id into v_id;
    else
      update public.matrix_shift_templates_v2 set
        location_id=v_ref1,
        code=upper(coalesce(nullif(trim(p_data->>'code'),''),code)),
        name=coalesce(nullif(trim(p_data->>'name'),''),name),
        starts_at=coalesce((p_data->>'startsAt')::time,starts_at),
        ends_at=coalesce((p_data->>'endsAt')::time,ends_at),
        ends_next_day=coalesce((p_data->>'endsNextDay')::boolean,ends_next_day),
        day_mask=case when p_data ? 'days' then
          array(select value::smallint from jsonb_array_elements_text(p_data->'days'))
          else day_mask end,
        sort_order=coalesce((p_data->>'sortOrder')::integer,sort_order),
        active=coalesce((p_data->>'active')::boolean,active),updated_at=now()
      where id=v_id and matrix_version_id=v_matrix;
    end if;

  elsif v_kind='ROLE_DUTY' then
    select target.id into v_ref1 from public.matrix_roles_v2 source
    join public.matrix_roles_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=(p_data->>'roleId')::uuid;
    select target.id into v_ref2 from public.matrix_duties_v2 source
    join public.matrix_duties_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=(p_data->>'dutyId')::uuid;
    if v_ref1 is null or v_ref2 is null then raise exception 'ROLE_OR_DUTY_NOT_IN_MATRIX_V2'; end if;
    insert into public.matrix_role_duties_v2(
      id,matrix_version_id,role_id,duty_id,assignment_mode,minimum_count,active
    ) values(
      gen_random_uuid(),v_matrix,v_ref1,v_ref2,
      coalesce(nullif(upper(p_data->>'assignmentMode'),''),'OPTIONAL'),
      coalesce((p_data->>'minimumCount')::integer,0),
      coalesce((p_data->>'active')::boolean,true)
    ) on conflict(matrix_version_id,role_id,duty_id) do update set
      assignment_mode=excluded.assignment_mode,minimum_count=excluded.minimum_count,
      active=excluded.active
    returning id into v_id;

  elsif v_kind='SCENARIO' then
    if p_id is not null then
      select s.logical_id into v_logical from public.matrix_scenarios_v2 s where s.id=p_id;
      select s.id into v_id from public.matrix_scenarios_v2 s
        where s.matrix_version_id=v_matrix and s.logical_id=v_logical;
    end if;
    v_ref1:=null;
    if p_data ? 'parentScenarioId' then
      if nullif(p_data->>'parentScenarioId','') is not null then
        select target.id into v_ref1 from public.matrix_scenarios_v2 source
        join public.matrix_scenarios_v2 target
          on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
        where source.id=(p_data->>'parentScenarioId')::uuid;
        if v_ref1 is null then raise exception 'PARENT_SCENARIO_NOT_IN_MATRIX_V2'; end if;
      end if;
    elsif v_id is not null then
      select s.parent_scenario_id into v_ref1 from public.matrix_scenarios_v2 s
      where s.id=v_id;
    end if;
    if coalesce((p_data->>'isDefault')::boolean,false) then
      update public.matrix_scenarios_v2 set is_default=false,updated_at=now()
      where matrix_version_id=v_matrix and is_default;
    end if;
    if v_id is null then
      insert into public.matrix_scenarios_v2(
        matrix_version_id,logical_id,parent_scenario_id,code,name,description,color,
        is_default,active,sort_order,valid_from,valid_to,settings_overrides
      ) values(
        v_matrix,gen_random_uuid(),v_ref1,upper(trim(p_data->>'code')),trim(p_data->>'name'),
        nullif(p_data->>'description',''),coalesce(nullif(p_data->>'color',''),'#7457e8'),
        coalesce((p_data->>'isDefault')::boolean,false),
        coalesce((p_data->>'active')::boolean,true),
        coalesce((p_data->>'sortOrder')::integer,0),
        nullif(p_data->>'validFrom','')::date,nullif(p_data->>'validTo','')::date,
        coalesce(p_data->'settingsOverrides','{}'::jsonb)
      ) returning id into v_id;
    else
      update public.matrix_scenarios_v2 set
        parent_scenario_id=v_ref1,
        code=upper(coalesce(nullif(trim(p_data->>'code'),''),code)),
        name=coalesce(nullif(trim(p_data->>'name'),''),name),
        description=case when p_data ? 'description' then nullif(p_data->>'description','') else description end,
        color=coalesce(nullif(p_data->>'color',''),color),
        is_default=coalesce((p_data->>'isDefault')::boolean,is_default),
        active=coalesce((p_data->>'active')::boolean,active),
        sort_order=coalesce((p_data->>'sortOrder')::integer,sort_order),
        valid_from=case when p_data ? 'validFrom' then nullif(p_data->>'validFrom','')::date else valid_from end,
        valid_to=case when p_data ? 'validTo' then nullif(p_data->>'validTo','')::date else valid_to end,
        settings_overrides=coalesce(p_data->'settingsOverrides',settings_overrides),updated_at=now()
      where id=v_id and matrix_version_id=v_matrix;
    end if;

  elsif v_kind='STAFFING_RULE' then
    select target.id into v_ref1 from public.matrix_scenarios_v2 source
    join public.matrix_scenarios_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=(p_data->>'scenarioId')::uuid;
    select target.id into v_ref2 from public.matrix_shift_templates_v2 source
    join public.matrix_shift_templates_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=(p_data->>'shiftTemplateId')::uuid;
    select target.id into v_ref3 from public.matrix_roles_v2 source
    join public.matrix_roles_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=(p_data->>'roleId')::uuid;
    v_ref4:=null;
    if nullif(p_data->>'dutyId','') is not null then
      select target.id into v_ref4 from public.matrix_duties_v2 source
      join public.matrix_duties_v2 target
        on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
      where source.id=(p_data->>'dutyId')::uuid;
    end if;
    if v_ref1 is null or v_ref2 is null or v_ref3 is null then
      raise exception 'STAFFING_SCOPE_NOT_IN_MATRIX_V2';
    end if;
    insert into public.matrix_staffing_rules_v2(
      id,matrix_version_id,scenario_id,shift_template_id,role_id,duty_id,
      operation,count_value,multiplier_basis_points,active,source_metadata
    ) values(
      gen_random_uuid(),v_matrix,v_ref1,v_ref2,v_ref3,v_ref4,
      upper(p_data->>'operation'),nullif(p_data->>'countValue','')::integer,
      nullif(p_data->>'multiplierBasisPoints','')::integer,
      coalesce((p_data->>'active')::boolean,true),
      coalesce(p_data->'sourceMetadata','{}'::jsonb)
    ) on conflict(scenario_id,shift_template_id,role_id,duty_id) do update set
      operation=excluded.operation,count_value=excluded.count_value,
      multiplier_basis_points=excluded.multiplier_basis_points,
      active=excluded.active,source_metadata=excluded.source_metadata,updated_at=now()
    returning id into v_id;

  elsif v_kind='STRATEGY' then
    if p_id is not null then
      select s.logical_id into v_logical from public.matrix_strategies_v2 s where s.id=p_id;
      select s.id into v_id from public.matrix_strategies_v2 s
        where s.matrix_version_id=v_matrix and s.logical_id=v_logical;
    end if;
    if v_id is null then
      insert into public.matrix_strategies_v2(
        matrix_version_id,logical_id,code,name,description,solver_code,solver_options,
        sort_order,active
      ) values(
        v_matrix,gen_random_uuid(),upper(trim(p_data->>'code')),trim(p_data->>'name'),
        nullif(p_data->>'description',''),coalesce(nullif(p_data->>'solverCode',''),'CP_SAT'),
        coalesce(p_data->'solverOptions','{}'::jsonb),
        coalesce((p_data->>'sortOrder')::integer,0),
        coalesce((p_data->>'active')::boolean,true)
      ) returning id into v_id;
    else
      update public.matrix_strategies_v2 set
        code=upper(coalesce(nullif(trim(p_data->>'code'),''),code)),
        name=coalesce(nullif(trim(p_data->>'name'),''),name),
        description=case when p_data ? 'description' then nullif(p_data->>'description','') else description end,
        solver_code=coalesce(nullif(p_data->>'solverCode',''),solver_code),
        solver_options=coalesce(p_data->'solverOptions',solver_options),
        sort_order=coalesce((p_data->>'sortOrder')::integer,sort_order),
        active=coalesce((p_data->>'active')::boolean,active),updated_at=now()
      where id=v_id and matrix_version_id=v_matrix;
    end if;

  elsif v_kind='OBJECTIVE' then
    select target.id into v_ref1 from public.matrix_strategies_v2 source
    join public.matrix_strategies_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=(p_data->>'strategyId')::uuid;
    if v_ref1 is null then raise exception 'STRATEGY_NOT_IN_MATRIX_V2'; end if;
    insert into public.matrix_strategy_objectives_v2(
      id,matrix_version_id,strategy_id,tier,sort_order,metric_code,direction,
      weight,tolerance,parameters,active
    ) values(
      gen_random_uuid(),v_matrix,v_ref1,(p_data->>'tier')::smallint,
      coalesce((p_data->>'sortOrder')::integer,0),upper(trim(p_data->>'metricCode')),
      coalesce(nullif(upper(p_data->>'direction'),''),'MINIMIZE'),
      coalesce((p_data->>'weight')::bigint,1),coalesce((p_data->>'tolerance')::bigint,0),
      coalesce(p_data->'parameters','{}'::jsonb),coalesce((p_data->>'active')::boolean,true)
    ) on conflict(strategy_id,tier,metric_code) do update set
      sort_order=excluded.sort_order,direction=excluded.direction,weight=excluded.weight,
      tolerance=excluded.tolerance,parameters=excluded.parameters,active=excluded.active
    returning id into v_id;

  elsif v_kind='SCENARIO_STRATEGY' then
    select target.id into v_ref1 from public.matrix_scenarios_v2 source
    join public.matrix_scenarios_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=(p_data->>'scenarioId')::uuid;
    select target.id into v_ref2 from public.matrix_strategies_v2 source
    join public.matrix_strategies_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=(p_data->>'strategyId')::uuid;
    if v_ref1 is null or v_ref2 is null then raise exception 'SCENARIO_OR_STRATEGY_NOT_IN_MATRIX_V2'; end if;
    insert into public.matrix_scenario_strategies_v2(
      id,matrix_version_id,scenario_id,strategy_id,sort_order,active,
      objective_overrides,solver_overrides
    ) values(
      gen_random_uuid(),v_matrix,v_ref1,v_ref2,
      coalesce((p_data->>'sortOrder')::integer,0),
      coalesce((p_data->>'active')::boolean,true),
      coalesce(p_data->'objectiveOverrides','{}'::jsonb),
      coalesce(p_data->'solverOverrides','{}'::jsonb)
    ) on conflict(scenario_id,strategy_id) do update set
      sort_order=excluded.sort_order,active=excluded.active,
      objective_overrides=excluded.objective_overrides,
      solver_overrides=excluded.solver_overrides
    returning id into v_id;

  elsif v_kind='PAY_RULE' then
    if p_id is not null then
      select p.logical_id into v_logical from public.matrix_pay_rules_v2 p where p.id=p_id;
      select p.id into v_id from public.matrix_pay_rules_v2 p
        where p.matrix_version_id=v_matrix and p.logical_id=v_logical;
    end if;
    if v_id is null then
      insert into public.matrix_pay_rules_v2(
        matrix_version_id,logical_id,code,name,description,calculation_method,
        amount_minor,rate_minor_per_hour,percent_basis_points,multiplier_basis_points,
        threshold_minutes,currency,priority,stacking_group,stacking_mode,day_mask,
        local_start,local_end,ends_next_day,valid_from,valid_to,condition_expression,
        formula_expression,active
      ) values(
        v_matrix,gen_random_uuid(),upper(trim(p_data->>'code')),trim(p_data->>'name'),
        nullif(p_data->>'description',''),upper(p_data->>'calculationMethod'),
        nullif(p_data->>'amountMinor','')::bigint,
        nullif(p_data->>'rateMinorPerHour','')::bigint,
        nullif(p_data->>'percentBasisPoints','')::integer,
        nullif(p_data->>'multiplierBasisPoints','')::integer,
        nullif(p_data->>'thresholdMinutes','')::integer,
        coalesce(
          nullif(upper(p_data->>'currency'),''),
          (select upper(mv.settings->>'currency')
            from public.matrix_versions mv where mv.id=v_matrix)
        ),
        coalesce((p_data->>'priority')::integer,100),nullif(p_data->>'stackingGroup',''),
        coalesce(nullif(upper(p_data->>'stackingMode'),''),'STACK'),
        case when p_data ? 'days' then array(select value::smallint from jsonb_array_elements_text(p_data->'days'))
          else array[1,2,3,4,5,6,7]::smallint[] end,
        nullif(p_data->>'localStart','')::time,nullif(p_data->>'localEnd','')::time,
        coalesce((p_data->>'endsNextDay')::boolean,false),
        nullif(p_data->>'validFrom','')::date,nullif(p_data->>'validTo','')::date,
        coalesce(p_data->'conditionExpression','{}'::jsonb),
        coalesce(p_data->'formulaExpression','{}'::jsonb),
        coalesce((p_data->>'active')::boolean,true)
      ) returning id into v_id;
    else
      update public.matrix_pay_rules_v2 set
        code=upper(coalesce(nullif(trim(p_data->>'code'),''),code)),
        name=coalesce(nullif(trim(p_data->>'name'),''),name),
        description=case when p_data ? 'description' then nullif(p_data->>'description','') else description end,
        calculation_method=coalesce(nullif(upper(p_data->>'calculationMethod'),''),calculation_method),
        amount_minor=case when p_data ? 'amountMinor' then nullif(p_data->>'amountMinor','')::bigint else amount_minor end,
        rate_minor_per_hour=case when p_data ? 'rateMinorPerHour' then nullif(p_data->>'rateMinorPerHour','')::bigint else rate_minor_per_hour end,
        percent_basis_points=case when p_data ? 'percentBasisPoints' then nullif(p_data->>'percentBasisPoints','')::integer else percent_basis_points end,
        multiplier_basis_points=case when p_data ? 'multiplierBasisPoints' then nullif(p_data->>'multiplierBasisPoints','')::integer else multiplier_basis_points end,
        threshold_minutes=case when p_data ? 'thresholdMinutes' then nullif(p_data->>'thresholdMinutes','')::integer else threshold_minutes end,
        currency=coalesce(nullif(upper(p_data->>'currency'),''),currency),
        priority=coalesce((p_data->>'priority')::integer,priority),
        stacking_group=case when p_data ? 'stackingGroup' then nullif(p_data->>'stackingGroup','') else stacking_group end,
        stacking_mode=coalesce(nullif(upper(p_data->>'stackingMode'),''),stacking_mode),
        day_mask=case when p_data ? 'days' then array(select value::smallint from jsonb_array_elements_text(p_data->'days')) else day_mask end,
        local_start=case when p_data ? 'localStart' then nullif(p_data->>'localStart','')::time else local_start end,
        local_end=case when p_data ? 'localEnd' then nullif(p_data->>'localEnd','')::time else local_end end,
        ends_next_day=coalesce((p_data->>'endsNextDay')::boolean,ends_next_day),
        valid_from=case when p_data ? 'validFrom' then nullif(p_data->>'validFrom','')::date else valid_from end,
        valid_to=case when p_data ? 'validTo' then nullif(p_data->>'validTo','')::date else valid_to end,
        condition_expression=coalesce(p_data->'conditionExpression',condition_expression),
        formula_expression=coalesce(p_data->'formulaExpression',formula_expression),
        active=coalesce((p_data->>'active')::boolean,active),updated_at=now()
      where id=v_id and matrix_version_id=v_matrix;
    end if;

    if p_data ? 'roleIds' then
      delete from public.matrix_pay_rule_roles_v2 where pay_rule_id=v_id;
      insert into public.matrix_pay_rule_roles_v2(matrix_version_id,pay_rule_id,role_id)
      select distinct v_matrix,v_id,target.id
      from jsonb_array_elements_text(p_data->'roleIds') x(value)
      join public.matrix_roles_v2 source on source.id=x.value::uuid
      join public.matrix_roles_v2 target
        on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id;
    end if;
    if p_data ? 'dutyIds' then
      delete from public.matrix_pay_rule_duties_v2 where pay_rule_id=v_id;
      insert into public.matrix_pay_rule_duties_v2(matrix_version_id,pay_rule_id,duty_id)
      select distinct v_matrix,v_id,target.id
      from jsonb_array_elements_text(p_data->'dutyIds') x(value)
      join public.matrix_duties_v2 source on source.id=x.value::uuid
      join public.matrix_duties_v2 target
        on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id;
    end if;
    if p_data ? 'locationIds' then
      delete from public.matrix_pay_rule_locations_v2 where pay_rule_id=v_id;
      insert into public.matrix_pay_rule_locations_v2(matrix_version_id,pay_rule_id,location_id)
      select distinct v_matrix,v_id,target.id
      from jsonb_array_elements_text(p_data->'locationIds') x(value)
      join public.matrix_locations_v2 source on source.id=x.value::uuid
      join public.matrix_locations_v2 target
        on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id;
    end if;
    if p_data ? 'shiftIds' then
      delete from public.matrix_pay_rule_shifts_v2 where pay_rule_id=v_id;
      insert into public.matrix_pay_rule_shifts_v2(matrix_version_id,pay_rule_id,shift_template_id)
      select distinct v_matrix,v_id,target.id
      from jsonb_array_elements_text(p_data->'shiftIds') x(value)
      join public.matrix_shift_templates_v2 source on source.id=x.value::uuid
      join public.matrix_shift_templates_v2 target
        on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id;
    end if;

  elsif v_kind='SCENARIO_PAY_RULE' then
    select target.id into v_ref1 from public.matrix_scenarios_v2 source
    join public.matrix_scenarios_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=(p_data->>'scenarioId')::uuid;
    select target.id into v_ref2 from public.matrix_pay_rules_v2 source
    join public.matrix_pay_rules_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=(p_data->>'payRuleId')::uuid;
    if v_ref1 is null or v_ref2 is null then
      raise exception 'SCENARIO_OR_PAY_RULE_NOT_IN_MATRIX_V2';
    end if;
    insert into public.matrix_scenario_pay_rule_overrides_v2(
      id,matrix_version_id,scenario_id,pay_rule_id,enabled,amount_minor,
      rate_minor_per_hour,percent_basis_points,multiplier_basis_points,formula_expression
    ) values(
      gen_random_uuid(),v_matrix,v_ref1,v_ref2,
      coalesce((p_data->>'enabled')::boolean,true),
      nullif(p_data->>'amountMinor','')::bigint,
      nullif(p_data->>'rateMinorPerHour','')::bigint,
      nullif(p_data->>'percentBasisPoints','')::integer,
      nullif(p_data->>'multiplierBasisPoints','')::integer,
      case when p_data ? 'formulaExpression' then p_data->'formulaExpression' else null end
    ) on conflict(scenario_id,pay_rule_id) do update set
      enabled=excluded.enabled,amount_minor=excluded.amount_minor,
      rate_minor_per_hour=excluded.rate_minor_per_hour,
      percent_basis_points=excluded.percent_basis_points,
      multiplier_basis_points=excluded.multiplier_basis_points,
      formula_expression=excluded.formula_expression
    returning id into v_id;

  elsif v_kind='SCENARIO_BUDGET' then
    select target.id into v_ref1 from public.matrix_scenarios_v2 source
    join public.matrix_scenarios_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=(p_data->>'scenarioId')::uuid;
    if v_ref1 is null then raise exception 'SCENARIO_NOT_IN_MATRIX_V2'; end if;
    v_ref2:=null; v_ref3:=null; v_ref4:=null;
    if nullif(p_data->>'locationId','') is not null then
      select target.id into v_ref2 from public.matrix_locations_v2 source
      join public.matrix_locations_v2 target
        on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
      where source.id=(p_data->>'locationId')::uuid;
      if v_ref2 is null then raise exception 'LOCATION_NOT_IN_MATRIX_V2'; end if;
    end if;
    if nullif(p_data->>'roleId','') is not null then
      select target.id into v_ref3 from public.matrix_roles_v2 source
      join public.matrix_roles_v2 target
        on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
      where source.id=(p_data->>'roleId')::uuid;
      if v_ref3 is null then raise exception 'ROLE_NOT_IN_MATRIX_V2'; end if;
    end if;
    if nullif(p_data->>'dutyId','') is not null then
      select target.id into v_ref4 from public.matrix_duties_v2 source
      join public.matrix_duties_v2 target
        on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
      where source.id=(p_data->>'dutyId')::uuid;
      if v_ref4 is null then raise exception 'DUTY_NOT_IN_MATRIX_V2'; end if;
    end if;
    insert into public.matrix_scenario_budgets_v2(
      id,matrix_version_id,scenario_id,budget_month,location_id,role_id,duty_id,
      operation,amount_minor,multiplier_basis_points,currency,hard_limit,
      warning_percent,source_metadata
    ) values(
      gen_random_uuid(),v_matrix,v_ref1,
      nullif(p_data->>'budgetMonth','')::date,v_ref2,v_ref3,v_ref4,
      coalesce(nullif(upper(p_data->>'operation'),''),'SET'),
      nullif(p_data->>'amountMinor','')::bigint,
      nullif(p_data->>'multiplierBasisPoints','')::integer,
      coalesce(
        nullif(upper(p_data->>'currency'),''),
        (select upper(mv.settings->>'currency')
          from public.matrix_versions mv where mv.id=v_matrix)
      ),
      nullif(p_data->>'hardLimit','')::boolean,
      nullif(p_data->>'warningPercent','')::integer,
      coalesce(p_data->'sourceMetadata','{}'::jsonb)
    ) on conflict(scenario_id,budget_month,location_id,role_id,duty_id) do update set
      operation=excluded.operation,amount_minor=excluded.amount_minor,
      multiplier_basis_points=excluded.multiplier_basis_points,
      currency=excluded.currency,hard_limit=excluded.hard_limit,
      warning_percent=excluded.warning_percent,
      source_metadata=excluded.source_metadata,updated_at=now()
    returning id into v_id;

  elsif v_kind='EMPLOYEE_ROLE' then
    select target.id into v_ref1 from public.matrix_roles_v2 source
    join public.matrix_roles_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=(p_data->>'roleId')::uuid;
    if v_ref1 is null then raise exception 'ROLE_NOT_IN_MATRIX_V2'; end if;
    if coalesce((p_data->>'isPrimary')::boolean,false) then
      update public.matrix_employee_roles_v2 set is_primary=false
      where matrix_version_id=v_matrix and employee_id=(p_data->>'employeeId')::uuid and is_primary;
    end if;
    insert into public.matrix_employee_roles_v2(
      id,matrix_version_id,employee_id,role_id,is_primary,can_lead,active,valid_from,valid_to
    ) values(
      gen_random_uuid(),v_matrix,(p_data->>'employeeId')::uuid,v_ref1,
      coalesce((p_data->>'isPrimary')::boolean,false),
      coalesce((p_data->>'canLead')::boolean,false),
      coalesce((p_data->>'active')::boolean,true),
      nullif(p_data->>'validFrom','')::date,nullif(p_data->>'validTo','')::date
    ) on conflict(matrix_version_id,employee_id,role_id) do update set
      is_primary=excluded.is_primary,can_lead=excluded.can_lead,active=excluded.active,
      valid_from=excluded.valid_from,valid_to=excluded.valid_to
    returning id into v_id;

  elsif v_kind='EMPLOYEE_LOCATION' then
    select target.id into v_ref1 from public.matrix_locations_v2 source
    join public.matrix_locations_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=(p_data->>'locationId')::uuid;
    if v_ref1 is null then raise exception 'LOCATION_NOT_IN_MATRIX_V2'; end if;
    insert into public.matrix_employee_locations_v2(
      id,matrix_version_id,employee_id,location_id,standard_allowed,overtime_allowed,
      home_location,active,valid_from,valid_to
    ) values(
      gen_random_uuid(),v_matrix,(p_data->>'employeeId')::uuid,v_ref1,
      coalesce((p_data->>'standardAllowed')::boolean,false),
      coalesce((p_data->>'overtimeAllowed')::boolean,false),
      coalesce((p_data->>'homeLocation')::boolean,false),
      coalesce((p_data->>'active')::boolean,true),
      nullif(p_data->>'validFrom','')::date,nullif(p_data->>'validTo','')::date
    ) on conflict(matrix_version_id,employee_id,location_id) do update set
      standard_allowed=excluded.standard_allowed,overtime_allowed=excluded.overtime_allowed,
      home_location=excluded.home_location,active=excluded.active,
      valid_from=excluded.valid_from,valid_to=excluded.valid_to
    returning id into v_id;

  elsif v_kind='EMPLOYEE_DUTY' then
    select target.id into v_ref1 from public.matrix_duties_v2 source
    join public.matrix_duties_v2 target
      on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
    where source.id=(p_data->>'dutyId')::uuid;
    if v_ref1 is null then raise exception 'DUTY_NOT_IN_MATRIX_V2'; end if;
    v_ref2:=null; v_ref3:=null;
    if nullif(p_data->>'roleId','') is not null then
      select target.id into v_ref2 from public.matrix_roles_v2 source
      join public.matrix_roles_v2 target
        on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
      where source.id=(p_data->>'roleId')::uuid;
      if v_ref2 is null then raise exception 'ROLE_NOT_IN_MATRIX_V2'; end if;
    end if;
    if nullif(p_data->>'locationId','') is not null then
      select target.id into v_ref3 from public.matrix_locations_v2 source
      join public.matrix_locations_v2 target
        on target.matrix_version_id=v_matrix and target.logical_id=source.logical_id
      where source.id=(p_data->>'locationId')::uuid;
      if v_ref3 is null then raise exception 'LOCATION_NOT_IN_MATRIX_V2'; end if;
    end if;
    insert into public.matrix_employee_duties_v2(
      id,matrix_version_id,employee_id,duty_id,role_id,location_id,active,
      valid_from,valid_to,source
    ) values(
      gen_random_uuid(),v_matrix,(p_data->>'employeeId')::uuid,v_ref1,
      v_ref2,v_ref3,coalesce((p_data->>'active')::boolean,true),
      nullif(p_data->>'validFrom','')::date,nullif(p_data->>'validTo','')::date,'MATRIX_V2_ADMIN'
    ) on conflict(matrix_version_id,employee_id,duty_id,role_id,location_id) do update set
      active=excluded.active,valid_from=excluded.valid_from,valid_to=excluded.valid_to,
      source=excluded.source
    returning id into v_id;

  else
    raise exception 'UNSUPPORTED_MATRIX_V2_KIND: %',v_kind;
  end if;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_v2_'||lower(v_kind),v_id::text,'UPSERT',
    jsonb_build_object('matrixVersionId',v_matrix,'data',
      case when v_kind in ('PAY_RULE','SCENARIO_PAY_RULE','SCENARIO_BUDGET') then
        p_data-array['amountMinor','rateMinorPerHour','percentBasisPoints',
          'multiplierBasisPoints','formulaExpression']
      else p_data end));
  return jsonb_build_object('id',v_id,'kind',v_kind,'matrixVersionId',v_matrix);
end;
$$;

create or replace function public.matrix_v2_content_document(p_matrix_version_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'settings',mv.settings,
    'roles',coalesce((select jsonb_agg(
      to_jsonb(x)-array['id','matrix_version_id','created_at','updated_at'] order by x.logical_id)
      from public.matrix_roles_v2 x where x.matrix_version_id=mv.id),'[]'::jsonb),
    'locations',coalesce((select jsonb_agg(
      to_jsonb(x)-array['id','matrix_version_id','created_at','updated_at'] order by x.logical_id)
      from public.matrix_locations_v2 x where x.matrix_version_id=mv.id),'[]'::jsonb),
    'duties',coalesce((select jsonb_agg(
      to_jsonb(x)-array['id','matrix_version_id','created_at','updated_at'] order by x.logical_id)
      from public.matrix_duties_v2 x where x.matrix_version_id=mv.id),'[]'::jsonb),
    'shifts',coalesce((select jsonb_agg(
      (to_jsonb(x)-array['id','matrix_version_id','location_id','created_at','updated_at'])
        ||jsonb_build_object('locationLogicalId',l.logical_id) order by x.logical_id)
      from public.matrix_shift_templates_v2 x
      join public.matrix_locations_v2 l on l.id=x.location_id
      where x.matrix_version_id=mv.id),'[]'::jsonb),
    'roleDuties',coalesce((select jsonb_agg(
      (to_jsonb(x)-array['id','matrix_version_id','role_id','duty_id','created_at'])
        ||jsonb_build_object('roleLogicalId',r.logical_id,'dutyLogicalId',d.logical_id)
        order by r.logical_id,d.logical_id)
      from public.matrix_role_duties_v2 x
      join public.matrix_roles_v2 r on r.id=x.role_id
      join public.matrix_duties_v2 d on d.id=x.duty_id
      where x.matrix_version_id=mv.id),'[]'::jsonb),
    'scenarios',coalesce((select jsonb_agg(
      (to_jsonb(x)-array['id','matrix_version_id','parent_scenario_id','created_at','updated_at'])
        ||jsonb_build_object('parentLogicalId',p.logical_id) order by x.logical_id)
      from public.matrix_scenarios_v2 x
      left join public.matrix_scenarios_v2 p on p.id=x.parent_scenario_id
      where x.matrix_version_id=mv.id),'[]'::jsonb),
    'staffingRules',coalesce((select jsonb_agg(
      (to_jsonb(x)-array['id','matrix_version_id','scenario_id','shift_template_id',
        'role_id','duty_id','created_at','updated_at'])
        ||jsonb_build_object('scenarioLogicalId',sc.logical_id,
          'shiftLogicalId',sh.logical_id,'roleLogicalId',r.logical_id,
          'dutyLogicalId',d.logical_id)
        order by sc.logical_id,sh.logical_id,r.logical_id,d.logical_id)
      from public.matrix_staffing_rules_v2 x
      join public.matrix_scenarios_v2 sc on sc.id=x.scenario_id
      join public.matrix_shift_templates_v2 sh on sh.id=x.shift_template_id
      join public.matrix_roles_v2 r on r.id=x.role_id
      left join public.matrix_duties_v2 d on d.id=x.duty_id
      where x.matrix_version_id=mv.id),'[]'::jsonb),
    'strategies',coalesce((select jsonb_agg(
      to_jsonb(x)-array['id','matrix_version_id','legacy_optimizer_profile_id',
        'created_at','updated_at'] order by x.logical_id)
      from public.matrix_strategies_v2 x where x.matrix_version_id=mv.id),'[]'::jsonb),
    'objectives',coalesce((select jsonb_agg(
      (to_jsonb(x)-array['id','matrix_version_id','strategy_id','created_at'])
        ||jsonb_build_object('strategyLogicalId',s.logical_id)
        order by s.logical_id,x.tier,x.sort_order,x.metric_code)
      from public.matrix_strategy_objectives_v2 x
      join public.matrix_strategies_v2 s on s.id=x.strategy_id
      where x.matrix_version_id=mv.id),'[]'::jsonb),
    'scenarioStrategies',coalesce((select jsonb_agg(
      (to_jsonb(x)-array['id','matrix_version_id','scenario_id','strategy_id','created_at'])
        ||jsonb_build_object('scenarioLogicalId',sc.logical_id,
          'strategyLogicalId',st.logical_id)
        order by sc.logical_id,x.sort_order,st.logical_id)
      from public.matrix_scenario_strategies_v2 x
      join public.matrix_scenarios_v2 sc on sc.id=x.scenario_id
      join public.matrix_strategies_v2 st on st.id=x.strategy_id
      where x.matrix_version_id=mv.id),'[]'::jsonb),
    'employeeRoles',coalesce((select jsonb_agg(
      (to_jsonb(x)-array['id','matrix_version_id','role_id','created_at'])
        ||jsonb_build_object('roleLogicalId',r.logical_id)
        order by x.employee_id,r.logical_id)
      from public.matrix_employee_roles_v2 x
      join public.matrix_roles_v2 r on r.id=x.role_id
      where x.matrix_version_id=mv.id),'[]'::jsonb),
    'employeeLocations',coalesce((select jsonb_agg(
      (to_jsonb(x)-array['id','matrix_version_id','location_id','created_at'])
        ||jsonb_build_object('locationLogicalId',l.logical_id)
        order by x.employee_id,l.logical_id)
      from public.matrix_employee_locations_v2 x
      join public.matrix_locations_v2 l on l.id=x.location_id
      where x.matrix_version_id=mv.id),'[]'::jsonb),
    'employeeDuties',coalesce((select jsonb_agg(
      (to_jsonb(x)-array['id','matrix_version_id','duty_id','role_id','location_id','created_at'])
        ||jsonb_build_object('dutyLogicalId',d.logical_id,
          'roleLogicalId',r.logical_id,'locationLogicalId',l.logical_id)
        order by x.employee_id,d.logical_id,r.logical_id,l.logical_id)
      from public.matrix_employee_duties_v2 x
      join public.matrix_duties_v2 d on d.id=x.duty_id
      left join public.matrix_roles_v2 r on r.id=x.role_id
      left join public.matrix_locations_v2 l on l.id=x.location_id
      where x.matrix_version_id=mv.id),'[]'::jsonb),
    'payRules',coalesce((select jsonb_agg(
      to_jsonb(x)-array['id','matrix_version_id','created_at','updated_at']
        order by x.logical_id)
      from public.matrix_pay_rules_v2 x where x.matrix_version_id=mv.id),'[]'::jsonb),
    'payRuleRoles',coalesce((select jsonb_agg(jsonb_build_object(
        'payRuleLogicalId',p.logical_id,'roleLogicalId',r.logical_id)
        order by p.logical_id,r.logical_id)
      from public.matrix_pay_rule_roles_v2 x
      join public.matrix_pay_rules_v2 p on p.id=x.pay_rule_id
      join public.matrix_roles_v2 r on r.id=x.role_id
      where x.matrix_version_id=mv.id),'[]'::jsonb),
    'payRuleDuties',coalesce((select jsonb_agg(jsonb_build_object(
        'payRuleLogicalId',p.logical_id,'dutyLogicalId',d.logical_id,'matchMode',x.match_mode)
        order by p.logical_id,d.logical_id)
      from public.matrix_pay_rule_duties_v2 x
      join public.matrix_pay_rules_v2 p on p.id=x.pay_rule_id
      join public.matrix_duties_v2 d on d.id=x.duty_id
      where x.matrix_version_id=mv.id),'[]'::jsonb),
    'payRuleLocations',coalesce((select jsonb_agg(jsonb_build_object(
        'payRuleLogicalId',p.logical_id,'locationLogicalId',l.logical_id)
        order by p.logical_id,l.logical_id)
      from public.matrix_pay_rule_locations_v2 x
      join public.matrix_pay_rules_v2 p on p.id=x.pay_rule_id
      join public.matrix_locations_v2 l on l.id=x.location_id
      where x.matrix_version_id=mv.id),'[]'::jsonb),
    'payRuleShifts',coalesce((select jsonb_agg(jsonb_build_object(
        'payRuleLogicalId',p.logical_id,'shiftLogicalId',s.logical_id)
        order by p.logical_id,s.logical_id)
      from public.matrix_pay_rule_shifts_v2 x
      join public.matrix_pay_rules_v2 p on p.id=x.pay_rule_id
      join public.matrix_shift_templates_v2 s on s.id=x.shift_template_id
      where x.matrix_version_id=mv.id),'[]'::jsonb),
    'scenarioPayRuleOverrides',coalesce((select jsonb_agg(
      (to_jsonb(x)-array['id','matrix_version_id','scenario_id','pay_rule_id','created_at'])
        ||jsonb_build_object('scenarioLogicalId',sc.logical_id,
          'payRuleLogicalId',p.logical_id) order by sc.logical_id,p.logical_id)
      from public.matrix_scenario_pay_rule_overrides_v2 x
      join public.matrix_scenarios_v2 sc on sc.id=x.scenario_id
      join public.matrix_pay_rules_v2 p on p.id=x.pay_rule_id
      where x.matrix_version_id=mv.id),'[]'::jsonb),
    'scenarioBudgets',coalesce((select jsonb_agg(
      (to_jsonb(x)-array['id','matrix_version_id','scenario_id','location_id','role_id',
        'duty_id','created_at','updated_at'])
        ||jsonb_build_object('scenarioLogicalId',sc.logical_id,
          'locationLogicalId',l.logical_id,'roleLogicalId',r.logical_id,
          'dutyLogicalId',d.logical_id)
        order by sc.logical_id,x.budget_month,l.logical_id,r.logical_id,d.logical_id)
      from public.matrix_scenario_budgets_v2 x
      join public.matrix_scenarios_v2 sc on sc.id=x.scenario_id
      left join public.matrix_locations_v2 l on l.id=x.location_id
      left join public.matrix_roles_v2 r on r.id=x.role_id
      left join public.matrix_duties_v2 d on d.id=x.duty_id
      where x.matrix_version_id=mv.id),'[]'::jsonb)
  )
  from public.matrix_versions mv where mv.id=p_matrix_version_id;
$$;

revoke all on function public.matrix_v2_content_document(uuid)
  from public, anon, authenticated;

create or replace function public.matrix_v2_publish_draft(
  p_effective_from date default current_date
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_draft public.matrix_versions%rowtype;
  v_active public.matrix_versions%rowtype;
  v_default_count integer;
  v_cycle boolean;
  v_document jsonb;
  v_hash text;
  v_scenario record;
  v_active_strategy_count integer;
begin
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if p_effective_from is null then raise exception 'EFFECTIVE_FROM_REQUIRED'; end if;
  if p_effective_from>current_date then
    raise exception 'FUTURE_MATRIX_ACTIVATION_REQUIRES_SCHEDULER';
  end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));

  select * into v_draft from public.matrix_versions mv
  where mv.status='DRAFT' and mv.schema_version>=2
  order by mv.version desc limit 1 for update;
  if v_draft.id is null then raise exception 'NO_MATRIX_V2_DRAFT'; end if;
  select * into v_active from public.matrix_versions mv
  where mv.status='ACTIVE' order by mv.version desc limit 1 for update;
  if exists(select 1 from public.matrix_versions mv
      where mv.status='ACTIVE' and p_effective_from<mv.effective_from) then
    raise exception 'EFFECTIVE_FROM_PRECEDES_ACTIVE_MATRIX';
  end if;

  select count(*) into v_default_count from public.matrix_scenarios_v2 s
  where s.matrix_version_id=v_draft.id and s.active and s.is_default;
  if v_default_count<>1 then raise exception 'EXACTLY_ONE_ACTIVE_DEFAULT_SCENARIO_REQUIRED'; end if;
  if exists(select 1 from public.matrix_scenarios_v2 s
    where s.matrix_version_id=v_draft.id and s.active and s.is_default
      and s.parent_scenario_id is not null) then
    raise exception 'DEFAULT_SCENARIO_CANNOT_INHERIT';
  end if;

  if not exists(select 1 from public.matrix_roles_v2 x
      where x.matrix_version_id=v_draft.id and x.active)
    or not exists(select 1 from public.matrix_locations_v2 x
      where x.matrix_version_id=v_draft.id and x.active)
    or not exists(select 1 from public.matrix_shift_templates_v2 x
      where x.matrix_version_id=v_draft.id and x.active)
    or not exists(select 1 from public.matrix_strategies_v2 x
      where x.matrix_version_id=v_draft.id and x.active) then
    raise exception 'ACTIVE_ROLE_LOCATION_SHIFT_AND_STRATEGY_REQUIRED';
  end if;

  if exists(select 1 from public.matrix_locations_v2 l
    where l.matrix_version_id=v_draft.id
      and not exists(select 1 from pg_catalog.pg_timezone_names tz
        where tz.name=l.timezone)) then
    raise exception 'INVALID_LOCATION_TIMEZONE';
  end if;
  if exists(
    select 1 from public.matrix_shift_templates_v2 shift_row
    where shift_row.matrix_version_id=v_draft.id and shift_row.active
      and shift_row.ends_next_day is distinct from
        (shift_row.ends_at<=shift_row.starts_at)
  ) then raise exception 'SHIFT_OVERNIGHT_FLAG_INCONSISTENT'; end if;
  if not public.matrix_v2_is_iso_4217_currency(
    upper(coalesce(v_draft.settings->>'currency',''))
  ) then
    raise exception 'INVALID_MATRIX_CURRENCY';
  end if;
  if nullif(v_draft.settings->>'timezone','') is null or not exists(
    select 1 from pg_catalog.pg_timezone_names tz
    where tz.name=v_draft.settings->>'timezone'
  ) then raise exception 'INVALID_MATRIX_TIMEZONE'; end if;
  if coalesce(v_draft.settings->>'minimumRestMinutes','') !~ '^[0-9]+$'
    or (v_draft.settings->>'minimumRestMinutes')::integer<0
    or coalesce(v_draft.settings->>'maximumShiftsPerDay','') !~ '^[0-9]+$'
    or (v_draft.settings->>'maximumShiftsPerDay')::integer not between 1 and 24
    or jsonb_typeof(v_draft.settings->'missingAvailabilityMeansAvailable')<>'boolean'
    or jsonb_typeof(v_draft.settings->'requireOptimal')<>'boolean'
  then raise exception 'INVALID_MATRIX_SETTINGS'; end if;
  if exists(
    select 1 from public.matrix_scenarios_v2 s
    where s.matrix_version_id=v_draft.id and s.active and (
      jsonb_typeof(s.settings_overrides)<>'object'
      or s.settings_overrides-array[
        'timezone','minimumRestMinutes','maximumShiftsPerDay',
        'missingAvailabilityMeansAvailable','requireOptimal',
        'onlyMorningBeforeMinute','onlyEveningAfterMinute','randomSeed'
      ]<>'{}'::jsonb
      or (s.settings_overrides ? 'timezone' and (
        nullif(s.settings_overrides->>'timezone','') is null
        or not exists(select 1 from pg_catalog.pg_timezone_names tz
          where tz.name=s.settings_overrides->>'timezone')
      ))
      or (s.settings_overrides ? 'minimumRestMinutes' and (
        coalesce(s.settings_overrides->>'minimumRestMinutes','') !~ '^[0-9]+$'
        or (s.settings_overrides->>'minimumRestMinutes')::integer<0
      ))
      or (s.settings_overrides ? 'maximumShiftsPerDay' and (
        coalesce(s.settings_overrides->>'maximumShiftsPerDay','') !~ '^[0-9]+$'
        or (s.settings_overrides->>'maximumShiftsPerDay')::integer not between 1 and 24
      ))
      or (s.settings_overrides ? 'missingAvailabilityMeansAvailable'
        and jsonb_typeof(s.settings_overrides->'missingAvailabilityMeansAvailable')<>'boolean')
      or (s.settings_overrides ? 'requireOptimal'
        and jsonb_typeof(s.settings_overrides->'requireOptimal')<>'boolean')
      or (s.settings_overrides ? 'onlyMorningBeforeMinute' and (
        coalesce(s.settings_overrides->>'onlyMorningBeforeMinute','') !~ '^[0-9]+$'
        or (s.settings_overrides->>'onlyMorningBeforeMinute')::integer>2880
      ))
      or (s.settings_overrides ? 'onlyEveningAfterMinute' and (
        coalesce(s.settings_overrides->>'onlyEveningAfterMinute','') !~ '^[0-9]+$'
        or (s.settings_overrides->>'onlyEveningAfterMinute')::integer>2880
      ))
      or (s.settings_overrides ? 'randomSeed' and
        coalesce(s.settings_overrides->>'randomSeed','') !~ '^[0-9]+$')
    )
  ) then raise exception 'INVALID_SCENARIO_SETTINGS_OVERRIDE'; end if;
  if exists(
    select 1 from public.matrix_pay_rules_v2 p
    where p.matrix_version_id=v_draft.id and p.active
      and p.currency<>upper(v_draft.settings->>'currency')
  ) or exists(
    select 1 from public.matrix_scenario_budgets_v2 b
    where b.matrix_version_id=v_draft.id
      and b.currency<>upper(v_draft.settings->>'currency')
  ) or exists(
    select 1 from public.employee_pay_rates_v2 r
    join public.matrix_employee_profiles_v2 profile
      on profile.matrix_version_id=v_draft.id
      and profile.employee_id=r.employee_id and profile.active
    where r.active and r.valid_from<=p_effective_from
      and (r.valid_to is null or r.valid_to>=p_effective_from)
      and r.currency<>upper(v_draft.settings->>'currency')
  ) then raise exception 'MIXED_CURRENCIES_UNSUPPORTED'; end if;
  if exists(
    select 1 from public.matrix_employee_profiles_v2 profile
    where profile.matrix_version_id=v_draft.id and profile.active
      and not exists(
        select 1 from public.employee_pay_rates_v2 rate
        where rate.employee_id=profile.employee_id and rate.active
          and rate.valid_from<=p_effective_from
          and (rate.valid_to is null or rate.valid_to>=p_effective_from)
      )
  ) then raise exception 'ACTIVE_EMPLOYEE_REQUIRES_PAY_RATE'; end if;
  if exists(
    select 1 from public.matrix_pay_rules_v2 p
    where p.matrix_version_id=v_draft.id and p.active and (
      jsonb_typeof(p.condition_expression)<>'object'
      or p.condition_expression-array['conditions']<>'{}'::jsonb
      or (p.condition_expression ? 'conditions'
        and jsonb_typeof(p.condition_expression->'conditions')<>'array')
      or p.formula_expression<>'{}'::jsonb
      or (p.local_start is null)<>(p.local_end is null)
      or (
        case when p.local_start is null then 0 else 1 end
        +(select count(*) from jsonb_array_elements(
          coalesce(p.condition_expression->'conditions','[]'::jsonb)
        ) condition where lower(coalesce(condition.value->>'field',''))='local_time'
          and upper(coalesce(condition.value->>'operator',''))='OVERLAPS_TIME')
      )>1
      or (
        p.calculation_method in (
          'SHIFT_DURATION_THRESHOLD_PER_HOUR','MONTHLY_THRESHOLD_PER_HOUR'
        ) and (
          p.local_start is not null or exists(
            select 1 from jsonb_array_elements(
              coalesce(p.condition_expression->'conditions','[]'::jsonb)
            ) condition where lower(coalesce(condition.value->>'field',''))='local_time'
              and upper(coalesce(condition.value->>'operator',''))='OVERLAPS_TIME'
          )
        )
      )
      or (p.calculation_method='MULTIPLIER'
        and p.multiplier_basis_points<10000)
      or (p.calculation_method='FIXED_PER_SHIFT' and (
        p.rate_minor_per_hour is not null or p.percent_basis_points is not null
        or p.multiplier_basis_points is not null or p.threshold_minutes is not null
      ))
      or (p.calculation_method='PER_HOUR' and (
        p.amount_minor is not null or p.percent_basis_points is not null
        or p.multiplier_basis_points is not null or p.threshold_minutes is not null
      ))
      or (p.calculation_method='PERCENT_BASE' and (
        p.amount_minor is not null or p.rate_minor_per_hour is not null
        or p.multiplier_basis_points is not null or p.threshold_minutes is not null
      ))
      or (p.calculation_method='MULTIPLIER' and (
        p.amount_minor is not null or p.rate_minor_per_hour is not null
        or p.percent_basis_points is not null or p.threshold_minutes is not null
      ))
      or (p.calculation_method in (
        'SHIFT_DURATION_THRESHOLD_PER_HOUR','MONTHLY_THRESHOLD_PER_HOUR'
      ) and (
        p.amount_minor is not null or p.percent_basis_points is not null
        or p.multiplier_basis_points is not null
      ))
    )
  ) then raise exception 'INVALID_PAY_RULE_CONFIGURATION'; end if;
  if exists(
    select 1
    from public.matrix_pay_rules_v2 p
    cross join lateral jsonb_array_elements(
      coalesce(p.condition_expression->'conditions','[]'::jsonb)
    ) condition
    where p.matrix_version_id=v_draft.id and p.active
      and not public.matrix_v2_is_supported_pay_condition(condition.value)
  ) then raise exception 'UNSUPPORTED_PAY_RULE_CONDITION'; end if;
  if exists(
    select 1 from public.matrix_pay_rules_v2 left_rule
    join public.matrix_pay_rules_v2 right_rule
      on right_rule.matrix_version_id=left_rule.matrix_version_id
      and right_rule.id>left_rule.id and right_rule.active
      and coalesce(right_rule.stacking_group,right_rule.id::text)
        =coalesce(left_rule.stacking_group,left_rule.id::text)
      and right_rule.stacking_mode<>left_rule.stacking_mode
    where left_rule.matrix_version_id=v_draft.id and left_rule.active
  ) then raise exception 'INCONSISTENT_PAY_STACKING_GROUP'; end if;
  if exists(
    select 1 from public.matrix_scenario_pay_rule_overrides_v2 override
    join public.matrix_scenarios_v2 scenario
      on scenario.id=override.scenario_id and scenario.active
    join public.matrix_pay_rules_v2 rule
      on rule.id=override.pay_rule_id and rule.active
    where override.matrix_version_id=v_draft.id and (
      coalesce(override.formula_expression,'{}'::jsonb)<>'{}'::jsonb
      or (rule.calculation_method='FIXED_PER_SHIFT' and (
        override.rate_minor_per_hour is not null
        or override.percent_basis_points is not null
        or override.multiplier_basis_points is not null
      ))
      or (rule.calculation_method in (
        'PER_HOUR','SHIFT_DURATION_THRESHOLD_PER_HOUR',
        'MONTHLY_THRESHOLD_PER_HOUR'
      ) and (
        override.amount_minor is not null
        or override.percent_basis_points is not null
        or override.multiplier_basis_points is not null
      ))
      or (rule.calculation_method='PERCENT_BASE' and (
        override.amount_minor is not null or override.rate_minor_per_hour is not null
        or override.multiplier_basis_points is not null
      ))
      or (rule.calculation_method='MULTIPLIER' and (
        override.amount_minor is not null or override.rate_minor_per_hour is not null
        or override.percent_basis_points is not null
        or (override.multiplier_basis_points is not null
          and override.multiplier_basis_points<10000)
      ))
    )
  ) then raise exception 'INVALID_SCENARIO_PAY_RULE_OVERRIDE'; end if;
  if exists(select 1 from public.matrix_shift_templates_v2 s
    where s.matrix_version_id=v_draft.id
      and cardinality(s.day_mask)<>(select count(distinct d) from unnest(s.day_mask) d)) then
    raise exception 'SHIFT_DAY_MASK_CONTAINS_DUPLICATES';
  end if;

  with recursive walk(id,parent_scenario_id,path,cycle) as (
    select s.id,s.parent_scenario_id,array[s.id],false
    from public.matrix_scenarios_v2 s where s.matrix_version_id=v_draft.id
    union all
    select p.id,p.parent_scenario_id,w.path||p.id,p.id=any(w.path)
    from walk w join public.matrix_scenarios_v2 p on p.id=w.parent_scenario_id
    where not w.cycle
  ) select coalesce(bool_or(w.cycle),false) into v_cycle from walk w;
  if v_cycle then raise exception 'SCENARIO_INHERITANCE_CYCLE'; end if;
  if exists(
    with recursive chain as (
      select s.id,s.parent_scenario_id,0 depth
      from public.matrix_scenarios_v2 s
      where s.matrix_version_id=v_draft.id
      union all
      select parent.id,parent.parent_scenario_id,chain.depth+1
      from chain
      join public.matrix_scenarios_v2 parent
        on parent.id=chain.parent_scenario_id
        and parent.matrix_version_id=v_draft.id
      where chain.depth<32
    )
    select 1 from chain
    where chain.depth=32 and chain.parent_scenario_id is not null
  ) then raise exception 'SCENARIO_INHERITANCE_TOO_DEEP'; end if;
  if exists(select 1 from public.matrix_scenarios_v2 s
    join public.matrix_scenarios_v2 p on p.id=s.parent_scenario_id
    where s.matrix_version_id=v_draft.id and s.active and not p.active) then
    raise exception 'ACTIVE_SCENARIO_HAS_INACTIVE_PARENT';
  end if;

  if exists(
    select 1 from public.matrix_strategies_v2 s
    where s.matrix_version_id=v_draft.id and s.active and (
      upper(s.solver_code)<>'CP_SAT'
      or jsonb_typeof(s.solver_options)<>'object'
    )
  ) then raise exception 'UNSUPPORTED_STRATEGY_SOLVER_CONFIGURATION'; end if;
  if exists(
    select 1 from public.matrix_strategies_v2 s
    where s.matrix_version_id=v_draft.id and s.active and (
      s.solver_options-array['maxTimeSeconds','randomSeed']<>'{}'::jsonb
      or (s.solver_options ? 'maxTimeSeconds' and (
        coalesce(s.solver_options->>'maxTimeSeconds','') !~ '^[0-9]+$'
        or (s.solver_options->>'maxTimeSeconds')::integer not between 1 and 86400
      ))
      or (s.solver_options ? 'randomSeed' and (
        coalesce(s.solver_options->>'randomSeed','') !~ '^[0-9]+$'
        or (s.solver_options->>'randomSeed')::numeric>2147483647
      ))
    )
  ) then raise exception 'INVALID_STRATEGY_SOLVER_OPTIONS'; end if;

  if exists(
    select 1 from public.matrix_strategy_objectives_v2 o
    join public.matrix_strategies_v2 s on s.id=o.strategy_id and s.active
    where o.matrix_version_id=v_draft.id and o.active and (
      upper(o.metric_code) not in (
        'UNFILLED','TOTAL_COST','PREFERENCE_VIOLATIONS',
        'HOME_LOCATION_VIOLATIONS','NOMINAL_DEVIATION_MINUTES',
        'OVERTIME_MINUTES','LOAD_SPREAD_MINUTES','WEEKEND_SPREAD',
        'BASELINE_CHANGES','COST','TOTAL_COST_UNITS','PREFERENCES',
        'HOME_LOCATION','NOMINAL_DEVIATION','OVERTIME','LOAD_SPREAD',
        'BASELINE_CHANGES_COUNT','UNFILLED_SEATS','TOTAL_COST_MINOR',
        'WORKLOAD_VARIANCE','WEEKEND_VARIANCE','NON_HOME_LOCATION_COUNT'
      )
      or jsonb_typeof(o.parameters)<>'object'
    )
  ) then raise exception 'UNSUPPORTED_STRATEGY_OBJECTIVE'; end if;
  if exists(
    select 1 from public.matrix_strategy_objectives_v2 o
    join public.matrix_strategies_v2 s on s.id=o.strategy_id and s.active
    where o.matrix_version_id=v_draft.id and o.active and (
      o.parameters-array['target','targetValue']<>'{}'::jsonb
      or (o.parameters ? 'target' and o.parameters ? 'targetValue')
      or ((o.parameters ? 'target' or o.parameters ? 'targetValue') and (
        upper(o.direction)<>'MINIMIZE'
        or coalesce(o.parameters->>case when o.parameters ? 'targetValue'
          then 'targetValue' else 'target' end,'') !~ '^[0-9]+$'
      ))
    )
  ) then raise exception 'INVALID_STRATEGY_OBJECTIVE_PARAMETERS'; end if;

  if exists(
    select 1 from public.matrix_scenario_strategies_v2 ss
    join public.matrix_scenarios_v2 sc on sc.id=ss.scenario_id and sc.active
    join public.matrix_strategies_v2 st on st.id=ss.strategy_id and st.active
    where ss.matrix_version_id=v_draft.id and ss.active and (
      jsonb_typeof(ss.objective_overrides)<>'object'
      or jsonb_typeof(ss.solver_overrides)<>'object'
    )
  ) then raise exception 'INVALID_SCENARIO_STRATEGY_OVERRIDE'; end if;
  if exists(
    select 1
    from public.matrix_scenario_strategies_v2 ss
    join public.matrix_scenarios_v2 sc on sc.id=ss.scenario_id and sc.active
    join public.matrix_strategies_v2 st on st.id=ss.strategy_id and st.active
    cross join lateral jsonb_each(ss.objective_overrides) ov
    left join public.matrix_strategy_objectives_v2 objective
      on objective.strategy_id=ss.strategy_id
      and objective.metric_code=upper(ov.key) and objective.active
    where ss.matrix_version_id=v_draft.id and ss.active and (
      ov.key<>upper(ov.key)
      or objective.id is null
      or jsonb_typeof(ov.value)<>'object'
      or (ov.value ? 'parameters'
        and jsonb_typeof(ov.value->'parameters')<>'object')
    )
  ) then raise exception 'INVALID_SCENARIO_OBJECTIVE_OVERRIDE'; end if;
  if exists(
    select 1
    from public.matrix_scenario_strategies_v2 ss
    join public.matrix_scenarios_v2 sc on sc.id=ss.scenario_id and sc.active
    join public.matrix_strategies_v2 st on st.id=ss.strategy_id and st.active
    cross join lateral jsonb_each(ss.objective_overrides) ov
    join public.matrix_strategy_objectives_v2 objective
      on objective.strategy_id=ss.strategy_id
      and objective.metric_code=upper(ov.key) and objective.active
    where ss.matrix_version_id=v_draft.id and ss.active and (
      ov.value-array['active','tier','weight','direction','tolerance','parameters']
        <>'{}'::jsonb
      or (ov.value ? 'active' and jsonb_typeof(ov.value->'active')<>'boolean')
      or (ov.value ? 'tier' and (
        coalesce(ov.value->>'tier','') !~ '^[0-9]+$'
        or (ov.value->>'tier')::integer not between 1 and 100
      ))
      or (ov.value ? 'weight' and coalesce(ov.value->>'weight','') !~ '^[0-9]+$')
      or (ov.value ? 'tolerance'
        and coalesce(ov.value->>'tolerance','') !~ '^[0-9]+$')
      or (ov.value ? 'direction' and upper(ov.value->>'direction')
        not in ('MIN','MINIMIZE','MAX','MAXIMIZE'))
      or (
        (objective.parameters||coalesce(
          ov.value->'parameters','{}'::jsonb
        ))-array['target','targetValue']<>'{}'::jsonb
        or (
          (objective.parameters||coalesce(
            ov.value->'parameters','{}'::jsonb
          )) ? 'target'
          and (objective.parameters||coalesce(
            ov.value->'parameters','{}'::jsonb
          )) ? 'targetValue'
        )
        or (
          (
            (objective.parameters||coalesce(
              ov.value->'parameters','{}'::jsonb
            )) ? 'target'
            or (objective.parameters||coalesce(
              ov.value->'parameters','{}'::jsonb
            )) ? 'targetValue'
          ) and (
            case upper(coalesce(ov.value->>'direction',objective.direction))
              when 'MIN' then 'MINIMIZE'
              when 'MAX' then 'MAXIMIZE'
              else upper(coalesce(ov.value->>'direction',objective.direction))
            end <> 'MINIMIZE'
            or coalesce(
              (objective.parameters||coalesce(
                ov.value->'parameters','{}'::jsonb
              ))->>case when (objective.parameters||coalesce(
                ov.value->'parameters','{}'::jsonb
              )) ? 'targetValue' then 'targetValue' else 'target' end,
              ''
            ) !~ '^[0-9]+$'
          )
        )
      )
    )
  ) then raise exception 'INVALID_SCENARIO_OBJECTIVE_OVERRIDE'; end if;
  if exists(
    select 1 from public.matrix_scenario_strategies_v2 ss
    join public.matrix_scenarios_v2 sc on sc.id=ss.scenario_id and sc.active
    join public.matrix_strategies_v2 st on st.id=ss.strategy_id and st.active
    where ss.matrix_version_id=v_draft.id and ss.active and (
      ss.solver_overrides-array['maxTimeSeconds','randomSeed']<>'{}'::jsonb
      or (ss.solver_overrides ? 'maxTimeSeconds' and (
        coalesce(ss.solver_overrides->>'maxTimeSeconds','') !~ '^[0-9]+$'
        or (ss.solver_overrides->>'maxTimeSeconds')::integer not between 1 and 86400
      ))
      or (ss.solver_overrides ? 'randomSeed' and (
        coalesce(ss.solver_overrides->>'randomSeed','') !~ '^[0-9]+$'
        or (ss.solver_overrides->>'randomSeed')::numeric>2147483647
      ))
    )
  ) then raise exception 'INVALID_SCENARIO_SOLVER_OVERRIDE'; end if;

  -- Validate the exact inherited configuration emitted by the snapshot, not
  -- just each override row in isolation. A child may override direction while
  -- inheriting a target, or introduce the second target alias; both must fail
  -- at publication rather than in the worker.
  if exists(
    with recursive scenario_chain as (
      select scenario.id root_id,scenario.id,scenario.parent_scenario_id,0 depth
      from public.matrix_scenarios_v2 scenario
      where scenario.matrix_version_id=v_draft.id and scenario.active
      union all
      select chain.root_id,parent.id,parent.parent_scenario_id,chain.depth+1
      from scenario_chain chain
      join public.matrix_scenarios_v2 parent
        on parent.id=chain.parent_scenario_id
        and parent.matrix_version_id=v_draft.id
      where chain.depth<32
    ), raw_links as (
      select chain.root_id,chain.depth,link.id,link.strategy_id,
        link.active,link.objective_overrides
      from scenario_chain chain
      join public.matrix_scenario_strategies_v2 link
        on link.scenario_id=chain.id
        and link.matrix_version_id=v_draft.id
    ), resolved_links as (
      select link.root_id,link.strategy_id,
        (array_agg(link.active order by link.depth,link.id))[1] active,
        solver_private.jsonb_deep_merge_array_v2(array_agg(
          link.objective_overrides order by link.depth desc,link.id
        )) objective_overrides
      from raw_links link
      group by link.root_id,link.strategy_id
    )
    select 1
    from resolved_links resolved
    join public.matrix_strategies_v2 strategy
      on strategy.id=resolved.strategy_id and strategy.active
    join public.matrix_strategy_objectives_v2 objective
      on objective.strategy_id=resolved.strategy_id and objective.active
    cross join lateral (select coalesce(
      resolved.objective_overrides->upper(objective.metric_code),'{}'::jsonb
    ) value) override_config
    where resolved.active
      and coalesce((override_config.value->>'active')::boolean,true)
      and not public.matrix_v2_is_supported_objective_config(
        coalesce(override_config.value->>'direction',objective.direction),
        objective.parameters||coalesce(
          override_config.value->'parameters','{}'::jsonb
        )
      )
  ) then raise exception 'INVALID_RESOLVED_SCENARIO_OBJECTIVE'; end if;

  for v_scenario in
    select s.id from public.matrix_scenarios_v2 s
    where s.matrix_version_id=v_draft.id and s.active
  loop
    with recursive chain as (
      select s.id,s.parent_scenario_id,0 depth
      from public.matrix_scenarios_v2 s where s.id=v_scenario.id
      union all
      select parent.id,parent.parent_scenario_id,chain.depth+1
      from public.matrix_scenarios_v2 parent
      join chain on chain.parent_scenario_id=parent.id
      where parent.matrix_version_id=v_draft.id and chain.depth<32
    ), resolved as (
      select distinct on (ss.strategy_id) ss.strategy_id,ss.active,chain.depth
      from chain join public.matrix_scenario_strategies_v2 ss
        on ss.scenario_id=chain.id and ss.matrix_version_id=v_draft.id
      order by ss.strategy_id,chain.depth,ss.id
    )
    select count(*) into v_active_strategy_count
    from resolved r join public.matrix_strategies_v2 st
      on st.id=r.strategy_id and st.active
    where r.active;
    if v_active_strategy_count=0 then
      raise exception 'ACTIVE_SCENARIO_WITHOUT_ACTIVE_STRATEGY:%',v_scenario.id;
    end if;
  end loop;
  if exists(select 1 from public.matrix_strategies_v2 s
    where s.matrix_version_id=v_draft.id and s.active
      and not exists(select 1 from public.matrix_strategy_objectives_v2 o
        where o.strategy_id=s.id and o.active and o.tier=1 and o.metric_code='UNFILLED')) then
    raise exception 'ACTIVE_STRATEGY_REQUIRES_TIER1_UNFILLED_OBJECTIVE';
  end if;

  if exists(select 1 from public.matrix_staffing_rules_v2 x
    join public.matrix_scenarios_v2 sc on sc.id=x.scenario_id
    join public.matrix_shift_templates_v2 sh on sh.id=x.shift_template_id
    join public.matrix_roles_v2 r on r.id=x.role_id
    left join public.matrix_duties_v2 d on d.id=x.duty_id
    where x.matrix_version_id=v_draft.id and x.active
      and (not sc.active or not sh.active or not r.active
        or (x.duty_id is not null and not d.active))) then
    raise exception 'ACTIVE_STAFFING_RULE_REFERENCES_INACTIVE_SCOPE';
  end if;

  -- Publishing is the fail-closed boundary. Dormant rows may remain in a
  -- draft for editing history, but no active configuration may point at a
  -- role, duty, location or shift that the snapshot itself will omit.
  if exists(
    select 1 from public.matrix_shift_templates_v2 shift_row
    join public.matrix_locations_v2 location on location.id=shift_row.location_id
    where shift_row.matrix_version_id=v_draft.id and shift_row.active
      and not location.active
  ) then raise exception 'ACTIVE_SHIFT_REFERENCES_INACTIVE_LOCATION'; end if;
  if exists(
    select 1 from public.matrix_role_duties_v2 link
    join public.matrix_roles_v2 role on role.id=link.role_id
    join public.matrix_duties_v2 duty on duty.id=link.duty_id
    where link.matrix_version_id=v_draft.id and link.active
      and (not role.active or not duty.active)
  ) then raise exception 'ROLE_DUTY_REFERENCES_INACTIVE_SCOPE'; end if;
  if exists(
    select 1 from public.matrix_employee_roles_v2 grant_row
    join public.matrix_employee_profiles_v2 profile
      on profile.matrix_version_id=grant_row.matrix_version_id
      and profile.employee_id=grant_row.employee_id
    join public.matrix_roles_v2 role on role.id=grant_row.role_id
    where grant_row.matrix_version_id=v_draft.id and profile.active
      and grant_row.active and not role.active
  ) then raise exception 'EMPLOYEE_ROLE_REFERENCES_INACTIVE_ROLE'; end if;
  if exists(
    select 1 from public.matrix_employee_locations_v2 grant_row
    join public.matrix_employee_profiles_v2 profile
      on profile.matrix_version_id=grant_row.matrix_version_id
      and profile.employee_id=grant_row.employee_id
    join public.matrix_locations_v2 location on location.id=grant_row.location_id
    where grant_row.matrix_version_id=v_draft.id and profile.active
      and grant_row.active and not location.active
  ) then raise exception 'EMPLOYEE_LOCATION_REFERENCES_INACTIVE_LOCATION'; end if;
  if exists(
    select 1 from public.matrix_employee_duties_v2 grant_row
    join public.matrix_employee_profiles_v2 profile
      on profile.matrix_version_id=grant_row.matrix_version_id
      and profile.employee_id=grant_row.employee_id
    join public.matrix_duties_v2 duty on duty.id=grant_row.duty_id
    left join public.matrix_roles_v2 role on role.id=grant_row.role_id
    left join public.matrix_locations_v2 location on location.id=grant_row.location_id
    where grant_row.matrix_version_id=v_draft.id and profile.active
      and grant_row.active and (
        not duty.active
        or (grant_row.role_id is not null and not role.active)
        or (grant_row.location_id is not null and not location.active)
      )
  ) then raise exception 'EMPLOYEE_DUTY_REFERENCES_INACTIVE_SCOPE'; end if;
  if exists(
    select 1 from public.matrix_scenario_strategies_v2 link
    join public.matrix_scenarios_v2 scenario on scenario.id=link.scenario_id
    join public.matrix_strategies_v2 strategy on strategy.id=link.strategy_id
    where link.matrix_version_id=v_draft.id and scenario.active
      and link.active and not strategy.active
  ) then raise exception 'SCENARIO_REFERENCES_INACTIVE_STRATEGY'; end if;
  if exists(
    select 1 from public.matrix_pay_rules_v2 rule
    left join public.matrix_pay_rule_roles_v2 role_link on role_link.pay_rule_id=rule.id
    left join public.matrix_roles_v2 role on role.id=role_link.role_id
    left join public.matrix_pay_rule_duties_v2 duty_link on duty_link.pay_rule_id=rule.id
    left join public.matrix_duties_v2 duty on duty.id=duty_link.duty_id
    left join public.matrix_pay_rule_locations_v2 location_link
      on location_link.pay_rule_id=rule.id
    left join public.matrix_locations_v2 location on location.id=location_link.location_id
    left join public.matrix_pay_rule_shifts_v2 shift_link on shift_link.pay_rule_id=rule.id
    left join public.matrix_shift_templates_v2 shift_row
      on shift_row.id=shift_link.shift_template_id
    where rule.matrix_version_id=v_draft.id and rule.active and (
      (role_link.pay_rule_id is not null and not role.active)
      or (duty_link.pay_rule_id is not null and not duty.active)
      or (location_link.pay_rule_id is not null and not location.active)
      or (shift_link.pay_rule_id is not null and not shift_row.active)
    )
  ) then raise exception 'PAY_RULE_REFERENCES_INACTIVE_SCOPE'; end if;
  if exists(
    select 1 from public.matrix_scenario_budgets_v2 budget
    join public.matrix_scenarios_v2 scenario on scenario.id=budget.scenario_id
    left join public.matrix_locations_v2 location on location.id=budget.location_id
    left join public.matrix_roles_v2 role on role.id=budget.role_id
    left join public.matrix_duties_v2 duty on duty.id=budget.duty_id
    where budget.matrix_version_id=v_draft.id and scenario.active and (
      (budget.location_id is not null and not location.active)
      or (budget.role_id is not null and not role.active)
      or (budget.duty_id is not null and not duty.active)
    )
  ) then raise exception 'SCENARIO_BUDGET_REFERENCES_INACTIVE_SCOPE'; end if;

  v_document:=public.matrix_v2_content_document(v_draft.id);
  if v_document is null then raise exception 'MATRIX_V2_CONTENT_NOT_FOUND'; end if;
  v_hash:=encode(extensions.digest(v_document::text,'sha256'),'hex');

  update public.matrix_versions set status='ARCHIVED',
    effective_to=greatest(effective_from,p_effective_from)
  where status='DRAFT' and id<>v_draft.id;
  update public.matrix_versions set status='ARCHIVED',
    effective_to=greatest(effective_from,p_effective_from-1)
  where status='ACTIVE' and id<>v_draft.id;
  update public.matrix_versions set status='ACTIVE',effective_from=p_effective_from,
    effective_to=null,activated_at=now(),published_at=now(),published_by=auth.uid(),
    content_hash=v_hash,schema_version=2
  where id=v_draft.id;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'matrix_v2',v_draft.id::text,'PUBLISH',jsonb_build_object(
    'version',v_draft.version,'effectiveFrom',p_effective_from,
    'contentHash',v_hash,'solverEngine',(select f.engine
      from public.solver_feature_flags f where f.flag_key='DEFAULT_ENGINE')));
  return v_draft.id;
end;
$$;

-- Scope-aware reads replace the broad legacy manager predicate. The helper
-- evaluates logical IDs against the ACTIVE Matrix, so grants survive versions.
do $$
declare t text;
begin
  foreach t in array array[
    'matrix_employee_roles_v2','matrix_employee_locations_v2','matrix_employee_duties_v2'
  ] loop
    execute format('drop policy if exists workforce_v2_read on public.%I',t);
    execute format(
      'create policy workforce_v2_read on public.%I for select to authenticated '
      ||'using (public.matrix_v2_can_manage_employee(employee_id) '
      ||'and exists(select 1 from public.matrix_versions mv '
      ||'where mv.id=matrix_version_id and (mv.status=''ACTIVE'' '
      ||'or public.has_app_role(''OWNER'') or public.has_app_role(''ADMIN''))))',t
    );
  end loop;
end $$;

drop policy if exists employee_time_constraints_v2_read
  on public.employee_time_constraints_v2;
create policy employee_time_constraints_v2_read
on public.employee_time_constraints_v2 for select to authenticated
using (public.matrix_v2_can_manage_employee(employee_id));

-- Function privileges are explicit; tables remain SELECT-only through the Data
-- API and all writes pass through validated, audited RPCs.
revoke all on function public.matrix_v2_create_draft(text)
  from public, anon, authenticated;
revoke all on function public.matrix_v2_workspace(date)
  from public, anon, authenticated;
revoke all on function public.matrix_v2_admin_save(text,uuid,jsonb)
  from public, anon, authenticated;
revoke all on function public.matrix_v2_publish_draft(date)
  from public, anon, authenticated;
revoke all on function public.employee_time_constraint_save_v2(
  uuid,uuid,text,timestamptz,timestamptz,text
) from public, anon, authenticated;
revoke all on function public.employee_pay_rate_save_v2(
  uuid,uuid,date,date,bigint,text,text,boolean
) from public, anon, authenticated;
revoke all on function public.employee_time_constraint_revoke_v2(uuid)
  from public, anon, authenticated;
revoke all on function public.matrix_scope_grant_save_v2(
  uuid,uuid,public.app_role,uuid,uuid,uuid,boolean
) from public, anon, authenticated;
revoke all on function public.solver_feature_flag_set(text,jsonb)
  from public, anon, authenticated;

grant execute on function public.matrix_v2_create_draft(text) to authenticated;
grant execute on function public.matrix_v2_workspace(date) to authenticated;
grant execute on function public.matrix_v2_admin_save(text,uuid,jsonb) to authenticated;
grant execute on function public.matrix_v2_publish_draft(date) to authenticated;
grant execute on function public.employee_time_constraint_save_v2(
  uuid,uuid,text,timestamptz,timestamptz,text
) to authenticated;
grant execute on function public.employee_pay_rate_save_v2(
  uuid,uuid,date,date,bigint,text,text,boolean
) to authenticated;
grant execute on function public.employee_time_constraint_revoke_v2(uuid)
  to authenticated;
grant execute on function public.matrix_scope_grant_save_v2(
  uuid,uuid,public.app_role,uuid,uuid,uuid,boolean
) to authenticated;
grant execute on function public.solver_feature_flag_set(text,jsonb) to authenticated;
