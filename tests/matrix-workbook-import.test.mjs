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
      {Kod:"WIECZOR",Nazwa:"Wieczorna",Od:"1899-12-30T17:00:00Z",Do:1/24,Dni:"5","Następny dzień":"TAK",Aktywna:"TAK"},
    ],
  }));

  assert.deepEqual(parsed.shifts.map(shift=>[shift.startsAt,shift.endsAt,shift.shiftPeriod]),[
    ["10:00","17:00","MORNING"],
    ["17:00","01:00","EVENING"],
  ]);
});

test("quick-start shifts without an optional order never emit an empty integer",async()=>{
  const parsed=await readMatrixWorkbook(workbookFile({
    Zmiany:[
      {Kod:"RANO",Nazwa:"Poranna",Od:"10:00",Do:"17:00",Dni:"1",Aktywna:"TAK"},
      {Kod:"WIECZOR",Nazwa:"Wieczorna",Od:"17:00",Do:"01:00",Dni:"5","Następny dzień":"TAK",Aktywna:"TAK"},
    ],
  }));

  assert.deepEqual(parsed.shifts.map(shift=>shift.sortOrder),["1","2"]);
  assert.ok(parsed.shifts.every(shift=>shift.sortOrder!==""));
});

test("shift colors round-trip through the app palette and blanks use the neutral default",async()=>{
  const parsed=await readMatrixWorkbook(workbookFile({
    Zmiany:[
      {Kod:"RANO",Nazwa:"Poranna",Od:"10:00",Do:"17:00",Dni:"1",Kolor:"Deep Moss — #55665A",Aktywna:"TAK"},
      {Kod:"WIECZOR",Nazwa:"Wieczorna",Od:"17:00",Do:"01:00",Dni:"5","Następny dzień":"TAK",Kolor:"",Aktywna:"TAK"},
    ],
  }));
  assert.deepEqual(parsed.shifts.map(shift=>shift.color),["#55665A","#879681"]);
});

test("invalid shift color fails closed at the exact Excel cell",async()=>{
  await assert.rejects(
    readMatrixWorkbook(workbookFile({Zmiany:[{Kod:"RANO",Nazwa:"Poranna",Od:"10:00",Do:"17:00",Dni:"1",Kolor:"zielony",Aktywna:"TAK"}]})),
    /Zmiany • wiersz 2 • kolumna „Kolor”.*#RRGGBB/,
  );
});

test("a freshly downloaded quick-start workbook remains self-importable after an empty UAT reset",async()=>{
  const parsed=await readMatrixWorkbook(workbookFile({
    Role:[{Kod:"KELNER",Nazwa:"Kelner",Aktywna:"TAK"}],
    Lokale:[{Kod:"KRUCZA",Nazwa:"Krucza",Aktywna:"TAK"}],
    Obowiązki:[],
    Pracownicy:[{
      "Numer pracownika":"","Imię":"Anna","Nazwisko":"Nowak",
      "E-mail":"anna.nowak@example.test","Kod roli":"KELNER",
      "Kody lokali":"KRUCZA","Rodzaj umowy":"ZLECENIE",Aktywna:"TAK",
    }],
    Scenariusze:[],
    Strategie:[],
    "Cele strategii":[],
    "Strategie scenariuszy":[],
  }));

  assert.equal(parsed.duties.length,0,"obowiązki są opcjonalne i pusty arkusz nie może blokować pierwszego uruchomienia");
  assert.deepEqual(parsed.scenarios.map(item=>item.code),["BASE"]);
  assert.deepEqual(parsed.strategies.map(item=>item.code),["BALANCED","MIN_COST","PREFERENCES"]);
  assert.equal(parsed.strategyObjectives.length,27);
  assert.equal(parsed.scenarioStrategies.length,3);
});

