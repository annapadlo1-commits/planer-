import assert from "node:assert/strict";
import test from "node:test";

import {
  createGatewayHandler,
  DISPATCHER_ACTIONS,
  MAX_BODY_BYTES,
  WORKER_ACTIONS,
} from "./contract.ts";

const WORKER_TOKEN = "worker-gateway-test-token-".padEnd(64, "w");
const DISPATCHER_TOKEN = "dispatcher-gateway-test-token-".padEnd(64, "d");
const RUN_ID = "11111111-1111-4111-8111-111111111111";
const ATTEMPT_ID = "22222222-2222-4222-8222-222222222222";
const LEASE_TOKEN = "33333333-3333-4333-8333-333333333333";
const DISPATCH_TOKEN = "44444444-4444-4444-8444-444444444444";
const EXECUTION_NAME =
  "projects/grafik/locations/europe-west1/jobs/solver/executions/solver-abc";

function gatewayRequest(action, args, options = {}) {
  const channel = options.channel ?? "worker";
  const token = options.token ??
    (channel === "dispatcher" ? DISPATCHER_TOKEN : WORKER_TOKEN);
  const tokenHeaders = channel === "none"
    ? {}
    : channel === "both"
    ? {
      "X-Solver-Gateway-Token": WORKER_TOKEN,
      "X-Dispatcher-Gateway-Token": DISPATCHER_TOKEN,
    }
    : channel === "dispatcher"
    ? { "X-Dispatcher-Gateway-Token": token }
    : { "X-Solver-Gateway-Token": token };
  return new Request("https://project.supabase.co/functions/v1/solver-gateway", {
    method: options.method ?? "POST",
    headers: {
      "Content-Type": options.contentType ?? "application/json",
      ...tokenHeaders,
      ...(options.headers ?? {}),
    },
    body: (options.method ?? "POST") === "POST"
      ? options.body ?? JSON.stringify({ action, args })
      : undefined,
  });
}

function leaseArgs() {
  return {
    p_run_id: RUN_ID,
    p_attempt_id: ATTEMPT_ID,
    p_lease_token: LEASE_TOKEN,
  };
}

function handlerWith(invokeRpc) {
  return createGatewayHandler({
    solverGatewayToken: WORKER_TOKEN,
    dispatcherGatewayToken: DISPATCHER_TOKEN,
    invokeRpc,
  });
}

function recoveryApply(kind) {
  const hasToken =
    kind === "RESERVATION_EXPIRED" || kind === "CLAIMED_UNACKNOWLEDGED";
  const hasAttempt =
    kind === "CLAIMED_UNACKNOWLEDGED" || kind === "LEASE_EXPIRED";
  const hasExecution = kind === "LAUNCH_EXPIRED" || kind === "LEASE_EXPIRED";
  return {
    p_dispatcher_id: "dispatcher:test:1",
    p_mode: "APPLY",
    p_limit: null,
    p_launch_grace_seconds: 180,
    p_run_id: RUN_ID,
    p_kind: kind,
    p_dispatch_token: hasToken ? DISPATCH_TOKEN : null,
    p_dispatch_attempt: 1,
    p_attempt_number: hasAttempt ? 1 : null,
    p_execution_name: hasExecution ? EXECUTION_NAME : null,
    p_observed_state: "NOT_FOUND",
  };
}

test("freezes worker and dispatcher allowlists", () => {
  assert.deepEqual(WORKER_ACTIONS, [
    "solver_claim_v2",
    "solver_load_snapshot_v2",
    "solver_heartbeat_v2",
    "solver_save_variant_v2",
    "solver_finalize_v2",
    "solver_interrupt_v2",
    "solver_fail_attempt_v2",
  ]);
  assert.deepEqual(DISPATCHER_ACTIONS, [
    "solver_dispatch_next_v2",
    "solver_mark_dispatched_v2",
    "solver_release_dispatch_v2",
    "solver_reconcile_stale_v2",
  ]);
});

test("forwards exact version-bound worker claim", async () => {
  const calls = [];
  const handler = handlerWith(async (action, args) => {
    calls.push({ action, args });
    return { status: 200, body: "{}", contentType: "application/json" };
  });
  const args = {
    p_run_id: RUN_ID,
    p_dispatch_token: DISPATCH_TOKEN,
    p_worker_id: "worker:cloud-run:1",
    p_worker_version: "ORTOOLS_V2_2026_08_02",
    p_task_attempt: 1,
    p_lease_seconds: 90,
  };
  assert.equal((await handler(gatewayRequest("solver_claim_v2", args))).status, 200);
  assert.deepEqual(calls, [{ action: "solver_claim_v2", args }]);
});

test("forwards dispatcher reservation on dispatcher channel", async () => {
  const calls = [];
  const handler = handlerWith(async (action, args) => {
    calls.push({ action, args });
    return { status: 200, body: "{}", contentType: "application/json" };
  });
  const args = { p_dispatcher_id: "dispatcher:test:1", p_lease_seconds: 90 };
  const response = await handler(
    gatewayRequest("solver_dispatch_next_v2", args, { channel: "dispatcher" }),
  );
  assert.equal(response.status, 200);
  assert.deepEqual(calls, [{ action: "solver_dispatch_next_v2", args }]);
});

test("rejects missing duplicate and wrong credentials before parsing", async () => {
  let invoked = false;
  const handler = handlerWith(async () => {
    invoked = true;
    return { status: 200, body: "{}", contentType: "application/json" };
  });
  const responses = await Promise.all([
    handler(gatewayRequest("", {}, { channel: "none", body: "bad" })),
    handler(gatewayRequest("", {}, { channel: "both", body: "bad" })),
    handler(gatewayRequest("", {}, { channel: "dispatcher", token: "bad", body: "bad" })),
  ]);
  assert.deepEqual(responses.map((response) => response.status), [401, 401, 401]);
  assert.equal(invoked, false);
});

