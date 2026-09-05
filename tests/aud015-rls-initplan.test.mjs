import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migration = await readFile(
  new URL(
    "../supabase/migrations/20260903095601_aud015_optimize_confirmed_rls_initplans.sql",
    import.meta.url,
  ),
  "utf8",
);

const statements = migration
  .replace(/--[^\n]*(?:\n|$)/gu, " ")
  .split(";")
  .map(statement => statement.trim())
  .filter(Boolean);

const expectedPolicies = new Map([
  ["employee_reads_own_assignments", "public.assignments"],
  ["employee_reads_own_attendance", "public.attendance_events"],
  ["availability_manage", "public.employee_availability"],
  ["availability_read", "public.employee_availability"],
  ["availability_history_read", "public.employee_availability_history"],
  ["authenticated_reads_employee_capabilities", "public.employee_capabilities"],
  ["hr_read", "public.employee_hr_profiles"],
  ["authenticated_reads_employee_locations", "public.employee_locations"],
  ["employee_reads_self", "public.employees"],
  ["user_reads_own_tasks", "public.tasks"],
  ["users_read_own_permissions", "public.user_permissions"],
]);

test("AUD-015 alters exactly the eleven advisor-confirmed policies", () => {
  assert.equal(statements.length, expectedPolicies.size);

  const actual = new Map(statements.map(statement => {
    const match = statement.match(
      /^alter policy ([a-z0-9_]+) on (public\.[a-z0-9_]+)\s/iu,
    );
    assert.ok(match, `unexpected migration statement: ${statement}`);
    return [match[1], match[2]];
  }));

  assert.deepEqual(actual, expectedPolicies);
});

test("AUD-015 changes predicates only and preserves the policy boundary", () => {
  assert.ok(statements.every(statement => /^alter policy\b/iu.test(statement)));
  assert.ok(statements.every(statement => /\busing\s*\(/iu.test(statement)));
  assert.doesNotMatch(
    migration,
    /\b(?:create|drop)\s+policy\b|\b(?:grant|revoke)\b|\bto\s+(?:public|anon|authenticated|service_role)\b/iu,
  );

  const availabilityManage = statements.find(statement =>
    /^alter policy availability_manage\b/iu.test(statement));
  assert.match(availabilityManage, /\bwith check\s*\(/iu);
  assert.ok(statements
    .filter(statement => !/^alter policy availability_manage\b/iu.test(statement))
    .every(statement => !/\bwith check\b/iu.test(statement)));
});

test("AUD-015 evaluates auth.uid once per statement instead of once per row", () => {
  const optimized = /\(\s*select\s+auth\.uid\(\)\s*\)/iu;
  assert.ok(statements.every(statement => optimized.test(statement)));

  const withoutOptimizedCalls = migration
    .replace(/--[^\n]*(?:\n|$)/gu, " ")
    .replace(
    /\(\s*select\s+auth\.uid\(\)\s*\)/giu,
    "",
    );
  assert.doesNotMatch(withoutOptimizedCalls, /auth\.uid\(\)/iu);
});
