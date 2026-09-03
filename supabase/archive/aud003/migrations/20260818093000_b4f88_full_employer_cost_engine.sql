-- B4F-88: explicit/versioned employer on-costs and approval-gated incident rates.
-- No statutory percentage is seeded: owners must enter and date every component.

create table if not exists public.employer_cost_components_v2 (
  id uuid primary key default gen_random_uuid(),
  logical_id uuid not null default gen_random_uuid(),
  revision integer not null default 1 check (revision > 0),
  supersedes_id uuid references public.employer_cost_components_v2(id),
  code text not null check (length(trim(code)) between 1 and 80),
  name text not null check (length(trim(name)) between 1 and 160),
  calculation_method text not null check (calculation_method in ('PERCENT_BASE','PER_HOUR','FIXED_PER_SHIFT')),
  percent_basis_points integer check (percent_basis_points >= 0),
  rate_minor_per_hour bigint check (rate_minor_per_hour >= 0),
  amount_minor bigint check (amount_minor >= 0),
  contract_type text,
  valid_from date not null,
  valid_to date,
  active boolean not null default true,
  reason text not null check (length(trim(reason)) >= 5),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  check (valid_to is null or valid_to >= valid_from),
  check (
    (calculation_method='PERCENT_BASE' and percent_basis_points is not null and rate_minor_per_hour is null and amount_minor is null)
    or (calculation_method='PER_HOUR' and rate_minor_per_hour is not null and percent_basis_points is null and amount_minor is null)
    or (calculation_method='FIXED_PER_SHIFT' and amount_minor is not null and percent_basis_points is null and rate_minor_per_hour is null)
  ),
  unique(logical_id,revision)
);

create unique index if not exists employer_cost_components_current_v2
  on public.employer_cost_components_v2(logical_id) where active;

