import assert from 'node:assert/strict';
import {readFile,readdir,mkdir,writeFile,rename,unlink} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import path from 'node:path';

const root=process.cwd();
const sourceSha='92bc2c8bcbba780d251f5a37a7e56767ecdb6386';
const run=(args)=>{const r=spawnSync('git',args,{maxBuffer:16*1024*1024});assert.equal(r.status,0,'SOURCE_GIT_READ_FAILED');return r.stdout;};
assert.equal(run(['branch','--show-current']).toString().trim(),'codex/aud003-canonical-baseline-trial-2026-09-03');
assert.equal(run(['rev-parse','HEAD']).toString().trim(),sourceSha);
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const normalized=bytes=>Buffer.from(bytes.toString().replaceAll('\r\n','\n'));
const history=JSON.parse(await readFile('supabase/baseline/aud003/history-reconciliation.json','utf8'));
assert.equal(history.sourceSha,sourceSha);
const archive='supabase/archive/aud003/migrations';
const baseline='20260903090000_aud003_canonical_uat_baseline.sql';
const created=(await readdir('supabase/migrations')).filter(x=>x.endsWith('_aud003_canonical_uat_baseline.sql'));
assert.equal(created.length,1);
assert.equal((await readFile(`supabase/migrations/${created[0]}`)).length,0,'CLI_SCAFFOLD_MUST_BE_EMPTY');
const generated=await readFile('supabase/baseline/aud003/generated-baseline.sql');
assert.equal(sha(generated),'2210f8436eb7d5dde033aae671dff98d6b166c3d60f97a5166ea3fa85e85d7db');
await mkdir(archive,{recursive:true});
const entries=[];
for(const entry of history.localFiles.filter(x=>!x.auditMigration)) {
 const original=path.resolve(entry.sourcePath),destination=path.resolve(archive,entry.file);
 assert.ok(original.startsWith(path.resolve(root,'supabase/migrations')+path.sep));
 assert.ok(destination.startsWith(path.resolve(root,archive)+path.sep));
 const canonical=run(['show',`${sourceSha}:${entry.sourcePath}`]);
 assert.equal(sha(canonical),entry.sourceSha256);
 assert.deepEqual(normalized(await readFile(original)),normalized(canonical),'UNEXPECTED_SOURCE_CHANGE');
 // Archive exact committed source bytes, not Windows checkout transformations.
 await writeFile(destination,canonical,{flag:'wx'});
 assert.equal(sha(await readFile(destination)),entry.sourceSha256);
 await unlink(original);
 entries.push({file:entry.file,path:`${archive}/${entry.file}`,sourcePath:entry.sourcePath,sourceSha,
  bytes:canonical.length,sha256:entry.sourceSha256,canonicalSha256:entry.sourceCanonicalSha256});
}
assert.equal(entries.length,227);
await writeFile('supabase/archive/aud003/legacy-ledger.manifest.json',await readFile('supabase/migrations/ledger.manifest.json'),{flag:'wx'});
await writeFile('supabase/archive/aud003/archive.manifest.json',JSON.stringify({format:'aud003-archive-v1',projectRef:history.projectRef,sourceSha,hashPolicy:'Exact original Git blob bytes; archive never executed as active migrations.',entries},null,2)+'\n',{flag:'wx'});
await rename(`supabase/migrations/${created[0]}`,`supabase/migrations/${baseline}`);
await writeFile(`supabase/migrations/${baseline}`,generated);
const provenance={format:'aud003-live-provenance-v1',projectRef:history.projectRef,sourceSha,sourceUatSha:history.sourceUatSha,
 ledgerSha256:history.ledgerSha256,counts:history.counts,baseline:`supabase/migrations/${baseline}`,baselineSha256:sha(generated),
 chronology:'Baseline version is a logical pre-audit ordering key (09:00), not the capture time. CLI scaffold was renamed before any application.',
 coverageMeaning:'Current state is covered by independently replayed captured schema; this is NOT an assertion that every historical statement was applied or semantically equivalent. Historical SQL is not replayed. Remote ledger untouched.',
 liveRows:history.liveRows.map(x=>({...x,baselineCoverage:'CURRENT_STATE_CAPTURE_AND_LOCAL_REBUILD',baselineVersion:'20260903090000',archivePath:x.sourceFile?`${archive}/${x.sourceFile}`:null})),
 localFiles:history.localFiles.map(x=>({...x,path:x.auditMigration?x.sourcePath:`${archive}/${x.file}`,baselineCoverage:x.auditMigration?'SEPARATE_UNCHANGED_FORWARD_MIGRATION':'ARCHIVED_NOT_REPLAYED_CURRENT_STATE_IN_BASELINE'}))};
await writeFile('supabase/baseline/aud003/live-provenance.json',JSON.stringify(provenance,null,2)+'\n',{flag:'wx'});
// Mechanical path updates only in existing tests; no assertions or runtime change.
const testFiles=run(['ls-files','tests']).toString().trim().split('\n').filter(x=>x.endsWith('.mjs'));
const changedTests=[];
for(const file of testFiles) {
 const before=await readFile(file,'utf8');let after=before;
 for(const entry of entries)after=after.replaceAll(`supabase/migrations/${entry.file}`,entry.path);
 if(file==='tests/aud008-tenant-isolation-inventory.test.mjs')after=after.replaceAll('supabase/migrations/${name}',`${archive}/`+'${name}');
 if(after!==before){await writeFile(file,after);changedTests.push(file);}
}
console.log(JSON.stringify({baseline,archived:entries.length,activeSql:(await readdir('supabase/migrations')).filter(x=>x.endsWith('.sql')),changedTests},null,2));
