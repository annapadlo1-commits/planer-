"use client";

import { AlertTriangle, CalendarDays, Check, CircleDollarSign, MapPin, Plus, RefreshCw, ShieldCheck, Users, X } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { emergencyAssignV2, getCandidateDiagnostics, getManagerStandbyMonth, getVariantIssueDiagnostics, solverErrorMessage, type SolverCandidateDiagnostic, type SolverCandidateDiagnostics, type SolverManagerStandby, type SolverVariantIssueDiagnostics, type SolverWorkspace, type SolverWorkspaceIssue } from "@/lib/solver-v2";

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

const hardReasonLabels:Record<string,string>={ROLE_REQUIRED:"Brak wymaganej roli",LOCATION_NOT_ALLOWED:"Lokal nie jest dozwolony w zwykłym limicie",LOCATION_REQUIRED:"Lokal nie jest dozwolony w zwykłym limicie",DUTY_REQUIRED:"Brak wymaganej kompetencji",SHIFT_OVERLAP:"Nakładająca się zmiana",OVERLAPPING_SHIFT:"Nakładająca się zmiana",ONE_PRIMARY_SHIFT_PER_DAY:"Pracownik ma już inną zmianę tego dnia",CONSECUTIVE_SHIFT_SEQUENCE:"To byłaby ostatnia zmiana dnia, a następnego dnia pierwsza — albo pierwsza po ostatniej zmianie poprzedniego dnia",STANDBY_TIER_1_RESERVED:"Pracownik jest tego dnia opublikowany jako pierwszy rezerwowy",STANDBY_TIER_2_RESERVED:"Pracownik jest tego dnia opublikowany jako drugi rezerwowy",DECLARED_UNAVAILABLE:"Pracownik zgłosił twardą niedostępność, urlop albo L4",TIME_CONSTRAINT:"Niedostępność, urlop lub L4",OUTSIDE_AVAILABILITY_WINDOW:"Zmiana poza zadeklarowanym oknem dostępności",MISSING_AVAILABILITY:"Brak deklaracji dostępności, gdy konfiguracja firmy jawnie jej wymaga",OUTSIDE_EMPLOYMENT:"Data poza okresem współpracy",WEEKEND_BLOCKED:"Pracownik ma zablokowane weekendy",REST_AFTER_PREVIOUS_SHIFT:"Za krótki odpoczynek po poprzedniej zmianie",REST_BEFORE_NEXT_SHIFT:"Za krótki odpoczynek przed następną zmianą",MINIMUM_REST:"Za krótki odpoczynek",MONTHLY_LIMIT:"Przekroczony indywidualny limit miesięczny",WEEKLY_LIMIT:"Przekroczony indywidualny limit tygodniowy",MAX_CONSECUTIVE_DAYS:"Przekroczona maksymalna liczba kolejnych dni pracy",MANAGER_SHIFT_BLOCK:"Pracodawca zablokował tę zmianę w konfiguracji firmy"};
const softReasonLabels:Record<string,string>={SHIFT_PREFERENCE_AVOIDED:"Pracownik prosi, aby unikać tej pory",SHIFT_AVOIDED:"Pracownik prosi, aby unikać tej pory",OVERTIME_AFTER_ASSIGNMENT:"Po dopisaniu przekroczy nominał miesięczny",MONTHLY_OVERTIME:"Po dopisaniu przekroczy nominał miesięczny"};
function reasonLabel(value:string){return hardReasonLabels[value]??softReasonLabels[value]??value;}
function preferenceLevelLabel(value:string){
  return ({PREFERRED:"preferowana",NEUTRAL:"neutralna",AVOIDED:"unikać",BLOCKED:"zablokowana"} as Record<string,string>)[value]??value;
}

function WorkspaceIssueCard({issue,timezone,operational,published,busy,inspect,explainPreview,previewAvailable}:{issue:SolverWorkspaceIssue;timezone:string;operational:boolean;published:boolean;busy:boolean;inspect:(id:string)=>void;explainPreview:(id:string)=>void;previewAvailable:boolean}){
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
  </article>;
}

