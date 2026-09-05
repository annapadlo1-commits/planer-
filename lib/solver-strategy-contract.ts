export const STRATEGY_SEMANTICS_VERSION = "B4F170_V1";

export const SUPPORTED_STRATEGY_SEMANTICS_VERSIONS = [
  "B4F165_V1",
  "B4F168_V1",
  "B4F169_V1",
  STRATEGY_SEMANTICS_VERSION,
] as const;

export const MANDATORY_PRODUCT_GUARDS = [
  "HARD_CONSTRAINTS",
  "COVERAGE",
  "ROLE_BACKUP",
  "OVERTIME",
  "ZERO_HOURS",
  "PRIMARY_ROLE",
  "MAX_MIN_FAIRNESS",
  "FAIRNESS_SPREAD",
  "FAIRNESS_QUALITY_TARGET",
] as const;

export const MANDATORY_PRODUCT_GUARDS_LABEL =
  "MANDATORY PRODUCT GUARDS • obowiązkowe zabezpieczenia produktu";

export const MANDATORY_PRODUCT_GUARDS_DESCRIPTION =
  "Każdy wariant zachowuje kolejno: twarde reguły, najlepszą możliwą obsadę, konieczne role dodatkowe, minimalne nadgodziny, ochronę osób z zerową liczbą godzin, pierwszeństwo ról podstawowych oraz podstawowy sprawiedliwy podział. Dla wariantu „Preferencje i równy podział” silnik dąży dodatkowo do minimum 70% szacowanego celu i najwyżej 30 p.p. rozstępu. Jeżeli legalny grafik nie osiągnie tego poziomu jakości, aplikacja nadal pokaże najlepszy poprawny wynik z ostrzeżeniem.";

export const DEFAULT_STRATEGY_DESCRIPTIONS = {
  BALANCED:
    "Po zapewnieniu wymaganej obsady, zasad czasu pracy, minimalnych nadgodzin i podstawowego wyrównania zespołu łączy koszt, preferencje pracowników i dalszą równowagę obciążenia.",
  MIN_COST:
    "Minimalizuje koszt wśród grafików spełniających pełną obsadę, zasady czasu pracy, minimalne nadgodziny i podstawowe wymagania sprawiedliwego podziału.",
  PREFERENCES:
    "Najpierw sprawiedliwie rozdziela pracę względem celów i możliwości pracowników. Następnie wśród podobnie sprawiedliwych grafików możliwie najlepiej uwzględnia preferowane dni, zmiany i lokalizacje.",
} as const;

export const DEFAULT_STRATEGY_SOLVER_CONTRACT = {
  strategySemanticsVersion: STRATEGY_SEMANTICS_VERSION,
  mandatoryProductGuards: [...MANDATORY_PRODUCT_GUARDS],
  configurableObjectivesStartAfterMandatoryGuards: true,
} as const;
