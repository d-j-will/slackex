# Embeddings Subsystem Architecture

**Status:** Reference
**Zoom level:** L1 (subsystem)
**Scope:** `Slackex.Embeddings` context — embedding clients (Stub / OpenAI-compatible), the persist → embed → store pipeline, the backfill task, pgvector storage at 384 dimensions, and OTP resilience.

---

## 1. Overview

The Embeddings subsystem turns message text into 384-dimensional vectors so that
`Slackex.Search` can rank messages by semantic similarity (cosine distance), and
so that `Slackex.Search.RAGContext` can pull relevant history into LLM prompts.

The subsystem is built around one deliberate decision: **embedding generation is
non-essential**. If it fails — provider down, model crash, listener restart —
chat keeps serving traffic and search degrades to full-text only. Nothing in the
embedding path is allowed to cascade into the application supervisor.

Two things follow from that decision and shape the whole design:

1. **A behaviour-based client abstraction** (`EmbeddingClient`) lets the actual
   generator be swapped per-environment by config alone. Production calls a remote
   API (DeepInfra); dev and tests use a deterministic stub. No environment loads a
   model in-process.
2. **The generation work is asynchronous Oban jobs**, decoupled from the
   message send path via a PubSub bridge (`pipeline:events`). The send path never
   waits on embeddings, and a failed generation never cascades into the
   application supervisor.

The hot runtime path is:

1. `ChannelServer` persists a batch of messages, then broadcasts
   `{:messages_persisted, ids}` on `pipeline:events`.
2. `PersistenceListener` receives the broadcast and enqueues `EmbeddingWorker` jobs.
3. `EmbeddingWorker` fetches embeddable messages, calls the configured
   `EmbeddingClient`, and upserts vectors into the `message_embeddings` table.
4. A `ReconciliationWorker` cron job sweeps every 15 minutes to catch anything
   the listener missed (process restart, deployment, node down).

---

## 2. C4 Diagrams

### 2.1 System Context

The subsystem sits inside the Slackex application. Its only external dependency
is the embedding provider — and *which* provider is environment-dependent. In
production that is a remote OpenAI-compatible API (DeepInfra); in dev and test it
is a deterministic in-process stub with no external call.

```mermaid
C4Context
  title System Context -- Slackex Embeddings Subsystem

  System(slackex, "Slackex", "Phoenix application; owns the Embeddings context")
  System_Ext(postgres, "PostgreSQL + pgvector", "Stores message_embeddings vectors and serves HNSW cosine search")
  System_Ext(provider, "Embedding Provider", "Generates vectors. PROD: remote OpenAI-compatible API (DeepInfra). DEV/TEST: deterministic in-process stub, no external call")

  Rel(slackex, postgres, "Upserts vectors into and queries by cosine similarity")
  Rel(slackex, provider, "Requests embeddings from", "HTTP (prod) / in-process stub (dev, test)")
```

### 2.2 Container Diagram

```mermaid
C4Container
  title Container Diagram -- Slackex Embeddings Subsystem

  Container_Boundary(slackex, "Slackex Application") {
    Container(channel_server, "ChannelServer", "GenServer", "Persists message batches, broadcasts pipeline:events")
    Container(pubsub, "Phoenix.PubSub", "Event bus", "Carries {:messages_persisted, ids} on pipeline:events")
    Container(listener, "PersistenceListener", "GenServer (restart: :temporary)", "Subscribes to pipeline:events, enqueues EmbeddingWorker jobs")
    Container(recon, "ReconciliationWorker", "Oban cron (every 15m)", "Safety net: finds messages missing embeddings in the last hour")
    Container(worker, "EmbeddingWorker", "Oban worker, queue :embeddings", "Batch embed + backfill; generates and upserts vectors")
    Container(client, "EmbeddingClient", "Behaviour facade", "Delegates to configured client implementation")
    Container(stub, "StubClient", "Module", "Deterministic seeded vectors (dev/test/default)")
    Container(openai, "OpenAIClient", "Module", "Calls remote OpenAI-compatible API (prod)")
  }

  ContainerDb(postgres, "PostgreSQL + pgvector", "message_embeddings, vector(384), HNSW index")
  System_Ext(provider, "Remote Embedding API", "DeepInfra (prod only)")

  Rel(channel_server, pubsub, "Broadcasts {:messages_persisted, ids} to")
  Rel(pubsub, listener, "Delivers persisted-message events to")
  Rel(listener, worker, "Enqueues batch jobs via EmbeddingWorker.enqueue/1")
  Rel(recon, worker, "Enqueues catch-up jobs via EmbeddingWorker.enqueue/1")
  Rel(worker, client, "Requests vectors through")
  Rel(client, stub, "Delegates to (when configured)")
  Rel(client, openai, "Delegates to (when configured)")
  Rel(openai, provider, "POSTs batches to", "HTTP")
  Rel(worker, postgres, "Upserts vectors into")
```

