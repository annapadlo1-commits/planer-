import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const budgets = new Map([
  ["components/MatrixV2Editor.tsx", 2_842],
  ["components/ActiveModules.tsx", 1_262],
  ["components/SolverV2Workspace.tsx", 959],
  ["app/page.tsx", 746],
  ["app/brand-streetart.css", 3_579],
]);

async function source(relativePath) {
  return readFile(new URL(`../${relativePath}`, import.meta.url), "utf8");
}

test("known frontend monoliths cannot grow without an explicit debt-budget review", async () => {
  for (const [relativePath, maximumLines] of budgets) {
    const text = await source(relativePath);
    const lines = text.replace(/\r\n/gu, "\n").split("\n").length - (text.endsWith("\n") ? 1 : 0);
    assert.ok(
      lines <= maximumLines,
      `${relativePath} grew to ${lines} lines (budget ${maximumLines}); extract a focused module instead`,
    );
  }
});

test("the legacy global important-declaration debt cannot increase", async () => {
  const css = await source("app/brand-streetart.css");
  const importantDeclarations = css.match(/!important\b/gu) ?? [];
  assert.ok(
    importantDeclarations.length <= 2_114,
    `brand-streetart.css has ${importantDeclarations.length} !important declarations; scope or remove the new rule`,
  );
});
