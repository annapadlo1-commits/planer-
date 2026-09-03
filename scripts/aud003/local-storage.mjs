import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {createHmac,randomBytes} from 'node:crypto';
import {inspectLocalTarget,docker,dockerRead,LOCAL_CONTAINER,LOCAL_CONTEXT,LOCAL_PROJECT} from './local-target.mjs';

const action=process.argv[2];
assert.ok(['provision','stop'].includes(action));
inspectLocalTarget();
const name='aud003-storage-local-20260903';
const image='public.ecr.aws/supabase/storage-api@sha256:528ec49c3c32561908b07ee91bced7f8456f3b688164e341eaa422441767a0bd';
const found=JSON.parse(dockerRead(['--context',LOCAL_CONTEXT,'ps','-a','--filter',`name=^/${name}$`,'--format','json']).trim()||'null');
let state;
if(found) {
 [state]=JSON.parse(dockerRead(['--context',LOCAL_CONTEXT,'inspect',name]));
 assert.equal(state.Config.Labels['com.szafunek.task'],LOCAL_PROJECT);
 assert.equal(state.Config.Image,image);
 assert.deepEqual(state.HostConfig.PortBindings,{'5000/tcp':[{HostIp:'127.0.0.1',HostPort:'55433'}]});
 assert.equal(state.HostConfig.NetworkMode,'aud003-local-only-20260903');
 assert.equal(state.HostConfig.Privileged,false);
}
function run(args,env=process.env) {
 const r=spawnSync(docker,['--context',LOCAL_CONTEXT,...args],{encoding:'utf8',env,maxBuffer:1024*1024});
 assert.equal(r.status,0,`LOCAL_STORAGE_DOCKER_FAILED:${args[0]}`);
}
if(action==='stop') {
 if(state?.State.Running)run(['stop',name]);
 console.log('LOCAL_STORAGE_STOPPED');
 process.exit(0);
}
function vars(items){return Object.fromEntries(items.map(x=>{const i=x.indexOf('=');return [x.slice(0,i),x.slice(i+1)];}));}
function jwt(secret,role) {
 const encode=x=>Buffer.from(JSON.stringify(x)).toString('base64url');
 const payload=`${encode({alg:'HS256',typ:'JWT'})}.${encode({role,iss:LOCAL_PROJECT,iat:Math.floor(Date.now()/1000),exp:Math.floor(Date.now()/1000)+3600})}`;
 return `${payload}.${createHmac('sha256',secret).update(payload).digest('base64url')}`;
}
let env;
if(!state) {
 const [db]=JSON.parse(dockerRead(['--context',LOCAL_CONTEXT,'inspect',LOCAL_CONTAINER]));
 const dbEnv=vars(db.Config.Env);
 const password=dbEnv.POSTGRES_PASSWORD||dbEnv.PGPASSWORD;
 assert.ok(password,'LOCAL_DATABASE_PASSWORD_MISSING');
 const secret=randomBytes(48).toString('base64url');
 env={AUTH_JWT_SECRET:secret,ANON_KEY:jwt(secret,'anon'),SERVICE_KEY:jwt(secret,'service_role'),
 DATABASE_URL:`postgres://supabase_storage_admin:${encodeURIComponent(password)}@${LOCAL_CONTAINER}:5432/postgres`,
 POSTGREST_URL:'http://127.0.0.1:59999',STORAGE_PUBLIC_URL:'http://127.0.0.1:55433',
 FILE_SIZE_LIMIT:'5242880',STORAGE_BACKEND:'file',FILE_STORAGE_BACKEND_PATH:'/var/lib/storage',
 GLOBAL_S3_BUCKET:LOCAL_PROJECT,TENANT_ID:LOCAL_PROJECT,REGION:'local',ENABLE_IMAGE_TRANSFORMATION:'false'};
 // Values stay only in process/container memory, never in argv or evidence.
 run(['run','-d','--name',name,'--label',`com.szafunek.task=${LOCAL_PROJECT}`,'--network','aud003-local-only-20260903',
 '--publish','127.0.0.1:55433:5000','--tmpfs','/var/lib/storage:rw,size=16m','--memory','384m',
 ...Object.keys(env).flatMap(k=>['-e',k]),image],{...process.env,...env});
} else {
 env=vars(state.Config.Env);
 assert.ok(env.DATABASE_URL.includes(`@${LOCAL_CONTAINER}:5432/postgres`));
 if(!state.State.Running)run(['start',name]);
}
let healthy=false;
for(let i=0;i<40;i++) {
 try {healthy=(await fetch('http://127.0.0.1:55433/status',{signal:AbortSignal.timeout(1000)})).ok;} catch {}
 if(healthy)break;
 await new Promise(r=>setTimeout(r,500));
}
assert.ok(healthy,'LOCAL_STORAGE_NOT_HEALTHY');
const result=spawnSync(process.execPath,['scripts/phase4a2b/provision_local_storage_bucket.mjs'],{
 encoding:'utf8',env:{...process.env,SUPABASE_STORAGE_URL:'http://127.0.0.1:55433',SUPABASE_SERVICE_ROLE_KEY:jwt(env.AUTH_JWT_SECRET,'service_role')}});
process.stdout.write(result.stdout||'');
process.stderr.write(result.stderr||'');
process.exitCode=result.status??1;
