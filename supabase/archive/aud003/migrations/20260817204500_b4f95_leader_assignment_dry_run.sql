create or replace function public.optimizer_leader_assignment_validate_uat_v1(
  p_variant_id uuid,
  p_assignment_id uuid,
  p_issue_id bigint,
  p_employee_id uuid,
  p_allow_limit_override boolean default false,
  p_duty_transfer_assignment_id uuid default null,
  p_approve_overtime boolean default false
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
  v_rollback_marker constant text := 'B4F95_DRY_RUN_ROLLBACK';
begin
  begin
    v_result := public.optimizer_leader_assignment_save_uat_v3(
      p_variant_id,
      p_assignment_id,
      p_issue_id,
      p_employee_id,
      'Walidacja przed zapisem',
      p_allow_limit_override,
      p_duty_transfer_assignment_id,
      p_approve_overtime
    );
    raise exception using errcode = 'P0001', message = v_rollback_marker;
  exception
    when raise_exception then
      if sqlerrm <> v_rollback_marker then
        raise;
      end if;
  end;

  return coalesce(v_result, '{}'::jsonb) || jsonb_build_object(
    'valid', true,
    'mutated', false,
    'checkedAt', now()
  );
end;
$$;

revoke all on function public.optimizer_leader_assignment_validate_uat_v1(
  uuid, uuid, bigint, uuid, boolean, uuid, boolean
) from public, anon, authenticated;
grant execute on function public.optimizer_leader_assignment_validate_uat_v1(
  uuid, uuid, bigint, uuid, boolean, uuid, boolean
) to authenticated;

comment on function public.optimizer_leader_assignment_validate_uat_v1(
  uuid, uuid, bigint, uuid, boolean, uuid, boolean
) is 'B4F-95: runs the exact atomic leader-save validation inside a rolled-back subtransaction; it never persists assignments, issues, audit rows or counters.';

notify pgrst, 'reload schema';