---

## 3. How To Read This Document

- Start with the **System Context** to see the one external dependency and how it
  changes per environment.
- Use the **Container Diagram** to see the producer → consumer chain:
  `ChannelServer` → PubSub → `PersistenceListener` → `EmbeddingWorker` → Postgres.
- Use the **Client Selection** section (§5) to understand why there are two
  client implementations and which one runs where.
- Use the **sequence diagrams** (§7) for runtime ordering, including the snooze /
  reconciliation behaviour that makes the pipeline self-healing.
- Use **Failure Modes & Resilience** (§9) to understand blast radius and why
  nothing here can take the app down.

### Terms Used Here

| Term | Meaning |
|---|---|
| Embedding | A 384-element float vector representing a message's `search_content` |
| Client | An `EmbeddingClient` behaviour implementation (Stub / OpenAI) |
| Backfill | A bulk job that embeds all unembedded messages for a channel or DM |
| Reconciliation | The cron sweep that catches messages the listener missed |
| `content_hash` | SHA-256 of `search_content`; detects when a message needs re-embedding |

---

## 4. Main Components

| Component | Responsibility |
|---|---|
| `Slackex.Embeddings.EmbeddingClient` | Behaviour + delegation facade; reads `:embedding_client` config and forwards `generate/1`, `generate_batch/1`, `dimensions/0` |
| `Slackex.Embeddings.StubClient` | Deterministic seeded vectors (384-dim); no I/O. Default + dev + test |
| `Slackex.Embeddings.OpenAIClient` | Calls a remote OpenAI-compatible embeddings API via `Req`. Prod |
| `Slackex.Embeddings.PersistenceListener` | Subscribes to `pipeline:events`, enqueues `EmbeddingWorker` jobs |
| `Slackex.Embeddings.EmbeddingWorker` | Oban worker: batch embed + channel/DM backfill; upserts vectors |
| `Slackex.Embeddings.ReconciliationWorker` | Oban cron (every 15m): finds and enqueues missed messages |
| `Slackex.Embeddings.MessageEmbedding` | Ecto schema for the `message_embeddings` table |

The context module `Slackex.Embeddings` declares a `Boundary` with
`deps: [Slackex.Chat]` and explicit exports, so the rest of the app may only
reach these public modules (`lib/slackex/embeddings/embeddings.ex`). RAG
formatting lives on the consumer side as `Slackex.Search.RAGContext` — moving
it there (slackex-n3c) broke a `Search <-> Embeddings` dependency cycle.

---

## 5. Client Selection: Two Implementations, One Behaviour

`EmbeddingClient` defines a three-callback behaviour and delegates each call to
`Application.get_env(:slackex, :embedding_client)`
(`lib/slackex/embeddings/embedding_client.ex`). Swapping providers is a config
change, not a code change — the worker, listener, and search code never name a
concrete client.

| Environment | Configured client | Where the work happens | Source |
|---|---|---|---|
| default (`config.exs`) | `StubClient` | in-process, deterministic | `config/config.exs:116` |
| dev (`dev.exs`) | `StubClient` | in-process, deterministic | `config/dev.exs:118` |
| test (`test.exs`) | `StubClient` | in-process, deterministic | `config/test.exs:77` |
| **prod (`prod.exs`)** | **`OpenAIClient`** | **remote API (DeepInfra)** | `config/prod.exs:26` |

There is no environment that runs the model locally. Dev defaults to the stub so
a checkout needs no API key and no ML toolchain to boot; a developer who wants
*real* vectors in dev points `:embedding_client` at `OpenAIClient` with a
DeepInfra key, exactly as prod does (`config/dev.exs`).

### 5.1 Why production uses a remote API, not a local model

