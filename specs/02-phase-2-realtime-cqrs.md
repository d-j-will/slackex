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
  pending_writes: [],     # Messages awaiting persistence (bounded, see @max_pending_writes)
  in_flight: %{},         # %{batch_ref => [messages]} — batches dispatched but not yet acknowledged
  rate_limiters: %{},     # %{user_id => RateLimiter.t()} — pruned on idle (see below)
  metadata: %{}           # Channel name, topic, member count
}
```

**Constants:**
- `@max_cached_messages 200` — bounded in-memory queue size
- `@idle_timeout 30 minutes` — hibernates after inactivity
- `@batch_interval 2 seconds` — flush pending writes to DB
- `@message_rate_limit [rate: 10, per: :second]` — per-user per-channel
- `@rate_limiter_prune_interval 5 minutes` — periodic sweep (via `Process.send_after`) removes `rate_limiters` entries whose `last_refill` is older than 5 minutes. This prevents unbounded memory growth in high-churn channels where many distinct users send messages over time. The `rate_limiters` map grows independently of `pending_writes` — even with successful flushes, a new entry is created for each unique user who sends a message. Without pruning, a public channel with 10,000 distinct users over its lifetime would accumulate 10,000 stale entries. With 5-minute pruning, only users active in the last 5 minutes are retained. Upper bound with pruning: at max rate (10 msg/s) × 300 seconds = ~3,000 unique users in the worst case × ~100 bytes ≈ ~300KB per ChannelServer — well within acceptable bounds
- `@max_pending_writes 1_000` — **per-ChannelServer** backpressure cap on pending writes. When reached, `send_message` returns `{:error, :backpressure}` and the message is rejected (not queued). This prevents unbounded memory growth during sustained DB outages. At max rate (10 msg/s per user), a single channel fills to 1,000 pending writes in ~100 seconds of sustained DB unavailability. Per-node memory budget: the number of active ChannelServers is naturally bounded by the idle timeout (30 min) — only channels with recent activity have live processes. Under extreme load, assume ~1,000 concurrent active channels per node × 1,000 pending writes × ~1KB per message map ≈ ~1GB worst case. Note: `@max_channels` in `Cache.Local` is an ETS eviction threshold, not a ChannelServer admission cap — there is no hard limit on concurrent ChannelServer processes (they are bounded by idle timeout and available memory).

### 1.2 Public API

- `start_link({channel_id, opts})` — starts GenServer, registered via `{:via, Registry, {Slackex.Messaging.ChannelRegistry, {:channel, channel_id}}}` for channels or `{:via, Registry, {Slackex.Messaging.ChannelRegistry, {:dm, dm_id}}}` for DMs. The composite key `{type, id}` prevents collisions if channel IDs and DM conversation IDs overlap numerically (they share no DB uniqueness constraint across tables)
- `send_message(channel_id, sender_id, content) :: {:ok, message} | {:error, reason}` — validates permissions, checks rate limit, generates Snowflake ID, sanitizes content, then: (1) adds to pending_writes, (2) appends to in-memory queue, (3) updates ETS cache, (4) broadcasts via PubSub to all subscribers
- `get_recent_messages(channel_id, limit \\ 50) :: [message]` — returns from in-memory queue

### 1.3 Key Callbacks

- **`init/1`** — rehydrates recent messages from cache/DB into bounded queue, schedules first batch flush
- **`handle_call(:send_message)`** — the core write path (validate → rate limit → generate ID → pending_writes → queue → cache → broadcast)
- **`handle_info(:batch_flush)`** — snapshots `pending_writes` into a batch with a unique `batch_ref`, moves those messages from `pending_writes` to `in_flight` map (`%{batch_ref => [messages]}`), flushes via `BatchWriter.async_insert_batch/2` with the `batch_ref`, reschedules timer. New messages arriving during flush are added to `pending_writes` (not the in-flight batch), preventing overlap corruption
- **`handle_info({:batch_result, ref, result})`** — on `:ok`, removes the batch from `in_flight` map by `ref` (the specific messages are known — no risk of clearing wrong entries); on `{:error, _}`, moves the batch's messages back to `pending_writes` for retry on next flush with incremented `retry_count`. After `@max_flush_retries` (default 10) consecutive failures for a batch, the messages are dropped entirely and a `[:slackex, :pipeline, :writes_dropped]` telemetry event is emitted with `%{count, channel_id, reason}`
- **`handle_info(:timeout)`** — flushes remaining writes, then hibernates

### 1.4 Durability Contract

**At-most-once delivery guarantee:** Messages are broadcast to connected clients immediately upon acceptance by the ChannelServer, before durable persistence to PostgreSQL. This is a deliberate latency tradeoff — clients see messages in <10ms rather than waiting for a DB round-trip.

**Failure window:** If a node crashes between accepting a message and the next batch flush (up to 2 seconds), messages in `pending_writes` are lost. Connected clients may have already rendered these messages.

**Product-level SLO:** Message durability target is **99.99%** under normal operation (no node crashes, database healthy). Loss scenarios:
- **Node crash:** Up to 2 seconds of messages (one flush interval) in `pending_writes` are lost.
- **Sustained DB failure:** After `@max_flush_retries` (10) consecutive failed flushes for a batch (~20 seconds at 2s intervals), that batch is dropped and a `[:slackex, :pipeline, :writes_dropped]` telemetry event is emitted. This is a deliberate circuit-breaker to prevent unbounded memory growth — without it, a prolonged DB outage would accumulate pending writes until OOM.
- **Backpressure cap:** If `pending_writes` reaches `@max_pending_writes` (1,000), new messages are rejected with `{:error, :backpressure}` (not silently dropped — the sender knows).

**Monitoring and alerting:** The `writes_dropped` telemetry event must trigger a high-priority alert. In production, DB failures lasting >20 seconds should be exceedingly rare. If this SLO proves insufficient, the architecture supports upgrading to a durable dead-letter queue (Oban job per failed batch) at the cost of additional DB load during recovery.

This is an explicit product tradeoff accepted for <10ms delivery latency. User-facing behavior: messages that vanish after a crash or drop are not re-shown to other users on reload. Clients should treat messages as "optimistic" until they appear in scroll-back history (which is always read from the durable DB). The architecture supports upgrading to at-least-once semantics by making the flush synchronous (at the cost of ~5-20ms additional latency per message).

**Mitigations:**
1. **Batch flush acknowledgment:** `BatchWriter.async_insert_batch/2` reports success/failure back to the ChannelServer via `send(caller, {:batch_result, ref, result})`. On failure, the ChannelServer retains the messages in `pending_writes` and retries on the next flush cycle.
2. **Crash recovery on restart:** When a ChannelServer process crashes and restarts on the same node, `init/1` compares the latest message IDs in ETS cache against the database. Any IDs present in cache but missing from the DB are re-persisted synchronously. **Important limitation (Phase 2 only):** ETS is node-local memory — if the entire BEAM node crashes (not just the ChannelServer process), ETS data is lost and this recovery path cannot reclaim un-persisted messages. This is the accepted durability gap for Phase 2. In Phase 3+, Redis (which survives node crashes) is added to the cache cascade, making crash recovery effective for node-level failures as well.
3. **Client-side gap detection:** Clients track the last received Snowflake ID. On reconnection, the catch-up mechanism (Phase 3) delivers missed messages from the DB. Messages lost before persistence will not appear in catch-up — this is the accepted tradeoff.
4. **Monitoring:** Emit `[:slackex, :pipeline, :batch_flush]` telemetry events with metadata `%{count, status, retry_count}` to track write failures and retries.

### 1.5 Message Broadcast

PubSub topic format:
```
channel: "channel:#{channel_id}"
dm:      "dm:#{dm_id}"
```

Contract rule: all client-visible realtime payloads use a versioned envelope so web/mobile clients share one protocol:
```elixir
%{
  v: 1,
  event: "message.new" | "message.ack" | "typing" | "presence.diff" | ...,
  target: %{type: :channel | :dm, id: integer()},
  payload: map(),
  meta: %{sent_at: DateTime.t(), correlation_id: String.t() | nil}
}
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

