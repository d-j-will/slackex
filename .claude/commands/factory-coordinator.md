Run the dark factory coordinator. Polls for factory work, spawns worktree-isolated agents, heartbeats on their behalf, and submits results. Feature-flagged behind `:dark_factory`.

## Prerequisites

- Tenun must be running with `:dark_factory` flag enabled
- MCP connection configured in `.mcp.json`
- At least one factory run queued via `queue_factory_run` MCP tool

## Coordinator Loop

Run this loop continuously until stopped or no work remains:

### 1. Poll for Work

Call `list_factory_work` via MCP. If no queued runs, call `list_verification_work`. If neither has work, report "No pending factory work" and wait 60 seconds before polling again.

### 2. Present Work and Confirm

Show the user the available runs (spec path, attempt number, queued timestamp). Ask which to claim, or "all" to claim up to the concurrency limit (default: 2).

### 3. Claim and Spawn (for each selected run)

a. `git fetch && git pull origin master`
b. Get current commit: `git rev-parse HEAD`
c. Call `claim_factory_work(run_id, commit_sha)` — receive `claim_token`
d. Spawn an implementing agent in an isolated worktree:

```
Agent({
  description: "Factory run {run_id}: {spec_path}",
  isolation: "worktree",
  prompt: <implementing agent prompt — see below>,
  name: "factory-run-{run_id}"
})
```

e. Record in local tracking: `{run_id, claim_token, agent_name, status: "working"}`

### 4. Heartbeat Loop

Every 5 minutes, for each active agent:
- Call `factory_heartbeat(run_id, claim_token)` via MCP
- If the agent has sent a progress message via SendMessage, include it in the heartbeat

### 5. Collect Results

When an agent completes (SendMessage with result):
- **Success**: Call `submit_factory_result(run_id, claim_token, success: true, branch_name: "factory/run-{id}", summary: {agent's summary})`
- **Failure**: Call `submit_factory_result(run_id, claim_token, success: false, summary: {error details})`
  - If response includes `retry: true`: send the agent failure context, let it retry
  - If `needs_review`: report to user

### 6. Verification

After a run reaches `awaiting_verification`:
- Call `claim_verification_work(run_id)` — receive new `claim_token`
- Spawn a verification agent in an isolated worktree:

```
Agent({
  description: "Verify run {run_id}: {spec_path}",
  isolation: "worktree",
  prompt: <verification agent prompt — see below>,
  name: "factory-verify-{run_id}"
})
```

- When verification agent completes: Call `submit_verification(run_id, claim_token, passed, scenarios_run, scenarios_passed, details)`

### 7. Cleanup

After a run reaches terminal state (`completed`, `needs_review`, `cancelled`):
- Remove the worktree if it still exists
- Report final status to user

## Implementing Agent Prompt Template

Pass this to the Agent tool when spawning an implementing agent:

```
You are a dark factory implementing agent. Your job is to implement a feature from its spec.

## Your Task
- Spec path: {spec_path} (read this first)
- Spec commit: {spec_commit_sha}
- Run ID: {run_id}
- Attempt: {attempt} of {max_attempts}

## Setup
1. Read the spec at {spec_path}
2. Read CLAUDE.md for project conventions
3. Read docs/engineering-principles.md
4. Read any relevant docs/rca/ files mentioned in the spec

## Implementation
1. Plan the implementation (write your plan internally)
2. Follow TDD: write tests from spec acceptance criteria, then implement
3. Run tests iteratively until all pass
4. Run `scripts/pre-deploy` (or: mix test && mix format --check-formatted && mix credo --strict)

## Communication
- Send progress updates to the coordinator via SendMessage every few minutes:
  "Progress: Implementing step 3/7 — CSV parser module"
- If you encounter a spec ambiguity where the wrong guess would change >1 test case:
  Send: "CLARIFY:{run_id}:{section}:{subsection} — {your question}"
  Then WAIT for the coordinator to forward an answer before continuing.
- If the ambiguity is minor (affects ≤1 test case), make an assumption and document it.

## Completion
When all checks pass:
- `git push origin {branch_name}`
- Send to coordinator: "COMPLETE:success branch={branch_name} tests={count} failures=0"

When checks fail and you can't fix:
- Send to coordinator: "COMPLETE:failure reason={description}"

## Rules
- Work only in your worktree
- Do not call MCP tools directly (coordinator handles those)
- Follow all CLAUDE.md conventions (no `unless`, no swallowed errors, etc.)
- Branch name: factory/run-{run_id}
```

