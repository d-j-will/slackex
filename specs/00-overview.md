# Slackex — Architecture Overview

## Project Vision

Slackex is a Discord-like real-time chat messaging platform built in Elixir, designed to leverage the BEAM VM and OTP for fault tolerance, massive concurrency, and soft real-time performance. It supports web (Phoenix LiveView) and mobile (Phoenix Channels over WebSocket) clients.

## Key Architectural Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Language/Runtime | Elixir 1.17+ / OTP 27+ | BEAM VM designed for telecom — millions of concurrent lightweight processes, fault tolerance, hot code upgrades |
| Web Client | Phoenix LiveView | Server-rendered real-time UI, single language stack, no separate SPA build |
| Mobile API | Phoenix Channels (WebSocket) | Same transport for web and mobile, native libraries available for Swift/Kotlin/React Native |
| Module Boundaries | `boundary` library | Enforces architectural boundaries at compile time without umbrella project complexity |
| Process Distribution | Horde | CRDT-based distributed Registry + DynamicSupervisor with automatic failover |
| Node Discovery | libcluster | Pluggable strategies (K8s DNS, gossip, epmd) for automatic BEAM cluster formation |
| Caching | ETS (local) + Redis (cross-node) | ETS for zero-latency hot cache, Redis for shared state across cluster nodes |
| Write Pipeline | ChannelServer batch flush + Task.Supervisor | ChannelServer accumulates pending writes and flushes via async Task on a timer. Simple, no extra process overhead. Broadway can be layered in later if back-pressure is needed at scale |
| Background Jobs | Oban | Postgres-backed durable job queue for embeddings, notifications, maintenance tasks |
| Database | PostgreSQL 16+ with pgvector | Relational data + full-text search + vector embeddings in one system |
| Message Search | Postgres FTS + pgvector semantic | Keyword search via tsvector, semantic search via vector similarity for future AI/RAG |
| Message Ordering | Snowflake IDs (64-bit) | Sortable, unique, encodes timestamp + node + sequence. Proven at Discord's scale. Note: Phase 1 GenServer impl is single-process; consider `:atomics`-based sharding if >4096 IDs/ms/node becomes a bottleneck |
| Auth (Web) | Session-based (phx.gen.auth) | Secure HttpOnly cookies, CSRF protection, standard Phoenix pattern |
| Auth (Mobile) | JWT access + refresh tokens | Stateless access tokens (15min), revocable refresh tokens (30 days) |
| CQRS Pattern | Command: GenServer → PubSub → async batch write; Query: ETS → Redis → Postgres | Immediate delivery via in-memory broadcast, async durable persistence |
| Real-time | Phoenix PubSub (pg2 adapter) | Distributed pub/sub across BEAM cluster nodes, zero external dependencies |
| Deployment | Docker + Kubernetes | Horizontal scaling, rolling deploys, libcluster K8s DNS discovery |
| AI Dev Tooling | Tidewave | MCP server for AI-assisted development in dev environment |
| Observability | Telemetry + telemetry_metrics_prometheus | BEAM-native instrumentation; Phoenix, Ecto, Oban emit events automatically |

## Technology Stack

### Core Dependencies

