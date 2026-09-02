export type UserSafeErrorOptions = {
  context: string;
  summary: string;
  nextStep: string;
  correlationId?: string;
  logger?: (...values: unknown[]) => void;
};

let fallbackSequence = 0;

function newCorrelationId() {
  const randomUuid = globalThis.crypto?.randomUUID?.();
  if (randomUuid) return `UI-${randomUuid.slice(0, 12).toUpperCase()}`;
  fallbackSequence = (fallbackSequence + 1) % 1_000_000;
  return `UI-${Date.now().toString(36).toUpperCase()}-${String(fallbackSequence).padStart(6, "0")}`;
}

function safeDiagnosticCode(value: unknown) {
  if (typeof value !== "string") return "UNAVAILABLE";
  const normalized = value.trim();
  return /^(?:[A-Z][A-Z0-9_]{1,63}|[0-9]{5})$/u.test(normalized)
    ? normalized
    : "UNAVAILABLE";
}

function safeDiagnostic(error: unknown) {
  const record = typeof error === "object" && error !== null
    ? error as Record<string, unknown>
    : {};
  const status = typeof record.status === "number"
    && Number.isInteger(record.status)
    && record.status >= 100
    && record.status <= 599
    ? record.status
    : undefined;
  return {
    kind: error instanceof Error ? "Error" : typeof error,
    code: safeDiagnosticCode(record.code),
    ...(status === undefined ? {} : { status }),
  };
}

export function userSafeErrorMessage(
  error: unknown,
  options: UserSafeErrorOptions,
) {
  const correlationId = options.correlationId ?? newCorrelationId();
  const logger = options.logger ?? console.error;
  logger(`[SZAFUNEK:${options.context}:${correlationId}]`, safeDiagnostic(error));
  return `${options.summary} ${options.nextStep} Jeśli problem wróci, przekaż wsparciu identyfikator: ${correlationId}.`;
}
