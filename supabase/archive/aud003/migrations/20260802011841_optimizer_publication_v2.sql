-- GRAFIK PRO 3.0 — solver v2 publication and dynamic schedule workspaces
--
-- Publication remains native to the UUID-based Matrix v2 model. It does not
-- project dynamic roles or duties back into the legacy enums.

create table public.published_schedules_v2 (
  id uuid primary key default gen_random_uuid(),
  idempotency_key text not null check (length(idempotency_key) between 8 and 200),
  month date not null check (date_trunc('month',month)::date=month),
  matrix_version_id uuid not null references public.matrix_versions(id),
  scenario_id uuid not null references public.matrix_scenarios_v2(id),
  source_type text not null check (source_type in ('COMPANY','ROLE_COMPOSITE')),
  name text not null check (length(trim(name)) between 1 and 200),
  status text not null default 'PUBLISHED' check (status in ('PUBLISHED','ARCHIVED')),
  publication_hash text not null check (publication_hash ~ '^[0-9a-f]{64}$'),
  validation_snapshot_hash text not null
    check (validation_snapshot_hash ~ '^[0-9a-f]{64}$'),
  validation_summary jsonb not null default '{}'::jsonb,
  created_by uuid not null references auth.users(id),
  published_at timestamptz not null default now(),
  archived_at timestamptz,
  archived_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  unique(created_by,idempotency_key),
  check (
    (status='PUBLISHED' and archived_at is null and archived_by is null)
    or (status='ARCHIVED' and archived_at is not null)
  )
);

create table public.published_schedule_variants_v2 (
  schedule_id uuid not null
    references public.published_schedules_v2(id) on delete restrict,
  variant_id uuid not null
    references public.plan_variants_v2(id) on delete restrict,
  role_id uuid references public.matrix_roles_v2(id),
  ordinal integer not null check (ordinal > 0),
  created_at timestamptz not null default now(),
  primary key(schedule_id,variant_id),
  unique(schedule_id,ordinal)
);

create table solver_private.published_schedule_finance_v2 (
  schedule_id uuid primary key
    references public.published_schedules_v2(id) on delete cascade,
  base_cost_units bigint not null check (base_cost_units >= 0),
  additions_cost_units bigint not null check (additions_cost_units >= 0),
  total_cost_units bigint not null check (total_cost_units >= 0),
  base_cost_minor bigint not null check (base_cost_minor >= 0),
  additions_cost_minor bigint not null check (additions_cost_minor >= 0),
  total_cost_minor bigint not null check (total_cost_minor >= 0),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  budget_minor bigint check (budget_minor is null or budget_minor >= 0),
  hard_budget boolean not null,
  created_at timestamptz not null default now(),
  check (base_cost_units+additions_cost_units=total_cost_units),
  check (base_cost_minor+additions_cost_minor=total_cost_minor)
);

create unique index published_schedules_v2_one_current_month
  on public.published_schedules_v2(month)
  where status='PUBLISHED';
create index published_schedules_v2_scenario_month_idx
  on public.published_schedules_v2(scenario_id,month,created_at desc);
create index published_schedules_v2_matrix_idx
  on public.published_schedules_v2(matrix_version_id);
create index published_schedule_variants_v2_variant_idx
  on public.published_schedule_variants_v2(variant_id);
create unique index published_schedule_variants_v2_one_role
  on public.published_schedule_variants_v2(schedule_id,role_id)
  where role_id is not null;

alter table public.published_schedules_v2 enable row level security;
alter table public.published_schedule_variants_v2 enable row level security;

create policy published_schedules_v2_manage_read
on public.published_schedules_v2
for select to authenticated
using (
  (select public.has_app_role('OWNER'))
  or (select public.has_app_role('ADMIN'))
  or (select public.has_app_role('HR_FINANCE'))
  or (select public.has_app_role('VERIFIER'))
);

create policy published_schedule_variants_v2_manage_read
on public.published_schedule_variants_v2
for select to authenticated
using (
  (
    (select public.has_app_role('OWNER'))
    or (select public.has_app_role('ADMIN'))
    or (select public.has_app_role('HR_FINANCE'))
    or (select public.has_app_role('VERIFIER'))
  )
  and exists(
    select 1
    from public.published_schedules_v2 s
    where s.id=schedule_id
  )
);

revoke all on public.published_schedules_v2,
  public.published_schedule_variants_v2
  from public,anon,authenticated;
grant select on public.published_schedules_v2,
  public.published_schedule_variants_v2
  to authenticated;
grant all on public.published_schedules_v2,
  public.published_schedule_variants_v2
  to service_role;
revoke all on solver_private.published_schedule_finance_v2
  from public,anon,authenticated;
grant all on solver_private.published_schedule_finance_v2 to service_role;

create or replace function solver_private.publication_snapshot_basis_v2(
  p_snapshot jsonb
)
returns jsonb
language sql
immutable
security definer
set search_path = ''
as $$
  select jsonb_set(
    coalesce(p_snapshot,'{}'::jsonb)
      -'runId'-'baselineAssignments',
    '{settings}',
    coalesce(p_snapshot->'settings','{}'::jsonb)-'randomSeed',
    true
  );
$$;

-- External assignments can legitimately change while independently solved
-- ROLE variants are being selected. They are excluded only from the static
-- input comparison; the current external set is still enforced by the fresh
-- validator, and the final ROLE composite is validated as one COMPANY payload.
-- Locked assignments remain part of both hashes and of hard validation.
create or replace function solver_private.publication_static_input_hash_v2(
  p_snapshot jsonb
)
returns text
language sql
immutable
security definer
set search_path = ''
as $$
  select encode(extensions.digest(convert_to(
    solver_private.canonical_json_v2(
      solver_private.publication_snapshot_basis_v2(p_snapshot)
        -'externalAssignments'
    ),
    'UTF8'
  ),'sha256'),'hex');
$$;

create or replace function solver_private.publication_snapshot_hash_v2(
  p_snapshot jsonb
)
returns text
language sql
immutable
security definer
set search_path = ''
as $$
  select encode(extensions.digest(convert_to(
    solver_private.canonical_json_v2(
      solver_private.publication_snapshot_basis_v2(p_snapshot)
    ),
    'UTF8'
  ),'sha256'),'hex');
$$;

