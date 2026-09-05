import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

test("B4F-106 uses SZAFUNEK in every primary user-facing brand surface", () => {
  for (const path of [
    "app/layout.tsx",
    "app/manifest.ts",
    "app/page.tsx",
    "app/offline/page.tsx",
    "components/AppAuthProvider.tsx",
    "components/PwaInstall.tsx",
    "lib/excel-workbook-polish.ts",
  ]) {
    const source = read(path);
    assert.match(source, /SZAFUNEK/, `${path} does not expose the current brand`);
    assert.doesNotMatch(source, /GRAFIK[ .]PRO/, `${path} still exposes the retired brand`);
  }
});

test("B4F-106 preserves stable employee and data-contract identifiers", () => {
  const instructions = read("components/MatrixV2Editor.tsx");
  const importer = read("lib/matrix-workbook-import.ts");
  assert.match(instructions, /GP-###/);
  assert.match(importer, /GRAFIK_PRO_TEMPLATE/);
});
