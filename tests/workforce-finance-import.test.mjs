import assert from "node:assert/strict";
import test from "node:test";
import { normalizeWorkforceFinanceRows } from "../lib/workforce-finance-import.ts";

test("normalizes Polish finance template rows without changing employee identity", () => {
  const result = normalizeWorkforceFinanceRows([{
    "ID stawki": "rate-1",
    "Numer pracownika": "GP-007",
    "Obowiązuje od": "01.09.2026",
    "Obowiązuje do": "30-09-2026",
    "Stawka godzinowa": "37,50",
    Waluta: "pln",
    "Rodzaj umowy": "Umowa zlecenie",
    Aktywna: "TAK",
  }]);

  assert.deepEqual(result, {
    _sourceLayout: "GRAFIK_PRO_FINANCE_V1",
    payRates: [{
      sourceRow: 2,
      rateId: "rate-1",
      employeeNo: "GP-007",
      validFrom: "2026-09-01",
      validTo: "2026-09-30",
      baseRate: "37.50",
      currency: "PLN",
      contractType: "ZLECENIE",
      active: true,
    }],
  });
});

test("keeps only meaningful rows and supports explicit deactivation", () => {
  const result = normalizeWorkforceFinanceRows([
    {},
    { employeeNo: "GP-008", validFrom: "2026-09-01", baseRate: "42", active: "NIE" },
  ]);
  assert.equal(result.payRates.length, 1);
  assert.equal(result.payRates[0].sourceRow, 3);
  assert.equal(result.payRates[0].active, false);
});
