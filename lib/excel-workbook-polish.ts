import ExcelJS from "exceljs";
import { APP_COLOR_LABELS } from "./app-color-palette.ts";
import { QUICK_WORKBOOK_SHEETS, referenceLabel, type WorkbookFieldDefinition } from "./workbook-contract.ts";

type Worksheet=ExcelJS.Worksheet;
const {Workbook}=ExcelJS;

const BRAND={primary:"33443B",primaryDark:"1A1A1A",primaryLight:"C4D2C4",ink:"1A1A1A",muted:"756D65",line:"CBBFAE",required:"F2EDE4",conditional:"E8E1D6",optional:"F7F3EC",system:"D7D0C7",success:"C4D2C4"};
const BOOL_VALUES=["☐ Nie","☑ Tak"];
const COLOR_VALUES=APP_COLOR_LABELS;
const EMPLOYMENT_STAGE_VALUES=["Stała współpraca","Okres próbny","Okres wypowiedzenia"];
const CONTRACT_VALUES=["Umowa o pracę","Umowa o pracę — część etatu","Umowa zlecenie","B2B","Inna"];
const OVERTIME_VALUES=["NIE","TYLKO PO ZATWIERDZENIU","TAK"];

type WorkbookKind="QUICK"|"FULL"|"ACCESS"|"FINANCE";
type HeaderKind="required"|"optional"|"conditional"|"system";

const ACCESS_GUIDE:{purpose:string;when:string;fields:Record<string,WorkbookFieldDefinition>}={
  purpose:"Nadaje, ogranicza albo wyłącza dostęp do aplikacji. Każdy wiersz oznacza jedną funkcję dla jednego adresu e-mail.",
  when:"Uzupełnij przy nadawaniu lub zmianie dostępu. Powtórz adres e-mail w kolejnym wierszu, jeśli osoba ma mieć kilka funkcji.",
  fields:{
    "Adres e-mail":{status:"WYMAGANE",purpose:"Identyfikuje konto, któremu nadajesz dostęp.",input:"Wpisz pełny adres e-mail używany do logowania.",allowed:"Poprawny adres e-mail.",example:"lider.bar@firma.pl",effect:"System nada lub zmieni wskazaną funkcję dla tego konta.",blank:"Wiersz zostanie odrzucony bez żadnych zmian.",application:"Dostęp do aplikacji i widoczne moduły."},
    "Rodzaj dostępu":{status:"WYMAGANE",purpose:"Określa funkcję i bazowy zakres uprawnień osoby.",input:"Wybierz nazwę funkcji z listy.",allowed:"Jedna z funkcji dostępnych na liście w pliku.",example:"Lider roli",effect:"Określa, co osoba może zobaczyć i wykonywać.",blank:"Wiersz zostanie odrzucony bez żadnych zmian.",application:"Menu, widoki i działania dostępne po zalogowaniu."},
    "Zakres roli":{status:"WARUNKOWE",purpose:"Ogranicza lidera roli do jednej wskazanej roli.",input:"Wybierz rolę z listy tylko dla funkcji Lider roli.",allowed:"Rola z konfiguracji firmy.",example:"Barman",effect:"Lider zobaczy i obsłuży wyłącznie wskazaną rolę.",blank:"Dla Lidera roli wiersz zostanie odrzucony; dla innych funkcji pole ma pozostać puste.",application:"Grafik i zespół w zakresie roli."},
    "Zakres lokalu":{status:"WARUNKOWE",purpose:"Ogranicza lidera lokalu do jednego wskazanego lokalu.",input:"Wybierz lokal z listy tylko dla funkcji Lider lokalu.",allowed:"Lokal z konfiguracji firmy.",example:"Krucza",effect:"Lider zobaczy i obsłuży wyłącznie wskazany lokal.",blank:"Dla Lidera lokalu wiersz zostanie odrzucony; dla innych funkcji pole ma pozostać puste.",application:"Grafik i zespół w zakresie lokalu."},
    "Aktywny":{status:"WYMAGANE",purpose:"Włącza albo wyłącza dokładnie tę funkcję i jej zakres.",input:"Wybierz ☑ Tak albo ☐ Nie.",allowed:"☑ Tak lub ☐ Nie.",example:"☑ Tak",effect:"Tak nadaje lub utrzymuje dostęp; Nie go wyłącza bez usuwania historii.",blank:"Import przyjmie domyślnie aktywny dostęp, dlatego wybierz wartość świadomie.",application:"Dostęp do aplikacji."},
  },
};

