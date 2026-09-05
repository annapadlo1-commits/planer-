"use client";

import { AlertTriangle, Check, Puzzle, RefreshCw, Upload, Users, X } from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { SolverV2Workspace } from "@/components/SolverV2Workspace";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import {
  createRoleCompositeIdempotencyKey,
  forgetPublishedSchedule,
  getPublishedSchedule,
  getPublicationAuthorityStatus,
  getRoleCompositeCandidates,
  getRoleCompositePreflight,
  getRolePublicationOverview,
  isValidIdempotencyKey,
  publishRoleComposite,
  recoverPublishedSchedule,
  resolvePublicationAuthority,
  rememberPublishedSchedule,
  roleCompositePublicationAttemptStorageKey,
  solverErrorMessage,
  type RunStorageContext,
  type SolverEngine,
  type SolverRoleCompositeCandidates,
  type SolverRoleCompositePreflight,
  type SolverRolePublicationOverview,
  type SolverPublicationAuthorityStatus,
  type SolverScenario,
  type SolverWorkspace,
} from "@/lib/solver-v2";

type Props = {
  engine: SolverEngine;
  solverVersion: string;
  userId: string;
  month: string;
  timezone: string;
  scenarios: SolverScenario[];
  matrixEffectiveFrom?: string;
  refreshKey?: number;
  onPublished?: (scheduleId: string) => void | Promise<void>;
};

type CompositeAnalysisMetric="TEAMS"|"ASSIGNMENTS"|"GAPS"|"COST"|"OVERTIME";

function monthLabel(value: string) {
  const date = new Date(`${value.slice(0, 7)}-01T12:00:00Z`);
  return Number.isNaN(date.getTime())
    ? "wybranego miesiąca"
    : new Intl.DateTimeFormat("pl-PL", { month: "long", year: "numeric", timeZone: "UTC" }).format(date);
}

function solutionLabel(value: string) {
  if (value === "OPTIMAL") return "Potwierdzone optimum";
  if (value === "FEASIBLE") return "Poprawny wariant";
  return "Zweryfikowany wariant";
}

function money(value: number, currency: string) {
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

function dateTime(value: string, timezone: string) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat("pl-PL", {
    day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", timeZone: timezone,
  }).format(date);
}

function sameVariantSet(left: string[], right: string[]) {
  return [...left].sort().join(":") === [...right].sort().join(":");
}

function gapDurationHours(startsAt: string, endsAt: string) {
  const [startHour, startMinute] = startsAt.split(":").map(Number);
  const [endHour, endMinute] = endsAt.split(":").map(Number);
  if (![startHour, startMinute, endHour, endMinute].every(Number.isFinite)) return 0;
  const start = startHour * 60 + startMinute;
  let end = endHour * 60 + endMinute;
  if (end <= start) end += 24 * 60;
  return (end - start) / 60;
}

