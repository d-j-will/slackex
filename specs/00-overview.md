# Slackex — Architecture Overview

## Project Vision

Slackex is a Discord-like real-time chat messaging platform built in Elixir, designed to leverage the BEAM VM and OTP for fault tolerance, massive concurrency, and soft real-time performance. Currently serving web clients via Phoenix LiveView; mobile API contracts (Phoenix Channels over WebSocket) are defined but not yet consumed by a native client.

## Current State (v0.5.54, March 2026)

All four original implementation phases are complete. The application is running in production on a 2-node BEAM cluster (Docker Compose on an unprivileged LXC). 1129 tests, CI/CD via GitHub Actions with automated deploys on version tags.

### What's Built

| Area | Features |
|------|----------|
| **Messaging** | Channels, DMs, message editing/deletion, threads/replies, reactions with quick-react + emoji picker + colon commands, typing indicators, read cursors, unread counts |
| **Channels** | Create, join/leave, invite links, member roles (owner/admin/member), pinned messages, browse channels modal |
| **Search** | Full-text (tsvector), semantic (pgvector), hybrid (RRF), three UI modes ("Best match", "Exact words", "Meaning") |
| **AI** | Channel summarization (DeepInfra/Gemma-3-4b-it), embedding pipeline (all-MiniLM-L6-v2), RAG context |
| **Real-time** | PubSub broadcast, Horde distributed GenServers, presence/online tracking, link previews (OG metadata) |
| **Security** | Cloak encryption on message content, DM request/block/report system, HTML sanitization |
| **UI** | Quick switcher (Cmd+K), slash commands, feature flags (FunWithFlags), dark/light theme |
| **Infrastructure** | 2-node cluster, Snowflake IDs, ETS + Redis caching, Oban background jobs, read replica support |

### What's Not Built

| Feature | Status | Notes |
|---------|--------|-------|
| File/image uploads | Not started | Needs object storage (S3/R2), CDN |
| Group DMs (3+ users) | Not started | Current DM model is 1:1 only |
| Push notifications (mobile) | Not started | Pigeon in deps but not wired |
| Email notifications | Not started | Swoosh configured but no notification emails |
| Native mobile client | Not started | API contracts exist for future adoption |
| #whats-new channel | Idea stage | Auto-subscribed channel with system bot posting release notes |

### Known Constraints

- **GPU is off-limits in prod** — mini-PC with flaky GPU; EXLA GPU access crashes the Proxmox host
- **BumblebeeClient disabled in prod** (v0.5.43) — CPU-only EXLA still OOMs the 20GB LXC. StubClient active, semantic search degraded. Using DeepInfra API for embeddings instead
- **Docker host is an unprivileged LXC** (CT 100) — 20GB on ~20GB Proxmox host, zero headroom. Docker cgroup `mem_limit` may not be enforced
- See `docs/rca/2026-03-05-embedding-cascade-app-crash.md` for the full incident history

