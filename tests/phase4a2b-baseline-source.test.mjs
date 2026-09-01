import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFile, readdir } from "node:fs/promises";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { canonicalGitBytes, canonicalGitText } from "./helpers/canonical-git-bytes.mjs";

const baselineUrl = new URL("../supabase/baseline/phase4a2b/", import.meta.url);
const manifest = JSON.parse(await readFile(new URL("manifest.json", baselineUrl), "utf8"));
const phase4a2Inventory = JSON.parse(await readFile(new URL(
  "../docs/phase4a2-uat-migration-reconciliation.json",
  import.meta.url,
), "utf8"));
const managedAclEvidence = JSON.parse(await readFile(new URL(
  "../docs/phase4a2b-managed-acl-catalogs.json",
  import.meta.url,
), "utf8"));
const builder = await readFile(new URL(
  "../scripts/phase4a2b/build_baseline.py",
  import.meta.url,
), "utf8");
const assembler = await readFile(new URL(
  "../scripts/phase4a2b/assemble_baseline.py",
  import.meta.url,
), "utf8");
const bucketProvisioner = await readFile(new URL(
  "../scripts/phase4a2b/provision_local_storage_bucket.mjs",
  import.meta.url,
), "utf8");
const bucketProvisionerPath = fileURLToPath(new URL(
  "../scripts/phase4a2b/provision_local_storage_bucket.mjs",
  import.meta.url,
));
const managedAclQueryWorktree = await readFile(new URL(
  "../scripts/phase4a2b/managed_acl_catalog_v2.sql",
  import.meta.url,
));
const managedAclQuery = canonicalGitText(
  "scripts/phase4a2b/managed_acl_catalog_v2.sql",
  managedAclQueryWorktree,
);
const restoreContract = await readFile(new URL(
  "../supabase/tests/phase4a2b_baseline_restore_contract.sql",
  import.meta.url,
), "utf8");
const runtimeContract = await readFile(new URL(
  "../supabase/tests/runtime_contract_guard_v2.sql",
  import.meta.url,
), "utf8");

const sha256 = value => createHash("sha256").update(value).digest("hex");

const tokenizeStatements = sql => {
  const statements = [];
  let clean = "";
  let safe = "";
  let state = "normal";
  let dollarTag = null;
  let blockDepth = 0;
  let escapeString = false;

  const whitespace = () => {
    clean += " ";
    safe += " ";
  };
  const flush = () => {
    const cleanSql = clean.trim();
    const safeSql = safe.trim();
    if (cleanSql) statements.push({ clean: cleanSql, safe: safeSql });
    clean = "";
    safe = "";
  };

  for (let index = 0; index < sql.length;) {
    if (state === "normal") {
      if (sql.startsWith("--", index)) {
        state = "line-comment";
        whitespace();
        index += 2;
        continue;
      }
      if (sql.startsWith("/*", index)) {
        state = "block-comment";
        blockDepth = 1;
        whitespace();
        index += 2;
        continue;
      }
      if (sql[index] === "'") {
        escapeString = /[Ee]/u.test(sql[index - 1] ?? "")
          && !/[A-Za-z0-9_]/u.test(sql[index - 2] ?? "");
        state = "single";
        clean += sql[index];
        safe += " ";
        index += 1;
        continue;
      }
      if (sql[index] === '"') {
        state = "double";
        clean += sql[index];
        safe += sql[index];
        index += 1;
        continue;
      }
      if (sql[index] === "$") {
        const match = sql.slice(index).match(/^\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$/u);
        if (match) {
          [dollarTag] = match;
          state = "dollar";
          clean += dollarTag;
          safe += " ";
          index += dollarTag.length;
          continue;
        }
      }
      if (sql[index] === ";") {
        flush();
        index += 1;
        continue;
      }
      clean += sql[index];
      safe += sql[index];
      index += 1;
      continue;
    }

    if (state === "line-comment") {
      if (sql[index] === "\n") {
        state = "normal";
        clean += "\n";
        safe += "\n";
      }
      index += 1;
      continue;
    }

    if (state === "block-comment") {
      if (sql.startsWith("/*", index)) {
        blockDepth += 1;
        index += 2;
        continue;
      }
      if (sql.startsWith("*/", index)) {
        blockDepth -= 1;
        index += 2;
        if (blockDepth === 0) state = "normal";
        continue;
      }
      if (sql[index] === "\n") {
        clean += "\n";
        safe += "\n";
      }
      index += 1;
      continue;
    }

    if (state === "single") {
      if (escapeString && sql[index] === "\\" && index + 1 < sql.length) {
        clean += sql.slice(index, index + 2);
        safe += "  ";
        index += 2;
        continue;
      }
      if (sql.startsWith("''", index)) {
        clean += "''";
        safe += "  ";
        index += 2;
        continue;
      }
      clean += sql[index];
      safe += " ";
      if (sql[index] === "'") state = "normal";
      index += 1;
      continue;
    }

    if (state === "double") {
      if (sql.startsWith('""', index)) {
        clean += '""';
        safe += '""';
        index += 2;
        continue;
      }
      clean += sql[index];
      safe += sql[index];
      if (sql[index] === '"') state = "normal";
      index += 1;
      continue;
    }

    if (state === "dollar") {
      if (sql.startsWith(dollarTag, index)) {
        clean += dollarTag;
        safe += " ".repeat(dollarTag.length);
        index += dollarTag.length;
        state = "normal";
        continue;
      }
      clean += sql[index];
      safe += " ";
      index += 1;
    }
  }

  assert.ok(state === "normal" || state === "line-comment", `unterminated SQL state ${state}`);
  assert.equal(blockDepth, 0);
  flush();
  return statements;
};

