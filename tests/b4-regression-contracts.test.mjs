import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migrationUrl = new URL(
  "../supabase/migrations/20260806100000_uat_finance_import_and_variant_preview.sql",
  import.meta.url,
);
const fullImportMigrationUrl = new URL(
  "../supabase/migrations/20260806133000_b4_full_company_roundtrip.sql",
  import.meta.url,
);
const fullImportWarningFixMigrationUrl = new URL(
  "../supabase/migrations/20260806150000_b4_full_import_preview_rate_warning_fix.sql",
  import.meta.url,
);
const diagnosticsAndPublicationFixMigrationUrl = new URL(
  "../supabase/migrations/20260806213000_b4_diagnostics_and_role_publication_fix.sql",
  import.meta.url,
);
const workloadDistributionMigrationUrl = new URL(
  "../supabase/migrations/20260806220000_b4_workload_distribution.sql",
  import.meta.url,
);
const workloadDistributionIntervalFixUrl = new URL(
  "../supabase/migrations/20260806221500_b4_workload_distribution_interval_fix.sql",
  import.meta.url,
);
const solverSemanticsMigrationUrl = new URL(
  "../supabase/migrations/20260806230000_b4_solver_semantics_standby_and_diagnostics.sql",
  import.meta.url,
);
const accessAndDraftMigrationUrl = new URL(
  "../supabase/migrations/20260815170000_uat_access_draft_shared_coverage_and_solver_release.sql",
  import.meta.url,
);
const sharedCoverageRollbackUrl = new URL(
  "../supabase/migrations/20260815190000_uat_revert_unapproved_shared_coverage.sql",
  import.meta.url,
);
const draftCascadeGuardFixUrl = new URL(
  "../supabase/migrations/20260815193000_uat_matrix_draft_cascade_guard_fix.sql",
  import.meta.url,
);
const workforceDraftCascadeGuardFixUrl = new URL(
  "../supabase/migrations/20260815194000_uat_matrix_workforce_draft_cascade_guard_fix.sql",
  import.meta.url,
);
const configurableStandbyMigrationUrl = new URL(
  "../supabase/migrations/20260816010000_configurable_category_standby_groups_uat.sql",
  import.meta.url,
);
const discardDraftAdHocFixUrl = new URL(
  "../supabase/migrations/20260815212630_uat_discard_draft_ad_hoc_fk_fix.sql",
  import.meta.url,
);
const localDateWorkloadDiagnosticsUrl = new URL(
  "../supabase/migrations/20260817202257_b4f79_local_date_workload_diagnostics.sql",
  import.meta.url,
);

test("B4 migration restores every server contract required by the UI", async () => {
  const sql = await readFile(migrationUrl, "utf8");
  assert.match(sql, /matrix_v2_finance_import_preview_uat_v1/);
  assert.match(sql, /matrix_v2_finance_import_apply_uat_v1/);
  assert.match(sql, /optimizer_variant_workspace_uat_v2/);
  assert.match(sql, /optimizer_published_schedule_alpha16/);
  assert.match(sql, /jsonb_build_object\('engine','ORTOOLS_V2'\)/);
});

test("explicit nominal and maximum hours survive every contract type", async () => {
  const [model,sql,workspace] = await Promise.all([
    readFile(new URL("../solver/src/grafik_solver/models.py",import.meta.url),"utf8"),
    readFile(solverSemanticsMigrationUrl,"utf8"),
    readFile(new URL("../components/SolverV2Workspace.tsx",import.meta.url),"utf8"),
  ]);
  assert.doesNotMatch(model,/is_flexible_contractor[\s\S]{0,600}nominal_monthly_minutes = None/);
  assert.match(sql,/'nominalMonthlyMinutes',coalesce\(profile\.nominal_monthly_minutes,0\)/);
  assert.match(sql,/'maximumMonthlyMinutes',coalesce\(profile\.maximum_monthly_minutes,0\)/);
  assert.match(workspace,/Powyżej twardego limitu/);
  assert.match(workspace,/ABOVE_MAXIMUM/);
});

test("B4 full company restore is a single authenticated transaction with a dry run", async () => {
  const sql=await readFile(fullImportMigrationUrl,"utf8");
  assert.match(sql,/matrix_v2_full_import_preview_uat_v1/);
  assert.match(sql,/matrix_v2_full_import_apply_uat_v1/);
  assert.match(sql,/FULL_IMPORT_DRY_RUN_COMPLETE/);
  assert.match(sql,/matrix_v2_full_import_phase_uat_v1\(v_configuration,'PRE'\)/);
  assert.match(sql,/matrix_v2_import_apply_uat_v5\(v_configuration_without_rates,p_mode\)/);
  assert.match(sql,/matrix_v2_finance_import_apply_uat_v1/);
  assert.match(sql,/has_app_role\('OWNER'\).*has_app_role\('ADMIN'\)/s);
  assert.match(sql,/revoke all on function public\.matrix_v2_full_import_preview_uat_v1/);
});

test("B4 full preview accepts dedicated finance rows without false missing-rate warnings", async () => {
  const sql=await readFile(fullImportWarningFixMigrationUrl,"utf8");
  assert.match(sql,/warning\.value->>'code'<>'PAY_RATE_MISSING'/);
  assert.match(sql,/upper\(rate\.value->>'employeeNo'\)=upper\(employee\.value->>'employeeNo'\)/);
  assert.match(sql,/nullif\(rate\.value->>'baseRate',''\) is not null/);
  assert.match(sql,/publikację konfiguracji firmy/);
  assert.match(sql,/set search_path = ''/);
  assert.match(sql,/revoke all on function public\.matrix_v2_full_import_preview_uat_v1/);
});

test("standby exhaustion cannot block a required schedule publication", async () => {
  const sql = await readFile(configurableStandbyMigrationUrl, "utf8");
  const repairedFunction = sql.slice(sql.lastIndexOf(
    "create or replace function solver_private.generate_standby_for_variant_uat_v2",
  ));
  assert.match(repairedFunction, /standbyGroups/);
  assert.match(repairedFunction, /if v_candidate\.employee_id is null then exit;/);
  assert.match(repairedFunction, /issue\.issue_code='UNFILLED_SLOT'/);
  assert.doesNotMatch(repairedFunction, /STANDBY_COVERAGE_INSUFFICIENT/);
});

test("standby activation revalidates the full hard-rule set", async () => {
  const sql = await readFile(migrationUrl, "utf8");
  for (const rule of [
    "ROLE_REQUIRED",
    "LOCATION_NOT_ALLOWED",
    "DUTY_REQUIRED",
    "HARD_UNAVAILABLE",
    "OUTSIDE_AVAILABILITY_WINDOW",
    "OUTSIDE_EMPLOYMENT",
    "NO_WEEKENDS",
    "ONLY_MORNING",
    "ONLY_EVENING",
    "DAILY_SHIFT_LIMIT",
    "SHIFT_OR_REST_CONFLICT",
    "MAXIMUM_MONTHLY_HOURS",
    "MAXIMUM_WEEKLY_HOURS",
    "MAX_CONSECUTIVE_DAYS",
  ]) assert.match(sql, new RegExp(rule));
  assert.match(sql, /standby_activation_reasons_uat_v2/);
  assert.match(sql, /v_enforce_work_time/);
  assert.match(sql, /hardRulesRevalidated/);
});

