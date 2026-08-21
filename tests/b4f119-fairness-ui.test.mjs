import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";


test("B4F-119 explains fairness before preferences for existing Matrix versions", async () => {
  const panel = await readFile(
    new URL("../components/SolverV2Panel.tsx", import.meta.url),
    "utf8",
  );
  assert.match(panel, /PREFERENCES_FAIRNESS_DESCRIPTION/);
  assert.match(panel, /najpierw maksymalizuje realizację celu najsłabiej obsłużonej osoby/);
  assert.match(panel, /Preferencje rozstrzygają dopiero między podobnie sprawiedliwymi rozwiązaniami/);
  assert.match(panel, /strategyDescription\(variant\.strategy\)/);
  assert.doesNotMatch(panel, /<p>\{variant\.strategy\.description\}<\/p>/);
});
