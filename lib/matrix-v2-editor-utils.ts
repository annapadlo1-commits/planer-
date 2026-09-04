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
