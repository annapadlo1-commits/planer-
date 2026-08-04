export const MAX_BODY_BYTES = 8 * 1024 * 1024;

export const WORKER_ACTIONS = [
  "solver_claim_next_v2",
  "solver_load_snapshot_v2",
  "solver_heartbeat_v2",
  "solver_save_variant_v2",
  "solver_finalize_v2",
  "solver_interrupt_v2",
  "solver_fail_attempt_v2",
] as const;

export const ALLOWED_ACTIONS = WORKER_ACTIONS;

export type WorkerAction = (typeof WORKER_ACTIONS)[number];
export type AllowedAction = WorkerAction;
export type JsonObject = Record<string, unknown>;

export type RpcResult = {
  status: number;
  body?: BodyInit | null;
  contentType?: string | null;
  errorCode?: string | null;
};

export type RpcInvoker = (
  action: AllowedAction,
  args: Readonly<JsonObject>,
) => Promise<RpcResult>;

type GatewayOptions = {
  solverGatewayToken: string;
  invokeRpc: RpcInvoker;
};

type RpcSpec = {
  maxBodyBytes: number;
  validate: (args: JsonObject) => void;
};

class GatewayError extends Error {
  readonly status: number;
  readonly code: string;

  constructor(status: number, code: string) {
    super(code);
    this.name = "GatewayError";
    this.status = status;
    this.code = code;
  }
}

// PostgreSQL's uuid type accepts the full 128-bit UUID text representation.
// Matrix v2 also deliberately stores deterministic md5-derived identifiers,
// whose version and variant bits are not rewritten to the RFC 4122 ranges.
// Match the database boundary here instead of rejecting those persisted IDs.
const POSTGRES_UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const HASH_PATTERN = /^[0-9a-f]{64}$/;
const CODE_PATTERN = /^[A-Z][A-Z0-9_:-]{0,99}$/;
const METRIC_PATTERN = /^[A-Z][A-Z0-9_]{0,79}$/;
const WORKER_ID_PATTERN = /^[A-Za-z0-9._:@/-]{3,200}$/;
const WORKER_VERSION_PATTERN = /^[A-Za-z0-9._:+/-]{1,200}$/;
const JSON_HEADERS = {
  "Cache-Control": "no-store",
  "Content-Type": "application/json; charset=utf-8",
  "X-Content-Type-Options": "nosniff",
};

function fail(status: number, code: string): never {
  throw new GatewayError(status, code);
}

function isObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function assertObject(value: unknown, name: string): asserts value is JsonObject {
  if (!isObject(value)) fail(400, `INVALID_${name}`);
}

function assertExactKeys(
  value: JsonObject,
  required: readonly string[],
  optional: readonly string[] = [],
): void {
  const allowed = new Set([...required, ...optional]);
  if (Object.keys(value).some((key) => !allowed.has(key))) {
    fail(400, "UNKNOWN_ARGUMENT");
  }
  if (required.some((key) => !Object.hasOwn(value, key))) {
    fail(400, "MISSING_ARGUMENT");
  }
}

function assertString(
  value: unknown,
  name: string,
  minimum: number,
  maximum: number,
): asserts value is string {
  if (
    typeof value !== "string" ||
    value.length < minimum ||
    value.length > maximum ||
    /[\u0000-\u001f\u007f]/u.test(value)
  ) {
    fail(400, `INVALID_${name}`);
  }
}

function assertUuid(
  value: unknown,
  name: string,
  nullable = false,
): asserts value is string | null {
  if (nullable && value === null) return;
  if (typeof value !== "string" || !POSTGRES_UUID_PATTERN.test(value)) {
    fail(400, `INVALID_${name}`);
  }
}

function assertInteger(
  value: unknown,
  name: string,
  minimum: number,
  maximum: number,
): asserts value is number {
  if (
    typeof value !== "number" ||
    !Number.isSafeInteger(value) ||
    value < minimum ||
    value > maximum
  ) {
    fail(400, `INVALID_${name}`);
  }
}

