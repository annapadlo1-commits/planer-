import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import test from "node:test";

const migration = await readFile(new URL(
  "../supabase/migrations/20260827160000_phase4a1_scoped_manager_security_hardening.sql",
  import.meta.url,
), "utf8");
const restoredRpcParity = await readFile(new URL(
  "../supabase/migrations/20260826224321_restore_frontend_rpc_parity.sql",
  import.meta.url,
), "utf8");
const canonicalEmployeePrivacy = await readFile(new URL(
  "../supabase/migrations/20260826201603_employee_workspace_privacy.sql",
  import.meta.url,
));
const canonicalAnonymousHardening = await readFile(new URL(
  "../supabase/migrations/20260826210712_explicit_anonymous_schedule_hardening.sql",
  import.meta.url,
));
const phase3ResourceAuthorization = await readFile(new URL(
  "../supabase/migrations/20260826140255_resource_scoped_manager_authorization.sql",
  import.meta.url,
), "utf8");
const sqlContract = await readFile(new URL(
  "../supabase/tests/phase4a1_scoped_manager_security_contract.sql",
  import.meta.url,
), "utf8");
const preflight = await readFile(new URL(
  "../docs/PHASE4A1_UAT_READ_ONLY_PREFLIGHT.sql", import.meta.url,
), "utf8");
const preflightTemplate = await readFile(new URL(
  "../docs/PHASE4A1_UAT_PREFLIGHT_RESULT_TEMPLATE.md", import.meta.url,
), "utf8");
const frontend = await Promise.all([
  "../app/page.tsx",
  "../components/ActiveModules.tsx",
  "../components/MatrixV2Editor.tsx",
  "../components/SolverV2Workspace.tsx",
  "../components/RecoveryCenter.tsx",
  "../lib/employer-costs.ts",
  "../lib/recovery-center.ts",
].map(async path => readFile(new URL(path, import.meta.url), "utf8")));

function policy(name) {
  const match = migration.match(new RegExp(
    `create\\s+policy\\s+${name}\\b([\\s\\S]*?)(?=\\n\\s*(?:drop\\s+policy|create\\s+policy|comment\\s+on|notify\\s+pgrst|commit;))`,
    "iu",
  ));
  assert.ok(match, `missing policy ${name}`);
  return match[0];
}

test("Phase 4A.1 is append-only policy hardening and excludes bulk-adjust", () => {
  assert.match(migration, /^-- Phase 4A\.1/mu);
  assert.doesNotMatch(migration, /matrix_v2_staffing_bulk_adjust_uat_v2/u);
  assert.doesNotMatch(migration, /\b(?:insert|update|delete|truncate)\s+(?:into|from)?\s*public\./iu);
  assert.match(migration, /set search_path\s*=\s*''/iu);
  assert.match(migration, /alter function public\.matrix_v2_can_manage_legacy_resource_uat_v1\(text,uuid,uuid\)\s+owner to postgres/iu);
  assert.match(migration, /revoke all on function[\s\S]*from public,anon,authenticated/iu);
  assert.match(migration, /grant execute on function[\s\S]*to authenticated\s*;/iu);
  assert.doesNotMatch(migration, /grant execute on function[\s\S]*?to\s+authenticated\s*,\s*service_role/iu);
});

