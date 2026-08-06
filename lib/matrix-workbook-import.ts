export type MatrixWorkbookPayload = {
  settings: Record<string, unknown>;
  roles: Record<string, unknown>[];
  locations: Record<string, unknown>[];
  duties: Record<string, unknown>[];
  scenarios: Record<string, unknown>[];
  strategies: Record<string, unknown>[];
  strategyObjectives: Record<string, unknown>[];
  scenarioStrategies: Record<string, unknown>[];
  payRules: Record<string, unknown>[];
  scenarioPayRuleOverrides: Record<string, unknown>[];
  scenarioBudgets: Record<string, unknown>[];
  employees: Record<string, unknown>[];
  employeeDuties: Record<string, unknown>[];
  employeeRoles: Record<string, unknown>[];
  employeeLocationsDetailed: Record<string, unknown>[];
  employeeCapabilities: Record<string, unknown>[];
  timeConstraints: Record<string, unknown>[];
  shifts: Record<string, unknown>[];
  staffingRules: Record<string, unknown>[];
  roleDuties: Record<string, unknown>[];
  _sourceLayout: "APPS_SCRIPT_BASE" | "GRAFIK_PRO_TEMPLATE";
};

function importCell(row:Record<string,unknown>,...names:string[]){
  const key=Object.keys(row).find(candidate=>names.some(name=>candidate.trim().toLocaleLowerCase("pl-PL")===name.toLocaleLowerCase("pl-PL")));
  return key===undefined?"":String(row[key]??"").trim();
}

function hasImportColumn(row:Record<string,unknown>,...names:string[]){
  return Object.keys(row).some(candidate=>names.some(name=>candidate.trim().toLocaleLowerCase("pl-PL")===name.toLocaleLowerCase("pl-PL")));
}

function importBoolean(value:string,defaultValue=false){
  if(!value)return defaultValue;
  return ["1","tak","true","yes","x"].includes(value.toLocaleLowerCase("pl-PL"));
}

function importList(value:string){return value.split(/[;,|]/).map(item=>item.trim()).filter(Boolean);}

function importDays(value:string){
  const labels:Record<string,number>={pon:1,wt:2,sr:3,śr:3,czw:4,pt:5,sob:6,nd:7,nie:7,niedz:7};
  return importList(value).map(item=>Number(item)||labels[item.toLocaleLowerCase("pl-PL")]).filter(day=>Number.isInteger(day)&&day>=1&&day<=7);
}

function importJson(value:string){
  if(!value)return {};
  try{return JSON.parse(value) as Record<string,unknown>;}
  catch{return {_invalidJson:value};}
}

function importMoneyMinor(value:string){
  if(!value)return "";
  const normalized=value.replace(/\s/g,"").replace(",",".");
  return /^-?\d+(?:\.\d{1,2})?$/.test(normalized)?String(Math.round(Number(normalized)*100)):value;
}

function importPercentBasisPoints(value:string){
  if(!value)return "";
  const normalized=value.replace("%","").replace(",",".").trim();
  return /^-?\d+(?:\.\d+)?$/.test(normalized)?String(Math.round(Number(normalized)*100)):value;
}

function importMultiplierBasisPoints(value:string){
  if(!value)return "";
  const normalized=value.replace(",",".").trim();
  return /^-?\d+(?:\.\d+)?$/.test(normalized)?String(Math.round(Number(normalized)*10000)):value;
}

function automaticShiftPeriod(startsAt:string){
  const match=/^(\d{1,2}):/.exec(startsAt);
  if(!match)return "";
  const hour=Number(match[1]);
  return hour<12?"MORNING":hour<17?"MIDDLE":"EVENING";
}

