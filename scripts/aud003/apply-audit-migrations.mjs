import assert from 'node:assert/strict';
import {readFile,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {inspectLocalTarget} from './local-target.mjs';

const output=process.argv[2];
assert.ok(output && !output.includes('://'));
const target=inspectLocalTarget();
const history=JSON.parse(await readFile('supabase/baseline/aud003/history-reconciliation.json','utf8'));
assert.equal(history.projectRef,'nhthrtpkfpmufmrmdyjg');
const files=history.localFiles.filter(x=>x.auditMigration);
assert.equal(files.length,6);
const results=[];
for(const entry of files) {
 const bytes=await readFile(`supabase/migrations/${entry.file}`);
 const canonical=Buffer.from(bytes.toString('utf8').replaceAll('\r\n','\n'));
 assert.equal(createHash('sha256').update(canonical).digest('hex'),entry.sourceCanonicalSha256,'AUDIT_MIGRATION_CHANGED');
 // Remove dollar-quoted routine bodies and comments only for outer statement inspection.
 const sql=canonical.toString();
 const outer=sql.replace(/\$([A-Za-z_][A-Za-z_0-9]*|)\$[\s\S]*?\$\1\$/gu,'BODY')
  .replace(/--[^\n]*/gu,'').trim();
 const wrapped=/^begin;/iu.test(outer)&&/commit;$/iu.test(outer);
 const middle=wrapped?outer.replace(/^begin;/iu,'').replace(/commit;$/iu,''):outer;
 assert.doesNotMatch(middle,/(?:^|;)\s*(?:begin|commit|rollback|start transaction)\s*;/iu);
 assert.doesNotMatch(outer,/^\s*\\|\b(?:dblink_connect|net\.http_|cron\.schedule|copy\s+[^;]*program)\b/imu);
 // Keep original file byte-for-byte. Existing explicit BEGIN/COMMIT files already
 // provide one transaction; nesting psql -1 around COMMIT would be misleading.
 const start=performance.now();
 const r=spawnSync(process.execPath,['scripts/aud003/local-psql.mjs',`supabase/migrations/${entry.file}`,'postgres',...(wrapped?[]:['--transaction'])],{encoding:'utf8',maxBuffer:4*1024*1024});
 results.push({file:entry.file,canonicalSha256:entry.sourceCanonicalSha256,transaction:wrapped?'original explicit BEGIN/COMMIT + ON_ERROR_STOP':'psql --single-transaction + ON_ERROR_STOP',exitCode:r.status,durationMs:Math.round(performance.now()-start),stdout:r.stdout,stderr:r.stderr});
 await writeFile(output,JSON.stringify({target,results},null,2)+'\n');
 console.log(JSON.stringify({file:entry.file,exitCode:r.status,durationMs:results.at(-1).durationMs}));
 if(r.status!==0){process.exitCode=1;break;}
}