This is the central, non-obvious — and now settled — architectural decision.
Production generates vectors from `sentence-transformers/all-MiniLM-L6-v2`
(384-dim) by calling DeepInfra over HTTP; it never loads the model in-process.
The reason is infrastructure, not quality:

- **GPU is off-limits in production.** The prod Docker host is an unprivileged
  LXC on a mini-PC with a flaky GPU. EXLA GPU access has crashed the physical
  Proxmox host.
- **CPU EXLA OOMs the LXC.** Even CPU-only local inference of the model exhausts
  the ~20 GB LXC memory.
- **Therefore all local ML inference has been removed from the codebase.** The
  EXLA + Bumblebee + Nx stack was deleted (commit d20a715); `OpenAIClient` points
  at DeepInfra and returns 384-dim vectors with no EXLA, no GPU, and no local
  memory pressure (`config/prod.exs`).

> **Historical note:** an earlier prod attempt activated an in-process
> `BumblebeeClient` and triggered the v0.5.36–v0.5.43 cascade outage (see §10).
> After that incident prod ran `StubClient` as a stopgap, then moved to the
> remote `OpenAIClient` so production keeps *real* semantic search without local
> inference. The local-inference stack (`BumblebeeClient`, `EmbeddingServing`,
> `Embeddings.Supervisor`, and the `bumblebee`/`exla`/`nx` deps) has since been
> removed entirely; only the two remote/stub clients remain. Older project notes
> that describe in-process inference or "StubClient in prod" are stale.

### 5.2 Client behaviour details

- **StubClient** seeds `:rand` with `:erlang.phash2(text)` and L2-normalizes the
  result, so the same input always yields the same unit vector. No network, no
  process to crash (`lib/slackex/embeddings/stub_client.ex`). It backs the
  default, dev, and test environments.
- **OpenAIClient** enforces a max batch of 100, sorts response vectors by the
  `index` field to preserve input order, and emits a
  `[:slackex, :ai, :embedding]` telemetry event with duration, token usage, and
  batch size (`lib/slackex/embeddings/openai_client.ex`).

### 5.3 Dimensionality (384) and a configuration sharp edge

The `message_embeddings.embedding` column is `vector(384)`, so every client must
produce 384-dim vectors. `StubClient` hard-codes `@dimensions 384`.
`OpenAIClient` is the exception: its compiled-in defaults are
`text-embedding-3-small` at **1536** dimensions. Production only gets 384 because
`runtime.exs` sets `:embedding_api` (model `all-MiniLM-L6-v2`,
`EMBEDDING_DIMENSIONS` defaulting to `"384"`) **when `EMBEDDING_API_KEY` is
present** (`config/runtime.exs:127-140`). If that env var is unset in prod,
`OpenAIClient.dimensions/0` falls back to 1536 and any 1536-dim vector would fail
to insert into the `vector(384)` column. **Prod must set `EMBEDDING_API_KEY`** (and,
for non-default providers, `EMBEDDING_MODEL` / `EMBEDDING_DIMENSIONS`).

---

## 6. Data Model

The subsystem owns one table, `message_embeddings`
(`lib/slackex/embeddings/message_embedding.ex`,
`priv/repo/migrations/20260303185600_create_message_embeddings.exs`,
`priv/repo/migrations/20260304000000_resize_embeddings_to_384.exs`).

```mermaid
erDiagram
  messages ||--o| message_embeddings : "0 or 1 embedding"

  message_embeddings {
    bigint message_id PK "= messages.id, autogenerate false"
    timestamptz message_inserted_at "denormalized from messages"
    bigint channel_id "denormalized, indexed"
    bigint dm_conversation_id "denormalized, indexed"
    vector_384 embedding "Pgvector.Ecto.Vector"
    string content_hash "SHA-256 hex, length 64"
    timestamptz inserted_at
  }
```

Design points and the reasoning behind them:

- **Primary key is `message_id`** (not an autogenerated id): each message has at
  most one embedding, so the message id *is* the identity. This is also what
  makes the upsert one-to-one.
- **`content_hash`** is the SHA-256 hex digest of `search_content`. The worker
  re-embeds only when the stored hash differs from the current content hash, so
  an edited message gets a fresh vector and an unchanged message is skipped
  (`embedding_worker.ex` `fetch_embeddable_messages/1` and `compute_content_hash/1`).
