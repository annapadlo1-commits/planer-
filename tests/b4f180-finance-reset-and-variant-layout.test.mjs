import test from "node:test";
import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";

const migrationUrl=new URL("../supabase/migrations/20260902231357_b4f180_restore_finance_visibility_after_uat_reset.sql",import.meta.url);

test("B4F-180 restores all seven finance policies now and after every isolated UAT reset",async()=>{
  const migration=await readFile(migrationUrl,"utf8");
  for(const [role,visibility] of [
    ["OWNER","FULL"],["ADMIN","AGGREGATE"],["HR_FINANCE","FULL"],
    ["ROLE_MANAGER","BUDGET_ONLY"],["LOCATION_MANAGER","BUDGET_ONLY"],
    ["VERIFIER","BUDGET_ONLY"],["EMPLOYEE","NONE"],
  ]){
    assert.equal((migration.match(new RegExp(`\\('${role}','${visibility}'\\)`,"g"))??[]).length,2,
      `${role} must be seeded both by migration and after a full reset`);
  }
  assert.equal((migration.match(/on conflict\(app_role\) do nothing/g)??[]).length,2);
  assert.match(migration,/truncate table[\s\S]*application_finance_visibility_policy_v1[\s\S]*matrix_v2_create_safe_first_run_uat_v1/);
  assert.match(migration,/projectRef'='nhthrtpkfpmufmrmdyjg'/);
  assert.doesNotMatch(migration,/bdybebzvzapihjdauehg/);
});

test("variant cards keep total cost, assignment cost and explicit separate budget state",async()=>{
  const panel=await readFile(new URL("../components/SolverV2Panel.tsx",import.meta.url),"utf8");
  assert.match(panel,/variant\.totalCostMinor[\s\S]*?<span><CircleDollarSign\/><small>Koszt<\/small>/);
  assert.match(panel,/Koszt jednego przydziału/);
  assert.match(panel,/<small>Budżet<\/small><strong>\{variant\.budgetMinor!=null\?money\(variant\.budgetMinor,variant\.currency\):"Nie ustawiono limitu"\}/);
  assert.match(panel,/Osobny limit kosztu zapisany dla wybranego wariantu biznesowego/);
});

test("technical metrics use one column and wrap values without collapsing labels",async()=>{
  const css=await readFile(new URL("../app/product-journey.css",import.meta.url),"utf8");
  assert.match(css,/\.solver-v2-results \.solver-v2-analysis\{grid-template-columns:minmax\(0,1fr\)\}/);
  assert.match(css,/\.solver-v2-results \.solver-v2-analysis>div\{[^}]*grid-template-columns:minmax\(0,1fr\)/);
  assert.match(css,/\.solver-v2-results \.solver-v2-analysis dt\{[^}]*overflow-wrap:normal;word-break:normal/);
  assert.match(css,/\.solver-v2-results \.solver-v2-analysis dd\{[^}]*white-space:normal;overflow-wrap:anywhere/);
  assert.doesNotMatch(css,/\.solver-v2-results \.solver-v2-analysis dd\{[^}]*white-space:nowrap/);
});

test("role publication uses one role anchor, leaves company publication untouched and rejects unauthorized users",async()=>{
  const [panel,publication]=await Promise.all([
    readFile(new URL("../components/SolverV2Panel.tsx",import.meta.url),"utf8"),
    readFile(new URL("../supabase/migrations/20260819130000_b4f101_enforce_ready_to_merge_publication.sql",import.meta.url),"utf8"),
  ]);
  const rolePublish=publication.slice(publication.indexOf("create or replace function public.optimizer_publish_role_variant_uat_v2"),publication.indexOf("create or replace function public.optimizer_publish_company_variant_resolved_uat_v2"));
  assert.match(panel,/scopeType !== "ROLE"/);
  assert.match(rolePublish,/v_run\.scope_type<>'ROLE' or v_run\.scope_role_id is null/);
  assert.match(rolePublish,/where publication\.month=v_run\.month[\s\S]*publication\.role_id=v_run\.scope_role_id[\s\S]*publication\.status='PUBLISHED'/);
  assert.match(rolePublish,/role_id,[\s\S]*v_run\.scope_role_id/);
  assert.match(rolePublish,/ROLE_PUBLICATION_FORBIDDEN/);
  assert.doesNotMatch(rolePublish,/insert into public\.published_schedules_v2/);
});
