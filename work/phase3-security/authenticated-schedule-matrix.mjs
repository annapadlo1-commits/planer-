import crypto from "node:crypto";
import { spawnSync } from "node:child_process";

const projectRef = "nhthrtpkfpmufmrmdyjg";
const productionRef = "bdybebzvzapihjdauehg";
const apiOrigin = `https://${projectRef}.supabase.co`;
const cli = "C:\\Users\\Dawid\\.cache\\codex-runtimes\\codex-primary-runtime\\dependencies\\bin\\fallback\\pnpm.cmd";
const shell = "C:\\Windows\\system32\\cmd.exe";
const setupFile = "work\\phase1-security\\real-auth-fixture-setup.sql";
const cleanupFile = "work\\phase1-security\\real-auth-fixture-cleanup.sql";
const augmentFile = "work\\phase3-security\\authenticated-schedule-augment.sql";
const employeeAId = "f2100000-0000-4000-8000-000000000001";
const employeeBId = "f2100000-0000-4000-8000-000000000002";
const roleXId = "f2300000-0000-4000-8000-000000000001";
const roleYId = "f2300000-0000-4000-8000-000000000002";
const locationAId = "f2400000-0000-4000-8000-000000000001";
const locationBId = "f2400000-0000-4000-8000-000000000002";
const definitions = [
  ["owner", "audit-phase1-owner@szafunek.pl", "OWNER"],
  ["roleManagerX", "audit-phase1-role-manager-x@szafunek.pl", "ROLE_MANAGER"],
  ["locationManagerA", "audit-phase1-location-manager-a@szafunek.pl", "LOCATION_MANAGER"],
  ["employeeA", "audit-phase1-employee-a@szafunek.pl", "EMPLOYEE"],
  ["employeeB", "audit-phase1-employee-b@szafunek.pl", "EMPLOYEE"],
];

