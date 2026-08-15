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
      ? "uat_master_employee_availability_days_save_v2"
      : "employee_availability_days_save_uat_v3", {
      ...(uatMasterEmployeeId ? { p_employee_id: uatMasterEmployeeId } : {}),
      p_dates: entry.dates,
      p_kind: entry.kind,
      p_all_day: entry.allDay,
      p_local_start: entry.allDay ? null : entry.start,
      p_local_end: entry.allDay ? null : entry.end,
      p_preferred_location_id: entry.preferredLocationId || null,
      p_note: entry.note || null,
    });
    if (!result) return false;
    const reviewCount = Number((result as { pendingReviewDays?: number }).pendingReviewDays || 0);
    notify(publicationConflicts.length > 0
      ? `Zapisano niedostępność po publikacji. Konflikty z opublikowanym grafikiem: ${publicationConflicts.length}. Wymagają decyzji lidera.`
      : reviewCount > 0
      ? `${reviewCount} dni z limitem nieobecności przekazano liderowi do weryfikacji.`
      : "Zapisano wybrany zakres dostępności.");
    await loadPortal();
    return true;
  }

  async function saveShiftPreferences(preferences: Record<ShiftPeriod, ShiftPreferenceLevel>) {
    const result = await rpc(uatMasterEmployeeId
      ? "uat_master_employee_shift_preferences_save_v2"
      : "employee_shift_preferences_save_self_v2", {
      ...(uatMasterEmployeeId ? { p_employee_id: uatMasterEmployeeId } : {}),
      p_month: selectedMonthDate,
      p_preferences: preferences,
    });
    if (!result) return false;
    setShiftPreferencesOpen(false);
    notify("Preferencje zmianowe zostały zapisane.");
    await loadPortal();
    await reload();
    return true;
  }

  async function selectUatMasterEmployee(employeeId: string | null) {
    const result = await rpc("uat_master_persona_select_v2", {
      p_persona: employeeId ? "EMPLOYEE" : "OWNER",
      p_employee_id: employeeId,
    });
    if (!result) return;
    setAvailabilityOpen(false);
    setShiftPreferencesOpen(false);
    setUatMasterEmployeeId(employeeId);
    setUatMasterSearch("");
    notify(employeeId
      ? "Tryb MASTER: otwarto audytowany widok wskazanego pracownika."
      : "Tryb MASTER: wrócono do własnego konta.");
  }

  async function loadSwapCandidates(assignmentId: string) {
    const result = await rpc("shift_swap_candidates_uat_v2", { p_assignment_id: assignmentId });
    return Array.isArray(result) ? result as ShiftSwapCandidate[] : [];
  }

  async function createSwapRequest(assignmentId: string, targetEmployeeId: string | null, message: string) {
    const result = await rpc("shift_swap_request_create_uat_v2", {
      p_assignment_id: assignmentId,
      p_target_employee_id: targetEmployeeId,
      p_message: message || null,
    });
    if (!result) return false;
    notify("Ogłoszenie o zamianie zostało dodane do tablicy.");
    await loadPortal();
    return true;
  }

  async function decideSwapAsEmployee(requestId: string, decision: "ACCEPT" | "REJECT") {
    const result = await rpc("shift_swap_employee_decide_uat_v2", {
      p_request_id: requestId,
      p_decision: decision,
    });
    if (!result) return false;
    notify(decision === "ACCEPT" ? "Zgłoszenie wysłano liderowi do akceptacji." : "Propozycja została odrzucona.");
    await loadPortal();
    return true;
  }

  async function decideSwapAsLeader(requestId: string, decision: "APPROVE" | "REJECT") {
    const reason = window.prompt(decision === "APPROVE" ? "Powód akceptacji zamiany:" : "Powód odrzucenia zamiany:");
    if (!reason) return false;
    const result = await rpc("shift_swap_leader_decide_uat_v2", {
      p_request_id: requestId,
      p_decision: decision,
      p_reason: reason,
    });
    if (!result) return false;
    notify(decision === "APPROVE" ? "Zamiana została zatwierdzona i naniesiona na grafik." : "Zamiana została odrzucona.");
    await loadPortal();
    return true;
  }

  async function saveOperationalEvent(entry: {
    startDate: string; endDate: string; kind: "EVENT" | "HOT_DAY"; title: string; description: string;
    locationId?: string; roleId: string; shiftTemplateIds: string[];
    additionalCount: number; maximumHardUnavailable: number;
  }) {
    const result = await rpc("workforce_calendar_event_range_save_uat_v2", {
      p_month: selectedMonthDate,
      p_start_date: entry.startDate,
      p_end_date: entry.endDate,
      p_event_kind: entry.kind,
      p_title: entry.title,
      p_description: entry.description || null,
      p_location_id: entry.locationId || null,
      p_demands: entry.kind === "EVENT" ? entry.shiftTemplateIds.map(shiftTemplateId => ({
        shiftTemplateId,
        roleId: entry.roleId,
        additionalCount: entry.additionalCount,
      })) : [],
      p_hot_limits: entry.kind === "HOT_DAY" ? [{
        roleId: entry.roleId,
        maximumHardUnavailable: entry.maximumHardUnavailable,
      }] : [],
    });
    if (!result) return false;
    notify(entry.kind === "EVENT" ? "Wydarzenie zapisane — dodatkowa obsada trafi do następnego uruchomienia generatora." : "Limit nieobecności zapisany i aktywny.");
    await loadOperationalContext();
    return true;
  }

  async function reviewAvailability(reviewId: string, decision: "APPROVE" | "REJECT") {
    const reason = window.prompt(decision === "APPROVE" ? "Powód akceptacji niedostępności:" : "Powód odrzucenia niedostępności:");
    if (!reason) return false;
    const result = await rpc("availability_exception_review_uat_v2", {
      p_review_id: reviewId,
      p_decision: decision,
      p_reason: reason,
    });
    if (!result) return false;
    notify(decision === "APPROVE" ? "Niedostępność została zatwierdzona." : "Wniosek został odrzucony.");
    await loadOperationalContext();
    return true;
  }

  async function exportKadromierz() {
    if (solverEngine !== "ORTOOLS_V2") {
      fail("Eksport starego grafiku jest wyłączony. Najpierw opublikuj grafik OR-Tools.");
      return;
    }
    const rows = await rpc("optimizer_kadromierz_export_v2", { p_month: selectedMonthDate });
    if (Array.isArray(rows)) downloadCsv(`grafik-kadromierz-${month}.csv`, rows);
  }

  if (view === "czas") return <RetiredModule title="Ewidencja czasu jest przygotowywana do połączenia z konfiguracją firmy" />;
  if (view === "integracje") {
    if (solverEngine !== "ORTOOLS_V2") return <RetiredModule title="Integracje starego grafiku są wyłączone" />;
    return <IntegrationView busy={busy} onExport={() => void exportKadromierz()} runCount={data.integrationRuns.length} />;
  }
  if (view === "rolePlans" && !rolePlanningEnabled) {
    return <RetiredModule title="Generator ról czeka na kontrolowane przełączenie OR-Tools" />;
  }
  if (view === "rolePlans") return <>
    <PageHead
      eyebrow="PLANOWANIE ZESPOŁOWE"
      title="Grafiki zespołów według kategorii"
      subtitle="Jeden generator obejmuje wszystkie role należące do zespołu. Przykładowo SALA planuje razem kelnerów, hostów i runnerów."
    />
    <div className="solver-v2-notice matrix-source-notice"><AlertTriangle/><span><strong>Grafiki ról korzystają wyłącznie z opublikowanej konfiguracji firmy{solverMatrixEffectiveFrom?` obowiązującej od ${solverMatrixEffectiveFrom}`:""}</strong><small>Zmiany zapisane tylko w wersji roboczej nie są jeszcze widoczne dla generatora.</small></span></div>
    {operationalContext && <OperationalCalendarPanel context={operationalContext} month={month} busy={busy} save={saveOperationalEvent} review={reviewAvailability} />}
    <div className="role-plan-cards compact">{solverRoleCategories.map((category) => {
      const role=category;
      const categoryStyle=roleCardStyle(category.id,category.color);
      const roleStyle=roleCardStyle(role.id,role.color);
      return <article key={role.id} style={{...categoryStyle,...roleStyle}}>
        <i />
        <div><small>KATEGORIA GRAFIKU</small><h3>{role.name}</h3><p>{category.roleNames.join(" • ")}</p></div>
        {solverEngine === "SHADOW"&&<span className="workflow-status empty">Test bez publikacji</span>}
        <div className="card-actions"><button disabled={busy || !onOpenSolverV2} className="primary-button" onClick={() => onOpenSolverV2?.(category)}><WandSparkles /> Otwórz generator</button></div>
      </article>;
    })}</div>
    {!solverRoleCategories.length&&<div className="solver-v2-notice warning"><AlertTriangle/>Najpierw przypisz każdą aktywną rolę do kategorii grafiku w konfiguracji firmy.</div>}
    {solverEngine === "SHADOW" && <div className="solver-v2-notice warning"><ShieldCheck />Tryb SHADOW pozwala wygenerować i porównać trzy warianty każdej roli. Publikacja zespołu i wspólnego grafiku pozostaje zablokowana do kontrolowanego przełączenia.</div>}
  </>;
  return <>
    {uatMaster && <UatMasterPersonaPanel
      preview={uatMaster}
      selectedEmployeeId={uatMasterEmployeeId}
      search={uatMasterSearch}
      setSearch={setUatMasterSearch}
      select={selectUatMasterEmployee}
      busy={busy}
    />}
    {portal ? <EmployeePortal
      portal={portal}
      month={month}
      timezone={timezone}
      dynamic={solverEngine === "ORTOOLS_V2"}
      roleNames={dynamicRoleNames}
      roleColors={dynamicRoleColors}
      openAvailability={() => portal.timeConstraints ? setAvailabilityOpen(true) : fail("Odśwież portal przed edycją dostępności.")}
      openPreferences={() => portal.shiftPreferences ? setShiftPreferencesOpen(true) : fail("Odśwież portal przed edycją preferencji.")}
      requestSwap={createSwapRequest}
      loadSwapCandidates={loadSwapCandidates}
      decideSwapAsEmployee={decideSwapAsEmployee}
      decideSwapAsLeader={decideSwapAsLeader}
      masterMode={Boolean(uatMasterEmployeeId)}
      busy={busy}
      section={portalSection}
      availabilityWorkspace={portal.timeConstraints}
      locations={data.locations}
      saveAvailability={saveTimeConstraint}
      fail={fail}
    /> : <div className="empty-state">Konto nie jest powiązane z pracownikiem.</div>}
    {availabilityOpen && portal?.timeConstraints && <AvailabilityCalendarDrawer
      workspace={portal.timeConstraints}
      month={month}
      locations={data.locations}
      close={() => setAvailabilityOpen(false)}
      save={saveTimeConstraint}
      fail={fail}
      busy={busy}
      calendarContext={portal.calendarContext}
      assignments={portal.assignments}
    />}
    {shiftPreferencesOpen && portal?.shiftPreferences && <ShiftPreferencesDrawer
      workspace={portal.shiftPreferences}
      month={month}
      close={() => setShiftPreferencesOpen(false)}
      save={saveShiftPreferences}
      busy={busy}
    />}
  </>;
}

