// Minimal service worker for installability + offline app shell (build plan §11
// item 35). Network-first for same-origin GETs, falling back to cache (and to the
// SPA shell for navigations) when offline. Supabase API calls are cross-origin and
// deliberately left untouched, so data is always live when online.
const CACHE = 'micro-saccos-v1'

self.addEventListener('install', () => self.skipWaiting())

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  )
})

self.addEventListener('fetch', (event) => {
  const { request } = event
  const url = new URL(request.url)
  if (request.method !== 'GET' || url.origin !== self.location.origin) return

  event.respondWith(
    fetch(request)
      .then((response) => {
        const copy = response.clone()
        caches.open(CACHE).then((cache) => cache.put(request, copy))
        return response
      })
      .catch(() =>
        caches.match(request).then((cached) => cached || caches.match('/index.html')),
      ),
  )
})
