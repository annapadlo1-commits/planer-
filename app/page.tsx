"use client";

import {
  AlertTriangle, BarChart3, Bell, CalendarDays, Check, ChevronLeft, ChevronRight,
  CircleDollarSign, Clock3, Download, Filter, Gauge, LogOut, MapPin,
  Menu, Plus, RefreshCw, Settings, Users, WandSparkles, Wifi, X, Boxes, Puzzle,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useAppAuth } from "@/components/AppAuthProvider";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import {CompleteModules,type CompleteWorkspace} from "@/components/CompleteModules";
import {SolverV2Panel} from "@/components/SolverV2Panel";
import {MatrixV2Editor} from "@/components/MatrixV2Editor";
import {
  getActiveSolverWorkspace,
  isActiveOrtoolsWorkspace,
  isEmptyOrtoolsWorkspace,
  loadSolverConfiguration,
  mapSolverWorkspaceToOperational,
  solverErrorMessage,
  type OperationalAssignment as Assignment,
  type OperationalEvent as EventRow,
  type OperationalIssue as Issue,
  type OperationalPlan as Plan,
  type OperationalShift as Shift,
  type OperationalWorkspace as Workspace,
  type SolverConfiguration,
  type SolverRole,
} from "@/lib/solver-v2";
import {matrixV2ErrorMessage,matrixV2Settings,type MatrixV2EmployeeDirectory,type MatrixV2Workspace} from "@/lib/matrix-v2";
type Candidate = {
  id:string; employee_no:string; name:string; role:string; hourly_rate:number;
  can_close:boolean; eligible:boolean; overtime_only:boolean;
};
type MatrixItem = { id:string; code:string; name:string; color?:string; active?:boolean; starts_at?:string; ends_at?:string; location_id?:string };
type RoleSection = { id:string; role_id:string; role_code:string; role_name:string; version:number; status:string; name:string; updated_at:string };
type MatrixWorkspace = { version:{id:string;version:number;name:string;status:string;settings:{minimumRestMinutes:number;maxShiftsPerDay:number}}|null; roles:MatrixItem[]; locations:MatrixItem[]; functions:MatrixItem[]; shifts:MatrixItem[]; demand:unknown[]; sections:RoleSection[]; conflicts:{id:string;severity:string;conflict_type:string;message:string}[] };
type NavKey = "centrum"|"generator"|"zespoly"|"matrix"|"grafik"|"kalendarz"|"kadra"|"hr"|"finanse"|"portal"|"czas"|"integracje"|"alerty"|"budzet";
type Modal = "plan"|"event"|"shift"|"employee"|null;
type PlanScope = {type:"COMPANY";role:null}|{type:"ROLE";role:SolverRole};
type EventForm = {
  location:string;type:string;title:string;description:string;date:string;
  start:string;end:string;guests:string;status:string;demand:Record<string,string>;
};

const DEFAULT_MONTH = new Date().toISOString().slice(0,7);
function monthDate(month:string){return `${month}-01`;}
function monthLabel(month:string,_timeZone?:string){
  return new Intl.DateTimeFormat("pl-PL",{month:"long",year:"numeric",timeZone:"UTC"})
    .format(new Date(`${month}-01T12:00:00Z`));
}
function daysInMonth(month:string){
  const [year,number]=month.split("-").map(Number);
  return new Date(year,number,0).getDate();
}
function adjacentMonth(month:string,offset:number){
  const [year,number]=month.split("-").map(Number);
  const date=new Date(year,number-1+offset,1,12);
  return `${date.getFullYear()}-${String(date.getMonth()+1).padStart(2,"0")}`;
}
const LEGACY_ROLES = ["KELNER","BARMAN","PIZZABAR","PREP","POMOC"];
const LEGACY_ROLE_LABELS: Record<string,string> = {
  KELNER:"Kelner",BARMAN:"Barman",PIZZABAR:"Pizzabar",PREP:"Prep",POMOC:"Pomoc"
};
const planStatusLabels:Record<string,string>={DRAFT:"Wersja robocza",GENERATING:"Generowanie",READY:"Gotowy do weryfikacji",PUBLISHED:"Opublikowany",STALE:"Nieaktualny",ARCHIVED:"Archiwalny",FAILED:"Błąd"};
const scenarioLabels:Record<string,string>={BASE:"Bazowy",EVENT:"Eventowy",SAVINGS:"Oszczędny",MERGED:"Scalony z grafików ról"};
const modeLabels:Record<string,string>={BALANCED:"Zrównoważony",MIN_COST:"Minimalny koszt",PREFERENCES:"Preferencje",ROLE_PLANS:"Grafiki ról"};
const issueLabels:Record<string,string>={SHORTAGE:"Brak obsady",CAPABILITY_MISSING:"Brak wymaganej funkcji",REST_VIOLATION:"Naruszenie odpoczynku",OVERLAP:"Nakładające się zmiany",MONTHLY_LIMIT:"Przekroczony limit miesięczny",WEEKLY_LIMIT:"Przekroczony limit tygodniowy"};
function issueMessage(i:Issue,roleLabels:Record<string,string>){if(i.issue_type==="SHORTAGE")return `Brakuje ${Math.max((i.required_count||0)-(i.assigned_count||0),0)} os. dla roli ${roleLabels[i.role||""]||i.role||""}.`;if(i.issue_type==="CAPABILITY_MISSING")return `Brakuje wymaganej funkcji: ${i.capability||"nieokreślona"}.`;return i.message;}
const nav = [
  ["centrum","Centrum dowodzenia",Gauge],["generator","Generator grafiku",WandSparkles],
  ["zespoly","Grafiki zespołów",Puzzle],["matrix","Matrix organizacji",Boxes],
  ["grafik","Grafik operacyjny",CalendarDays],["kalendarz","Kalendarz miesiąca",CalendarDays],
  ["kadra","Pracownicy i archiwum",Users],["hr","Kadry i HR",Users],
  ["finanse","Finanse chronione",CircleDollarSign],["portal","Portal pracownika",Users],
  ["czas","Ewidencja czasu",Clock3],["integracje","Kadromierz",Download],
  ["alerty","Braki i alerty",AlertTriangle],["budzet","Koszt planu",CircleDollarSign],
] as const;

