# Dark Factory: Spec-Driven Agentic Development — Feature Discovery

**Research Date:** 2026-03-08
**Method:** Architecture brainstorm, reference analysis (StrongDM Attractor)
**Status:** Discovery / Idea capture
**Reference:** https://github.com/strongdm/attractor (StrongDM, NLSpec-driven pipeline orchestration)
**Related:**
- `docs/research/mcp-product-discovery-workflow-discovery-2026-03-08.md` (MCP server — the input channel for specs)
- `docs/research/tauri-desktop-mobile-app-discovery-2026-03-08.md` (mobile capture of ideas → specs)

---

## 1. Vision

A "dark factory" for software development: humans define **what** (specs, outcomes, acceptance criteria), agents deliver **how** (implementation), and the system validates against **scenarios the agent hasn't seen**. Minimal human interaction in the coding loop.

```
Human World                          Dark Factory                         Verification
+------------------+                +---------------------+              +-----------------+
| Specs            |                | Agentic Coding Loop |              | Unseen Scenarios|
| - Feature desc   |──────────────→| - Plan              |──────────→  | - Generated     |
| - Outcomes       |                | - Implement         |              |   from spec but |
| - Acceptance     |                | - Test (known)      |              |   NOT shown to  |
|   criteria       |                | - Iterate           |              |   the agent     |
+------------------+                +---------------------+              +-----------------+
                                           ↑                                    |
                                           └────────────────────────────────────┘
                                                    Fail → retry loop
```

The key insight: **acceptance criteria visible to the agent** guide implementation. **Unseen test scenarios** provide independent verification — not to trick the agent, but to confirm the implementation is sound beyond the stated criteria. The same reason a code reviewer who didn't write the code adds value.

This requires specs to be **well-specified with suitable acceptance criteria**. The unseen scenarios are not a substitute for good specs — they're a verification layer that validates the spec was implemented correctly, including edge cases that naturally arise from any well-defined problem.

### Core Principle: Dogfooding

**The dark factory must be used to build Slackex itself.** This is non-negotiable.

If the factory can't be trusted to deliver Slackex features, it can't be trusted for anything. Slackex is the first customer and the proving ground. Every feature delivered through the dark factory simultaneously improves the product and validates the factory.

Why Slackex is an ideal dogfooding target:
- **Existing spec infrastructure** — `docs/feature/*/roadmap.yaml` with BDD criteria, `execution-log.yaml` for tracking, hookify rules as safety gates
- **Strong test culture** — 1132+ tests, integration tests verifying full producer→consumer paths (not just units)
- **Incident history as constraints** — `docs/rca/` documents encode "never do X again" rules that feed directly into spec constraints
- **Real complexity** — Encrypted fields, partitioned tables, multi-node OTP, feature flags, PubSub event bridges — not a toy project
- **Known failure modes** — Past incidents (supervisor cascades, swallowed errors, missing wiring) are exactly the kind of things Tier 2 unseen scenarios should catch

The progression:
1. **First feature:** Pick a well-scoped Slackex feature, write the spec manually, run through the dark factory, compare quality to human-implemented features
2. **Iterate the factory:** Use lessons from the first feature to refine the pipeline, spec format, and scenario generation
3. **Expand:** Gradually increase the scope and autonomy of factory-delivered features
4. **Prove it:** Track metrics — defect rate, iteration count, time-to-delivery, Tier 2 pass rate — against manually-implemented features

If the factory consistently delivers features that pass unseen scenarios on Slackex's real codebase, that's the proof.

### Core Principle: Internal Consensus, External Verification

The dark factory is **consensus-based internally** and **independently verified externally**. These are distinct layers:

**Inside the factory: Adversarial subagent loops**

The factory doesn't just implement and ship. It runs internal adversarial loops where subagents challenge each other's decisions until consensus is reached. The factory will not release work until all internal agents agree the implementation is sound.

```
┌─────────────────────────────────────────────────────┐
│ Dark Factory (internal, consensus-based)             │
│                                                      │
│  ┌─────────────┐    ┌──────────────┐    ┌─────────┐ │
│  │ Implementer │←──→│ Adversarial  │←──→│Consensus│ │
│  │ Agent       │    │ Subagent     │    │ Gate    │ │
│  │             │    │              │    │         │ │
│  │ "Here's my  │    │ "Is this     │    │ "Do we  │ │
│  │  approach"  │    │  actually    │    │  all    │ │
│  │             │    │  right?"     │    │  agree?"│ │
│  └─────────────┘    └──────────────┘    └─────────┘ │
│                                              |       │
│                      Only exits when consensus       │
│                      is reached                      │
└──────────────────────────|───────────────────────────┘
                           ↓
              External Verification (Tier 2)
              Independent confirmation that
              the consensus was correct
```

