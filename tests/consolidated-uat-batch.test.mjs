import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = path => readFile(new URL(`../${path}`, import.meta.url), "utf8");

test("merge fallback keeps the publication action visible with a durable variant id", async () => {
  const [client,migration,panel]=await Promise.all([
    read("lib/solver-v2.ts"),
    read("supabase/migrations/20260816001553_consolidated_uat_overtime_budget_and_composite.sql"),
    read("components/RoleCompositePanel.tsx"),
  ]);
  assert.match(client,/PUBLISHED_ROLE_VARIANT/);
  assert.doesNotMatch(client,/if \(!source\.strategy\) throw new Error\("ROLE_COMPOSITE_STRATEGY_MISSING"\)/);
  assert.match(migration,/'strategy', jsonb_build_object/);
  assert.match(panel,/Opublikuj scalony grafik/);
  assert.match(panel,/inspectRole\(role\.publicationId/);
});

test("automatic generation honors global overtime consent and prices the individual nominal", async () => {
  const [model,engine,pricing,migration,approvalMigration,editor,workspace,client]=await Promise.all([
    read("solver/src/grafik_solver/models.py"),read("solver/src/grafik_solver/cp_sat_engine.py"),
    read("solver/src/grafik_solver/pay_rules.py"),
    read("supabase/migrations/20260816001553_consolidated_uat_overtime_budget_and_composite.sql"),
    read("supabase/migrations/20260816004500_leader_overtime_approval_uat.sql"),
    read("components/MatrixV2Editor.tsx"),read("components/SolverV2Workspace.tsx"),read("lib/solver-v2.ts"),
  ]);
  assert.match(model,/overtime_policy: str = "NEVER"/);
  assert.match(engine,/employee\.overtime_policy != "ALLOWED"/);
  assert.match(engine,/total <= employee\.nominal_monthly_minutes/);
  assert.match(pricing,/threshold_source == "EMPLOYEE_NOMINAL"/);
  assert.match(migration,/OVERTIME_PAY_RULE_MISSING/);
  assert.match(migration,/matrix_v2_employee_save_alpha16\(p_employee_id, p_data\)/);
  assert.doesNotMatch(migration,/matrix_v2_employee_save_uat_v2\(p_employee_id, p_data\)/);
  assert.match(editor,/TYLKO PO ZATWIERDZENIU/);
  assert.match(approvalMigration,/LEADER_OVERTIME_NOT_ALLOWED/);
  assert.match(approvalMigration,/LEADER_OVERTIME_APPROVAL_REQUIRED/);
  assert.match(approvalMigration,/requote_variant_payload_v2/);
  assert.match(approvalMigration,/'APPROVE_OVERTIME'/);
  assert.match(workspace,/Zatwierdź nadgodziny/);
  assert.match(workspace,/Pełny koszt po zmianie/);
  assert.match(client,/optimizer_leader_assignment_save_uat_v3/);
});

test("monthly planning budgets are cumulative, revisioned and enforce HARD TARGET or MONITORING", async () => {
  const [migration,page,drawer,model,engine]=await Promise.all([
    read("supabase/migrations/20260816001553_consolidated_uat_overtime_budget_and_composite.sql"),
    read("app/page.tsx"),read("components/MonthlyBudgetDrawer.tsx"),
    read("solver/src/grafik_solver/models.py"),read("solver/src/grafik_solver/cp_sat_engine.py"),
  ]);
  assert.match(migration,/monthly_budget_revisions_v2/);
  assert.match(migration,/budgetRevisionId/);
  assert.match(migration,/status='ARCHIVED'/);
  assert.match(migration,/enforcement in \('HARD','TARGET','MONITORING'\)/);
  assert.match(migration,/scope_type in \('COMPANY','LOCATION','CATEGORY','LOCATION_CATEGORY','ROLE'\)/);
  assert.match(migration,/BUDGET_TARGET_EXCESS/);
  assert.match(page,/Budżet miesiąca/);
  assert.match(drawer,/Budżety działają równocześnie/);
  assert.match(drawer,/LABOR_PERCENT/);
  assert.match(model,/metric_type: str = "COST"/);
  assert.match(engine,/budget\.enforcement == "MONITORING"/);
});

test("workbooks contain a per-sheet field dictionary and explicit overtime choices", async () => {
  const [polish,editor,parser]=await Promise.all([
    read("lib/excel-workbook-polish.ts"),read("components/MatrixV2Editor.tsx"),read("lib/matrix-workbook-import.ts"),
  ]);
  assert.match(polish,/addDataDictionary/);
  assert.match(polish,/Opis pól/);
  assert.match(polish,/OVERTIME_VALUES/);
  assert.match(editor,/Zgoda na nadgodziny/);
  assert.match(editor,/Grupy rezerwy/);
  assert.match(parser,/normalizeOvertimePolicy/);
  assert.match(parser,/standbyGroups/);
});

test("standby is configured as category groups and never consumes shortage capacity", async () => {
  const [migration,editor,workspace,client]=await Promise.all([
    read("supabase/migrations/20260816010000_configurable_category_standby_groups_uat.sql"),
    read("components/MatrixV2Editor.tsx"),read("components/SolverV2Workspace.tsx"),read("lib/solver-v2.ts"),
  ]);
  assert.match(migration,/standbyGroups/);
  assert.match(migration,/STANDBY_ROLE_USED_IN_MULTIPLE_GROUPS/);
  assert.match(migration,/issue\.issue_code='UNFILLED_SLOT'/);
  assert.match(migration,/issue\.role_id=any\(v_role_ids\)/);
  assert.match(migration,/eligible_role_ids/);
  assert.match(migration,/standby_activate_uat_v3/);
  assert.match(editor,/Rezerwa per kategoria/);
  assert.match(editor,/Role nieuwzględnione w żadnej grupie/);
  assert.match(workspace,/standbyAction\.eligibleRoleIds\.includes/);
  assert.match(client,/manager_standby_month_uat_v3/);
  assert.match(client,/optimizer_variant_standby_preview_uat_v2/);
});

test("a leader shortage opens the ad-hoc pool with the exact role and date", async () => {
  const [workspace,panel,recovery,page]=await Promise.all([
    read("components/SolverV2Workspace.tsx"),read("components/SolverV2Panel.tsx"),
    read("components/RecoveryCenter.tsx"),read("app/page.tsx"),
  ]);
  assert.match(workspace,/Sprawdź pulę ad-hoc/);
  assert.match(workspace,/roleId:issue\.role\?\.id/);
  assert.match(panel,/onOpenAdHoc=\{onOpenAdHoc\}/);
  assert.match(page,/initialTab=\{recoveryFocus\?"AD_HOC":"SHORTAGES"\}/);
  assert.match(recovery,/Brak w wersji lidera/);
  assert.match(recovery,/Utwórz pełny profil pracownika/);
  assert.match(recovery,/opublikuj konfigurację i wygeneruj kategorię ponownie/);
});
