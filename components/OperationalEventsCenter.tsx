"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import {
  AlertTriangle, Archive, Boxes, CalendarDays, Check, ChevronDown, CircleX,
  ClipboardCheck, ExternalLink, Filter, LoaderCircle, MapPin, PackageSearch,
  Plus, RefreshCw, Search, Send, Sparkles, Users, X,
} from "lucide-react";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";

type CatalogItem={id:string;code:string;name:string;color?:string;categoryId?:string|null};
type Employee={id:string;employeeNo:string;name:string;email?:string|null};
type Candidate={employeeId:string;employeeNo:string;name:string;status:"SAFE"|"WARNING"|"BLOCKED";reasons:string[];plannedMinutes:number;nominalMinutes:number;maximumMinutes:number};
type EventParticipant={employeeId?:string|null;name:string;candidateStatus:string;status:string;reasons:string[]};
type OperationalEvent={
  id:string;type:string;title:string;description?:string|null;startsAt:string;endsAt:string;
  status:string;audienceMode:string;requiredCount?:number|null;locationId?:string|null;
  locationName?:string|null;publishedNote?:string|null;agenda?:string|null;
  inventoryType?:string|null;inventoryGroups?:string[];participants:EventParticipant[];
  checklist:{id:string;label:string;visibility:string;completed:boolean}[];
  inventoryLink?:{status:string;url?:string|null;externalSessionId?:string|null;lastError?:string|null}|null;
};
type Workspace={
  canManage:boolean;canConfigureIntegration:boolean;categories:CatalogItem[];roles:CatalogItem[];
  locations:CatalogItem[];employees:Employee[];events:OperationalEvent[];
  integration?:{id:string;displayName:string;baseUrl?:string|null;launchPathTemplate:string;status:string;active:boolean}|null;
};
type CatalogFallback={categories:CatalogItem[];roles:CatalogItem[];locations:CatalogItem[]};

const TYPE_LABELS:Record<string,string>={MEETING:"Zebranie",CLEANING:"Sprzątanie generalne",INVENTORY:"Inwentaryzacja",TRAINING:"Szkolenie",ONBOARDING:"Onboarding",OTHER:"Inne wydarzenie"};
const STATUS_LABELS:Record<string,string>={DRAFT:"Wersja robocza",ANALYSIS:"Analiza",PUBLISHED:"Opublikowane",COMPLETED:"Zakończone",CANCELLED:"Anulowane"};
const AUDIENCE_LABELS:Record<string,string>={ALL_SCOPE:"Wszyscy w wybranym zakresie",NEED_COUNT:"Potrzebuję określonej liczby osób",SELECTED:"Wybieram konkretne osoby"};
const INVENTORY_LABELS:Record<string,string>={FULL:"Pełna",PARTIAL:"Częściowa",CONTROL:"Kontrolna",SELECTED_GROUPS:"Wybrane grupy produktów"};

function errorMessage(value:string){
  const code=value.split("\n")[0];
  if(code.includes("PARTICIPANT_HARD_BLOCK"))return "Wybrana osoba ma twardą blokadę. Odśwież analizę i wybierz inną osobę.";
  if(code.includes("PARTICIPANT_WARNING_REQUIRES_REASON"))return "Dla osoby z ostrzeżeniem wpisz uzasadnienie świadomej decyzji.";
  if(code.includes("NOT_ENOUGH_PARTICIPANTS"))return "Wybierz co najmniej tyle osób, ile wymaga wydarzenie.";
  if(code.includes("PUBLISHED_CONFIGURATION_NOT_FOUND"))return "Najpierw opublikuj konfigurację firmy dla tego miesiąca.";
  return value;
}
function toIso(date:string,time:string){return new Date(`${date}T${time}:00`).toISOString();}
function localMoment(value:string){return new Intl.DateTimeFormat("pl-PL",{dateStyle:"medium",timeStyle:"short"}).format(new Date(value));}
function hours(minutes:number){return `${Math.round(minutes/6)/10} h`;}

