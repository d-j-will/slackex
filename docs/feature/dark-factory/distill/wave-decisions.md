# DISTILL Decisions — dark-factory (coordinator agent)

**Date:** 2026-04-09
**Wave:** DISTILL (wave 5 of 6)

---

## Key Decisions

- [D1] **Two-layer testing strategy:** Layer 1 (ExUnit, automated, CI) for Phase 1 backend. Layer 2 (behavioral, manual first-run) for coordinator behavior. Rationale: coordinator is a Claude Code session, not compiled code — automated testing requires Phase 2 Agent SDK. (see: `test-scenarios.md`)

- [D2] **Test framework: ExUnit** — Elixir's native test framework. Only viable option for this project. Gherkin scenarios from DISCUSS serve as behavioral specification, not executable BDD tests. (see: `test-scenarios.md`)

- [D3] **Integration approach: Real services** — All tests hit real PostgreSQL. No mocks at any level. Project convention per CLAUDE.md: "never mock the database." (see: `test-scenarios.md`)

- [D4] **Pipeline integration test (new file):** Added `pipeline_test.exs` to verify PubSub wiring and full state machine traversal. This was missing from the Phase 1 implementation plan — the plan had context tests and MCP tests but no dedicated wiring tests. (see: `test-scenarios.md` IC-1 through IC-4)

- [D5] **ChannelNotifier wiring test (new file):** Added `channel_notifier_test.exs` to verify PubSub -> thread message path exists. Required by CLAUDE.md spec-driven acceptance test mandate. (see: `acceptance-review.md`)

- [D6] **Walking skeleton first spec:** A deliberately simple spec ("add factory_run_count to bot user profile") to exercise the full coordinator pipeline on first run. (see: `walking-skeleton.md`)

- [D7] **No infrastructure testing:** Coordinator is client-side. No deployment changes. No CI/CD modifications. DEVOPS wave is skipped for this feature.

## Test Coverage Summary

- **Total scenarios:** 63 (46 automated + 17 behavioral)
- **Walking skeleton scenarios:** 9 (5 automated + 4 behavioral)
- **Acceptance criteria coverage:** 26/26 (100%)
- **Story coverage:** 20/20 (100%)
- **Test framework:** ExUnit
- **Integration approach:** Real services (PostgreSQL, PubSub, Oban)

### By Release Slice

| Slice | Layer 1 (ExUnit) | Layer 2 (Behavioral) | Total |
|-------|:----------------:|:-------------------:|:-----:|
| P0: Walking Skeleton | ~40 | 4 | ~44 |
| P1: Clarification | 0 | 5 | 5 |
| P2: Concurrency | 0 | 3 | 3 |
| P3: Crash Resilience | ~6 | 2 | ~8 |
| P4: Spec Refinement | 0 | 3 | 3 |

## Constraints Established

- Layer 2 behavioral tests are executed manually by running the coordinator — they are NOT automated CI tests
- Pipeline integration tests (IC-1 through IC-4) are mandatory — they catch TBU (Tested But Unwired) defects
- Feature flag tests must cover ALL entry points (MCP tools, LifecycleWorker, ChannelNotifier)
- Walking skeleton behavioral test must be the first test after Slice 1 ships

## Upstream Issues

- **Phase 1 plan gap:** The implementation plan (`deliver/plan.md`) has no dedicated PubSub wiring tests or ChannelNotifier integration tests. DISTILL adds `pipeline_test.exs` and `channel_notifier_test.exs` as new test files (Task 7.5 and Task 8 expansion). These should be added to the plan before DELIVER begins.

- **AC-7 nuance:** `list_pending_verification/1` returns full `Run` structs including `tier1_result` field. Isolation is enforced by the coordinator's prompt (only passes 3 fields), not by the query. This is acceptable for Phase 1 but should be noted in the verification agent prompt design.

---

## Artifact Inventory

| Artifact | Path |
|----------|------|
| Walking Skeleton | `distill/walking-skeleton.md` |
| Test Scenarios | `distill/test-scenarios.md` |
| Acceptance Review | `distill/acceptance-review.md` |
| Wave Decisions | `distill/wave-decisions.md` |

**Total: 4 artifacts**

---

## Handoff

**Ready for:** nw-software-crafter / nw-functional-software-crafter (DELIVER wave)
**Key artifacts for DELIVER:**
- `distill/test-scenarios.md` — authoritative test specification with driving ports
- `distill/walking-skeleton.md` — first-run acceptance test plan
- `discuss/acceptance-criteria.md` — business acceptance criteria
- `design/architecture-coordinator.md` — component context
- `deliver/plan.md` — implementation plan (Phase 1 backend)

**DELIVER scope:**
1. Phase 1 backend (11 tasks from `deliver/plan.md` + 2 new test tasks from DISTILL)
2. Coordinator skill (5 slices from `discuss/story-map.md`)