create table if not exists public.recovery_incident_rate_revisions_v2 (
  id uuid primary key default gen_random_uuid(),
  incident_id uuid not null references public.recovery_incidents_v2(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  revision integer not null default 1 check (revision > 0),
  supersedes_id uuid references public.recovery_incident_rate_revisions_v2(id),
  proposed_rate_minor bigint not null check (proposed_rate_minor >= 0),
  approved_rate_minor bigint check (approved_rate_minor >= 0),
  currency text not null default 'PLN',
  valid_from date not null,
  valid_to date not null,
  status text not null default 'PROPOSED' check(status in ('PROPOSED','APPROVED','REJECTED','SUPERSEDED')),
  proposal_reason text not null check(length(trim(proposal_reason)) >= 5),
  decision_reason text,
  proposed_by uuid references auth.users(id) on delete set null,
  approved_by uuid references auth.users(id) on delete set null,
  proposed_at timestamptz not null default now(),
  approved_at timestamptz,
  check(valid_to >= valid_from),
  check((status='APPROVED' and approved_rate_minor is not null and approved_by is not null and approved_at is not null)
    or status <> 'APPROVED'),
  unique(incident_id,employee_id,revision)
);

alter table public.employer_cost_components_v2 enable row level security;
alter table public.recovery_incident_rate_revisions_v2 enable row level security;
revoke all on public.employer_cost_components_v2,public.recovery_incident_rate_revisions_v2 from public,anon,authenticated;
grant select on public.employer_cost_components_v2,public.recovery_incident_rate_revisions_v2 to authenticated;

drop policy if exists employer_cost_components_read_v2 on public.employer_cost_components_v2;
create policy employer_cost_components_read_v2 on public.employer_cost_components_v2
  for select to authenticated using (public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE') or public.has_app_role('ROLE_MANAGER') or public.has_app_role('LOCATION_MANAGER'));
drop policy if exists incident_rates_read_v2 on public.recovery_incident_rate_revisions_v2;
create policy incident_rates_read_v2 on public.recovery_incident_rate_revisions_v2
  for select to authenticated using (public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE') or public.has_app_role('ROLE_MANAGER') or public.has_app_role('LOCATION_MANAGER'));

create or replace function public.employer_cost_workspace_uat_v1(p_month date)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_month date:=date_trunc('month',p_month)::date;v_end date:=(date_trunc('month',p_month)+interval '1 month - 1 day')::date;
begin
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE') or public.has_app_role('ROLE_MANAGER') or public.has_app_role('LOCATION_MANAGER')) then raise exception 'FORBIDDEN'; end if;
  return jsonb_build_object('month',v_month,'components',coalesce((select jsonb_agg(jsonb_build_object(
    'id',c.id,'logicalId',c.logical_id,'revision',c.revision,'code',c.code,'name',c.name,
    'calculationMethod',c.calculation_method,'percentBasisPoints',c.percent_basis_points,
    'rateMinorPerHour',c.rate_minor_per_hour,'amountMinor',c.amount_minor,'contractType',c.contract_type,
    'validFrom',c.valid_from,'validTo',c.valid_to,'active',c.active,'reason',c.reason
  ) order by c.code,c.revision desc) from public.employer_cost_components_v2 c
    where c.active and c.valid_from<=v_end and coalesce(c.valid_to,'infinity'::date)>=v_month),'[]'::jsonb));
end $$;

create or replace function public.employer_cost_component_save_uat_v1(
  p_logical_id uuid,p_code text,p_name text,p_calculation_method text,p_value bigint,
  p_contract_type text,p_valid_from date,p_valid_to date,p_active boolean,p_reason text
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_actor uuid:=auth.uid();v_previous public.employer_cost_components_v2%rowtype;v_id uuid:=gen_random_uuid();v_logical uuid:=coalesce(p_logical_id,gen_random_uuid());v_revision integer:=1;
begin
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
  if p_calculation_method not in ('PERCENT_BASE','PER_HOUR','FIXED_PER_SHIFT') then raise exception 'INVALID_CALCULATION_METHOD'; end if;
  if p_value<0 or length(trim(coalesce(p_reason,'')))<5 then raise exception 'VALUE_AND_REASON_REQUIRED'; end if;
  select * into v_previous from public.employer_cost_components_v2 where logical_id=v_logical and active for update;
  if v_previous.id is not null then
    v_revision:=v_previous.revision+1;
    update public.employer_cost_components_v2 set active=false where id=v_previous.id;
  end if;
  insert into public.employer_cost_components_v2(id,logical_id,revision,supersedes_id,code,name,calculation_method,
    percent_basis_points,rate_minor_per_hour,amount_minor,contract_type,valid_from,valid_to,active,reason,created_by)
  values(v_id,v_logical,v_revision,v_previous.id,upper(trim(p_code)),trim(p_name),p_calculation_method,
    case when p_calculation_method='PERCENT_BASE' then p_value::integer end,
    case when p_calculation_method='PER_HOUR' then p_value end,
    case when p_calculation_method='FIXED_PER_SHIFT' then p_value end,
    nullif(trim(coalesce(p_contract_type,'')),''),p_valid_from,p_valid_to,p_active,trim(p_reason),v_actor);
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data) values(v_actor,'employer_cost_component_v2',v_id::text,'VERSION_SAVED',jsonb_build_object('logicalId',v_logical,'revision',v_revision));
  return v_id;
end $$;

create or replace function public.recovery_incident_rate_propose_uat_v1(
  p_incident_id uuid,p_employee_id uuid,p_rate_minor bigint,p_currency text,p_valid_from date,p_valid_to date,p_reason text
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_actor uuid:=auth.uid();v_previous public.recovery_incident_rate_revisions_v2%rowtype;v_id uuid:=gen_random_uuid();v_revision integer:=1;
begin
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('ROLE_MANAGER') or public.has_app_role('LOCATION_MANAGER')) then raise exception 'FORBIDDEN'; end if;
  if p_rate_minor<0 or p_valid_to<p_valid_from or length(trim(coalesce(p_reason,'')))<5 then raise exception 'INVALID_RATE_PROPOSAL'; end if;
  select * into v_previous from public.recovery_incident_rate_revisions_v2 where incident_id=p_incident_id and employee_id=p_employee_id and status in ('PROPOSED','APPROVED') order by revision desc limit 1 for update;
  if v_previous.id is not null then update public.recovery_incident_rate_revisions_v2 set status='SUPERSEDED' where id=v_previous.id;v_revision:=v_previous.revision+1;end if;
  insert into public.recovery_incident_rate_revisions_v2(id,incident_id,employee_id,revision,supersedes_id,proposed_rate_minor,currency,valid_from,valid_to,proposal_reason,proposed_by)
  values(v_id,p_incident_id,p_employee_id,v_revision,v_previous.id,p_rate_minor,upper(p_currency),p_valid_from,p_valid_to,trim(p_reason),v_actor);
  return v_id;
end $$;

create or replace function public.recovery_incident_rate_decide_uat_v1(p_rate_id uuid,p_approve boolean,p_approved_rate_minor bigint,p_reason text)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v_actor uuid:=auth.uid();v_rate public.recovery_incident_rate_revisions_v2%rowtype;
begin
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then raise exception 'FORBIDDEN'; end if;
  select * into v_rate from public.recovery_incident_rate_revisions_v2 where id=p_rate_id for update;
  if v_rate.id is null or v_rate.status<>'PROPOSED' then raise exception 'RATE_PROPOSAL_NOT_PENDING'; end if;
  if length(trim(coalesce(p_reason,'')))<5 then raise exception 'DECISION_REASON_REQUIRED'; end if;
  if p_approve and coalesce(p_approved_rate_minor,v_rate.proposed_rate_minor)<0 then raise exception 'INVALID_APPROVED_RATE'; end if;
  update public.recovery_incident_rate_revisions_v2 set status=case when p_approve then 'APPROVED' else 'REJECTED' end,
    approved_rate_minor=case when p_approve then coalesce(p_approved_rate_minor,proposed_rate_minor) end,
    approved_by=case when p_approve then v_actor end,approved_at=case when p_approve then now() end,decision_reason=trim(p_reason)
  where id=p_rate_id;
end $$;

alter function public.recovery_incident_detail_uat_v1(uuid)
  rename to recovery_incident_detail_before_b4f88_uat_v1;
create function public.recovery_incident_detail_uat_v1(p_incident_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_detail jsonb;
begin
  v_detail:=public.recovery_incident_detail_before_b4f88_uat_v1(p_incident_id);
  return jsonb_set(v_detail,'{incidentRates}',coalesce((select jsonb_agg(jsonb_build_object(
    'id',r.id,'employeeId',r.employee_id,'employeeName',trim(concat(e.first_name,' ',e.last_name)),
    'revision',r.revision,'proposedRateMinor',r.proposed_rate_minor,'approvedRateMinor',r.approved_rate_minor,
    'currency',r.currency,'validFrom',r.valid_from,'validTo',r.valid_to,'status',r.status,
    'proposalReason',r.proposal_reason,'decisionReason',r.decision_reason
  ) order by r.revision desc) from public.recovery_incident_rate_revisions_v2 r join public.employees e on e.id=r.employee_id where r.incident_id=p_incident_id),'[]'::jsonb),true);
end $$;

alter function solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)
  rename to build_snapshot_payload_before_b4f88_uat_v1;

create function solver_private.build_snapshot_payload_v2(
  p_matrix_version_id uuid,p_month date,p_scenario_id uuid,p_scope_role_id uuid,p_scope_type text,p_actor uuid
) returns jsonb language plpgsql security definer set search_path=public,solver_private,pg_temp as $$
declare v_snapshot jsonb;v_end date:=(p_month+interval '1 month - 1 day')::date;v_rules jsonb;
begin
  v_snapshot:=solver_private.build_snapshot_payload_before_b4f88_uat_v1(p_matrix_version_id,p_month,p_scenario_id,p_scope_role_id,p_scope_type,p_actor);
  select coalesce(jsonb_agg(rule_payload),'[]'::jsonb) into v_rules from (
    select jsonb_build_object('id','employer-cost:'||c.id,'calculationType',c.calculation_method,
      'values',jsonb_strip_nulls(jsonb_build_object('percentBasisPoints',c.percent_basis_points,'rateMinorPerHour',c.rate_minor_per_hour,'amountMinor',c.amount_minor)),
      'conditions',case when c.contract_type is null then '[]'::jsonb else jsonb_build_array(jsonb_build_object('field','contract_code','operator','EQ','value',c.contract_type)) end,
      'stackingGroup','employer-cost:'||c.logical_id,'stackingMode','STACK','priority',100,'active',true,
      'effectiveFrom',c.valid_from,'effectiveTo',c.valid_to,'costCategory','EMPLOYER_ONCOST') rule_payload
    from public.employer_cost_components_v2 c where c.active and c.valid_from<=v_end and coalesce(c.valid_to,'infinity'::date)>=p_month
    union all
    select jsonb_build_object('id','incident-rate:'||r.id,'calculationType','BASE_RATE_OVERRIDE',
      'values',jsonb_build_object('rateMinorPerHour',r.approved_rate_minor),
      'conditions',jsonb_build_array(jsonb_build_object('field','employee_id','operator','EQ','value',r.employee_id::text)),
      'stackingGroup','incident-rate:'||r.employee_id,'stackingMode','FIRST','priority',0,'active',true,
      'effectiveFrom',greatest(r.valid_from,p_month),'effectiveTo',least(r.valid_to,v_end),'costCategory','WAGE')
    from public.recovery_incident_rate_revisions_v2 r join public.recovery_incidents_v2 i on i.id=r.incident_id
    where r.status='APPROVED' and i.month=p_month and r.valid_from<=v_end and r.valid_to>=p_month
  ) payloads;
  return jsonb_set(v_snapshot,'{payRules}',coalesce(v_snapshot->'payRules','[]'::jsonb)||v_rules,true);
end $$;

revoke all on function public.employer_cost_workspace_uat_v1(date),public.employer_cost_component_save_uat_v1(uuid,text,text,text,bigint,text,date,date,boolean,text),
 public.recovery_incident_rate_propose_uat_v1(uuid,uuid,bigint,text,date,date,text),public.recovery_incident_rate_decide_uat_v1(uuid,boolean,bigint,text) from public,anon,authenticated;
grant execute on function public.employer_cost_workspace_uat_v1(date),public.employer_cost_component_save_uat_v1(uuid,text,text,text,bigint,text,date,date,boolean,text),
 public.recovery_incident_rate_propose_uat_v1(uuid,uuid,bigint,text,date,date,text),public.recovery_incident_rate_decide_uat_v1(uuid,boolean,bigint,text) to authenticated;
revoke all on function public.recovery_incident_detail_before_b4f88_uat_v1(uuid),public.recovery_incident_detail_uat_v1(uuid) from public,anon,authenticated;
grant execute on function public.recovery_incident_detail_uat_v1(uuid) to authenticated;
revoke all on function solver_private.build_snapshot_payload_before_b4f88_uat_v1(uuid,date,uuid,uuid,text,uuid),solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid) from public,anon,authenticated;
grant execute on function solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid) to service_role;