- **`channel_id` / `dm_conversation_id` are denormalized** so backfill and
  scoped queries don't need to join back to `messages`. Both are indexed.
- **`message_inserted_at` is denormalized** from `messages`. The `messages` table
  is partitioned by insertion time, so carrying the timestamp here lets vector
  rows be filtered/joined without forcing a partition scan on the parent table.
- **HNSW index** (`idx_embeddings_hnsw`, `vector_cosine_ops`,
  `m = 16, ef_construction = 64`) gives approximate nearest-neighbour cosine
  search. The resize migration drops and recreates this index because the
  column type changed from `vector(1536)` to `vector(384)`.

Embeddings are **immutable by row**: the worker upserts with
`on_conflict: {:replace, [:embedding, :content_hash, :inserted_at]}, conflict_target: :message_id`
(`embedding_worker.ex:186-189`). Because this is an explicit `{:replace, ...}`
(not `on_conflict: :nothing`), there is no nil-id ghost-struct to handle here —
the conflict path returns the replaced row, not a phantom struct.

---

## 7. Runtime Flows

### 7.1 Persist → embed → store (the normal path)

```mermaid
sequenceDiagram
  participant CS as ChannelServer
  participant PubSub as Phoenix.PubSub
  participant PL as PersistenceListener
  participant W as EmbeddingWorker (Oban)
  participant C as EmbeddingClient
  participant Prov as Provider (Stub / DeepInfra API)
  participant DB as Postgres (message_embeddings)

  CS->>CS: batch persisted ({:batch_result, ref, :ok})
  CS->>PubSub: broadcast pipeline:events {:messages_persisted, ids}
  PubSub-->>PL: {:messages_persisted, ids}
  PL->>W: EmbeddingWorker.enqueue(ids)  (chunks of 50)

  Note over W: per Oban job (queue :embeddings, max_attempts 3)
  W->>DB: fetch embeddable (not deleted, hash mismatch)
  W->>C: generate_batch(search_contents)
  C->>Prov: produce vectors
  Prov-->>C: 384-dim vectors
  C-->>W: {:ok, vectors}
  W->>DB: upsert each (on_conflict replace, target message_id)
```

Notes:

- `enqueue/1` chunks message IDs into batches of 50 and inserts one Oban job per
  batch at priority 3 (`embedding_worker.ex`).
- The worker calls the configured client (`StubClient` or `OpenAIClient`)
  directly — there is no in-process serving process to pre-flight, so the
  serving-availability snooze branch that once guarded the local model is gone
  (removed with the local-inference stack in commit d20a715).
- Generation failure returns `{:error, reason}` (logged), which propagates to
  Oban so the job retries with backoff. The return value is **never** discarded —
  this is the rule that the v0.5.36 outage was caused by violating.

### 7.2 Reconciliation safety net

```mermaid
sequenceDiagram
  participant Cron as Oban Cron (*/15)
  participant R as ReconciliationWorker
  participant DB as Postgres
  participant W as EmbeddingWorker

  Cron->>R: perform/1
  R->>DB: LEFT JOIN messages/message_embeddings,<br/>inserted_at >= now()-1h, no embedding, has search_content
  DB-->>R: unembedded message ids
  R->>W: enqueue(ids) in batches of 50
```

The reconciliation sweep runs every 15 minutes (cron schedule at
`config/config.exs:81`) with a **1-hour lookback**
(`@lookback_window_seconds 3_600` in `reconciliation_worker.ex`). It exists because the
`pipeline:events` → `PersistenceListener` bridge is fire-and-forget: if the
listener is down during a broadcast (restart, deploy, node failure), that event
is simply missed. The cron catches those messages within 15 minutes. The
trade-off is explicit: messages older than an hour that were missed will not be
back-filled by this sweep (a one-off `enqueue_backfill/1` job can cover those).

### 7.3 Backfill

`EmbeddingWorker.enqueue_backfill(channel_id: id)` (or `dm_conversation_id:`)
inserts a single job, made unique per scope for a 1-hour window so concurrent
requests don't stack up (`embedding_worker.ex:62-85`). The job streams *all*
unembedded messages for that scope, processes them in batches of 50, and sleeps
1 second between batches to avoid saturating the `:embeddings` queue and the
provider. Backfill is best-effort: a failing batch is logged and the stream
continues rather than aborting the whole backfill
(`embedding_worker.ex:222-238`).

