# Phase 4 Intelligence & Search -- Technology Research

**Date:** 2026-03-03
**Researcher:** Nova (nw-researcher)
**Spec Reference:** `specs/04-phase-4-intelligence.md`
**Research Depth:** Detailed
**Source Count:** 40+ sources across 10 topic areas

---

## Table of Contents

1. [pgvector in PostgreSQL](#1-pgvector-in-postgresql)
2. [OpenAI text-embedding-3-small](#2-openai-text-embedding-3-small)
3. [Hybrid Search with Reciprocal Rank Fusion](#3-hybrid-search-with-reciprocal-rank-fusion)
4. [PostgreSQL Full-Text Search](#4-postgresql-full-text-search)
5. [Embedding Pipeline Architecture](#5-embedding-pipeline-architecture)
6. [Oban Worker Patterns for Embedding Pipelines](#6-oban-worker-patterns-for-embedding-pipelines)
7. [RAG Context Retrieval](#7-rag-context-retrieval)
8. [pgvector + Ecto Integration in Elixir](#8-pgvector--ecto-integration-in-elixir)
9. [Authorization in Search](#9-authorization-in-search)
10. [Partitioned Tables + pgvector](#10-partitioned-tables--pgvector)
11. [Risk Register](#11-risk-register)
12. [Knowledge Gaps](#12-knowledge-gaps)

---

## 1. pgvector in PostgreSQL

### 1.1 Core Capabilities

pgvector is the open-source PostgreSQL extension for vector similarity search. It supports vectors up to 2,000 dimensions for the standard `vector` type, making `vector(1536)` (as specified in Phase 4) well within limits. [GitHub: pgvector/pgvector](https://github.com/pgvector/pgvector), [Crunchy Data: HNSW Indexes](https://www.crunchydata.com/blog/hnsw-indexes-with-postgres-and-pgvector), [pgvector DeepWiki: HNSW Configuration](https://deepwiki.com/pgvector/pgvector/5.1.4-hnsw-configuration-parameters)

**Supported distance operators:**

| Operator | Function | Index Ops Class |
|----------|----------|-----------------|
| `<->` | L2 (Euclidean) distance | `vector_l2_ops` |
| `<=>` | Cosine distance | `vector_cosine_ops` |
| `<#>` | Negative inner product | `vector_ip_ops` |
| `<+>` | L1 distance | `vector_l1_ops` |

The spec uses `<=>` (cosine distance) which is the correct operator for semantic similarity with normalized embeddings. Cosine similarity can be derived as `1 - (embedding <=> query_vector)`. [GitHub: pgvector/pgvector](https://github.com/pgvector/pgvector)

### 1.2 HNSW Index Parameters

The spec defines: `CREATE INDEX idx_embeddings_hnsw ON message_embeddings USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64)`.

**Parameter analysis:**

| Parameter | Spec Value | Default | Valid Range | Role |
|-----------|-----------|---------|-------------|------|
| `m` | 16 | 16 | 2-100 | Max bidirectional connections per node per layer |
| `ef_construction` | 64 | 64 | -- | Candidate list size during index build |
| `ef_search` | (runtime) | 40 | -- | Candidate list size during query |

The spec uses pgvector's default values (m=16, ef_construction=64). The original HNSW research paper recommends m values in the range 5-48, with 16 as a strong default. These defaults are explicitly recommended by multiple authoritative sources as the correct starting point. [GitHub: pgvector/pgvector](https://github.com/pgvector/pgvector), [Crunchy Data: HNSW Indexes](https://www.crunchydata.com/blog/hnsw-indexes-with-postgres-and-pgvector), [pgvector DeepWiki: HNSW Configuration](https://deepwiki.com/pgvector/pgvector/5.1.4-hnsw-configuration-parameters)

**Confidence: HIGH** -- The spec's parameter choices align with defaults and community recommendations.

### 1.3 Performance Characteristics

**Query performance (from benchmarks):**

- HNSW achieves recall@10 of 0.98 at ~5ms latency with 1M vectors. [Jonathan Katz: pgvector HNSW Performance](https://jkatz05.com/post/postgres/pgvector-hnsw-performance/)
- HNSW provides ~30x QPS improvement and ~30x p99 latency improvement over IVFFlat at 99% recall. [Jonathan Katz: pgvector 150x Speedup](https://jkatz05.com/post/postgres/pgvector-performance-150x-speedup/)
- A properly tuned pgvector instance on r7g.2xlarge (64 GB RAM) handles 5-10 million 1536-dimensional vectors with sub-20ms p99 latency. [Medium: Optimizing Vector Search at Scale](https://medium.com/@dikhyantkrishnadalai/optimizing-vector-search-at-scale-lessons-from-pgvector-supabase-performance-tuning-ce4ada4ba2ed)

**Tuning sweet spot for m parameter with 1536-dim vectors:**

- m=8: fast but recall too low for RAG workloads
- m=16: good balance (spec value) -- recommended starting point
- m=32: excellent recall but halves throughput
- Best practice: m=16 with ef_search tuned between 100-200

[Medium: Optimizing Vector Search at Scale](https://medium.com/@dikhyantkrishnadalai/optimizing-vector-search-at-scale-lessons-from-pgvector-supabase-performance-tuning-ce4ada4ba2ed), [Crunchy Data: HNSW Indexes](https://www.crunchydata.com/blog/hnsw-indexes-with-postgres-and-pgvector)

**Index build considerations:**

- Index builds are significantly faster when the graph fits into `maintenance_work_mem`. When it exceeds this limit, build switches from in-memory to on-disk, which is substantially slower. [Crunchy Data: HNSW Indexes](https://www.crunchydata.com/blog/hnsw-indexes-with-postgres-and-pgvector), [GitHub: pgvector/pgvector](https://github.com/pgvector/pgvector)
- For 1M rows of 1536-dim embeddings, the index can be 8GB or larger. The entire index should fit in memory for optimal query performance. [Crunchy Data: HNSW Indexes](https://www.crunchydata.com/blog/hnsw-indexes-with-postgres-and-pgvector)
- Build initial data first, then create the index. Use parallel workers via `max_parallel_maintenance_workers`. [GitHub: pgvector/pgvector](https://github.com/pgvector/pgvector)

**pgvector 0.8.0 improvements (relevant to the spec's filtered search with authorization):**

- Iterative index scans prevent "overfiltering" -- when WHERE clauses filter out most candidates, pre-0.8.0 would return fewer results than requested. Iterative scan continues traversing the HNSW graph until enough filtered results are found. [PostgreSQL: pgvector 0.8.0 Released](https://www.postgresql.org/about/news/pgvector-080-released-2952/), [AWS: pgvector 0.8.0 on Aurora](https://aws.amazon.com/blogs/database/supercharging-vector-search-performance-and-relevance-with-pgvector-0-8-0-on-amazon-aurora-postgresql/), [Clarvo: Optimizing Filtered Vector Queries](https://www.clarvo.ai/blog/optimizing-filtered-vector-queries-from-tens-of-seconds-to-single-digit-milliseconds-in-postgresql)
- 9.4x latency reduction for filtered queries (123.3ms to 13.1ms in benchmarks). [Clarvo: Optimizing Filtered Vector Queries](https://www.clarvo.ai/blog/optimizing-filtered-vector-queries-from-tens-of-seconds-to-single-digit-milliseconds-in-postgresql)
- Two modes: `relaxed_order` (faster, allows slight reordering) and `strict_order` (exact ordering, higher cost).
- Enable with: `SET hnsw.iterative_scan = on;`

**Recommendation for the spec:** The authorization EXISTS subqueries in semantic_search will act as filters on vector results. Ensure the deployment uses pgvector >= 0.8.0 and enable `hnsw.iterative_scan` to prevent authorization filtering from causing result set shortfalls. This is critical for the Phase 4 design.

### 1.4 Practical Recommendations for This Implementation

1. **Use defaults (m=16, ef_construction=64)** as the spec already specifies -- they are correct for a messaging app's scale.
2. **Set `hnsw.ef_search` to 100-200** at the session level for search queries to improve recall beyond the default 40.
3. **Increase `maintenance_work_mem`** before running the backfill HNSW index build (e.g., `SET maintenance_work_mem = '2GB'` in the migration).
4. **Build index after initial data load** -- the spec's backfill pattern supports this.
5. **Enable `hnsw.iterative_scan`** in PostgreSQL config or per-session for authorization-filtered queries.
6. **Require pgvector >= 0.8.0** to benefit from iterative scan for filtered searches.

**Confidence: HIGH**

---

## 2. OpenAI text-embedding-3-small

### 2.1 Model Specifications

| Property | Value | Source |
|----------|-------|--------|
| Dimensions | 1536 (default) | [Pinecone: OpenAI Embeddings v3](https://www.pinecone.io/learn/openai-embeddings-v3/), [OpenAI: New Embedding Models](https://openai.com/index/new-embedding-models-and-api-updates/) |
| Max input tokens | 8,191 | [Pinecone: OpenAI Embeddings v3](https://www.pinecone.io/learn/openai-embeddings-v3/), [OpenAI Platform](https://platform.openai.com/docs/models/text-embedding-3-small) |
| MTEB score | 62.3% | [Pinecone: OpenAI Embeddings v3](https://www.pinecone.io/learn/openai-embeddings-v3/), [OpenAI: New Embedding Models](https://openai.com/index/new-embedding-models-and-api-updates/) |
| MIRACL score | 44.0% | [Pinecone: OpenAI Embeddings v3](https://www.pinecone.io/learn/openai-embeddings-v3/), [OpenAI: New Embedding Models](https://openai.com/index/new-embedding-models-and-api-updates/) |
| Pricing | $0.02/1M tokens | [Helicone: OpenAI Pricing](https://www.helicone.ai/llm-cost/provider/openai/model/text-embedding-3-small), [OpenAI Pricing](https://platform.openai.com/docs/pricing) |
| Batch API pricing | $0.01/1M tokens (50% discount) | [Helicone: OpenAI Pricing](https://www.helicone.ai/llm-cost/provider/openai/model/text-embedding-3-small) |
| Matryoshka dimensions | Reducible to 512 | [Pinecone: OpenAI Embeddings v3](https://www.pinecone.io/learn/openai-embeddings-v3/) |

**Confidence: HIGH** -- Specifications verified across 3+ independent sources.

### 2.2 Comparison with Alternatives

| Model | Dimensions | MTEB | MIRACL | Price/1M tokens | Best For |
|-------|-----------|------|--------|-----------------|----------|
| text-embedding-3-small | 1536 | 62.3% | 44.0% | $0.02 | Cost-effective, general purpose |
| text-embedding-3-large | 3072 | 64.6% | 54.9% | $0.13 | Higher accuracy needs |
| text-embedding-ada-002 | 1536 | 61.0% | 31.4% | $0.10 | Legacy (superseded) |

[OpenAI: New Embedding Models](https://openai.com/index/new-embedding-models-and-api-updates/), [Pinecone: OpenAI Embeddings v3](https://www.pinecone.io/learn/openai-embeddings-v3/), [PingCAP: Analyzing Performance Gains](https://www.pingcap.com/article/analyzing-performance-gains-in-openais-text-embedding-3-small/)

Key findings:
- text-embedding-3-small is 5x cheaper than ada-002 with better performance. [OpenAI: New Embedding Models](https://openai.com/index/new-embedding-models-and-api-updates/)
- The large model's 256-dimension truncated output outperforms ada-002's full 1536-dim output -- a 6x reduction in storage. [Pinecone: OpenAI Embeddings v3](https://www.pinecone.io/learn/openai-embeddings-v3/)
- Both v3 models use Matryoshka Representation Learning (MRL), enabling dimension reduction with minimal accuracy loss. [Pinecone: OpenAI Embeddings v3](https://www.pinecone.io/learn/openai-embeddings-v3/)

**Assessment of spec's model choice:** text-embedding-3-small at 1536 dimensions is the correct choice for a messaging app. The cost-performance tradeoff is optimal. Chat messages are typically short (under 500 tokens), well within the 8,191 token limit. The 44% MIRACL improvement over ada-002 is particularly valuable for multilingual message search.

### 2.3 Batch API and Rate Limits

- **Batch size:** The spec specifies max 100 texts per API call. The API supports up to approximately 300K total tokens per request (~36 inputs of 8K each). For typical chat messages (50-200 tokens), 100 messages per batch is well within limits. [OpenAI Community: Max Total Embeddings Tokens](https://community.openai.com/t/max-total-embeddings-tokens-per-request/1254699)
- **Rate limits (Tier 5):** ~10M TPM, ~10K RPM for embedding models. Lower tiers have proportionally lower limits. [OpenAI: Rate Limits](https://platform.openai.com/docs/guides/rate-limits), [Muneebdev: OpenAI Rate Limits Guide](https://muneebdev.com/openai-api-rate-limits-guide/)
- **Batch API:** Available for non-time-sensitive requests at 50% cost reduction. Jobs complete within 24 hours. Useful for backfill operations. [Helicone: OpenAI Pricing](https://www.helicone.ai/llm-cost/provider/openai/model/text-embedding-3-small)

### 2.4 Cost Estimation for This Application

For a messaging app with moderate traffic:
- Average message length: ~50 tokens
- 10,000 messages/day = 500,000 tokens/day
- Daily embedding cost: $0.01 (standard) or $0.005 (batch)
- Monthly cost: ~$0.30 (standard) or ~$0.15 (batch)
- Backfill of 1M historical messages: ~$1.00 (batch)

*Interpretation: These costs are negligible. The spec's 100-message batch size and 1-second pauses for backfill rate limiting are conservative and appropriate.*

### 2.5 Practical Recommendations

1. **The spec's model choice is optimal.** No change needed.
2. **Consider the Batch API for the `enqueue_backfill` job** to halve embedding costs during historical backfill.
3. **Monitor token usage** -- chat messages are short, so RPM limits are more likely to be hit than TPM limits.
4. **Future option:** If higher accuracy is needed, the Matryoshka feature allows testing text-embedding-3-large at 1536 dimensions (same storage, better accuracy) as a drop-in upgrade.

**Confidence: HIGH**

---

## 3. Hybrid Search with Reciprocal Rank Fusion

### 3.1 RRF Origin and Algorithm

RRF was introduced by Cormack, Clarke, and Buttcher at SIGIR 2009. The paper demonstrated that RRF "consistently yields better results than any individual system, and better results than the standard method Condorcet Fuse." [Cormack et al., SIGIR 2009](https://dl.acm.org/doi/10.1145/1571941.1572114), [Research Paper PDF](https://cormack.uwaterloo.ca/cormacksigir09-rrf.pdf), [Google Research](https://research.google/pubs/reciprocal-rank-fusion-outperforms-condorcet-and-individual-rank-learning-methods/)

The formula used in the spec:
```
score(doc) = 1/(k + rank_text) + 1/(k + rank_semantic)  where k = 60
```

This is the canonical RRF formula from the original paper.

### 3.2 The k Parameter

The spec uses k=60, which is the value from the original paper and the industry-standard default.

**Why k=60 works:**

| Rank Position | Score Contribution (k=60) |
|--------------|--------------------------|
| Rank 1 | 1/61 = 0.0164 |
| Rank 10 | 1/70 = 0.0143 |
| Rank 50 | 1/110 = 0.0091 |
| Rank 100 | 1/160 = 0.0063 |

- Values below 10 make top-ranked items dominate too heavily; a single strong ranking overrides everything else.
- Values above 100 flatten the curve too much, losing discriminative power.
- k=60 balances these extremes.

[Microsoft Learn: Hybrid Search Scoring RRF](https://learn.microsoft.com/en-us/azure/search/hybrid-search-ranking), [Elasticsearch: Reciprocal Rank Fusion](https://www.elastic.co/docs/reference/elasticsearch/rest-apis/reciprocal-rank-fusion), [OpenSearch: Introducing RRF](https://opensearch.org/blog/introducing-reciprocal-rank-fusion-hybrid-search/)

**Robustness:** RRF's performance is "not critically sensitive to the choice of k, making it a robust and reliable method." This means the spec's choice of k=60 does not need empirical tuning for this application. [OpenSearch: Introducing RRF](https://opensearch.org/blog/introducing-reciprocal-rank-fusion-hybrid-search/)

**Confidence: HIGH** -- k=60 is universally recommended and empirically validated.

### 3.3 Alternatives to RRF

| Method | Description | Tradeoff |
|--------|-------------|----------|
| **RRF (k=60)** | Rank-based fusion, no score normalization needed | Simple, robust, no training required |
| **Convex Combination** | `score = alpha * norm_text + (1-alpha) * norm_semantic` | Requires score normalization; alpha needs tuning |
| **CombMNZ** | Multiplies combined score by number of lists containing the doc | Favors documents appearing in multiple lists |
| **Learned Fusion** | ML model trained on relevance judgments | Best accuracy but requires training data |
| **Weighted RRF** | Azure AI Search extension: multiply RRF score by weight per query | More control but more parameters to tune |

[Microsoft Learn: Hybrid Search Scoring RRF](https://learn.microsoft.com/en-us/azure/search/hybrid-search-ranking), [Cormack et al., SIGIR 2009](https://dl.acm.org/doi/10.1145/1571941.1572114), [Assembled: Better RAG Results with RRF](https://www.assembled.com/blog/better-rag-results-with-reciprocal-rank-fusion-and-hybrid-search)

**Assessment of spec's choice:** RRF is the correct choice for this application. It requires no score normalization (FTS and vector scores have incompatible ranges), no training data, and no parameter tuning beyond k. For a messaging app where search quality is important but not mission-critical, RRF's simplicity and robustness are ideal.

### 3.4 When Hybrid Outperforms Single-Mode

Hybrid search consistently outperforms single-mode search in several scenarios:
- **Vocabulary mismatch:** User searches for "deploy" but messages say "ship" or "release" -- semantic search finds these, FTS misses them.
- **Exact terminology:** User searches for an error code "ECONNREFUSED" -- FTS finds exact matches, semantic search may miss.
- **Mixed intent:** "How do we handle authentication?" -- FTS matches "authentication", semantic search finds related discussions about "login", "OAuth", "SSO".

[Assembled: Better RAG Results with RRF](https://www.assembled.com/blog/better-rag-results-with-reciprocal-rank-fusion-and-hybrid-search), [Microsoft Learn: Hybrid Search Scoring RRF](https://learn.microsoft.com/en-us/azure/search/hybrid-search-ranking)

### 3.5 Practical Recommendations

1. **k=60 is correct.** No change needed.
2. **Run both searches in parallel** via `Task.async` as the spec describes -- this minimizes latency.
3. **Consider adding weighted RRF later** if user feedback indicates one mode should be prioritized (e.g., `1.5/(k + rank_text) + 1.0/(k + rank_semantic)` to weight FTS higher).
4. **Log search mode and result counts** to understand real-world usage patterns.

**Confidence: HIGH**

---

## 4. PostgreSQL Full-Text Search

### 4.1 plainto_tsquery vs websearch_to_tsquery

The spec uses `plainto_tsquery('english', query)`. This is the simpler option.

| Feature | `plainto_tsquery` | `websearch_to_tsquery` |
|---------|-------------------|------------------------|
| Word combination | AND between all words | AND between words (default) |
| OR support | No | Yes (`OR` keyword) |
| NOT support | No | Yes (`-` prefix) |
| Phrase support | No | Yes (`"quoted phrase"`) |
| Error on bad input | No | No (never raises) |
| User input safe | Yes | Yes |

[PostgreSQL Docs: Controlling Text Search](https://www.postgresql.org/docs/current/textsearch-controls.html), [Peter Ullrich: Full-text Search with Postgres and Ecto](https://peterullrich.com/complete-guide-to-full-text-search-with-postgres-and-ecto), [pgPedia: websearch_to_tsquery](https://pgpedia.info/w/websearch_to_tsquery.html)

**Recommendation:** Consider upgrading to `websearch_to_tsquery` for the search UI. It gives users web-search-like syntax (OR, NOT with `-`, phrase matching with quotes) with zero risk of syntax errors. Both functions are safe for untrusted user input. This is a minor enhancement that improves search expressiveness at no cost. [PostgreSQL Docs: Controlling Text Search](https://www.postgresql.org/docs/current/textsearch-controls.html), [pgPedia: websearch_to_tsquery](https://pgpedia.info/w/websearch_to_tsquery.html), [Peter Ullrich: Full-text Search with Postgres and Ecto](https://peterullrich.com/complete-guide-to-full-text-search-with-postgres-and-ecto)

### 4.2 ts_rank vs ts_rank_cd

The spec uses `ts_rank`. This is the standard choice.

| Function | Basis | Positional Data Required | Use Case |
|----------|-------|--------------------------|----------|
| `ts_rank` | Term frequency | No | General ranking |
| `ts_rank_cd` | Cover density (proximity) | Yes | When term proximity matters |

- `ts_rank_cd` penalizes when matching terms are far apart; `ts_rank` focuses on frequency regardless of proximity. [PostgreSQL Docs: Controlling Text Search](https://www.postgresql.org/docs/current/textsearch-controls.html)
- `ts_rank_cd` returns zero if positional information is stripped from the tsvector. [PostgreSQL Docs: Controlling Text Search](https://www.postgresql.org/docs/current/textsearch-controls.html)
- Both accept normalization flags (divide by document length, log of document length, etc.). [PostgreSQL Docs: Controlling Text Search](https://www.postgresql.org/docs/current/textsearch-controls.html)

**Assessment:** `ts_rank` is correct for chat messages. Messages are short (typically one paragraph), so term proximity within a single message is less meaningful. `ts_rank_cd` would add value if searching longer documents.

**Performance warning:** Ranking is I/O intensive -- it must retrieve the tsvector for every matching document. This "is almost impossible to avoid since practical queries often result in large numbers of matches." The spec's `limit` (default 20) with `offset` pagination mitigates this, but ranking still scans all matches before limiting. [PostgreSQL Docs: Controlling Text Search](https://www.postgresql.org/docs/current/textsearch-controls.html)

### 4.3 GIN Index Considerations

- GIN indexes are the preferred index type for full-text search. They contain an inverted index of lexemes with compressed position lists. [PostgreSQL Docs: Text Search Indexes](https://www.postgresql.org/docs/current/textsearch-indexes.html)
- A GIN index reduces FTS query time from ~200ms to ~4ms on large datasets. [OneUptime: Full-Text Search GIN PostgreSQL](https://oneuptime.com/blog/post/2026-01-25-full-text-search-gin-postgresql/view)
- **On partitioned tables:** GIN indexes must be created on each partition individually (PostgreSQL creates local indexes automatically when you define an index on the partitioned parent). The index is local to each partition. [PostgreSQL Docs: Table Partitioning](https://www.postgresql.org/docs/current/ddl-partitioning.html)

**Risk:** The spec does not explicitly mention creating a GIN index on `messages.content` for FTS. Without a GIN index, `to_tsvector('english', content) @@ plainto_tsquery(...)` will do a sequential scan on every partition. A GIN index should be added:

```sql
CREATE INDEX idx_messages_content_fts ON messages
  USING gin (to_tsvector('english', content));
```

This will automatically create local GIN indexes on each partition.

**Confidence: HIGH** -- All recommendations verified against PostgreSQL official documentation.

### 4.4 Practical Recommendations

1. **Upgrade to `websearch_to_tsquery`** for richer user-facing search syntax.
2. **Add a GIN index on `to_tsvector('english', content)`** to the messages table if not already present.
3. **Use `ts_rank` (not `ts_rank_cd`)** as the spec specifies -- correct for short messages.
4. **Consider normalization option 32** (scale to 0-1 range) if RRF needs comparable score magnitudes, though RRF is rank-based and does not use raw scores.

---

## 5. Embedding Pipeline Architecture

### 5.1 Event-Driven Pattern Assessment

The spec's architecture: `BatchWriter -> PubSub broadcast -> PersistenceListener (GenServer) -> Oban EmbeddingWorker`

This is a well-established event-driven pattern with clear separation of concerns:

- **Producer:** BatchWriter broadcasts `{:messages_persisted, message_ids}` -- fire-and-forget, no coupling to embedding concern.
- **Consumer:** PersistenceListener subscribes to PubSub, enqueues Oban jobs -- translates events into durable work items.
- **Worker:** EmbeddingWorker processes jobs -- handles API calls, retries, deduplication.

The spec explicitly documents the key weakness: PubSub is ephemeral. If PersistenceListener is down during a broadcast, those message IDs are silently missed. [Google Cloud: Event-driven Architecture with Pub/Sub](https://docs.google.com/solutions/event-driven-architecture-pubsub), [Google Cloud: Handling Duplicate Data in Streaming Pipeline](https://cloud.google.com/blog/products/data-analytics/handling-duplicate-data-in-streaming-pipeline-using-pubsub-dataflow)

### 5.2 Reconciliation / Self-Healing Pattern

The spec's ReconciliationWorker (cron every 15 minutes, 1-hour lookback) is a standard "sweep" pattern for eventual consistency:

```
Missed messages → ReconciliationWorker → LEFT JOIN to find gaps → Enqueue EmbeddingWorker jobs
```

This pattern is widely used in production systems:
- **Google Cloud Dataflow:** Uses backfill mechanisms when subscriptions fall behind. Landfill data stored for recovery. [Google Cloud: Handling Duplicate Data](https://cloud.google.com/blog/products/data-analytics/handling-duplicate-data-in-streaming-pipeline-using-pubsub-dataflow)
- **Mozilla data pipeline:** Reconciliation processes watch for duplicate submissions and fill gaps. [Mozilla: GCP Data Pipeline Overview](https://mozilla.github.io/data-docs/concepts/pipeline/gcp_data_pipeline.html), [Mozilla: GCP Ingestion Architecture](https://mozilla.github.io/gcp-ingestion/architecture/overview/)

**Assessment of the 1-hour lookback window:** The spec acknowledges this is a deliberate bound for query performance. The tradeoff is:

| Lookback Window | Query Cost | Gap Risk |
|----------------|-----------|----------|
| 15 minutes | Lowest | Misses during extended outages (>15min) |
| 1 hour (spec) | Moderate | Covers typical restarts and short outages |
| 24 hours | Higher | Covers most scenarios but scans more rows |

The 1-hour window is a reasonable default. The spec mitigates extended outages with the manual `enqueue_backfill(channel_id)` job.

### 5.3 Deduplication via Content Hashing

The spec uses SHA-256 of message content in `content_hash` with `on_conflict: :nothing` for insert deduplication. This is a standard approach:

- **Content-based dedup:** Prevents re-embedding identical content (e.g., after message edit reverts to original text).
- **`on_conflict: :nothing`:** PostgreSQL upsert that silently skips duplicate inserts -- idempotent by design.
- **SHA-256:** Collision-resistant, fast, widely used for content addressing.

[Google Cloud: Handling Duplicate Data](https://cloud.google.com/blog/products/data-analytics/handling-duplicate-data-in-streaming-pipeline-using-pubsub-dataflow), [DoiT Engineering: Deduplication with Pub/Sub](https://engineering.doit.com/deduplication-delayed-messaging-and-fifo-with-pub-sub-b4b4373820a9)

**Note:** The spec does not define behavior for message edits. If a message is edited, the content changes but the embedding remains stale. Consider: should edits trigger re-embedding? If so, the worker should compare `content_hash` and update if changed. This is not a gap in the spec per se (it may be intentionally deferred), but it is a design decision to make explicit.

### 5.4 Practical Recommendations

1. **The event bridge pattern is correct** and well-suited for Elixir's PubSub.
2. **Add monitoring** for the coverage ratio metric the spec mentions (`unembedded_count / total_messages_last_24h`). Alert below 95%.
3. **Consider message edit handling** -- either re-embed on edit or document the decision to skip.
4. **The 1-hour lookback is appropriate** for a messaging app. Extended outages should trigger manual backfill.

**Confidence: HIGH**

---

## 6. Oban Worker Patterns for Embedding Pipelines

### 6.1 Queue Configuration

The spec uses: `queue: :embeddings, max_attempts: 3, priority: 3`

Oban queue configuration reference:

| Setting | Spec Value | Default | Assessment |
|---------|-----------|---------|------------|
| Queue name | `:embeddings` | `:default` | Correct -- dedicated queue isolates embedding work |
| max_attempts | 3 | 20 | Appropriate -- external API failures should not retry 20 times |
| priority | 3 | 0 | Lower priority than default -- embedding is background work |

[Oban.Worker Docs](https://hexdocs.pm/oban/Oban.Worker.html), [Oban GitHub](https://github.com/oban-bg/oban), [DockYard: Parallel Request Processing with Oban](https://dockyard.com/blog/2024/03/26/parallel-request-processing-with-elixir-and-oban)

Queue concurrency should be configured in `config.exs`:
```elixir
config :slackex, Oban,
  queues: [default: 10, embeddings: 5]
```

Setting `:embeddings` concurrency to 5 limits parallel OpenAI API calls to 5, providing natural rate limiting. [Oban Docs](https://hexdocs.pm/oban/Oban.html), [Milmazz: Oban Job Processing](https://milmazz.uno/article/2022/02/11/oban-job-processing-package-for-elixir/)

### 6.2 Rate Limiting External API Calls

**Open-source Oban:** Rate limiting is not built into the open-source version. Options:

1. **Queue concurrency as rate limit:** Set `embeddings: 2` to limit concurrent API calls. This is crude but effective for the spec's use case. [Elixir Forum: Rate Limiting with Oban](https://elixirforum.com/t/how-to-rate-limit-with-oban/64201), [Elixir Forum: Rate Limit Requests to External API](https://elixirforum.com/t/how-to-properly-limit-my-own-rate-requests-to-external-api/58864)
2. **In-worker rate limiting:** Add `Process.sleep(1000)` between batches (the spec already does this for backfill with "1-second pauses"). [Elixir Forum: Rate Limiting with Oban](https://elixirforum.com/t/how-to-rate-limit-with-oban/64201)
3. **Snooze on rate limit response:** Return `{:snooze, 60}` from `perform/1` when the API returns 429 Too Many Requests. This requeues the job for later without counting as a failure. [Oban.Worker Docs](https://hexdocs.pm/oban/Oban.Worker.html)

**Oban Pro (if available):** Provides true rate limiting with `rate_limit: [allowed: 30, period: {1, :minute}]` at the queue level, with global coordination across cluster nodes. [Oban Pro](https://oban.pro/), [Oban Pro: Smart Engine](https://oban.pro/docs/pro/1.4.3/Oban.Pro.Engines.Smart.html)

### 6.3 Uniqueness Constraints

The spec mentions uniqueness constraints for the ReconciliationWorker's `enqueue_backfill(channel_id)` (1-hour uniqueness period).

```elixir
use Oban.Worker,
  queue: :embeddings,
  unique: [period: 3600, fields: [:worker, :args], keys: [:channel_id]]
```

This prevents duplicate backfill jobs for the same channel within an hour. The `keys` option scopes uniqueness to the `channel_id` argument, allowing different channels to backfill simultaneously. [Oban.Worker Docs](https://hexdocs.pm/oban/Oban.Worker.html), [Milmazz: Oban Job Processing](https://milmazz.uno/article/2022/02/11/oban-job-processing-package-for-elixir/)

### 6.4 Cron-Based Reconciliation

```elixir
{Oban.Plugins.Cron, crontab: [
  {"*/15 * * * *", Slackex.Embeddings.ReconciliationWorker}
]}
```

The Cron plugin is centralized and leadership-aware -- only one node in the cluster runs cron jobs at a time, preventing duplicate reconciliation runs. [Oban Docs](https://hexdocs.pm/oban/Oban.html), [FullstackPhoenix: Recurring Jobs with Oban](https://fullstackphoenix.com/tutorials/how-to-setup-recurring-jobs-with-oban-in-elixir)

### 6.5 Error Handling Strategy

| API Response | Worker Action | Rationale |
|-------------|---------------|-----------|
| 200 OK | `:ok` | Success |
| 429 Rate Limited | `{:snooze, 60}` | Retry after cooldown, no failure count |
| 400 Bad Request | `{:cancel, reason}` | Don't retry bad input |
| 500 Server Error | `{:error, reason}` | Retry with exponential backoff |
| Network Timeout | `{:error, :timeout}` | Retry with exponential backoff |

[Oban.Worker Docs](https://hexdocs.pm/oban/Oban.Worker.html)

Default backoff is exponential with jitter. For max_attempts=3, retries occur at approximately 4s, 16s, and then the job is discarded. [Oban.Worker Docs](https://hexdocs.pm/oban/Oban.Worker.html)

### 6.6 Practical Recommendations

1. **Set embeddings queue concurrency to 3-5** for natural rate limiting against the OpenAI API.
2. **Use `{:snooze, seconds}` for 429 responses** to avoid wasting retry attempts.
3. **Use `{:cancel, reason}` for 400 responses** to prevent retrying known-bad inputs.
4. **The spec's uniqueness constraints are correct** for preventing duplicate backfill jobs.
5. **Monitor the Oban dashboard** (or logs) for discarded embedding jobs -- these indicate persistent API failures.

**Confidence: HIGH**

---

## 7. RAG Context Retrieval

### 7.1 Token Estimation

The spec uses `max_tokens: 4000, estimated at 4 chars/token` for context truncation.

**Accuracy of the 4 chars/token heuristic:**

- For average English text, ~4 characters per token and ~1.3 tokens per word is a reasonable approximation. [GitHub: Qwen Code Issue #1289](https://github.com/QwenLM/qwen-code/issues/1289), [Galileo: Tiktoken Guide](https://galileo.ai/blog/tiktoken-guide-production-ai)
- However, accuracy varies significantly: a 4,000-character passage might tokenize to 900 or 1,200 tokens depending on vocabulary density, whitespace, and special characters. [Galileo: Tiktoken Guide](https://galileo.ai/blog/tiktoken-guide-production-ai)
- Text with URLs, code snippets, or emoji can be 37% or more off from the heuristic. [Galileo: Tiktoken Guide](https://galileo.ai/blog/tiktoken-guide-production-ai)

**For chat messages specifically:** The heuristic is reasonably accurate. Chat messages are predominantly natural English text with simple vocabulary. The spec's `[timestamp] username: content` format adds predictable overhead per message (timestamp is ~25 chars = ~6 tokens, username ~10 chars = ~3 tokens).

**Alternative approach:** Use a proper tokenizer library. However, no mature Elixir tokenizer for cl100k_base exists. The heuristic is acceptable for RAG context budgeting where precision is not critical -- slightly overestimating (returning fewer messages) is better than exceeding the context window.

### 7.2 Chunking vs Full-Message Retrieval for Chat

The spec uses full-message retrieval (each message is one unit), not chunking. This is the correct approach for chat applications.

| Strategy | Best For | Rationale |
|----------|----------|-----------|
| **Full-message (spec)** | Chat/messaging | Messages are natural semantic units; splitting them loses meaning |
| **Fixed-size chunking** | Long documents | Standardizes input size; ~512 tokens recommended starting point |
| **Semantic chunking** | Articles/docs | Groups sentences by embedding similarity |

[Weaviate: Chunking Strategies for RAG](https://weaviate.io/blog/chunking-strategies-for-rag), [Unstructured: Chunking for RAG](https://unstructured.io/blog/chunking-for-rag-best-practices), [NVIDIA: Finding Best Chunking Strategy](https://developer.nvidia.com/blog/finding-the-best-chunking-strategy-for-accurate-ai-responses/)

Chat messages are typically 1-100 words (5-400 tokens). Chunking would either:
- Split messages unnecessarily (losing context), or
- Combine adjacent messages (losing attribution and temporal information)

The spec preserves message boundaries and attribution (`[timestamp] username: content`), which is critical for LLM grounding.

### 7.3 Context Window Formatting

The spec's format: `[2026-03-03 14:30:00] alice: Has anyone tried the new deployment pipeline?`

This is a common RAG formatting pattern for chat contexts. Key considerations:

- **Attribution is essential** -- the LLM needs to know who said what for accurate responses.
- **Timestamps provide temporal ordering** -- helps the LLM understand conversation flow.
- **Do not fill the context window to capacity** -- LLMs exhibit "lost in the middle" degradation, where information in the center of a long context is less attended to. [Weaviate: Chunking Strategies for RAG](https://weaviate.io/blog/chunking-strategies-for-rag)
- The spec's 4,000 token default is conservative (most modern LLMs have 8K-128K+ windows), leaving room for system prompts, instructions, and generation.

### 7.4 Relevance Filtering

The spec uses a similarity threshold of 0.3 (cosine distance). Messages less similar than this are excluded.

For cosine similarity with OpenAI embeddings:
- 0.8+ : Very similar content
- 0.5-0.8 : Related content
- 0.3-0.5 : Loosely related
- <0.3 : Likely irrelevant

The threshold of 0.3 (cosine distance, which corresponds to cosine similarity of 0.7) is a reasonable filter that includes related content while excluding noise.

### 7.5 Practical Recommendations

1. **Full-message retrieval is correct** for chat applications. Do not chunk.
2. **The 4 chars/token heuristic is acceptable** for context budgeting. Err on the side of conservative estimates.
3. **Consider a lower max_tokens** (e.g., 2,000-3,000) to stay within the "sweet spot" of LLM attention, leaving more room for the system prompt.
4. **Add a maximum message count cap** (e.g., 30 messages) in addition to token counting, to prevent contexts dominated by many tiny messages.
5. **Sort retrieved messages chronologically** (by timestamp) before formatting, not by similarity score, to preserve conversation flow.

**Confidence: MEDIUM-HIGH** -- Token estimation heuristic accuracy is well-documented but inherently approximate.

---

## 8. pgvector + Ecto Integration in Elixir

### 8.1 Setup Requirements

The `pgvector` Elixir package (version ~> 0.3) requires specific setup. [GitHub: pgvector/pgvector-elixir](https://github.com/pgvector/pgvector-elixir), [HexDocs: pgvector](https://hexdocs.pm/pgvector/readme.html), [Hex.pm: pgvector](https://hex.pm/packages/pgvector)

**Step 1: Custom Postgrex types (CRITICAL)**

```elixir
# lib/slackex/postgrex_types.ex
Postgrex.Types.define(
  Slackex.PostgrexTypes,
  Pgvector.extensions() ++ Ecto.Adapters.Postgres.extensions(),
  []
)
```

**Step 2: Configure the repo to use custom types**

```elixir
# config/config.exs
config :slackex, Slackex.Repo, types: Slackex.PostgrexTypes
```

**Step 3: Schema field type**

```elixir
field :embedding, Pgvector.Ecto.Vector
```

**Step 4: Migration column type**

```elixir
add :embedding, :vector, size: 1536
```

### 8.2 Query Patterns

```elixir
import Ecto.Query
import Pgvector.Ecto.Query

# Cosine distance (for ordering)
from e in MessageEmbedding,
  order_by: cosine_distance(e.embedding, ^Pgvector.new(query_embedding)),
  limit: 20

# With similarity threshold
from e in MessageEmbedding,
  where: cosine_distance(e.embedding, ^Pgvector.new(query_embedding)) < ^threshold,
  order_by: cosine_distance(e.embedding, ^Pgvector.new(query_embedding)),
  limit: 20
```

Available distance functions: `l2_distance`, `cosine_distance`, `max_inner_product`, `l1_distance`, `hamming_distance`, `jaccard_distance`. [GitHub: pgvector/pgvector-elixir](https://github.com/pgvector/pgvector-elixir), [HexDocs: pgvector](https://hexdocs.pm/pgvector/readme.html)

### 8.3 Known Gotchas

1. **Lists must be wrapped in `Pgvector.new/1`:** You cannot pass a raw list to distance functions. Always use `^Pgvector.new([1, 2, 3])`, not `^[1, 2, 3]`. [GitHub: pgvector/pgvector-elixir](https://github.com/pgvector/pgvector-elixir)

2. **Custom Postgrex types are mandatory:** Without `Postgrex.Types.define/3` and the repo configuration, Ecto cannot serialize/deserialize vector columns. This is a compile-time requirement. [GitHub: pgvector/pgvector-elixir](https://github.com/pgvector/pgvector-elixir), [HexDocs: pgvector](https://hexdocs.pm/pgvector/readme.html)

3. **HNSW index in Ecto migration:** Use `execute/1` for complex index syntax:
   ```elixir
   execute """
   CREATE INDEX idx_embeddings_hnsw ON message_embeddings
     USING hnsw (embedding vector_cosine_ops)
     WITH (m = 16, ef_construction = 64)
   """
   ```
   The standard `create index(...)` macro can work for simple cases (`create index("items", ["embedding vector_cosine_ops"], using: :hnsw)`) but does not support `WITH (m = 16, ef_construction = 64)` parameters directly. [GitHub: pgvector/pgvector-elixir](https://github.com/pgvector/pgvector-elixir), [Elixir Forum: Combined HNSW Index](https://elixirforum.com/t/how-to-create-a-combined-index-with-hnsw/59324)

4. **One index per distance function:** If you use both cosine and L2 distance, you need separate indexes. The spec uses only cosine, so one index suffices. [GitHub: pgvector/pgvector-elixir](https://github.com/pgvector/pgvector-elixir)

5. **Insert serialization:** Vectors can be inserted as plain lists -- Ecto handles serialization:
   ```elixir
   %MessageEmbedding{embedding: [0.1, 0.2, ...]} |> Repo.insert()
   ```
   [GitHub: pgvector/pgvector-elixir](https://github.com/pgvector/pgvector-elixir)

### 8.4 Practical Recommendations

1. **Create `lib/slackex/postgrex_types.ex` early** -- this is a prerequisite for all vector operations.
2. **Use `execute/1` in migration** for the HNSW index to specify `WITH` parameters.
3. **Always wrap query vectors** in `Pgvector.new/1` in Ecto queries.
4. **Test with StubClient** in dev/test to avoid needing OpenAI API keys during development.

**Confidence: HIGH** -- All information verified against official pgvector-elixir docs and README.

---

## 9. Authorization in Search

### 9.1 EXISTS vs JOIN for Authorization Filtering

The spec explicitly uses EXISTS-based subqueries instead of JOINs for authorization. This is a well-reasoned choice.

**The row duplication problem with JOINs:**

When using JOINs for authorization (e.g., `JOIN subscriptions ON ...`), a message can appear multiple times if a user has multiple subscription records or if the join condition matches multiple rows. This corrupts:
- **Ranking:** `ts_rank` and cosine distance values are duplicated, producing incorrect ordering.
- **Pagination:** OFFSET/LIMIT counts duplicate rows, causing messages to be skipped or repeated across pages.
- **Result counts:** The total count is inflated.

[PostgreSQL Docs: Subquery Expressions](https://www.postgresql.org/docs/current/functions-subquery.html), [Crunchy Data: Joins or Subquery in PostgreSQL](https://www.crunchydata.com/blog/joins-or-subquery-in-postgresql-lessons-learned), [MSSQLTips: EXISTS vs IN vs JOIN](https://www.mssqltips.com/sqlservertip/6659/sql-exists-vs-in-vs-join-performance-comparison/)

**EXISTS prevents this:**

> "A simple EXISTS example is like an inner join on col2, but it produces at most one output row for each tab1 row, even if there are several matching tab2 rows." -- [PostgreSQL Docs](https://www.postgresql.org/docs/current/functions-subquery.html)

EXISTS is semantically a boolean check: "does at least one matching row exist?" It short-circuits after finding the first match and never duplicates the outer row. [PostgreSQL Docs: Subquery Expressions](https://www.postgresql.org/docs/current/functions-subquery.html), [Crunchy Data: Joins or Subquery in PostgreSQL](https://www.crunchydata.com/blog/joins-or-subquery-in-postgresql-lessons-learned)

### 9.2 Performance Considerations

- **EXISTS is often faster than JOIN for existence checks** because it stops scanning after the first match. [MSSQLTips: EXISTS vs IN vs JOIN](https://www.mssqltips.com/sqlservertip/6659/sql-exists-vs-in-vs-join-performance-comparison/), [GeeksforGeeks: SQL Join vs Subquery](https://www.geeksforgeeks.org/sql/sql-join-vs-subquery/)
- PostgreSQL's query optimizer can often transform EXISTS subqueries into semi-joins internally, achieving similar performance to explicit JOINs. [CYBERTEC: Subqueries and Performance](https://www.cybertec-postgresql.com/en/subqueries-and-performance-in-postgresql/)
- The EXISTS subqueries in the spec reference small lookup tables (`subscriptions`, `dm_conversations`) with indexed columns, so the subquery execution is fast.

### 9.3 The Spec's Authorization Pattern

```sql
WHERE (
  -- Public channels: visible to all authenticated users
  EXISTS (SELECT 1 FROM channels WHERE channels.id = messages.channel_id AND channels.is_private = false)
  OR
  -- Private channels: only to members
  EXISTS (SELECT 1 FROM subscriptions WHERE subscriptions.channel_id = messages.channel_id AND subscriptions.user_id = $user_id)
  OR
  -- DMs: only to participants
  EXISTS (SELECT 1 FROM dm_conversations WHERE dm_conversations.id = message_embeddings.dm_conversation_id AND (user_a_id = $user_id OR user_b_id = $user_id))
)
```

This is correct and maintains three orthogonal authorization paths (public, private, DM) without row duplication.

### 9.4 Practical Recommendations

1. **EXISTS-based authorization is correct.** Do not switch to JOINs.
2. **Ensure indexes exist** on `channels.id`, `channels.is_private`, `subscriptions.channel_id + user_id`, and `dm_conversations.user_a_id / user_b_id`.
3. **With pgvector 0.8.0+ iterative scan**, the EXISTS clauses act as filters during vector search. Enable `hnsw.iterative_scan` to prevent result shortfalls from authorization filtering.
4. **Test with users who have access to many channels** -- the OR'd EXISTS pattern is evaluated for every candidate row, so users with broad access should not cause performance degradation (PostgreSQL short-circuits OR evaluation).

**Confidence: HIGH**

---

## 10. Partitioned Tables + pgvector

### 10.1 The Foreign Key Limitation

PostgreSQL does not support foreign key references TO a partitioned table unless the FK includes the full partition key. The messages table has a composite PK `(id, inserted_at)` (partitioned by `inserted_at`). A simple FK `message_embeddings.message_id -> messages.id` is not possible because `id` alone is not unique across partitions.

[PostgreSQL Docs: Table Partitioning](https://www.postgresql.org/docs/current/ddl-partitioning.html), [EDB: PostgreSQL 12 Foreign Keys and Partitioned Tables](https://www.enterprisedb.com/blog/postgresql-12-foreign-keys-and-partitioned-tables), [Depesz: FK to Partitioned Table](https://www.depesz.com/2018/10/02/foreign-key-to-partitioned-table/)

The spec's decision to skip the FK and enforce integrity at the application level is the correct approach. Key rationale:
- The FK would require `message_embeddings` to include `message_inserted_at` in the FK constraint, adding complexity.
- Even with PostgreSQL 12+ FK support for partitioned tables, FK creation on partitioned tables with many partitions can take 30+ minutes per constraint. [PostgreSQL Mailing List: FK on Partitioned Table Performance](https://www.postgresql.org/message-id/CAE+E=SQacy6t_3XzCWnY1eiRcNWfz4pp02FER0N7mU_F+o8G_Q@mail.gmail.com)
- Orphaned embeddings are harmless (they waste storage but do not affect correctness) and can be cleaned by a periodic job.

### 10.2 Partition-Aware Joins

The spec stores `message_inserted_at` in `message_embeddings` and joins on `(message_id, message_inserted_at) = (id, inserted_at)`. This is critical for partition pruning.

**Why this matters:**

- Without `inserted_at` in the join condition, PostgreSQL must scan ALL partitions of the messages table to find the matching message. [EDB: Multi-column Partitioning and Pruning](https://www.enterprisedb.com/postgres-tutorials/what-multi-column-partitioning-postgresql-and-how-pruning-occurs)
- With `inserted_at` in the join, PostgreSQL can prune to the single relevant partition, reducing I/O by orders of magnitude. [PostgreSQL Docs: Table Partitioning](https://www.postgresql.org/docs/current/ddl-partitioning.html), [EDB: Multi-column Partitioning](https://www.enterprisedb.com/postgres-tutorials/what-multi-column-partitioning-postgresql-and-how-pruning-occurs)
- Partition pruning can occur at both planning time and execution time (runtime pruning), so even parameterized queries benefit. [PostgreSQL Docs: Table Partitioning](https://www.postgresql.org/docs/current/ddl-partitioning.html)

The spec's approach of copying `message_inserted_at` from the message's `inserted_at` (derived from Snowflake ID) enables this optimization. This is the correct pattern.

### 10.3 Index Considerations on Partitioned Tables

- GIN indexes (for FTS) on the partitioned messages table are created as local indexes on each partition. PostgreSQL handles this automatically when you create an index on the parent table. [PostgreSQL Docs: Table Partitioning](https://www.postgresql.org/docs/current/ddl-partitioning.html)
- The `message_embeddings` table is NOT partitioned, so the HNSW index is a single global index. This simplifies vector search but means the entire index must fit in memory.
- If `message_embeddings` grows very large (millions of rows), consider partitioning it by `channel_id` or time range. However, pgvector HNSW indexes do not currently support cross-partition queries, so this would require application-level fan-out.

### 10.4 Practical Recommendations

1. **The composite join key pattern is correct and essential.** Always include `message_inserted_at` in joins with the partitioned messages table.
2. **No FK is the right choice.** Application-level integrity with periodic orphan cleanup is sufficient.
3. **Add an orphan cleanup Oban cron job** that deletes embeddings where no matching message exists. Run weekly or monthly.
4. **Monitor HNSW index size** as embeddings grow. At 1M+ embeddings, ensure `shared_buffers` and system RAM can accommodate the index.
5. **Run `EXPLAIN ANALYZE`** on the semantic search query to verify partition pruning is occurring. Look for "Partitions removed" in the plan output.

**Confidence: HIGH**

---

## 11. Risk Register

| # | Risk | Severity | Likelihood | Mitigation |
|---|------|----------|-----------|------------|
| R1 | pgvector < 0.8.0 causes authorization-filtered vector queries to return fewer results than requested | HIGH | MEDIUM | Require pgvector >= 0.8.0; enable `hnsw.iterative_scan` |
| R2 | Missing GIN index on messages.content causes FTS to sequential scan all partitions | HIGH | HIGH | Explicitly create GIN index in migration |
| R3 | Postgrex custom types not configured causes runtime crash on first vector operation | HIGH | MEDIUM | Add `Postgrex.Types.define` early; test in CI |
| R4 | HNSW index build on large backfill blocks PostgreSQL for minutes | MEDIUM | MEDIUM | Build index after initial data load; increase `maintenance_work_mem` |
| R5 | PersistenceListener down for >1 hour causes embedding gap beyond reconciliation window | LOW | LOW | Monitor coverage ratio; manual backfill for extended outages |
| R6 | OpenAI API rate limiting during backfill causes job failures | MEDIUM | MEDIUM | Use `{:snooze, N}` for 429s; limit queue concurrency to 3-5 |
| R7 | Token estimation heuristic (4 chars/token) overflows LLM context window with code-heavy messages | LOW | LOW | Add max message count cap; conservative token budget |
| R8 | Message edits leave stale embeddings | LOW | MEDIUM | Decide on edit re-embedding policy; document the decision |
| R9 | `Pgvector.new/1` not used in Ecto queries causes silent type errors | MEDIUM | MEDIUM | Establish pattern in code review; unit test vector queries |
| R10 | Orphaned embeddings accumulate over time (no FK enforcement) | LOW | HIGH | Periodic cleanup Oban job (weekly/monthly) |

---

## 12. Knowledge Gaps

### 12.1 Documented Gaps

| Topic | What Was Searched | Finding |
|-------|-------------------|---------|
| **Elixir tiktoken library** | Searched for Elixir/Erlang BPE tokenizer compatible with cl100k_base | No mature Elixir library found. The 4 chars/token heuristic is the pragmatic alternative for this ecosystem. |
| **pgvector HNSW with partitioned embedding tables** | Searched for pgvector support of HNSW indexes across partitioned tables | pgvector HNSW indexes are local to each partition. Cross-partition ANN queries are not natively supported. This is not a concern for the current spec (embeddings table is not partitioned), but becomes relevant if the table grows beyond single-index capacity. |
| **Oban open-source per-worker rate limiting** | Searched for built-in rate limiting in Oban OSS | Not available in open-source Oban. Rate limiting requires Oban Pro's Smart Engine or application-level implementation (queue concurrency + snooze). |
| **text-embedding-3-small behavior on very short texts** | Searched for embedding quality degradation on texts under 10 tokens | No authoritative benchmarks found for embedding quality on very short messages (e.g., "ok", "thanks", "lol"). These messages may produce low-quality embeddings that add noise to semantic search. Consider filtering messages below a minimum length before embedding. |
| **RRF behavior with highly asymmetric result sets** | Searched for RRF performance when one search mode returns many results and the other returns few | Limited data. The original paper tested roughly balanced result sets. In practice, if FTS returns 100 results and semantic returns 5, the semantic results may be underweighted despite being highly relevant. The spec's approach of running both with the same limit (default 20) helps mitigate this. |

### 12.2 Areas Requiring Empirical Validation

These questions can only be answered through testing with the application's actual data:

1. **Optimal ef_search value:** Start with 100, measure recall vs latency, adjust.
2. **Similarity threshold (0.3):** May need adjustment based on actual embedding quality for chat messages.
3. **Reconciliation lookback window (1 hour):** Monitor coverage metrics to determine if this is sufficient.
4. **Queue concurrency for embeddings:** Start with 5, adjust based on OpenAI rate limit responses.

---

## Summary of Spec Alignment

The Phase 4 spec is well-researched and makes sound technical choices across all areas. Key validations:

- **pgvector with HNSW (m=16, ef_construction=64):** Defaults are correct and recommended.
- **text-embedding-3-small at 1536 dimensions:** Optimal cost-performance choice.
- **RRF with k=60:** Industry standard, empirically validated.
- **EXISTS-based authorization:** Prevents row duplication, correct for ranked search.
- **Composite join key for partition pruning:** Essential pattern, correctly implemented.
- **Event bridge + reconciliation:** Standard pattern for eventual consistency.

**Three items to add to the spec:**
1. A GIN index on `to_tsvector('english', content)` for the messages table.
2. A requirement for pgvector >= 0.8.0 with `hnsw.iterative_scan` enabled.
3. The `Postgrex.Types.define` setup in the Ecto integration checklist.

**One item to consider upgrading:**
- `plainto_tsquery` to `websearch_to_tsquery` for richer user-facing search syntax.

---

## Sources Index

### Official Documentation
- [PostgreSQL: Table Partitioning](https://www.postgresql.org/docs/current/ddl-partitioning.html)
- [PostgreSQL: Controlling Text Search](https://www.postgresql.org/docs/current/textsearch-controls.html)
- [PostgreSQL: Text Search Indexes](https://www.postgresql.org/docs/current/textsearch-indexes.html)
- [PostgreSQL: Subquery Expressions](https://www.postgresql.org/docs/current/functions-subquery.html)
- [PostgreSQL: pgvector 0.8.0 Released](https://www.postgresql.org/about/news/pgvector-080-released-2952/)
- [OpenAI: New Embedding Models](https://openai.com/index/new-embedding-models-and-api-updates/)
- [OpenAI: Rate Limits Guide](https://platform.openai.com/docs/guides/rate-limits)
- [OpenAI: Pricing](https://platform.openai.com/docs/pricing)

### GitHub Repositories and Package Documentation
- [pgvector/pgvector](https://github.com/pgvector/pgvector)
- [pgvector/pgvector-elixir](https://github.com/pgvector/pgvector-elixir)
- [HexDocs: pgvector](https://hexdocs.pm/pgvector/readme.html)
- [Hex.pm: pgvector](https://hex.pm/packages/pgvector)
- [Oban GitHub](https://github.com/oban-bg/oban)
- [HexDocs: Oban.Worker](https://hexdocs.pm/oban/Oban.Worker.html)
- [HexDocs: Oban](https://hexdocs.pm/oban/Oban.html)

### Academic and Research Papers
- [Cormack, Clarke, Buttcher: "Reciprocal Rank Fusion outperforms Condorcet and Individual Rank Learning Methods" (SIGIR 2009)](https://dl.acm.org/doi/10.1145/1571941.1572114)
- [Original RRF Paper PDF](https://cormack.uwaterloo.ca/cormacksigir09-rrf.pdf)
- [Google Research: RRF](https://research.google/pubs/reciprocal-rank-fusion-outperforms-condorcet-and-individual-rank-learning-methods/)

### Technical Blogs and Cloud Provider Documentation
- [Jonathan Katz: pgvector HNSW Performance](https://jkatz05.com/post/postgres/pgvector-hnsw-performance/)
- [Jonathan Katz: pgvector 150x Speedup](https://jkatz05.com/post/postgres/pgvector-performance-150x-speedup/)
- [Crunchy Data: HNSW Indexes](https://www.crunchydata.com/blog/hnsw-indexes-with-postgres-and-pgvector)
- [Crunchy Data: Joins or Subquery in PostgreSQL](https://www.crunchydata.com/blog/joins-or-subquery-in-postgresql-lessons-learned)
- [AWS: pgvector HNSW/IVFFlat Deep Dive](https://aws.amazon.com/blogs/database/optimize-generative-ai-applications-with-pgvector-indexing-a-deep-dive-into-ivfflat-and-hnsw-techniques/)
- [AWS: pgvector 0.8.0 on Aurora](https://aws.amazon.com/blogs/database/supercharging-vector-search-performance-and-relevance-with-pgvector-0-8-0-on-amazon-aurora-postgresql/)
- [Microsoft Learn: Hybrid Search Scoring RRF](https://learn.microsoft.com/en-us/azure/search/hybrid-search-ranking)
- [Elasticsearch: Reciprocal Rank Fusion](https://www.elastic.co/docs/reference/elasticsearch/rest-apis/reciprocal-rank-fusion)
- [Google Cloud: Event-driven Architecture with Pub/Sub](https://docs.google.com/solutions/event-driven-architecture-pubsub)
- [EDB: PostgreSQL 12 Foreign Keys and Partitioned Tables](https://www.enterprisedb.com/blog/postgresql-12-foreign-keys-and-partitioned-tables)
- [EDB: Multi-column Partitioning](https://www.enterprisedb.com/postgres-tutorials/what-multi-column-partitioning-postgresql-and-how-pruning-occurs)
- [Pinecone: OpenAI Embeddings v3](https://www.pinecone.io/learn/openai-embeddings-v3/)
- [Clarvo: Optimizing Filtered Vector Queries](https://www.clarvo.ai/blog/optimizing-filtered-vector-queries-from-tens-of-seconds-to-single-digit-milliseconds-in-postgresql)

### Elixir Community
- [Peter Ullrich: Full-text Search with Postgres and Ecto](https://peterullrich.com/complete-guide-to-full-text-search-with-postgres-and-ecto)
- [DockYard: Parallel Request Processing with Oban](https://dockyard.com/blog/2024/03/26/parallel-request-processing-with-elixir-and-oban)
- [DEV.to: Adding Embeddings to a Phoenix App](https://dev.to/byronsalty/adding-embeddings-to-a-phoenix-app-120a)
- [Elixir Forum: Rate Limiting with Oban](https://elixirforum.com/t/how-to-rate-limit-with-oban/64201)
- [Elixir Forum: Combined HNSW Index](https://elixirforum.com/t/how-to-create-a-combined-index-with-hnsw/59324)
- [FullstackPhoenix: Recurring Jobs with Oban](https://fullstackphoenix.com/tutorials/how-to-setup-recurring-jobs-with-oban-in-elixir)
- [Milmazz: Oban Job Processing](https://milmazz.uno/article/2022/02/11/oban-job-processing-package-for-elixir/)

### Search and RAG
- [Weaviate: Chunking Strategies for RAG](https://weaviate.io/blog/chunking-strategies-for-rag)
- [Unstructured: Chunking for RAG](https://unstructured.io/blog/chunking-for-rag-best-practices)
- [NVIDIA: Finding Best Chunking Strategy](https://developer.nvidia.com/blog/finding-the-best-chunking-strategy-for-accurate-ai-responses/)
- [Assembled: Better RAG Results with RRF](https://www.assembled.com/blog/better-rag-results-with-reciprocal-rank-fusion-and-hybrid-search)
- [OpenSearch: Introducing RRF](https://opensearch.org/blog/introducing-reciprocal-rank-fusion-hybrid-search/)
- [Galileo: Tiktoken Guide](https://galileo.ai/blog/tiktoken-guide-production-ai)
- [PingCAP: Analyzing text-embedding-3-small Performance](https://www.pingcap.com/article/analyzing-performance-gains-in-openais-text-embedding-3-small/)
