# Embedding Provider Evaluation

**Status**: Complete
**Date**: 2026-03-05
**Context**: BumblebeeClient disabled in prod (v0.5.43) — EXLA OOM crashes on 20GB LXC. StubClient active. Semantic search degraded. Need a production-ready provider that avoids all local ML memory concerns.
**Recommendation**: **DeepInfra direct** via configured `OpenAIClient` — same model, same vectors, ~$0.001/month, zero local memory.

---

## Key Finding: No New Code Needed

The existing `OpenAIClient` (`lib/slackex/embeddings/openai_client.ex`) uses the OpenAI-compatible embeddings API format. DeepInfra and OpenRouter implement the **identical API format**. The integration requires making `OpenAIClient` configurable (URL, model, dimensions from app config) and pointing it at DeepInfra.

---

## Provider Comparison

### 1. DeepInfra (Direct) — RECOMMENDED

| Attribute | Value |
|-----------|-------|
| **Endpoint** | `https://api.deepinfra.com/v1/openai/embeddings` |
| **Model** | `sentence-transformers/all-MiniLM-L6-v2` |
| **Dimensions** | 384 (identical to BumblebeeClient) |
| **Pricing** | $0.005 / 1M input tokens |
| **Auth** | Bearer token (`EMBEDDING_API_KEY` env var) |
| **Batch support** | Yes — `input` accepts `string[]` |
| **Max batch** | ~1024 texts per request |
| **API format** | OpenAI-compatible (`/v1/openai/embeddings`) |
| **Data policy** | No training on inputs, no prompt retention |
| **Free tier** | None — pay-as-you-go |

**Curl example:**
```bash
curl "https://api.deepinfra.com/v1/openai/embeddings" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $DEEPINFRA_TOKEN" \
  -d '{
    "input": ["Hello world", "Test sentence"],
    "model": "sentence-transformers/all-MiniLM-L6-v2",
    "encoding_format": "float"
  }'
```

**Response** (identical to OpenAI format):
```json
{
  "data": [
    {"embedding": [0.123, -0.456, ...], "index": 0},
    {"embedding": [0.789, -0.012, ...], "index": 1}
  ],
  "usage": {"prompt_tokens": 8, "total_tokens": 8}
}
```

**Why recommended:** Same model as BumblebeeClient (all-MiniLM-L6-v2), same 384-dim vectors, no migration needed, negligible cost, zero local memory, existing `OpenAIClient` code handles the API format.

