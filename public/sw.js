// Minimal service worker for installability + offline app shell (build plan §11
// item 35). Cache-first for Vite's content-hashed /assets/, network-first for
// everything else same-origin, falling back to cache (and to the SPA shell for
// navigations) when offline. Supabase API calls are cross-origin and deliberately
// left untouched, so data is always live when online.
// Bumped with the caching strategy below. The old worker wrote failed responses
// into the cache, so anyone carrying a 5xx from a deploy window needs a clean
// slate rather than an upgrade — the activate handler drops every other version.
const CACHE = 'micro-saccos-v2'

// The SPA shell, precached so the offline fallback can actually find it.
//
// Navigations are cached under the path that was asked for (/dashboard, /profile,
// …), never under /index.html, because the server rewrites without the browser
// knowing. So the fallback's `caches.match('/index.html')` matched nothing unless
// something had happened to request that exact path, and offline navigation fell
// through to a browser error page — the one case the shell exists for.
self.addEventListener('install', (event) => {
  event.waitUntil(
    caches
      .open(CACHE)
      .then((cache) => cache.add(new Request('/index.html', { cache: 'reload' })))
      .catch(() => {})
      .then(() => self.skipWaiting()),
  )
})

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  )
})

// Web Push (migration 026). The payload is the JSON the dispatcher sends; a push
// with no body still shows something useful rather than the browser's generic
// "This site has been updated in the background".
self.addEventListener('push', (event) => {
  let payload
  try {
    payload = event.data ? event.data.json() : {}
  } catch {
    // Not JSON — fall back to the raw text so a plain-text push still says something.
    payload = { title: 'Micro-SACCOS', body: event.data ? event.data.text() : '' }
  }
  event.waitUntil(
    self.registration.showNotification(payload.title || 'Micro-SACCOS', {
      body: payload.body || '',
      icon: '/favicon.svg',
      badge: '/favicon.svg',
      data: { url: payload.url || '/' },
      // Same tag = a new reminder replaces the old one instead of stacking five
      // copies of "your fee is overdue" in the tray.
      tag: payload.tag || 'micro-saccos',
      renotify: true,
    }),
  )
})

// Focus an already-open tab rather than opening a second one.
self.addEventListener('notificationclick', (event) => {
  event.notification.close()
  const url = event.notification.data?.url || '/'
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clients) => {
      for (const client of clients) {
        if (client.url.includes(self.location.origin) && 'focus' in client) {
          client.navigate(url)
          return client.focus()
        }
      }
      return self.clients.openWindow(url)
    }),
  )
})

self.addEventListener('fetch', (event) => {
  const { request } = event
  const url = new URL(request.url)
  if (request.method !== 'GET' || url.origin !== self.location.origin) return

  // Vite's build output is content-hashed, so /assets/index-Bp6Eqax3.js can never
  // change meaning — a new build is a new filename. Those are served cache-first:
  // a repeat visit paints from disk instead of waiting on the network, which on
  // the 3G connections this group is actually on is the difference between
  // "instant" and "several seconds of white screen". Everything else stays
  // network-first so data-adjacent responses are never stale.
  const immutable = url.pathname.startsWith('/assets/')

  if (immutable) {
    event.respondWith(
      caches.match(request).then((cached) => cached || fetchAndCache(request)),
    )
    return
  }

  event.respondWith(
    fetchAndCache(request).catch(() =>
      caches.match(request).then((cached) => {
        if (cached) return cached
        // The SPA shell answers for a NAVIGATION and nothing else. It used to
        // answer for anything that failed, so an offline request for a script or
        // an image was served index.html — HTML with a .js content type, which
        // fails as a syntax error rather than as a missing file, and reads in the
        // console as a broken build instead of a dropped connection.
        if (request.mode === 'navigate') return caches.match('/index.html')
        return Response.error()
      }),
    ),
  )
})

// Cache only what is worth replaying. Without the `ok` check, a 500 or a 503
// served during a deploy was written into the cache like any other response and
// then handed back from it forever after, turning a few seconds of downtime into
// a permanently broken install. `basic` excludes opaque cross-origin responses,
// whose status always reads 0.
function fetchAndCache(request) {
  return fetch(request).then((response) => {
    if (response.ok && response.type === 'basic') {
      const copy = response.clone()
      caches.open(CACHE).then((cache) => cache.put(request, copy)).catch(() => {})
    }
    return response
  })
}
