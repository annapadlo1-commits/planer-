import type { MatrixV2Workspace } from "@/lib/matrix-v2";

export const operationLabel: Record<string, string> = {
  SET: "Ustaw",
  ADD: "Dodaj",
  MULTIPLY: "Pomnóż",
  REMOVE: "Usuń wymaganie",
};

export const payMethodLabel: Record<string, string> = {
  FIXED_PER_SHIFT: "Stała kwota za zmianę",
  PER_HOUR: "Kwota za godzinę",
  PERCENT_BASE: "Procent stawki podstawowej",
  MULTIPLIER: "Mnożnik stawki",
  SHIFT_DURATION_THRESHOLD_PER_HOUR: "Dodatek po długości zmiany",
  MONTHLY_THRESHOLD_PER_HOUR: "Dodatek po progu miesięcznym",
};

export function shortTime(value?: string | null) {
  return value ? value.slice(0, 5) : "—";
}

export function money(value: number | null | undefined, currency: string) {
  if (value === undefined || value === null) return "—";
  try {
    return new Intl.NumberFormat("pl-PL", { style: "currency", currency }).format(value / 100);
  } catch {
    return `${new Intl.NumberFormat("pl-PL", { maximumFractionDigits: 2 }).format(value / 100)} ${currency}`;
  }
}

export function plural(value: number, one: string, few: string, many: string) {
  if (value === 1) return `${value} ${one}`;
  if (value >= 2 && value <= 4) return `${value} ${few}`;
  return `${value} ${many}`;
}

export function contractTypeLabel(value?: string | null) {
  return ({
    UMOWA_O_PRACE: "Umowa o pracę",
    CZESC_ETATU: "Część etatu",
    ZLECENIE: "Umowa zlecenie",
    B2B: "B2B",
    INNE: "Inna",
  } as Record<string, string>)[value ?? "INNE"] ?? "Inna";
}

export function localToday(timezone: string, now = new Date()) {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en", {
      timeZone: timezone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).formatToParts(now).filter(part => part.type !== "literal").map(part => [part.type, part.value]),
  );
  return `${parts.year}-${parts.month}-${parts.day}`;
}

export function scenarioHasActiveStrategy(
  scenarioId: string,
  scenarios: MatrixV2Workspace["scenarios"],
  links: MatrixV2Workspace["scenarioStrategies"],
  activeStrategyIds: Set<string>,
) {
  const scenarioById = new Map(scenarios.map(scenario => [scenario.id, scenario]));
  const resolved = new Map<string, boolean>();
  const visited = new Set<string>();
  let current = scenarioById.get(scenarioId);
  let depth = 0;

  while (current) {
    if (depth > 32 || visited.has(current.id)) return false;
    const currentId = current.id;
    visited.add(currentId);
    for (const link of links.filter(item => item.scenario_id === currentId)) {
      if (!resolved.has(link.strategy_id)) resolved.set(link.strategy_id, link.active);
    }
    if (!current.parent_scenario_id) break;
    current = scenarioById.get(current.parent_scenario_id);
    depth += 1;
  }

  return [...resolved].some(([strategyId, active]) => active && activeStrategyIds.has(strategyId));
}

export function activeBusinessObjectives(data: MatrixV2Workspace, strategyId: string) {
  return data.strategyObjectives.filter(objective =>
    objective.strategy_id === strategyId
    && objective.active
    && objective.metric_code !== "HOME_LOCATION_VIOLATIONS"
  );
}

export function strategySignature(data: MatrixV2Workspace, strategyId: string) {
  return activeBusinessObjectives(data, strategyId).map(objective => ({
    metric: objective.metric_code,
    tier: objective.tier,
    direction: objective.direction,
    weight: objective.weight,
    tolerance: objective.tolerance,
    parameters: objective.parameters ?? {},
  })).sort((left, right) => left.tier - right.tier || left.metric.localeCompare(right.metric))
    .map(value => JSON.stringify(value))
    .join("|");
}

export function strategyRelativeLevel(data: MatrixV2Workspace, strategyId: string, metric: string) {
  const strategies = data.strategies.filter(strategy => strategy.active);
  const values = strategies.map(strategy => {
    const objective = activeBusinessObjectives(data, strategy.id).find(item => item.metric_code === metric);
    return { strategyId: strategy.id, tier: objective?.tier ?? 101, weight: objective?.weight ?? 0 };
  });
  const current = values.find(value => value.strategyId === strategyId) ?? { tier: 101, weight: 0 };
  const ordered = [...values].sort((left, right) => left.tier - right.tier || right.weight - left.weight);
  const best = ordered[0];
  const worst = ordered.at(-1)!;
  if (values.every(value => value.tier === best.tier && value.weight === best.weight)) {
    return { className: "same", label: "Taki sam nacisk" };
  }
  if (current.tier === best.tier && current.weight === best.weight) {
    return { className: "high", label: "Najwyższy priorytet" };
  }
  if (current.tier === worst.tier && current.weight === worst.weight) {
    return { className: "low", label: "Najniższy priorytet" };
  }
  return { className: "medium", label: "Pośredni nacisk" };
}

export function strategyDistinguishers(data: MatrixV2Workspace, strategyId: string) {
  return activeBusinessObjectives(data, strategyId)
    .filter(objective => objective.metric_code !== "UNFILLED")
    .map(objective => ({ objective, level: strategyRelativeLevel(data, strategyId, objective.metric_code) }))
    .filter(item => item.level.className === "high")
    .sort((left, right) => right.objective.weight - left.objective.weight)
    .slice(0, 3);
}
