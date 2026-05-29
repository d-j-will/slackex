# Dark Factory Coordinator — User Stories

**Date:** 2026-04-09
**Feature:** dark-factory (coordinator agent extension)
**Phase:** DISCUSS — Phase 3 Requirements

---

All stories trace to JTBD jobs. Format: LeanUX hypothesis + standard user story.

## Slice 1: Walking Skeleton (P0)

### S1: Queue a factory run
**Job:** A (Unattended Execution), G (Protocol Abstraction)
**Story:** As a human operator, I want to queue a feature spec for factory implementation, so the coordinator can pick it up without further intervention.
**Hypothesis:** We believe that providing a single MCP tool (`queue_factory_run`) as the sole human input will reduce the steps needed to start factory work from ~10 (manual session) to 1.
**Size:** XS

### S2: Coordinator polls and claims
**Job:** A (Unattended Execution), G (Protocol Abstraction)
**Story:** As the coordinator agent, I want to periodically poll for queued work and claim it automatically, so the human doesn't need to confirm each claim.
**Hypothesis:** We believe that automatic polling and claiming will eliminate the babysitting requirement, enabling true unattended execution.
**Size:** S

### S3: Spawn worktree-isolated agent
**Job:** A (Unattended Execution), C (Concurrent Throughput)
**Story:** As the coordinator agent, I want to spawn an implementing agent in an isolated git worktree, so each run has a clean environment and concurrent runs don't interfere.
**Hypothesis:** We believe that worktree isolation via Claude Code's `isolation: "worktree"` will provide sufficient separation for concurrent factory runs.
**Size:** M (highest technical risk in walking skeleton)

### S4: Heartbeat on behalf of agents
**Job:** A (Unattended Execution), D (Ambient Awareness)
**Story:** As the coordinator agent, I want to heartbeat on behalf of all active agents, so their claims stay alive and the thread shows progress.
**Hypothesis:** We believe that centralized heartbeating simplifies agent design (agents don't need MCP access) and provides consistent progress updates.
**Size:** S

### S5: Submit result on completion
**Job:** A (Unattended Execution), G (Protocol Abstraction)
**Story:** As the coordinator agent, I want to submit results when an agent finishes, handling the success/retry/fail branching, so the pipeline advances without human intervention.
**Hypothesis:** We believe that coordinator-managed submission with automatic retry handling will reduce the manual steps from ~5 (check result, decide retry, re-run) to 0.
**Size:** S

### S6: Claim verification work
**Job:** H (Independent Verification)
**Story:** As the coordinator agent, I want to claim runs awaiting verification and spawn a verification agent, so independent verification happens automatically after implementation.
**Hypothesis:** We believe that automatic verification claiming will reduce the delay between implementation and verification from hours (manual) to minutes (next poll cycle).
**Size:** S

### S7: Verification agent reads spec only
**Job:** H (Independent Verification)
**Story:** As the verification agent, I want to read only the spec and project constraints before generating scenarios, so my scenarios are truly independent of the implementation approach.
**Hypothesis:** We believe that spec-only scenario generation will catch bugs that the implementing agent's self-tests miss, because the verification agent has no bias toward the implementation's assumptions.
**Size:** M (isolation discipline is the critical quality attribute)

### S8: Run scenarios and submit verification
**Job:** H (Independent Verification)
**Story:** As the verification agent, I want to run my generated scenarios against the feature branch and have the coordinator submit the results, so the pipeline reaches a terminal state automatically.
**Hypothesis:** We believe that Tier 2 verification will catch at least 1 issue per 5 factory runs that Tier 1 self-tests missed.
**Size:** S

### S9: Human reviews from thread
**Job:** A (Unattended Execution)
**Story:** As a human operator, I want to see a completion summary in the channel thread with the branch name and verification results, so I can review and merge without searching for context.
**Hypothesis:** We believe that thread-based completion notifications will reduce the time between "factory done" and "human reviews" from hours to minutes.
**Size:** XS

---

## Slice 2: Clarification Threading (P1)

### S10: Agent requests clarification
**Job:** B (Clarification Over Guessing)
**Story:** As an implementing agent, I want to ask the coordinator to post a clarification question to the channel thread when I encounter a high-stakes spec ambiguity, so I get a correct answer instead of guessing.
**Hypothesis:** We believe that targeted clarification will reduce wasted implementation cycles by >50% for specs with ambiguities.
**Size:** M

### S11: Coordinator forwards human reply
**Job:** B (Clarification Over Guessing)
**Story:** As the coordinator agent, I want to detect human replies to clarification questions in the thread and forward them to the waiting agent, so the agent can resume with the correct understanding.
**Hypothesis:** We believe that thread-based async Q&A will provide answers within 30 minutes for most clarifications during working hours.
**Size:** M (thread polling and response matching are the unknowns)

### S12: Clarification timeout
**Job:** B (Clarification Over Guessing)
**Story:** As the coordinator agent, I want to enforce a timeout on unanswered clarifications, so agents aren't blocked indefinitely when the human is unavailable.
**Hypothesis:** We believe that a 2-hour timeout with assume-or-fail fallback prevents the human from becoming a permanent bottleneck.
**Size:** S

### S15: Structured progress messages
**Job:** D (Ambient Awareness)
**Story:** As a human operator, I want to see structured progress in the thread ("step 3/7: CSV parser"), so I know exactly where each run stands without checking the terminal.
**Hypothesis:** We believe that step-level progress reduces "is it working?" anxiety to near zero.
**Size:** XS

---

## Slice 3: Concurrent Execution (P2)

### S13: N concurrent agents
**Job:** C (Concurrent Throughput)
**Story:** As the coordinator agent, I want to run up to N agents simultaneously, so the factory queue drains faster.
**Hypothesis:** We believe that concurrency=2 will reduce queue drain time by ~40% (not 50% due to shared CPU).
**Size:** S

### S14: Claim as slots free
**Job:** C (Concurrent Throughput)
**Story:** As the coordinator agent, I want to claim new work whenever a slot frees up, so the factory is always running at capacity.
**Hypothesis:** We believe that immediate backfill on completion will keep utilization above 80% during active factory operation.
**Size:** XS

---

## Slice 4: Crash Resilience (P3)

### S16: Worktree discovery on restart
**Job:** E (Crash Resilience)
**Story:** As the coordinator agent, I want to discover orphaned `.factory/run-*` worktrees on startup and reconcile them with DB state, so I can recover from crashes.
**Hypothesis:** We believe that worktree-based recovery will preserve >80% of in-progress work after a coordinator crash.
**Size:** M

### S17: Resume heartbeating
**Job:** E (Crash Resilience)
**Story:** As the coordinator agent, I want to resume heartbeating for recoverable runs immediately on restart, so their claims don't get released by the LifecycleWorker.
**Hypothesis:** We believe that fast heartbeat resume (within one poll cycle) will prevent stale release for most crash-recovery scenarios.
**Size:** S

---

## Slice 5: Spec Refinement (P4)

### S18: Collect clarification Q&A
**Job:** F (Spec Refinement Through Use)
**Story:** As the coordinator agent, I want to collect all clarification Q&A pairs from a completed run's thread, so I can propose spec improvements.
**Size:** S

### S19: Propose spec amendments
**Job:** F (Spec Refinement Through Use)
**Story:** As the coordinator agent, I want to post proposed spec amendments to the thread based on clarification Q&A, so the human can improve the spec for future runs.
**Size:** S

### S20: Human approves amendments
**Job:** F (Spec Refinement Through Use)
**Story:** As a human operator, I want to approve or reject individual spec amendments, so my specs improve without unwanted changes.
**Size:** XS
