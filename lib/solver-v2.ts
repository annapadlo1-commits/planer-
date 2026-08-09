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

export type SolverRole = { id: string; code: string; name: string };
export type SolverLocation = { id: string; code: string; name: string };

export type SolverConfiguration = {
  engine: SolverEngine;
  enabled: boolean;
  solverVersion: string | null;
  matrixVersionId: string | null;
  matrixEffectiveFrom: string | null;
  scenarios: SolverScenario[];
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
  return Number.isFinite(value) ? value : null;
}

function normalizeNamedEntity(value: unknown, fallbackName = "") {
  const source = record(value);
  return {
    id: String(valueOf(source, "id", "id", "")),
    name: String(valueOf(source, "name", "name", fallbackName)),
  };
}

function normalizeWorkspaceFinance(value: unknown): SolverWorkspaceFinance | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const source = record(value);
  return {
    baseCostMinor: numberOf(source, "baseCostMinor", "base_cost_minor"),
    additionsCostMinor: numberOf(source, "additionsCostMinor", "additions_cost_minor"),
    totalCostMinor: numberOf(source, "totalCostMinor", "total_cost_minor"),
    budgetMinor: nullableNumberOf(source, "budgetMinor", "budget_minor"),
    currency: solverCurrency(source.currency),
  };
}

function normalizeWorkspaceVariant(value: unknown): SolverWorkspaceVariant {
  const source = record(value);
  const scope = record(source.scope);
  const rawRole = scope.role;
  if (!source.strategy) throw new Error("WORKSPACE_VARIANT_STRATEGY_MISSING");
  const strategy = normalizeNamedEntity(source.strategy);
  if (!strategy.id || !strategy.name) throw new Error("WORKSPACE_VARIANT_STRATEGY_INVALID");
  return {
    id: String(valueOf(source, "id", "id", "")),
    runId: String(valueOf(source, "runId", "run_id", "")),
    name: String(valueOf(source, "name", "name", "Wariant")),
    status: String(valueOf(source, "status", "status", "READY")),
    recommended: Boolean(valueOf(source, "recommended", "recommended", false)),
    selected: Boolean(valueOf(source, "selected", "selected", false)),
    strategy,
    scope: {
      type: valueOf<SolverScope>(scope, "type", "type", "COMPANY"),
      role: rawRole ? normalizeNamedEntity(rawRole) : null,
    },
    assignmentCount: numberOf(source, "assignmentCount", "assignment_count"),
    unfilledCount: numberOf(source, "unfilledCount", "unfilled_count"),
    solverStatus: String(valueOf(source, "solverStatus", "solver_status", "FEASIBLE")),
    finance: normalizeWorkspaceFinance(source.finance),
  };
}

function normalizeWorkspaceAssignment(value: unknown): SolverWorkspaceAssignment {
  const source = record(value);
  const employee = record(source.employee);
  const duties = Array.isArray(source.duties) ? source.duties : [];
  return {
    id: String(valueOf(source, "id", "id", "")),
    slotKey: String(valueOf(source, "slotKey", "slot_key", "")),
    employee: {
      id: String(valueOf(employee, "id", "id", "")),
      employeeNo: String(valueOf(employee, "employeeNo", "employee_no", "")),
      firstName: String(valueOf(employee, "firstName", "first_name", "")),
      lastName: String(valueOf(employee, "lastName", "last_name", "")),
      nominalMonthlyMinutes: numberOf(employee, "nominalMonthlyMinutes", "nominal_monthly_minutes"),
    },
    role: normalizeNamedEntity(source.role, "Rola"),
    duties: duties.map(item => normalizeNamedEntity(item, "Obowiązek")),
    locked: Boolean(valueOf(source, "locked", "locked", false)),
    costMinor: source.costMinor === null || source.cost_minor === null
      ? null
      : numberOf(source, "costMinor", "cost_minor"),
  };
}

function normalizeWorkspaceShift(value: unknown): SolverWorkspaceShift {
  const source = record(value);
  const location = record(source.location);
  const assignments = Array.isArray(source.assignments) ? source.assignments : [];
  return {
    id: String(valueOf(source, "id", "id", "")),
    slotGroupKey: String(valueOf(source, "slotGroupKey", "slot_group_key", "")),
    date: String(valueOf(source, "date", "date", "")),
    startsAt: String(valueOf(source, "startsAt", "starts_at", "")),
    endsAt: String(valueOf(source, "endsAt", "ends_at", "")),
    location: {
      ...normalizeNamedEntity(source.location, "Lokal"),
      timezone: String(valueOf(location, "timezone", "timezone", "")).trim() || null,
    },
    shiftTemplate: normalizeNamedEntity(source.shiftTemplate, "Zmiana"),
    assignments: assignments.map(normalizeWorkspaceAssignment),
  };
}

function normalizeWorkspaceIssue(value: unknown): SolverWorkspaceIssue {
  const source = record(value);
  const shift = record(source.shift);
  const shiftLocation = record(shift.location);
  const shiftTemplate = record(shift.shiftTemplate);
  const code = String(valueOf(source, "code", "issue_code", "UNFILLED"));
  const rawMessage = String(valueOf(source, "message", "message", "Nieobsadzone miejsce"));
  return {
    id: String(valueOf(source, "id", "id", "")),
    variantId: String(valueOf(source, "variantId", "variant_id", "")),
    slotKey: valueOf<string | null>(source, "slotKey", "slot_key", null),
    code,
    severity: String(valueOf(source, "severity", "severity", "WARNING")),
    message: code === "UNFILLED_SLOT"
      ? "Nieobsadzone miejsce w wymaganej obsadzie."
      : rawMessage.replace(/Matrix/gi,"konfiguracja firmy"),
    requiredCount: nullableNumberOf(source, "requiredCount", "required_count"),
    assignedCount: nullableNumberOf(source, "assignedCount", "assigned_count"),
    role: source.role ? normalizeNamedEntity(source.role) : null,
    duty: source.duty ? normalizeNamedEntity(source.duty) : null,
    shift: source.shift ? {
      id: String(valueOf(shift,"id","id","")),
      date: String(valueOf(shift,"date","shift_date","")),
      startsAt: String(valueOf(shift,"startsAt","starts_at","")),
      endsAt: String(valueOf(shift,"endsAt","ends_at","")),
      location: {
        ...normalizeNamedEntity(shift.location,"Lokal"),
        timezone:String(valueOf(shiftLocation,"timezone","timezone","")).trim()||null,
      },
      shiftTemplate: {
        ...normalizeNamedEntity(shift.shiftTemplate,"Zmiana"),
        shiftPeriod:String(valueOf(shiftTemplate,"shiftPeriod","shift_period","")).trim()||undefined,
      },
    }:null,
  };
}

function normalizeWorkspace(value: unknown): SolverWorkspace {
  const payload = record(value);
  const context = record(payload.context);
  const scenario = normalizeNamedEntity(context.scenario, "Scenariusz"),
    variants = Array.isArray(payload.variants) ? payload.variants : [],
    shifts = Array.isArray(payload.shifts) ? payload.shifts : [],
    issues = Array.isArray(payload.issues) ? payload.issues : [];
  return {
    context: {
      type: String(valueOf(context, "type", "type", "SELECTED_VARIANT")),
      engine: valueOf<SolverEngine | undefined>(context, "engine", "engine", valueOf<SolverEngine | undefined>(payload, "engine", "engine", undefined)),
      runId: valueOf<string | undefined>(context, "runId", "run_id", undefined),
      scheduleId: valueOf<string | undefined>(context, "scheduleId", "schedule_id", undefined),
      sourceType: valueOf<string | undefined>(context, "sourceType", "source_type", undefined),
      name: String(valueOf(context, "name", "name", "Grafik")),
      status: valueOf<string | undefined>(context, "status", "status", undefined),
      month: String(valueOf(context, "month", "month", "")),
      scenario,
      matrixVersionId: String(valueOf(context, "matrixVersionId", "matrix_version_id", "")),
      publishedAt: valueOf<string | null | undefined>(context, "publishedAt", "published_at", undefined),
      archivedAt: valueOf<string | null | undefined>(context, "archivedAt", "archived_at", undefined),
      variantKind: valueOf<"GENERATED" | "LEADER_COPY" | undefined>(context, "variantKind", "variant_kind", undefined),
      sourceVariantId: valueOf<string | null | undefined>(context, "sourceVariantId", "source_variant_id", undefined),
      revision: Number(valueOf(context, "revision", "revision", 0)),
      lastEditedAt: valueOf<string | null | undefined>(context, "lastEditedAt", "last_edited_at", undefined),
    },
    variants: variants.map(normalizeWorkspaceVariant),
    shifts: shifts.map(normalizeWorkspaceShift),
    issues: issues.map(normalizeWorkspaceIssue),
    finance: normalizeWorkspaceFinance(payload.finance),
  };
}

