const BUILD_VERSION = new URL(self.location.href).searchParams.get("v") || "local";
const CACHE_PREFIX = "szafunek-static-";
const CACHE_VERSION = `${CACHE_PREFIX}${BUILD_VERSION}`;
const OFFLINE_URL = "/offline.html";
const SAFE_SHELL = [
  OFFLINE_URL,
  "/manifest.webmanifest",
  "/favicon.ico",
  "/icons/szafunek-192.png",
  "/icons/szafunek-512.png",
  "/icons/szafunek-maskable-512.png",
  "/icons/apple-touch-icon.png",
];

function isDynamicApplicationRequest(request, url) {
  if (url.pathname === "/api" || url.pathname.startsWith("/api/")) return true;
  if (url.pathname === "/auth" || url.pathname.startsWith("/auth/")) return true;
  if (url.pathname === "/sw.js" || url.searchParams.has("_rsc")) return true;
  if (request.headers.has("Range")) return true;
  if (request.headers.get("RSC") === "1") return true;
  if (request.headers.has("Next-Router-State-Tree") || request.headers.has("Next-Router-Prefetch")) return true;
  return false;
}

function isSafeStaticAsset(url) {
  return url.pathname.startsWith("/_next/static/")
    || url.pathname.startsWith("/icons/")
    || url.pathname === "/favicon.ico"
    || url.pathname === "/manifest.webmanifest";
}

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE_VERSION).then((cache) => cache.addAll(SAFE_SHELL)));
});

self.addEventListener("message", (event) => {
  if (event.data?.type === "SKIP_WAITING") void self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(
        keys
          .filter((key) => key.startsWith(CACHE_PREFIX) && key !== CACHE_VERSION)
          .map((key) => caches.delete(key)),
      ))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin || isDynamicApplicationRequest(request, url)) return;

  if (request.mode === "navigate") {
    event.respondWith(fetch(request).catch(async () => {
      const fallback = await caches.match(OFFLINE_URL);
      return fallback || Response.error();
    }));
    return;
  }

  if (!isSafeStaticAsset(url)) return;

  event.respondWith(
    caches.match(request).then((cached) => cached || fetch(request).then((response) => {
      if (response.ok && response.type !== "opaque") {
        const copy = response.clone();
        event.waitUntil(caches.open(CACHE_VERSION).then((cache) => cache.put(request, copy)));
      }
      return response;
    })),
  );
});
