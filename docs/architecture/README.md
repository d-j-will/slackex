# Slackex Architecture Docs

A zoom-level reading map for the Slackex architecture. Start at **L0** for the
whole-system picture, drop into an **L1** subsystem doc for a single bounded
context, then read an **L2 deep dive** when you need the mechanism behind a
particular guarantee. **Cross-cutting** docs span every subsystem.

```
L0  System landscape ............ the one map that points at everything
L1  Subsystem architecture ...... one doc per bounded context
L2  Deep dives .................. the interesting/hard mechanisms
X   Cross-cutting ............... data model, deployment, feature flags
```

---

## L0 — System Landscape (start here)

- [System Landscape](system-landscape.md) — Whole-application C4 System Context +
  Container view: the Phoenix endpoint, the LiveView tier, all bounded contexts,
  PostgreSQL, PubSub, and the external integrations that hang off the edges.

---

## L1 — Subsystem Architecture (one per bounded context)

- [Chat Context](chat.md) — `Slackex.Chat`: channels, messages, members,
  moderation, DMs, and the public facade other contexts call.
- [Accounts & Authentication](accounts-and-auth.md) — `Slackex.Accounts`: users,
  registration, sessions, Guardian/auth, profiles, online status.
- [Message Pipeline & Persistence](message-pipeline-and-persistence.md) —
  `Slackex.Messaging` + `Slackex.Pipeline`: how a message goes from send to
  durable, ordered, encrypted storage.
- [Search & Intelligence](search-and-intelligence.md) — `Slackex.Search`:
  full-text search, semantic/vector search, hybrid RRF fusion, RAG.
- [Embeddings Subsystem](embeddings.md) — `Slackex.Embeddings`: BumblebeeClient
  vs StubClient, the embedding worker pipeline, vector generation and storage.
- [AI & Summarization](ai-summarization.md) — `Slackex.AI`: LLM clients,
  conversation/DM summarization, streaming responses (Req `into: :self`).
- [Integrations (Webhooks & MCP)](integrations.md) — `Slackex.Integrations`:
  incoming webhooks (`POST /api/webhooks/:token`, bot users, hashed tokens) and
  the MCP server surface.
- [Sous (Decision Event-Sourcing)](sous.md) — `Slackex.Sous`: the event-sourced
  decision feature (`/decide` modal → decision cards and projections).
- [Dark Factory](dark-factory.md) — `Slackex.Factory`: the factory run/work
  coordination system exposed via MCP (`queue_factory_run`, claim/submit).
- [Links & Link Previews](links-and-previews.md) — `Slackex.Links`: URL
  extraction, link preview fetching/unfurling, the `LinkPreviewWorker`.
- [Content Rendering & Markdown](content-and-markdown.md) — `Slackex.Markdown`:
  Earmark + custom Scrubber + chat preprocessor, the `:markdown_rendering` flag.
- [Encryption at Rest](encryption-at-rest.md) — `Slackex.Encrypted`: Cloak
  vaults, encrypted Ecto field types, key management, the plaintext companion
  column.
- [Analytics](analytics.md) — `Slackex.Analytics` + the AnalyticsTracker
  LiveView hook: what events are captured and where they land.
- [Caching & Read Model](caching-and-read-model.md) — `Slackex.Cache` +
  `Slackex.ReadRepo`: the read-side / CQRS read model, in-process or Redis cache.
- [Observability & Operations](observability-and-ops.md) — `Slackex.Ops` + the
  OTEL/metrics stack: traces (OTEL Collector → Tempo), Prometheus metrics,
  Grafana.
- [Web Tier & LiveView](web-and-liveview.md) — `slackex_web` architecture: router
  and pipelines, the LiveView modules (chat_live, sous_live, etc.), components.
- [Notifications](notifications.md) — Presence tracking, push preferences, device
  subscriptions, catch-up, and push delivery.

---

## L2 — Deep Dives (important / interesting mechanisms)

- [Hybrid RRF Search](deep-dive-hybrid-rrf-search.md) — The Reciprocal Rank
  Fusion algorithm fusing FTS and vector results, and the EXISTS-based
  authorization SQL.
- [Embedding Pipeline Resilience](deep-dive-embedding-resilience.md) — OTP
  supervision design for embeddings: `restart: :temporary`, dedicated
  supervisor, blast-radius containment.