| Library | Version | Purpose |
|---------|---------|---------|
| phoenix | ~> 1.7 | Web framework |
| phoenix_live_view | ~> 1.0 | Server-rendered real-time UI |
| phoenix_html | ~> 4.0 | HTML helpers |
| phoenix_live_dashboard | ~> 0.8 | Runtime monitoring dashboard |
| ecto_sql | ~> 3.12 | Database wrapper and query DSL |
| postgrex | ~> 0.19 | PostgreSQL driver |
| redix | ~> 1.5 | Redis driver |
| phoenix_pubsub | ~> 2.1 | Distributed pub/sub |
| horde | ~> 0.9 | CRDT-based distributed process management |
| libcluster | ~> 3.4 | Automatic BEAM cluster formation |
| oban | ~> 2.18 | Postgres-backed background job queue |
| bcrypt_elixir | ~> 3.0 | Password hashing |
| guardian | ~> 2.3 | JWT for mobile API auth |
| boundary | ~> 0.10 | Compile-time module boundary enforcement (runtime: false) |
| jason | ~> 1.4 | JSON encoding/decoding |
| bandit | ~> 1.5 | HTTP server |
| html_sanitize_ex | ~> 1.4 | HTML content sanitization |
| dns_cluster | ~> 0.1.1 | DNS-based cluster discovery (Phoenix default; replaced by libcluster in Phase 3 for K8s/gossip strategies) |
| pgvector | ~> 0.3 | Vector similarity search |
| pigeon | ~> 2.0 | Push notifications (FCM/APNs) |
| telemetry | ~> 1.3 | Instrumentation |
| telemetry_metrics | ~> 1.0 | Metrics definitions |
| telemetry_poller | ~> 1.1 | Periodic measurements |
| telemetry_metrics_prometheus | ~> 1.1 | Prometheus export |
| **Dev & Test** | | |
| tidewave | ~> 0.5 | MCP server for AI-assisted dev (dev only) |
| phoenix_live_reload | ~> 1.2 | Live reload in dev |
| esbuild | ~> 0.8 | JavaScript bundler (dev only) |
| tailwind | ~> 0.2 | CSS framework (dev only) |
| dialyxir | ~> 1.4 | Static type analysis (dev/test) |
| credo | ~> 1.7 | Linting (dev/test) |
| ex_machina | ~> 2.8 | Test factories (test only) |
| wallaby | ~> 0.30 | Browser E2E tests (test only) |
| local_cluster | ~> 2.1 | Multi-node test clusters (test only) |
| floki | ~> 0.36 | HTML parsing for tests (test only) |

## Boundary Definitions

The `boundary` library enforces module dependency rules at compile time. Instead of an umbrella project with separate apps, we define boundaries within a single application:

```
Slackex (Application)                        # Canonical final-state (after all phases)
├── Slackex.Accounts        # User management, authentication
│   ├── deps: [Slackex.Repo]
│   └── exports: [User, Auth, UserToken]
│
├── Slackex.Chat             # Channels, messages, subscriptions
│   ├── deps: [Slackex.Accounts, Slackex.Infrastructure, Slackex.Repo]
│   └── exports: [Channel, Message, Subscription, ReadCursor, DMConversation, Permissions]
│
├── Slackex.Messaging        # Real-time message delivery (GenServers, PubSub)
│   ├── deps: [Slackex.Chat, Slackex.Accounts, Slackex.Cache, Slackex.Infrastructure]
│   └── exports: [ChannelServer]  # Messaging context module is implicitly exported
│
├── Slackex.Pipeline         # CQRS write side (batch persistence via Task.Supervisor)
│   ├── deps: [Slackex.Chat, Slackex.Repo]
│   └── exports: [BatchWriter]
│
├── Slackex.Search           # CQRS read side (cache cascade, FTS, pgvector)
│   ├── deps: [Slackex.Chat, Slackex.Cache, Slackex.Embeddings]
│   └── exports: [MessageSearch, HistoryLoader]
│
├── Slackex.Cache            # ETS + Redis cache management
│   ├── deps: []
│   └── exports: [Local, Redis, get/2, put/3, invalidate/2]
│
├── Slackex.Notifications    # Push notifications, unread tracking, catch-up
│   ├── deps: [Slackex.Chat, Slackex.Accounts, Slackex.Cache]
│   └── exports: [PushWorker, UnreadTracker, CatchupServer]
│
├── Slackex.Embeddings       # AI/RAG pipeline (vector generation)
│   ├── deps: [Slackex.Chat, Slackex.Repo]
│   └── exports: [EmbeddingWorker, EmbeddingClient, RAGContext]
│
├── Slackex.Infrastructure   # Snowflake IDs, Rate Limiter, Clock
│   ├── deps: []
│   └── exports: [Snowflake, RateLimiter]
│
├── Slackex.Repo             # Ecto Repo (thin boundary)
│   ├── deps: []
│   └── exports: [Repo, ReadRepo]
│
└── SlackexWeb               # Phoenix web layer (LiveView, Channels, API)
    ├── deps: [Slackex.Accounts, Slackex.Chat, Slackex.Messaging,
    │          Slackex.Search, Slackex.Notifications]
    └── exports: []  # No other boundary should depend on web
```

