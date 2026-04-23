# Manual resilience checks

## WebSocket reconnect banner (chat layout)

1. Open /chat in two browsers as different users.
2. In browser A, open DevTools > Network > set throttling to "Offline".
3. Within ~5s the yellow "Reconnecting…" banner appears at the top of the chat.
4. Set throttling back to "No throttling". Banner clears within 2s.
5. Background the tab for 30s, then refocus — verify the socket reconnects
   immediately (not after the next LiveSocket heartbeat attempt).

## Service-worker push badge

Pre-req: PWA installed on macOS Chrome (or any Chromium browser supporting setAppBadge).

1. Open Chrome DevTools > Application > Service Workers for tenun.dev.
2. Confirm the active worker reports cache `tenun-shell-v2`. If not, click "Update" then "Skip waiting".
3. In the "Push" textarea, paste:
   {"title":"#general","body":"alice: hi","tag":"channel:42","url":"/chat/general","type":"new_message"}
   then press "Push".
4. With the tab visible: notification is suppressed (no toast), but the page console
   logs `push:received` thanks to the open client postMessage.
5. Background the tab. Push again. Toast appears + OS badge increments.
6. Click the notification: tab is focused/navigated AND the OS badge clears.
