"use client";

import {
  AlertTriangle, ArrowLeftRight, BarChart3, Bell, CalendarDays, Check, ChevronLeft, ChevronRight,
  CircleDollarSign, Clock3, Download, Edit3, Filter, Gauge, LogOut, MapPin,
  Menu, Plus, RefreshCw, Settings, ShieldCheck, Users, WandSparkles, Wifi, X, Boxes,
} from "lucide-react";
import type { LucideIcon } from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { usePathname, useRouter } from "next/navigation";
import { useAppAuth } from "@/components/AppAuthProvider";
import { ConfigurationJourney } from "@/components/ConfigurationJourney";
import { applicationEnvironmentLabel, createSupabaseBrowserClient, supabaseProjectRef } from "@/lib/supabase/client";
import {ActiveModules,type ActiveWorkspace} from "@/components/ActiveModules";
import {SolverV2Panel} from "@/components/SolverV2Panel";
import {SolverV2Workspace} from "@/components/SolverV2Workspace";
import {GeneratorV2Page} from "@/components/GeneratorV2Page";
import {MatrixV2Editor} from "@/components/MatrixV2Editor";
import {
  getOperationalSolverWorkspace,
  getManagerStandbyMonth,
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
  type SolverManagerStandby,
  type SolverWorkspace,
} from "@/lib/solver-v2";
import {matrixV2ErrorMessage,matrixV2Settings,type MatrixV2EmployeeDirectory,type MatrixV2Workspace} from "@/lib/matrix-v2";
import { employeeMatchesWorkforceQuery } from "@/lib/workforce-profile";
import {
  employeeNavigation,
  isEmployeePersona,
  managementNavigation,
  pathForSection,
  sectionFromPath,
  type ProductSection,
  type SetupFocus,
  type SetupSection,
  type SetupStepKey,
} from "@/lib/product-journey";
type NavKey = "centrum"|"generator"|"zespoly"|"matrix"|"grafik"|"kalendarz"|"kadra"|"hr"|"finanse"|"portal"|"czas"|"integracje"|"alerty"|"budzet";
type Modal = "plan"|"shift"|null;
type PlanScope = {type:"COMPANY";role:null}|{type:"ROLE";role:SolverRole};
type WorkforceCalendarEvent = {id:string;date:string;kind:"EVENT"|"HOT_DAY";title:string;locationName?:string|null};
type WorkforceCalendarContext = {events:WorkforceCalendarEvent[]};
type ShiftSwapAnnouncement = {id:string;date:string;status:string;shiftName:string;locationName:string;roleName:string;proposerName:string};
type ShiftSwapBoardContext = {requests?:ShiftSwapAnnouncement[]};

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
const productIcons: Record<ProductSection, LucideIcon> = {
  start: Gauge, team: Users, schedule: CalendarDays, operations: Bell, analytics: BarChart3, settings: Settings,
  "my-schedule": CalendarDays, "company-schedule": Users, availability: Clock3, swaps: ArrowLeftRight, messages: Bell, time: Clock3,
};
const legacySection: Record<NavKey, ProductSection> = {
  centrum:"start",kadra:"team",zespoly:"schedule",generator:"schedule",grafik:"schedule",
  kalendarz:"operations",portal:"operations",czas:"operations",integracje:"operations",alerty:"operations",
  budzet:"analytics",matrix:"settings",hr:"settings",finanse:"settings",
};

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
function csvCell(value:unknown) { return `"${String(value??"").replaceAll('"','""')}"`; }
function downloadCsv(name:string, rows:unknown[][]) {
  const blob=new Blob(["\ufeff"+rows.map(r=>r.map(csvCell).join(";")).join("\n")],{type:"text/csv;charset=utf-8"});
  const a=document.createElement("a"); a.href=URL.createObjectURL(blob); a.download=name; a.click(); URL.revokeObjectURL(a.href);
}

