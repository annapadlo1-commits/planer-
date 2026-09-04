import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  availablePersonas,
  defaultPersonaForAccess,
  employeeNavigation,
  managementNavigationForRoles,
  reconcilePersona,
} from "../lib/product-journey.ts";

const employee = { active: true };

test("active employee remains the least-privileged default with owner or manager access", () => {
  assert.equal(defaultPersonaForAccess([{ app_role: "OWNER" }], employee), "employee");
  assert.equal(defaultPersonaForAccess([{ app_role: "ROLE_MANAGER" }], employee), "employee");
  assert.deepEqual(availablePersonas([{ app_role: "OWNER" }], employee), ["employee", "management"]);
  assert.equal(reconcilePersona("management", [{ app_role: "OWNER" }], employee, false), "employee");
  assert.equal(reconcilePersona("management", [{ app_role: "OWNER" }], employee, true), "management");
});

test("persona availability fails closed for inactive or unlinked employees", () => {
  assert.equal(defaultPersonaForAccess([{ app_role: "OWNER" }], { active: false }), "management");
  assert.equal(defaultPersonaForAccess([{ app_role: "EMPLOYEE" }], { active: false }), null);
  assert.deepEqual(availablePersonas([{ app_role: "EMPLOYEE" }], null), []);
});

test("employee and management navigation remain separate", () => {
  const employeeKeys = employeeNavigation.map(item => item.key);
  const managementKeys = managementNavigationForRoles([{ app_role: "OWNER" }]).map(item => item.key);
  assert.deepEqual(employeeKeys, ["today", "my-schedule", "company-schedule", "swaps", "messages", "profile"]);
  assert.equal(employeeKeys.includes("settings"), false);
  assert.equal(managementKeys.includes("settings"), true);
  assert.equal(managementKeys.includes("today"), false);
});

test("page exposes an explicit switch without widening employee portal props", async () => {
  const source = await readFile(new URL("../app/page.tsx", import.meta.url), "utf8");
  const employeeBranch = source.match(/\{employeeShell\?<\>\s+\{primarySection[\s\S]*?<\/>:<\>/)?.[0] ?? "";
  assert.match(source, /switchPersona/);
  assert.match(source, /aria-pressed=\{activePersona===\"employee\"\}/);
  assert.match(source, /aria-pressed=\{activePersona===\"management\"\}/);
  assert.match(employeeBranch, /employeeIdentity=\{employeePortalIdentity\}/);
  assert.doesNotMatch(employeeBranch, /allowUatMasterPersona/);
  assert.match(source, /active===\"portal\".*allowUatMasterPersona/s);
});
