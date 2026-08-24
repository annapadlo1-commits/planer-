"use client";

import { AlertTriangle, CalendarDays, Cat, Check, CircleDollarSign, Edit3, History, Redo2, RefreshCw, Search, Sparkles, Square, Undo2, Upload, Users, X } from "lucide-react";
import dynamic from "next/dynamic";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { SolverV2Workspace } from "@/components/SolverV2Workspace";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { presentSolverVariantMetrics } from "@/lib/solver-variant-presentation";
import {
  MANDATORY_PRODUCT_GUARDS_DESCRIPTION,
  MANDATORY_PRODUCT_GUARDS_LABEL,
} from "@/lib/solver-strategy-contract";
import { polishQueuedTaskSentence } from "@/lib/polish-plural";
import {
  createIdempotencyKey,
  createLeaderVariant,
  createManualLeaderStudio,
  requestLeaderRefill,
  applyLeaderRefill,
  requestLeaderReoptimization,
  applyLeaderReoptimization,
  forgetPublishedSchedule,
  forgetSolverRun,
  getPublishedSchedule,
  getPublicationChangePreview,
  getPublicationReadiness,
  getPublicationAuthorityStatus,
  getLeaderVariantForRun,
  getLeaderVariantWorkspace,
  getLeaderHistoryStatus,
  getLeaderWorkflowStatus,
  getSelectedVariantWorkspace,
  getVariantWorkspace,
  getSolverStatus,
  getSolverVariants,
  createLeaderCheckpoint,
  moveLeaderHistory,
  restoreLeaderCheckpoint,
  transitionLeaderWorkflow,
  validateLeaderDraft,
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
  type SolverLeaderVariant,
  type SolverLeaderHistoryStatus,
  type SolverLeaderWorkflowStatus,
  type SolverLeaderDraftValidation,
  type SolverLeaderOptimizationMode,
  type SolverPublicationChangePreview,
  type SolverPublicationReadiness,
  type SolverScenario,
  type SolverScope,
  type SolverStrategyProgress,
  type SolverVariant,
  type SolverWorkspace,
} from "@/lib/solver-v2";

const LazyGeneratorMemoryExperience=dynamic(()=>import("@/components/games/GeneratorMemoryExperience"),{
  ssr:false,
  loading:()=> <div className="cat-game-loading" role="status"><Cat/><strong>Ładuję Memory…</strong></div>,
});
const GENERATOR_MEMORY_PROMPT_KEY="szafunek_memory_generator_prompt_seen";

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
  activeConfigurationVersion?: number|null;
  draftConfigurationVersion?: number|null;
  allowStart?: boolean;
  onNameChange: (value: string) => void;
  onScenarioChange: (value: string) => void;
  onVariantSelected?: (variant: SolverVariant) => void | Promise<void>;
  onOpenAdHoc?:(context:{roleId:string|null;date:string|null})=>void;
  onOpenReadiness?:()=>void;
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
  return value === "OPTIMAL"
    ? "Silnik matematycznie potwierdził, że dla tych priorytetów nie istnieje lepszy wynik"
    : "Najlepszy wynik znaleziony w dostępnym czasie — bez matematycznego potwierdzenia optimum";
}

function variantCountLabel(value: number) {
  if (value === 1) return "1 wariant";
  if (value >= 2 && value <= 4) return `${value} warianty`;
  return `${value} wariantów`;
}

function elapsedLabel(seconds: number | null | undefined) {
  const safeSeconds = Math.max(0, Math.floor(seconds ?? 0));
  if (safeSeconds < 60) return `${safeSeconds} s`;
  const minutes = Math.floor(safeSeconds / 60);
  const remainder = safeSeconds % 60;
  return remainder ? `${minutes} min ${remainder} s` : `${minutes} min`;
}

function strategyDescription(strategy: SolverVariant["strategy"]) {
  return strategy.description?.trim() ?? "";
}