export function SolverV2Workspace({ workspace, timezone, published = false, operational=false, onOperationalChanged, notify, fail }: Props) {
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
    if(!window.confirm(`Dopisać ${candidate.name} do tego nieobsadzonego miejsca?`))return;
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
      if(!window.confirm(`Dopisać ${candidate.employeeName} do grafiku operacyjnego? Wariant źródłowy pozostanie bez zmian w historii.`))return;
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
          {workspace.issues.map(issue => <WorkspaceIssueCard key={issue.id} issue={issue} timezone={timezone} operational={operational} published={published} busy={diagnosticsLoading||variantDiagnosticsLoading} inspect={id=>void inspectIssue(id)} explainPreview={id=>void inspectVariantIssue(id)} previewAvailable={Boolean(workspace.variants[0]?.id)}/>)}
        </div>}
    </details>

    {workspace.finance && <div className="solver-workspace-finance">
      <div><CircleDollarSign/><span><small>Koszt podstawowy</small><strong>{money(workspace.finance.baseCostMinor, workspace.finance.currency)}</strong></span></div>
      <div><span><small>Dodatki płacowe</small><strong>{money(workspace.finance.additionsCostMinor, workspace.finance.currency)}</strong></span></div>
      <div><span><small>Łączny koszt</small><strong>{money(workspace.finance.totalCostMinor, workspace.finance.currency)}</strong></span></div>
      <div><span><small>Budżet scenariusza</small><strong>{money(workspace.finance.budgetMinor, workspace.finance.currency)}</strong></span></div>
    </div>}

    {published && <details className="solver-workspace-standby" open>
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

    {variantDiagnostics&&<><button className="drawer-scrim top" onClick={()=>setVariantDiagnostics(null)}/><aside className="drawer role-drawer top candidate-diagnostics-drawer">
      <div className="drawer-head"><div><p className="eyebrow">WARIANT • WYJAŚNIENIE BRAKU</p><h2>{variantDiagnostics.shift.date} • {timeLabel(variantDiagnostics.shift.startsAt,timezone)}–{timeLabel(variantDiagnostics.shift.endsAt,timezone)}</h2><small>Powody są liczone dla pracowników dostępnych w opublikowanej konfiguracji firmy i aktualnego składu tego wariantu.</small></div><button className="icon-button" onClick={()=>setVariantDiagnostics(null)}><X/></button></div>
      <div className="drawer-content">
        <div className="candidate-diagnostics-summary"><span><b>{variantDiagnostics.summary.considered}</b><small>sprawdzonych osób</small></span><span><b>{variantDiagnostics.summary.eligible}</b><small>bez blokady</small></span><span><b>{variantDiagnostics.summary.blocked}</b><small>z blokadą</small></span></div>
        {variantDiagnostics.decisionContext&&<div className="solver-v2-notice warning"><AlertTriangle/><span><strong>Dlaczego powstał ten brak</strong><small>{variantDiagnostics.decisionContext.message} Ten błąd poprzedniej wersji silnika został naprawiony: rezerwa nie może już zmniejszać wymaganej obsady.</small></span></div>}
        {variantDiagnostics.summary.eligible>0&&!variantDiagnostics.decisionContext&&<div className="solver-v2-notice warning"><AlertTriangle/><span><strong>{variantDiagnostics.summary.eligible} osób nie ma indywidualnej twardej blokady</strong><small>{variantDiagnostics.publishedScheduleId?"To nie gwarantuje, że dopisanie zachowa poprawność całego miesiąca. Przycisk wykona ponowną kontrolę globalną przed zapisem.":"Silnik mógł wykorzystać te osoby w innym miejscu. Ręczna korekta jest dostępna dopiero w opublikowanym grafiku operacyjnym."}</small></span></div>}
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
