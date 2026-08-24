import {
  DEFAULT_STRATEGY_DESCRIPTIONS,
  DEFAULT_STRATEGY_SOLVER_CONTRACT,
} from "./solver-strategy-contract.ts";

export type MatrixWorkbookPayload = {
  settings: Record<string, unknown>;
  roleCategories: Record<string, unknown>[];
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
  adHocWorkers: Record<string, unknown>[];
  _workbook: {
    mode: "EMPTY_TEMPLATE" | "CURRENT_CONFIG_EXPORT" | "LEGACY";
    contractVersion: string;
    sourceMatrixVersionId: string;
  };
  _sourceLayout: "APPS_SCRIPT_BASE" | "GRAFIK_PRO_TEMPLATE";
};

export type WorkbookValidationIssue={sheet:string;row:number;column:string;value:string;code:string;message:string;fix:string};
export class MatrixWorkbookValidationError extends Error{
  issues:WorkbookValidationIssue[];
  constructor(issues:WorkbookValidationIssue[]){
    super(`Plik zawiera ${issues.length} ${issues.length===1?"błąd zależności":"błędów zależności"}. Popraw wskazane komórki i sprawdź plik ponownie.`);
    this.name="MatrixWorkbookValidationError";this.issues=issues;
  }
}

function normalizeImportHeader(value:string){
  return value.trim().replace(/\s*[\r\n]+\s*(?:WYMAGANE|OPCJONALNE|WARUNKOWE|SYSTEM)\s*$/iu,"").toLocaleLowerCase("pl-PL");
}

function importCell(row:Record<string,unknown>,...names:string[]){
  const key=Object.keys(row).find(candidate=>names.some(name=>normalizeImportHeader(candidate)===normalizeImportHeader(name)));
  return key===undefined?"":String(row[key]??"").trim();
}

function hasImportColumn(row:Record<string,unknown>,...names:string[]){
  return Object.keys(row).some(candidate=>names.some(name=>normalizeImportHeader(candidate)===normalizeImportHeader(name)));
}

function importBoolean(value:string,defaultValue=false){
  if(!value)return defaultValue;
  const normalized=value.replace(/[☑☐✓✔]/gu,"").trim().toLocaleLowerCase("pl-PL");
  return ["1","tak","true","yes","x"].includes(normalized);
}

function normalizeOvertimePolicy(value:string){
  const normalized=value.replace(/[☑☐✓✔]/gu,"").trim().toLocaleUpperCase("pl-PL");
  if(!normalized||["NIE","NEVER","0","FALSE"].includes(normalized))return "NEVER";
  if(["TYLKO PO ZATWIERDZENIU","PO ZATWIERDZENIU","APPROVAL_REQUIRED"].includes(normalized))return "APPROVAL_REQUIRED";
  if(["TAK","ALLOWED","1","TRUE"].includes(normalized))return "ALLOWED";
  return normalized;
}

function importList(value:string){return value.split(/[;,|]/).map(item=>item.trim()).filter(Boolean);}

export function normalizeWorkbookCode(value:string){
  const reference=value.match(/\[([^\]]+)\]\s*$/u)?.[1]??value;
  return reference.replace(/[Łł]/g,"L").normalize("NFKD").replace(/[\u0300-\u036f]/g,"")
    .toUpperCase().replace(/[^A-Z0-9]+/g,"_").replace(/^_+|_+$/g,"").slice(0,80);
}

const importCode=normalizeWorkbookCode;

function workbookCodeHash(value:string){
  let hash=0x811c9dc5;
  for(const character of value.normalize("NFKC")){
    hash^=character.codePointAt(0)??0;
    hash=Math.imul(hash,0x01000193)>>>0;
  }
  return hash.toString(16).toUpperCase().padStart(8,"0").slice(0,6);
}

function assignStableWorkbookCodes<T extends {code:string;name:string;sourceRow:number}>(items:T[],sheetName:string){
  const names=new Map<string,T>();
  for(const item of items){
    const key=item.name.normalize("NFKC").trim().toLocaleLowerCase("pl-PL"),previous=names.get(key);
    if(previous)throw new Error(`${sheetName} • wiersze ${previous.sourceRow} i ${item.sourceRow} • kolumna „Nazwa”: ta sama nazwa występuje dwa razy. Usuń duplikat albo nadaj elementom różne nazwy.`);
    names.set(key,item);
  }
  const groups=new Map<string,T[]>();
  for(const item of items){const group=groups.get(item.code)??[];group.push(item);groups.set(item.code,group);}
  for(const [base,group] of groups){
    if(!base)throw new Error(`${sheetName} • wiersz ${group[0].sourceRow} • kolumna „Nazwa”: nazwa nie pozwala utworzyć bezpiecznego kodu. Użyj co najmniej jednej litery A–Z lub cyfry.`);
    if(group.length===1)continue;
    for(const item of group){const suffix=`__${workbookCodeHash(item.name)}`;item.code=`${base.slice(0,80-suffix.length)}${suffix}`;}
    if(new Set(group.map(item=>item.code)).size!==group.length)throw new Error(`${sheetName} • kolumna „Kod”: nie udało się jednoznacznie rozstrzygnąć kolizji kodów. Nadaj tym elementom ręcznie różne stabilne kody.`);
  }
  return items;
}

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

const DEFAULT_SCENARIOS=[{
  code:"BASE",name:"Bazowy",description:"Standardowe zapotrzebowanie",color:"#C96F54",
  parentScenarioCode:"",isDefault:true,validFrom:"",validTo:"",settingsOverrides:{},sortOrder:"1",active:true,
}];
const DEFAULT_SHIFT_COLOR="#879681";

const DEFAULT_STRATEGIES=[
  {code:"BALANCED",name:"Zrównoważony",description:DEFAULT_STRATEGY_DESCRIPTIONS.BALANCED,solverCode:"CP_SAT",solverOptions:{maxTimeSeconds:120,randomSeed:0},sortOrder:"1",active:true},
  {code:"MIN_COST",name:"Minimalny koszt",description:DEFAULT_STRATEGY_DESCRIPTIONS.MIN_COST,solverCode:"CP_SAT",solverOptions:{maxTimeSeconds:120,randomSeed:0},sortOrder:"2",active:true},
  {code:"PREFERENCES",name:"Preferencje i równy podział",description:DEFAULT_STRATEGY_DESCRIPTIONS.PREFERENCES,solverCode:"CP_SAT",solverOptions:{maxTimeSeconds:120,randomSeed:0},sortOrder:"3",active:true},
];

const DEFAULT_OBJECTIVE_WEIGHTS:Record<string,Record<string,number>>={
  BALANCED:{UNFILLED:1_000_000,TOTAL_COST:1_000,PREFERENCE_VIOLATIONS:80_000,OVERTIME_MINUTES:250_000,NOMINAL_DEVIATION_MINUTES:30_000,LOAD_SPREAD_MINUTES:40_000,WEEKEND_SPREAD:25_000,BASELINE_CHANGES:20_000},
  MIN_COST:{UNFILLED:1_000_000,TOTAL_COST:10_000,PREFERENCE_VIOLATIONS:30_000,OVERTIME_MINUTES:500_000,NOMINAL_DEVIATION_MINUTES:20_000,LOAD_SPREAD_MINUTES:15_000,WEEKEND_SPREAD:10_000,BASELINE_CHANGES:10_000},
  PREFERENCES:{UNFILLED:1_000_000,TOTAL_COST:500,PREFERENCE_VIOLATIONS:250_000,OVERTIME_MINUTES:100_000,NOMINAL_DEVIATION_MINUTES:150_000,LOAD_SPREAD_MINUTES:200_000,WEEKEND_SPREAD:180_000,BASELINE_CHANGES:10_000},
};

