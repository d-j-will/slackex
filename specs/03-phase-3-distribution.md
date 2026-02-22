# Phase 3 — Distribution & Scale

## Goal

Transform the single-node application into a distributed BEAM cluster. Replace local Registry and DynamicSupervisor with Horde for automatic process distribution and failover. Add Redis as a cross-node cache layer. Implement push notifications for mobile. Partition the messages table by time for query performance at scale.

## Prerequisites

Phase 2 complete and all acceptance criteria met.

## Dependencies Added

| Library | Version | Purpose |
|---------|---------|---------|
| horde | ~> 0.9 | CRDT-based distributed Registry + DynamicSupervisor |
| libcluster | ~> 3.4 | Automatic BEAM cluster formation |
| redix | ~> 1.5 | Redis driver |
| pigeon | ~> 2.0 | Push notifications (FCM/APNs) |
| nimble_pool | ~> 1.1 | Connection pooling for Redix |

## Step 1: libcluster — Node Discovery

### 1.1 Configuration

```elixir
# Dev: Gossip strategy for local multi-node dev
config :libcluster,
  topologies: [gossip: [strategy: Cluster.Strategy.Gossip, config: [port: 45892]]]

# Prod: Kubernetes DNS strategy
config :libcluster,
  topologies: [k8s_dns: [strategy: Cluster.Strategy.Kubernetes.DNS,
    config: [service: "slackex-headless", application_name: "slackex", polling_interval: 5_000]]]

# Test: No clustering (use LocalCluster for explicit tests)
config :libcluster, topologies: []
```

### 1.2 Node Listener

`Slackex.NodeListener` — GenServer that monitors node connections/disconnections via `:net_kernel.monitor_nodes/2`. Logs join/leave events. Used for observability and Horde membership sync.

## Step 2: Horde — Distributed Process Management

### 2.1 Replace Registry with Horde.Registry

`Slackex.Messaging.ChannelRegistry` — wraps `Horde.Registry` with `members: :auto` for auto-discovery via libcluster. Targets **at most one** ChannelServer process per channel across the cluster using delta-CRDTs for eventually consistent membership. **Note:** This is a best-effort guarantee, not a hard invariant — during network partitions, Horde's CRDT convergence delay can temporarily allow two processes for the same key (see Section 2.2 Writer Fencing for the safety mechanism that handles this).

Public API:
- `lookup(channel_id) :: {:ok, pid} | :not_found`
- `via(channel_id)` — returns `{:via, Horde.Registry, {__MODULE__, {:channel, channel_id}}}` tuple
- `via_dm(dm_id)` — returns `{:via, Horde.Registry, {__MODULE__, {:dm, dm_id}}}` tuple

Registry keys are composite tuples `{:channel, id}` / `{:dm, id}` to prevent collisions between channel IDs and DM conversation IDs (which are auto-increment IDs from separate tables and can overlap numerically).

### 2.2 Writer Fencing (Split-Brain Safety)

Horde's CRDT-based registry is eventually consistent. During a network partition, two nodes may each start a ChannelServer for the same channel, violating the single-writer invariant and producing divergent writes, duplicate rate-limit state, and message ordering conflicts.

