import assert from "node:assert/strict";
import test from "node:test";
import {
  configurationBlockerAction,
  configurationJourney,
  isEmployeePersona,
  pathForSection,
  sectionFromPath,
} from "../lib/product-journey.ts";
import { readFile } from "node:fs/promises";

function workspace(overrides = {}) {
  return {
    matrixVersion: { id: "matrix", version: 1, name: "Test", status: "DRAFT", schema_version: 2, settings: { timezone: "Europe/Warsaw", currency: "PLN" } },
    month: "2026-08-01", editable: true, financeVisible: false,
    locations: [{ id: "location", code: "L", name: "Lokal", sort_order: 0, active: true, timezone: "Europe/Warsaw" }],
    roles: [{ id: "role", code: "R", name: "Rola", sort_order: 0, active: true }],
    duties: [{ id: "duty", code: "D", name: "Kompetencja", sort_order: 0, active: true }],
    roleDuties: [{ id: "rd", role_id: "role", duty_id: "duty", assignment_mode: "OPTIONAL", minimum_count: 0, active: true }],
    shiftTemplates: [{ id: "shift", code: "S", name: "Zmiana", sort_order: 0, active: true, location_id: "location", starts_at: "10:00", ends_at: "18:00", ends_next_day: false, day_mask: [1], shift_period: "MORNING" }],
    scenarios: [{ id: "scenario", code: "BASE", name: "Bazowy", sort_order: 0, active: true, is_default: true }],
    staffingRules: [{ id: "rule", scenario_id: "scenario", shift_template_id: "shift", role_id: "role", operation: "SET", count_value: 1, active: true }],
    strategies: [{ id: "strategy", code: "BALANCED", name: "Zrównoważony", sort_order: 0, active: true, solver_code: "CP_SAT" }],
    scenarioStrategies: [{ id: "ss", scenario_id: "scenario", strategy_id: "strategy", sort_order: 0, active: true }],
    employees: [{ id: "employee", employeeNo: "GP-001", firstName: "A", lastName: "B", active: true, nominalMonthlyMinutes: 0, maximumMonthlyMinutes: 0, maximumWeeklyMinutes: 0, maximumConsecutiveDays: 1, onlyMorning: false, onlyEvening: false, noWeekends: false }],
    employeeRoles: [{ id: "er", employee_id: "employee", role_id: "role", is_primary: true, can_lead: false, active: true }],
    employeeLocations: [{ id: "el", employee_id: "employee", location_id: "location", standard_allowed: true, overtime_allowed: false, home_location: false, active: true }],
    employeeDuties: [], timeConstraints: [], payRules: [], payRuleRoles: [], payRuleDuties: [], payRuleLocations: [], payRuleShifts: [], scenarioPayRuleOverrides: [], scenarioBudgets: [], employeePayRates: [], strategyObjectives: [],
    ...overrides,
  };
}

test("navigation selects a dedicated shell for an employee", () => {
  assert.equal(isEmployeePersona([{ app_role: "EMPLOYEE" }]), true);
  assert.equal(isEmployeePersona([{ app_role: "EMPLOYEE" }, { app_role: "OWNER" }]), false);
  assert.equal(sectionFromPath("/availability", true), "availability");
  assert.equal(sectionFromPath("/settings", true), "my-schedule");
  assert.equal(sectionFromPath("/unknown", false), "start");
  assert.equal(pathForSection("schedule"), "/schedule");
});

test("configuration journey recommends the first real data gap", () => {
  const data = workspace({ staffingRules: [] });
  const result = configurationJourney(data, "2026-08", null);
  assert.equal(result.next?.key, "shifts");
  assert.equal(result.steps.find(step => step.key === "employees")?.state, "complete");
  assert.equal(result.steps.find(step => step.key === "readiness")?.state, "blocked");
  assert.equal(result.ready, false);
});

test("server readiness completes the guided setup", () => {
  const data = workspace();
  const result = configurationJourney(data, "2026-08", { ready: true, blockers: [], effectiveFrom: "2026-08-05", scheduleMonth: "2026-08-01", matrixVersionId: "matrix" });
  assert.equal(result.completed, 6);
  assert.equal(result.percent, 100);
  assert.equal(result.next, null);
  assert.equal(result.ready, true);
});

test("server blockers keep readiness as the only current step", () => {
  const data = workspace();
  const result = configurationJourney(data, "2026-08", { ready: false, blockers: [{ code: "MISSING_PAY_RATE", message: "Brak stawki" }], effectiveFrom: "2026-08-05", scheduleMonth: "2026-08-01", matrixVersionId: "matrix" });
  assert.equal(result.next?.key, "readiness");
  assert.equal(result.steps.find(step => step.key === "readiness")?.state, "current");
  assert.equal(result.blockers.length, 1);
});

test("roles do not require optional duties to complete setup", () => {
  const data = workspace({ duties: [], roleDuties: [] });
  const result = configurationJourney(data, "2026-08", { ready: true, blockers: [], effectiveFrom: "2026-08-05", scheduleMonth: "2026-08-01", matrixVersionId: "matrix" });
  assert.equal(result.steps.find(step => step.key === "roles")?.state, "complete");
  assert.equal(result.ready, true);
});

test("missing pay rate blocker opens the exact employee and required period", () => {
  const data = workspace();
  const action = configurationBlockerAction({ code: "MISSING_PAY_RATE", message: "Brak stawki", employeeId: "employee", employeeName: "A B", requiredFrom: "2026-08-01", requiredTo: "2026-08-31" }, data, "2026-08");
  assert.equal(action.step, "employees");
  assert.equal(action.focus?.employeeId, "employee");
  assert.equal(action.focus?.targetId, "matrix-v2-rate-employee");
  assert.match(action.message, /01\.08\.2026–31\.08\.2026/);
  assert.equal(action.actionLabel, "Uzupełnij stawkę");
});

test("schedule opens with role plans before company merge", async () => {
  const appSource = await readFile(new URL("../app/page.tsx", import.meta.url), "utf8");
  assert.match(appSource, /schedule:\"zespoly\"/);
  assert.match(appSource, /1\. Grafiki ról/);
  assert.match(appSource, /2\. Scal i porównaj grafik firmy/);
  assert.ok(appSource.indexOf("1. Grafiki ról") < appSource.indexOf("2. Scal i porównaj grafik firmy"));
});

test("employee search input is constrained inside its grid cell", async () => {
  const cssSource = await readFile(new URL("../app/matrix-v2.css", import.meta.url), "utf8");
  assert.match(cssSource, /\.workforce-picker>\*\{min-width:0\}/);
  assert.match(cssSource, /\.workforce-employee-search input\{width:100%;min-width:0;max-width:100%;box-sizing:border-box\}/);
});