function defaultObjectiveTier(strategyCode:string,metricCode:string){
  if(metricCode==="UNFILLED")return 1;
  if(strategyCode==="MIN_COST"){
    if(metricCode==="TOTAL_COST")return 2;
    if(metricCode==="OVERTIME_MINUTES")return 3;
    if(metricCode==="PREFERENCE_VIOLATIONS")return 4;
    if(["WEEKEND_SPREAD","LOAD_SPREAD_MINUTES","NOMINAL_DEVIATION_MINUTES"].includes(metricCode))return 5;
    return 6;
  }
  if(strategyCode==="PREFERENCES"){
    if(metricCode==="LOAD_SPREAD_MINUTES")return 2;
    if(metricCode==="NOMINAL_DEVIATION_MINUTES")return 3;
    if(metricCode==="PREFERENCE_VIOLATIONS")return 4;
    if(metricCode==="WEEKEND_SPREAD")return 5;
    if(metricCode==="TOTAL_COST")return 6;
    return 7;
  }
  return 2;
}

function defaultStrategyObjectives(){
  const metricOrder=["UNFILLED","TOTAL_COST","PREFERENCE_VIOLATIONS","OVERTIME_MINUTES","NOMINAL_DEVIATION_MINUTES","LOAD_SPREAD_MINUTES","WEEKEND_SPREAD","BASELINE_CHANGES"];
  return DEFAULT_STRATEGIES.flatMap(strategy=>metricOrder.map((metricCode,index)=>({
    strategyCode:strategy.code,tier:String(defaultObjectiveTier(strategy.code,metricCode)),sortOrder:String(index+1),
    metricCode,direction:"MINIMIZE",weight:String(DEFAULT_OBJECTIVE_WEIGHTS[strategy.code][metricCode]),tolerance:"0",parameters:{},active:true,
  })));
}

