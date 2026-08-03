"use client";

import {
  AlertTriangle,
  CalendarDays,
  Download,
  Plus,
  Save,
  ShieldCheck,
  Trash2,
  UserRound,
  WandSparkles,
  X,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import * as XLSX from "xlsx";

import { RoleCompositePanel } from "@/components/RoleCompositePanel";
import {
  getEmployeePublishedAssignments,
  type SolverEmployeePublishedAssignment,
  type SolverEngine,
  type SolverRole,
  type SolverScenario,
} from "@/lib/solver-v2";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";

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
};
type PortalTimeConstraintsWorkspace = {
  employeeId: string;
  timezone: string;
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
  attendance: { id: string; action: string; occurredAt: string; location: string }[];
  timeConstraints?: PortalTimeConstraintsWorkspace;
  shiftPreferences?: PortalShiftPreferences;
};

type View = "rolePlans" | "portal" | "czas" | "integracje";
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
  solverScenarios = [],
  solverRoles = [],
  solverUserId,
  roleCompositeRefreshKey = 0,
  timezone,
  onOpenSolverV2,
}: {
  month: string;
  view: View;
  data: ActiveWorkspace;
  reload: () => Promise<void>;
  notify: (message: string) => void;
  fail: (message: string) => void;
  solverEngine?: SolverEngine;
  solverVersion?: string;
  solverScenarios?: SolverScenario[];
  solverRoles?: SolverRole[];
  solverUserId?: string;
  roleCompositeRefreshKey?: number;
  timezone: string;
  currency: string;
  onOpenSolverV2?: (role: SolverRole) => void;
}) {
  const selectedMonthDate = `${month}-01`;
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const [busy, setBusy] = useState(false);
  const [portal, setPortal] = useState<PortalWorkspace | null>(null);
  const [availabilityOpen, setAvailabilityOpen] = useState(false);
  const [shiftPreferencesOpen, setShiftPreferencesOpen] = useState(false);
  const rolePlanningEnabled = solverEngine === "ORTOOLS_V2" || solverEngine === "SHADOW";
  const portalLoadToken = useRef(0);
  const portalMonthRef = useRef(selectedMonthDate);
  portalMonthRef.current = selectedMonthDate;
  const dynamicRoleNames = useMemo(
    () => Object.fromEntries(solverRoles.flatMap((role) => [[role.id, role.name], [role.code, role.name], [role.name, role.name]])),
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

  const loadPortal = useCallback(async () => {
    const requestedMonth = selectedMonthDate;
    if (!supabase || view !== "portal" || portalMonthRef.current !== requestedMonth) return;
    const token = ++portalLoadToken.current;
    const assignmentsRequest: Promise<{ portal?: PortalWorkspace; assignments: PortalAssignment[]; error: Error | null }> =
      solverEngine === "ORTOOLS_V2"
        ? getEmployeePublishedAssignments(supabase, requestedMonth)
            .then((assignments) => ({ assignments, error: null }))
            .catch((cause) => ({ assignments: [], error: cause instanceof Error ? cause : new Error(String(cause)) }))
        : solverEngine
          ? Promise.resolve(supabase.rpc("employee_portal_workspace", { p_month: requestedMonth })).then((result) => {
              if (result.error || !result.data) return { assignments: [], error: new Error(result.error?.message || "Brak danych portalu pracownika.") };
              const legacyPortal = result.data as PortalWorkspace;
              return { portal: legacyPortal, assignments: legacyPortal.assignments || [], error: null };
            })
          : Promise.resolve({ assignments: [], error: new Error("Konfiguracja silnika jest niedostępna.") });
    const [assignmentsResult, constraintsResult, preferencesResult] = await Promise.all([
      assignmentsRequest,
      supabase.rpc("employee_time_constraints_self_v2", { p_month: requestedMonth }),
      supabase.rpc("employee_shift_preferences_self_v2", { p_month: requestedMonth }),
    ]);
    if (token !== portalLoadToken.current || portalMonthRef.current !== requestedMonth) return;
    const errors: string[] = [];
    if (assignmentsResult.error) errors.push(translateError(assignmentsResult.error.message));
    let timeConstraints: PortalTimeConstraintsWorkspace | undefined;
    if (constraintsResult.error || !constraintsResult.data) {
      errors.push(`Nie udało się pobrać okien dostępności: ${translateError(constraintsResult.error?.message || "Brak danych odpowiedzi.")}`);
    } else {
      const payload = constraintsResult.data as Partial<PortalTimeConstraintsWorkspace>;
      if (!payload.employeeId) errors.push("Odpowiedź Matrixa nie zawiera identyfikatora pracownika.");
      else timeConstraints = { employeeId: payload.employeeId, timezone: payload.timezone || timezone, constraints: payload.constraints || [] };
    }
    let shiftPreferences: PortalShiftPreferences | undefined;
    if (preferencesResult.error || !preferencesResult.data) {
      errors.push(`Nie udało się pobrać preferencji zmianowych: ${translateError(preferencesResult.error?.message || "Brak danych odpowiedzi.")}`);
    } else shiftPreferences = preferencesResult.data as PortalShiftPreferences;
    if (errors.length) fail(errors.join(" • "));
    setPortal({
      ...assignmentsResult.portal,
      assignments: assignmentsResult.assignments,
      attendance: assignmentsResult.portal?.attendance || [],
      timeConstraints,
      shiftPreferences,
    });
  }, [fail, selectedMonthDate, solverEngine, supabase, timezone, view]);

  useEffect(() => {
    setPortal(null);
    setAvailabilityOpen(false);
    setShiftPreferencesOpen(false);
    portalLoadToken.current += 1;
  }, [selectedMonthDate, solverEngine]);
  useEffect(() => {
    void loadPortal();
    return () => { portalLoadToken.current += 1; };
  }, [loadPortal]);

  async function saveTimeConstraint(entry: { dates: string[]; kind: "AVAILABLE" | "PREFER_NOT_TO_WORK" | "CANNOT_WORK"; allDay: boolean; start?: string; end?: string; preferredLocationId?: string; note: string }) {
    const result = await rpc("employee_availability_days_save_v2", {
      p_dates: entry.dates,
      p_kind: entry.kind,
      p_all_day: entry.allDay,
      p_local_start: entry.allDay ? null : entry.start,
      p_local_end: entry.allDay ? null : entry.end,
      p_preferred_location_id: entry.preferredLocationId || null,
      p_note: entry.note || null,
    });
    if (!result) return false;
    notify("Zapisano wybrany zakres dostępności.");
    await loadPortal();
    await reload();
    return true;
  }

  async function revokeTimeConstraint(id: string) {
    if (!confirm("Odwołać ten własny wpis dostępności? Historia pozostanie zachowana.")) return;
    const result = await rpc("employee_availability_entry_revoke_uat_v2", { p_id: id });
    if (result) {
      notify("Wpis dostępności został odwołany.");
      await loadPortal();
      await reload();
    }
  }

  async function saveShiftPreferences(preferences: Record<ShiftPeriod, ShiftPreferenceLevel>) {
    const result = await rpc("employee_shift_preferences_save_self_v2", {
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

  async function exportKadromierz() {
    if (solverEngine !== "ORTOOLS_V2") {
      fail("Eksport starego grafiku jest wyłączony. Najpierw opublikuj grafik OR-Tools.");
      return;
    }
    const rows = await rpc("optimizer_kadromierz_export_v2", { p_month: selectedMonthDate });
    if (Array.isArray(rows)) downloadCsv(`grafik-kadromierz-${month}.csv`, rows);
  }

  if (view === "czas") return <RetiredModule title="Ewidencja czasu czeka na kontrakt Matrix v2" />;
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
      title="Grafiki według roli"
      subtitle="Lider wybiera scenariusz, porównuje trzy warianty i publikuje gotowy grafik swojego zespołu bez czekania na pozostałe role."
    />
    <div className="role-plan-cards">{solverRoles.map((role) => <article key={role.id}>
      <i style={{ background: "#7257d8" }} />
      <div><small>GRAFIK ROLI</small><h3>{role.name}</h3><p>Scenariusze, warianty i analiza OR-Tools.</p></div>
      <span className="workflow-status empty">{solverEngine === "SHADOW" ? "Test bez publikacji" : "Warianty dynamiczne"}</span>
      <strong>OR-Tools</strong>
      <div className="card-actions"><button disabled={busy || !onOpenSolverV2} className="primary-button" onClick={() => onOpenSolverV2?.(role)}><WandSparkles /> Otwórz generator</button></div>
    </article>)}</div>
    {solverEngine === "SHADOW" && <div className="solver-v2-notice warning"><ShieldCheck />Tryb SHADOW pozwala wygenerować i porównać trzy warianty każdej roli. Publikacja zespołu i wspólnego grafiku pozostaje zablokowana do kontrolowanego przełączenia.</div>}
    {solverEngine === "ORTOOLS_V2" && solverUserId && solverVersion ? <RoleCompositePanel
      engine={solverEngine}
      solverVersion={solverVersion}
      userId={solverUserId}
      month={selectedMonthDate}
      timezone={timezone}
      scenarios={solverScenarios}
      refreshKey={roleCompositeRefreshKey}
      onPublished={async () => { notify("Scalony grafik ról został opublikowany"); await reload(); }}
    /> : solverEngine === "ORTOOLS_V2" ? <div className="solver-v2-notice warning"><AlertTriangle />Brak kompletnej konfiguracji generatora.</div> : null}
  </>;
  return <>
    {portal ? <EmployeePortal
      portal={portal}
      month={month}
      timezone={timezone}
      dynamic={solverEngine === "ORTOOLS_V2"}
      roleNames={dynamicRoleNames}
      openAvailability={() => portal.timeConstraints ? setAvailabilityOpen(true) : fail("Odśwież portal przed edycją dostępności.")}
      openPreferences={() => portal.shiftPreferences ? setShiftPreferencesOpen(true) : fail("Odśwież portal przed edycją preferencji.")}
    /> : <div className="empty-state">Konto nie jest powiązane z pracownikiem.</div>}
    {availabilityOpen && portal?.timeConstraints && <AvailabilityWindowsDrawer
      workspace={portal.timeConstraints}
      month={month}
      locations={data.locations}
      close={() => setAvailabilityOpen(false)}
      save={saveTimeConstraint}
      revoke={revokeTimeConstraint}
      fail={fail}
      busy={busy}
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

function PageHead({ eyebrow, title, subtitle, actions }: { eyebrow: string; title: string; subtitle: string; actions?: React.ReactNode }) {
  return <div className="module-page-head"><div><p className="eyebrow">{eyebrow}</p><h2>{title}</h2><p>{subtitle}</p></div><div>{actions}</div></div>;
}

function RetiredModule({ title }: { title: string }) {
  return <><PageHead eyebrow="ALPHA 16" title={title} subtitle="Aplikacja nie wykona zapisu przez wycofany model Alpha 15." /><section className="empty-engine"><ShieldCheck /><h2>Brak konkurencyjnego zapisu</h2><p>Moduł zostanie uruchomiony wyłącznie po podłączeniu wersjonowanego kontraktu Matrix/OR-Tools.</p></section></>;
}

function IntegrationView({ busy, onExport, runCount }: { busy: boolean; onExport: () => void; runCount: number }) {
  return <><PageHead eyebrow="INTEGRACJE • OR-TOOLS" title="Kadromierz — bezpieczny eksport" subtitle="Eksport korzysta wyłącznie z opublikowanego grafiku nowego silnika." actions={<button disabled={busy} className="primary-button" onClick={onExport}><Download /> Eksport grafiku</button>} /><div className="integration-cards"><section><ShieldCheck /><h3>Import starego modelu jest wyłączony</h3><p>Dostępność i preferencje trafiają do Matrixa; duże zmiany są importowane w Matrixie z podglądem.</p></section><section><Download /><h3>Eksport do Kadromierza</h3><p>Opublikowane integracje w historii: {runCount}.</p><button disabled={busy} onClick={onExport}>Przygotuj eksport</button></section></div></>;
}

function EmployeePortal({ portal, month, timezone, dynamic, roleNames, openAvailability, openPreferences }: { portal: PortalWorkspace; month: string; timezone: string; dynamic: boolean; roleNames: Record<string, string>; openAvailability: () => void; openPreferences: () => void }) {
  const employee = portal.employee;
  const [selected, setSelected] = useState<PortalAssignment | null>(null);
  const grouped = new Map<string, PortalAssignment[]>();
  portal.assignments.forEach((assignment) => grouped.set(assignment.date, [...(grouped.get(assignment.date) || []), assignment]));
  const monthlyMinutes = portal.assignments.reduce((sum, assignment) => sum + Math.max(0, Math.round((new Date(assignment.endsAt).getTime() - new Date(assignment.startsAt).getTime()) / 60_000)), 0);
  const periodCounts = portal.assignments.reduce((counts, assignment) => {
    const label = `${assignment.shiftName ?? ""} ${assignment.shiftCode ?? ""}`.toLocaleLowerCase("pl-PL");
    const localHour = Number(new Intl.DateTimeFormat("en-GB", { hour: "2-digit", hourCycle: "h23", timeZone: assignmentTimezone(assignment, timezone) }).format(new Date(assignment.startsAt)));
    const period = label.includes("rano") || label.includes("morning") || localHour < 14 ? "morning" : label.includes("wiecz") || label.includes("evening") || localHour >= 16 ? "evening" : "middle";
    counts[period] += 1;
    return counts;
  }, { morning: 0, middle: 0, evening: 0 });
  const [year, monthNumber] = month.split("-").map(Number);
  const first = new Date(Date.UTC(year, monthNumber - 1, 1, 12));
  const offset = (first.getUTCDay() + 6) % 7;
  const dayCount = new Date(Date.UTC(year, monthNumber, 0, 12)).getUTCDate();
  const cells = Array.from({ length: offset + dayCount }, (_, index) => index < offset ? 0 : index - offset + 1);
  const monthName = labelMonth(month, timezone);
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
  return <><PageHead eyebrow="WIDOK PRACOWNIKA" title="Mój grafik i sprawy pracownicze" subtitle="Opublikowane zmiany, dokładne okna dostępności i proste preferencje zmianowe." actions={<button className="secondary-button" onClick={exportSchedule}><Download /> Excel</button>} /><div className="portal-grid portal-top"><section className="portal-profile"><UserRound />{dynamic ? <><h3>Moje konto</h3><p>Profil Matrix v2</p><span>Role i lokale wynikają z opublikowanego Matrixa.</span></> : <><h3>{employee?.firstName} {employee?.lastName}</h3><p>{employee?.employeeNo} • {employee ? rolePl[employee.primaryRole] || employee.primaryRole : "—"}</p><span>{employee?.locations.map((location) => location.name).join(", ")}</span></>}</section><section><h3>Moja dostępność</h3><button className="primary-button portal-action-visible" onClick={openAvailability}><CalendarDays /> Zarządzaj oknami</button><p>{portal.timeConstraints?.constraints.length || 0} zapisanych przedziałów.</p></section><section><h3>Moje preferencje</h3><button className="primary-button portal-action-visible" onClick={openPreferences}><Plus /> Ustaw pory zmian</button><p>Ustawienie pracodawcy w Matrixie ma pierwszeństwo.</p></section></div><section className="employee-month-summary"><span><small>Zaplanowane godziny</small><strong>{Math.floor(monthlyMinutes / 60)} h {monthlyMinutes % 60 ? `${monthlyMinutes % 60} min` : ""}</strong></span><span><small>Wszystkie zmiany</small><strong>{portal.assignments.length}</strong></span><span><small>Poranne</small><strong>{periodCounts.morning}</strong></span><span><small>Środkowe</small><strong>{periodCounts.middle}</strong></span><span><small>Wieczorne</small><strong>{periodCounts.evening}</strong></span></section><section className="employee-calendar-card"><div className="matrix-demand-head"><div><h3>Moje opublikowane zmiany — {monthName}</h3><p>Kliknij zmianę, aby zobaczyć współpracowników.</p></div></div><div className="role-calendar-week">{days.map((day) => <b key={day}>{day}</b>)}</div><div className="employee-month-calendar">{cells.map((day, index) => {
    const date = day ? `${month}-${String(day).padStart(2, "0")}` : "";
    return <section className={!day ? "blank" : ""} key={index}>{day && <><strong>{day}</strong>{(grouped.get(date) || []).map((assignment) => <button key={assignment.id} onClick={() => setSelected(assignment)} className="role-assignment"><b>{time(assignment.startsAt, assignmentTimezone(assignment, timezone))}–{time(assignment.endsAt, assignmentTimezone(assignment, timezone))}</b><small>{assignment.location} • {portalShiftLabel(assignment)}</small></button>)}</>}</section>;
  })}</div></section>{selected && <CoworkerDrawer assignment={selected} timezone={timezone} dynamic={dynamic} roleNames={roleNames} close={() => setSelected(null)} />}</>;
}

function ShiftPreferencesDrawer({ workspace, month, close, save, busy }: { workspace: PortalShiftPreferences; month: string; close: () => void; save: (preferences: Record<ShiftPeriod, ShiftPreferenceLevel>) => Promise<boolean>; busy: boolean }) {
  const [preferences, setPreferences] = useState(workspace.employee);
  const periods: readonly (readonly [ShiftPeriod, string])[] = [["MORNING", "Rano"], ["MIDDLE", "Środek"], ["EVENING", "Wieczór"]];
  return <><button className="drawer-scrim" onClick={close} /><aside className="drawer complete-drawer shift-preferences-drawer"><div className="drawer-head"><div><p className="eyebrow">PORTAL PRACOWNIKA • PREFERENCJE</p><h2>Pory zmian • {labelMonth(month)}</h2></div><button className="icon-button" onClick={close}><X /></button></div><div className="drawer-content"><p>Preferencje są miękkie; dostępność godzinową ustaw osobno.</p>{periods.map(([period, label]) => <section className="shift-preference-row" key={period}><span><strong>{label}</strong>{workspace.managerOverrides?.[period] ? <small><ShieldCheck /> Nadrzędnie w Matrixie: {preferenceLevelLabel(workspace.managerOverrides[period])}</small> : <small>Efektywnie: {preferenceLevelLabel(workspace.effective?.[period] ?? preferences[period])}</small>}</span><select value={preferences[period]} onChange={(event) => setPreferences((current) => ({ ...current, [period]: event.target.value as ShiftPreferenceLevel }))}><option value="PREFERRED">Preferuję</option><option value="NEUTRAL">Neutralnie</option><option value="AVOIDED">Wolę unikać</option></select></section>)}<button className="primary-button full" disabled={busy} onClick={() => void save(preferences)}><Save /> {busy ? "Zapisuję…" : "Zapisz preferencje"}</button></div></aside></>;
}

function AvailabilityWindowsDrawer({ workspace, month, locations, close, save, revoke, fail, busy }: { workspace: PortalTimeConstraintsWorkspace; month: string; locations: MatrixItem[]; close: () => void; save: (entry: { dates: string[]; kind: "AVAILABLE" | "PREFER_NOT_TO_WORK" | "CANNOT_WORK"; allDay: boolean; start?: string; end?: string; preferredLocationId?: string; note: string }) => Promise<boolean>; revoke: (id: string) => Promise<void>; fail: (message: string) => void; busy: boolean }) {
  const timezone = workspace.timezone;
  const [from, setFrom] = useState(`${month}-01`);
  const [to, setTo] = useState(`${month}-01`);
  const [kind, setKind] = useState<"AVAILABLE" | "PREFER_NOT_TO_WORK" | "CANNOT_WORK">("AVAILABLE");
  const [allDay, setAllDay] = useState(true);
  const [start, setStart] = useState("08:00");
  const [end, setEnd] = useState("16:00");
  const [preferredLocationId, setPreferredLocationId] = useState("");
  const [note, setNote] = useState("");
  const [selectedDays, setSelectedDays] = useState<string[]>([]);
  const [rangeAnchor, setRangeAnchor] = useState<string | null>(null);
  const [year, monthNumber] = month.split("-").map(Number);
  const maxDate = `${month}-${String(new Date(Date.UTC(year, monthNumber, 0, 12)).getUTCDate()).padStart(2, "0")}`;
  const monthDates = useMemo(() => Array.from({ length: Number(maxDate.slice(-2)) }, (_, index) => `${month}-${String(index + 1).padStart(2, "0")}`), [maxDate, month]);
  const calendarOffset = (new Date(`${month}-01T12:00:00Z`).getUTCDay() + 6) % 7;
  const dateRange = (startDate: string, endDate: string) => monthDates.filter(day => day >= startDate && day <= endDate);
  const setRange = (startDate: string, endDate: string) => {
    const ordered = startDate <= endDate ? [startDate, endDate] : [endDate, startDate];
    setFrom(ordered[0]); setTo(ordered[1]); setSelectedDays(dateRange(ordered[0], ordered[1])); setRangeAnchor(null);
  };
  const clickDay = (date: string) => {
    if (!selectedDays.length) { setSelectedDays([date]); setFrom(date); setTo(date); setRangeAnchor(date); return; }
    if (rangeAnchor) { setRange(rangeAnchor, date); return; }
    setSelectedDays(current => current.includes(date) ? current.filter(day => day !== date) : [...current, date].sort());
  };
  const grouped = useMemo(() => {
    const result = new Map<string, PortalTimeConstraint[]>();
    [...workspace.constraints].sort((a, b) => a.startsAt.localeCompare(b.startsAt)).forEach((row) => {
      const day = localIsoDate(row.startsAt, timezone);
      result.set(day, [...(result.get(day) || []), row]);
    });
    return [...result.entries()];
  }, [timezone, workspace.constraints]);
  const submit = async () => {
    try {
      if (!selectedDays.length) throw new Error("Zaznacz co najmniej jeden dzień.");
      if (await save({ dates: selectedDays, kind, allDay, start, end, preferredLocationId, note })) setNote("");
    } catch (cause) {
      fail(cause instanceof Error ? cause.message : "Nie udało się przygotować przedziału.");
    }
  };
  return <><button className="drawer-scrim" onClick={close} /><aside className="drawer role-drawer availability-windows-drawer"><div className="drawer-head"><div><p className="eyebrow">PORTAL PRACOWNIKA • MATRIX V2</p><h2>Dostępność • {labelMonth(month, timezone)}</h2><small>Zaznacz cały zakres, a potem odkliknij pojedyncze wyjątki • strefa {timezone}</small></div><button className="icon-button" onClick={close}><X /></button></div><div className="drawer-content availability-window-layout"><form className="availability-window-form" onSubmit={(event) => { event.preventDefault(); void submit(); }}><h3>Ustaw dni dostępności</h3><p>Kliknij pierwszy i ostatni dzień zakresu. Każdy zaznaczony dzień możesz potem odkliknąć.</p><div className="availability-day-picker"><div className="availability-weekdays">{days.map(day=><b key={day}>{day}</b>)}</div><div className="availability-days">{Array.from({length:calendarOffset},(_,index)=><i key={`blank-${index}`}/>)}{monthDates.map(date=><button type="button" key={date} className={selectedDays.includes(date)?"selected":""} onClick={()=>clickDay(date)}>{Number(date.slice(-2))}</button>)}</div><small>{rangeAnchor?"Wybierz ostatni dzień zakresu.":selectedDays.length?`Wybrano ${selectedDays.length} dni. Kliknij dzień, aby go dodać lub odznaczyć.`:"Wybierz pierwszy dzień zakresu."}</small></div><div className="form-row"><label>Od dnia<input required type="date" min={`${month}-01`} max={maxDate} value={from} onChange={(event) => setRange(event.target.value,to<event.target.value?event.target.value:to)} /></label><label>Do dnia<input required type="date" min={from} max={maxDate} value={to} onChange={(event) => setRange(from,event.target.value)} /></label></div><label>Co deklarujesz?<select value={kind} onChange={(event) => setKind(event.target.value as typeof kind)}><option value="AVAILABLE">Mogę pracować</option><option value="PREFER_NOT_TO_WORK">Wolę nie pracować (preferencja)</option><option value="CANNOT_WORK">Nie mogę pracować (twarda blokada)</option></select></label><label className="availability-all-day"><input type="checkbox" checked={!allDay} onChange={(event) => setAllDay(!event.target.checked)} /> Chcę podać konkretne godziny</label>{!allDay && <div className="form-row"><label>Od<input required type="time" value={start} onChange={(event) => setStart(event.target.value)} /></label><label>Do<input required type="time" value={end} onChange={(event) => setEnd(event.target.value)} /></label></div>}<label>Preferowany lokal (opcjonalnie)<select value={preferredLocationId} onChange={(event) => setPreferredLocationId(event.target.value)}><option value="">Bez preferencji</option>{locations.filter((location) => location.active).map((location) => <option value={location.id} key={location.id}>{location.name}</option>)}</select></label><label>Notatka (opcjonalnie)<textarea maxLength={500} value={note} onChange={(event) => setNote(event.target.value)} /></label><button disabled={busy||!selectedDays.length} className="primary-button full"><Plus /> Zapisz {selectedDays.length||""} {selectedDays.length===1?"dzień":"dni"}</button></form><section className="availability-window-list"><div className="availability-window-list-head"><div><h3>Zapisane dni i przedziały</h3><p>Miękka preferencja wpływa na ocenę wariantu; twarda blokada wyklucza przydział.</p></div><span>{workspace.constraints.length}</span></div>{grouped.map(([day, rows]) => <article className="availability-window-day" key={day}><h4>{day}</h4>{rows.map((row) => {
    const editable = row.editable && row.source === "GRAFIK_PRO" && ["AVAILABLE_WINDOW", "UNAVAILABLE", "PREFER_NOT_TO_WORK", "PREFERRED_LOCATION"].includes(row.kind);
    return <div className={`availability-window-row ${row.kind.toLowerCase().replaceAll("_", "-")}`} key={row.id}><span className="availability-window-kind">{timeConstraintKindPl(row.kind)}</span><span className="availability-window-time"><b>{time(row.startsAt, timezone)}–{time(row.endsAt, timezone)}</b><small>{timeConstraintSourcePl(row.source)}{row.note ? ` • ${row.note}` : ""}</small></span>{editable ? <button disabled={busy} className="danger-button" onClick={() => void revoke(row.id)}><Trash2 /> Odwołaj</button> : <em><ShieldCheck /> Tylko do odczytu</em>}</div>;
  })}</article>)}</section></div></aside></>;
}

function CoworkerDrawer({ assignment, timezone, dynamic, roleNames, close }: { assignment: PortalAssignment; timezone: string; dynamic: boolean; roleNames: Record<string, string>; close: () => void }) {
  const localTimezone = assignmentTimezone(assignment, timezone);
  return <><button className="drawer-scrim" onClick={close} /><aside className="drawer complete-drawer"><div className="drawer-head"><div><p className="eyebrow">SZCZEGÓŁY ZMIANY</p><h2>{assignment.date} • {time(assignment.startsAt, localTimezone)}–{time(assignment.endsAt, localTimezone)}</h2><small>{assignment.location} • {portalShiftLabel(assignment)}</small></div><button className="icon-button" onClick={close}><X /></button></div><div className="drawer-content coworker-list"><h3>Osoby na tej zmianie</h3>{assignment.coworkers?.length ? assignment.coworkers.map((coworker, index) => <div key={index}><UserRound /><span><b>{coworker.name}</b><small>{dynamic ? roleNames[coworker.role] ?? coworker.role : rolePl[coworker.role] || coworker.role}</small></span></div>) : <p>Nie ma innych przypisanych osób.</p>}</div></aside></>;
}

function labelMonth(month: string, timezone = "Europe/Warsaw") {
  return new Intl.DateTimeFormat("pl-PL", { month: "long", year: "numeric", timeZone: timezone }).format(new Date(`${month}-01T12:00:00Z`));
}
function nextIsoDate(date: string) { return new Date(Date.parse(`${date}T12:00:00Z`) + 86_400_000).toISOString().slice(0, 10); }
function localIsoDate(value: string, timezone: string) {
  const parts = Object.fromEntries(new Intl.DateTimeFormat("en-CA", { timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(new Date(value)).filter((part) => part.type !== "literal").map((part) => [part.type, part.value]));
  return `${parts.year}-${parts.month}-${parts.day}`;
}
function localDateTimeToIso(date: string, timeValue: string, timezone: string) {
  const intended = Date.parse(`${date}T${timeValue}:00Z`);
  const offsetAt = (instant: number) => {
    const parts = Object.fromEntries(new Intl.DateTimeFormat("en-CA", { timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23" }).formatToParts(new Date(instant)).filter((part) => part.type !== "literal").map((part) => [part.type, part.value]));
    return Date.UTC(Number(parts.year), Number(parts.month) - 1, Number(parts.day), Number(parts.hour), Number(parts.minute), Number(parts.second)) - instant;
  };
  let instant = intended - offsetAt(intended);
  instant = intended - offsetAt(instant);
  return new Date(instant).toISOString();
}
function time(value?: string, timezone = "Europe/Warsaw") { return value ? new Date(value).toLocaleTimeString("pl-PL", { hour: "2-digit", minute: "2-digit", timeZone: timezone }) : "—"; }
function portalShiftLabel(assignment: PortalAssignment) { return assignment.shiftName?.trim() || assignment.shiftCode || "Zmiana"; }
function assignmentTimezone(assignment: PortalAssignment, fallback: string) { return assignment.locationTimezone?.trim() || fallback; }
function preferenceLevelLabel(value: string) { return ({ PREFERRED: "preferowana", NEUTRAL: "neutralna", AVOIDED: "unikać", BLOCKED: "zablokowana", INHERIT: "wg pracownika" } as Record<string, string>)[value] || value; }
function timeConstraintKindPl(kind: string) { return ({ AVAILABLE_WINDOW: "Dostępność", UNAVAILABLE: "Twarda niedostępność", PREFER_NOT_TO_WORK: "Wolę nie pracować", PREFERRED_LOCATION: "Preferowany lokal", LEAVE: "Urlop", SICKNESS: "L4 / zwolnienie" } as Record<string, string>)[kind] || kind; }
function timeConstraintSourcePl(source: string) { return ({ GRAFIK_PRO: "Wpis własny", MANAGER: "Przełożony", HR: "Kadry", KADROMIERZ: "Kadromierz", IMPORT: "Import", SYSTEM: "System" } as Record<string, string>)[source] || source; }
function translateError(message: string) {
  const translations: Record<string, string> = {
    AUTH_REQUIRED: "Zaloguj się ponownie.",
    EMPLOYEE_NOT_FOUND: "Konto nie jest powiązane z pracownikiem.",
    INVALID_TIME_RANGE: "Koniec przedziału musi przypadać po jego początku.",
    PROTECTED_TIME_CONSTRAINT: "Tego wpisu nie można zmienić w portalu pracownika.",
    FORBIDDEN: "Nie masz uprawnień do tej operacji.",
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
