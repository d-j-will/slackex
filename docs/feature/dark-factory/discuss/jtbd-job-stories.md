# Dark Factory Coordinator — JTBD Job Stories

**Date:** 2026-04-09
**Feature:** dark-factory (coordinator agent extension)
**Phase:** DISCUSS — Phase 1 JTBD Analysis

---

## Job Map

Eight jobs identified through analysis of the coordinator agent spec, Phase 1 architecture, and research documents. Ordered by opportunity score (highest first).

### Job A — Unattended Execution (Opportunity: 18)

> "When I have a well-specified feature queued, I want the factory to implement it without me opening and babysitting a Claude Code session, so I can work on other things or walk away entirely."

**Dimensions:**
- **Functional:** Run the factory pipeline without human session management
- **Emotional:** Freedom from babysitting anxiety; trust that work progresses autonomously
- **Social:** "I built a system that works while I sleep" — maker credibility

**This is the coordinator's primary job.** Every other job either enables this one (C, E, G) or validates its output (H, B, D). If the coordinator only solves one job, it must be this one.

---

### Job H — Independent Verification (Opportunity: 16)

> "When an implementation is complete, I want a separate agent that has only read the spec — not the implementation — to independently generate acceptance scenarios, so I have confidence the implementation satisfies the spec's intent, not just the implementing agent's interpretation of it."

**Dimensions:**
- **Functional:** Separate agent generates unseen scenarios from spec alone
- **Emotional:** Genuine confidence in correctness — not self-graded homework
- **Social:** "Independently verified" carries weight when presenting quality claims

**The factory's credibility depends on this.** Without independent verification, the dark factory is just "an agent that says its own code works." The two-tier separation (implementing agent sees acceptance criteria, verification agent generates unseen scenarios from spec only) is the key differentiator.

---

### Job B — Clarification Over Guessing (Opportunity: 15)

> "When a spec is ambiguous, I want the agent to ask me a targeted question in the channel thread — with a spec identifier so I know exactly what's in question — rather than guessing or failing, so I don't waste an entire implementation cycle on wrong assumptions."

**Dimensions:**
- **Functional:** Get targeted questions when specs are ambiguous, with structured identifiers
- **Emotional:** Confidence the agent won't silently waste cycles on wrong assumptions
- **Social:** Collaborative relationship with the agent — dialogue, not one-way commands

**This is the key enabler for Job A.** Without clarification, unattended execution only works for perfectly specified features. Real specs have gaps. The agent needs a way to ask rather than guess.

---

### Job C — Concurrent Throughput (Opportunity: 13)

> "When multiple features are queued, I want them implemented in parallel, so I get more throughput from my Max subscription and the factory queue drains faster."

**Dimensions:**
- **Functional:** Multiple features implementing simultaneously in isolated worktrees
- **Emotional:** Momentum — queue draining feels productive
- **Social:** Demonstrating the factory's capacity to handle real workloads

---

### Job E — Crash Resilience (Opportunity: 13)

> "When the coordinator session dies or my machine restarts, I want in-progress work to be recoverable rather than lost, so partially-completed implementations aren't wasted."

**Dimensions:**
- **Functional:** Recovery of in-progress work after coordinator crash
- **Emotional:** Safety — not afraid to run long jobs knowing the system can recover
- **Social:** Trust in the system's reliability

---

### Job G — Protocol Abstraction (Opportunity: 10)

> "When I want to run the factory, I want the coordinator to handle the MCP protocol sequence — claim, heartbeat, submit — so I don't have to remember and execute the ceremony myself."

**Dimensions:**
- **Functional:** Coordinator handles claim/heartbeat/submit sequence transparently
- **Emotional:** No cognitive load remembering the protocol
- **Social:** Lower barrier for others to use the factory in the future

---

### Job F — Spec Refinement Through Use (Opportunity: 9)

> "When a factory run surfaces ambiguities in my spec through clarification questions, I want those Q&A pairs to be folded back into the spec, so future runs against the same spec don't hit the same questions."

**Dimensions:**
- **Functional:** Auto-proposed spec amendments from clarification Q&A after run completion
- **Emotional:** Satisfaction that specs improve over time without dedicated editing effort
- **Social:** Specs become living documents that improve collaboratively through use

---

### Job D — Ambient Awareness (Opportunity: 8)

> "When factory work is in progress, I want structured progress updates in my channel threads — step counts, current activity, clarification requests — so I have confidence work is moving and can intervene early if something looks wrong."

**Dimensions:**
- **Functional:** Structured progress updates in channel threads via heartbeat messages
- **Emotional:** Calm confidence vs. "is it even working?" anxiety
- **Social:** Visibility to others who might be watching the channel

**Partially served by Phase 1.** Heartbeat messages already exist. The coordinator adds structure (step counts, clarification alerts) and manages them automatically.
