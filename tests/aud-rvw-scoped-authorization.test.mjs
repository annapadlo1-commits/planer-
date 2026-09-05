import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  canManageWholeSolverCategory,
  shouldRestoreCategoryGenerator,
  workspaceAccessPolicy,
} from "../lib/workspace-access-policy.ts";

const migration = await readFile(
  new URL("../supabase/migrations/20260905140000_aud_rvw_scoped_authorization.sql", import.meta.url),
  "utf8",
);
const page = await readFile(new URL("../app/page.tsx", import.meta.url), "utf8");
const sqlContract = await readFile(
  new URL("../supabase/tests/aud_rvw_scoped_authorization_contract.sql", import.meta.url),
  "utf8",
);

test("AUD review: polityka dostępu jest fail-closed dla lidera i całej kategorii", () => {
  const owner = workspaceAccessPolicy([{ app_role: "OWNER" }]);
  const roleManagerA = workspaceAccessPolicy([{ app_role: "ROLE_MANAGER", role_logical_id: "role-a" }]);
  const roleManagerAB = workspaceAccessPolicy([
    { app_role: "ROLE_MANAGER", role_logical_id: "role-a" },
    { app_role: "ROLE_MANAGER", role_logical_id: "role-b" },
  ]);
  const roles = [
    { id: "role-a-version", code: "A", name: "A", logicalId: "role-a" },
    { id: "role-b-version", code: "B", name: "B", logicalId: "role-b" },
  ];
  const category = {
    id: "category", code: "AB", name: "A+B", sortOrder: 1, anchorRoleId: "role-a-version",
    roleIds: ["role-a-version", "role-b-version"], roleNames: ["A", "B"],
  };

  assert.equal(owner.canManageCompanySchedule, true);
  assert.equal(roleManagerA.canManageCompanySchedule, false);
  assert.equal(roleManagerA.canReadCompanyWorkspace, false);
  assert.equal(roleManagerA.canReadManagementOperations, true);
  assert.equal(canManageWholeSolverCategory(owner, roles, category), true);
  assert.equal(canManageWholeSolverCategory(roleManagerA, roles, category), false);
  assert.equal(canManageWholeSolverCategory(roleManagerAB, roles, category), true);
  assert.equal(canManageWholeSolverCategory(roleManagerAB, roles.slice(0, 1), category), false);
  assert.equal(canManageWholeSolverCategory(roleManagerAB, roles, { ...category, roleIds: [] }), false);
  assert.equal(shouldRestoreCategoryGenerator(false, null, "category"), true);
  assert.equal(shouldRestoreCategoryGenerator(true, "other", "category"), true);
  assert.equal(shouldRestoreCategoryGenerator(true, "category", "category"), false);
});

test("AUD review: complete_workspace nie zwraca danych całej firmy rolom zakresowym", () => {
  assert.match(migration, /complete_workspace_before_aud_rvw_scoped_authorization_uat_v1/u);
  assert.match(migration, /matrix_v2_can_manage_resource_uat_v1/u);
  assert.match(migration, /v_employee-'hr'-'finance'/u);
  assert.match(migration, /'preferences','\[\]'::jsonb/u);
  assert.match(migration, /'integrationRuns','\[\]'::jsonb/u);
  assert.match(migration, /'timeRecords','\[\]'::jsonb/u);
  assert.match(migration, /'plan',null/u);
  assert.match(migration, /revoke all on function\s+public\.complete_workspace_before_aud_rvw_scoped_authorization_uat_v1/u);
});

test("AUD review: lider zarządza wyłącznie issue dokładnie przypisanej roli", () => {
  assert.match(migration, /aud_rvw_can_manage_schedule_issue_uat_v1/u);
  assert.match(migration, /grant_row\.role_logical_id is not null/u);
  assert.match(migration, /grant_row\.role_logical_id=role\.logical_id/u);
  assert.match(migration, /schedule\.id=p_schedule_id/u);
  assert.match(migration, /schedule\.status='PUBLISHED'/u);
  assert.match(migration, /raise exception 'FORBIDDEN'/u);
  assert.doesNotMatch(migration, /location_logical_id is null/u);
});

