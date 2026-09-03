import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { solverRunRecoveryCandidates } from "../lib/solver-run-recovery.ts";

test("server recovery selects the newest run for the exact scenario and category",()=>{
  const runs=[
    {id:"older",createdAt:"2026-09-03T12:00:00Z",scenario:{id:"base"},scope:{type:"ROLE",roleId:"bar"}},
    {id:"newest",createdAt:"2026-09-03T12:10:00Z",scenario:{id:"base"},scope:{type:"ROLE",roleId:"bar"}},
    {id:"other-category",createdAt:"2026-09-03T12:20:00Z",scenario:{id:"base"},scope:{type:"ROLE",roleId:"sala"}},
    {id:"other-scenario",createdAt:"2026-09-03T12:30:00Z",scenario:{id:"event"},scope:{type:"ROLE",roleId:"bar"}},
  ];
  assert.deepEqual(
    solverRunRecoveryCandidates(runs,{scenarioId:"base",scopeType:"ROLE",scopeRoleId:"bar"}).map(run=>run.id),
    ["newest","older"],
  );
});

test("logout may clear browser memory, so the panel restores the run from the authenticated server catalog",async()=>{
  const [authSession,panel,solverClient]=await Promise.all([
    readFile(new URL("../lib/auth-session.ts",import.meta.url),"utf8"),
    readFile(new URL("../components/SolverV2Panel.tsx",import.meta.url),"utf8"),
    readFile(new URL("../lib/solver-v2.ts",import.meta.url),"utf8"),
  ]);

  assert.match(authSession,/key\?\.startsWith\("grafik-pro:"\)/);
  assert.match(panel,/!skipRecovery && supabase && selectedScenario\?\.id/);
  assert.match(panel,/getLatestRecoverableSolverRunId\(supabase/);
  assert.match(panel,/rememberSolverRun\(context, serverRunId\)/);
  assert.match(panel,/Odzyskano z serwera generowanie zapisane przed wylogowaniem/);
  assert.match(panel,/const recovering = serverRecoveryBusy \|\| Boolean\(pollingRunId && !run\)/);
  assert.match(solverClient,/getSolverRunsCatalog\([\s\S]*?getSolverStatus\(client, candidate\.id\)/);
  assert.match(solverClient,/status\.run\.requestEngine === input\.engine[\s\S]*?status\.run\.solverVersion === input\.solverVersion/);
});
