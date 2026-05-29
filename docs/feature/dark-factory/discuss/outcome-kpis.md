# Dark Factory Coordinator — Outcome KPIs

**Date:** 2026-04-09
**Feature:** dark-factory (coordinator agent extension)
**Phase:** DISCUSS — Phase 3 Requirements

---

## Primary KPIs

### KPI-1: Human Intervention Rate
**What:** Percentage of factory runs that complete (queued -> completed) without any human interaction beyond the initial queue and final review.
**Target:** >60% of runs complete unattended within 3 months of coordinator launch.
**Measurement:** `(runs where status reached "completed" without clarification or needs_review) / total runs`
**Job:** A (Unattended Execution)
**Why this target:** Early runs will surface spec quality issues, driving clarification. As specs improve (Job F), the rate should climb.

### KPI-2: Tier 2 Catch Rate
**What:** Percentage of factory runs where Tier 2 verification catches at least one issue the implementing agent missed.
**Target:** >20% of runs have at least 1 Tier 2 scenario fail.
**Measurement:** `(runs where tier2_result.scenarios_passed < tier2_result.scenarios_run) / total verified runs`
**Job:** H (Independent Verification)
**Why this target:** If Tier 2 never catches anything, either (a) the implementing agent is perfect (unlikely) or (b) the verification agent generates trivial scenarios. If >50% fail, specs are too ambiguous. 20% indicates the verification is genuinely adding value without the factory being fundamentally broken.

### KPI-3: Clarification Efficiency
**What:** Average number of clarification requests per run.
**Target:** <2 clarifications per run within 3 months.
**Measurement:** Count of `[CLARIFY:...]` messages per run, averaged.
**Job:** B (Clarification Over Guessing)
**Why this target:** More than 2 per run suggests specs need structural improvement. Zero suggests agents are guessing instead of asking (confidence threshold too high) or specs are unusually complete.

---

## Secondary KPIs

### KPI-4: Queue Drain Rate
**What:** Average time from `queued` to `completed` per run.
**Target:** <4 hours for a typical Tenun feature (P0 slice). <2 hours with concurrency (P2 slice).
**Measurement:** `completed_at - inserted_at` for successful runs.
**Job:** C (Concurrent Throughput)

### KPI-5: Crash Recovery Success Rate
**What:** Percentage of coordinator crashes where in-progress work is recovered (not restarted from scratch).
**Target:** >80% of recoverable runs resumed successfully.
**Measurement:** `(runs where worktree was reused after crash) / (runs active at time of crash)`
**Job:** E (Crash Resilience)

### KPI-6: Spec Improvement Velocity
**What:** Number of spec amendments approved per month through the clarification feedback loop.
**Target:** >5 amendments per month in first 3 months (declining as specs mature).
**Measurement:** Count of approved `[SPEC-AMENDMENT:...]` per month.
**Job:** F (Spec Refinement Through Use)

### KPI-7: Attempt Efficiency
**What:** Average number of implementation attempts before success or escalation.
**Target:** <1.5 attempts per run.
**Measurement:** `average(attempt)` at time of `awaiting_verification` or `needs_review`.
**Why:** High attempt counts indicate either agent quality issues or spec quality issues. Trending up = something is degrading.

---

## Anti-KPIs (Things That Should NOT Happen)

| Anti-KPI | Threshold | Response |
|----------|-----------|----------|
| Verification agent reads implementation before generating scenarios | 0 tolerance | Fix prompt, add audit check |
| Coordinator claims work while Phase 1 backend is unavailable | 0 tolerance | Check flag + connectivity before claiming |
| Heartbeat misses causing false stale release | <5% of runs | Increase heartbeat frequency or timeout |
| Spec amendment applied without human approval | 0 tolerance | Approval is mandatory (AC-26) |
| Concurrent agents interfere with each other (shared _build) | 0 tolerance | Worktree isolation enforced (AC-20) |

---

## Measurement Infrastructure

These KPIs are measurable from existing data:

| KPI | Data Source |
|-----|------------|
| KPI-1 (intervention rate) | `factory_runs` table: runs that went queued -> completed without `needs_review` or clarification events |
| KPI-2 (Tier 2 catch rate) | `factory_runs.tier2_result`: compare `scenarios_passed` vs `scenarios_run` |
| KPI-3 (clarification count) | `factory_events` table: count events with `[CLARIFY:...]` in message per run |
| KPI-4 (drain rate) | `factory_runs`: `completed_at - inserted_at` |
| KPI-5 (crash recovery) | Coordinator logs (not in DB — requires log analysis or future instrumentation) |
| KPI-6 (spec amendments) | Thread messages: count approved `[SPEC-AMENDMENT:...]` (requires thread search) |
| KPI-7 (attempt efficiency) | `factory_runs.attempt` at terminal state |

**Phase 2 instrumentation:** KPI-5 and KPI-6 would benefit from dedicated DB tracking. For Phase 1, thread messages and coordinator logs are sufficient.
