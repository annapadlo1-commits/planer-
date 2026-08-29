import assert from "node:assert/strict";
import { Buffer } from "node:buffer";
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

const taggedField = value => value === null || value === undefined
  ? "N"
  : `V${Buffer.from(String(value), "utf8").toString("hex")}`;
const taggedArray = value => value === null || value === undefined
  ? "N"
  : taggedField([...value].sort((left, right) => Buffer.compare(
    Buffer.from(left, "utf8"),
    Buffer.from(right, "utf8"),
  )).join("\n"));
const record = (kind, objectKey, fields) => ({
  kind,
  objectKey,
  recordText: [kind, ...fields].join("|"),
});
const byteCompare = (left, right) => Buffer.compare(
  Buffer.from(left, "utf8"),
  Buffer.from(right, "utf8"),
);

const buildCompanionRecords = inventory => [
  ...inventory.managed_schema_policies.map(row => record(
    "managed_policy",
    `${row.schema}.${row.table}.${row.policy}`,
    [
      taggedField(row.schema),
      taggedField(row.table),
      taggedField(row.policy),
      taggedField(row.permissive),
      taggedArray(row.roles),
      taggedField(row.command),
      taggedField(row.using_expression),
      taggedField(row.with_check_expression),
    ],
  )),
  ...inventory.managed_policy_tables.map(row => record(
    "managed_policy_table",
    `${row.schema}.${row.table}`,
    [
      taggedField(row.schema),
      taggedField(row.table),
      taggedField(row.rls_enabled),
      taggedField(row.force_rls),
    ],
  )),
  ...inventory.storage_buckets.map(row => record(
    "storage_bucket",
    row.id,
    [
      taggedField(row.id),
      taggedField(row.name),
      taggedField(row.public),
      taggedField(row.file_size_limit),
      taggedArray(row.allowed_mime_types),
      taggedField(row.avif_autodetection),
      taggedField(row.type),
      taggedField(row.versioning_status),
    ],
  )),
  ...inventory.realtime_publications.map(row => record(
    "realtime_publication",
    row.publication,
    [
      taggedField(row.publication),
      taggedField(row.owner),
      taggedField(row.all_tables),
      taggedField(row.publish_insert),
      taggedField(row.publish_update),
      taggedField(row.publish_delete),
      taggedField(row.publish_truncate),
      taggedField(row.publish_via_root),
    ],
  )),
  ...inventory.realtime_publication_members.map(row => record(
    "realtime_publication_member",
    `${row.publication}.${row.schema}.${row.table}`,
    [
      taggedField(row.publication),
      taggedField(row.schema),
      taggedField(row.table),
      taggedField(row.all_columns),
      taggedArray(row.columns),
      taggedField(row.row_filter),
    ],
  )),
  ...inventory.realtime_publication_schemas.map(row => record(
    "realtime_publication_schema",
    `${row.publication}.${row.schema}`,
    [taggedField(row.publication), taggedField(row.schema)],
  )),
  ...inventory.event_triggers.map(row => record(
    "event_trigger",
    row.name,
    [
      taggedField(row.name),
      taggedField(row.event),
      taggedField(row.enabled),
      taggedField(row.owner),
      taggedField(row.function),
      taggedArray(row.tags),
    ],
  )),
  ...inventory.cron_jobs.map(row => record(
    "cron_job",
    row.jobname ?? `#${row.jobid}`,
    [
      taggedField(row.jobname),
      taggedField(row.schedule),
      taggedField(row.active),
      taggedField(row.database),
      taggedField(row.username),
      taggedField(row.nodename),
      taggedField(row.nodeport),
      taggedField(row.command_sha256),
      taggedField(row.command_bytes),
    ],
  )),
  ...inventory.extensions.map(row => record(
    "extension",
    row.name,
    [
      taggedField(row.name),
      taggedField(row.schema),
      taggedField(row.version),
      taggedField(row.relocatable),
    ],
  )),
  ...inventory.user_schema_details.map(row => record(
    "user_schema",
    row.schema,
    [taggedField(row.schema), taggedField(row.owner), taggedArray(row.acl_items)],
  )),
  ...inventory.default_acls.map(row => record(
    "default_acl",
    `${row.grantor}.${row.schema ?? ""}.${row.object_type}`,
    [
      taggedField(row.grantor),
      taggedField(row.schema),
      taggedField(row.object_type),
      taggedArray(row.acl_items),
    ],
  )),
].sort((left, right) =>
  byteCompare(left.kind, right.kind) ||
  byteCompare(left.objectKey, right.objectKey) ||
  byteCompare(left.recordText, right.recordText)
);

