import assert from "node:assert/strict";
import test from "node:test";

import {
  ALLOWED_ACTIONS,
  createGatewayHandler,
} from "./contract.ts";

const TOKEN = "solver-gateway-test-token".padEnd(64, "x");
const RUN_ID = "11111111-1111-4111-8111-111111111111";
const ATTEMPT_ID = "22222222-2222-4222-8222-222222222222";
const LEASE_TOKEN = "33333333-3333-4333-8333-333333333333";

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
      () => createGatewayHandler({ solverGatewayToken: token, invokeRpc }),
      /Invalid gateway token configuration/,
    );
  }
});
