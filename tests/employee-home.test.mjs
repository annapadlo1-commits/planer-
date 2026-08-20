import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import ts from "typescript";

async function loadModule() {
  const source = await readFile(new URL("../lib/employee-home.ts", import.meta.url), "utf8");
  const output = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.ES2022, target: ts.ScriptTarget.ES2022 },
  }).outputText;
  return import(`data:text/javascript;base64,${Buffer.from(output).toString("base64")}`);
}

test("employee home finds the live shift and summarizes only the current week", async () => {
  const { employeeHomeSnapshot } = await loadModule();
  const snapshot = employeeHomeSnapshot({
    timezone: "Europe/Warsaw",
    employeeId: "employee-1",
    now: new Date("2026-08-20T08:30:00Z"),
    assignments: [
      { id: "live", date: "2026-08-20", startsAt: "2026-08-20T08:00:00Z", endsAt: "2026-08-20T16:00:00Z" },
      { id: "weekend", date: "2026-08-22", startsAt: "2026-08-22T08:00:00Z", endsAt: "2026-08-22T12:00:00Z" },
      { id: "later", date: "2026-08-31", startsAt: "2026-08-31T08:00:00Z", endsAt: "2026-08-31T16:00:00Z" },
    ],
    swaps: [],
  });
  assert.equal(snapshot.today, "2026-08-20");
  assert.equal(snapshot.nextState, "NOW");
  assert.equal(snapshot.currentAssignmentId, "live");
  assert.equal(snapshot.nextAssignmentId, "live");
  assert.equal(snapshot.weekShiftCount, 2);
  assert.equal(snapshot.weekMinutes, 720);
  assert.equal(snapshot.monthMinutes, 1200);
  assert.equal(snapshot.weekendShiftCount, 1);
});

test("employee home distinguishes direct swap actions, open shifts and leader review", async () => {
  const { employeeHomeSnapshot } = await loadModule();
  const snapshot = employeeHomeSnapshot({
    timezone: "Europe/Warsaw",
    employeeId: "employee-1",
    now: new Date("2026-08-20T08:30:00Z"),
    assignments: [],
    swaps: [
      { status: "OPEN", targetEmployeeId: "employee-1", eligible: true, isMine: false },
      { status: "OPEN", targetEmployeeId: null, eligible: true, isMine: false },
      { status: "OPEN", targetEmployeeId: null, eligible: false, isMine: false },
      { status: "EMPLOYEE_ACCEPTED", acceptedByEmployeeId: "employee-1", eligible: true, isMine: false },
      { status: "EMPLOYEE_ACCEPTED", acceptedByEmployeeId: "employee-2", eligible: true, isMine: false },
    ],
  });
  assert.equal(snapshot.nextState, "NONE");
  assert.equal(snapshot.targetedSwapCount, 1);
  assert.equal(snapshot.openShiftCount, 2);
  assert.equal(snapshot.waitingLeaderCount, 1);
});

test("timekeeping on Home is an inert placeholder and never calls the retired writer", async () => {
  const source = await readFile(new URL("../components/ActiveModules.tsx", import.meta.url), "utf8");
  assert.match(source, /className="employee-timeclock-placeholder"/);
  assert.match(source, /Rozpocznij pracę/);
  assert.match(source, /Zakończ pracę/);
  assert.match(source, /QR, lokalizacja albo zwykłe potwierdzenie/);
  assert.match(source, /employee-timeclock-actions"><button type="button" disabled/);
  assert.doesNotMatch(source, /attendance_clock/);
});