const FINANCE_GUIDE:{purpose:string;when:string;fields:Record<string,WorkbookFieldDefinition>}={
  purpose:"Aktualizuje okresy stawek godzinowych pracowników bez powtarzania danych kadrowych z konfiguracji firmy.",
  when:"Pobierz po zapisaniu struktury i zespołu. Jeden wiersz oznacza jeden okres obowiązywania stawki jednej osoby.",
  fields:{
    "ID stawki":{status:"SYSTEM",purpose:"Rozpoznaje istniejący okres stawki.",input:"Nie zmieniaj. Dla nowego okresu pozostaw puste.",allowed:"Identyfikator z eksportu albo puste.",example:"Puste dla nowej stawki",effect:"Z ID aktualizuje istniejący wpis; bez ID tworzy nowy.",blank:"Powstanie nowy okres stawki.",application:"Historia stawek pracownika."},
    "Numer pracownika":{status:"WYMAGANE",purpose:"Wskazuje osobę, której dotyczy stawka.",input:"Zachowaj numer z pobranego pliku.",allowed:"Istniejący numer GP-###.",example:"GP-067",effect:"Łączy stawkę z właściwym pracownikiem.",blank:"Wiersz zostanie odrzucony bez zmian.",application:"Finanse zespołu i koszt grafiku."},
    "Imię i nazwisko":{status:"SYSTEM",purpose:"Pomaga wzrokowo sprawdzić, czy edytujesz właściwą osobę.",input:"Nie zmieniaj; system nie używa tego pola do identyfikacji.",allowed:"Tekst z eksportu.",example:"Anna Nowak",effect:"Nie zmienia danych pracownika.",blank:"Import nadal użyje numeru pracownika.",application:"Tylko plik pomocniczy."},
    "Zatrudniony od":{status:"SYSTEM",purpose:"Pokazuje początek zatrudnienia i pomaga dobrać początek stawki.",input:"Nie zmieniaj.",allowed:"Data RRRR-MM-DD z konfiguracji firmy.",example:"2026-08-01",effect:"Nie aktualizuje zatrudnienia w imporcie finansowym.",blank:"Nie blokuje importu stawki.",application:"Tylko plik pomocniczy."},
    "Zatrudniony do":{status:"SYSTEM",purpose:"Pokazuje koniec zatrudnienia, jeśli został ustalony.",input:"Nie zmieniaj.",allowed:"Data RRRR-MM-DD albo puste.",example:"2026-12-31",effect:"Nie aktualizuje zatrudnienia w imporcie finansowym.",blank:"Oznacza brak daty końca w informacji pomocniczej.",application:"Tylko plik pomocniczy."},
    "Obowiązuje od":{status:"WYMAGANE",purpose:"Pierwszy dzień używania tej stawki.",input:"Wpisz datę w formacie RRRR-MM-DD.",allowed:"Data mieszcząca się w okresie zatrudnienia.",example:"2026-09-01",effect:"Od tego dnia koszt grafiku używa tej stawki.",blank:"Wiersz zostanie odrzucony bez zmian.",application:"Koszt grafiku i historia stawek."},
    "Obowiązuje do":{status:"OPCJONALNE",purpose:"Ostatni dzień używania tej stawki.",input:"Wpisz datę RRRR-MM-DD albo pozostaw puste dla stawki bez daty końcowej.",allowed:"Data nie wcześniejsza niż Obowiązuje od albo puste.",example:"2026-12-31",effect:"Kończy obowiązywanie stawki we wskazanym dniu.",blank:"Stawka obowiązuje bez daty końcowej.",application:"Koszt grafiku i historia stawek."},
    "Stawka godzinowa":{status:"WYMAGANE",purpose:"Podstawowa kwota brutto za godzinę w tym okresie.",input:"Wpisz kwotę z dwoma miejscami po przecinku.",allowed:"Liczba większa lub równa 0.",example:"32,50",effect:"Zmienia koszt przydziałów objętych tym okresem.",blank:"Wiersz zostanie odrzucony bez zmian.",application:"Finanse, warianty i koszt grafiku."},
    "Waluta":{status:"WYMAGANE",purpose:"Waluta stawki godzinowej.",input:"Zachowaj walutę firmy.",allowed:"Trzyliterowy kod, np. PLN.",example:"PLN",effect:"Zapewnia poprawne obliczenie i prezentację kosztu.",blank:"Wiersz zostanie odrzucony bez zmian.",application:"Finanse i koszt grafiku."},
    "Aktywna":{status:"WYMAGANE",purpose:"Włącza okres stawki albo zachowuje go w historii jako wyłączony.",input:"Wybierz ☑ Tak albo ☐ Nie.",allowed:"☑ Tak lub ☐ Nie.",example:"☑ Tak",effect:"Nie wyłącza wpis bez jego usuwania; Tak pozwala używać stawki w jej okresie.",blank:"Import przyjmie wpis jako aktywny, dlatego wybierz wartość świadomie.",application:"Historia stawek i koszt grafiku."},
  },
};

const REQUIRED:Record<string,Set<string>>={
  "Firma":new Set(["Waluta","Strefa czasowa","Minimalny odpoczynek (godz.)","Maks. zmian jednego pracownika na dobę","Brak wpisanej dostępności oznacza dostępność"]),
  "Kategorie grafików":new Set(["Nazwa","Aktywna"]),
  "Role":new Set(["Nazwa","Kod kategorii","Aktywna"]),
  "Lokale":new Set(["Nazwa","Strefa czasowa","Aktywna"]),
  "Obowiązki":new Set(["Nazwa","Aktywna"]),
  "Pracownicy":new Set(["Aktywny","Imię","Nazwisko","Rola podstawowa","Lokal pracy 1","Etap zatrudnienia","Zatrudniony od","Miesięczny cel godzin","Twardy limit miesięczny godzin","Limit tygodniowy godzin","Maks. kolejnych dni","Rodzaj umowy","Zgoda na nadgodziny"]),
  "Zmiany":new Set(["Nazwa","Lokal","Od","Do","Kończy się następnego dnia","Dni tygodnia","Aktywna"]),
  "Obsada":new Set(["Zmiana","Rola","Liczba osób","Aktywna"]),
  "Grupy rezerwy":new Set(["Nazwa","Kategoria grafiku","Poziomy rezerwy"]),
  "Role grup rezerwy":new Set(["Grupa rezerwy","Rola"]),
  "Pula ad-hoc":new Set(["Imię","Nazwisko","Telefon","Rola","Rodzaj współpracy","Stawka godzinowa","Waluta","Aktywna"]),
  "Dostępy":new Set(["Adres e-mail","Rodzaj dostępu","Aktywny"]),
  "Finanse pracowników":new Set(["Numer pracownika","Obowiązuje od","Stawka godzinowa","Waluta","Aktywna"]),
};
const SYSTEM:Record<string,Set<string>>={
  "Kategorie grafików":new Set(["Kod"]),"Role":new Set(["Kod"]),"Lokale":new Set(["Kod"]),"Obowiązki":new Set(["Kod"]),"Zmiany":new Set(["Kod"]),"Grupy rezerwy":new Set(["Kod"]),
  "Pracownicy":new Set(["Numer pracownika"]),
  "Finanse pracowników":new Set(["ID stawki","Imię i nazwisko","Zatrudniony od","Zatrudniony do"]),
};

