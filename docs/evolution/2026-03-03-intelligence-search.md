# Intelligence & Search: Feature Evolution

**Date:** 2026-03-03
**Status:** Complete
**Project ID:** intelligence-search
**Test Count:** 946 (0 failures)
**Duration:** ~86 minutes (18:54 - 20:22 UTC on 2026-03-03)

## Summary

Phase 4 Intelligence & Search -- pgvector-powered semantic search, PostgreSQL full-text search, hybrid search with Reciprocal Rank Fusion, an event-driven embedding pipeline, and a RAG-ready query interface for the Slackex messaging application. The feature enables users to find messages across channels and DMs using natural language queries, combining keyword matching (FTS) with meaning-based retrieval (vector similarity) for superior recall. All search results are authorization-scoped: users only see messages from channels they belong to and DM conversations they participate in. The feature is deployed behind a `:message_search` feature flag, defaulting to disabled until PO approval.

## Motivation

- Users have no way to search message history beyond manual scrolling. As conversation volume grows, finding specific information becomes impractical.
- Keyword search alone misses semantically relevant results (e.g., searching "deploy" won't find messages about "shipping to production"). Semantic search via vector embeddings addresses this gap.
- Hybrid search (FTS + semantic) with Reciprocal Rank Fusion provides the best of both approaches: exact keyword hits and conceptual relevance, merged into a single ranked result set.
- A RAG-ready context interface prepares the codebase for future LLM-powered features (e.g., channel summarization, Q&A bots) without additional search infrastructure.

## Architecture Decisions

### pgvector with HNSW indexing for cosine similarity

Vector embeddings are stored in a `message_embeddings` table using the pgvector extension with `vector(1536)` columns (matching OpenAI text-embedding-3-small dimensions). An HNSW index with `m=16` and `ef_construction=64` provides approximate nearest-neighbor search with cosine distance. HNSW was chosen over IVFFlat because it provides better recall without requiring periodic retraining of cluster centroids as the dataset grows. The index parameters balance recall accuracy against memory footprint for the expected message volume.

### search_content plaintext companion column for encrypted messages

Message content is encrypted at rest via Cloak.Ecto (from the encryption-at-rest feature). Since encrypted fields cannot be indexed or searched directly, full-text search requires a plaintext `search_content` column on the messages table. This column stores a copy of the message content specifically for the FTS GIN index (`to_tsvector('english', search_content)`). The embedding pipeline also reads from `search_content` to generate vectors. This is a deliberate tradeoff: search functionality requires readable text, and the column is explicitly scoped to search indexing.

### EXISTS-based authorization preventing row duplication

Search queries enforce authorization using EXISTS subqueries rather than JOINs. A JOIN between messages and channel_members/dm_participants would multiply rows when a user has multiple membership paths to the same message (e.g., a message in a public channel the user also has an explicit membership record for). EXISTS returns a boolean per message row, preventing duplication in ranked results. Three authorization paths are checked: public channel membership, private channel subscription, and DM conversation participation.

### Event-driven embedding pipeline

The embedding pipeline follows an event-driven architecture: `BatchWriter` (Pipeline boundary) broadcasts `{:messages_persisted, message_ids}` on the `"pipeline:events"` PubSub topic after successful batch inserts. `PersistenceListener` (Embeddings boundary) subscribes to this topic and enqueues `EmbeddingWorker` Oban jobs for the persisted message IDs. PubSub is OTP infrastructure shared between boundaries -- Embeddings subscribes independently without importing Pipeline, avoiding circular dependencies. The worker looks up `channel_id`/`dm_conversation_id` from the database, so the event payload contains only message IDs.

### ReconciliationWorker for self-healing missed events

An Oban cron job (`ReconciliationWorker`) runs every 15 minutes with a 1-hour lookback window. It finds messages without corresponding embeddings via a LEFT JOIN and enqueues them in batches of 50. This handles edge cases where PubSub events are lost (e.g., PersistenceListener restart, node crash, network partition). The 1-hour lookback is wide enough to catch stragglers without reprocessing the entire history on each run.

### Reciprocal Rank Fusion (k=60) for hybrid search

Hybrid search runs FTS and semantic search concurrently via `Task.async`, then merges results using Reciprocal Rank Fusion with `k=60`. RRF was chosen over linear score combination because FTS `ts_rank` scores and cosine similarity scores are on different scales -- normalizing them would require arbitrary weighting. RRF operates on rank positions only, making it scale-agnostic. `k=60` is the standard constant from the original RRF paper (Cormack et al.), providing a good balance between favoring top-ranked results and allowing lower-ranked results to contribute.

### FunWithFlags feature flag guarding both UI and context

The `:message_search` flag guards the feature at two levels: the LiveView template (search component is not rendered when disabled) and the `Slackex.Search.search_messages/3` context function (returns `{:error, :feature_disabled}` when disabled). Dual guarding prevents API-level access to search when the UI is hidden. The flag defaults to disabled and requires explicit PO approval for global enable.

### Dependency injection via opts for testability

All modules that depend on external services (EmbeddingClient, PubSub) accept the implementation via an `opts` keyword list parameter, with defaults read from application config. Tests pass alternative implementations (StubClient, FailingClient) directly without any mock framework. This keeps tests fast, deterministic, and free of mock-related coupling. The `StubClient` generates deterministic vectors via `phash2` seeding, ensuring reproducible similarity scores across test runs.

## Implementation Phases

### Phase 01: Database Foundation and Schema (Steps 01-01 through 01-03)

| Commit | Step | Description |
|--------|------|-------------|
| `767a515` | 01-01 | Deploy-safe migration enabling pgvector extension with IF NOT EXISTS idempotency |
| `310d982` | 01-02 | Create message_embeddings table with vector(1536) column, HNSW index (m=16, ef_construction=64, cosine), btree indexes on channel_id and dm_conversation_id |
| `159f3b9` | 01-03 | MessageEmbedding Ecto schema, Postgrex custom types module for vector support, Repo configured with custom types |

### Phase 02: Embedding Pipeline (Steps 02-01 through 02-03)

| Commit | Step | Description |
|--------|------|-------------|
| `2ce5019` | 02-01 | EmbeddingClient behaviour with generate/1, generate_batch/1, dimensions/0 callbacks; OpenAIClient (Req, text-embedding-3-small, batch<=100) and StubClient (deterministic phash2-seeded vectors); config per environment |
| `cf76c4c` | 02-02 | EmbeddingWorker Oban job on :embeddings queue (max_attempts: 3, priority: 3); SHA-256 content hashing for deduplication; enqueue/1 chunks into batches of 50; enqueue_backfill/1 with 1hr uniqueness window |
| `8a5f204` | 02-03 | PersistenceListener GenServer subscribing to "pipeline:events" PubSub topic; ReconciliationWorker Oban cron (*/15, 1hr lookback); supervisor wiring |

### Phase 03: Search (Steps 03-01 through 03-03)

| Commit | Step | Description |
|--------|------|-------------|
| `acfd54a` | 03-01 | Full-text search with plainto_tsquery, ts_rank ranking, EXISTS-based authorization (public channel, private channel, DM), GIN index on to_tsvector, sender preloading |
| `9c868fa` | 03-02 | Semantic search with pgvector cosine similarity, query embedding generation, partition-pruned join on (message_id, message_inserted_at), similarity threshold 0.3, same EXISTS authorization |
| `078febd` | 03-03 | Hybrid search with RRF (k=60) merging FTS and semantic results via Task.async; Search context boundary with search_messages/3 dispatching to :text, :semantic, or :hybrid mode |

### Phase 04: UI and RAG Integration (Steps 04-01 through 04-03)

| Commit | Step | Description |
|--------|------|-------------|
| `728f5dc` | 04-01 | SearchComponent LiveView: query/results/mode/searching state, 300ms debounce, jump_to_message, :message_search feature flag guard on both template and context |
| `3478fa4` | 04-02 | RAGContext.retrieve/2: semantic search, format as "[timestamp] username: content" lines, truncate to max_tokens (default 4000, ~4 chars/token), no mid-line cuts |
| `3f74646` | 04-03 | Configuration and supervisor wiring: PersistenceListener after Oban, ReconciliationWorker cron, embedding_client per-env config, OPENAI_API_KEY in runtime.exs |

### Quality Passes

| Commit | Description |
|--------|-------------|
| `b0ad05a` | RPP L1-L4 refactoring applied to 5 production files and 8 test files |
| `72c2e05` | Adversarial review defects resolved across 5 files |

## Quality Metrics

### Test Coverage

- **Starting test count:** 850
- **New tests added:** 96
- **Final test count:** 946
- **Failures:** 0

### TDD Execution

All 12 steps followed 5-phase TDD cycles (PREPARE, RED_ACCEPTANCE, RED_UNIT, GREEN, COMMIT). Every phase across all steps reached PASS status. The execution log records 60 events across all steps. RED_UNIT was skipped (with justification) for 9 of 12 steps where acceptance tests already covered all behaviors through the driving port:

- **01-01, 01-02:** Migrations are pure infrastructure with no domain logic; acceptance tests verify via information_schema and pg_indexes.
- **01-03:** Schema is a pure data definition; acceptance tests cover changeset validation, field types, and roundtrip persistence.
- **02-02:** Content_hash, dedup, and filtering covered through driving port; crypto.hash helpers are trivial wrappers.
- **02-03:** Lookback query, batch chunking, and PubSub handling covered through driving ports.
- **03-01, 03-02:** All behaviors tested through driving port; no separate pure functions beneath the query module.
- **04-02:** All behaviors covered through driving port; internal helpers follow port-to-port testing principle.
- **04-03:** No new validation functions added; wiring was correct from prior steps.

Unit tests were executed for steps 02-01, 03-03, and 04-01 where distinct unit-level behaviors existed alongside acceptance tests.

### Refactoring (RPP L1-L4)

Applied Refactoring Priority Protocol to 5 production files and 8 test files (commit `b0ad05a`):
- **L1 (Critical):** Naming clarity, dead code removal
- **L2 (High):** Duplication elimination, function length reduction
- **L3 (Medium):** Module organization, documentation
- **L4 (Low):** Idiomatic patterns, consistency

Files refactored:
- `lib/slackex/embeddings/embedding_worker.ex`
- `lib/slackex/embeddings/openai_client.ex`
- `lib/slackex/embeddings/reconciliation_worker.ex`
- `lib/slackex/search/message_search.ex`
- `lib/slackex_web/live/chat_live/search_component.ex`
- `test/slackex/embeddings/configuration_wiring_test.exs`
- `test/slackex/embeddings/embedding_worker_test.exs`
- `test/slackex/embeddings/persistence_listener_test.exs`
- `test/slackex/embeddings/rag_context_test.exs`
- `test/slackex/embeddings/reconciliation_worker_test.exs`
- `test/slackex/search/message_search_test.exs`
- `test/slackex/search_test.exs`
- `test/support/data_case.ex`
- `test/support/embedding_helpers.ex`

### Adversarial Review

Reviewed by `nw-software-crafter-reviewer`. Defects found and addressed in commit `72c2e05`:

Files modified:
- `lib/slackex/embeddings/rag_context.ex`
- `test/slackex/embeddings/embedding_worker_test.exs`
- `test/slackex/embeddings/rag_context_test.exs`
- `test/slackex/embeddings/reconciliation_worker_test.exs`
- `test/slackex_web/live/chat_live/search_component_test.exs`
- `test/support/failing_client.ex`

### Roadmap Validation

Roadmap was validated by `nw-software-crafter-reviewer` in 1 iteration (approved at revision 1). Six defects addressed during validation:
- D1: Clarified PubSub boundary compliance in 02-03 description and added boundary criterion
- D2: Added 01-03 to 03-02 dependencies
- D3: Strengthened GIN index criterion with 100+ message seeding and EXPLAIN output verification
- D4: Added feature flag guard criteria for both UI and context module in 04-01
- D5: Clarified event payload is just message IDs; worker looks up channel_id/dm_conversation_id from DB
- D6: Added 300ms debounce criterion to 04-01

### Mutation Testing

Skipped -- no Elixir mutation testing framework available. Compensating controls: comprehensive acceptance test coverage across all 12 steps, EXISTS-based authorization tested for all three access paths (public channel, private channel, DM), content_hash deduplication tests, RRF score merging tests for single-source and multi-source results, feature flag guard tests at both UI and context levels, EmbeddingClient error propagation tests, ReconciliationWorker LEFT JOIN gap detection tests, RAG token budget truncation tests.

### DES Integrity

All 12 steps verified through DES (Design-Execute-Seal) integrity check. Execution log confirms every step reached PASS status across all TDD phases with timestamps spanning 18:54 to 20:02 UTC.

## Files Modified

### New Production Files

- `lib/slackex/embeddings/embeddings.ex` -- Embeddings boundary module declaration
- `lib/slackex/embeddings/message_embedding.ex` -- MessageEmbedding Ecto schema with vector(1536) field
- `lib/slackex/embeddings/embedding_client.ex` -- EmbeddingClient behaviour (generate/1, generate_batch/1, dimensions/0)
- `lib/slackex/embeddings/openai_client.ex` -- OpenAI text-embedding-3-small implementation via Req
- `lib/slackex/embeddings/stub_client.ex` -- Deterministic test client with phash2-seeded vectors
- `lib/slackex/embeddings/embedding_worker.ex` -- Oban worker for batch embedding generation
- `lib/slackex/embeddings/persistence_listener.ex` -- GenServer subscribing to pipeline:events PubSub topic
- `lib/slackex/embeddings/reconciliation_worker.ex` -- Oban cron job for self-healing missed embeddings
- `lib/slackex/embeddings/rag_context.ex` -- RAG-ready context formatter with token budget truncation
- `lib/slackex/search.ex` -- Search context boundary with search_messages/3 public API
- `lib/slackex/search/message_search.ex` -- FTS, semantic, and hybrid search implementations
- `lib/slackex/postgrex_types.ex` -- Postgrex custom types module for vector support
- `lib/slackex_web/live/chat_live/search_component.ex` -- Search LiveView component with feature flag guard
- `priv/repo/migrations/20260303185500_enable_pgvector.exs` -- Enable pgvector extension
- `priv/repo/migrations/20260303185600_create_message_embeddings.exs` -- Create message_embeddings table with HNSW index
- `priv/repo/migrations/20260303191200_add_fts_gin_index.exs` -- Add GIN index on to_tsvector for messages

### New Test Files

- `test/slackex/infrastructure/pgvector_extension_test.exs` -- pgvector extension verification
- `test/slackex/infrastructure/message_embeddings_table_test.exs` -- Table schema and index verification
- `test/slackex/embeddings/message_embedding_test.exs` -- Schema roundtrip and changeset tests
- `test/slackex/embeddings/embedding_client_test.exs` -- Behaviour contract tests
- `test/slackex/embeddings/openai_client_test.exs` -- OpenAI client tests
- `test/slackex/embeddings/stub_client_test.exs` -- StubClient determinism and dimension tests
- `test/slackex/embeddings/embedding_worker_test.exs` -- Worker batch processing, dedup, and error tests
- `test/slackex/embeddings/persistence_listener_test.exs` -- PubSub subscription and enqueue tests
- `test/slackex/embeddings/reconciliation_worker_test.exs` -- Cron gap detection and batch enqueue tests
- `test/slackex/embeddings/rag_context_test.exs` -- Context formatting and token budget tests
- `test/slackex/embeddings/configuration_wiring_test.exs` -- Supervisor and config verification
- `test/slackex/search/message_search_test.exs` -- FTS, semantic, hybrid search with authorization tests
- `test/slackex/search_test.exs` -- Search context boundary dispatch and feature flag tests
- `test/slackex_web/live/chat_live/search_component_test.exs` -- LiveView component interaction tests
- `test/support/embedding_helpers.ex` -- Shared test helpers for embedding setup
- `test/support/failing_client.ex` -- EmbeddingClient implementation that returns errors for adversarial tests

### Modified Files

- `mix.exs` -- Added pgvector and req dependencies
- `lib/slackex/application.ex` -- Added PersistenceListener to supervision tree after Oban
- `lib/slackex/repo.ex` -- Configured custom Postgrex types module
- `lib/slackex/read_repo.ex` -- Configured custom Postgrex types module
- `lib/slackex/chat/message.ex` -- Added search_content field for FTS indexing
- `lib/slackex_web/live/chat_live/index.ex` -- Integrated SearchComponent with feature flag conditional
- `config/config.exs` -- Oban :embeddings queue, ReconciliationWorker cron, embedding_client config
- `config/dev.exs` -- StubClient for development
- `config/test.exs` -- StubClient for tests
- `config/runtime.exs` -- OpenAIClient with OPENAI_API_KEY for production
- `test/support/data_case.ex` -- Added embedding cleanup helpers

## Commit History (oldest to newest)

| Commit | Message |
|--------|---------|
| `767a515` | feat(search): add deploy-safe migration enabling pgvector extension |
| `310d982` | feat(search): add message_embeddings table with HNSW index |
| `159f3b9` | feat(search): add MessageEmbedding schema and Postgrex vector type registration |
| `acfd54a` | feat(search): add full-text search with authorization enforcement |
| `2ce5019` | feat(embeddings): add EmbeddingClient behaviour with OpenAI and Stub implementations |
| `cf76c4c` | feat(embeddings): add EmbeddingWorker Oban job for batch embedding generation |
| `9c868fa` | feat(search): add semantic search with pgvector cosine similarity |
| `8a5f204` | feat(embeddings): add PersistenceListener and ReconciliationWorker |
| `078febd` | feat(search): add hybrid search with RRF and Search context boundary |
| `3478fa4` | feat(embeddings): add RAGContext.retrieve/2 for LLM-ready context formatting |
| `728f5dc` | feat(search): add SearchComponent LiveView with feature flag guard |
| `3f74646` | test(embeddings): verify configuration and supervisor wiring end-to-end |
| `b0ad05a` | refactor(search): apply RPP L1-L4 on Phase 4 Intelligence & Search code |
| `72c2e05` | fix(test): resolve adversarial review defects in Phase 4 Intelligence & Search |

## Lessons Learned

1. **EXISTS subqueries prevent row duplication in authorization-scoped ranked search.** JOINing messages with channel_members for authorization creates a many-to-one relationship that duplicates message rows in results, breaking rank ordering. EXISTS evaluates to a single boolean per message row regardless of how many membership paths exist. This pattern is essential whenever authorization filtering is combined with ranked or scored results (FTS rank, cosine similarity, RRF scores). The tradeoff is that EXISTS cannot be used to extract data from the joined table -- but for authorization checks, only a boolean is needed.

2. **Reciprocal Rank Fusion elegantly sidesteps the score normalization problem.** FTS `ts_rank` produces values in a small floating-point range that varies with document length and term frequency, while cosine similarity produces values between -1 and 1. Combining these scores requires arbitrary normalization or weighting that is difficult to tune. RRF ignores absolute scores entirely, operating on rank positions: `1/(k + rank)`. This makes it robust across any combination of scoring functions. The k=60 constant dampens the contribution of lower-ranked results without eliminating them. In practice, this means a message ranked #1 by FTS and #10 by semantic search scores higher than a message ranked #5 by both -- which matches user intuition about relevance.

3. **Event-driven pipelines need a reconciliation safety net.** PubSub-based event propagation (BatchWriter -> PersistenceListener -> EmbeddingWorker) handles the happy path efficiently but is inherently best-effort: if the listener is restarting, the node is partitioned, or the Oban queue is full, events are silently lost. The ReconciliationWorker cron job (15-minute interval, 1-hour lookback) provides a self-healing mechanism by scanning for messages without embeddings. The lookback window must be wider than the cron interval to avoid gaps. This dual-path pattern (real-time events + periodic reconciliation) is applicable to any eventually-consistent pipeline where completeness matters more than immediate consistency.

4. **Content hashing prevents redundant embedding regeneration.** The SHA-256 content_hash stored alongside each embedding allows the EmbeddingWorker to skip messages whose content hasn't changed since the last embedding was generated. This is important for edited messages: when a message is updated, the pipeline re-enqueues it, but if the content hash matches, the expensive API call to generate a new embedding is skipped. Without this check, every message edit would trigger an embedding API call even if the edit was cosmetic (e.g., fixing a typo that doesn't affect semantic meaning). The hash comparison is a cheap local operation that saves significant API cost at scale.

5. **Feature flags must guard both UI and API paths.** Guarding only the LiveView template hides the search UI but leaves `search_messages/3` callable by any code path (other LiveViews, API endpoints, IEx sessions). Adding a flag check at the context module level ensures the feature is truly disabled regardless of entry point. This dual-guard pattern is enforced by the project's feature flag discipline and was explicitly validated during roadmap review (defect D4). The cost is two flag checks per request instead of one, but FunWithFlags caches flag state in ETS, making the overhead negligible.
