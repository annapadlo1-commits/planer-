import assert from 'node:assert/strict';
import {mkdtempSync,readFileSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {spawnSync} from 'node:child_process';
import test from 'node:test';
import {expectedCounts,verifyRlsEvidence} from '../scripts/aud003/rls-evidence.mjs';

const sql=readFileSync('supabase/tests/phase4a1_scoped_manager_security_contract.sql','utf8');
test('MRG-RVW-03 fixture has no destructive helper, flag enable, trigger bypass or persistent transaction',()=>{
  assert.match(sql,/^begin;/mu);assert.match(sql,/rollback;\s*$/u);
  assert.doesNotMatch(sql,/\bcommit\s*;|session_replication_role|disable\s+trigger|seed_required_defaults_uat|\b(?:create|alter|drop)\s+(?:function|policy|table)|\bgrant\b|\brevoke\b/iu);
  assert.doesNotMatch(sql,/(?:insert\s+into|update|delete\s+from)\s+(?:public\.)?uat_environment_controls/iu);
  assert.match(sql,/PHASE4A_UAT_DESTRUCTIVE_FLAG_CHANGED/u);
  assert.match(sql,/savepoint zero_active;[\s\S]*?set local role authenticated;[\s\S]*?PHASE4A_ZERO_ACTIVE_MATRIX_ALLOWED[\s\S]*?rollback to savepoint zero_active;/u);
  const actorBlocks=sql.match(/do \$\$ begin\s+if current_user<>[\s\S]*?end \$\$;/gu);
  assert.equal(actorBlocks.length,13);
  for(const block of actorBlocks) {
    assert.match(block,/rolsuper or rolbypassrls/u);
    assert.match(block,/auth\.uid\(\) is distinct from/u);
    assert.match(block,/request\.jwt\.claim\.role/u);
  }
  assert.equal((sql.match(/set_config\('request.jwt.claims','\{\}',true\)/gu)||[]).length,16);
});

const syntheticLog=[...sql.matchAll(/raise notice '(RLS_(?:ASSERT|CONTEXT)\|[^']+)'/gu)].map(m=>`NOTICE: ${m[1]}`).join('\n');
test('MRG-RVW-03 evidence requires every assertion, role and successful SQL termination',()=>{
  assert.equal(verifyRlsEvidence(sql,syntheticLog,0).assertionGroups,37);
  assert.deepEqual(verifyRlsEvidence(sql,syntheticLog,0).counts,expectedCounts);
  assert.throws(()=>verifyRlsEvidence(sql,syntheticLog,3),/RLS_SQL_EXECUTION_FAILED/u);
  assert.throws(()=>verifyRlsEvidence(sql,'',0),/RLS_ASSERTION_MISSING/u);
  assert.throws(()=>verifyRlsEvidence(sql,syntheticLog.replace(/NOTICE: RLS_ASSERT[^\n]+\n/u,''),0),/RLS_ASSERTION_MISSING/u);
  assert.throws(()=>verifyRlsEvidence(sql,syntheticLog+'\nNOTICE: RLS_ASSERT|ANON|PHASE4A_FAKE',0),/RLS_ASSERTION_MISSING/u);
  assert.throws(()=>verifyRlsEvidence(sql,syntheticLog.replaceAll('|authenticated','|postgres'),0),/PRIVILEGED_ACTOR/u);
});

// Preload replaces child_process in a separate Node process before the real
// launcher is imported. No Docker binary or network connection is ever called.
const preload=`import cp from 'node:child_process';
import {syncBuiltinESMExports} from 'node:module';
const bad=process.env.AUD003_TEST_BAD;
const name='supabase_db_aud003-local-db-20260903';
const image='sha256:28f0e16a019e648089fc1a6d333549a55548f6019c15ae4bd7cd58b989027518';
const ports={'5432/tcp':[{HostIp:'127.0.0.1',HostPort:'55432'}]};
const state={Id:'33197cfa244a28049ce0166bffb5ae167d07e69f62e4fd209f578d4bc90d9864',Name:'/'+name,Image:image,
 Config:{Image:image,Labels:{'com.supabase.cli.project':'aud003-local-db-20260903'},Cmd:[],Env:[]},
 HostConfig:{PortBindings:ports,NetworkMode:'aud003-local-only-20260903',Privileged:false,PidMode:''},
 Mounts:[{Type:'volume',Name:name,Destination:'/var/lib/postgresql/data'}],
 State:{Running:true,Health:{Status:'healthy'}},NetworkSettings:{Ports:ports}};
if(bad==='container')state.Id='wrong';
if(bad==='binding')ports['5432/tcp'][0].HostIp='0.0.0.0';
if(bad==='image')state.Config.Image='untrusted';
if(bad==='remote-project')state.Config.Env=['PROJECT_REF=nhthrtpkfpmufmrmdyjg'];
cp.spawnSync=(binary,args)=>{
 if(args.includes('exec')){process.stderr.write('SQL_EXEC_WOULD_RUN');return {status:0,stdout:'',stderr:''};}
 let data;
 if(args.join(' ')==='context show')return {status:0,stdout:bad==='context'?'remote':'desktop-linux'};
 if(args[0]==='context')data=[{Endpoints:{docker:{Host:'npipe:////./pipe/dockerDesktopLinuxEngine'}}}];
 else if(args.includes('volume'))data=[{Name:name,Driver:'local',Options:bad==='volume'?{type:'nfs'}:{}}];
 else if(args.includes('image'))data=[{Id:image,RepoDigests:[]}];
 else data=[state];
 return {status:0,stdout:JSON.stringify(data),stderr:''};
};syncBuiltinESMExports();`;
test('MRG-RVW-03 real launcher rejects forbidden target before SQL exec (offline)',()=>{
  const temp=mkdtempSync(path.join(tmpdir(),'aud003-launcher-'));
  try {
    const mock=path.join(temp,'mock.mjs');writeFileSync(mock,preload);
    const sqlPath=path.join(temp,'no-op.sql');writeFileSync(sqlPath,'select 1;');
    for(const bad of ['context','container','binding','image','remote-project','volume','database','host','valid']) {
      const env={...process.env,AUD003_TEST_BAD:bad,DOCKER_CONTEXT:'desktop-linux'};
      delete env.DOCKER_HOST;if(bad==='host')env.DOCKER_HOST='tcp://forbidden.invalid:2375';
      const r=spawnSync(process.execPath,['--import',pathToFileURL(mock).href,'scripts/aud003/local-psql.mjs',sqlPath,bad==='database'?'remote':'postgres'],{encoding:'utf8',env});
      if(bad==='valid') {assert.equal(r.status,0,r.stderr);assert.match(r.stderr,/SQL_EXEC_WOULD_RUN/u);}
      else {
        assert.notEqual(r.status,0,bad);assert.doesNotMatch(r.stderr,/SQL_EXEC_WOULD_RUN/u,bad);
        const expected={host:/DOCKER_HOST_MUST_BE_UNSET/u,database:/LOCAL_SQL_FILE_AND_ALLOWLISTED_DATABASE_REQUIRED/u,
          'remote-project':/REMOTE_CONFIGURATION_REFUSED/u,volume:/REMOTE_VOLUME_REFUSED/u};
        assert.match(r.stderr,expected[bad]??/AssertionError/u,bad);
      }
    }
  } finally {rmSync(temp,{recursive:true,force:true});}
});
