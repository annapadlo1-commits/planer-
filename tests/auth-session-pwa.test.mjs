import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  authEventAction,
  beginAuthVerification,
  browserIsOffline,
  classifySessionFailure,
  clearProtectedBrowserState,
  createAuthVerificationGate,
  invalidateAuthVerification,
  isAuthVerificationCurrent,
  SESSION_CHECK_FAILED_MESSAGE,
  SESSION_EXPIRED_MESSAGE,
} from "../lib/auth-session.ts";

class MemoryStorage {
  constructor(entries = []) { this.values = new Map(entries); }
  get length() { return this.values.size; }
  clear() { this.values.clear(); }
  getItem(key) { return this.values.get(key) ?? null; }
  key(index) { return [...this.values.keys()][index] ?? null; }
  removeItem(key) { this.values.delete(key); }
}

test("session failures distinguish missing, revoked and network states", () => {
  assert.equal(classifySessionFailure(null), "MISSING");
  assert.equal(classifySessionFailure({ name: "AuthSessionMissingError" }), "MISSING");
  assert.equal(classifySessionFailure({ code: "refresh_token_not_found" }), "INVALID");
  assert.equal(classifySessionFailure({ message: "Invalid Refresh Token: Refresh Token Not Found" }), "INVALID");
  assert.equal(classifySessionFailure({ status: 401, message: "Invalid JWT" }), "INVALID");
  assert.equal(classifySessionFailure({ code: "user_not_found" }), "INVALID");
  assert.equal(classifySessionFailure({ name: "AuthRetryableFetchError", message: "Failed to fetch" }), "NETWORK");
  assert.match(SESSION_EXPIRED_MESSAGE, /Zaloguj się ponownie/);
  assert.match(SESSION_CHECK_FAILED_MESSAGE, /Sprawdź połączenie/);
});

test("auth event state machine re-verifies identity and access on token refresh", () => {
  assert.equal(authEventAction("INITIAL_SESSION"), "IGNORE");
  assert.equal(authEventAction("SIGNED_IN"), "VERIFY");
  assert.equal(authEventAction("USER_UPDATED"), "VERIFY");
  assert.equal(authEventAction("PASSWORD_RECOVERY"), "VERIFY");
  assert.equal(authEventAction("TOKEN_REFRESHED"), "VERIFY");
  assert.equal(authEventAction("SIGNED_OUT"), "CLEAR");
});

test("auth verification generation rejects stale identity and permission results", () => {
  const gate = createAuthVerificationGate();
  const ownerRequest = beginAuthVerification(gate);
  assert.equal(isAuthVerificationCurrent(gate, ownerRequest), true);
  const scopedRoleRequest = beginAuthVerification(gate);
  assert.equal(isAuthVerificationCurrent(gate, ownerRequest), false);
  assert.equal(isAuthVerificationCurrent(gate, scopedRoleRequest), true);
  invalidateAuthVerification(gate);
  assert.equal(isAuthVerificationCurrent(gate, scopedRoleRequest), false);
});

test("SSR never mistakes the Node navigator shim for an offline browser", () => {
  assert.equal(browserIsOffline(undefined), false);
  assert.equal(browserIsOffline(null), false);
  assert.equal(browserIsOffline({ navigator: {} }), false);
  assert.equal(browserIsOffline({ navigator: { onLine: true } }), false);
  assert.equal(browserIsOffline({ navigator: { onLine: false } }), true);
});

test("logout cleanup removes protected work state but preserves PWA and game preferences", () => {
  const local = new MemoryStorage([
    ["grafik-pro:solver-run:user:2026-08", "run-id"],
    ["grafik-pro:published-schedule-v2:user:2026-08", "schedule-id"],
    ["szafunek:pwa-install:shown-at", "1"],
    ["szafunek-game-2048-best", "512"],
  ]);
  const session = new MemoryStorage([
    ["grafik-pro:matrix-v2:draft", "sensitive-draft"],
    ["grafik-pro:selected-month", "2026-08"],
  ]);

  clearProtectedBrowserState(local, session);

  assert.equal(session.length, 0);
  assert.equal(local.getItem("grafik-pro:solver-run:user:2026-08"), null);
  assert.equal(local.getItem("grafik-pro:published-schedule-v2:user:2026-08"), null);
  assert.equal(local.getItem("szafunek:pwa-install:shown-at"), "1");
  assert.equal(local.getItem("szafunek-game-2048-best"), "512");
});