function normalizeRoleCompositeVariant(value: unknown, containerValue?: unknown): SolverRoleCompositeVariant | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const source = record(value);
  const container = record(containerValue);
  const run = record(container.run);
  if (!source.strategy) throw new Error("ROLE_COMPOSITE_STRATEGY_MISSING");
  const strategy = normalizeNamedEntity(source.strategy);
  if (!strategy.id || !strategy.name) throw new Error("ROLE_COMPOSITE_STRATEGY_INVALID");
  return {
    id: String(valueOf(source, "id", "id", "")),
    runId: String(valueOf(source, "runId", "run_id", valueOf(run, "id", "id", ""))),
    name: String(valueOf(source, "name", "name", "Wariant roli")),
    strategy,
    assignmentCount: numberOf(source, "assignmentCount", "assignment_count"),
    unfilledCount: numberOf(source, "unfilledCount", "unfilled_count"),
    solverStatus: String(valueOf(source, "solverStatus", "solver_status", "FEASIBLE")),
  };
}

function normalizeRoleCompositeCandidates(value: unknown): SolverRoleCompositeCandidates {
  const payload = record(value);
  const roles = Array.isArray(payload.roles) ? payload.roles : [];
  const missingRoles = Array.isArray(payload.missingRoleIds)
    ? payload.missingRoleIds
    : Array.isArray(payload.missing_role_ids)
      ? payload.missing_role_ids
      : Array.isArray(payload.missingRoles) ? payload.missingRoles : [];
  return {
    month: String(valueOf(payload, "month", "month", "")),
    scenario: normalizeNamedEntity(payload.scenario, "Scenariusz"),
    roles: roles.map(item => {
      const source = record(item);
      const role = source.role ? record(source.role) : source;
      return {
        id: String(valueOf(source, "id", "id", valueOf(role, "id", "id", ""))),
        name: String(valueOf(source, "name", "name", valueOf(role, "name", "name", "Rola"))),
        sortOrder: numberOf(source, "sortOrder", "sort_order", numberOf(role, "sortOrder", "sort_order")),
        variant: normalizeRoleCompositeVariant(source.variant, source),
      };
    }).sort((left, right) => left.sortOrder - right.sortOrder || left.name.localeCompare(right.name, "pl")),
    missingRoleIds: missingRoles.map(item => {
      const source = record(item);
      return source.id ? String(source.id) : String(item);
    }),
    ready: Boolean(valueOf(payload, "ready", "ready", false)),
  };
}

function normalizeRun(value: unknown): SolverRun {
  const payload = record(value);
  const run = record(payload.run ?? payload);
  return {
    id: String(valueOf(run, "id", "id", "")),
    requestEngine: valueOf<Exclude<SolverEngine, "ALPHA15"> | undefined>(
      run,
      "requestEngine",
      "request_engine",
      undefined,
    ),
    solverVersion: valueOf<string | undefined>(
      run,
      "solverVersion",
      "solver_version",
      undefined,
    ),
    status: String(valueOf(run, "status", "status", "QUEUED")),
    phase: String(valueOf(run, "phase", "phase", "QUEUED")),
    progress: Math.min(100, Math.max(0, numberOf(run, "progress", "progress"))),
    month: valueOf<string | undefined>(run, "month", "month", undefined),
    scopeType: valueOf<SolverScope | undefined>(run, "scopeType", "scope_type", undefined),
    scopeRoleId: valueOf<string | null | undefined>(run, "scopeRoleId", "scope_role_id", undefined),
    failureMessage: valueOf<string | null | undefined>(run, "failureMessage", "failure_message", undefined),
    updatedAt: valueOf<string | undefined>(run, "updatedAt", "updated_at", undefined),
  };
}

function normalizeStrategy(value: unknown): SolverStrategyProgress {
  const source = record(value);
  const strategy = record(source.strategy);
  return {
    id: String(valueOf(source, "id", "id", valueOf(strategy, "id", "id", ""))),
    name: String(valueOf(source, "name", "name", valueOf(strategy, "name", "name", "Wariant"))),
    status: String(valueOf(source, "status", "status", "QUEUED")),
    phase: String(valueOf(source, "phase", "phase", "QUEUED")),
    progress: Math.min(100, Math.max(0, numberOf(source, "progress", "progress"))),
  };
}

function normalizeVariant(value: unknown): SolverVariant {
  const source = record(value);
  if (!source.strategy) throw new Error("VARIANT_STRATEGY_MISSING");
  const strategy = record(source.strategy);
  const strategyId = String(valueOf(strategy, "id", "id", ""));
  const strategyName = String(valueOf(strategy, "name", "name", ""));
  if (!strategyId || !strategyName) throw new Error("VARIANT_STRATEGY_INVALID");
  const metrics = record(valueOf(source, "metrics", "metrics", {}));
  const cost = source.totalCostMinor ?? source.total_cost_minor;
  const budget = source.budgetMinor ?? source.budget_minor;
  const finance = record(source.finance);
  return {
    id: String(valueOf(source, "id", "id", "")),
    name: String(valueOf(source, "name", "name", valueOf(strategy, "name", "name", "Wariant"))),
    strategy: {
      id: strategyId,
      name: strategyName,
      description: valueOf<string | undefined>(strategy, "description", "description", undefined),
    },
    status: String(valueOf(source, "status", "status", "READY")),
    hardViolations: numberOf(source, "hardViolations", "hard_violations"),
    assignmentCount: numberOf(source, "assignmentCount", "assignment_count"),
    unfilledCount: numberOf(source, "unfilledCount", "unfilled_count"),
    totalCostMinor: cost === undefined || cost === null ? null : Number(cost),
    budgetMinor: budget === undefined || budget === null ? null : Number(budget),
    currency: solverCurrency(
      source.currency ?? finance.currency,
      (cost !== undefined && cost !== null) || (budget !== undefined && budget !== null),
    ),
    solverStatus: String(valueOf(source, "solverStatus", "solver_status", "FEASIBLE")),
    recommended: Boolean(valueOf(source, "recommended", "recommended", false)),
    selected: Boolean(valueOf(source, "selected", "selected", false)),
    equivalentToVariantId: valueOf<string | null | undefined>(source, "equivalentToVariantId", "equivalent_to_variant_id", undefined),
    metrics,
  };
}

async function rpc(client: SupabaseClient, name: string, args: Record<string, unknown>) {
  const result = await client.rpc(name, args);
  if (result.error) {
    const parts = [
      `RPC_${name.toUpperCase()}`,
      result.error.code,
      result.error.message,
      result.error.details,
      result.error.hint,
    ].filter(value => Boolean(String(value ?? "").trim()));
    console.error("[GRAFIK PRO UAT RPC]", JSON.stringify({ name, code: result.error.code, message: result.error.message, details: result.error.details, hint: result.error.hint }));
    throw new Error(parts.join(":"));
  }
  return result.data as unknown;
}

