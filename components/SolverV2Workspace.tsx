"use client";

import { AlertTriangle, BarChart3, CalendarDays, Check, CircleDollarSign, Edit3, MapPin, Plus, RefreshCw, ShieldCheck, Trash2, Users, X } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import type { CSSProperties } from "react";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { emergencyAssignV2, getCandidateDiagnostics, getLeaderAssignmentContext, getManagerStandbyMonth, getVariantIssueDiagnostics, getVariantWorkloadDistribution, removeLeaderAssignment, saveLeaderAssignment, solverErrorMessage, type SolverCandidateDiagnostic, type SolverCandidateDiagnostics, type SolverLeaderAssignmentContext, type SolverManagerStandby, type SolverVariantIssueDiagnostics, type SolverWorkloadDistributionRow, type SolverWorkspace, type SolverWorkspaceIssue } from "@/lib/solver-v2";

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
  if(row.reasonCode==="AVAILABILITY_LIMITED")return `Ograniczenie dostępności: ${row.hardUnavailableDays} dni twardej niedostępności w tym miesiącu.`;
  if(row.reasonCode==="AVAILABILITY_WINDOW_LIMITED")return `Pracownik podał konkretne okna dostępności w ${row.availableWindowDays} dniach; silnik mógł planować tylko wewnątrz nich.`;
  if(row.reasonCode==="MAXIMUM_REACHED")return "Osiągnięto miesięczny limit godzin zapisany w konfiguracji pracownika.";
  if(row.reasonCode==="TARGET_NOT_SET")return "Nie ustawiono miesięcznego wymiaru. Silnik nie miał celu godzinowego, z którym mógł porównać tę osobę.";
  if(row.reasonCode==="ABOVE_NOMINAL")return "Przydział przekracza miesięczny wymiar. Lider powinien sprawdzić koszt i zgodność z umową przed publikacją.";
  if(row.reasonCode==="ON_TARGET")return "Przydział jest zgodny z ustawionym miesięcznym wymiarem.";
  return "Brak indywidualnej twardej blokady dostępności. Różnica wynika z rozdziału solvera, zapotrzebowania zmian i reguł całego zespołu.";
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

function roleStyle(roleId:string):CSSProperties{
  const index=[...roleId].reduce((sum,character)=>sum+character.charCodeAt(0),0)%rolePalette.length;
  return {"--role-accent":rolePalette[index].accent,"--role-background":rolePalette[index].background} as CSSProperties;
}

