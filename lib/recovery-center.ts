import type { SupabaseClient } from "@supabase/supabase-js";

export type RecoveryMode = "PROPOSE" | "SEND_OFFERS" | "AUTO_DRAFT";

export type RecoveryShortage = {
  roleId: string;
  roleName: string;
  roleColor?: string | null;
  locationId: string;
  locationName: string;
  startsAt: string;
  endsAt: string;
  affectedDays: number;
  firstDate: string;
  lastDate: string;
  missingSlots: number;
  missingHours: number;
  dates: string[];
  structural: boolean;
  actions: string[];
};

export type RecoveryIncident = {
  id: string;
  type: string;
  title: string;
  status: string;
  mode: RecoveryMode;
  startsOn: string;
  endsOn: string;
  employeeId?: string | null;
  employeeName?: string | null;
  roleId?: string | null;
  roleName?: string | null;
  roleColor?: string | null;
  locationId?: string | null;
  locationName?: string | null;
  notes?: string | null;
  baseRevision: number;
  updatedAt: string;
  actionCount: number;
  offerCount: number;
};

export type RecoveryCandidate = {
  employeeId: string;
  name: string;
  employeeNo: string;
  source: "STANDBY" | "ACTIVE_TEAM" | "AD_HOC" | string;
  tier?: number | null;
  priority: number;
  contractType?: string | null;
  eligible?: boolean;
  locationOk?: boolean;
  dutyOk?: boolean;
  hardBlocked?: boolean;
  overlaps?: boolean;
  reasons?: string[];
  monthMinutes?: number;
  weekMinutes?: number;
  nominalMonthlyMinutes?: number;
  maximumMonthlyMinutes?: number;
  maximumWeeklyMinutes?: number;
};

export type RecoveryAction = {
  id: string;
  type: string;
  status: string;
  shiftId?: string | null;
  assignmentId?: string | null;
  issueId?: number | null;
  draftVariantId?: string | null;
  selectedEmployeeId?: string | null;
  candidates: RecoveryCandidate[];
  risk: "LOW" | "MEDIUM" | "HIGH" | "CRITICAL" | string;
  warnings: { code: string; message: string }[];
  costDeltaMinor?: number | null;
  currency?: string | null;
  version: number;
  shiftDate?: string | null;
  startsAt?: string | null;
  endsAt?: string | null;
  locationName?: string | null;
  roleName?: string | null;
  roleColor?: string | null;
};

export type RecoveryIncidentDetail = {
  id: string;
  month: string;
  title: string;
  type: string;
  status: string;
  mode: RecoveryMode;
  startsOn: string;
  endsOn: string;
  employeeId?: string | null;
  roleId?: string | null;
  locationId?: string | null;
  contractType?: string | null;
  notes?: string | null;
  actions: RecoveryAction[];
  overrides: Record<string, unknown>[];
  incidentRates: { id: string; employeeId: string; employeeName: string; revision: number; proposedRateMinor: number; approvedRateMinor?: number | null; currency: string; validFrom: string; validTo: string; status: string; proposalReason: string; decisionReason?: string | null }[];
};

export type RecoveryAdHocWorker = {
  id: string;
  employeeId?: string | null;
  name: string;
  email?: string | null;
  phone?: string | null;
  roleId: string;
  roleName: string;
  roleColor?: string | null;
  contractType: string;
  rateMinor?: number | null;
  currency: string;
  availableFrom?: string | null;
  availableTo?: string | null;
  active: boolean;
  notes?: string | null;
};

export type RecoveryWorkspace = {
  month: string;
  revision: number;
  schedule?: { id: string; name: string; status: string; publishedAt?: string; validation?: Record<string, unknown> } | null;
  shortages: RecoveryShortage[];
  incidents: RecoveryIncident[];
  adHocPool: RecoveryAdHocWorker[];
  budget: { amount: number; warningPercent: number; hardLimit: boolean; updatedAt?: string | null };
  roleScopes: { roleId: string; roleName: string; roleColor?: string | null; canManage: boolean }[];
  locationScopes: { locationId: string; locationName: string; canManage: boolean }[];
};

export type RecoveryOffer = {
  id: string;
  actionId: string;
  incidentId: string;
  title: string;
  status: string;
  rateMinor?: number | null;
  currency?: string | null;
  message?: string | null;
  offeredAt: string;
  shiftDate?: string | null;
  startsAt?: string | null;
  endsAt?: string | null;
  locationName?: string | null;
  roleName?: string | null;
};

