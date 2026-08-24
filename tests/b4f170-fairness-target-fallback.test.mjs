import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const files = await Promise.all([
  readFile("supabase/migrations/20260824160525_b4f170_fairness_target_best_valid_fallback.sql", "utf8"),
  readFile("solver/src/grafik_solver/lifecycle.py", "utf8"),
  readFile("solver/src/grafik_solver/models.py", "utf8"),
  readFile("solver/src/grafik_solver/cp_sat_engine.py", "utf8"),
  readFile("lib/solver-v2.ts", "utf8"),
  readFile("components/SolverV2Panel.tsx", "utf8"),
  readFile("supabase/functions/solver-gateway/contract.test.mjs", "utf8"),
  readFile("supabase/tests/b4f170_fairness_target_fallback_contract.sql", "utf8"),
]);

const [migration, lifecycle, models, engine, client, panel, gatewayTest, sqlContract] = files;

test("B4F-170 publishes Matrix v22 with a soft 70 percent and 30 p.p. target", () => {
  assert.match(migration, /'strategySemanticsVersion','B4F170_V1'/u);
  assert.match(migration, /'FAIRNESS_QUALITY_TARGET'/u);
  assert.match(migration, /'fairnessQualityTarget',jsonb_build_object/u);
  assert.match(migration, /'minimumEstimatedAchievableTargetUtilizationBps',700/u);
  assert.match(migration, /'maximumEstimatedAchievableTargetUtilizationSpreadBps',300/u);
  assert.match(migration, /'maxAttempts',3/u);
  assert.match(migration, /B4F170_HISTORICAL_MATRIX_CONTENT_CHANGED/u);
  assert.match(engine, /STRATEGY_SEMANTICS_VERSION = "B4F170_V1"/u);
  assert.match(models, /class FairnessQualityTarget/u);
});

test("all misses return the best verified incumbent instead of failing the run", () => {
  assert.match(lifecycle, /best_valid/u);
  assert.match(lifecycle, /return self\._with_quality_audit\(/u);
  assert.match(lifecycle, /"FAIRNESS_TARGET_MET": int\(target_met\)/u);
  assert.match(lifecycle, /"FAIRNESS_TARGET_FALLBACK_USED"/u);
  assert.match(lifecycle, /except OptimizationIncomplete/u);
  assert.doesNotMatch(lifecycle, /raise FairnessQualityGateFailed/u);
  assert.doesNotMatch(lifecycle, /return False, "FAIRNESS_QUALITY_GATE_FAILED"/u);
});

test("gateway, database, normalizer and UI preserve a non-blocking warning", () => {
  assert.match(gatewayTest, /fairness quality target was not met/u);
  assert.match(sqlContract, /FINALIZATION_MUST_ONLY_REQUIRE_VALID_VARIANTS/u);
  assert.match(sqlContract, /''metrics'',variant\.metrics/u);
  assert.match(client, /normalizeFairnessTarget/u);
  assert.match(client, /failureReasons/u);
  assert.match(panel, /Nie udało się osiągnąć docelowego poziomu wyrównania/u);
  assert.match(panel, /Pokazujemy najlepszy znaleziony legalny układ/u);
  assert.match(panel, /Docelowy poziom nie był możliwy do osiągnięcia/u);
});