function assertFiniteNumber(value: unknown, name: string): asserts value is number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    fail(400, `INVALID_${name}`);
  }
}

function assertBoolean(value: unknown, name: string): asserts value is boolean {
  if (typeof value !== "boolean") fail(400, `INVALID_${name}`);
}

function assertArray(
  value: unknown,
  name: string,
  maximum: number,
): asserts value is unknown[] {
  if (!Array.isArray(value) || value.length > maximum) {
    fail(400, `INVALID_${name}`);
  }
}

function assertJsonTree(value: unknown): void {
  const pending: Array<{ value: unknown; depth: number }> = [
    { value, depth: 0 },
  ];
  let nodes = 0;
  while (pending.length > 0) {
    const current = pending.pop()!;
    nodes += 1;
    if (nodes > 200_000 || current.depth > 10) {
      fail(400, "JSON_COMPLEXITY_LIMIT");
    }
    if (Array.isArray(current.value)) {
      if (current.value.length > 100_000) fail(400, "JSON_ARRAY_LIMIT");
      for (const child of current.value) {
        pending.push({ value: child, depth: current.depth + 1 });
      }
      continue;
    }
    if (isObject(current.value)) {
      const entries = Object.entries(current.value);
      if (entries.length > 1_000) fail(400, "JSON_OBJECT_LIMIT");
      for (const [key, child] of entries) {
        if (key.length > 128 || /[\u0000-\u001f\u007f]/u.test(key)) {
          fail(400, "INVALID_JSON_KEY");
        }
        pending.push({ value: child, depth: current.depth + 1 });
      }
      continue;
    }
    if (
      current.value !== null &&
      typeof current.value !== "string" &&
      typeof current.value !== "boolean" &&
      (typeof current.value !== "number" || !Number.isFinite(current.value))
    ) {
      fail(400, "INVALID_JSON_VALUE");
    }
  }
}

function assertLeaseArgs(args: JsonObject): void {
  assertUuid(args.p_run_id, "RUN_ID");
  assertUuid(args.p_attempt_id, "ATTEMPT_ID");
  assertUuid(args.p_lease_token, "LEASE_TOKEN");
}

function validateClaim(args: JsonObject): void {
  assertExactKeys(args, [
    "p_worker_id",
    "p_worker_version",
    "p_task_attempt",
    "p_lease_seconds",
  ]);
  if (
    typeof args.p_worker_id !== "string" ||
    !WORKER_ID_PATTERN.test(args.p_worker_id)
  ) {
    fail(400, "INVALID_WORKER_ID");
  }
  if (
    typeof args.p_worker_version !== "string" ||
    !WORKER_VERSION_PATTERN.test(args.p_worker_version)
  ) {
    fail(400, "INVALID_WORKER_VERSION");
  }
  assertInteger(args.p_task_attempt, "TASK_ATTEMPT", 1, 20);
  assertInteger(args.p_lease_seconds, "LEASE_SECONDS", 30, 900);
}

function validateLoadSnapshot(args: JsonObject): void {
  assertExactKeys(args, ["p_run_id", "p_attempt_id", "p_lease_token"]);
  assertLeaseArgs(args);
}

function validateHeartbeat(args: JsonObject): void {
  assertExactKeys(args, [
    "p_run_id",
    "p_attempt_id",
    "p_lease_token",
    "p_progress",
  ]);
  assertLeaseArgs(args);
  assertObject(args.p_progress, "PROGRESS");
  assertExactKeys(
    args.p_progress,
    ["schemaVersion", "phase"],
    [
      "progress",
      "strategyId",
      "strategyProgress",
      "strategyCount",
      "completedStrategies",
      "assignmentCount",
      "unfilledCount",
    ],
  );
  if (args.p_progress.schemaVersion !== 2) {
    fail(400, "INVALID_PROGRESS_SCHEMA");
  }
  assertString(args.p_progress.phase, "PROGRESS_PHASE", 1, 80);
  for (const field of ["progress", "strategyProgress"] as const) {
    if (Object.hasOwn(args.p_progress, field)) {
      assertInteger(args.p_progress[field], field.toUpperCase(), 0, 100);
    }
  }
  for (const field of [
    "strategyCount",
    "completedStrategies",
    "assignmentCount",
    "unfilledCount",
  ] as const) {
    if (Object.hasOwn(args.p_progress, field)) {
      assertInteger(args.p_progress[field], field.toUpperCase(), 0, 100_000);
    }
  }
  if (Object.hasOwn(args.p_progress, "strategyId")) {
    assertUuid(args.p_progress.strategyId, "STRATEGY_ID");
  }
}

