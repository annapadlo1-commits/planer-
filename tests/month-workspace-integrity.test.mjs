import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  beginMonthWorkspaceLoad,
  canStartMonthWorkspaceLoad,
  canUseMonthWorkspace,
  completeMonthWorkspaceLoad,
  createMonthWorkspaceGate,
  failMonthWorkspaceLoad,
  selectMonthWorkspace,
} from "../lib/month-workspace-state.ts";

const page = await readFile(new URL("../app/page.tsx", import.meta.url), "utf8");

test("month workspace is rendered only for its exact loadedMonth", () => {
  assert.match(page, /loadedMonth\s*===\s*selectedMonthDate/u);
});

test("a failed month read clears every month-bound state and blocks mutations", () => {
  assert.match(page, /clearMonthWorkspace/u);
  assert.match(page, /workspaceCurrent/u);
  assert.match(page, /disabled=\{!workspaceCurrent/u);
});

test("month loading uses an explicit latest-request gate", () => {
  assert.match(page, /isMonthWorkspaceRequestCurrent/u);
  assert.match(page, /completeMonthWorkspaceLoad/u);
  assert.match(page, /failMonthWorkspaceLoad/u);
});

test("a committed month selection blocks stale callbacks from restarting the prior month", () => {
  assert.doesNotMatch(
    page,
    /monthWorkspaceGateRef=useRef\([^;]+;\s*selectMonthWorkspace\(monthWorkspaceGateRef\.current,selectedMonthDate\)/u,
  );
  assert.match(page, /canStartMonthWorkspaceLoad\(monthWorkspaceGateRef\.current,requestedMonth\)/u);
  assert.match(page, /reloadCurrentMonth/u);
  assert.equal(page.match(/await reloadCurrentMonth\(\)/gu)?.length, 3);
  assert.doesNotMatch(page, /onPublished=\{async\(\)=>\{await load\(\)/u);
});

test("configuration and complete_workspace failures both fail closed", () => {
  assert.match(page, /solverConfigurationResult\.error\|\|!solverConfigurationResult\.configuration/u);
  assert.match(page, /if\(completeResult\.error\)\{/u);
  assert.match(page, /failMonthWorkspaceLoad\(monthWorkspaceGateRef\.current,request\)/u);
});

test("failure copy identifies the month, repair location and retry action", () => {
  assert.match(page, /Nie udało się wczytać danych dla/u);
  assert.match(page, /Konfiguracja firmy → Kontrola gotowości/u);
  assert.match(page, /Ponów odczyt/u);
});

test("A success followed by B error removes A and blocks every mutation", () => {
  const gate = createMonthWorkspaceGate("2026-08-01");
  const requestA = beginMonthWorkspaceLoad(gate, "2026-08-01");
  assert.equal(completeMonthWorkspaceLoad(gate, requestA), true);
  assert.equal(canUseMonthWorkspace(gate, "2026-08-01"), true);

  const requestB = beginMonthWorkspaceLoad(gate, "2026-09-01");
  assert.equal(canUseMonthWorkspace(gate, "2026-09-01"), false);
  assert.equal(gate.loadedMonth, null);
  assert.equal(failMonthWorkspaceLoad(gate, requestB), true);
  assert.equal(canUseMonthWorkspace(gate, "2026-08-01"), false);
  assert.equal(canUseMonthWorkspace(gate, "2026-09-01"), false);
});

test("B retry restores only B after A success and B error", () => {
  const gate = createMonthWorkspaceGate("2026-08-01");
  completeMonthWorkspaceLoad(gate, beginMonthWorkspaceLoad(gate, "2026-08-01"));
  failMonthWorkspaceLoad(gate, beginMonthWorkspaceLoad(gate, "2026-09-01"));
  const retryB = beginMonthWorkspaceLoad(gate, "2026-09-01");
  assert.equal(completeMonthWorkspaceLoad(gate, retryB), true);
  assert.equal(canUseMonthWorkspace(gate, "2026-09-01"), true);
  assert.equal(canUseMonthWorkspace(gate, "2026-08-01"), false);
});

test("A and B request races are latest-month-wins in both response orders", () => {
  for (const order of ["A_FIRST", "B_FIRST"]) {
    const gate = createMonthWorkspaceGate("2026-08-01");
    const requestA = beginMonthWorkspaceLoad(gate, "2026-08-01");
    const requestB = beginMonthWorkspaceLoad(gate, "2026-09-01");
    if (order === "A_FIRST") {
      assert.equal(completeMonthWorkspaceLoad(gate, requestA), false);
      assert.equal(completeMonthWorkspaceLoad(gate, requestB), true);
    } else {
      assert.equal(completeMonthWorkspaceLoad(gate, requestB), true);
      assert.equal(completeMonthWorkspaceLoad(gate, requestA), false);
    }
    assert.equal(gate.loadedMonth, "2026-09-01");
  }
});

test("changing month during a request invalidates its late response", () => {
  const gate = createMonthWorkspaceGate("2026-08-01");
  const requestA = beginMonthWorkspaceLoad(gate, "2026-08-01");
  selectMonthWorkspace(gate, "2026-09-01");
  assert.equal(completeMonthWorkspaceLoad(gate, requestA), false);
  assert.equal(gate.loadedMonth, null);
});

test("a stale callback cannot restart a load for the previously selected month", () => {
  const gate = createMonthWorkspaceGate("2026-08-01");
  selectMonthWorkspace(gate, "2026-09-01");
  assert.equal(canStartMonthWorkspaceLoad(gate, "2026-08-01"), false);
  assert.equal(canStartMonthWorkspaceLoad(gate, "2026-09-01"), true);
});

test("a newly selected month never exposes the prior month even briefly", () => {
  const gate = createMonthWorkspaceGate("2026-08-01");
  completeMonthWorkspaceLoad(gate, beginMonthWorkspaceLoad(gate, "2026-08-01"));
  selectMonthWorkspace(gate, "2026-09-01");
  assert.equal(gate.loadedMonth, null);
  assert.equal(canUseMonthWorkspace(gate, "2026-09-01"), false);
});
