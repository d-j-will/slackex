# Dark Factory Coordinator — Test Scenarios

**Date:** 2026-04-09
**Wave:** DISTILL (wave 5 of 6)
**Input:** `discuss/acceptance-criteria.md` (26 ACs), `design/architecture-coordinator.md`, `design/component-boundaries.md`

---

## Test Organization

Tests are organized by release slice (matching story-map.md priority order). Each acceptance criterion maps to one or more ExUnit test cases with a named driving port.

### Port Boundaries

| Port | Type | Module | Test Method |
|------|------|--------|------------|
| `Factory.queue_run/1` | Context function | `Slackex.Factory` | Direct call in ExUnit |
| `Factory.claim_run/2` | Context function | `Slackex.Factory` | Direct call in ExUnit |
| `Factory.heartbeat/3` | Context function | `Slackex.Factory` | Direct call in ExUnit |
| `Factory.submit_result/2` | Context function | `Slackex.Factory` | Direct call in ExUnit |
| `Factory.claim_verification/1` | Context function | `Slackex.Factory` | Direct call in ExUnit |
| `Factory.submit_verification/2` | Context function | `Slackex.Factory` | Direct call in ExUnit |
| `Factory.cancel_run/2` | Context function | `Slackex.Factory` | Direct call in ExUnit |
| `Factory.release_stale_claims/0` | Context function | `Slackex.Factory` | Direct call in ExUnit |
| `POST /mcp` (tools/call) | HTTP endpoint | `SlackexWeb.MCP.Server` | ConnCase + JSON-RPC |
| PubSub `"factory:events"` | Broadcast | `Phoenix.PubSub` | Subscribe + assert_receive |
| ChannelNotifier | GenServer | `Factory.ChannelNotifier` | PubSub broadcast + message assertion |

---

## Slice 1: Walking Skeleton (P0)

### AC-1: End-to-end unattended pipeline
**Driving port:** `Factory.queue_run/1` through `Factory.submit_verification/2`
**Test file:** `test/slackex/factory/pipeline_test.exs`

```elixir
# Full pipeline integration test — exercises every state transition
describe "full pipeline" do
  test "queue -> claim -> submit success -> claim verification -> verify pass -> completed"
  # Exercises: queue_run, claim_run, heartbeat, submit_result(success),
  #            claim_verification, submit_verification(pass)
  # Asserts: final status == "completed", tier2_result populated,
  #          events audit trail has all transitions,
  #          PubSub broadcast received for each transition
end
```

### AC-2: Automatic polling and claiming
**Driving port:** `Factory.list_pending/1` + `Factory.claim_run/2`
**Test file:** `test/slackex/factory_test.exs` (existing)
**Note:** Coordinator polling behavior is Layer 2 (behavioral). Backend claim mechanics are Layer 1.

```elixir
describe "claim_run/2" do
  test "claims oldest queued run (FIFO order)"
  test "atomic: concurrent claims on same run — only one succeeds"
end
```

### AC-3: Heartbeat keeps claims alive
**Driving port:** `Factory.heartbeat/3` + `Factory.release_stale_claims/0`
**Test file:** `test/slackex/factory_test.exs`

```elixir
describe "heartbeat interaction with LifecycleWorker" do
  test "run with recent heartbeat is NOT released by release_stale_claims"
  test "run with stale heartbeat IS released by release_stale_claims"
end
```

### AC-4: Success submission advances to verification
**Driving port:** `Factory.submit_result/2`
**Test file:** `test/slackex/factory_test.exs`

```elixir
describe "submit_result/2 success path" do
  test "transitions implementing -> awaiting_verification"
  test "stores branch_name and tier1_result"
  test "appends status_change event"
  test "broadcasts {:factory_run_updated, run} on PubSub"
end
```

### AC-5 + AC-6: Failure with retries / exhausted
**Driving port:** `Factory.submit_result/2`
**Test file:** `test/slackex/factory_test.exs`

```elixir
describe "submit_result/2 failure path" do
  test "attempts remaining: stays implementing, increments attempt"
  test "attempts exhausted: transitions to needs_review"
  test "events record each failure with metadata"
end
```

### AC-7: Verification isolation
**Driving port:** `Factory.list_pending_verification/1`
**Test file:** `test/slackex/factory_test.exs`

```elixir
describe "list_pending_verification/1" do
  test "returns spec_path, spec_commit_sha, branch_name"
  test "does NOT return tier1_result"
  test "does NOT return claim_token from implementation phase"
end
```

### AC-8 + AC-9: Verification pass / fail
**Driving port:** `Factory.submit_verification/2`
**Test file:** `test/slackex/factory_test.exs`

