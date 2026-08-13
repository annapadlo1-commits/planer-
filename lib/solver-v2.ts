import type { SupabaseClient } from "@supabase/supabase-js";

export type SolverEngine = "ALPHA15" | "ORTOOLS_V2" | "SHADOW";
export type SolverScope = "COMPANY" | "ROLE";

export type SolverScenario = {
  id: string | null;
  code: string;
  name: string;
  description?: string;
  strategyCount: number;
  isDefault: boolean;
  validFrom?: string | null;
  validTo?: string | null;
  profileMode?: "BASELINE" | "PERIOD";
};

export type SolverRole = { id: string; code: string; name: string; color?: string | null; logicalId?: string | null };
export type SolverRoleCategory = {
  id: string;
  code: string;
  name: string;
  color?: string | null;
  sortOrder: number;
  anchorRoleId: string;
  roleIds: string[];
  roleNames: string[];
};
export type SolverLocation = { id: string; code: string; name: string };

export type SolverConfiguration = {
  engine: SolverEngine;
  enabled: boolean;
  solverVersion: string | null;
  matrixVersionId: string | null;
  matrixEffectiveFrom: string | null;
  scenarios: SolverScenario[];
  roleCategories: SolverRoleCategory[];
  roles: SolverRole[];
  locations: SolverLocation[];
  currency: string | null;
  timezone: string | null;
};

export type SolverRun = {
  id: string;
  requestEngine?: Exclude<SolverEngine, "ALPHA15">;
  solverVersion?: string;
  status: string;
  phase: string;
  progress: number;
  month?: string;
  scopeType?: SolverScope;
  scopeRoleId?: string | null;
  failureMessage?: string | null;
  createdAt?: string;
  queuedAt?: string;
  startedAt?: string | null;
  heartbeatAt?: string | null;
  queuePosition?: number | null;
  waitingSeconds?: number;
  runningSeconds?: number | null;
  updatedAt?: string;
};

export type SolverStrategyProgress = {
  id: string;
  name: string;
  status: string;
  phase: string;
  progress: number;
};

export type SolverStatus = { run: SolverRun; strategies: SolverStrategyProgress[] };

export type SolverVariant = {
  id: string;
  name: string;
  strategy: { id: string; name: string; description?: string };
  status: string;
  hardViolations: number;
  assignmentCount: number;
  unfilledCount: number;
  totalCostMinor?: number | null;
  budgetMinor?: number | null;
  currency: string;
  solverStatus: string;
  recommended: boolean;
  selected: boolean;
  equivalentToVariantId?: string | null;
  metrics: Record<string, unknown>;
};

export type SolverVariants = { runId: string; variants: SolverVariant[] };

export type SolverWorkspaceFinance = {
  baseCostMinor: number;
  additionsCostMinor: number;
  totalCostMinor: number;
  budgetMinor: number | null;
  currency: string;
};

export type SolverWorkspaceContext = {
  type: "SELECTED_VARIANT" | "PUBLISHED_SCHEDULE" | string;
  engine?: SolverEngine;
  runId?: string;
  scheduleId?: string;
  sourceType?: string;
  name: string;
  status?: string;
  month: string;
  scenario: { id: string; name: string };
  matrixVersionId: string;
  publishedAt?: string | null;
  archivedAt?: string | null;
  variantKind?: "GENERATED" | "LEADER_COPY";
  sourceVariantId?: string | null;
  revision?: number;
  lastEditedAt?: string | null;
};

export type SolverWorkspaceVariant = {
  id: string;
  runId: string;
  name: string;
  status: string;
  recommended: boolean;
  selected: boolean;
  strategy: { id: string; name: string };
  scope: {
    type: SolverScope;
    role: { id: string; name: string } | null;
  };
  assignmentCount: number;
  unfilledCount: number;
  solverStatus: string;
  finance: SolverWorkspaceFinance | null;
};

export type SolverWorkspaceAssignment = {
  id: string;
  slotKey: string;
  employee: {
    id: string;
    employeeNo: string;
    firstName: string;
    lastName: string;
    nominalMonthlyMinutes: number;
  };
  role: { id: string; name: string };
  duties: { id: string; name: string }[];
  locked: boolean;
  costMinor: number | null;
};

export type SolverWorkspaceShift = {
  id: string;
  slotGroupKey: string;
  date: string;
  startsAt: string;
  endsAt: string;
  location: { id: string; name: string; timezone: string | null };
  shiftTemplate: { id: string; name: string };
  assignments: SolverWorkspaceAssignment[];
};

export type SolverWorkspaceIssue = {
  id: string;
  variantId: string;
  slotKey: string | null;
  code: string;
  severity: string;
  message: string;
  requiredCount: number | null;
  assignedCount: number | null;
  role: { id: string; name: string } | null;
  duty: { id: string; name: string } | null;
  shift: {
    id: string;
    date: string;
    startsAt: string;
    endsAt: string;
    location: { id: string; name: string; timezone: string | null };
    shiftTemplate: { id: string; name: string; shiftPeriod?: string };
  } | null;
};

export type SolverWorkspace = {
  context: SolverWorkspaceContext;
  variants: SolverWorkspaceVariant[];
  shifts: SolverWorkspaceShift[];
  issues: SolverWorkspaceIssue[];
  finance: SolverWorkspaceFinance | null;
};