test("recovered UAT RPC parity migration is the final hardened frontend contract", () => {
  assert.equal(Buffer.byteLength(restoredRpcParity), 5771);
  assert.equal(createHash("md5").update(restoredRpcParity).digest("hex"), "210a5e84e48a83e08fa957c0da680755");
  assert.match(restoredRpcParity, /matrix_v2_staffing_bulk_adjust_uat_v2\([\s\S]*p_delta integer default 1/iu);
  assert.match(restoredRpcParity, /security definer[\s\S]*set search_path = ''/iu);
  assert.match(restoredRpcParity, /has_app_role\('OWNER'\)[\s\S]*has_app_role\('ADMIN'\)/u);
  assert.match(restoredRpcParity, /coalesce\(p_delta,0\)=0 or abs\(p_delta\)>20/u);
  assert.match(restoredRpcParity, /for update of rule/iu);
  assert.match(restoredRpcParity, /operation='SET'[\s\S]*\+p_delta<1/iu);
  assert.match(restoredRpcParity, /operation='ADD'[\s\S]*\+p_delta<0/iu);
  assert.match(restoredRpcParity, /insert into public\.audit_log/iu);
  assert.match(restoredRpcParity, /'updated',v_updated[\s\S]*'skipped'/u);
});

test("canonical UAT migration IDs are unique, ordered and byte-identical", async () => {
  const names = (await readdir(new URL("../supabase/migrations/", import.meta.url))).sort();
  const canonical = [
    "20260826140255_resource_scoped_manager_authorization.sql",
    "20260826201603_employee_workspace_privacy.sql",
    "20260826210712_explicit_anonymous_schedule_hardening.sql",
    "20260826224321_restore_frontend_rpc_parity.sql",
    "20260827160000_phase4a1_scoped_manager_security_hardening.sql",
  ];
  assert.deepEqual(names.filter(name => canonical.includes(name)), canonical);
  assert.ok(!names.includes("20260826200600_employee_workspace_privacy.sql"));
  assert.ok(!names.includes("20260826210018_explicit_anonymous_schedule_hardening.sql"));
  const versions = names.map(name => name.match(/^(\d+)_/u)?.[1]).filter(Boolean);
  assert.equal(new Set(versions).size, versions.length);
  assert.equal(canonicalEmployeePrivacy.byteLength, 7186);
  assert.equal(createHash("md5").update(canonicalEmployeePrivacy).digest("hex"), "ef5af6cf509c3a5c30f4b45a18c96456");
  assert.equal(canonicalAnonymousHardening.byteLength, 1307);
  assert.equal(createHash("md5").update(canonicalAnonymousHardening).digest("hex"), "7514a3362c33743bddd4947d07d5562e");
});

test("canonical Phase 3 authorization and anonymous boundary remain intact", () => {
  assert.match(phase3ResourceAuthorization, /matrix_v2_scope_allows_resource_for_app_role_uat_v1/iu);
  assert.match(phase3ResourceAuthorization, /matrix_v2_can_manage_resource_uat_v1/iu);
  assert.match(phase3ResourceAuthorization, /set search_path\s*=\s*''/iu);
  const anonymousSql = canonicalAnonymousHardening.toString("utf8");
  assert.match(anonymousSql, /revoke select on table public\.shifts from anon/iu);
  assert.match(anonymousSql, /revoke select on table public\.assignments from anon/iu);
  assert.match(anonymousSql, /for select\s+to authenticated/iu);
});

test("legacy mapping requires exactly one active Matrix and exactly one resource match", () => {
  assert.match(migration, /where matrix\.status='ACTIVE'/u);
  assert.match(migration, /select count\(\*\),\(array_agg\(matrix\.id\)\)\[1\][\s\S]*if v_match_count<>1 then return false/iu);
  assert.match(migration, /select count\(\*\),\(array_agg\(role\.id\)\)\[1\][\s\S]*role\.matrix_version_id=v_matrix_id[\s\S]*if v_match_count<>1 then return false/iu);
  assert.match(migration, /select count\(\*\),\(array_agg\(matrix_location\.id\)\)\[1\][\s\S]*matrix_location\.matrix_version_id=v_matrix_id[\s\S]*if v_match_count<>1 then return false/iu);
  assert.doesNotMatch(migration, /order by matrix\.version|limit 1/iu);
  assert.doesNotMatch(migration, /has_app_role\('(ROLE_MANAGER|LOCATION_MANAGER)'\)/iu);
  assert.doesNotMatch(migration, /\bexecute\s+(?:format|immediate)|\bdynamic\s+sql/iu);
});

test("manual UAT preflight bundle is SELECT-only and complete", () => {
  assert.match(preflight, /RUN ONLY IN SZAFUNEK UAT PROJECT — DO NOT RUN IN PRODUCTION/u);
  const executable = preflight.replace(/\/\*[\s\S]*?\*\//gu, "").replace(/^\s*--.*$/gmu, "");
  const statements = executable.split(";").map(value => value.trim()).filter(Boolean);
  assert.ok(statements.length >= 15);
  for (const statement of statements) {
    assert.match(statement, /^select\b/iu, statement.slice(0, 80));
    assert.doesNotMatch(statement, /^(?:insert|update|delete|merge|create|alter|drop|truncate|grant|revoke|notify)\b/iu);
    assert.doesNotMatch(statement, /\b(?:call|perform)\s+|select\s+(?:public\.)?[a-z0-9_]*(?:mutate|adjust|create|update|delete|decide|propose)[a-z0-9_]*\s*\(/iu);
  }
  for (const section of "ABCDEFGHIJKLMN") assert.match(preflight, new RegExp(`-- ${section}\\.`, "u"));
  for (const heading of ["UAT identity confirmed manually", "Migration ledger", "Owner pattern",
    "Active Matrix count", "Scope grant problems", "Final preflight verdict"]) {
    assert.match(preflightTemplate, new RegExp(heading, "u"));
  }
});

test("assignment, availability and event policies use resource-aware authorization", () => {
  for (const name of [
    "employee_reads_own_assignments",
    "availability_read",
    "availability_manage",
    "managers_manage_events",
  ]) {
    const definition = policy(name);
    assert.match(definition, /to authenticated/iu);
    assert.match(definition, /matrix_v2_can_manage_(?:legacy_)?resource_uat_v1/iu);
    assert.doesNotMatch(definition, /has_app_role\('(ROLE_MANAGER|LOCATION_MANAGER)'\)/iu);
  }
  assert.match(policy("availability_manage"), /with check/iu);
  assert.match(policy("employee_reads_own_assignments"), /assigned_role[\s\S]*shift\.location_id[\s\S]*employee_id/iu);
});

test("published schedule is intentionally global but non-published legacy rows are admin-only", () => {
  for (const name of ["authenticated_reads_plans", "employee_reads_published_shifts"]) {
    const definition = policy(name);
    assert.match(definition, /PUBLISHED/iu);
    assert.doesNotMatch(definition, /ROLE_MANAGER|LOCATION_MANAGER/u);
  }
  const history = policy("availability_history_read");
  assert.match(history, /matrix_v2_can_manage_resource_uat_v1/iu);
  assert.doesNotMatch(history, /has_app_role\('(ROLE_MANAGER|LOCATION_MANAGER)'\)/iu);
});

test("legacy person reads are scoped and direct finance reads are admin/finance only", () => {
  for (const name of [
    "employee_reads_self",
    "authenticated_reads_employee_locations",
    "authenticated_reads_employee_capabilities",
    "employee_reads_own_attendance",
    "plan_issues_read",
    "matrix_role_categories_v2_select",
  ]) {
    const definition = policy(name);
    assert.match(definition, /matrix_v2_can_manage_(?:legacy_)?resource_uat_v1/iu);
    assert.doesNotMatch(definition, /has_app_role\('(ROLE_MANAGER|LOCATION_MANAGER)'\)/iu);
  }
  for (const name of ["employer_cost_components_read_v2", "incident_rates_read_v2"]) {
    const definition = policy(name);
    assert.match(definition, /has_app_role\('HR_FINANCE'\)/u);
    assert.doesNotMatch(definition, /ROLE_MANAGER|LOCATION_MANAGER/u);
  }
});

test("active frontend workflows use RPC payloads rather than hardened business tables", () => {
  const source = frontend.join("\n");
  for (const table of [
    "assignments", "employee_availability", "operational_events", "employees",
    "employee_locations", "employee_capabilities", "attendance_events", "plan_issues",
    "employer_cost_components_v2", "recovery_incident_rate_revisions_v2",
  ]) {
    assert.doesNotMatch(source, new RegExp(`\\.from\\(["']${table}["']\\)`, "u"), table);
  }
  assert.match(source, /employer_cost_workspace_uat_v1/u);
  assert.match(source, /recovery_incident_rate_(?:propose|decide)_uat_v1/u);
  assert.match(source, /matrix_v2_workspace/u);
});

test("SQL contract covers the required actors and denial boundaries", () => {
  for (const marker of [
    "phase4a-owner", "phase4a-admin", "phase4a-role-x", "phase4a-role-y",
    "phase4a-location-a", "phase4a-location-b", "phase4a-employee-a",
    "phase4a-employee-b", "phase4a-no-role", "set local role anon",
    "CROSS_WRITE_ALLOWED", "NO_ROLE_READ_ALLOWED", "ANON_ASSIGNMENT_SELECT_ALLOWED",
  ]) assert.match(sqlContract, new RegExp(marker, "iu"));
  assert.match(sqlContract, /false,'f4a10000-0000-4000-8000-000000000001'/iu);
  assert.match(sqlContract, /'INVALID'/u);
  assert.match(sqlContract, /rollback;/iu);
});
