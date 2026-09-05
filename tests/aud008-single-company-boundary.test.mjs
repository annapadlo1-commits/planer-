import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migration = await readFile(
  new URL("../supabase/migrations/20260905120000_aud008_single_company_boundary.sql", import.meta.url),
  "utf8",
);
const recursiveMigration = await readFile(
  new URL("../supabase/migrations/20260905150000_aud008_recursive_company_boundary.sql", import.meta.url),
  "utf8",
);
const editor = await readFile(new URL("../components/MatrixV2Editor.tsx", import.meta.url), "utf8");
const parser = await readFile(new URL("../lib/matrix-workbook-import.ts", import.meta.url), "utf8");
const financeParser = await readFile(new URL("../lib/workforce-finance-import.ts", import.meta.url), "utf8");
const financeExport = await readFile(new URL("../lib/workforce-finance-export.ts", import.meta.url), "utf8");
const messages = await readFile(new URL("../lib/matrix-v2.ts", import.meta.url), "utf8");

test("AUD-008: prywatna granica firmy jest singletonem i nie jest wystawiona przez Data API", () => {
  assert.match(migration, /create table solver_private\.single_company_boundary_uat_v1/u);
  assert.match(migration, /check \(singleton_key=1\)/u);
  assert.match(migration, /primary key \(singleton_key\)/u);
  assert.match(migration, /revoke all on table solver_private\.single_company_boundary_uat_v1/u);
  assert.doesNotMatch(migration, /grant [^;]+ on table solver_private\.single_company_boundary_uat_v1 to (?:anon|authenticated)/iu);
});

test("AUD-008: baza atomowo dopuszcza najwyżej jeden korzeń, draft i active", () => {
  const lockOffset = migration.indexOf("lock table public.matrix_versions in share row exclusive mode");
  const lifecycleLockOffset = migration.indexOf("pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'))");
  const companyLockOffset = migration.indexOf("pg_advisory_xact_lock(hashtext('matrix-v2-single-company-boundary'))", lifecycleLockOffset);
  const preflightOffset = migration.indexOf("do $lineage_guard$");
  const triggerOffset = migration.indexOf("create trigger matrix_v2_single_company_boundary_uat_v1");
  assert.ok(
    lifecycleLockOffset >= 0
      && lifecycleLockOffset < lockOffset
      && lockOffset < companyLockOffset
      && companyLockOffset < preflightOffset
      && preflightOffset < triggerOffset,
  );
  assert.match(migration, /matrix_versions_single_company_root_uat_v1/u);
  assert.match(migration, /where base_version_id is null/u);
  assert.match(migration, /matrix_versions_single_draft_uat_v1/u);
  assert.match(migration, /matrix_versions_single_active_uat_v1/u);
  assert.match(migration, /matrix_v2_enforce_single_company_boundary_uat_v1/u);
  assert.match(migration, /before insert or update\s+on public\.matrix_versions/u);
  assert.match(migration, /LEGACY_COMPANY_VERSION_DISABLED/u);
  assert.match(migration, /AUD008_EXISTING_LINEAGE_INVALID/u);
  assert.match(migration, /AUD008_EXISTING_COMPANY_METADATA_INVALID/u);
  assert.match(migration, /MATRIX_VERSION_LINEAGE_INVALID/u);
  assert.match(migration, /MATRIX_VERSION_LINEAGE_IMMUTABLE/u);
  assert.match(migration, /SECOND_COMPANY_FORBIDDEN/u);
  assert.match(migration, /new\.settings,'\{\}'::jsonb\) \? 'organizationId'/u);
  assert.match(migration, /new\.settings,'\{\}'::jsonb\) \? 'tenantId'/u);
  assert.match(migration, /new\.settings,'\{\}'::jsonb\) \? 'organization_id'/u);
  assert.match(migration, /new\.settings,'\{\}'::jsonb\) \? 'tenant_id'/u);
  assert.match(migration, /pg_advisory_xact_lock\(hashtext\('matrix-v2-single-company-boundary'\)\)/u);
  assert.doesNotMatch(migration, /update public\.matrix_versions\s+set settings/iu);
});

test("AUD-008: wszystkie trzy tryby importu sprawdzają obowiązkową granicę przed mutacją", () => {
  assert.match(migration, /matrix_v2_assert_single_company_payload_uat_v1/u);
  assert.match(migration, /WORKBOOK_COMPANY_BOUNDARY_REQUIRED/u);
  assert.match(migration, /WORKBOOK_COMPANY_BOUNDARY_INVALID/u);
  assert.match(migration, /matrix_v2_team_import_preview_uat_v1/u);
  assert.match(migration, /matrix_v2_team_import_apply_uat_v1/u);
  assert.match(migration, /matrix_v2_full_import_preview_raw_uat_v1/u);
  assert.match(migration, /matrix_v2_full_import_apply_raw_uat_v1/u);
  assert.match(migration, /matrix_v2_finance_import_preview_core_aud008/u);
  assert.match(migration, /matrix_v2_finance_import_apply_core_aud008/u);
  assert.match(migration, /p_configuration \? 'companyBoundaryId'/u);
  assert.match(migration, /p_configuration \? 'organization_id'/u);
  assert.match(migration, /p_configuration \? 'tenant_id'/u);
  assert.doesNotMatch(migration, /p_configuration->>'companyBoundaryId'/u);
});

