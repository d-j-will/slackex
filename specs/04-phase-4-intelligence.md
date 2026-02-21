# Phase 4 — Intelligence & Search

## Goal

Add full-text search, pgvector-based semantic search, and an embedding generation pipeline. This phase makes chat history searchable via both keyword and meaning, and lays the foundation for future AI/RAG features (conversation summaries, intelligent Q&A over channel history).

## Prerequisites

Phase 3 complete and all acceptance criteria met.

## Dependencies Added

| Library | Version | Purpose |
|---------|---------|---------|
| pgvector | ~> 0.3 | Vector similarity search via PostgreSQL |
| req | ~> 0.5 | HTTP client for embedding API calls |

## Step 1: Enable pgvector Extension

Migration: `CREATE EXTENSION IF NOT EXISTS vector`

## Step 2: Message Embeddings Table

Create table `message_embeddings` (primary key: `message_id`):

| Column | Type | Constraints |
|--------|------|-------------|
| message_id | bigint | PK (references messages.id — no FK constraint, see note) |
| message_inserted_at | utc_datetime_usec | NOT NULL — copied from message's `inserted_at` (derived from Snowflake ID). Enables partition-aware joins with the partitioned `messages` table. |
| channel_id | bigint | indexed, nullable |
| dm_conversation_id | bigint | indexed, nullable |
| embedding | vector(1536) | OpenAI text-embedding-3-small dimensions |
| content_hash | string(64) | SHA-256 of content, for dedup |
| inserted_at | utc_datetime_usec | no updated_at |

**HNSW index** for fast approximate nearest neighbor search:
```sql
CREATE INDEX idx_embeddings_hnsw ON message_embeddings
  USING hnsw (embedding vector_cosine_ops)
  WITH (m = 16, ef_construction = 64)
```

**No FK to messages:** After Phase 3, messages is a partitioned table with composite PK `(id, inserted_at)`. PostgreSQL doesn't support FK references to partitioned tables unless the FK includes the full partition key. Referential integrity is enforced at the application level. Orphaned embeddings are harmless and can be cleaned by a periodic Oban job.

**DM indexing:** DMs are included in the embedding pipeline. When `EmbeddingWorker` processes a message, it populates either `channel_id` (for channel messages) or `dm_conversation_id` (for DMs), leaving the other NULL. The `PersistenceListener` and `ReconciliationWorker` handle both message types identically — DM messages flow through the same `BatchWriter` persistence path and emit the same `{:messages_persisted, message_ids}` events. **DM search authorization:** DM messages are only returned to participants. Search queries add: `(dm_conversation_id IS NULL OR dm_conversation_id IN (SELECT id FROM dm_conversations WHERE user_a_id = $user_id OR user_b_id = $user_id))`. This ensures DMs never leak to non-participants in any search mode.

## Step 3: Embedding Schema

`Slackex.Embeddings.MessageEmbedding` — Ecto schema with `@primary_key {:message_id, :integer, autogenerate: false}`. Uses `Pgvector.Ecto.Vector` type for the embedding field. This schema lives in the `Embeddings` boundary (not `Chat`) to maintain clean boundary separation — the embedding concern is owned by `Slackex.Embeddings`.

## Step 4: Embedding Client

### 4.1 Behaviour (`Slackex.Embeddings.EmbeddingClient`)

```elixir
@callback generate(text :: String.t()) :: {:ok, [float()]} | {:error, term()}
@callback generate_batch(texts :: [String.t()]) :: {:ok, [[float()]]} | {:error, term()}
@callback dimensions() :: pos_integer()
```

Delegates to the configured client module (`Application.get_env(:slackex, :embedding_client)`).

### 4.2 OpenAI Implementation (`Slackex.Embeddings.OpenAIClient`)

- Model: `text-embedding-3-small`, 1536 dimensions
- Max batch size: 100 texts per API call (larger batches chunked automatically)
- Uses `Req.post/2` to OpenAI API with Bearer auth
- Sorts response by `index` field to preserve input order

### 4.3 Stub Client (`Slackex.Embeddings.StubClient`)

Generates deterministic fake embeddings for testing — uses `phash2(text)` as seed for repeatable pseudo-random vectors, then normalizes to unit length. Config: `test.exs` and `dev.exs` default to stub client.

## Step 5: Embedding Generation Worker

`Slackex.Embeddings.EmbeddingWorker` — Oban worker (queue: `:embeddings`, max_attempts: 3, priority: 3).