create or replace function solver_private.materialized_variant_payload_v2(
  p_variant_ids uuid[],
  p_snapshot jsonb,
  p_strategy_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with requested as (
    select distinct x.variant_id
    from unnest(coalesce(p_variant_ids,'{}'::uuid[])) x(variant_id)
  ), assignment_rows as (
    select pa.id,pa.slot_key as slot_id,pa.employee_id
    from public.plan_assignments_v2 pa
    join requested r on r.variant_id=pa.variant_id
  ), assignment_payload as (
    select ar.slot_id as slot_key,ar.employee_id,
      coalesce((
        select sum((c.calculation_basis->>'costUnits')::bigint)
        from solver_private.plan_assignment_cost_components_v2 c
        where c.assignment_id=ar.id
      ),0)::bigint as cost_units,
      coalesce((
        select jsonb_agg(jsonb_build_object(
          'ruleId',coalesce(c.pay_rule_id::text,'BASE'),
          'calculationType',c.component_code,
          'costUnits',(c.calculation_basis->>'costUnits')::bigint
        ) order by c.id)
        from solver_private.plan_assignment_cost_components_v2 c
        where c.assignment_id=ar.id
      ),'[]'::jsonb) as cost_components
    from assignment_rows ar
  ), snapshot_slots as (
    select s.value->>'slotId' slot_id
    from jsonb_array_elements(coalesce(p_snapshot->'slots','[]'::jsonb)) s
  ), selected_map as (
    select jsonb_object_agg(
      s.slot_id,to_jsonb(a.employee_id) order by s.slot_id
    ) payload
    from snapshot_slots s
    left join assignment_rows a using(slot_id)
  )
  select jsonb_build_object(
    'schemaVersion',2,
    'strategyId',p_strategy_id,
    'solutionHash',(
      select encode(extensions.digest(convert_to(
        solver_private.canonical_json_v2(m.payload),'UTF8'
      ),'sha256'),'hex')
      from selected_map m
    ),
    'assignments',coalesce((
      select jsonb_agg(jsonb_build_object(
        'slotId',a.slot_key,
        'employeeId',a.employee_id,
        'costUnits',a.cost_units,
        'costComponents',a.cost_components
      ) order by a.slot_key,a.employee_id)
      from assignment_payload a
    ),'[]'::jsonb),
    'unfilledSlotIds',coalesce((
      select jsonb_agg(s.value->>'slotId' order by s.ordinality)
      from jsonb_array_elements(coalesce(p_snapshot->'slots','[]'::jsonb))
        with ordinality s(value,ordinality)
      where not exists(
        select 1 from assignment_rows a
        where a.slot_id=s.value->>'slotId'
      )
    ),'[]'::jsonb),
    'metrics',jsonb_build_object(
      'UNFILLED',(
        select count(*)
        from snapshot_slots s
        where not exists(
          select 1 from assignment_rows a where a.slot_id=s.slot_id
        )
      ),
      'TOTAL_COST',coalesce((select sum(a.cost_units) from assignment_payload a),0)
    ),
    'stageObjectives','[]'::jsonb,
    'optimal',false
  );
$$;

create or replace function solver_private.assert_materialized_variant_metadata_v2(
  p_variant_id uuid,
  p_snapshot jsonb
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_invalid bigint;
begin
  with slots as (
    select s.value item,s.value->>'slotId' slot_id
    from jsonb_array_elements(coalesce(p_snapshot->'slots','[]'::jsonb)) s
  )
  select count(*) into v_invalid
  from public.plan_assignments_v2 pa
  left join slots slot on slot.slot_id=pa.slot_key
  left join public.plan_shifts_v2 sh on sh.id=pa.shift_id
  where pa.variant_id=p_variant_id and (
    slot.slot_id is null
    or sh.id is null
    or sh.variant_id is distinct from pa.variant_id
    or sh.slot_group_key is distinct from slot.item->>'occurrenceId'
    or sh.shift_template_id is distinct from
      nullif(slot.item->>'shiftTemplateId','')::uuid
    or sh.location_id is distinct from nullif(slot.item->>'locationId','')::uuid
    or sh.shift_date is distinct from nullif(slot.item->>'date','')::date
    or sh.starts_at is distinct from nullif(slot.item->>'start','')::timestamptz
    or sh.ends_at is distinct from nullif(slot.item->>'end','')::timestamptz
    or pa.role_id is distinct from nullif(slot.item->>'roleId','')::uuid
    or array(
      select ad.duty_id::text
      from public.plan_assignment_duties_v2 ad
      where ad.assignment_id=pa.id
      order by ad.duty_id::text
    ) is distinct from array(
      select duty.value
      from jsonb_array_elements_text(
        coalesce(slot.item->'dutyIds','[]'::jsonb)
      ) duty(value)
      order by duty.value
    )
  );
  if v_invalid>0 then
    raise exception 'VARIANT_MATERIALIZATION_METADATA_MISMATCH';
  end if;

  with slots as (
    select s.value item
    from jsonb_array_elements(coalesce(p_snapshot->'slots','[]'::jsonb)) s
  )
  select count(*) into v_invalid
  from public.plan_shifts_v2 sh
  where sh.variant_id=p_variant_id and not exists(
    select 1 from slots slot
    where sh.slot_group_key=slot.item->>'occurrenceId'
      and sh.shift_template_id=nullif(slot.item->>'shiftTemplateId','')::uuid
      and sh.location_id=nullif(slot.item->>'locationId','')::uuid
      and sh.shift_date=nullif(slot.item->>'date','')::date
      and sh.starts_at=nullif(slot.item->>'start','')::timestamptz
      and sh.ends_at=nullif(slot.item->>'end','')::timestamptz
  );
  if v_invalid>0 then
    raise exception 'VARIANT_MATERIALIZATION_METADATA_MISMATCH';
  end if;

  with expected as (
    select distinct s.value->>'occurrenceId' slot_group_key,
      nullif(s.value->>'shiftTemplateId','')::uuid shift_template_id,
      nullif(s.value->>'locationId','')::uuid location_id,
      nullif(s.value->>'date','')::date shift_date,
      nullif(s.value->>'start','')::timestamptz starts_at,
      nullif(s.value->>'end','')::timestamptz ends_at
    from jsonb_array_elements(coalesce(p_snapshot->'slots','[]'::jsonb)) s
  )
  select count(*) into v_invalid
  from expected e
  where not exists(
    select 1 from public.plan_shifts_v2 sh
    where sh.variant_id=p_variant_id
      and sh.slot_group_key=e.slot_group_key
      and sh.shift_template_id=e.shift_template_id
      and sh.location_id=e.location_id
      and sh.shift_date=e.shift_date
      and sh.starts_at=e.starts_at
      and sh.ends_at=e.ends_at
  );
  if v_invalid>0 then
    raise exception 'VARIANT_MATERIALIZATION_METADATA_MISMATCH';
  end if;
end;
$$;

create or replace function solver_private.revalidate_materialized_variant_v2(
  p_variant_id uuid,
  p_neutralize_external boolean,
  p_validate_hard boolean
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_variant public.plan_variants_v2%rowtype;
  v_run public.optimization_runs_v2%rowtype;
  v_stored jsonb;
  v_current jsonb;
  v_stored_basis_hash text;
  v_current_basis_hash text;
  v_payload jsonb;
  v_validation jsonb;
begin
  select * into v_variant
  from public.plan_variants_v2 v
  where v.id=p_variant_id;
  if v_variant.id is null then raise exception 'VARIANT_NOT_FOUND'; end if;
  if v_variant.hard_violations<>0 then
    raise exception 'VARIANT_HAS_HARD_VIOLATIONS';
  end if;

  select * into v_run
  from public.optimization_runs_v2 r
  where r.id=v_variant.run_id;
  if v_run.id is null or v_run.status<>'READY' then
    raise exception 'RUN_NOT_READY';
  end if;
  if v_variant.snapshot_hash<>v_run.snapshot_hash then
    raise exception 'VARIANT_SNAPSHOT_MISMATCH';
  end if;

  select s.snapshot into v_stored
  from solver_private.optimization_snapshots_v2 s
  where s.run_id=v_run.id;
  if v_stored is null then raise exception 'SNAPSHOT_NOT_FOUND'; end if;

  v_current := solver_private.build_snapshot_payload_v2(
    v_run.id,v_run.month,v_run.matrix_version_id,v_run.scenario_id,
    v_run.scope_type,v_run.scope_role_id
  );
  v_stored_basis_hash := solver_private.publication_static_input_hash_v2(v_stored);
  v_current_basis_hash := solver_private.publication_static_input_hash_v2(v_current);
  if v_current_basis_hash<>v_stored_basis_hash then
    raise exception 'PUBLICATION_INPUT_CHANGED';
  end if;

  if p_neutralize_external then
    v_current := jsonb_set(v_current,'{externalAssignments}','[]'::jsonb,true);
  end if;

  perform solver_private.assert_materialized_variant_metadata_v2(
    v_variant.id,v_current
  );
  v_payload := solver_private.materialized_variant_payload_v2(
    array[v_variant.id],v_current,v_variant.strategy_id
  );
  if lower(v_payload->>'solutionHash') is distinct from lower(v_variant.solution_hash) then
    raise exception 'VARIANT_MATERIALIZATION_HASH_MISMATCH';
  end if;
  if p_validate_hard then
    v_validation := solver_private.validate_variant_v2(v_current,v_payload);
  else
    v_validation := jsonb_build_object('hardValidationDeferred',true);
  end if;
  return v_validation||jsonb_build_object(
    'validationSnapshotHash',solver_private.publication_snapshot_hash_v2(v_current),
    'variantId',v_variant.id,
    'currency',nullif(v_current->>'currency','')
  );
end;
$$;

create or replace function solver_private.revalidate_materialized_variant_v2(
  p_variant_id uuid,
  p_neutralize_external boolean
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select solver_private.revalidate_materialized_variant_v2($1,$2,true);
$$;

-- A ROLE solve quotes pay within its own scope. Aggregate rules such as a
-- monthly threshold can change when several roles are composed, so the final
-- COMPANY payload is quoted once more before global budget validation.
create or replace function solver_private.requote_variant_payload_v2(
  p_snapshot jsonb,
  p_payload jsonb
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with assignments as (
    select a.value item,a.ordinality
    from jsonb_array_elements(coalesce(p_payload->'assignments','[]'::jsonb))
      with ordinality a(value,ordinality)
  ), expected as (
    select * from solver_private.expected_pay_components_v2(p_snapshot,p_payload)
  ), quoted as (
    select a.ordinality,a.item||jsonb_build_object(
      'costUnits',coalesce(sum(e.cost_units),0),
      'costComponents',coalesce(jsonb_agg(jsonb_build_object(
        'ruleId',e.rule_id,
        'calculationType',e.calculation_type,
        'costUnits',e.cost_units
      ) order by e.rule_id,e.calculation_type)
        filter(where e.rule_id is not null),'[]'::jsonb)
    ) item,
    coalesce(sum(e.cost_units),0)::bigint cost_units
    from assignments a
    left join expected e
      on e.slot_id=a.item->>'slotId'
      and e.employee_id=a.item->>'employeeId'
    group by a.ordinality,a.item
  ), aggregate_payload as (
    select coalesce(jsonb_agg(q.item order by q.ordinality),'[]'::jsonb) assignments,
      coalesce(sum(q.cost_units),0)::bigint total_cost_units
    from quoted q
  )
  select jsonb_set(
    jsonb_set(p_payload,'{assignments}',a.assignments,true),
    '{metrics}',
    coalesce(p_payload->'metrics','{}'::jsonb)||jsonb_build_object(
      'UNFILLED',jsonb_array_length(coalesce(p_payload->'unfilledSlotIds','[]'::jsonb)),
      'TOTAL_COST',a.total_cost_units
    ),
    true
  )
  from aggregate_payload a;
$$;

create or replace function solver_private.variant_set_workspace_v2(
  p_variant_ids uuid[],
  p_context jsonb,
  p_can_view_finance boolean
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with requested as (
    select distinct x.variant_id
    from unnest(coalesce(p_variant_ids,'{}'::uuid[])) x(variant_id)
  ), grouped_shifts as (
    select ps.slot_group_key,ps.shift_template_id,ps.location_id,ps.shift_date,
      ps.starts_at,ps.ends_at
    from public.plan_shifts_v2 ps
    join requested r on r.variant_id=ps.variant_id
    group by ps.slot_group_key,ps.shift_template_id,ps.location_id,ps.shift_date,
      ps.starts_at,ps.ends_at
  )
  select jsonb_build_object(
    'context',coalesce(p_context,'{}'::jsonb),
    'variants',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',v.id,
        'runId',v.run_id,
        'name',v.name,
        'status',v.status,
        'recommended',v.recommended,
        'selected',v.selected,
        'strategy',jsonb_build_object('id',st.id,'name',st.name),
        'scope',jsonb_build_object(
          'type',run.scope_type,
          'role',case when role.id is null then null else
            jsonb_build_object('id',role.id,'name',role.name)
          end
        ),
        'assignmentCount',v.assignment_count,
        'unfilledCount',v.unfilled_count,
        'solverStatus',v.solver_status,
        'finance',case when p_can_view_finance then jsonb_build_object(
          'baseCostMinor',fin.base_cost_minor,
          'additionsCostMinor',fin.additions_cost_minor,
          'totalCostMinor',fin.total_cost_minor,
          'currency',nullif(snap.snapshot->>'currency',''),
          'budgetMinor',fin.budget_minor
        ) else null end
      ) order by run.scope_type,coalesce(role.sort_order,0),rs.ordinal)
      from requested req
      join public.plan_variants_v2 v on v.id=req.variant_id
      join public.optimization_runs_v2 run on run.id=v.run_id
      join public.optimization_run_strategies_v2 rs on rs.id=v.run_strategy_id
      join public.matrix_strategies_v2 st on st.id=v.strategy_id
      left join public.matrix_roles_v2 role on role.id=run.scope_role_id
      left join solver_private.plan_variant_finance_v2 fin on fin.variant_id=v.id
      left join solver_private.optimization_snapshots_v2 snap on snap.run_id=run.id
    ),'[]'::jsonb),
    'shifts',coalesce((
      select jsonb_agg(jsonb_build_object(
        'slotGroupKey',sh.slot_group_key,
        'date',sh.shift_date,
        'startsAt',sh.starts_at,
        'endsAt',sh.ends_at,
        'location',jsonb_build_object(
          'id',loc.id,'name',loc.name,'timezone',loc.timezone
        ),
        'shiftTemplate',jsonb_build_object('id',tmpl.id,'name',tmpl.name),
        'assignments',coalesce((
          select jsonb_agg(jsonb_build_object(
            'id',pa.id,
            'slotKey',pa.slot_key,
            'employee',jsonb_build_object(
              'id',employee.id,
              'employeeNo',employee.employee_no,
              'firstName',employee.first_name,
              'lastName',employee.last_name,
              'nominalMonthlyMinutes',employee.monthly_nominal_minutes
            ),
            'role',jsonb_build_object('id',role.id,'name',role.name),
            'duties',coalesce((
              select jsonb_agg(jsonb_build_object('id',d.id,'name',d.name)
                order by d.sort_order,d.name)
              from public.plan_assignment_duties_v2 ad
              join public.matrix_duties_v2 d on d.id=ad.duty_id
              where ad.assignment_id=pa.id
            ),'[]'::jsonb),
            'locked',pa.locked,
            'costMinor',case when p_can_view_finance then coalesce((
              select sum(component.amount_minor)
              from solver_private.plan_assignment_cost_components_v2 component
              where component.assignment_id=pa.id
            ),0) else null end
          ) order by role.sort_order,role.name,employee.last_name,
            employee.first_name,pa.slot_key)
          from public.plan_assignments_v2 pa
          join requested ar on ar.variant_id=pa.variant_id
          join public.plan_shifts_v2 aps on aps.id=pa.shift_id
          join public.employees employee on employee.id=pa.employee_id
          join public.matrix_roles_v2 role on role.id=pa.role_id
          where aps.slot_group_key=sh.slot_group_key
            and aps.shift_template_id=sh.shift_template_id
            and aps.location_id=sh.location_id
            and aps.shift_date=sh.shift_date
            and aps.starts_at=sh.starts_at
            and aps.ends_at=sh.ends_at
        ),'[]'::jsonb)
      ) order by sh.starts_at,loc.sort_order,tmpl.sort_order,sh.slot_group_key)
      from grouped_shifts sh
      join public.matrix_locations_v2 loc on loc.id=sh.location_id
      join public.matrix_shift_templates_v2 tmpl on tmpl.id=sh.shift_template_id
    ),'[]'::jsonb),
    'issues',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',i.id,
        'variantId',i.variant_id,
        'slotKey',i.slot_key,
        'code',i.issue_code,
        'severity',i.severity,
        'message',i.message,
        'role',case when role.id is null then null else
          jsonb_build_object('id',role.id,'name',role.name)
        end,
        'duty',case when duty.id is null then null else
          jsonb_build_object('id',duty.id,'name',duty.name)
        end
      ) order by i.severity desc,i.id)
      from public.plan_issues_v2 i
      join requested r on r.variant_id=i.variant_id
      left join public.matrix_roles_v2 role on role.id=i.role_id
      left join public.matrix_duties_v2 duty on duty.id=i.duty_id
    ),'[]'::jsonb),
    'finance',case when p_can_view_finance then (
      select jsonb_build_object(
        'baseCostMinor',coalesce(sum(f.base_cost_minor),0),
        'additionsCostMinor',coalesce(sum(f.additions_cost_minor),0),
        'totalCostMinor',coalesce(sum(f.total_cost_minor),0),
        'currency',case when count(distinct snap.snapshot->>'currency')=1
          then min(snap.snapshot->>'currency') else null end,
        'budgetMinor',case when count(distinct f.budget_minor)=1
          then min(f.budget_minor) else null end
      )
      from requested r
      join public.plan_variants_v2 v on v.id=r.variant_id
      join solver_private.plan_variant_finance_v2 f on f.variant_id=r.variant_id
      join solver_private.optimization_snapshots_v2 snap on snap.run_id=v.run_id
    ) else null end
  );
