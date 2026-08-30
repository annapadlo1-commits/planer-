-- Phase 4A.2B neutral-baseline restore contract.
--
-- Run only after restoring the reviewed baseline into a fresh, isolated
-- Supabase instance. This contract is intentionally catalog/configuration
-- only: it never creates fixtures or projects PGMQ message payloads. It does
-- count the two disposable local queue tables to prove schema-only residue 0.

begin;
set transaction isolation level repeatable read, read only;
set local statement_timeout = '120s';
set local lock_timeout = '5s';

do $phase4a2b$
declare
  v_actual bigint;
  v_actual_two bigint;
  v_acl text[];
  v_bool boolean;
  v_force_rls boolean;
  v_definitions text;
  v_object text;
  v_owner text;
  v_persistence "char";
  v_kind "char";
  v_ledger_mode text;
  v_ledger_rows bigint;
  v_names text[];
  v_record record;
begin
  if current_setting('transaction_read_only') <> 'on' then
    raise exception 'PHASE4A2B_CONTRACT_NOT_READ_ONLY';
  end if;

  -- A direct restore has an empty ledger. The independent migration-path pass
  -- is allowed one, and only one, synthetic baseline row. The runner must
  -- select the expected mode explicitly; there is no permissive default.
  v_ledger_mode := current_setting('phase4a2b.expected_ledger_mode', true);
  if v_ledger_mode not in ('empty', 'synthetic-baseline')
    or v_ledger_mode is null
  then
    raise exception 'PHASE4A2B_EXPECTED_LEDGER_MODE_INVALID:%', v_ledger_mode;
  end if;
  if to_regclass('supabase_migrations.schema_migrations') is null then
    if v_ledger_mode <> 'empty' then
      raise exception 'PHASE4A2B_MIGRATION_LEDGER_MISSING';
    end if;
    v_ledger_rows := 0;
  else
    execute 'select count(*) from supabase_migrations.schema_migrations'
      into v_ledger_rows;
  end if;
  if v_ledger_mode = 'empty' and v_ledger_rows <> 0 then
    raise exception 'PHASE4A2B_DIRECT_LEDGER_CONTAMINATED:%', v_ledger_rows;
  elsif v_ledger_mode = 'synthetic-baseline' then
    execute $ledger$
      select count(*)
      from supabase_migrations.schema_migrations
      where version = '20260830000000'
        and name = 'phase4a2b_neutral_baseline'
    $ledger$ into v_actual;
    if v_ledger_rows <> 1 or v_actual <> 1 then
      raise exception 'PHASE4A2B_SYNTHETIC_LEDGER_INVALID:%/%',
        v_actual, v_ledger_rows;
    end if;
  end if;
  perform pg_catalog.set_config(
    'phase4a2b.actual_ledger_rows', v_ledger_rows::text, true
  );

  -- Canonical application schemas and types must resolve independently of
  -- search_path, and application-owned schemas remain owned by postgres.
  foreach v_object in array array[
    'authorization_private',
    'solver_private'
  ] loop
    select pg_get_userbyid(namespace_row.nspowner)
      into v_owner
    from pg_catalog.pg_namespace namespace_row
    where namespace_row.nspname = v_object;
    if v_owner is distinct from 'postgres' then
      raise exception 'PHASE4A2B_SCHEMA_OWNER_INVALID:%.%', v_object, v_owner;
    end if;
  end loop;

  select array_agg(namespace_row.nspname order by namespace_row.nspname collate "C")
    into v_names
  from pg_catalog.pg_namespace namespace_row
  where namespace_row.nspname !~ '^pg_'
    and namespace_row.nspname not in (
      'information_schema', '_realtime', 'auth', 'extensions', 'graphql', 'graphql_public',
      'net', 'pgbouncer', 'pgmq', 'realtime', 'storage',
      'supabase_functions', 'supabase_migrations', 'vault'
    );
  if v_names is distinct from array[
    'authorization_private', 'cron', 'public', 'solver_private'
  ]::text[] then
    raise exception 'PHASE4A2B_USER_SCHEMA_SET_INVALID:%', v_names;
  end if;

  for v_record in
    select * from (values
      (
        'authorization_private'::text,
        'postgres'::text,
        array['postgres=UC/postgres']::text[]
      ),
      (
        'cron',
        'supabase_admin',
        array[
          'postgres=U*/supabase_admin',
          'supabase_admin=UC/supabase_admin'
        ]::text[]
      ),
      (
        'public',
        'pg_database_owner',
        array[
          '=U/pg_database_owner',
          'anon=U/pg_database_owner',
          'authenticated=U/pg_database_owner',
          'pg_database_owner=UC/pg_database_owner',
          'postgres=U/pg_database_owner',
          'service_role=U/pg_database_owner'
        ]::text[]
      ),
      (
        'solver_private',
        'postgres',
        array[
          'postgres=UC/postgres',
          'service_role=U/postgres'
        ]::text[]
      )
    ) expected(schema_name, owner_name, acl_items)
  loop
    select
      pg_get_userbyid(namespace_row.nspowner),
      array(
        select acl_item::text
        from unnest(coalesce(namespace_row.nspacl, array[]::aclitem[])) acl_item
        order by acl_item::text collate "C"
      )
      into v_owner, v_acl
    from pg_catalog.pg_namespace namespace_row
    where namespace_row.nspname = v_record.schema_name;
    if not found
      or v_owner is distinct from v_record.owner_name
      or v_acl is distinct from v_record.acl_items
    then
      raise exception 'PHASE4A2B_USER_SCHEMA_IDENTITY_INVALID:%',
        v_record.schema_name;
    end if;
  end loop;

  foreach v_object in array array[
    'public.app_role',
    'public.attendance_event_type',
    'public.employee_role',
    'public.event_status',
    'public.location_code',
    'public.plan_status',
    'public.task_status'
  ] loop
    if to_regtype(v_object) is null then
      raise exception 'PHASE4A2B_CANONICAL_TYPE_MISSING:%', v_object;
    end if;
  end loop;

  foreach v_object in array array[
    'public.assignments',
    'public.audit_log',
    'public.employees',
    'public.matrix_employee_locations_v2',
    'public.matrix_employee_profiles_v2',
    'public.matrix_employee_roles_v2',
    'public.matrix_scope_grants_v2',
    'public.matrix_versions',
    'public.operational_events',
    'public.optimization_run_strategies_v2',
    'public.optimization_runs_v2',
    'public.plan_issues',
    'public.plan_variants_v2',
    'public.published_schedules_v2',
    'public.uat_environment_controls',
    'solver_private.solver_job_dispatch_outbox_uat_v1',
    'solver_private.solver_job_runtime_config_uat_v1'
  ] loop
    if to_regclass(v_object) is null then
      raise exception 'PHASE4A2B_CANONICAL_RELATION_MISSING:%', v_object;
    end if;
  end loop;

  foreach v_object in array array[
    'public.current_user_access()',
    'public.matrix_v2_admin_save(text,uuid,jsonb)',
    'public.matrix_v2_can_manage_legacy_assignment_uat_v1(uuid)',
    'public.matrix_v2_can_manage_legacy_plan_issue_uat_v1(uuid)',
    'public.matrix_v2_can_manage_legacy_resource_uat_v1(text,uuid,uuid)',
    'public.matrix_v2_workspace(date)',
    'public.uat_full_business_reset_preview_v1()',
    'public.uat_full_business_reset_v1(text)',
    'solver_private.guard_matrix_child_immutable_v2()',
    'solver_private.guard_matrix_version_immutable_v2()',
    'solver_private.matrix_v2_create_safe_first_run_uat_v1(uuid)'
  ] loop
    if to_regprocedure(v_object) is null then
      raise exception 'PHASE4A2B_CANONICAL_ROUTINE_MISSING:%', v_object;
    end if;
  end loop;

  -- Exact application catalog shape from the reviewed schema-only capture.
  select count(*), count(*) filter (where table_row.relrowsecurity)
    into v_actual, v_actual_two
  from pg_catalog.pg_class table_row
  join pg_catalog.pg_namespace namespace_row
    on namespace_row.oid = table_row.relnamespace
  where namespace_row.nspname = 'public'
    and table_row.relkind in ('r', 'p');
  if v_actual <> 113 or v_actual_two <> 113 then
    raise exception 'PHASE4A2B_PUBLIC_TABLE_RLS_SHAPE_INVALID:%/%',
      v_actual_two, v_actual;
  end if;

  select count(*), count(*) filter (where table_row.relrowsecurity)
    into v_actual, v_actual_two
  from pg_catalog.pg_class table_row
  join pg_catalog.pg_namespace namespace_row
    on namespace_row.oid = table_row.relnamespace
  where namespace_row.nspname = 'solver_private'
    and table_row.relkind in ('r', 'p');
  if v_actual <> 12 or v_actual_two <> 3 then
    raise exception 'PHASE4A2B_PRIVATE_TABLE_RLS_SHAPE_INVALID:%/%',
      v_actual_two, v_actual;
  end if;

  select count(*) into v_actual
  from pg_catalog.pg_policies policy_row
  where policy_row.schemaname = 'public';
  if v_actual <> 129 then
    raise exception 'PHASE4A2B_PUBLIC_POLICY_COUNT_INVALID:%', v_actual;
  end if;

  select count(*), count(*) filter (where procedure_row.prosecdef)
    into v_actual, v_actual_two
  from pg_catalog.pg_proc procedure_row
  join pg_catalog.pg_namespace namespace_row
    on namespace_row.oid = procedure_row.pronamespace
  where namespace_row.nspname in (
    'authorization_private', 'public', 'solver_private'
  ) and procedure_row.prokind = 'f';
  if v_actual <> 547 or v_actual_two <> 519 then
    raise exception 'PHASE4A2B_ROUTINE_SHAPE_INVALID:%/%',
      v_actual_two, v_actual;
  end if;

  if exists(
    select 1
    from pg_catalog.pg_proc procedure_row
    join pg_catalog.pg_namespace namespace_row
      on namespace_row.oid = procedure_row.pronamespace
    where namespace_row.nspname in (
      'authorization_private', 'public', 'solver_private'
    )
      and procedure_row.prokind = 'f'
      and pg_get_userbyid(procedure_row.proowner) <> 'postgres'
  ) then
    raise exception 'PHASE4A2B_APPLICATION_ROUTINE_OWNER_INVALID';
  end if;

  -- Every captured SECURITY DEFINER routine has exactly one explicit
  -- search_path, and the complete reviewed UAT distribution is pinned. This
  -- permits the reviewed legacy paths without accepting arbitrary drift.
  if exists(
    select 1
    from pg_catalog.pg_proc procedure_row
    join pg_catalog.pg_namespace namespace_row
      on namespace_row.oid = procedure_row.pronamespace
    where namespace_row.nspname in (
      'authorization_private', 'public', 'solver_private'
    )
      and procedure_row.prosecdef
      and (
        select count(*)
        from unnest(coalesce(procedure_row.proconfig, array[]::text[])) setting(value)
        where setting.value like 'search_path=%'
      ) <> 1
  ) then
    raise exception 'PHASE4A2B_SECURITY_DEFINER_SEARCH_PATH_MISSING';
  end if;

  for v_record in
    select * from (values
      ('search_path=""'::text, 458::bigint),
      ('search_path=public', 55),
      ('search_path=public, pg_temp', 5),
      ('search_path=public, solver_private, pg_temp', 1)
    ) expected(search_path_setting, routine_count)
  loop
    select count(*) into v_actual
    from pg_catalog.pg_proc procedure_row
    join pg_catalog.pg_namespace namespace_row
      on namespace_row.oid = procedure_row.pronamespace
    cross join lateral unnest(procedure_row.proconfig) setting(value)
    where namespace_row.nspname in (
      'authorization_private', 'public', 'solver_private'
    )
      and procedure_row.prokind = 'f'
      and procedure_row.prosecdef
      and setting.value = v_record.search_path_setting;
    if v_actual <> v_record.routine_count then
      raise exception 'PHASE4A2B_SECURITY_DEFINER_SEARCH_PATH_DRIFT:%:%/%',
        v_record.search_path_setting, v_actual, v_record.routine_count;
    end if;
  end loop;

  select string_agg(
    format(
      '%I.%I(%s)',
      namespace_row.nspname,
      procedure_row.proname,
      pg_get_function_identity_arguments(procedure_row.oid)
    ),
    ',' order by procedure_row.oid
  ) into v_definitions
    from pg_catalog.pg_proc procedure_row
    join pg_catalog.pg_namespace namespace_row
      on namespace_row.oid = procedure_row.pronamespace
    where namespace_row.nspname = 'public'
      and procedure_row.prosecdef
      and has_function_privilege('anon', procedure_row.oid, 'execute');
  if v_definitions is not null then
    raise exception 'PHASE4A2B_ANON_SECURITY_DEFINER_EXECUTE_LEAK:%',
      v_definitions;
  end if;

  if has_schema_privilege('anon', 'authorization_private', 'usage')
    or has_schema_privilege('authenticated', 'authorization_private', 'usage')
    or has_schema_privilege('anon', 'solver_private', 'usage')
    or has_schema_privilege('authenticated', 'solver_private', 'usage')
    or not has_schema_privilege('service_role', 'solver_private', 'usage')
  then
    raise exception 'PHASE4A2B_PRIVATE_SCHEMA_ACL_INVALID';
  end if;

  if not has_function_privilege(
      'authenticated', 'public.current_user_access()', 'execute')
    or not has_function_privilege(
      'authenticated', 'public.matrix_v2_workspace(date)', 'execute')
    or not has_function_privilege(
      'authenticated', 'public.matrix_v2_admin_save(text,uuid,jsonb)', 'execute')
  then
    raise exception 'PHASE4A2B_AUTHENTICATED_APPLICATION_RPC_MISSING';
  end if;

  foreach v_object in array array[
    'public.matrix_v2_can_manage_legacy_assignment_uat_v1(uuid)',
    'public.matrix_v2_can_manage_legacy_plan_issue_uat_v1(uuid)',
    'public.matrix_v2_can_manage_legacy_resource_uat_v1(text,uuid,uuid)'
  ] loop
    if has_function_privilege('anon', v_object, 'execute')
      or has_function_privilege('service_role', v_object, 'execute')
      or not has_function_privilege('authenticated', v_object, 'execute')
    then
      raise exception 'PHASE4A2B_SCOPED_HELPER_ACL_INVALID:%', v_object;
    end if;
  end loop;

  if has_table_privilege('anon', 'public.audit_log', 'select')
    or has_table_privilege('anon', 'public.audit_log', 'insert')
    or has_table_privilege('authenticated', 'public.audit_log', 'select')
    or has_table_privilege('authenticated', 'public.audit_log', 'insert')
    or not has_table_privilege('service_role', 'public.audit_log', 'select')
    or not has_table_privilege('service_role', 'public.audit_log', 'insert')
  then
    raise exception 'PHASE4A2B_AUDIT_LOG_ACL_INVALID';
  end if;

  -- Canonical Phase 4A.1 policies, including the explicitly deferred global
  -- legacy-event SELECT decision, must survive the baseline conversion.
  foreach v_object in array array[
    'assignments.employee_reads_own_assignments',
    'matrix_scope_grants_v2.matrix_scope_grants_v2_read',
    'matrix_scope_grants_v2.matrix_scope_grants_v2_write',
    'operational_events.authenticated_reads_events',
    'operational_events.managers_manage_events',
    'plan_issues.plan_issues_read'
  ] loop
    if not exists(
      select 1
      from pg_catalog.pg_policies policy_row
      where policy_row.schemaname = 'public'
        and policy_row.tablename = split_part(v_object, '.', 1)
        and policy_row.policyname = split_part(v_object, '.', 2)
        and policy_row.roles = array['authenticated']::name[]
    ) then
      raise exception 'PHASE4A2B_CANONICAL_POLICY_INVALID:%', v_object;
    end if;
  end loop;

  if not exists(
      select 1
      from pg_catalog.pg_trigger trigger_row
      where trigger_row.tgrelid = 'public.matrix_versions'::regclass
        and trigger_row.tgname = 'zz_matrix_version_immutable_v2'
        and not trigger_row.tgisinternal
    )
    or not exists(
      select 1
      from pg_catalog.pg_trigger trigger_row
      where trigger_row.tgrelid = 'public.matrix_roles_v2'::regclass
        and trigger_row.tgname = 'matrix_v2_immutable_guard'
        and not trigger_row.tgisinternal
    )
  then
    raise exception 'PHASE4A2B_MATRIX_IMMUTABILITY_TRIGGER_MISSING';
  end if;

  -- Environment-bound routines are rendered only with the dedicated local
  -- restore identity. Source-level scanning separately proves that no live
  -- project ref occurs anywhere in the candidate.
  select string_agg(
      pg_get_functiondef(procedure_row.oid), E'\n'
      order by namespace_row.nspname, procedure_row.proname
    )
    into v_definitions
  from pg_catalog.pg_proc procedure_row
  join pg_catalog.pg_namespace namespace_row
    on namespace_row.oid = procedure_row.pronamespace
  where (namespace_row.nspname, procedure_row.proname) in (
    ('public', 'uat_full_business_reset_preview_v1'),
    ('public', 'uat_full_business_reset_v1'),
    ('solver_private', 'matrix_v2_create_safe_first_run_uat_v1')
  );
  if regexp_count(v_definitions, 'localphasegateabcdef') <> 5
    or v_definitions like '%__PHASE4A2B_PROJECT_REF__%'
  then
    raise exception 'PHASE4A2B_ENVIRONMENT_IDENTITY_NOT_NEUTRAL';
  end if;

  select count(*) into v_actual from public.uat_environment_controls;
  if v_actual <> 0 then
    raise exception 'PHASE4A2B_ENVIRONMENT_CONTROL_DATA_LEAK:%', v_actual;
  end if;

  -- The three postgres/public default-ACL records are application-owned
  -- capture state: 3 function grants, 4 table grants and 4 sequence grants.
  -- Managed supabase_admin default ACLs are supplied by platform bootstrap;
  -- the baseline deliberately neither replays nor rewrites them.
  select
    count(*),
    array_agg(
      format(
        '%s:%s:%s',
        coalesce(namespace_row.nspname, '<global>'),
        pg_get_userbyid(default_acl.defaclrole),
        default_acl.defaclobjtype::text
      )
      order by
        coalesce(namespace_row.nspname, '') collate "C",
        pg_get_userbyid(default_acl.defaclrole) collate "C",
        default_acl.defaclobjtype::text collate "C"
    )
    into v_actual, v_names
  from pg_catalog.pg_default_acl default_acl
  left join pg_catalog.pg_namespace namespace_row
    on namespace_row.oid = default_acl.defaclnamespace;
  if v_actual <> 29 then
    raise exception 'PHASE4A2B_DEFAULT_ACL_TOTAL_COUNT_INVALID:%:%',
      v_actual, v_names;
  end if;

  select string_agg(
      format(
        '%s|%s|%s|%s',
        acl_record.schema_name,
        acl_record.grantor_name,
        acl_record.object_type,
        acl_record.acl_items
      ),
      E'\n'
      order by
        acl_record.schema_name collate "C",
        acl_record.grantor_name collate "C",
        acl_record.object_type collate "C"
    )
    into v_definitions
  from (
    select
      coalesce(namespace_row.nspname, '') as schema_name,
      pg_get_userbyid(default_acl.defaclrole) as grantor_name,
      default_acl.defaclobjtype::text as object_type,
      coalesce((
        select string_agg(
          acl_item::text, ',' order by acl_item::text collate "C"
        )
        from unnest(default_acl.defaclacl) acl_item
      ), '') as acl_items
    from pg_catalog.pg_default_acl default_acl
    left join pg_catalog.pg_namespace namespace_row
      on namespace_row.oid = default_acl.defaclnamespace
  ) acl_record;
  if octet_length(v_definitions) <> 3005
    or encode(
      pg_catalog.sha256(pg_catalog.convert_to(v_definitions, 'UTF8')), 'hex'
    ) <> 'c86785623e746bdaf24fabcb75b2a6019385b230830284d851ec27ad030933a3'
  then
    raise exception 'PHASE4A2B_DEFAULT_ACL_FINGERPRINT_INVALID';
  end if;

  select count(*) into v_actual
  from pg_catalog.pg_default_acl default_acl
  join pg_catalog.pg_namespace namespace_row
    on namespace_row.oid = default_acl.defaclnamespace
  where pg_get_userbyid(default_acl.defaclrole) = 'postgres'
    and namespace_row.nspname = 'public'
    and default_acl.defaclobjtype::text in ('f', 'r', 'S');
  if v_actual <> 3 then
    raise exception 'PHASE4A2B_APP_DEFAULT_ACL_RECORD_COUNT_INVALID:%', v_actual;
  end if;

  select count(*) into v_actual
  from pg_catalog.pg_default_acl default_acl
  join pg_catalog.pg_namespace namespace_row
    on namespace_row.oid = default_acl.defaclnamespace
  cross join lateral unnest(default_acl.defaclacl) acl_item
  where pg_get_userbyid(default_acl.defaclrole) = 'postgres'
    and namespace_row.nspname = 'public'
    and default_acl.defaclobjtype::text in ('f', 'r', 'S');
  if v_actual <> 11 then
    raise exception 'PHASE4A2B_APP_DEFAULT_ACL_GRANT_COUNT_INVALID:%', v_actual;
  end if;

  for v_record in
    select * from (values
      ('f'::text, 'authenticated=X/postgres'::text),
      ('f', 'postgres=X/postgres'),
      ('f', 'service_role=X/postgres'),
      ('r', 'anon=arwdDxtm/postgres'),
      ('r', 'authenticated=arwdDxtm/postgres'),
      ('r', 'postgres=arwdDxtm/postgres'),
      ('r', 'service_role=arwdDxtm/postgres'),
      ('S', 'anon=rwU/postgres'),
      ('S', 'authenticated=rwU/postgres'),
      ('S', 'postgres=rwU/postgres'),
      ('S', 'service_role=rwU/postgres')
    ) expected(object_type, acl_text)
  loop
    if not exists(
      select 1
      from pg_catalog.pg_default_acl default_acl
      join pg_catalog.pg_namespace namespace_row
        on namespace_row.oid = default_acl.defaclnamespace
      cross join lateral unnest(default_acl.defaclacl) acl_item
      where pg_get_userbyid(default_acl.defaclrole) = 'postgres'
        and namespace_row.nspname = 'public'
        and default_acl.defaclobjtype::text = v_record.object_type
        and acl_item::text = v_record.acl_text
    ) then
      raise exception 'PHASE4A2B_APP_DEFAULT_ACL_GRANT_MISSING:%:%',
        v_record.object_type, v_record.acl_text;
    end if;
  end loop;

  -- Platform/extension ACL sections are observe-only. The canonical catalog
  -- fingerprint below was captured by a supplemental SELECT-only UAT query;
  -- it covers the two managed schemas plus every explicit routine/relation
  -- ACL in cron, extensions and vault. No ACL is rewritten by this baseline.
  select
    count(*),
    string_agg(
      format(
        '%s|%s|%s|%s|%s|%s',
        acl_record.object_kind,
        acl_record.schema_name,
        acl_record.object_identity,
        acl_record.object_subkind,
        acl_record.owner_name,
        acl_record.acl_items
      ),
      E'\n'
      order by
        acl_record.object_kind collate "C",
        acl_record.schema_name collate "C",
        acl_record.object_identity collate "C",
        acl_record.object_subkind collate "C",
        acl_record.owner_name collate "C",
        acl_record.acl_items collate "C"
    )
    into v_actual, v_definitions
  from (
    select
      'schema'::text as object_kind,
      namespace_row.nspname as schema_name,
      namespace_row.nspname as object_identity,
      ''::text as object_subkind,
      pg_get_userbyid(namespace_row.nspowner) as owner_name,
      coalesce((
        select string_agg(
          acl_item::text, ',' order by acl_item::text collate "C"
        )
        from unnest(namespace_row.nspacl) acl_item
      ), '') as acl_items
    from pg_catalog.pg_namespace namespace_row
    where namespace_row.nspname in ('cron', 'public')
      and namespace_row.nspacl is not null

    union all

    select
      'function',
      namespace_row.nspname,
      format(
        '%I.%I(%s)',
        namespace_row.nspname,
        procedure_row.proname,
        pg_get_function_identity_arguments(procedure_row.oid)
      ),
      procedure_row.prokind::text,
      pg_get_userbyid(procedure_row.proowner),
      coalesce((
        select string_agg(
          acl_item::text, ',' order by acl_item::text collate "C"
        )
        from unnest(procedure_row.proacl) acl_item
      ), '')
    from pg_catalog.pg_proc procedure_row
    join pg_catalog.pg_namespace namespace_row
      on namespace_row.oid = procedure_row.pronamespace
    where namespace_row.nspname in ('cron', 'extensions', 'vault')
      and procedure_row.proacl is not null

    union all

    select
      'relation',
      namespace_row.nspname,
      format('%I.%I', namespace_row.nspname, relation_row.relname),
      relation_row.relkind::text,
      pg_get_userbyid(relation_row.relowner),
      coalesce((
        select string_agg(
          acl_item::text, ',' order by acl_item::text collate "C"
        )
        from unnest(relation_row.relacl) acl_item
      ), '')
    from pg_catalog.pg_class relation_row
    join pg_catalog.pg_namespace namespace_row
      on namespace_row.oid = relation_row.relnamespace
    where namespace_row.nspname in ('cron', 'extensions', 'vault')
      and relation_row.relacl is not null
  ) acl_record;
  if v_actual <> 75
    or octet_length(v_definitions) <> 10311
    or encode(
      pg_catalog.sha256(pg_catalog.convert_to(v_definitions, 'UTF8')), 'hex'
    ) <> 'c3278105b5071f36da447bb3dd365f2602e3346ffa5eb9560e96bdd9bd9f2ffc'
  then
    raise exception 'PHASE4A2B_MANAGED_ACL_CATALOG_INVALID:%', v_actual;
  end if;

  -- Exact captured extension identity. Other platform extensions are not
  -- permitted: the source companion attestation contains exactly seven.
  select count(*) into v_actual from pg_catalog.pg_extension;
  if v_actual <> 7 then
    raise exception 'PHASE4A2B_EXTENSION_SET_COUNT_INVALID:%', v_actual;
  end if;
  for v_record in
    select * from (values
      ('pg_cron'::text, '1.6.4'::text, 'pg_catalog'::text, false),
      ('pg_stat_statements', '1.11', 'extensions', true),
      ('pgcrypto', '1.3', 'extensions', true),
      ('pgmq', '1.5.1', 'pgmq', false),
      ('plpgsql', '1.0', 'pg_catalog', false),
      ('supabase_vault', '0.3.1', 'vault', false),
      ('uuid-ossp', '1.1', 'extensions', true)
    ) expected(
      extension_name, extension_version, schema_name, is_relocatable
    )
  loop
    if not exists(
      select 1
      from pg_catalog.pg_extension extension_row
      join pg_catalog.pg_namespace namespace_row
        on namespace_row.oid = extension_row.extnamespace
      where extension_row.extname = v_record.extension_name
        and extension_row.extversion = v_record.extension_version
        and namespace_row.nspname = v_record.schema_name
        and extension_row.extrelocatable = v_record.is_relocatable
    ) then
      raise exception 'PHASE4A2B_EXTENSION_IDENTITY_INVALID:%',
        v_record.extension_name;
    end if;
  end loop;

  -- Storage configuration and policy metadata only; no storage object rows
  -- are selected.
  select count(*) into v_actual from storage.buckets;
  if v_actual <> 1 then
    raise exception 'PHASE4A2B_STORAGE_BUCKET_SET_INVALID:%', v_actual;
  end if;
  select count(*) into v_actual
  from storage.buckets bucket_row
  where bucket_row.id = 'profile-avatars'
    and bucket_row.name = 'profile-avatars'
    and not bucket_row.public
    and bucket_row.file_size_limit = 5242880
    and bucket_row.allowed_mime_types =
      array['image/jpeg', 'image/png', 'image/webp']::text[]
    and not bucket_row.avif_autodetection
    and bucket_row.type::text = 'STANDARD'
    and bucket_row.versioning_status::text = 'DISABLED';
  if v_actual <> 1 then
    raise exception 'PHASE4A2B_STORAGE_BUCKET_INVALID';
  end if;

  if not (
    select table_row.relrowsecurity and not table_row.relforcerowsecurity
    from pg_catalog.pg_class table_row
    where table_row.oid = 'storage.objects'::regclass
  ) then
    raise exception 'PHASE4A2B_STORAGE_OBJECTS_RLS_POSTURE_INVALID';
  end if;

  select array_agg(policy_row.policyname order by policy_row.policyname)
    into v_names
  from pg_catalog.pg_policies policy_row
  where policy_row.schemaname = 'storage'
    and policy_row.tablename = 'objects';
  if v_names is distinct from array[
    'profile_avatars_self_delete_v1',
    'profile_avatars_self_insert_v1',
    'profile_avatars_self_select_v1',
    'profile_avatars_self_update_v1'
  ]::text[] then
    raise exception 'PHASE4A2B_STORAGE_POLICY_SET_INVALID:%', v_names;
  end if;
  select count(*), count(distinct (policy_row.schemaname, policy_row.tablename))
    into v_actual, v_actual_two
  from pg_catalog.pg_policies policy_row
  where policy_row.schemaname in ('auth', 'storage', 'realtime');
  if v_actual <> 4 or v_actual_two <> 1 then
    raise exception 'PHASE4A2B_MANAGED_POLICY_SHAPE_INVALID:%/%',
      v_actual, v_actual_two;
  end if;
  if exists(
    select 1
    from pg_catalog.pg_policies policy_row
    where policy_row.schemaname = 'storage'
      and policy_row.tablename = 'objects'
      and policy_row.policyname = any(array[
        'profile_avatars_self_delete_v1',
        'profile_avatars_self_insert_v1',
        'profile_avatars_self_select_v1',
        'profile_avatars_self_update_v1'
      ])
      and policy_row.roles <> array['authenticated']::name[]
  ) then
    raise exception 'PHASE4A2B_STORAGE_POLICY_ROLE_INVALID';
  end if;

  for v_record in
    select * from (values
      (
        'profile_avatars_self_delete_v1'::text,
        'DELETE'::text,
        '((bucket_id = ''profile-avatars''::text) AND ((storage.foldername(name))[1] = (( SELECT auth.uid() AS uid))::text))'::text,
        null::text
      ),
      (
        'profile_avatars_self_insert_v1',
        'INSERT',
        null,
        '((bucket_id = ''profile-avatars''::text) AND ((storage.foldername(name))[1] = (( SELECT auth.uid() AS uid))::text))'
      ),
      (
        'profile_avatars_self_select_v1',
        'SELECT',
        '((bucket_id = ''profile-avatars''::text) AND ((storage.foldername(name))[1] = (( SELECT auth.uid() AS uid))::text))',
        null
      ),
      (
        'profile_avatars_self_update_v1',
        'UPDATE',
        '((bucket_id = ''profile-avatars''::text) AND ((storage.foldername(name))[1] = (( SELECT auth.uid() AS uid))::text))',
        '((bucket_id = ''profile-avatars''::text) AND ((storage.foldername(name))[1] = (( SELECT auth.uid() AS uid))::text))'
      )
    ) expected(policy_name, command_name, using_expression, check_expression)
  loop
    if not exists(
      select 1
      from pg_catalog.pg_policies policy_row
      where policy_row.schemaname = 'storage'
        and policy_row.tablename = 'objects'
        and policy_row.policyname = v_record.policy_name
        and policy_row.permissive = 'PERMISSIVE'
        and policy_row.roles = array['authenticated']::name[]
        and policy_row.cmd = v_record.command_name
        and policy_row.qual is not distinct from v_record.using_expression
        and policy_row.with_check is not distinct from v_record.check_expression
    ) then
      raise exception 'PHASE4A2B_STORAGE_POLICY_DEFINITION_INVALID:%',
        v_record.policy_name;
    end if;
  end loop;

  select array_agg(publication_row.pubname order by publication_row.pubname collate "C")
    into v_names
  from pg_catalog.pg_publication publication_row;
  if v_names is distinct from array['supabase_realtime']::text[] then
    raise exception 'PHASE4A2B_PUBLICATION_SET_INVALID:%', v_names;
  end if;

  if not exists(
    select 1
    from pg_catalog.pg_publication publication_row
    where publication_row.pubname = 'supabase_realtime'
      and pg_get_userbyid(publication_row.pubowner) = 'postgres'
      and not publication_row.puballtables
      and publication_row.pubinsert
      and publication_row.pubupdate
      and publication_row.pubdelete
      and publication_row.pubtruncate
      and not publication_row.pubviaroot
  ) then
    raise exception 'PHASE4A2B_REALTIME_PUBLICATION_FLAGS_INVALID';
  end if;

  select array_agg(
      format('%I.%I', publication_table.schemaname, publication_table.tablename)
      order by publication_table.schemaname, publication_table.tablename
    )
    into v_names
  from pg_catalog.pg_publication_tables publication_table
  where publication_table.pubname = 'supabase_realtime';
  if v_names is distinct from array[
    'public.optimization_run_strategies_v2',
    'public.optimization_runs_v2'
  ]::text[] then
    raise exception 'PHASE4A2B_REALTIME_PUBLICATION_INVALID:%', v_names;
  end if;
  if exists(
    select 1
    from pg_catalog.pg_publication_rel publication_relation
    join pg_catalog.pg_publication publication_row
      on publication_row.oid = publication_relation.prpubid
    where publication_row.pubname = 'supabase_realtime'
      and (
        publication_relation.prattrs is not null
        or publication_relation.prqual is not null
      )
  ) then
    raise exception 'PHASE4A2B_REALTIME_MEMBER_FILTER_INVALID';
  end if;
  if exists(
    select 1
    from pg_catalog.pg_publication_namespace publication_schema
    join pg_catalog.pg_publication publication_row
      on publication_row.oid = publication_schema.pnpubid
    where publication_row.pubname = 'supabase_realtime'
  ) then
    raise exception 'PHASE4A2B_REALTIME_SCHEMA_MEMBERSHIP_INVALID';
  end if;

  -- The application cron command was deliberately excluded from the private
  -- capture. Its metadata must remain absent until a separately authorized
  -- companion step; command text is never selected here.
  if to_regclass('cron.job') is null then
    raise exception 'PHASE4A2B_CRON_CATALOG_MISSING';
  end if;
  select count(*) into v_actual from cron.job;
  if v_actual <> 0 then
    raise exception 'PHASE4A2B_DEFERRED_CRON_JOB_REPLAYED:%', v_actual;
  end if;

  -- Platform-owned event triggers are observed, not replayed by the baseline.
  select array_agg(trigger_row.evtname order by trigger_row.evtname)
    into v_names
  from pg_catalog.pg_event_trigger trigger_row;
  if v_names is distinct from array[
    'issue_graphql_placeholder',
    'issue_pg_cron_access',
    'issue_pg_graphql_access',
    'issue_pg_net_access',
    'pgrst_ddl_watch',
    'pgrst_drop_watch'
  ]::text[] then
    raise exception 'PHASE4A2B_PLATFORM_EVENT_TRIGGER_SET_INVALID:%', v_names;
  end if;
  for v_record in
    select * from (values
      (
        'issue_graphql_placeholder'::text,
        'sql_drop'::text,
        array['DROP EXTENSION']::text[],
        'extensions'::text,
        'set_graphql_placeholder'::text
      ),
      (
        'issue_pg_cron_access', 'ddl_command_end',
        array['CREATE EXTENSION']::text[], 'extensions',
        'grant_pg_cron_access'
      ),
      (
        'issue_pg_graphql_access', 'ddl_command_end',
        array['CREATE EXTENSION']::text[], 'extensions',
        'grant_pg_graphql_access'
      ),
      (
        'issue_pg_net_access', 'ddl_command_end',
        array['CREATE EXTENSION']::text[], 'extensions',
        'grant_pg_net_access'
      ),
      (
        'pgrst_ddl_watch', 'ddl_command_end', null::text[],
        'extensions', 'pgrst_ddl_watch'
      ),
      (
        'pgrst_drop_watch', 'sql_drop', null::text[],
        'extensions', 'pgrst_drop_watch'
      )
    ) expected(
      trigger_name, event_name, tags, function_schema, function_name
    )
  loop
    if not exists(
      select 1
      from pg_catalog.pg_event_trigger trigger_row
      join pg_catalog.pg_proc procedure_row
        on procedure_row.oid = trigger_row.evtfoid
      join pg_catalog.pg_namespace namespace_row
        on namespace_row.oid = procedure_row.pronamespace
      where trigger_row.evtname = v_record.trigger_name
        and trigger_row.evtevent = v_record.event_name
        and trigger_row.evtenabled = 'O'
        and pg_get_userbyid(trigger_row.evtowner) = 'supabase_admin'
        and trigger_row.evttags is not distinct from v_record.tags
        and namespace_row.nspname = v_record.function_schema
        and procedure_row.proname = v_record.function_name
        and pg_get_function_identity_arguments(procedure_row.oid) = ''
    ) then
      raise exception 'PHASE4A2B_PLATFORM_EVENT_TRIGGER_IDENTITY_INVALID:%',
        v_record.trigger_name;
    end if;
  end loop;

  -- PGMQ queue metadata is compared with the read-only UAT inventory. This
  -- calls list_queues(), inspects catalogs, and later requires zero rows in
  -- the two exact disposable local q_/a_ tables without projecting payloads.
  select count(*), count(*) filter (
      where queue_row.queue_name = 'schedule_optimizer_v2'
        and not queue_row.is_partitioned
        and not queue_row.is_unlogged
    )
    into v_actual, v_actual_two
  from pgmq.list_queues() queue_row;
  if v_actual <> 1 or v_actual_two <> 1 then
    raise exception 'PHASE4A2B_PGMQ_QUEUE_METADATA_INVALID:%/%',
      v_actual_two, v_actual;
  end if;

  select count(*) into v_actual
  from pg_catalog.pg_class table_row
  join pg_catalog.pg_namespace namespace_row
    on namespace_row.oid = table_row.relnamespace
  where namespace_row.nspname = 'pgmq'
    and table_row.relname ~ '^(q|a)_'
    and table_row.relkind in ('r', 'p');
  if v_actual <> 2 then
    raise exception 'PHASE4A2B_PGMQ_QUEUE_TABLE_SET_INVALID:%', v_actual;
  end if;

  foreach v_object in array array[
    'a_schedule_optimizer_v2',
    'q_schedule_optimizer_v2'
  ] loop
    select
      table_row.relkind,
      table_row.relpersistence,
      pg_get_userbyid(table_row.relowner),
      table_row.relrowsecurity,
      table_row.relforcerowsecurity,
      array(
        select acl_item::text
        from unnest(coalesce(table_row.relacl, array[]::aclitem[])) acl_item
        order by acl_item::text
      )
      into v_kind, v_persistence, v_owner, v_bool, v_force_rls, v_acl
    from pg_catalog.pg_class table_row
    join pg_catalog.pg_namespace namespace_row
      on namespace_row.oid = table_row.relnamespace
    where namespace_row.nspname = 'pgmq'
      and table_row.relname = v_object;
    if not found
      or v_kind <> 'r'
      or v_persistence <> 'p'
      or v_owner <> 'postgres'
      or v_bool
      or v_force_rls
      or v_acl is distinct from array[
        'pg_monitor=r/postgres',
        'postgres=arwdDxtm/postgres'
      ]::text[]
    then
      raise exception 'PHASE4A2B_PGMQ_QUEUE_TABLE_IDENTITY_INVALID:%', v_object;
    end if;
    execute format('select count(*) from pgmq.%I', v_object) into v_actual;
    if v_actual <> 0 then
      raise exception 'PHASE4A2B_PGMQ_QUEUE_DATA_PRESENT:%:%',
        v_object, v_actual;
    end if;
  end loop;

  select
    sequence_row.relkind,
    sequence_row.relpersistence,
    pg_get_userbyid(sequence_row.relowner),
    array(
      select acl_item::text
      from unnest(coalesce(sequence_row.relacl, array[]::aclitem[])) acl_item
      order by acl_item::text
    )
    into v_kind, v_persistence, v_owner, v_acl
  from pg_catalog.pg_class sequence_row
  join pg_catalog.pg_namespace namespace_row
    on namespace_row.oid = sequence_row.relnamespace
  where namespace_row.nspname = 'pgmq'
    and sequence_row.relname = 'q_schedule_optimizer_v2_msg_id_seq';
  if not found
    or v_kind <> 'S'
    or v_persistence <> 'p'
    or v_owner <> 'postgres'
    or v_acl is distinct from array[
      'pg_monitor=r/postgres',
      'postgres=rwU/postgres'
    ]::text[]
  then
    raise exception 'PHASE4A2B_PGMQ_SEQUENCE_IDENTITY_INVALID';
  end if;

  -- Schema-only means every application table is empty. Only counts from the
  -- disposable local restore are observed; PGMQ q_/a_ tables are excluded and
  -- message contents are never read.
  for v_record in
    select namespace_row.nspname as schema_name, table_row.relname as table_name
    from pg_catalog.pg_class table_row
    join pg_catalog.pg_namespace namespace_row
      on namespace_row.oid = table_row.relnamespace
    where namespace_row.nspname in ('public', 'solver_private')
      and table_row.relkind in ('r', 'p')
    order by namespace_row.nspname, table_row.relname
  loop
    execute format(
      'select count(*) from %I.%I',
      v_record.schema_name,
      v_record.table_name
    ) into v_actual;
    if v_actual <> 0 then
      raise exception 'PHASE4A2B_APPLICATION_DATA_PRESENT:%.%:%',
        v_record.schema_name, v_record.table_name, v_actual;
    end if;
  end loop;
  select count(*) into v_actual from auth.users;
  if v_actual <> 0 then
    raise exception 'PHASE4A2B_AUTH_USER_DATA_PRESENT:%', v_actual;
  end if;
  select count(*) into v_actual from storage.objects;
  if v_actual <> 0 then
    raise exception 'PHASE4A2B_STORAGE_OBJECT_DATA_PRESENT:%', v_actual;
  end if;
end;
$phase4a2b$;

select jsonb_build_object(
  'contract', 'phase4a2b_baseline_restore_contract',
  'readOnly', current_setting('transaction_read_only') = 'on',
  'migrationLedgerMode', current_setting('phase4a2b.expected_ledger_mode'),
  'migrationLedgerRows',
    current_setting('phase4a2b.actual_ledger_rows')::bigint,
  'publicTablesWithRls', 113,
  'publicPolicies', 129,
  'pgmqQueue', 'schedule_optimizer_v2',
  'environmentIdentity', 'localphasegateabcdef',
  'verdict', 'PASS'
) as phase4a2b_baseline_restore_contract;

rollback;
