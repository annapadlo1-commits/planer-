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

test("employee home previews at most three unique coworkers from the exact category and day", async () => {
  const { employeeCategoryCoworkerPreview } = await loadModule();
  const preview = employeeCategoryCoworkerPreview({
    employeeId: "employee-self",
    assignment: { id: "own", date: "2026-08-22", startsAt: "2026-08-22T16:00:00Z", endsAt: "2026-08-23T02:00:00Z" },
    assignments: [
      { id: "own", employeeId: "employee-self", employeeName: "Zofia", categoryId: "bar", categoryName: "Bar", date: "2026-08-22", startsAt: "2026-08-22T16:00:00Z", endsAt: "2026-08-23T02:00:00Z" },
      { id: "a", employeeId: "a", employeeName: "Aleksandra", categoryId: "bar", categoryName: "Bar", date: "2026-08-22", startsAt: "2026-08-22T08:00:00Z", endsAt: "2026-08-22T16:00:00Z" },
      { id: "b", employeeId: "b", employeeName: "Beata", categoryId: "bar", categoryName: "Bar", date: "2026-08-22", startsAt: "2026-08-22T10:00:00Z", endsAt: "2026-08-22T18:00:00Z" },
      { id: "b-2", employeeId: "b", employeeName: "Beata", categoryId: "bar", categoryName: "Bar", date: "2026-08-22", startsAt: "2026-08-22T18:00:00Z", endsAt: "2026-08-22T20:00:00Z" },
      { id: "c", employeeId: "c", employeeName: "Celina", categoryId: "bar", categoryName: "Bar", date: "2026-08-22", startsAt: "2026-08-22T12:00:00Z", endsAt: "2026-08-22T20:00:00Z" },
      { id: "d", employeeId: "d", employeeName: "Dorota", categoryId: "bar", categoryName: "Bar", date: "2026-08-22", startsAt: "2026-08-22T14:00:00Z", endsAt: "2026-08-22T22:00:00Z" },
      { id: "host", employeeId: "host", employeeName: "Helena", categoryId: "sala", categoryName: "Sala", date: "2026-08-22", startsAt: "2026-08-22T09:00:00Z", endsAt: "2026-08-22T17:00:00Z" },
      { id: "tomorrow", employeeId: "tomorrow", employeeName: "Iga", categoryId: "bar", categoryName: "Bar", date: "2026-08-23", startsAt: "2026-08-23T09:00:00Z", endsAt: "2026-08-23T17:00:00Z" },
    ],
  });
  assert.equal(preview.categoryName, "Bar");
  assert.equal(preview.total, 4);
  assert.deepEqual(preview.people.map(person => person.name), ["Aleksandra", "Beata", "Celina"]);
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
