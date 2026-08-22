import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  DEFAULT_STRATEGY_DESCRIPTIONS,
  MANDATORY_PRODUCT_GUARDS,
  STRATEGY_SEMANTICS_VERSION,
} from "../lib/solver-strategy-contract.ts";

const migrationUrl = new URL(
  "../supabase/migrations/20260822160000_b4f165_strategy_source_of_truth.sql",
  import.meta.url,
);

test("B4F-165 publishes one explicit strategy contract and protects history", async () => {
  const migration = await readFile(migrationUrl, "utf8");

  assert.equal(STRATEGY_SEMANTICS_VERSION, "B4F165_V1");
  assert.deepEqual(MANDATORY_PRODUCT_GUARDS, [
    "HARD_CONSTRAINTS",
    "COVERAGE",
    "ROLE_BACKUP",
    "OVERTIME",
    "ZERO_HOURS",
    "PRIMARY_ROLE",
    "MAX_MIN_FAIRNESS",
    "FAIRNESS_SPREAD",
  ]);
  for (const description of Object.values(DEFAULT_STRATEGY_DESCRIPTIONS)) {
    assert.match(migration, new RegExp(description.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  }
  assert.match(migration, /validate_strategy_semantics_b4f165/);
  assert.match(migration, /STRATEGY_SEMANTICS_MISMATCH/);
  assert.match(migration, /B4F165_HISTORICAL_MATRIX_CONTENT_CHANGED/);
  assert.match(migration, /matrix_v2_content_document\(v_prior\.id\)/);
  assert.doesNotMatch(migration, /bdybebzvzapihjdauehg/);
});

test("B4F-165 UI uses Matrix descriptions and shows mandatory guards", async () => {
  const [panel, engine, presentation] = await Promise.all([
    readFile(new URL("../components/SolverV2Panel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../solver/src/grafik_solver/cp_sat_engine.py", import.meta.url), "utf8"),
    readFile(new URL("../lib/solver-variant-presentation.ts", import.meta.url), "utf8"),
  ]);

  assert.match(panel, /MANDATORY_PRODUCT_GUARDS_LABEL/);
  assert.doesNotMatch(panel, /PREFERENCES_FAIRNESS_DESCRIPTION/);
  assert.match(panel, /strategy\.description\?\.trim\(\)/);
  assert.doesNotMatch(engine, /effective_objective_tier/);
  assert.match(engine, /MATRIX_RUNTIME_SEMANTICS_MATCH/);
  assert.match(presentation, /Potwierdzona/);
});
