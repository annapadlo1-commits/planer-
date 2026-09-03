import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migrationUrl=new URL(
  "../supabase/archive/aud003/migrations/20260806190000_b4_full_import_idempotency.sql",
  import.meta.url,
);

test("full company import prefers detailed capabilities before preview and apply",async()=>{
  const sql=await readFile(migrationUrl,"utf8");
  assert.match(sql,/matrix_v2_full_import_configuration_uat_v2/);
  assert.match(sql,/employeeDuties/);
  assert.match(sql,/employeeCapabilities/);
  assert.match(sql,/not exists/);
  assert.match(sql,/matrix_v2_full_import_preview_raw_uat_v1/);
  assert.match(sql,/matrix_v2_full_import_apply_raw_uat_v1/);
  assert.equal((sql.match(/matrix_v2_full_import_configuration_uat_v2\(coalesce\(p_payload->'configuration'/g)??[]).length,2);
  assert.match(sql,/grant execute on function public\.matrix_v2_full_import_preview_uat_v1/);
  assert.doesNotMatch(sql,/bdybebzvzapihjdauehg/);
});
