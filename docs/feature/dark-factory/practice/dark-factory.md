# Dark Factory — Pre-Implementation Design Notes

> **Status: pre-implementation. Not memoir. Not for publication.**
>
> Dark Factory is not yet running. This document captures the design thinking — decisions made, reasoning behind them, failure modes expected — so it can be compared against reality once the system is built. It is a form of pre-registration: predictions made in advance are falsifiable in a way that retrofitted narratives are not. The eventual essay will be written after the system has been running long enough to have real incidents, real adjustments, and real data. At that point this file gets replaced entirely, from experience.
>
> Nothing in this document is a claim of what happened. Everything is a claim of what I expect to happen.

## The problem I want to solve

Every agent tool I've tried — Cursor, Windsurf, Copilot, Claude Code on its default settings, nwave — assumes a developer is sitting there watching. They pause, ask *should I proceed?*, wait for input, and resume. That's a reasonable default for pair-programming with an agent. It is the wrong default for the work I actually want done, which is feature delivery that happens while I'm asleep, in meetings, or context-switched away.

When I have pushed existing tools toward unsupervised operation, three problems consistently land:

1. **I can't glance at what the agent is doing.** Logs exist, but I have to go find them. The information is *somewhere*, not *anywhere*.
2. **The agent has no good way to ask me a question.** Interactive prompts are useless if nobody is at the terminal. A dashboard is a place I'd have to remember to visit.
3. **When something goes wrong, I can't reconstruct *why*.** Logs tell me what happened, not how the agent got there. I want the audit trail to look like a conversation, because that's what it actually is.

All three share a shape: the agent exists outside the substrate where I already live. My team communication, my async awareness, my audit-by-scrolling habit — all of that happens in chat. The agent happens somewhere else. Dark Factory is the practice I want to build where that gap is closed.

## What Dark Factory will be, if the design holds

A practice in which AI agents execute feature work end-to-end in unattended, lights-out sessions — queued, coordinated, clarified, and audited through the same chat environment the team uses to collaborate with each other. Agents act as first-class participants: they pick up queued work, report progress, and surface clarifications in messages. Humans retain final approval to *ship* (the feature-flag toggle that exposes work to users) but not approval to *work* (the execution of the work itself).

Chat is essential to the practice, not incidental. Hybrid/async/remote teams already collaborate there; agents that work outside chat are tools invoked from elsewhere, not participants in the room. The commitment to chat-as-harness is a load-bearing design decision and everything downstream assumes it.

*Dark* is the manufacturing term for a factory that runs lights-out when nobody is in the building. That is what this is aiming at.

## Design decisions and the predictions behind them

Each of the following is a decision I am making with a reason — not a lesson I've learned. Each one names the decision, the reasoning, the failure mode I expect to have to handle, and what observation would falsify the decision once the system is running.

### 1. Lights-out by default — no per-commit approval gate

**Decision.** Agents commit and merge without asking, provided tests pass and the change lands behind a feature flag.

**Reasoning.** Per-commit approval makes me the latency. The safety I care about comes from automated checks I already trust (test suite, feature flags, expand/contract migrations), not from human confirmation of individual actions. Adding a human gate at the commit level exchanges real throughput for theatrical safety.

**Expected failure mode.** The agent will occasionally ship passing-but-subtly-wrong work that I'd have caught if I were watching. The feature flag gives a cheap revert, but the window between "landed" and "noticed" matters — if it's too long, the downstream harm compounds.

**What would falsify this.** If, over a meaningful period, the rate of silently-wrong merges is high enough that revert cost outweighs throughput gain, this decision is wrong and per-change review has to return in some form. I don't yet know what "meaningful period" or "high enough" should be; I'll need to calibrate against actual incidents.

### 2. Clarification via chat message, not interactive prompt

**Decision.** When an agent can't proceed, it posts a message mentioning a human in the work thread — not an `ask_user` tool call, not stdin blocking, not a dashboard prompt.

**Reasoning.** Clarification is collaboration. Collaboration happens in chat. Out-of-band channels concentrate the question on whoever they point at; chat broadcasts the question to anyone with context. The second effect is load-bearing: on a team, anyone who knows the answer can respond. As a solo dev, I get the weaker version of this benefit — but even alone, the question is visible to me on any device that has chat, not tied to a terminal I happened to leave open.

**Expected failure mode.** Questions will sit unanswered if I'm not watching the channel. The agent stalls visibly but ignored.

**What would falsify this.** If clarifications routinely take longer to answer than interactive-prompt equivalents would have, or if I find myself checking chat more anxiously than I'd have watched a terminal, the decision is wrong.

### 3. Audit via message history, not log files

**Decision.** The agent's meaningful decisions and justifications are posted as messages in the work thread. Routine operational detail stays in logs. The line between the two is whether a human would care if they noticed it later.

**Reasoning.** Chat is where I already read for ambient awareness. If agent reasoning is only in logs, I'll never see it until something breaks. If it's in messages, I'll glance at it passively the way I glance at teammate messages. The audit trail becomes part of normal reading, not a thing I have to remember to check.

