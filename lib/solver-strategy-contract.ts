export const STRATEGY_SEMANTICS_VERSION = "B4F165_V1";

export const MANDATORY_PRODUCT_GUARDS = [
  "HARD_CONSTRAINTS",
  "COVERAGE",
  "ROLE_BACKUP",
  "OVERTIME",
  "ZERO_HOURS",
  "PRIMARY_ROLE",
  "MAX_MIN_FAIRNESS",
  "FAIRNESS_SPREAD",
] as const;

export const MANDATORY_PRODUCT_GUARDS_LABEL =
  "MANDATORY PRODUCT GUARDS • obowiązkowe zabezpieczenia produktu";

export const MANDATORY_PRODUCT_GUARDS_DESCRIPTION =
  "Każdy wariant zachowuje kolejno: twarde reguły, wymaganą obsadę, konieczne role dodatkowe, minimalne nadgodziny, ochronę osób z zerową liczbą godzin, pierwszeństwo ról podstawowych oraz podstawowy sprawiedliwy podział. Dopiero potem stosuje cele właściwe dla wybranej strategii.";

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
