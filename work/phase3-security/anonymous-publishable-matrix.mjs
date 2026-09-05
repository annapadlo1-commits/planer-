import { spawnSync } from "node:child_process";

const mode = process.argv[2] ?? "EXPECT_FIXED";
if (!new Set(["EXPECT_LEAK", "EXPECT_BASELINE_DENY", "EXPECT_FIXED"]).has(mode)) throw new Error(`INVALID_MODE:${mode}`);

const projectRef = "nhthrtpkfpmufmrmdyjg";
const productionRef = "bdybebzvzapihjdauehg";
const apiOrigin = `https://${projectRef}.supabase.co`;
const cli = "C:\\Users\\Dawid\\.cache\\codex-runtimes\\codex-primary-runtime\\dependencies\\bin\\fallback\\pnpm.cmd";
const commandShell = "C:\\Windows\\system32\\cmd.exe";
const setupFile = "work\\phase3-security\\anonymous-fixture-setup.sql";
const cleanupFile = "work\\phase3-security\\anonymous-fixture-cleanup.sql";
const shiftId = "f4300000-0000-4000-8000-000000000001";

function assert(condition, code) { if (!condition) throw new Error(code); }
function collectObjects(value, result = []) {
  if (Array.isArray(value)) for (const item of value) collectObjects(item, result);
  else if (value && typeof value === "object") {
    result.push(value);
    for (const item of Object.values(value)) collectObjects(item, result);
  }
  return result;
}
function runCli(command, includeStdoutOnError = false) {
  const result = spawnSync(commandShell, ["/d", "/s", "/c", command], {
    encoding: "utf8", windowsHide: true,
    env: { ...process.env, PATH: `C:\\Users\\Dawid\\.cache\\codex-runtimes\\codex-primary-runtime\\dependencies\\node\\bin;${process.env.PATH ?? ""}` },
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.status !== 0) {
    const safe = `${result.stderr ?? ""}${includeStdoutOnError ? result.stdout ?? "" : ""}`
      .replace(/[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}/g, "[REDACTED_JWT]")
      .replace(/sb_(?:secret|publishable)_[A-Za-z0-9_-]+/g, "[REDACTED_API_KEY]").slice(0, 1500);
    throw new Error(`CLI_FAILED:${safe || result.status}`);
  }
  return result.stdout;
}
function loadPublishableKeyInMemory() {
  const stdout = runCli(`${cli} dlx supabase projects api-keys --project-ref ${projectRef} --reveal --output json`);
  const rows = collectObjects(JSON.parse(stdout));
  const modern = rows.find(row => String(row.type ?? "").toLowerCase() === "publishable" && row.disabled !== true);
  const key = modern?.api_key ?? modern?.key ?? modern?.value;
  assert(typeof key === "string" && key.startsWith("sb_publishable_"), "ACTIVE_MODERN_PUBLISHABLE_KEY_NOT_FOUND");
  return key;
}
async function anonymousGet(publicKey, path) {
  const response = await fetch(`${apiOrigin}/rest/v1/${path}`, { headers: { apikey: publicKey } });
  const text = await response.text();
  let body; try { body = JSON.parse(text); } catch { body = text; }
  return { status: response.status, ok: response.ok, body };
}
async function anonymousRpc(publicKey, name, args) {
  const response = await fetch(`${apiOrigin}/rest/v1/rpc/${name}`, {
    method: "POST", headers: { apikey: publicKey, "Content-Type": "application/json" }, body: JSON.stringify(args),
  });
  const text = await response.text();
  let body; try { body = JSON.parse(text); } catch { body = text; }
  return { status: response.status, ok: response.ok, body };
}
function summarizeTable(surface, result) {
  const rows = Array.isArray(result.body) ? result.body : [];
  const fields = rows.flatMap(row => row && typeof row === "object" ? Object.keys(row) : []);
  const sensitiveFields = ["plan_id", "location_id", "shift_date", "shift_code", "starts_at", "ends_at", "employee_id", "role_id"];
  const errorCode = !result.ok && result.body && typeof result.body === "object" ? String(result.body.code ?? "") : "";
  const errorMessage = !result.ok && result.body && typeof result.body === "object" ? String(result.body.message ?? "").slice(0, 160) : "";
  return { surface, http: result.status, rows: rows.length, sensitiveFieldsPresent: sensitiveFields.some(field => fields.includes(field)), errorCode, errorMessage };
}

async function main() {
  assert(projectRef !== productionRef && projectRef === "nhthrtpkfpmufmrmdyjg", "ABORT_PROJECT_GUARD");
  const settings = await fetch(`${apiOrigin}/auth/v1/settings`);
  assert([200, 401, 403].includes(settings.status), "ABORT_UNEXPECTED_API_ORIGIN");
  const publicKey = loadPublishableKeyInMemory();
  let fixtureReady = false;
  let primaryError;
  let cleanup;
  const evidence = [];
  try {
    const setup = runCli(`${cli} dlx supabase db query --linked --project-ref ${projectRef} --file ${setupFile}`, true);
    assert(setup.includes('"shifts": 1') || setup.includes('"shifts":1'), "FIXTURE_SETUP_EVIDENCE_MISSING");
    fixtureReady = true;

    const surfaces = [
      ["published legacy shifts", `shifts?select=id,plan_id,location_id,shift_date,shift_code,starts_at,ends_at,status&id=eq.${shiftId}`],
      ["legacy assignments", "assignments?select=id,shift_id,employee_id,assigned_role&limit=5"],
      ["legacy plans", "plans?select=id,month,status&name=eq.AUDIT%20PHASE3%20PUBLISHED%20PLAN"],
      ["composite schedules", "composite_schedules?select=id,month,status&limit=5"],
      ["published schedules v2", "published_schedules_v2?select=*&limit=5"],
      ["published role schedules v2", "published_role_schedules_v2?select=*&limit=5"],
      ["published schedule variants v2", "published_schedule_variants_v2?select=*&limit=5"],
      ["published standby v2", "published_standby_assignments_v2?select=*&limit=5"],
      ["plan shifts v2", "plan_shifts_v2?select=*&limit=5"],
      ["plan assignments v2", "plan_assignments_v2?select=*&limit=5"],
      ["plan assignment duties v2", "plan_assignment_duties_v2?select=*&limit=5"],
    ];
    for (const [label, path] of surfaces) evidence.push(summarizeTable(label, await anonymousGet(publicKey, path)));

    const rpcs = [
      ["optimizer_employee_schedule_uat_v3", { p_month: "2026-10-01" }],
      ["published_employee_category_calendar_uat_v3", { p_month: "2026-10-01" }],
      ["schedule_publication_status_uat_v2", { p_month: "2026-10-01" }],
      ["optimizer_published_schedule_v2", { p_schedule_id: "f4200000-0000-4000-8000-000000000001" }],
    ];
    for (const [name, args] of rpcs) {
      const response = await anonymousRpc(publicKey, name, args);
      const rows = Array.isArray(response.body) ? response.body.length : response.body && typeof response.body === "object" && !response.body.code ? 1 : 0;
      evidence.push({ surface: `RPC ${name}`, http: response.status, rows, sensitiveFieldsPresent: false });
      assert(!response.ok, `ANONYMOUS_RPC_BYPASS:${name}:${response.status}`);
    }

    const shifts = evidence.find(row => row.surface === "published legacy shifts");
    if (mode === "EXPECT_LEAK") {
      assert(shifts.http === 200 && shifts.rows === 1 && shifts.sensitiveFieldsPresent, `PREFLIGHT_LEAK_NOT_REPRODUCED:${JSON.stringify(shifts)}`);
    } else {
      assert(shifts.rows === 0, `ANONYMOUS_SHIFT_ROWS_EXPOSED:${JSON.stringify(shifts)}`);
      for (const row of evidence) assert(row.rows === 0, `ANONYMOUS_SCHEDULE_ROWS_EXPOSED:${JSON.stringify(row)}`);
      if (mode === "EXPECT_FIXED") {
        const assignments = evidence.find(row => row.surface === "legacy assignments");
        assert(shifts.errorCode === "42501" && /permission denied for table shifts/i.test(shifts.errorMessage),
          `SHIFT_DENIAL_NOT_LOCAL_TO_TABLE_ACL:${JSON.stringify(shifts)}`);
        assert(assignments?.errorCode === "42501" && /permission denied for table assignments/i.test(assignments.errorMessage),
          `ASSIGNMENT_DENIAL_NOT_LOCAL_TO_TABLE_ACL:${JSON.stringify(assignments)}`);
        assert(!/has_app_role/i.test(`${shifts.errorMessage} ${assignments?.errorMessage ?? ""}`),
          "ANONYMOUS_DENIAL_STILL_DEPENDS_ON_HAS_APP_ROLE_FAILURE");
      }
    }
  } catch (error) {
    primaryError = error;
  } finally {
    try {
      if (fixtureReady) {
        const output = runCli(`${cli} dlx supabase db query --linked --project-ref ${projectRef} --file ${cleanupFile}`, true);
        cleanup = JSON.parse(output.slice(output.indexOf("{"))).rows?.[0]?.phase3_fixture_cleanup ?? null;
        assert(cleanup && cleanup.auditUsers === 0 && cleanup.auditEmployees === 0 && cleanup.auditRoles === 0
          && cleanup.auditLocations === 0 && cleanup.auditMatrices === 0 && cleanup.auditSchedules === 0
          && cleanup.auditShifts === 0 && cleanup.auditAssignments === 0 && cleanup.auditStandby === 0
          && cleanup.activeMatrices === 0 && cleanup.ownerGrants === 1,
        `POSTFLIGHT_CLEANUP_NONZERO:${JSON.stringify(cleanup)}`);
      }
    } catch (cleanupError) {
      primaryError = primaryError ? new Error(`${primaryError.message};CLEANUP:${cleanupError.message}`) : cleanupError;
    }
  }
  process.stdout.write(`${JSON.stringify({ status: primaryError ? "FAIL" : "PASS", mode, credential: "active sb_publishable_*", userJwt: false, secretUsedForAssertions: false, evidence, cleanup, error: primaryError?.message ?? null }, null, 2)}\n`);
  if (primaryError) throw primaryError;
}

await main();