```elixir
describe "submit_verification/2" do
  test "pass: transitions to completed, stores tier2_result, sets completed_at"
  test "fail: transitions to needs_review (never back to awaiting_verification)"
  test "fail: tier2_result includes failure details"
end
```

### AC-10: Worktree cleanup
**Note:** Worktree cleanup is coordinator behavior (Layer 2). No ExUnit test — verified by running the coordinator.

---

## Slice 1: Integration Checkpoints

These tests verify wiring between components — the exact category of test that CLAUDE.md mandates after the v0.5.47 incident.

### IC-1: PubSub wiring — state transitions broadcast events
**Driving port:** `Factory.queue_run/1` (and each subsequent transition)
**Test file:** `test/slackex/factory/pipeline_test.exs`

```elixir
describe "PubSub wiring" do
  setup do
    Phoenix.PubSub.subscribe(Slackex.PubSub, "factory:events")
  end

  test "queue_run broadcasts {:factory_run_updated, run}" do
    {:ok, run} = Factory.queue_run(valid_attrs())
    assert_receive {:factory_run_updated, ^run}, 1000
  end

  test "claim_run broadcasts {:factory_run_updated, run}" do
    # ... claim and assert_receive
  end

  test "submit_result broadcasts {:factory_run_updated, run}" do
    # ... submit and assert_receive
  end

  test "submit_verification broadcasts {:factory_run_updated, run}" do
    # ... verify and assert_receive
  end
end
```

### IC-2: ChannelNotifier wiring — PubSub events trigger thread messages
**Driving port:** `Factory.queue_run/1` -> PubSub -> ChannelNotifier -> `Messaging.send_message/4`
**Test file:** `test/slackex/factory/channel_notifier_test.exs`

```elixir
describe "ChannelNotifier integration" do
  test "queue_run triggers a message in the run's channel" do
    {:ok, run} = Factory.queue_run(valid_attrs())
    # Wait for ChannelNotifier to process PubSub message
    Process.sleep(100)
    # Assert a message was created in the channel
    messages = Messaging.list_messages(run.channel_id, limit: 5)
    assert Enum.any?(messages, &String.contains?(&1.content, "queued"))
  end
end
```

### IC-3: MCP round-trip — full pipeline via HTTP
**Driving port:** `POST /mcp` with JSON-RPC
**Test file:** `test/slackex_web/mcp/factory_tools_test.exs` (existing, expanded)

```elixir
describe "full pipeline via MCP" do
  test "queue -> list -> claim -> heartbeat -> submit -> verify -> complete"
  # This is the most important integration test.
  # It exercises: HTTP layer, MCP dispatch, FactoryTools, Factory context,
  #               Ecto, PubSub, and state machine — all in one path.
  # Already defined in the Phase 1 plan (Task 10).
end
```

### IC-4: Feature flag guards all entry points
**Driving port:** `POST /mcp` with `:dark_factory` disabled
**Test file:** `test/slackex_web/mcp/factory_tools_test.exs`

```elixir
describe "feature flag" do
  test "tools/list excludes factory tools when flag disabled"
  test "tools/call returns error for factory tools when flag disabled"
  test "LifecycleWorker skips release_stale_claims when flag disabled"
  test "ChannelNotifier skips posting when flag disabled"
end
```

---

## Slice 2: Clarification Threading (P1)

**Note:** Clarification is entirely coordinator-side (Claude Code behavior). No new ExUnit tests needed for the Phase 1 backend. The acceptance criteria (AC-11 through AC-17) are verified via Layer 2 behavioral tests.

### Behavioral Test Script (Layer 2)

| # | Test | Human Action | Observe |
|---|------|-------------|---------|
| CL-1 | Agent asks clarification | Queue a spec with deliberate ambiguity | Thread shows `[CLARIFY:run-{id}:...]` message |
| CL-2 | Human reply forwarded | Reply to clarification in thread | Thread shows "Clarification received, resuming" |
| CL-3 | Timeout fallback | Don't reply for 2 hours | Thread shows timeout notice, agent assumes or fails |
| CL-4 | Low-stakes assumption | Queue spec with minor ambiguity | Agent does NOT ask; assumption documented in PR |
| CL-5 | Multiple clarifications | Queue spec with 2+ ambiguities | Both tracked independently; answering one doesn't affect the other |

---

## Slice 3: Concurrent Execution (P2)

### Behavioral Test Script (Layer 2)

| # | Test | Setup | Observe |
|---|------|-------|---------|
| CC-1 | Two runs in parallel | Queue 3 specs, set concurrency=2 | 2 agents spawn, 3rd waits. Thread shows parallel progress. |
| CC-2 | Backfill on completion | Wait for one agent to complete | 3rd run claimed on next poll cycle |
| CC-3 | Isolated worktrees | Check `.factory/` during CC-1 | Two separate `run-{id}/` directories, each with own `_build/` |

