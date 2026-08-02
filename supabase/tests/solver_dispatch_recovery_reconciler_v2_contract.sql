-- Contract checks for one-shot Cloud Run dispatch and two-phase recovery.
do $$
declare
  v_claim text;
  v_dispatch text;
  v_mark text;
  v_reconcile text;
  v_interrupt text;
  v_fail text;
begin
  if to_regprocedure(
    'public.solver_claim_v2(uuid,uuid,text,text,integer,integer)'
  ) is null then raise exception 'missing version-bound solver_claim_v2'; end if;
  if to_regprocedure(
    'public.solver_reconcile_stale_v2(text,text,integer,integer,uuid,text,uuid,integer,integer,text,text)'
  ) is null then raise exception 'missing solver_reconcile_stale_v2'; end if;
  if to_regprocedure('public.solver_claim_next_v2(text,integer,integer)')
    is not null
  then raise exception 'pull-worker claim RPC still exists'; end if;
  if to_regprocedure('solver_private.recover_expired_solver_runs_v2(integer)')
    is not null
  then raise exception 'provider-blind recovery helper still exists'; end if;
  if exists(
    select 1 from pg_trigger
    where tgrelid='public.optimization_runs_v2'::regclass
      and tgname='optimization_runs_v2_cleanup_retry_variants'
      and not tgisinternal
  ) then raise exception 'obsolete pull cleanup trigger still exists'; end if;

  select pg_get_functiondef(to_regprocedure(
    'public.solver_claim_v2(uuid,uuid,text,text,integer,integer)'
  )) into v_claim;
  select pg_get_functiondef(to_regprocedure(
    'public.solver_dispatch_next_v2(text,integer)'
  )) into v_dispatch;
  select pg_get_functiondef(to_regprocedure(
    'public.solver_mark_dispatched_v2(uuid,uuid,text)'
  )) into v_mark;
  select pg_get_functiondef(to_regprocedure(
    'public.solver_reconcile_stale_v2(text,text,integer,integer,uuid,text,uuid,integer,integer,text,text)'
  )) into v_reconcile;
  select pg_get_functiondef(to_regprocedure(
    'public.solver_interrupt_v2(uuid,uuid,uuid,text)'
  )) into v_interrupt;
  select pg_get_functiondef(to_regprocedure(
    'public.solver_fail_attempt_v2(uuid,uuid,uuid,text,text,boolean)'
  )) into v_fail;

  if strpos(v_claim,'SOLVER_VERSION_MISMATCH')=0
    or strpos(v_claim,'SOLVER_VERSION_MISMATCH')
      > strpos(v_claim,'set worker_launch_token=null')
  then raise exception 'claim consumes token before solver version fence'; end if;
  if v_claim not like '%not between 1 and 20%'
  then raise exception 'claim task attempt is not bounded 1..20'; end if;
  if v_dispatch not like '%claimedUnacknowledged%'
    or v_dispatch not like '%solverVersion%'
  then raise exception 'dispatch does not expose Cloud claim/version state'; end if;
  if v_dispatch not like '%DISPATCH_ATTEMPTS_EXHAUSTED%'
  then raise exception 'dispatch attempt 21 has no terminal behavior'; end if;
  if v_mark not like '%optimization_attempts_v2%'
    or v_mark not like '%worker_execution_name=p_execution_name%'
  then raise exception 'claim-before-mark attempt repair is missing'; end if;

  if v_reconcile not like '%RESERVATION_EXPIRED%'
    or v_reconcile not like '%CLAIMED_UNACKNOWLEDGED%'
    or v_reconcile not like '%LAUNCH_EXPIRED%'
    or v_reconcile not like '%LEASE_EXPIRED%'
    or v_reconcile not like '%RECOVERY_STATE_NOT_CONCLUSIVE%'
    or v_reconcile not like '%CLAIMED_RECOVERY_REQUIRES_NOT_FOUND%'
  then raise exception 'recovery state machine is incomplete'; end if;
  if strpos(v_reconcile,'STALE')=0
    or strpos(lower(v_reconcile),'delete from public.plan_variants_v2')=0
    or strpos(v_reconcile,'''{}''::jsonb')=0
  then raise exception 'recovery CAS/output cleanup is incomplete'; end if;
  if v_interrupt not like '%reset_retry_outputs_v2%'
    or v_fail not like '%reset_retry_outputs_v2%'
    or v_interrupt not like '%worker_execution_name=null%'
    or v_fail not like '%worker_execution_name=null%'
  then raise exception 'worker retry cleanup is incomplete'; end if;

  if has_function_privilege(
    'public','public.solver_claim_v2(uuid,uuid,text,text,integer,integer)',
    'EXECUTE'
  ) or has_function_privilege(
    'anon','public.solver_claim_v2(uuid,uuid,text,text,integer,integer)',
    'EXECUTE'
  ) or has_function_privilege(
    'authenticated',
    'public.solver_claim_v2(uuid,uuid,text,text,integer,integer)','EXECUTE'
  ) then raise exception 'claim RPC leaked outside service_role'; end if;
  if not has_function_privilege(
    'service_role',
    'public.solver_claim_v2(uuid,uuid,text,text,integer,integer)','EXECUTE'
  ) then raise exception 'service_role cannot execute claim RPC'; end if;

  if has_function_privilege(
    'public',
    'public.solver_reconcile_stale_v2(text,text,integer,integer,uuid,text,uuid,integer,integer,text,text)',
    'EXECUTE'
  ) or has_function_privilege(
    'anon',
    'public.solver_reconcile_stale_v2(text,text,integer,integer,uuid,text,uuid,integer,integer,text,text)',
    'EXECUTE'
  ) or has_function_privilege(
    'authenticated',
    'public.solver_reconcile_stale_v2(text,text,integer,integer,uuid,text,uuid,integer,integer,text,text)',
    'EXECUTE'
  ) then raise exception 'recovery RPC leaked outside service_role'; end if;
  if not has_function_privilege(
    'service_role',
    'public.solver_reconcile_stale_v2(text,text,integer,integer,uuid,text,uuid,integer,integer,text,text)',
    'EXECUTE'
  ) then raise exception 'service_role cannot execute recovery RPC'; end if;

  if has_function_privilege(
    'service_role','solver_private.reset_retry_outputs_v2(uuid)','EXECUTE'
  ) or has_function_privilege(
    'public','solver_private.reset_retry_outputs_v2(uuid)','EXECUTE'
  ) then raise exception 'private retry helper is externally executable'; end if;

  if exists(
    select 1 from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname in (
        'solver_claim_v2','solver_dispatch_next_v2',
        'solver_mark_dispatched_v2','solver_release_dispatch_v2',
        'solver_reconcile_stale_v2'
      )
      and (not p.prosecdef or not ('search_path=""'=any(p.proconfig)))
  ) then raise exception 'machine RPC missing SECURITY DEFINER/search_path fence'; end if;
end;
$$;
