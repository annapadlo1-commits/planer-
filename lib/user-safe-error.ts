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

function errorDetail(error: unknown) {
  if (error instanceof Error) return error.message;
  if (typeof error === "string") return error;
  try {
    return JSON.stringify(error);
  } catch {
    return "UNSERIALIZABLE_ERROR";
  }
}

export function userSafeErrorMessage(
  error: unknown,
  options: UserSafeErrorOptions,
) {
  const correlationId = options.correlationId ?? newCorrelationId();
  const logger = options.logger ?? console.error;
  logger(`[SZAFUNEK:${options.context}:${correlationId}]`, errorDetail(error));
  return `${options.summary} ${options.nextStep} Jeśli problem wróci, przekaż wsparciu identyfikator: ${correlationId}.`;
}
