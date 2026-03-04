# RCA: EmbeddingServing Crash-Loop on Deploy v0.5.25 & v0.5.26

**Date:** 2026-03-04
**Severity:** P0 — full production outage, app unresponsive
**Duration:** ~29 minutes (03:15 – 03:44 UTC)
**Trigger:** Deploy of v0.5.25 (Bumblebee embedding provider feature)

## Timeline

1. v0.5.25 tagged and pushed — CI builds image, deploys to server
2. Migration runs successfully (vector 1536 → 384)
3. Containers created and started, 15-second health check wait
4. Both app1 and app2 show "Up Less than a second" — crash-looping
5. Smoke test fails: "FAIL: app1 health check unreachable"
6. User reports: "WE killed the Live service again"
7. Root causes identified: GenServer name collision + blocking init
8. v0.5.26 deployed with name fix + handle_continue — still crash-looping
9. Second root cause identified: model not pre-downloaded, handle_continue crashes
10. v0.5.27 deployed: reverted to StubClient + resilient handle_continue
11. v0.5.27 deploys successfully, all smoke tests pass, production restored

## Root Causes

### 1. GenServer name collision (v0.5.25)

`EmbeddingServing` registered itself as `Slackex.Embeddings.EmbeddingServing` via `GenServer.start_link(..., name: __MODULE__)`. Inside `init/1`, it called `Nx.Serving.start_link(name: __MODULE__)` — attempting to register a second process under the same atom. Result: `{:error, {:already_started, pid}}`, crashing the GenServer.

### 2. Blocking init (v0.5.25)

Model download + EXLA compilation ran synchronously in `init/1`. GenServer's default 5-second timeout killed the process before loading completed. The supervisor restarted it, creating an infinite crash-loop that prevented the entire application from booting.

### 3. Missing model on server (v0.5.26)

The v0.5.26 fix moved heavy work to `handle_continue` and separated process names. But `Bumblebee.load_model({:hf, "sentence-transformers/all-MiniLM-L6-v2"})` crashed because the model wasn't pre-downloaded in the `bumblebee_models` Docker volume. The crash propagated through `handle_continue` via pattern-match (`{:ok, model_info} = ...`), killing the GenServer and triggering the same supervisor restart loop.

## Why Pre-Deploy Didn't Catch It

The pre-deploy script runs 7 checks — all passed for v0.5.25. None exercise `EmbeddingServing` startup because:

1. **`mix test`** uses `StubClient` (configured in `config/test.exs`), so `maybe_embedding_serving/1` never adds `EmbeddingServing` to the supervision tree
2. **Docker image build** verifies compilation, not runtime behavior
3. **Release boot check** runs `bin/slackex eval "IO.puts(:ok)"` — evaluates a single expression without starting the full supervision tree
4. **No integration test** starts the app with prod-like config

## Contributing Factors

### 1. Config divergence between test and prod

`prod.exs` set `:embedding_client` to `BumblebeeClient`, while `test.exs` kept `StubClient`. The code path that crashes in prod was never exercised in CI. This is the same class of bug as the clustering RCA (2026-03-03): features that only activate in prod config have zero test coverage.

### 2. Crash-on-failure pattern matching in GenServer callbacks

`handle_continue` used `{:ok, model_info} = Bumblebee.load_model(hf_spec)` — a pattern that crashes on any non-ok result. GenServers that depend on external resources (network downloads, GPU compilation) must handle failure gracefully or risk crash-loops under supervision.

### 3. No model provisioning step

The Docker Compose config created the `bumblebee_models` volume and set `BUMBLEBEE_CACHE_DIR`, but no step existed to actually download the model into the volume before the app tried to load it.

### 4. Supervision tree blast radius

`EmbeddingServing` is a direct child of the application supervisor. Its repeated crashes hit the max restart intensity, taking down the entire app — not just the embedding subsystem. A dedicated supervisor would have contained the blast radius.

## Fixes Applied

| Fix | Version | Description |
|-----|---------|-------------|
| Name separation | v0.5.26 | `@serving_name :"#{__MODULE__}.Nx"` for Nx.Serving process |
| Non-blocking init | v0.5.26 | `handle_continue(:load_model, _)` defers heavy work |
| Resilient loading | v0.5.27 | `load_and_start_serving/2` catches errors, enters degraded state |
| Config revert | v0.5.27 | `StubClient` in prod until model is provisioned |
| Model provisioning script | v0.5.27 | `scripts/provision-bumblebee-model` to pre-cache model in Docker volume |

## Action Items

| Priority | Action | Status |
|----------|--------|--------|
| P0 | Restore production | Done (v0.5.27) |
| P1 | Pre-cache model via provisioning script before switching to BumblebeeClient | TODO |
| P1 | Add release boot integration test with prod-like config | TODO |
| P2 | Move EmbeddingServing under a dedicated supervisor to contain blast radius | TODO |
| P2 | Add pre-deploy check that validates supervision tree startup | TODO |
| P3 | Document Bumblebee activation checklist | TODO |

## Lessons

1. **If CI never exercises a code path, that code path will break in prod.** The StubClient/BumblebeeClient config split meant the real embedding path had zero CI coverage. This is the second time config divergence caused a prod outage (see clustering RCA).
2. **GenServers that depend on external resources must fail gracefully.** Pattern-match crashes in `init`/`handle_continue` become crash-loops under supervision. Use rescue/catch and enter a degraded state.
3. **Pre-deploy boot checks should start the full supervision tree**, not just evaluate a one-liner. The release boot check gave false confidence.
4. **Infrastructure must be provisioned before code that depends on it.** The Docker volume existed but was empty. A provisioning step is a deployment prerequisite, not an afterthought.
