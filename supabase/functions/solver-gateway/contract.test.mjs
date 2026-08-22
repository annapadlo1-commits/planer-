import assert from "node:assert/strict";
import test from "node:test";

import {
  ALLOWED_ACTIONS,
  createGatewayHandler,
} from "./contract.ts";

const TOKEN = "solver-gateway-test-token".padEnd(64, "x");
const GATEWAY_VERSION = "solver-gateway-test-deployment";
const RUN_ID = "11111111-1111-4111-8111-111111111111";
const ATTEMPT_ID = "22222222-2222-4222-8222-222222222222";
const LEASE_TOKEN = "33333333-3333-4333-8333-333333333333";
const STRATEGY_ID = "44444444-4444-4444-8444-444444444444";

const claimArgs = {
  p_worker_id: "free-host-worker-1:42",
  p_worker_version: "ORTOOLS_V2_2026_08_02",
  p_task_attempt: 1,
  p_lease_seconds: 90,
};

function gatewayRequest(action, args, token = TOKEN) {
  return new Request("https://example.test/solver-gateway", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Solver-Gateway-Token": token,
    },
    body: JSON.stringify({ action, args }),
  });
}

function handlerWith(calls = []) {
  return createGatewayHandler({
    solverGatewayToken: TOKEN,
    gatewayVersion: GATEWAY_VERSION,
    invokeRpc: async (action, args) => {
      calls.push({ action, args });
      return {
        status: 200,
        body: JSON.stringify({ ok: true }),
        contentType: "application/json",
      };
    },
  });
}

function normalizedVariant() {
  return {
    schemaVersion: 2,
    strategyId: STRATEGY_ID,
    strategyCode: "COST",
    label: "Minimalny koszt",
    sortOrder: 1,
    assignments: [],
    unfilledSlotIds: [],
    metrics: { UNFILLED: 0, TOTAL_COST: 0 },
    stageObjectives: [{
      tier: 1,
      name: "TIER_1",
      value: 0,
      status: "OPTIMAL",
      bestBound: 0,
      timeBudgetSeconds: 180.0,
      elapsedSeconds: 12.5,
      usedFallback: false,
      tolerance: 0,
      frozenUpperBound: 0,
      costIncumbentGuard: 0,
      terms: [{
        metric: "TOTAL_COST",
        direction: "MIN",
        weight: 100,
        tolerance: 0,
        parameters: {},
        normalizationCoefficient: 1_000_000,
        metricUpperBound: 10_000,
      }],
    }],
    optimal: true,
    solutionHash: "a".repeat(64),
    equivalentToStrategyId: null,
  };
}

test("exposes only provider-neutral worker actions", () => {
  assert.deepEqual(ALLOWED_ACTIONS, [
    "solver_claim_next_v2",
    "solver_load_snapshot_v2",
    "solver_heartbeat_v2",
    "solver_save_variant_v2",
    "solver_finalize_v2",
    "solver_interrupt_v2",
    "solver_fail_attempt_v2",
  ]);
});

test("forwards a valid pull claim with exact arguments", async () => {
  const calls = [];
  const response = await handlerWith(calls)(
    gatewayRequest("solver_claim_next_v2", claimArgs),
  );
  assert.equal(response.status, 200);
  assert.deepEqual(calls, [
    { action: "solver_claim_next_v2", args: claimArgs },
  ]);
});

test("rejects removed dispatcher actions and unknown arguments", async () => {
  const handler = handlerWith();
  const removed = await handler(gatewayRequest("solver_dispatch_next_v2", {}));
  assert.equal(removed.status, 400);
  assert.deepEqual(await removed.json(), { error: "ACTION_NOT_ALLOWED" });

  const unknown = await handler(gatewayRequest("solver_claim_next_v2", {
    ...claimArgs,
    p_run_id: RUN_ID,
  }));
  assert.equal(unknown.status, 400);
  assert.deepEqual(await unknown.json(), { error: "UNKNOWN_ARGUMENT" });
});

test("rejects invalid pull claim boundaries", async () => {
  const handler = handlerWith();
  for (const args of [
    { ...claimArgs, p_worker_id: "x" },
    { ...claimArgs, p_worker_version: "bad version" },
    { ...claimArgs, p_task_attempt: 0 },
    { ...claimArgs, p_task_attempt: 21 },
    { ...claimArgs, p_lease_seconds: 29 },
    { ...claimArgs, p_lease_seconds: 901 },
  ]) {
    const response = await handler(gatewayRequest("solver_claim_next_v2", args));
    assert.equal(response.status, 400);
  }
});