function workloadMinutesLabel(value:number){
  const safeMinutes=Math.max(0,Math.round(value));
  const hours=Math.floor(safeMinutes/60);
  const minutes=safeMinutes%60;
  if(!hours)return `${minutes} min`;
  return minutes?`${hours} godz. ${minutes} min`:`${hours} godz.`;
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

function auditObject(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

function solverStageProofLabel(variant: SolverVariant) {
  const fallbackCount = variant.stageProof.filter(stage => stage.usedFallback === true).length;
  const elapsed = variant.stageProof.reduce(
    (total, stage) => total + (Number(stage.elapsedSeconds) || 0),
    0,
  );
  const budget = variant.stageProof.reduce(
    (total, stage) => total + (Number(stage.timeBudgetSeconds) || 0),
    0,
  );
  return `${variant.stageProof.length} etapów • ${elapsed.toFixed(2)} s / ${budget.toFixed(2)} s • fallback: ${fallbackCount}`;
}

function solverVersionStampLabel(variant: SolverVariant) {
  const stamp = variant.versionStamp;
  if (!stamp) return "—";
  const values = [
    `frontend ${stamp.frontendCommit.slice(0, 12)}`,
    `solver ${stamp.solverCommit.slice(0, 12)}`,
    `build ${stamp.solverBuildId}`,
    `gateway ${stamp.gatewayVersion?.slice(0, 16) ?? "—"}`,
    `DB ${stamp.databaseMigrationVersion}`,
    `strategia ${stamp.strategyConfigVersion.slice(0, 12)}`,
    stamp.executionMode === "JOB" && stamp.northflankRunId
      ? `Job ${stamp.northflankRunId.slice(0, 12)}`
      : stamp.executionMode,
  ];
  return values.join(" • ");
}

function leaderOptimizationSource(variants:SolverVariant[],mode:SolverLeaderOptimizationMode){
  const valid=variants.filter(variant=>variant.hardViolations===0);
  if(!valid.length)return null;
  if(mode==="COST")return [...valid].sort((left,right)=>
    (left.totalCostMinor??Number.MAX_SAFE_INTEGER)-(right.totalCostMinor??Number.MAX_SAFE_INTEGER)
    ||left.unfilledCount-right.unfilledCount)[0];
  if(mode==="FAIRNESS"){
    const score=(variant:SolverVariant)=>{
      for(const key of ["LOAD_UTILIZATION_SPREAD_BPS","LOAD_SPREAD_MINUTES","TARGET_DEVIATION_MINUTES"]){
        const value=Number(variant.metrics[key]);
        if(Number.isFinite(value))return value;
      }
      return Number.MAX_SAFE_INTEGER;
    };
    return [...valid].sort((left,right)=>score(left)-score(right)||left.unfilledCount-right.unfilledCount)[0];
  }
  return valid.find(variant=>variant.recommended)??valid[0];
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
  activeConfigurationVersion,
  draftConfigurationVersion,
  allowStart = true,
  onNameChange,
  onScenarioChange,
  onVariantSelected,
  onOpenAdHoc,
  onOpenReadiness,
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
  const [memoryPromptOpen,setMemoryPromptOpen]=useState(false);
  const [memoryGameOpen,setMemoryGameOpen]=useState(false);
  const [strategies, setStrategies] = useState<SolverStrategyProgress[]>([]);
  const [variants, setVariants] = useState<SolverVariant[]>([]);
  const [busy, setBusy] = useState(false);
  const [leaderWorkspaceBusy,setLeaderWorkspaceBusy]=useState(false);
  const [message, setMessage] = useState("");
  const [pollWarning, setPollWarning] = useState("");
  const [selectedWorkspace, setSelectedWorkspace] = useState<SolverWorkspace | null>(null);
  const [leaderBaselineWorkspace,setLeaderBaselineWorkspace]=useState<SolverWorkspace|null>(null);
  const [leaderVariant,setLeaderVariant]=useState<SolverLeaderVariant|null>(null);
  const [leaderStudioOpen,setLeaderStudioOpen]=useState(false);
  const [leaderHistory,setLeaderHistory]=useState<SolverLeaderHistoryStatus|null>(null);
  const [leaderCheckpointName,setLeaderCheckpointName]=useState("");
  const [leaderCheckpointRestoreSeq,setLeaderCheckpointRestoreSeq]=useState<number|null>(null);
  const [leaderCheckpointRestoreReason,setLeaderCheckpointRestoreReason]=useState("");
  const [leaderWorkflow,setLeaderWorkflow]=useState<SolverLeaderWorkflowStatus>("DRAFT");
  const [pendingLeaderWorkflow,setPendingLeaderWorkflow]=useState<SolverLeaderWorkflowStatus|null>(null);
  const [leaderWorkflowReason,setLeaderWorkflowReason]=useState("");
  const [leaderDraftValidation,setLeaderDraftValidation]=useState<SolverLeaderDraftValidation|null>(null);
  const handleLeaderWorkspaceBusyChange=useCallback((nextBusy:boolean)=>{
    setLeaderWorkspaceBusy(nextBusy);
    if(nextBusy)setLeaderDraftValidation(null);
  },[]);
  const [leaderRefillReason,setLeaderRefillReason]=useState("");
  const [leaderRefillSubmitting,setLeaderRefillSubmitting]=useState(false);
  const [leaderRefillRun,setLeaderRefillRun]=useState<{runId:string;leaderRevision:number;reason:string}|null>(null);
  const [leaderRefillStatus,setLeaderRefillStatus]=useState<{tone:"info"|"success"|"danger";title:string;detail:string}|null>(null);
  const leaderRefillApplyingRef=useRef(false);
  const [leaderOptimizationMode,setLeaderOptimizationMode]=useState<SolverLeaderOptimizationMode>("COST");
  const [leaderOptimizationReason,setLeaderOptimizationReason]=useState("");
  const [leaderOptimizationRun,setLeaderOptimizationRun]=useState<{runId:string;leaderRevision:number;mode:SolverLeaderOptimizationMode;reason:string}|null>(null);
  const [leaderOptimizationStatus,setLeaderOptimizationStatus]=useState<{tone:"info"|"success"|"danger";title:string;detail:string}|null>(null);
  const [leaderOptimizationProposal,setLeaderOptimizationProposal]=useState<{sourceVariantId:string;workspace:SolverWorkspace;leaderRevision:number;reason:string}|null>(null);
  const leaderOptimizationApplyingRef=useRef(false);
  const [inspectedWorkspace, setInspectedWorkspace] = useState<SolverWorkspace | null>(null);
  const [inspectingVariantId, setInspectingVariantId] = useState<string | null>(null);
  const [publishedWorkspace, setPublishedWorkspace] = useState<SolverWorkspace | null>(null);
  const [publicationName, setPublicationName] = useState(name);
  const [publicationChanges,setPublicationChanges]=useState<SolverPublicationChangePreview|null>(null);
  const [publicationChangesBusy,setPublicationChangesBusy]=useState(false);
  const [publicationChangesRetry,setPublicationChangesRetry]=useState(0);
  const [publicationReadiness,setPublicationReadiness]=useState<SolverPublicationReadiness|null>(null);
  const [pendingCompanyPublication,setPendingCompanyPublication]=useState<{warningCount:number;roleReplacementCount:number}|null>(null);
  const [publicationWarningReason,setPublicationWarningReason]=useState("");
  const [publicationReplacementReason,setPublicationReplacementReason]=useState("");
  const [refreshing,setRefreshing]=useState(false);
  const [lastStatusCheck,setLastStatusCheck]=useState("");
  const statusFingerprintRef=useRef("");

  const active = Boolean(run && !isSolverRunTerminal(run.status));
  const recovering = Boolean(pollingRunId && !run);
  const canOpenManualStudio = engine === "ORTOOLS_V2" && allowStart && !recovering && !active && !leaderVariant;
  const generatedSelectedVariant = (leaderVariant ? variants.find(variant=>variant.id===leaderVariant.sourceVariantId) : null)
    ?? variants.find(variant => variant.selected)
    ?? null;
  const leaderStudioSourceVariants = run?.status === "READY"
    ? variants.filter(variant=>variant.hardViolations===0)
    : [];
  const selectedVariant = generatedSelectedVariant && leaderVariant ? {
    ...generatedSelectedVariant,
    id:leaderVariant.id,
    name:leaderVariant.name,
    status:leaderVariant.status,
    assignmentCount:leaderVariant.assignmentCount||selectedWorkspace?.variants[0]?.assignmentCount||generatedSelectedVariant.assignmentCount,
    unfilledCount:leaderVariant.unfilledCount||selectedWorkspace?.variants[0]?.unfilledCount||0,
    selected:true,
  } : leaderVariant&&selectedWorkspace?.variants[0] ? {
    ...selectedWorkspace.variants[0],id:leaderVariant.id,name:leaderVariant.name,
    status:leaderVariant.status,selected:true,hardViolations:0,
    totalCostMinor:selectedWorkspace.variants[0].finance?.totalCostMinor??null,
    budgetMinor:selectedWorkspace.variants[0].finance?.budgetMinor??null,
    currency:selectedWorkspace.variants[0].finance?.currency??"PLN",
    metrics:{manualStudio:true},
    stageProof:[],
    versionStamp:null,
  } : generatedSelectedVariant;
  const leaderPublicationReady = !leaderVariant
    || selectedVariant?.id!==leaderVariant.id
    || leaderWorkflow==="READY_TO_MERGE"
    || leaderWorkflow==="PUBLISHED";
  const studioBusy=busy||leaderWorkspaceBusy;
  const leaderDraftValidationCurrent=Boolean(
    leaderVariant
    && leaderDraftValidation?.variantId===leaderVariant.id
    && leaderDraftValidation.revision===leaderVariant.revision,
  );
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
    let loadedVariants=result.variants;
    if(engine==="ORTOOLS_V2"&&scopeType==="ROLE"&&scopeRoleId){
      try{
        const authority=await getPublicationAuthorityStatus(supabase,month);
        const rolePublication=authority.roles.find(item=>item.roleId===scopeRoleId);
        if(rolePublication)loadedVariants=loadedVariants.map(variant=>variant.id===rolePublication.variantId
          ? {...variant,status:"PUBLISHED"}
          : variant);
      }catch{
        // Publication status is an enhancement to recovered runs; the run remains usable if it cannot be read.
      }
    }
    setVariants(loadedVariants);
    if(engine!=="SHADOW"){
      const leader=await getLeaderVariantForRun(supabase,runId);
      setLeaderDraftValidation(null);
      setLeaderVariant(leader);
      if(leader){
        setLeaderStudioOpen(true);
        const [workspace,baseline]=await Promise.all([getLeaderVariantWorkspace(supabase,leader.id),leader.sourceVariantId?getVariantWorkspace(supabase,leader.sourceVariantId):Promise.resolve(null)]);
        setLeaderBaselineWorkspace(baseline);
        setSelectedWorkspace(workspace);
        setPublicationName(workspace.context.name||leader.name);
      }else if(loadedVariants.some(variant => variant.selected)){
        setLeaderStudioOpen(false);
        await loadSelectedWorkspace(runId);
      }
    }
  }, [supabase, engine, loadSelectedWorkspace, month, scopeRoleId, scopeType]);

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
    setMemoryPromptOpen(false);
    setMemoryGameOpen(false);
    setStrategies([]);
    setVariants([]);
    setSelectedWorkspace(null);
    setLeaderBaselineWorkspace(null);
    setLeaderVariant(null);
    setLeaderStudioOpen(false);
    setLeaderDraftValidation(null);
    setInspectedWorkspace(null);
    setPublishedWorkspace(null);
    setPublicationChanges(null);
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

  useEffect(()=>{
    if(!supabase||engine!=="ORTOOLS_V2"||!selectedVariant||selectedVariant.status==="PUBLISHED"||!leaderPublicationReady){
      setPublicationChanges(null);setPublicationChangesBusy(false);return;
    }
    let disposed=false;
    setPublicationChangesBusy(true);
    void getPublicationChangePreview(supabase,selectedVariant.id)
      .then(preview=>{if(!disposed)setPublicationChanges(preview);})
      .catch(()=>{if(!disposed)setPublicationChanges(null);})
      .finally(()=>{if(!disposed)setPublicationChangesBusy(false);});
    return()=>{disposed=true;};
  },[supabase,engine,selectedVariant?.id,selectedVariant?.status,leaderPublicationReady,publicationChangesRetry]);

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

  useEffect(()=>{
    if(!supabase||!leaderVariant||leaderVariant.status==="PUBLISHED"){setLeaderHistory(null);return;}
    let disposed=false;
    void Promise.all([getLeaderHistoryStatus(supabase,leaderVariant.id),getLeaderWorkflowStatus(supabase,leaderVariant.id)])
      .then(([history,workflow])=>{if(!disposed){setLeaderHistory(history);setLeaderWorkflow(workflow);}})
      .catch(error=>{if(!disposed)setMessage(solverErrorMessage(errorText(error)));});
    return()=>{disposed=true;};
  },[supabase,leaderVariant?.id,leaderVariant?.revision,leaderVariant?.status]);

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
      if(!isSolverRunTerminal(result.run.status)){
        try{
          if(window.localStorage.getItem(GENERATOR_MEMORY_PROMPT_KEY)!=="true"){
            window.localStorage.setItem(GENERATOR_MEMORY_PROMPT_KEY,"true");
            setMemoryPromptOpen(true);
          }
        }catch{
          // Brak localStorage nie może wpływać na generator ani wymuszać ponownego pokazywania sugestii.
        }
      }
      setMessage(result.reused
        ? "Odzyskano rozpoczęte wcześniej generowanie."
        : "Zlecenie zapisano w kolejce. Gdy worker rozpocznie obliczenia, status zmieni się automatycznie.");
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
    setBusy(true);
    setMessage("");
    try {
      await selectSolverVariant(supabase, run.id, variant.id);
      setLeaderDraftValidation(null);
      setLeaderVariant(null);
      setLeaderStudioOpen(false);
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

  async function createLeaderCopy(sourceVariant:SolverVariant){
    if(!supabase||!run)return;
    setBusy(true);setMessage("");
    try{
      const leader=await createLeaderVariant(supabase,{
        runId:run.id,sourceVariantId:sourceVariant.id,
        name:`Wersja lidera • ${scopeLabel} • ${month.slice(0,7)}`,
      });
      const workspace=await getLeaderVariantWorkspace(supabase,leader.id);
      const baseline=await getVariantWorkspace(supabase,sourceVariant.id);
      const summary=workspace.variants[0];
      setVariants(current=>current.map(variant=>({...variant,selected:variant.id===sourceVariant.id})));
      setLeaderDraftValidation(null);
      setLeaderVariant({...leader,assignmentCount:summary?.assignmentCount??sourceVariant.assignmentCount,
        unfilledCount:summary?.unfilledCount??sourceVariant.unfilledCount});
      setLeaderStudioOpen(true);
      setSelectedWorkspace(workspace);setPublicationName(workspace.context.name||leader.name);
      setLeaderBaselineWorkspace(baseline);
      setMessage(`Otwarto osobną wersję lidera na bazie strategii „${sourceVariant.strategy.name}”. Warianty generatora pozostały bez zmian; możesz teraz dowolnie poprawiać szkic przed wspólną kontrolą.`);
    }catch(error){setMessage(solverErrorMessage(errorText(error)));}
    finally{setBusy(false);}
  }

  async function createManualStudio(){
    if(!supabase||!selectedScenario?.id||!expectedSolverVersion||!name.trim())return;
    setBusy(true);setMessage("");
    try{
      const created=await createManualLeaderStudio(supabase,{
        month,scenarioId:selectedScenario.id,scopeType,scopeRoleId,
        name:`Studio lidera • ${scopeLabel} • ${month.slice(0,7)}`,
        solverVersion:expectedSolverVersion,
      });
      const [status,workspace]=await Promise.all([
        getSolverStatus(supabase,created.runId),getLeaderVariantWorkspace(supabase,created.leader.id),
      ]);
      rememberSolverRun(context,created.runId);
      setRun(status.run);setStrategies(status.strategies);setVariants([]);
      setLeaderDraftValidation(null);
      setLeaderVariant({...created.leader,
        assignmentCount:workspace.variants[0]?.assignmentCount??0,
        unfilledCount:workspace.variants[0]?.unfilledCount??created.leader.unfilledCount});
      setLeaderStudioOpen(true);
      setSelectedWorkspace(workspace);setPublicationName(workspace.context.name||created.leader.name);
      setLeaderBaselineWorkspace(null);
      setMessage("Otwarto Studio bez generatora. Wszystkie wymagane miejsca są widoczne jako braki; obsadzaj je ręcznie, a każda zmiana przejdzie kontrolę całego miesiąca.");
    }catch(error){setMessage(solverErrorMessage(errorText(error)));}
    finally{setBusy(false);}
  }

  async function reloadLeaderWorkspace(){
    if(!supabase||!leaderVariant)return;
    setBusy(true);
    try{
      const workspace=await getLeaderVariantWorkspace(supabase,leaderVariant.id);
      const summary=workspace.variants[0];
      if((workspace.context.revision??leaderVariant.revision)!==leaderVariant.revision){
        setPendingLeaderWorkflow(null);
        setLeaderWorkflowReason("");
      }
      setSelectedWorkspace(workspace);
      setLeaderDraftValidation(current=>current?.variantId===leaderVariant.id
        && current.revision===workspace.context.revision?current:null);
      setLeaderHistory(await getLeaderHistoryStatus(supabase,leaderVariant.id));
      setLeaderVariant(current=>current?{...current,revision:workspace.context.revision??current.revision,
        assignmentCount:summary?.assignmentCount??current.assignmentCount,
        unfilledCount:summary?.unfilledCount??current.unfilledCount,lastEditedAt:workspace.context.lastEditedAt}:current);
    }catch(error){setMessage(solverErrorMessage(errorText(error)));}
    finally{setBusy(false);}
  }

  async function checkLeaderDraft(){
    if(!supabase||!leaderVariant)return;
    setBusy(true);setMessage("");
    try{
      const result=await validateLeaderDraft(supabase,leaderVariant.id);
      setLeaderDraftValidation(result);
      setMessage(result.valid
        ? `Kontrola rewizji ${result.revision} zakończona: brak naruszeń twardych. Wakaty: ${result.unfilledCount}; osoby z 0 h: ${result.zeroHoursCount}; osoby poniżej nominału: ${result.belowTargetCount}; nadgodziny: ${workloadMinutesLabel(result.overtimeMinutes)}; niespełnione preferencje: ${result.preferenceViolations}.`
        : `Kontrola rewizji ${result.revision} wykryła ${result.hardViolations} naruszeń twardych. Popraw wskazane miejsca przed przekazaniem grafiku. Pełny raport pozostaje widoczny nad kalendarzem.`);
    }catch(error){setLeaderDraftValidation(null);setMessage(solverErrorMessage(errorText(error)));}
    finally{setBusy(false);}
  }

  async function startLeaderRefill(){
    if(!supabase){
      const detail="Brak połączenia z backendem UAT. Odśwież stronę, ponownie otwórz Studio lidera i spróbuj jeszcze raz.";
      setLeaderRefillStatus({tone:"danger",title:"Nie można uruchomić generatora",detail});setMessage(detail);return;
    }
    if(!leaderVariant||leaderWorkflow!=="DRAFT"){
      const detail="Automatyczne uzupełnianie działa wyłącznie w otwartej wersji roboczej. Wróć do etapu „Roboczy” i spróbuj ponownie.";
      setLeaderRefillStatus({tone:"danger",title:"Szkic nie jest gotowy do edycji",detail});setMessage(detail);return;
    }
    const reason=leaderRefillReason.trim();
    if(reason.length<3){setMessage("Podaj krótki powód automatycznego uzupełnienia wakatów — zostanie zapisany w audycie.");return;}
    setLeaderRefillSubmitting(true);setBusy(true);setMessage("");
    setLeaderRefillStatus({tone:"info",title:"Kliknięcie przyjęte — uruchamiam zadanie",detail:"Łączę szkic z generatorem. Wszystkie ręczne decyzje pozostaną zablokowane, a zadanie obejmie wyłącznie wakaty."});
    try{
      const request=await requestLeaderRefill(supabase,{
        variantId:leaderVariant.id,reason,
        idempotencyKey:createIdempotencyKey(context,`leader-refill-r${leaderVariant.revision}`),
      });
      setLeaderRefillRun({runId:request.runId,leaderRevision:request.leaderRevision,reason});
      setLeaderRefillStatus({tone:"info",title:"Generator otrzymał zadanie",detail:"Oczekuję na wynik. Przycisk pozostanie zablokowany, aby nie uruchomić drugiego uzupełnienia tego samego szkicu."});
      setMessage("Generator uzupełnia wyłącznie wolne miejsca. Wszystkie obecne przydziały lidera są zablokowane i pozostaną bez zmian.");
    }catch(error){const detail=solverErrorMessage(errorText(error));setLeaderRefillStatus({tone:"danger",title:"Nie udało się uruchomić uzupełnienia",detail});setMessage(detail);}
    finally{setLeaderRefillSubmitting(false);setBusy(false);}
  }

  useEffect(()=>{
    if(!supabase||!leaderRefillRun||!leaderVariant)return;
    let cancelled=false;
    let timer:ReturnType<typeof setTimeout>|null=null;
    const poll=async()=>{
      try{
        const status=await getSolverStatus(supabase,leaderRefillRun.runId);
        if(cancelled)return;
        if(status.run.status==="READY"){
          if(leaderRefillApplyingRef.current)return;
          leaderRefillApplyingRef.current=true;
          setLeaderRefillStatus({tone:"info",title:"Sprawdzam gotowy wynik",detail:"Generator zakończył obliczenia. Wybieram poprawny wariant i dopisuję tylko obsadzone wakaty."});
          const result=await getSolverVariants(supabase,leaderRefillRun.runId);
          const source=result.variants.find(item=>item.recommended&&item.hardViolations===0)
            ?? result.variants.find(item=>item.hardViolations===0);
          if(!source)throw new Error("LEADER_REFILL_NO_VALID_VARIANT");
          const applied=await applyLeaderRefill(supabase,{
            leaderVariantId:leaderVariant.id,sourceVariantId:source.id,reason:leaderRefillRun.reason,
          });
          if(cancelled)return;
          const added=Number(applied.addedAssignments??0);
          setLeaderRefillRun(null);setLeaderRefillReason("");
          await reloadLeaderWorkspace();
          setLeaderRefillStatus({tone:"success",title:`Uzupełniono ${added} ${added===1?"miejsce":"miejsc"}`,detail:"Wcześniejsze przydziały lidera pozostały bez zmian, a cały miesiąc został ponownie sprawdzony."});
          setMessage(`Uzupełniono ${added} wolnych ${added===1?"miejsce":"miejsc"}. Wcześniejsze przydziały lidera pozostały bez zmian; cały miesiąc został ponownie sprawdzony.`);
          return;
        }
        if(["FAILED","CANCELLED","STALE_INPUT"].includes(status.run.status)){
          setLeaderRefillRun(null);
          setLeaderRefillStatus({tone:"danger",title:"Automatyczne uzupełnienie nie zostało zastosowane",detail:`Zadanie zakończyło się statusem ${solverStatusLabel(status.run.status)}. Wersja lidera pozostała bez zmian.`});
          setMessage(`Nie zastosowano automatycznego uzupełnienia. Zadanie zakończyło się statusem ${solverStatusLabel(status.run.status)}; wersja lidera pozostała bez zmian.`);
          return;
        }
        setLeaderRefillStatus({tone:"info",title:"Generator pracuje",detail:`${solverPhaseLabel(status.run.phase)} • ${Math.max(0,Math.min(100,status.run.progress??0))}%`});
        timer=setTimeout(poll,3000);
      }catch(error){
        if(cancelled)return;
        const detail=solverErrorMessage(errorText(error));
        setLeaderRefillRun(null);setLeaderRefillStatus({tone:"danger",title:"Nie udało się dokończyć uzupełnienia",detail});setMessage(detail);
      }finally{leaderRefillApplyingRef.current=false;}
    };
    void poll();
    return()=>{cancelled=true;if(timer)clearTimeout(timer);};
  },[supabase,leaderRefillRun?.runId,leaderVariant?.id]);

  async function startLeaderOptimization(){
    if(!supabase||!leaderVariant||leaderWorkflow!=="DRAFT")return;
    const reason=leaderOptimizationReason.trim();
    if(reason.length<3){setMessage("Podaj krótki cel przeliczenia — zostanie zapisany w audycie.");return;}
    setBusy(true);setMessage("");setLeaderOptimizationProposal(null);
    setLeaderOptimizationStatus({tone:"info",title:"Przygotowuję bezpieczne przeliczenie",detail:"Przypięte decyzje pozostaną bez zmian. Generator otrzyma tylko niezablokowany zakres szkicu."});
    try{
      const request=await requestLeaderReoptimization(supabase,{
        variantId:leaderVariant.id,mode:leaderOptimizationMode,reason,
        idempotencyKey:createIdempotencyKey(context,`leader-${leaderOptimizationMode.toLowerCase()}-r${leaderVariant.revision}`),
      });
      setLeaderOptimizationRun({runId:request.runId,leaderRevision:request.leaderRevision,mode:request.mode,reason});
      setLeaderOptimizationStatus({tone:"info",title:"Generator otrzymał zadanie",detail:`Zachowano ${request.lockedAssignments} przypiętych decyzji. Wersja lidera nie zmieni się przed zakończeniem obliczeń.`});
    }catch(error){const detail=solverErrorMessage(errorText(error));setLeaderOptimizationStatus({tone:"danger",title:"Nie udało się uruchomić przeliczenia",detail});setMessage(detail);}
    finally{setBusy(false);}
  }

  async function cancelLeaderOptimization(){
    if(!supabase||!leaderOptimizationRun)return;
    setBusy(true);
    try{
      await requestSolverCancellation(supabase,leaderOptimizationRun.runId);
      setLeaderOptimizationStatus({tone:"info",title:"Zatrzymuję przeliczenie",detail:"Wysłano bezpieczne zatrzymanie. Wersja lidera pozostaje bez zmian; status zadania zostanie odświeżony automatycznie."});
    }catch(error){const detail=solverErrorMessage(errorText(error));setLeaderOptimizationStatus({tone:"danger",title:"Nie udało się zatrzymać przeliczenia",detail});setMessage(detail);}
    finally{setBusy(false);}
  }

  useEffect(()=>{
    if(!supabase||!leaderOptimizationRun||!leaderVariant)return;
    let cancelled=false;let timer:ReturnType<typeof setTimeout>|null=null;
    const poll=async()=>{
      try{
        const status=await getSolverStatus(supabase,leaderOptimizationRun.runId);
        if(cancelled)return;
        if(status.run.status==="READY"){
          if(leaderOptimizationApplyingRef.current)return;
          leaderOptimizationApplyingRef.current=true;
          const result=await getSolverVariants(supabase,leaderOptimizationRun.runId);
          const source=leaderOptimizationSource(result.variants,leaderOptimizationRun.mode);
          if(!source)throw new Error("LEADER_OPTIMIZATION_NO_VALID_VARIANT");
          if(leaderOptimizationRun.mode==="PROPOSE_ONLY"){
            const workspace=await getVariantWorkspace(supabase,source.id);
            if(cancelled)return;
            setLeaderOptimizationProposal({sourceVariantId:source.id,workspace,
              leaderRevision:leaderOptimizationRun.leaderRevision,reason:leaderOptimizationRun.reason});
            setLeaderOptimizationRun(null);
            setLeaderOptimizationStatus({tone:"success",title:"Propozycja jest gotowa",detail:"Szkic nie został zmieniony. Możesz otworzyć porównanie, zastosować propozycję albo ją odrzucić."});
            return;
          }
          setLeaderOptimizationStatus({tone:"info",title:"Wynik jest gotowy",detail:"Sprawdzam rewizję szkicu i zastępuję wyłącznie niezablokowane przydziały."});
          const applied=await applyLeaderReoptimization(supabase,{leaderVariantId:leaderVariant.id,
            sourceVariantId:source.id,reason:leaderOptimizationRun.reason});
          if(cancelled)return;
          const replaced=Number(applied.replacedAssignments??0);
          setLeaderOptimizationRun(null);setLeaderOptimizationReason("");
          await reloadLeaderWorkspace();
          setLeaderOptimizationStatus({tone:"success",title:"Przeliczenie zastosowane",detail:`Zapisano ${replaced} niezablokowanych przydziałów. Przypięte decyzje pozostały bez zmian.`});
          return;
        }
        if(["FAILED","CANCELLED","STALE_INPUT"].includes(status.run.status)){
          setLeaderOptimizationRun(null);
          setLeaderOptimizationStatus({tone:"danger",title:"Przeliczenie nie zostało zastosowane",detail:`Zadanie zakończyło się statusem ${solverStatusLabel(status.run.status)}. Szkic pozostał bez zmian.`});
          return;
        }
        setLeaderOptimizationStatus({tone:"info",title:"Generator pracuje",detail:`${solverPhaseLabel(status.run.phase)} • ${Math.max(0,Math.min(100,status.run.progress??0))}%`});
        timer=setTimeout(poll,3000);
      }catch(error){
        if(cancelled)return;
        const detail=solverErrorMessage(errorText(error));setLeaderOptimizationRun(null);
        setLeaderOptimizationStatus({tone:"danger",title:"Nie udało się dokończyć przeliczenia",detail});setMessage(detail);
      }finally{leaderOptimizationApplyingRef.current=false;}
    };
    void poll();return()=>{cancelled=true;if(timer)clearTimeout(timer);};
  },[supabase,leaderOptimizationRun?.runId,leaderVariant?.id]);

  async function applyLeaderOptimizationProposal(){
    if(!supabase||!leaderVariant||!leaderOptimizationProposal)return;
    setBusy(true);setMessage("");
    try{
      const applied=await applyLeaderReoptimization(supabase,{leaderVariantId:leaderVariant.id,
        sourceVariantId:leaderOptimizationProposal.sourceVariantId,reason:leaderOptimizationProposal.reason});
      const replaced=Number(applied.replacedAssignments??0);
      setLeaderOptimizationProposal(null);setLeaderOptimizationReason("");
      await reloadLeaderWorkspace();
      setLeaderOptimizationStatus({tone:"success",title:"Propozycja zastosowana",detail:`Zapisano ${replaced} niezablokowanych przydziałów. Przypięte decyzje pozostały bez zmian.`});
    }catch(error){const detail=solverErrorMessage(errorText(error));setLeaderOptimizationStatus({tone:"danger",title:"Nie udało się zastosować propozycji",detail});setMessage(detail);}
    finally{setBusy(false);}
  }

  async function moveLeaderRevision(direction:"UNDO"|"REDO"){
    if(!supabase||!leaderVariant)return;
    setBusy(true);setMessage("");
    try{
      await moveLeaderHistory(supabase,leaderVariant.id,direction);
      await reloadLeaderWorkspace();
      setMessage(direction==="UNDO"?"Cofnięto ostatnią zmianę. Cały grafik został ponownie sprawdzony.":"Ponowiono zmianę. Cały grafik został ponownie sprawdzony.");
    }catch(error){setMessage(solverErrorMessage(errorText(error)));}
    finally{setBusy(false);}
  }

  async function saveLeaderCheckpoint(){
    if(!supabase||!leaderVariant)return;
    const checkpointName=leaderCheckpointName.trim();
    if(checkpointName.length<3){setMessage("Nadaj punktowi kontrolnemu nazwę mającą co najmniej 3 znaki.");return;}
    setBusy(true);setMessage("");
    try{
      await createLeaderCheckpoint(supabase,leaderVariant.id,checkpointName);
      await reloadLeaderWorkspace();
      setLeaderCheckpointName("");
      setMessage(`Zapisano punkt kontrolny „${checkpointName}”. Możesz do niego wrócić bez publikowania grafiku.`);
    }catch(error){setMessage(solverErrorMessage(errorText(error)));}
    finally{setBusy(false);}
  }

  async function restoreSelectedLeaderCheckpoint(){
    if(!supabase||!leaderVariant||leaderCheckpointRestoreSeq===null)return;
    const reason=leaderCheckpointRestoreReason.trim();
    if(reason.length<3){setMessage("Podaj krótki powód przywrócenia punktu kontrolnego — zostanie zapisany w audycie.");return;}
    setBusy(true);setMessage("");
    try{
      await restoreLeaderCheckpoint(supabase,{variantId:leaderVariant.id,historySeq:leaderCheckpointRestoreSeq,reason});
      await reloadLeaderWorkspace();
      setLeaderCheckpointRestoreSeq(null);setLeaderCheckpointRestoreReason("");
      setMessage("Przywrócono wybrany punkt kontrolny. To nadal wersja robocza; pracownicy nie widzą zmian.");
    }catch(error){setMessage(solverErrorMessage(errorText(error)));}
    finally{setBusy(false);}
  }

  async function moveLeaderWorkflow(targetStatus:SolverLeaderWorkflowStatus){
    if(!supabase||!leaderVariant)return;
    const labels:Record<SolverLeaderWorkflowStatus,string>={DRAFT:"wersji roboczej",REVIEW:"sprawdzenia",LEADER_APPROVED:"zatwierdzenia lidera",READY_TO_MERGE:"gotowości do scalenia",PUBLISHED:"publikacji"};
    const reason=leaderWorkflowReason.trim();
    if(reason.length<3){setMessage("Podaj krótki powód zmiany etapu — zostanie zapisany w audycie.");return;}
    setBusy(true);setMessage("");
    try{
      await transitionLeaderWorkflow(supabase,{variantId:leaderVariant.id,targetStatus,reason});
      setLeaderWorkflow(targetStatus);setPendingLeaderWorkflow(null);setLeaderWorkflowReason("");setMessage(`Status Studia zmieniono na: ${labels[targetStatus]}.`);
    }catch(error){setMessage(solverErrorMessage(errorText(error)));}
    finally{setBusy(false);}
  }

  async function inspectVariant(variant: SolverVariant) {
    if (!supabase) return;
    setBusy(true);
    setInspectingVariantId(variant.id);
    setMessage("");
    try {
      setInspectedWorkspace(await getVariantWorkspace(supabase, variant.id));
    } catch (error) {
      setMessage(solverErrorMessage(error instanceof Error ? error.message : String(error)));
    } finally {
      setBusy(false);
      setInspectingVariantId(null);
    }
  }

  async function executeCompanyPublication(warningReason:string|null,roleReplacementReason:string|null) {
    if (!supabase || !run || !selectedVariant || engine === "SHADOW" || scopeType !== "COMPANY") return;
    const trimmedName=publicationName.trim();
    setBusy(true);setMessage("");
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
        roleReplacementReason,
      });
      rememberPublishedSchedule(context, publication.scheduleId);
      window.localStorage.removeItem(attemptKey);
      setVariants(current => current.map(variant => variant.id === selectedVariant.id
        ? { ...variant, status: "PUBLISHED" }
        : variant));
      setLeaderVariant(current=>current&&current.id===selectedVariant.id?{...current,status:"PUBLISHED"}:current);
      try {
        const workspace = await getPublishedSchedule(supabase, publication.scheduleId);
        setPublishedWorkspace(workspace);
        setMessage(publication.reused
          ? "Ten sam grafik był już opublikowany. Przywrócono jego aktualny podgląd."
          : `Grafik został opublikowany. Zmieniono przydziały ${publication.changed??0} osób i wysłano ${publication.notified??0} powiadomień.`);
      } catch {
        setMessage("Grafik został opublikowany, ale nie udało się odświeżyć jego podglądu. Użyj przycisku „Odśwież”.");
      }
      try {
        await onPublished?.(publication.scheduleId);
      } catch {
        setMessage("Grafik został opublikowany, ale główny widok nie odświeżył się automatycznie. Użyj przycisku „Odśwież”.");
      }
      setPendingCompanyPublication(null);
      setPublicationWarningReason("");
      setPublicationReplacementReason("");
    } catch (error) {
      setMessage(solverErrorMessage(error instanceof Error ? error.message : String(error)));
    } finally {
      setBusy(false);
    }
  }

  async function publishSelected() {
    if (!supabase || !run || !selectedVariant || engine === "SHADOW" || scopeType !== "COMPANY") return;
    const trimmedName = publicationName.trim();
    if (!trimmedName) {setMessage("Nie udało się opublikować grafiku. Podaj jego nazwę.");return;}
    setBusy(true);setMessage("");setPendingCompanyPublication(null);
    try{
      const [readiness,authority]=await Promise.all([
        getPublicationReadiness(supabase,run.id,selectedVariant.id,trimmedName),
        getPublicationAuthorityStatus(supabase,month),
      ]);
      setPublicationReadiness(readiness);
      if(!readiness.ready){setMessage("Nie można opublikować grafiku. Szczegółowe blokady są widoczne poniżej.");return;}
      const warningCount=readiness.warnings.unfilledCount;
      const roleReplacementCount=authority.roles.length;
      if(warningCount>0||roleReplacementCount>0){
        setPendingCompanyPublication({warningCount,roleReplacementCount});
        setMessage("Kontrola zakończona. Przejrzyj skutki publikacji i podaj wymagane uzasadnienia.");
        return;
      }
    }catch(error){setMessage(solverErrorMessage(errorText(error)));return;}
    finally{setBusy(false);}
    await executeCompanyPublication(null,null);
  }

  async function confirmCompanyPublication(){
    if(!pendingCompanyPublication)return;
    const warningReason=pendingCompanyPublication.warningCount>0?publicationWarningReason.trim():null;
    const replacementReason=pendingCompanyPublication.roleReplacementCount>0?publicationReplacementReason.trim():null;
    if(pendingCompanyPublication.warningCount>0&&(!warningReason||warningReason.length<3)){setMessage("Podaj powód publikacji mimo braków obsady.");return;}
    if(pendingCompanyPublication.roleReplacementCount>0&&(!replacementReason||replacementReason.length<5)){setMessage("Podaj powód zastąpienia opublikowanych grafików zespołów.");return;}
    await executeCompanyPublication(warningReason,replacementReason);
  }

  async function publishSelectedRole() {
    if (!supabase || !run || !selectedVariant || engine === "SHADOW" || scopeType !== "ROLE") return;
    if (!leaderPublicationReady) {
      setMessage("Wersja lidera nie jest jeszcze gotowa do publikacji. W Studio wybierz „Sprawdź cały grafik”, przejdź przez zatwierdzenie lidera i oznacz wersję jako gotową do scalenia.");
      return;
    }
    const trimmedName = publicationName.trim();
    if (!trimmedName) {
      setMessage("Nie udało się opublikować grafiku zespołu. Podaj jego nazwę.");
      return;
    }
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
      setLeaderVariant(current=>current&&current.id===selectedVariant.id?{...current,status:"PUBLISHED"}:current);
      if(leaderVariant?.id===selectedVariant.id)setLeaderWorkflow("PUBLISHED");
      await onVariantSelected?.({ ...selectedVariant, status: "PUBLISHED" });
      setMessage(publication.reused
        ? "Ten grafik zespołu był już opublikowany. Nie wysłano podwójnych powiadomień."
        : `Grafik zespołu został opublikowany. Zmieniono przydziały ${publication.changed} osób i powiadomiono ${publication.notified} pracowników z połączonym kontem.`);
    } catch (error) {
      setMessage(solverErrorMessage(error instanceof Error ? error.message : String(error)));
    } finally {
      setBusy(false);
    }
  }

  function startAnother() {
    forgetSolverRun(context);
    setPollingRunId(null);
    setMemoryPromptOpen(false);
    setMemoryGameOpen(false);
    setRun(null);
    setStrategies([]);
    setVariants([]);
    setSelectedWorkspace(null);
    setLeaderBaselineWorkspace(null);
    setLeaderWorkspaceBusy(false);
    setLeaderDraftValidation(null);
    setLeaderVariant(null);
    setLeaderStudioOpen(false);
    setPendingLeaderWorkflow(null);
    setLeaderWorkflowReason("");
    setInspectedWorkspace(null);
    setPublicationReadiness(null);
    setMessage("");
  }

  const viewGeneratedSchedule=()=>{
    setMemoryGameOpen(false);
    window.requestAnimationFrame(()=>document.getElementById("solver-v2-results")?.scrollIntoView({behavior:"smooth",block:"start"}));
  };

  const publicationChangePanel=selectedVariant&&selectedVariant.status!=="PUBLISHED"&&leaderPublicationReady
    ?<section className="solver-publication-changes" aria-label="Różnice i powiadomienia przed publikacją">
      <header><Users/><span><strong>Osoby objęte publikacją</strong><small>{publicationChanges?.baselineFound?"Porównanie z obecnie obowiązującym grafikiem.":"Pierwsza publikacja — wszyscy przydzieleni pracownicy są traktowani jako objęci zmianą."}</small></span></header>
      {publicationChangesBusy?<p>Wyliczam różnice i zakres powiadomień…</p>:publicationChanges?<>
        <div className="solver-publication-change-totals"><span><small>Zmienione osoby</small><b>{publicationChanges.changedCount}</b></span><span><small>Otrzymają powiadomienie</small><b>{publicationChanges.notificationCount}</b></span></div>
        {publicationChanges.people.length>0?<div className="solver-publication-change-people">{publicationChanges.people.slice(0,8).map(person=><span key={person.employeeId}><b>{person.name}</b><small>{person.employeeNo} • {person.changeType==="ADDED"?"dodane przydziały":person.changeType==="REMOVED"?"usunięte przydziały":"zmienione przydziały"} • {person.beforeAssignmentCount} → {person.afterAssignmentCount}{person.willNotify?" • powiadomienie":" • brak połączonego konta"}</small></span>)}{publicationChanges.people.length>8&&<em>oraz {publicationChanges.people.length-8} kolejnych osób</em>}</div>:<p>Grafik nie różni się od obowiązującej wersji. Publikacja nie wyśle powiadomień pracownikom.</p>}
      </>:<div className="solver-v2-notice warning"><AlertTriangle/><span><strong>Nie udało się wyliczyć zakresu publikacji</strong><small>Publikacja pozostaje zablokowana, aby nie wysłać niekontrolowanych powiadomień.</small></span><button type="button" className="secondary-button" onClick={()=>setPublicationChangesRetry(value=>value+1)}>Spróbuj ponownie</button></div>}
    </section>:null;

  return <div className="solver-v2-panel">
    <div className="solver-v2-heading">
      <span className="solver-v2-icon"><Sparkles/></span>
      <span>
        <strong>{engine === "SHADOW" ? "Nieprodukcyjny test nowego silnika" : "Optymalizacja całej konfiguracji firmy"}</strong>
        <small>{scopeLabel} • warianty pokazują różne priorytety biznesowe</small>
      </span>
      {engine === "SHADOW" && <em>TRYB CIENIA</em>}
    </div>

    <div className="solver-v2-notice matrix-source-notice"><AlertTriangle/><span><strong>Źródło danych: opublikowana konfiguracja firmy{matrixEffectiveFrom?` obowiązująca od ${matrixEffectiveFrom}`:""}</strong><small>Zmiany robocze nie trafiają do silnika. Nowa rola, pracownik, stawka lub reguła zostanie użyta dopiero po opublikowaniu konfiguracji właściwej dla tego miesiąca.</small></span></div>
    {draftConfigurationVersion&&activeConfigurationVersion&&draftConfigurationVersion>activeConfigurationVersion&&<div className="solver-v2-notice warning"><AlertTriangle/><span><strong>Masz nowszą wersję roboczą: v{draftConfigurationVersion}; generator nadal używa opublikowanej v{activeConfigurationVersion}</strong><small>Elementy dodane tylko w wersji roboczej — na przykład zmiana „Runner Help” — nie pojawią się w wyniku. Przed nowym generowaniem przejdź do konfiguracji firmy, usuń wskazane blokady i opublikuj wersję roboczą.</small></span></div>}

    {recovering && <div className="solver-v2-notice"><RefreshCw className="spin"/>Odzyskuję rozpoczęte wcześniej generowanie…</div>}
    {!run && !recovering && !allowStart && <div className="solver-v2-notice"><Sparkles/>Uruchamianie nowego silnika jest wyłączone w bieżącej konfiguracji.</div>}
    {!run && !recovering && allowStart && <div className="solver-v2-form">
      <label>Nazwa
        <input value={name} onChange={event => onNameChange(event.target.value)}/>
      </label>
      <label>Profil zapotrzebowania
        <select value={scenarioCode} onChange={event => onScenarioChange(event.target.value)}>
          {scenarios.map(scenario => <option value={scenario.code} key={scenario.id ?? scenario.code}>
            {scenario.name}{scenario.profileMode==="PERIOD"&&scenario.validFrom?` • od ${scenario.validFrom}${scenario.validTo?` do ${scenario.validTo}`:""}`:""}{scenario.strategyCount ? ` • ${variantCountLabel(scenario.strategyCount)}` : ""}
          </option>)}
        </select>
      </label>
      {selectedScenario?.description && <p>{selectedScenario.description}</p>}
      <div className="solver-v2-notice"><CalendarDays/><span><strong>Wydarzenia i zwiększona obsada dotyczą konkretnych dni</strong><small>Profil obejmuje bazę miesiąca albo jawny okres sezonowy. Koncert, wysoki ruch w weekend lub wyjątkową zmianę dodaj w Kalendarzu operacyjnym — system doliczy obsadę tylko we wskazanych datach, lokalach, rolach i zmianach.</small></span></div>
      {!selectedScenario?.id && <div className="solver-v2-notice warning"><AlertTriangle/>Konfiguracja firmy nie jest jeszcze gotowa do generowania.</div>}
      {selectedScenario?.id && selectedScenario.strategyCount===0 && <div className="solver-v2-notice warning"><AlertTriangle/>Ten profil zapotrzebowania nie ma jeszcze wariantu biznesowego. Dodaj co najmniej jeden w konfiguracji firmy.</div>}
      <button className="primary-button full" disabled={busy || !expectedSolverVersion || !selectedScenario?.id || selectedScenario.strategyCount===0 || !name.trim()} onClick={() => void start()}>
        {busy ? <><RefreshCw className="spin"/> Uruchamiam…</> : <><Sparkles/> Generuj wszystkie aktywne warianty</>}
      </button>
    </div>}

    {canOpenManualStudio&&(run?.status!=="READY"||leaderStudioSourceVariants.length===0)&&<section className="solver-manual-studio-entry"><span><Edit3/></span><div><strong>Studio lidera — ułóż grafik bez generatora</strong><small>Możesz rozpocząć od pustej obsady także po zakończonym lub nieudanym generowaniu. Internet oraz backend są nadal potrzebne; pomijamy wyłącznie automatyczne generowanie.</small></div><button type="button" className="secondary-button" disabled={busy||!selectedScenario?.id||!expectedSolverVersion||!name.trim()} onClick={()=>void createManualStudio()}>{busy?<RefreshCw className="spin"/>:<Edit3/>} Otwórz Studio</button></section>}

    {run && <div className="solver-v2-run">
      <div className="solver-v2-run-head">
        <span>
          <small>{solverPhaseLabel(run.phase)}</small>
          <strong>{solverStatusLabel(run.status)}</strong>
        </span>
        <b>{run.progress}%</b>
      </div>
      <div className="solver-v2-progress"><i style={{ width: `${run.progress}%` }}/></div>
      {memoryPromptOpen&&!isSolverRunTerminal(run.status)&&<aside className="generator-memory-prompt" aria-label="Jednorazowa propozycja Memory"><span><Cat/></span><span><h4>pss, zagramy?</h4><p>Jeszcze chwilę mielę grafik. Memory?</p></span><div className="generator-memory-prompt-actions"><button type="button" className="primary-button" onClick={()=>{setMemoryPromptOpen(false);setMemoryGameOpen(true);}}>GRAJ</button><button type="button" className="secondary-button" onClick={()=>setMemoryPromptOpen(false)}>NIE, PATRZĘ JAK MIELISZ</button></div></aside>}
      {strategies.length > 0 && <div className="solver-v2-strategies">
        {strategies.map(strategy => <div key={strategy.id}>
          <span><strong>{strategy.name}</strong><small>{solverStatusLabel(strategy.status)}</small></span>
          <em>{strategy.progress}%</em>
        </div>)}
      </div>}
      {run.failureMessage && run.status!=="FAILED" && <div className="solver-v2-notice warning"><AlertTriangle/>{solverErrorMessage(run.failureMessage)}</div>}
      {run.status==="QUEUED"&&run.phase!=="RETRY_QUEUED"&&<div className="solver-v2-run-state queued"><RefreshCw className="spin"/><span><strong>{run.queuePosition&&run.queuePosition>1?polishQueuedTaskSentence(run.queuePosition-1):`To zadanie jest pierwsze w kolejce`}</strong><small>Zlecenie jest zapisane i nie trzeba klikać ponownie. Oczekiwanie: {elapsedLabel(run.waitingSeconds)}. Obliczenia uruchomią się automatycznie po zwolnieniu workera.</small></span></div>}
      {run.status==="RUNNING"&&<div className="solver-v2-run-state running"><RefreshCw className="spin"/><span><strong>Worker układa teraz ten grafik</strong><small>Czas obliczeń: {elapsedLabel(run.runningSeconds)}. Postęp i strategie są odświeżane automatycznie.</small></span></div>}
      {run.status==="QUEUED"&&run.phase==="RETRY_QUEUED"&&<div className="solver-v2-run-state retry"><RefreshCw/><span><strong>Poprzednia próba została bezpiecznie zakończona</strong><small>Zadanie oczekuje w kolejce na automatyczne ponowienie. „Odśwież” tylko sprawdza stan — nie tworzy kolejnej kopii zadania.</small></span></div>}
      {run.status==="FAILED"&&<div className="solver-v2-run-state failed"><AlertTriangle/><span><strong>Ten przebieg zakończył się błędem</strong><small>{run.failureMessage?solverErrorMessage(run.failureMessage):"Nie zapisano technicznej przyczyny awarii."} „Odśwież” sprawdza zapisany stan. „Spróbuj ponownie” tworzy nowe, osobne generowanie z aktualnymi danymi.</small></span></div>}
      {run.status==="STALE_INPUT"&&<div className="solver-v2-run-state failed"><AlertTriangle/><span><strong>Dane zmieniły się w czasie obliczeń</strong><small>Uruchom nowe generowanie, aby policzyć grafik na aktualnej, spójnej konfiguracji firmy.</small></span></div>}
      {pollWarning && <div className="solver-v2-poll-warning">{pollWarning}</div>}
      <div className="solver-v2-actions">
        {active && <button className="secondary-button" disabled={busy || run.status === "CANCEL_REQUESTED"} onClick={() => void cancel()}><Square/> Zatrzymaj bezpiecznie</button>}
        <button className="secondary-button" disabled={busy||refreshing} onClick={() => void refreshStatus(run.id)}><RefreshCw className={refreshing?"spin":""}/> {refreshing?"Sprawdzam…":"Odśwież status"}</button>
        {lastStatusCheck&&<small className="solver-v2-last-check">Ostatnie ręczne sprawdzenie: {lastStatusCheck}</small>}
        {run.status==="FAILED"&&<button type="button" className="primary-button" onClick={onOpenReadiness}>Przejdź do kontroli gotowości</button>}
        {isSolverRunTerminal(run.status) && <button className="secondary-button" disabled={busy} onClick={startAnother}>{["FAILED","STALE_INPUT"].includes(run.status)?"Spróbuj ponownie":"Nowe generowanie"}</button>}
      </div>
    </div>}

    {run&&memoryGameOpen&&<LazyGeneratorMemoryExperience status={run.status} onClose={()=>setMemoryGameOpen(false)} onViewSchedule={viewGeneratedSchedule}/>}

    {variants.length > 0 && <div className="solver-v2-results" id="solver-v2-results">
      <div className="solver-v2-results-head">
        <span><strong>{run?.status==="READY"?"Porównaj gotowe warianty":"Zapisane warianty diagnostyczne"}</strong><small>{run?.status==="READY"?"Każdy wariant stosuje inny zestaw priorytetów: koszt, preferencje i równy podział pracy.":"Nie można ich wybrać ani opublikować, ale pozostają widoczne, aby wskazać dokładnie, na którym wariancie zakończyła się finalizacja."}</small></span>
      </div>
      <div className="solver-v2-notice"><Check/><span><strong>{MANDATORY_PRODUCT_GUARDS_LABEL}</strong><small>{MANDATORY_PRODUCT_GUARDS_DESCRIPTION}</small></span></div>
      {variants.some(variant=>variant.solverStatus!=="OPTIMAL")&&<div className="solver-v2-notice warning"><AlertTriangle/><span><strong>Co najmniej jeden wariant nie ma dowodu matematycznego optimum</strong><small>Wynik przestrzega twardych reguł i jest najlepszym znalezionym w limicie obliczeń, ale może istnieć lepszy układ. To normalny wynik planowania. Oddzielny „Tryb audytowy” może wymagać formalnego dowodu, lecz przy dużym grafiku potrafi zakończyć przebieg bez zapisu poprawnego wariantu.</small></span></div>}
      {variants.some(variant=>Number(variant.metrics.LOAD_UTILIZATION_TARGET_COUNT??0)<2)&&<div className="solver-v2-notice warning"><AlertTriangle/><span><strong>Ten zapisany przebieg nie porównywał obciążenia pracowników</strong><small>Wynik powstał w starszej wersji silnika, w której osoby z umowami elastycznymi mogły wypaść z celu równego podziału. Wygeneruj nowe warianty — obecna wersja uwzględnia je przez wspólną bazę sprawiedliwości.</small></span></div>}
      {allVariantsEquivalent && <div className="solver-v2-notice"><Check/><span><strong>Strategie zwróciły ten sam skład grafiku</strong><small>Przy obecnej obsadzie i twardych regułach silnik nie znalazł alternatywnego składu, który zmieniałby koszt, preferencje lub równy podział. Różne strategie nie tworzą sztucznie innych przydziałów.</small></span></div>}
      <div className="solver-v2-grid">
        {variants.map(variant => {const chosenAsSource=variant.selected||leaderVariant?.sourceVariantId===variant.id;const description=strategyDescription(variant.strategy);return <article className={`${variant.recommended ? "recommended" : ""} ${chosenAsSource ? "selected" : ""}`} key={variant.id}>
          <div className="solver-v2-card-head">
            <span><small>STRATEGIA</small><h3>{variant.strategy.name}</h3></span>
            {variant.recommended && <em>{variant.solverStatus==="OPTIMAL"?"REKOMENDOWANY":"NAJLEPSZY ZNALEZIONY"}</em>}
            {chosenAsSource && <em className="chosen"><Check/> {leaderVariant?"BAZA WERSJI LIDERA":"WYBRANY"}</em>}
          </div>
          {description && <p>{description}</p>}
          <div className="solver-v2-metrics">
            <span><Users/><small>Przydziały</small><strong>{variant.assignmentCount}</strong></span>
            <span><AlertTriangle/><small>Braki</small><strong>{variant.unfilledCount}</strong></span>
            {variant.totalCostMinor !== undefined && variant.totalCostMinor !== null
              && <span><CircleDollarSign/><small>Koszt</small><strong>{money(variant.totalCostMinor, variant.currency)}</strong></span>}
          </div>
          <div className="solver-v2-coverage-detail"><span><small>Pokrycie wymaganej obsady</small><strong>{variant.assignmentCount + variant.unfilledCount > 0 ? `${Math.round(variant.assignmentCount / (variant.assignmentCount + variant.unfilledCount) * 1000) / 10}%` : "100%"}</strong></span><span><small>Koszt jednego przydziału</small><strong>{variant.totalCostMinor != null && variant.assignmentCount ? money(Math.round(variant.totalCostMinor / variant.assignmentCount), variant.currency) : "—"}</strong></span></div>
          <details className="solver-v2-technical-metrics">
            <summary><span>Jak silnik ocenił ten wariant?</span><small>Techniczne wskaźniki i wyjaśnienia</small></summary>
            <dl className="solver-v2-analysis">
              {presentSolverVariantMetrics(variant.metrics).map(metric=><div key={metric.code}><dt>{metric.label}<small>{metric.explanation}</small></dt><dd>{metric.value}</dd></div>)}
              {variant.budgetMinor!==undefined&&variant.budgetMinor!==null&&<div><dt>Budżet<small>Limit kosztu zapisany dla wybranego wariantu biznesowego.</small></dt><dd>{money(variant.budgetMinor,variant.currency)}</dd></div>}
              {variant.stageProof.length>0&&<div><dt>Dowód etapów optymalizacji<small>Status, wynik, zamrożona granica, tolerancja, budżet, czas i użycie fallbacku są zapisane dla każdego etapu.</small></dt><dd>{solverStageProofLabel(variant)}</dd></div>}
              {variant.versionStamp&&<div><dt>Stamp wersji przebiegu<small>Wersje komponentów i konfiguracji, na których dokładnie powstał ten wariant.</small></dt><dd>{solverVersionStampLabel(variant)}</dd></div>}
            </dl>
          </details>
          {variant.strategy.name.toLocaleLowerCase("pl-PL").includes("równ")&&Number(variant.metrics.LOAD_UTILIZATION_SPREAD_BPS??0)>1000&&<div className="solver-v2-notice warning"><AlertTriangle/><span><strong>Podział godzin nadal wymaga decyzji lidera</strong><small>Różnica wykorzystania indywidualnych wymiarów przekracza 100 punktów procentowych. Nie jest to procent różnicy godzin min–max. Otwórz „Rozkład pracy”, aby sprawdzić godziny, wymiary, dostępność i decyzje generatora dla każdej osoby.</small></span></div>}
          <div className={`solver-v2-validation ${variant.unfilledCount>0||variant.hardViolations>0?"warning":""}`}>
            {variant.unfilledCount>0||variant.hardViolations>0?<AlertTriangle/>:<Check/>}<span><strong>{variant.hardViolations>0?"Wariant zawiera niedozwolone przydziały":variant.unfilledCount>0?`Technicznie poprawny, ale niekompletny: ${variant.unfilledCount} nieobsadzonych miejsc`:"Kompletny grafik bez naruszeń"}</strong><small>{variant.unfilledCount>0?`Silnik nie złamał reguł pracownika — pozostawił wakaty zamiast wykonać niedozwolony przydział. ${solutionLabel(variant.solverStatus)}.`:solutionLabel(variant.solverStatus)}</small></span>
          </div>
          {variant.equivalentToVariantId && <small className="solver-v2-equivalent">Ten wariant ma taki sam skład jak inny wynik.</small>}
          {!variant.equivalentToVariantId && (aggregateVariantCounts.get(aggregateVariantFingerprint(variant)) ?? 0) > 1 && <small className="solver-v2-equivalent">Te same wskaźniki zbiorcze, ale inny skład pracowników. Otwórz szczegóły, aby porównać przydziały.</small>}
          <button className="secondary-button full" disabled={busy} onClick={() => void inspectVariant(variant)}>{inspectingVariantId===variant.id?<RefreshCw className="spin"/>:<Search/>} {inspectingVariantId===variant.id?"Otwieram szczegóły…":"Pokaż grafik i przyczyny braków"}</button>
          {engine === "SHADOW"
            ? <button className="secondary-button full" disabled>Wynik testowy — bez publikacji</button>
            : <button className="primary-button full" disabled={busy || run?.status!=="READY" || chosenAsSource || variant.hardViolations > 0} onClick={() => void choose(variant)}>
              {chosenAsSource ? <><Check/> {leaderVariant?"Użyty jako baza":"Wybrano ten wariant"}</> : "Wybierz jako bazę"}
            </button>}
        </article>})}
      </div>
    </div>}

    {engine==="ORTOOLS_V2"&&run?.status==="READY"&&!leaderVariant&&leaderStudioSourceVariants.length>0&&<section className="solver-studio-start-options">
      <header><span><Edit3/></span><div><small>STUDIO LIDERA • PUNKT STARTOWY</small><h3>Wybierz bazę roboczego grafiku</h3><p>Każda opcja tworzy osobny szkic. Warianty generatora pozostają bez zmian, a pracownicy niczego nie zobaczą przed publikacją.</p></div></header>
      <div className="solver-studio-start-grid">
        {leaderStudioSourceVariants.map(variant=><article key={variant.id}><span><Sparkles/></span><div><small>WARIANT GENERATORA</small><strong>{variant.strategy.name}</strong><p>{variant.assignmentCount} przydziałów • {variant.unfilledCount} braków{variant.recommended?" • rekomendowany":""}</p></div><button type="button" className="primary-button" disabled={busy} onClick={()=>void createLeaderCopy(variant)}>{busy?<RefreshCw className="spin"/>:<Edit3/>} Otwórz ten wariant</button></article>)}
        <article className="manual"><span><CalendarDays/></span><div><small>BEZ GENERATORA</small><strong>Utwórz pusty grafik ręcznie</strong><p>System przygotuje wymagane zmiany i wakaty; ludzi przypisujesz samodzielnie w Studio.</p></div><button type="button" className="secondary-button" disabled={busy||!selectedScenario?.id||!expectedSolverVersion||!name.trim()} onClick={()=>void createManualStudio()}>{busy?<RefreshCw className="spin"/>:<Edit3/>} Otwórz pusty szkic</button></article>
      </div>
    </section>}
    {leaderVariant&&selectedWorkspace&&leaderStudioOpen&&<section className="leader-studio-fullscreen" role="dialog" aria-modal="true" aria-label="Studio lidera">
      <header className="leader-studio-fullscreen-head">
        <span><Edit3/><div><small>STUDIO LIDERA • REWIZJA {leaderVariant.revision}</small><h2>{leaderVariant.name}</h2><p>{leaderVariant.sourceVariantId?"Osobna wersja robocza na bazie wariantu generatora. Pracownicy nie widzą zmian przed publikacją.":"Pusty grafik ręczny z gotowym zapotrzebowaniem. Pracownicy nie widzą zmian przed publikacją."}</p></div></span>
        <div className="leader-studio-history-actions">
          <button type="button" className="secondary-button" disabled={studioBusy||!leaderHistory?.canUndo} onClick={()=>void moveLeaderRevision("UNDO")}><Undo2/> Cofnij</button>
          <button type="button" className="secondary-button" disabled={studioBusy||!leaderHistory?.canRedo} onClick={()=>void moveLeaderRevision("REDO")}><Redo2/> Ponów</button>
          <details className="leader-history-menu">
            <summary><History/> Historia</summary>
            <div className="leader-history-menu-body">
              {leaderWorkflow==="DRAFT"&&<form className="leader-checkpoint-create" onSubmit={event=>{event.preventDefault();void saveLeaderCheckpoint();}}>
                <label>Nazwa punktu kontrolnego<input value={leaderCheckpointName} maxLength={80} onChange={event=>setLeaderCheckpointName(event.target.value)} placeholder="np. Obsadzona SALA"/></label>
                <button type="submit" className="secondary-button" disabled={studioBusy||leaderCheckpointName.trim().length<3}>Zapisz punkt</button>
              </form>}
              <div className="leader-history-list">{leaderHistory?.entries.map(entry=><article className={`${entry.current?"current ":""}${entry.isCheckpoint?"checkpoint":""}`} key={entry.seq}>
                <span><b>{entry.checkpointName??entry.label}</b><small>Rewizja {entry.revision}{entry.current?" • bieżąca":""}</small></span>
                {entry.isCheckpoint&&!entry.current&&leaderWorkflow==="DRAFT"&&<button type="button" className="link-button" disabled={studioBusy} onClick={()=>{setLeaderCheckpointRestoreSeq(entry.seq);setLeaderCheckpointRestoreReason("");}}>Przywróć</button>}
              </article>)}</div>
            </div>
          </details>
          <em>{leaderVariant.status==="PUBLISHED"?"OPUBLIKOWANA":"WERSJA ROBOCZA"}</em>
          <button type="button" className="icon-button" aria-label="Zamknij Studio lidera" disabled={studioBusy} onClick={()=>{setLeaderWorkspaceBusy(false);setLeaderStudioOpen(false);setPendingLeaderWorkflow(null);setLeaderWorkflowReason("");setLeaderCheckpointRestoreSeq(null);setLeaderCheckpointRestoreReason("");setLeaderRefillStatus(null);setLeaderOptimizationRun(null);setLeaderOptimizationStatus(null);setLeaderOptimizationProposal(null);}}><X/></button>
        </div>
      </header>
      {leaderCheckpointRestoreSeq!==null&&<section className="leader-workflow-confirm leader-checkpoint-restore"><div><strong>Przywrócić punkt kontrolny?</strong><small>Bieżący szkic zostanie zapisany w historii, a wybrany układ stanie się nową rewizją roboczą. Nic nie trafi do pracowników.</small></div><label>Powód przywrócenia<textarea autoFocus minLength={3} value={leaderCheckpointRestoreReason} onChange={event=>setLeaderCheckpointRestoreReason(event.target.value)} placeholder="np. powrót do układu po obsadzeniu SALI"/></label><span><button type="button" className="secondary-button" disabled={studioBusy} onClick={()=>{setLeaderCheckpointRestoreSeq(null);setLeaderCheckpointRestoreReason("");}}>Anuluj</button><button type="button" className="primary-button" disabled={studioBusy||leaderCheckpointRestoreReason.trim().length<3} onClick={()=>void restoreSelectedLeaderCheckpoint()}>{busy?<RefreshCw className="spin"/>:<History/>} Przywróć punkt</button></span></section>}
      <nav className="leader-studio-workflow" aria-label="Etap wersji roboczej">
        <span className={leaderWorkflow==="DRAFT"?"active":"done"}><b>1</b> Roboczy</span>
        <span className={leaderWorkflow==="REVIEW"?"active":["LEADER_APPROVED","READY_TO_MERGE","PUBLISHED"].includes(leaderWorkflow)?"done":""}><b>2</b> Do sprawdzenia</span>
        <span className={leaderWorkflow==="LEADER_APPROVED"?"active":["READY_TO_MERGE","PUBLISHED"].includes(leaderWorkflow)?"done":""}><b>3</b> Zatwierdzony przez lidera</span>
        <span className={leaderWorkflow==="READY_TO_MERGE"?"active":leaderWorkflow==="PUBLISHED"?"done":""}><b>4</b> Gotowy do scalenia</span>
        <span className={leaderWorkflow==="PUBLISHED"?"active":""}><b>5</b> Opublikowany</span>
        <div>{leaderWorkflow==="DRAFT"&&<><button className="secondary-button" disabled={studioBusy} onClick={()=>void checkLeaderDraft()}><Check/> Sprawdź cały grafik</button><button className="primary-button" disabled={studioBusy||!leaderDraftValidationCurrent||!leaderDraftValidation?.valid} title={!leaderDraftValidationCurrent?"Najpierw sprawdź bieżącą wersję całego szkicu":leaderDraftValidation?.valid?"Przekaż sprawdzony szkic":"Najpierw popraw naruszenia twardych reguł"} onClick={()=>setPendingLeaderWorkflow("REVIEW")}>Przekaż sprawdzony grafik</button></>}{leaderWorkflow==="REVIEW"&&<><button className="secondary-button" disabled={studioBusy} onClick={()=>setPendingLeaderWorkflow("DRAFT")}>Wróć do edycji</button><button className="primary-button" disabled={studioBusy} onClick={()=>setPendingLeaderWorkflow("LEADER_APPROVED")}>Zatwierdź jako lider</button></>}{leaderWorkflow==="LEADER_APPROVED"&&<><button className="secondary-button" disabled={studioBusy} onClick={()=>setPendingLeaderWorkflow("DRAFT")}>Wróć do edycji</button><button className="primary-button" disabled={studioBusy} onClick={()=>setPendingLeaderWorkflow("READY_TO_MERGE")}>Oznacz jako gotowy do scalenia</button></>}{leaderWorkflow==="READY_TO_MERGE"&&<button className="secondary-button" disabled={studioBusy} onClick={()=>setPendingLeaderWorkflow("DRAFT")}>Cofnij do edycji</button>}</div>
      </nav>
      {leaderDraftValidationCurrent&&leaderDraftValidation&&<section
        className={`leader-refill-status leader-draft-validation-result ${!leaderDraftValidation.valid?"danger":leaderDraftValidation.unfilledCount+leaderDraftValidation.zeroHoursCount+leaderDraftValidation.belowTargetCount+leaderDraftValidation.overtimeMinutes+leaderDraftValidation.preferenceViolations>0?"info":"success"}`}
        role="status" aria-live="polite" aria-label={`Wynik kontroli całego grafiku, rewizja ${leaderDraftValidation.revision}`}>
        {leaderDraftValidation.valid?<Check/>:<AlertTriangle/>}
        <span>
          <strong>{leaderDraftValidation.valid?"Kontrola całego grafiku zakończona":"Kontrola całego grafiku wykryła twarde błędy"} • rewizja {leaderDraftValidation.revision}</strong>
          <small><b>Naruszenia twarde:</b> {leaderDraftValidation.hardViolations} • <b>wakaty:</b> {leaderDraftValidation.unfilledCount} • <b>przydziały:</b> {leaderDraftValidation.assignmentCount}</small>
          <small><b>Osoby z 0 h:</b> {leaderDraftValidation.zeroHoursCount} • <b>osoby poniżej nominału:</b> {leaderDraftValidation.belowTargetCount}</small>
          <small><b>Nadgodziny:</b> {workloadMinutesLabel(leaderDraftValidation.overtimeMinutes)} • <b>niespełnione preferencje:</b> {leaderDraftValidation.preferenceViolations}</small>
          <small>{leaderDraftValidation.valid
            ? "Wakaty i ostrzeżenia miękkie są jawne w raporcie, ale zgodnie z kontraktem nie blokują przekazania sprawdzonego szkicu. Każda kolejna edycja unieważni ten wynik."
            : "Twarde naruszenia blokują przekazanie. Popraw grafik i uruchom kontrolę ponownie."}</small>
        </span>
      </section>}
      {leaderWorkflow==="DRAFT"&&<section className="leader-assistant-tools" aria-label="Opcjonalne narzędzia generatora">
        {selectedVariant&&selectedVariant.unfilledCount>0&&<details name="leader-studio-assistant" className="leader-assistant-tool leader-refill-action">
          <summary><span><Sparkles/><span><strong>Uzupełnij tylko wakaty</strong><small>Ręczne przydziały pozostaną bez zmian.</small></span></span><em className={leaderRefillStatus?.tone??""}>{leaderRefillSubmitting?"Uruchamiam…":leaderRefillRun?"Generator pracuje":leaderRefillStatus?.title??(selectedVariant.unfilledCount===1?"1 wakat":`${selectedVariant.unfilledCount} wakatów`)}</em></summary>
          <div className="leader-assistant-tool-body">
            <label className="leader-assistant-reason">Powód uruchomienia<textarea minLength={3} disabled={leaderRefillSubmitting||Boolean(leaderRefillRun)||Boolean(leaderOptimizationRun)} value={leaderRefillReason} onChange={event=>setLeaderRefillReason(event.target.value)} placeholder="np. uzupełnienie pozostałych wakatów po ręcznej korekcie"/><small>{leaderRefillReason.trim().length<3?"Wpisz co najmniej 3 znaki, aby uruchomić generator tylko dla wakatów.":"Gotowe — generator nie zmieni ręcznych decyzji lidera."}</small></label>
            <span><button type="button" className="primary-button" disabled={!supabase||leaderRefillSubmitting||studioBusy||Boolean(leaderRefillRun)||Boolean(leaderOptimizationRun)||leaderRefillReason.trim().length<3} onClick={()=>void startLeaderRefill()} title={!supabase?"Brak połączenia z backendem UAT":leaderRefillReason.trim().length<3?"Najpierw wpisz powód uruchomienia":"Uzupełnij wyłącznie nieobsadzone miejsca"}>{leaderRefillSubmitting||leaderRefillRun?<RefreshCw className="spin"/>:<Sparkles/>} {leaderRefillSubmitting?"Uruchamiam zadanie…":leaderRefillRun?"Uzupełniam wolne miejsca…":"Uzupełnij tylko wakaty"}</button></span>
            {leaderRefillStatus&&<div className={`leader-refill-status ${leaderRefillStatus.tone}`} role="status" aria-live="assertive">{leaderRefillStatus.tone==="danger"?<AlertTriangle/>:leaderRefillStatus.tone==="success"?<Check/>:<RefreshCw className={leaderRefillSubmitting||leaderRefillRun?"spin":""}/>}<span><strong>{leaderRefillStatus.title}</strong><small>{leaderRefillStatus.detail}</small></span></div>}
          </div>
        </details>}
        <details name="leader-studio-assistant" className="leader-assistant-tool leader-optimization-action">
          <summary><span><Sparkles/><span><strong>Przelicz niezablokowany zakres</strong><small>Koszt, sprawiedliwość albo sama propozycja.</small></span></span><em className={leaderOptimizationStatus?.tone??""}>{leaderOptimizationRun?"Generator pracuje":leaderOptimizationStatus?.title??"Opcjonalne"}</em></summary>
          <div className="leader-assistant-tool-body">
            <label>Tryb przeliczenia<select disabled={Boolean(leaderOptimizationRun)} value={leaderOptimizationMode} onChange={event=>setLeaderOptimizationMode(event.target.value as SolverLeaderOptimizationMode)}><option value="COST">Popraw koszt</option><option value="FAIRNESS">Popraw sprawiedliwość</option><option value="PROPOSE_ONLY">Tylko pokaż propozycję</option></select></label>
            <label className="leader-assistant-reason">Cel przeliczenia<textarea minLength={3} disabled={Boolean(leaderOptimizationRun)} value={leaderOptimizationReason} onChange={event=>setLeaderOptimizationReason(event.target.value)} placeholder="np. wyrównanie godzin bez zmiany przypiętych decyzji"/></label>
            <span><button type="button" className="secondary-button" disabled={studioBusy||Boolean(leaderRefillRun)||Boolean(leaderOptimizationRun)||leaderOptimizationReason.trim().length<3} onClick={()=>void startLeaderOptimization()}>{leaderOptimizationRun?<RefreshCw className="spin"/>:<Sparkles/>} {leaderOptimizationRun?"Przeliczam…":leaderOptimizationMode==="PROPOSE_ONLY"?"Przygotuj propozycję":"Uruchom przeliczenie"}</button>{leaderOptimizationRun&&<button type="button" className="danger-button" disabled={studioBusy} onClick={()=>void cancelLeaderOptimization()}><X/> Zatrzymaj przeliczenie</button>}</span>
            {leaderOptimizationStatus&&<div className={`leader-refill-status ${leaderOptimizationStatus.tone}`} role="status" aria-live="polite">{leaderOptimizationStatus.tone==="danger"?<AlertTriangle/>:leaderOptimizationStatus.tone==="success"?<Check/>:<RefreshCw className={leaderOptimizationRun?"spin":""}/>}<span><strong>{leaderOptimizationStatus.title}</strong><small>{leaderOptimizationStatus.detail}</small></span></div>}
            {leaderOptimizationProposal&&<article className="leader-optimization-proposal"><div><strong>Propozycja bez automatycznego zapisu</strong><small>Przydziały: {leaderOptimizationProposal.workspace.variants[0]?.assignmentCount??0} • braki: {leaderOptimizationProposal.workspace.variants[0]?.unfilledCount??0}. Bieżący szkic nadal ma rewizję {leaderVariant.revision}.</small></div><span><button type="button" className="secondary-button" disabled={studioBusy} onClick={()=>setInspectedWorkspace(leaderOptimizationProposal.workspace)}>Otwórz porównanie</button><button type="button" className="secondary-button" disabled={studioBusy} onClick={()=>{setLeaderOptimizationProposal(null);setLeaderOptimizationStatus(null);}}>Odrzuć</button><button type="button" className="primary-button" disabled={studioBusy||leaderVariant.revision!==leaderOptimizationProposal.leaderRevision} title={leaderVariant.revision!==leaderOptimizationProposal.leaderRevision?"Szkic zmienił się po przygotowaniu propozycji — uruchom nowe przeliczenie":"Zastosuj propozycję do niezablokowanego zakresu"} onClick={()=>void applyLeaderOptimizationProposal()}>Zastosuj propozycję</button></span></article>}
          </div>
        </details>
      </section>}
      {pendingLeaderWorkflow&&<section className="leader-workflow-confirm"><div><strong>Potwierdź zmianę etapu</strong><small>Powód zostanie zapisany w historii wersji lidera. Samo przejście etapu nie publikuje grafiku pracownikom.</small></div><label>Powód decyzji<textarea autoFocus minLength={3} value={leaderWorkflowReason} onChange={event=>setLeaderWorkflowReason(event.target.value)} placeholder="np. grafik sprawdzony przez lidera BAR"/></label><span><button type="button" className="secondary-button" disabled={studioBusy} onClick={()=>{setPendingLeaderWorkflow(null);setLeaderWorkflowReason("");}}>Anuluj</button><button type="button" className="primary-button" disabled={studioBusy||leaderWorkflowReason.trim().length<3} onClick={()=>void moveLeaderWorkflow(pendingLeaderWorkflow)}>{busy?<RefreshCw className="spin"/>:<Check/>} Zapisz zmianę etapu</button></span></section>}
      <div className="leader-studio-fullscreen-body"><SolverV2Workspace key={`leader:${selectedWorkspace.context.runId??leaderVariant.id}`} workspace={selectedWorkspace} baselineWorkspace={leaderBaselineWorkspace} timezone={timezone} published={leaderVariant.status==="PUBLISHED"} leaderEditable={leaderVariant.status!=="PUBLISHED"&&leaderWorkflow==="DRAFT"} initialView="CALENDAR" onLeaderChanged={reloadLeaderWorkspace} onLeaderBusyChange={handleLeaderWorkspaceBusyChange} onOpenAdHoc={onOpenAdHoc} notify={setMessage} fail={setMessage}/></div>
    </section>}

    {previewWorkspace && !inspectedWorkspace && !leaderVariant && <div id="solver-variant-detail"><SolverV2Workspace key={`preview:${previewWorkspace.context.runId??previewWorkspace.context.scheduleId??previewWorkspace.variants[0]?.id??"workspace"}`} workspace={previewWorkspace} timezone={timezone} published={previewWorkspace.context.type === "PUBLISHED_SCHEDULE"||selectedVariant?.status==="PUBLISHED"} notify={setMessage} fail={setMessage}/></div>}

    {inspectedWorkspace && <>
      <button className="drawer-scrim top" aria-label="Zamknij podgląd wariantu" onClick={() => setInspectedWorkspace(null)}/>
      <aside className="drawer role-drawer top solver-variant-preview-drawer" style={{width:"min(1280px, calc(100vw - 32px))"}} aria-label="Podgląd grafiku wariantu">
        <div className="drawer-head">
          <div><p className="eyebrow">WARIANT • PODGLĄD GRAFIKU</p><h2>{inspectedWorkspace.context.name}</h2><small>Pełny skład, obsada według dni oraz rozkład braków.</small></div>
          <button className="icon-button" aria-label="Zamknij podgląd wariantu" onClick={() => setInspectedWorkspace(null)}><X/></button>
        </div>
        <div className="drawer-content"><SolverV2Workspace key={`inspect:${inspectedWorkspace.context.runId??inspectedWorkspace.variants[0]?.id??"workspace"}`} workspace={inspectedWorkspace} timezone={timezone} published={false} notify={setMessage} fail={setMessage}/></div>
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
        {publicationChangePanel}
        {leaderVariant&&!leaderStudioOpen&&<button type="button" className="secondary-button" disabled={busy} onClick={()=>setLeaderStudioOpen(true)}><Edit3/> Otwórz ponownie Studio lidera</button>}
        {!leaderPublicationReady&&<small className="publication-workflow-blocker">Najpierw zakończ kontrolę wersji lidera i oznacz ją jako „Gotowa do scalenia”.</small>}
        <button className="primary-button" disabled={busy || publicationChangesBusy || !publicationChanges || !publicationName.trim() || selectedVariant.status === "PUBLISHED" || !leaderPublicationReady} title={!leaderPublicationReady?"Publikacja wymaga etapu: Gotowy do scalenia":!publicationChanges?"Najpierw wylicz różnice i zakres powiadomień":"Opublikuj grafik zespołu"} onClick={() => void publishSelectedRole()}>
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
        {publicationChangePanel}
        <button className="primary-button" disabled={busy || publicationChangesBusy || !publicationChanges || !publicationName.trim()} onClick={() => void publishSelected()}>
          {busy ? <><RefreshCw className="spin"/> Publikuję…</> : <><Upload/> Opublikuj wybrany wariant</>}
        </button>
      </div>}

    {pendingCompanyPublication&&<section className="solver-publication-confirm" aria-label="Potwierdzenie publikacji grafiku firmy"><header><AlertTriangle/><span><strong>Sprawdź skutki przed publikacją</strong><small>Kontrola nie zmieniła grafiku. Publikacja nastąpi dopiero po jawnym potwierdzeniu poniżej.</small></span></header>{pendingCompanyPublication.warningCount>0&&<label>Powód publikacji mimo {pendingCompanyPublication.warningCount} braków obsady<textarea minLength={3} value={publicationWarningReason} onChange={event=>setPublicationWarningReason(event.target.value)} placeholder="np. potwierdzony niedobór kadrowy; wakaty zostaną obsadzone operacyjnie"/></label>}{pendingCompanyPublication.roleReplacementCount>0&&<label>Powód zastąpienia {pendingCompanyPublication.roleReplacementCount} opublikowanych grafików zespołów<textarea minLength={5} value={publicationReplacementReason} onChange={event=>setPublicationReplacementReason(event.target.value)} placeholder="np. zatwierdzone scalenie grafików kategorii do grafiku firmy"/></label>}<div><button type="button" className="secondary-button" disabled={busy} onClick={()=>{setPendingCompanyPublication(null);setPublicationWarningReason("");setPublicationReplacementReason("");}}>Anuluj — niczego nie publikuj</button><button type="button" className="primary-button" disabled={busy||(pendingCompanyPublication.warningCount>0&&publicationWarningReason.trim().length<3)||(pendingCompanyPublication.roleReplacementCount>0&&publicationReplacementReason.trim().length<5)} onClick={()=>void confirmCompanyPublication()}>{busy?<RefreshCw className="spin"/>:<Upload/>} Potwierdź i opublikuj</button></div></section>}

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
