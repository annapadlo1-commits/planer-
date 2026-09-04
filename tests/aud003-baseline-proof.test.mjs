import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,mkdtemp,writeFile,rm,cp,unlink,mkdir} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {checkArchive} from '../scripts/aud003/check-archive.mjs';
import {buildBaseline} from '../scripts/aud003/build-baseline.mjs';
const root=new URL('../',import.meta.url);

test('AUD-003 baseline generation is byte-deterministic and rejects an unidentified source',async()=>{
 const source=JSON.parse(await readFile(new URL('supabase/baseline/aud003/uat-catalog-2026-09-03.json',root),'utf8'));
 const generated=Buffer.from(buildBaseline(source));
 assert.deepEqual(generated,await readFile(new URL('supabase/baseline/aud003/generated-baseline.sql',root)));
 assert.deepEqual(generated,await readFile(new URL('supabase/migrations/20260903090000_aud003_canonical_uat_baseline.sql',root)));
 for(const patch of [{projectRef:'wrong-project'},{environment:'PRODUCTION'},{identityEnabled:false},{transactionReadOnly:'off'}])assert.throws(()=>buildBaseline({...source,...patch}));
});

test('AUD-003 source inventory understands named ACL identities, overloads and renames',async()=>{
 const temp=await mkdtemp(path.join(tmpdir(),'aud003-rpc-parser-'));
 try {
  await mkdir(path.join(temp,'supabase/migrations'),{recursive:true});
  await writeFile(path.join(temp,'supabase/migrations/20260903090000_probe.sql'),`
create function public.probe(p_rows jsonb) returns void language sql as $$select;$$;
create function public.probe(p_rows text) returns void language sql as $$select;$$;
revoke all on function "public"."probe"(p_rows jsonb) from public, anon, authenticated;
grant execute on function "public"."probe"(p_rows jsonb) to authenticated;
alter function public.probe(p_rows jsonb) rename to probe_before;
create function public.probe(p_rows jsonb) returns void language sql as $$select;$$;
revoke all on function public.probe(jsonb) from public, anon, authenticated;
`);
  const r=spawnSync(process.execPath,[fileURLToPath(new URL('scripts/rpc-contract/migration-source-inventory.mjs',root))],{cwd:temp,encoding:'utf8'});
  assert.equal(r.status,0,r.stderr);
  const {inventory}=JSON.parse(r.stdout);
  const renamed=inventory.find(x=>x.name==='probe_before');
  assert.equal(renamed.authenticatedExecute,true);assert.equal(renamed.anonExecute,false);
  assert.equal(inventory.find(x=>x.name==='probe'&&x.args[0].type==='jsonb').authenticatedExecute,false);
  assert.equal(inventory.find(x=>x.name==='probe'&&x.args[0].type==='text').publicExecute,true);
  assert.equal(inventory.length,3);
 } finally {await rm(temp,{recursive:true,force:true});}
});

test('AUD-003 active migration ledger, exact 227 source blobs and 256 live provenance rows reconcile',async()=>{
 assert.deepEqual(await checkArchive(),{archived:227,active:9,liveRows:256});
});

test('AUD-003 archive rejects changed, missing and additional evidence without rewriting expected hashes',async()=>{
 const temp=await mkdtemp(path.join(tmpdir(),'aud003-archive-'));
 try {
  for(const dir of ['supabase/archive/aud003','supabase/baseline/aud003','supabase/migrations'])await cp(new URL(dir,root),path.join(temp,dir),{recursive:true});
  assert.equal((await checkArchive(temp)).archived,227);
  const manifest=JSON.parse(await readFile(path.join(temp,'supabase/archive/aud003/archive.manifest.json'),'utf8'));
  const file=path.join(temp,manifest.entries[0].path), original=await readFile(file);
  await writeFile(file,Buffer.concat([original,Buffer.from(' ')]));
  await assert.rejects(checkArchive(temp),/ARCHIVE_BYTES_CHANGED/u);
  await writeFile(file,original);
  await unlink(file);
  await assert.rejects(checkArchive(temp),/ARCHIVE_FILE_SET_MISMATCH/u);
  await writeFile(file,original);
  await writeFile(path.join(temp,'supabase/archive/aud003/migrations/20990101000000_extra.sql'),'select 1;');
  await assert.rejects(checkArchive(temp),/ARCHIVE_FILE_SET_MISMATCH/u);
 } finally {await rm(temp,{recursive:true,force:true});}
});

test('AUD-003 semantic comparator fails closed on application, grants, RLS and platform changes',async()=>{
 const temp=await mkdtemp(path.join(tmpdir(),'aud003-semantic-'));
 try {
  const source=JSON.parse(await readFile(new URL('supabase/baseline/aud003/uat-catalog-2026-09-03.json',root),'utf8'));
  const localPath=path.join(temp,'local.json'), reportPath=path.join(temp,'report.json');
  const run=async mutate=>{
   const local=structuredClone(source);local.projectRef=null;local.localProject='aud003-local-db-20260903';mutate(local);
   await writeFile(localPath,JSON.stringify(local));
   return spawnSync(process.execPath,['scripts/aud003/compare-catalogs.mjs',localPath,reportPath],{cwd:root,encoding:'utf8'});
  };
  assert.equal((await run(()=>{})).status,0);
  const mutations=[
   c=>c.relations.pop(),c=>c.relations.push({...c.relations[0],name:'unexpected_table'}),
   c=>c.relations.push({...c.relations[0]}),
   c=>c.columns[0].type='text',c=>c.routines[0].definition+=' -- changed',
   c=>c.policies[0].qual='true',c=>c.storageObjectsTable.rls=false,
   c=>c.storageObjectsTable.acl+=',unexpected_role=r/supabase_storage_admin',
   c=>c.defaultAcls[0].acl.push('unexpected_role=X/postgres'),
   c=>c.extensions[0].owner='unexpected_role',c=>c.storageBuckets[0].public=true,
  ];
  for(const mutate of mutations)assert.equal((await run(mutate)).status,1);
 } finally {await rm(temp,{recursive:true,force:true});}
});
