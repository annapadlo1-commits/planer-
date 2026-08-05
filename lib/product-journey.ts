import type {
  MatrixV2PublicationBlocker,
  MatrixV2PublicationReadiness,
  MatrixV2Workspace,
} from "@/lib/matrix-v2";

export type ManagementSection = "start" | "team" | "schedule" | "operations" | "analytics" | "settings";
export type EmployeeSection = "my-schedule" | "company-schedule" | "availability" | "swaps" | "messages" | "time";
export type ProductSection = ManagementSection | EmployeeSection;
export type SetupSection = "structure" | "workforce" | "strategies" | "finance";
export type SetupStepKey = "company" | "roles" | "shifts" | "employees" | "variants" | "readiness";
export type SetupStepState = "complete" | "current" | "blocked";

export type ProductNavigationItem = {
  key: ProductSection;
  label: string;
  description: string;
};

export type ConfigurationStep = {
  key: SetupStepKey;
  label: string;
  description: string;
  detail: string;
  section: SetupSection;
  complete: boolean;
  state: SetupStepState;
};

export type ConfigurationJourney = {
  steps: ConfigurationStep[];
  completed: number;
  total: number;
  percent: number;
  ready: boolean;
  next: ConfigurationStep | null;
  blockers: MatrixV2PublicationReadiness["blockers"];
};

export type SetupFocus = {
  employeeId?: string;
  targetId?: string;
};

export type ConfigurationBlockerAction = {
  section: SetupSection;
  step: SetupStepKey;
  focus?: SetupFocus;
  title: string;
  message: string;
  actionLabel: string;
};

const MANAGEMENT_ROLES = new Set(["OWNER", "ADMIN", "HR_FINANCE", "ROLE_MANAGER", "LOCATION_MANAGER", "VERIFIER"]);

export const managementNavigation: ProductNavigationItem[] = [
  { key: "start", label: "Start", description: "Stan firmy i następna najlepsza akcja" },
  { key: "team", label: "Zespół", description: "Pracownicy, role i zespoły" },
  { key: "schedule", label: "Grafik", description: "Przygotowanie, warianty i publikacja" },
  { key: "operations", label: "Operacje", description: "Alerty, kalendarz i bieżące sprawy" },
  { key: "analytics", label: "Analizy", description: "Koszt, pokrycie i jakość planu" },
  { key: "settings", label: "Ustawienia", description: "Prowadzona konfiguracja firmy" },
];

export const employeeNavigation: ProductNavigationItem[] = [
  { key: "my-schedule", label: "Mój grafik", description: "Moje zmiany i stand-by" },
  { key: "company-schedule", label: "Grafik firmy", description: "Kto pracuje w danym dniu" },
  { key: "availability", label: "Dostępność", description: "Kiedy mogę pracować" },
  { key: "swaps", label: "Zamiany", description: "Prośby i ogłoszenia o zamianie" },
  { key: "messages", label: "Wiadomości", description: "Komunikacja w zespole" },
  { key: "time", label: "Czas pracy", description: "Moja ewidencja czasu" },
];

export function isEmployeePersona(roles: { app_role: string }[] | null | undefined) {
  const names = roles?.map(role => role.app_role) ?? [];
  return names.length > 0 && !names.some(role => MANAGEMENT_ROLES.has(role));
}

export function sectionFromPath(pathname: string, employee: boolean): ProductSection {
  const requested = pathname.split("/").filter(Boolean)[0] ?? "";
  const allowed = employee ? employeeNavigation : managementNavigation;
  return allowed.some(item => item.key === requested)
    ? requested as ProductSection
    : employee ? "my-schedule" : "start";
}

export function pathForSection(section: ProductSection) {
  return section === "start" ? "/" : `/${section}`;
}

function rateCoversMonth(rate: MatrixV2Workspace["employeePayRates"][number], month: string) {
  const monthStart = `${month}-01`;
  const [year, monthNumber] = month.split("-").map(Number);
  const monthEnd = `${month}-${String(new Date(year, monthNumber, 0).getDate()).padStart(2, "0")}`;
  return rate.active && rate.valid_from <= monthEnd && (!rate.valid_to || rate.valid_to >= monthStart);
}

