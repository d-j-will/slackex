# Bumblebee Embedding Provider: Feature Evolution

**Date:** 2026-03-04
**Status:** Complete
**Project ID:** bumblebee-embedding-provider
**Test Count:** 964 (0 failures, 8 excluded bumblebee integration)
**Duration:** ~44 minutes (01:18 - 02:11 UTC on 2026-03-04)

## Summary

Replaced the external OpenAI embedding dependency with a local Bumblebee-powered embedding provider using the `sentence-transformers/all-MiniLM-L6-v2` model. The feature delivers zero-cost, zero-latency (no network round-trip) embedding inference running entirely within the BEAM, eliminating the OpenAI API dependency for the Intelligence & Search feature (Phase 4). The embedding dimension was migrated from 1536 (OpenAI text-embedding-3-small) to 384 (MiniLM-L6-v2), and the system was configured so that StubClient remains the default in dev/test while BumblebeeClient activates only in production.

## Motivation

- **Zero operational cost.** OpenAI text-embedding-3-small charges per token. For a self-hosted messaging app, embedding every message creates unbounded API cost proportional to message volume.
- **No external dependency.** Bumblebee runs inference locally on CPU via EXLA. No API keys, no network calls, no rate limits, no vendor lock-in.
- **Native Elixir.** Bumblebee and Nx are first-class Elixir libraries with direct OTP integration. The model runs as an Nx.Serving GenServer inside the existing supervision tree -- no sidecar processes, no Python runtime, no gRPC bridges.
- **Privacy.** Message content never leaves the server for embedding generation. Important for a messaging application handling private conversations.

## Architecture Decisions

### Bumblebee + all-MiniLM-L6-v2 over alternatives

Three alternatives were evaluated (documented in `docs/research/embedding-provider-evaluation.md`):

1. **OpenAI text-embedding-3-small (1536 dims):** Best quality but per-token cost scales with message volume. Requires network calls and API key management. Kept as inactive fallback at 1536 dimensions.
2. **Ollama with nomic-embed-text:** Local inference but requires a separate Ollama server process, adding operational complexity. Remains a fallback option if CPU inference latency proves unacceptable.
3. **Bumblebee with all-MiniLM-L6-v2 (384 dims):** Zero cost, native Elixir, ~80MB model download on first startup, good quality for sentence similarity tasks. Selected as the production default.

The decision prioritized: free > local/self-hosted > Nx/Bumblebee > API providers.

### Nx.Serving GenServer over Horde distributed serving

EmbeddingServing runs as a simple per-node GenServer, not a Horde-distributed process. Embedding inference is a local CPU operation with no shared state between nodes. Each cluster node loads the model independently into BEAM memory. This avoids the complexity of distributed process management for a workload that has no distribution requirement.

### StubClient as global default, BumblebeeClient only in prod

BumblebeeClient is configured only in `config/prod.exs`. The global default in `config/config.exs` remains StubClient. This prevents EXLA compilation overhead from affecting developer machines during `mix test` and `iex -S mix` in development. Developers who want to test real inference opt in explicitly via `MIX_ENV=prod`.

### Conditional supervision tree start

EmbeddingServing is added to the supervision tree only when the configured embedding client is BumblebeeClient. This prevents model loading (and the associated ~200-400MB memory allocation) in dev/test environments where StubClient is active. The conditional logic is extracted into a testable function in `application.ex`.

### vector(384) migration with precondition check

The migration from vector(1536) to vector(384) is safe because: (1) the `:message_search` feature flag is OFF, meaning no embeddings have been generated in production, and (2) the `message_embeddings` table has zero rows. The migration drops the existing HNSW index, alters the column dimension, and recreates the index. It is fully reversible via `mix ecto.rollback`.

## Implementation Phases

### Phase 01: Foundation -- Dependencies, Dimension Migration, Stub Alignment (Steps 01-01 through 01-03)