export async function readMatrixWorkbook(file:File):Promise<MatrixWorkbookPayload>{
  const XLSX=await import("xlsx");
  const workbook=XLSX.read(await file.arrayBuffer(),{type:"array",cellDates:false});
  const rows=(names:string[])=>{
    const sheetName=workbook.SheetNames.find(name=>names.some(expected=>name.toLocaleLowerCase("pl-PL")===expected.toLocaleLowerCase("pl-PL")));
    return sheetName?XLSX.utils.sheet_to_json<Record<string,unknown>>(workbook.Sheets[sheetName],{defval:"",raw:false,dateNF:"yyyy-mm-dd"}):[];
  };
  const splitName=(value:string)=>{const parts=value.trim().split(/\s+/);return {firstName:parts.shift()??"",lastName:parts.join(" ")};};
  const normalizeContract=(value:string)=>{
    const key=value.toLocaleUpperCase("pl-PL").replace(/[^A-ZĄĆĘŁŃÓŚŹŻ0-9]/g,"");
    if(!key)return "";
    if(["UMOWAOPRACĘ","UMOWAOPRACE","UOP"].includes(key))return "UMOWA_O_PRACE";
    if(["UMOWAZLECENIE","ZLECENIE","UZ"].includes(key))return "ZLECENIE";
    if(["CZĘŚĆETATU","CZESCETATU"].includes(key))return "CZESC_ETATU";
    if(key==="B2B")return "B2B";
    if(["INNE","OTHER"].includes(key))return "INNE";
    return "";
  };
  const normalizeDate=(value:string)=>{
    const trimmed=value.trim();
    if(!trimmed)return "";
    if(/^\d{4}-\d{2}-\d{2}$/.test(trimmed))return trimmed;
    if(/^\d{5}(?:\.\d+)?$/.test(trimmed)){
      const parsed=XLSX.SSF.parse_date_code(Number(trimmed));
      if(parsed)return `${String(parsed.y).padStart(4,"0")}-${String(parsed.m).padStart(2,"0")}-${String(parsed.d).padStart(2,"0")}`;
    }
    const match=trimmed.match(/^(\d{1,2})[./-](\d{1,2})[./-](\d{2}|\d{4})$/);
    if(match){
      const year=match[3].length===2?2000+Number(match[3]):Number(match[3]);
      return `${String(year).padStart(4,"0")}-${String(Number(match[2])).padStart(2,"0")}-${String(Number(match[1])).padStart(2,"0")}`;
    }
    return trimmed;
  };

  const settingsRow=rows(["Firma","Ustawienia firmy","Company"])[0]??{};
  const settings={
    currency:importCell(settingsRow,"Waluta","currency").toUpperCase(),
    timezone:importCell(settingsRow,"Strefa czasowa","timezone"),
    minimumRestMinutes:importCell(settingsRow,"Minimalny odpoczynek (min)","minimumRestMinutes"),
    maximumShiftsPerDay:importCell(settingsRow,"Maks. zmian jednego pracownika na dobę","Maks. zmian dziennie","maximumShiftsPerDay"),
    missingAvailabilityMeansAvailable:importBoolean(importCell(settingsRow,"Brak dostępności oznacza dostępność","missingAvailabilityMeansAvailable")),
    requireOptimal:importBoolean(importCell(settingsRow,"Wymagaj wyniku optymalnego","requireOptimal")),
  };
  const namedRows=(sheetNames:string[])=>rows(sheetNames).map(row=>({
    code:importCell(row,"Kod","code").toUpperCase(),name:importCell(row,"Nazwa","name"),
    description:importCell(row,"Opis","description"),color:importCell(row,"Kolor","color"),
    sortOrder:importCell(row,"Kolejność","sortOrder"),active:importBoolean(importCell(row,"Aktywna","Aktywny","active"),true),
  }));
  const roles=namedRows(["Role","Roles"]);
  const locations=rows(["Lokale","Locations"]).map(row=>({
    code:importCell(row,"Kod","code").toUpperCase(),name:importCell(row,"Nazwa","name"),
    timezone:importCell(row,"Strefa czasowa","timezone"),sortOrder:importCell(row,"Kolejność","sortOrder"),
    active:importBoolean(importCell(row,"Aktywna","Aktywny","active"),true),
  }));
  const duties=namedRows(["Obowiązki","Obowiazki","Duties"]);
  const scenarios=rows(["Scenariusze","Scenarios"]).map(row=>({
    code:importCell(row,"Kod","code").toUpperCase(),name:importCell(row,"Nazwa","name"),
    description:importCell(row,"Opis","description"),color:importCell(row,"Kolor","color"),
    parentScenarioCode:importCell(row,"Kod nadrzędnego","parentScenarioCode").toUpperCase(),
    isDefault:importBoolean(importCell(row,"Domyślny","isDefault")),validFrom:normalizeDate(importCell(row,"Obowiązuje od","validFrom")),
    validTo:normalizeDate(importCell(row,"Obowiązuje do","validTo")),settingsOverrides:importJson(importCell(row,"Ustawienia JSON","settingsOverrides")),
    sortOrder:importCell(row,"Kolejność","sortOrder"),active:importBoolean(importCell(row,"Aktywny","Aktywna","active"),true),
  }));
  const strategies=rows(["Strategie","Strategies"]).map(row=>({
    code:importCell(row,"Kod","code").toUpperCase(),name:importCell(row,"Nazwa","name"),description:importCell(row,"Opis","description"),
    solverCode:importCell(row,"Kod silnika","solverCode"),solverOptions:importJson(importCell(row,"Opcje silnika JSON","solverOptions")),
    sortOrder:importCell(row,"Kolejność","sortOrder"),active:importBoolean(importCell(row,"Aktywna","active"),true),
  }));
  const strategyObjectives=rows(["Kryteria strategii","Strategy Objectives"]).map(row=>({
    strategyCode:importCell(row,"Kod strategii","strategyCode").toUpperCase(),tier:importCell(row,"Poziom","tier"),
    sortOrder:importCell(row,"Kolejność","sortOrder"),metricCode:importCell(row,"Miara","metricCode").toUpperCase(),
    direction:importCell(row,"Kierunek","direction").toUpperCase(),weight:importCell(row,"Waga","weight"),
    tolerance:importCell(row,"Tolerancja","tolerance"),parameters:importJson(importCell(row,"Parametry JSON","parameters")),
    active:importBoolean(importCell(row,"Aktywne","Aktywna","active"),true),
  }));
  const scenarioStrategies=rows(["Warianty scenariuszy","Scenario Strategies"]).map(row=>({
    scenarioCode:importCell(row,"Kod scenariusza","scenarioCode").toUpperCase(),strategyCode:importCell(row,"Kod strategii","strategyCode").toUpperCase(),
    sortOrder:importCell(row,"Kolejność","sortOrder"),objectiveOverrides:importJson(importCell(row,"Nadpisania celów JSON","objectiveOverrides")),
    solverOverrides:importJson(importCell(row,"Nadpisania silnika JSON","solverOverrides")),active:importBoolean(importCell(row,"Aktywne","Aktywna","active"),true),
  }));
  const payRules=rows(["Zasady płacowe","Zasady placowe","Pay Rules"]).map(row=>({
    code:importCell(row,"Kod","code").toUpperCase(),name:importCell(row,"Nazwa","name"),description:importCell(row,"Opis","description"),
    calculationMethod:importCell(row,"Sposób obliczania","calculationMethod").toUpperCase(),amountMinor:importMoneyMinor(importCell(row,"Kwota","amount")),
    rateMinorPerHour:importMoneyMinor(importCell(row,"Kwota za godzinę","ratePerHour")),percentBasisPoints:importPercentBasisPoints(importCell(row,"Procent","percent")),
    multiplierBasisPoints:importMultiplierBasisPoints(importCell(row,"Mnożnik","multiplier")),thresholdMinutes:importCell(row,"Próg minut","thresholdMinutes"),
    currency:importCell(row,"Waluta","currency").toUpperCase(),priority:importCell(row,"Priorytet","priority"),stackingGroup:importCell(row,"Grupa łączenia","stackingGroup"),
    stackingMode:importCell(row,"Sposób łączenia","stackingMode").toUpperCase(),days:importDays(importCell(row,"Dni","days")),
    localStart:importCell(row,"Od","localStart"),localEnd:importCell(row,"Do","localEnd"),endsNextDay:importBoolean(importCell(row,"Następny dzień","endsNextDay")),
    validFrom:normalizeDate(importCell(row,"Obowiązuje od","validFrom")),validTo:normalizeDate(importCell(row,"Obowiązuje do","validTo")),
    conditionExpression:importJson(importCell(row,"Warunek JSON","conditionExpression")),formulaExpression:importJson(importCell(row,"Formuła JSON","formulaExpression")),
    roleCodes:importList(importCell(row,"Kody ról","roleCodes")),dutyCodes:importList(importCell(row,"Kody obowiązków","dutyCodes")),
    locationCodes:importList(importCell(row,"Kody lokali","locationCodes")),shiftCodes:importList(importCell(row,"Kody zmian","shiftCodes")),
    sortOrder:importCell(row,"Kolejność","sortOrder"),active:importBoolean(importCell(row,"Aktywna","active"),true),
  }));
  const scenarioPayRuleOverrides=rows(["Dodatki scenariuszy","Scenario Pay Rules"]).map(row=>({
    scenarioCode:importCell(row,"Kod scenariusza","scenarioCode").toUpperCase(),payRuleCode:importCell(row,"Kod zasady","payRuleCode").toUpperCase(),
    enabled:importBoolean(importCell(row,"Włączona","enabled"),true),amountMinor:importMoneyMinor(importCell(row,"Kwota","amount")),
    rateMinorPerHour:importMoneyMinor(importCell(row,"Kwota za godzinę","ratePerHour")),percentBasisPoints:importPercentBasisPoints(importCell(row,"Procent","percent")),
    multiplierBasisPoints:importMultiplierBasisPoints(importCell(row,"Mnożnik","multiplier")),formulaExpression:importJson(importCell(row,"Formuła JSON","formulaExpression")),
  }));
  const scenarioBudgets=rows(["Budżety scenariuszy","Budzety scenariuszy","Scenario Budgets"]).map(row=>({
    scenarioCode:importCell(row,"Kod scenariusza","scenarioCode").toUpperCase(),budgetMonth:normalizeDate(importCell(row,"Miesiąc","budgetMonth")),
    locationCode:importCell(row,"Kod lokalu","locationCode").toUpperCase(),roleCode:importCell(row,"Kod roli","roleCode").toUpperCase(),
    dutyCode:importCell(row,"Kod obowiązku","dutyCode").toUpperCase(),operation:importCell(row,"Operacja","operation").toUpperCase(),
    amountMinor:importMoneyMinor(importCell(row,"Budżet","amount")),multiplierBasisPoints:importMultiplierBasisPoints(importCell(row,"Mnożnik","multiplier")),
    currency:importCell(row,"Waluta","currency").toUpperCase(),hardLimit:importBoolean(importCell(row,"Twardy limit","hardLimit")),
    warningPercent:importCell(row,"Próg ostrzeżenia (%)","warningPercent"),
  }));

  const employeeRows=rows(["Pracownicy","Employees","BAZA_PRACOWNIKÓW"]);
  const functionRows=rows(["FUNKCJE_DODATKOWE"]);
  const dictionaryRows=rows(["Słowniki","Slowniki"]);
  const dutyCodes=[...new Set([
    ...functionRows.map(row=>importCell(row,"KOD")),
    ...dictionaryRows.filter(row=>importCell(row,"TYP").toLocaleUpperCase("pl-PL")==="OBOWIĄZEK").map(row=>importCell(row,"KOD")),
  ].filter(Boolean))];
  const sourceEmployeeLayout=employeeRows.some(row=>Boolean(importCell(row,"PRACOWNIK_ID*","IMIĘ_I_NAZWISKO*")));
  const employees=employeeRows.map(row=>{
    const combinedName=splitName(importCell(row,"IMIĘ_I_NAZWISKO*","IMIĘ_I_NAZWISKO"));
    const sourceEmployeeNo=importCell(row,"PRACOWNIK_ID*","PRACOWNIK_ID");
    const locationColumns=Object.keys(row).filter(key=>/(?:_STANDARD|_NADGODZINY)$/i.test(key));
    const locationGrants=Array.from(new Set(locationColumns.map(key=>key.replace(/_(?:STANDARD|NADGODZINY)$/i,"")))).map(code=>({
      code,
      standardAllowed:importBoolean(importCell(row,`${code}_STANDARD`)),
      overtimeAllowed:importBoolean(importCell(row,`${code}_NADGODZINY`)),
      homeLocation:false,
    }));
    const baseLocation=importCell(row,"LOKALIZACJA_BAZOWA*","LOKALIZACJA_BAZOWA","Lokal bazowy","Kod lokalu bazowego");
    const sourceLocationGrants=locationGrants.map(grant=>({
      ...grant,
      standardAllowed:grant.standardAllowed||grant.code.toLocaleUpperCase("pl-PL")===baseLocation.toLocaleUpperCase("pl-PL"),
      homeLocation:grant.code.toLocaleUpperCase("pl-PL")===baseLocation.toLocaleUpperCase("pl-PL"),
    })).filter(grant=>grant.standardAllowed||grant.overtimeAllowed||grant.homeLocation);
    if(baseLocation&&!sourceLocationGrants.some(grant=>grant.code.toLocaleUpperCase("pl-PL")===baseLocation.toLocaleUpperCase("pl-PL"))){
      sourceLocationGrants.push({code:baseLocation,standardAllowed:true,overtimeAllowed:false,homeLocation:true});
    }
    const nominalHours=importCell(row,"Nominał godzin","nominalHours","GODZINY_MIESIĘCZNE*","GODZINY_MIESIĘCZNE");
    const contractType=normalizeContract(importCell(row,"Rodzaj umowy","contractType","TYP_UMOWY*","TYP_UMOWY"));
    const employee:Record<string,unknown> = {
      employeeNo:sourceEmployeeLayout&&!/^GP-\d+$/i.test(sourceEmployeeNo)?"":sourceEmployeeNo||importCell(row,"Numer pracownika","employeeNo"),
      sourceEmployeeNo:sourceEmployeeNo||undefined,
      firstName:importCell(row,"Imię","firstName")||combinedName.firstName,lastName:importCell(row,"Nazwisko","lastName")||combinedName.lastName,
      email:importCell(row,"E-mail","Email","EMAIL*"),primaryRoleCode:importCell(row,"Kod roli","primaryRoleCode","ROLA_GŁÓWNA*","ROLA_GŁÓWNA"),
      locationCodes:locationColumns.length?sourceLocationGrants.filter(grant=>grant.standardAllowed).map(grant=>grant.code):importList(importCell(row,"Kody lokali","locationCodes")),
      employmentStart:normalizeDate(importCell(row,"Zatrudniony od","employmentStart","DATA_ZATRUDNIENIA_OD*","DATA_ZATRUDNIENIA_OD")),employmentEnd:normalizeDate(importCell(row,"Zatrudniony do","employmentEnd","DATA_ZATRUDNIENIA_DO")),
      nominalHours,maximumMonthlyHours:importCell(row,"Limit miesięczny godzin","maximumMonthlyHours"),
      maximumWeeklyHours:importCell(row,"Limit tygodniowy godzin","maximumWeeklyHours","MAX_GODZIN_TYGODNIOWO"),maximumConsecutiveDays:importCell(row,"Maks. kolejnych dni","maximumConsecutiveDays","MAX_DNI_Z_RZĘDU"),
      minimumRestHours:importCell(row,"Minimalny odpoczynek godzin","minimumRestHours","MIN_ODPOCZYNEK_H"),baseRate:importCell(row,"Stawka godzinowa","baseRate"),contractType,
      dutyCodes,
      employmentFraction:importCell(row,"ETAT*","ETAT","employmentFraction"),
      workTimePolicy:importCell(row,"Polityka czasu pracy","workTimePolicy","POLITYKA_CZASU_PRACY").toUpperCase(),
    };
    if(hasImportColumn(row,"Miesiąc preferencji","preferenceMonth"))employee.preferenceMonth=normalizeDate(importCell(row,"Miesiąc preferencji","preferenceMonth"));
    const shiftPeriodPreferences:Record<string,string>={};
    if(hasImportColumn(row,"Preferencja rano","morningPreference"))shiftPeriodPreferences.MORNING=importCell(row,"Preferencja rano","morningPreference")||"INHERIT";
    if(hasImportColumn(row,"Preferencja środek","middlePreference"))shiftPeriodPreferences.MIDDLE=importCell(row,"Preferencja środek","middlePreference")||"INHERIT";
    if(hasImportColumn(row,"Preferencja wieczór","eveningPreference"))shiftPeriodPreferences.EVENING=importCell(row,"Preferencja wieczór","eveningPreference")||"INHERIT";
    if(Object.keys(shiftPeriodPreferences).length)employee.shiftPeriodPreferences=shiftPeriodPreferences;
    if(locationColumns.length)employee.locationGrants=sourceLocationGrants;
    if(hasImportColumn(row,"Aktywny","active","AKTYWNY*"))employee.active=importBoolean(importCell(row,"Aktywny","active","AKTYWNY*"),true);
    if(hasImportColumn(row,"Tylko rano","onlyMorning","TYLKO_RANO"))employee.onlyMorning=importBoolean(importCell(row,"Tylko rano","onlyMorning","TYLKO_RANO"));
    if(hasImportColumn(row,"Tylko popołudnie","Tylko wieczór","onlyEvening","TYLKO_POPOŁUDNIE"))employee.onlyEvening=importBoolean(importCell(row,"Tylko popołudnie","Tylko wieczór","onlyEvening","TYLKO_POPOŁUDNIE"));
    if(hasImportColumn(row,"Bez weekendów","noWeekends","BEZ_WEEKENDÓW"))employee.noWeekends=importBoolean(importCell(row,"Bez weekendów","noWeekends","BEZ_WEEKENDÓW"));
    return employee;
  });

  const dutyColumnAliases:Record<string,string[]>={
    EVENT_ROTACYJNY:["ROTACYJNY","EVENT"],
  };
  const inlineEmployeeDuties=dutyCodes.length?employeeRows.flatMap((row,index)=>dutyCodes.filter(code=>importBoolean(importCell(row,code,...(dutyColumnAliases[code.toLocaleUpperCase("pl-PL")]??[])))).map(code=>({
    employeeNo:employees[index].employeeNo,email:employees[index].email,dutyCode:code,roleCode:employees[index].primaryRoleCode,active:true,
  }))):[];

  const shiftRows=rows(["Zmiany","Shifts","DEFINICJE_ZMIAN"]);
  const sourceShiftLayout=shiftRows.some(row=>Boolean(importCell(row,"LOKALIZACJA_ID","GRUPA_DNI","ZMIANA_ID")));
  const shifts=shiftRows.map(row=>{
    const baseCode=importCell(row,"Kod","code","ZMIANA_ID");
    const group=importCell(row,"GRUPA_DNI");
    const sourceCode=sourceShiftLayout?`${baseCode}_${group}`:baseCode;
    const day=importCell(row,"DZIEŃ_TYGODNIA");
    const startsAt=importCell(row,"Od","startsAt","START");
    return {
      code:sourceCode,name:importCell(row,"Nazwa","name","NAZWA")+(group?` • ${group}`:""),locationCode:importCell(row,"Kod lokalu","locationCode","LOKALIZACJA_ID"),
      // Pora jest wyłącznie techniczną wartością pochodną. Użytkownik podaje
      // dokładne godziny, a import nigdy nie ufa ręcznemu MORNING/MIDDLE/EVENING.
      shiftPeriod:automaticShiftPeriod(startsAt),startsAt,endsAt:importCell(row,"Do","endsAt","KONIEC"),
      endsNextDay:importBoolean(importCell(row,"Następny dzień","endsNextDay","KONIEC_DZIEŃ_PLUS")),days:sourceShiftLayout?importDays(day):importDays(importCell(row,"Dni","days")),
      sortOrder:importCell(row,"Kolejność","sortOrder"),active:importBoolean(importCell(row,"Aktywna","active","AKTYWNA"),true),
    };
  });
  const groupedShifts=Array.from(new Map(shifts.map(shift=>[`${shift.locationCode}:${shift.code}:${shift.startsAt}:${shift.endsAt}`,shift])).values()).map(shift=>({
    ...shift,days:[...new Set(shifts.filter(candidate=>candidate.locationCode===shift.locationCode&&candidate.code===shift.code&&candidate.startsAt===shift.startsAt&&candidate.endsAt===shift.endsAt).flatMap(candidate=>candidate.days))].sort(),
  }));

  const staffingRows=rows(["Obsada","Staffing","MACIERZ_OBSADY"]);
  const staffingRules=staffingRows.map(row=>{
    const group=importCell(row,"GRUPA_DNI");
    const sourceShift=importCell(row,"ZMIANA_ID");
    return {
      scenarioCode:importCell(row,"Kod scenariusza","scenarioCode","SCENARIUSZ"),shiftCode:sourceShift?`${sourceShift}_${group}`:importCell(row,"Kod zmiany","shiftCode"),locationCode:importCell(row,"Kod lokalu","locationCode","LOKALIZACJA_ID"),
      roleCode:importCell(row,"Kod roli","roleCode","ROLA"),dutyCode:importCell(row,"Kod obowiązku","dutyCode","FUNKCJA_WYMAGANA"),operation:importCell(row,"Operacja","operation","OPERACJA").toUpperCase(),
      countValue:importCell(row,"Liczba osób","countValue","OPTYMALNIE_OSÓB","MIN_OSÓB"),active:importBoolean(importCell(row,"Aktywna","active","AKTYWNA"),true),
    };
  });
  const roleDuties=functionRows.length?functionRows.filter(row=>importBoolean(importCell(row,"AKTYWNA"),true)&&!["DOWOLNA",""].includes(importCell(row,"ROLA_WYMAGANA"))).map(row=>{
    const sourceMode=importCell(row,"TYP_PRZYDZIAŁU","ASSIGNMENT_MODE").toLocaleUpperCase("pl-PL");
    const assignmentMode=["WYMÓG_ZMIANY","REQUIRED"].includes(sourceMode)?"REQUIRED":["OPCJONALNY","OPTIONAL"].includes(sourceMode)?"OPTIONAL":"";
    return {
      roleCode:importCell(row,"ROLA_WYMAGANA"),dutyCode:importCell(row,"KOD"),assignmentMode,
      minimumCount:assignmentMode==="REQUIRED"?"1":"0",shiftObligation:assignmentMode==="REQUIRED",
      shiftPeriod:importCell(row,"PORA","SHIFT_PERIOD").toUpperCase(),active:true,
    };
  }):rows(["Role-Obowiązki","Role Duties","Obowiązki ról"]).map(row=>({
    roleCode:importCell(row,"Kod roli","roleCode"),dutyCode:importCell(row,"Kod obowiązku","dutyCode"),assignmentMode:importCell(row,"Znaczenie","assignmentMode").toUpperCase(),
    minimumCount:importCell(row,"Minimum","minimumCount"),shiftObligation:importBoolean(importCell(row,"Obowiązek zmianowy","shiftObligation")),
    shiftPeriod:importCell(row,"Pora","shiftPeriod").toUpperCase(),active:importBoolean(importCell(row,"Aktywne","active"),true),
  }));

  const employeeRoles=rows(["Role pracowników","Role pracownikow","Employee Roles"]).map(row=>({
    employeeNo:importCell(row,"Numer pracownika","employeeNo"),roleCode:importCell(row,"Kod roli","roleCode").toUpperCase(),
    isPrimary:importBoolean(importCell(row,"Podstawowa","isPrimary")),canLead:importBoolean(importCell(row,"Może zatwierdzać","canLead")),
    validFrom:normalizeDate(importCell(row,"Obowiązuje od","validFrom")),validTo:normalizeDate(importCell(row,"Obowiązuje do","validTo")),
    active:importBoolean(importCell(row,"Aktywna","active"),true),
  }));
  const employeeLocationsDetailed=rows(["Lokale pracowników","Lokale pracownikow","Employee Locations"]).map(row=>({
    employeeNo:importCell(row,"Numer pracownika","employeeNo"),locationCode:importCell(row,"Kod lokalu","locationCode").toUpperCase(),
    standardAllowed:importBoolean(importCell(row,"Zwykła praca","standardAllowed")),overtimeAllowed:importBoolean(importCell(row,"Dodatkowa praca","overtimeAllowed")),
    homeLocation:importBoolean(importCell(row,"Lokal bazowy","homeLocation")),validFrom:normalizeDate(importCell(row,"Obowiązuje od","validFrom")),
    validTo:normalizeDate(importCell(row,"Obowiązuje do","validTo")),active:importBoolean(importCell(row,"Aktywna","active"),true),
  }));
  const employeeCapabilities=rows(["Kompetencje pracowników","Kompetencje pracownikow","Employee Capabilities"]).map(row=>({
    employeeNo:importCell(row,"Numer pracownika","employeeNo"),dutyCode:importCell(row,"Kod obowiązku","dutyCode").toUpperCase(),
    roleCode:importCell(row,"Kod roli","roleCode").toUpperCase(),locationCode:importCell(row,"Kod lokalu","locationCode").toUpperCase(),
    validFrom:normalizeDate(importCell(row,"Obowiązuje od","validFrom")),validTo:normalizeDate(importCell(row,"Obowiązuje do","validTo")),
    active:importBoolean(importCell(row,"Aktywna","active"),true),
  }));
  // The detailed capability sheet is authoritative whenever it contains the
  // same employee + duty pair.  The convenience TAK/NIE columns in
  // "Pracownicy" must not create a second, role-scoped capability during a
  // round trip of the full company workbook.
  const employeeDuties=inlineEmployeeDuties.filter(inline=>!employeeCapabilities.some(detailed=>
    String(detailed.employeeNo??"").toLocaleUpperCase("pl-PL")===String(inline.employeeNo??"").toLocaleUpperCase("pl-PL")
      &&String(detailed.dutyCode??"").toLocaleUpperCase("pl-PL")===String(inline.dutyCode??"").toLocaleUpperCase("pl-PL")
  ));
  const timeConstraints=rows(["Dostępność","Dostepnosc","Availability"]).map(row=>({
    constraintId:importCell(row,"ID wpisu","constraintId"),employeeNo:importCell(row,"Numer pracownika","employeeNo"),
    kind:importCell(row,"Rodzaj","kind").toUpperCase(),startsAt:importCell(row,"Od","startsAt"),endsAt:importCell(row,"Do","endsAt"),
    note:importCell(row,"Notatka","note"),active:importBoolean(importCell(row,"Aktywny","Aktywna","active"),true),
  }));

  return {settings,roles,locations,duties,scenarios,strategies,strategyObjectives,scenarioStrategies,
    payRules,scenarioPayRuleOverrides,scenarioBudgets,employees,employeeDuties,employeeRoles,
    employeeLocationsDetailed,employeeCapabilities,timeConstraints,shifts:groupedShifts,staffingRules,roleDuties,
    _sourceLayout:sourceEmployeeLayout?"APPS_SCRIPT_BASE":"GRAFIK_PRO_TEMPLATE"};
}