- [Sous Event Sourcing & CQRS](deep-dive-event-sourcing-sous.md) — The
  event-sourcing tracer: command → event → projection flow, event store schema,
  projections.
- [Encrypted Fields with Full-Text Search](deep-dive-encrypted-fields-fts.md) —
  The tension between Cloak encryption and searchability, resolved via the
  plaintext `search_content` column.
- [The `pipeline:events` Bridge](deep-dive-pipeline-events-bridge.md) — The
  PubSub bridge from message persistence to downstream consumers (link previews,
  embeddings).
- [Snowflake IDs & Table Partitioning](deep-dive-snowflake-partitioning.md) —
  Snowflake ID generation (structure, ordering guarantees, generator process)
  and the partitioned messages table.
- [Multi-Node & Horde](deep-dive-multi-node-horde.md) — Distributed runtime:
  libcluster topology, Horde distributed supervisor/registry for ChannelServer.
- [Streaming LLM Responses (Req `into: :self`)](deep-dive-req-streaming.md) — The
  Req `into: :self` streaming pattern: raw Mint messages, `Req.parse_message/2`,
  async response cleanup.
- [Realtime Chat](realtime-chat.md) — The core realtime messaging path: LiveView
  chat, Phoenix Channel clients, PubSub fanout, and batched async persistence.
- [Threads & Reactions](threads-and-reactions.md) — Thread replies, reply-count
  propagation, reaction toggles, and the LiveView update flow.

---

## Cross-Cutting

- [Data Model & ERD](data-model-erd.md) — Entity-relationship overview of the
  major Ecto schemas and their relationships (users, channels, messages, and
  more).
- [Deployment Topology](deployment-topology.md) — How the system is built and
  deployed: GitHub Actions CI/CD, GHCR images, SSH-to-LXC deploy, the production
  topology.
- [Feature Flags & Lifecycle](feature-flags-and-lifecycle.md) — The
  FunWithFlags-based feature flag system: how flags gate context + LiveView +
  routes, and the flag lifecycle.
- [Background Jobs & Workers](background-jobs-and-workers.md) — The Oban
  ecosystem: all 11 workers across 6 queues, cron schedules, enqueue paths
  (incl. the `pipeline:events` bridge), and the `perform/1`-return rule.

---

## Design Proposals

- [Chat Domain: As-Is & To-Be](chat-domain-as-is-to-be.md) — *(Proposed)* The
  current `Slackex.Chat` facade and a proposed deeper public chat interface, with
  caller-dependency cleanup.

---

## Related Design Docs

The docs above describe runtime behavior and component boundaries. For the
design *history* and decisions behind a specific feature, or for operational
procedures, look here instead:

- **Feature design docs** — per-feature architecture and ADRs:
  - [`docs/feature/dark-factory/design/`](../feature/dark-factory/design/)
  - [`docs/feature/incoming-webhooks/design/`](../feature/incoming-webhooks/design/)
  - [`docs/feature/markdown-rendering/design/`](../feature/markdown-rendering/design/)
  - [`docs/feature/mcp-server/design/`](../feature/mcp-server/design/)
  - [`docs/feature/sous/design/`](../feature/sous/design/)
- **Runbooks** — operational procedures: [`docs/runbooks/`](../runbooks/)
  (deployment, model deployment, observability, manual resilience checks,
  agent-ops dogfood).
- **RCAs** — root cause analyses for past production incidents:
  [`docs/rca/`](../rca/)
- **UI/UX design** — component system, design system, information architecture:
  [`docs/design/`](../design/)
- **Engineering principles** — cross-cutting operational and delivery rules:
  [`docs/engineering-principles.md`](../engineering-principles.md)

---

## Scope Guide

- **Reading top-down?** Start at L0 (System Landscape), then pick the L1
  subsystem you care about, then drill into its L2 deep dives.
- **Want runtime behavior and component boundaries?** Use the docs in *this*
  directory.
- **Want the design history and decisions for a specific feature?** Use the
  `docs/feature/*/design/` docs under *Related Design Docs*.
- **Need to operate the system?** Use `docs/runbooks/`.
- **Investigating a past failure?** Use `docs/rca/`.