export type SolverWorkloadDistributionRow = {
  employeeId: string;
  employeeNo: string;
  employeeName: string;
  roleNames: string[];
  plannedMinutes: number;
  shiftCount: number;
  nominalMonthlyMinutes: number;
  maximumMonthlyMinutes: number;
  differenceMinutes: number;
  hardUnavailableDays: number;
  availableWindowDays: number;
  reasonCode: "AVAILABILITY_LIMITED" | "AVAILABILITY_WINDOW_LIMITED" | "MAXIMUM_REACHED" | "TARGET_NOT_SET" | "SOLVER_DISTRIBUTION" | "ABOVE_NOMINAL" | "ON_TARGET" | string;
  locations: { id: string; name: string; minutes: number; shiftCount: number }[];
};

export async function getVariantWorkloadDistribution(
  client: SupabaseClient,
  variantId: string,
): Promise<SolverWorkloadDistributionRow[]> {
  const payload=record(await rpc(client,"optimizer_variant_workload_distribution_uat_v1",{
    p_variant_id:variantId,
  }));
  if(!Array.isArray(payload.employees))return [];
  return payload.employees.map(value=>{
    const row=record(value);
    return {
      employeeId:String(row.employeeId??""),
      employeeNo:String(row.employeeNo??""),
      employeeName:String(row.employeeName??""),
      roleNames:Array.isArray(row.roleNames)?row.roleNames.map(String):[],
      plannedMinutes:numberOf(row,"plannedMinutes","planned_minutes"),
      shiftCount:numberOf(row,"shiftCount","shift_count"),
      nominalMonthlyMinutes:numberOf(row,"nominalMonthlyMinutes","nominal_monthly_minutes"),
      maximumMonthlyMinutes:numberOf(row,"maximumMonthlyMinutes","maximum_monthly_minutes"),
      differenceMinutes:numberOf(row,"differenceMinutes","difference_minutes"),
      hardUnavailableDays:numberOf(row,"hardUnavailableDays","hard_unavailable_days"),
      availableWindowDays:numberOf(row,"availableWindowDays","available_window_days"),
      reasonCode:String(row.reasonCode??"SOLVER_DISTRIBUTION"),
      locations:Array.isArray(row.locations)?row.locations.map(value=>{
        const location=record(value);
        return {id:String(location.id??""),name:String(location.name??""),minutes:numberOf(location,"minutes","minutes"),shiftCount:numberOf(location,"shiftCount","shift_count")};
      }):[],
    };
  });
}

export type SolverLeaderVariant = {
  id: string;
  sourceVariantId: string;
  name: string;
  status: string;
  revision: number;
  assignmentCount: number;
  unfilledCount: number;
  lastEditedAt?: string | null;
};

export type SolverLeaderAssignmentContext = {
  variantId: string;
  assignmentId: string | null;
  issueId: string | null;
  slotKey: string;
  currentEmployeeId: string | null;
  role: { id: string; name: string };
  duty: { id: string; name: string } | null;
  shift: {
    id: string; date: string; startsAt: string; endsAt: string;
    locationId: string; locationName: string; shiftName: string;
  };
  candidates: {
    employeeId: string; employeeNo: string; employeeName: string; current: boolean;
    roleName?: string; locationName?: string; dutyName?: string | null;
    dutyMatch: boolean; dutyCoverageMode: "DIRECT"|"TRANSFER"|"NOT_COVERED";
    dutyTransferAssignmentId: string|null; dutyTransferEmployeeId: string|null;
    dutyTransferEmployeeName: string|null;
    availabilityStatus: "AVAILABLE"|"SOFT_AVOID"|"HARD_UNAVAILABLE"|"SHIFT_CONFLICT"|"OUTSIDE_AVAILABLE_WINDOW"|string;
    suggestionEligible: boolean;
  }[];
};

export type SolverManagerStandby = {
  id: string;
  date: string;
  tier: 1 | 2;
  status: "PREVIEW" | "PLANNED" | "ACTIVATED" | "DECLINED";
  roleId: string;
  roleName: string;
  employeeId: string;
  employeeNo: string;
  employeeName: string;
  sourceType: "COMPANY" | "ROLE";
  activatedShiftId: string | null;
};

export type SolverEmployeeDayAvailability={
  employeeId:string;date:string;scheduled:boolean;status:string;label:string;
};

export async function getManagerStandbyMonth(
  client: SupabaseClient,
  month: string,
  scopeRoleId?: string | null,
): Promise<SolverManagerStandby[]> {
  const value = await rpc(client, "manager_standby_month_uat_v2", {
    p_month: month,
    p_scope_role_id: scopeRoleId ?? null,
  });
  if (!Array.isArray(value)) return [];
  return value.map(item => {
    const row = record(item);
    return {
      id: String(row.id), date: String(row.date), tier: Number(row.tier) as 1 | 2,
      status: String(row.status) as SolverManagerStandby["status"],
      roleId: String(row.roleId), roleName: String(row.roleName),
      employeeId: String(row.employeeId), employeeNo: String(row.employeeNo),
      employeeName: String(row.employeeName), sourceType: String(row.sourceType) as "COMPANY" | "ROLE",
      activatedShiftId: row.activatedShiftId ? String(row.activatedShiftId) : null,
    };
  });
}

export async function getVariantStandbyPreview(
  client: SupabaseClient,
  variantId: string,
): Promise<SolverManagerStandby[]> {
  const value = await rpc(client, "optimizer_variant_standby_preview_uat_v1", {
    p_variant_id: variantId,
  });
  if (!Array.isArray(value)) return [];
  return value.map(item => {
    const row = record(item);
    return {
      id: String(row.id), date: String(row.date), tier: Number(row.tier) as 1 | 2,
      status: "PREVIEW" as const,
      roleId: String(row.roleId), roleName: String(row.roleName),
      employeeId: String(row.employeeId), employeeNo: String(row.employeeNo),
      employeeName: String(row.employeeName), sourceType: String(row.sourceType) as "COMPANY" | "ROLE",
      activatedShiftId: null,
    };
  });
}