test("overnight validation names every invalid Excel row before server publication",async()=>{
  await assert.rejects(
    readMatrixWorkbook(workbookFile({
      Zmiany:[
        {Kod:"NOC_1",Nazwa:"Nocna",Od:"17:00",Do:"00:00",Dni:"1","Następny dzień":"NIE",Aktywna:"TAK"},
        {Kod:"DZIEN_1",Nazwa:"Dzienna",Od:"10:00",Do:"17:00",Dni:"2","Następny dzień":"TAK",Aktywna:"TAK"},
      ],
    })),
    error=>{
      assert.match(error.message,/Zmiany • wiersz 2 • NOC_1 \(17:00–00:00\).*TAK/);
      assert.match(error.message,/Zmiany • wiersz 3 • DZIEN_1 \(10:00–17:00\).*NIE/);
      return true;
    },
  );
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

test("technical blank dictionary rows do not become empty active roles or locations",async()=>{
  const parsed=await readMatrixWorkbook(workbookFile({
    "Kategorie grafików":[
      {Kod:"SALA",Nazwa:"Sala",Aktywna:"TAK"},
      {Kod:"",Nazwa:"",Kolor:"#7257D8",Kolejność:"2",Aktywna:"TAK"},
    ],
    Role:[
      {Kod:"KELNER",Nazwa:"Kelner","Kod kategorii":"SALA",Aktywna:"TAK"},
      {Kod:"",Nazwa:"","Kod kategorii":"",Kolor:"#7257D8",Kolejność:"2",Aktywna:"TAK"},
    ],
    Lokale:[
      {Kod:"KRUCZA",Nazwa:"Krucza",Aktywna:"TAK"},
      {Kod:"",Nazwa:"","Strefa czasowa":"",Kolejność:"2",Aktywna:"TAK"},
    ],
    Obowiązki:[
      {Kod:"RUNNER",Nazwa:"Runner",Aktywna:"TAK"},
      {Kod:"",Nazwa:"",Kolor:"#4A8D78",Kolejność:"2",Aktywna:"TAK"},
    ],
  }));

  assert.deepEqual(parsed.roleCategories.map(item=>item.code),["SALA"]);
  assert.deepEqual(parsed.roles.map(item=>item.code),["KELNER"]);
  assert.deepEqual(parsed.locations.map(item=>item.code),["KRUCZA"]);
  assert.deepEqual(parsed.duties.map(item=>item.code),["RUNNER"]);
});

test("a named dictionary row without a required value points to the exact sheet row and columns",async()=>{
  await assert.rejects(
    readMatrixWorkbook(workbookFile({
      Role:[
        {Kod:"KELNER",Nazwa:"Kelner",Aktywna:"TAK"},
        {Kod:"BARMAN",Nazwa:"",Aktywna:"TAK"},
      ],
    })),
    /Role • wiersz 3 • kolumna „Nazwa”: uzupełnij nazwę roli/,
  );
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

test("staffing defaults to base SET while role-duty rows remain competency-only",async()=>{
  const parsed=await readMatrixWorkbook(workbookFile({
    Obsada:[{"Kod zmiany":"S1","Kod roli":"BARMAN","Liczba osób":"2"}],
    "Role-Obowiązki":[{"Kod roli":"BARMAN","Kod obowiązku":"ZAMKNIECIE"}],
  }));
  assert.equal(parsed.staffingRules[0].scenarioCode,"BASE");
  assert.equal(parsed.staffingRules[0].operation,"SET");
  assert.equal(parsed.roleDuties[0].assignmentMode,"OPTIONAL");
  assert.equal(parsed.roleDuties[0].minimumCount,"0");
  assert.equal(parsed.roleDuties[0].shiftObligation,false);
});

test("role-duty assignment mode accepts only blank, OPTIONAL or EXTRA",async()=>{
  const parsed=await readMatrixWorkbook(workbookFile({
    "Role-Obowiązki":[
      {"Kod roli":"BARMAN","Kod obowiązku":"BAR"},
      {"Kod roli":"BARMAN","Kod obowiązku":"ZAMKNIECIE",Znaczenie:"optional"},
      {"Kod roli":"KELNER","Kod obowiązku":"RUNNER",Znaczenie:"EXTRA"},
    ],
  }));

  assert.deepEqual(parsed.roleDuties.map(row=>row.assignmentMode),["OPTIONAL","OPTIONAL","EXTRA"]);
});

test("an unknown role-duty assignment mode fails closed with the exact cell location",async()=>{
  await assert.rejects(
    readMatrixWorkbook(workbookFile({
      "Role-Obowiązki":[{"Kod roli":"KELNER","Kod obowiązku":"RUNNER",Znaczenie:"OPTOINAL"}],
    })),
    error=>{
      assert.match(error.message,/Role-Obowiązki • wiersz 2 • kolumna „Znaczenie”/);
      assert.match(error.message,/wartość „OPTOINAL” jest nieprawidłowa/);
      assert.match(error.message,/puste albo wpisz OPTIONAL lub EXTRA/);
      return true;
    },
  );

  await assert.rejects(
    readMatrixWorkbook(workbookFile({
      FUNKCJE_DODATKOWE:[{
        KOD:"RUNNER",ROLA_WYMAGANA:"KELNER",TYP_PRZYDZIAŁU:"WYMAGANY",AKTYWNA:"TAK",
      }],
    })),
    /FUNKCJE_DODATKOWE • wiersz 2 • kolumna „TYP_PRZYDZIAŁU”.*wartość „WYMAGANY”.*OPTIONAL lub EXTRA/,
  );
});

test("legacy broad role-duty demand is rejected with an exact-shift repair path",async()=>{
  await assert.rejects(
    readMatrixWorkbook(workbookFile({
      "Role-Obowiązki":[{
        "Kod roli":"KELNER","Kod obowiązku":"RUNNER",Znaczenie:"REQUIRED",
        Minimum:"1","Obowiązek zmianowy":"TAK",Pora:"MIDDLE",Aktywne:"TAK",
      }],
    })),
    error=>{
      assert.match(error.message,/Role-Obowiązki • wiersz 2 • pola „Znaczenie \/ Minimum \/ Pora”/);
      assert.match(error.message,/arkusza „Obsada”/);
      assert.match(error.message,/dokładny „Kod zmiany”/);
      return true;
    },
  );
});

test("legacy Apps Script WYMÓG_ZMIANY never creates shiftObligation plus shiftPeriod",async()=>{
  await assert.rejects(
    readMatrixWorkbook(workbookFile({
      FUNKCJE_DODATKOWE:[{
        KOD:"RUNNER",ROLA_WYMAGANA:"KELNER",TYP_PRZYDZIAŁU:"WYMÓG_ZMIANY",
        PORA:"MIDDLE",AKTYWNA:"TAK",
      }],
    })),
    /FUNKCJE_DODATKOWE • wiersz 2 .*stary szeroki wymóg rola–obowiązek.*„Obsada”/,
  );
});

test("quick-start staffing resolves a displayed scenario name to its canonical code",async()=>{
  const parsed=await readMatrixWorkbook(workbookFile({
    Scenariusze:[],
    Obsada:[{"Kod scenariusza":"Bazowy","Kod zmiany":"S1","Kod roli":"BARMAN","Liczba osób":"2"}],
  }));
  assert.equal(parsed.scenarios[0].code,"BASE");
  assert.equal(parsed.staffingRules[0].scenarioCode,"BASE");
});

test("one company workbook parses every business input required for a clean restore",async()=>{
  const parsed=await readMatrixWorkbook(workbookFile({
    Firma:[{"Waluta":"PLN","Strefa czasowa":"Europe/Warsaw","Minimalny odpoczynek (min)":"660","Maks. zmian jednego pracownika na dobę":"2","Brak dostępności oznacza dostępność":"NIE","Wymagaj wyniku optymalnego":"TAK"}],
    "Kategorie grafików":[{Kod:"SALA",Nazwa:"Sala",Kolor:"#7257d8",Kolejność:"1",Aktywna:"TAK"}],
    Role:[{Kod:"KELNER",Nazwa:"Kelner","Kod kategorii":"SALA",Kolor:"#7257d8",Kolejność:"1",Aktywna:"TAK"}],
    "Grupy rezerwy":[{Kod:"SALA_SERWIS",Nazwa:"Serwis sali","Kod kategorii":"SALA","Kody ról":"KELNER",Poziomy:"2"}],
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
  assert.equal(parsed.settings.standbyTiersPerRoleDay,0);
  assert.equal(parsed.settings.standbyGroups[0].tiers,2);
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

test("first-run workbook imports schedule categories, fallback roles, probation and ad-hoc pool",async()=>{
  const parsed=await readMatrixWorkbook(workbookFile({
    "Kategorie grafików":[
      {Kod:"SALA",Nazwa:"Sala",Kolor:"#7257d8",Kolejność:"1",Aktywna:"TAK"},
      {Kod:"BAR",Nazwa:"Bar",Kolor:"#0f8f7a",Kolejność:"2",Aktywna:"TAK"},
    ],
    Role:[
      {Kod:"KELNER",Nazwa:"Kelner","Kod kategorii":"SALA",Aktywna:"TAK"},
      {Kod:"HOST",Nazwa:"Host","Kod kategorii":"SALA",Aktywna:"TAK"},
      {Kod:"BARMAN",Nazwa:"Barman","Kod kategorii":"BAR",Aktywna:"TAK"},
    ],
    Pracownicy:[{
      "Numer pracownika":"GP-201",Imię:"Anna",Nazwisko:"Nowak","Kod roli":"KELNER",
      "Role rezerwowe (kolejność)":"HOST:1","Etap zatrudnienia":"PROBATION",
      "Koniec okresu próbnego":"2026-09-30","Rodzaj umowy":"ZLECENIE",
    }],
    "Role pracowników":[
      {"Numer pracownika":"GP-201","Kod roli":"KELNER",Podstawowa:"TAK","Sposób użycia":"STANDARD","Priorytet rezerwowy":"0",Aktywna:"TAK"},
      {"Numer pracownika":"GP-201","Kod roli":"HOST",Podstawowa:"NIE","Sposób użycia":"BACKUP","Priorytet rezerwowy":"1",Aktywna:"TAK"},
    ],
    "Pula ad-hoc":[{
      "Imię i nazwisko":"Jan Adhoc","E-mail":"jan.adhoc@example.test",Telefon:"500600700","Kod roli":"BARMAN",
      "Rodzaj współpracy":"Umowa zlecenie","Stawka godzinowa":"45,50",Waluta:"PLN",
      "Dostępny od":"2026-09-01","Dostępny do":"2026-09-30",Aktywna:"TAK",
    }],
  }));

  assert.deepEqual(parsed.roleCategories.map(category=>category.code),["SALA","BAR"]);
  assert.deepEqual(parsed.roles.map(role=>[role.code,role.categoryCode]),[["KELNER","SALA"],["HOST","SALA"],["BARMAN","BAR"]]);
  assert.equal(parsed.employees[0].employmentStage,"PROBATION");
  assert.equal(parsed.employees[0].probationEnd,"2026-09-30");
  assert.deepEqual(parsed.employees[0].backupRoles,[{roleCode:"HOST",priority:1}]);
  assert.deepEqual(parsed.employeeRoles.map(role=>[role.roleCode,role.assignmentMode,role.backupPriority]),[["KELNER","STANDARD","0"],["HOST","BACKUP","1"]]);
  assert.equal(parsed.adHocWorkers[0].roleCode,"BARMAN");
  assert.equal(parsed.adHocWorkers[0].baseRateMinor,"4550");
  assert.equal(parsed.adHocWorkers[0].availableFrom,"2026-09-01");
});

test("Excel-native serial dates from the downloaded quick-start workbook stay ISO calendar dates",async()=>{
  const parsed=await readMatrixWorkbook(workbookFile({
    Pracownicy:[{
      Imię:"Anna",Nazwisko:"Próbna","Kod roli":"KELNER",
      "Koniec okresu próbnego":46294,"Rodzaj umowy":"ZLECENIE",
    }],
    "Pula ad-hoc":[{
      "Imię i nazwisko":"Jan Adhoc",Telefon:"500600700","Kod roli":"BARMAN",
      "Dostępny od":46266,"Dostępny do":46285,Aktywna:"TAK",
    }],
  }));

  assert.equal(parsed.employees[0].probationEnd,"2026-09-29");
  assert.equal(parsed.adHocWorkers[0].availableFrom,"2026-09-01");
  assert.equal(parsed.adHocWorkers[0].availableTo,"2026-09-20");
});

test("an ad-hoc worker without a role points to the exact workbook sheet, row and column",async()=>{
  await assert.rejects(
    readMatrixWorkbook(workbookFile({
      "Pula ad-hoc":[
        {"Imię i nazwisko":"Jan Poprawny",Telefon:"500600700","Kod roli":"BARMAN",Aktywna:"TAK"},
        {"Imię i nazwisko":"Jerzy","Kod roli":"",Aktywna:"TAK"},
      ],
    })),
    /Pula ad-hoc • wiersz 3 • kolumna „Rola”: wybierz rolę z zakładki „Role” albo usuń ten niepełny wiersz/,
  );
});

test("polished Google Sheets-ready labels import without silent semantic changes",async()=>{
  const parsed=await readMatrixWorkbook(workbookFile({
    "Kategorie grafików":[{"Nazwa\nWYMAGANE":"Sala","Kolor\nOPCJONALNE":"Fioletowy — #7257D8","Aktywna\nWYMAGANE":"☑ Tak"}],
    Pracownicy:[{
      "Imię\nWYMAGANE":"Anna","Nazwisko\nWYMAGANE":"Próbna","Kod roli\nWYMAGANE":"KELNER",
      "Etap zatrudnienia\nWYMAGANE":"Okres próbny","Rodzaj umowy\nWYMAGANE":"Umowa o pracę — część etatu",
      "Koniec okresu próbnego\nWARUNKOWE":"2026-09-30","Bez weekendów\nOPCJONALNE":"☐ Nie","Aktywny\nWYMAGANE":"☑ Tak",
    }],
    "Pula ad-hoc":[{"Imię\nWYMAGANE":"Jan","Nazwisko\nWYMAGANE":"Kowalski","Telefon\nWYMAGANE":"500600700","Kod roli\nWYMAGANE":"BARMAN","Aktywna\nWYMAGANE":"☑ Tak"}],
  }));

  assert.equal(parsed.roleCategories[0].color,"#7257D8");
  assert.equal(parsed.employees[0].employmentStage,"PROBATION");
  assert.equal(parsed.employees[0].contractType,"CZESC_ETATU");
  assert.equal(parsed.employees[0].active,true);
  assert.equal(parsed.employees[0].noWeekends,false);
  assert.equal(parsed.adHocWorkers[0].displayName,"Jan Kowalski");
});

test("probation and ad-hoc errors identify the exact field that must be completed",async()=>{
  await assert.rejects(
    readMatrixWorkbook(workbookFile({Pracownicy:[{Imię:"Anna",Nazwisko:"Próbna","Rola podstawowa":"Kelner [KELNER]","Etap zatrudnienia":"Okres próbny"}]})),
    /Pracownicy • wiersz 2 • kolumna „Koniec okresu próbnego”/,
  );
  await assert.rejects(
    readMatrixWorkbook(workbookFile({"Pula ad-hoc":[{Imię:"Jan",Nazwisko:"Adhoc",Rola:"Barman [BARMAN]"}]})),
    /Pula ad-hoc • wiersz 2 • kolumna „Telefon”/,
  );
});

test("unknown employment stage points to the exact sheet row and column",async()=>{
  await assert.rejects(
    readMatrixWorkbook(workbookFile({Pracownicy:[
      {Imię:"Anna",Nazwisko:"Poprawna","Etap zatrudnienia":"Stała współpraca"},
      {Imię:"Ewa",Nazwisko:"Błędna","Etap zatrudnienia":"OKRES TESTOWY"},
    ]})),
    /Pracownicy • wiersz 3 • kolumna „Etap zatrudnienia”: wartość „OKRES TESTOWY” jest nieprawidłowa/,
  );
});

test("simplified workbook keeps one employee source and makes every additional role fallback",async()=>{
  const parsed=await readMatrixWorkbook(workbookFile({
    Firma:[{"Waluta":"PLN","Strefa czasowa":"Europe/Warsaw","Minimalny odpoczynek (godz.)":"11","Maks. zmian jednego pracownika na dobę":"1","Brak wpisanej dostępności oznacza dostępność":"TAK"}],
    "Kategorie grafików":[{Kod:"SALA",Nazwa:"Sala",Aktywna:"TAK"}],
    Role:[
      {Kod:"KELNER",Nazwa:"Kelner","Kategoria grafiku":"Sala [SALA]",Aktywna:"TAK"},
      {Kod:"HOST",Nazwa:"Host","Kategoria grafiku":"Sala [SALA]",Aktywna:"TAK"},
    ],
    Lokale:[{Kod:"KRUCZA",Nazwa:"Krucza","Strefa czasowa":"Europe/Warsaw",Aktywna:"TAK"}],
    Obowiązki:[{Kod:"KASA",Nazwa:"Obsługa kasy",Aktywna:"TAK"}],
    Pracownicy:[{
      "Numer pracownika":"GP-067",Aktywny:"TAK",Imię:"Tejlor",Nazwisko:"Słift",
      "Rola podstawowa":"Kelner [KELNER]","Rola dodatkowa 1":"Host [HOST]",
      "Lokal pracy 1":"Krucza [KRUCZA]","Kompetencja dodatkowa 1":"Obsługa kasy [KASA]",
      "Etap zatrudnienia":"Stała współpraca","Zatrudniony od":"2026-01-01",
      "Miesięczny cel godzin":"180","Twardy limit miesięczny godzin":"220","Limit tygodniowy godzin":"48",
      "Maks. kolejnych dni":"6","Rodzaj umowy":"Umowa o pracę","Zgoda na nadgodziny":"NIE",
    }],
    Zmiany:[{Kod:"KRUCZA_WIECZOR",Nazwa:"Wieczór",Lokal:"Krucza [KRUCZA]",Od:"18:00",Do:"03:00","Kończy się następnego dnia":"TAK","Dni tygodnia":"1,2",Aktywna:"TAK"}],
    Obsada:[{Zmiana:"Wieczór [KRUCZA_WIECZOR]",Rola:"Host [HOST]","Obowiązek (opcjonalnie)":"Obsługa kasy [KASA]","Liczba osób":"1",Aktywna:"TAK"}],
  }));

  assert.equal(parsed.settings.minimumRestMinutes,"660");
  assert.equal(parsed.roles[0].categoryCode,"SALA");
  assert.equal(parsed.employees[0].primaryRoleCode,"KELNER");
  assert.deepEqual(parsed.employees[0].backupRoles,[{roleCode:"HOST",priority:1}]);
  assert.deepEqual(parsed.employees[0].locationCodes,["KRUCZA"]);
  assert.deepEqual(parsed.employees[0].dutyCodes,["KASA"]);
  assert.equal(parsed.staffingRules[0].shiftCode,"KRUCZA_WIECZOR");
  assert.equal(parsed.staffingRules[0].roleCode,"HOST");
  assert.equal(parsed.staffingRules[0].dutyCode,"KASA");
});

test("legacy technical non-primary STANDARD role is canonicalized to BACKUP",async()=>{
  const parsed=await readMatrixWorkbook(workbookFile({
    Role:[{Kod:"KELNER",Nazwa:"Kelner"},{Kod:"HOST",Nazwa:"Host"}],
    "Role pracowników":[{"Numer pracownika":"GP-067","Kod roli":"HOST",Podstawowa:"NIE","Sposób użycia":"STANDARD","Priorytet rezerwowy":"7",Aktywna:"TAK"}],
  }));
  assert.equal(parsed.employeeRoles[0].assignmentMode,"BACKUP");
  assert.equal(parsed.employeeRoles[0].backupPriority,"7");
});