The adversarial subagent challenges decisions like:
- "You chose `on_conflict: :nothing` — what happens when it conflicts and returns a nil-id struct?"
- "This GenServer has no supervision strategy — what if it crashes? What's the blast radius?"
- "You're joining without partition keys — will this degrade on the partitioned messages table?"
- "This listener subscribes to a PubSub topic — where's the integration test proving the producer actually broadcasts to it?"

These challenges are informed by the project's own constraints, incident history, and architectural rules (CLAUDE.md, hookify rules, RCA docs). The adversarial agent knows the project's failure modes.

**Outside the factory: Independent verification**

Once internal consensus is reached, the unseen scenarios provide an independent check. The relationship here is collaborative, not adversarial — confirming that the factory's consensus produced a correct result.

The adversarial work happens **inside** the factory. The verification layer **outside** is just honest confirmation.

---

## 2. The Attractor Model (Reference)

StrongDM's Attractor provides a reference architecture for this pattern. Key concepts:

### 2.1 NLSpecs (Natural Language Specifications)

Human-readable specs intended to be directly usable by coding agents. The spec IS the source of truth — not code, not tickets, not conversations. The agent reads the spec and implements/validates from it.

### 2.2 Declarative Pipeline as Graph

Attractor defines workflows as directed graphs in DOT syntax:
- **Nodes** = tasks (LLM calls, human gates, parallel branches, tools)
- **Edges** = transitions with conditions and weights
- **Attributes** configure behaviour (retries, timeouts, model selection)

The graph IS the workflow — no imperative control flow.

### 2.3 Key Architecture Concepts

| Concept | Description |
|---------|-------------|
| **Goal gates** | Critical nodes that must succeed before pipeline can exit |
| **Checkpoint/resume** | Serialisable state after each node — crash recovery |
| **Context fidelity** | Controls how much history carries between LLM calls (full session, summary, truncated) |
| **Human-in-the-loop** | Designated nodes pause for human decision, then route based on choice |
| **Edge-based routing** | Conditions on edges determine flow (outcome=success → implement, outcome=fail → fix) |
| **Model stylesheet** | CSS-like rules for LLM model selection per node class |
| **Pluggable handlers** | Node types map to handlers (codergen, human gate, parallel, tool) |
| **Retry policies** | Exponential backoff with configurable limits per node |

### 2.4 Execution Loop

```
Parse DOT → Validate → Initialise → Execute Loop → Finalise

Execute Loop:
  1. Check if terminal node (verify goal gates)
  2. Execute handler (LLM call, human gate, tool, etc.)
  3. Record completion + outcome
  4. Update shared context
  5. Save checkpoint
  6. Select next edge (5-step priority: conditions → labels → suggestions → weight → lexical)
  7. Advance to next node
```

---

## 3. Applying to Slackex Development

### 3.1 The Input Pipeline

How specs get into the dark factory — this connects directly to the MCP discovery doc:

```
Mobile (Slackex chat)          MCP Agent             Spec Repository
+------------------+          +---------+           +----------------+
| "We need bulk    |          | Refines |           | feature/       |
|  CSV import..."  |──MCP───→| into    |──commit──→|  bulk-import/  |
|                  |          | NLSpec  |           |   spec.md      |
+------------------+          +---------+           |   criteria.md  |
                                                    |   scenarios.md |
                                                    +----------------+
```

The conversational capture in Slackex channels (via MCP) feeds into structured NLSpecs in the repo. The dark factory consumes those specs.

### 3.2 The Two-Tier Testing Strategy

This is the critical innovation:

**Tier 1: Known acceptance criteria (visible to agent)**
- Written by humans as part of the spec
- Agent sees these during implementation
- Proves the agent can follow instructions and satisfy stated requirements
- Similar to TDD — the agent writes code to make these pass

**Tier 2: Unseen scenarios (independent verification)**
- Generated from the spec but NOT provided to the implementing agent
- Could be generated by a separate AI, by humans, or by property-based test generators
- Run AFTER the agent claims implementation is complete
- Provides independent verification that the implementation is sound — edge cases, boundary conditions, and interactions that naturally arise from the problem domain
- Not adversarial — the spec must be well-written enough that a correct implementation passes these naturally

