BEGIN;
DO $test$
DECLARE n integer; failed boolean;
BEGIN
  SELECT count(*) INTO n FROM pg_constraint
  WHERE convalidated AND conname IN ('matrix_employee_roles_v2_primary_or_fallback_check','matrix_staffing_active_set_positive_uat006');
  IF n<>2 THEN RAISE EXCEPTION 'AUD013_CONSTRAINTS_NOT_VALIDATED'; END IF;
  IF NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='solver_private' AND table_name='optimization_attempts_v2' AND column_name='worker_build_manifest' AND data_type='jsonb') THEN
    RAISE EXCEPTION 'AUD004_MANIFEST_COLUMN_MISSING'; END IF;
  SELECT count(*) INTO n FROM pg_policies WHERE schemaname='public'
  AND policyname IN ('employee_reads_own_assignments','employee_reads_own_attendance','availability_manage','availability_read','availability_history_read','authenticated_reads_employee_capabilities','hr_read','authenticated_reads_employee_locations','employee_reads_self','user_reads_own_tasks','users_read_own_permissions')
  AND qual ~ 'SELECT auth.uid\(\)';
  IF n<>10 THEN RAISE EXCEPTION 'AUD015_SELECT_INITPLANS_MISSING:%',n; END IF;
  SELECT count(*) INTO n FROM pg_policies WHERE schemaname='public'
  AND tablename='employee_availability'
  AND policyname IN ('availability_manage_insert','availability_manage_update','availability_manage_delete')
  AND (coalesce(qual,'') ~ 'SELECT auth.uid\(\)' OR coalesce(with_check,'') ~ 'SELECT auth.uid\(\)');
  IF n<>3 THEN RAISE EXCEPTION 'AUD015_WRITE_INITPLANS_MISSING:%',n; END IF;
  IF EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public'
      AND (
        regexp_replace(coalesce(qual,''), '\(\s*SELECT\s+auth\.uid\(\)(\s+AS\s+uid)?\s*\)', '', 'gi') ~ 'auth.uid\(\)'
        OR regexp_replace(coalesce(with_check,''), '\(\s*SELECT\s+auth\.uid\(\)(\s+AS\s+uid)?\s*\)', '', 'gi') ~ 'auth.uid\(\)'
      )
  ) THEN RAISE EXCEPTION 'AUD015_RAW_AUTH_UID_REMAINS'; END IF;
  IF (SELECT provolatile FROM pg_proc WHERE oid='public.current_user_access_v2()'::regprocedure)<>'s'
  OR (SELECT provolatile FROM pg_proc WHERE oid='public.current_company_time_context_v1()'::regprocedure)<>'s'
  THEN RAISE EXCEPTION 'READ_RPC_NOT_STABLE'; END IF;
  IF has_function_privilege('anon','public.application_access_provision_current_user_v1()','EXECUTE')
  OR NOT has_function_privilege('authenticated','public.application_access_provision_current_user_v1()','EXECUTE')
  OR has_function_privilege('authenticated','public.solver_save_variants_v2(uuid,uuid,uuid,jsonb,text)','EXECUTE')
  OR NOT has_function_privilege('service_role','public.solver_save_variants_v2(uuid,uuid,uuid,jsonb,text)','EXECUTE')
  OR has_function_privilege('service_role','public.solver_save_variant_before_aud004_018(uuid,uuid,uuid,jsonb,text)','EXECUTE')
  THEN RAISE EXCEPTION 'AUDIT_RPC_PRIVILEGES_WRONG'; END IF;
  PERFORM set_config('request.jwt.claim.sub','',true);
  failed:=false;
  BEGIN PERFORM public.current_user_access_v2();
  EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'AUTH_REQUIRED' THEN RAISE; END IF;failed:=true;END;
  IF NOT failed THEN RAISE EXCEPTION 'AUD012_ANONYMOUS_READ_ALLOWED'; END IF;
  failed:=false;
  BEGIN PERFORM public.current_company_time_context_v1();
  EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'AUTH_REQUIRED' THEN RAISE; END IF;failed:=true;END;
  IF NOT failed THEN RAISE EXCEPTION 'AUD011_ANONYMOUS_READ_ALLOWED'; END IF;
  failed:=false;
  BEGIN PERFORM public.application_access_provision_current_user_v1();
  EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'AUTH_REQUIRED' THEN RAISE; END IF;failed:=true;END;
  IF NOT failed THEN RAISE EXCEPTION 'AUD012_ANONYMOUS_PROVISION_ALLOWED'; END IF;
  failed:=false;
  BEGIN PERFORM public.solver_claim_next_v3('local-proof','local-proof','{}',1,30);
  EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'WORKER_BUILD_MANIFEST_INVALID' THEN RAISE; END IF;failed:=true;END;
  IF NOT failed THEN RAISE EXCEPTION 'AUD004_INVALID_MANIFEST_ALLOWED'; END IF;
  failed:=false;
  BEGIN PERFORM public.solver_save_variants_v2(null,null,null,'[{"strategyCode":"BALANCED"},{"strategyCode":"BALANCED"},{"strategyCode":"PREFERENCES"}]','local-proof');
  EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'STRATEGY_SET_MISMATCH' THEN RAISE; END IF;failed:=true;END;
  IF NOT failed THEN RAISE EXCEPTION 'AUD017_DUPLICATE_STRATEGY_ALLOWED'; END IF;
END;
$test$;
SELECT 'AUDIT_EFFECTS_AND_FAIL_CLOSED_GUARDS_VERIFIED_LOCALLY';
ROLLBACK;
