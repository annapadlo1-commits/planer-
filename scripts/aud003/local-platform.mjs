import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { inspectLocalTarget, docker, LOCAL_CONTAINER, LOCAL_CONTEXT } from './local-target.mjs';

const action=process.argv[2];
assert.ok(['inspect','snapshot','rebuild'].includes(action),'EXPLICIT_LOCAL_PLATFORM_ACTION_REQUIRED');
const target=inspectLocalTarget();
console.log(JSON.stringify({action,target}));
function psql(database,sql,user='postgres') {
 const result=spawnSync(docker,['--context',LOCAL_CONTEXT,'exec','-i',LOCAL_CONTAINER,'psql','-X','-qAt','-v','ON_ERROR_STOP=1','-h','/var/run/postgresql','-U',user,'-d',database,'--file=/dev/stdin'],{input:sql,encoding:'utf8',maxBuffer:1024*1024});
 if(result.status!==0)throw Error(`LOCAL_PLATFORM_SQL_FAILED:${result.status}:${result.stderr}`);
 return result.stdout.trim();
}
function withQuiescedLocalDatabase(callback) {
 const admin=psql('template1',"SELECT current_user;",'supabase_admin');
 assert.equal(admin,'supabase_admin');
 const sessions=JSON.parse(psql('template1',"SELECT coalesce(json_agg(json_build_object('pid',pid,'type',backend_type,'client',client_addr)), '[]') FROM pg_stat_activity WHERE datname='postgres';",'supabase_admin'));
 assert.ok(sessions.every(x=>['pg_net 0.20.4 worker','pg_cron launcher'].includes(x.type) && x.client===null),'UNEXPECTED_LOCAL_CLIENT_SESSION');
 psql('template1','ALTER DATABASE postgres ALLOW_CONNECTIONS false;','supabase_admin');
 try {
  psql('template1',"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='postgres';",'supabase_admin');
  callback();
 } finally {
  // Restore accessibility even if template creation failed. If a DROP succeeded
  // but CREATE failed, leave the failure explicit rather than claiming recovery.
  psql('template1','ALTER DATABASE postgres ALLOW_CONNECTIONS true;','supabase_admin');
 }
}
const databases=JSON.parse(psql('template1',"SELECT json_agg(datname ORDER BY datname) FROM pg_database;"));
if(action==='inspect') {
 console.log(psql('template1',"BEGIN TRANSACTION READ ONLY; SELECT json_agg(json_build_object('database',datname,'owner',pg_get_userbyid(datdba),'template',datistemplate,'allowConnections',datallowconn) ORDER BY datname) FROM pg_database; ROLLBACK;"));
 process.exit(0);
}
// _supabase is the platform's internal database. It is never reset here.
assert.deepEqual(databases,action==='snapshot'?['_supabase','postgres','template0','template1']:['_supabase','aud003_empty_template','postgres','template0','template1']);
if(action==='snapshot') {
 const empty=JSON.parse(psql('postgres',`BEGIN TRANSACTION READ ONLY;
 SELECT json_build_object('app', (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('public','authorization_private','solver_private') AND c.relkind IN ('r','p','v','m')), 'users',(SELECT count(*) FROM auth.users),'objects',(SELECT count(*) FROM storage.objects),'buckets',(SELECT count(*) FROM storage.buckets)); ROLLBACK;`));
 assert.deepEqual(empty,{app:0,users:0,objects:0,buckets:0});
 // CREATE/DROP DATABASE cannot be wrapped in a transaction. These narrowly
 // allowlisted lifecycle operations are separate from atomic baseline execution.
 withQuiescedLocalDatabase(()=>psql('template1','CREATE DATABASE aud003_empty_template WITH TEMPLATE postgres;\nALTER DATABASE aud003_empty_template ALLOW_CONNECTIONS false;'));
 console.log('EMPTY_LOCAL_PLATFORM_TEMPLATE_CREATED');
} else {
 // Only the disposable postgres database in the exact pinned task container.
 // The pristine platform template and all other Docker resources are preserved.
 withQuiescedLocalDatabase(()=>psql('template1','DROP DATABASE postgres WITH (FORCE);\nCREATE DATABASE postgres WITH TEMPLATE aud003_empty_template;'));
 console.log('DISPOSABLE_LOCAL_DATABASE_RECREATED_FROM_EMPTY_PLATFORM');
}