## Verification Agent Prompt Template

Pass this to the Agent tool when spawning a verification agent:

```
You are a dark factory verification agent. Your job is to independently verify a feature implementation by generating test scenarios the implementing agent has never seen.

## CRITICAL: Isolation Protocol
You must follow this order EXACTLY:
1. Read the spec FIRST (before looking at any implementation code)
2. Generate your scenarios from the spec alone
3. ONLY THEN check out the implementation branch to run your scenarios

## Your Task
- Spec path: {spec_path}
- Spec commit: {spec_commit_sha}
- Branch to verify: {branch_name}
- Run ID: {run_id}

## Phase 1: Read Spec (DO THIS FIRST)
1. Read the spec at {spec_path}
2. Read CLAUDE.md for project conventions and known antipatterns
3. Read docs/engineering-principles.md
4. Read docs/rca/ for incident history — these inform your scenario categories

## Phase 2: Generate Scenarios (BEFORE looking at implementation)
Generate Given/When/Then test scenarios across these categories:
- **Boundary values**: empty inputs, max sizes, zero counts
- **Concurrency**: simultaneous operations on same data
- **Error recovery**: dependency fails mid-operation
- **Data integrity**: create -> read -> update -> verify round-trips
- **Project antipatterns** (from docs/rca/):
  - nil-id ghost structs (on_conflict: :nothing)
  - Swallowed Oban worker errors
  - Missing PubSub wiring (topic subscribed but never broadcast)
  - Partition key omissions in joins

Write at least 5 scenarios. Focus on things the implementing agent likely missed.

## Phase 3: Run Scenarios
1. `git checkout -b factory/verify-run-{run_id} origin/{branch_name}`
2. Write your scenario tests as ExUnit tests
3. Run them: `mix test <your test file>`
4. Push the verification branch: `git push origin factory/verify-run-{run_id}`

## Completion
Send to coordinator:
"VERIFY:passed={true|false} scenarios_run={N} scenarios_passed={M} details={summary}"

## Rules
- NEVER read the implementing agent's conversation or plan
- NEVER read Tier 1 test results before generating your scenarios
- Your scenarios must be independently derived from the spec
- Push your verification branch as a review artifact
```

## Clarification Relay (Slice 2)

When an implementing agent sends a message starting with "CLARIFY:":
1. Parse: `CLARIFY:{run_id}:{section}:{subsection} — {question}`
2. Post to the run's channel thread via `reply_to_thread`:
   `[CLARIFY:run-{run_id}:spec:{section}:{subsection}] {question}`
3. Mark the agent as "clarifying"
4. Continue heartbeating for this run
5. Poll the thread every 30 seconds for new non-bot messages
6. When a reply is detected:
   - Post confirmation: "[Factory: run-{run_id}] Interpreting your reply as response to the clarification. Forwarding to agent."
   - Forward the answer to the agent via SendMessage
7. If no reply within 2 hours: notify the agent to assume or fail

## Concurrency (Slice 3)

Maximum concurrent agents: 2 (configurable). Clarifying agents count toward the limit. When a slot frees up, claim the next queued run on the next poll cycle.

## Recovery (Slice 4)

On startup, before entering the poll loop:
1. Check for orphaned worktrees: `ls .factory/run-*/`
2. For each, query run status via `list_factory_runs`
3. If run is still `implementing` (not yet timed out): re-claim and resume
4. If run was released (back to `queued`): clean up the orphaned worktree

## Important

- Never skip heartbeats — stale claims get released by the LifecycleWorker after 10 minutes
- The coordinator is the ONLY process that talks to Tenun MCP for factory operations
- Worker agents communicate with the coordinator via SendMessage, never MCP directly
- All durable state is in Tenun (DB + threads). Coordinator state is ephemeral.
