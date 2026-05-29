# Dark Factory Coordinator — Acceptance Criteria

**Date:** 2026-04-09
**Feature:** dark-factory (coordinator agent extension)
**Phase:** DISCUSS — Phase 3 Requirements

---

## Slice 1: Walking Skeleton (P0)

### AC-1: End-to-end unattended pipeline
```gherkin
Given the coordinator is running and a spec is queued
When no human interacts with the coordinator
Then the run progresses through: queued -> implementing -> awaiting_verification -> verifying_tier2 -> completed
And the channel thread shows status updates at each transition
And a feature branch and verification branch exist for human review
```

### AC-2: Automatic polling and claiming
```gherkin
Given 2 runs are queued
When the coordinator polls on its next cycle
Then it claims the oldest queued run
And spawns an agent in .factory/run-{id}/ worktree
And the run transitions to "implementing"
```

### AC-3: Heartbeat keeps claims alive
```gherkin
Given an agent is implementing run-42
When the coordinator heartbeats every 5 minutes with progress messages
Then run-42's last_heartbeat_at is updated
And the thread shows progress messages
And the LifecycleWorker does not release the claim
```

### AC-4: Success submission advances to verification
```gherkin
Given run-42's agent completes with all pre-deploy checks passing
When the coordinator submits success with the branch name
Then the run transitions to "awaiting_verification"
And the thread shows "Implementation complete — awaiting Tier 2 verification"
```

### AC-5: Failure with retries
```gherkin
Given run-42 is on attempt 1 of 3 and the agent fails
When the coordinator submits failure
Then the run stays "implementing" with attempt=2
And the agent retries with failure context
```

### AC-6: Failure exhausted
```gherkin
Given run-42 is on attempt 3 of 3 and the agent fails
When the coordinator submits failure
Then the run transitions to "needs_review"
And the thread shows "All 3 attempts exhausted"
```

### AC-7: Verification isolation
```gherkin
Given run-42 is "awaiting_verification"
When the coordinator spawns a verification agent
Then the agent receives: spec_path, spec_commit_sha, branch_name
And the agent does NOT receive: tier1_result, implementation context, progress messages
And the agent reads the spec BEFORE checking out the implementation branch
```

### AC-8: Verification pass
```gherkin
Given the verification agent generated 5 scenarios and all pass
When the coordinator submits verification
Then the run transitions to "completed"
And the thread shows "Tier 2 passed (5/5) — ready for review"
And the verification branch is pushed as factory/verify-run-{id}
```

### AC-9: Verification fail (never retries)
```gherkin
Given the verification agent generated 5 scenarios and 2 fail
When the coordinator submits verification
Then the run transitions to "needs_review" (NOT back to "awaiting_verification")
And the thread includes failure details
And the verification branch is pushed for human inspection
```

### AC-10: Worktree cleanup
```gherkin
Given run-42 has reached a terminal state (completed, needs_review, or cancelled)
When the coordinator detects the terminal state
Then it removes the .factory/run-42/ worktree
And the workspace is clean
```

---

## Slice 2: Clarification Threading (P1)

### AC-11: Clarification request posted to thread
```gherkin
Given the implementing agent encounters a high-stakes ambiguity
When the agent sends a clarification request to the coordinator
Then the coordinator posts to the run's thread:
  "[CLARIFY:run-42:spec:acceptance-criteria:3] <question>"
And the agent is paused (state: clarifying)
And the coordinator continues heartbeating for this run
```

### AC-12: Low-stakes ambiguity handled without clarification
```gherkin
Given the implementing agent encounters a minor ambiguity
And the wrong guess would affect at most 1 test case
When the agent assesses confidence
Then it makes an assumption and documents it in the PR description
And does NOT post a clarification to the thread
```

### AC-13: Human reply forwarded to agent
```gherkin
Given a clarification was posted for run-42
When the human replies in the thread with an answer
Then the coordinator detects the reply
And forwards it to the waiting agent
And the thread shows "Clarification received, resuming"
And the agent continues implementing
```

### AC-14: Clarification timeout (assume)
```gherkin
Given a clarification was posted 2 hours ago with no human response
When the timeout expires
Then the coordinator posts a timeout notice
And the agent makes a reasonable assumption and documents it
And the agent continues implementing
```

### AC-15: Clarification timeout (fail on fundamental ambiguity)
```gherkin
Given a fundamental clarification was posted 2 hours ago with no response
When the timeout expires and the agent cannot reasonably assume
Then the agent submits failure with reason "blocked on clarification"
```

### AC-16: Other agents unaffected
```gherkin
Given agent-1 is waiting for clarification on run-42
And agent-2 is implementing run-57
Then agent-2 continues normally
And both runs continue receiving heartbeats
```

### AC-17: Structured progress messages
```gherkin
Given run-42's agent is on step 3 of 7
When the coordinator heartbeats
Then the thread shows "[Factory: bulk-import] Implementing step 3/7: CSV parser module"
```

---

## Slice 3: Concurrent Execution (P2)

### AC-18: Concurrency limit respected
```gherkin
Given 5 runs are queued and the concurrency limit is 2
When the coordinator polls
Then it claims and spawns agents for exactly 2 runs
And 3 runs remain queued
```

### AC-19: Backfill on completion
```gherkin
Given 2 agents are running (at concurrency limit) and 1 run is queued
When agent-1 completes
Then the coordinator claims the queued run on the next poll cycle
And spawns a new agent in a fresh worktree
```

### AC-20: Isolated worktrees
```gherkin
Given 2 agents are running concurrently
Then each agent has its own .factory/run-{id}/ worktree
And each worktree has its own _build directory
And compilation in one worktree does not affect the other
```

---

## Slice 4: Crash Resilience (P3)

### AC-21: Worktree discovery
```gherkin
Given the coordinator crashed while run-42 was implementing
And .factory/run-42/ worktree exists with partial work
When the coordinator restarts
Then it discovers the orphaned worktree
And checks DB state for run-42
```

### AC-22: Resume recoverable run
```gherkin
Given run-42 is still "implementing" in DB (timeout hasn't elapsed)
And .factory/run-42/ worktree exists
When the coordinator restarts
Then it re-claims run-42 and resumes heartbeating
And reuses the existing worktree (does not start from scratch)
```

### AC-23: Clean up released run
```gherkin
Given run-42 was released by LifecycleWorker (back to "queued")
And .factory/run-42/ worktree exists
When the coordinator restarts
Then it removes the orphaned worktree
And lets run-42 be re-claimed naturally (fresh worktree on next claim)
```

---

## Slice 5: Spec Refinement (P4)

### AC-24: Collect clarification Q&A
```gherkin
Given run-42 had 2 clarification Q&A exchanges
When run-42 reaches a terminal state
Then the coordinator collects all [CLARIFY:...] messages and their replies
```

### AC-25: Propose amendments
```gherkin
Given clarification Q&A was collected for run-42
When the coordinator generates amendments
Then it posts [SPEC-AMENDMENT:run-42] to the thread
With specific original/proposed text for each amendment
And asks the human to approve or reject
```

### AC-26: Amendments require approval
```gherkin
Given amendments were proposed for run-42
When the human has not explicitly approved
Then the spec is NOT modified
And amendments are preserved in the thread for future reference
```