**Single-writer invariant (best-effort):** Each ChannelServer is the single writer for its channel. Concurrent writes from different channels are safe (different rows). In Phase 2 (single-node), this is enforced by Registry's `:unique` keys. In Phase 3 (Horde), this is **best-effort** — Horde's CRDT-based registry is eventually consistent, so during a network partition, two ChannelServers for the same channel can briefly coexist (split-brain). See Phase 3 for the fencing strategy that makes writes safe under this condition.

Public API:
- `insert_batch(messages) :: {:ok, count} | {:error, term}` — maps each message to a row map, **deriving `inserted_at` from the Snowflake ID** via `Snowflake.extract_timestamp/1` (not relying on Ecto timestamps or DB defaults). This is critical because `insert_all` bypasses Ecto changesets — without explicit derivation, `inserted_at` would be nil or inconsistent, breaking partition placement and `ON CONFLICT DO NOTHING` dedup safety after Phase 3 partitioning. Executes a single `Repo.insert_all("messages", entries, on_conflict: :nothing)` for the batch. No `conflict_target` is specified — `ON CONFLICT DO NOTHING` catches any unique constraint violation, which remains correct after Phase 3 changes the PK to `(id, inserted_at)` for partitioning
- `async_insert_batch(messages, caller_ref)` — dispatches via `Task.Supervisor.start_child(Slackex.WriteSupervisor, ...)`, sending `{:batch_result, ref, :ok | {:error, reason}}` to the caller on completion. On success, the ChannelServer removes the batch from its `in_flight` map. On failure, messages are moved back to `pending_writes` for retry on the next flush cycle. Messages also remain in ETS cache as a secondary recovery source. **Phase 3 evolution:** Both `insert_batch` and `async_insert_batch` gain required `epoch:`, `type:` (`:channel` | `:dm`), and `id:` (channel or DM conversation ID) options for writer fencing — see Phase 3 Step 2.2. The epoch check and insert execute atomically within a single transaction. Phase 2's epoch-less arities are removed in Phase 3.