function validateCostComponent(value: unknown): void {
  assertObject(value, "COST_COMPONENT");
  assertExactKeys(value, ["ruleId", "calculationType", "costUnits"]);
  if (
    value.ruleId !== "BASE" &&
    (typeof value.ruleId !== "string" ||
      !POSTGRES_UUID_PATTERN.test(value.ruleId))
  ) {
    fail(400, "INVALID_COST_RULE_ID");
  }
  if (
    typeof value.calculationType !== "string" ||
    !CODE_PATTERN.test(value.calculationType)
  ) {
    fail(400, "INVALID_CALCULATION_TYPE");
  }
  assertInteger(value.costUnits, "COST_UNITS", 0, Number.MAX_SAFE_INTEGER);
}

function validateAssignment(value: unknown): void {
  assertObject(value, "ASSIGNMENT");
  assertExactKeys(value, [
    "slotId",
    "employeeId",
    "costUnits",
    "costComponents",
  ]);
  assertString(value.slotId, "SLOT_ID", 1, 1_000);
  assertUuid(value.employeeId, "EMPLOYEE_ID");
  assertInteger(value.costUnits, "COST_UNITS", 0, Number.MAX_SAFE_INTEGER);
  assertArray(value.costComponents, "COST_COMPONENTS", 100);
  value.costComponents.forEach(validateCostComponent);
}

function validateMetrics(value: unknown): void {
  assertObject(value, "METRICS");
  if (Object.keys(value).length > 100) fail(400, "METRICS_LIMIT");
  for (const [metric, metricValue] of Object.entries(value)) {
    if (!METRIC_PATTERN.test(metric)) fail(400, "INVALID_METRIC_NAME");
    assertInteger(metricValue, "METRIC_VALUE", 0, Number.MAX_SAFE_INTEGER);
  }
}

function validateObjectiveTerm(value: unknown): void {
  assertObject(value, "OBJECTIVE_TERM");
  assertExactKeys(
    value,
    ["metric", "direction", "weight", "tolerance", "parameters"],
    ["normalizationCoefficient", "metricUpperBound"],
  );
  if (typeof value.metric !== "string" || !METRIC_PATTERN.test(value.metric)) {
    fail(400, "INVALID_OBJECTIVE_METRIC");
  }
  if (value.direction !== "MIN" && value.direction !== "MAX") {
    fail(400, "INVALID_OBJECTIVE_DIRECTION");
  }
  assertInteger(value.weight, "OBJECTIVE_WEIGHT", 0, Number.MAX_SAFE_INTEGER);
  assertInteger(
    value.tolerance,
    "OBJECTIVE_TOLERANCE",
    0,
    Number.MAX_SAFE_INTEGER,
  );
  assertObject(value.parameters, "OBJECTIVE_PARAMETERS");
  assertExactKeys(value.parameters, [], ["targetValue"]);
  if (Object.hasOwn(value.parameters, "targetValue")) {
    assertInteger(
      value.parameters.targetValue,
      "OBJECTIVE_TARGET",
      0,
      Number.MAX_SAFE_INTEGER,
    );
  }
  if (Object.hasOwn(value, "normalizationCoefficient")) {
    assertInteger(
      value.normalizationCoefficient,
      "OBJECTIVE_NORMALIZATION_COEFFICIENT",
      0,
      Number.MAX_SAFE_INTEGER,
    );
  }
  if (Object.hasOwn(value, "metricUpperBound")) {
    assertInteger(
      value.metricUpperBound,
      "OBJECTIVE_METRIC_UPPER_BOUND",
      0,
      Number.MAX_SAFE_INTEGER,
    );
  }
}

