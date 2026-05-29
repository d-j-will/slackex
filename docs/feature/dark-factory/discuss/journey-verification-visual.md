# Journey: Independent Verification

**Date:** 2026-04-09
**Jobs served:** H (Independent Verification)
**Primary persona:** David (human operator)
**Secondary persona:** Verification agent (spec-only context), Coordinator agent (orchestrator)

---

## Journey Map

```
Implementation complete (awaiting_verification)
       |
       v
+------------------+     +------------------+     +------------------+     +------------------+
| Coordinator      |     | Verification     |     | Verification     |     | Result posted    |
| claims verif.    |---->| agent reads      |---->| agent runs       |---->| to thread.       |
| work, spawns     |     | spec ONLY.       |     | scenarios against|     | completed or     |
| verif. agent     |     | Generates unseen |     | feature branch.  |     | needs_review.    |
+------------------+     | scenarios.       |     +------------------+     +------------------+
                          +------------------+

                          ISOLATION BOUNDARY
                          ==================
                          Agent NEVER sees:
                          - Implementing agent's conversation
                          - Implementation plan or reasoning
                          - Tier 1 test results
                          - Progress messages from impl thread
```

---

## Step-by-Step

### Step 1: Verification Available
**Actor:** Coordinator
**Action:** Polls `list_verification_work`. Discovers runs in `awaiting_verification` status.
**Output:** List of runs with `spec_path`, `spec_commit_sha`, `branch_name`. Notably: NO `tier1_result`, NO implementation context.
**Emotion:** (Human may not even be present. This is part of unattended execution.)

### Step 2: Claim Verification
**Actor:** Coordinator
**Action:** Calls `claim_verification_work(run_id)`. Receives `claim_token`, `spec_path`, `spec_commit_sha`, `branch_name`.
**Output:** Run transitions `awaiting_verification` -> `verifying_tier2`. Thread updated: "Verification started."
**Emotion:** Human sees "verification started" — anticipation.

### Step 3: Read Spec Only
**Actor:** Verification agent (spawned in isolation)
**Action:** Reads the spec at `${spec_path}` (at `${spec_commit_sha}`). Reads project constraints from `CLAUDE.md`, `docs/engineering-principles.md`, and `docs/rca/` incident history.
**CRITICAL:** Does NOT read:
- The implementation code (yet)
- The implementing agent's conversation or plan
- The Tier 1 test results
- The progress messages from the implementation thread
**Output:** Understanding of what the spec requires, informed by project-specific failure modes.
**Design principle:** The verification agent's value comes from its independence. If it reads the implementation first, it becomes a code reviewer (useful but not what Tier 2 is for). Tier 2 tests whether the spec's intent was captured, not whether the code looks clean.

### Step 4: Generate Unseen Scenarios
**Actor:** Verification agent
**Action:** From the spec alone, generates test scenarios in Given/When/Then format. Categories informed by project history:

| Category | Source | Example |
|----------|--------|---------|
| **Boundary values** | Spec requirements | Empty inputs, max sizes, zero counts |
| **Concurrency** | Spec + project patterns | Simultaneous operations on same data |
| **Error recovery** | Spec + engineering principles | Dependency fails mid-operation |
| **Data integrity** | Spec data model | Create -> read -> update -> verify round-trips |
| **Nil-id ghosts** | `docs/rca/` + CLAUDE.md | `on_conflict: :nothing` returns nil id |
| **Swallowed errors** | `docs/rca/` + hookify rules | Oban `perform/1` discards return value |
| **Missing wiring** | `docs/rca/` pipeline events | PubSub topic subscribed but never broadcast |
| **Partition key omissions** | Project patterns | Join without `(message_id, message_inserted_at)` |

**Output:** Set of Given/When/Then scenarios the implementing agent has never seen.
**Emotion:** (Agent is working independently. Human is unaware of specific scenarios.)

