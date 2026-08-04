"use client";

import { AlertTriangle, Check, CircleDollarSign, RefreshCw, Search, Sparkles, Square, Upload, Users, X } from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { SolverV2Workspace } from "@/components/SolverV2Workspace";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import {
  createIdempotencyKey,
  forgetPublishedSchedule,
  forgetSolverRun,
  getPublishedSchedule,
  getPublicationReadiness,
  getSelectedVariantWorkspace,
  getVariantWorkspace,
  getSolverStatus,
  getSolverVariants,
  isValidIdempotencyKey,
  isSolverRunTerminal,
  publicationAttemptStorageKey,
  publishCompanyVariant,
  publishRoleVariant,
  recoverPublishedSchedule,
  recoverSolverRun,
  rememberPublishedSchedule,
  rememberSolverRun,
  requestSolverCancellation,
  requestSolverRun,
  selectSolverVariant,
  solverErrorMessage,
  solverPendingRequestStorageKey,
  solverPhaseLabel,
  solverRequestFingerprint,
  solverStatusLabel,
  type RunStorageContext,
  type SolverEngine,
  type SolverRun,
  type SolverPublicationReadiness,
  type SolverScenario,
  type SolverScope,
  type SolverStrategyProgress,
  type SolverVariant,
  type SolverWorkspace,
} from "@/lib/solver-v2";

type Props = {
  engine: SolverEngine;
  solverVersion: string;
  userId: string;
  month: string;
  timezone: string;
  name: string;
  scenarioCode: string;
  scenarios: SolverScenario[];
  scopeType: SolverScope;
  scopeRoleId?: string | null;
  scopeLabel: string;
  matrixEffectiveFrom?: string|null;
  allowStart?: boolean;
  onNameChange: (value: string) => void;
  onScenarioChange: (value: string) => void;
  onVariantSelected?: (variant: SolverVariant) => void | Promise<void>;
  onPublished?: (scheduleId: string) => void | Promise<void>;
  initialRunId?: string | null;
  skipRecovery?: boolean;
};

function money(value: number | null | undefined, currency: string) {
  if (value === undefined || value === null) return "—";
  try {
    return new Intl.NumberFormat("pl-PL", { style: "currency", currency, maximumFractionDigits: 0 }).format(value / 100);
  } catch {
    return `${new Intl.NumberFormat("pl-PL", { maximumFractionDigits: 0 }).format(value / 100)} ${currency}`;
  }
}

function solutionLabel(value: string) {
  return value === "OPTIMAL" ? "Potwierdzone optimum" : "Poprawne rozwiązanie";
}

function variantCountLabel(value: number) {
  if (value === 1) return "1 wariant";
  if (value >= 2 && value <= 4) return `${value} warianty`;
  return `${value} wariantów`;
}

function aggregateVariantFingerprint(variant: SolverVariant) {
  const metrics = Object.entries(variant.metrics)
    .sort(([left], [right]) => left.localeCompare(right));
  return JSON.stringify({
    assignmentCount: variant.assignmentCount,
    unfilledCount: variant.unfilledCount,
    totalCostMinor: variant.totalCostMinor ?? null,
    metrics,
  });
}

function publicationIssueTime(value:string|undefined,timezone:string){
  if(!value)return "—";
  const date=new Date(value);
  if(!Number.isFinite(date.getTime()))return value;
  return new Intl.DateTimeFormat("pl-PL",{hour:"2-digit",minute:"2-digit",timeZone:timezone}).format(date);
}

type StatusRefreshOutcome = "ACTIVE" | "TERMINAL" | "RETRY" | "STALE";

