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
