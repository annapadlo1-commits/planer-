"use client";

import { AlertTriangle, ArrowLeftRight, BarChart3, CalendarDays, Check, CircleDollarSign, Edit3, MapPin, Plus, RefreshCw, Search, ShieldCheck, Trash2, Users, X } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import type { CSSProperties } from "react";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { emergencyAssignV2, getCandidateDiagnostics, getEmployeeAvailabilityMonth, getLeaderAssignmentContext, getManagerStandbyMonth, getVariantIssueDiagnostics, getVariantStandbyPreview, getVariantWorkloadDistribution, removeLeaderAssignment, saveLeaderAssignment, solverErrorMessage, type SolverCandidateDiagnostic, type SolverCandidateDiagnostics, type SolverEmployeeDayAvailability, type SolverLeaderAssignmentContext, type SolverManagerStandby, type SolverVariantIssueDiagnostics, type SolverWorkloadDistributionRow, type SolverWorkspace, type SolverWorkspaceIssue } from "@/lib/solver-v2";

type Props = {
  workspace: SolverWorkspace;
  timezone: string;
  published?: boolean;
  operational?: boolean;
  onOperationalChanged?:()=>void|Promise<void>;
  notify?:(message:string)=>void;
  fail?:(message:string)=>void;
  leaderEditable?:boolean;
  onLeaderChanged?:()=>void|Promise<void>;
};

function money(value: number | null, currency: string) {
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

function dateLabel(value: string) {
  const date = new Date(`${value.slice(0, 10)}T12:00:00Z`);
  if (Number.isNaN(date.getTime())) return "Termin zmiany";
  return new Intl.DateTimeFormat("pl-PL", {
    weekday: "long",
    day: "numeric",
    month: "long",
    timeZone: "UTC",
  }).format(date);
}

function monthLabel(value: string) {
  const date = new Date(`${value.slice(0, 7)}-01T12:00:00Z`);
  if (Number.isNaN(date.getTime())) return "Wybrany miesiąc";
  return new Intl.DateTimeFormat("pl-PL", { month: "long", year: "numeric", timeZone: "UTC" }).format(date);
}

function timeLabel(value: string, timezone: string) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat("pl-PL", {
    hour: "2-digit", minute: "2-digit", timeZone: timezone,
  }).format(date);
}

function workloadHours(minutes:number){
  const hours=minutes/60;
  return `${new Intl.NumberFormat("pl-PL",{maximumFractionDigits:1}).format(hours)} h`;
}

function workloadReason(row:SolverWorkloadDistributionRow){
  if(row.maximumMonthlyMinutes>0&&row.plannedMinutes>row.maximumMonthlyMinutes)return `BŁĄD: grafik przekracza twardy limit o ${workloadHours(row.plannedMinutes-row.maximumMonthlyMinutes)}. Tego wariantu nie wolno publikować.`;
  if(row.reasonCode==="AVAILABILITY_LIMITED")return `Ograniczenie dostępności: ${row.hardUnavailableDays} dni twardej niedostępności w tym miesiącu.`;
  if(row.reasonCode==="AVAILABILITY_WINDOW_LIMITED")return `Pracownik podał konkretne okna dostępności w ${row.availableWindowDays} dniach; silnik mógł planować tylko wewnątrz nich.`;
  if(row.reasonCode==="MAXIMUM_REACHED")return "Osiągnięto twardy miesięczny limit godzin. Silnik nie może dodać kolejnego przydziału.";
  if(row.reasonCode==="TARGET_NOT_SET")return "Nie ustawiono miesięcznego celu godzinowego. Osoba uczestniczy w równym podziale przez wspólną bazę dla umów bez nominału.";
  if(row.reasonCode==="ABOVE_NOMINAL")return "Przydział przekracza miesięczny wymiar. Lider powinien sprawdzić koszt i zgodność z umową przed publikacją.";
  if(row.reasonCode==="ON_TARGET")return "Przydział jest zgodny z ustawionym miesięcznym wymiarem.";
  return "Brak indywidualnej twardej blokady dostępności. Różnica wynika z rozdziału solvera, zapotrzebowania zmian i reguł całego zespołu.";
}

function workloadReasonCode(row:SolverWorkloadDistributionRow){
  return row.maximumMonthlyMinutes>0&&row.plannedMinutes>row.maximumMonthlyMinutes?"ABOVE_MAXIMUM":row.reasonCode;
}

type WorkspaceView="CALENDAR"|"WORKLOAD"|"ISSUES";
type SchedulePerspective="EMPLOYEES"|"ROLES"|"COVERAGE";

