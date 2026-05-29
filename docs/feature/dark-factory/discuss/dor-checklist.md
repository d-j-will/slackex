# Dark Factory Coordinator — Definition of Ready Checklist

**Date:** 2026-04-09
**Feature:** dark-factory (coordinator agent extension)
**Phase:** DISCUSS — Phase 3 DoR Validation

---

## DoR Items

### 1. User need is clearly stated
- [x] **Evidence:** 8 JTBD job stories with dimensions, four forces, and opportunity scoring. Primary job (Unattended Execution, score 18) is unambiguous. See `jtbd-job-stories.md`.

### 2. Acceptance criteria are testable
- [x] **Evidence:** 26 acceptance criteria in Given/When/Then format across 5 slices. All criteria reference observable state transitions, thread messages, or file system artifacts. See `acceptance-criteria.md`.

### 3. Dependencies are identified
- [x] **Evidence:** Phase 1 backend (11 tasks in `deliver/plan.md`) must be complete. Dependency table in `prioritization.md` maps each story to the Phase 1 tasks it requires. No external dependencies beyond Claude Code Max subscription.

### 4. Architecture constraints are documented
- [x] **Evidence:** 6 constraints documented in `requirements.md` (C-1 through C-6). NFR-1 explicitly states no server-side changes. Coordinator is a client of Phase 1 MCP tools. Architecture doc (approved) defines the MCP protocol.

### 5. Scope is bounded and estimable
- [x] **Evidence:** 20 stories across 5 slices. Walking skeleton (P0) is 9 stories, estimated ~1 day. Each subsequent slice is ~0.5 day. Total: ~3 days for all slices. Story sizes range XS-M with no L/XL stories.

### 6. Risks are identified with mitigations
- [x] **Evidence:** 7 risks in `prioritization.md` risk matrix. Highest risk (worktree agent spawn) is addressed by validating in walking skeleton. Response matching (Open Question #3) flagged as must-resolve before P1.

### 7. UX/journey is mapped
- [x] **Evidence:** 3 journey maps (factory execution, clarification, verification) with visual diagrams, YAML schemas, Gherkin scenarios, and emotional arcs. Shared artifacts registry tracks all `${variable}` sources. See `journey-*-visual.md`.

### 8. Success metrics are defined
- [x] **Evidence:** Outcome KPIs with measurable targets in `outcome-kpis.md`. Leading indicators (queue drain rate, Tier 2 catch rate) and lagging indicators (human intervention rate, spec improvement velocity).

### 9. No open blocking questions
- [ ] **Partially met.** Three open questions from the coordinator spec must be resolved before implementation:

| Question | Status | Recommended Resolution |
|----------|--------|----------------------|
| OQ-3: Response matching for clarifications | **Open** | Require `[RE:CLARIFY:...]` prefix in human replies. Fall back to position-based with coordinator confirmation. |
| OQ-2: Clarification quality / confidence threshold | **Resolved in stories** | AC-12 defines the threshold: "wrong guess changes >1 test case." |
| OQ-4: Verification coordinator | **Resolved in stories** | Same coordinator manages both implementing and verification agents. |
| OQ-1: Concurrency limit configurability | **Resolved in stories** | Per-session via environment variable, default 2. |
| OQ-5: Worktree warm cache | **Resolved in stories** | Don't share `_build`. Pre-seed `deps` only. |

**Remaining blocker:** OQ-3 (response matching) needs a concrete design decision before Slice 2 (P1) implementation. Does not block Slice 1 (P0).

---

## DoR Verdict

**8 of 9 items fully met. 1 partially met (OQ-3 open but non-blocking for walking skeleton).**

**Ready for DESIGN wave** with the caveat that OQ-3 must be resolved before P1 implementation begins. The walking skeleton (P0) has no open questions.