function UatMasterPersonaPanel({ preview, selectedEmployeeId, search, setSearch, select, busy }: {
  preview: UatMasterPreview;
  selectedEmployeeId: string | null;
  search: string;
  setSearch: (value: string) => void;
  select: (employeeId: string | null) => Promise<void>;
  busy: boolean;
}) {
  const selected = preview.employees.find((employee) => employee.id === selectedEmployeeId);
  const normalized = search.trim().toLocaleLowerCase("pl-PL");
  const matches = preview.employees.filter((employee) => !normalized ||
    `${employee.name} ${employee.employeeNo} ${employee.roleName || ""} ${employee.roleCode || ""}`
      .toLocaleLowerCase("pl-PL").includes(normalized)).slice(0, 8);
  return <section className="uat-master-persona-panel">
    <div className="uat-master-persona-head"><span><ShieldCheck /><b>UAT MASTER — audytowany podgląd ról</b><small>Każde wybranie osoby i zapis testowy trafia do historii audytu. Funkcja działa wyłącznie w izolowanym UAT.</small></span>{selected && <button className="secondary-button" disabled={busy} onClick={() => void select(null)}>Wróć do mojego konta</button>}</div>
    <label>Sprawdź aplikację jako pracownik<input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Wpisz imię, nazwisko, numer GP lub rolę" /></label>
    {selected && <div className="uat-master-selected"><UserRound /><span><b>{selected.name}</b><small>{selected.employeeNo} • {selected.roleName || "Brak roli"}</small></span></div>}
    {(!selected || normalized) && <div className="uat-master-results">{matches.map((employee) => <button type="button" key={employee.id} disabled={busy || employee.id === selectedEmployeeId} onClick={() => void select(employee.id)}><b>{employee.name}</b><small>{employee.employeeNo} • {employee.roleName || "Brak roli"}</small></button>)}{!matches.length && <p>Brak pracownika pasującego do wyszukiwania.</p>}</div>}
  </section>;
}

