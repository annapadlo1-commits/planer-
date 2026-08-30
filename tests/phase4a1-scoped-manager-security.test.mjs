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
const review = await readFile(new URL(
  "../docs/PHASE4A1_SCOPED_MANAGER_SECURITY_REVIEW_2026-08-27.md", import.meta.url,
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

function helper(name) {
  const match = migration.match(new RegExp(
    `create\\s+or\\s+replace\\s+function\\s+public\\.${name}\\b([\\s\\S]*?\\$\\$;)`, "iu",
  ));
  assert.ok(match, `missing helper ${name}`);
  return match[0];
}

test("Phase 4A.1 is append-only policy hardening and excludes bulk-adjust", () => {
  assert.match(migration, /^-- Phase 4A\.1/mu);
  assert.doesNotMatch(migration, /matrix_v2_staffing_bulk_adjust_uat_v2/u);
  assert.doesNotMatch(migration, /\b(?:insert|update|delete|truncate)\s+(?:into|from)?\s*public\./iu);
  assert.match(migration, /set search_path\s*=\s*''/iu);
  assert.match(migration, /alter function public\.matrix_v2_can_manage_legacy_resource_uat_v1\(text,uuid,uuid\)\s+owner to postgres/iu);
  assert.match(migration,
    /revoke all on function public\.matrix_v2_can_manage_legacy_resource_uat_v1\(text,uuid,uuid\)\s+from public,anon,authenticated,service_role/iu);
  assert.match(migration,
    /grant execute on function public\.matrix_v2_can_manage_legacy_resource_uat_v1\(text,uuid,uuid\)\s+to authenticated\s*;/iu);
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
  for (const version of ["20260826200600", "20260826201603", "20260826210018",
    "20260826210712", "20260826224321", "20260827160000"]) assert.match(preflight, new RegExp(version, "u"));
  assert.match(preflight, /STOP — MIGRATION HISTORY REPAIR REQUIRED BEFORE NORMAL MIGRATOR/u);
  assert.match(preflight, /CANONICAL UAT HISTORY|MIXED HISTORY|OLD-SOURCE HISTORY/u);
  for (const heading of ["UAT identity confirmed manually", "Migration ledger", "Owner pattern",
    "Active Matrix count", "Scope grant problems", "Final preflight verdict"]) {
    assert.match(preflightTemplate, new RegExp(heading, "u"));
  }
});

test("assignment trusted-row helper uses actual shift location with minimal ACL", () => {
  const definition = helper("matrix_v2_can_manage_legacy_assignment_uat_v1");
  assert.match(definition, /\(\s*p_assignment_id uuid\s*\) returns boolean/iu);
  assert.match(definition, /stable[\s\S]*security definer[\s\S]*set search_path = ''/iu);
  assert.match(definition, /auth\.uid\(\) is null[\s\S]*return false/iu);
  assert.match(definition, /from public\.assignments assignment[\s\S]*join public\.shifts shift/iu);
  assert.match(definition, /assignment\.assigned_role[\s\S]*assignment\.employee_id[\s\S]*shift\.location_id/iu);
  assert.match(definition, /matrix_v2_can_manage_legacy_resource_uat_v1/iu);
  assert.doesNotMatch(definition, /has_app_role\('(ROLE_MANAGER|LOCATION_MANAGER)'\)|execute format|dynamic sql/iu);
  assert.match(migration, /alter function public\.matrix_v2_can_manage_legacy_assignment_uat_v1\(uuid\)\s+owner to postgres/iu);
  assert.match(migration, /revoke all on function public\.matrix_v2_can_manage_legacy_assignment_uat_v1\(uuid\)\s+from public,anon,authenticated,service_role/iu);
  assert.match(migration, /grant execute on function public\.matrix_v2_can_manage_legacy_assignment_uat_v1\(uuid\)\s+to authenticated/iu);
  const assignmentPolicy = policy("employee_reads_own_assignments");
  assert.match(assignmentPolicy, /matrix_v2_can_manage_legacy_assignment_uat_v1\(assignments\.id\)/iu);
  assert.doesNotMatch(assignmentPolicy, /select\s+shift\.location_id|from public\.shifts/iu);
});

test("plan-issue sibling uses the same trusted actual-location boundary", () => {
  const definition = helper("matrix_v2_can_manage_legacy_plan_issue_uat_v1");
  assert.match(definition, /stable[\s\S]*security definer[\s\S]*set search_path = ''/iu);
  assert.match(definition, /auth\.uid\(\) is null[\s\S]*return false/iu);
  assert.match(definition, /from public\.plan_issues issue[\s\S]*join public\.shifts shift/iu);
  assert.match(definition, /issue\.role[\s\S]*shift\.location_id/iu);
  assert.match(definition, /matrix_v2_can_manage_legacy_resource_uat_v1/iu);
  assert.match(migration, /alter function public\.matrix_v2_can_manage_legacy_plan_issue_uat_v1\(uuid\)\s+owner to postgres/iu);
  assert.match(migration, /revoke all on function public\.matrix_v2_can_manage_legacy_plan_issue_uat_v1\(uuid\)\s+from public,anon,authenticated,service_role/iu);
  assert.match(migration, /grant execute on function public\.matrix_v2_can_manage_legacy_plan_issue_uat_v1\(uuid\)\s+to authenticated/iu);
  const issuePolicy = policy("plan_issues_read");
  assert.match(issuePolicy, /matrix_v2_can_manage_legacy_plan_issue_uat_v1\(plan_issues\.id\)/iu);
  assert.doesNotMatch(issuePolicy, /select\s+shift\.location_id|from public\.shifts/iu);
});

test("availability and event-write policies use resource-aware authorization", () => {
  for (const name of ["availability_read", "availability_manage", "managers_manage_events"]) {
    const definition = policy(name);
    assert.match(definition, /to authenticated/iu);
    assert.match(definition, /matrix_v2_can_manage_(?:legacy_)?resource_uat_v1/iu);
    assert.doesNotMatch(definition, /has_app_role\('(ROLE_MANAGER|LOCATION_MANAGER)'\)/iu);
  }
  assert.match(policy("availability_manage"), /with check/iu);
  assert.doesNotMatch(migration, /drop policy if exists authenticated_reads_events/iu);
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
    "LOCATION_A_DRAFT_SHIFT_LOCATION_LEAK", "LOCATION_B_DRAFT_SHIFT_VISIBLE",
    "NO_ROLE_EVENT_UPDATE_ALLOWED", "NO_ROLE_EVENT_INSERT_ALLOWED",
  ]) assert.match(sqlContract, new RegExp(marker, "iu"));
  assert.match(sqlContract, /false,'f4a10000-0000-4000-8000-000000000001'/iu);
  assert.match(sqlContract, /'INVALID'/u);
  assert.match(sqlContract, /rollback;/iu);
});

