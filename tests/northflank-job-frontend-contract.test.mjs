import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  parseSolverVersionStamp,
  solverPhaseLabel,
  solverStatusLabel,
} from "../lib/solver-v2.ts";

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

const stamp = {
  schemaVersion: 1,
  frontendCommit: "uat-build-1",
  solverCommit: "86522fe6d701a14a5a2ec90d999f385739a4f212",
  solverImageDigest: null,
  solverBuildId: "difficult-price-5668",
  gatewayVersion: "solver-gateway-v14",
  strategyConfigVersion:
    "8a5b8979d0e26ec4c0dbcaaf267a6362b69d92a1b0cc2f854447a73fe71ab885",
  databaseMigrationVersion: "20260824163743_uat_northflank_job_runtime",
  snapshotSchemaVersion: 2,
  executionMode: "JOB",
  northflankRunId: "northflank-run-1",
  dispatcherVersion: "solver-job-dispatcher-v1",
};

test("frontend parses every immutable version-stamp field", () => {
  assert.deepEqual(parseSolverVersionStamp(stamp), stamp);
  assert.equal(parseSolverVersionStamp({}), null);
});

test("frontend fails closed on a changed or incomplete version-stamp contract", () => {
  assert.throws(
    () => parseSolverVersionStamp({ ...stamp, solverBuildId: undefined }),
    /SOLVER_VERSION_STAMP_SOLVERBUILDID_INVALID/u,
  );
  assert.throws(
    () => parseSolverVersionStamp({ ...stamp, executionMode: "SERVERLESS" }),
    /SOLVER_VERSION_STAMP_EXECUTIONMODE_INVALID/u,
  );
  assert.throws(
    () => parseSolverVersionStamp({ ...stamp, strategyConfigVersion: "not-a-hash" }),
    /SOLVER_VERSION_STAMP_STRATEGYCONFIGVERSION_INVALID/u,
  );
});

test("frontend remains backward compatible with the historical nested stamp", () => {
  assert.equal(parseSolverVersionStamp({
    frontend: { buildId: "legacy-uat" },
    solver: { workerVersion: "ORTOOLS_V2_2026_08_02" },
    gateway: { deploymentId: "solver-gateway-v13" },
  }), null);
});

test("Job lifecycle has user-readable labels without a direct Northflank client", () => {
  assert.equal(
    solverPhaseLabel("DISPATCH_PENDING"),
    "Oczekiwanie na wolne miejsce do uruchomienia",
  );
  assert.equal(
    solverPhaseLabel("DISPATCH_UNCERTAIN"),
    "Sprawdzanie, czy zadanie zostało przyjęte",
  );
  assert.equal(
    solverStatusLabel("GENERATING"),
    "Trwa układanie grafiku",
  );
  const frontend = read("lib/solver-v2.ts");
  const panel = read("components/SolverV2Panel.tsx");
  assert.doesNotMatch(frontend, /api\.northflank\.com/iu);
  assert.doesNotMatch(frontend, /NORTHFLANK_SOLVER_JOB_API_TOKEN/u);
  assert.doesNotMatch(panel, /api\.northflank\.com/iu);
  assert.doesNotMatch(panel, /NORTHFLANK_SOLVER_JOB_API_TOKEN/u);
});
