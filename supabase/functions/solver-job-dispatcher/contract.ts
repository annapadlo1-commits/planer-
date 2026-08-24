export type JsonObject = Record<string, unknown>;

export type DispatcherOptions = {
  supabaseUrl: string;
  publishableKey: string;
  serviceRoleKey: string;
  dispatcherToken: string;
  jobSigningSecret: string;
  northflankApiToken: string;
  northflankProjectId: string;
  northflankJobId: string;
  solverGatewayUrl: string;
  dispatcherVersion: string;
  fetchImpl?: typeof fetch;
  now?: () => number;
};

type DispatchReservation = {
  reserved: boolean;
  status: string;
  runId?: string;
  dispatchNonce?: string;
  dispatchLeaseToken?: string;
  configuredPlan?: string;
  wallTimeoutSeconds?: number;
  solverCommit?: string;
  solverBuildId?: string;
};

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu;
const ID_PATTERN = /^[a-zA-Z0-9]+(?:-[a-zA-Z0-9]+)*$/u;
const VERSION_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:@/-]{0,499}$/u;
const JSON_HEADERS = {
  "Cache-Control": "no-store",
  "Content-Type": "application/json; charset=utf-8",
  "X-Content-Type-Options": "nosniff",
};
const CORS_HEADERS = {
  "Access-Control-Allow-Headers":
    "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Max-Age": "600",
};

class DispatcherError extends Error {
  readonly status: number;
  readonly code: string;

  constructor(status: number, code: string) {
    super(code);
    this.status = status;
    this.code = code;
  }
}

function fail(status: number, code: string): never {
  throw new DispatcherError(status, code);
}

function isObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function exactKeys(
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

function json(status: number, body: JsonObject): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...JSON_HEADERS, ...CORS_HEADERS },
  });
}

async function equal(first: string, second: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(first)),
    crypto.subtle.digest("SHA-256", encoder.encode(second)),
  ]);
  const left = new Uint8Array(a);
  const right = new Uint8Array(b);
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference === 0;
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const value of bytes) binary += String.fromCharCode(value);
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/u, "");
}

async function signJobCapability(
  secret: string,
  runId: string,
  dispatchNonce: string,
  expires: number,
): Promise<string> {
  const encoder = new TextEncoder();
  const expiresRaw = String(expires);
  const value = `sj1|${runId}|${dispatchNonce}|${expiresRaw}`;
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = base64Url(new Uint8Array(await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(value),
  )));
  return `sj1_${runId}_${dispatchNonce}_${expiresRaw}_${signature}`;
}

async function postgrestRpc(
  fetchImpl: typeof fetch,
  options: DispatcherOptions,
  name: string,
  args: JsonObject,
  authorization: string,
): Promise<unknown> {
  const response = await fetchImpl(
    `${options.supabaseUrl}/rest/v1/rpc/${name}`,
    {
      method: "POST",
      redirect: "error",
      headers: {
        Accept: "application/json",
        apikey: authorization === options.serviceRoleKey
          ? options.serviceRoleKey
          : options.publishableKey,
        Authorization: `Bearer ${authorization}`,
        "Content-Type": "application/json",
        "User-Agent": `szafunek-solver-job-dispatcher/${options.dispatcherVersion}`,
      },
      body: JSON.stringify(args),
      signal: AbortSignal.timeout(30_000),
    },
  );
  if (!response.ok) {
    let code = "UPSTREAM_RPC_FAILED";
    try {
      const body = await response.json() as { message?: unknown };
      if (
        typeof body.message === "string" &&
        /^[A-Z][A-Z0-9_:-]{0,99}$/u.test(body.message)
      ) code = body.message;
    } catch {
      // Never forward database detail, hint or SQL text.
    }
    throw new DispatcherError(response.status, code);
  }
  const text = await response.text();
  return text ? JSON.parse(text) : null;
}