test("AUD review: request kategorii wymaga grantu do każdej aktywnej roli", () => {
  assert.match(migration, /required_roles/u);
  assert.match(migration, /member\.category_id=scope\.category_id/u);
  assert.match(migration, /not exists\(\s*select 1\s*from required_roles required/u);
  assert.match(migration, /grant_row\.role_logical_id=required\.logical_id/u);
  assert.match(migration, /OPTIMIZER_SCOPE_FORBIDDEN/u);
  assert.match(migration, /optimizer_create_manual_leader_studio_before_aud_rvw_uat_v1/u);
  assert.match(migration, /optimizer_create_leader_variant_before_aud_rvw_uat_v1/u);
  assert.match(migration, /can_edit_leader_variant_before_aud_rvw_uat_v1/u);
  assert.match(migration, /can_access_run_before_aud_rvw_uat_v1/u);
  assert.match(migration, /aud_rvw_can_request_optimizer_matrix_scope_uat_v1/u);
  assert.match(migration, /v_run\.matrix_version_id,v_run\.scope_type,v_run\.scope_role_id/u);
  assert.match(migration, /run\.matrix_version_id,run\.scope_type,run\.scope_role_id/u);
  assert.doesNotMatch(migration, /app_role='LOCATION_MANAGER'/u);
});

test("AUD review: frontend nie rozszerza uprawnień roli na kategorię", () => {
  assert.match(page, /canManageWholeSolverCategory\(accessPolicy/u);
  assert.match(page, /Nie masz uprawnień do wszystkich ról tej kategorii/u);
  assert.match(page, /!savedCategory\|\|!canManageSolverCategory\(savedCategory\)/u);
  assert.match(page, /sessionStorage\.removeItem\(planPanelStorageKey\)/u);
  assert.match(page, /modal!=="plan"\|\|!openCategory\|\|canManageSolverCategory\(openCategory\)/u);
  assert.match(page, /setModal\(null\)[\s\S]*setPlanScope\(\{type:"COMPANY",category:null\}\)/u);
  assert.match(page, /shouldRestoreCategoryGenerator\(modal==="plan",currentId,savedCategory\.id\)/u);
  assert.match(page, /setModal\(current=>current==="plan"\?current:"plan"\)/u);
  assert.match(page, /canReadFullEmployeeDirectory[\s\S]*matrix_v2_employee_directory_alpha16/u);
  assert.match(page, /canReadCompanyWorkspace[\s\S]*workforce_calendar_context_uat_v4/u);
});

test("AUD review: migracja jest ograniczona do dokładnego projektu UAT", () => {
  assert.match(migration, /control\.config->>'environment'='ISOLATED_UAT'/u);
  assert.match(migration, /control\.config->>'projectRef'='nhthrtpkfpmufmrmdyjg'/u);
  assert.match(migration, /control\.enabled is true/u);
});

test("AUD review: końcowe RPC są wywoływane jako authenticated i nie zostawiają skutków ubocznych", () => {
  const roleOffset = sqlContract.indexOf("set local role authenticated;");
  const diagnosticsOffset = sqlContract.indexOf("public.optimizer_candidate_diagnostics_alpha16(", roleOffset);
  const requestOffset = sqlContract.indexOf("public.optimizer_request_v2(", roleOffset);
  const resetOffset = sqlContract.indexOf("reset role;", roleOffset);
  assert.ok(roleOffset >= 0);
  assert.ok(diagnosticsOffset > roleOffset && diagnosticsOffset < resetOffset);
  assert.ok(requestOffset > roleOffset && requestOffset < resetOffset);
  assert.match(sqlContract, /AUD_RVW_FINAL_FOREIGN_ROLE_DIAGNOSTICS_ALLOWED/u);
  assert.match(sqlContract, /AUD_RVW_FINAL_PARTIAL_CATEGORY_REQUEST_ALLOWED/u);
  assert.match(sqlContract, /AUD_RVW_FINAL_REJECTED_RPC_LEFT_SIDE_EFFECTS/u);
  assert.match(sqlContract, /'anon','public\.optimizer_candidate_diagnostics_alpha16\(uuid,bigint\)','execute'/u);
  assert.match(sqlContract, /'authenticated','public\.optimizer_request_v2\(date,uuid,text,uuid,text,text,text\)','execute'/u);
});
