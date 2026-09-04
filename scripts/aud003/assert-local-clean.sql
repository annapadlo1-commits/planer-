BEGIN TRANSACTION READ ONLY;
DO $test$
DECLARE r record; n bigint;
BEGIN
 FOR r IN SELECT schemaname,tablename FROM pg_tables WHERE schemaname IN ('public','solver_private','authorization_private') LOOP
  EXECUTE format('SELECT count(*) FROM %I.%I',r.schemaname,r.tablename) INTO n;
  IF n<>0 THEN RAISE EXCEPTION 'LOCAL_FIXTURE_ROWS_REMAIN:%.%:%',r.schemaname,r.tablename,n; END IF;
 END LOOP;
 IF EXISTS(SELECT 1 FROM auth.users) OR EXISTS(SELECT 1 FROM storage.objects)
 OR EXISTS(SELECT 1 FROM cron.job) THEN RAISE EXCEPTION 'LOCAL_USER_OBJECT_OR_CRON_ROWS_REMAIN'; END IF;
END;
$test$;
SELECT jsonb_build_object('allApplicationTablesEmpty',true,'authUsers',0,'storageObjects',0,'cronJobs',0,
 'bucketCount',(SELECT count(*) FROM storage.buckets),'uatDestructiveToolsConfigured',EXISTS(SELECT 1 FROM public.uat_environment_controls));
ROLLBACK;
