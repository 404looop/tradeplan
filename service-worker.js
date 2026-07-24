/* PWA service worker for ترید پلن.
   Strategy: network-first for page loads (so updates always win when online),
   cache fallback for offline. Supabase and other cross-origin requests are
   never intercepted. Bump CACHE to force-refresh all clients. */
const CACHE = 'tradeplan-v32';

self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE)
      .then(c => c.addAll(['./']))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  if (new URL(req.url).origin !== location.origin) return;

  // The EA download must always be fresh: network-first like page loads,
  // otherwise users grab a stale cached copy right after an update.
  if (req.mode === 'navigate' || new URL(req.url).pathname.endsWith('.mq5')) {
    e.respondWith(
      fetch(req)
        .then(res => {
          const copy = res.clone();
          caches.open(CACHE).then(c => c.put(req, copy));
          return res;
        })
        .catch(() => caches.match(req).then(r => r || caches.match('./')))
    );
    return;
  }

  e.respondWith(
    caches.match(req).then(cached => {
      const fetched = fetch(req)
        .then(res => {
          if (res.ok) {
            const copy = res.clone();
            caches.open(CACHE).then(c => c.put(req, copy));
          }
          return res;
        })
        .catch(() => cached);
      return cached || fetched;
    })
  );
});