const loadBaselineFiles = async () => {
  const files = [];
  for (const entry of manifest.files) {
    const worktreeData = await readFile(new URL(entry.path, baselineUrl));
    const data = canonicalGitBytes(`supabase/baseline/phase4a2b/${entry.path}`, worktreeData);
    files.push({ ...entry, data, text: data.toString("utf8") });
  }
  return files;
};

test("manifest pins the approved capture and deterministic routing", async () => {
  assert.equal(manifest.format, "phase4a2b-neutral-baseline-v1");
  assert.deepEqual(manifest.capture, {
    run_id: 33301678124,
    workflow_commit: "bf577d2df7fdcb9bdd8840117c5c34a601d573b4",
    base_commit: "9ce77eeadffcf46a7d8842e914b43f4fbcfddbfc",
    frozen_source_commit: "5565c50370cb9436a76d1e6d7013250eaad2bece",
    frozen_source_tree: "a8f6148cc0ff8960638553951972ba949b464d84",
    raw_schema_bytes: 2679643,
    raw_schema_sha256: "7628c7732e0dbc8402cab65fd1f34d3779c7407b0988a0344bb8914891786870",
    raw_statement_count: 4218,
  });
  assert.deepEqual(manifest.routing.section_counts, {
    core: 2505,
    extensions: 6,
    extension_comments: 6,
    environment: 6,
    app_default_acl: 3,
    managed_default_acl: 3,
    platform_managed_acl: 67,
    event_triggers: 6,
  });
  assert.equal(manifest.routing.restore_guard_pairs_removed, 1);
  assert.equal(manifest.routing.source_project_ref_occurrences_tokenized, 5);
  assert.equal(manifest.routing.cron_jobs_replayed, 0);
  assert.equal(manifest.routing.platform_managed_acl_sections_observe_only, 67);
  assert.equal(manifest.routing.platform_managed_acl_section_bytes, 31793);
  assert.equal(
    manifest.routing.platform_managed_acl_section_sha256,
    "4aeb80754c981402c5eba9b052ee312305113496c354c1e19ec40245b99e3b45",
  );

  const pgmqInventory = {
    queues: [{ queue_name: "schedule_optimizer_v2", is_partitioned: false, is_unlogged: false }],
    tables: [
      { schema: "pgmq", table: "a_schedule_optimizer_v2", relkind: "r", relpersistence: "p", rls_enabled: false, force_rls: false, owner: "postgres", acl: "{pg_monitor=r/postgres,postgres=arwdDxtm/postgres}" },
      { schema: "pgmq", table: "q_schedule_optimizer_v2", relkind: "r", relpersistence: "p", rls_enabled: false, force_rls: false, owner: "postgres", acl: "{pg_monitor=r/postgres,postgres=arwdDxtm/postgres}" },
    ],
    sequences: [{ schema: "pgmq", sequence: "q_schedule_optimizer_v2_msg_id_seq", owner: "postgres", acl: "{pg_monitor=r/postgres,postgres=rwU/postgres}" }],
  };
  const payload = JSON.stringify(pgmqInventory);
  assert.equal(Buffer.byteLength(payload), 664);
  assert.equal(sha256(payload), manifest.supplemental_read_only_inventory.pgmq_canonical_json_sha256);
  assert.equal(manifest.supplemental_read_only_inventory.message_rows_read, 0);
  assert.equal(manifest.supplemental_read_only_inventory.uat_mutations, 0);
  assert.deepEqual(manifest.supplemental_read_only_inventory.managed_acl_catalog, {
    serialization: "phase4a2b-managed-acl-v2",
    query_path: "scripts/phase4a2b/managed_acl_catalog_v2.sql",
    recorded_at_utc: "2026-08-30T10:49:11Z",
    uat_identity_verified: true,
    workflow_run_id: 33307376650,
    record_count: 75,
    canonical_bytes: 12186,
    canonical_sha256: "3266bb4037115a7f14ee4e612b1d27eb56a6b8dd2eed2774181c4a9a7264eeed",
    business_rows_read: 0,
    uat_mutations: 0,
  });

  const managedCompatibility =
    manifest.platform_companion.restore_expectation.platform_managed_acl_compatibility;
  assert.equal(managedAclEvidence.format, "phase4a2b-managed-acl-evidence-v2");
  assert.equal(managedAclEvidence.serialization.version, "phase4a2b-managed-acl-v2");
  assert.equal(managedAclEvidence.serialization.canonical_query_path,
    "scripts/phase4a2b/managed_acl_catalog_v2.sql");
  const managedQueryBlobSha = createHash("sha1")
    .update(`blob ${Buffer.byteLength(managedAclQuery)}\0`)
    .update(managedAclQuery)
    .digest("hex");
  assert.equal(managedQueryBlobSha, managedAclEvidence.serialization.canonical_query_blob_sha);
  assert.match(managedAclQuery, /pg_get_function_identity_arguments\(procedure_row\.oid\)/u);
  assert.match(managedAclQuery, /namespace_row\.nspname::text as schema_name/u);
  assert.match(managedAclQuery, /format\([\s\S]*pg_get_function_identity_arguments[\s\S]*\)::text/u);
  assert.match(managedAclQuery, /order by canonical_line collate "C"/u);
  assert.doesNotMatch(managedAclQuery,
    /^\s*(?:insert|update|delete|merge|truncate|copy|call|do|create|alter|drop|grant|revoke)\b/imu);

  const parseManagedLine = line => {
    const fields = line.split("|");
    assert.equal(fields.length, 6, line);
    const [kind, schema, identity, subkind, owner, acl] = fields;
    return {
      line, kind, schema, identity, subkind, owner, acl,
      key: [kind, schema, identity, subkind].join("|"),
    };
  };
  const sortC = values => [...values].sort((left, right) =>
    Buffer.compare(Buffer.from(left, "utf8"), Buffer.from(right, "utf8")));
  const aclItems = acl => acl ? acl.split(",") : [];
  const lineOf = row =>
    [row.kind, row.schema, row.identity, row.subkind, row.owner, row.acl].join("|");
  const normalizeFreshExtensionRepresentation = row => ({
    ...row,
    owner: row.owner === "supabase_admin" ? "postgres" : row.owner,
    acl: sortC(aclItems(row.acl)
      .filter(item => !item.startsWith("supabase_admin="))
      .map(item => item.replace(/\/supabase_admin$/u, "/postgres")))
      .join(","),
  });

  for (const [label, expected] of [
    ["source_uat", managedCompatibility.source_uat],
    ["fresh_restore", managedCompatibility.fresh_restore],
  ]) {
    const catalog = managedAclEvidence[label];
    const catalogPayload = catalog.canonical_lines.join("\n");
    assert.equal(catalog.serialization ?? managedAclEvidence.serialization.version,
      "phase4a2b-managed-acl-v2");
    assert.equal(catalog.canonical_lines.length, expected.record_count);
    assert.deepEqual(catalog.canonical_lines, sortC(catalog.canonical_lines));
    assert.equal(new Set(catalog.canonical_lines).size, catalog.canonical_lines.length);
    assert.equal(Buffer.byteLength(catalogPayload), expected.canonical_bytes);
    assert.equal(sha256(catalogPayload), expected.canonical_sha256);
    const functionRows = catalog.canonical_lines
      .map(parseManagedLine)
      .filter(row => row.kind === "function");
    assert.equal(functionRows.length, 67);
    assert.equal(functionRows.every(row => row.identity.endsWith(")")), true);
  }

  const sourceRows = managedAclEvidence.source_uat.canonical_lines.map(parseManagedLine);
  const freshRows = managedAclEvidence.fresh_restore.canonical_lines.map(parseManagedLine);
  const sourceByKey = new Map(sourceRows.map(row => [row.key, row]));
  const freshByKey = new Map(freshRows.map(row => [row.key, row]));
  assert.deepEqual(sortC([...sourceByKey.keys()]), sortC([...freshByKey.keys()]));

  const derived = {
    exact: [],
    extension_owner_grantor_and_owner_acl_representation: [],
    dashboard_user_privilege_delta: [],
    cron_job_run_details_trigger_privilege_delta: [],
    unclassified: [],
  };
  for (const [key, sourceRow] of sourceByKey) {
    const freshRow = freshByKey.get(key);
    if (lineOf(sourceRow) === lineOf(freshRow)) {
      derived.exact.push(key);
      continue;
    }
    if (sourceRow.schema === "extensions"
      && sourceRow.owner === "postgres"
      && freshRow.owner === "supabase_admin") {
      const normalized = normalizeFreshExtensionRepresentation(freshRow);
      if (lineOf(sourceRow) === lineOf(normalized)) {
        derived.extension_owner_grantor_and_owner_acl_representation.push(key);
        continue;
      }
      const sourceAcl = new Set(aclItems(sourceRow.acl));
      const normalizedAcl = new Set(aclItems(normalized.acl));
      const missing = [...sourceAcl].filter(item => !normalizedAcl.has(item));
      const extra = [...normalizedAcl].filter(item => !sourceAcl.has(item));
      if (missing.length === 1 && missing[0].startsWith("dashboard_user=")
        && extra.length === 0) {
        derived.dashboard_user_privilege_delta.push(key);
        continue;
      }
    }
    if (key === "relation|cron|cron.job_run_details|r") {
      derived.cron_job_run_details_trigger_privilege_delta.push(key);
      continue;
    }
    derived.unclassified.push(key);
  }
  for (const values of Object.values(derived)) values.sort((left, right) =>
    Buffer.compare(Buffer.from(left, "utf8"), Buffer.from(right, "utf8")));

  assert.deepEqual({
    exact: derived.exact.length,
    extension_owner_grantor_and_owner_acl_representation:
      derived.extension_owner_grantor_and_owner_acl_representation.length,
    dashboard_user_privilege_delta: derived.dashboard_user_privilege_delta.length,
    cron_job_run_details_trigger_privilege_delta:
      derived.cron_job_run_details_trigger_privilege_delta.length,
    unmatched: 0,
    unclassified: derived.unclassified.length,
  }, managedCompatibility.difference_counts);
  assert.deepEqual(derived.exact, sortC(managedAclEvidence.comparison.exact.identities));
  assert.deepEqual(
    derived.extension_owner_grantor_and_owner_acl_representation,
    sortC(managedAclEvidence.comparison
      .extension_owner_grantor_and_owner_acl_representation.identities),
  );
  assert.deepEqual(
    derived.dashboard_user_privilege_delta,
    sortC(managedAclEvidence.comparison.dashboard_user_privilege_delta.identities),
  );
  assert.deepEqual(
    derived.cron_job_run_details_trigger_privilege_delta,
    sortC(managedAclEvidence.comparison
      .cron_job_run_details_trigger_privilege_delta.identities),
  );
  assert.deepEqual(derived.unclassified, []);
  assert.deepEqual(managedAclEvidence.comparison.source_only_identities, []);
  assert.deepEqual(managedAclEvidence.comparison.fresh_only_identities, []);
  assert.deepEqual(managedAclEvidence.comparison.unclassified_identities, []);
  assert.equal(
    Object.values(managedCompatibility.difference_counts)
      .slice(0, 4).reduce((sum, count) => sum + count, 0),
    75,
  );

  const dashboardObjects = derived.dashboard_user_privilege_delta.map(key => {
    const [kind, , identity] = key.split("|");
    return `${kind}:${identity.replace(/\(.*/u, "")}`;
  }).sort();
  assert.deepEqual(dashboardObjects, [
    "function:extensions.pg_stat_statements",
    "function:extensions.pg_stat_statements_info",
    "function:extensions.pg_stat_statements_reset",
    "relation:extensions.pg_stat_statements",
    "relation:extensions.pg_stat_statements_info",
  ]);
  assert.deepEqual(derived.cron_job_run_details_trigger_privilege_delta,
    ["relation|cron|cron.job_run_details|r"]);
  assert.deepEqual(managedAclEvidence.runtime_acceptance, {
    accepted_catalog: "fresh_restore only",
    source_uat_hash_is_runtime_accepted: false,
    accepted_record_count: 75,
    accepted_canonical_bytes: 14874,
    accepted_canonical_sha256:
      "7f9df875629efa3cc7ad63829b2293a4002e40b6257c05c7f911ed0d24c9eb27",
    multiple_hash_or_fallback: false,
  });
  assert.equal(managedAclEvidence.comparison.mutation_or_normalization, "prohibited");
  assert.equal(managedAclEvidence.safety.managed_acl_or_owner_mutations, false);
  assert.notEqual(managedCompatibility.source_uat.canonical_sha256,
    managedCompatibility.fresh_restore.canonical_sha256);
  assert.deepEqual(manifest.supplemental_read_only_inventory.publication_catalog, {
    recorded_at_utc: "2026-08-30T09:18:00Z",
    uat_identity_verified: true,
    record_count: 1,
    names: ["supabase_realtime"],
    business_rows_read: 0,
    uat_mutations: 0,
  });
  assert.deepEqual(manifest.supplemental_read_only_inventory.security_definer_search_paths, {
    recorded_at_utc: "2026-08-30T09:23:23Z",
    uat_identity_verified: true,
    routine_count: 519,
    distribution: {
      'search_path=""': 458,
      "search_path=public": 55,
      "search_path=public, pg_temp": 5,
      "search_path=public, solver_private, pg_temp": 1,
    },
    business_rows_read: 0,
    uat_mutations: 0,
  });
});

