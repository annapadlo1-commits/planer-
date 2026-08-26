import "jsr:@supabase/functions-js/edge-runtime.d.ts";

import {
  type AllowedAction,
  createGatewayHandler,
  type JsonObject,
  resolveSupabaseSecretKey,
  type RpcResult,
} from "./contract.ts";

function requireEnvironment(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`Missing required gateway environment: ${name}`);
  return value;
}

const supabaseUrl = requireEnvironment("SUPABASE_URL").replace(/\/+$/u, "");
const supabaseSecretKey = resolveSupabaseSecretKey(
  Deno.env.get("SUPABASE_SECRET_KEYS"),
);
const solverGatewayToken = requireEnvironment("SOLVER_GATEWAY_TOKEN");
const gatewayVersion = Deno.env.get("DENO_DEPLOYMENT_ID")?.trim() || "local";
if (solverGatewayToken === supabaseSecretKey) {
  throw new Error("Gateway token must be independent from the Supabase secret key");
}

const parsedSupabaseUrl = new URL(supabaseUrl);
if (
  (Deno.env.get("DENO_DEPLOYMENT_ID") && parsedSupabaseUrl.protocol !== "https:") ||
  parsedSupabaseUrl.username ||
  parsedSupabaseUrl.password ||
  parsedSupabaseUrl.search ||
  parsedSupabaseUrl.hash
) {
  throw new Error("Invalid Supabase URL for solver gateway");
}

const invokeRpc = async (
  action: AllowedAction,
  args: Readonly<JsonObject>,
): Promise<RpcResult> => {
  const response = await fetch(`${supabaseUrl}/rest/v1/rpc/${action}`, {
    method: "POST",
    redirect: "error",
    headers: {
      Accept: "application/json",
      apikey: supabaseSecretKey,
      "Content-Type": "application/json",
      "User-Agent": "grafik-solver-gateway/0.1",
    },
    body: JSON.stringify(args),
    signal: AbortSignal.timeout(30_000),
  });
  if (response.ok) {
    return {
      status: response.status,
      body: response.body,
      contentType: response.headers.get("content-type"),
    };
  }
  // PostgREST returns PostgreSQL exceptions as JSON.  Forward only a strict
  // machine code (never details, hints or SQL text) so the worker can persist
  // the real failure instead of the useless "HTTP 400" seen in UAT.
  let errorCode: string | null = null;
  try {
    const upstream = await response.json() as { message?: unknown };
    const message = typeof upstream.message === "string" ? upstream.message : "";
    if (/^[A-Z][A-Z0-9_:-]{0,99}$/u.test(message)) errorCode = message;
  } catch {
    errorCode = null;
  }
  return {
    status: response.status,
    body: null,
    contentType: response.headers.get("content-type"),
    errorCode,
  };
};

Deno.serve(
  createGatewayHandler({
    solverGatewayToken,
    gatewayVersion,
    invokeRpc,
  }),
);
