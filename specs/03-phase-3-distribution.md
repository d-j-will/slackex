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

`Slackex.Messaging.ChannelRegistry` — wraps `Horde.Registry` with `members: :auto` for auto-discovery via libcluster. Guarantees at most one ChannelServer process per channel across the cluster using delta-CRDTs for eventually consistent membership.

Public API:
- `lookup(channel_id) :: {:ok, pid} | :not_found`
- `via(channel_id)` — returns `{:via, Horde.Registry, {__MODULE__, channel_id}}` tuple

### 2.2 Replace DynamicSupervisor with Horde.DynamicSupervisor

`Slackex.Messaging.ChannelSupervisor` — wraps `Horde.DynamicSupervisor` with `process_redistribution: :active` to rebalance on node changes.

Public API:
- `ensure_started(channel_id, opts \\ [])` — cluster-wide lookup then start. Same API as Phase 2 but now distributed.
- `count()` — active channel processes across the cluster

### 2.3 Update ChannelServer

Change `via/1` from `{:via, Registry, ...}` to `Slackex.Messaging.ChannelRegistry.via(channel_id)`.

### 2.4 Process Handoff on Node Down

Horde automatically restarts affected processes on surviving nodes. ChannelServer's `init/1` rehydrates from cache/DB. To minimize data loss, add a `terminate/2` callback that does a **synchronous** `BatchWriter.insert_batch/1` flush of pending writes (not async — the process is about to die).

## Step 3: Redis — Cross-Node Cache

### 3.1 Redis Connection Pool (`Slackex.Cache.Redis`)

Supervisor that starts a pool of 10 Redix connections. Commands are dispatched to a random connection. All Redis commands are wrapped with `rescue` to gracefully degrade when Redis is unavailable — the system falls through to Postgres.

Public API:
- `get_messages(channel_id) :: {:ok, [message]} | {:miss, []}` — `LRANGE` last 100 messages
- `push_message(channel_id, message)` — `RPUSH` + `LTRIM` to 100 + `EXPIRE` 1 hour
- `cache_messages(channel_id, messages)` — bulk backfill (`DEL` + `RPUSH` + `EXPIRE`)
- `set_read_cursor(user_id, channel_id, message_id)` — `SET` with 24h TTL
- `get_read_cursor(user_id, channel_id) :: {:ok, integer} | :miss`
- `invalidate(channel_id)` — `DEL`

### 3.2 Three-Tier Cache Cascade

Update `Slackex.Cache` boundary — `deps: [], exports: [Local, Redis]`

```
Read path:
  1. ETS (local node) — ~0.01ms
  2. Redis (cross-node) — ~0.5-2ms → backfills ETS on hit
  3. Returns :miss if both miss (caller falls through to DB)

Write path (write-through):
  Cache.put_message → Local.put_message + Redis.push_message
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
| `Chat.list_messages/2` | ReadRepo | Historical read, tolerates replication lag |
| `Chat.list_user_channels/1` | ReadRepo | Channel list doesn't change often |
| `Chat.list_public_channels/0` | ReadRepo | Read-only listing |
| `Chat.unread_count/2` | ReadRepo | Read-only count |
| `Search.MessageSearch.*` | ReadRepo | All search is read-only |
| `Chat.get_role/2` | Primary | Authorization before writes |
| `Chat.send_message/3` | Primary | Write operation |
| `Chat.create_channel/2` | Primary | Write operation |
| `Chat.mark_as_read/2` | Primary | Write (upsert) |
| `Chat.join_channel/2` | Primary | Write |

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
3. Create monthly partitions (past 3 months, current, next 3)
4. Recreate indexes: `(channel_id, id)`, `(dm_conversation_id, id)`, `(sender_id)`, GIN FTS
5. Copy data from old table
6. Drop old table
7. Re-add foreign keys to users, channels, dm_conversations

**Note on FKs:** Partitioned tables require FK references to match the full partition key `(id, inserted_at)`. Tables referencing just `message_id` (like `message_embeddings`) should NOT use FK constraints — enforce referential integrity at the application level.

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

- **Deployment:** 3 replicas, pod env vars via downward API (`POD_IP` → `RELEASE_NODE`), readiness/liveness probes on `/health`, resource limits (512Mi-2Gi memory, 500m-2000m CPU)
- **Headless Service** (`clusterIP: None`): for BEAM node discovery via K8s DNS — exposes ports 4000 (HTTP) and 4369 (epmd)
- **ClusterIP Service**: regular load-balanced service on port 80→4000
- **Ingress**: nginx with sticky sessions (`cookie` affinity) for WebSocket, long proxy timeouts (3600s)

### 8.3 Health Endpoint

`SlackexWeb.HealthController` — `GET /health` returns JSON with database status, Redis status, current node, connected nodes, and channel process count. Returns 503 if database or Redis is unhealthy.

### 8.4 Local Multi-Node Development

Shell script starts 3 nodes on ports 4000-4002 using `iex --sname slackexN -S mix phx.server`. Nodes auto-discover via gossip strategy. Support dynamic `PORT` env var in dev endpoint config.

## Phase 3 Acceptance Criteria

- [ ] Horde distributes ChannelServer processes across cluster nodes
- [ ] When a node goes down, affected channels restart on surviving nodes within 5 seconds
- [ ] Channel processes flush pending writes before termination
- [ ] libcluster auto-discovers nodes (gossip in dev, K8s DNS in prod)
- [ ] Redis cache serves as cross-node shared cache
- [ ] Cache cascade: ETS → Redis → PostgreSQL works correctly
- [ ] ReadRepo is configured and routes read-only queries to replica (or primary as fallback)
- [ ] Device tokens table stores FCM/APNs tokens per user
- [ ] Push notification Oban worker dispatches to FCM/APNs using stored device tokens
- [ ] Notifications only sent to offline users (online status tracked in Redis)
- [ ] Redis commands gracefully degrade when Redis is unavailable
- [ ] Messages table is partitioned by month
- [ ] Partition maintenance worker creates future partitions
- [ ] Reconnection catch-up delivers correct unread counts and missed messages
- [ ] Health endpoint reports database, Redis, and cluster status
- [ ] Kubernetes manifests deploy a 3-pod cluster with sticky WebSocket sessions
- [ ] `docker build` produces a working production release image
- [ ] Local multi-node dev cluster works via gossip strategy
- [ ] All behavioral tests from Phases 1-2 still pass
- [ ] Distributed tests (using LocalCluster) verify Horde failover
