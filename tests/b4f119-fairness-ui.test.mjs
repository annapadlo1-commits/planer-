import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";


test("B4F-119 fairness-first copy now comes from the published Matrix contract", async () => {
  const [panel, contract] = await Promise.all([
    readFile(new URL("../components/SolverV2Panel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../lib/solver-strategy-contract.ts", import.meta.url), "utf8"),
  ]);
  assert.doesNotMatch(panel, /PREFERENCES_FAIRNESS_DESCRIPTION/);
  assert.match(contract, /Najpierw sprawiedliwie rozdziela pracę względem celów i możliwości pracowników/);
  assert.match(contract, /Następnie wśród podobnie sprawiedliwych grafików/);
  assert.match(panel, /strategyDescription\(variant\.strategy\)/);
  assert.match(panel, /strategy\.description\?\.trim\(\)/);
  assert.match(panel, /MANDATORY_PRODUCT_GUARDS_LABEL/);
});
