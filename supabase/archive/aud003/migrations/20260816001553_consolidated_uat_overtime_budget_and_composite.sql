-- GRAFIK PRO consolidated UAT batch (2026-08-16).
-- Repair the merge-candidate response produced by the publication fallback.
-- Publication still revalidates the variant set server-side; these fields are
-- display metadata and must not be allowed to hide the publication action.

create or replace function public.optimizer_role_composite_candidates_v2(
  p_month date,
  p_scenario_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_raw jsonb;
  v_overview jsonb;
  v_roles jsonb;
begin
  v_raw := public.optimizer_role_composite_candidates_before_publication_fallback_uat_v1(
    p_month, p_scenario_id
  );
  if jsonb_array_length(coalesce(v_raw->'roles', '[]'::jsonb)) > 0 then
    return v_raw;
  end if;

  v_overview := public.optimizer_role_publication_overview_uat_v2(p_month);
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', item.value->'role'->>'id',
    'name', item.value->'role'->>'name',
    'sortOrder', item.ordinality,
    'variant', jsonb_build_object(
      'id', item.value->>'variantId',
      'name', coalesce(nullif(item.value->>'name', ''), 'Opublikowany wariant zespołu'),
      'strategy', jsonb_build_object(
        'id', 'PUBLISHED_ROLE_VARIANT',
        'name', 'Opublikowany wariant zespołu'
      ),
      'assignmentCount', coalesce((item.value->>'assignmentCount')::integer, 0),
      'unfilledCount', coalesce((item.value->>'unfilledCount')::integer, 0),
      'solverStatus', 'PUBLISHED'
    )
  ) order by item.ordinality), '[]'::jsonb)
  into v_roles
  from jsonb_array_elements(coalesce(v_overview->'roles', '[]'::jsonb))
    with ordinality item(value, ordinality)
  where item.value->'scenario'->>'id' = p_scenario_id::text
    and nullif(item.value->>'variantId', '') is not null;

  if jsonb_array_length(v_roles) = 0 then
    return v_raw;
  end if;

  return jsonb_set(
    jsonb_set(
      jsonb_set(v_raw, '{roles}', v_roles, true),
      '{missingRoleIds}', '[]'::jsonb, true
    ),
    '{ready}', 'true'::jsonb, true
  );
end;
$$;

revoke all on function public.optimizer_role_composite_candidates_v2(date, uuid)
  from public, anon;
grant execute on function public.optimizer_role_composite_candidates_v2(date, uuid)
  to authenticated;

notify pgrst, 'reload schema';

-- A person must never be labelled as reserve for the same role/day that still
-- has an uncovered required seat. Required staffing wins over standby.
alter function solver_private.generate_standby_for_variant_uat_v2(uuid,date,uuid,uuid,uuid,uuid)
  rename to generate_standby_before_shortage_guard_uat_v1;

create function solver_private.generate_standby_for_variant_uat_v2(
  p_variant_id uuid,p_month date,p_matrix_version_id uuid,p_role_id uuid,
  p_source_schedule_id uuid,p_source_role_schedule_id uuid
) returns integer language plpgsql security definer set search_path='' as $$
declare v_created integer;
begin
  v_created:=solver_private.generate_standby_before_shortage_guard_uat_v1(
    p_variant_id,p_month,p_matrix_version_id,p_role_id,p_source_schedule_id,p_source_role_schedule_id);
  update public.published_standby_assignments_v2 standby set status='SUPERSEDED'
  where standby.source_variant_id=p_variant_id and standby.role_id=p_role_id
    and standby.status='PLANNED' and exists(
      select 1 from public.plan_issues_v2 issue
      join public.plan_shifts_v2 shift_row on shift_row.id=issue.shift_id
      where issue.variant_id=p_variant_id and issue.role_id=p_role_id
        and issue.issue_code='UNFILLED_SLOT' and shift_row.shift_date=standby.standby_date
    );
  return (select count(*) from public.published_standby_assignments_v2 standby
    where standby.source_variant_id=p_variant_id and standby.role_id=p_role_id
      and standby.status='PLANNED'
      and standby.source_schedule_id is not distinct from p_source_schedule_id
      and standby.source_role_schedule_id is not distinct from p_source_role_schedule_id);
