# PWA Push Notifications Design Spec

**Date:** 2026-04-02
**Status:** Draft
**Feature Flag:** `:push_notifications`

## Overview

Add Web Push notifications to Tenun's existing PWA, leveraging the already-built notification backend (PushWorker, OnlineTracker, DeviceTokenController, adapter pattern). Users opt in manually via a settings toggle — no surprise permission prompts. Notifications support per-channel preferences (all messages / mentions only / nothing) with smart grouping (channel messages collapse, DMs and mentions show individually).

## Constraints

- ~50 active users (homelab/team scale)
- Self-hosted — no Firebase/Google dependency
- PWA-only (no native mobile) — Web Push (VAPID) via `web_push_elixir`
- Existing backend infrastructure reused where possible
- Feature-flagged behind `:push_notifications`

## Existing Infrastructure (Reused)

| Component | Status | Notes |
|-----------|--------|-------|
| `Notifications.PushWorker` | Exists | Oban worker on `:notifications` queue, triggers on new messages/DMs |
| `Notifications.OnlineTracker` | Exists | Redis-backed, 2-min TTL, only notifies offline users |
| `Notifications.PushAdapter.Stub` | Exists | Adapter interface — swap for real adapter |
| `device_tokens` table + schema | Exists | Stores `user_id`, `token`, `platform`, `device_name` |
| `DeviceTokenController` | Exists | POST/DELETE `/api/device-tokens` |
| `ChannelServer` integration | Exists | Enqueues push jobs on new channel message (5s delay) and new DM (immediate) |

## VAPID Keys and Configuration

VAPID (Voluntary Application Server Identification) keys identify the server to browser push services. Generated once, stored as environment variables.

**Key generation:** A mix task (`mix tenun.gen.vapid_keys`) generates a VAPID key pair and outputs instructions to add them to `.env`.

**Configuration:**

```elixir
# config/runtime.exs
config :slackex, Slackex.Notifications.WebPushAdapter,
  vapid_public_key: System.get_env("VAPID_PUBLIC_KEY"),
  vapid_private_key: System.get_env("VAPID_PRIVATE_KEY"),
  vapid_subject: "mailto:admin@tenun.dev"
```

**Client exposure:** The VAPID public key is exposed to the browser via a meta tag in the root layout:

```heex
<meta name="vapid-public-key" content={vapid_public_key} />
```

The browser needs this key to create a push subscription.

## Push Subscription Storage

Reuse the existing `device_tokens` table. A Web Push subscription from the browser is a JSON object containing an `endpoint` URL and `keys` (p256dh + auth).

- Store the full subscription JSON in the `token` field
- Set `platform: "web_push"`
- The existing unique constraint on `token` prevents duplicate subscriptions
- The existing `DeviceTokenController` (POST/DELETE) handles registration — no new endpoints needed

## Notification Preferences

### New Table: `notification_preferences`

| Column | Type | Notes |
|--------|------|-------|
| `id` | `bigint` | Standard PK |
| `user_id` | `bigint FK` | FK to users, NOT NULL |
| `channel_id` | `bigint FK, nullable` | FK to channels. NULL = global default |
| `level` | `string` | `"all"`, `"mentions"`, `"nothing"` |
| `inserted_at` | `utc_datetime_usec` | |
| `updated_at` | `utc_datetime_usec` | |

**Unique constraint:** `(user_id, channel_id)` — one preference per user per channel. A row with `channel_id: NULL` is the user's global default.

### Resolution Logic

When deciding whether to notify a user about a message:

1. Check per-channel preference for this user + channel
2. If none, fall back to global default (`channel_id = NULL` row)
3. If no global default, fall back to `"all"` (notify for everything)

For DMs, preferences do not apply — DMs always notify (unless the user has no push subscription at all).

### Mention Detection

When a user's preference level is `"mentions"`, the PushWorker checks if the message content contains `@username` for the target user. This is a simple string match against the user's `username` field. If found, the notification is sent; otherwise, it is skipped.

## WebPush Adapter

A new module `Slackex.Notifications.WebPushAdapter` implementing the same interface as the existing `StubAdapter`. Swapping Stub for WebPush is a config change:

```elixir
# config/runtime.exs (prod)
config :slackex, :push_adapter, Slackex.Notifications.WebPushAdapter
```

The adapter:
1. Decodes the subscription JSON from the `token` field
2. Builds the Web Push notification payload
3. Sends via `web_push_elixir` using the configured VAPID keys
4. Returns `:ok` on success or `{:error, reason}` on failure
5. On HTTP 410 (subscription expired/unsubscribed), deletes the device token from the database

### Notification Payload

The push payload is a JSON string received by the service worker:

```json
{
  "title": "#general",
  "body": "username: message content here...",
  "tag": "channel:123",
  "url": "/chat/general",
  "type": "channel"
}
```

| Field | Description |
|-------|-------------|
| `title` | Channel name (`#slug`) or sender name (`@username` for DMs) |
| `body` | Message content, truncated to 100 characters (matches existing PushWorker behavior) |
| `tag` | Grouping key for smart collapse (see below) |
| `url` | Deep link back to the channel or DM conversation |
| `type` | `"channel"`, `"dm"`, or `"mention"` — used by service worker for grouping logic |

### Smart Grouping via `tag`

The browser uses the `tag` field to collapse notifications — same tag replaces the previous notification:

- **Channel messages:** `tag: "channel:#{channel_id}"` — multiple messages in the same channel collapse into one notification showing the latest
- **DMs:** `tag: "dm:#{dm_id}:#{message_id}"` — each DM shows individually (unique tag per message)
- **Mentions:** `tag: "mention:#{channel_id}:#{message_id}"` — each mention shows individually, not collapsed with regular channel messages

The existing 5-second delay on channel messages provides natural batching. If multiple messages arrive within 5 seconds, only the latest notification is sent (the worker already checks if the user has come online in the meantime).

## PushWorker Modifications

The existing `Notifications.PushWorker` needs two changes:

### 1. Preference Checking

Before sending a notification, query `notification_preferences` for the target user + channel:
- If level is `"nothing"`, skip the notification
- If level is `"mentions"`, check if the message content contains `@username` for the target user
- If level is `"all"` or no preference exists, send the notification

### 2. Payload Enhancement

Include `tag`, `url`, and `type` fields in the notification payload passed to the adapter. The existing payload already has title and body — extend it with the grouping metadata.

## Service Worker Push Handler

Add two event listeners to the existing `priv/static/service-worker.js`:

### Push Event

Receives the push payload and displays a notification:

```javascript
self.addEventListener('push', (event) => {
  const data = event.data?.json() || {};
  const options = {
    body: data.body,
    tag: data.tag,
    renotify: true,
    data: { url: data.url },
  };
  event.waitUntil(self.registration.showNotification(data.title, options));
});
```

### Notification Click

Opens or focuses the app at the correct URL when the notification is clicked:

```javascript
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(clients.openWindow(event.notification.data.url));
});
```

## Client-Side Permission + Subscription Flow

Triggered exclusively from the user settings toggle — no unprompted permission requests.

### Enable Flow

1. User clicks "Enable notifications" toggle in profile settings
2. JS calls `Notification.requestPermission()`
3. If granted, subscribe via `registration.pushManager.subscribe()` with the VAPID public key from the meta tag
4. POST the subscription JSON to `/api/device-tokens` with `platform: "web_push"`
5. UI confirms notifications are enabled

### Disable Flow

1. User clicks "Disable notifications" toggle
2. Call `subscription.unsubscribe()` on the push subscription
3. DELETE `/api/device-tokens` to remove the subscription server-side
4. UI confirms notifications are disabled

### State Detection

The settings UI shows the current state by checking:
- `Notification.permission` — whether the browser has granted permission
- `registration.pushManager.getSubscription()` — whether an active subscription exists

If the browser has denied permission (user previously clicked "Block"), the toggle shows a message explaining they need to reset the permission in browser settings.

## User Interface

### Profile Settings (Global Defaults)

Add a "Notifications" section to the existing profile edit form:

- **Push notifications toggle** — Enable/Disable (triggers the permission + subscription flow)
- **Default notification level** — dropdown: All messages / Mentions only / Nothing
  - This sets the global default (`channel_id: NULL` preference row)

### Per-Channel Bell (Channel Overrides)

A notification bell icon in the channel header. Clicking opens a small dropdown with three options:

- **All messages** — notify on every message in this channel
- **Mentions only** — only notify when `@username` appears
- **Nothing** — mute this channel

The current setting is indicated visually (checkmark or highlight). If no per-channel preference is set, "All messages" is shown with a "(default)" label.

## Feature Flag & Rollout

Gated behind `:push_notifications` FunWithFlags flag:

- **Flag off** — Settings toggle hidden, PushWorker uses StubAdapter, service worker push handler is inert (no pushes arrive)
- **Flag on** — Full notification flow enabled
- **Per-user gating** — Enable for specific users first for validation

## Testing Strategy

### Integration Test

Register subscription → send message to channel → verify PushWorker enqueues → verify WebPushAdapter is called with correct payload and subscription. No faking the upstream — exercise the full path from message send to adapter call.

### Unit Tests

- `Notifications.Preference` — resolution logic (per-channel > global > default)
- `Notifications.Preference` — mention detection (`@username` in content)
- `WebPushAdapter` — payload construction (title, body, tag, url, type)
- `WebPushAdapter` — subscription JSON decoding
- `WebPushAdapter` — handles HTTP 410 (expired subscription cleanup)
- `PushWorker` — respects preference levels (all/mentions/nothing)
- `PushWorker` — tag generation for smart grouping
- `DeviceTokenController` — accepts `platform: "web_push"` with subscription JSON

### Contract Test

WebPushAdapter payload JSON shape matches what the service worker expects: `title`, `body`, `tag`, `url`, `type` fields all present with correct types.

## Module Summary

| Layer | Module | Change |
|-------|--------|--------|
| Config | VAPID keys in `runtime.exs` | New |
| Mix task | `Mix.Tasks.Tenun.Gen.VapidKeys` | New |
| Adapter | `Notifications.WebPushAdapter` | New |
| Preferences | `Notifications.Preference` | New (schema + context) |
| Worker | `Notifications.PushWorker` | Modify (add preference check + tag) |
| Service Worker | `priv/static/service-worker.js` | Modify (add push + click handlers) |
| Client JS | Notification subscription hook | New |
| Layout | `root.html.heex` | Modify (add VAPID meta tag) |
| UI | Profile settings | Modify (add notifications section) |
| UI | Channel header | Modify (add notification bell) |
| API | `DeviceTokenController` | No change (already handles web_push) |
| Migration | `notification_preferences` table | New |
| Gate | `:push_notifications` flag | New |
| Dep | `web_push_elixir` | New hex dependency |
