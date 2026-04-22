# Manual resilience checks

## WebSocket reconnect banner (chat layout)

1. Open /chat in two browsers as different users.
2. In browser A, open DevTools > Network > set throttling to "Offline".
3. Within ~5s the yellow "Reconnecting…" banner appears at the top of the chat.
4. Set throttling back to "No throttling". Banner clears within 2s.
5. Background the tab for 30s, then refocus — verify the socket reconnects
   immediately (not after the next LiveSocket heartbeat attempt).
