-- Contract checks for 20260801224500_active_solver_version_publication_fence_v2.sql.
-- Run after the complete migration chain on a disposable/local database.

begin;

do $$
declare
  v_helper text;
  v_selection_guard text;
  v_link_guard text;
  v_select text;
  v_company text;
  v_composite text;
  v_candidates text;
  v_candidates_fallback text;
  v_candidates_delegate text;
  v_employee text;
begin
  if to_regprocedure(
    'solver_private.active_ortools_solver_version_v2()'
  ) is null then
    raise exception 'ACTIVE_SOLVER_VERSION_HELPER_MISSING';
  end if;
  if to_regprocedure(
    'solver_private.guard_active_variant_selection_v2()'
  ) is null then
    raise exception 'ACTIVE_SELECTION_GUARD_MISSING';
  end if;
  if to_regprocedure(
    'solver_private.optimizer_select_variant_pre_version_fence_v2(uuid,uuid)'
  ) is null or to_regprocedure(
    'solver_private.optimizer_publish_company_variant_pre_version_fence_v2(uuid,uuid,text,text)'
  ) is null or to_regprocedure(
    'solver_private.optimizer_publish_role_composite_pre_version_fence_v2(date,uuid,uuid[],text,text)'
  ) is null then
    raise exception 'PRIVATE_PUBLICATION_IMPLEMENTATION_MISSING';
  end if;

  if has_function_privilege(
    'anon','solver_private.active_ortools_solver_version_v2()','execute'
  ) or has_function_privilege(
    'authenticated','solver_private.active_ortools_solver_version_v2()','execute'
  ) or not has_function_privilege(
    'service_role','solver_private.active_ortools_solver_version_v2()','execute'
  ) then raise exception 'ACTIVE_SOLVER_VERSION_HELPER_GRANTS_INVALID'; end if;

  if has_function_privilege(
    'anon',
    'solver_private.optimizer_select_variant_pre_version_fence_v2(uuid,uuid)',
    'execute'
  ) or has_function_privilege(
    'authenticated',
    'solver_private.optimizer_select_variant_pre_version_fence_v2(uuid,uuid)',
    'execute'
  ) or has_function_privilege(
    'service_role',
    'solver_private.optimizer_select_variant_pre_version_fence_v2(uuid,uuid)',
    'execute'
  ) or has_function_privilege(
    'anon',
    'solver_private.optimizer_publish_company_variant_pre_version_fence_v2(uuid,uuid,text,text)',
    'execute'
  ) or has_function_privilege(
    'authenticated',
    'solver_private.optimizer_publish_company_variant_pre_version_fence_v2(uuid,uuid,text,text)',
    'execute'
  ) or has_function_privilege(
    'service_role',
    'solver_private.optimizer_publish_company_variant_pre_version_fence_v2(uuid,uuid,text,text)',
    'execute'
  ) or has_function_privilege(
    'anon',
    'solver_private.optimizer_publish_role_composite_pre_version_fence_v2(date,uuid,uuid[],text,text)',
    'execute'
  ) or has_function_privilege(
    'authenticated',
    'solver_private.optimizer_publish_role_composite_pre_version_fence_v2(date,uuid,uuid[],text,text)',
    'execute'
  ) or has_function_privilege(
    'service_role',
    'solver_private.optimizer_publish_role_composite_pre_version_fence_v2(date,uuid,uuid[],text,text)',
    'execute'
  ) then raise exception 'PRIVATE_PUBLICATION_IMPLEMENTATION_EXPOSED'; end if;

  if not has_function_privilege(
    'authenticated','public.optimizer_select_variant_v2(uuid,uuid)','execute'
  ) or has_function_privilege(
    'anon','public.optimizer_select_variant_v2(uuid,uuid)','execute'
  ) or not has_function_privilege(
    'authenticated',
    'public.optimizer_publish_company_variant_alpha16(uuid,uuid,text,text,text)',
    'execute'
  ) or has_function_privilege(
    'anon',
    'public.optimizer_publish_company_variant_alpha16(uuid,uuid,text,text,text)',
    'execute'
  ) or has_function_privilege(
    'authenticated',
    'public.optimizer_publish_company_variant_v2(uuid,uuid,text,text)',
    'execute'
  ) or not has_function_privilege(
    'authenticated',
    'public.optimizer_publish_role_composite_v2(date,uuid,uuid[],text,text)',
    'execute'
  ) or has_function_privilege(
    'anon',
    'public.optimizer_publish_role_composite_v2(date,uuid,uuid[],text,text)',
    'execute'
  ) then raise exception 'PUBLIC_VERSION_FENCE_RPC_GRANTS_INVALID'; end if;

  if not exists(
    select 1
    from pg_trigger trigger_row
    join pg_proc proc on proc.oid=trigger_row.tgfoid
    join pg_namespace namespace on namespace.oid=proc.pronamespace
    where trigger_row.tgrelid='public.plan_variants_v2'::regclass
      and not trigger_row.tgisinternal
      and trigger_row.tgenabled='O'
      and trigger_row.tgname='plan_variants_v2_active_solver_selection'
      and namespace.nspname='solver_private'
      and proc.proname='guard_active_variant_selection_v2'
  ) then raise exception 'ACTIVE_SELECTION_TRIGGER_MISSING'; end if;
  if not exists(
    select 1
    from pg_trigger trigger_row
    join pg_proc proc on proc.oid=trigger_row.tgfoid
    join pg_namespace namespace on namespace.oid=proc.pronamespace
    where trigger_row.tgrelid=
      'public.published_schedule_variants_v2'::regclass
      and not trigger_row.tgisinternal
      and trigger_row.tgenabled='O'
      and trigger_row.tgname='published_schedule_variants_v2_production_only'
      and namespace.nspname='solver_private'
      and proc.proname='guard_production_variant_link_v2'
  ) then raise exception 'ACTIVE_PUBLICATION_LINK_TRIGGER_MISSING'; end if;

  v_helper:=replace(pg_get_functiondef(
    'solver_private.active_ortools_solver_version_v2()'::regprocedure
  ),' ','');
  if position('flag.enabled' in v_helper)=0
    or position('flag.engine' in v_helper)=0
    or position('ORTOOLS_V2' in v_helper)=0
    or position('solverVersion' in v_helper)=0
    or position('SOLVER_VERSION_CONFIGURATION_REQUIRED' in v_helper)=0 then
    raise exception 'ACTIVE_SOLVER_VERSION_HELPER_NOT_FAIL_CLOSED';
  end if;

  v_selection_guard:=replace(pg_get_functiondef(
    'solver_private.guard_active_variant_selection_v2()'::regprocedure
  ),' ','');
  v_link_guard:=replace(pg_get_functiondef(
    'solver_private.guard_production_variant_link_v2()'::regprocedure
  ),' ','');
  if position('active_ortools_solver_version_v2()' in v_selection_guard)=0
    or position('run.solver_version' in v_selection_guard)=0
    or position('RUN_SOLVER_VERSION_NOT_ACTIVE' in v_selection_guard)=0 then
    raise exception 'ACTIVE_SELECTION_VERSION_FENCE_MISSING';
  end if;
  if position('active_ortools_solver_version_v2()' in v_link_guard)=0
    or position('run.solver_version' in v_link_guard)=0
    or position('RUN_SOLVER_VERSION_NOT_ACTIVE' in v_link_guard)=0 then
    raise exception 'ACTIVE_PUBLICATION_LINK_VERSION_FENCE_MISSING';
  end if;

  v_select:=replace(pg_get_functiondef(
    'public.optimizer_select_variant_v2(uuid,uuid)'::regprocedure
  ),' ','');
  v_company:=replace(pg_get_functiondef(
    'public.optimizer_publish_company_variant_v2(uuid,uuid,text,text)'::regprocedure
  ),' ','');
  v_composite:=replace(pg_get_functiondef(
    'public.optimizer_publish_role_composite_v2(date,uuid,uuid[],text,text)'::regprocedure
  ),' ','');
  v_candidates:=replace(pg_get_functiondef(
    'public.optimizer_role_composite_candidates_v2(date,uuid)'::regprocedure
  ),' ','');
  v_candidates_fallback:=replace(pg_get_functiondef(
    'public.optimizer_role_composite_candidates_before_publication_fallback(date,uuid)'::regprocedure
  ),' ','');
  v_candidates_delegate:=replace(pg_get_functiondef(
    'public.optimizer_role_composite_candidates_before_categories_uat_v1(date,uuid)'::regprocedure
  ),' ','');
  if position('active_ortools_solver_version_v2()' in v_select)=0
    or position('run.solver_version' in v_select)=0
    or position('v_active_solver_version' in v_select)=0 then
    raise exception 'SELECT_RPC_VERSION_FENCE_MISSING';
  end if;
  if position('active_ortools_solver_version_v2()' in v_company)=0
    or position('v_run_solver_version' in v_company)=0
    or position('v_active_solver_version' in v_company)=0 then
    raise exception 'COMPANY_PUBLICATION_VERSION_FENCE_MISSING';
  end if;
  if position('active_ortools_solver_version_v2()' in v_composite)=0
    or position('run.solver_version' in v_composite)=0
    or position('v_active_solver_version' in v_composite)=0 then
    raise exception 'ROLE_COMPOSITE_PUBLICATION_VERSION_FENCE_MISSING';
  end if;
  if position('optimizer_role_composite_candidates_before_publication_fallback_uat_v1' in v_candidates)=0
    or position('optimizer_role_composite_candidates_before_categories_uat_v1' in v_candidates_fallback)=0
    or position('active_ortools_solver_version_v2()' in v_candidates_delegate)=0
    or position('run.solver_version' in v_candidates_delegate)=0
    or position('v_active_solver_version' in v_candidates_delegate)=0 then
    raise exception 'ROLE_CANDIDATE_EXACT_VERSION_FILTER_MISSING';
  end if;

  v_employee:=replace(pg_get_functiondef(
    'public.optimizer_employee_published_schedule_v2(date)'::regprocedure
  ),' ','');
  if position(
    $needle$'locationTimezone',location.timezone$needle$ in v_employee
  )=0
    or position(
      'location.matrix_version_id=v_matrix_version_id' in v_employee
    )=0 then
    raise exception 'EMPLOYEE_LOCATION_TIMEZONE_MISSING';
  end if;
end;
$$;

rollback;
