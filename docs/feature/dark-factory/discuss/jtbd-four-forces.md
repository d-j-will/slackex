# Dark Factory Coordinator — Four Forces Analysis

**Date:** 2026-04-09
**Feature:** dark-factory (coordinator agent extension)
**Phase:** DISCUSS — Phase 1 JTBD Analysis

---

## Job A — Unattended Execution

| Force | Description |
|-------|-------------|
| **Push** (current pain) | Must open a Claude Code session, say "check factory jobs", confirm each claim, monitor progress. Can't walk away. One session = one run. |
| **Pull** (desired future) | Queue specs, walk away, come back to completed branches with verification results in channel threads. |
| **Anxiety** (adoption fear) | "What if the coordinator does something stupid and I'm not watching? What if it claims work I didn't want it to?" |
| **Habit** (inertia) | Muscle memory of manually driving Claude Code sessions. Comfort of seeing every step happen. |

**Design implication:** The coordinator must earn trust gradually. Start with explicit confirmation before claiming work, then offer an "auto-claim" mode once the human trusts the system. Channel thread updates provide the "I can see what's happening" safety net that replaces direct terminal observation.

---

## Job H — Independent Verification

| Force | Description |
|-------|-------------|
| **Push** | Implementing agent writes tests that confirm its own assumptions — self-grading homework. Past incidents (v0.5.47-v0.5.64 pipeline events bridge) proved that unit tests passing doesn't mean the wiring exists. |
| **Pull** | A separate agent that only sees the spec generates scenarios the implementer never considered. Catches assumption errors, missing wiring, boundary conditions. |
| **Anxiety** | "Will the verification agent generate trivial tests that don't catch real bugs? Will it waste a cycle testing happy paths the implementer already covered?" |
| **Habit** | Trusting the implementing agent's test suite. Reviewing code manually as the quality gate. |

**Design implication:** Verification agent prompts must include project-specific antipatterns from `docs/rca/` — nil-id ghosts, swallowed Oban errors, missing PubSub wiring, partition key omissions. These aren't generic edge cases; they're Tenun's known failure modes. Verification quality depends on this context.

---

## Job B — Clarification Over Guessing

| Force | Description |
|-------|-------------|
| **Push** | Agents that guess wrong waste full implementation cycles (compile, test, pre-deploy — all on wrong assumptions). Agents that fail immediately provide no useful work. |
| **Pull** | Agent asks a specific question with `[CLARIFY:run-42:acceptance-criteria:3]` identifier, gets a targeted answer, resumes with correct understanding. |
| **Anxiety** | "Will the agent ask too many trivial questions? Will I become the bottleneck? Will unanswered questions block the factory?" |
| **Habit** | Writing specs and assuming they're complete. Not anticipating which parts the agent will find ambiguous. |

**Design implication:** Need a "confidence threshold" — agents should make judgment calls and document assumptions for low-stakes ambiguities, reserving clarification for questions where the wrong guess would change >1 test case. The 2-hour clarification timeout with "assume and document" fallback prevents the human from becoming a permanent bottleneck.

---

## Job C — Concurrent Throughput

| Force | Description |
|-------|-------------|
| **Push** | One session = one run at a time. Queue of 5 features takes 5 sequential sessions. Max subscription has capacity for more. |
| **Pull** | 2-3 features implementing simultaneously in isolated worktrees, queue drains 2-3x faster. |
| **Anxiety** | "Will concurrent Elixir compiles exhaust CPU/memory? Will API rate limits on Claude Code cause failures? Will my machine become unusable?" |
| **Habit** | Running one thing at a time, manually monitoring it. Sequential is simpler to reason about. |

**Design implication:** Default concurrency of 2 is conservative and correct. The coordinator should monitor system resources and auto-throttle if memory pressure rises. Each worktree has its own `_build` directory — concurrent compiles are CPU-bound and memory-hungry.

---

## Job E — Crash Resilience

| Force | Description |
|-------|-------------|
| **Push** | Coordinator crash = all in-progress work lost. Worktrees orphaned with partial implementations. Claims go stale after heartbeat timeout, runs re-queue, work restarts from scratch. |
| **Pull** | Coordinator restarts, discovers `.factory/run-*` worktrees, re-reads run state from DB, resumes heartbeating and monitoring. |
| **Anxiety** | "Is the recovery reliable? Will it resume in a weird half-state? Will it accidentally re-claim work that was already re-queued?" |
| **Habit** | Mentally preparing for loss. Not running the coordinator before leaving the machine. Treating long-running jobs as risky. |

**Design implication:** Recovery must be conservative — on restart, the coordinator should inventory worktrees, check DB state for matching runs, and only resume heartbeating for runs that are still `implementing` or `verifying_tier2` with a matching claim token persisted locally. If the claim was already released (timeout), don't fight it — let the run re-queue naturally.

---

## Job G — Protocol Abstraction

| Force | Description |
|-------|-------------|
| **Push** | Must remember the MCP tool sequence: `list_factory_work` → pick run → `claim_factory_work` → implement → `factory_heartbeat` (every 5 min) → `submit_factory_result`. Token management, heartbeat cadence, error handling. |
| **Pull** | Say "check factory jobs" or start the coordinator, and it handles the entire protocol transparently. |
| **Anxiety** | "Am I losing control by abstracting the protocol? Will I lose visibility into what's happening?" |
| **Habit** | Manually calling MCP tools in sequence. Feeling of control from each explicit step. |

**Design implication:** The coordinator is the abstraction. Channel thread updates replace terminal observation. The human's interaction surface becomes: queue specs, read threads, answer clarifications, review completed branches.

---

## Job F — Spec Refinement Through Use

| Force | Description |
|-------|-------------|
| **Push** | Same spec ambiguities surface across multiple runs. Each run re-discovers the same gaps. Clarification Q&A lives in channel threads and is forgotten. |
| **Pull** | After a run completes, coordinator collects all `[CLARIFY:...]` Q&A pairs and proposes spec amendments. Approved changes prevent future clarifications on the same points. |
| **Anxiety** | "Will auto-amendments corrupt my carefully written specs? Will the coordinator misinterpret Q&A context?" |
| **Habit** | Treating specs as static write-once documents. Editing specs is a separate activity from running the factory. |

**Design implication:** Spec amendments should be proposed, not applied. The coordinator posts proposed changes to the thread for human review. Only explicit approval triggers the update. This makes the feedback loop opt-in per amendment.

---

## Job D — Ambient Awareness

| Force | Description |
|-------|-------------|
| **Push** | No visibility into agent progress during autonomous execution. Is it stuck? Making progress? About to finish? Blocked on a compile error? |
| **Pull** | Thread shows structured updates: "Implementing step 3/7: CSV parser module", "Running pre-deploy checks...", "[CLARIFY:...] question posted" |
| **Anxiety** | "Will the updates be noisy? Will they drown out real channel conversation?" |
| **Habit** | Checking the Claude Code terminal directly for progress. |

**Design implication:** Updates go to the run's thread (not the channel top-level), keeping noise contained. The coordinator posts on behalf of agents, aggregating heartbeats into meaningful step-level updates rather than raw "still alive" pings.
