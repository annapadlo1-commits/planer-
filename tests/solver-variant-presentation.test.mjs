import assert from "node:assert/strict";
import test from "node:test";
import { formatDurationMinutes, presentSolverVariantMetrics } from "../lib/solver-variant-presentation.ts";

test("formats engine minutes as readable hours", () => {
  assert.equal(formatDurationMinutes(0), "0 min");
  assert.equal(formatDurationMinutes(780), "13 godz.");
  assert.equal(formatDurationMinutes(1410), "23 godz. 30 min");
});

test("hides obsolete and raw engine-only metrics", () => {
  const result = presentSolverVariantMetrics({
    HOME_LOCATION_VIOLATIONS: 0,
    TOTAL_COST: 100,
    UNFILLED: 0,
    LOAD_SPREAD_MINUTES: 780,
    UNKNOWN_INTERNAL_METRIC: 999,
  });
  assert.deepEqual(result.map(item => item.code), ["LOAD_SPREAD_MINUTES"]);
  assert.equal(result[0].value, "13 godz.");
  assert.match(result[0].explanation, /starszy wynik/);
});

test("explains normalized workload and missing contractual targets", () => {
  const normalized = presentSolverVariantMetrics({
    LOAD_UTILIZATION_SPREAD_BPS: 125,
    MIN_ESTIMATED_ACHIEVABLE_TARGET_UTILIZATION_BPS: 411,
    ESTIMATED_ACHIEVABLE_TARGET_UTILIZATION_SPREAD_BPS: 261,
    ESTIMATED_ACHIEVABLE_TARGET_MINUTES_TOTAL: 9_600,
    ESTIMATED_ACHIEVABLE_TARGET_METHOD_VERSION: 2,
    UNDER_TARGET_MINUTES: 120,
    LOAD_UTILIZATION_TARGET_COUNT: 4,
    NOMINAL_DEVIATION_MINUTES: 0,
    NOMINAL_TARGET_EMPLOYEE_COUNT: 0,
  });
  assert.equal(normalized.find(item => item.code === "LOAD_UTILIZATION_SPREAD_BPS")?.value, "12,5 p.p.");
  const minimumEstimate = normalized.find(item => item.code === "MIN_ESTIMATED_ACHIEVABLE_TARGET_UTILIZATION_BPS");
  const estimateSpread = normalized.find(item => item.code === "ESTIMATED_ACHIEVABLE_TARGET_UTILIZATION_SPREAD_BPS");
  assert.equal(minimumEstimate?.value, "41,1%");
  assert.match(minimumEstimate?.label ?? "", /szacowanego osiągalnego celu/i);
  assert.match(minimumEstimate?.explanation ?? "", /rzeczywista możliwa liczba godzin może być niższa/i);
  assert.equal(estimateSpread?.value, "26,1 p.p.");
  assert.match(estimateSpread?.label ?? "", /szacowanych osiągalnych celów/i);
  assert.equal(normalized.some(item => item.code === "ESTIMATED_ACHIEVABLE_TARGET_METHOD_VERSION"), false);
  assert.equal(normalized.find(item => item.code === "UNDER_TARGET_MINUTES")?.value, "2 godz.");
  assert.equal(normalized.find(item => item.code === "NOMINAL_DEVIATION_MINUTES")?.value, "Brak wymiarów");
  assert.match(normalized.find(item => item.code === "NOMINAL_DEVIATION_MINUTES")?.explanation ?? "", /zero nie oznacza/);

  const missing = presentSolverVariantMetrics({
    LOAD_UTILIZATION_SPREAD_BPS: 0,
    LOAD_UTILIZATION_TARGET_COUNT: 1,
  });
  assert.equal(missing[0].value, "Brak danych");
});