end; $$;

alter function public.optimizer_variant_standby_preview_uat_v1(uuid)
  rename to optimizer_variant_standby_preview_before_shortage_guard_uat_v1;
create function public.optimizer_variant_standby_preview_uat_v1(p_variant_id uuid)
returns jsonb language sql volatile security definer set search_path='' as $$
  select coalesce(jsonb_agg(item.value order by item.ordinality),'[]'::jsonb)
  from jsonb_array_elements(public.optimizer_variant_standby_preview_before_shortage_guard_uat_v1(p_variant_id))
    with ordinality item(value,ordinality)
  where not exists(
    select 1 from public.plan_issues_v2 issue
    join public.plan_shifts_v2 shift_row on shift_row.id=issue.shift_id
    where issue.variant_id=p_variant_id and issue.role_id=(item.value->>'roleId')::uuid
      and issue.issue_code='UNFILLED_SLOT' and shift_row.shift_date=(item.value->>'date')::date
  );
$$;

revoke all on function solver_private.generate_standby_before_shortage_guard_uat_v1(uuid,date,uuid,uuid,uuid,uuid)
  from public,anon,authenticated;
grant execute on function solver_private.generate_standby_for_variant_uat_v2(uuid,date,uuid,uuid,uuid,uuid)
  to service_role;
revoke all on function public.optimizer_variant_standby_preview_uat_v1(uuid) from public,anon;
grant execute on function public.optimizer_variant_standby_preview_uat_v1(uuid) to authenticated;

notify pgrst, 'reload schema';

alter function solver_private.matrix_v2_full_import_phase_uat_v1(jsonb,text)
  rename to matrix_v2_full_import_phase_before_overtime_uat_v1;

