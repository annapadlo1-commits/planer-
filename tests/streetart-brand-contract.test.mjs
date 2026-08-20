import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, statSync } from "node:fs";
import test from "node:test";

const fileUrl = path => new URL(`../${path}`, import.meta.url);
const read = path => readFileSync(fileUrl(path), "utf8");
const sha256 = path => createHash("sha256").update(readFileSync(fileUrl(path))).digest("hex");

test("login uses the transparent streetart lockup and the approved copy", () => {
  const auth = read("components/AppAuthProvider.tsx");
  assert.match(auth, /\/brand\/szafunek-lockup-transparent\.png/);
  assert.match(auth, /\/icons\/szafunek-192\.png/);
  assert.match(auth, />PIZZAIOLO</);
  assert.match(auth, />OGARNIJ ZMIANY</);
  assert.doesNotMatch(auth, /HIDE\. COLLECT\. KEEP YOURS\./i);
  assert.doesNotMatch(auth, /SZANUJ SWÓJ CZAS|SZANUJ ZESPÓŁ/i);
  assert.doesNotMatch(auth, /primary_logo_lockup|cat-symbol-exact/i);
});

test("brand boards and mockups are never used as application assets", () => {
  const css = read("app/brand-streetart.css");
  const page = read("app/page.tsx");
  assert.doesNotMatch(css, /url\([^)]*(reference|mockup|board|desktop_ui|login_screen)/i);
  assert.doesNotMatch(page, /reference-approved|primary_logo_lockup|cat-symbol-exact/i);
  assert.match(css, /--brand-graphite:#1f2a27/i);
  assert.match(css, /--brand-cream:#f6f4ef/i);
  assert.match(css, /--brand-sage:#a6b8a9/i);
  assert.match(css, /--brand-eucalyptus:#dde6de/i);
  assert.match(css, /--brand-peach:#f6c8b6/i);
});

test("streetart character is implemented as a reusable UI layer, not a palette swap", () => {
  const css = read("app/brand-streetart.css");
  assert.match(css, /SZAFUNEK street-poster layer/);
  assert.match(css, /\.product-shell \.product-sidebar::after/);
  assert.match(css, /\.product-shell \.product-sidebar \.brand::before/);
  assert.match(css, /\.product-shell \.product-sidebar nav button\.active::after/);
  assert.match(css, /\.product-shell \.topbar::after/);
  assert.match(css, /\.configuration-next-action\s*\{[^}]*var\(--brand-peach\)/s);
  assert.match(css, /\.schedule-role-first-intro::before/);
  assert.match(css, /\.matrix-v2-summary svg\s*\{[^}]*var\(--brand-ink\)/s);
  assert.match(css, /\.analytics-empty::before\s*\{[^}]*\/icons\/szafunek-192\.png/s);
  assert.match(css, /\.pwa-install\s*\{[^}]*var\(--brand-ink\)/s);
  assert.match(css, /clip-path:/);
});

test("final visual corrections cover short sidebars, login and deep management views", () => {
  const css = read("app/brand-streetart.css");
  assert.match(css, /\.product-shell \.product-sidebar\s*\{[^}]*height:100dvh[^}]*overflow:hidden!important/s);
  assert.match(css, /\.product-shell \.product-sidebar nav\s*\{[^}]*flex:1 1 0!important[^}]*height:0[^}]*overflow-y:scroll!important[^}]*scrollbar-width:auto!important/s);
  assert.match(css, /\.product-shell \.product-sidebar nav::\-webkit-scrollbar\s*\{[^}]*display:block!important[^}]*width:10px!important/s);
  assert.match(css, /\.product-shell \.product-sidebar \.sidebar-footer\s*\{[^}]*flex:0 0 auto/s);
  assert.match(css, /\.login-brand-signature\s*\{[^}]*padding:0!important[^}]*background:transparent!important[^}]*clip-path:none!important/s);
  assert.match(css, /\.login-brand-signature::before\s*\{[^}]*display:none!important/s);
  assert.match(css, /\.login-brand h1\s*\{[^}]*font-size:clamp\(36px,4vw,64px\)!important/s);
  assert.match(css, /\.solver-manual-studio-entry>span\s*\{[^}]*var\(--brand-ink\)!important/s);
  assert.match(css, /\.availability-daily-summary>summary svg[\s\S]*var\(--brand-ink\)!important/);
  assert.match(css, /\.leader-studio-fullscreen\s*\{[^}]*--violet:var\(--brand-ink\)/s);
  assert.match(css, /\.matrix-v2-shell\s*\{[^}]*--violet:var\(--brand-ink\)/s);
  assert.match(css, /\.analytics-head\s*\{[^}]*var\(--brand-ink\)!important/s);
});