test("requires the dedicated worker token", async () => {
  const handler = handlerWith();
  for (const token of ["", "wrong-token".padEnd(64, "x")]) {
    const response = await handler(
      gatewayRequest("solver_claim_next_v2", claimArgs, token),
    );
    assert.equal(response.status, 401);
  }
});

test("rejects malformed lease arguments before invoking RPC", async () => {
  const calls = [];
  const handler = handlerWith(calls);
  const response = await handler(gatewayRequest("solver_finalize_v2", {
    p_run_id: RUN_ID,
    p_attempt_id: ATTEMPT_ID,
    p_lease_token: `${LEASE_TOKEN}bad`,
  }));
  assert.equal(response.status, 400);
  assert.equal(calls.length, 0);
});

test("forwards only a validated upstream PostgreSQL error code", async () => {
  const base = {
    solverGatewayToken: TOKEN,
    gatewayVersion: GATEWAY_VERSION,
    invokeRpc: async () => ({
      status: 400,
      errorCode: "RUN_VARIANTS_INCOMPLETE",
    }),
  };
  const response = await createGatewayHandler(base)(gatewayRequest(
    "solver_finalize_v2",
    {p_run_id:RUN_ID,p_attempt_id:ATTEMPT_ID,p_lease_token:LEASE_TOKEN},
  ));
  assert.equal(response.status,400);
  assert.deepEqual(await response.json(),{error:"RUN_VARIANTS_INCOMPLETE"});

  const unsafe = await createGatewayHandler({
    ...base,
    invokeRpc: async () => ({status:400,errorCode:"SQL failed: private detail"}),
  })(gatewayRequest("solver_finalize_v2",{
    p_run_id:RUN_ID,p_attempt_id:ATTEMPT_ID,p_lease_token:LEASE_TOKEN,
  }));
  assert.deepEqual(await unsafe.json(),{error:"UPSTREAM_RPC_FAILED"});
});

test("accepts PostgreSQL UUIDs used by stable matrix identifiers", async () => {
  const calls = [];
  const handler = handlerWith(calls);
  const stableStrategyId = "2c6ca898-8d99-e28f-59f1-ac829a5fbee6";
  const args = {
    p_run_id: RUN_ID,
    p_attempt_id: ATTEMPT_ID,
    p_lease_token: LEASE_TOKEN,
    p_progress: {
      schemaVersion: 2,
      phase: "SOLVING",
      progress: 10,
      strategyId: stableStrategyId,
      strategyProgress: 1,
      strategyCount: 3,
      completedStrategies: 0,
    },
  };

  const response = await handler(gatewayRequest("solver_heartbeat_v2", args));

  assert.equal(response.status, 200);
  assert.deepEqual(calls, [{ action: "solver_heartbeat_v2", args }]);
});

test("accepts normalized objective metadata emitted by the worker", async () => {
  const calls = [];
  const handler = handlerWith(calls);
  const args = {
    p_run_id: RUN_ID,
    p_attempt_id: ATTEMPT_ID,
    p_lease_token: LEASE_TOKEN,
    p_variant: normalizedVariant(),
  };

  const response = await handler(gatewayRequest("solver_save_variant_v2", args));

  assert.equal(response.status, 200);
  assert.deepEqual(calls, [{
    action: "solver_save_variant_v2",
    args: { ...args, p_gateway_version: GATEWAY_VERSION },
  }]);
});

test("accepts the primary-role-before-backup diagnostic emitted by category runs", async () => {
  const calls = [];
  const handler = handlerWith(calls);
  const variant = normalizedVariant();
  variant.stageObjectives[0].roleBackupPenalty = 200;
  variant.metrics.ROLE_BACKUP_PENALTY = 200;
  const args = {
    p_run_id: RUN_ID,
    p_attempt_id: ATTEMPT_ID,
    p_lease_token: LEASE_TOKEN,
    p_variant: variant,
  };

  const response = await handler(gatewayRequest("solver_save_variant_v2", args));

  assert.equal(response.status, 200);
  assert.deepEqual(calls, [{
    action: "solver_save_variant_v2",
    args: { ...args, p_gateway_version: GATEWAY_VERSION },
  }]);
});