> **Note:** This diagram reflects the canonical final-state boundaries after all four phases.
> Phase docs show incremental boundary states — each phase spec documents only the boundaries
> it introduces or modifies.

**Boundary library convention:** The boundary module itself (e.g., `Slackex.Messaging`) is always implicitly exported — it serves as the public API. The `exports` list names additional submodules accessible from outside. All other submodules are internal implementation details.

**Boundary rules enforced at compile time:**
- `SlackexWeb` can depend on all domain boundaries, but no domain boundary can depend on `SlackexWeb`
- `Slackex.Chat` can depend on `Slackex.Accounts` (needs user references) but not vice versa
- `Slackex.Messaging` depends on `Slackex.Chat` for schemas but `Slackex.Chat` does not depend on `Slackex.Messaging`
- `Slackex.Cache` and `Slackex.Infrastructure` are leaf dependencies with no domain knowledge

## System Architecture Diagram

```
                    ┌─────────────────────────────────┐
                    │     Load Balancer (nginx)        │
                    │  (sticky sessions for WebSocket) │
                    └──────────┬──────────────────────┘
                               │
              ┌────────────────┼────────────────┐
              ▼                ▼                 ▼
     ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
     │  BEAM Node 1 │ │  BEAM Node 2 │ │  BEAM Node 3 │
     │              │ │              │ │              │
     │ Phoenix      │ │ Phoenix      │ │ Phoenix      │
     │ LiveView     │ │ LiveView     │ │ LiveView     │
     │ Channels     │ │ Channels     │ │ Channels     │
     │ Horde Procs  │ │ Horde Procs  │ │ Horde Procs  │
     │ ETS Cache    │ │ ETS Cache    │ │ ETS Cache    │
     └──────┬───────┘ └──────┬───────┘ └──────┬───────┘
            │                │                 │
            ├────── Phoenix.PubSub (pg2) ──────┤
            │       (Distributed Erlang)       │
            │                                  │
     ┌──────┴──────────────────────────────────┴──────┐
     │                    Redis                        │
     │  (Cross-node cache, session store)              │
     └─────────────────────┬──────────────────────────┘
                           │
     ┌─────────────────────┴──────────────────────────┐
     │              PostgreSQL + pgvector               │
     │                                                  │
     │  ┌────────────┐ ┌────────────┐ ┌─────────────┐ │
     │  │ messages   │ │ embeddings │ │ users       │ │
     │  │(partitioned│ │ (pgvector) │ │ channels    │ │
     │  │ by month)  │ │            │ │ cursors     │ │
     │  └────────────┘ └────────────┘ └─────────────┘ │
     └─────────────────────────────────────────────────┘
```

## OTP Supervision Tree

```
Slackex.Application
├── Slackex.Repo                                    # Primary Ecto Repo
├── Slackex.ReadRepo                                # Read replica Repo
├── {Phoenix.PubSub, name: Slackex.PubSub}          # Distributed PubSub
├── SlackexWeb.Presence                              # Phoenix Presence
├── SlackexWeb.Endpoint                              # HTTP + WebSocket
├── {Horde.Registry, name: Slackex.Messaging.ChannelRegistry}  # Distributed registry
├── {Horde.DynamicSupervisor,                                  # Distributed supervisor
│    name: Slackex.Messaging.ChannelSupervisor}
├── Slackex.Infrastructure.Snowflake                 # ID generator
├── SlackexWeb.Telemetry                             # Telemetry metrics + poller
├── Slackex.Cache.Local                              # ETS table manager
├── Slackex.Cache.Redis                              # Redix connection pool
├── {Task.Supervisor, name: Slackex.WriteSupervisor}  # Async batch write tasks
├── {Oban, oban_config()}                            # Background job processor
```

## CQRS Message Flow

```
User sends message
       │
       ▼
  Phoenix Channel / LiveView
       │
       ▼
  ChannelServer GenServer (via Horde Registry)
       │
       ├──► Accumulate in pending_writes (IMMEDIATE, flushed on 2s timer)
       │     │
       │     └──► Task.Supervisor async batch INSERT to PostgreSQL
       │           └── Reports {:batch_result, ref, :ok | :error} back to ChannelServer
       │
       ├──► In-memory queue + ETS local cache update (IMMEDIATE)
       │
       ├──► PubSub broadcast to all subscribers (IMMEDIATE)
       │     └── LiveView / Channel processes push to clients
       │
       └──► Enqueue Oban job: embedding generation (ASYNC, low priority)
```

