import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { polishQueuedTaskSentence, polishTaskCount } from "../lib/polish-plural.ts";

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
  assert.match(client,/optimizer_leader_assignment_save_uat_v4/);
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

test("Polish queue copy handles singular, teens and compound plural forms", () => {
  assert.equal(polishTaskCount(1),"1 zadanie");
  assert.equal(polishTaskCount(2),"2 zadania");
  assert.equal(polishTaskCount(12),"12 zadań");
  assert.equal(polishTaskCount(22),"22 zadania");
  assert.equal(polishTaskCount(114),"114 zadań");
  assert.equal(polishQueuedTaskSentence(1),"Przed tym grafikiem jest jeszcze 1 zadanie");
  assert.equal(polishQueuedTaskSentence(5),"Przed tym grafikiem jest jeszcze 5 zadań");
  assert.equal(polishQueuedTaskSentence(12),"Przed tym grafikiem jest jeszcze 12 zadań");
  assert.equal(polishQueuedTaskSentence(22),"Przed tym grafikiem są jeszcze 22 zadania");
});

test("merge summary filters and opens the metric-specific detail in place", async () => {
  const [panel,workspace]=await Promise.all([
    read("components/RoleCompositePanel.tsx"),
    read("components/SolverV2Workspace.tsx"),
  ]);
  assert.match(panel,/focusAnalysis\("GAPS"\)/);
  assert.match(panel,/analysisMetric==="GAPS"\?"ISSUES"/);
  assert.match(panel,/analysisMetric==="TEAMS"\?"CALENDAR":"WORKLOAD"/);
  assert.match(panel,/aria-pressed=/);
  assert.match(panel,/initialView=\{inspectedRoleInitialView\}/);
  assert.match(workspace,/initialView\?:WorkspaceView/);
});

test("category snapshots keep every employee reference inside the retained workforce", async () => {
  const [migration,panel,page,client]=await Promise.all([
    read("supabase/migrations/20260816080000_uat_category_snapshot_employee_reference_guard.sql"),
    read("components/SolverV2Panel.tsx"),
    read("app/page.tsx"),
    read("lib/solver-v2.ts"),
  ]);
  for(const key of ["availabilityWindows","hardBlocks","externalAssignments","lockedAssignments","baselineAssignments"]){
    assert.match(migration,new RegExp(`'${key}'`));
  }
  assert.match(migration,/item\.value->>'employeeId'/);
  assert.match(migration,/jsonb_array_elements_text\(v_employee_ids\)/);
  assert.match(panel,/onOpenReadiness\?:\(\)=>void/);
  assert.match(panel,/onClick=\{onOpenReadiness\}/);
  assert.match(page,/closeModal\(\);openSetupStep\("structure","readiness"\)/);
  assert.match(client,/CONSTRAINT REFERENCES MISSING EMPLOYEE/);
});

test("daily shift validation ignores external assignments outside the selected month", async () => {
  const migration=await read(
    "supabase/migrations/20260816083000_uat_variant_daily_limit_period_guard.sql",
  );
  assert.match(migration,/v_period_start date:=\(p_snapshot->>'periodStart'\)::date/);
  assert.match(migration,/v_period_end date:=\(p_snapshot->>'periodEnd'\)::date/);
  assert.match(migration,/between v_period_start and v_period_end/);
  assert.match(migration,/validate_variant_before_primary_shift_invariants_v2/);
  assert.doesNotMatch(
    migration,
    /return solver_private\.validate_variant_before_daily_limit_period_guard_uat_v1/,
  );
});

test("B4F-91 versions permanent work patterns across UI, snapshot, solver and leader edits",async()=>{
  const [migration,editor,models,eligibility,client]=await Promise.all([
    read("supabase/migrations/20260818074124_b4f91_weekly_work_patterns.sql"),
    read("components/MatrixV2Editor.tsx"),read("solver/src/grafik_solver/models.py"),
    read("solver/src/grafik_solver/eligibility.py"),read("lib/solver-v2.ts"),
  ]);
  assert.match(migration,/employee_weekly_work_patterns_v2/);
  assert.match(migration,/revision integer not null/);
  assert.match(migration,/workPatterns/);
  assert.match(migration,/optimizer_leader_assignment_save_uat_v4/);
  assert.match(editor,/Stały wzorzec pracy/);
  assert.match(editor,/employee_weekly_work_patterns_replace_uat_v1/);
  assert.match(models,/class WorkPattern/);
  assert.match(eligibility,/PERMANENT_WORK_PATTERN/);
  assert.match(client,/optimizer_leader_assignment_validate_uat_v2/);
});

test("B4F-88 keeps wages, employer on-costs and incident proposals semantically separate",async()=>{
  const [migration,models,pricing,engine,validator,drawer]=await Promise.all([
    read("supabase/migrations/20260818093000_b4f88_full_employer_cost_engine.sql"),
    read("solver/src/grafik_solver/models.py"),read("solver/src/grafik_solver/pay_rules.py"),
    read("solver/src/grafik_solver/cp_sat_engine.py"),read("solver/src/grafik_solver/validator.py"),
    read("components/MonthlyBudgetDrawer.tsx"),
  ]);
  assert.match(migration,/employer_cost_components_v2/);
  assert.match(migration,/recovery_incident_rate_revisions_v2/);
  assert.match(migration,/status='APPROVED'/);
  assert.match(migration,/'costCategory','EMPLOYER_ONCOST'/);
  assert.match(migration,/'calculationType','BASE_RATE_OVERRIDE'/);
  assert.match(models,/cost_category: str = "WAGE"/);
  assert.match(models,/cost_basis: str = "WAGES"/);
  assert.match(pricing,/BASE_OVERRIDE_CALCULATION_TYPE/);
  assert.match(engine,/static_cost_for_basis/);
  assert.match(validator,/budget\.cost_basis == "FULL_EMPLOYER_COST"/);
  assert.match(drawer,/System niczego nie dolicza domyślnie/);
});

test("B4F-83 scopes persistent availability filters by category role and location",async()=>{
  const [migration,modules,page]=await Promise.all([
    read("supabase/migrations/20260818214442_b4f83_scoped_availability_summary.sql"),
    read("components/ActiveModules.tsx"),read("app/page.tsx"),
  ]);
  assert.match(migration,/workforce_calendar_context_uat_v4/);
  assert.match(migration,/'availabilityScopedSummary'/);
  assert.match(migration,/matrix_scope_grants_v2/);
  assert.match(migration,/scope_grant\.role_logical_id/);
  assert.match(migration,/scope_grant\.location_logical_id/);
  assert.match(modules,/setAvailabilityCategoryIds/);
  assert.match(modules,/setAvailabilityRoleIds/);
  assert.match(modules,/setAvailabilityLocationIds/);
  assert.match(modules,/Kategoria, rola, lokal, osoba lub data/);
  assert.match(modules,/workforce_calendar_context_uat_v4/);
  assert.match(page,/workforce_calendar_context_uat_v4/);
});