**Fencing strategy — writer epoch:**
1. Each ChannelServer acquires a **writer epoch** on startup by atomically incrementing a counter in PostgreSQL. For channel-type servers: `UPDATE channels SET writer_epoch = writer_epoch + 1 WHERE id = $1 RETURNING writer_epoch`. For DM-type servers: `UPDATE dm_conversations SET writer_epoch = writer_epoch + 1 WHERE id = $1 RETURNING writer_epoch`. The epoch is stored in ChannelServer state.
2. **Phase 3 API change:** `BatchWriter.insert_batch/2` gains a required second parameter — `insert_batch(messages, epoch: epoch, type: :channel | :dm, id: id)`. The epoch is **not optional** — callers must provide it (enforced by pattern match, not default value). The epoch check and batch insert are executed as a **single atomic database transaction** to eliminate TOCTOU race conditions:
   ```elixir
   Repo.transaction(fn ->
     # Row-lock + epoch check in one query
     case Repo.query!("SELECT writer_epoch FROM channels WHERE id = $1 FOR UPDATE", [id]) do
       %{rows: [[db_epoch]]} when db_epoch > caller_epoch ->
         Repo.rollback(:epoch_stale)
       _ ->
         Repo.insert_all("messages", entries, on_conflict: :nothing)
     end
   end)
   ```
   The `FOR UPDATE` row lock prevents concurrent writers from interleaving between the epoch check and the insert within the same transaction. If the DB epoch is higher than the caller's epoch, the transaction is rolled back with `{:error, :epoch_stale}`. Phase 2's `insert_batch/1` arity is removed in Phase 3 to prevent unguarded writes.
3. On Horde conflict resolution (when the partition heals and CRDTs converge), the losing ChannelServer is terminated. Its pending writes will fail the epoch check. The winning ChannelServer's writes succeed.
4. **Snowflake IDs remain unique** regardless of split-brain (different nodes have different node_id bits), so `ON CONFLICT DO NOTHING` safely deduplicates any overlapping writes.

**Migration:** Add `writer_epoch` integer column (default 0, NOT NULL) to both `channels` and `dm_conversations` tables in Phase 3.

> **Note:** This makes the single-writer invariant **verifiable** rather than merely assumed.
> Rate limiters may briefly allow excess throughput during split-brain (two ChannelServers
> each tracking independent state), but this is bounded by the partition duration and
> is an acceptable tradeoff vs. the complexity of distributed rate limiting.

**Ghost messages during split-brain:** Because the ChannelServer broadcasts messages to connected clients immediately (before batch flush), a stale writer on the losing partition side can broadcast messages that later fail the epoch check and are never persisted. Connected clients will see these messages appear and then vanish on reload. This is an **accepted tradeoff** — it falls within the existing durability contract (at-most-once delivery, Phase 2 Section 1.4). Mitigation: clients should treat messages as optimistic until they appear in scroll-back history. The ghost window is bounded by the partition duration + one flush interval (2s). Post-heal, the stale writer is terminated by Horde conflict resolution, stopping further ghost broadcasts.

**Epoch-stale is terminal:** When `BatchWriter` returns `{:error, :epoch_stale}`, the ChannelServer must treat this as a **non-retryable terminal error** — unlike generic batch errors which are retried (Phase 2 Section 1.3). On receiving `:epoch_stale`, the ChannelServer: (1) stops accepting new `send_message` calls (returns `{:error, :not_writer}`), (2) drops all `pending_writes` and `in_flight` batches (they will never persist), (3) emits `[:slackex, :channel_server, :epoch_stale_shutdown]` telemetry, and (4) terminates itself via `{:stop, :normal, state}`. This prevents a stale writer from continuing to broadcast ghost messages after its first failed flush. Horde will not restart the process on this node since the winning writer already holds the registry entry.

### 2.3 Replace DynamicSupervisor with Horde.DynamicSupervisor

`Slackex.Messaging.ChannelSupervisor` — wraps `Horde.DynamicSupervisor` with `process_redistribution: :active` to rebalance on node changes.

Public API:
- `ensure_started(channel_id, opts \\ [])` — cluster-wide lookup then start. Same API as Phase 2 but now distributed.
- `count()` — active channel processes across the cluster

### 2.4 Update ChannelServer

Change `via/1` from `{:via, Registry, ...}` to `Slackex.Messaging.ChannelRegistry.via(channel_id)`.

### 2.5 Process Handoff on Node Down

Horde automatically restarts affected processes on surviving nodes. ChannelServer's `init/1` rehydrates from cache/DB.