function PageHead({ eyebrow, title, subtitle, actions }: { eyebrow: string; title: string; subtitle: string; actions?: React.ReactNode }) {
  return <div className="module-page-head"><div><p className="eyebrow">{eyebrow}</p><h2>{title}</h2><p>{subtitle}</p></div><div>{actions}</div></div>;
}

function RetiredModule({ title }: { title: string }) {
  return <><PageHead eyebrow="ALPHA 16" title={title} subtitle="Aplikacja nie wykona zapisu przez wycofany model Alpha 15." /><section className="empty-engine"><ShieldCheck /><h2>Brak konkurencyjnego zapisu</h2><p>Moduł zostanie uruchomiony wyłącznie po podłączeniu wersjonowanej konfiguracji firmy i silnika OR-Tools.</p></section></>;
}

function IntegrationView({ busy, onExport, runCount }: { busy: boolean; onExport: () => void; runCount: number }) {
  return <><PageHead eyebrow="INTEGRACJE • OR-TOOLS" title="Kadromierz — bezpieczny eksport" subtitle="Eksport korzysta wyłącznie z opublikowanego grafiku nowego silnika." actions={<button disabled={busy} className="primary-button" onClick={onExport}><Download /> Eksport grafiku</button>} /><div className="integration-cards"><section><ShieldCheck /><h3>Import starego modelu jest wyłączony</h3><p>Dostępność i preferencje trafiają do konfiguracji firmy; duże zmiany importujesz z podglądem przed zapisem.</p></section><section><Download /><h3>Eksport do Kadromierza</h3><p>Opublikowane integracje w historii: {runCount}.</p><button disabled={busy} onClick={onExport}>Przygotuj eksport</button></section></div></>;
}

function OperationalCalendarPanel({ context, month, busy, save, review }: {
  context: WorkforceCalendarContext;
  month: string;
  busy: boolean;
  save: (entry: { startDate: string; endDate: string; kind: "EVENT" | "HOT_DAY"; title: string; description: string; locationId?: string; roleId: string; shiftTemplateIds: string[]; additionalCount: number; maximumHardUnavailable: number }) => Promise<boolean>;
  review: (reviewId: string, decision: "APPROVE" | "REJECT") => Promise<boolean>;
}) {
  const roles = context.roles || [];
  const locations = context.locations || [];
  const templates = context.shiftTemplates || [];
  const [kind, setKind] = useState<"EVENT" | "HOT_DAY">("EVENT");
  const [startDate, setStartDate] = useState(`${month}-01`);
  const [endDate, setEndDate] = useState(`${month}-01`);
  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [locationId, setLocationId] = useState(locations[0]?.id || "");
  const [roleId, setRoleId] = useState(roles[0]?.id || "");
  const [selectedTemplates, setSelectedTemplates] = useState<string[]>([]);
  const [count, setCount] = useState(1);
  const [limit, setLimit] = useState(0);
  useEffect(() => {
    if (!roles.some(role => role.id === roleId)) setRoleId(roles[0]?.id || "");
    if (!locations.some(location => location.id === locationId)) setLocationId(locations[0]?.id || "");
  }, [locationId, locations, roleId, roles]);
  const dayOfWeek = startDate ? ((new Date(`${startDate}T12:00:00Z`).getUTCDay() + 6) % 7) + 1 : 1;
  const visibleTemplates = useMemo(() => templates.filter(template => template.locationId === locationId && template.dayMask.includes(dayOfWeek)), [dayOfWeek, locationId, templates]);
  useEffect(() => { setSelectedTemplates(visibleTemplates.map(template => template.id)); }, [locationId, startDate]); // eslint-disable-line react-hooks/exhaustive-deps
  const submit = async (event: React.FormEvent) => {
    event.preventDefault();
    if (!startDate || !endDate || endDate < startDate || !title.trim() || !roleId) return;
    if (kind === "EVENT" && (!locationId || !selectedTemplates.length)) return;
    const ok = await save({ startDate, endDate, kind, title, description, locationId: kind === "EVENT" ? locationId : undefined, roleId, shiftTemplateIds: selectedTemplates, additionalCount: count, maximumHardUnavailable: limit });
    if (ok) { setTitle(""); setDescription(""); }
  };
  return <section className="operational-calendar-panel">
    <div className="matrix-demand-head"><div><h3>Kalendarz operacyjny i alerty dostępności</h3><p>Wydarzenie zwiększa wymaganą obsadę w konkretnym dniu i na wskazanych zmianach. Limit nieobecności kieruje nadmiarowe zgłoszenia do lidera.</p></div><span>{context.events.length} zdarzeń</span></div>
    {context.canManage && <details className="operational-additional-tools">
      <summary><span><Plus/><strong>Narzędzia dodatkowe</strong><small>Dodaj wydarzenie, zwiększoną obsadę albo limit nieobecności tylko wtedy, gdy jest potrzebny.</small></span></summary>
      <form className="operational-event-form" onSubmit={event => void submit(event)}>
      <div className="segmented-choice"><button type="button" className={kind === "EVENT" ? "active" : ""} onClick={() => setKind("EVENT")}><Megaphone /> Wydarzenie + obsada</button><button type="button" className={kind === "HOT_DAY" ? "active" : ""} onClick={() => setKind("HOT_DAY")}><Flame /> Limit nieobecności</button></div>
      <div className="form-row"><label>Od dnia<input type="date" min={`${month}-01`} max={`${month}-${String(new Date(Number(month.slice(0, 4)), Number(month.slice(5, 7)), 0).getDate()).padStart(2, "0")}`} value={startDate} onChange={event => { setStartDate(event.target.value); if (endDate < event.target.value) setEndDate(event.target.value); }} required /></label><label>Do dnia<input type="date" min={startDate || `${month}-01`} max={`${month}-${String(new Date(Number(month.slice(0, 4)), Number(month.slice(5, 7)), 0).getDate()).padStart(2, "0")}`} value={endDate} onChange={event => setEndDate(event.target.value)} required /></label><label>Nazwa<input value={title} maxLength={160} onChange={event => setTitle(event.target.value)} placeholder={kind === "EVENT" ? "np. Koncert — większy ruch" : "np. Długi weekend"} required /></label></div>
      <label>Opis (opcjonalnie)<textarea value={description} maxLength={500} onChange={event => setDescription(event.target.value)} /></label>
      <fieldset className="operational-card-picker"><legend>Rola</legend>{roles.map(role => <button type="button" key={role.id} className={roleId === role.id ? "active" : ""} onClick={() => setRoleId(role.id)}>{role.name}</button>)}</fieldset>
      {kind === "EVENT" ? <><fieldset className="operational-card-picker"><legend>Lokal</legend>{locations.map(location => <button type="button" key={location.id} className={locationId === location.id ? "active" : ""} onClick={() => setLocationId(location.id)}>{location.name}</button>)}</fieldset><fieldset className="operational-shift-picker"><legend>Zmiany objęte dodatkową obsadą</legend>{visibleTemplates.map(template => <label key={template.id}><input type="checkbox" checked={selectedTemplates.includes(template.id)} onChange={() => setSelectedTemplates(current => current.includes(template.id) ? current.filter(id => id !== template.id) : [...current, template.id])} /><span><b>{template.name}</b><small>{String(template.startsAt).slice(0, 5)}–{String(template.endsAt).slice(0, 5)}</small></span></label>)}</fieldset><label className="compact-number">Dodatkowe osoby na każdej zaznaczonej zmianie<input type="number" min={1} max={500} value={count} onChange={event => setCount(Number(event.target.value))} /></label></> : <label className="compact-number">Ile twardych niedostępności roli można przyjąć automatycznie?<input type="number" min={0} max={500} value={limit} onChange={event => setLimit(Number(event.target.value))} /><small>Kolejne zgłoszenie będzie oczekiwać na decyzję lidera.</small></label>}
      <button className="primary-button" disabled={busy || (kind === "EVENT" && !selectedTemplates.length)}><Save /> Zapisz i zostań tutaj</button>
      </form>
    </details>}
    <div className="operational-event-list">{context.events.map(event => <article key={event.id} className={event.kind.toLowerCase()}>{event.kind === "HOT_DAY" ? <Flame /> : <Megaphone />}<span><small>{event.date} • {event.kind === "HOT_DAY" ? "Limit nieobecności" : event.locationName || "Wydarzenie"}</small><h4>{event.title}</h4><p>{event.kind === "EVENT" ? event.demands?.map(demand => `+${demand.additionalCount} ${demand.roleName} • ${demand.shiftName}`).join("; ") : event.hotLimits?.map(item => `${item.roleName}: automatycznie do ${item.maximumHardUnavailable}`).join("; ")}</p></span></article>)}</div>
    {context.canManage && Boolean(context.availabilitySummary?.length) && <details className="availability-daily-summary technical-details"><summary><span><CalendarDays /><strong>Techniczne zestawienie dostępności dzień po dniu</strong><small>Otwórz, gdy analizujesz limity lub pojedyncze zgłoszenia.</small></span></summary><div>{context.availabilitySummary?.map(item=><details key={`${item.date}:${item.roleId}`}><summary><b>{item.date} • {item.roleName}</b><span><em>{item.hardCount} twardych</em><em>{item.availableCount??"—"}/{item.totalCount??"—"} dostępnych</em><em>{item.progressPercent??0}% zgłoszeń</em>{item.pendingCount>0&&<em>{item.pendingCount} oczekuje</em>}</span></summary><p>{item.hardEmployees.length?`Twardo niedostępni: ${item.hardEmployees.join(", ")}. `:""}{item.softEmployees.length?`Wolą nie pracować: ${item.softEmployees.join(", ")}. `:""}{item.pendingEmployees.length?`Do decyzji: ${item.pendingEmployees.join(", ")}.`:""}</p>{item.lastUpdatedAt&&<small>Ostatnia aktualizacja: {new Intl.DateTimeFormat("pl-PL",{dateStyle:"short",timeStyle:"short"}).format(new Date(item.lastUpdatedAt))}</small>}</details>)}</div></details>}
    {context.canManage && context.pendingReviews.length > 0 && <section className="availability-review-list"><h4><Flame /> Wnioski o nieobecność wymagające decyzji</h4>{context.pendingReviews.map(item => <article key={item.id}><span><b>{item.employeeName} • {item.employeeNo}</b><small>{item.date} • {item.roleName}{item.note ? ` • ${item.note}` : ""}</small></span><div><button className="primary-button" disabled={busy} onClick={() => void review(item.id, "APPROVE")}>Akceptuj</button><button className="secondary-button" disabled={busy} onClick={() => void review(item.id, "REJECT")}>Odrzuć</button></div></article>)}</section>}
  </section>;
}