export async function readMatrixWorkbook(file:File):Promise<MatrixWorkbookPayload>{
  const XLSX=await import("xlsx");
  const workbook=XLSX.read(await file.arrayBuffer(),{type:"array",cellDates:false});
  const matchingSheetName=(names:string[])=>workbook.SheetNames.find(name=>names.some(expected=>name.toLocaleLowerCase("pl-PL")===expected.toLocaleLowerCase("pl-PL")));
  const rows=(names:string[])=>{
    const sheetName=matchingSheetName(names);
    // Keep Excel-native numbers untouched. In particular, SheetJS formats
    // serial dates incorrectly for this workbook when `raw:false` is combined
    // with `dateNF` (2026-09-29 became 2026-29-09). The field normalizers below
    // already understand Excel serial dates, numeric times and money values.
    return sheetName?XLSX.utils.sheet_to_json<Record<string,unknown>>(workbook.Sheets[sheetName],{defval:"",raw:true}):[];
  };
  const metaRows=rows(["_META","META"]);
  const meta=new Map(metaRows.map(row=>[importCell(row,"Klucz","key"),importCell(row,"Wartość","value")]));
  const rawWorkbookMode=meta.get("workbookMode");
  const workbookIdentity={
    mode:(rawWorkbookMode==="EMPTY_TEMPLATE"||rawWorkbookMode==="CURRENT_CONFIG_EXPORT"?rawWorkbookMode:"LEGACY") as "EMPTY_TEMPLATE"|"CURRENT_CONFIG_EXPORT"|"LEGACY",
    contractVersion:meta.get("contractVersion")??"1",
    sourceMatrixVersionId:meta.get("sourceMatrixVersionId")??"",
  };
  const splitName=(value:string)=>{const parts=value.trim().split(/\s+/);return {firstName:parts.shift()??"",lastName:parts.join(" ")};};
  const normalizeContract=(value:string)=>{
    const key=value.toLocaleUpperCase("pl-PL").replace(/[^A-ZĄĆĘŁŃÓŚŹŻ0-9]/g,"");
    if(!key)return "";
    if(["UMOWAOPRACĘ","UMOWAOPRACE","UOP"].includes(key))return "UMOWA_O_PRACE";
    if(["UMOWAZLECENIE","ZLECENIE","UZ"].includes(key))return "ZLECENIE";
    if(["CZĘŚĆETATU","CZESCETATU","UMOWAOPRACĘCZĘŚĆETATU","UMOWAOPRACECZESCETATU"].includes(key))return "CZESC_ETATU";
    if(key==="B2B")return "B2B";
    if(["INNE","OTHER"].includes(key))return "INNE";
    return "";
  };
  const normalizeDate=(value:string)=>{
    const trimmed=value.trim();
    if(!trimmed)return "";
    const yearFirst=trimmed.match(/^(\d{4})-(\d{2})-(\d{2})$/);
    if(yearFirst){
      const year=Number(yearFirst[1]),month=Number(yearFirst[2]),day=Number(yearFirst[3]);
      if(month>=1&&month<=12&&day>=1&&day<=31)return trimmed;
      // Backward compatibility for workbooks downloaded before the raw-cell
      // fix, where a formatted date could be persisted as yyyy-dd-mm.
      if(day>=1&&day<=12&&month>=1&&month<=31){
        return `${String(year).padStart(4,"0")}-${String(day).padStart(2,"0")}-${String(month).padStart(2,"0")}`;
      }
      return trimmed;
    }
    if(/^\d{5}(?:\.\d+)?$/.test(trimmed)){
      const parsed=new Date(Date.UTC(1899,11,30)+Math.floor(Number(trimmed))*86_400_000);
      if(!Number.isNaN(parsed.valueOf()))return parsed.toISOString().slice(0,10);
    }
    const match=trimmed.match(/^(\d{1,2})[./-](\d{1,2})[./-](\d{2}|\d{4})$/);
    if(match){
      const year=match[3].length===2?2000+Number(match[3]):Number(match[3]);
      return `${String(year).padStart(4,"0")}-${String(Number(match[2])).padStart(2,"0")}-${String(Number(match[1])).padStart(2,"0")}`;
    }
    return trimmed;
  };
  const normalizeTime=(value:string)=>{
    const trimmed=value.trim();
    if(!trimmed)return "";
    const clock=trimmed.match(/^(\d{1,2}):(\d{2})(?::\d{2}(?:[.,]\d+)?)?$/);
    if(clock){
      const hour=Number(clock[1]),minute=Number(clock[2]);
      if(hour>=0&&hour<=23&&minute>=0&&minute<=59)return `${String(hour).padStart(2,"0")}:${String(minute).padStart(2,"0")}`;
    }
    const numeric=trimmed.replace(",",".");
    if(/^\d+(?:\.\d+)?$/.test(numeric)){
      const fraction=((Number(numeric)%1)+1)%1;
      const minutes=Math.round(fraction*24*60)%(24*60);
      return `${String(Math.floor(minutes/60)).padStart(2,"0")}:${String(minutes%60).padStart(2,"0")}`;
    }
    const embedded=trimmed.match(/(?:^|[T\s])(\d{1,2}):(\d{2})(?::\d{2})?(?:$|[\sZ+-])/);
    if(embedded){
      const hour=Number(embedded[1]),minute=Number(embedded[2]);
      if(hour>=0&&hour<=23&&minute>=0&&minute<=59)return `${String(hour).padStart(2,"0")}:${String(minute).padStart(2,"0")}`;
    }
    return trimmed;
  };

  const settingsRow=rows(["Firma","Ustawienia firmy","Company"])[0]??{};
  const minimumRestHours=importCell(settingsRow,"Minimalny odpoczynek (godz.)");
  const settings={
    currency:importCell(settingsRow,"Waluta","currency").toUpperCase(),
    timezone:importCell(settingsRow,"Strefa czasowa","timezone"),
    minimumRestMinutes:importCell(settingsRow,"Minimalny odpoczynek (min)","minimumRestMinutes")||(minimumRestHours?String(Math.round(Number(minimumRestHours.replace(",","."))*60)):"660"),
    maximumShiftsPerDay:importCell(settingsRow,"Maks. zmian jednego pracownika na dobę","Maks. zmian dziennie","maximumShiftsPerDay"),
    standbyTiersPerRoleDay:importCell(settingsRow,"Poziomy rezerwy stand-by na rolę i dzień","Poziomy stand-by","standbyTiersPerRoleDay")||"0",
    missingAvailabilityMeansAvailable:importBoolean(importCell(settingsRow,"Brak wpisanej dostępności oznacza dostępność","Brak dostępności oznacza dostępność","missingAvailabilityMeansAvailable"),true),
    requireOptimal:importBoolean(importCell(settingsRow,"Wymagaj wyniku optymalnego","requireOptimal"),false),
  };
  const validatedDictionaryRows=(sheetNames:string[],entityName:string)=>{
    const sheetName=matchingSheetName(sheetNames)??sheetNames[0];
    return rows(sheetNames).map((row,index)=>({row,sourceRow:index+2})).filter(({row,sourceRow})=>{
      const suppliedCode=importCell(row,"Kod","code");
      const suppliedName=importCell(row,"Nazwa","name");
      // Exported templates can retain technical defaults (colour, order or
      // activity) in an otherwise empty row. Such a row is not a business
      // record and must never become an active dictionary item with code="".
      if(!suppliedCode&&!suppliedName)return false;
      if(suppliedCode&&!suppliedName){
        throw new Error(`${sheetName} • wiersz ${sourceRow} • kolumna „Nazwa”: uzupełnij nazwę ${entityName}.`);
      }
      return true;
    });
  };
  const normalizeColor=(value:string)=>/#[0-9A-F]{6}/i.exec(value)?.[0].toUpperCase()??value;
  const namedRows=(sheetNames:string[],entityName:string)=>assignStableWorkbookCodes(validatedDictionaryRows(sheetNames,entityName).map(({row,sourceRow},index)=>({
    code:importCode(importCell(row,"Kod","code")||importCell(row,"Nazwa","name")),name:importCell(row,"Nazwa","name"),
    description:importCell(row,"Opis","description"),color:normalizeColor(importCell(row,"Kolor","color")),
    sortOrder:importCell(row,"Kolejność","sortOrder")||String(index+1),active:importBoolean(importCell(row,"Aktywna","Aktywny","active"),true),sourceRow,
  })),matchingSheetName(sheetNames)??sheetNames[0]);
  const roleCategories=namedRows(["Kategorie grafików","Kategorie grafikow","Role categories"],"kategorii grafiku");
  const roles=assignStableWorkbookCodes(validatedDictionaryRows(["Role","Roles"],"roli").map(({row,sourceRow},index)=>({
    code:importCode(importCell(row,"Kod","code")||importCell(row,"Nazwa","name")),name:importCell(row,"Nazwa","name"),
    categoryCode:importCode(importCell(row,"Kategoria grafiku","Kod kategorii","Kategoria","categoryCode")),
    description:importCell(row,"Opis","description"),color:normalizeColor(importCell(row,"Kolor","color")),
    sortOrder:importCell(row,"Kolejność","sortOrder")||String(index+1),active:importBoolean(importCell(row,"Aktywna","Aktywny","active"),true),sourceRow,
  })),matchingSheetName(["Role","Roles"])??"Role");
  const standbyGroups=assignStableWorkbookCodes(validatedDictionaryRows(["Grupy rezerwy","Standby groups"],"grupy rezerwy").map(({row,sourceRow},index)=>({
    code:importCode(importCell(row,"Kod","code")||importCell(row,"Nazwa","name")),
    name:importCell(row,"Nazwa","name"),
    categoryCode:importCode(importCell(row,"Kategoria grafiku","Kod kategorii","categoryCode")),
    roleCodes:importList(importCell(row,"Role obsługiwane wspólnie","Kody ról","roleCodes")).map(importCode),
    tiers:Number(importCell(row,"Poziomy rezerwy","Poziomy","tiers")||"1"),sourceRow,index:index+1,
  })),matchingSheetName(["Grupy rezerwy","Standby groups"])??"Grupy rezerwy");
  const roleAliases=new Map<string,string>();
  for(const role of roles){
    const code=String(role.code??"");
    for(const alias of [code,String(role.name??"")])if(alias.trim())roleAliases.set(importCode(alias),code);
  }
  const normalizeRoleCode=(value:string)=>roleAliases.get(importCode(value))??importCode(value);
  const locations=assignStableWorkbookCodes(validatedDictionaryRows(["Lokale","Locations"],"lokalu").map(({row,sourceRow},index)=>({
    code:importCode(importCell(row,"Kod","code")||importCell(row,"Nazwa","name")),name:importCell(row,"Nazwa","name"),
    timezone:importCell(row,"Strefa czasowa","timezone"),sortOrder:importCell(row,"Kolejność","sortOrder")||String(index+1),
    active:importBoolean(importCell(row,"Aktywna","Aktywny","active"),true),sourceRow,
  })),matchingSheetName(["Lokale","Locations"])??"Lokale");
  const locationAliases=new Map<string,string>();
  for(const location of locations){
    const code=String(location.code??"");
    for(const alias of [code,String(location.name??"")])if(alias.trim())locationAliases.set(importCode(alias),code);
  }
  const normalizeLocationCode=(value:string)=>locationAliases.get(importCode(value))??importCode(value);
  const duties=namedRows(["Obowiązki","Obowiazki","Duties"],"obowiązku");
  const dutyAliases=new Map<string,string>();
  for(const duty of duties){const code=String(duty.code??"");for(const alias of [code,String(duty.name??"")])if(alias.trim())dutyAliases.set(importCode(alias),code);}
  const normalizeDutyCode=(value:string)=>dutyAliases.get(importCode(value))??importCode(value);
  const standbyAliases=new Map<string,string>();
  for(const group of standbyGroups){for(const alias of [String(group.code),String(group.name)])if(alias.trim())standbyAliases.set(importCode(alias),String(group.code));}
  const reserveRoleRows=rows(["Role grup rezerwy","Standby group roles"]);
  if(reserveRoleRows.length){
    const memberships=new Map<string,string[]>();
    reserveRoleRows.forEach((row,index)=>{
      const rawGroup=importCell(row,"Grupa rezerwy","Kod grupy","standbyGroupCode");
      const groupCode=standbyAliases.get(importCode(rawGroup))??importCode(rawGroup);
      const roleCode=normalizeRoleCode(importCell(row,"Rola","Kod roli","roleCode"));
      if(!standbyGroups.some(group=>group.code===groupCode))throw new Error(`Role grup rezerwy • wiersz ${index+2} • kolumna „Grupa rezerwy”: wartość „${rawGroup}” nie wskazuje grupy z arkusza „Grupy rezerwy”.`);
      if(!roles.some(role=>role.code===roleCode))throw new Error(`Role grup rezerwy • wiersz ${index+2} • kolumna „Rola”: wybierz rolę z arkusza „Role”.`);
      const values=memberships.get(groupCode)??[];if(!values.includes(roleCode))values.push(roleCode);memberships.set(groupCode,values);
    });
    for(const group of standbyGroups)group.roleCodes=memberships.get(String(group.code))??[];
  }
  const scenarios=rows(["Scenariusze","Scenarios"]).map(row=>({
    code:importCell(row,"Kod","code").toUpperCase(),name:importCell(row,"Nazwa","name"),
    description:importCell(row,"Opis","description"),color:normalizeColor(importCell(row,"Kolor","color")),
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
    localStart:normalizeTime(importCell(row,"Od","localStart")),localEnd:normalizeTime(importCell(row,"Do","localEnd")),endsNextDay:importBoolean(importCell(row,"Następny dzień","endsNextDay")),
    validFrom:normalizeDate(importCell(row,"Obowiązuje od","validFrom")),validTo:normalizeDate(importCell(row,"Obowiązuje do","validTo")),
    conditionExpression:importJson(importCell(row,"Warunek JSON","conditionExpression")),formulaExpression:importJson(importCell(row,"Formuła JSON","formulaExpression")),
    roleCodes:importList(importCell(row,"Kody ról","roleCodes")).map(normalizeRoleCode),dutyCodes:importList(importCell(row,"Kody obowiązków","dutyCodes")),
    locationCodes:importList(importCell(row,"Kody lokali","locationCodes")).map(normalizeLocationCode),shiftCodes:importList(importCell(row,"Kody zmian","shiftCodes")),
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
    locationCode:normalizeLocationCode(importCell(row,"Kod lokalu","locationCode")),roleCode:normalizeRoleCode(importCell(row,"Kod roli","roleCode")),
    dutyCode:importCell(row,"Kod obowiązku","dutyCode").toUpperCase(),operation:importCell(row,"Operacja","operation").toUpperCase(),
    amountMinor:importMoneyMinor(importCell(row,"Budżet","amount")),multiplierBasisPoints:importMultiplierBasisPoints(importCell(row,"Mnożnik","multiplier")),
    currency:importCell(row,"Waluta","currency").toUpperCase(),hardLimit:importBoolean(importCell(row,"Twardy limit","hardLimit")),
    warningPercent:importCell(row,"Próg ostrzeżenia (%)","warningPercent"),
  }));

  const employeeRows=rows(["Pracownicy","Employees","BAZA_PRACOWNIKÓW"]);
  const functionRows=rows(["FUNKCJE_DODATKOWE"]);
  const dictionaryRows=rows(["Słowniki","Slowniki"]);
  const dutyCodes=[...new Set([
    ...duties.map(duty=>String(duty.code??"")),
    ...functionRows.map(row=>importCell(row,"KOD")),
    ...dictionaryRows.filter(row=>importCell(row,"TYP").toLocaleUpperCase("pl-PL")==="OBOWIĄZEK").map(row=>importCell(row,"KOD")),
  ].filter(Boolean))];
  const sourceEmployeeLayout=employeeRows.some(row=>Boolean(importCell(row,"PRACOWNIK_ID*","IMIĘ_I_NAZWISKO*")));
  const normalizeEmploymentStage=(value:string,sourceRow:number)=>{
    const key=(value||"REGULAR").normalize("NFD").replace(/[\u0300-\u036f]/g,"").replace(/Ł/g,"L").replace(/ł/g,"l")
      .toLocaleUpperCase("pl-PL").replace(/[^A-Z0-9]+/g,"_").replace(/^_+|_+$/g,"");
    if(["REGULAR","STALA_WSPOLPRACA"].includes(key))return "REGULAR";
    if(["PROBATION","OKRES_PROBNY"].includes(key))return "PROBATION";
    if(["NOTICE","OKRES_WYPOWIEDZENIA"].includes(key))return "NOTICE";
    throw new Error(`Pracownicy • wiersz ${sourceRow} • kolumna „Etap zatrudnienia”: wartość „${value}” jest nieprawidłowa. Wybierz: Stała współpraca, Okres próbny albo Okres wypowiedzenia.`);
  };
  const employees=employeeRows.map((row,index)=>{
    const combinedName=splitName(importCell(row,"IMIĘ_I_NAZWISKO*","IMIĘ_I_NAZWISKO"));
    const sourceEmployeeNo=importCell(row,"PRACOWNIK_ID*","PRACOWNIK_ID");
    const locationColumns=Object.keys(row).filter(key=>/(?:_STANDARD|_NADGODZINY)$/i.test(key));
    const locationGrants=Array.from(new Set(locationColumns.map(key=>key.replace(/_(?:STANDARD|NADGODZINY)$/i,"")))).map(code=>({
      code,
      standardAllowed:importBoolean(importCell(row,`${code}_STANDARD`)),
      overtimeAllowed:importBoolean(importCell(row,`${code}_NADGODZINY`)),
      homeLocation:false,
    }));
    const baseLocation=normalizeLocationCode(importCell(row,"LOKALIZACJA_BAZOWA*","LOKALIZACJA_BAZOWA","Lokal bazowy","Kod lokalu bazowego"));
    const sourceLocationGrants=locationGrants.map(grant=>({
      ...grant,
      standardAllowed:grant.standardAllowed||grant.code.toLocaleUpperCase("pl-PL")===baseLocation.toLocaleUpperCase("pl-PL"),
      homeLocation:grant.code.toLocaleUpperCase("pl-PL")===baseLocation.toLocaleUpperCase("pl-PL"),
    })).filter(grant=>grant.standardAllowed||grant.overtimeAllowed||grant.homeLocation);
    if(baseLocation&&!sourceLocationGrants.some(grant=>grant.code.toLocaleUpperCase("pl-PL")===baseLocation.toLocaleUpperCase("pl-PL"))){
      sourceLocationGrants.push({code:baseLocation,standardAllowed:true,overtimeAllowed:false,homeLocation:true});
    }
    const simpleLocationCodes=[1,2,3].map(position=>normalizeLocationCode(importCell(row,`Lokal pracy ${position}`))).filter(Boolean);
    const simpleDutyCodes=[1,2,3].map(position=>normalizeDutyCode(importCell(row,`Kompetencja dodatkowa ${position}`))).filter(Boolean);
    const simpleDutyColumnsPresent=[1,2,3].some(position=>hasImportColumn(row,`Kompetencja dodatkowa ${position}`));
    const simpleBackupRoles=[1,2,3].map((position)=>({roleCode:normalizeRoleCode(importCell(row,`Rola dodatkowa ${position}`)),priority:position})).filter(entry=>entry.roleCode);
    const nominalHours=importCell(row,"Miesięczny cel godzin","Nominał godzin","nominalHours","GODZINY_MIESIĘCZNE*","GODZINY_MIESIĘCZNE");
    const contractType=normalizeContract(importCell(row,"Rodzaj umowy","contractType","TYP_UMOWY*","TYP_UMOWY"));
    const employee:Record<string,unknown> = {
      employeeNo:sourceEmployeeLayout&&!/^GP-\d+$/i.test(sourceEmployeeNo)?"":sourceEmployeeNo||importCell(row,"Numer pracownika","employeeNo"),
      sourceEmployeeNo:sourceEmployeeNo||undefined,
      firstName:importCell(row,"Imię","firstName")||combinedName.firstName,lastName:importCell(row,"Nazwisko","lastName")||combinedName.lastName,
      email:importCell(row,"E-mail","Email","EMAIL*"),primaryRoleCode:normalizeRoleCode(importCell(row,"Rola podstawowa","Kod roli","primaryRoleCode","ROLA_GŁÓWNA*","ROLA_GŁÓWNA")),
      locationCodes:simpleLocationCodes.length?simpleLocationCodes:locationColumns.length?sourceLocationGrants.filter(grant=>grant.standardAllowed).map(grant=>normalizeLocationCode(grant.code)):importList(importCell(row,"Kody lokali","locationCodes")).map(normalizeLocationCode),
      employmentStart:normalizeDate(importCell(row,"Zatrudniony od","employmentStart","DATA_ZATRUDNIENIA_OD*","DATA_ZATRUDNIENIA_OD")),employmentEnd:normalizeDate(importCell(row,"Zatrudniony do","employmentEnd","DATA_ZATRUDNIENIA_DO")),
      nominalHours,maximumMonthlyHours:importCell(row,"Twardy limit miesięczny godzin","Limit miesięczny godzin","maximumMonthlyHours"),
      maximumWeeklyHours:importCell(row,"Limit tygodniowy godzin","maximumWeeklyHours","MAX_GODZIN_TYGODNIOWO"),maximumConsecutiveDays:importCell(row,"Maks. kolejnych dni","maximumConsecutiveDays","MAX_DNI_Z_RZĘDU"),
      minimumRestHours:importCell(row,"Minimalny odpoczynek godzin","minimumRestHours","MIN_ODPOCZYNEK_H"),baseRate:importCell(row,"Stawka godzinowa","baseRate"),contractType,
      dutyCodes:simpleDutyColumnsPresent?simpleDutyCodes:dutyCodes,
      employmentFraction:importCell(row,"ETAT*","ETAT","employmentFraction"),
      workTimePolicy:importCell(row,"Polityka czasu pracy","workTimePolicy","POLITYKA_CZASU_PRACY").toUpperCase(),
      overtimePolicy:normalizeOvertimePolicy(importCell(row,"Zgoda na nadgodziny","overtimePolicy","ZGODA_NA_NADGODZINY")),
      employmentStage:normalizeEmploymentStage(importCell(row,"Etap zatrudnienia","employmentStage"),index+2),
      probationEnd:normalizeDate(importCell(row,"Koniec okresu próbnego","probationEnd")),
      backupRoles:simpleBackupRoles.length?simpleBackupRoles:importList(importCell(row,"Role rezerwowe (kolejność)","Role rezerwowe","backupRoles")).map((entry,index)=>{
        const [roleCode,priorityText]=entry.split(":").map(item=>item.trim());
        const parsedPriority=Number(priorityText||index+1);
        return {roleCode:normalizeRoleCode(roleCode),priority:Number.isInteger(parsedPriority)&&parsedPriority>0?parsedPriority:index+1};
      }).filter(entry=>entry.roleCode),
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
  const invalidEmployee=employees.map((employee,index)=>({employee,index,roles:[String(employee.primaryRoleCode??""),...((employee.backupRoles as Array<{roleCode?:string}>|undefined)??[]).map(role=>String(role.roleCode??""))].filter(Boolean)})).find(({employee,roles})=>
    !employee.primaryRoleCode
      ||(employee.employmentStage==="PROBATION"&&!employee.probationEnd)
      ||new Set(roles.map(role=>role.toLocaleUpperCase("pl-PL"))).size!==roles.length
  );
  if(invalidEmployee){
    const {employee,index,roles}=invalidEmployee;
    if(!employee.primaryRoleCode)throw new Error(`Pracownicy • wiersz ${index+2} • kolumna „Rola podstawowa”: wybierz dokładnie jedną rolę podstawową z listy.`);
    if(employee.employmentStage==="PROBATION"&&!employee.probationEnd)throw new Error(`Pracownicy • wiersz ${index+2} • kolumna „Koniec okresu próbnego”: wpisz datę RRRR-MM-DD, ponieważ etap zatrudnienia to „Okres próbny”.`);
    if(new Set(roles.map(role=>role.toLocaleUpperCase("pl-PL"))).size!==roles.length)throw new Error(`Pracownicy • wiersz ${index+2} • kolumny ról: ta sama rola została wpisana więcej niż raz. Pozostaw ją tylko jako podstawową albo tylko raz jako dodatkową.`);
  }

  const dutyColumnAliases:Record<string,string[]>={
    EVENT_ROTACYJNY:["ROTACYJNY","EVENT"],
  };
  const inlineEmployeeDuties=employeeRows.flatMap((row,index)=>{
    const configured=[1,2,3].map(position=>normalizeDutyCode(importCell(row,`Kompetencja dodatkowa ${position}`))).filter(Boolean);
    const legacy=dutyCodes.filter(code=>importBoolean(importCell(row,code,...(dutyColumnAliases[code.toLocaleUpperCase("pl-PL")]??[]))));
    return [...new Set([...configured,...legacy])].map(code=>({
      employeeNo:employees[index].employeeNo,email:employees[index].email,dutyCode:code,roleCode:employees[index].primaryRoleCode,active:true,
    }));
  });

  const shiftSheetAliases=["Zmiany","Shifts","DEFINICJE_ZMIAN"];
  const shiftSheetName=matchingSheetName(shiftSheetAliases)??"Zmiany";
  const shiftRows=rows(shiftSheetAliases);
  const sourceShiftLayout=shiftRows.some(row=>Boolean(importCell(row,"LOKALIZACJA_ID","GRUPA_DNI","ZMIANA_ID")));
  const shifts=shiftRows.map((row,index)=>{
    const baseCode=importCell(row,"Kod","code","ZMIANA_ID");
    const group=importCell(row,"GRUPA_DNI");
    const shiftName=importCell(row,"Nazwa","name","NAZWA");
    const locationCode=normalizeLocationCode(importCell(row,"Lokal","Kod lokalu","locationCode","LOKALIZACJA_ID"));
    const sourceCode=sourceShiftLayout?`${baseCode}_${group}`:importCode(baseCode)||importCode(`${locationCode}_${shiftName}`);
    const day=importCell(row,"DZIEŃ_TYGODNIA");
    const startsAt=normalizeTime(importCell(row,"Od","startsAt","START"));
    const color=normalizeColor(importCell(row,"Kolor","color"))||DEFAULT_SHIFT_COLOR;
    if(!/^#[0-9A-F]{6}$/i.test(color))throw new Error(`${shiftSheetName} • wiersz ${index+2} • kolumna „Kolor”: wpisz kolor z listy albo wartość #RRGGBB.`);
    return {
      code:sourceCode,name:shiftName+(group?` • ${group}`:""),locationCode,
      // Pora jest wyłącznie techniczną wartością pochodną. Użytkownik podaje
      // dokładne godziny, a import nigdy nie ufa ręcznemu MORNING/MIDDLE/EVENING.
      shiftPeriod:automaticShiftPeriod(startsAt),startsAt,endsAt:normalizeTime(importCell(row,"Do","endsAt","KONIEC")),
      endsNextDay:importBoolean(importCell(row,"Kończy się następnego dnia","Następny dzień","endsNextDay","KONIEC_DZIEŃ_PLUS")),days:sourceShiftLayout?importDays(day):importDays(importCell(row,"Dni tygodnia","Dni","days")),
      // „Kolejność” jest polem opcjonalnym i nie występuje w prostym pliku
      // startowym. Nigdy nie wysyłamy pustego tekstu do pola liczbowego w bazie;
      // stabilna kolejność wierszy jest bezpiecznym ustawieniem domyślnym.
      sortOrder:importCell(row,"Kolejność","sortOrder")||String(index+1),color:color.toUpperCase(),active:importBoolean(importCell(row,"Aktywna","active","AKTYWNA"),true),sourceRow:index+2,
    };
  });
  const overnightErrors=shifts.flatMap((shift,index)=>{
    if(!/^\d{2}:\d{2}$/.test(shift.startsAt)||!/^\d{2}:\d{2}$/.test(shift.endsAt))return [];
    const expectedEndsNextDay=shift.endsAt<=shift.startsAt;
    if(shift.endsNextDay===expectedEndsNextDay)return [];
    const expected=expectedEndsNextDay?"TAK":"NIE";
    return [`${shiftSheetName} • wiersz ${index+2} • ${shift.code||shift.name||"zmiana"} (${shift.startsAt}–${shift.endsAt}): pole „Następny dzień” powinno mieć wartość ${expected}.`];
  });
  if(overnightErrors.length){
    throw new Error(`Nie można sprawdzić pliku: ${overnightErrors.length} ${overnightErrors.length===1?"zmiana ma":"zmiany mają"} niespójne oznaczenie przejścia przez północ.\n${overnightErrors.join("\n")}`);
  }
  const groupedShifts=Array.from(new Map(shifts.map(shift=>[`${shift.locationCode}:${shift.code}:${shift.startsAt}:${shift.endsAt}`,shift])).values()).map(shift=>({
    ...shift,days:[...new Set(shifts.filter(candidate=>candidate.locationCode===shift.locationCode&&candidate.code===shift.code&&candidate.startsAt===shift.startsAt&&candidate.endsAt===shift.endsAt).flatMap(candidate=>candidate.days))].sort(),
  }));
  const shiftAliases=new Map<string,string>();
  for(const shift of groupedShifts){
    const code=String(shift.code??"");
    for(const alias of [code,String(shift.name??"")])if(alias.trim())shiftAliases.set(importCode(alias),code);
  }

  const staffingRows=rows(["Obsada","Staffing","MACIERZ_OBSADY"]);
  const staffingRules=staffingRows.map((row,index)=>{
    const group=importCell(row,"GRUPA_DNI");
    const sourceShift=importCell(row,"ZMIANA_ID");
    return {
      scenarioCode:importCell(row,"Kod scenariusza","scenarioCode","SCENARIUSZ"),shiftCode:sourceShift?`${sourceShift}_${group}`:importCode(importCell(row,"Zmiana","Kod zmiany","shiftCode")),locationCode:normalizeLocationCode(importCell(row,"Kod lokalu","locationCode","LOKALIZACJA_ID")),
      roleCode:normalizeRoleCode(importCell(row,"Rola","Kod roli","roleCode","ROLA")),dutyCode:normalizeDutyCode(importCell(row,"Obowiązek (opcjonalnie)","Kod obowiązku","dutyCode","FUNKCJA_WYMAGANA")),
      // W prostym imporcie pracodawca podaje docelową liczbę osób. Pole
      // „Operacja” jest technicznym detalem importu pełnej kopii, dlatego jego
      // brak oznacza bezpieczne i intuicyjne SET zamiast blokować cały plik.
      operation:importCell(row,"Operacja","operation","OPERACJA").toUpperCase()||"SET",
      countValue:importCell(row,"Liczba osób","countValue","OPTYMALNIE_OSÓB","MIN_OSÓB"),active:importBoolean(importCell(row,"Aktywna","active","AKTYWNA"),true),
      sourceMetadata:{source:"MATRIX_WORKBOOK_IMPORT"},sourceRow:index+2,
    };
  });
  const competencyRows=functionRows.length?functionRows:rows(["Role-Obowiązki","Role Duties","Obowiązki ról"]);
  const competencySheet=functionRows.length?"FUNKCJE_DODATKOWE":matchingSheetName(["Role-Obowiązki","Role Duties","Obowiązki ról"])??"Role-Obowiązki";
  const roleDuties=competencyRows
    .map((row,index)=>({row,sourceRow:index+2}))
    .filter(({row})=>functionRows.length
      ?importBoolean(importCell(row,"AKTYWNA"),true)&&!["DOWOLNA",""].includes(importCell(row,"ROLA_WYMAGANA"))
      :true)
    .map(({row,sourceRow})=>{
      const assignmentModeValue=importCell(row,"Znaczenie","assignmentMode","TYP_PRZYDZIAŁU","ASSIGNMENT_MODE");
      const assignmentMode=assignmentModeValue.toLocaleUpperCase("pl-PL");
      const normalizedAssignmentMode=assignmentMode==="OPCJONALNY"?"OPTIONAL":assignmentMode;
      const assignmentModeColumn=functionRows.length?"TYP_PRZYDZIAŁU":"Znaczenie";
      const minimumCount=importCell(row,"Minimum","minimumCount");
      const shiftObligation=importBoolean(importCell(row,"Obowiązek zmianowy","shiftObligation"));
      const shiftPeriod=importCell(row,"Pora","shiftPeriod","PORA","SHIFT_PERIOD").toUpperCase();
      const hasLegacyMinimum=minimumCount!==""&&(!/^\d+$/.test(minimumCount)||Number(minimumCount)!==0);
      if(["REQUIRED","WYMÓG_ZMIANY"].includes(assignmentMode)||hasLegacyMinimum||shiftObligation||Boolean(shiftPeriod)){
        throw new Error(`${competencySheet} • wiersz ${sourceRow} • pola „Znaczenie / Minimum / Pora”: stary szeroki wymóg rola–obowiązek nie jest już obsługiwany, ponieważ mógł objąć kilka zmian o tej samej porze. Przenieś wymaganą liczbę osób do arkusza „Obsada” i wskaż dokładny „Kod zmiany”, „Kod roli” oraz opcjonalnie „Kod obowiązku”. Tutaj pozostaw wyłącznie relację kompetencyjną bez minimum.`);
      }
      if(!["","OPTIONAL","EXTRA"].includes(normalizedAssignmentMode)){
        throw new Error(`${competencySheet} • wiersz ${sourceRow} • kolumna „${assignmentModeColumn}”: wartość „${assignmentModeValue}” jest nieprawidłowa. Pozostaw pole puste albo wpisz OPTIONAL lub EXTRA.`);
      }
      return {
        roleCode:normalizeRoleCode(importCell(row,"Kod roli","roleCode","ROLA_WYMAGANA")),
        dutyCode:normalizeDutyCode(importCell(row,"Kod obowiązku","dutyCode","KOD")),
        assignmentMode:normalizedAssignmentMode==="EXTRA"?"EXTRA":"OPTIONAL",
        minimumCount:"0",shiftObligation:false,shiftPeriod:"",
        active:importBoolean(importCell(row,"Aktywne","active","AKTYWNA"),true),
      };
    });
  // The guided workbook deliberately has no separate technical role-duty
  // sheet. An exact staffing row that names both a role and a duty is already
  // an unambiguous declaration that this role can perform that duty. Seed the
  // missing competency relation (minimum remains 0); demand still comes only
  // from the exact shift staffing rule.
  const resolvedRoleDuties=[...roleDuties];
  for(const rule of staffingRules){
    const roleCode=String(rule.roleCode??""),dutyCode=String(rule.dutyCode??"");
    if(!roleCode||!dutyCode||resolvedRoleDuties.some(link=>link.roleCode===roleCode&&link.dutyCode===dutyCode))continue;
    resolvedRoleDuties.push({roleCode,dutyCode,assignmentMode:"OPTIONAL",minimumCount:"0",shiftObligation:false,shiftPeriod:"",active:true});
  }

  const employeeRoles=rows(["Role pracowników","Role pracownikow","Employee Roles"]).map(row=>{
    const isPrimary=importBoolean(importCell(row,"Podstawowa","isPrimary"));
    return {employeeNo:importCell(row,"Numer pracownika","employeeNo"),roleCode:normalizeRoleCode(importCell(row,"Kod roli","roleCode")),
      isPrimary,canLead:importBoolean(importCell(row,"Może zatwierdzać","canLead")),
      validFrom:normalizeDate(importCell(row,"Obowiązuje od","validFrom")),validTo:normalizeDate(importCell(row,"Obowiązuje do","validTo")),
      active:importBoolean(importCell(row,"Aktywna","active"),true),assignmentMode:isPrimary?"STANDARD":"BACKUP",
      backupPriority:importCell(row,"Priorytet rezerwowy","backupPriority")||"100"};
  });
  const adHocWorkers=rows(["Pula ad-hoc","Pula ad hoc","Ad hoc pool"]).map((row,index)=>({
    displayName:[importCell(row,"Imię","firstName"),importCell(row,"Nazwisko","lastName")].filter(Boolean).join(" ")||importCell(row,"Imię i nazwisko","Nazwa","displayName"),
    email:importCell(row,"E-mail","Email","email"),phone:importCell(row,"Telefon","phone"),
    roleCode:normalizeRoleCode(importCell(row,"Rola","Kod roli","roleCode")),
    contractType:normalizeContract(importCell(row,"Rodzaj współpracy","Rodzaj umowy","contractType"))||"ZLECENIE",
    baseRateMinor:importMoneyMinor(importCell(row,"Stawka godzinowa","baseRate")),
    currency:(importCell(row,"Waluta","currency")||"PLN").toUpperCase(),
    availableFrom:normalizeDate(importCell(row,"Dostępny od","availableFrom")),
    availableTo:normalizeDate(importCell(row,"Dostępny do","availableTo")),
    notes:importCell(row,"Notatki","notes"),active:importBoolean(importCell(row,"Aktywna","active"),true),sourceRow:index+2,
  })).filter(row=>row.displayName||row.email||row.phone);
  const adHocWorkerWithoutRole=adHocWorkers.find(row=>!row.roleCode);
  if(adHocWorkerWithoutRole){
    throw new Error(`Pula ad-hoc • wiersz ${adHocWorkerWithoutRole.sourceRow} • kolumna „Rola”: wybierz rolę z zakładki „Role” albo usuń ten niepełny wiersz.`);
  }
  const adHocWorkerWithoutPhone=adHocWorkers.find(row=>!row.phone);
  if(adHocWorkerWithoutPhone)throw new Error(`Pula ad-hoc • wiersz ${adHocWorkerWithoutPhone.sourceRow} • kolumna „Telefon”: wpisz numer telefonu osoby ad-hoc albo usuń ten niepełny wiersz.`);
  const employeeLocationsDetailed=rows(["Lokale pracowników","Lokale pracownikow","Employee Locations"]).map(row=>({
    employeeNo:importCell(row,"Numer pracownika","employeeNo"),locationCode:normalizeLocationCode(importCell(row,"Kod lokalu","locationCode")),
    standardAllowed:importBoolean(importCell(row,"Zwykła praca","standardAllowed")),overtimeAllowed:importBoolean(importCell(row,"Dodatkowa praca","overtimeAllowed")),
    homeLocation:importBoolean(importCell(row,"Lokal bazowy","homeLocation")),validFrom:normalizeDate(importCell(row,"Obowiązuje od","validFrom")),
    validTo:normalizeDate(importCell(row,"Obowiązuje do","validTo")),active:importBoolean(importCell(row,"Aktywna","active"),true),
  }));
  const employeeCapabilities=rows(["Kompetencje pracowników","Kompetencje pracownikow","Employee Capabilities"]).map(row=>({
    employeeNo:importCell(row,"Numer pracownika","employeeNo"),dutyCode:normalizeDutyCode(importCell(row,"Kod obowiązku","dutyCode")),
    roleCode:normalizeRoleCode(importCell(row,"Kod roli","roleCode")),locationCode:normalizeLocationCode(importCell(row,"Kod lokalu","locationCode")),
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

  // A fresh UAT reset intentionally starts with no business data.  The
  // scenario and solver strategies are technical defaults, not fields the
  // employer should have to reconstruct.  Therefore a freshly downloaded
  // quick-start workbook with header-only hidden technical sheets must remain
  // self-importable.
  const resolvedScenarios=scenarios.length?scenarios:DEFAULT_SCENARIOS.map(item=>({...item}));
  const resolvedStrategies=strategies.length?strategies:DEFAULT_STRATEGIES.map(item=>({...item}));
  const resolvedObjectives=strategyObjectives.length?strategyObjectives:
    (strategies.length?strategyObjectives:defaultStrategyObjectives());
  const resolvedScenarioStrategies=scenarioStrategies.length?scenarioStrategies:
    (!scenarios.length&&!strategies.length?resolvedScenarios.flatMap(scenario=>resolvedStrategies.map((strategy,index)=>({
      scenarioCode:String(scenario.code),strategyCode:String(strategy.code),sortOrder:String(index+1),objectiveOverrides:{},solverOverrides:{},active:true,
    }))):scenarioStrategies);

  // Visible quick-start sheets use user-facing scenario names (for example
  // „Bazowy”), while the hidden technical dictionary stores the stable code
  // (for example BASE). Resolve both to the canonical code so a workbook
  // downloaded from the application is always self-importable. A blank
  // scenario means the active default.
  const scenarioAliases=new Map<string,string>();
  for(const scenario of resolvedScenarios){
    const code=String(scenario.code??"");
    for(const alias of [code,String(scenario.name??"")]){
      if(alias.trim())scenarioAliases.set(importCode(alias),code);
    }
  }
  const defaultScenarioCode=String(resolvedScenarios.find(scenario=>scenario.active&&scenario.isDefault)?.code
    ??resolvedScenarios.find(scenario=>scenario.active)?.code??"");
  const normalizeScenarioCode=(value:string)=>{
    const alias=importCode(value);
    return alias?(scenarioAliases.get(alias)??alias):defaultScenarioCode;
  };
  const resolvedStaffingRules=staffingRules.map(rule=>{
    const shiftAlias=importCode(String(rule.shiftCode??""));
    return {...rule,shiftCode:shiftAliases.get(shiftAlias)??String(rule.shiftCode??""),scenarioCode:normalizeScenarioCode(String(rule.scenarioCode??""))};
  });
  const normalizedScenarioStrategies=resolvedScenarioStrategies.map(link=>({...link,scenarioCode:normalizeScenarioCode(String(link.scenarioCode??""))}));
  const normalizedScenarioPayRuleOverrides=scenarioPayRuleOverrides.map(link=>({...link,scenarioCode:normalizeScenarioCode(String(link.scenarioCode??""))}));
  const normalizedScenarioBudgets=scenarioBudgets.map(budget=>({...budget,scenarioCode:normalizeScenarioCode(String(budget.scenarioCode??""))}));

  if(workbookIdentity.mode!=="LEGACY"){
    const issues:WorkbookValidationIssue[]=[];
    const categoryCodes=new Set(roleCategories.map(item=>String(item.code))),roleCodesSet=new Set(roles.map(item=>String(item.code)));
    const locationCodesSet=new Set(locations.map(item=>String(item.code))),dutyCodesSet=new Set(duties.map(item=>String(item.code))),shiftCodesSet=new Set(groupedShifts.map(item=>String(item.code)));
    const add=(sheet:string,row:number,column:string,value:unknown,code:string,message:string,fix:string)=>issues.push({sheet,row,column,value:String(value??""),code,message,fix});
    roles.forEach(role=>{if(role.categoryCode&&!categoryCodes.has(String(role.categoryCode)))add("Role",role.sourceRow,"Kategoria grafiku",role.categoryCode,"CATEGORY_NOT_FOUND","Rola wskazuje kategorię, której nie ma w tym pliku.","Dodaj kategorię w zakładce „Kategorie grafików” albo wybierz istniejącą wartość z listy.");});
    employees.forEach((employee,index)=>{
      if(employee.primaryRoleCode&&!roleCodesSet.has(String(employee.primaryRoleCode)))add("Pracownicy",index+2,"Rola podstawowa",employee.primaryRoleCode,"ROLE_NOT_FOUND","Pracownik wskazuje rolę spoza tego pliku.","Dodaj rolę w zakładce „Role” albo wybierz istniejącą rolę z listy.");
      for(const code of (employee.locationCodes as string[]??[]))if(!locationCodesSet.has(String(code)))add("Pracownicy",index+2,"Lokal pracy",code,"LOCATION_NOT_FOUND","Pracownik wskazuje lokal spoza tego pliku.","Dodaj lokal w zakładce „Lokale” albo wybierz istniejący lokal z listy.");
      for(const code of (employee.dutyCodes as string[]??[]))if(!dutyCodesSet.has(String(code)))add("Pracownicy",index+2,"Kompetencja dodatkowa",code,"DUTY_NOT_FOUND","Pracownik wskazuje obowiązek spoza tego pliku.","Dodaj obowiązek w zakładce „Obowiązki” albo usuń tę kompetencję.");
    });
    groupedShifts.forEach(shift=>{if(shift.locationCode&&!locationCodesSet.has(String(shift.locationCode)))add("Zmiany",Number(shift.sourceRow??2),"Lokal",shift.locationCode,"LOCATION_NOT_FOUND","Zmiana wskazuje lokal spoza tego pliku.","Dodaj lokal w zakładce „Lokale” albo wybierz istniejący lokal z listy.");});
    resolvedStaffingRules.forEach(rule=>{
      const row=Number(rule.sourceRow??2);
      if(rule.shiftCode&&!shiftCodesSet.has(String(rule.shiftCode)))add("Obsada",row,"Zmiana",rule.shiftCode,"SHIFT_NOT_FOUND","Obsada wskazuje zmianę spoza tego pliku.","Dodaj zmianę w zakładce „Zmiany” albo wybierz istniejącą zmianę z listy.");
      if(rule.roleCode&&!roleCodesSet.has(String(rule.roleCode)))add("Obsada",row,"Rola",rule.roleCode,"ROLE_NOT_FOUND","Obsada wskazuje rolę spoza tego pliku.","Dodaj rolę w zakładce „Role” albo wybierz istniejącą rolę z listy.");
      if(rule.dutyCode&&!dutyCodesSet.has(String(rule.dutyCode)))add("Obsada",row,"Obowiązek (opcjonalnie)",rule.dutyCode,"DUTY_NOT_FOUND","Obsada wskazuje obowiązek spoza tego pliku.","Dodaj obowiązek w zakładce „Obowiązki” albo pozostaw pole puste.");
    });
    standbyGroups.forEach(group=>{
      if(group.categoryCode&&!categoryCodes.has(String(group.categoryCode)))add("Grupy rezerwy",group.sourceRow,"Kategoria grafiku",group.categoryCode,"CATEGORY_NOT_FOUND","Grupa rezerwy wskazuje kategorię spoza tego pliku.","Wybierz kategorię z listy.");
      if(!group.roleCodes.length)add("Role grup rezerwy",2,"Rola","","STANDBY_GROUP_WITHOUT_ROLE","Grupa rezerwy nie ma żadnej roli.","Dodaj co najmniej jeden wiersz dla tej grupy w zakładce „Role grup rezerwy”.");
      for(const code of group.roleCodes)if(!roleCodesSet.has(String(code)))add("Role grup rezerwy",2,"Rola",code,"ROLE_NOT_FOUND","Grupa rezerwy wskazuje rolę spoza tego pliku.","Wybierz rolę z listy.");
    });
    adHocWorkers.forEach(worker=>{if(worker.roleCode&&!roleCodesSet.has(String(worker.roleCode)))add("Pula ad-hoc",worker.sourceRow,"Rola",worker.roleCode,"ROLE_NOT_FOUND","Osoba ad-hoc wskazuje rolę spoza tego pliku.","Dodaj rolę w zakładce „Role” albo wybierz istniejącą rolę z listy.");});
    if(issues.length)throw new MatrixWorkbookValidationError(issues);
  }

  return {settings:{...settings,standbyTiersPerRoleDay:0,standbyGroups,...DEFAULT_STRATEGY_SOLVER_CONTRACT},roleCategories,roles,locations,duties,scenarios:resolvedScenarios,strategies:resolvedStrategies,strategyObjectives:resolvedObjectives,scenarioStrategies:normalizedScenarioStrategies,
    payRules,scenarioPayRuleOverrides:normalizedScenarioPayRuleOverrides,scenarioBudgets:normalizedScenarioBudgets,employees,employeeDuties,employeeRoles,
    employeeLocationsDetailed,employeeCapabilities,timeConstraints,shifts:groupedShifts,staffingRules:resolvedStaffingRules,roleDuties:resolvedRoleDuties,adHocWorkers,
    _workbook:workbookIdentity,_sourceLayout:sourceEmployeeLayout?"APPS_SCRIPT_BASE":"GRAFIK_PRO_TEMPLATE"};
}
