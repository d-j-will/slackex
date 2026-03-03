# Slackex Specification Index

> Quick-reference for identifying the next most important task.
> Read this file instead of loading all phase specs into context.

## Project Status

| Phase | Status | Tests | Spec |
|-------|--------|-------|------|
| [Phase 1 — Foundation](#phase-1--foundation) | **COMPLETE** | 211 | [01-phase-1-foundation.md](01-phase-1-foundation.md) |
| [Phase 2 — Real-time & CQRS](#phase-2--real-time--cqrs) | **COMPLETE** | +45 | [02-phase-2-realtime-cqrs.md](02-phase-2-realtime-cqrs.md) |
| [Phase 3 — Distribution & Scale](#phase-3--distribution--scale) | **COMPLETE** | +55 | [03-phase-3-distribution.md](03-phase-3-distribution.md) |
| [Phase 4 — Intelligence & Search](#phase-4--intelligence--search) | Not started | — | [04-phase-4-intelligence.md](04-phase-4-intelligence.md) |
| [Phase 5 — Full-Feature UI](#phase-5--full-feature-ui) | **IN PROGRESS** | +355 | [07-phase-5-ui.md](07-phase-5-ui.md) |
| [Unplanned Features](#unplanned-features) | **COMPLETE** | (included above) | `docs/evolution/` |
| [CI/CD & DevOps](#cicd--devops) | **Mostly Done** | — | [05-ci-cd-devops.md](05-ci-cd-devops.md) |
| [Testing Strategy](#testing-strategy) | Reference | — | [06-testing-strategy.md](06-testing-strategy.md) |
| [Architecture Overview](#architecture-overview) | Reference | — | [00-overview.md](00-overview.md) |

**Current test count: 850 (0 failures)**

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

**Status: COMPLETE** | Spec: [03-phase-3-distribution.md](03-phase-3-distribution.md)

| Step | Description | Status |
|------|-------------|--------|
| 1 | libcluster — Node Discovery | **Done** |
| 2.1 | Replace Registry with Horde.Registry | **Done** |
| 2.2 | Writer Fencing (Split-Brain Safety) | **Done** |
| 2.3 | Replace DynamicSupervisor with Horde.DynamicSupervisor | **Done** |
| 2.4 | Update ChannelServer via tuples | **Done** |
| 2.5 | Process Handoff on Node Down (terminate/2 + crash recovery) | **Done** |
| 3 | Redis — Cross-Node Cache (pool, cascade, write-through) | **Done** |
| 3.5 | Read Replica Support (ReadRepo, lag detection) | **Done** |
| 4 | Push Notifications (PushWorker, Oban) | **Done** |
| 4.5 | Device Tokens Table | **Done** |
| 5 | Message Table Partitioning | **Deferred** (scale-dependent; requires maintenance window — revisit at >10M rows) |
| 6 | Reconnection & Catch-Up (CatchupServer) | **Done** |
| 7 | Update Application Supervisor (Phase 3) | **Done** |
| 8 | Kubernetes Deployment | **N/A** (deployment target is Docker Compose + Proxmox homelab, not K8s) |
| 8.3 | Health (`/health`) + Readiness (`/ready`) endpoints | **Done** |

### Next recommended task

**Phase 5 Step 6 — Reactions** (new `message_reactions` table, emoji picker JS hook, reaction bar component, real-time toggle). Composite score 6.85 — highest remaining feature. See `docs/research/next-feature-priority-2026-02-28-v2.md` for full analysis.

Alternative: **Phase 4 — Intelligence & Search** (Phase 3 prereq now cleared). **Phase 5 Step 8 — Channel Members & Pinned Messages** (member management modal, `pinned_messages` table, channel header). Composite 6.60.

---

## Phase 4 — Intelligence & Search

**Status: NOT STARTED** | Spec: [04-phase-4-intelligence.md](04-phase-4-intelligence.md) | Prereq: ~~Phase 3 complete~~ ✓ cleared

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

## Phase 5 — Full-Feature UI

**Status: IN PROGRESS** | Spec: [07-phase-5-ui.md](07-phase-5-ui.md) | Prereq: Phase 2 complete, Phase 3 Step 6 complete

| Step | Description | Status |
|------|-------------|--------|
| 1 | Layout Refactor & Responsive Shell | **Done** |
| 2 | DM Conversations in UI | **Done** |
| 3 | Channel Browsing, Creation & Join/Leave | **Done** |
| 4 | User Profiles & Online Status | **Done** |
| 5 | Message Editing & Deletion | **Done** |
| 6 | Reactions | Not started |
| 7 | Threads/Replies | Not started |
| 8 | Channel Members & Pinned Messages | Not started |
| 9 | Invite Links & User Blocks | Partial (blocking backend done in DM Safety; invite links + block UI remain) |
| 10 | Unread Counts, Catchup & Polish | Partial (unread counts + sidebar badges done; catchup & polish remain) |

---

## Unplanned Features

Features completed outside the original phase specs. All have evolution documents in `docs/evolution/`.

| Feature | Completed | Tests Added | Evolution Doc |
|---------|-----------|-------------|---------------|
| DM Safety Phase 1 — DM request system, accept/decline/block | 2026-02-27 | ~40 | `2026-02-27-dm-safety-phase-1.md` |
| DM Safety Phase 2 — Abuse reporting, content moderation, trust scores | 2026-02-27 | ~35 | `2026-02-27-dm-safety-phase-2.md` |
| DM Safety Phase 3 — DM preferences, rate limiting, velocity detection, account age gates | 2026-02-27 | ~30 | `2026-02-27-dm-safety-phase-3.md` |
| Encryption at Rest — Cloak.Ecto AES-GCM-256, encrypted content/email, HMAC search, key rotation | 2026-02-28 | ~25 | `2026-02-28-encryption-at-rest.md` |

---

## CI/CD & DevOps

**Status: Mostly Done** | Spec: [05-ci-cd-devops.md](05-ci-cd-devops.md)

| Item | Status |
|------|--------|
| Docker Compose (Postgres + Redis) | Done |
| Pre-commit hook (format, tests, YAML lint) | Done |
| Mix aliases (setup, lint, quality, ci) | Partial |
| Credo config | Done |
| Formatter config | Done |
| Dialyzer | **Done** |
| Boundary architectural linter | **Done** (`boundary` 0.10.4 — context declarations, violations fail `--warnings-as-errors`) |
| GitHub Actions CI + deploy pipeline | **Done** (`.github/workflows/ci-deploy.yml`) |
| Production Dockerfile | **Done** |
| `scripts/pre-deploy` verification script | **Done** (tests, format, credo, dialyzer, YAML, Docker build + boot) |
| Health/readiness endpoints | **Done** (`/health` returns node, cluster_nodes, cluster_size) |
| Claude Code hooks (block `--no-verify`, migration safety, CI patterns) | **Done** (`.claude/settings.json`) |
| `/deploy` slash command | **Done** (`.claude/commands/deploy.md`) |
| Feature flags (FunWithFlags, admin UI) | **Done** |
| bin/setup, bin/server scripts | Not started |
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
| `docs/research/next-feature-priority-2026-02-28-v2.md` | Evidence-based next feature ranking (Reactions → Channel Members/Pins → Threads) |
| `docs/evolution/` | Per-feature evolution documents (architecture decisions, test counts) |
| `docs/engineering-principles.md` | Production engineering principles (shift-left, deploy-safe, test isolation, automation) |
| `scripts/pre-deploy` | Full pre-tag verification (tests, format, credo, dialyzer, YAML, Docker build + boot) |
| `.claude/settings.json` | Claude Code hooks (block `--no-verify`, migration safety, CI config validation) |
