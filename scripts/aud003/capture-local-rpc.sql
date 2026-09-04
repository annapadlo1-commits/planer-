BEGIN TRANSACTION READ ONLY;
SET LOCAL search_path='';
SELECT jsonb_build_object('localProject','aud003-local-db-20260903','database',current_database(),'user',current_user,'rows',jsonb_agg(to_jsonb(r) ORDER BY schema_name,name,identity_arguments))
FROM (
 SELECT n.nspname AS schema_name,p.proname AS name,pg_get_function_identity_arguments(p.oid) AS identity_arguments,
 p.pronargdefaults,
 ARRAY(SELECT p.proargnames[i] FROM generate_series(1,cardinality(coalesce(p.proallargtypes,p.proargtypes::oid[]))) i
       WHERE p.proargmodes IS NULL OR p.proargmodes[i] IN ('i','b','v')) AS input_arg_names,
 ARRAY(SELECT format_type(t,NULL) FROM unnest(p.proargtypes::oid[]) t) AS input_arg_types,
 has_function_privilege('authenticated',p.oid,'EXECUTE') AS authenticated_execute,
 has_function_privilege('anon',p.oid,'EXECUTE') AS anon_execute,
 EXISTS(SELECT 1 FROM aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a WHERE a.grantee=0 AND a.privilege_type='EXECUTE') AS public_execute
 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname IN ('public','solver_private','authorization_private') AND p.prokind='f'
) r;
ROLLBACK;