**Best-effort flush on graceful shutdown:** Add a `terminate/2` callback that does a **synchronous** `BatchWriter.insert_batch(messages, epoch: epoch, type: channel_type, id: channel_id)` flush of pending writes (not async — the process is about to die). The epoch check still applies — if a newer writer has taken over, the flush is safely rejected. This handles graceful shutdowns (rolling deploys, manual stop) but **not** abrupt node failures (hardware crash, OOM kill, network partition) where `terminate/2` is not guaranteed to run.

**Crash recovery in init/1:** On startup, the ChannelServer must reconcile cache state against the database:
1. Load the latest N messages (full payloads, not just IDs) from cache (ETS/Redis) for this channel — the cache stores complete message structs, so all fields needed for re-persistence are available
2. Query the database for which of those message IDs exist
3. Re-persist any messages found in cache but missing from the DB via synchronous `BatchWriter.insert_batch(messages, epoch: epoch, type: channel_type, id: channel_id)` (using the freshly acquired epoch from this ChannelServer's startup). The full message payloads from cache provide all required columns (sender_id, content, inserted_at, etc.)
4. This closes the durability gap for messages that were cached but not yet flushed when the previous process died

**Monitoring:** Emit `[:slackex, :channel_server, :crash_recovery]` telemetry with `%{channel_id, recovered_count}` to track how often crash recovery finds un-persisted messages.

## Step 3: Redis — Cross-Node Cache

### 3.1 Redis Connection Pool (`Slackex.Cache.Redis`)

Supervisor that starts a pool of 10 Redix connections. Commands are dispatched to a random connection. All Redis commands are wrapped with `rescue` to gracefully degrade when Redis is unavailable — the system falls through to Postgres.

Public API (all functions accept a `target` tuple `{:channel, id}` or `{:dm, id}` — Redis keys are namespaced as `msgs:channel:{id}` or `msgs:dm:{id}` to prevent collisions between channel and DM IDs):
- `get_messages(target) :: {:ok, [message]} | {:miss, []}` — `LRANGE` last 200 messages
- `push_message(target, message)` — `RPUSH` + `LTRIM` to 200 + `EXPIRE` 1 hour
- `cache_messages(target, messages)` — bulk backfill (`DEL` + `RPUSH` + `EXPIRE`)
- `set_read_cursor(user_id, target, message_id)` — `SET` with 24h TTL (key: `cursor:{user_id}:channel:{id}` or `cursor:{user_id}:dm:{id}`)
- `get_read_cursor(user_id, target) :: {:ok, integer} | :miss`
- `invalidate(target)` — `DEL`

### 3.2 Three-Tier Cache Cascade

Update `Slackex.Cache` boundary — `deps: [], exports: [Local, Redis]`

```
Read path:
  1. ETS (local node) — ~0.01ms
  2. Redis (cross-node) — ~0.5-2ms → backfills ETS on hit
  3. Returns :miss if both miss (caller falls through to DB)

Write path (write-through with timeout degradation):
  Cache.put_message → Local.put_message + Redis.push_message

  Redis writes use a 100ms timeout (Redix :timeout option). On timeout
  or connection error, the write is logged via telemetry
  ([:slackex, :cache, :redis_write_timeout]) and silently dropped —
  ETS remains the authoritative hot cache, and the next read-miss will
  backfill Redis from DB. This prevents a slow or partitioned Redis
  from adding latency to the message broadcast path.
```

### 3.3 Update ChannelServer Cache Writes

Replace `Cache.Local.put_message(...)` with `Cache.put_message(...)` (writes through to both ETS and Redis).

### 3.4 Update HistoryLoader

On cache miss, load from DB and backfill both Redis (`cache_messages`) and ETS (`put_message` per message).

## Step 3.5: Read Replica Support

### 3.5.1 ReadRepo Module

`Slackex.ReadRepo` — `use Ecto.Repo` with `read_only: true`. Falls back to primary database if `DATABASE_READ_URL` is not configured.

### 3.5.2 Query Routing

| Query | Repo | Reason |
|-------|------|--------|
| `Chat.list_messages/2` (older history) | `repo_for_age(oldest_id)` | See routing function below |
| `Chat.list_user_channels/1` | ReadRepo | Channel list doesn't change often |
| `Chat.list_public_channels/0` | ReadRepo | Read-only listing |
| `Chat.unread_count/2` | Primary | Unread count must reflect recently sent messages (see consistency rules below) |
| `Search.MessageSearch.*` | ReadRepo | All search is read-only |
| `Chat.get_role/2` | Primary | Authorization before writes |
| `Chat.send_message/3` | Primary | Write operation |
| `Chat.create_channel/2` | Primary | Write operation |
| `Chat.mark_as_read/2` | Primary | Write (upsert) |
| `Chat.join_channel/2` | Primary | Write |
| `CatchupServer.build_catchup/1` | Primary | Recent messages — must not miss data from replication lag |
| `HistoryLoader.recent/2` (cache miss) | Primary | Initial channel load — user expects to see latest messages |

**Hard routing contract — `Slackex.ReadRepo.repo_for_age/1`:** A single function that encapsulates the replica-vs-primary decision so callers cannot accidentally pick the wrong repo. Takes a Snowflake ID (or `:recent` atom) and returns `ReadRepo` or `Repo`:

```elixir
def repo_for_age(:recent), do: Repo
def repo_for_age(snowflake_id) do
  if lag_exceeded?() do
    Repo  # replica is behind — all reads go to primary
  else
    age_ms = System.os_time(:millisecond) - Snowflake.extract_timestamp(snowflake_id)
    if age_ms < @recent_threshold_ms, do: Repo, else: ReadRepo
  end
end
```

`@recent_threshold_ms` defaults to 30_000 (30 seconds). The `lag_exceeded?()` check is evaluated **first** — when lag is detected, the function short-circuits to `Repo` regardless of message age. Only when lag is within bounds does the age-based branch apply. Callers like `Chat.list_messages/2` pass the oldest requested Snowflake ID; callers like `HistoryLoader.recent/2` pass `:recent`. This eliminates the risk of a caller accidentally reading stale data from the replica.

**Consistency rules:**
- **Recent window (< 30 seconds old):** Always read from Primary. This covers reconnection catch-up, initial channel load, and unread count after sending a message. Replication lag in this window would cause users to "miss" messages they just sent or received.
- **Older history (scroll-up pagination):** ReadRepo is safe — the data is stable and replication lag is imperceptible for older messages.
- **Search:** ReadRepo is acceptable — search results being a few seconds behind is tolerable.
- **Lag detection fallback:** A periodic check (every 5 seconds via `Process.send_after`) queries the replica for replication lag using `SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))::float`. This returns the number of seconds since the last replayed transaction — a direct measure of how stale the replica is. If lag exceeds 5 seconds, all `ReadRepo` queries automatically fall back to Primary until the next check shows recovery. Emit `[:slackex, :read_repo, :lag_fallback]` telemetry with `%{lag_seconds: float}`. **Guard: no-replica mode.** When `DATABASE_READ_URL` is not configured, `ReadRepo` points at the primary database. In this case, lag detection is **disabled** — `pg_last_xact_replay_timestamp()` returns NULL on a primary (it's a standby-only function). The `ReadRepo` module detects this at startup by comparing its connection URL against `Repo`'s — if identical, set an internal flag to bypass lag monitoring entirely and always route directly (no overhead). **Guard: NULL on real standby.** `pg_last_xact_replay_timestamp()` can also return NULL on a genuine standby that has never replayed a transaction (fresh replica, or a standby that has been idle with no upstream writes). When the lag query returns NULL and we are in replica mode (not no-replica), treat it as **lag exceeded** — fall back to Primary and emit `[:slackex, :read_repo, :lag_null_standby]` telemetry. This is safe because a fresh standby with no replayed transactions has unknown staleness, and the condition self-resolves once the first transaction is replayed.

### 3.5.3 Test Support

Update `DataCase.setup_sandbox/1` to start sandbox owners for both `Slackex.Repo` and `Slackex.ReadRepo`.

## Step 4: Push Notifications (Mobile)

### 4.1 Notification Worker (`Slackex.Notifications.PushWorker`)

Oban worker (queue: `:notifications`, max_attempts: 3). Handles two job types:

- **`"new_message"`** — loads sender and channel, finds offline subscribers (excluding sender), sends push with title `"#channel_name"` and body `"username: content..."` truncated to 100 chars
- **`"new_dm"`** — sends push to recipient only if offline, with title as sender username

### 4.2 Enqueue from ChannelServer

After broadcasting a message, enqueue push notification via Oban. Channel messages use `schedule_in: 5` (5-second delay for batching). DM notifications fire immediately.

### 4.3 Online Status Tracking (`Slackex.Notifications.OnlineTracker`)

Tracks user online status in Redis with 2-minute TTL, refreshed by periodic heartbeat. Updated when LiveView/Channel connections mount/unmount.

Public API:
- `mark_online(user_id)` — `SET online:#{user_id} "1" EX 120`
- `mark_offline(user_id)` — `DEL`
- `refresh(user_id)` — `EXPIRE`
- `online?(user_id) :: boolean`

## Step 4.5: Device Tokens Table

### Migration

Create table `device_tokens`:

| Column | Type | Constraints |
|--------|------|-------------|
| user_id | references(users) | NOT NULL, on_delete: delete_all, indexed |
| token | string | NOT NULL, unique index |
| platform | string(10) | NOT NULL — "fcm" or "apns" |
| device_name | string(100) | |
| timestamps | utc_datetime_usec | |

### Schema (`Slackex.Notifications.DeviceToken`)

Standard Ecto schema. Validates platform inclusion in `["fcm", "apns"]`. PushWorker queries this table to dispatch to the correct push service.

## Step 5: Message Table Partitioning

### 5.1 Migration: Convert to Range-Partitioned Table

**Strategy** (destructive — run during maintenance window):
1. Rename `messages` to `messages_old`
2. Create new `messages` table with `PARTITION BY RANGE (inserted_at)` and composite PK `(id, inserted_at)`
3. Create monthly partitions covering **all existing data plus future headroom**: query `SELECT date_trunc('month', min(inserted_at)) FROM messages_old` to find the earliest month, then create partitions from that month through current + 3 months ahead. Failing to cover the full historical range will cause the copy step (step 6) to error with "no partition of relation matches row"
4. Recreate indexes: `(channel_id, inserted_at, id)`, `(dm_conversation_id, inserted_at, id)`, `(sender_id)`, GIN FTS — note: `inserted_at` is included in composite indexes to enable partition pruning on queries that filter by both `channel_id` and Snowflake-derived timestamp bounds
5. Re-add CHECK constraint: `ALTER TABLE messages ADD CONSTRAINT messages_target_check CHECK ((channel_id IS NOT NULL AND dm_conversation_id IS NULL) OR (channel_id IS NULL AND dm_conversation_id IS NOT NULL));` — this was defined in Phase 1 and must be preserved through table recreation (CHECK constraints are not automatically carried over)
6. Copy data from old table: `INSERT INTO messages SELECT * FROM messages_old`
7. **Validate (all checks must pass before proceeding to step 8):**
   - **Row count match:** `SELECT count(*) FROM messages` = `SELECT count(*) FROM messages_old`
   - **Per-partition row counts:** `SELECT tableoid::regclass, count(*) FROM messages GROUP BY 1` — verify every expected partition has rows and no partition is unexpectedly empty
   - **Boundary integrity:** `SELECT min(inserted_at), max(inserted_at) FROM messages` matches old table, and each partition's min/max falls within its declared range
   - **Checksum sample:** For a random sample of 3 partitions, compare chunked checksums between old and new tables. Use range-based hashing to avoid loading full partitions into memory: `SELECT md5(string_agg(id::text, ',' ORDER BY id)) FROM messages WHERE inserted_at BETWEEN $start AND $end AND id BETWEEN $lo AND $hi` in chunks of 100K rows. Compare each chunk's hash between old and new tables. This avoids the memory risk of `md5(array_agg(id ORDER BY id)::text)` on large partitions.
   - **Critical query smoke tests:** Run `HistoryLoader.recent/2`, `HistoryLoader.before/3`, and `MessageSearch.text_search/3` against the new table and verify results match old table for a set of test channel IDs
   - **EXPLAIN verification:** Run `EXPLAIN` on a typical `before` query and confirm partition pruning is active (not scanning all partitions)
8. Drop old table (only after ALL validation checks pass)
9. Re-add foreign keys to users, channels, dm_conversations

**Rollback plan:**
- Before step 1, take a logical backup: `pg_dump --table=messages --data-only`
- If migration fails at any step before dropping `messages_old` (steps 1-6), reverse by: `DROP TABLE IF EXISTS messages; ALTER TABLE messages_old RENAME TO messages;`
- If failure occurs after step 7 (old table dropped), restore from the logical backup
- **Rehearsal:** Run the full migration on a staging environment with production-scale data before the real cutover. Measure duration, validate row counts, and test application queries against the partitioned table.

**Large-table alternative (>100M rows):** If staging rehearsal shows the rename/copy/drop migration exceeds an acceptable maintenance window, use an incremental approach instead:
1. Create the partitioned table as `messages_partitioned` (no rename of original)
2. Use `pg_partman` or a custom Oban worker to copy data in batches (e.g., 100K rows per batch with `INSERT INTO messages_partitioned SELECT * FROM messages WHERE id BETWEEN $1 AND $2`)
3. Once caught up, enable dual-writes in BatchWriter (write to both tables)
4. Run a final sync pass to close any gap
5. Swap tables atomically: `ALTER TABLE messages RENAME TO messages_legacy; ALTER TABLE messages_partitioned RENAME TO messages;` (brief lock, no data copy)
6. Drop `messages_legacy` after validation

This approach minimizes downtime to the atomic rename step (~seconds) at the cost of implementation complexity.

**Pre-migration checklist:**
- [ ] Staging rehearsal completed successfully
- [ ] Logical backup of messages table taken
- [ ] Application put into maintenance mode (no new user requests)
- [ ] **Write drain barrier:** Stop all ChannelServers from accepting new messages (reject with `{:error, :maintenance}`), then force a synchronous flush of all `pending_writes` and `in_flight` batches across all nodes. Verify zero pending writes: `Messaging.channel_count()` should be 0 (all ChannelServers have shut down) or iterate active ChannelServers and confirm empty `pending_writes` and `in_flight` maps. Only proceed once all accepted messages are durably persisted.
- [ ] Row count recorded: `SELECT count(*) FROM messages`
- [ ] Estimated migration duration: ______ (from staging rehearsal)

**Note on FKs:** Partitioned tables require FK references to match the full partition key `(id, inserted_at)`. Tables referencing just `message_id` (like `message_embeddings`) should NOT use FK constraints — enforce referential integrity at the application level.

**Note on BatchWriter compatibility:** Phase 3's `BatchWriter.insert_batch/2` (with required `epoch:, type:, id:`) uses `on_conflict: :nothing` without a `conflict_target`, which generates `ON CONFLICT DO NOTHING`. This remains correct after partitioning — PostgreSQL evaluates the `DO NOTHING` clause against any unique constraint violation (including the composite PK `(id, inserted_at)`). The epoch check + insert runs inside a single transaction with `FOR UPDATE` row lock (see Step 2.2), so partitioning does not affect fencing atomicity. No changes to BatchWriter's conflict handling are required for this migration. (Note: Phase 2's epoch-less `insert_batch/1` arity was removed in Phase 3 Step 2.2.)

**Note on `inserted_at` stability:** The `inserted_at` value is derived from the Snowflake ID timestamp (set in the Message changeset via `Snowflake.extract_timestamp/1`), not generated at insert time. This ensures that for any given message ID, the `inserted_at` value is deterministic and immutable. Retries of the same message always produce the same `(id, inserted_at)` pair, landing in the same partition — preventing duplicate logical messages across partitions.

### 5.2 Partition Maintenance Worker

`Slackex.Workers.PartitionMaintenance` — Oban worker (monthly cron), creates 3 months of future partitions using `CREATE TABLE IF NOT EXISTS ... PARTITION OF messages FOR VALUES FROM (...) TO (...)`.

## Step 6: Reconnection & Catch-Up

`Slackex.Notifications.CatchupServer` — builds catch-up payload for reconnecting users.

Public API:
- `build_catchup(user_id)` — for each subscribed channel: compute unread count, fetch missed messages (up to 100) from read cursor position. Returns `%{channels: [%{channel_id, channel_name, channel_slug, unread_count, recent_messages}], timestamp}`. Read cursors checked in Redis first, fallback to DB.

## Step 7: Update Application Supervisor (Phase 3)

Children added/changed from Phase 2:
1. `Slackex.Repo`
2. `Slackex.ReadRepo` — **new**
3. `{Cluster.Supervisor, [topologies(), ...]}` — **new**
4. `Slackex.NodeListener` — **new**
5. `{Phoenix.PubSub, name: Slackex.PubSub}`
6. `SlackexWeb.Presence`
7. `Slackex.Infrastructure.Snowflake`
8. `Slackex.Cache.Local`
9. `Slackex.Cache.Redis` — **new**
10. `Slackex.Messaging.ChannelRegistry` — **changed** from local Registry to Horde
11. `Slackex.Messaging.ChannelSupervisor` — **changed** from DynamicSupervisor to Horde
12. `{Task.Supervisor, name: Slackex.WriteSupervisor}`
13. `{Oban, ...}`
14. `SlackexWeb.Endpoint`

## Step 8: Kubernetes Deployment

### 8.1 Dockerfile

Two-stage build:
- **Build stage** (`hexpm/elixir:1.17.0-erlang-27.0-debian-bookworm`): install hex/rebar, compile deps, compile assets, compile app, create release
- **Runtime stage** (`debian:bookworm-slim`): non-root user, tini as init for signal handling, `RELEASE_DISTRIBUTION=name` for BEAM clustering, healthcheck on `/health`

### 8.2 Kubernetes Resources

- **StatefulSet:** 3 replicas (not Deployment — StatefulSet provides stable pod ordinals required for `SNOWFLAKE_NODE_ID`). Pod env vars: `SNOWFLAKE_NODE_ID` derived from the pod ordinal (e.g., `slackex-0` → `0`, `slackex-1` → `1`) via an init container or `fieldRef` + shell extraction. `POD_IP` via downward API → `RELEASE_NODE`. Liveness probe on `/health`, readiness probe on `/ready`, resource limits (512Mi-2Gi memory, 500m-2000m CPU). `podManagementPolicy: Parallel` for faster rollouts (ordering is not required — nodes are peers)
- **Headless Service** (`clusterIP: None`): for BEAM node discovery via K8s DNS — exposes ports 4000 (HTTP), 4369 (epmd), and 9000-9010 (Erlang distribution port range). **Erlang dist port pinning:** Set `ELIXIR_ERL_OPTIONS="-kernel inet_dist_listen_min 9000 inet_dist_listen_max 9010"` in the pod env. Without pinning, BEAM picks random ephemeral ports for inter-node communication, which are unreachable through K8s services.
- **ClusterIP Service**: regular load-balanced service on port 80→4000
- **Ingress**: nginx with sticky sessions (`cookie` affinity) for WebSocket, long proxy timeouts (3600s)

### 8.3 Health & Readiness Endpoints

**Liveness — `GET /health`:** Returns 200 if the BEAM node is responsive and the database connection is alive. Does **not** check Redis. Used by Kubernetes `livenessProbe` — a failure here restarts the pod.

**Readiness — `GET /ready`:** Returns JSON with database status, Redis status (informational), current node, connected nodes, and channel process count (via `Messaging.channel_count/0`). Returns 503 **only** if the database is unhealthy. Redis status is reported as a `"degraded"` field but does **not** affect the HTTP status code. Used by Kubernetes `readinessProbe` — a failure here removes the pod from the load balancer but does **not** restart it.

> **Rationale:** Redis is an optional cache with graceful degradation. If readiness failed on Redis
> outage, a shared Redis failure would make ALL pods unready simultaneously — causing a complete
> traffic blackout that is worse than degraded cache performance. Redis health should be monitored
> via metrics/alerts, not probe status codes.

### 8.4 Local Multi-Node Development

Shell script starts 3 nodes on ports 4000-4002 using `iex --sname slackexN -S mix phx.server`. Nodes auto-discover via gossip strategy. Support dynamic `PORT` env var in dev endpoint config.

## Phase 3 Acceptance Criteria

- [x] ~~Horde distributes ChannelServer processes across cluster nodes~~ (Step 2.1/2.3/2.4 — Horde.Registry + Horde.DynamicSupervisor with `members: :auto`, `process_redistribution: :active`)
- [x] ~~When a node goes down, affected channels restart on surviving nodes within 5 seconds~~ (Step 2.5 — Horde auto-restart + init/1 rehydration)
- [x] ~~Channel processes flush pending writes before graceful termination (terminate/2 is best-effort)~~ (Step 2.5 — terminate/2 with trap_exit + synchronous BatchWriter flush)
- [x] ~~ChannelServer init/1 reconciles cache vs DB to recover un-persisted messages after crash~~ (Step 2.5 — reconcile_cache/4 compares cache IDs against DB, re-persists missing)
- [x] ~~libcluster auto-discovers nodes (gossip in dev, K8s DNS in prod)~~ (Step 1 — Cluster.Supervisor + NodeListener + config per env)
- [x] ~~Redis cache serves as cross-node shared cache~~ (Step 3 — Cache.Redis Supervisor with 10 Redix connections, push/get/cache/invalidate API)
- [x] ~~Cache cascade: ETS → Redis → PostgreSQL works correctly~~ (Step 3 — Cache facade: ETS→Redis→miss read path, write-through put_message)
- [ ] ReadRepo is configured and routes read-only queries to replica (or primary as fallback)
- [ ] Device tokens table stores FCM/APNs tokens per user
- [ ] Push notification Oban worker dispatches to FCM/APNs using stored device tokens
- [ ] Notifications only sent to offline users (online status tracked in Redis)
- [x] ~~Redis commands gracefully degrade when Redis is unavailable~~ (Step 3 — try/rescue wrapping, 100ms write timeout, telemetry on failure)
- [ ] Messages table is partitioned by month
- [ ] Partition maintenance worker creates future partitions
- [ ] Reconnection catch-up delivers correct unread counts and missed messages
- [ ] Liveness endpoint (`/health`) returns 200 when BEAM and database are responsive
- [ ] Readiness endpoint (`/ready`) reports database, Redis (informational), and cluster status
- [ ] Redis outage does NOT cause readiness failure (degraded status only, no 503)
- [ ] Kubernetes manifests deploy a 3-pod cluster with sticky WebSocket sessions
- [ ] `docker build` produces a working production release image
- [x] ~~Local multi-node dev cluster works via gossip strategy~~ (Step 1 — gossip config in dev.exs)
- [x] ~~All behavioral tests from Phases 1-2 still pass~~ (289 tests, 0 failures after Redis cache integration)
- [ ] Distributed tests (using LocalCluster) verify Horde failover