**Job types:**
- `%{"message_ids" => [...]}` — fetches unembedded messages (LEFT JOIN excludes already-embedded), generates embeddings in batch, inserts with `on_conflict: :nothing`
- `%{"channel_id" => id, "backfill" => true}` — streams all unembedded messages for a channel, processes in batches of 50 with 1-second pauses for rate limiting

**Enqueue helpers:**
- `enqueue(message_ids)` — chunks into batches of 50, inserts Oban jobs at priority 3
- `enqueue_backfill(channel_id)` — single job with uniqueness constraint (1 hour period)

**Integration via PubSub event bridge:** After successful batch persistence, `BatchWriter` broadcasts `{:messages_persisted, message_ids}` on the internal PubSub topic `"pipeline:events"`.

**Listener:** `Slackex.Embeddings.PersistenceListener` — a dedicated supervised GenServer (not an Oban worker) that subscribes to `"pipeline:events"` in `init/1` and enqueues `EmbeddingWorker` Oban jobs on receipt of `{:messages_persisted, message_ids}` events. This must be a long-lived supervised process because Oban workers are transient job executors — they are started by the Oban queue, run their `perform/1`, and terminate. An Oban worker cannot maintain a persistent PubSub subscription. The listener is added to the application supervisor after Oban (it depends on Oban being available to enqueue jobs).

**Boundary note:** Neither `Pipeline` nor `Messaging` adds `Slackex.Embeddings` to its deps. The event bridge is the sanctioned integration path. `Pipeline` depends on `[Chat, Repo]` (for batch inserts) and uses `Phoenix.PubSub` (OTP infrastructure, not a boundary dep) for the event broadcast. `Embeddings` subscribes independently via `PersistenceListener`.

**Durability safety net:** The PubSub event bridge is ephemeral — if `PersistenceListener` is down during a `{:messages_persisted, ...}` broadcast (process restart, deployment, node failure), those message IDs are silently missed and never enqueued for embedding. To prevent silent decay of semantic search coverage, add a periodic reconciliation Oban cron job:

`Slackex.Embeddings.ReconciliationWorker` — Oban worker (queue: `:embeddings`, cron: every 15 minutes, max_attempts: 1). Queries for messages inserted in the last hour that have no corresponding row in `message_embeddings` (`LEFT JOIN message_embeddings ON ... WHERE embedding IS NULL`), and enqueues `EmbeddingWorker` jobs for the missing IDs in batches of 50. Uses `Oban.insert_all` with uniqueness constraints to avoid duplicate jobs. This ensures that even if the real-time listener misses events, embedding coverage self-heals within 15 minutes.

## Step 6: Search Module

### 6.1 Full-Text Search (`Slackex.Search.MessageSearch.text_search/3`)

Uses PostgreSQL `tsvector/tsquery`:
- Filter: `to_tsvector('english', content) @@ plainto_tsquery('english', query)`
- Rank: `ts_rank(to_tsvector('english', content), plainto_tsquery('english', query))` descending
- **Authorization filter:** Uses a conditional join strategy — not a simple `JOIN subscriptions`. The query filters results as: **(a)** public channels (`channels.is_private = false`) are included for any authenticated user (no subscription required), **(b)** private channels are included only via `JOIN subscriptions` where the user has a membership row, **(c)** DMs (`dm_conversation_id IS NOT NULL`) are included only where the user is a participant (`user_a_id` or `user_b_id`). Implementation: `LEFT JOIN subscriptions ON ... LEFT JOIN dm_conversations ON ... WHERE (channels.is_private = false OR subscriptions.user_id = $user_id OR dm_conversations.user_a_id = $user_id OR dm_conversations.user_b_id = $user_id)`. This is a deliberate policy distinction from the `Permissions` module's `read_messages` check (which governs direct channel access, not search discoverability). See `01-phase-1-foundation.md` Step 6 for the policy rationale.
- Options: `user_id` (required), `channel_id` (scope), `limit` (default 20), `offset`
- Preloads `:sender`

### 6.2 Semantic Search (`Slackex.Search.MessageSearch.semantic_search/3`)

Uses pgvector cosine similarity:
- Generates embedding for the query text via `EmbeddingClient.generate/1`
- Joins `message_embeddings` with `messages` on `(message_id, message_inserted_at) = (id, inserted_at)` — enables PostgreSQL partition pruning on the partitioned messages table
- **Authorization filter:** Same conditional join strategy as `text_search/3` — public channels visible to all authenticated users, private channels restricted to members, DMs restricted to participants
- Filters by similarity threshold (default 0.3)
- Orders by cosine distance ascending (`<=>` operator)
- Returns messages with `:similarity` score attached

### 6.3 Hybrid Search (`Slackex.Search.MessageSearch.hybrid_search/3`)

