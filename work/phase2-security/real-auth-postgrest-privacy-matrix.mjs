import crypto from "node:crypto";
import { spawnSync } from "node:child_process";

const mode = process.argv[2] ?? "EXPECT_FIXED";
if (!new Set(["EXPECT_LEAK", "EXPECT_FIXED"]).has(mode)) throw new Error(`INVALID_MODE:${mode}`);

const projectRef = "nhthrtpkfpmufmrmdyjg";
const productionRef = "bdybebzvzapihjdauehg";
const apiOrigin = `https://${projectRef}.supabase.co`;
const cli = "C:\\Users\\Dawid\\.cache\\codex-runtimes\\codex-primary-runtime\\dependencies\\bin\\fallback\\pnpm.cmd";
const commandShell = "C:\\Windows\\system32\\cmd.exe";
const setupFile = "work\\phase2-security\\real-auth-fixture-setup.sql";
const cleanupFile = "work\\phase2-security\\real-auth-fixture-cleanup.sql";

const ids = {
  a: "f3100000-0000-4000-8000-000000000001",
  b: "f3100000-0000-4000-8000-000000000002",
  c: "f3100000-0000-4000-8000-000000000003",
  d: "f3100000-0000-4000-8000-000000000004",
  roleX: "f3300000-0000-4000-8000-000000000001",
};
const allEmployees = [ids.a, ids.b, ids.c, ids.d];
const definitions = [
  ["owner", "audit-phase2-owner@szafunek.pl", "OWNER"],
  ["roleManagerX", "audit-phase2-role-manager-x@szafunek.pl", "ROLE_MANAGER"],
  ["locationManagerA", "audit-phase2-location-manager-a@szafunek.pl", "LOCATION_MANAGER"],
  ["employeeA", "audit-phase2-employee-a@szafunek.pl", "EMPLOYEE"],
  ["employeeB", "audit-phase2-employee-b@szafunek.pl", "EMPLOYEE"],
];

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
function loadKeysInMemory() {
  const stdout = runCli(`${cli} dlx supabase projects api-keys --project-ref ${projectRef} --reveal --output json`);
  const rows = collectObjects(JSON.parse(stdout));
  const admin = rows.find(row => String(row.type ?? "").toLowerCase() === "secret" && row.disabled !== true);
  const publishable = rows.find(row => String(row.type ?? "").toLowerCase() === "publishable" && row.disabled !== true);
  const adminKey = admin?.api_key ?? admin?.key ?? admin?.value;
  const publicKey = publishable?.api_key ?? publishable?.key ?? publishable?.value;
  assert(typeof adminKey === "string" && adminKey.startsWith("sb_secret_"), "MODERN_SECRET_KEY_NOT_FOUND");
  assert(typeof publicKey === "string" && publicKey.startsWith("sb_publishable_"), "MODERN_PUBLISHABLE_KEY_NOT_FOUND");
  return { adminKey, publicKey };
}
async function adminRequest(adminKey, path, init = {}) {
  return fetch(`${apiOrigin}/auth/v1/admin${path}`, {
    ...init,
    headers: { apikey: adminKey, "Content-Type": "application/json", ...(init.headers ?? {}) },
  });
}
async function deleteAuditUsers(adminKey) {
  const response = await adminRequest(adminKey, "/users?per_page=1000&page=1");
  const body = await response.json().catch(() => ({}));
  assert(response.ok, `ADMIN_LIST_USERS_FAILED_${response.status}`);
  const users = Array.isArray(body.users) ? body.users : Array.isArray(body) ? body : [];
  for (const user of users.filter(row => definitions.some(([, email]) => email === String(row.email).toLowerCase()))) {
    const deleted = await adminRequest(adminKey, `/users/${user.id}`, { method: "DELETE" });
    assert(deleted.ok || deleted.status === 404, `ADMIN_DELETE_FAILED_${deleted.status}`);
  }
}
async function createPersonas(adminKey) {
  const personas = {};
  for (const [name, email, appRole] of definitions) {
    const password = `Uat-${crypto.randomBytes(32).toString("base64url")}!9`;
    const response = await adminRequest(adminKey, "/users", {
      method: "POST",
      body: JSON.stringify({ email, password, email_confirm: true, user_metadata: { audit_marker: "PHASE2_PRIVACY", audit_persona: name } }),
    });
    const body = await response.json().catch(() => ({}));
    assert(response.ok && body.id, `ADMIN_CREATE_${name}_FAILED_${response.status}`);
    personas[name] = { id: body.id, email, password, appRole };
  }
  return personas;
}
async function login(personas, publicKey) {
  for (const [name, persona] of Object.entries(personas)) {
    const response = await fetch(`${apiOrigin}/auth/v1/token?grant_type=password`, {
      method: "POST", headers: { apikey: publicKey, "Content-Type": "application/json" },
      body: JSON.stringify({ email: persona.email, password: persona.password }),
    });
    const body = await response.json().catch(() => ({}));
    assert(response.ok && body.access_token && body.user?.id === persona.id, `LOGIN_${name}_FAILED_${response.status}`);
    const claims = JSON.parse(Buffer.from(body.access_token.split(".")[1], "base64url").toString("utf8"));
    assert(claims.role === "authenticated" && claims.sub === persona.id && claims.iss === `${apiOrigin}/auth/v1`, `JWT_${name}_INVALID`);
    persona.token = body.access_token;
    persona.safeClaims = { uidPrefix: persona.id.slice(0, 8), role: claims.role, issuerRef: projectRef };
    delete persona.password;
  }
}
async function rpc(persona, name, args, publicKey) {
  const response = await fetch(`${apiOrigin}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: { apikey: publicKey, Authorization: `Bearer ${persona.token}`, "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  const text = await response.text();
  let body; try { body = JSON.parse(text); } catch { body = text; }
  return { ok: response.ok, status: response.status, body };
}
const sorted = values => [...values].sort();
const same = (actual, expected) => JSON.stringify(sorted(actual)) === JSON.stringify(sorted(expected));
const collectionIds = (payload, collection, key) => (payload[collection] ?? []).map(row => row[key]).filter(Boolean);
function assertInvariant(payload, visible, label) {
  const visibleSet = new Set(visible);
  const collections = [
    ["employeeRoles", "employee_id"], ["employeeLocations", "employee_id"],
    ["employeeDuties", "employee_id"], ["timeConstraints", "employeeId"],
    ["workPatterns", "employeeId"], ["employeePayRates", "employee_id"],
  ];
  for (const [collection, key] of collections) {
    for (const employeeId of collectionIds(payload, collection, key)) {
      assert(visibleSet.has(employeeId), `${label}_${collection}_OUTSIDE_VISIBLE:${employeeId}`);
    }
  }
  for (const row of payload.adHocWorkers ?? []) {
    if (row.employee_id) assert(visibleSet.has(row.employee_id), `${label}_ADHOC_OUTSIDE_VISIBLE:${row.employee_id}`);
  }
}
function summarize(payload) {
  return {
    employees: collectionIds(payload, "employees", "id"),
    employeeRoles: collectionIds(payload, "employeeRoles", "employee_id"),
    employeeLocations: collectionIds(payload, "employeeLocations", "employee_id"),
    timeConstraints: collectionIds(payload, "timeConstraints", "employeeId"),
    workPatterns: collectionIds(payload, "workPatterns", "employeeId"),
    employeePayRates: collectionIds(payload, "employeePayRates", "employee_id"),
    adHocWorkers: (payload.adHocWorkers ?? []).map(row => ({ employeeId: row.employee_id ?? null, displayName: row.display_name, hasRate: "base_rate_minor" in row || "currency" in row })),
    financeVisibility: payload.financeVisibility,
  };
}

async function main() {
  assert(projectRef !== productionRef, "ABORT_PRODUCTION_PROJECT_REF");
  const settings = await fetch(`${apiOrigin}/auth/v1/settings`);
  assert([200, 401, 403].includes(settings.status), "ABORT_UNEXPECTED_API_ORIGIN");
  const { adminKey, publicKey } = loadKeysInMemory();
  let personas = {};
  let fixtureReady = false;
  let cleanup = null;
  let primaryError;
  const evidence = {};
  try {
    await deleteAuditUsers(adminKey);
    personas = await createPersonas(adminKey);
    const setup = runCli(`${cli} dlx supabase db query --linked --project-ref ${projectRef} --file ${setupFile}`, true);
    assert(setup.includes('"authUsers": 5') || setup.includes('"authUsers":5'), "FIXTURE_SETUP_EVIDENCE_MISSING");
    fixtureReady = true;
    await login(personas, publicKey);

    for (const [name, persona] of Object.entries(personas)) {
      const response = await rpc(persona, "matrix_v2_workspace", { p_month: "2026-08-01" }, publicKey);
      assert(response.ok && response.body && typeof response.body === "object", `WORKSPACE_${name}_FAILED_${response.status}`);
      evidence[name] = summarize(response.body);
    }

    const employeeLeak = evidence.employeeA.workPatterns.some(id => id !== ids.a)
      && evidence.employeeA.adHocWorkers.some(row => row.employeeId && row.employeeId !== ids.a);
    if (mode === "EXPECT_LEAK") {
      assert(employeeLeak, "BASELINE_PRIVACY_LEAK_NOT_REPRODUCED");
      const bypass = await rpc(personas.employeeA, "matrix_v2_workspace_before_overtime_uat_v1", { p_month: "2026-08-01" }, publicKey);
      assert(bypass.ok && (bypass.body.adHocWorkers ?? []).some(row => "base_rate_minor" in row), "BASELINE_INTERNAL_WRAPPER_BYPASS_NOT_REPRODUCED");
      evidence.baseline = { employeeLeak: true, internalWrapperFinancialBypass: true, internalWrapperStatus: bypass.status };
    } else {
      const expected = {
        owner: allEmployees,
        roleManagerX: [ids.a, ids.c],
        locationManagerA: [ids.a, ids.b],
        employeeA: [ids.a],
        employeeB: [ids.b],
      };
      for (const [name, visible] of Object.entries(expected)) {
        assert(same(evidence[name].employees, visible), `${name}_EMPLOYEES_SCOPE_INVALID:${JSON.stringify(evidence[name].employees)}`);
        assertInvariant((await rpc(personas[name], "matrix_v2_workspace", { p_month: "2026-08-01" }, publicKey)).body, visible, name);
        for (const key of ["employeeRoles", "employeeLocations", "timeConstraints", "workPatterns"])
          assert(same(evidence[name][key], visible), `${name}_${key}_SCOPE_INVALID:${JSON.stringify(evidence[name][key])}`);
      }
      assert(same(evidence.owner.employeePayRates, allEmployees), "OWNER_FINANCE_PROJECTION_INCOMPLETE");
      for (const name of ["roleManagerX", "locationManagerA", "employeeA", "employeeB"])
        assert(evidence[name].employeePayRates.length === 0, `${name}_EMPLOYEE_PAY_RATES_NOT_REDACTED`);
      assert(evidence.roleManagerX.adHocWorkers.every(row => !row.hasRate), "ROLE_MANAGER_ADHOC_FINANCE_NOT_REDACTED");
      assert(same(evidence.roleManagerX.adHocWorkers.filter(row => row.employeeId).map(row => row.employeeId), [ids.a, ids.c]), "ROLE_MANAGER_ADHOC_SCOPE_INVALID");
      assert(evidence.roleManagerX.adHocWorkers.some(row => row.displayName === "AUDIT P2 TEMP X")
        && !evidence.roleManagerX.adHocWorkers.some(row => row.displayName === "AUDIT P2 TEMP Y"), "ROLE_MANAGER_TEMP_ADHOC_SCOPE_INVALID");
      assert(same(evidence.locationManagerA.adHocWorkers.filter(row => row.employeeId).map(row => row.employeeId), [ids.a, ids.b])
        && !evidence.locationManagerA.adHocWorkers.some(row => row.employeeId === null), "LOCATION_MANAGER_ADHOC_SCOPE_INVALID");
      assert(evidence.employeeA.adHocWorkers.length === 0 && evidence.employeeB.adHocWorkers.length === 0, "EMPLOYEE_RECOVERY_ADHOC_EXPOSED");
      assert(!employeeLeak, "EMPLOYEE_COWORKER_LEAK_REMAINS");

      for (const internal of [
        "matrix_v2_workspace_before_categories_uat_v1", "matrix_v2_workspace_before_overtime_uat_v1",
        "matrix_v2_workspace_before_ad_hoc_projection_uat_v1", "matrix_v2_workspace_before_b4f91_uat_v1",
        "matrix_v2_workspace_before_b4f52_uat_v1", "matrix_v2_workspace_before_employee_privacy_uat_v1",
      ]) {
        const response = await rpc(personas.employeeA, internal, { p_month: "2026-08-01" }, publicKey);
        assert(!response.ok, `INTERNAL_WRAPPER_EXECUTABLE:${internal}:${response.status}`);
      }

      const revoke = await rpc(personas.owner, "matrix_scope_grant_save_v2", {
        p_id: null, p_auth_user_id: personas.roleManagerX.id, p_app_role: "ROLE_MANAGER",
        p_role_id: ids.roleX, p_location_id: null, p_duty_id: null, p_active: false,
      }, publicKey);
      assert(revoke.ok, `SCOPE_REVOKE_FAILED_${revoke.status}`);
      const afterRevoke = await rpc(personas.roleManagerX, "matrix_v2_workspace", { p_month: "2026-08-01" }, publicKey);
      assert(afterRevoke.ok, `WORKSPACE_AFTER_REVOKE_FAILED_${afterRevoke.status}`);
      const revokedSummary = summarize(afterRevoke.body);
      assert(revokedSummary.employees.length === 0 && revokedSummary.workPatterns.length === 0
        && revokedSummary.timeConstraints.length === 0 && revokedSummary.adHocWorkers.length === 0,
      `SAME_JWT_REVOKE_NOT_IMMEDIATE:${JSON.stringify(revokedSummary)}`);
      evidence.revokeSameJwt = revokedSummary;
      const restore = await rpc(personas.owner, "matrix_scope_grant_save_v2", {
        p_id: null, p_auth_user_id: personas.roleManagerX.id, p_app_role: "ROLE_MANAGER",
        p_role_id: ids.roleX, p_location_id: null, p_duty_id: null, p_active: true,
      }, publicKey);
      assert(restore.ok, `SCOPE_RESTORE_FAILED_${restore.status}`);
    }

    process.stdout.write(`${JSON.stringify({ status: "TESTS_PASS", mode, authMethod: "Supabase Auth password grant", tokenType: "normal authenticated access_token", serviceKeyUsedForAssertions: false, personas: Object.fromEntries(Object.entries(personas).map(([name, value]) => [name, value.safeClaims])), evidence }, null, 2)}\n`);
  } catch (error) {
    primaryError = error;
  } finally {
    try {
      if (fixtureReady) {
        const output = runCli(`${cli} dlx supabase db query --linked --project-ref ${projectRef} --file ${cleanupFile}`, true);
        cleanup = JSON.parse(output.slice(output.indexOf("{"))).rows?.[0]?.phase2_real_auth_cleanup ?? null;
        assert(cleanup && cleanup.auditAuthUsers === 0 && cleanup.auditEmployees === 0 && cleanup.auditRoles === 0
          && cleanup.auditLocations === 0 && cleanup.auditMatrices === 0 && cleanup.auditPatterns === 0
          && cleanup.auditAdHoc === 0 && cleanup.auditDependentData === 0 && cleanup.activeMatrices === 0
          && cleanup.ownerGrants === 1, `POSTFLIGHT_CLEANUP_NONZERO:${JSON.stringify(cleanup)}`);
      }
      await deleteAuditUsers(adminKey);
    } catch (cleanupError) {
      primaryError = primaryError ? new Error(`${primaryError.message};CLEANUP:${cleanupError.message}`) : cleanupError;
    }
  }
  process.stdout.write(`${JSON.stringify({ status: primaryError ? "FAIL" : "PASS", mode, cleanup, error: primaryError?.message ?? null }, null, 2)}\n`);
  if (primaryError) throw primaryError;
}

await main();
