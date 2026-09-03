import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migrationUrl = new URL(
  "../supabase/migrations/20260903130000_aud012_separate_access_read_from_provisioning.sql",
  import.meta.url,
);
const providerUrl = new URL("../components/AppAuthProvider.tsx", import.meta.url);

function sqlFunction(sql, name) {
  const start = sql.indexOf(`create or replace function public.${name}`);
  assert.notEqual(start, -1, `${name} must exist`);
  const end = sql.indexOf("\n$$;", start);
  assert.notEqual(end, -1, `${name} must have a terminated body`);
  return sql.slice(start, end + 4);
}

test("AUD-012 current_user_access_v2 is a stable read with no provisioning mutation", async () => {
  const sql = await readFile(migrationUrl, "utf8");
  const readRpc = sqlFunction(sql, "current_user_access_v2()");

  assert.match(readRpc, /\nlanguage plpgsql\nstable\nsecurity definer\nset search_path=''\n/u);
  assert.doesNotMatch(readRpc, /\b(?:insert|update|delete|truncate)\b/iu);
  assert.doesNotMatch(readRpc, /application_access_materialize_uat_v1/iu);
  assert.match(readRpc, /'provisioning_available',v_provisioning_available/u);
  assert.match(sql, /revoke all on function public\.current_user_access_v2\(\) from public,anon;/u);
  assert.match(sql, /grant execute on function public\.current_user_access_v2\(\) to authenticated;/u);
});

test("AUD-012 provisioning is explicit, self-scoped, idempotent and auditable", async () => {
  const sql = await readFile(migrationUrl, "utf8");
  const provisioning = sqlFunction(sql, "application_access_provision_current_user_v1()");
  const materialize = sqlFunction(sql, "application_access_materialize_uat_v1(");
  const provider = await readFile(providerUrl, "utf8");

  assert.match(provisioning, /v_user uuid:=auth\.uid\(\)/u);
  assert.match(provisioning, /lower\(auth_user\.email\)/u);
  assert.match(provisioning, /PROVISIONING_ACCESS_NOT_GRANTED/u);
  assert.match(provisioning, /APPLICATION_ACCESS_PROVISION_SELF/u);
  assert.match(materialize, /PROVISIONING_IDENTITY_MISMATCH/u);
  assert.match(materialize, /PROVISIONING_DIRECTORY_LINK_CONFLICT/u);
  assert.match(materialize, /PROVISIONING_EMPLOYEE_AMBIGUOUS/u);
  assert.match(materialize, /on conflict do nothing/iu);
  assert.match(materialize, /where public\.matrix_scope_grants_v2\.active is distinct from true/u);
  assert.match(sql, /revoke all on function public\.application_access_provision_current_user_v1\(\)\s+from public,anon;/u);
  assert.match(sql, /grant execute on function public\.application_access_provision_current_user_v1\(\)\s+to authenticated;/u);

  assert.equal((provider.match(/application_access_provision_current_user_v1/gu) ?? []).length, 1);
  assert.match(provider, /onClick=\{\(\)=>void provisionCurrentAccess\(\)\}>Aktywuj nadany dostęp/u);
  const loadLiveData = provider.slice(provider.indexOf("const loadLiveData"), provider.indexOf("const recoverFirstRunConfiguration"));
  assert.doesNotMatch(loadLiveData, /application_access_provision_current_user_v1/u);
});
