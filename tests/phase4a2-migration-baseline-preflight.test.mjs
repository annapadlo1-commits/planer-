import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const manifest = JSON.parse(await readFile(new URL(
  "../docs/phase4a2-uat-migration-reconciliation.json",
  import.meta.url,
), "utf8"));
const preflight = await readFile(new URL(
  "../docs/PHASE4A2_UAT_BASELINE_READ_ONLY_PREFLIGHT.sql",
  import.meta.url,
), "utf8");
const runbook = await readFile(new URL(
  "../docs/PHASE4A2_MIGRATION_BASELINE_RECOVERY_2026-08-28.md",
  import.meta.url,
), "utf8");

test("Phase 4A.2 pins the reviewed source and isolated UAT", () => {
  assert.equal(manifest.source.repository, "annapadlo1-commits/planer-");
  assert.equal(manifest.source.branch, "codex/uat-consolidated-fixes");
  assert.equal(manifest.source.commit, "5565c50370cb9436a76d1e6d7013250eaad2bece");
  assert.equal(manifest.source.tree, "a8f6148cc0ff8960638553951972ba949b464d84");
  assert.equal(manifest.uat.project_ref, "nhthrtpkfpmufmrmdyjg");
  assert.equal(manifest.uat.branch_name, "dynamic-matrix-solver-v2");
  assert.equal(manifest.uat.preview_project_status, "ACTIVE_HEALTHY");
  assert.equal(manifest.uat.migration_status, "MIGRATIONS_FAILED");
  assert.equal(manifest.uat.identity_control.config.projectRef, manifest.uat.project_ref);
  assert.equal(manifest.uat.identity_control.config.environment, "ISOLATED_UAT");
});

test("ledger manifest is ordered, unique and self-fingerprinting", () => {
  assert.equal(manifest.ledger.row_count, 254);
  assert.equal(manifest.ledger.rows.length, 254);
  const versions = manifest.ledger.rows.map(row => row.version);
  assert.deepEqual(versions, [...versions].sort());
  assert.equal(new Set(versions).size, versions.length);
  for (const row of manifest.ledger.rows) {
    assert.match(row.version, /^(?:\d{4}|\d{14})$/u);
    assert.match(row.name, /^[a-z0-9_]+$/u);
    assert.ok(Number.isInteger(row.statement_count) && row.statement_count >= 0);
    assert.ok(Number.isInteger(row.sql_bytes) && row.sql_bytes >= 0);
    assert.match(row.sql_md5, /^[a-f0-9]{32}$/u);
  }
  const payload = manifest.ledger.rows.map(row =>
    [row.version, row.name, row.statement_count, row.sql_bytes, row.sql_md5].join("|")
  ).join("\n");
  assert.equal(createHash("md5").update(payload).digest("hex"), manifest.ledger.fingerprint);
  assert.equal(manifest.ledger.fingerprint, "04c5c2ad59937027420bd7c71b782d14");
});

test("reconciliation counts expose semantic drift instead of hiding it", () => {
  assert.deepEqual(manifest.comparison.counts, {
    source_migrations: 224,
    live_ledger_rows: 254,
    same_version_and_name: 45,
    same_name_different_version: 131,
    same_name_different_version_content_equal: 90,
    same_name_different_version_content_drift: 41,
    source_only_names: 48,
    live_only_names: 82,
    source_version_conflicts: 0,
    live_version_conflicts: 0,
  });
  assert.equal(manifest.comparison.same_name_different_version.length, 131);
  assert.equal(manifest.comparison.source_only_names.length, 48);
  assert.equal(manifest.comparison.live_only_names.length, 82);
  assert.deepEqual(manifest.comparison.live_only_categories, {
    alpha16_replay: 49,
    dev_manual_repair: 4,
    northflank_runtime: 7,
    other_repair_final_receipt: 22,
  });
  assert.equal(
    manifest.comparison.same_name_different_version
      .filter(row => row.content_equal_after_crlf_and_edge_trim_normalization).length,
    90,
  );
});