export default function GrafikPro() {
  const { user, access, connected, summary, refresh, signOut }=useAppAuth();
  const router=useRouter();
  const pathname=usePathname();
  const employeeShell=isEmployeePersona(access?.roles);
  const primarySection=sectionFromPath(pathname,employeeShell);
  const productNavigation=employeeShell?employeeNavigation:managementNavigation;
  const supabase=useMemo(()=>createSupabaseBrowserClient(),[]);
  const [data,setData]=useState<Workspace>({
    plan:null,assignments:[],shifts:[],issues:[],events:[],
    budget:{amount:0,warning_percent:90,hard_limit:false}
  });
  const [complete,setComplete]=useState<ActiveWorkspace|null>(null);
  const [matrixV2,setMatrixV2]=useState<MatrixV2Workspace|null>(null);
  const [operationalWorkspace,setOperationalWorkspace]=useState<SolverWorkspace|null>(null);
  const [managerStandby,setManagerStandby]=useState<SolverManagerStandby[]>([]);
  const [swapAnnouncements,setSwapAnnouncements]=useState<ShiftSwapAnnouncement[]>([]);
  const [workforceCalendar,setWorkforceCalendar]=useState<WorkforceCalendarContext>({events:[]});
  const [matrixFocusEmployeeId,setMatrixFocusEmployeeId]=useState<string|null>(null);
  const [matrixCreateEmployeeRequest,setMatrixCreateEmployeeRequest]=useState(0);
  const [loading,setLoading]=useState(true);
  const [busy,setBusy]=useState(false);
  const [solverConfiguration,setSolverConfiguration]=useState<SolverConfiguration|null>(null);
  const [solverConfigurationError,setSolverConfigurationError]=useState("");
  const [planScope,setPlanScope]=useState<PlanScope>({type:"COMPANY",role:null});
  const [solverPanelVersion,setSolverPanelVersion]=useState(0);
  const [roleCompositeRefreshKey,setRoleCompositeRefreshKey]=useState(0);
  const [error,setError]=useState("");
  const [toast,setToast]=useState("");
  const [active,setActiveState]=useState<NavKey>("centrum");
  const [configurationTab,setConfigurationTab]=useState<SetupSection>("structure");
  const [configurationStep,setConfigurationStep]=useState<SetupStepKey>("company");
  const [modal,setModal]=useState<Modal>(null);
  const [selectedShift,setSelectedShift]=useState<Shift|null>(null);
  const [selectedEmployee,setSelectedEmployee]=useState("");
  const [location,setLocation]=useState("ALL");
  const [role,setRole]=useState("ALL");
  const [day,setDay]=useState("ALL");
  const [selectedMonth,setSelectedMonth]=useState(DEFAULT_MONTH);
  const selectedMonthDate=monthDate(selectedMonth);
  const loadTokenRef=useRef(0),loadMonthRef=useRef(selectedMonthDate);loadMonthRef.current=selectedMonthDate;
  const [planForm,setPlanForm]=useState({name:`Plan operacyjny ${DEFAULT_MONTH}`,scenario:""});
  const isOrtools=solverConfiguration?.engine==="ORTOOLS_V2";
  const environmentLabel=applicationEnvironmentLabel();
  const projectRef=supabaseProjectRef();
  const activeTimezone=isOrtools?solverConfiguration?.timezone??"": "Europe/Warsaw";
  const activeCurrency=isOrtools?solverConfiguration?.currency??"": "PLN";
  const solverTimezone=solverConfiguration?.engine==="SHADOW"?solverConfiguration.timezone??"":activeTimezone;
  const selectedMonthLabel=monthLabel(selectedMonth);
  const setActive=useCallback((next:NavKey)=>{
    setActiveState(next);
    const section=legacySection[next];
    if(sectionFromPath(pathname,employeeShell)!==section)router.push(pathForSection(section));
  },[employeeShell,pathname,router]);
  const openProductSection=useCallback((section:ProductSection)=>{
    const managementDefaults:Partial<Record<ProductSection,NavKey>>={start:"centrum",team:"kadra",schedule:"zespoly",operations:"alerty",analytics:"budzet",settings:"matrix"};
    if(!employeeShell)setActiveState(managementDefaults[section]??"centrum");
    router.push(pathForSection(section));
  },[employeeShell,router]);
  const openSetupStep=useCallback((section:SetupSection,step:SetupStepKey,focus?:SetupFocus)=>{
    setConfigurationTab(section);setConfigurationStep(step);setMatrixFocusEmployeeId(focus?.employeeId??null);setActive("matrix");
    const targetId=focus?.targetId??`configuration-step-${step}`;
    const alignStep=(behavior:ScrollBehavior)=>{
      const target=document.getElementById(targetId);
      target?.scrollIntoView({behavior,block:"start"});
      if(focus?.employeeId&&targetId.startsWith("matrix-v2-rate-")){
        target?.querySelector<HTMLInputElement>('input[name="amount"]')?.focus({preventScroll:true});
      }
    };
    window.setTimeout(()=>alignStep("smooth"),220);
    // Readiness data and editor panels hydrate independently. Re-align after they
    // settle so content inserted above the target cannot move it out of view.
    window.setTimeout(()=>alignStep("auto"),900);
    window.setTimeout(()=>alignStep("auto"),1800);
  },[setActive]);
  const openEmployeeProfile=useCallback((employeeId:string)=>{
    window.sessionStorage.setItem("grafik-pro:matrix-v2:employee-request",JSON.stringify({kind:"employee",employeeId}));
    setMatrixCreateEmployeeRequest(0);setMatrixFocusEmployeeId(employeeId);setConfigurationTab("workforce");setConfigurationStep("employees");setActiveState("matrix");
    router.push(`${pathForSection("settings")}?employee=${encodeURIComponent(employeeId)}`);
  },[router]);
  const openNewEmployeeProfile=useCallback(()=>{
    window.sessionStorage.setItem("grafik-pro:matrix-v2:employee-request",JSON.stringify({kind:"new"}));
    setMatrixFocusEmployeeId(null);setConfigurationTab("workforce");setConfigurationStep("employees");setMatrixCreateEmployeeRequest(current=>current+1);setActiveState("matrix");
    router.push(`${pathForSection("settings")}?employee=new`);
  },[router]);
  const markNewEmployeeProfileOpened=useCallback(()=>setMatrixCreateEmployeeRequest(0),[]);
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
    const solverConfigurationResult=await loadSolverConfiguration(supabase,requestedMonth)
      .then(configuration=>({configuration,error:null as Error|null}))
      .catch(cause=>({configuration:null,error:cause instanceof Error?cause:new Error(String(cause))}));
    if(token!==loadTokenRef.current||loadMonthRef.current!==requestedMonth)return;
    const currentSolverConfiguration=solverConfigurationResult.configuration;
    const readsLegacyPlan=currentSolverConfiguration?.engine==="ALPHA15"||currentSolverConfiguration?.engine==="SHADOW";
    const legacyPlanRequest=readsLegacyPlan
      ? supabase.rpc("plan_workspace",{p_month:requestedMonth,p_plan_id:null})
      : Promise.resolve({data:null,error:null});
    const activeWorkspaceRequest=currentSolverConfiguration?.engine==="ORTOOLS_V2"&&canReadCompanyWorkspace
      ? getOperationalSolverWorkspace(supabase,requestedMonth)
        .then(workspace=>({workspace,error:null as Error|null}))
        .catch(cause=>({workspace:null,error:cause instanceof Error?cause:new Error(String(cause))}))
      : Promise.resolve({workspace:null,error:null as Error|null});
    const standbyRequest=currentSolverConfiguration?.engine==="ORTOOLS_V2"&&canReadCompanyWorkspace
      ? getManagerStandbyMonth(supabase,requestedMonth).then(rows=>({rows,error:null as Error|null})).catch(cause=>({rows:[],error:cause instanceof Error?cause:new Error(String(cause))}))
      : Promise.resolve({rows:[],error:null as Error|null});
    const swapBoardRequest=currentSolverConfiguration?.engine==="ORTOOLS_V2"&&canReadCompanyWorkspace
      ? supabase.rpc("shift_swap_board_uat_v2",{p_month:requestedMonth})
      : Promise.resolve({data:null,error:null});
    const [result,completeResult,matrixV2Result,employeeDirectoryResult,calendarResult,activeWorkspaceResult,standbyResult,swapBoardResult]=await Promise.all([
      legacyPlanRequest,
      supabase.rpc("complete_workspace",{p_month:requestedMonth}),
      supabase.rpc("matrix_v2_workspace",{p_month:requestedMonth}),
      supabase.rpc("matrix_v2_employee_directory_alpha16",{p_month:requestedMonth}),
      supabase.rpc("workforce_calendar_context_uat_v3",{p_month:requestedMonth}),
      activeWorkspaceRequest,
      standbyRequest,
      swapBoardRequest,
    ]);
    if(token!==loadTokenRef.current||loadMonthRef.current!==requestedMonth)return;
    const errors:string[]=[];
    setManagerStandby(standbyResult.rows);
    setSwapAnnouncements(((swapBoardResult.data as ShiftSwapBoardContext|null)?.requests??[]).filter(request=>["OPEN","EMPLOYEE_ACCEPTED"].includes(request.status)));
    if(standbyResult.error&&canReadCompanyWorkspace)errors.push(`Nie udało się pobrać stand-by: ${standbyResult.error.message}`);
    if(swapBoardResult.error&&canReadCompanyWorkspace)errors.push(`Nie udało się pobrać ogłoszeń zamiany: ${swapBoardResult.error.message}`);
    if(solverConfigurationResult.error){
      const message=solverErrorMessage(solverConfigurationResult.error.message);
      setSolverConfigurationError(message);
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
      setOperationalWorkspace(activeWorkspaceResult.workspace);
      setData(mapSolverWorkspaceToOperational(activeWorkspaceResult.workspace,{events:[]}));
    }else if(currentSolverConfiguration?.engine==="ORTOOLS_V2"){
      setOperationalWorkspace(null);
      setData({plan:null,assignments:[],shifts:[],issues:[],events:[],budget:{amount:0,warning_percent:100,hard_limit:false}});
      if(canReadCompanyWorkspace&&activeWorkspaceResult.error){
        errors.push(`Nie udało się pobrać obowiązującego grafiku OR-Tools: ${activeWorkspaceResult.error.message}`);
      }else if(canReadCompanyWorkspace&&activeWorkspaceResult.workspace){
        errors.push("Odczyt obowiązującego grafiku nie potwierdził aktywnego workspace OR-Tools.");
      }else if(canReadCompanyWorkspace){
        errors.push("Odczyt obowiązującego grafiku OR-Tools nie zwrócił wymaganego kontraktu.");
      }
    }else if(currentSolverConfiguration?.engine==="ALPHA15"||currentSolverConfiguration?.engine==="SHADOW"){
      setOperationalWorkspace(null);
      setData(legacyData);
    }else{
      setOperationalWorkspace(null);
      setData({plan:null,assignments:[],shifts:[],issues:[],events:legacyData.events,budget:{amount:0,warning_percent:100,hard_limit:false}});
    }
    if(!completeResult.error&&completeResult.data)setComplete(completeResult.data as ActiveWorkspace);
    if(completeResult.error
      &&completeResult.error.message!=="Could not find the function public.complete_workspace"
      &&!completeResult.error.message.includes("EMPLOYEE_ACCOUNT_NOT_LINKED")){
      errors.push(completeResult.error.message);
    }
    if(!calendarResult.error&&calendarResult.data)setWorkforceCalendar(calendarResult.data as WorkforceCalendarContext);
    else{
      setWorkforceCalendar({events:[]});
      if(calendarResult.error)errors.push(`Nie udało się pobrać eventów i HOT DAY: ${calendarResult.error.message}`);
    }
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
    if(employeeShell){setActiveState("portal");return;}
    const defaults:Record<string,NavKey>={start:"centrum",team:"kadra",schedule:"zespoly",operations:"alerty",analytics:"budzet",settings:"matrix"};
    setActiveState(current=>legacySection[current]===primarySection?current:defaults[primarySection]??"centrum");
  },[employeeShell,primarySection]);
  useEffect(()=>{
    setDay("ALL");setModal(null);setSelectedShift(null);setSelectedEmployee("");
    setPlanScope({type:"COMPANY",role:null});
    setPlanForm(current=>({...current,name:`Plan operacyjny ${selectedMonth}`}));
  },[selectedMonth]);
  useEffect(()=>{setModal(null);setSelectedShift(null);setPlanScope({type:"COMPANY",role:null});},[solverConfiguration?.engine]);
  useEffect(()=>{
    if(role!=="ALL"&&!roleOptions.some(option=>option.value===role))setRole("ALL");
  },[role,roleOptions]);
  useEffect(()=>{
    if(location!=="ALL"&&!locationOptions.some(option=>option.value===location))setLocation("ALL");
  },[location,locationOptions]);

  const openCompanyGenerator=()=>{
    if(!solverConfiguration){setError(`Generator jest zablokowany: ${solverConfigurationError||"brak poprawnej konfiguracji"}`);return;}
    if(solverConfiguration.engine!=="ALPHA15"&&!solverConfiguration.solverVersion?.trim()){setError("Generator jest zablokowany: konfiguracja nie wskazuje wymaganej wersji solvera.");return;}
    setPlanScope({type:"COMPANY",role:null});setActive("generator");
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
  const rolePlanningData=useMemo<ActiveWorkspace|null>(()=>{
    if(!complete||solverConfiguration?.engine!=="ORTOOLS_V2"||!solverConfiguration.roles.length)return complete;
    return {...complete,roles:solverConfiguration.roles.map(item=>({id:item.id,code:item.code,name:item.name,active:true}))};
  },[complete,solverConfiguration]);
  const shiftAssignments=selectedShift?data.assignments.filter(a=>a.shift_id===selectedShift.id):[];
  const totalMinutes=data.assignments.reduce((n,a)=>n+(new Date(a.ends_at).getTime()-new Date(a.starts_at).getTime())/60000,0);
  const cost=Number(data.plan?.total_cost||0);
  const budget=Number(data.budget?.amount||0);
  const coverage=data.shifts.length?Math.round(100*(1-Math.min(data.issues.filter(i=>i.issue_type==="SHORTAGE"||i.issue_type==="CAPABILITY_MISSING").length/data.shifts.length,1))):0;

  const activeNavigation=productNavigation.find(item=>item.key===primarySection)??productNavigation[0];
  const employeePortalSection=primarySection==="company-schedule"?"company-schedule":primarySection==="availability"?"availability":primarySection==="swaps"?"swaps":"my-schedule";

  return <main className="app-shell product-shell" data-persona={employeeShell?"employee":"management"}>
    <aside className="sidebar product-sidebar">
      <div className="brand"><span>GP</span><div><strong>GRAFIK PRO</strong><small>PLANOWANIE I OPERACJE</small></div></div>
      <div className="persona-pill">{employeeShell?<><Users/> PANEL PRACOWNIKA</>:<><ShieldCheck/> PANEL ZARZĄDZAJĄCY</>}</div>
      <nav>{productNavigation.map(item=>{const Icon=productIcons[item.key];return <button key={item.key} className={primarySection===item.key?"active":""} onClick={()=>openProductSection(item.key)}><Icon/><span>{item.label}</span><small>{item.description}</small></button>;})}</nav>
      <div className="sidebar-footer">
        <div className="profile"><span>{(user?.email||"GP").slice(0,2).toUpperCase()}</span><div><strong>{access?.employee?`${access.employee.first_name} ${access.employee.last_name}`:user?.email}</strong><small>{({OWNER:"Właściciel",ADMIN:"Administrator",HR_FINANCE:"Kadry i finanse",ROLE_MANAGER:"Menadżer roli",LOCATION_MANAGER:"Menadżer lokalu",VERIFIER:"Weryfikator",EMPLOYEE:"Pracownik"} as Record<string,string>)[access?.roles?.[0]?.app_role||""]||"Użytkownik"}</small></div></div>
        <button className="sidebar-signout" onClick={()=>void signOut()}><LogOut size={15}/> Wyloguj się</button>
      </div>
    </aside>
    <section className="workspace">
      <header className="topbar">
        <button className="icon-button menu-button"><Menu size={20}/></button>
        <div className="product-topbar-copy"><p className="eyebrow">{employeeShell?"MOJE SPRAWY":"ZARZĄDZANIE"} / {selectedMonthLabel.toLocaleUpperCase("pl-PL")}</p><h1>{activeNavigation.label}</h1><small>{activeNavigation.description}</small></div>
        <div className="topbar-actions">
          <button className={`live-status environment-status ${connected?"online":""}`} onClick={()=>{void refresh();void load();}} title={`Projekt Supabase: ${projectRef}`}><Wifi size={15}/><span><b>{environmentLabel}</b><small>{projectRef} • konfiguracja {matrixV2?`v${matrixV2.matrixVersion.version} ${matrixV2.editable?"robocza":"aktywna"}`:"niedostępna"} • {matrixV2?.workforceCounts?.active??summary?.employees??0} osób</small></span></button>
          <div className="month-selector" aria-label="Wybór miesiąca">
            <button type="button" aria-label="Poprzedni miesiąc" title="Poprzedni miesiąc" onClick={()=>setSelectedMonth(month=>adjacentMonth(month,-1))}><ChevronLeft size={17}/></button>
            <label className="date-selector" title="Wybierz miesiąc"><CalendarDays size={16}/><select aria-label="Wybierz miesiąc z listy" value={selectedMonth} onChange={e=>setSelectedMonth(e.target.value)}>{monthOptions.map(option=><option key={option.value} value={option.value}>{option.label}</option>)}</select></label>
            <button type="button" aria-label="Następny miesiąc" title="Następny miesiąc" onClick={()=>setSelectedMonth(month=>adjacentMonth(month,1))}><ChevronRight size={17}/></button>
          </div>
          {!employeeShell&&<button className="primary-button" disabled={!solverConfiguration} onClick={openCompanyGenerator}><WandSparkles size={17}/> Nowy wariant</button>}
        </div>
      </header>
      {solverConfigurationError&&<div className="engine-error"><AlertTriangle size={18}/><span><strong>Generator jest zablokowany</strong>{solverConfigurationError}</span></div>}
      {error&&<div className="engine-error"><AlertTriangle size={18}/><span><strong>Operacja nie powiodła się</strong>{error}</span><button onClick={()=>setError("")}>×</button></div>}
      {loading?<div className="engine-loading"><RefreshCw className="spin"/><strong>Pobieram rzeczywisty grafik…</strong></div>:
      <div className="content">
        {employeeShell?<>
          {primarySection==="messages"&&<section className="feature-coming-card"><Bell/><h2>Wiadomości zespołu są następnym rozszerzeniem portalu</h2><p>Ten moduł pozostaje jawnie nieaktywny w pierwszym vertical slice. Nie udajemy działającej komunikacji, dopóki nie ma wersjonowanych rozmów, powiadomień i pełnego E2E.</p></section>}
          {primarySection==="time"&&complete&&<ActiveModules month={selectedMonth} view="czas" data={complete} reload={load} notify={notify} fail={setError} solverEngine={solverConfiguration?.engine} solverVersion={solverConfiguration?.solverVersion??undefined} solverRoles={solverConfiguration?.roles} timezone={activeTimezone} currency={activeCurrency}/>} 
          {["my-schedule","company-schedule","availability","swaps"].includes(primarySection)&&complete&&<ActiveModules month={selectedMonth} view="portal" portalSection={employeePortalSection} data={complete} reload={load} notify={notify} fail={setError} solverEngine={solverConfiguration?.engine} solverVersion={solverConfiguration?.solverVersion??undefined} solverRoles={solverConfiguration?.roles} timezone={activeTimezone} currency={activeCurrency}/>} 
          {!complete&&primarySection!=="messages"&&<section className="empty-engine"><AlertTriangle/><h2>Portal nie ma jeszcze kompletnego kontekstu</h2><p>Odśwież dane albo poproś właściciela o powiązanie konta z profilem pracownika.</p></section>}
        </>:<>
        {primarySection==="schedule"&&<ContextTabs items={[["zespoly","1. Grafiki ról"],["generator","2. Scal i porównaj grafik firmy"],["grafik","3. Opublikowany grafik"]]} active={active} select={setActive}/>} 
        {primarySection==="operations"&&<ContextTabs items={[["alerty","Alerty"],["kalendarz","Kalendarz"],["portal","Podgląd pracownika"],["integracje","Eksport"]]} active={active} select={setActive}/>} 
        {active==="centrum"&&<>
          {matrixV2&&<ConfigurationJourney compact data={matrixV2} month={selectedMonth} onOpenStep={openSetupStep} onCreateSchedule={()=>setActive("zespoly")}/>} 
          <section className="kpi-grid">
            <button className="kpi-card" onClick={()=>setActive("grafik")}><span className="kpi-icon violet"><Users/></span><span><small>Obsada</small><strong>{data.plan?`${coverage}%`:"—"}</strong><em>{data.plan?`${data.assignments.length} przydziałów`:"Brak planu"}</em></span></button>
            <button className="kpi-card" onClick={()=>setActive("alerty")}><span className="kpi-icon coral"><AlertTriangle/></span><span><small>Otwarte alerty</small><strong>{data.issues.length}</strong><em>{data.issues.filter(i=>i.severity==="CRITICAL").length} krytycznych</em></span></button>
            <button className="kpi-card" onClick={()=>setActive("budzet")}><span className="kpi-icon teal"><CircleDollarSign/></span><span><small>Koszt / budżet</small><strong>{data.plan&&budget?`${Math.round(cost/budget*100)}%`:"—"}</strong><em>{formatMoney(cost,activeCurrency)}</em></span></button>
            {isOrtools?<button className="kpi-card" onClick={()=>openSetupStep("strategies","variants")}><span className="kpi-icon orange"><Boxes/></span><span><small>Warianty biznesowe</small><strong>{solverConfiguration?.scenarios.length||0}</strong><em>w aktywnej konfiguracji</em></span></button>:<button className="kpi-card" onClick={()=>setActive("kalendarz")}><span className="kpi-icon orange"><CalendarDays/></span><span><small>Eventy</small><strong>{data.events.length}</strong><em>{data.events.filter(e=>e.status==="NEEDS_VERIFICATION").length} do weryfikacji</em></span></button>}
          </section>
          {!data.plan?<section className="empty-engine"><WandSparkles size={36}/><h2>{matrixV2?"Dokończ konfigurację albo utwórz pierwszy plan":"Baza jest gotowa do pierwszego rzeczywistego planu"}</h2><p>Generator sprawdzi role, lokalizacje, kompetencje, limity i {isOrtools?"warianty biznesowe":"eventy"}. Jeśli czegoś brakuje, prowadzona konfiguracja wskaże dokładne miejsce naprawy.</p><button className="primary-button" onClick={openCompanyGenerator}>Generuj plan</button></section>:
          <section className="live-overview">
            <div className="section-head"><div><p className="eyebrow">AKTYWNY WARIANT</p><h2>{data.plan.name} • v{data.plan.version}</h2></div><span className={`status-pill ${data.plan.status.toLowerCase()}`}>{planStatusLabels[data.plan.status]||data.plan.status}</span></div>
            <div className="overview-grid"><div><small>Scenariusz</small><strong>{isOrtools?data.plan.scenario_code:scenarioLabels[data.plan.scenario_code]||data.plan.scenario_code}</strong></div><div><small>Optymalizacja</small><strong>{isOrtools?data.plan.optimization_mode:modeLabels[data.plan.optimization_mode]||data.plan.optimization_mode}</strong></div><div><small>Zmiany</small><strong>{data.shifts.length}</strong></div><div><small>Roboczogodziny</small><strong>{Math.round(totalMinutes/60)}</strong></div></div>
            <div className="quick-actions"><button onClick={()=>setActive("grafik")}>Otwórz grafik <ChevronRight/></button><button onClick={()=>setActive("kadra")}>Pracownicy i archiwum <ChevronRight/></button><button onClick={()=>setActive("alerty")}>Rozwiąż alerty <ChevronRight/></button></div>
          </section>}
        </>}
        {active==="generator"&&solverConfiguration&&solverConfiguration.engine!=="ALPHA15"&&user&&<GeneratorV2Page configuration={solverConfiguration} userId={user.id} month={selectedMonthDate} timezone={solverTimezone} notify={notify} fail={setError} onPublished={async()=>{await load();setActive("grafik");}}/>}
        {active==="generator"&&solverConfiguration?.engine==="ALPHA15"&&<section className="empty-engine"><AlertTriangle/><h2>Nowy generator czeka na kontrolowane przełączenie</h2><p>Interfejs Alpha 15 nie jest już rozwijany. Uruchamianie nowych wariantów zostanie odblokowane po wdrożeniu workera OR-Tools, sekretu gatewaya i zmianie flagi silnika.</p></section>}
        {active==="grafik"&&isOrtools&&operationalWorkspace&&<SolverV2Workspace workspace={operationalWorkspace} timezone={activeTimezone} published operational notify={notify} fail={setError} onOperationalChanged={load}/>}
        {active==="grafik"&&isOrtools&&!operationalWorkspace&&<section className="empty-engine"><CalendarDays/><h2>Brak opublikowanego grafiku operacyjnego</h2><p>W Generatorze wybierz gotowy wariant, przejrzyj analizę i opublikuj go jako osobną wersję operacyjną.</p><button className="primary-button" onClick={()=>setActive("generator")}>Otwórz Generator i warianty</button></section>}
        {active==="grafik"&&!isOrtools&&<ScheduleView data={data} assignments={assignments} location={location} role={role} day={day} setLocation={setLocation} setRole={setRole} setDay={setDay} onShift={(s)=>{setSelectedShift(s);setModal("shift");}} onGenerate={()=>setActive("generator")} roleOptions={roleOptions} locationOptions={locationOptions} dynamic={false} timezone={activeTimezone} currency={activeCurrency}/>}
        {active==="zespoly"&&<>
          <section className="schedule-role-first-intro">
            <span>ETAP 1 Z 3 • GRAFIKI RÓL</span>
            <h2>Najpierw przygotuj i zatwierdź grafik każdej roli</h2>
            <p>Każdy lider przegląda swój grafik roli. Dopiero po akceptacji ról przejdź do etapu 2, aby scalić je w jeden grafik firmy i porównać warianty.</p>
          </section>
          {!solverConfiguration?<div className="empty-engine"><AlertTriangle/><p>Generator grafików ról jest zablokowany do czasu poprawnego odczytu konfiguracji.</p></div>:rolePlanningData&&<ActiveModules month={selectedMonth} view="rolePlans" data={rolePlanningData} reload={load} notify={notify} fail={setError} solverEngine={solverConfiguration.engine} solverVersion={solverConfiguration.solverVersion??undefined} solverMatrixEffectiveFrom={solverConfiguration.matrixEffectiveFrom??undefined} solverScenarios={solverConfiguration.scenarios} solverRoles={solverConfiguration.roles} solverUserId={user?.id} roleCompositeRefreshKey={roleCompositeRefreshKey} timezone={activeTimezone} currency={activeCurrency} onOpenSolverV2={openRoleGenerator}/>} 
        </>}
        {active==="matrix"&&matrixV2&&<><ConfigurationJourney data={matrixV2} month={selectedMonth} onOpenStep={openSetupStep} onCreateSchedule={openCompanyGenerator}/><MatrixV2Editor key={`${selectedMonthDate}:${matrixFocusEmployeeId??""}:${configurationStep}`} initialTab={configurationTab} month={selectedMonth} data={matrixV2} reload={load} notify={notify} fail={setError} focusEmployeeId={matrixFocusEmployeeId} createEmployeeRequest={matrixCreateEmployeeRequest} onCreateEmployeeOpened={markNewEmployeeProfileOpened}/></>}
        {active==="matrix"&&!matrixV2&&<section className="empty-engine"><AlertTriangle/><h2>Konfiguracja firmy jest niedostępna</h2><p>Odśwież dane albo sprawdź migracje UAT. Aplikacja nie przełączy się po cichu na konkurencyjne źródło danych.</p></section>}
        {active==="kalendarz"&&<MonthView month={selectedMonth} data={data} events={workforceCalendar.events} standby={managerStandby} swaps={swapAnnouncements} timezone={activeTimezone} onDay={(d)=>{setDay(d);setActive("grafik");}}/>}
        {active==="kadra"&&matrixV2&&<WorkforceCatalog data={matrixV2} onEdit={openEmployeeProfile} onAdd={openNewEmployeeProfile}/>}
        {["hr","finanse"].includes(active)&&matrixV2&&<MatrixDestination section={active==="hr"?"dane kadrowe i ograniczenia":"stawki, dodatki i budżety"} open={()=>{setMatrixFocusEmployeeId(null);setActive("matrix");}}/>}
        {active==="portal"&&complete&&<ActiveModules month={selectedMonth} view="portal" data={complete} reload={load} notify={notify} fail={setError} solverEngine={solverConfiguration?.engine} solverVersion={solverConfiguration?.solverVersion??undefined} solverRoles={solverConfiguration?.roles} timezone={activeTimezone} currency={activeCurrency}/>}
        {active==="czas"&&complete&&<ActiveModules month={selectedMonth} view="czas" data={complete} reload={load} notify={notify} fail={setError} solverEngine={solverConfiguration?.engine} solverVersion={solverConfiguration?.solverVersion??undefined} solverRoles={solverConfiguration?.roles} timezone={activeTimezone} currency={activeCurrency}/>}
        {active==="integracje"&&complete&&<ActiveModules month={selectedMonth} view="integracje" data={complete} reload={load} notify={notify} fail={setError} solverEngine={solverConfiguration?.engine} solverVersion={solverConfiguration?.solverVersion??undefined} solverRoles={solverConfiguration?.roles} timezone={activeTimezone} currency={activeCurrency}/>}
        {active==="alerty"&&isOrtools&&operationalWorkspace&&<SolverV2Workspace workspace={operationalWorkspace} timezone={activeTimezone} published operational notify={notify} fail={setError} onOperationalChanged={load}/>}
        {active==="alerty"&&!isOrtools&&<IssuesView issues={data.issues} shifts={data.shifts} roleLabels={activeRoleLabels} onOpen={(s)=>{setSelectedShift(s);setModal("shift");}}/>}
        {active==="budzet"&&<BudgetView cost={cost} budget={budget} assignments={data.assignments} currency={activeCurrency} dynamic={isOrtools}/>} 
        </>}
      </div>}
    </section>
    {modal&&<><button className="drawer-scrim" onClick={()=>setModal(null)}/><aside className={`drawer ${modal==="plan"?"solver-drawer":""}`}>
      <div className="drawer-head"><div><p className="eyebrow">GRAFIK PRO • OPERACJA</p><h2>{modal==="plan"?"Nowy wariant":"Szczegóły zmiany"}</h2></div><button className="icon-button" onClick={()=>setModal(null)}><X/></button></div>
      {modal==="plan"&&<div className="drawer-content">
        {!solverConfiguration&&<div className="solver-v2-notice warning"><AlertTriangle/>Generator pozostaje zablokowany, dopóki konfiguracja nie zostanie poprawnie odczytana.</div>}
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
          matrixEffectiveFrom={solverConfiguration.matrixEffectiveFrom}
          allowStart={solverConfiguration.engine==="ORTOOLS_V2"||solverConfiguration.engine==="SHADOW"}
          onNameChange={value=>setPlanForm(current=>({...current,name:value}))}
          onScenarioChange={value=>setPlanForm(current=>({...current,scenario:value}))}
          onVariantSelected={variant=>{notify(`Wybrano wariant: ${variant.strategy.name}`);if(planScope.type==="ROLE")setRoleCompositeRefreshKey(current=>current+1);}}
          onPublished={async()=>{await load();notify("Opublikowany grafik OR-Tools jest teraz widoczny w głównym widoku.");setActive("grafik");}}
        />}
        {solverConfiguration&&solverConfiguration.engine!=="ALPHA15"&&user&&!solverConfiguration.solverVersion&&<div className="solver-v2-notice warning"><AlertTriangle/>Generator pozostaje zablokowany, ponieważ konfiguracja nie wskazuje wersji solvera.</div>}
        {solverConfiguration?.engine==="ALPHA15"&&<div className="solver-v2-notice warning"><AlertTriangle/>Tworzenie nowych grafików Alpha 15 zostało usunięte. Przełącz kontrolowanie OR-Tools, aby uruchamiać warianty.</div>}
      </div>}
      {modal==="shift"&&selectedShift&&<div className="drawer-content">
        <div className="detail-status"><MapPin/><span><strong>{selectedShift.location_name??selectedShift.location_code} • {selectedShift.shift_name??selectedShift.shift_code}</strong><small>{fmtDate(selectedShift.shift_date)} • {fmtTime(selectedShift.starts_at,selectedShift.location_timezone??activeTimezone)}–{fmtTime(selectedShift.ends_at,selectedShift.location_timezone??activeTimezone)}</small></span></div>
        <h3>Przydzieleni pracownicy ({shiftAssignments.length})</h3>
        {shiftAssignments.map(a=><div className="person-row" key={a.id}><span className="avatar violet">{a.name.split(" ").map(x=>x[0]).join("")}</span><span><strong>{a.name}</strong><small>{a.role_name??activeRoleLabels[a.role]??a.role}{a.capability?` • ${a.capability}`:""}</small></span>{!isOrtools&&<em>{formatMoney(Number(a.cost),activeCurrency)}</em>}</div>)}
        {data.issues.filter(i=>i.shift_id===selectedShift.id).map(i=><div className={`issue-box ${i.severity.toLowerCase()}`} key={i.id}><AlertTriangle/><span><strong>{i.severity==="CRITICAL"?"Krytyczny":i.severity==="WARNING"?"Ostrzeżenie":"Informacja"}</strong>{issueMessage(i,activeRoleLabels)}</span></div>)}
        {!isOrtools&&<div className="solver-v2-notice warning"><AlertTriangle/>Ten grafik jest dostępny wyłącznie do odczytu podczas migracji. Awaryjne przypisanie działa tylko w opublikowanym grafiku OR-Tools, z pełną diagnostyką kandydata.</div>}
      </div>}
    </aside></>}
    {toast&&<div className="toast"><Check size={17}/>{toast}</div>}
  </main>;
}

