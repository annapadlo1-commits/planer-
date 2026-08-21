import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const source = readFileSync(new URL("../public/sw.js", import.meta.url), "utf8");

function request(url, { method = "GET", mode = "cors", headers = {} } = {}) {
  return { url, method, mode, headers: new Headers(headers) };
}

function createHarness() {
  const listeners = new Map();
  const stores = new Map();
  const deletedCaches = [];
  const calls = { fetch: [], skipWaiting: 0, claim: 0 };
  let network = async (input) => new Response(`network:${typeof input === "string" ? input : input.url}`);

  const keyOf = (input) => typeof input === "string" ? input : input.url;
  const cacheFor = (name) => {
    if (!stores.has(name)) stores.set(name, new Map());
    const entries = stores.get(name);
    return {
      async addAll(urls) {
        for (const url of urls) entries.set(url, new Response(`precache:${url}`));
      },
      async match(input) {
        const value = entries.get(keyOf(input));
        return value?.clone();
      },
      async put(input, response) {
        entries.set(keyOf(input), response.clone());
      },
    };
  };
  const caches = {
    open: async (name) => cacheFor(name),
    match: async (input) => {
      for (const entries of stores.values()) {
        const value = entries.get(keyOf(input));
        if (value) return value.clone();
      }
      return undefined;
    },
    keys: async () => [...stores.keys()],
    delete: async (name) => {
      deletedCaches.push(name);
      return stores.delete(name);
    },
  };
  const self = {
    location: { href: "https://uat.szafunek.pl/sw.js?v=commit-123", origin: "https://uat.szafunek.pl" },
    addEventListener: (name, listener) => listeners.set(name, listener),
    skipWaiting: async () => { calls.skipWaiting += 1; },
    clients: { claim: async () => { calls.claim += 1; } },
  };
  vm.runInNewContext(source, {
    self,
    caches,
    URL,
    Response,
    Headers,
    Promise,
    fetch: async (input) => {
      calls.fetch.push(keyOf(input));
      return network(input);
    },
  });

  const lifecycle = async (name, payload = {}) => {
    let waiting;
    listeners.get(name)({ ...payload, waitUntil: (promise) => { waiting = Promise.resolve(promise); } });
    await waiting;
  };
  const fetchEvent = async (input) => {
    let responsePromise;
    const waiting = [];
    listeners.get("fetch")({
      request: input,
      respondWith: (promise) => { responsePromise = Promise.resolve(promise); },
      waitUntil: (promise) => waiting.push(Promise.resolve(promise)),
    });
    const response = responsePromise ? await responsePromise : undefined;
    await Promise.all(waiting);
    return response;
  };

  return {
    listeners,
    stores,
    deletedCaches,
    calls,
    lifecycle,
    fetchEvent,
    setNetwork(next) { network = next; },
  };
}

test("installation precaches only the public shell and never forces activation", async () => {
  const harness = createHarness();
  await harness.lifecycle("install");
  assert.equal(harness.calls.skipWaiting, 0);
  const cache = harness.stores.get("szafunek-static-commit-123");
  assert.ok(cache.has("/offline.html"));
  assert.ok(cache.has("/manifest.webmanifest"));
  assert.equal([...cache.keys()].some((key) => key.startsWith("/api/")), false);
});

test("new worker activates only after an explicit SKIP_WAITING message", async () => {
  const harness = createHarness();
  await harness.listeners.get("message")({ data: { type: "OTHER" } });
  assert.equal(harness.calls.skipWaiting, 0);
  await harness.listeners.get("message")({ data: { type: "SKIP_WAITING" } });
  assert.equal(harness.calls.skipWaiting, 1);
});

test("activation deletes only older SZAFUNEK caches and claims clients", async () => {
  const harness = createHarness();
  harness.stores.set("szafunek-static-old", new Map());
  harness.stores.set("unrelated-cache", new Map());
  await harness.lifecycle("activate");
  assert.deepEqual(harness.deletedCaches, ["szafunek-static-old"]);
  assert.equal(harness.stores.has("unrelated-cache"), true);
  assert.equal(harness.calls.claim, 1);
});

test("navigation is always fetched fresh and only a network failure uses offline HTML", async () => {
  const harness = createHarness();
  await harness.lifecycle("install");
  const fresh = await harness.fetchEvent(request("https://uat.szafunek.pl/pracownik/grafik", { mode: "navigate" }));
  assert.equal(await fresh.text(), "network:https://uat.szafunek.pl/pracownik/grafik");

  harness.setNetwork(async () => { throw new Error("offline"); });
  const fallback = await harness.fetchEvent(request("https://uat.szafunek.pl/pracownik/grafik", { mode: "navigate" }));
  assert.equal(await fallback.text(), "precache:/offline.html");
});

test("API, auth, RSC, cross-origin and non-GET requests are never intercepted", async () => {
  const harness = createHarness();
  for (const input of [
    request("https://uat.szafunek.pl/api/profile", { mode: "navigate" }),
    request("https://uat.szafunek.pl/auth/callback", { mode: "navigate" }),
    request("https://uat.szafunek.pl/?_rsc=abc"),
    request("https://uat.szafunek.pl/", { headers: { RSC: "1" } }),
    request("https://uat.szafunek.pl/_next/static/media/font.woff2", { headers: { Range: "bytes=0-99" } }),
    request("https://nhthrtpkfpmufmrmdyjg.supabase.co/rest/v1/data"),
    request("https://uat.szafunek.pl/api/profile", { method: "POST" }),
  ]) {
    assert.equal(await harness.fetchEvent(input), undefined, input.url);
  }
  assert.equal(harness.calls.fetch.length, 0);
});

test("hashed static assets use cache-first without expanding cache scope", async () => {
  const harness = createHarness();
  await harness.lifecycle("install");
  const asset = request("https://uat.szafunek.pl/_next/static/chunks/app-123.js");
  const first = await harness.fetchEvent(asset);
  assert.equal(await first.text(), "network:https://uat.szafunek.pl/_next/static/chunks/app-123.js");
  harness.setNetwork(async () => { throw new Error("offline"); });
  const cached = await harness.fetchEvent(asset);
  assert.equal(await cached.text(), "network:https://uat.szafunek.pl/_next/static/chunks/app-123.js");
  assert.equal(await harness.fetchEvent(request("https://uat.szafunek.pl/company/private.json")), undefined);
});
