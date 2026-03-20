# PWA Setup — Tenun Branding

**Date:** 2026-03-20
**Status:** Approved

## Goal

Make Slackex/Tenun installable as a PWA — homescreen icon, standalone display (no browser chrome), system-theme-aware status bar, branded offline screen.

## Components

### 1. Manifest (`priv/static/manifest.json`)

```json
{
  "name": "Tenun",
  "short_name": "Tenun",
  "description": "Where ideas become woven into reality",
  "start_url": "/",
  "display": "standalone",
  "background_color": "#2A2640",
  "theme_color": "#5D4D8F",
  "icons": [
    { "src": "/images/icon-192.png", "sizes": "192x192", "type": "image/png" },
    { "src": "/images/icon-512.png", "sizes": "512x512", "type": "image/png" },
    { "src": "/images/icon-512-maskable.png", "sizes": "512x512", "type": "image/png", "purpose": "maskable" }
  ]
}
```

### 2. Static Paths Update (`lib/slackex_web.ex`)

Add `manifest.json` and `service-worker.js` to `static_paths/0`:
```elixir
def static_paths, do: ~w(assets fonts images favicon.ico robots.txt manifest.json service-worker.js)
```

### 3. Meta Tags (`root.html.heex`)

Add to `<head>`:
```html
<link rel="manifest" href="/manifest.json" />
<meta name="theme-color" content="#5D4D8F" media="(prefers-color-scheme: dark)" />
<meta name="theme-color" content="#E8A835" media="(prefers-color-scheme: light)" />
<meta name="apple-mobile-web-app-capable" content="yes" />
<meta name="apple-mobile-web-app-status-bar-style" content="default" />
<link rel="apple-touch-icon" href="/images/icon-192.png" />
```

Note: `apple-mobile-web-app-capable` is deprecated but kept as fallback for older iOS. Modern Safari reads `display: standalone` from the manifest.

### 4. Service Worker (`priv/static/service-worker.js`)

Static file (not bundled by esbuild). Responsibilities:
- Cache the `/offline` page on install
- Clean up old caches on activate
- Intercept failed navigation requests and serve cached offline page

```javascript
const CACHE_NAME = 'tenun-shell-v1';
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
```

### 5. Service Worker Registration (`assets/js/app.js`)

Add at the end of app.js:
```javascript
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('/service-worker.js')
    .then(() => console.debug('Service Worker registered'))
    .catch(err => console.warn('Service Worker registration failed:', err));
}
```

### 6. Offline Page

**Route:** `GET /offline` — outside all auth pipelines in `router.ex`

**Controller:** `SlackexWeb.OfflineController` — renders a self-contained HTML page with:
- Tenun "T" icon centered
- "Tenun is connecting..." text with subtle animation
- System theme support via `prefers-color-scheme` media query
- Dark: `#2A2640` background, `#f5f5f5` text
- Light: `#FAFAFA` background, `#1a1a1a` text
- No LiveView, no JS dependencies — pure static HTML
- Auto-retry: `<meta http-equiv="refresh" content="5">` to check connectivity every 5 seconds

### 7. Icons (`priv/static/images/`)

Generate three placeholder icons with white "T" letterform on purple (`#5D4D8F`) background:
- `icon-192.png` — 192x192, standard icon
- `icon-512.png` — 512x512, standard icon
- `icon-512-maskable.png` — 512x512, "T" within 40% radius safe zone for adaptive icon rendering

These are placeholder icons until proper Tenun branding is designed.

### 8. Disconnect Indicator Restyle (`assets/css/app.css`)

Restyle the existing LiveView `phx-disconnected` indicator to match Tenun branding instead of the default Phoenix "We can't find the internet" flash. Show a subtle top banner: "Reconnecting..." in theme-appropriate colors.

**Note on offline vs disconnect:** The service worker offline page handles complete network failure (DNS down, server unreachable). The `phx-disconnected` indicator handles in-session WebSocket drops where the page is loaded but the LiveView connection is lost. Both are needed — they cover different failure modes.

### 9. LiveView Title Update

Change the default LiveView title from "SlackEx" to "Tenun" in `root.html.heex`:
```html
<.live_title default="Tenun">{assigns[:page_title]}</.live_title>
```

## Files Modified

| File | Change |
|------|--------|
| `lib/slackex_web.ex` | Add `manifest.json`, `service-worker.js` to static_paths |
| `lib/slackex_web/components/layouts/root.html.heex` | Add manifest link, meta tags, change title to Tenun |
| `lib/slackex_web/router.ex` | Add `GET /offline` route outside auth |
| `assets/js/app.js` | Add service worker registration |
| `assets/css/app.css` | Restyle phx-disconnected indicator |

## Files Created

| File | Description |
|------|-------------|
| `priv/static/manifest.json` | PWA manifest |
| `priv/static/service-worker.js` | Offline fallback service worker |
| `lib/slackex_web/controllers/offline_controller.ex` | Offline page controller |
| `lib/slackex_web/controllers/offline_html.ex` | Offline page view/template |
| `priv/static/images/icon-192.png` | App icon 192x192 |
| `priv/static/images/icon-512.png` | App icon 512x512 |
| `priv/static/images/icon-512-maskable.png` | Maskable app icon 512x512 |

## Out of Scope

- Push notifications (Web Push API + server-side)
- Background sync
- Offline message caching
- App store distribution (Capacitor/Tauri)
- Full rebrand of codebase from Slackex to Tenun (separate effort)

## Testing

- Lighthouse PWA audit passes
- "Add to Home Screen" prompt appears on mobile
- App launches in standalone mode (no browser chrome)
- Offline page displays when network is unavailable
- System dark/light theme respected in status bar and offline page
- Disconnect indicator shows "Reconnecting..." instead of default Phoenix flash
