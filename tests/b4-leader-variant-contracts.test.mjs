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
  assert.match(panel, /Otwórz ten wariant/);
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
  assert.match(workspace,/targetIssueId:issue\.id/);
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
  assert.match(panel,/Przekaż sprawdzony grafik/);
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
  assert.match(panel,/\{canOpenManualStudio&&\(run\?\.status!=="READY"\|\|leaderStudioSourceVariants\.length===0\)&&<section className="solver-manual-studio-entry">/,
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

test("B4F-97 exposes direct Studio entry from every valid generator variant or a blank draft",async()=>{
  const panel=await readFile(new URL("../components/SolverV2Panel.tsx",import.meta.url),"utf8");
  assert.match(panel,/STUDIO LIDERA • PUNKT STARTOWY/);
  assert.match(panel,/leaderStudioSourceVariants\.map\(variant/);
  assert.match(panel,/createLeaderCopy\(variant\)/);
  assert.match(panel,/Utwórz pusty grafik ręcznie/);
  assert.match(panel,/Otwórz pusty szkic/);
  assert.match(panel,/async function createLeaderCopy\(sourceVariant:SolverVariant\)/);
  assert.match(panel,/sourceVariantId:sourceVariant\.id/);
  assert.match(panel,/getVariantWorkspace\(supabase,sourceVariant\.id\)/);
  assert.doesNotMatch(panel,/async function createLeaderCopy\(\)\{/);
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
  assert.match(styles,/leader-studio-candidate-panel>\.drawer-content\{[^}]*overflow-y:auto/);
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

test("B4F-101 enforces finance visibility in the server payload, not only in React",async()=>{
  const [migration,client,workspace]=await Promise.all([
    readFile(new URL("../supabase/migrations/20260819103000_b4f101_server_finance_redaction.sql",import.meta.url),"utf8"),
    readFile(new URL("../lib/solver-v2.ts",import.meta.url),"utf8"),
    readFile(new URL("../components/SolverV2Workspace.tsx",import.meta.url),"utf8"),
  ]);
  assert.match(migration,/redact_workspace_finance_uat_v1/);
  assert.match(migration,/v_assignment-'costMinor'-'cost_minor'/);
  assert.match(migration,/v_visibility='BUDGET_ONLY'/);
  assert.match(migration,/'budgetStatus'/);
  assert.match(migration,/v_visibility<>'NONE'/);
  assert.match(migration,/optimizer_variant_workspace_uat_v2/);
  assert.match(migration,/optimizer_leader_variant_workspace_uat_v1/);
  assert.match(migration,/optimizer_selected_variant_workspace_v2/);
  assert.match(migration,/optimizer_published_schedule_v2/);
  assert.match(migration,/optimizer_variants_v2/);
  assert.match(migration,/optimizer_runs_catalog_before_b4f101_alpha16/);
  assert.match(migration,/revoke all on function solver_private\.redact_workspace_finance_uat_v1/);
  assert.match(client,/budgetStatus:/);
  assert.match(workspace,/workspace\.budgetStatus/);
  assert.doesNotMatch(workspace,/workspace\.finance&&financeVisibility==="BUDGET_ONLY"/);
});

test("B4F-101 closes legacy workspace, employer-cost and recovery finance routes",async()=>{
  const sql=await readFile(new URL("../supabase/migrations/20260819123000_b4f101_close_legacy_finance_routes.sql",import.meta.url),"utf8");
  for(const name of ["complete_workspace","employer_cost_workspace_uat_v1","recovery_center_workspace_uat_v1","recovery_incident_detail_uat_v1"]){
    assert.match(sql,new RegExp(`create function public\\.${name}`));
  }
  assert.match(sql,/application_finance_visibility_current_uat_v1\(\)/);
  assert.match(sql,/v_employee-'finance'/);
  assert.match(sql,/v_person-'rateMinor'-'currency'/);
  assert.match(sql,/v_rate-'proposedRateMinor'-'approvedRateMinor'-'currency'/);
  assert.match(sql,/v_visibility<>'FULL'/);
});

test("B4F-52 closes the remaining legacy finance RPC and optimizer bypasses",async()=>{
  const sql=await readFile(new URL("../supabase/migrations/20260819150415_b4f52_close_remaining_finance_routes.sql",import.meta.url),"utf8");
  for(const name of ["plan_workspace","matrix_v2_workspace","monthly_budgets_get_uat_v1","optimizer_variants_v3"]){
    assert.match(sql,new RegExp(`create function public\\.${name}`));
  }
  assert.match(sql,/application_finance_visibility_current_uat_v1\(\)/);
  assert.match(sql,/v_assignment-'cost'/);
  assert.match(sql,/v_worker-'base_rate_minor'-'rateMinor'-'approved_rate_minor'-'currency'/);
  assert.match(sql,/jsonb_set\(v_payload,'\{employeePayRates\}','\[\]'::jsonb,true\)/);
  assert.match(sql,/v_variant-'score'-'metrics'/);
  assert.match(sql,/public\.optimizer_finalize_v3\(uuid,text,jsonb\)/);
  assert.match(sql,/public\.optimizer_complete_finalize_v4\(uuid\)/);
  assert.match(sql,/from public,anon,authenticated/);
  assert.match(sql,/grant execute on function public\.plan_workspace\(date,uuid\)/);
});

test("B4F-101 blocks every publication route until a leader copy is ready to merge",async()=>{
  const [sql,panel,client]=await Promise.all([
    readFile(new URL("../supabase/migrations/20260819130000_b4f101_enforce_ready_to_merge_publication.sql",import.meta.url),"utf8"),
    readFile(new URL("../components/SolverV2Panel.tsx",import.meta.url),"utf8"),
    readFile(new URL("../lib/solver-v2.ts",import.meta.url),"utf8"),
  ]);
  assert.match(sql,/new\.variant_kind='LEADER_COPY'/);
  assert.match(sql,/old\.leader_workflow_status is distinct from 'READY_TO_MERGE'/);
  assert.match(sql,/LEADER_VARIANT_NOT_READY_TO_PUBLISH/);
  assert.match(sql,/before update of status on public\.plan_variants_v2/);
  assert.match(sql,/revoke all on function solver_private\.guard_leader_variant_publication_uat_v1/);
  assert.match(panel,/const leaderPublicationReady =/);
  assert.match(panel,/if \(!leaderPublicationReady\)/);
  assert.match(panel,/oznacz (?:ją|wersję) jako gotową do scalenia/);
  assert.match(panel,/selectedVariant\.status === "PUBLISHED" \|\| !leaderPublicationReady/);
  assert.match(client,/LEADER_VARIANT_NOT_READY_TO_PUBLISH/);
});

test("B4F-101 previews exact changed people and notifies only affected linked accounts",async()=>{
  const [sql,panel,client,styles]=await Promise.all([
    readFile(new URL("../supabase/migrations/20260819130000_b4f101_enforce_ready_to_merge_publication.sql",import.meta.url),"utf8"),
    readFile(new URL("../components/SolverV2Panel.tsx",import.meta.url),"utf8"),
    readFile(new URL("../lib/solver-v2.ts",import.meta.url),"utf8"),
    readFile(new URL("../app/solver-v2.css",import.meta.url),"utf8"),
  ]);
  assert.match(sql,/changed_variant_employees_uat_v1/);
  assert.match(sql,/optimizer_publication_change_preview_uat_v1/);
  assert.match(sql,/before_schedule jsonb/);
  assert.match(sql,/after_schedule jsonb/);
  assert.match(sql,/is distinct from coalesce\(new_row\.schedule/);
  assert.match(sql,/join public\.employees employee on employee\.id=change\.employee_id/);
  assert.match(sql,/where employee\.auth_user_id is not null/);
  assert.match(sql,/'previousVariantId',v_previous_variant_id/);
  assert.match(sql,/'changed',v_changed,'notified',v_notified/);
  assert.match(sql,/revoke all on function solver_private\.changed_variant_employees_uat_v1/);
  assert.match(client,/getPublicationChangePreview/);
  assert.match(client,/optimizer_publication_change_preview_uat_v1/);
  assert.match(panel,/Osoby objęte publikacją/);
  assert.match(panel,/Zmienione osoby/);
  assert.match(panel,/Otrzymają powiadomienie/);
  assert.match(panel,/publicationChangesBusy \|\| !publicationChanges/);
  assert.match(styles,/solver-publication-change-people/);
});

test("B4F-95 checks the whole Studio draft without mutation before an audited workflow decision",async()=>{
  const [migration,panel,client]=await Promise.all([
    readFile(new URL("../supabase/migrations/20260819110000_b4f95_final_draft_validation.sql",import.meta.url),"utf8"),
    readFile(new URL("../components/SolverV2Panel.tsx",import.meta.url),"utf8"),
    readFile(new URL("../lib/solver-v2.ts",import.meta.url),"utf8"),
  ]);
  assert.match(migration,/optimizer_leader_draft_validate_uat_v1/);
  assert.match(migration,/stable security definer/);
  assert.match(migration,/materialized_variant_payload_v2/);
  assert.match(migration,/validate_variant_v2/);
  assert.match(migration,/v_target in \('REVIEW','LEADER_APPROVED','READY_TO_MERGE'\)/);
  assert.match(client,/validateLeaderDraft/);
  assert.match(panel,/Sprawdź cały grafik/);
  assert.match(panel,/Przekaż sprawdzony grafik/);
  assert.match(panel,/leaderDraftValidation\.revision!==leaderVariant\.revision/);
});

test("B4F-100 fills only remaining vacancies and preserves every existing leader decision",async()=>{
  const [migration,runContract,inputHashContract,panel,client]=await Promise.all([
    readFile(new URL("../supabase/migrations/20260818220459_b4f100_leader_refill_remaining.sql",import.meta.url),"utf8"),
    readFile(new URL("../supabase/migrations/20260819070912_b4f100_leader_refill_run_contract.sql",import.meta.url),"utf8"),
    readFile(new URL("../supabase/migrations/20260819082931_b4f100_leader_optimizer_input_hash.sql",import.meta.url),"utf8"),
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
  assert.match(runContract,/v_requested#>>'\{run,id\}'/,
    "wrapper musi odczytać rzeczywisty kontrakt optimizer_request_v2.run.id");
  assert.match(runContract,/'runId',v_refill_run_id/,
    "RPC musi zwrócić klientowi stabilne pole runId do pollingu");
  assert.match(runContract,/LEADER_REFILL_DRAFT_REQUIRED/);
  assert.match(inputHashContract,/optimizer_leader_refill_request_uat_v1/);
  assert.match(inputHashContract,/optimizer_leader_reoptimization_request_uat_v1/);
  assert.match(inputHashContract,/update solver_private\.optimization_snapshots_v2 set snapshot=v_snapshot,snapshot_hash=v_hash/,
    "worker musi dostać hash pełnego snapshotu z blokadami lidera");
  assert.doesNotMatch(inputHashContract,/update public\.optimization_runs_v2 set snapshot_hash=v_hash/,
    "run musi zachować bazowy hash konfiguracji używany przez kontrolę STALE_INPUT");
  assert.match(client,/requestLeaderRefill/);
  assert.match(client,/applyLeaderRefill/);
  assert.match(panel,/Uzupełnij tylko wakaty/);
  assert.match(panel,/Nie udało się uruchomić uzupełnienia/,
    "błąd RPC musi być widoczny bezpośrednio w pełnoekranowym Studio");
  assert.match(panel,/Kliknięcie przyjęte — uruchamiam zadanie/,
    "kliknięcie musi dać natychmiastową, jednoznaczną odpowiedź jeszcze przed wynikiem RPC");
  assert.match(panel,/leaderRefillSubmitting\?"Uruchamiam zadanie…"/,
    "etykieta przycisku nie może wyglądać na bezczynną podczas uruchamiania RPC");
  assert.match(panel,/Brak połączenia z backendem UAT/,
    "chwilowy brak klienta backendu nie może kończyć obsługi kliknięcia po cichu");
  assert.match(panel,/aria-live="assertive"/);
  assert.match(panel,/Generator pracuje/);
  assert.match(panel,/Wpisz co najmniej 3 znaki, aby uruchomić generator tylko dla wakatów/);
  assert.match(panel,/key=\{`leader:\$\{selectedWorkspace\.context\.runId\?\?leaderVariant\.id\}`\}/,
    "odświeżenie rewizji nie może przemontować Studia i wyzerować perspektywy Stanowiska");
  assert.doesNotMatch(panel,/key=\{`leader:[^`]*leaderVariant\.revision/);
  assert.match(panel,/Wszystkie obecne przydziały lidera są zablokowane/);
  assert.match(panel,/result\.variants\.find\(item=>item\.recommended&&item\.hardViolations===0\)/);
});

test("B4F-100 can improve cost or fairness and prepare a proposal without changing explicit locks",async()=>{
  const [migration,panel,client]=await Promise.all([
    readFile(new URL("../supabase/migrations/20260819072223_b4f100_leader_reoptimization_modes.sql",import.meta.url),"utf8"),
    readFile(new URL("../components/SolverV2Panel.tsx",import.meta.url),"utf8"),
    readFile(new URL("../lib/solver-v2.ts",import.meta.url),"utf8"),
  ]);
  assert.match(migration,/optimizer_leader_reoptimization_request_uat_v1/);
  assert.match(migration,/v_mode not in \('COST','FAIRNESS','PROPOSE_ONLY'\)/);
  assert.match(migration,/where assignment\.variant_id=p_variant_id and assignment\.locked/,
    "przeliczenie może utrwalić tylko jawnie przypięte decyzje");
  assert.match(migration,/baselineAssignments/);
  assert.match(migration,/LEADER_OPTIMIZATION_DRAFT_CHANGED/);
  assert.match(migration,/LEADER_OPTIMIZATION_LOCK_NOT_PRESERVED/);
  assert.match(migration,/delete from public\.plan_assignments_v2 assignment[\s\S]*not assignment\.locked/);
  assert.match(migration,/pg_advisory_xact_lock/);
  assert.match(migration,/revoke all on function public\.optimizer_leader_reoptimization_request_uat_v1/);
  assert.match(client,/requestLeaderReoptimization/);
  assert.match(client,/applyLeaderReoptimization/);
  assert.match(panel,/Popraw koszt/);
  assert.match(panel,/Popraw sprawiedliwość/);
  assert.match(panel,/Tylko pokaż propozycję/);
  assert.match(panel,/Propozycja bez automatycznego zapisu/);
  assert.match(panel,/Szkic nie został zmieniony/);
  assert.match(panel,/leaderVariant\.revision!==leaderOptimizationProposal\.leaderRevision/,
    "starej propozycji nie wolno stosować do nowszej rewizji szkicu");
});

test("B4F-107 keeps optional generator tools compact until the leader expands one",async()=>{
  const [panel,styles]=await Promise.all([
    readFile(new URL("../components/SolverV2Panel.tsx",import.meta.url),"utf8"),
    readFile(new URL("../app/product-journey.css",import.meta.url),"utf8"),
  ]);
  assert.match(panel,/className="leader-assistant-tools" aria-label="Opcjonalne narzędzia generatora"/);
  assert.equal((panel.match(/<details className="leader-assistant-tool/g)??[]).length,2,
    "uzupełnienie wakatów i przeliczenie muszą być dwoma niezależnie rozwijanymi narzędziami");
  assert.doesNotMatch(panel,/<details className="leader-assistant-tool[^>]*\sopen(?:=|\s|>)/,
    "narzędzia mają być domyślnie zwinięte, aby kalendarz był widoczny na pierwszym ekranie");
  assert.match(styles,/\.leader-assistant-tools\{[^}]*grid-template-columns:repeat\(2,minmax\(0,1fr\)\)[^}]*padding:8px 18px/);
  assert.match(styles,/\.leader-assistant-tool>summary\{[^}]*min-height:48px/,
    "zwinięte narzędzie nie może ponownie zabierać dużej części wysokości Studia");
  assert.match(styles,/\.leader-assistant-tool:only-child,\.leader-assistant-tool\[open\]\{grid-column:1\/-1\}/,
    "dopiero świadomie rozwinięty formularz może zająć pełną szerokość");
});

test("B4F-74 binds the Studio impact to one revision and one authoritative monthly balance",async()=>{
  const [migration,workspace,client]=await Promise.all([
    readFile(new URL("../supabase/migrations/20260819183425_b4f74_leader_impact_summary.sql",import.meta.url),"utf8"),
    readFile(new URL("../components/SolverV2Workspace.tsx",import.meta.url),"utf8"),
    readFile(new URL("../lib/solver-v2.ts",import.meta.url),"utf8"),
  ]);
  for(const field of ["revision","eligibleLocationIds","externalMinutes","totalMonthlyMinutes","overtimeMinutes","preferenceViolations","assignmentImpacts"]){
    assert.match(migration,new RegExp(`'${field}'`),`kontrakt rozkładu musi zwracać ${field}`);
    assert.match(client,new RegExp(field),`klient musi normalizować ${field}`);
  }
  assert.match(migration,/security definer[\s\S]*set search_path = ''/);
  assert.match(migration,/solver_private\.can_access_run_v2/);
  assert.match(migration,/revoke all on function public\.optimizer_variant_workload_distribution_uat_v1\(uuid\)[\s\S]*from public,anon,authenticated/);
  assert.match(migration,/grant execute on function public\.optimizer_variant_workload_distribution_uat_v1\(uuid\)[\s\S]*to authenticated/);
  assert.match(migration,/'costMinor',case when v_finance_visibility='FULL'/,
    "koszt pojedynczej osoby nie może wyciec poza poziom FULL");
  assert.match(migration,/externalAssignments/);
  assert.match(migration,/preferredShiftTemplateIds/);
  assert.match(migration,/preferredLocationIds/);
  assert.match(migration,/softDayOffDates/);
  assert.match(migration,/workPatterns/);
  assert.match(workspace,/row\.totalMonthlyMinutes>row\.maximumMonthlyMinutes/,
    "twardy limit musi obejmować bieżący szkic i inne grafiki miesiąca");
  assert.match(workspace,/Naruszenia preferencji/);
  assert.match(workspace,/Koszt tej osoby/);
  assert.match(workspace,/studioAnalysisRevision/);
  assert.match(workspace,/shift\.assignments\.filter\(assignment=>!roleFilters\.length\|\|roleFilters\.includes\(assignment\.role\.id\)\)/,
    "filtr roli nie może doliczać przydziałów pozostałych ról na tej samej zmianie");
});

test("Studio role calendar exposes vacancies as drop targets and keeps analytics panels separate",async()=>{
  const [workspace,styles]=await Promise.all([
    readFile(new URL("../components/SolverV2Workspace.tsx",import.meta.url),"utf8"),
    readFile(new URL("../app/product-journey.css",import.meta.url),"utf8"),
  ]);
  assert.match(workspace,/const scheduleRoles=workspaceRoles/,
    "pusty ręczny szkic nadal musi pokazać wszystkie wymagane role");
  assert.match(workspace,/studio-role-vacancy studio-vacancy-target/);
  assert.match(workspace,/studio-employee-vacancies/,
    "perspektywa Pracownicy musi wystawiać jawne wakaty otwierające panel kandydatów");
  assert.match(workspace,/solver-coverage-vacancies/,
    "perspektywa Pokrycie obsady musi wystawiać osobne cele rola-zmiana zamiast niejednoznacznej karty zbiorczej");
  assert.match(workspace,/application\/x-grafik-employee/);
  assert.match(workspace,/applyEmployeeDrop\(issue\.id,employeeId\)/);
  assert.doesNotMatch(workspace,/Dodaj do szkicu/);
  assert.match(workspace,/event\.key==="Enter"/,
    "kandydat musi dać się przydzielić klawiaturą bez przywracania dodatkowego guzika zapisu");
  assert.match(workspace,/Klawiaturą: wybierz wakat, przejdź do osoby i naciśnij Enter/);
  assert.match(workspace,/Obsada i wolne miejsca/);
  assert.match(workspace,/workspaceView==="ISSUES"&&<section className="solver-issues-view">/);
  assert.match(styles,/leader-studio>\.solver-issues-view\{grid-column:2;grid-row:3/);
  assert.match(styles,/\.studio-role-vacancy:hover/);
  assert.doesNotMatch(workspace,/onLeaderChanged\?\.\(\);await openWorkload\(true\)/,
    "zapis w Studio nie może sam przenosić lidera z kalendarza do rozkładu pracy");
});

test("B4F-100 stores named checkpoints and restores them as a new audited draft revision",async()=>{
  const [migration,identityRestore,panel,client]=await Promise.all([
    readFile(new URL("../supabase/migrations/20260819065501_b4f100_leader_named_checkpoints.sql",import.meta.url),"utf8"),
    readFile(new URL("../supabase/migrations/20260819074736_b4f100_leader_history_identity_restore.sql",import.meta.url),"utf8"),
    readFile(new URL("../components/SolverV2Panel.tsx",import.meta.url),"utf8"),
    readFile(new URL("../lib/solver-v2.ts",import.meta.url),"utf8"),
  ]);
  assert.match(migration,/is_checkpoint boolean not null default false/);
  assert.match(migration,/optimizer_leader_checkpoint_create_uat_v1/);
  assert.match(migration,/optimizer_leader_checkpoint_restore_uat_v1/);
  assert.match(migration,/pg_advisory_xact_lock/);
  assert.match(migration,/solver_private\.refresh_leader_variant_uat_v1/);
  assert.match(identityRestore,/optimizer_leader_history_move_uat_v1/);
  assert.match(identityRestore,/optimizer_leader_checkpoint_restore_uat_v1/);
  assert.equal((identityRestore.match(/\) overriding system value/gi)??[]).length,2,
    "zarówno Cofnij/Ponów, jak i punkt kontrolny muszą jawnie przywracać identyfikatory GENERATED ALWAYS");
  assert.match(migration,/revoke all on function[\s\S]*public\.optimizer_leader_checkpoint_create_uat_v1\(uuid,text\)[\s\S]*from public,anon,authenticated/);
  assert.match(migration,/revoke all on function[\s\S]*public\.optimizer_leader_checkpoint_restore_uat_v1\(uuid,bigint,text\)[\s\S]*from public,anon,authenticated/);
  assert.match(client,/createLeaderCheckpoint/);
  assert.match(client,/restoreLeaderCheckpoint/);
  assert.match(panel,/Nazwa punktu kontrolnego/);
  assert.match(panel,/Przywrócić punkt kontrolny\?/);
  assert.match(panel,/Bieżący szkic zostanie zapisany w historii/);
  assert.doesNotMatch(panel,/window\.confirm\([^)]*punkt kontrolny/i);
});

test("Studio keeps the employee side panel available while scrolling through later weeks",async()=>{
  const styles=await readFile(new URL("../app/product-journey.css",import.meta.url),"utf8");
  assert.match(styles,/leader-studio>\.leader-studio-candidate-panel\{[^}]*position:sticky/);
  assert.match(styles,/leader-studio-candidate-panel>\.drawer-content\{[^}]*overflow-y:auto/);
  assert.doesNotMatch(styles,/leader-studio>\.solver-global-filters,.leader-studio>\.leader-studio-candidate-panel,.leader-studio>\.leader-studio-impact\{position:static/);
});

test("current standby preview remains callable while the broken v3 employee wrapper is retired",async()=>{
  const migration=await readFile(new URL(
    "../supabase/migrations/20260819132000_b4f100_standby_preview_contract_cleanup.sql",
    import.meta.url,
  ),"utf8");
  assert.match(migration,/optimizer_variant_standby_preview_uat_v2/);
  assert.match(migration,/md5\(p_variant_id::text \|\| v_date::text \|\| \(v_group->>'code'\) \|\| v_tier::text\)/,
    "kod grupy musi zostać odczytany przed konkatenacją identyfikatora podglądu");
  assert.match(migration,/grant execute on function public\.optimizer_variant_standby_preview_uat_v2\(uuid\)[\s\S]*to authenticated/);
  assert.match(migration,/revoke all on function public\.matrix_v2_employee_save_uat_v3\(uuid, jsonb\)[\s\S]*from public, anon, authenticated/);
});
