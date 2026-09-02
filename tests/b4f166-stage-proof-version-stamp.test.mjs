import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

const migration = read(
  "supabase/migrations/20260822173000_b4f166_stage_proof_version_stamp.sql",
);
const postgresRegexFix = read(
  "supabase/migrations/20260822180000_b4f166_postgres_version_stamp_regex_fix.sql",
);
const gatewayContract = read("supabase/functions/solver-gateway/contract.ts");
const gatewayEntrypoint = read("supabase/functions/solver-gateway/index.ts");
const client = read("lib/solver-v2.ts");
const panel = read("components/SolverV2Panel.tsx");

test("B4F-166 persists stage proof and a complete component stamp", () => {
  for (const fragment of [
    "stage_proof jsonb not null",
    "version_stamp jsonb not null",
    "validate_stage_proof_b4f166",
    "p_gateway_version text",
    "p_frontend_version text",
    "'frontend'",
    "'solver'",
    "'gateway'",
    "'database'",
    "'strategyConfig'",
    "'snapshot'",
    "'stageProof',variant.stage_proof",
    "'versionStamp',variant.version_stamp",
  ]) {
    assert.ok(migration.includes(fragment), `missing migration fragment: ${fragment}`);
  }
});

test("B4F-166 fails closed when canonical stage telemetry is incomplete", () => {
  for (const requiredKey of [
    '"value"',
    '"frozenUpperBound"',
    '"tolerance"',
    '"timeBudgetSeconds"',
    '"elapsedSeconds"',
    '"usedFallback"',
  ]) {
    assert.ok(gatewayContract.includes(requiredKey), `missing gateway key: ${requiredKey}`);
  }
  assert.match(gatewayContract, /p_gateway_version:\s*options\.gatewayVersion/u);
  assert.match(gatewayEntrypoint, /DENO_DEPLOYMENT_ID/u);
  assert.match(migration, /STAGE_PROOF_INCOMPLETE/u);
  assert.match(migration, /FRONTEND_VERSION_STAMP_MISSING/u);
});

test("B4F-166 sends the frontend build and exposes proof in technical details", () => {
  assert.match(client, /p_frontend_version:\s*process\.env\.NEXT_PUBLIC_APP_BUILD_ID/u);
  assert.match(client, /stageProof:\s*Array\.isArray/u);
  assert.match(client, /versionStamp:\s*record/u);
  assert.match(panel, /Dowód etapów optymalizacji/u);
  assert.match(panel, /Identyfikatory wersji przebiegu/u);
});

test("B4F-166 keeps the 500-character boundary outside PostgreSQL regex quantifiers", () => {
  assert.doesNotMatch(postgresRegexFix, /\{0,499\}.*\*\$/u);
  assert.match(
    postgresRegexFix,
    /length\(coalesce\(p_frontend_version,[\s\S]*not between 1 and 500/u,
  );
  assert.match(
    postgresRegexFix,
    /length\(coalesce\(p_gateway_version,[\s\S]*not between 1 and 500/u,
  );
  assert.match(postgresRegexFix, /notify pgrst,'reload schema'/u);
});
