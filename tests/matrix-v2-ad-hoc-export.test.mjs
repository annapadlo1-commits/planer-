import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

import { matrixV2AdHocRoleCode } from "../lib/matrix-v2.ts";

test("ad-hoc export uses the projected workspace role code when the stored role id belongs to an older version", () => {
  const roles = [{ id: "draft-role", code: "BARMAN" }];
  const worker = {
    id: "worker",
    display_name: "Jan Kowalski",
    role_id: "active-role",
    roleCode: "BARMAN",
    contract_type: "ZLECENIE",
    currency: "PLN",
    active: true,
  };

  assert.equal(matrixV2AdHocRoleCode(worker, roles), "BARMAN");
});

test("workspace RPC projects global ad-hoc rows by logical role identity", async () => {
  const sql = await readFile(
    new URL("../supabase/migrations/20260816013000_uat_ad_hoc_export_role_projection.sql", import.meta.url),
    "utf8",
  );

  assert.match(sql, /workspace_role\.logical_id\s*=\s*source_role\.logical_id/i);
  assert.match(sql, /'roleCode',\s*coalesce\(workspace_role\.code,\s*source_role\.code\)/i);
  assert.match(sql, /'role_id',\s*coalesce\(workspace_role\.id,\s*pool\.role_id\)/i);
});
