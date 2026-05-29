# Dark Factory Coordinator — Walking Skeleton

**Date:** 2026-04-09
**Wave:** DISTILL (wave 5 of 6)
**Input:** `discuss/story-map.md` Slice 1, `discuss/acceptance-criteria.md` AC-1 through AC-10

---

## Walking Skeleton Definition

The walking skeleton proves the thinnest end-to-end path: **a single factory run goes from queued to completed without human intervention** (other than the initial queue and final review).

### Path Under Test

```
queue_factory_run -> list_factory_work -> claim_factory_work -> [agent implements]
  -> factory_heartbeat -> submit_factory_result(success) -> list_verification_work
  -> claim_verification_work -> [verifier generates scenarios] -> submit_verification(pass)
  -> run.status == "completed"
```

### Two Testing Layers

**Layer 1: ExUnit integration tests (automated, CI)**
Tests the Phase 1 backend: Factory context state machine, MCP tool dispatch, event audit trail, LifecycleWorker timeouts, ChannelNotifier wiring. These run in CI on every push.

**Layer 2: Coordinator behavioral acceptance (manual, first-run)**
Tests the coordinator skill: poll loop, agent spawning, heartbeat delegation, result submission, worktree lifecycle. These are executed by running the coordinator against a real queued spec and observing thread output. Automated coordinator testing is Phase 2 scope.

### Walking Skeleton Scenarios (Layer 1 — automated)

These 5 scenarios prove the backend pipeline works end-to-end. They must ALL pass before any coordinator work begins.

| # | Scenario | Driving Port | Observable Outcome |
|---|----------|-------------|-------------------|
| WS-1 | Full pipeline: queue -> implement -> verify -> complete | `Factory.queue_run/1` | Run reaches `completed` status with `tier2_result` populated |
| WS-2 | Failure + retry: implement fails, retries, succeeds | `Factory.submit_result/2` | Run stays `implementing` on first failure, advances on second success |
| WS-3 | Failure exhausted: all attempts fail | `Factory.submit_result/2` | Run reaches `needs_review` after max_attempts failures |
| WS-4 | Timeout release: stale claim released by LifecycleWorker | `Factory.release_stale_claims/0` | Run returns to `queued` (implementing) or `awaiting_verification` (verifying) |
| WS-5 | MCP round-trip: full pipeline via MCP HTTP interface | `POST /mcp` (tools/call) | Same as WS-1 but exercised through MCP transport layer |

### Walking Skeleton Scenarios (Layer 2 — behavioral)

These are verified by running the coordinator against a real queued spec. Pass criteria are thread observations.

| # | Scenario | Human Action | Observable Outcome (Thread) |
|---|----------|-------------|----------------------------|
| WS-B1 | Coordinator claims and implements | Start coordinator, queue a trivial spec | Thread shows: queued -> claimed -> progress updates -> implementation complete |
| WS-B2 | Coordinator verifies independently | Wait for WS-B1 to reach awaiting_verification | Thread shows: verification started -> Tier 2 passed -> ready for review |
| WS-B3 | Branches exist for review | Check git after WS-B2 | `factory/run-{id}` and `factory/verify-run-{id}` branches exist |
| WS-B4 | Worktree cleaned up | Check filesystem after WS-B2 | `.factory/run-{id}/` directory removed |

---

## Walking Skeleton First Spec

For the coordinator's first real test, use a deliberately simple spec:

```markdown
# Test Feature: Add factory_run_count to bot user profile

## Acceptance Criteria
1. Bot user's profile page shows "Factory runs: N" where N is the count of completed factory runs
2. Count updates after each completed run
3. Count is 0 for bot users with no completed runs

## Constraints
- Read-only query, no new tables
- Feature-flagged behind :dark_factory
```

This spec is:
- Small enough to complete in one attempt
- Testable (clear acceptance criteria)
- Low risk (read-only, feature-flagged)
- Exercises the full pipeline including Tier 2 verification
