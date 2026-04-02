# Realtime Chat Architecture

**Status:** Reference
**Scope:** LiveView chat, Phoenix Channel clients, PubSub fanout, async persistence

---

## 1. Overview

Slackex routes realtime chat through a per-conversation `ChannelServer` process.
The hot path is optimized for fast user feedback:

1. User sends a message from LiveView or a Phoenix Channel client.
2. `Slackex.Messaging` ensures the target process exists.
3. `ChannelServer` validates, rate-limits, caches, and immediately broadcasts the message over PubSub.
4. Subscribers update the UI before the database write completes.
5. Persistence happens asynchronously in batched writes through `BatchWriter`.

This splits the user-visible realtime path from the durability path while keeping a single backend pipeline for channels and DMs.

---

## 2. C4 Diagrams

### 2.1 System Context

```mermaid
C4Context
  title System Context -- Slackex Realtime Chat

  Person(user, "Chat User", "Reads channels, sends messages, receives realtime updates")

  System_Ext(browser, "Browser / PWA Client", "Phoenix LiveView client")
  System_Ext(socket_client, "Socket Client", "Phoenix Channel client")
  System(slackex, "Slackex", "Phoenix application providing realtime chat")
  System_Ext(postgres, "PostgreSQL", "Stores messages, memberships, read state, and writer epochs")
  System_Ext(redis, "Redis", "Cross-node cache and fast-path state")
  System_Ext(push, "Push Notification Delivery", "Offline notification delivery")

  Rel(user, browser, "Uses")
  Rel(user, socket_client, "Can also use")
  Rel(browser, slackex, "Reads history and sends messages via", "HTTP + LiveView WebSocket")
  Rel(socket_client, slackex, "Sends and receives realtime messages via", "Phoenix Channels WebSocket")
  Rel(slackex, postgres, "Persists and queries chat data in")
  Rel(slackex, redis, "Caches hot data in")
  Rel(slackex, push, "Triggers notifications through")
```

### 2.2 Container Diagram

```mermaid
C4Container
  title Container Diagram -- Slackex Realtime Chat

  Person(user, "Chat User")

  Container_Boundary(slackex, "Slackex Application") {
    Container(liveview, "ChatLive.Index", "Phoenix LiveView", "Browser chat UI, subscriptions, message streams")
    Container(socket_transport, "ChatChannel / DMChannel", "Phoenix Channels", "Realtime socket interface for non-LiveView clients")
    Container(chat, "Chat", "Elixir Context", "History loading, read state, membership, domain CRUD")
    Container(messaging, "Messaging", "Elixir Context", "Public facade for send, edit, delete, reply, reactions")
    Container(channel_supervisor, "ChannelSupervisor", "Dynamic Supervisor", "Starts per-channel and per-DM workers on demand")
    Container(channel_server, "ChannelServer", "GenServer", "Per-conversation hot state, validation, PubSub broadcast, batching")
    Container(cache, "Cache", "ETS + Redis", "Hot message cache and cursor fast path")
    Container(pubsub, "Phoenix.PubSub", "Distributed event bus", "Fans realtime envelopes out to subscribers")
    Container(batch_writer, "BatchWriter", "Task + Ecto", "Async batched persistence with writer fencing")
  }

  ContainerDb(postgres, "PostgreSQL", "Messages, memberships, read state, writer epochs")
  System_Ext(redis, "Redis", "Cross-node cache backend")
  System_Ext(push, "Push Notification Delivery", "Offline notification fanout")

  Rel(user, liveview, "Reads and sends messages in", "Browser")
  Rel(user, socket_transport, "Can connect through", "WebSocket client")
  Rel(liveview, chat, "Loads history and marks read through")
  Rel(liveview, messaging, "Delegates send and edit operations to")
  Rel(socket_transport, chat, "Loads initial history through")
  Rel(socket_transport, messaging, "Delegates send operations to")
  Rel(messaging, channel_supervisor, "Ensures target worker exists via")
  Rel(channel_supervisor, channel_server, "Starts and supervises")
  Rel(messaging, channel_server, "Routes realtime sends to")
  Rel(channel_server, cache, "Reads and updates hot messages in")
  Rel(channel_server, pubsub, "Broadcasts envelopes to")
  Rel(pubsub, liveview, "Delivers realtime message events to")
  Rel(pubsub, socket_transport, "Delivers realtime message events to")
  Rel(channel_server, batch_writer, "Flushes pending writes through")
  Rel(batch_writer, postgres, "Persists message batches to")
  Rel(chat, postgres, "Queries history, membership, and read state from")
  Rel(cache, redis, "Uses as cross-node backing store")
  Rel(channel_server, push, "Triggers notification jobs for")
```

