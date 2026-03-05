# RCA: Embedding Failure Cascade Crashes Application, VM & Physical Server (v0.5.36 – v0.5.42)

**Date:** 2026-03-05
**Severity:** P0 — full production outage, application unrecoverable, physical server crashed multiple times
**Duration:** ~8+ hours across multiple outage windows
**Trigger:** v0.5.36 deployed; Oban embedding jobs fired; EmbeddingServing crash-looped; supervisor exhausted restart budget; cascade killed the entire application; EXLA GPU access crashed the physical Proxmox server
**Related incidents:** [2026-03-04 crash-loop](2026-03-04-bumblebee-serving-crash-loop.md), [2026-03-03 clustering](2026-03-03-clustering-deploy-failure.md)

## Impact

- **chat.davewil.dev** completely unreachable across multiple outage windows totaling 8+ hours
- Docker host VM unresponsive — required Proxmox power cycle (multiple times)
- **Physical Proxmox server crashed multiple times** — EXLA GPU access brought down the hypervisor, requiring physical power cycles
- Recovery blocked by cascading infrastructure failures (DNS, GHCR auth, GPU crash)
- **Seven version tags** (v0.5.36 through v0.5.42) required to fully resolve
- **Third production incident in 72 hours**, all from the same embedding subsystem
- **Total downtime: 8+ hours across multiple outage windows**
- User had to physically walk to the server to power-cycle the Proxmox host — twice

## Timeline

| Time (UTC) | Event |
|------------|-------|
| ~20:42 | v0.5.36 tagged (commit `ebc9f71`: pre-commit Credo fix — no embedding changes) |
| ~20:45 | CI deploys v0.5.36 to Docker host |
| ~20:46 | App boots with BumblebeeClient (activated in v0.5.33 via `config/prod.exs`) |
| ~20:47 | User sends message → Oban enqueues embedding job → `EmbeddingWorker.perform/1` fires |
| ~20:47 | EmbeddingServing crashes (EXLA/model failure) |
| ~20:47 | `perform/1` discards error: `_ = generate_and_persist_embeddings(); :ok` |
| ~20:47 | Oban thinks job succeeded — no retry, no visibility |
| ~20:47 | More messages → more jobs → more crashes → Embeddings.Supervisor restart loop |
| ~20:48 | Supervisor hits max_restarts (3/60s) → supervisor dies |
| ~20:48 | Main Slackex.Supervisor restarts Embeddings.Supervisor (default `:permanent`) |
| ~20:48 | Embeddings.Supervisor dies again immediately → cycle repeats |
| ~20:49 | Slackex.Supervisor exhausts its own restart budget → **full application crash** |
| ~20:49 | EXLA memory spike during crash-loop → VM enters memory pressure |
| ~20:50+ | Docker host VM becomes unresponsive (likely OOM) |
| ~00:00 | User notices: "My docker_host is showing no CPU usage since the outage" |
| ~00:05 | Proxmox power cycle of Docker host VM |
| ~00:07 | **Recovery attempt 1**: VM boots but Tailscale DNS (100.100.100.100) not resolving |
| ~00:10 | DNS fix: `tailscale set --accept-dns=false`, manual Google DNS (8.8.8.8) |
| ~00:12 | **Recovery attempt 2**: `docker compose pull` → "denied" (GHCR auth) |
| ~00:15 | Investigation: `~/.docker/config.json` has `ghs_` token (short-lived GitHub App token, expired) |
| ~00:20 | Root cause fix committed: v0.5.37 (error propagation, snooze, `restart: :temporary`, budget 5/300s) |
| ~00:36 | v0.5.37 CI fails — Dialyzer `unmatched_return` on backfill stream |
| ~00:37 | v0.5.38 tagged with Dialyzer fix |
| ~00:40 | v0.5.38 CI passes, image pushed to GHCR |
| ~00:45 | **Recovery attempt 3**: GHCR still denied — need fresh PAT |
| ~04:00+ | User creates classic PAT, re-authenticates Docker, pulls v0.5.38, site restored |
| | **— Phase 2: GPU crashes (v0.5.39 – v0.5.42) —** |
| ~04:10 | User tries search feature → EmbeddingServing fires EXLA → **GPU access crashes Docker host** |
| ~04:15 | v0.5.39 tagged: reverts to StubClient, disables BumblebeeClient entirely |
| ~04:20 | Site restored with v0.5.39 (no semantic search, but stable) |
| ~04:30 | User requests semantic search on CPU — "It's a key feature I want to demonstrate" |
| ~04:45 | v0.5.40 tagged: re-enables BumblebeeClient with `EXLA_TARGET=host` in `docker-compose.prod.yml` + `mem_limit: 2g` |
| ~05:00 | v0.5.40 deployed via CI |
| ~05:05 | **Docker host crashes again** — `EXLA_TARGET` is compile-time, not runtime; the NIF was still GPU-compiled |
| ~05:10 | v0.5.41 tagged: emergency revert to StubClient |
| ~05:15 | v0.5.41 CI deploy fails (smoke test — containers still recovering from v0.5.40 crash) |
| ~05:20 | User deploys v0.5.41 manually |
| ~05:25 | **Docker host crashes AGAIN** — even with StubClient, the EXLA NIF probes GPU on BEAM module load |
| ~05:25 | **Physical Proxmox server hard power-off** — user has to physically walk to the server |
| ~05:30 | User: "I'm about to punch myself in the face" |
| ~05:45 | Root cause identified: `EXLA_TARGET=host` must be set in Dockerfile BEFORE `mix deps.compile` |
| ~06:00 | v0.5.42 tagged: `ENV EXLA_TARGET=host` in Dockerfile build stage, BumblebeeClient re-enabled |
| ~06:30 | v0.5.42 CI completes successfully — image compiled with CPU-only EXLA NIF |
| ~07:00 | Docker host restarted, v0.5.42 deployed, site stable with CPU-only semantic search |

