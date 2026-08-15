import ExcelJS from "exceljs";

type Worksheet=ExcelJS.Worksheet;
const {Workbook}=ExcelJS;

const BRAND={purple:"7257D8",purpleDark:"4F35B5",purpleLight:"EEE9FF",ink:"24212B",muted:"6F6878",line:"DDD7E7",required:"FFF0E6",optional:"F6F3FA",system:"ECEFF3",success:"EAF8F3"};
const BOOL_VALUES=["☐ Nie","☑ Tak"];
const COLOR_VALUES=["Fioletowy — #7257D8","Turkusowy — #0F8F7A","Niebieski — #2F75B5","Złoty — #C9A51D","Różowy — #C62BBE","Koralowy — #D4574F","Zielony — #4A8D78","Szary — #7A6F85"];
const EMPLOYMENT_STAGE_VALUES=["Stała współpraca","Okres próbny","Okres wypowiedzenia"];
const CONTRACT_VALUES=["Umowa o pracę","Umowa o pracę — część etatu","Umowa zlecenie","B2B","Inna"];

type WorkbookKind="QUICK"|"FULL"|"ACCESS"|"FINANCE";
type HeaderKind="required"|"optional"|"system";

const REQUIRED:Record<string,Set<string>>={
  "Firma":new Set(["Waluta","Strefa czasowa","Minimalny odpoczynek (min)","Maks. zmian jednego pracownika na dobę","Poziomy rezerwy stand-by na rolę i dzień","Brak dostępności oznacza dostępność","Wymagaj wyniku optymalnego"]),
  "Kategorie grafików":new Set(["Nazwa","Aktywna"]),
  "Role":new Set(["Nazwa","Kod kategorii","Aktywna"]),
  "Lokale":new Set(["Nazwa","Strefa czasowa","Aktywna"]),
  "Obowiązki":new Set(["Nazwa","Aktywna"]),
  "Pracownicy":new Set(["Aktywny","Imię","Nazwisko","Kod roli","Kody lokali","Etap zatrudnienia","Zatrudniony od","Nominał godzin","Limit miesięczny godzin","Limit tygodniowy godzin","Maks. kolejnych dni","Rodzaj umowy"]),
  "Zmiany":new Set(["Nazwa","Kod lokalu","Od","Do","Następny dzień","Dni","Aktywna"]),
  "Obsada":new Set(["Kod zmiany","Kod lokalu","Kod roli","Operacja","Liczba osób","Aktywna"]),
  "Pula ad-hoc":new Set(["Imię","Nazwisko","Kod roli","Rodzaj współpracy","Aktywna"]),
  "Dostępy":new Set(["Adres e-mail","Rodzaj dostępu","Aktywny"]),
  "Finanse pracowników":new Set(["Numer pracownika","Obowiązuje od","Stawka godzinowa","Waluta","Rodzaj umowy","Aktywna"]),
};
const SYSTEM:Record<string,Set<string>>={
  "Pracownicy":new Set(["Numer pracownika"]),
  "Finanse pracowników":new Set(["ID stawki","Imię i nazwisko","Zatrudniony od","Zatrudniony do"]),
};

