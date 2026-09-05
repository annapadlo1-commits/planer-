-- UAT-006: duty archival must be atomic and shift buckets are derived data.

create or replace function solver_private.alpha16_shift_period_default_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.shift_period := case
    when new.starts_at < time '12:00' then 'MORNING'
    when new.starts_at < time '17:00' then 'MIDDLE'
    else 'EVENING'
  end;
  return new;
end;
$$;

create or replace function solver_private.matrix_duty_deactivation_guard_uat006()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
  if old.active and not new.active and (
    exists(select 1 from public.matrix_role_duties_v2 link
      where link.matrix_version_id=old.matrix_version_id and link.duty_id=old.id and link.active)
    or exists(select 1 from public.matrix_employee_duties_v2 link
      where link.matrix_version_id=old.matrix_version_id and link.duty_id=old.id and link.active)
    or exists(select 1 from public.matrix_staffing_rules_v2 rule
      where rule.matrix_version_id=old.matrix_version_id and rule.duty_id=old.id and rule.active)
    or exists(select 1 from public.matrix_pay_rule_duties_v2 link
      where link.matrix_version_id=old.matrix_version_id and link.duty_id=old.id)
  ) then
    raise exception 'DUTY_ARCHIVE_REQUIRES_AUDITED_RPC';
  end if;
  return new;
end;
$$;

drop trigger if exists matrix_duty_deactivation_guard_uat006 on public.matrix_duties_v2;
create trigger matrix_duty_deactivation_guard_uat006
before update of active on public.matrix_duties_v2
for each row execute function solver_private.matrix_duty_deactivation_guard_uat006();

create or replace function public.matrix_v2_duty_archive_uat_v2(
  p_duty_id uuid,
  p_reason text
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare
  v_duty public.matrix_duties_v2%rowtype;
  v_role_duties integer:=0; v_employee_duties integer:=0;
  v_staffing_rules integer:=0; v_pay_rules integer:=0;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  if length(trim(coalesce(p_reason,'')))<5 then raise exception 'ARCHIVE_REASON_REQUIRED'; end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));
  select duty.* into v_duty from public.matrix_duties_v2 duty
  join public.matrix_versions version on version.id=duty.matrix_version_id
  where duty.id=p_duty_id and version.status='DRAFT' for update of duty;
  if v_duty.id is null then raise exception 'DRAFT_DUTY_NOT_FOUND'; end if;
  if not v_duty.active then raise exception 'DUTY_ALREADY_ARCHIVED'; end if;

  update public.matrix_role_duties_v2 set active=false
    where matrix_version_id=v_duty.matrix_version_id and duty_id=p_duty_id and active;
  get diagnostics v_role_duties=row_count;
  update public.matrix_employee_duties_v2 set active=false
    where matrix_version_id=v_duty.matrix_version_id and duty_id=p_duty_id and active;
  get diagnostics v_employee_duties=row_count;
  update public.matrix_staffing_rules_v2 set active=false
    where matrix_version_id=v_duty.matrix_version_id and duty_id=p_duty_id and active;
  get diagnostics v_staffing_rules=row_count;
  delete from public.matrix_pay_rule_duties_v2
    where matrix_version_id=v_duty.matrix_version_id and duty_id=p_duty_id;
  get diagnostics v_pay_rules=row_count;
  update public.matrix_duties_v2 set active=false where id=p_duty_id;

  insert into public.audit_log(actor_id,entity_type,entity_id,action,old_data,new_data)
  values(auth.uid(),'matrix_v2_duty',p_duty_id::text,'ARCHIVE_WITH_DEPENDENCIES',
    to_jsonb(v_duty),jsonb_build_object('active',false,'reason',trim(p_reason),
      'roleDutiesDeactivated',v_role_duties,'employeeDutiesDeactivated',v_employee_duties,
      'staffingRulesDeactivated',v_staffing_rules,'payRuleLinksRemoved',v_pay_rules));
  return jsonb_build_object('dutyId',p_duty_id,'archived',true,
    'roleDutiesDeactivated',v_role_duties,'employeeDutiesDeactivated',v_employee_duties,
    'staffingRulesDeactivated',v_staffing_rules,'payRuleLinksRemoved',v_pay_rules);
end;
$$;

-- Repair inconsistent UAT draft data created by the former partial archive path.
with repaired as (
  update public.matrix_duties_v2 duty set active=true
  from public.matrix_versions version
  where version.id=duty.matrix_version_id and version.status='DRAFT' and not duty.active and (
    exists(select 1 from public.matrix_role_duties_v2 link where link.matrix_version_id=duty.matrix_version_id and link.duty_id=duty.id and link.active)
    or exists(select 1 from public.matrix_employee_duties_v2 link where link.matrix_version_id=duty.matrix_version_id and link.duty_id=duty.id and link.active)
    or exists(select 1 from public.matrix_staffing_rules_v2 rule where rule.matrix_version_id=duty.matrix_version_id and rule.duty_id=duty.id and rule.active)
  ) returning duty.id
)
insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
select null,'matrix_v2_duty',id::text,'RESTORE_DUTY_WITH_ACTIVE_DEPENDENCIES',
  jsonb_build_object('active',true,'migration','20260805150000') from repaired;

update public.matrix_shift_templates_v2 shift_row set
  shift_period=case when shift_row.starts_at<time '12:00' then 'MORNING'
    when shift_row.starts_at<time '17:00' then 'MIDDLE' else 'EVENING' end,
  updated_at=now()
from public.matrix_versions version
where version.id=shift_row.matrix_version_id and version.status='DRAFT'
  and shift_row.active and shift_row.shift_period is distinct from case
    when shift_row.starts_at<time '12:00' then 'MORNING'
    when shift_row.starts_at<time '17:00' then 'MIDDLE' else 'EVENING' end;

revoke all on function public.matrix_v2_duty_archive_uat_v2(uuid,text) from public;
grant execute on function public.matrix_v2_duty_archive_uat_v2(uuid,text) to authenticated;

