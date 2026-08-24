import test from "node:test";
import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";

const migrationUrl=new URL("../supabase/migrations/20260824224431_b4f171_first_run_access_guards.sql",import.meta.url);
const editorUrl=new URL("../components/MatrixV2Editor.tsx",import.meta.url);
const authUrl=new URL("../components/AppAuthProvider.tsx",import.meta.url);

test("B4F-171 preserves the only draft when no active version exists",async()=>{
  const migration=await readFile(migrationUrl,"utf8");
  assert.match(migration,/p_draft_count=1 and p_active_count=0 then return 'PRESERVE_ONLY_DRAFT'/);
  assert.match(migration,/if v_decision='PRESERVE_ONLY_DRAFT' then[\s\S]*?return jsonb_build_object\([\s\S]*?'preservedOnlyDraft',true/);
});

test("B4F-171 discards a draft only when an active version remains",async()=>{
  const migration=await readFile(migrationUrl,"utf8");
  assert.match(migration,/p_draft_count=1 and p_active_count>0 then return 'DISCARD_DRAFT'/);
  assert.match(migration,/delete from public\.matrix_versions where id=v_draft\.id/);
  assert.match(migration,/B4F171_USABLE_MATRIX_REQUIRED_AFTER_DISCARD/);
});

test("B4F-171 recreates the safe first-run workspace from zero versions",async()=>{
  const migration=await readFile(migrationUrl,"utf8");
  assert.match(migration,/p_draft_count=0 and p_active_count=0 then return 'ENSURE_FIRST_RUN'/);
  assert.match(migration,/matrix_v2_create_safe_first_run_uat_v1/);
  assert.match(migration,/matrix_v2_seed_required_defaults_uat_v1\(v_draft\)/);
  assert.match(migration,/scenarios',1,'strategies',3,'objectives',24/);
  assert.match(migration,/B4F171_SAFE_FIRST_RUN_CREATED/);
});

test("failed full-import preview is isolated from reset and apply",async()=>{
  const editor=await readFile(editorUrl,"utf8");
  const importStart=editor.indexOf("function MatrixExcelImport");
  const importSource=editor.slice(importStart);
  assert.match(importSource,/matrix_v2_full_import_preview_uat_v1/);
  assert.match(importSource,/if\(result\.error\)/);
  assert.match(importSource,/matrix_v2_full_import_apply_uat_v1/);
  assert.doesNotMatch(importSource,/uat_full_business_reset_v1/);
  assert.match(importSource,/Nie czyść UAT przed importem/);
});

test("cancel after failed preview cannot discard the sole first-run draft",async()=>{
  const [migration,editor]=await Promise.all([
    readFile(migrationUrl,"utf8"),
    readFile(editorUrl,"utf8"),
  ]);
  assert.match(migration,/B4F171_PRESERVE_ONLY_DRAFT/);
  assert.match(editor,/Ta operacja nie cofa wcześniej zatwierdzonego resetu ani importu/);
  assert.match(editor,/Nie usunięto jedynej konfiguracji firmy/);
});

test("OWNER access remains valid when the workspace is missing",async()=>{
  const auth=await readFile(authUrl,"utf8");
  const accessCall=auth.indexOf('rpc("current_user_access_v2")');
  const workspaceCall=auth.indexOf('rpc("matrix_v2_workspace"');
  assert.ok(accessCall>=0&&workspaceCall>accessCall,"access must be loaded before workspace");
  assert.match(auth,/setAccess\(nextAccess\)/);
  assert.match(auth,/MISSING_CONFIGURATION/);
  assert.match(auth,/Uprawnienia są prawidłowe, ale brakuje konfiguracji firmy/);
});

test("workspace failure does not clear correctly loaded access",async()=>{
  const auth=await readFile(authUrl,"utf8");
  const workspaceError=auth.match(/if\(matrixResult\.error\)\{[\s\S]*?return false;\s*\}/)?.[0]??"";
  assert.match(workspaceError,/setWorkspaceIssue/);
  assert.doesNotMatch(workspaceError,/setAccess\(null\)/);
  assert.match(auth,/Uprawnienia potwierdzone, ale nie udało się pobrać przestrzeni roboczej/);
  assert.doesNotMatch(auth,/Promise\.all\(\[\s*supabase\.rpc\("current_user_access_v2"\)/);
});

test("missing configuration routes an owner to safe first-run setup",async()=>{
  const auth=await readFile(authUrl,"utf8");
  assert.match(auth,/matrix_v2_ensure_first_run_uat_v1/);
  assert.match(auth,/Utwórz bezpieczną pustą konfigurację/);
  assert.match(auth,/role\.app_role==="OWNER"\|\|role\.app_role==="ADMIN"/);
});

test("all supported UI lifecycle paths retain at least one usable matrix",async()=>{
  const [migration,editor]=await Promise.all([
    readFile(migrationUrl,"utf8"),
    readFile(editorUrl,"utf8"),
  ]);
  assert.match(migration,/before delete on public\.matrix_versions/);
  assert.match(migration,/MATRIX_LAST_USABLE_VERSION_REQUIRED/);
  assert.match(migration,/matrix_v2_create_safe_first_run_uat_v1\(v_actor\)/);
  assert.match(editor,/emptyStateConfirmed/);
  assert.match(editor,/Mam plik — najpierw sprawdź bez resetu/);
});

test("B4F-171 is hard-bound to UAT and never references production",async()=>{
  const migration=await readFile(migrationUrl,"utf8");
  assert.match(migration,/projectRef'='nhthrtpkfpmufmrmdyjg'/);
  assert.doesNotMatch(migration,/bdybebzvzapihjdauehg/);
  assert.match(migration,/ISOLATED_UAT_DESTRUCTIVE_TOOLS/);
});
