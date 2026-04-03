# Dark Factory Lifecycle Proposal

**Date:** 2026-04-03
**Status:** Proposal
**Purpose:** Define the intended lifecycle for dark-factory-delivered work, including the distinction between implementation complete, deployed dark, business-approved release, and flag cleanup.

**Related:**
- `docs/research/dark-factory-spec-driven-development-discovery-2026-03-08.md`
- `docs/research/vision-roadmap-2026-03-08.md`
- `docs/research/dark-factory-feature-flag-governance-2026-04-03.md`

---

## 1. Why This Lifecycle Exists

The dark factory should not end at "agent says the code is done." It should drive work to a safer and more business-relevant boundary:

- the feature is implemented
- the feature is verified
- the code is deployed to production behind a feature flag
- the person with real accountability decides whether it should be exposed
- the feature flag is later removed once the change is stable

This separates three different decisions that should not be collapsed together:

- **technical correctness**
- **production deployability**
- **business release authority**

---

## 2. Core Lifecycle Distinctions

### Implemented

The agent has produced code and passed the known implementation checks.

### Verified

The work has passed independent verification, including scenarios or checks beyond the implementation loop.

### Deployed Dark

The code is in production infrastructure, but hidden behind a feature flag.

### Released

A product owner or similarly accountable person has green-lit exposure of the feature to its intended audience.

### Cleaned Up

The temporary feature flag has been removed after the release is considered stable.

---

## 3. Proposed Lifecycle States

This proposal extends the current dark factory lifecycle beyond `completed`.

### Existing conceptual states

- `queued`
- `implementing`
- `awaiting_verification`
- `verifying_tier2`
- `needs_review`
- `cancelled`

### Proposed end-state lifecycle

- `queued`
- `implementing`
- `awaiting_verification`
- `verifying_tier2`
- `awaiting_deploy`
- `deploying_dark`
- `deployed_dark`
- `awaiting_release_decision`
- `released`
- `awaiting_flag_cleanup`
- `completed`
- `needs_review`
- `cancelled`

---

## 4. State Meanings

| State | Meaning | Owner |
|---|---|---|
| `queued` | Spec accepted into the factory queue | Human or MCP client |
| `implementing` | Agent is building the change | Implementer agent |
| `awaiting_verification` | Tier 1 implementation succeeded and is waiting for independent verification | Factory |
| `verifying_tier2` | Independent verification is running | Verification agent |
| `awaiting_deploy` | Verification passed and the change is waiting for dark deploy | Factory or deploy agent |
| `deploying_dark` | Production deployment is in progress with flag default-off | Deploy system |
| `deployed_dark` | Code is live in production but hidden behind a feature flag | System |
| `awaiting_release_decision` | Business sign-off is required to expose the feature | PO or stakeholder |
| `released` | Feature flag has been enabled for its intended audience | PO or system under explicit PO approval |
| `awaiting_flag_cleanup` | Feature is stable, but temporary delivery scaffolding still exists | Factory or cleanup run |
| `completed` | Feature is released and the flag has been removed | System |
| `needs_review` | Factory cannot safely proceed without human intervention | Human |
| `cancelled` | Run intentionally stopped | Human or authorized agent |

---

## 5. Transition Rules

### Implementation and verification

- `queued -> implementing`
- `implementing -> awaiting_verification`
- `implementing -> needs_review`
- `awaiting_verification -> verifying_tier2`
- `verifying_tier2 -> awaiting_deploy`
- `verifying_tier2 -> needs_review`

### Deployment and release

- `awaiting_deploy -> deploying_dark`
- `deploying_dark -> deployed_dark`
- `deploying_dark -> needs_review`
- `deployed_dark -> awaiting_release_decision`
- `awaiting_release_decision -> released`
- `awaiting_release_decision -> cancelled`

### Cleanup

- `released -> awaiting_flag_cleanup`
- `awaiting_flag_cleanup -> completed`
- `awaiting_flag_cleanup -> needs_review`

### Human escape hatches

- any non-terminal state may move to `needs_review`
- most non-terminal states may move to `cancelled` with appropriate authorization

---

## 6. Lifecycle Diagram

```text
queued
  -> implementing
  -> awaiting_verification
  -> verifying_tier2
  -> awaiting_deploy
  -> deploying_dark
  -> deployed_dark
  -> awaiting_release_decision
  -> released
  -> awaiting_flag_cleanup
  -> completed

Failure / uncertainty exits:
  implementing -> needs_review
  verifying_tier2 -> needs_review
  deploying_dark -> needs_review
  awaiting_flag_cleanup -> needs_review

Cancellation exits:
  queued -> cancelled
  awaiting_release_decision -> cancelled
```

---

## 7. Human Authority Boundary

The most important lifecycle rule is this:

**The dark factory may deploy dark, but it may not decide release.**

That means:

- agents may implement
- agents may verify
- agents may prepare and even execute deployment behind a feature flag
- agents may present evidence and recommend release
- agents may not expose the feature without explicit approval from the person with skin in the game

This preserves business accountability while keeping the technical loop highly automated.

---

## 8. What Counts As "Ready For Release Decision"

A run should only reach `awaiting_release_decision` when all of the following are true:

- implementation succeeded
- verification passed
- code is deployed to production
- the feature is hidden behind a flag with the intended default-off behavior
- observability for the feature is available
- rollback or disable path is known and cheap
- the PO has the evidence needed to decide

The release decision should be based on evidence, not trust in the agent alone.

---

## 9. Cleanup Is Part Of The Lifecycle

Feature flags are delivery scaffolding, not permanent architecture.

That means the dark factory should treat cleanup as part of completion:

- once the release is stable, the system should open a cleanup run or transition into a cleanup stage
- completion should mean both "released" and "temporary flag removed"
- stale flags should be considered a failure of lifecycle completion, not a harmless leftover

---

## 10. Implications For The Current Factory Model

The current implementation in `lib/slackex/factory.ex` ends effectively at verification completion. To reach this proposed lifecycle, the factory model will eventually need:

- explicit deployment stages
- explicit release-decision stages
- explicit cleanup stages
- run metadata for feature-flag ownership and release readiness
- a human approval event model, not just agent progress events

This proposal does not require all of that immediately. It defines the intended direction so future phases do not accidentally bake in the wrong terminal state.

---

## 11. Recommended Next Design Step

The next design artifact should define feature-flag governance for factory-delivered work:

- how flags are named
- what metadata every run must carry
- who can approve release
- what evidence must exist before release
- when cleanup is required

That is captured in `docs/research/dark-factory-feature-flag-governance-2026-04-03.md`.
