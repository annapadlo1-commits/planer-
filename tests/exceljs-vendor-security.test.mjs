import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import test from "node:test";
import ExcelJS from "exceljs";

const vendorArchiveUrl = new URL("../vendor/exceljs-4.4.0-szafunek.1.tgz", import.meta.url);
const provenanceUrl = new URL("../vendor/exceljs-4.4.0-szafunek.1.provenance.json", import.meta.url);
const projectPackageUrl = new URL("../package.json", import.meta.url);
const packageLockUrl = new URL("../package-lock.json", import.meta.url);
const installedPackageUrl = new URL("../node_modules/exceljs/package.json", import.meta.url);
const installedUuidPackageUrl = new URL("../node_modules/uuid/package.json", import.meta.url);
const exceljsUuidCallUrl = new URL(
  "../node_modules/exceljs/lib/xlsx/xform/sheet/cf-ext/cf-rule-ext-xform.js",
  import.meta.url,
);

const EXPECTED_PATCHED_HASHES = Object.freeze({
  md5: "a2e68cd9e8c01b3f10306bfbb5423df5",
  sha256: "0f7da7f9c35c75db5c699e0c781411c8d9d0c122f96d4149f9624d40eba4f3b5",
  sha512: "d88af4a4678263369924e5513aeffebc8c1a9e6bad8cc05af12b33ed69ce7550c1024663bafef503c5d87d0172fb003e01c13bbe28b3e4c7fb3ae8e3aa46164e",
});

test("AUD-021 pins the inspected ExcelJS patch and uuid 11 without a global override", () => {
  const archive = readFileSync(vendorArchiveUrl);
  const provenance = JSON.parse(readFileSync(provenanceUrl, "utf8"));
  const projectPackage = JSON.parse(readFileSync(projectPackageUrl, "utf8"));
  const packageLock = JSON.parse(readFileSync(packageLockUrl, "utf8"));
  const installedPackage = JSON.parse(readFileSync(installedPackageUrl, "utf8"));
  const installedUuidPackage = JSON.parse(readFileSync(installedUuidPackageUrl, "utf8"));
  const lockEntry = packageLock.packages["node_modules/exceljs"];

  for (const [algorithm, expected] of Object.entries(EXPECTED_PATCHED_HASHES)) {
    assert.equal(createHash(algorithm).update(archive).digest("hex"), expected);
    assert.equal(provenance.patchedArchiveHashes[algorithm], expected);
  }

  assert.equal(projectPackage.dependencies.exceljs, "file:vendor/exceljs-4.4.0-szafunek.1.tgz");
  assert.equal(projectPackage.overrides, undefined);
  assert.equal(packageLock.packages[""].dependencies.exceljs, "file:vendor/exceljs-4.4.0-szafunek.1.tgz");
  assert.equal(lockEntry.version, "4.4.0-szafunek.1");
  assert.equal(lockEntry.resolved, "file:vendor/exceljs-4.4.0-szafunek.1.tgz");
  assert.equal(lockEntry.integrity, `sha512-${createHash("sha512").update(archive).digest("base64")}`);
  assert.equal(lockEntry.dependencies.uuid, "11.1.1");
  assert.equal(installedPackage.name, "exceljs");
  assert.equal(installedPackage.version, "4.4.0-szafunek.1");
  assert.equal(installedPackage.dependencies.uuid, "11.1.1");
  assert.equal(installedUuidPackage.version, "11.1.1");
  for (const hook of ["preinstall", "install", "postinstall", "prepare"]) {
    assert.equal(installedPackage.scripts?.[hook], undefined);
  }
});

test("AUD-021 keeps ExcelJS on uuid.v4 without buffer or options arguments", () => {
  const source = readFileSync(exceljsUuidCallUrl, "utf8");
  assert.match(source, /const \{v4: uuidv4\} = require\('uuid'\);/u);
  assert.equal((source.match(/uuidv4\(\)/gu) ?? []).length, 2);
  assert.doesNotMatch(source, /uuidv4\([^)]/u);
  assert.doesNotMatch(source, /\b(?:v3|v5|v6)\s*\(/u);
});

test("AUD-021 preserves formulas, styles, validation, dates, Polish text and multi-sheet round-trip", async () => {
  const workbook = new ExcelJS.Workbook();
  const data = workbook.addWorksheet("Dane Łódź");
  const dictionary = workbook.addWorksheet("Słownik");
  dictionary.addRows([["Status"], ["Aktywny"], ["Nieaktywny"]]);

  data.getCell("A1").value = "Łódź — żółć i gęślą jaźń";
  data.getCell("B1").value = 1234.5;
  data.getCell("C1").value = new Date(Date.UTC(2026, 8, 3));
  data.getCell("C1").numFmt = "yyyy-mm-dd";
  data.getCell("D1").value = { formula: "B1*2", result: 2469 };
  data.getCell("D1").font = { bold: true, color: { argb: "FFFFFFFF" } };
  data.getCell("D1").fill = { type: "pattern", pattern: "solid", fgColor: { argb: "FF33443B" } };
  data.getCell("E1").value = "Aktywny";
  data.getCell("E1").dataValidation = {
    type: "list",
    allowBlank: false,
    formulae: ["'Słownik'!$A$2:$A$3"],
  };
  data.addConditionalFormatting({
    ref: "B1:B2",
    rules: [{ type: "dataBar", cfvo: [{ type: "min" }, { type: "max" }], color: { argb: "FF638EC6" } }],
  });

  const bytes = await workbook.xlsx.writeBuffer();
  const imported = new ExcelJS.Workbook();
  await imported.xlsx.load(bytes);
  const importedData = imported.getWorksheet("Dane Łódź");

  assert.deepEqual(imported.worksheets.map(sheet => sheet.name), ["Dane Łódź", "Słownik"]);
  assert.equal(importedData.getCell("A1").value, "Łódź — żółć i gęślą jaźń");
  assert.equal(importedData.getCell("B1").value, 1234.5);
  assert.equal(importedData.getCell("C1").value.toISOString(), "2026-09-03T00:00:00.000Z");
  assert.deepEqual(importedData.getCell("D1").value, { formula: "B1*2", result: 2469 });
  assert.equal(importedData.getCell("D1").font.bold, true);
  assert.equal(importedData.getCell("D1").fill.fgColor.argb, "FF33443B");
  assert.equal(importedData.getCell("E1").dataValidation.type, "list");
  assert.deepEqual(importedData.getCell("E1").dataValidation.formulae, ["'Słownik'!$A$2:$A$3"]);
  assert.equal(importedData.model.conditionalFormattings.length, 1);
});
