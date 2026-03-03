# RCA: Clustering Broken on Deploy v0.5.14

**Date:** 2026-03-03
**Severity:** P1 — production outage (partial), user-visible errors
**Duration:** ~30 minutes
**Trigger:** Deploy of v0.5.14 (FunWithFlags + cluster node indicator)

## Timeline

1. v0.5.14 tagged and pushed — CI builds image, deploys to server
2. App boots successfully, `/chat` works for basic usage
3. User stops `app1` to test node failover → 502 (Caddy has no failover health checks)
4. User restarts `app1` → intermittent "Something went wrong" errors, LiveView disconnections
5. Logs show: `** System running to use fully qualified hostnames ** Hostname app2 is illegal`
6. Root cause identified: `rel/env.sh.eex` sets `RELEASE_DISTRIBUTION=name` but Docker Compose provides short hostnames
7. v0.5.15 deployed with fix (`sname`), v0.5.16 adds smoke test

## Root Cause

`rel/env.sh.eex` contained `RELEASE_DISTRIBUTION=name`, which requires fully qualified domain names (FQDNs) for Erlang node names. Docker Compose sets `hostname: app1` / `hostname: app2` — short names. Erlang rejected `app2` as an illegal hostname in long-name mode, preventing the gossip strategy from forming a cluster.

**This bug pre-dated v0.5.14.** Clustering was never working in production. The error was logged continuously but never surfaced because no feature depended on it being visible.

## Contributing Factors

### 1. Feature built on an unverified assumption
The node indicator spec assumed clustering was working. The feature's entire purpose was to *visualize* which cluster node serves a session. Nobody verified the underlying capability before building the UI for it.

### 2. `rel/env.sh.eex` not included in investigation scope
When implementing the spec, 12 files were read and modified. `rel/env.sh.eex` — the file that controls Erlang distribution mode — was never read. It is only 8 lines long and directly determines whether clustering works.

### 3. Local tests cannot catch clustering issues
`config/test.exs` disables clustering (`topologies: []`). `mix test` passes regardless of whether `rel/env.sh.eex` is correct. There was no integration test or deploy-time check for cluster formation.

### 4. No deploy smoke test existed
The deploy workflow checked `docker compose ps` (container running ≠ container healthy) but did not hit any endpoint or verify cluster state. A container can be "running" while logging errors every second.

### 5. Repeated prior attempts not consolidated
The clustering setup was attempted ~5 times across multiple sessions. Each attempt addressed a different symptom without establishing a verification checklist. Lessons were not persisted in CLAUDE.md until after this incident.

## What Was Fixed

| Version | Fix |
|---------|-----|
| v0.5.15 | `RELEASE_DISTRIBUTION=sname` in `rel/env.sh.eex` (accepts short hostnames) |
| v0.5.16 | `/health` returns cluster JSON; CI smoke test hits both containers post-deploy; cluster size check |
| v0.5.16 | Pre-deploy verification rules added to CLAUDE.md |

## Action Items

- [x] Fix `RELEASE_DISTRIBUTION` (v0.5.15)
- [x] Add `/health` cluster info endpoint (v0.5.16)
- [x] Add CI smoke test that fails deploy on unhealthy containers (v0.5.16)
- [x] Add pre-deploy verification rules to CLAUDE.md (v0.5.16)
- [x] Add Caddy active health checks so failover works when a node goes down (v0.5.17 — deploy script writes health-checked proxy snippet and auto-migrates Caddyfile)
- [x] Add startup log line that confirms cluster formation — `NodeListener` logs peer count after 30s delay (v0.5.17)

## Lessons

1. **If a feature depends on infrastructure, verify the infrastructure first.** Don't build a dashboard for a system that isn't running.
2. **Read every file in the release surface area.** `rel/env.sh.eex` is 8 lines. Skipping it cost more time than reading it.
3. **`mix test` passing is necessary but not sufficient for deploy safety.** Clustering, Docker networking, env vars, and release boot are not covered by unit tests.
4. **Deploy verification must be automated.** Humans forget to check logs. CI doesn't.
5. **Persist lessons immediately.** If a problem has been encountered before, it should be in CLAUDE.md before the next deploy, not after the next failure.