export function OperationalEventsCenter({month,notify,fail,catalog}:{month:string;notify:(message:string)=>void;fail:(message:string)=>void;catalog?:CatalogFallback}){
  const supabase=useMemo(()=>createSupabaseBrowserClient(),[]);
  const [workspace,setWorkspace]=useState<Workspace|null>(null);
  const [loading,setLoading]=useState(true);
  const [busy,setBusy]=useState(false);
  const [creatorOpen,setCreatorOpen]=useState(false);
  const [archiveOpen,setArchiveOpen]=useState(false);
  const [typeFilter,setTypeFilter]=useState("ALL");
  const [statusFilter,setStatusFilter]=useState("ACTIVE");
  const [query,setQuery]=useState("");
  const [candidateQuery,setCandidateQuery]=useState("");
  const [preview,setPreview]=useState<Candidate[]>([]);
  const [selected,setSelected]=useState<string[]>([]);
  const [integrationOpen,setIntegrationOpen]=useState(false);
  const [integrationUrl,setIntegrationUrl]=useState("");
  const [integrationPath,setIntegrationPath]=useState("/sessions/new?eventId={eventId}");
  const [form,setForm]=useState({
    type:"CLEANING",title:"",description:"",date:`${month}-01`,start:"10:00",end:"12:00",
    locationId:"",audienceMode:"NEED_COUNT",requiredCount:"3",categoryIds:[] as string[],roleIds:[] as string[],
    privateNote:"",publishedNote:"",agenda:"",checklist:"",inventoryType:"FULL",
    inventoryGroups:"",overrideReason:"",
  });

  const load=useCallback(async(quiet=false)=>{
    if(!supabase)return;
    if(!quiet)setLoading(true);
    const result=await supabase.rpc("operational_program_workspace_uat_v1",{p_month:`${month}-01`});
    if(!quiet)setLoading(false);
    if(result.error||!result.data){fail(errorMessage(result.error?.message||"Nie udało się pobrać wydarzeń operacyjnych."));return;}
    const next=result.data as Workspace;
    setWorkspace(next);
    setIntegrationUrl(next.integration?.baseUrl||"");
    setIntegrationPath(next.integration?.launchPathTemplate||"/sessions/new?eventId={eventId}");
  },[fail,month,supabase]);
  useEffect(()=>{void load();},[load]);
  useEffect(()=>setForm(current=>({...current,date:`${month}-01`})),[month]);

  const categories=workspace?.categories.length?workspace.categories:(catalog?.categories??[]);
  const roleCatalog=workspace?.roles.length?workspace.roles:(catalog?.roles??[]);
  const locations=workspace?.locations.length?workspace.locations:(catalog?.locations??[]);
  const roles=roleCatalog.filter(role=>!form.categoryIds.length||!!role.categoryId&&form.categoryIds.includes(role.categoryId));
  const toggleScope=(field:"categoryIds"|"roleIds",id:string)=>setForm(current=>{
    const next=current[field].includes(id)?current[field].filter(value=>value!==id):[...current[field],id];
    if(field==="categoryIds")return {
      ...current,categoryIds:next,
      roleIds:current.roleIds.filter(roleId=>!next.length||!!roleCatalog.find(role=>role.id===roleId&&(!role.categoryId||next.includes(role.categoryId)))),
    };
    return {...current,roleIds:next};
  });
  const visibleEvents=(workspace?.events??[]).filter(item=>{
    const active=statusFilter==="ACTIVE"?item.status!=="CANCELLED":statusFilter==="ALL"||item.status===statusFilter;
    const type=typeFilter==="ALL"||item.type===typeFilter;
    const text=`${item.title} ${item.locationName||""} ${TYPE_LABELS[item.type]||item.type}`.toLocaleLowerCase("pl-PL");
    return active&&type&&(!query.trim()||text.includes(query.trim().toLocaleLowerCase("pl-PL")));
  });
  const filteredCandidates=preview.filter(item=>!candidateQuery.trim()||`${item.name} ${item.employeeNo}`.toLocaleLowerCase("pl-PL").includes(candidateQuery.trim().toLocaleLowerCase("pl-PL")));
  const safeCount=preview.filter(item=>item.status==="SAFE").length;
  const warningCount=preview.filter(item=>item.status==="WARNING").length;
  const blockedCount=preview.filter(item=>item.status==="BLOCKED").length;

  const analyze=async()=>{
    if(!supabase||!form.title.trim()||!form.date||!form.start||!form.end)return;
    setBusy(true);
    const result=await supabase.rpc("operational_program_preview_uat_v1",{
      p_month:`${month}-01`,p_starts_at:toIso(form.date,form.start),p_ends_at:toIso(form.date,form.end),
      p_location_id:form.locationId||null,p_category_ids:form.categoryIds,
      p_role_ids:form.roleIds,p_employee_ids:[],p_required_count:Number(form.requiredCount)||1,
    });
    setBusy(false);
    if(result.error||!result.data){fail(errorMessage(result.error?.message||"Analiza kandydatów nie powiodła się."));return;}
    const next=(result.data as {candidates:Candidate[]}).candidates;
    setPreview(next);
    if(form.audienceMode==="ALL_SCOPE")setSelected(next.filter(item=>item.status!=="BLOCKED").map(item=>item.employeeId));
    else setSelected(current=>current.filter(id=>next.some(item=>item.employeeId===id&&item.status!=="BLOCKED")));
    notify(`Analiza gotowa: ${next.filter(item=>item.status==="SAFE").length} osób bez ostrzeżeń.`);
  };

  const publish=async()=>{
    if(!supabase||!preview.length)return;
    const minimum=form.audienceMode==="NEED_COUNT"?Number(form.requiredCount)||1:1;
    if(selected.length<minimum){fail(`Wybierz co najmniej ${minimum} os.`);return;}
    if(selected.some(id=>preview.find(item=>item.employeeId===id)?.status==="WARNING")&&form.overrideReason.trim().length<5){
      fail("Wpisz uzasadnienie decyzji dla zaznaczonych osób z ostrzeżeniem.");return;
    }
    setBusy(true);
    const audience=[
      ...form.categoryIds.map(id=>({mode:"INCLUDE",type:"CATEGORY",id})),
      ...form.roleIds.map(id=>({mode:"INCLUDE",type:"ROLE",id})),
      ...selected.map(id=>({mode:"INCLUDE",type:"EMPLOYEE",id})),
    ];
    const checklist=form.checklist.split("\n").map(value=>value.trim()).filter(Boolean).map((label,index)=>({label,order:index+1,visibility:"ALL"}));
    const result=await supabase.rpc("operational_program_save_uat_v1",{
      p_event:{type:form.type,title:form.title.trim(),description:form.description.trim(),startsAt:toIso(form.date,form.start),
        endsAt:toIso(form.date,form.end),locationId:form.locationId||null,status:"PUBLISHED",audienceMode:form.audienceMode,
        requiredCount:Number(form.requiredCount)||selected.length,privateNote:form.privateNote.trim(),publishedNote:form.publishedNote.trim(),
        agenda:form.agenda.trim(),inventoryType:form.type==="INVENTORY"?form.inventoryType:null,
        inventoryGroups:form.inventoryGroups.split(",").map(value=>value.trim()).filter(Boolean),overrideReason:form.overrideReason.trim()},
      p_audience:audience,p_checklist:checklist,p_participant_ids:selected,
    });
    setBusy(false);
    if(result.error){fail(errorMessage(result.error.message));return;}
    notify("Wydarzenie opublikowane. Uczestnicy otrzymali powiadomienia, a czas trafił do ewidencji.");
    setCreatorOpen(false);setPreview([]);setSelected([]);
    setForm(current=>({...current,title:"",description:"",privateNote:"",publishedNote:"",agenda:"",checklist:"",overrideReason:""}));
    await load(true);
  };

  const cancel=async(event:OperationalEvent)=>{
    if(!supabase)return;
    const reason=window.prompt(`Podaj powód anulowania wydarzenia „${event.title}”. Uczestnicy dostaną tę informację.`);
    if(!reason?.trim())return;
    setBusy(true);
    const result=await supabase.rpc("operational_program_cancel_uat_v1",{p_event_id:event.id,p_reason:reason.trim()});
    setBusy(false);
    if(result.error){fail(errorMessage(result.error.message));return;}
    notify("Wydarzenie anulowano, a uczestnicy zostali poinformowani.");await load(true);
  };

  const saveIntegration=async()=>{
    if(!supabase)return;
    setBusy(true);
    const result=await supabase.rpc("operational_program_integration_save_uat_v1",{
      p_base_url:integrationUrl.trim(),p_launch_path_template:integrationPath.trim(),p_active:true,
    });
    setBusy(false);
    if(result.error){fail(errorMessage(result.error.message));return;}
    notify("Połączenie z INVETORY PRO zapisane.");setIntegrationOpen(false);await load(true);
  };

  if(loading)return <section className="operational-program-loading"><LoaderCircle className="spin"/><strong>Pobieram wydarzenia i dostępność zespołu…</strong></section>;
  if(!workspace)return null;
  return <section className="operational-programs">
    <header className="operational-program-head"><div><p className="eyebrow">OPERACJE PO PUBLIKACJI GRAFIKU</p><h2>Wydarzenia zespołu</h2><p>Zebrania, sprzątanie, inwentaryzacje i inne działania planowane na gotowym grafiku.</p></div><div className="operational-program-actions"><button className="secondary-button" onClick={()=>void load()}><RefreshCw/> Odśwież</button>{workspace.canManage&&<button className="primary-button" onClick={()=>setCreatorOpen(open=>!open)}>{creatorOpen?<X/>:<Plus/>}{creatorOpen?"Zamknij kreator":"Nowe wydarzenie"}</button>}</div></header>
    <div className="operational-program-kpis">
      <article><CalendarDays/><span><small>W tym miesiącu</small><strong>{workspace.events.length}</strong></span></article>
      <article><Send/><span><small>Opublikowane</small><strong>{workspace.events.filter(item=>item.status==="PUBLISHED").length}</strong></span></article>
      <article><PackageSearch/><span><small>Inwentaryzacje</small><strong>{workspace.events.filter(item=>item.type==="INVENTORY").length}</strong></span></article>
      <button onClick={()=>setArchiveOpen(open=>!open)}><Archive/><span><small>Archiwum</small><strong>{workspace.events.filter(item=>["COMPLETED","CANCELLED"].includes(item.status)).length}</strong></span></button>
    </div>

    {workspace.canConfigureIntegration&&<details className="inventory-bridge" open={integrationOpen} onToggle={event=>setIntegrationOpen(event.currentTarget.open)}><summary><span><Boxes/><b>INVETORY PRO</b><em>{workspace.integration?.active?"Połączenie skonfigurowane":"Skonfiguruj wejście do magazynu"}</em></span><span className={`integration-status ${workspace.integration?.active?"ready":"waiting"}`}>{workspace.integration?.status||"DISCONNECTED"}<ChevronDown/></span></summary><div><p>SZAFUNEK przekazuje wydarzenie, termin i uczestników. Stany, produkty oraz wynik inwentaryzacji pozostają w INVETORY PRO.</p><label>Adres aplikacji INVETORY PRO<input value={integrationUrl} onChange={event=>setIntegrationUrl(event.target.value)} placeholder="https://inventory-pro.example.com"/></label><label>Ścieżka uruchomienia<input value={integrationPath} onChange={event=>setIntegrationPath(event.target.value)} placeholder="/sessions/new?eventId={eventId}"/></label><button className="primary-button" disabled={busy||!integrationUrl.trim()} onClick={()=>void saveIntegration()}><Check/> Zapisz połączenie</button></div></details>}

    {creatorOpen&&<section className="operational-creator"><header><div><p className="eyebrow">KREATOR WYDARZENIA</p><h3>Najpierw zakres i czas, potem analiza kandydatów</h3></div><span>1. Dane → 2. Analiza → 3. Publikacja</span></header><div className="operational-form-grid"><label>Rodzaj<select value={form.type} onChange={event=>setForm({...form,type:event.target.value})}>{Object.entries(TYPE_LABELS).map(([value,label])=><option key={value} value={value}>{label}</option>)}</select></label><label className="wide">Nazwa<input value={form.title} onChange={event=>setForm({...form,title:event.target.value})} placeholder="np. Generalne sprzątanie baru"/></label><label>Data<input type="date" value={form.date} onChange={event=>setForm({...form,date:event.target.value})}/></label><label>Od<input type="time" value={form.start} onChange={event=>setForm({...form,start:event.target.value})}/></label><label>Do<input type="time" value={form.end} onChange={event=>setForm({...form,end:event.target.value})}/></label><label>Lokal<select value={form.locationId} onChange={event=>setForm({...form,locationId:event.target.value})}><option value="">Wszystkie / bez lokalu</option>{locations.map(item=><option key={item.id} value={item.id}>{item.name}</option>)}</select></label><label>Sposób obsady<select value={form.audienceMode} onChange={event=>setForm({...form,audienceMode:event.target.value})}>{Object.entries(AUDIENCE_LABELS).map(([value,label])=><option key={value} value={value}>{label}</option>)}</select></label><label>Liczba osób<input type="number" min="1" value={form.requiredCount} onChange={event=>setForm({...form,requiredCount:event.target.value})}/></label><fieldset className="wide operational-scope-picker"><legend>Kategorie — możesz wybrać kilka</legend><div><button type="button" className={!form.categoryIds.length?"selected":""} onClick={()=>setForm(current=>({...current,categoryIds:[],roleIds:[]}))}>Wszystkie</button>{categories.map(item=><button type="button" key={item.id} className={form.categoryIds.includes(item.id)?"selected":""} onClick={()=>toggleScope("categoryIds",item.id)}>{item.name}</button>)}</div></fieldset><fieldset className="wide operational-scope-picker"><legend>Role — możesz łączyć role z różnych kategorii</legend><div><button type="button" className={!form.roleIds.length?"selected":""} onClick={()=>setForm(current=>({...current,roleIds:[]}))}>Wszystkie w zakresie</button>{roles.map(item=><button type="button" key={item.id} className={form.roleIds.includes(item.id)?"selected":""} onClick={()=>toggleScope("roleIds",item.id)}>{item.name}</button>)}</div></fieldset>{form.type==="INVENTORY"&&<><label>Typ inwentaryzacji<select value={form.inventoryType} onChange={event=>setForm({...form,inventoryType:event.target.value})}>{Object.entries(INVENTORY_LABELS).map(([value,label])=><option key={value} value={value}>{label}</option>)}</select></label><label className="wide">Grupy produktów<input value={form.inventoryGroups} onChange={event=>setForm({...form,inventoryGroups:event.target.value})} placeholder="bar, alkohole, szkło — oddziel przecinkami"/></label></>}<label className="wide">Opis organizacyjny<input value={form.description} onChange={event=>setForm({...form,description:event.target.value})} placeholder="Krótki opis widoczny w archiwum"/></label><label className="wide">Informacja dla uczestników<textarea value={form.publishedNote} onChange={event=>setForm({...form,publishedNote:event.target.value})} placeholder="Co uczestnicy powinni wiedzieć?"/></label><label className="wide">Agenda<textarea value={form.agenda} onChange={event=>setForm({...form,agenda:event.target.value})} placeholder="Plan wydarzenia"/></label><label className="wide">Checklista — jeden punkt w wierszu<textarea value={form.checklist} onChange={event=>setForm({...form,checklist:event.target.value})} placeholder={"Przygotuj arkusze\nSprawdź sprzęt\nZamknij wydarzenie"}/></label><label className="wide private-field">Prywatna notatka organizatora<textarea value={form.privateNote} onChange={event=>setForm({...form,privateNote:event.target.value})} placeholder="Widoczna tylko dla organizatora"/></label></div><button className="primary-button operational-analyze" disabled={busy||!form.title.trim()} onClick={()=>void analyze()}><Sparkles/>{busy?"Analizuję…":"Sprawdź dostępność i zaproponuj osoby"}</button>
      {!!preview.length&&<div className="candidate-analysis"><header><div><h4>Wynik analizy</h4><p>Zielone osoby można przypisać. Pomarańczowe wymagają świadomej decyzji. Czerwonych system nie pozwoli przypisać.</p></div><div><span className="safe">{safeCount} bez blokad</span><span className="warning">{warningCount} ostrzeżeń</span><span className="blocked">{blockedCount} blokad</span></div></header><label className="candidate-search"><Search/><input value={candidateQuery} onChange={event=>setCandidateQuery(event.target.value)} placeholder="Szukaj nazwiska lub numeru"/></label><div className="candidate-grid">{filteredCandidates.map(item=><button type="button" key={item.employeeId} disabled={item.status==="BLOCKED"} className={`${item.status.toLowerCase()} ${selected.includes(item.employeeId)?"selected":""}`} onClick={()=>setSelected(current=>current.includes(item.employeeId)?current.filter(id=>id!==item.employeeId):[...current,item.employeeId])}><span><b>{item.name}</b><small>{item.employeeNo} • {hours(item.plannedMinutes)} z celu {hours(item.nominalMinutes)}</small>{item.reasons.map(reason=><em key={reason}>{reason}</em>)}</span>{selected.includes(item.employeeId)&&<Check/>}</button>)}</div>{selected.some(id=>preview.find(item=>item.employeeId===id)?.status==="WARNING")&&<label className="override-reason">Uzasadnienie decyzji dla osób z ostrzeżeniem<textarea value={form.overrideReason} onChange={event=>setForm({...form,overrideReason:event.target.value})} placeholder="np. uzgodniono z pracownikiem i potwierdzono odpoczynek"/></label>}<footer><span>Wybrano <b>{selected.length}</b> os. {form.audienceMode==="NEED_COUNT"&&`z wymaganych ${Number(form.requiredCount)||1}`}</span><button className="primary-button" disabled={busy||!selected.length} onClick={()=>void publish()}><Send/>{busy?"Publikuję…":"Opublikuj wydarzenie"}</button></footer></div>}
    </section>}

    <div className="operational-event-tools"><label><Search/><input value={query} onChange={event=>setQuery(event.target.value)} placeholder="Szukaj wydarzenia lub lokalu"/></label><label><Filter/><select value={typeFilter} onChange={event=>setTypeFilter(event.target.value)}><option value="ALL">Wszystkie typy</option>{Object.entries(TYPE_LABELS).map(([value,label])=><option key={value} value={value}>{label}</option>)}</select></label><label><select value={statusFilter} onChange={event=>setStatusFilter(event.target.value)}><option value="ACTIVE">Aktywne</option><option value="ALL">Wszystkie statusy</option>{Object.entries(STATUS_LABELS).map(([value,label])=><option key={value} value={value}>{label}</option>)}</select></label></div>
    <div className="operational-event-list">{visibleEvents.map(item=><article key={item.id} className={`event-${item.type.toLowerCase()} ${item.status.toLowerCase()}`}><header><span className="event-icon">{item.type==="INVENTORY"?<PackageSearch/>:item.type==="MEETING"?<Users/>:item.type==="CLEANING"?<ClipboardCheck/>:<CalendarDays/>}</span><div><small>{TYPE_LABELS[item.type]||item.type} • {STATUS_LABELS[item.status]||item.status}</small><h3>{item.title}</h3><p><CalendarDays/> {localMoment(item.startsAt)}–{new Intl.DateTimeFormat("pl-PL",{timeStyle:"short"}).format(new Date(item.endsAt))}{item.locationName&&<><MapPin/> {item.locationName}</>}</p></div><span className={`status-chip ${item.status.toLowerCase()}`}>{STATUS_LABELS[item.status]||item.status}</span></header>{item.publishedNote&&<p className="event-note">{item.publishedNote}</p>}<div className="event-summary"><span><Users/><b>{item.participants.length}</b> uczestników</span>{item.requiredCount&&<span>Wymagane: <b>{item.requiredCount}</b></span>}<span>Zakres: <b>{AUDIENCE_LABELS[item.audienceMode]||item.audienceMode}</b></span></div><details><summary>Pokaż uczestników, agendę i checklistę <ChevronDown/></summary><div className="event-details"><div><h4>Uczestnicy</h4>{item.participants.map(person=><span className={`participant ${person.candidateStatus.toLowerCase()}`} key={`${person.employeeId}-${person.name}`}><b>{person.name}</b><small>{person.reasons.join(" • ")||"Bez ostrzeżeń"}</small></span>)}</div><div><h4>Agenda i zadania</h4><p>{item.agenda||"Brak agendy."}</p>{item.checklist.map(check=><span className="check-item" key={check.id}>{check.completed?<Check/>:<span/>}{check.label}</span>)}</div></div></details><footer>{item.type==="INVENTORY"&&item.inventoryLink?.url&&<a className="primary-button" href={item.inventoryLink.url} target="_blank" rel="noreferrer"><ExternalLink/> Otwórz inwentaryzację</a>}{item.type==="INVENTORY"&&!item.inventoryLink?.url&&<span className="inventory-wait"><AlertTriangle/> Skonfiguruj INVETORY PRO, aby utworzyć sesję magazynową.</span>}{workspace.canManage&&!["CANCELLED","COMPLETED"].includes(item.status)&&<button className="danger-button" disabled={busy} onClick={()=>void cancel(item)}><CircleX/> Anuluj i poinformuj uczestników</button>}</footer></article>)}{!visibleEvents.length&&<div className="operational-empty"><CalendarDays/><h3>Brak wydarzeń spełniających filtr</h3><p>Utwórz pierwsze wydarzenie na gotowym grafiku albo otwórz archiwum.</p></div>}</div>
    {archiveOpen&&<p className="archive-hint"><Archive/> Archiwum jest częścią tej samej listy. W filtrze statusu wybierz „Wszystkie statusy” albo „Anulowane”.</p>}
  </section>;
}
