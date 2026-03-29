# Dark Factory -- Architecture Design

**Date:** 2026-03-29
**Status:** Approved (Phase 1)
**Related:**
- `docs/research/dark-factory-spec-driven-development-discovery-2026-03-08.md`
- `docs/research/agentic-adoption-maturity-model-discovery-2026-03-08.md`
- `docs/research/vision-roadmap-2026-03-08.md`

---

## 1. Vision

A work queue with structured execution. Users queue feature specs, Claude Code sessions pick up work via MCP, implement in worktrees, push branches. A separate session generates unseen test scenarios for independent verification.

The dark factory is Tenun's proof that spec-driven agentic development works. Tenun features are built by the factory. If the factory can't deliver Tenun features that pass unseen scenarios, it can't be trusted for anything.

### What This Document Covers

**Phase 1 (this design):** Embedded in Tenun. MCP tools + Oban lifecycle + PubSub notifications. Human-initiated Claude Code sessions on Max subscription. AI-generated Tier 2 scenarios.

**Documented end goals (not built in Phase 1):**
- **Phase 2 runtime:** Tenun orchestrates agents via Claude Agent SDK (push-based). Pipeline runs become GenServers with live state. No human needed to start sessions.
- **Phase 2 triggering:** MCP-initiated pipeline creation from channel conversations (`draft_spec` prompt flows into `queue_factory_run`).
- **Phase 2 verification:** Property-based tests (StreamData) alongside AI-generated scenarios. Separate MCP tokens with restricted scope for true agent isolation.
- **Phase 2 completion:** Auto-PR creation on `completed`. Multi-user support (team members pick up each other's work).

---

## 2. System Context

```
User opens Claude Code (Max subscription)
  -> "check factory jobs" (skill or prompt)
    -> MCP: list_factory_work -> claims a run
      -> reads spec from docs/feature/*/
        -> implements in git worktree
          -> MCP: factory_heartbeat (updates channel thread)
            -> pushes branch, MCP: submit_factory_result

Later (same or different session):
  -> "check verification jobs"
    -> MCP: list_verification_work -> claims completed run
      -> reads spec ONLY (not implementation context)
        -> generates unseen scenarios from spec
          -> checks out feature branch, runs scenarios
            -> MCP: submit_verification (pass/fail + details)
```

```
+-------------------------+         MCP (poll)         +----------------+
| Implementing Agent      |<-------------------------->|                |
| (Claude Code session)   |   list_factory_work        |                |
|                         |   claim_factory_work       |     Tenun      |
| - reads spec            |   factory_heartbeat        |                |
| - implements in         |   submit_factory_result    | - factory_runs |
|   worktree              |                            |   table        |
| - runs pre-deploy       |                            | - state        |
|   checks                |                            |   machine      |
| - pushes branch         |                            | - Oban         |
+-------------------------+                            |   lifecycle    |
                                                       | - PubSub ->   |
+-------------------------+         MCP (poll)         |   channel      |
| Verification Agent      |<-------------------------->|   updates      |
| (Claude Code session)   |   list_verification_work   |                |
|                         |   claim_verification_work  +----------------+
| - reads spec ONLY       |   factory_heartbeat               |
| - generates unseen      |   submit_verification        PostgreSQL
|   scenarios             |                            (factory_runs,
| - runs against          |                             factory_events)
|   feature branch        |
| - never sees impl       |
|   agent's context       |
+-------------------------+
```

### Key Design Principles

1. **Tenun is a platform, not an agent runtime.** Tenun manages pipeline state and exposes it via MCP. Agents are external and bring their own compute.
2. **Pull, not push.** Agents poll Tenun for work. Tenun never invokes agents. This decouples Tenun from the agent runtime entirely.
3. **Isolation by protocol.** The verification agent receives only the spec and branch name -- never the implementing agent's conversation, plan, or reasoning. Phase 1 enforces this by prompt. Phase 2 enforces by restricted MCP token scope.
4. **The factory is a work queue.** When and how agent sessions start doesn't matter to Tenun. Local Claude Code, `/remote` sessions, or eventually API-backed agents all use the same MCP protocol.

---

## 3. Data Model

### `factory_runs`

One row per pipeline run.

| Column | Type | Notes |
|--------|------|-------|
| `id` | `bigint` (Snowflake) | |
| `spec_path` | `string` | e.g. `docs/feature/bulk-import/` |
| `spec_commit_sha` | `string` | Git SHA at claim time, pins spec version |
| `status` | `string` | State machine (see below) |
| `queued_by_id` | `references(users)` | Bot user who queued it |
| `channel_id` | `references(channels)` | Where to post updates |
| `thread_message_id` | `bigint` | Nullable, set on first status post |
| `branch_name` | `string` | Set when implementing agent pushes |
| `claim_token` | `string` | Random token, set on claim, required for updates |
| `claimed_at` | `utc_datetime_usec` | |
| `last_heartbeat_at` | `utc_datetime_usec` | Updated by `factory_heartbeat` |
| `attempt` | `integer` | Default 1 |
| `max_attempts` | `integer` | Configurable, default 3 |
| `heartbeat_timeout_minutes` | `integer` | Default 10 |
| `tier1_result` | `map` | JSON from implementing agent |
| `tier2_result` | `map` | JSON from verification agent |
| `completed_at` | `utc_datetime_usec` | |
| `timestamps` | | |

Indexes: `status`, `queued_by_id`, `(status, queued_by_id)` composite for list queries.

### `factory_events`

Append-only audit log of state transitions and progress updates.

| Column | Type | Notes |
|--------|------|-------|
| `id` | `bigint` | |
| `factory_run_id` | `references(factory_runs)` | |
| `event_type` | `string` | `status_change`, `progress`, `error` |
| `from_status` | `string` | null for non-transition events |
| `to_status` | `string` | null for non-transition events |
| `message` | `text` | Human-readable description |
| `metadata` | `map` | Arbitrary JSON (test results, error details) |
| `timestamps` | | |

### State Machine

```
queued -> implementing -> awaiting_verification -> verifying_tier2 -> completed
              ^    |                                      |
              |    v                                      v
              |  fail + attempts remain            needs_review
              |  (stays implementing,                     ^
              |   increments attempt)                     |
              |                                           |
              +-- timeout (Oban releases,           fail + exhausted
                  clears claim fields + branch_name,
                  preserves attempt count)

awaiting_verification <- timeout from verifying_tier2 (Oban releases, clears claim fields)

cancelled (from any non-terminal state)
```

**Terminal states:** `completed`, `needs_review`, `cancelled`.

**Timeout behavior:**
- `implementing` timeout -> `queued` (clear `claim_token`, `claimed_at`, `last_heartbeat_at`, `branch_name`; preserve `attempt`)
- `verifying_tier2` timeout -> `awaiting_verification` (clear claim fields)
- Timeout = no heartbeat within `heartbeat_timeout_minutes`

**Post-terminal behavior:**
- `completed`: factory posts "ready for review" with branch name to thread. Human reviews, opens PR or merges.
- `needs_review`: factory posts failure details to thread. Human decides: fix manually, adjust spec and requeue, or abandon.

---

## 4. MCP Tools

### Creating work

**`queue_factory_run`** -- Creates a new run in `queued` status. Posts initial thread message to the specified channel, stores `thread_message_id`.

Arguments: `spec_path`, `channel_id`
Returns: `run_id`, `thread_message_id`

### For the implementing agent

**`list_factory_work`** -- Returns up to 5 oldest `queued` runs for the authenticated bot user. Each entry: run ID, spec path, attempt number, queued timestamp.

Arguments: none

**`claim_factory_work`** -- Transitions `queued` -> `implementing` (atomic: `WHERE id = ? AND status = 'queued'`, returns `{:error, :already_claimed}` on race). Generates `claim_token`, stores `spec_commit_sha`, sets `claimed_at` + `last_heartbeat_at`. Posts "claimed" message to run's thread.

Arguments: `run_id`, `commit_sha`
Returns: `claim_token`, `spec_path`, `spec_commit_sha`, `channel_id`, `thread_message_id`, `attempt`, `max_attempts`

**`submit_factory_result`** --
- **Success**: `implementing` -> `awaiting_verification`. Stores `branch_name` and `tier1_result`.
- **Failure + attempts remain**: stays `implementing`, increments `attempt`, logs event. Returns `{retry: true, attempt: N, max_attempts: M}`.
- **Failure + exhausted**: -> `needs_review`.

Arguments: `run_id`, `claim_token`, `success` (boolean), `branch_name` (required if success), `summary` (map)

### For the verification agent

**`list_verification_work`** -- Returns up to 5 oldest `awaiting_verification` runs. Each entry: run ID, spec path, spec commit SHA, branch name. Excludes `tier1_result` and implementation context.

Arguments: none

**`claim_verification_work`** -- Transitions `awaiting_verification` -> `verifying_tier2` (atomic: `WHERE id = ? AND status = 'awaiting_verification'`). Generates `claim_token`, sets `claimed_at` + `last_heartbeat_at`. Posts "verification started" to thread.

Arguments: `run_id`
Returns: `claim_token`, `spec_path`, `spec_commit_sha`, `branch_name`

**`submit_verification`** --
- **Pass**: -> `completed`. Stores `tier2_result`.
- **Fail**: -> `needs_review`. Stores `tier2_result`. Never retries.

Arguments: `run_id`, `claim_token`, `passed` (boolean), `scenarios_run` (integer), `scenarios_passed` (integer), `details` (map)

### Shared tools

**`factory_heartbeat`** -- Updates `last_heartbeat_at`. Optionally posts message to thread if `message` is provided.

Arguments: `run_id`, `claim_token`, `message` (optional)

**`list_factory_runs`** -- Read-only. Returns all runs for the authenticated bot user, optionally filtered by status.

Arguments: `status` (optional -- filter to specific status, omit for all non-terminal, pass `all` for everything)

**`cancel_factory_run`** -- Any non-terminal state -> `cancelled`. Requires `claim_token` OR ownership by the bot user who queued it. Posts cancellation to thread.

Arguments: `run_id`, `claim_token` (optional)

### Shared behaviors

- All mutations validate `claim_token` (except `cancel_factory_run` by owner and `queue_factory_run`)
- All state transitions enforced in context module -- invalid transitions return `{:error, reason}`
- All transitions append to `factory_events`
- Status changes trigger PubSub -> channel thread updates
- Feature-flagged behind `:dark_factory`
- `queued_by_id` is the bot user ID; human-user association is Phase 2
- Heartbeat frequency: at least every `heartbeat_timeout_minutes / 2` (agents must comply)

---

## 5. Agent Workflows

These are prompt/skill definitions for Claude Code sessions, not Tenun code.

### Implementing Agent

When the user says "check factory jobs":

1. `git fetch && git pull origin master`
2. Call `list_factory_work`
   - No work? Report "no pending jobs" and stop.
3. Present the list, user confirms which to claim.
4. `git rev-parse HEAD` to get current commit SHA.
5. Call `claim_factory_work(run_id, commit_sha)`
6. Read the spec at `spec_path` (at the pinned commit).
7. Read `CLAUDE.md`, `docs/engineering-principles.md`, and any relevant `docs/rca/` files.
8. Create a git worktree: `git worktree add .factory/run-{id} -b factory/run-{id}`
9. Plan the implementation (internal to the agent).
10. Implement in the worktree, running tests iteratively.
    - Call `factory_heartbeat(message: "Implementing step 3/7: ...")` at least every 5 minutes.
11. Run `scripts/pre-deploy` (or the non-Docker subset: tests, format, credo, dialyzer).
12. When all checks pass:
    - `git push` the feature branch.
    - Call `submit_factory_result(success: true, branch_name: "factory/run-{id}")`.
13. When checks fail and agent can't fix:
    - Call `submit_factory_result(success: false, summary: {error details})`.
    - If retry response: go back to step 10 with failure context (same worktree).
    - If needs_review: report to user and stop.

### Verification Agent

When the user says "check verification jobs":

1. `git fetch && git pull origin master`
2. Call `list_verification_work`
   - No work? Report "no verification jobs" and stop.
3. Present the list, user confirms which to claim.
4. Call `claim_verification_work(run_id)`
   - Receives: `spec_path`, `spec_commit_sha`, `branch_name`
5. Read the spec at `spec_path` (at `spec_commit_sha`).
   - **Do NOT read the implementation code yet.**
   - **Do NOT read the implementing agent's progress messages.**
6. Generate unseen test scenarios from the spec alone, in Given/When/Then format. Categories:
   - Boundary values (empty inputs, maximum sizes, zero counts)
   - Concurrency (simultaneous operations on the same data)
   - Error recovery (dependency fails mid-operation)
   - Data integrity (create -> read -> update -> verify round-trips)
   - Project-specific antipatterns (from `docs/rca/` -- nil-id ghosts, swallowed errors, missing PubSub wiring, partition key omissions)
7. Check out a verification branch: `git checkout -b factory/verify-run-{id} origin/{branch_name}`
8. Write the scenario tests, run them against the implementation.
   - Call `factory_heartbeat` at least every 5 minutes.
9. Push the verification branch (artifact for review).
10. Call `submit_verification` with results.

### Prompt Requirements

Both agent prompts need:
- MCP connection details (`.mcp.json` already configured)
- The factory protocol (which tools to call and in what order)
- Project-specific constraints (CLAUDE.md, engineering principles)
- Heartbeat discipline (every `heartbeat_timeout_minutes / 2`)

Implementing agent additionally:
- TDD workflow (write tests from spec criteria, then implement)
- Worktree setup (always create fresh, never reuse)
- Branch naming: `factory/run-{id}`
- Full pre-deploy checks before submitting success

Verification agent additionally:
- Isolation discipline (read spec first, generate scenarios, THEN look at code)
- Scenario quality guidance (concrete categories above, not trivial happy-path duplicates)
- Verification branch: `factory/verify-run-{id}`
- Push verification tests as review artifact

---

## 6. Tenun Implementation

### New Modules

**`Slackex.Factory`** -- Context module. All pipeline state transitions. Enforces the state machine, appends events, broadcasts PubSub. No MCP awareness.

Key functions:
- `queue_run/2` -- creates run + initial event
- `claim_run/2` -- atomic claim with optimistic lock
- `heartbeat/2` -- updates timestamp, optionally appends progress event
- `submit_result/2` -- handles success/retry/exhausted branching
- `claim_verification/1` -- atomic claim for Tier 2
- `submit_verification/2` -- handles pass/needs_review
- `cancel_run/2` -- validates ownership or claim token
- `list_runs/2` -- filtered query
- `list_pending/1` -- queued runs for a bot user
- `list_pending_verification/1` -- awaiting_verification runs for a bot user
- `release_stale_claims/0` -- called by Oban worker

All mutations return `{:ok, run}` or `{:error, reason}`. All status changes append to `factory_events` and broadcast `{:factory_run_updated, run}` on PubSub topic `"factory:events"`.

**`Slackex.Factory.Run`** -- Ecto schema for `factory_runs`.

**`Slackex.Factory.Event`** -- Ecto schema for `factory_events`.

**`Slackex.Factory.LifecycleWorker`** -- Oban worker, runs every 2 minutes. Finds runs where `last_heartbeat_at` is older than `heartbeat_timeout_minutes`. Releases stale claims, posts timeout events to channel threads.

**`Slackex.Factory.ChannelNotifier`** -- GenServer. Subscribes to `"factory:events"` PubSub topic. On `{:factory_run_updated, run}`, posts the latest event to the run's channel thread via `Messaging.send_message` using the bot user who queued the run. Supervised with `restart: :temporary` (non-essential).

**`SlackexWeb.MCP.Server`** -- Existing module, extended with 10 new factory tools. Tools delegate to `Slackex.Factory` context.

### Migration

One migration, two tables. Expand-only. Indexes on `status`, `queued_by_id`, and `(status, queued_by_id)` composite.

### Feature Flag

`:dark_factory` -- guards all MCP tools and the Oban worker. ChannelNotifier starts unconditionally but checks the flag before posting.

### File Count

| Type | Files | Notes |
|------|-------|-------|
| Context | 1 | `Slackex.Factory` |
| Schemas | 2 | `Factory.Run`, `Factory.Event` |
| Oban worker | 1 | `Factory.LifecycleWorker` |
| Channel notifier | 1 | `Factory.ChannelNotifier` |
| MCP tools | 0 | 10 new tools in existing `Server.ex` |
| Migration | 1 | Two tables |
| Tests | 3 | Context, lifecycle worker, MCP integration |
| **Total** | **9** | |

### What Doesn't Change

- No changes to existing MCP tools
- No changes to existing schemas
- No new dependencies
- No new OTP supervision complexity beyond one Oban worker and one small GenServer

---

## 7. Two-Tier Verification Strategy

### Tier 1: Known Acceptance Criteria (visible to implementing agent)

- Written by humans as part of the spec
- Agent sees these during implementation
- Agent writes tests to satisfy these, runs them as part of implementation
- Verified by the implementing agent before submitting success

### Tier 2: Unseen Scenarios (Phase 1 -- AI-generated)

- Generated by the verification agent from the spec alone
- The verification agent never sees the implementing agent's context
- Scenarios are Given/When/Then format across these categories:
  - Boundary values
  - Concurrency
  - Error recovery
  - Data integrity round-trips
  - Project-specific antipatterns (informed by `docs/rca/`)
- Run against the feature branch
- Tier 2 failure always escalates to `needs_review` -- never auto-retries

### Documented Phase 2 Verification Enhancements

- **Property-based tests (StreamData):** Define invariants from the spec, generate hundreds of random inputs. Stronger guarantees than AI-generated scenarios.
- **Mutation testing:** Introduce deliberate bugs, verify the test suite catches them. Validates that Tier 2 scenarios aren't trivial.
- **Human-written unseen scenarios:** For critical features, humans write additional held-back scenarios.

---

## 8. Evolution Path

### Phase 1 (this design)

| Aspect | Phase 1 |
|--------|---------|
| Agent runtime | Human-initiated Claude Code (Max subscription) |
| Triggering | Manual via `queue_factory_run` MCP tool |
| Orchestration | MCP tools + Oban lifecycle + PubSub |
| State management | Ecto + Oban periodic worker |
| Tier 2 | AI-generated scenarios |
| Isolation | Prompt-enforced |
| Completion | Human reviews branch, merges manually |

### Phase 2 (documented end goal)

| Aspect | Phase 2 |
|--------|---------|
| Agent runtime | Claude Agent SDK, always-on, API-backed |
| Triggering | MCP-initiated from channel conversations |
| Orchestration | GenServer per run (Approach 3), push-based |
| State management | Live GenServer state, DB as checkpoint |
| Tier 2 | AI + StreamData + mutation testing |
| Isolation | Separate MCP tokens with restricted scope |
| Completion | Auto-PR creation, human approves merge |

### Migration Path

Phase 1 -> Phase 2 is additive:
- `Slackex.Factory` context doesn't change -- GenServers call the same functions
- MCP tools don't change -- they still delegate to the context
- DB schema doesn't change -- GenServer state is hydrated from the same tables
- New MCP tools are added (not replacing old ones)
- Agent SDK sessions call the same MCP tools the human sessions use

The context module is the stable core. Everything above it (how agents connect) and below it (how state is stored) can evolve independently.
