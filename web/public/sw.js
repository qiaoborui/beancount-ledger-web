const CACHE_NAME = "beancount-ledger-shell-v8";
const API_CACHE_NAME = "beancount-ledger-api-v2";
const APP_SHELL = "/";
const APP_STATIC_ASSETS = [APP_SHELL, "/manifest.webmanifest", "/icons/icon-192.svg", "/icons/icon-512.svg"];
const STATIC_CACHE_MAX_ENTRIES = 96;
// Only cache read-only API responses that do not vary by sensitive unlock state.
// Summary, transactions, and income-statement intentionally stay network-only here because
// the server returns different payloads before/after Face ID / Passkey unlock. Caching them
// in the service worker can leak unlocked data after the app locks again.
const STALE_WHILE_REVALIDATE_API_PATHS = new Set([
  "/api/ledger/accounts",
  "/api/ledger/version",
]);

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_STATIC_ASSETS)));
});

self.addEventListener("message", (event) => {
  if (event.data?.type === "SKIP_WAITING") self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  const keep = new Set([CACHE_NAME, API_CACHE_NAME]);
  event.waitUntil(
    Promise.all([
      self.registration.navigationPreload ? self.registration.navigationPreload.enable() : Promise.resolve(),
      caches.keys().then((keys) => Promise.all(keys.filter((key) => !keep.has(key)).map((key) => caches.delete(key)))),
    ]).then(() => self.clients.claim()),
  );
});

self.addEventListener("push", (event) => {
  const fallback = { title: "我的账本", body: "你有一条新的账本通知。", url: "/", tag: "ledger" };
  const data = (() => {
    try {
      return event.data ? { ...fallback, ...event.data.json() } : fallback;
    } catch {
      return fallback;
    }
  })();

  event.waitUntil(self.registration.showNotification(data.title, {
    body: data.body,
    tag: data.tag,
    icon: "/icons/icon-192.svg",
    badge: "/icons/icon-192.svg",
    data: { url: data.url || "/" },
  }));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = new URL(event.notification.data?.url || "/", self.location.origin).href;
  event.waitUntil(clients.matchAll({ type: "window", includeUncontrolled: true }).then((clientList) => {
    for (const client of clientList) {
      if (client.url === url && "focus" in client) return client.focus();
    }
    return clients.openWindow(url);
  }));
});

function cacheableApiRequest(request, url) {
  if (request.method !== "GET") return false;
  if (request.credentials === "omit") return false;
  return STALE_WHILE_REVALIDATE_API_PATHS.has(url.pathname);
}

async function staleWhileRevalidate(request) {
  const cache = await caches.open(API_CACHE_NAME);
  const cached = await cache.match(request);
  const network = fetch(request).then((response) => {
    if (response && response.ok && response.type === "basic") cache.put(request, response.clone());
    return response;
  });

  if (cached) {
    network.catch(() => undefined);
    return cached;
  }

  return network.catch(() => new Response(JSON.stringify({ error: "离线且暂无缓存" }), {
    status: 503,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  }));
}

function cacheableStaticRequest(request, url) {
  if (url.pathname.startsWith("/assets/")) return true;
  if (url.pathname.startsWith("/icons/")) return true;
  return APP_STATIC_ASSETS.includes(url.pathname);
}

async function cacheFirst(request) {
  const cached = await caches.match(request);
  if (cached) return cached;

  const response = await fetch(request);
  if (response && response.status === 200 && response.type === "basic") {
    const cache = await caches.open(CACHE_NAME);
    await cache.put(request, response.clone());
    await trimCache(cache, STATIC_CACHE_MAX_ENTRIES);
  }
  return response;
}

async function trimCache(cache, maxEntries) {
  const keys = await cache.keys();
  if (keys.length <= maxEntries) return;
  await Promise.all(keys.slice(0, keys.length - maxEntries).map((key) => cache.delete(key)));
}

self.addEventListener("fetch", (event) => {
  const request = event.request;
  const url = new URL(request.url);

  if (url.origin !== self.location.origin) return;
  if (request.method !== "GET") return;

  if (url.pathname.startsWith("/api/")) {
    if (cacheableApiRequest(request, url)) event.respondWith(staleWhileRevalidate(request));
    return;
  }

  if (request.mode === "navigate") {
    event.respondWith(
      Promise.resolve(event.preloadResponse)
        .then((preload) => preload || fetch(request))
        .catch(async () => {
          const cachedShell = await caches.match(APP_SHELL);
          return cachedShell ?? new Response("Offline", { status: 503, headers: { "Content-Type": "text/plain; charset=utf-8" } });
        }),
    );
    return;
  }

  if (cacheableStaticRequest(request, url)) {
    event.respondWith(cacheFirst(request));
  }
});
