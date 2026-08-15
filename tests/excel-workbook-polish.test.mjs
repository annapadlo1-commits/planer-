import test from "node:test";
import assert from "node:assert/strict";
import * as XLSX from "xlsx";
import ExcelJS from "exceljs";
import { polishAccessWorkbook, polishMatrixWorkbook } from "../lib/excel-workbook-polish.ts";
import { readMatrixWorkbook } from "../lib/matrix-workbook-import.ts";

function rawWorkbook(sheets){
  const workbook=XLSX.utils.book_new();
  for(const [name,rows] of Object.entries(sheets))XLSX.utils.book_append_sheet(workbook,XLSX.utils.aoa_to_sheet(rows),name);
  return XLSX.write(workbook,{type:"array",bookType:"xlsx"});
}

async function load(bytes){
  const workbook=new ExcelJS.Workbook();
  await workbook.xlsx.load(bytes);
  return workbook;
}

test("configuration workbook gets guided instructions, portable lists and separate ad-hoc names",async()=>{
  const polished=await polishMatrixWorkbook(rawWorkbook({
    Instrukcja:[["stara instrukcja"]],
    "Kategorie grafików":[["Kod","Nazwa","Kolor","Aktywna"],["SALA","Sala","#7257D8","TAK"]],
    Role:[["Kod","Nazwa","Kod kategorii","Aktywna"],["KELNER","Kelner","SALA","TAK"]],
    Lokale:[["Kod","Nazwa","Aktywna"],["KRUCZA","Krucza","TAK"]],
    Pracownicy:[["Numer pracownika","Imię","Nazwisko","Kod roli","Etap zatrudnienia","Rodzaj umowy","Aktywny"],["","Anna","Nowak","KELNER","PROBATION","ZLECENIE","TAK"]],
    "Pula ad-hoc":[["Imię i nazwisko","Telefon","Kod roli","Rodzaj współpracy","Aktywna"],["Jan Kowalski","500600700","KELNER","ZLECENIE","TAK"]],
    Słowniki:[["TYP","KOD","NAZWA"],["ROLA","KELNER","Kelner"],["LOKAL","KRUCZA","Krucza"],["KATEGORIA GRAFIKU","SALA","Sala"]],
  }),"QUICK");
  const workbook=await load(polished);
  assert.match(String(workbook.getWorksheet("Instrukcja").getCell("A1").value),/konfiguracja firmy krok po kroku/i);
  assert.equal(workbook.getWorksheet("Instrukcja").getCell("A2").value,"KROK");
  assert.doesNotMatch(workbook.getWorksheet("Instrukcja").getColumn(1).values.join("\n"),/Co uzupełnić/);
  assert.equal(workbook.getWorksheet("_LISTY").state,"hidden");
  assert.equal(workbook.getWorksheet("Pracownicy").getCell("E2").value,"Okres próbny");
  assert.match(String(workbook.getWorksheet("Pracownicy").getCell("B1").value),/WYMAGANE/);
  assert.equal(workbook.getWorksheet("Pracownicy").getCell("E2").dataValidation.type,"list");
  assert.equal(workbook.getWorksheet("Pracownicy").getCell("A1").note,undefined);
  assert.equal(workbook.getWorksheet("Pula ad-hoc").getCell("A1").value,"Imię\nWYMAGANE");
  assert.equal(workbook.getWorksheet("Pula ad-hoc").getCell("A2").value,"Jan");
  assert.equal(workbook.getWorksheet("Pula ad-hoc").getCell("B2").value,"Kowalski");
  const parsed=await readMatrixWorkbook(new File([polished],"google-sheets-roundtrip.xlsx",{type:"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"}));
  assert.equal(parsed.employees[0].employmentStage,"PROBATION");
  assert.equal(parsed.employees[0].contractType,"ZLECENIE");
  assert.equal(parsed.adHocWorkers[0].displayName,"Jan Kowalski");
});

test("access workbook exports user-facing access labels and checkbox values",async()=>{
  const polished=await polishAccessWorkbook(rawWorkbook({
    Instrukcja:[["stara instrukcja"]],
    Dostępy:[["Adres e-mail","Rodzaj dostępu","Zakres roli","Zakres lokalu","Aktywny"],["anna@example.test","ROLE_MANAGER","KELNER","","TAK"]],
    Słowniki:[["TYP","KOD","NAZWA / OPIS"],["RODZAJ DOSTĘPU","ROLE_MANAGER","Lider roli — opis"],["ROLA","KELNER","Kelner"]],
  }));
  const workbook=await load(polished),sheet=workbook.getWorksheet("Dostępy");
  assert.equal(sheet.getCell("B2").value,"Lider roli");
  assert.equal(sheet.getCell("E2").value,"☑ Tak");
  assert.equal(sheet.getCell("B2").dataValidation.type,"list");
  assert.match(String(sheet.getCell("A1").value),/WYMAGANE/);
});
