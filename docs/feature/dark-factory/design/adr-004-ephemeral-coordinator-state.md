# ADR-004: Ephemeral Coordinator State (Not Persisted to DB)

**Date:** 2026-04-09
**Status:** Accepted
**Context:** Dark Factory Coordinator

---

## Context

The coordinator tracks several pieces of state: active agents, clarification status, concurrency slots. This state could be persisted (DB, file) or kept ephemeral (in-memory within the session).

## Decision

All coordinator state is **ephemeral** (in-memory). The coordinator is designed to be restartable — it reconstructs state from durable sources (Tenun DB via MCP + worktree discovery + thread messages) on startup.

## Alternatives Considered

### Persist to Local File
Write coordinator state to `.factory/coordinator-state.json` on each change.

**Pros:** Survives crashes. Fast to read on restart.
**Cons:** Stale file risk (crash mid-write). Must handle concurrent access. File may not reflect Tenun-side state changes (e.g., LifecycleWorker released a claim).

**Rejected because:** The file can go stale relative to Tenun DB state. On restart, the coordinator must check DB state anyway — the file adds a source of truth that can conflict.

### Persist to Tenun DB (New Columns/Table)
Add coordinator state columns to `factory_runs` or a new `factory_coordinator_state` table.

**Pros:** Single source of truth. Survives coordinator crash. Queryable.
**Cons:** Server-side schema changes. Couples Tenun to coordinator internals (which agent is running, clarification tracking). Violates C-3.

**Rejected because:** Coordinator internals (which Claude Code agent is assigned to which run) are not Tenun's concern. This coupling is appropriate for Phase 2 (GenServer per run) but premature now.

## Consequences

### Positive
- Zero server-side changes
- No stale state files to manage
- Coordinator is truly stateless — restart is always safe
- Tenun DB + threads remain the single source of truth
- Simple mental model: "if in doubt, restart the coordinator"

### Negative
- Crash loses: active agent map, clarification tracking, agent sub-state
- Recovery requires worktree discovery + DB queries + thread reads (slower than reading a state file)
- Clarification answers received during crash window are delayed until the human re-answers (agent may re-ask)

### Mitigations
- Recovery sequence is well-defined (architecture-coordinator.md §9)
- Worktree discovery is fast (filesystem scan)
- DB state is authoritative (MCP query)
- Thread messages are permanent (clarification Q&A preserved even across crashes)
- Acceptable trade-off: recovery takes ~1 poll cycle, not instant, but no data is permanently lost
