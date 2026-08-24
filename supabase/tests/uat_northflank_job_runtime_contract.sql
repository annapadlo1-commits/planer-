begin;

do $$
declare v_result jsonb:=public.solver_job_contract_probe_uat_v1();
begin
  if v_result->>'passed'<>'true' or v_result->>'rolledBack'<>'true' then
    raise exception 'NORTHFLANK_JOB_GATE_B_FAILED: %',v_result;
  end if;
end;
$$;

rollback;
