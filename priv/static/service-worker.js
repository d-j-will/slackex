// Bump on any change to precached shell (e.g. the /offline page) so existing
// installs reinstall and drop the stale cache. v4: Loom black/gold offline page.
const CACHE_NAME = 'tenun-shell-v4';
const OFFLINE_URL = '/offline';

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.add(OFFLINE_URL))
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  if (event.request.mode === 'navigate') {
    event.respondWith(
      fetch(event.request).catch(() => caches.match(OFFLINE_URL))
    );
  }
});

// Push notification handler
self.addEventListener('push', (event) => {
  const data = event.data?.json() || {};
  const options = {
    body: data.body || '',
    tag: data.tag || 'tenun-default',
    renotify: true,
    icon: '/images/icon-192.png',
    badge: '/images/icon-192.png',
    data: { url: data.url || '/chat', tag: data.tag },
  };

  event.waitUntil((async () => {
    // 1. Increment OS badge (W3C Badging API). Best-effort: not all platforms
    //    support it (iOS PWAs need 16.4+). The count lives on the SW global so
    //    it survives across consecutive pushes within one SW lifetime; clients
    //    will overwrite it via `badge:set` events sent from the LiveView.
    if ('setAppBadge' in self.navigator) {
      try {
        self._badgeCount = (self._badgeCount || 0) + 1;
        await self.navigator.setAppBadge(self._badgeCount);
      } catch (err) {
        console.warn('[SW] setAppBadge failed:', err);
      }
    }

    // 2. Tell every open client so any visible tab can update its in-app
    //    sidebar/badge immediately (the WebSocket may have missed the message).
    const clients = await self.clients.matchAll({
      type: 'window',
      includeUncontrolled: true,
    });
    for (const client of clients) {
      client.postMessage({ type: 'push:received', payload: data });
    }

    // 3. Always show the OS notification — matches WhatsApp/Slack/Discord
    //    desktop behavior. The user wants to know they got a message even
    //    when the app is open, unfocused, occluded, or minimized. The
    //    in-app badge updates separately via the postMessage above.
    return self.registration
      .showNotification(data.title || 'Tenun', options)
      .catch((err) => console.error('[SW] showNotification failed:', err));
  })());
});

// Notification click handler — clear badge, open or focus the app
self.addEventListener('notificationclick', (event) => {
  event.notification.close();

  event.waitUntil((async () => {
    // Only clear the OS badge when this was the last visible notification —
    // otherwise we'd zero it while other unread toasts remain on screen.
    if ('clearAppBadge' in self.navigator) {
      const remaining = await self.registration.getNotifications();
      if (remaining.length <= 1) {
        self._badgeCount = 0;
        try {
          await self.navigator.clearAppBadge();
        } catch (_err) {
          // best-effort
        }
      } else {
        self._badgeCount = Math.max(0, (self._badgeCount || 0) - 1);
        try {
          await self.navigator.setAppBadge(self._badgeCount || 1);
        } catch (_err) {
          // best-effort
        }
      }
    }

    const windowClients = await self.clients.matchAll({
      type: 'window',
      includeUncontrolled: true,
    });

    for (const client of windowClients) {
      if (client.url.includes('/chat') && 'focus' in client) {
        client.navigate(event.notification.data.url);
        return client.focus();
      }
    }

    return self.clients.openWindow(event.notification.data.url);
  })());
});
