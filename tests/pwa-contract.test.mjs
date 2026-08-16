import assert from "node:assert/strict";
import { readFileSync, statSync } from "node:fs";
import test from "node:test";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

test("manifest exposes an installable standalone GRAFIK PRO application", () => {
  const manifest = read("app/manifest.ts");
  assert.match(manifest, /name:\s*"GRAFIK PRO"/);
  assert.match(manifest, /display:\s*"standalone"/);
  assert.match(manifest, /start_url:\s*"\/\?source=pwa"/);
  assert.match(manifest, /grafik-pro-192\.png/);
  assert.match(manifest, /grafik-pro-512\.png/);
  assert.match(manifest, /purpose:\s*"maskable"/);
});

test("root metadata supports mobile safe areas and Apple installation", () => {
  const layout = read("app/layout.tsx");
  assert.match(layout, /manifest:\s*"\/manifest\.webmanifest"/);
  assert.match(layout, /appleWebApp/);
  assert.match(layout, /viewportFit:\s*"cover"/);
  assert.match(layout, /<PwaInstall \/>/);
});

test("service worker never caches application APIs or authenticated pages", () => {
  const worker = read("public/sw.js");
  assert.match(worker, /pathname\.startsWith\("\/api\/"\)/);
  assert.match(worker, /pathname\.startsWith\("\/auth\/"\)/);
  assert.match(worker, /request\.mode === "navigate"/);
  assert.match(worker, /caches\.match\("\/offline"\)/);
  assert.doesNotMatch(worker, /cache\.put\(request[^\n]+navigate/);
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
    "public/icons/grafik-pro-192.png",
    "public/icons/grafik-pro-512.png",
    "public/icons/grafik-pro-maskable-512.png",
    "public/icons/apple-touch-icon.png",
  ]) {
    assert.ok(statSync(new URL(`../${path}`, import.meta.url)).size > 1_000, `${path} is missing or empty`);
  }
});
