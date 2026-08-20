import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");

test("F4 makes employment and pay-rate periods one bidirectional DB invariant", async () => {
  const migration = await read(
    "supabase/migrations/20260820081703_f4_employment_pay_rate_bidirectional_invariant.sql",
  );
  assert.match(
    migration,
    /create or replace function solver_private\.assert_employment_pay_rate_period_uat_v1/,
  );
  assert.match(migration, /raise exception 'PAY_RATE_OUTSIDE_EMPLOYMENT'/);
  assert.match(
    migration,
    /raise exception 'EMPLOYMENT_DATES_CONFLICT_PAY_RATES'/,
  );
  const invariant = migration.slice(
    migration.indexOf("create or replace function solver_private.assert_employment_pay_rate_period_uat_v1"),
    migration.indexOf("create or replace function solver_private.guard_employee_pay_rate_employment_uat_v1"),
  );
  assert.match(invariant, /from public\.employee_pay_rates_v2 rate/);
  assert.doesNotMatch(invariant, /rate\.active/);

  assert.match(
    migration,
    /create trigger employee_pay_rate_employment_guard_uat_v1[\s\S]*before insert or update of employee_id,valid_from,valid_to/,
  );
  assert.match(
    migration,
    /create trigger matrix_employee_profile_pay_rate_guard_uat_v1[\s\S]*before insert or update of employee_id,employment_start,employment_end/,
  );
  assert.match(
    migration,
    /perform solver_private\.assert_employment_pay_rate_period_uat_v1\([\s\S]*new\.valid_from,[\s\S]*new\.valid_to/,
  );
  assert.match(
    migration,
    /perform solver_private\.assert_employment_pay_rate_period_uat_v1\([\s\S]*new\.employment_start,[\s\S]*new\.employment_end,[\s\S]*null,[\s\S]*null/,
  );
  assert.match(migration, /from public\.employees employee[\s\S]*for update/);
  assert.match(migration, /Abort instead of installing a guard over already-invalid data/);
});

test("F4 closes the externally callable alpha16 employee writer", async () => {
  const [migration, alpha16Contract] = await Promise.all([
    read("supabase/migrations/20260820081703_f4_employment_pay_rate_bidirectional_invariant.sql"),
    read("supabase/tests/alpha16_contract.sql"),
  ]);
  assert.match(
    migration,
    /revoke all on function public\.matrix_v2_employee_save_alpha16\(uuid,jsonb\)[\s\S]*from public, anon, authenticated, service_role/,
  );
  assert.doesNotMatch(
    migration,
    /grant execute on function public\.matrix_v2_employee_save_alpha16/,
  );
  assert.match(alpha16Contract, /has_function_privilege\([\s\S]*'authenticated','public\.matrix_v2_employee_save_alpha16/);
  assert.match(alpha16Contract, /public\.matrix_v2_employee_save_uat_v4\(null,jsonb_build_object/);
  assert.doesNotMatch(alpha16Contract, /v_result:=public\.matrix_v2_employee_save_alpha16/);
});

test("F4 SQL contract covers direct INSERT UPDATE and the supported RPC", async () => {
  const [contract, errors] = await Promise.all([
    read("supabase/tests/f4_employment_pay_rate_invariant_contract.sql"),
    read("lib/matrix-v2.ts"),
  ]);
  assert.match(contract, /insert into public\.employee_pay_rates_v2/);
  assert.match(contract, /update public\.employee_pay_rates_v2[\s\S]*set valid_to=v_end\+1/);
  assert.match(contract, /update public\.matrix_employee_profiles_v2[\s\S]*set employment_end=v_end-1/);
  assert.match(contract, /public\.matrix_v2_employee_save_v2\(v_employee/);
  assert.match(contract, /public\.matrix_v2_employee_save_uat_v4\(v_employee/);
  assert.match(contract, /PAY_RATE_OUTSIDE_EMPLOYMENT/);
  assert.match(contract, /EMPLOYMENT_DATES_CONFLICT_PAY_RATES/);
  assert.match(contract, /rollback;/);
  assert.match(errors, /EMPLOYMENT_DATES_CONFLICT_PAY_RATES/);
  assert.match(errors, /PAY_RATE_OUTSIDE_EMPLOYMENT/);
});
