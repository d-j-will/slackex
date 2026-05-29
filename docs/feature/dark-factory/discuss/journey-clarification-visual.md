# Journey: Clarification Threading

**Date:** 2026-04-09
**Jobs served:** B (Clarification Over Guessing), F (Spec Refinement Through Use)
**Primary persona:** David (human operator)
**Secondary persona:** Implementing agent (worktree-isolated), Coordinator agent (relay)

---

## Journey Map

```
Agent discovers ambiguity
       |
       v
+------------------+     +------------------+     +------------------+     +------------------+
| Agent assesses   |     | Coordinator      |     | Human reads      |     | Agent resumes    |
| confidence:      |---->| relays to thread |---->| thread, replies  |---->| with answer,     |
| ask or assume?   |     | with [CLARIFY:]  |     | with answer      |     | continues impl   |
+------------------+     +------------------+     +------------------+     +------------------+
       |                                                                          |
       v (low-stakes)                                                             v
  [Assume + document                                                   [Spec amendment
   in PR description]                                                   proposed after
                                                                        run completes]
```

---

## Step-by-Step

### Step 1: Ambiguity Detected
**Actor:** Implementing agent
**Action:** While reading spec or implementing, encounters ambiguity. Examples:
- Missing acceptance criteria for edge case
- "Support large files" without size limit
- Conflicting constraints between spec sections
- Dependency on unbuilt feature
**Emotion:** Agent is uncertain. (Human is unaware — they're doing other work.)

### Step 2: Confidence Assessment
**Actor:** Implementing agent
**Action:** Evaluates: "If I guess wrong, does this change more than one test case?"
- **High confidence / low stakes:** Make a judgment call, document the assumption in the PR description. Continue implementing. No clarification needed.
- **Low confidence / high stakes:** The wrong guess would change the architecture, data model, or multiple test cases. Must ask.
**Output:** Decision to ask or assume.
**Design principle:** The confidence threshold prevents the human from becoming a bottleneck on trivial questions. Only questions that materially affect correctness get escalated.

### Step 3: Clarification Request
**Actor:** Agent -> Coordinator -> Thread
**Action:** Agent sends clarification to coordinator via `SendMessage`:
```
{clarify, run_id, "acceptance-criteria:3", "The spec says 'messages are delivered
in order' but doesn't define ordering for concurrent senders. Per-channel (Snowflake)
or per-sender?"}
```
Coordinator posts to run's channel thread via `reply_to_thread`:
```
[CLARIFY:run-42:spec:acceptance-criteria:3]
The spec says "messages are delivered in order" but doesn't define ordering
for concurrent senders. Should ordering be per-channel (Snowflake ID) or
per-sender?
```
**Output:** Thread message with structured identifier. Agent marked as `clarifying` (coordinator-local state).
**Emotion:** Human sees notification. Brief concern ("the spec has a gap") but also reassurance ("the agent asked instead of guessing").
**Shared artifacts:** `${clarification_id}` = `acceptance-criteria:3`

### Step 4: Waiting
**Actor:** Coordinator (active), Agent (paused), Human (async)
**Action:**
- Coordinator continues heartbeating for this run (claim stays alive).
- Agent's worktree is untouched (partial work preserved).
- Other agents continue on their own runs.
- Coordinator can claim and start new work (up to concurrency limit — but see open question about whether clarifying agents count toward the limit).
**Output:** No forward progress on this run. Other runs unaffected.
**Failure mode:** No response within 2 hours -> timeout (see Step 4b).

### Step 4b: Clarification Timeout
**Actor:** Coordinator
**Trigger:** No response detected after configurable timeout (default: 2 hours).
**Action:** Coordinator posts timeout notice to thread:
```
[CLARIFY:run-42:spec:acceptance-criteria:3] Timed out after 2 hours.
Agent will make a reasonable assumption and document it in the PR.
```
Agent is instructed to either:
- Make a reasonable assumption and document it prominently
- Submit failure with "blocked on clarification" if the ambiguity is too fundamental
**Emotion:** Human may feel guilty ("I should have answered") or relieved ("it handled it").

### Step 5: Human Responds
**Actor:** Human
**Action:** Reads the clarification in the channel thread. Replies with an answer. Should reference the clarification ID for reliable matching:
```
@bot Per-channel ordering via Snowflake ID. Don't track per-sender order.
```
**Output:** Reply message in thread.
**Emotion:** Collaborative. "The agent asked a good question. I gave a clear answer."
**Open design question:** How does the coordinator match replies to questions? Current options:
1. Require `[RE:CLARIFY:run-42:acceptance-criteria:3]` prefix (reliable, requires user discipline)
2. Position-based (fragile if unrelated messages interleave)
3. Coordinator posts confirmation: "Interpreting your reply as response to [CLARIFY:...]. Correct?" (reliable, adds latency)

### Step 6: Response Forwarded
**Actor:** Coordinator
**Action:** Detects reply in thread (via polling `search_messages` or a future `get_thread_replies_after` tool). Forwards answer to the waiting agent via `SendMessage`.
**Output:** Agent receives answer. Coordinator marks agent as `implementing` (from `clarifying`).
**Emotion:** (Agent resumes. Human sees: "Clarification received, resuming.")

### Step 7: Agent Resumes
**Actor:** Implementing agent
**Action:** Incorporates the answer into implementation. Continues from where it paused.
**Output:** Implementation proceeds with correct understanding.
**Emotion:** Human sees "Resuming — implementing streaming CSV parser" in thread. Confidence restored.

### Step 8: Spec Refinement (Post-Run, Job F)
**Actor:** Coordinator (after run completes)
**Action:** Collects all `[CLARIFY:...]` Q&A pairs from the run's thread. Proposes spec amendments:
```
[SPEC-AMENDMENT:run-42]
Based on clarification Q&A during this run, proposed spec changes:

1. Section: acceptance-criteria, item 3
   Original: "Messages are delivered in order"
   Proposed: "Messages are delivered in per-channel order (Snowflake ID).
   Per-sender ordering is not guaranteed for concurrent senders."
   Source: [CLARIFY:run-42:spec:acceptance-criteria:3]

Approve these amendments? Reply "approve all" or specify which to accept.
```
**Output:** Proposed amendments in thread for human review.
**Emotion:** Satisfaction — "the spec gets better each time without me having to remember what was ambiguous."

---

## Multiple Clarifications

An agent may ask multiple questions during a single run. The coordinator tracks them independently:

```
run-42:
  clarifications:
    - id: "acceptance-criteria:3"
      status: answered
      answer: "per-channel ordering"
      asked_at: 2026-04-09T10:00:00Z
      answered_at: 2026-04-09T10:15:00Z
    - id: "data-model:users:soft-delete"
      status: pending
      asked_at: 2026-04-09T10:20:00Z
```

The agent can continue working on unrelated parts of the implementation while one clarification is pending, as long as the ambiguous section isn't blocking overall progress.

---

## Emotional Arc

```
Ambiguity    Ask         Wait        Answer      Resume      Spec Updated
    |          |           |           |           |              |
    v          v           v           v           v              v
Uncertainty -> Trust  -> Patience -> Clarity -> Confidence -> Satisfaction
 "The spec     "Good,    "I'll      "Clear     "Back on     "Spec is
  has a gap"   it asked   answer     answer"    track"       better now"
               not                                            (Job F)
               guessed"
```

The critical emotional transition is Step 3: from "the spec has a gap" to "the agent handled it correctly by asking." This builds trust in the coordinator's judgment over time.
