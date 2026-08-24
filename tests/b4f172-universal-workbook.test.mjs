import assert from "node:assert/strict";
import test from "node:test";
import ExcelJS from "exceljs";
import * as XLSX from "xlsx";
import {polishMatrixWorkbook} from "../lib/excel-workbook-polish.ts";
import {normalizeWorkbookCode,readMatrixWorkbook} from "../lib/matrix-workbook-import.ts";

function rawWorkbook(sheets){
  const workbook=XLSX.utils.book_new();
  for(const [name,rows] of Object.entries(sheets)){
    XLSX.utils.book_append_sheet(workbook,XLSX.utils.aoa_to_sheet(rows),name);
  }
  return XLSX.write(workbook,{type:"array",bookType:"xlsx"});
}

function workbookFile(sheets){
  const bytes=rawWorkbook(Object.fromEntries(Object.entries(sheets).map(([name,rows])=>[
    name,[Object.keys(rows[0]??{}),...rows.map(row=>Object.keys(rows[0]??{}).map(key=>row[key]??""))],
  ])));
  return new File([bytes],"matrix.xlsx",{type:"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"});
}

test("B4F-172: empty quick workbook has dynamic bounded lists and protected technical identity",async()=>{
  const raw=rawWorkbook({
    Instrukcja:[["SZAFUNEK"]],
    Firma:[["Waluta","Strefa czasowa","Minimalny odpoczynek (godz.)","Maks. zmian jednego pracownika na dobę","Brak wpisanej dostępności oznacza dostępność"],["PLN","Europe/Warsaw",11,1,"TAK"]],
    "Kategorie grafików":[["Kod","Nazwa","Opis","Kolor","Aktywna"]],
    Role:[["Kod","Nazwa","Kategoria grafiku","Kolor","Aktywna"]],
    Lokale:[["Kod","Nazwa","Strefa czasowa","Aktywna"]],
    Obowiązki:[["Kod","Nazwa","Opis","Kolor","Aktywna"]],
    Pracownicy:[["Numer pracownika","Aktywny","Imię","Nazwisko","E-mail","Rola podstawowa"]],
    Zmiany:[["Kod","Nazwa","Lokal","Od","Do","Kończy się następnego dnia","Dni tygodnia","Kolor","Aktywna"]],
    Obsada:[["Zmiana","Rola","Obowiązek (opcjonalnie)","Liczba osób","Aktywna"]],
    "Grupy rezerwy":[["Kod","Nazwa","Kategoria grafiku","Poziomy rezerwy"]],
    "Role grup rezerwy":[["Grupa rezerwy","Rola"]],
    "Pula ad-hoc":[["Imię","Nazwisko","E-mail","Telefon","Rola","Rodzaj współpracy","Stawka godzinowa","Waluta","Dostępny od","Dostępny do","Notatki","Aktywna"]],
    _META:[["Klucz","Wartość"],["workbookMode","EMPTY_TEMPLATE"],["contractVersion","2"]],
  });
  const bytes=await polishMatrixWorkbook(raw,"QUICK",{mode:"EMPTY_TEMPLATE"});
  const workbook=new ExcelJS.Workbook();
  await workbook.xlsx.load(bytes);

  const lists=workbook.getWorksheet("_LISTY");
  assert.equal(lists.state,"veryHidden");
  assert.match(String(lists.getCell("G2").value?.formula??""),/'Kategorie grafików'!\$B2/);
  assert.match(String(lists.getCell("E2").value?.formula??""),/'Role'!\$B2/);
  const roleCategory=workbook.getWorksheet("Role").getCell("C2");
  assert.equal(roleCategory.dataValidation.formulae[0],"'_LISTY'!$G$2:$G$501");
  assert.doesNotMatch(JSON.stringify(workbook.model),/\$2:\$1/);
  assert.equal(workbook.getWorksheet("Role").getColumn(1).hidden,true);
  assert.notEqual(workbook.getWorksheet("Role").getCell("A2").protection?.locked,false);
  assert.equal(workbook.getWorksheet("Role").getCell("B2").protection.locked,false);
  assert.equal(workbook.getWorksheet("Role").model.sheetProtection?.sheet,true);
  assert.equal(workbook.getWorksheet("_META").state,"veryHidden");
  assert.equal(workbook.getWorksheet("Firma").getCell("C2").dataValidation.type,"decimal");
  assert.equal(workbook.getWorksheet("Zmiany").getCell("D2").dataValidation.type,"time");
});

test("B4F-172: Polish letters, maximum length and a blank shift code are normalized deterministically",async()=>{
  assert.equal(normalizeWorkbookCode("Łódź / Śródmieście"),"LODZ_SRODMIESCIE");
  assert.equal(normalizeWorkbookCode("a".repeat(200)).length,80);
  const parsed=await readMatrixWorkbook(workbookFile({
    Lokale:[{Kod:"",Nazwa:"Łódź Śródmieście","Strefa czasowa":"Europe/Warsaw",Aktywna:"TAK"}],
    Zmiany:[{Kod:"",Nazwa:"Wieczór",Lokal:"Łódź Śródmieście",Od:"17:00",Do:"01:00","Kończy się następnego dnia":"TAK","Dni tygodnia":"1",Aktywna:"TAK"}],
  }));
  assert.equal(parsed.locations[0].code,"LODZ_SRODMIESCIE");
  assert.equal(parsed.shifts[0].code,"LODZ_SRODMIESCIE_WIECZOR");
});

