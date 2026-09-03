import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import test from "node:test";

const inventory = JSON.parse(await readFile(new URL("../supabase/tenant-isolation-inventory.json", import.meta.url), "utf8"));

test("AUD-008 inventory classifies every captured public table exactly once", () => {
  assert.equal(inventory.tables.count, 113);
  assert.equal(inventory.tables.rlsEnabledCount, 113);
  assert.equal(inventory.tables.withoutTenantKey.length, 113);
  assert.equal(inventory.tables.tenantOwned.length, 111);
  assert.deepEqual(inventory.tables.global, ["solver_feature_flags", "uat_environment_controls"]);
  assert.equal(new Set([...inventory.tables.tenantOwned, ...inventory.tables.global]).size, 113);
  assert.equal(inventory.tables.tenantOwned.some(name => inventory.tables.global.includes(name)), false);
});

test("AUD-008 retains exact evidence for all broad authenticated reads", () => {
  assert.deepEqual(inventory.policies.broadAuthenticatedReads.map(item => item.table).sort(), [
    "demand_rules", "event_demand_changes", "locations", "monthly_budgets", "operational_events", "roles",
    "shift_definitions", "solver_feature_flags", "workforce_calendar_events_v2", "workforce_event_demand_v2",
    "workforce_hot_day_limits_v2",
  ]);
});

test("AUD-008 migration gate stays fail-closed until live mapping and replay exist", () => {
  assert.equal(inventory.migrationGate.status, "BLOCKED_FAIL_CLOSED");
  assert.equal(inventory.migrationGate.missingInputs.length, 4);
  assert.equal(inventory.views.count, inventory.views.requiresTenantReview.length);
  assert.ok(inventory.routines.count > 0);
  assert.ok(inventory.triggers.count > 0);
  assert.equal(inventory.requiredTwoCompanyCases.length, 4);
  assert.match(inventory.requiredTwoCompanyCases[0].sameValues.join(" "), /GP-001.*BAR.*KELNER.*Kelner/u);
});

test("AUD-008 checked-in inventory is byte-identical to deterministic reconstruction", async () => {
  const root = new URL("..", import.meta.url);
  const generated = execFileSync(process.execPath, ["scripts/tenant-isolation-inventory.mjs"], {
    cwd: root,
    encoding: "utf8",
  });
  const checkedIn = await readFile(new URL("../supabase/tenant-isolation-inventory.json", import.meta.url), "utf8");
  assert.equal(generated, checkedIn);
});

test("AUD-008 global allowlist matches every destructive UAT reset contract", async () => {
  const migrations = await Promise.all([
    "20260812001000_uat_application_access_and_full_reset.sql",
    "20260813143000_uat_quick_start_self_import_defaults.sql",
    "20260824224431_b4f171_first_run_access_guards.sql",
  ].map(name => readFile(new URL(`../supabase/migrations/${name}`, import.meta.url), "utf8")));
  for (const sql of migrations) {
    assert.match(sql, /tablename not in \('uat_environment_controls','solver_feature_flags'\)/u);
  }
});