$$;

create or replace function solver_private.archive_current_publication_v2(
  p_month date,
  p_keep_variant_ids uuid[],
  p_actor uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_archived_ids uuid[];
begin
  with archived as (
    update public.published_schedules_v2 s
    set status='ARCHIVED',archived_at=now(),archived_by=p_actor
    where s.month=p_month and s.status='PUBLISHED'
    returning s.id
  )
  select coalesce(array_agg(a.id),'{}'::uuid[]) into v_archived_ids
  from archived a;

  update public.plan_variants_v2 v
  set status=case when v.selected then 'SELECTED' else 'READY' end,
    published_at=null
  where v.status='PUBLISHED'
    and exists(
      select 1 from public.published_schedule_variants_v2 sv
      where sv.schedule_id=any(v_archived_ids) and sv.variant_id=v.id
    )
    and not (v.id=any(coalesce(p_keep_variant_ids,'{}'::uuid[])));
end;
$$;

create or replace function solver_private.published_variant_is_frozen_v2(
  p_variant_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_variant_id is not null and exists(
    select 1
    from public.published_schedule_variants_v2 sv
    where sv.variant_id=p_variant_id
  );
$$;

create or replace function solver_private.guard_published_variant_row_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op='DELETE' and solver_private.published_variant_is_frozen_v2(old.id) then
    raise exception 'PUBLISHED_VARIANT_IMMUTABLE';
  end if;
  if tg_op='UPDATE'
    and solver_private.published_variant_is_frozen_v2(old.id)
    and (
      to_jsonb(new)-array[
        'status','selected','selected_at','selected_by','published_at'
      ]::text[]
    ) is distinct from (
      to_jsonb(old)-array[
        'status','selected','selected_at','selected_by','published_at'
      ]::text[]
    ) then
    raise exception 'PUBLISHED_VARIANT_CONTENT_IMMUTABLE';
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;

create or replace function solver_private.guard_published_variant_direct_child_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old_variant_id uuid;
  v_new_variant_id uuid;
begin
  if tg_op<>'INSERT' then
    v_old_variant_id := nullif(to_jsonb(old)->>'variant_id','')::uuid;
    if solver_private.published_variant_is_frozen_v2(v_old_variant_id) then
      raise exception 'PUBLISHED_VARIANT_CONTENT_IMMUTABLE';
    end if;
  end if;
  if tg_op<>'DELETE' then
    v_new_variant_id := nullif(to_jsonb(new)->>'variant_id','')::uuid;
    if solver_private.published_variant_is_frozen_v2(v_new_variant_id) then
      raise exception 'PUBLISHED_VARIANT_CONTENT_IMMUTABLE';
    end if;
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;

create or replace function solver_private.guard_published_variant_assignment_child_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_assignment_id uuid;
  v_variant_id uuid;
begin
  if tg_op<>'INSERT' then
    v_assignment_id := nullif(to_jsonb(old)->>'assignment_id','')::uuid;
    select pa.variant_id into v_variant_id
    from public.plan_assignments_v2 pa where pa.id=v_assignment_id;
    if solver_private.published_variant_is_frozen_v2(v_variant_id) then
      raise exception 'PUBLISHED_VARIANT_CONTENT_IMMUTABLE';
    end if;
  end if;
  if tg_op<>'DELETE' then
    v_assignment_id := nullif(to_jsonb(new)->>'assignment_id','')::uuid;
    select pa.variant_id into v_variant_id
    from public.plan_assignments_v2 pa where pa.id=v_assignment_id;
    if solver_private.published_variant_is_frozen_v2(v_variant_id) then
      raise exception 'PUBLISHED_VARIANT_CONTENT_IMMUTABLE';
    end if;
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;

create or replace function solver_private.guard_publication_variant_link_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'PUBLISHED_SCHEDULE_VARIANT_LINK_IMMUTABLE';
end;
$$;

create or replace function solver_private.guard_production_variant_link_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists(
    select 1
    from public.plan_variants_v2 variant
    join public.optimization_runs_v2 run on run.id=variant.run_id
    where variant.id=new.variant_id
      and run.request_engine='ORTOOLS_V2'
  ) then
    raise exception 'SHADOW_RUN_NOT_PUBLISHABLE';
  end if;
  return new;
end;
$$;

create trigger plan_variants_v2_publication_freeze
before update or delete on public.plan_variants_v2
for each row execute function solver_private.guard_published_variant_row_v2();
create trigger plan_shifts_v2_publication_freeze
before insert or update or delete on public.plan_shifts_v2
for each row execute function solver_private.guard_published_variant_direct_child_v2();
create trigger plan_assignments_v2_publication_freeze
before insert or update or delete on public.plan_assignments_v2
for each row execute function solver_private.guard_published_variant_direct_child_v2();
create trigger plan_issues_v2_publication_freeze
before insert or update or delete on public.plan_issues_v2
for each row execute function solver_private.guard_published_variant_direct_child_v2();
create trigger plan_variant_finance_v2_publication_freeze
before insert or update or delete on solver_private.plan_variant_finance_v2
for each row execute function solver_private.guard_published_variant_direct_child_v2();
create trigger plan_assignment_duties_v2_publication_freeze
before insert or update or delete on public.plan_assignment_duties_v2
for each row execute function solver_private.guard_published_variant_assignment_child_v2();
create trigger plan_assignment_cost_components_v2_publication_freeze
before insert or update or delete
on solver_private.plan_assignment_cost_components_v2
for each row execute function solver_private.guard_published_variant_assignment_child_v2();
create trigger published_schedule_variants_v2_link_freeze
before update or delete on public.published_schedule_variants_v2
for each row execute function solver_private.guard_publication_variant_link_v2();
create trigger published_schedule_variants_v2_production_only
before insert on public.published_schedule_variants_v2
for each row execute function solver_private.guard_production_variant_link_v2();

-- Selection is independent from publication lifecycle. A variant referenced by
-- the active publication stays PUBLISHED whether it is selected or deselected.
create or replace function public.optimizer_select_variant_v2(
  p_run_id uuid,
  p_variant_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_variant public.plan_variants_v2%rowtype;
  v_engine text;
begin
  select flag.engine into v_engine
  from public.solver_feature_flags flag
  where flag.flag_key='DEFAULT_ENGINE' and flag.enabled;
  if v_engine is null then raise exception 'SOLVER_ENGINE_CONFIGURATION_MISSING'; end if;
  if v_engine<>'ORTOOLS_V2' then raise exception 'ORTOOLS_SELECTION_DISABLED'; end if;
  if not solver_private.can_access_run_v2(p_run_id) then
    raise exception 'RUN_NOT_FOUND';
  end if;
  perform solver_private.lock_planning_revision_v2();
  perform pg_advisory_xact_lock(hashtextextended('select-v2:'||p_run_id::text,0));
  if not exists(
    select 1 from public.optimization_runs_v2 r
    where r.id=p_run_id and r.status='READY'
      and r.request_engine='ORTOOLS_V2'
  ) then raise exception 'RUN_NOT_READY'; end if;
  select * into v_variant
  from public.plan_variants_v2 v
  where v.id=p_variant_id and v.run_id=p_run_id and v.hard_violations=0
  for update;
  if v_variant.id is null then raise exception 'VARIANT_NOT_SELECTABLE'; end if;

  update public.plan_variants_v2 v
  set selected=false,
    status=case when exists(
      select 1
      from public.published_schedule_variants_v2 sv
      join public.published_schedules_v2 s
        on s.id=sv.schedule_id and s.status='PUBLISHED'
      where sv.variant_id=v.id
    ) then 'PUBLISHED'
    when v.status in ('SELECTED','PUBLISHED') then 'READY'
    else v.status end,
    selected_at=null,selected_by=null
  where v.run_id=p_run_id and v.selected;

  update public.plan_variants_v2 v
  set selected=true,
    status=case when exists(
      select 1
      from public.published_schedule_variants_v2 sv
      join public.published_schedules_v2 s
        on s.id=sv.schedule_id and s.status='PUBLISHED'
      where sv.variant_id=v.id
    ) then 'PUBLISHED' else 'SELECTED' end,
    selected_at=now(),selected_by=auth.uid()
  where v.id=p_variant_id;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(auth.uid(),'optimization_run_v2',p_run_id::text,'SELECT_VARIANT',
    jsonb_build_object('variantId',p_variant_id));
  return jsonb_build_object(
    'runId',p_run_id,'variantId',p_variant_id,'selected',true,'planId',null
  );
end;
$$;

create or replace function public.optimizer_selected_variant_workspace_v2(
  p_run_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_variant_id uuid;
  v_can_view_finance boolean;
  v_context jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not solver_private.can_access_run_v2(p_run_id) then
    raise exception 'RUN_NOT_FOUND';
  end if;

  select v.id,jsonb_build_object(
    'type','SELECTED_VARIANT',
    'runId',r.id,
    'engine',r.request_engine,
    'requestEngine',r.request_engine,
    'month',r.month,
    'name',r.name,
    'scenario',jsonb_build_object('id',s.id,'name',s.name),
    'matrixVersionId',r.matrix_version_id
  )
  into v_variant_id,v_context
  from public.optimization_runs_v2 r
  join public.plan_variants_v2 v on v.run_id=r.id and v.selected
  join public.matrix_scenarios_v2 s on s.id=r.scenario_id
  where r.id=p_run_id;
  if v_variant_id is null then raise exception 'SELECTED_VARIANT_NOT_FOUND'; end if;

  v_can_view_finance := public.has_app_role('OWNER')
    or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE');
  return solver_private.variant_set_workspace_v2(
    array[v_variant_id],v_context,v_can_view_finance
  );
end;
$$;

create or replace function public.optimizer_published_schedule_v2(
  p_schedule_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_schedule public.published_schedules_v2%rowtype;
  v_variant_ids uuid[];
  v_context jsonb;
  v_can_view_finance boolean;
  v_workspace jsonb;
  v_finance jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (
    public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE') or public.has_app_role('VERIFIER')
  ) then raise exception 'FORBIDDEN'; end if;

  select * into v_schedule
  from public.published_schedules_v2 s
  where s.id=p_schedule_id;
  if v_schedule.id is null then raise exception 'PUBLISHED_SCHEDULE_NOT_FOUND'; end if;

  select array_agg(sv.variant_id order by sv.ordinal)
  into v_variant_ids
  from public.published_schedule_variants_v2 sv
  where sv.schedule_id=v_schedule.id;
  if coalesce(cardinality(v_variant_ids),0)=0 then
    raise exception 'PUBLISHED_SCHEDULE_EMPTY';
  end if;

  select jsonb_build_object(
    'type','PUBLISHED_SCHEDULE',
    'scheduleId',v_schedule.id,
    'sourceType',v_schedule.source_type,
    'name',v_schedule.name,
    'status',v_schedule.status,
    'month',v_schedule.month,
    'scenario',jsonb_build_object('id',s.id,'name',s.name),
    'matrixVersionId',v_schedule.matrix_version_id,
    'publishedAt',v_schedule.published_at,
    'archivedAt',v_schedule.archived_at
  ) into v_context
  from public.matrix_scenarios_v2 s
  where s.id=v_schedule.scenario_id;

  v_can_view_finance := public.has_app_role('OWNER')
    or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE');
  v_workspace := solver_private.variant_set_workspace_v2(
    v_variant_ids,v_context,v_can_view_finance
  );
  if v_can_view_finance then
    select jsonb_build_object(
      'baseCostMinor',f.base_cost_minor,
      'additionsCostMinor',f.additions_cost_minor,
      'totalCostMinor',f.total_cost_minor,
      'currency',f.currency,
      'budgetMinor',f.budget_minor
    ) into v_finance
    from solver_private.published_schedule_finance_v2 f
    where f.schedule_id=v_schedule.id;
    v_workspace := jsonb_set(
      v_workspace,'{finance}',coalesce(v_finance,'null'::jsonb),true
    );
  end if;
  return v_workspace;
end;
$$;

create or replace function public.optimizer_role_composite_candidates_v2(
  p_month date,
  p_scenario_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_month date;
  v_matrix_version_id uuid;
  v_scenario_name text;
  v_roles jsonb;
  v_missing_roles jsonb;
  v_variant_ids jsonb;
  v_demanded_count integer;
  v_candidate_count integer;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  if p_scenario_id is null then raise exception 'SCENARIO_REQUIRED'; end if;
  v_month := date_trunc('month',p_month)::date;

  select s.matrix_version_id,s.name
  into v_matrix_version_id,v_scenario_name
  from public.matrix_scenarios_v2 s
  join public.matrix_versions mv
    on mv.id=s.matrix_version_id and mv.schema_version>=2
  where s.id=p_scenario_id and s.active;
  if v_matrix_version_id is null then raise exception 'SCENARIO_NOT_FOUND'; end if;

  with demanded as (
    select d.role_id,sum(d.required_count)::bigint demand_slot_count
    from solver_private.resolved_demand_v2(
      v_month,v_matrix_version_id,p_scenario_id,null
    ) d
    group by d.role_id
  ), candidates as (
    select d.role_id,d.demand_slot_count,role.name role_name,
      role.color role_color,role.sort_order,
      candidate.run_id,candidate.run_created_at,candidate.run_finished_at,
      candidate.variant_id,candidate.variant_name,candidate.variant_status,
      candidate.assignment_count,candidate.unfilled_count,
      candidate.solver_status,candidate.selected_at,
      candidate.strategy_id,candidate.strategy_name,candidate.strategy_code
    from demanded d
    join public.matrix_roles_v2 role
      on role.id=d.role_id and role.matrix_version_id=v_matrix_version_id
    left join lateral (
      select r.id run_id,r.created_at run_created_at,
        r.finished_at run_finished_at,v.id variant_id,v.name variant_name,
        v.status variant_status,v.assignment_count,v.unfilled_count,
        v.solver_status,v.selected_at,
        strategy.id strategy_id,strategy.name strategy_name,
        strategy.code strategy_code
      from public.optimization_runs_v2 r
      join public.plan_variants_v2 v
        on v.run_id=r.id and v.selected and v.hard_violations=0
        and v.status in ('SELECTED','PUBLISHED')
      join public.matrix_strategies_v2 strategy
        on strategy.id=v.strategy_id
      where r.month=v_month
        and r.matrix_version_id=v_matrix_version_id
        and r.scenario_id=p_scenario_id
        and r.request_engine='ORTOOLS_V2'
        and r.scope_type='ROLE'
        and r.scope_role_id=d.role_id
        and r.status='READY'
      order by r.finished_at desc nulls last,r.created_at desc,
        v.selected_at desc nulls last,v.created_at desc,r.id desc,v.id desc
      limit 1
    ) candidate on true
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'role',jsonb_build_object(
        'id',c.role_id,'name',c.role_name,'color',c.role_color,
        'sortOrder',c.sort_order
      ),
      'demandSlotCount',c.demand_slot_count,
      'run',case when c.run_id is null then null else jsonb_build_object(
        'id',c.run_id,'status','READY','createdAt',c.run_created_at,
        'finishedAt',c.run_finished_at
      ) end,
      'variant',case when c.variant_id is null then null else jsonb_build_object(
        'id',c.variant_id,'name',c.variant_name,'status',c.variant_status,
        'assignmentCount',c.assignment_count,'unfilledCount',c.unfilled_count,
        'solverStatus',c.solver_status,'selectedAt',c.selected_at,
        'strategy',jsonb_build_object(
          'id',c.strategy_id,'name',c.strategy_name,'code',c.strategy_code
        )
      ) end,
      'ready',c.variant_id is not null
    ) order by c.sort_order,c.role_name,c.role_id::text),'[]'::jsonb),
    coalesce(jsonb_agg(jsonb_build_object(
      'id',c.role_id,'name',c.role_name
    ) order by c.sort_order,c.role_name,c.role_id::text)
      filter(where c.variant_id is null),'[]'::jsonb),
    coalesce(jsonb_agg(to_jsonb(c.variant_id)
      order by c.sort_order,c.role_name,c.role_id::text)
      filter(where c.variant_id is not null),'[]'::jsonb),
    count(*)::integer,count(c.variant_id)::integer
  into v_roles,v_missing_roles,v_variant_ids,v_demanded_count,v_candidate_count
  from candidates c;

  return jsonb_build_object(
    'month',v_month,
    'scenario',jsonb_build_object('id',p_scenario_id,'name',v_scenario_name),
    'matrixVersionId',v_matrix_version_id,
    'roles',v_roles,
    'missingRoles',v_missing_roles,
    'variantIds',v_variant_ids,
    'demandedRoleCount',v_demanded_count,
    'ready',v_demanded_count>0 and v_candidate_count=v_demanded_count
  );
end;
$$;

create or replace function public.optimizer_publish_company_variant_v2(
  p_run_id uuid,
  p_variant_id uuid,
  p_name text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_run public.optimization_runs_v2%rowtype;
  v_variant public.plan_variants_v2%rowtype;
  v_existing public.published_schedules_v2%rowtype;
  v_schedule_id uuid := gen_random_uuid();
  v_month date;
  v_validation jsonb;
  v_publication_hash text;
  v_base_units bigint;
  v_total_units bigint;
  v_currency text;
  v_engine text;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select flag.engine into v_engine
  from public.solver_feature_flags flag
  where flag.flag_key='DEFAULT_ENGINE' and flag.enabled;
  if v_engine is null then raise exception 'SOLVER_ENGINE_CONFIGURATION_MISSING'; end if;
  if v_engine<>'ORTOOLS_V2' then raise exception 'ORTOOLS_PUBLICATION_DISABLED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'COMPANY_PUBLICATION_FORBIDDEN';
  end if;
  if length(coalesce(p_idempotency_key,'')) not between 8 and 200 then
    raise exception 'INVALID_IDEMPOTENCY_KEY';
  end if;
  if length(trim(coalesce(p_name,''))) not between 1 and 200 then
    raise exception 'INVALID_PLAN_NAME';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'publish-v2-key:'||v_actor::text||':'||p_idempotency_key,0
  ));
  select * into v_existing
  from public.published_schedules_v2 s
  where s.created_by=v_actor and s.idempotency_key=p_idempotency_key;
  if v_existing.id is not null then
    if v_existing.source_type<>'COMPANY'
      or v_existing.name<>trim(p_name)
      or not exists(
      select 1
      from public.published_schedule_variants_v2 sv
      join public.plan_variants_v2 v on v.id=sv.variant_id
      where sv.schedule_id=v_existing.id and sv.variant_id=p_variant_id
        and v.run_id=p_run_id
    ) then raise exception 'IDEMPOTENCY_KEY_REUSED'; end if;
    return jsonb_build_object(
      'scheduleId',v_existing.id,'status',v_existing.status,
      'sourceType',v_existing.source_type,'reused',true
    );
  end if;

  select r.month into v_month
  from public.optimization_runs_v2 r
  where r.id=p_run_id;
  if v_month is null then raise exception 'RUN_NOT_FOUND'; end if;

  -- Every code path that combines the planning-revision lock with run or
  -- variant locks uses this order. This prevents a concurrent selection,
  -- worker validation and publication from forming an advisory-lock cycle.
  perform solver_private.lock_planning_revision_v2();
  perform pg_advisory_xact_lock(hashtextextended(
    'publish-v2-month:'||v_month::text,0
  ));
  perform pg_advisory_xact_lock(hashtextextended(
    'select-v2:'||p_run_id::text,0
  ));

  select * into v_run
  from public.optimization_runs_v2 r
  where r.id=p_run_id
  for update;
  if v_run.id is null then raise exception 'RUN_NOT_FOUND'; end if;
  if v_run.month<>v_month then raise exception 'RUN_MONTH_CHANGED'; end if;
  if v_run.request_engine<>'ORTOOLS_V2' then
    raise exception 'SHADOW_RUN_NOT_PUBLISHABLE';
  end if;
  if v_run.status<>'READY' or v_run.scope_type<>'COMPANY' then
    raise exception 'COMPANY_RUN_NOT_READY';
  end if;
  select * into v_variant
  from public.plan_variants_v2 v
  where v.id=p_variant_id and v.run_id=v_run.id
  for update;
  if v_variant.id is null or not v_variant.selected
    or v_variant.hard_violations<>0
    or v_variant.status not in ('SELECTED','PUBLISHED') then
    raise exception 'SELECTED_COMPANY_VARIANT_REQUIRED';
  end if;

  v_validation := solver_private.revalidate_materialized_variant_v2(v_variant.id,false);
  v_currency := upper(nullif(v_validation->>'currency',''));
  if v_currency is null or v_currency !~ '^[A-Z]{3}$' then
    raise exception 'SNAPSHOT_CURRENCY_REQUIRED';
  end if;
  v_publication_hash := encode(extensions.digest(convert_to(
    solver_private.canonical_json_v2(jsonb_build_object(
      'sourceType','COMPANY','month',v_run.month,
      'matrixVersionId',v_run.matrix_version_id,
      'scenarioId',v_run.scenario_id,
      'variantId',v_variant.id,'solutionHash',v_variant.solution_hash
    )),'UTF8'
  ),'sha256'),'hex');

  perform solver_private.archive_current_publication_v2(
    v_run.month,array[v_variant.id],v_actor
  );
  insert into public.published_schedules_v2(
    id,idempotency_key,month,matrix_version_id,scenario_id,source_type,
    name,status,publication_hash,validation_snapshot_hash,
    validation_summary,created_by
  ) values(
    v_schedule_id,p_idempotency_key,v_run.month,v_run.matrix_version_id,
    v_run.scenario_id,'COMPANY',trim(p_name),'PUBLISHED',v_publication_hash,
    v_validation->>'validationSnapshotHash',
    v_validation-'totalCostUnits'-'budgetMinor'-'validationSnapshotHash'-'variantId',
    v_actor
  );
  insert into public.published_schedule_variants_v2(
    schedule_id,variant_id,role_id,ordinal
  ) values(v_schedule_id,v_variant.id,null,1);
  select coalesce(sum((c.calculation_basis->>'costUnits')::bigint),0)
  into v_base_units
  from public.plan_assignments_v2 a
  join solver_private.plan_assignment_cost_components_v2 c
    on c.assignment_id=a.id and c.pay_rule_id is null
  where a.variant_id=v_variant.id;
  v_total_units := (v_validation->>'totalCostUnits')::bigint;
  insert into solver_private.published_schedule_finance_v2(
    schedule_id,base_cost_units,additions_cost_units,total_cost_units,
    base_cost_minor,additions_cost_minor,total_cost_minor,currency,
    budget_minor,hard_budget
  ) values(
    v_schedule_id,v_base_units,greatest(v_total_units-v_base_units,0),v_total_units,
    round(v_base_units::numeric/60)::bigint,
    round(v_total_units::numeric/60)::bigint
      -round(v_base_units::numeric/60)::bigint,
    round(v_total_units::numeric/60)::bigint,
    v_currency,
    nullif(v_validation->>'budgetMinor','')::bigint,
    coalesce((v_validation->>'hardBudget')::boolean,false)
  );
  update public.plan_variants_v2
  set status='PUBLISHED',published_at=now()
  where id=v_variant.id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'published_schedule_v2',v_schedule_id::text,
    'PUBLISH_COMPANY',jsonb_build_object(
      'month',v_run.month,'scenarioId',v_run.scenario_id,
      'matrixVersionId',v_run.matrix_version_id,'variantId',v_variant.id,
      'publicationHash',v_publication_hash
    ));
  return jsonb_build_object(
    'scheduleId',v_schedule_id,'status','PUBLISHED',
    'sourceType','COMPANY','reused',false
  );
end;
$$;

create or replace function public.optimizer_publish_role_composite_v2(
  p_month date,
  p_scenario_id uuid,
  p_variant_ids uuid[],
  p_name text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_month date := date_trunc('month',p_month)::date;
  v_variant_ids uuid[];
  v_existing public.published_schedules_v2%rowtype;
  v_existing_ids uuid[];
  v_schedule_id uuid := gen_random_uuid();
  v_matrix_ids uuid[];
  v_scenario_ids uuid[];
  v_months date[];
  v_count integer;
  v_role_count integer;
  v_matrix_version_id uuid;
  v_validation_run_id uuid;
  v_strategy_id uuid;
  v_company_snapshot jsonb;
  v_combined_payload jsonb;
  v_combined_validation jsonb;
  v_validation jsonb;
  v_publication_hash text;
  v_variant_id uuid;
  v_base_units bigint;
  v_total_units bigint;
  v_currency text;
  v_engine text;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  select flag.engine into v_engine
  from public.solver_feature_flags flag
  where flag.flag_key='DEFAULT_ENGINE' and flag.enabled;
  if v_engine is null then raise exception 'SOLVER_ENGINE_CONFIGURATION_MISSING'; end if;
  if v_engine<>'ORTOOLS_V2' then raise exception 'ORTOOLS_PUBLICATION_DISABLED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'COMPOSITE_PUBLICATION_FORBIDDEN';
  end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  if p_scenario_id is null then raise exception 'SCENARIO_REQUIRED'; end if;
  if length(coalesce(p_idempotency_key,'')) not between 8 and 200 then
    raise exception 'INVALID_IDEMPOTENCY_KEY';
  end if;
  if length(trim(coalesce(p_name,''))) not between 1 and 200 then
    raise exception 'INVALID_PLAN_NAME';
  end if;
  if coalesce(cardinality(p_variant_ids),0)=0
    or cardinality(p_variant_ids)>200 then
    raise exception 'INVALID_VARIANT_SET';
  end if;
  select array_agg(x.variant_id order by x.variant_id::text)
  into v_variant_ids
  from (select distinct unnest(p_variant_ids) variant_id) x;
  if cardinality(v_variant_ids)<>cardinality(p_variant_ids)
    or array_position(v_variant_ids,null) is not null then
    raise exception 'DUPLICATE_OR_NULL_VARIANT';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'publish-v2-key:'||v_actor::text||':'||p_idempotency_key,0
  ));
  select * into v_existing
  from public.published_schedules_v2 s
  where s.created_by=v_actor and s.idempotency_key=p_idempotency_key;
  if v_existing.id is not null then
    select array_agg(sv.variant_id order by sv.variant_id::text)
    into v_existing_ids
    from public.published_schedule_variants_v2 sv
    where sv.schedule_id=v_existing.id;
    if v_existing.source_type<>'ROLE_COMPOSITE'
      or v_existing.month<>v_month
      or v_existing.scenario_id<>p_scenario_id
      or v_existing.name<>trim(p_name)
      or v_existing_ids is distinct from v_variant_ids then
      raise exception 'IDEMPOTENCY_KEY_REUSED';
    end if;
    return jsonb_build_object(
      'scheduleId',v_existing.id,'status',v_existing.status,
      'sourceType',v_existing.source_type,'reused',true
    );
  end if;

  -- Lock order is global revision, month, then sorted runs/variants.
  perform solver_private.lock_planning_revision_v2();
  perform pg_advisory_xact_lock(hashtextextended(
    'publish-v2-month:'||v_month::text,0
  ));
  for v_validation_run_id in
    select distinct v.run_id
    from public.plan_variants_v2 v
    where v.id=any(v_variant_ids)
    order by v.run_id
  loop
    perform pg_advisory_xact_lock(hashtextextended(
      'select-v2:'||v_validation_run_id::text,0
    ));
  end loop;

  perform 1
  from public.plan_variants_v2 v
  join public.optimization_runs_v2 r on r.id=v.run_id
  where v.id=any(v_variant_ids)
  order by v.id::text
  for update of v,r;

  if exists(
    select 1
    from public.plan_variants_v2 v
    join public.optimization_runs_v2 r on r.id=v.run_id
    where v.id=any(v_variant_ids)
      and r.request_engine<>'ORTOOLS_V2'
  ) then raise exception 'SHADOW_RUN_NOT_PUBLISHABLE'; end if;

  select count(*),count(distinct r.scope_role_id),
    array_agg(distinct r.matrix_version_id),
    array_agg(distinct r.scenario_id),
    array_agg(distinct r.month)
  into v_count,v_role_count,v_matrix_ids,v_scenario_ids,v_months
  from public.plan_variants_v2 v
  join public.optimization_runs_v2 r on r.id=v.run_id
  where v.id=any(v_variant_ids)
    and v.selected and v.hard_violations=0
    and v.status in ('SELECTED','PUBLISHED')
    and r.status='READY' and r.scope_type='ROLE';
  if v_count<>cardinality(v_variant_ids)
    or v_role_count<>cardinality(v_variant_ids) then
    raise exception 'ONE_SELECTED_ROLE_VARIANT_PER_ROLE_REQUIRED';
  end if;
  if cardinality(v_matrix_ids)<>1 or cardinality(v_scenario_ids)<>1
    or cardinality(v_months)<>1
    or v_months[1]<>v_month or v_scenario_ids[1]<>p_scenario_id then
    raise exception 'ROLE_VARIANTS_SCOPE_MISMATCH';
  end if;
  v_matrix_version_id := v_matrix_ids[1];
  select v.run_id into v_validation_run_id
  from public.plan_variants_v2 v
  where v.id=any(v_variant_ids)
  order by v.run_id::text limit 1;

  foreach v_variant_id in array v_variant_ids loop
    v_validation := solver_private.revalidate_materialized_variant_v2(
      v_variant_id,true,false
    );
  end loop;

  v_company_snapshot := solver_private.build_snapshot_payload_v2(
    v_validation_run_id,v_month,v_matrix_version_id,p_scenario_id,'COMPANY',null
  );
  -- COMPANY validation owns every selected ROLE assignment, so the soft
  -- baseline is removed. External assignments are deliberately preserved:
  -- for COMPANY they include adjacent-month work needed for rest, weekly
  -- limits and consecutive-day validation. Current locks also remain hard.
  v_company_snapshot := jsonb_set(
    v_company_snapshot,'{baselineAssignments}','[]'::jsonb,true
  );
  v_currency := upper(nullif(v_company_snapshot->>'currency',''));
  if v_currency is null or v_currency !~ '^[A-Z]{3}$' then
    raise exception 'SNAPSHOT_CURRENCY_REQUIRED';
  end if;
  if exists(
    select slot.value->>'roleId'
    from jsonb_array_elements(coalesce(v_company_snapshot->'slots','[]'::jsonb)) slot
    group by slot.value->>'roleId'
    except
    select r.scope_role_id::text
    from public.plan_variants_v2 v
    join public.optimization_runs_v2 r on r.id=v.run_id
    where v.id=any(v_variant_ids)
  ) or exists(
    select r.scope_role_id::text
    from public.plan_variants_v2 v
    join public.optimization_runs_v2 r on r.id=v.run_id
    where v.id=any(v_variant_ids)
    except
    select slot.value->>'roleId'
    from jsonb_array_elements(coalesce(v_company_snapshot->'slots','[]'::jsonb)) slot
    group by slot.value->>'roleId'
  ) then raise exception 'ALL_DEMANDED_ROLES_REQUIRED'; end if;

  v_strategy_id := nullif(v_company_snapshot->'strategies'->0->>'id','')::uuid;
  if v_strategy_id is null then raise exception 'SCENARIO_HAS_NO_STRATEGIES'; end if;
  v_publication_hash := encode(extensions.digest(convert_to(
    solver_private.canonical_json_v2(jsonb_build_object(
      'sourceType','ROLE_COMPOSITE','month',v_month,
      'matrixVersionId',v_matrix_version_id,'scenarioId',p_scenario_id,
      'variants',(
        select jsonb_agg(jsonb_build_object(
          'variantId',v.id,'solutionHash',v.solution_hash,
          'roleId',r.scope_role_id
        ) order by r.scope_role_id::text,v.id::text)
        from public.plan_variants_v2 v
        join public.optimization_runs_v2 r on r.id=v.run_id
        where v.id=any(v_variant_ids)
      )
    )),'UTF8'
  ),'sha256'),'hex');
  v_combined_payload := solver_private.materialized_variant_payload_v2(
    v_variant_ids,v_company_snapshot,v_strategy_id
  );
  v_combined_payload := solver_private.requote_variant_payload_v2(
    v_company_snapshot,v_combined_payload
  );
  v_combined_validation := solver_private.validate_variant_v2(
    v_company_snapshot,v_combined_payload
  );

  perform solver_private.archive_current_publication_v2(
    v_month,v_variant_ids,v_actor
  );
  insert into public.published_schedules_v2(
    id,idempotency_key,month,matrix_version_id,scenario_id,source_type,
    name,status,publication_hash,validation_snapshot_hash,
    validation_summary,created_by
  ) values(
    v_schedule_id,p_idempotency_key,v_month,v_matrix_version_id,p_scenario_id,
    'ROLE_COMPOSITE',trim(p_name),'PUBLISHED',v_publication_hash,
    solver_private.publication_snapshot_hash_v2(v_company_snapshot),
    v_combined_validation-'totalCostUnits'-'budgetMinor',v_actor
  );
  insert into public.published_schedule_variants_v2(
    schedule_id,variant_id,role_id,ordinal
  )
  select v_schedule_id,v.id,r.scope_role_id,
    (row_number() over(order by role.sort_order,role.name,r.scope_role_id::text))::integer
  from public.plan_variants_v2 v
  join public.optimization_runs_v2 r on r.id=v.run_id
  join public.matrix_roles_v2 role on role.id=r.scope_role_id
  where v.id=any(v_variant_ids)
  order by role.sort_order,role.name,r.scope_role_id::text;
  select
    coalesce((
      select sum((component.value->>'costUnits')::bigint)
      from jsonb_array_elements(
        coalesce(v_combined_payload->'assignments','[]'::jsonb)
      ) assignment
      cross join lateral jsonb_array_elements(
        coalesce(assignment.value->'costComponents','[]'::jsonb)
      ) component
      where component.value->>'ruleId'='BASE'
    ),0),
    coalesce((
      select sum((assignment.value->>'costUnits')::bigint)
      from jsonb_array_elements(
        coalesce(v_combined_payload->'assignments','[]'::jsonb)
      ) assignment
    ),0)
  into v_base_units,v_total_units;
  insert into solver_private.published_schedule_finance_v2(
    schedule_id,base_cost_units,additions_cost_units,total_cost_units,
    base_cost_minor,additions_cost_minor,total_cost_minor,currency,
    budget_minor,hard_budget
  ) values(
    v_schedule_id,v_base_units,greatest(v_total_units-v_base_units,0),v_total_units,
    round(v_base_units::numeric/60)::bigint,
    round(v_total_units::numeric/60)::bigint
      -round(v_base_units::numeric/60)::bigint,
    round(v_total_units::numeric/60)::bigint,
    v_currency,
    nullif(v_combined_validation->>'budgetMinor','')::bigint,
    coalesce((v_combined_validation->>'hardBudget')::boolean,false)
  );
  update public.plan_variants_v2
  set status='PUBLISHED',published_at=now()
  where id=any(v_variant_ids);
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'published_schedule_v2',v_schedule_id::text,
    'PUBLISH_ROLE_COMPOSITE',jsonb_build_object(
      'month',v_month,'scenarioId',p_scenario_id,
      'matrixVersionId',v_matrix_version_id,
      'variantIds',to_jsonb(v_variant_ids),
      'publicationHash',v_publication_hash
    ));
  return jsonb_build_object(
    'scheduleId',v_schedule_id,'status','PUBLISHED',
    'sourceType','ROLE_COMPOSITE','variantCount',cardinality(v_variant_ids),
    'reused',false
  );