function displayIsoDate(value: string) {
  const [year, month, day] = value.slice(0, 10).split("-");
  return year && month && day ? `${day}.${month}.${year}` : value;
}

export function configurationBlockerAction(
  blocker: MatrixV2PublicationBlocker,
  data: MatrixV2Workspace,
  month: string,
): ConfigurationBlockerAction {
  const title = blocker.employeeName ?? blocker.shiftName ?? "Konfiguracja firmy";
  if (blocker.employeeId && blocker.code === "MISSING_PAY_RATE") {
    const employee = data.employees.find(item => item.id === blocker.employeeId);
    const [year, monthNumber] = month.split("-").map(Number);
    const monthStart = `${month}-01`;
    const monthEnd = `${month}-${String(new Date(year, monthNumber, 0).getDate()).padStart(2, "0")}`;
    const requiredFrom = blocker.requiredFrom ?? (employee?.employmentStart && employee.employmentStart > monthStart ? employee.employmentStart : monthStart);
    const requiredTo = blocker.requiredTo ?? (employee?.employmentEnd && employee.employmentEnd < monthEnd ? employee.employmentEnd : monthEnd);
    return {
      section: "workforce",
      step: "employees",
      focus: { employeeId: blocker.employeeId, targetId: `matrix-v2-rate-${blocker.employeeId}` },
      title,
      message: `Dodaj aktywną stawkę obejmującą cały wymagany okres: ${displayIsoDate(requiredFrom)}–${displayIsoDate(requiredTo)}. Pole „Do” może zostać puste, jeśli stawka obowiązuje dalej.`,
      actionLabel: "Uzupełnij stawkę",
    };
  }
  if (blocker.employeeId && blocker.code === "MISSING_ROLE") {
    return {
      section: "workforce",
      step: "employees",
      focus: { employeeId: blocker.employeeId, targetId: "configuration-step-employees" },
      title,
      message: "Przypisz pracownikowi co najmniej jedną aktywną rolę. Dodatkowe obowiązki nadal są opcjonalne.",
      actionLabel: "Przypisz rolę",
    };
  }
  if (blocker.employeeId && blocker.code === "MISSING_STANDARD_LOCATION") {
    return {
      section: "workforce",
      step: "employees",
      focus: { employeeId: blocker.employeeId, targetId: "configuration-step-employees" },
      title,
      message: "Wskaż co najmniej jeden zwykły lokal pracy dla tego pracownika.",
      actionLabel: "Przypisz lokal",
    };
  }
  if (blocker.employeeId) {
    return {
      section: "workforce",
      step: "employees",
      focus: { employeeId: blocker.employeeId, targetId: "configuration-step-employees" },
      title,
      message: blocker.message,
      actionLabel: "Otwórz profil",
    };
  }
  return {
    section: "structure",
    step: "shifts",
    focus: blocker.shiftTemplateId ? { targetId: "configuration-step-shifts" } : undefined,
    title,
    message: blocker.message,
    actionLabel: blocker.shiftTemplateId ? "Otwórz zmianę" : "Otwórz konfigurację",
  };
}

function withSequentialState(steps: Omit<ConfigurationStep, "state">[]): ConfigurationStep[] {
  let foundCurrent = false;
  return steps.map(step => {
    if (step.complete) return { ...step, state: "complete" };
    if (!foundCurrent) {
      foundCurrent = true;
      return { ...step, state: "current" };
    }
    return { ...step, state: "blocked" };
  });
}

