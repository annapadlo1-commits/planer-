export type MonthWorkspaceGate = {
  selectedMonth: string;
  loadedMonth: string | null;
  failedMonth: string | null;
  requestId: number;
};

export type MonthWorkspaceRequest = {
  month: string;
  requestId: number;
};

export function createMonthWorkspaceGate(selectedMonth: string): MonthWorkspaceGate {
  return { selectedMonth, loadedMonth: null, failedMonth: null, requestId: 0 };
}

export function selectMonthWorkspace(gate: MonthWorkspaceGate, month: string) {
  if (gate.selectedMonth === month) return;
  gate.selectedMonth = month;
  gate.loadedMonth = null;
  gate.failedMonth = null;
  gate.requestId += 1;
}

export function beginMonthWorkspaceLoad(
  gate: MonthWorkspaceGate,
  month: string,
): MonthWorkspaceRequest {
  selectMonthWorkspace(gate, month);
  gate.requestId += 1;
  gate.failedMonth = null;
  return { month, requestId: gate.requestId };
}

export function isMonthWorkspaceRequestCurrent(
  gate: MonthWorkspaceGate,
  request: MonthWorkspaceRequest,
) {
  return gate.selectedMonth === request.month && gate.requestId === request.requestId;
}

export function completeMonthWorkspaceLoad(
  gate: MonthWorkspaceGate,
  request: MonthWorkspaceRequest,
) {
  if (!isMonthWorkspaceRequestCurrent(gate, request)) return false;
  gate.loadedMonth = request.month;
  gate.failedMonth = null;
  return true;
}

export function failMonthWorkspaceLoad(
  gate: MonthWorkspaceGate,
  request: MonthWorkspaceRequest,
) {
  if (!isMonthWorkspaceRequestCurrent(gate, request)) return false;
  gate.loadedMonth = null;
  gate.failedMonth = request.month;
  return true;
}

export function invalidateMonthWorkspaceRequests(gate: MonthWorkspaceGate) {
  gate.requestId += 1;
}

export function canUseMonthWorkspace(gate: MonthWorkspaceGate, month: string) {
  return gate.selectedMonth === month
    && gate.loadedMonth === month
    && gate.failedMonth === null;
}