end;
$$;

create or replace function public.optimizer_active_workspace_v2(p_month date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_engine text;
  v_schedule_id uuid;
  v_month date:=date_trunc('month',p_month)::date;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  select f.engine into v_engine
  from public.solver_feature_flags f
  where f.flag_key='DEFAULT_ENGINE' and f.enabled;
  if v_engine is null then raise exception 'SOLVER_ENGINE_CONFIGURATION_MISSING'; end if;
  if v_engine not in ('ALPHA15','SHADOW','ORTOOLS_V2') then
    raise exception 'SOLVER_ENGINE_CONFIGURATION_INVALID';
  end if;
  if v_engine<>'ORTOOLS_V2' then return null; end if;
  if not (
    public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE') or public.has_app_role('VERIFIER')
  ) then raise exception 'FORBIDDEN'; end if;
  select s.id into v_schedule_id
  from public.published_schedules_v2 s
  where s.month=v_month and s.status='PUBLISHED'
  order by s.published_at desc,s.id desc limit 1;
  if v_schedule_id is null then
    return jsonb_build_object(
      'engine','ORTOOLS_V2',
      'context',jsonb_build_object(
        'type','PUBLISHED_SCHEDULE','status','EMPTY','month',v_month,
        'name','Brak opublikowanego grafiku'
      ),
      'variants','[]'::jsonb,'shifts','[]'::jsonb,
      'issues','[]'::jsonb,'finance',null
    );
  end if;
  return public.optimizer_published_schedule_v2(v_schedule_id)
    ||jsonb_build_object('engine','ORTOOLS_V2');
end;
$$;

create or replace function public.optimizer_employee_published_schedule_v2(
  p_month date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_engine text;
  v_employee_id uuid;
  v_schedule_id uuid;
  v_matrix_version_id uuid;
  v_month date:=date_trunc('month',p_month)::date;
  v_assignments jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  select f.engine into v_engine
  from public.solver_feature_flags f
  where f.flag_key='DEFAULT_ENGINE' and f.enabled;
  if v_engine is null then raise exception 'SOLVER_ENGINE_CONFIGURATION_MISSING'; end if;
  if v_engine not in ('ALPHA15','SHADOW','ORTOOLS_V2') then
    raise exception 'SOLVER_ENGINE_CONFIGURATION_INVALID';
  end if;
  if v_engine<>'ORTOOLS_V2' then return null; end if;
  select e.id into v_employee_id
  from public.employees e
  where e.auth_user_id=auth.uid() and e.active and e.archived_at is null
  order by e.employee_no limit 1;
  if v_employee_id is null then raise exception 'EMPLOYEE_ACCOUNT_NOT_LINKED'; end if;
  select s.id,s.matrix_version_id into v_schedule_id,v_matrix_version_id
  from public.published_schedules_v2 s
  where s.month=v_month and s.status='PUBLISHED'
  order by s.published_at desc,s.id desc limit 1;
  if v_schedule_id is null then
    return jsonb_build_object(
      'engine','ORTOOLS_V2','scheduleId',null,'assignments','[]'::jsonb
    );
  end if;

  with own_assignments as (
    select pa.id,pa.employee_id,pa.role_id,pa.shift_id,
      ps.slot_group_key,ps.shift_date,ps.starts_at,ps.ends_at,
      ps.location_id,ps.shift_template_id
    from public.published_schedule_variants_v2 sv
    join public.plan_assignments_v2 pa on pa.variant_id=sv.variant_id
    join public.plan_shifts_v2 ps on ps.id=pa.shift_id
    where sv.schedule_id=v_schedule_id and pa.employee_id=v_employee_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',own.id,
    'shiftId',own.slot_group_key,
    'date',own.shift_date,
    'startsAt',own.starts_at,
    'endsAt',own.ends_at,
    'shiftCode',shift_template.code,
    'shiftName',shift_template.name,
    'location',location.name,
    'locationCode',location.code,
    'role',role.name,
    'roleCode',role.code,
    'capability',coalesce((
      select string_agg(duty.name,', ' order by duty.sort_order,duty.name)
      from public.plan_assignment_duties_v2 assignment_duty
      join public.matrix_duties_v2 duty on duty.id=assignment_duty.duty_id
      where assignment_duty.assignment_id=own.id
    ),''),
    'coworkers',coalesce((
      select jsonb_agg(jsonb_build_object(
        'name',coworker.first_name||' '||coworker.last_name,
        'role',coworker_role.name,
        'capability',coalesce((
          select string_agg(duty.name,', ' order by duty.sort_order,duty.name)
          from public.plan_assignment_duties_v2 assignment_duty
          join public.matrix_duties_v2 duty on duty.id=assignment_duty.duty_id
          where assignment_duty.assignment_id=coworker_assignment.id
        ),'')
      ) order by coworker.last_name,coworker.first_name,coworker_assignment.id)
      from public.published_schedule_variants_v2 coworker_link
      join public.plan_assignments_v2 coworker_assignment
        on coworker_assignment.variant_id=coworker_link.variant_id
      join public.plan_shifts_v2 coworker_shift
        on coworker_shift.id=coworker_assignment.shift_id
      join public.matrix_employee_profiles_v2 coworker
        on coworker.matrix_version_id=v_matrix_version_id
        and coworker.employee_id=coworker_assignment.employee_id
      join public.matrix_roles_v2 coworker_role on coworker_role.id=coworker_assignment.role_id
      where coworker_link.schedule_id=v_schedule_id
        and coworker_assignment.employee_id<>v_employee_id
        and coworker_shift.slot_group_key=own.slot_group_key
        and coworker_shift.location_id=own.location_id
        and coworker_shift.starts_at=own.starts_at
        and coworker_shift.ends_at=own.ends_at
    ),'[]'::jsonb)
  ) order by own.starts_at,own.id),'[]'::jsonb)
  into v_assignments
  from own_assignments own
  join public.matrix_locations_v2 location on location.id=own.location_id
  join public.matrix_shift_templates_v2 shift_template
    on shift_template.id=own.shift_template_id
  join public.matrix_roles_v2 role on role.id=own.role_id;

  return jsonb_build_object(
    'engine','ORTOOLS_V2','scheduleId',v_schedule_id,
    'assignments',v_assignments
  );