function record(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

async function rpc(client: SupabaseClient, name: string, args: Record<string, unknown>) {
  const { data, error } = await client.rpc(name, args);
  if (error) throw error;
  return record(data);
}

export async function getRecoveryWorkspace(client: SupabaseClient, month: string): Promise<RecoveryWorkspace> {
  return await rpc(client, "recovery_center_workspace_uat_v1", { p_month: `${month}-01` }) as unknown as RecoveryWorkspace;
}

export async function saveRecoveryIncident(client: SupabaseClient, input: {
  month: string;
  expectedRevision: number;
  incidentId?: string | null;
  employeeId?: string | null;
  roleId?: string | null;
  locationId?: string | null;
  type: string;
  startsOn: string;
  endsOn: string;
  title: string;
  notes?: string | null;
  mode: RecoveryMode;
}) {
  return await rpc(client, "recovery_incident_save_uat_v1", {
    p_month: `${input.month}-01`, p_expected_revision: input.expectedRevision,
    p_incident_id: input.incidentId ?? null, p_employee_id: input.employeeId ?? null,
    p_role_id: input.roleId ?? null, p_location_id: input.locationId ?? null,
    p_incident_type: input.type,
    p_starts_on: input.startsOn, p_ends_on: input.endsOn, p_title: input.title,
    p_notes: input.notes ?? null, p_mode: input.mode,
  });
}

export async function prepareRecoveryIncident(client: SupabaseClient, incidentId: string, expectedRevision: number, mode: RecoveryMode) {
  return await rpc(client, "recovery_incident_prepare_uat_v1", {
    p_incident_id: incidentId, p_expected_revision: expectedRevision, p_mode: mode,
  });
}

export async function selectRecoveryCandidate(client: SupabaseClient, input: {
  actionId: string;
  employeeId: string;
  expectedActionVersion: number;
  expectedRevision: number;
}) {
  return await rpc(client, "recovery_action_select_candidate_uat_v1", {
    p_action_id: input.actionId, p_employee_id: input.employeeId,
    p_expected_action_version: input.expectedActionVersion,
    p_expected_revision: input.expectedRevision,
  });
}

export async function applyRecoveryDraft(client: SupabaseClient, incidentId: string, expectedRevision: number) {
  return await rpc(client, "recovery_incident_apply_draft_uat_v1", {
    p_incident_id: incidentId, p_expected_revision: expectedRevision,
  });
}

export async function getRecoveryIncidentDetail(client: SupabaseClient, incidentId: string): Promise<RecoveryIncidentDetail> {
  return await rpc(client, "recovery_incident_detail_uat_v1", { p_incident_id: incidentId }) as unknown as RecoveryIncidentDetail;
}

export async function getEmployeeRecoveryOffers(client: SupabaseClient, month: string): Promise<RecoveryOffer[]> {
  const value = await rpc(client, "recovery_employee_offers_uat_v1", { p_month: `${month}-01` });
  return Array.isArray(value.offers) ? value.offers as RecoveryOffer[] : [];
}

export async function respondRecoveryOffer(client: SupabaseClient, responseId: string, accept: boolean, message?: string) {
  return await rpc(client, "recovery_offer_respond_uat_v1", {
    p_response_id: responseId, p_accept: accept, p_message: message ?? null,
  });
}

export async function saveRecoveryAdHoc(client: SupabaseClient, input: {
  id?: string | null;
  employeeId?: string | null;
  name: string;
  email?: string;
  phone?: string;
  roleId: string;
  contractType: string;
  rateMinor?: number | null;
  currency: string;
  availableFrom?: string | null;
  availableTo?: string | null;
  notes?: string;
}) {
  return await rpc(client, "recovery_ad_hoc_save_uat_v1", {
    p_id: input.id ?? null, p_employee_id: input.employeeId ?? null,
    p_display_name: input.name, p_email: input.email ?? null, p_phone: input.phone ?? null,
    p_role_id: input.roleId, p_contract_type: input.contractType,
    p_rate_minor: input.rateMinor ?? null, p_currency: input.currency,
    p_available_from: input.availableFrom ?? null, p_available_to: input.availableTo ?? null,
    p_notes: input.notes ?? null,
  });
}

export async function saveRecoveryOverride(client: SupabaseClient, input: {
  incidentId: string;
  type: string;
  employeeId?: string | null;
  roleId?: string | null;
  startsOn: string;
  endsOn: string;
  numericValue: number;
  currency?: string | null;
  justification: string;
  employeeAcknowledged: boolean;
  complianceConfirmed: boolean;
}) {
  return await rpc(client, "recovery_override_save_uat_v1", {
    p_incident_id: input.incidentId, p_override_type: input.type,
    p_employee_id: input.employeeId ?? null, p_role_id: input.roleId ?? null,
    p_starts_on: input.startsOn, p_ends_on: input.endsOn,
    p_numeric_value: input.numericValue, p_currency: input.currency ?? null,
    p_justification: input.justification, p_employee_acknowledged: input.employeeAcknowledged,
    p_compliance_confirmed: input.complianceConfirmed,
  });
}

export async function proposeRecoveryIncidentRate(client: SupabaseClient, input: { incidentId: string; employeeId: string; rateMinor: number; currency: string; validFrom: string; validTo: string; reason: string }) {
  return await rpc(client, "recovery_incident_rate_propose_uat_v1", {
    p_incident_id: input.incidentId, p_employee_id: input.employeeId, p_rate_minor: input.rateMinor,
    p_currency: input.currency, p_valid_from: input.validFrom, p_valid_to: input.validTo, p_reason: input.reason,
  });
}

export async function decideRecoveryIncidentRate(client: SupabaseClient, input: { rateId: string; approve: boolean; approvedRateMinor?: number | null; reason: string }) {
  return await rpc(client, "recovery_incident_rate_decide_uat_v1", {
    p_rate_id: input.rateId, p_approve: input.approve, p_approved_rate_minor: input.approvedRateMinor ?? null, p_reason: input.reason,
  });
}

export async function saveRecoveryBudget(client: SupabaseClient, month: string, amount: number, warningPercent: number, hardLimit: boolean) {
  return await rpc(client, "recovery_month_budget_save_uat_v1", {
    p_month: `${month}-01`, p_amount: amount, p_warning_percent: warningPercent, p_hard_limit: hardLimit,
  });
}

export function recoveryErrorMessage(error: unknown) {
  const record = typeof error === "object" && error !== null ? error as Record<string, unknown> : null;
  const nested = record && typeof record.error === "object" && record.error !== null
    ? record.error as Record<string, unknown> : null;
  const parts = [
    error instanceof Error ? error.message : null,
    record?.message, record?.details, record?.hint, record?.code,
    nested?.message, nested?.details, nested?.hint, nested?.code,
    typeof error === "string" ? error : null,
  ].filter((value): value is string => typeof value === "string" && value.trim().length > 0);
  let message = parts.join(" • ");
  if (!message && record) {
    try { message = JSON.stringify(record); } catch { message = ""; }
  }
  if (message.includes("RECOVERY_REVISION_CONFLICT")) return "Ktoś inny zmienił ten miesiąc. Odświeżyliśmy dane — sprawdź je przed ponownym zapisem.";
  if (message.includes("ROLE_SCOPE_FORBIDDEN") || message.includes("ROLE_OR_LOCATION_SCOPE_FORBIDDEN")) return "Nie masz uprawnień do tej roli lub lokalizacji.";
  if (message.includes("EMPLOYEE_ACKNOWLEDGEMENT_REQUIRED")) return "Przekroczenie limitu godzin wymaga potwierdzenia poinformowania lub wymaganej zgody pracownika.";
  if (message.includes("EMPLOYMENT_COMPLIANCE_CONFIRMATION_REQUIRED")) return "Dla umowy o pracę lub części etatu właściciel musi najpierw potwierdzić kontrolę zgodności czasu pracy. Samo kliknięcie wyjątku nie legalizuje przydziału.";
  if (message.includes("INVALID_CONTRACT_TYPE")) return "Wybierz obsługiwany rodzaj współpracy: umowa o pracę, część etatu, zlecenie, B2B lub inna.";
  if (message.includes("RECOVERY_ACTION_CONFLICT")) return "Ten kandydat lub brak został już zmieniony w innej sesji. Odśwież incydent i wybierz ponownie.";
  if (message.includes("RECOVERY_CANDIDATE_HARD_BLOCKED")) return "Tej osoby nie można wybrać: ma twardą blokadę, nakładającą się zmianę albo nie ma wymaganej roli, lokalu lub obowiązku.";
  if (message.includes("RECOVERY_CANDIDATE_CHANGED")) return "Sytuacja kandydata zmieniła się od ostatniej analizy. System przerwał zapis przed naruszeniem grafiku — przygotuj propozycje ponownie.";
  if (message.includes("RECOVERY_CANDIDATE_SELECTION_REQUIRED")) return "Najpierw wybierz co najmniej jednego kandydata do wersji roboczej.";
  if (message.includes("LEADER_LIMIT_OVERRIDE_REQUIRED")) return "Wybrana osoba przekroczyłaby limit. Dodaj datowany wyjątek z uzasadnieniem i potwierdzeniem pracownika albo wybierz inną osobę.";
  if (message.includes("OWNER_REQUIRED")) return "Budżet bazowy może zmienić właściciel lub administrator.";
  if (message.includes("INVALID_INCIDENT_RANGE")) return "Zakres incydentu musi mieścić się w wybranym miesiącu.";
  return message && message !== "[object Object]"
    ? message
    : "Operacja Centrum napraw nie powiodła się. Odśwież dane i spróbuj ponownie; jeśli błąd wróci, zgłoś godzinę operacji administratorowi UAT.";
}