| Commit | Step | Description |
|--------|------|-------------|
| `5fc8a31` | 01-01 | Add bumblebee ~> 0.6.0 and exla >= 0.0.0 to mix.exs; configure EXLA.Backend default, Nx.BinaryBackend in test |
| `1936535` | 01-02 | Migrate message_embeddings from vector(1536) to vector(384); drop and recreate HNSW index |
| `0a35305` | 01-03 | Align StubClient and FailingClient to 384 dims; keep OpenAIClient at 1536; make basis_vector dynamic via EmbeddingClient.dimensions() |

### Phase 02: Core Implementation -- EmbeddingServing and BumblebeeClient (Steps 02-01 through 02-03)

| Commit | Step | Description |
|--------|------|-------------|
| `98ad4ab` | 02-01 | Create EmbeddingServing Nx.Serving GenServer; loads all-MiniLM-L6-v2 with mean pooling and L2 normalization; BUMBLEBEE_CACHE_DIR for model cache; Docker volume for persistence |
| `d5ad28b` | 02-02 | Create BumblebeeClient implementing EmbeddingClient behaviour; delegates to EmbeddingServing; returns 384 from dimensions/0; handles serving-not-started errors |
| `740aa35` | 02-03 | Conditional EmbeddingServing start in supervision tree when client is BumblebeeClient; placed before Oban; boundary exports updated |

### Phase 03: Configuration Switch and Integration Testing (Steps 03-01 through 03-02)

| Commit | Step | Description |
|--------|------|-------------|
| `ad2f216` | 03-01 | Set BumblebeeClient as prod default in prod.exs; keep StubClient as global default in config.exs |
| `a839974` | 03-02 | BumblebeeClient integration tests tagged @moduletag :bumblebee; verifies 384-dim output, L2 normalization, cosine similarity ordering; excluded from default mix test and CI |

### Quality Passes

| Commit | Description |
|--------|-------------|
| `8aa15c6` | RPP L1-L4 refactoring applied to bumblebee feature files |
| `bb840d1` | Document both error types in BumblebeeClient moduledoc |

## Key Modules

### New Production Files

- `lib/slackex/embeddings/embedding_serving.ex` -- Nx.Serving GenServer for model loading and inference. Loads sentence-transformers/all-MiniLM-L6-v2 with `output_pool: :mean_pooling` and `embedding_processor: :l2_norm`. Compile options: batch_size 64, sequence_length 512. Model repo configurable via application config. BUMBLEBEE_CACHE_DIR controls HuggingFace Hub cache location.
- `lib/slackex/embeddings/bumblebee_client.ex` -- EmbeddingClient behaviour implementation. Delegates generate/1 and generate_batch/1 to EmbeddingServing via Nx.Serving.batched_run. Returns 384 from dimensions/0. Returns `{:error, :serving_not_started}` when EmbeddingServing is not running and `{:error, reason}` for inference failures.

### New Test Files

- `test/slackex/embeddings/bumblebee_client_test.exs` -- Unit tests with mocked serving process; verifies behaviour contract without model download
- `test/slackex/embeddings/bumblebee_client_integration_test.exs` -- Integration tests tagged :bumblebee; verifies real model inference, L2 normalization, cosine similarity ordering
- `test/slackex/embeddings/embedding_serving_test.exs` -- Unit tests for serving configuration and startup logic

### Modified Production Files

- `mix.exs` -- Added {:bumblebee, "~> 0.6.0"} and {:exla, ">= 0.0.0"} dependencies
- `config/config.exs` -- Set Nx default backend to EXLA.Backend
- `config/test.exs` -- Override Nx backend to Nx.BinaryBackend for fast CI
- `config/prod.exs` -- Set BumblebeeClient as embedding provider
- `lib/slackex/application.ex` -- Conditional EmbeddingServing start in supervision tree
- `lib/slackex/embeddings/embeddings.ex` -- Added BumblebeeClient and EmbeddingServing to boundary exports
- `lib/slackex/embeddings/stub_client.ex` -- Updated @dimensions to 384
- `docker-compose.prod.yml` -- Added bumblebee_models named volume for model cache persistence