function EmployeePortal({ portal, month, timezone, dynamic, roleNames, roleColors, openAvailability, openPreferences, requestSwap, loadSwapCandidates, decideSwapAsEmployee, decideSwapAsLeader, masterMode, busy, section, availabilityWorkspace, locations, saveAvailability, fail }: {
  portal: PortalWorkspace;
  month: string;
  timezone: string;
  dynamic: boolean;
  roleNames: Record<string, string>;
  roleColors: Record<string, string>;
  openAvailability: () => void;
  openPreferences: () => void;
  requestSwap: (assignmentId: string, targetEmployeeId: string | null, message: string) => Promise<boolean>;
  loadSwapCandidates: (assignmentId: string) => Promise<ShiftSwapCandidate[]>;
  decideSwapAsEmployee: (requestId: string, decision: "ACCEPT" | "REJECT") => Promise<boolean>;
  decideSwapAsLeader: (requestId: string, decision: "APPROVE" | "REJECT") => Promise<boolean>;
  masterMode: boolean;
  busy: boolean;
  section: EmployeePortalSection;
  availabilityWorkspace?:PortalTimeConstraintsWorkspace;
  locations:MatrixItem[];
  saveAvailability:(entry:{dates:string[];kind:"AVAILABLE"|"PREFER_NOT_TO_WORK"|"CANNOT_WORK";allDay:boolean;start?:string;end?:string;preferredLocationId?:string;note:string})=>Promise<boolean>;
  fail:(message:string)=>void;
}) {
  const employee = portal.employee;
  const [selected, setSelected] = useState<PortalAssignment | null>(null);
  const [selectedDay,setSelectedDay]=useState<string|null>(null);
  const [daySearch,setDaySearch]=useState("");
  useEffect(() => { setSelected(null);setSelectedDay(null);setDaySearch(""); }, [employee?.id]);
  const grouped = new Map<string, PortalAssignment[]>();
  portal.assignments.forEach((assignment) => grouped.set(assignment.date, [...(grouped.get(assignment.date) || []), assignment]));
  const selectedDayAssignments=selectedDay?grouped.get(selectedDay)||[]:[];
  const standbyByDay = new Map<string, SolverEmployeeStandby[]>();
  portal.standby.forEach((entry) => standbyByDay.set(entry.date, [...(standbyByDay.get(entry.date) || []), entry]));
  const eventsByDay = new Map<string, WorkforceCalendarEvent[]>();
  portal.calendarContext?.events.forEach((entry) => eventsByDay.set(entry.date, [...(eventsByDay.get(entry.date) || []), entry]));
  const swapAnnouncementsByDay = new Map<string, ShiftSwapRequest[]>();
  portal.swapBoard?.requests.filter(request=>["OPEN","EMPLOYEE_ACCEPTED"].includes(request.status)).forEach((entry)=>swapAnnouncementsByDay.set(entry.date,[...(swapAnnouncementsByDay.get(entry.date)||[]),entry]));
  const monthlyMinutes = portal.assignments.reduce((sum, assignment) => sum + Math.max(0, Math.round((new Date(assignment.endsAt).getTime() - new Date(assignment.startsAt).getTime()) / 60_000)), 0);
  const [year, monthNumber] = month.split("-").map(Number);
  const first = new Date(Date.UTC(year, monthNumber - 1, 1, 12));
  const offset = (first.getUTCDay() + 6) % 7;
  const dayCount = new Date(Date.UTC(year, monthNumber, 0, 12)).getUTCDate();
  const cells = Array.from({ length: offset + dayCount }, (_, index) => index < offset ? 0 : index - offset + 1);
  const monthName = labelMonth(month, timezone);
  const showMine = section === "overview" || section === "my-schedule";
  const showCompany = section === "overview" || section === "company-schedule";
  const showAvailability = section === "overview" || section === "availability";
  const showSwaps = section === "overview" || section === "swaps";
  const sectionCopy: Record<EmployeePortalSection, { title: string; subtitle: string }> = {
    overview: { title: "Mój grafik i sprawy pracownicze", subtitle: "Opublikowane zmiany, dostępność, rezerwa i zamiany w jednym miejscu." },
    "my-schedule": { title: "Mój grafik", subtitle: "Moje opublikowane zmiany, wydarzenia i dyżury rezerwowe." },
    "company-schedule": { title: "Grafik firmy", subtitle: "Czytelny podgląd tego, kto pracuje w wybranym dniu." },
    availability: { title: "Moja dostępność", subtitle: "Zaznacz wyjątki oraz dokładne preferowane godziny bez szukania formularza w grafiku." },
    swaps: { title: "Zamiany zmian", subtitle: "Ogłoszenia, zgody pracowników i decyzje liderów w jednym procesie." },
  };
  const exportSchedule = () => {
    const workbook = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(workbook, XLSX.utils.json_to_sheet(portal.assignments.map((assignment) => ({
      DATA: assignment.date,
      OD: time(assignment.startsAt, assignmentTimezone(assignment, timezone)),
      DO: time(assignment.endsAt, assignmentTimezone(assignment, timezone)),
      LOKAL: assignment.location,
      ZMIANA: portalShiftLabel(assignment),
    }))), "MÓJ_GRAFIK");
    XLSX.writeFile(workbook, `MOJ_GRAFIK_${month.replace("-", "_")}.xlsx`);
  };
  return <><PageHead eyebrow={masterMode ? "UAT MASTER • WIDOK PRACOWNIKA" : "WIDOK PRACOWNIKA"} title={sectionCopy[section].title} subtitle={sectionCopy[section].subtitle} actions={showMine?<button className="secondary-button" onClick={exportSchedule}><Download /> Excel</button>:undefined} />
    {masterMode && <div className="uat-master-active-banner"><ShieldCheck /><span><b>Testujesz widok: {employee?.firstName} {employee?.lastName} • {employee?.employeeNo}</b><small>Zapisy dostępności i preferencji są wykonywane dla tej osoby oraz oznaczone w audycie jako UAT MASTER. Akcje zamiany pozostają zablokowane.</small></span></div>}
    {portal.publicationConflict && <div className="solver-v2-notice warning"><AlertTriangle /><span><strong>Właściciel musi rozstrzygnąć konflikt publikacji grafiku ról i firmy.</strong><small>Dostępność i preferencje można testować, ale opublikowane zmiany są ukryte do czasu wyboru ważnej wersji.</small></span></div>}
    <section className="employee-portal-callouts"><article><CalendarDays/><span><b>Grafik i dostępność razem</b><small>Na jednym dniu widzisz zmianę, lokal, rezerwę, wydarzenie i swoją deklarację.</small></span></article><article><ArrowLeftRight/><span><b>Zamiana bez przeklikiwania</b><small>Otwórz dzień ze zmianą i od razu opublikuj propozycję do wybranej osoby albo całej tablicy.</small></span></article><article><Megaphone/><span><b>Sprawy zespołu</b><small>Aktywne propozycje zamian są oznaczone również na kalendarzu.</small></span></article></section>
    {(showMine || showAvailability) && <div className="portal-grid portal-top"><section className="portal-profile"><UserRound />{masterMode || !dynamic ? <><h3>{employee?.firstName} {employee?.lastName}</h3><p>{employee?.employeeNo} • {employee ? rolePl[employee.primaryRole] || employee.primaryRole : "—"}</p><span>{employee?.locations.map((location) => location.name).join(", ") || "Brak przypisanego lokalu"}</span></> : <><h3>Moje konto</h3><p>Profil konfiguracji firmy</p><span>Role i lokale wynikają z opublikowanej konfiguracji.</span></>}</section>{showAvailability&&<section><h3>Grafik i dostępność w jednym kalendarzu</h3><p>Zmiana, rezerwa, wydarzenie i Twoja deklaracja są nałożone na ten sam dzień. Edytor znajduje się bezpośrednio pod podsumowaniem.</p></section>}</div>}
    {showMine&&<><section className="employee-month-summary"><span><small>Zaplanowane godziny</small><strong>{Math.floor(monthlyMinutes / 60)} h {monthlyMinutes % 60 ? `${monthlyMinutes % 60} min` : ""}</strong></span><span><small>Wszystkie zmiany</small><strong>{portal.assignments.length}</strong></span><span className="standby-summary"><small>Dyżury rezerwowe</small><strong>{portal.standby.length}</strong><em>osobno od godzin</em></span></section>
    {availabilityWorkspace&&<AvailabilityCalendarDrawer embedded workspace={availabilityWorkspace} month={month} locations={locations} save={saveAvailability} fail={fail} busy={busy} calendarContext={portal.calendarContext} assignments={portal.assignments} onSelectDay={setSelectedDay}/>} 
    <section className="employee-calendar-card"><div className="matrix-demand-head"><div><h3>Moje opublikowane zmiany — {monthName}</h3><p>Wybierz dzień, aby od razu zobaczyć swoje zmiany i osoby pracujące razem z Tobą.</p></div></div><div className="role-calendar-week">{days.map((day) => <b key={day}>{day}</b>)}</div><div className="employee-month-calendar">{cells.map((day, index) => {
    const date = day ? `${month}-${String(day).padStart(2, "0")}` : "";
    const events = eventsByDay.get(date) || [];
    const swapAnnouncements=swapAnnouncementsByDay.get(date)||[];
    const assignments=grouped.get(date)||[];
    return <section className={`${!day ? "blank" : ""} ${events.some(event => event.kind === "HOT_DAY") ? "has-hot-day" : ""} ${swapAnnouncements.length?"has-swap-announcement":""} ${selectedDay===date?"selected":""}`} key={index}>{day && <><button type="button" className="employee-day-open" onClick={()=>setSelectedDay(date)}><strong>{day}</strong><small>{assignments.length?`${assignments.length} ${assignments.length===1?"zmiana":"zmiany"}`:"Wolne"}</small></button>{swapAnnouncements.length>0&&<div className="portal-calendar-swap"><ArrowLeftRight/><span><b>Aktywna zamiana</b><small>{swapAnnouncements.length} {swapAnnouncements.length===1?"ogłoszenie":"ogłoszenia"}</small></span></div>}{events.map(event => <div key={event.id} className={`portal-calendar-event ${event.kind.toLowerCase()}`}>{event.kind === "HOT_DAY" ? <Flame /> : <Megaphone />}<span><b>{event.title}</b><small>{event.kind === "HOT_DAY" ? "Ograniczona niedostępność" : event.locationName || "Wydarzenie"}</small></span></div>)}{assignments.map((assignment) => <button key={assignment.id} onClick={() => setSelectedDay(date)} className="role-assignment"><b>{time(assignment.startsAt, assignmentTimezone(assignment, timezone))}–{time(assignment.endsAt, assignmentTimezone(assignment, timezone))}</b><small>{assignment.location} • {portalShiftLabel(assignment)}</small></button>)}{(standbyByDay.get(date) || []).map((entry) => <div key={entry.id} className={`portal-standby tier-${entry.tier} ${entry.status.toLowerCase()}`}><b>Rezerwa {entry.tier}</b><small>{entry.roleName}{entry.status === "ACTIVATED" ? " • aktywowana" : " • gotowość dzienna"}</small></div>)}</>}</section>;
  })}</div></section>
    {selectedDay&&<section className="employee-day-workspace">
      <header><span><small>WYBRANY DZIEŃ</small><h3>{selectedDay}</h3><p>Twoje zmiany i osoby pracujące razem z Tobą.</p></span><button className="icon-button" aria-label="Zamknij widok dnia" onClick={()=>setSelectedDay(null)}><X/></button></header>
      <label className="day-workspace-search">Filtruj osoby<input value={daySearch} onChange={event=>setDaySearch(event.target.value)} placeholder="Imię, rola, lokal lub nazwa zmiany"/></label>
      <div className="employee-day-shifts">{selectedDayAssignments.map(assignment=>{
        const query=daySearch.trim().toLocaleLowerCase("pl-PL");
        const coworkers=(assignment.coworkers||[]).filter(coworker=>!query||`${coworker.name} ${roleNames[coworker.role]??coworker.role} ${assignment.location} ${portalShiftLabel(assignment)}`.toLocaleLowerCase("pl-PL").includes(query));
        return <article key={assignment.id}><header><span><strong>{time(assignment.startsAt,assignmentTimezone(assignment,timezone))}–{time(assignment.endsAt,assignmentTimezone(assignment,timezone))}</strong><small>{assignment.location} • {portalShiftLabel(assignment)}</small></span>{!masterMode&&<button className="secondary-button" disabled={busy||new Date(assignment.startsAt)<=new Date()} onClick={()=>setSelected(assignment)}><ArrowLeftRight/> Zaproponuj zamianę</button>}</header><h4>Pracujesz z</h4><div className="employee-coworker-grid">{coworkers.length?coworkers.map((coworker,index)=><span style={roleCardStyle(coworker.role,roleColors[coworker.role])} key={`${coworker.name}:${index}`}><UserRound/><b>{coworker.name}</b><small>{dynamic?roleNames[coworker.role]??coworker.role:rolePl[coworker.role]||coworker.role}</small></span>):<p>{query?"Brak osób spełniających filtr.":"Na tej zmianie nie ma innych przypisanych osób."}</p>}</div></article>;
      })}{!selectedDayAssignments.length&&<p className="solver-workspace-empty">Tego dnia nie masz zaplanowanej zmiany.</p>}</div>
    </section>}
    </>}
    {showAvailability&&!showMine&&availabilityWorkspace&&<AvailabilityCalendarDrawer embedded workspace={availabilityWorkspace} month={month} locations={locations} save={saveAvailability} fail={fail} busy={busy} calendarContext={portal.calendarContext} assignments={portal.assignments} onSelectDay={setSelectedDay}/>} 
    {showSwaps && !masterMode && portal.swapBoard && <ShiftSwapBoardPanel board={portal.swapBoard} busy={busy} decideAsEmployee={decideSwapAsEmployee} decideAsLeader={decideSwapAsLeader} />}
    {showCompany && portal.companyCalendar && <CompanyScheduleCalendar calendar={portal.companyCalendar} month={month} timezone={timezone} events={portal.calendarContext?.events || []} roleColors={roleColors} />}
    {selected && <CoworkerDrawer assignment={selected} timezone={timezone} dynamic={dynamic} roleNames={roleNames} close={() => setSelected(null)} requestSwap={requestSwap} loadSwapCandidates={loadSwapCandidates} allowSwap={!masterMode} busy={busy} />}
  </>;
}

