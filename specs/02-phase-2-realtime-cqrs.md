# Phase 2 — Real-Time & CQRS

## Goal

Evolve Phase 1's direct-to-database messaging into a proper CQRS architecture with in-memory GenServer processes per channel, async write pipeline for batch persistence, ETS local caching, Phoenix Presence for online status and typing indicators, and scroll-based history pagination.

## Prerequisites

Phase 1 complete and all acceptance criteria met.

## Dependencies Added

- `{:oban, "~> 2.18"}` — Postgres-backed background job queue

> **Note:** The write pipeline uses `Task.Supervisor` (built into OTP) for async batch
> inserts rather than Broadway. The ChannelServer already owns batching logic via its
> flush timer, so Broadway's producer/batcher abstraction adds unnecessary complexity
> at this stage. Broadway can be layered in later if back-pressure becomes necessary.

## Step 1: ChannelServer GenServer

The core of the real-time system. One GenServer process per active channel, running on a single node (distributed via Horde in Phase 3).

### 1.1 Process State

```
%ChannelServer{
  channel_id,
  channel_type,           # :channel | :dm
  messages: :queue.new(), # Bounded recent message queue
  message_count: 0,
  pending_writes: [],     # Messages awaiting persistence
  rate_limiters: %{},     # %{user_id => RateLimiter.t()}
  metadata: %{}           # Channel name, topic, member count
}
```

**Constants:**
- `@max_cached_messages 200` — bounded in-memory queue size
- `@idle_timeout 30 minutes` — hibernates after inactivity
- `@batch_interval 2 seconds` — flush pending writes to DB
- `@message_rate_limit [rate: 10, per: :second]` — per-user per-channel

### 1.2 Public API

- `start_link({channel_id, opts})` — starts GenServer, registered via `{:via, Registry, {Slackex.ChannelRegistry, channel_id}}`
- `send_message(channel_id, sender_id, content) :: {:ok, message} | {:error, reason}` — validates permissions, checks rate limit, generates Snowflake ID, sanitizes content, then: (1) adds to pending_writes, (2) appends to in-memory queue, (3) updates ETS cache, (4) broadcasts via PubSub to all subscribers
- `get_recent_messages(channel_id, limit \\ 50) :: [message]` — returns from in-memory queue

### 1.3 Key Callbacks

- **`init/1`** — rehydrates recent messages from cache/DB into bounded queue, schedules first batch flush
- **`handle_call(:send_message)`** — the core write path (validate → rate limit → generate ID → pending_writes → queue → cache → broadcast)
- **`handle_info(:batch_flush)`** — flushes `pending_writes` via `BatchWriter.async_insert_batch/2` with a caller reference for acknowledgment, reschedules timer
- **`handle_info({:batch_result, ref, result})`** — on `:ok`, clears acknowledged messages from `pending_writes`; on `{:error, _}`, messages are retained for retry on next flush
- **`handle_info(:timeout)`** — flushes remaining writes, then hibernates

### 1.4 Durability Contract

**At-most-once delivery guarantee:** Messages are broadcast to connected clients immediately upon acceptance by the ChannelServer, before durable persistence to PostgreSQL. This is a deliberate latency tradeoff — clients see messages in <10ms rather than waiting for a DB round-trip.

**Failure window:** If a node crashes between accepting a message and the next batch flush (up to 2 seconds), messages in `pending_writes` are lost. Connected clients may have already rendered these messages.

**Mitigations:**
1. **Batch flush acknowledgment:** `BatchWriter.async_insert_batch/2` reports success/failure back to the ChannelServer via `send(caller, {:batch_result, ref, result})`. On failure, the ChannelServer retains the messages in `pending_writes` and retries on the next flush cycle.
2. **Crash recovery on restart:** When a ChannelServer starts (or restarts after Horde failover in Phase 3), `init/1` compares the latest message IDs in cache (ETS/Redis) against the database. Any IDs present in cache but missing from the DB are re-persisted synchronously.
3. **Client-side gap detection:** Clients track the last received Snowflake ID. On reconnection, the catch-up mechanism (Phase 3) delivers missed messages from the DB. Messages lost before persistence will not appear in catch-up — this is the accepted tradeoff.
4. **Monitoring:** Emit `[:slackex, :pipeline, :batch_flush]` telemetry events with metadata `%{count, status, retry_count}` to track write failures and retries.

### 1.5 Message Broadcast

PubSub topic format:
```
channel: "channel:#{channel_id}"
dm:      "dm:#{dm_id}"
```

