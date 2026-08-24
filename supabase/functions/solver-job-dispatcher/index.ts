import "jsr:@supabase/functions-js/edge-runtime.d.ts";

import { createDispatcherHandler } from "./contract.ts";

function requireEnvironment(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`Missing dispatcher environment: ${name}`);
  return value;
}

Deno.serve(createDispatcherHandler({
  supabaseUrl: requireEnvironment("SUPABASE_URL").replace(/\/+$/u, ""),
  publishableKey: requireEnvironment("SUPABASE_ANON_KEY"),
  serviceRoleKey: requireEnvironment("SUPABASE_SERVICE_ROLE_KEY"),
  dispatcherToken: requireEnvironment("SOLVER_DISPATCHER_TOKEN"),
  jobSigningSecret: requireEnvironment("SOLVER_JOB_TOKEN_SIGNING_SECRET"),
  northflankApiToken: requireEnvironment("NORTHFLANK_SOLVER_JOB_API_TOKEN"),
  northflankProjectId: requireEnvironment("NORTHFLANK_PROJECT_ID"),
  northflankJobId: requireEnvironment("NORTHFLANK_JOB_ID"),
  solverGatewayUrl: requireEnvironment("SOLVER_GATEWAY_URL"),
  dispatcherVersion: Deno.env.get("DENO_DEPLOYMENT_ID")?.trim() || "local",
}));