test("every generated SQL byte is covered by the manifest", async () => {
  const files = await loadBaselineFiles();
  const listed = manifest.files.map(entry => entry.path);
  const actual = (await readdir(baselineUrl, { withFileTypes: true }))
    .filter(entry => entry.isFile() && /\.(?:sql|tmpl)$/u.test(entry.name))
    .map(entry => entry.name)
    .sort();
  assert.deepEqual([...listed].sort(), actual);
  assert.equal(new Set(listed).size, listed.length);
  for (const file of files) {
    assert.equal(file.data.byteLength, file.bytes, `${file.path} byte count`);
    assert.equal(sha256(file.data), file.sha256, `${file.path} SHA-256`);
    assert.ok(file.bytes < 500000, `${file.path} exceeds review ceiling`);
  }
});

test("neutral SQL contains no remote identity, data load, or managed replay", async () => {
  const files = await loadBaselineFiles();
  const neutral = files.filter(file => !file.path.endsWith(".tmpl"));
  const neutralText = neutral.map(file => file.text).join("\n");
  const extensions = files.find(file => file.path === "00_platform_extensions.sql");
  assert.ok(extensions);
  assert.match(
    extensions.text,
    /CREATE SCHEMA IF NOT EXISTS "pgmq" AUTHORIZATION "postgres";\nGRANT USAGE ON SCHEMA "pgmq" TO "pg_monitor";[\s\S]*CREATE EXTENSION IF NOT EXISTS "pgmq" WITH SCHEMA "pgmq";/u,
  );
  assert.equal((extensions.text.match(/CREATE SCHEMA IF NOT EXISTS "pgmq"/gu) ?? []).length, 1);
  const creationDefaultAcl = tokenizeStatements(extensions.text)
    .filter(({ safe }) => /^ALTER DEFAULT PRIVILEGES\b/iu.test(safe));
  assert.equal(creationDefaultAcl.length, 7);
  const creationRevokes = creationDefaultAcl.filter(({ safe }) => /\bREVOKE ALL ON\b/iu.test(safe));
  const creationGrants = creationDefaultAcl.filter(({ safe }) => /\bGRANT ALL ON\b/iu.test(safe));
  assert.deepEqual(
    creationRevokes.map(({ safe }) => safe.match(/REVOKE ALL ON (FUNCTIONS|TABLES|SEQUENCES)/iu)?.[1]).sort(),
    ["FUNCTIONS", "SEQUENCES", "TABLES"],
  );
  for (const { safe } of creationRevokes) {
    assert.match(
      safe,
      /REVOKE\s+ALL\s+ON\s+(?:FUNCTIONS|TABLES|SEQUENCES)\s+FROM\s+PUBLIC,\s*"postgres",\s*"anon",\s*"authenticated",\s*"service_role"$/iu,
    );
  }
  assert.deepEqual(
    creationGrants.map(({ safe }) => safe.match(/GRANT ALL ON (FUNCTIONS|TABLES|SEQUENCES) TO (PUBLIC|"postgres")$/iu)?.slice(1)).sort(),
    [
      ["FUNCTIONS", '"postgres"'],
      ["FUNCTIONS", "PUBLIC"],
      ["SEQUENCES", '"postgres"'],
      ["TABLES", '"postgres"'],
    ].sort(),
  );
  assert.ok(
    manifest.files.findIndex(entry => entry.path === "00_platform_extensions.sql")
      < manifest.files.findIndex(entry => entry.path.startsWith("10_core_")),
    "creation defaults must precede application objects",
  );
  assert.doesNotMatch(neutralText, /nhthrtpkfpmufmrmdyjg|bdybebzvzapihjdauehg/u);
  assert.doesNotMatch(neutralText, /__PHASE4A2B_PROJECT_REF__/u);
  assert.doesNotMatch(neutralText, /^\s*(?:CREATE|ALTER|DROP)\s+EVENT\s+TRIGGER\b/imu);
  assert.doesNotMatch(neutralText, /^\s*CREATE\s+(?:PUBLICATION|SUBSCRIPTION)\b/imu);

  const statements = files.flatMap(file => tokenizeStatements(file.text));
  const managedAclRewrites = statements.filter(({ safe }) => (
    /^ALTER\s+EXTENSION\b/iu.test(safe)
    || (
      /^ALTER\s+(?:FUNCTION|TABLE|VIEW|SEQUENCE)\b/iu.test(safe)
      && /"(?:cron|extensions|vault)"/iu.test(safe)
      && /\bOWNER\s+TO\b/iu.test(safe)
    )
    || (
      /^(?:GRANT|REVOKE)\b/iu.test(safe)
      && (
        /\bON\s+(?:FUNCTION|TABLE|SEQUENCE|SCHEMA)\s+"(?:cron|extensions|vault)"/iu.test(safe)
        || /(?:\bTO|\bFROM)\s+"supabase_admin"/iu.test(safe)
      )
    )
  ));
  assert.deepEqual(managedAclRewrites, []);
  const defaultPrivilegeMutations = statements.filter(({ safe }) => /^ALTER DEFAULT PRIVILEGES\b/iu.test(safe));
  for (const { safe } of defaultPrivilegeMutations) {
    assert.doesNotMatch(safe, /(?:ROLE|TO|FROM)\s+"supabase_admin"/iu);
  }
  const forbidden = statements.filter(({ safe }) => /^\s*(?:INSERT|UPDATE|DELETE|MERGE|TRUNCATE|COPY|CALL|DO|BEGIN|COMMIT|ROLLBACK|ALTER\s+SYSTEM|VACUUM|ANALYZE|CLUSTER|REINDEX)\b/iu.test(safe));
  assert.deepEqual(forbidden, []);
  assert.equal(statements.filter(({ safe }) => /^CREATE\s+INDEX\s+CONCURRENTLY\b/iu.test(safe)).length, 0);
  assert.equal(statements.filter(({ safe }) => /\bpg_catalog\.setval\s*\(/iu.test(safe)).length, 0);
  const selects = statements.filter(({ safe }) => /^\s*SELECT\b/iu.test(safe));
  for (const { clean } of selects) {
    assert.ok(
      /^SELECT\s+(?:pg_catalog|"pg_catalog")\.(?:set_config|"set_config")\s*\(/iu.test(clean)
        || /^SELECT\s+"pgmq"\."create"\('schedule_optimizer_v2'\)$/iu.test(clean),
      `unexpected top-level SELECT: ${clean.slice(0, 160)}`,
    );
  }
});

test("environment routines are isolated behind exactly five tokens", async () => {
  const files = await loadBaselineFiles();
  const template = files.find(file => file.path.endsWith(".tmpl"));
  assert.ok(template);
  assert.equal(template.text.match(/__PHASE4A2B_PROJECT_REF__/gu)?.length, 5);
  assert.doesNotMatch(template.text, /nhthrtpkfpmufmrmdyjg|bdybebzvzapihjdauehg/u);
  assert.equal((template.text.match(/^CREATE FUNCTION /gmu) ?? []).length, 3);
  for (const name of manifest.routing.environment_function_names) {
    assert.match(template.text, new RegExp(`CREATE FUNCTION ".+"\\."${name}"\\(`, "u"));
  }
  for (const file of files.filter(file => file !== template)) {
    assert.doesNotMatch(file.text, /__PHASE4A2B_PROJECT_REF__/u);
    for (const name of manifest.routing.environment_function_names) {
      assert.doesNotMatch(file.text, new RegExp(`CREATE FUNCTION ".+"\\."${name}"\\(`, "u"));
    }
  }
});

test("platform companion restores only reviewed app-owned state", async () => {
  const companion = await readFile(new URL("99_platform_companion.sql", baselineUrl), "utf8");
  assert.match(companion, /^GRANT ALL ON SCHEMA "authorization_private" TO "postgres";$/mu);
  assert.match(companion, /^GRANT ALL ON SCHEMA "solver_private" TO "postgres";$/mu);
  assert.equal((companion.match(/^GRANT ALL ON SCHEMA /gmu) ?? []).length, 2);
  assert.match(companion, /^SELECT "pgmq"\."create"\('schedule_optimizer_v2'\);$/mu);
  assert.equal((companion.match(/^CREATE POLICY /gmu) ?? []).length, 4);
  for (const policy of manifest.platform_companion.storage_policies) {
    assert.match(companion, new RegExp(`CREATE POLICY "${policy}"`, "u"));
  }
  assert.equal((companion.match(/^ALTER PUBLICATION "supabase_realtime"/gmu) ?? []).length, 2);
  assert.match(companion, /Storage API/u);
  assert.doesNotMatch(companion, /storage"?\."?buckets"?\s*\(/iu);
  assert.equal(manifest.platform_companion.storage_bucket_provisioning, "Storage API");
  const defaultAclStatements = tokenizeStatements(companion)
    .filter(({ safe }) => /^ALTER DEFAULT PRIVILEGES\b/iu.test(safe));
  assert.equal(defaultAclStatements.length, 14);
  const defaultAclRevokes = defaultAclStatements.filter(({ safe }) => /\bREVOKE ALL ON\b/iu.test(safe));
  const defaultAclGrants = defaultAclStatements.filter(({ safe }) => /\bGRANT ALL ON\b/iu.test(safe));
  assert.equal(defaultAclRevokes.length, 3);
  assert.equal(defaultAclGrants.length, 11);
  assert.deepEqual(
    defaultAclRevokes.map(({ safe }) => safe.match(/REVOKE ALL ON (FUNCTIONS|TABLES|SEQUENCES)/iu)?.[1]).sort(),
    ["FUNCTIONS", "SEQUENCES", "TABLES"],
  );
  for (const { safe } of defaultAclRevokes) {
    assert.match(
      safe,
      /^ALTER\s+DEFAULT\s+PRIVILEGES\s+FOR\s+ROLE\s+"postgres"\s+IN\s+SCHEMA\s+"public"\s+REVOKE\s+ALL\s+ON\s+(?:FUNCTIONS|TABLES|SEQUENCES)\s+FROM\s+PUBLIC,\s*"postgres",\s*"anon",\s*"authenticated",\s*"service_role"$/iu,
    );
  }
  for (const { safe } of defaultAclGrants) {
    assert.match(safe, /^ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON (?:SEQUENCES|FUNCTIONS|TABLES) TO /iu);
    assert.doesNotMatch(safe, /supabase_admin/iu);
  }
  assert.ok(
    companion.indexOf("-- Normalize application defaults before replaying captured UAT grants.")
      < companion.indexOf("-- Name: DEFAULT PRIVILEGES FOR SEQUENCES"),
    "final default-ACL normalization must precede captured grants",
  );
  assert.deepEqual(manifest.platform_companion.default_acl_replay, {
    postgres_public_sections: 3,
    order: "last",
    supabase_admin_and_extension_managed: "observe-only",
    observed_total_records: 29,
    restore_total_records: 32,
    canonical_bytes: 3005,
    canonical_sha256: "c86785623e746bdaf24fabcb75b2a6019385b230830284d851ec27ad030933a3",
  });
  const defaultAclPayload = phase4a2Inventory.schema_capture_inventory.default_acls
    .map(entry => [
      entry.schema ?? "",
      entry.grantor,
      entry.object_type,
      [...(entry.acl_items ?? [])].sort().join(","),
    ])
    .sort((left, right) => {
      for (let index = 0; index < 3; index += 1) {
        const comparison = Buffer.compare(
          Buffer.from(left[index], "utf8"),
          Buffer.from(right[index], "utf8"),
        );
        if (comparison !== 0) return comparison;
      }
      return 0;
    })
    .map(entry => entry.join("|"))
    .join("\n");
  assert.equal(Buffer.byteLength(defaultAclPayload), 3005);
  assert.equal(
    sha256(defaultAclPayload),
    manifest.platform_companion.default_acl_replay.canonical_sha256,
  );
  assert.match(
    restoreContract,
    new RegExp(manifest.platform_companion.default_acl_replay.canonical_sha256, "u"),
  );
  assert.match(
    restoreContract,
    new RegExp(manifest.platform_companion.restore_expectation.platform_default_acl_compatibility.canonical_sha256, "u"),
  );
  const localPlatformDefaultAclRows = [
    { schema: "supabase_functions", grantor: "supabase_admin", object_type: "S", acl_items: ["postgres=rwU/supabase_admin", "anon=rwU/supabase_admin", "authenticated=rwU/supabase_admin", "service_role=rwU/supabase_admin"] },
    { schema: "supabase_functions", grantor: "supabase_admin", object_type: "f", acl_items: ["postgres=X/supabase_admin", "anon=X/supabase_admin", "authenticated=X/supabase_admin", "service_role=X/supabase_admin"] },
    { schema: "supabase_functions", grantor: "supabase_admin", object_type: "r", acl_items: ["postgres=arwdDxtm/supabase_admin", "anon=arwdDxtm/supabase_admin", "authenticated=arwdDxtm/supabase_admin", "service_role=arwdDxtm/supabase_admin"] },
  ];
  const localPlatformDefaultAclPayload = localPlatformDefaultAclRows
    .sort((left, right) => Buffer.compare(Buffer.from(left.object_type), Buffer.from(right.object_type)))
    .map(entry => [entry.schema, entry.grantor, entry.object_type, [...entry.acl_items].sort().join(",")].join("|"))
    .join("\n");
  assert.equal(Buffer.byteLength(localPlatformDefaultAclPayload), 470);
  assert.equal(
    sha256(localPlatformDefaultAclPayload),
    manifest.platform_companion.restore_expectation.platform_default_acl_compatibility.canonical_sha256,
  );
  const managedCompatibility = manifest.platform_companion.restore_expectation.platform_managed_acl_compatibility;
  assert.match(restoreContract, new RegExp(managedCompatibility.fresh_restore.canonical_sha256, "u"));
  assert.doesNotMatch(restoreContract, new RegExp(managedCompatibility.source_uat.canonical_sha256, "u"));
  assert.deepEqual(manifest.platform_companion.source_attestation, {
    serialization: "phase4a2-companion-v2",
    record_count: 56,
    fingerprint_sha256: "e7f678581129e4f5669c668095e076c9e4e62e10f2fd7c913725cb559e4c074d",
    category_counts: {
      managed_policy: 4,
      managed_policy_table: 1,
      storage_bucket: 1,
      realtime_publication: 1,
      realtime_publication_member: 2,
      realtime_publication_schema: 0,
      event_trigger: 6,
      cron_job: 1,
      extension: 7,
      user_schema: 4,
      default_acl: 29,
    },
  });
  assert.deepEqual(manifest.platform_companion.restore_expectation, {
    cron_job: 0,
    cron_status: "deferred-no-command-text-captured",
    platform_default_acl_compatibility: {
      schema: "supabase_functions",
      grantor: "supabase_admin",
      object_types: ["S", "f", "r"],
      source_uat_schema_exists: false,
      source_uat_records: 0,
      restore_records: 3,
      canonical_bytes: 470,
      canonical_sha256: "4e48afbadff3c1f4a2bf8d07c492872b05ba062c59161f708e5a615e04434efe",
      treatment: "assert-exact-then-exclude-from-uat-comparable-payload",
    },
    default_acl_source_comparison: "exact-after-asserted-local-delta-exclusion",
    platform_managed_acl_compatibility: {
      serialization: "phase4a2b-managed-acl-v2",
      evidence_path: "docs/phase4a2b-managed-acl-catalogs.json",
      query_path: "scripts/phase4a2b/managed_acl_catalog_v2.sql",
      source_uat: {
        runtime_accepted: false,
        record_count: 75,
        canonical_bytes: 12186,
        canonical_sha256: "3266bb4037115a7f14ee4e612b1d27eb56a6b8dd2eed2774181c4a9a7264eeed",
      },
      fresh_restore: {
        runtime_scope: "pinned-fresh-local-supabase",
        record_count: 75,
        canonical_bytes: 14874,
        canonical_sha256: "7f9df875629efa3cc7ad63829b2293a4002e40b6257c05c7f911ed0d24c9eb27",
      },
      identity_sets_equal: true,
      difference_counts: {
        exact: 23,
        extension_owner_grantor_and_owner_acl_representation: 46,
        dashboard_user_privilege_delta: 5,
        cron_job_run_details_trigger_privilege_delta: 1,
        unmatched: 0,
        unclassified: 0,
      },
      difference_classes: [
        "extension-object-owner-grantor-and-owner-acl-representation",
        "dashboard-user-pg-stat-statements-privilege-delta",
        "cron.job_run_details-postgres-trigger-privilege",
      ],
      treatment: "observe-and-assert-only",
      mutation_or_normalization: "prohibited",
    },
    all_other_source_attestation_categories: "exact",
  });

  const fileOrder = manifest.files.map(entry => entry.path);
  assert.ok(
    fileOrder.indexOf("90_environment_uat_functions.sql.tmpl")
      < fileOrder.indexOf("99_platform_companion.sql"),
  );
  assert.equal(fileOrder.at(-1), "99_platform_companion.sql");
});

test("builder and local renderer fail closed", () => {
  assert.match(builder, /RAW_SCHEMA_SHA256 = "7628c7732e0dbc8402cab65fd1f34d3779c7407b0988a0344bb8914891786870"/u);
  assert.match(builder, /expected 2602 pg_dump sections/u);
  assert.match(builder, /source project ref distribution changed/u);
  assert.match(builder, /platform-managed default ACL leaked/u);
  assert.match(builder, /MANAGED_ACL_CAPTURE_RUN_ID = 33_307_376_650/u);
  assert.match(builder, /MANAGED_ACL_CANONICAL_BYTES = 12_186/u);
  assert.match(builder, /RESTORE_MANAGED_ACL_CANONICAL_BYTES = 14_874/u);
  assert.match(builder, /phase4a2b-managed-acl-v2/u);
  assert.doesNotMatch(builder, /phase4a2b-managed-acl-v1/u);
  assert.match(assembler, /\^local\[a-z\]\{15\}\$/u);
  assert.match(assembler, /expected five environment tokens/u);
  assert.match(assembler, /baseline file set differs from manifest/u);
  assert.match(bucketProvisioner, /127\.0\.0\.1/u);
  assert.match(bucketProvisioner, /\/storage\/v1/u);
  assert.match(bucketProvisioner, /> 65535/u);
  assert.match(bucketProvisioner, /SUPABASE_STORAGE_URL/u);
  assert.match(bucketProvisioner, /\/bucket/u);
  assert.match(bucketProvisioner, /id:\s*"profile-avatars"/u);
  assert.match(bucketProvisioner, /type:\s*"STANDARD"/u);
  assert.doesNotMatch(bucketProvisioner, /https:\/\//u);
});

test("Storage helper rejects URL confusion before invoking curl", () => {
  const rejected = [
    "http://localhost:5000@evil.example",
    "http://127.0.0.1:5000?redirect=evil.example",
    "http://127.0.0.1:5000/storage/v1/extra",
    "http://127.0.0.1:99999",
    "http://localhost:0",
    "https://127.0.0.1:5000",
  ];
  for (const url of rejected) {
    const result = spawnSync(process.execPath, [bucketProvisionerPath], {
      encoding: "utf8",
      env: {
        PATH: process.env.PATH,
        SUPABASE_STORAGE_URL: url,
        SUPABASE_SERVICE_ROLE_KEY: "local-test-key-must-not-leave-process",
      },
      timeout: 2_000,
    });
    assert.notEqual(result.status, 0, url);
    assert.match(result.stderr, /refusing (?:non-local Supabase URL|invalid local Storage port)/u);
    assert.doesNotMatch(result.stderr, /curl/u);
  }
});

test("runtime publication guard follows the secured delegate", () => {
  assert.match(runtimeContract,
    /optimizer_publish_role_variant_uat_v2\(uuid,uuid,text,text\)[\s\S]*optimizer_publish_role_variant_before_b4f121_uat_v2/iu);
  assert.match(runtimeContract,
    /optimizer_publish_role_variant_before_b4f121_uat_v2\(uuid,uuid,text,text\)/iu);
  assert.match(runtimeContract, /ROLE_PUBLICATION_SECURED_DELEGATE_MISSING/u);
  assert.match(runtimeContract, /v_role_publish_delegate_definition/iu);
  assert.match(runtimeContract, /ROLE_PUBLICATION_FORBIDDEN/iu);
  assert.match(runtimeContract, /solver_private\.revalidate_materialized_variant_v2/iu);
  assert.match(runtimeContract, /ANON_RUNTIME_RPC_EXECUTE_NOT_REVOKED/u);
  assert.doesNotMatch(runtimeContract,
    /position\('ROLE_PUBLICATION_FORBIDDEN' in v_role_publish_definition\)/iu);
});

test("restore contract is read-only and validates both ledger paths", () => {
  assert.match(
    restoreContract,
    /'information_schema', '_realtime', 'auth', 'extensions', 'graphql', 'graphql_public'/u,
  );
  const statements = tokenizeStatements(restoreContract);
  assert.deepEqual(
    statements.map(({ safe }) => safe.match(/^\s*([A-Z]+)/iu)?.[1]?.toUpperCase()),
    ["BEGIN", "SET", "SET", "SET", "DO", "SELECT", "ROLLBACK"],
  );
  assert.match(
    restoreContract,
    /^set transaction isolation level repeatable read, read only;$/mu,
  );
  assert.match(restoreContract, /phase4a2b\.expected_ledger_mode/u);
  assert.match(restoreContract, /v_ledger_mode not in \('empty', 'synthetic-baseline'\)/u);
  assert.match(restoreContract, /PHASE4A2B_DIRECT_LEDGER_CONTAMINATED/u);
  assert.match(restoreContract, /PHASE4A2B_SYNTHETIC_LEDGER_INVALID/u);
  assert.match(
    restoreContract,
    /to_regclass\('supabase_migrations\.schema_migrations'\) is null/u,
  );
  assert.match(restoreContract, /if v_ledger_mode <> 'empty' then/u);
  assert.match(restoreContract, /phase4a2b\.actual_ledger_rows/u);
  assert.match(restoreContract, /PHASE4A2B_USER_SCHEMA_SET_INVALID/u);
  assert.match(restoreContract, /PHASE4A2B_DEFAULT_ACL_TOTAL_COUNT_INVALID/u);
  assert.match(
    restoreContract,
    /c86785623e746bdaf24fabcb75b2a6019385b230830284d851ec27ad030933a3/u,
  );
  assert.match(restoreContract, /extension_row\.extrelocatable/u);
  assert.match(restoreContract, /PHASE4A2B_EXTENSION_SET_COUNT_INVALID/u);
  assert.match(restoreContract, /PHASE4A2B_STORAGE_BUCKET_SET_INVALID/u);
  assert.match(restoreContract, /PHASE4A2B_MANAGED_POLICY_SHAPE_INVALID/u);
  assert.match(restoreContract, /PHASE4A2B_PUBLICATION_SET_INVALID/u);
  assert.doesNotMatch(
    restoreContract,
    /3266bb4037115a7f14ee4e612b1d27eb56a6b8dd2eed2774181c4a9a7264eeed/u,
  );
  assert.match(
    restoreContract,
    /7f9df875629efa3cc7ad63829b2293a4002e40b6257c05c7f911ed0d24c9eb27/u,
  );
  assert.doesNotMatch(restoreContract,
    /c3278105b5071f36da447bb3dd365f2602e3346ffa5eb9560e96bdd9bd9f2ffc|9055de5193241c43fffe2b9dc75925a305eada026bc765131d40f01e48d349c5/u);
  assert.match(restoreContract, /PHASE4A2B_MANAGED_ACL_CATALOG_INVALID/u);
  assert.match(restoreContract, /'schema'::text as object_kind/u);
  assert.match(restoreContract, /namespace_row\.nspname::text as schema_name/u);
  assert.match(restoreContract,
    /pg_get_function_identity_arguments\(procedure_row\.oid\)[\s\S]*\)::text/iu);
  assert.match(restoreContract, /PHASE4A2B_SECURITY_DEFINER_SEARCH_PATH_DRIFT/u);
  assert.match(restoreContract, /\('search_path=""'::text, 458::bigint\)/u);
  assert.match(restoreContract, /trigger_row\.evttags is not distinct from v_record\.tags/u);
  assert.match(restoreContract, /20260830000000/u);
  assert.match(restoreContract, /phase4a2b_neutral_baseline/u);

  assert.doesNotMatch(
    restoreContract,
    /^\s*(?:INSERT|UPDATE|DELETE|MERGE|TRUNCATE|COPY|CALL|CREATE|ALTER|DROP|GRANT|REVOKE)\b/imu,
  );
  assert.doesNotMatch(
    restoreContract,
    /\b(?:dblink|postgres_fdw|http_(?:get|post)|net\.http|pg_catalog\.setval)\b/iu,
  );
  assert.doesNotMatch(restoreContract, /\bfrom\s+pgmq\.(?:q|a)_/iu);
  assert.match(restoreContract, /from pgmq\.list_queues\(\)/u);
  assert.match(restoreContract, /PHASE4A2B_PGMQ_QUEUE_DATA_PRESENT/u);
  assert.match(restoreContract, /PHASE4A2B_APPLICATION_DATA_PRESENT/u);
  assert.match(restoreContract, /PHASE4A2B_AUTH_USER_DATA_PRESENT/u);
  assert.match(restoreContract, /PHASE4A2B_STORAGE_OBJECT_DATA_PRESENT/u);
  assert.match(restoreContract, /^rollback;$/mu);
});