create function solver_private.matrix_v2_full_import_phase_uat_v1(
  p_configuration jsonb, p_phase text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_result jsonb; v_matrix uuid; v_item jsonb; v_policy text; v_employee uuid;
begin
  v_result:=solver_private.matrix_v2_full_import_phase_before_overtime_uat_v1(p_configuration,p_phase);
  if upper(trim(coalesce(p_phase,'')))<>'POST' then return v_result; end if;
  select id into v_matrix from public.matrix_versions where status='DRAFT' and schema_version>=2 order by version desc limit 1;
  for v_item in select value from jsonb_array_elements(coalesce(p_configuration->'employees','[]'::jsonb)) loop
    v_policy:=upper(coalesce(nullif(v_item->>'overtimePolicy',''),'NEVER'));
    if v_policy not in ('NEVER','APPROVAL_REQUIRED','ALLOWED') then raise exception 'INVALID_OVERTIME_POLICY'; end if;
    select profile.employee_id into v_employee from public.matrix_employee_profiles_v2 profile
      where profile.matrix_version_id=v_matrix and (
        (nullif(trim(v_item->>'employeeNo'),'') is not null and upper(profile.employee_no)=upper(trim(v_item->>'employeeNo')))
        or (nullif(trim(v_item->>'email'),'') is not null and lower(profile.email)=lower(trim(v_item->>'email')))
      ) order by case when upper(profile.employee_no)=upper(trim(v_item->>'employeeNo')) then 0 else 1 end limit 1;
    if v_employee is not null then update public.matrix_employee_profiles_v2 set overtime_policy=v_policy,updated_by=auth.uid(),updated_at=now()
      where matrix_version_id=v_matrix and employee_id=v_employee; end if;
  end loop;
  return v_result;
end; $$;

revoke all on function solver_private.matrix_v2_full_import_phase_before_overtime_uat_v1(jsonb,text)
  from public,anon,authenticated;
grant execute on function solver_private.matrix_v2_full_import_phase_uat_v1(jsonb,text)
  to service_role;

notify pgrst, 'reload schema';

-- Monthly planning budgets have their own revisions. Changing an amount does
-- not create a new company-configuration version.
create table if not exists public.monthly_budget_revisions_v2 (
  id uuid primary key default gen_random_uuid(),
  budget_month date not null check (budget_month = date_trunc('month', budget_month)::date),
  revision integer not null check (revision > 0),
  status text not null check (status in ('ACTIVE','ARCHIVED')),
  note text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  archived_at timestamptz,
  unique (budget_month, revision)
);

create unique index if not exists monthly_budget_revisions_v2_one_active
  on public.monthly_budget_revisions_v2(budget_month) where status = 'ACTIVE';

create table if not exists public.monthly_budget_lines_v2 (
  id uuid primary key default gen_random_uuid(),
  revision_id uuid not null references public.monthly_budget_revisions_v2(id) on delete cascade,
  scope_type text not null check (scope_type in ('COMPANY','LOCATION','CATEGORY','LOCATION_CATEGORY','ROLE')),
  location_logical_id uuid,
  category_logical_id uuid,
  role_logical_id uuid,
  metric_type text not null check (metric_type in ('COST','HOURS','LABOR_PERCENT')),
  enforcement text not null check (enforcement in ('HARD','TARGET','MONITORING')),
  limit_value numeric(18,4) not null check (limit_value >= 0),
  reference_value numeric(18,4) check (reference_value is null or reference_value >= 0),
  currency text check (currency is null or currency ~ '^[A-Z]{3}$'),
  cost_basis text check (cost_basis is null or cost_basis in ('WAGES','FULL_EMPLOYER_COST')),
  distribution_mode text not null default 'MONTHLY' check (distribution_mode in ('MONTHLY','AUTO','MANUAL')),
  distribution jsonb,
  check ((scope_type in ('LOCATION','LOCATION_CATEGORY')) = (location_logical_id is not null)),
  check ((scope_type in ('CATEGORY','LOCATION_CATEGORY')) = (category_logical_id is not null)),
  check ((scope_type = 'ROLE') = (role_logical_id is not null)),
  check ((metric_type = 'COST') = (currency is not null)),
  check (metric_type <> 'LABOR_PERCENT' or reference_value is not null or enforcement = 'MONITORING'),
  unique nulls not distinct (revision_id, scope_type, location_logical_id, category_logical_id, role_logical_id, metric_type)
);

alter table public.monthly_budget_revisions_v2 enable row level security;
alter table public.monthly_budget_lines_v2 enable row level security;
revoke all on table public.monthly_budget_revisions_v2, public.monthly_budget_lines_v2 from public, anon, authenticated;
grant all on table public.monthly_budget_revisions_v2, public.monthly_budget_lines_v2 to service_role;

create or replace function public.monthly_budgets_get_uat_v1(p_month date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_revision public.monthly_budget_revisions_v2%rowtype;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE')) then
    raise exception 'BUDGET_VIEW_FORBIDDEN';
  end if;
  select * into v_revision from public.monthly_budget_revisions_v2
    where budget_month = date_trunc('month', p_month)::date and status = 'ACTIVE';
  return jsonb_build_object(
    'month', date_trunc('month', p_month)::date,
    'canEdit', public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE'),
    'revision', case when v_revision.id is null then null else jsonb_build_object(
      'id', v_revision.id, 'number', v_revision.revision, 'note', v_revision.note,
      'createdAt', v_revision.created_at
    ) end,
    'lines', coalesce((select jsonb_agg(jsonb_build_object(
      'id', line.id, 'scopeType', line.scope_type,
      'locationLogicalId', line.location_logical_id,
      'categoryLogicalId', line.category_logical_id, 'roleLogicalId', line.role_logical_id,
      'metricType', line.metric_type, 'enforcement', line.enforcement,
      'limitValue', line.limit_value, 'referenceValue', line.reference_value,
      'currency', line.currency, 'costBasis', line.cost_basis,
      'distributionMode', line.distribution_mode, 'distribution', line.distribution
    ) order by line.scope_type, line.location_logical_id, line.category_logical_id, line.role_logical_id, line.metric_type)
    from public.monthly_budget_lines_v2 line where line.revision_id = v_revision.id), '[]'::jsonb)
  );
end;
$$;

create or replace function public.monthly_budgets_save_uat_v1(
  p_month date, p_lines jsonb, p_note text
) returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare v_month date := date_trunc('month', p_month)::date;
  v_revision_id uuid; v_revision integer; v_line jsonb; v_scope text;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE')) then
    raise exception 'BUDGET_EDIT_FORBIDDEN';
  end if;
  if jsonb_typeof(p_lines) <> 'array' then raise exception 'BUDGET_LINES_MUST_BE_ARRAY'; end if;
  perform pg_advisory_xact_lock(hashtext('monthly-budget:' || v_month::text));
  select coalesce(max(revision),0)+1 into v_revision from public.monthly_budget_revisions_v2 where budget_month=v_month;
  update public.monthly_budget_revisions_v2 set status='ARCHIVED', archived_at=now()
    where budget_month=v_month and status='ACTIVE';
  insert into public.monthly_budget_revisions_v2(budget_month,revision,status,note,created_by)
    values(v_month,v_revision,'ACTIVE',nullif(trim(p_note),''),auth.uid()) returning id into v_revision_id;
  for v_line in select value from jsonb_array_elements(p_lines) loop
    v_scope:=upper(coalesce(v_line->>'scopeType',''));
    if v_scope not in ('COMPANY','LOCATION','CATEGORY','LOCATION_CATEGORY','ROLE') then raise exception 'INVALID_BUDGET_SCOPE'; end if;
    insert into public.monthly_budget_lines_v2(
      revision_id,scope_type,location_logical_id,category_logical_id,role_logical_id,
      metric_type,enforcement,limit_value,reference_value,currency,cost_basis,
      distribution_mode,distribution
    ) values(
      v_revision_id,v_scope,coalesce(nullif(v_line->>'locationLogicalId','')::uuid,(
        select location_row.logical_id from public.matrix_locations_v2 location_row
        where location_row.id=nullif(v_line->>'locationId','')::uuid limit 1
      )),coalesce(nullif(v_line->>'categoryLogicalId','')::uuid,(
        select category.logical_id from public.matrix_role_categories_v2 category
        where category.id=nullif(v_line->>'categoryId','')::uuid limit 1
      )),coalesce(nullif(v_line->>'roleLogicalId','')::uuid,(
        select role_row.logical_id from public.matrix_roles_v2 role_row
        where role_row.id=nullif(v_line->>'roleId','')::uuid limit 1
      )),upper(coalesce(nullif(v_line->>'metricType',''),'COST')),
      upper(coalesce(nullif(v_line->>'enforcement',''),'TARGET')),
      coalesce((v_line->>'limitValue')::numeric,0),nullif(v_line->>'referenceValue','')::numeric,
      case when upper(coalesce(nullif(v_line->>'metricType',''),'COST'))='COST'
        then upper(coalesce(nullif(v_line->>'currency',''),'PLN')) else null end,
      case when upper(coalesce(nullif(v_line->>'metricType',''),'COST'))='COST'
        then upper(coalesce(nullif(v_line->>'costBasis',''),'WAGES')) else null end,
      upper(coalesce(nullif(v_line->>'distributionMode',''),'MONTHLY')),
      case when jsonb_typeof(v_line->'distribution')='object' then v_line->'distribution' else null end
    );
  end loop;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
    values(auth.uid(),'monthly_budget_revision',v_revision_id::text,'PUBLISH',
      jsonb_build_object('month',v_month,'revision',v_revision,'lineCount',jsonb_array_length(p_lines),'note',p_note));
  return public.monthly_budgets_get_uat_v1(v_month);
end;
$$;

revoke all on function public.monthly_budgets_get_uat_v1(date),
  public.monthly_budgets_save_uat_v1(date,jsonb,text) from public, anon;
grant execute on function public.monthly_budgets_get_uat_v1(date),
  public.monthly_budgets_save_uat_v1(date,jsonb,text) to authenticated;

alter function solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)
  rename to build_snapshot_payload_before_monthly_budget_uat_v1;

create function solver_private.build_snapshot_payload_v2(
  p_run_id uuid,p_month date,p_matrix_version_id uuid,p_scenario_id uuid,
  p_scope_type text,p_scope_role_id uuid
) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_snapshot jsonb; v_revision uuid; v_budgets jsonb;
  v_strategies jsonb:='[]'::jsonb; v_strategy jsonb; v_terms jsonb; v_max_tier integer;
begin
  v_snapshot:=solver_private.build_snapshot_payload_before_monthly_budget_uat_v1(
    p_run_id,p_month,p_matrix_version_id,p_scenario_id,p_scope_type,p_scope_role_id);
  select id into v_revision from public.monthly_budget_revisions_v2
    where budget_month=date_trunc('month',p_month)::date and status='ACTIVE';
  if v_revision is null then return v_snapshot; end if;
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
    'id',line.id,'metricType',line.metric_type,'enforcement',line.enforcement,
    'amountMinor',case when line.metric_type='COST' then round(line.limit_value*100)::bigint
      when line.metric_type='LABOR_PERCENT' and line.reference_value is not null
        then round(line.reference_value*100*line.limit_value/100)::bigint else null end,
    'limitMinutes',case when line.metric_type='HOURS' then round(line.limit_value*60)::bigint else null end,
    'limitBps',case when line.metric_type='LABOR_PERCENT' then round(line.limit_value*100)::bigint else null end,
    'referenceAmountMinor',case when line.reference_value is not null then round(line.reference_value*100)::bigint else null end,
    'hard',line.enforcement='HARD',
    'locationId',location_row.id,
    'roleIds',case when line.role_logical_id is not null then coalesce((
      select jsonb_agg(role_row.id) from public.matrix_roles_v2 role_row
      where role_row.matrix_version_id=p_matrix_version_id
        and role_row.logical_id=line.role_logical_id and role_row.active
    ),'[]'::jsonb) when line.category_logical_id is null then '[]'::jsonb else coalesce((
      select jsonb_agg(role_row.id) from public.matrix_role_categories_v2 category
      join public.matrix_roles_v2 role_row on role_row.category_id=category.id and role_row.active
      where category.matrix_version_id=p_matrix_version_id
        and category.logical_id=line.category_logical_id and category.active
    ),'[]'::jsonb) end
  ))),'[]'::jsonb) into v_budgets
  from public.monthly_budget_lines_v2 line
  left join public.matrix_locations_v2 location_row
    on location_row.matrix_version_id=p_matrix_version_id
   and location_row.logical_id=line.location_logical_id and location_row.active
  where line.revision_id=v_revision;
  v_snapshot:=jsonb_set(v_snapshot,'{budgets}',v_budgets,true);
  v_snapshot:=jsonb_set(v_snapshot,'{budgetRevisionId}',to_jsonb(v_revision),true);
  if exists(select 1 from public.monthly_budget_lines_v2 line where line.revision_id=v_revision and line.enforcement='TARGET') then
    for v_strategy in select value from jsonb_array_elements(coalesce(v_snapshot->'strategies','[]'::jsonb)) loop
      v_terms:=coalesce(v_strategy->'objectiveTerms','[]'::jsonb);
      select coalesce(max((term.value->>'tier')::integer),0) into v_max_tier
        from jsonb_array_elements(v_terms) term(value);
      v_terms:=v_terms||jsonb_build_array(jsonb_build_object(
        'tier',v_max_tier+1,'metric','BUDGET_TARGET_EXCESS','weight',1,'direction','MIN'
      ));
      v_strategies:=v_strategies||jsonb_build_array(jsonb_set(v_strategy,'{objectiveTerms}',v_terms,true));
    end loop;
    v_snapshot:=jsonb_set(v_snapshot,'{strategies}',v_strategies,true);
  end if;
  return v_snapshot;
