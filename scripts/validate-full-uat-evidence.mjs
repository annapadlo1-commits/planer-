import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";

const root = new URL("../", import.meta.url);
const evidence = JSON.parse(readFileSync(new URL("docs/full-uat-evidence.json", root), "utf8"));
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

const failures = [];
const head = execFileSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" }).trim();
if (evidence.environment?.supabaseProjectRef !== "nhthrtpkfpmufmrmdyjg") {
  failures.push("Dowód nie wskazuje wyłącznego projektu Supabase UAT nhthrtpkfpmufmrmdyjg.");
}
if (evidence.environment?.productionTouched !== false) failures.push("Dowód musi jawnie potwierdzać brak mutacji produkcji.");
if (evidence.deployedCommit !== head) failures.push(`Commit dowodu ${evidence.deployedCommit || "BRAK"} nie jest bieżącym HEAD ${head}.`);
if (!evidence.canonicalUatUrl?.startsWith("https://")) failures.push("Brak kanonicznego adresu HTTPS UAT.");

for (const id of requiredStages) {
  const stage = evidence.stages?.find((item) => item.id === id);
  if (!stage) {
    failures.push(`Brak wymaganego etapu E2E: ${id}.`);
    continue;
  }
  if (stage.status !== "PASS") failures.push(`${id}: status ${stage.status || "BRAK"}, wymagany PASS.`);
  if (!stage.startedAt || !stage.finishedAt) failures.push(`${id}: brak czasu rozpoczęcia lub zakończenia.`);
  if (!stage.actorRole) failures.push(`${id}: brak roli wykonującej test.`);
  if (!Array.isArray(stage.evidence) || stage.evidence.length === 0) failures.push(`${id}: brak dowodu fizycznego.`);
}

if (evidence.browser?.consoleErrors !== 0) failures.push("Konsola przeglądarki musi mieć dokładnie 0 błędów.");
if (evidence.browser?.unhandledPageErrors !== 0) failures.push("Liczba nieobsłużonych błędów strony musi wynosić 0.");
if (evidence.ownerUat?.status !== "PASS") failures.push("Brak końcowego PASS właścicielki produktu.");

if (failures.length) {
  console.error("FULL UAT EVIDENCE: NOT READY");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

console.log(`FULL UAT EVIDENCE: PASS • ${head} • ${requiredStages.length} etapów`);
