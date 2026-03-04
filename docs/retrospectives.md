# Retrospectives

Production incidents and lessons learned. Each entry links to the full RCA.

## 2026-03-04: EmbeddingServing Crash-Loop (v0.5.25, v0.5.26)

**Severity:** P0 | **Duration:** ~29 min | **RCA:** [docs/rca/2026-03-04-bumblebee-serving-crash-loop.md](rca/2026-03-04-bumblebee-serving-crash-loop.md)

**What happened:** Deploying the Bumblebee embedding provider caused both app containers to crash-loop. Three bugs compounded: GenServer name collision, blocking init, and missing model on server. Required two hotfix deploys (v0.5.26, v0.5.27) to restore service.

**Key lesson:** Code paths only active in prod config have zero CI coverage. This is the second outage caused by test/prod config divergence. GenServers depending on external resources must handle failure gracefully — crash-on-failure pattern matching under supervision creates crash-loops.

**Open actions:**
- [ ] Pre-cache Bumblebee model before switching to BumblebeeClient
- [ ] Add integration test with prod-like supervision tree startup
- [ ] Move EmbeddingServing under dedicated supervisor

---

## 2026-03-03: Clustering Broken on Deploy (v0.5.14)

**Severity:** P1 | **Duration:** ~30 min | **RCA:** [docs/rca/2026-03-03-clustering-deploy-failure.md](rca/2026-03-03-clustering-deploy-failure.md)

**What happened:** `rel/env.sh.eex` set `RELEASE_DISTRIBUTION=name` (long names) but Docker Compose provided short hostnames. Erlang rejected the hostnames, preventing cluster formation. Bug pre-dated the deploy but was never surfaced.

**Key lesson:** Features built on unverified assumptions fail when the assumption is wrong. No deploy smoke test existed to verify cluster state. The file controlling Erlang distribution was never read during implementation.

**Open actions:**
- [x] Deploy smoke test verifying cluster formation
- [x] Health endpoint returning cluster state
- [x] CLAUDE.md clustering documentation
