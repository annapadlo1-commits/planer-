import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("../", import.meta.url);
const requiredStages = [
  "onboarding_import_excel",
  "google_sheets_export_import",
  "team_and_access",
  "published_configuration",
  "generator_all_strategies",
  "leader_studio_manual_and_generated",
  "publication_and_employee_portal",
  "analytics_and_staffing_risk",
  "state_filters_scroll_and_console",
];

test("full UAT evidence manifest covers the complete product journey and stays fail-closed", async () => {
  const evidence = JSON.parse(await readFile(new URL("docs/full-uat-evidence.json", root), "utf8"));
  assert.equal(evidence.environment.supabaseProjectRef, "nhthrtpkfpmufmrmdyjg");
  assert.equal(evidence.environment.productionTouched, false);
  assert.deepEqual(evidence.stages.map((stage) => stage.id), requiredStages);
  assert.ok(evidence.stages.every((stage) => ["PENDING", "BLOCKED", "PASS", "FAIL"].includes(stage.status)));
  assert.notEqual(evidence.ownerUat.status, "PASS", "manifest cannot claim owner PASS before physical UAT evidence is recorded");
});

test("full UAT verifier requires every physical stage, browser cleanliness and owner confirmation", async () => {
  const verifier = await readFile(new URL("scripts/validate-full-uat-evidence.mjs", root), "utf8");
  for (const stage of requiredStages) assert.match(verifier, new RegExp(`"${stage}"`));
  assert.match(verifier, /stage\.status !== "PASS"/);
  assert.match(verifier, /consoleErrors !== 0/);
  assert.match(verifier, /unhandledPageErrors !== 0/);
  assert.match(verifier, /ownerUat\?\.status !== "PASS"/);
  assert.match(verifier, /productionTouched !== false/);
});
