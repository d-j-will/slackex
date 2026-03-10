# Embedding Provider Research

**Date**: 2026-03-03
**Status**: Complete
**Context**: Phase 4 Intelligence & Search — selecting a real embedding provider to replace `StubClient` and enable `:message_search` in production.

## Executive Summary

**Primary Recommendation: Bumblebee + all-MiniLM-L6-v2 (Elixir native)**
- Zero cost, zero external dependency, proven Elixir integration
- 384 dimensions (requires migration from current `vector(1536)`)
- Acceptable quality for a messaging app's semantic search
- ~80MB model, runs on CPU in the BEAM process

**Fallback: Ollama with nomic-embed-text** if Bumblebee latency is unacceptable on CPU for the deployment hardware.

**Budget fallback: Jina AI free tier** (10M free tokens) or **Voyage AI free tier** (200M free tokens) if local compute is too constrained.

The current `vector(1536)` schema must be migrated regardless of the choice (only OpenAI uses 1536; all free/local options use 384–1024 dims). This is a one-time migration since the table is new and has no production data yet (feature flag is off).

---

## 1. Free-Tier API Providers

### Jina AI Embeddings API
- **Free tier**: 10 million tokens per API key, no credit card required
- **Rate limits (free)**: 100 RPM, 100K TPM, 2 concurrent requests
- **Model**: jina-embeddings-v3 — 1024 dimensions
- **Quality**: Strong MTEB scores, multilingual
- **Paid**: token-based pricing after free tier exhausted
- **Verdict**: Good free starter option. 10M tokens covers ~5M short messages. For a small team (~1000 msgs/day at ~20 tokens each = 20K tokens/day), the free tier lasts ~500 days. **Viable for initial rollout.**

