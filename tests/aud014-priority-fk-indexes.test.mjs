import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migration = await readFile(
  new URL(
    "../supabase/migrations/20260905110000_aud014_priority_foreign_key_indexes.sql",
    import.meta.url,
  ),
  "utf8",
);

const expected = new Map([
  ["matrix_employee_profiles_v2_employee_id_fk_idx", ["matrix_employee_profiles_v2", "employee_id"]],
  ["matrix_roles_v2_category_fk_idx", ["matrix_roles_v2", "matrix_version_id, category_id"]],
  ["matrix_staffing_rules_v2_role_fk_idx", ["matrix_staffing_rules_v2", "matrix_version_id, role_id"]],
  ["matrix_staffing_rules_v2_duty_fk_idx", ["matrix_staffing_rules_v2", "matrix_version_id, duty_id"]],
  ["matrix_strategy_objectives_v2_strategy_fk_idx", ["matrix_strategy_objectives_v2", "matrix_version_id, strategy_id"]],
]);

test("AUD-014 adds exactly the five prioritized covering indexes", () => {
  const actual = new Map([...migration.matchAll(
    /create index if not exists ([a-z0-9_]+)\s+on public\.([a-z0-9_]+) \(([^)]+)\);/giu,
  )].map((match) => [match[1], [match[2], match[3]]]));
  assert.deepEqual(actual, expected);
});

test("AUD-014 is index-only and leaves constraints, RLS and data untouched", () => {
  assert.doesNotMatch(
    migration,
    /\b(?:insert|update|delete|alter table|drop|policy|grant|revoke)\b/iu,
  );
});
