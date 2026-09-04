-- Alpha 14 hotfix: resumable initial population and guaranteed run closure.

create or replace function public.optimizer_save_state_v3(
  p_run_id uuid,
  p_expected_generation integer,
  p_checkpoint jsonb,
  p_metrics jsonb
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_generation integer;
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  update public.optimization_runs set
    checkpoint=coalesce(p_checkpoint,'{}'::jsonb),
    heartbeat_at=now(),
    result_summary=coalesce(result_summary,'{}'::jsonb)||coalesce(p_metrics,'{}'::jsonb)
  where id=p_run_id and requested_by=auth.uid() and status='RUNNING'
    and current_generation=p_expected_generation
  returning current_generation into v_generation;
  if v_generation is null then raise exception 'STALE_OR_FORBIDDEN_STATE'; end if;
  return jsonb_build_object('runId',p_run_id,'generation',v_generation);
end $$;

create or replace function public.optimizer_fail_v3(p_run_id uuid,p_error text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_changed integer;
begin
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  update public.optimization_runs set
    status='FAILED', finished_at=now(), heartbeat_at=now(),
    failure_message=left(coalesce(p_error,'UNKNOWN_ERROR'),2000),
    result_summary=coalesce(result_summary,'{}'::jsonb)||jsonb_build_object('phase','FAILED','progress',100)
  where id=p_run_id and requested_by=auth.uid() and status='RUNNING';
  get diagnostics v_changed=row_count;
  return jsonb_build_object('runId',p_run_id,'failed',v_changed=1);
end $$;

revoke all on function public.optimizer_save_state_v3(uuid,integer,jsonb,jsonb) from public,anon;
revoke all on function public.optimizer_fail_v3(uuid,text) from public,anon;
grant execute on function public.optimizer_save_state_v3(uuid,integer,jsonb,jsonb) to authenticated;
grant execute on function public.optimizer_fail_v3(uuid,text) to authenticated;
