import "jsr:@supabase/functions-js/edge-runtime.d.ts";

import {
  type AllowedAction,
  createGatewayHandler,
  type JsonObject,
  type RpcResult,
} from "./contract.ts";

function requireEnvironment(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`Missing required gateway environment: ${name}`);
  return value;
}

const supabaseUrl = requireEnvironment("SUPABASE_URL").replace(/\/+$/u, "");
const serviceRoleKey = requireEnvironment("SUPABASE_SERVICE_ROLE_KEY");
const solverGatewayToken = requireEnvironment("SOLVER_GATEWAY_TOKEN");
const dispatcherGatewayToken = requireEnvironment("DISPATCHER_GATEWAY_TOKEN");
if (
  solverGatewayToken === serviceRoleKey ||
  dispatcherGatewayToken === serviceRoleKey ||
  solverGatewayToken === dispatcherGatewayToken
) {
  throw new Error(
    "Worker, dispatcher and service-role credentials must be independent",
  );
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
      apikey: serviceRoleKey,
      Authorization: `Bearer ${serviceRoleKey}`,
      "Content-Type": "application/json",
      "User-Agent": "grafik-solver-gateway/0.1",
    },
    body: JSON.stringify(args),
    signal: AbortSignal.timeout(30_000),
  });
  return {
    status: response.status,
    body: response.ok ? response.body : null,
    contentType: response.headers.get("content-type"),
  };
};

Deno.serve(
  createGatewayHandler({
    solverGatewayToken,
    dispatcherGatewayToken,
    invokeRpc,
  }),
);