## Root Causes

### Primary: EmbeddingWorker swallowed errors (code defect)

```elixir
# BEFORE (v0.5.33 through v0.5.36) — the bug
def perform(%Oban.Job{args: %{"message_ids" => message_ids}}) do
  _ = message_ids                           # ← discards {:error, reason}
      |> fetch_embeddable_messages()
      |> generate_and_persist_embeddings()
  :ok                                       # ← Oban thinks every job succeeded
end
```

This violated the Oban error contract:
- `:ok` = success, job done
- `{:error, reason}` = failure, Oban retries with backoff
- `{:snooze, N}` = reschedule without counting as attempt

By always returning `:ok`, failed jobs were never retried, errors were invisible to Oban's telemetry, and the underlying failure (EmbeddingServing crash) was never surfaced for correction.

### Secondary: Supervisor restart budget too tight

```elixir
# Embeddings.Supervisor — 3 restarts per 60 seconds
Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 60)
```

EXLA JIT compilation and model loading cause transient failures that can burn through 3 restarts in seconds. Once exhausted, the supervisor itself dies.

### Tertiary: No cascade protection

```elixir
# application.ex — default :permanent restart
children ++ [Slackex.Embeddings.Supervisor]
```

With the default `restart: :permanent`, when Embeddings.Supervisor died, the main Slackex.Supervisor was obligated to restart it. Repeated failures exhausted the main supervisor's budget, cascading into a **full application crash** — taking down Postgres connections, PubSub, the Phoenix Endpoint, and everything else.

### Quaternary: EXLA uses GPU by default — crashes the physical server

EXLA (the XLA backend for Nx) defaults to GPU when available. The Proxmox host has a GPU that cannot handle EXLA workloads — **the user explicitly warned "do not use GPU on the server" multiple times.** This warning was ignored when BumblebeeClient was activated. EXLA hitting the GPU didn't just crash the VM — it crashed the physical Proxmox hypervisor, requiring a full server power cycle.

### Quinary: EXLA_TARGET is compile-time, not runtime — three additional crashes

After the initial fix (v0.5.37/v0.5.38), `EXLA_TARGET=host` was added to `docker-compose.prod.yml` as a runtime environment variable. **This had zero effect.** `EXLA_TARGET` controls how the EXLA NIF (Native Implemented Function) is compiled — it determines whether the NIF binary includes GPU support. Setting it at runtime doesn't change the already-compiled NIF.

