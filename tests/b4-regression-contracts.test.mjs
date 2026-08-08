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
  const sql = await readFile(migrationUrl, "utf8");
  const repairedFunction = sql.slice(sql.lastIndexOf(
    "create or replace function solver_private.generate_standby_for_variant_uat_v2",
  ));
  assert.match(repairedFunction, /standbyTiersPerRoleDay/);
  assert.match(repairedFunction, /if v_employee is null then\s+exit;/);
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

test("new solver balances contract utilization instead of raw minutes", async () => {
  const source = await readFile(new URL(
    "../solver/src/grafik_solver/cp_sat_engine.py",
    import.meta.url,
  ), "utf8");
  assert.match(source, /LOAD_SPREAD_MINUTES": "LOAD_UTILIZATION_SPREAD_BPS/);
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
  assert.match(editor, /importIssueMessage\(issue\.message\)/);
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
  assert.match(solverClient, /STATUS=FEASIBLE/);
  assert.match(solverClient, /RUN_ALREADY_CLAIMED/);
  assert.doesNotMatch(solverClient, /normalized\.includes\("CONFLICT"\)/);
  assert.match(panel, /run\.failureMessage && run\.status!=="FAILED"/);
  assert.match(panel, /run\.failureMessage\?solverErrorMessage\(run\.failureMessage\)/);
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

test("role cards hide engine jargon and optional operational tools stay collapsed", async () => {
  const modules=await readFile(new URL("../components/ActiveModules.tsx",import.meta.url),"utf8");
  assert.match(modules,/role-plan-cards compact/);
  assert.match(modules,/roleCardStyle\(role\.id\)/);
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
  assert.match(modules,/roleCardStyle\(assignment\.roleId\)/);
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

test("team catalog uses the same explicit target and hard limit semantics as the solver", async () => {
  const page=await readFile(new URL("../app/page.tsx",import.meta.url),"utf8");
  assert.match(page,/Cel godzinowy/);
  assert.match(page,/Twardy limit miesięczny/);
  assert.match(page,/Te same dane czyta generator, publikacja, portal oraz pełny eksport firmy/);
  assert.doesNotMatch(page,/Uzgodniony pułap \(informacyjny\)/);
  assert.doesNotMatch(page,/nie blokuje silnika/);
});

test("calendar comparison can preselect the compared employee for a server-validated replacement", async () => {
  const workspace=await readFile(new URL("../components/SolverV2Workspace.tsx",import.meta.url),"utf8");
  assert.match(workspace,/preferredEmployeeId/);
  assert.match(workspace,/context\.candidates\.some\(candidate=>candidate\.employeeId===preferredEmployeeId&&candidate\.suggestionEligible\)/);
  assert.match(workspace,/Sprawdź, czy \{primary\.length\?comparisonEmployee\.firstName:employeeDetailShortName\} może przejąć tę zmianę/);
  assert.match(workspace,/rolę, lokal i obowiązek/);
  assert.match(workspace,/przejmie obowiązek/);
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
  assert.match(workspace,/setComparisonAvailability\(\[\]\)/);
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
  assert.match(client,/optimizer_leader_assignment_context_uat_v2/);
  assert.match(client,/p_duty_transfer_assignment_id/);
  assert.match(migration,/optimizer_employee_availability_month_uat_v1/);
  assert.match(migration,/'date',day_value\.day_date::date/);
  assert.match(migration,/dutyTransferAssignmentId/);
  assert.match(migration,/DUTY_TRANSFER_REQUIRED/);
});

test("employee portal uses one combined schedule and availability calendar", async () => {
  const modules=await readFile(new URL("../components/ActiveModules.tsx",import.meta.url),"utf8");
  const css=await readFile(new URL("../app/product-journey.css",import.meta.url),"utf8");
  assert.match(modules,/Grafik i dostępność w jednym kalendarzu/);
  assert.match(modules,/employee-combined-calendar/);
  assert.match(modules,/publishedAssignments\.length/);
  assert.match(css,/\.employee-calendar-card\{display:none\}/);
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
