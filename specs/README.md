# Slackex Specification Index

> Quick-reference for identifying the next most important task.
> Read this file instead of loading all phase specs into context.

## Project Status

| Phase | Status | Tests | Spec |
|-------|--------|-------|------|
| [Phase 1 — Foundation](#phase-1--foundation) | **COMPLETE** | 211 | [01-phase-1-foundation.md](01-phase-1-foundation.md) |
| [Phase 2 — Real-time & CQRS](#phase-2--real-time--cqrs) | **COMPLETE** | +45 | [02-phase-2-realtime-cqrs.md](02-phase-2-realtime-cqrs.md) |
| [Phase 3 — Distribution & Scale](#phase-3--distribution--scale) | **IN PROGRESS** | +9 | [03-phase-3-distribution.md](03-phase-3-distribution.md) |
| [Phase 4 — Intelligence & Search](#phase-4--intelligence--search) | Not started | — | [04-phase-4-intelligence.md](04-phase-4-intelligence.md) |
| [CI/CD & DevOps](#cicd--devops) | Partial | — | [05-ci-cd-devops.md](05-ci-cd-devops.md) |
| [Testing Strategy](#testing-strategy) | Reference | — | [06-testing-strategy.md](06-testing-strategy.md) |
| [Architecture Overview](#architecture-overview) | Reference | — | [00-overview.md](00-overview.md) |

**Current test count: 246 (0 failures)**

---

## Phase 1 — Foundation

**Status: COMPLETE** | Spec: [01-phase-1-foundation.md](01-phase-1-foundation.md)

| Step | Description | Status |
|------|-------------|--------|
| 1 | Project Generation & Configuration | Done |
| 2 | Database Schema & Migrations | Done |
| 3 | Ecto Schemas | Done |
| 4 | Snowflake ID Generator | Done |
| 4.5 | Rate Limiter | Done |
| 4.6 | Guardian & Auth Module | Done |
| 5 | Context Modules (Public APIs) | Done |
| 6 | Permissions Module | Done |
| 7 | LiveView Chat Interface | Done |
| 8 | Application Supervisor | Done |
| 9 | Docker Compose for Local Dev | Done |

---

## Phase 2 — Real-time & CQRS

**Status: COMPLETE** | Spec: [02-phase-2-realtime-cqrs.md](02-phase-2-realtime-cqrs.md)

| Step | Description | Status |
|------|-------------|--------|
| 1 | ChannelServer GenServer | Done |
| 2 | Async Write Pipeline (BatchWriter) | Done |
| 3 | ETS Local Cache | Done |
| 4 | Phoenix Presence | Done |
| 5 | Scroll-Based History Pagination (HistoryLoader) | Done |
| 6 | Update All Write Paths to Use CQRS | Done |
| 7 | Oban Setup (Background Jobs, CacheWarmer) | Done |
| 8 | Versioned Envelope Contract | Done |
| 9 | Write Rejection Normalization | Done |

---

## Phase 3 — Distribution & Scale

**Status: IN PROGRESS** | Spec: [03-phase-3-distribution.md](03-phase-3-distribution.md)

| Step | Description | Status |
|------|-------------|--------|
| 1 | libcluster — Node Discovery | **Done** |
| 2.1 | Replace Registry with Horde.Registry | **Done** |
| 2.2 | Writer Fencing (Split-Brain Safety) | **Done** |
| 2.3 | Replace DynamicSupervisor with Horde.DynamicSupervisor | **Done** |
| 2.4 | Update ChannelServer via tuples | **Done** |
| 2.5 | Process Handoff on Node Down (terminate/2 + crash recovery) | **Done** |
| 3 | Redis — Cross-Node Cache (pool, cascade, write-through) | Not started |
| 3.5 | Read Replica Support (ReadRepo, lag detection) | Not started |
| 4 | Push Notifications (PushWorker, Oban) | Not started |
| 4.5 | Device Tokens Table | Not started |
| 5 | Message Table Partitioning | Not started |
| 6 | Reconnection & Catch-Up (CatchupServer) | Not started |
| 7 | Update Application Supervisor (Phase 3) | Partial (Horde + libcluster added) |
| 8 | Kubernetes Deployment (Dockerfile, manifests, health endpoints) | Not started |

### Next recommended task

**Step 3 — Redis Cross-Node Cache** (pool, cascade, write-through). This adds cross-node cache coherence before proceeding to push notifications.

---

## Phase 4 — Intelligence & Search

**Status: NOT STARTED** | Spec: [04-phase-4-intelligence.md](04-phase-4-intelligence.md) | Prereq: Phase 3 complete

| Step | Description | Status |
|------|-------------|--------|
| 1 | Enable pgvector Extension | Not started |
| 2 | Message Embeddings Table | Not started |
| 3 | Embedding Schema | Not started |
| 4 | Embedding Client (behaviour + OpenAI + stub) | Not started |
| 5 | Embedding Generation Worker (Oban + PersistenceListener) | Not started |
| 6 | Search Module (FTS, semantic, hybrid RRF) | Not started |
| 7 | Search LiveView Component | Not started |
| 8 | RAG-Ready Query Interface | Not started |
| 9 | Update Application Supervisor | Not started |
| 10 | Configuration | Not started |

---

## CI/CD & DevOps

**Status: PARTIAL** | Spec: [05-ci-cd-devops.md](05-ci-cd-devops.md)

| Item | Status |
|------|--------|
| Docker Compose (Postgres + Redis) | Done |
| Pre-commit hook (format, compile, credo, assets, test) | Done |
| Mix aliases (setup, lint, quality, ci) | Partial |
| Credo config | Done |
| Formatter config | Done |
| Dialyzer | Not configured |
| GitHub Actions CI | Not configured |
| Production Dockerfile | Not started |
| bin/setup, bin/server scripts | Not started |
| Health/readiness endpoints | Not started (Phase 3 Step 8) |
| Tidewave MCP | Done |

---

## Testing Strategy

**Reference document** | Spec: [06-testing-strategy.md](06-testing-strategy.md)

Testing Trophy approach — 75% behavioral integration, 15% unit (pure functions), 5% static analysis, 5% E2E. Describes test infrastructure (Factory, DataCase, ConnCase, ChannelCase) and planned test categories for all phases.

---

## Architecture Overview

**Reference document** | Spec: [00-overview.md](00-overview.md)

Contains: architectural decisions table, boundary definitions, supervision tree, CQRS message flow diagram, database schema overview, file structure, dependency introduction timeline, deferred features list.

---

## Key Files

| File | Purpose |
|------|---------|
| `progress.txt` | Detailed build log with lessons learned (numbered 1-34) |
| `specs/README.md` | This file — status index |
| `mix.exs` | Dependencies and project config |
| `lib/slackex/application.ex` | Supervision tree |