function ShiftSwapBoardPanel({ board, busy, decideAsEmployee, decideAsLeader }: {
  board: ShiftSwapBoard;
  busy: boolean;
  decideAsEmployee: (requestId: string, decision: "ACCEPT" | "REJECT") => Promise<boolean>;
  decideAsLeader: (requestId: string, decision: "APPROVE" | "REJECT") => Promise<boolean>;
}) {
  const [view,setView]=useState<"ACTIVE"|"TO_ME"|"MINE"|"HISTORY">("ACTIVE");
  const [query,setQuery]=useState("");
  const [location,setLocation]=useState("");
  const activeCount=board.requests.filter(request=>["OPEN","EMPLOYEE_ACCEPTED"].includes(request.status)).length;
  const locationOptions=[...new Set(board.requests.map(request=>request.locationName))].sort((a,b)=>a.localeCompare(b,"pl-PL"));
  const visible=board.requests.filter(request=>{
    const active=["OPEN","EMPLOYEE_ACCEPTED"].includes(request.status);
    const matchesView=view==="ACTIVE"?active:view==="TO_ME"?active&&request.targetEmployeeId===board.employeeId:view==="MINE"?request.isMine:view==="HISTORY"?!active:true;
    const normalized=query.trim().toLocaleLowerCase("pl-PL");
    const matchesQuery=!normalized||`${request.proposerName} ${request.targetName??""} ${request.acceptedByName??""} ${request.roleName} ${request.locationName} ${request.shiftName} ${request.message??""}`.toLocaleLowerCase("pl-PL").includes(normalized);
    return matchesView&&matchesQuery&&(!location||request.locationName===location);
  });
  return <section className="swap-board-card"><div className="matrix-demand-head"><div><h3><ArrowLeftRight /> Tablica zamian</h3><p>Przejęcie zmiany zawsze wymaga zgodności roli, lokalu, kompetencji, dostępności i odpoczynku. Po zgodzie pracownika decyzję podejmuje lider.</p></div><span>{activeCount} aktywnych • {board.requests.length} łącznie</span></div><div className="swap-board-toolbar"><input value={query} onChange={event=>setQuery(event.target.value)} placeholder="Szukaj osoby, roli, lokalu lub zmiany"/><select value={view} onChange={event=>setView(event.target.value as typeof view)}><option value="ACTIVE">Aktywne propozycje</option><option value="TO_ME">Skierowane do mnie</option><option value="MINE">Moje ogłoszenia</option><option value="HISTORY">Historia zakończonych</option></select><select value={location} onChange={event=>setLocation(event.target.value)}><option value="">Wszystkie lokale</option>{locationOptions.map(item=><option key={item}>{item}</option>)}</select></div>{visible.length ? <div className="swap-board-list">{visible.map(request => <article key={request.id}><div><small>{request.date} • {time(request.startsAt)}–{time(request.endsAt)}</small><h4>{request.shiftName} • {request.locationName}</h4><p><b>{request.proposerName}</b> • {request.roleName}{request.targetName?` → ${request.targetName}`:" • ogłoszenie otwarte"}{request.message ? ` — ${request.message}` : ""}</p>{request.acceptedByName&&<p>Przejęcie zaproponował(a): <b>{request.acceptedByName}</b></p>}</div><span className={`swap-status ${request.status.toLowerCase()}`}>{swapStatusLabel(request.status)}</span><div className="swap-actions">{request.status === "OPEN" && !request.isMine && request.eligible && <button className="primary-button" disabled={busy} onClick={() => void decideAsEmployee(request.id, "ACCEPT")}>Mogę przejąć</button>}{request.status === "OPEN" && !request.isMine && !request.eligible && <small>{request.ineligibilityReasons.map(swapReasonLabel).join(" • ")}</small>}{request.status === "OPEN" && request.targetEmployeeId === board.employeeId && <button className="secondary-button" disabled={busy} onClick={() => void decideAsEmployee(request.id, "REJECT")}>Odrzuć</button>}{request.requiresLeaderDecision && board.canManage && <><button className="primary-button" disabled={busy} onClick={() => void decideAsLeader(request.id, "APPROVE")}>Akceptuj jako lider</button><button className="secondary-button" disabled={busy} onClick={() => void decideAsLeader(request.id, "REJECT")}>Odrzuć</button></>}</div>{Boolean(request.history?.length)&&<details className="swap-audit"><summary>Historia decyzji • {request.history?.length} zdarzeń</summary>{request.history?.map(entry=><div key={entry.id}><span><b>{swapHistoryLabel(entry.action)}</b><small>{entry.actorName}</small></span><time>{new Intl.DateTimeFormat("pl-PL",{dateStyle:"short",timeStyle:"short"}).format(new Date(entry.createdAt))}</time></div>)}</details>}</article>)}</div> : <p className="empty-inline">Brak ogłoszeń spełniających wybrane filtry.</p>}</section>;
}

