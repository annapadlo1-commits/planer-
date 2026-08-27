import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migrationUrl = new URL(
  "../supabase/migrations/20260826201603_employee_workspace_privacy.sql",
  import.meta.url,
);

test("employee workspace uses one Phase 1-backed canonical visibility set", async () => {
  const sql = await readFile(migrationUrl, "utf8");
  assert.match(sql, /authorization_private\.matrix_v2_visible_employee_ids_uat_v1\(\)/);
  assert.match(sql, /public\.matrix_v2_can_manage_employee\(employee\.id\)/);
  assert.match(sql, /select coalesce\(array_agg\(visible\.employee_id/);
  assert.doesNotMatch(sql, /bdybebzvzapihjdauehg/);
});

test("every employee-derived workspace collection is constrained server-side", async () => {
  const sql = await readFile(migrationUrl, "utf8");
  for (const collection of [
    "employees", "employeeRoles", "employeeLocations", "employeeDuties",
    "timeConstraints", "workPatterns", "employeePayRates", "adHocWorkers",
  ]) {
    assert.match(sql, new RegExp(`jsonb_set\\(v_payload, '\\{${collection}\\}'`), `${collection} must be projected by the privacy boundary`);
  }
  assert.ok((sql.match(/= any\(v_visible_employee_ids\)/g) ?? []).length >= 8);
  assert.match(sql, /public\.matrix_v2_can_manage_resource_uat_v1\(/,
    "ad-hoc resources must also respect their recovery role/employee scope");
});

test("financial redaction remains an independent earlier boundary", async () => {
  const sql = await readFile(migrationUrl, "utf8");
  const wrapped = sql.indexOf("matrix_v2_workspace_before_employee_privacy_uat_v1(p_month)");
  const visible = sql.indexOf("matrix_v2_visible_employee_ids_uat_v1() visible");
  assert.ok(wrapped >= 0 && visible > wrapped, "the existing finance-redacted payload must be obtained before person filtering");
  assert.doesNotMatch(sql, /jsonb_set\(v_payload, '\{payRules\}'/,
    "Phase 2 must not replace the existing finance policy");
});

test("historical SECURITY DEFINER workspace wrappers are internal-only", async () => {
  const sql = await readFile(migrationUrl, "utf8");
  for (const wrapper of [
    "matrix_v2_workspace_before_categories_uat_v1", "matrix_v2_workspace_before_overtime_uat_v1",
    "matrix_v2_workspace_before_ad_hoc_projection_uat_v1", "matrix_v2_workspace_before_b4f91_uat_v1",
    "matrix_v2_workspace_before_b4f52_uat_v1", "matrix_v2_workspace_before_employee_privacy_uat_v1",
  ]) assert.match(sql, new RegExp(`public\\.${wrapper}\\(date\\)`));
  assert.match(sql, /from public, anon, authenticated, service_role/);
  assert.match(sql, /grant execute on function public\.matrix_v2_workspace\(date\) to authenticated/);
  assert.match(sql, /security definer[\s\S]*set search_path = ''/i);
});
