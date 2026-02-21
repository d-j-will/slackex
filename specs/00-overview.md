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
| Write Pipeline | Broadway | High-throughput batched message persistence with back-pressure and concurrency control |
| Background Jobs | Oban | Postgres-backed durable job queue for embeddings, notifications, maintenance tasks |
| Database | PostgreSQL 16+ with pgvector | Relational data + full-text search + vector embeddings in one system |
| Message Search | Postgres FTS + pgvector semantic | Keyword search via tsvector, semantic search via vector similarity for future AI/RAG |
| Message Ordering | Snowflake IDs (64-bit) | Sortable, unique, encodes timestamp + node + sequence. Proven at Discord's scale |
| Auth (Web) | Session-based (phx.gen.auth) | Secure HttpOnly cookies, CSRF protection, standard Phoenix pattern |
| Auth (Mobile) | JWT access + refresh tokens | Stateless access tokens (15min), revocable refresh tokens (30 days) |
| CQRS Pattern | Command: GenServer → PubSub → Broadway; Query: ETS → Redis → Postgres | Immediate delivery via in-memory broadcast, async durable persistence |
| Real-time | Phoenix PubSub (pg2 adapter) | Distributed pub/sub across BEAM cluster nodes, zero external dependencies |
| Deployment | Docker + Kubernetes | Horizontal scaling, rolling deploys, libcluster K8s DNS discovery |
| AI Dev Tooling | Tidewave | MCP server for AI-assisted development in dev environment |

## Technology Stack

### Core Dependencies

```elixir
# mix.exs deps
[
  # Web Framework
  {:phoenix, "~> 1.7"},
  {:phoenix_live_view, "~> 1.0"},
  {:phoenix_html, "~> 4.0"},
  {:phoenix_live_dashboard, "~> 0.8"},

  # Database & Cache
  {:ecto_sql, "~> 3.12"},
  {:postgrex, "~> 0.19"},
  {:redix, "~> 1.5"},

  # Real-time & Distribution
  {:phoenix_pubsub, "~> 2.1"},
  {:horde, "~> 0.9"},
  {:libcluster, "~> 3.4"},

  # Async Processing
  {:broadway, "~> 1.1"},
  {:oban, "~> 2.18"},

  # Auth
  {:bcrypt_elixir, "~> 3.0"},
  {:guardian, "~> 2.3"},           # JWT for mobile

  # Architecture
  {:boundary, "~> 0.10", runtime: false},

  # Utilities
  {:jason, "~> 1.4"},
  {:bandit, "~> 1.5"},
  {:dns_cluster, "~> 0.1.1"},

  # Search & AI
  {:pgvector, "~> 0.3"},

  # Push Notifications
  {:pigeon, "~> 2.0"},

  # Dev & Test
  {:tidewave, "~> 0.5", only: :dev},
  {:phoenix_live_reload, "~> 1.2", only: :dev},
  {:esbuild, "~> 0.8", runtime: false, only: :dev},
  {:tailwind, "~> 0.2", runtime: false, only: :dev},
  {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
  {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
  {:ex_machina, "~> 2.8", only: :test},
  {:wallaby, "~> 0.30", only: :test},
  {:local_cluster, "~> 2.1", only: :test},
  {:floki, "~> 0.36", only: :test}
]
```

## Boundary Definitions

The `boundary` library enforces module dependency rules at compile time. Instead of an umbrella project with separate apps, we define boundaries within a single application:

```
Slackex (Application)
├── Slackex.Accounts        # User management, authentication
│   ├── deps: [Slackex.Repo]
│   └── exports: [User, Auth, UserToken]
│
├── Slackex.Chat             # Channels, messages, subscriptions
│   ├── deps: [Slackex.Accounts, Slackex.Repo]
│   └── exports: [Channel, Message, Subscription, ReadCursor, DMConversation]
│
├── Slackex.Messaging        # Real-time message delivery (GenServers, PubSub)
│   ├── deps: [Slackex.Chat, Slackex.Accounts]
│   └── exports: [ChannelServer, send_message/3, subscribe_channel/1]
│
├── Slackex.Pipeline         # CQRS write side (Broadway, batch persistence)
│   ├── deps: [Slackex.Chat, Slackex.Repo]
│   └── exports: [MessagePipeline]
│
├── Slackex.Search           # CQRS read side (cache cascade, FTS, pgvector)
│   ├── deps: [Slackex.Chat, Slackex.Repo, Slackex.Cache]
│   └── exports: [MessageSearch, HistoryLoader]
│
├── Slackex.Cache            # ETS + Redis cache management
│   ├── deps: []
│   └── exports: [Local, Redis, get/2, put/3, invalidate/2]
│
├── Slackex.Notifications    # Push notifications, unread tracking, catch-up
│   ├── deps: [Slackex.Chat, Slackex.Accounts]
│   └── exports: [PushWorker, UnreadTracker]
│
├── Slackex.Embeddings       # AI/RAG pipeline (vector generation)
│   ├── deps: [Slackex.Chat, Slackex.Repo]
│   └── exports: [EmbeddingWorker, EmbeddingClient]
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
├── {Horde.Registry, name: Slackex.ChannelRegistry}  # Distributed registry
├── {Horde.DynamicSupervisor,                        # Distributed supervisor
│    name: Slackex.ChannelSupervisor}
├── Slackex.Infrastructure.Snowflake                 # ID generator
├── Slackex.Cache.Local                              # ETS table manager
├── Slackex.Cache.Redis                              # Redix connection pool
├── {Oban, oban_config()}                            # Background job processor
└── Slackex.Pipeline.MessagePipeline                 # Broadway write pipeline
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
       ├──► PubSub broadcast to all subscribers (IMMEDIATE)
       │     └── LiveView / Channel processes push to clients
       │
       ├──► ETS local cache update (IMMEDIATE)
       │
       ├──► Enqueue to Broadway write pipeline (ASYNC)
       │     │
       │     ├──► Batch INSERT to PostgreSQL
       │     │
       │     └──► Enqueue Oban job: Redis cache update
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
| 2 — Real-time & CQRS | GenServers, Broadway, caching | In-memory message delivery, async persistence, presence |
| 3 — Distribution | Horde, clustering, Redis | Multi-node deployment, push notifications, partitioning |
| 4 — Intelligence | pgvector, search, RAG | Full-text + semantic search, embedding pipeline |

Each phase has its own detailed spec document.

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
│   │   │   ├── message_pipeline.ex     # Broadway definition
│   │   │   ├── message_producer.ex     # Broadway producer
│   │   │   └── batch_writer.ex         # Batched Postgres inserts
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
