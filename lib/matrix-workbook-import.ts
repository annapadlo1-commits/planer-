export type MatrixWorkbookPayload = {
  employees: Record<string, unknown>[];
  employeeDuties: Record<string, unknown>[];
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
  const employeeDuties=dutyCodes.length?employeeRows.flatMap((row,index)=>dutyCodes.filter(code=>importBoolean(importCell(row,code,...(dutyColumnAliases[code.toLocaleUpperCase("pl-PL")]??[])))).map(code=>({
    employeeNo:employees[index].employeeNo,email:employees[index].email,dutyCode:code,roleCode:employees[index].primaryRoleCode,active:true,
  }))):[];

  const shiftRows=rows(["Zmiany","Shifts","DEFINICJE_ZMIAN"]);
  const sourceShiftLayout=shiftRows.some(row=>Boolean(importCell(row,"LOKALIZACJA_ID","GRUPA_DNI","ZMIANA_ID")));
  const shifts=shiftRows.map(row=>{
    const baseCode=importCell(row,"Kod","code","ZMIANA_ID");
    const group=importCell(row,"GRUPA_DNI");
    const sourceCode=sourceShiftLayout?`${baseCode}_${group}`:baseCode;
    const day=importCell(row,"DZIEŃ_TYGODNIA");
    return {
      code:sourceCode,name:importCell(row,"Nazwa","name","NAZWA")+(group?` • ${group}`:""),locationCode:importCell(row,"Kod lokalu","locationCode","LOKALIZACJA_ID"),
      shiftPeriod:importCell(row,"Pora","shiftPeriod","PORA").toUpperCase(),startsAt:importCell(row,"Od","startsAt","START"),endsAt:importCell(row,"Do","endsAt","KONIEC"),
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

  return {employees,employeeDuties,shifts:groupedShifts,staffingRules,roleDuties,
    _sourceLayout:sourceEmployeeLayout?"APPS_SCRIPT_BASE":"GRAFIK_PRO_TEMPLATE"};
}
