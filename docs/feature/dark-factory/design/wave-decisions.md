# DESIGN Decisions — dark-factory (coordinator agent)

**Date:** 2026-04-09
**Wave:** DESIGN (wave 3 of 6)

---

## Key Decisions

- [D1] **Architecture pattern: Coordinator-Worker with message passing** — Long-lived Claude Code session orchestrates worktree-isolated worker agents. Chosen over scheduled tasks (no SendMessage) and background agents (no shared state). (see: `adr-001-coordinator-as-claude-code-session.md`)

- [D2] **Centralized heartbeat delegation** — Coordinator heartbeats on behalf of all agents. Workers never call MCP directly. Trades single-point-of-failure risk for simplicity. (see: `adr-002-centralized-heartbeat-delegation.md`)

- [D3] **Clarification via message convention** — `[CLARIFY:...]` prefix on existing thread messages. No new MCP tools or DB columns. Response matching via positional detection with coordinator confirmation. (see: `adr-003-clarification-via-message-convention.md`)

- [D4] **Ephemeral coordinator state** — All coordinator state is in-memory, reconstructed from DB + worktrees + threads on restart. No local persistence files. (see: `adr-004-ephemeral-coordinator-state.md`)

- [D5] **Clarifying agents count toward concurrency limit** — Preserves resource guarantees (worktrees consume disk/memory even when paused). 2-hour timeout prevents indefinite slot occupation. (see: `architecture-coordinator.md` §7)

- [D6] **OQ-3 resolved: Positional matching with confirmation** — Coordinator treats first non-bot reply after a clarification as the answer candidate, posts confirmation, gives human 2 minutes to correct. For multiple pending clarifications, coordinator asks human to specify which question. (see: `architecture-coordinator.md` §8)

- [D7] **Zero Tenun-side changes** — Coordinator is a pure client of Phase 1 MCP tools. No new server code, no schema changes, no new dependencies. (see: `technology-stack.md`)

## Architecture Summary

- **Pattern:** Coordinator-Worker with message passing (Claude Code session + worktree-isolated agents)
- **Paradigm:** Functional (Elixir for Phase 1 backend; coordinator is prompt/skill-based, not compiled code)
- **Key components:**
  - Coordinator session (poll loop, claim manager, heartbeat manager, clarification manager, recovery manager)
  - Implementing agent (worktree-isolated, TDD workflow, pre-deploy checks)
  - Verification agent (worktree-isolated, spec-only context, unseen scenario generation)

## Technology Stack

- **Claude Code (Max subscription):** Coordinator session, Agent tool, SendMessage, worktree isolation
- **MCP over SSE:** Coordinator <-> Tenun communication (existing factory tools)
- **Git worktrees:** Isolated working directories per run (existing Git primitive)
- **Tenun platform (existing):** Factory context, ChannelNotifier, LifecycleWorker, MCP server

No new dependencies.

## Constraints Established

- Coordinator must be restartable at any time without data loss (all durable state in Tenun)
- Worker agents must never call MCP tools directly (centralized through coordinator)
- Verification agent must read spec before implementation code (prompt-enforced)
- Concurrency limit default 2, configurable per session
- Clarification timeout default 2 hours
- Heartbeat cadence: `heartbeat_timeout_minutes / 2`

## Upstream Changes

- **OQ-3 from coordinator-agent.md resolved:** Response matching uses positional detection with coordinator confirmation. The coordinator-agent.md spec should be updated with §8 of architecture-coordinator.md.
- **No DISCUSS requirements changed.** All 26 acceptance criteria are architecturally supported.
- **No user stories changed.** All 20 stories map to the component architecture.

## ADRs

| ADR | Decision | Status |
|-----|----------|--------|
| ADR-001 | Coordinator as long-lived Claude Code session | Accepted |
| ADR-002 | Centralized heartbeat delegation | Accepted |
| ADR-003 | Clarification via message convention, not protocol | Accepted |
| ADR-004 | Ephemeral coordinator state (not persisted to DB) | Accepted |

## Artifact Inventory

| Artifact | Path |
|----------|------|
| Architecture Design | `design/architecture-coordinator.md` |
| Component Boundaries | `design/component-boundaries.md` |
| Technology Stack | `design/technology-stack.md` |
| ADR-001 | `design/adr-001-coordinator-as-claude-code-session.md` |
| ADR-002 | `design/adr-002-centralized-heartbeat-delegation.md` |
| ADR-003 | `design/adr-003-clarification-via-message-convention.md` |
| ADR-004 | `design/adr-004-ephemeral-coordinator-state.md` |
| Wave Decisions | `design/wave-decisions.md` |

**Total: 8 artifacts** (plus 5 existing: architecture.md, coordinator-agent.md, plan.md)

---

## Handoff

**Ready for:** nw-acceptance-designer (DISTILL wave) and nw-platform-architect (DEVOPS wave)
**Key artifacts for DISTILL:** `acceptance-criteria.md` (from DISCUSS) + `architecture-coordinator.md` (component context for test design)
**Key artifacts for DEVOPS:** `technology-stack.md`, `component-boundaries.md` (though DEVOPS scope is minimal — no infrastructure changes)
**Note:** DEVOPS wave may be very thin for this feature since the coordinator is client-side only with no deployment changes.
