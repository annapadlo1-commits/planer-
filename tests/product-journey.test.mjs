import assert from "node:assert/strict";
import test from "node:test";
import {
  configurationJourney,
  isEmployeePersona,
  pathForSection,
  sectionFromPath,
} from "../lib/product-journey.ts";

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