export async function loadSolverConfiguration(
  client: SupabaseClient,
  month: string,
): Promise<SolverConfiguration> {
  const monthStart = /^\d{4}-\d{2}(-\d{2})?$/.test(month)
    ? `${month.slice(0, 7)}-01`
    : "";
  if (!monthStart) throw new Error("SOLVER_MONTH_INVALID");
  let configurationPayload: Record<string, unknown>;
  try {
    configurationPayload = record(await rpc(client, "optimizer_configuration_v2", {
      p_month: monthStart,
    }));
  } catch (cause) {
    throw new Error(`SOLVER_CONFIGURATION_UNAVAILABLE:${cause instanceof Error ? cause.message : String(cause)}`);
  }
  const enabled = Boolean(configurationPayload.enabled);
  const rawEngine = String(configurationPayload.engine ?? "");
  if (!["ALPHA15", "ORTOOLS_V2", "SHADOW"].includes(rawEngine)) {
    throw new Error("SOLVER_ENGINE_INVALID");
  }
  if (!enabled) throw new Error("SOLVER_DISABLED");
  const engine = rawEngine as SolverEngine;
  if (engine === "ALPHA15") {
    return {
      engine,
      enabled,
      solverVersion: null,
      matrixVersionId: null,
      matrixEffectiveFrom: null,
      scenarios: [LEGACY_DEFAULT_SCENARIO],
      roles: [],
      locations: [],
      currency: null,
      timezone: null,
    };
  }

  const solverVersion = String(configurationPayload.solverVersion ?? "").trim();
  if (!solverVersion) throw new Error("SOLVER_VERSION_CONFIGURATION_REQUIRED");

  const matrixVersion = record(configurationPayload.matrixVersion);
  const activeMatrixId = String(matrixVersion.id ?? "") || null;
  if (!activeMatrixId || Number(matrixVersion.schemaVersion ?? 0) < 2) {
    throw new Error("SOLVER_MATRIX_V2_MISSING");
  }
  if (
    !/^[0-9a-f]{64}$/.test(String(matrixVersion.contentHash ?? ""))
    || !/^[0-9a-f]{64}$/.test(String(matrixVersion.workforceHash ?? ""))
  ) throw new Error("SOLVER_MATRIX_V2_UNPUBLISHED");
  const settings = record(matrixVersion.settings);
  const currency = solverCurrency(settings.currency);
  const timezone = String(settings.timezone ?? "").trim();
  if (!timezone) throw new Error("SOLVER_TIMEZONE_MISSING");
  try { new Intl.DateTimeFormat("en", { timeZone: timezone }).format(new Date(0)); }
  catch { throw new Error("SOLVER_TIMEZONE_INVALID"); }
  const minimumRestMinutes = Number(settings.minimumRestMinutes);
  const maximumShiftsPerDay = Number(settings.maximumShiftsPerDay ?? settings.maxShiftsPerDay);
  if (
    !Number.isInteger(minimumRestMinutes) || minimumRestMinutes < 0
    || !Number.isInteger(maximumShiftsPerDay) || maximumShiftsPerDay < 1 || maximumShiftsPerDay > 24
    || typeof settings.missingAvailabilityMeansAvailable !== "boolean"
    || typeof settings.requireOptimal !== "boolean"
  ) throw new Error("SOLVER_MATRIX_SETTINGS_INVALID");

  const profilePayload = record(await rpc(client, "optimizer_demand_profiles_uat_v1", {
    p_month: monthStart,
  }));
  const profileRows = Array.isArray(profilePayload.profiles) ? profilePayload.profiles : [];
  const profilesById = new Map(profileRows.map(value => {
    const item = record(value);
    return [String(item.id ?? ""), {
      validFrom: item.validFrom ? String(item.validFrom) : null,
      validTo: item.validTo ? String(item.validTo) : null,
      profileMode: String(item.profileMode ?? "UNDATED_LEGACY"),
    }] as const;
  }));

  const scenarioResult = { data: (Array.isArray(configurationPayload.scenarios)
    ? configurationPayload.scenarios : []).map(value => {
      const item = record(value);
      return {
        id: String(item.id ?? ""), code: String(item.code ?? ""),
        name: String(item.name ?? ""), description: item.description ? String(item.description) : null,
        is_default: Boolean(item.isDefault), sort_order: Number(item.sortOrder ?? 0),
        parent_scenario_id: item.parentScenarioId ? String(item.parentScenarioId) : null,
        available: Boolean(item.available),
      };
    }) };
  const roleResult = { data: (Array.isArray(configurationPayload.roles)
    ? configurationPayload.roles : []).map(value => {
      const item = record(value);
      return { id: String(item.id ?? ""), code: String(item.code ?? ""), name: String(item.name ?? "") };
    }) };
  const locationResult = { data: (Array.isArray(configurationPayload.locations)
    ? configurationPayload.locations : []).map(value => {
      const item = record(value);
      return { id: String(item.id ?? ""), code: String(item.code ?? ""), name: String(item.name ?? "") };
    }) };
  const strategyResult = { data: (Array.isArray(configurationPayload.strategies)
    ? configurationPayload.strategies : []).map(value => ({ id: String(record(value).id ?? "") })) };
  const linksResult = { data: (Array.isArray(configurationPayload.scenarioStrategies)
    ? configurationPayload.scenarioStrategies : []).map(value => {
      const item = record(value);
      return {
        scenario_id: String(item.scenarioId ?? ""), strategy_id: String(item.strategyId ?? ""),
        active: Boolean(item.active),
      };
    }) };
  const activeStrategyIds = new Set((strategyResult.data ?? []).map(item => item.id));
  if (!activeStrategyIds.size) throw new Error("SOLVER_STRATEGIES_MISSING");
  const scenarioRows = scenarioResult.data ?? [];
  const scenarioById = new Map(scenarioRows.map(item => [item.id, item]));
  const linksByScenario = new Map<string, typeof linksResult.data>();
  for (const link of linksResult.data ?? []) {
    const links = linksByScenario.get(link.scenario_id) ?? [];
    links.push(link);
    linksByScenario.set(link.scenario_id, links);
  }
  const strategyCounts = new Map<string, number>();
  for (const scenario of scenarioRows) {
    const resolved = new Map<string, boolean>();
    const visited = new Set<string>();
    let current: typeof scenario | undefined = scenario;
    let depth = 0;
    while (current) {
      if (depth > 32 || visited.has(current.id)) {
        throw new Error("SOLVER_SCENARIO_INHERITANCE_INVALID");
      }
      visited.add(current.id);
      for (const link of linksByScenario.get(current.id) ?? []) {
        if (!resolved.has(link.strategy_id)) {
          resolved.set(link.strategy_id, Boolean(link.active));
        }
      }
      if (!current.parent_scenario_id) break;
      current = scenarioById.get(current.parent_scenario_id);
      if (!current) throw new Error("SOLVER_SCENARIO_PARENT_MISSING");
      depth += 1;
    }
    strategyCounts.set(
      scenario.id,
      [...resolved].filter(([strategyId, active]) => (
        active && activeStrategyIds.has(strategyId)
      )).length,
    );
  }
  const scenarios: SolverScenario[] = scenarioRows.filter(item => {
    const profile = profilesById.get(item.id);
    return item.available && (item.is_default || profile?.profileMode === "PERIOD");
  }).map(item => {
    const profile = profilesById.get(item.id);
    return ({
    id: item.id,
    code: item.code,
    name: item.name,
    description: item.description ?? undefined,
    strategyCount: strategyCounts.get(item.id) ?? 0,
    isDefault: Boolean(item.is_default),
    validFrom: profile?.validFrom ?? null,
    validTo: profile?.validTo ?? null,
    profileMode: item.is_default ? "BASELINE" : "PERIOD",
  });
  });
  if (!scenarios.length) throw new Error("SOLVER_SCENARIOS_MISSING");
  if (scenarios.filter(scenario => scenario.isDefault).length !== 1) {
    throw new Error("SOLVER_DEFAULT_SCENARIO_INVALID");
  }
  if (scenarios.some(scenario => scenario.strategyCount === 0)) {
    throw new Error("SOLVER_SCENARIO_STRATEGIES_MISSING");
  }
  const roles = (roleResult.data ?? []).map(item => ({ id: item.id, code: item.code, name: item.name }));
  if (!roles.length) throw new Error("SOLVER_ROLES_MISSING");
  const locations = (locationResult.data ?? []).map(item => ({ id: item.id, code: item.code, name: item.name }));
  if (!locations.length) throw new Error("SOLVER_LOCATIONS_MISSING");
  return {
    engine,
    enabled,
    solverVersion,
    matrixVersionId: activeMatrixId,
    matrixEffectiveFrom: String(matrixVersion.effectiveFrom??"")||null,
    scenarios,
    roles,
    locations,
    currency,
    timezone,
  };
}

export async function requestSolverRun(
  client: SupabaseClient,
  input: {
    month: string;
    scenarioId: string;
    scopeType: SolverScope;
    scopeRoleId?: string | null;
    name: string;
    idempotencyKey: string;
  },
): Promise<{ run: SolverRun; reused: boolean }> {
  const payload = record(await rpc(client, "optimizer_request_v2", {
    p_month: input.month,
    p_scenario_id: input.scenarioId,
    p_scope_type: input.scopeType,
    p_scope_role_id: input.scopeRoleId ?? null,
    p_name: input.name,
    p_idempotency_key: input.idempotencyKey,
  }));
  const run = normalizeRun(payload);
  if (!run.id) throw new Error("RUN_ID_MISSING");
  return { run, reused: Boolean(payload.reused) };
}

