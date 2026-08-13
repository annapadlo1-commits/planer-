export type MatrixV2Version = {
  id: string;
  version: number;
  name: string;
  status: "ACTIVE" | "DRAFT" | "ARCHIVED";
  schema_version: number;
  effective_from?: string | null;
  base_version_id?: string | null;
  settings?: Partial<MatrixV2Settings> & { maxShiftsPerDay?: number };
};

export type MatrixV2Settings = {
  currency: string;
  timezone: string;
  minimumRestMinutes: number;
  maximumShiftsPerDay: number;
  standbyTiersPerRoleDay: number;
  missingAvailabilityMeansAvailable: boolean;
  requireOptimal: boolean;
};

export type MatrixV2NamedItem = {
  id: string;
  code: string;
  name: string;
  color?: string;
  description?: string | null;
  sort_order: number;
  active: boolean;
};

export type MatrixV2RoleCategory = MatrixV2NamedItem;
export type MatrixV2Role = MatrixV2NamedItem & { category_id?: string | null };
export type MatrixV2Location = MatrixV2NamedItem & { timezone: string };
export type MatrixV2Duty = MatrixV2NamedItem;
export type MatrixV2Shift = MatrixV2NamedItem & {
  location_id: string;
  starts_at: string;
  ends_at: string;
  ends_next_day: boolean;
  day_mask: number[];
  shift_period: "MORNING" | "MIDDLE" | "EVENING";
};
export type MatrixV2RoleDuty = {
  id: string;
  role_id: string;
  duty_id: string;
  assignment_mode: "REQUIRED" | "OPTIONAL" | "EXTRA";
  minimum_count: number;
  shift_obligation: boolean;
  shift_period?: "MORNING" | "MIDDLE" | "EVENING" | null;
  active: boolean;
};
export type MatrixV2ScenarioSettingsOverrides = Partial<Pick<MatrixV2Settings,
  "minimumRestMinutes" | "maximumShiftsPerDay" |
  "missingAvailabilityMeansAvailable" | "requireOptimal"
>> & { randomSeed?: number };
export type MatrixV2Scenario = MatrixV2NamedItem & {
  parent_scenario_id?: string | null;
  is_default: boolean;
  valid_from?: string | null;
  valid_to?: string | null;
  settings_overrides?: MatrixV2ScenarioSettingsOverrides;
};
export type MatrixV2StaffingRule = {
  id: string;
  scenario_id: string;
  shift_template_id: string;
  role_id: string;
  duty_id?: string | null;
  operation: "SET" | "ADD" | "MULTIPLY" | "REMOVE";
  count_value?: number | null;
  multiplier_basis_points?: number | null;
  active: boolean;
  source_metadata?: Record<string, unknown>;
};
export type MatrixV2Strategy = MatrixV2NamedItem & {
  solver_code: string;
  solver_options?: Record<string, unknown>;
};
export type MatrixV2Objective = {
  id: string;
  strategy_id: string;
  tier: number;
  sort_order: number;
  metric_code: string;
  direction: "MINIMIZE" | "MAXIMIZE";
  weight: number;
  tolerance: number;
  parameters?: Record<string, unknown>;
  active: boolean;
};
export type MatrixV2ScenarioStrategy = {
  id: string;
  scenario_id: string;
  strategy_id: string;
  sort_order: number;
  active: boolean;
  objective_overrides?: Record<string, unknown>;
  solver_overrides?: Record<string, unknown>;
};
export type MatrixV2PayRule = MatrixV2NamedItem & {
  calculation_method: string;
  amount_minor?: number | null;
  rate_minor_per_hour?: number | null;
  percent_basis_points?: number | null;
  multiplier_basis_points?: number | null;
  formula_expression?: Record<string, unknown> | null;
  condition_expression?: Record<string, unknown> | null;
  threshold_minutes?: number | null;
  currency: string;
  priority: number;
  stacking_group?: string | null;
  stacking_mode: "STACK" | "MAX" | "FIRST";
  day_mask: number[];
  local_start?: string | null;
  local_end?: string | null;
  ends_next_day: boolean;
  valid_from?: string | null;
  valid_to?: string | null;
};
export type MatrixV2PayScope = { pay_rule_id: string };
export type MatrixV2PayRole = MatrixV2PayScope & { role_id: string };
export type MatrixV2PayDuty = MatrixV2PayScope & { duty_id: string };
export type MatrixV2PayLocation = MatrixV2PayScope & { location_id: string };
export type MatrixV2PayShift = MatrixV2PayScope & { shift_template_id: string };
export type MatrixV2ScenarioPayRule = {
  id: string;
  scenario_id: string;
  pay_rule_id: string;
  enabled: boolean;
  amount_minor?: number | null;
  rate_minor_per_hour?: number | null;
  percent_basis_points?: number | null;
  multiplier_basis_points?: number | null;
  formula_expression?: Record<string, unknown> | null;
};
export type MatrixV2Budget = {
  id: string;
  scenario_id: string;
  budget_month?: string | null;
  location_id?: string | null;
  role_id?: string | null;
  duty_id?: string | null;
  operation: "SET" | "ADD" | "MULTIPLY" | "REMOVE";
  amount_minor?: number | null;
  multiplier_basis_points?: number | null;
  currency: string;
  hard_limit?: boolean | null;
  warning_percent?: number | null;
  source_metadata?: Record<string, unknown>;
};

