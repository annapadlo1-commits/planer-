"use client";

import { AlertTriangle, Check, Puzzle, RefreshCw, Upload, Users } from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { SolverV2Workspace } from "@/components/SolverV2Workspace";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import {
  createRoleCompositeIdempotencyKey,
  forgetPublishedSchedule,
  getPublishedSchedule,
  getRoleCompositeCandidates,
  isValidIdempotencyKey,
  publishRoleComposite,
  recoverPublishedSchedule,
  rememberPublishedSchedule,
  roleCompositePublicationAttemptStorageKey,
  solverErrorMessage,
  type RunStorageContext,
  type SolverEngine,
  type SolverRoleCompositeCandidates,
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
  refreshKey?: number;
  onPublished?: (scheduleId: string) => void | Promise<void>;
};

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

function sameVariantSet(left: string[], right: string[]) {
  return [...left].sort().join(":") === [...right].sort().join(":");
}

export function RoleCompositePanel({ engine, solverVersion, userId, month, timezone, scenarios, refreshKey = 0, onPublished }: Props) {
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const expectedSolverVersion = solverVersion.trim();
  const candidateRequestRef = useRef(0);
  const availableScenarios = useMemo(() => scenarios.filter(scenario => Boolean(scenario.id)), [scenarios]);
  const defaultScenarioId = availableScenarios.find(scenario => scenario.isDefault)?.id ?? "";
  const [scenarioId, setScenarioId] = useState(defaultScenarioId);
  const [candidates, setCandidates] = useState<SolverRoleCompositeCandidates | null>(null);
  const [publishedWorkspace, setPublishedWorkspace] = useState<SolverWorkspace | null>(null);
  const [publicationName, setPublicationName] = useState(`Grafik zespołów • ${monthLabel(month)}`);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [loading, setLoading] = useState(false);
  const storageContext = useMemo<RunStorageContext>(() => ({
    userId,
    engine,
    solverVersion: expectedSolverVersion,
    month,
    scenarioId: scenarioId || "missing-scenario",
    scopeType: "COMPANY",
    scopeRoleId: null,
  }), [userId, engine, expectedSolverVersion, month, scenarioId]);

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
      const result = await getRoleCompositeCandidates(supabase, month, scenarioId);
      if (requestId !== candidateRequestRef.current) return null;
      if (result.month.slice(0, 7) !== month.slice(0, 7) || result.scenario.id !== scenarioId) {
        throw new Error("ROLE_COMPOSITE_REFERENCE_MISMATCH");
      }
      setCandidates(result);
      if (!silent) setMessage("");
      return result;
    } catch (error) {
      if (requestId !== candidateRequestRef.current) return null;
      setCandidates(null);
      if (!silent) setMessage(solverErrorMessage(error instanceof Error ? error.message : String(error)));
      return null;
    } finally {
      if (!silent && requestId === candidateRequestRef.current) setLoading(false);
    }
  }, [supabase, scenarioId, engine, expectedSolverVersion, month]);

  useEffect(() => {
    candidateRequestRef.current += 1;
    setCandidates(null);
    if (scenarioId) void loadCandidates();
  }, [scenarioId, refreshKey, loadCandidates]);

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

  const missingRoles = candidates?.roles.filter(role => !role.variant || candidates.missingRoleIds.includes(role.id)) ?? [];
  const unknownMissingCount = candidates
    ? candidates.missingRoleIds.filter(id => !candidates.roles.some(role => role.id === id)).length
    : 0;
  const variantIds = candidates?.roles.flatMap(role => role.variant ? [role.variant.id] : []) ?? [];
  const ready = Boolean(
    candidates?.ready
    && candidates.roles.length > 0
    && missingRoles.length === 0
    && unknownMissingCount === 0
    && variantIds.length === candidates.roles.length,
  );
  const assignmentCount = candidates?.roles.reduce((sum, role) => sum + (role.variant?.assignmentCount ?? 0), 0) ?? 0;
  const unfilledCount = candidates?.roles.reduce((sum, role) => sum + (role.variant?.unfilledCount ?? 0), 0) ?? 0;
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

  async function publish() {
    if (!supabase || engine !== "ORTOOLS_V2" || !candidates || !selectedScenario?.id || !ready) return;
    const trimmedName = publicationName.trim();
    if (!trimmedName) {
      setMessage("Nie podano nazwy publikowanego grafiku.");
      return;
    }

    setBusy(true);
    setMessage("");
    try {
      const fresh = await getRoleCompositeCandidates(supabase, month, selectedScenario.id);
      setCandidates(fresh);
      const freshIds = fresh.roles.flatMap(role => role.variant ? [role.variant.id] : []);
      if (!fresh.ready || fresh.missingRoleIds.length > 0 || freshIds.length !== fresh.roles.length) {
        setMessage("Nie wszystkie wymagane role mają teraz wybrany wariant. Uzupełnij braki i odśwież zestaw.");
        return;
      }
      if (!sameVariantSet(variantIds, freshIds)) {
        setMessage("Zestaw wybranych wariantów zmienił się. Sprawdź odświeżoną listę i ponownie potwierdź publikację.");
        return;
      }
      const freshAssignmentCount = fresh.roles.reduce((sum, role) => sum + (role.variant?.assignmentCount ?? 0), 0);
      const freshUnfilledCount = fresh.roles.reduce((sum, role) => sum + (role.variant?.unfilledCount ?? 0), 0);

      const confirmation = window.confirm(
        `Opublikować „${trimmedName}” jako obowiązujący grafik dla ${monthLabel(month)}?\n\n`
        + `System połączy ${fresh.roles.length} grafików ról: ${freshAssignmentCount} przydziałów i ${freshUnfilledCount} braków.\n\n`
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

  return <section className="role-composite-panel">
    <div className="role-composite-head">
      <span className="role-composite-icon"><Puzzle/></span>
      <span>
        <small>GLOBALNE SCALENIE RÓL</small>
        <strong>Publikacja wspólnego grafiku</strong>
        <em>Każda wymagana rola musi mieć świadomie wybrany wariant.</em>
      </span>
      <button className="secondary-button" disabled={loading || busy || !scenarioId || !expectedSolverVersion} onClick={() => void loadCandidates()}>
        <RefreshCw className={loading ? "spin" : ""}/> Odśwież zestaw
      </button>
    </div>

    {!expectedSolverVersion && <div className="solver-v2-notice warning"><AlertTriangle/>Konfiguracja nie wskazuje aktywnej wersji workera. Scalanie pozostaje zablokowane.</div>}

    <label className="role-composite-scenario">Scenariusz Matrixa
      <select value={scenarioId} disabled={loading || busy || !expectedSolverVersion} onChange={event => setScenarioId(event.target.value)}>
        {availableScenarios.map(scenario => <option key={scenario.id ?? scenario.code} value={scenario.id ?? ""}>{scenario.name}</option>)}
      </select>
    </label>

    {!availableScenarios.length && <div className="solver-v2-notice warning"><AlertTriangle/>Aktywny Matrix nie ma scenariusza dostępnego do scalenia.</div>}
    {loading && <div className="role-composite-loading"><RefreshCw className="spin"/> Sprawdzam wybrane warianty wszystkich ról…</div>}

    {candidates && !loading && <>
      <div className="role-composite-summary">
        <span><Users/><small>Wymagane role</small><strong>{candidates.roles.length}</strong></span>
        <span><Check/><small>Wybrane warianty</small><strong>{variantIds.length}</strong></span>
        <span><AlertTriangle/><small>Braki obsady</small><strong>{unfilledCount}</strong></span>
      </div>

      <div className="role-composite-roles">
        {candidates.roles.map(role => <article className={role.variant ? "ready" : "missing"} key={role.id}>
          <span>
            <small>ROLA</small>
            <strong>{role.name}</strong>
          </span>
          {role.variant
            ? <>
              <span className="role-composite-variant">
                <small>{role.variant.strategy.name}</small>
                <strong>{role.variant.name}</strong>
                <em>{solutionLabel(role.variant.solverStatus)}</em>
              </span>
              <span className="role-composite-counts">
                <b>{role.variant.assignmentCount}</b><small>przydziałów</small>
                <b>{role.variant.unfilledCount}</b><small>braków</small>
              </span>
              <em className="role-composite-state"><Check/> Wybrany</em>
            </>
            : <div className="role-composite-missing"><AlertTriangle/><span><strong>Brak wybranego wariantu</strong><small>Otwórz generator tej roli, utwórz wariant i wybierz go do scalenia.</small></span></div>}
        </article>)}
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

      <div className="role-composite-publish">
        <span>
          <strong>{ready ? "Komplet wariantów jest gotowy" : "Publikacja czeka na komplet ról"}</strong>
          <small>Publikacja jest osobną decyzją i zawsze uruchamia ponowną globalną walidację.</small>
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
