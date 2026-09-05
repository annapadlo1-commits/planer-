import test from "node:test";
import assert from "node:assert/strict";

import { hydrateMonthlyBudgetLines } from "../lib/monthly-budgets.ts";

test("a saved category budget is immediately rehydrated against the current configuration rows", () => {
  const lines = [{
    scopeType: "CATEGORY",
    categoryLogicalId: "category-logical",
    categoryId: null,
    metricType: "COST",
    enforcement: "TARGET",
    limitValue: 115000,
  }];
  const matrix = {
    locations: [],
    roles: [],
    roleCategories: [{ id: "category-v6-row", logicalId: "category-logical" }],
  };

  assert.equal(hydrateMonthlyBudgetLines(lines, matrix)[0].categoryId, "category-v6-row");
});