### Modified Test Files

- `test/support/failing_client.ex` -- Updated @dimensions to 384
- `test/support/embedding_helpers.ex` -- Made basis_vector dynamic via EmbeddingClient.dimensions()
- `test/test_helper.exs` -- Added ExUnit.configure exclude: [:bumblebee]
- `test/slackex/embeddings/stub_client_test.exs` -- Updated dimension assertions to 384
- `test/slackex/embeddings/embedding_client_test.exs` -- Updated dimension assertions to 384
- `test/slackex/embeddings/message_embedding_test.exs` -- Updated vector dimensions to 384
- `test/slackex/embeddings/embedding_worker_test.exs` -- Updated vector dimensions to 384

### Migration

- `priv/repo/migrations/<timestamp>_resize_embeddings_to_384.exs` -- Drop HNSW index, alter embedding column from vector(1536) to vector(384), recreate HNSW index; fully reversible

## Quality Metrics

### Test Coverage

- **Starting test count:** 946
- **New tests added:** 18
- **Final test count:** 964
- **Failures:** 0
- **Excluded:** 8 (tagged :bumblebee, require model download)

### TDD Execution

All 8 steps followed 5-phase TDD cycles (PREPARE, RED_ACCEPTANCE, RED_UNIT, GREEN, COMMIT). Every phase across all steps reached PASS status. The execution log records 40 events across all steps.

RED_ACCEPTANCE was skipped (with justification) for all 8 steps:
- **01-01, 03-01:** Config-only steps with no testable logic
- **01-02:** Migration verified via mix ecto.migrate/rollback
- **01-03:** Config alignment step with no new acceptance-level behavior
- **02-01:** EmbeddingServing requires model download; model-dependent tests tagged :bumblebee and excluded from CI
- **02-02:** Unit-level module, no acceptance test needed
- **02-03:** Supervision tree wiring tested at unit level via extracted function
- **03-02:** This step IS the integration test -- no higher-level acceptance test exists

RED_UNIT was skipped for 3 steps:
- **01-01:** Config-only step with no testable logic
- **01-02:** Migration verified via mix ecto.migrate/rollback
- **03-01, 03-02 (RED_UNIT for 03-01):** Config-only step, verification is existing tests pass unchanged

### Roadmap Validation

Roadmap was validated by `nw-software-crafter-reviewer` in 3 iterations (approved at iteration 3). Defects addressed during validation:
- **D1:** Migration safety -- precondition documented (feature flag OFF, table empty)
- **D2:** Model caching -- BUMBLEBEE_CACHE_DIR + Docker named volume for persistence
- **D3:** Dev friction -- StubClient as global default, BumblebeeClient only in prod.exs
- **D4:** Unit tests -- BumblebeeClient unit tests with mocked serving (step 02-02)
- **SPEC-D3:** OpenAI kept at 1536 as inactive provider

### Mutation Testing

Skipped -- no Elixir mutation testing framework available. Compensating controls: BumblebeeClient behaviour contract tested via mocked serving, EmbeddingServing configuration tested via extracted functions, dimension alignment verified across StubClient/FailingClient/test helpers, integration tests verify real model inference output (384-dim, L2-normalized, cosine similarity ordering).

## Configuration Strategy

| Environment | Embedding Client | Nx Backend | EmbeddingServing |
|-------------|-----------------|------------|------------------|
| dev | StubClient | EXLA.Backend | Not started |
| test | StubClient | Nx.BinaryBackend | Not started |
| prod | BumblebeeClient | EXLA.Backend | Started (before Oban) |

## Deployment Notes