function validateStageObjective(value: unknown): void {
  assertObject(value, "STAGE_OBJECTIVE");
  if (value.name === "DIVERSIFY") {
    assertExactKeys(value, [
      "tier",
      "name",
      "status",
      "businessObjectiveBoundsPreserved",
      "excludedEquivalentStrategies",
    ]);
    assertInteger(value.tier, "OBJECTIVE_TIER", 0, 100_000);
    assertString(value.status, "OBJECTIVE_STATUS", 1, 40);
    assertBoolean(
      value.businessObjectiveBoundsPreserved,
      "BUSINESS_OBJECTIVE_BOUNDS_PRESERVED",
    );
    assertArray(
      value.excludedEquivalentStrategies,
      "EXCLUDED_EQUIVALENT_STRATEGIES",
      100,
    );
    for (const exclusion of value.excludedEquivalentStrategies) {
      assertObject(exclusion, "DIVERSITY_EXCLUSION");
      assertExactKeys(exclusion, ["strategyId", "minimumAssignmentChanges"]);
      assertUuid(exclusion.strategyId, "DIVERSITY_STRATEGY_ID");
      assertInteger(
        exclusion.minimumAssignmentChanges,
        "MINIMUM_ASSIGNMENT_CHANGES",
        1,
        100_000,
      );
    }
    return;
  }
  assertExactKeys(
    value,
    ["tier", "name", "value", "status", "tolerance", "frozenUpperBound"],
    ["bestBound", "terms"],
  );
  assertInteger(value.tier, "OBJECTIVE_TIER", 0, 100_000);
  assertString(value.name, "OBJECTIVE_NAME", 1, 100);
  assertInteger(
    value.value,
    "OBJECTIVE_VALUE",
    Number.MIN_SAFE_INTEGER,
    Number.MAX_SAFE_INTEGER,
  );
  assertString(value.status, "OBJECTIVE_STATUS", 1, 40);
  assertInteger(
    value.tolerance,
    "OBJECTIVE_TOLERANCE",
    0,
    Number.MAX_SAFE_INTEGER,
  );
  assertInteger(
    value.frozenUpperBound,
    "OBJECTIVE_BOUND",
    Number.MIN_SAFE_INTEGER,
    Number.MAX_SAFE_INTEGER,
  );
  if (Object.hasOwn(value, "bestBound")) {
    assertFiniteNumber(value.bestBound, "BEST_BOUND");
  }
  if (Object.hasOwn(value, "terms")) {
    assertArray(value.terms, "OBJECTIVE_TERMS", 100);
    value.terms.forEach(validateObjectiveTerm);
  }
}

function validateVariant(value: unknown): void {
  assertObject(value, "VARIANT");
  assertExactKeys(value, [
    "schemaVersion",
    "strategyId",
    "strategyCode",
    "label",
    "sortOrder",
    "assignments",
    "unfilledSlotIds",
    "metrics",
    "stageObjectives",
    "optimal",
    "solutionHash",
    "equivalentToStrategyId",
  ]);
  if (value.schemaVersion !== 2) fail(400, "INVALID_VARIANT_SCHEMA");
  assertUuid(value.strategyId, "STRATEGY_ID");
  assertString(value.strategyCode, "STRATEGY_CODE", 1, 100);
  assertString(value.label, "STRATEGY_LABEL", 1, 200);
  assertInteger(value.sortOrder, "SORT_ORDER", 0, 100_000);
  assertArray(value.assignments, "ASSIGNMENTS", 100_000);
  value.assignments.forEach(validateAssignment);
  assertArray(value.unfilledSlotIds, "UNFILLED_SLOTS", 100_000);
  for (const slotId of value.unfilledSlotIds) {
    assertString(slotId, "SLOT_ID", 1, 1_000);
  }
  validateMetrics(value.metrics);
  assertArray(value.stageObjectives, "STAGE_OBJECTIVES", 1_000);
  value.stageObjectives.forEach(validateStageObjective);
  assertBoolean(value.optimal, "OPTIMAL");
  if (typeof value.solutionHash !== "string" || !HASH_PATTERN.test(value.solutionHash)) {
    fail(400, "INVALID_SOLUTION_HASH");
  }
  assertUuid(value.equivalentToStrategyId, "EQUIVALENT_STRATEGY_ID", true);
  assertJsonTree(value);
}