function validateOptions(options: DispatcherOptions): void {
  const parsedSupabase = new URL(options.supabaseUrl);
  const parsedGateway = new URL(options.solverGatewayUrl);
  if (
    parsedSupabase.protocol !== "https:" ||
    parsedGateway.protocol !== "https:" ||
    parsedGateway.pathname !== "/functions/v1/solver-gateway" ||
    parsedGateway.search ||
    parsedGateway.hash
  ) throw new Error("Invalid dispatcher URLs");
  for (const [name, value] of [
    ["service role", options.serviceRoleKey],
    ["dispatcher token", options.dispatcherToken],
    ["job signing secret", options.jobSigningSecret],
    ["Northflank token", options.northflankApiToken],
  ] as const) {
    if (value.length < 32 || value.length > 2048 || /\s/u.test(value)) {
      throw new Error(`Invalid ${name} configuration`);
    }
  }
  if (
    new Set([
      options.serviceRoleKey,
      options.dispatcherToken,
      options.jobSigningSecret,
      options.northflankApiToken,
    ]).size !== 4
  ) throw new Error("Dispatcher credentials must be independent");
  if (
    !ID_PATTERN.test(options.northflankProjectId) ||
    !ID_PATTERN.test(options.northflankJobId) ||
    !VERSION_PATTERN.test(options.dispatcherVersion)
  ) throw new Error("Invalid Northflank resource configuration");
}

function userBearer(request: Request): string {
  const header = request.headers.get("authorization") ?? "";
  const match = /^Bearer\s+(.+)$/iu.exec(header);
  if (!match || match[1].length < 20 || match[1].length > 4096) {
    fail(401, "AUTH_REQUIRED");
  }
  return match[1];
}

async function requireBackend(
  request: Request,
  expected: string,
): Promise<void> {
  const presented = request.headers.get("x-solver-dispatcher-token") ?? "";
  if (!(await equal(presented, expected))) fail(401, "UNAUTHORIZED");
}

function normalizeReservation(value: unknown): DispatchReservation {
  const item = Array.isArray(value) ? value[0] : value;
  if (!isObject(item)) fail(502, "DISPATCH_RESERVATION_INVALID");
  return {
    reserved: item.reserved === true,
    status: String(item.status ?? "UNKNOWN"),
    runId: typeof item.runId === "string" ? item.runId : undefined,
    dispatchNonce: typeof item.dispatchNonce === "string"
      ? item.dispatchNonce
      : undefined,
    dispatchLeaseToken: typeof item.dispatchLeaseToken === "string"
      ? item.dispatchLeaseToken
      : undefined,
    configuredPlan: typeof item.configuredPlan === "string"
      ? item.configuredPlan
      : undefined,
    wallTimeoutSeconds: Number(item.wallTimeoutSeconds),
    solverCommit: typeof item.solverCommit === "string"
      ? item.solverCommit
      : undefined,
    solverBuildId: typeof item.solverBuildId === "string"
      ? item.solverBuildId
      : undefined,
  };
}

async function recordDispatchResult(
  fetchImpl: typeof fetch,
  options: DispatcherOptions,
  reservation: DispatchReservation,
  outcome: string,
  values: {
    northflankRunId?: string;
    httpStatus?: number;
    errorCode?: string;
    errorMessage?: string;
  } = {},
): Promise<void> {
  await postgrestRpc(
    fetchImpl,
    options,
    "solver_dispatch_result_uat_v1",
    {
      p_run_id: reservation.runId,
      p_dispatch_lease_token: reservation.dispatchLeaseToken,
      p_outcome: outcome,
      p_northflank_run_id: values.northflankRunId ?? null,
      p_http_status: values.httpStatus ?? null,
      p_error_code: values.errorCode ?? null,
      p_error_message: values.errorMessage ?? null,
    },
    options.serviceRoleKey,
  );
}

