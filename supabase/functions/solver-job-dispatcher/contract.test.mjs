import assert from "node:assert/strict";
import test from "node:test";

import { createDispatcherHandler } from "./contract.ts";

const RUN_ID = "11111111-1111-4111-8111-111111111111";
const NONCE = "22222222-2222-4222-8222-222222222222";
const LEASE = "33333333-3333-4333-8333-333333333333";
const NF_RUN = "44444444-4444-4444-8444-444444444444";
const BACKEND_TOKEN = "dispatcher-backend-token".padEnd(64, "d");

function reservation() {
  return {
    reserved: true,
    status: "DISPATCHING",
    runId: RUN_ID,
    dispatchNonce: NONCE,
    dispatchLeaseToken: LEASE,
    configuredPlan: "nf-compute-100-1",
    wallTimeoutSeconds: 720,
    solverCommit: "8".repeat(40),
    solverBuildId: "difficult-price-5668",
  };
}

function baseOptions(fetchImpl) {
  return {
    supabaseUrl: "https://uat.supabase.co",
    publishableKey: "publishable-key".padEnd(64, "p"),
    serviceRoleKey: "service-role-key".padEnd(64, "s"),
    dispatcherToken: BACKEND_TOKEN,
    jobSigningSecret: "job-signing-secret".padEnd(64, "j"),
    northflankApiToken: "northflank-api-token".padEnd(64, "n"),
    northflankProjectId: "planer-ortools",
    northflankJobId: "solver-gateway-job-uat",
    solverGatewayUrl:
      "https://uat.supabase.co/functions/v1/solver-gateway",
    dispatcherVersion: "dispatcher-test-v1",
    fetchImpl,
    now: () => Date.parse("2026-08-24T12:00:00Z"),
  };
}

function backendRequest(action, values = {}) {
  return new Request("https://uat.supabase.co/functions/v1/solver-job-dispatcher", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Solver-Dispatcher-Token": BACKEND_TOKEN,
    },
    body: JSON.stringify({ action, ...values }),
  });
}

test("dispatches exactly one target-bound Job and persists acceptance", async () => {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url: String(url), init });
    if (String(url).endsWith("/rpc/solver_dispatch_reserve_uat_v1")) {
      return Response.json(reservation());
    }
    if (String(url).endsWith("/rpc/solver_dispatch_result_uat_v1")) {
      return Response.json({ ok: true });
    }
    if (String(url).endsWith("/runs")) {
      return Response.json({ data: { id: NF_RUN, runName: "synthetic-run" } });
    }
    throw new Error(`Unexpected URL ${url}`);
  };
  const response = await createDispatcherHandler(baseOptions(fetchImpl))(
    backendRequest("dispatch"),
  );
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    reserved: true,
    runId: RUN_ID,
    northflankRunId: NF_RUN,
    status: "ACCEPTED",
  });
  const northflankCalls = calls.filter(({ url }) => url.endsWith("/runs"));
  assert.equal(northflankCalls.length, 1);
  const payload = JSON.parse(northflankCalls[0].init.body);
  assert.equal(payload.runtimeEnvironment.TARGET_RUN_ID, RUN_ID);
  assert.equal(payload.runtimeEnvironment.SOLVER_EXECUTION_MODE, "JOB");
  assert.equal(payload.runtimeEnvironment.MAX_RUNS, "1");
  assert.equal(payload.runtimeEnvironment.IDLE_EXIT_SECONDS, "30");
  assert.match(payload.runtimeEnvironment.SOLVER_GATEWAY_TOKEN, /^sj1_/u);
  assert.equal(payload.billing.deploymentPlan, "nf-compute-100-1");
  const resultCall = calls.find(({ url }) =>
    url.endsWith("/rpc/solver_dispatch_result_uat_v1")
  );
  const resultArgs = JSON.parse(resultCall.init.body);
  assert.equal(resultArgs.p_outcome, "ACCEPTED");
  assert.equal(resultArgs.p_northflank_run_id, NF_RUN);
});