const rolePalette=[
  {accent:"#6848d8",background:"#f0ebff"},
  {accent:"#138b7d",background:"#e5f7f3"},
  {accent:"#d45a54",background:"#fff0ee"},
  {accent:"#d17b20",background:"#fff4e5"},
  {accent:"#2879bd",background:"#eaf5ff"},
  {accent:"#b44785",background:"#fcecf5"},
];
const dutyPalette=[
  {accent:"#756135",background:"#fff7dc"},
  {accent:"#2f6f69",background:"#e9f7f5"},
  {accent:"#7a4e88",background:"#f8eefb"},
  {accent:"#8a5135",background:"#fff0e8"},
  {accent:"#3f5f8a",background:"#edf3ff"},
];
const locationPalette=[
  {accent:"#246b9c",background:"#eaf5ff"},
  {accent:"#a65338",background:"#fff0e9"},
  {accent:"#2d7d5e",background:"#e9f8f1"},
  {accent:"#8155a0",background:"#f5edfb"},
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

function roleStyle(roleId:string):CSSProperties{
  const index=stablePaletteIndex(roleId,rolePalette.length);
  return {"--role-accent":rolePalette[index].accent,"--role-background":rolePalette[index].background} as CSSProperties;
}

function dutyStyle(dutyId:string):CSSProperties{
  const index=stablePaletteIndex(dutyId,dutyPalette.length);
  return {color:dutyPalette[index].accent,backgroundColor:dutyPalette[index].background};
}

function locationStyle(locationId:string):CSSProperties{
  const index=stablePaletteIndex(locationId,locationPalette.length);
  return {"--location-accent":locationPalette[index].accent,"--location-background":locationPalette[index].background} as CSSProperties;
}

function assignmentStyle(roleId:string,locationId:string):CSSProperties{
  return {...roleStyle(roleId),...locationStyle(locationId)};
}

function monthWeeks(value:string){
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

function shortDayLabel(value:string){
  return new Intl.DateTimeFormat("pl-PL",{weekday:"short",day:"numeric",month:"short",timeZone:"UTC"}).format(new Date(`${value}T12:00:00Z`));
}

function timestampLabel(value: string | null | undefined, timezone: string) {
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

function publicationStatus(value?: string) {
  if (value === "PUBLISHED") return "Opublikowany";
  if (value === "ARCHIVED") return "Zarchiwizowany";
  return "Gotowy do publikacji";
}

const hardReasonLabels:Record<string,string>={ROLE_REQUIRED:"Brak wymaganej roli",LOCATION_NOT_ALLOWED:"Lokal nie jest dozwolony w zwykłym limicie",LOCATION_REQUIRED:"Lokal nie jest dozwolony w zwykłym limicie",DUTY_REQUIRED:"Brak wymaganej kompetencji",SHIFT_OVERLAP:"Nakładająca się zmiana",OVERLAPPING_SHIFT:"Nakładająca się zmiana",ONE_PRIMARY_SHIFT_PER_DAY:"Osiągnięty dzienny limit zmian z konfiguracji firmy",CONSECUTIVE_SHIFT_SEQUENCE:"To byłaby ostatnia zmiana dnia, a następnego dnia pierwsza — albo pierwsza po ostatniej zmianie poprzedniego dnia",STANDBY_TIER_1_RESERVED:"Pracownik jest tego dnia opublikowany jako pierwszy rezerwowy",STANDBY_TIER_2_RESERVED:"Pracownik jest tego dnia opublikowany jako drugi rezerwowy",DECLARED_UNAVAILABLE:"Pracownik zgłosił twardą niedostępność, urlop albo L4",TIME_CONSTRAINT:"Niedostępność, urlop lub L4",OUTSIDE_AVAILABILITY_WINDOW:"Zmiana poza zadeklarowanym oknem dostępności",MISSING_AVAILABILITY:"Brak deklaracji dostępności, gdy konfiguracja firmy jawnie jej wymaga",OUTSIDE_EMPLOYMENT:"Data poza okresem współpracy",WEEKEND_BLOCKED:"Pracownik ma zablokowane weekendy",REST_AFTER_PREVIOUS_SHIFT:"Za krótki odpoczynek po poprzedniej zmianie",REST_BEFORE_NEXT_SHIFT:"Za krótki odpoczynek przed następną zmianą",MINIMUM_REST:"Za krótki odpoczynek",MONTHLY_LIMIT:"Przekroczony indywidualny limit miesięczny",WEEKLY_LIMIT:"Przekroczony indywidualny limit tygodniowy",MAX_CONSECUTIVE_DAYS:"Przekroczona maksymalna liczba kolejnych dni pracy",MANAGER_SHIFT_BLOCK:"Pracodawca zablokował tę zmianę w konfiguracji firmy"};
const softReasonLabels:Record<string,string>={SHIFT_PREFERENCE_AVOIDED:"Pracownik prosi, aby unikać tej pory",SHIFT_AVOIDED:"Pracownik prosi, aby unikać tej pory",OVERTIME_AFTER_ASSIGNMENT:"Po dopisaniu przekroczy nominał miesięczny",MONTHLY_OVERTIME:"Po dopisaniu przekroczy nominał miesięczny"};
function reasonLabel(value:string){return hardReasonLabels[value]??softReasonLabels[value]??value;}
function availabilityLabel(value:string){return ({AVAILABLE:"Dostępny • wolne okno i limit dzienny",SOFT_AVOID:"Dostępny, ale woli nie pracować",HARD_UNAVAILABLE:"Twarda niedostępność / urlop / L4",SHIFT_CONFLICT:"Ma już zmianę w tym czasie",DAILY_LIMIT:"Osiągnięty dzienny limit zmian",OUTSIDE_AVAILABLE_WINDOW:"Poza zgłoszonym oknem dostępności"} as Record<string,string>)[value]??"Wymaga sprawdzenia";}
function preferenceLevelLabel(value:string){
  return ({PREFERRED:"preferowana",NEUTRAL:"neutralna",AVOIDED:"unikać",BLOCKED:"zablokowana"} as Record<string,string>)[value]??value;
}

function WorkspaceIssueCard({issue,timezone,operational,published,busy,inspect,explainPreview,previewAvailable,leaderEditable,editLeader}:{issue:SolverWorkspaceIssue;timezone:string;operational:boolean;published:boolean;busy:boolean;inspect:(id:string)=>void;explainPreview:(id:string)=>void;previewAvailable:boolean;leaderEditable:boolean;editLeader:(id:string)=>void}){
  const shift=issue.shift;
  const shiftTimezone=shift?.location.timezone??timezone;
  const required=issue.requiredCount;
  const assigned=issue.assignedCount;
  const missing=required===null?null:Math.max(0,required-(assigned??0));
  return <article id={`solver-issue-${issue.id}`}>
    <header><span><strong>{issue.message}</strong><small>{issue.severity==="CRITICAL"?"BLOKADA KRYTYCZNA":issue.severity==="WARNING"?"OSTRZEŻENIE":"INFORMACJA"}</small></span></header>
    {shift&&<div className="solver-issue-context"><span><CalendarDays/><b>{dateLabel(shift.date)}</b></span><span><MapPin/><b>{shift.location.name}</b></span><span>{timeLabel(shift.startsAt,shiftTimezone)}–{timeLabel(shift.endsAt,shiftTimezone)} • {shift.shiftTemplate.name}</span></div>}
    {issue.role&&<div className="solver-issue-requirements"><span>Wymagana rola: <b>{issue.role.name}</b></span><span>Dodatkowy obowiązek: <b>{issue.duty?.name??"brak — wystarczy rola"}</b></span></div>}
    {required!==null&&<div className="solver-issue-staffing"><span>Wymagane <b>{required}</b></span><span>Przypisane <b>{assigned??0}</b></span><span>Brakuje <b>{missing}</b></span></div>}
    {operational&&published&&issue.code==="UNFILLED_SLOT"&&<button className="secondary-button" disabled={busy} onClick={()=>inspect(issue.id)}>{busy?<RefreshCw className="spin"/>:<Users/>} Dlaczego nikt nie został przypisany?</button>}
    {!operational&&previewAvailable&&issue.code==="UNFILLED_SLOT"&&<button className="secondary-button" disabled={busy} onClick={()=>explainPreview(issue.id)}>{busy?<RefreshCw className="spin"/>:<Users/>} Co blokowało kandydatów?</button>}
    {leaderEditable&&issue.code==="UNFILLED_SLOT"&&<button className="primary-button" disabled={busy} onClick={()=>editLeader(issue.id)}><Plus/> Uzupełnij w wersji lidera</button>}
  </article>;
}

export function SolverV2Workspace({ workspace, timezone, published = false, operational=false, onOperationalChanged, notify, fail, leaderEditable=false, onLeaderChanged }: Props) {
  const supabase=useMemo(()=>createSupabaseBrowserClient(),[]);
  const [diagnostics,setDiagnostics]=useState<SolverCandidateDiagnostics|null>(null);
  const [variantDiagnostics,setVariantDiagnostics]=useState<SolverVariantIssueDiagnostics|null>(null);
  const [diagnosticsLoading,setDiagnosticsLoading]=useState(false);
  const [variantDiagnosticsLoading,setVariantDiagnosticsLoading]=useState(false);
  const [selectedEmployee,setSelectedEmployee]=useState("");
  const [notifyEmployee,setNotifyEmployee]=useState(true);
  const [standby,setStandby]=useState<SolverManagerStandby[]>([]);
  const [standbyError,setStandbyError]=useState("");
  const [standbyAction,setStandbyAction]=useState<SolverManagerStandby|null>(null);
  const [standbyTargetAssignmentId,setStandbyTargetAssignmentId]=useState("");
  const [standbyReason,setStandbyReason]=useState("");
  const [leaderContext,setLeaderContext]=useState<SolverLeaderAssignmentContext|null>(null);
  const [leaderEmployeeId,setLeaderEmployeeId]=useState("");
  const [leaderSearch,setLeaderSearch]=useState("");
  const [leaderReason,setLeaderReason]=useState("");
  const [leaderFeedback,setLeaderFeedback]=useState("");
  const [leaderLimitWarning,setLeaderLimitWarning]=useState("");
  const [leaderBusy,setLeaderBusy]=useState(false);
  const [workspaceView,setWorkspaceView]=useState<WorkspaceView>("CALENDAR");
  const [schedulePerspective,setSchedulePerspective]=useState<SchedulePerspective>("EMPLOYEES");
  const [locationFilter,setLocationFilter]=useState("");
  const [employeeDetailId,setEmployeeDetailId]=useState("");
  const [employeeDetailSeed,setEmployeeDetailSeed]=useState<{id:string;name:string;employeeNo:string}|null>(null);
  const [comparisonEmployeeId,setComparisonEmployeeId]=useState("");
  const [comparisonAvailability,setComparisonAvailability]=useState<SolverEmployeeDayAvailability[]>([]);
  const [comparisonAvailabilityLoading,setComparisonAvailabilityLoading]=useState(false);
  const [workloadRows,setWorkloadRows]=useState<SolverWorkloadDistributionRow[]|null>(null);
  const [workloadLoading,setWorkloadLoading]=useState(false);
  const [workloadError,setWorkloadError]=useState("");
  const [workloadSearch,setWorkloadSearch]=useState("");
  const [workloadReasonFilter,setWorkloadReasonFilter]=useState("");
  const [workloadSort,setWorkloadSort]=useState<"HOURS_DESC"|"HOURS_ASC"|"DIFFERENCE">("HOURS_DESC");
  const workspaceVariantId=workspace.variants[0]?.id??"";
  const workspaceIdentity=`${workspace.context.type}:${workspace.context.runId??workspace.context.scheduleId??workspace.context.sourceVariantId??workspaceVariantId}:${workspaceVariantId}`;
  const scopeRoleId=workspace.variants[0]?.scope.role?.id??null;
  useEffect(()=>{
    // React reuses the drawer when another strategy is opened. Variant-bound
    // state must be cleared so workload and diagnostics can never be shown for
    // a different variant than the one named in the header.
    setWorkspaceView("CALENDAR");
    setSchedulePerspective("EMPLOYEES");
    setLocationFilter("");
    setWorkloadRows(null);
    setWorkloadError("");
    setWorkloadSearch("");
    setWorkloadReasonFilter("");
    setEmployeeDetailId("");
    setEmployeeDetailSeed(null);
    setComparisonEmployeeId("");
    setComparisonAvailability([]);
    setDiagnostics(null);
    setVariantDiagnostics(null);
    setLeaderContext(null);
  },[workspaceIdentity]);
  useEffect(()=>{
    const variantId=workspace.variants[0]?.id;
    const employeeIds=[employeeDetailId,comparisonEmployeeId].filter(Boolean);
    if(!supabase||!variantId||!employeeIds.length){setComparisonAvailability([]);return;}
    let active=true;setComparisonAvailabilityLoading(true);
    void getEmployeeAvailabilityMonth(supabase,variantId,employeeIds)
      .then(rows=>{if(active)setComparisonAvailability(rows);})
      .catch(()=>{if(active)setComparisonAvailability([]);})
      .finally(()=>{if(active)setComparisonAvailabilityLoading(false);});
    return()=>{active=false;};
  },[comparisonEmployeeId,employeeDetailId,supabase,workspaceVariantId]);
  useEffect(()=>{
    let active=true;
    if(!supabase){setStandby([]);return;}
    setStandbyError("");
    const variantId=workspace.variants[0]?.id;
    const request=published
      ? getManagerStandbyMonth(supabase,workspace.context.month,scopeRoleId)
      : variantId?getVariantStandbyPreview(supabase,variantId):Promise.resolve([]);
    void request
      .then(rows=>{if(active)setStandby(rows);})
      .catch(error=>{if(active)setStandbyError(solverErrorMessage(error instanceof Error?error.message:String(error)));});
    return()=>{active=false;};
  },[published,scopeRoleId,supabase,workspace.context.month,workspace.variants]);
  const workspaceLocations=[...new Map(workspace.shifts.map(shift=>[shift.location.id,shift.location])).values()].sort((a,b)=>a.name.localeCompare(b.name,"pl-PL"));
  const visibleShifts=workspace.shifts.filter(shift=>!locationFilter||shift.location.id===locationFilter);
  const visibleIssues=workspace.issues.filter(issue=>!locationFilter||issue.shift?.location.id===locationFilter);
  const shiftsByDate = new Map<string, typeof workspace.shifts>();
  for (const shift of visibleShifts) {
    shiftsByDate.set(shift.date, [...(shiftsByDate.get(shift.date) ?? []), shift]);
  }
  const dates = [...shiftsByDate.entries()].sort(([left], [right]) => left.localeCompare(right));
  const weeks=monthWeeks(workspace.context.month);
  const scheduleEntries=visibleShifts.flatMap(shift=>shift.assignments.map(assignment=>({shift,assignment})));
  const assignedRoleNamesByEmployee=scheduleEntries.reduce((roles,entry)=>{
    const current=roles.get(entry.assignment.employee.id)??new Set<string>();
    current.add(entry.assignment.role.name);
    roles.set(entry.assignment.employee.id,current);
    return roles;
  },new Map<string,Set<string>>());
  const scheduleEmployees=[...new Map(scheduleEntries.map(entry=>[entry.assignment.employee.id,entry.assignment.employee])).values()].sort((left,right)=>`${left.lastName} ${left.firstName}`.localeCompare(`${right.lastName} ${right.firstName}`,"pl-PL"));
  const scheduleRoles=[...new Map(scheduleEntries.map(entry=>[entry.assignment.role.id,entry.assignment.role])).values()].sort((left,right)=>left.name.localeCompare(right.name,"pl-PL"));
  const assignmentCount = scheduleEntries.length;
  const unfilledIssues=visibleIssues.filter(issue=>issue.code==="UNFILLED_SLOT");
  const missingSeats=(issue:SolverWorkspaceIssue)=>issue.requiredCount===null
    ? 1
    : Math.max(0,issue.requiredCount-(issue.assignedCount??0));
  const unfilledCount=unfilledIssues.reduce((sum,issue)=>sum+missingSeats(issue),0);
  const groupMissing=(label:(issue:SolverWorkspaceIssue)=>string)=>[...unfilledIssues.reduce((groups,issue)=>{
    const key=label(issue)||"Nieokreślone";
    groups.set(key,(groups.get(key)??0)+missingSeats(issue));
    return groups;
  },new Map<string,number>()).entries()].sort((left,right)=>right[1]-left[1]||left[0].localeCompare(right[0],"pl-PL"));
  const missingByRole=groupMissing(issue=>issue.role?.name??"Brak wskazanej roli");
  const missingByLocation=groupMissing(issue=>issue.shift?.location.name??"Brak wskazanego lokalu");
  const missingByShift=group…8492 tokens truncated…loyeeDetailWorkload.nominalMonthlyMinutes>0?`${employeeDetailWorkload.differenceMinutes>0?"+":""}${workloadHours(employeeDetailWorkload.differenceMinutes)}`:"—"}</strong></span>
        </div>}
        <div className="employee-compare-toolbar"><label><ArrowLeftRight/> Porównaj z<select value={comparisonEmployeeId} onChange={event=>setComparisonEmployeeId(event.target.value)}><option value="">Nie porównuj</option>{scheduleEmployees.filter(employee=>employee.id!==employeeDetail.id).map(employee=><option value={employee.id} key={employee.id}>{employee.lastName} {employee.firstName} • {employee.employeeNo}</option>)}</select></label><small>Nakładamy oba grafiki tydzień po tygodniu. Obowiązki i lokale są widoczne przy każdej zmianie; każda korekta przechodzi końcową kontrolę serwera.</small></div>
        <div className="employee-compare-legend"><span className="primary-person">{employeeDetailName}</span>{comparisonEmployee&&<span className="comparison-person">{comparisonEmployee.firstName} {comparisonEmployee.lastName}</span>}</div>
        <section className="employee-availability-comparison" aria-label="Dostępność porównywanych pracowników">
          <header><strong>Dostępność dzień po dniu</strong><small>{comparisonAvailabilityLoading?"Sprawdzamy deklaracje…":"Kolor rozróżnia dostępność od samego wolnego miejsca w grafiku."}</small></header>
          <div>{weeks.flat().filter((date,index,all)=>date.slice(0,7)===workspace.context.month.slice(0,7)&&all.indexOf(date)===index).map(date=><article key={date}><b>{shortDayLabel(date)}</b>{[employeeDetail.id,comparisonEmployee?.id].filter(Boolean).map(employeeId=>{const row=comparisonAvailability.find(item=>item.employeeId===employeeId&&item.date===date);const person=employeeId===employeeDetail.id?employeeDetailShortName:comparisonEmployee?.firstName;return <span className={`availability-${(row?.status??"unknown").toLowerCase()}`} key={employeeId}><em>{person}</em><small>{row?.scheduled?"Ma zmianę • ":""}{row?.label??"Sprawdzamy dostępność"}</small></span>;})}</article>)}</div>
        </section>
        {leaderEditable&&!comparisonEmployee&&<div className="swap-suggestion-hint"><ArrowLeftRight/><span><strong>Możliwe zamiany dla {employeeDetailShortName}</strong><small>Przy każdej zmianie wybierz „Możliwa zamiana”. Otworzymy wyszukiwalną listę osób z wolnym oknem oraz analizą obowiązku.</small></span></div>}
        <div className="employee-compare-weeks">{weeks.map((week,weekIndex)=><section key={week[0]}><header><strong>Tydzień {weekIndex+1}</strong><small>{shortDayLabel(week[0])} – {shortDayLabel(week[6])}</small></header><div>{week.filter(date=>date.slice(0,7)===workspace.context.month.slice(0,7)).map(date=>{const primary=employeeEntries(employeeDetail.id,date);const compared=comparisonEmployee?employeeEntries(comparisonEmployee.id,date):[];return <article className="employee-compare-day" key={date}><header><CalendarDays/><strong>{shortDayLabel(date)}</strong></header><div className="employee-compare-slots"><section><small>{employeeDetailShortName}</small>{primary.map(({shift,assignment})=><div style={assignmentStyle(assignment.role.id,shift.location.id)} key={assignment.id}><span><b>{timeLabel(shift.startsAt,shift.location.timezone??timezone)}–{timeLabel(shift.endsAt,shift.location.timezone??timezone)}</b><small>{shift.location.name} • {assignment.role.name}</small></span>{assignment.duties.length>0&&<span className="solver-week-duties">{assignment.duties.map(duty=><em style={dutyStyle(duty.id)} key={duty.id}>{duty.name}</em>)}</span>}{leaderEditable&&!comparisonEmployee&&<button type="button" className="possible-swap-day" onClick={()=>void openLeaderEdit({assignmentId:assignment.id})}><ArrowLeftRight/> Możliwa zamiana</button>}{leaderEditable&&comparisonEmployee&&<button aria-label="Edytuj przydział" onClick={()=>void openLeaderEdit({assignmentId:assignment.id})}><Edit3/></button>}</div>)}{!primary.length&&<p>Wolne</p>}</section>{comparisonEmployee&&<section><small>{comparisonEmployee.firstName}</small>{compared.map(({shift,assignment})=><div style={assignmentStyle(assignment.role.id,shift.location.id)} key={assignment.id}><span><b>{timeLabel(shift.startsAt,shift.location.timezone??timezone)}–{timeLabel(shift.endsAt,shift.location.timezone??timezone)}</b><small>{shift.location.name} • {assignment.role.name}</small></span>{assignment.duties.length>0&&<span className="solver-week-duties">{assignment.duties.map(duty=><em style={dutyStyle(duty.id)} key={duty.id}>{duty.name}</em>)}</span>}{leaderEditable&&<button aria-label="Edytuj przydział" onClick={()=>void openLeaderEdit({assignmentId:assignment.id})}><Edit3/></button>}</div>)}{!compared.length&&<p>Wolne</p>}</section>}</div>{comparisonEmployee&&((primary.length&&!compared.length)||(!primary.length&&compared.length))&&<button type="button" className="swap-opportunity" disabled={!leaderEditable} onClick={()=>void openLeaderEdit({assignmentId:(primary[0]??compared[0]).assignment.id,preferredEmployeeId:primary.length?comparisonEmployee.id:employeeDetail.id})}><ArrowLeftRight/> Sprawdź, czy {primary.length?comparisonEmployee.firstName:employeeDetailShortName} może przejąć tę zmianę. System najpierw kontroluje rolę, lokal i obowiązek, a przy zapisie cały miesiąc.</button>}</article>})}</div></section>)}</div>
      </div>
    </aside></>}

    {leaderContext&&<><button className="drawer-scrim top" onClick={()=>setLeaderContext(null)}/><aside className="drawer role-drawer top leader-assignment-drawer">
      <div className="drawer-head"><div><p className="eyebrow">WERSJA LIDERA • EDYCJA PRZED PUBLIKACJĄ</p><h2>{leaderContext.shift.date} • {leaderContext.shift.shiftName}</h2><small>{leaderContext.shift.locationName} • {leaderContext.role.name} • {timeLabel(leaderContext.shift.startsAt,timezone)}–{timeLabel(leaderContext.shift.endsAt,timezone)}</small></div><button className="icon-button" onClick={()=>setLeaderContext(null)}><X/></button></div>
      <div className="drawer-content">
        <div className="solver-v2-notice"><ShieldCheck/><span><strong>Oryginalne warianty nie zostaną zmienione</strong><small>Ta korekta dotyczy tylko kopii lidera. Przed zapisem serwer ponownie sprawdzi cały miesiąc, wszystkie twarde reguły oraz koszty.</small></span></div>
        <div className="leader-candidate-picker"><label>Znajdź pracownika<input value={leaderSearch} onChange={event=>setLeaderSearch(event.target.value)} placeholder="Wpisz nazwisko, numer, rolę, lokal lub obowiązek"/></label><div className="leader-candidate-summary"><span><b>{eligibleLeaderCandidates}</b> można bezpiecznie sprawdzić</span><span><b>{blockedLeaderCandidates}</b> ma blokadę lub brak pokrycia obowiązku</span></div><div>{visibleLeaderCandidates.map(candidate=><button type="button" disabled={!candidate.suggestionEligible} className={`${leaderEmployeeId===candidate.employeeId?"selected":""} ${candidate.suggestionEligible?"eligible":"blocked"}`} onClick={()=>{setLeaderEmployeeId(candidate.employeeId);setLeaderFeedback("");setLeaderLimitWarning("");}} key={candidate.employeeId}><span><strong>{candidate.employeeName}</strong><small>{candidate.employeeNo}{candidate.current?" • obecnie":""} • {availabilityLabel(candidate.availabilityStatus)}</small><em>{candidate.dutyCoverageMode==="DIRECT"?(leaderContext.duty?`Ma obowiązek: ${leaderContext.duty.name}`:"Rola i lokal pasują"):candidate.dutyCoverageMode==="TRANSFER"?`${candidate.dutyTransferEmployeeName} przejmie obowiązek „${leaderContext.duty?.name}”`:`Brak pokrycia obowiązku „${leaderContext.duty?.name}”`}</em></span>{leaderEmployeeId===candidate.employeeId&&<Check/>}</button>)}</div>{!visibleLeaderCandidates.length&&<p>Brak kandydatów spełniających wyszukiwanie.</p>}<small>Lista pokazuje cały zespół, a nie czterech „aktywnych” pracowników: zielone osoby można sprawdzić i zapisać, wyszarzone mają podany konkretny powód blokady. Przy zamianie trójstronnej serwer może przenieść obowiązek, a na końcu kontroluje cały miesiąc.</small></div>
        <label>Powód zmiany<textarea required minLength={3} value={leaderReason} onChange={event=>setLeaderReason(event.target.value)} placeholder="np. uzgodniona zamiana w zespole"/></label>
        {leaderFeedback&&<div className="solver-v2-notice warning" role="status"><AlertTriangle/><span><strong>Status zapisu</strong><small>{leaderFeedback}</small></span></div>}
        {leaderLimitWarning&&<div className="solver-v2-notice danger" role="alert"><AlertTriangle/><span><strong>Świadomy wyjątek od limitu</strong><small>{leaderLimitWarning} Solver automatyczny nadal nie wykona takiego przydziału. Ręczny wyjątek będzie widoczny w audycie wraz z podanym wyżej powodem.</small></span></div>}
        <div className="leader-edit-actions">{leaderContext.assignmentId&&<button className="danger-button" disabled={leaderBusy} onClick={()=>void removeLeaderEdit()}><Trash2/> Usuń przydział</button>}{leaderLimitWarning&&<button className="danger-button" disabled={leaderBusy||leaderReason.trim().length<3} onClick={()=>void saveLeaderEdit(true)}><AlertTriangle/> Przypisz mimo limitu</button>}<button className="primary-button" disabled={leaderBusy} onClick={()=>void saveLeaderEdit()}>{leaderBusy?<RefreshCw className="spin"/>:<Check/>} Sprawdź i zapisz</button></div>
      </div>
    </aside></>}


    {variantDiagnostics&&<><button className="drawer-scrim top" onClick={()=>setVariantDiagnostics(null)}/><aside className="drawer role-drawer top candidate-diagnostics-drawer">
      <div className="drawer-head"><div><p className="eyebrow">WARIANT • WYJAŚNIENIE BRAKU</p><h2>{variantDiagnostics.shift.date} • {timeLabel(variantDiagnostics.shift.startsAt,timezone)}–{timeLabel(variantDiagnostics.shift.endsAt,timezone)}</h2><small>Powody są liczone dla pracowników dostępnych w opublikowanej konfiguracji firmy i aktualnego składu tego wariantu.</small></div><button className="icon-button" onClick={()=>setVariantDiagnostics(null)}><X/></button></div>
      <div className="drawer-content">
        <div className="candidate-diagnostics-summary"><span><b>{variantDiagnostics.summary.considered}</b><small>sprawdzonych osób</small></span><span><b>{variantDiagnostics.summary.eligible}</b><small>bez blokady</small></span><span><b>{variantDiagnostics.summary.blocked}</b><small>z blokadą</small></span></div>
        {variantDiagnostics.decisionContext&&<div className="solver-v2-notice warning"><AlertTriangle/><span><strong>Dlaczego powstał ten brak</strong><small>{variantDiagnostics.decisionContext.message} Ten błąd poprzedniej wersji silnika został naprawiony: rezerwa nie może już zmniejszać wymaganej obsady.</small></span></div>}
        {variantDiagnostics.summary.eligible>0&&!variantDiagnostics.decisionContext&&<div className="solver-v2-notice warning"><AlertTriangle/><span><strong>{variantDiagnostics.summary.eligible} osób nie ma indywidualnej twardej blokady</strong><small>{leaderEditable?"Wróć do listy braków i użyj „Uzupełnij w wersji lidera”. System sprawdzi wtedy cały miesiąc przed zapisem.":variantDiagnostics.publishedScheduleId?"To nie gwarantuje, że dopisanie zachowa poprawność całego miesiąca. Przycisk wykona ponowną kontrolę globalną przed zapisem.":"Silnik mógł wykorzystać te osoby w innym miejscu. Utwórz wersję lidera, aby poprawić grafik przed publikacją."}</small></span></div>}
        <p className="candidate-count-explainer">Liczba „z blokadą” oznacza unikalne osoby. Sumy w kategoriach mogą być większe, bo jedna osoba może mieć kilka powodów jednocześnie.</p>
        <div className="variant-reason-list">{variantDiagnostics.summary.reasons.map(reason=><details key={reason.code}><summary><span><strong>{reasonLabel(reason.code)}</strong><small>Kliknij, aby zobaczyć osoby i szczegóły</small></span><b>{reason.count} os.</b></summary><div>{variantDiagnostics.candidates.filter(candidate=>candidate.reasons.includes(reason.code)).map(candidate=><article key={candidate.employeeId}><span><strong>{candidate.employeeName}</strong><small>{candidate.employeeNo}</small></span>{candidate.blockingDetails?.filter(detail=>detail.code===reason.code).map((detail,index)=><p key={`${detail.code}:${index}`}><b>{detail.label}</b>{detail.shiftName?` • ${detail.shiftName}`:""}{detail.locationName?` • ${detail.locationName}`:""}{detail.startsAt?` • ${timeLabel(detail.startsAt,timezone)}–${timeLabel(detail.endsAt??detail.startsAt,timezone)}`:""}{detail.createdAt?` • zgłoszono ${timestampLabel(detail.createdAt,timezone)}`:""}</p>)}</article>)}</div></details>)}</div>
        {variantDiagnostics.candidates.some(candidate=>candidate.roleMatch)&&<section className="variant-role-candidates"><div><h3>Pracownicy z wymaganą rolą</h3><p>Kliknij osobę, aby bez wychodzenia z analizy zobaczyć jej kalendarz, aktualne godziny, liczbę zmian, cel i twardy limit. Rola i dodatkowy obowiązek są sprawdzane osobno.</p></div>{variantDiagnostics.candidates.filter(candidate=>candidate.roleMatch).map(candidate=>{const workload=(workloadRows??[]).find(row=>row.employeeId===candidate.employeeId);const onlyLimitRisk=candidate.reasons.length>0&&candidate.reasons.every(reason=>reason==="WEEKLY_LIMIT"||reason==="MONTHLY_LIMIT");return <article key={candidate.employeeId}><button type="button" className="candidate-calendar-link" onClick={()=>openEmployeeCalendar(candidate)}><span><strong>{candidate.employeeName}</strong><small>{candidate.employeeNo} • {candidate.locationMatch?"lokal pasuje":"lokal nie pasuje"}{candidate.dutyMatch?" • wymagany obowiązek pasuje":" • brak wymaganego obowiązku"}</small></span><em><CalendarDays/> {workload?`${workloadHours(workload.plannedMinutes)} • ${workload.shiftCount} zmian • cel ${workload.nominalMonthlyMinutes>0?workloadHours(workload.nominalMonthlyMinutes):"brak"}`:"Otwórz kalendarz i bilans"}</em></button>{candidate.reasons.length?<><ul>{candidate.reasons.map(reason=><li key={reason}>{reasonLabel(reason)}</li>)}</ul>{candidate.blockingDetails?.map((detail,index)=><small className="candidate-block-detail" key={`${detail.code}:${index}`}>{detail.label}{detail.shiftName?` • ${detail.shiftName}`:""}{detail.locationName?` • ${detail.locationName}`:""}{detail.startsAt?` • ${timeLabel(detail.startsAt,timezone)}–${timeLabel(detail.endsAt??detail.startsAt,timezone)}`:""}</small>)}{leaderEditable&&onlyLimitRisk&&<button className="danger-button" onClick={()=>{const issueId=variantDiagnostics.issueId;setVariantDiagnostics(null);void openLeaderEdit({issueId,preferredEmployeeId:candidate.employeeId});}}><AlertTriangle/> Przypisz w wersji lidera</button>}</>:<div className="candidate-eligible-actions"><b className="candidate-eligible">Brak indywidualnej blokady</b>{variantDiagnostics.publishedScheduleId&&<button className="primary-button" disabled={variantDiagnosticsLoading} onClick={()=>void assignVariantCandidate(candidate)}>{variantDiagnosticsLoading&&selectedEmployee===candidate.employeeId?<RefreshCw className="spin"/>:<Plus/>} Sprawdź i dopisz do grafiku</button>}</div>}</article>})}</section>}
        {!variantDiagnostics.summary.reasons.length&&<p>Nie znaleziono twardych blokad kandydatów. Ten przypadek wymaga kontroli celów strategii i materiału wejściowego solvera.</p>}
      </div>
    </aside></>}
    {diagnostics&&<><button className="drawer-scrim top" onClick={()=>setDiagnostics(null)}/><aside className="drawer role-drawer top candidate-diagnostics-drawer">
      <div className="drawer-head"><div><p className="eyebrow">GRAFIK OPERACYJNY • DIAGNOSTYKA BRAKU</p><h2>{diagnostics.shift.date} • {timeLabel(diagnostics.shift.startsAt,activeDiagnosticIssue?.shift?.location.timezone??timezone)}–{timeLabel(diagnostics.shift.endsAt,activeDiagnosticIssue?.shift?.location.timezone??timezone)}</h2><small>{[activeDiagnosticIssue?.shift?.location.name,activeDiagnosticIssue?.role?.name,activeDiagnosticIssue?.duty?.name].filter(Boolean).join(" • ")||diagnostics.issue.message}</small></div><button className="icon-button" onClick={()=>setDiagnostics(null)}><X/></button></div>
      <div className="drawer-content">
        <div className="candidate-diagnostics-summary"><span><b>{diagnostics.summary.considered}</b><small>rozważonych</small></span><span><b>{diagnostics.summary.eligible}</b><small>można przypisać</small></span><span><b>{diagnostics.summary.warning}</b><small>awaryjnie</small></span><span><b>{diagnostics.summary.blocked}</b><small>blokada twarda</small></span></div>
        <p>Każdy pracownik ma wyjaśnienie decyzji solvera oraz aktualne obciążenie przed dopisaniem.</p>
        <div className="candidate-diagnostics-list">{diagnostics.candidates.map(candidate=><article className={candidate.classification.toLowerCase()} key={candidate.employeeId}>
          <header><span><strong>{candidate.name}</strong><small>{candidate.employeeNo}</small></span><em>{candidate.classification==="ELIGIBLE"?"MOŻNA PRZYPISAĆ":candidate.classification==="WARNING"?"MOŻNA AWARYJNIE":"BLOKADA TWARDA"}</em></header>
          <dl><div><dt>Zmiany w miesiącu</dt><dd>{candidate.monthlyShifts}</dd></div><div><dt>Godziny miesiąca</dt><dd>{Math.round(candidate.monthlyMinutes/60)} godz. • {candidate.nominalMonthlyMinutes>0?`wymiar ${Math.round(candidate.nominalMonthlyMinutes/60)} godz.`:"wymiar nieustawiony"} • {candidate.maximumMonthlyMinutes>0?`limit ${Math.round(candidate.maximumMonthlyMinutes/60)} godz.`:"limit nieustawiony"}</dd></div><div><dt>Godziny tygodnia</dt><dd>{Math.round(candidate.weeklyMinutes/60)} godz. / {candidate.maximumWeeklyMinutes>0?`limit ${Math.round(candidate.maximumWeeklyMinutes/60)} godz.`:"limit nieustawiony"}</dd></div><div><dt>Kolejne dni po dopisaniu</dt><dd>{candidate.projectedConsecutiveDays} / limit {candidate.maximumConsecutiveDays} ({candidate.consecutiveDaysBefore} przed • {candidate.consecutiveDaysAfter} po)</dd></div><div><dt>Poprzednia zmiana</dt><dd>{candidate.previousShift?`${candidate.previousShift.date} • ${timeLabel(candidate.previousShift.startsAt,timezone)}–${timeLabel(candidate.previousShift.endsAt,timezone)}`:"brak"}</dd></div><div><dt>Następna zmiana</dt><dd>{candidate.nextShift?`${candidate.nextShift.date} • ${timeLabel(candidate.nextShift.startsAt,timezone)}–${timeLabel(candidate.nextShift.endsAt,timezone)}`:"brak"}</dd></div><div><dt>Dostępność</dt><dd>{candidate.declaredUnavailable?"zgłoszona niedostępność":candidate.outsideAvailableWindow?"poza oknem dostępności":"zgodna z deklaracją"}</dd></div><div><dt>Sąsiednie dni</dt><dd>{candidate.worksPreviousDay?"pracuje dzień wcześniej":"wolne dzień wcześniej"} • {candidate.worksNextDay?"pracuje dzień później":"wolne dzień później"}</dd></div><div><dt>Preferencja</dt><dd>{preferenceLevelLabel(candidate.preferenceLevel)}</dd></div></dl>
          {[...candidate.hardReasons,...candidate.softReasons].length>0?<ul>{candidate.hardReasons.map(reason=><li key={reason}><ShieldCheck/> {reasonLabel(reason)}</li>)}{candidate.softReasons.map(reason=><li key={reason}><AlertTriangle/> {reasonLabel(reason)}</li>)}</ul>:<p className="candidate-ok"><Check/> Brak konfliktów i naruszeń.</p>}
          <button className={candidate.classification==="WARNING"?"danger-button":"primary-button"} disabled={diagnosticsLoading||candidate.classification==="BLOCKED"} onClick={()=>{setSelectedEmployee(candidate.employeeId);void assign(candidate);}}>{diagnosticsLoading&&selectedEmployee===candidate.employeeId?<RefreshCw className="spin"/>:<Plus/>} {candidate.classification==="WARNING"?"Dopisz awaryjnie":"Dopisz pracownika"}</button>
        </article>)}</div>
        <label className="check-label"><input type="checkbox" checked={notifyEmployee} onChange={event=>setNotifyEmployee(event.target.checked)}/> Powiadom pracownika po skutecznym zapisie</label>
      </div>
    </aside></>}
  </section>;
}