test("rejects invalid stage time budgets before invoking PostgreSQL", async () => {
  const calls = [];
  const handler = handlerWith(calls);
  for (const timeBudgetSeconds of [Number.NaN, -1, 86_401, "180"]) {
    const variant = normalizedVariant();
    variant.stageObjectives[0].timeBudgetSeconds = timeBudgetSeconds;
    const response = await handler(gatewayRequest("solver_save_variant_v2", {
      p_run_id: RUN_ID,
      p_attempt_id: ATTEMPT_ID,
      p_lease_token: LEASE_TOKEN,
      p_variant: variant,
    }));
    assert.equal(response.status, 400);
  }
  assert.equal(calls.length, 0);
});

test("accepts verified fairness diagnostics emitted by the worker", async () => {
  const calls = [];
  const handler = handlerWith(calls);
  const variant = normalizedVariant();
  variant.stageObjectives[0].fairnessIncumbentGuard = {
    LOAD_UTILIZATION_SPREAD_BPS: 850,
    NOMINAL_DEVIATION_MINUTES: 56_520,
  };
  variant.stageObjectives[0].verifiedZeroIncumbent = true;
  variant.stageObjectives[0].certifiedCoverageSeed = true;
  Object.assign(variant.stageObjectives[0], {
    fairCoverageSeedMinimumEstimatedAchievableUtilizationBps: 411,
    fairCoverageSeedEstimatedAchievableUtilizationSpreadBps: 261,
    fairCoverageSeedStatus: "OPTIMAL",
    fairCoverageSeedTimeBudgetSeconds: 90,
    fairCoverageSpreadStatus: "FEASIBLE",
    fairCoverageSpreadTimeBudgetSeconds: 54,
  });
  variant.stageObjectives[0].terms[0].configuredTier = 4;
  variant.metrics.MIN_ACHIEVABLE_TARGET_UTILIZATION_BPS = 411;
  variant.metrics.ACHIEVABLE_TARGET_UTILIZATION_SPREAD_BPS = 261;
  const args = {
    p_run_id: RUN_ID,
    p_attempt_id: ATTEMPT_ID,
    p_lease_token: LEASE_TOKEN,
    p_variant: variant,
  };

  const response = await handler(gatewayRequest("solver_save_variant_v2", args));

  assert.equal(response.status, 200);
  assert.deepEqual(calls, [{
    action: "solver_save_variant_v2",
    args: { ...args, p_gateway_version: GATEWAY_VERSION },
  }]);
});

test("accepts versioned cost categories emitted by the current worker", async () => {
  const calls = [];
  const handler = handlerWith(calls);
  const variant = normalizedVariant();
  variant.assignments = [{
    slotId: "slot-2026-09-01-host-1",
    employeeId: "55555555-5555-4555-8555-555555555555",
    costUnits: 19_200,
    costComponents: [{
      ruleId: "BASE",
      calculationType: "BASE_HOURLY",
      costUnits: 19_200,
      costCategory: "WAGE",
    }],
  }];
  variant.metrics.TOTAL_COST = 19_200;
  const args = {
    p_run_id: RUN_ID,
    p_attempt_id: ATTEMPT_ID,
    p_lease_token: LEASE_TOKEN,
    p_variant: variant,
  };

  const response = await handler(gatewayRequest("solver_save_variant_v2", args));

  assert.equal(response.status, 200);
  assert.deepEqual(calls, [{
    action: "solver_save_variant_v2",
    args: { ...args, p_gateway_version: GATEWAY_VERSION },
  }]);
});

test("rejects malformed worker cost categories", async () => {
  const calls = [];
  const handler = handlerWith(calls);
  const variant = normalizedVariant();
  variant.assignments = [{
    slotId: "slot-2026-09-01-host-1",
    employeeId: "55555555-5555-4555-8555-555555555555",
    costUnits: 19_200,
    costComponents: [{
      ruleId: "BASE",
      calculationType: "BASE_HOURLY",
      costUnits: 19_200,
      costCategory: "wage with spaces",
    }],
  }];

  const response = await handler(gatewayRequest("solver_save_variant_v2", {
    p_run_id: RUN_ID,
    p_attempt_id: ATTEMPT_ID,
    p_lease_token: LEASE_TOKEN,
    p_variant: variant,
  }));

  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), { error: "INVALID_COST_CATEGORY" });
  assert.equal(calls.length, 0);
});

