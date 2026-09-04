import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migration = await readFile(
  new URL(
    "../supabase/migrations/20260905100000_aud015_consolidate_permissive_policies.sql",
    import.meta.url,
  ),
  "utf8",
);

const expectedTables = [
  "employee_availability",
  "employee_hr_profiles",
  "employee_pay_rates_v2",
  "matrix_duties_v2",
  "matrix_employee_duties_v2",
  "matrix_employee_locations_v2",
  "matrix_employee_roles_v2",
  "matrix_locations_v2",
  "matrix_pay_rule_duties_v2",
  "matrix_pay_rule_locations_v2",
  "matrix_pay_rule_roles_v2",
  "matrix_pay_rule_shifts_v2",
  "matrix_pay_rules_v2",
  "matrix_role_duties_v2",
  "matrix_roles_v2",
  "matrix_scenario_budgets_v2",
  "matrix_scenario_pay_rule_overrides_v2",
  "matrix_scenario_strategies_v2",
  "matrix_scenarios_v2",
  "matrix_scope_grants_v2",
  "matrix_shift_templates_v2",
  "matrix_staffing_rules_v2",
  "matrix_strategies_v2",
  "matrix_strategy_objectives_v2",
  "monthly_budgets",
  "operational_events",
  "solver_feature_flags",
].sort();

test("AUD-015 consolidates exactly the 27 UAT advisor overlaps", () => {
  const altered = [...migration.matchAll(
    /alter policy "[^"]+" on "public"\."([^"]+)"/giu,
  )].map((match) => match[1]).sort();
  assert.deepEqual(altered, expectedTables);

  const dropped = [...migration.matchAll(
    /drop policy "[^"]+" on "public"\."([^"]+)"/giu,
  )].map((match) => match[1]).sort();
  assert.deepEqual(dropped, expectedTables);
});

test("AUD-015 preserves the old SELECT union and splits only write commands", () => {
  const altered = [...migration.matchAll(
    /alter policy[\s\S]*?\n\s+using \(\(([\s\S]*?)\) or \(([\s\S]*?)\)\);/giu,
  )];
  assert.equal(altered.length, expectedTables.length);
  assert.ok(altered.every((match) => match[1].trim() && match[2].trim()));

  for (const command of ["insert", "update", "delete"]) {
    const created = [...migration.matchAll(
      new RegExp(`create policy "[^"]+_${command}" on "public"\\."([^"]+)"`, "giu"),
    )].map((match) => match[1]).sort();
    assert.deepEqual(created, expectedTables);
  }
  assert.doesNotMatch(migration, /create policy[\s\S]*?\bfor all\b/iu);
});

test("AUD-015 keeps role and RLS boundaries explicit", () => {
  assert.equal(
    [...migration.matchAll(/create policy /giu)].length,
    expectedTables.length * 3,
  );
  assert.equal(
    [...migration.matchAll(/\bto "authenticated"/giu)].length,
    expectedTables.length * 3,
  );
  assert.doesNotMatch(
    migration,
    /\b(?:disable row level security|grant|revoke|alter table)\b/iu,
  );
  const withoutOptimizedCalls = migration.replace(
    /\(\s*select\s+auth\.uid\(\)(?:\s+as\s+[a-z0-9_]+)?\s*\)/giu,
    "",
  );
  assert.doesNotMatch(withoutOptimizedCalls, /auth\.uid\(\)/iu);
});
