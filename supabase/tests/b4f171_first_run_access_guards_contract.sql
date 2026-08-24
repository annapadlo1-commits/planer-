do $$
declare
  v_discard text;
  v_trigger_function text;
  v_discard_function text;
  v_ensure_function text;
begin
  if solver_private.matrix_v2_discard_decision_uat_v1(1,0)<>'PRESERVE_ONLY_DRAFT' then
    raise exception 'B4F171_ONLY_DRAFT_MUST_BE_PRESERVED';
  end if;
  if solver_private.matrix_v2_discard_decision_uat_v1(1,1)<>'DISCARD_DRAFT' then
    raise exception 'B4F171_ACTIVE_PLUS_DRAFT_MUST_DISCARD_DRAFT';
  end if;
  if solver_private.matrix_v2_discard_decision_uat_v1(0,0)<>'ENSURE_FIRST_RUN' then
    raise exception 'B4F171_ZERO_VERSIONS_MUST_ENSURE_FIRST_RUN';
  end if;
  if solver_private.matrix_v2_discard_decision_uat_v1(0,1)<>'NOOP_ACTIVE' then
    raise exception 'B4F171_ACTIVE_ONLY_MUST_REMAIN_ACTIVE';
  end if;

  select pg_get_functiondef('public.matrix_v2_prevent_last_usable_delete_uat_v1()'::regprocedure)
  into v_trigger_function;
  if v_trigger_function not like '%MATRIX_LAST_USABLE_VERSION_REQUIRED%' then
    raise exception 'B4F171_LAST_USABLE_DELETE_GUARD_MISSING';
  end if;
  if not exists(
    select 1 from pg_trigger t
    where t.tgrelid='public.matrix_versions'::regclass
      and t.tgname='matrix_v2_prevent_last_usable_delete_uat_v1'
      and not t.tgisinternal
  ) then
    raise exception 'B4F171_LAST_USABLE_DELETE_TRIGGER_MISSING';
  end if;

  select pg_get_functiondef('public.matrix_v2_discard_current_draft_uat_v2()'::regprocedure)
  into v_discard_function;
  if v_discard_function not like '%B4F171_PRESERVE_ONLY_DRAFT%'
    or v_discard_function not like '%B4F171_USABLE_MATRIX_REQUIRED_AFTER_DISCARD%' then
    raise exception 'B4F171_DISCARD_POSTCONDITION_MISSING';
  end if;

  select pg_get_functiondef('public.matrix_v2_ensure_first_run_uat_v1()'::regprocedure)
  into v_ensure_function;
  if v_ensure_function not like '%matrix_v2_create_safe_first_run_uat_v1%'
    or v_ensure_function not like '%USABLE_MATRIX_EXISTS%' then
    raise exception 'B4F171_FIRST_RUN_ENSURE_CONTRACT_MISSING';
  end if;

  if has_function_privilege('anon','public.matrix_v2_ensure_first_run_uat_v1()','EXECUTE')
    or has_function_privilege('anon','public.matrix_v2_discard_current_draft_uat_v2()','EXECUTE')
    or not has_function_privilege('authenticated','public.matrix_v2_ensure_first_run_uat_v1()','EXECUTE') then
    raise exception 'B4F171_RPC_PRIVILEGES_INVALID';
  end if;

  if pg_get_functiondef('public.uat_full_business_reset_v1(text)'::regprocedure)
      like '%bdybebzvzapihjdauehg%'
    or pg_get_functiondef('public.uat_full_business_reset_v1(text)'::regprocedure)
      not like '%nhthrtpkfpmufmrmdyjg%' then
    raise exception 'B4F171_UAT_PROJECT_GUARD_INVALID';
  end if;

  raise notice 'B4F171_FIRST_RUN_ACCESS_GUARDS_CONTRACT_PASS';
end;
$$;