test("requires complete stage elapsed and fallback proof", async () => {
  for (const key of ["timeBudgetSeconds", "elapsedSeconds", "usedFallback"]) {
    const calls = [];
    const handler = handlerWith(calls);
    const variant = normalizedVariant();
    delete variant.stageObjectives[0][key];
    const response = await handler(gatewayRequest("solver_save_variant_v2", {
      p_run_id: RUN_ID,
      p_attempt_id: ATTEMPT_ID,
      p_lease_token: LEASE_TOKEN,
      p_variant: variant,
    }));
    assert.equal(response.status, 400);
    assert.equal(calls.length, 0);
  }
});

test("rejects invalid stage elapsed and fallback values", async () => {
  for (const [key, invalid] of [
    ["elapsedSeconds", -1],
    ["elapsedSeconds", 86_401],
    ["elapsedSeconds", "12.5"],
    ["usedFallback", "false"],
  ]) {
    const calls = [];
    const handler = handlerWith(calls);
    const variant = normalizedVariant();
    variant.stageObjectives[0][key] = invalid;
    const response = await handler(gatewayRequest("solver_save_variant_v2", {
      p_run_id: RUN_ID,
      p_attempt_id: ATTEMPT_ID,
      p_lease_token: LEASE_TOKEN,
      p_variant: variant,
    }));
    assert.equal(response.status, 400);
    assert.equal(calls.length, 0);
  }
});

test("accepts overtime gate diagnostics emitted by the worker", async () => {
  const calls = [];
  const handler = handlerWith(calls);
  const variant = normalizedVariant();
  Object.assign(variant.stageObjectives[0], {
    overtimeMinimum: 0,
    overtimeStatus: "OPTIMAL",
    overtimeFrozenUpperBound: 0,
    overtimeTimeBudgetSeconds: 12.5,
    overtimeElapsedSeconds: 3.25,
    overtimeVerifiedZeroIncumbent: true,
    overtimeUsedFallback: false,
  });
  const args = {
    p_run_id: RUN_ID,
    p_attempt_id: ATTEMPT_ID,
    p_lease_token: LEASE_TOKEN,
    p_variant: variant,
  };

  const response = await handler(gatewayRequest("solver_save_variant_v2", args));

  assert.equal(response.status, 200);
  assert.deepEqual(calls, [{
    action: "solver_save_variant_v2",
    args: { ...args, p_gateway_version: GATEWAY_VERSION },
  }]);
});

test("accepts a diversity proof that preserves frozen objectives", async () => {
  const calls = [];
  const handler = handlerWith(calls);
  const variant = normalizedVariant();
  variant.stageObjectives.push({
    tier: 2,
    name: "DIVERSIFY",
    value: 0,
    status: "OPTIMAL",
    tolerance: 0,
    frozenUpperBound: 0,
    timeBudgetSeconds: 5,
    elapsedSeconds: 0.5,
    usedFallback: false,
    businessObjectiveBoundsPreserved: true,
    excludedEquivalentStrategies: [{
      strategyId: STRATEGY_ID,
      minimumAssignmentChanges: 3,
    }],
  });
  const args = {
    p_run_id: RUN_ID,
    p_attempt_id: ATTEMPT_ID,
    p_lease_token: LEASE_TOKEN,
    p_variant: variant,
  };

  const response = await handler(gatewayRequest("solver_save_variant_v2", args));

  assert.equal(response.status, 200);
  assert.deepEqual(calls, [{
    action: "solver_save_variant_v2",
    args: { ...args, p_gateway_version: GATEWAY_VERSION },
  }]);
});

