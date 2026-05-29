# ADR-003: Clarification via Message Convention, Not Protocol

**Date:** 2026-04-09
**Status:** Accepted
**Context:** Dark Factory Coordinator

---

## Context

When an implementing agent encounters a spec ambiguity, it needs to ask the human a question and receive an answer. This requires a communication channel between agent and human, mediated by the coordinator.

## Decision

Clarification uses a **message convention** (`[CLARIFY:...]` prefix) on existing Tenun channel threads. No new MCP tools, no new DB columns, no new protocol.

Response matching uses **positional detection with coordinator confirmation** (see architecture-coordinator.md §8).

## Alternatives Considered

### New MCP Protocol (Dedicated Clarification Tools)
Add `request_clarification`, `respond_to_clarification`, `list_pending_clarifications` MCP tools with a dedicated `factory_clarifications` DB table.

**Pros:** Structured data. Reliable matching. Queryable history.
**Cons:** New server-side code. Schema changes. Couples Tenun to clarification semantics. Overkill for Phase 1 volume.

**Rejected because:** Violates C-3 (no Tenun server changes for the coordinator). The thread IS the record — adding a parallel DB table creates dual-source-of-truth risk.

### Structured Thread Messages (JSON in Thread)
Post clarifications as JSON objects in the thread. Parse responses from JSON replies.

**Pros:** Machine-readable. Easy to parse.
**Cons:** Unreadable for humans browsing the thread. Breaks the natural chat flow. Humans must write JSON to respond.

**Rejected because:** The channel thread should be human-readable. The whole point of posting to threads is ambient awareness for the human.

## Consequences

### Positive
- Zero server-side changes
- Human-readable thread history
- Natural reply flow (human just types an answer)
- `[CLARIFY:...]` prefix is machine-parseable AND human-scannable
- Thread is the single source of truth for clarification history
- Spec amendment proposals (Job F) naturally extend this convention

### Negative
- Response matching is heuristic (positional + confirmation), not deterministic
- Thread polling has latency (depends on `search_messages` poll interval)
- Multiple pending clarifications require disambiguation (coordinator asks "which question?")

### Mitigations
- Coordinator confirmation step catches mismatched responses (~10s latency)
- Poll interval can be tuned (every 30s for active clarifications, longer otherwise)
- Phase 2 can add `get_thread_replies_after` MCP tool if polling proves insufficient
