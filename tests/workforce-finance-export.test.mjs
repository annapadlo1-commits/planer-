import assert from "node:assert/strict";
import test from "node:test";
import { buildWorkforceFinanceTemplate } from "../lib/workforce-finance-export.ts";

test("AUD-008: finance export writes the exact boundary into hidden workbook metadata", async () => {
  const boundary = "a0080000-0000-4000-8000-000000000001";
  const artifact = await buildWorkforceFinanceTemplate({
    month: "2026-09-01",
    matrixVersion: {
      id: "11111111-1111-4111-8111-111111111111",
      version: 1,
      effective_from: "2026-09-01",
      settings: { currency: "PLN" },
    },
    employees: [],
    employeePayRates: [],
  }, boundary);
  const XLSX = await import("xlsx");
  const workbook = XLSX.read(artifact.bytes, { type: "array" });
  const metaRows = XLSX.utils.sheet_to_json(workbook.Sheets._META, { defval: "", raw: false });
  assert.equal(metaRows.find(row => row.Klucz === "companyBoundaryId")?.["Wartość"], boundary);
  assert.equal(workbook.Workbook?.Sheets?.find(sheet => sheet.name === "_META")?.Hidden, 2);
  assert.match(artifact.fileName, /2026-09/u);
});