test("denies cross-channel RPCs", async () => {
  let invoked = false;
  const handler = handlerWith(async () => {
    invoked = true;
    return { status: 200, body: "{}", contentType: "application/json" };
  });
  const first = await handler(
    gatewayRequest("solver_finalize_v2", leaseArgs(), { channel: "dispatcher" }),
  );
  const second = await handler(
    gatewayRequest(
      "solver_dispatch_next_v2",
      { p_dispatcher_id: "dispatcher:test:1", p_lease_seconds: 90 },
      { channel: "worker" },
    ),
  );
  assert.deepEqual([first.status, second.status], [403, 403]);
  assert.equal(invoked, false);
});

test("validates run token version attempt and lease on claim", async () => {
  const handler = handlerWith(async () => ({
    status: 200,
    body: "{}",
    contentType: "application/json",
  }));
  const base = {
    p_run_id: RUN_ID,
    p_dispatch_token: DISPATCH_TOKEN,
    p_worker_id: "worker:test:1",
    p_worker_version: "ORTOOLS_V2_2026_08_02",
    p_task_attempt: 1,
    p_lease_seconds: 90,
  };
  const responses = await Promise.all([
    handler(gatewayRequest("solver_claim_v2", { ...base, p_run_id: "bad" })),
    handler(gatewayRequest("solver_claim_v2", { ...base, p_dispatch_token: null })),
    handler(gatewayRequest("solver_claim_v2", { ...base, p_worker_version: "bad version" })),
    handler(gatewayRequest("solver_claim_v2", { ...base, p_task_attempt: 0 })),
    handler(gatewayRequest("solver_claim_v2", { ...base, p_task_attempt: 21 })),
  ]);
  assert.deepEqual(responses.map((response) => response.status), [400, 400, 400, 400, 400]);
});

test("validates dispatcher lease and execution identity", async () => {
  const handler = handlerWith(async () => ({
    status: 200,
    body: "{}",
    contentType: "application/json",
  }));
  const valid = await handler(gatewayRequest("solver_mark_dispatched_v2", {
    p_run_id: RUN_ID,
    p_dispatch_token: DISPATCH_TOKEN,
    p_execution_name: EXECUTION_NAME,
  }, { channel: "dispatcher" }));
  const invalid = await handler(gatewayRequest("solver_dispatch_next_v2", {
    p_dispatcher_id: "dispatcher:test:1",
    p_lease_seconds: 301,
  }, { channel: "dispatcher" }));
  assert.deepEqual([valid.status, invalid.status], [200, 400]);
});

test("accepts four recovery kinds and restricts claimed apply to NOT_FOUND", async () => {
  let calls = 0;
  const handler = handlerWith(async () => {
    calls += 1;
    return {
      status: 200,
      body: JSON.stringify({ applied: false, outcome: "STALE" }),
      contentType: "application/json",
    };
  });
  const kinds = [
    "RESERVATION_EXPIRED",
    "CLAIMED_UNACKNOWLEDGED",
    "LAUNCH_EXPIRED",
    "LEASE_EXPIRED",
  ];
  const accepted = await Promise.all(kinds.map((kind) => handler(gatewayRequest(
    "solver_reconcile_stale_v2",
    recoveryApply(kind),
    { channel: "dispatcher" },
  ))));
  const invalid = await handler(gatewayRequest(
    "solver_reconcile_stale_v2",
    { ...recoveryApply("CLAIMED_UNACKNOWLEDGED"), p_observed_state: "FAILED" },
    { channel: "dispatcher" },
  ));
  assert.deepEqual(accepted.map((response) => response.status), [200, 200, 200, 200]);
  assert.equal(invalid.status, 400);
  assert.equal(calls, 4);
});

test("accepts exact worker lease envelope", async () => {
  const calls = [];
  const handler = handlerWith(async (action, args) => {
    calls.push({ action, args });
    return { status: 200, body: "{}", contentType: "application/json" };
  });
  const response = await handler(gatewayRequest("solver_finalize_v2", leaseArgs()));
  assert.equal(response.status, 200);
  assert.deepEqual(calls, [{ action: "solver_finalize_v2", args: leaseArgs() }]);
});

test("rejects malformed transport and oversized bodies before RPC", async () => {
  let invoked = false;
  const handler = handlerWith(async () => {
    invoked = true;
    return { status: 200, body: "{}", contentType: "application/json" };
  });
  const responses = await Promise.all([
    handler(gatewayRequest("", {}, { method: "GET" })),
    handler(gatewayRequest("", {}, { contentType: "text/plain" })),
    handler(gatewayRequest("", {}, { body: "{" })),
    handler(gatewayRequest("solver_save_variant_v2", {}, {
      body: JSON.stringify({ padding: "x".repeat(MAX_BODY_BYTES + 1) }),
    })),
  ]);
  assert.deepEqual(responses.map((response) => response.status), [405, 415, 400, 413]);
  assert.equal(invoked, false);
});

test("fails closed on upstream failures and non-json responses", async () => {
  const unavailable = handlerWith(async () => { throw new Error("offline"); });
  const invalid = handlerWith(async () => ({
    status: 200,
    body: "ok",
    contentType: "text/plain",
  }));
  assert.equal((await unavailable(gatewayRequest("solver_finalize_v2", leaseArgs()))).status, 502);
  assert.equal((await invalid(gatewayRequest("solver_finalize_v2", leaseArgs()))).status, 502);
});
