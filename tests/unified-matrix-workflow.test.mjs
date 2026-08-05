import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const componentPath=new URL("../components/MatrixV2Editor.tsx",import.meta.url);
const migrationPath=new URL("../supabase/migrations/20260805170000_uat006_unified_shift_staffing_workflow.sql",import.meta.url);
const [component,migration]=await Promise.all([
  readFile(componentPath,"utf8"),
  readFile(migrationPath,"utf8"),
]);

test("Matrix exposes one top-level Zmiany i obsada workflow",()=>{
  assert.match(component,/1\. Zmiany i obsada/);
  assert.doesNotMatch(component,/tab === "staffing"/);
  assert.doesNotMatch(component,/> 3\. Wymagana obsada</);
  assert.match(component,/<StaffingTab embedded/);
});

test("staffing UI follows exact shift, role, duty and positive headcount",()=>{
  const start=component.indexOf('if (kind === "STAFFING_RULE")');
  const end=component.indexOf('if (kind === "OBJECTIVE")',start);
  const staffing=component.slice(start,end);
  assert.match(staffing,/Zmiana/);
  assert.match(staffing,/Rola/);
  assert.match(staffing,/Obowiązek lub kompetencja/);
  assert.match(staffing,/Wymagana liczba osób/);
  assert.match(staffing,/min="1"/);
  assert.doesNotMatch(staffing,/>Pora</);
});

test("role duty editor no longer asks for a broad time-of-day bucket",()=>{
  const start=component.indexOf('if (kind === "ROLE_DUTY")');
  const end=component.indexOf('if (kind === "EMPLOYEE_ROLE")',start);
  const roleDuty=component.slice(start,end);
  assert.doesNotMatch(roleDuty,/shiftPeriod|MORNING|MIDDLE|EVENING/);
  assert.match(component,/shiftObligation:false,shiftPeriod:null/);
});

test("unified RPC links duties and writes staffing under one transaction lock",()=>{
  assert.match(component,/matrix_v2_shift_staffing_save_uat_v3/);
  assert.match(migration,/pg_advisory_xact_lock\(hashtext\('matrix-v2-lifecycle'\)\)/);
  assert.match(migration,/insert into public\.matrix_role_duties_v2/);
  assert.match(migration,/perform public\.matrix_v2_admin_save_alpha16/);
  assert.match(migration,/SAVE_UNIFIED_SHIFT_STAFFING/);
});

test("unified RPC is fail-closed and not executable by anonymous users",()=>{
  assert.match(migration,/if auth\.uid\(\) is null then raise exception 'AUTH_REQUIRED'/);
  assert.match(migration,/has_app_role\('OWNER'\).*has_app_role\('ADMIN'\)/s);
  assert.match(migration,/revoke all on function public\.matrix_v2_shift_staffing_save_uat_v3[\s\S]+from public,anon,authenticated/);
  assert.match(migration,/grant execute on function public\.matrix_v2_shift_staffing_save_uat_v3[\s\S]+to authenticated/);
});
