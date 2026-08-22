import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migrationUrl = new URL(
  "../supabase/migrations/20260822083354_b4f164_overtime_policy_validation.sql",
  import.meta.url,
);

test("B4F-164 enforces the same overtime policy at the SQL validation boundary", async () => {
  const [migration, validator] = await Promise.all([
    readFile(migrationUrl, "utf8"),
    readFile(
      new URL("../solver/src/grafik_solver/validator.py", import.meta.url),
      "utf8",
    ),
  ]);

  assert.match(migration, /validate_variant_before_b4f164_overtime_policy_uat_v1/);
  assert.match(migration, /OVERTIME_POLICY_LIMIT:%:%:%:%/);
  assert.match(migration, /externalAssignments/);
  assert.match(migration, /policy='NEVER'/);
  assert.match(migration, /policy='APPROVAL_REQUIRED'/);
  assert.match(migration, /overtimeDecision'='LEADER_APPROVED'/);
  assert.match(migration, /projectedMonthlyMinutes/);
  assert.doesNotMatch(migration, /bdybebzvzapihjdauehg/);

  assert.match(validator, /employee\.overtime_policy != "ALLOWED"/);
  assert.match(validator, /OVERTIME_POLICY_LIMIT:/);
});

test("B4F-164 leader approval is persisted before a final full-variant validation", async () => {
  const migration = await readFile(migrationUrl, "utf8");

  assert.match(migration, /p_approve_overtime boolean default false/);
  assert.match(migration, /LEADER_OVERTIME_APPROVAL_REQUIRED/);
  assert.match(migration, /b4f164_overtime_approval_employee/);
  assert.match(migration, /'overtimeDecision'.*'LEADER_APPROVED'/s);
  assert.match(migration, /v_validation:=solver_private\.validate_variant_v2/);
  assert.match(migration, /APPROVE_OVERTIME/);
  assert.match(migration, /overtimeApprovalAssignmentId/);
});