function dutyStyle(dutyId:string):CSSProperties{
  const index=[...dutyId].reduce((sum,character)=>sum+character.charCodeAt(0),0)%dutyPalette.length;
  return {color:dutyPalette[index].accent,backgroundColor:dutyPalette[index].background};
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
    {(issue.role||issue.duty)&&<small>{[issue.role?.name,issue.duty?.name].filter(Boolean).join(" • ")}</small>}
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
  const [leaderReason,setLeaderReason]=useState("");
  const [leaderBusy,setLeaderBusy]=useState(false);
  const [workspaceView,setWorkspaceView]=useState<WorkspaceView>("CALENDAR");
  const [schedulePerspective,setSchedulePerspective]=useState<SchedulePerspective>("EMPLOYEES");
  const [workloadRows,setWorkloadRows]=useState<SolverWorkloadDistributionRow[]|null>(null);
  const [workloadLoading,setWorkloadLoading]=useState(false);
  const [workloadError,setWorkloadError]=useState("");
  const [workloadSearch,setWorkloadSearch]=useState("");
  const [workloadLocation,setWorkloadLocation]=useState("");
  const [workloadReasonFilter,setWorkloadReasonFilter]=useState("");
  const [workloadSort,setWorkloadSort]=useState<"HOURS_DESC"|"HOURS_ASC"|"DIFFERENCE">("HOURS_DESC");
  const scopeRoleId=workspace.variants[0]?.scope.role?.id??null;
  useEffect(()=>{
    let active=true;
    if(!published||!supabase){setStandby([]);return;}
    setStandbyError("");
    void getManagerStandbyMonth(supabase,workspace.context.month,scopeRoleId)
      .then(rows=>{if(active)setStandby(rows);})
      .catch(error=>{if(active)setStandbyError(solverErrorMessage(error instanceof Error?error.message:String(error)));});
    return()=>{active=false;};
  },[published,scopeRoleId,supabase,workspace.context.month]);
  const shiftsByDate = new Map<string, typeof workspace.shifts>();
  for (const shift of workspace.shifts) {
    shiftsByDate.set(shift.date, [...(shiftsByDate.get(shift.date) ?? []), shift]);
  }
  const dates = [...shiftsByDate.entries()].sort(([left], [right]) => left.localeCompare(right));
  const weeks=monthWeeks(workspace.context.month);
  const scheduleEntries=workspace.shifts.flatMap(shift=>shift.assignments.map(assignment=>({shift,assignment})));
  const scheduleEmployees=[...new Map(scheduleEntries.map(entry=>[entry.assignment.employee.id,entry.assignment.employee])).values()].sort((left,right)=>`${left.lastName} ${left.firstName}`.localeCompare(`${right.lastName} ${right.firstName}`,"pl-PL"));
  const scheduleRoles=[...new Map(scheduleEntries.map(entry=>[entry.assignment.role.id,entry.assignment.role])).values()].sort((left,right)=>left.name.localeCompare(right.name,"pl-PL"));
  const coverageRows=[...new Map(workspace.shifts.map(shift=>[`${shift.location.id}:${shift.shiftTemplate.id}:${timeLabel(shift.startsAt,shift.location.timezone??timezone)}:${timeLabel(shift.endsAt,shift.location.timezone??timezone)}`,{key:`${shift.location.id}:${shift.shiftTemplate.id}:${timeLabel(shift.startsAt,shift.location.timezone??timezone)}:${timeLabel(shift.endsAt,shift.location.timezone??timezone)}`,locationId:shift.location.id,locationName:shift.location.name,templateId:shift.shiftTemplate.id,shiftName:shift.shiftTemplate.name,start:timeLabel(shift.startsAt,shift.location.timezone??timezone),end:timeLabel(shift.endsAt,shift.location.timezone??timezone)}])).values()];
  const assignmentCount = workspace.variants.reduce((sum, variant) => sum + variant.assignmentCount, 0);
  const unfilledCount = workspace.variants.reduce((sum, variant) => sum + variant.unfilledCount, 0);
  const unfilledIssues=workspace.issues.filter(issue=>issue.code==="UNFILLED_SLOT");
  const missingSeats=(issue:SolverWorkspaceIssue)=>issue.requiredCount===null
    ? 1
    : Math.max(0,issue.requiredCount-(issue.assignedCount??0));
  const groupMissing=(label:(issue:SolverWorkspaceIssue)=>string)=>[...unfilledIssues.reduce((groups,issue)=>{
    const key=label(issue)||"Nieokreślone";
    groups.set(key,(groups.get(key)??0)+missingSeats(issue));
    return groups;
  },new Map<string,number>()).entries()].sort((left,right)=>right[1]-left[1]||left[0].localeCompare(right[0],"pl-PL"));
  const missingByRole=groupMissing(issue=>issue.role?.name??"Brak wskazanej roli");
  const missingByLocation=groupMissing(issue=>issue.shift?.location.name??"Brak wskazanego lokalu");
  const missingByShift=groupMissing(issue=>issue.shift?.shiftTemplate.name??"Brak wskazanej zmiany");
  const publishedAt = timestampLabel(workspace.context.publishedAt, timezone);
  const activeDiagnosticIssue=diagnostics?workspace.issues.find(issue=>issue.id===diagnostics.issue.id)??null:null;
  const workloadLocations=[...new Map((workloadRows??[]).flatMap(row=>row.locations.map(location=>[location.id,location] as const))).values()].sort((a,b)=>a.name.localeCompare(b.name,"pl-PL"));
  const filteredWorkload=(workloadRows??[]).filter(row=>{
    const search=workloadSearch.trim().toLocaleLowerCase("pl-PL");
    return (!search||`${row.employeeName} ${row.employeeNo} ${row.roleNames.join(" ")}`.toLocaleLowerCase("pl-PL").includes(search))
      &&(!workloadLocation||row.locations.some(location=>location.id===workloadLocation))
      &&(!workloadReasonFilter||row.reasonCode===workloadReasonFilter);
  }).sort((left,right)=>workloadSort==="HOURS_ASC"?left.plannedMinutes-right.plannedMinutes
    :workloadSort==="DIFFERENCE"?Math.abs(right.differenceMinutes)-Math.abs(left.differenceMinutes)
    :right.plannedMinutes-left.plannedMinutes||left.employeeName.localeCompare(right.employeeName,"pl-PL"));
  const workloadMinutes=filteredWorkload.map(row=>row.plannedMinutes).sort((a,b)=>a-b);
  const workloadMedian=workloadMinutes.length?(workloadMinutes[Math.floor((workloadMinutes.length-1)/2)]+workloadMinutes[Math.ceil((workloadMinutes.length-1)/2)])/2:0;

  async function openWorkload(force=false){
    setWorkspaceView("WORKLOAD");
    if(workloadRows&&!force||workloadLoading)return;
    const variantId=workspace.variants[0]?.id;
    if(!supabase||!variantId){setWorkloadError("Ten widok nie wskazuje wariantu do analizy.");return;}
    setWorkloadLoading(true);setWorkloadError("");
    try{setWorkloadRows(await getVariantWorkloadDistribution(supabase,variantId));}
    catch(error){setWorkloadError(solverErrorMessage(error instanceof Error?error.message:String(error)));}
    finally{setWorkloadLoading(false);}
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
    const result=await supabase.rpc("standby_activate_uat_v2",{
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

  async function openLeaderEdit(input:{assignmentId?:string;issueId?:string}){
    const variantId=workspace.variants[0]?.id;
    if(!supabase||!leaderEditable||!variantId)return;
    setLeaderBusy(true);setLeaderContext(null);setLeaderReason("");
    try{
      const context=await getLeaderAssignmentContext(supabase,{variantId,...input});
      setLeaderContext(context);setLeaderEmployeeId(context.currentEmployeeId??"");
    }catch(error){fail?.(solverErrorMessage(error instanceof Error?error.message:String(error)));}
    finally{setLeaderBusy(false);}
  }
  async function saveLeaderEdit(){
    if(!supabase||!leaderContext||!leaderEmployeeId||leaderReason.trim().length<3)return;
    setLeaderBusy(true);
    try{
      await saveLeaderAssignment(supabase,{variantId:leaderContext.variantId,
        assignmentId:leaderContext.assignmentId,issueId:leaderContext.issueId,
        employeeId:leaderEmployeeId,reason:leaderReason.trim()});
      notify?.("Zmiana przeszła pełną kontrolę reguł i została zapisana wyłącznie w wersji lidera.");
      setLeaderContext(null);await onLeaderChanged?.();await openWorkload(true);
    }catch(error){fail?.(solverErrorMessage(error instanceof Error?error.message:String(error)));}
    finally{setLeaderBusy(false);}
  }
  async function removeLeaderEdit(){
    if(!supabase||!leaderContext?.assignmentId||leaderReason.trim().length<3)return;
    setLeaderBusy(true);
    try{
      await removeLeaderAssignment(supabase,{variantId:leaderContext.variantId,
        assignmentId:leaderContext.assignmentId,reason:leaderReason.trim()});
      notify?.("Przydział usunięto z wersji lidera. Miejsce jest widoczne jako brak do uzupełnienia.");
      setLeaderContext(null);await onLeaderChanged?.();await openWorkload(true);
    }catch(error){fail?.(solverErrorMessage(error instanceof Error?error.message:String(error)));}
    finally{setLeaderBusy(false);}
  }

  return <section className={`solver-workspace ${published ? "published" : ""}`}>
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

    {workspaceView==="ISSUES"&&<>
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

    <details className="solver-workspace-issues" open={workspace.issues.length > 0}>
      <summary>
        <span><AlertTriangle/><strong>{unfilledIssues.length?"Napraw braki i sprawdź powody":"Uwagi do grafiku"}</strong></span>
        <small>{workspace.issues.length}</small>
      </summary>
      {workspace.issues.length === 0
        ? <p>Nie zgłoszono braków ani uwag do tego wariantu.</p>
        : <div>
          {workspace.issues.map(issue => <WorkspaceIssueCard key={issue.id} issue={issue} timezone={timezone} operational={operational} published={published} busy={diagnosticsLoading||variantDiagnosticsLoading||leaderBusy} inspect={id=>void inspectIssue(id)} explainPreview={id=>void inspectVariantIssue(id)} previewAvailable={Boolean(workspace.variants[0]?.id)} leaderEditable={leaderEditable} editLeader={id=>void openLeaderEdit({issueId:id})}/>)}
        </div>}
    </details>
    </>}

    {workspace.finance && <div className="solver-workspace-finance">
      <div><CircleDollarSign/><span><small>Koszt podstawowy</small><strong>{money(workspace.finance.baseCostMinor, workspace.finance.currency)}</strong></span></div>
      <div><span><small>Dodatki płacowe</small><strong>{money(workspace.finance.additionsCostMinor, workspace.finance.currency)}</strong></span></div>
      <div><span><small>Łączny koszt</small><strong>{money(workspace.finance.totalCostMinor, workspace.finance.currency)}</strong></span></div>
      <div><span><small>Budżet scenariusza</small><strong>{money(workspace.finance.budgetMinor, workspace.finance.currency)}</strong></span></div>
    </div>}

    {workspaceView==="WORKLOAD"&&<section className="solver-workload-content" aria-label="Rozkład pracy zespołu">
      <header className="solver-workspace-view-head"><span><em>{published?"OPUBLIKOWANY GRAFIK":workspace.context.variantKind==="LEADER_COPY"?"WERSJA LIDERA • JESZCZE NIEOPUBLIKOWANA":"WARIANT • JESZCZE NIEOPUBLIKOWANY"}</em><strong>Rozkład pracy zespołu</strong><small>{workspace.context.variantKind==="LEADER_COPY"?"Aktualny bilans kopii lidera — po każdej zmianie jest liczony ponownie.":"Analiza dokładnie tego wariantu, który wskazuje nagłówek."}</small></span><button className="secondary-button" disabled={workloadLoading} onClick={()=>void openWorkload(true)}><RefreshCw className={workloadLoading?"spin":""}/> Przelicz</button></header>
      {workloadLoading&&<div className="solver-workspace-empty"><RefreshCw className="spin"/> Obliczamy rozkład godzin…</div>}
      {workloadError&&<div className="solver-v2-notice warning"><AlertTriangle/><span><strong>Nie udało się pobrać rozkładu pracy</strong><small>{workloadError}</small></span></div>}
      {workloadRows&&<>
        <div className="solver-workload-summary">
          <span><small>Osoby w analizie</small><strong>{filteredWorkload.length}</strong></span>
          <span><small>Najmniej godzin</small><strong>{workloadHours(workloadMinutes[0]??0)}</strong></span>
          <span><small>Mediana</small><strong>{workloadHours(workloadMedian)}</strong></span>
          <span><small>Najwięcej godzin</small><strong>{workloadHours(workloadMinutes.at(-1)??0)}</strong></span>
          <span><small>Różnica min–max</small><strong>{workloadHours((workloadMinutes.at(-1)??0)-(workloadMinutes[0]??0))}</strong></span>
        </div>
        <div className="solver-workload-filters">
          <label>Znajdź pracownika<input value={workloadSearch} onChange={event=>setWorkloadSearch(event.target.value)} placeholder="Imię, nazwisko, numer lub rola"/></label>
          <label>Lokal<select value={workloadLocation} onChange={event=>setWorkloadLocation(event.target.value)}><option value="">Wszystkie lokale</option>{workloadLocations.map(location=><option key={location.id} value={location.id}>{location.name}</option>)}</select></label>
          <label>Wyjaśnienie<select value={workloadReasonFilter} onChange={event=>setWorkloadReasonFilter(event.target.value)}><option value="">Wszystkie przyczyny</option><option value="AVAILABILITY_LIMITED">Ograniczona dostępność</option><option value="AVAILABILITY_WINDOW_LIMITED">Konkretne okna dostępności</option><option value="MAXIMUM_REACHED">Osiągnięty limit</option><option value="TARGET_NOT_SET">Brak wymiaru</option><option value="SOLVER_DISTRIBUTION">Rozdział silnika</option><option value="ABOVE_NOMINAL">Powyżej wymiaru</option><option value="ON_TARGET">Zgodnie z wymiarem</option></select></label>
          <label>Sortowanie<select value={workloadSort} onChange={event=>setWorkloadSort(event.target.value as typeof workloadSort)}><option value="HOURS_DESC">Najwięcej godzin</option><option value="HOURS_ASC">Najmniej godzin</option><option value="DIFFERENCE">Największa różnica od wymiaru</option></select></label>
        </div>
        <div className="solver-workload-list">{filteredWorkload.map(row=><article key={row.employeeId}>
          <header><span><strong>{row.employeeName}</strong><small>{row.employeeNo} • {row.roleNames.join(", ")||"Rola w analizowanym grafiku"}</small></span><b>{workloadHours(row.plannedMinutes)}</b></header>
          <div className="solver-workload-kpis"><span><small>Zmiany</small><strong>{row.shiftCount}</strong></span><span><small>Wymiar</small><strong>{row.nominalMonthlyMinutes?workloadHours(row.nominalMonthlyMinutes):"Brak"}</strong></span><span><small>Różnica</small><strong className={row.differenceMinutes>0?"over":row.differenceMinutes<0?"under":""}>{row.nominalMonthlyMinutes?`${row.differenceMinutes>0?"+":""}${workloadHours(row.differenceMinutes)}`:"—"}</strong></span></div>
          <div className="solver-workload-locations">{row.locations.length?row.locations.map(location=><span key={location.id}><MapPin/>{location.name}: <b>{workloadHours(location.minutes)}</b> • {location.shiftCount} zmian</span>):<span>Brak przydziałów w lokalach</span>}</div>
          <p className={`reason-${row.reasonCode.toLowerCase()}`}><strong>Dlaczego taki wynik?</strong> {workloadReason(row)}</p>
        </article>)}</div>
        {!filteredWorkload.length&&<div className="solver-workspace-empty">Żadna osoba nie spełnia wybranych filtrów.</div>}
      </>}
    </section>}

    {workspaceView==="ISSUES"&&published && <details className="solver-workspace-standby" open>
      <summary><span><ShieldCheck/><strong>Rezerwa bezpieczeństwa</strong></span><small>{standby.length} dyżurów gotowości</small></summary>
      <p className="solver-workspace-empty">Pełna obsada ma pierwszeństwo. System dodaje pierwszą i — gdy pozwala na to liczebność zespołu — drugą osobę rezerwową.</p>
      {standbyError ? <p className="solver-workspace-empty">Nie udało się pobrać rezerwy: {standbyError}</p>
        : standby.length===0 ? <p className="solver-workspace-empty">Dla tego widoku nie udało się utworzyć bezpiecznej rezerwy bez naruszenia wymaganej obsady.</p>
        : <div className="solver-standby-days">{[...new Map(standby.map(item=>[item.date,standby.filter(row=>row.date===item.date)]))].map(([date,rows])=><article key={date}>
          <header><CalendarDays/><strong>{dateLabel(date)}</strong></header>
          {(rows as SolverManagerStandby[]).map(entry=><div key={entry.id}><span><b>{entry.roleName}</b><small>{entry.employeeName} • {entry.employeeNo}</small></span><em className={`tier-${entry.tier}`}>Rezerwa {entry.tier}{entry.status==="ACTIVATED"?" • aktywowana":entry.status==="DECLINED"?" • odrzucona":""}</em>{entry.status==="PLANNED"&&<button className="secondary-button" disabled={diagnosticsLoading} onClick={()=>{setStandbyAction(entry);setStandbyTargetAssignmentId("");setStandbyReason("");}}>Aktywuj</button>}</div>)}
        </article>)}</div>}
      {standbyAction&&<form className="standby-activation-form" onSubmit={event=>{event.preventDefault();void activateStandby();}}><div><strong>Aktywuj {standbyAction.employeeName} • rezerwa {standbyAction.tier}</strong><small>{standbyAction.date} • {standbyAction.roleName}. Wybierz osobę, której opublikowany przydział ma zostać zastąpiony. System ponownie sprawdzi wszystkie twarde reguły.</small></div><label>Zastępowany przydział<select required value={standbyTargetAssignmentId} onChange={event=>setStandbyTargetAssignmentId(event.target.value)}><option value="">Wybierz przydział</option>{workspace.shifts.filter(shift=>shift.date===standbyAction.date).flatMap(shift=>shift.assignments.filter(assignment=>assignment.role.id===standbyAction.roleId&&assignment.employee.id!==standbyAction.employeeId).map(assignment=><option key={assignment.id} value={assignment.id}>{assignment.employee.firstName} {assignment.employee.lastName} • {shift.shiftTemplate.name} • {timeLabel(shift.startsAt,shift.location.timezone??timezone)}</option>))}</select></label><label>Powód aktywacji<textarea required minLength={3} value={standbyReason} onChange={event=>setStandbyReason(event.target.value)} placeholder="np. potwierdzona nieobecność pracownika"/></label><div><button type="button" className="secondary-button" onClick={()=>setStandbyAction(null)}>Anuluj</button><button className="primary-button" disabled={diagnosticsLoading||!standbyTargetAssignmentId||standbyReason.trim().length<3}>Potwierdź aktywację</button></div></form>}
    </details>}

    {workspaceView==="CALENDAR"&&<section className="solver-weekly-workspace">
      <header className="solver-workspace-view-head"><span><strong>Grafik tygodniowy</strong><small>Ta sama wersja grafiku w trzech perspektywach. Pierwsza kolumna i daty pozostają widoczne podczas przewijania.</small></span></header>
      <div className="solver-schedule-perspectives" role="tablist" aria-label="Perspektywa grafiku"><button className={schedulePerspective==="EMPLOYEES"?"active":""} onClick={()=>setSchedulePerspective("EMPLOYEES")}>Pracownicy</button><button className={schedulePerspective==="ROLES"?"active":""} onClick={()=>setSchedulePerspective("ROLES")}>Stanowiska</button><button className={schedulePerspective==="COVERAGE"?"active":""} onClick={()=>setSchedulePerspective("COVERAGE")}>Pokrycie obsady</button></div>
      {dates.length === 0 && <div className="solver-workspace-empty">Ten wariant nie zawiera jeszcze zmian do pokazania.</div>}
      {weeks.map((week,weekIndex)=><article className="solver-roster-week" key={week[0]}>
        <header><strong>Tydzień {weekIndex+1}</strong><small>{shortDayLabel(week[0])} – {shortDayLabel(week[6])}</small></header>
        <div className="solver-roster-scroll">
          <div className="solver-roster-grid solver-roster-head"><b>{schedulePerspective==="EMPLOYEES"?"Pracownik":schedulePerspective==="ROLES"?"Stanowisko":"Zmiana i lokal"}</b>{week.map(date=><span className={date.slice(0,7)!==workspace.context.month.slice(0,7)?"outside-month":""} key={date}>{shortDayLabel(date)}</span>)}</div>
          {schedulePerspective==="EMPLOYEES"&&scheduleEmployees.map(employee=><div className="solver-roster-grid solver-roster-row" key={employee.id}><header><strong>{employee.firstName} {employee.lastName}</strong><small>{employee.nominalMonthlyMinutes?workloadHours(employee.nominalMonthlyMinutes)+" wymiaru":"Brak wymiaru"}</small></header>{week.map(date=>{const entries=scheduleEntries.filter(entry=>entry.assignment.employee.id===employee.id&&entry.shift.date===date);return <div className={["solver-roster-cell",date.slice(0,7)!==workspace.context.month.slice(0,7)?"outside-month":""].join(" ")} key={date}>{entries.map(({shift,assignment})=><article className="solver-roster-assignment" style={roleStyle(assignment.role.id)} key={assignment.id}><span><b>{timeLabel(shift.startsAt,shift.location.timezone??timezone)}–{timeLabel(shift.endsAt,shift.location.timezone??timezone)}</b><small>{shift.location.name} • {assignment.role.name}</small></span>{assignment.duties.length>0&&<span className="solver-week-duties">{assignment.duties.map(duty=><em style={dutyStyle(duty.id)} key={duty.id}>{duty.name}</em>)}</span>}{leaderEditable&&<button aria-label={"Zmień przydział: "+employee.firstName+" "+employee.lastName} disabled={leaderBusy} onClick={()=>void openLeaderEdit({assignmentId:assignment.id})}><Edit3/></button>}</article>)}{!entries.length&&date.slice(0,7)===workspace.context.month.slice(0,7)&&<span className="solver-roster-empty">—</span>}</div>})}</div>)}
          {schedulePerspective==="ROLES"&&scheduleRoles.map(role=><div className="solver-roster-grid solver-roster-row" key={role.id}><header style={roleStyle(role.id)}><strong>{role.name}</strong><small>Obsada stanowiska</small></header>{week.map(date=>{const entries=scheduleEntries.filter(entry=>entry.assignment.role.id===role.id&&entry.shift.date===date);return <div className={["solver-roster-cell",date.slice(0,7)!==workspace.context.month.slice(0,7)?"outside-month":""].join(" ")} key={date}>{entries.map(({shift,assignment})=><article className="solver-role-assignment" style={roleStyle(role.id)} key={assignment.id}><span><b>{assignment.employee.firstName} {assignment.employee.lastName}</b><small>{timeLabel(shift.startsAt,shift.location.timezone??timezone)}–{timeLabel(shift.endsAt,shift.location.timezone??timezone)} • {shift.location.name}</small></span>{leaderEditable&&<button aria-label="Edytuj przydział" disabled={leaderBusy} onClick={()=>void openLeaderEdit({assignmentId:assignment.id})}><Edit3/></button>}</article>)}{!entries.length&&date.slice(0,7)===workspace.context.month.slice(0,7)&&<span className="solver-roster-empty">—</span>}</div>})}</div>)}
          {schedulePerspective==="COVERAGE"&&coverageRows.map(coverage=><div className="solver-roster-grid solver-roster-row coverage" key={coverage.key}><header><strong>{coverage.shiftName}</strong><small>{coverage.start}–{coverage.end} • {coverage.locationName}</small></header>{week.map(date=>{const dayShifts=workspace.shifts.filter(shift=>shift.date===date&&shift.location.id===coverage.locationId&&shift.shiftTemplate.id===coverage.templateId&&timeLabel(shift.startsAt,shift.location.timezone??timezone)===coverage.start);const assigned=dayShifts.reduce((sum,shift)=>sum+shift.assignments.length,0);const issues=workspace.issues.filter(issue=>issue.code==="UNFILLED_SLOT"&&issue.shift?.date===date&&issue.shift.location.id===coverage.locationId&&issue.shift.shiftTemplate.id===coverage.templateId);const missing=issues.reduce((sum,issue)=>sum+missingSeats(issue),0);const required=assigned+missing;const percent=required?Math.round(assigned/required*100):0;return <div className={["solver-roster-cell","coverage",missing?"shortage":required?"complete":"",date.slice(0,7)!==workspace.context.month.slice(0,7)?"outside-month":""].join(" ")} key={date}>{required?<><span><b>{assigned}/{required}</b><small>{missing?"Brakuje "+missing:"Pełna obsada"}</small></span><i><b style={{width:String(percent)+"%"}}/></i>{missing>0&&leaderEditable&&<button onClick={()=>void openLeaderEdit({issueId:issues[0].id})}>Uzupełnij</button>}</>:date.slice(0,7)===workspace.context.month.slice(0,7)?<span className="solver-roster-empty">Brak zmiany</span>:null}</div>})}</div>)}
        </div>
      </article>)}
    </section>}

    {leaderContext&&<><button className="drawer-scrim top" onClick={()=>setLeaderContext(null)}/><aside className="drawer role-drawer top leader-assignment-drawer">
      <div className="drawer-head"><div><p className="eyebrow">WERSJA LIDERA • EDYCJA PRZED PUBLIKACJĄ</p><h2>{leaderContext.shift.date} • {leaderContext.shift.shiftName}</h2><small>{leaderContext.shift.locationName} • {leaderContext.role.name} • {timeLabel(leaderContext.shift.startsAt,timezone)}–{timeLabel(leaderContext.shift.endsAt,timezone)}</small></div><button className="icon-button" onClick={()=>setLeaderContext(null)}><X/></button></div>
      <div className="drawer-content">
        <div className="solver-v2-notice"><ShieldCheck/><span><strong>Oryginalne warianty nie zostaną zmienione</strong><small>Ta korekta dotyczy tylko kopii lidera. Przed zapisem serwer ponownie sprawdzi cały miesiąc, wszystkie twarde reguły oraz koszty.</small></span></div>
        <label>Pracownik<select required value={leaderEmployeeId} onChange={event=>setLeaderEmployeeId(event.target.value)}><option value="">Wybierz osobę</option>{leaderContext.candidates.map(candidate=><option value={candidate.employeeId} key={candidate.employeeId}>{candidate.employeeName} • {candidate.employeeNo}{candidate.current?" • obecnie":""}</option>)}</select><small>Lista zawiera osoby z właściwą rolą, lokalem i wymaganymi kompetencjami. Ostateczna kontrola obejmuje także dostępność, odpoczynek i limity pracy.</small></label>
        <label>Powód zmiany<textarea required minLength={3} value={leaderReason} onChange={event=>setLeaderReason(event.target.value)} placeholder="np. uzgodniona zamiana w zespole"/></label>
        <div className="leader-edit-actions">{leaderContext.assignmentId&&<button className="danger-button" disabled={leaderBusy||leaderReason.trim().length<3} onClick={()=>void removeLeaderEdit()}><Trash2/> Usuń przydział</button>}<button className="primary-button" disabled={leaderBusy||!leaderEmployeeId||leaderReason.trim().length<3} onClick={()=>void saveLeaderEdit()}>{leaderBusy?<RefreshCw className="spin"/>:<Check/>} Sprawdź i zapisz</button></div>
      </div>
    </aside></>}


    {variantDiagnostics&&<><button className="drawer-scrim top" onClick={()=>setVariantDiagnostics(null)}/><aside className="drawer role-drawer top candidate-diagnostics-drawer">
      <div className="drawer-head"><div><p className="eyebrow">WARIANT • WYJAŚNIENIE BRAKU</p><h2>{variantDiagnostics.shift.date} • {timeLabel(variantDiagnostics.shift.startsAt,timezone)}–{timeLabel(variantDiagnostics.shift.endsAt,timezone)}</h2><small>Powody są liczone dla pracowników dostępnych w opublikowanej konfiguracji firmy i aktualnego składu tego wariantu.</small></div><button className="icon-button" onClick={()=>setVariantDiagnostics(null)}><X/></button></div>
      <div className="drawer-content">
        <div className="candidate-diagnostics-summary"><span><b>{variantDiagnostics.summary.considered}</b><small>sprawdzonych osób</small></span><span><b>{variantDiagnostics.summary.eligible}</b><small>bez blokady</small></span><span><b>{variantDiagnostics.summary.blocked}</b><small>z blokadą</small></span></div>
        {variantDiagnostics.decisionContext&&<div className="solver-v2-notice warning"><AlertTriangle/><span><strong>Dlaczego powstał ten brak</strong><small>{variantDiagnostics.decisionContext.message} Ten błąd poprzedniej wersji silnika został naprawiony: rezerwa nie może już zmniejszać wymaganej obsady.</small></span></div>}
        {variantDiagnostics.summary.eligible>0&&!variantDiagnostics.decisionContext&&<div className="solver-v2-notice warning"><AlertTriangle/><span><strong>{variantDiagnostics.summary.eligible} osób nie ma indywidualnej twardej blokady</strong><small>{leaderEditable?"Wróć do listy braków i użyj „Uzupełnij w wersji lidera”. System sprawdzi wtedy cały miesiąc przed zapisem.":variantDiagnostics.publishedScheduleId?"To nie gwarantuje, że dopisanie zachowa poprawność całego miesiąca. Przycisk wykona ponowną kontrolę globalną przed zapisem.":"Silnik mógł wykorzystać te osoby w innym miejscu. Utwórz wersję lidera, aby poprawić grafik przed publikacją."}</small></span></div>}
        <div className="variant-reason-list">{variantDiagnostics.summary.reasons.map(reason=><article key={reason.code}><span><strong>{reasonLabel(reason.code)}</strong></span><b>{reason.count} os.</b></article>)}</div>
        {variantDiagnostics.candidates.some(candidate=>candidate.roleMatch)&&<section className="variant-role-candidates"><div><h3>Pracownicy z wymaganą rolą</h3><p>Lista pokazuje indywidualne blokady. Brak blokady nie oznacza jeszcze, że można dopisać osobę bez ponownej kontroli wszystkich reguł miesiąca.</p></div>{variantDiagnostics.candidates.filter(candidate=>candidate.roleMatch).map(candidate=><article key={candidate.employeeId}><span><strong>{candidate.employeeName}</strong><small>{candidate.employeeNo} • {candidate.locationMatch?"lokal pasuje":"lokal nie pasuje"}{candidate.dutyMatch?" • kompetencje pasują":" • brak wymaganej kompetencji"}</small></span>{candidate.reasons.length?<ul>{candidate.reasons.map(reason=><li key={reason}>{reasonLabel(reason)}</li>)}</ul>:<div className="candidate-eligible-actions"><b className="candidate-eligible">Brak indywidualnej blokady</b>{variantDiagnostics.publishedScheduleId&&<button className="primary-button" disabled={variantDiagnosticsLoading} onClick={()=>void assignVariantCandidate(candidate)}>{variantDiagnosticsLoading&&selectedEmployee===candidate.employeeId?<RefreshCw className="spin"/>:<Plus/>} Sprawdź i dopisz do grafiku</button>}</div>}</article>)}</section>}
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