export type SolverCandidateDiagnostic = {
  employeeId: string;
  employeeNo: string;
  name: string;
  classification: "ELIGIBLE" | "WARNING" | "BLOCKED";
  hardReasons: string[];
  softReasons: string[];
  preferenceLevel: string;
  monthlyShifts: number;
  monthlyMinutes: number;
  nominalMonthlyMinutes: number;
  maximumMonthlyMinutes: number;
  weeklyMinutes: number;
  maximumWeeklyMinutes: number;
  consecutiveDaysBefore: number;
  consecutiveDaysAfter: number;
  projectedConsecutiveDays: number;
  maximumConsecutiveDays: number;
  declaredUnavailable: boolean;
  outsideAvailableWindow: boolean;
  worksPreviousDay: boolean;
  worksNextDay: boolean;
  previousShift: { date: string; startsAt: string; endsAt: string } | null;
  nextShift: { date: string; startsAt: string; endsAt: string } | null;
};

export type SolverCandidateDiagnostics = {
  scheduleId: string;
  issue: { id: string; code: string; message: string; slotKey: string; roleId: string; dutyId: string | null };
  shift: {
    id: string; slotGroupKey: string; date: string; startsAt: string; endsAt: string;
    locationId: string; shiftTemplateId: string; shiftPeriod: "MORNING" | "MIDDLE" | "EVENING";
  };
  candidates: SolverCandidateDiagnostic[];
  summary: { considered: number; eligible: number; warning: number; blocked: number };
};

export type SolverVariantIssueDiagnostics = {
  variantId: string;
  issueId: string;
  publishedScheduleId: string | null;
  shift: { date: string; startsAt: string; endsAt: string; shiftPeriod: string };
  summary: {
    considered: number;
    eligible: number;
    blocked: number;
    reasons: { code: string; count: number }[];
  };
  decisionContext: {
    code: string;
    standbyTiers: number;
    message: string;
  } | null;
  candidates: {
    employeeId: string;
    employeeNo: string;
    employeeName: string;
    roleMatch: boolean;
    locationMatch: boolean;
    dutyMatch: boolean;
    hasDeclaredWindow: boolean;
    coversShift: boolean;
    reasons: string[];
    blockingDetails?: Array<{
      code: string;
      label: string;
      startsAt?: string | null;
      endsAt?: string | null;
      shiftName?: string | null;
      locationName?: string | null;
      note?: string | null;
      createdAt?: string | null;
    }>;
  }[];
};

export type SolverPublicationReadiness = {
  ready: boolean;
  blockers: Record<string, { code: string; message: string; count?: number; status?: string; phase?: string }>;
  warnings: { unfilledCount: number; message?: string | null };
  issues: Array<{
    id: string; code: string; severity: string; message: string; date?: string;
    startsAt?: string; endsAt?: string; locationId?: string; locationName?: string;
    shiftTemplateId?: string; shiftTemplateName?: string; roleId?: string;
    roleName?: string; dutyId?: string | null; dutyName?: string | null;
    requiredCount?: number | null; assignedCount?: number | null; slotKey?: string;
  }>;
};

export type SolverCatalogRun = {
  id: string;
  name: string;
  status: string;
  phase: string;
  progress: number;
  createdAt: string;
  finishedAt?: string | null;
  scenario: { id: string; code: string; name: string };
  scope: { type: SolverScope; roleId?: string | null; roleName?: string | null };
  variants: SolverVariant[];
};

export type OperationalPlan = {
  id: string;
  month: string;
  name: string;
  scenario_code: string;
  optimization_mode: string;
  staffing_level: string;
  status: string;
  version: number;
  score: number;
  total_cost: number;
};

export type OperationalAssignment = {
  id: string;
  shift_id: string;
  employee_id: string;
  employee_no: string;
  name: string;
  role: string;
  role_id?: string;
  role_name?: string;
  capability?: string;
  location: string;
  location_id?: string;
  location_name?: string;
  location_timezone?: string;
  date: string;
  shift_code: string;
  shift_template_id?: string;
  shift_name?: string;
  starts_at: string;
  ends_at: string;
  cost: number;
  monthly_minutes: number;
  nominal_minutes: number;
};

export type OperationalShift = {
  id: string;
  shift_date: string;
  shift_code: string;
  shift_template_id?: string;
  shift_name?: string;
  starts_at: string;
  ends_at: string;
  location_code: string;
  location_id?: string;
  location_name?: string;
  location_timezone?: string;
  assignment_count: number;
};

export type OperationalIssue = {
  id: string;
  shift_id?: string;
  issue_type: string;
  severity: string;
  role?: string;
  role_id?: string;
  capability?: string;
  required_count?: number;
  assigned_count?: number;
  message: string;
};

export type OperationalEvent = {
  id: string;
  title: string;
  event_type: string;
  status: string;
  starts_at: string;
  ends_at: string;
  location: string;
  expected_guests?: number;
};

export type OperationalWorkspace = {
  plan: OperationalPlan | null;
  assignments: OperationalAssignment[];
  shifts: OperationalShift[];
  issues: OperationalIssue[];
  events: OperationalEvent[];
  budget: { amount: number; warning_percent: number; hard_limit: boolean };
};

export type SolverEmployeePublishedAssignment = {
  id: string;
  shiftId?: string;
  date: string;
  startsAt: string;
  endsAt: string;
  shiftCode?: string;
  shiftName?: string;
  location: string;
  locationCode?: string;
  locationTimezone?: string;
  role: string;
  roleCode?: string;
  capability?: string;
  coworkers?: { name: string; role: string; capability?: string }[];
};

