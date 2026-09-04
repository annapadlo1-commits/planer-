-- UAT-006 / MX-K09: REQUIRED means at least one person.  Repair the single
-- legacy draft row and validate the global table constraint so UI, import and
-- every RPC share the same invariant.

do $$
declare
  v_actor uuid;
  v_repaired integer:=0;
begin
  select permission.auth_user_id into v_actor
  from public.user_permissions permission
  where permission.app_role in ('OWNER','ADMIN')
  order by permission.id
  limit 1;

  with repaired as (
    update public.matrix_role_duties_v2 role_duty
    set minimum_count=1
    from public.matrix_versions matrix
    where matrix.id=role_duty.matrix_version_id
      and matrix.status='DRAFT'
      and role_duty.active
      and role_duty.assignment_mode='REQUIRED'
      and role_duty.minimum_count<=0
    returning role_duty.id,role_duty.matrix_version_id,
      role_duty.role_id,role_duty.duty_id
  ), audited as (
    insert into public.audit_log(
      actor_id,entity_type,entity_id,action,old_data,new_data
    )
    select v_actor,'matrix_role_duty_v2',repaired.id::text,
      'REPAIR_REQUIRED_MINIMUM',
      jsonb_build_object('minimumCount',0),
      jsonb_build_object(
        'minimumCount',1,
        'matrixVersionId',repaired.matrix_version_id,
        'roleId',repaired.role_id,
        'dutyId',repaired.duty_id,
        'reason','REQUIRED_REQUIRES_AT_LEAST_ONE'
      )
    from repaired
    returning 1
  )
  select count(*) into v_repaired from audited;

  if v_repaired<>1 then
    raise exception 'EXPECTED_ONE_REQUIRED_ZERO_REPAIR_GOT_%',v_repaired;
  end if;
end;
$$;

alter table public.matrix_role_duties_v2
  validate constraint matrix_role_duties_required_positive_uat006;
