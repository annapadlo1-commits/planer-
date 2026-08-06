import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migrationUrl = new URL(
  "../supabase/migrations/20260806100000_uat_finance_import_and_variant_preview.sql",
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
  assert.match(solverClient, /Nieobsadzone miejsce w wymaganej obsadzie/);
  assert.match(app, /grafik-pro:selected-month/);
  assert.match(panel, /rolePublication\.variantId/);
});
