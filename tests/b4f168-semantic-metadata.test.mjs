import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { OBJECTIVE_METRICS } from "../lib/matrix-v2.ts";
import {
  STRATEGY_SEMANTICS_VERSION,
  SUPPORTED_STRATEGY_SEMANTICS_VERSIONS,
} from "../lib/solver-strategy-contract.ts";

const migrationUrl = new URL(
  "../supabase/archive/aud003/migrations/20260822200000_b4f168_remove_obsolete_solver_metadata.sql",
  import.meta.url,
);
const stampMigrationUrl = new URL(
  "../supabase/archive/aud003/migrations/20260822203000_b4f168_database_stamp.sql",
  import.meta.url,
);

test("B4F-168 publishes a new semantic contract without mutating history", async () => {
  const migration = await readFile(migrationUrl, "utf8");

  assert.equal(STRATEGY_SEMANTICS_VERSION, "B4F170_V1");
  assert.deepEqual(SUPPORTED_STRATEGY_SEMANTICS_VERSIONS, [
    "B4F165_V1",
    "B4F168_V1",
    "B4F169_V1",
    "B4F170_V1",
  ]);
  assert.match(migration, /apply_strategy_semantics_b4f168/);
  assert.match(migration, /delete from public\.matrix_strategy_objectives_v2/);
  assert.match(migration, /metric_code='HOME_LOCATION_VIOLATIONS'/);
  assert.match(migration, /B4F168_HISTORICAL_MATRIX_CONTENT_CHANGED/);
  assert.match(migration, /matrix_v2_content_document\(v_prior\.id\)/);
  assert.doesNotMatch(migration, /bdybebzvzapihjdauehg/);
});

test("B4F-168 advances the database stamp without changing solver results", async () => {
  const migration = await readFile(stampMigrationUrl, "utf8");

  assert.match(migration, /solver_save_variant_before_b4f168/);
  assert.match(migration, /20260822203000_b4f168_database_stamp/);
  assert.match(migration, /strategySemanticsVersion'='B4F168_V1'/);
  assert.match(migration, /set version_stamp=jsonb_set/);
  assert.doesNotMatch(migration, /stage_proof\s*=/);
  assert.doesNotMatch(migration, /update public\.plan_assignments/);
  assert.doesNotMatch(migration, /bdybebzvzapihjdauehg/);
});

test("B4F-168 new Matrix authoring cannot select the obsolete objective", () => {
  assert.equal(
    OBJECTIVE_METRICS.some(item => item.value === "HOME_LOCATION_VIOLATIONS"),
    false,
  );
});

test("B4F-168 fairness regression references the canonical B4F-159 ID", async () => {
  const [uiTest, solverTest] = await Promise.all([
    readFile(new URL("./b4f159-fairness-ui.test.mjs", import.meta.url), "utf8"),
    readFile(new URL("../solver/tests/test_solver.py", import.meta.url), "utf8"),
  ]);

  assert.match(uiTest, /B4F-159 fairness-first/);
  assert.match(solverTest, /B4F-159 A: no preferences/);
  assert.doesNotMatch(uiTest, /B4F-119 fairness-first/);
  assert.doesNotMatch(solverTest, /B4F-119 A: no preferences/);
});