function argb(value:string){return `FF${value}`;}
function baseHeader(value:string){return value.split("\n")[0].trim();}
function headerKind(sheetName:string,header:string):HeaderKind{
  if(SYSTEM[sheetName]?.has(header))return "system";
  if(REQUIRED[sheetName]?.has(header))return "required";
  return "optional";
}
function headerLabel(header:string,kind:HeaderKind){return `${header}\n${kind==="required"?"WYMAGANE":kind==="system"?"SYSTEM":"OPCJONALNE"}`;}
function usedColumnCount(sheet:Worksheet){return Math.max(1,sheet.actualColumnCount||sheet.columnCount||1);}
function usedRowCount(sheet:Worksheet){return Math.max(1,sheet.actualRowCount||sheet.rowCount||1);}
function styleSheet(sheet:Worksheet){
  sheet.views=[{state:"frozen",ySplit:1,showGridLines:false}];
  const cols=usedColumnCount(sheet),rows=usedRowCount(sheet);
  const header=sheet.getRow(1);header.height=34;
  for(let col=1;col<=cols;col++){
    const cell=header.getCell(col);const raw=String(cell.value??"");if(!raw)continue;
    const plain=baseHeader(raw),kind=headerKind(sheet.name,plain);
    cell.value=headerLabel(plain,kind);
    cell.font={name:"Aptos",size:10,bold:true,color:{argb:argb(BRAND.ink)}};
    cell.alignment={vertical:"middle",horizontal:"left",wrapText:true};
    cell.fill={type:"pattern",pattern:"solid",fgColor:{argb:argb(kind==="required"?BRAND.required:kind==="system"?BRAND.system:BRAND.optional)}};
    cell.border={bottom:{style:"medium",color:{argb:argb(BRAND.purple)}}};
    cell.note=kind==="required"?"Pole wymagane. Brak lub nieprawidłowa wartość zatrzyma import i wskaże tę komórkę.":kind==="system"?"Pole systemowe. Nie zmieniaj go podczas aktualizacji istniejącego rekordu.":"Pole opcjonalne — pozostaw puste, jeśli nie dotyczy.";
    const column=sheet.getColumn(col);column.width=Math.min(34,Math.max(14,plain.length+3));
  }
  for(let row=2;row<=rows;row++){
    const current=sheet.getRow(row);current.height=22;
    for(let col=1;col<=cols;col++){
      const cell=current.getCell(col);
      cell.font={name:"Aptos",size:10,color:{argb:argb(BRAND.ink)}};
      cell.alignment={vertical:"middle",horizontal:"left",wrapText:false};
      cell.border={bottom:{style:"hair",color:{argb:argb(BRAND.line)}}};
    }
  }
  sheet.autoFilter={from:{row:1,column:1},to:{row:Math.max(2,rows),column:cols}};
}
function findColumn(sheet:Worksheet,label:string){
  for(let col=1;col<=usedColumnCount(sheet);col++)if(baseHeader(String(sheet.getRow(1).getCell(col).value??""))===label)return col;
  return 0;
}
function listFormula(listSheet:Worksheet,column:number,count:number){return `'${listSheet.name}'!$${listSheet.getColumn(column).letter}$2:$${listSheet.getColumn(column).letter}$${count+1}`;}
function addListValidation(sheet:Worksheet,column:number,formula:string,prompt:string){
  if(!column||/\$2:\$1$/u.test(formula))return;
  for(let row=2;row<=501;row++){
    sheet.getCell(row,column).dataValidation={type:"list",allowBlank:true,formulae:[formula],showErrorMessage:true,errorStyle:"stop",errorTitle:"Wybierz wartość z listy",error:"Ta wartość nie jest obsługiwana przez import.",showInputMessage:true,promptTitle:"GRAFIK PRO",prompt};
  }
}
function writeList(sheet:Worksheet,column:number,title:string,values:string[]){
  sheet.getCell(1,column).value=title;
  values.forEach((value,index)=>{sheet.getCell(index+2,column).value=value;});
  sheet.getColumn(column).width=38;
}
function replaceBooleanValues(sheet:Worksheet){
  const boolHeaders=["Aktywna","Aktywny","Aktywne","Domyślny","Podstawowa","Może zatwierdzać","Zwykła praca","Dodatkowa praca","Lokal bazowy","Następny dzień","Włączona","Twardy limit","Brak dostępności oznacza dostępność","Wymagaj wyniku optymalnego","Bez weekendów"];
  for(const label of boolHeaders){
    const col=findColumn(sheet,label);if(!col)continue;
    for(let row=2;row<=usedRowCount(sheet);row++){
      const cell=sheet.getCell(row,col),value=String(cell.value??"").trim().toLocaleUpperCase("pl-PL");
      if(["TAK","TRUE","1","X","☑ TAK"].includes(value))cell.value="☑ Tak";
      else if(["NIE","FALSE","0","☐ NIE"].includes(value))cell.value="☐ Nie";
    }
  }
}
function replaceEmploymentStages(sheet:Worksheet){
  const col=findColumn(sheet,"Etap zatrudnienia");if(!col)return;
  const labels:Record<string,string>={REGULAR:"Stała współpraca",PROBATION:"Okres próbny",NOTICE:"Okres wypowiedzenia"};
  for(let row=2;row<=usedRowCount(sheet);row++){
    const cell=sheet.getCell(row,col),key=String(cell.value??"").trim().toLocaleUpperCase("pl-PL");
    if(labels[key])cell.value=labels[key];
  }
}
function replaceContracts(sheet:Worksheet){
  const labels:Record<string,string>={UMOWA_O_PRACE:"Umowa o pracę",CZESC_ETATU:"Umowa o pracę — część etatu",ZLECENIE:"Umowa zlecenie",B2B:"B2B",INNE:"Inna"};
  for(const header of ["Rodzaj umowy","Rodzaj współpracy"]){
    const col=findColumn(sheet,header);if(!col)continue;
    for(let row=2;row<=usedRowCount(sheet);row++){
      const cell=sheet.getCell(row,col),key=String(cell.value??"").trim().toLocaleUpperCase("pl-PL");
      if(labels[key])cell.value=labels[key];
    }
  }
}
function splitAdHocNames(sheet:Worksheet){
  const combined=findColumn(sheet,"Imię i nazwisko");if(!combined)return;
  const names=Array.from({length:Math.max(0,usedRowCount(sheet)-1)},(_,index)=>String(sheet.getCell(index+2,combined).value??"").trim());
  sheet.spliceColumns(combined,1,["Imię"],["Nazwisko"]);
  const firstCol=combined,lastCol=combined+1;
  for(let row=2;row<=names.length+1;row++){
    const original=names[row-2];
    const parts=original.split(/\s+/).filter(Boolean);
    sheet.getCell(row,firstCol).value=parts.shift()??"";
    sheet.getCell(row,lastCol).value=parts.join(" ");
  }
}
function formatInstruction(sheet:Worksheet,kind:WorkbookKind){
  sheet.spliceRows(1,sheet.rowCount);
  const rows=kind==="ACCESS"?[
    ["1","Otwórz zakładkę „Dostępy”","Każdy wiersz nadaje lub wyłącza jedną funkcję dla jednego adresu e-mail."],
    ["2","Wpisz adres e-mail","To pole jest wymagane i identyfikuje konto. Jedna osoba może wystąpić w kilku wierszach."],
    ["3","Wybierz rodzaj dostępu","Użyj listy wyboru. Nie wpisuj kodów technicznych z pamięci."],
    ["4","Uzupełnij zakres, jeśli jest potrzebny","Lider roli wymaga zakresu roli, a lider lokalu — zakresu lokalu. Dla pozostałych funkcji pozostaw pola puste."],
    ["5","Ustaw aktywność","☑ Tak nadaje lub utrzymuje funkcję; ☐ Nie wyłącza dokładnie ten dostęp."],
    ["6","Zaimportuj i sprawdź podgląd","Jeden błędny wiersz zatrzyma cały zapis i wskaże zakładkę, wiersz oraz kolumnę."],
  ]:[
    ["1","Firma i lokale","Sprawdź walutę, strefę czasową i lokale. Pola oznaczone WYMAGANE nie mogą być puste."],
    ["2","Kategorie, role i obowiązki","Najpierw dodaj kategorie, potem role. Obowiązki są opcjonalne. Korzystaj z list wyboru i gotowej palety kolorów."],
    ["3","Pracownicy","Wpisz osobno imię i nazwisko, wybierz rolę, lokale, etap zatrudnienia i rodzaj umowy. Numer nowej osoby pozostaw pusty — system nada GP-###."],
    ["4","Okres próbny","Wybierz „Okres próbny” z listy i podaj datę końca okresu próbnego. System nie zamieni nieznanej wartości na stałą współpracę."],
    ["5","Zmiany i obsada","Wpisz godziny w formacie 24-godzinnym, wybierz lokal i rolę oraz podaj wymaganą liczbę osób."],
    ["6","Pula ad-hoc (opcjonalnie)","Wpisz osobno imię i nazwisko, telefon, rolę i okres dostępności. Osoby ad-hoc nie trafiają do zwykłego grafiku."],
    ["7","Sprawdzenie pliku","Zapisz plik jako .xlsx. Możesz edytować go w Excelu albo Google Sheets i ponownie pobrać jako Microsoft Excel (.xlsx)."],
    ["8","Podgląd przed zapisem","W GRAFIK PRO wybierz „Sprawdź plik”. Błąd wskaże zakładkę, wiersz, kolumnę, błędną wartość i sposób poprawy."],
  ];
  sheet.mergeCells("A1:C1");sheet.getCell("A1").value=kind==="ACCESS"?"GRAFIK PRO — dostępy do aplikacji":"GRAFIK PRO — konfiguracja firmy krok po kroku";
  sheet.getCell("A1").font={name:"Aptos Display",size:20,bold:true,color:{argb:"FFFFFFFF"}};sheet.getCell("A1").fill={type:"pattern",pattern:"solid",fgColor:{argb:argb(BRAND.purple)}};sheet.getCell("A1").alignment={vertical:"middle"};sheet.getRow(1).height=38;
  sheet.addRow(["KROK","GDZIE PRZEJŚĆ","CO ZROBIĆ"]);
  for(const row of rows)sheet.addRow(row);
  sheet.addRow(["Legenda","WYMAGANE = pole musi być uzupełnione • OPCJONALNE = wypełnij, jeśli dotyczy • SYSTEM = nie zmieniaj","Wartości wybieraj z list. Nieznana wartość nigdy nie zostanie cicho zastąpiona inną."]);
  sheet.getColumn(1).width=14;sheet.getColumn(2).width=36;sheet.getColumn(3).width=100;
  sheet.views=[{state:"frozen",ySplit:2,showGridLines:false}];
  const header=sheet.getRow(2);header.height=28;header.eachCell(cell=>{cell.font={name:"Aptos",size:10,bold:true,color:{argb:"FFFFFFFF"}};cell.fill={type:"pattern",pattern:"solid",fgColor:{argb:argb(BRAND.purpleDark)}};cell.alignment={vertical:"middle"};});
  for(let row=3;row<=sheet.rowCount;row++){const current=sheet.getRow(row);current.height=34;current.eachCell(cell=>{cell.font={name:"Aptos",size:10,color:{argb:argb(BRAND.ink)}};cell.alignment={vertical:"middle",wrapText:true};cell.border={bottom:{style:"thin",color:{argb:argb(BRAND.line)}}};});current.getCell(1).font={name:"Aptos",size:11,bold:true,color:{argb:argb(BRAND.purpleDark)}};}
}

