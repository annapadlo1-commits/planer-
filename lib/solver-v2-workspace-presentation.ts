import type { CSSProperties } from "react";
import type { SolverWorkloadDistributionRow } from "@/lib/solver-v2";

export function money(value: number | null, currency: string) {
  if (value === null) return "Bez limitu";
  try {
    return new Intl.NumberFormat("pl-PL", {
      style: "currency",
      currency,
      maximumFractionDigits: 2,
    }).format(value / 100);
  } catch {
    return `${new Intl.NumberFormat("pl-PL", { maximumFractionDigits: 2 }).format(value / 100)} ${currency}`;
  }
}

export function dateLabel(value: string) {
  const date = new Date(`${value.slice(0, 10)}T12:00:00Z`);
  if (Number.isNaN(date.getTime())) return "Termin zmiany";
  return new Intl.DateTimeFormat("pl-PL", {
    weekday: "long",
    day: "numeric",
    month: "long",
    timeZone: "UTC",
  }).format(date);
}

export function monthLabel(value: string) {
  const date = new Date(`${value.slice(0, 7)}-01T12:00:00Z`);
  if (Number.isNaN(date.getTime())) return "Wybrany miesiąc";
  return new Intl.DateTimeFormat("pl-PL", { month: "long", year: "numeric", timeZone: "UTC" }).format(date);
}

export function timeLabel(value: string, timezone: string) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat("pl-PL", {
    hour: "2-digit", minute: "2-digit", timeZone: timezone,
  }).format(date);
}

export function workloadHours(minutes:number){
  const hours=minutes/60;
  return `${new Intl.NumberFormat("pl-PL",{maximumFractionDigits:1}).format(hours)} h`;
}

export function workloadReason(row:SolverWorkloadDistributionRow){
  if(row.maximumMonthlyMinutes>0&&row.totalMonthlyMinutes>row.maximumMonthlyMinutes)return `BŁĄD: łączny bilans miesiąca przekracza twardy limit o ${workloadHours(row.totalMonthlyMinutes-row.maximumMonthlyMinutes)}. Tego wariantu nie wolno publikować.`;
  if(row.reasonCode==="AVAILABILITY_LIMITED")return `Ograniczenie dostępności: ${row.hardUnavailableDays} dni twardej niedostępności w tym miesiącu.`;
  if(row.reasonCode==="AVAILABILITY_WINDOW_LIMITED")return `Pracownik podał konkretne okna dostępności w ${row.availableWindowDays} dniach; silnik mógł planować tylko wewnątrz nich.`;
  if(row.reasonCode==="MAXIMUM_REACHED")return "Osiągnięto twardy miesięczny limit godzin. Silnik nie może dodać kolejnego przydziału.";
  if(row.reasonCode==="TARGET_NOT_SET")return "Nie ustawiono miesięcznego celu godzinowego. Osoba uczestniczy w równym podziale przez wspólną bazę dla umów bez nominału.";
  if(row.reasonCode==="ABOVE_NOMINAL")return "Przydział przekracza miesięczny wymiar. Lider powinien sprawdzić koszt i zgodność z umową przed publikacją.";
  if(row.reasonCode==="ON_TARGET")return "Przydział jest zgodny z ustawionym miesięcznym wymiarem.";
  return "Brak indywidualnej twardej blokady dostępności. Różnica wynika z rozdziału solvera, zapotrzebowania zmian i reguł całego zespołu.";
}

export function workloadReasonCode(row:SolverWorkloadDistributionRow){
  return row.maximumMonthlyMinutes>0&&row.totalMonthlyMinutes>row.maximumMonthlyMinutes?"ABOVE_MAXIMUM":row.reasonCode;
}

const rolePalette=[
  {accent:"#879681",background:"#F2EDE4"},
  {accent:"#138b7d",background:"#e5f7f3"},
  {accent:"#d45a54",background:"#fff0ee"},
  {accent:"#d17b20",background:"#fff4e5"},
  {accent:"#2879bd",background:"#eaf5ff"},
  {accent:"#b44785",background:"#fcecf5"},
];
const dutyPalette=[
  {accent:"#756135",background:"#fff7dc"},
  {accent:"#2f6f69",background:"#e9f7f5"},
  {accent:"#55665A",background:"#F2EDE4"},
  {accent:"#8a5135",background:"#fff0e8"},
  {accent:"#3f5f8a",background:"#edf3ff"},
];
const locationPalette=[
  {accent:"#246b9c",background:"#eaf5ff"},
  {accent:"#a65338",background:"#fff0e9"},
  {accent:"#2d7d5e",background:"#e9f8f1"},
  {accent:"#879681",background:"#F2EDE4"},
];

// FNV-1a keeps colours deterministic between renders while avoiding the heavy
// collisions produced by a plain sum of character codes.
export function stablePaletteIndex(value:string,length:number){
  let hash=0x811c9dc5;
  for(const character of value){
    hash^=character.charCodeAt(0);
    hash=Math.imul(hash,0x01000193)>>>0;
  }
  return length>0?hash%length:0;
}

export function roleStyle(roleId:string):CSSProperties{
  const index=stablePaletteIndex(roleId,rolePalette.length);
  return {"--role-accent":rolePalette[index].accent,"--role-background":rolePalette[index].background} as CSSProperties;
}

export function dutyStyle(dutyId:string):CSSProperties{
  const index=stablePaletteIndex(dutyId,dutyPalette.length);
  return {color:dutyPalette[index].accent,backgroundColor:dutyPalette[index].background};
}

export function locationStyle(locationId:string):CSSProperties{
  const index=stablePaletteIndex(locationId,locationPalette.length);
  return {"--location-accent":locationPalette[index].accent,"--location-background":locationPalette[index].background} as CSSProperties;
}