Sources: [Jina AI Embeddings](https://jina.ai/embeddings/)

### Voyage AI
- **Free tier**: 200 million tokens for voyage-3.5-lite (and other v3+ models)
- **Model**: voyage-3.5-lite — $0.02/1M tokens after free tier
- **Dimensions**: 1024
- **Quality**: Strong retrieval benchmarks, competitive with OpenAI
- **Verdict**: Most generous free tier. 200M tokens covers years of usage for a small team. **Best free API option.**

Sources: [Voyage AI Pricing](https://docs.voyageai.com/docs/pricing), [MongoDB Voyage 3.5 Announcement](https://www.mongodb.com/company/blog/product-release-announcements/introducing-voyage-3-5-voyage-3-5-lite-improved-quality-new-retrieval-frontier)

### Google Gemini Embedding
- **Free tier**: Available but quota limits not fully documented
- **Model**: gemini-embedding-001 (replacing deprecated text-embedding-004)
- **Dimensions**: 768 (configurable)
- **Paid**: $0.15/1M tokens (standard), $0.075/1M (batch)
- **Verdict**: Free tier exists but limits unclear. Paid pricing is 7.5x more expensive than OpenAI small. **Not recommended unless free tier proves generous.**

Sources: [Gemini API Pricing](https://ai.google.dev/gemini-api/docs/pricing), [Gemini Embedding Blog](https://developers.googleblog.com/gemini-embedding-available-gemini-api/)

### Hugging Face Serverless Inference API
- **Free tier**: Rate-limited, ~few hundred requests/hour
- **Models**: Any embedding model on HF Hub (all-MiniLM-L6-v2, etc.)
- **Dimensions**: Model-dependent (384 for MiniLM)
- **Verdict**: Rate limits too low for batch processing. Models cold-start. **Not recommended for production.**

Sources: [HF Inference API FAQ](https://huggingface.co/docs/api-inference/faq), [HF Pricing](https://huggingface.co/pricing)

---

## 2. Local / Self-Hosted

### Ollama with Embedding Models
- **Cost**: Free (open source)
- **Models available**:
  - `nomic-embed-text` — 768 dims, 0.5GB RAM, 8192 token context, surpasses OpenAI ada-002
  - `mxbai-embed-large` — 1024 dims, 1.2GB RAM, MTEB retrieval score 64.68
  - `all-minilm:l6-v2` — 384 dims, ~80MB RAM, lightweight
- **Integration**: HTTP API at `localhost:11434`, simple JSON request/response
- **Operational**: Single binary install, `ollama pull <model>` + `ollama serve`
- **Docker**: Official Docker image available, can run alongside app in docker-compose
- **Verdict**: Easy to set up, good model selection. `nomic-embed-text` is the sweet spot (quality + size). Already runs on the Docker host. **Strong option.**

Sources: [Ollama Embedding Models Blog](https://ollama.com/blog/embedding-models), [nomic-embed-text](https://ollama.com/library/nomic-embed-text), [mxbai-embed-large](https://ollama.com/library/mxbai-embed-large)

### Hugging Face Text Embeddings Inference (TEI)
- **Cost**: Free (open source)
- **Resource requirements**: ~4GB RAM for CPU deployment (1 CPU + 4Gi baseline)
- **Models**: Any sentence-transformers model from HF Hub
- **Features**: Token-based dynamic batching, OpenAI-compatible API, optimized Rust backend
- **Docker**: Official images for CPU and GPU
- **Verdict**: Production-grade inference server. More complex to operate than Ollama but higher throughput. **Good for scale, overkill for small team.**

Sources: [TEI GitHub](https://github.com/huggingface/text-embeddings-inference), [TEI Docs](https://huggingface.co/docs/text-embeddings-inference/en/index)

### Sentence-Transformers via FastAPI
- **Cost**: Free
- **Complexity**: Requires Python runtime, FastAPI server, pip dependencies
- **Verdict**: Unnecessary complexity when Ollama and TEI exist. **Not recommended.**

---

## 3. Elixir Native (Nx/Bumblebee)

### Bumblebee + all-MiniLM-L6-v2
- **Cost**: Free, no external dependency
- **Dimensions**: 384
- **Model size**: ~80MB (downloaded once from HF Hub, cached locally)
- **Memory**: Model loaded into BEAM memory (~200-400MB with Nx tensors)
- **Integration**: First-class Elixir — `Bumblebee.load_model/1`, `Nx.Serving.run/2`
- **Proven pattern**: pgvector-elixir has an official Bumblebee example:

```elixir
model_id = "sentence-transformers/all-MiniLM-L6-v2"
{:ok, model_info} = Bumblebee.load_model({:hf, model_id})
{:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, model_id})

serving = Bumblebee.Text.text_embedding(model_info, tokenizer,
  output_attribute: :hidden_state,
  output_pool: :mean_pooling,
  embedding_processor: :l2_norm
)

embeddings = Nx.Serving.run(serving, ["search query"])
```

- **Quality**: MTEB retrieval ~56% Top-5 (older architecture, but acceptable for message search)
- **Latency**: CPU inference for short texts is fast (~10-50ms per text on modern hardware). Batch processing viable via `Nx.Serving` with batching.
- **Startup**: Model download on first run (~80MB), then cached. Loading into memory takes a few seconds.
- **Risk**: CPU-only on BEAM may be slow for large batch backfills. Can mitigate with Oban job concurrency limits.
- **Verdict**: **Best fit for this project's priorities.** Zero cost, zero dependency, native Elixir, proven pgvector integration. Quality is "good enough" for messaging search.

Sources: [pgvector-elixir Bumblebee example](https://github.com/pgvector/pgvector-elixir/blob/master/examples/bumblebee/example.exs), [Bumblebee GitHub](https://github.com/elixir-nx/bumblebee), [DockYard Semantic Search](https://dockyard.com/blog/2023/01/11/semantic-search-with-phoenix-axon-bumblebee-and-exfaiss), [DEV.to Bumblebee Semantic Search](https://dev.to/ndrean/an-example-of-semantic-search-with-elixir-and-bumblebee-h9n)

### Bumblebee + e5-small
- **Dimensions**: 384
- **Quality**: Reported 100% Top-5 accuracy on some retrieval benchmarks, <30ms latency
- **Status**: Needs verification that Bumblebee supports e5-small model loading
- **Verdict**: Worth testing as alternative to MiniLM if Bumblebee supports it.

### Bumblebee + BGE-small-en-v1.5
- **Dimensions**: 384
- **Quality**: BGE family scores well on MTEB; BGE-M3 (larger) scores 63.0
- **Status**: Needs verification that Bumblebee supports BGE models
- **Verdict**: Worth testing alongside MiniLM and e5-small.

---

## 4. Provider APIs

### OpenAI text-embedding-3-small (already implemented)
- **Cost**: $0.02/1M tokens (standard), $0.01/1M (batch)
- **Dimensions**: 1536 (default), can reduce to 512 via `dimensions` parameter
- **Quality**: Strong MTEB scores
- **Note**: Cannot reduce to 384 — only 512 and 1536 supported
- **Verdict**: Already implemented in `OpenAIClient`. Cheapest paid API. Use as production fallback if local options fail.

Sources: [OpenAI Embeddings Guide](https://platform.openai.com/docs/guides/embeddings), [OpenAI Models](https://platform.openai.com/docs/models/text-embedding-3-small)

### Cohere embed-v4
- **Cost**: $0.12/1M tokens (6x more than OpenAI small)
- **Quality**: MTEB leader at 65.2
- **Verdict**: Too expensive for marginal quality gain. **Not recommended.**

Sources: [Cohere Pricing](https://www.metacto.com/blogs/cohere-pricing-explained-a-deep-dive-into-integration-development-costs)

### Voyage AI voyage-3.5-lite
- **Cost**: $0.02/1M tokens (same as OpenAI small), 200M free tokens
- **Dimensions**: 1024
- **Quality**: Competitive with OpenAI
- **Verdict**: Best value paid API thanks to generous free tier. **Good alternative to OpenAI.**

### Google gemini-embedding-001
- **Cost**: $0.15/1M tokens
- **Dimensions**: 768 (configurable)
- **Verdict**: Expensive. **Not recommended.**

---

## Comparison Matrix

| Provider | Model | Dims | MTEB Retrieval | Cost/1M tokens | Latency | Elixir Fit | Dependency |
|----------|-------|------|---------------|----------------|---------|------------|------------|
| **Bumblebee** | all-MiniLM-L6-v2 | 384 | ~56% Top-5 | Free | ~10-50ms (CPU) | Native | None |
| **Bumblebee** | e5-small | 384 | ~100% Top-5* | Free | <30ms* | Native | None |
| **Ollama** | nomic-embed-text | 768 | Beats ada-002 | Free | ~5-20ms | HTTP client | Docker sidecar |
| **Ollama** | mxbai-embed-large | 1024 | 64.68 | Free | ~10-30ms | HTTP client | Docker sidecar |
| **Jina** | jina-embeddings-v3 | 1024 | Strong | Free (10M) | ~50-100ms | HTTP client | External API |
| **Voyage** | voyage-3.5-lite | 1024 | Strong | Free (200M) | ~50-100ms | HTTP client | External API |
| OpenAI | text-embed-3-small | 1536/512 | Strong | $0.02 | ~50-100ms | Implemented | External API |
| Cohere | embed-v4 | varies | 65.2 (best) | $0.12 | ~50-100ms | HTTP client | External API |
| Google | gemini-embed-001 | 768 | Good | $0.15 | ~50-100ms | HTTP client | External API |

*e5-small benchmarks from specific retrieval task, not general MTEB average. Needs independent verification.

---

## Migration Considerations

### Dimension Change (Required for all non-OpenAI options)

The current schema uses `vector(1536)`. All recommended options use smaller dimensions (384, 768, or 1024).

**Impact is minimal because:**
1. Feature flag `:message_search` is **off** — no production data in `message_embeddings` table yet
2. Migration is a simple column type change: `ALTER COLUMN embedding TYPE vector(384)`
3. No backfill needed (table is empty in production)

**Migration approach:**
```elixir
# Expand phase: change column dimension
alter table(:message_embeddings) do
  modify :embedding, :"vector(384)"
end
```

If starting with Bumblebee (384 dims) but wanting to keep the option for higher-dimension models later, consider starting with 384 and migrating up if needed. Migrating up requires re-embedding all data; migrating down requires truncation. Starting small is better.

### EmbeddingClient Implementation

The `EmbeddingClient` behaviour (`generate/1`, `generate_batch/1`, `dimensions/0`) makes swapping providers trivial:

```elixir
defmodule Slackex.Embeddings.BumblebeeClient do
  @behaviour Slackex.Embeddings.EmbeddingClient

  def dimensions, do: 384

  def generate(text) do
    %{embedding: embedding} = Nx.Serving.run(Slackex.Embeddings.Serving, text)
    {:ok, Nx.to_flat_list(embedding)}
  end

  def generate_batch(texts) do
    results = Nx.Serving.run(Slackex.Embeddings.Serving, texts)
    {:ok, Enum.map(results, fn %{embedding: e} -> Nx.to_flat_list(e) end)}
  end
end
```

---

## Recommended Path Forward

### Phase 1: Bumblebee Proof of Concept
1. Add `bumblebee` and `exla` (or `torchx`) to `mix.exs` deps
2. Create `Slackex.Embeddings.BumblebeeClient` implementing the behaviour
3. Create `Slackex.Embeddings.Serving` GenServer to hold the loaded model
4. Migrate `message_embeddings.embedding` from `vector(1536)` to `vector(384)`
5. Run search tests against Bumblebee — verify quality is acceptable for message search
6. Benchmark: latency per query, memory footprint, batch throughput

### Phase 2: Evaluate and Ship
- If Bumblebee performance is acceptable → ship it, enable `:message_search`
- If CPU latency is too high for batch processing → add Ollama as sidecar with `nomic-embed-text` (768 dims)
- If local compute is too constrained → use Voyage AI free tier (200M tokens, years of headroom)

### Phase 3: Production Monitoring
- Monitor embedding generation latency via Oban job telemetry
- Track search quality via user engagement (clicks on search results)
- Reassess provider if quality or performance falls short

---

## Knowledge Gaps

1. **Bumblebee + e5-small/BGE-small compatibility**: Not confirmed whether Bumblebee can load these models. Needs hands-on testing with `Bumblebee.load_model({:hf, "intfloat/e5-small-v2"})`.
2. **CPU inference latency on deployment hardware**: Benchmarks cited are from various hardware. Need to test on the actual Docker host to confirm <100ms target.
3. **EXLA vs Torchx backend**: EXLA (Google XLA) is generally faster but requires larger compilation cache. Torchx is simpler. Need to test both.
4. **Bumblebee batch serving**: `Nx.Serving` supports batching but exact throughput for 100-text batches on CPU is unknown. Critical for the Oban worker path.
5. **Memory pressure**: Running embedding model in the same BEAM as the app adds ~200-400MB. Need to verify the Docker host has sufficient headroom.
6. **e5-small "100% Top-5" claim**: This was from a specific product-search benchmark, not general MTEB. Actual retrieval quality for short message search needs verification.

---

## Sources

- [pgvector-elixir Bumblebee Example](https://github.com/pgvector/pgvector-elixir/blob/master/examples/bumblebee/example.exs)
- [Bumblebee GitHub](https://github.com/elixir-nx/bumblebee)
- [DockYard: Semantic Search with Phoenix + Bumblebee](https://dockyard.com/blog/2023/01/11/semantic-search-with-phoenix-axon-bumblebee-and-exfaiss)
- [DEV.to: Semantic Search with Elixir and Bumblebee](https://dev.to/ndrean/an-example-of-semantic-search-with-elixir-and-bumblebee-h9n)
- [Ollama Embedding Models](https://ollama.com/blog/embedding-models)
- [nomic-embed-text on Ollama](https://ollama.com/library/nomic-embed-text)
- [mxbai-embed-large on Ollama](https://ollama.com/library/mxbai-embed-large)
- [HF Text Embeddings Inference](https://github.com/huggingface/text-embeddings-inference)
- [Jina AI Embeddings](https://jina.ai/embeddings/)
- [Voyage AI Pricing](https://docs.voyageai.com/docs/pricing)
- [OpenAI Embeddings Guide](https://platform.openai.com/docs/guides/embeddings)
- [Gemini API Pricing](https://ai.google.dev/gemini-api/docs/pricing)
- [13 Best Embedding Models 2026 (Elephas)](https://elephas.app/blog/best-embedding-models)
- [Best Embedding Models 2025 MTEB (Ailog)](https://app.ailog.fr/en/blog/guides/choosing-embedding-models)
- [all-MiniLM-L6-v2 on HuggingFace](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2)
- [Collabnix Ollama Embedded Models Guide 2025](https://collabnix.com/ollama-embedded-models-the-complete-technical-guide-for-2025-enterprise-deployment/)
