import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';

const sourceSha = '92bc2c8bcbba780d251f5a37a7e56767ecdb6386';
const projectRef = 'nhthrtpkfpmufmrmdyjg';
const outputDir = 'supabase/baseline/aud003';
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const canonical = bytes => Buffer.from(bytes.toString('utf8').replaceAll('\r\n', '\n'), 'utf8');
const git = process.env.AUD003_GIT_BINARY || 'git';
const capture = JSON.parse(await readFile(path.join(outputDir, 'uat-catalog-2026-09-03.json'), 'utf8'));
assert.equal(capture.projectRef, projectRef);
assert.equal(capture.transactionReadOnly, 'on');
assert.equal(capture.trialMergeSha, sourceSha);
const liveByVersion = new Map(capture.ledger.rows.map(row => [row.version, row]));
assert.equal(liveByVersion.size, capture.ledger.count, 'DUPLICATE_LIVE_VERSION');
const files = (await readdir('supabase/migrations')).filter(name => name.endsWith('.sql')).sort();
const entries = [];
const versions = new Set();
for (const file of files) {
  const match = file.match(/^(\d{4}|\d{14})_([a-z0-9_]+)\.sql$/u);
  assert.ok(match, 'INVALID_MIGRATION_FILENAME');
  const [, version, name] = match;
  assert.equal(versions.has(version), false, 'DUPLICATE_SOURCE_VERSION');
  versions.add(version);
  const sourcePath = `supabase/migrations/${file}`;
  const result = spawnSync(git, ['show', `${sourceSha}:${sourcePath}`], { maxBuffer: 16 * 1024 * 1024 });
  assert.equal(result.status, 0, `MISSING_SOURCE_BLOB:${file}`);
  const sourceBytes = result.stdout;
  const worktreeBytes = await readFile(sourcePath);
  assert.deepEqual(canonical(worktreeBytes), canonical(sourceBytes), `WORKTREE_SQL_CHANGED:${file}`);
  const live = liveByVersion.get(version);
  const audit = /^20260903\d{6}_aud\d{3}_/u.test(file);
  const sourceCanonicalSha256 = sha256(canonical(sourceBytes));
  const classification = !live ? 'LOCAL_ONLY' : live.canonical_sql_sha256 === sourceCanonicalSha256 ? 'SHARED_CONTENT_MATCH' : 'SHARED_CONTENT_MISMATCH';
  entries.push({
    version, name, file, sourcePath, sourceSha, sourceBytes: sourceBytes.length,
    sourceSha256: sha256(sourceBytes), sourceCanonicalSha256,
    worktreeBytes: worktreeBytes.length, worktreeSha256: sha256(worktreeBytes),
    worktreeOnlyNewlineDifference: !worktreeBytes.equals(sourceBytes),
    classification, auditMigration: audit, live: live ?? null,
    plannedTreatment: audit ? 'KEEP_UNCHANGED_AFTER_VALIDATED_BASELINE' : 'ARCHIVE_EXACT_SOURCE_BLOB_OUTSIDE_ACTIVE_MIGRATIONS',
    baselineCoverage: audit ? 'NOT_PART_OF_PRE_AUDIT_BASELINE' : 'PENDING_LOCAL_REBUILD_AND_SEMANTIC_PROOF',
  });
}
const liveRows = capture.ledger.rows.map(row => {
  const source = entries.find(entry => entry.version === row.version);
  return { ...row, sourceFile: source?.file ?? null,
    classification: source?.classification ?? 'LIVE_ONLY',
    baselineCoverage: 'CURRENT_CATALOG_CAPTURED_REBUILD_NOT_EXECUTED',
    remoteHistoryAction: 'NONE',
  };
});
const counts = {
  localFiles: entries.length, liveLedger: liveRows.length,
  localOnly: entries.filter(x => x.classification === 'LOCAL_ONLY').length,
  liveOnly: liveRows.filter(x => x.classification === 'LIVE_ONLY').length,
  sharedVersions: entries.filter(x => x.live).length,
  sharedContentMismatch: entries.filter(x => x.classification === 'SHARED_CONTENT_MISMATCH').length,
  sharedContentMatch: entries.filter(x => x.classification === 'SHARED_CONTENT_MATCH').length,
  auditMigrations: entries.filter(x => x.auditMigration).length,
  preAuditFiles: entries.filter(x => !x.auditMigration).length,
  historicalLocalOnly: entries.filter(x => x.classification === 'LOCAL_ONLY' && !x.auditMigration).length,
};
assert.equal(counts.auditMigrations, 6);
const specialFiles = [
  '20260826220734_restore_frontend_rpc_parity.sql',
  '20260902231357_b4f180_restore_finance_visibility_after_uat_reset.sql',
].map(file => {
  const source = entries.find(row => row.file === file);
  assert.ok(source);
  return { sourceFile: file, sourceVersion: source.version, sourceSha256: source.sourceSha256,
    sameNameLiveVersions: liveRows.filter(row => row.name === source.name).map(row => ({ version: row.version, sqlSha256: row.sql_sha256, canonicalSqlSha256: row.canonical_sql_sha256 })),
    sameVersion: source.classification, equivalence: 'NOT_ASSUMED_FROM_NAME_OR_TIMESTAMP',
  };
});
const report = {
  format: 'aud003-history-reconciliation-v1', status: 'PREPARATION_ONLY_REBUILD_BLOCKED',
  sourceSha, sourceUatSha: capture.sourceUatSha, projectRef,
  capturedAtUtc: capture.capturedAtUtc, ledgerSha256: capture.ledger.sha256,
  comparison: 'Exact source Git bytes and CRLF-to-LF canonical source vs ledger statements joined with LF; mismatch is content evidence, not proof of semantic inequivalence.',
  counts, specialFiles, localFiles: entries, liveRows,
};
await writeFile(path.join(outputDir, 'history-reconciliation.json'), `${JSON.stringify(report, null, 2)}\n`);
console.log(JSON.stringify({ counts, specialFiles }, null, 2));