test("Phase 4A.2 pins the reviewed source and isolated UAT", () => {
  assert.equal(manifest.schema_version, 2);
  assert.equal(manifest.source.repository, "annapadlo1-commits/planer-");
  assert.equal(manifest.source.branch, "codex/uat-consolidated-fixes");
  assert.equal(manifest.source.commit, "5565c50370cb9436a76d1e6d7013250eaad2bece");
  assert.equal(manifest.source.tree, "a8f6148cc0ff8960638553951972ba949b464d84");
  assert.equal(manifest.uat.project_ref, "nhthrtpkfpmufmrmdyjg");
  assert.equal(manifest.uat.branch_name, "dynamic-matrix-solver-v2");
  assert.equal(manifest.uat.preview_project_status, "ACTIVE_HEALTHY");
  assert.equal(manifest.uat.migration_status, "MIGRATIONS_FAILED");
  assert.equal(manifest.uat.identity_control.enabled, true);
  assert.equal(manifest.uat.identity_control.config.projectRef, manifest.uat.project_ref);
  assert.equal(manifest.uat.identity_control.config.environment, "ISOLATED_UAT");
  assert.deepEqual(manifest.catalog_rendering_context, {
    search_path: "\"\\$user\", public, extensions",
    capture_role: "postgres",
    server_version_num: "170006",
    quote_all_identifiers: "off",
    capture_role_bypasses_rls: true,
  });
});