export type MatrixV2Employee = {
  id: string;
  profileId?: string;
  employeeNo: string;
  firstName: string;
  lastName: string;
  email?: string | null;
  contractType?: "UMOWA_O_PRACE" | "ZLECENIE" | "CZESC_ETATU" | "B2B" | "INNE";
  employmentFraction?: number;
  workTimePolicy?: "CONTRACT_DEFAULT" | "CUSTOM";
  active: boolean;
  employmentStart?: string | null;
  employmentEnd?: string | null;
  employmentStage?: "REGULAR" | "PROBATION" | "NOTICE";
  probationEnd?: string | null;
  nominalMonthlyMinutes: number;
  maximumMonthlyMinutes: number;
  maximumWeeklyMinutes: number;
  maximumConsecutiveDays: number;
  minimumRestMinutes?: number | null;
  onlyMorning: boolean;
  onlyEvening: boolean;
  noWeekends: boolean;
  preferredShiftCode?: string | null;
  archivedAt?: string | null;
  archiveReason?: string | null;
  primaryRoleId?: string | null;
  locationIds?: string[];
  shiftPeriodPreferences?: Partial<Record<"MORNING" | "MIDDLE" | "EVENING", "INHERIT" | "PREFERRED" | "NEUTRAL" | "AVOIDED" | "BLOCKED">>;
};

export type MatrixV2PublicationBlocker = {
  code: "MISSING_PAY_RATE" | "MISSING_ROLE" | "MISSING_STANDARD_LOCATION" | string;
  employeeId?: string;
  employeeNo?: string;
  employeeName?: string;
  requiredFrom?: string;
  requiredTo?: string;
  shiftTemplateId?: string;
  shiftCode?: string;
  shiftName?: string;
  locationId?: string;
  startsAt?: string;
  endsAt?: string;
  endsNextDay?: boolean;
  expectedEndsNextDay?: boolean;
  message: string;
};

export type MatrixV2PublicationReadiness = {
  ready: boolean;
  blockers: MatrixV2PublicationBlocker[];
  effectiveFrom: string;
  scheduleMonth?: string;
  matrixVersionId: string;
};
export type MatrixV2EmployeeRole = {
  id: string;
  employee_id: string;
  role_id: string;
  is_primary: boolean;
  can_lead: boolean;
  assignment_mode?: "STANDARD" | "BACKUP";
  backup_priority?: number;
  active: boolean;
  valid_from?: string | null;
  valid_to?: string | null;
};
export type MatrixV2EmployeeLocation = {
  id: string;
  employee_id: string;
  location_id: string;
  standard_allowed: boolean;
  overtime_allowed: boolean;
  home_location: boolean;
  active: boolean;
  valid_from?: string | null;
  valid_to?: string | null;
};
export type MatrixV2EmployeeDuty = {
  id: string;
  employee_id: string;
  duty_id: string;
  role_id?: string | null;
  location_id?: string | null;
  active: boolean;
  valid_from?: string | null;
  valid_to?: string | null;
};
export type MatrixV2TimeConstraint = {
  id: string;
  employeeId: string;
  kind: "AVAILABLE_WINDOW" | "UNAVAILABLE" | "LEAVE" | "SICKNESS";
  startsAt: string;
  endsAt: string;
  source: string;
  editableByEmployee: boolean;
  status: "ACTIVE" | "REVOKED";
  note?: string | null;
};
export type MatrixV2PayRate = {
  id: string;
  employee_id: string;
  valid_from: string;
  valid_to?: string | null;
  base_rate_minor: number;
  currency: string;
  contract_type?: string | null;
  active: boolean;
};