---

## 8. Key Design Properties

- **Config-only provider swap.** Every consumer talks to the `EmbeddingClient`
  facade; the concrete client is chosen by `:embedding_client` config per env.
- **Non-essential by construction.** Generation is async Oban work behind a
  PubSub bridge; the chat send path never blocks on it.
- **No local inference anywhere.** Prod calls DeepInfra
  (`all-MiniLM-L6-v2`, 384-dim) over HTTP; dev and test use the deterministic
  stub. No environment loads an ML model into the BEAM, so prod hardware never
  runs EXLA/Bumblebee.
- **Self-healing.** The 15-minute reconciliation sweep re-enqueues anything the
  fire-and-forget listener missed, so transient failures recover without manual
  intervention.
- **Idempotent, content-addressed writes.** `content_hash` skips unchanged
  messages and re-embeds edited ones; the upsert replaces by `message_id`.
- **Loud failures.** Generation errors are logged and propagated to Oban for
  retry; nothing is swallowed.

---

## 9. Failure Modes & Resilience

The governing rule (project CLAUDE.md, "Production Resilience"): a crash in
embeddings must not propagate to unrelated subsystems. With local inference
removed, the remaining embedding process is the `PersistenceListener` bridge; the
spine of the guarantee is `restart: :temporary` on that non-essential listener,
plus the reconciliation safety net. There is no longer any in-process model or
serving supervisor to crash.

| Failure | Detection | Response | Blast radius |
|---|---|---|---|
| Remote API error / timeout (prod) | `OpenAIClient` returns `{:api_error, ...}` / `{:network_error, ...}` | Worker logs + returns `{:error, ...}`; Oban retries with backoff (max 3 attempts) | That batch's messages stay unembedded until retry/reconciliation |
| `PersistenceListener` down during broadcast | No subscriber receives the fire-and-forget event | `ReconciliationWorker` (every 15m, 1h lookback) re-enqueues missed messages | Up to ~15-minute delay for affected messages |
| `PersistenceListener` repeatedly crashing | Supervisor would normally restart it | Started `restart: :temporary` so repeated crashes can't exhaust the **root** supervisor budget and take down the app | App unaffected; ReconciliationWorker covers gaps |
| DB unavailable during upsert | Query raises in `perform/1` | Exception propagates to Oban; retried with backoff | Job-local; consistent with rest of app |
| Backfill batch failure | Logged inside `generate_and_persist_embeddings/1` | Stream continues with remaining batches (best-effort) | Only the failed batch's messages |

Two structural facts make this hold:

1. **No serving process is ever started.** With `BumblebeeClient`,
   `EmbeddingServing`, and `Embeddings.Supervisor` deleted, `application.ex` no
   longer has a `maybe_embedding_serving/1` clause — no environment loads an ML
   model into the BEAM, so there is no model memory and no serving crash to
   contain.
2. **The PubSub→Oban bridges are `restart: :temporary`** in the application
   children list (`application.ex`): `PersistenceListener` and
   `LinkPreviewListener` (plus `Factory.ChannelNotifier` and `Andon.Listener`).
   The comment there is explicit — `:permanent` restart on a repeatedly-crashing
   listener would exhaust the root supervisor budget and take down the app; the
   listeners are non-essential and `ReconciliationWorker` is the durability
   safety net.

---

## 10. Incident Precedent (why the resilience exists)

The v0.5.36–v0.5.43 production outage is the reason for nearly every control in
§9. In-process `BumblebeeClient` was activated in prod, and:

- the worker swallowed errors (`_ = result; :ok`), so Oban never saw failures and
  never retried;
- there was no pre-flight serving check, so jobs hammered a dead serving process;
- the supervisor used `restart: :permanent`, so its repeated deaths exhausted the
  root supervisor budget and crashed the whole app;
- EXLA probed the GPU on NIF load and crashed the physical Proxmox host; CPU-only
  EXLA then OOMed the 20 GB LXC.

