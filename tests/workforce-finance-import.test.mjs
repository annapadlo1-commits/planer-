import assert from "node:assert/strict";
import test from "node:test";
import { normalizeWorkforceFinanceRows, readWorkforceFinanceWorkbook } from "../lib/workforce-finance-import.ts";

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

test("finance workbook carries the required single-company boundary from _META", async () => {
  const XLSX = await import("xlsx");
  const workbook = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(workbook, XLSX.utils.aoa_to_sheet([
    ["Numer pracownika", "Obowiązuje od", "Stawka godzinowa", "Waluta", "Rodzaj umowy", "Aktywna"],
    ["GP-008", "2026-09-01", "42", "PLN", "INNE", "TAK"],
  ]), "Finanse pracowników");
  XLSX.utils.book_append_sheet(workbook, XLSX.utils.aoa_to_sheet([
    ["Klucz", "Wartość"],
    ["companyBoundaryId", "a0080000-0000-4000-8000-000000000001"],
  ]), "_META");
  const bytes = XLSX.write(workbook, { type: "array", bookType: "xlsx" });
  const parsed = await readWorkforceFinanceWorkbook(new File([bytes], "finance.xlsx"));
  assert.deepEqual(parsed._workbook, {
    companyBoundaryId: "a0080000-0000-4000-8000-000000000001",
  });
  assert.equal(parsed.payRates.length, 1);
});