type FilterOption={value:string;label:string;code:string};
function ContextTabs({items,active,select}:{items:[NavKey,string][];active:NavKey;select:(key:NavKey)=>void}){
  return <nav className="product-section-tabs" aria-label="Widoki modułu">{items.map(([key,label])=><button type="button" key={key} className={active===key?"active":""} onClick={()=>select(key)}>{label}</button>)}</nav>;
}
function WorkforceCatalog({data,onEdit,onAdd}:{data:MatrixV2Workspace;onEdit:(employeeId:string)=>void;onAdd:()=>void}){
  const [query,setQuery]=useState("");
  const roleName=(employeeId:string)=>{
    const primary=data.employeeRoles.find(item=>item.employee_id===employeeId&&item.active&&item.is_primary)??data.employeeRoles.find(item=>item.employee_id===employeeId&&item.active);
    return data.roles.find(item=>item.id===primary?.role_id)?.name??"Brak roli";
  };
  const locationNames=(employeeId:string)=>data.employeeLocations.filter(item=>item.employee_id===employeeId&&item.active&&item.standard_allowed).map(item=>data.locations.find(location=>location.id===item.location_id)?.name).filter(Boolean).join(", ")||"Brak lokalu";
  const rows=data.employees.filter(employee=>employeeMatchesWorkforceQuery(data,employee,query));
  return <section className="workforce-catalog"><header><div><p className="eyebrow">ZESPÓŁ • JEDNO ŹRÓDŁO DANYCH</p><h2>Pracownicy</h2><p>W jednym profilu edytujesz dane, umowę, role, lokale, kompetencje, limity, dostępność i stawki.</p></div><div className="workforce-catalog-actions"><span className="matrix-v2-version">WERSJA ROBOCZA v{data.matrixVersion.version}</span>{data.editable&&<button className="primary-button" onClick={onAdd}><Plus/> Dodaj pracownika</button>}</div></header><label className="workforce-catalog-search"><Users/><input value={query} onChange={event=>setQuery(event.target.value)} placeholder="Połącz kryteria: imię, numer, rola, lokal lub obowiązek"/></label><div className="workforce-catalog-list">{rows.map(employee=>{const flexible=["ZLECENIE","B2B"].includes(employee.contractType??"")&&employee.workTimePolicy!=="CUSTOM";return <article className={employee.active?"":"archived"} key={employee.id}><span className="avatar violet">{`${employee.firstName[0]??""}${employee.lastName[0]??""}`}</span><span><small>{employee.employeeNo}</small><strong>{employee.firstName} {employee.lastName}</strong></span><span><small>Rola</small><b>{roleName(employee.id)}</b></span><span><small>Zwykłe lokale</small><b>{locationNames(employee.id)}</b></span><span><small>{flexible?"Uzgodniony pułap (informacyjny)":"Twardy limit miesięczny"}</small><b>{Math.round(employee.maximumMonthlyMinutes/60)} godz.{flexible?" • nie blokuje silnika":""}</b></span><button className="secondary-button" onClick={()=>onEdit(employee.id)}><Edit3/> Otwórz profil</button></article>})}{!rows.length&&<p className="solver-workspace-empty">Nie znaleziono pracowników.</p>}</div></section>;
}
function MatrixDestination({section,open}:{section:string;open:()=>void}){
  return <section className="empty-engine"><Boxes size={36}/><h2>Matrix jest jedynym miejscem edycji</h2><p>Przejdź do Matrixa, aby zmienić {section}. Dzięki temu generator, grafik operacyjny, portal i katalog pracowników zawsze czytają te same dane.</p><button className="primary-button" onClick={open}>Otwórz Matrix organizacji</button></section>;
}
function Filters({location,role,day,setLocation,setRole,setDay,roleOptions,locationOptions}:{location:string;role:string;day:string;setLocation:(x:string)=>void;setRole:(x:string)=>void;setDay:(x:string)=>void;roleOptions:FilterOption[];locationOptions:FilterOption[]}) {
  return <div className="live-filters"><Filter size={16}/><select value={location} onChange={e=>setLocation(e.target.value)}><option value="ALL">Wszystkie lokale</option>{locationOptions.map(item=><option value={item.value} key={item.value}>{item.label}</option>)}</select><select value={role} onChange={e=>setRole(e.target.value)}><option value="ALL">Wszystkie role</option>{roleOptions.map(item=><option value={item.value} key={item.value}>{item.label}</option>)}</select><input type="date" value={day==="ALL"?"":day} onChange={e=>setDay(e.target.value||"ALL")}/><button onClick={()=>{setLocation("ALL");setRole("ALL");setDay("ALL");}}>Wyczyść</button></div>;
}
function ScheduleView({data,assignments,location,role,day,setLocation,setRole,setDay,onShift,onGenerate,roleOptions,locationOptions,dynamic,timezone,currency}:{data:Workspace;assignments:Assignment[];location:string;role:string;day:string;setLocation:(x:string)=>void;setRole:(x:string)=>void;setDay:(x:string)=>void;onShift:(s:Shift)=>void;onGenerate:()=>void;roleOptions:FilterOption[];locationOptions:FilterOption[];dynamic:boolean;timezone:string;currency:string}) {
  const grouped=new Map<string,Assignment[]>();for(const a of assignments){const k=a.shift_id;grouped.set(k,[...(grouped.get(k)||[]),a]);}
  return <section className="live-module"><div className="section-head"><div><p className="eyebrow">DANE Z SUPABASE</p><h2>{data.plan?.name||"Brak wygenerowanego planu"}</h2></div><div><button className="secondary-button" onClick={()=>downloadCsv("grafik.csv",[["Data","Lokal","Zmiana","Od","Do","Pracownik","Rola","Obowiązki",`Koszt (${currency})`],...assignments.map(a=>[a.date,a.location_name??a.location,a.shift_name??a.shift_code,fmtTime(a.starts_at,a.location_timezone??timezone),fmtTime(a.ends_at,a.location_timezone??timezone),a.name,a.role_name??a.role,a.capability||"",dynamic?"":a.cost])])}><Download size={16}/> CSV</button><button className="primary-button" onClick={onGenerate}><Plus size={16}/> Wariant</button></div></div><Filters {...{location,role,day,setLocation,setRole,setDay,roleOptions,locationOptions}}/>
    {!data.plan?<div className="empty-engine"><p>Najpierw wygeneruj wariant.</p></div>:<div className="schedule-list">{data.shifts.filter(s=>(location==="ALL"||(dynamic?s.location_id===location:s.location_code===location))&&(day==="ALL"||s.shift_date===day)).map(s=>{const staff=(grouped.get(s.id)||[]).filter(a=>role==="ALL"||(dynamic?a.role_id===role:a.role===role));if(role!=="ALL"&&!staff.length)return null;return <button className="real-shift" key={s.id} onClick={()=>onShift(s)}><span className={`shift-code ${dynamic?"dynamic":s.shift_code.toLowerCase()}`}>{s.shift_name??s.shift_code}</span><span><strong>{fmtDate(s.shift_date,s.location_timezone??timezone)} • {s.location_name??s.location_code}</strong><small>{fmtTime(s.starts_at,s.location_timezone??timezone)}–{fmtTime(s.ends_at,s.location_timezone??timezone)}</small></span><div className="shift-avatars">{staff.slice(0,6).map(a=><i key={a.id} title={`${a.name} • ${a.role_name??a.role}`}>{a.name.split(" ").map(x=>x[0]).join("")}</i>)}{staff.length>6&&<b>+{staff.length-6}</b>}</div><strong>{staff.length} os.</strong><ChevronRight/></button>;})}</div>}
  </section>;
}
function MonthView({month,data,events,standby,swaps,timezone,onDay}:{month:string;data:Workspace;events:WorkforceCalendarEvent[];standby:SolverManagerStandby[];swaps:ShiftSwapAnnouncement[];timezone:string;onDay:(d:string)=>void}) {
  const first=new Date(`${month}-01T12:00:00Z`);const offset=(first.getUTCDay()+6)%7;const count=daysInMonth(month);const cells=Array.from({length:offset+count},(_,i)=>i<offset?0:i-offset+1);
  return <section className="live-module"><div className="section-head"><div><p className="eyebrow">KALENDARZ MENADŻERSKI</p><h2>{monthLabel(month,timezone)}</h2></div></div><div className="real-month"><div className="month-weekdays">{["Pon","Wt","Śr","Czw","Pt","Sob","Niedz"].map(x=><span key={x}>{x}</span>)}</div><div className="month-grid">{cells.map((n,i)=>{if(!n)return <span key={i}/>;const date=`${month}-${String(n).padStart(2,"0")}`;const ass=data.assignments.filter(a=>a.date===date);const dayEvents=events.filter(event=>event.date===date);const dayStandby=standby.filter(item=>item.date===date&&item.status!=="DECLINED");const daySwaps=swaps.filter(item=>item.date===date);return <button key={date} className={`month-day ${dayEvents.some(event=>event.kind==="HOT_DAY")?"has-hot-day":""} ${daySwaps.length?"has-swap-announcement":""}`} onClick={()=>onDay(date)}><span className="day-number">{n}</span>{daySwaps.length>0&&<span className="manager-calendar-swap"><ArrowLeftRight/><b>ZAMIANA</b>{daySwaps.length} aktywna</span>}{dayEvents.map(event=><span key={event.id} className={`manager-calendar-event ${event.kind.toLowerCase()}`}><b>{event.kind==="HOT_DAY"?"HOT DAY":"EVENT"}</b>{event.title}</span>)}{dayStandby.length>0&&<span className="manager-calendar-standby"><b>STAND-BY • {dayStandby.length}</b>{dayStandby.slice(0,2).map(item=><small key={item.id}>T{item.tier} • {item.employeeName} • {item.roleName}{item.status==="ACTIVATED"?" • aktywowany":""}</small>)}{dayStandby.length>2&&<small>+{dayStandby.length-2} kolejnych</small>}</span>}<div className="mini-people">{ass.slice(0,4).map(a=><span className="avatar violet" key={a.id}>{a.name.split(" ").map(x=>x[0]).join("")}</span>)}{ass.length>4&&<b>+{ass.length-4}</b>}</div><small>{ass.length} przydziałów</small></button>;})}</div></div></section>;
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
