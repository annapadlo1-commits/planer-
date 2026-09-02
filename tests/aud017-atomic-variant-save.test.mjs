import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migration = await readFile(new URL(
  "../supabase/migrations/20260903100000_aud017_atomic_solver_variant_batch.sql",
  import.meta.url,
), "utf8");
const lifecycle = await readFile(new URL(
  "../solver/src/grafik_solver/lifecycle.py",
  import.meta.url,
), "utf8");

test("AUD-017 validates every result before the first persistence call", () => {
  const validation = lifecycle.indexOf("reports = []");
  const batchSave = lifecycle.indexOf("self.rpc.save_variants(");
  assert.ok(validation >= 0);
  assert.ok(batchSave > validation);
  assert.doesNotMatch(
    lifecycle.slice(validation, batchSave),
    /save_variant\s*\(/u,
  );
});

test("AUD-017 persists one exact three-variant PostgreSQL transaction", () => {
  assert.match(migration, /^begin;/mu);
  assert.match(migration, /^commit;/mu);
  assert.match(
    migration,
    /create or replace function public\.solver_save_variants_v2\(/u,
  );
  assert.match(
    migration,
    /v_count<>3 or v_distinct_count<>3 or v_canonical_count<>3/u,
  );
  assert.match(
    migration,
    /in \('BALANCED','MIN_COST','PREFERENCES'\)/u,
  );
  assert.match(migration, /public\.solver_save_variant_v2\(/u);
  assert.match(
    migration,
    /revoke all[\s\S]*from public,anon,authenticated,service_role;/u,
  );
  assert.match(
    migration,
    /grant execute[\s\S]*to service_role;/u,
  );
  assert.doesNotMatch(
    migration,
    /grant execute[\s\S]*to (?:anon|authenticated)/u,
  );
});
