import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import test from "node:test";

const migration=readFileSync("supabase/archive/aud003/migrations/20260822220000_b4f169_deterministic_fairness_quality_gate.sql","utf8");
const models=readFileSync("solver/src/grafik_solver/models.py","utf8");
const lifecycle=readFileSync("solver/src/grafik_solver/lifecycle.py","utf8");
const engine=readFileSync("solver/src/grafik_solver/cp_sat_engine.py","utf8");
const ui=readFileSync("lib/solver-v2.ts","utf8");
const sqlContract=readFileSync("supabase/tests/b4f169_fairness_quality_gate_contract.sql","utf8");

test("B4F-169 derives the default seed from the complete business snapshot, not runId",()=>{
  assert.match(migration,/build_snapshot_payload_before_b4f169/);
  assert.match(migration,/v_seed_document:=v_snapshot-'runId'/);
  assert.match(migration,/item\.value-'randomSeed'/);
  assert.match(migration,/BUSINESS_SNAPSHOT_B4F169_V1/);
  assert.doesNotMatch(migration,/hashtextextended\(p_run_id::text/);
  assert.match(sqlContract,/v_seed_document\\s\*:=\\s\*v_snapshot/);
});

test("historical Matrix v21 retains the originally published 70 percent and 30 p.p. gate",()=>{
  assert.match(migration,/'strategySemanticsVersion','B4F169_V1'/);
  assert.match(migration,/'FAIRNESS_QUALITY_GATE'/);
  assert.match(migration,/'minimumEstimatedAchievableTargetUtilizationBps',700/);
  assert.match(migration,/'maximumEstimatedAchievableTargetUtilizationSpreadBps',300/);
  assert.match(migration,/'maxAttempts',3/);
  assert.match(migration,/B4F169_HISTORICAL_MATRIX_CONTENT_CHANGED/);
  assert.doesNotMatch(migration,/perform solver_private\.apply_strategy_semantics_b4f168\(p_matrix_version_id\)/);
  assert.match(migration,/perform solver_private\.validate_strategy_semantics_b4f168/);
  assert.match(engine,/PREVIOUS_STRATEGY_SEMANTICS_VERSION = "B4F169_V1"/);
  assert.match(models,/"fairnessQualityGate"/);
});

test("current worker keeps deterministic retries but no longer turns a quality miss into failure",()=>{
  assert.match(lifecycle,/_FAIRNESS_RETRY_SEED_STEP = 104_729/);
  assert.match(lifecycle,/for attempt_index in range\(target\.max_attempts\)/);
  assert.match(lifecycle,/best_valid/);
  assert.doesNotMatch(lifecycle,/raise FairnessQualityGateFailed/);
  assert.doesNotMatch(lifecycle,/return False, "FAIRNESS_QUALITY_GATE_FAILED"/);
  assert.match(lifecycle,/"FAIRNESS_TARGET_MET": int\(target_met\)/);
  assert.match(ui,/wycofaną, blokującą bramkę jakości fairness/);
});
