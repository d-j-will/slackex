# Dark Factory Coordinator — Acceptance Test Review

**Date:** 2026-04-09
**Wave:** DISTILL (wave 5 of 6)

---

## Coverage Analysis

### All 26 Acceptance Criteria Covered

| AC | Description | Layer 1 (ExUnit) | Layer 2 (Behavioral) | Driving Port |
|----|------------|:----------------:|:-------------------:|-------------|
| AC-1 | End-to-end pipeline | WS-1, IC-3 | WS-B1, WS-B2 | `Factory.queue_run/1` through full chain |
| AC-2 | Auto poll and claim | Claim FIFO test | WS-B1 | `Factory.list_pending/1` + `Factory.claim_run/2` |
| AC-3 | Heartbeat keeps claims | Heartbeat + lifecycle | WS-B1 | `Factory.heartbeat/3` |
| AC-4 | Success -> verification | Submit success tests | WS-B1 | `Factory.submit_result/2` |
| AC-5 | Failure + retry | Submit failure (retry) | — | `Factory.submit_result/2` |
| AC-6 | Failure exhausted | Submit failure (exhausted) | — | `Factory.submit_result/2` |
| AC-7 | Verification isolation | list_pending_verification test | WS-B2 | `Factory.list_pending_verification/1` |
| AC-8 | Verification pass | Submit verif (pass) | WS-B2 | `Factory.submit_verification/2` |
| AC-9 | Verification fail | Submit verif (fail) | — | `Factory.submit_verification/2` |
| AC-10 | Worktree cleanup | — | WS-B4 | Coordinator behavior |
| AC-11 | Clarification posted | — | CL-1 | Coordinator behavior |
| AC-12 | Low-stakes assumption | — | CL-4 | Coordinator behavior |
| AC-13 | Reply forwarded | — | CL-2 | Coordinator behavior |
| AC-14 | Timeout (assume) | — | CL-3 | Coordinator behavior |
| AC-15 | Timeout (fail) | — | CL-3 | Coordinator behavior |
| AC-16 | Other agents unaffected | — | CL-5 | Coordinator behavior |
| AC-17 | Structured progress | — | WS-B1 | Coordinator behavior |
| AC-18 | Concurrency limit | — | CC-1 | Coordinator behavior |
| AC-19 | Backfill on completion | — | CC-2 | Coordinator behavior |
| AC-20 | Isolated worktrees | — | CC-3 | Coordinator behavior |
| AC-21 | Worktree discovery | Release edge cases | CR-1 | `Factory.release_stale_claims/0` |
| AC-22 | Resume recoverable | — | CR-1 | Coordinator behavior |
| AC-23 | Clean up released | Release edge cases | CR-2 | Coordinator behavior |
| AC-24 | Collect Q&A | — | SR-1 | Coordinator behavior |
| AC-25 | Propose amendments | — | SR-1 | Coordinator behavior |
| AC-26 | Amendments need approval | — | SR-2, SR-3 | Coordinator behavior |

### Coverage by Layer

- **Layer 1 only (automated):** AC-5, AC-6, AC-9 — pure state machine behavior, no coordinator involvement
- **Both layers:** AC-1, AC-2, AC-3, AC-4, AC-7, AC-8, AC-21 — backend + coordinator
- **Layer 2 only (behavioral):** AC-10 through AC-20, AC-22 through AC-26 — coordinator behavior

### Gap: 16 of 26 ACs are Layer 2 only

This is expected and acceptable. The coordinator is a Claude Code session, not compiled code. Its acceptance criteria can only be verified by running it. Phase 2 (Agent SDK migration) enables automated testing of coordinator behavior.

**Mitigation:** The walking skeleton behavioral test (WS-B1 through WS-B4) should be the first thing run after implementing Slice 1. This provides early signal on the coordinator's core loop.

---

## Integration Checkpoint Rationale

Four integration checkpoints (IC-1 through IC-4) are included specifically because of CLAUDE.md's spec-driven acceptance test mandate:

> Every spec that introduces a PubSub event bridge, Oban job pipeline, or cross-context integration point must have at least one integration test that verifies the full producer → consumer path exists.

The dark factory has all three:
1. **PubSub event bridge:** `Factory.broadcast_update/1` -> `"factory:events"` topic -> `ChannelNotifier`
2. **Oban job pipeline:** `LifecycleWorker` cron -> `Factory.release_stale_claims/0`
3. **Cross-context integration:** `Factory` -> `Messaging.send_message/4` (via ChannelNotifier)

IC-1 verifies the PubSub bridge exists (not just that handlers work when faked).
IC-2 verifies the ChannelNotifier actually creates messages (not just that it subscribes).
IC-3 verifies the MCP transport works end-to-end (not just that context functions work).
IC-4 verifies the feature flag guards ALL entry points (not just one).

---

## Upstream Issues

No contradictions found between DISCUSS acceptance criteria and DESIGN architecture decisions.

One clarification added:
- **AC-7 refinement:** DISCUSS says "agent does NOT receive tier1_result." The DESIGN architecture confirms this is enforced at the MCP level: `list_verification_work` excludes `tier1_result` from its response. The ExUnit test for `list_pending_verification/1` should assert the returned struct does NOT include implementation details. However, `list_pending_verification/1` returns full `Run` structs from the DB — the field IS on the struct but should not be passed to the verification agent. The isolation is enforced by the coordinator's prompt (it only passes spec_path, spec_commit_sha, branch_name), not by the query. This is documented but not a contradiction.

---

## Test Execution Order

### Phase 1 Implementation (DELIVER wave)

Tests should be written and run in this order, matching the implementation plan's task sequence:

1. **Task 1-2:** Migration + schemas (compile check only)
2. **Task 3:** Context queue + list tests (factory_test.exs, first describe blocks)
3. **Task 4:** Claim tests (factory_test.exs, claim describe block)
4. **Task 5:** Heartbeat + submit + cancel tests
5. **Task 6:** Verification tests
6. **Task 7:** LifecycleWorker tests (lifecycle_worker_test.exs)
7. **NEW — Task 7.5:** Pipeline integration tests (pipeline_test.exs) — PubSub wiring, full traversal
8. **Task 8:** ChannelNotifier (channel_notifier_test.exs) — wiring test
9. **Task 9-10:** MCP tools + integration tests (factory_tools_test.exs)
10. **Task 11:** Dialyzer + full suite

### Coordinator Slices (post-Phase 1)

Run Layer 2 behavioral tests after each coordinator slice ships:
- After Slice 1: WS-B1 through WS-B4
- After Slice 2: CL-1 through CL-5
- After Slice 3: CC-1 through CC-3
- After Slice 4: CR-1, CR-2
- After Slice 5: SR-1 through SR-3