function errorText(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

function isStaleRunReference(message: string) {
  const normalized = message.toUpperCase();
  return normalized.includes("RUN_NOT_FOUND")
    || normalized.includes("RUN_REFERENCE_MISMATCH")
    || normalized.includes("RUN_REQUEST_ENGINE_MISMATCH")
    || normalized.includes("RUN_SOLVER_VERSION_MISMATCH");
}

function isStalePublishedScheduleReference(message: string) {
  const normalized = message.toUpperCase();
  return normalized.includes("PUBLISHED_SCHEDULE_NOT_FOUND")
    || normalized.includes("PUBLISHED_SCHEDULE_REFERENCE_MISMATCH");
}

export function SolverV2Panel({
  engine,
  solverVersion,
  userId,
  month,
  timezone,
  name,
  scenarioCode,
  scenarios,
  scopeType,
  scopeRoleId,
  scopeLabel,
  matrixEffectiveFrom,
  allowStart = true,
  onNameChange,
  onScenarioChange,
  onVariantSelected,
  onPublished,
  initialRunId,
  skipRecovery = false,
}: Props) {
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const selectedScenario = scenarios.find(item => item.code === scenarioCode);
  const expectedSolverVersion = solverVersion.trim();
  const context = useMemo<RunStorageContext>(() => ({
    userId,
    engine,
    solverVersion: expectedSolverVersion,
    month,
    scenarioId: selectedScenario?.id ?? "missing-scenario",
    scopeType,
    scopeRoleId: scopeRoleId ?? null,
  }), [userId, engine, expectedSolverVersion, month, selectedScenario?.id, scopeType, scopeRoleId]);
  const [run, setRun] = useState<SolverRun | null>(null);
  const [pollingRunId, setPollingRunId] = useState<string | null>(null);
  const [strategies, setStrategies] = useState<SolverStrategyProgress[]>([]);
  const [variants, setVariants] = useState<SolverVariant[]>([]);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [pollWarning, setPollWarning] = useState("");
  const [selectedWorkspace, setSelectedWorkspace] = useState<SolverWorkspace | null>(null);
  const [inspectedWorkspace, setInspectedWorkspace] = useState<SolverWorkspace | null>(null);
  const [publishedWorkspace, setPublishedWorkspace] = useState<SolverWorkspace | null>(null);
  const [publicationName, setPublicationName] = useState(name);
  const [publicationReadiness,setPublicationReadiness]=useState<SolverPublicationReadiness|null>(null);
  const [refreshing,setRefreshing]=useState(false);
  const [lastStatusCheck,setLastStatusCheck]=useState("");
  const statusFingerprintRef=useRef("");

  const active = Boolean(run && !isSolverRunTerminal(run.status));
  const recovering = Boolean(pollingRunId && !run);
  const selectedVariant = variants.find(variant => variant.selected) ?? null;
  const selectedIsPublished = Boolean(
    selectedVariant
    && publishedWorkspace?.context.status === "PUBLISHED"
    && publishedWorkspace.variants.some(variant => variant.id === selectedVariant.id),
  );
  const previewWorkspace = inspectedWorkspace ?? (selectedIsPublished
    ? publishedWorkspace
    : selectedWorkspace ?? (!run ? publishedWorkspace : null));
  const allVariantsEquivalent = variants.length > 1 && variants.every((variant, index) => index === 0 || variant.equivalentToVariantId || variants[0].equivalentToVariantId === variant.id);
  const aggregateVariantCounts = useMemo(() => {
    const counts = new Map<string, number>();
    for (const variant of variants) {
      const fingerprint = aggregateVariantFingerprint(variant);
      counts.set(fingerprint, (counts.get(fingerprint) ?? 0) + 1);
    }
    return counts;
  }, [variants]);
  const messageIsWarning = [
    "Nie udało",
    "Nie masz",
    "Tylko właściciel",
    "Dane firmy",
    "Przed publikacją",
    "Ten grafik nie",
    "Podaj nazwę",
    "Nie znaleziono",
    "Wybrany scenariusz",
  ].some(prefix => message.startsWith(prefix));

  const loadSelectedWorkspace = useCallback(async (runId: string) => {
    if (!supabase) return;
    const workspace = await getSelectedVariantWorkspace(supabase, runId);
    setSelectedWorkspace(workspace);
    setPublicationName(workspace.context.name || "Grafik");
  }, [supabase]);

  const loadVariants = useCallback(async (runId: string) => {
    if (!supabase) return;
    const result = await getSolverVariants(supabase, runId);
    setVariants(result.variants);
    if (engine !== "SHADOW" && result.variants.some(variant => variant.selected)) {
      await loadSelectedWorkspace(runId);
    }
  }, [supabase, engine, loadSelectedWorkspace]);

  const refreshStatus = useCallback(async (runId: string, silent = false): Promise<StatusRefreshOutcome> => {
    if (!supabase) return "RETRY";
    if(!silent)setRefreshing(true);
    try {
      const result = await getSolverStatus(supabase, runId);
      if (result.run.id !== runId) {
        throw new Error("RUN_REFERENCE_MISMATCH");
      }
      if (result.run.requestEngine !== engine) {
        throw new Error("RUN_REQUEST_ENGINE_MISMATCH");
      }
      if (!expectedSolverVersion || result.run.solverVersion !== expectedSolverVersion) {
        throw new Error("RUN_SOLVER_VERSION_MISMATCH");
      }
      setRun(result.run);
      setStrategies(result.strategies);
      setPollWarning("");
      if (result.run.status === "READY" || result.run.status === "FAILED") await loadVariants(result.run.id);
      const fingerprint=`${result.run.status}:${result.run.phase}:${result.run.progress}:${result.run.updatedAt??""}`;
      const changed=Boolean(statusFingerprintRef.current&&statusFingerprintRef.current!==fingerprint);
      statusFingerprintRef.current=fingerprint;
      if(!silent){
        const checkedAt=new Intl.DateTimeFormat("pl-PL",{hour:"2-digit",minute:"2-digit",second:"2-digit",timeZone:timezone}).format(new Date());
        setLastStatusCheck(checkedAt);
        setMessage(changed
          ?`Status sprawdzony o ${checkedAt} — nowy stan: ${solverStatusLabel(result.run.status)} (${result.run.progress}%).`
          :`Status sprawdzony o ${checkedAt} — bez zmian. ${solverStatusLabel(result.run.status)} (${result.run.progress}%).`);
      }
      if (isSolverRunTerminal(result.run.status)) {
        setPollingRunId(current => current === runId ? null : current);
        return "TERMINAL";
      }
      return "ACTIVE";
    } catch (error) {
      const detail = errorText(error);
      if (isStaleRunReference(detail)) {
        forgetSolverRun(context);
        setPollingRunId(current => current === runId ? null : current);
        setRun(current => current?.id === runId ? null : current);
        setStrategies([]);
        setVariants([]);
        setSelectedWorkspace(null);
        setInspectedWorkspace(null);
        setPollWarning("");
        setMessage(solverErrorMessage(detail));
        return "STALE";
      }
      if (!silent) setMessage(solverErrorMessage(detail));
      else setPollWarning("Nie udało się odświeżyć postępu. Kolejna próba nastąpi automatycznie.");
      return "RETRY";
    } finally {
      if(!silent)setRefreshing(false);
    }
  }, [supabase, engine, expectedSolverVersion, loadVariants, context, timezone]);

  useEffect(() => {
    let disposed = false;
    setRun(null);
    setPollingRunId(null);
    setStrategies([]);
    setVariants([]);
    setSelectedWorkspace(null);
    setInspectedWorkspace(null);
    setPublishedWorkspace(null);
    setMessage("");
    setPollWarning("");
    setPublicationReadiness(null);
    setLastStatusCheck("");
    statusFingerprintRef.current="";
    const recovered = skipRecovery ? null : (initialRunId ?? recoverSolverRun(context));
    if (recovered) setPollingRunId(recovered);
    const publishedScheduleId = engine === "ORTOOLS_V2" ? recoverPublishedSchedule(context) : null;
    if (publishedScheduleId && supabase) {
      void getPublishedSchedule(supabase, publishedScheduleId)
        .then(workspace => {
          if (disposed) return;
          if (
            workspace.context.type !== "PUBLISHED_SCHEDULE"
            || workspace.context.engine !== "ORTOOLS_V2"
            || workspace.context.scheduleId !== publishedScheduleId
            || workspace.context.month.slice(0, 7) !== month.slice(0, 7)
          ) throw new Error("PUBLISHED_SCHEDULE_REFERENCE_MISMATCH");
          setPublishedWorkspace(workspace);
        })
        .catch(error => {
          if (!disposed && isStalePublishedScheduleReference(errorText(error))) {
            forgetPublishedSchedule(context);
          }
        });
    }
    return () => { disposed = true; };
  }, [context, engine, month, supabase, initialRunId, skipRecovery]);

  useEffect(() => {
    if (!pollingRunId) return;
    let disposed = false;
    let timer: number | undefined;
    const poll = async () => {
      const outcome = await refreshStatus(pollingRunId, true);
      if (disposed || (outcome !== "ACTIVE" && outcome !== "RETRY")) return;
      timer = window.setTimeout(() => void poll(), 2500);
    };
    void poll();
    return () => {
      disposed = true;
      if (timer !== undefined) window.clearTimeout(timer);
    };
  }, [pollingRunId, refreshStatus]);

  async function start() {
    if (!supabase || pollingRunId || !expectedSolverVersion || !selectedScenario?.id || selectedScenario.strategyCount === 0 || !name.trim()) return;
    setBusy(true);
    setMessage("");
    setPollWarning("");
    const requestFingerprint = solverRequestFingerprint(context, name);
    const requestKeyName = solverPendingRequestStorageKey(context, requestFingerprint);
    let idempotencyKey = window.localStorage.getItem(requestKeyName);
    if (!isValidIdempotencyKey(idempotencyKey)) {
      window.localStorage.removeItem(requestKeyName);
      idempotencyKey = createIdempotencyKey(context, requestFingerprint);
      window.localStorage.setItem(requestKeyName, idempotencyKey);
    }
    window.sessionStorage.removeItem(requestKeyName);
    try {
      const result = await requestSolverRun(supabase, {
        month,
        scenarioId: selectedScenario.id,
        scopeType,
        scopeRoleId,
        name: name.trim(),
        idempotencyKey,
      });
      if (result.run.requestEngine !== engine) {
        throw new Error("RUN_REQUEST_ENGINE_MISMATCH");
      }
      if (!expectedSolverVersion || result.run.solverVersion !== expectedSolverVersion) {
        throw new Error("RUN_SOLVER_VERSION_MISMATCH");
      }
      rememberSolverRun(context, result.run.id);
      window.localStorage.removeItem(requestKeyName);
      setRun(result.run);
      setPollingRunId(result.run.id);
      setStrategies([]);
      setVariants([]);
      setSelectedWorkspace(null);
      setPublicationName(name.trim());
      setMessage(result.reused
        ? "Odzyskano rozpoczęte wcześniej generowanie."
        : "Generator rozpoczął pracę. Możesz zamknąć tę kartę i wrócić później.");
    } catch (error) {
      setMessage(solverErrorMessage(errorText(error)));
    } finally {
      setBusy(false);
    }
  }

  async function cancel() {
    if (!supabase || !run || !window.confirm("Zatrzymać generowanie? Zapisane wcześniej grafiki nie zostaną usunięte.")) return;
    setBusy(true);
    setMessage("");
    try {
      const updated = await requestSolverCancellation(supabase, run.id);
      setRun(updated);
      setMessage("Wysłano prośbę o bezpieczne zatrzymanie generatora.");
    } catch (error) {
      setMessage(solverErrorMessage(error instanceof Error ? error.message : String(error)));
    } finally {
      setBusy(false);
    }
  }

  async function choose(variant: SolverVariant) {
    if (!supabase || !run) return;
    const costSummary = variant.totalCostMinor === undefined || variant.totalCostMinor === null
      ? ""
      : ` • koszt ${money(variant.totalCostMinor, variant.currency)}`;
    const confirmation = window.confirm(
      `Wybrać „${variant.strategy.name}” jako wynik tego generowania?\n\n` +
      `${variant.assignmentCount} przydziałów • ${variant.unfilledCount} braków${costSummary}`,
    );
    if (!confirmation) return;
    setBusy(true);
    setMessage("");
    try {
      await selectSolverVariant(supabase, run.id, variant.id);
      setVariants(current => current.map(item => ({ ...item, selected: item.id === variant.id })));
      await loadSelectedWorkspace(run.id);
      setMessage(scopeType === "ROLE"
        ? "Wariant roli został wybrany. Możesz go teraz opublikować niezależnie dla swojego zespołu."
        : "Wariant został wybrany. Obowiązujący grafik nie zmieni się, dopóki nie potwierdzisz osobnej publikacji.");
      await onVariantSelected?.({ ...variant, selected: true });
    } catch (error) {
      setMessage(solverErrorMessage(error instanceof Error ? error.message : String(error)));
    } finally {
      setBusy(false);
    }
  }

  async function inspectVariant(variant: SolverVariant) {
    if (!supabase) return;
    setBusy(true);
    setMessage("");
    try {
      setInspectedWorkspace(await getVariantWorkspace(supabase, variant.id));
    } catch (error) {
      setMessage(solverErrorMessage(error instanceof Error ? error.message : String(error)));
    } finally {
      setBusy(false);
    }
  }

  async function publishSelected() {
    if (!supabase || !run || !selectedVariant || engine === "SHADOW" || scopeType !== "COMPANY") return;
    const trimmedName = publicationName.trim();
    if (!trimmedName) {
      setMessage("Nie udało się opublikować grafiku. Podaj jego nazwę.");
      return;
    }
    setBusy(true);
    setMessage("");
    let readiness:SolverPublicationReadiness;
    try{
      readiness=await getPublicationReadiness(supabase,run.id,selectedVariant.id,trimmedName);
      setPublicationReadiness(readiness);
    }catch(error){
      setBusy(false);
      setMessage(solverErrorMessage(errorText(error)));
      return;
    }
    if(!readiness.ready){
      setBusy(false);
      setMessage("Nie można opublikować grafiku. Szczegółowe blokady są widoczne poniżej.");
      return;
    }
    let warningReason:string|null=null;
    if(readiness.warnings.unfilledCount>0){
      warningReason=window.prompt(
        `Wariant zawiera ${readiness.warnings.unfilledCount} braków obsady.\n\nPodaj powód publikacji mimo ostrzeżeń (zostanie zapisany w historii):`,
      )?.trim()??null;
      if(!warningReason||warningReason.length<3){
        setBusy(false);
        setMessage("Publikacja z brakami obsady została anulowana: wymagany jest powód decyzji.");
        return;
      }
    }
    const costSummary = selectedVariant.totalCostMinor === undefined || selectedVariant.totalCostMinor === null
      ? ""
      : ` • koszt ${money(selectedVariant.totalCostMinor, selectedVariant.currency)}`;
    const confirmation = window.confirm(
      `Opublikować „${trimmedName}” jako obowiązujący grafik dla wybranego miesiąca?\n\n`
      + `Wybrano strategię „${selectedVariant.strategy.name}”: ${selectedVariant.assignmentCount} przydziałów • ${selectedVariant.unfilledCount} braków${costSummary}.\n\n`
      + `${readiness.warnings.unfilledCount>0?`UWAGA: wariant zawiera ${readiness.warnings.unfilledCount} braków obsady.\n\n`:""}`
      + "Obecnie opublikowany grafik dla tego miesiąca zostanie zarchiwizowany. Przed publikacją system ponownie sprawdzi aktualne dane i wszystkie twarde reguły.",
    );
    if (!confirmation){setBusy(false);return;}

    const attemptKey = publicationAttemptStorageKey(context, run.id, selectedVariant.id, trimmedName);
    let idempotencyKey = window.localStorage.getItem(attemptKey);
    if (!isValidIdempotencyKey(idempotencyKey)) {
      window.localStorage.removeItem(attemptKey);
      const publicationFingerprint = solverRequestFingerprint(
        context,
        `${trimmedName}|publish:${run.id}:${selectedVariant.id}`,
      );
      idempotencyKey = createIdempotencyKey(context, publicationFingerprint);
      window.localStorage.setItem(attemptKey, idempotencyKey);
    }

    try {
      const publication = await publishCompanyVariant(supabase, {
        runId: run.id,
        variantId: selectedVariant.id,
        name: trimmedName,
        idempotencyKey,
        warningReason,
      });
      rememberPublishedSchedule(context, publication.scheduleId);
      window.localStorage.removeItem(attemptKey);
      setVariants(current => current.map(variant => variant.id === selectedVariant.id
        ? { ...variant, status: "PUBLISHED" }
        : variant));
      try {
        const workspace = await getPublishedSchedule(supabase, publication.scheduleId);
        setPublishedWorkspace(workspace);
        setMessage(publication.reused
          ? "Ten sam grafik był już opublikowany. Przywrócono jego aktualny podgląd."
          : "Grafik został opublikowany i jest teraz obowiązującym grafikiem miesiąca.");
      } catch {
        setMessage("Grafik został opublikowany, ale nie udało się odświeżyć jego podglądu. Użyj przycisku „Odśwież”.");
      }
      try {
        await onPublished?.(publication.scheduleId);
      } catch {
        setMessage("Grafik został opublikowany, ale główny widok nie odświeżył się automatycznie. Użyj przycisku „Odśwież”.");
      }
    } catch (error) {
      setMessage(solverErrorMessage(error instanceof Error ? error.message : String(error)));
    } finally {
      setBusy(false);
    }
  }

  async function publishSelectedRole() {
    if (!supabase || !run || !selectedVariant || engine === "SHADOW" || scopeType !== "ROLE") return;
    const trimmedName = publicationName.trim();
    if (!trimmedName) {
      setMessage("Nie udało się opublikować grafiku zespołu. Podaj jego nazwę.");
      return;
    }
    const confirmation = window.confirm(
      `Opublikować „${trimmedName}” dla zespołu ${scopeLabel}?\n\n`
      + `${selectedVariant.assignmentCount} przydziałów • ${selectedVariant.unfilledCount} braków.\n\n`
      + "Pracownicy tego zespołu od razu otrzymają powiadomienie i zobaczą swoje zmiany. Pozostałe zespoły nie muszą być jeszcze gotowe.",
    );
    if (!confirmation) return;

    const attemptKey = publicationAttemptStorageKey(context, run.id, selectedVariant.id, trimmedName);
    let idempotencyKey = window.localStorage.getItem(attemptKey);
    if (!isValidIdempotencyKey(idempotencyKey)) {
      window.localStorage.removeItem(attemptKey);
      const publicationFingerprint = solverRequestFingerprint(
        context,
        `${trimmedName}|publish-role:${run.id}:${selectedVariant.id}`,
      );
      idempotencyKey = createIdempotencyKey(context, publicationFingerprint);
      window.localStorage.setItem(attemptKey, idempotencyKey);
    }

    setBusy(true);
    setMessage("");
    try {
      const publication = await publishRoleVariant(supabase, {
        runId: run.id,
        variantId: selectedVariant.id,
        name: trimmedName,
        idempotencyKey,
      });
      window.localStorage.removeItem(attemptKey);
      setVariants(current => current.map(variant => variant.id === selectedVariant.id
        ? { ...variant, status: "PUBLISHED" }
        : variant));
      await onVariantSelected?.({ ...selectedVariant, status: "PUBLISHED" });
      setMessage(publication.reused
        ? "Ten grafik zespołu był już opublikowany. Nie wysłano podwójnych powiadomień."
        : `Grafik zespołu został opublikowany. Powiadomiono ${publication.notified} pracowników.`);
    } catch (error) {
      setMessage(solverErrorMessage(error instanceof Error ? error.message : String(error)));
    } finally {
      setBusy(false);
    }
  }

  function startAnother() {
    forgetSolverRun(context);
    setPollingRunId(null);
    setRun(null);
    setStrategies([]);
    setVariants([]);
    setSelectedWorkspace(null);
    setInspectedWorkspace(null);
    setPublicationReadiness(null);
    setMessage("");
  }

  return <div className="solver-v2-panel">
    <div className="solver-v2-heading">
      <span className="solver-v2-icon"><Sparkles/></span>
      <span>
        <strong>{engine === "SHADOW" ? "Nieprodukcyjny test nowego silnika" : "Optymalizacja całego Matrixa"}</strong>
        <small>{scopeLabel} • liczba wariantów wynika z aktywnych strategii Matrixa</small>
      </span>
      {engine === "SHADOW" && <em>TRYB CIENIA</em>}
    </div>

    <div className="solver-v2-notice matrix-source-notice"><AlertTriangle/><span><strong>Źródło danych: opublikowany Matrix{matrixEffectiveFrom?` obowiązujący od ${matrixEffectiveFrom}`:""}</strong><small>Wersja robocza nie trafia do silnika. Nowa rola, pracownik, stawka lub reguła zostanie użyta dopiero po poprawnej publikacji Matrixa dla tego miesiąca.</small></span></div>

    {recovering && <div className="solver-v2-notice"><RefreshCw className="spin"/>Odzyskuję rozpoczęte wcześniej generowanie…</div>}
    {!run && !recovering && !allowStart && <div className="solver-v2-notice"><Sparkles/>Uruchamianie nowego silnika jest wyłączone w bieżącej konfiguracji.</div>}
    {!run && !recovering && allowStart && <div className="solver-v2-form">
      <label>Nazwa
        <input value={name} onChange={event => onNameChange(event.target.value)}/>
      </label>
      <label>Scenariusz Matrixa
        <select value={scenarioCode} onChange={event => onScenarioChange(event.target.value)}>
          {scenarios.map(scenario => <option value={scenario.code} key={scenario.id ?? scenario.code}>
            {scenario.name}{scenario.strategyCount ? ` • ${variantCountLabel(scenario.strategyCount)}` : ""}
          </option>)}
        </select>
      </label>
      {selectedScenario?.description && <p>{selectedScenario.description}</p>}
      {!selectedScenario?.id && <div className="solver-v2-notice warning"><AlertTriangle/>Nowy Matrix nie jest jeszcze gotowy. Użyj dotychczasowego silnika.</div>}
      {selectedScenario?.id && selectedScenario.strategyCount===0 && <div className="solver-v2-notice warning"><AlertTriangle/>Ten scenariusz nie ma jeszcze aktywnej strategii. Dodaj co najmniej jedną w Matrixie.</div>}
      <button className="primary-button full" disabled={busy || !expectedSolverVersion || !selectedScenario?.id || selectedScenario.strategyCount===0 || !name.trim()} onClick={() => void start()}>
        {busy ? <><RefreshCw className="spin"/> Uruchamiam…</> : <><Sparkles/> Generuj wszystkie aktywne warianty</>}
      </button>
    </div>}

    {run && <div className="solver-v2-run">
      <div className="solver-v2-run-head">
        <span>
          <small>{solverPhaseLabel(run.phase)}</small>
          <strong>{solverStatusLabel(run.status)}</strong>
        </span>
        <b>{run.progress}%</b>
      </div>
      <div className="solver-v2-progress"><i style={{ width: `${run.progress}%` }}/></div>
      {strategies.length > 0 && <div className="solver-v2-strategies">
        {strategies.map(strategy => <div key={strategy.id}>
          <span><strong>{strategy.name}</strong><small>{solverStatusLabel(strategy.status)}</small></span>
          <em>{strategy.progress}%</em>
        </div>)}
      </div>}
      {run.failureMessage && <div className="solver-v2-notice warning"><AlertTriangle/>{solverErrorMessage(run.failureMessage)}</div>}
      {run.status==="QUEUED"&&run.phase==="RETRY_QUEUED"&&<div className="solver-v2-run-state retry"><RefreshCw/><span><strong>Poprzednia próba została bezpiecznie zakończona</strong><small>Zadanie oczekuje w kolejce na automatyczne ponowienie. „Odśwież” tylko sprawdza stan — nie tworzy kolejnej kopii zadania.</small></span></div>}
      {run.status==="FAILED"&&<div className="solver-v2-run-state failed"><AlertTriangle/><span><strong>Ten przebieg zakończył się błędem</strong><small>„Odśwież” sprawdza zapisany stan. „Spróbuj ponownie” tworzy nowe, osobne generowanie z aktualnymi danymi.</small></span></div>}
      {run.status==="STALE_INPUT"&&<div className="solver-v2-run-state failed"><AlertTriangle/><span><strong>Dane zmieniły się w czasie obliczeń</strong><small>Uruchom nowe generowanie, aby policzyć grafik na aktualnej, spójnej wersji Matrixa.</small></span></div>}
      {pollWarning && <div className="solver-v2-poll-warning">{pollWarning}</div>}
      <div className="solver-v2-actions">
        {active && <button className="secondary-button" disabled={busy || run.status === "CANCEL_REQUESTED"} onClick={() => void cancel()}><Square/> Zatrzymaj bezpiecznie</button>}
        <button className="secondary-button" disabled={busy||refreshing} onClick={() => void refreshStatus(run.id)}><RefreshCw className={refreshing?"spin":""}/> {refreshing?"Sprawdzam…":"Odśwież status"}</button>
        {lastStatusCheck&&<small className="solver-v2-last-check">Ostatnie ręczne sprawdzenie: {lastStatusCheck}</small>}
        {isSolverRunTerminal(run.status) && <button className="secondary-button" disabled={busy} onClick={startAnother}>{["FAILED","STALE_INPUT"].includes(run.status)?"Spróbuj ponownie":"Nowe generowanie"}</button>}
      </div>
    </div>}

    {variants.length > 0 && <div className="solver-v2-results">
      <div className="solver-v2-results-head">
        <span><strong>{run?.status==="READY"?"Porównaj gotowe warianty":"Zapisane warianty diagnostyczne"}</strong><small>{run?.status==="READY"?"Każdy został policzony osobno według strategii zapisanej w Matrixie.":"Nie można ich wybrać ani opublikować, ale pozostają widoczne, aby wskazać dokładnie, na którym wariancie zakończyła się finalizacja."}</small></span>
      </div>
      {allVariantsEquivalent && <div className="solver-v2-notice"><Check/><span><strong>Strategie zwróciły ten sam skład grafiku</strong><small>Przy obecnej obsadzie i twardych regułach silnik nie znalazł alternatywnego składu, który zmieniałby koszt, preferencje lub równy podział. Różne strategie nie tworzą sztucznie innych przydziałów.</small></span></div>}
      <div className="solver-v2-grid">
        {variants.map(variant => <article className={`${variant.recommended ? "recommended" : ""} ${variant.selected ? "selected" : ""}`} key={variant.id}>
          <div className="solver-v2-card-head">
            <span><small>STRATEGIA</small><h3>{variant.strategy.name}</h3></span>
            {variant.recommended && <em>REKOMENDOWANY</em>}
            {variant.selected && <em className="chosen"><Check/> WYBRANY</em>}
          </div>
          {variant.strategy.description && <p>{variant.strategy.description}</p>}
          <div className="solver-v2-metrics">
            <span><Users/><small>Przydziały</small><strong>{variant.assignmentCount}</strong></span>
            <span><AlertTriangle/><small>Braki</small><strong>{variant.unfilledCount}</strong></span>
            {variant.totalCostMinor !== undefined && variant.totalCostMinor !== null
              && <span><CircleDollarSign/><small>Koszt</small><strong>{money(variant.totalCostMinor, variant.currency)}</strong></span>}
          </div>
          <div className="solver-v2-coverage-detail"><span><small>Pokrycie wymaganej obsady</small><strong>{variant.assignmentCount + variant.unfilledCount > 0 ? `${Math.round(variant.assignmentCount / (variant.assignmentCount + variant.unfilledCount) * 1000) / 10}%` : "100%"}</strong></span><span><small>Koszt jednego przydziału</small><strong>{variant.totalCostMinor != null && variant.assignmentCount ? money(Math.round(variant.totalCostMinor / variant.assignmentCount), variant.currency) : "—"}</strong></span></div>
          <dl className="solver-v2-analysis">
            {Object.entries(variant.metrics).filter(([metric])=>metric!=="UNFILLED"&&metric!=="TOTAL_COST").map(([metric,value])=><div key={metric}><dt>{({PREFERENCE_VIOLATIONS:"Niespełnione preferencje",NOMINAL_DEVIATION_MINUTES:"Odchylenie od nominału (min)",OVERTIME_MINUTES:"Nadgodziny (min)",LOAD_SPREAD_MINUTES:"Rozpiętość obciążenia (min)",WEEKEND_SPREAD:"Różnica weekendów",BASELINE_CHANGES:"Zmiany wobec bazowego"} as Record<string,string>)[metric]??metric}</dt><dd>{String(value??"—")}</dd></div>)}
            {variant.budgetMinor!==undefined&&variant.budgetMinor!==null&&<div><dt>Budżet</dt><dd>{money(variant.budgetMinor,variant.currency)}</dd></div>}
          </dl>
          <div className={`solver-v2-validation ${variant.unfilledCount>0||variant.hardViolations>0?"warning":""}`}>
            {variant.unfilledCount>0||variant.hardViolations>0?<AlertTriangle/>:<Check/>}<span><strong>{variant.hardViolations>0?"Wariant zawiera niedozwolone przydziały":variant.unfilledCount>0?`Technicznie poprawny, ale niekompletny: ${variant.unfilledCount} nieobsadzonych miejsc`:"Kompletny grafik bez naruszeń"}</strong><small>{variant.unfilledCount>0?`Silnik nie złamał reguł pracownika — pozostawił wakaty zamiast wykonać niedozwolony przydział. ${solutionLabel(variant.solverStatus)}.`:solutionLabel(variant.solverStatus)}</small></span>
          </div>
          {variant.equivalentToVariantId && <small className="solver-v2-equivalent">Ten wariant ma taki sam skład jak inny wynik.</small>}
          {!variant.equivalentToVariantId && (aggregateVariantCounts.get(aggregateVariantFingerprint(variant)) ?? 0) > 1 && <small className="solver-v2-equivalent">Te same wskaźniki zbiorcze, ale inny skład pracowników. Otwórz szczegóły, aby porównać przydziały.</small>}
          <button className="secondary-button full" disabled={busy} onClick={() => void inspectVariant(variant)}><Search/> Pokaż grafik i rozkład braków</button>
          {engine === "SHADOW"
            ? <button className="secondary-button full" disabled>Wynik testowy — bez publikacji</button>
            : <button className="primary-button full" disabled={busy || run?.status!=="READY" || variant.selected || variant.hardViolations > 0} onClick={() => void choose(variant)}>
              {variant.selected ? <><Check/> Wybrano ten wariant</> : "Wybierz ten wariant"}
            </button>}
        </article>)}
      </div>
    </div>}

    {previewWorkspace && !inspectedWorkspace && <div id="solver-variant-detail"><SolverV2Workspace workspace={previewWorkspace} timezone={timezone} published={previewWorkspace.context.type === "PUBLISHED_SCHEDULE"}/></div>}

    {inspectedWorkspace && <>
      <button className="drawer-scrim top" aria-label="Zamknij podgląd wariantu" onClick={() => setInspectedWorkspace(null)}/>
      <aside className="drawer role-drawer top solver-variant-preview-drawer" style={{width:"min(1280px, calc(100vw - 32px))"}} aria-label="Podgląd grafiku wariantu">
        <div className="drawer-head">
          <div><p className="eyebrow">WARIANT • PODGLĄD GRAFIKU</p><h2>{inspectedWorkspace.context.name}</h2><small>Pełny skład, obsada według dni oraz rozkład braków.</small></div>
          <button className="icon-button" aria-label="Zamknij podgląd wariantu" onClick={() => setInspectedWorkspace(null)}><X/></button>
        </div>
        <div className="drawer-content"><SolverV2Workspace workspace={inspectedWorkspace} timezone={timezone} published={false}/></div>
      </aside>
    </>}

    {engine === "ORTOOLS_V2" && selectedVariant && selectedWorkspace && scopeType === "ROLE"
      && <div className="solver-v2-publication">
        <span>
          <strong>{selectedVariant.status === "PUBLISHED" ? "Grafik tego zespołu jest opublikowany" : "Opublikuj gotowy grafik zespołu"}</strong>
          <small>{selectedVariant.status === "PUBLISHED"
            ? "Pracownicy zespołu widzą już swoje zmiany. Właściciel może później połączyć opublikowane grafiki wszystkich ról."
            : "Nie musisz czekać na pozostałe role. Publikacja powiadomi tylko pracowników tego zespołu, a wynik pozostanie dostępny do późniejszego podsumowania całej firmy."}</small>
        </span>
        <label>Nazwa grafiku zespołu
          <input value={publicationName} maxLength={200} onChange={event => setPublicationName(event.target.value)}/>
        </label>
        <button className="primary-button" disabled={busy || !publicationName.trim() || selectedVariant.status === "PUBLISHED"} onClick={() => void publishSelectedRole()}>
          {selectedVariant.status === "PUBLISHED"
            ? <><Check/> Grafik opublikowany</>
            : busy ? <><RefreshCw className="spin"/> Publikuję…</> : <><Upload/> Opublikuj dla zespołu</>}
        </button>
      </div>}

    {engine === "ORTOOLS_V2" && selectedVariant && selectedWorkspace && scopeType === "COMPANY" && !selectedIsPublished
      && <div className="solver-v2-publication">
        <span>
          <strong>Publikacja jest osobną decyzją</strong>
          <small>Sam wybór wariantu nie zmienił obowiązującego grafiku. Publikacja ponownie sprawdzi aktualne dane i zastąpi dotychczasowy grafik tego miesiąca.</small>
        </span>
        <label>Nazwa publikowanego grafiku
          <input value={publicationName} maxLength={200} onChange={event => setPublicationName(event.target.value)}/>
        </label>
        <button className="primary-button" disabled={busy || !publicationName.trim()} onClick={() => void publishSelected()}>
          {busy ? <><RefreshCw className="spin"/> Publikuję…</> : <><Upload/> Opublikuj wybrany wariant</>}
        </button>
      </div>}

    {publicationReadiness&&<div className={`solver-v2-readiness ${publicationReadiness.ready?"ready":"blocked"}`}>
      <h4>{publicationReadiness.ready?"Grafik przeszedł kontrolę publikacji":"Publikacja jest zablokowana"}</h4>
      {Object.values(publicationReadiness.blockers).map(blocker=><div className="solver-v2-notice warning" key={blocker.code}><AlertTriangle/><span><strong>{blocker.message}</strong>{blocker.count!==undefined&&<small>Liczba problemów: {blocker.count}</small>}{blocker.status&&<small>Status: {solverStatusLabel(blocker.status)} • etap {solverPhaseLabel(blocker.phase??"")}</small>}</span></div>)}
      {publicationReadiness.warnings.unfilledCount>0&&<div className="solver-v2-notice warning"><AlertTriangle/><span><strong>{publicationReadiness.warnings.message??"Grafik zawiera braki obsady."}</strong><small>{publicationReadiness.warnings.unfilledCount} nieobsadzonych miejsc. To ostrzeżenie miękkie; publikacja wymaga świadomego potwierdzenia.</small></span></div>}
      {publicationReadiness.issues.length>0&&<details><summary>Szczegóły alertów ({publicationReadiness.issues.length})</summary><div className="publication-readiness-issues">{publicationReadiness.issues.map(issue=>{
        const required=issue.requiredCount??null,assigned=issue.assignedCount??0;
        return <article key={issue.id}><header><b>{issue.date??"Termin"} • {publicationIssueTime(issue.startsAt,timezone)}–{publicationIssueTime(issue.endsAt,timezone)}</b><em>{issue.severity}</em></header><strong>{[issue.locationName,issue.shiftTemplateName,issue.roleName,issue.dutyName].filter(Boolean).join(" • ")||issue.code}</strong><p>{issue.message}</p>{required!==null&&<small>Wymagane: {required} • przypisane: {assigned} • brakuje: {Math.max(0,required-assigned)}</small>}<button className="secondary-button" onClick={()=>document.getElementById(`solver-issue-${issue.id}`)?.scrollIntoView({behavior:"smooth",block:"center"})}>Pokaż w podglądzie wariantu</button></article>;
      })}</div></details>}
    </div>}

    {engine === "ORTOOLS_V2" && selectedIsPublished
      && <div className="solver-v2-selection-note">
        <Check/>
        <span>
          <strong>Ten wariant jest opublikowany</strong>
          <small>Jest obecnie obowiązującym grafikiem dla tego miesiąca.</small>
        </span>
      </div>}

    {message && <div className={`solver-v2-notice ${messageIsWarning ? "warning" : ""}`}>{messageIsWarning ? <AlertTriangle/> : <Check/>}{message}</div>}
  </div>;
}
