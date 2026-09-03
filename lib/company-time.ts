export type CompanyTimeContext = {
  timezone: string;
  currentMonth: string;
  matrixVersionId: string;
  matrixVersion: number;
  matrixStatus: "ACTIVE" | "DRAFT";
};

export class CompanyTimeConfigurationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CompanyTimeConfigurationError";
  }
}

export function requireIanaTimeZone(value: unknown) {
  const timezone = typeof value === "string" ? value.trim() : "";
  if (!timezone) {
    throw new CompanyTimeConfigurationError(
      "Brakuje strefy czasowej firmy. Przejdź do Konfiguracja firmy → Firma i lokale, ustaw strefę IANA i opublikuj konfigurację.",
    );
  }
  try {
    new Intl.DateTimeFormat("en", { timeZone: timezone }).format(0);
  } catch {
    throw new CompanyTimeConfigurationError(
      "Strefa czasowa firmy jest nieprawidłowa. Przejdź do Konfiguracja firmy → Firma i lokale, wybierz poprawną strefę IANA i opublikuj konfigurację.",
    );
  }
  return timezone;
}

export function businessMonthAt(instant: Date, timezoneValue: unknown) {
  const timezone = requireIanaTimeZone(timezoneValue);
  if (Number.isNaN(instant.getTime())) {
    throw new CompanyTimeConfigurationError("Nie można ustalić bieżącego miesiąca firmy z nieprawidłowego czasu.");
  }
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: timezone,
    year: "numeric",
    month: "2-digit",
  }).formatToParts(instant);
  const year = parts.find(part => part.type === "year")?.value;
  const month = parts.find(part => part.type === "month")?.value;
  if (!year || !month) throw new CompanyTimeConfigurationError("Nie można ustalić bieżącego miesiąca firmy.");
  return `${year}-${month}`;
}

export function isBusinessMonth(value: unknown): value is string {
  return typeof value === "string" && /^\d{4}-(?:0[1-9]|1[0-2])$/u.test(value);
}

export function parseCompanyTimeContext(value: unknown): CompanyTimeContext {
  if (!value || typeof value !== "object") {
    throw new CompanyTimeConfigurationError("Serwer nie zwrócił kontekstu czasu firmy.");
  }
  const raw = value as Record<string, unknown>;
  const timezone = requireIanaTimeZone(raw.timezone);
  const currentMonth = raw.currentMonth ?? raw.current_month;
  const matrixVersionId = raw.matrixVersionId ?? raw.matrix_version_id;
  const matrixVersion = Number(raw.matrixVersion ?? raw.matrix_version);
  const matrixStatus = raw.matrixStatus ?? raw.matrix_status;
  if (!isBusinessMonth(currentMonth) || typeof matrixVersionId !== "string" || !matrixVersionId
    || !Number.isInteger(matrixVersion) || matrixVersion < 1
    || (matrixStatus !== "ACTIVE" && matrixStatus !== "DRAFT")) {
    throw new CompanyTimeConfigurationError("Serwer zwrócił niepełny kontekst czasu firmy.");
  }
  return { timezone, currentMonth, matrixVersionId, matrixVersion, matrixStatus };
}

export function initialBusinessMonth(companyMonth: unknown, fromUrl?: unknown, fromSession?: unknown) {
  if (!isBusinessMonth(companyMonth)) {
    throw new CompanyTimeConfigurationError("Brakuje potwierdzonego miesiąca firmy.");
  }
  return [fromUrl, fromSession].find(isBusinessMonth) ?? companyMonth;
}