export async function getSolverStatus(client: SupabaseClient, runId: string): Promise<SolverStatus> {
  const payload = record(await rpc(client, "optimizer_status_v2", { p_run_id: runId }));
  const list = payload.strategies;
  return {
    run: normalizeRun(payload),
    strategies: Array.isArray(list) ? list.map(normalizeStrategy) : [],
  };
}

export async function requestSolverCancellation(client: SupabaseClient, runId: string): Promise<SolverRun> {
  return normalizeRun(await rpc(client, "optimizer_request_cancel_v2", { p_run_id: runId }));
}

export async function getSolverVariants(client: SupabaseClient, runId: string): Promise<SolverVariants> {
  const payload = record(await rpc(client, "optimizer_variants_v2", { p_run_id: runId }));
  const variants = Array.isArray(payload.variants) ? payload.variants.map(normalizeVariant) : [];
  return { runId: String(valueOf(payload, "runId", "run_id", runId)), variants };
}

export async function selectSolverVariant(client: SupabaseClient, runId: string, variantId: string) {
  const payload = record(await rpc(client, "optimizer_select_variant_v2", {
    p_run_id: runId,
    p_variant_id: variantId,
  }));
  return {
    runId: String(valueOf(payload, "runId", "run_id", runId)),
    variantId: String(valueOf(payload, "variantId", "variant_id", variantId)),
    selected: Boolean(valueOf(payload, "selected", "selected", true)),
    planId: valueOf<string | null>(payload, "planId", "plan_id", null),
  };
}

export async function getSelectedVariantWorkspace(
  client: SupabaseClient,
  runId: string,
): Promise<SolverWorkspace> {
  return normalizeWorkspace(await rpc(client, "optimizer_selected_variant_workspace_alpha16", {
    p_run_id: runId,
  }));
}

export async function publishCompanyVariant(
  client: SupabaseClient,
  input: {
    runId: string;
    variantId: string;
    name: string;
    idempotencyKey: string;
    warningReason?: string | null;
    roleReplacementReason?: string | null;
  },
): Promise<SolverPublication> {
  const payload = record(await rpc(client, "optimizer_publish_company_variant_resolved_uat_v2", {
    p_run_id: input.runId,
    p_variant_id: input.variantId,
    p_name: input.name,
    p_idempotency_key: input.idempotencyKey,
    p_warning_reason: input.warningReason?.trim()||null,
    p_role_replacement_reason: input.roleReplacementReason?.trim()||null,
  }));
  if(payload.published===false){
    throw new Error(`${String(payload.code??"PUBLICATION_FAILED")}: ${String(payload.message??"Publikacja nie powiodła się.")}`);
  }
  const scheduleId = String(valueOf(payload, "scheduleId", "schedule_id", ""));
  if (!scheduleId) throw new Error("SCHEDULE_ID_MISSING");
  return {
    scheduleId,
    status: String(valueOf(payload, "status", "status", "PUBLISHED")),
    sourceType: String(valueOf(payload, "sourceType", "source_type", "COMPANY")),
    reused: Boolean(valueOf(payload, "reused", "reused", false)),
  };
}

export async function getPublishedSchedule(
  client: SupabaseClient,
  scheduleId: string,
): Promise<SolverWorkspace> {
  return normalizeWorkspace(await rpc(client, "optimizer_published_schedule_alpha16", {
    p_schedule_id: scheduleId,
  }));
}

export async function getActiveSolverWorkspace(
  client: SupabaseClient,
  month: string,
): Promise<SolverWorkspace | null> {
  const value = await rpc(client, "optimizer_active_workspace_v2", { p_month: month });
  if (value === null || value === undefined) return null;
  const payload = record(value);
  if (!Object.keys(payload).length) return null;
  if (payload.engine !== "ORTOOLS_V2") throw new Error("ACTIVE_WORKSPACE_ENGINE_INVALID");
  return normalizeWorkspace(value);
}

function normalizeCandidate(value: unknown): SolverCandidateDiagnostic {
  const source = record(value);
  const previous = source.previousShift ? record(source.previousShift) : null;
  const next = source.nextShift ? record(source.nextShift) : null;
  const classification = String(source.classification);
  if (!["ELIGIBLE", "WARNING", "BLOCKED"].includes(classification)) {
    throw new Error("CANDIDATE_CLASSIFICATION_INVALID");
  }
  return {
    employeeId: String(source.employeeId ?? ""),
    employeeNo: String(source.employeeNo ?? ""),
    name: String(source.name ?? "Pracownik"),
    classification: classification as SolverCandidateDiagnostic["classification"],
    hardReasons: Array.isArray(source.hardReasons) ? source.hardReasons.map(String) : [],
    softReasons: Array.isArray(source.softReasons) ? source.softReasons.map(String) : [],
    preferenceLevel: String(source.preferenceLevel ?? "NEUTRAL"),
    monthlyShifts: numberOf(source, "monthlyShifts", "monthly_shifts"),
    monthlyMinutes: numberOf(source, "monthlyMinutes", "monthly_minutes"),
    nominalMonthlyMinutes: numberOf(source, "nominalMonthlyMinutes", "nominal_monthly_minutes"),
    maximumMonthlyMinutes: numberOf(source, "maximumMonthlyMinutes", "maximum_monthly_minutes"),
    weeklyMinutes: numberOf(source, "weeklyMinutes", "weekly_minutes"),
    maximumWeeklyMinutes: numberOf(source, "maximumWeeklyMinutes", "maximum_weekly_minutes"),
    consecutiveDaysBefore: numberOf(source, "consecutiveDaysBefore", "consecutive_days_before"),
    consecutiveDaysAfter: numberOf(source, "consecutiveDaysAfter", "consecutive_days_after"),
    projectedConsecutiveDays: numberOf(source, "projectedConsecutiveDays", "projected_consecutive_days"),
    maximumConsecutiveDays: numberOf(source, "maximumConsecutiveDays", "maximum_consecutive_days"),
    declaredUnavailable: Boolean(source.declaredUnavailable),
    outsideAvailableWindow: Boolean(source.outsideAvailableWindow),
    worksPreviousDay: Boolean(source.worksPreviousDay),
    worksNextDay: Boolean(source.worksNextDay),
    previousShift: previous ? {
      date: String(previous.date ?? ""), startsAt: String(previous.startsAt ?? ""), endsAt: String(previous.endsAt ?? ""),
    } : null,
    nextShift: next ? {
      date: String(next.date ?? ""), startsAt: String(next.startsAt ?? ""), endsAt: String(next.endsAt ?? ""),
    } : null,
  };
}

export async function getCandidateDiagnostics(
  client: SupabaseClient,
  scheduleId: string,
  issueId: string,
): Promise<SolverCandidateDiagnostics> {
  const payload = record(await rpc(client, "optimizer_candidate_diagnostics_alpha16", {
    p_schedule_id: scheduleId,
    p_issue_id: Number(issueId),
  }));
  const issue = record(payload.issue), shift = record(payload.shift), summary = record(payload.summary);
  return {
    scheduleId: String(payload.scheduleId ?? scheduleId),
    issue: {
      id: String(issue.id ?? issueId), code: String(issue.code ?? "UNFILLED_SLOT"),
      message: String(issue.message ?? "Nieobsadzone miejsce"),
      slotKey: String(issue.slotKey ?? ""), roleId: String(issue.roleId ?? ""),
      dutyId: issue.dutyId ? String(issue.dutyId) : null,
    },
    shift: {
      id: String(shift.id ?? ""), slotGroupKey: String(shift.slotGroupKey ?? ""),
      date: String(shift.date ?? ""), startsAt: String(shift.startsAt ?? ""),
      endsAt: String(shift.endsAt ?? ""), locationId: String(shift.locationId ?? ""),
      shiftTemplateId: String(shift.shiftTemplateId ?? ""),
      shiftPeriod: String(shift.shiftPeriod ?? "MIDDLE") as SolverCandidateDiagnostics["shift"]["shiftPeriod"],
    },
    candidates: Array.isArray(payload.candidates) ? payload.candidates.map(normalizeCandidate) : [],
    summary: {
      considered: numberOf(summary, "considered", "considered"),
      eligible: numberOf(summary, "eligible", "eligible"),
      warning: numberOf(summary, "warning", "warning"),
      blocked: numberOf(summary, "blocked", "blocked"),
    },
  };
}