end; $$;

revoke all on function solver_private.build_snapshot_payload_before_monthly_budget_uat_v1(uuid,date,uuid,uuid,text,uuid)
  from public,anon,authenticated;
grant execute on function solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)
  to service_role;

notify pgrst, 'reload schema';

alter function solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)
  rename to build_snapshot_payload_before_overtime_pricing_uat_v1;

create function solver_private.build_snapshot_payload_v2(
  p_run_id uuid,p_month date,p_matrix_version_id uuid,p_scenario_id uuid,
  p_scope_type text,p_scope_role_id uuid
) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_snapshot jsonb; v_rules jsonb:='[]'::jsonb; v_rule jsonb; v_formula jsonb;
begin
  v_snapshot:=solver_private.build_snapshot_payload_before_overtime_pricing_uat_v1(
    p_run_id,p_month,p_matrix_version_id,p_scenario_id,p_scope_type,p_scope_role_id);
  for v_rule in select value from jsonb_array_elements(coalesce(v_snapshot->'payRules','[]'::jsonb)) loop
    select coalesce(rule.formula_expression,'{}'::jsonb) into v_formula
      from public.matrix_pay_rules_v2 rule where rule.id=(v_rule->>'id')::uuid;
    if upper(coalesce(v_rule->>'calculationType',''))='MONTHLY_THRESHOLD_PER_HOUR' then
      v_rule:=jsonb_set(v_rule,'{values}',coalesce(v_rule->'values','{}'::jsonb)||jsonb_build_object(
        'thresholdSource',coalesce(nullif(v_formula->>'thresholdSource',''),'FIXED')
      ),true);
    end if;
    v_rules:=v_rules||jsonb_build_array(v_rule);
  end loop;
  v_snapshot:=jsonb_set(v_snapshot,'{payRules}',v_rules,true);
  if exists(select 1 from jsonb_array_elements(coalesce(v_snapshot->'employees','[]'::jsonb)) employee
      where employee.value->>'overtimePolicy' in ('ALLOWED','APPROVAL_REQUIRED'))
    and not exists(select 1 from jsonb_array_elements(v_rules) rule
      where upper(rule.value->>'calculationType')='MONTHLY_THRESHOLD_PER_HOUR'
        and rule.value->'values'->>'thresholdSource'='EMPLOYEE_NOMINAL') then
    raise exception 'OVERTIME_PAY_RULE_MISSING';
  end if;
  return v_snapshot;
