-- Static contract checks for 20260801201439_optimizer_publication_v2.sql.
-- Run against a disposable/local database after migrations.

begin;

do $$
declare
  v_public_rpc text;
  v_private_rpc text;
begin
  if to_regclass('public.published_schedules_v2') is null
    or to_regclass('public.published_schedule_variants_v2') is null
    or to_regclass('solver_private.published_schedule_finance_v2') is null then
    raise exception 'PUBLICATION_V2_TABLES_MISSING';
  end if;

  if not exists(
    select 1 from pg_class c
    where c.oid='public.published_schedules_v2'::regclass and c.relrowsecurity
  ) or not exists(
    select 1 from pg_class c
    where c.oid='public.published_schedule_variants_v2'::regclass and c.relrowsecurity
  ) then raise exception 'PUBLICATION_V2_RLS_DISABLED'; end if;

  if has_table_privilege('anon','public.published_schedules_v2','select')
    or has_table_privilege('anon','public.published_schedule_variants_v2','select')
    or has_table_privilege('authenticated','public.published_schedules_v2','insert')
    or has_table_privilege('authenticated','public.published_schedules_v2','update')
    or has_table_privilege('authenticated','public.published_schedules_v2','delete')
    or has_table_privilege(
      'anon','solver_private.published_schedule_finance_v2','select'
    )
    or has_table_privilege(
      'authenticated','solver_private.published_schedule_finance_v2','select'
    ) then
    raise exception 'PUBLICATION_V2_TABLE_GRANTS_TOO_BROAD';
  end if;
  if not has_table_privilege(
    'authenticated','public.published_schedules_v2','select'
  ) then raise exception 'PUBLICATION_V2_AUTH_READ_GRANT_MISSING'; end if;

  foreach v_public_rpc in array array[
    'public.optimizer_selected_variant_workspace_v2(uuid)',
    'public.optimizer_select_variant_v2(uuid,uuid)',
    'public.optimizer_published_schedule_v2(uuid)',
    'public.optimizer_role_composite_candidates_v2(date,uuid)',
    'public.optimizer_publish_company_variant_alpha16(uuid,uuid,text,text,text)',
    'public.optimizer_publish_role_composite_v2(date,uuid,uuid[],text,text)'
  ] loop
    if not has_function_privilege('authenticated',v_public_rpc,'execute')
      or has_function_privilege('anon',v_public_rpc,'execute') then
      raise exception 'PUBLICATION_V2_PUBLIC_RPC_GRANT_INVALID:%',v_public_rpc;
    end if;
  end loop;

  foreach v_private_rpc in array array[
    'solver_private.publication_snapshot_basis_v2(jsonb)',
    'solver_private.publication_static_input_hash_v2(jsonb)',
    'solver_private.publication_snapshot_hash_v2(jsonb)',
    'solver_private.materialized_variant_payload_v2(uuid[],jsonb,uuid)',
    'solver_private.assert_materialized_variant_metadata_v2(uuid,jsonb)',
    'solver_private.revalidate_materialized_variant_v2(uuid,boolean)',
    'solver_private.revalidate_materialized_variant_v2(uuid,boolean,boolean)',
    'solver_private.requote_variant_payload_v2(jsonb,jsonb)',
    'solver_private.variant_set_workspace_v2(uuid[],jsonb,boolean)',
    'solver_private.archive_current_publication_v2(date,uuid[],uuid)'
    ,'solver_private.published_variant_is_frozen_v2(uuid)'
    ,'solver_private.guard_published_variant_row_v2()'
    ,'solver_private.guard_published_variant_direct_child_v2()'
    ,'solver_private.guard_published_variant_assignment_child_v2()'
    ,'solver_private.guard_publication_variant_link_v2()'
    ,'solver_private.guard_production_variant_link_v2()'
    ,'solver_private.guard_legacy_plan_publication_v2()'
    ,'solver_private.guard_run_provenance_v2()'
  ] loop
    if has_function_privilege('anon',v_private_rpc,'execute')
      or has_function_privilege('authenticated',v_private_rpc,'execute') then
      raise exception 'PUBLICATION_V2_PRIVATE_RPC_EXPOSED:%',v_private_rpc;
    end if;
  end loop;

  if exists(
    select 1
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where (
      n.nspname='public' and p.proname in (
        'optimizer_selected_variant_workspace_v2',
        'optimizer_select_variant_v2',
        'optimizer_published_schedule_v2',
        'optimizer_role_composite_candidates_v2',
        'optimizer_publish_company_variant_v2',
        'optimizer_publish_role_composite_v2'
      )
    ) and (
      not p.prosecdef
      or not exists(
        select 1 from unnest(coalesce(p.proconfig,'{}'::text[])) setting
        where setting like 'search_path=%'
      )
    )
  ) then raise exception 'PUBLICATION_V2_RPC_SECURITY_CONFIG_INVALID'; end if;

  if (
    select count(*)
    from pg_trigger t
    where not t.tgisinternal and t.tgname in (
      'plan_variants_v2_publication_freeze',
      'plan_shifts_v2_publication_freeze',
      'plan_assignments_v2_publication_freeze',
      'plan_issues_v2_publication_freeze',
      'plan_variant_finance_v2_publication_freeze',
      'plan_assignment_duties_v2_publication_freeze',
      'plan_assignment_cost_components_v2_publication_freeze',
      'published_schedule_variants_v2_link_freeze',
      'published_schedule_variants_v2_production_only'
    )
  )<>9 then raise exception 'PUBLICATION_V2_FREEZE_TRIGGERS_MISSING'; end if;

  if not exists(
    select 1 from pg_trigger trigger_row
    where not trigger_row.tgisinternal
      and trigger_row.tgname='optimization_runs_v2_provenance_immutable'
  ) or not exists(
    select 1 from pg_trigger trigger_row
    where not trigger_row.tgisinternal
      and trigger_row.tgname='plans_legacy_publication_cutover_guard'
  ) then raise exception 'SOLVER_PROVENANCE_GUARDS_MISSING'; end if;

  if not exists(
    select 1 from information_schema.columns column_row
    where column_row.table_schema='public'
      and column_row.table_name='optimization_runs_v2'
      and column_row.column_name='request_engine'
      and column_row.is_nullable='NO'
  ) then raise exception 'RUN_REQUEST_ENGINE_MISSING'; end if;
  if not exists(
    select 1 from information_schema.columns column_row
    where column_row.table_schema='public'
      and column_row.table_name='optimization_runs_v2'
      and column_row.column_name='solver_version'
      and column_row.is_nullable='NO'
  ) then raise exception 'RUN_SOLVER_VERSION_MISSING'; end if;
  if position(
    'request_engine,solver_version' in replace(pg_get_functiondef(
      'public.optimizer_request_v2(date,uuid,text,uuid,text,text)'::regprocedure
    ),' ','')
  )=0 or position(
    'SOLVER_VERSION_CONFIGURATION_REQUIRED' in pg_get_functiondef(
      'public.optimizer_request_v2(date,uuid,text,uuid,text,text)'::regprocedure
    )
  )=0 then raise exception 'RUN_PROVENANCE_NOT_CAPTURED'; end if;

  if not exists(
    select 1 from pg_indexes
    where schemaname='public'
      and indexname='published_schedules_v2_one_current_month'
      and indexdef ilike '%unique%where (status = ''PUBLISHED''%'
  ) then raise exception 'PUBLICATION_V2_ACTIVE_MONTH_GUARD_MISSING'; end if;

  if position(
    'ORTOOLS_SELECTION_DISABLED' in pg_get_functiondef(
      'public.optimizer_select_variant_v2(uuid,uuid)'::regprocedure
    )
  )=0 or position(
    'request_engine=''ORTOOLS_V2''' in replace(pg_get_functiondef(
      'public.optimizer_select_variant_v2(uuid,uuid)'::regprocedure
    ),' ','')
  )=0 then raise exception 'SHADOW_VARIANT_SELECTION_NOT_BLOCKED'; end if;
  if position(
    'request_engine=''ORTOOLS_V2''' in replace(pg_get_functiondef(
      'public.optimizer_role_composite_candidates_v2(date,uuid)'::regprocedure
    ),' ','')
  )=0 then raise exception 'SHADOW_ROLE_CANDIDATE_NOT_BLOCKED'; end if;
  if position(
    'ORTOOLS_PUBLICATION_DISABLED' in pg_get_functiondef(
      'public.optimizer_publish_company_variant_v2(uuid,uuid,text,text)'::regprocedure
    )
  )=0 or position(
    'ORTOOLS_PUBLICATION_DISABLED' in pg_get_functiondef(
      'public.optimizer_publish_role_composite_v2(date,uuid,uuid[],text,text)'::regprocedure
    )
  )=0 or position(
    'SHADOW_RUN_NOT_PUBLISHABLE' in pg_get_functiondef(
      'public.optimizer_publish_company_variant_v2(uuid,uuid,text,text)'::regprocedure
    )
  )=0 or position(
    'SHADOW_RUN_NOT_PUBLISHABLE' in pg_get_functiondef(
      'public.optimizer_publish_role_composite_v2(date,uuid,uuid[],text,text)'::regprocedure
    )
  )=0 then raise exception 'SHADOW_PUBLICATION_NOT_BLOCKED'; end if;
  if position(
    'LEGACY_PUBLICATION_DISABLED' in pg_get_functiondef(
      'solver_private.guard_legacy_plan_publication_v2()'::regprocedure
    )
  )=0 then raise exception 'LEGACY_PUBLICATION_CUTOVER_GUARD_MISSING'; end if;
end;
$$;

rollback;