end;
$$;

create or replace function public.optimizer_kadromierz_export_v2(p_month date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_engine text;
  v_schedule_id uuid;
  v_matrix_version_id uuid;
  v_month date:=date_trunc('month',p_month)::date;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  select f.engine into v_engine
  from public.solver_feature_flags f
  where f.flag_key='DEFAULT_ENGINE' and f.enabled;
  if v_engine is null then raise exception 'SOLVER_ENGINE_CONFIGURATION_MISSING'; end if;
  if v_engine not in ('ALPHA15','SHADOW','ORTOOLS_V2') then
    raise exception 'SOLVER_ENGINE_CONFIGURATION_INVALID';
  end if;
  if v_engine<>'ORTOOLS_V2' then return null; end if;
  if not (
    public.has_app_role('OWNER') or public.has_app_role('ADMIN')
    or public.has_app_role('HR_FINANCE')
  ) then raise exception 'FORBIDDEN'; end if;
  select s.id,s.matrix_version_id into v_schedule_id,v_matrix_version_id
  from public.published_schedules_v2 s
  where s.month=v_month and s.status='PUBLISHED'
  order by s.published_at desc,s.id desc limit 1;
  if v_schedule_id is null then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'numer_pracownika',employee.employee_no,
    'pracownik',employee.first_name||' '||employee.last_name,
    'data',shift.shift_date,'lokal',location.code,
    'zmiana',template.code,'od',shift.starts_at,'do',shift.ends_at,
    'rola',role.code,
    'obowiazki',coalesce((
      select string_agg(duty.code,',' order by duty.sort_order,duty.code)
      from public.plan_assignment_duties_v2 assignment_duty
      join public.matrix_duties_v2 duty on duty.id=assignment_duty.duty_id
      where assignment_duty.assignment_id=assignment.id
    ),'')
  ) order by shift.starts_at,employee.employee_no,assignment.id),'[]'::jsonb)
  into v_result
  from public.published_schedule_variants_v2 link
  join public.plan_assignments_v2 assignment on assignment.variant_id=link.variant_id
  join public.plan_shifts_v2 shift on shift.id=assignment.shift_id
  join public.matrix_employee_profiles_v2 employee
    on employee.matrix_version_id=v_matrix_version_id
    and employee.employee_id=assignment.employee_id
  join public.matrix_locations_v2 location on location.id=shift.location_id
  join public.matrix_shift_templates_v2 template on template.id=shift.shift_template_id
  join public.matrix_roles_v2 role on role.id=assignment.role_id
  where link.schedule_id=v_schedule_id;
  return v_result;
