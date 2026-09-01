import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { classifyInventory, compareSourceAndLive } from "../scripts/rpc-contract/parity-core.mjs";

const frontend = [{
  name: "example_rpc",
  payloadShapes: [{ keys: ["p_required"], dynamic: false }],
  callSites: [],
  testReferences: [],
}];
const definition = {
  schema: "public",
  name: "example_rpc",
  args: [
    { name: "p_required", type: "uuid", hasDefault: false, mode: "in" },
    { name: "p_optional", type: "text", hasDefault: true, mode: "in" },
  ],
  authenticatedExecute: true,
  anonExecute: false,
  publicExecute: false,
};
const RESTORED_STAFFING_RPC = "matrix_v2_staffing_bulk_adjust_uat_v2";

test("canonical migrations cover every frontend runtime RPC with compatible authorization", () => {
  const result = spawnSync(process.execPath, ["scripts/check-rpc-source-parity.mjs"], {
    cwd: new URL("../", import.meta.url),
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
  });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  const report = JSON.parse(result.stdout);
  assert.equal(report.unresolvedDynamicNames, 0);
  assert.ok(report.frontendUniqueRpc >= 151);
  assert.equal(report.counts.MATCHED, report.frontendUniqueRpc);
});

test("parity classifier detects a missing function", () => {
  assert.equal(classifyInventory(frontend, []).matrix[0].classification, "MISSING");
});

test("parity classifier validates named arguments and defaults", () => {
  assert.equal(classifyInventory(frontend, [definition]).matrix[0].classification, "MATCHED");
  const incompatible = { ...definition, args: [...definition.args, { name: "p_new_required", type: "integer", hasDefault: false, mode: "in" }] };
  assert.equal(classifyInventory(frontend, [incompatible]).matrix[0].classification, "SIGNATURE_MISMATCH");
});

test("parity classifier detects a missing authenticated grant", () => {
  assert.equal(classifyInventory(frontend, [{ ...definition, authenticatedExecute: false }]).matrix[0].classification, "AUTH_GRANT_MISMATCH");
});

test("parity classifier detects anonymous or PUBLIC execution", () => {
  assert.equal(classifyInventory(frontend, [{ ...definition, anonExecute: true }]).matrix[0].classification, "UNEXPECTED_ANON");
  assert.equal(classifyInventory(frontend, [{ ...definition, publicExecute: true }]).matrix[0].classification, "UNEXPECTED_ANON");
});

test("source/live comparator reports deterministic source-only and live-only signatures", () => {
  const sourceOnly = { ...definition, name: "source_only_rpc" };
  const liveOnly = { ...definition, name: "live_only_rpc" };
  const drift = compareSourceAndLive(
    [definition, sourceOnly],
    [definition, liveOnly],
    ["example_rpc", "source_only_rpc", "live_only_rpc"],
  );

  assert.deepEqual(drift, {
    sourceOnly: ["public.source_only_rpc(p_required:uuid,p_optional:text=?)"],
    liveOnly: ["public.live_only_rpc(p_required:uuid,p_optional:text=?)"],
  });
});

test("live checker accepts a temporary local UAT catalog without database access", () => {
  const cwd = new URL("../", import.meta.url);
  const inventoryResult = spawnSync(process.execPath, ["scripts/rpc-contract/migration-source-inventory.mjs"], {
    cwd,
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
  });
  assert.equal(inventoryResult.status, 0, inventoryResult.stderr || inventoryResult.stdout);

  const source = JSON.parse(inventoryResult.stdout);
  const temporary = mkdtempSync(path.join(tmpdir(), "szafunek-rpc-test-"));
  const catalogPath = path.join(temporary, "catalog.json");
  writeFileSync(catalogPath, `${JSON.stringify({
    projectRef: "nhthrtpkfpmufmrmdyjg",
    capturedAt: "local-test-fixture",
    rows: source.inventory,
  }, null, 2)}\n`);

  try {
    const result = spawnSync(process.execPath, ["scripts/check-rpc-live-parity.mjs", "--catalog", catalogPath], {
      cwd,
      encoding: "utf8",
      maxBuffer: 32 * 1024 * 1024,
    });
    assert.equal(result.status, 0, result.stderr || result.stdout);
    const report = JSON.parse(result.stdout);
    assert.deepEqual(report.sourceLiveSignatureDrift, { sourceOnly: [], liveOnly: [] });
    assert.equal(report.counts.MATCHED, report.frontendUniqueRpc);
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
});

test("live parity gate refuses a catalog from any project other than UAT", () => {
  const result = spawnSync(process.execPath, ["scripts/check-rpc-live-parity.mjs", "--catalog", "tests/fixtures/rpc-catalog-wrong-project.json"], {
    cwd: new URL("../", import.meta.url),
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Refusing non-UAT catalog/);
});

test("restored staffing RPC is fail-closed, atomic and rejects an invalid final count", () => {
  const sql = readFileSync(new URL("../supabase/migrations/20260826224321_restore_frontend_rpc_parity.sql", import.meta.url), "utf8");
  assert.match(sql, new RegExp(`function public\\.${RESTORED_STAFFING_RPC}\\(`));
  const auth = sql.indexOf("if auth.uid() is null");
  const roleGuard = sql.indexOf("public.has_app_role('OWNER')");
  const firstMutation = sql.indexOf("v_matrix:=public.matrix_v2_create_draft");
  const lock = sql.indexOf("for update of rule");
  const finalCountGuard = sql.indexOf("STAFFING_COUNT_BELOW_MINIMUM");
  const update = sql.indexOf("update public.matrix_staffing_rules_v2 rule set");
  const audit = sql.indexOf("insert into public.audit_log");
  assert.ok(auth >= 0 && auth < roleGuard && roleGuard < firstMutation);
  assert.ok(lock > firstMutation && finalCountGuard > lock && update > finalCountGuard && audit > update);
  assert.match(sql, /STAFFING_TARGET_NOT_FOUND/);
  assert.match(sql, /rule\.operation='SET'.*count_value,0\)\+p_delta<1/s);
  assert.match(sql, /rule\.operation='ADD'.*count_value,0\)\+p_delta<0/s);
  assert.doesNotMatch(sql, /greatest\(0,coalesce\(rule\.count_value/);
  assert.match(sql, /from public,anon,authenticated/);
  assert.match(sql, /grant execute[\s\S]*to authenticated/);
});
