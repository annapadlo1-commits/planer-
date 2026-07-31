"use client";

import {
  AlertTriangle, BarChart3, Bell, CalendarDays, Check, ChevronRight,
  CircleDollarSign, Clock3, Download, Filter, Gauge, LogOut, MapPin,
  Menu, Plus, RefreshCw, Settings, Users, WandSparkles, Wifi, X, Boxes, Puzzle,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { useAppAuth } from "@/components/AppAuthProvider";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import {CompleteModules,type CompleteWorkspace} from "@/components/CompleteModules";

type Plan = {
  id: string; month: string; name: string; scenario_code: string;
  optimization_mode: string; staffing_level: string; status: string;
  version: number; score: number; total_cost: number;
};
type Assignment = {
  id: string; shift_id: string; employee_id: string; employee_no: string;
  name: string; role: string; capability?: string; location: string; date: string;
  shift_code: string; starts_at: string; ends_at: string; cost: number;
  monthly_minutes: number; nominal_minutes: number;
};
type Shift = {
  id: string; shift_date: string; shift_code: string; starts_at: string;
  ends_at: string; location_code: string; assignment_count: number;
};
type Issue = {
  id: string; shift_id?: string; issue_type: string; severity: string;
  role?: string; capability?: string; required_count?: number;
  assigned_count?: number; message: string;
};
type EventRow = {
  id: string; title: string; event_type: string; status: string;
  starts_at: string; ends_at: string; location: string; expected_guests?: number;
};
type Candidate = {
  id:string; employee_no:string; name:string; role:string; hourly_rate:number;
  can_close:boolean; eligible:boolean; overtime_only:boolean;
};
type Workspace = {
  plan: Plan | null; assignments: Assignment[]; shifts: Shift[];
  issues: Issue[]; events: EventRow[];
  budget: { amount: number; warning_percent: number; hard_limit: boolean };
};
type MatrixItem = { id:string; code:string; name:string; color?:string; active?:boolean; starts_at?:string; ends_at?:string; location_id?:string };
type RoleSection = { id:string; role_id:string; role_code:string; role_name:string; version:number; status:string; name:string; updated_at:string };
type MatrixWorkspace = { version:{id:string;version:number;name:string;status:string;settings:{minimumRestMinutes:number;maxShiftsPerDay:number}}|null; roles:MatrixItem[]; locations:MatrixItem[]; functions:MatrixItem[]; shifts:MatrixItem[]; demand:unknown[]; sections:RoleSection[]; conflicts:{id:string;severity:string;conflict_type:string;message:string}[] };
type NavKey = "centrum"|"generator"|"zespoly"|"matrix"|"grafik"|"kalendarz"|"kadra"|"hr"|"finanse"|"portal"|"czas"|"integracje"|"alerty"|"budzet";
type Modal = "plan"|"event"|"shift"|"employee"|null;

const MONTH = "2026-07-01";
const roles = ["KELNER","BARMAN","PIZZABAR","PREP","POMOC"];
const roleLabels: Record<string,string> = {
  KELNER:"Kelner",BARMAN:"Barman",PIZZABAR:"Pizzabar",PREP:"Prep",POMOC:"Pomoc"
};
const planStatusLabels:Record<string,string>={DRAFT:"Wersja robocza",GENERATING:"Generowanie",READY:"Gotowy do weryfikacji",PUBLISHED:"Opublikowany",STALE:"Nieaktualny",ARCHIVED:"Archiwalny",FAILED:"Błąd"};
const scenarioLabels:Record<string,string>={BASE:"Bazowy",EVENT:"Eventowy",SAVINGS:"Oszczędny",MERGED:"Scalony z grafików ról"};
const modeLabels:Record<string,string>={BALANCED:"Zrównoważony",MIN_COST:"Minimalny koszt",PREFERENCES:"Preferencje",ROLE_PLANS:"Grafiki ról"};
const issueLabels:Record<string,string>={SHORTAGE:"Brak obsady",CAPABILITY_MISSING:"Brak wymaganej funkcji",REST_VIOLATION:"Naruszenie odpoczynku",OVERLAP:"Nakładające się zmiany",MONTHLY_LIMIT:"Przekroczony limit miesięczny",WEEKLY_LIMIT:"Przekroczony limit tygodniowy"};
function issueMessage(i:Issue){if(i.issue_type==="SHORTAGE")return `Brakuje ${Math.max((i.required_count||0)-(i.assigned_count||0),0)} os. dla roli ${roleLabels[i.role||""]||i.role||""}.`;if(i.issue_type==="CAPABILITY_MISSING")return `Brakuje wymaganej funkcji: ${i.capability||"nieokreślona"}.`;return i.message.replaceAll("PIZZABAR","Pizzabar").replaceAll("KELNER","Kelner").replaceAll("BARMAN","Barman").replaceAll("POMOC","Pomoc");}
const nav = [
  ["centrum","Centrum dowodzenia",Gauge],["generator","Generator grafiku",WandSparkles],
  ["zespoly","Grafiki zespołów",Puzzle],["matrix","Matrix organizacji",Boxes],
  ["grafik","Grafik operacyjny",CalendarDays],["kalendarz","Kalendarz miesiąca",CalendarDays],
  ["kadra","Pracownicy i archiwum",Users],["hr","Kadry i HR",Users],
  ["finanse","Finanse chronione",CircleDollarSign],["portal","Portal pracownika",Users],
  ["czas","Ewidencja czasu",Clock3],["integracje","Kadromierz",Download],
  ["alerty","Braki i alerty",AlertTriangle],["budzet","Koszt planu",CircleDollarSign],
] as const;

function fmtTime(value:string) {
  return new Intl.DateTimeFormat("pl-PL",{hour:"2-digit",minute:"2-digit",timeZone:"Europe/Warsaw"}).format(new Date(value));
}
function fmtDate(value:string) {
  return new Intl.DateTimeFormat("pl-PL",{day:"2-digit",month:"short",timeZone:"Europe/Warsaw"}).format(new Date(value+"T12:00:00"));
}
function csvCell(value:unknown) { return `"${String(value??"").replaceAll('"','""')}"`; }
function downloadCsv(name:string, rows:unknown[][]) {
  const blob=new Blob(["\ufeff"+rows.map(r=>r.map(csvCell).join(";")).join("\n")],{type:"text/csv;charset=utf-8"});
  const a=document.createElement("a"); a.href=URL.createObjectURL(blob); a.download=name; a.click(); URL.revokeObjectURL(a.href);
}

export default function GrafikPro() {
  const { user, access, connected, summary, refresh, signOut }=useAppAuth();
  const supabase=useMemo(()=>createSupabaseBrowserClient(),[]);
  const [data,setData]=useState<Workspace>({
    plan:null,assignments:[],shifts:[],issues:[],events:[],
    budget:{amount:0,warning_percent:90,hard_limit:false}
  });
  const [matrix,setMatrix]=useState<MatrixWorkspace>({version:null,roles:[],locations:[],functions:[],shifts:[],demand:[],sections:[],conflicts:[]});
  const [complete,setComplete]=useState<CompleteWorkspace|null>(null);
  const [loading,setLoading]=useState(true);
  const [busy,setBusy]=useState(false);
  const [error,setError]=useState("");
  const [toast,setToast]=useState("");
  const [active,setActive]=useState<NavKey>("centrum");
  const [modal,setModal]=useState<Modal>(null);
  const [selectedShift,setSelectedShift]=useState<Shift|null>(null);
  const [selectedEmployee,setSelectedEmployee]=useState("");
  const [candidateRole,setCandidateRole]=useState("BARMAN");
  const [candidates,setCandidates]=useState<Candidate[]>([]);
  const [candidateId,setCandidateId]=useState("");
  const [notifyEmployee,setNotifyEmployee]=useState(true);
  const [location,setLocation]=useState("ALL");
  const [role,setRole]=useState("ALL");
  const [day,setDay]=useState("ALL");
  const [planForm,setPlanForm]=useState({name:"Plan operacyjny 2026-07",scenario:"BASE",mode:"BALANCED",staffing:"OPTIMAL"});
  const [eventForm,setEventForm]=useState({
    location:"KRUCZA",type:"EVENT",title:"",description:"",date:"2026-07-15",
    start:"18:00",end:"02:00",guests:"",status:"CONFIRMED",kelner:"0",barman:"0",pizzabar:"0",prep:"0",pomoc:"0"
  });

  const notify=(message:string)=>{setToast(message);window.setTimeout(()=>setToast(""),3200);};
  const load=useCallback(async()=>{
    if(!supabase||!user)return;
    setLoading(true);setError("");
    const [result,matrixResult,completeResult]=await Promise.all([
      supabase.rpc("plan_workspace",{p_month:MONTH,p_plan_id:null}),
      supabase.rpc("matrix_workspace",{p_month:MONTH}),
      supabase.rpc("complete_workspace",{p_month:MONTH})
    ]);
    if(result.error)setError(result.error.message);
    else setData((result.data||{
      plan:null,assignments:[],shifts:[],issues:[],events:[],
      budget:{amount:0,warning_percent:90,hard_limit:false}
    }) as Workspace);
    if(!matrixResult.error&&matrixResult.data)setMatrix(matrixResult.data as MatrixWorkspace);
    if(!completeResult.error&&completeResult.data)setComplete(completeResult.data as CompleteWorkspace);
    if(completeResult.error&&completeResult.error.message!=="Could not find the function public.complete_workspace")setError(completeResult.error.message);
    setLoading(false);
  },[supabase,user]);
  useEffect(()=>{void load();},[load]);

  const assignments=useMemo(()=>data.assignments.filter(a=>
    (location==="ALL"||a.location===location)&&(role==="ALL"||a.role===role)&&
    (day==="ALL"||a.date===day)&&(selectedEmployee===""||a.employee_id===selectedEmployee)
  ),[data.assignments,location,role,day,selectedEmployee]);
  const employees=useMemo(()=>{
    const map=new Map<string,{id:string;no:string;name:string;role:string;minutes:number;nominal:number;cost:number;shifts:number}>();
    for(const a of data.assignments){
      const x=map.get(a.employee_id)||{id:a.employee_id,no:a.employee_no,name:a.name,role:a.role,minutes:a.monthly_minutes,nominal:a.nominal_minutes,cost:0,shifts:0};
      x.cost+=Number(a.cost);x.shifts++;map.set(a.employee_id,x);
    }
    return [...map.values()].sort((a,b)=>b.minutes/Math.max(b.nominal,1)-a.minutes/Math.max(a.nominal,1));
  },[data.assignments]);
  const shiftAssignments=selectedShift?data.assignments.filter(a=>a.shift_id===selectedShift.id):[];
  const totalMinutes=data.assignments.reduce((n,a)=>n+(new Date(a.ends_at).getTime()-new Date(a.starts_at).getTime())/60000,0);
  const cost=Number(data.plan?.total_cost||0);
  const budget=Number(data.budget?.amount||0);
  const coverage=data.shifts.length?Math.round(100*(1-Math.min(data.issues.filter(i=>i.issue_type==="SHORTAGE"||i.issue_type==="CAPABILITY_MISSING").length/data.shifts.length,1))):0;

  async function generate() {
    if(!supabase)return;setBusy(true);setError("");
    const result=await supabase.rpc("generate_plan",{
      p_month:MONTH,p_name:planForm.name,p_scenario_code:planForm.scenario,
      p_optimization_mode:planForm.mode,p_staffing_level:planForm.staffing
    });
    setBusy(false);
    if(result.error){setError(result.error.message);return;}
    setModal(null);notify(`Plan zapisany: ${result.data.assignments} przydziałów, ${result.data.issues} alertów`);
    await load();setActive("grafik");
  }
  async function publish() {
    if(!supabase||!data.plan)return;setBusy(true);
    const result=await supabase.rpc("publish_plan",{p_plan_id:data.plan.id});setBusy(false);
    if(result.error)setError(result.error.message);else{notify("Grafik został opublikowany");await load();}
  }
  async function createEvent() {
    if(!supabase)return;setBusy(true);setError("");
    const endDate=eventForm.end<=eventForm.start?
      new Date(new Date(`${eventForm.date}T12:00:00`).getTime()+86400000).toISOString().slice(0,10):eventForm.date;
    const demand=roles.map(r=>({
      role:r,shift_code:"WIECZOR",
      additional_count:Number(eventForm[r.toLowerCase() as keyof typeof eventForm]||0)
    })).filter(x=>x.additional_count>0);
    const result=await supabase.rpc("create_operational_event",{
      p_location:eventForm.location,p_event_type:eventForm.type,p_title:eventForm.title,
      p_description:eventForm.description,p_starts_at:`${eventForm.date}T${eventForm.start}:00+02:00`,
      p_ends_at:`${endDate}T${eventForm.end}:00+02:00`,
      p_expected_guests:eventForm.guests?Number(eventForm.guests):null,p_status:eventForm.status,p_demand:demand
    });
    setBusy(false);
    if(result.error)setError(result.error.message);else{
      setModal(null);notify("Event zapisany. Gotowe plany oznaczono jako nieaktualne.");await load();
    }
  }
  async function findCandidates() {
    if(!supabase||!selectedShift)return;
    setBusy(true);setError("");
    const result=await supabase.rpc("shift_candidates",{
      p_shift_id:selectedShift.id,p_role:candidateRole
    });
    setBusy(false);
    if(result.error){setError(result.error.message);return;}
    const rows=(result.data||[]) as Candidate[];
    setCandidates(rows);setCandidateId(rows.find(x=>x.eligible)?.id||"");
  }
  async function emergencyAssign() {
    if(!supabase||!selectedShift||!candidateId)return;
    setBusy(true);setError("");
    const result=await supabase.rpc("emergency_assign",{
      p_shift_id:selectedShift.id,p_employee_id:candidateId,
      p_role:candidateRole,p_notify:notifyEmployee
    });
    setBusy(false);
    if(result.error){setError(result.error.message);return;}
    notify(result.data.notified?"Pracownik dodany i powiadomiony":"Pracownik dodany awaryjnie");
    setCandidates([]);setCandidateId("");await load();
  }

  return <main className="app-shell">
    <aside className="sidebar">
      <div className="brand"><span>GP</span><div><strong>GRAFIK PRO</strong><small>3.0 • ALPHA 12</small></div></div>
      <nav>{nav.map(([key,label,Icon])=><button key={key} className={active===key?"active":""} onClick={()=>setActive(key)}><Icon size={18}/>{label}</button>)}</nav>
      <div className="sidebar-footer">
        <div className="profile"><span>{(user?.email||"GP").slice(0,2).toUpperCase()}</span><div><strong>{access?.employee?`${access.employee.first_name} ${access.employee.last_name}`:user?.email}</strong><small>{({OWNER:"Właściciel",ADMIN:"Administrator",HR_FINANCE:"Kadry i finanse",ROLE_MANAGER:"Menadżer roli",LOCATION_MANAGER:"Menadżer lokalu",VERIFIER:"Weryfikator",EMPLOYEE:"Pracownik"} as Record<string,string>)[access?.roles?.[0]?.app_role||""]||"Użytkownik"}</small></div></div>
        <button className="sidebar-signout" onClick={()=>void signOut()}><LogOut size={15}/> Wyloguj się</button>
      </div>
    </aside>
    <section className="workspace">
      <header className="topbar">
        <button className="icon-button menu-button"><Menu size={20}/></button>
        <div><p className="eyebrow">OPERACJE / LIPIEC 2026</p><h1>{nav.find(x=>x[0]===active)?.[1]}</h1></div>
        <div className="topbar-actions">
          <button className={`live-status ${connected?"online":""}`} onClick={()=>{void refresh();void load();}}><Wifi size={15}/><span>Supabase • {summary?.employees||0} osób</span></button>
          <button className="date-selector"><CalendarDays size={16}/> lipiec 2026</button>
          <button className="secondary-button" onClick={()=>setModal("event")}><Plus size={16}/> Event</button>
          <button className="primary-button" onClick={()=>setModal("plan")}><WandSparkles size={17}/> Nowy wariant</button>
        </div>
      </header>
      {error&&<div className="engine-error"><AlertTriangle size={18}/><span><strong>Operacja nie powiodła się</strong>{error}</span><button onClick={()=>setError("")}>×</button></div>}
      {loading?<div className="engine-loading"><RefreshCw className="spin"/><strong>Pobieram rzeczywisty grafik…</strong></div>:
      <div className="content">
        {active==="centrum"&&<>
          <section className="kpi-grid">
            <button className="kpi-card" onClick={()=>setActive("grafik")}><span className="kpi-icon violet"><Users/></span><span><small>Obsada</small><strong>{data.plan?`${coverage}%`:"—"}</strong><em>{data.plan?`${data.assignments.length} przydziałów`:"Brak planu"}</em></span></button>
            <button className="kpi-card" onClick={()=>setActive("alerty")}><span className="kpi-icon coral"><AlertTriangle/></span><span><small>Otwarte alerty</small><strong>{data.issues.length}</strong><em>{data.issues.filter(i=>i.severity==="CRITICAL").length} krytycznych</em></span></button>
            <button className="kpi-card" onClick={()=>setActive("budzet")}><span className="kpi-icon teal"><CircleDollarSign/></span><span><small>Koszt / budżet</small><strong>{data.plan?`${Math.round(cost/budget*100)}%`:"—"}</strong><em>{cost.toLocaleString("pl-PL")} zł</em></span></button>
            <button className="kpi-card" onClick={()=>setActive("kalendarz")}><span className="kpi-icon orange"><CalendarDays/></span><span><small>Eventy</small><strong>{data.events.length}</strong><em>{data.events.filter(e=>e.status==="NEEDS_VERIFICATION").length} do weryfikacji</em></span></button>
          </section>
          {!data.plan?<section className="empty-engine"><WandSparkles size={36}/><h2>Baza jest gotowa do pierwszego rzeczywistego planu</h2><p>Generator utworzy zmiany i przydziały w Supabase, sprawdzi role, lokalizacje, kompetencje, limity i eventy.</p><button className="primary-button" onClick={()=>setModal("plan")}>Generuj plan</button></section>:
          <section className="live-overview">
            <div className="section-head"><div><p className="eyebrow">AKTYWNY WARIANT</p><h2>{data.plan.name} • v{data.plan.version}</h2></div><span className={`status-pill ${data.plan.status.toLowerCase()}`}>{planStatusLabels[data.plan.status]||data.plan.status}</span></div>
            <div className="overview-grid"><div><small>Scenariusz</small><strong>{scenarioLabels[data.plan.scenario_code]||data.plan.scenario_code}</strong></div><div><small>Optymalizacja</small><strong>{modeLabels[data.plan.optimization_mode]||data.plan.optimization_mode}</strong></div><div><small>Zmiany</small><strong>{data.shifts.length}</strong></div><div><small>Roboczogodziny</small><strong>{Math.round(totalMinutes/60)}</strong></div></div>
            <div className="quick-actions"><button onClick={()=>setActive("grafik")}>Otwórz grafik <ChevronRight/></button><button onClick={()=>setActive("kadra")}>Pracownicy i archiwum <ChevronRight/></button><button onClick={()=>setActive("alerty")}>Rozwiąż alerty <ChevronRight/></button>{data.plan.status!=="PUBLISHED"&&<button className="publish" onClick={()=>void publish()}>Opublikuj wariant <Check/></button>}</div>
          </section>}
        </>}
        {(active==="grafik"||active==="generator")&&<ScheduleView data={data} assignments={assignments} location={location} role={role} day={day} setLocation={setLocation} setRole={setRole} setDay={setDay} onShift={(s)=>{setSelectedShift(s);setModal("shift");}} onGenerate={()=>setModal("plan")}/>} 
        {active==="zespoly"&&complete&&<CompleteModules view="rolePlans" data={complete} reload={load} notify={notify} fail={setError}/>} 
        {active==="matrix"&&complete&&<CompleteModules view="matrixAdmin" data={complete} reload={load} notify={notify} fail={setError}/>} 
        {active==="kalendarz"&&<MonthView data={data} onDay={(d)=>{setDay(d);setActive("grafik");}} onEvent={()=>setModal("event")}/>}
        {active==="kadra"&&complete&&<CompleteModules view="kadra" data={complete} reload={load} notify={notify} fail={setError}/>} 
        {active==="hr"&&complete&&<CompleteModules view="hr" data={complete} reload={load} notify={notify} fail={setError}/>} 
        {active==="finanse"&&complete&&<CompleteModules view="finanse" data={complete} reload={load} notify={notify} fail={setError}/>} 
        {active==="portal"&&complete&&<CompleteModules view="portal" data={complete} reload={load} notify={notify} fail={setError}/>} 
        {active==="czas"&&complete&&<CompleteModules view="czas" data={complete} reload={load} notify={notify} fail={setError}/>} 
        {active==="integracje"&&complete&&<CompleteModules view="integracje" data={complete} reload={load} notify={notify} fail={setError}/>} 
        {active==="alerty"&&<IssuesView issues={data.issues} shifts={data.shifts} onOpen={(s)=>{setSelectedShift(s);setModal("shift");}}/>}
        {active==="budzet"&&<BudgetView cost={cost} budget={budget} assignments={data.assignments}/>}
      </div>}
    </section>
    {modal&&<><button className="drawer-scrim" onClick={()=>setModal(null)}/><aside className="drawer">
      <div className="drawer-head"><div><p className="eyebrow">GRAFIK PRO • OPERACJA</p><h2>{modal==="plan"?"Nowy wariant":modal==="event"?"Event / wyjątek":modal==="shift"?"Szczegóły zmiany":"Pracownik"}</h2></div><button className="icon-button" onClick={()=>setModal(null)}><X/></button></div>
      {modal==="plan"&&<div className="drawer-content">
        <label>Nazwa<input value={planForm.name} onChange={e=>setPlanForm({...planForm,name:e.target.value})}/></label>
        <label>Scenariusz<select value={planForm.scenario} onChange={e=>setPlanForm({...planForm,scenario:e.target.value})}><option value="BASE">Bazowy</option><option value="EVENT">Eventowy</option><option value="SAVINGS">Oszczędny</option></select></label>
        <label>Tryb optymalizacji<select value={planForm.mode} onChange={e=>setPlanForm({...planForm,mode:e.target.value})}><option value="BALANCED">Zrównoważony</option><option value="MIN_COST">Minimalny koszt</option><option value="PREFERENCES">Preferencje</option></select></label>
        <label>Poziom obsady<select value={planForm.staffing} onChange={e=>setPlanForm({...planForm,staffing:e.target.value})}><option value="MINIMAL">Minimalny (85%)</option><option value="OPTIMAL">Optymalny (100%)</option><option value="FULL">Pełny (110%)</option></select></label>
        <div className="impact-box"><Settings/><span><strong>Silnik transakcyjny</strong><small>Role • lokalizacje • limity • kompetencje • eventy • koszty</small></span></div>
        <button disabled={busy} className="primary-button full" onClick={()=>void generate()}>{busy?"Generuję w Supabase…":"Generuj i zapisz wariant"}</button>
      </div>}
      {modal==="event"&&<div className="drawer-content">
        <div className="form-row"><label>Lokal<select value={eventForm.location} onChange={e=>setEventForm({...eventForm,location:e.target.value})}><option>KRUCZA</option><option>PAWILONY</option></select></label><label>Typ<select value={eventForm.type} onChange={e=>setEventForm({...eventForm,type:e.target.value})}><option>EVENT</option><option>CLEANING</option><option>INVENTORY</option><option>TRAINING</option><option>ADDITIONAL_SHIFT</option><option>CLOSURE</option></select></label></div>
        <label>Nazwa<input value={eventForm.title} onChange={e=>setEventForm({...eventForm,title:e.target.value})} placeholder="np. Event firmowy"/></label>
        <label>Opis<textarea value={eventForm.description} onChange={e=>setEventForm({...eventForm,description:e.target.value})}/></label>
        <div className="form-row"><label>Data<input type="date" value={eventForm.date} onChange={e=>setEventForm({...eventForm,date:e.target.value})}/></label><label>Od<input type="time" value={eventForm.start} onChange={e=>setEventForm({...eventForm,start:e.target.value})}/></label><label>Do<input type="time" value={eventForm.end} onChange={e=>setEventForm({...eventForm,end:e.target.value})}/></label></div>
        <div className="form-row"><label>Goście<input type="number" value={eventForm.guests} onChange={e=>setEventForm({...eventForm,guests:e.target.value})}/></label><label>Status<select value={eventForm.status} onChange={e=>setEventForm({...eventForm,status:e.target.value})}><option value="DRAFT">Szkic</option><option value="NEEDS_VERIFICATION">Do weryfikacji</option><option value="CONFIRMED">Potwierdzony</option></select></label></div>
        <h3>Dodatkowa obsada wieczorna</h3><div className="demand-inputs">{roles.map(r=><label key={r}>{roleLabels[r]}<input type="number" min="0" value={eventForm[r.toLowerCase() as keyof typeof eventForm]} onChange={e=>setEventForm({...eventForm,[r.toLowerCase()]:e.target.value})}/></label>)}</div>
        <button disabled={busy||!eventForm.title} className="primary-button full" onClick={()=>void createEvent()}>{busy?"Zapisuję…":"Zapisz event i przelicz wpływ"}</button>
      </div>}
      {modal==="shift"&&selectedShift&&<div className="drawer-content">
        <div className="detail-status"><MapPin/><span><strong>{selectedShift.location_code} • {selectedShift.shift_code}</strong><small>{fmtDate(selectedShift.shift_date)} • {fmtTime(selectedShift.starts_at)}–{fmtTime(selectedShift.ends_at)}</small></span></div>
        <h3>Przydzieleni pracownicy ({shiftAssignments.length})</h3>
        {shiftAssignments.map(a=><div className="person-row" key={a.id}><span className="avatar violet">{a.name.split(" ").map(x=>x[0]).join("")}</span><span><strong>{a.name}</strong><small>{roleLabels[a.role]}{a.capability?` • ${a.capability}`:""}</small></span><em>{Number(a.cost).toFixed(0)} zł</em></div>)}
        {data.issues.filter(i=>i.shift_id===selectedShift.id).map(i=><div className={`issue-box ${i.severity.toLowerCase()}`} key={i.id}><AlertTriangle/><span><strong>{i.severity==="CRITICAL"?"Krytyczny":i.severity==="WARNING"?"Ostrzeżenie":"Informacja"}</strong>{issueMessage(i)}</span></div>)}
        <div className="emergency-panel">
          <h3>Awaryjnie dopisz pracownika</h3>
          <div className="form-row"><label>Rola<select value={candidateRole} onChange={e=>{setCandidateRole(e.target.value);setCandidates([]);setCandidateId("");}}>{roles.map(r=><option key={r}>{r}</option>)}</select></label><button disabled={busy} className="secondary-button candidate-search" onClick={()=>void findCandidates()}>{busy?"Szukam…":"Znajdź kandydatów"}</button></div>
          {candidates.length>0&&<>
            <label>Kandydat<select value={candidateId} onChange={e=>setCandidateId(e.target.value)}><option value="">Wybierz osobę</option>{candidates.map(c=><option key={c.id} value={c.id} disabled={!c.eligible}>{c.name} • {c.employee_no}{c.can_close?" • zamyka zmianę":""}{c.overtime_only?" • nadgodziny":""}{!c.eligible?" • konflikt":""}</option>)}</select></label>
            <label className="check-label"><input type="checkbox" checked={notifyEmployee} onChange={e=>setNotifyEmployee(e.target.checked)}/> Powiadom pracownika w aplikacji (jeśli ma konto)</label>
            <button disabled={busy||!candidateId} className="danger-button full" onClick={()=>void emergencyAssign()}><Plus size={16}/> Dopisz awaryjnie</button>
          </>}
        </div>
      </div>}
    </aside></>}
    {toast&&<div className="toast"><Check size={17}/>{toast}</div>}
  </main>;
}

function Filters({location,role,day,setLocation,setRole,setDay}:{location:string;role:string;day:string;setLocation:(x:string)=>void;setRole:(x:string)=>void;setDay:(x:string)=>void}) {
  return <div className="live-filters"><Filter size={16}/><select value={location} onChange={e=>setLocation(e.target.value)}><option value="ALL">Oba lokale</option><option>KRUCZA</option><option>PAWILONY</option></select><select value={role} onChange={e=>setRole(e.target.value)}><option value="ALL">Wszystkie role</option>{roles.map(r=><option key={r}>{r}</option>)}</select><input type="date" value={day==="ALL"?"":day} onChange={e=>setDay(e.target.value||"ALL")}/><button onClick={()=>{setLocation("ALL");setRole("ALL");setDay("ALL");}}>Wyczyść</button></div>;
}
function ScheduleView({data,assignments,location,role,day,setLocation,setRole,setDay,onShift,onGenerate}:{data:Workspace;assignments:Assignment[];location:string;role:string;day:string;setLocation:(x:string)=>void;setRole:(x:string)=>void;setDay:(x:string)=>void;onShift:(s:Shift)=>void;onGenerate:()=>void}) {
  const grouped=new Map<string,Assignment[]>();for(const a of assignments){const k=a.shift_id;grouped.set(k,[...(grouped.get(k)||[]),a]);}
  return <section className="live-module"><div className="section-head"><div><p className="eyebrow">DANE Z SUPABASE</p><h2>{data.plan?.name||"Brak wygenerowanego planu"}</h2></div><div><button className="secondary-button" onClick={()=>downloadCsv("grafik.csv",[["Data","Lokal","Zmiana","Od","Do","Pracownik","Rola","Funkcja","Koszt"],...assignments.map(a=>[a.date,a.location,a.shift_code,fmtTime(a.starts_at),fmtTime(a.ends_at),a.name,a.role,a.capability||"",a.cost])])}><Download size={16}/> CSV</button><button className="primary-button" onClick={onGenerate}><Plus size={16}/> Wariant</button></div></div><Filters {...{location,role,day,setLocation,setRole,setDay}}/>
    {!data.plan?<div className="empty-engine"><p>Najpierw wygeneruj wariant.</p></div>:<div className="schedule-list">{data.shifts.filter(s=>(location==="ALL"||s.location_code===location)&&(day==="ALL"||s.shift_date===day)).map(s=>{const staff=(grouped.get(s.id)||[]).filter(a=>role==="ALL"||a.role===role);if(role!=="ALL"&&!staff.length)return null;return <button className="real-shift" key={s.id} onClick={()=>onShift(s)}><span className={`shift-code ${s.shift_code.toLowerCase()}`}>{s.shift_code}</span><span><strong>{fmtDate(s.shift_date)} • {s.location_code}</strong><small>{fmtTime(s.starts_at)}–{fmtTime(s.ends_at)}</small></span><div className="shift-avatars">{staff.slice(0,6).map(a=><i key={a.id} title={`${a.name} • ${a.role}`}>{a.name.split(" ").map(x=>x[0]).join("")}</i>)}{staff.length>6&&<b>+{staff.length-6}</b>}</div><strong>{staff.length} os.</strong><ChevronRight/></button>;})}</div>}
  </section>;
}
function RolePlanningView({matrix,busy,onCreate,onTransition}:{matrix:MatrixWorkspace;busy:boolean;onCreate:(id:string,name:string)=>Promise<void>;onTransition:(id:string,status:string)=>Promise<void>}) {
  const latest=new Map<string,RoleSection>();
  for(const section of matrix.sections){const current=latest.get(section.role_id);if(!current||section.version>current.version)latest.set(section.role_id,section);}
  const submitted=[...latest.values()].filter(x=>["SUBMITTED","APPROVED","LOCKED"].includes(x.status)).length;
  return <section className="live-module"><div className="section-head"><div><p className="eyebrow">PLANOWANIE ZESPOŁOWE</p><h2>{submitted} / {matrix.roles.length} zespołów przekazało grafik</h2></div><span className="status-pill ready">Matrix v{matrix.version?.version||"—"}</span></div>
    <div className="team-plan-grid">{matrix.roles.map(r=>{const s=latest.get(r.id);return <article className="team-plan-card" key={r.id}><div className="team-role"><i style={{background:r.color||"#7257d8"}}/><span><strong>{r.name}</strong><small>{s?`Wariant ${s.version} • ${s.status}`:"Brak wariantu"}</small></span></div><p>{s?s.name:"Lider tej roli może utworzyć pierwszy niezależny fragment grafiku."}</p><div className="team-actions">{!s&&<button disabled={busy} className="primary-button" onClick={()=>void onCreate(r.id,r.name)}><Plus/> Utwórz</button>}{s&&["DRAFT","READY","CHANGES_REQUESTED"].includes(s.status)&&<button disabled={busy} className="primary-button" onClick={()=>void onTransition(s.id,"SUBMITTED")}><Check/> Przekaż właścicielowi</button>}{s?.status==="SUBMITTED"&&<><button disabled={busy} className="primary-button" onClick={()=>void onTransition(s.id,"APPROVED")}><Check/> Zatwierdź puzzel</button><button disabled={busy} className="secondary-button" onClick={()=>void onTransition(s.id,"CHANGES_REQUESTED")}>Do poprawy</button></>}{s?.status==="APPROVED"&&<button disabled={busy} className="secondary-button" onClick={()=>void onTransition(s.id,"LOCKED")}><LockIcon/> Zablokuj</button>}{s&&<button disabled={busy} className="secondary-button" onClick={()=>void onCreate(r.id,r.name)}>Nowy wariant</button>}</div></article>;})}</div>
    <div className="assembly-box"><Puzzle/><span><strong>Pełny grafik powstaje z zatwierdzonych puzzli</strong><small>Właściciel widzi wszystkie role. Przed publikacją system sprawdza kolizje osób, lokalizacji, odpoczynku, dostępności i budżetu.</small></span></div>
  </section>;
}

function LockIcon(){return <span aria-hidden="true">◆</span>;}

function MatrixView({matrix}:{matrix:MatrixWorkspace}) {
  return <section className="live-module"><div className="section-head"><div><p className="eyebrow">WERSJONOWANA STRUKTURA ORGANIZACJI</p><h2>{matrix.version?.name||"Brak aktywnego Matrixa"}</h2></div><span className="status-pill published">AKTYWNY • v{matrix.version?.version||"—"}</span></div>
    <div className="matrix-summary"><div><small>Role podstawowe</small><strong>{matrix.roles.length}</strong><span>można dodawać bez zmiany kodu</span></div><div><small>Funkcje dodatkowe</small><strong>{matrix.functions.length}</strong><span>np. HOST, RUNNER, zamknięcie</span></div><div><small>Lokale</small><strong>{matrix.locations.length}</strong><span>dowolna liczba lokalizacji</span></div><div><small>Zmiany</small><strong>{matrix.shifts.length}</strong><span>do {matrix.version?.settings?.maxShiftsPerDay||7} dziennie</span></div></div>
    <div className="matrix-columns"><div><h3>Role</h3>{matrix.roles.map(x=><div className="matrix-row" key={x.id}><i style={{background:x.color||"#7257d8"}}/><span><strong>{x.name}</strong><small>{x.code}</small></span><em>{x.active===false?"Wyłączona":"Aktywna"}</em></div>)}<button className="matrix-add"><Plus/> Dodaj rolę w nowej wersji</button></div><div><h3>Funkcje i obowiązki</h3>{matrix.functions.map(x=><div className="matrix-row" key={x.id}><i/><span><strong>{x.name}</strong><small>{x.code}</small></span><em>Edytowalna</em></div>)}<button className="matrix-add"><Plus/> Dodaj funkcję</button></div><div><h3>Lokale i zmiany</h3>{matrix.locations.map(x=><div className="matrix-row" key={x.id}><i/><span><strong>{x.name}</strong><small>{x.code}</small></span><em>{matrix.shifts.filter(s=>s.location_id===x.id).length} zmian</em></div>)}<button className="matrix-add"><Plus/> Dodaj lokal / zmianę</button></div></div>
    <div className="impact-box"><Settings/><span><strong>Zmiany Matrixa nie niszczą historii</strong><small>Nowa konfiguracja tworzy kolejną wersję. Opublikowane grafiki pozostają przypięte do wersji, na której powstały. Minimalny odpoczynek: {Math.round((matrix.version?.settings?.minimumRestMinutes||660)/60)} h.</small></span></div>
  </section>;
}

function MonthView({data,onDay,onEvent}:{data:Workspace;onDay:(d:string)=>void;onEvent:()=>void}) {
  const first=new Date("2026-07-01T12:00:00");const offset=(first.getDay()+6)%7;const cells=Array.from({length:offset+31},(_,i)=>i<offset?0:i-offset+1);
  return <section className="live-module"><div className="section-head"><div><p className="eyebrow">KALENDARZ MENADŻERSKI</p><h2>Lipiec 2026</h2></div><button className="primary-button" onClick={onEvent}><Plus/> Event / wyjątek</button></div><div className="real-month"><div className="month-weekdays">{["Pon","Wt","Śr","Czw","Pt","Sob","Niedz"].map(x=><span key={x}>{x}</span>)}</div><div className="month-grid">{cells.map((n,i)=>{if(!n)return <span key={i}/>;const date=`2026-07-${String(n).padStart(2,"0")}`;const ass=data.assignments.filter(a=>a.date===date);const ev=data.events.filter(e=>e.starts_at.slice(0,10)===date);return <button key={date} className="month-day" onClick={()=>onDay(date)}><span className="day-number">{n}</span><div className="mini-people">{ass.slice(0,4).map(a=><span className="avatar violet" key={a.id}>{a.name.split(" ").map(x=>x[0]).join("")}</span>)}{ass.length>4&&<b>+{ass.length-4}</b>}</div>{ev.map(e=><span className="calendar-event orange" key={e.id}>{e.title}</span>)}<small>{ass.length} przydziałów</small></button>;})}</div></div></section>;
}
function EmployeeView({employees,onSelect}:{employees:{id:string;no:string;name:string;role:string;minutes:number;nominal:number;cost:number;shifts:number}[];selected:string;onSelect:(x:string)=>void}) {
  return <section className="live-module"><div className="section-head"><div><p className="eyebrow">OBCIĄŻENIE I SPRAWIEDLIWOŚĆ</p><h2>Widok per pracownik</h2></div><button className="secondary-button" onClick={()=>downloadCsv("pracownicy.csv",[["ID","Pracownik","Rola","Godziny","Nominał","Wykorzystanie","Zmiany","Koszt"],...employees.map(e=>[e.no,e.name,e.role,Math.round(e.minutes/60),Math.round(e.nominal/60),Math.round(e.minutes/e.nominal*100)+"%",e.shifts,Math.round(e.cost)])])}><Download/> CSV</button></div><div className="employee-table"><div className="table-head"><span>Pracownik</span><span>Rola</span><span>Godziny</span><span>Nominał</span><span>Wykorzystanie</span></div>{employees.map(e=>{const pct=Math.round(e.minutes/Math.max(e.nominal,1)*100);return <button key={e.id} onClick={()=>onSelect(e.id)}><span><strong>{e.name}</strong><small>{e.no} • {e.shifts} zmian</small></span><span>{roleLabels[e.role]}</span><strong>{Math.round(e.minutes/60)} h</strong><span>{Math.round(e.nominal/60)} h</span><span className={`load ${pct>110?"over":pct<70?"under":""}`}><i style={{width:`${Math.min(pct,130)}%`}}/>{pct}%</span></button>;})}</div></section>;
}
function IssuesView({issues,shifts,onOpen}:{issues:Issue[];shifts:Shift[];onOpen:(s:Shift)=>void}) {
  return <section className="live-module"><div className="section-head"><div><p className="eyebrow">WYNIK WALIDACJI</p><h2>{issues.length} aktywnych alertów</h2></div></div><div className="issues-list">{issues.length===0?<div className="success-box"><Check/><span><strong>Brak naruszeń</strong>Plan spełnia wszystkie obecne reguły.</span></div>:issues.map(i=><button key={i.id} className={`issue-row ${i.severity.toLowerCase()}`} onClick={()=>{const s=shifts.find(x=>x.id===i.shift_id);if(s)onOpen(s);}}><AlertTriangle/><span><strong>{issueLabels[i.issue_type]||i.issue_type} • {roleLabels[i.role||""]||"Cały plan"}</strong><small>{issueMessage(i)}</small></span><em>{i.assigned_count??"—"} / {i.required_count??"—"}</em><ChevronRight/></button>)}</div></section>;
}
function BudgetView({cost,budget,assignments}:{cost:number;budget:number;assignments:Assignment[]}) {
  const byRole=roles.map(r=>({role:r,cost:assignments.filter(a=>a.role===r).reduce((n,a)=>n+Number(a.cost),0)}));
  return <section className="live-module"><div className="section-head"><div><p className="eyebrow">FINANSE PLANU</p><h2>{cost.toLocaleString("pl-PL")} zł / {budget.toLocaleString("pl-PL")} zł</h2></div></div><div className="budget-hero"><strong>{Math.round(cost/budget*100)}%</strong><div className="progress"><i style={{width:`${Math.min(cost/budget*100,100)}%`}}/></div><small>Pozostało {(budget-cost).toLocaleString("pl-PL")} zł</small></div><div className="role-costs">{byRole.map(x=><div key={x.role}><span>{roleLabels[x.role]}</span><strong>{Math.round(x.cost).toLocaleString("pl-PL")} zł</strong><i style={{width:`${cost?x.cost/cost*100:0}%`}}/></div>)}</div></section>;
}