function CompanyScheduleCalendar({ calendar, month, timezone, events, roleColors }: { calendar: CompanyCalendar; month: string; timezone: string; events: WorkforceCalendarEvent[]; roleColors: Record<string,string> }) {
  const [selectedDate, setSelectedDate] = useState<string | null>(null);
  const [query,setQuery]=useState("");
  const [roleFilter,setRoleFilter]=useState("");
  const [locationFilter,setLocationFilter]=useState("");
  const [year, monthNumber] = month.split("-").map(Number);
  const offset = (new Date(Date.UTC(year, monthNumber - 1, 1, 12)).getUTCDay() + 6) % 7;
  const dayCount = new Date(Date.UTC(year, monthNumber, 0, 12)).getUTCDate();
  const cells = Array.from({ length: offset + dayCount }, (_, index) => index < offset ? 0 : index - offset + 1);
  const byDate = new Map<string, CompanyCalendarAssignment[]>();
  calendar.assignments.forEach(assignment => byDate.set(assignment.date, [...(byDate.get(assignment.date) || []), assignment]));
  const eventDates = new Set(events.map(event => event.date));
  const selected = selectedDate ? byDate.get(selectedDate) || [] : [];
  const roleOptions=[...new Map(calendar.assignments.map(item=>[item.roleId,{id:item.roleId,name:item.roleName}])).values()].sort((a,b)=>a.name.localeCompare(b.name,"pl-PL"));
  const locationOptions=[...new Map(calendar.assignments.map(item=>[item.locationId,{id:item.locationId,name:item.locationName}])).values()].sort((a,b)=>a.name.localeCompare(b.name,"pl-PL"));
  const filtered=selected.filter(item=>{
    const normalized=query.trim().toLocaleLowerCase("pl-PL");
    return (!normalized||`${item.employeeName} ${item.employeeNo} ${item.roleName} ${item.locationName} ${item.shiftName}`.toLocaleLowerCase("pl-PL").includes(normalized))
      &&(!roleFilter||item.roleId===roleFilter)&&(!locationFilter||item.locationId===locationFilter);
  });
  const groups=[...filtered.reduce((result,item)=>{
    const key=`${item.locationId}:${item.startsAt}:${item.endsAt}:${item.shiftName}`;
    result.set(key,[...(result.get(key)||[]),item]);return result;
  },new Map<string,CompanyCalendarAssignment[]>()).values()];
  return <section className="company-calendar-card"><div className="matrix-demand-head"><div><h3>Grafik firmy</h3><p>Wybierz dzień, a potem filtruj po osobie, roli lub lokalu. Widok służy także do znalezienia osoby do zamiany.</p></div></div><div className="role-calendar-week">{days.map(day => <b key={day}>{day}</b>)}</div><div className="company-month-calendar">{cells.map((day, index) => {
    const date = day ? `${month}-${String(day).padStart(2, "0")}` : "";
    const assignments = byDate.get(date) || [];
    return <button type="button" key={index} className={`${!day ? "blank" : ""} ${eventDates.has(date) ? "has-event" : ""} ${selectedDate === date ? "selected" : ""}`} disabled={!day} onClick={() => setSelectedDate(date)}>{day && <><b>{day}</b><strong>{assignments.length} os.</strong>{assignments.some(assignment => assignment.isSwap) && <small>Zamiana</small>}{eventDates.has(date) && <Megaphone />}</>}</button>;
  })}</div>{selectedDate && <section className="company-day-workspace"><header><span><small>OBSADA WYBRANEGO DNIA</small><h3>{selectedDate}</h3><p>{filtered.length} osób po zastosowaniu filtrów</p></span><button className="icon-button" onClick={() => setSelectedDate(null)}><X /></button></header><div className="company-day-filters"><label>Znajdź osobę lub zmianę<input value={query} onChange={event=>setQuery(event.target.value)} placeholder="Imię, numer, rola, lokal lub zmiana"/></label><label>Rola<select value={roleFilter} onChange={event=>setRoleFilter(event.target.value)}><option value="">Wszystkie role</option>{roleOptions.map(role=><option value={role.id} key={role.id}>{role.name}</option>)}</select></label><label>Lokal<select value={locationFilter} onChange={event=>setLocationFilter(event.target.value)}><option value="">Wszystkie lokale</option>{locationOptions.map(location=><option value={location.id} key={location.id}>{location.name}</option>)}</select></label><button className="secondary-button" onClick={()=>{setQuery("");setRoleFilter("");setLocationFilter("");}}>Wyczyść</button></div><div className="company-day-groups">{groups.map(group=>{const first=group[0];return <article key={`${first.locationId}:${first.startsAt}:${first.shiftName}`}><header><span><b>{time(first.startsAt,timezone)}–{time(first.endsAt,timezone)}</b><small>{first.shiftName}</small></span><strong>{first.locationName}</strong></header><div>{group.map(assignment=><span className="company-day-person" style={roleCardStyle(assignment.roleId,roleColors[assignment.roleId])} key={assignment.id}><UserRound/><b>{assignment.employeeName}</b><small>{assignment.roleName} • {assignment.employeeNo}{assignment.isSwap?" • zamiana":""}</small></span>)}</div></article>})}{!groups.length&&<p className="solver-workspace-empty">Brak osób spełniających wybrane filtry.</p>}</div></section>}</section>;
}

