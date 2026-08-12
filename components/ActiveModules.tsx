"use client";

import {
  AlertTriangle,
  ArrowLeftRight,
  CalendarDays,
  Download,
  Flame,
  Megaphone,
  Plus,
  Save,
  ShieldCheck,
  UserRound,
  WandSparkles,
  X,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { CSSProperties } from "react";
import * as XLSX from "xlsx";

import {
  getEmployeePublishedSchedule,
  type SolverEmployeePublishedAssignment,
  type SolverEmployeeStandby,
  type SolverEngine,
  type SolverRole,
  type SolverRoleCategory,
} from "@/lib/solver-v2";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";

function roleCardStyle(value:string,color?:string|null):CSSProperties{
  if(color && /^#[0-9a-f]{6}$/i.test(color)){
    return {"--role-color":color,"--role-soft":`${color}18`} as CSSProperties;
  }
  let hash=0x811c9dc5;
  for(const character of value){hash^=character.charCodeAt(0);hash=Math.imul(hash,0x01000193)>>>0;}
  const hue=hash%360;
  return {"--role-color":`hsl(${hue} 62% 47%)`,"--role-soft":`hsl(${hue} 72% 95%)`} as CSSProperties;
}

export type AdminEmployee = {
  id: string;
  employeeNo: string;
  firstName: string;
  lastName: string;
  email: string;
  primaryRole: string;
  nominalMinutes: number;
  maxWeeklyMinutes: number;
  maxMonthlyMinutes: number;
  active: boolean;
  locations: { code: string; name: string; home: boolean; standard: boolean; overtime: boolean }[];
  capabilities: { id: string; capability: string; role?: string; location?: string }[];
};

export type MatrixItem = {
  id: string;
  code: string;
  name: string;
  color?: string;
  description?: string;
  active: boolean;
};

export type ActiveWorkspace = {
  counts: { employees: number; archivedEmployees: number; roleManagers: number; locations: number };
  employees: AdminEmployee[];
  activeMatrix?: { id: string; version: number; name: string; status: string };
  draftMatrix?: { id: string; version: number; name: string; status: string };
  roles: MatrixItem[];
  functions: MatrixItem[];
  locations: MatrixItem[];
  shifts: MatrixItem[];
  demand: unknown[];
  sections: unknown[];
  budget: { amount?: number; warning_percent?: number; hard_limit?: boolean };
  preferences: unknown[];
  integrationRuns: { id: string; integration: string; direction: string; status: string; file_name?: string; created_at: string }[];
  timeRecords: unknown[];
};

type PortalAssignment = SolverEmployeePublishedAssignment & { locationTimezone?: string };
type PortalTimeConstraint = {
  id: string;
  kind: string;
  startsAt: string;
  endsAt: string;
  source: string;
  editable: boolean;
  note?: string | null;
  preferredLocationId?: string | null;
};
type PortalTimeConstraintsWorkspace = {
  employeeId: string;
  timezone: string;
  defaultAvailable?: boolean;
  constraints: PortalTimeConstraint[];
};
type ShiftPreferenceLevel = "PREFERRED" | "NEUTRAL" | "AVOIDED";
type ShiftPeriod = "MORNING" | "MIDDLE" | "EVENING";
type PortalShiftPreferences = {
  employeeId: string;
  month: string;
  employee: Record<ShiftPeriod, ShiftPreferenceLevel>;
  effective: Record<string, string>;
  managerOverrides: Record<string, string>;
};
type WorkforceCalendarEvent = {
  id: string;
  date: string;
  kind: "EVENT" | "HOT_DAY";
  title: string;
  description?: string | null;
  locationId?: string | null;
  locationName?: string | null;
  demands?: { id: string; shiftTemplateId: string; shiftName: string; roleId: string; roleName: string; dutyId?: string | null; additionalCount: number }[];
  hotLimits?: { roleId: string; roleName: string; maximumHardUnavailable: number }[];
};
type WorkforceCalendarContext = {
  month: string;
  matrixVersionId?: string;
  canManage?: boolean;
  roles?: { id: string; name: string; code: string }[];
  locations?: { id: string; name: string; code: string }[];
  shiftTemplates?: { id: string; name: string; code: string; locationId: string; startsAt: string; endsAt: string; endsNextDay: boolean; dayMask: number[] }[];
  events: WorkforceCalendarEvent[];
  pendingReviews: { id: string; employeeId: string; employeeName: string; employeeNo: string; date: string; roleId: string; roleName: string; status: string; note?: string | null; requestedAt: string }[];
  availabilitySummary?: { date:string; roleId:string; roleName:string; totalCount?:number; availableCount?:number; recordedCount?:number; progressPercent?:number; lastUpdatedAt?:string|null; hardCount:number; softCount:number; pendingCount:number; hardEmployees:string[]; softEmployees:string[]; pendingEmployees:string[] }[];
};
type ShiftSwapRequest = {
  id: string;
  status: string;
  message?: string | null;
  assignmentId: string;
  date: string;
  startsAt: string;
  endsAt: string;
  locationName: string;
  shiftName: string;
  roleId: string;
  roleName: string;
  proposerEmployeeId: string;
  proposerName: string;
  targetEmployeeId?: string | null;
  acceptedByEmployeeId?: string | null;
  eligible: boolean;
  ineligibilityReasons: string[];
  isMine: boolean;
  requiresLeaderDecision: boolean;
  targetName?: string | null;
  acceptedByName?: string | null;
  history?: { id: number; action: string; actorName: string; createdAt: string; details?: Record<string, unknown> }[];
};
type ShiftSwapBoard = { employeeId?: string | null; month: string; canManage?: boolean; requests: ShiftSwapRequest[] };
type ShiftSwapCandidate = { employeeId: string; employeeNo: string; name: string; eligible: boolean; reasons: string[] };
type CompanyCalendarAssignment = {
  id: string; date: string; startsAt: string; endsAt: string;
  locationId: string; locationName: string; shiftName: string;
  roleId: string; roleName: string; employeeId: string;
  employeeName: string; employeeNo: string; isSwap: boolean; swapAuditId?: string | null;
};
type CompanyCalendar = { month: string; assignments: CompanyCalendarAssignment[] };
type UatMasterEmployee = {
  id: string;
  employeeNo: string;
  name: string;
  roleId?: string | null;
  roleName?: string | null;
  roleCode?: string | null;
};
type UatMasterPreview = {
  enabled: boolean;
  matrixVersionId?: string | null;
  matrixVersion?: number | null;
  employees: UatMasterEmployee[];
};
type PortalWorkspace = {
  employee?: {
    id: string;
    employeeNo: string;
    firstName: string;
    lastName: string;
    primaryRole: string;
    locations: { code: string; name: string }[];
  };
  assignments: PortalAssignment[];
  standby: SolverEmployeeStandby[];
  attendance: { id: string; action: string; occurredAt: string; location: string }[];
  timeConstraints?: PortalTimeConstraintsWorkspace;
  shiftPreferences?: PortalShiftPreferences;
  calendarContext?: WorkforceCalendarContext;
  swapBoard?: ShiftSwapBoard;
  companyCalendar?: CompanyCalendar;
  publicationConflict?: boolean;
  masterPersona?: boolean;
};
type UatMasterPortalContext = Omit<PortalWorkspace, "assignments"> & {
  assignments: CompanyCalendarAssignment[];
};

type View = "rolePlans" | "portal" | "czas" | "integracje";
export type EmployeePortalSection = "overview" | "my-schedule" | "company-schedule" | "availability" | "swaps";
const days = ["Pon", "Wt", "Śr", "Czw", "Pt", "Sob", "Niedz"];
const rolePl: Record<string, string> = {
  KELNER: "Kelner",
  BARMAN: "Barman",
  PIZZABAR: "Pizzabar",
  PREP: "Prep",
  POMOC: "Pomoc",
};

export function ActiveModules({
  month,
  view,
  data,
  reload,
  notify,
  fail,
  solverEngine,
  solverVersion,
  solverMatrixEffectiveFrom,
  solverRoleCategories = [],
  solverRoles = [],
  timezone,
  onOpenSolverV2,
  portalSection = "overview",
  allowUatMasterPersona = false,
}: {
  month: string;
  view: View;
  data: ActiveWorkspace;
  reload: () => Promise<void>;
  notify: (message: string) => void;
  fail: (message: string) => void;
  solverEngine?: SolverEngine;
  solverVersion?: string;
  solverMatrixEffectiveFrom?: string;
  solverRoleCategories?: SolverRoleCategory[];
  solverRoles?: SolverRole[];
  timezone: string;
  currency: string;
  onOpenSolverV2?: (category: SolverRoleCategory) => void;
  portalSection?: EmployeePortalSection;
  allowUatMasterPersona?: boolean;
}) {
  const selectedMonthDate = `${month}-01`;
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const [busy, setBusy] = useState(false);
  const [portal, setPortal] = useState<PortalWorkspace | null>(null);
  const [availabilityOpen, setAvailabilityOpen] = useState(false);
  const [shiftPreferencesOpen, setShiftPreferencesOpen] = useState(false);
  const [operationalContext, setOperationalContext] = useState<WorkforceCalendarContext | null>(null);
  const [uatMaster, setUatMaster] = useState<UatMasterPreview | null>(null);
  const [uatMasterEmployeeId, setUatMasterEmployeeId] = useState<string | null>(null);
  const [uatMasterSearch, setUatMasterSearch] = useState("");
  const rolePlanningEnabled = solverEngine === "ORTOOLS_V2" || solverEngine === "SHADOW";
  const portalLoadToken = useRef(0);
  const portalMonthRef = useRef(selectedMonthDate);
  portalMonthRef.current = selectedMonthDate;
  const dynamicRoleNames = useMemo(
    () => Object.fromEntries(solverRoles.flatMap((role) => [[role.id, role.name], [role.code, role.name], [role.name, role.name]])),
    [solverRoles],
  );
  const dynamicRoleColors = useMemo(
    () => Object.fromEntries(solverRoles.flatMap((role) => [[role.id, role.color ?? ""], [role.code, role.color ?? ""], [role.name, role.color ?? ""]])),
    [solverRoles],
  );

  const rpc = useCallback(async (name: string, args: Record<string, unknown>) => {
    if (!supabase) return undefined;
    setBusy(true);
    const result = await supabase.rpc(name, args);
    setBusy(false);
    if (result.error) {
      fail(translateError(result.error.message));
      return undefined;
    }
    return result.data ?? true;
  }, [fail, supabase]);

  useEffect(() => {
    if (!supabase || view !== "portal" || !allowUatMasterPersona) {
      setUatMaster(null);
      setUatMasterEmployeeId(null);
      setUatMasterSearch("");
      return;
    }
    let current = true;
    void supabase.rpc("uat_master_persona_preview_v2").then((result) => {
      if (!current || result.error || !result.data) return;
      const preview = result.data as UatMasterPreview;
      if (preview.enabled) setUatMaster({ ...preview, employees: preview.employees || [] });
    });
    return () => { current = false; };
  }, [allowUatMasterPersona, supabase, view]);

  const loadPortal = useCallback(async () => {
    const requestedMonth = selectedMonthDate;
    if (!supabase || view !== "portal" || portalMonthRef.current !== requestedMonth) return;
    const token = ++portalLoadToken.current;
    if (uatMasterEmployeeId) {
      const [contextResult, calendarResult] = await Promise.all([
        supabase.rpc("uat_master_employee_portal_context_v2", {
          p_employee_id: uatMasterEmployeeId,
          p_month: requestedMonth,
        }),
        supabase.rpc("workforce_calendar_context_uat_v3", { p_month: requestedMonth }),
      ]);
      if (token !== portalLoadToken.current || portalMonthRef.current !== requestedMonth) return;
      if (contextResult.error || !contextResult.data) {
        fail(`Nie udało się otworzyć widoku pracownika w trybie MASTER: ${translateError(contextResult.error?.message || "Brak danych odpowiedzi.")}`);
        setPortal(null);
        return;
      }
      const targeted = contextResult.data as UatMasterPortalContext;
      const assignments = (targeted.assignments || []).map((assignment) => ({
        id: assignment.id,
        date: assignment.date,
        startsAt: assignment.startsAt,
        endsAt: assignment.endsAt,
        shiftCode: assignment.shiftName,
        shiftName: assignment.shiftName,
        location: assignment.locationName,
        locationCode: assignment.locationId,
        role: assignment.roleName,
        roleCode: assignment.roleId,
        coworkers: [],
      }));
      const calendarContext = calendarResult.error || !calendarResult.data
        ? undefined : calendarResult.data as WorkforceCalendarContext;
      if (calendarResult.error) fail(`Nie udało się pobrać eventów: ${translateError(calendarResult.error.message)}`);
      setPortal({
        ...targeted,
        assignments,
        standby: targeted.standby || [],
        attendance: targeted.attendance || [],
        calendarContext,
        swapBoard: undefined,
        masterPersona: true,
      });
      return;
    }
    const assignmentsRequest: Promise<{ portal?: PortalWorkspace; assignments: PortalAssignment[]; standby: SolverEmployeeStandby[]; error: Error | null }> =
      solverEngine === "ORTOOLS_V2"
        ? getEmployeePublishedSchedule(supabase, requestedMonth)
            .then((schedule) => ({ ...schedule, error: null }))
            .catch((cause) => ({ assignments: [], standby: [], error: cause instanceof Error ? cause : new Error(String(cause)) }))
        : solverEngine
          ? Promise.resolve(supabase.rpc("employee_portal_workspace", { p_month: requestedMonth })).then((result) => {
              if (result.error || !result.data) return { assignments: [], standby: [], error: new Error(result.error?.message || "Brak danych portalu pracownika.") };
              const legacyPortal = result.data as PortalWorkspace;
              return { portal: legacyPortal, assignments: legacyPortal.assignments || [], standby: legacyPortal.standby || [], error: null };
            })
          : Promise.resolve({ assignments: [], standby: [], error: new Error("Konfiguracja silnika jest niedostępna.") });
    const [assignmentsResult, constraintsResult, preferencesResult, calendarResult, swapResult, companyCalendarResult] = await Promise.all([
      assignmentsRequest,
      supabase.rpc("employee_time_constraints_self_v2", { p_month: requestedMonth }),
      supabase.rpc("employee_shift_preferences_self_v2", { p_month: requestedMonth }),
      supabase.rpc("workforce_calendar_context_uat_v3", { p_month: requestedMonth }),
      solverEngine === "ORTOOLS_V2"
        ? supabase.rpc("shift_swap_board_uat_v2", { p_month: requestedMonth })
        : Promise.resolve({ data: null, error: null }),
      solverEngine === "ORTOOLS_V2"
        ? supabase.rpc("published_company_calendar_uat_v2", { p_month: requestedMonth })
        : Promise.resolve({ data: null, error: null }),
    ]);
    if (token !== portalLoadToken.current || portalMonthRef.current !== requestedMonth) return;
    const errors: string[] = [];
    if (assignmentsResult.error) errors.push(translateError(assignmentsResult.error.message));
    let timeConstraints: PortalTimeConstraintsWorkspace | undefined;
    if (constraintsResult.error || !constraintsResult.data) {
      errors.push(`Nie udało się pobrać okien dostępności: ${translateError(constraintsResult.error?.message || "Brak danych odpowiedzi.")}`);
    } else {
      const payload = constraintsResult.data as Partial<PortalTimeConstraintsWorkspace>;
      if (!payload.employeeId) errors.push("Odpowiedź konfiguracji firmy nie zawiera identyfikatora pracownika.");
      else timeConstraints = {
        employeeId: payload.employeeId,
        timezone: payload.timezone || timezone,
        defaultAvailable: payload.defaultAvailable !== false,
        constraints: payload.constraints || [],
      };
    }
    let shiftPreferences: PortalShiftPreferences | undefined;
    if (preferencesResult.error || !preferencesResult.data) {
      errors.push(`Nie udało się pobrać preferencji zmianowych: ${translateError(preferencesResult.error?.message || "Brak danych odpowiedzi.")}`);
    } else shiftPreferences = preferencesResult.data as PortalShiftPreferences;
    const calendarContext = calendarResult.error || !calendarResult.data
      ? undefined : calendarResult.data as WorkforceCalendarContext;
    if (calendarResult.error) errors.push(`Nie udało się pobrać eventów: ${translateError(calendarResult.error.message)}`);
    const swapBoard = swapResult.error || !swapResult.data
      ? undefined : swapResult.data as ShiftSwapBoard;
    if (swapResult.error) errors.push(`Nie udało się pobrać tablicy zamian: ${translateError(swapResult.error.message)}`);
    const companyCalendar = companyCalendarResult.error || !companyCalendarResult.data
      ? undefined : companyCalendarResult.data as CompanyCalendar;
    if (companyCalendarResult.error) errors.push(`Nie udało się pobrać grafiku firmy: ${translateError(companyCalendarResult.error.message)}`);
    if (errors.length) fail(errors.join(" • "));
    setPortal({
      ...assignmentsResult.portal,
      assignments: assignmentsResult.assignments,
      standby: assignmentsResult.standby,
      attendance: assignmentsResult.portal?.attendance || [],
      timeConstraints,
      shiftPreferences,
      calendarContext,
      swapBoard,
      companyCalendar,
    });
  }, [fail, selectedMonthDate, solverEngine, supabase, timezone, uatMasterEmployeeId, view]);

  useEffect(() => {
    setPortal(null);
    setAvailabilityOpen(false);
    setShiftPreferencesOpen(false);
    portalLoadToken.current += 1;
  }, [selectedMonthDate, solverEngine, uatMasterEmployeeId]);
  useEffect(() => {
    void loadPortal();
    return () => { portalLoadToken.current += 1; };
  }, [loadPortal]);

  const loadOperationalContext = useCallback(async () => {
    if (!supabase || view !== "rolePlans") return;
    const result = await supabase.rpc("workforce_calendar_context_uat_v3", { p_month: selectedMonthDate });
    if (result.error) {
      fail(`Nie udało się pobrać kalendarza operacyjnego: ${translateError(result.error.message)}`);
      return;
    }
    setOperationalContext(result.data as WorkforceCalendarContext);
  }, [fail, selectedMonthDate, supabase, view]);
  useEffect(() => { void loadOperationalContext(); }, [loadOperationalContext]);

  async function saveTimeConstraint(entry: { dates: string[]; kind: "AVAILABLE" | "PREFER_NOT_TO_WORK" | "CANNOT_WORK"; allDay: boolean; start?: string; end?: string; preferredLocationId?: string; note: string }) {
    let publicationConflicts: Array<{ scheduleName?: string; publishedAt?: string; date?: string; shiftName?: string; locationName?: string }> = [];
    if (entry.kind === "CANNOT_WORK" && supabase) {
      // OR-Tools' published schedule payload intentionally contains only assignments
      // and stand-by entries.  The stable employee id is provided by the shared
      // availability workspace, so keep it as the self-service fallback.  Without
      // this fallback the post-publication conflict check was silently skipped.
      const employeeId = uatMasterEmployeeId || portal?.employee?.id || portal?.timeConstraints?.employeeId;
      if (employeeId) {
        const conflictResult = await supabase.rpc("employee_availability_publication_conflicts_uat_v1", {
          p_employee_id: employeeId,
          p_dates: entry.dates,
        });
        if (conflictResult.error) {
          fail(`Nie udało się sprawdzić opublikowanego grafiku: ${translateError(conflictResult.error.message)}`);
          return false;
        }
        publicationConflicts = Array.isArray(conflictResult.data) ? conflictResult.data as typeof publicationConflicts : [];
        if (publicationConflicts.length) {
          const details = publicationConflicts.slice(0, 5).map(conflict =>
            `${conflict.date || "dzień"}: ${conflict.shiftName || "zmiana"} • ${conflict.locationName || "lokal"} • grafik „${conflict.scheduleName || "opublikowany"}”${conflict.publishedAt ? ` opublikowany ${new Date(conflict.publishedAt).toLocaleString("pl-PL", { timeZone: timezone })}` : ""}`
          ).join("\n");
          if (!window.confirm(`Te dni mają już opublikowane przydziały:\n\n${details}\n\nNiedostępność zostanie zapisana PO publikacji. Nie oznacza to, że silnik ją zignorował; lider musi rozwiązać konflikt. Zapisać?`)) return false;
        }
      }
    }
    const result = await rpc(uatMasterEmployeeId
      ? "uat_master_emp…12320 tokens truncated…aint[]>();
    workspace.constraints.forEach(entry=>{
      const startsOn=localIsoDate(entry.startsAt,timezone);
      const exclusiveEnd=new Date(entry.endsAt).getTime();
      const endsOn=localIsoDate(new Date(Math.max(
        new Date(entry.startsAt).getTime(),exclusiveEnd-1,
      )).toISOString(),timezone);
      monthDates.filter(date=>date>=startsOn&&date<=endsOn).forEach(date=>{
        result.set(date,[...(result.get(date)??[]),entry]);
      });
    });
    return result;
  },[monthDates,timezone,workspace.constraints]);
  const dayState=(date:string)=>{
    const entries=entriesByDay.get(date)??[];
    const hard=entries.find(entry=>["UNAVAILABLE","LEAVE","SICKNESS"].includes(entry.kind));
    if(hard)return {tone:"hard",label:timeConstraintKindPl(hard.kind),entry:hard};
    const soft=entries.find(entry=>entry.kind==="PREFER_NOT_TO_WORK");
    if(soft)return {tone:"soft",label:"Wolę nie pracować",entry:soft};
    const windowEntry=entries.find(entry=>entry.kind==="AVAILABLE_WINDOW");
    return {tone:"available",label:windowEntry?"Mogę w podanych godzinach":"Mogę pracować",entry:windowEntry};
  };
  const explicitDays=monthDates.filter(date=>(entriesByDay.get(date)??[]).length>0).length;
  const publishedDays=new Set(assignments.map(assignment=>assignment.date)).size;
  const exceptionDays=monthDates.filter(date=>(entriesByDay.get(date)??[]).some(entry=>entry.kind!=="AVAILABLE_WINDOW")).length;
  const defaultDays=monthDates.length-explicitDays;
  const dayIsProtected=(date:string)=>(entriesByDay.get(date)??[]).some(entry=>!entry.editable||entry.source!=="GRAFIK_PRO");
  const applyDayToEditor=(date:string)=>{
    const state=dayState(date);
    const entries=entriesByDay.get(date)??[];
    const locationEntry=entries.find(entry=>entry.kind==="PREFERRED_LOCATION");
    if(state.tone==="hard")setKind("CANNOT_WORK");
    else if(state.tone==="soft")setKind("PREFER_NOT_TO_WORK");
    else setKind("AVAILABLE");
    const entry=state.entry;
    if(entry&&["AVAILABLE_WINDOW","UNAVAILABLE"].includes(entry.kind)){
      const begins=time(entry.startsAt,timezone),finishes=time(entry.endsAt,timezone);
      const fullDay=begins==="00:00"&&finishes==="00:00";
      setAllDay(fullDay);
      if(!fullDay){setStart(begins);setEnd(finishes);}
    }else setAllDay(true);
    setPreferredLocationId(locationEntry?.preferredLocationId??entry?.preferredLocationId??"");
    setNote(entry?.note??locationEntry?.note??"");
  };
  const selectRange=(first:string,last:string)=>{
    const [from,to]=first<=last?[first,last]:[last,first];
    const range=monthDates.filter(date=>date>=from&&date<=to);
    const selectable=range.filter(date=>!dayIsProtected(date));
    if(selectable.length!==range.length)fail("Chronione dni pracodawcy, urlopu lub L4 pominięto — może je zmienić tylko osoba zarządzająca konfiguracją firmy.");
    setSelectedDays(selectable);
    setRangeAnchor(null);
  };
  const clickDay=(date:string)=>{
    onSelectDay?.(date);
    if(dayIsProtected(date)){fail("Ten dzień zawiera chroniony wpis pracodawcy, urlopu lub L4 i jest w portalu tylko do odczytu.");return;}
    if(rangeAnchor){selectRange(rangeAnchor,date);return;}
    if(selectedDays.length>1){
      setSelectedDays(current=>current.includes(date)?current.filter(item=>item!==date):[...current,date].sort());
      return;
    }
    if(selectedDays.length===1&&selectedDays[0]===date){setSelectedDays([]);setRangeAnchor(null);return;}
    setSelectedDays([date]);setRangeAnchor(date);applyDayToEditor(date);
  };
  const submit=async()=>{
    try{
      if(!selectedDays.length)throw new Error("Zaznacz co najmniej jeden dzień.");
      const ok=await save({dates:selectedDays,kind,allDay,start,end,preferredLocationId,note});
      if(ok){setSelectedDays([]);setRangeAnchor(null);setNote("");setPreferredLocationId("");}
    }catch(cause){fail(cause instanceof Error?cause.message:"Nie udało się zapisać dostępności.");}
  };

  const body=<div className="availability-calendar-content">
      <section className="availability-month-status" aria-label="Podsumowanie dostępności miesiąca">
        <div><small>Dni z własnym wpisem</small><strong>{explicitDays}</strong></div>
        <div><small>Dni według zasady firmy</small><strong>{defaultDays}</strong></div>
        <div><small>Dni z opublikowaną zmianą</small><strong>{publishedDays}</strong></div>
        <div><small>Wyjątki i preferencje</small><strong>{exceptionDays}</strong></div>
        <p>{workspace.defaultAvailable!==false
          ?"Nie musisz zaznaczać każdego dnia. Bez własnego wpisu system przyjmuje, że możesz pracować; urlop, L4 i inne wyjątki pokaże osobno."
          :"Firma wymaga jawnej deklaracji dostępności. Dni bez wpisu nie zostaną uznane za dostępne podczas planowania."}</p>
      </section>
      <section className="availability-calendar-panel">
        <div className="availability-calendar-legend"><span className="available">Mogę pracować</span><span className="soft">Wolę nie pracować</span><span className="hard">Nie mogę / urlop / L4</span></div>
        <div className="availability-weekdays">{days.map(day=><b key={day}>{day}</b>)}</div>
        <div className="availability-state-calendar">{Array.from({length:calendarOffset},(_,index)=><i key={`blank-${index}`}/>)}{monthDates.map(date=>{
          const state=dayState(date),entries=entriesByDay.get(date)??[];
          const protectedEntry=entries.some(entry=>!entry.editable||entry.source!=="GRAFIK_PRO");
          const events=calendarContext?.events.filter(event=>event.date===date)??[];
          const pending=calendarContext?.pendingReviews.some(review=>review.date===date)??false;
          const publishedAssignments=assignments.filter(assignment=>assignment.date===date);
          return <button type="button" key={date} className={`${state.tone} ${selectedDays.includes(date)?"selected":""} ${protectedEntry?"protected":""} ${events.some(event=>event.kind==="HOT_DAY")?"hot-day":""} ${pending?"pending-review":""} ${publishedAssignments.length?"published-assignment":""}`} onClick={()=>clickDay(date)} aria-disabled={protectedEntry} title={protectedEntry?`${state.label} • wpis chroniony, tylko do odczytu`:state.label}><b>{Number(date.slice(-2))}</b><small>{state.label}</small>{publishedAssignments.length>0&&<em><AlertTriangle/> Opublikowany grafik: {publishedAssignments.map(assignment=>time(assignment.startsAt,assignmentTimezone(assignment,timezone))).join(", ")}</em>}{events.some(event=>event.kind==="HOT_DAY")&&<em><Flame/> Limit nieobecności</em>}{events.some(event=>event.kind==="EVENT")&&<em><Megaphone/> Wydarzenie</em>}{pending&&<em>Oczekuje na lidera</em>}{protectedEntry&&<ShieldCheck/>}</button>;
        })}</div>
        <p className="availability-selection-help">{rangeAnchor?"Kliknij ostatni dzień zakresu albo od razu ustaw wybrany dzień.":selectedDays.length?`Wybrano ${selectedDays.length} dni. Kliknij dzień, aby go odznaczyć.`:"Kliknij dzień. Drugie kliknięcie na innym dniu zaznaczy cały zakres."}</p>
      </section>
      <form className="availability-state-editor" onSubmit={event=>{event.preventDefault();void submit();}}>
        <div><h3>Zmień zaznaczone dni</h3><p>{selectedDays.length?`${selectedDays[0]}${selectedDays.length>1?` – ${selectedDays.at(-1)}`:""}`:"Najpierw wybierz dzień lub zakres w kalendarzu."}</p></div>
        <div className="availability-state-options">
          <button type="button" className={`available ${kind==="AVAILABLE"?"active":""}`} onClick={()=>setKind("AVAILABLE")}><span/>Mogę pracować</button>
          <button type="button" className={`soft ${kind==="PREFER_NOT_TO_WORK"?"active":""}`} onClick={()=>setKind("PREFER_NOT_TO_WORK")}><span/>Wolę nie pracować</button>
          <button type="button" className={`hard ${kind==="CANNOT_WORK"?"active":""}`} onClick={()=>setKind("CANNOT_WORK")}><span/>Nie mogę pracować</button>
        </div>
        {kind!=="PREFER_NOT_TO_WORK"&&<><label className="availability-all-day"><input type="checkbox" checked={!allDay} onChange={event=>setAllDay(!event.target.checked)}/> Podaj konkretne godziny</label>{!allDay&&<div className="form-row"><label>Od (24 h)<input required type="text" inputMode="numeric" pattern="(?:[01][0-9]|2[0-3]):[0-5][0-9]" placeholder="08:00" value={start} onChange={event=>setStart(event.target.value)}/></label><label>Do (24 h)<input required type="text" inputMode="numeric" pattern="(?:[01][0-9]|2[0-3]):[0-5][0-9]" placeholder="16:30" value={end} onChange={event=>setEnd(event.target.value)}/></label></div>}</>}
        <fieldset className="availability-location-options"><legend>Preferowany lokal (opcjonalnie)</legend><button type="button" className={!preferredLocationId?"active":""} onClick={()=>setPreferredLocationId("")}>Bez preferencji</button>{locations.filter(location=>location.active).map(location=><button type="button" className={preferredLocationId===location.id?"active":""} onClick={()=>setPreferredLocationId(location.id)} key={location.id}>{location.name}</button>)}</fieldset>
        <label>Notatka (opcjonalnie)<textarea maxLength={500} value={note} onChange={event=>setNote(event.target.value)}/></label>
        <div className="availability-editor-actions"><button type="button" className="secondary-button" disabled={!selectedDays.length||busy} onClick={()=>{setSelectedDays([]);setRangeAnchor(null);}}>Wyczyść wybór</button><button className="primary-button" disabled={!selectedDays.length||busy}><Save/>{busy?"Zapisuję…":"Zapisz i zostań tutaj"}</button></div>
        <small className="availability-protected-note"><ShieldCheck/> Wpis pracodawcy, urlop lub L4 ma pierwszeństwo i pozostaje tylko do odczytu.</small>
      </form>
    </div>;
  if(embedded)return <section className="employee-combined-calendar"><div className="matrix-demand-head"><div><h3>Mój grafik i dostępność — {labelMonth(month,timezone)}</h3><p>Opublikowane zmiany, wydarzenia i deklaracje dostępności są na jednym kalendarzu. Kliknij dzień, aby zobaczyć zespół i od razu zmienić dostępność.</p></div></div>{body}</section>;
  return <><button className="drawer-scrim" onClick={close}/><aside className="drawer role-drawer availability-calendar-drawer">
    <div className="drawer-head"><div><p className="eyebrow">PORTAL PRACOWNIKA • GRAFIK I DOSTĘPNOŚĆ</p><h2>{labelMonth(month,timezone)}</h2><small>Opublikowany grafik i deklaracje są na jednym kalendarzu.</small></div><button className="icon-button" onClick={close}><X/></button></div>
    <div className="drawer-content">{body}</div>
  </aside></>;
}

function CoworkerDrawer({ assignment, timezone, dynamic, roleNames, close, requestSwap, loadSwapCandidates, allowSwap, busy }: { assignment: PortalAssignment; timezone: string; dynamic: boolean; roleNames: Record<string, string>; close: () => void; requestSwap: (assignmentId: string, targetEmployeeId: string | null, message: string) => Promise<boolean>; loadSwapCandidates: (assignmentId: string) => Promise<ShiftSwapCandidate[]>; allowSwap: boolean; busy: boolean }) {
  const localTimezone = assignmentTimezone(assignment, timezone);
  const [swapOpen,setSwapOpen]=useState(false);
  const [candidateLoading,setCandidateLoading]=useState(false);
  const [candidates,setCandidates]=useState<ShiftSwapCandidate[]>([]);
  const [targetEmployeeId,setTargetEmployeeId]=useState("");
  const [candidateQuery,setCandidateQuery]=useState("");
  const [message,setMessage]=useState("Chcę zamienić tę zmianę.");
  const openSwap=async()=>{setSwapOpen(true);setCandidateLoading(true);const rows=await loadSwapCandidates(assignment.id);setCandidates(rows);setCandidateLoading(false);};
  const submit=async(event:React.FormEvent)=>{event.preventDefault();if(await requestSwap(assignment.id,targetEmployeeId||null,message))close();};
  const normalizedCandidateQuery=candidateQuery.trim().toLocaleLowerCase("pl-PL");
  const eligibleCandidates=candidates.filter(candidate=>candidate.eligible&&(!normalizedCandidateQuery||`${candidate.name} ${candidate.employeeNo}`.toLocaleLowerCase("pl-PL").includes(normalizedCandidateQuery)));
  return <><button className="drawer-scrim" onClick={close} /><aside className="drawer complete-drawer"><div className="drawer-head"><div><p className="eyebrow">SZCZEGÓŁY ZMIANY</p><h2>{assignment.date} • {time(assignment.startsAt, localTimezone)}–{time(assignment.endsAt, localTimezone)}</h2><small>{assignment.location} • {portalShiftLabel(assignment)}</small></div><button className="icon-button" onClick={close}><X /></button></div><div className="drawer-content coworker-list">{allowSwap ? !swapOpen?<button className="primary-button full" disabled={busy || new Date(assignment.startsAt)<=new Date()} onClick={()=>void openSwap()}><ArrowLeftRight/> Zaproponuj zamianę</button>:<form className="swap-request-form" onSubmit={event=>void submit(event)}><h3>Nowe ogłoszenie o zamianie</h3><label>Znajdź adresata<input className="swap-candidate-search" value={candidateQuery} onChange={event=>setCandidateQuery(event.target.value)} placeholder="Wpisz imię, nazwisko lub numer" disabled={candidateLoading||busy}/><small>{candidateLoading?"Sprawdzam rolę, lokal, obowiązki, dostępność i odpoczynek…":`${candidates.filter(candidate=>candidate.eligible).length} osób spełnia warunki tej zmiany.`}</small></label><div className="swap-candidate-list"><button type="button" className={!targetEmployeeId?"active":""} onClick={()=>setTargetEmployeeId("")}><span><b>Cała tablica</b><small>Każda uprawniona osoba</small></span></button>{eligibleCandidates.map(candidate=><button type="button" className={targetEmployeeId===candidate.employeeId?"active":""} onClick={()=>setTargetEmployeeId(candidate.employeeId)} key={candidate.employeeId}><span><b>{candidate.name}</b><small>{candidate.employeeNo}</small></span><small>Może przejąć</small></button>)}</div><label>Wiadomość<textarea value={message} maxLength={500} onChange={event=>setMessage(event.target.value)}/></label><div className="swap-form-actions"><button type="button" className="secondary-button" onClick={()=>setSwapOpen(false)}>Anuluj</button><button className="primary-button" disabled={busy||candidateLoading}><ArrowLeftRight/> Opublikuj propozycję</button></div>{!candidateLoading&&candidates.some(candidate=>!candidate.eligible)&&<details><summary>Dlaczego część osób jest niedostępna?</summary>{candidates.filter(candidate=>!candidate.eligible).slice(0,12).map(candidate=><p key={candidate.employeeId}><b>{candidate.name}</b> — {candidate.reasons.map(swapReasonLabel).join(", ")}</p>)}</details>}</form> : <div className="uat-master-readonly"><ShieldCheck /> Akcje zamiany są niedostępne w symulowanym widoku MASTER.</div>}<h3>Osoby na tej zmianie</h3>{assignment.coworkers?.length ? assignment.coworkers.map((coworker, index) => <div key={index}><UserRound /><span><b>{coworker.name}</b><small>{dynamic ? roleNames[coworker.role] ?? coworker.role : rolePl[coworker.role] || coworker.role}</small></span></div>) : <p>Nie ma innych przypisanych osób.</p>}</div></aside></>;
}

function labelMonth(month: string, timezone = "Europe/Warsaw") {
  return new Intl.DateTimeFormat("pl-PL", { month: "long", year: "numeric", timeZone: timezone }).format(new Date(`${month}-01T12:00:00Z`));
}
function localIsoDate(value: string, timezone: string) {
  const parts = Object.fromEntries(new Intl.DateTimeFormat("en-CA", { timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(new Date(value)).filter((part) => part.type !== "literal").map((part) => [part.type, part.value]));
  return `${parts.year}-${parts.month}-${parts.day}`;
}
function time(value?: string, timezone = "Europe/Warsaw") { return value ? new Date(value).toLocaleTimeString("pl-PL", { hour: "2-digit", minute: "2-digit", timeZone: timezone }) : "—"; }
function portalShiftLabel(assignment: PortalAssignment) { return assignment.shiftName?.trim() || assignment.shiftCode || "Zmiana"; }
function assignmentTimezone(assignment: PortalAssignment, fallback: string) { return assignment.locationTimezone?.trim() || fallback; }
function preferenceLevelLabel(value: string) { return ({ PREFERRED: "preferowana", NEUTRAL: "neutralna", AVOIDED: "unikać", BLOCKED: "zablokowana", INHERIT: "wg pracownika" } as Record<string, string>)[value] || value; }
function swapStatusLabel(value: string) { return ({ OPEN: "Otwarte", EMPLOYEE_ACCEPTED: "Czeka na lidera", EMPLOYEE_REJECTED:"Odrzucone przez pracownika", LEADER_APPROVED: "Zatwierdzone", LEADER_REJECTED: "Odrzucone przez lidera", CANCELLED:"Anulowane" } as Record<string, string>)[value] || value; }
function swapReasonLabel(value?: string) { return ({ ROLE_REQUIRED: "Brak wymaganej roli", LOCATION_NOT_ALLOWED: "Lokal nie jest dozwolony", DUTY_REQUIRED: "Brak wymaganej kompetencji i zastępczego pokrycia na zmianie", HARD_UNAVAILABLE: "Twarda niedostępność", STANDBY_CONFLICT: "Dyżur rezerwowy tego dnia", SHIFT_OR_REST_CONFLICT: "Kolizja grafiku lub odpoczynku", MAXIMUM_MONTHLY_HOURS: "Przekroczenie limitu miesięcznego", MAXIMUM_WEEKLY_HOURS: "Przekroczenie limitu tygodniowego", OUTSIDE_EMPLOYMENT:"Data poza okresem zatrudnienia", NO_WEEKENDS:"Zablokowane weekendy", ONLY_MORNING:"Ta zmiana nie mieści się w dozwolonych godzinach pracownika", ONLY_EVENING:"Ta zmiana nie mieści się w dozwolonych godzinach pracownika", CANNOT_SWAP_WITH_SELF:"Nie można zamienić się ze sobą" } as Record<string, string>)[value || ""] || value || "Ta zamiana nie spełnia twardych reguł."; }
function swapHistoryLabel(value:string){return ({CREATED:"Utworzono ogłoszenie",ACCEPT:"Pracownik przyjął propozycję",REJECT:"Pracownik odrzucił propozycję",LEADER_APPROVE:"Lider zatwierdził zamianę",LEADER_REJECT:"Lider odrzucił zamianę",CANCEL:"Anulowano"} as Record<string,string>)[value]||value.replaceAll("_"," ");}
function timeConstraintKindPl(kind: string) { return ({ AVAILABLE_WINDOW: "Dostępność", UNAVAILABLE: "Twarda niedostępność", PREFER_NOT_TO_WORK: "Wolę nie pracować", PREFERRED_LOCATION: "Preferowany lokal", LEAVE: "Urlop", SICKNESS: "L4 / zwolnienie" } as Record<string, string>)[kind] || kind; }
function translateError(message: string) {
  const translations: Record<string, string> = {
    AUTH_REQUIRED: "Zaloguj się ponownie.",
    EMPLOYEE_NOT_FOUND: "Konto nie jest powiązane z pracownikiem.",
    INVALID_TIME_RANGE: "Koniec przedziału musi przypadać po jego początku.",
    PROTECTED_TIME_CONSTRAINT: "Tego wpisu nie można zmienić w portalu pracownika.",
    FORBIDDEN: "Nie masz uprawnień do tej operacji.",
    SCHEDULE_PUBLICATION_CONFLICT_REQUIRES_OWNER_RESOLUTION: "Grafik roli i grafik firmy są ze sobą sprzeczne. System nie pokaże pracownikom losowo wybranej wersji; konflikt musi rozstrzygnąć właściciel.",
    STANDBY_COVERAGE_INSUFFICIENT: "Grafik ma pierwszeństwo przed rezerwą. System opublikuje pełną obsadę i doda tyle bezpiecznej rezerwy, ile pozwala liczebność zespołu.",
    STANDBY_TIER_1_MUST_BE_USED_OR_DECLINED_FIRST: "Najpierw aktywuj albo odrzuć pierwszą osobę rezerwową.",
    STANDBY_REVALIDATION_HARD_BLOCK: "Osoba rezerwowa ma obecnie twardą niedostępność i nie może przejąć tej zmiany.",
  };
  const code = Object.keys(translations).find((candidate) => message.includes(candidate));
  return code ? translations[code] : message;
}
function downloadCsv(name: string, rows: Record<string, unknown>[]) {
  if (!rows.length) return;
  const headers = Object.keys(rows[0]);
  const cell = (value: unknown) => `"${String(value ?? "").replaceAll('"', '""')}"`;
  const blob = new Blob(["\ufeff" + [headers.join(";"), ...rows.map((row) => headers.map((header) => cell(row[header])).join(";"))].join("\n")], { type: "text/csv;charset=utf-8" });
  const anchor = document.createElement("a");
  anchor.href = URL.createObjectURL(blob);
  anchor.download = name;
  anchor.click();
  URL.revokeObjectURL(anchor.href);
}