export type SolverEmployeeStandby = {
  id: string;
  date: string;
  tier: 1 | 2;
  status: "PLANNED" | "ACTIVATED" | "DECLINED" | "CANCELLED" | "SUPERSEDED";
  roleId: string;
  roleName: string;
  activatedShiftId?: string;
};

export type SolverEmployeePublishedSchedule = {
  assignments: SolverEmployeePublishedAssignment[];
  standby: SolverEmployeeStandby[];
};

export type SolverPublication = {
  scheduleId: string;
  status: string;
  sourceType: string;
  reused: boolean;
};

export type SolverPublicationAuthorityStatus = {
  month: string;
  conflict: boolean;
  company: null | { id: string; name: string; sourceType: string; publishedAt: string };
  roles: Array<{ id: string; roleId: string; roleName: string; variantId: string; name: string; publishedAt: string }>;
  conflicts: Array<{ reason: string; roleId: string; roleName: string; roleScheduleId: string; companyScheduleId: string }>;
  resolved?: boolean;
  keptSource?: "COMPANY" | "ROLES";
};

export type SolverRoleCompositeVariant = {
  id: string;
  runId: string;
  name: string;
  strategy: { id: string; name: string };
  assignmentCount: number;
  unfilledCount: number;
  solverStatus: string;
};

export type SolverRoleCompositeRole = {
  id: string;
  name: string;
  sortOrder: number;
  variant: SolverRoleCompositeVariant | null;
};

export type SolverRoleCompositeCandidates = {
  month: string;
  scenario: { id: string; name: string };
  roles: SolverRoleCompositeRole[];
  missingRoleIds: string[];
  ready: boolean;
};

export type SolverRoleCompositeGap = {
  issueId: string;
  variantId: string;
  date: string;
  startsAt: string;
  endsAt: string;
  location: string;
  role: string;
  duty?: string;
  requiredCount: number;
  assignedCount: number;
  missingCount: number;
  critical: boolean;
  message: string;
};

export type SolverRoleCompositePreflight = {
  month: string;
  scenarioId: string;
  totalGaps: number;
  criticalGaps: number;
  gaps: SolverRoleCompositeGap[];
};

export type SolverRolePublicationOverview = {
  month: string;
  totals: {
    publishedRoles: number;
    assignmentCount: number;
    unfilledCount: number;
    overtimeMinutes: number;
    totalCostMinor: number;
    scheduledMinutes: number;
  };
  roles: Array<{
    publicationId: string;
    name: string;
    publishedAt: string;
    role: { id: string; name: string };
    scenario: { id: string; name: string };
    variantId: string;
    assignmentCount: number;
    unfilledCount: number;
    overtimeMinutes: number;
    totalCostMinor: number;
    currency: string;
    teamSize: number;
    scheduledMinutes: number;
  }>;
};

export type RunStorageContext = {
  userId: string;
  engine: SolverEngine;
  solverVersion: string;
  month: string;
  scenarioId: string;
  scopeType: SolverScope;
  scopeRoleId?: string | null;
};

const LEGACY_DEFAULT_SCENARIO: SolverScenario = {
  id: null,
  code: "BASE",
  name: "Bazowy",
  strategyCount: 0,
  isDefault: true,
};

function solverCurrency(value: unknown, required = true) {
  const currency = String(value ?? "").trim().toUpperCase();
  if (/^[A-Z]{3}$/.test(currency)) return currency;
  if (!required && !currency) return "";
  throw new Error("INVALID_SOLVER_CURRENCY");
}

function record(value: unknown): Record<string, unknown> {
  if (Array.isArray(value)) return record(value[0]);
  return value && typeof value === "object" ? value as Record<string, unknown> : {};
}

function valueOf<T>(source: Record<string, unknown>, camel: string, snake: string, fallback: T): T {
  const value = source[camel] ?? source[snake];
  return (value === undefined || value === null ? fallback : value) as T;
}

function numberOf(source: Record<string, unknown>, camel: string, snake: string, fallback = 0) {
  const value = Number(valueOf(source, camel, snake, fallback));
  return Number.isFinite(value) ? value : fallback;
}

function nullableNumberOf(source: Record<string, unknown>, camel: string, snake: string) {
  const raw = source[camel] ?? source[snake];
  if (raw === undefined || raw === null || raw === "") return null;
  const value = Number(raw);
  return Number.isFinite(value)…16383 tokens truncated…eturn stableHash(JSON.stringify({
    engine: context.engine,
    solverVersion: context.solverVersion?.trim() || null,
    month: context.month,
    scenarioId: context.scenarioId,
    scopeType: context.scopeType,
    scopeRoleId: context.scopeRoleId ?? null,
    name: name.trim(),
  }));
}

export function solverPendingRequestStorageKey(context: RunStorageContext, requestFingerprint: string) {
  return [solverRunStorageKey(context), "pending-request", requestFingerprint].join(":");
}

export function createIdempotencyKey(context: RunStorageContext, requestFingerprint = "request") {
  const scope = context.scopeRoleId ?? "company";
  const random = typeof crypto !== "undefined" && "randomUUID" in crypto
    ? crypto.randomUUID()
    : `${Date.now()}-${Math.random().toString(16).slice(2)}`;
  const key = `${context.engine}:${context.month}:${context.scenarioId}:${context.scopeType}:${scope}:${requestFingerprint}:${random}`;
  if (isValidIdempotencyKey(key)) return key;
  return `${context.engine}:${context.month}:${stableHash(key)}:${random}`;
}

export function publicationAttemptStorageKey(
  context: RunStorageContext,
  runId: string,
  variantId: string,
  publicationName: string,
) {
  const fingerprint = solverRequestFingerprint(
    context,
    `${publicationName.trim()}|publish:${runId}:${variantId}`,
  );
  return [solverRunStorageKey(context), "publication", runId, variantId, fingerprint].join(":");
}

