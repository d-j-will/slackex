# Notifications Architecture

**Status:** Reference
**Scope:** Presence tracking, push preferences, device subscriptions, catch-up, and push delivery

---

## 1. Overview

Slackex notifications combine several separate capabilities:

- presence tracking for online and offline awareness
- user push subscription storage
- global and per-channel notification preferences
- async push fanout for new channel messages and DMs
- reconnect catch-up generation for missed channel activity

The design tries to avoid noisy notifications while keeping reconnect and offline behavior predictable.

---

## 2. Main Components

| Component | Responsibility |
|---|---|
| `Slackex.Notifications.OnlineTracker` | Stores online markers in Redis with TTL refresh |
| `Slackex.Notifications.Preference` | Resolves global and per-channel notification levels |
| `Slackex.Notifications.DeviceToken` | Stores device tokens or web push subscriptions |
| `Slackex.Notifications.PushWorker` | Oban worker that sends push notifications for messages and DMs |
| `Slackex.Notifications.CatchupServer` | Builds reconnect payloads from read cursors and message history |
| `Slackex.Messaging.ChannelServer` | Enqueues push jobs after message batches persist |
| `SlackexWeb.ChatLive.Index` | Handles push subscription registration and user preference changes |

---

## 3. Presence Tracking

```mermaid
sequenceDiagram
  actor User
  participant LV as ChatLive.Index
  participant OT as OnlineTracker
  participant Redis as Redis

  User->>LV: connect to chat LiveView
  LV->>OT: mark_online(user_id)
  OT->>Redis: SET online:user_id EX 120

  loop every 60 seconds while connected
    LV->>OT: refresh(user_id)
    OT->>Redis: EXPIRE online:user_id 120
  end

  Note over OT,Redis: offline status is inferred when the TTL expires or marker is deleted
```

### Notes

- Presence is soft-state in Redis, not a durable database record.
- Channel and DM push delivery use presence checks to avoid notifying currently active users.
- The LiveView also queries online status for DM sidebar presentation.

---

## 4. Push Subscription And Preference Flow

```mermaid
flowchart TD
  A[User enables notifications in chat UI] --> B[LiveView push_event push:subscribe]
  B --> C[Browser obtains web push subscription]
  C --> D[push:register_subscription event]
  D --> E[Insert or update DeviceToken platform web_push]
  E --> F[push_subscribed assign becomes true]

  G[User changes global level] --> H[Preference.set_global_default]
  I[User changes channel level] --> J[Preference.set_preference]

  H --> K[Preference.resolve_level during delivery]
  J --> K
```

### Notes

- Web push subscriptions are stored in the same `device_tokens` table as FCM and APNs tokens.
- Preferences support three levels: `all`, `mentions`, and `nothing`.
- Channel-specific preferences override the global default.

---

## 5. Channel Push Delivery Flow

```mermaid
sequenceDiagram
  participant CS as ChannelServer
  participant Oban as Oban
  participant PW as PushWorker
  participant Pref as Preference
  participant OT as OnlineTracker
  participant Repo as Repo
  participant Adapter as Push Adapter

  CS->>Oban: enqueue PushWorker type new_message
  Oban->>PW: perform(job)
  PW->>Repo: load channel and subscribers excluding sender
  PW->>OT: filter out online subscribers

  loop each remaining subscriber
    PW->>Pref: resolve_level(user_id, channel_id)
    alt level is nothing
      PW->>PW: skip user
    else level is mentions and user not mentioned
      PW->>PW: skip user
    else notify
      PW->>Repo: load device tokens
      PW->>Adapter: send_push(token, platform, payload)
    end
  end
```

### Notes

- Channel push jobs are delayed by 5 seconds when enqueued from `ChannelServer`.
- The sender is always excluded.
- Mention-only delivery uses `Slackex.Notifications.Mention` to decide whether a subscriber should be notified.

---

## 6. DM Push Delivery Flow

```mermaid
sequenceDiagram
  participant CS as ChannelServer
  participant Oban as Oban
  participant PW as PushWorker
  participant OT as OnlineTracker
  participant Repo as Repo
  participant Adapter as Push Adapter

  CS->>Oban: enqueue PushWorker type new_dm
  Oban->>PW: perform(job)
  PW->>Repo: load DM conversation
  PW->>PW: determine recipient from DM record
  PW->>OT: check if recipient is online

  alt recipient is online
    PW->>PW: skip push
  else recipient is offline
    PW->>Repo: load device tokens
    PW->>Adapter: send_push(token, platform, payload)
  end
```

### Notes

- DM recipient selection is derived from the DM record, not from the caller.
- DM notifications do not use per-channel preference rules.

---

## 7. Reconnect Catch-Up Flow

```mermaid
flowchart TD
  A[Client reconnects] --> B[CatchupServer.build_catchup user_id]
  B --> C[List subscribed channels]
  C --> D[Resolve read cursor per channel]
  D --> E{Redis cursor present?}
  E -- Yes --> F[Use Redis value]
  E -- No --> G[Load DB read cursor or 0]
  F --> H[Count unread messages]
  G --> H
  H --> I[Load up to 100 missed messages after cursor]
  I --> J[Serialize message payloads]
  J --> K[Return channels plus timestamp]
```

### Notes

- Catch-up is a pure function module even though its name says `CatchupServer`.
- Redis is a fast path for read cursors; the database remains the fallback of record.
- This supports reconnect UX without requiring the whole message history to be reloaded.

---

## 8. Design Properties

- **Offline-aware delivery:** push fanout is gated by Redis presence state.
- **Preference-driven notifications:** global defaults and per-channel overrides reduce noise.
- **Shared token model:** web push, FCM, and APNs all use the same storage abstraction.
- **Async dispatch:** push work runs out-of-band in Oban, not in the message send path.
- **Graceful target deletion:** workers discard jobs when the channel or DM no longer exists.
- **Reconnect support:** catch-up payloads bridge the gap between offline time and resumed activity.

---

## 9. Code Map

- `lib/slackex/notifications/online_tracker.ex`
- `lib/slackex/notifications/preference.ex`
- `lib/slackex/notifications/device_token.ex`
- `lib/slackex/notifications/push_worker.ex`
- `lib/slackex/notifications/catchup_server.ex`
- `lib/slackex/messaging/channel_server.ex`
- `lib/slackex_web/live/chat_live/index.ex`

---

## 10. Related Tests

- `test/slackex/notifications_test.exs`
- `test/slackex/notifications/push_notifications_integration_test.exs`
- `test/slackex/notifications/catchup_server_test.exs`
- `test/slackex/notifications/online_tracker_test.exs`
