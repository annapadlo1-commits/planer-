import assert from "node:assert/strict";
import test from "node:test";

import {
  applyLeaderRefill,
  requestLeaderRefill,
} from "../lib/solver-v2.ts";

function rpcClient(responses) {
  const calls = [];
  return {
    calls,
    client: {
      async rpc(name, args) {
        calls.push({ name, args });
        const response = responses[name];
        if (!response) throw new Error(`Unexpected RPC ${name}`);
        return response;
      },
    },
  };
}

test("B4F-105 request and apply use the exact auditable leader-refill RPC contract", async () => {
  const mock = rpcClient({
    optimizer_leader_refill_request_uat_v1: {
      data: { runId: "run-105", leaderRevision: 5 },
      error: null,
    },
    optimizer_leader_refill_apply_uat_v1: {
      data: { variantId: "leader-105", revision: 6, addedAssignments: 32 },
      error: null,
    },
  });

  const requested = await requestLeaderRefill(mock.client, {
    variantId: "leader-105",
    reason: "uzupełnienie wakatów po korekcie",
    idempotencyKey: "leader-refill-r5-test",
  });
  assert.deepEqual(requested, { runId: "run-105", leaderRevision: 5 });
  assert.deepEqual(mock.calls[0], {
    name: "optimizer_leader_refill_request_uat_v1",
    args: {
      p_variant_id: "leader-105",
      p_reason: "uzupełnienie wakatów po korekcie",
      p_idempotency_key: "leader-refill-r5-test",
    },
  });

  const applied = await applyLeaderRefill(mock.client, {
    leaderVariantId: "leader-105",
    sourceVariantId: "generated-result-105",
    reason: "uzupełnienie wakatów po korekcie",
  });
  assert.deepEqual(applied, {
    variantId: "leader-105",
    revision: 6,
    addedAssignments: 32,
  });
  assert.deepEqual(mock.calls[1], {
    name: "optimizer_leader_refill_apply_uat_v1",
    args: {
      p_leader_variant_id: "leader-105",
      p_source_variant_id: "generated-result-105",
      p_reason: "uzupełnienie wakatów po korekcie",
    },
  });
});

test("B4F-105 exposes request failures instead of accepting a silent no-op", async () => {
  const missingRun = rpcClient({
    optimizer_leader_refill_request_uat_v1: { data: { leaderRevision: 5 }, error: null },
  });
  await assert.rejects(
    requestLeaderRefill(missingRun.client, {
      variantId: "leader-105",
      reason: "test",
      idempotencyKey: "leader-refill-r5-test",
    }),
    /RUN_ID_MISSING/,
  );

  const serverError = rpcClient({
    optimizer_leader_refill_request_uat_v1: {
      data: null,
      error: {
        code: "P0001",
        message: "LEADER_REFILL_DRAFT_CHANGED",
        details: "revision 5 is stale",
        hint: "Reload the leader workspace",
      },
    },
  });
  await assert.rejects(
    requestLeaderRefill(serverError.client, {
      variantId: "leader-105",
      reason: "test",
      idempotencyKey: "leader-refill-r5-test",
    }),
    /LEADER_REFILL_DRAFT_CHANGED.*revision 5 is stale.*Reload the leader workspace/,
  );
});
