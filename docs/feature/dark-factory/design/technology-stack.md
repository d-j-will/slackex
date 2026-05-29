# Dark Factory Coordinator — Technology Stack

**Date:** 2026-04-09
**Wave:** DESIGN

---

## Stack Overview

The coordinator introduces **no new dependencies** to the Tenun codebase. It uses existing Claude Code primitives and Tenun MCP tools.

| Layer | Technology | Role | New? |
|-------|-----------|------|:----:|
| Orchestration | Claude Code session (Max subscription) | Long-lived coordinator | No |
| Worker spawning | Claude Code `Agent` tool with `isolation: "worktree"` | Spawn isolated implementing/verification agents | No |
| Agent communication | Claude Code `SendMessage` | Coordinator <-> agent message passing | No |
| Platform communication | MCP over SSE/HTTP | Coordinator <-> Tenun factory tools | No |
| Human communication | Tenun channel threads via `reply_to_thread` MCP tool | Progress updates, clarifications | No |
| Thread polling | `search_messages` MCP tool | Detect clarification responses | No |
| Version control | Git worktrees (`git worktree add/remove`) | Isolated working directories per run | No |
| State persistence | Tenun DB via MCP (factory_runs, factory_events) | Durable run state | Phase 1 |
| Timeout enforcement | Oban cron (LifecycleWorker) | Release stale claims | Phase 1 |
| Feature gating | FunWithFlags (`:dark_factory`) | Feature flag | Phase 1 |
| Thread notifications | ChannelNotifier (GenServer) | PubSub -> thread posts | Phase 1 |

---

## Rationale for No New Dependencies

The coordinator is a **client** of existing systems. Its "technology" is prompt engineering and Claude Code orchestration primitives. Adding server-side dependencies for coordinator behavior would:
1. Couple Tenun to a specific orchestration model (violates "Tenun is a platform, not an agent runtime")
2. Require server-side changes for what is purely client-side logic
3. Add operational complexity (new processes, supervision, monitoring)

The coordinator proves its value first. If it works well, Phase 2 migrates the orchestration into Tenun (GenServer per run, Agent SDK) — that's when new server-side dependencies arrive.

---

## Dev Machine Requirements

| Resource | Minimum | Recommended | Notes |
|----------|---------|-------------|-------|
| CPU cores | 4 | 8+ | Concurrent Elixir compiles are CPU-bound |
| RAM | 16 GB | 32 GB | Each worktree `_build` can use 1-2 GB |
| Disk | 10 GB free | 20 GB+ | Worktrees + `_build` + `deps` per run |
| Claude Code | Max subscription | Max subscription | Required for concurrent agent sessions |
| Git | 2.20+ | Latest | Worktree support |
| Network | Stable | Stable | MCP SSE connection to Tenun |

---

## Phase 2 Stack Evolution

When the coordinator migrates into Tenun (Phase 2):

| Phase 1 (Coordinator) | Phase 2 (Tenun-native) |
|----------------------|----------------------|
| Claude Code session | GenServer per run |
| Agent tool | Claude Agent SDK |
| SendMessage | Agent SDK messaging |
| MCP poll | PubSub push |
| Ephemeral state | GenServer state + DB checkpoint |
| Prompt-enforced isolation | MCP token scope restriction |

The Factory context module and MCP tools remain unchanged across phases.
