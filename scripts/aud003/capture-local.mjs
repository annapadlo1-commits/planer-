import assert from 'node:assert/strict';
import { readFile,writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
const output=process.argv[2];
assert.ok(output && !output.includes('://'),'LOCAL_OUTPUT_REQUIRED');
let query=await readFile('scripts/aud003/capture-uat-catalog.sql','utf8');
const ledger=/ledger as \([\s\S]*?\n\)\nselect/u;
assert.ok(ledger.test(query));
query=query.replace(ledger,`ledger as (
 select null::text as version,null::text as name,0 as statement_count,0 as sql_bytes,null::text as sql_md5,null::text as sql_sha256,null::text as canonical_sql_sha256 where false
)
select`);
const queryPath=output.replace(/\.json$/u,'.sql');
assert.notEqual(queryPath,output);
await writeFile(queryPath,query);
const run=spawnSync(process.execPath,['scripts/aud003/local-psql.mjs',queryPath],{encoding:'utf8',maxBuffer:16*1024*1024});
if(run.status!==0)throw Error(`LOCAL_CAPTURE_FAILED:${run.status}:${run.stderr}`);
const capture=JSON.parse(run.stdout.trim());
assert.equal(capture.transactionReadOnly,'on');
assert.equal(capture.projectRef,null,'LOCAL_DATABASE_MUST_NOT_CLAIM_REMOTE_IDENTITY');
capture.format='aud003-local-catalog-v2';
capture.localProject='aud003-local-db-20260903';
await writeFile(output,JSON.stringify(capture,null,2)+'\n');
console.log(JSON.stringify({output,relations:capture.relations.length,routines:capture.routines.length,policies:capture.policies.length}));
