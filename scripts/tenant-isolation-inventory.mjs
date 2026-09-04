import { createHash } from "node:crypto";
import { readFile, readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

const root = process.cwd();
const baselineDir = path.join(root, "supabase", "baseline", "phase4a2b");
const baselineManifest = JSON.parse(await readFile(path.join(baselineDir, "manifest.json"), "utf8"));
const coreFiles = (await readdir(baselineDir)).filter(name => /^10_core_\d+\.sql$/u.test(name)).sort();
const coreSql = (await Promise.all(coreFiles.map(name => readFile(path.join(baselineDir, name), "utf8")))).join("\n");

const unique = values => [...new Set(values)].sort();
const compact = value => value.replace(/\s+/gu, " ").trim();
const sha256 = value => createHash("sha256").update(value).digest("hex");

const tables = [];
for (const match of coreSql.matchAll(/CREATE TABLE "public"\."([^"]+)"\s*\(([\s\S]*?)\n\);/gu)) {
  const columns = [...match[2].matchAll(/^\s*"([^"]+)"\s+/gmu)].map(item => item[1]);
  tables.push({
    name: match[1],
    columns,
    tenantColumns: columns.filter(column => ["company_id", "organization_id", "tenant_id"].includes(column)),
  });
}

const rlsEnabled = new Set([...coreSql.matchAll(/ALTER TABLE(?: ONLY)? "public"\."([^"]+)" ENABLE ROW LEVEL SECURITY;/gu)].map(match => match[1]));
const policies = [...coreSql.matchAll(/CREATE POLICY "([^"]+)" ON "public"\."([^"]+)"([\s\S]*?);/gu)].map(match => ({
  name: match[1], table: match[2], definition: compact(match[3]),
}));
const broadAuthenticatedReads = policies.filter(policy =>
  /TO "authenticated"/u.test(policy.definition)
  && /FOR SELECT/u.test(policy.definition)
  && /USING \(true\)/u.test(policy.definition)
).map(policy => ({ name: policy.name, table: policy.table }));

const views = unique([...coreSql.matchAll(/CREATE (?:MATERIALIZED )?VIEW "([^"]+)"\."([^"]+)"/gu)].map(match => `${match[1]}.${match[2]}`));
const routines = unique([...coreSql.matchAll(/CREATE FUNCTION "([^"]+)"\."([^"]+)"\(([\s\S]*?)\) RETURNS/gu)].map(match =>
  `${match[1]}.${match[2]}(${compact(match[3])})`
));
const triggers = unique([...coreSql.matchAll(/CREATE TRIGGER "([^"]+)"[\s\S]*? ON "([^"]+)"\."([^"]+)"/gu)].map(match =>
  `${match[2]}.${match[3]}:${match[1]}`
));
const foreignKeys = [...coreSql.matchAll(/ALTER TABLE ONLY "public"\."([^"]+)"[\s\S]*?ADD CONSTRAINT "([^"]+)" FOREIGN KEY \(([^)]+)\) REFERENCES "public"\."([^"]+)"\(([^)]+)\)/gu)].map(match => ({
  table: match[1], constraint: match[2], columns: compact(match[3]), referencedTable: match[4], referencedColumns: compact(match[5]),
}));

const globalAllowlist = [
  { table: "solver_feature_flags", reason: "Wersjonowana flaga silnika całego artefaktu; dotychczasowe procedury resetu jawnie zachowują tę tabelę." },
  { table: "uat_environment_controls", reason: "Kontrola bezpieczeństwa środowiska UAT, a nie dane firmy; dotychczasowe procedury resetu jawnie zachowują tę tabelę." },
];
const globalNames = new Set(globalAllowlist.map(item => item.table));
const tenantTables = tables.map(table => table.name).filter(name => !globalNames.has(name)).sort();

