import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

test("analytics dashboard is sourced from the published workspace and supports business filters", () => {
  const source = read("components/AnalyticsDashboard.tsx");
  assert.match(source, /data\.assignments/);
  assert.match(source, /Wszystkie lokale/);
  assert.match(source, /Wszystkie role/);
  assert.match(source, /Powtarzalne braki zasobów/);
  assert.doesNotMatch(source, /Math\.random/);
});

test("message center is no longer a placeholder and private RPCs are explicitly granted", () => {
  const page = read("app/page.tsx");
  const ui = read("components/MessageCenter.tsx");
  const migration = read("supabase/migrations/20260812233000_team_communication_uat.sql");
  assert.match(page, /<MessageCenter/);
  assert.doesNotMatch(page, /Wiadomości zespołu są następnym rozszerzeniem/);
  assert.match(ui, /message_conversation_create_uat_v1/);
  assert.match(ui, /message_send_uat_v1/);
  assert.match(migration, /enable row level security/g);
  assert.match(migration, /security definer set search_path=''/g);
  assert.match(migration, /revoke all on function public\.message_center_workspace_uat_v1\(\) from public,anon/);
  assert.match(migration, /grant execute on function public\.message_send_uat_v1\(uuid,text\) to authenticated/);
});

test("employee swap board supports active, targeted, mine and history views", () => {
  const source = read("components/ActiveModules.tsx");
  assert.match(source, /Skierowane do mnie/);
  assert.match(source, /Moje ogłoszenia/);
  assert.match(source, /Historia zakończonych/);
  assert.match(source, /Wpisz imię, nazwisko lub numer/);
  assert.match(source, /Dlaczego część osób jest niedostępna/);
});

test("management navigation follows application roles and scoped managers can read their workspace", () => {
  const journey = read("lib/product-journey.ts");
  const page = read("app/page.tsx");
  assert.match(journey, /managementNavigationForRoles/);
  assert.match(journey, /ROLE_MANAGER: \["start", "team", "schedule", "operations", "analytics"\]/);
  assert.match(page, /"ROLE_MANAGER","LOCATION_MANAGER"/);
  assert.match(page, /scheduleWriteAllowed/);
});
