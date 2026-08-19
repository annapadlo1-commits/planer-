import assert from "node:assert/strict";
import { readFileSync, statSync } from "node:fs";
import test from "node:test";

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

test("approved streetart rasters are used on primary visual surfaces", () => {
  const page = read("app/page.tsx");
  const auth = read("components/AppAuthProvider.tsx");
  const css = read("app/brand-streetart.css");
  assert.match(page, /\/brand\/primary_logo_lockup\.png/);
  assert.match(auth, /\/brand\/primary_logo_lockup\.png/);
  assert.match(auth, /\/brand\/cat-symbol-exact\.png/);
  assert.match(css, /#e8e1d6/i);
  assert.match(css, /#1a1a1a/i);
  assert.match(css, /#a6b3a0/i);
  assert.match(css, /#d9987e/i);
});

test("approved brand and install assets exist", () => {
  for (const path of [
    "public/brand/primary_logo_lockup.png",
    "public/brand/cat-symbol-exact.png",
    "public/brand/reference-approved.jpg",
    "public/favicon.ico",
    "public/icons/favicon-16.png",
    "public/icons/favicon-32.png",
    "public/icons/szafunek-192.png",
    "public/icons/szafunek-512.png",
    "public/icons/szafunek-maskable-512.png",
    "public/icons/apple-touch-icon.png",
  ]) assert.ok(statSync(new URL(`../${path}`, import.meta.url)).size > 100, `${path} is missing`);
});

test("streetart branding stays in the presentation layer", () => {
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