**Sources:**
- [DeepInfra API Reference](https://deepinfra.com/sentence-transformers/all-MiniLM-L6-v2/api)
- [DeepInfra OpenAI API Compatibility](https://deepinfra.com/docs/openai_api)
- [DeepInfra Model Page](https://deepinfra.com/sentence-transformers/all-MiniLM-L6-v2)

---

### 2. OpenRouter

| Attribute | Value |
|-----------|-------|
| **Endpoint** | `https://openrouter.ai/api/v1/embeddings` |
| **Model** | `sentence-transformers/all-minilm-l6-v2` |
| **Dimensions** | 384 |
| **Pricing** | $0.005 / 1M input tokens (passes through DeepInfra) |
| **Auth** | Bearer token |
| **Batch support** | Yes |
| **API format** | OpenAI-compatible |
| **Backend** | DeepInfra (single provider for this model) |
| **Error codes** | 400, 401, 402, 404, 429, 529 |

**Not recommended:** Routes to DeepInfra anyway. Adds latency (extra hop) and a dependency (OpenRouter availability) for zero benefit on this model. Use OpenRouter only if you need multi-model routing.

**Sources:**
- [OpenRouter all-MiniLM-L6-v2](https://openrouter.ai/sentence-transformers/all-minilm-l6-v2)
- [OpenRouter Embeddings API](https://openrouter.ai/docs/api/reference/embeddings)

---

### 3. Hugging Face Inference Providers

| Attribute | Value |
|-----------|-------|
| **Endpoint** | `https://router.huggingface.co/v1/embeddings` |
| **Model** | `sentence-transformers/all-MiniLM-L6-v2` |
| **Dimensions** | 384 |
| **Pricing** | Pass-through (no HF markup) |
| **Free tier** | $0.10/month (free account), $2.00/month (PRO at $9/mo) |
| **API format** | OpenAI-compatible |
| **Backend** | hf-inference (CPU-based) |

**Not recommended for production:** Free tier ($0.10/month credits) may cover current volume but has undocumented rate limits and unclear reliability guarantees. DeepInfra at $0.001/month is more predictable.

**Sources:**
- [HF Pricing and Billing](https://huggingface.co/docs/inference-providers/pricing)

---

### 4. Jina AI

| Attribute | Value |
|-----------|-------|
| **Endpoint** | `https://api.jina.ai/v1/embeddings` |
| **Model** | `jina-embeddings-v3` (NOT all-MiniLM-L6-v2) |
| **Dimensions** | Configurable 256–2048 via Matryoshka (default 1024) |
| **Free tier** | 10M tokens on signup; 100 RPM, 100K TPM |
| **API format** | OpenAI-compatible |

**Not viable:** Different model produces incompatible vectors. Would require full re-embed of all messages. Generous free tier (10M tokens) is attractive but the migration cost is not worth it.

**Sources:**
- [Jina Embeddings](https://jina.ai/embeddings/)

---

### 5. Local Bumblebee (Current — Disabled)

| Attribute | Value |
|-----------|-------|
| **Model** | all-MiniLM-L6-v2 (via Bumblebee + EXLA) |
| **Dimensions** | 384 |
| **Pricing** | $0 (hardware cost only) |
| **Memory** | ~1-2GB per container (peak during JIT) |
| **Status** | Disabled (v0.5.43) — crashes 20GB LXC |

**Long-term goal:** Re-enable after infrastructure hardening (see `docs/research/rca-action-item-research-2026-03.md`). Keep as offline/privacy fallback.

---

## Cost Analysis

### Estimated Slackex Volume

| Metric | Estimate |
|--------|----------|
| Average message length | ~30 words ≈ ~40 tokens |
| Messages per day (current) | ~50–200 |
| Tokens per day | ~2,000–8,000 |
| Tokens per month | ~60K–240K |
| Backfill (existing messages) | ~10K messages ≈ ~400K tokens |

### Monthly Cost

| Provider | Rate | Monthly (240K tokens) | Backfill (400K tokens) |
|----------|------|-----------------------|------------------------|
| **DeepInfra** | $0.005/M | **$0.0012** | **$0.002** |
| **OpenRouter** | $0.005/M | **$0.0012** | **$0.002** |
| **HF (free)** | $0.10 credit | **$0.00** | **$0.00** |
| **OpenAI** | $0.020/M | **$0.0048** | **$0.008** |

All options are effectively free at this volume. Even at 100x scale: $0.12/month on DeepInfra.

---

## Integration Plan

### Step 1: Make `OpenAIClient` Configurable

The current `OpenAIClient` hardcodes `@api_url`, `@model`, and `@dimensions`. Extract these to application config:

```elixir
# lib/slackex/embeddings/openai_client.ex
defmodule Slackex.Embeddings.OpenAIClient do
  @behaviour Slackex.Embeddings.EmbeddingClient

  @max_batch_size 100
  @receive_timeout_ms 30_000

  # --- Configurable attributes ---
  defp api_url, do: config(:api_url, "https://api.openai.com/v1/embeddings")
  defp model, do: config(:model, "text-embedding-3-small")
  defp api_key, do: config(:api_key) || Application.get_env(:slackex, :openai_api_key)

  @impl true
  def dimensions, do: config(:dimensions, 1536)

  # generate/1, generate_batch/1 unchanged except:
  #   @api_url -> api_url()
  #   @model -> model()

  defp config(key, default \\ nil) do
    Application.get_env(:slackex, :openai_embedding, %{})
    |> Map.get(key, default)
  end
end
```

### Step 2: Production Config

```elixir
# config/prod.exs
config :slackex, :embedding_client, Slackex.Embeddings.OpenAIClient
```

```elixir
# config/runtime.exs (add to existing)
if embedding_api_key = System.get_env("EMBEDDING_API_KEY") do
  config :slackex, :openai_embedding, %{
    api_url: System.get_env("EMBEDDING_API_URL", "https://api.deepinfra.com/v1/openai/embeddings"),
    model: System.get_env("EMBEDDING_MODEL", "sentence-transformers/all-MiniLM-L6-v2"),
    dimensions: String.to_integer(System.get_env("EMBEDDING_DIMENSIONS", "384")),
    api_key: embedding_api_key
  }
end
```

### Step 3: Docker Compose

```yaml
# docker-compose.prod.yml
x-app: &app-defaults
  environment:
    EMBEDDING_API_KEY: "${EMBEDDING_API_KEY}"
    # EMBEDDING_API_URL and EMBEDDING_MODEL use defaults (DeepInfra + all-MiniLM-L6-v2)
```

### Step 4: Deploy and Backfill

1. Get DeepInfra API key from https://deepinfra.com/dash/api_keys
2. Set `EMBEDDING_API_KEY` on the Docker host
3. Deploy
4. Run backfill: `docker compose exec -T app1 bin/slackex eval "Slackex.Release.backfill_embeddings()" < /dev/null`
5. Enable `:message_search` feature flag

### Migration Safety

**No database migration required.** DeepInfra serves the exact same all-MiniLM-L6-v2 model, producing identical 384-dimensional vectors. Existing embeddings remain valid.

**Verification:** After switching, embed a known test string via both BumblebeeClient (dev) and the API. Cosine similarity should be >0.99.

---

## What This Eliminates

| RCA Problem | Status with DeepInfra |
|-------------|----------------------|
| EXLA JIT memory spike | **Eliminated** — no EXLA in production |
| EmbeddingServing crash-loop | **Eliminated** — no local serving process |
| Supervisor cascade risk | **Eliminated** — no ML supervisor needed |
| GPU access on server | **Eliminated** — no EXLA NIF loaded |
| LXC memory pressure | **Eliminated** — no model in memory |
| Two containers loading model | **Eliminated** — stateless HTTP calls |
| CI model provisioning | **Eliminated** — no model caching needed |

---

## Risk Assessment

| Risk | Severity | Mitigation |
|------|----------|------------|
| Provider downtime | Medium | Oban workers return `{:error, ...}` and retry with backoff. Search degrades to text-only. |
| Network latency | Low | ~100-200ms vs ~50ms local. Embeddings are async Oban jobs, not in request path. |
| API key compromise | Medium | Env var only. Never committed. Rotatable via DeepInfra dashboard. |
| Model deprecation | Very Low | Most popular embedding model. Multiple providers serve it. Config change to switch. |
| Data privacy | Low-Medium | Message `search_content` sent to DeepInfra. Policy: no training, no retention. |
| Cost at scale | Very Low | $0.12/month at 100x current volume. |

### Privacy Note

`search_content` plaintext (used for FTS + embedding) is sent to DeepInfra. Messages are encrypted at rest (Cloak) but the search companion column is plaintext by design. DeepInfra's policy states no training on inputs and no prompt retention. If privacy becomes a hard constraint, re-enable local Bumblebee after infrastructure hardening.

---

## Decision

| Criterion | Weight | DeepInfra | OpenRouter | HF Inference | Bumblebee |
|-----------|--------|-----------|------------|--------------|-----------|
| Cost | High | ~$0/mo | ~$0/mo | $0 (free tier) | $0 |
| No external dependency | High | Requires internet | Requires internet | Requires internet | Full offline |
| Elixir ecosystem fit | Medium | Existing client | Existing client | Existing client | Native Nx |
| Embedding quality | Medium | Same model | Same model | Same model | Same model |
| Latency | Medium | ~150ms | ~200ms | ~200ms | ~50ms |
| Operational complexity | Medium | **None** (config change) | **None** | **None** | **High** (EXLA/LXC) |
| Production readiness | High | **Now** | **Now** | Uncertain | **Blocked** (OOM) |

**Winner: DeepInfra direct.** Same model, same vectors, no migration, no new code, negligible cost, eliminates all RCA root causes related to local ML. Can be live in production within a single deploy.

---

## Sources

- [DeepInfra all-MiniLM-L6-v2 API](https://deepinfra.com/sentence-transformers/all-MiniLM-L6-v2/api)
- [DeepInfra OpenAI API Compatibility](https://deepinfra.com/docs/openai_api)
- [DeepInfra Model Page](https://deepinfra.com/sentence-transformers/all-MiniLM-L6-v2)
- [OpenRouter all-MiniLM-L6-v2](https://openrouter.ai/sentence-transformers/all-minilm-l6-v2)
- [OpenRouter Embeddings API](https://openrouter.ai/docs/api/reference/embeddings)
- [HF Inference Pricing](https://huggingface.co/docs/inference-providers/pricing)
- [Jina Embeddings](https://jina.ai/embeddings/)
- [HuggingFace all-MiniLM-L6-v2](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2)
- [LangChain DeepInfra Embeddings](https://docs.langchain.com/oss/javascript/integrations/text_embedding/deepinfra)
- [BentoML: Open-Source Embedding Models 2026](https://www.bentoml.com/blog/a-guide-to-open-source-embedding-models)
- [Elephas: Best Embedding Models 2026](https://elephas.app/blog/best-embedding-models)
