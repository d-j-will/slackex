# DISCUSS Decisions — dark-factory (coordinator agent)

**Date:** 2026-04-09
**Wave:** DISCUSS (Phase 2 of 6)

---

## Key Decisions

- [D1] **Feature type: Infrastructure** — The coordinator is a client-side orchestration layer (Claude Code skills/prompts + MCP protocol). No Tenun server-side changes. Rationale: keeps Phase 1 backend stable while proving concurrent execution. (see: `requirements.md` NFR-1)

- [D2] **Walking skeleton: Depends (brownfield)** — Phase 1 backend must exist first. The coordinator's walking skeleton (Slice 1, 9 stories) is the first coordinator-specific deliverable. (see: `story-map.md` Slice 1)

- [D3] **UX research depth: Comprehensive** — Three distinct journeys mapped with emotional arcs, covering all 8 jobs. Not deep-dive because the primary "user" is the human operator (single persona). (see: `journey-*-visual.md`)

- [D4] **JTBD: Yes** — 8 jobs identified. Core insight: unattended execution (Job A) is the primary job, but it only works with clarification (Job B) for imperfect specs, and only has credibility with independent verification (Job H). (see: `jtbd-opportunity-scores.md`)

- [D5] **Coordinator implementation: Long-lived session (Option B)** — Recommended in coordinator spec. Natural fit for stateful, long-running orchestration with team coordination. (see: `coordinator-agent.md` §7)

- [D6] **Concurrency default: 2** — Conservative. Bounded by CPU (Elixir compiles), memory (concurrent `_build`), and API rate limits. Configurable per session. (see: `requirements.md` FR-4.1)

- [D7] **Clarification confidence threshold: >1 test case** — Agent asks only when the wrong guess would change more than 1 test case. Low-stakes ambiguities are assumed and documented. (see: `acceptance-criteria.md` AC-12)

- [D8] **Verification never retries** — Tier 2 failure always escalates to `needs_review`. Rationale: verification failure indicates either a real bug or a spec gap, both requiring human judgment. (see: `acceptance-criteria.md` AC-9)

## Requirements Summary

- **Primary jobs/user needs:** Unattended factory execution (queue specs, walk away, come back to verified branches), independent verification by a spec-only agent, and clarification threading when specs are ambiguous.
- **Walking skeleton scope:** Single run, single agent, no clarification, no crash recovery. Proves coordinator can drive queue -> implement -> verify -> complete unattended.
- **Feature type:** Infrastructure (client-side orchestration, no server changes)

## Constraints Established

- Phase 1 backend must be implemented before coordinator work begins (C-1)
- Verification isolation is prompt-enforced in Phase 1, not cryptographically enforced (C-3)
- Coordinator does not deploy code — deployment is a separate human decision (C-5)
- GPU off-limits; all factory work runs locally on dev machine (C-4)
- `scripts/pre-deploy` must pass before any implementation submitted as success (C-6)

## Open Questions Resolved

| Question | Resolution | Source |
|----------|-----------|--------|
| Concurrency limit configurability | Per-session env var, default 2 | FR-4.4 |
| Clarification quality threshold | >1 test case impact | AC-12 |
| Verification coordinator | Same coordinator, same session | S6 |
| Worktree warm cache | Don't share `_build`, pre-seed `deps` only | NFR-6 |

## Open Questions Remaining

| Question | Blocks | Recommended Resolution |
|----------|--------|----------------------|
| Response matching for clarification replies | Slice 2 (P1) | Require `[RE:CLARIFY:...]` prefix. Fall back to position-based with confirmation. |

## Upstream Changes

- No DISCOVER documents exist to back-propagate changes to.
- The coordinator-agent.md spec (Draft, 2026-04-08) should be updated with:
  1. Resolved open questions (OQ-1, OQ-2, OQ-4, OQ-5) per this document
  2. A "Coordinator Recovery" section addressing crash resilience (Job E)
  3. A concrete response matching strategy (OQ-3) once decided

---

## Artifact Inventory

| Phase | Artifact | Path |
|-------|----------|------|
| 1 - JTBD | Job Stories | `discuss/jtbd-job-stories.md` |
| 1 - JTBD | Four Forces | `discuss/jtbd-four-forces.md` |
| 1 - JTBD | Opportunity Scores | `discuss/jtbd-opportunity-scores.md` |
| 2 - Journey | Factory Execution (visual) | `discuss/journey-factory-execution-visual.md` |
| 2 - Journey | Factory Execution (YAML) | `discuss/journey-factory-execution.yaml` |
| 2 - Journey | Factory Execution (Gherkin) | `discuss/journey-factory-execution.feature` |
| 2 - Journey | Clarification (visual) | `discuss/journey-clarification-visual.md` |
| 2 - Journey | Clarification (YAML) | `discuss/journey-clarification.yaml` |
| 2 - Journey | Clarification (Gherkin) | `discuss/journey-clarification.feature` |
| 2 - Journey | Verification (visual) | `discuss/journey-verification-visual.md` |
| 2 - Journey | Verification (YAML) | `discuss/journey-verification.yaml` |
| 2 - Journey | Verification (Gherkin) | `discuss/journey-verification.feature` |
| 2 - Journey | Shared Artifacts Registry | `discuss/shared-artifacts-registry.md` |
| 2.5 - Story Map | Story Map | `discuss/story-map.md` |
| 2.5 - Story Map | Prioritization | `discuss/prioritization.md` |
| 3 - Requirements | Requirements | `discuss/requirements.md` |
| 3 - Requirements | User Stories | `discuss/user-stories.md` |
| 3 - Requirements | Acceptance Criteria | `discuss/acceptance-criteria.md` |
| 3 - Requirements | DoR Checklist | `discuss/dor-checklist.md` |
| 3 - Requirements | Outcome KPIs | `discuss/outcome-kpis.md` |
| 3 - Summary | Wave Decisions | `discuss/wave-decisions.md` |

**Total: 21 artifacts**

---

## Handoff

**Ready for:** nw-solution-architect (DESIGN wave)
**Key artifacts for DESIGN:** `requirements.md`, `acceptance-criteria.md`, `story-map.md`, `outcome-kpis.md`
**Blocking question for DESIGN:** OQ-3 (response matching) must be resolved before designing Slice 2.
**KPIs for DEVOPS:** `outcome-kpis.md` (measurement infrastructure section)
