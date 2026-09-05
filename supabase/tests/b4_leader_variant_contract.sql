-- Runtime contract for the editable leader copy introduced in B4.
-- Run after all migrations in a disposable or UAT transaction.

begin;

do $$
declare
  v_rpc text;
begin
  foreach v_rpc in array array[
    'public.optimizer_create_leader_variant_uat_v1(uuid,uuid,text)',
    'public.optimizer_leader_assignment_context_uat_v1(uuid,uuid,bigint)',
    'public.optimizer_leader_assignment_save_uat_v1(uuid,uuid,bigint,uuid,text)',
    'public.optimizer_leader_assignment_remove_uat_v1(uuid,uuid,text)',
    'public.optimizer_leader_variant_workspace_uat_v1(uuid)',
    'public.optimizer_leader_variant_for_run_uat_v1(uuid)',
    'public.optimizer_demand_profiles_uat_v1(date)'
  ] loop
    if not has_function_privilege('authenticated',v_rpc,'execute')
      or has_function_privilege('anon',v_rpc,'execute') then
      raise exception 'B4_LEADER_RPC_GRANT_INVALID:%',v_rpc;
    end if;
  end loop;

  if not exists(
    select 1 from information_schema.columns
    where table_schema='public' and table_name='plan_variants_v2'
      and column_name='variant_kind' and is_nullable='NO'
  ) or not exists(
    select 1 from information_schema.columns
    where table_schema='public' and table_name='plan_variants_v2'
      and column_name='source_variant_id'
  ) or not exists(
    select 1 from information_schema.columns
    where table_schema='public' and table_name='plan_variants_v2'
      and column_name='revision' and is_nullable='NO'
  ) then raise exception 'B4_LEADER_VARIANT_COLUMNS_MISSING'; end if;

  if not exists(
    select 1 from pg_indexes
    where schemaname='public'
      and indexname='plan_variants_generated_run_strategy_v2'
      and indexdef ilike '%unique%where (variant_kind = ''GENERATED''%'
  ) then raise exception 'B4_GENERATED_VARIANT_UNIQUENESS_MISSING'; end if;

  if position(
    'variant.variant_kind=''GENERATED''' in replace(pg_get_functiondef(
      'public.optimizer_variants_v2(uuid)'::regprocedure
    ),' ','')
  )=0 then raise exception 'B4_COMPARISON_EXPOSES_CUSTOM_COPY'; end if;

  if position(
    'solver_private.validate_variant_v2' in pg_get_functiondef(
      'solver_private.refresh_leader_variant_uat_v1(uuid,uuid,text)'::regprocedure
    )
  )=0 then raise exception 'B4_LEADER_EDIT_NOT_REVALIDATED'; end if;

  if has_function_privilege(
    'authenticated','solver_private.refresh_leader_variant_uat_v1(uuid,uuid,text)','execute'
  ) or has_function_privilege(
    'anon','solver_private.can_edit_leader_variant_uat_v1(uuid)','execute'
  ) then raise exception 'B4_PRIVATE_HELPER_EXPOSED'; end if;
end;
$$;

rollback;
-- Runtime contract for the editable leader copy introduced in B4.
-- Run after all migrations in a disposable or UAT transaction.

begin;

do $$
declare
  v_rpc text;
begin
  foreach v_rpc in array array[
    'public.optimizer_create_leader_variant_uat_v1(uuid,uuid)',
    'public.optimizer_leader_assignment_context_uat_v1(uuid,uuid,uuid)',
    'public.optimizer_leader_assignment_save_uat_v1(uuid,uuid,uuid,uuid,text)',
    'public.optimizer_leader_assignment_remove_uat_v1(uuid,uuid,text)',
    'public.optimizer_leader_variant_workspace_uat_v1(uuid)',
    'public.optimizer_leader_variant_for_run_uat_v1(uuid)',
    'public.optimizer_demand_profiles_uat_v1(uuid)'
  ] loop
    if not has_function_privilege('authenticated',v_rpc,'execute')
      or has_function_privilege('anon',v_rpc,'execute') then
      raise exception 'B4_LEADER_RPC_GRANT_INVALID:%',v_rpc;
    end if;
  end loop;

  if not exists(
    select 1 from information_schema.columns
    where table_schema='public' and table_name='plan_variants_v2'
      and column_name='variant_kind' and is_nullable='NO'
  ) or not exists(
    select 1 from information_schema.columns
    where table_schema='public' and table_name='plan_variants_v2'
      and column_name='source_variant_id'
  ) or not exists(
    select 1 from information_schema.columns
    where table_schema='public' and table_name='plan_variants_v2'
      and column_name='revision' and is_nullable='NO'
  ) then raise exception 'B4_LEADER_VARIANT_COLUMNS_MISSING'; end if;

  if not exists(
    select 1 from pg_indexes
    where schemaname='public'
      and indexname='plan_variants_v2_generated_run_strategy_unique'
      and indexdef ilike '%unique%where (variant_kind = ''GENERATED''%'
  ) then raise exception 'B4_GENERATED_VARIANT_UNIQUENESS_MISSING'; end if;

  if position(
    'variant.variant_kind=''GENERATED''' in replace(pg_get_functiondef(
      'public.optimizer_variants_v2(uuid)'::regprocedure
    ),' ','')
  )=0 then raise exception 'B4_COMPARISON_EXPOSES_CUSTOM_COPY'; end if;

  if position(
    'solver_private.validate_variant_v2' in pg_get_functiondef(
      'solver_private.refresh_leader_variant_uat_v1(uuid,uuid)'::regprocedure
    )
  )=0 then raise exception 'B4_LEADER_EDIT_NOT_REVALIDATED'; end if;

  if has_function_privilege(
    'authenticated','solver_private.refresh_leader_variant_uat_v1(uuid,uuid)','execute'
  ) or has_function_privilege(
    'anon','solver_private.can_edit_leader_variant_uat_v1(uuid)','execute'
  ) then raise exception 'B4_PRIVATE_HELPER_EXPOSED'; end if;
end;
$$;

rollback;