## Key Architectural Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Language/Runtime | Elixir 1.19+ / OTP 27+ | BEAM VM designed for telecom — millions of concurrent lightweight processes, fault tolerance, hot code upgrades |
| Web Client | Phoenix LiveView | Server-rendered real-time UI, single language stack, no separate SPA build |
| Mobile API | Phoenix Channels (WebSocket) | Same transport for web and mobile, native libraries available for Swift/Kotlin/React Native |
| Process Distribution | Horde | CRDT-based distributed Registry + DynamicSupervisor with automatic failover |
| Node Discovery | libcluster | Gossip strategy for automatic BEAM cluster formation |
| Caching | ETS (local) + Redis (cross-node) | ETS for zero-latency hot cache, Redis for shared state across cluster nodes |
| Write Pipeline | ChannelServer batch flush + Task.Supervisor | ChannelServer accumulates pending writes and flushes via async Task on a timer |
| Background Jobs | Oban | Postgres-backed durable job queue for embeddings, link previews, maintenance |
| Database | PostgreSQL 16+ with pgvector | Relational data + full-text search + vector embeddings in one system |
| Message Search | Postgres FTS + pgvector semantic + hybrid RRF | Keyword search via tsvector, semantic search via vector similarity, combined via Reciprocal Rank Fusion |
| Message Ordering | Snowflake IDs (64-bit) | Sortable, unique, encodes timestamp + node + sequence |
| Auth (Web) | Session-based (phx.gen.auth) | Secure HttpOnly cookies, CSRF protection, standard Phoenix pattern |
| Auth (Mobile) | JWT access + refresh tokens | Stateless access tokens (15min), revocable refresh tokens (30 days) |
| Encryption | Cloak (AES-256-GCM) | Message content encrypted at rest, `search_content` plaintext companion for FTS |
| Feature Flags | FunWithFlags | Runtime feature toggling without deploys |
| AI/LLM | DeepInfra API (OpenAI-compatible) | Gemma-3-4b-it for summarization, all-MiniLM-L6-v2 for embeddings |
| Frontend Strategy | LiveView-first, contract-first backend | APIs and WebSocket events as stable contracts for future SPA/mobile migration |
| CQRS Pattern | Command: GenServer -> PubSub -> async batch write; Query: ETS -> Redis -> Postgres | Immediate delivery via in-memory broadcast, async durable persistence |
| Real-time | Phoenix PubSub (pg2 adapter) | Distributed pub/sub across BEAM cluster nodes, zero external dependencies |
| Deployment | Docker Compose on unprivileged LXC | 2-node cluster, Caddy reverse proxy, CI/CD via GitHub Actions on version tags |
| Observability | Telemetry + telemetry_metrics | BEAM-native instrumentation; Phoenix, Ecto, Oban emit events automatically |

## Frontend Portability Guardrails

These constraints are mandatory to keep a future web-client migration low-risk:

1. LiveView is an adapter layer. Business rules, authorization, rate limiting, and persistence live in contexts (`Slackex.*`) and channel/message services, not in LiveView callbacks or HEEX templates.
2. Realtime events are contract-first. Channel/DM topics and payloads are versioned (`v1`) and documented as public contracts shared by web and mobile clients.
3. HTTP JSON contracts exist in parallel with LiveView flows for auth/bootstrap/read paths so non-LiveView clients can adopt incrementally.
4. Write outcomes use normalized server semantics (`:ok`, `:backpressure`, `:rate_limited`, `:not_writer`, etc.) so optimistic UI behavior is consistent across clients.
5. Test strategy prioritizes context/channel behavior and contract tests; LiveView tests focus on wiring and rendering.

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
| jason | ~> 1.4 | JSON encoding/decoding |
| bandit | ~> 1.5 | HTTP server |
| html_sanitize_ex | ~> 1.4 | HTML content sanitization |
| cloak_ecto | ~> 1.3 | Field-level encryption (AES-256-GCM) |
| fun_with_flags | ~> 1.12 | Feature flags with Ecto persistence |
| pgvector | ~> 0.3 | Vector similarity search |
| req | ~> 0.5 | HTTP client (DeepInfra API, link previews) |
| bumblebee | ~> 0.6 | ML model serving (dev only, disabled in prod) |
| exla | ~> 0.9 | Nx compiler backend (dev only, disabled in prod) |
| telemetry | ~> 1.3 | Instrumentation |
| telemetry_metrics | ~> 1.0 | Metrics definitions |
| telemetry_poller | ~> 1.1 | Periodic measurements |
| emoji-mart | 5.6.0 | Emoji picker (JS, loaded dynamically) |
| tailwindcss | 4.1.7 | CSS framework |
| **Dev & Test** | | |
| tidewave | ~> 0.5 | MCP server for AI-assisted dev (dev only) |
| phoenix_live_reload | ~> 1.2 | Live reload in dev |
| esbuild | ~> 0.8 | JavaScript bundler (dev only) |
| dialyxir | ~> 1.4 | Static type analysis (dev/test) |
| credo | ~> 1.7 | Linting (dev/test) |
| floki | ~> 0.36 | HTML parsing for tests (test only) |
| local_cluster | ~> 2.1 | Multi-node test clusters (test only) |

## Module Boundaries

Architectural boundaries are enforced by convention (contexts as public APIs, submodules as internal details):