### Step 5: Run Scenarios Against Branch
**Actor:** Verification agent
**Action:** Checks out verification branch: `git checkout -b factory/verify-run-{id} origin/factory/run-{id}`. Writes the scenario tests. Runs them against the implementation.
**Output:** Test results: N scenarios run, M passed, failures with details.
**Coordinator action:** Heartbeats on behalf of the verification agent throughout.
**Failure mode:** Scenarios that fail may indicate:
- Implementation bug (spec was clear, implementation missed it)
- Spec gap (spec didn't specify this case, implementation couldn't have known)
- Scenario quality issue (scenario tests something outside spec scope)

### Step 6: Push Verification Branch
**Actor:** Verification agent
**Action:** Pushes `factory/verify-run-{id}` branch with the scenario tests as a review artifact.
**Output:** Verification branch available for human inspection.
**Design principle:** The scenarios themselves are valuable artifacts. Even if all pass, they document what was independently tested. If some fail, the branch shows exactly what broke.

### Step 7: Submit Verification
**Actor:** Coordinator (on behalf of verification agent)
**Action:** Calls `submit_verification(run_id, claim_token, passed, scenarios_run, scenarios_passed, details)`.
**Output:**
- **All pass:** Run transitions `verifying_tier2` -> `completed`. Thread: "Tier 2 passed (5/5 scenarios) — ready for review."
- **Any fail:** Run transitions `verifying_tier2` -> `needs_review`. Thread: "Tier 2 failed (3/5 scenarios) — needs review." Never auto-retries.
**Emotion:**
- Pass: Strong confidence. "It passed scenarios the implementing agent never saw."
- Fail: Concern but also validation. "Good thing we checked — the implementation missed something."

### Step 8: Human Review
**Actor:** Human
**Action:** For `completed`: review branch, merge or open PR. For `needs_review`: examine failure details in thread and verification branch. Decide whether to fix manually, adjust spec and requeue, or abandon.
**Output:** Feature merged, requeued, or abandoned.
**Emotion:**
- Completed: Satisfaction, trust in the factory.
- Needs review: Diagnostic mindset. "What did the verification catch? Was it a real bug or a bad scenario?"

---

## Isolation Guarantees

| Phase | What the verification agent sees | What it does NOT see |
|-------|----------------------------------|---------------------|
| Phase 1 | Current | Implementing agent's conversation, plan, reasoning |
| Scenario generation | Spec text, acceptance criteria, project constraints, RCA docs | Tier 1 test results, implementation code, progress messages |
| Scenario execution | Implementation code (on the branch) | Why the implementer made specific choices |

**Phase 1 enforcement:** Prompt-based. The verification agent's prompt instructs it to read spec first, generate scenarios, THEN check out the branch.
**Phase 2 enforcement:** Restricted MCP token scope. Verification agent physically cannot access implementation context.

---

## Emotional Arc

```
Impl Done    Verif Starts   Scenarios Run   Pass/Fail     Review
    |              |              |              |            |
    v              v              v              v            v
Hopeful  ->  Anticipation  ->  Suspense  ->  Relief    ->  Trust
 "Impl         "Second          "Will it      or           "Factory
  passed        opinion          hold up?"    Concern       works"
  Tier 1"       checking"                     "What did     or
                                              it catch?"    "Glad we
                                                            checked"
```

The verification journey's emotional peak is Step 7: the moment results come back. Pass = the factory's strongest credibility signal. Fail = the factory's strongest safety signal ("it caught something humans might have missed").

---

## Why Independent Verification Matters

From the research doc's core principle:

> The key insight: acceptance criteria visible to the agent guide implementation. Unseen test scenarios provide independent verification — not to trick the agent, but to confirm the implementation is sound beyond the stated criteria. The same reason a code reviewer who didn't write the code adds value.

The implementing agent is incentivized (by its prompt) to make all acceptance criteria pass. It optimizes for what it can see. The verification agent tests what the spec implies but doesn't explicitly state — the gaps between acceptance criteria where bugs hide.

This is directly analogous to the v0.5.47-v0.5.64 incident: all unit tests passed because they faked the upstream event. An independent verification agent reading only the spec would have generated a "does the full producer -> consumer path exist?" scenario and caught the missing wiring.
