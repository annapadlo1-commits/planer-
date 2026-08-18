import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migrationUrl = new URL(
  "../supabase/migrations/20260806173000_b4_leader_variant_and_demand_profiles.sql",
  import.meta.url,
);

test("leader copy keeps the three generated variants immutable and separate", async () => {
  const sql = await readFile(migrationUrl, "utf8");
  assert.match(sql, /variant_kind text not null default 'GENERATED'/);
  assert.match(sql, /source_variant_id uuid references public\.plan_variants_v2\(id\)/);
  assert.match(sql, /where variant_kind='GENERATED'/);
  assert.match(sql, /optimizer_create_leader_variant_uat_v1/);
  assert.match(sql, /'LEADER_COPY'/);
  assert.match(sql, /insert into public\.plan_assignments_v2/);
  assert.match(sql, /insert into public\.plan_assignment_duties_v2/);
  assert.match(sql, /insert into solver_private\.plan_assignment_cost_components_v2/);
  assert.match(sql, /variant\.variant_kind='GENERATED'/);
});

test("every manual leader edit is authorized and fully revalidated", async () => {
  const sql = await readFile(migrationUrl, "utf8");
  for (const rpc of [
    "optimizer_leader_assignment_context_uat_v1",
    "optimizer_leader_assignment_save_uat_v1",
    "optimizer_leader_assignment_remove_uat_v1",
    "optimizer_leader_variant_workspace_uat_v1",
  ]) assert.match(sql, new RegExp(rpc));
  assert.match(sql, /can_edit_leader_variant_uat_v1/);
  assert.match(sql, /refresh_leader_variant_uat_v1/);
  assert.match(sql, /validate_variant_v2/);
  assert.match(sql, /v_validation:=solver_private\.validate_variant_v2/);
  assert.match(sql, /EDIT_REASON_REQUIRED/);
  assert.match(sql, /jsonb_build_object\('reason',p_reason,'validation',v_validation\)/);
  assert.match(sql, /set search_path=''/);
  assert.doesNotMatch(sql, /bdybebzvzapihjdauehg/);
});

test("only baseline and dated demand profiles reach the generator", async () => {
  const [sql, client, editor] = await Promise.all([
    readFile(migrationUrl, "utf8"),
    readFile(new URL("../lib/solver-v2.ts", import.meta.url), "utf8"),
    readFile(new URL("../components/MatrixV2Editor.tsx", import.meta.url), "utf8"),
  ]);
  assert.match(sql, /'BASELINE'/);
  assert.match(sql, /'PERIOD'/);
  assert.match(sql, /'UNDATED_LEGACY'/);
  assert.match(client, /item\.is_default \|\| profile\?\.profileMode === "PERIOD"/);
  assert.match(editor, /Profile obsady na dłuższy okres/);
  assert.match(editor, /Dodaj wyjątek dzienny/);
  assert.match(editor, /BRAK OKRESU — NIEWIDOCZNY W GENERATORZE/);
});