- **First startup latency.** The first production startup downloads ~80MB of model weights from HuggingFace Hub. Subsequent startups load from the Docker volume cache. Plan for additional startup time on first deploy.
- **Memory footprint.** The model loads into BEAM memory as Nx tensors, consuming approximately 200-400MB. Monitor node memory after deploy.
- **BUMBLEBEE_CACHE_DIR.** Set this environment variable to a path inside the `bumblebee_models` Docker volume (e.g., `/app/bumblebee_models`). This persists downloaded models across container restarts.
- **Model loading is per-node.** Each cluster node loads the model independently. With 2 app containers, expect ~400-800MB total additional memory across the cluster.
- **No feature flag change needed.** The `:message_search` feature flag remains OFF. This change only swaps the embedding provider -- search activation is a separate PO decision.

## Commit History (oldest to newest)

| Commit | Message |
|--------|---------|
| `5fc8a31` | feat(deps): add Bumblebee and EXLA for local embedding inference |
| `1936535` | feat(embeddings): migrate message_embeddings from vector(1536) to vector(384) |
| `0a35305` | fix(embeddings): revert OpenAIClient to 1536 dims and make basis_vector dynamic |
| `98ad4ab` | feat(embeddings): add EmbeddingServing module with Bumblebee model loading |
| `d5ad28b` | feat(embeddings): add BumblebeeClient implementing EmbeddingClient behaviour |
| `740aa35` | feat(embeddings): conditionally start EmbeddingServing in supervision tree |
| `ad2f216` | feat(embeddings): set BumblebeeClient as prod default embedding provider |
| `a839974` | test(embeddings): add BumblebeeClient integration tests for real model inference |
| `8aa15c6` | refactor(embeddings): apply L1-L4 refactoring to bumblebee feature files |
| `bb840d1` | docs(embeddings): document both error types in BumblebeeClient moduledoc |

## Future Considerations

1. **Enable :message_search feature flag** after verifying inference performance in production. Monitor p99 latency of `EmbeddingServing` inference to confirm sub-second response times under typical message lengths.
2. **Ollama with nomic-embed-text as fallback.** If CPU inference latency on the production host is unacceptable (e.g., >2s per batch), Ollama provides GPU-accelerated local inference without API costs. Would require a new OllamaClient implementation.
3. **OpenAIClient kept at 1536 dimensions as inactive fallback.** Reactivating OpenAI would require a reverse migration from vector(384) back to vector(1536) and re-embedding all messages. This is intentionally expensive to prevent accidental provider switches.
4. **Batch size tuning.** The default compile option of batch_size 64 may need adjustment based on production CPU characteristics. Monitor queue depth and processing latency in Oban's :embeddings queue.
5. **Model upgrades.** The model repo is configurable via application config. Upgrading to a larger model (e.g., all-MiniLM-L12-v2) requires only a config change and dimension migration if the output dimension differs.

## Lessons Learned

1. **Conditional supervision tree entries keep dev/test environments lean.** Adding EmbeddingServing unconditionally would force model download and ~200-400MB memory allocation in every development session, even though dev uses StubClient. Extracting the conditional logic into a testable function (`embedding_serving_children/0`) keeps the supervision tree clean and the logic verifiable without integration-level tests.

2. **Dimension migration is safe when guarded by feature flags.** The vector(1536) to vector(384) migration would be dangerous on a table with existing data -- all embeddings would need regeneration. Because the `:message_search` feature flag kept the embedding pipeline disabled, the `message_embeddings` table had zero rows, making the ALTER COLUMN a metadata-only operation. Feature flags create safe windows for schema changes that would otherwise require complex data migration.

3. **Nx.BinaryBackend in test prevents EXLA compilation overhead in CI.** EXLA compiles XLA for the host platform on first use, adding significant time to CI runs. Overriding to Nx.BinaryBackend in `config/test.exs` ensures tests use pure-Elixir tensor operations. The tradeoff is that test-time tensor operations are slower per-operation, but since tests use StubClient (no real inference), this has no practical impact.

4. **Integration tests for ML models should be opt-in, not default.** Bumblebee integration tests require downloading the model (~80MB) and running real inference, which is slow and requires network access. Tagging with `@moduletag :bumblebee` and excluding via `ExUnit.configure(exclude: [:bumblebee])` keeps the default `mix test` fast while allowing on-demand verification with `mix test --include bumblebee`.
