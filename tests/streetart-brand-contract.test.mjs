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
  assert.match(css, /\.analytics-empty::before\s*\{[^}]*\/icons\/szafunek-192\.png/s);
  assert.match(css, /\.pwa-install\s*\{[^}]*var\(--brand-ink\)/s);
  assert.match(css, /clip-path:/);
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
