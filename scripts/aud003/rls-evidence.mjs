import assert from 'node:assert/strict';

// Counts are assertion groups, not individual boolean operands or setup checks.
// A group containing OR is counted once, and emits only after all checks hold.
export const expectedCounts = Object.freeze({ROLE_X:9,LOCATION_A:6,ROLE_Y:1,
  LOCATION_B:4,EMPLOYEE_A:4,EMPLOYEE_B:2,OWNER:2,ADMIN:2,NO_ROLE:6,ANON:1});
export function verifyRlsEvidence(sql, log, exitCode) {
  assert.equal(exitCode,0,'RLS_SQL_EXECUTION_FAILED');
  const expected=[...sql.matchAll(/raise notice 'RLS_ASSERT\|([A-Z_]+)\|(PHASE4A_[A-Z0-9_]+)'/gu)]
    .map(m=>`${m[1]}|${m[2]}`);
  const actual=[...log.matchAll(/NOTICE:\s+RLS_ASSERT\|([A-Z_]+)\|(PHASE4A_[A-Z0-9_]+)/gu)]
    .map(m=>`${m[1]}|${m[2]}`);
  assert.equal(new Set(expected).size,expected.length,'DUPLICATE_EXPECTED_ASSERTION');
  assert.deepEqual(actual,expected,'RLS_ASSERTION_MISSING_EXTRA_OR_REORDERED');
  const counts={};
  for(const key of actual){const actor=key.split('|')[0];counts[actor]=(counts[actor]??0)+1;}
  assert.deepEqual(counts,expectedCounts,'RLS_COVERAGE_CHANGED');
  const contexts=[...log.matchAll(/NOTICE:\s+RLS_CONTEXT\|([A-Z_]+)\|(\w+)/gu)];
  for(const actor of Object.keys(expectedCounts)) {
    assert.ok(contexts.some(m=>m[1]===actor),'MISSING_ROLE_CONTEXT');
    assert.ok(contexts.filter(m=>m[1]===actor).every(m=>m[2]===(actor==='ANON'?'anon':'authenticated')),'PRIVILEGED_ACTOR');
  }
  return {assertionGroups:actual.length,counts,contexts:contexts.length,assertions:actual,
    tenantIsolation:'BLOCKED: AUD-008 / B4F-175; locations and versions are not tenants'};
}
