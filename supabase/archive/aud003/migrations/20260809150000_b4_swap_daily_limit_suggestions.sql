-- B4 UAT: a free time window is not a valid swap suggestion when the employee
-- has already reached the configured daily shift limit. Keep the reason visible
-- in discovery instead of surprising the leader only after the save attempt.

alter function public.optimizer_leader_assignment_context_uat_v2(uuid,uuid,bigint)
  rename to optimizer_leader_assignment_context_before_daily_limit_uat_v2;

create function public.optimizer_leader_assignment_context_uat_v2(
  p_variant_id uuid,p_assignment_id uuid default null,p_issue_id bigint default null
) returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_payload jsonb;v_matrix_version_id uuid;v_shift_date date;
  v_daily_limit integer:=1;v_candidates jsonb:='[]'::jsonb;
begin
  v_payload:=public.optimizer_leader_assignment_context_before_daily_limit_uat_v2(
    p_variant_id,p_assignment_id,p_issue_id);
  select run.matrix_version_id into v_matrix_version_id
  from public.plan_variants_v2 variant
  join public.optimization_runs_v2 run on run.id=variant.run_id
  where variant.id=p_variant_id;
  v_shift_date:=(v_payload#>>'{shift,date}')::date;
  select greatest(1,coalesce(nullif(settings->>'maximumShiftsPerDay','')::integer,1))
    into v_daily_limit from public.matrix_versions where id=v_matrix_version_id;
  select coalesce(jsonb_agg(case when candidate.value->>'availabilityStatus' in ('AVAILABLE','SOFT_AVOID')
      and (select count(*) from public.plan_assignments_v2 occupied
        join public.plan_shifts_v2 occupied_shift on occupied_shift.id=occupied.shift_id
        where occupied.variant_id=p_variant_id
          and occupied.employee_id=(candidate.value->>'employeeId')::uuid
          and occupied.id is distinct from p_assignment_id
          and occupied_shift.shift_date=v_shift_date)>=v_daily_limit
    then candidate.value||jsonb_build_object(
      'availabilityStatus','DAILY_LIMIT','suggestionEligible',false)
    else candidate.value end order by candidate.ordinality),'[]'::jsonb)
    into v_candidates
  from jsonb_array_elements(coalesce(v_payload->'candidates','[]'::jsonb))
    with ordinality candidate(value,ordinality);
  return jsonb_set(v_payload,'{candidates}',v_candidates,true);
end;
$$;

revoke all on function public.optimizer_leader_assignment_context_uat_v2(uuid,uuid,bigint) from public;
grant execute on function public.optimizer_leader_assignment_context_uat_v2(uuid,uuid,bigint) to authenticated;
