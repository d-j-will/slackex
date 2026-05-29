# Dark Factory Coordinator — Component Boundaries

**Date:** 2026-04-09
**Wave:** DESIGN

---

## Component Map

The coordinator system has three runtime components (Claude Code sessions) and no new server-side components.

```
┌─────────────────────────────────────────────────────────────┐
│ Dev Machine                                                  │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ Coordinator Session (long-lived)                      │   │
│  │                                                       │   │
│  │  ┌─────────────┐  ┌──────────────┐  ┌────────────┐  │   │
│  │  │ Poll Loop   │  │ Claim Manager│  │ Heartbeat  │  │   │
│  │  │             │  │              │  │ Manager    │  │   │
│  │  └─────────────┘  └──────────────┘  └────────────┘  │   │
│  │  ┌─────────────┐  ┌──────────────┐  ┌────────────┐  │   │
│  │  │ Clarify Mgr │  │ Agent Spawner│  │ Recovery   │  │   │
│  │  │             │  │              │  │ Manager    │  │   │
│  │  └─────────────┘  └──────────────┘  └────────────┘  │   │
│  └──────────────────────────────────────────────────────┘   │
│       │ Agent tool                │ Agent tool               │
│       v                          v                           │
│  ┌──────────────┐          ┌──────────────┐                 │
│  │ Impl Agent   │          │ Verif Agent  │                 │
│  │ (worktree)   │          │ (worktree)   │                 │
│  │ .factory/    │          │ .factory/    │                 │
│  │  run-42/     │          │  run-57/     │                 │
│  └──────────────┘          └──────────────┘                 │
│                                                              │
└─────────────────────────────────────────────────────────────┘
         │ MCP/SSE                        │ Git push
         v                                v
┌──────────────────┐              ┌──────────────┐
│ Tenun Platform   │              │ GitHub       │
│ (existing, no    │              │ (existing)   │
│  changes)        │              │              │
└──────────────────┘              └──────────────┘
```

---

## Boundary Definitions

### Coordinator Session

**Responsibility:** Orchestrate factory runs. Poll for work, claim, spawn agents, heartbeat, relay clarifications, submit results, clean up.

**Owns:**
- Poll loop timing and concurrency decisions
- Active agent registry (ephemeral)
- Clarification state tracking (ephemeral)
- Heartbeat scheduling
- Worktree lifecycle (create/remove)

**Does NOT own:**
- Run state machine (owned by Factory context via MCP)
- Thread message persistence (owned by Messaging context)
- Timeout enforcement (owned by LifecycleWorker)
- Feature flag evaluation (owned by Tenun, coordinator checks via MCP response)

**Interface IN:** Human starts the session. SendMessage from worker agents.
**Interface OUT:** MCP tools (Tenun). Agent tool (spawn workers). Git commands.

### Implementing Agent

**Responsibility:** Read a spec, implement it with TDD in a worktree, run pre-deploy checks, report result.

**Owns:**
- Implementation decisions within the spec's constraints
- Test writing and iteration
- Pre-deploy check execution
- Git operations within its worktree

**Does NOT own:**
- MCP communication (coordinator handles)
- Heartbeat timing (coordinator handles)
- Claim management (coordinator handles)
- Thread posting (coordinator handles)

**Interface IN:** Prompt from coordinator (spec content, project context). SendMessage from coordinator (clarification answers).
**Interface OUT:** SendMessage to coordinator (completion, failure, clarification request). Git push.

### Verification Agent

**Responsibility:** Read a spec (at pinned SHA), generate unseen scenarios, run them against the feature branch, report results.

**Owns:**
- Scenario generation from spec alone
- Test execution against the feature branch
- Quality of scenario coverage

**Does NOT own:**
- Implementation context (must never access)
- MCP communication (coordinator handles)
- Verdict on what to do with failures (human decides)

**Interface IN:** Prompt from coordinator (spec path, commit SHA, branch name — NO tier1_result, NO impl context).
**Interface OUT:** SendMessage to coordinator (verification result). Git push (verification branch).

---

## Isolation Boundaries

### Worker Agent Isolation (Worktree)

Each worker agent operates in a git worktree at `.factory/run-{id}/`. This provides:
- **File system isolation:** Changes in one worktree don't affect another
- **Build isolation:** Each worktree has its own `_build/` and `deps/`
- **Git isolation:** Each worktree is on its own branch

Workers cannot:
- Access each other's worktrees
- Access the main working directory's state
- Call MCP tools directly (no token)

### Verification Isolation (Prompt-enforced)

The verification agent's prompt explicitly instructs:
1. Read spec at `${spec_commit_sha}` FIRST
2. Read CLAUDE.md and RCA docs for antipattern context
3. Generate scenarios BEFORE checking out the implementation branch
4. Never read Tier 1 results, implementation conversation, or progress messages

Phase 1 enforcement is prompt-based. Phase 2 will enforce via restricted MCP token scope.

### Coordinator-Tenun Boundary (MCP)

The coordinator interacts with Tenun exclusively through MCP tools. It cannot:
- Access the database directly
- Modify run state outside the defined state machine
- Bypass feature flag checks (tools return errors when flag is off)
- Impersonate users other than its bot user

---

## Dependency Inversion

The coordinator depends on abstractions (MCP tool contracts), not implementations:

```
Coordinator
    │
    │ depends on
    v
MCP Tool Interface (list/claim/heartbeat/submit)
    │
    │ implemented by
    v
Tenun Factory Context (Ecto, PostgreSQL)
```

If Phase 2 replaces the MCP transport (e.g., WebSocket push instead of SSE poll), the coordinator's behavior changes minimally — only the polling mechanism, not the business logic.

Similarly, the coordinator depends on Claude Code's Agent tool interface. If the agent spawning mechanism changes (e.g., Agent SDK in Phase 2), the coordinator's orchestration logic stays the same — only the spawning call changes.