The immediate fixes at the time were error propagation to Oban, a `{:snooze, 30}`
pre-flight serving check, a `restart: :temporary` + 5/300s serving budget,
conditional serving start, and compile-time `EXLA_TARGET=host`. The durable
resolution was to stop running the model in-process at all: prod moved to the
remote DeepInfra API, and the local-inference stack (`BumblebeeClient`,
`EmbeddingServing`, `Embeddings.Supervisor`, the serving pre-flight/snooze
branch, and the `bumblebee`/`exla`/`nx` deps) was later deleted outright (commit
d20a715). What remains in the current code is the part still relevant without a
local model — error propagation to Oban and the reconciliation safety net; the
serving-specific controls are gone because the process they guarded no longer
exists. A deeper treatment of the supervision reasoning, restart-budget maths,
and recovery sequencing at the time of the incident lives in the companion
deep-dive (see Related Documents), which remains a historical record.

---

## 11. Search & RAG Integration (boundary)

Embeddings *produces and stores* vectors; `Slackex.Search.MessageSearch` *queries*
them. The boundary is clean:

- `MessageSearch.semantic_search/3` runs pgvector cosine similarity against
  `message_embeddings` with a default similarity threshold of 0.3, enforcing
  authorization via **EXISTS subqueries** (not joins) to avoid row duplication
  that would corrupt ranking. `hybrid_search/3` fuses full-text and semantic
  results via Reciprocal Rank Fusion (`@rrf_k 60`)
  (`lib/slackex/search/message_search.ex`).
- `Slackex.Search.RAGContext.retrieve/2` calls **`semantic_search/3` only**
  (not hybrid), then formats the top results as `"[YYYY-MM-DD HH:MM] username:
  content"` lines, truncated to a token budget (default 4000 tokens, ~4
  chars/token) without cutting a line (`lib/slackex/search/rag_context.ex`).

The search UI itself is gated by the `:message_search` FunWithFlags flag
(`lib/slackex_web/live/chat_live/index.ex:128`). Ranking, fusion, and FTS detail
belong to the search documentation, not here.

---

## 12. Code Map

| File | Responsibility |
|---|---|
| `lib/slackex/embeddings/embeddings.ex` | Context module + `Boundary` definition and exports |
| `lib/slackex/embeddings/embedding_client.ex` | Behaviour + config-driven delegation facade |
| `lib/slackex/embeddings/stub_client.ex` | Deterministic seeded 384-dim client (default/dev/test) |
| `lib/slackex/embeddings/openai_client.ex` | Remote OpenAI-compatible API client + telemetry (prod) |
| `lib/slackex/embeddings/persistence_listener.ex` | `pipeline:events` → `EmbeddingWorker` bridge |
| `lib/slackex/embeddings/embedding_worker.ex` | Oban worker: batch embed + backfill + upsert |
| `lib/slackex/embeddings/reconciliation_worker.ex` | Oban cron safety net for missed messages |
| `lib/slackex/embeddings/message_embedding.ex` | Ecto schema for `message_embeddings` |
| `lib/slackex/application.ex` | `restart: :temporary` listener supervision specs |
| `config/{config,dev,test,prod,runtime}.exs` | Per-env `:embedding_client` and `:embedding_api` |
| `priv/repo/migrations/20260303185600_create_message_embeddings.exs` | Initial table + HNSW index (1536-dim) |
| `priv/repo/migrations/20260304000000_resize_embeddings_to_384.exs` | Resize column + index to 384-dim |

---

## 13. Related Documents

- [`deep-dive-embedding-resilience.md`](deep-dive-embedding-resilience.md) — L2 deep dive into the embedding supervision tree, restart-budget reasoning, snooze/reconciliation recovery sequencing, and the v0.5.36 cascade post-mortem in OTP terms
- [`realtime-chat.md`](realtime-chat.md) — the `ChannelServer` → `BatchWriter` path that produces the `pipeline:events` broadcast this subsystem consumes
- [`../runbooks/observability.md`](../runbooks/observability.md) — metrics and traces, including the `[:slackex, :ai, :embedding]` telemetry event
- [`../research/embedding-provider-evaluation.md`](../research/embedding-provider-evaluation.md) — why prod moved to a remote provider instead of local inference
- [`../rca/2026-03-05-embedding-cascade-app-crash.md`](../rca/2026-03-05-embedding-cascade-app-crash.md) — root cause analysis of the v0.5.36–v0.5.43 outage
- [`../engineering-principles.md`](../engineering-principles.md) — cross-cutting deploy-safety, test-isolation, and production-hardening rules