function assert(condition, code) { if (!condition) throw new Error(code); }
function collect(value, rows = []) {
  if (Array.isArray(value)) value.forEach(item => collect(item, rows));
  else if (value && typeof value === "object") { rows.push(value); Object.values(value).forEach(item => collect(item, rows)); }
  return rows;
}
function runCli(command, includeStdoutOnError = false) {
  const result = spawnSync(shell, ["/d", "/s", "/c", command], {
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
function loadKeys() {
  const rows = collect(JSON.parse(runCli(`${cli} dlx supabase projects api-keys --project-ref ${projectRef} --reveal --output json`)));
  const secretRow = rows.find(row => String(row.type ?? "").toLowerCase() === "secret" && row.disabled !== true);
  const publishableRow = rows.find(row => String(row.type ?? "").toLowerCase() === "publishable" && row.disabled !== true);
  const secret = secretRow?.api_key ?? secretRow?.key ?? secretRow?.value;
  const publishable = publishableRow?.api_key ?? publishableRow?.key ?? publishableRow?.value;
  assert(typeof secret === "string" && secret.startsWith("sb_secret_"), "MODERN_SECRET_KEY_NOT_FOUND");
  assert(typeof publishable === "string" && publishable.startsWith("sb_publishable_"), "MODERN_PUBLISHABLE_KEY_NOT_FOUND");
  return { secret, publishable };
}
async function admin(secret, path, init = {}) {
  return fetch(`${apiOrigin}/auth/v1/admin${path}`, { ...init, headers: { apikey: secret, "Content-Type": "application/json", ...(init.headers ?? {}) } });
}
async function deleteUsers(secret) {
  const response = await admin(secret, "/users?per_page=1000&page=1");
  const body = await response.json().catch(() => ({}));
  assert(response.ok, `ADMIN_LIST_FAILED_${response.status}`);
  const users = Array.isArray(body.users) ? body.users : [];
  for (const user of users.filter(row => definitions.some(([, email]) => email === String(row.email).toLowerCase()))) {
    const removed = await admin(secret, `/users/${user.id}`, { method: "DELETE" });
    assert(removed.ok || removed.status === 404, `ADMIN_DELETE_FAILED_${removed.status}`);
  }
}
async function createUsers(secret) {
  const personas = {};
  for (const [name, email, appRole] of definitions) {
    const password = `Uat-${crypto.randomBytes(32).toString("base64url")}!9`;
    const response = await admin(secret, "/users", { method: "POST", body: JSON.stringify({ email, password, email_confirm: true, user_metadata: { audit_marker: "PHASE3_AUTH_SCHEDULE" } }) });
    const body = await response.json().catch(() => ({}));
    assert(response.ok && body.id, `ADMIN_CREATE_${name}_FAILED_${response.status}`);
    personas[name] = { id: body.id, email, password, appRole };
  }
  return personas;
}
async function login(personas, publishable) {
  for (const [name, persona] of Object.entries(personas)) {
    const response = await fetch(`${apiOrigin}/auth/v1/token?grant_type=password`, { method: "POST", headers: { apikey: publishable, "Content-Type": "application/json" }, body: JSON.stringify({ email: persona.email, password: persona.password }) });
    const body = await response.json().catch(() => ({}));
    assert(response.ok && body.access_token, `LOGIN_${name}_FAILED_${response.status}`);
    persona.token = body.access_token;
    delete persona.password;
  }
}
async function rpc(persona, publishable, name, args) {
  const response = await fetch(`${apiOrigin}/rest/v1/rpc/${name}`, { method: "POST", headers: { apikey: publishable, Authorization: `Bearer ${persona.token}`, "Content-Type": "application/json" }, body: JSON.stringify(args) });
  const body = await response.json().catch(() => null);
  return { ok: response.ok, status: response.status, body };
}
async function table(persona, publishable, path) {
  const response = await fetch(`${apiOrigin}/rest/v1/${path}`, { headers: { apikey: publishable, Authorization: `Bearer ${persona.token}` } });
  const body = await response.json().catch(() => null);
  return { ok: response.ok, status: response.status, body };
}

async function main() {
  assert(projectRef !== productionRef && projectRef === "nhthrtpkfpmufmrmdyjg", "ABORT_PROJECT_GUARD");
  const { secret, publishable } = loadKeys();
  let personas = {};
  let fixtureReady = false;
  let cleanup;
  let primaryError;
  const evidence = {};
  try {
    await deleteUsers(secret);
    personas = await createUsers(secret);
    const setup = runCli(`${cli} dlx supabase db query --linked --project-ref ${projectRef} --file ${setupFile}`, true);
    assert(setup.includes('"authUsers": 5') || setup.includes('"authUsers":5'), "FIXTURE_SETUP_MISSING");
    fixtureReady = true;
    const augment = runCli(`${cli} dlx supabase db query --linked --project-ref ${projectRef} --file ${augmentFile}`, true);
    assert((augment.includes('"shifts": 2') || augment.includes('"shifts":2'))
      && (augment.includes('"assignments": 2') || augment.includes('"assignments":2')), "FIXTURE_AUGMENT_MISSING");
    await login(personas, publishable);

    for (const [name, expectedEmployee] of [["employeeA", employeeAId], ["employeeB", employeeBId]]) {
      const schedule = await rpc(personas[name], publishable, "optimizer_employee_schedule_uat_v3", { p_month: "2026-08-01" });
      assert(schedule.ok && schedule.body?.engine === "ORTOOLS_V2" && Array.isArray(schedule.body.assignments), `EMPLOYEE_SCHEDULE_${name}_FAILED_${schedule.status}`);
      assert(schedule.body.assignments.length > 0, `EMPLOYEE_SCHEDULE_${name}_EMPTY`);
      const company = await rpc(personas[name], publishable, "published_employee_category_calendar_uat_v3", { p_month: "2026-08-01" });
      assert(company.ok && company.body?.employeeId === expectedEmployee && Array.isArray(company.body.assignments), `EMPLOYEE_COMPANY_CALENDAR_${name}_FAILED_${company.status}`);
      evidence[name] = { ownScheduleHttp: schedule.status, ownAssignments: schedule.body.assignments.length, standby: Array.isArray(schedule.body.standby) ? schedule.body.standby.length : 0, companyCalendarHttp: company.status, companyAssignments: company.body.assignments.length };
    }

    const ownerRows = await table(personas.owner, publishable, "published_role_schedules_v2?select=role_id&month=eq.2026-08-01&status=eq.PUBLISHED");
    assert(ownerRows.ok && [roleXId, roleYId].every(id => ownerRows.body.some(row => row.role_id === id)), `OWNER_PUBLISHED_SCOPE_FAILED_${ownerRows.status}`);
    const roleRows = await table(personas.roleManagerX, publishable, "published_role_schedules_v2?select=role_id&month=eq.2026-08-01&status=eq.PUBLISHED");
    assert(roleRows.ok && roleRows.body.length > 0 && roleRows.body.every(row => row.role_id === roleXId), `ROLE_MANAGER_PUBLISHED_SCOPE_FAILED_${roleRows.status}`);
    const locationAllowed = await rpc(personas.locationManagerA, publishable, "matrix_v2_can_manage_resource_uat_v1", { p_role_id: null, p_location_id: locationAId, p_employee_id: null });
    const locationForeign = await rpc(personas.locationManagerA, publishable, "matrix_v2_can_manage_resource_uat_v1", { p_role_id: null, p_location_id: locationBId, p_employee_id: null });
    assert(locationAllowed.ok && locationAllowed.body === true && locationForeign.ok && locationForeign.body === false, "LOCATION_MANAGER_SCOPE_FAILED");
    const employeeManagerOnly = await rpc(personas.employeeA, publishable, "matrix_v2_can_manage_resource_uat_v1", { p_role_id: roleXId, p_location_id: null, p_employee_id: null });
    assert(employeeManagerOnly.ok && employeeManagerOnly.body === false, "EMPLOYEE_MANAGER_SCOPE_EXPOSED");
    evidence.owner = { publishedRoleRows: ownerRows.body.length };
    evidence.roleManagerX = { publishedRoleRows: roleRows.body.length, onlyRoleX: true };
    evidence.locationManagerA = { locationA: true, locationB: false };
  } catch (error) {
    primaryError = error;
  } finally {
    try {
      if (fixtureReady) {
        const output = runCli(`${cli} dlx supabase db query --linked --project-ref ${projectRef} --file ${cleanupFile}`, true);
        cleanup = JSON.parse(output.slice(output.indexOf("{"))).rows?.[0]?.phase1_real_auth_cleanup ?? null;
        assert(cleanup?.auditAuthUsers === 0 && cleanup?.auditEmployees === 0 && cleanup?.auditRoles === 0
          && cleanup?.auditLocations === 0 && cleanup?.auditDependentRows === 0 && cleanup?.activeMatrices === 0
          && cleanup?.ownerGrants === 1, `CLEANUP_NONZERO:${JSON.stringify(cleanup)}`);
      }
      await deleteUsers(secret);
    } catch (cleanupError) {
      primaryError = primaryError ? new Error(`${primaryError.message};CLEANUP:${cleanupError.message}`) : cleanupError;
    }
  }
  process.stdout.write(`${JSON.stringify({ status: primaryError ? "FAIL" : "PASS", auth: "publishable + normal user JWT", secretUsedForAssertions: false, evidence, cleanup, error: primaryError?.message ?? null }, null, 2)}\n`);
  if (primaryError) throw primaryError;
}

await main();