export async function getVariantIssueDiagnostics(
  client: SupabaseClient,
  variantId: string,
  issueId: string,
): Promise<SolverVariantIssueDiagnostics> {
  const payload = record(await rpc(client, "optimizer_variant_issue_diagnostics_uat_v2", {
    p_variant_id: variantId,
    p_issue_id: Number(issueId),
  }));
  const shift = record(payload.shift), summary = record(payload.summary);
  const decisionContext = payload.decisionContext ? record(payload.decisionContext) : null;
  const reasons = Array.isArray(summary.reasons) ? summary.reasons.map(value => {
    const reason = record(value);
    return { code: String(reason.code ?? "UNKNOWN"), count: numberOf(reason, "count", "count") };
  }) : [];
  const candidates = Array.isArray(payload.candidates) ? payload.candidates.map(value => {
    const candidate=record(value);
    return {
      employeeId:String(candidate.employeeId??""),
      employeeNo:String(candidate.employeeNo??""),
      employeeName:String(candidate.employeeName??""),
      roleMatch:Boolean(candidate.roleMatch),
      locationMatch:Boolean(candidate.locationMatch),
      dutyMatch:Boolean(candidate.dutyMatch),
      hasDeclaredWindow:Boolean(candidate.hasDeclaredWindow),
      coversShift:Boolean(candidate.coversShift),
      reasons:Array.isArray(candidate.reasons)?candidate.reasons.map(String):[],
      blockingDetails:Array.isArray(candidate.blockingDetails)?candidate.blockingDetails.map(value=>{
        const detail=record(value);
        return {
          code:String(detail.code??"UNKNOWN"),label:String(detail.label??"Szczegół blokady"),
          startsAt:detail.startsAt?String(detail.startsAt):null,endsAt:detail.endsAt?String(detail.endsAt):null,
          shiftName:detail.shiftName?String(detail.shiftName):null,locationName:detail.locationName?String(detail.locationName):null,
          note:detail.note?String(detail.note):null,createdAt:detail.createdAt?String(detail.createdAt):null,
        };
      }):[],
    };
  }):[];
  return {
    variantId: String(payload.variantId ?? variantId),
    issueId: String(payload.issueId ?? issueId),
    publishedScheduleId: payload.publishedScheduleId ? String(payload.publishedScheduleId) : null,
    shift: {
      date: String(shift.date ?? ""),
      startsAt: String(shift.startsAt ?? ""),
      endsAt: String(shift.endsAt ?? ""),
      shiftPeriod: String(shift.shiftPeriod ?? "MIDDLE"),
    },
    summary: {
      considered: numberOf(summary, "considered", "considered"),
      eligible: numberOf(summary, "eligible", "eligible"),
      blocked: numberOf(summary, "blocked", "blocked"),
      reasons,
    },
    decisionContext: decisionContext ? {
      code: String(decisionContext.code ?? ""),
      standbyTiers: numberOf(decisionContext, "standbyTiers", "standby_tiers"),
      message: String(decisionContext.message ?? ""),
    } : null,
    candidates,
  };
}

export async function emergencyAssignV2(
  client: SupabaseClient,
  input: {
    scheduleId: string; issueId: string; employeeId: string;
    allowSoft: boolean; reason?: string; notify: boolean;
  },
) {
  return record(await rpc(client, "optimizer_emergency_assign_alpha16", {
    p_schedule_id: input.scheduleId,
    p_issue_id: Number(input.issueId),
    p_employee_id: input.employeeId,
    p_allow_soft: input.allowSoft,
    p_reason: input.reason?.trim() || null,
    p_notify: input.notify,
  }));
}

export async function getOperationalSolverWorkspace(
  client: SupabaseClient,
  month: string,
): Promise<SolverWorkspace | null> {
  const payload = record(await rpc(client, "optimizer_operational_workspace_alpha16", { p_month: month }));
  // Older operational wrappers returned `workspace: null` when the month had
  // no publication. The UI still needs the canonical EMPTY ORTOOLS workspace
  // so a manager can open the generator and create the first schedule.
  if (!payload.workspace) return getActiveSolverWorkspace(client, month);
  const workspace = normalizeWorkspace(payload.workspace);
  const overrides = Array.isArray(payload.overrides) ? payload.overrides.map(record) : [];
  if (!overrides.length) return workspace;
  const resolvedIssues = new Set(overrides.map(item => String(item.issueId ?? "")));
  const overridesByVariant = new Map<string, number>();
  const byShift = new Map<string, SolverWorkspaceAssignment[]>();
  for (const override of overrides) {
    const variantId = String(override.variantId ?? "");
    if (variantId) overridesByVariant.set(variantId, (overridesByVariant.get(variantId) ?? 0) + 1);
    const key = String(override.slotGroupKey ?? "");
    if (!key) continue;
    const assignment = normalizeWorkspaceAssignment({
      id: override.id,
      slotKey: override.slotKey,
      employee: override.employee,
      role: override.role,
      duties: override.duties,
      locked: true,
      costMinor: null,
    });
    byShift.set(key, [...(byShift.get(key) ?? []), assignment]);
  }
  return {
    ...workspace,
    variants: workspace.variants.map(variant => ({
      ...variant,
      assignmentCount: variant.assignmentCount + (overridesByVariant.get(variant.id) ?? 0),
      unfilledCount: Math.max(0, variant.unfilledCount - (overridesByVariant.get(variant.id) ?? 0)),
    })),
    shifts: workspace.shifts.map(shift => ({
      ...shift,
      assignments: [...shift.assignments, ...(byShift.get(shift.slotGroupKey) ?? [])],
    })),
    issues: workspace.issues.filter(issue => !resolvedIssues.has(issue.id)),
  };
}

export async function getPublicationReadiness(
  client: SupabaseClient,
  runId: string,
  variantId: string,
  name: string,
): Promise<SolverPublicationReadiness> {
  const payload = record(await rpc(client, "optimizer_publication_attempt_alpha16", {
    p_run_id: runId,
    p_variant_id: variantId,
    p_name:name,
  }));
  return {
    ready: Boolean(payload.ready),
    blockers: record(payload.blockers) as SolverPublicationReadiness["blockers"],
    warnings: record(payload.warnings) as SolverPublicationReadiness["warnings"],
    issues: Array.isArray(payload.issues) ? payload.issues.map(item => record(item) as SolverPublicationReadiness["issues"][number]) : [],
  };
}

export async function getSolverRunsCatalog(
  client: SupabaseClient,
  month: string,
  scopeType: SolverScope,
  scopeRoleId?: string | null,
): Promise<SolverCatalogRun[]> {
  const payload = record(await rpc(client, "optimizer_runs_catalog_alpha16", {
    p_month: month,
    p_scope_type: scopeType,
    p_scope_role_id: scopeRoleId ?? null,
  }));
  return Array.isArray(payload.runs) ? payload.runs.map(value => {
    const source = record(value), scenario = record(source.scenario), scope = record(source.scope);
    return {
      id: String(source.id ?? ""), name: String(source.name ?? "Grafik"),
      status: String(source.status ?? "QUEUED"), phase: String(source.phase ?? "QUEUED"),
      progress: Number(source.progress ?? 0), createdAt: String(source.createdAt ?? ""),
      finishedAt: source.finishedAt ? String(source.finishedAt) : null,
      scenario: { id: String(scenario.id ?? ""), code: String(scenario.code ?? ""), name: String(scenario.name ?? "Scenariusz") },
      scope: { type: String(scope.type ?? scopeType) as SolverScope, roleId: scope.roleId ? String(scope.roleId) : null, roleName: scope.roleName ? String(scope.roleName) : null },
      variants: Array.isArray(source.variants) ? source.variants.map(normalizeVariant) : [],
    };
  }) : [];
}

export function isActiveOrtoolsWorkspace(workspace: SolverWorkspace | null): workspace is SolverWorkspace {
  return Boolean(
    workspace
    && workspace.context.type === "PUBLISHED_SCHEDULE"
    && workspace.context.engine === "ORTOOLS_V2"
    && workspace.context.status === "PUBLISHED",
  );
}

export function isEmptyOrtoolsWorkspace(workspace: SolverWorkspace | null): workspace is SolverWorkspace {
  return Boolean(
    workspace
    && workspace.context.type === "PUBLISHED_SCHEDULE"
    && workspace.context.engine === "ORTOOLS_V2"
    && workspace.context.status === "EMPTY"
    && workspace.variants.length === 0
    && workspace.shifts.length === 0
    && workspace.issues.length === 0
    && workspace.finance === null,
  );
}