## Database Schema Overview

See Phase 1 spec for initial schema, Phase 3 for partitioning, Phase 4 for pgvector tables.

**Core tables:** `users`, `channels`, `subscriptions`, `messages` (partitioned), `dm_conversations`, `read_cursors`, `message_embeddings`

## Implementation Phases

| Phase | Focus | Key Deliverables |
|-------|-------|-----------------|
| 1 — Foundation | Project setup, auth, basic messaging | Working app with channels, messages, LiveView UI |
| 2 — Real-time & CQRS | GenServers, async write pipeline, caching | In-memory message delivery, async persistence, presence |
| 3 — Distribution | Horde, clustering, Redis | Multi-node deployment, push notifications, partitioning |
| 4 — Intelligence | pgvector, search, RAG | Full-text + semantic search, embedding pipeline |

Each phase has its own detailed spec document.

### Phase-Scoped Dependency Introduction

| Dependency | Introduced In | Notes |
|------------|---------------|-------|
| phoenix, phoenix_live_view, ecto_sql, postgrex, bcrypt_elixir, guardian, boundary, jason, bandit, html_sanitize_ex, dns_cluster | Phase 1 | Core application stack |
| oban | Phase 2 | Background jobs (embeddings, notifications, cache warming) |
| horde, libcluster, redix, nimble_pool, pigeon | Phase 3 | Distribution, clustering, cross-node cache, push notifications. `dns_cluster` (Phase 1) superseded by `libcluster` for K8s/gossip strategies. |
| pgvector, req | Phase 4 | Vector search, HTTP client for embedding API |
| telemetry, telemetry_metrics, telemetry_poller, telemetry_metrics_prometheus | Phase 1 | Observability (used across all phases) |
| Dev/test: tidewave, credo, dialyxir, ex_machina, wallaby, local_cluster, floki | Phase 1 | Development and testing tooling |

## Explicitly Deferred Features

These features are intentionally out of scope for the initial 4-phase plan. The schema and architecture accommodate them for future implementation.

| Feature | Rationale | Earliest Phase |
|---------|-----------|---------------|
| Message editing/deletion | `edited_at` column exists in schema, handlers deferred | Post Phase 2 |
| File/image uploads | Requires object storage (S3/R2), CDN integration | Post Phase 4 |
| Threads/replies | Requires `parent_message_id`, nested UI components | Post Phase 4 |
| Reactions/emoji | Requires reactions table, UI components | Post Phase 2 |
| User profiles/settings | Basic user schema exists, settings UI deferred | Post Phase 1 |
| Admin dashboard | LiveDashboard in deps, custom admin deferred | Post Phase 3 |
| Email notifications | Requires email provider integration (Swoosh) | Post Phase 3 |
| Group DMs (3+ users) | Current DM model is 1:1 only | Post Phase 2 |

## File Structure