test("the UI exposes a persistent, editable leader workflow before publication", async () => {
  const [panel, workspace, page, editor] = await Promise.all([
    readFile(new URL("../components/SolverV2Panel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../components/SolverV2Workspace.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../components/MatrixV2Editor.tsx", import.meta.url), "utf8"),
  ]);
  assert.match(panel, /Utwórz wersję lidera/);
  assert.match(panel, /Wybierz jako bazę/);
  assert.match(panel, /Oryginalne trzy warianty powyżej pozostają niezmienione/);
  assert.equal((panel.match(/window\.confirm/g) ?? []).length, 1, "wybór i publikacja nie mogą otwierać blokujących okien przeglądarki");
  const solverClient = await readFile(new URL("../lib/solver-v2.ts", import.meta.url), "utf8");
  assert.match(solverClient, /source\.id \?\? source\.variantId/, "odpowiedź tworzenia kopii zwraca variantId, a odczyt istniejącej kopii id");
  assert.match(workspace, /Uzupełnij w wersji lidera/);
  assert.match(workspace, /Usuń przydział/);
  assert.match(workspace, /Powód zmiany/);
  assert.doesNotMatch(workspace, /window\.confirm/, "operacyjne uzupełnianie i edycja kopii nie mogą blokować karty natywnym oknem");
  assert.match(page, /grafik-pro:open-role-generator/);
  assert.match(editor, /import-draft/);
  assert.match(editor, /import-open/);
  assert.doesNotMatch(editor, /window\.prompt\("Nazwa nowej wersji roboczej:/, "utworzenie roboczej kopii nie może blokować karty natywnym oknem");
  assert.doesNotMatch(editor, /window\.confirm\(`Odtworzyć atomowo pełną bazę firmy:/, "pełny import ma być zatwierdzany w aplikacji, nie w natywnym oknie");
  assert.doesNotMatch(editor, /window\.confirm\(`Zapisać atomowo \$\{changeCount\}/, "import stawek ma być zatwierdzany w aplikacji, nie w natywnym oknie");
  assert.match(editor, /Wybierz datę obowiązywania/);
  assert.match(editor, /Sprawdź gotowość/);
  assert.match(editor, /Potwierdź publikację/);
  assert.doesNotMatch(editor, /window\.prompt\(\s*`Od kiedy ta wersja ma obowiązywać\?/,
    "publikacja ma prowadzić użytkownika w panelu aplikacji, nie przez natywne pytanie o datę");
  assert.doesNotMatch(editor, /window\.confirm\("Kontrola gotowości nie wykryła blokad\./,
    "końcowe potwierdzenie publikacji ma pozostać w panelu aplikacji");
});

test("B4F-93 opens an auditable leader studio without dispatching the generator", async () => {
  const [sql,authoritySql,panel,client]=await Promise.all([
    readFile(new URL("../supabase/migrations/20260818143000_b4f93_manual_leader_studio.sql",import.meta.url),"utf8"),
    readFile(new URL("../supabase/migrations/20260818183433_b4f93_authoritative_external_assignments.sql",import.meta.url),"utf8"),
    readFile(new URL("../components/SolverV2Panel.tsx",import.meta.url),"utf8"),
    readFile(new URL("../lib/solver-v2.ts",import.meta.url),"utf8"),
  ]);
  assert.match(sql,/optimizer_create_manual_leader_studio_uat_v1/);
  assert.match(sql,/build_snapshot_payload_v2/);
  assert.match(sql,/Miejsce oczekuje na ręczną obsadę w Studio lidera/);
  assert.match(sql,/CREATE_MANUAL_LEADER_STUDIO/);
  assert.doesNotMatch(sql,/pgmq\.send/);
  assert.doesNotMatch(sql,/bdybebzvzapihjdauehg/);
  assert.match(panel,/Studio lidera — ułóż grafik bez generatora/);
  assert.match(panel,/Internet oraz backend są nadal potrzebne/);
  assert.match(panel,/const canOpenManualStudio = engine === "ORTOOLS_V2" && allowStart && !recovering && !active && !leaderVariant/);
  assert.match(panel,/\{canOpenManualStudio&&<section className="solver-manual-studio-entry">/,
    "Studio ma pozostać dostępne po zakończonym lub nieudanym uruchomieniu generatora");
  assert.doesNotMatch(panel,/\{engine==="ORTOOLS_V2"&&<section className="solver-manual-studio-entry">/,
    "Studio nie może być zagnieżdżone wyłącznie w formularzu widocznym przed pierwszym generowaniem");
  assert.match(client,/createManualLeaderStudio/);
  assert.match(client,/if \(!id\) return null/);
  assert.match(panel,/rememberSolverRun\(context,created\.runId\)/);
  assert.match(authoritySql,/published_role_schedules_v2 publication/);
  assert.match(authoritySql,/published_schedules_v2 publication/);
  assert.match(authoritySql,/publication\.status='PUBLISHED'/);
  assert.match(authoritySql,/select distinct raw\.employee_id,raw\.starts_at,raw\.ends_at/);
  assert.doesNotMatch(authoritySql,/v\.status='PUBLISHED'/,
    "historyczne oznaczenie wariantu nie jest źródłem obowiązującego grafiku");
  assert.doesNotMatch(authoritySql,/bdybebzvzapihjdauehg/);
});