test("new solver balances contract utilization inside every role", async () => {
  const source = await readFile(new URL(
    "../solver/src/grafik_solver/cp_sat_engine.py",
    import.meta.url,
  ), "utf8");
  assert.match(source, /LOAD_SPREAD_MINUTES": "ROLE_LOAD_FAIRNESS_SCORE/);
  assert.match(source, /ROLE_LOAD_FAIRNESS_ROLE_COUNT/);
  assert.match(source, /STRATEGY_RESULT_DOMINATED/);
  assert.match(source, /add_division_equality/);
  assert.match(source, /LOAD_UTILIZATION_TARGET_COUNT/);
  assert.match(source, /fairnessIncumbentGuard/);
  assert.match(source, /fairness_first/);
  assert.match(source, /artifacts\.metrics\[metric_name\] <= bound/);
  assert.doesNotMatch(source, /len\(eligible_employee_ids\) - standby_tiers/);
});

test("B4 user interface does not expose retired Matrix and English event labels", async () => {
  const [generator, panel, editor, modules, app, solverClient] = await Promise.all([
    readFile(new URL("../components/SolverV2Workspace.tsx", import.meta.url), "utf8"),
    readFile(new URL("../components/SolverV2Panel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../components/MatrixV2Editor.tsx", import.meta.url), "utf8"),
    readFile(new URL("../components/ActiveModules.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../lib/solver-v2.ts", import.meta.url), "utf8"),
  ]);
  const visibleSource = `${generator}\n${panel}\n${editor}\n${modules}\n${app}`;
  for (const retiredLabel of [
    "Optymalizacja całego Matrixa",
    "Źródło danych: opublikowany Matrix",
    "Event + obsada",
    "> HOT DAY<",
    "> Event<",
    "Eventy i HOT DAY",
    "MATRIX ORGANIZACJI",
  ]) assert.doesNotMatch(visibleSource, new RegExp(retiredLabel));
  assert.match(visibleSource, /Wydarzenie \+ obsada/);
  assert.match(visibleSource, /Limit nieobecności/);
  assert.match(editor, /KONFIGURACJA FIRMY • MODEL DYNAMICZNY/);
  assert.match(editor, /importIssueMessage\(issue\)/);
  assert.match(solverClient, /Nieobsadzone miejsce w wymaganej obsadzie/);
  assert.match(app, /grafik-pro:selected-month/);
  assert.match(panel, /rolePublication\.variantId/);
  assert.match(app, /\["scalanie","2\. Scal i porównaj grafik firmy"\]/);
  assert.match(app, /ETAP 2 Z 3 • SCALANIE FIRMY/);
  assert.doesNotMatch(modules, /<RoleCompositePanel/);
});

test("daily employee shift limit has one configurable source across UI, solver and validation", async () => {
  const [editor, engine, validator, invariantSql, diagnosticSql] = await Promise.all([
    readFile(new URL("../components/MatrixV2Editor.tsx", import.meta.url), "utf8"),
    readFile(new URL("../solver/src/grafik_solver/cp_sat_engine.py", import.meta.url), "utf8"),
    readFile(new URL("../solver/src/grafik_solver/validator.py", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260804210000_primary_shift_sequence_invariants.sql", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260805010000_diagnostic_hard_rules_and_actions.sql", import.meta.url), "utf8"),
  ]);
  assert.match(editor, /name="maximumShiftsPerDay"/);
  assert.match(editor, /Rezerwa per kategoria/);
  assert.doesNotMatch(editor, /const maximumShiftsPerDay = 1;/);
  assert.match(engine, /employee\.maximum_shifts_per_day/);
  assert.match(validator, /count > employee\.maximum_shifts_per_day/);
  assert.match(invariantSql, /count\(distinct item_key\)>v_maximum_shifts_per_day/);
  assert.match(diagnosticSql, /count\(distinct assignment\.shift_id\)/);
});

test("solver failure copy distinguishes an incomplete optimum proof from a worker conflict", async () => {
  const [panel, solverClient] = await Promise.all([
    readFile(new URL("../components/SolverV2Panel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../lib/solver-v2.ts", import.meta.url), "utf8"),
  ]);
  assert.match(solverClient, /OPTIMIZATION_INCOMPLETE/);
  assert.match(solverClient, /STRATEGY_RESULT_DOMINATED/);
  assert.match(solverClient, /UNFILLED_NOT_PROVEN/);
  assert.match(solverClient, /STATUS=FEASIBLE/);
  assert.match(solverClient, /RUN_ALREADY_CLAIMED/);
  assert.doesNotMatch(solverClient, /normalized\.includes\("CONFLICT"\)/);
  assert.match(panel, /run\.failureMessage && run\.status!=="FAILED"/);
  assert.match(panel, /run\.failureMessage\?solverErrorMessage\(run\.failureMessage\)/);
});

test("ordinary planning accepts the best feasible schedule while audit mode stays strict", async () => {
  const [engine,panel]=await Promise.all([
    readFile(new URL("../solver/src/grafik_solver/cp_sat_engine.py",import.meta.url),"utf8"),
    readFile(new URL("../components/SolverV2Panel.tsx",import.meta.url),"utf8"),
  ]);
  assert.match(engine,/snapshot\.settings\.require_optimal[\s\S]*minimum_unfilled > 0[\s\S]*not coverage_minimum_proven/);
  assert.match(panel,/onClick=\{onOpenReadiness\}/);
  assert.match(panel,/Przejdź do kontroli gotowości/);
});

test("bulk access and idempotent draft cancellation remain explicit UAT contracts", async () => {
  const [editor,sql,rollback]=await Promise.all([
    readFile(new URL("../components/MatrixV2Editor.tsx",import.meta.url),"utf8"),
    readFile(accessAndDraftMigrationUrl,"utf8"),
    readFile(sharedCoverageRollbackUrl,"utf8"),
  ]);
  assert.match(editor,/szafunek-dostepy-do-aplikacji\.xlsx/);
  assert.match(editor,/application_access_bulk_apply_uat_v1/);
  assert.match(editor,/matrix_v2_discard_current_draft_uat_v2/);
  assert.match(editor,/Anuluj wersję roboczą/);
  assert.match(editor,/matrix_v2_shift_staffing_save_uat_v3/);
  assert.doesNotMatch(editor,/matrix_v2_shift_staffing_save_uat_v4/);
  assert.match(sql,/create or replace function public\.application_access_bulk_apply_uat_v1/);
  assert.match(sql,/create or replace function public\.matrix_v2_discard_draft_uat_v1/);
  // The rejected experiment remains in append-only migration history, but a
  // later migration must explicitly remove it before any release is promoted.
  assert.match(sql,/SHARED_ROTATION|sharedCoverageGroup/);
  assert.match(rollback,/drop function if exists public\.matrix_v2_shift_staffing_save_uat_v4/);
  assert.match(rollback,/No cross-location demand collapsing is applied/);
});