test("a lost Northflank response becomes acceptance-unknown without a retry", async () => {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url: String(url), init });
    if (String(url).endsWith("/rpc/solver_dispatch_reserve_uat_v1")) {
      return Response.json(reservation());
    }
    if (String(url).endsWith("/rpc/solver_dispatch_result_uat_v1")) {
      return Response.json({ ok: true });
    }
    if (String(url).endsWith("/runs")) throw new TypeError("network timeout");
    throw new Error(`Unexpected URL ${url}`);
  };
  const response = await createDispatcherHandler(baseOptions(fetchImpl))(
    backendRequest("dispatch"),
  );
  assert.equal(response.status, 200);
  assert.equal((await response.json()).status, "ACCEPTANCE_UNKNOWN");
  assert.equal(calls.filter(({ url }) => url.endsWith("/runs")).length, 1);
  const resultCall = calls.find(({ url }) =>
    url.endsWith("/rpc/solver_dispatch_result_uat_v1")
  );
  assert.equal(
    JSON.parse(resultCall.init.body).p_outcome,
    "ACCEPTANCE_UNKNOWN",
  );
});

test("only a proven 429 rejection enters dispatch retry", async () => {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url: String(url), init });
    if (String(url).endsWith("/rpc/solver_dispatch_reserve_uat_v1")) {
      return Response.json(reservation());
    }
    if (String(url).endsWith("/rpc/solver_dispatch_result_uat_v1")) {
      return Response.json({ ok: true });
    }
    if (String(url).endsWith("/runs")) {
      return Response.json({ error: "rate limited" }, { status: 429 });
    }
    throw new Error(`Unexpected URL ${url}`);
  };
  const response = await createDispatcherHandler(baseOptions(fetchImpl))(
    backendRequest("dispatch"),
  );
  assert.equal((await response.json()).status, "PENDING");
  const resultCall = calls.find(({ url }) =>
    url.endsWith("/rpc/solver_dispatch_result_uat_v1")
  );
  assert.equal(
    JSON.parse(resultCall.init.body).p_outcome,
    "RETRYABLE_REJECTED",
  );
});

test("the browser request path uses its JWT and never accepts Northflank input", async () => {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url: String(url), init });
    if (String(url).endsWith("/rpc/optimizer_request_job_uat_v1")) {
      assert.equal(init.headers.Authorization, "Bearer user-jwt-token-value");
      return Response.json({ run: { id: RUN_ID }, executionMode: "JOB" });
    }
    if (String(url).endsWith("/rpc/solver_dispatch_reserve_uat_v1")) {
      return Response.json({ reserved: false, status: "DISABLED" });
    }
    throw new Error(`Unexpected URL ${url}`);
  };
  const handler = createDispatcherHandler(baseOptions(fetchImpl));
  const response = await handler(new Request(
    "https://uat.supabase.co/functions/v1/solver-job-dispatcher",
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: "Bearer user-jwt-token-value",
      },
      body: JSON.stringify({
        action: "request",
        request: {
          month: "2026-09-01",
          scenarioId: "66666666-6666-4666-8666-666666666666",
          scopeType: "COMPANY",
          scopeRoleId: null,
          name: "Synthetic Job UAT",
          idempotencyKey: "synthetic-job-uat-0001",
          frontendVersion: "8".repeat(40),
        },
      }),
    },
  ));
  assert.equal(response.status, 202);
  assert.equal((await response.json()).dispatch.status, "DISABLED");
  assert.equal(calls.some(({ url }) => url.includes("northflank.com")), false);
});

test("backend actions require the independent dispatcher token", async () => {
  const handler = createDispatcherHandler(baseOptions(async () => {
    throw new Error("must not call upstream");
  }));
  const response = await handler(new Request("https://example.test", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "dispatch" }),
  }));
  assert.equal(response.status, 401);
  assert.deepEqual(await response.json(), { error: "UNAUTHORIZED" });
});

test("rejects unknown arguments before any external call", async () => {
  let called = false;
  const handler = createDispatcherHandler(baseOptions(async () => {
    called = true;
    return Response.json({});
  }));
  const response = await handler(backendRequest("dispatch", { runId: RUN_ID }));
  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), { error: "UNKNOWN_ARGUMENT" });
  assert.equal(called, false);
});