Combines FTS and semantic search using **Reciprocal Rank Fusion (RRF)**:
```
score(doc) = 1/(k + rank_text) + 1/(k + rank_semantic)  where k = 60
```

Runs both searches in parallel via `Task.async`, merges by message ID, sorts by combined RRF score descending. Returns messages with `:search_score` attached.

### 6.4 Search Context (`Slackex.Search`)

Boundary: `deps: [Chat, Cache, Embeddings, Repo], exports: [MessageSearch, HistoryLoader]`

> **Note on Repo dependency:** `MessageSearch` builds Ecto queries with direct SQL fragments (tsvector, pgvector cosine distance) and executes them via `ReadRepo` (Phase 3+) or `Repo`. `HistoryLoader` also queries the DB on cache miss. Both require `Repo` in the boundary deps. This is consistent with the canonical boundary graph in `00-overview.md`.

Public API:
- `search_messages(user_id, query, opts) :: {:ok, [Message.t()]}` — dispatches to `:text`, `:semantic`, or `:hybrid` mode (default: `:hybrid`). `user_id` is required — all search paths use the conditional join strategy: public channels are visible to any authenticated user, private channels are restricted to members only

## Step 7: Search LiveView Component

`SlackexWeb.ChatLive.SearchComponent` — live component with:
- **State:** query, results, search_mode (`:hybrid` default), searching flag
- **Events:** `"search"` (min 2 chars), `"set_mode"`, `"jump_to_message"`
- **Async pattern:** component sends `{:perform_search, query, mode}` to parent, parent runs search and calls `send_update/2` with results
- **Jump to message:** navigates to the channel, loads messages around the target, pushes `"scroll_to_message"` JS event

## Step 8: RAG-Ready Query Interface

`Slackex.Embeddings.RAGContext` — retrieves relevant message context for LLM consumption.

Public API:
- `retrieve(query, opts) :: {:ok, context_string, count} | {:error, reason}` — runs semantic search, formats as `[timestamp] username: content` lines, truncates to `max_tokens` (default 4000, estimated at 4 chars/token)

## Step 9: Update Application Supervisor (Phase 4)

Children added after Oban in the supervisor tree:
1. `Slackex.Embeddings.PersistenceListener` — **new** (must start after Oban, subscribes to `"pipeline:events"`)

The `ReconciliationWorker` does not need a supervisor entry — it runs as an Oban cron job (configured in Oban's `:plugins` list alongside the existing `CacheWarmer`):
```elixir
{Oban.Plugins.Cron, crontab: [
  {"0 * * * *", Slackex.Workers.CacheWarmer},
  {"*/15 * * * *", Slackex.Embeddings.ReconciliationWorker}
]}
```

## Step 10: Configuration

- `config/config.exs`: `:embedding_client` defaults to `OpenAIClient`
- `config/dev.exs`: `:embedding_client` set to `StubClient`
- `config/test.exs`: `:embedding_client` set to `StubClient`
- `config/runtime.exs` (prod): `:openai_api_key` from `OPENAI_API_KEY` env var

## Embeddings Boundary

`Slackex.Embeddings` — `deps: [Chat, Repo], exports: [EmbeddingWorker, EmbeddingClient, RAGContext, MessageEmbedding]`

## Phase 4 Acceptance Criteria

- [ ] pgvector extension is enabled and message_embeddings table exists with HNSW index
- [ ] Full-text search returns relevant messages ranked by ts_rank
- [ ] Semantic search finds messages with similar meaning (not just matching words)
- [ ] Hybrid search merges FTS and semantic results using Reciprocal Rank Fusion
- [ ] Search can be scoped to a specific channel or search all channels
- [ ] Embedding worker generates embeddings asynchronously via Oban
- [ ] Embedding generation is triggered automatically after successful batch persistence via PersistenceListener
- [ ] PersistenceListener is supervised and restarts on crash without losing future events
- [ ] ReconciliationWorker runs every 15 minutes and enqueues jobs for any unembedded messages
- [ ] Batch embedding supports up to 100 texts per API call
- [ ] Channel backfill job can generate embeddings for existing message history
- [ ] Stub embedding client works in test/dev without an API key
- [ ] Search UI in LiveView shows results with highlighted matches
- [ ] "Jump to message" navigates to the correct channel and scrolls to the message
- [ ] RAGContext.retrieve/2 returns formatted context suitable for LLM consumption
- [ ] Search works across partitioned message tables transparently
- [ ] All behavioral tests from Phases 1-3 still pass
- [ ] New behavioral tests cover: FTS search, semantic search, embedding generation
