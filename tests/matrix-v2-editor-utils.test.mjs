import assert from "node:assert/strict";
import test from "node:test";
import {
  contractTypeLabel,
  localToday,
  money,
  plural,
  scenarioHasActiveStrategy,
  shortTime,
} from "../lib/matrix-v2-editor-utils.ts";

test("Matrix editor pure utilities preserve labels and Polish presentation", () => {
  assert.equal(shortTime("08:30:00"), "08:30");
  assert.equal(shortTime(null), "—");
  assert.match(money(12_345, "PLN"), /123,45/u);
  assert.equal(plural(1, "osoba", "osoby", "osób"), "1 osoba");
  assert.equal(plural(3, "osoba", "osoby", "osób"), "3 osoby");
  assert.equal(plural(5, "osoba", "osoby", "osób"), "5 osób");
  assert.equal(contractTypeLabel("UMOWA_O_PRACE"), "Umowa o pracę");
  assert.equal(contractTypeLabel("UNKNOWN"), "Inna");
  assert.equal(localToday("Europe/Warsaw", new Date("2026-01-31T23:30:00Z")), "2026-02-01");
});

test("scenario strategy inheritance is nearest-first, cycle-safe and activation-aware", () => {
  const scenarios = [
    { id: "base", parent_scenario_id: null },
    { id: "child", parent_scenario_id: "base" },
  ];
  const active = new Set(["balanced"]);
  assert.equal(scenarioHasActiveStrategy("child", scenarios, [
    { scenario_id: "base", strategy_id: "balanced", active: true },
  ], active), true);
  assert.equal(scenarioHasActiveStrategy("child", scenarios, [
    { scenario_id: "child", strategy_id: "balanced", active: false },
    { scenario_id: "base", strategy_id: "balanced", active: true },
  ], active), false);
  assert.equal(scenarioHasActiveStrategy("missing", scenarios, [], active), false);
  assert.equal(scenarioHasActiveStrategy("child", [
    { id: "child", parent_scenario_id: "loop" },
    { id: "loop", parent_scenario_id: "child" },
  ], [], active), false);
});