**Expected failure mode.** Signal-to-noise. Either the agent posts too much (channel becomes unreadable) or too little (audit doesn't capture what I need for post-hoc reconstruction).

**What would falsify this.** If I find myself *preferring* to grep logs when investigating an incident, rather than scrolling chat, the decision is wrong.

### 4. Queue-driven intake, not ad-hoc invocation

**Decision.** Agents pick work from a queue (a channel with structured work items). Nothing runs by manual invocation.

**Reasoning.** Ad-hoc invocation makes me the dispatcher — I decide what runs next, in what order, when. That turns me into the bottleneck on throughput even when the agents themselves are idle. A queue lets the system work continuously, in priority order, without me being present to start the next thing.

**Expected failure mode.** Queue discipline will erode when there's something urgent. I will be tempted to "just quickly" tell the agent to do something, bypassing the queue — and the moment I do, the queue stops being a reliable picture of what's happening.

**What would falsify this.** If I find myself routinely bypassing the queue for urgent things, either the queue UX needs fixing or the principle is wrong.

### 5. Agents have identities, not just credentials

**Decision.** Each agent has a name, an avatar, and a persistent identity in the chat. Feedback is addressed to the agent by name and persists across sessions via system-prompt updates or a memory mechanism.

**Reasoning.** Treating agents as scripts makes corrective feedback feel like config-file editing — impersonal, forgettable, lossy. Treating them as participants lets me use the feedback habits I already have for human teammates. This is not for the agent's benefit; it's for mine, because my feedback loops are calibrated for talking to people.

**Expected failure mode.** The social posture is theatre if the underlying agent runtime doesn't actually persist feedback across sessions. The mechanism has to work before the identity means anything.

**What would falsify this.** If corrections given to a named agent don't change its behaviour in the next session, the memory mechanism isn't working and the identity model is cosplay.

### 6. Humans gate shipping, not execution

**Decision.** Agents work autonomously all the way through to feature-flagged merge. A human gate exists between "work complete" and "flag turned on for users" — and only there.

**Reasoning.** The shipping decision carries consequences only humans can own: product judgment, customer impact, timing against external commitments, sometimes legal or compliance exposure. Execution decisions (implementation, testing, refactor, docs) don't. Separating the two puts human judgment exactly where it's load-bearing and removes it where it isn't. For me, solo, the gate is always me. For a team, it should be the PO or feature owner — most orgs will still want a PO to agree to shipping, and they should.

**Expected failure mode.** The shipping-gate discipline breaks down either at my end (I flip flags without thinking) or at the agent's end (it gets clever about interpreting "work complete" in ways that blur the gate).

**What would falsify this.** If I end up re-reviewing merged work as if it were unshipped work, the gate isn't doing its job and something upstream needs to change.

## Precondition: the Tenun substrate

Tenun is the chat environment Dark Factory will be built against. Tenun itself exists and runs in production; Dark Factory does not yet. The parts of Tenun that matter for Dark Factory specifically:

- Bot users are first-class accounts (`is_bot` flag, BOT badge in UI, full message history)
- MCP server exposes channel history as a queryable resource for the agent
- Incoming webhooks allow external triggers (scheduled jobs, GitHub actions, manual posts)
- Pgvector + FTS hybrid search lets agents search the conversation the way I do
- Encrypted at rest with a plaintext companion column for FTS — the audit trail is private but queryable

None of this infrastructure was built specifically for Dark Factory, but all of it is load-bearing for the harness contract above. If Dark Factory turns out to need affordances Tenun doesn't have, those become Tenun work items first.

## Open questions the design can't answer

Things that only running the system will resolve:

- Whether chat is *essential* to the practice, or whether some other persistent shared substrate (wiki, project board, issue tracker) could host the same affordances. My current guess: the async-glanceable-broadcast properties are essential and chat happens to provide them natively, but I wouldn't stake the essay on chat being the only viable harness until I've seen otherwise.
- Whether the six decisions above are six decisions or three decisions repeated twice. I keep collapsing and re-expanding them while writing and I don't know the resting point.
- Whether *Dark Factory* is a useful name or a marketing-flavoured one that turns off the developers who'd most benefit. I like the name; I notice I'm primed to defend it.
- How the practice changes as underlying agent capability improves. Most of these decisions assume agents that need clarification, make recoverable mistakes, and benefit from feedback. Stronger agents might collapse some decisions entirely.
- How the practice behaves in a multi-human team vs solo operation. I will be building this alone; I can't test the team dynamics from a solo baseline.
- How any of this survives contact with organisational culture — the question of *how orgs actually work*. That's a separate investigation and it's bigger than this document.

## Publication criteria

This file stops being pre-implementation design notes and becomes a real essay when:

1. Dark Factory is running against Tenun continuously for a meaningful stretch of wall-clock time (I don't yet know how long "meaningful" is — I'll calibrate as I go)
2. The system has handled real feature deliveries end-to-end, including at least a handful of failures and recoveries
3. I have specific incidents I can point at for each of the six decisions — either confirming the prediction or contradicting it
4. Every "I expect" and "I predict" in this file can be replaced with a "what happened was" grounded in a named incident

Until all four conditions are met, this file stays private, stays marked as pre-implementation, and does not get shared for peer review as anything other than a design sketch.