function validateSaveVariant(args: JsonObject): void {
  assertExactKeys(args, [
    "p_run_id",
    "p_attempt_id",
    "p_lease_token",
    "p_variant",
  ]);
  assertLeaseArgs(args);
  validateVariant(args.p_variant);
}

function validateFinalize(args: JsonObject): void {
  validateLoadSnapshot(args);
}

function validateInterrupt(args: JsonObject): void {
  assertExactKeys(args, [
    "p_run_id",
    "p_attempt_id",
    "p_lease_token",
    "p_reason",
  ]);
  assertLeaseArgs(args);
  if (typeof args.p_reason !== "string" || !CODE_PATTERN.test(args.p_reason)) {
    fail(400, "INVALID_INTERRUPT_REASON");
  }
}

function validateFailure(args: JsonObject): void {
  assertExactKeys(args, [
    "p_run_id",
    "p_attempt_id",
    "p_lease_token",
    "p_error_code",
    "p_error_message",
    "p_retryable",
  ]);
  assertLeaseArgs(args);
  if (
    typeof args.p_error_code !== "string" ||
    !CODE_PATTERN.test(args.p_error_code)
  ) {
    fail(400, "INVALID_ERROR_CODE");
  }
  assertString(args.p_error_message, "ERROR_MESSAGE", 1, 1_000);
  assertBoolean(args.p_retryable, "RETRYABLE");
}

const RPC_SPECS: Record<AllowedAction, RpcSpec> = {
  solver_claim_next_v2: { maxBodyBytes: 16 * 1024, validate: validateClaim },
  solver_load_snapshot_v2: {
    maxBodyBytes: 4 * 1024,
    validate: validateLoadSnapshot,
  },
  solver_heartbeat_v2: {
    maxBodyBytes: 64 * 1024,
    validate: validateHeartbeat,
  },
  solver_save_variant_v2: {
    maxBodyBytes: MAX_BODY_BYTES,
    validate: validateSaveVariant,
  },
  solver_finalize_v2: { maxBodyBytes: 4 * 1024, validate: validateFinalize },
  solver_interrupt_v2: { maxBodyBytes: 8 * 1024, validate: validateInterrupt },
  solver_fail_attempt_v2: {
    maxBodyBytes: 16 * 1024,
    validate: validateFailure,
  },
};

function isAllowedAction(value: unknown): value is AllowedAction {
  return (
    typeof value === "string" &&
    (ALLOWED_ACTIONS as readonly string[]).includes(value)
  );
}

function validateConfiguredToken(token: string): void {
  const looksLikeSupabaseCredential =
    token.startsWith("sb_secret_") ||
    token.startsWith("sb_publishable_") ||
    token.split(".").length === 3;
  if (
    token.length < 32 ||
    token.length > 512 ||
    looksLikeSupabaseCredential ||
    /[\p{White_Space}\p{Cc}\p{Cf}]/u.test(token)
  ) {
    throw new Error("Invalid gateway token configuration");
  }
}

async function tokensEqual(presented: string, expected: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const [presentedHash, expectedHash] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(presented)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
  ]);
  const first = new Uint8Array(presentedHash);
  const second = new Uint8Array(expectedHash);
  let difference = 0;
  for (let index = 0; index < first.length; index += 1) {
    difference |= first[index] ^ second[index];
  }
  return difference === 0;
}