export function assignmentStyle(roleId:string,locationId:string):CSSProperties{
  return {...roleStyle(roleId),...locationStyle(locationId)};
}

export function monthWeeks(value:string){
  const [year,month]=value.slice(0,7).split("-").map(Number);
  const first=new Date(Date.UTC(year,month-1,1));
  const last=new Date(Date.UTC(year,month,0));
  const firstMonday=new Date(first);
  firstMonday.setUTCDate(first.getUTCDate()-((first.getUTCDay()+6)%7));
  const lastSunday=new Date(last);
  lastSunday.setUTCDate(last.getUTCDate()+(7-((last.getUTCDay()+6)%7)-1));
  const weeks:string[][]=[];
  for(const cursor=new Date(firstMonday);cursor<=lastSunday;cursor.setUTCDate(cursor.getUTCDate()+7)){
    weeks.push(Array.from({length:7},(_,day)=>{
      const date=new Date(cursor);date.setUTCDate(cursor.getUTCDate()+day);
      return date.toISOString().slice(0,10);
    }));
  }
  return weeks;
}

export function shortDayLabel(value:string){
  return new Intl.DateTimeFormat("pl-PL",{weekday:"short",day:"numeric",month:"short",timeZone:"UTC"}).format(new Date(`${value}T12:00:00Z`));
}

export function timestampLabel(value: string | null | undefined, timezone: string) {
  if (!value) return null;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return null;
  return new Intl.DateTimeFormat("pl-PL", {
    day: "numeric",
    month: "long",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    timeZone: timezone,
  }).format(date);
}

export function publicationStatus(value?: string) {
  if (value === "PUBLISHED") return "Opublikowany";
  if (value === "ARCHIVED") return "Zarchiwizowany";
  return "Gotowy do publikacji";
}

const hardReasonLabels:Record<string,string>={ROLE_REQUIRED:"Brak wymaganej roli",LOCATION_NOT_ALLOWED:"Lokal nie jest dozwolony w zwykłym limicie",LOCATION_REQUIRED:"Lokal nie jest dozwolony w zwykłym limicie",DUTY_REQUIRED:"Brak wymaganej kompetencji",SHIFT_OVERLAP:"Nakładająca się zmiana",OVERLAPPING_SHIFT:"Nakładająca się zmiana",ONE_PRIMARY_SHIFT_PER_DAY:"Osiągnięty dzienny limit zmian z konfiguracji firmy",CONSECUTIVE_SHIFT_SEQUENCE:"To byłaby ostatnia zmiana dnia, a następnego dnia pierwsza — albo pierwsza po ostatniej zmianie poprzedniego dnia",STANDBY_TIER_1_RESERVED:"Pracownik jest tego dnia opublikowany jako pierwszy rezerwowy",STANDBY_TIER_2_RESERVED:"Pracownik jest tego dnia opublikowany jako drugi rezerwowy",DECLARED_UNAVAILABLE:"Pracownik zgłosił twardą niedostępność, urlop albo L4",TIME_CONSTRAINT:"Niedostępność, urlop lub L4",OUTSIDE_AVAILABILITY_WINDOW:"Zmiana poza zadeklarowanym oknem dostępności",MISSING_AVAILABILITY:"Brak deklaracji dostępności, gdy konfiguracja firmy jawnie jej wymaga",OUTSIDE_EMPLOYMENT:"Data poza okresem współpracy",WEEKEND_BLOCKED:"Pracownik ma zablokowane weekendy",REST_AFTER_PREVIOUS_SHIFT:"Za krótki odpoczynek po poprzedniej zmianie",REST_BEFORE_NEXT_SHIFT:"Za krótki odpoczynek przed następną zmianą",MINIMUM_REST:"Za krótki odpoczynek",MONTHLY_LIMIT:"Przekroczony indywidualny limit miesięczny",WEEKLY_LIMIT:"Przekroczony indywidualny limit tygodniowy",MAX_CONSECUTIVE_DAYS:"Przekroczona maksymalna liczba kolejnych dni pracy",MANAGER_SHIFT_BLOCK:"Pracodawca zablokował tę zmianę w konfiguracji firmy"};
const softReasonLabels:Record<string,string>={SHIFT_PREFERENCE_AVOIDED:"Pracownik prosi, aby unikać tej pory",SHIFT_AVOIDED:"Pracownik prosi, aby unikać tej pory",OVERTIME_AFTER_ASSIGNMENT:"Po dopisaniu przekroczy nominał miesięczny",MONTHLY_OVERTIME:"Po dopisaniu przekroczy nominał miesięczny"};
export function reasonLabel(value:string){return hardReasonLabels[value]??softReasonLabels[value]??value;}
export function availabilityLabel(value:string){return ({AVAILABLE:"Dostępny • wolne okno i limit dzienny",SOFT_AVOID:"Dostępny, ale woli nie pracować",HARD_UNAVAILABLE:"Twarda niedostępność / urlop / L4",PERMANENT_WORK_PATTERN:"Stały wzorzec pracy blokuje tę zmianę",SHIFT_CONFLICT:"Ma już zmianę w tym czasie",DAILY_LIMIT:"Osiągnięty dzienny limit zmian",OUTSIDE_AVAILABLE_WINDOW:"Poza zgłoszonym oknem dostępności"} as Record<string,string>)[value]??"Wymaga sprawdzenia";}
export function preferenceLevelLabel(value:string){
  return ({PREFERRED:"preferowana",NEUTRAL:"neutralna",AVOIDED:"unikać",BLOCKED:"zablokowana"} as Record<string,string>)[value]??value;
}