end;
$$;

revoke all on function solver_private.publication_snapshot_basis_v2(jsonb)
  from public,anon,authenticated;
revoke all on function solver_private.publication_snapshot_hash_v2(jsonb)
  from public,anon,authenticated;
revoke all on function solver_private.publication_static_input_hash_v2(jsonb)
  from public,anon,authenticated;
revoke all on function solver_private.materialized_variant_payload_v2(uuid[],jsonb,uuid)
  from public,anon,authenticated;
revoke all on function solver_private.assert_materialized_variant_metadata_v2(uuid,jsonb)
  from public,anon,authenticated;
revoke all on function solver_private.revalidate_materialized_variant_v2(uuid,boolean)
  from public,anon,authenticated;
revoke all on function solver_private.revalidate_materialized_variant_v2(uuid,boolean,boolean)
  from public,anon,authenticated;
revoke all on function solver_private.requote_variant_payload_v2(jsonb,jsonb)
  from public,anon,authenticated;
revoke all on function solver_private.variant_set_workspace_v2(uuid[],jsonb,boolean)
  from public,anon,authenticated;
revoke all on function solver_private.archive_current_publication_v2(date,uuid[],uuid)
  from public,anon,authenticated;
revoke all on function solver_private.published_variant_is_frozen_v2(uuid)
  from public,anon,authenticated;
