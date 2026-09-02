import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { userSafeErrorMessage } from "../lib/user-safe-error.ts";
import { matrixV2ErrorMessage } from "../lib/matrix-v2.ts";

const raw = "relation solver_private.secret_table does not exist; token=hidden";

test("unknown backend detail is logged with correlation but never rendered", () => {
  const logged = [];
  const message = userSafeErrorMessage(raw, {
    context: "test-operation",
    summary: "Nie udało się wykonać operacji.",
    nextStep: "Odśwież dane i spróbuj ponownie.",
    correlationId: "UI-TEST-123456",
    logger: (...values) => logged.push(values),
  });
  assert.doesNotMatch(message, /solver_private|secret_table|token=hidden/iu);
  assert.match(message, /UI-TEST-123456/u);
  assert.match(message, /Odśwież dane/u);
  assert.match(JSON.stringify(logged), /solver_private/u);
});

test("matrix fallback and constraint failure never expose backend names", () => {
  const originalError = console.error;
  console.error = () => undefined;
  try {
    for (const backendMessage of [
      raw,
      'new row violates check constraint "private_constraint_name"',
      "INVALID_UNMAPPED_PRIVATE_RULE payload=secret",
    ]) {
      const message = matrixV2ErrorMessage(backendMessage);
      assert.doesNotMatch(
        message,
        /solver_private|private_constraint_name|INVALID_UNMAPPED|payload=secret/iu,
      );
      assert.match(message, /identyfikator:/iu);
    }
  } finally {
    console.error = originalError;
  }
});

test("audited auth and workspace surfaces do not interpolate raw error.message", async () => {
  const [page, auth] = await Promise.all([
    readFile(new URL("../app/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../components/AppAuthProvider.tsx", import.meta.url), "utf8"),
  ]);
  assert.doesNotMatch(page, /Szczegóły:\s*\$\{completeResult\.error\.message\}/u);
  assert.doesNotMatch(page, /errors\.push\([^\n]*\.error\.message/u);
  assert.doesNotMatch(auth, /setMessage\(result\.error\.message\)/u);
  assert.match(page, /userSafeErrorMessage/u);
  assert.match(auth, /userSafeErrorMessage/u);
});
