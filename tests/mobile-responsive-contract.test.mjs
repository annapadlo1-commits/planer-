import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const layout = await readFile(new URL("../app/layout.tsx", import.meta.url), "utf8");
const css = await readFile(new URL("../app/mobile-hardening.css", import.meta.url), "utf8");

test("mobilna warstwa ochronna jest importowana po wszystkich warstwach produktu", () => {
  const mobileIndex = layout.indexOf('import "./mobile-hardening.css"');
  assert.ok(mobileIndex > layout.indexOf('import "./cat-games.css"'));
  assert.equal(layout.slice(mobileIndex + 1).includes('import "./'), false);
});

test("iOS PWA zachowuje safe area i dotykalny przycisk menu", () => {
  assert.match(css, /@media \(display-mode: standalone\) and \(max-width: 760px\)/);
  assert.match(css, /calc\(8px \+ env\(safe-area-inset-top\)\)/);
  assert.match(css, /\.product-shell \.menu-button,[\s\S]*min-height: 44px/);
  assert.match(css, /width: min\(320px, 100vw\) !important/);
});

test("logowanie nie uruchamia automatycznego zoomu i mieści się w viewport", () => {
  assert.match(css, /\.login-page \{[\s\S]*min-height: 100dvh !important/);
  assert.match(css, /\.login-card input,[\s\S]*font-size: 16px !important/);
  assert.match(css, /\.login-card,[\s\S]*max-width: 100% !important/);
});

test("profil pracownika może się zwężać bez poziomego overflow", () => {
  assert.match(css, /\.personal-workspace > \*/);
  assert.match(css, /\.personal-workspace-hero > span:not\(\.personal-avatar\)/);
  assert.match(css, /overflow-wrap: anywhere/);
  assert.match(css, /@media \(max-width: 420px\)[\s\S]*\.personal-workspace-hero/);
});

test("grafik firmy jest czytelną pionową listą tygodnia na telefonie", () => {
  assert.match(css, /\.company-week-row \{[\s\S]*min-width: 0 !important/);
  assert.match(css, /\.company-week-row > div \{[\s\S]*grid-template-columns: 1fr !important/);
  assert.match(css, /\.company-week-day\.blank \{[\s\S]*display: none/);
});

test("pełnoekranowe drawery uwzględniają notch i dolny pasek systemowy", () => {
  assert.match(css, /\.drawer > \.drawer-head,[\s\S]*env\(safe-area-inset-top\)/);
  assert.match(css, /\.drawer > \.drawer-content,[\s\S]*env\(safe-area-inset-bottom\)/);
  assert.match(css, /height: calc\(100dvh - 64px - env\(safe-area-inset-top\)\) !important/);
});

test("Studio lidera ma bezpieczny nagłówek i własny scroll puli pracowników", () => {
  assert.match(css, /\.leader-studio-fullscreen \{[\s\S]*env\(safe-area-inset-top\)/);
  assert.match(css, /\.leader-employee-pool > div \{[\s\S]*max-height: min\(40dvh, 320px\) !important/);
  assert.match(css, /@media \(max-width: 420px\)[\s\S]*\.leader-employee-pool > div[\s\S]*grid-template-columns: 1fr !important/);
});

test("szerokie tabele przewijają się lokalnie zamiast rozszerzać dokument", () => {
  assert.match(css, /\.matrix-v2-table,[\s\S]*\.solver-issues-view[\s\S]*overflow-x: auto !important/);
  assert.match(css, /html,[\s\S]*body[\s\S]*overflow-x: clip/);
});