export type MatrixV2Workspace = {
  matrixVersion: MatrixV2Version;
  month?: string | null;
  editable: boolean;
  financeVisible: boolean;
  featureFlag?: { engine?: string } | null;
  roleCategories?: MatrixV2RoleCategory[];
  roles: MatrixV2Role[];
  locations: MatrixV2Location[];
  duties: MatrixV2Duty[];
  shiftTemplates: MatrixV2Shift[];
  roleDuties: MatrixV2RoleDuty[];
  scenarios: MatrixV2Scenario[];
  staffingRules: MatrixV2StaffingRule[];
  strategies: MatrixV2Strategy[];
  strategyObjectives: MatrixV2Objective[];
  scenarioStrategies: MatrixV2ScenarioStrategy[];
  employees: MatrixV2Employee[];
  employeeRoles: MatrixV2EmployeeRole[];
  employeeLocations: MatrixV2EmployeeLocation[];
  employeeDuties: MatrixV2EmployeeDuty[];
  timeConstraints: MatrixV2TimeConstraint[];
  payRules: MatrixV2PayRule[];
  payRuleRoles: MatrixV2PayRole[];
  payRuleDuties: MatrixV2PayDuty[];
  payRuleLocations: MatrixV2PayLocation[];
  payRuleShifts: MatrixV2PayShift[];
  scenarioPayRuleOverrides: MatrixV2ScenarioPayRule[];
  scenarioBudgets: MatrixV2Budget[];
  employeePayRates: MatrixV2PayRate[];
  adHocWorkers?: MatrixV2AdHocWorker[];
  workforceHash?: string | null;
  workforceCounts?: { active: number; archived: number };
};

export type MatrixV2EmployeeDirectory = {
  matrixVersionId: string;
  workforceHash?: string | null;
  activeCount: number;
  archivedCount: number;
  employees: MatrixV2Employee[];
};

export type MatrixV2AdHocWorker = {
  id: string;
  employee_id?: string | null;
  display_name: string;
  email?: string | null;
  phone?: string | null;
  role_id: string;
  contract_type: "UMOWA_O_PRACE" | "ZLECENIE" | "CZESC_ETATU" | "B2B" | "INNE";
  base_rate_minor?: number | null;
  currency: string;
  available_from?: string | null;
  available_to?: string | null;
  active: boolean;
  notes?: string | null;
};

export type MatrixV2SaveKind =
  | "MATRIX_SETTINGS" | "ROLE" | "LOCATION" | "DUTY" | "SHIFT" | "ROLE_DUTY"
  | "SCENARIO" | "STAFFING_RULE" | "STRATEGY" | "OBJECTIVE"
  | "SCENARIO_STRATEGY" | "PAY_RULE" | "SCENARIO_PAY_RULE"
  | "SCENARIO_BUDGET" | "EMPLOYEE_ROLE" | "EMPLOYEE_LOCATION"
  | "EMPLOYEE_DUTY";

export const WEEKDAYS = [
  { value: 1, label: "Pon" }, { value: 2, label: "Wt" },
  { value: 3, label: "Śr" }, { value: 4, label: "Czw" },
  { value: 5, label: "Pt" }, { value: 6, label: "Sob" },
  { value: 7, label: "Niedz" },
];

export const OBJECTIVE_METRICS = [
  { value: "UNFILLED", label: "Liczba nieobsadzonych miejsc" },
  { value: "TOTAL_COST", label: "Całkowity koszt" },
  { value: "PREFERENCE_VIOLATIONS", label: "Niespełnione preferencje" },
  { value: "HOME_LOCATION_VIOLATIONS", label: "Wycofane kryterium lokalu macierzystego (zawsze 0)" },
  { value: "NOMINAL_DEVIATION_MINUTES", label: "Odchylenie od nominału" },
  { value: "OVERTIME_MINUTES", label: "Nadgodziny" },
  { value: "LOAD_SPREAD_MINUTES", label: "Różnica wykorzystania wymiarów pracy" },
  { value: "WEEKEND_SPREAD", label: "Nierówny podział weekendów" },
  { value: "BASELINE_CHANGES", label: "Zmiany względem planu bazowego" },
];