export function roleCompositePublicationAttemptStorageKey(
  userId: string,
  month: string,
  scenarioId: string,
  variantIds: string[],
  publicationName: string,
) {
  const fingerprint = stableHash(JSON.stringify({
    variantIds: [...variantIds].sort(),
    publicationName: publicationName.trim(),
  }));
  return [
    "grafik-pro",
    "role-composite-publication-v2",
    userId,
    month,
    scenarioId,
    fingerprint,
  ].join(":");
}

export function createRoleCompositeIdempotencyKey(
  month: string,
  scenarioId: string,
  variantIds: string[],
  publicationName: string,
) {
  const random = typeof crypto !== "undefined" && "randomUUID" in crypto
    ? crypto.randomUUID()
    : `${Date.now()}-${Math.random().toString(16).slice(2)}`;
  const fingerprint = stableHash(JSON.stringify({
    month,
    scenarioId,
    variantIds: [...variantIds].sort(),
    publicationName: publicationName.trim(),
  }));
  const key = `${month}:ROLE_COMPOSITE:${scenarioId}:${fingerprint}:${random}`;
  if (isValidIdempotencyKey(key)) return key;
  return `${month}:ROLE_COMPOSITE:${stableHash(key)}:${random}`;
}

export function publishedScheduleStorageKey(context: RunStorageContext) {
  return ["grafik-pro", "published-schedule-v2", context.userId, context.month].join(":");
}

export function rememberPublishedSchedule(context: RunStorageContext, scheduleId: string) {
  if (typeof window === "undefined") return;
  if (!isValidStoredUuid(scheduleId)) throw new Error("SCHEDULE_ID_INVALID");
  window.localStorage.setItem(publishedScheduleStorageKey(context), scheduleId);
}

export function recoverPublishedSchedule(context: RunStorageContext) {
  if (typeof window === "undefined") return null;
  const key = publishedScheduleStorageKey(context);
  const scheduleId = window.localStorage.getItem(key);
  if (!scheduleId) return null;
  if (isValidStoredUuid(scheduleId)) return scheduleId;
  window.localStorage.removeItem(key);
  return null;
}

export function forgetPublishedSchedule(context: RunStorageContext) {
  if (typeof window === "undefined") return;
  window.localStorage.removeItem(publishedScheduleStorageKey(context));
}

export function isSolverRunTerminal(status: string) {
  return ["READY", "FAILED", "CANCELLED", "STALE_INPUT"].includes(status);
}

const STATUS_LABELS: Record<string, string> = {
  QUEUED: "Oczekuje na uruchomienie",
  RUNNING: "Trwa układanie grafiku",
  VALIDATING: "Końcowa kontrola reguł",
  READY: "Warianty są gotowe",
  CANCEL_REQUESTED: "Zatrzymywanie",
  CANCELLED: "Generowanie zatrzymane",
  FAILED: "Generowanie nie powiodło się",
  STALE_INPUT: "Konfiguracja firmy zmieniła się w trakcie obliczeń",
};

const PHASE_LABELS: Record<string, string> = {
  QUEUED: "Przygotowanie danych",
  RETRY_QUEUED: "Oczekiwanie na automatyczne ponowienie",
  CLAIMED: "Worker odebrał zadanie",
  STARTING: "Uruchamianie workera",
  LOADING: "Wczytywanie konfiguracji firmy",
  SNAPSHOT: "Zapisywanie konfiguracji użytej do obliczeń",
  MODEL: "Budowanie modelu grafiku",
  SOLVING: "Szukanie najlepszego rozwiązania",
  VALIDATING: "Sprawdzanie wyniku",
  SAVING: "Zapisywanie policzonych wariantów",
  SAVING_VARIANTS: "Zapisywanie policzonych wariantów",
  FINALIZING: "Końcowa kontrola i zamknięcie przebiegu",
  DATABASE_VALIDATION: "Końcowa kontrola spójności w bazie",
  MATERIALIZING: "Zapisywanie wariantów",
  READY: "Gotowe do porównania",
  FAILED: "Błąd generowania",
  STALE_INPUT: "Dane zmieniły się podczas generowania",
  CANCEL_REQUESTED: "Bezpieczne zatrzymywanie",
  CANCELLED: "Generowanie zatrzymane",
};

export function solverStatusLabel(status: string) {
  return STATUS_LABELS[status] ?? "Aktualizowanie stanu";
}

export function solverPhaseLabel(phase: string) {
  return PHASE_LABELS[phase] ?? "Przetwarzanie grafiku";
}