export function RoleCompositePanel({ engine, solverVersion, userId, month, timezone, scenarios, matrixEffectiveFrom, refreshKey = 0, onPublished }: Props) {
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const expectedSolverVersion = solverVersion.trim();
  const candidateRequestRef = useRef(0);
  const configuredScenarios = useMemo(() => scenarios.filter(scenario => Boolean(scenario.id)), [scenarios]);
  const defaultScenarioId = configuredScenarios.find(scenario => scenario.isDefault)?.id ?? "";
  const [scenarioId, setScenarioId] = useState(defaultScenarioId);
  const [candidates, setCandidates] = useState<SolverRoleCompositeCandidates | null>(null);
  const [preflight, setPreflight] = useState<SolverRoleCompositePreflight | null>(null);
  const [overview, setOverview] = useState<SolverRolePublicationOverview | null>(null);
  const [authority, setAuthority] = useState<SolverPublicationAuthorityStatus | null>(null);
  const [publishedWorkspace, setPublishedWorkspace] = useState<SolverWorkspace | null>(null);
  const [inspectedRoleWorkspace, setInspectedRoleWorkspace] = useState<SolverWorkspace | null>(null);
  const [inspectedRoleName, setInspectedRoleName] = useState("");
  const [inspectedRoleInitialView, setInspectedRoleInitialView] = useState<"CALENDAR"|"WORKLOAD"|"ISSUES">("CALENDAR");
  const [analysisMetric, setAnalysisMetric] = useState<CompositeAnalysisMetric>("TEAMS");
  const [publicationName, setPublicationName] = useState(`Grafik zespołów • ${monthLabel(month)}`);
  const [publicationReason, setPublicationReason] = useState("");
  const [publicationAttempted, setPublicationAttempted] = useState(false);
  const publicationReasonRef = useRef<HTMLTextAreaElement | null>(null);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [loading, setLoading] = useState(false);
  const availableScenarios = useMemo(() => {
    const result = [...configuredScenarios];
    const known = new Set(result.map(scenario => scenario.id));
    for (const publication of overview?.roles ?? []) {
      if (!publication.scenario.id || known.has(publication.scenario.id)) continue;
      known.add(publication.scenario.id);
      result.push({
        id: publication.scenario.id,
        code: `PUBLISHED_${publication.scenario.id}`,
        name: publication.scenario.name,
        description: "Scenariusz źródłowy wcześniej opublikowanych grafików ról.",
        strategyCount: 0,
        isDefault: false,
      });
    }
    return result;
  }, [configuredScenarios, overview]);
  const publishedScenarioGroups = useMemo(() => {
    const groups = new Map<string, { id: string; name: string; roleIds: Set<string> }>();
    for (const publication of overview?.roles ?? []) {
      if (!publication.scenario.id) continue;
      const group = groups.get(publication.scenario.id) ?? {
        id: publication.scenario.id,
        name: publication.scenario.name,
        roleIds: new Set<string>(),
      };
      group.roleIds.add(publication.role.id);
      groups.set(publication.scenario.id, group);
    }
    return [...groups.values()];
  }, [overview]);
  const selectedScenarioIsCurrent = configuredScenarios.some(scenario => scenario.id === scenarioId);
  const storageContext = useMemo<RunStorageContext>(() => ({
    userId,
    engine,
    solverVersion: expectedSolverVersion,
    month,
    scenarioId: scenarioId || "missing-scenario",
    scopeType: "COMPANY",
    scopeRoleId: null,
  }), [userId, engine, expectedSolverVersion, month, scenarioId]);
  const shortagePatterns = useMemo(() => {
    const groups = new Map<string, { role: string; location: string; startsAt: string; endsAt: string; dates: string[]; hours: number }>();
    for (const gap of preflight?.gaps ?? []) {
      const key = `${gap.role}:${gap.location}:${gap.startsAt}:${gap.endsAt}`;
      const current = groups.get(key) ?? { role: gap.role, location: gap.location, startsAt: gap.startsAt, endsAt: gap.endsAt, dates: [], hours: 0 };
      current.dates.push(gap.date);
      current.hours += gapDurationHours(gap.startsAt, gap.endsAt) * gap.missingCount;
      groups.set(key, current);
    }
    return [...groups.values()].filter(item => item.dates.length >= 2).sort((left, right) => right.hours - left.hours);
  }, [preflight]);

  useEffect(() => {
    if (!availableScenarios.some(scenario => scenario.id === scenarioId)) {
      setScenarioId(defaultScenarioId);
    }
  }, [availableScenarios, defaultScenarioId, scenarioId]);

  useEffect(() => {
    setPublicationName(`Grafik zespołów • ${monthLabel(month)}`);
  }, [month]);

  const loadCandidates = useCallback(async (silent = false) => {
    if (!supabase || !scenarioId || !expectedSolverVersion || engine !== "ORTOOLS_V2") return null;
    const requestId = ++candidateRequestRef.current;
    if (!silent) setLoading(true);
    try {
      const [result, latestOverview] = await Promise.all([
        getRoleCompositeCandidates(supabase, month, scenarioId),
        getRolePublicationOverview(supabase, month),
      ]);
      if (requestId !== candidateRequestRef.current) return null;
      if (result.month.slice(0, 7) !== month.slice(0, 7) || result.scenario.id !== scenarioId) {
        throw new Error("ROLE_COMPOSITE_REFERENCE_MISMATCH");
      }
      setCandidates(result);
      setOverview(latestOverview);
      const publishedRoleById = new Map(
        latestOverview.roles
          .filter(publication => publication.scenario.id === scenarioId)
          .map(publication => [publication.role.id, publication] as const),
      );
      const publishedVariantIds = result.roles.flatMap(role => {
        const publication = publishedRoleById.get(role.id);
        return publication?.variantId ? [publication.variantId] : [];
      });
      if (publishedVariantIds.length === result.roles.length && publishedVariantIds.length > 0) {
        setPreflight(await getRoleCompositePreflight(supabase, month, scenarioId, publishedVariantIds));
      } else {
        setPreflight(null);
      }
      if (!silent) setMessage("");
      return result;
    } catch (error) {
      if (requestId !== candidateRequestRef.current) return null;
      setCandidates(null);
      setPreflight(null);
      if (!silent) setMessage(solverErrorMessage(error instanceof Error ? error.message : String(error)));
      return null;
    } finally {
      if (!silent && requestId === candidateRequestRef.current) setLoading(false);
    }
  }, [supabase, scenarioId, engine, expectedSolverVersion, month]);

  const loadOverview = useCallback(async () => {
    if (!supabase || !expectedSolverVersion || engine !== "ORTOOLS_V2") return;
    try {
      setOverview(await getRolePublicationOverview(supabase, month));
    } catch (error) {
      setOverview(null);
      setMessage(solverErrorMessage(error instanceof Error ? error.message : String(error)));
    }
  }, [supabase, expectedSolverVersion, engine, month]);

  const loadAuthority = useCallback(async () => {
    if (!supabase || engine !== "ORTOOLS_V2") return;
    try {
      setAuthority(await getPublicationAuthorityStatus(supabase, month));
    } catch (error) {
      setAuthority(null);
      setMessage(solverErrorMessage(error instanceof Error ? error.message : String(error)));
    }
  }, [supabase, engine, month]);

  useEffect(() => {
    candidateRequestRef.current += 1;
    setCandidates(null);
    setPreflight(null);
    if (scenarioId) void loadCandidates();
  }, [scenarioId, refreshKey, loadCandidates]);

  useEffect(() => { void loadOverview(); void loadAuthority(); }, [loadOverview, loadAuthority, refreshKey]);

  useEffect(() => {
    if (
      !candidates
      || loading
      || scenarioId !== defaultScenarioId
      || candidates.roles.length === 0
      || candidates.roles.some(role => Boolean(role.variant))
    ) return;
    const completePublishedScenario = publishedScenarioGroups.find(group => (
      group.id !== defaultScenarioId && group.roleIds.size === candidates.roles.length
    ));
    if (!completePublishedScenario) return;
    setMessage(
      `Pokazuję kompletny zestaw grafików ról opublikowany dla scenariusza „${completePublishedScenario.name}”. `
      + "Nowa konfiguracja firmy obowiązuje przy następnym generowaniu, ale nie unieważnia wcześniejszych publikacji.",
    );
    setScenarioId(completePublishedScenario.id);
  }, [candidates, defaultScenarioId, loading, publishedScenarioGroups, scenarioId]);

  useEffect(() => {
    if (!candidates || loading || candidates.roles.length > 0 || publishedScenarioGroups.length === 0) return;
    const publishedScenario = [...publishedScenarioGroups]
      .sort((left, right) => right.roleIds.size - left.roleIds.size)[0];
    if (!publishedScenario || publishedScenario.id === scenarioId) return;
    const currentScenarioName=configuredScenarios.find(item=>item.id===scenarioId)?.name??"wybrany";
    setMessage(
      `Scenariusz „${currentScenarioName}” nie zawiera zespołów do scalenia. `
      + `Pokazuję istniejące publikacje dla scenariusza „${publishedScenario.name}”.`,
    );
    setScenarioId(publishedScenario.id);
  }, [candidates, configuredScenarios, loading, publishedScenarioGroups, scenarioId]);

  useEffect(() => {
    setPublishedWorkspace(null);
    if (!supabase || engine !== "ORTOOLS_V2" || !expectedSolverVersion) return;
    let disposed = false;
    const scheduleId = recoverPublishedSchedule(storageContext);
    if (scheduleId) {
      void getPublishedSchedule(supabase, scheduleId)
        .then(workspace => {
          if (disposed) return;
          if (
            workspace.context.type !== "PUBLISHED_SCHEDULE"
            || workspace.context.engine !== "ORTOOLS_V2"
            || workspace.context.scheduleId !== scheduleId
            || workspace.context.month.slice(0, 7) !== month.slice(0, 7)
          ) throw new Error("PUBLISHED_SCHEDULE_REFERENCE_MISMATCH");
          if (workspace.context.sourceType !== "ROLE_COMPOSITE") return;
          setPublishedWorkspace(workspace);
        })
        .catch(error => {
          const detail = error instanceof Error ? error.message : String(error);
          if (!disposed && (
            detail.toUpperCase().includes("PUBLISHED_SCHEDULE_NOT_FOUND")
            || detail.toUpperCase().includes("PUBLISHED_SCHEDULE_REFERENCE_MISMATCH")
          )) forgetPublishedSchedule(storageContext);
        });
    }
    return () => { disposed = true; };
  }, [supabase, engine, expectedSolverVersion, month, storageContext]);

  if (engine !== "ORTOOLS_V2") return null;

  const publishedRoleById = new Map(
    (overview?.roles ?? [])
      .filter(publication => publication.scenario.id === scenarioId)
      .map(publication => [publication.role.id, publication] as const),
  );
  const missingRoles = candidates?.roles.filter(role => !publishedRoleById.get(role.id)) ?? [];
  const unknownMissingCount = candidates
    ? candidates.missingRoleIds.filter(id => !candidates.roles.some(role => role.id === id)).length
    : 0;
  const variantIds = candidates?.roles.flatMap(role => {
    const publication = publishedRoleById.get(role.id);
    return publication?.variantId ? [publication.variantId] : [];
  }) ?? [];
  const ready = Boolean(
    candidates
    && candidates.roles.length > 0
    && missingRoles.length === 0
    && unknownMissingCount === 0
    && variantIds.length === candidates.roles.length,
  );
  const assignmentCount = candidates?.roles.reduce((sum, role) => sum + (publishedRoleById.get(role.id)?.assignmentCount ?? 0), 0) ?? 0;
  const unfilledCount = candidates?.roles.reduce((sum, role) => sum + (publishedRoleById.get(role.id)?.unfilledCount ?? 0), 0) ?? 0;
  const publicationReasonLength = publicationReason.trim().length;
  const publicationReasonMissing = Math.max(0, 10 - publicationReasonLength);
  const publicationReasonInvalid = unfilledCount > 0 && publicationReasonLength < 10;
  const missingRoleLabel = [
    ...missingRoles.map(role => role.name),
    ...(unknownMissingCount ? [`${unknownMissingCount} inne wymagane role`] : []),
  ].join(", ");
  const selectedScenario = availableScenarios.find(scenario => scenario.id === scenarioId);
  const publishedForSelection = publishedWorkspace?.context.scenario.id === scenarioId
    && publishedWorkspace.context.month.slice(0, 7) === month.slice(0, 7);
  const messageIsWarning = message.startsWith("Nie ")
    || message.startsWith("Tylko ")
    || message.startsWith("Dane ")
    || message.startsWith("Zestaw ");
  const averageOvertimePerAssignment = overview?.totals.assignmentCount
    ? overview.totals.overtimeMinutes / overview.totals.assignmentCount
    : 0;
  const analysisRoles=useMemo(()=>{
    const rows=[...(overview?.roles??[])];
    const score=(role:(typeof rows)[number])=>analysisMetric==="ASSIGNMENTS"?role.assignmentCount
      :analysisMetric==="GAPS"?role.unfilledCount
      :analysisMetric==="COST"?role.totalCostMinor
      :analysisMetric==="OVERTIME"?role.overtimeMinutes
      :0;
    return rows
      .filter(role=>analysisMetric!=="GAPS"||role.unfilledCount>0)
      .sort((left,right)=>score(right)-score(left)||left.role.name.localeCompare(right.role.name,"pl-PL"));
  },[analysisMetric,overview]);
  const analysisLabel=analysisMetric==="TEAMS"?"Wszystkie opublikowane zespoły"
    :analysisMetric==="ASSIGNMENTS"?"Zespoły od największej liczby przydziałów"
    :analysisMetric==="GAPS"?"Tylko zespoły z brakami"
    :analysisMetric==="COST"?"Zespoły od najwyższego kosztu"
    :"Zespoły od największej liczby nadgodzin";

  async function publish() {
    if (!supabase || engine !== "ORTOOLS_V2" || !candidates || !selectedScenario?.id || !ready) return;
    setPublicationAttempted(true);
    const trimmedName = publicationName.trim();
    if (!trimmedName) {
      setMessage("Nie podano nazwy publikowanego grafiku.");
      return;
    }
    if (publicationReasonInvalid) {
      setMessage(`Nie można jeszcze opublikować grafiku. Dopisz ${publicationReasonMissing} ${publicationReasonMissing === 1 ? "znak" : "znaków"} uzasadnienia decyzji o brakach.`);
      window.setTimeout(() => {
        publicationReasonRef.current?.focus();
        publicationReasonRef.current?.scrollIntoView({ behavior: "smooth", block: "center" });
      }, 0);
      return;
    }

    setBusy(true);
    setMessage("");
    try {
      const [fresh, freshOverview] = await Promise.all([
        getRoleCompositeCandidates(supabase, month, selectedScenario.id),
        getRolePublicationOverview(supabase, month),
      ]);
      setCandidates(fresh);
      setOverview(freshOverview);
      const freshPublishedRoleById = new Map(
        freshOverview.roles
          .filter(publication => publication.scenario.id === selectedScenario.id)
          .map(publication => [publication.role.id, publication] as const),
      );
      const freshIds = fresh.roles.flatMap(role => {
        const publication = freshPublishedRoleById.get(role.id);
        return publication?.variantId ? [publication.variantId] : [];
      });
      if (fresh.missingRoleIds.some(id => !fresh.roles.some(role => role.id === id)) || freshIds.length !== fresh.roles.length) {
        setMessage("Nie wszystkie wymagane role mają teraz opublikowany grafik. Uzupełnij braki i odśwież zestaw.");
        return;
      }
      if (!sameVariantSet(variantIds, freshIds)) {
        setMessage("Zestaw wybranych wariantów zmienił się. Sprawdź odświeżoną listę i ponownie potwierdź publikację.");
        return;
      }
      const freshAssignmentCount = fresh.roles.reduce((sum, role) => sum + (freshPublishedRoleById.get(role.id)?.assignmentCount ?? 0), 0);
      const freshUnfilledCount = fresh.roles.reduce((sum, role) => sum + (freshPublishedRoleById.get(role.id)?.unfilledCount ?? 0), 0);
      const freshPreflight = await getRoleCompositePreflight(supabase, month, selectedScenario.id, freshIds);
      setPreflight(freshPreflight);
      if (freshPreflight.totalGaps > 0 && publicationReason.trim().length < 10) {
        setMessage("Po ponownej kontroli grafik nadal zawiera braki. Uzupełnij uzasadnienie świadomej publikacji.");
        return;
      }

      const confirmation = window.confirm(
        `Opublikować „${trimmedName}” jako obowiązujący grafik dla ${monthLabel(month)}?\n\n`
        + `System połączy ${fresh.roles.length} grafików ról: ${freshAssignmentCount} przydziałów i ${freshUnfilledCount} braków.\n\n`
        + `${freshPreflight.criticalGaps > 0 ? `UWAGA: ${freshPreflight.criticalGaps} zmian nie ma ani jednej osoby w wymaganej roli.\n\n` : ""}`
        + "Przed publikacją całość zostanie ponownie sprawdzona globalnie. Obecnie opublikowany grafik tego miesiąca zostanie zarchiwizowany.",
      );
      if (!confirmation) return;

      const attemptKey = roleCompositePublicationAttemptStorageKey(
        userId,
        month,
        selectedScenario.id,
        freshIds,
        trimmedName,
      );
      let idempotencyKey = window.localStorage.getItem(attemptKey);
      if (!isValidIdempotencyKey(idempotencyKey)) {
        window.localStorage.removeItem(attemptKey);
        idempotencyKey = createRoleCompositeIdempotencyKey(
          month,
          selectedScenario.id,
          freshIds,
          trimmedName,
        );
        window.localStorage.setItem(attemptKey, idempotencyKey);
      }
      const publication = await publishRoleComposite(supabase, {
        month,
        scenarioId: selectedScenario.id,
        variantIds: freshIds,
        name: trimmedName,
        idempotencyKey,
        warningReason: publicationReason,
      });
      rememberPublishedSchedule(storageContext, publication.scheduleId);
      window.localStorage.removeItem(attemptKey);
      try {
        await onPublished?.(publication.scheduleId);
      } catch {
        // Publication is already durable; a parent refresh must not turn it into a reported failure.
      }
      try {
        const workspace = await getPublishedSchedule(supabase, publication.scheduleId);
        if (
          workspace.context.type !== "PUBLISHED_SCHEDULE"
          || workspace.context.engine !== "ORTOOLS_V2"
          || workspace.context.sourceType !== "ROLE_COMPOSITE"
          || workspace.context.scheduleId !== publication.scheduleId
          || workspace.context.month.slice(0, 7) !== month.slice(0, 7)
        ) throw new Error("PUBLISHED_SCHEDULE_REFERENCE_MISMATCH");
        setPublishedWorkspace(workspace);
        setMessage(publication.reused
          ? "Ten sam scalony grafik był już opublikowany. Przywrócono jego podgląd."
          : "Scalony grafik wszystkich ról został opublikowany.");
      } catch {
        setMessage("Scalony grafik został opublikowany, ale jego podgląd wymaga odświeżenia.");
      }
    } catch (error) {
      setMessage(solverErrorMessage(error instanceof Error ? error.message : String(error)));
    } finally {
      setBusy(false);
    }
  }

  async function resolveConflict(keepSource: "COMPANY" | "ROLES") {
    if (!supabase || !authority?.conflict) return;
    const label = keepSource === "COMPANY" ? "grafik firmowy" : "opublikowane grafiki zespołów";
    const reason = window.prompt(
      `Konflikt publikacji: jako obowiązujące pozostaną ${label}.\n\nPodaj powód decyzji do historii audytu:`,
      `Decyzja właściciela: obowiązujące pozostają ${label}.`,
    );
    if (!reason) return;
    setBusy(true);
    setMessage("");
    try {
      const next = await resolvePublicationAuthority(supabase, month, keepSource, reason);
      setAuthority(next);
      await loadOverview();
      setMessage(`Rozstrzygnięto konflikt. Obowiązujące pozostają ${label}; decyzję zapisano w audycie.`);
    } catch (error) {
      setMessage(solverErrorMessage(error instanceof Error ? error.message : String(error)));
    } finally {
      setBusy(false);
    }
  }

  function focusAnalysis(metric:CompositeAnalysisMetric){
    setAnalysisMetric(metric);
    setInspectedRoleWorkspace(null);
    window.requestAnimationFrame(()=>document.querySelector(".role-publication-analysis-head")?.scrollIntoView({behavior:"smooth",block:"start"}));
  }

  async function inspectRole(publicationId: string, roleName: string, requestedView?:"ISSUES"|"CALENDAR"|"WORKLOAD") {
    if (!supabase) return;
    setBusy(true);
    setMessage("");
    try {
      const workspace = await getPublishedSchedule(supabase, publicationId);
      setInspectedRoleWorkspace(workspace);
      setInspectedRoleName(roleName);
      setInspectedRoleInitialView(requestedView??(analysisMetric==="GAPS"?"ISSUES":analysisMetric==="TEAMS"?"CALENDAR":"WORKLOAD"));
    } catch (error) {
      setMessage(solverErrorMessage(error instanceof Error ? error.message : String(error)));
    } finally {
      setBusy(false);
    }
  }

  return <section className="role-composite-panel">
    <div className="role-composite-head">
      <span className="role-composite-icon"><Puzzle/></span>
      <span>
        <small>PODSUMOWANIE WŁAŚCICIELA</small>
        <strong>Opublikowane grafiki zespołów</strong>
        <em>Każdy zespół publikuje niezależnie. Tutaj kontrolujesz komplet i opcjonalnie tworzysz wspólną wersję.</em>
      </span>
      <button className="secondary-button" disabled={loading || busy || !scenarioId || !expectedSolverVersion} onClick={() => { void loadCandidates(); void loadOverview(); }}>
        <RefreshCw className={loading ? "spin" : ""}/> Odśwież zestaw
      </button>
    </div>

    <div className="solver-v2-notice matrix-source-notice"><AlertTriangle/><span><strong>Scalanie dotyczy opublikowanej konfiguracji firmy{matrixEffectiveFrom?` obowiązującej od ${matrixEffectiveFrom}`:""}</strong><small>Robocze zmiany pracowników i ról nie są uwzględniane, dopóki konfiguracja nie przejdzie kontroli i publikacji.</small></span></div>

    {authority?.conflict&&<section className="publication-authority-conflict">
      <AlertTriangle/>
      <div><strong>Istnieją dwa konkurencyjne grafiki dla {monthLabel(month)}</strong><p>Grafik firmowy „{authority.company?.name ?? "—"}” oraz {authority.roles.length} opublikowany grafik zespołu nie mogą jednocześnie być źródłem prawdy. Do czasu decyzji pracownicy nie zobaczą losowo wybranej wersji.</p><ul>{authority.conflicts.map(conflict=><li key={`${conflict.roleScheduleId}:${conflict.companyScheduleId}`}>{conflict.roleName}: grafik zespołu koliduje z grafikiem firmy.</li>)}</ul></div>
      <div className="publication-authority-actions"><button disabled={busy} className="secondary-button" onClick={()=>void resolveConflict("COMPANY")}>Zachowaj grafik firmy</button><button disabled={busy} className="primary-button" onClick={()=>void resolveConflict("ROLES")}>Zachowaj grafiki zespołów</button></div>
    </section>}

    {overview&&<section className="role-publication-overview">
      <div className="role-publication-totals">
        <button type="button" className={analysisMetric==="TEAMS"?"active":""} aria-pressed={analysisMetric==="TEAMS"} onClick={()=>focusAnalysis("TEAMS")}><Users/><small>Opublikowane zespoły</small><strong>{overview.totals.publishedRoles}</strong></button>
        <button type="button" className={analysisMetric==="ASSIGNMENTS"?"active":""} aria-pressed={analysisMetric==="ASSIGNMENTS"} onClick={()=>focusAnalysis("ASSIGNMENTS")}><Check/><small>Przydziały</small><strong>{overview.totals.assignmentCount}</strong></button>
        <button type="button" className={analysisMetric==="GAPS"?"active":""} aria-pressed={analysisMetric==="GAPS"} onClick={()=>focusAnalysis("GAPS")}><AlertTriangle/><small>Braki</small><strong>{overview.totals.unfilledCount}</strong></button>
        <button type="button" className={analysisMetric==="COST"?"active":""} aria-pressed={analysisMetric==="COST"} onClick={()=>focusAnalysis("COST")}><small>Koszt wszystkich zespołów</small><strong>{money(overview.totals.totalCostMinor,overview.roles[0]?.currency??"PLN")}</strong></button>
        <button type="button" className={analysisMetric==="OVERTIME"?"active":""} aria-pressed={analysisMetric==="OVERTIME"} onClick={()=>focusAnalysis("OVERTIME")}><small>Nadgodziny</small><strong>{Math.round(overview.totals.overtimeMinutes/60)} h</strong></button>
      </div>
      <div className="role-publication-analysis-head"><strong>{analysisLabel}</strong><small>Kliknij zespół, aby otworzyć {analysisMetric==="GAPS"?"braki i ich przyczyny":analysisMetric==="TEAMS"?"jego grafik":"godziny, osoby i lokale"} bez opuszczania scalenia.</small></div>
      <div className="role-publication-analysis">
        {analysisRoles.map(role=>{
          const costShare=overview.totals.totalCostMinor?role.totalCostMinor/overview.totals.totalCostMinor:0;
          const assignmentShare=overview.totals.assignmentCount?role.assignmentCount/overview.totals.assignmentCount:0;
          const costPressure=assignmentShare?costShare/assignmentShare:0;
          const overtimePerAssignment=role.assignmentCount?role.overtimeMinutes/role.assignmentCount:0;
          const flagged=costPressure>1.15||(averageOvertimePerAssignment>0&&overtimePerAssignment>averageOvertimePerAssignment*1.25);
          return <article className={flagged?"flagged":""} key={role.publicationId}>
            <header><span><small>ZESPÓŁ</small><strong>{role.role.name}</strong><em>{role.scenario.name} • {dateTime(role.publishedAt,timezone)}</em></span>{flagged&&<b><AlertTriangle/> Do sprawdzenia</b>}</header>
            <dl><div><dt>Koszt</dt><dd>{money(role.totalCostMinor,role.currency)}</dd></div><div><dt>Udział kosztu / przydziałów</dt><dd>{Math.round(costShare*100)}% / {Math.round(assignmentShare*100)}%</dd></div><div><dt>Nadgodziny</dt><dd>{Math.round(role.overtimeMinutes/60)} h</dd></div><div><dt>Braki</dt><dd>{role.unfilledCount}</dd></div><div><dt>Osoby w grafiku</dt><dd>{role.teamSize}</dd></div></dl>
            {flagged&&<small>{costPressure>1.15?"Udział w kosztach jest wyraźnie większy niż udział w liczbie przydziałów. ":""}{averageOvertimePerAssignment>0&&overtimePerAssignment>averageOvertimePerAssignment*1.25?"Nadgodziny na przydział przekraczają średnią zespołów.":""}</small>}
            <footer className="role-publication-card-actions"><button type="button" className="secondary-button" onClick={()=>void inspectRole(role.publicationId,role.role.name,"CALENDAR")}><Users/> Otwórz zespół</button><button type="button" className="secondary-button" disabled={role.unfilledCount===0} aria-label={role.unfilledCount===0?`${role.role.name}: brak wakatów do otwarcia`:`${role.role.name}: otwórz ${role.unfilledCount} braków`} onClick={()=>void inspectRole(role.publicationId,role.role.name,"ISSUES")}><AlertTriangle/> Braki {role.unfilledCount}</button></footer>
          </article>;
        })}
        {!analysisRoles.length&&<p>{analysisMetric==="GAPS"?"Żaden opublikowany zespół nie ma braków.":"Żaden zespół nie opublikował jeszcze grafiku na ten miesiąc."}</p>}
      </div>
      {inspectedRoleWorkspace&&<section className="role-publication-drilldown">
        <header><span><small>SZCZEGÓŁY ZESPOŁU</small><strong>{inspectedRoleName}</strong></span><button type="button" className="icon-button" aria-label="Zamknij szczegóły zespołu" onClick={()=>setInspectedRoleWorkspace(null)}><X/></button></header>
        <SolverV2Workspace key={`${inspectedRoleWorkspace.context.scheduleId??inspectedRoleWorkspace.context.runId}:${inspectedRoleInitialView}`} workspace={inspectedRoleWorkspace} timezone={timezone} published initialView={inspectedRoleInitialView}/>
      </section>}
    </section>}

    {!expectedSolverVersion && <div className="solver-v2-notice warning"><AlertTriangle/>Konfiguracja nie wskazuje aktywnej wersji workera. Scalanie pozostaje zablokowane.</div>}

    <label className="role-composite-scenario">Pokaż publikacje zespołów dla scenariusza
      <select value={scenarioId} disabled={loading || busy || !expectedSolverVersion} onChange={event => setScenarioId(event.target.value)}>
        {availableScenarios.map(scenario => <option key={scenario.id ?? scenario.code} value={scenario.id ?? ""}>
          {scenario.name}{configuredScenarios.some(item => item.id === scenario.id) ? "" : " • wcześniej opublikowane grafiki"}
        </option>)}
      </select>
    </label>

    {!selectedScenarioIsCurrent && scenarioId && <div className="solver-v2-notice warning">
      <AlertTriangle/>
      <span>
        <strong>Scalasz istniejące publikacje z ich konfiguracji źródłowej.</strong>
        <small>
          Wspólny grafik zachowa reguły, według których liderzy opublikowali swoje zespoły. Aktywna konfiguracja firmy zostanie użyta przy następnym generowaniu grafików ról.
        </small>
      </span>
    </div>}

    {!availableScenarios.length && <div className="solver-v2-notice warning"><AlertTriangle/>Opublikowana konfiguracja firmy nie ma profilu zapotrzebowania dostępnego do scalenia.</div>}
    {loading && <div className="role-composite-loading"><RefreshCw className="spin"/> Sprawdzam opublikowane grafiki wszystkich ról…</div>}

    {candidates && !loading && <>
      <div className="role-composite-summary">
        <span><Users/><small>Wymagane role</small><strong>{candidates.roles.length}</strong></span>
        <span><Check/><small>Opublikowane zespoły</small><strong>{variantIds.length}</strong></span>
        <span><AlertTriangle/><small>Braki obsady</small><strong>{unfilledCount}</strong></span>
      </div>

      <div className="role-composite-roles">
        {candidates.roles.map(role => {
          const publication = publishedRoleById.get(role.id);
          return <article className={publication ? "ready" : "missing"} key={role.id}>
          <span>
            <small>ROLA</small>
            <strong>{role.name}</strong>
          </span>
          {publication
            ? <>
              <span className="role-composite-variant">
                <small>Opublikowany grafik roli</small>
                <strong>{publication.name}</strong>
                <em>Źródło scalenia • {new Date(publication.publishedAt).toLocaleString("pl-PL", { dateStyle: "short", timeStyle: "short" })}</em>
              </span>
              <span className="role-composite-counts">
                <b>{publication.assignmentCount}</b><small>przydziałów</small>
                <b>{publication.unfilledCount}</b><small>braków</small>
              </span>
              <em className="role-composite-state"><Check/> Opublikowany</em>
            </>
            : <div className="role-composite-missing"><AlertTriangle/><span><strong>Brak opublikowanego grafiku</strong><small>Lider tej roli musi wybrać wariant i opublikować go dla zespołu.</small></span></div>}
        </article>})}
      </div>

      {(missingRoles.length > 0 || unknownMissingCount > 0) && <div className="solver-v2-notice warning">
        <AlertTriangle/>
        <span>
          <strong>Nie można jeszcze opublikować wspólnego grafiku.</strong>
          <small>
            Brakuje: {missingRoleLabel}.
          </small>
        </span>
      </div>}

      {!candidates.roles.length && <div className="solver-v2-notice warning"><AlertTriangle/>Ten scenariusz nie zawiera wymaganych ról do scalenia.</div>}

      {preflight && preflight.totalGaps > 0 && <section className="role-composite-preflight">
        <header>
          <AlertTriangle/>
          <span>
            <strong>Przed publikacją potwierdź {preflight.totalGaps} nieobsadzonych miejsc</strong>
            <small>{preflight.criticalGaps > 0
              ? `${preflight.criticalGaps} z nich to krytyczne braki: na zmianie nie ma ani jednej osoby w wymaganej roli.`
              : "Każda zmiana ma co najmniej część wymaganej obsady, ale grafik pozostaje niekompletny."}</small>
          </span>
        </header>
        <div className="role-composite-gap-list">
          {preflight.gaps.slice(0, 12).map(gap => <article className={gap.critical ? "critical" : "partial"} key={gap.issueId}>
            <span><strong>{gap.date} • {gap.startsAt.slice(0,5)}–{gap.endsAt.slice(0,5)}</strong><small>{gap.location} • {gap.role}{gap.duty ? ` • ${gap.duty}` : ""}</small></span>
            <b>{gap.assignedCount}/{gap.requiredCount}<small>{gap.critical ? "brak całej roli" : `brakuje ${gap.missingCount}`}</small></b>
          </article>)}
          {preflight.gaps.length > 12 && <small className="role-composite-gap-more">oraz {preflight.gaps.length - 12} kolejnych miejsc — pełna lista pozostaje w grafikach ról.</small>}
        </div>
        {shortagePatterns.length > 0 && <div className="role-composite-structural-shortage">
          <strong>System wykrył powtarzalny brak zasobów, nie tylko pojedynczy wakat</strong>
          {shortagePatterns.slice(0, 4).map(pattern => <article key={`${pattern.role}:${pattern.location}:${pattern.startsAt}`}>
            <span><b>{pattern.role} • {pattern.location} • {pattern.startsAt.slice(0,5)}–{pattern.endsAt.slice(0,5)}</b><small>{pattern.dates.length} dni: {pattern.dates.join(", ")}</small></span>
            <em>około {new Intl.NumberFormat("pl-PL", { maximumFractionDigits: 1 }).format(pattern.hours)} roboczogodzin do pokrycia</em>
          </article>)}
          <small>Możliwe działania: dodatkowa osoba lub pula ad-hoc, zwiększenie wymiaru za zgodą, przeniesienie między lokalami, zmiana minimum obsady albo godzin działalności. System niczego nie zmieni bez decyzji właściciela.</small>
        </div>}
        <label className="role-composite-reason">Dlaczego publikujesz grafik mimo braków?
          <textarea
            ref={publicationReasonRef}
            value={publicationReason}
            maxLength={1000}
            disabled={busy}
            aria-invalid={publicationAttempted && publicationReasonInvalid}
            aria-describedby="role-composite-reason-help"
            placeholder="Np. lider zaakceptował obsadę 5/6, a krytyczny brak zostanie pokryty ofertą zmiany przed rozpoczęciem pracy."
            onChange={event => {
              setPublicationReason(event.target.value);
              if (event.target.value.trim().length >= 10) setPublicationAttempted(false);
            }}
          />
          <small
            id="role-composite-reason-help"
            style={publicationReasonInvalid ? { color: "#b42318", fontWeight: 700 } : undefined}
          >
            {publicationReasonInvalid
              ? `Wpisano ${publicationReasonLength}/10 znaków — dopisz jeszcze ${publicationReasonMissing}. Uzasadnienie zapisze się razem z publikacją; osobny zapis nie jest potrzebny.`
              : "Uzasadnienie jest gotowe i zapisze się razem z publikacją wraz z liczbą braków oraz osobą publikującą."}
          </small>
        </label>
      </section>}

      <div className="role-composite-publish">
        <span>
          <strong>{ready ? "Wszystkie zespoły w tym scenariuszu są opublikowane" : "Wspólna wersja czeka na brakujące publikacje zespołów"}</strong>
          <small>Niezależne grafiki są widoczne dla zespołów. Wspólna publikacja tworzy jeden obowiązujący grafik firmy i podlega końcowej kontroli oraz audytowi braków.</small>
        </span>
        <label>Nazwa wspólnego grafiku
          <input value={publicationName} maxLength={200} disabled={busy} onChange={event => setPublicationName(event.target.value)}/>
        </label>
        <button className="primary-button" disabled={busy || !ready || !publicationName.trim()} onClick={() => void publish()}>
          {busy ? <><RefreshCw className="spin"/> Sprawdzam i publikuję…</> : <><Upload/> Opublikuj scalony grafik</>}
        </button>
      </div>
    </>}

    {message && <div className={`solver-v2-notice ${messageIsWarning ? "warning" : ""}`}>
      {messageIsWarning ? <AlertTriangle/> : <Check/>}{message}
    </div>}

    {publishedWorkspace && publishedForSelection && <details className="role-composite-published" open={false}>
      <summary>
        <span><Check/><strong>Podgląd ostatniego scalenia ról</strong></span>
        <small>{publishedWorkspace.finance
          ? `Koszt ${money(publishedWorkspace.finance.totalCostMinor, publishedWorkspace.finance.currency)} • rozwiń pełny grafik`
          : "Rozwiń pełny grafik"}</small>
      </summary>
      <SolverV2Workspace workspace={publishedWorkspace} timezone={timezone} published/>
    </details>}
  </section>;
}