```
Slackex (Application)
├── Slackex.Accounts        # User management, authentication
│   └── exports: [User, Auth, UserToken]
│
├── Slackex.Chat             # Channels, messages, DMs, reactions, pins, members
│   └── exports: [Channel, Message, Subscription, ReadCursor, DMConversation,
│                  Permissions, MessageReaction, Pins, Members]
│
├── Slackex.Messaging        # Real-time message delivery (GenServers, PubSub)
│   └── exports: [ChannelServer, Envelope]
│
├── Slackex.Search           # CQRS read side (FTS, pgvector, hybrid RRF)
│   └── exports: [MessageSearch, HistoryLoader]
│
├── Slackex.Cache            # ETS + Redis cache management
│   └── exports: [Local, Redis]
│
├── Slackex.Notifications    # Online tracking, unread counts
│   └── exports: [OnlineTracker]
│
├── Slackex.Embeddings       # Vector embedding pipeline
│   └── exports: [EmbeddingWorker, OpenAIClient, BumblebeeClient, StubClient,
│                  PersistenceListener, RAGContext]
│
├── Slackex.AI               # LLM integration (summarization)
│   └── exports: [Summarizer, LLMClient, OpenAICompatibleClient]
│
├── Slackex.Links            # Link preview extraction and fetching
│   └── exports: [LinkPreviewListener, URLExtractor, LinkPreviewFetcher]
│
├── Slackex.Infrastructure   # Snowflake IDs, Rate Limiter
│   └── exports: [Snowflake]
│
└── SlackexWeb               # Phoenix web layer (LiveView, API)
    └── exports: []  # No domain boundary depends on web
```

## System Architecture Diagram

```
                    ┌─────────────────────────────────┐
                    │     Caddy (reverse proxy)        │
                    │  (automatic TLS, WebSocket proxy)│
                    └──────────┬──────────────────────┘
                               │
              ┌────────────────┼────────────────┐
              ▼                                  ▼
     ┌──────────────┐                   ┌──────────────┐
     │  BEAM Node 1 │                   │  BEAM Node 2 │
     │  (app1)      │                   │  (app2)      │
     │              │                   │              │
     │ Phoenix      │                   │ Phoenix      │
     │ LiveView     │                   │ LiveView     │
     │ Horde Procs  │                   │ Horde Procs  │
     │ ETS Cache    │                   │ ETS Cache    │
     │ Oban Workers │                   │ Oban Workers │
     └──────┬───────┘                   └──────┬───────┘
            │                                   │
            ├────── Phoenix.PubSub (pg2) ───────┤
            │       (Distributed Erlang)        │
            │                                   │
     ┌──────┴───────────────────────────────────┴──────┐
     │                    Redis                         │
     │  (Cross-node cache, feature flags)               │
     └─────────────────────┬───────────────────────────┘
                           │
     ┌─────────────────────┴───────────────────────────┐
     │              PostgreSQL + pgvector                │
     │                                                   │
     │  ┌────────────┐ ┌────────────┐ ┌─────────────┐  │
     │  │ messages   │ │ embeddings │ │ users       │  │
     │  │(partitioned│ │ (pgvector) │ │ channels    │  │
     │  │ by month)  │ │            │ │ reactions   │  │
     │  └────────────┘ └────────────┘ └─────────────┘  │
     └──────────────────────────────────────────────────┘
                           │
     ┌─────────────────────┴───────────────────────────┐
     │           DeepInfra API (external)               │
     │  Embeddings: all-MiniLM-L6-v2 (384-dim)         │
     │  LLM: google/gemma-3-4b-it (summarization)      │
     └──────────────────────────────────────────────────┘
```

## OTP Supervision Tree