### 1.6 Channel Registry & Supervisor (Phase 2: Local)

In Phase 2, we use standard Elixir `Registry` (`:unique` keys) and `DynamicSupervisor`. Phase 3 replaces these with Horde.

`ChannelSupervisor.ensure_started(channel_id, opts)` — looks up via Registry, starts child if not found, handles `{:error, {:already_started, pid}}` race.

### 1.7 Messaging Context (`Slackex.Messaging`)

Boundary: `deps: [Slackex.Chat, Slackex.Accounts, Slackex.Cache, Slackex.Infrastructure], exports: [ChannelServer]`

Public API:
- `send_message(channel_id, sender_id, content, opts \\ [])` — ensures ChannelServer is started, delegates to it
- `get_recent_messages(channel_id, limit \\ 50)` — from ChannelServer if running, falls back to `Chat.list_messages/2`
- `subscribe_channel(channel_id)` — subscribes calling process to `"channel:#{channel_id}"`
- `unsubscribe_channel(channel_id)`
- `subscribe_dm(dm_id)`, `subscribe_user(user_id)`
- `broadcast_typing(channel_id, user)` — broadcasts `{:user_typing, user}` to channel topic
- `channel_count() :: non_neg_integer()` — returns the number of active ChannelServer processes (delegates to ChannelSupervisor/Horde). Used by health endpoints without exposing ChannelSupervisor outside the boundary.

## Step 2: Async Write Pipeline

The ChannelServer accumulates messages in `pending_writes` and flushes them on a 2-second timer. The flush dispatches an async task via `Task.Supervisor` to batch-insert into PostgreSQL. This keeps the ChannelServer non-blocking while ensuring durable persistence.

### 2.1 Batch Writer (`Slackex.Pipeline.BatchWriter`)

**Single-writer invariant:** Each ChannelServer is the single writer for its channel. Concurrent writes from different channels are safe (different rows).

Public API:
- `insert_batch(messages) :: {:ok, count} | {:error, term}` — single `Repo.insert_all("messages", entries, on_conflict: :nothing)` for the batch. No `conflict_target` is specified — `ON CONFLICT DO NOTHING` catches any unique constraint violation, which remains correct after Phase 3 changes the PK to `(id, inserted_at)` for partitioning
- `async_insert_batch(messages, caller_ref)` — dispatches via `Task.Supervisor.start_child(Slackex.WriteSupervisor, ...)`, sending `{:batch_result, ref, :ok | {:error, reason}}` to the caller on completion. On success, the ChannelServer clears those messages from `pending_writes`. On failure, messages are retained for retry on the next flush cycle. Messages also remain in ETS cache as a secondary recovery source.

### 2.2 Pipeline Boundary

`Slackex.Pipeline` — `deps: [Slackex.Chat, Slackex.Repo], exports: [BatchWriter]`

## Step 3: ETS Local Cache

### 3.1 Cache Manager (`Slackex.Cache.Local`)

GenServer that owns an ETS table (`:set`, `:public`, `:named_table`, `read_concurrency: true`, `write_concurrency: true`).

**Single-writer invariant for ETS:** Only ChannelServer processes call `put_message/2` for their `channel_id`. Since each channel has exactly one ChannelServer (enforced by Registry/Horde), this guarantees single-writer semantics per channel and eliminates ETS TOCTOU races in the read-then-write pattern.

**Constants:** `@max_channels 1_000`, `@max_messages_per_channel 200`

Public API:
- `put_message(channel_id, message) :: :ok` — prepends to channel's message list, trims to max
- `get_messages(channel_id) :: {:ok, [message]}` — returns messages in chronological order
- `invalidate(channel_id) :: :ok` — deletes channel's cache entry
- `stats() :: %{memory_bytes: integer, size: integer}` — ETS table stats

### 3.2 Cache Boundary

`Slackex.Cache` — `deps: [], exports: [Local]`

Phase 2 cascade: ETS → Postgres (Redis added in Phase 3).

## Step 4: Phoenix Presence

### 4.1 Presence Module

`SlackexWeb.Presence` — standard `use Phoenix.Presence` with `pubsub_server: Slackex.PubSub`.

### 4.2 Presence Tracking in LiveView

On `activate_channel/2`:
- Track presence on topic `"channel_presence:#{channel.id}"` with `%{username, joined_at}`
- Get current presence list and assign to socket
- Handle `presence_diff` broadcasts to sync presence state

### 4.3 Typing Indicators