test("draft cancellation permits only the FK cascade child-delete path", async () => {
  const sql=await readFile(draftCascadeGuardFixUrl,"utf8");
  assert.match(sql,/if tg_op='DELETE' then return old; end if;\s*raise exception 'MATRIX_VERSION_NOT_FOUND'/);
  assert.match(sql,/if v_status<>'DRAFT' then raise exception 'MATRIX_VERSION_IMMUTABLE'/);
  assert.match(sql,/Direct orphaning remains impossible by/);
  assert.doesNotMatch(sql,/session_replication_role|disable trigger/i);
});

test("draft cancellation also permits the workforce-profile cascade path", async () => {
  const sql=await readFile(workforceDraftCascadeGuardFixUrl,"utf8");
  assert.match(sql,/guard_matrix_employee_profile_v2/);
  assert.match(sql,/if tg_op='DELETE' then return old; end if;\s*raise exception 'MATRIX_WORKFORCE_VERSION_NOT_FOUND'/);
  assert.match(sql,/if v_status<>'DRAFT' then\s*raise exception 'MATRIX_WORKFORCE_VERSION_IMMUTABLE'/);
  assert.match(sql,/Foreign keys still prevent a direct orphan/);
  assert.doesNotMatch(sql,/session_replication_role|disable trigger/i);
});

test("draft cancellation reconnects ad-hoc rows before deleting draft roles", async () => {
  const sql=await readFile(discardDraftAdHocFixUrl,"utf8");
  const reconnect=sql.indexOf("update public.recovery_ad_hoc_pool_v2");
  const cleanup=sql.indexOf("delete from public.recovery_ad_hoc_pool_v2");
  const discard=sql.indexOf("delete from public.matrix_versions");
  assert.ok(reconnect>=0&&cleanup>reconnect&&discard>cleanup);
  assert.match(sql,/active_role\.logical_id=draft_role\.logical_id/);
  assert.match(sql,/'adHocRowsReconnected',v_ad_hoc_reconnected/);
  assert.doesNotMatch(sql,/session_replication_role|disable trigger/i);
});

test("leader corrections explain the rejected hard rule instead of reporting a connection failure", async () => {
  const solverClient = await readFile(new URL("../lib/solver-v2.ts", import.meta.url), "utf8");
  assert.match(solverClient, /VARIANT_HARD_BLOCK_INVALID/);
  assert.match(solverClient, /ma twardą niedostępność, urlop albo L4/);
  assert.match(solverClient, /VARIANT_OVERLAP_OR_REST_INVALID/);
  assert.match(solverClient, /zbyt krótki odpoczynek/);
  assert.match(solverClient, /VARIANT_WORK_LIMIT_INVALID/);
  assert.match(solverClient, /przekroczyłaby limit pracy/);
});

test("B4 candidate diagnostics use the real configuration table", async () => {
  const sql=await readFile(diagnosticsAndPublicationFixMigrationUrl,"utf8");
  assert.match(sql,/from public\.matrix_versions version/);
  assert.doesNotMatch(sql,/from public\.matrix_versions_v2 version/);
  assert.match(sql,/maximumShiftsPerDay/);
});

test("B4 role publication supersedes the previous logical role across configuration versions", async () => {
  const sql=await readFile(diagnosticsAndPublicationFixMigrationUrl,"utf8");
  assert.match(sql,/previous_role\.logical_id=v_logical_role_id/);
  assert.match(sql,/publication\.status='PUBLISHED'/);
  assert.match(sql,/published_role_supersede_logical_predecessor_v2/);
  assert.match(sql,/pg_advisory_xact_lock/);
});

test("employee availability save stays in the open calendar", async () => {
  const modules=await readFile(new URL("../components/ActiveModules.tsx",import.meta.url),"utf8");
  const saveBlock=modules.slice(
    modules.indexOf("async function saveTimeConstraint"),
    modules.indexOf("async function saveShiftPreferences"),
  );
  assert.match(saveBlock,/await loadPortal\(\)/);
  assert.doesNotMatch(saveBlock,/await reload\(\)/);
});

test("optimum is presented as an optional audit mode, not a promise of a better schedule", async () => {
  const [editor,panel]=await Promise.all([
    readFile(new URL("../components/MatrixV2Editor.tsx",import.meta.url),"utf8"),
    readFile(new URL("../components/SolverV2Panel.tsx",import.meta.url),"utf8"),
  ]);
  assert.match(editor,/Tryb audytowy: wymagaj matematycznego dowodu optimum/);
  assert.match(editor,/nie ulepsza automatycznie grafiku/);
  assert.doesNotMatch(panel,/Czekaj na matematycznie najlepszy wynik/);
});

