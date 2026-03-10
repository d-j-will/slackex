# Bumblebee Proof-of-Concept Research

**Date**: 2026-03-04
**Status**: Complete
**Context**: Implementation guide for replacing `StubClient` with Bumblebee + all-MiniLM-L6-v2 as the embedding provider. This is the primary recommendation from the [embedding provider evaluation](./embedding-provider-research-2026-03.md).

## Executive Summary

Bumblebee integration into Slackex is straightforward. The existing `EmbeddingClient` behaviour makes the swap trivial — implement 3 callbacks, add an `Nx.Serving` to the supervision tree, and migrate the vector column from 1536→384 dimensions. The migration is risk-free since `:message_search` is flag-disabled and the `message_embeddings` table is empty in production.

**Estimated scope**: 5 new/modified files, 1 migration, ~150 lines of new code.

---

## 1. Dependencies

Add to `mix.exs` deps:

```elixir
# Embedding inference (Bumblebee + EXLA)
{:bumblebee, "~> 0.6.0"},
{:exla, ">= 0.0.0"},
```

Current Bumblebee version: **v0.6.3** (latest on Hex as of 2026-03).

**EXLA** is the recommended backend — it compiles Nx computations to optimized CPU (or GPU) code via Google XLA. It's an optional dep for Bumblebee but critical for production inference speed.

**Note**: EXLA downloads a pre-built XLA binary on first compile (~200MB). For Docker builds, this happens during `mix deps.compile` and is cached in the Docker layer. No GPU required — CPU inference is sufficient for all-MiniLM-L6-v2.