async function reserveAndDispatch(
  fetchImpl: typeof fetch,
  options: DispatcherOptions,
): Promise<JsonObject> {
  const raw = await postgrestRpc(
    fetchImpl,
    options,
    "solver_dispatch_reserve_uat_v1",
    { p_dispatcher_version: options.dispatcherVersion, p_lease_seconds: 60 },
    options.serviceRoleKey,
  );
  const reservation = normalizeReservation(raw);
  if (!reservation.reserved) return {
    reserved: false,
    status: reservation.status,
  };
  if (
    !reservation.runId ||
    !reservation.dispatchNonce ||
    !reservation.dispatchLeaseToken ||
    !UUID_PATTERN.test(reservation.runId) ||
    !UUID_PATTERN.test(reservation.dispatchNonce) ||
    !UUID_PATTERN.test(reservation.dispatchLeaseToken) ||
    !reservation.configuredPlan ||
    !Number.isInteger(reservation.wallTimeoutSeconds) ||
    reservation.wallTimeoutSeconds! < 60 ||
    reservation.wallTimeoutSeconds! > 3_000
  ) fail(502, "DISPATCH_RESERVATION_INVALID");

  const now = Math.floor((options.now ?? Date.now)() / 1000);
  const expires = now + Math.min(reservation.wallTimeoutSeconds! + 900, 3_500);
  const capability = await signJobCapability(
    options.jobSigningSecret,
    reservation.runId,
    reservation.dispatchNonce,
    expires,
  );
  const payload = {
    runtimeEnvironment: {
      TARGET_RUN_ID: reservation.runId,
      SOLVER_EXECUTION_MODE: "JOB",
      SOLVER_GATEWAY_URL: options.solverGatewayUrl,
      SOLVER_GATEWAY_TOKEN: capability,
      MAX_RUNS: "1",
      IDLE_EXIT_SECONDS: "30",
      WORKER_TASK_ATTEMPT: "1",
      JOB_WALL_TIMEOUT_SECONDS: String(reservation.wallTimeoutSeconds),
      SOLVER_COMMIT: reservation.solverCommit ?? "",
      SOLVER_BUILD_ID: reservation.solverBuildId ?? "",
      DISPATCHER_VERSION: options.dispatcherVersion,
    },
    billing: { deploymentPlan: reservation.configuredPlan },
  };

  let response: Response;
  try {
    response = await fetchImpl(
      `https://api.northflank.com/v1/projects/${options.northflankProjectId}` +
        `/jobs/${options.northflankJobId}/runs`,
      {
        method: "POST",
        redirect: "error",
        headers: {
          Accept: "application/json",
          Authorization: `Bearer ${options.northflankApiToken}`,
          "Content-Type": "application/json",
          "User-Agent": `szafunek-solver-job-dispatcher/${options.dispatcherVersion}`,
        },
        body: JSON.stringify(payload),
        signal: AbortSignal.timeout(25_000),
      },
    );
  } catch {
    await recordDispatchResult(
      fetchImpl,
      options,
      reservation,
      "ACCEPTANCE_UNKNOWN",
      {
        errorCode: "NORTHFLANK_TRANSPORT_UNKNOWN",
        errorMessage:
          "Brak jednoznacznej odpowiedzi Northflank; automatyczny ponowny POST jest zablokowany.",
      },
    );
    return {
      reserved: true,
      runId: reservation.runId,
      status: "ACCEPTANCE_UNKNOWN",
    };
  }

  if (!response.ok) {
    if (response.status === 429) {
      await recordDispatchResult(
        fetchImpl,
        options,
        reservation,
        "RETRYABLE_REJECTED",
        {
          httpStatus: response.status,
          errorCode: "NORTHFLANK_RATE_LIMITED",
          errorMessage: "Northflank odrzucił request przed utworzeniem Job Run.",
        },
      );
      return { reserved: true, runId: reservation.runId, status: "PENDING" };
    }
    const ambiguous = response.status >= 500 || response.status === 408;
    await recordDispatchResult(
      fetchImpl,
      options,
      reservation,
      ambiguous ? "ACCEPTANCE_UNKNOWN" : "PERMANENT_FAILURE",
      {
        httpStatus: response.status,
        errorCode: ambiguous
          ? "NORTHFLANK_UPSTREAM_UNKNOWN"
          : "NORTHFLANK_REQUEST_REJECTED",
        errorMessage: ambiguous
          ? "Odpowiedź Northflank nie dowodzi, że Job Run nie powstał."
          : "Northflank jednoznacznie odrzucił request utworzenia Job Run.",
      },
    );
    return {
      reserved: true,
      runId: reservation.runId,
      status: ambiguous ? "ACCEPTANCE_UNKNOWN" : "FAILED",
    };
  }

  let northflankRunId = "";
  try {
    const body = await response.json() as { data?: { id?: unknown } };
    northflankRunId = typeof body.data?.id === "string" ? body.data.id : "";
  } catch {
    northflankRunId = "";
  }
  if (!northflankRunId || northflankRunId.length > 200) {
    await recordDispatchResult(
      fetchImpl,
      options,
      reservation,
      "ACCEPTANCE_UNKNOWN",
      {
        httpStatus: response.status,
        errorCode: "NORTHFLANK_SUCCESS_BODY_INVALID",
        errorMessage:
          "Northflank odpowiedział sukcesem bez prawidłowego run ID; ponowny POST jest zablokowany.",
      },
    );
    return {
      reserved: true,
      runId: reservation.runId,
      status: "ACCEPTANCE_UNKNOWN",
    };
  }
  await recordDispatchResult(
    fetchImpl,
    options,
    reservation,
    "ACCEPTED",
    { northflankRunId, httpStatus: response.status },
  );
  return {
    reserved: true,
    runId: reservation.runId,
    northflankRunId,
    status: "ACCEPTED",
  };
}

