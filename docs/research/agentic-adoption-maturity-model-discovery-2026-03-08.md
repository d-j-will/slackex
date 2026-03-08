# Agentic Adoption Maturity Model: Feature Discovery

**Research Date:** 2026-03-08
**Method:** First-principles analysis of human adoption patterns
**Status:** Discovery / Idea capture
**Related:** `docs/research/dark-factory-spec-driven-development-discovery-2026-03-08.md`

---

## 1. The Real Problem

The dark factory is a technical vision. But the actual challenge is:

**How do you move a team of humans — with different skill levels, different comfort zones, and different levels of trust in AI — from "I write all my code by hand" to "I write specs and verify outcomes"?**

This is a change management problem disguised as a technology problem. It requires understanding:
- Why people resist (it's usually rational, not irrational)
- What trust actually means in this context
- How different skill levels experience the transition differently
- Why "just try it" doesn't work

---

## 2. The Maturity Levels (0-5)

### Level 0: Manual
**"I write all the code."**

- Developer writes every line by hand
- Tests are written after implementation (if at all)
- Specs are informal or nonexistent
- Debugging is print statements and intuition
- This is where most developers have spent their entire career

**What this feels like:** Full control. The code is mine. I understand every line because I wrote every line.

### Level 1: AI-Assisted
**"I write the code, AI helps me go faster."**

- Copilot-style autocomplete
- AI generates boilerplate, developer reviews and edits
- Developer is still the author — AI is a typing accelerator
- No change to mental model: developer is still in control of every decision

**What this feels like:** Faster. Like a really good autocomplete. I'm still driving.

**Key transition from 0→1:** Low friction. The developer never gives up control. The AI is just a tool, like a better IDE.

### Level 2: AI-Partnered
**"AI writes chunks of code, I review and integrate."**

- Developer describes intent, AI generates implementation
- Developer reviews, tests, and modifies the output
- AI handles routine work; developer handles architecture and edge cases
- Developer still reads all the code — they just didn't type it

**What this feels like:** I'm a reviewer more than a writer. I need to understand what good code looks like to judge the AI's output.

**Key transition from 1→2:** Developer must trust AI output enough to not rewrite it from scratch. This is where resistance starts — "I could write it better" is a common (and sometimes correct) response.

### Level 3: Spec-Guided
**"I write detailed specs with acceptance criteria. AI implements. I verify."**

- Developer writes specs (Given/When/Then, acceptance criteria, constraints)
- AI implements from the spec autonomously
- Developer runs tests, reviews diffs, verifies behaviour
- Developer still looks at code, but primarily to verify, not to author

**What this feels like:** I'm a product owner and a code reviewer, not an author. My value is in knowing what to build and recognising when it's right.

**Key transition from 2→3:** The hardest jump. Developer must accept that:
  - Writing a good spec IS the hard work
  - They don't need to read every line to trust the output
  - Verification (tests, acceptance criteria) is more reliable than manual code review
  - Their expertise shifts from "how to implement" to "what to implement and how to verify"

### Level 4: Verified Autonomous
**"I write specs. The factory implements and verifies. I review failures only."**

- Developer writes specs with known acceptance criteria
- Dark factory implements, runs internal consensus loops, self-verifies against Tier 1 criteria
- Independent verification (Tier 2 unseen scenarios) runs automatically
- Developer only engages when something fails verification
- Observability provides confidence without reading code

**What this feels like:** I'm an architect and a quality gate. Most of the time, the factory just works. When it doesn't, I have the data to understand why.

**Key transition from 3→4:** Developer must trust the verification layer. "How do I know it works if I didn't look at the code?" → "The tests prove it works, including tests the implementation agent never saw."

### Level 5: Dark Factory
**"I define outcomes. The system delivers."**

- Developer defines outcomes and constraints at a high level
- AI agents refine into detailed specs (via MCP, conversation, etc.)
- Dark factory implements with full consensus and verification
- Observability monitors production behaviour
- Developer intervenes only for novel architectural decisions and failure escalations
- The loop from idea → production is largely autonomous

**What this feels like:** I'm a product thinker and a systems architect. My job is to define what matters and ensure the system is trustworthy. I spend more time on "why" and "what" than "how."

**Key transition from 4→5:** Letting go of spec writing as a purely human activity. Trusting that AI can refine a conversation into a spec, and that the verification layer catches gaps.

---

## 3. Why People Resist (And Why It's Rational)

### Identity Threat

For many developers, **writing code is their identity**. "I'm a developer" means "I write code." Moving to spec-writing and verification feels like being told your core skill is obsolete. This isn't irrational — it's a real identity shift.

**How to address:** Reframe the identity, don't dismiss it.
- "You're not losing a skill — you're gaining leverage. A developer who can write specs that produce correct code from an agent is 10x more valuable than a developer who can only write code by hand."
- "Understanding code well enough to verify it requires deeper skill than writing it from scratch."
- "The best architects already think in specs and constraints, not in lines of code."

### Loss of Control

"If I didn't write it, I can't trust it." This is a reasonable heuristic — until the verification layer is strong enough to replace manual inspection.

**How to address:** Build trust incrementally.
- Level 1-2: They still see and control everything
- Level 3: They verify with tests they wrote
- Level 4: They verify with tests they didn't write, but can inspect
- Level 5: They verify via observability and outcomes

Each level adds a small amount of trust. Nobody jumps from 0 to 5.

### Skill Anxiety

Less experienced developers worry: "If I don't practice writing code, how will I learn?" More experienced developers worry: "My 20 years of coding expertise is suddenly less valuable."

**How to address differently by experience level** (see Section 4).

### Quality Concerns

"AI code is mediocre." This was true 2 years ago. It's less true now. It'll be less true next year. But the concern is legitimate — trusting AI output requires evidence, not faith.

**How to address:** Prove it.
- Run the factory on a real feature. Compare the output to human-written code. Measure: test pass rate, defect rate, time to delivery.
- The unseen scenarios (Tier 2) exist specifically to catch "mediocre" implementations that pass their own tests but miss edge cases.
- Show, don't tell. Demonstrations beat arguments.

---

## 4. Meeting People Where They Are

### 4.1 The Resistant Senior ("I've been doing this for 20 years")

**What they fear:** Obsolescence. Their hard-won intuition about code quality, architecture, and edge cases feels undervalued.

**What they're actually great at:** Exactly the skills the dark factory needs — defining constraints, spotting architectural issues, knowing what can go wrong, writing adversarial scenarios.

**Engagement strategy:**
- Position them as the **adversarial subagent in human form**. "Your job isn't to write the code — it's to break the factory's output. Your 20 years of experience is what makes you the best person to write the constraints and unseen scenarios."
- Have them write the Tier 2 verification scenarios. This directly leverages their experience.
- Have them review the factory's internal consensus process. "Does the adversarial loop catch what you would have caught?"
- Start them at Level 2 — AI-partnered. Let them see AI generate code and critique it. They'll naturally move to "I could guide this better with a spec" (Level 3).

### 4.2 The Less Experienced Developer ("I'm still learning")

**What they fear:** Never developing deep skills. "If the AI writes the code, how do I learn?"

**What they're actually great at:** Fresh perspective, willingness to try new tools, less attachment to "the old way."

**Engagement strategy:**
- Level 1-2 is actually a learning accelerator. "Read the AI's code. Understand why it made those choices. Try to improve it. You're learning from a tutor that never gets tired."
- At Level 3, spec-writing teaches them to think about requirements, edge cases, and acceptance criteria — skills that are harder to develop than coding syntax.
- Pair them with a senior for spec review. The senior's experience + the junior's openness = fast adoption.
- Use the dark factory output as teaching material. "Here's what the factory produced. What would you change? Why?"

### 4.3 The Pragmatist ("Show me the numbers")

**What they need:** Evidence, not philosophy.

**Engagement strategy:**
- Run a controlled experiment: same feature, one human-implemented, one factory-implemented. Compare time, defect rate, test coverage.
- Show observability data: "The factory-built feature has zero errors in production after 1 week."
- Track their own time: "You spent 3 days on this feature. The factory did it in 2 hours and you spent 30 minutes verifying."

### 4.4 The Anxious ("What if it goes wrong?")

**What they fear:** Production incidents caused by AI code they don't understand.

**Engagement strategy:**
- The unseen scenarios exist specifically for this concern. "There are tests the AI never saw. If they pass, the code is correct."
- Observability means they can see problems immediately, not after a user reports them.
- Start them at Level 1. Let them see AI be helpful without being threatening. Build trust slowly.
- Human gates in the pipeline. "Nothing deploys without your approval. You can always say no."

---

## 5. The Engagement Progression

### Phase 1: Normalise AI Assistance (0→1)

**Goal:** Everyone uses AI daily without thinking about it.

- Copilot/autocomplete for everyone
- No pressure to change workflow
- Share wins casually: "AI helped me write this migration in 2 minutes"
- Remove friction: pre-configure tools, provide API keys

**Duration:** 2-4 weeks. Low resistance because low stakes.

### Phase 2: AI as Pair Partner (1→2)

**Goal:** Developers are comfortable asking AI to generate chunks of code.

- Introduce Claude Code / similar tools for larger generation
- Encourage "AI-first drafts" — let AI write the first pass, developer refines
- Code review of AI output becomes a team practice
- Celebrate quality catches: "Good eye — the AI missed this edge case"

**Duration:** 4-8 weeks. Some resistance from seniors. Address with identity reframing.

### Phase 3: Spec-Writing as a Skill (2→3)

**Goal:** The team writes specs that are good enough for autonomous implementation.

- Introduce spec templates (Given/When/Then, acceptance criteria)
- Run workshops: "Write a spec for this feature. Let AI implement it. See what happens."
- Iterate: bad specs produce bad code. Good specs produce good code. The team learns what "good spec" means.
- The senior developers shine here — their experience makes their specs better.
- Track: spec quality → implementation quality correlation

**Duration:** 2-3 months. This is the hardest transition. Requires patience and visible wins.

### Phase 4: Trust the Verification (3→4)

**Goal:** Developers trust Tier 2 unseen scenarios as a verification layer.

- Introduce property-based testing and AI-generated edge cases
- Show that unseen scenarios catch bugs the developer's own tests missed
- Gradually reduce manual code review for factory-produced features (keep it for human-written code)
- Observability dashboards become the primary confidence signal

**Duration:** 2-3 months. Trust builds through repeated positive experience.

### Phase 5: Full Dark Factory (4→5)

**Goal:** Idea → spec → implementation → verification → production with minimal human interaction.

- AI agents participate in spec refinement (via MCP)
- Internal consensus loops handle quality without human review
- Humans focus on outcomes, architecture, and escalation
- The team measures success by outcomes delivered, not code written

**Duration:** Ongoing. This is a destination, not a one-time transition.

---

## 6. First Principles for Engagement

### 6.1 Trust is Built, Not Declared

You can't tell someone to trust AI. Trust comes from:
- **Repeated positive experience** — AI did the right thing 50 times in a row
- **Transparent failure** — When AI fails, it's visible and explainable (observability)
- **Safety nets** — Human gates, Tier 2 verification, rollback capability
- **Agency** — The developer can always say "no, I'll do this by hand"

### 6.2 Meet People at Their Level

A senior with 20 years of C++ is in a different place than a junior who learned to code with Copilot. The maturity levels aren't just for the organisation — they're for individuals. Some people will be at Level 4 while others are at Level 1. That's fine.

**Never force someone to skip levels.** Each level builds trust that enables the next.

### 6.3 Reframe, Don't Dismiss

"You won't need to code anymore" is threatening. "Your expertise becomes more leveraged" is empowering. Same outcome, completely different emotional response.

The skills that matter at Level 5:
- Defining clear outcomes and constraints
- Understanding system architecture and failure modes
- Writing effective acceptance criteria
- Recognising quality (even if you didn't produce it)
- Knowing when to trust automation and when to intervene

These are senior skills. The dark factory doesn't make experience obsolete — it makes experience the bottleneck. That's empowering for experienced developers, if framed correctly.

### 6.4 Make the Old Way Harder, Not Forbidden

Don't ban manual coding. Instead, make the spec-driven path easier and more rewarding:
- Spec-driven features get priority in the sprint
- Factory-delivered features have better test coverage (Tier 2)
- Factory-delivered features have better observability
- Manual coding is always an option — but it takes longer and has less verification

People naturally gravitate toward the path of least resistance. Make the right thing the easy thing.

### 6.5 Celebrate Spec Quality, Not Code Volume

Change what the team values:
- "Great spec — the factory nailed this on the first pass" (spec was so clear the AI got it right)
- "Excellent Tier 2 scenarios — you caught three edge cases the factory missed" (verification skill)
- "Clean acceptance criteria — no ambiguity" (communication skill)

Stop measuring lines of code. Start measuring outcomes delivered and verification pass rates.

---

## 7. Metrics for Tracking Adoption

| Metric | What It Measures |
|--------|-----------------|
| % of features with formal specs | Spec-writing adoption |
| % of features with Tier 1 acceptance criteria | Quality of specs |
| % of features factory-implemented | Factory adoption |
| Tier 2 first-pass rate | Factory quality (should trend up) |
| Time from spec to verified implementation | Factory efficiency |
| Human intervention rate | How often someone overrides the factory |
| Developer satisfaction survey | Are people happier or stressed? |
| Defect rate (factory vs manual) | Quality comparison |
| Time to diagnose production issues | Observability effectiveness |

---

## 8. Anti-Patterns to Avoid

### "Just trust it"
Telling people to trust AI without evidence. Trust is earned through experience, not mandated.

### Skipping levels
Jumping from Level 0 to Level 4 because "we need to move fast." This creates fear and resistance that takes months to undo.

### Penalising manual coding
Making people feel bad for wanting to write code by hand. The goal is to make the spec-driven path attractive, not to forbid alternatives.

### One-size-fits-all rollout
Expecting everyone to adopt at the same pace. Let the enthusiasts pioneer, the pragmatists follow the evidence, and the sceptics take their time.

### Ignoring legitimate concerns
"AI code is sometimes wrong" is a fact, not resistance. Address it with verification, don't dismiss it.

### Measuring adoption instead of outcomes
"80% of our features use the dark factory" is meaningless if the quality is poor. Measure outcomes: defect rate, delivery speed, developer satisfaction.

---

## 9. Open Questions

1. **Team size and dynamics** — How many co-workers? What's the current skill distribution? Who are the likely early adopters?
2. **Current spec practices** — How formal are specs today? BDD already in use, or new concept?
3. **Org culture** — Top-down mandate or bottom-up adoption? What's the appetite for change?
4. **Tooling budget** — API keys for everyone? Shared AI accounts? What can the org fund?
5. **Timeline expectations** — Is this a 6-month transition or a 2-year journey? Rushing creates resistance.
6. **Success criteria** — What would "this is working" look like for the team? For management?
7. **Support structure** — Who champions the adoption? Is there dedicated time for learning, or is it "figure it out alongside your normal work"?
8. **Failure tolerance** — When the factory produces a bug, how does the org respond? Learning opportunity or blame game?