```
Slackex.Application
├── SlackexWeb.Telemetry                             # Telemetry metrics + poller
├── Slackex.Chat.DMRateLimiter                       # DM rate limiting
├── Slackex.Vault                                    # Cloak encryption vault
├── Slackex.Repo                                     # Primary Ecto Repo
├── Slackex.ReadRepo                                 # Read replica Repo
├── Slackex.ReadRepo.LagMonitor                      # Replica lag monitoring
├── {Cluster.Supervisor, ...}                        # libcluster node discovery
├── Slackex.NodeListener                             # Cluster membership events
├── {Phoenix.PubSub, name: Slackex.PubSub}           # Distributed PubSub
├── SlackexWeb.Presence                              # Phoenix Presence
├── Slackex.Infrastructure.Snowflake                 # ID generator
├── Slackex.Cache.Local                              # ETS table manager
├── Slackex.Cache.Redis                              # Redix connection pool
├── Slackex.Messaging.ChannelRegistry                # Horde distributed registry
├── Slackex.Messaging.ChannelSupervisor              # Horde distributed supervisor
├── {Task.Supervisor, name: Slackex.WriteSupervisor} # Async batch write tasks
├── {Task.Supervisor, name: Slackex.TaskSupervisor}  # General async tasks (AI, etc.)
├── maybe_embedding_serving([])                      # Bumblebee serving (dev only)
├── {Oban, oban_config()}                            # Background job processor
├── Slackex.Embeddings.PersistenceListener           # Embedding save listener
├── Slackex.Links.LinkPreviewListener                # Link preview fetcher
└── SlackexWeb.Endpoint                              # HTTP + WebSocket (last)
```

## CQRS Message Flow

```
User sends message
       │
       ▼
  Phoenix LiveView
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
       │     └── LiveView processes push to clients
       │
       ├──► Enqueue Oban job: embedding generation (ASYNC, low priority)
       │
       └──► LinkPreviewListener extracts URLs, fetches OG metadata (ASYNC)
```

## Database Schema Overview

**Core tables:** `users`, `channels`, `subscriptions`, `messages` (partitioned by month), `dm_conversations`, `read_cursors`, `message_embeddings`, `message_reactions`, `pinned_messages`, `link_previews`

**Encryption:** Message `content` field encrypted via Cloak (AES-256-GCM). `search_content` plaintext companion column enables GIN indexing for FTS.

**Search indexes:** GIN on `search_tsvector` for full-text, IVFFlat on `embedding` for vector similarity, composite indexes for partitioned message joins `(message_id, message_inserted_at)`.

## Implementation Phases

| Phase | Focus | Status |
|-------|-------|--------|
| 1 — Foundation | Project setup, auth, basic messaging | **Complete** |
| 2 — Real-time & CQRS | GenServers, async write pipeline, caching | **Complete** |
| 3 — Distribution | Horde, clustering, Redis | **Complete** (2-node prod cluster) |
| 4 — Intelligence | pgvector, search, RAG | **Complete** (BumblebeeClient disabled in prod, using DeepInfra API) |
| Post-phase features | Editing, threads, reactions, pins, link previews, summarization, search UI | **Complete** |

Each phase has its own detailed spec document in `specs/`.

## File Structure

