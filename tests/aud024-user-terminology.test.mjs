import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const panel = await readFile(new URL(
  "../components/SolverV2Panel.tsx",
  import.meta.url,
), "utf8");

test("AUD-024 uses product language in visible solver provenance", () => {
  assert.doesNotMatch(panel, /`Matrix v\$\{/u);
  assert.doesNotMatch(panel, />Stamp wersji przebiegu</u);
  assert.match(panel, /`konfiguracja firmy v\$\{/u);
  assert.match(panel, />Identyfikatory wersji przebiegu</u);
});
