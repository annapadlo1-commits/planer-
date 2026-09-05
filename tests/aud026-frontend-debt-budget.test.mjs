import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const budgets = new Map([
  ["components/MatrixV2Editor.tsx", 2_738],
  ["components/ActiveModules.tsx", 1_262],
  ["components/SolverV2Workspace.tsx", 800],
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

test("Matrix editor formatting and strategy selectors stay outside the React monolith", async () => {
  const editor = await source("components/MatrixV2Editor.tsx");
  const utilities = await source("lib/matrix-v2-editor-utils.ts");
  assert.match(editor, /from "@\/lib\/matrix-v2-editor-utils"/u);
  assert.doesNotMatch(editor, /function scenarioHasActiveStrategy/u);
  assert.match(utilities, /export function scenarioHasActiveStrategy/u);
  assert.match(utilities, /depth > 32 \|\| visited\.has\(current\.id\)/u);
  for (const helper of [
    "activeBusinessObjectives",
    "strategySignature",
    "strategyRelativeLevel",
    "strategyDistinguishers",
  ]) {
    assert.doesNotMatch(editor, new RegExp(`function ${helper}`, "u"));
    assert.match(utilities, new RegExp(`export function ${helper}`, "u"));
  }
});

test("Solver workspace presentation helpers stay outside the React monolith", async () => {
  const workspace = await source("components/SolverV2Workspace.tsx");
  const presentation = await source("lib/solver-v2-workspace-presentation.ts");
  assert.match(workspace, /from "@\/lib\/solver-v2-workspace-presentation"/u);
  assert.match(workspace, /export \{ stablePaletteIndex \} from "@\/lib\/solver-v2-workspace-presentation"/u);
  assert.doesNotMatch(workspace, /function stablePaletteIndex/u);
  assert.doesNotMatch(workspace, /function monthWeeks/u);
  assert.doesNotMatch(workspace, /const hardReasonLabels/u);
  assert.match(presentation, /export function stablePaletteIndex/u);
  assert.match(presentation, /export function monthWeeks/u);
  assert.match(presentation, /export function workloadReason/u);
});