These diagrams show the system at a higher level than the sequence diagrams below.

---

## 3. How To Read This Document

- Start with the **System Context** diagram to see who uses realtime chat and which external systems Slackex depends on.
- Move to the **Container Diagram** to understand which internal modules own UI, routing, hot state, caching, fanout, and persistence.
- Use the **sequence diagrams** when you want runtime behavior: who calls whom, when PubSub fires, and when persistence happens.
- Use the **history flowchart** when you want to understand navigation, initial message loading, and upward pagination.

### Quick Legend

| Diagram Type | Best For | Read It As |
|---|---|---|
| C4 System Context | System boundaries | Users and external dependencies around Slackex |
| C4 Container | Internal architecture | Major runtime building blocks inside the app |
| Sequence Diagram | Request/event flow | Time-ordered interactions between components |
| Flowchart | Decision paths | Branching logic for navigation and history loading |

### Terms Used Here

| Term | Meaning |
|---|---|
| Conversation | Either a channel or a DM conversation |
| Target | The tuple identifying a conversation, such as `{:channel, id}` or `{:dm, id}` |
| Envelope | The normalized PubSub event payload used for realtime fanout |
| Hot path | The latency-sensitive path that updates the UI immediately |
| Durability path | The asynchronous batch write path that persists messages to PostgreSQL |
| Writer fencing | Epoch checks that prevent stale `ChannelServer` instances from writing |

---

## 4. Main Components

| Component | Responsibility |
|---|---|
| `SlackexWeb.ChatLive.Index` | Handles LiveView events, subscriptions, and message stream updates |
| `SlackexWeb.ChatLive.Conversations` | Enters/leaves channels and DMs, loads history, manages pagination |
| `SlackexWeb.ChatLive.Helpers` | Thin helpers for send/typing flows and stream updates |
| `Slackex.Messaging` | Public facade for send/edit/delete/reaction/reply operations |
| `Slackex.Messaging.ChannelSupervisor` | Starts per-channel and per-DM `ChannelServer` processes on demand |
| `Slackex.Messaging.ChannelServer` | Validates messages, maintains in-memory queue, broadcasts PubSub events, batches writes |
| `Slackex.Pipeline.BatchWriter` | Persists message batches with writer-epoch fencing |
| `Phoenix.PubSub` | Fans out realtime events to LiveViews, Phoenix Channels, and other subscribers |
| `Slackex.Chat` | Loads history, marks read state, and performs domain operations |

---

## 5. LiveView Send Path

```mermaid
sequenceDiagram
  actor User
  participant LV as ChatLive.Index
  participant H as ChatLive.Helpers
  participant M as Slackex.Messaging
  participant Sup as ChannelSupervisor
  participant CS as ChannelServer
  participant Cache as Cache
  participant PubSub as Phoenix.PubSub
  participant UI as Active LiveViews
  participant BW as BatchWriter
  participant DB as Postgres
  participant Jobs as Push + Listeners

  User->>LV: phx-submit send_message
  LV->>H: send_message_to_channel/dm(...)
  H->>M: send_message/send_dm(...)
  M->>Sup: ensure_started(target)
  Sup-->>M: {:ok, pid}
  M->>CS: send_message(sender_id, content)

  CS->>CS: validate content
  CS->>CS: check permissions or DM participant
  CS->>CS: rate limit sender
  CS->>CS: generate Snowflake ID + timestamp
  CS->>Cache: put_message(target, message)
  CS->>CS: append to in-memory queue
  CS->>PubSub: broadcast envelope message.new

  PubSub-->>UI: {:envelope, %{event: message.new}}
  UI->>UI: enrich sender if needed
  UI->>UI: compute grouping and dividers
  UI->>UI: stream_insert(:messages, message)
  UI->>UI: maybe mark as read
  UI-->>User: message appears immediately

  Note over CS,BW: every 2 seconds, pending writes are flushed asynchronously
  CS->>BW: async_insert_batch(batch, ref, epoch_opts)
  BW->>DB: transaction + writer_epoch fence
  BW->>DB: Repo.insert_all(messages)

  alt persist succeeds
    DB-->>BW: {:ok, count}
    BW-->>CS: {:batch_result, ref, :ok}
    CS->>PubSub: broadcast pipeline:events
    CS->>Jobs: enqueue push notifications
  else persist fails
    DB-->>BW: {:error, reason}
    BW-->>CS: {:batch_result, ref, {:error, reason}}
    CS->>CS: retry or stale shutdown or telemetry
  end
```