export function matrixV2Settings(version: MatrixV2Version): MatrixV2Settings {
  const source = version.settings;
  if (!source) throw new Error("INVALID_MATRIX_SETTINGS");
  const currency = String(source.currency ?? "").trim().toUpperCase();
  if (!/^[A-Z]{3}$/.test(currency)) throw new Error("INVALID_MATRIX_CURRENCY");
  const timezone = String(source.timezone ?? "").trim();
  if (!timezone) throw new Error("INVALID_MATRIX_TIMEZONE");
  try { new Intl.DateTimeFormat("en", { timeZone: timezone }).format(new Date(0)); }
  catch { throw new Error("INVALID_MATRIX_TIMEZONE"); }
  const minimumRestMinutes = Number(source.minimumRestMinutes);
  const maximumShiftsPerDay = Number(source.maximumShiftsPerDay ?? source.maxShiftsPerDay);
  const standbyTiersPerRoleDay = Number(source.standbyTiersPerRoleDay ?? 0);
  if (!Number.isInteger(minimumRestMinutes) || minimumRestMinutes < 0) throw new Error("INVALID_MATRIX_SETTINGS");
  if (!Number.isInteger(maximumShiftsPerDay) || maximumShiftsPerDay < 1 || maximumShiftsPerDay > 24) throw new Error("INVALID_MATRIX_SETTINGS");
  if (!Number.isInteger(standbyTiersPerRoleDay) || standbyTiersPerRoleDay < 0 || standbyTiersPerRoleDay > 2) throw new Error("INVALID_MATRIX_SETTINGS");
  if (typeof source.missingAvailabilityMeansAvailable !== "boolean" || typeof source.requireOptimal !== "boolean") {
    throw new Error("INVALID_MATRIX_SETTINGS");
  }
  return {
    currency,
    timezone,
    minimumRestMinutes,
    maximumShiftsPerDay,
    standbyTiersPerRoleDay,
    missingAvailabilityMeansAvailable: source.missingAvailabilityMeansAvailable,
    requireOptimal: source.requireOptimal,
  };
}

export function itemName<T extends { id: string; name: string }>(items: T[], id?: string | null) {
  return items.find(item => item.id === id)?.name ?? "Cała firma";
}

export function objectiveName(code: string) {
  return OBJECTIVE_METRICS.find(item => item.value === code)?.label ?? "Dodatkowe kryterium";
}