export function mapSolverWorkspaceToOperational(
  workspace: SolverWorkspace,
  previous?: Pick<OperationalWorkspace, "events"> | null,
): OperationalWorkspace {
  if (
    workspace.context.type === "PUBLISHED_SCHEDULE"
    && workspace.context.engine === "ORTOOLS_V2"
    && workspace.context.status === "EMPTY"
    && workspace.variants.length === 0
    && workspace.shifts.length === 0
    && workspace.issues.length === 0
    && workspace.finance === null
  ) {
    return {
      plan: null,
      assignments: [],
      shifts: [],
      issues: [],
      events: previous?.events ?? [],
      budget: { amount: 0, warning_percent: 100, hard_limit: false },
    };
  }
  if (!isActiveOrtoolsWorkspace(workspace)) throw new Error("ACTIVE_ORTOOLS_WORKSPACE_INVALID");
  const selectedVariant = workspace.variants.find(variant => variant.selected)
    ?? workspace.variants[0]
    ?? null;
  const slotToShift = new Map<string, string>();
  const assignments: OperationalAssignment[] = [];
  const employeeMinutes = new Map<string, number>();

  for (const shift of workspace.shifts) {
    const durationMinutes = Math.max(
      0,
      Math.round((new Date(shift.endsAt).getTime() - new Date(shift.startsAt).getTime()) / 60000),
    );
    for (const assignment of shift.assignments) {
      slotToShift.set(assignment.slotKey, shift.slotGroupKey);
      employeeMinutes.set(
        assignment.employee.id,
        (employeeMinutes.get(assignment.employee.id) ?? 0) + durationMinutes,
      );
      assignments.push({
        id: assignment.id,
        shift_id: shift.slotGroupKey,
        employee_id: assignment.employee.id,
        employee_no: assignment.employee.employeeNo,
        name: `${assignment.employee.firstName} ${assignment.employee.lastName}`.trim(),
        role: assignment.role.name,
        role_id: assignment.role.id,
        role_name: assignment.role.name,
        capability: assignment.duties.map(duty => duty.name).join(", ") || undefined,
        location: shift.location.name,
        location_id: shift.location.id,
        location_name: shift.location.name,
        location_timezone: shift.location.timezone ?? undefined,
        date: shift.date,
        shift_code: shift.shiftTemplate.name,
        shift_template_id: shift.shiftTemplate.id,
        shift_name: shift.shiftTemplate.name,
        starts_at: shift.startsAt,
        ends_at: shift.endsAt,
        cost: (assignment.costMinor ?? 0) / 100,
        monthly_minutes: 0,
        nominal_minutes: assignment.employee.nominalMonthlyMinutes,
      });
    }
  }
  for (const assignment of assignments) {
    assignment.monthly_minutes = employeeMinutes.get(assignment.employee_id) ?? 0;
  }

  const totalCostMinor = workspace.finance?.totalCostMinor ?? selectedVariant?.finance?.totalCostMinor ?? 0;
  const budgetMinor = workspace.finance?.budgetMinor ?? selectedVariant?.finance?.budgetMinor ?? null;
  return {
    plan: {
      id: workspace.context.scheduleId ?? workspace.context.runId ?? "published-v2",
      month: workspace.context.month,
      name: workspace.context.name,
      scenario_code: workspace.context.scenario.name,
      optimization_mode: selectedVariant?.strategy.name ?? "OR-Tools",
      staffing_level: "DYNAMIC_MATRIX",
      status: workspace.context.status ?? "PUBLISHED",
      version: 1,
      score: 0,
      total_cost: totalCostMinor / 100,
    },
    assignments,
    shifts: workspace.shifts.map(shift => ({
      id: shift.slotGroupKey,
      shift_date: shift.date,
      shift_code: shift.shiftTemplate.name,
      shift_template_id: shift.shiftTemplate.id,
      shift_name: shift.shiftTemplate.name,
      starts_at: shift.startsAt,
      ends_at: shift.endsAt,
      location_code: shift.location.name,
      location_id: shift.location.id,
      location_name: shift.location.name,
      location_timezone: shift.location.timezone ?? undefined,
      assignment_count: shift.assignments.length,
    })),
    issues: workspace.issues.map(issue => ({
      id: issue.id,
      shift_id: issue.slotKey ? slotToShift.get(issue.slotKey) : undefined,
      issue_type: issue.code,
      severity: issue.severity,
      role: issue.role?.name,
      role_id: issue.role?.id,
      capability: issue.duty?.name,
      required_count: 1,
      assigned_count: 0,
      message: issue.message,
    })),
    events: previous?.events ?? [],
    budget: {
      amount: budgetMinor === null ? 0 : budgetMinor / 100,
      warning_percent: 100,
      hard_limit: false,
    },
  };
}

function normalizeEmployeeAssignment(value: unknown): SolverEmployeePublishedAssignment {
  const source = record(value);
  const coworkers = Array.isArray(source.coworkers) ? source.coworkers : [];
  return {
    id: String(valueOf(source, "id", "id", "")),
    shiftId: valueOf<string | undefined>(source, "shiftId", "shift_id", undefined),
    date: String(valueOf(source, "date", "date", "")),
    startsAt: String(valueOf(source, "startsAt", "starts_at", "")),
    endsAt: String(valueOf(source, "endsAt", "ends_at", "")),
    shiftCode: valueOf<string | undefined>(source, "shiftCode", "shift_code", undefined),
    shiftName: valueOf<string | undefined>(source, "shiftName", "shift_name", undefined),
    location: String(valueOf(source, "location", "location", "")),
    locationCode: valueOf<string | undefined>(source, "locationCode", "location_code", undefined),
    locationTimezone: valueOf<string | undefined>(source, "locationTimezone", "location_timezone", undefined),
    role: String(valueOf(source, "role", "role", "")),
    roleCode: valueOf<string | undefined>(source, "roleCode", "role_code", undefined),
    capability: valueOf<string | undefined>(source, "capability", "capability", undefined),
    coworkers: coworkers.map(item => {
      const coworker = record(item);
      return {
        name: String(valueOf(coworker, "name", "name", "")),
        role: String(valueOf(coworker, "role", "role", "")),
        capability: valueOf<string | undefined>(coworker, "capability", "capability", undefined),
      };
    }),
  };
}

export async function getEmployeePublishedSchedule(
  client: SupabaseClient,
  month: string,
): Promise<SolverEmployeePublishedSchedule> {
  const value = await rpc(client, "optimizer_employee_schedule_uat_v3", { p_month: month });
  if (value === null || value === undefined) return { assignments: [], standby: [] };
  const payload = record(value);
  if (payload.engine !== "ORTOOLS_V2") throw new Error("EMPLOYEE_PUBLISHED_SCHEDULE_ENGINE_INVALID");
  const standby = Array.isArray(payload.standby) ? payload.standby.map((item) => {
    const source = record(item);
    const tier = Number(source.tier);
    if (tier !== 1 && tier !== 2) throw new Error("EMPLOYEE_STANDBY_TIER_INVALID");
    return {
      id: String(source.id ?? ""),
      date: String(source.date ?? ""),
      tier,
      status: String(source.status ?? "PLANNED") as SolverEmployeeStandby["status"],
      roleId: String(source.roleId ?? ""),
      roleName: String(source.roleName ?? ""),
      activatedShiftId: source.activatedShiftId ? String(source.activatedShiftId) : undefined,
    } satisfies SolverEmployeeStandby;
  }) : [];
  if (Array.isArray(payload.assignments)) return {
    assignments: payload.assignments.map(normalizeEmployeeAssignment),
    standby,
  };
  if (!Array.isArray(payload.shifts)) throw new Error("EMPLOYEE_PUBLISHED_SCHEDULE_INVALID");
  const assignments = payload.shifts.flatMap(shiftValue => {
    const shift = record(shiftValue);
    const location = normalizeNamedEntity(shift.location);
    const locationSource = record(shift.location);
    const template = normalizeNamedEntity(shift.shiftTemplate);
    const assignments = Array.isArray(shift.assignments) ? shift.assignments : [];
    return assignments.map(assignmentValue => {
      const assignment = record(assignmentValue);
      const role = normalizeNamedEntity(assignment.role);
      const duties = Array.isArray(assignment.duties) ? assignment.duties.map(item => normalizeNamedEntity(item).name) : [];
      return {
        id: String(valueOf(assignment, "id", "id", "")),
        shiftId: String(valueOf(shift, "slotGroupKey", "slot_group_key", "")),
        date: String(valueOf(shift, "date", "date", "")),
        startsAt: String(valueOf(shift, "startsAt", "starts_at", "")),
        endsAt: String(valueOf(shift, "endsAt", "ends_at", "")),
        shiftCode: template.name,
        shiftName: template.name,
        location: location.name,
        locationCode: location.id,
        locationTimezone: valueOf<string | undefined>(locationSource, "timezone", "timezone", undefined),
        role: role.name,
        capability: duties.join(", ") || undefined,
      } satisfies SolverEmployeePublishedAssignment;
    });
  });
  return { assignments, standby };
}