### Notes

- UI updates happen on PubSub delivery, not after the database write.
- The same `ChannelServer` path is used for both channels and DMs.
- Batched persistence reduces write overhead while preserving a responsive send path.

---

## 6. Conversation Entry And History Load

```mermaid
flowchart TD
  A[User navigates to channel or DM] --> B[ChatLive handle_params]
  B --> C[Conversations.enter_channel or enter_dm]
  C --> D[Leave previous conversation]
  D --> E[Unsubscribe old topic]
  E --> F[Subscribe new topic]

  F --> G{Target message requested?}
  G -- Yes --> H[HistoryLoader.around target message]
  G -- No --> I[Chat.list_messages or list_dm_messages]
  H --> J[Load reactions]
  I --> J

  J --> K[Mark as read]
  K --> L[Assign active conversation state]
  L --> M[Reset LiveView stream with recent history]
  M --> N[User sees conversation]

  N --> O[User scrolls up]
  O --> P[phx load_more]
  P --> Q{Has more and oldest id?}
  Q -- Yes --> R[Chat.list_messages before oldest_id]
  R --> S[Prepend older messages into stream]
  S --> T[Update oldest_message_id and has_more_messages]
  Q -- No --> U[No-op]
```

### Notes

- Realtime delivery and history loading are separate paths.
- Initial history comes from `Slackex.Chat`, while new messages arrive over PubSub.
- Targeted navigation can load messages around a specific message ID for deep links.

---

## 7. Phoenix Channel Client Path

```mermaid
sequenceDiagram
  actor Client as Socket Client
  participant PC as ChatChannel or DMChannel
  participant Chat as Slackex.Chat
  participant M as Slackex.Messaging
  participant CS as ChannelServer
  participant PubSub as Phoenix.PubSub

  Client->>PC: join chat:id or dm:id
  PC->>Chat: authorize and load last 50 messages
  PC->>Chat: mark as read
  PC->>PubSub: subscribe to channel:id or dm:id
  PC-->>Client: {:ok, %{messages: ...}}

  Client->>PC: handle_in new_message
  PC->>M: send_message or send_dm
  M->>CS: send_message(...)
  CS->>PubSub: broadcast envelope message.new
  PubSub-->>PC: {:envelope, %{event: message.new}}
  PC-->>Client: push message.new
```

### Notes

- Phoenix Channel clients reuse the same backend messaging pipeline as LiveView.
- This keeps authorization, rate limiting, and persistence behavior consistent across clients.

---

## 8. Key Design Properties

- **Fast feedback:** users see messages on PubSub broadcast before persistence completes.
- **Single realtime coordinator per conversation:** `ChannelServer` owns hot state for an active channel or DM.
- **Shared backend path:** LiveView and Phoenix Channel clients both use `Slackex.Messaging`.
- **Bounded in-memory state:** recent messages are kept in a capped queue for fast reads.
- **Async durability:** writes are batched through `BatchWriter` instead of blocking the send path.
- **Writer fencing:** database epoch checks prevent stale writers from persisting after failover or ownership changes.

---

## 9. Code Map

- `lib/slackex_web/live/chat_live/index.ex`
- `lib/slackex_web/live/chat_live/conversations.ex`
- `lib/slackex_web/live/chat_live/helpers.ex`
- `lib/slackex_web/channels/chat_channel.ex`
- `lib/slackex_web/channels/dm_channel.ex`
- `lib/slackex/messaging/messaging.ex`
- `lib/slackex/messaging/channel_server.ex`
- `lib/slackex/pipeline/batch_writer.ex`
- `lib/slackex/chat/chat.ex`

---

## 10. Related Documents

- `docs/feature/mcp-server/design/architecture.md` - how external agents and SSE subscribers consume the messaging system
- `docs/feature/markdown-rendering/design/architecture.md` - how message content moves from storage to safe render-time HTML
- `docs/runbooks/observability.md` - metrics, traces, and operational visibility for the realtime system
- `docs/engineering-principles.md` - project-wide rules around deploy safety, test isolation, and production hardening
- `docs/design/information-architecture.md` - UI navigation model for channels, DMs, thread panels, and in-chat transitions