export function matrixV2ErrorMessage(message: string) {
  const value = message.toUpperCase();
  const correlatedImportError = message.match(/MATRIX_IMPORT_(?:PREVIEW|APPLY)_FAILED\|([^|]+)\|([^|]+)\|(.+)/i);
  if (correlatedImportError) {
    return `Import nie został zapisany z powodu błędu systemowego. Identyfikator: ${correlatedImportError[1]}. Żadne dane z pliku nie zostały zastosowane.`;
  }
  if (value.includes("MATRIX_IMPORT_CONTRACT_INCOMPLETE") ||
      value.includes("MATRIX_IMPORT_PREREQUISITE_MISSING") ||
      value.includes("MATRIX_V2_IMPORT_PREVIEW_UAT_V2") ||
      value.includes("MATRIX_V2_IMPORT_APPLY_UAT_V2")) {
    return "Import jest chwilowo niedostępny, ponieważ środowisko UAT nie ma kompletnej wersji mechanizmu importu. Żadne dane z pliku nie zostały zastosowane.";
  }
  if (value.includes("INVALID_MATRIX_SETTINGS")) return "Opublikowana konfiguracja firmy nie ma kompletnych ustawień.";
  if (value.includes("INVALID_MATRIX_TIMEZONE")) return "Konfiguracja firmy musi mieć prawidłową, jawnie wybraną strefę czasową.";
  if (value.includes("ACTIVE_EMPLOYEE_REQUIRES_ROLE_AND_LOCATION")) return "Każdy aktywny pracownik musi mieć co najmniej jedną aktywną rolę i dostęp do co najmniej jednego lokalu.";
  if (value.includes("ACTIVE_EMPLOYEE_REQUIRES_PAY_RATE")) return "Co najmniej jeden aktywny pracownik nie ma stawki obowiązującej w miesiącu grafiku. Otwórz listę blokad, aby zobaczyć konkretną osobę.";
  if (value.includes("ACTIVE_EMPLOYEE_REQUIRES_STANDARD_LOCATION")) return "Wybierz co najmniej jeden lokal, w którym pracownik może pracować w zwykłym limicie.";
  if (value.includes("MATRIX_WORKFORCE_VERSION_IMMUTABLE")) return "Opublikowane dane pracownika są historyczne i nie mogą być zmieniane. Utwórz nową wersję roboczą konfiguracji firmy.";
  if (value.includes("MATRIX_EMPLOYEE_NOT_FOUND")) return "Nie znaleziono pracownika w bieżącej wersji roboczej konfiguracji firmy.";
  if (value.includes("EMPLOYEE_NUMBER_ALREADY_EXISTS")) return "Ten numer pracownika jest już używany.";
  if (value.includes("EMPLOYEE_EMAIL_ALREADY_EXISTS")) return "Ten adres e-mail jest już przypisany do innego pracownika.";
  if (value.includes("EMPLOYEE_IDENTITY_REQUIRED")) return "Podaj numer pracownika, imię i nazwisko.";
  if (value.includes("INVALID_SHIFT_PERIOD") || value.includes("SHIFT_PERIOD_REQUIRED")) return "Wybierz okres zmiany: poranna, środek albo wieczorna.";
  if (value.includes("INVALID_SHIFT_PERIOD_PREFERENCES") || value.includes("INVALID_SHIFT_PREFERENCE_LEVEL")) return "Preferencje okresów zmian zawierają nieprawidłową wartość.";
  if (value.includes("MATRIX_IMPORT_HAS_ERRORS")) return "Import zawiera błędy. Wróć do podglądu i popraw wskazane wiersze.";
  if (value.includes("ROLE_CATEGORY_NOT_FOUND")) return "Nie znaleziono kategorii grafiku wskazanej przy roli. Sprawdź arkusz „Kategorie grafików” oraz kolumnę „Kod kategorii” w arkuszu „Role”.";
  if (value.includes("INVALID_EMPLOYMENT_DATES")) return "Data zakończenia zatrudnienia nie może być wcześniejsza od daty rozpoczęcia.";
  if (value.includes("EMPLOYMENT_DATES_CONFLICT_PAY_RATES")) return "Nowy okres zatrudnienia jest sprzeczny z zapisaną historią stawek. Najpierw popraw daty odpowiednich okresów stawki.";
  if (value.includes("PAY_RATE_BEFORE_EMPLOYMENT")) return "Stawka nie może obowiązywać przed datą rozpoczęcia zatrudnienia.";
  if (value.includes("PAY_RATE_OUTSIDE_EMPLOYMENT")) return "Okres stawki musi mieścić się w okresie zatrudnienia pracownika.";
  if (value.includes("OVERLAPPING_ACTIVE_PAY_RATE")) return "Ten okres nakłada się na inną aktywną stawkę pracownika. Zakończ poprzedni okres albo edytuj istniejący wpis.";
  if (value.includes("INVALID_PAY_RATE")) return "Sprawdź datę rozpoczęcia, datę zakończenia i kwotę stawki.";
  if (value.includes("INVALID_EMPLOYEE_LIMITS")) return "Sprawdź nominał, limity czasu pracy i ograniczenia pracownika.";
  if (value.includes("MIXED_CURRENCIES_UNSUPPORTED")) return "Konfiguracja firmy może używać tylko jednej waluty rozliczeniowej. Ujednolić stawki, dodatki i budżety przed publikacją.";
  if (value.includes("INVALID_MATRIX_CURRENCY")) return "Waluta firmy musi być prawidłowym trzyliterowym kodem, np. PLN, EUR lub USD.";
  if (value.includes("FORBIDDEN")) return "Tylko właściciel lub administrator może zmieniać konfigurację firmy.";
  if (value.includes("EXACTLY_ONE_ACTIVE_DEFAULT_SCENARIO_REQUIRED")) return "Wybierz dokładnie jeden aktywny scenariusz domyślny.";
  if (value.includes("DEFAULT_SCENARIO_CANNOT_INHERIT")) return "Scenariusz domyślny nie może dziedziczyć po innym scenariuszu.";
  if (value.includes("SCENARIO_INHERITANCE_CYCLE")) return "Scenariusze tworzą zamknięty łańcuch dziedziczenia. Zmień scenariusz nadrzędny.";
  if (value.includes("ACTIVE_SCENARIO_HAS_INACTIVE_PARENT")) return "Aktywny scenariusz nie może dziedziczyć po wyłączonym scenariuszu.";
  if (value.includes("ACTIVE_SCENARIO_WITHOUT_ACTIVE_STRATEGY")) return "Każdy aktywny scenariusz musi mieć co najmniej jedną aktywną strategię.";
  if (value.includes("ACTIVE_STRATEGY_REQUIRES_TIER1_UNFILLED_OBJECTIVE")) return "Każda aktywna strategia musi zaczynać od minimalizacji braków na poziomie 1.";
  if (value.includes("ACTIVE_ROLE_LOCATION_SHIFT_AND_STRATEGY_REQUIRED")) return "Konfiguracja firmy wymaga aktywnej roli, lokalu, zmiany i wariantu biznesowego.";
  if (value.includes("ACTIVE_STAFFING_RULE_REFERENCES_INACTIVE_SCOPE")) return "Aktywna reguła obsady odwołuje się do wyłączonego elementu.";
  if (value.includes("INVALID_LOCATION_TIMEZONE")) return "Jedna z lokalizacji ma nieprawidłową strefę czasową.";
  if (value.includes("SHIFT_OVERNIGHT_FLAG_INCONSISTENT")) return "Zmiana kończąca się o wcześniejszej godzinie musi mieć zaznaczone „następny dzień”; przy późniejszej godzinie to oznaczenie musi być wyłączone.";
  if (value.includes("SHIFT_DAY_MASK_CONTAINS_DUPLICATES")) return "Dni tygodnia w zmianie nie mogą się powtarzać.";
  if (value.includes("EFFECTIVE_FROM_PRECEDES_ACTIVE_MATRIX")) return "Data obowiązywania nie może być wcześniejsza niż data obecnie opublikowanej konfiguracji.";
  if (value.includes("FUTURE_MATRIX_ACTIVATION_REQUIRES_SCHEDULER")) return "Przyszła wersja konfiguracji wymaga zaplanowanej aktywacji. Na tym etapie opublikuj ją najwcześniej w dniu rozpoczęcia obowiązywania.";
  if (value.includes("NO_MATRIX_V2_DRAFT")) return "Nie ma wersji roboczej do opublikowania.";
  if (value.includes("SCHEDULE_PUBLICATION_CONFLICT_REQUIRES_OWNER_RESOLUTION") ||
      value.includes("COMPANY_PUBLICATION_CONFLICTS_WITH_PUBLISHED_ROLES") ||
      value.includes("ROLE_PUBLICATION_CONFLICTS_WITH_COMPANY_SCHEDULE")) {
    return "Dla tego miesiąca istnieją konkurencyjne publikacje grafiku roli i firmy. System nie wybierze jednej po cichu — właściciel musi najpierw rozstrzygnąć konflikt.";
  }
  if (value.includes("UNIQUE") || value.includes("DUPLICATE")) return "Taki element lub powiązanie już istnieje w tej wersji konfiguracji.";
  if (value.includes('INVALID INPUT SYNTAX FOR TYPE INTEGER: ""')) {
    return "Importer utworzył pustą wartość techniczną w polu liczbowym. To błąd mapowania pliku, a nie komórka, którą użytkownik ma odgadnąć. Żadne dane nie zostały zastosowane.";
  }
  if (value.includes("CHECK CONSTRAINT") || value.includes("INVALID")) return "Jedna z wartości nie spełnia reguł konfiguracji firmy. Sprawdź formularz.";
  return "Nie udało się zapisać zmiany. Sprawdź formularz i spróbuj ponownie.";
}