export async function getEmployeePublishedAssignments(
  client: SupabaseClient,
  month: string,
): Promise<SolverEmployeePublishedAssignment[]> {
  return (await getEmployeePublishedSchedule(client, month)).assignments;
}

export async function getPublicationAuthorityStatus(
  client: SupabaseClient,
  month: string,
): Promise<SolverPublicationAuthorityStatus> {
  return record(await rpc(client, "schedule_publication_status_uat_v2", {
    p_month: month,
  })) as SolverPublicationAuthorityStatus;
}

export async function resolvePublicationAuthority(
  client: SupabaseClient,
  month: string,
  keepSource: "COMPANY" | "ROLES",
  reason: string,
): Promise<SolverPublicationAuthorityStatus> {
  return record(await rpc(client, "schedule_publication_resolve_with_standby_uat_v2", {
    p_month: month,
    p_keep_source: keepSource,
    p_reason: reason,
  })) as SolverPublicationAuthorityStatus;
}

export async function getVariantWorkspace(
  client: SupabaseClient,
  variantId: string,
): Promise<SolverWorkspace> {
  return normalizeWorkspace(await rpc(client, "optimizer_variant_workspace_uat_v2", {
    p_variant_id: variantId,
  }));
}

function normalizeLeaderVariant(value: unknown): SolverLeaderVariant | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const source = record(value);
  const id = String(source.id ?? source.variantId ?? "");
  const sourceVariantId = String(source.sourceVariantId ?? source.source_variant_id ?? "");
  if (!id || !sourceVariantId) return null;
  return {
    id,
    sourceVariantId,
    name: String(source.name ?? "Wersja lidera"),
    status: String(source.status ?? "SELECTED"),
    revision: Number(source.revision ?? 0),
    assignmentCount: numberOf(source, "assignmentCount", "assignment_count"),
    unfilledCount: numberOf(source, "unfilledCount", "unfilled_count"),
    lastEditedAt: source.lastEditedAt ? String(source.lastEditedAt) : null,
  };
}

export async function getLeaderVariantForRun(
  client: SupabaseClient,
  runId: string,
): Promise<SolverLeaderVariant | null> {
  const payload = record(await rpc(client, "optimizer_leader_variant_for_run_uat_v1", {
    p_run_id: runId,
  }));
  return normalizeLeaderVariant(payload.variant);
}

export async function createLeaderVariant(
  client: SupabaseClient,
  input: { runId: string; sourceVariantId: string; name: string },
): Promise<SolverLeaderVariant> {
  const payload = record(await rpc(client, "optimizer_create_leader_variant_uat_v1", {
    p_run_id: input.runId,
    p_source_variant_id: input.sourceVariantId,
    p_name: input.name,
  }));
  const normalized = normalizeLeaderVariant({
    ...payload,
    status: "SELECTED",
    assignmentCount: 0,
    unfilledCount: 0,
  });
  if (!normalized) throw new Error("LEADER_VARIANT_CREATE_FAILED");
  return normalized;
}

export async function getLeaderVariantWorkspace(
  client: SupabaseClient,
  variantId: string,
): Promise<SolverWorkspace> {
  return normalizeWorkspace(await rpc(client, "optimizer_leader_variant_workspace_uat_v1", {
    p_variant_id: variantId,
  }));
}

export async function getLeaderAssignmentContext(
  client: SupabaseClient,
  input: { variantId: string; assignmentId?: string | null; issueId?: string | null },
): Promise<SolverLeaderAssignmentContext> {
  const payload = record(await rpc(client, "optimizer_leader_assignment_context_uat_v2", {
    p_variant_id: input.variantId,
    p_assignment_id: input.assignmentId ?? null,
    p_issue_id: input.issueId ? Number(input.issueId) : null,
  }));
  const role = record(payload.role), shift = record(payload.shift), duty = payload.duty ? record(payload.duty) : null;
  return {
    variantId: String(payload.variantId ?? input.variantId),
    assignmentId: payload.assignmentId ? String(payload.assignmentId) : null,
    issueId: payload.issueId ? String(payload.issueId) : null,
    slotKey: String(payload.slotKey ?? ""),
    currentEmployeeId: payload.currentEmployeeId ? String(payload.currentEmployeeId) : null,
    role: { id: String(role.id ?? ""), name: String(role.name ?? "Rola") },
    duty: duty ? { id: String(duty.id ?? ""), name: String(duty.name ?? "Obowiązek") } : null,
    shift: {
      id: String(shift.id ?? ""), date: String(shift.date ?? ""),
      startsAt: String(shift.startsAt ?? ""), endsAt: String(shift.endsAt ?? ""),
      locationId: String(shift.locationId ?? ""), locationName: String(shift.locationName ?? "Lokal"),
      shiftName: String(shift.shiftName ?? "Zmiana"),
    },
    candidates: Array.isArray(payload.candidates) ? payload.candidates.map(value => {
      const candidate = record(value);
      return {
        employeeId: String(candidate.employeeId ?? ""),
        employeeNo: String(candidate.employeeNo ?? ""),
        employeeName: String(candidate.employeeName ?? ""),
        current: Boolean(candidate.current),
        roleName: candidate.roleName ? String(candidate.roleName) : undefined,
        locationName: candidate.locationName ? String(candidate.locationName) : undefined,
        dutyName: candidate.dutyName ? String(candidate.dutyName) : null,
        dutyMatch: Boolean(candidate.dutyMatch),
        dutyCoverageMode: String(candidate.dutyCoverageMode??"NOT_COVERED") as "DIRECT"|"TRANSFER"|"NOT_COVERED",
        dutyTransferAssignmentId: candidate.dutyTransferAssignmentId?String(candidate.dutyTransferAssignmentId):null,
        dutyTransferEmployeeId: candidate.dutyTransferEmployeeId?String(candidate.dutyTransferEmployeeId):null,
        dutyTransferEmployeeName: candidate.dutyTransferEmployeeName?String(candidate.dutyTransferEmployeeName):null,
        availabilityStatus: String(candidate.availabilityStatus??"UNKNOWN"),
        suggestionEligible: Boolean(candidate.suggestionEligible),
      };
    }) : [],
  };
}

export async function getEmployeeAvailabilityMonth(
  client:SupabaseClient,variantId:string,employeeIds:string[],
):Promise<SolverEmployeeDayAvailability[]>{
  const value=await rpc(client,"optimizer_employee_availability_month_uat_v1",{
    p_variant_id:variantId,p_employee_ids:employeeIds,
  });
  if(!Array.isArray(value))return [];
  return value.map(item=>{const row=record(item);return{
    employeeId:String(row.employeeId??""),date:String(row.date??""),
    scheduled:Boolean(row.scheduled),status:String(row.status??"UNKNOWN"),label:String(row.label??"Wymaga sprawdzenia"),
  };});
}

export async function saveLeaderAssignment(
  client: SupabaseClient,
  input: {
    variantId: string; assignmentId?: string | null; issueId?: string | null;
    employeeId: string; reason: string; allowLimitOverride?: boolean;
    dutyTransferAssignmentId?: string|null;
  },
) {
  return record(await rpc(client, "optimizer_leader_assignment_save_uat_v2", {
    p_variant_id: input.variantId,
    p_assignment_id: input.assignmentId ?? null,
    p_issue_id: input.issueId ? Number(input.issueId) : null,
    p_employee_id: input.employeeId,
    p_reason: input.reason,
    p_allow_limit_override: input.allowLimitOverride ?? false,
    p_duty_transfer_assignment_id: input.dutyTransferAssignmentId ?? null,
  }));
}

export async function removeLeaderAssignment(
  client: SupabaseClient,
  input: { variantId: string; assignmentId: string; reason: string },
) {
  return record(await rpc(client, "optimizer_leader_assignment_remove_uat_v1", {
    p_variant_id: input.variantId,
    p_assignment_id: input.assignmentId,
    p_reason: input.reason,
  }));
}