### 2.2 Pipeline Boundary

`Slackex.Pipeline` — `deps: [Slackex.Chat, Slackex.Repo], exports: [BatchWriter]`

## Step 3: ETS Local Cache

### 3.1 Cache Manager (`Slackex.Cache.Local`)

GenServer that owns an ETS table (`:set`, `:public`, `:named_table`, `read_concurrency: true`, `write_concurrency: true`).

**Single-writer invariant for ETS (local node):** Only ChannelServer processes call `put_message/2` for their `channel_id`. In Phase 2 (single-node), Registry enforces exactly one ChannelServer per channel. In Phase 3 (distributed), Horde provides this as a best-effort guarantee — see Phase 3 fencing strategy for split-brain safety. ETS is node-local so concurrent writes from different nodes don't conflict at the ETS level, only at the PostgreSQL level (where fencing applies).

**Constants:** `@max_channels 1_000` (LRU eviction threshold — when exceeded, the oldest-accessed channel's cache is evicted; this is a **cache manager limit**, not a ChannelServer admission cap), `@max_messages_per_channel 200`

Public API (all keys are target-aware tuples `{:channel, id}` or `{:dm, id}` to prevent collisions — see Section 1.2):
- `put_message(target, message) :: :ok` — where `target` is `{:channel, id}` or `{:dm, id}`. Prepends to target's message list, trims to max
- `get_messages(target) :: {:ok, [message]}` — returns messages in chronological order
- `invalidate(target) :: :ok` — deletes target's cache entry
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

Public API (all functions accept a `target` tuple `{:channel, id}` or `{:dm, id}` — consistent with cache and registry keys):
- `recent(target, limit \\ 50)` — checks cache first (using target tuple as key), falls through to DB on miss, backfills cache from DB results
- `before(target, before_id, limit \\ 50)` — always from DB (older messages not worth caching). **Partition-aware (Phase 3+):** Derives an `inserted_at` upper bound from `before_id` via `Snowflake.extract_timestamp/1` and includes it in the WHERE clause (`inserted_at <= ?`) to enable PostgreSQL partition pruning on the time-partitioned messages table.

## Step 6: Update All Write Paths to Use CQRS

### 6.1 Update LiveView

Modify `ChatLive.Index`:
- Replace `Chat.send_message/3` with `Messaging.send_message/3` (routes through ChannelServer)
- Replace `Chat.list_messages/2` with `HistoryLoader.recent/2` (cache cascade)
- Add `"load_more"` handler that calls `HistoryLoader.before/3` and stream-inserts at position 0

### 6.2 Update Mobile ChatChannel

Modify `SlackexWeb.ChatChannel`:
- Replace `Chat.send_message/3` with `Messaging.send_message/3` in `handle_in("new_message", ...)` — routes through ChannelServer for rate limiting, caching, and batch persistence
- Replace direct DB reads with `HistoryLoader.recent/2` for the initial message payload on `join/3`

**Rationale:** All write paths **must** route through `Messaging` to ensure consistent rate limiting, caching, write batching, and (in Phase 3) writer-epoch fencing. Leaving any channel on `Chat.send_message/3` or `Chat.send_dm/3` would bypass all of these guarantees, creating a behavioral divergence between clients.

### 6.3 Update DM Write Paths

DM messages must also route through the CQRS pipeline — a ChannelServer with `channel_type: :dm` manages each active DM conversation identically to channels (same batching, rate limiting, caching, and fencing).

Modify all DM write paths:
- **LiveView:** Replace `Chat.send_dm/3` with `Messaging.send_dm/3` — which calls `ChannelSupervisor.ensure_started({:dm, dm_id}, ...)` and delegates to the DM's ChannelServer
- **Mobile DMChannel (`SlackexWeb.DMChannel`):** Replace `Chat.send_dm/3` with `Messaging.send_dm/3` in `handle_in("new_message", ...)`
- **DM reads:** Replace direct DB reads with `HistoryLoader.recent/2` (using the DM conversation ID)

**Messaging context DM API additions:**
- `send_dm(dm_id, sender_id, content, opts \\ [])` — validates sender is a DM participant, ensures ChannelServer (type: `:dm`) is started, delegates to it
- `subscribe_dm(dm_id)` — subscribes calling process to `"dm:#{dm_id}"`

### 6.4 Write Outcome Contract (Cross-Client Consistency)

All write paths (`Messaging.send_message/4`, `Messaging.send_dm/4`) return normalized outcomes consumed identically by LiveView, mobile, and future SPA clients:

- Success: `{:ok, message}`
- Rejection outcomes: `{:error, :rate_limited | :backpressure | :not_writer | :unauthorized | :invalid_content}`

Channel handlers translate these outcomes into stable client events/errors without client-specific branching in domain code.
The contract tests (`@tag :contract`, see `06-testing-strategy.md`) serve as the canonical, executable specification of the realtime protocol — no separate documentation file is needed.

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
6. `{Registry, keys: :unique, name: Slackex.Messaging.ChannelRegistry}` — **new**
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

### Steps 1-3: CQRS Foundation (ChannelServer + BatchWriter + Cache) — COMPLETE

- [x] ChannelServer GenServer starts on first message to a channel
- [x] Messages are broadcast immediately via PubSub (< 10ms latency)
- [x] Messages are persisted asynchronously via Task.Supervisor batch writes
- [x] In-memory message queue is bounded at 200 messages per channel
- [x] ChannelServer hibernates after 30 minutes of inactivity
- [x] ETS cache serves recent messages without hitting PostgreSQL
- [x] Cache miss falls through to PostgreSQL transparently
- [x] Batch writes group pending messages per flush interval (2s)
- [x] Rate limiting prevents >10 messages/second per user per channel
- [x] DM sender is validated as a participant (not just any authenticated user)
- [x] All behavioral tests from Phase 1 still pass
- [x] New behavioral tests cover: GenServer message flow, cache hit/miss, rate limiting, batch persistence

### Steps 4-7: Presence, HistoryLoader, Oban, Write Path Migration — COMPLETE

- [x] Phoenix Presence shows online users per channel
- [x] Typing indicators broadcast via Messaging.broadcast_typing/2
- [x] Scroll-up loads older messages via HistoryLoader.before/3 paginated DB query
- [x] Oban is configured and the cache warmer runs hourly
- [x] ChatChannel and DMChannel write paths route through Messaging context (ChannelServer → BatchWriter)
- [x] Duplicate broadcast eliminated (ChannelServer broadcasts via PubSub, channels subscribe and push)
- [x] All boundary constraints compile without warnings
- [x] New behavioral tests cover: presence, typing, HistoryLoader cache cascade, CacheWarmer, write path migration

### Steps 8-9: Remaining

- [ ] Auto-scroll to bottom on new messages (only if already at bottom) — requires LiveView/JS hook
- [ ] Realtime payloads follow versioned `v1` envelope contract shared across web/mobile clients
- [ ] Write rejection semantics are normalized (`rate_limited`, `backpressure`, `not_writer`, etc.) and exposed consistently to clients
