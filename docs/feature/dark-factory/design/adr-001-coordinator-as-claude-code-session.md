# ADR-001: Coordinator as Long-Lived Claude Code Session

**Date:** 2026-04-09
**Status:** Accepted
**Context:** Dark Factory Coordinator

---

## Context

The dark factory needs an orchestrator that polls for work, spawns implementing/verification agents, manages heartbeats, relays clarifications, and submits results. Three implementation options were evaluated.

## Decision

The coordinator runs as a **long-lived Claude Code session** (Option B from the coordinator spec).

## Alternatives Considered

### Option A: Scheduled Task
A recurring scheduled task that polls every N minutes.

**Pros:** Simple, survives session restarts, no long-running process.
**Cons:** Up to 3 min latency to notice work. Must re-discover state each invocation. No natural agent-to-coordinator communication (SendMessage requires a live session). Cannot relay clarifications in real-time.

**Rejected because:** The lack of SendMessage support makes clarification relay impossible without additional infrastructure.

### Option C: Skill-Triggered Background Agents
A skill starts the loop, spawns background agents, returns control to the user.

**Pros:** User can do other work. Explicit start/stop.
**Cons:** Background agent lifecycle is complex. No coordinator context between spawned agents. Heartbeat delegation requires a persistent process.

**Rejected because:** Background agents cannot maintain the shared state needed for coordinated heartbeating and clarification tracking.

## Consequences

### Positive
- Natural message passing via SendMessage between coordinator and workers
- Stateful coordination (active agent registry, clarification tracking)
- User can observe progress in the session
- Simple mental model: "the coordinator is a Claude Code session I keep running"

### Negative
- Tied to a single session — must be restarted if it crashes
- Session consumes a Claude Code context window
- Cannot run while the user is doing other Claude Code work in the same terminal (but can run in a separate terminal/tmux pane)

### Mitigations
- Crash recovery architecture (worktree discovery + DB reconciliation) limits data loss
- LifecycleWorker releases stale claims server-side, preventing permanent stuck runs
- Coordinator is stateless enough to restart — all durable state is in Tenun DB + threads
