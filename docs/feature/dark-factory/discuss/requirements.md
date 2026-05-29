# Dark Factory Coordinator — Requirements

**Date:** 2026-04-09
**Feature:** dark-factory (coordinator agent extension)
**Phase:** DISCUSS — Phase 3 Requirements

---

## Functional Requirements

### FR-1: Coordinator Lifecycle (Jobs A, G)

| ID | Requirement | Priority |
|----|------------|----------|
| FR-1.1 | The coordinator runs as a long-lived Claude Code session that polls for factory work on a configurable interval. | P0 |
| FR-1.2 | The coordinator automatically claims available work without human confirmation (after initial setup). | P0 |
| FR-1.3 | The coordinator spawns a worktree-isolated agent for each claimed run. | P0 |
| FR-1.4 | The coordinator heartbeats on behalf of all active agents at `heartbeat_timeout_minutes / 2` cadence. | P0 |
| FR-1.5 | The coordinator submits results (success or failure) on behalf of agents when they complete. | P0 |
| FR-1.6 | The coordinator cleans up worktrees after runs reach terminal state. | P0 |
| FR-1.7 | The human's only interaction surface is: queue specs, read threads, answer clarifications, review branches. | P0 |

### FR-2: Independent Verification (Job H)

| ID | Requirement | Priority |
|----|------------|----------|
| FR-2.1 | The coordinator polls for verification work and claims available runs. | P0 |
| FR-2.2 | The coordinator spawns a verification agent that receives ONLY: spec_path, spec_commit_sha, branch_name. | P0 |
| FR-2.3 | The verification agent reads the spec BEFORE looking at implementation code. | P0 |
| FR-2.4 | The verification agent generates scenarios informed by project-specific antipatterns from `docs/rca/` and CLAUDE.md. | P0 |
| FR-2.5 | The verification agent pushes a verification branch (`factory/verify-run-{id}`) as a review artifact. | P0 |
| FR-2.6 | Verification failure always transitions to `needs_review` — never auto-retries. | P0 |

### FR-3: Clarification Threading (Jobs B, F)

| ID | Requirement | Priority |
|----|------------|----------|
| FR-3.1 | Implementing agents can send clarification requests to the coordinator when spec ambiguity is detected. | P1 |
| FR-3.2 | Clarification messages are posted to the run's channel thread with structured `[CLARIFY:{run_id}:{section}:{subsection}:{item}]` identifiers. | P1 |
| FR-3.3 | The coordinator polls the thread for human replies and forwards them to the waiting agent. | P1 |
| FR-3.4 | Agents apply a confidence threshold: only ask when the wrong guess would change >1 test case. | P1 |
| FR-3.5 | Clarification requests time out after a configurable duration (default: 2 hours). | P1 |
| FR-3.6 | On timeout, the agent either assumes and documents or submits failure if the ambiguity is too fundamental. | P1 |
| FR-3.7 | Multiple clarifications per run are tracked independently by the coordinator. | P1 |
| FR-3.8 | After run completion, the coordinator collects clarification Q&A and proposes spec amendments in the thread. | P4 |
| FR-3.9 | Spec amendments require explicit human approval before being applied. | P4 |

### FR-4: Concurrent Execution (Job C)

| ID | Requirement | Priority |
|----|------------|----------|
| FR-4.1 | The coordinator manages up to N concurrent agents (configurable, default: 2). | P2 |
| FR-4.2 | The coordinator claims new work as slots become available. | P2 |
| FR-4.3 | Each agent runs in an isolated worktree with its own `_build` directory. | P2 |
| FR-4.4 | The concurrency limit is configurable per session (environment variable or coordinator setting). | P2 |

### FR-5: Crash Resilience (Job E)

| ID | Requirement | Priority |
|----|------------|----------|
| FR-5.1 | On restart, the coordinator discovers orphaned `.factory/run-*` worktrees. | P3 |
| FR-5.2 | The coordinator reconciles discovered worktrees with DB run state. | P3 |
| FR-5.3 | For runs still in `implementing` with matching state, the coordinator re-claims and resumes. | P3 |
| FR-5.4 | For runs already released by timeout, the coordinator cleans up the orphaned worktree. | P3 |

### FR-6: Ambient Awareness (Job D)

| ID | Requirement | Priority |
|----|------------|----------|
| FR-6.1 | Heartbeat messages include structured progress: "Implementing step N/M: description". | P1 |
| FR-6.2 | All status transitions are posted to the run's thread (not top-level channel). | P0 |
| FR-6.3 | Clarification requests are visually distinct in the thread via `[CLARIFY:...]` prefix. | P1 |

---

## Non-Functional Requirements

| ID | Requirement | Category |
|----|------------|----------|
| NFR-1 | The coordinator introduces no changes to Tenun server-side code. It is purely a client of existing MCP tools. | Architecture |
| NFR-2 | All coordinator state is either in the DB (via MCP) or ephemeral (local to the session). Thread messages are the durable audit trail. | Data |
| NFR-3 | Feature-flagged behind `:dark_factory`. Coordinator skill/prompt only functions when the flag is enabled. | Safety |
| NFR-4 | The coordinator must not affect normal Tenun chat operation. ChannelNotifier failures do not cascade. | Isolation |
| NFR-5 | Heartbeat cadence must prevent stale claim release under normal operation (heartbeat_timeout / 2 margin). | Reliability |
| NFR-6 | Concurrent agent worktrees must not share `_build` directories (race condition risk). | Correctness |
| NFR-7 | The coordinator session can be stopped and restarted without data loss (DB + threads are the source of truth). | Resilience |

---

## Constraints

| ID | Constraint | Source |
|----|-----------|--------|
| C-1 | Phase 1 backend must be implemented first (MCP tools, Factory context, tables). | Architecture doc |
| C-2 | Claude Code Max subscription required for concurrent agents. | Resource |
| C-3 | Verification isolation is prompt-enforced in Phase 1 (not cryptographically enforced). | Architecture doc §3 |
| C-4 | GPU is off-limits on production server. All factory work runs locally on dev machine. | CLAUDE.md |
| C-5 | The coordinator does not deploy code. Deployment is a separate human decision (Phase 2 lifecycle). | Lifecycle proposal |
| C-6 | `scripts/pre-deploy` must pass before any implementation is submitted as success. | Engineering principles |
