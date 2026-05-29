# Dark Factory Coordinator — Opportunity Scores

**Date:** 2026-04-09
**Feature:** dark-factory (coordinator agent extension)
**Phase:** DISCUSS — Phase 1 JTBD Analysis
**Method:** Ulwick Opportunity Algorithm: `Opportunity = Importance + max(Importance - Satisfaction, 0)`

---

## Scoring

| Rank | Job | Importance (1-10) | Satisfaction (1-10) | Opportunity | Category |
|------|-----|:-----------------:|:-------------------:|:-----------:|----------|
| 1 | A — Unattended Execution | 10 | 2 | **18** | Primary job |
| 2 | H — Independent Verification | 9 | 2 | **16** | Primary job |
| 3 | B — Clarification Over Guessing | 8 | 1 | **15** | Primary job |
| 4 | C — Concurrent Throughput | 7 | 1 | **13** | Enabler |
| 5 | E — Crash Resilience | 7 | 1 | **13** | Enabler |
| 6 | G — Protocol Abstraction | 6 | 2 | **10** | Enabler |
| 7 | F — Spec Refinement | 5 | 1 | **9** | Secondary |
| 8 | D — Ambient Awareness | 6 | 4 | **8** | Secondary |

---

## Satisfaction Rationale

| Job | Current Satisfaction | Why |
|-----|:-------------------:|-----|
| A | 2 | Phase 1 requires human to open session, confirm claims, monitor. Not unattended. |
| H | 2 | Verification agent exists in Phase 1 design but requires manual session start. The isolation protocol is defined but not enforced. |
| B | 1 | No clarification mechanism exists. Agents guess or fail. |
| C | 1 | One session = one run. No concurrency. |
| E | 1 | No crash recovery. Coordinator crash loses all in-progress work. |
| G | 2 | Skills partially abstract the protocol, but human still drives each step. |
| F | 1 | No spec feedback mechanism. Clarification Q&A lives and dies in conversation history. |
| D | 4 | Phase 1 heartbeat messages provide basic progress. Not structured, not automatic. |

---

## Job Clusters

### Cluster 1: Core Value (Jobs A, H, B) — Opportunity 15-18

These three jobs define what the coordinator IS. Without unattended execution, it's not a coordinator. Without independent verification, the factory has no credibility. Without clarification, unattended execution only works for perfect specs (which don't exist).

**Dependency chain:** B enables A (clarification prevents wasted cycles during unattended execution). H validates A's output (independent verification proves the unattended work is correct).

### Cluster 2: Enablers (Jobs C, E, G) — Opportunity 10-13

These jobs make the coordinator practical. Concurrent throughput (C) makes unattended execution worthwhile — one-at-a-time unattended is still slow. Crash resilience (E) makes unattended execution safe — you can't walk away if a crash loses everything. Protocol abstraction (G) removes the human from the mechanical loop.

**Dependency chain:** G is required for A (can't be unattended if human must drive protocol). C amplifies A's value. E makes A safe.

### Cluster 3: Secondary (Jobs F, D) — Opportunity 8-9

Valuable but not blocking. Spec refinement (F) is a virtuous cycle that improves over time. Ambient awareness (D) is partially served by Phase 1 heartbeats.

**These can ship in a later iteration** without degrading the core coordinator experience.

---

## Implementation Priority

Based on dependency analysis and opportunity scores:

1. **Must have (MVP):** A + G + H + B — unattended execution with protocol abstraction, independent verification, and clarification
2. **Should have (v1.1):** C + E — concurrency and crash resilience make it practical for daily use
3. **Nice to have (v1.2):** D + F — structured awareness and spec feedback loop