function metricPoints(value: unknown): number[] {
  if (!isObject(value) || !Array.isArray(value.values)) return [];
  return value.values.flatMap((series) => {
    if (!isObject(series) || !Array.isArray(series.data)) return [];
    return series.data.flatMap((point) => {
      if (!isObject(point)) return [];
      const parsed = Number(point.value);
      return Number.isFinite(parsed) && parsed >= 0 ? [parsed] : [];
    });
  });
}

function metricUnit(value: unknown): string {
  if (!isObject(value) || !isObject(value.metricInfo)) return "";
  return String(value.metricInfo.metricUnit ?? "").toLowerCase();
}

async function reconcileOne(
  fetchImpl: typeof fetch,
  options: DispatcherOptions,
  runId: string,
): Promise<JsonObject> {
  const inspected = await postgrestRpc(
    fetchImpl,
    options,
    "solver_dispatch_inspect_uat_v1",
    { p_run_id: runId },
    options.serviceRoleKey,
  );
  const item = Array.isArray(inspected) ? inspected[0] : inspected;
  if (!isObject(item) || typeof item.northflankRunId !== "string") {
    fail(404, "NORTHFLANK_RUN_NOT_FOUND");
  }
  const northflankRunId = item.northflankRunId;
  const base = `https://api.northflank.com/v1/projects/${options.northflankProjectId}` +
    `/jobs/${options.northflankJobId}`;
  const headers = {
    Accept: "application/json",
    Authorization: `Bearer ${options.northflankApiToken}`,
    "User-Agent": `szafunek-solver-job-dispatcher/${options.dispatcherVersion}`,
  };
  const detailsResponse = await fetchImpl(`${base}/runs/${northflankRunId}`, {
    method: "GET",
    redirect: "error",
    headers,
    signal: AbortSignal.timeout(20_000),
  });
  if (!detailsResponse.ok) fail(502, "NORTHFLANK_RECONCILE_FAILED");
  const detailsBody = await detailsResponse.json() as { data?: JsonObject };
  const details = detailsBody.data;
  if (!isObject(details) || typeof details.status !== "string") {
    fail(502, "NORTHFLANK_RUN_INVALID");
  }
  const startedAt = typeof details.startedAt === "string" && details.startedAt
    ? details.startedAt
    : null;
  const concludedAt = typeof details.concludedAt === "string" && details.concludedAt
    ? details.concludedAt
    : null;

  let peakRssMb: number | null = null;
  let averageRssMb: number | null = null;
  let peakCpuPercent: number | null = null;
  if (startedAt) {
    const end = concludedAt ?? new Date((options.now ?? Date.now)()).toISOString();
    const query = new URLSearchParams({
      runId: northflankRunId,
      queryType: "range",
      startTime: startedAt,
      endTime: end,
    });
    query.append("metricTypes", "cpu");
    query.append("metricTypes", "memory");
    const metricsResponse = await fetchImpl(`${base}/metrics?${query}`, {
      method: "GET",
      redirect: "error",
      headers,
      signal: AbortSignal.timeout(20_000),
    });
    if (metricsResponse.ok) {
      const metricsBody = await metricsResponse.json() as { data?: JsonObject };
      const metrics = metricsBody.data ?? {};
      const memory = metricPoints(metrics.memory);
      const cpu = metricPoints(metrics.cpu);
      const memoryUnit = metricUnit(metrics.memory);
      const cpuUnit = metricUnit(metrics.cpu);
      if (memory.length) {
        const scale = memoryUnit === "pct" ? 1024 / 100 : 1;
        peakRssMb = Math.max(...memory) * scale;
        averageRssMb = memory.reduce((sum, value) => sum + value, 0) /
          memory.length * scale;
      }
      if (cpu.length) {
        const scale = cpuUnit === "vcpu" ? 100 : 1;
        peakCpuPercent = Math.max(...cpu) * scale;
      }
    }
  }
  const reconciled = await postgrestRpc(
    fetchImpl,
    options,
    "solver_job_reconcile_uat_v1",
    {
      p_run_id: runId,
      p_northflank_run_id: northflankRunId,
      p_northflank_status: details.status,
      p_container_started_at: startedAt,
      p_job_finished_at: concludedAt,
      p_peak_rss_mb: peakRssMb,
      p_average_rss_mb: averageRssMb,
      p_peak_cpu_percent: peakCpuPercent,
      p_failure_code: details.status === "FAILED"
        ? "NORTHFLANK_JOB_FAILED"
        : null,
    },
    options.serviceRoleKey,
  );
  return { runId, northflankRunId, reconciled };
}

