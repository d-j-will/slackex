# ADR-002: Centralized Heartbeat Delegation

**Date:** 2026-04-09
**Status:** Accepted
**Context:** Dark Factory Coordinator

---

## Context

Active factory runs require periodic heartbeats to keep claims alive. The LifecycleWorker releases claims when `last_heartbeat_at` exceeds `heartbeat_timeout_minutes`. The question is whether agents heartbeat themselves or the coordinator heartbeats on their behalf.

## Decision

The **coordinator heartbeats on behalf of all active agents**. Worker agents never call MCP tools directly.

## Alternatives Considered

### Distributed Heartbeat (Each Agent Self-Heartbeats)
Each agent has its own MCP token and calls `factory_heartbeat` directly.

**Pros:** No single point of failure for heartbeats. Agents are self-sufficient.
**Cons:** Requires MCP token distribution to each agent. Adds auth complexity. Agents must know the heartbeat protocol. Multiple concurrent MCP sessions.

**Rejected because:** Distributing MCP tokens to ephemeral worktree agents adds complexity with no current benefit. Phase 2 (restricted MCP tokens) is the right time for this.

### Hybrid (Coordinator Primary, Agent Fallback)
Coordinator heartbeats normally. Agents self-heartbeat if they detect the coordinator is unresponsive.

**Pros:** Resilient to coordinator latency.
**Cons:** Requires agents to have MCP access. Complex failure detection. Race conditions between coordinator and agent heartbeats.

**Rejected because:** Premature complexity. The LifecycleWorker already handles the timeout case gracefully.

## Consequences

### Positive
- Agents are simple — they implement and report via SendMessage. No MCP awareness needed.
- Single MCP session (coordinator) simplifies auth and rate limiting.
- Heartbeat cadence is consistent across all agents.
- Progress messages are centralized and can be formatted consistently.

### Negative
- Coordinator crash stops ALL heartbeats simultaneously (thundering herd on timeout).
- Coordinator must be responsive — if it hangs, all claims go stale.

### Mitigations
- Heartbeat timeout is generous (10 min default, heartbeat every 5 min = 5 min margin).
- Crash recovery architecture re-claims runs before timeout when possible.
- LifecycleWorker release is graceful — runs re-queue, work can resume on next claim.
- Phase 2 can add distributed heartbeat when restricted MCP tokens exist.