export async function getRoleCompositeCandidates(
  client: SupabaseClient,
  month: string,
  scenarioId: string,
): Promise<SolverRoleCompositeCandidates> {
  return normalizeRoleCompositeCandidates(await rpc(client, "optimizer_role_composite_candidates_v2", {
    p_month: month,
    p_scenario_id: scenarioId,
  }));
}

export async function getRoleCompositePreflight(
  client: SupabaseClient,
  month: string,
  scenarioId: string,
  variantIds: string[],
): Promise<SolverRoleCompositePreflight> {
  const payload = record(await rpc(client, "optimizer_role_composite_preflight_uat_v2", {
    p_month: month,
    p_scenario_id: scenarioId,
    p_variant_ids: variantIds,
  }));
  const gaps = Array.isArray(payload.gaps) ? payload.gaps.map(value => {
    const row = record(value);
    return {
      issueId: String(valueOf(row, "issueId", "issue_id", "")),
      variantId: String(valueOf(row, "variantId", "variant_id", "")),
      date: String(valueOf(row, "date", "date", "")),
      startsAt: String(valueOf(row, "startsAt", "starts_at", "")),
      endsAt: String(valueOf(row, "endsAt", "ends_at", "")),
      location: String(valueOf(row, "location", "location", "Lokal")),
      role: String(valueOf(row, "role", "role", "Rola")),
      duty: valueOf<string | undefined>(row, "duty", "duty", undefined),
      requiredCount: numberOf(row, "requiredCount", "required_count"),
      assignedCount: numberOf(row, "assignedCount", "assigned_count"),
      missingCount: numberOf(row, "missingCount", "missing_count"),
      critical: Boolean(valueOf(row, "critical", "critical", false)),
      message: String(valueOf(row, "message", "message", "Brak obsady")),
    };
  }) : [];
  return {
    month: String(valueOf(payload, "month", "month", month)),
    scenarioId: String(valueOf(payload, "scenarioId", "scenario_id", scenarioId)),
    totalGaps: numberOf(payload, "totalGaps", "total_gaps"),
    criticalGaps: numberOf(payload, "criticalGaps", "critical_gaps"),
    gaps,
  };
}

export async function getRolePublicationOverview(
  client: SupabaseClient,
  month: string,
): Promise<SolverRolePublicationOverview> {
  const payload = record(await rpc(client, "optimizer_role_publication_overview_uat_v2", {
    p_month: month,
  }));
  const totals = record(payload.totals);
  const roles = Array.isArray(payload.roles) ? payload.roles.map(value => {
    const row = record(value), role = record(row.role), scenario = record(row.scenario);
    return {
      publicationId: String(row.publicationId ?? ""),
      name: String(row.name ?? ""),
      publishedAt: String(row.publishedAt ?? ""),
      role: { id: String(role.id ?? ""), name: String(role.name ?? "") },
      scenario: { id: String(scenario.id ?? ""), name: String(scenario.name ?? "") },
      variantId: String(row.variantId ?? ""),
      assignmentCount: numberOf(row, "assignmentCount", "assignment_count"),
      unfilledCount: numberOf(row, "unfilledCount", "unfilled_count"),
      overtimeMinutes: numberOf(row, "overtimeMinutes", "overtime_minutes"),
      totalCostMinor: numberOf(row, "totalCostMinor", "total_cost_minor"),
      currency: String(row.currency ?? "PLN"),
      teamSize: numberOf(row, "teamSize", "team_size"),
      scheduledMinutes: numberOf(row, "scheduledMinutes", "scheduled_minutes"),
    };
  }) : [];
  return {
    month: String(payload.month ?? month),
    totals: {
      publishedRoles: numberOf(totals, "publishedRoles", "published_roles"),
      assignmentCount: numberOf(totals, "assignmentCount", "assignment_count"),
      unfilledCount: numberOf(totals, "unfilledCount", "unfilled_count"),
      overtimeMinutes: numberOf(totals, "overtimeMinutes", "overtime_minutes"),
      totalCostMinor: numberOf(totals, "totalCostMinor", "total_cost_minor"),
      scheduledMinutes: numberOf(totals, "scheduledMinutes", "scheduled_minutes"),
    },
    roles,
  };
}

export async function publishRoleComposite(
  client: SupabaseClient,
  input: {
    month: string;
    scenarioId: string;
    variantIds: string[];
    name: string;
    idempotencyKey: string;
    warningReason?: string;
  },
): Promise<SolverPublication> {
  const payload = record(await rpc(client, "optimizer_publish_role_composite_uat_v3", {
    p_month: input.month,
    p_scenario_id: input.scenarioId,
    p_variant_ids: input.variantIds,
    p_name: input.name,
    p_idempotency_key: input.idempotencyKey,
    p_warning_reason: input.warningReason?.trim() || null,
  }));
  const scheduleId = String(valueOf(payload, "scheduleId", "schedule_id", ""));
  if (!scheduleId) throw new Error("SCHEDULE_ID_MISSING");
  return {
    scheduleId,
    status: String(valueOf(payload, "status", "status", "PUBLISHED")),
    sourceType: String(valueOf(payload, "sourceType", "source_type", "ROLE_COMPOSITE")),
    reused: Boolean(valueOf(payload, "reused", "reused", false)),
  };
}

export async function publishRoleVariant(
  client: SupabaseClient,
  input: {
    runId: string;
    variantId: string;
    name: string;
    idempotencyKey: string;
  },
): Promise<{ roleScheduleId: string; status: string; reused: boolean; notified: number }> {
  const payload = record(await rpc(client, "optimizer_publish_role_variant_uat_v2", {
    p_run_id: input.runId,
    p_variant_id: input.variantId,
    p_name: input.name,
    p_idempotency_key: input.idempotencyKey,
  }));
  const roleScheduleId = String(valueOf(payload, "roleScheduleId", "role_schedule_id", ""));
  if (!roleScheduleId) throw new Error("ROLE_SCHEDULE_ID_MISSING");
  return {
    roleScheduleId,
    status: String(valueOf(payload, "status", "status", "PUBLISHED")),
    reused: Boolean(valueOf(payload, "reused", "reused", false)),
    notified: numberOf(payload, "notified", "notified"),
  };
}

function legacySolverRunStorageKey(context: RunStorageContext) {
  return [
    "grafik-pro",
    "solver-v2",
    context.userId,
    context.engine,
    context.month,
    context.scenarioId,
    context.scopeType,
    context.scopeRoleId ?? "company",
  ].join(":");
}

export function solverRunStorageKey(context: RunStorageContext) {
  return [
    legacySolverRunStorageKey(context),
    "solver-version",
    stableHash(context.solverVersion?.trim() || "missing-version"),
  ].join(":");
}

const STORED_UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isValidStoredUuid(value: string | null | undefined): value is string {
  return Boolean(value && STORED_UUID_PATTERN.test(value));
}

export function isValidIdempotencyKey(value: string | null | undefined): value is string {
  return Boolean(value && value.length >= 8 && value.length <= 200);
}

export function rememberSolverRun(context: RunStorageContext, runId: string) {
  if (typeof window === "undefined") return;
  if (!isValidStoredUuid(runId)) throw new Error("RUN_ID_INVALID");
  window.localStorage.setItem(solverRunStorageKey(context), runId);
  window.localStorage.removeItem(legacySolverRunStorageKey(context));
}

export function recoverSolverRun(context: RunStorageContext) {
  if (typeof window === "undefined") return null;
  const key = solverRunStorageKey(context);
  const runId = window.localStorage.getItem(key);
  window.localStorage.removeItem(legacySolverRunStorageKey(context));
  if (!runId) return null;
  if (isValidStoredUuid(runId)) return runId;
  window.localStorage.removeItem(key);
  return null;
}

export function forgetSolverRun(context: RunStorageContext) {
  if (typeof window === "undefined") return;
  window.localStorage.removeItem(solverRunStorageKey(context));
  window.localStorage.removeItem(legacySolverRunStorageKey(context));
}

function stableHash(value: string) {
  let hash = 0xcbf29ce484222325n;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= BigInt(value.charCodeAt(index));
    hash = BigInt.asUintN(64, hash * 0x100000001b3n);
  }
  return hash.toString(36);
}

export function solverRequestFingerprint(context: RunStorageContext, name: string) {
  return stableHash(JSON.stringify({
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
