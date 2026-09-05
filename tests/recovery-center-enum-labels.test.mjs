import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");

test("RecoveryCenter localizes detail statuses and risks without leaking unknown enum codes", async () => {
  const source = await read("components/RecoveryCenter.tsx");

  for (const label of [
    "Wersja robocza", "Aktywny", "Plan naprawy przygotowany",
    "Oferty wysłane", "Zastosowany", "Zakończony", "Anulowany",
    "Niskie ryzyko", "Średnie ryzyko", "Wysokie ryzyko", "Krytyczne ryzyko",
    "Proponowana", "Zatwierdzona", "Odrzucona", "Zastąpiona",
  ]) {
    assert.ok(source.includes(label), `Brak polskiej etykiety: ${label}`);
  }

  assert.match(
    source,
    /enumLabel\(incidentStatusLabels, detail\.status, "Status wymaga sprawdzenia"\)/,
  );
  assert.match(
    source,
    /enumLabel\(actionRiskLabels, action\.risk, "Ryzyko wymaga sprawdzenia"\)/,
  );
  assert.match(
    source,
    /enumLabel\(incidentRateStatusLabels, rate\.status, "Status stawki wymaga sprawdzenia"\)/,
  );
  assert.match(source, /return labels\[code\] \?\? fallback/);
  assert.match(source, /return actionRiskLabels\[code\] \? code\.toLowerCase\(\) : "unknown"/);

  assert.doesNotMatch(source, /• \{detail\.status\}/);
  assert.doesNotMatch(source, />\{action\.risk\}<\/b>/);
  assert.doesNotMatch(source, /• \{rate\.status\}<\/small>/);
});
