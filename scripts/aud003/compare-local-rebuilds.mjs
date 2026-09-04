import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';

const [leftPath, rightPath, outputPath] = process.argv.slice(2);
assert.ok(leftPath && rightPath && outputPath, 'TWO_LOCAL_CATALOGS_AND_OUTPUT_REQUIRED');

function normalized(catalog) {
  assert.equal(catalog.localProject, 'aud003-local-db-20260903');
  assert.equal(catalog.projectRef, null);
  const copy = structuredClone(catalog);
  delete copy.capturedAtUtc;
  return copy;
}

function sha256(value) {
  return createHash('sha256').update(JSON.stringify(value)).digest('hex');
}

const left = normalized(JSON.parse(await readFile(leftPath, 'utf8')));
const right = normalized(JSON.parse(await readFile(rightPath, 'utf8')));
const leftSha256 = sha256(left);
const rightSha256 = sha256(right);
const matched = leftSha256 === rightSha256;
await writeFile(outputPath, `${JSON.stringify({
  format: 'aud003-local-rebuild-determinism-v1',
  left: leftPath,
  right: rightPath,
  normalization: ['capturedAtUtc removed; every other catalog field compared byte-for-byte after JSON parsing'],
  leftSha256,
  rightSha256,
  matched,
}, null, 2)}\n`);
assert.ok(matched, 'LOCAL_REBUILDS_DIFFER');
process.stdout.write(`LOCAL_REBUILDS_MATCHED ${leftSha256}\n`);