test("accepts the month-scoped symmetric-remainder rotation proof", async () => {
  const calls = [];
  const handler = handlerWith(calls);
  const variant = normalizedVariant();
  variant.stageObjectives.push({
    tier: 2,
    name: "ROTATION_TIE_BREAK",
    value: 14_400,
    status: "OPTIMAL",
    bestBound: 14_400,
    tolerance: 0,
    frozenUpperBound: 14_400,
    timeBudgetSeconds: 0,
    elapsedSeconds: 0,
    usedFallback: false,
    rotationKeyVersion: "MONTH_EMPLOYEE_SHA256_V1",
    rotationMonth: "2026-08",
    rotationOrderHash: "b".repeat(64),
    scoreDefinition:
      "SUM(WITHIN_GROUP_MONTH_RANK_X_INTERNAL_ASSIGNED_MINUTES)",
    scope: "PROVEN_INTERCHANGEABLE_EMPLOYEE_BUNDLE_PERMUTATIONS",
    applied: true,
    interchangeableGroupCount: 1,
    rotatedEmployeeCount: 20,
    changedAssignmentCount: 2,
    excludedIdentityBoundEmployeeCount: 0,
    businessMetricVectorPreserved: true,
    businessMetricVectorHash: "c".repeat(64),
    solutionHashBefore: "d".repeat(64),
    solutionHashAfter: "e".repeat(64),
  });
  const args = {
    p_run_id: RUN_ID,
    p_attempt_id: ATTEMPT_ID,
    p_lease_token: LEASE_TOKEN,
    p_variant: variant,
  };

  const response = await handler(gatewayRequest("solver_save_variant_v2", args));

  assert.equal(response.status, 200);
  assert.deepEqual(calls, [{
    action: "solver_save_variant_v2",
    args: { ...args, p_gateway_version: GATEWAY_VERSION },
  }]);
});

test("rejects incomplete or contradictory rotation proofs", async () => {
  for (const mutate of [
    (stage) => { stage.rotationMonth = "2026-13"; },
    (stage) => { stage.businessMetricVectorPreserved = false; },
    (stage) => { stage.changedAssignmentCount = 0; },
    (stage) => { stage.unexpected = true; },
  ]) {
    const calls = [];
    const handler = handlerWith(calls);
    const variant = normalizedVariant();
    const stage = {
      tier: 2,
      name: "ROTATION_TIE_BREAK",
      value: 14_400,
      status: "OPTIMAL",
      bestBound: 14_400,
      tolerance: 0,
      frozenUpperBound: 14_400,
      timeBudgetSeconds: 0,
      elapsedSeconds: 0,
      usedFallback: false,
      rotationKeyVersion: "MONTH_EMPLOYEE_SHA256_V1",
      rotationMonth: "2026-08",
      rotationOrderHash: "b".repeat(64),
      scoreDefinition:
        "SUM(WITHIN_GROUP_MONTH_RANK_X_INTERNAL_ASSIGNED_MINUTES)",
      scope: "PROVEN_INTERCHANGEABLE_EMPLOYEE_BUNDLE_PERMUTATIONS",
      applied: true,
      interchangeableGroupCount: 1,
      rotatedEmployeeCount: 20,
      changedAssignmentCount: 2,
      excludedIdentityBoundEmployeeCount: 0,
      businessMetricVectorPreserved: true,
      businessMetricVectorHash: "c".repeat(64),
      solutionHashBefore: "d".repeat(64),
      solutionHashAfter: "e".repeat(64),
    };
    mutate(stage);
    variant.stageObjectives.push(stage);
    const response = await handler(gatewayRequest("solver_save_variant_v2", {
      p_run_id: RUN_ID,
      p_attempt_id: ATTEMPT_ID,
      p_lease_token: LEASE_TOKEN,
      p_variant: variant,
    }));
    assert.equal(response.status, 400);
    assert.equal(calls.length, 0);
  }
});

test("rejects non-JSON requests and unsupported methods", async () => {
  const handler = handlerWith();
  const get = await handler(new Request("https://example.test", {
    method: "GET",
  }));
  assert.equal(get.status, 405);

  const text = await handler(new Request("https://example.test", {
    method: "POST",
    headers: {
      "Content-Type": "text/plain",
      "X-Solver-Gateway-Token": TOKEN,
    },
    body: "not-json",
  }));
  assert.equal(text.status, 415);
});

test("fails closed for invalid configured credentials", () => {
  const invokeRpc = async () => ({ status: 200 });
  for (const token of [
    "short",
    "sb_secret_not_a_gateway_token_1234567890",
    "header.payload.signature",
  ]) {
    assert.throws(
      () => createGatewayHandler({
        solverGatewayToken: token,
        gatewayVersion: GATEWAY_VERSION,
        invokeRpc,
      }),
      /Invalid gateway token configuration/,
    );
  }
});