test("SQL fixture source is self-contained and explicitly typed", () => {
  assert.match(sqlContract,
    /regexp_count\(v_definition,'v_match_count\\s\*<>\\s\*1'\)\s*<\s*3/iu);
  assert.doesNotMatch(sqlContract,
    /replace\(v_definition,'v_match_count <> 1'/iu);

  const legacyLocations = sqlContract.indexOf("insert into public.locations");
  const matrixLocations = sqlContract.indexOf("insert into public.matrix_locations_v2");
  const profiles = sqlContract.indexOf("insert into public.matrix_employee_profiles_v2");
  const employeeRoles = sqlContract.indexOf("insert into public.matrix_employee_roles_v2");
  const employeeLocations = sqlContract.indexOf("insert into public.matrix_employee_locations_v2");
  assert.ok(legacyLocations >= 0 && legacyLocations < matrixLocations);
  assert.ok(profiles > matrixLocations && profiles < employeeRoles && profiles < employeeLocations);
  assert.match(sqlContract,
    /insert into public\.locations[\s\S]*'KRUCZA'::public\.location_code[\s\S]*'PAWILONY'::public\.location_code[\s\S]*on conflict\(code\) do nothing/iu);
  assert.match(sqlContract,
    /insert into public\.matrix_employee_profiles_v2[\s\S]*P4A-A[\s\S]*P4A-B[\s\S]*P4A-N[\s\S]*P4A-I/iu);
  const matrixBootstrapStart = sqlContract.indexOf("do $$\ndeclare v_version integer;v_settings jsonb;");
  const matrixBootstrapEnd = sqlContract.indexOf("\ninsert into public.matrix_roles_v2", matrixBootstrapStart);
  assert.ok(matrixBootstrapStart >= 0 && matrixBootstrapEnd > matrixBootstrapStart);
  const matrixBootstrap = sqlContract.slice(matrixBootstrapStart, matrixBootstrapEnd);
  assert.match(matrixBootstrap, /if v_settings is null then/iu);
  assert.match(matrixBootstrap, /'currency','PLN'/iu);
  assert.match(matrixBootstrap, /'timezone','Europe\/Warsaw'/iu);
  assert.match(matrixBootstrap, /'minimumRestMinutes',660/iu);
  assert.match(matrixBootstrap, /'maximumShiftsPerDay',1/iu);
  assert.match(matrixBootstrap, /'missingAvailabilityMeansAvailable',true/iu);
  assert.match(matrixBootstrap, /'requireOptimal',false/iu);
  assert.doesNotMatch(matrixBootstrap,
    /coalesce\(v_settings,'\{\}'::jsonb\)|\|\|jsonb_build_object\('timezone'/iu);
  assert.match(sqlContract, /'DRAFT'::public\.event_status/iu);
  assert.match(sqlContract, /null::timestamptz/iu);
  assert.match(sqlContract, /f4a14000-0000-4000-8000-000000000001'::uuid/iu);
});

test("active unrelated employee has isolated valid Matrix memberships", () => {
  assert.match(sqlContract, /'P4A-N'::text[\s\S]{0,120}null::text,true/iu);
  assert.match(sqlContract,
    /f4a11000-0000-4000-8000-000000000003'::uuid,[\s\S]{0,100}f4a13000-0000-4000-8000-000000000003'::uuid,true,false,true/iu);
  assert.match(sqlContract,
    /f4a11000-0000-4000-8000-000000000003'::uuid,[\s\S]{0,100}f4a14000-0000-4000-8000-000000000003'::uuid,true,false,true,true/iu);

  const roleMembership = sqlContract.indexOf(
    "'f4a13000-0000-4000-8000-000000000003'::uuid,true,false,true",
  );
  const locationMembership = sqlContract.indexOf(
    "'f4a14000-0000-4000-8000-000000000003'::uuid,true,false,true,true",
  );
  const activation = sqlContract.indexOf("update public.matrix_versions set status='ACTIVE'");
  assert.ok(roleMembership >= 0 && locationMembership >= 0);
  assert.ok(roleMembership < activation && locationMembership < activation);

  const grantStatements = [...sqlContract.matchAll(
    /insert into public\.matrix_scope_grants_v2[\s\S]*?;/giu,
  )].map(match => match[0]).join("\n");
  assert.doesNotMatch(grantStatements,
    /f4a13[1]00-0000-4000-8000-000000000003|f4a14[1]00-0000-4000-8000-000000000003/iu);
  assert.match(sqlContract, /PHASE4A_UNRELATED_RESOURCE_SCOPE_GRANTED/u);
});

test("zero-ACTIVE contract check rolls back its temporary archive subtransaction", () => {
  assert.match(sqlContract,
    /update public\.matrix_versions set status='ARCHIVED'[\s\S]*errcode='P4A11'[\s\S]*errcode='P4A10'[\s\S]*exception when sqlstate 'P4A10'/iu);
  assert.match(sqlContract,
    /PHASE4A_ZERO_ACTIVE_MATRIX_ROLLBACK[\s\S]*status='ACTIVE'[\s\S]*PHASE4A_ACTIVE_MATRIX_NOT_RESTORED/iu);
  assert.doesNotMatch(sqlContract,
    /update public\.matrix_versions set status='ACTIVE',effective_to=null/iu);
  assert.match(sqlContract, /PHASE4A_LOCATION_A_DRAFT_SHIFT_LOCATION_LEAK/u);
  assert.match(sqlContract, /PHASE4A_LOCATION_B_BOUNDARY_INVALID/u);
  assert.match(sqlContract, /PHASE4A_LOCATION_B_DRAFT_SHIFT_VISIBLE/u);
});

test("operational event read finding remains explicitly deferred", () => {
  assert.match(review, /TECH-AUD-024 WRITE FIXED IN SOURCE/u);
  assert.match(review, /TECH-AUD-026 GLOBAL LEGACY EVENT READ DEFERRED \/ STILL OPEN/u);
  assert.match(review, /authenticated_reads_events[\s\S]*USING \(true\)/u);
  assert.match(review, /plan_workspace\(date,uuid\)/u);
  assert.doesNotMatch(sqlContract, /LOCATION_[AB]_EVENT_READ_LEAK|NO_ROLE_RESOURCE_READ_ALLOWED[^\n]*operational_events/u);
});
