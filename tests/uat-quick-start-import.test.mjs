import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";

const root = path.resolve(import.meta.dirname, "..");
const editor = fs.readFileSync(path.join(root, "components", "MatrixV2Editor.tsx"), "utf8");
const migration = fs.readFileSync(
  path.join(root, "supabase", "migrations", "20260810200000_uat_quick_start_import_identity_reconnect.sql"),
  "utf8",
);
const reconnectMigration = fs.readFileSync(
  path.join(root, "supabase", "migrations", "20260810201500_uat_import_reconnect_preserved_profiles.sql"),
  "utf8",
);
const relationAndTimeoutFix = fs.readFileSync(
  path.join(root, "supabase", "migrations", "20260810223000_uat_team_import_relation_and_timeout_fix.sql"),
  "utf8",
);

test("quick start has separate team and finance stages without a fixed workforce size", () => {
  assert.match(editor, /type MatrixImportScope\s*=\s*"TEAM"\s*\|\s*"FINANCE"\s*\|\s*"CONFIGURATION"/);
  assert.match(editor, /1\. Struktura i zespół/);
  assert.match(editor, /2\. Finanse zespołu/);
  assert.match(editor, /matrix_v2_team_import_preview_uat_v1/);
  assert.match(editor, /matrix_v2_team_import_apply_uat_v1/);
  assert.doesNotMatch(editor, /EXPECTED_ACTIVE_EMPLOYEES/);
});

test("quick workbook documents automatic identifiers and hides advanced sheets", () => {
  assert.match(editor, /System nada kolejny wolny numer GP-### automatycznie/);
  assert.match(editor, /grafik-pro-szybki-start-v/);
  assert.match(editor, /const hidden=new Set/);
  assert.match(editor, /\["KOLOR","#7257D8"/);
});

test("UAT import reconnects preserved global identities and gates public RPCs", () => {
  assert.match(migration, /from public\.employees e/);
  assert.match(migration, /matrix_v2_team_import_preview_uat_v1/);
  assert.match(migration, /matrix_v2_team_import_apply_uat_v1/);
  assert.match(migration, /has_app_role\('OWNER'\).*has_app_role\('ADMIN'\)/);
  assert.match(migration, /revoke all on function[\s\S]*public\.matrix_v2_team_import_preview_uat_v1/);
  assert.match(reconnectMigration, /matrix_v2_reconnect_preserved_profiles_uat_v1/);
  assert.match(reconnectMigration, /matrix_v2_full_import_phase_raw_uat_v1/);
});

test("quick-start import drops stale detailed relations and has a bounded RPC timeout", () => {
  assert.match(relationAndTimeoutFix, /p_configuration->'employeeRoles'[\s\S]*and exists \(/);
  assert.match(relationAndTimeoutFix, /p_configuration->'employees'/);
  assert.match(relationAndTimeoutFix, /upper\(trim\(employee\.value->>'employeeNo'\)\)=upper\(trim\(relation\.value->>'employeeNo'\)\)/);
  assert.match(relationAndTimeoutFix, /matrix_v2_team_import_preview_uat_v1\(jsonb,text\)[\s\S]*statement_timeout to '60s'/);
  assert.doesNotMatch(relationAndTimeoutFix, /alter role authenticated/);
});
