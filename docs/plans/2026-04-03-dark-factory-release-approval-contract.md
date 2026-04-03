# Dark Factory Release Approval Contract

This document defines the human approval boundary, minimum metadata, and allowed state transitions for the deploy-dark lifecycle MVP described in `docs/plans/2026-04-03-dark-factory-deploy-dark-lifecycle-plan-v2.md`.

Related docs:

- `docs/plans/2026-04-03-dark-factory-deploy-dark-lifecycle-plan-v2.md` - MVP execution plan that consumes this contract
- `docs/plans/2026-04-03-dark-factory-deploy-dark-lifecycle-plan.md` - broader lifecycle implementation plan
- `docs/research/dark-factory-lifecycle-proposal-2026-04-03.md` - intended long-term lifecycle model
- `docs/research/dark-factory-feature-flag-governance-2026-04-03.md` - governance rules for flag-backed release

---

## 1. Scope Of This Contract

This contract applies only to the deploy-dark lifecycle MVP.

It defines:

- who may approve release
- what minimum metadata must exist before release approval is possible
- which status transitions are allowed
- which transitions must fail closed

It does **not** define:

- real production deploy automation
- percentage rollout rules
- advanced multi-role approval workflows
- generalized release policy for all of Slackex

Those belong to later phases.

---

## 2. MVP Authority Decision

**Decision:** only the run's designated `feature_owner` may approve release in the MVP.

### Why this is the right MVP rule

- it preserves the "person with skin in the game" boundary
- it is much safer than allowing any authenticated factory client to release
- it keeps the approval rule easy to test and reason about
- it avoids prematurely designing a larger product-approval permission model

### If `feature_owner` is not yet fully modeled

The implementation may use a temporary but explicit equivalent, as long as:

- the approver identity is persisted
- only one designated human authority can approve the release
- the temporary rule is documented in code and tests

The system must fail closed if no valid feature owner can be determined.

---

## 3. MVP Metadata Required Before Release Decision

A run must not enter `awaiting_release_decision` unless it has all of the following:

| Field | Reason |
|---|---|
| `flag_name` | The PO must know what runtime control governs exposure |
| `rollback_path` | The PO must know how to disable the feature quickly |
| `release_criteria` | The PO must know what conditions justify enabling the feature |

### Field semantics

- `flag_name` must be a concrete runtime flag name, not a placeholder
- `rollback_path` must describe a real disable path, not "revert later"
- `release_criteria` must be human-readable enough to support a release decision

### Explicitly not required in the MVP

The following may be added later, but are not mandatory in this first slice:

- rollout audience controls
- approval note requirements
- separate deploy evidence record type
- cleanup owner metadata

---

## 4. Allowed Status Transitions In The MVP

The MVP lifecycle introduces only these new release-facing states:

- `deployed_dark`
- `awaiting_release_decision`
- `released`
- `awaiting_flag_cleanup`
- `completed`

### Allowed transitions

| From | To | Allowed | Notes |
|---|---|---|---|
| `verifying_tier2` | `deployed_dark` | Yes | Trusted recorded state in MVP; not real deploy automation yet |
| `deployed_dark` | `awaiting_release_decision` | Yes | Only if minimum metadata exists |
| `awaiting_release_decision` | `released` | Yes | Requires authorized feature-owner approval |
| `released` | `awaiting_flag_cleanup` | Yes | Explicit cleanup phase |
| `awaiting_flag_cleanup` | `completed` | Yes | Means released and cleanup-complete |

### Invalid transitions that must fail closed

| Invalid transition | Why it must fail |
|---|---|
| `verifying_tier2 -> released` | Skips deploy-dark and PO decision |
| `deployed_dark -> completed` | Skips release and cleanup |
| `awaiting_release_decision -> completed` | Skips release and cleanup |
| `released -> completed` | Skips explicit cleanup phase |
| `awaiting_flag_cleanup -> released` without defined rule | Prevents ambiguous re-entry |

---

## 5. Approval Rules

### Release approval must require:

- run is currently `awaiting_release_decision`
- caller is the authorized `feature_owner`
- required metadata is present

### Release approval must persist:

- approver identity
- approval timestamp

### Release approval must emit:

- a persisted lifecycle event
- a channel-thread-visible update if notifier integration exists

---

## 6. Failure-Closed Rules

The MVP must fail closed in these cases:

- no designated `feature_owner`
- caller is not the designated `feature_owner`
- run is not in `awaiting_release_decision`
- `flag_name` missing
- `rollback_path` missing
- `release_criteria` missing

In all of these cases, the system must not partially transition to `released`.

---

## 7. Required Tests

These tests must exist before the MVP is considered done:

- authorized feature owner can approve release from `awaiting_release_decision`
- non-owner cannot approve release
- release approval from the wrong source state fails
- missing `flag_name` blocks entry to `awaiting_release_decision`
- missing `rollback_path` blocks entry to `awaiting_release_decision`
- missing `release_criteria` blocks entry to `awaiting_release_decision`
- `completed` is only reachable after `awaiting_flag_cleanup`
- approval persists approver identity and timestamp

---

## 8. Decision Record

### Why this contract is intentionally narrow

The hardest and most important thing to get right first is not deployment automation. It is the business authority boundary. If the factory can model deploy-dark and human release correctly, the rest can be added incrementally without changing the core trust model.

### Revisit triggers

This contract must be revisited if any of the following happen:

- real production deploy automation is added
- more than one human role may approve release
- rollout audiences become first-class in the MVP
- approval is delegated to non-human actors
- cleanup policy becomes more complex than a single explicit stage