async function readBody(request: Request): Promise<Uint8Array> {
  const contentLength = request.headers.get("content-length");
  if (contentLength !== null) {
    if (!/^\d+$/u.test(contentLength)) fail(400, "INVALID_CONTENT_LENGTH");
    const parsedLength = Number(contentLength);
    if (!Number.isSafeInteger(parsedLength)) fail(400, "INVALID_CONTENT_LENGTH");
    if (parsedLength > MAX_BODY_BYTES) fail(413, "BODY_TOO_LARGE");
  }
  if (request.body === null) fail(400, "BODY_REQUIRED");

  const reader = request.body!.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_BODY_BYTES) {
      await reader.cancel();
      fail(413, "BODY_TOO_LARGE");
    }
    chunks.push(value);
  }
  const body = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}

function jsonResponse(status: number, code: string): Response {
  return new Response(JSON.stringify({ error: code }), {
    status,
    headers: JSON_HEADERS,
  });
}

function parseEnvelope(body: Uint8Array): JsonObject {
  let decoded: string;
  try {
    decoded = new TextDecoder("utf-8", { fatal: true }).decode(body);
  } catch {
    fail(400, "INVALID_UTF8");
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(decoded);
  } catch {
    fail(400, "INVALID_JSON");
  }
  assertObject(parsed, "ENVELOPE");
  assertExactKeys(parsed, ["action", "args"]);
  return parsed;
}

export function createGatewayHandler(options: GatewayOptions) {
  validateConfiguredToken(options.solverGatewayToken);

  return async (request: Request): Promise<Response> => {
    try {
      if (request.method !== "POST") {
        return new Response(JSON.stringify({ error: "METHOD_NOT_ALLOWED" }), {
          status: 405,
          headers: { ...JSON_HEADERS, Allow: "POST" },
        });
      }

      const presentedToken =
        request.headers.get("x-solver-gateway-token") ?? "";
      if (!(await tokensEqual(presentedToken, options.solverGatewayToken))) {
        return jsonResponse(401, "UNAUTHORIZED");
      }

      const contentType = request.headers.get("content-type") ?? "";
      if (contentType.split(";", 1)[0].trim().toLowerCase() !== "application/json") {
        return jsonResponse(415, "JSON_REQUIRED");
      }
      const contentEncoding = request.headers.get("content-encoding");
      if (contentEncoding && contentEncoding.toLowerCase() !== "identity") {
        return jsonResponse(415, "CONTENT_ENCODING_NOT_ALLOWED");
      }

      const body = await readBody(request);
      const envelope = parseEnvelope(body);
      if (!isAllowedAction(envelope.action)) {
        return jsonResponse(400, "ACTION_NOT_ALLOWED");
      }
      assertObject(envelope.args, "ARGS");
      const spec = RPC_SPECS[envelope.action];
      if (body.byteLength > spec.maxBodyBytes) {
        return jsonResponse(413, "ACTION_BODY_TOO_LARGE");
      }
      spec.validate(envelope.args);

      let result: RpcResult;
      try {
        result = await options.invokeRpc(envelope.action, envelope.args);
      } catch {
        return jsonResponse(502, "UPSTREAM_UNAVAILABLE");
      }
      if (!Number.isInteger(result.status) || result.status < 200 || result.status > 599) {
        return jsonResponse(502, "INVALID_UPSTREAM_RESPONSE");
      }
      if (result.status >= 300) {
        const safeCode = typeof result.errorCode === "string"
          && CODE_PATTERN.test(result.errorCode)
          ? result.errorCode
          : "UPSTREAM_RPC_FAILED";
        return jsonResponse(result.status, safeCode);
      }
      if (
        result.body != null &&
        !(result.contentType ?? "").toLowerCase().startsWith("application/json")
      ) {
        return jsonResponse(502, "INVALID_UPSTREAM_CONTENT_TYPE");
      }
      return new Response(result.body ?? null, {
        status: result.status,
        headers: JSON_HEADERS,
      });
    } catch (error) {
      if (error instanceof GatewayError) {
        return jsonResponse(error.status, error.code);
      }
      return jsonResponse(500, "INTERNAL_ERROR");
    }
  };
}