Furthermore, even reverting to StubClient (v0.5.41) didn't help — the EXLA NIF is loaded into the BEAM when its module is referenced at application start, and the GPU-compiled NIF **probes the GPU on load**. This means any Docker image built without `EXLA_TARGET=host` at compile time will touch the GPU regardless of whether Bumblebee is actually used.

This misunderstanding caused three additional server crashes:
1. **v0.5.40**: BumblebeeClient + runtime `EXLA_TARGET=host` → GPU crash
2. **v0.5.41**: StubClient (no Bumblebee) but GPU-compiled NIF still loaded → GPU crash
3. **v0.5.41 (again)**: Physical Proxmox host hard power-off

The fix (v0.5.42) was to set `ENV EXLA_TARGET=host` in the Dockerfile **before** `mix deps.compile`, ensuring the NIF is built without GPU support.

### Senary: No resource limits on containers

`docker-compose.prod.yml` had no `mem_limit` or `deploy.resources.limits`. Even in CPU-only mode, the EXLA memory spike during the crash-loop was unbounded, allowing it to consume all VM memory.

## Contributing Factors

### 1. Action items from previous RCA left incomplete

The [2026-03-04 crash-loop RCA](2026-03-04-bumblebee-serving-crash-loop.md) explicitly listed:

> - [ ] Move EmbeddingServing under dedicated supervisor

This was partially done (Embeddings.Supervisor was created in v0.5.35) but **without `restart: :temporary`**, making it useless as a blast-radius containment measure. The supervisor existed but its death still cascaded.

### 2. No worker-level dependency check

EmbeddingWorker had no pre-flight check for EmbeddingServing availability. When the serving process crashed, workers immediately hammered it, accelerating the supervisor restart loop.

### 3. BumblebeeClient activated without OTP resilience review

BumblebeeClient was activated in prod (`config/prod.exs`) at commit `3f3f238` (v0.5.33). The activation involved changing one config line. No review was performed of:
- Worker error handling paths
- Supervisor restart budgets
- Cascade protection
- Resource consumption under failure

### 4. CI quality gates don't test OTP resilience

All CI checks passed for v0.5.36:
- `mix test` — uses StubClient, never exercises BumblebeeClient path
- `mix dialyzer` — found no type error in `_ = result; :ok`
- `mix compile --warnings-as-errors` — no warning for error swallowing
- Docker build + boot check — doesn't start the supervision tree

**None of these gates test supervision behavior, error propagation, or cascade isolation.**

### 5. Recovery hampered by infrastructure fragility

Three separate infrastructure failures compounded the recovery time:

