import test from "node:test";
import assert from "node:assert/strict";
import * as XLSX from "xlsx";
import ExcelJS from "exceljs";
import { APP_COLOR_PALETTE } from "../lib/app-color-palette.ts";
import { polishAccessWorkbook, polishFinanceWorkbook, polishMatrixWorkbook } from "../lib/excel-workbook-polish.ts";
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
    Pracownicy:[["Numer pracownika","Imię","Nazwisko","Kod roli","Etap zatrudnienia","Koniec okresu próbnego","Rodzaj umowy","Aktywny"],["","Anna","Nowak","KELNER","PROBATION","2026-09-30","ZLECENIE","TAK"]],
    "Pula ad-hoc":[["Imię i nazwisko","Telefon","Kod roli","Rodzaj współpracy","Aktywna"],["Jan Kowalski","500600700","KELNER","ZLECENIE","TAK"]],
    Słowniki:[["TYP","KOD","NAZWA"],["ROLA","KELNER","Kelner"],["LOKAL","KRUCZA","Krucza"],["KATEGORIA GRAFIKU","SALA","Sala"]],
  }),"QUICK");
  const workbook=await load(polished);
  assert.match(String(workbook.getWorksheet("Instrukcja").getCell("A1").value),/konfiguracja firmy krok po kroku/i);
  assert.equal(workbook.getWorksheet("Instrukcja").getCell("A1").fill.fgColor.argb,"FF33443B");
  assert.equal(workbook.getWorksheet("Instrukcja").getCell("A2").value,"KROK");
  assert.equal(workbook.getWorksheet("Instrukcja").getCell("A2").fill.fgColor.argb,"FF1A1A1A");
  assert.doesNotMatch(workbook.getWorksheet("Instrukcja").getColumn(1).values.join("\n"),/Co uzupełnić/);
  assert.equal(workbook.getWorksheet("_LISTY").state,"veryHidden");
  const colorValues=workbook.getWorksheet("_LISTY").getColumn(4).values
    .slice(2)
    .filter(Boolean)
    .map(String);
  assert.equal(colorValues.length,24);
  assert.deepEqual(colorValues,APP_COLOR_PALETTE.map(({name,hex})=>`${name} — ${hex}`));
  assert.equal(workbook.getWorksheet("Kategorie grafików").getCell("C2").dataValidation.type,"list");
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
  assert.equal(sheet.getCell("C2").value,"Kelner [KELNER]");
  assert.equal(sheet.getCell("E2").value,"☑ Tak");
  assert.equal(sheet.getCell("B2").dataValidation.type,"list");
  assert.equal(sheet.getCell("C2").dataValidation.type,"list");
  assert.match(String(sheet.getCell("A1").value),/WYMAGANE/);
  assert.equal(workbook.getWorksheet("Słowniki").state,"hidden");
  const fieldGuide=workbook.getWorksheet("Opis pól");
  assert.match(fieldGuide.getColumn(2).values.join("\n"),/Nadaje, ogranicza albo wyłącza dostęp/);
  assert.doesNotMatch(fieldGuide.getColumn(6).values.join("\n"),/zgodnie z celem zakładki/i);
});

test("finance workbook keeps employment type in one authoritative employee profile",async()=>{
  const polished=await polishFinanceWorkbook(rawWorkbook({
    Instrukcja:[["stara instrukcja"]],
    "Finanse pracowników":[
      ["ID stawki","Numer pracownika","Imię i nazwisko","Zatrudniony od","Zatrudniony do","Obowiązuje od","Obowiązuje do","Stawka godzinowa","Waluta","Aktywna"],
      ["","GP-067","Anna Nowak","2026-08-01","","2026-08-01","",32.5,"PLN","TAK"],
    ],
    Słowniki:[["POLE","WARTOŚĆ","OPIS"],["Aktywna","TAK","Wpis obowiązuje"]],
  }));
  const workbook=await load(polished),sheet=workbook.getWorksheet("Finanse pracowników");
  assert.equal(sheet.getRow(1).values.some(value=>/Rodzaj umowy/u.test(String(value??""))),false);
  assert.equal(sheet.getCell("J2").value,"☑ Tak");
  assert.equal(workbook.getWorksheet("Słowniki").state,"hidden");
  const fieldGuide=workbook.getWorksheet("Opis pól");
  assert.match(fieldGuide.getColumn(2).values.join("\n"),/Aktualizuje okresy stawek godzinowych/u);
  assert.doesNotMatch(fieldGuide.getColumn(6).values.join("\n"),/zgodnie z celem zakładki/i);
});