end; $$;

revoke all on function solver_private.build_snapshot_payload_before_overtime_pricing_uat_v1(uuid,date,uuid,uuid,text,uuid)
  from public,anon,authenticated;
grant execute on function solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)
  to service_role;

notify pgrst, 'reload schema';

-- Explicit global overtime consent. Existing UAT data remains safely NEVER;
-- a location permission may narrow ALLOWED but can never broaden NEVER.
alter table public.matrix_employee_profiles_v2
  add column if not exists overtime_policy text not null default 'NEVER';

do $$ begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'matrix_employee_profiles_v2_overtime_policy_check'
  ) then
    alter table public.matrix_employee_profiles_v2
      add constraint matrix_employee_profiles_v2_overtime_policy_check
      check (overtime_policy in ('NEVER','APPROVAL_REQUIRED','ALLOWED'));
  end if;
end $$;

create or replace function solver_private.inherit_employee_overtime_policy_uat_v1()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  select previous.overtime_policy into new.overtime_policy
  from public.matrix_employee_profiles_v2 previous
  join public.matrix_versions version_row on version_row.id = previous.matrix_version_id
  where previous.employee_id = new.employee_id
    and previous.matrix_version_id <> new.matrix_version_id
  order by case version_row.status when 'ACTIVE' then 0 when 'ARCHIVED' then 1 else 2 end,
    version_row.effective_from desc nulls last, version_row.version desc
  limit 1;
  new.overtime_policy := coalesce(new.overtime_policy, 'NEVER');
  return new;
