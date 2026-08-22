import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import test from "node:test";

const migration=readFileSync("supabase/migrations/20260822220000_b4f169_deterministic_fairness_quality_gate.sql","utf8");
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

test("Matrix v21 declares the approved 70 percent and 30 p.p. fairness gate",()=>{
  assert.match(migration,/'strategySemanticsVersion','B4F169_V1'/);
  assert.match(migration,/'FAIRNESS_QUALITY_GATE'/);
  assert.match(migration,/'minimumEstimatedAchievableTargetUtilizationBps',700/);
  assert.match(migration,/'maximumEstimatedAchievableTargetUtilizationSpreadBps',300/);
  assert.match(migration,/'maxAttempts',3/);
  assert.match(migration,/B4F169_HISTORICAL_MATRIX_CONTENT_CHANGED/);
  assert.doesNotMatch(migration,/perform solver_private\.apply_strategy_semantics_b4f168\(p_matrix_version_id\)/);
  assert.match(migration,/perform solver_private\.validate_strategy_semantics_b4f168/);
  assert.match(engine,/STRATEGY_SEMANTICS_VERSION = "B4F169_V1"/);
  assert.match(models,/class FairnessQualityGate/);
});

test("worker retries deterministically and a missed gate has a dedicated non-ready error",()=>{
  assert.match(lifecycle,/_FAIRNESS_RETRY_SEED_STEP = 104_729/);
  assert.match(lifecycle,/for attempt_index in range\(gate\.max_attempts\)/);
  assert.match(lifecycle,/raise FairnessQualityGateFailed/);
  assert.match(lifecycle,/return False, "FAIRNESS_QUALITY_GATE_FAILED"/);
  assert.match(lifecycle,/"FAIRNESS_QUALITY_GATE_PASSED": 1/);
  assert.match(ui,/po trzech kontrolowanych próbach/);
  assert.match(ui,/najwyżej 30 p\.p\. rozstępu/);
});
