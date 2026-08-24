import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import test from "node:test";

const migrationUrl=new URL("../supabase/migrations/20260824231701_b4f173_workbook_identity_guard.sql",import.meta.url);

test("B4F-173: preview and apply both reject stale or forged workbook identity",async()=>{
  const sql=await readFile(migrationUrl,"utf8");
  assert.match(sql,/matrix_v2_assert_workbook_identity_uat_v1/u);
  assert.match(sql,/v_mode not in \('EMPTY_TEMPLATE','CURRENT_CONFIG_EXPORT'\)/u);
  assert.match(sql,/WORKBOOK_SOURCE_MATRIX_STALE/u);
  assert.match(sql,/WORKBOOK_SCOPE_IDENTIFIER_FORBIDDEN/u);
  assert.match(sql,/perform pg_advisory_xact_lock\(hashtext\('matrix-v2-lifecycle'\)\)/u);
  assert.equal((sql.match(/matrix_v2_assert_workbook_identity_uat_v1\(p_configuration\)/gu)??[]).length,2,"preview i apply muszą niezależnie sprawdzać identyfikator");
  assert.match(sql,/revoke all on function[\s\S]+from public,anon,authenticated/u);
  assert.match(sql,/grant execute on function[\s\S]+to authenticated/u);
});

