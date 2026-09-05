import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { uiSafeColor } from "../lib/app-color-palette.ts";

test("legacy purple chrome is absent from application source", () => {
  const script = fileURLToPath(new URL("../scripts/replace-legacy-purple-palette.mjs", import.meta.url));
  const cwd = fileURLToPath(new URL("..", import.meta.url));
  const output = execFileSync(process.execPath, [script], { cwd, encoding: "utf8" });
  assert.match(output, /Brak literalnych fioletowych/);
});

test("legacy configured colors cannot reintroduce purple chrome", () => {
  assert.equal(uiSafeColor("#7257D8"), "#55665A");
  assert.equal(uiSafeColor("#C96F54"), "#C96F54");
  assert.equal(uiSafeColor("not-a-color", "#879681"), "#879681");
});