test("B4F-172: staffing resolves a visible shift name after its blank code is generated",async()=>{
  const parsed=await readMatrixWorkbook(workbookFile({
    _META:[{Klucz:"workbookMode",Wartość:"EMPTY_TEMPLATE"},{Klucz:"contractVersion",Wartość:"2"}],
    "Kategorie grafików":[{Kod:"",Nazwa:"Sala",Aktywna:"TAK"}],
    Role:[{Kod:"",Nazwa:"Kelner","Kategoria grafiku":"Sala",Aktywna:"TAK"}],
    Lokale:[{Kod:"",Nazwa:"Centrum","Strefa czasowa":"Europe/Warsaw",Aktywna:"TAK"}],
    Obowiązki:[{Kod:"",Nazwa:"Serwis",Aktywna:"TAK"}],
    Zmiany:[{Kod:"",Nazwa:"Wieczór",Lokal:"Centrum",Od:"17:00",Do:"23:00","Kończy się następnego dnia":"NIE","Dni tygodnia":"1",Aktywna:"TAK"}],
    Obsada:[{Zmiana:"Wieczór",Rola:"Kelner","Obowiązek (opcjonalnie)":"Serwis","Liczba osób":"1",Aktywna:"TAK"}],
  }));
  assert.equal(parsed.shifts[0].code,"CENTRUM_WIECZOR");
  assert.equal(parsed.staffingRules[0].shiftCode,"CENTRUM_WIECZOR");
});

test("B4F-174: normalized reserve-group relation supports several roles without comma text",async()=>{
  const parsed=await readMatrixWorkbook(workbookFile({
    "Kategorie grafików":[{Kod:"BAR",Nazwa:"Bar",Aktywna:"TAK"}],
    Role:[
      {Kod:"BARMAN",Nazwa:"Barman","Kategoria grafiku":"BAR",Aktywna:"TAK"},
      {Kod:"BARBACK",Nazwa:"Barback","Kategoria grafiku":"BAR",Aktywna:"TAK"},
      {Kod:"KIEROWNIK_BARU",Nazwa:"Kierownik baru","Kategoria grafiku":"BAR",Aktywna:"TAK"},
    ],
    "Grupy rezerwy":[{Kod:"BAR_CORE",Nazwa:"Rezerwa baru","Kategoria grafiku":"BAR","Poziomy rezerwy":"2"}],
    "Role grup rezerwy":[
      {"Grupa rezerwy":"BAR_CORE",Rola:"BARMAN"},
      {"Grupa rezerwy":"BAR_CORE",Rola:"BARBACK"},
      {"Grupa rezerwy":"BAR_CORE",Rola:"KIEROWNIK_BARU"},
    ],
  }));
  assert.deepEqual(parsed.settings.standbyGroups[0].roleCodes,["BARMAN","BARBACK","KIEROWNIK_BARU"]);
});

test("B4F-172: current export keeps a stable hidden code when the visible name changes",async()=>{
  const parsed=await readMatrixWorkbook(workbookFile({
    _META:[{Klucz:"workbookMode",Wartość:"CURRENT_CONFIG_EXPORT"},{Klucz:"contractVersion",Wartość:"2"},{Klucz:"sourceMatrixVersionId",Wartość:"11111111-1111-4111-8111-111111111111"}],
    "Kategorie grafików":[{Kod:"SALA",Nazwa:"Sala",Aktywna:"TAK"}],
    Role:[{Kod:"KELNER_STABILNY",Nazwa:"Starszy kelner","Kategoria grafiku":"SALA",Aktywna:"TAK"}],
  }));
  assert.equal(parsed.roles[0].code,"KELNER_STABILNY");
  assert.equal(parsed.roles[0].name,"Starszy kelner");
  assert.deepEqual(parsed._workbook,{mode:"CURRENT_CONFIG_EXPORT",contractVersion:"2",sourceMatrixVersionId:"11111111-1111-4111-8111-111111111111"});
});

test("B4F-172: v2 cross-sheet graph returns column, value and repair path",async()=>{
  await assert.rejects(readMatrixWorkbook(workbookFile({
    _META:[{Klucz:"workbookMode",Wartość:"EMPTY_TEMPLATE"},{Klucz:"contractVersion",Wartość:"2"}],
    "Kategorie grafików":[{Kod:"SALA",Nazwa:"Sala",Aktywna:"TAK"}],
    Role:[{Kod:"KELNER",Nazwa:"Kelner","Kategoria grafiku":"NIE_MA",Aktywna:"TAK"}],
  })),error=>{
    assert.equal(error.name,"MatrixWorkbookValidationError");
    assert.deepEqual(error.issues[0],{
      sheet:"Role",row:2,column:"Kategoria grafiku",value:"NIE_MA",code:"CATEGORY_NOT_FOUND",
      message:"Rola wskazuje kategorię, której nie ma w tym pliku.",
      fix:"Dodaj kategorię w zakładce „Kategorie grafików” albo wybierz istniejącą wartość z listy.",
    });
    return true;
  });
});