revoke all on function solver_private.guard_published_variant_row_v2()
  from public,anon,authenticated;
revoke all on function solver_private.guard_published_variant_direct_child_v2()
  from public,anon,authenticated;
revoke all on function solver_private.guard_published_variant_assignment_child_v2()
  from public,anon,authenticated;
revoke all on function solver_private.guard_publication_variant_link_v2()
  from public,anon,authenticated;
revoke all on function solver_private.guard_production_variant_link_v2()
  from public,anon,authenticated;

grant execute on function solver_private.publication_snapshot_basis_v2(jsonb)
  to service_role;
grant execute on function solver_private.publication_snapshot_hash_v2(jsonb)
  to service_role;
grant execute on function solver_private.publication_static_input_hash_v2(jsonb)
  to service_role;
grant execute on function solver_private.materialized_variant_payload_v2(uuid[],jsonb,uuid)
  to service_role;
grant execute on function solver_private.assert_materialized_variant_metadata_v2(uuid,jsonb)
  to service_role;
grant execute on function solver_private.revalidate_materialized_variant_v2(uuid,boolean)
  to service_role;
grant execute on function solver_private.revalidate_materialized_variant_v2(uuid,boolean,boolean)
  to service_role;
grant execute on function solver_private.requote_variant_payload_v2(jsonb,jsonb)
  to service_role;