export function createDispatcherHandler(options: DispatcherOptions) {
  validateOptions(options);
  const fetchImpl = options.fetchImpl ?? fetch;
  return async (request: Request): Promise<Response> => {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }
    if (request.method !== "POST") return json(405, { error: "METHOD_NOT_ALLOWED" });
    try {
      const raw = await request.text();
      if (!raw || raw.length > 64 * 1024) fail(413, "BODY_INVALID");
      let body: unknown;
      try {
        body = JSON.parse(raw);
      } catch {
        fail(400, "INVALID_JSON");
      }
      if (!isObject(body)) fail(400, "INVALID_BODY");
      const action = body.action;
      if (action === "request") {
        exactKeys(body, ["action", "request"]);
        if (!isObject(body.request)) fail(400, "INVALID_REQUEST");
        exactKeys(body.request, [
          "month","scenarioId","scopeType","scopeRoleId","name",
          "idempotencyKey","frontendVersion",
        ]);
        const bearer = userBearer(request);
        const created = await postgrestRpc(
          fetchImpl,
          options,
          "optimizer_request_job_uat_v1",
          {
            p_month: body.request.month,
            p_scenario_id: body.request.scenarioId,
            p_scope_type: body.request.scopeType,
            p_scope_role_id: body.request.scopeRoleId,
            p_name: body.request.name,
            p_idempotency_key: body.request.idempotencyKey,
            p_frontend_version: body.request.frontendVersion,
          },
          bearer,
        );
        const dispatch = await reserveAndDispatch(fetchImpl, options);
        return json(202, { created, dispatch });
      }
      if (action === "dispatch") {
        exactKeys(body, ["action"]);
        await requireBackend(request, options.dispatcherToken);
        return json(200, await reserveAndDispatch(fetchImpl, options));
      }
      if (action === "reconcile") {
        exactKeys(body, ["action", "runId"]);
        await requireBackend(request, options.dispatcherToken);
        if (typeof body.runId !== "string" || !UUID_PATTERN.test(body.runId)) {
          fail(400, "RUN_ID_INVALID");
        }
        return json(200, await reconcileOne(fetchImpl, options, body.runId));
      }
      if (action === "reconcileAll") {
        exactKeys(body, ["action"], ["limit"]);
        await requireBackend(request, options.dispatcherToken);
        const candidatesRaw = await postgrestRpc(
          fetchImpl,
          options,
          "solver_job_reconcile_candidates_uat_v1",
          { p_limit: Number(body.limit ?? 20) },
          options.serviceRoleKey,
        );
        const candidates = Array.isArray(candidatesRaw) ? candidatesRaw : [];
        const results: JsonObject[] = [];
        for (const candidate of candidates) {
          if (isObject(candidate) && typeof candidate.runId === "string") {
            results.push(await reconcileOne(fetchImpl, options, candidate.runId));
          }
        }
        return json(200, { results });
      }
      if (action === "watchdog") {
        exactKeys(body, ["action"]);
        await requireBackend(request, options.dispatcherToken);
        const rawWatchdog = await postgrestRpc(
          fetchImpl,
          options,
          "solver_job_watchdog_uat_v1",
          {},
          options.serviceRoleKey,
        );
        const watchdog = Array.isArray(rawWatchdog) ? rawWatchdog[0] : rawWatchdog;
        const expired = isObject(watchdog) && Array.isArray(watchdog.expired)
          ? watchdog.expired
          : [];
        let aborted = 0;
        for (const item of expired) {
          if (!isObject(item) || typeof item.northflankRunId !== "string") continue;
          const response = await fetchImpl(
            `https://api.northflank.com/v1/projects/${options.northflankProjectId}` +
              `/jobs/${options.northflankJobId}/runs/${item.northflankRunId}`,
            {
              method: "DELETE",
              redirect: "error",
              headers: {
                Accept: "application/json",
                Authorization: `Bearer ${options.northflankApiToken}`,
                "User-Agent":
                  `szafunek-solver-job-dispatcher/${options.dispatcherVersion}`,
              },
              signal: AbortSignal.timeout(20_000),
            },
          );
          if (response.ok || response.status === 404 || response.status === 409) {
            aborted += 1;
          }
        }
        return json(200, { expiredCount: expired.length, aborted });
      }
      fail(400, "ACTION_NOT_ALLOWED");
    } catch (error) {
      if (error instanceof DispatcherError) {
        return json(error.status, { error: error.code });
      }
      return json(500, { error: "INTERNAL_ERROR" });
    }
  };
}