function ShiftPreferencesDrawer({ workspace, month, close, save, busy }: { workspace: PortalShiftPreferences; month: string; close: () => void; save: (preferences: Record<ShiftPeriod, ShiftPreferenceLevel>) => Promise<boolean>; busy: boolean }) {
  const [preferences, setPreferences] = useState(workspace.employee);
  const periods: readonly (readonly [ShiftPeriod, string])[] = [["MORNING", "Rano"], ["MIDDLE", "Środek"], ["EVENING", "Wieczór"]];
  return <><button className="drawer-scrim" onClick={close} /><aside className="drawer complete-drawer shift-preferences-drawer"><div className="drawer-head"><div><p className="eyebrow">PORTAL PRACOWNIKA • PREFERENCJE</p><h2>Preferowane godziny • {labelMonth(month)}</h2></div><button className="icon-button" onClick={close}><X /></button></div><div className="drawer-content"><p>To starszy sposób zapisu preferencji. Dokładną dostępność ustaw w kalendarzu godzinowym.</p>{periods.map(([period, label]) => <section className="shift-preference-row" key={period}><span><strong>{label}</strong>{workspace.managerOverrides?.[period] ? <small><ShieldCheck /> Ustawienie pracodawcy: {preferenceLevelLabel(workspace.managerOverrides[period])}</small> : <small>Aktualne ustawienie: {preferenceLevelLabel(workspace.effective?.[period] ?? preferences[period])}</small>}</span><select value={preferences[period]} onChange={(event) => setPreferences((current) => ({ ...current, [period]: event.target.value as ShiftPreferenceLevel }))}><option value="PREFERRED">Preferuję</option><option value="NEUTRAL">Neutralnie</option><option value="AVOIDED">Wolę unikać</option></select></section>)}<button className="primary-button full" disabled={busy} onClick={() => void save(preferences)}><Save /> {busy ? "Zapisuję…" : "Zapisz preferencje"}</button></div></aside></>;
}

