# Dark Factory Coordinator — Prioritization

**Date:** 2026-04-09
**Feature:** dark-factory (coordinator agent extension)
**Phase:** DISCUSS — Phase 2.5 Story Mapping

---

## Prioritization Framework

Stories prioritized by: **outcome impact** (from JTBD opportunity scores) x **dependency position** (blocks other stories) x **risk reduction** (addresses unknowns early).

---

## Priority Order

### P0: Walking Skeleton (Slice 1) — Ship first

| Story | Rationale |
|-------|-----------|
| S1: Queue run | Entry point. Trivial (already exists in Phase 1 MCP). |
| S2: Coordinator polls + claims | Core coordinator loop. Must work before anything else. |
| S3: Spawn worktree agent | Proves worktree isolation works with Claude Code `isolation: "worktree"`. Highest technical risk — validate early. |
| S4: Heartbeat delegation | Required to keep claims alive. Low complexity. |
| S5: Submit result | Closes the implementation loop. |
| S6-S8: Verification flow | Completes end-to-end pipeline. Proves Tier 2 isolation works. |
| S9: Human review | Minimal — human reads thread and checks out branch. |

**Why first:** This is the critical path. Every other feature depends on the coordinator loop working. Technical risk concentrates in S3 (spawning worktree agents from a coordinator session) and S7 (verification isolation). Validate both early.

**Estimated scope:** ~1 day to implement coordinator skill + prompts. Phase 1 backend (MCP tools, context module) must exist first.

### P1: Clarification Threading (Slice 2) — Ship second

| Story | Rationale |
|-------|-----------|
| S10: Agent requests clarification | Opportunity score 15 (Job B). Enables factory to handle real specs. |
| S11: Forward human reply | Closes the clarification loop. Thread polling is the main technical unknown. |
| S12: Timeout fallback | Safety valve. Prevents infinite waits. |
| S15: Structured progress | Low effort, high UX value. Piggybacks on existing heartbeat. |

**Why second:** Without clarification, the factory only works for perfect specs. This is the feature that makes unattended execution (Job A) practical for daily use. The response-matching design question (Open Question #3 from the coordinator spec) must be resolved before implementation.

**Estimated scope:** ~0.5 day. Mostly prompt engineering + thread polling logic.

### P2: Concurrent Execution (Slice 3) — Ship third

| Story | Rationale |
|-------|-----------|
| S13: N concurrent agents | Opportunity score 13 (Job C). Multiplies factory throughput. |
| S14: Claim as slots free | Natural extension of the poll loop. |

**Why third:** Concurrency amplifies the value of everything built in P0 and P1. But it's not blocking — a single-agent coordinator still delivers end-to-end value. Building it after clarification means concurrent runs can also ask questions.

**Estimated scope:** ~0.5 day. Coordinator loop already polls; adding a counter and spawning multiple agents is incremental.

### P3: Crash Resilience (Slice 4) — Ship fourth

| Story | Rationale |
|-------|-----------|
| S16: Crash recovery (worktree discovery) | Opportunity score 13 (Job E). Makes concurrent execution safe. |
| S17: Resume heartbeating | Prevents stale claim release for recoverable runs. |

**Why fourth:** Crash resilience becomes critical once concurrency is enabled — a crash during 2-3 concurrent runs loses 2-3x as much work. The LifecycleWorker already handles the server-side timeout gracefully; this adds client-side recovery.

**Estimated scope:** ~0.5 day. Worktree discovery + DB state reconciliation.

### P4: Spec Refinement (Slice 5) — Ship last

| Story | Rationale |
|-------|-----------|
| S18: Collect clarification Q&A | Low complexity — read thread messages. |
| S19: Propose amendments | Prompt engineering — format Q&A into spec diffs. |
| S20: Human approves amendments | Thread-based approval. |

**Why last:** Valuable virtuous cycle but not blocking. The factory delivers full value without it. Each earlier slice delivers incrementally more value; this one improves the input quality for future runs.

**Estimated scope:** ~0.5 day. Mostly prompt engineering + thread message collection.

---

## Dependency on Phase 1 Backend

All coordinator stories depend on the Phase 1 implementation plan (`docs/feature/dark-factory/deliver/plan.md`) being complete:

| Phase 1 Task | Coordinator Stories That Depend On It |
|-------------|--------------------------------------|
| Task 1: Migration | All (tables must exist) |
| Task 2: Schemas | All (Run/Event structs) |
| Task 3-6: Factory context | S1-S9 (queue, claim, heartbeat, submit, verify) |
| Task 7: LifecycleWorker | S16-S17 (crash recovery relies on timeout release) |
| Task 8: ChannelNotifier | S4, S10, S15 (thread messages) |
| Task 9: MCP FactoryTools | S1-S9 (coordinator calls these tools) |

**The coordinator is a client of Phase 1.** It does not modify Phase 1 code.

---

## Risk Matrix

| Risk | Likelihood | Impact | Mitigation | Slice |
|------|-----------|--------|------------|-------|
| Worktree agent spawn doesn't work with Claude Code `isolation: "worktree"` | Medium | High | Test S3 in walking skeleton first | P0 |
| Verification isolation violated (agent reads impl context) | Low | High | Prompt discipline + manual review of first few runs | P0 |
| Thread polling too slow/unreliable for clarification matching | Medium | Medium | Start with simple polling; add `get_thread_replies_after` if needed | P1 |
| Response matching ambiguity (human reply to wrong question) | Medium | Medium | Resolve Open Question #3 before P1 implementation | P1 |
| Concurrent compiles exhaust machine resources | Medium | Medium | Default concurrency=2, monitor memory, auto-throttle | P2 |
| Coordinator crash during concurrent runs loses significant work | Medium | High | P3 (crash resilience) must follow P2 closely | P3 |
| Clarifying agents block concurrency slots indefinitely | Low | Medium | Define whether clarifying counts toward limit in P1 | P1 |
