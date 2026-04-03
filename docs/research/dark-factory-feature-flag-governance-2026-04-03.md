# Dark Factory Feature-Flag Governance

**Date:** 2026-04-03
**Status:** Proposal
**Purpose:** Define how feature flags should be used when the dark factory delivers code to production before business release.

**Related:**
- `docs/research/dark-factory-lifecycle-proposal-2026-04-03.md`
- `docs/research/dark-factory-spec-driven-development-discovery-2026-03-08.md`
- `docs/research/vision-roadmap-2026-03-08.md`

---

## 1. Why This Needs Governance

If the dark factory deploys code to production behind feature flags, then feature flags are no longer just implementation details. They become part of the delivery contract.

Without governance, feature flags turn into:

- hidden release decisions
- permanent dead branches
- unclear ownership
- stale rollout logic
- ambiguity around when work is truly done

For the dark factory, a feature flag should be treated as a temporary business-control mechanism with explicit ownership, evidence, and cleanup expectations.

---

## 2. Core Principles

### Deploy Is Not Release

Deploying code behind a flag is a technical event. Enabling that flag for real users is a business event.

### The PO Owns Exposure

The person with skin in the game decides whether the feature becomes visible.

### Flags Are Temporary

Feature flags used for dark-factory delivery must be removed once the feature is proven stable.

### Evidence Before Enablement

A PO should not be asked to trust the agent blindly. The factory must present enough evidence for a grounded release decision.

---

## 3. Required Metadata For Every Factory-Delivered Flag

Every factory run that intends dark deployment should carry at least this metadata:

| Field | Purpose |
|---|---|
| `flag_name` | The concrete runtime flag controlling exposure |
| `flag_default` | Usually `off` for dark deployment |
| `feature_owner` | The human accountable for release decision |
| `release_audience` | Who the feature can be enabled for first |
| `release_criteria` | What must be true before enablement |
| `rollback_path` | How to disable or contain the feature quickly |
| `cleanup_trigger` | What condition means the flag should now be removed |
| `cleanup_owner` | Who owns final cleanup if the factory does not complete it automatically |

This metadata should be attached to the run, not buried only in code comments or chat history.

---

## 4. Flag Naming Rules

Dark-factory-delivered flags should follow consistent rules:

- names should describe the user-visible capability, not the internal task name
- names should be stable enough to appear in dashboards, release notes, and approval workflows
- names should avoid implementation jargon like `tier2_rewrite_v3`

Preferred shape:

```text
feature_<capability_name>
```

Examples:

- `feature_channel_summarization`
- `feature_push_notifications`
- `feature_factory_status_visibility`

Avoid:

- `temp_fix_flag`
- `new_flow_v2`
- `mvp_test_toggle`

---

## 5. Release Authority Model

### The factory may:

- create the flag
- ship code with the flag default-off
- verify dark deployment behavior
- present a release recommendation

### The factory may not:

- decide the business release on its own
- silently broaden audience exposure
- treat technical success as permission to release

### The PO may:

- approve release
- reject release
- request a narrower rollout
- require more evidence before release

---

## 6. Evidence Required Before A PO Green Light

Before a feature can move from `awaiting_release_decision` to `released`, the factory should surface at least:

- summary of what changed
- verification result summary
- deployment status confirming the code is live dark
- key observability signals relevant to the feature
- known risks or open questions
- explicit rollback path

The PO does not need raw implementation detail. They need enough evidence to make an informed exposure decision.

---

## 7. Rollout Expectations

The governance model should support progressive exposure, not only all-or-nothing enablement.

Possible rollout shapes:

- enabled only for internal users
- enabled only for a PO or review cohort
- enabled for a small percentage or named audience if the flag system supports it
- enabled globally once confidence is sufficient

The important thing is that the intended rollout audience is explicit before release approval.

---

## 8. Cleanup Policy

### Release is not the end

After a feature is released, the flag should move into a cleanup phase, not stay indefinitely.

### Cleanup should happen when:

- the feature has proven stable
- no rollback value remains in the flag
- the PO considers the capability part of the normal product surface

### Cleanup should include:

- removing the flag checks
- removing temporary rollout branches
- removing obsolete docs or special-case instructions
- updating tests so the feature is the default behavior

### Completion rule

For dark-factory-delivered work, **completed** should mean:

- deployed dark
- PO-approved release happened
- temporary feature flag was removed

---

## 9. Failure Modes This Governance Prevents

This model is specifically meant to prevent:

- the factory self-approving customer exposure
- features that sit dark in production forever without clear ownership
- flags that become permanent architecture by neglect
- confusion over whether a feature is done, deployed, released, or merely hidden
- rollback uncertainty because no one defined the disable path upfront

---

## 10. Minimal Implementation Implications

This governance proposal implies future dark factory work should add:

- run-level fields or associated records for release metadata
- explicit approval events from human stakeholders
- explicit transition from `deployed_dark` to `awaiting_release_decision`
- explicit cleanup tracking after release

The current system does not need all of this immediately. But if the factory is heading toward production-behind-flag delivery, these are not optional forever.

---

## 11. Recommendation

The dark factory should aim for this contract:

- **Agents deliver deployable code**
- **The system deploys dark**
- **A PO green-lights exposure**
- **The factory later removes the flag**

That is the cleanest separation of technical automation and business accountability.