```
slackex/
├── specs/                              # Architecture specs
├── docs/                               # Feature specs, RCAs, research, runbooks
│   ├── rca/                            # Root cause analyses
│   ├── runbooks/                       # Deployment, model deployment
│   ├── design/                         # UI/UX design docs
│   ├── engineering-principles.md       # Migration safety, deploy rules
│   └── research/                       # Technology evaluations
├── scripts/
│   └── pre-deploy                      # 7-step verification script
├── lib/
│   ├── slackex/
│   │   ├── application.ex              # OTP application + supervision tree
│   │   ├── repo.ex                     # Primary Ecto Repo
│   │   ├── read_repo.ex                # Read replica Repo
│   │   ├── vault.ex                    # Cloak encryption vault
│   │   ├── accounts/                   # User management, auth
│   │   ├── chat/                       # Channels, messages, DMs, reactions, pins
│   │   │   ├── chat.ex                 # Context module (public API)
│   │   │   ├── channel.ex
│   │   │   ├── message.ex             # Encrypted content + search_content
│   │   │   ├── message_reaction.ex
│   │   │   ├── dm_conversation.ex
│   │   │   ├── permissions.ex
│   │   │   ├── pins.ex
│   │   │   └── members.ex
│   │   ├── messaging/                  # Real-time delivery (GenServers, PubSub)
│   │   │   ├── messaging.ex
│   │   │   ├── channel_server.ex      # GenServer per channel/DM
│   │   │   ├── channel_registry.ex    # Horde.Registry wrapper
│   │   │   ├── channel_supervisor.ex  # Horde.DynamicSupervisor wrapper
│   │   │   └── envelope.ex            # Broadcast envelope schema
│   │   ├── search/                     # FTS + pgvector + hybrid RRF
│   │   │   ├── search.ex
│   │   │   ├── message_search.ex
│   │   │   └── history_loader.ex
│   │   ├── cache/                      # ETS + Redis
│   │   ├── notifications/              # Online tracking
│   │   │   └── online_tracker.ex
│   │   ├── embeddings/                 # Vector embedding pipeline
│   │   │   ├── embedding_worker.ex    # Oban worker
│   │   │   ├── openai_client.ex       # DeepInfra API client
│   │   │   ├── bumblebee_client.ex    # Local model (dev only)
│   │   │   ├── stub_client.ex         # No-op client (prod fallback)
│   │   │   ├── persistence_listener.ex
│   │   │   └── rag_context.ex
│   │   ├── ai/                         # LLM integration
│   │   │   ├── summarizer.ex
│   │   │   ├── llm_client.ex          # Behaviour + delegation
│   │   │   ├── openai_compatible_client.ex  # DeepInfra streaming client
│   │   │   └── stub_llm_client.ex
│   │   ├── links/                      # Link preview pipeline
│   │   │   ├── link_preview_listener.ex
│   │   │   ├── url_extractor.ex
│   │   │   └── link_preview_fetcher.ex
│   │   └── infrastructure/
│   │       └── snowflake.ex
│   │
│   ├── slackex_web/
│   │   ├── endpoint.ex
│   │   ├── router.ex
│   │   ├── live/
│   │   │   ├── chat_live/
│   │   │   │   ├── index.ex           # Main chat interface (~1800 lines)
│   │   │   │   ├── sidebar_component.ex
│   │   │   │   ├── thread_panel_component.ex
│   │   │   │   ├── search_component.ex
│   │   │   │   ├── summary_modal.ex
│   │   │   │   ├── create_channel_modal.ex
│   │   │   │   ├── browse_channels_modal.ex
│   │   │   │   ├── channel_members_modal.ex
│   │   │   │   ├── invite_link_modal.ex
│   │   │   │   ├── pinned_messages_modal.ex
│   │   │   │   ├── new_dm_modal.ex
│   │   │   │   ├── quick_switcher_modal.ex
│   │   │   │   └── slash_command.ex
│   │   │   └── auth_live/
│   │   ├── controllers/
│   │   │   └── api/                    # JSON API for mobile bootstrap
│   │   └── components/
│   │       ├── core_components.ex
│   │       ├── chat_components.ex      # Message bubbles, compose, reactions, etc.
│   │       └── layouts/
│   │
│   └── slackex_web.ex
│
├── assets/
│   ├── js/
│   │   ├── app.js
│   │   └── hooks/
│   │       ├── message_list.js         # Scroll behavior, infinite scroll
│   │       ├── compose.js              # Auto-resize, typing, emoji shortcodes
│   │       ├── emoji_picker.js         # emoji-mart integration
│   │       ├── emoji_shortcodes.js     # :shortcode: -> native emoji map
│   │       ├── edit_message.js
│   │       └── quick_switcher.js
│   └── css/
├── config/
│   ├── config.exs
│   ├── dev.exs                         # BumblebeeClient enabled
│   ├── test.exs                        # StubClient, StubLLMClient
│   ├── prod.exs                        # OpenAIClient, StubClient (embeddings disabled)
│   └── runtime.exs                     # DeepInfra API keys from env vars
├── test/                               # 1129 tests
│   ├── slackex/                        # Domain context tests
│   ├── slackex_web/                    # LiveView + controller tests
│   └── support/
│       └── factory.ex                  # Test factories
├── docker-compose.yml                  # Local dev (Postgres + Redis)
├── docker-compose.prod.yml             # Production (2 app nodes + Postgres + Redis)
├── Dockerfile                          # Multi-stage production build
├── .github/
│   └── workflows/
│       └── ci-deploy.yml               # CI + deploy on version tags
├── CLAUDE.md                           # AI assistant instructions
└── mix.exs
```
