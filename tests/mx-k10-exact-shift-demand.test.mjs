import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migrationPath=new URL(
  "../supabase/migrations/20260820081631_mx_k10_exact_shift_demand_only.sql",
  import.meta.url,
);
const sqlContractPath=new URL(
  "../supabase/tests/mx_k10_exact_shift_demand_contract.sql",
  import.meta.url,
);
const [migration,sqlContract]=await Promise.all([
  readFile(migrationPath,"utf8"),
  readFile(sqlContractPath,"utf8"),
]);

test("resolved demand runtime has only exact shift staffing source",()=>{
  const start=migration.indexOf(
    "create or replace function solver_private.resolved_demand_v2",
  );
  const end=migration.indexOf(
    "revoke all on function solver_private.resolved_demand_v2",
    start,
  );
  assert.notEqual(start,-1);
  assert.notEqual(end,-1);
  const runtime=migration.slice(start,end);
  assert.match(runtime,/public\.matrix_staffing_rules_v2/);
  assert.match(runtime,/staffing\.shift_template_id=key\.shift_template_id/);
  assert.doesNotMatch(runtime,/matrix_role_duties_v2/);
  assert.doesNotMatch(runtime,/minimum_requirements/);
  assert.doesNotMatch(runtime,/shift_period/);
});

test("migration fails closed for every active retired role-duty demand field",()=>{
  const preflight=migration.slice(
    migration.indexOf("do $$"),
    migration.indexOf("insert into solver_private.mx_k10_legacy_role_duty_archive"),
  );
  assert.match(preflight,/role_duty\.active/);
  assert.match(preflight,/assignment_mode='REQUIRED'/);
  assert.match(preflight,/minimum_count>0/);
  assert.match(preflight,/shift_obligation/);
  assert.match(preflight,/shift_period is not null/);
  assert.match(preflight,/MX_K10_EXACT_SHIFT_MAPPING_REQUIRED/);
  assert.match(migration,/matrix_role_duties_v2_competency_only_check/);
});

test("database regression executes two MIDDLE shifts and keeps +1 on one exact id",()=>{
  assert.match(sqlContract,/v_shift_selected/);
  assert.match(sqlContract,/v_shift_same_period/);
  assert.match(sqlContract,/MXK10_MIDDLE_A/);
  assert.match(sqlContract,/MXK10_MIDDLE_B/);
  assert.match(sqlContract,/shift_period='MIDDLE'/);
  assert.match(sqlContract,/'ADD',1/);
  assert.match(sqlContract,/solver_private\.resolved_demand_v2/);
  assert.match(sqlContract,/MX_K10_DEMAND_LEAKED_TO_SECOND_MIDDLE_SHIFT/);
  assert.match(sqlContract,/rollback;/);
});

test("legacy import contracts reject broad fields with an actionable code",()=>{
  assert.match(migration,/mx_k10_legacy_role_duty_payload_v1/);
  assert.match(migration,/LEGACY_PERIOD_DEMAND_REJECTED/);
  assert.match(migration,/Kod zmiany/);
  assert.match(migration,/matrix_v2_import_preview_alpha16/);
  assert.match(migration,/matrix_v2_import_apply_alpha16/);
});