- LiveView `"typing"` event calls `Messaging.broadcast_typing/2`
- JS hook debounces input events (2-second cooldown between typing broadcasts)
- Server auto-clears typing indicator after 3 seconds via `Process.send_after/3`

## Step 5: Scroll-Based History Pagination

### 5.1 MessageList JS Hook

Responsibilities:
- Track whether user is at bottom of scroll (`isAtBottom`)
- On scroll near top (< 100px): push `"load_more"` event with oldest visible message ID
- On update: auto-scroll to bottom only if user was already at bottom

### 5.2 History Loader (`Slackex.Search.HistoryLoader`)

CQRS read side — loads message history from the cache cascade (ETS → Postgres in Phase 2, Redis added in Phase 3).

Public API:
- `recent(channel_id, limit \\ 50)` — checks cache first, falls through to DB on miss, backfills cache from DB results
- `before(channel_id, before_id, limit \\ 50)` — always from DB (older messages not worth caching)

## Step 6: Update LiveView to Use CQRS

Modify `ChatLive.Index`:
- Replace `Chat.send_message/3` with `Messaging.send_message/3` (routes through ChannelServer)
- Replace `Chat.list_messages/2` with `HistoryLoader.recent/2` (cache cascade)
- Add `"load_more"` handler that calls `HistoryLoader.before/3` and stream-inserts at position 0

## Step 7: Oban Setup (Background Jobs)

### 7.1 Configuration

- Queues: `default: 10`, `notifications: 20`, `embeddings: 5` (Phase 4)
- Plugins: `Oban.Plugins.Pruner` (clean old jobs), `Oban.Plugins.Cron` with `CacheWarmer` hourly
- Test config: `testing: :inline` for synchronous execution

### 7.2 Oban Migration

Run `mix ecto.gen.migration add_oban_jobs_table`, call `Oban.Migration.up(version: 12)` in `up/0`.

### 7.3 Cache Warmer Worker

`Slackex.Workers.CacheWarmer` — Oban worker (queue: default, max_attempts: 1). Finds channels with activity in the last hour, ensures their ChannelServer is started (which rehydrates cache on init).

## Step 8: Update Application Supervisor

Children added to Phase 1 supervisor (in order):
1. `Slackex.Repo`
2. `{Phoenix.PubSub, name: Slackex.PubSub}`
3. `SlackexWeb.Presence` — **new**
4. `Slackex.Infrastructure.Snowflake`
5. `Slackex.Cache.Local` — **new**
6. `{Registry, keys: :unique, name: Slackex.ChannelRegistry}` — **new**
7. `Slackex.Messaging.ChannelSupervisor` — **new**
8. `{Task.Supervisor, name: Slackex.WriteSupervisor}` — **new**
9. `{Oban, Application.fetch_env!(:slackex, Oban)}` — **new**
10. `SlackexWeb.Endpoint` (must be last)

## Step 9: Updated Boundary Definitions

- `Slackex.Messaging` — deps: `[Chat, Accounts, Cache, Infrastructure]`, exports: `[ChannelServer]`
- `Slackex.Pipeline` — deps: `[Chat, Repo]`, exports: `[BatchWriter]`
- `Slackex.Search` — deps: `[Chat, Cache]`, exports: `[HistoryLoader]`
- `Slackex.Cache` — deps: `[]`, exports: `[Local]`

## Phase 2 Acceptance Criteria

- [ ] ChannelServer GenServer starts on first message to a channel
- [ ] Messages are broadcast immediately via PubSub (< 10ms latency)
- [ ] Messages are persisted asynchronously via Task.Supervisor batch writes
- [ ] In-memory message queue is bounded at 200 messages per channel
- [ ] ChannelServer hibernates after 30 minutes of inactivity
- [ ] ETS cache serves recent messages without hitting PostgreSQL
- [ ] Cache miss falls through to PostgreSQL transparently
- [ ] Phoenix Presence shows online users per channel
- [ ] Typing indicators appear and auto-clear after 3 seconds
- [ ] Scroll-up loads older messages via paginated DB query
- [ ] Auto-scroll to bottom on new messages (only if already at bottom)
- [ ] Oban is configured and the cache warmer runs hourly
- [ ] Batch writes group pending messages per flush interval (2s)
- [ ] Rate limiting prevents >10 messages/second per user per channel
- [ ] DM sender is validated as a participant (not just any authenticated user)
- [ ] All boundary constraints compile without warnings
- [ ] All behavioral tests from Phase 1 still pass
- [ ] New behavioral tests cover: GenServer message flow, cache hit/miss, presence, typing