test("mobile opens as one compact login and reuses the approved people, shifts and message language", () => {
  const css = read("app/brand-streetart.css");
  assert.match(css, /Mobile product language from the approved scheduling board/);
  assert.match(css, /@media\(max-width:760px\)[\s\S]*\.login-page\s*\{[^}]*flex-direction:column[^}]*min-height:100dvh/s);
  assert.match(css, /\.login-brand h1\s*\{display:none!important\}/);
  assert.match(css, /\.login-brand-signature\s*\{[^}]*width:min\(330px,88vw\)!important/s);
  assert.match(css, /\.pwa-install\s*\{[^}]*grid-template-columns:44px minmax\(0,1fr\) 38px!important/s);
  assert.match(css, /\.workforce-catalog-list>article\s*\{[^}]*grid-template-columns:44px minmax\(0,1fr\) 42px!important/s);
  assert.match(css, /\.message-avatar\s*\{[^}]*border-radius:50%!important[^}]*var\(--brand-sage\)!important/s);
  assert.match(css, /\.employee-portal-callouts\s*\{display:none!important\}/);
  assert.match(css, /\.portal-profile\s*\{[^}]*grid-template-columns:48px 1fr!important/s);
});

test("role checkbox filters use one compact dropdown instead of permanent fieldsets", () => {
  const dropdown = read("components/CheckboxDropdown.tsx");
  const solver = read("components/SolverV2Workspace.tsx");
  const matrix = read("components/MatrixV2Editor.tsx");
  const operations = read("components/ActiveModules.tsx");
  const css = read("app/brand-streetart.css");
  assert.match(dropdown, /<details className={`checkbox-dropdown/);
  assert.match(dropdown, /<fieldset>/);
  assert.match(solver, /<CheckboxDropdown label="Role"/);
  assert.match(matrix, /<CheckboxDropdown className="matrix-v2-role-filter" label="Role"/);
  assert.match(matrix, /<CheckboxDropdown label="Role obsługiwane wspólnie"/);
  assert.match(operations, /<CheckboxDropdown label="Role"/);
  assert.doesNotMatch(solver, /<fieldset><legend>Role<\/legend>/);
  assert.doesNotMatch(matrix, /matrix-v2-role-filter"><legend>Role<\/legend>/);
  assert.doesNotMatch(operations, /<fieldset><legend>Role<\/legend>/);
  assert.match(css, /\.checkbox-dropdown>summary\s*\{[^}]*min-height:48px/s);
  assert.match(css, /\.checkbox-dropdown>fieldset\s*\{[^}]*max-height:260px!important/s);
});

test("operations and mobile Leader Studio use the street-poster system without lavender controls", () => {
  const css = read("app/brand-streetart.css");
  assert.match(css, /\.recovery-tabs\s*\{[^}]*var\(--brand-ink\)!important/s);
  assert.match(css, /\.uat-master-persona-panel\s*\{[^}]*border:2px solid var\(--brand-ink\)!important/s);
  assert.match(css, /\.leader-assistant-tool\s*\{[^}]*var\(--brand-paper\)!important/s);
  assert.match(css, /@media\(max-width:760px\)[\s\S]*\.leader-studio-fullscreen-head\s*\{[^}]*grid-template-columns:minmax\(0,1fr\)!important/s);
  assert.match(css, /\.leader-studio-history-actions\s*\{[^}]*grid-template-columns:repeat\(3,40px\) minmax\(80px,1fr\) 40px!important/s);
  assert.match(css, /\.leader-studio>\.solver-workspace-summary\s*\{[^}]*grid-template-columns:repeat\(3,minmax\(0,1fr\)\)!important/s);
  assert.match(css, /\.leader-studio>\.solver-workspace-tabs\s*\{[^}]*grid-template-columns:repeat\(3,minmax\(155px,1fr\)\)!important/s);
  assert.match(css, /\.configuration-next-icon svg\s*\{[^}]*var\(--brand-paper\)!important/s);
  assert.match(css, /\.solver-v2-heading\s*\{[^}]*border:2px solid var\(--brand-ink\)!important[^}]*background:var\(--brand-eucalyptus\)!important/s);
  assert.match(css, /\.solver-v2-progress i\s*\{[^}]*background:var\(--brand-ink\)!important/s);
  assert.match(css, /@media\(max-width:760px\)[\s\S]*\.solver-v2-actions\s*\{[^}]*grid-template-columns:1fr 1fr!important/s);
  assert.match(css, /\.solver-manual-studio-entry>span\s*\{[^}]*display:grid!important[^}]*width:34px!important/s);
  assert.match(css, /\.solver-workspace:not\(\.leader-studio\)\s*\{[^}]*border:1\.5px solid var\(--brand-ink\)!important[^}]*background:var\(--brand-paper\)!important/s);
  assert.match(css, /\.solver-workspace:not\(\.leader-studio\)>\.solver-workspace-tabs button\.active\s*\{[^}]*background:var\(--brand-paper\)!important/s);
  assert.match(css, /section\.live-module:has\(>\.real-month\)\s*\{[^}]*border:1\.5px solid var\(--brand-ink\)!important[^}]*background:var\(--brand-paper\)!important/s);
  assert.match(css, /\.message-thread-placeholder>svg\s*\{[^}]*color:var\(--brand-paper\)!important[^}]*background:var\(--brand-ink\)!important/s);
  assert.match(css, /\.employee-combined-calendar,\s*\.employee-day-workspace\s*\{[^}]*border:1\.5px solid var\(--brand-ink\)!important/s);
  assert.match(css, /\.availability-state-calendar button\.selected\s*\{[^}]*outline:2px solid var\(--brand-ink\)!important/s);
  assert.match(css, /\.matrix-v2-drawer \.matrix-import-mode button\.active\s*\{[^}]*background:var\(--brand-eucalyptus\)!important/s);
  assert.match(css, /\.matrix-v2-drawer \.matrix-import-trust\s*\{[^}]*border:1\.5px solid var\(--brand-ink\)!important[^}]*background:var\(--brand-eucalyptus\)!important/s);
});

test("deep schedule, generator and configuration views do not fall back to lavender SaaS cards", () => {
  const css = read("app/brand-streetart.css");
  assert.match(css, /\.solver-workspace \.solver-schedule-perspectives button\.active\s*\{[^}]*background:var\(--brand-paper\)!important/s);
  assert.match(css, /\.solver-workspace \.solver-workload-summary>span\s*\{[^}]*border:1px solid var\(--brand-ink\)!important[^}]*background:var\(--brand-paper-2\)!important/s);
  assert.match(css, /\.solver-workspace \.solver-standby-days>article\s*\{[^}]*border:1\.5px solid var\(--brand-ink\)!important/s);
  assert.match(css, /\.operational-additional-tools\s*\{[^}]*border:1\.5px solid var\(--brand-ink\)!important[^}]*background:var\(--brand-paper\)!important/s);
  assert.match(css, /\.live-overview\s*\{[^}]*border:1\.5px solid var\(--brand-ink\)!important[^}]*background:var\(--brand-paper\)!important/s);
  assert.match(css, /\.generator-v2-scenarios,\s*\.generator-v2-catalog\s*\{[^}]*border:1\.5px solid var\(--brand-ink\)!important/s);
  assert.match(css, /\.matrix-v2-workforce \.workforce-profile-readiness\s*\{[^}]*background:var\(--brand-eucalyptus\)!important/s);
  assert.match(css, /\.matrix-v2-finance-banner\s*\{[^}]*background:var\(--brand-eucalyptus\)!important/s);
  assert.match(css, /\.finance-access-policy\s*\{[^}]*border:1\.5px solid var\(--brand-ink\)!important[^}]*background:var\(--brand-paper-2\)!important/s);
});

test("employee swaps and message counters use the street-poster notification language", () => {
  const css = read("app/brand-streetart.css");
  assert.match(css, /\.employee-recovery-offers\s*\{[^}]*border:1\.5px solid var\(--brand-ink\)!important[^}]*background:var\(--brand-paper\)!important/s);
  assert.match(css, /\.employee-recovery-offers>header>svg\s*\{[^}]*color:var\(--brand-ink\)!important[^}]*background:var\(--brand-peach\)!important/s);
  assert.match(css, /\.employee-recovery-offers \.recovery-empty\s*\{[^}]*border:1\.5px solid var\(--brand-ink\)!important/s);
  assert.match(css, /\.message-center \.conversation-list>button>i\s*\{[^}]*color:var\(--brand-ink\)!important[^}]*background:var\(--brand-peach\)!important/s);
  assert.match(css, /\.employee-day-shifts>article,\s*\.employee-day-team\s*\{[^}]*border:1\.5px solid var\(--brand-ink\)!important/s);
  assert.match(css, /\.complete-drawer\s*\{[^}]*--violet:var\(--brand-ink\)[^}]*background:var\(--brand-paper\)!important/s);
  assert.match(css, /\.swap-request-form\s*\{[^}]*border:1\.5px solid var\(--brand-ink\)!important[^}]*background:var\(--brand-paper-2\)!important/s);
  assert.match(css, /\.swap-candidate-list>button\.active\s*\{[^}]*background:var\(--brand-peach\)!important/s);
});

test("approved small application icon is copied byte-for-byte to every small surface", () => {
  const expected = {
    "public/favicon.ico": "fa6a461cc8b20c8a49eae3bbf270e43e10d2d494b756cbbc8c5c41f2d55b25d2",
    "public/icons/favicon-16.png": "d50592d94eb2aa64e9f359ec8b0f9c5e72f2fa7ed9c88a73639321b66a1e78d2",
    "public/icons/favicon-32.png": "ce9ca82eb1edd970947917aa2ce7859415567cad18b31d67513d085beaf2bd8e",
    "public/icons/favicon-48.png": "7224e758a4a0cf98a028b64a8230e6e0438f58d79543d854b8e0c171d44755aa",
    "public/icons/favicon-64.png": "816a4849c500e970c2b0559ccf0b64ba35131fae4800f55e517983424de8b56d",
    "public/icons/apple-touch-icon.png": "60a448e296c75ed7f71494d3983dd2b48fe92f20ce1549a3e753efa74c721b15",
    "public/icons/szafunek-192.png": "57f7d72eaba17aea0581d0b59a67b71d7e198e46dcb9b10c64144532f9a125a7",
    "public/icons/szafunek-512.png": "cd976b93d65cca46a57ef34a2dff4d40fdae349c14fcfd8b51af0af2a5f50cf5",
    "public/icons/szafunek-maskable-512.png": "cd976b93d65cca46a57ef34a2dff4d40fdae349c14fcfd8b51af0af2a5f50cf5",
    "public/icons/szafunek-app-icon-master.png": "aa29ba98966db41c9d8e6593448ce0a47d681a39fe9e60ca8e436075e1d7d062",
  };
  for (const [path, digest] of Object.entries(expected)) {
    assert.ok(statSync(fileUrl(path)).size > 100, `${path} is missing`);
    assert.equal(sha256(path), digest, `${path} is not the approved supplied raster`);
  }
});

test("PWA prompt, offline page and manifest use the separate application icon", () => {
  const pwa = read("components/PwaInstall.tsx");
  const offline = read("app/offline/page.tsx");
  const manifest = read("app/manifest.ts");
  assert.match(pwa, /\/icons\/szafunek-192\.png/);
  assert.match(offline, /\/icons\/szafunek-192\.png/);
  assert.match(manifest, /\/icons\/szafunek-192\.png/);
  assert.match(manifest, /\/icons\/szafunek-512\.png/);
  assert.doesNotMatch(`${pwa}\n${offline}`, /cat-symbol-exact|primary_logo_lockup/i);
});

test("obsolete board crops are removed from the public application bundle", () => {
  for (const path of [
    "public/brand/reference-approved.jpg",
    "public/brand/primary_logo_lockup.png",
    "public/brand/cat-symbol-exact.png",
  ]) assert.equal(existsSync(fileUrl(path)), false, `${path} should not ship`);
  assert.ok(statSync(fileUrl("public/brand/szafunek-lockup-transparent.png")).size > 1000);
});

test("branding correction stays in the presentation layer", () => {
  const changedSurfaces = [
    "app/brand-streetart.css",
    "app/layout.tsx",
    "app/manifest.ts",
    "app/page.tsx",
    "components/AppAuthProvider.tsx",
    "components/PwaInstall.tsx",
    "app/offline/page.tsx",
  ];
  for (const path of changedSurfaces) {
    const source = read(path);
    assert.doesNotMatch(source, /solver_run|generate_schedule|saveLeaderAssignment|matrix_v2_publish/i);
  }
});