test("Next proxy verifies claims, rotates cookies and prevents authenticated response caching", async () => {
  const proxy = await readFile(new URL("../lib/supabase/proxy.ts", import.meta.url), "utf8");
  const entry = await readFile(new URL("../proxy.ts", import.meta.url), "utf8");
  assert.match(proxy, /createServerClient/);
  assert.match(proxy, /request\.cookies\.getAll\(\)/);
  assert.match(proxy, /request\.cookies\.set\(name, value\)/);
  assert.match(proxy, /supabaseResponse\.cookies\.set\(name, value, options\)/);
  assert.match(proxy, /Object\.entries\(cacheHeaders\)/);
  assert.match(proxy, /supabase\.auth\.getClaims\(\)/);
  assert.doesNotMatch(proxy, /auth\.getSession\(/);
  assert.match(proxy, /private, no-store/);
  assert.match(entry, /export async function proxy/);
  assert.match(entry, /sw\.js\|manifest\.webmanifest\|offline\.html/);
});

test("AppAuthProvider uses verified startup, resume checks, offline shield and local logout", async () => {
  const provider = await readFile(new URL("../components/AppAuthProvider.tsx", import.meta.url), "utf8");
  assert.match(provider, /supabase\.auth\.getUser\(\)/);
  assert.doesNotMatch(provider, /supabase\.auth\.getSession\(\)/);
  assert.match(provider, /authEventAction\(event\)/);
  assert.match(provider, /clearProtectedContext\(\)/);
  assert.match(provider, /isAuthVerificationCurrent/);
  const scheduleOffset = provider.indexOf("const scheduleVerification = () =>");
  const deferredOffset = provider.indexOf("window.setTimeout", scheduleOffset);
  assert.ok(scheduleOffset >= 0 && deferredOffset > scheduleOffset);
  assert.ok(provider.indexOf("invalidateAuthVerification(verificationGateRef.current)", scheduleOffset) < deferredOffset);
  assert.ok(provider.indexOf("setLoading(true)", scheduleOffset) < deferredOffset);
  assert.ok(provider.indexOf("clearProtectedContext()", scheduleOffset) < deferredOffset);
  assert.match(provider, /clearWorkspaceContext\(\)[\s\S]*matrix_v2_ensure_first_run_uat_v1/u);
  assert.match(provider, /visibilitychange/);
  assert.match(provider, /pageshow/);
  assert.match(provider, /window\.addEventListener\("offline"/);
  assert.match(provider, /window\.addEventListener\("online"/);
  assert.match(provider, /const \[offline, setOffline\] = useState\(false\)/);
  assert.match(provider, /browserIsOffline\(window\)/);
  assert.doesNotMatch(provider, /useState\(\(\) => typeof navigator/);
  assert.match(provider, /signOut\(\{ scope: "local" \}\)/);
  assert.match(provider, /clearProtectedBrowserState/);
  assert.match(provider, /window\.location\.replace\("\/"\)/);
  assert.match(provider, /Dane firmowe są bezpiecznie ukryte/);
  assert.match(provider, /Nie pokazujemy panelu bez aktualnych uprawnień/);
  assert.match(provider, /!summary \|\| !companyTimezone \|\| !currentCompanyMonth/);
  assert.match(provider, /Potwierdzamy dane firmy i właściwy miesiąc/);
  assert.match(provider, /role_logical_id\?: string \| null/);
  assert.match(provider, /location_logical_id\?: string \| null/);
  const contextGuard = provider.indexOf("!summary || !companyTimezone || !currentCompanyMonth");
  assert.ok(contextGuard > provider.indexOf('workspaceIssue === "TIMEZONE_CONFIGURATION_FAILED"'));
  assert.ok(contextGuard > provider.indexOf('workspaceIssue === "WORKSPACE_LOAD_FAILED"'));
  assert.ok(contextGuard > provider.indexOf("if (sessionCheckError)"));
  assert.ok(contextGuard < provider.indexOf("<AuthContext.Provider value={value}>", contextGuard));
});

test("service worker never stores auth, API, navigation or Supabase responses", async () => {
  const worker = await readFile(new URL("../public/sw.js", import.meta.url), "utf8");
  assert.match(worker, /pathname === "\/api" \|\| url\.pathname\.startsWith\("\/api\/"\)/);
  assert.match(worker, /pathname === "\/auth" \|\| url\.pathname\.startsWith\("\/auth\/"\)/);
  assert.match(worker, /request\.mode === "navigate"/);
  assert.match(worker, /url\.origin !== self\.location\.origin/);
  assert.doesNotMatch(worker, /supabase/i);
});

test("SSR dependency is pinned to the audited session-race fix line", async () => {
  const packageJson = JSON.parse(await readFile(new URL("../package.json", import.meta.url), "utf8"));
  const lock = JSON.parse(await readFile(new URL("../package-lock.json", import.meta.url), "utf8"));
  assert.equal(packageJson.dependencies["@supabase/ssr"], "0.12.4");
  assert.equal(lock.packages["node_modules/@supabase/ssr"].version, "0.12.4");
});

test("auth callback responses are private and never cache a refreshed session", async () => {
  const callback = await readFile(new URL("../app/auth/callback/route.ts", import.meta.url), "utf8");
  assert.match(callback, /exchangeCodeForSession/);
  assert.match(callback, /private, no-store/);
  assert.match(callback, /Pragma/);
  assert.match(callback, /Expires/);
});
