import assert from "node:assert/strict";
import test from "node:test";
import * as XLSX from "xlsx";
import { readMatrixWorkbook } from "../lib/matrix-workbook-import.ts";

function workbookFile(sheets) {
  const workbook=XLSX.utils.book_new();
  for(const [name,rows] of Object.entries(sheets)){
    XLSX.utils.book_append_sheet(workbook,XLSX.utils.json_to_sheet(rows),name);
  }
  const bytes=XLSX.write(workbook,{type:"array",bookType:"xlsx"});
  return new File([bytes],"matrix.xlsx",{
    type:"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  });
}

test("standard Matrix workbook keeps employee HR and finance fields",async()=>{
  const parsed=await readMatrixWorkbook(workbookFile({
    Pracownicy:[{
      "Numer pracownika":"",
      "Imię":"Weronika",
      "Nazwisko":"Dąbrowska",
      "E-mail":"barman.07@demo.pl",
      "Kod roli":"BARMAN",
      "Kody lokali":"KRUCZA, PAWILONY",
      "Lokal bazowy":"KRUCZA",
      "KRUCZA_STANDARD":"TAK",
      "KRUCZA_NADGODZINY":"NIE",
      "PAWILONY_STANDARD":"TAK",
      "PAWILONY_NADGODZINY":"TAK",
      "Zatrudniony od":"01.01.2025",
      "Stawka godzinowa":"25",
      "Rodzaj umowy":"Umowa zlecenie",
      "Minimalny odpoczynek godzin":"8",
      "ZAMKNIECIE":"TAK",
    }],
    Słowniki:[{TYP:"OBOWIĄZEK",KOD:"ZAMKNIECIE",NAZWA:"Zamknięcie lokalu"}],
  }));

  assert.equal(parsed._sourceLayout,"GRAFIK_PRO_TEMPLATE");
  assert.equal(parsed.employees.length,1);
  const employee=parsed.employees[0];
  assert.equal(employee.employeeNo,"");
  assert.equal(employee.firstName,"Weronika");
  assert.equal(employee.lastName,"Dąbrowska");
  assert.equal(employee.email,"barman.07@demo.pl");
  assert.equal(employee.primaryRoleCode,"BARMAN");
  assert.deepEqual(employee.locationCodes,["KRUCZA","PAWILONY"]);
  assert.deepEqual(employee.locationGrants,[
    {code:"KRUCZA",standardAllowed:true,overtimeAllowed:false,homeLocation:true},
    {code:"PAWILONY",standardAllowed:true,overtimeAllowed:true,homeLocation:false},
  ]);
  assert.equal(employee.employmentStart,"2025-01-01");
  assert.equal(employee.baseRate,"25");
  assert.equal(employee.contractType,"ZLECENIE");
  assert.equal(employee.minimumRestHours,"8");
  assert.deepEqual(employee.dutyCodes,["ZAMKNIECIE"]);
  assert.equal(parsed.employeeDuties.length,1);
  assert.equal(parsed.employeeDuties[0].dutyCode,"ZAMKNIECIE");
});

test("detailed capability rows win over convenience columns during a full round trip",async()=>{
  const parsed=await readMatrixWorkbook(workbookFile({
    Pracownicy:[{
      "Numer pracownika":"GP-101","Imię":"Aleksandra","Nazwisko":"Dąbrowska",
      "Kod roli":"KELNER","Kody lokali":"KRUCZA","Rodzaj umowy":"ZLECENIE","RUNNER":"TAK",
    }],
    "Kompetencje pracowników":[{
      "Numer pracownika":"GP-101","Kod obowiązku":"RUNNER","Kod roli":"","Kod lokalu":"","Aktywna":"TAK",
    }],
    Słowniki:[{TYP:"OBOWIĄZEK",KOD:"RUNNER",NAZWA:"Runner"}],
  }));

  assert.equal(parsed.employeeCapabilities.length,1);
  assert.equal(parsed.employeeCapabilities[0].roleCode,"");
  assert.equal(parsed.employeeDuties.length,0,"globalna kompetencja z arkusza szczegółowego nie może dostać drugiego wpisu ograniczonego do roli");
});

test("Apps Script employee identifiers are matched by email instead of appended as GP duplicates",async()=>{
  const parsed=await readMatrixWorkbook(workbookFile({
    BAZA_PRACOWNIKÓW:[{
      "PRACOWNIK_ID*":"OLD-57",
      "IMIĘ_I_NAZWISKO*":"Oliwia Kania",
      "EMAIL*":"oliwia@example.test",
      "ROLA_GŁÓWNA*":"PIZZABAR",
      "KRUCZA_STANDARD":"TAK",
      "PAWILONY_STANDARD":"NIE",
      "KRUCZA_NADGODZINY":"NIE",
      "PAWILONY_NADGODZINY":"TAK",
      "LOKALIZACJA_BAZOWA*":"KRUCZA",
      "DATA_ZATRUDNIENIA_OD*":"2025-01-01",
      "TYP_UMOWY*":"ZLECENIE",
      "TYLKO_RANO":"TAK",
      "TYLKO_POPOŁUDNIE":"NIE",
      "BEZ_WEEKENDÓW":"TAK",
      "AKTYWNY*":"TAK",
    }],
  }));

  assert.equal(parsed._sourceLayout,"APPS_SCRIPT_BASE");
  assert.equal(parsed.employees[0].employeeNo,"");
  assert.equal(parsed.employees[0].sourceEmployeeNo,"OLD-57");
  assert.deepEqual(parsed.employees[0].locationCodes,["KRUCZA"]);
  assert.deepEqual(parsed.employees[0].locationGrants,[
    {code:"KRUCZA",standardAllowed:true,overtimeAllowed:false,homeLocation:true},
    {code:"PAWILONY",standardAllowed:false,overtimeAllowed:true,homeLocation:false},
  ]);
  assert.equal(parsed.employees[0].onlyMorning,true);
  assert.equal(parsed.employees[0].onlyEvening,false);
  assert.equal(parsed.employees[0].noWeekends,true);
  assert.equal(parsed.employees[0].active,true);
});

test("shift period is derived only from exact start time, never from a name, code or imported label",async()=>{
  const parsed=await readMatrixWorkbook(workbookFile({
    Zmiany:[
      {Kod:"RANO_1",Nazwa:"Poranna",Pora:"",Od:"10:00",Do:"17:00",Dni:"1",Aktywna:"TAK"},
      {Kod:"SPECJALNA_1",Nazwa:"Specjalna",Pora:"EVENING",Od:"12:00",Do:"18:00",Dni:"1",Aktywna:"TAK"},
    ],
  }));

  assert.deepEqual(parsed.shifts.map(shift=>shift.shiftPeriod),[
    "MORNING","MIDDLE",
  ]);
});

test("Excel-native times are normalized to strict HH:MM before server validation",async()=>{
  const parsed=await readMatrixWorkbook(workbookFile({
    Zmiany:[
      {Kod:"RANO",Nazwa:"Poranna",Od:10/24,Do:"17:00:00",Dni:"1",Aktywna:"TAK"},
      {Kod:"WIECZOR",Nazwa:"Wieczorna",Od:"1899-12-30T17:00:00Z",Do:1/24,Dni:"5",Aktywna:"TAK"},
    ],
  }));

  assert.deepEqual(parsed.shifts.map(shift=>[shift.startsAt,shift.endsAt,shift.shiftPeriod]),[
    ["10:00","17:00","MORNING"],
    ["17:00","01:00","EVENING"],
  ]);
});

test("new role and location may be entered by name and receive stable codes in the same workbook",async()=>{
  const parsed=await readMatrixWorkbook(workbookFile({
    Role:[{Kod:"",Nazwa:"Barista senior",Aktywna:"TAK"}],
    Lokale:[{Kod:"",Nazwa:"Nowy lokal",Aktywna:"TAK"}],
    Pracownicy:[{
      Imię:"Anna",Nazwisko:"Nowak","E-mail":"anna@example.test",
      "Kod roli":"Barista senior","Kody lokali":"Nowy lokal","Rodzaj umowy":"ZLECENIE",
    }],
  }));

  assert.equal(parsed.roles[0].code,"BARISTA_SENIOR");
  assert.equal(parsed.roles[0].sortOrder,"1");
  assert.equal(parsed.locations[0].code,"NOWY_LOKAL");
  assert.equal(parsed.locations[0].sortOrder,"1");
  assert.equal(parsed.employees[0].primaryRoleCode,"BARISTA_SENIOR");
  assert.deepEqual(parsed.employees[0].locationCodes,["NOWY_LOKAL"]);
});

test("Apps Script Sunday code ND and duty column aliases are preserved",async()=>{
  const parsed=await readMatrixWorkbook(workbookFile({
    BAZA_PRACOWNIKÓW:[{
      "PRACOWNIK_ID*":"P001","IMIĘ_I_NAZWISKO*":"Anna Nowak","EMAIL*":"anna@example.test",
      "ROLA_GŁÓWNA*":"BARMAN","LOKALIZACJA_BAZOWA*":"KRUCZA","KRUCZA_STANDARD":"TAK",
      "TYP_UMOWY*":"ZLECENIE","ROTACYJNY":"TAK",
    }],
    FUNKCJE_DODATKOWE:[{KOD:"EVENT_ROTACYJNY",ROLA_WYMAGANA:"BARMAN",TYP_PRZYDZIAŁU:"OPCJONALNY",AKTYWNA:"TAK"}],
    DEFINICJE_ZMIAN:[
      {LOKALIZACJA_ID:"KRUCZA",GRUPA_DNI:"PT-ND",DZIEŃ_TYGODNIA:"PT",ZMIANA_ID:"WIECZÓR",NAZWA:"Wieczorna",PORA:"EVENING",START:"17:00",KONIEC:"01:00",KONIEC_DZIEŃ_PLUS:"1",AKTYWNA:"TAK"},
      {LOKALIZACJA_ID:"KRUCZA",GRUPA_DNI:"PT-ND",DZIEŃ_TYGODNIA:"SOB",ZMIANA_ID:"WIECZÓR",NAZWA:"Wieczorna",PORA:"EVENING",START:"17:00",KONIEC:"01:00",KONIEC_DZIEŃ_PLUS:"1",AKTYWNA:"TAK"},
      {LOKALIZACJA_ID:"KRUCZA",GRUPA_DNI:"PT-ND",DZIEŃ_TYGODNIA:"ND",ZMIANA_ID:"WIECZÓR",NAZWA:"Wieczorna",PORA:"EVENING",START:"17:00",KONIEC:"01:00",KONIEC_DZIEŃ_PLUS:"1",AKTYWNA:"TAK"},
    ],
  }));

  assert.deepEqual(parsed.shifts[0].days,[5,6,7]);
  assert.equal(parsed.shifts[0].shiftPeriod,"EVENING");
  assert.equal(parsed.employeeDuties[0].dutyCode,"EVENT_ROTACYJNY");
});

test("duty dictionary marks complete employee coverage, including unchecked duties",async()=>{
  const parsed=await readMatrixWorkbook(workbookFile({
    Pracownicy:[{
      "Imię":"Anna","Nazwisko":"Nowak","E-mail":"anna@example.test",
      "Kod roli":"BARMAN","Kody lokali":"KRUCZA","Rodzaj umowy":"ZLECENIE",
      "BAR":"TAK","ZAMKNIECIE":"NIE",
    }],
    Słowniki:[
      {TYP:"OBOWIĄZEK",KOD:"BAR",NAZWA:"Bar"},
      {TYP:"OBOWIĄZEK",KOD:"ZAMKNIECIE",NAZWA:"Zamknięcie"},
    ],
  }));

  assert.deepEqual(parsed.employees[0].dutyCodes,["BAR","ZAMKNIECIE"]);
  assert.deepEqual(parsed.employeeDuties.map(duty=>duty.dutyCode),["BAR"]);
});

test("a partial employee row does not overwrite preferences that are absent from the file",async()=>{
  const parsed=await readMatrixWorkbook(workbookFile({
    Pracownicy:[{"Imię":"Anna","Nazwisko":"Nowak","E-mail":"anna@example.test","Kod roli":"BARMAN","Kody lokali":"KRUCZA","Rodzaj umowy":"ZLECENIE"}],
  }));
  assert.equal("preferenceMonth" in parsed.employees[0],false);
  assert.equal("shiftPeriodPreferences" in parsed.employees[0],false);
});

test("staffing and role-duty semantics stay empty when the workbook does not state them",async()=>{
  const parsed=await readMatrixWorkbook(workbookFile({
    Obsada:[{"Kod zmiany":"S1","Kod roli":"BARMAN","Liczba osób":"2"}],
    "Role-Obowiązki":[{"Kod roli":"BARMAN","Kod obowiązku":"ZAMKNIECIE"}],
  }));
  assert.equal(parsed.staffingRules[0].scenarioCode,"");
  assert.equal(parsed.staffingRules[0].operation,"");
  assert.equal(parsed.roleDuties[0].assignmentMode,"");
});

test("one company workbook parses every business input required for a clean restore",async()=>{
  const parsed=await readMatrixWorkbook(workbookFile({
    Firma:[{"Waluta":"PLN","Strefa czasowa":"Europe/Warsaw","Minimalny odpoczynek (min)":"660","Maks. zmian jednego pracownika na dobę":"2","Poziomy rezerwy stand-by na rolę i dzień":"2","Brak dostępności oznacza dostępność":"NIE","Wymagaj wyniku optymalnego":"TAK"}],
    Role:[{Kod:"KELNER",Nazwa:"Kelner",Kolor:"#7257d8",Kolejność:"1",Aktywna:"TAK"}],
    Lokale:[{Kod:"KRUCZA",Nazwa:"Krucza","Strefa czasowa":"Europe/Warsaw",Kolejność:"1",Aktywna:"TAK"}],
    Obowiązki:[{Kod:"RUNNER",Nazwa:"Runner",Opis:"Wsparcie",Kolor:"#4a8d78",Kolejność:"1",Aktywna:"TAK"}],
    Scenariusze:[{Kod:"BAZOWY",Nazwa:"Bazowy",Domyślny:"TAK","Ustawienia JSON":"{}",Aktywny:"TAK"}],
    Strategie:[{Kod:"BALANCED",Nazwa:"Zbalansowany","Kod silnika":"CP_SAT","Opcje silnika JSON":"{}",Aktywna:"TAK"}],
    "Kryteria strategii":[{"Kod strategii":"BALANCED",Poziom:"1",Miara:"UNFILLED",Kierunek:"MINIMIZE",Waga:"1",Tolerancja:"0","Parametry JSON":"{}",Aktywne:"TAK"}],
    "Warianty scenariuszy":[{"Kod scenariusza":"BAZOWY","Kod strategii":"BALANCED",Kolejność:"1","Nadpisania celów JSON":"{}","Nadpisania silnika JSON":"{}",Aktywne:"TAK"}],
    "Zasady płacowe":[{Kod:"NOC",Nazwa:"Dodatek nocny","Sposób obliczania":"FIXED_PER_HOUR","Kwota za godzinę":"5,50",Waluta:"PLN","Sposób łączenia":"STACK",Dni:"1,2,3,4,5,6,7","Kody ról":"KELNER",Aktywna:"TAK"}],
    "Dodatki scenariuszy":[{"Kod scenariusza":"BAZOWY","Kod zasady":"NOC",Włączona:"TAK"}],
    "Budżety scenariuszy":[{"Kod scenariusza":"BAZOWY",Miesiąc:"2026-09-01",Operacja:"SET",Budżet:"10000",Waluta:"PLN","Twardy limit":"NIE","Próg ostrzeżenia (%)":"90"}],
    Pracownicy:[{"Numer pracownika":"GP-001",Imię:"Anna",Nazwisko:"Nowak","Kod roli":"KELNER","Kody lokali":"KRUCZA","Rodzaj umowy":"ZLECENIE"}],
    "Role pracowników":[{"Numer pracownika":"GP-001","Kod roli":"KELNER",Podstawowa:"TAK","Może zatwierdzać":"TAK",Aktywna:"TAK"}],
    "Lokale pracowników":[{"Numer pracownika":"GP-001","Kod lokalu":"KRUCZA","Zwykła praca":"TAK","Dodatkowa praca":"NIE","Lokal bazowy":"TAK",Aktywna:"TAK"}],
    "Kompetencje pracowników":[{"Numer pracownika":"GP-001","Kod obowiązku":"RUNNER","Kod roli":"KELNER",Aktywna:"TAK"}],
    Dostępność:[{"ID wpisu":"","Numer pracownika":"GP-001",Rodzaj:"AVAILABLE_WINDOW",Od:"2026-09-01T08:00:00+02:00",Do:"2026-09-01T18:00:00+02:00",Aktywny:"TAK"}],
  }));

  assert.equal(parsed.settings.currency,"PLN");
  assert.equal(parsed.settings.maximumShiftsPerDay,"2");
  assert.equal(parsed.settings.standbyTiersPerRoleDay,"2");
  assert.equal(parsed.roles[0].code,"KELNER");
  assert.equal(parsed.locations[0].timezone,"Europe/Warsaw");
  assert.equal(parsed.scenarios[0].isDefault,true);
  assert.equal(parsed.strategyObjectives[0].metricCode,"UNFILLED");
  assert.equal(parsed.payRules[0].rateMinorPerHour,"550");
  assert.deepEqual(parsed.payRules[0].roleCodes,["KELNER"]);
  assert.equal(parsed.scenarioBudgets[0].amountMinor,"1000000");
  assert.equal(parsed.employeeRoles[0].canLead,true);
  assert.equal(parsed.employeeLocationsDetailed[0].homeLocation,true);
  assert.equal(parsed.employeeCapabilities[0].dutyCode,"RUNNER");
  assert.equal(parsed.timeConstraints[0].kind,"AVAILABLE_WINDOW");
});

test("legacy daily-shift header remains import-compatible",async()=>{
  const parsed=await readMatrixWorkbook(workbookFile({
    Firma:[{"Maks. zmian dziennie":"1"}],
  }));
  assert.equal(parsed.settings.maximumShiftsPerDay,"1");
});
