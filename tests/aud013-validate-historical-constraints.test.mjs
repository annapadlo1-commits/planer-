import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const sql = await readFile(new URL(
  "../supabase/migrations/20260903120000_aud013_validate_historical_constraints.sql",
  import.meta.url,
), "utf8").catch(() => "");

test("AUD-013 preflights and validates exactly both historical constraints", () => {
  assert.match(sql, /nhthrtpkfpmufmrmdyjg/u);
  for (const name of [
    "matrix_employee_roles_v2_primary_or_fallback_check",
    "matrix_staffing_active_set_positive_uat006",
  ]) {
    assert.match(sql, new RegExp(`validate constraint ${name}`, "iu"));
    assert.match(sql, new RegExp(`conname\\s*=\\s*'${name}'`, "iu"));
  }
  assert.match(sql, /AUD013_ROLE_SEMANTICS_VIOLATIONS/u);
  assert.match(sql, /AUD013_STAFFING_RULE_VIOLATIONS/u);
  assert.match(sql, /AUD013_CONSTRAINT_VALIDATION_INCOMPLETE/u);
});

test("AUD-013 migration does not rewrite historical rows", () => {
  const executable = sql
    .replace(/\/\*[\s\S]*?\*\//gu, "")
    .replace(/^\s*--.*$/gmu, "");
  assert.doesNotMatch(executable, /\b(?:insert|update|delete|merge|truncate)\b/iu);
});
