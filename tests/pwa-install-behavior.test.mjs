import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  PWA_INSTALL_AUTO_COOLDOWN_MS,
  PWA_INSTALL_DISMISS_COOLDOWN_MS,
  isIosSafariUserAgent,
  rememberInstallSuggestionDismissed,
  rememberInstallSuggestionShown,
  shouldAutomaticallyOfferInstall,
} from "../lib/pwa-install.ts";

class MemoryStorage {
  values = new Map();
  getItem(key) { return this.values.get(key) ?? null; }
  setItem(key, value) { this.values.set(key, String(value)); }
}

test("iOS installation help is limited to Safari, including iPadOS desktop UA", () => {
  assert.equal(isIosSafariUserAgent("Mozilla/5.0 (iPhone) AppleWebKit/605.1.15 Version/17.0 Mobile Safari/604.1"), true);
  assert.equal(isIosSafariUserAgent("Mozilla/5.0 (iPhone) AppleWebKit/605.1.15 CriOS/125.0 Mobile Safari/604.1"), false);
  assert.equal(isIosSafariUserAgent("Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15", 5), true);
  assert.equal(isIosSafariUserAgent("Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15", 0), false);
});

test("automatic install invitation has a 30-day display cooldown", () => {
  const storage = new MemoryStorage();
  const now = 1_800_000_000_000;
  assert.equal(shouldAutomaticallyOfferInstall(storage, now), true);
  assert.equal(rememberInstallSuggestionShown(storage, now), true);
  assert.equal(shouldAutomaticallyOfferInstall(storage, now + PWA_INSTALL_AUTO_COOLDOWN_MS - 1), false);
  assert.equal(shouldAutomaticallyOfferInstall(storage, now + PWA_INSTALL_AUTO_COOLDOWN_MS), true);
});

test("dismissal suppresses the invitation for 90 days and storage failures fail quietly", () => {
  const storage = new MemoryStorage();
  const now = 1_800_000_000_000;
  assert.equal(rememberInstallSuggestionDismissed(storage, now), true);
  assert.equal(shouldAutomaticallyOfferInstall(storage, now + PWA_INSTALL_DISMISS_COOLDOWN_MS - 1), false);
  assert.equal(shouldAutomaticallyOfferInstall(storage, now + PWA_INSTALL_DISMISS_COOLDOWN_MS), true);

  const unavailable = { getItem() { throw new Error("blocked"); }, setItem() { throw new Error("blocked"); } };
  assert.equal(shouldAutomaticallyOfferInstall(unavailable, now), false);
  assert.equal(rememberInstallSuggestionShown(unavailable, now), false);
  assert.equal(rememberInstallSuggestionDismissed(unavailable, now), false);
});

test("component registers a versioned worker without forced takeover and reuses one update surface", () => {
  const component = readFileSync(new URL("../components/PwaInstall.tsx", import.meta.url), "utf8");
  assert.match(component, /register\(`\/sw\.js\?v=\$\{buildId\}`/);
  assert.match(component, /updateViaCache:\s*"none"/);
  assert.match(component, /waitingWorker\.postMessage\(\{ type: "SKIP_WAITING" \}\)/);
  assert.match(component, /if \(reloadRequested\.current\) window\.location\.reload\(\)/);
  assert.match(component, /12_000/);
  assert.doesNotMatch(component, /window\.location\.reload\(\);[\s\S]*onInstalled/);
});