function AvailabilityCalendarDrawer({ workspace, month, locations, close, save, fail, busy, calendarContext, assignments, embedded=false, onSelectDay }: {
  workspace: PortalTimeConstraintsWorkspace;
  month: string;
  locations: MatrixItem[];
  close?: () => void;
  save: (entry: { dates: string[]; kind: "AVAILABLE" | "PREFER_NOT_TO_WORK" | "CANNOT_WORK"; allDay: boolean; start?: string; end?: string; preferredLocationId?: string; note: string }) => Promise<boolean>;
  fail: (message: string) => void;
  busy: boolean;
  calendarContext?: WorkforceCalendarContext;
  assignments: PortalAssignment[];
  embedded?:boolean;
  onSelectDay?:(date:string)=>void;
}) {
  const timezone=workspace.timezone;
  const [year,monthNumber]=month.split("-").map(Number);
  const dayCount=new Date(Date.UTC(year,monthNumber,0,12)).getUTCDate();
  const monthDates=useMemo(()=>Array.from({length:dayCount},(_,index)=>`${month}-${String(index+1).padStart(2,"0")}`),[dayCount,month]);
  const calendarOffset=(new Date(`${month}-01T12:00:00Z`).getUTCDay()+6)%7;
  const [selectedDays,setSelectedDays]=useState<string[]>([]);
  const [rangeAnchor,setRangeAnchor]=useState<string|null>(null);
  const [kind,setKind]=useState<"AVAILABLE"|"PREFER_NOT_TO_WORK"|"CANNOT_WORK">("AVAILABLE");
  const [allDay,setAllDay]=useState(true);
  const [start,setStart]=useState("08:00");
  const [end,setEnd]=useState("16:00");
  const [preferredLocationId,setPreferredLocationId]=useState("");
  const [note,setNote]=useState("");

  const entriesByDay=useMemo(()=>{
    const result=new Map<string,PortalTimeConstraint[]>();
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