export function configurationJourney(
  data: MatrixV2Workspace,
  month: string,
  serverReadiness?: MatrixV2PublicationReadiness | null,
): ConfigurationJourney {
  const activeLocations = data.locations.filter(item => item.active);
  const activeRoles = data.roles.filter(item => item.active);
  const activeDuties = data.duties.filter(item => item.active);
  const activeShifts = data.shiftTemplates.filter(item => item.active);
  const activeEmployees = data.employees.filter(item => item.active);
  const defaultScenarios = data.scenarios.filter(item => item.active && item.is_default);
  const defaultScenario = defaultScenarios[0];
  const baseRules = data.staffingRules.filter(rule =>
    rule.active && rule.scenario_id === defaultScenario?.id && rule.operation === "SET" && Number(rule.count_value) >= 1,
  );
  const coveredShifts = new Set(baseRules.map(rule => rule.shift_template_id));
  const validSettings = Boolean(
    data.matrixVersion.settings?.timezone &&
    /^[A-Z]{3}$/.test(String(data.matrixVersion.settings?.currency ?? "")),
  );
  const completeEmployees = activeEmployees.filter(employee => {
    const hasRole = data.employeeRoles.some(item => item.employee_id === employee.id && item.active);
    const hasLocation = data.employeeLocations.some(item => item.employee_id === employee.id && item.active && item.standard_allowed);
    const hasRate = !data.financeVisible || data.employeePayRates.some(rate => rate.employee_id === employee.id && rateCoversMonth(rate, month));
    return hasRole && hasLocation && hasRate;
  });
  const activeStrategyIds = new Set(data.strategies.filter(item => item.active).map(item => item.id));
  const linkedStrategies = data.scenarioStrategies.filter(item =>
    item.active && item.scenario_id === defaultScenario?.id && activeStrategyIds.has(item.strategy_id),
  );
  const baseComplete = [
    validSettings && activeLocations.length > 0,
    activeRoles.length > 0,
    activeShifts.length > 0 && activeShifts.every(shift => coveredShifts.has(shift.id)),
    activeEmployees.length > 0 && completeEmployees.length === activeEmployees.length,
    defaultScenarios.length === 1 && linkedStrategies.length > 0,
  ];
  const readinessComplete = baseComplete.every(Boolean) && (data.editable ? serverReadiness?.ready === true : true);
  const rawSteps: Omit<ConfigurationStep, "state">[] = [
    {
      key: "company", label: "Firma i lokale", section: "structure", complete: baseComplete[0],
      description: "Ustaw strefę czasową, walutę i miejsca pracy.",
      detail: `${activeLocations.length} ${activeLocations.length === 1 ? "aktywny lokal" : "aktywnych lokali"}`,
    },
    {
      key: "roles", label: "Role i opcjonalne obowiązki", section: "structure", complete: baseComplete[1],
      description: "Dodaj role. Obowiązek przypisz tylko tam, gdzie jest rzeczywiście potrzebny.",
      detail: `${activeRoles.length} ról • ${activeDuties.length} opcjonalnych obowiązków`,
    },
    {
      key: "shifts", label: "Zmiany i obsada", section: "structure", complete: baseComplete[2],
      description: "W jednej karcie ustaw godziny, dni, role i liczbę osób.",
      detail: `${coveredShifts.size}/${activeShifts.length} zmian ma bazową obsadę`,
    },
    {
      key: "employees", label: "Pracownicy", section: "workforce", complete: baseComplete[3],
      description: "Uzupełnij role, lokale i wymagane stawki zespołu.",
      detail: `${completeEmployees.length}/${activeEmployees.length} kompletnych profili`,
    },
    {
      key: "variants", label: "Warianty biznesowe", section: "strategies", complete: baseComplete[4],
      description: "Wybierz scenariusz bazowy i strategie porównania.",
      detail: `${linkedStrategies.length} ${linkedStrategies.length === 1 ? "aktywny wariant" : "aktywnych wariantów"}`,
    },
    {
      key: "readiness", label: "Kontrola gotowości", section: "structure", complete: readinessComplete,
      description: "Serwer sprawdza blokery przed publikacją i uruchomieniem solvera.",
      detail: serverReadiness
        ? serverReadiness.ready ? "Brak blokad serwera" : `${serverReadiness.blockers.length} blokad serwera`
        : data.editable ? "Oczekiwanie na kontrolę serwera" : "Aktywna konfiguracja",
    },
  ];
  const steps = withSequentialState(rawSteps);
  const completed = steps.filter(step => step.complete).length;
  return {
    steps,
    completed,
    total: steps.length,
    percent: Math.round(completed / steps.length * 100),
    ready: completed === steps.length,
    next: steps.find(step => !step.complete) ?? null,
    blockers: serverReadiness?.blockers ?? [],
  };
}