async function polish(input:ArrayBuffer|Uint8Array,kind:WorkbookKind){
  const workbook=new Workbook();await workbook.xlsx.load(input as ArrayBuffer);
  const instruction=workbook.getWorksheet("Instrukcja");if(instruction)formatInstruction(instruction,kind);
  const adHoc=workbook.getWorksheet("Pula ad-hoc");if(adHoc)splitAdHocNames(adHoc);
  let lists=workbook.getWorksheet("_LISTY");if(lists)workbook.removeWorksheet(lists.id);lists=workbook.addWorksheet("_LISTY",{state:"hidden"});
  writeList(lists,1,"Tak / nie",BOOL_VALUES);writeList(lists,2,"Etap zatrudnienia",EMPLOYMENT_STAGE_VALUES);writeList(lists,3,"Rodzaj umowy",CONTRACT_VALUES);writeList(lists,4,"Kolor",COLOR_VALUES);
  const sourceDictionaries=workbook.getWorksheet("Słowniki");
  const roleCodes:string[]=[],locationCodes:string[]=[],categoryCodes:string[]=[],accessRoles:string[]=[];
  const accessRoleLabels=new Map<string,string>();
  sourceDictionaries?.eachRow((row,index)=>{if(index===1)return;const type=String(row.getCell(1).value??"").trim(),code=String(row.getCell(2).value??"").trim(),name=String(row.getCell(3).value??"").trim();if(!code)return;if(type==="ROLA")roleCodes.push(code);if(type==="LOKAL")locationCodes.push(code);if(type==="KATEGORIA GRAFIKU")categoryCodes.push(code);if(type==="RODZAJ DOSTĘPU"){const label=name.split(" — ")[0]||code;accessRoles.push(label);accessRoleLabels.set(code,label);}});
  writeList(lists,5,"Role",roleCodes);writeList(lists,6,"Lokale",locationCodes);writeList(lists,7,"Kategorie",categoryCodes);writeList(lists,8,"Rodzaje dostępu",accessRoles);
  for(const sheet of workbook.worksheets){
    if(sheet.name==="_LISTY"||sheet.name==="Instrukcja")continue;
    replaceBooleanValues(sheet);replaceEmploymentStages(sheet);replaceContracts(sheet);styleSheet(sheet);
    const accessColumn=findColumn(sheet,"Rodzaj dostępu");
    if(accessColumn)for(let row=2;row<=usedRowCount(sheet);row++){const cell=sheet.getCell(row,accessColumn),label=accessRoleLabels.get(String(cell.value??"").trim());if(label)cell.value=label;}
    const boolFormula=listFormula(lists,1,BOOL_VALUES.length);
    for(const label of ["Aktywna","Aktywny","Aktywne","Domyślny","Podstawowa","Może zatwierdzać","Zwykła praca","Dodatkowa praca","Lokal bazowy","Następny dzień","Włączona","Twardy limit","Brak dostępności oznacza dostępność","Wymagaj wyniku optymalnego","Bez weekendów"])addListValidation(sheet,findColumn(sheet,label),boolFormula,"Wybierz ☐ Nie albo ☑ Tak.");
    addListValidation(sheet,findColumn(sheet,"Etap zatrudnienia"),listFormula(lists,2,EMPLOYMENT_STAGE_VALUES.length),"Wybierz etap zatrudnienia. Dla okresu próbnego uzupełnij również datę końca.");
    for(const label of ["Rodzaj umowy","Rodzaj współpracy"])addListValidation(sheet,findColumn(sheet,label),listFormula(lists,3,CONTRACT_VALUES.length),"Wybierz rodzaj umowy z listy.");
    addListValidation(sheet,findColumn(sheet,"Kolor"),listFormula(lists,4,COLOR_VALUES.length),"Wybierz kolor z gotowej palety.");
    for(const label of ["Kod roli","Kod roli podstawowej"])addListValidation(sheet,findColumn(sheet,label),listFormula(lists,5,roleCodes.length),"Wybierz kod istniejącej roli.");
    for(const label of ["Kod lokalu","Lokal bazowy","Zakres lokalu"])addListValidation(sheet,findColumn(sheet,label),listFormula(lists,6,locationCodes.length),"Wybierz kod istniejącego lokalu.");
    addListValidation(sheet,findColumn(sheet,"Kod kategorii"),listFormula(lists,7,categoryCodes.length),"Wybierz kategorię grafiku.");
    addListValidation(sheet,findColumn(sheet,"Rodzaj dostępu"),listFormula(lists,8,accessRoles.length),"Wybierz rodzaj dostępu w języku użytkownika.");
  }
  lists.state="hidden";
  return new Uint8Array(await workbook.xlsx.writeBuffer());
}

export function polishMatrixWorkbook(input:ArrayBuffer|Uint8Array,variant:"QUICK"|"FULL"){return polish(input,variant);}
export function polishAccessWorkbook(input:ArrayBuffer|Uint8Array){return polish(input,"ACCESS");}
export function polishFinanceWorkbook(input:ArrayBuffer|Uint8Array){return polish(input,"FINANCE");}

export function downloadWorkbook(bytes:Uint8Array,fileName:string){
  const blob=new Blob([bytes as BlobPart],{type:"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"});
  const href=URL.createObjectURL(blob),anchor=document.createElement("a");anchor.href=href;anchor.download=fileName;document.body.appendChild(anchor);anchor.click();anchor.remove();URL.revokeObjectURL(href);
}