```
slackex/
├── specs/                              # This directory — architecture specs
├── lib/
│   ├── slackex/
│   │   ├── application.ex              # OTP application + supervision tree
│   │   ├── repo.ex                     # Primary Ecto Repo
│   │   ├── read_repo.ex                # Read replica Repo
│   │   ├── accounts/                   # Boundary: Slackex.Accounts
│   │   │   ├── accounts.ex             # Context module (public API)
│   │   │   ├── user.ex                 # Schema
│   │   │   ├── user_token.ex           # Schema
│   │   │   └── auth.ex                 # Auth logic (web sessions + JWT)
│   │   ├── chat/                       # Boundary: Slackex.Chat
│   │   │   ├── chat.ex                 # Context module (public API)
│   │   │   ├── channel.ex              # Schema
│   │   │   ├── message.ex              # Schema
│   │   │   ├── subscription.ex         # Schema
│   │   │   ├── dm_conversation.ex      # Schema
│   │   │   ├── read_cursor.ex          # Schema
│   │   │   └── permissions.ex          # Authorization rules
│   │   ├── messaging/                  # Boundary: Slackex.Messaging
│   │   │   ├── messaging.ex            # Context module (public API)
│   │   │   ├── channel_server.ex       # GenServer per channel
│   │   │   ├── dm_server.ex            # GenServer per DM
│   │   │   ├── channel_registry.ex     # Horde.Registry wrapper
│   │   │   ├── channel_supervisor.ex   # Horde.DynamicSupervisor wrapper
│   │   │   └── message_broadcaster.ex  # PubSub broadcast logic
│   │   ├── pipeline/                   # Boundary: Slackex.Pipeline
│   │   │   └── batch_writer.ex         # Batched Postgres inserts (called async via Task.Supervisor)
│   │   ├── search/                     # Boundary: Slackex.Search
│   │   │   ├── search.ex              # Context module (public API)
│   │   │   ├── message_search.ex       # FTS + pgvector queries
│   │   │   └── history_loader.ex       # Cache cascade read logic
│   │   ├── cache/                      # Boundary: Slackex.Cache
│   │   │   ├── cache.ex               # Unified cache API
│   │   │   ├── local.ex                # ETS manager
│   │   │   └── redis.ex                # Redix pool wrapper
│   │   ├── notifications/              # Boundary: Slackex.Notifications
│   │   │   ├── notifications.ex        # Context module
│   │   │   ├── push_worker.ex          # Oban worker for FCM/APNs
│   │   │   ├── catchup_server.ex       # Reconnection catch-up logic
│   │   │   └── unread_tracker.ex       # Per-user unread counts
│   │   ├── embeddings/                 # Boundary: Slackex.Embeddings
│   │   │   ├── embedding_worker.ex     # Oban worker
│   │   │   └── embedding_client.ex     # API client for embedding model
│   │   └── infrastructure/             # Boundary: Slackex.Infrastructure
│   │       ├── snowflake.ex            # Snowflake ID generator
│   │       └── rate_limiter.ex         # Token bucket rate limiter
│   │
│   ├── slackex_web/
│   │   ├── endpoint.ex                 # Phoenix endpoint (+ Tidewave plug)
│   │   ├── router.ex                   # Routes (LiveView + API)
│   │   ├── channels/
│   │   │   ├── user_socket.ex          # WebSocket entry point
│   │   │   ├── chat_channel.ex         # Channel protocol handler
│   │   │   └── dm_channel.ex           # DM protocol handler
│   │   ├── live/
│   │   │   ├── chat_live/
│   │   │   │   ├── index.ex            # Main chat interface
│   │   │   │   ├── sidebar_component.ex
│   │   │   │   ├── message_list_component.ex
│   │   │   │   ├── message_input_component.ex
│   │   │   │   ├── search_component.ex
│   │   │   │   └── channel_settings_component.ex
│   │   │   └── auth_live/
│   │   │       ├── login.ex
│   │   │       └── register.ex
│   │   ├── controllers/
│   │   │   └── api/                    # JSON API for mobile bootstrap
│   │   │       └── auth_controller.ex  # Token exchange endpoint
│   │   └── components/
│   │       ├── core_components.ex
│   │       └── layouts/
│   │
│   └── slackex_web.ex
│
├── priv/
│   └── repo/migrations/
├── assets/
│   ├── js/
│   │   ├── app.js
│   │   └── hooks/
│   │       ├── message_list.js         # Scroll behavior hook
│   │       └── typing_indicator.js     # Typing debounce hook
│   └── css/
├── config/
│   ├── config.exs
│   ├── dev.exs
│   ├── test.exs
│   ├── prod.exs
│   └── runtime.exs
├── test/
│   ├── slackex/                        # Behavioral integration tests
│   ├── slackex_web/                    # LiveView + Channel tests
│   ├── support/
│   │   ├── factory.ex                  # ExMachina factories
│   │   ├── conn_case.ex
│   │   ├── data_case.ex
│   │   └── channel_case.ex
│   └── e2e/                            # Wallaby browser tests
├── docker-compose.yml                  # Local dev (Postgres + Redis)
├── Dockerfile                          # Multi-stage production build
├── .github/
│   └── workflows/
│       └── ci.yml                      # GitHub Actions CI pipeline
├── .formatter.exs
├── .credo.exs
├── .dialyzer_ignore.exs
├── mix.exs
└── mix.lock
```
