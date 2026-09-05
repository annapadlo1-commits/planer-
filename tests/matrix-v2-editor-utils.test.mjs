import assert from "node:assert/strict";
import test from "node:test";
import {
  activeBusinessObjectives,
  contractTypeLabel,
  localToday,
  money,
  plural,
  scenarioHasActiveStrategy,
  shortTime,
  strategyDistinguishers,
  strategyRelativeLevel,
  strategySignature,
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

function strategyWorkspace() {
  return {
    strategies: [
      { id: "high", active: true },
      { id: "medium", active: true },
      { id: "low", active: true },
      { id: "inactive", active: false },
    ],
    strategyObjectives: [
      { id: "high-cost", strategy_id: "high", metric_code: "COST", active: true, tier: 1, weight: 90, direction: "MINIMIZE", tolerance: 0, parameters: { cap: 100 }, sort_order: 2 },
      { id: "high-fair", strategy_id: "high", metric_code: "FAIRNESS", active: true, tier: 1, weight: 80, direction: "MINIMIZE", tolerance: 2, parameters: {}, sort_order: 1 },
      { id: "high-weekend", strategy_id: "high", metric_code: "WEEKEND_SPREAD", active: true, tier: 1, weight: 70, direction: "MINIMIZE", tolerance: 0, parameters: {}, sort_order: 3 },
      { id: "high-change", strategy_id: "high", metric_code: "BASELINE_CHANGES", active: true, tier: 1, weight: 60, direction: "MINIMIZE", tolerance: 0, parameters: {}, sort_order: 4 },
      { id: "high-unfilled", strategy_id: "high", metric_code: "UNFILLED", active: true, tier: 1, weight: 100, direction: "MINIMIZE", tolerance: 0, parameters: {}, sort_order: 0 },
      { id: "high-home", strategy_id: "high", metric_code: "HOME_LOCATION_VIOLATIONS", active: true, tier: 1, weight: 100, direction: "MINIMIZE", tolerance: 0, parameters: {}, sort_order: 0 },
      { id: "high-disabled", strategy_id: "high", metric_code: "DISABLED", active: false, tier: 1, weight: 100, direction: "MINIMIZE", tolerance: 0, parameters: {}, sort_order: 0 },
      { id: "medium-cost", strategy_id: "medium", metric_code: "COST", active: true, tier: 2, weight: 50, direction: "MINIMIZE", tolerance: 0, parameters: { cap: 100 }, sort_order: 0 },
      { id: "low-cost", strategy_id: "low", metric_code: "COST", active: true, tier: 3, weight: 10, direction: "MINIMIZE", tolerance: 0, parameters: { cap: 100 }, sort_order: 0 },
    ],
  };
}

test("strategy selectors filter inactive and home-location objectives without mutating input", () => {
  const data = strategyWorkspace();
  const before = structuredClone(data);
  assert.deepEqual(
    activeBusinessObjectives(data, "high").map(objective => objective.metric_code),
    ["COST", "FAIRNESS", "WEEKEND_SPREAD", "BASELINE_CHANGES", "UNFILLED"],
  );
  strategySignature(data, "high");
  strategyDistinguishers(data, "high");
  assert.deepEqual(data, before);
});

test("strategy signature is deterministic across objective order and includes parameters", () => {
  const data = strategyWorkspace();
  const signature = strategySignature(data, "high");
  const reordered = { ...data, strategyObjectives: [...data.strategyObjectives].reverse() };
  assert.equal(strategySignature(reordered, "high"), signature);
  const changedParameters = structuredClone(data);
  changedParameters.strategyObjectives[0].parameters.cap = 200;
  assert.notEqual(strategySignature(changedParameters, "high"), signature);
});

test("relative strategy levels distinguish same, high, medium and low", () => {
  const data = strategyWorkspace();
  assert.equal(strategyRelativeLevel(data, "high", "COST").className, "high");
  assert.equal(strategyRelativeLevel(data, "medium", "COST").className, "medium");
  assert.equal(strategyRelativeLevel(data, "low", "COST").className, "low");
  assert.equal(strategyRelativeLevel(data, "high", "UNKNOWN").className, "same");
});

test("strategy distinguishers exclude staffing gaps, order by weight and stop at three", () => {
  const metrics = strategyDistinguishers(strategyWorkspace(), "high")
    .map(item => item.objective.metric_code);
  assert.deepEqual(metrics, ["COST", "FAIRNESS", "WEEKEND_SPREAD"]);
});
