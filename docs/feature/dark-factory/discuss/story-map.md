# Dark Factory Coordinator — User Story Map

**Date:** 2026-04-09
**Feature:** dark-factory (coordinator agent extension)
**Phase:** DISCUSS — Phase 2.5 Story Mapping

---

## Backbone (User Activities)

These are the big horizontal activities the human performs, left to right:

```
WRITE SPEC ──> QUEUE WORK ──> COORDINATE ──> MONITOR ──> CLARIFY ──> VERIFY ──> REVIEW ──> REFINE SPEC
    |              |              |             |            |           |          |            |
    v              v              v             v            v           v          v            v
 (manual,      (MCP tool)    (coordinator   (thread     (thread     (separate  (human       (feedback
  outside                     agent)         updates)    Q&A)        agent)     reviews       loop)
  factory)                                                                      branch)
```

---

## Story Map Grid

### Row 1: Walking Skeleton (MVP — end-to-end value)

The thinnest slice that delivers unattended execution through independent verification.

| Activity | Story | Job |
|----------|-------|-----|
| Queue | S1: Queue a factory run via MCP | A, G |
| Coordinate | S2: Coordinator polls and claims work automatically | A, G |
| Coordinate | S3: Coordinator spawns worktree-isolated agent | A, C |
| Monitor | S4: Coordinator heartbeats on behalf of agents | A, D |
| Coordinate | S5: Coordinator submits result on agent completion | A, G |
| Verify | S6: Coordinator claims verification work and spawns verifier | H |
| Verify | S7: Verification agent reads spec only, generates scenarios | H |
| Verify | S8: Verification agent runs scenarios, coordinator submits | H |
| Review | S9: Human reviews completed branch from thread notification | A |

**Walking skeleton scope:** Single run, single agent (concurrency=1), no clarification, no crash recovery, no spec refinement. Proves the coordinator can drive a run from queue to completion unattended.

### Row 2: Clarification + Concurrent Execution

Adds the two features that make the coordinator practical for real specs.

| Activity | Story | Job |
|----------|-------|-----|
| Clarify | S10: Agent requests clarification via coordinator -> thread | B |
| Clarify | S11: Coordinator detects human reply, forwards to agent | B |
| Clarify | S12: Clarification timeout with assume-or-fail fallback | B |
| Coordinate | S13: Coordinator runs up to N agents concurrently | C |
| Coordinate | S14: Coordinator claims new work as slots free up | C |
| Monitor | S15: Structured progress messages (step N/M format) | D |

### Row 3: Resilience + Spec Refinement

Adds safety and the feedback loop.

| Activity | Story | Job |
|----------|-------|-----|
| Coordinate | S16: Coordinator recovers from crash (worktree discovery) | E |
| Coordinate | S17: Coordinator resumes heartbeating for recoverable runs | E |
| Refine Spec | S18: Coordinator collects clarification Q&A post-run | F |
| Refine Spec | S19: Coordinator proposes spec amendments in thread | F |
| Refine Spec | S20: Human approves/rejects amendments | F |

---

## Story Dependencies

```
S1 (queue) ─────────────────────┐
                                v
S2 (poll + claim) ──> S3 (spawn agent) ──> S4 (heartbeat) ──> S5 (submit)
                          |                                        |
                          v                                        v
                     S13 (concurrency)                    S6 (claim verif)
                                                               |
                                                               v
                                                     S7 (spec only) ──> S8 (run + submit)
                                                                              |
                                                                              v
                                                                        S9 (human review)

S10 (ask clarification) ──> S11 (forward reply) ──> S12 (timeout)
        |
        └──> S18 (collect Q&A) ──> S19 (propose amendments) ──> S20 (approve)

S16 (crash recovery) ──> S17 (resume heartbeating)
```

**Critical path:** S1 -> S2 -> S3 -> S4 -> S5 -> S6 -> S7 -> S8 -> S9 (walking skeleton)

---

## Release Slices

### Slice 1: Walking Skeleton (S1-S9)
**Outcome:** Coordinator can drive a single factory run from queue to completed, unattended.
**Value:** Proves the concept works end-to-end. Human can queue, walk away, come back to a verified branch.
**Constraint:** Single run at a time (concurrency=1). No clarification — agent must handle all ambiguities by assuming.

### Slice 2: Clarification Threading (S10-S12, S15)
**Outcome:** Agents can ask questions when specs are ambiguous. Human answers in the thread.
**Value:** Factory works for imperfect specs. Dramatically reduces wasted cycles from wrong assumptions.
**Constraint:** Still single-run. But the coordinator's clarification relay is general-purpose.

### Slice 3: Concurrent Execution (S13-S14)
**Outcome:** Coordinator runs multiple agents in parallel up to configurable limit.
**Value:** 2-3x throughput improvement. Queue drains meaningfully faster.
**Constraint:** No crash recovery yet — crashes during concurrent runs lose more work.

### Slice 4: Crash Resilience (S16-S17)
**Outcome:** Coordinator can recover from crashes by discovering orphaned worktrees and resuming.
**Value:** Makes concurrent execution safe. Human can walk away with confidence.
**Constraint:** Recovery is best-effort — some edge cases may require manual cleanup.

### Slice 5: Spec Refinement (S18-S20)
**Outcome:** Specs improve automatically through use. Clarification Q&A feeds back into the spec.
**Value:** Virtuous cycle — each factory run makes future runs smoother.
**Constraint:** Requires human approval for each amendment. Not fully autonomous.
