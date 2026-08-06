export type SolverVariantMetricPresentation = {
  code: string;
  label: string;
  value: string;
  explanation: string;
};

const HIDDEN_METRICS = new Set([
  "UNFILLED",
  "TOTAL_COST",
  // This is an obsolete technical invariant. A permanent work location is not
  // a supported business concept in the current configuration model.
  "HOME_LOCATION_VIOLATIONS",
  "NOMINAL_TARGET_EMPLOYEE_COUNT",
  "LOAD_UTILIZATION_TARGET_COUNT",
]);

const METRICS: Record<string, { label: string; explanation: string; unit?: "MINUTES" }> = {
  PREFERENCE_VIOLATIONS: {
    label: "Niespełnione prośby pracowników",
    explanation: "Ile miękkich preferencji dostępności nie udało się spełnić. Mniej oznacza wariant bliższy prośbom zespołu.",
  },
  NOMINAL_DEVIATION_MINUTES: {
    label: "Różnica względem planowanych godzin",
    explanation: "Łączna różnica między przydzielonym czasem a miesięcznym wymiarem osób, które mają ustawiony wymiar. Mniej oznacza lepsze dopasowanie.",
    unit: "MINUTES",
  },
  OVERTIME_MINUTES: {
    label: "Planowane nadgodziny",
    explanation: "Łączny czas ponad miesięczny wymiar pracy. Mniej oznacza mniejsze ryzyko nadgodzin.",
    unit: "MINUTES",
  },
  LOAD_SPREAD_MINUTES: {
    label: "Historyczna różnica czasu pracy",
    explanation: "Ten starszy wynik porównuje surowe minuty i nie uwzględnia różnych wymiarów pracy. Wygeneruj wariant ponownie, aby otrzymać miarodajne porównanie procentowe.",
    unit: "MINUTES",
  },
  LOAD_UTILIZATION_SPREAD_BPS: {
    label: "Różnica wykorzystania wymiaru pracy",
    explanation: "Różnica procentowa między najbardziej i najmniej obciążoną osobą, liczona względem jej miesięcznego wymiaru lub limitu. Mniej oznacza równiejszy podział.",
  },
  WEEKEND_SPREAD: {
    label: "Różnica liczby weekendów",
    explanation: "Różnica między największą i najmniejszą liczbą weekendowych przydziałów. Mniej oznacza równiejszy podział weekendów.",
  },
  BASELINE_CHANGES: {
    label: "Przydziały inne niż w grafiku bazowym",
    explanation: "Liczba przydziałów zmienionych względem wskazanego grafiku bazowego. Mniej oznacza mniej zmian dla zespołu.",
  },
};

function finiteNumber(value: unknown): number | null {
  const number = typeof value === "number" ? value : Number(value);
  return Number.isFinite(number) ? number : null;
}

export function formatDurationMinutes(value: unknown): string {
  const minutes = finiteNumber(value);
  if (minutes === null) return "—";
  const rounded = Math.round(Math.abs(minutes));
  const sign = minutes < 0 ? "−" : "";
  const hours = Math.floor(rounded / 60);
  const remainder = rounded % 60;
  if (!hours) return `${sign}${remainder} min`;
  if (!remainder) return `${sign}${hours} godz.`;
  return `${sign}${hours} godz. ${remainder} min`;
}

export function presentSolverVariantMetrics(metrics: Record<string, unknown>): SolverVariantMetricPresentation[] {
  return Object.entries(metrics).flatMap(([code, rawValue]) => {
    if (HIDDEN_METRICS.has(code)) return [];
    const definition = METRICS[code];
    if (!definition) return [];
    const nominalTargetCount = finiteNumber(metrics.NOMINAL_TARGET_EMPLOYEE_COUNT) ?? 0;
    const utilizationTargetCount = finiteNumber(metrics.LOAD_UTILIZATION_TARGET_COUNT) ?? 0;
    const value = code === "NOMINAL_DEVIATION_MINUTES" && nominalTargetCount === 0
      ? "Brak wymiarów"
      : code === "LOAD_UTILIZATION_SPREAD_BPS" && utilizationTargetCount < 2
        ? "Brak danych"
        : code === "LOAD_UTILIZATION_SPREAD_BPS"
          ? `${((finiteNumber(rawValue) ?? 0) / 10).toLocaleString("pl-PL", { maximumFractionDigits: 1 })}%`
          : definition.unit === "MINUTES"
      ? formatDurationMinutes(rawValue)
      : finiteNumber(rawValue)?.toLocaleString("pl-PL") ?? "—";
    const explanation = code === "NOMINAL_DEVIATION_MINUTES" && nominalTargetCount === 0
      ? "Nie ustawiono miesięcznego wymiaru żadnej osoby, więc zero nie oznacza idealnego dopasowania. Uzupełnij wymiary w danych pracowników i wygeneruj grafik ponownie."
      : code === "LOAD_UTILIZATION_SPREAD_BPS" && utilizationTargetCount < 2
        ? "Do porównania potrzeba co najmniej dwóch osób z miesięcznym wymiarem lub limitem czasu pracy."
        : definition.explanation;
    return [{ code, label: definition.label, explanation, value }];
  });
}
