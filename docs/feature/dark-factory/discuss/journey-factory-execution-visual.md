# Journey: Factory Execution

**Date:** 2026-04-09
**Jobs served:** A (Unattended Execution), C (Concurrent Throughput), G (Protocol Abstraction), D (Ambient Awareness), E (Crash Resilience)
**Primary persona:** David (human operator)
**Secondary persona:** Coordinator agent (long-lived Claude Code session)

---

## Journey Map

```
PHASE 1: Queue                PHASE 2: Coordinate              PHASE 3: Monitor               PHASE 4: Complete
Human-initiated               Coordinator-driven               Human-observed                  Human-reviewed

[Queue spec via MCP]           [Coordinator polls]              [Thread updates]               [Branch ready]
       |                              |                              |                              |
       v                              v                              v                              v
+----------------+            +------------------+            +------------------+            +------------------+
| Human writes   |            | Coordinator      |            | Human reads      |            | Human reviews    |
| spec, queues   |----------->| claims work,     |----------->| thread updates,  |----------->| branch, merges   |
| via MCP tool   |            | spawns agents    |            | answers clarifns |            | or requests fix  |
+----------------+            | in worktrees     |            |                  |            +------------------+
                              +------------------+            +------------------+
                                     |                              |
                              +------+------+               +------+------+
                              |             |               |             |
                              v             v               v             v
                         [Agent 1]    [Agent 2]        [Progress]   [Clarify?]
                         worktree     worktree          "step 3/7"   -> Job B
                         run-42       run-57
```

---

## Step-by-Step

### Step 1: Queue Work
**Actor:** Human
**Action:** Write a feature spec in `docs/feature/{name}/`, then call `queue_factory_run` via MCP with `spec_path` and `channel_id`.
**Output:** Run created in `queued` status. Initial thread message posted to channel.
**Emotion:** Intentional. "I'm committing this spec to the factory."
**Shared artifacts:** `${run_id}`, `${thread_message_id}`, `${spec_path}`

### Step 2: Coordinator Polls
**Actor:** Coordinator agent (long-lived session)
**Action:** Periodically calls `list_factory_work`. Discovers queued runs.
**Output:** List of available work with spec paths and attempt counts.
**Emotion:** (Coordinator is mechanical here. Human emotion: anticipation — "will it pick up my work?")
**Failure mode:** Coordinator not running. Work sits in queue indefinitely. -> Human must start coordinator.

### Step 3: Claim and Spawn
**Actor:** Coordinator
**Action:** Calls `claim_factory_work(run_id, commit_sha)` for each available run (up to concurrency limit). Receives `${claim_token}`. Spawns a worktree-isolated agent for each claimed run.
**Output:** Run transitions `queued` -> `implementing`. "Claimed" message posted to thread. Agent starts in `.factory/run-{id}/` worktree.
**Emotion:** (Human sees "claimed" in thread: confidence — "it's working.")
**Shared artifacts:** `${claim_token}`, `${worktree_path}`, `${agent_id}`
**Failure mode:** Race condition (another session claims first) -> `{:error, :already_claimed}`. Coordinator skips, tries next.

### Step 4: Agent Implements
**Actor:** Spawned implementing agent (worktree-isolated)
**Action:** Reads spec at `${spec_path}`, reads `CLAUDE.md` and engineering principles. Plans, implements with TDD, runs tests iteratively.
**Output:** Code changes in worktree. Tests passing.
**Emotion:** (Human is away or doing other work. This is the "unattended" part.)
**Failure mode:** Agent encounters ambiguity -> triggers Clarification journey (Job B). Agent hits compile/test failure -> iterates internally.

### Step 5: Coordinator Heartbeats
**Actor:** Coordinator
**Action:** Every `heartbeat_timeout_minutes / 2` (default 5 min), calls `factory_heartbeat(run_id, claim_token, message)` for each active agent. Message includes structured progress: "Implementing step 3/7: CSV parser module."
**Output:** `last_heartbeat_at` updated. Progress message posted to thread.
**Emotion:** Human glances at thread: calm confidence. "Step 3 of 7, it's making progress."
**Shared artifacts:** Progress messages in thread provide the ambient awareness (Job D).

### Step 6: Pre-Deploy Checks
**Actor:** Spawned implementing agent
**Action:** Runs `scripts/pre-deploy` (tests, format, credo, dialyzer). All checks must pass.
**Output:** All checks green. Branch pushed: `factory/run-{id}`.
**Failure mode:** Checks fail -> agent iterates. If agent can't fix after attempts -> submits failure.

### Step 7: Submit Result
**Actor:** Coordinator (on behalf of agent)
**Action:** Calls `submit_factory_result(run_id, claim_token, success: true, branch_name: "factory/run-{id}")`.
**Output:** Run transitions `implementing` -> `awaiting_verification`. Thread updated: "Implementation complete — awaiting Tier 2 verification."
**Emotion:** Human sees completion in thread: satisfaction. "One down."
**Failure path (success: false):**
- Attempts remain -> stays `implementing`, `attempt` incremented. Agent retries.
- Attempts exhausted -> `needs_review`. Thread updated. Human must intervene.

### Step 8: Verification (-> Verification Journey)
**Actor:** Verification agent (separate session, separate context)
**Action:** See Journey: Independent Verification.
**Output:** Run transitions to `completed` or `needs_review`.

### Step 9: Human Review
**Actor:** Human
**Action:** Reads thread summary. Checks out `factory/run-{id}` branch. Reviews code, test output, verification results.
**Output:** Human merges branch, opens PR, or requests manual fix.
**Emotion:** Confidence if Tier 2 passed. Concern if `needs_review`.

### Step 10: Cleanup
**Actor:** Coordinator
**Action:** Removes worktree (`.factory/run-{id}/`). Optionally proposes spec amendments from clarification Q&A (Job F -> Clarification journey).
**Output:** Clean workspace. Spec improvements proposed.

---

## Crash Recovery Sub-Journey (Job E)

```
Coordinator crashes
       |
       v
[All heartbeats stop]
       |
       v (after heartbeat_timeout_minutes)
[LifecycleWorker releases stale claims]
       |
       v
[Runs re-queue: implementing -> queued, verifying_tier2 -> awaiting_verification]
       |
       v
[Human restarts coordinator]
       |
       v
[Coordinator discovers orphaned .factory/run-* worktrees]
       |
       +---> Worktree has matching queued run? Resume (re-claim, re-use worktree)
       +---> No matching run? Clean up worktree, let run re-queue naturally
```

**Open design question:** Should the coordinator persist `{run_id -> claim_token}` mappings locally so it can resume heartbeating without re-claiming? Current spec doesn't address this.

---

## Emotional Arc

```
Queue     Claim     Implement    Submit    Verify    Review
  |         |          |           |         |         |
  v         v          v           v         v         v
Intent -> Anticipation -> Trust -> Relief -> Confidence -> Satisfaction
  "I'm       "It         "I can    "One      "It        "This
   queueing   picked      do other  done."    passed     works."
   this."     it up!"     things."            unseen
                                              scenarios!"
```

The emotional arc should build confidence progressively. Each thread update reinforces trust. Clarification requests (Job B) temporarily dip confidence ("the spec has gaps") but the structured Q&A quickly restores it ("the agent asked the right question, I gave the answer, it's moving again").