grant execute on function solver_private.variant_set_workspace_v2(uuid[],jsonb,boolean)
  to service_role;
grant execute on function solver_private.archive_current_publication_v2(date,uuid[],uuid)
  to service_role;
grant execute on function solver_private.published_variant_is_frozen_v2(uuid)
  to service_role;
grant execute on function solver_private.guard_published_variant_row_v2()
  to service_role;
grant execute on function solver_private.guard_published_variant_direct_child_v2()
  to service_role;
grant execute on function solver_private.guard_published_variant_assignment_child_v2()
  to service_role;
grant execute on function solver_private.guard_publication_variant_link_v2()
  to service_role;
grant execute on function solver_private.guard_production_variant_link_v2()
  to service_role;

revoke all on function public.optimizer_selected_variant_workspace_v2(uuid)
  from public,anon,authenticated;
revoke all on function public.optimizer_select_variant_v2(uuid,uuid)
  from public,anon,authenticated;
revoke all on function public.optimizer_published_schedule_v2(uuid)
  from public,anon,authenticated;
revoke all on function public.optimizer_active_workspace_v2(date)
  from public,anon,authenticated;
revoke all on function public.optimizer_employee_published_schedule_v2(date)
  from public,anon,authenticated;
revoke all on function public.optimizer_kadromierz_export_v2(date)
  from public,anon,authenticated;
revoke all on function public.optimizer_role_composite_candidates_v2(date,uuid)
  from public,anon,authenticated;
revoke all on function public.optimizer_publish_company_variant_v2(uuid,uuid,text,text)
  from public,anon,authenticated;
revoke all on function public.optimizer_publish_role_composite_v2(date,uuid,uuid[],text,text)
  from public,anon,authenticated;

grant execute on function public.optimizer_selected_variant_workspace_v2(uuid)
  to authenticated;
grant execute on function public.optimizer_select_variant_v2(uuid,uuid)
  to authenticated;
grant execute on function public.optimizer_published_schedule_v2(uuid)
  to authenticated;
grant execute on function public.optimizer_active_workspace_v2(date)
  to authenticated;
grant execute on function public.optimizer_employee_published_schedule_v2(date)
  to authenticated;
grant execute on function public.optimizer_kadromierz_export_v2(date)
  to authenticated;
grant execute on function public.optimizer_role_composite_candidates_v2(date,uuid)
  to authenticated;
grant execute on function public.optimizer_publish_company_variant_v2(uuid,uuid,text,text)
  to authenticated;
grant execute on function public.optimizer_publish_role_composite_v2(date,uuid,uuid[],text,text)
  to authenticated;

comment on table public.published_schedules_v2 is
  'Immutable publication header for a native Matrix v2 company variant or role composite.';
comment on table public.published_schedule_variants_v2 is
  'Exact solver variants composing a published Matrix v2 schedule; dynamic role IDs remain native.';
comment on function public.optimizer_selected_variant_workspace_v2(uuid) is
  'Planner-only dynamic preview of the single consciously selected variant for a run.';
comment on function public.optimizer_role_composite_candidates_v2(date,uuid) is
  'Planner-only list of demanded dynamic roles and each latest selected READY role variant for safe composition.';
comment on function public.optimizer_active_workspace_v2(date) is
  'Canonical operational read model for the currently published OR-Tools v2 schedule; returns null for explicit Alpha 15 or shadow mode.';
comment on function public.optimizer_employee_published_schedule_v2(date) is
  'Employee-only assignments and coworkers from the authoritative OR-Tools v2 publication.';
comment on function public.optimizer_publish_company_variant_v2(uuid,uuid,text,text) is
  'OWNER/ADMIN-only, idempotent publication of a selected COMPANY variant after fresh database validation.';
comment on function public.optimizer_publish_role_composite_v2(date,uuid,uuid[],text,text) is
  'OWNER/ADMIN-only global assembly and publication of one selected ROLE variant for every demanded role.';
