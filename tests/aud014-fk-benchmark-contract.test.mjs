import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const benchmark = await readFile(
  new URL("../scripts/aud014/benchmark-evidence-backed-fk-indexes.sql", import.meta.url),
  "utf8",
);
const runner = await readFile(
  new URL("../scripts/aud014/run-evidence-backed-fk-benchmark.mjs", import.meta.url),
  "utf8",
);
const migrationVerifier = await readFile(
  new URL("../scripts/aud014/verify-evidence-backed-fk-migration.mjs", import.meta.url),
  "utf8",
);

test("AUD-014 benchmark covers the exact three FK semantics", () => {
  assert.match(
    benchmark,
    /'application_access_directory_v1_auth_user_id_fkey',[\s\S]*'auth_user_id','set null'/u,
  );
  assert.match(
    benchmark,
    /'audit_log_actor_id_fkey','actor_id','no action'/u,
  );
  assert.match(
    benchmark,
    /'employee_preferences_employee_id_fkey',[\s\S]*'employee_id','cascade'/u,
  );
});

test("AUD-014 benchmark has deterministic scales and the read/delete/write matrix", () => {
  assert.match(benchmark, /array\[1000,100000,1000000\]::bigint\[\]/u);
  assert.match(benchmark, /operation in \('read','delete','write'\)/u);
  assert.match(benchmark, /for v_repetition in 1\.\.5 loop/u);
  assert.match(benchmark, /AUD014_INCOMPLETE_BENCHMARK_MATRIX/u);
  assert.match(benchmark, /AUD014_AFTER_PLAN_DID_NOT_USE_INDEX/u);
});

test("AUD-014 benchmark is local-only, temporary and rolled back", () => {
  assert.match(benchmark, /if inet_client_addr\(\) is not null/u);
  assert.match(benchmark, /raise exception 'AUD014_LOCAL_DOCKER_ONLY'/u);
  assert.match(benchmark, /create temporary table aud014_benchmark_results/u);
  assert.match(benchmark, /begin;[\s\S]*rollback;/u);
  assert.doesNotMatch(benchmark, /nhthrtpkfpmufmrmdyjg|supabase\.co/iu);
  assert.match(runner, /\["exec", "-i", container, "psql"/u);
  assert.doesNotMatch(runner, /https?:|supabase\.co|--linked/iu);
});

test("AUD-014 migration verifier applies DDL locally and always rolls it back", () => {
  assert.match(
    migrationVerifier,
    /const verification = migration[\s\S]*\.replace\(\/\\bbegin;[\s\S]*\.replace\(\/commit;/u,
  );
  assert.match(
    migrationVerifier,
    /"environment":"ISOLATED_UAT","projectRef":"nhthrtpkfpmufmrmdyjg"/u,
  );
  assert.match(migrationVerifier, /aud014-negative-local-test/u);
  assert.match(migrationVerifier, /AUD014_WRONG_SUPABASE_PROJECT/u);
  assert.match(migrationVerifier, /negativeDefinitionProbe/u);
  assert.match(migrationVerifier, /AUD014_INDEX_DEFINITION_MISMATCH/u);
  assert.match(migrationVerifier, /assert\.notEqual\([\s\S]*negativeRun\.status/u);
  assert.match(migrationVerifier, /from pg_catalog\.pg_index/u);
  assert.match(migrationVerifier, /persistentChanges',false/u);
  assert.match(migrationVerifier, /rollback;/u);
  assert.doesNotMatch(migrationVerifier, /https?:|supabase\.co|--linked/iu);
});
