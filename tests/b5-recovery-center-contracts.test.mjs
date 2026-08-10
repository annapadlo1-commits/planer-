import test from "node:test";
import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";

const migrationUrl=new URL("../supabase/migrations/20260809210000_b4plus_b5_recovery_center.sql",import.meta.url);
const applyMigrationUrl=new URL("../supabase/migrations/20260809223000_b5_recovery_draft_application.sql",import.meta.url);

test("B5 recovery schema is RLS protected and exposes the complete audited workflow",async()=>{
  const sql=await readFile(migrationUrl,"utf8");
  for(const table of [
    "recovery_month_revisions_v2","recovery_incidents_v2","recovery_actions_v2",
    "recovery_offer_responses_v2","recovery_ad_hoc_pool_v2","recovery_overrides_v2",
  ]){
    assert.match(sql,new RegExp(`create table if not exists public\\.${table}`));
    assert.match(sql,new RegExp(`alter table public\\.${table} enable row level security`));
  }
  for(const fn of [
    "recovery_center_workspace_uat_v1","recovery_incident_save_uat_v1",
    "recovery_incident_prepare_uat_v1","recovery_incident_detail_uat_v1",
    "recovery_employee_offers_uat_v1","recovery_offer_respond_uat_v1",
    "recovery_ad_hoc_save_uat_v1","recovery_override_save_uat_v1",
    "recovery_month_budget_save_uat_v1","optimizer_role_colours_uat_v1",
  ]) assert.match(sql,new RegExp(`function public\\.${fn}`));
  assert.match(sql,/pg_advisory_xact_lock/);
  assert.match(sql,/REVISION_CONFLICT/);
  assert.match(sql,/DRAFT_READY/);
  assert.doesNotMatch(sql,/AUTO_DRAFT[\s\S]{0,2000}status\s*=\s*'PUBLISHED'/);
});

test("manager recovery center contains structural diagnosis, three repair modes and emergency controls",async()=>{
  const source=await readFile(new URL("../components/RecoveryCenter.tsx",import.meta.url),"utf8");
  assert.match(source,/Centrum napraw grafiku/);
  assert.match(source,/POWTARZALNY BRAK ZASOBÓW/);
  assert.match(source,/Zaproponuj/);
  assert.match(source,/Wyślij oferty/);
  assert.match(source,/Przygotuj wersję roboczą/);
  assert.match(source,/Pula ad-hoc/);
  assert.match(source,/Budżet i limity/);
  assert.match(source,/Rodzaj współpracy/);
  assert.match(source,/bez cichej zmiany grafiku/i);
});

test("employee offer response and manager navigation are wired into the application",async()=>{
  const [page,source]=await Promise.all([
    readFile(new URL("../app/page.tsx",import.meta.url),"utf8"),
    readFile(new URL("../components/RecoveryCenter.tsx",import.meta.url),"utf8"),
  ]);
  assert.match(page,/naprawy/);
  assert.match(page,/Centrum napraw/);
  assert.match(page,/employeeMode/);
  assert.match(source,/>Przyjmij</);
  assert.match(source,/>Odrzuć</);
  assert.match(source,/respondRecoveryOffer/);
});

test("recovery decisions create auditable leader drafts and never mutate a published schedule",async()=>{
  const [sql,client,source]=await Promise.all([
    readFile(applyMigrationUrl,"utf8"),
    readFile(new URL("../lib/recovery-center.ts",import.meta.url),"utf8"),
    readFile(new URL("../components/RecoveryCenter.tsx",import.meta.url),"utf8"),
  ]);
  assert.match(sql,/recovery_action_select_candidate_uat_v1/);
  assert.match(sql,/recovery_incident_apply_draft_uat_v1/);
  assert.match(sql,/CREATE_RECOVERY_LEADER_COPY/);
  assert.match(sql,/RECOVERY_CANDIDATE_CHANGED/);
  assert.match(sql,/publishedScheduleChanged',false/);
  assert.match(sql,/optimizer_leader_assignment_save_uat_v2/);
  assert.doesNotMatch(sql,/update\s+public\.published_schedules_v2/i);
  assert.doesNotMatch(sql,/insert\s+into\s+public\.published_role_schedules_v2/i);
  assert.match(client,/selectRecoveryCandidate/);
  assert.match(client,/applyRecoveryDraft/);
  assert.match(source,/Utwórz wersję roboczą ról/);
  assert.match(source,/Opublikowany grafik nie zmienił się/);
});

test("canonical role colours come from the published database configuration",async()=>{
  const [solver,modules,migration]=await Promise.all([
    readFile(new URL("../lib/solver-v2.ts",import.meta.url),"utf8"),
    readFile(new URL("../components/ActiveModules.tsx",import.meta.url),"utf8"),
    readFile(migrationUrl,"utf8"),
  ]);
  assert.match(solver,/optimizer_role_colours_uat_v1/);
  assert.match(modules,/roleCardStyle\(role\.id,role\.color\)/);
  assert.match(modules,/roleColors\[assignment\.roleId\]/);
  assert.match(migration,/with palette\(ordinal, colour\)/);
  assert.match(migration,/role\.color is distinct from palette\.colour/);
});

test("emergency staffing uses canonical contract types and requires an employment compliance confirmation",async()=>{
  const [migration,client,source]=await Promise.all([
    readFile(migrationUrl,"utf8"),
    readFile(new URL("../lib/recovery-center.ts",import.meta.url),"utf8"),
    readFile(new URL("../components/RecoveryCenter.tsx",import.meta.url),"utf8"),
  ]);
  assert.match(migration,/contract_type in \('UMOWA_O_PRACE','CZESC_ETATU','ZLECENIE','B2B','INNE'\)/);
  assert.match(migration,/profile\.employment_start is null or profile\.employment_start<=target\.shift_date/);
  assert.match(migration,/EMPLOYMENT_COMPLIANCE_CONFIRMATION_REQUIRED/);
  assert.match(migration,/compliance_confirmed boolean not null default false/);
  assert.match(client,/p_compliance_confirmed/);
  assert.match(source,/Właściciel potwierdza kontrolę zgodności czasu pracy i podstawy umownej/);
  assert.match(source,/Zwykłej pracy zmianowej nie opisujemy jako umowy o dzieło/);
  assert.doesNotMatch(source,/value="CIVIL_CONTRACT"/);
  assert.doesNotMatch(source,/value="MANDATE"/);
});