test("preflight artifact bytes, file hash and Git blob are pinned", () => {
  const bytes = Buffer.from(preflight, "utf8");
  const gitBlob = createHash("sha1")
    .update(Buffer.concat([Buffer.from(`blob ${bytes.length}\0`, "utf8"), bytes]))
    .digest("hex");
  const fileSha256 = createHash("sha256").update(bytes).digest("hex");

  assert.deepEqual(manifest.preflight_artifact, {
    path: "docs/PHASE4A2_UAT_BASELINE_READ_ONLY_PREFLIGHT.sql",
    bytes: 21156,
    git_blob_sha1: "9d43a89a0e533b336e8d071832f321fcc0774972",
    file_sha256: "52b9412dbaa71c9cebafaf1cbf9baef74d029deff2e7672a606c438297c690e9",
  });
  assert.equal(bytes.length, manifest.preflight_artifact.bytes);
  assert.equal(gitBlob, manifest.preflight_artifact.git_blob_sha1);
  assert.equal(fileSha256, manifest.preflight_artifact.file_sha256);
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

test("baseline inventory captures complete managed companion semantics", () => {
  const inventory = manifest.schema_capture_inventory;
  const predicate = "((bucket_id = 'profile-avatars'::text) AND ((storage.foldername(name))[1] = (( SELECT auth.uid() AS uid))::text))";

  assert.deepEqual(inventory.user_schemas,
    ["authorization_private", "cron", "public", "solver_private"]);
  assert.deepEqual(inventory.user_schemas,
    inventory.user_schema_details.map(row => row.schema));
  assert.equal(inventory.user_schema_details.length, 4);

  assert.equal(inventory.managed_schema_policies.length, 4);
  const policies = new Map(inventory.managed_schema_policies.map(row => [row.command, row]));
  for (const policy of policies.values()) {
    assert.equal(policy.permissive, "PERMISSIVE");
    assert.deepEqual(policy.roles, ["authenticated"]);
    assert.equal(policy.schema, "storage");
    assert.equal(policy.table, "objects");
  }
  assert.equal(policies.get("DELETE").using_expression, predicate);
  assert.equal(policies.get("DELETE").with_check_expression, null);
  assert.equal(policies.get("INSERT").using_expression, null);
  assert.equal(policies.get("INSERT").with_check_expression, predicate);
  assert.equal(policies.get("SELECT").using_expression, predicate);
  assert.equal(policies.get("SELECT").with_check_expression, null);
  assert.equal(policies.get("UPDATE").using_expression, predicate);
  assert.equal(policies.get("UPDATE").with_check_expression, predicate);
  assert.deepEqual(inventory.managed_policy_tables, [{
    table: "objects",
    schema: "storage",
    force_rls: false,
    rls_enabled: true,
  }]);

  assert.deepEqual(inventory.storage_buckets, [{
    id: "profile-avatars",
    name: "profile-avatars",
    type: "STANDARD",
    public: false,
    file_size_limit: 5242880,
    versioning_status: "DISABLED",
    allowed_mime_types: ["image/jpeg", "image/png", "image/webp"],
    avif_autodetection: false,
  }]);
  assert.deepEqual(inventory.realtime_publications, [{
    owner: "postgres",
    all_tables: false,
    publication: "supabase_realtime",
    publish_delete: true,
    publish_insert: true,
    publish_update: true,
    publish_truncate: true,
    publish_via_root: false,
  }]);
  assert.equal(inventory.realtime_publication_members.length, 2);
  for (const member of inventory.realtime_publication_members) {
    assert.equal(member.all_columns, true);
    assert.equal(member.columns, null);
    assert.equal(member.row_filter, null);
  }
  assert.deepEqual(inventory.realtime_publication_schemas, []);

  assert.equal(inventory.cron_jobs.length, 1);
  assert.equal(inventory.cron_jobs[0].command_md5,
    "b7fd6127d5addd3ed945f227129d1c59");
  assert.equal(inventory.cron_jobs[0].command_sha256,
    "bcc3a7aec4daf8ce6cf981bfae60cd4de011b1b1d8a44f7f2879b18f47c893d4");
  assert.equal(inventory.cron_jobs[0].command_bytes, 57);
  assert.equal(Object.hasOwn(inventory.cron_jobs[0], "command"), false);
  assert.equal(inventory.default_acl_count, 29);
  assert.equal(inventory.default_acls.length, 29);
});

test("manifest independently reconstructs the complete companion fingerprint", () => {
  const records = buildCompanionRecords(manifest.schema_capture_inventory);
  const categoryCounts = Object.fromEntries(
    Object.keys(manifest.companion_snapshot.category_counts).map(kind => [
      kind,
      records.filter(row => row.kind === kind).length,
    ]),
  );
  const fingerprint = createHash("sha256")
    .update(records.map(row => row.recordText).join("\n"), "utf8")
    .digest("hex");

  assert.equal(manifest.companion_snapshot.serialization_version,
    "phase4a2-companion-v2");
  assert.match(manifest.companion_snapshot.fingerprint_algorithm,
    /SHA-256[\s\S]*tagged UTF-8 hex[\s\S]*C collation/u);
  assert.deepEqual(categoryCounts, manifest.companion_snapshot.category_counts);
  assert.equal(Object.values(categoryCounts).reduce((sum, count) => sum + count, 0), 56);
  assert.equal(records.length, manifest.companion_snapshot.record_count);
  assert.equal(records.length, 56);
  assert.equal(fingerprint, manifest.companion_snapshot.fingerprint_sha256);
  assert.equal(fingerprint,
    "e7f678581129e4f5669c668095e076c9e4e62e10f2fd7c913725cb559e4c074d");
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
  assert.match(preflight, new RegExp(manifest.companion_snapshot.fingerprint_sha256, "u"));
  assert.match(preflight, /companion_snapshot\.companion_record_count=56/u);
  assert.match(preflight, /current_user='postgres'/u);
  assert.match(preflight, /current_setting\('server_version_num'\)='170006'/u);
  assert.ok(preflight.includes(String.raw`current_setting('search_path')=E'"\\$user", public, extensions'`));
  assert.match(preflight, /current_setting\('quote_all_identifiers'\)='off'/u);
  assert.match(preflight, /rolsuper or rolbypassrls/u);
  assert.match(preflight, /has_table_privilege\(current_user,'cron\.job','SELECT'\)/u);
  assert.match(preflight, /has_table_privilege\(current_user,'storage\.buckets','SELECT'\)/u);
  assert.match(preflight, /select count\(\*\)=1[\s\S]*enabled is true[\s\S]*ISOLATED_UAT/u);
  assert.match(preflight, /qual as using_expression/u);
  assert.match(preflight, /with_check as with_check_expression/u);
  for (const kind of Object.keys(manifest.companion_snapshot.category_counts)) {
    assert.match(preflight, new RegExp(`'${kind}'`, "u"));
  }
  assert.match(preflight, /GO — READ-ONLY SCHEMA CAPTURE ONLY/u);
  assert.match(preflight,
    /STOP — IDENTITY, LEDGER, MATRIX, OR COMPANION SNAPSHOT CHANGED/u);
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
  assert.match(runbook, /Required future procedure \(not authorization\)/u);
  assert.match(runbook, /does not authorize a dump, restore/u);
  assert.match(runbook, /Remain on the reviewed Phase 4A\.2 gate commit/u);
  assert.match(runbook,
    /git hash-object docs\/PHASE4A2_UAT_BASELINE_READ_ONLY_PREFLIGHT\.sql/u);
  assert.match(runbook, new RegExp(manifest.preflight_artifact.git_blob_sha1, "u"));
  assert.match(runbook,
    /git rev-parse '5565c50370cb9436a76d1e6d7013250eaad2bece\^\{tree\}'/u);
  assert.match(runbook, /git merge-base --is-ancestor 5565c503/u);
  assert.match(runbook,
    /git diff --exit-code 5565c503[\s\S]*-- supabase\/migrations/u);
  assert.match(runbook,
    /Only after `GO`[\s\S]*check out `5565c503[\s\S]*only now/u);
  assert.match(runbook, /fresh disposable isolated test project/u);
  assert.match(runbook, /separate baseline SQL PR/u);
  assert.match(runbook, /four custom `storage\.objects` policies/u);
  assert.match(runbook, /one active `pg_cron` job/u);
  assert.match(runbook, /No storage object data, employee data, auth users, secrets/u);
  assert.doesNotMatch(runbook,
    /1\. Check out the exact source commit[\s\S]*Run `docs\/PHASE4A2_UAT_BASELINE_READ_ONLY_PREFLIGHT\.sql`/u);
});