```
Spec: "Users can bulk import contacts from CSV"

Tier 1 (agent sees):
  - Given a valid CSV with 3 contacts, when imported, then 3 contacts exist
  - Given a CSV with invalid email, when imported, then row is rejected with error

Tier 2 (agent never sees):
  - Given a 100,000 row CSV, when imported, then completes within 30 seconds
  - Given a CSV with BOM marker, when imported, then parses correctly
  - Given a CSV where all rows duplicate existing contacts, when imported, then zero new contacts and clear summary
  - Given concurrent imports of the same CSV, when both complete, then no duplicate contacts
```

### 3.3 How This Maps to Slackex's Existing Patterns

Slackex already has elements of this:

| Existing Pattern | Dark Factory Evolution |
|-----------------|----------------------|
| Feature specs in `docs/feature/` | Become NLSpecs — structured for agent consumption |
| `roadmap.yaml` with BDD criteria | Tier 1 acceptance criteria |
| `execution-log.yaml` | Pipeline checkpoint/resume |
| Hookify rules (migration safety, etc.) | Validation gates in the pipeline |
| Pre-deploy script (7 checks) | Goal gates that must pass before "exit" |
| RCA docs from incidents | Feed back into spec constraints ("never do X") |

---

## 4. Architecture for Slackex Dark Factory

### 4.1 Pipeline Phases

```
┌─────────┐   ┌──────────┐   ┌───────────┐   ┌──────────┐   ┌───────────┐
│  SPEC   │──→│  PLAN    │──→│ IMPLEMENT │──→│ VERIFY   │──→│  ACCEPT   │
│         │   │          │   │           │   │          │   │           │
│ NLSpec  │   │ Break    │   │ Agent     │   │ Tier 1   │   │ Tier 2    │
│ + known │   │ into     │   │ coding    │   │ known    │   │ unseen    │
│ criteria│   │ tasks    │   │ loop      │   │ tests    │   │ scenarios │
└─────────┘   └──────────┘   └───────────┘   └──────────┘   └───────────┘
     ↑                             ↑               |               |
     |                             └───────────────┘               |
     |                              Fail → retry                   |
     └─────────────────────────────────────────────────────────────┘
                              Fail → refine spec or escalate to human
```

### 4.2 Agent Isolation

The implementing agent and the verifying agent must be separate:

- **Implementing agent** sees: spec, known acceptance criteria, codebase
- **Verification agent** sees: spec, generates unseen scenarios, runs them against implementation
- **Neither** sees the other's work during execution

This prevents the implementer from overfitting to test cases and prevents the verifier from being influenced by implementation choices.

### 4.3 Spec Structure

```
feature/
  bulk-import/
    spec.md              # Natural language feature description
    criteria.md          # Known acceptance criteria (BDD Given/When/Then)
    constraints.md       # Non-functional requirements, safety rules
    scenarios/
      known/             # Visible to implementing agent
        happy-path.md
        error-handling.md
      unseen/            # Generated, never shown to implementer
        edge-cases.md    # Generated by verification agent or humans
        load.md
        concurrency.md
```

### 4.4 Where Agents Run

Following the same principle as the MCP discovery doc — Slackex doesn't run agents:

- **Implementing agent:** User/org's Claude Code, Cursor, Copilot, custom agent
- **Verification agent:** Separate agent instance (could be same provider, different session)
- **Scenario generator:** Could be a third agent, or a property-based test generator, or humans
- **Orchestrator:** Could be Attractor-style DOT pipeline, GitHub Actions, or a custom Elixir orchestrator

---

## 5. The Unseen Scenario Problem

This is the hardest and most interesting part. How do you generate test scenarios that meaningfully validate an implementation without showing them to the implementer?

### 5.1 Approaches

**Human-written unseen scenarios:**
- Humans write additional scenarios that are held back from the agent
- High quality but doesn't scale
- Works for critical features

**AI-generated from spec:**
- A separate AI reads the spec and generates edge cases, boundary conditions, adversarial inputs
- The generating AI never sees the implementation
- Can produce large numbers of scenarios
- Quality varies — needs human review of the scenario set (not the implementation)

**Property-based test generation:**
- Define properties that must hold (e.g., "import is idempotent", "row count matches")
- Generator creates random inputs that test those properties
- StreamData in Elixir is a natural fit
- Truly unseen — even humans don't know the specific inputs

**Mutation testing:**
- Deliberately introduce bugs into the implementation
- Verify that the test suite catches them
- If tests pass with a bug, the test suite is insufficient
- Tools exist for Elixir (though limited)

**Fuzzing:**
- Random/semi-random inputs to find crashes and unexpected behaviour
- Good for robustness, less good for business logic validation

