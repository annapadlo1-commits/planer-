import assert from "node:assert/strict";
import { readFileSync, statSync } from "node:fs";
import test from "node:test";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

test("manifest exposes an installable standalone SZAFUNEK application", () => {
  const manifest = read("app/manifest.ts");
  assert.match(manifest, /name:\s*"SZAFUNEK"/);
  assert.match(manifest, /display:\s*"standalone"/);
  assert.match(manifest, /start_url:\s*"\/"/);
  assert.match(manifest, /scope:\s*"\/"/);
  assert.match(manifest, /orientation:\s*"any"/);
  assert.match(manifest, /prefer_related_applications:\s*false/);
  assert.match(manifest, /szafunek-192\.png/);
  assert.match(manifest, /szafunek-512\.png/);
  assert.match(manifest, /purpose:\s*"maskable"/);
});

test("root metadata supports mobile safe areas and Apple installation", () => {
  const layout = read("app/layout.tsx");
  assert.match(layout, /manifest:\s*"\/manifest\.webmanifest"/);
  assert.match(layout, /appleWebApp/);
  assert.match(layout, /"apple-mobile-web-app-capable":\s*"yes"/);
  assert.match(layout, /viewportFit:\s*"cover"/);
  assert.match(layout, /<PwaInstall \/>/);
});

test("service worker never caches application APIs or authenticated pages", () => {
  const worker = read("public/sw.js");
  assert.match(worker, /pathname\.startsWith\("\/api\/"\)/);
  assert.match(worker, /pathname\.startsWith\("\/auth\/"\)/);
  assert.match(worker, /url\.searchParams\.has\("_rsc"\)/);
  assert.match(worker, /Next-Router-State-Tree/);
  assert.match(worker, /request\.mode === "navigate"/);
  assert.match(worker, /OFFLINE_URL = "\/offline\.html"/);
  assert.doesNotMatch(worker, /cache\.put\(request[^\n]+navigate/);
  assert.match(worker, /event\.data\?\.type === "SKIP_WAITING"/);
});

test("service worker and manifest receive update-safe response headers", () => {
  const config = read("next.config.ts");
  assert.match(config, /source:\s*"\/sw\.js"/);
  assert.match(config, /no-cache, no-store, must-revalidate/);
  assert.match(config, /Service-Worker-Allowed/);
  assert.match(config, /X-Content-Type-Options/);
  assert.match(config, /NEXT_PUBLIC_APP_BUILD_ID/);
});

test("offline fallback is self-contained and never displays cached business data", () => {
  const offline = read("public/offline.html");
  assert.match(offline, /Brak połączenia z internetem/);
  assert.match(offline, /nie są przechowywane offline/);
  assert.doesNotMatch(offline, /<script/i);
});

test("mobile navigation is operable and no longer hidden", () => {
  const page = read("app/page.tsx");
  const css = read("app/product-journey.css");
  assert.match(page, /mobileNavigationOpen/);
  assert.match(page, /aria-controls="product-navigation"/);
  assert.match(page, /product-navigation-scrim/);
  assert.doesNotMatch(css, /product-sidebar\{display:none/);
  assert.match(css, /product-sidebar\{display:flex/);
});

test("required PNG icons exist and are non-empty", () => {
  for (const path of [
    "public/icons/szafunek-192.png",
    "public/icons/szafunek-512.png",
    "public/icons/szafunek-maskable-512.png",
    "public/icons/apple-touch-icon.png",
  ]) {
    assert.ok(statSync(new URL(`../${path}`, import.meta.url)).size > 1_000, `${path} is missing or empty`);
  }
});
