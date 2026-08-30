import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const preflight = readFileSync('docs/PHASE4A2C_UAT_READ_ONLY_PREFLIGHT.sql', 'utf8');
const snapshot = readFileSync('docs/PHASE4A2C_UAT_EXISTING_SECURITY_SNAPSHOT.sql', 'utf8');
const contract = readFileSync('supabase/tests/phase4a2c_existing_uat_hosted_contract.sql', 'utf8');
const runbook = readFileSync('docs/PHASE4A2C_EXISTING_UAT_DEPLOYMENT_GATE_2026-08-30.md', 'utf8');

test('preflight is SELECT-only and pins exact UAT identity', () => {
  const scrubbed = preflight.replace(/^\s*--.*$/gm, '');
  assert.match(preflight, /nhthrtpkfpmufmrmdyjg/);
  assert.match(preflight, /ISOLATED_UAT_DESTRUCTIVE_TOOLS/);
  assert.match(preflight, /GO — PHASE4A2C UAT PREFLIGHT/);
  assert.doesNotMatch(scrubbed, /\b(insert|update|delete|create|alter|drop|grant|revoke|truncate|call|do)\b/i);
  assert.match(scrubbed.trim(), /^with\b/i);
  assert.equal((scrubbed.match(/;\s*$/g) ?? []).length, 1);
});

test('preflight pins ledger, Matrix and legacy default ACL', () => {
  assert.match(preflight, /count\(\*\) = 254/);
  assert.match(preflight, /04c5c2ad59937027420bd7c71b782d14/);
  assert.match(preflight, /20260830180000/);
  assert.match(preflight, /count\(\*\) = 29/);
  assert.match(preflight, /c86785623e746bdaf24fabcb75b2a6019385b230830284d851ec27ad030933a3/);
  assert.match(preflight, /workforce_count = 86/);
});

test('hosted contract is transaction-bound and identity pinned', () => {
  assert.match(contract, /^begin;/);
  assert.match(contract, /rollback;\s*$/);
  assert.match(contract, /nhthrtpkfpmufmrmdyjg/);
  assert.match(contract, /ISOLATED_UAT/);
  assert.doesNotMatch(contract, /bdybebzvzapihjdauehg/);
  assert.match(contract, /v_ledger_count <> 255/);
});

test('hosted contract requires exact hardened fingerprint', () => {
  assert.match(contract, /v_count <> 27/);
  assert.match(contract, /octet_length\(v_payload\) <> 2708/);
  assert.match(contract, /1f690d52941e6a5865cb59919ded58fa087f2e594215836bd33a78a1141ae9ff/);
  assert.match(contract, /GLOBAL_ROUTINE_ACL_INVALID/);
  assert.match(contract, /DEFAULT_ACL_NOT_HARDENED/);
});

test('security snapshot is SELECT-only, canonical and fail-closed', () => {
  const scrubbed = snapshot.replace(/^\s*--.*$/gm, '');
  assert.doesNotMatch(scrubbed, /\b(insert|update|delete|create|alter|drop|grant|revoke|truncate|call|do)\b/i);
  assert.match(snapshot, /relation_acl/);
  assert.match(snapshot, /routine_acl/);
  assert.match(snapshot, /rls\|/);
  assert.match(snapshot, /policy\|/);
  assert.match(snapshot, /record_count = 3623/);
  assert.match(snapshot, /337074/);
  assert.match(snapshot, /5166ef241ec5b86a22eeb72c4ee62bca8d5da66efdae6fecbc1c9c1883e10185/);
  assert.match(snapshot, /STOP — EXISTING ACL, RLS, OR POLICY STATE CHANGED/);
});

test('hosted contract pins the unchanged existing security state', () => {
  assert.match(contract, /v_count <> 3623/);
  assert.match(contract, /octet_length\(v_payload\) <> 337074/);
  assert.match(contract, /5166ef241ec5b86a22eeb72c4ee62bca8d5da66efdae6fecbc1c9c1883e10185/);
  assert.match(contract, /EXISTING_SECURITY_STATE_CHANGED/);
});

test('hosted contract checks all four rollback-only canaries', () => {
  for (const marker of ['probe_table', 'probe_sequence', 'probe_invoker', 'probe_definer']) {
    assert.match(contract, new RegExp(`phase4a2c_uat_${marker}`));
  }
  assert.match(contract, /DEFAULT_DENY_FAILED/);
  assert.match(contract, /OWNER_RIGHTS_MISSING/);
  assert.match(contract, /DEFINER_CANARY_INVALID/);
});

test('runbook requires separate authorization and forward-only repair', () => {
  assert.match(runbook, /explicit user authorization/i);
  assert.match(runbook, /forward-only repair migration/i);
  assert.match(runbook, /do not edit or delete the applied ledger row/i);
  assert.match(runbook, /NO ACCESS \/ NO MUTATION/);
  assert.match(runbook, /NO DML/);
  assert.match(runbook, /ZERO REQUIRED/);
});
