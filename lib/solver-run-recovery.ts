export type SolverRunRecoverySummary = {
  id: string;
  createdAt: string;
  scenario: { id: string };
  scope: { type: "COMPANY" | "ROLE"; roleId?: string | null };
};

export type SolverRunRecoveryContext = {
  scenarioId: string;
  scopeType: "COMPANY" | "ROLE";
  scopeRoleId?: string | null;
};

function recoveryTimestamp(value: string) {
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) ? timestamp : 0;
}

export function solverRunRecoveryCandidates<T extends SolverRunRecoverySummary>(
  runs: T[],
  context: SolverRunRecoveryContext,
  limit = 10,
) {
  const expectedRoleId = context.scopeRoleId ?? null;
  const safeLimit = Math.max(0, Math.floor(limit));
  return runs
    .filter(run => run.scenario.id === context.scenarioId)
    .filter(run => run.scope.type === context.scopeType)
    .filter(run => (run.scope.roleId ?? null) === expectedRoleId)
    .sort((left, right) => recoveryTimestamp(right.createdAt) - recoveryTimestamp(left.createdAt)
      || right.id.localeCompare(left.id))
    .slice(0, safeLimit);
}
