-- Contract checks for the provider-neutral pull worker and lease recovery.
do $$
declare
  v_claim text;
  v_recovery text;
  v_interrupt_wrapper text;
  v_interrupt_delegate text;
  v_fail_wrapper text;
  v_fail_delegate text;
begin
  if to_regprocedure(
    'public.solver_claim_next_v2(text,text,integer,integer)'
  ) is null then raise exception 'missing version-bound pull claim'; end if;
  if to_regprocedure(
    'solver_private.recover_expired_solver_runs_v2(integer)'
  ) is null then raise exception 'missing automatic lease recovery'; end if;

  if to_regprocedure(
    'public.solver_claim_v2(uuid,uuid,text,text,integer,integer)'
  ) is not null
    or to_regprocedure('public.solver_dispatch_next_v2(text,integer)') is not null
    or to_regprocedure(
      'public.solver_reconcile_stale_v2(text,text,integer,integer,uuid,text,uuid,integer,integer,text,text)'
    ) is not null
  then raise exception 'provider-specific dispatcher RPC still exists'; end if;
  if to_regclass('solver_private.optimization_dispatch_v2') is not null then
    raise exception 'provider-specific dispatch reservation table still exists';
  end if;
  if exists(
    select 1 from pg_trigger
    where tgrelid='public.optimization_runs_v2'::regclass
      and tgname='optimization_runs_v2_reset_stale_dispatch'
      and not tgisinternal
  ) then raise exception 'provider-specific dispatch trigger still exists'; end if;

  select pg_get_functiondef(to_regprocedure(
    'public.solver_claim_next_v2(text,text,integer,integer)'
  )) into v_claim;
  select pg_get_functiondef(to_regprocedure(
    'solver_private.recover_expired_solver_runs_v2(integer)'
  )) into v_recovery;
  select pg_get_functiondef(to_regprocedure(
    'public.solver_interrupt_v2(uuid,uuid,uuid,text)'
  )) into v_interrupt_wrapper;
  select pg_get_functiondef(to_regprocedure(
    'public.solver_interrupt_before_nfjob_uat_v1(uuid,uuid,uuid,text)'
  )) into v_interrupt_delegate;
  select pg_get_functiondef(to_regprocedure(
    'public.solver_fail_attempt_v2(uuid,uuid,uuid,text,text,boolean)'
  )) into v_fail_wrapper;
  select pg_get_functiondef(to_regprocedure(
    'public.solver_fail_attempt_before_nfjob_uat_v1(uuid,uuid,uuid,text,text,boolean)'
  )) into v_fail_delegate;

  if v_claim not like '%pgmq.read%'
    or v_claim not like '%pgmq.set_vt%'
    or v_claim not like '%VERSION_MISMATCH%'
    or v_claim not like '%p_worker_version%'
    or v_claim not like '%for update%'
    or v_claim not like '%pgmq.archive%'
    or v_claim not like '%optimization_attempts_v2%'
  then raise exception 'pull claim is not atomic and version-bound'; end if;
  if strpos(v_claim,'VERSION_MISMATCH')
    > strpos(v_claim,'insert into solver_private.optimization_attempts_v2')
  then raise exception 'worker version fence runs after attempt mutation'; end if;
  if v_claim not like '%not between 1 and 20%'
    or v_claim not like '%not between 30 and 900%'
  then raise exception 'pull claim resource bounds are missing'; end if;

  if v_recovery not like '%LEASE_EXPIRED%'
    or v_recovery not like '%CANCEL_REQUESTED%'
    or v_recovery not like '%MAX_ATTEMPTS%'
    or v_recovery not like '%skip locked%'
    or v_recovery not like '%reset_retry_outputs_v2%'
    or v_recovery not like '%pgmq.send%'
  then raise exception 'automatic recovery state machine is incomplete'; end if;
  if v_interrupt_wrapper not like '%solver_interrupt_before_nfjob_uat_v1%'
    or v_interrupt_delegate not like '%reset_retry_outputs_v2%'
    or v_interrupt_delegate not like '%worker_execution_name=null%'
    or v_fail_wrapper not like '%solver_fail_attempt_before_nfjob_uat_v1%'
    or v_fail_delegate not like '%reset_retry_outputs_v2%'
    or v_fail_delegate not like '%worker_execution_name=null%'
  then raise exception 'retry cleanup is incomplete'; end if;

  if (
    select count(*) from cron.job
    where jobname='grafik-pro-solver-v2-recovery'
  ) <> 1 then raise exception 'automatic recovery cron is not singular'; end if;

  if has_function_privilege(
    'public',
    'public.solver_claim_next_v2(text,text,integer,integer)',
    'EXECUTE'
  ) or has_function_privilege(
    'anon',
    'public.solver_claim_next_v2(text,text,integer,integer)',
    'EXECUTE'
  ) or has_function_privilege(
    'authenticated',
    'public.solver_claim_next_v2(text,text,integer,integer)',
    'EXECUTE'
  ) then raise exception 'pull claim leaked outside service_role'; end if;
  if not has_function_privilege(
    'service_role',
    'public.solver_claim_next_v2(text,text,integer,integer)',
    'EXECUTE'
  ) then raise exception 'service_role cannot execute pull claim'; end if;
  if has_function_privilege(
    'service_role',
    'solver_private.recover_expired_solver_runs_v2(integer)',
    'EXECUTE'
  ) or has_function_privilege(
    'public',
    'solver_private.recover_expired_solver_runs_v2(integer)',
    'EXECUTE'
  ) then raise exception 'private recovery helper is externally executable'; end if;

  if exists(
    select 1 from pg_proc procedure_row
    join pg_namespace namespace_row
      on namespace_row.oid=procedure_row.pronamespace
    where namespace_row.nspname='public'
      and procedure_row.proname in (
        'solver_claim_next_v2','solver_interrupt_v2','solver_fail_attempt_v2'
      )
      and (
        not procedure_row.prosecdef
        or not ('search_path=""'=any(procedure_row.proconfig))
      )
  ) then raise exception 'machine RPC missing SECURITY DEFINER/search_path fence'; end if;
end;
$$;
