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
  assert.match(panel, /Osobna wersja robocza na bazie wariantu generatora/);
  assert.match(panel, /className="leader-studio-fullscreen"/);
  assert.match(panel, /aria-modal="true"/);
  assert.match(panel, /initialView="CALENDAR"/);
  assert.match(panel, /Pracownicy nie widzą zmian przed publikacją/);
  const styles = await readFile(new URL("../app/product-journey.css", import.meta.url), "utf8");
  assert.match(styles, /solver-workspace\.leader-studio\{display:grid;grid-template-columns:minmax\(230px,290px\) minmax\(620px,1fr\) minmax\(250px,320px\)/);
  assert.match(styles, /leader-studio>\.solver-global-filters,\.leader-studio>\.leader-studio-candidate-panel\{grid-column:1/);
  assert.match(styles, /leader-studio>\.leader-studio-impact\{grid-column:3/);
  assert.match(workspace, /open=\{!leaderEditable&&workspace\.issues\.length > 0\}/);
  assert.match(workspace, /leader-studio-candidate-panel/);
  assert.match(workspace, /application\/x-grafik-employee/);
  assert.match(workspace, /draggable=\{candidate\.suggestionEligible\}/);
  assert.match(workspace, /studio-vacancy-target/);
  assert.match(workspace, /onDrop=\{event=>/);
  assert.match(styles, /\.leader-studio>\.leader-studio-candidate-panel\{grid-column:1/);
  assert.match(panel, /Cofnij/);
  assert.match(panel, /Ponów/);
  assert.match(panel, /getLeaderHistoryStatus/);
  assert.match(panel, /moveLeaderHistory/);
  assert.equal((panel.match(/window\.confirm/g) ?? []).length, 1, "wybór i publikacja nie mogą otwierać blokujących okien przeglądarki");
  const solverClient = await readFile(new URL("../lib/solver-v2.ts", import.meta.url), "utf8");
  assert.match(solverClient, /source\.id \?\? source\.variantId/, "odpowiedź tworzenia kopii zwraca variantId, a odczyt istniejącej kopii id");
  assert.match(workspace, /Uzupełnij w wersji lidera/);
  assert.match(workspace, /Usuń ze szkicu/);
  assert.doesNotMatch(workspace, /Dodaj do szkicu/);
  assert.match(workspace, /applyEmployeeDrop/);
  assert.doesNotMatch(workspace, /Najpierw użyj „Sprawdź”/);
  assert.doesNotMatch(workspace, /<label>Powód zmiany/);
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

test("leader history is durable, atomic and protected behind authenticated RPC",async()=>{
  const migration=await readFile(new URL("../supabase/migrations/20260818201340_leader_studio_history.sql",import.meta.url),"utf8");
  assert.match(migration,/leader_variant_history_v2/);
  assert.match(migration,/leader_variant_history_cursor_v2/);
  assert.match(migration,/deferrable initially deferred/);
  assert.match(migration,/pg_advisory_xact_lock/);
  assert.match(migration,/optimizer_leader_history_move_uat_v1/);
  assert.match(migration,/p_direction not in \('UNDO','REDO'\)/);
  assert.match(migration,/solver_private\.refresh_leader_variant_uat_v1/);
  assert.match(migration,/revoke all on function public\.optimizer_leader_history_status_uat_v1/);
  assert.match(migration,/grant execute on function public\.optimizer_leader_history_status_uat_v1/);
});

test("Studio drag operations move or swap assignments atomically and revalidate the month",async()=>{
  const migration=await readFile(new URL("../supabase/migrations/20260818202834_leader_studio_atomic_drag_operations.sql",import.meta.url),"utf8");
  const workspace=await readFile(new URL("../components/SolverV2Workspace.tsx",import.meta.url),"utf8");
  assert.match(migration,/optimizer_leader_assignment_drag_uat_v1/);
  assert.match(migration,/pg_advisory_xact_lock/);
  assert.match(migration,/dragOperation','SWAP'/);
  assert.match(migration,/dragOperation','MOVE'/);
  assert.match(migration,/solver_private\.refresh_leader_variant_uat_v1/);
  assert.match(migration,/revoke all on function public\.optimizer_leader_assignment_drag_uat_v1/);
  assert.match(workspace,/application\/x-grafik-assignment/);
  assert.match(workspace,/applyAssignmentDrag/);
  assert.match(workspace,/targetAssignmentId:assignment\.id/);
  assert.match(workspace,/targetIssueId:issues\[0\]\.id/);
});

test("leader can pin and unpin an assignment without exposing the protected table",async()=>{
  const migration=await readFile(new URL("../supabase/migrations/20260818203634_leader_studio_assignment_lock.sql",import.meta.url),"utf8");
  const workspace=await readFile(new URL("../components/SolverV2Workspace.tsx",import.meta.url),"utf8");
  assert.match(migration,/optimizer_leader_assignment_lock_uat_v1/);
  assert.match(migration,/leaderLocked/);
  assert.match(migration,/solver_private\.refresh_leader_variant_uat_v1/);
  assert.match(migration,/LEADER_LOCK/);
  assert.match(migration,/LEADER_UNLOCK/);
  assert.match(migration,/revoke all on function public\.optimizer_leader_assignment_lock_uat_v1/);
  assert.match(workspace,/Przypnij decyzję lidera/);
  assert.match(workspace,/Odepnij decyzję lidera/);
  assert.match(workspace,/draggable=\{leaderEditable&&!assignment\.locked\}/);
});

test("Studio preflights the exact drag transaction and always rolls the preview back",async()=>{
  const migration=await readFile(new URL("../supabase/migrations/20260818210100_leader_studio_drag_preflight.sql",import.meta.url),"utf8");
  const client=await readFile(new URL("../lib/solver-v2.ts",import.meta.url),"utf8");
  const workspace=await readFile(new URL("../components/SolverV2Workspace.tsx",import.meta.url),"utf8");
  assert.match(migration,/optimizer_leader_assignment_drag_preview_uat_v1/);
  assert.match(migration,/optimizer_leader_assignment_drag_uat_v1/);
  assert.match(migration,/LEADER_DRAG_PREVIEW_ROLLBACK/);
  assert.match(migration,/return jsonb_build_object\('valid',false,'errorCode',v_error\)/);
  assert.match(migration,/revoke all on function public\.optimizer_leader_assignment_drag_preview_uat_v1/);
  assert.match(client,/previewLeaderAssignmentDrag/);
  assert.match(workspace,/Kontrola przed upuszczeniem/);
  assert.match(workspace,/Nie można upuścić tutaj/);
});

test("leader workflow is durable, audited and owner-gated before merge",async()=>{
  const migration=await readFile(new URL("../supabase/migrations/20260818215500_leader_studio_workflow.sql",import.meta.url),"utf8");
  const panel=await readFile(new URL("../components/SolverV2Panel.tsx",import.meta.url),"utf8");
  assert.match(migration,/leader_workflow_status in \('DRAFT','REVIEW','LEADER_APPROVED','READY_TO_MERGE','PUBLISHED'\)/);
  assert.match(migration,/LEADER_WORKFLOW_TRANSITION_INVALID/);
  assert.match(migration,/public\.has_app_role\('OWNER'\).*public\.has_app_role\('ADMIN'\)/s);
  assert.match(migration,/LEADER_WORKFLOW_TRANSITION/);
  assert.match(migration,/revoke all on function public\.optimizer_leader_workflow_status_uat_v1/);
  assert.match(panel,/Przekaż do sprawdzenia/);
  assert.match(panel,/Zatwierdź jako lider/);
  assert.match(panel,/Oznacz jako gotowy do scalenia/);
  assert.match(panel,/leaderWorkflow==="DRAFT"/);
});

test("bulk Studio operations affect exactly the visible filtered assignment range in one revision",async()=>{
  const migration=await readFile(new URL("../supabase/migrations/20260818223000_leader_studio_bulk_assignments.sql",import.meta.url),"utf8");
  const workspace=await readFile(new URL("../components/SolverV2Workspace.tsx",import.meta.url),"utf8");
  assert.match(migration,/optimizer_leader_assignments_bulk_uat_v1/);
  assert.match(migration,/pg_advisory_xact_lock/);
  assert.match(migration,/v_operation not in \('LOCK','UNLOCK','REMOVE'\)/);
  assert.match(migration,/UNFILLED_SLOT/);
  assert.match(migration,/solver_private\.refresh_leader_variant_uat_v1/);
  assert.match(migration,/LEADER_BULK_/);
  assert.match(migration,/revoke all on function public\.optimizer_leader_assignments_bulk_uat_v1/);
  assert.match(migration,/grant execute on function public\.optimizer_leader_assignments_bulk_uat_v1/);
  assert.match(workspace,/Operacje dla zaznaczenia lub widocznego zakresu/);
  assert.match(workspace,/Zaznacz widoczne/);
  assert.match(workspace,/> Przypnij</);
  assert.match(workspace,/> Usuń</);
  assert.match(workspace,/const visibleAssignmentIds=scheduleEntries\.map/);
  assert.match(workspace,/Wybierz konkretne przydziały do operacji zbiorczej/);
  assert.match(workspace,/toggleAssignmentSelection\(assignment\.id\)/);
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

test("Studio lidera filters candidates and supports uninterrupted draft editing", async () => {
  const workspace=await readFile(new URL("../components/SolverV2Workspace.tsx",import.meta.url),"utf8");
  const panel=await readFile(new URL("../components/SolverV2Panel.tsx",import.meta.url),"utf8");
  const styles=await readFile(new URL("../app/product-journey.css",import.meta.url),"utf8");
  assert.match(workspace,/type LeaderCandidateView="ELIGIBLE"\|"ALL"\|"BELOW_TARGET"\|"PREFERRED"/);
  assert.match(workspace,/Tylko możliwe/);
  assert.match(workspace,/Wszyscy z powodami/);
  assert.match(workspace,/Wpływ bieżącego szkicu/);
  assert.match(workspace,/Zmiana względem wariantu bazowego/);
  assert.match(panel,/baselineWorkspace=\{leaderBaselineWorkspace\}/);
  assert.match(panel,/Potwierdź zmianę etapu/);
  assert.doesNotMatch(panel,/window\.prompt\(`Podaj powód przejścia/);
  assert.match(panel,/Sprawdź skutki przed publikacją/);
  assert.match(panel,/Potwierdź i opublikuj/);
  assert.doesNotMatch(panel,/window\.prompt/);
  assert.match(workspace,/Skutek w szkicu/);
  assert.match(workspace,/Pełną kontrolę uruchamiasz raz/);
  assert.match(workspace,/Upuszczenie kafelka od razu zmienia roboczy szkic/);
  assert.doesNotMatch(workspace,/Szkic zaktualizowany\. Możesz kontynuować/);
  assert.doesNotMatch(workspace,/Zastosuj sprawdzoną zmianę/);
  assert.doesNotMatch(workspace,/Dodaj komentarz audytowy/);
  assert.match(styles,/\.leader-studio-impact/);
  assert.match(styles,/\.leader-change-preview/);
  assert.match(styles,/leader-studio-candidate-panel>\.drawer-content\{overflow:visible\}/);
});

test("the owner configures finance visibility by application role in one access policy", async () => {
  const migration=await readFile(new URL("../supabase/migrations/20260818190421_studio_finance_visibility_policy.sql",import.meta.url),"utf8");
  const editor=await readFile(new URL("../components/MatrixV2Editor.tsx",import.meta.url),"utf8");
  const workspace=await readFile(new URL("../components/SolverV2Workspace.tsx",import.meta.url),"utf8");
  assert.match(migration,/visibility in \('NONE','BUDGET_ONLY','AGGREGATE','FULL'\)/);
  assert.match(migration,/if not public\.has_app_role\('OWNER'\) then raise exception 'ACCESS_POLICY_EDIT_FORBIDDEN'/);
  assert.match(migration,/application_finance_visibility_current_uat_v1/);
  assert.match(migration,/insert into public\.audit_log/);
  assert.match(editor,/Widoczność kosztów według rodzaju dostępu/);
  assert.match(editor,/Sama rola aplikacyjna nie nadaje już ukrytego poziomu finansowego/);
  assert.match(editor,/application_finance_visibility_save_uat_v1/);
  assert.match(workspace,/application_finance_visibility_current_uat_v1/);
  assert.match(workspace,/financeVisibility==="FULL"/);
  assert.match(workspace,/financeVisibility==="BUDGET_ONLY"/);
  assert.match(workspace,/setFinanceVisibility\("NONE"\)/);
});

test("B4F-100 fills only remaining vacancies and preserves every existing leader decision",async()=>{
  const [migration,panel,client]=await Promise.all([
    readFile(new URL("../supabase/migrations/20260818220459_b4f100_leader_refill_remaining.sql",import.meta.url),"utf8"),
    readFile(new URL("../components/SolverV2Panel.tsx",import.meta.url),"utf8"),
    readFile(new URL("../lib/solver-v2.ts",import.meta.url),"utf8"),
  ]);
  assert.match(migration,/optimizer_leader_refill_request_uat_v1/);
  assert.match(migration,/lockedAssignments/);
  assert.match(migration,/baselineAssignments/);
  assert.match(migration,/leaderStudioRefill/);
  assert.match(migration,/issue_code='UNFILLED_SLOT' and issue\.slot_key=source\.slot_key/);
  assert.match(migration,/LEADER_REFILL_DRAFT_CHANGED/);
  assert.match(migration,/pg_advisory_xact_lock/);
  assert.match(migration,/solver_private\.refresh_leader_variant_uat_v1/);
  assert.match(migration,/revoke all on function public\.optimizer_leader_refill_request_uat_v1/);
  assert.doesNotMatch(migration,/delete from public\.plan_assignments_v2/,
    "uzupełnienie nie może usuwać ani zastępować decyzji lidera");
  assert.match(client,/requestLeaderRefill/);
  assert.match(client,/applyLeaderRefill/);
  assert.match(panel,/Uzupełnij automatycznie tylko pozostałe miejsca/);
  assert.match(panel,/Wpisz co najmniej 3 znaki, aby uruchomić generator tylko dla wakatów/);
  assert.match(panel,/key=\{`leader:\$\{selectedWorkspace\.context\.runId\?\?leaderVariant\.id\}`\}/,
    "odświeżenie rewizji nie może przemontować Studia i wyzerować perspektywy Stanowiska");
  assert.doesNotMatch(panel,/key=\{`leader:[^`]*leaderVariant\.revision/);
  assert.match(panel,/Wszystkie obecne przydziały lidera są zablokowane/);
  assert.match(panel,/result\.variants\.find\(item=>item\.recommended&&item\.hardViolations===0\)/);
});

test("Studio role calendar exposes vacancies as drop targets and keeps analytics panels separate",async()=>{
  const [workspace,styles]=await Promise.all([
    readFile(new URL("../components/SolverV2Workspace.tsx",import.meta.url),"utf8"),
    readFile(new URL("../app/product-journey.css",import.meta.url),"utf8"),
  ]);
  assert.match(workspace,/const scheduleRoles=workspaceRoles/,
    "pusty ręczny szkic nadal musi pokazać wszystkie wymagane role");
  assert.match(workspace,/studio-role-vacancy studio-vacancy-target/);
  assert.match(workspace,/application\/x-grafik-employee/);
  assert.match(workspace,/applyEmployeeDrop\(issue\.id,employeeId\)/);
  assert.doesNotMatch(workspace,/Dodaj do szkicu/);
  assert.match(workspace,/Obsada i wolne miejsca/);
  assert.match(workspace,/workspaceView==="ISSUES"&&<section className="solver-issues-view">/);
  assert.match(styles,/leader-studio>\.solver-issues-view\{grid-column:2;grid-row:3/);
  assert.match(styles,/\.studio-role-vacancy:hover/);
  assert.doesNotMatch(workspace,/onLeaderChanged\?\.\(\);await openWorkload\(true\)/,
    "zapis w Studio nie może sam przenosić lidera z kalendarza do rozkładu pracy");
});