function fmtTime(value:string,timeZone="Europe/Warsaw") {
  return new Intl.DateTimeFormat("pl-PL",{hour:"2-digit",minute:"2-digit",timeZone}).format(new Date(value));
}
function fmtDate(value:string,_timeZone?:string) {
  return new Intl.DateTimeFormat("pl-PL",{day:"2-digit",month:"short",timeZone:"UTC"}).format(new Date(value+"T12:00:00Z"));
}
function formatMoney(value:number,currency:string){
  if(!currency)return "—";
  return new Intl.NumberFormat("pl-PL",{style:"currency",currency,maximumFractionDigits:2}).format(value);
}
function localDateTimeToIso(date:string,time:string,timeZone:string){
  const intended=Date.parse(`${date}T${time}:00Z`);
  const offsetAt=(instant:number)=>{
    const parts=Object.fromEntries(new Intl.DateTimeFormat("en-CA",{
      timeZone,year:"numeric",month:"2-digit",day:"2-digit",hour:"2-digit",minute:"2-digit",second:"2-digit",hourCycle:"h23",
    }).formatToParts(new Date(instant)).filter(part=>part.type!=="literal").map(part=>[part.type,part.value]));
    const represented=Date.UTC(Number(parts.year),Number(parts.month)-1,Number(parts.day),Number(parts.hour),Number(parts.minute),Number(parts.second));
    return represented-instant;
  };
  let instant=intended-offsetAt(intended);
  instant=intended-offsetAt(instant);
  return new Date(instant).toISOString();
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
  const [matrixV2,setMatrixV2]=useState<MatrixV2Workspace|null>(null);
  const [loading,setLoading]=useState(true);
  const [busy,setBusy]=useState(false);
  const [optimizerProgress,setOptimizerProgress]=useState(0);
  const [solverConfiguration,setSolverConfiguration]=useState<SolverConfiguration|null>(null);
  const [solverConfigurationError,setSolverConfigurationError]=useState("");
  const [planScope,setPlanScope]=useState<PlanScope>({type:"COMPANY",role:null});
  const [solverPanelVersion,setSolverPanelVersion]=useState(0);
  const [roleCompositeRefreshKey,setRoleCompositeRefreshKey]=useState(0);
  const [error,setError]=useState("");
  const [toast,setToast]=useState("");
  const [active,setActive]=useState<NavKey>("centrum");
  const [modal,setModal]=useState<Modal>(null);
  const [selectedShift,setSelectedShift]=useState<Shift|null>(null);
  const [selectedEmployee,setSelectedEmployee]=useState("");
  const [candidateRole,setCandidateRole]=useState("");
  const [candidates,setCandidates]=useState<Candidate[]>([]);
  const [candidateId,setCandidateId]=useState("");
  const [notifyEmployee,setNotifyEmployee]=useState(true);
  const [location,setLocation]=useState("ALL");
  const [role,setRole]=useState("ALL");
  const [day,setDay]=useState("ALL");
  const [selectedMonth,setSelectedMonth]=useState(DEFAULT_MONTH);
  const selectedMonthDate=monthDate(selectedMonth);
  const loadTokenRef=useRef(0),loadMonthRef=useRef(selectedMonthDate);loadMonthRef.current=selectedMonthDate;
  const [planForm,setPlanForm]=useState({name:`Plan operacyjny ${DEFAULT_MONTH}`,scenario:"",legacyScenario:"BASE",mode:"BALANCED",staffing:"OPTIMAL"});
  const [eventForm,setEventForm]=useState<EventForm>({
    location:"",type:"EVENT",title:"",description:"",date:`${DEFAULT_MONTH}-15`,
    start:"18:00",end:"02:00",guests:"",status:"CONFIRMED",demand:{}
  });
  const isOrtools=solverConfiguration?.engine==="ORTOOLS_V2";
  const activeTimezone=isOrtools?solverConfiguration?.timezone??"": "Europe/Warsaw";
  const activeCurrency=isOrtools?solverConfiguration?.currency??"": "PLN";
  const solverTimezone=solverConfiguration?.engine==="SHADOW"?solverConfiguration.timezone??"":activeTimezone;
  const selectedMonthLabel=monthLabel(selectedMonth);
  const monthOptions=useMemo(()=>Array.from({length:48},(_,index)=>{
    const [year,number]=selectedMonth.split("-").map(Number);
    const date=new Date(year,number-1-12+index,1,12);
    const value=`${date.getFullYear()}-${String(date.getMonth()+1).padStart(2,"0")}`;
    return {value,label:monthLabel(value)};
  }),[selectedMonth]);
  const dynamicRoles=useMemo(()=>isOrtools?(solverConfiguration?.roles??[]):[],[isOrtools,solverConfiguration]);
  const dynamicLocations=useMemo(()=>isOrtools?(solverConfiguration?.locations??[]):[],[isOrtools,solverConfiguration]);
  const roleOptions=useMemo(()=>isOrtools
    ? dynamicRoles.map(item=>({value:item.id,label:item.name,code:item.code}))
    : LEGACY_ROLES.map(code=>({value:code,label:LEGACY_ROLE_LABELS[code]??code,code})),[isOrtools,dynamicRoles]);
  const locationOptions=useMemo(()=>isOrtools
    ? dynamicLocations.map(item=>({value:item.id,label:item.name,code:item.code}))
    : [{value:"KRUCZA",label:"Krucza",code:"KRUCZA"},{value:"PAWILONY",label:"Pawilony",code:"PAWILONY"}],[isOrtools,dynamicLocations]);
  const activeRoleLabels=useMemo(()=>Object.fromEntries(roleOptions.flatMap(item=>[
    [item.value,item.label],[item.code,item.label],[item.label,item.label],
  ])),[roleOptions]);
  const canReadCompanyWorkspace=Boolean(access?.roles?.some(item=>
    ["OWNER","ADMIN","HR_FINANCE","VERIFIER"].includes(item.app_role)
  ));

  const notify=(message:string)=>{setToast(message);window.setTimeout(()=>setToast(""),3200);};
  const load=useCallback(async()=>{
    if(!supabase||!user)return;
    const requestedMonth=selectedMonthDate;
    if(loadMonthRef.current!==requestedMonth)return;
    const token=++loadTokenRef.current;
    setLoading(true);setError("");setSolverConfiguration(null);setSolverConfigurationError("");
    const activeWorkspaceRequest=canReadCompanyWorkspace
      ? getActiveSolverWorkspace(supabase,requestedMonth)
        .then(workspace=>({workspace,error:null as Error|null}))
        .catch(cause=>({workspace:null,error:cause instanceof Error?cause:new Error(String(cause))}))
      : Promise.resolve({workspace:null,error:null as Error|null});
    const solverConfigurationRequest=loadSolverConfiguration(supabase,requestedMonth)
      .then(configuration=>({configuration,error:null as Error|null}))
      .catch(cause=>({configuration:null,error:cause instanceof Error?cause:new Error(String(cause))}));
    const [result,matrixResult,completeResult,matrixV2Result,employeeDirectoryResult,activeWorkspaceResult,solverConfigurationResult]=await Promise.all([
      supabase.rpc("plan_workspace",{p_month:requestedMonth,p_plan_id:null}),
      supabase.rpc("matrix_workspace",{p_month:requestedMonth}),
      supabase.rpc("complete_workspace",{p_month:requestedMonth}),
      supabase.rpc("matrix_v2_workspace",{p_month:requestedMonth}),
      supabase.rpc("matrix_v2_employee_directory_v2"),
      activeWorkspaceRequest,
      solverConfigurationRequest,
    ]);
    if(token!==loadTokenRef.current||loadMonthRef.current!==requestedMonth)return;
    const errors:string[]=[];
    const currentSolverConfiguration=solverConfigurationResult.configuration;
    if(solverConfigurationResult.error){
      const message=solverErrorMessage(solverConfigurationResult.error.message);
      setSolverConfigurationError(message);
      errors.push(`Konfiguracja generatora jest niedostępna: ${message}`);
    }else if(currentSolverConfiguration){
      setSolverConfiguration(currentSolverConfiguration);
      setPlanForm(current=>{
        if(currentSolverConfiguration.scenarios.some(scenario=>scenario.code===current.scenario))return current;
        const selected=currentSolverConfiguration.scenarios.find(scenario=>scenario.isDefault);
        return selected?{...current,scenario:selected.code}:current;
      });
    }
    const legacyData=(result.data||{
      plan:null,assignments:[],shifts:[],issues:[],events:[],
      budget:{amount:0,warning_percent:90,hard_limit:false}
    }) as Workspace;
    if(result.error)errors.push(result.error.message);
    if(currentSolverConfiguration?.engine==="ORTOOLS_V2"&&(isActiveOrtoolsWorkspace(activeWorkspaceResult.workspace)||isEmptyOrtoolsWorkspace(activeWorkspaceResult.workspace))){
      setData(mapSolverWorkspaceToOperational(activeWorkspaceResult.workspace,{events:[]}));
    }else if(currentSolverConfiguration?.engine==="ORTOOLS_V2"){
      setData({plan:null,assignments:[],shifts:[],issues:[],events:[],budget:{amount:0,warning_percent:100,hard_limit:false}});
      if(canReadCompanyWorkspace&&activeWorkspaceResult.error){
        errors.push(`Nie udało się pobrać obowiązującego grafiku OR-Tools: ${activeWorkspaceResult.error.message}`);
      }else if(canReadCompanyWorkspace&&activeWorkspaceResult.workspace){
        errors.push("Odczyt obowiązującego grafiku nie potwierdził aktywnego workspace OR-Tools.");
      }else if(canReadCompanyWorkspace){
        errors.push("Odczyt obowiązującego grafiku OR-Tools nie zwrócił wymaganego kontraktu.");
      }
    }else if(currentSolverConfiguration?.engine==="ALPHA15"||currentSolverConfiguration?.engine==="SHADOW"){
      setData(legacyData);
    }else{
      setData({plan:null,assignments:[],shifts:[],issues:[],events:legacyData.events,budget:{amount:0,warning_percent:100,hard_limit:false}});
    }
    if(!matrixResult.error&&matrixResult.data)setMatrix(matrixResult.data as MatrixWorkspace);
    if(!completeResult.error&&completeResult.data)setComplete(completeResult.data as CompleteWorkspace);
    if(completeResult.error&&completeResult.error.message!=="Could not find the function public.complete_workspace")errors.push(completeResult.error.message);
    if(!matrixV2Result.error&&matrixV2Result.data&&(matrixV2Result.data as MatrixV2Workspace).matrixVersion?.schema_version>=2){
      try{
        const workspace=matrixV2Result.data as MatrixV2Workspace;
        matrixV2Settings(workspace.matrixVersion);
        if(!employeeDirectoryResult.error&&employeeDirectoryResult.data){
          const directory=employeeDirectoryResult.data as MatrixV2EmployeeDirectory;
          setMatrixV2({...workspace,employees:directory.employees,
            workforceHash:directory.workforceHash,
            workforceCounts:{active:directory.activeCount,archived:directory.archivedCount}});
        }else setMatrixV2(workspace);
      }catch(cause){
        setMatrixV2(null);
        errors.push(matrixV2ErrorMessage(cause instanceof Error?cause.message:String(cause)));
      }
    }else{
      setMatrixV2(null);
      if(matrixV2Result.error&&currentSolverConfiguration?.engine==="ORTOOLS_V2")errors.push(matrixV2Result.error.message);
    }
    setError(errors.join(" • "));
    setLoading(false);
  },[supabase,user,selectedMonthDate,canReadCompanyWorkspace]);
  useEffect(()=>{void load();return()=>{loadTokenRef.current+=1};},[load]);
  useEffect(()=>{
    setDay("ALL");setModal(null);setSelectedShift(null);setSelectedEmployee("");
    setCandidates([]);setCandidateId("");setPlanScope({type:"COMPANY",role:null});
    setPlanForm(current=>({...current,name:`Plan operacyjny ${selectedMonth}`}));
    setEventForm(current=>({...current,date:`${selectedMonth}-15`}));
  },[selectedMonth]);
  useEffect(()=>{setModal(null);setSelectedShift(null);setCandidates([]);setCandidateId("");setPlanScope({type:"COMPANY",role:null});},[solverConfiguration?.engine]);
  useEffect(()=>{
    if(role!=="ALL"&&!roleOptions.some(option=>option.value===role))setRole("ALL");
    if(candidateRole&&!roleOptions.some(option=>option.code===candidateRole))setCandidateRole("");
    if(!candidateRole&&roleOptions[0])setCandidateRole(roleOptions[0].code);
  },[role,roleOptions,candidateRole]);
  useEffect(()=>{
    if(location!=="ALL"&&!locationOptions.some(option=>option.value===location))setLocation("ALL");
    setEventForm(current=>{
      const selected=locationOptions.find(option=>option.code===current.location);
      return selected||!locationOptions[0]?current:{...current,location:locationOptions[0].code};
    });
  },[location,locationOptions]);

  const openCompanyGenerator=()=>{
    if(!solverConfiguration){setError(`Generator jest zablokowany: ${solverConfigurationError||"brak poprawnej konfiguracji"}`);return;}
    if(solverConfiguration.engine!=="ALPHA15"&&!solverConfiguration.solverVersion?.trim()){setError("Generator jest zablokowany: konfiguracja nie wskazuje wymaganej wersji solvera.");return;}
    setPlanScope({type:"COMPANY",role:null});setModal("plan");
  };
  const openEvent=()=>{
    if(!solverConfiguration){setError(`Edycja eventu jest zablokowana: ${solverConfigurationError||"brak poprawnej konfiguracji"}`);return;}
    if(solverConfiguration.engine==="ORTOOLS_V2"){
      setActive("matrix");
      notify("W nowym silniku dodatkową obsadę i okresy specjalne konfigurujesz jako scenariusz w Matrixie.");
      return;
    }
    setModal("event");
  };
  const openRoleGenerator=(requestedRole:SolverRole)=>{
    if(!solverConfiguration){setError(`Generator jest zablokowany: ${solverConfigurationError||"brak poprawnej konfiguracji"}`);return;}
    if(!solverConfiguration.solverVersion?.trim()){setError("Generator roli jest zablokowany: konfiguracja nie wskazuje wymaganej wersji solvera.");return;}
    const dynamicRole=solverConfiguration.roles.find(item=>item.id===requestedRole.id||item.code===requestedRole.code);
    if(!dynamicRole){setError("Ta rola nie jest dostępna w aktywnej wersji Matrixa. Odśwież konfigurację i spróbuj ponownie.");return;}
    setPlanScope({type:"ROLE",role:dynamicRole});
    setPlanForm(current=>({...current,name:`Grafik ${dynamicRole.name} • ${selectedMonth}`}));
    setModal("plan");
  };

  const assignments=useMemo(()=>data.assignments.filter(a=>
    (location==="ALL"||(isOrtools?a.location_id===location:a.location===location))&&
    (role==="ALL"||(isOrtools?a.role_id===role:a.role===role))&&
    (day==="ALL"||a.date===day)&&(selectedEmployee===""||a.employee_id===selectedEmployee)
  ),[data.assignments,location,role,day,selectedEmployee,isOrtools]);
  const employees=useMemo(()=>{
    const map=new Map<string,{id:string;no:string;name:string;role:string;minutes:number;nominal:number;cost:number;shifts:number}>();
    for(const a of data.assignments){
      const x=map.get(a.employee_id)||{id:a.employee_id,no:a.employee_no,name:a.name,role:a.role_name??a.role,minutes:a.monthly_minutes,nominal:a.nominal_minutes,cost:0,shifts:0};
      x.cost+=Number(a.cost);x.shifts++;map.set(a.employee_id,x);
    }
    return [...map.values()].sort((a,b)=>b.minutes/Math.max(b.nominal,1)-a.minutes/Math.max(a.nominal,1));
  },[data.assignments]);
  const rolePlanningData=useMemo<CompleteWorkspace|null>(()=>{
    if(!complete||solverConfiguration?.engine!=="ORTOOLS_V2"||!solverConfiguration.roles.length)return complete;
    return {...complete,roles:solverConfiguration.roles.map(item=>({id:item.id,code:item.code,name:item.name,active:true}))};
  },[complete,solverConfiguration]);
  const shiftAssignments=selectedShift?data.assignments.filter(a=>a.shift_id===selectedShift.id):[];
  const totalMinutes=data.assignments.reduce((n,a)=>n+(new Date(a.ends_at).getTime()-new Date(a.starts_at).getTime())/60000,0);
  const cost=Number(data.plan?.total_cost||0);
  const budget=Number(data.budget?.amount||0);
  const coverage=data.shifts.length?Math.round(100*(1-Math.min(data.issues.filter(i=>i.issue_type==="SHORTAGE"||i.issue_type==="CAPABILITY_MISSING").length/data.shifts.length,1))):0;

  async function generateAlpha15() {
    if(!supabase||!solverConfiguration||!["ALPHA15","SHADOW"].includes(solverConfiguration.engine)){
      setError("Dotychczasowy generator nie jest aktywny w bieżącej konfiguracji.");return;
    }
    setBusy(true);setError("");setOptimizerProgress(0);
    let {data:{session},error:sessionError}=await supabase.auth.getSession();
    if(sessionError||!session){
      const refreshed=await supabase.auth.refreshSession();
      session=refreshed.data.session;
      sessionError=refreshed.error;
    }
    if(sessionError||!session?.access_token){
      setBusy(false);
      setError("Sesja wygasła. Wyloguj się i zaloguj ponownie, a następnie uruchom generator.");
      return;
    }
    const invoke=async(body:Record<string,unknown>)=>{
      const response=await supabase.functions.invoke("schedule-optimizer",{body,headers:{Authorization:`Bearer ${session!.access_token}`}});
      if(response.error)throw response.error;
      if(response.data?.error)throw new Error(response.data.error);
      return response.data;
    };
    let result:{data:any;error:null}|{data:null;error:Error};
    try{
      const start=await invoke({action:"START",month:selectedMonthDate,scenario:planForm.legacyScenario,profile:planForm.mode});
      let initializing=Boolean(start.initializing),initCursor=Number(start.initCursor||0),initTarget=Number(start.initTarget||8);
      while(initializing){
        const init=await invoke({action:"INIT",runId:start.runId});
        initializing=Boolean(init.initializing);initCursor=Number(init.initCursor||initCursor);initTarget=Number(init.initTarget||initTarget);
        setOptimizerProgress(Math.min(10,Math.round(10*initCursor/Math.max(1,initTarget))));
      }
      let generation=Number(start.generation||0),target=Number(start.targetGenerations||40);
      while(generation<target){
        const step=await invoke({action:"STEP",runId:start.runId});
        generation=Number(step.generation);target=Number(step.targetGenerations||target);
        setOptimizerProgress(Math.min(99,10+Math.round(89*generation/Math.max(1,target))));
      }
      let done=await invoke({action:"FINALIZE",runId:start.runId,name:planForm.name}),finalizeCalls=0;
      while(done.finalizing){
        if(finalizeCalls++>=5)throw new Error("FINALIZATION_DID_NOT_COMPLETE");
        setOptimizerProgress(Math.min(99,90+Math.round(9*Number(done.finalizeCursor||0)/Math.max(1,Number(done.finalizeTarget||3)))));
        done=await invoke({action:"FINALIZE",runId:start.runId,name:planForm.name});
      }
      result={data:done,error:null};setOptimizerProgress(100);
    }catch(e){result={data:null,error:e instanceof Error?e:new Error(String(e))};}
    setBusy(false);
    if(result.error){setError(result.error.message);return;}
    setModal(null);notify(`Plan zapisany: ${result.data.assignments} przydziałów, ${result.data.issues} alertów`);
    await load();setActive("grafik");
  }
  async function publish() {
    if(isOrtools){setError("Wariant OR-Tools publikuj wyłącznie w panelu nowego solvera po walidacji wersji i pochodzenia.");return;}
    if(!supabase||!data.plan)return;setBusy(true);
    const result=await supabase.rpc("publish_plan",{p_plan_id:data.plan.id});setBusy(false);
    if(result.error)setError(result.error.message);else{notify("Grafik został opublikowany");await load();}
  }
  async function createEvent() {
    if(!supabase||!solverConfiguration||solverConfiguration.engine==="ORTOOLS_V2"){
      setError("Event operacyjny można zapisać tą ścieżką wyłącznie dla jawnie aktywnego silnika Alpha 15 lub Shadow.");return;
    }
    setBusy(true);setError("");
    const endDate=eventForm.end<=eventForm.start?
      new Date(new Date(`${eventForm.date}T12:00:00`).getTime()+86400000).toISOString().slice(0,10):eventForm.date;
    const demand=roleOptions.map(item=>({
      role:item.code,shift_code:"WIECZOR",
      additional_count:Number(eventForm.demand[item.value]||0)
    })).filter(x=>x.additional_count>0);
    const result=await supabase.rpc("create_operational_event",{
      p_location:eventForm.location,p_event_type:eventForm.type,p_title:eventForm.title,
      p_description:eventForm.description,p_starts_at:localDateTimeToIso(eventForm.date,eventForm.start,activeTimezone),
      p_ends_at:localDateTimeToIso(endDate,eventForm.end,activeTimezone),
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
        <div><p className="eyebrow">OPERACJE / {selectedMonthLabel.toLocaleUpperCase("pl-PL")}</p><h1>{nav.find(x=>x[0]===active)?.[1]}</h1></div>
        <div className="topbar-actions">
          <button className={`live-status ${connected?"online":""}`} onClick={()=>{void refresh();void load();}}><Wifi size={15}/><span>Supabase • {summary?.employees||0} osób</span></button>
          <div className="month-selector" aria-label="Wybór miesiąca">
            <button type="button" aria-label="Poprzedni miesiąc" title="Poprzedni miesiąc" onClick={()=>setSelectedMonth(month=>adjacentMonth(month,-1))}><ChevronLeft size={17}/></button>
            <label className="date-selector" title="Wybierz miesiąc"><CalendarDays size={16}/><select aria-label="Wybierz miesiąc z listy" value={selectedMonth} onChange={e=>setSelectedMonth(e.target.value)}>{monthOptions.map(option=><option key={option.value} value={option.value}>{option.label}</option>)}</select></label>
            <button type="button" aria-label="Następny miesiąc" title="Następny miesiąc" onClick={()=>setSelectedMonth(month=>adjacentMonth(month,1))}><ChevronRight size={17}/></button>
          </div>
          {solverConfiguration&&!isOrtools&&<button className="secondary-button" onClick={openEvent}><Plus size={16}/> Event</button>}
          <button className="primary-button" disabled={!solverConfiguration} onClick={openCompanyGenerator}><WandSparkles size={17}/> Nowy wariant</button>
        </div>
      </header>
      {solverConfigurationError&&<div className="engine-error"><AlertTriangle size={18}/><span><strong>Generator jest zablokowany</strong>{solverConfigurationError}</span></div>}
      {error&&<div className="engine-error"><AlertTriangle size={18}/><span><strong>Operacja nie powiodła się</strong>{error}</span><button onClick={()=>setError("")}>×</button></div>}
      {loading?<div className="engine-loading"><RefreshCw className="spin"/><strong>Pobieram rzeczywisty grafik…</strong></div>:
      <div className="content">
        {active==="centrum"&&<>
          <section className="kpi-grid">
            <button className="kpi-card" onClick={()=>setActive("grafik")}><span className="kpi-icon violet"><Users/></span><span><small>Obsada</small><strong>{data.plan?`${coverage}%`:"—"}</strong><em>{data.plan?`${data.assignments.length} przydziałów`:"Brak planu"}</em></span></button>
            <button className="kpi-card" onClick={()=>setActive("alerty")}><span className="kpi-icon coral"><AlertTriangle/></span><span><small>Otwarte alerty</small><strong>{data.issues.length}</strong><em>{data.issues.filter(i=>i.severity==="CRITICAL").length} krytycznych</em></span></button>
            <button className="kpi-card" onClick={()=>setActive("budzet")}><span className="kpi-icon teal"><CircleDollarSign/></span><span><small>Koszt / budżet</small><strong>{data.plan&&budget?`${Math.round(cost/budget*100)}%`:"—"}</strong><em>{formatMoney(cost,activeCurrency)}</em></span></button>
            {isOrtools?<button className="kpi-card" onClick={()=>setActive("matrix")}><span className="kpi-icon orange"><Boxes/></span><span><small>Scenariusze Matrixa</small><strong>{solverConfiguration?.scenarios.length||0}</strong><em>bez legacy eventów</em></span></button>:<button className="kpi-card" onClick={()=>setActive("kalendarz")}><span className="kpi-icon orange"><CalendarDays/></span><span><small>Eventy</small><strong>{data.events.length}</strong><em>{data.events.filter(e=>e.status==="NEEDS_VERIFICATION").length} do weryfikacji</em></span></button>}
          </section>
          {!data.plan?<section className="empty-engine"><WandSparkles size={36}/><h2>Baza jest gotowa do pierwszego rzeczywistego planu</h2><p>Generator utworzy zmiany i przydziały w Supabase oraz sprawdzi role, lokalizacje, kompetencje, limity i {isOrtools?"scenariusze Matrixa":"eventy"}.</p><button className="primary-button" onClick={openCompanyGenerator}>Generuj plan</button></section>:
          <section className="live-overview">
            <div className="section-head"><div><p className="eyebrow">AKTYWNY WARIANT</p><h2>{data.plan.name} • v{data.plan.version}</h2></div><span className={`status-pill ${data.plan.status.toLowerCase()}`}>{planStatusLabels[data.plan.status]||data.plan.status}</span></div>
            <div className="overview-grid"><div><small>Scenariusz</small><strong>{isOrtools?data.plan.scenario_code:scenarioLabels[data.plan.scenario_code]||data.plan.scenario_code}</strong></div><div><small>Optymalizacja</small><strong>{isOrtools?data.plan.optimization_mode:modeLabels[data.plan.optimization_mode]||data.plan.optimization_mode}</strong></div><div><small>Zmiany</small><strong>{data.shifts.length}</strong></div><div><small>Roboczogodziny</small><strong>{Math.round(totalMinutes/60)}</strong></div></div>
            <div className="quick-actions"><button onClick={()=>setActive("grafik")}>Otwórz grafik <ChevronRight/></button><button onClick={()=>setActive("kadra")}>Pracownicy i archiwum <ChevronRight/></button><button onClick={()=>setActive("alerty")}>Rozwiąż alerty <ChevronRight/></button>{!isOrtools&&data.plan.status!=="PUBLISHED"&&<button className="publish" onClick={()=>void publish()}>Opublikuj wariant <Check/></button>}</div>
          </section>}
        </>}
        {(active==="grafik"||active==="generator")&&<ScheduleView data={data} assignments={assignments} location={location} role={role} day={day} setLocation={setLocation} setRole={setRole} setDay={setDay} onShift={(s)=>{setSelectedShift(s);setModal("shift");}} onGenerate={openCompanyGenerator} roleOptions={roleOptions} locationOptions={locationOptions} dynamic={isOrtools} timezone={activeTimezone} currency={activeCurrency}/>}
        {active==="zespoly"&&(!solverConfiguration?<div className="empty-engine"><AlertTriangle/><p>Generator zespołów jest zablokowany do czasu poprawnego odczytu konfiguracji.</p></div>:rolePlanningData&&<CompleteModules month={selectedMonth} view="rolePlans" data={rolePlanningData} reload={load} notify={notify} fail={setError} solverEngine={solverConfiguration.engine} solverVersion={solverConfiguration.solverVersion??undefined} solverScenarios={solverConfiguration.scenarios} solverRoles={solverConfiguration.roles} solverUserId={user?.id} roleCompositeRefreshKey={roleCompositeRefreshKey} timezone={activeTimezone} currency={activeCurrency} onOpenSolverV2={openRoleGenerator}/>)}
        {active==="matrix"&&(matrixV2?<MatrixV2Editor key={selectedMonthDate} month={selectedMonth} data={matrixV2} reload={load} notify={notify} fail={setError}/>:complete&&<CompleteModules month={selectedMonth} view="matrixAdmin" data={complete} reload={load} notify={notify} fail={setError} solverEngine={solverConfiguration?.engine} solverVersion={solverConfiguration?.solverVersion??undefined} solverRoles={solverConfiguration?.roles} timezone={activeTimezone} currency={activeCurrency}/>)}
        {active==="kalendarz"&&<MonthView month={selectedMonth} data={data} timezone={activeTimezone} onDay={(d)=>{setDay(d);setActive("grafik");}} onEvent={isOrtools?undefined:openEvent}/>}
        {isOrtools&&["kadra","hr","finanse"].includes(active)&&<section className="empty-engine"><Boxes size={36}/><h2>Matrix jest jedynym źródłem danych nowego silnika</h2><p>Profile pracowników, role, ograniczenia, stawki i budżety zmieniaj w wersji roboczej Matrixa. Dawne formularze nie zapisują danych używanych przez OR-Tools.</p><button className="primary-button" onClick={()=>setActive("matrix")}>Otwórz Matrix organizacji</button></section>}
        {active==="kadra"&&!isOrtools&&complete&&<CompleteModules month={selectedMonth} view="kadra" data={complete} reload={load} notify={notify} fail={setError} solverEngine={solverConfiguration?.engine} solverVersion={solverConfiguration?.solverVersion??undefined} solverRoles={solverConfiguration?.roles} timezone={activeTimezone} currency={activeCurrency}/>}
        {active==="hr"&&!isOrtools&&complete&&<CompleteModules month={selectedMonth} view="hr" data={complete} reload={load} notify={notify} fail={setError} solverEngine={solverConfiguration?.engine} solverVersion={solverConfiguration?.solverVersion??undefined} solverRoles={solverConfiguration?.roles} timezone={activeTimezone} currency={activeCurrency}/>}
        {active==="finanse"&&!isOrtools&&complete&&<CompleteModules month={selectedMonth} view="finanse" data={complete} reload={load} notify={notify} fail={setError} solverEngine={solverConfiguration?.engine} solverVersion={solverConfiguration?.solverVersion??undefined} solverRoles={solverConfiguration?.roles} timezone={activeTimezone} currency={activeCurrency}/>}
        {active==="portal"&&complete&&<CompleteModules month={selectedMonth} view="portal" data={complete} reload={load} notify={notify} fail={setError} solverEngine={solverConfiguration?.engine} solverVersion={solverConfiguration?.solverVersion??undefined} solverRoles={solverConfiguration?.roles} timezone={activeTimezone} currency={activeCurrency}/>}
        {active==="czas"&&complete&&<CompleteModules month={selectedMonth} view="czas" data={complete} reload={load} notify={notify} fail={setError} solverEngine={solverConfiguration?.engine} solverVersion={solverConfiguration?.solverVersion??undefined} solverRoles={solverConfiguration?.roles} timezone={activeTimezone} currency={activeCurrency}/>}
        {active==="integracje"&&complete&&<CompleteModules month={selectedMonth} view="integracje" data={complete} reload={load} notify={notify} fail={setError} solverEngine={solverConfiguration?.engine} solverVersion={solverConfiguration?.solverVersion??undefined} solverRoles={solverConfiguration?.roles} timezone={activeTimezone} currency={activeCurrency}/>}
        {active==="alerty"&&<IssuesView issues={data.issues} shifts={data.shifts} roleLabels={activeRoleLabels} onOpen={(s)=>{setSelectedShift(s);setModal("shift");}}/>}
        {active==="budzet"&&<BudgetView cost={cost} budget={budget} assignments={data.assignments} currency={activeCurrency} dynamic={isOrtools}/>}
      </div>}
    </section>
    {modal&&<><button className="drawer-scrim" onClick={()=>setModal(null)}/><aside className={`drawer ${modal==="plan"&&solverConfiguration?.engine!=="ALPHA15"?"solver-drawer":""}`}>
      <div className="drawer-head"><div><p className="eyebrow">GRAFIK PRO • OPERACJA</p><h2>{modal==="plan"?"Nowy wariant":modal==="event"?"Event / wyjątek":modal==="shift"?"Szczegóły zmiany":"Pracownik"}</h2></div><button className="icon-button" onClick={()=>setModal(null)}><X/></button></div>
      {modal==="plan"&&<div className="drawer-content">
        {!solverConfiguration&&<div className="solver-v2-notice warning"><AlertTriangle/>Generator pozostaje zablokowany, dopóki konfiguracja nie zostanie poprawnie odczytana.</div>}
        {solverConfiguration&&solverConfiguration.engine!=="ORTOOLS_V2"&&planScope.type==="COMPANY"&&<>
          {solverConfiguration.engine==="SHADOW"&&<div className="solver-shadow-note"><RefreshCw/><span><strong>Tryb cienia jest aktywny</strong><small>Alpha 15 pozostaje oficjalnym generatorem. Osobny test OR-Tools korzysta z niezmiennego snapshotu aktywnego Matrixa i nie może opublikować wyniku.</small></span></div>}
          <label>Nazwa<input value={planForm.name} onChange={e=>setPlanForm({...planForm,name:e.target.value})}/></label>
          <label>Scenariusz Alpha 15<select value={planForm.legacyScenario} onChange={e=>setPlanForm({...planForm,legacyScenario:e.target.value})}><option value="BASE">Bazowy</option><option value="EVENT">Eventowy</option><option value="SAVINGS">Oszczędny</option></select></label>
          <label>Tryb optymalizacji<select value={planForm.mode} onChange={e=>setPlanForm({...planForm,mode:e.target.value})}><option value="BALANCED">Zrównoważony</option><option value="MIN_COST">Minimalny koszt</option><option value="PREFERENCES">Preferencje</option></select></label>
          <div className="impact-box"><Settings/><span><strong>Sprawdzony silnik Alpha 15</strong><small>Pełny miesiąc • twarde reguły • zapis etapami • bezpieczny fallback</small></span></div>
          <button disabled={busy} className="primary-button full" onClick={()=>void generateAlpha15()}>{busy?`Optymalizuję pełny miesiąc… ${optimizerProgress}%`:"Znajdź najlepszy grafik"}</button>
        </>}
        {solverConfiguration&&solverConfiguration.engine!=="ALPHA15"&&user&&solverConfiguration.solverVersion&&<SolverV2Panel
          key={`${solverPanelVersion}:${solverConfiguration.solverVersion}:${selectedMonthDate}:${planForm.scenario}:${planScope.type}:${planScope.type==="ROLE"?planScope.role.id:"company"}`}
          engine={solverConfiguration.engine}
          solverVersion={solverConfiguration.solverVersion}
          userId={user.id}
          month={selectedMonthDate}
          timezone={solverTimezone}
          name={planForm.name}
          scenarioCode={planForm.scenario}
          scenarios={solverConfiguration.scenarios}
          scopeType={planScope.type}
          scopeRoleId={planScope.type==="ROLE"?planScope.role.id:null}
          scopeLabel={planScope.type==="ROLE"?`Grafik roli: ${planScope.role.name}`:"Grafik całej firmy"}
          allowStart={solverConfiguration.engine==="ORTOOLS_V2"||solverConfiguration.engine==="SHADOW"}
          onNameChange={value=>setPlanForm(current=>({...current,name:value}))}
          onScenarioChange={value=>setPlanForm(current=>({...current,scenario:value}))}
          onVariantSelected={variant=>{notify(`Wybrano wariant: ${variant.strategy.name}`);if(planScope.type==="ROLE")setRoleCompositeRefreshKey(current=>current+1);}}
          onPublished={async()=>{await load();notify("Opublikowany grafik OR-Tools jest teraz widoczny w głównym widoku.");setActive("grafik");}}
        />}
        {solverConfiguration&&solverConfiguration.engine!=="ALPHA15"&&user&&!solverConfiguration.solverVersion&&<div className="solver-v2-notice warning"><AlertTriangle/>Generator pozostaje zablokowany, ponieważ konfiguracja nie wskazuje wersji solvera.</div>}
      </div>}
      {modal==="event"&&!isOrtools&&<div className="drawer-content">
        <div className="form-row"><label>Lokal<select value={eventForm.location} onChange={e=>setEventForm({...eventForm,location:e.target.value})}>{locationOptions.map(item=><option value={item.code} key={item.value}>{item.label}</option>)}</select></label><label>Typ<select value={eventForm.type} onChange={e=>setEventForm({...eventForm,type:e.target.value})}><option>EVENT</option><option>CLEANING</option><option>INVENTORY</option><option>TRAINING</option><option>ADDITIONAL_SHIFT</option><option>CLOSURE</option></select></label></div>
        <label>Nazwa<input value={eventForm.title} onChange={e=>setEventForm({...eventForm,title:e.target.value})} placeholder="np. Event firmowy"/></label>
        <label>Opis<textarea value={eventForm.description} onChange={e=>setEventForm({...eventForm,description:e.target.value})}/></label>
        <div className="form-row"><label>Data<input type="date" value={eventForm.date} onChange={e=>setEventForm({...eventForm,date:e.target.value})}/></label><label>Od<input type="time" value={eventForm.start} onChange={e=>setEventForm({...eventForm,start:e.target.value})}/></label><label>Do<input type="time" value={eventForm.end} onChange={e=>setEventForm({...eventForm,end:e.target.value})}/></label></div>
        <div className="form-row"><label>Goście<input type="number" value={eventForm.guests} onChange={e=>setEventForm({...eventForm,guests:e.target.value})}/></label><label>Status<select value={eventForm.status} onChange={e=>setEventForm({...eventForm,status:e.target.value})}><option value="DRAFT">Szkic</option><option value="NEEDS_VERIFICATION">Do weryfikacji</option><option value="CONFIRMED">Potwierdzony</option></select></label></div>
        <h3>Dodatkowa obsada wieczorna</h3><div className="demand-inputs">{roleOptions.map(item=><label key={item.value}>{item.label}<input type="number" min="0" value={eventForm.demand[item.value]??"0"} onChange={e=>setEventForm(current=>({...current,demand:{...current.demand,[item.value]:e.target.value}}))}/></label>)}</div>
        <button disabled={busy||!eventForm.title} className="primary-button full" onClick={()=>void createEvent()}>{busy?"Zapisuję…":"Zapisz event i przelicz wpływ"}</button>
      </div>}
      {modal==="shift"&&selectedShift&&<div className="drawer-content">
        <div className="detail-status"><MapPin/><span><strong>{selectedShift.location_name??selectedShift.location_code} • {selectedShift.shift_name??selectedShift.shift_code}</strong><small>{fmtDate(selectedShift.shift_date)} • {fmtTime(selectedShift.starts_at,selectedShift.location_timezone??activeTimezone)}–{fmtTime(selectedShift.ends_at,selectedShift.location_timezone??activeTimezone)}</small></span></div>
        <h3>Przydzieleni pracownicy ({shiftAssignments.length})</h3>
        {shiftAssignments.map(a=><div className="person-row" key={a.id}><span className="avatar violet">{a.name.split(" ").map(x=>x[0]).join("")}</span><span><strong>{a.name}</strong><small>{a.role_name??activeRoleLabels[a.role]??a.role}{a.capability?` • ${a.capability}`:""}</small></span>{!isOrtools&&<em>{formatMoney(Number(a.cost),activeCurrency)}</em>}</div>)}
        {data.issues.filter(i=>i.shift_id===selectedShift.id).map(i=><div className={`issue-box ${i.severity.toLowerCase()}`} key={i.id}><AlertTriangle/><span><strong>{i.severity==="CRITICAL"?"Krytyczny":i.severity==="WARNING"?"Ostrzeżenie":"Informacja"}</strong>{issueMessage(i,activeRoleLabels)}</span></div>)}
        {!isOrtools&&<div className="emergency-panel">
          <h3>Awaryjnie dopisz pracownika</h3>
          <div className="form-row"><label>Rola<select value={candidateRole} onChange={e=>{setCandidateRole(e.target.value);setCandidates([]);setCandidateId("");}}>{roleOptions.map(item=><option value={item.code} key={item.value}>{item.label}</option>)}</select></label><button disabled={busy} className="secondary-button candidate-search" onClick={()=>void findCandidates()}>{busy?"Szukam…":"Znajdź kandydatów"}</button></div>
          {candidates.length>0&&<>
            <label>Kandydat<select value={candidateId} onChange={e=>setCandidateId(e.target.value)}><option value="">Wybierz osobę</option>{candidates.map(c=><option key={c.id} value={c.id} disabled={!c.eligible}>{c.name} • {c.employee_no}{c.can_close?" • zamyka zmianę":""}{c.overtime_only?" • nadgodziny":""}{!c.eligible?" • konflikt":""}</option>)}</select></label>
            <label className="check-label"><input type="checkbox" checked={notifyEmployee} onChange={e=>setNotifyEmployee(e.target.checked)}/> Powiadom pracownika w aplikacji (jeśli ma konto)</label>
            <button disabled={busy||!candidateId} className="danger-button full" onClick={()=>void emergencyAssign()}><Plus size={16}/> Dopisz awaryjnie</button>
          </>}
        </div>}
      </div>}
    </aside></>}
    {toast&&<div className="toast"><Check size={17}/>{toast}</div>}
  </main>;
}

type FilterOption={value:string;label:string;code:string};
function Filters({location,role,day,setLocation,setRole,setDay,roleOptions,locationOptions}:{location:string;role:string;day:string;setLocation:(x:string)=>void;setRole:(x:string)=>void;setDay:(x:string)=>void;roleOptions:FilterOption[];locationOptions:FilterOption[]}) {
  return <div className="live-filters"><Filter size={16}/><select value={location} onChange={e=>setLocation(e.target.value)}><option value="ALL">Wszystkie lokale</option>{locationOptions.map(item=><option value={item.value} key={item.value}>{item.label}</option>)}</select><select value={role} onChange={e=>setRole(e.target.value)}><option value="ALL">Wszystkie role</option>{roleOptions.map(item=><option value={item.value} key={item.value}>{item.label}</option>)}</select><input type="date" value={day==="ALL"?"":day} onChange={e=>setDay(e.target.value||"ALL")}/><button onClick={()=>{setLocation("ALL");setRole("ALL");setDay("ALL");}}>Wyczyść</button></div>;
}
function ScheduleView({data,assignments,location,role,day,setLocation,setRole,setDay,onShift,onGenerate,roleOptions,locationOptions,dynamic,timezone,currency}:{data:Workspace;assignments:Assignment[];location:string;role:string;day:string;setLocation:(x:string)=>void;setRole:(x:string)=>void;setDay:(x:string)=>void;onShift:(s:Shift)=>void;onGenerate:()=>void;roleOptions:FilterOption[];locationOptions:FilterOption[];dynamic:boolean;timezone:string;currency:string}) {
  const grouped=new Map<string,Assignment[]>();for(const a of assignments){const k=a.shift_id;grouped.set(k,[...(grouped.get(k)||[]),a]);}
  return <section className="live-module"><div className="section-head"><div><p className="eyebrow">DANE Z SUPABASE</p><h2>{data.plan?.name||"Brak wygenerowanego planu"}</h2></div><div><button className="secondary-button" onClick={()=>downloadCsv("grafik.csv",[["Data","Lokal","Zmiana","Od","Do","Pracownik","Rola","Obowiązki",`Koszt (${currency})`],...assignments.map(a=>[a.date,a.location_name??a.location,a.shift_name??a.shift_code,fmtTime(a.starts_at,a.location_timezone??timezone),fmtTime(a.ends_at,a.location_timezone??timezone),a.name,a.role_name??a.role,a.capability||"",dynamic?"":a.cost])])}><Download size={16}/> CSV</button><button className="primary-button" onClick={onGenerate}><Plus size={16}/> Wariant</button></div></div><Filters {...{location,role,day,setLocation,setRole,setDay,roleOptions,locationOptions}}/>
    {!data.plan?<div className="empty-engine"><p>Najpierw wygeneruj wariant.</p></div>:<div className="schedule-list">{data.shifts.filter(s=>(location==="ALL"||(dynamic?s.location_id===location:s.location_code===location))&&(day==="ALL"||s.shift_date===day)).map(s=>{const staff=(grouped.get(s.id)||[]).filter(a=>role==="ALL"||(dynamic?a.role_id===role:a.role===role));if(role!=="ALL"&&!staff.length)return null;return <button className="real-shift" key={s.id} onClick={()=>onShift(s)}><span className={`shift-code ${dynamic?"dynamic":s.shift_code.toLowerCase()}`}>{s.shift_name??s.shift_code}</span><span><strong>{fmtDate(s.shift_date,s.location_timezone??timezone)} • {s.location_name??s.location_code}</strong><small>{fmtTime(s.starts_at,s.location_timezone??timezone)}–{fmtTime(s.ends_at,s.location_timezone??timezone)}</small></span><div className="shift-avatars">{staff.slice(0,6).map(a=><i key={a.id} title={`${a.name} • ${a.role_name??a.role}`}>{a.name.split(" ").map(x=>x[0]).join("")}</i>)}{staff.length>6&&<b>+{staff.length-6}</b>}</div><strong>{staff.length} os.</strong><ChevronRight/></button>;})}</div>}
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

function MonthView({month,data,timezone,onDay,onEvent}:{month:string;data:Workspace;timezone:string;onDay:(d:string)=>void;onEvent?:()=>void}) {
  const first=new Date(`${month}-01T12:00:00Z`);const offset=(first.getUTCDay()+6)%7;const count=daysInMonth(month);const cells=Array.from({length:offset+count},(_,i)=>i<offset?0:i-offset+1);
  return <section className="live-module"><div className="section-head"><div><p className="eyebrow">KALENDARZ MENADŻERSKI</p><h2>{monthLabel(month,timezone)}</h2></div>{onEvent&&<button className="primary-button" onClick={onEvent}><Plus/> Event / wyjątek</button>}</div><div className="real-month"><div className="month-weekdays">{["Pon","Wt","Śr","Czw","Pt","Sob","Niedz"].map(x=><span key={x}>{x}</span>)}</div><div className="month-grid">{cells.map((n,i)=>{if(!n)return <span key={i}/>;const date=`${month}-${String(n).padStart(2,"0")}`;const ass=data.assignments.filter(a=>a.date===date);const ev=onEvent?data.events.filter(e=>e.starts_at.slice(0,10)===date):[];return <button key={date} className="month-day" onClick={()=>onDay(date)}><span className="day-number">{n}</span><div className="mini-people">{ass.slice(0,4).map(a=><span className="avatar violet" key={a.id}>{a.name.split(" ").map(x=>x[0]).join("")}</span>)}{ass.length>4&&<b>+{ass.length-4}</b>}</div>{ev.map(e=><span className="calendar-event orange" key={e.id}>{e.title}</span>)}<small>{ass.length} przydziałów</small></button>;})}</div></div></section>;
}
function EmployeeView({employees,onSelect}:{employees:{id:string;no:string;name:string;role:string;minutes:number;nominal:number;cost:number;shifts:number}[];selected:string;onSelect:(x:string)=>void}) {
  return <section className="live-module"><div className="section-head"><div><p className="eyebrow">OBCIĄŻENIE I SPRAWIEDLIWOŚĆ</p><h2>Widok per pracownik</h2></div><button className="secondary-button" onClick={()=>downloadCsv("pracownicy.csv",[["ID","Pracownik","Rola","Godziny","Nominał","Wykorzystanie","Zmiany","Koszt"],...employees.map(e=>[e.no,e.name,e.role,Math.round(e.minutes/60),Math.round(e.nominal/60),Math.round(e.minutes/Math.max(e.nominal,1)*100)+"%",e.shifts,Math.round(e.cost)])])}><Download/> CSV</button></div><div className="employee-table"><div className="table-head"><span>Pracownik</span><span>Rola</span><span>Godziny</span><span>Nominał</span><span>Wykorzystanie</span></div>{employees.map(e=>{const pct=Math.round(e.minutes/Math.max(e.nominal,1)*100);return <button key={e.id} onClick={()=>onSelect(e.id)}><span><strong>{e.name}</strong><small>{e.no} • {e.shifts} zmian</small></span><span>{LEGACY_ROLE_LABELS[e.role]??e.role}</span><strong>{Math.round(e.minutes/60)} h</strong><span>{Math.round(e.nominal/60)} h</span><span className={`load ${pct>110?"over":pct<70?"under":""}`}><i style={{width:`${Math.min(pct,130)}%`}}/>{pct}%</span></button>;})}</div></section>;
}
function IssuesView({issues,shifts,roleLabels,onOpen}:{issues:Issue[];shifts:Shift[];roleLabels:Record<string,string>;onOpen:(s:Shift)=>void}) {
  return <section className="live-module"><div className="section-head"><div><p className="eyebrow">WYNIK WALIDACJI</p><h2>{issues.length} aktywnych alertów</h2></div></div><div className="issues-list">{issues.length===0?<div className="success-box"><Check/><span><strong>Brak naruszeń</strong>Plan spełnia wszystkie obecne reguły.</span></div>:issues.map(i=><button key={i.id} className={`issue-row ${i.severity.toLowerCase()}`} onClick={()=>{const s=shifts.find(x=>x.id===i.shift_id);if(s)onOpen(s);}}><AlertTriangle/><span><strong>{issueLabels[i.issue_type]||i.issue_type} • {roleLabels[i.role_id??i.role??""]||i.role||"Cały plan"}</strong><small>{issueMessage(i,roleLabels)}</small></span><em>{i.assigned_count??"—"} / {i.required_count??"—"}</em><ChevronRight/></button>)}</div></section>;
}
function BudgetView({cost,budget,assignments,currency,dynamic}:{cost:number;budget:number;assignments:Assignment[];currency:string;dynamic:boolean}) {
  const byRole=[...new Map(assignments.map(a=>[a.role_id??a.role,{id:a.role_id??a.role,name:a.role_name??a.role}])).values()].map(item=>({role:item,cost:assignments.filter(a=>(a.role_id??a.role)===item.id).reduce((n,a)=>n+Number(a.cost),0)}));
  const percentage=budget?Math.round(cost/budget*100):0;
  return <section className="live-module"><div className="section-head"><div><p className="eyebrow">FINANSE PLANU</p><h2>{formatMoney(cost,currency)} / {budget?formatMoney(budget,currency):"brak budżetu"}</h2></div></div><div className="budget-hero"><strong>{budget?`${percentage}%`:"—"}</strong><div className="progress"><i style={{width:`${Math.min(percentage,100)}%`}}/></div><small>{budget?`Pozostało ${formatMoney(budget-cost,currency)}`:"Matrix nie zwrócił budżetu dla tego wariantu"}</small></div>{!dynamic&&<div className="role-costs">{byRole.map(x=><div key={x.role.id}><span>{LEGACY_ROLE_LABELS[x.role.name]??x.role.name}</span><strong>{formatMoney(x.cost,currency)}</strong><i style={{width:`${cost?x.cost/cost*100:0}%`}}/></div>)}</div>}</section>;
}