---

## Slice 4: Crash Resilience (P3)

### ExUnit Tests (Layer 1)

**Driving port:** `Factory.release_stale_claims/0`
**Test file:** `test/slackex/factory/lifecycle_worker_test.exs` (existing, expanded)

```elixir
describe "release_stale_claims edge cases" do
  test "implementing timeout: reverts to queued, preserves attempt count"
  test "verifying_tier2 timeout: reverts to awaiting_verification"
  test "does not release runs within timeout window"
  test "does not release runs in terminal states"
  test "releases multiple stale runs in one pass"
end
```

### Behavioral Test Script (Layer 2)

| # | Test | Setup | Observe |
|---|------|-------|---------|
| CR-1 | Crash recovery | Kill coordinator during active run | Restart coordinator; it discovers worktree, re-claims run |
| CR-2 | Stale claim cleanup | Kill coordinator, wait for timeout | LifecycleWorker releases claim; coordinator restart cleans orphaned worktree |

---

## Slice 5: Spec Refinement (P4)

### Behavioral Test Script (Layer 2)

| # | Test | Setup | Observe |
|---|------|-------|---------|
| SR-1 | Amendments proposed | Complete a run that had clarifications | Thread shows `[SPEC-AMENDMENT:...]` with proposed changes |
| SR-2 | Approval applies amendment | Reply "approve all" | Spec file updated with clarification answers |
| SR-3 | Rejection preserves spec | Reply "reject all" | Spec file unchanged |

---

## Test Count Summary

### Layer 1 (ExUnit, automated, CI)

| Category | Count | File |
|----------|:-----:|------|
| Factory context (queue, claim, heartbeat, submit, cancel, verify) | ~20 | `factory_test.exs` |
| LifecycleWorker (timeout enforcement) | ~6 | `lifecycle_worker_test.exs` |
| Pipeline integration (full state machine traversal) | ~4 | `pipeline_test.exs` (new) |
| PubSub wiring (broadcast assertions) | ~5 | `pipeline_test.exs` |
| ChannelNotifier wiring | ~3 | `channel_notifier_test.exs` (new) |
| MCP integration (HTTP round-trip) | ~4 | `factory_tools_test.exs` |
| Feature flag guards | ~4 | `factory_tools_test.exs` |
| **Total automated** | **~46** | |

### Layer 2 (Behavioral, coordinator first-run)

| Category | Count |
|----------|:-----:|
| Walking skeleton (WS-B1 through WS-B4) | 4 |
| Clarification (CL-1 through CL-5) | 5 |
| Concurrent execution (CC-1 through CC-3) | 3 |
| Crash resilience (CR-1, CR-2) | 2 |
| Spec refinement (SR-1 through SR-3) | 3 |
| **Total behavioral** | **17** |

---

## Story-to-Test Traceability

| Story | AC | Layer 1 Tests | Layer 2 Tests |
|-------|-----|:------------:|:------------:|
| S1 (Queue) | AC-1 | WS-1, IC-3 | WS-B1 |
| S2 (Poll + claim) | AC-2 | claim FIFO, atomic claim | WS-B1 |
| S3 (Spawn agent) | AC-1 | — | WS-B1 |
| S4 (Heartbeat) | AC-3 | heartbeat + lifecycle | WS-B1 |
| S5 (Submit result) | AC-4,5,6 | submit success/fail/exhausted | WS-B1 |
| S6 (Claim verif) | AC-7 | list_pending_verification isolation | WS-B2 |
| S7 (Spec only) | AC-7 | — | WS-B2 |
| S8 (Run scenarios) | AC-8,9 | submit_verification pass/fail | WS-B2 |
| S9 (Human review) | AC-1 | — | WS-B3 |
| S10 (Ask clarification) | AC-11,12 | — | CL-1, CL-4 |
| S11 (Forward reply) | AC-13 | — | CL-2 |
| S12 (Timeout) | AC-14,15 | — | CL-3 |
| S13 (N concurrent) | AC-18,20 | — | CC-1, CC-3 |
| S14 (Backfill) | AC-19 | — | CC-2 |
| S15 (Progress) | AC-17 | — | WS-B1 |
| S16 (Recovery) | AC-21,22 | release edge cases | CR-1 |
| S17 (Resume heartbeat) | AC-23 | — | CR-1 |
| S18 (Collect Q&A) | AC-24 | — | SR-1 |
| S19 (Propose amendments) | AC-25 | — | SR-1 |
| S20 (Approve) | AC-26 | — | SR-2, SR-3 |

All 20 stories have at least one test. All 26 acceptance criteria are covered.