export function solverErrorMessage(message: string) {
  const normalized = message.toUpperCase();
  if (normalized.includes("STRATEGY_RESULT_DOMINATED")) return "Generator odrzucił wariant, ponieważ inny wynik był od niego lepszy we wszystkich celach tej strategii. Żaden mylący wariant nie został udostępniony. Uruchom generowanie ponownie; jeśli problem wróci, przekaż kod STRATEGY_RESULT_DOMINATED administratorowi UAT.";
  if (normalized.includes("UNFILLED_NOT_PROVEN")) return "Generator znalazł nieobsadzone miejsca, ale nie potwierdził jeszcze matematycznie, że nie da się ich obsadzić. Wynik nie został pokazany jako gotowy. Spróbuj ponownie; jeśli problem wróci, przekaż kod UNFILLED_NOT_PROVEN administratorowi UAT.";
  if (normalized.includes("OPTIMIZATION_INCOMPLETE")
    || (normalized.includes("ENDED INCOMPLETE") && normalized.includes("STATUS=FEASIBLE"))) {
    return "Silnik znalazł poprawny grafik, ale nie zdążył matematycznie potwierdzić, że nie istnieje lepszy układ. Konfiguracja użyta przez ten przebieg miała włączony tryb audytowy, dlatego wynik nie został zapisany. Do zwykłego planowania wyłącz „Tryb audytowy: wymagaj matematycznego dowodu optimum”, opublikuj konfigurację firmy i uruchom nowe generowanie.";
  }
  if (normalized.includes("RUN_VARIANTS_INCOMPLETE")) return "Końcowa kontrola wykryła, że nie zapisano wyniku dla każdej strategii. Przebieg nie zostanie opublikowany; szczegółowa przyczyna pozostaje w historii próby.";
  if (normalized.includes("RUN_REQUIRES_OPTIMAL_VARIANTS")) return "Konfiguracja wymaga matematycznego dowodu optimum, a co najmniej jeden wariant jest poprawny, lecz silnik nie potwierdził optimum w dostępnym czasie. Zwiększ limit czasu albo świadomie dopuść najlepsze znalezione rozwiązanie i uruchom ponownie.";
  if (normalized.includes("ROLE_PUBLICATION_CONFLICTS_WITH_EXISTING_STANDBY")) return "Nie można opublikować grafiku zespołu, ponieważ co najmniej jedna osoba jest już aktywowana jako rezerwa w tym samym dniu. Sprawdź aktywne zastępstwa w Operacje → Alerty, zakończ konflikt i ponów publikację.";
  if (normalized.includes("LEASE_LOST")) return "Worker utracił dzierżawę tego zadania. System nie zapisze wyniku z nieaktualnej próby; sprawdź, czy zadanie zostało automatycznie ponowione.";
  if (normalized.includes("SOLVER_CONFIGURATION_MISSING") || normalized.includes("SOLVER_ENGINE_CONFIGURATION_MISSING")) return "Nie ustawiono aktywnego silnika grafiku.";
  if (normalized.includes("SOLVER_ENGINE_INVALID") || normalized.includes("SOLVER_ENGINE_CONFIGURATION_INVALID")) return "Konfiguracja silnika zawiera nieobsługiwaną wartość.";
  if (normalized.includes("SOLVER_VERSION_CONFIGURATION_REQUIRED")) return "Konfiguracja nowego silnika nie wskazuje wersji obrazu workera. Generator pozostaje bezpiecznie zablokowany.";
  if (normalized.includes("RUN_REQUEST_ENGINE_MISMATCH") || normalized.includes("SHADOW_RUN_NOT_PUBLISHABLE")) return "Ten przebieg powstał w innym trybie silnika i nie może zostać użyty produkcyjnie. Uruchom nowe generowanie w bieżącym trybie.";
  if (normalized.includes("RUN_SOLVER_VERSION_MISMATCH") || normalized.includes("RUN_REFERENCE_MISMATCH")) return "Zapisany przebieg pochodzi z innej wersji generatora. Uruchom nowe generowanie na aktualnej wersji.";
  if (normalized.includes("SOLVER_DISABLED")) return "Generator grafiku jest obecnie wyłączony.";
  if (normalized.includes("ORTOOLS_REQUEST_DISABLED") || normalized.includes("ORTOOLS_SELECTION_DISABLED") || normalized.includes("ORTOOLS_PUBLICATION_DISABLED")) return "Nowy silnik nie jest aktywny dla tej operacji. Alpha 15 i tryb cienia pozostają bezpiecznie odseparowane.";
  if (normalized.includes("SOLVER_MATRIX_V2_UNPUBLISHED")) return "Konfiguracja firmy dla wybranego miesiąca nie została opublikowana. Przejdź do Ustawienia → Kontrola gotowości, usuń wskazane blokady i opublikuj wersję roboczą.";
  if (normalized.includes("SOLVER_MATRIX_V2_MISSING") || normalized.includes("MATRIX_V2_FOR_MONTH_NOT_FOUND")) return "Brakuje opublikowanej konfiguracji firmy dla wybranego miesiąca. Przejdź do Ustawienia, wybierz ten miesiąc i dokończ publikację konfiguracji.";
  if (normalized.includes("SOLVER_CONFIGURATION_UNAVAILABLE")) return "Nie udało się odczytać konfiguracji dla wybranego miesiąca. Przejdź do Ustawienia → Kontrola gotowości i sprawdź wskazane blokady; jeśli konfiguracja jest opublikowana, odśwież dane.";
  if (normalized.includes("SOLVER_TIMEZONE_MISSING") || normalized.includes("SOLVER_TIMEZONE_INVALID")) return "W opublikowanej konfiguracji firmy brakuje prawidłowej strefy czasowej.";
  if (normalized.includes("INVALID_SOLVER_CURRENCY")) return "W opublikowanej konfiguracji firmy brakuje prawidłowej waluty rozliczeniowej.";
  if (normalized.includes("SOLVER_MATRIX_SETTINGS_INVALID")) return "Opublikowana konfiguracja firmy nie ma kompletnych reguł bezpieczeństwa generatora.";
  if (normalized.includes("SOLVER_DEFAULT_SCENARIO_INVALID")) return "Konfiguracja firmy musi mieć dokładnie jeden domyślny profil zapotrzebowania.";
  if (normalized.includes("SOLVER_SCENARIOS_MISSING")) return "Konfiguracja firmy nie zawiera profili zapotrzebowania.";
  if (normalized.includes("SOLVER_STRATEGIES_MISSING")) return "Konfiguracja firmy nie zawiera wariantów biznesowych.";
  if (normalized.includes("SOLVER_SCENARIO_STRATEGIES_MISSING")) return "Każdy aktywny scenariusz musi mieć co najmniej jedną aktywną strategię.";
  if (normalized.includes("SOLVER_ROLES_MISSING")) return "Opublikowana konfiguracja firmy nie zawiera ról pracowników.";
  if (normalized.includes("SOLVER_LOCATIONS_MISSING")) return "Opublikowana konfiguracja firmy nie zawiera lokali.";
  if (normalized.includes("VARIANT_STRATEGY_MISSING") || normalized.includes("VARIANT_STRATEGY_INVALID") || normalized.includes("ROLE_COMPOSITE_STRATEGY")) return "Odpowiedź generatora nie zawiera prawidłowej strategii wariantu. Odśwież dane przed kontynuacją.";
  if (normalized.includes("COMPANY_PUBLICATION_FORBIDDEN")) return "Tylko właściciel lub administrator może opublikować grafik całej firmy.";
  if (normalized.includes("WARNING_REASON_REQUIRED")) return "Publikacja z brakami obsady wymaga podania powodu decyzji.";
  if (normalized.includes("ROLE_COMPOSITE_CRITICAL_GAPS")) return "Scalony grafik zawiera dzień, w którym dla wymaganej roli nie obsadzono nikogo. Otwórz kontrolę braków, wybierz działanie i dopiero potem świadomie potwierdź publikację.";
  if (normalized.includes("PLAN_NOT_READY")) return "Grafik nie jest gotowy do publikacji. Rozwiń listę blokad i przejdź do wskazanych alertów.";
  if (normalized.includes("PUBLICATION_INPUT_CHANGED")) return "Dane firmy zmieniły się od czasu generowania. Uruchom nowy grafik przed publikacją.";
  if (normalized.includes("SELECTED_COMPANY_VARIANT_REQUIRED")) return "Przed publikacją wybierz poprawny wariant grafiku całej firmy.";
  if (normalized.includes("COMPANY_RUN_NOT_READY")) return "Ten grafik nie jest jeszcze gotowy do publikacji.";
  if (normalized.includes("EMERGENCY_ASSIGNMENT_HARD_BLOCK")) return "Tego pracownika nie można dopisać: naruszyłoby to twardą regułę. Rozwiń diagnostykę kandydata.";
  if (normalized.includes("LEADER_VARIANT_NOT_EDITABLE") || normalized.includes("LEADER_VARIANT_NOT_FOUND")) return "Wersja lidera nie jest już edytowalna. Utwórz świeżą kopię z jednego z trzech wygenerowanych wariantów.";
  if (normalized.includes("LEADER_VARIANT_FORBIDDEN")) return "Nie masz uprawnień do przygotowania wersji lidera dla tego zespołu.";
  if (normalized.includes("EDIT_REASON_REQUIRED")) return "Krótko opisz powód ręcznej zmiany. Zapiszemy go w historii wersji lidera.";
  if (normalized.includes("LOCKED_ASSIGNMENT_CANNOT_BE_REMOVED")) return "Tego przydziału nie można usunąć, ponieważ pochodzi z twardo zablokowanej decyzji.";
  if (normalized.includes("ASSIGNMENT_NOT_FOUND") || normalized.includes("UNFILLED_ISSUE_NOT_FOUND")) return "Wybrane miejsce zmieniło się. Odśwież wersję lidera i spróbuj ponownie.";
  if (normalized.includes("VARIANT_HARD_BLOCK_INVALID")) return "Nie można zapisać tej osoby: w godzinach zmiany ma twardą niedostępność, urlop albo L4. Wersja lidera nie została zmieniona — wybierz inną osobę lub popraw dostępność z zachowaniem historii publikacji.";
  if (normalized.includes("VARIANT_AVAILABILITY_INVALID")) return "Nie można zapisać tej osoby: podane godziny nie mieszczą się w jej dostępności. Wersja lidera nie została zmieniona — wybierz inną osobę albo sprawdź kalendarz dostępności.";
  if (normalized.includes("VARIANT_OVERLAP_OR_REST_INVALID")) return "Nie można zapisać tej osoby: powstałoby nakładanie zmian albo zbyt krótki odpoczynek między nimi. Wersja lidera nie została zmieniona.";
  if (normalized.includes("VARIANT_MULTIPLE_PRIMARY_SHIFTS_PER_DAY_INVALID")) return "Nie można zapisać tej osoby: osiągnęła dzienny limit zmian ustawiony w konfiguracji firmy. Wersja lidera nie została zmieniona.";
  if (normalized.includes("VARIANT_CONSECUTIVE_SHIFT_SEQUENCE_INVALID")) return "Nie można zapisać tej osoby: powstałaby niedozwolona sekwencja ostatniej zmiany dnia i pierwszej zmiany następnego dnia. Wersja lidera nie została zmieniona.";
  if (normalized.includes("LEADER_LIMIT_OVERRIDE_REQUIRED")) return "Ta zmiana przekroczy tygodniowy lub miesięczny limit pracownika. Lider może zapisać ją wyłącznie jako świadomy wyjątek z podanym powodem.";
  if (normalized.includes("VARIANT_WORK_LIMIT_INVALID") || normalized.includes("VARIANT_CONSECUTIVE_DAYS_INVALID")) return "Nie można zapisać tej osoby: przekroczyłaby limit pracy zapisany w konfiguracji firmy lub pracownika. Wersja lidera nie została zmieniona.";
  if (normalized.includes("VARIANT_EMPLOYEE_ELIGIBILITY_INVALID")) return "Nie można zapisać tej osoby: nie spełnia wymagań roli, lokalu, obowiązku, umowy albo aktywnej stawki dla tej zmiany. Wersja lidera nie została zmieniona.";
  if (normalized.includes("VARIANT_HARD_BUDGET_INVALID")) return "Nie można zapisać korekty: przekroczyłaby twardy budżet grafiku. Wersja lidera nie została zmieniona.";
  if (normalized.includes("VARIANT_MATERIALIZATION_HASH_MISMATCH") || normalized.includes("VARIANT_HAS_HARD_VIOLATIONS")) return "Ręczna zmiana nie przeszła kontroli całego grafiku i nie została zapisana.";
  if (normalized.includes("STANDBY_REVALIDATION_FAILED")) return "Nie można aktywować tej osoby z rezerwy, ponieważ od publikacji zmieniła się jej dostępność albo aktywacja naruszyłaby twardą regułę. Odśwież rezerwę i wybierz inną osobę.";
  if (normalized.includes("STANDBY_TIER_1_MUST_BE_USED_OR_DECLINED_FIRST")) return "Najpierw użyj albo odrzuć pierwszą osobę rezerwową. Druga rezerwa jest uruchamiana dopiero w kolejnym kroku.";
  if (normalized.includes("SOFT_OVERRIDE_REASON_REQUIRED")) return "Awaryjne naruszenie miękkiej reguły wymaga potwierdzenia i podania powodu.";
  if (normalized.includes("SLOT_ALREADY_FILLED")) return "To brakujące miejsce zostało już obsadzone. Odśwież grafik operacyjny.";
  if (normalized.includes("CANDIDATE_NOT_FOUND")) return "Wybrany pracownik nie jest już kandydatem do tej zmiany. Odśwież listę.";
  if (normalized.includes("INVALID_PLAN_NAME")) return "Podaj nazwę publikowanego grafiku.";
  if (normalized.includes("PUBLICATION_FAILED")) return "Publikacja nie została zapisana. Odśwież diagnostykę gotowości i spróbuj ponownie.";
  if (normalized.includes("SELECTED_VALID_ROLE_VARIANT_REQUIRED")) return "Wersja lidera nie została zatwierdzona jako wariant do publikacji. System spróbuje zatwierdzić ją automatycznie przy ponownej publikacji.";
  if (normalized.includes("SCHEDULE_ID_MISSING")) return "Publikacja nie zwróciła identyfikatora grafiku. Odśwież widok przed ponowną próbą.";
  if (normalized.includes("SCHEDULE_ID_INVALID")) return "Publikacja zwróciła nieprawidłowy identyfikator grafiku. Odśwież widok przed ponowną próbą.";
  if (normalized.includes("SELECTED_VARIANT_NOT_FOUND")) return "Nie znaleziono wybranego wariantu. Wybierz wariant ponownie.";
  if (normalized.includes("PUBLISHED_SCHEDULE_NOT_FOUND")) return "Nie znaleziono opublikowanego grafiku lub nie masz do niego dostępu.";
  if (normalized.includes("COMPOSITE_PUBLICATION_FORBIDDEN")) return "Tylko właściciel lub administrator może opublikować scalony grafik ról.";
  if (normalized.includes("ROLE_VARIANTS_INCOMPLETE")) return "Nie wszystkie wymagane role mają wybrany wariant.";
  if (normalized.includes("ROLE_VARIANT_SET_CHANGED")) return "Zestaw wybranych wariantów ról zmienił się. Odśwież listę przed publikacją.";
  if (normalized.includes("ONE_SELECTED_ROLE_VARIANT_PER_ROLE_REQUIRED")) return "Każda wymagana rola musi mieć dokładnie jeden aktualnie wybrany wariant.";
  if (normalized.includes("ROLE_VARIANTS_SCOPE_MISMATCH")) return "Wybrane warianty nie należą do tego samego miesiąca i scenariusza. Odśwież zestaw.";
  if (normalized.includes("DUPLICATE_OR_NULL_VARIANT")) return "Zestaw ról zawiera nieprawidłowy wariant. Odśwież listę przed publikacją.";
  if (normalized.includes("INVALID_VARIANT_SET")) return "Zestaw wariantów ról jest niekompletny. Odśwież listę i spróbuj ponownie.";
  if (normalized.includes("FORBIDDEN")) return "Nie masz uprawnień do uruchomienia generatora.";
  if (normalized.includes("RUN_NOT_FOUND")) return "Nie znaleziono tego przebiegu lub nie masz do niego dostępu.";
  if (normalized.includes("RUN_ID_MISSING")) return "Generator nie zwrócił identyfikatora przebiegu.";
  if (normalized.includes("RUN_ID_INVALID")) return "Generator zwrócił nieprawidłowy identyfikator przebiegu.";
  if (normalized.includes("SCENARIO")) return "Wybrany profil zapotrzebowania nie jest już aktywny. Odśwież konfigurację firmy i wybierz ponownie.";
  if (normalized.includes("STALE")) return "Konfiguracja firmy zmieniła się w trakcie obliczeń. Uruchom nowy wariant na aktualnych danych.";
  if (normalized.includes("RUN_ALREADY_CLAIMED")
    || normalized.includes("RUN_CLAIM_CONFLICT")
    || normalized.includes("DISPATCH_CONFLICT")
    || normalized.includes("HTTP 409")) {
    return "Inny worker kontynuuje ten przebieg. Postęp zostanie odświeżony automatycznie.";
  }
  const technicalCode = normalized.match(/(?:RPC_[A-Z0-9_]+|PGRST\d+|[A-Z][A-Z0-9_]{5,})/)?.[0] ?? "NIEZNANY_BŁĄD_RPC";
  return `Operacja nie została zapisana. Kod techniczny: ${technicalCode}. Odśwież dane i spróbuj ponownie; jeśli błąd wróci, przekaż ten kod administratorowi UAT.`;
}

