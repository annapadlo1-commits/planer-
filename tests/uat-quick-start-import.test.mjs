import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";

const root = path.resolve(import.meta.dirname, "..");
const editor = fs.readFileSync(path.join(root, "components", "MatrixV2Editor.tsx"), "utf8");
const importer = fs.readFileSync(path.join(root, "lib", "matrix-workbook-import.ts"), "utf8");
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
const guidedImportOrderFix = fs.readFileSync(
  path.join(root, "supabase", "migrations", "20260810234500_uat_guided_onboarding_import_order_fix.sql"),
  "utf8",
);
const selfImportDefaults = fs.readFileSync(
  path.join(root, "supabase", "migrations", "20260813143000_uat_quick_start_self_import_defaults.sql"),
  "utf8",
);
const categoryOrderFix = fs.readFileSync(
  path.join(root, "supabase", "migrations", "20260813150000_uat_team_import_category_order_fix.sql"),
  "utf8",
);
const categoryCodeResolution = fs.readFileSync(
  path.join(root, "supabase", "migrations", "20260813151000_uat_role_category_code_resolution.sql"),
  "utf8",
);
const previewSafeDelete = fs.readFileSync(
  path.join(root, "supabase", "migrations", "20260813170000_uat_quick_start_preview_safe_delete.sql"),
  "utf8",
);
const employeeRoleAuditColumns = fs.readFileSync(
  path.join(root, "supabase", "migrations", "20260813173000_uat_employee_role_audit_columns.sql"),
  "utf8",
);
const explicitRoleOrderFix = fs.readFileSync(
  path.join(root, "supabase", "migrations", "20260815191000_uat_full_import_explicit_role_order.sql"),
  "utf8",
);
const emptyDictionaryRowsFix = fs.readFileSync(
  path.join(root, "supabase", "migrations", "20260815133914_uat_full_import_empty_dictionary_rows.sql"),
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

test("quick start does not reject its own header-only technical sheets", () => {
  assert.match(importer, /DEFAULT_SCENARIOS/);
  assert.match(importer, /DEFAULT_STRATEGIES/);
  assert.match(importer, /self-importable/);
  assert.match(editor, /Arkusz „Obowiązki” może pozostać pusty/);
  assert.doesNotMatch(editor, /!configuration\.duties\.length\|\|!configuration\.scenarios\.length\|\|!configuration\.strategies\.length/);
});

test("every future UAT reset seeds the system-owned scenario and solver defaults", () => {
  assert.match(selfImportDefaults, /matrix_v2_seed_required_defaults_uat_v1/);
  assert.match(selfImportDefaults, /'BASE','Bazowy'/);
  assert.match(selfImportDefaults, /'BALANCED','Zrównoważony'/);
  assert.match(selfImportDefaults, /'MIN_COST','Minimalny koszt'/);
  assert.match(selfImportDefaults, /'PREFERENCES','Preferencje i równy podział'/);
  assert.match(selfImportDefaults, /perform solver_private\.matrix_v2_seed_required_defaults_uat_v1\(v_draft\)/);
  assert.match(selfImportDefaults, /ISOLATED_UAT_DESTRUCTIVE_TOOLS/);
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

test("incoming dictionaries and shifts exist before staffing validation", () => {
  assert.match(guidedImportOrderFix, /matrix_v2_seed_import_shifts_uat_v1/);
  const preCall=guidedImportOrderFix.indexOf("'PRE'");
  const seedCall=guidedImportOrderFix.indexOf("matrix_v2_seed_import_shifts_uat_v1",preCall);
  const previewCall=guidedImportOrderFix.indexOf("matrix_v2_import_preview_uat_v5",seedCall);
  assert.ok(preCall < seedCall);
  assert.ok(seedCall < previewCall);
  assert.match(guidedImportOrderFix, /else row\.value\|\|jsonb_build_object\('operation','SET','countValue','0'\)/);
  assert.match(guidedImportOrderFix, /set search_path\s*=\s*''/);
  assert.match(guidedImportOrderFix, /revoke all on function[\s\S]*solver_private\.matrix_v2_seed_import_shifts_uat_v1/);
});

test("optional shift order receives a stable numeric default before the UAT RPC", () => {
  assert.match(importer, /const shifts=shiftRows\.map\(\(row,index\)=>/);
  assert.match(importer, /sortOrder:importCell\(row,"Kolejność","sortOrder"\)\|\|String\(index\+1\)/);
});

test("import UI explains errors and separates everyday setup from backup restore", () => {
  assert.match(editor, /Pełna kopia firmy/);
  assert.match(editor, /Zapisz strukturę i zespół/);
  assert.match(editor, /Kod roli z tego wiersza nie występuje/);
  assert.match(editor, /Kod zmiany i lokal nie odpowiadają/);
  assert.match(editor, /Co zawiera pełna kopia i kiedy jej użyć/);
});

test("role categories are inserted before roles during full import", () => {
  const categories = categoryOrderFix.indexOf("insert into public.matrix_role_categories_v2");
  const legacyPhase = categoryOrderFix.indexOf("matrix_v2_full_import_phase_before_categories_uat_v1(p_configuration,p_phase)");
  assert.ok(categories >= 0, "migration must insert role categories");
  assert.ok(legacyPhase > categories, "role categories must exist before the wrapped importer creates roles");
  assert.match(categoryOrderFix, /ROLE_CATEGORY_NOT_FOUND/);
});

test("role save resolves a workbook category code before shared validation", () => {
  const resolveCode = categoryCodeResolution.indexOf("v_category_code:=upper");
  const wrappedSave = categoryCodeResolution.indexOf("matrix_v2_admin_save_before_categories_uat_v1(p_kind,p_id,v_payload)");
  assert.ok(resolveCode >= 0, "role category code must be resolved");
  assert.ok(wrappedSave > resolveCode, "category resolution must happen before the shared role save");
  assert.match(categoryCodeResolution, /jsonb_build_object\('categoryId',v_category\)/);
});

test("quick-start preview uses an explicit safe full-table replacement for the ad-hoc pool", () => {
  assert.match(previewSafeDelete, /delete from public\.recovery_ad_hoc_pool_v2 where true;/i);
  assert.doesNotMatch(previewSafeDelete, /delete from public\.recovery_ad_hoc_pool_v2\s*;/i);
});

test("backup-role import audit fields exist on the versioned employee-role table", () => {
  assert.match(employeeRoleAuditColumns, /alter table public\.matrix_employee_roles_v2/i);
  assert.match(employeeRoleAuditColumns, /add column if not exists created_by uuid/i);
  assert.match(employeeRoleAuditColumns, /add column if not exists updated_by uuid/i);
  assert.match(employeeRoleAuditColumns, /add column if not exists updated_at timestamptz not null default now\(\)/i);
});

test("full import writes workbook roles before resolving employees", () => {
  const categoryWrite=explicitRoleOrderFix.indexOf("insert into public.matrix_role_categories_v2");
  const roleWrite=explicitRoleOrderFix.indexOf("matrix_v2_admin_save_alpha16('ROLE'");
  const employeePhase=explicitRoleOrderFix.indexOf("matrix_v2_full_import_phase_before_explicit_roles_uat_v1",roleWrite);
  assert.ok(categoryWrite>=0);
  assert.ok(roleWrite>categoryWrite);
  assert.ok(employeePhase>roleWrite);
  assert.match(explicitRoleOrderFix,/jsonb_set\(v_configuration,'\{roleCategories\}','\[\]'::jsonb,true\)/);
  assert.match(explicitRoleOrderFix,/rolesAppliedBeforeEmployees/);
});

test("full import ignores technical blank dictionary rows before role resolution", () => {
  assert.match(emptyDictionaryRowsFix,/array\['roleCategories','roles','locations','duties'\]/);
  assert.match(emptyDictionaryRowsFix,/FULL_IMPORT_DICTIONARY_VALUE_REQUIRED/);
  assert.match(emptyDictionaryRowsFix,/nullif\(trim\(item\.value->>'code'\),'\s*'\) is not null/);
  assert.match(emptyDictionaryRowsFix,/emptyDictionaryRowsIgnored/);
});