const inventory = {
  format: "szafunek-tenant-isolation-inventory-v1",
  evidence: {
    status: "HISTORICAL_CAPTURE_PLUS_LOCAL_RECONSTRUCTION",
    sourceCaptureRecordedAtUtc: baselineManifest.supplemental_read_only_inventory.managed_acl_catalog.recorded_at_utc,
    sourceProjectIdentityVerifiedAtCapture: baselineManifest.supplemental_read_only_inventory.managed_acl_catalog.uat_identity_verified,
    frozenSourceCommit: baselineManifest.capture.frozen_source_commit,
    rawSchemaSha256: baselineManifest.capture.raw_schema_sha256,
    coreFiles,
    reconstructedCoreSha256: sha256(coreSql),
    limitation: "Dokładny projekt UAT nhthrtpkfpmufmrmdyjg nie był dostępny 2026-09-03; ten plik nie jest dowodem bieżącego katalogu live.",
  },
  globalAllowlist,
  tables: {
    count: tables.length,
    rlsEnabledCount: tables.filter(table => rlsEnabled.has(table.name)).length,
    withoutTenantKey: tables.filter(table => table.tenantColumns.length === 0).map(table => table.name).sort(),
    tenantOwned: tenantTables,
    global: [...globalNames].sort(),
    foreignKeys,
  },
  views: { count: views.length, requiresTenantReview: views },
  routines: { count: routines.length, requiresTenantReview: routines },
  triggers: { count: triggers.length, requiresTenantReview: triggers },
  policies: { count: policies.length, broadAuthenticatedReads },
  storage: {
    bucket: baselineManifest.platform_companion.storage_bucket,
    policies: baselineManifest.platform_companion.storage_policies,
    requiredTenantBoundary: "company membership plus user ownership; object path alone is not a company boundary",
  },
  realtime: {
    publication: baselineManifest.platform_companion.realtime_publication,
    members: baselineManifest.platform_companion.realtime_members,
    requiredTenantBoundary: "company_id filter enforced before subscription payload delivery",
  },
  flows: [
    { name: "auth-and-access", surfaces: ["application_access_directory_v1", "user_permissions", "current_user_access_v2", "application_access_provision_current_user_v1"] },
    { name: "configuration-and-import", surfaces: ["matrix_versions", "matrix_*_v2", "matrix_v2_full_import_*", "matrix_v2_complete_workspace"] },
    { name: "solver-and-worker", surfaces: ["optimization_runs_v2", "optimization_run_strategies_v2", "plan_variants_v2", "solver_private.*"] },
    { name: "publication", surfaces: ["published_schedules_v2", "published_schedule_variants_v2", "published_role_schedules_v2"] },
    { name: "employee-portal", surfaces: ["employees", "employee_availability", "shift_swap_*_v2", "employee_*_workspace_v1"] },
    { name: "operations-and-messages", surfaces: ["workforce_*_v2", "operational_program_*_v1", "team_*_v1", "notifications"] },
    { name: "storage-and-realtime", surfaces: ["storage.objects/profile-avatars", "supabase_realtime"] },
  ],
  requiredTwoCompanyCases: [
    { case: "overlapping-business-identifiers", sameValues: ["employee_no=GP-001", "location_code=BAR", "role_code=KELNER", "role_name=Kelner"], expected: "independent rows per company" },
    { case: "cross-company-read", expected: "denied for direct table, view, RPC, storage and realtime" },
    { case: "cross-company-write", expected: "denied for insert, update, delete, import, publication and solver persistence" },
    { case: "cross-company-object-reference", expected: "composite tenant FK rejects ids from another company" },
  ],
  migrationGate: {
    status: "BLOCKED_FAIL_CLOSED",
    missingInputs: [
      "fresh read-only live catalog from exact UAT project",
      "explicit company record and owner membership mapping for every existing UAT row",
      "reviewed classification of every view and SECURITY DEFINER routine",
      "isolated PostgreSQL/Supabase replay with two authenticated companies",
    ],
    forbiddenUntilResolved: "Do not generate or apply the NOT NULL/backfill/RLS cutover migration.",
  },
};

const serialized = `${JSON.stringify(inventory, null, 2)}\n`;
if (process.argv.includes("--write")) {
  await writeFile(path.join(root, "supabase", "tenant-isolation-inventory.json"), serialized, "utf8");
} else {
  process.stdout.write(serialized);
}