### 5.2 Recommended Blend

For Slackex features:

1. **Known criteria** (Tier 1): Human-written BDD scenarios in `criteria.md`
2. **Property-based** (Tier 2a): StreamData generators for data integrity properties
3. **AI-generated edge cases** (Tier 2b): Separate agent reads spec, generates boundary/adversarial scenarios
4. **Mutation testing** (Tier 2c): Verify test suite actually catches real bugs

---

## 6. Integration with Existing Slackex Workflow

### 6.1 Evolution Path

```
Today (manual + assisted):
  Human writes spec → Human implements with AI assistance → Human writes tests → Human reviews

Near-term (agent-implemented, human-verified):
  Human writes spec → Agent implements → Agent writes Tier 1 tests → Human reviews + writes Tier 2

Dark factory (minimal human):
  Human writes spec → Agent implements → Tier 1 auto-verified → Tier 2 auto-generated and run → Human reviews only failures
```

### 6.2 What Stays Human

Even in a dark factory, humans own:
- **Spec writing** — Defining what to build and why
- **Acceptance criteria** — Defining what "done" means
- **Constraint definition** — Safety rules, performance requirements, architectural boundaries
- **Failure review** — When Tier 2 scenarios fail, humans decide: refine spec, adjust constraints, or accept the deviation
- **Deployment approval** — Human gate before production (at least initially)

### 6.3 What Becomes Automated

- **Planning** — Breaking specs into implementation tasks
- **Implementation** — Writing code, tests, migrations
- **Known-scenario verification** — Running Tier 1 acceptance tests
- **Edge case generation** — AI or property-based Tier 2 scenarios
- **Iteration on failure** — Agent retries with feedback from failed tests
- **Code review basics** — Automated style, security, pattern compliance checks

---

## 7. Elixir/OTP as Dark Factory Runtime

Elixir is actually well-suited for orchestrating a dark factory:

- **GenServer per pipeline** — Each feature pipeline is a supervised process with state
- **DynamicSupervisor** — Spin up/down pipeline processes as specs arrive
- **PubSub** — Real-time status updates to Slackex channels ("Feature X: implementing step 3 of 7...")
- **Oban** — Queue agent tasks, retry on failure, schedule verification runs
- **StreamData** — Property-based test generation for Tier 2 scenarios
- **Checkpoint/resume** — GenServer state can be serialised to Postgres for crash recovery
- **Broadway** — If scaling to many concurrent pipelines, Broadway for backpressure

---

## 8. Connection to Other Discovery Docs

| Discovery Doc | Connection |
|--------------|------------|
| **MCP Product Discovery** | MCP is the input channel — conversations become specs via AI agent refinement |
| **Tauri Desktop/Mobile** | Mobile capture of ideas that feed into the spec pipeline |
| **Huddles** | Voice discussions about features could be transcribed and fed into spec refinement |
| **Pair Programming** | Human + agent pairing for spec review and constraint definition |

The full loop:

```
Idea (mobile/huddle/chat)
  → MCP agent refines into spec
    → Dark factory implements
      → Unseen scenarios verify
        → Human approves deployment
          → Status updates flow back to Slackex channel
```

---

## 9. Open Questions

1. **Orchestrator choice** — Build an Attractor-style DOT pipeline in Elixir? Use Attractor directly? Simpler Oban-based task queue? GitHub Actions?
2. **Spec format** — Markdown NLSpecs (like Attractor)? YAML (like current roadmap.yaml)? Both?
3. **Agent provider** — Does the dark factory use a specific agent (Claude Code), or is it provider-agnostic like the MCP design?
4. **Unseen scenario quality** — How to validate that AI-generated Tier 2 scenarios are meaningful and not trivial?
5. **Feedback loop** — When Tier 2 fails, how does the feedback reach the implementing agent? Full spec context? Just the failing scenario? Both?
6. **Cost** — Running multiple agents (implementer, verifier, scenario generator) per feature multiplies API costs. What's the budget model?
7. **Incremental adoption** — Can this be adopted gradually? E.g., start with just Tier 1 auto-verification, add Tier 2 later?
8. **Slackex self-hosting** — Could Slackex features themselves be developed this way? Dogfooding the dark factory on its own codebase?
9. **Human escalation** — At what point does the factory give up and escalate to a human? After N retries? After Tier 2 failure rate exceeds threshold?
10. **Spec drift** — How to keep specs in sync with the evolving codebase? Specs that reference patterns/modules that no longer exist become misleading.