| Failure | Cause | Time lost |
|---------|-------|-----------|
| VM unresponsive | No Proxmox HA policy; OOM killed the VM with no auto-restart | ~3 hours (user didn't notice immediately) |
| DNS resolution | Tailscale DNS (100.100.100.100) failed post-VM-reboot | ~15 min |
| GHCR authentication | CI injects `ghs_` (1-hour) tokens, not persistent PATs | ~30+ min (user had to create new PAT) |

### 6. This is the third incident in 72 hours from the same subsystem

| Date | Version | Incident | Duration |
|------|---------|----------|----------|
| 2026-03-03 | v0.5.14 | Clustering broken on deploy | ~30 min |
| 2026-03-04 | v0.5.25 | EmbeddingServing crash-loop | ~29 min |
| **2026-03-05** | **v0.5.36** | **Embedding cascade kills app + VM** | **~4+ hours** |

Each incident generated action items. The action items from incident 2 would have prevented incident 3 if they had been completed.

## Fixes Applied (v0.5.37 – v0.5.42)

### Layer 1: Error propagation (v0.5.37)

```elixir
# AFTER — errors propagated to Oban
def perform(%Oban.Job{args: %{"message_ids" => message_ids}}) do
  with :ok <- ensure_serving_available() do
    message_ids
    |> fetch_embeddable_messages()
    |> generate_and_persist_embeddings()
  end
end
```

### Layer 2: Dependency pre-check (v0.5.37)

```elixir
defp ensure_serving_available do
  case Application.get_env(:slackex, :embedding_client) do
    Slackex.Embeddings.BumblebeeClient ->
      case Process.whereis(Slackex.Embeddings.EmbeddingServing) do
        nil -> {:snooze, 30}  # Don't hammer a dead process
        _pid -> :ok
      end
    _other -> :ok
  end
end
```

### Layer 3: Cascade protection (v0.5.37)

```elixir
# application.ex — non-essential supervisor won't cascade
spec = Supervisor.child_spec(Slackex.Embeddings.Supervisor, restart: :temporary)
children ++ [spec]
```

### Layer 4: Generous restart budget (v0.5.37)

```elixir
# 5 restarts per 300 seconds (was 3/60s)
Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 300)
```

### Layer 5: Dialyzer compliance (v0.5.38)

Explicit `_ =` with comment in backfill stream (best-effort, errors logged but batch continues).

### Layer 6: Emergency StubClient revert (v0.5.39)

Disabled BumblebeeClient entirely after GPU crash brought down Docker host. Semantic search disabled but site stable.

### Layer 7: Container memory limits (v0.5.40)

```yaml
# docker-compose.prod.yml — cap app containers at 2GB
x-app: &app-defaults
  mem_limit: 2g
```

Also added `EXLA_TARGET: "host"` as runtime env — **which had no effect** (see Root Cause: Quinary).

### Layer 8: CPU-only EXLA at compile time (v0.5.42)

```dockerfile
# Dockerfile — MUST be set before mix deps.compile
ENV EXLA_TARGET=host
```

This is the definitive fix. The EXLA NIF is now compiled without GPU support. The NIF binary cannot probe or access the GPU regardless of runtime configuration. BumblebeeClient re-enabled in `config/prod.exs`.

### Layer 9: Infrastructure hardening (v0.5.40 – v0.5.42)

- **Tailscale DNS fix**: CI deploy auto-provisions a `fix-dns.service` systemd unit on the Docker host that runs on boot, disabling Tailscale DNS and setting Google DNS (8.8.8.8)
- **GHCR auth preservation**: CI deploy now checks if existing Docker auth works before re-authenticating — prevents overwriting long-lived PAT with short-lived `ghs_` token
- **Bumblebee model pre-caching**: CI deploy runs a best-effort model download into the shared Docker volume after container recreation

## What We Got Right

- **Initial code fix was comprehensive** — v0.5.37 addressed four root causes in a single commit
- **Tests updated** — error propagation, snooze, cascade isolation all tested (1002 tests pass)
- **Guardrails created** — CLAUDE.md Production Resilience principle, hookify rule, OTP resilience review skill
- **Root cause identified quickly** — once the VM was back, the code fix took ~20 minutes
- **Infrastructure hardened** — DNS fix automated, GHCR auth preserved, memory limits added, model pre-cached
- **Compile-time fix was definitive** — v0.5.42's Dockerfile change ensures GPU can never be accessed regardless of config
- **Comprehensive documentation** — CLAUDE.md Hardware constraints section, RCA with 8 lessons

## What We Got Wrong

- **Didn't complete action items from the previous RCA** — the cascade protection was explicitly listed as TODO
- **Activated a new subsystem without an OTP resilience review** — one config line change, zero defensive review
- **No infrastructure resilience** — no Proxmox HA, no container memory limits, no auto-restart
- **GHCR auth uses ephemeral tokens** — CI pipeline injects `ghs_` tokens that expire in 1 hour, leaving the server unable to pull images for manual recovery
- **Time to detection was hours** — no external monitoring, no alerting, user discovered the outage manually
- **Recovery required three separate attempts** — each blocked by a different infra failure
- **Assumed EXLA_TARGET was runtime** — set it in docker-compose.prod.yml and deployed, causing three more crashes before discovering it's compile-time
- **Assumed StubClient was safe** — didn't realize the GPU-compiled EXLA NIF probes GPU on BEAM module load regardless of application config
- **User's GPU warning was ignored across seven versions** — from v0.5.36 to v0.5.42, the user repeatedly stated "do not use GPU on the server" and was ignored each time

## Action Items

### P0 — Immediate (before next deploy)

| # | Action | Owner | Status |
|---|--------|-------|--------|
| 1 | Deploy v0.5.42 with all fixes (cascade + CPU-only EXLA + mem limits) | davewil | Done |
| 2 | Set persistent GHCR PAT on Docker host (not `ghs_` token) | davewil | Done |
| 3 | Add container memory limits to `docker-compose.prod.yml` | | Done (v0.5.40, 2GB per container) |
| 4 | Set `EXLA_TARGET=host` in Dockerfile at compile time | | Done (v0.5.42) |

### P1 — This week

| # | Action | Owner | Status |
|---|--------|-------|--------|
| 5 | Configure Proxmox HA policy for Docker host VM (auto-restart on crash) | | TODO |
| 6 | Fix Tailscale DNS permanently — systemd service on boot + CI belt-and-suspenders | | Done (v0.5.40 — CI auto-provisions fix-dns.service) |
| 7 | Add external uptime monitoring + alerting (e.g., UptimeRobot → Telegram) | | TODO |
| 8 | CI deploy step: preserve long-lived PAT instead of overwriting with `GITHUB_TOKEN` | | Done (v0.5.40 — conditional auth check) |
| 9 | Add `dmesg`/`journalctl` review on Docker host to confirm OOM theory | | TODO |

### P2 — Before next feature activation

| # | Action | Owner | Status |
|---|--------|-------|--------|
| 10 | OTP resilience review required before activating any non-essential subsystem | | Policy (documented) |
| 11 | Integration test: start app with BumblebeeClient config, verify graceful degradation | | TODO |
| 12 | Warm-up inference in CI deploy pipeline (validates model loads + generates output) | | Done (v0.5.40 — CI runs model pre-cache step) |
| 13 | Single-node EmbeddingServing (only on app1) to halve memory usage | | TODO |

### P3 — Process improvements

| # | Action | Owner | Status |
|---|--------|-------|--------|
| 14 | RCA action items must have explicit owners and deadlines — review weekly | | Policy |
| 15 | "Definition of Done" for RCA action items — not just "created" but verified in prod | | Policy |
| 16 | Close the loop on prior RCA open items before deploying new features to same subsystem | | Policy |
| 17 | Document compile-time vs runtime env vars for all NIF-based dependencies | | Done (CLAUDE.md Hardware constraints) |

## Lessons

### 1. Incomplete action items from RCA #2 directly caused RCA #3

The previous RCA (2026-03-04) listed "Move EmbeddingServing under dedicated supervisor" as P2 TODO. The supervisor was created but without `restart: :temporary` — making it cosmetic, not functional. If that action item had been properly completed and verified, this outage would not have happened.

**Rule: RCA action items are not done until verified in production. Untested mitigations are not mitigations.**

### 2. One config line can crash your entire infrastructure

Activating BumblebeeClient was a single line change in `config/prod.exs`. It passed all CI gates. It looked safe. It took down the application, crashed the VM, and required 4+ hours to recover. The change activated a subsystem with known resilience gaps that had not been addressed.

**Rule: Activating a non-essential subsystem in production requires an OTP resilience review, not just a config change.**

### 3. Recovery time is dominated by infrastructure, not code

The code fix took 20 minutes. Recovery took 4+ hours because of:
- No alerting (hours before anyone noticed)
- No VM auto-restart (manual Proxmox intervention)
- DNS failure post-reboot (Tailscale)
- GHCR auth failure (ephemeral tokens)

**Rule: Recovery infrastructure (monitoring, auto-restart, persistent credentials) matters more than MTTR for the code fix.**

### 4. `_ = result; :ok` is the Elixir equivalent of `catch (Exception e) { return true; }`

It silences every error signal, prevents all retry logic, and creates the illusion of success. Dialyzer doesn't flag it. Tests don't catch it (if they use stubs). It only manifests in production under real failure conditions. This pattern should be treated as a critical defect in any Oban worker.

**Rule: Hookify rule `oban-worker-error-swallow` now warns on this pattern at edit time.**

### 5. Three incidents from one subsystem in 72 hours is a pattern, not bad luck

| # | What happened | What was missing |
|---|---------------|-----------------|
| 1 | Clustering broken | No deploy smoke test |
| 2 | EmbeddingServing crash-loop | No graceful degradation |
| 3 | Cascade kills app + VM | Incomplete RCA action items |

Each incident revealed a gap. Each gap was documented. Not all were closed before the next incident. The velocity of shipping outpaced the velocity of hardening.

**Rule: No new features to a subsystem that has open P1/P2 action items from a previous incident.**

### 6. User warnings were ignored — repeatedly

The user explicitly stated multiple times: "Do not use GPU on the server." The server is a mini-PC with a flaky GPU — GPU is off-limits. EXLA defaults to GPU when available. This warning was ignored when BumblebeeClient was activated, directly causing the physical server crashes.

Even after the initial fix, GPU access continued across v0.5.39–v0.5.41 because the distinction between compile-time and runtime environment variables was not understood.

**Rule: User-stated hardware constraints are non-negotiable. Document them in CLAUDE.md and enforce them in config.**

### 7. Compile-time vs runtime is a critical distinction for NIFs

`EXLA_TARGET=host` set as a runtime environment variable (in `docker-compose.prod.yml`) has **zero effect**. EXLA_TARGET controls how the NIF is compiled — the C/C++ binary that interfaces with XLA. Once compiled with GPU support, the NIF will probe the GPU on load regardless of any runtime configuration.

This caused three unnecessary server crashes (v0.5.40, v0.5.41 × 2) because:
1. The runtime env var appeared to be the right fix
2. Even reverting to StubClient didn't help — the GPU-compiled NIF loads when any EXLA module is referenced
3. The only fix was recompiling the NIF without GPU support (`ENV EXLA_TARGET=host` in Dockerfile before `mix deps.compile`)

**Rule: For NIF-based dependencies, always verify whether configuration is compile-time or runtime. If compile-time, it must be set in the Dockerfile build stage.**

### 8. "Revert to safe config" doesn't work when the binary itself is unsafe

Reverting from BumblebeeClient to StubClient (v0.5.41) should have been a safe fallback — StubClient doesn't use EXLA at all. But the Docker image still contained the GPU-compiled EXLA NIF, which probes the GPU when loaded. The BEAM loads NIF modules eagerly when they're referenced anywhere in the dependency graph.

This violated the assumption that "not using a feature" means "not touching its infrastructure." With NIFs, the binary is loaded whether you call it or not.

**Rule: When a NIF has dangerous hardware interactions, the fix must be at the compilation level, not the configuration level.**

## Appendix: Defense-in-Depth After Fixes

| Layer | Control | Status |
|-------|---------|--------|
| Code | Worker propagates errors to Oban | v0.5.37 ✅ |
| Code | Worker checks serving availability, snoozes if down | v0.5.37 ✅ |
| Code | Hookify rule warns on `_ =` in worker files | v0.5.37 ✅ |
| Build | `EXLA_TARGET=host` set in Dockerfile before `mix deps.compile` | v0.5.42 ✅ |
| Build | Comment in Dockerfile explaining compile-time requirement | v0.5.42 ✅ |
| Supervision | Embeddings.Supervisor `restart: :temporary` | v0.5.37 ✅ |
| Supervision | Generous restart budget (5/300s) | v0.5.37 ✅ |
| Config | `EXLA_TARGET: "host"` in docker-compose.prod.yml (belt-and-suspenders) | v0.5.40 ✅ |
| Config | Hardware constraints documented in CLAUDE.md | v0.5.42 ✅ |
| Process | OTP resilience review skill | v0.5.37 ✅ |
| Process | Production Resilience principle in CLAUDE.md | v0.5.37 ✅ |
| Infra | Container memory limits (2GB per app) | v0.5.40 ✅ |
| Infra | Persistent GHCR credentials (CI preserves PAT) | v0.5.40 ✅ |
| Infra | Tailscale DNS fix-dns.service auto-provisioned by CI | v0.5.40 ✅ |
| Infra | Bumblebee model pre-cached in shared volume on deploy | v0.5.40 ✅ |
| Infra | Proxmox HA auto-restart | TODO |
| Infra | External monitoring + alerting | TODO |
