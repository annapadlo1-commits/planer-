"use client";

import { AlertTriangle, ArrowLeftRight, BarChart3, CalendarDays, Check, CircleDollarSign, Edit3, LockKeyhole, LockOpen, MapPin, Plus, RefreshCw, Search, ShieldCheck, Trash2, Users, X } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import type { CSSProperties } from "react";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { bulkLeaderAssignments, dragLeaderAssignment, emergencyAssignV2, getCandidateDiagnostics, getEmployeeAvailabilityMonth, getLeaderAssignmentContext, getManagerStandbyMonth, getVariantIssueDiagnostics, getVariantStandbyPreview, getVariantWorkloadDistribution, previewLeaderAssignmentDrag, removeLeaderAssignment, saveLeaderAssignment, setLeaderAssignmentLock, validateLeaderAssignment, solverErrorMessage, type SolverCandidateDiagnostic, type SolverCandidateDiagnostics, type SolverEmployeeDayAvailability, type SolverLeaderAssignmentContext, type SolverManagerStandby, type SolverVariantIssueDiagnostics, type SolverWorkloadDistributionRow, type SolverWorkspace, type SolverWorkspaceIssue } from "@/lib/solver-v2";

type Props = {
  workspace: SolverWorkspace;
  baselineWorkspace?: SolverWorkspace | null;
  timezone: string;
  published?: boolean;
  operational?: boolean;
  onOperationalChanged?:()=>void|Promise<void>;
  notify?:(message:string)=>void;
  fail?:(message:string)=>void;
  leaderEditable?:boolean;
  onLeaderChanged?:()=>void|Promise<void>;
  onOpenAdHoc?:(context:{roleId:string|null;date:string|null})=>void;
  initialView?:WorkspaceView;
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
type LeaderCandidateView="ELIGIBLE"|"ALL"|"BELOW_TARGET"|"PREFERRED";
type FinanceVisibility="NONE"|"BUDGET_ONLY"|"AGGREGATE"|"FULL";

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

function WorkspaceIssueCard({issue,timezone,operational,published,busy,inspect,explainPreview,previewAvailable,leaderEditable,editLeader,onOpenAdHoc}:{issue:SolverWorkspaceIssue;timezone:string;operational:boolean;published:boolean;busy:boolean;inspect:(id:string)=>void;explainPreview:(id:string)=>void;previewAvailable:boolean;leaderEditable:boolean;editLeader:(id:string)=>void;onOpenAdHoc?:(context:{roleId:string|null;date:string|null})=>void}){
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
    {leaderEditable&&issue.code==="UNFILLED_SLOT"&&onOpenAdHoc&&<button className="secondary-button" disabled={busy} onClick={()=>onOpenAdHoc({roleId:issue.role?.id??null,date:issue.shift?.date??null})}><Users/> Sprawdź pulę ad-hoc</button>}
  </article>;
}

export function SolverV2Workspace({ workspace, baselineWorkspace=null, timezone, published = false, operational=false, onOperationalChanged, notify, fail, leaderEditable=false, onLeaderChanged, onOpenAdHoc, initialView="CALENDAR" }: Props) {
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
  const [leaderOvertimeWarning,setLeaderOvertimeWarning]=useState(false);
  const [leaderValidatedKey,setLeaderValidatedKey]=useState("");
  const [leaderBusy,setLeaderBusy]=useState(false);
  const [bulkOperation,setBulkOperation]=useState<"LOCK"|"UNLOCK"|"REMOVE"|null>(null);
  const [bulkReason,setBulkReason]=useState("");
  const [selectedAssignmentIds,setSelectedAssignmentIds]=useState<string[]>([]);
  const [dragPreview,setDragPreview]=useState<{key:string;loading:boolean;valid:boolean;message:string}|null>(null);
  const [pendingAssignmentDrag,setPendingAssignmentDrag]=useState<{sourceAssignmentId:string;targetAssignmentId?:string;targetIssueId?:string}|null>(null);
  const [leaderCandidateView,setLeaderCandidateView]=useState<LeaderCandidateView>("ELIGIBLE");
  const [workspaceView,setWorkspaceView]=useState<WorkspaceView>(initialView);
  const [schedulePerspective,setSchedulePerspective]=useState<SchedulePerspective>("EMPLOYEES");
  const [locationFilter,setLocationFilter]=useState("");
  const [roleFilters,setRoleFilters]=useState<string[]>([]);
  const [employeeDetailId,setEmployeeDetailId]=useState("");
  const [employeeDetailSeed,setEmployeeDetailSeed]=useState<{id:string;name:string;employeeNo:string}|null>(null);
  const [comparisonEmployeeId,setComparisonEmployeeId]=useState("");
  const [comparisonAvailability,setComparisonAvailability]=useState<SolverEmployeeDayAvailability[]>([]);
  const [comparisonAvailabilityLoading,setComparisonAvailabilityLoading]=useState(false);
  const [workloadRows,setWorkloadRows]=useState<SolverWorkloadDistributionRow[]|null>(null);
  const [workloadVariantId,setWorkloadVariantId]=useState("");
  const [workloadLoading,setWorkloadLoading]=useState(false);
  const [workloadError,setWorkloadError]=useState("");
  const [workloadSearch,setWorkloadSearch]=useState("");
  const [workloadReasonFilter,setWorkloadReasonFilter]=useState("");
  const [workloadSort,setWorkloadSort]=useState<"HOURS_DESC"|"HOURS_ASC"|"DIFFERENCE">("HOURS_DESC");
  const [financeVisibility,setFinanceVisibility]=useState<FinanceVisibility>("NONE");
  const workspaceVariantId=workspace.variants[0]?.id??"";
  const workspaceIdentity=`${workspace.context.type}:${workspace.context.runId??workspace.context.scheduleId??workspace.context.sourceVariantId??workspaceVariantId}:${workspaceVariantId}`;
  const scopeRoleId=workspace.variants[0]?.scope.role?.id??null;
  useEffect(()=>{
    let active=true;
    setFinanceVisibility("NONE");
    if(!supabase)return()=>{active=false;};
    void supabase.rpc("application_finance_visibility_current_uat_v1")
      .then(({data,error})=>{
        if(!active||error)return;
        const value=typeof data==="string"?data:Array.isArray(data)&&typeof data[0]==="string"?data[0]:"NONE";
        if(value==="NONE"||value==="BUDGET_ONLY"||value==="AGGREGATE"||value==="FULL")setFinanceVisibility(value);
      });
    return()=>{active=false;};
  },[supabase]);
  useEffect(()=>{
    // React reuses the drawer when another strategy is opened. Variant-bound
    // state must be cleared so workload and diagnostics can never be shown for
    // a different variant than the one named in the header.
    setWorkspaceView(initialView);
    setSchedulePerspective("EMPLOYEES");
    setLocationFilter("");
    setWorkloadRows(null);
    setWorkloadVariantId("");
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
  },[initialView,workspaceIdentity]);
  useEffect(()=>{
    if(initialView!=="WORKLOAD"||!supabase||!workspaceVariantId)return;
    let active=true;
    setWorkloadLoading(true);
    setWorkloadError("");
    void getVariantWorkloadDistribution(supabase,workspaceVariantId)
      .then(rows=>{if(active){setWorkloadRows(rows);setWorkloadVariantId(workspaceVariantId);}})
      .catch(error=>{if(active)setWorkloadError(solverErrorMessage(error instanceof Error?error.message:String(error)));})
      .finally(()=>{if(active)setWorkloadLoading(false);});
    return()=>{active=false;};
  },[initialView,supabase,workspaceIdentity,workspaceVariantId]);
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
  const workspaceRoles=[...new Map([...workspace.shifts.flatMap(shift=>shift.assignments.map(assignment=>[assignment.role.id,assignment.role] as const)),...workspace.issues.flatMap(issue=>issue.role?[[issue.role.id,issue.role] as const]:[])]).values()].sort((a,b)=>a.name.localeCompare(b.name,"pl-PL"));
  const visibleIssues=workspace.issues.filter(issue=>(!locationFilter||issue.shift?.location.id===locationFilter)&&(!roleFilters.length||(issue.role&&roleFilters.includes(issue.role.id))));
  const visibleShifts=workspace.shifts.filter(shift=>(!locationFilter||shift.location.id===locationFilter)&&(!roleFilters.length||shift.assignments.some(assignment=>roleFilters.includes(assignment.role.id))||visibleIssues.some(issue=>issue.shift?.id===shift.id)));
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
  const baselineSlotEmployees=useMemo(()=>new Map((baselineWorkspace?.shifts??[]).flatMap(shift=>shift.assignments.map(assignment=>[assignment.slotKey,assignment.employee.id] as const))),[baselineWorkspace]);
  const currentSlotEmployees=useMemo(()=>new Map(workspace.shifts.flatMap(shift=>shift.assignments.map(assignment=>[assignment.slotKey,assignment.employee.id] as const))),[workspace.shifts]);
  const modifiedAssignmentCount=useMemo(()=>Array.from(new Set([...baselineSlotEmployees.keys(),...currentSlotEmployees.keys()])).filter(slot=>baselineSlotEmployees.get(slot)!==currentSlotEmployees.get(slot)).length,[baselineSlotEmployees,currentSlotEmployees]);
  const baselineAssignmentCount=baselineSlotEmployees.size;
  const baselineUnfilledCount=(baselineWorkspace?.issues??[]).filter(issue=>issue.code==="UNFILLED_SLOT").reduce((sum,issue)=>sum+missingSeats(issue),0);
  const baselineCostMinor=baselineWorkspace?.finance?.totalCostMinor??null;
  const groupMissing=(label:(issue:SolverWorkspaceIssue)=>string)=>[...unfilledIssues.reduce((groups,issue)=>{
    const key=label(issue)||"Nieokreślone";
    groups.set(key,(groups.get(key)??0)+missingSeats(issue));
    return groups;
  },new Map<string,number>()).entries()].sort((left,right)=>right[1]-left[1]||left[0].localeCompare(right[0],"pl-PL"));
  const missingByRole=groupMissing(issue=>issue.role?.name??"Brak wskazanej roli");
  const missingByLocation=groupMissing(issue=>issue.shift?.location.name??"Brak wskazanego lokalu");
  const missingByShift=groupMissing(issue=>issue.shift?.shiftTemplate.name??"Brak wskazanej zmiany");
  const staffingRiskRows=[...unfilledIssues.reduce((groups,issue)=>{
    const date=issue.shift?.date??"Brak daty";
    const role=issue.role?.name??"Brak wskazanej roli";
    const location=issue.shift?.location.name??"Brak wskazanego lokalu";
    const key=`${date}:${issue.role?.id??role}:${issue.shift?.location.id??location}`;
    const required=Math.max(0,issue.requiredCount??1);
    const assigned=Math.max(0,issue.assignedCount??0);
    const current=groups.get(key)??{key,date,role,location,required:0,assigned:0,missing:0};
    current.required+=required;current.assigned+=assigned;current.missing+=missingSeats(issue);
    groups.set(key,current);return groups;
  },new Map<string,{key:string;date:string;role:string;location:string;required:number;assigned:number;missing:number}>()).values()]
    .map(row=>({...row,coverage:row.required?Math.round(row.assigned/row.required*100):0}))
    .sort((left,right)=>left.coverage-right.coverage||right.missing-left.missing||left.date.localeCompare(right.date));
  const publishedAt = timestampLabel(workspace.context.publishedAt, timezone);
  const activeDiagnosticIssue=diagnostics?workspace.issues.find(issue=>issue.id===diagnostics.issue.id)??null:null;
  const currentWorkloadRows=workloadVariantId===workspaceVariantId?workloadRows:null;
  const filteredWorkload=(currentWorkloadRows??[]).filter(row=>{
    const normalize=(value:string)=>value.normalize("NFD").replace(/[\u0300-\u036f]/g,"").toLocaleLowerCase("pl-PL");
    const search=normalize(workloadSearch.trim());
    const assignedRoleNames=[...(assignedRoleNamesByEmployee.get(row.employeeId)??[])];
    const searchable=normalize(`${row.employeeName} ${row.employeeNo} ${row.roleNames.join(" ")} ${assignedRoleNames.join(" ")}`);
    return (!search||searchable.includes(search))
      &&(!locationFilter||row.locations.some(location=>location.id===locationFilter))
      &&(!roleFilters.length||row.roleNames.some(name=>workspaceRoles.some(role=>roleFilters.includes(role.id)&&role.name===name)))
      &&(!workloadReasonFilter||row.reasonCode===workloadReasonFilter);
  }).sort((left,right)=>workloadSort==="HOURS_ASC"?left.plannedMinutes-right.plannedMinutes
    :workloadSort==="DIFFERENCE"?Math.abs(right.differenceMinutes)-Math.abs(left.differenceMinutes)
    :right.plannedMinutes-left.plannedMinutes||left.employeeName.localeCompare(right.employeeName,"pl-PL"));
  const workloadMinutes=filteredWorkload.map(row=>row.plannedMinutes).sort((a,b)=>a-b);
  const workloadOverMaximum=filteredWorkload.filter(row=>row.maximumMonthlyMinutes>0&&row.plannedMinutes>row.maximumMonthlyMinutes).length;
  const workloadMedian=workloadMinutes.length?(workloadMinutes[Math.floor((workloadMinutes.length-1)/2)]+workloadMinutes[Math.ceil((workloadMinutes.length-1)/2)])/2:0;

  async function loadWorkload(force=false){
    if(currentWorkloadRows&&!force||workloadLoading)return;
    const variantId=workspace.variants[0]?.id;
    if(!supabase||!variantId){setWorkloadError("Ten widok nie wskazuje wariantu do analizy.");return;}
    setWorkloadLoading(true);setWorkloadError("");
    try{
      const rows=await getVariantWorkloadDistribution(supabase,variantId);
      if(variantId===workspaceVariantId){setWorkloadRows(rows);setWorkloadVariantId(variantId);}
    }
    catch(error){setWorkloadError(solverErrorMessage(error instanceof Error?error.message:String(error)));}
    finally{setWorkloadLoading(false);}
  }

  async function openWorkload(force=false){
    setWorkspaceView("WORKLOAD");
    await loadWorkload(force);
  }

  function openEmployeeCalendar(candidate:{employeeId:string;employeeName:string;employeeNo:string}){
    setEmployeeDetailSeed({id:candidate.employeeId,name:candidate.employeeName,employeeNo:candidate.employeeNo});
    setEmployeeDetailId(candidate.employeeId);
    setComparisonEmployeeId("");
    setVariantDiagnostics(null);
    void loadWorkload();
  }

  async function inspectIssue(issueId:string){
    if(!supabase||!workspace.context.scheduleId)return;
    setDiagnosticsLoading(true);setDiagnostics(null);setSelectedEmployee("");
    try{setDiagnostics(await getCandidateDiagnostics(supabase,workspace.context.scheduleId,issueId));}
    catch(error){fail?.(solverErrorMessage(error instanceof Error?error.message:String(error)));}
    finally{setDiagnosticsLoading(false);}
  }
  async function inspectVariantIssue(issueId:string){
    const variantId=workspace.variants[0]?.id;
    if(!supabase||!variantId)return;
    setVariantDiagnosticsLoading(true);setVariantDiagnostics(null);
    void loadWorkload();
    try{setVariantDiagnostics(await getVariantIssueDiagnostics(supabase,variantId,issueId));}
    catch(error){fail?.(solverErrorMessage(error instanceof Error?error.message:String(error)));}
    finally{setVariantDiagnosticsLoading(false);}
  }
  async function assign(candidate:SolverCandidateDiagnostic){
    if(!supabase||!diagnostics||candidate.classification==="BLOCKED")return;
    let reason="";
    if(candidate.classification==="WARNING"){
      reason=window.prompt(`Awaryjne dopisanie naruszy regułę miękką:\n${candidate.softReasons.map(reasonLabel).join("\n")}\n\nPodaj powód decyzji:`)?.trim()??"";
      if(reason.length<3)return;
    }
    setDiagnosticsLoading(true);
    try{
      await emergencyAssignV2(supabase,{scheduleId:diagnostics.scheduleId,issueId:diagnostics.issue.id,employeeId:candidate.employeeId,allowSoft:candidate.classification==="WARNING",reason,notify:notifyEmployee});
      notify?.(notifyEmployee?"Pracownik został dopisany i powiadomiony.":"Pracownik został dopisany do grafiku operacyjnego.");
      setDiagnostics(null);setSelectedEmployee("");await onOperationalChanged?.();
    }catch(error){fail?.(solverErrorMessage(error instanceof Error?error.message:String(error)));}
    finally{setDiagnosticsLoading(false);}
  }
  async function assignVariantCandidate(candidate:SolverVariantIssueDiagnostics["candidates"][number]){
    const scheduleId=variantDiagnostics?.publishedScheduleId;
    if(!supabase||!variantDiagnostics||!scheduleId||candidate.reasons.length)return;
    setVariantDiagnosticsLoading(true);setSelectedEmployee(candidate.employeeId);
    try{
      const operational=await getCandidateDiagnostics(supabase,scheduleId,variantDiagnostics.issueId);
      const current=operational.candidates.find(item=>item.employeeId===candidate.employeeId);
      if(!current)throw new Error("CANDIDATE_NOT_FOUND");
      if(current.classification==="BLOCKED"){
        throw new Error(`EMERGENCY_ASSIGNMENT_HARD_BLOCK:${current.hardReasons.join(",")}`);
      }
      let reason="";
      if(current.classification==="WARNING"){
        reason=window.prompt(`Dopisanie naruszy regułę miękką:\n${current.softReasons.map(reasonLabel).join("\n")}\n\nPodaj powód decyzji:`)?.trim()??"";
        if(reason.length<3)return;
      }
      await emergencyAssignV2(supabase,{scheduleId,issueId:variantDiagnostics.issueId,employeeId:candidate.employeeId,allowSoft:current.classification==="WARNING",reason,notify:true});
      notify?.("Pracownik został dopisany do grafiku operacyjnego i powiadomiony. Wariant źródłowy pozostał niezmieniony dla audytu.");
      setVariantDiagnostics(null);await onOperationalChanged?.();
    }catch(error){fail?.(solverErrorMessage(error instanceof Error?error.message:String(error)));}
    finally{setVariantDiagnosticsLoading(false);setSelectedEmployee("");}
  }
  async function activateStandby(){
    if(!supabase||!standbyAction||!standbyTargetAssignmentId||standbyReason.trim().length<3)return;
    setDiagnosticsLoading(true);
    const result=await supabase.rpc("standby_activate_uat_v3",{
      p_standby_id:standbyAction.id,p_original_assignment_id:standbyTargetAssignmentId,
      p_reason:standbyReason.trim(),
    });
    setDiagnosticsLoading(false);
    if(result.error){fail?.(solverErrorMessage(result.error.message));return;}
    notify?.(`Aktywowano rezerwę ${standbyAction.tier}. Zastępstwo jest widoczne w grafiku i audycie.`);
    setStandbyAction(null);setStandbyTargetAssignmentId("");setStandbyReason("");
    try{setStandby(await getManagerStandbyMonth(supabase,workspace.context.month,scopeRoleId));}
    catch(error){setStandbyError(solverErrorMessage(error instanceof Error?error.message:String(error)));}
    await onOperationalChanged?.();
  }

  async function openLeaderEdit(input:{assignmentId?:string;issueId?:string;preferredEmployeeId?:string}){
    const variantId=workspace.variants[0]?.id;
    if(!supabase||!leaderEditable||!variantId)return;
    setLeaderBusy(true);setLeaderContext(null);setLeaderReason("");setLeaderSearch("");setLeaderFeedback("");setLeaderLimitWarning("");setLeaderOvertimeWarning(false);setLeaderValidatedKey("");
    try{
      const {preferredEmployeeId,...contextInput}=input;
      const context=await getLeaderAssignmentContext(supabase,{variantId,...contextInput});
      const preferredCandidate=preferredEmployeeId&&context.candidates.some(candidate=>candidate.employeeId===preferredEmployeeId&&candidate.suggestionEligible);
      setLeaderContext(context);setLeaderEmployeeId(preferredCandidate?preferredEmployeeId:context.currentEmployeeId??"");
      if(preferredEmployeeId&&!preferredCandidate){const candidate=context.candidates.find(item=>item.employeeId===preferredEmployeeId);setLeaderFeedback(candidate?`Ta osoba nie jest bezpieczną sugestią: ${availabilityLabel(candidate.availabilityStatus)}${candidate.dutyCoverageMode==="NOT_COVERED"?"; po zamianie nikt nie pokryłby wymaganego obowiązku":""}.`:"Porównywana osoba nie ma wymaganej roli lub dostępu do lokalu.");}
    }catch(error){fail?.(solverErrorMessage(error instanceof Error?error.message:String(error)));}
    finally{setLeaderBusy(false);}
  }
  async function saveLeaderEdit(allowLimitOverride=false,approveOvertime=false){
    if(!supabase||!leaderContext)return;
    if(!leaderEmployeeId){setLeaderFeedback("Wybierz pracownika z listy kandydatów.");return;}
    const selectedCandidate=leaderContext.candidates.find(candidate=>candidate.employeeId===leaderEmployeeId);
    if(!selectedCandidate?.suggestionEligible){setLeaderFeedback("Ta osoba nie jest bezpieczną sugestią dla tej zmiany. Sprawdź status dostępności i pokrycie obowiązku.");return;}
    const validationKey=[leaderContext.variantId,leaderContext.assignmentId??leaderContext.issueId,leaderEmployeeId,allowLimitOverride,approveOvertime,selectedCandidate.dutyTransferAssignmentId??""].join(":");
    if(leaderValidatedKey!==validationKey){setLeaderFeedback("Najpierw użyj „Sprawdź”. Zapis jest dostępny dopiero po aktualnej, niemutującej kontroli serwera.");return;}
    if(leaderReason.trim().length<3){setLeaderFeedback("Wpisz krótki powód zmiany — jest zapisywany w audycie.");return;}
    setLeaderBusy(true);
    setLeaderFeedback("Serwer sprawdza rolę, lokal, obowiązki, dostępność, odpoczynek i limity całego miesiąca…");
    try{
      await saveLeaderAssignment(supabase,{variantId:leaderContext.variantId,
        assignmentId:leaderContext.assignmentId,issueId:leaderContext.issueId,
        employeeId:leaderEmployeeId,reason:leaderReason.trim(),allowLimitOverride,
        dutyTransferAssignmentId:selectedCandidate.dutyTransferAssignmentId,approveOvertime});
      notify?.(approveOvertime?"Nadgodziny zostały zatwierdzone w wersji lidera. Zakres, wycena i powód zapisano w audycie.":allowLimitOverride?"Zmiana została przypisana jako świadomy wyjątek od limitu. Powód i ryzyko zapisano w audycie.":"Zmiana przeszła pełną kontrolę reguł i została zapisana wyłącznie w wersji lidera.");
      setLeaderContext(null);await onLeaderChanged?.();await openWorkload(true);
    }catch(error){
      const raw=error instanceof Error?error.message:String(error);
      if(raw.toUpperCase().includes("LEADER_OVERTIME_APPROVAL_REQUIRED")){
        setLeaderOvertimeWarning(true);setLeaderFeedback("Ta osoba ma ustawienie „tylko po zatwierdzeniu”. Sprawdź liczbę godzin i pełną wycenę poniżej, a następnie podejmij osobną decyzję.");return;
      }
      if(raw.toUpperCase().includes("LEADER_OVERTIME_NOT_ALLOWED")){
        setLeaderFeedback("Pracownik ma twarde „NIE” dla nadgodzin. Wybierz inną osobę albo najpierw zmień zgodę i uzupełnij wymagane reguły płacowe w konfiguracji firmy.");return;
      }
      if(raw.toUpperCase().includes("LEADER_LIMIT_OVERRIDE_REQUIRED")){
        const detail=raw.split("LEADER_LIMIT_OVERRIDE_REQUIRED:")[1]?.split("\n")[0]?.trim()??"Przypisanie przekroczy twardy limit godzin.";
        setLeaderLimitWarning(detail);setLeaderFeedback("Automatyczny grafik nie może przekroczyć limitu. Jako lider możesz świadomie zapisać ten wyjątek, ponieważ podałeś powód zmiany.");return;
      }
      const message=solverErrorMessage(raw);setLeaderFeedback(message);fail?.(message);
    }
    finally{setLeaderBusy(false);}
  }

  useEffect(()=>{
    if(!leaderEditable||!workspaceVariantId)return;
    void loadWorkload();
  // The displayed draft identity is the boundary for Studio metrics. Filters
  // are deliberately not dependencies, so changing them never refetches or
  // resets the user's working context.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  },[leaderEditable,workspaceIdentity,workspaceVariantId]);
  async function validateLeaderEdit(allowLimitOverride=false,approveOvertime=false){
    if(!supabase||!leaderContext||!leaderEmployeeId)return;
    const selectedCandidate=leaderContext.candidates.find(candidate=>candidate.employeeId===leaderEmployeeId);
    if(!selectedCandidate?.suggestionEligible){setLeaderFeedback("Ta osoba ma blokadę. Wybierz kandydata oznaczonego jako możliwy do sprawdzenia.");return;}
    setLeaderBusy(true);setLeaderValidatedKey("");
    setLeaderFeedback("Sprawdzam bez zapisywania: rolę, lokal, obowiązki, dostępność, odpoczynek, limity i koszt całego miesiąca…");
    try{
      await validateLeaderAssignment(supabase,{variantId:leaderContext.variantId,assignmentId:leaderContext.assignmentId,issueId:leaderContext.issueId,employeeId:leaderEmployeeId,allowLimitOverride,dutyTransferAssignmentId:selectedCandidate.dutyTransferAssignmentId,approveOvertime});
      setLeaderValidatedKey([leaderContext.variantId,leaderContext.assignmentId??leaderContext.issueId,leaderEmployeeId,allowLimitOverride,approveOvertime,selectedCandidate.dutyTransferAssignmentId??""].join(":"));
      setLeaderFeedback("Kontrola zakończona: zmiana jest poprawna i niczego jeszcze nie zapisano. Dodaj komentarz audytowy i wybierz „Zapisz”, jeśli chcesz ją zastosować.");
    }catch(error){
      const raw=error instanceof Error?error.message:String(error);const upper=raw.toUpperCase();
      if(upper.includes("LEADER_OVERTIME_APPROVAL_REQUIRED")){setLeaderOvertimeWarning(true);setLeaderFeedback("Ta zmiana tworzy nadgodziny wymagające decyzji. Sprawdź wycenę i ponów kontrolę z zatwierdzeniem nadgodzin.");}
      else if(upper.includes("LEADER_OVERTIME_NOT_ALLOWED")){setLeaderFeedback("Pracownik ma twarde „NIE” dla nadgodzin. Wybierz inną osobę albo zmień zgodę w konfiguracji firmy.");}
      else if(upper.includes("LEADER_LIMIT_OVERRIDE_REQUIRED")){const detail=raw.split("LEADER_LIMIT_OVERRIDE_REQUIRED:")[1]?.split("\n")[0]?.trim()??"Przypisanie przekroczy limit godzin.";setLeaderLimitWarning(detail);setLeaderFeedback("Zmiana przekracza limit. Ponów kontrolę jako świadomy wyjątek, jeśli chcesz ją dopuścić.");}
      else{const message=solverErrorMessage(raw);setLeaderFeedback(message);fail?.(message);}
    }finally{setLeaderBusy(false);}
  }
  async function removeLeaderEdit(){
    if(!supabase||!leaderContext?.assignmentId)return;
    if(leaderReason.trim().length<3){setLeaderFeedback("Wpisz krótki powód usunięcia — jest zapisywany w audycie.");return;}
    setLeaderBusy(true);
    try{
      await removeLeaderAssignment(supabase,{variantId:leaderContext.variantId,
        assignmentId:leaderContext.assignmentId,reason:leaderReason.trim()});
      notify?.("Przydział usunięto z wersji lidera. Miejsce jest widoczne jako brak do uzupełnienia.");
      setLeaderContext(null);await onLeaderChanged?.();await openWorkload(true);
    }catch(error){fail?.(solverErrorMessage(error instanceof Error?error.message:String(error)));}
    finally{setLeaderBusy(false);}
  }
  async function applyAssignmentDrag(input:{sourceAssignmentId:string;targetAssignmentId?:string;targetIssueId?:string}){
    const variantId=workspace.variants[0]?.id;
    if(!supabase||!leaderEditable||!variantId||leaderBusy)return;
    setLeaderBusy(true);
    try{
      const result=await previewLeaderAssignmentDrag(supabase,{variantId,...input});
      const message=result.valid?(input.targetAssignmentId?
        "Można zamienić pracowników. Twarde reguły całego miesiąca pozostaną spełnione.":
        "Można przenieść pracownika. Zwolnione miejsce pozostanie jawnym wakatem."):
        solverErrorMessage(result.errorCode??"VARIANT_MATERIALIZATION_HASH_MISMATCH");
      setDragPreview({key:`${input.sourceAssignmentId}:${input.targetAssignmentId??input.targetIssueId??""}`,loading:false,valid:result.valid,message});
      setPendingAssignmentDrag(result.valid?input:null);
    }catch(error){const message=solverErrorMessage(error instanceof Error?error.message:String(error));setDragPreview({key:"error",loading:false,valid:false,message});setPendingAssignmentDrag(null);}
    finally{setLeaderBusy(false);}
  }
  async function confirmAssignmentDrag(){
    const variantId=workspace.variants[0]?.id;
    if(!supabase||!leaderEditable||!variantId||!pendingAssignmentDrag||leaderBusy)return;
    setLeaderBusy(true);
    try{
      await dragLeaderAssignment(supabase,{variantId,...pendingAssignmentDrag,reason:pendingAssignmentDrag.targetAssignmentId?
        "Zamiana pracowników przez przeciągnięcie w Studio lidera":"Przeniesienie pracownika na wakat w Studio lidera"});
      notify?.(pendingAssignmentDrag.targetAssignmentId?"Zamiana została zapisana jako jedna rewizja.":"Pracownik został przeniesiony, a zwolnione miejsce pozostało jawnym wakatem.");
      setPendingAssignmentDrag(null);setDragPreview(null);await onLeaderChanged?.();await openWorkload(true);
    }catch(error){fail?.(solverErrorMessage(error instanceof Error?error.message:String(error)));}
    finally{setLeaderBusy(false);}
  }
  async function toggleAssignmentLock(assignmentId:string,locked:boolean){
    const variantId=workspace.variants[0]?.id;
    if(!supabase||!leaderEditable||!variantId||leaderBusy)return;
    setLeaderBusy(true);
    try{
      await setLeaderAssignmentLock(supabase,{variantId,assignmentId,locked,
        reason:locked?"Przypięcie świadomej decyzji lidera":"Odpięcie decyzji lidera"});
      notify?.(locked?"Przydział przypięto. Kolejne przeliczenie nie może go zmienić.":"Przydział odpięto i może ponownie uczestniczyć w optymalizacji.");
      await onLeaderChanged?.();
    }catch(error){fail?.(solverErrorMessage(error instanceof Error?error.message:String(error)));}
    finally{setLeaderBusy(false);}
  }
  async function applyVisibleBulk(){
    const variantId=workspace.variants[0]?.id;
    const visibleAssignmentIds=scheduleEntries.map(entry=>entry.assignment.id);
    const selectedVisibleIds=selectedAssignmentIds.filter(id=>visibleAssignmentIds.includes(id));
    const assignmentIds=selectedVisibleIds.length?selectedVisibleIds:visibleAssignmentIds;
    const reason=bulkReason.trim();
    if(!supabase||!leaderEditable||!variantId||leaderBusy||!assignmentIds.length||!bulkOperation||reason.length<3)return;
    setLeaderBusy(true);
    try{
      await bulkLeaderAssignments(supabase,{variantId,assignmentIds,operation:bulkOperation,reason});
      notify?.(`Operacja zbiorcza zakończona: ${assignmentIds.length} przydziałów zapisano jako jedną rewizję.`);
      setBulkOperation(null);setBulkReason("");setSelectedAssignmentIds([]);
      await onLeaderChanged?.();await openWorkload(true);
    }catch(error){fail?.(solverErrorMessage(error instanceof Error?error.message:String(error)));}
    finally{setLeaderBusy(false);}
  }
  function toggleAssignmentSelection(assignmentId:string){
    setSelectedAssignmentIds(current=>current.includes(assignmentId)?current.filter(id=>id!==assignmentId):[...current,assignmentId]);
  }

  const normalizedLeaderSearch=leaderSearch.trim().toLocaleLowerCase("pl-PL");
  const visibleLeaderCandidates=(leaderContext?.candidates??[]).filter(candidate=>{
    const matchesSearch=!normalizedLeaderSearch||[
      candidate.employeeName,candidate.employeeNo,candidate.roleName,leaderContext?.role.name,
      candidate.locationName,leaderContext?.shift.locationName,candidate.dutyName,leaderContext?.duty?.name,
    ].filter(Boolean).join(" ").toLocaleLowerCase("pl-PL").includes(normalizedLeaderSearch);
    const utilization=candidate.nominalMonthlyMinutes>0?candidate.projectedMonthlyMinutes/candidate.nominalMonthlyMinutes:0;
    const matchesView=leaderCandidateView==="ALL"
      ||leaderCandidateView==="ELIGIBLE"&&candidate.suggestionEligible
      ||leaderCandidateView==="BELOW_TARGET"&&candidate.suggestionEligible&&utilization<1
      ||leaderCandidateView==="PREFERRED"&&candidate.suggestionEligible&&candidate.availabilityStatus==="AVAILABLE";
    return matchesSearch&&matchesView;
  }).sort((left,right)=>Number(right.suggestionEligible)-Number(left.suggestionEligible)
    ||(left.nominalMonthlyMinutes>0?left.projectedMonthlyMinutes/left.nominalMonthlyMinutes:1)-(right.nominalMonthlyMinutes>0?right.projectedMonthlyMinutes/right.nominalMonthlyMinutes:1)
    ||left.employeeName.localeCompare(right.employeeName,"pl-PL"));
  const eligibleLeaderCandidates=(leaderContext?.candidates??[]).filter(candidate=>candidate.suggestionEligible).length;
  const blockedLeaderCandidates=(leaderContext?.candidates??[]).length-eligibleLeaderCandidates;
  const selectedLeaderCandidate=(leaderContext?.candidates??[]).find(candidate=>candidate.employeeId===leaderEmployeeId)??null;
  const studioZeroHours=filteredWorkload.filter(row=>row.plannedMinutes===0&&row.nominalMonthlyMinutes>0).length;
  const studioBelowTarget=filteredWorkload.filter(row=>row.nominalMonthlyMinutes>0&&row.plannedMinutes<row.nominalMonthlyMinutes).length;
  const studioAboveTarget=filteredWorkload.filter(row=>row.nominalMonthlyMinutes>0&&row.plannedMinutes>row.nominalMonthlyMinutes).length;
  const studioOvertimeMinutes=filteredWorkload.reduce((sum,row)=>sum+Math.max(0,row.plannedMinutes-row.nominalMonthlyMinutes),0);
  const employeeDetailWorkload=(currentWorkloadRows??[]).find(row=>row.employeeId===employeeDetailId)??null;
  const employeeDetail=scheduleEmployees.find(employee=>employee.id===employeeDetailId)??(
    employeeDetailSeed?.id===employeeDetailId
      ? {id:employeeDetailSeed.id,firstName:employeeDetailSeed.name,lastName:"",employeeNo:employeeDetailSeed.employeeNo,nominalMonthlyMinutes:employeeDetailWorkload?.nominalMonthlyMinutes??0}
      : null
  );
  const employeeDetailName=employeeDetail?[employeeDetail.firstName,employeeDetail.lastName].filter(Boolean).join(" "):"";
  const employeeDetailShortName=employeeDetailName.split(" ")[0]??employeeDetailName;
  const comparisonEmployee=scheduleEmployees.find(employee=>employee.id===comparisonEmployeeId)??null;
  const employeeEntries=(employeeId:string,date:string)=>scheduleEntries.filter(entry=>entry.assignment.employee.id===employeeId&&entry.shift.date===date);

  return <section className={`solver-workspace ${published ? "published" : ""} ${leaderEditable?"leader-studio":""}`}>
    <div className="solver-workspace-head">
      <span>
        <small>{published ? publicationStatus(workspace.context.status) : "Podgląd wybranego wariantu"}</small>
        <strong>{workspace.context.name}</strong>
        <em>{monthLabel(workspace.context.month)} • {workspace.context.scenario.name}</em>
      </span>
      {published && <b>{publicationStatus(workspace.context.status)}</b>}
    </div>

    {publishedAt && <div className="solver-workspace-published-at">Opublikowano {publishedAt}</div>}

    <div className="solver-workspace-summary">
      <span><Users/><small>Przydziały</small><strong>{assignmentCount}</strong></span>
      <span><AlertTriangle/><small>Braki</small><strong>{unfilledCount}</strong></span>
      <span><CalendarDays/><small>Dni ze zmianami</small><strong>{dates.length}</strong></span>
    </div>

    <nav className="solver-workspace-tabs" aria-label="Widoki grafiku">
      <button className={workspaceView==="CALENDAR"?"active":""} onClick={()=>setWorkspaceView("CALENDAR")}><CalendarDays/><span><strong>Grafik tygodniowy</strong><small>Cały miesiąc bez rozwijania dni</small></span></button>
      <button className={workspaceView==="WORKLOAD"?"active":""} onClick={()=>void openWorkload()}><BarChart3/><span><strong>Rozkład pracy</strong><small>Godziny, zmiany i lokale zespołu</small></span></button>
      <button className={workspaceView==="ISSUES"?"active":""} onClick={()=>setWorkspaceView("ISSUES")}><AlertTriangle/><span><strong>Braki i powody</strong><small>{unfilledCount?`${unfilledCount} miejsc wymaga decyzji`:"Brak nieobsadzonych miejsc"}</small></span></button>
    </nav>
    {(!leaderEditable||!leaderContext)&&<div className="solver-global-filters">
      <label><MapPin/> Lokal<select value={locationFilter} onChange={event=>setLocationFilter(event.target.value)}><option value="">Wszystkie lokale</option>{workspaceLocations.map(location=><option value={location.id} key={location.id}>{location.name}</option>)}</select></label>
      <fieldset><legend>Role</legend>{workspaceRoles.map(role=><label className="check-label" key={role.id}><input type="checkbox" checked={roleFilters.includes(role.id)} onChange={event=>setRoleFilters(event.target.checked?[...roleFilters,role.id]:roleFilters.filter(id=>id!==role.id))}/>{role.name}</label>)}</fieldset>
      {(locationFilter||roleFilters.length>0)&&<button className="secondary-button" onClick={()=>{setLocationFilter("");setRoleFilters([]);}}><X/> Wyczyść filtry</button>}
      <small>Te filtry zmieniają grafik, rozkład godzin, statystyki, koszty i listę braków; nie zerują się po edycji.</small>
    </div>}

    {leaderEditable&&scheduleEntries.length>0&&<div className="leader-bulk-toolbar"><span><Users/><strong>Operacje dla zaznaczenia lub widocznego zakresu</strong><small>{selectedAssignmentIds.length?`${selectedAssignmentIds.length} zaznaczonych przydziałów`:`${scheduleEntries.length} przydziałów po aktywnych filtrach roli i lokalu`}</small></span><div><button className="secondary-button" disabled={leaderBusy} onClick={()=>setSelectedAssignmentIds(scheduleEntries.map(entry=>entry.assignment.id))}><Check/> Zaznacz widoczne</button>{selectedAssignmentIds.length>0&&<button className="secondary-button" onClick={()=>setSelectedAssignmentIds([])}><X/> Wyczyść zaznaczenie</button>}<button className="secondary-button" disabled={leaderBusy} onClick={()=>setBulkOperation("LOCK")}><LockKeyhole/> Przypnij</button><button className="secondary-button" disabled={leaderBusy} onClick={()=>setBulkOperation("UNLOCK")}><LockOpen/> Odepnij</button><button className="danger-button" disabled={leaderBusy} onClick={()=>setBulkOperation("REMOVE")}><Trash2/> Usuń</button></div>{bulkOperation&&<div className="leader-bulk-confirm"><strong>{bulkOperation==="LOCK"?"Przypnij":bulkOperation==="UNLOCK"?"Odepnij":"Usuń"} {selectedAssignmentIds.length||scheduleEntries.length} {selectedAssignmentIds.length?"zaznaczonych":"widocznych"} przydziałów</strong><label>Powód operacji<textarea minLength={3} value={bulkReason} onChange={event=>setBulkReason(event.target.value)} placeholder="np. uzgodniona korekta grafiku"/></label>{bulkOperation==="REMOVE"&&<small>Wymagane miejsca pozostaną jako jawne wakaty do ponownego obsadzenia.</small>}<span><button className="secondary-button" onClick={()=>{setBulkOperation(null);setBulkReason("");}}>Anuluj</button><button className={bulkOperation==="REMOVE"?"danger-button":"primary-button"} disabled={leaderBusy||bulkReason.trim().length<3} onClick={()=>void applyVisibleBulk()}>{leaderBusy?<RefreshCw className="spin"/>:<Check/>} Potwierdź i zapisz rewizję</button></span></div>}<small>Zaznacz konkretne kafelki albo użyj aktywnych filtrów. Jedna operacja tworzy jedną rewizję możliwą do cofnięcia.</small></div>}

    {leaderEditable&&scheduleEntries.length>0&&<details className="leader-assignment-selector"><summary>Wybierz konkretne przydziały do operacji zbiorczej <small>{selectedAssignmentIds.length} zaznaczonych</small></summary><div>{scheduleEntries.map(({shift,assignment})=><button type="button" className={selectedAssignmentIds.includes(assignment.id)?"selected":""} aria-pressed={selectedAssignmentIds.includes(assignment.id)} onClick={()=>toggleAssignmentSelection(assignment.id)} key={assignment.id}><span>{selectedAssignmentIds.includes(assignment.id)?<Check/>:null}<strong>{assignment.employee.firstName} {assignment.employee.lastName}</strong></span><small>{shortDayLabel(shift.date)} • {timeLabel(shift.startsAt,shift.location.timezone??timezone)}–{timeLabel(shift.endsAt,shift.location.timezone??timezone)} • {shift.location.name} • {assignment.role.name}</small></button>)}</div></details>}

    {leaderEditable&&<aside className="leader-studio-impact" aria-label="Wpływ zmian w Studio lidera">
      <header><BarChart3/><span><strong>Wpływ bieżącego szkicu</strong><small>{locationFilter||roleFilters.length?"Wyniki dla aktywnych filtrów":"Cały zakres wersji lidera"}</small></span></header>
      <div><span><small>Przydziały</small><b>{assignmentCount}</b></span><span className={unfilledCount?"warning":"ok"}><small>Braki</small><b>{unfilledCount}</b></span><span className={studioZeroHours?"warning":"ok"}><small>Osoby z 0 h</small><b>{studioZeroHours}</b></span><span><small>Poniżej celu</small><b>{studioBelowTarget}</b></span><span><small>Powyżej celu</small><b>{studioAboveTarget}</b></span><span><small>Nad celem</small><b>{workloadHours(studioOvertimeMinutes)}</b></span>{workspace.finance&&(financeVisibility==="AGGREGATE"||financeVisibility==="FULL")&&<span><small>Łączny koszt</small><b>{money(workspace.finance.totalCostMinor,workspace.finance.currency)}</b></span>}{workspace.finance&&financeVisibility==="BUDGET_ONLY"&&<span className={workspace.finance.budgetMinor!==null&&workspace.finance.totalCostMinor>workspace.finance.budgetMinor?"warning":"ok"}><small>Status budżetu</small><b>{workspace.finance.budgetMinor===null?"Bez limitu":workspace.finance.totalCostMinor<=workspace.finance.budgetMinor?"W budżecie":"Przekroczony"}</b></span>}</div>
      {baselineWorkspace&&<section className="leader-baseline-delta"><strong>Zmiana względem wariantu bazowego</strong><div><span><small>Zmodyfikowane miejsca</small><b>{modifiedAssignmentCount}</b></span><span><small>Przydziały</small><b>{assignmentCount-baselineAssignmentCount>=0?"+":""}{assignmentCount-baselineAssignmentCount}</b></span><span><small>Braki</small><b>{unfilledCount-baselineUnfilledCount>=0?"+":""}{unfilledCount-baselineUnfilledCount}</b></span>{workspace.finance&&baselineCostMinor!==null&&(financeVisibility==="AGGREGATE"||financeVisibility==="FULL")&&<span><small>Koszt</small><b>{workspace.finance.totalCostMinor-baselineCostMinor>=0?"+":""}{money(workspace.finance.totalCostMinor-baselineCostMinor,workspace.finance.currency)}</b></span>}</div></section>}
      <button type="button" className="secondary-button" disabled={workloadLoading} onClick={()=>void openWorkload(true)}><RefreshCw className={workloadLoading?"spin":""}/> Przelicz pełną analizę</button>
      <small>Po każdym zapisie szkic jest ponownie pobierany. Twarde reguły sprawdza serwer przed zapisem; świadome wyjątki pozostają w audycie.</small>
    </aside>}

    {workspaceView==="ISSUES"&&<>
    {staffingRiskRows.length>0&&<section className="solver-staffing-risk" aria-label="Ryzyko obsady przed publikacją"><header><AlertTriangle/><span><strong>Ryzyko obsady według dnia, roli i lokalu</strong><small>Najpierw pokazujemy zakresy o najniższym pokryciu. Szczegóły problemów poniżej prowadzą do konkretnej zmiany, kandydatów i możliwego działania.</small></span></header><div>{staffingRiskRows.slice(0,12).map(row=><article className={row.coverage<50?"critical":row.coverage<100?"warning":"ok"} key={row.key}><span><b>{row.date} • {row.role}</b><small>{row.location}</small></span><strong>{row.coverage}%</strong><em>{row.assigned}/{row.required} obsadzonych • brakuje {row.missing}</em></article>)}</div>{staffingRiskRows.length>12&&<small>Pokazano 12 najwyższych ryzyk z {staffingRiskRows.length}. Użyj filtrów roli i lokalu, aby zawęzić analizę.</small>}</section>}
    {unfilledIssues.length>0&&<section className="solver-missing-breakdown">
      <div className="solver-missing-explainer"><AlertTriangle/><span><strong>{unfilledCount} braków to suma nieobsadzonych wymaganych miejsc</strong><small>Każdy brak poniżej wskazuje konkretny dzień, lokal, zmianę i rolę. To nie jest liczba pracowników ani naruszenie twardych reguł.</small></span></div>
      <div className="solver-missing-groups">
        {[["Według roli",missingByRole],["Według lokalu",missingByLocation],["Według zmiany",missingByShift]].map(([title,rows])=><article key={title as string}>
          <h4>{title as string}</h4>
          {(rows as [string,number][]).slice(0,8).map(([name,count])=><div key={name}><span>{name}</span><strong>{count}</strong></div>)}
          {(rows as [string,number][]).length>8&&<small>+ {(rows as [string,number][]).length-8} kolejnych pozycji w szczegółach</small>}
        </article>)}
      </div>
    </section>}

    <details className="solver-workspace-issues" open={!leaderEditable&&workspace.issues.length > 0}>
      <summary>
        <span><AlertTriangle/><strong>{unfilledIssues.length?(leaderEditable?"Otwórz szczegóły problemów":"Napraw braki i sprawdź powody"):"Uwagi do grafiku"}</strong></span>
        <small>{visibleIssues.length}</small>
      </summary>
      {visibleIssues.length === 0
        ? <p>{locationFilter?"Brak braków i uwag dla wybranego lokalu.":"Nie zgłoszono braków ani uwag do tego wariantu."}</p>
        : <div>
          {visibleIssues.map(issue => <WorkspaceIssueCard key={issue.id} issue={issue} timezone={timezone} operational={operational} published={published} busy={diagnosticsLoading||variantDiagnosticsLoading||leaderBusy} inspect={id=>void inspectIssue(id)} explainPreview={id=>void inspectVariantIssue(id)} previewAvailable={Boolean(workspace.variants[0]?.id)} leaderEditable={leaderEditable} editLeader={id=>void openLeaderEdit({issueId:id})} onOpenAdHoc={onOpenAdHoc}/>)}
        </div>}
    </details>
    </>}

    {workspace.finance && (financeVisibility==="AGGREGATE"||financeVisibility==="FULL") && <div className="solver-workspace-finance">
      <div><CircleDollarSign/><span><small>Koszt podstawowy</small><strong>{money(workspace.finance.baseCostMinor, workspace.finance.currency)}</strong></span></div>
      <div><span><small>Dodatki płacowe</small><strong>{money(workspace.finance.additionsCostMinor, workspace.finance.currency)}</strong></span></div>
      <div><span><small>Łączny koszt</small><strong>{money(workspace.finance.totalCostMinor, workspace.finance.currency)}</strong></span></div>
      <div><span><small>Budżet scenariusza</small><strong>{money(workspace.finance.budgetMinor, workspace.finance.currency)}</strong></span></div>
    </div>}
    {workspace.finance && financeVisibility==="BUDGET_ONLY" && <div className="solver-workspace-finance budget-only">
      <div><CircleDollarSign/><span><small>Status budżetu scenariusza</small><strong>{workspace.finance.budgetMinor===null?"Brak ustawionego limitu":workspace.finance.totalCostMinor<=workspace.finance.budgetMinor?"Koszt mieści się w budżecie":"Koszt przekracza budżet"}</strong></span></div>
    </div>}

    {workspaceView==="WORKLOAD"&&<section className="solver-workload-content" aria-label="Rozkład pracy zespołu">
      <header className="solver-workspace-view-head"><span><em>{published?"OPUBLIKOWANY GRAFIK":workspace.context.variantKind==="LEADER_COPY"?"WERSJA LIDERA • JESZCZE NIEOPUBLIKOWANA":"WARIANT • JESZCZE NIEOPUBLIKOWANY"}</em><strong>Rozkład pracy zespołu</strong><small>{workspace.context.variantKind==="LEADER_COPY"?"Aktualny bilans kopii lidera — po każdej zmianie jest liczony ponownie.":"Analiza dokładnie tego wariantu, który wskazuje nagłówek."}</small></span><button className="secondary-button" disabled={workloadLoading} onClick={()=>void openWorkload(true)}><RefreshCw className={workloadLoading?"spin":""}/> Przelicz</button></header>
      {workloadLoading&&<div className="solver-workspace-empty"><RefreshCw className="spin"/> Obliczamy rozkład godzin…</div>}
      {workloadError&&<div className="solver-v2-notice warning"><AlertTriangle/><span><strong>Nie udało się pobrać rozkładu pracy</strong><small>{workloadError}</small></span></div>}
      {currentWorkloadRows&&<>
        <div className="solver-workload-summary">
          <span><small>Osoby w analizie</small><strong>{filteredWorkload.length}</strong></span>
          <span><small>Najmniej godzin</small><strong>{workloadHours(workloadMinutes[0]??0)}</strong></span>
          <span><small>Mediana</small><strong>{workloadHours(workloadMedian)}</strong></span>
          <span><small>Najwięcej godzin</small><strong>{workloadHours(workloadMinutes.at(-1)??0)}</strong></span>
          <span><small>Różnica min–max</small><strong>{workloadHours((workloadMinutes.at(-1)??0)-(workloadMinutes[0]??0))}</strong></span>
          <span className={workloadOverMaximum?"critical":""}><small>Powyżej twardego limitu</small><strong>{workloadOverMaximum}</strong></span>
        </div>
        <div className="solver-workload-filters">
          <label>Znajdź pracownika<input value={workloadSearch} onChange={event=>setWorkloadSearch(event.target.value)} placeholder="Imię, nazwisko, numer lub rola"/></label>
          <label>Lokal<select value={locationFilter} onChange={event=>setLocationFilter(event.target.value)}><option value="">Wszystkie lokale</option>{workspaceLocations.map(location=><option key={location.id} value={location.id}>{location.name}</option>)}</select></label>
          <label>Wyjaśnienie<select value={workloadReasonFilter} onChange={event=>setWorkloadReasonFilter(event.target.value)}><option value="">Wszystkie przyczyny</option><option value="ABOVE_MAXIMUM">Przekroczony twardy limit</option><option value="AVAILABILITY_LIMITED">Ograniczona dostępność</option><option value="AVAILABILITY_WINDOW_LIMITED">Konkretne okna dostępności</option><option value="MAXIMUM_REACHED">Osiągnięty limit</option><option value="TARGET_NOT_SET">Brak celu godzinowego</option><option value="SOLVER_DISTRIBUTION">Rozdział silnika</option><option value="ABOVE_NOMINAL">Powyżej celu</option><option value="ON_TARGET">Zgodnie z celem</option></select></label>
          <label>Sortowanie<select value={workloadSort} onChange={event=>setWorkloadSort(event.target.value as typeof workloadSort)}><option value="HOURS_DESC">Najwięcej godzin</option><option value="HOURS_ASC">Najmniej godzin</option><option value="DIFFERENCE">Największa różnica od wymiaru</option></select></label>
        </div>
        <div className="solver-workload-list">{filteredWorkload.map(row=><article key={row.employeeId}>
          <header><span><strong>{row.employeeName}</strong><small>{row.employeeNo} • {row.roleNames.join(", ")||"Rola w analizowanym grafiku"}</small></span><b>{workloadHours(row.plannedMinutes)}</b></header>
          <div className="solver-workload-kpis"><span><small>Zmiany</small><strong>{row.shiftCount}</strong></span><span><small>Cel godzinowy</small><strong>{row.nominalMonthlyMinutes?workloadHours(row.nominalMonthlyMinutes):"Brak"}</strong></span><span><small>Twardy limit</small><strong>{row.maximumMonthlyMinutes?workloadHours(row.maximumMonthlyMinutes):"Brak"}</strong></span><span><small>Różnica od celu</small><strong className={row.differenceMinutes>0?"over":row.differenceMinutes<0?"under":""}>{row.nominalMonthlyMinutes?`${row.differenceMinutes>0?"+":""}${workloadHours(row.differenceMinutes)}`:"—"}</strong></span></div>
          <div className="solver-workload-locations">{row.locations.length?row.locations.map(location=><span key={location.id}><MapPin/>{location.name}: <b>{workloadHours(location.minutes)}</b> • {location.shiftCount} zmian</span>):<span>Brak przydziałów w lokalach</span>}</div>
          <p className={`reason-${workloadReasonCode(row).toLowerCase()}`}><strong>Dlaczego taki wynik?</strong> {workloadReason(row)}</p>
          <button className="secondary-button employee-calendar-open" onClick={()=>openEmployeeCalendar({employeeId:row.employeeId,employeeName:row.employeeName,employeeNo:row.employeeNo})}><CalendarDays/> Otwórz kalendarz i porównaj</button>
        </article>)}</div>
        {!filteredWorkload.length&&<div className="solver-workspace-empty">Żadna osoba nie spełnia wybranych filtrów.</div>}
      </>}
    </section>}

    {workspaceView==="ISSUES" && <details className="solver-workspace-standby" open>
      <summary><span><ShieldCheck/><strong>{published?"Opublikowana rezerwa bezpieczeństwa":"Podgląd rezerwy przed publikacją"}</strong></span><small>{standby.length} dyżurów gotowości</small></summary>
      <p className="solver-workspace-empty">Pełna obsada każdej roli w skonfigurowanej grupie ma pierwszeństwo. Rezerwa 1 i 2 jest osobną warstwą — nie zabiera miejsc wymaganej obsadzie i nie jest liczona do godzin pracy.</p>
      {standbyError ? <p className="solver-workspace-empty">Nie udało się pobrać rezerwy: {standbyError}</p>
        : standby.length===0 ? <p className="solver-workspace-empty">Dla tego wariantu nie ma bezpiecznej rezerwy. Sprawdź grupy rezerwy w konfiguracji firmy albo uzupełnij braki i dostępność zespołu.</p>
        : <div className="solver-standby-days">{[...new Map(standby.map(item=>[item.date,standby.filter(row=>row.date===item.date)]))].map(([date,rows])=><article key={date}>
          <header><CalendarDays/><strong>{dateLabel(date)}</strong></header>
          {(rows as SolverManagerStandby[]).map(entry=><div key={entry.id}><span><b>{entry.groupName??entry.roleName}</b><small>{entry.employeeName} • {entry.employeeNo}{entry.eligibleRoleNames.length?` • może zastąpić: ${entry.eligibleRoleNames.join(", ")}`:""}</small></span><em className={`tier-${entry.tier}`}>Rezerwa {entry.tier}{entry.status==="PREVIEW"?" • po publikacji":entry.status==="ACTIVATED"?" • aktywowana":entry.status==="DECLINED"?" • odrzucona":""}</em>{entry.status==="PLANNED"&&<button className="secondary-button" disabled={diagnosticsLoading} onClick={()=>{setStandbyAction(entry);setStandbyTargetAssignmentId("");setStandbyReason("");}}>Aktywuj</button>}</div>)}
        </article>)}</div>}
      {standbyAction&&<form className="standby-activation-form" onSubmit={event=>{event.preventDefault();void activateStandby();}}><div><strong>Aktywuj {standbyAction.employeeName} • rezerwa {standbyAction.tier}</strong><small>{standbyAction.date} • grupa {standbyAction.groupName??standbyAction.roleName}. Wybierz osobę z jednej z dozwolonych ról: {standbyAction.eligibleRoleNames.join(", ")||standbyAction.roleName}. System ponownie sprawdzi wszystkie twarde reguły.</small></div><label>Zastępowany przydział<select required value={standbyTargetAssignmentId} onChange={event=>setStandbyTargetAssignmentId(event.target.value)}><option value="">Wybierz przydział</option>{workspace.shifts.filter(shift=>shift.date===standbyAction.date).flatMap(shift=>shift.assignments.filter(assignment=>(standbyAction.eligibleRoleIds.length?standbyAction.eligibleRoleIds.includes(assignment.role.id):assignment.role.id===standbyAction.roleId)&&assignment.employee.id!==standbyAction.employeeId).map(assignment=><option key={assignment.id} value={assignment.id}>{assignment.employee.firstName} {assignment.employee.lastName} • {assignment.role.name} • {shift.shiftTemplate.name} • {timeLabel(shift.startsAt,shift.location.timezone??timezone)}</option>))}</select></label><label>Powód aktywacji<textarea required minLength={3} value={standbyReason} onChange={event=>setStandbyReason(event.target.value)} placeholder="np. potwierdzona nieobecność pracownika"/></label><div><button type="button" className="secondary-button" onClick={()=>setStandbyAction(null)}>Anuluj</button><button className="primary-button" disabled={diagnosticsLoading||!standbyTargetAssignmentId||standbyReason.trim().length<3}>Potwierdź aktywację</button></div></form>}
    </details>}

    {workspaceView==="CALENDAR"&&<section className="solver-weekly-workspace">
      <header className="solver-workspace-view-head"><span><strong>Grafik tygodniowy</strong><small>Ta sama wersja grafiku w trzech perspektywach. Pierwsza kolumna i daty pozostają widoczne podczas przewijania.</small></span></header>
      {dragPreview&&<div className={`solver-v2-notice ${dragPreview.loading?"info":dragPreview.valid?"success":"danger"}`} role="status">{dragPreview.loading?<RefreshCw className="spin"/>:dragPreview.valid?<Check/>:<AlertTriangle/>}<span><strong>{dragPreview.loading?"Kontrola przed upuszczeniem":dragPreview.valid?"Dozwolona operacja":"Nie można upuścić tutaj"}</strong><small>{dragPreview.message}</small></span>{pendingAssignmentDrag&&<span className="leader-drag-confirm"><button className="secondary-button" disabled={leaderBusy} onClick={()=>{setPendingAssignmentDrag(null);setDragPreview(null);}}>Anuluj</button><button className="primary-button" disabled={leaderBusy} onClick={()=>void confirmAssignmentDrag()}>{leaderBusy?<RefreshCw className="spin"/>:<Check/>} Zastosuj sprawdzoną zmianę</button></span>}</div>}
      <div className="solver-schedule-perspectives" role="tablist" aria-label="Perspektywa grafiku"><button className={schedulePerspective==="EMPLOYEES"?"active":""} onClick={()=>setSchedulePerspective("EMPLOYEES")}>Pracownicy</button><button className={schedulePerspective==="ROLES"?"active":""} onClick={()=>setSchedulePerspective("ROLES")}>Stanowiska</button><button className={schedulePerspective==="COVERAGE"?"active":""} onClick={()=>setSchedulePerspective("COVERAGE")}>Pokrycie obsady</button></div>
      {dates.length === 0 && <div className="solver-workspace-empty">Ten wariant nie zawiera jeszcze zmian do pokazania.</div>}
      {weeks.map((week,weekIndex)=><article className="solver-roster-week" key={week[0]}>
        <header><strong>Tydzień {weekIndex+1}</strong><small>{shortDayLabel(week[0])} – {shortDayLabel(week[6])}</small></header>
        {schedulePerspective!=="COVERAGE"&&<div className="solver-roster-scroll">
          <div className="solver-roster-grid solver-roster-head"><b>{schedulePerspective==="EMPLOYEES"?"Pracownik":"Stanowisko"}</b>{week.map(date=><span className={date.slice(0,7)!==workspace.context.month.slice(0,7)?"outside-month":""} key={date}>{shortDayLabel(date)}</span>)}</div>
          {schedulePerspective==="EMPLOYEES"&&scheduleEmployees.map(employee=><div className="solver-roster-grid solver-roster-row" key={employee.id}><button className="solver-roster-person" onClick={()=>{setEmployeeDetailId(employee.id);setComparisonEmployeeId("");}}><strong>{employee.firstName} {employee.lastName}</strong><small>{employee.nominalMonthlyMinutes?workloadHours(employee.nominalMonthlyMinutes)+" wymiaru":"Brak wymiaru"}</small><em><Search/> Porównaj</em></button>{week.map(date=>{const entries=employeeEntries(employee.id,date);return <div className={["solver-roster-cell",date.slice(0,7)!==workspace.context.month.slice(0,7)?"outside-month":""].join(" ")} key={date}>{entries.map(({shift,assignment})=><article className={`solver-roster-assignment studio-assignment-drag ${assignment.locked?"leader-locked":""}`} style={assignmentStyle(assignment.role.id,shift.location.id)} draggable={leaderEditable&&!assignment.locked} onDragStart={event=>{event.dataTransfer.setData("application/x-grafik-assignment",assignment.id);event.dataTransfer.effectAllowed="move";}} onDragOver={event=>{if(leaderEditable&&event.dataTransfer.types.includes("application/x-grafik-assignment")){event.preventDefault();event.dataTransfer.dropEffect="move";}}} onDrop={event=>{const sourceAssignmentId=event.dataTransfer.getData("application/x-grafik-assignment");if(sourceAssignmentId&&sourceAssignmentId!==assignment.id){event.preventDefault();void applyAssignmentDrag({sourceAssignmentId,targetAssignmentId:assignment.id});}}} key={assignment.id}><span><b>{timeLabel(shift.startsAt,shift.location.timezone??timezone)}–{timeLabel(shift.endsAt,shift.location.timezone??timezone)}</b><small>{shift.location.name} • {assignment.role.name}</small></span>{assignment.duties.length>0&&<span className="solver-week-duties">{assignment.duties.map(duty=><em style={dutyStyle(duty.id)} key={duty.id}>{duty.name}</em>)}</span>}{leaderEditable&&<span className="studio-assignment-actions"><button aria-label={assignment.locked?"Odepnij decyzję lidera":"Przypnij decyzję lidera"} disabled={leaderBusy} onClick={()=>void toggleAssignmentLock(assignment.id,!assignment.locked)}>{assignment.locked?<LockKeyhole/>:<LockOpen/>}</button><button aria-label={"Zmień przydział: "+employee.firstName+" "+employee.lastName} disabled={leaderBusy||assignment.locked} onClick={()=>void openLeaderEdit({assignmentId:assignment.id})}><Edit3/></button></span>}</article>)}{!entries.length&&date.slice(0,7)===workspace.context.month.slice(0,7)&&<span className="solver-roster-empty">—</span>}</div>})}</div>)}
          {schedulePerspective==="ROLES"&&scheduleRoles.map(role=><div className="solver-roster-grid solver-roster-row" key={role.id}><header style={roleStyle(role.id)}><strong>{role.name}</strong><small>Obsada stanowiska</small></header>{week.map(date=>{const entries=scheduleEntries.filter(entry=>entry.assignment.role.id===role.id&&entry.shift.date===date);return <div className={["solver-roster-cell",date.slice(0,7)!==workspace.context.month.slice(0,7)?"outside-month":""].join(" ")} key={date}>{entries.map(({shift,assignment})=><article className={`solver-role-assignment studio-assignment-drag ${assignment.locked?"leader-locked":""}`} style={assignmentStyle(role.id,shift.location.id)} draggable={leaderEditable&&!assignment.locked} onDragStart={event=>{event.dataTransfer.setData("application/x-grafik-assignment",assignment.id);event.dataTransfer.effectAllowed="move";}} onDragOver={event=>{if(leaderEditable&&event.dataTransfer.types.includes("application/x-grafik-assignment")){event.preventDefault();event.dataTransfer.dropEffect="move";}}} onDrop={event=>{const sourceAssignmentId=event.dataTransfer.getData("application/x-grafik-assignment");if(sourceAssignmentId&&sourceAssignmentId!==assignment.id){event.preventDefault();void applyAssignmentDrag({sourceAssignmentId,targetAssignmentId:assignment.id});}}} key={assignment.id}><span><b>{assignment.employee.firstName} {assignment.employee.lastName}</b><small>{timeLabel(shift.startsAt,shift.location.timezone??timezone)}–{timeLabel(shift.endsAt,shift.location.timezone??timezone)} • {shift.location.name}</small></span>{assignment.duties.length>0&&<span className="solver-week-duties">{assignment.duties.map(duty=><em style={dutyStyle(duty.id)} key={duty.id}>{duty.name}</em>)}</span>}{leaderEditable&&<span className="studio-assignment-actions"><button aria-label={assignment.locked?"Odepnij decyzję lidera":"Przypnij decyzję lidera"} disabled={leaderBusy} onClick={()=>void toggleAssignmentLock(assignment.id,!assignment.locked)}>{assignment.locked?<LockKeyhole/>:<LockOpen/>}</button><button aria-label="Edytuj przydział" disabled={leaderBusy||assignment.locked} onClick={()=>void openLeaderEdit({assignmentId:assignment.id})}><Edit3/></button></span>}</article>)}{!entries.length&&date.slice(0,7)===workspace.context.month.slice(0,7)&&<span className="solver-roster-empty">—</span>}</div>})}</div>)}
        </div>}
        {schedulePerspective==="COVERAGE"&&<div className="solver-coverage-days">{week.filter(date=>date.slice(0,7)===workspace.context.month.slice(0,7)).map(date=>{const dayShifts=visibleShifts.filter(shift=>shift.date===date);return <section key={date}><header><CalendarDays/><strong>{shortDayLabel(date)}</strong><small>{dayShifts.length} zmian</small></header><div>{dayShifts.sort((a,b)=>a.startsAt.localeCompare(b.startsAt)||a.location.name.localeCompare(b.location.name,"pl-PL")).map(shift=>{const issues=visibleIssues.filter(issue=>issue.code==="UNFILLED_SLOT"&&issue.shift?.id===shift.id);const assigned=shift.assignments.length;const missing=issues.reduce((sum,issue)=>sum+missingSeats(issue),0);const required=assigned+missing;const noDemand=required===0;return <article style={locationStyle(shift.location.id)} className={noDemand?"no-demand":missing?"shortage studio-vacancy-target":"complete"} onDragOver={event=>{if(missing>0&&leaderEditable){event.preventDefault();event.dataTransfer.dropEffect=event.dataTransfer.types.includes("application/x-grafik-assignment")?"move":"copy";}}} onDrop={event=>{const sourceAssignmentId=event.dataTransfer.getData("application/x-grafik-assignment");const employeeId=event.dataTransfer.getData("application/x-grafik-employee");if(sourceAssignmentId&&issues[0]){event.preventDefault();void applyAssignmentDrag({sourceAssignmentId,targetIssueId:issues[0].id});}else if(employeeId&&issues[0]){event.preventDefault();void openLeaderEdit({issueId:issues[0].id,preferredEmployeeId:employeeId});}}} key={shift.id}><span><b>{timeLabel(shift.startsAt,shift.location.timezone??timezone)}–{timeLabel(shift.endsAt,shift.location.timezone??timezone)}</b><small>{shift.shiftTemplate.name} • {shift.location.name}</small></span><strong>{noDemand?"—":`${assigned}/${required}`}</strong><em>{noDemand?"Brak wymaganego zapotrzebowania":missing?`Brakuje ${missing}`:"Pełna obsada"}</em>{missing>0&&leaderEditable&&<button onClick={()=>void openLeaderEdit({issueId:issues[0].id})}>Wybierz wakat</button>}</article>})}{!dayShifts.length&&<p>Brak zaplanowanych zmian tego dnia.</p>}</div></section>})}</div>}
      </article>)}
    </section>}

    {employeeDetail&&<><button className="drawer-scrim top" onClick={()=>setEmployeeDetailId("")}/><aside className="drawer top solver-employee-compare-drawer">
      <div className="drawer-head"><div><p className="eyebrow">GRAFIK PRACOWNIKA • PORÓWNANIE</p><h2>{employeeDetailName}</h2><small>{employeeDetail.employeeNo} • {employeeDetailWorkload?.nominalMonthlyMinutes?`cel ${workloadHours(employeeDetailWorkload.nominalMonthlyMinutes)}`:employeeDetail.nominalMonthlyMinutes?`cel ${workloadHours(employeeDetail.nominalMonthlyMinutes)}`:"bez wpisanego celu godzinowego"}</small></div><button className="icon-button" onClick={()=>setEmployeeDetailId("")}><X/></button></div>
      <div className="drawer-content">
        {workloadLoading&&!employeeDetailWorkload&&<div className="solver-workspace-empty"><RefreshCw className="spin"/> Obliczamy bieżący bilans tej osoby…</div>}
        {employeeDetailWorkload&&<div className="employee-detail-workload-summary">
          <span><small>Zaproponowane godziny</small><strong>{workloadHours(employeeDetailWorkload.plannedMinutes)}</strong></span>
          <span><small>Liczba zmian</small><strong>{employeeDetailWorkload.shiftCount}</strong></span>
          <span><small>Cel godzinowy</small><strong>{employeeDetailWorkload.nominalMonthlyMinutes>0?workloadHours(employeeDetailWorkload.nominalMonthlyMinutes):"Brak"}</strong></span>
          <span><small>Twardy limit</small><strong>{employeeDetailWorkload.maximumMonthlyMinutes>0?workloadHours(employeeDetailWorkload.maximumMonthlyMinutes):"Brak"}</strong></span>
          <span className={employeeDetailWorkload.differenceMinutes===0?"on-target":""}><small>Różnica od celu</small><strong>{employeeDetailWorkload.nominalMonthlyMinutes>0?`${employeeDetailWorkload.differenceMinutes>0?"+":""}${workloadHours(employeeDetailWorkload.differenceMinutes)}`:"—"}</strong></span>
        </div>}
        <div className="employee-compare-toolbar"><label><ArrowLeftRight/> Porównaj z<select value={comparisonEmployeeId} onChange={event=>setComparisonEmployeeId(event.target.value)}><option value="">Nie porównuj</option>{scheduleEmployees.filter(employee=>employee.id!==employeeDetail.id).map(employee=><option value={employee.id} key={employee.id}>{employee.lastName} {employee.firstName} • {employee.employeeNo}</option>)}</select></label><small>Nakładamy oba grafiki tydzień po tygodniu. Obowiązki i lokale są widoczne przy każdej zmianie; każda korekta przechodzi końcową kontrolę serwera.</small></div>
        <div className="employee-compare-legend"><span className="primary-person">{employeeDetailName}</span>{comparisonEmployee&&<span className="comparison-person">{comparisonEmployee.firstName} {comparisonEmployee.lastName}</span>}</div>
        <section className="employee-availability-comparison employee-availability-month-grid" aria-label="Dostępność porównywanych pracowników">
          <header><strong>Dostępność w układzie kalendarza poniedziałek–niedziela</strong><small>{comparisonAvailabilityLoading?"Sprawdzamy deklaracje…":"Daty pozostają w tych samych kolumnach co w grafiku poniżej."}</small></header>
          <div className="employee-availability-weeks">{weeks.map(week=><section key={week[0]}>{week.map(date=>date.slice(0,7)===workspace.context.month.slice(0,7)?<article key={date}><b>{shortDayLabel(date)}</b>{[employeeDetail.id,comparisonEmployee?.id].filter(Boolean).map(employeeId=>{const row=comparisonAvailability.find(item=>item.employeeId===employeeId&&item.date===date);const person=employeeId===employeeDetail.id?employeeDetailShortName:comparisonEmployee?.firstName;return <span className={`availability-${(row?.status??"unknown").toLowerCase()}`} key={employeeId}><em>{person}</em><small>{row?.scheduled?"Ma zmianę • ":""}{row?.label??"Sprawdzamy dostępność"}</small></span>;})}</article>:<article className="outside-month" key={date}/>)}</section>)}</div>
        </section>
        {leaderEditable&&!comparisonEmployee&&<div className="swap-suggestion-hint"><ArrowLeftRight/><span><strong>Możliwe zamiany dla {employeeDetailShortName}</strong><small>Przy każdej zmianie wybierz „Możliwa zamiana”. Otworzymy wyszukiwalną listę osób z wolnym oknem oraz analizą obowiązku.</small></span></div>}
        <div className="employee-compare-weeks">{weeks.map((week,weekIndex)=><section key={week[0]}><header><strong>Tydzień {weekIndex+1}</strong><small>{shortDayLabel(week[0])} – {shortDayLabel(week[6])}</small></header><div>{week.filter(date=>date.slice(0,7)===workspace.context.month.slice(0,7)).map(date=>{const primary=employeeEntries(employeeDetail.id,date);const compared=comparisonEmployee?employeeEntries(comparisonEmployee.id,date):[];return <article className="employee-compare-day" key={date}><header><CalendarDays/><strong>{shortDayLabel(date)}</strong></header><div className="employee-compare-slots"><section><small>{employeeDetailShortName}</small>{primary.map(({shift,assignment})=><div style={assignmentStyle(assignment.role.id,shift.location.id)} key={assignment.id}><span><b>{timeLabel(shift.startsAt,shift.location.timezone??timezone)}–{timeLabel(shift.endsAt,shift.location.timezone??timezone)}</b><small>{shift.location.name} • {assignment.role.name}</small></span>{assignment.duties.length>0&&<span className="solver-week-duties">{assignment.duties.map(duty=><em style={dutyStyle(duty.id)} key={duty.id}>{duty.name}</em>)}</span>}{leaderEditable&&!comparisonEmployee&&<button type="button" className="possible-swap-day" onClick={()=>void openLeaderEdit({assignmentId:assignment.id})}><ArrowLeftRight/> Możliwa zamiana</button>}{leaderEditable&&comparisonEmployee&&<button aria-label="Edytuj przydział" onClick={()=>void openLeaderEdit({assignmentId:assignment.id})}><Edit3/></button>}</div>)}{!primary.length&&<p>Wolne</p>}</section>{comparisonEmployee&&<section><small>{comparisonEmployee.firstName}</small>{compared.map(({shift,assignment})=><div style={assignmentStyle(assignment.role.id,shift.location.id)} key={assignment.id}><span><b>{timeLabel(shift.startsAt,shift.location.timezone??timezone)}–{timeLabel(shift.endsAt,shift.location.timezone??timezone)}</b><small>{shift.location.name} • {assignment.role.name}</small></span>{assignment.duties.length>0&&<span className="solver-week-duties">{assignment.duties.map(duty=><em style={dutyStyle(duty.id)} key={duty.id}>{duty.name}</em>)}</span>}{leaderEditable&&<button aria-label="Edytuj przydział" onClick={()=>void openLeaderEdit({assignmentId:assignment.id})}><Edit3/></button>}</div>)}{!compared.length&&<p>Wolne</p>}</section>}</div>{comparisonEmployee&&((primary.length&&!compared.length)||(!primary.length&&compared.length))&&<button type="button" className="swap-opportunity" disabled={!leaderEditable} onClick={()=>void openLeaderEdit({assignmentId:(primary[0]??compared[0]).assignment.id,preferredEmployeeId:primary.length?comparisonEmployee.id:employeeDetail.id})}><ArrowLeftRight/> Sprawdź, czy {primary.length?comparisonEmployee.firstName:employeeDetailShortName} może przejąć tę zmianę. System najpierw kontroluje rolę, lokal i obowiązek, a przy zapisie cały miesiąc.</button>}</article>})}</div></section>)}</div>
      </div>
    </aside></>}

    {leaderContext&&<>{!leaderEditable&&<button className="drawer-scrim top" onClick={()=>setLeaderContext(null)}/>}<aside className={leaderEditable?"leader-studio-candidate-panel":"drawer role-drawer top leader-assignment-drawer"}>
      <div className="drawer-head"><div><p className="eyebrow">WERSJA LIDERA • EDYCJA PRZED PUBLIKACJĄ</p><h2>{leaderContext.shift.date} • {leaderContext.shift.shiftName}</h2><small>{leaderContext.shift.locationName} • {leaderContext.role.name} • {timeLabel(leaderContext.shift.startsAt,timezone)}–{timeLabel(leaderContext.shift.endsAt,timezone)}</small></div><button className="icon-button" onClick={()=>setLeaderContext(null)}><X/></button></div>
      <div className="drawer-content">
        <div className="solver-v2-notice"><ShieldCheck/><span><strong>Oryginalne warianty nie zostaną zmienione</strong><small>Ta korekta dotyczy tylko kopii lidera. Przed zapisem serwer ponownie sprawdzi cały miesiąc, wszystkie twarde reguły oraz koszty.</small></span></div>
        <div className="leader-candidate-picker">
          <label>Znajdź pracownika<input value={leaderSearch} onChange={event=>setLeaderSearch(event.target.value)} placeholder="Wpisz nazwisko, numer, rolę, lokal lub obowiązek"/></label>
          <div className="leader-candidate-view" role="tablist" aria-label="Filtr kandydatów"><button type="button" className={leaderCandidateView==="ELIGIBLE"?"active":""} onClick={()=>setLeaderCandidateView("ELIGIBLE")}>Tylko możliwe</button><button type="button" className={leaderCandidateView==="BELOW_TARGET"?"active":""} onClick={()=>setLeaderCandidateView("BELOW_TARGET")}>Poniżej celu</button><button type="button" className={leaderCandidateView==="PREFERRED"?"active":""} onClick={()=>setLeaderCandidateView("PREFERRED")}>Dostępni</button><button type="button" className={leaderCandidateView==="ALL"?"active":""} onClick={()=>setLeaderCandidateView("ALL")}>Wszyscy z powodami</button></div>
          <div className="leader-candidate-summary"><span><b>{eligibleLeaderCandidates}</b> można bezpiecznie sprawdzić</span><span><b>{blockedLeaderCandidates}</b> ma blokadę lub brak pokrycia obowiązku</span></div>
          <div>{visibleLeaderCandidates.map(candidate=><button type="button" draggable={candidate.suggestionEligible} disabled={!candidate.suggestionEligible} className={`${leaderEmployeeId===candidate.employeeId?"selected":""} ${candidate.suggestionEligible?"eligible":"blocked"}`} onDragStart={event=>{event.dataTransfer.setData("application/x-grafik-employee",candidate.employeeId);event.dataTransfer.effectAllowed="copy";setLeaderEmployeeId(candidate.employeeId);}} onClick={()=>{setLeaderEmployeeId(candidate.employeeId);setLeaderFeedback("");setLeaderLimitWarning("");setLeaderOvertimeWarning(false);setLeaderValidatedKey("");}} key={candidate.employeeId}>
            <span><strong>{candidate.employeeName}</strong><small>{candidate.employeeNo}{candidate.current?" • obecnie":""} • {availabilityLabel(candidate.availabilityStatus)}</small><em>{candidate.dutyCoverageMode==="DIRECT"?(leaderContext.duty?`Ma obowiązek: ${leaderContext.duty.name}`:"Rola i lokal pasują"):candidate.dutyCoverageMode==="TRANSFER"?`${candidate.dutyTransferEmployeeName} przejmie obowiązek „${leaderContext.duty?.name}”`:`Brak pokrycia obowiązku „${leaderContext.duty?.name}”`}</em>{candidate.addedOvertimeMinutes>0&&<em className={candidate.overtimeBlocked?"overtime-blocked":candidate.overtimeApprovalRequired?"overtime-approval":"overtime-allowed"}>{candidate.overtimeBlocked?"Nadgodziny niedozwolone":candidate.overtimeApprovalRequired?"Nadgodziny wymagają decyzji lidera":"Nadgodziny dozwolone przez pracownika"} • +{workloadHours(candidate.addedOvertimeMinutes)}</em>}</span>
            {leaderEmployeeId===candidate.employeeId&&<Check/>}
          </button>)}</div>
          {!visibleLeaderCandidates.length&&<p>Brak kandydatów spełniających wyszukiwanie i wybrany filtr. Wybierz „Wszyscy z powodami”, aby zobaczyć konkretne blokady.</p>}
          <small>Lista pokazuje cały zespół, a nie czterech „aktywnych” pracowników: zielone osoby można sprawdzić i zapisać, wyszarzone mają podany konkretny powód blokady. Przy zamianie trójstronnej serwer może przenieść obowiązek, a na końcu kontroluje cały miesiąc.</small>
        </div>
        {selectedLeaderCandidate&&<section className="leader-change-preview">
          <header><BarChart3/><span><strong>Skutek przed zapisem</strong><small>Podgląd dla {selectedLeaderCandidate.employeeName}; „Sprawdź” wykona niemutującą kontrolę całego miesiąca.</small></span></header>
          <div><span><small>Godziny przed</small><b>{workloadHours(selectedLeaderCandidate.currentMonthlyMinutes)}</b></span><span><small>Godziny po</small><b>{workloadHours(selectedLeaderCandidate.projectedMonthlyMinutes)}</b></span><span><small>Cel miesięczny</small><b>{selectedLeaderCandidate.nominalMonthlyMinutes?workloadHours(selectedLeaderCandidate.nominalMonthlyMinutes):"Brak"}</b></span><span><small>Realizacja celu</small><b>{selectedLeaderCandidate.nominalMonthlyMinutes?`${Math.round(selectedLeaderCandidate.projectedMonthlyMinutes/selectedLeaderCandidate.nominalMonthlyMinutes*100)}%`:"—"}</b></span>{financeVisibility==="FULL"&&<span><small>Zmiana kosztu</small><b>{selectedLeaderCandidate.addedCostMinor>=0?"+":""}{money(selectedLeaderCandidate.addedCostMinor,selectedLeaderCandidate.currency)}</b></span>}<span><small>Dostępność</small><b>{availabilityLabel(selectedLeaderCandidate.availabilityStatus)}</b></span></div>
        </section>}
        <label>Powód zmiany<textarea required minLength={3} value={leaderReason} onChange={event=>setLeaderReason(event.target.value)} placeholder="np. uzgodniona zamiana w zespole"/></label>
        {selectedLeaderCandidate&&selectedLeaderCandidate.addedOvertimeMinutes>0&&<div className={`leader-overtime-quote ${selectedLeaderCandidate.overtimeBlocked?"blocked":selectedLeaderCandidate.overtimeApprovalRequired?"approval":"allowed"}`}>
          <header><CircleDollarSign/><span><strong>{selectedLeaderCandidate.overtimeBlocked?"Ta osoba nie może mieć nadgodzin":selectedLeaderCandidate.overtimeApprovalRequired?"Propozycja nadgodzin do zatwierdzenia":"Nadgodziny dozwolone przez pracownika"}</strong><small>Wycena obejmuje cały wariant po tej zmianie, w tym reguły zależne od umowy, dnia i pory.</small></span></header>
          <div><span><small>Przed zmianą</small><b>{workloadHours(selectedLeaderCandidate.currentMonthlyMinutes)}</b></span><span><small>Po zmianie</small><b>{workloadHours(selectedLeaderCandidate.projectedMonthlyMinutes)}</b></span><span><small>Nominał</small><b>{workloadHours(selectedLeaderCandidate.nominalMonthlyMinutes)}</b></span><span><small>Nowe nadgodziny</small><b>+{workloadHours(selectedLeaderCandidate.addedOvertimeMinutes)}</b></span>{financeVisibility==="FULL"&&<><span><small>Zmiana kosztu grafiku</small><b>{selectedLeaderCandidate.addedCostMinor>=0?"+":""}{money(selectedLeaderCandidate.addedCostMinor,selectedLeaderCandidate.currency)}</b></span><span><small>Pełny koszt po zmianie</small><b>{money(selectedLeaderCandidate.projectedTotalCostMinor,selectedLeaderCandidate.currency)}</b></span></>}</div>
          {selectedLeaderCandidate.overtimeBlocked&&<p>Ustawienie „NIE” jest twardą blokadą. Zwykły zapis ani wyjątek od limitu nie mogą jej ominąć.</p>}
        </div>}
        {leaderFeedback&&<div className="solver-v2-notice warning" role="status"><AlertTriangle/><span><strong>Status zapisu</strong><small>{leaderFeedback}</small></span></div>}
        {leaderLimitWarning&&<div className="solver-v2-notice danger" role="alert"><AlertTriangle/><span><strong>Świadomy wyjątek od limitu</strong><small>{leaderLimitWarning} Solver automatyczny nadal nie wykona takiego przydziału. Najpierw sprawdź wyjątek, a potem wybierz „Przypisz mimo limitu”; decyzja i powód pozostaną w audycie.</small></span></div>}
        <div className="leader-edit-actions">{leaderContext.assignmentId&&<button className="danger-button" disabled={leaderBusy} onClick={()=>void removeLeaderEdit()}><Trash2/> Usuń przydział</button>}<button className="secondary-button" disabled={leaderBusy||Boolean(selectedLeaderCandidate?.overtimeBlocked)} onClick={()=>void validateLeaderEdit(Boolean(leaderLimitWarning),leaderOvertimeWarning)}>{leaderBusy?<RefreshCw className="spin"/>:<Check/>} {leaderLimitWarning||leaderOvertimeWarning?"Sprawdź wyjątek":"Sprawdź"}</button><button className="primary-button" disabled={leaderBusy||leaderReason.trim().length<3||!leaderValidatedKey} onClick={()=>void saveLeaderEdit(Boolean(leaderLimitWarning),leaderOvertimeWarning)}><Check/> {leaderOvertimeWarning?"Zatwierdź nadgodziny i zapisz":leaderLimitWarning?"Przypisz mimo limitu":"Zapisz"}</button></div>
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
        {variantDiagnostics.candidates.some(candidate=>candidate.roleMatch)&&<section className="variant-role-candidates"><div><h3>Pracownicy z wymaganą rolą</h3><p>Kliknij osobę, aby bez wychodzenia z analizy zobaczyć jej kalendarz, aktualne godziny, liczbę zmian, cel i twardy limit. Rola i dodatkowy obowiązek są sprawdzane osobno.</p></div>{variantDiagnostics.candidates.filter(candidate=>candidate.roleMatch).map(candidate=>{const workload=(currentWorkloadRows??[]).find(row=>row.employeeId===candidate.employeeId);const onlyLimitRisk=candidate.reasons.length>0&&candidate.reasons.every(reason=>reason==="WEEKLY_LIMIT"||reason==="MONTHLY_LIMIT");return <article key={candidate.employeeId}><button type="button" className="candidate-calendar-link" onClick={()=>openEmployeeCalendar(candidate)}><span><strong>{candidate.employeeName}</strong><small>{candidate.employeeNo} • {candidate.locationMatch?"lokal pasuje":"lokal nie pasuje"}{candidate.dutyMatch?" • wymagany obowiązek pasuje":" • brak wymaganego obowiązku"}</small></span><em><CalendarDays/> {workload?`${workloadHours(workload.plannedMinutes)} • ${workload.shiftCount} zmian • cel ${workload.nominalMonthlyMinutes>0?workloadHours(workload.nominalMonthlyMinutes):"brak"}`:"Otwórz kalendarz i bilans"}</em></button>{candidate.reasons.length?<><ul>{candidate.reasons.map(reason=><li key={reason}>{reasonLabel(reason)}</li>)}</ul>{candidate.blockingDetails?.map((detail,index)=><small className="candidate-block-detail" key={`${detail.code}:${index}`}>{detail.label}{detail.shiftName?` • ${detail.shiftName}`:""}{detail.locationName?` • ${detail.locationName}`:""}{detail.startsAt?` • ${timeLabel(detail.startsAt,timezone)}–${timeLabel(detail.endsAt??detail.startsAt,timezone)}`:""}</small>)}{leaderEditable&&onlyLimitRisk&&<button className="danger-button" onClick={()=>{const issueId=variantDiagnostics.issueId;setVariantDiagnostics(null);void openLeaderEdit({issueId,preferredEmployeeId:candidate.employeeId});}}><AlertTriangle/> Przypisz w wersji lidera</button>}</>:<div className="candidate-eligible-actions"><b className="candidate-eligible">Brak indywidualnej blokady</b>{variantDiagnostics.publishedScheduleId&&<button className="primary-button" disabled={variantDiagnosticsLoading} onClick={()=>void assignVariantCandidate(candidate)}>{variantDiagnosticsLoading&&selectedEmployee===candidate.employeeId?<RefreshCw className="spin"/>:<Plus/>} Sprawdź i dopisz do grafiku</button>}</div>}</article>})}</section>}
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