end;
$$;

drop trigger if exists matrix_employee_overtime_policy_inherit_uat_v1
  on public.matrix_employee_profiles_v2;
create trigger matrix_employee_overtime_policy_inherit_uat_v1
before insert on public.matrix_employee_profiles_v2
for each row execute function solver_private.inherit_employee_overtime_policy_uat_v1();

alter function public.matrix_v2_workspace(date)
  rename to matrix_v2_workspace_before_overtime_uat_v1;

create function public.matrix_v2_workspace(p_month date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
  v_matrix uuid;
  v_employees jsonb := '[]'::jsonb;
  v_employee jsonb;
  v_locations jsonb := '[]'::jsonb;
  v_location jsonb;
  v_categories jsonb := '[]'::jsonb;
  v_category jsonb;
  v_roles jsonb := '[]'::jsonb;
  v_role jsonb;
begin
  v_result := public.matrix_v2_workspace_before_overtime_uat_v1(p_month);
  v_matrix := nullif(v_result->'matrixVersion'->>'id', '')::uuid;
  for v_employee in
    select value from jsonb_array_elements(coalesce(v_result->'employees', '[]'::jsonb))
  loop
    v_employee := v_employee || jsonb_build_object(
      'overtimePolicy', coalesce((
        select profile.overtime_policy
        from public.matrix_employee_profiles_v2 profile
        where profile.matrix_version_id = v_matrix
          and profile.employee_id = (v_employee->>'id')::uuid
      ), 'NEVER')
    );
    v_employees := v_employees || jsonb_build_array(v_employee);
  end loop;
  v_result := jsonb_set(v_result, '{employees}', v_employees, true);
  for v_location in select value from jsonb_array_elements(coalesce(v_result->'locations','[]'::jsonb)) loop
    v_location := v_location || jsonb_build_object('logicalId',(
      select location_row.logical_id from public.matrix_locations_v2 location_row
      where location_row.id=(v_location->>'id')::uuid
    ));
    v_locations := v_locations || jsonb_build_array(v_location);
  end loop;
  v_result := jsonb_set(v_result, '{locations}', v_locations, true);
  for v_role in select value from jsonb_array_elements(coalesce(v_result->'roles','[]'::jsonb)) loop
    v_role := v_role || jsonb_build_object('logicalId',(
      select role_row.logical_id from public.matrix_roles_v2 role_row
      where role_row.id=(v_role->>'id')::uuid
    ));
    v_roles := v_roles || jsonb_build_array(v_role);
  end loop;
  v_result := jsonb_set(v_result, '{roles}', v_roles, true);
  for v_category in select value from jsonb_array_elements(coalesce(v_result->'roleCategories','[]'::jsonb)) loop
    v_category := v_category || jsonb_build_object('logicalId',(
      select category.logical_id from public.matrix_role_categories_v2 category
      where category.id=(v_category->>'id')::uuid
    ));
    v_categories := v_categories || jsonb_build_array(v_category);
  end loop;
  return jsonb_set(v_result, '{roleCategories}', v_categories, true);
end;
$$;

create or replace function public.matrix_v2_employee_save_uat_v4(
  p_employee_id uuid default null,
  p_data jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
  v_employee uuid;
  v_matrix uuid;
  v_stage text;
  v_overtime_policy text;
  v_contract text;
  v_fraction numeric;
  v_work_time_policy text;
  v_start date;
  v_end date;
begin
  if nullif(p_data->>'employmentStart','') is not null
    and not pg_catalog.pg_input_is_valid(p_data->>'employmentStart','date') then
    raise exception 'INVALID_EMPLOYMENT_DATES';
  end if;
  if nullif(p_data->>'employmentEnd','') is not null
    and not pg_catalog.pg_input_is_valid(p_data->>'employmentEnd','date') then
    raise exception 'INVALID_EMPLOYMENT_DATES';
  end if;
  v_start:=nullif(p_data->>'employmentStart','')::date;
  v_end:=nullif(p_data->>'employmentEnd','')::date;
  if v_end is not null and (v_start is null or v_end<v_start) then
    raise exception 'INVALID_EMPLOYMENT_DATES';
  end if;
  if p_employee_id is not null and exists(
    select 1 from public.employee_pay_rates_v2 rate
    where rate.employee_id=p_employee_id and (
      (v_start is not null and rate.valid_from<v_start)
      or (v_end is not null and (
        rate.valid_from>v_end or rate.valid_to is null or rate.valid_to>v_end
      ))
    )
  ) then raise exception 'EMPLOYMENT_DATES_CONFLICT_PAY_RATES'; end if;
  v_result := public.matrix_v2_employee_save_alpha16(p_employee_id, p_data);
  v_employee := (v_result->>'id')::uuid;
  select id into v_matrix from public.matrix_versions
    where status = 'DRAFT' and schema_version >= 2
    order by version desc limit 1;
  v_stage := case upper(coalesce(nullif(p_data->>'employmentStage',''),'REGULAR'))
    when 'PROBATION' then 'PROBATION'
    when 'NOTICE' then 'NOTICE'
    else 'REGULAR' end;
  v_overtime_policy := upper(coalesce(nullif(p_data->>'overtimePolicy',''),'NEVER'));
  if v_overtime_policy not in ('NEVER','APPROVAL_REQUIRED','ALLOWED') then
    raise exception 'INVALID_OVERTIME_POLICY';
  end if;
  if p_data ? 'contractType' then
    v_contract:=solver_private.normalize_contract_type_v2(p_data->>'contractType');
    v_fraction:=greatest(.01,least(1,coalesce(
      nullif(replace(p_data->>'employmentFraction',',','.'),'')::numeric,1
    )));
    insert into public.employee_hr_profiles(
      employee_id,contract_type,employment_fraction,updated_by,updated_at
    ) values(v_employee,v_contract,v_fraction,auth.uid(),now())
    on conflict(employee_id) do update set
      contract_type=excluded.contract_type,
      employment_fraction=excluded.employment_fraction,
      updated_by=auth.uid(),updated_at=now();
  end if;
  if p_data ? 'workTimePolicy' then
    v_work_time_policy:=case when upper(coalesce(p_data->>'workTimePolicy',''))='CUSTOM'
      then 'CUSTOM' else 'CONTRACT_DEFAULT' end;
  else
    select profile.work_time_policy into v_work_time_policy
    from public.matrix_employee_profiles_v2 profile
    where profile.employee_id=v_employee and profile.matrix_version_id=v_matrix;
    v_work_time_policy:=coalesce(v_work_time_policy,'CONTRACT_DEFAULT');
  end if;
  update public.matrix_employee_profiles_v2 set
    employment_stage = v_stage,
    probation_end = nullif(p_data->>'probationEnd','')::date,
    overtime_policy = v_overtime_policy,
    work_time_policy = v_work_time_policy,
    updated_by = auth.uid(),
    updated_at = now()
  where matrix_version_id = v_matrix and employee_id = v_employee;
  return v_result || jsonb_build_object(
    'employmentStage', v_stage,
    'probationEnd', nullif(p_data->>'probationEnd',''),
    'overtimePolicy', v_overtime_policy,
    'contractType',coalesce(v_contract,(select profile.contract_type
      from public.employee_hr_profiles profile where profile.employee_id=v_employee)),
    'workTimePolicy',v_work_time_policy
  );
end;
$$;

alter function solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)
  rename to build_snapshot_payload_before_overtime_uat_v1;

create function solver_private.build_snapshot_payload_v2(
  p_run_id uuid,
  p_month date,
  p_matrix_version_id uuid,
  p_scenario_id uuid,
  p_scope_type text,
  p_scope_role_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_snapshot jsonb;
  v_employees jsonb := '[]'::jsonb;
  v_employee jsonb;
begin
  v_snapshot := solver_private.build_snapshot_payload_before_overtime_uat_v1(
    p_run_id, p_month, p_matrix_version_id, p_scenario_id,
    p_scope_type, p_scope_role_id
  );
  for v_employee in
    select value from jsonb_array_elements(coalesce(v_snapshot->'employees', '[]'::jsonb))
  loop
    v_employee := v_employee || jsonb_build_object(
      'overtimePolicy', coalesce((
        select profile.overtime_policy
        from public.matrix_employee_profiles_v2 profile
        where profile.matrix_version_id = p_matrix_version_id
          and profile.employee_id = (v_employee->>'id')::uuid
      ), 'NEVER')
    );
    v_employees := v_employees || jsonb_build_array(v_employee);
  end loop;
  v_snapshot:=jsonb_set(v_snapshot, '{employees}', v_employees, true);
  if exists(select 1 from jsonb_array_elements(v_employees) employee
      where employee.value->>'overtimePolicy' in ('ALLOWED','APPROVAL_REQUIRED'))
    and not exists(select 1 from jsonb_array_elements(coalesce(v_snapshot->'payRules','[]'::jsonb)) rule
      where upper(rule.value->>'calculationType')='MONTHLY_THRESHOLD_PER_HOUR'
        and rule.value->'values'->>'thresholdSource'='EMPLOYEE_NOMINAL') then
    raise exception 'OVERTIME_PAY_RULE_MISSING';
  end if;
  return v_snapshot;
end;
$$;

revoke all on function public.matrix_v2_workspace(date),
  public.matrix_v2_employee_save_uat_v4(uuid,jsonb)
  from public, anon;
grant execute on function public.matrix_v2_workspace(date),
  public.matrix_v2_employee_save_uat_v4(uuid,jsonb)
  to authenticated;
revoke all on function solver_private.build_snapshot_payload_before_overtime_uat_v1(uuid,date,uuid,uuid,text,uuid)
  from public, anon, authenticated;
grant execute on function solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)
  to service_role;

notify pgrst, 'reload schema';
