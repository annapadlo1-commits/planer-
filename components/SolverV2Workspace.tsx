"use client";

import { AlertTriangle, CalendarDays, Check, CircleDollarSign, MapPin, Plus, RefreshCw, ShieldCheck, Users, X } from "lucide-react";
import { useMemo, useState } from "react";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { emergencyAssignV2, getCandidateDiagnostics, solverErrorMessage, type SolverCandidateDiagnostic, type SolverCandidateDiagnostics, type SolverWorkspace, type SolverWorkspaceIssue } from "@/lib/solver-v2";

type Props = {
  workspace: SolverWorkspace;
  timezone: string;
  published?: boolean;
  operational?: boolean;
  onOperationalChanged?:()=>void|Promise<void>;
  notify?:(message:string)=>void;
  fail?:(message:string)=>void;
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

const hardReasonLabels:Record<string,string>={ROLE_REQUIRED:"Brak wymaganej roli",LOCATION_NOT_ALLOWED:"Lokal nie jest dozwolony w zwykłym limicie",LOCATION_REQUIRED:"Lokal nie jest dozwolony w zwykłym limicie",DUTY_REQUIRED:"Brak wymaganego obowiązku lub kompetencji",SHIFT_OVERLAP:"Nakładająca się zmiana",OVERLAPPING_SHIFT:"Nakładająca się zmiana",DECLARED_UNAVAILABLE:"Pracownik zgłosił niedostępność, urlop albo L4",TIME_CONSTRAINT:"Niedostępność, urlop lub L4",OUTSIDE_AVAILABILITY_WINDOW:"Zmiana poza zadeklarowanym oknem dostępności",REST_AFTER_PREVIOUS_SHIFT:"Za krótki odpoczynek po poprzedniej zmianie",REST_BEFORE_NEXT_SHIFT:"Za krótki odpoczynek przed następną zmianą",MINIMUM_REST:"Za krótki odpoczynek",MONTHLY_LIMIT:"Przekroczony limit miesięczny",WEEKLY_LIMIT:"Przekroczony limit tygodniowy",MAX_CONSECUTIVE_DAYS:"Przekroczona maksymalna liczba kolejnych dni pracy",MANAGER_SHIFT_BLOCK:"Pracodawca zablokował tę porę zmiany w Matrixie"};
const softReasonLabels:Record<string,string>={SHIFT_PREFERENCE_AVOIDED:"Pracownik prosi, aby unikać tej pory",SHIFT_AVOIDED:"Pracownik prosi, aby unikać tej pory",OVERTIME_AFTER_ASSIGNMENT:"Po dopisaniu przekroczy nominał miesięczny",MONTHLY_OVERTIME:"Po dopisaniu przekroczy nominał miesięczny"};
function reasonLabel(value:string){return hardReasonLabels[value]??softReasonLabels[value]??value;}
function preferenceLevelLabel(value:string){
  return ({PREFERRED:"preferowana",NEUTRAL:"neutralna",AVOIDED:"unikać",BLOCKED:"zablokowana"} as Record<string,string>)[value]??value;
}
function shiftPeriodLabel(value:string|undefined){
  return ({MORNING:"poranna",MIDDLE:"środek",EVENING:"wieczorna"} as Record<string,string>)[value??""]??value??"niestandardowa";
}

function WorkspaceIssueCard({issue,timezone,operational,published,busy,inspect}:{issue:SolverWorkspaceIssue;timezone:string;operational:boolean;published:boolean;busy:boolean;inspect:(id:string)=>void}){
  const shift=issue.shift;
  const shiftTimezone=shift?.location.timezone??timezone;
  const required=issue.requiredCount;
  const assigned=issue.assignedCount;
  const missing=required===null?null:Math.max(0,required-(assigned??0));
  return <article id={`solver-issue-${issue.id}`}>
    <header><span><strong>{issue.message}</strong><small>{issue.severity==="CRITICAL"?"BLOKADA KRYTYCZNA":issue.severity==="WARNING"?"OSTRZEŻENIE":"INFORMACJA"}</small></span></header>
    {shift&&<div className="solver-issue-context"><span><CalendarDays/><b>{dateLabel(shift.date)}</b></span><span><MapPin/><b>{shift.location.name}</b></span><span>{timeLabel(shift.startsAt,shiftTimezone)}–{timeLabel(shift.endsAt,shiftTimezone)} • {shift.shiftTemplate.name} • {shiftPeriodLabel(shift.shiftTemplate.shiftPeriod)}</span></div>}
    {(issue.role||issue.duty)&&<small>{[issue.role?.name,issue.duty?.name].filter(Boolean).join(" • ")}</small>}
    {required!==null&&<div className="solver-issue-staffing"><span>Wymagane <b>{required}</b></span><span>Przypisane <b>{assigned??0}</b></span><span>Brakuje <b>{missing}</b></span></div>}
    {operational&&published&&issue.code==="UNFILLED_SLOT"&&<button className="secondary-button" disabled={busy} onClick={()=>inspect(issue.id)}>{busy?<RefreshCw className="spin"/>:<Users/>} Dlaczego nikt nie został przypisany?</button>}
  </article>;
}

export function SolverV2Workspace({ workspace, timezone, published = false, operational=false, onOperationalChanged, notify, fail }: Props) {
  const supabase=useMemo(()=>createSupabaseBrowserClient(),[]);
  const [diagnostics,setDiagnostics]=useState<SolverCandidateDiagnostics|null>(null);
  const [diagnosticsLoading,setDiagnosticsLoading]=useState(false);
  const [selectedEmployee,setSelectedEmployee]=useState("");
  const [notifyEmployee,setNotifyEmployee]=useState(true);
  const shiftsByDate = new Map<string, typeof workspace.shifts>();
  for (const shift of workspace.shifts) {
    shiftsByDate.set(shift.date, [...(shiftsByDate.get(shift.date) ?? []), shift]);
  }
  const dates = [...shiftsByDate.entries()].sort(([left], [right]) => left.localeCompare(right));
  const assignmentCount = workspace.variants.reduce((sum, variant) => sum + variant.assignmentCount, 0);
  const unfilledCount = workspace.variants.reduce((sum, variant) => sum + variant.unfilledCount, 0);
  const publishedAt = timestampLabel(workspace.context.publishedAt, timezone);
  const activeDiagnosticIssue=diagnostics?workspace.issues.find(issue=>issue.id===diagnostics.issue.id)??null:null;

  async function inspectIssue(issueId:string){
    if(!supabase||!workspace.context.scheduleId)return;
    setDiagnosticsLoading(true);setDiagnostics(null);setSelectedEmployee("");
    try{setDiagnostics(await getCandidateDiagnostics(supabase,workspace.context.scheduleId,issueId));}
    catch(error){fail?.(solverErrorMessage(error instanceof Error?error.message:String(error)));}
    finally{setDiagnosticsLoading(false);}
  }
  async function assign(candidate:SolverCandidateDiagnostic){
    if(!supabase||!diagnostics||candidate.classification==="BLOCKED")return;
    let reason="";
    if(candidate.classification==="WARNING"){
      reason=window.prompt(`Awaryjne dopisanie naruszy regułę miękką:\n${candidate.softReasons.map(reasonLabel).join("\n")}\n\nPodaj powód decyzji:`)?.trim()??"";
      if(reason.length<3)return;
    }
    if(!window.confirm(`Dopisać ${candidate.name} do tego nieobsadzonego miejsca?`))return;
    setDiagnosticsLoading(true);
    try{
      await emergencyAssignV2(supabase,{scheduleId:diagnostics.scheduleId,issueId:diagnostics.issue.id,employeeId:candidate.employeeId,allowSoft:candidate.classification==="WARNING",reason,notify:notifyEmployee});
      notify?.(notifyEmployee?"Pracownik został dopisany i powiadomiony.":"Pracownik został dopisany do grafiku operacyjnego.");
      setDiagnostics(null);setSelectedEmployee("");await onOperationalChanged?.();
    }catch(error){fail?.(solverErrorMessage(error instanceof Error?error.message:String(error)));}
    finally{setDiagnosticsLoading(false);}
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

    {workspace.finance && <div className="solver-workspace-finance">
      <div><CircleDollarSign/><span><small>Koszt podstawowy</small><strong>{money(workspace.finance.baseCostMinor, workspace.finance.currency)}</strong></span></div>
      <div><span><small>Dodatki z Matrixa</small><strong>{money(workspace.finance.additionsCostMinor, workspace.finance.currency)}</strong></span></div>
      <div><span><small>Łączny koszt</small><strong>{money(workspace.finance.totalCostMinor, workspace.finance.currency)}</strong></span></div>
      <div><span><small>Budżet scenariusza</small><strong>{money(workspace.finance.budgetMinor, workspace.finance.currency)}</strong></span></div>
    </div>}

    <div className="solver-workspace-calendar">
      <h4>Obsada według dni</h4>
      {dates.length === 0 && <div className="solver-workspace-empty">Ten wariant nie zawiera jeszcze zmian do pokazania.</div>}
      {dates.map(([date, shifts], dateIndex) => {
        const people = shifts.reduce((sum, shift) => sum + shift.assignments.length, 0);
        return <details key={date} open={dateIndex === 0}>
          <summary>
            <span><CalendarDays/><strong>{dateLabel(date)}</strong></span>
            <small>{shifts.length} {shifts.length === 1 ? "zmiana" : "zmian"} • {people} przydziałów</small>
          </summary>
          <div className="solver-workspace-shifts">
            {shifts.map(shift => <article key={`${shift.slotGroupKey}:${shift.location.id}:${shift.shiftTemplate.id}`}>
              <header>
                <span><MapPin/><strong>{shift.location.name}</strong></span>
                <span>{timeLabel(shift.startsAt,shift.location.timezone ?? timezone)}–{timeLabel(shift.endsAt,shift.location.timezone ?? timezone)}</span>
              </header>
              <h5>{shift.shiftTemplate.name}</h5>
              {shift.assignments.length === 0
                ? <p className="solver-workspace-empty">Brak przydzielonych osób</p>
                : <div className="solver-workspace-people">
                  {shift.assignments.map(assignment => <div key={assignment.id}>
                    <span>
                      <strong>{[assignment.employee.firstName, assignment.employee.lastName].filter(Boolean).join(" ") || "Pracownik"}</strong>
                      <small>{assignment.role.name}</small>
                    </span>
                    <em>{assignment.duties.length
                      ? assignment.duties.map(duty => duty.name).join(", ")
                      : "Bez dodatkowych obowiązków"}</em>
                  </div>)}
                </div>}
            </article>)}
          </div>
        </details>;
      })}
    </div>

    <details className="solver-workspace-issues" open={workspace.issues.length > 0 && workspace.issues.length <= 8}>
      <summary>
        <span><AlertTriangle/><strong>Braki i uwagi</strong></span>
        <small>{workspace.issues.length}</small>
      </summary>
      {workspace.issues.length === 0
        ? <p>Nie zgłoszono braków ani uwag do tego wariantu.</p>
        : <div>
          {workspace.issues.map(issue => <WorkspaceIssueCard key={issue.id} issue={issue} timezone={timezone} operational={operational} published={published} busy={diagnosticsLoading} inspect={id=>void inspectIssue(id)}/>)}
        </div>}
    </details>
    {diagnostics&&<><button className="drawer-scrim top" onClick={()=>setDiagnostics(null)}/><aside className="drawer role-drawer top candidate-diagnostics-drawer">
      <div className="drawer-head"><div><p className="eyebrow">GRAFIK OPERACYJNY • DIAGNOSTYKA BRAKU</p><h2>{diagnostics.shift.date} • {timeLabel(diagnostics.shift.startsAt,activeDiagnosticIssue?.shift?.location.timezone??timezone)}–{timeLabel(diagnostics.shift.endsAt,activeDiagnosticIssue?.shift?.location.timezone??timezone)}</h2><small>{[activeDiagnosticIssue?.shift?.location.name,activeDiagnosticIssue?.role?.name,activeDiagnosticIssue?.duty?.name].filter(Boolean).join(" • ")||diagnostics.issue.message}</small></div><button className="icon-button" onClick={()=>setDiagnostics(null)}><X/></button></div>
      <div className="drawer-content">
        <div className="candidate-diagnostics-summary"><span><b>{diagnostics.summary.considered}</b><small>rozważonych</small></span><span><b>{diagnostics.summary.eligible}</b><small>można przypisać</small></span><span><b>{diagnostics.summary.warning}</b><small>awaryjnie</small></span><span><b>{diagnostics.summary.blocked}</b><small>blokada twarda</small></span></div>
        <p>Każdy pracownik ma wyjaśnienie decyzji solvera oraz aktualne obciążenie przed dopisaniem.</p>
        <div className="candidate-diagnostics-list">{diagnostics.candidates.map(candidate=><article className={candidate.classification.toLowerCase()} key={candidate.employeeId}>
          <header><span><strong>{candidate.name}</strong><small>{candidate.employeeNo}</small></span><em>{candidate.classification==="ELIGIBLE"?"MOŻNA PRZYPISAĆ":candidate.classification==="WARNING"?"MOŻNA AWARYJNIE":"BLOKADA TWARDA"}</em></header>
          <dl><div><dt>Zmiany w miesiącu</dt><dd>{candidate.monthlyShifts}</dd></div><div><dt>Godziny miesiąca</dt><dd>{Math.round(candidate.monthlyMinutes/60)} / {Math.round(candidate.nominalMonthlyMinutes/60)} nominał • limit {Math.round(candidate.maximumMonthlyMinutes/60)}</dd></div><div><dt>Godziny tygodnia</dt><dd>{Math.round(candidate.weeklyMinutes/60)} / {Math.round(candidate.maximumWeeklyMinutes/60)}</dd></div><div><dt>Kolejne dni po dopisaniu</dt><dd>{candidate.projectedConsecutiveDays} / limit {candidate.maximumConsecutiveDays} ({candidate.consecutiveDaysBefore} przed • {candidate.consecutiveDaysAfter} po)</dd></div><div><dt>Poprzednia zmiana</dt><dd>{candidate.previousShift?`${candidate.previousShift.date} • ${timeLabel(candidate.previousShift.startsAt,timezone)}–${timeLabel(candidate.previousShift.endsAt,timezone)}`:"brak"}</dd></div><div><dt>Następna zmiana</dt><dd>{candidate.nextShift?`${candidate.nextShift.date} • ${timeLabel(candidate.nextShift.startsAt,timezone)}–${timeLabel(candidate.nextShift.endsAt,timezone)}`:"brak"}</dd></div><div><dt>Dostępność</dt><dd>{candidate.declaredUnavailable?"zgłoszona niedostępność":candidate.outsideAvailableWindow?"poza oknem dostępności":"zgodna z deklaracją"}</dd></div><div><dt>Sąsiednie dni</dt><dd>{candidate.worksPreviousDay?"pracuje dzień wcześniej":"wolne dzień wcześniej"} • {candidate.worksNextDay?"pracuje dzień później":"wolne dzień później"}</dd></div><div><dt>Preferencja</dt><dd>{preferenceLevelLabel(candidate.preferenceLevel)}</dd></div></dl>
          {[...candidate.hardReasons,...candidate.softReasons].length>0?<ul>{candidate.hardReasons.map(reason=><li key={reason}><ShieldCheck/> {reasonLabel(reason)}</li>)}{candidate.softReasons.map(reason=><li key={reason}><AlertTriangle/> {reasonLabel(reason)}</li>)}</ul>:<p className="candidate-ok"><Check/> Brak konfliktów i naruszeń.</p>}
          <button className={candidate.classification==="WARNING"?"danger-button":"primary-button"} disabled={diagnosticsLoading||candidate.classification==="BLOCKED"} onClick={()=>{setSelectedEmployee(candidate.employeeId);void assign(candidate);}}>{diagnosticsLoading&&selectedEmployee===candidate.employeeId?<RefreshCw className="spin"/>:<Plus/>} {candidate.classification==="WARNING"?"Dopisz awaryjnie":"Dopisz pracownika"}</button>
        </article>)}</div>
        <label className="check-label"><input type="checkbox" checked={notifyEmployee} onChange={event=>setNotifyEmployee(event.target.checked)}/> Powiadom pracownika po skutecznym zapisie</label>
      </div>
    </aside></>}
  </section>;
}