test("AUD-008: metadane obcej firmy są odrzucane rekurencyjnie w imporcie i ustawieniach", () => {
  assert.match(recursiveMigration, /matrix_v2_reject_foreign_company_metadata_uat_v1/u);
  assert.match(recursiveMigration, /jsonb_array_elements\(p_value\)/u);
  assert.match(recursiveMigration, /jsonb_each\(p_value\)/u);
  assert.match(recursiveMigration, /lower\(replace\(v_key,'_',''\)\)/u);
  assert.match(recursiveMigration, /'organizationid','tenantid'/u);
  assert.match(recursiveMigration, /v_normalized_key='companyboundaryid'/u);
  assert.match(recursiveMigration, /p_path=array\['_workbook'\]::text\[\]/u);
  assert.match(recursiveMigration, /matrix_v2_recursive_company_boundary_uat_v1/u);
  assert.match(recursiveMigration, /before insert or update of settings/u);
  assert.match(recursiveMigration, /do \$existing_payload_guard\$/u);
  assert.match(recursiveMigration, /SINGLE_COMPANY_BOUNDARY_MISSING/u);
});

test("AUD-008: eksport przenosi granicę, parser zachowuje ją, a błąd jest bezpieczny dla użytkownika", () => {
  assert.match(editor, /matrix_v2_company_boundary_uat_v1/u);
  assert.match(editor, /\["companyBoundaryId",companyBoundaryId\]/u);
  assert.match(editor, /companyBoundaryId/u);
  assert.match(parser, /companyBoundaryId/u);
  assert.match(financeParser, /companyBoundaryId/u);
  assert.match(financeExport, /companyBoundaryId/u);
  assert.match(messages, /SECOND_COMPANY_FORBIDDEN/u);
  assert.match(messages, /jedn(?:ą|ej) firm/u);
});

test("AUD-008: publiczny kontrakt dostępu jest fail-closed dla ról i anonimowego użytkownika", () => {
  assert.match(migration, /matrix_v2_company_boundary_uat_v1/u);
  assert.match(migration, /matrix_v2_claim_single_company_uat_v1/u);
  assert.match(migration, /AUTH_REQUIRED/u);
  assert.match(migration, /FORBIDDEN/u);
  assert.match(migration, /has_app_role\('OWNER'\)/u);
  assert.match(migration, /p_allow_hr_finance and public\.has_app_role\('HR_FINANCE'\)/u);
  assert.match(migration, /revoke all on function public\.matrix_v2_claim_single_company_uat_v1/u);
  assert.match(migration, /grant execute on function public\.matrix_v2_claim_single_company_uat_v1\(uuid\)\s+to authenticated/u);
  assert.doesNotMatch(migration, /grant execute on function public\.matrix_v2_claim_single_company_uat_v1\(uuid\) to anon/u);
});

test("AUD-008: historyczne surowe RPC importu nie są osiągalne przez API", () => {
  for (const signature of [
    "matrix_create_draft", "matrix_register_import", "matrix_import_apply",
    "matrix_publish_draft", "matrix_save_demand", "matrix_save_item", "matrix_save_shift",
    "matrix_v2_import_preview_alpha16", "matrix_v2_import_apply_alpha16",
    "matrix_v2_import_preview_uat_v2", "matrix_v2_import_apply_uat_v2",
    "matrix_v2_import_preview_uat_v3", "matrix_v2_import_apply_uat_v3",
    "matrix_v2_import_preview_uat_v4", "matrix_v2_import_apply_uat_v4",
    "matrix_v2_import_preview_uat_v5", "matrix_v2_import_apply_uat_v5",
    "matrix_v2_team_import_preview_uat_v1_core_20260814",
    "matrix_v2_team_import_preview_uat_v1_core_20260824",
    "matrix_v2_team_import_apply_uat_v1_core_20260824",
  ]) assert.match(migration, new RegExp(`revoke all on function public\\.${signature}`));
  for (const signature of [
    "matrix_v2_import_preview_before_mx_k10",
    "matrix_v2_import_apply_before_mx_k10",
  ]) assert.match(recursiveMigration, new RegExp(`revoke all on function public\\.${signature}`));
});

test("AUD-008: migracja wymaga dokładnego i aktywnego kontraktu izolowanego UAT", () => {
  assert.match(migration, /control\.enabled is true/u);
  assert.match(migration, /control\.config->>'environment'='ISOLATED_UAT'/u);
  assert.match(migration, /control\.config->>'projectRef'='nhthrtpkfpmufmrmdyjg'/u);
});