Sources: [Bumblebee README](https://github.com/elixir-nx/bumblebee/blob/main/README.md), [Bumblebee v0.6.3 HexDocs](https://hexdocs.pm/bumblebee/Bumblebee.html)

---

## 2. Configuration

### config/config.exs

```elixir
# Nx backend — use EXLA for JIT-compiled inference
config :nx, default_backend: EXLA.Backend

# Embedding client — Bumblebee for all environments
config :slackex, :embedding_client, Slackex.Embeddings.BumblebeeClient
```

### config/test.exs

Keep `StubClient` in test to avoid model downloads during CI:

```elixir
config :slackex, :embedding_client, Slackex.Embeddings.StubClient
```

### Environment variables

- `BUMBLEBEE_CACHE_DIR` (optional): Override model cache location. Default uses Bumblebee's built-in cache dir. Useful for Docker volume mounts to persist models across container recreations.
- `XLA_TARGET` (optional): Set to `cuda12` for GPU. Omit for CPU (default).

Sources: [Bumblebee HexDocs](https://hexdocs.pm/bumblebee/Bumblebee.html), [EXLA GitHub](https://github.com/elixir-nx/xla)

---

## 3. Implementation

### 3a. Nx.Serving module

New file: `lib/slackex/embeddings/embedding_serving.ex`

```elixir
defmodule Slackex.Embeddings.EmbeddingServing do
  @moduledoc """
  Supervised Nx.Serving that loads the sentence-transformers model
  on startup and handles batched embedding requests.
  """

  @model_id "sentence-transformers/all-MiniLM-L6-v2"

  def child_spec(_opts) do
    model_id = @model_id

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [model_id]},
      type: :worker
    }
  end

  def start_link(model_id) do
    {:ok, model_info} = Bumblebee.load_model({:hf, model_id})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, model_id})

    serving =
      Bumblebee.Text.text_embedding(model_info, tokenizer,
        output_attribute: :hidden_state,
        output_pool: :mean_pooling,
        embedding_processor: :l2_norm,
        compile: [batch_size: 64, sequence_length: 512],
        defn_options: [compiler: EXLA]
      )

    Nx.Serving.start_link(
      serving: serving,
      name: __MODULE__,
      batch_size: 64,
      batch_timeout: 100
    )
  end
end
```

**Key configuration choices:**

| Option | Value | Rationale |
|--------|-------|-----------|
| `output_attribute` | `:hidden_state` | Required to match sentence-transformers output |
| `output_pool` | `:mean_pooling` | Standard pooling for sentence embeddings |
| `embedding_processor` | `:l2_norm` | Normalizes vectors for cosine similarity |
| `compile: batch_size` | 64 | Pre-compiles for batches up to 64 (covers Oban worker batches) |
| `compile: sequence_length` | 512 | MiniLM max is 512 tokens; pre-compile avoids recompilation |
| `batch_timeout` | 100ms | Nx.Serving waits up to 100ms to fill a batch before executing |

**Critical gotcha**: Bumblebee defaults for `output_attribute`, `output_pool`, and `embedding_processor` do NOT match the Python `sentence-transformers` library. All three options must be set explicitly or embeddings will be incorrect.

Sources: [TIL: sentence-transformers embeddings from Bumblebee](https://samrat.me/til-creating-sentence-transformers-embeddings-from-bumblebee/), [pgvector-elixir Bumblebee example](https://github.com/pgvector/pgvector-elixir/blob/master/examples/bumblebee/example.exs), [Nx.Serving HexDocs](https://hexdocs.pm/nx/Nx.Serving.html)

### 3b. BumblebeeClient implementation

New file: `lib/slackex/embeddings/bumblebee_client.ex`

```elixir
defmodule Slackex.Embeddings.BumblebeeClient do
  @moduledoc """
  Embedding client backed by Bumblebee running all-MiniLM-L6-v2
  in-process via Nx.Serving.

  Generates 384-dimensional L2-normalized embeddings. The serving
  is started by EmbeddingServing in the supervision tree and handles
  automatic batching of concurrent requests.
  """

  @behaviour Slackex.Embeddings.EmbeddingClient

  @dimensions 384

  @impl true
  @spec generate(String.t()) :: {:ok, [float()]} | {:error, term()}
  def generate(text) do
    case generate_batch([text]) do
      {:ok, [vector]} -> {:ok, vector}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec generate_batch([String.t()]) :: {:ok, [[float()]]} | {:error, term()}
  def generate_batch(texts) do
    results = Nx.Serving.batched_run(Slackex.Embeddings.EmbeddingServing, texts)

    vectors =
      Enum.map(results, fn %{embedding: tensor} ->
        Nx.to_flat_list(tensor)
      end)

    {:ok, vectors}
  rescue
    error -> {:error, {:inference_error, error}}
  end

  @impl true
  @spec dimensions() :: pos_integer()
  def dimensions, do: @dimensions
end
```

**Design notes:**
- Delegates to `Nx.Serving.batched_run/2` which auto-batches concurrent callers
- Converts Nx tensors to flat lists (matching the `[float()]` contract)
- Rescue clause catches EXLA compilation errors or OOM during inference
- The `@dimensions 384` matches all-MiniLM-L6-v2's output size

Sources: [Bumblebee GitHub](https://github.com/elixir-nx/bumblebee), [bitcrowd RAG in Elixir](https://bitcrowd.dev/a-rag-for-elixir-in-elixir/)

### 3c. Supervision tree

Add `EmbeddingServing` to `application.ex`, early in the tree (before PersistenceListener and Oban):

```elixir
children = [
  # ... Repo, ReadRepo, etc.
  Slackex.Embeddings.EmbeddingServing,   # Load model on startup
  # ... Oban, PersistenceListener, Endpoint
]
```

Per Nx.Serving docs: "make sure Nx.Serving comes early in your supervision tree, for example before your web application endpoint or your data processing pipelines."

**Startup behavior**: Model downloads from Hugging Face Hub on first run (~80MB for all-MiniLM-L6-v2), then cached. Subsequent starts load from cache in ~2-3 seconds. EXLA JIT compilation happens on first inference call, adding ~5-10s one-time cost.

**Conditional startup**: Since test uses `StubClient`, the serving should only start when the configured client is `BumblebeeClient`:

```elixir
embedding_children =
  if Application.get_env(:slackex, :embedding_client) == Slackex.Embeddings.BumblebeeClient do
    [Slackex.Embeddings.EmbeddingServing]
  else
    []
  end
```

Source: [Nx.Serving HexDocs](https://hexdocs.pm/nx/Nx.Serving.html)

---

## 4. Migration

### 4a. Vector dimension change

The `message_embeddings` table currently uses `vector(1536)`. Bumblebee's all-MiniLM-L6-v2 produces 384 dimensions.

**Risk**: Zero. The table is empty in production (`:message_search` flag is off). No data to migrate or re-embed.

Migration (via `/new-migration`):

```elixir
defmodule Slackex.Repo.Migrations.ChangeEmbeddingDimensionsTo384 do
  use Ecto.Migration

  def up do
    # Drop existing HNSW index (depends on vector dimension)
    execute "DROP INDEX IF EXISTS idx_embeddings_hnsw"

    # Change vector dimension
    alter table(:message_embeddings) do
      modify :embedding, :"vector(384)"
    end

    # Recreate HNSW index with new dimension
    execute """
    CREATE INDEX idx_embeddings_hnsw
      ON message_embeddings USING hnsw (embedding vector_cosine_ops)
      WITH (m = 16, ef_construction = 64)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS idx_embeddings_hnsw"

    alter table(:message_embeddings) do
      modify :embedding, :"vector(1536)"
    end

    execute """
    CREATE INDEX idx_embeddings_hnsw
      ON message_embeddings USING hnsw (embedding vector_cosine_ops)
      WITH (m = 16, ef_construction = 64)
    """
  end
end
```

### 4b. StubClient dimension update

`StubClient` must also change from `@dimensions 1536` to `@dimensions 384` so tests match the production schema:

```elixir
# In stub_client.ex
@dimensions 384
```

### 4c. MessageEmbedding schema

Check `lib/slackex/embeddings/message_embedding.ex` — if it references a dimension constant, update it to 384.

---

## 5. Docker Considerations

### Dockerfile changes

EXLA needs the XLA binary. Two options:

**Option A: Download at compile time (recommended)**
No Dockerfile changes needed. EXLA downloads the pre-built XLA binary during `mix deps.compile`. Docker layer caching handles this.

**Option B: Pre-download for faster builds**
```dockerfile
# Before mix deps.compile
ENV XLA_TARGET=cpu
RUN mix deps.compile exla
```

### Model caching in production

The model downloads from HF Hub on first start. To avoid this in production:

**Option 1: Bake model into image**
```dockerfile
# After mix release
RUN mix run -e 'Bumblebee.load_model({:hf, "sentence-transformers/all-MiniLM-L6-v2"})'
RUN mix run -e 'Bumblebee.load_tokenizer({:hf, "sentence-transformers/all-MiniLM-L6-v2"})'
```

**Option 2: Volume mount (simpler)**
```yaml
# docker-compose.prod.yml
volumes:
  - bumblebee_cache:/root/.cache/bumblebee
```

Option 2 is simpler and avoids bloating the Docker image. First deploy downloads the model; subsequent container recreations reuse the cache.

### Memory impact

- all-MiniLM-L6-v2 model: ~80MB on disk, ~200-400MB in memory (with Nx tensors)
- EXLA compilation cache: ~50MB
- Total additional memory: **~300-500MB**

Verify the Docker host has sufficient headroom. Current app + Postgres + Redis + Caddy likely uses ~1-2GB. Adding 500MB should be fine on a 4GB+ host.

---

## 6. Testing Strategy

### Unit tests (StubClient, no changes needed)

Existing tests use `StubClient` via config — they continue to work unchanged. StubClient dimensions change to 384 to match the new schema.

### Integration test for BumblebeeClient

New test that verifies the client produces correct output (run only locally, not in CI):

```elixir
# test/slackex/embeddings/bumblebee_client_test.exs
defmodule Slackex.Embeddings.BumblebeeClientTest do
  use ExUnit.Case, async: true

  @moduletag :bumblebee  # Tag to skip in CI

  describe "generate/1" do
    test "returns a 384-dimensional vector" do
      {:ok, vector} = Slackex.Embeddings.BumblebeeClient.generate("hello world")
      assert length(vector) == 384
      assert Enum.all?(vector, &is_float/1)
    end

    test "similar texts produce similar embeddings" do
      {:ok, v1} = Slackex.Embeddings.BumblebeeClient.generate("the cat sat on the mat")
      {:ok, v2} = Slackex.Embeddings.BumblebeeClient.generate("a cat was sitting on a mat")
      {:ok, v3} = Slackex.Embeddings.BumblebeeClient.generate("stock market crash in 2008")

      similarity_12 = cosine_similarity(v1, v2)
      similarity_13 = cosine_similarity(v1, v3)

      # Similar texts should have higher similarity
      assert similarity_12 > similarity_13
      assert similarity_12 > 0.8
    end
  end

  describe "generate_batch/1" do
    test "returns vectors for all inputs" do
      {:ok, vectors} = Slackex.Embeddings.BumblebeeClient.generate_batch(["a", "b", "c"])
      assert length(vectors) == 3
      assert Enum.all?(vectors, fn v -> length(v) == 384 end)
    end
  end

  defp cosine_similarity(a, b) do
    dot = Enum.zip(a, b) |> Enum.map(fn {x, y} -> x * y end) |> Enum.sum()
    # Vectors are L2-normalized, so dot product = cosine similarity
    dot
  end
end
```

Run with: `mix test --only bumblebee` (requires model download, ~30s first run).

### CI considerations

CI should NOT run Bumblebee tests — model download + EXLA compilation would add 2+ minutes and ~500MB to CI. Use `@moduletag :bumblebee` and exclude in CI config:

```elixir
# test/test_helper.exs (or CI mix task)
ExUnit.configure(exclude: [:bumblebee])
```

---

## 7. Implementation Checklist

1. **Add deps** to `mix.exs`: `{:bumblebee, "~> 0.6.0"}`, `{:exla, ">= 0.0.0"}`
2. **Configure EXLA** in `config/config.exs`: `config :nx, default_backend: EXLA.Backend`
3. **Create `EmbeddingServing`** — Nx.Serving GenServer loading all-MiniLM-L6-v2
4. **Create `BumblebeeClient`** — implements `EmbeddingClient` behaviour, delegates to serving
5. **Add to supervision tree** — conditional on configured client
6. **Migration** — `vector(1536)` → `vector(384)`, rebuild HNSW index
7. **Update `StubClient`** — `@dimensions 384`
8. **Update `config.exs`** — default client to `BumblebeeClient`
9. **Update `config/test.exs`** — keep `StubClient` for tests
10. **Add integration test** — tagged `:bumblebee`, excluded from CI
11. **Docker** — add bumblebee cache volume to `docker-compose.prod.yml`
12. **Verify** — `mix test` passes, Bumblebee test passes locally, Docker image builds

---

## 8. Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| CPU inference too slow for batch processing | Low-Medium | Medium | Oban worker already processes async; batch_size=64 with Nx.Serving batching. Benchmark first. |
| Memory pressure on Docker host | Low | High | Monitor with `docker stats`. Model is ~300-500MB. If tight, use Ollama sidecar instead. |
| EXLA compilation errors in Docker | Low | Medium | Use `XLA_TARGET=cpu` explicitly. Test Docker build locally before deploying. |
| Model quality insufficient for message search | Low | Medium | all-MiniLM-L6-v2 is widely used for chat/message search. Test with real messages before enabling flag. |
| First-request latency (JIT compilation) | Certain | Low | ~5-10s on first inference. Mitigate with warmup call in `Application.start/2`. |

---

## 9. Knowledge Gaps (to resolve during implementation)

1. **EXLA in Docker**: Confirm EXLA XLA binary downloads correctly in the multi-stage Dockerfile. May need `RUN mix deps.compile exla` in build stage.
2. **Bumblebee + Nx.Serving.batched_run/2 return format**: Verify the exact return shape. Docs show `%{embedding: tensor}` but format may vary by Bumblebee version.
3. **Warmup strategy**: Should the serving do a dummy inference on startup to trigger JIT compilation? Or accept the first-request latency?
4. **Dialyzer + Bumblebee**: EXLA and Nx may generate dialyzer warnings. May need PLT additions.

---

## Sources

- [Bumblebee v0.6.3 HexDocs](https://hexdocs.pm/bumblebee/Bumblebee.html)
- [Bumblebee GitHub](https://github.com/elixir-nx/bumblebee)
- [Nx.Serving HexDocs](https://hexdocs.pm/nx/Nx.Serving.html)
- [pgvector-elixir Bumblebee Example](https://github.com/pgvector/pgvector-elixir/blob/master/examples/bumblebee/example.exs)
- [TIL: sentence-transformers from Bumblebee](https://samrat.me/til-creating-sentence-transformers-embeddings-from-bumblebee/)
- [DockYard: Semantic Search with Bumblebee](https://dockyard.com/blog/2023/01/11/semantic-search-with-phoenix-axon-bumblebee-and-exfaiss)
- [bitcrowd: RAG for Elixir in Elixir](https://bitcrowd.dev/a-rag-for-elixir-in-elixir/)
- [DEV.to: Semantic Search with Bumblebee](https://dev.to/ndrean/an-example-of-semantic-search-with-elixir-and-bumblebee-h9n)
- [DockYard: Clustering Bumblebee](https://dockyard.com/blog/2024/03/05/elixir-machine-learning-clustering-bumblebee-structured-prompting)
- [HuggingFace: Bumblebee Announcement](https://huggingface.co/blog/elixir-bumblebee)
- [all-MiniLM-L6-v2 on HuggingFace](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2)
