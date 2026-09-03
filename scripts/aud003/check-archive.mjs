import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import path from 'node:path';
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
export async function checkArchive(root=process.cwd()) {
 const manifest=JSON.parse(await readFile(path.join(root,'supabase/archive/aud003/archive.manifest.json'),'utf8'));
 const provenance=JSON.parse(await readFile(path.join(root,'supabase/baseline/aud003/live-provenance.json'),'utf8'));
 const capture=JSON.parse(await readFile(path.join(root,'supabase/baseline/aud003/uat-catalog-2026-09-03.json'),'utf8'));
 assert.equal(manifest.sourceSha,'92bc2c8bcbba780d251f5a37a7e56767ecdb6386');
 assert.equal(manifest.projectRef,'nhthrtpkfpmufmrmdyjg');
 assert.equal(provenance.projectRef,manifest.projectRef);
 assert.equal(provenance.ledgerSha256,capture.ledger.sha256);
 assert.equal(manifest.entries.length,227);
 assert.deepEqual((await readdir(path.join(root,'supabase/archive/aud003/migrations'))).sort(),manifest.entries.map(e=>e.file).sort(),'ARCHIVE_FILE_SET_MISMATCH');
 for(const e of manifest.entries) {
  assert.equal(e.path,`supabase/archive/aud003/migrations/${e.file}`);
  const bytes=await readFile(path.join(root,e.path));
  assert.equal(hash(bytes),e.sha256,`ARCHIVE_BYTES_CHANGED:${e.file}`);
  assert.equal(bytes.length,e.bytes);
  const mapped=provenance.localFiles.find(x=>x.file===e.file);
  assert.ok(mapped && !mapped.auditMigration && mapped.sourceSha256===e.sha256 && mapped.path===e.path,'ARCHIVE_PROVENANCE_MISMATCH');
 }
 assert.equal(provenance.localFiles.length,233);
 assert.equal(provenance.liveRows.length,256);
 assert.equal(capture.ledger.count,256);
 assert.equal(new Set(provenance.localFiles.map(x=>x.file)).size,233);
 assert.equal(new Set(provenance.liveRows.map(x=>x.version)).size,256);
 assert.deepEqual(provenance.liveRows.map(({version,sql_sha256,canonical_sql_sha256})=>({version,sql_sha256,canonical_sql_sha256})),capture.ledger.rows.map(({version,sql_sha256,canonical_sql_sha256})=>({version,sql_sha256,canonical_sql_sha256})),'LIVE_PROVENANCE_MISMATCH');
 const active=(await readdir(path.join(root,'supabase/migrations'))).filter(x=>x.endsWith('.sql')).sort();
 assert.deepEqual(active,[path.basename(provenance.baseline),...provenance.localFiles.filter(x=>x.auditMigration).map(x=>x.file)].sort(),'ACTIVE_FILE_SET_MISMATCH');
 assert.equal(hash(await readFile(path.join(root,provenance.baseline))),provenance.baselineSha256,'BASELINE_HASH_MISMATCH');
 for(const audit of provenance.localFiles.filter(x=>x.auditMigration)) {
  const bytes=Buffer.from((await readFile(path.join(root,audit.path),'utf8')).replaceAll('\r\n','\n'));
  assert.equal(hash(bytes),audit.sourceCanonicalSha256,`AUDIT_MIGRATION_CHANGED:${audit.file}`);
 }
 return {archived:manifest.entries.length,active:active.length,liveRows:provenance.liveRows.length};
}