function argb(value:string){return `FF${value}`;}
function baseHeader(value:string){return value.split("\n")[0].trim();}
function headerKind(sheetName:string,header:string,kind?:WorkbookKind):HeaderKind{
  const guided=kind==="ACCESS"&&sheetName==="Dostępy"?ACCESS_GUIDE.fields[header]:kind==="FINANCE"&&sheetName==="Finanse pracowników"?FINANCE_GUIDE.fields[header]:undefined;
  if(guided){
    if(guided.status==="SYSTEM")return "system";
    if(guided.status==="WYMAGANE")return "required";
    if(guided.status==="WARUNKOWE")return "conditional";
    return "optional";
  }
  if(kind==="QUICK"){
    const status=QUICK_WORKBOOK_SHEETS[sheetName]?.fields[header]?.status;
    if(status==="SYSTEM")return "system";
    if(status==="WYMAGANE")return "required";
    if(status==="WARUNKOWE")return "conditional";
    return "optional";
  }
  if(SYSTEM[sheetName]?.has(header))return "system";
  if(REQUIRED[sheetName]?.has(header))return "required";
  return "optional";
}
function headerLabel(header:string,kind:HeaderKind){return `${header}\n${kind==="required"?"WYMAGANE":kind==="conditional"?"WARUNKOWE":kind==="system"?"SYSTEM":"OPCJONALNE"}`;}
function usedColumnCount(sheet:Worksheet){return Math.max(1,sheet.actualColumnCount||sheet.columnCount||1);}
function usedRowCount(sheet:Worksheet){return Math.max(1,sheet.actualRowCount||sheet.rowCount||1);}
function styleSheet(sheet:Worksheet,kind:WorkbookKind){
  sheet.views=[{state:"frozen",ySplit:1,showGridLines:false}];
  const cols=usedColumnCount(sheet),rows=usedRowCount(sheet);
  const header=sheet.getRow(1);header.height=34;
  for(let col=1;col<=cols;col++){
    const cell=header.getCell(col);const raw=String(cell.value??"");if(!raw)continue;
    const plain=baseHeader(raw),fieldKind=headerKind(sheet.name,plain,kind);
    cell.value=sheet.name==="Opis pól"?plain:headerLabel(plain,fieldKind);
    cell.font={name:"Aptos",size:10,bold:true,color:{argb:argb(BRAND.ink)}};
    cell.alignment={vertical:"middle",horizontal:"left",wrapText:true};
    cell.fill={type:"pattern",pattern:"solid",fgColor:{argb:argb(fieldKind==="required"?BRAND.required:fieldKind==="conditional"?BRAND.conditional:fieldKind==="system"?BRAND.system:BRAND.optional)}};
    cell.border={bottom:{style:"medium",color:{argb:argb(BRAND.primary)}}};
    // Guidance stays visible in the header. Do not add ExcelJS comments here:
    // their VML parts may be rejected by desktop Excel after SheetJS output is
    // loaded and rewritten.
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
function listFormula(listSheet:Worksheet,column:number,count:number,fixedEnd?:number){
  const end=fixedEnd??Math.max(2,count+1);
  return `'${listSheet.name}'!$${listSheet.getColumn(column).letter}$2:$${listSheet.getColumn(column).letter}$${end}`;
}
function addListValidation(sheet:Worksheet,column:number,formula:string,prompt:string){
  if(!column)return;
  for(let row=2;row<=501;row++){
    sheet.getCell(row,column).dataValidation={type:"list",allowBlank:true,formulae:[formula],showErrorMessage:true,errorStyle:"stop",errorTitle:"Wybierz wartość z listy",error:prompt,showInputMessage:false};
  }
}
function writeList(sheet:Worksheet,column:number,title:string,values:Array<string|number>){
  sheet.getCell(1,column).value=title;
  values.forEach((value,index)=>{sheet.getCell(index+2,column).value=value;});
  sheet.getColumn(column).width=38;
}
function replaceBooleanValues(sheet:Worksheet){
  const boolHeaders=["Aktywna","Aktywny","Aktywne","Domyślny","Podstawowa","Może zatwierdzać","Zwykła praca","Dodatkowa praca","Lokal bazowy","Następny dzień","Kończy się następnego dnia","Włączona","Twardy limit","Brak dostępności oznacza dostępność","Brak wpisanej dostępności oznacza dostępność","Wymagaj wyniku optymalnego","Bez weekendów"];
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
  const rows=kind==="ACCESS"?[
    ["1","Otwórz zakładkę „Dostępy”","Każdy wiersz nadaje lub wyłącza jedną funkcję dla jednego adresu e-mail."],
    ["2","Wpisz adres e-mail","To pole jest wymagane i identyfikuje konto. Jedna osoba może wystąpić w kilku wierszach."],
    ["3","Wybierz rodzaj dostępu","Użyj listy wyboru. Nie wpisuj kodów technicznych z pamięci."],
    ["4","Uzupełnij zakres, jeśli jest potrzebny","Lider roli wymaga zakresu roli, a lider lokalu — zakresu lokalu. Dla pozostałych funkcji pozostaw pola puste."],
    ["5","Ustaw aktywność","☑ Tak nadaje lub utrzymuje funkcję; ☐ Nie wyłącza dokładnie ten dostęp."],
    ["6","Zaimportuj i sprawdź podgląd","W SZAFUNKU wybierz plik lokalny albo użyj „Importuj z Dysku Google”. Jeden błędny wiersz zatrzyma cały zapis i wskaże zakładkę, wiersz oraz kolumnę."],
  ]:kind==="FINANCE"?[
    ["1","Nie zmieniaj danych pomocniczych","Numer pracownika wskazuje osobę. Imię i nazwisko oraz daty zatrudnienia służą tylko do kontroli i nie aktualizują profilu."],
    ["2","Dodaj nowy okres stawki","Dodaj wiersz, pozostaw ID stawki puste i podaj numer pracownika, datę początku, kwotę, walutę oraz aktywność."],
    ["3","Zmień istniejący okres","Zachowaj ID stawki i popraw wyłącznie okres, kwotę, walutę albo aktywność w tym samym wierszu."],
    ["4","Nie powtarzaj rodzaju umowy","Forma współpracy pochodzi z profilu pracownika. Dla istniejącej stawki system zachowa jej zapis historyczny; dla nowej użyje bieżącej formy współpracy."],
    ["5","Sprawdź okresy","Aktywne okresy jednej osoby nie mogą się nakładać. Puste „Obowiązuje do” oznacza stawkę bez daty końcowej."],
    ["6","Sprawdź i zapisz","Import najpierw pokaże dokładny podgląd. Jeden błędny wiersz zatrzyma wszystkie zmiany."],
  ]:[
    ["1","Firma, kategorie, role i lokale","Uzupełnij strukturę firmy w tej kolejności. Kody nadaje system; wybieraj gotowe wartości z list zamiast przepisywać kody."],
    ["2","Obowiązki (jeśli są potrzebne)","Dodaj tylko kompetencje, które rzeczywiście zawężają obsadę, np. obsługę kasy. Zwykłego stanowiska nie powtarzaj jako obowiązku."],
    ["3","Pracownicy — jeden wiersz na osobę","Wpisz osobno imię i nazwisko. W tym samym wierszu wybierz dokładnie jedną rolę podstawową, lokale pracy oraz ewentualne kompetencje."],
    ["4","Role dodatkowe pracownika","Wpisuj je wyłącznie w kolumnach „Rola dodatkowa 1–3”. Są zawsze awaryjne: generator użyje ich dopiero po wyczerpaniu dostępnych osób z daną rolą podstawową."],
    ["5","Okres próbny","Jeżeli etap to „Okres próbny”, data końca okresu próbnego jest obowiązkowa. Nieznana wartość nie zostanie cicho zamieniona na stałą współpracę."],
    ["6","Zmiany i obsada","Najpierw zdefiniuj godziny zmian, potem liczbę potrzebnych osób. Obowiązek w obsadzie pozostaw pusty, jeżeli wystarcza sama rola."],
    ["7","Rezerwa i pula ad-hoc (opcjonalnie)","Wypełnij tylko, jeśli firma korzysta z tych funkcji. Dla ad-hoc wymagane są osobne imię i nazwisko, telefon oraz rola."],
    ["8","Finanse i dostępność","Stawek nie ma w prostym pliku — uzupełnij je osobnym plikiem finansowym. Bieżącą dostępność pracownicy lub liderzy wpisują w aplikacji."],
    ["9","Opis pól","Przed wpisaniem danych otwórz zakładkę „Opis pól”. Każde pole ma cel, dozwolony format, przykład, skutek uzupełnienia i skutek pozostawienia pustego."],
    ["10","Sprawdzenie i import","Zapisz jako .xlsx. Plik działa w Excelu i Google Sheets; z Arkuszy Google pobierz go ponownie jako Microsoft Excel (.xlsx), a następnie użyj „Sprawdź plik”."],
  ];
  const title=kind==="ACCESS"?"SZAFUNEK — dostępy do aplikacji":kind==="FINANCE"?"SZAFUNEK — finanse zespołu":"SZAFUNEK — konfiguracja firmy krok po kroku";
  const content=[
    [title,"", ""],
    ["KROK","GDZIE PRZEJŚĆ","CO ZROBIĆ"],
    ...rows,
    ["Legenda","WYMAGANE = musi być uzupełnione • WARUNKOWE = wymagane tylko w opisanej sytuacji • OPCJONALNE = wypełnij, jeśli dotyczy • SYSTEM = nie zmieniaj","Wartości wybieraj z list. Nieznana wartość nigdy nie zostanie cicho zastąpiona inną."],
  ];
  sheet.spliceRows(1,Math.max(sheet.rowCount,content.length),...content);
  sheet.mergeCells("A1:C1");sheet.getCell("A1").value=title;
  sheet.getCell("A1").font={name:"Aptos Display",size:20,bold:true,color:{argb:"FFFFFFFF"}};sheet.getCell("A1").fill={type:"pattern",pattern:"solid",fgColor:{argb:argb(BRAND.primary)}};sheet.getCell("A1").alignment={vertical:"middle"};sheet.getRow(1).height=38;
  sheet.getColumn(1).width=14;sheet.getColumn(2).width=36;sheet.getColumn(3).width=100;
  sheet.views=[{state:"frozen",ySplit:2,showGridLines:false}];
  const header=sheet.getRow(2);header.height=28;header.eachCell(cell=>{cell.font={name:"Aptos",size:10,bold:true,color:{argb:"FFFFFFFF"}};cell.fill={type:"pattern",pattern:"solid",fgColor:{argb:argb(BRAND.primaryDark)}};cell.alignment={vertical:"middle"};});
  for(let row=3;row<=sheet.rowCount;row++){const current=sheet.getRow(row);current.height=row===sheet.rowCount?64:34;current.eachCell(cell=>{cell.font={name:"Aptos",size:10,color:{argb:argb(BRAND.ink)}};cell.alignment={vertical:"middle",wrapText:true};cell.border={bottom:{style:"thin",color:{argb:argb(BRAND.line)}}};});current.getCell(1).font={name:"Aptos",size:11,bold:true,color:{argb:argb(BRAND.primaryDark)}};}
}

function writeDynamicReferenceList(sheet:Worksheet,column:number,title:string,sourceSheet:string,nameColumn:string,codeColumn:string){
  sheet.getCell(1,column).value=title;
  for(let row=2;row<=501;row++){
    sheet.getCell(row,column).value={formula:`IF('${sourceSheet}'!$${nameColumn}${row}="","",'${sourceSheet}'!$${nameColumn}${row}&IF('${sourceSheet}'!$${codeColumn}${row}="",""," ["&'${sourceSheet}'!$${codeColumn}${row}&"]"))`};
  }
}

type TypedValidation={sheet:string;headers:string[];type:"decimal"|"whole"|"date"|"time";operator?:"between"|"greaterThanOrEqual";formulae?:Array<number|string>;prompt:string};
const QUICK_TYPED_VALIDATIONS:TypedValidation[]=[
  {sheet:"Firma",headers:["Minimalny odpoczynek (godz.)"],type:"decimal",formulae:[0,168],prompt:"Wpisz liczbę godzin od 0 do 168."},
  {sheet:"Firma",headers:["Maks. zmian jednego pracownika na dobę"],type:"whole",formulae:[1,24],prompt:"Wpisz liczbę całkowitą od 1 do 24."},
  {sheet:"Pracownicy",headers:["Koniec okresu próbnego","Zatrudniony od","Zatrudniony do"],type:"date",formulae:["2000-01-01","2200-12-31"],prompt:"Wpisz datę w formacie RRRR-MM-DD."},
  {sheet:"Pracownicy",headers:["Miesięczny cel godzin","Twardy limit miesięczny godzin","Limit tygodniowy godzin","Minimalny odpoczynek godzin"],type:"decimal",operator:"greaterThanOrEqual",formulae:[0],prompt:"Wpisz liczbę godzin nie mniejszą od zera."},
  {sheet:"Pracownicy",headers:["Maks. kolejnych dni"],type:"whole",formulae:[1,366],prompt:"Wpisz liczbę całkowitą od 1 do 366."},
  {sheet:"Zmiany",headers:["Od","Do"],type:"time",formulae:[0,0.99999],prompt:"Wpisz godzinę w formacie GG:MM."},
  {sheet:"Obsada",headers:["Liczba osób"],type:"whole",formulae:[1,1000],prompt:"Wpisz liczbę całkowitą co najmniej 1."},
  {sheet:"Pula ad-hoc",headers:["Stawka godzinowa"],type:"decimal",operator:"greaterThanOrEqual",formulae:[0],prompt:"Wpisz kwotę nie mniejszą od zera."},
  {sheet:"Pula ad-hoc",headers:["Dostępny od","Dostępny do"],type:"date",formulae:["2000-01-01","2200-12-31"],prompt:"Wpisz datę w formacie RRRR-MM-DD."},
];

function applyQuickTypedValidations(workbook:ExcelJS.Workbook){
  for(const rule of QUICK_TYPED_VALIDATIONS){
    const sheet=workbook.getWorksheet(rule.sheet);if(!sheet)continue;
    for(const header of rule.headers){
      const column=findColumn(sheet,header);if(!column)continue;
      for(let row=2;row<=501;row++)sheet.getCell(row,column).dataValidation={type:rule.type as never,operator:rule.operator??"between",allowBlank:true,formulae:rule.formulae??[],showErrorMessage:true,errorStyle:"stop",errorTitle:"Nieprawidłowa wartość",error:rule.prompt,showInputMessage:false};
    }
  }
}

async function protectQuickWorkbook(workbook:ExcelJS.Workbook){
  for(const sheet of workbook.worksheets){
    if(sheet.name==="Instrukcja"||sheet.name==="Opis pól")continue;
    const business=QUICK_WORKBOOK_SHEETS[sheet.name];
    if(business){
      for(let column=1;column<=usedColumnCount(sheet);column++){
        const header=baseHeader(String(sheet.getCell(1,column).value??""));
        const technical=business.fields[header]?.status==="SYSTEM";
        sheet.getColumn(column).hidden=technical;
        for(let row=2;row<=501;row++)sheet.getCell(row,column).protection={locked:technical};
      }
    }
    await sheet.protect("SZAFUNEK_TEMPLATE_V2",{selectLockedCells:false,selectUnlockedCells:true,formatCells:false,formatColumns:false,formatRows:false,insertRows:true,deleteRows:true,sort:true,autoFilter:true});
  }
}

const TECHNICAL_SHEET_PURPOSE:Record<string,string>={
  Firma:"Ustawienia wspólne firmy i generatora.","Kategorie grafików":"Grupy ról generowane i oceniane razem.",Role:"Role wymagane w obsadzie.","Grupy rezerwy":"Konfiguracja wspólnej gotowości wybranych ról.",Lokale:"Miejsca wykonywania pracy.",Obowiązki:"Kompetencje i zadania wewnątrz ról.",Pracownicy:"Profile planistyczne pracowników.",Zmiany:"Powtarzalne godziny pracy.",Obsada:"Wymagana liczba osób.","Role-Obowiązki":"Techniczne powiązania ról z obowiązkami.","Role pracowników":"Techniczna historia przypisań ról.","Lokale pracowników":"Techniczna historia dostępu do lokali.","Kompetencje pracowników":"Techniczna historia kompetencji.",Dostępność:"Dokładne okna dostępności i nieobecności.","Pula ad-hoc":"Osoby awaryjne proponowane do naprawy braków.",Scenariusze:"Bazowe i okresowe profile zapotrzebowania.",Strategie:"Definicje sposobów optymalizacji.","Kryteria strategii":"Matematyczne cele strategii.","Warianty scenariuszy":"Powiązania profili zapotrzebowania ze strategiami.","Zasady płacowe":"Reguły obliczania dodatków i kosztów.","Dodatki scenariuszy":"Nadpisania reguł płacowych dla profili zapotrzebowania.","Budżety scenariuszy":"Historyczny techniczny model budżetu profilu.","Finanse pracowników":"Okresy stawek podstawowych.",Dostępy:"Funkcje i zakres widoczności kont.",Słowniki:"Kody używane przez pełną kopię techniczną.",
};
function technicalField(sheet:string,field:string):WorkbookFieldDefinition{
  const status=headerKind(sheet,field)==="required"?"WYMAGANE":headerKind(sheet,field)==="system"?"SYSTEM":"OPCJONALNE";
  const booleanField=/^(Aktywn|Domyśln|Podstawowa|Może zatwierdzać|Zwykła praca|Dodatkowa praca|Lokal bazowy|Następny dzień|Włączona|Twardy limit|Bez weekendów)/u.test(field);
  const jsonField=/JSON/u.test(field);
  const codeField=/Kod|Kody/u.test(field);
  const input=booleanField?"Wybierz ☐ Nie albo ☑ Tak.":jsonField?"Nie edytuj ręcznie bez dokumentacji technicznej; wymagany jest poprawny obiekt JSON.":codeField?"Zachowaj stabilny kod z pełnej kopii; odwołania muszą wskazywać rekord z odpowiedniej zakładki.":"Zachowaj wartość z eksportu albo wpisz wartość zgodną z formatem pola.";
  return {status,purpose:`Pole techniczne „${field}” w obszarze: ${TECHNICAL_SHEET_PURPOSE[sheet]??"pełna kopia konfiguracji"}`,input,allowed:booleanField?"☐ Nie lub ☑ Tak":jsonField?"Poprawny JSON":codeField?"Kod istniejącego rekordu":"Format zachowany w eksporcie",example:"Wartość z pobranej pełnej kopii",effect:"Zmiana wpływa na techniczne odtworzenie tego rekordu podczas pełnego importu.",blank:status==="WYMAGANE"?"Pełne odtworzenie zostanie zablokowane.":"Pole zachowa wartość domyślną albo relacja nie zostanie utworzona.",application:"Pełna kopia techniczna; na co dzień użyj prostego pliku lub aplikacji."};
}
function addDataDictionary(workbook:ExcelJS.Workbook,kind:WorkbookKind){
  const existing=workbook.getWorksheet("Opis pól");if(existing)workbook.removeWorksheet(existing.id);
  const dictionary=workbook.addWorksheet("Opis pól");
  dictionary.addRow(["ZAKŁADKA","DO CZEGO SŁUŻY","KIEDY WYPEŁNIĆ","POLE","STATUS","CO WPISAĆ / JAK WYBRAĆ","DOZWOLONE WARTOŚCI / FORMAT","PRZYKŁAD","CO ZMIENI W APLIKACJI","CO JEŚLI POZOSTAWISZ PUSTE","GDZIE ZOBACZYSZ EFEKT"]);
  for(const sheet of workbook.worksheets){
    if(["Instrukcja","Opis pól","_LISTY","_META"].includes(sheet.name)||(kind!=="FULL"&&sheet.name==="Słowniki"))continue;
    const quick=kind==="QUICK"?QUICK_WORKBOOK_SHEETS[sheet.name]:undefined;
    const guided=kind==="ACCESS"&&sheet.name==="Dostępy"?ACCESS_GUIDE:kind==="FINANCE"&&sheet.name==="Finanse pracowników"?FINANCE_GUIDE:undefined;
    const purpose=quick?.purpose??guided?.purpose??TECHNICAL_SHEET_PURPOSE[sheet.name]??"Dane techniczne pełnej kopii konfiguracji.";
    const when=quick?.when??guided?.when??"Edytuj wyłącznie podczas świadomego pełnego odtwarzania; w codziennej pracy użyj odpowiedniego widoku aplikacji.";
    for(let column=1;column<=usedColumnCount(sheet);column++){
      const field=baseHeader(String(sheet.getRow(1).getCell(column).value??""));if(!field)continue;
      const definition=quick?.fields[field]??guided?.fields[field]??technicalField(sheet.name,field);
      dictionary.addRow([sheet.name,purpose,when,field,definition.status,definition.input,definition.allowed,definition.example,definition.effect,definition.blank,definition.application]);
    }
  }
  dictionary.views=[{state:"frozen",ySplit:1,showGridLines:false}];dictionary.autoFilter={from:{row:1,column:1},to:{row:dictionary.rowCount,column:11}};
  [24,54,58,34,16,66,54,34,62,62,44].forEach((width,index)=>dictionary.getColumn(index+1).width=width);
}

export type QuickWorkbookMode="EMPTY_TEMPLATE"|"CURRENT_CONFIG_EXPORT";
async function polish(input:ArrayBuffer|Uint8Array,kind:WorkbookKind,options?:{mode?:QuickWorkbookMode}){
  // Rebuild the SheetJS export in a fresh ExcelJS package. Loading and then
  // rewriting the same OOXML package produces files accepted by tolerant
  // readers but rejected by some desktop Excel builds (error 1004). Copying
  // the cell grid into a clean package avoids carrying incompatible metadata.
  const XLSX=await import("xlsx");
  const source=XLSX.read(input,{type:"array",cellDates:false});
  const workbook=new Workbook();
  for(const name of source.SheetNames){
    const sourceSheet=source.Sheets[name];
    const rows=XLSX.utils.sheet_to_json<unknown[]>(sourceSheet,{header:1,raw:true,defval:null});
    const sheet=workbook.addWorksheet(name);
    if(rows.length)sheet.addRows(rows);
  }
  if(kind==="QUICK"&&options?.mode){
    let meta=workbook.getWorksheet("_META");if(!meta)meta=workbook.addWorksheet("_META");
    const existing=new Map<string,unknown>();meta.eachRow((row,index)=>{if(index>1)existing.set(String(row.getCell(1).value??""),row.getCell(2).value);});
    meta.spliceRows(1,Math.max(1,meta.rowCount),["Klucz","Wartość"],["workbookMode",options.mode],["contractVersion","2"],
      ...[...existing].filter(([key])=>key==="sourceMatrixVersionId"||key==="companyBoundaryId").map(([key,value])=>[key,value]));
  }
  const instruction=workbook.getWorksheet("Instrukcja");if(instruction)formatInstruction(instruction,kind);
  addDataDictionary(workbook,kind);
  const adHoc=workbook.getWorksheet("Pula ad-hoc");if(adHoc)splitAdHocNames(adHoc);
  const sourceDictionaries=workbook.getWorksheet("Słowniki")??workbook.getWorksheet("_LISTY");
  const roleReferences:string[]=[],locationReferences:string[]=[],categoryReferences:string[]=[],dutyReferences:string[]=[],shiftReferences:string[]=[],accessRoles:string[]=[];
  const accessRoleLabels=new Map<string,string>(),roleLabels=new Map<string,string>(),locationLabels=new Map<string,string>();
  sourceDictionaries?.eachRow((row,index)=>{if(index===1)return;const type=String(row.getCell(1).value??"").trim(),code=String(row.getCell(2).value??"").trim(),name=String(row.getCell(3).value??"").trim();if(!code)return;const reference=referenceLabel(name,code);if(type==="ROLA"){roleReferences.push(reference);roleLabels.set(code,reference);}if(type==="LOKAL"){locationReferences.push(reference);locationLabels.set(code,reference);}if(type==="KATEGORIA GRAFIKU")categoryReferences.push(reference);if(type==="OBOWIĄZEK")dutyReferences.push(reference);if(type==="ZMIANA")shiftReferences.push(reference);if(type==="RODZAJ DOSTĘPU"){const label=name.split(" — ")[0]||code;accessRoles.push(label);accessRoleLabels.set(code,label);}});
  if(kind!=="FULL"&&sourceDictionaries?.name==="Słowniki")sourceDictionaries.state="hidden";
  let lists=workbook.getWorksheet("_LISTY");if(lists)workbook.removeWorksheet(lists.id);lists=workbook.addWorksheet("_LISTY",{state:"hidden"});
  writeList(lists,1,"Tak / nie",BOOL_VALUES);writeList(lists,2,"Etap zatrudnienia",EMPLOYMENT_STAGE_VALUES);writeList(lists,3,"Rodzaj umowy",CONTRACT_VALUES);writeList(lists,4,"Kolor",COLOR_VALUES);
  if(kind==="QUICK"){
    writeDynamicReferenceList(lists,5,"Role","Role","B","A");writeDynamicReferenceList(lists,6,"Lokale","Lokale","B","A");writeDynamicReferenceList(lists,7,"Kategorie","Kategorie grafików","B","A");
    writeDynamicReferenceList(lists,10,"Obowiązki","Obowiązki","B","A");writeDynamicReferenceList(lists,11,"Zmiany","Zmiany","B","A");writeDynamicReferenceList(lists,13,"Grupy rezerwy","Grupy rezerwy","B","A");
  }else{
    writeList(lists,5,"Role",roleReferences);writeList(lists,6,"Lokale",locationReferences);writeList(lists,7,"Kategorie",categoryReferences);writeList(lists,10,"Obowiązki",dutyReferences);writeList(lists,11,"Zmiany",shiftReferences);
  }
  writeList(lists,8,"Rodzaje dostępu",accessRoles);writeList(lists,9,"Zgoda na nadgodziny",OVERTIME_VALUES);writeList(lists,12,"Poziomy rezerwy",[1,2]);
  for(const sheet of workbook.worksheets){
    if(sheet.name==="_LISTY"||sheet.name==="_META"||sheet.name==="Instrukcja")continue;
    replaceBooleanValues(sheet);replaceEmploymentStages(sheet);replaceContracts(sheet);styleSheet(sheet,kind);
    const accessColumn=findColumn(sheet,"Rodzaj dostępu");
    if(accessColumn)for(let row=2;row<=usedRowCount(sheet);row++){const cell=sheet.getCell(row,accessColumn),label=accessRoleLabels.get(String(cell.value??"").trim());if(label)cell.value=label;}
    if(kind==="ACCESS"&&sheet.name==="Dostępy"){
      for(const [header,labels] of [["Zakres roli",roleLabels],["Zakres lokalu",locationLabels]] as const){
        const column=findColumn(sheet,header);if(!column)continue;
        for(let row=2;row<=usedRowCount(sheet);row++){const cell=sheet.getCell(row,column),label=labels.get(String(cell.value??"").trim());if(label)cell.value=label;}
      }
    }
    const dynamicEnd=kind==="QUICK"?501:undefined;
    const boolFormula=listFormula(lists,1,BOOL_VALUES.length);
    for(const label of ["Aktywna","Aktywny","Aktywne","Domyślny","Podstawowa","Może zatwierdzać","Zwykła praca","Dodatkowa praca","Lokal bazowy","Następny dzień","Kończy się następnego dnia","Włączona","Twardy limit","Brak dostępności oznacza dostępność","Brak wpisanej dostępności oznacza dostępność","Wymagaj wyniku optymalnego","Bez weekendów"])addListValidation(sheet,findColumn(sheet,label),boolFormula,"Wybierz ☐ Nie albo ☑ Tak.");
    addListValidation(sheet,findColumn(sheet,"Etap zatrudnienia"),listFormula(lists,2,EMPLOYMENT_STAGE_VALUES.length),"Wybierz etap zatrudnienia. Dla okresu próbnego uzupełnij również datę końca.");
    for(const label of ["Rodzaj umowy","Rodzaj współpracy"])addListValidation(sheet,findColumn(sheet,label),listFormula(lists,3,CONTRACT_VALUES.length),"Wybierz rodzaj umowy z listy.");
    addListValidation(sheet,findColumn(sheet,"Kolor"),listFormula(lists,4,COLOR_VALUES.length),"Wybierz kolor z gotowej palety.");
    for(const label of ["Kod roli","Kod roli podstawowej","Rola podstawowa","Rola dodatkowa 1","Rola dodatkowa 2","Rola dodatkowa 3","Rola","Zakres roli"])addListValidation(sheet,findColumn(sheet,label),listFormula(lists,5,roleReferences.length,dynamicEnd),"Wybierz rolę z listy. Jeśli lista jest pusta, najpierw dodaj rolę w zakładce „Role”.");
    for(const label of ["Kod lokalu","Lokal bazowy","Zakres lokalu","Lokal","Lokal pracy 1","Lokal pracy 2","Lokal pracy 3"])addListValidation(sheet,findColumn(sheet,label),listFormula(lists,6,locationReferences.length,dynamicEnd),"Wybierz lokal z listy. Jeśli lista jest pusta, najpierw dodaj lokal w zakładce „Lokale”.");
    for(const label of ["Kod kategorii","Kategoria grafiku"])addListValidation(sheet,findColumn(sheet,label),listFormula(lists,7,categoryReferences.length,dynamicEnd),"Wybierz kategorię z listy. Jeśli lista jest pusta, najpierw dodaj ją w zakładce „Kategorie grafików”.");
    addListValidation(sheet,findColumn(sheet,"Rodzaj dostępu"),listFormula(lists,8,accessRoles.length),"Wybierz rodzaj dostępu w języku użytkownika.");
    addListValidation(sheet,findColumn(sheet,"Zgoda na nadgodziny"),listFormula(lists,9,OVERTIME_VALUES.length),"NIE blokuje nadgodziny; TYLKO PO ZATWIERDZENIU pozostawia decyzję liderowi; TAK pozwala użyć nadgodzin dopiero po zwykłym wymiarze.");
    for(const label of ["Kod obowiązku","Obowiązek (opcjonalnie)","Kompetencja dodatkowa 1","Kompetencja dodatkowa 2","Kompetencja dodatkowa 3"])addListValidation(sheet,findColumn(sheet,label),listFormula(lists,10,dutyReferences.length,dynamicEnd),"Wybierz obowiązek z listy albo pozostaw puste, jeśli sama rola wystarcza.");
    for(const label of ["Kod zmiany","Zmiana"])addListValidation(sheet,findColumn(sheet,label),listFormula(lists,11,shiftReferences.length,dynamicEnd),"Wybierz zmianę z listy. Jeśli lista jest pusta, najpierw dodaj ją w zakładce „Zmiany”.");
    addListValidation(sheet,findColumn(sheet,"Grupa rezerwy"),listFormula(lists,13,0,dynamicEnd),"Wybierz grupę utworzoną w zakładce „Grupy rezerwy”.");
    addListValidation(sheet,findColumn(sheet,"Poziomy rezerwy"),listFormula(lists,12,2),"Wybierz 1 albo 2 poziomy rezerwy.");
  }
  if(kind==="QUICK"){
    applyQuickTypedValidations(workbook);
    workbook.calcProperties.fullCalcOnLoad=true;
    const meta=workbook.getWorksheet("_META");if(meta)meta.state="veryHidden";
    lists.state="veryHidden";
    await protectQuickWorkbook(workbook);
  }else{
    if(kind==="FINANCE"){
      const meta=workbook.getWorksheet("_META");if(meta)meta.state="veryHidden";
    }
    lists.state="hidden";
  }
  return new Uint8Array(await workbook.xlsx.writeBuffer());
}

export function polishMatrixWorkbook(input:ArrayBuffer|Uint8Array,variant:"QUICK"|"FULL",options?:{mode?:QuickWorkbookMode}){return polish(input,variant,options);}
export function polishAccessWorkbook(input:ArrayBuffer|Uint8Array){return polish(input,"ACCESS");}
export function polishFinanceWorkbook(input:ArrayBuffer|Uint8Array){return polish(input,"FINANCE");}

export function downloadWorkbook(bytes:Uint8Array,fileName:string){
  const blob=new Blob([bytes as BlobPart],{type:"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"});
  const href=URL.createObjectURL(blob),anchor=document.createElement("a");anchor.href=href;anchor.download=fileName;document.body.appendChild(anchor);anchor.click();anchor.remove();URL.revokeObjectURL(href);
}
