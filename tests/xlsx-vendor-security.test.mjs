import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import test from "node:test";
import * as XLSX from "xlsx";

const vendorArchiveUrl = new URL("../vendor/xlsx-0.20.3.tgz", import.meta.url);
const projectPackageUrl = new URL("../package.json", import.meta.url);
const packageLockUrl = new URL("../package-lock.json", import.meta.url);
const installedPackageUrl = new URL("../node_modules/xlsx/package.json", import.meta.url);

const EXPECTED_HASHES = Object.freeze({
  md5: "aac39517149362ea8123d8a303486c3c",
  sha256: "8dc73fc3b00203e72d176e85b50938627c7b086e607c682e8d3c22c02bb99fe8",
  sha512: "a0b0eade3c3b01c2ea2961f60210a9553665f267fa5f661178ff8d7a1d12254cd5fc1759623b61f78b46e6da22301d4f3eb62dc4e09f6a850292fb6e1fedc024",
});

test("AUD-009 pins the inspected official SheetJS archive and patched package line", () => {
  const archive = readFileSync(vendorArchiveUrl);
  for (const [algorithm, expected] of Object.entries(EXPECTED_HASHES)) {
    assert.equal(createHash(algorithm).update(archive).digest("hex"), expected);
  }

  const projectPackage = JSON.parse(readFileSync(projectPackageUrl, "utf8"));
  const packageLock = JSON.parse(readFileSync(packageLockUrl, "utf8"));
  const installedPackage = JSON.parse(readFileSync(installedPackageUrl, "utf8"));
  const lockEntry = packageLock.packages["node_modules/xlsx"];

  assert.equal(projectPackage.dependencies.xlsx, "file:vendor/xlsx-0.20.3.tgz");
  assert.equal(packageLock.packages[""].dependencies.xlsx, "file:vendor/xlsx-0.20.3.tgz");
  assert.equal(lockEntry.version, "0.20.3");
  assert.equal(lockEntry.resolved, "file:vendor/xlsx-0.20.3.tgz");
  assert.equal(lockEntry.integrity, `sha512-${createHash("sha512").update(archive).digest("base64")}`);
  assert.equal(installedPackage.name, "xlsx");
  assert.equal(installedPackage.version, "0.20.3");
  assert.equal(XLSX.version, "0.20.3");
  for (const hook of ["preinstall", "install", "postinstall", "prepare"]) {
    assert.equal(installedPackage.scripts?.[hook], undefined);
  }
});

test("SheetJS 0.20.3 preserves workbook data through export and re-import", () => {
  const workbook = XLSX.utils.book_new();
  const data = XLSX.utils.aoa_to_sheet([
    ["Tekst", "Liczba", "Data", "Formuła", "Puste"],
    ["Łódź — żółć i gęślą jaźń", 1234.5, new Date(Date.UTC(2026, 8, 2)), null, null],
    [],
    ["__proto__", -7, new Date(Date.UTC(2026, 8, 30)), null, "koniec"],
  ], { cellDates: true });
  data.D2 = { t: "n", f: "B2*2", v: 2469 };
  data.D4 = { t: "n", f: "ABS(B4)", v: 7 };
  data["!ref"] = "A1:E4";
  XLSX.utils.book_append_sheet(workbook, data, "Dane Łódź");
  XLSX.utils.book_append_sheet(
    workbook,
    XLSX.utils.aoa_to_sheet([["Arkusz drugi"], ["constructor"], ["prototype"]]),
    "Drugi arkusz",
  );

  const exported = XLSX.write(workbook, { type: "array", bookType: "xlsx", cellDates: true });
  const imported = XLSX.read(exported, { type: "array", cellDates: true });
  const rows = XLSX.utils.sheet_to_json(imported.Sheets["Dane Łódź"], {
    header: 1,
    raw: true,
    defval: null,
    blankrows: true,
  });

  assert.deepEqual(imported.SheetNames, ["Dane Łódź", "Drugi arkusz"]);
  assert.equal(rows[1][0], "Łódź — żółć i gęślą jaźń");
  assert.equal(rows[1][1], 1234.5);
  assert.ok(rows[1][2] instanceof Date);
  assert.equal(rows[1][2].toISOString(), "2026-09-02T00:00:00.000Z");
  assert.deepEqual(rows[2], [null, null, null, null, null]);
  assert.equal(rows[3][0], "__proto__");
  assert.equal(imported.Sheets["Dane Łódź"].D2.f, "B2*2");
  assert.equal(imported.Sheets["Dane Łódź"].D4.f, "ABS(B4)");
  assert.equal(Object.prototype.polluted, undefined);
});

test("a truncated XLSX container is rejected instead of being treated as a workbook", () => {
  const truncatedZip = Uint8Array.from([0x50, 0x4b, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00]);
  assert.throws(() => XLSX.read(truncatedZip, { type: "array" }));
});
