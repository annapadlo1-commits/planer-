import assert from "node:assert/strict";
import test from "node:test";
import { employeeMatchesWorkforceQuery, workforceProfileReadiness } from "../lib/workforce-profile.ts";

function workspace(overrides = {}) {
  return {
    financeVisible: true,
    roles: [{ id: "role", name: "Kelner" }],
    locations: [{ id: "location", name: "Krucza" }],
    duties: [{ id: "duty", name: "Zamknięcie zmiany" }],
    employeeRoles: [{ id: "er", employee_id: "employee", role_id: "role", active: true, is_primary: true }],
    employeeLocations: [{ id: "el", employee_id: "employee", location_id: "location", active: true, standard_allowed: true }],
    employeeDuties: [{ id: "ed", employee_id: "employee", duty_id: "duty", active: true }],
    employeePayRates: [{ id: "rate", employee_id: "employee", valid_from: "2026-08-01", valid_to: "2026-08-31", active: true }],
    ...overrides,
  };
}

function employee(overrides = {}) {
  return {
    id: "employee", employeeNo: "GP-001", firstName: "Anna", lastName: "Wiśniewska", email: "anna@example.test",
    active: true, contractType: "ZLECENIE", workTimePolicy: "CONTRACT_DEFAULT", employmentStart: "2026-01-01", employmentEnd: null,
    nominalMonthlyMinutes: 0, maximumMonthlyMinutes: 0, maximumWeeklyMinutes: 0, maximumConsecutiveDays: 31,
    ...overrides,
  };
}

test("combined workforce search matches every token across different fields", () => {
  const data = workspace();
  const person = employee();
  assert.equal(employeeMatchesWorkforceQuery(data, person, "Anna Krucza zamkniecie"), true);
  assert.equal(employeeMatchesWorkforceQuery(data, person, "Anna Pawilony"), false);
});

test("profile is complete when role, location and the whole monthly rate period are covered", () => {
  const result = workforceProfileReadiness(workspace(), employee(), "2026-08");
  assert.equal(result.complete, true);
  assert.equal(result.completed, result.total);
});

test("a gap between rates is shown as an incomplete monthly rate", () => {
  const data = workspace({ employeePayRates: [
    { id: "r1", employee_id: "employee", valid_from: "2026-08-01", valid_to: "2026-08-10", active: true },
    { id: "r2", employee_id: "employee", valid_from: "2026-08-12", valid_to: "2026-08-31", active: true },
  ] });
  const result = workforceProfileReadiness(data, employee(), "2026-08");
  assert.equal(result.complete, false);
  assert.equal(result.checks.find(check => check.key === "rate")?.complete, false);
});

test("additional duties are optional and do not reduce profile completion", () => {
  const data = workspace({ employeeDuties: [] });
  assert.equal(workforceProfileReadiness(data, employee(), "2026-08").complete, true);
});