test("variant comparison is constrained to the drawer width", async () => {
  const css=await readFile(new URL("../app/product-journey.css",import.meta.url),"utf8");
  assert.match(css,/\.solver-v2-grid>article\{min-width:0;max-width:100%\}/);
  assert.match(css,/\.solver-v2-analysis dt small\{display:block/);
  assert.match(css,/@media\(max-width:1180px\)\{\.solver-v2-grid\{grid-template-columns:repeat\(2,minmax\(0,1fr\)\)\}\}/);
});

test("leader workload distribution includes the full eligible roster and decision reasons", async () => {
  const [sql,workspace,client]=await Promise.all([
    readFile(workloadDistributionMigrationUrl,"utf8"),
    readFile(new URL("../components/SolverV2Workspace.tsx",import.meta.url),"utf8"),
    readFile(new URL("../lib/solver-v2.ts",import.meta.url),"utf8"),
  ]);
  assert.match(sql,/optimizer_variant_workload_distribution_uat_v1/);
  assert.match(sql,/matrix_employee_profiles_v2 profile/);
  assert.match(sql,/coalesce\(stats\.planned_minutes,0\)/);
  assert.match(sql,/AVAILABILITY_LIMITED/);
  assert.match(sql,/SOLVER_DISTRIBUTION/);
  assert.match(sql,/TARGET_NOT_SET/);
  assert.match(sql,/matrix_locations_v2 location/);
  assert.match(workspace,/Rozkład pracy zespołu/);
  assert.match(workspace,/Dlaczego taki wynik\?/);
  assert.match(workspace,/WERSJA LIDERA • JESZCZE NIEOPUBLIKOWANA/);
  assert.match(client,/getVariantWorkloadDistribution/);
});

test("workload distribution uses a valid end-of-month interval", async () => {
  const [sql,fix]=await Promise.all([
    readFile(workloadDistributionMigrationUrl,"utf8"),
    readFile(workloadDistributionIntervalFixUrl,"utf8"),
  ]);
  assert.match(sql,/interval '1 month'-interval '1 day'/);
  assert.doesNotMatch(sql,/interval '1 month-1 day'/);
  assert.match(fix,/WORKLOAD_DISTRIBUTION_INTERVAL_FIX_FAILED/);
});

test("schedule review is a fullscreen weekly workspace without collapsed day lists", async () => {
  const [workspace,css]=await Promise.all([
    readFile(new URL("../components/SolverV2Workspace.tsx",import.meta.url),"utf8"),
    readFile(new URL("../app/product-journey.css",import.meta.url),"utf8"),
  ]);
  assert.match(workspace,/Grafik tygodniowy/);
  assert.match(workspace,/Rozkład pracy/);
  assert.match(workspace,/Braki i powody/);
  assert.match(workspace,/solver-roster-grid/);
  assert.match(workspace,/Pracownicy/);
  assert.match(workspace,/Stanowiska/);
  assert.match(workspace,/Pokrycie obsady/);
  assert.doesNotMatch(workspace,/className="solver-workspace-calendar"/);
  assert.match(workspace,/solver-week-duties/);
  assert.match(css,/\.drawer\.solver-drawer\{inset:0!important;width:100vw!important/);
  assert.match(css,/grid-template-columns:minmax\(128px,1\.15fr\) repeat\(7,minmax\(0,1fr\)\)/);
});

test("location filter keeps the issue summary, badge and empty state consistent", async () => {
  const workspace=await readFile(new URL("../components/SolverV2Workspace.tsx",import.meta.url),"utf8");
  assert.match(workspace,/<small>\{visibleIssues\.length\}<\/small>/);
  assert.match(workspace,/visibleIssues\.length === 0/);
  assert.match(workspace,/Brak braków i uwag dla wybranego lokalu\./);
  assert.doesNotMatch(workspace,/<small>\{workspace\.issues\.length\}<\/small>/);
});

test("category cards hide engine jargon and optional operational tools stay collapsed", async () => {
  const modules=await readFile(new URL("../components/ActiveModules.tsx",import.meta.url),"utf8");
  assert.match(modules,/role-plan-cards compact/);
  assert.match(modules,/solverRoleCategories\.map\(\(category\)/);
  assert.match(modules,/roleCardStyle\(category\.id,category\.color\)/);
  assert.match(modules,/category\.roleNames\.join\(" • "\)/);
  assert.match(modules,/onOpenSolverV2\?\.\(category\)/);
  assert.doesNotMatch(modules,/<strong>OR-Tools<\/strong>/);
  assert.doesNotMatch(modules,/Scenariusze, warianty i analiza OR-Tools/);
  assert.match(modules,/<details className="operational-additional-tools">/);
  assert.match(modules,/Narzędzia dodatkowe/);
  assert.match(modules,/technical-details/);
});

test("token refresh does not reload the whole application context", async () => {
  const provider=await readFile(new URL("../components/AppAuthProvider.tsx",import.meta.url),"utf8");
  const listener=provider.slice(provider.indexOf("onAuthStateChange"),provider.indexOf("return () => listener.subscription.unsubscribe"));
  assert.match(listener,/event === "SIGNED_IN" \|\| event === "USER_UPDATED"/);
  assert.doesNotMatch(listener,/event === "TOKEN_REFRESHED"/);
});

test("employee and company calendars open a filterable day workspace", async () => {
  const [modules,css]=await Promise.all([
    readFile(new URL("../components/ActiveModules.tsx",import.meta.url),"utf8"),
    readFile(new URL("../app/uat-overhaul.css",import.meta.url),"utf8"),
  ]);
  assert.match(modules,/employee-day-workspace/);
  assert.match(modules,/Pracujesz z/);
  assert.match(modules,/company-day-workspace/);
  assert.match(modules,/Wszystkie role/);
  assert.match(modules,/Wszystkie lokale/);
  assert.match(modules,/roleCardStyle\(assignment\.roleId,roleColors\[assignment\.roleId\]\)/);
  assert.match(css,/\.company-day-filters/);
  assert.match(css,/\.employee-coworker-grid/);
});

test("publishing a leader copy selects that copy before role publication", async () => {
  const [panel,client]=await Promise.all([
    readFile(new URL("../components/SolverV2Panel.tsx",import.meta.url),"utf8"),
    readFile(new URL("../lib/solver-v2.ts",import.meta.url),"utf8"),
  ]);
  const handler=panel.slice(panel.indexOf("async function publishSelectedRole"),panel.indexOf("function startAnother"));
  assert.match(handler,/selectSolverVariant\(supabase, run\.id, leaderVariant\.id\)/);
  assert.ok(handler.indexOf("selectSolverVariant")<handler.indexOf("publishRoleVariant"));
  assert.match(client,/SELECTED_VALID_ROLE_VARIANT_REQUIRED/);
});

test("solver honors Matrix strategy budgets and fair-distribution tier order", async () => {
  const [engine,sql,gateway]=await Promise.all([
    readFile(new URL("../solver/src/grafik_solver/cp_sat_engine.py",import.meta.url),"utf8"),
    readFile(new URL("../supabase/migrations/20260806233000_b4_fair_distribution_priority.sql",import.meta.url),"utf8"),
    readFile(new URL("../supabase/functions/solver-gateway/contract.ts",import.meta.url),"utf8"),
  ]);
  assert.doesNotMatch(engine,/MAX_RELAXED_STRATEGY_SECONDS/);
  assert.match(engine,/configured_strategy_budget =/);
  assert.match(engine,/strategy\.time_limit_seconds/);
  assert.match(engine,/configured_coverage_ceiling/);
  assert.doesNotMatch(engine,/MAX_RELAXED_COVERAGE_SECONDS/);
  assert.match(engine,/remaining_strategy_budget \/ max\(1, remaining_strategy_count\)/);
  assert.match(engine,/incumbent_zero_tier =/);
  assert.match(engine,/"verifiedZeroIncumbent": True/);
  assert.match(sql,/when 'LOAD_SPREAD_MINUTES' then 3/);
  assert.match(sql,/when 'NOMINAL_DEVIATION_MINUTES' then 4/);
  assert.match(sql,/version\.status = 'DRAFT'/);
  assert.match(gateway,/"fairnessIncumbentGuard"/);
  assert.match(gateway,/"verifiedZeroIncumbent"/);
});

test("relaxed comparison reserves solver time for every remaining business tier", async () => {
  const engine=await readFile(new URL("../solver/src/grafik_solver/cp_sat_engine.py",import.meta.url),"utf8");
  assert.match(engine,/remaining_tier_count = len\(ordered_tiers\) - tier_index \+ 1/);
  assert.match(engine,/usable_tier_budget \/ max\(1, remaining_tier_count\)/);
  assert.match(engine,/time_limit_seconds=tier_time_budget/);
  assert.match(engine,/"timeBudgetSeconds": round\(tier_time_budget, 3\)/);
});

test("team catalog uses the same explicit target and hard limit semantics as the solver", async () => {
  const page=await readFile(new URL("../app/page.tsx",import.meta.url),"utf8");
  assert.match(page,/Cel godzinowy/);
  assert.match(page,/Twardy limit miesięczny/);
  assert.match(page,/Te same dane czyta generator, publikacja, portal oraz pełny eksport firmy/);
  assert.doesNotMatch(page,/Uzgodniony pułap \(informacyjny\)/);
  assert.doesNotMatch(page,/nie blokuje silnika/);
});

test("calendar comparison can preselect the compared employee for a server-validated replacement", async () => {
  const [workspace,styles]=await Promise.all([
    readFile(new URL("../components/SolverV2Workspace.tsx",import.meta.url),"utf8"),
    readFile(new URL("../app/product-journey.css",import.meta.url),"utf8"),
  ]);
  assert.match(workspace,/preferredEmployeeId/);
  assert.match(workspace,/context\.candidates\.some\(candidate=>candidate\.employeeId===preferredEmployeeId&&candidate\.suggestionEligible\)/);
  assert.match(workspace,/Sprawdź, czy \{primary\.length\?comparisonEmployee\.firstName:employeeDetailShortName\} może przejąć tę zmianę/);
  assert.match(workspace,/rolę, lokal i obowiązek/);
  assert.match(workspace,/przejmie obowiązek/);
  assert.match(workspace,/employee-unified-month-calendar/);
  assert.match(workspace,/Dostępność, zmiany, obowiązki i lokale obu osób są warstwami tego samego dnia/);
  assert.match(workspace,/Wolne w grafiku/);
  assert.doesNotMatch(workspace,/employee-availability-comparison/,
    "porównanie pracownika nie może renderować osobnego kalendarza dostępności nad grafikiem");
  assert.doesNotMatch(workspace,/employee-compare-weeks/,
    "grafik i dostępność mają być jedną siatką dat, a nie dwoma kalendarzami");
  assert.match(styles,/\.employee-unified-weeks>section\{display:grid;grid-template-columns:repeat\(7,minmax\(0,1fr\)\)\}/);
});

test("shortage candidates open their calendar and an audited leader-only limit override", async () => {
  const workspace=await readFile(new URL("../components/SolverV2Workspace.tsx",import.meta.url),"utf8");
  const client=await readFile(new URL("../lib/solver-v2.ts",import.meta.url),"utf8");
  const migration=await readFile(new URL("../supabase/migrations/20260807090000_b4_leader_limit_override_and_candidate_context.sql",import.meta.url),"utf8");
  assert.match(workspace,/openEmployeeCalendar\(candidate\)/);
  assert.match(workspace,/Zaproponowane godziny/);
  assert.match(workspace,/Przypisz mimo limitu/);
  assert.match(workspace,/candidate\.reasons\.every\(reason=>reason==="WEEKLY_LIMIT"\|\|reason==="MONTHLY_LIMIT"\)/);
  assert.match(client,/p_allow_limit_override: input\.allowLimitOverride \?\? false/);
  assert.match(migration,/LEADER_LIMIT_OVERRIDE_REQUIRED/);
  assert.match(migration,/'limitOverride',jsonb_array_length\(v_limit_details\)>0 and p_allow_limit_override/);
  assert.match(migration,/maximumMonthlyMinutes',2147483647,'maximumWeeklyMinutes',2147483647/);
  assert.match(migration,/WEEKLY_LIMIT','label',format/);
});

test("every opened variant owns fresh workload and diagnostic state", async () => {
  const panel=await readFile(new URL("../components/SolverV2Panel.tsx",import.meta.url),"utf8");
  const workspace=await readFile(new URL("../components/SolverV2Workspace.tsx",import.meta.url),"utf8");
  assert.match(panel,/key=\{`leader:/);
  assert.match(panel,/key=\{`preview:/);
  assert.match(panel,/key=\{`inspect:/);
  assert.match(workspace,/const workspaceIdentity=/);
  assert.match(workspace,/setWorkloadRows\(null\)/);
  assert.match(workspace,/workloadVariantId===workspaceVariantId/);
  assert.match(workspace,/setWorkloadVariantId\(workspaceVariantId\)/);
  assert.match(workspace,/setComparisonAvailability\(\[\]\)/);
});

test("B4F-79 workload diagnostics count company-local days instead of UTC dates", async () => {
  const sql=await readFile(localDateWorkloadDiagnosticsUrl,"utf8");
  assert.match(sql,/version\.settings->>'timezone'/);
  assert.match(sql,/lower\(constraint_row\.time_range\) at time zone v_timezone/);
  assert.match(sql,/upper\(constraint_row\.time_range\)-interval '1 microsecond'\) at time zone v_timezone/);
  assert.match(sql,/v_run\.month::timestamp at time zone v_timezone/);
  assert.doesNotMatch(sql,/at time zone 'UTC'/);
});

test("UAT-052 availability uses the company timezone and swap actions stay in flow", async () => {
  const migration=await readFile(new URL("../supabase/migrations/20260817150626_uat052_availability_local_date_contract.sql",import.meta.url),"utf8");
  const css=await readFile(new URL("../app/product-journey.css",import.meta.url),"utf8");
  assert.match(migration,/at time zone v_timezone\)::date<=day_value\.day_date/);
  assert.match(migration,/upper\(constraint_row\.time_range\)-interval '1 microsecond'\) at time zone v_timezone/);
  assert.match(css,/\.possible-swap-day\{position:static!important;right:auto!important;top:auto!important;/);
  assert.match(css,/height:auto!important/);
});

test("swap discovery starts on the first employee and validates availability plus duty hand-off", async () => {
  const workspace=await readFile(new URL("../components/SolverV2Workspace.tsx",import.meta.url),"utf8");
  const client=await readFile(new URL("../lib/solver-v2.ts",import.meta.url),"utf8");
  const migration=await readFile(new URL("../supabase/migrations/20260807152000_b4_swap_suggestions_and_duty_transfer.sql",import.meta.url),"utf8");
  assert.match(workspace,/Możliwa zamiana/);
  assert.match(workspace,/possible-swap-day/);
  assert.match(workspace,/swap-suggestion-hint/);
  assert.match(workspace,/suggestionEligible/);
  assert.match(workspace,/dutyCoverageMode===\"TRANSFER\"/);
  assert.match(workspace,/DAILY_LIMIT:\"Osiągnięty dzienny limit zmian\"/);
  assert.match(client,/optimizer_leader_assignment_context_uat_v4/);
  assert.match(client,/p_duty_transfer_assignment_id/);
  assert.match(migration,/optimizer_employee_availability_month_uat_v1/);
  assert.match(migration,/'date',day_value\.day_date::date/);
  assert.match(migration,/dutyTransferAssignmentId/);
  assert.match(migration,/occupied_shift\.shift_date=v_shift\.shift_date/);
  assert.match(migration,/then 'DAILY_LIMIT'/);
  assert.match(migration,/DUTY_TRANSFER_REQUIRED/);
});

test("employee portal uses one combined schedule and availability calendar", async () => {
  const modules=await readFile(new URL("../components/ActiveModules.tsx",import.meta.url),"utf8");
  const css=await readFile(new URL("../app/product-journey.css",import.meta.url),"utf8");
  const uatCss=await readFile(new URL("../app/uat-overhaul.css",import.meta.url),"utf8");
  const publicationCalendar=await readFile(new URL("../supabase/migrations/20260809152000_b4_deduplicate_published_company_calendar.sql",import.meta.url),"utf8");
  assert.match(modules,/Grafik i dostępność w jednym kalendarzu/);
  assert.match(modules,/employee-combined-calendar/);
  assert.match(css,/\.portal-grid\.portal-top\{grid-template-columns:minmax\(250px,320px\) minmax\(0,1fr\)\}/);
  assert.match(css,/\.employee-combined-calendar \.availability-calendar-content\{min-height:0;grid-template-columns:minmax\(560px,1\.55fr\) minmax\(310px,\.65fr\)\}/);
  assert.match(uatCss,/\.availability-calendar-content > \.availability-month-status \{\s*grid-column: 1 \/ -1;/);
  assert.match(modules,/publishedAssignments\.length/);
  assert.match(modules,/portal\?\.employee\?\.id \|\| portal\?\.timeConstraints\?\.employeeId/);
  assert.match(modules,/Niedostępność zostanie zapisana PO publikacji/);
  assert.match(modules,/Zapisano niedostępność po publikacji/);
  assert.match(modules,/Konflikty z opublikowanym grafikiem:/);
  assert.match(css,/\.employee-calendar-card\{display:none\}/);
  assert.match(publicationCalendar,/distinct on\(role\.logical_id\)/);
  assert.match(publicationCalendar,/where not exists\(select 1 from company_variants\)/);
  assert.match(publicationCalendar,/'locationId',location\.logical_id/);
  assert.match(publicationCalendar,/'roleId',role\.logical_id/);
});

test("employee portal never calls the owner-only UAT MASTER persona preview", async () => {
  const modules=await readFile(new URL("../components/ActiveModules.tsx",import.meta.url),"utf8");
  const page=await readFile(new URL("../app/page.tsx",import.meta.url),"utf8");
  assert.match(modules,/allowUatMasterPersona = false/);
  assert.match(modules,/view !== "portal" \|\| !allowUatMasterPersona/);
  assert.match(modules,/allowUatMasterPersona && !uatMasterEmployeeId/);
  assert.match(modules,/allowUatMasterPersona && uatMaster \? null/);
  assert.match(page,/view="portal" allowUatMasterPersona/);
  assert.doesNotMatch(page,/portalSection=\{employeePortalSection\}[^\n]+allowUatMasterPersona/);
});

test("stand-by is balanced by role and tier after the required schedule", async () => {
  const migration=await readFile(new URL("../supabase/migrations/20260807151000_b4_standby_fairness_v3.sql",import.meta.url),"utf8");
  assert.match(migration,/standby_candidates_for_role_day_uat_v3/);
  assert.match(migration,/history\.tier=v_tier/);
  assert.match(migration,/v_tier_counts/);
  assert.match(migration,/v_counts/);
  assert.match(migration,/issue_code='UNFILLED_SLOT'/);
  assert.match(migration,/v_tier=2 and (?:exists|v_role_day\.has_shortage)/);
});

test("merged company publication is preflighted, auditable and available on UAT", async () => {
  const [client,panel,preflightSql,severitySql,continuitySql]=await Promise.all([
    readFile(new URL("../lib/solver-v2.ts",import.meta.url),"utf8"),
    readFile(new URL("../components/RoleCompositePanel.tsx",import.meta.url),"utf8"),
    readFile(new URL("../supabase/migrations/20260809160000_b4_company_publication_preflight_and_event_ranges.sql",import.meta.url),"utf8"),
    readFile(new URL("../supabase/migrations/20260809162000_b4_company_preflight_grouped_severity.sql",import.meta.url),"utf8"),
    readFile(new URL("../supabase/migrations/20260810150416_b4_b5_published_role_composite_selection_continuity.sql",import.meta.url),"utf8"),
  ]);
  assert.match(client,/optimizer_role_composite_preflight_uat_v2/);
  assert.match(client,/optimizer_publish_role_composite_uat_v3/);
  assert.match(client,/p_warning_reason: input\.warningReason\?\.trim\(\)\s*\|\|\s*null/);
  assert.match(panel,/Przed publikacją potwierdź \{preflight\.totalGaps\} nieobsadzonych miejsc/);
  assert.match(panel,/preflight\.criticalGaps/);
  assert.match(panel,/publicationReasonInvalid = unfilledCount > 0 && publicationReasonLength < 10/);
  assert.match(panel,/setPublicationAttempted\(true\)/);
  assert.match(panel,/publicationReasonRef\.current\?\.focus\(\)/);
  assert.match(panel,/Uzasadnienie zapisze się razem z publikacją; osobny zapis nie jest potrzebny/);
  assert.match(panel,/disabled=\{busy \|\| !ready \|\| !publicationName\.trim\(\)\}/);
  assert.match(panel,/publishedScenarioGroups/);
  assert.match(panel,/completePublishedScenario/);
  assert.match(panel,/publishedRoleById/);
  assert.match(panel,/publication\?\.variantId/);
  assert.match(panel,/freshPublishedRoleById/);
  assert.match(panel,/Nie wszystkie wymagane role mają teraz opublikowany grafik/);
  assert.match(panel,/wcześniej opublikowane grafiki/);
  assert.match(panel,/Scalasz istniejące publikacje z ich konfiguracji źródłowej/);
  assert.match(preflightSql,/optimizer_publish_role_composite_uat_v3/);
  assert.match(preflightSql,/WARNING_REASON_REQUIRED/);
  assert.match(preflightSql,/optimizer_publish_role_composite_v2/);
  assert.match(severitySql,/assigned\.assigned_count = 0 critical/);
  assert.match(severitySql,/sum\(gap\.missing_count\) filter \(where gap\.critical\)/);
  assert.match(continuitySql,/PUBLISHED_ROLE_VARIANTS_REQUIRED/);
  assert.match(continuitySql,/role_schedule\.status = 'PUBLISHED'/);
  assert.match(continuitySql,/'select-v2:' \|\| v_source_run_id::text/);
  assert.match(continuitySql,/v_temporarily_deselected/);
  assert.match(continuitySql,/leaderSelectionRestored/);
});

test("merged company publication recovers category teams from durable publications", async () => {
  const [panel,migration]=await Promise.all([
    readFile(new URL("../components/RoleCompositePanel.tsx",import.meta.url),"utf8"),
    readFile(new URL("../supabase/migrations/20260815192000_uat_role_composite_category_fallback.sql",import.meta.url),"utf8"),
  ]);
  assert.match(panel,/candidates\.roles\.length > 0/);
  assert.match(panel,/publishedScenarioGroups\.length === 0/);
  assert.match(panel,/Pokazuję istniejące publikacje dla scenariusza/);
  assert.match(migration,/optimizer_role_publication_overview_uat_v2/);
  assert.match(migration,/item\.value->'scenario'->>'id'=p_scenario_id::text/);
  assert.match(migration,/'\{missingRoleIds\}','\[\]'::jsonb/);
});

test("selecting a calendar day never forces the page to jump", async () => {
  const [modules,page]=await Promise.all([
    readFile(new URL("../components/ActiveModules.tsx",import.meta.url),"utf8"),
    readFile(new URL("../app/page.tsx",import.meta.url),"utf8"),
  ]);
  assert.match(modules,/onClick=\{\(\)=>setSelectedDay\(date\)\}/);
  assert.match(modules,/onClick=\{\(\) => setSelectedDate\(date\)\}/);
  assert.doesNotMatch(modules,/employeeDayRef/);
  assert.doesNotMatch(modules,/detailRef/);
  assert.doesNotMatch(modules,/scrollIntoView\(\{behavior:"smooth",block:"start"\}\)/);
  assert.match(page,/selectedDay=\{day\} onDay=\{setDay\}/);
  assert.match(page,/manager-day-summary/);
  assert.doesNotMatch(page,/onDay=\{\(d\)=>\{setDay\(d\);setActive\("grafik"\);\}\}/);
  const combinedCalendar=modules.slice(modules.indexOf("availabilityWorkspace&&<AvailabilityCalendarDrawer embedded"),modules.indexOf("<section className=\"employee-calendar-card\""));
  assert.doesNotMatch(combinedCalendar,/onSelectDay=\{setSelectedDay\}/);
});

test("operational events and absence limits accept one audited date range", async () => {
  const [modules,migration]=await Promise.all([
    readFile(new URL("../components/ActiveModules.tsx",import.meta.url),"utf8"),
    readFile(new URL("../supabase/migrations/20260809160000_b4_company_publication_preflight_and_event_ranges.sql",import.meta.url),"utf8"),
  ]);
  assert.match(modules,/workforce_calendar_event_range_save_uat_v2/);
  assert.match(modules,/Od dnia/);
  assert.match(modules,/Do dnia/);
  assert.match(migration,/p_start_date date/);
  assert.match(migration,/p_end_date date/);
  assert.match(migration,/generate_series\(p_start_date,\s*p_end_date,\s*interval '1 day'\)/);
});

test("one browser client and synchronous month context prevent transient duplicate configuration", async () => {
  const [client,page,workspace]=await Promise.all([
    readFile(new URL("../lib/supabase/client.ts",import.meta.url),"utf8"),
    readFile(new URL("../app/page.tsx",import.meta.url),"utf8"),
    readFile(new URL("../components/SolverV2Workspace.tsx",import.meta.url),"utf8"),
  ]);
  assert.match(client,/let browserClient/);
  assert.match(client,/if \(browserClient === undefined\) browserClient = createBrowserClient/);
  assert.match(page,/\[selectedMonth,setSelectedMonth\]=useState\(\(\)=>/);
  assert.match(page,/const fromUrl=new URLSearchParams\(window\.location\.search\)\.get\("month"\)/);
  assert.match(workspace,/setLeaderEmployeeId\(candidate\.employeeId\);setLeaderFeedback\(""\);setLeaderLimitWarning\(""\)/);
});

test("company publication accepts complete disjoint category variants", async () => {
  const [migration,guard]=await Promise.all([
    readFile(new URL("../supabase/migrations/20260816065000_b4f_category_composite_publication.sql",import.meta.url),"utf8"),
    readFile(new URL("../supabase/migrations/20260816070500_b4f_category_composite_consistency_guard.sql",import.meta.url),"utf8"),
  ]);
  assert.match(migration,/optimization_snapshots_v2 run_snapshot/);
  assert.match(migration,/run_snapshot\.snapshot->'scope'->'roleIds'/);
  assert.match(migration,/ALL_DEMANDED_ROLES_REQUIRED/);
  assert.match(migration,/OVERLAPPING_CATEGORY_VARIANTS/);
  assert.match(migration,/'categoryAware',true/);
  assert.doesNotMatch(migration,/except\s+select r\.scope_role_id::text/);
  assert.match(guard,/role_composite_consistency_guard_v2/);
  assert.match(guard,/covered_role\.role_id=demanded\.role_id::text/);
  assert.match(guard,/ROLE_COMPOSITE_REQUIRES_EVERY_DEMANDED_ROLE/);
});

test("cross-section actions preserve their exact destination subtab", async () => {
  const page=await readFile(new URL("../app/page.tsx",import.meta.url),"utf8");
  assert.match(page,/router\.push\(`\$\{pathForSection\(section\)\}\?month=\$\{selectedMonth\}&view=\$\{next\}`\)/);
  assert.match(page,/const routeParams=new URLSearchParams\(window\.location\.search\)/);
  assert.match(page,/requestedSubsection&&legacySection\[requestedSubsection\]===primarySection/);
  assert.match(page,/new URLSearchParams\(\{month:selectedMonth,view:"naprawy"\}\)/);
  assert.match(page,/params\.set\("roleId",context\.roleId\)/);
  assert.match(page,/params\.set\("date",context\.date\)/);
});

test("configuration publication uses the company day and keeps failures inside the drawer", async () => {
  const [editor,migration]=await Promise.all([
    readFile(new URL("../components/MatrixV2Editor.tsx",import.meta.url),"utf8"),
    readFile(new URL("../supabase/migrations/20260811235500_uat_publication_company_timezone_fix.sql",import.meta.url),"utf8"),
  ]);
  assert.match(editor,/matrix_v2_publish_draft_uat_v2/);
  assert.match(editor,/Publikacja nie została wykonana/);
  assert.match(editor,/setPublicationError\(matrixV2ErrorMessage\(result\.error\.message\)\)/);
  assert.match(migration,/pg_catalog\.set_config\('TimeZone',v_timezone,true\)/);
  assert.match(migration,/clock_timestamp\(\) at time zone v_timezone/);
  assert.match(migration,/return public\.matrix_v2_publish_draft\(v_effective_from\)/);
});

test("duplicate shift cleanup has an explicit in-app preview and confirmation", async () => {
  const editor=await readFile(new URL("../components/MatrixV2Editor.tsx",import.meta.url),"utf8");
  assert.match(editor,/setShiftMergeDialog\(\{groups:0,duplicates:0,loading:true,error:null\}\)/);
  assert.match(editor,/Porządkowanie powtarzających się zmian/);
  assert.match(editor,/applyEquivalentShiftMerge/);
  assert.match(editor,/Połącz \{shiftMergeDialog\.groups\} grup/);
  assert.doesNotMatch(editor,/window\.confirm\(`Połączyć \$\{payload\.duplicates/);
});

test("application access is configured independently from schedule employees", async () => {
  const [editor,auth,migration]=await Promise.all([
    readFile(new URL("../components/MatrixV2Editor.tsx",import.meta.url),"utf8"),
    readFile(new URL("../components/AppAuthProvider.tsx",import.meta.url),"utf8"),
    readFile(new URL("../supabase/migrations/20260812001000_uat_application_access_and_full_reset.sql",import.meta.url),"utf8"),
  ]);
  assert.match(editor,/5\. Dostępy do aplikacji/);
  assert.match(editor,/Osoba z finansów lub administrator nie musi być pracownikiem/);
  assert.match(editor,/application_access_save_uat_v1/);
  assert.match(editor,/ROLE_MANAGER/);
  assert.match(editor,/LOCATION_MANAGER/);
  assert.match(auth,/current_user_access_v2/);
  assert.match(migration,/application_access_directory_v1/);
  assert.match(migration,/ROLE_SCOPE_REQUIRED/);
  assert.match(migration,/LOCATION_SCOPE_REQUIRED/);
});

test("full UAT reset preserves only the owner and creates an empty first-run draft", async () => {
  const [editor,migration]=await Promise.all([
    readFile(new URL("../components/MatrixV2Editor.tsx",import.meta.url),"utf8"),
    readFile(new URL("../supabase/migrations/20260812001000_uat_application_access_and_full_reset.sql",import.meta.url),"utf8"),
  ]);
  assert.match(editor,/Wyczyść UAT i rozpocznij od zera/);
  assert.match(editor,/uat_full_business_reset_v1/);
  assert.doesNotMatch(editor,/window\.prompt\(`Ta operacja usunie/);
  assert.match(migration,/ISOLATED_UAT_DESTRUCTIVE_TOOLS/);
  assert.match(migration,/delete from auth\.users u where u\.id<>v_actor/);
  assert.match(migration,/Pierwsza konfiguracja firmy/);
  assert.match(migration,/'maximumShiftsPerDay',1/);
});

test("initial UAT company setup is effective from the first day of its planning month", async () => {
  const [migration,categoryMigration,page]=await Promise.all([
    readFile(new URL("../supabase/migrations/20260813221000_uat_initial_matrix_month_boundary.sql",import.meta.url),"utf8"),
    readFile(new URL("../supabase/migrations/20260813222000_uat_role_category_month_boundary.sql",import.meta.url),"utf8"),
    readFile(new URL("../app/page.tsx",import.meta.url),"utf8"),
  ]);
  assert.match(migration,/normalize_initial_matrix_month_uat_v1/);
  assert.match(migration,/new\.version=1/);
  assert.match(migration,/date_trunc\('month',new\.effective_from\)::date/);
  assert.match(migration,/matrix_covers_planning_month_uat_v1/);
  assert.match(migration,/Published versions are immutable/);
  assert.match(migration,/optimizer_configuration_v2/);
  assert.match(migration,/optimizer_request_v2/);
  assert.match(categoryMigration,/optimizer_role_categories_uat_v1/);
  assert.match(categoryMigration,/matrix_covers_planning_month_uat_v1/);
  assert.match(page,/Nie można jeszcze utworzyć grafiku na/);
  assert.match(page,/solverConfigurationError/);
  assert.match(page,/Przejdź do kontroli konfiguracji/);
});

test("global feedback is dismissible and remains in the active workspace flow", async () => {
  const [page,styles]=await Promise.all([
    readFile(new URL("../app/page.tsx",import.meta.url),"utf8"),
    readFile(new URL("../app/globals.css",import.meta.url),"utf8"),
  ]);
  assert.match(page,/context-feedback-stack/);
  assert.match(page,/aria-live="assertive"/);
  assert.match(page,/aria-label="Zamknij komunikat"/);
  assert.match(styles,/\.context-feedback-stack\{position:relative;z-index:2/);
  assert.doesNotMatch(styles,/\.context-feedback-stack\{position:fixed/);
  assert.match(styles,/\.toast\{position:fixed;z-index:5000/);
});

test("queued optimizer runs explain the worker queue instead of looking frozen", async () => {
  const [panel,plural,client,styles,migration]=await Promise.all([
    readFile(new URL("../components/SolverV2Panel.tsx",import.meta.url),"utf8"),
    readFile(new URL("../lib/polish-plural.ts",import.meta.url),"utf8"),
    readFile(new URL("../lib/solver-v2.ts",import.meta.url),"utf8"),
    readFile(new URL("../app/uat-overhaul.css",import.meta.url),"utf8"),
    readFile(new URL("../supabase/migrations/20260813234500_uat_optimizer_queue_transparency.sql",import.meta.url),"utf8"),
  ]);
  assert.match(panel,/Zlecenie zapisano w kolejce/);
  assert.match(panel,/To zadanie jest pierwsze w kolejce/);
  assert.match(panel,/polishQueuedTaskSentence\(run\.queuePosition-1\)/);
  assert.match(plural,/Przed tym grafikiem/);
  assert.match(plural,/usesPluralVerb/);
  assert.match(plural,/lastTwo < 12 \|\| lastTwo > 14/);
  assert.match(panel,/Worker układa teraz ten grafik/);
  assert.match(client,/queuePosition\?:\s*number\s*\|\s*null/);
  assert.match(client,/waitingSeconds\?:\s*number/);
  assert.match(styles,/\.solver-v2-run-state\.queued/);
  assert.match(styles,/\.solver-v2-run-state\.running/);
  assert.match(migration,/'queuePosition'/);
  assert.match(migration,/status='QUEUED'/);
  assert.match(migration,/extract\(epoch from \(coalesce\(r\.started_at,now\(\)\)-r\.queued_at\)\)/);
});

test("duty-only shifts do not inherit unrelated role-wide duty minima", async () => {
  const migration=await readFile(new URL("../supabase/migrations/20260812194000_b4f_duty_only_shift_demand_fix.sql",import.meta.url),"utf8");
  assert.match(migration,/minimum_requirements as/);
  assert.match(migration,/and rd\.shift_obligation and rd\.shift_period=ro\.shift_period/);
  assert.match(migration,/where ro\.generic_count>0/);
  assert.match(migration,/duty-only staffing rows remain independent demand slots/);
});

test("operational event creator never loses the active company catalog", async () => {
  const [page,events]=await Promise.all([
    readFile(new URL("../app/page.tsx",import.meta.url),"utf8"),
    readFile(new URL("../components/OperationalEventsCenter.tsx",import.meta.url),"utf8"),
  ]);
  assert.match(page,/catalog=\{matrixV2\?\{/);
  assert.match(page,/categories:\(matrixV2\.roleCategories\?\?\[\]\)\.filter\(item=>item\.active\)/);
  assert.match(page,/roles:matrixV2\.roles\.filter\(item=>item\.active\)/);
  assert.match(page,/locations:matrixV2\.locations\.filter\(item=>item\.active\)/);
  assert.match(events,/workspace\?\.categories\.length\?workspace\.categories:\(catalog\?\.categories\?\?\[\]\)/);
  assert.match(events,/workspace\?\.roles\.length\?workspace\.roles:\(catalog\?\.roles\?\?\[\]\)/);
  assert.match(events,/workspace\?\.locations\.length\?workspace\.locations:\(catalog\?\.locations\?\?\[\]\)/);
  assert.match(events,/\{locations\.map\(item=>/);
  assert.match(events,/\{categories\.map\(item=>/);
});
