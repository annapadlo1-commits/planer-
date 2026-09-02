import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migration = await readFile(new URL(
  "../supabase/migrations/20260903110000_aud004_018_immutable_runtime_manifest.sql",
  import.meta.url,
), "utf8").catch(() => "");
const dockerfile = await readFile(new URL("../solver/Dockerfile", import.meta.url), "utf8");
const gateway = await readFile(new URL(
  "../supabase/functions/solver-gateway/index.ts",
  import.meta.url,
), "utf8");

test("worker image and gateway fail closed on immutable source identity", () => {
  assert.match(dockerfile, /ARG SOLVER_SOURCE_SHA/u);
  assert.match(dockerfile, /org\.opencontainers\.image\.revision/u);
  assert.match(gateway, /requireEnvironment\("GATEWAY_SOURCE_SHA"\)/u);
  assert.match(gateway, /\^\[0-9a-f\]\{40\}\$/u);
});

test("database stamps the claimed artifact and actual migration ledger", () => {
  assert.match(migration, /solver_claim_next_v3/u);
  assert.match(migration, /worker_build_manifest/u);
  assert.match(migration, /supabase_migrations\.schema_migrations/u);
  assert.match(migration, /ledgerSha256/u);
  assert.match(migration, /ledgerRowCount/u);
  assert.match(migration, /sourceSha/u);
  assert.match(migration, /imageDigest/u);
  assert.match(migration, /contractVersion/u);
  assert.match(migration, /buildTimestamp/u);
  assert.match(migration, /gatewaySourceSha/u);
  assert.match(migration, /from public,anon,authenticated,service_role/u);
});