test("Northflank UAT-only migration receipts are frozen exactly", () => {
  const expected = new Map([
    ["20260824182754", "b62070eb2f8fbdd71d2e3abe18cd8b95"],
    ["20260824183338", "31721f7da10dff2a8bef038f4c52a6e0"],
    ["20260824183525", "97230fde4712ffd2b72c7a261e8f1c3b"],
    ["20260824183905", "3bc532cfa64f598de13a39c56a20e776"],
    ["20260824184140", "f9d4f4fe0c1e554c4c4d71198597c93b"],
    ["20260824190050", "092d87742b0c0da0f4c620fd75d443fa"],
    ["20260824215911", "f92ca8622eb94de5b152ebe59131623f"],
  ]);
  const rows = manifest.ledger.rows.filter(row => expected.has(row.version));
  assert.equal(rows.length, expected.size);
  for (const row of rows) assert.equal(row.sql_md5, expected.get(row.version));
});

test("baseline capture inventory includes state excluded from a default managed-schema dump", () => {
  assert.deepEqual(manifest.schema_capture_inventory.user_schemas,
    ["authorization_private", "cron", "public", "solver_private"]);
  assert.equal(manifest.schema_capture_inventory.managed_schema_policies.length, 4);
  assert.deepEqual(
    manifest.schema_capture_inventory.managed_schema_policies.map(row => row.policy),
    [
      "profile_avatars_self_delete_v1",
      "profile_avatars_self_insert_v1",
      "profile_avatars_self_select_v1",
      "profile_avatars_self_update_v1",
    ],
  );
  assert.equal(manifest.schema_capture_inventory.storage_buckets.length, 1);
  assert.equal(manifest.schema_capture_inventory.storage_buckets[0].id, "profile-avatars");
  assert.equal(manifest.schema_capture_inventory.realtime_publication_members.length, 2);
  assert.equal(manifest.schema_capture_inventory.cron_jobs.length, 1);
  assert.equal(manifest.schema_capture_inventory.cron_jobs[0].command_md5,
    "b7fd6127d5addd3ed945f227129d1c59");
});

test("safety decision forbids migration replay and ledger repair", () => {
  assert.equal(manifest.safety_decision.normal_migrator, "STOP");
  assert.equal(manifest.safety_decision.baseline_sql_in_this_change, false);
  assert.equal(manifest.safety_decision.ledger_repair_in_this_change, false);
  assert.equal(manifest.safety_decision.uat_mutation_in_this_change, false);
  assert.deepEqual(manifest.safety_decision.do_not_rerun_source_versions, [
    "20260822160000_b4f165_strategy_source_of_truth",
    "20260822220000_b4f169_deterministic_fairness_quality_gate",
  ]);
  assert.match(runbook, /Normal migration push[\s\S]*remain \*\*STOP\*\*/u);
  assert.match(runbook, /intentionally contains \*\*no baseline SQL\*\*/u);
});

test("read-only preflight is SELECT-only and pins identity plus fingerprint", () => {
  assert.match(preflight, /RUN ONLY IN SZAFUNEK UAT PROJECT nhthrtpkfpmufmrmdyjg/u);
  assert.match(preflight, new RegExp(manifest.ledger.fingerprint, "u"));
  assert.match(preflight, /GO — READ-ONLY SCHEMA CAPTURE ONLY/u);
  assert.match(preflight, /STOP — IDENTITY, LEDGER, OR MATRIX STATE CHANGED/u);
  const executable = preflight
    .replace(/\/\*[\s\S]*?\*\//gu, "")
    .replace(/^\s*--.*$/gmu, "");
  const statements = executable.split(";").map(value => value.trim()).filter(Boolean);
  assert.ok(statements.length >= 12);
  for (const statement of statements) {
    assert.match(statement, /^select\b/iu, statement.slice(0, 120));
    assert.doesNotMatch(statement,
      /^(?:insert|update|delete|merge|create|alter|drop|truncate|grant|revoke|call|do|notify)\b/iu);
  }
  assert.doesNotMatch(executable,
    /\b(?:insert|update|delete|merge|create|alter|drop|truncate|grant|revoke)\s+(?:into|from|table|function|policy|schema_migrations)\b/iu);
});

test("runbook requires a second reviewed baseline PR and isolated restore", () => {
  assert.match(runbook, /Open a separate baseline SQL PR/u);
  assert.match(runbook, /fresh isolated test project/u);
  assert.match(runbook, /four custom `storage\.objects` policies/u);
  assert.match(runbook, /one active `pg_cron` job/u);
  assert.match(runbook, /No storage object data, employee data, auth users, secrets/u);
});
