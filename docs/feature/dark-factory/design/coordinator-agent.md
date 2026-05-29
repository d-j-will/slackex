# Dark Factory -- Coordinator Agent with Clarification Threading

**Date:** 2026-04-09
**Status:** Approved
**Parent:** `docs/feature/dark-factory/design/architecture.md` (Phase 1)
**Extends:** Phase 1 architecture with concurrent execution and spec refinement

---

## 1. Problem

Phase 1 assumes a human manually opens Claude Code sessions, claims work, and drives execution. This works for proving the pipeline but doesn't scale:

- Only one run executes at a time (the human's session)
- The human must babysit the session ("check factory jobs", confirm claims)
- When a spec is ambiguous, the agent has no way to ask questions -- it either guesses or fails

## 2. Solution

A **coordinator agent** that:

1. Polls the factory queue for available work
2. Spawns concurrent worktree-isolated agents for each claimed run
3. Enables agents to ask clarification questions back through the run's channel thread
4. Manages the lifecycle: heartbeats, timeouts, cleanup

The coordinator runs locally (dev machine, Claude Code session). All execution happens locally. The Docker host is only involved at deploy time after verification passes.

---

## 3. Coordinator Design

### Lifecycle

```
Coordinator starts (scheduled task or manual invocation)
  loop:
    list_factory_work via MCP
    for each available run (up to concurrency limit):
      claim_factory_work
      spawn agent in isolated worktree
      register agent in active work table

    monitor active agents:
      - heartbeat on behalf of working agents
      - detect completed/failed agents
      - clean up worktrees on completion
      - relay clarification requests/responses

    sleep(poll_interval)
```

### Concurrency Model

The coordinator is the only process that talks to the Tenun MCP for factory operations. Spawned agents work in isolated worktrees and communicate back to the coordinator via `SendMessage`.

```
+-------------------+
|   Coordinator     |    Tenun MCP
|   (long-lived)    |<--------------->  list/claim/heartbeat/submit
|                   |
|  active_agents:   |
|  run-42 -> agent1 |---> Agent 1 (worktree: .factory/run-42/)
|  run-57 -> agent2 |---> Agent 2 (worktree: .factory/run-57/)
|  run-63 -> agent3 |---> Agent 3 (worktree: .factory/run-63/)
+-------------------+
```

### Concurrency Limit

Bounded by practical constraints:
- **CPU cores** for parallel compilation (Elixir/BEAM compiles are CPU-bound)
- **Memory** for concurrent `_build` directories
- **API rate limits** on Claude Code (Max subscription)

Default: 2 concurrent agents. Configurable.

### Heartbeat Delegation

The coordinator heartbeats on behalf of all active agents. Agents don't need MCP access -- they just implement and report back. This keeps the MCP interaction centralized and avoids token/auth complexity.

Heartbeat cadence: every `heartbeat_timeout_minutes / 2` (default: 5 minutes for a 10-minute timeout).

---

## 4. Clarification Threading

### The Problem

Specs vary in quality. An agent may encounter:
- Missing acceptance criteria for edge cases
- Ambiguous requirements ("should support large files" -- how large?)
- Conflicting constraints between spec sections
- Dependencies on unbuilt features not mentioned in the spec

Phase 1 response: agent guesses or submits failure. Both waste cycles.

### The Solution

Agents can pause implementation to ask questions. Questions are posted to the run's channel thread with a **spec identifier** that ties the question back to the specific section or requirement.

### Spec Identifiers

Every clarification message includes a structured identifier:

```
[CLARIFY:run-42:spec:acceptance-criteria:3]
The third acceptance criterion says "messages are delivered in order"
but doesn't define ordering for concurrent senders. Should ordering
be per-channel (Snowflake ID) or per-sender?
```

Format: `[CLARIFY:{run_id}:{section}:{subsection}:{item}]`

Where:
- `run_id` -- ties to the factory run
- `section` -- top-level spec section (e.g., `acceptance-criteria`, `data-model`, `api`, `ui`)
- `subsection` -- specific area within the section
- `item` -- optional item number or name

This identifier serves three purposes:
1. **Thread readability** -- humans scanning the channel can see exactly which spec element is in question
2. **Response routing** -- when a human replies, the coordinator matches the response back to the waiting agent and the specific question
3. **Spec improvement** -- after a run completes, clarification Q&A can be folded back into the spec, improving it for future runs

### Message Flow

```
Agent discovers ambiguity
  -> sends message to coordinator: {clarify, run_id, identifier, question}

Coordinator receives clarification request
  -> posts to run's channel thread via reply_to_thread:
     "[CLARIFY:run-42:acceptance-criteria:3] <question>"
  -> marks agent as "awaiting_clarification"
  -> continues heartbeating for this run

Human reads thread, replies with answer

Coordinator polls thread (search_messages or periodic thread read)
  -> detects new reply after the clarification message
  -> forwards answer to the waiting agent via SendMessage

Agent incorporates answer
  -> resumes implementation
  -> coordinator marks agent as "implementing"
```

### Waiting Behavior

While an agent waits for clarification:
- The coordinator continues heartbeating (the claim stays alive)
- The agent's worktree is untouched (partial work preserved)
- Other agents continue working on their own runs
- The coordinator can still claim and start new work (up to concurrency limit)

### Timeout

If no response arrives within a configurable timeout (default: 2 hours):
- The coordinator posts a timeout notice to the thread
- The agent is instructed to either:
  - Make a reasonable assumption and document it in the PR
  - Submit failure with "blocked on clarification" if the ambiguity is too fundamental

### Multiple Clarifications

An agent may ask multiple questions during a single run. Each gets its own identifier and thread message. The coordinator tracks them independently:

```
run-42:
  clarifications:
    - id: "acceptance-criteria:3", status: answered, answer: "per-channel ordering"
    - id: "data-model:users:soft-delete", status: pending, asked_at: ...
```

---

## 5. State Machine Extension

The existing state machine gains a sub-state within `implementing`:

```
implementing:
  working        -- agent is actively coding
  clarifying     -- agent has asked a question, waiting for response
```

This is a **coordinator-local** sub-state, not a database column. The Tenun pipeline still sees `implementing` -- the clarification state is managed entirely by the coordinator. The thread messages provide the audit trail.

Rationale: keeping clarification state local avoids schema changes and keeps the factory pipeline simple. The thread IS the record.

---

## 6. Thread Structure

A typical run's thread looks like:

```
[Bot] Factory run #42 queued
  spec: docs/feature/bulk-import/
  queued by: @david

[Bot] Run #42 claimed (attempt 1/3)

[Bot] Run #42 progress: Reading spec and planning implementation...

[Bot] Run #42 progress: Implementing step 2/5 -- CSV parser module

[Bot] [CLARIFY:run-42:spec:acceptance-criteria:3]
  The spec says "support large files" but doesn't define a size limit.
  What's the maximum expected file size? This affects whether we stream
  or load into memory.

[@david] 500MB max. Stream it -- we've had OOMs with large in-memory loads before.

[Bot] Run #42 progress: Clarification received, resuming. Implementing streaming CSV parser.

[Bot] Run #42 progress: Running pre-deploy checks...

[Bot] Run #42 submitted successfully
  branch: factory/run-42
  tests: 47 passed, 0 failed
```

The `[CLARIFY:...]` prefix makes clarification messages visually distinct and machine-parseable.

---

## 7. Coordinator Implementation Options

### Option A: Scheduled Task

A scheduled task that polls every N minutes. Simple, uses existing infrastructure.

```
Scheduled task (every 3 minutes):
  1. Check for available work
  2. Check for clarification responses
  3. Check for completed/failed agents
  4. Heartbeat active runs
```

**Pros:** Simple, no new infrastructure, survives session restarts.
**Cons:** Polling latency (up to 3 min to notice new work or responses). Agents must be spawned fresh each poll cycle or tracked across invocations.

### Option B: Long-Lived Session

A Claude Code session that runs continuously, spawning agents as teams.

```
/team coordinator:
  - polls for work
  - spawns executor teammates in worktrees
  - relays clarifications
  - manages lifecycle
```

**Pros:** Lower latency, natural team coordination, agents can message the coordinator directly.
**Cons:** Tied to a single session, must be restarted if it crashes.

### Option C: Skill-Triggered with Background Agents

A skill (`/factory-coordinator`) that starts the loop, spawns background agents, and returns control to the user. The coordinator runs as background agents with periodic check-ins.

**Pros:** User can do other work while factory runs. Explicit start/stop.
**Cons:** Background agent lifecycle management is complex.

### Recommended: Option B (Long-Lived Session)

The coordinator is inherently a long-running, stateful process. A dedicated Claude Code session with team coordination is the natural fit. It can:
- Spawn agents with `isolation: "worktree"`
- Use `SendMessage` for agent communication
- Maintain state across the session
- The user can observe progress in the session

---

## 8. Spec Improvement Feedback Loop

After a run completes (success or failure), the coordinator can:

1. Collect all `[CLARIFY:...]` Q&A pairs from the thread
2. Propose spec amendments based on the answers
3. Post the proposed amendments to the thread for human review
4. If approved, a follow-up agent (or the coordinator itself) updates the spec

This creates a virtuous cycle: specs improve with each factory run, reducing future clarification needs.

---

## 9. New MCP Considerations

No new MCP tools required. The coordinator uses existing tools:
- `list_factory_work` / `claim_factory_work` / `factory_heartbeat` / `submit_factory_result` -- existing
- `reply_to_thread` -- existing Tenun messaging tool, used for clarifications
- `search_messages` -- existing, used to poll for clarification responses

The `[CLARIFY:...]` identifier is a message format convention, not a protocol change.

### Potential Future MCP Addition

If polling for responses proves too slow or unreliable, a dedicated tool could help:

**`get_thread_replies_after`** -- Returns messages in a thread after a given message ID. More efficient than `search_messages` for monitoring a specific thread.

Arguments: `channel_id`, `thread_message_id`, `after_message_id`

This is optional and can be added when needed.

---

## 10. Relationship to Architecture Phases

| Aspect | Phase 1 (current) | This Addition | Phase 2 (future) |
|--------|-------------------|---------------|------------------|
| Who starts agents | Human | Coordinator agent | Claude Agent SDK |
| Concurrency | 1 (human's session) | N (coordinator-managed) | N (GenServer per run) |
| Clarification | Agent guesses or fails | Thread-based Q&A | Structured clarification protocol |
| Spec IDs | N/A | Message convention `[CLARIFY:...]` | Formal schema field |
| Worktree management | Human creates | Coordinator creates/cleans | Agent SDK manages |
| State tracking | DB only | DB + coordinator local state | DB + GenServer state |

This sits between Phase 1 and Phase 2 -- it proves concurrent execution and human-in-the-loop clarification without requiring the Agent SDK migration.

---

## 11. Open Questions (Resolved)

All open questions were resolved during the DISCUSS and DESIGN waves (2026-04-09). See `design/wave-decisions.md` for decision rationale and `design/architecture-coordinator.md` for implementation details.

1. **Concurrency limit** -- Configurable per-session via environment variable, default 2. Clarifying agents count toward the limit (preserves resource guarantees). See `architecture-coordinator.md` §7.

2. **Clarification quality** -- Confidence threshold: agent asks only when the wrong guess would change >1 test case. Low-stakes ambiguities are assumed and documented in the PR description. See `discuss/acceptance-criteria.md` AC-12.

3. **Response matching** -- Positional detection with coordinator confirmation. Coordinator treats first non-bot reply after a clarification as the answer candidate, posts confirmation, gives 2 minutes to correct. For multiple pending clarifications, coordinator asks human to specify which question. See `architecture-coordinator.md` §8 and `design/adr-003-clarification-via-message-convention.md`.

4. **Verification coordinator** -- Same coordinator manages both implementing and verification agents, sharing the same concurrency pool. Implementation is prioritized over verification when slots are scarce. See `discuss/user-stories.md` S6.

5. **Worktree warm cache** -- Don't share `_build` (concurrent compile race conditions). Pre-seed `deps/` only (read-only after fetch). See `design/architecture-coordinator.md` §7.
