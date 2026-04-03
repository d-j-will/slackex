# Dark Factory Deploy-Dark Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED: implement this plan in slices. Do not jump directly to automatic release. Preserve the boundary that deployment may be automated but exposure requires explicit human approval.

**Goal:** Evolve `Slackex.Factory` from an implementation-and-verification pipeline into a deploy-dark release workflow where verified work can move into production behind a feature flag, await PO approval for exposure, and later complete only after flag cleanup.

**Architecture:** Extend the existing factory run model with explicit deployment, release-decision, and cleanup stages. Treat feature flags as first-class run metadata. Reuse MCP as the control surface, channel-thread updates as the human-visible status surface, and existing deployment/tagging practices as the production handoff path.

**Tech Stack:** `Slackex.Factory`, `Slackex.Factory.Run`, `Slackex.Factory.Event`, `SlackexWeb.MCP.FactoryTools`, FunWithFlags, existing deployment pipeline, Phoenix PubSub.

**Parent docs:**
- `docs/research/dark-factory-spec-driven-development-discovery-2026-03-08.md`
- `docs/research/dark-factory-lifecycle-proposal-2026-04-03.md`
- `docs/research/dark-factory-feature-flag-governance-2026-04-03.md`
- `docs/research/vision-roadmap-2026-03-08.md`

---

## Why This Phase Exists

Today, the factory lifecycle effectively ends after verification. That is too early for the end-state you described.

The intended completion boundary is:

- implementation passes
- verification passes
- code is deployed dark behind a feature flag
- a PO with skin in the game green-lights exposure
- the feature flag is later removed

This plan is about building that missing lifecycle, without collapsing deployment and release into the same decision.

---

## Current State

The current factory model in `lib/slackex/factory/run.ex` supports these statuses:

- `queued`
- `implementing`
- `awaiting_verification`
- `verifying_tier2`
- `completed`
- `needs_review`
- `cancelled`

Current gaps relative to the intended end-state:

- no deploy-dark stage
- no release-decision stage
- no cleanup stage
- no feature-flag metadata on runs
- no explicit human approval event model
- `completed` currently means "verification complete," not "released and cleaned up"

---

## Non-Goals

- Do not implement automatic feature exposure in this phase.
- Do not remove the human release authority boundary.
- Do not build percentage rollouts unless FunWithFlags support is already straightforward and well-bounded.
- Do not attempt a full generalized release-management system for all of Slackex.
- Do not couple this phase to Tauri, huddles, or pair-programming work.

---

## Proposed Delivery Strategy

Implement this in three bounded waves:

1. **Lifecycle modeling** — extend statuses and run metadata, but no deploy execution yet
2. **Human approval workflow** — explicit PO approval and release gating
3. **Deploy-dark orchestration and cleanup** — controlled automation into production-behind-flag and explicit cleanup tracking

This prevents the system from jumping straight into deployment automation before its state model is trustworthy.

---

## File Structure

### New Files

| File | Responsibility |
|---|---|
| `test/slackex/factory/release_lifecycle_test.exs` | End-to-end lifecycle tests for deploy-dark, approval, and cleanup transitions |
| `test/slackex_web/mcp/factory_release_tools_test.exs` | MCP-level tests for approval/release lifecycle tools |
| `docs/runbooks/dark-factory-release-decision.md` | Manual workflow for PO release approval and post-release cleanup |

### Modified Files

| File | Change |
|---|---|
| `lib/slackex/factory/run.ex` | Add new statuses and feature-flag metadata fields |
| `lib/slackex/factory.ex` | Add lifecycle transitions for deploy-dark, release approval, and cleanup |
| `lib/slackex/factory/event.ex` | Extend event vocabulary if needed for approval/release/cleanup events |
| `lib/slackex/factory/channel_notifier.ex` | Improve channel thread updates for deploy and release milestones |
| `lib/slackex_web/mcp/factory_tools.ex` | Add narrowly scoped tools for deploy-dark readiness, release approval, and cleanup transitions |
| `test/slackex/factory_test.exs` | Update current lifecycle expectations |

### Migration Work

| File | Change |
|---|---|
| `priv/repo/migrations/*_extend_factory_runs_for_release_lifecycle.exs` | Add new run fields and any indexes needed for release-state queries |

---

## Proposed Run Fields

To support the deploy-dark lifecycle, `factory_runs` should eventually track at least:

| Field | Purpose |
|---|---|
| `flag_name` | Runtime flag controlling exposure |
| `flag_default` | Usually `off` |
| `feature_owner_id` or equivalent | Person accountable for release decision |
| `release_audience` | Initial rollout audience |
| `release_criteria` | Structured or text summary of required evidence |
| `rollback_path` | How the feature is disabled quickly |
| `deploy_result` | Deployment evidence/result summary |
| `released_at` | When the feature was exposed |
| `released_by_id` | Who approved exposure |
| `cleanup_status` | Cleanup stage if split from main status |
| `flag_removed_at` | When the flag was removed |

Not all of these have to land in the first migration, but the design should be explicit about the intended record shape.

---

## Proposed Lifecycle States For Implementation

Add these statuses to `Slackex.Factory.Run`:

- `awaiting_deploy`
- `deploying_dark`
- `deployed_dark`
- `awaiting_release_decision`
- `released`
- `awaiting_flag_cleanup`

Retain:

- `queued`
- `implementing`
- `awaiting_verification`
- `verifying_tier2`
- `needs_review`
- `cancelled`
- `completed`

The meaning of `completed` changes: it should only represent work that is released and cleanup-complete.

---

## Task 0: Lock The Lifecycle And Authorization Contract

**Files:**
- Update or create planning/contract docs as needed

- [ ] **Step 1: Define which transitions require explicit human approval**

At minimum:

- `awaiting_release_decision -> released` requires explicit PO approval

Decide whether `awaiting_deploy -> deploying_dark` also requires approval initially.

- [ ] **Step 2: Define who is authorized to approve release**

For the first slice, prefer a narrow rule over a flexible one. Example options:

- only the run's designated `feature_owner`
- channel owner/admin plus explicit `feature_owner`
- a dedicated product-owner flag or role

- [ ] **Step 3: Define the exact minimum metadata required before a run can reach `awaiting_release_decision`**

This should include:

- `flag_name`
- `rollback_path`
- `release_criteria`
- verification summary
- deployment summary

---

## Task 1: Extend The Factory Run Schema Safely

**Files:**
- Modify: `lib/slackex/factory/run.ex`
- Create migration under `priv/repo/migrations/`
- Add tests in `test/slackex/factory_test.exs`

- [ ] **Step 1: Add failing tests for new statuses and required fields**

Test that the schema accepts the new lifecycle statuses and validates required metadata for release-capable runs.

- [ ] **Step 2: Write an expand-only migration**

Add new nullable fields first. Do not make the migration depend on immediate backfill of old runs.

- [ ] **Step 3: Update `Run` changesets carefully**

Keep queue-time requirements minimal for the first wave if needed. It is acceptable to add release metadata in later transitions rather than forcing all new fields at queue time immediately.

- [ ] **Step 4: Run factory schema tests and migration tests**

Targeted tests first; full suite later.

---

## Task 2: Add Pure Lifecycle Transitions In `Slackex.Factory`

**Files:**
- Modify: `lib/slackex/factory.ex`
- Modify: `lib/slackex/factory/event.ex`
- Create: `test/slackex/factory/release_lifecycle_test.exs`

- [ ] **Step 1: Add transition functions without deploy side effects first**

Examples:

- `mark_awaiting_deploy/2`
- `mark_deployed_dark/2`
- `request_release_decision/2`
- `approve_release/2`
- `mark_awaiting_flag_cleanup/2`
- `complete_flag_cleanup/2`

Keep these functions primarily about state validation and persistence.

- [ ] **Step 2: Enforce transition legality**

Examples:

- cannot approve release from `awaiting_verification`
- cannot mark deployed dark before verification passes
- cannot complete cleanup before release

- [ ] **Step 3: Emit explicit events for each transition**

Use `factory_events` to make the lifecycle auditable.

Suggested event types or status-change messages:

- deployment requested
- deployed dark
- awaiting release decision
- release approved
- cleanup started
- flag cleanup completed

- [ ] **Step 4: Add focused lifecycle tests**

Test both happy-path transitions and illegal transitions.

---

## Task 3: Make Human Approval A First-Class Workflow Step

**Files:**
- Modify: `lib/slackex/factory.ex`
- Modify: `lib/slackex/factory/channel_notifier.ex`
- Add tests in `test/slackex/factory/release_lifecycle_test.exs`

- [ ] **Step 1: Model approval as data, not just a chat convention**

When release is approved, persist:

- who approved it
- when it was approved
- any optional approval note

- [ ] **Step 2: Surface release-decision state clearly in channel threads**

The channel notifier should produce thread updates that make these states obvious:

- deployed dark
- awaiting PO decision
- release approved
- awaiting flag cleanup

- [ ] **Step 3: Ensure the factory cannot self-approve**

Do not let claim tokens or implementation agents trigger the release approval transition unless they are explicitly acting as the approved human authority model.

---

## Task 4: Add Narrow MCP Control Surfaces For The New Lifecycle

**Files:**
- Modify: `lib/slackex_web/mcp/factory_tools.ex`
- Create: `test/slackex_web/mcp/factory_release_tools_test.exs`

- [ ] **Step 1: Add only the minimum new tools needed**

Possible tools:

- `mark_factory_awaiting_deploy`
- `mark_factory_deployed_dark`
- `approve_factory_release`
- `mark_factory_awaiting_flag_cleanup`
- `complete_factory_flag_cleanup`

Do not add a large release-management API in one pass.

- [ ] **Step 2: Encode the human boundary in the tool contract**

`approve_factory_release` should require explicit approved identity and should fail closed if the caller is not authorized.

- [ ] **Step 3: Add MCP tests for positive and negative cases**

At minimum:

- authorized approval succeeds
- unauthorized approval fails
- illegal lifecycle transition fails

---

## Task 5: Add Deploy-Dark And Cleanup Dogfood Paths

**Files:**
- Create: `docs/runbooks/dark-factory-release-decision.md`
- Extend tests as needed

- [ ] **Step 1: Write a manual runbook for the human boundary**

The runbook should explain:

- what evidence the PO reviews
- how release approval is recorded
- how to disable the feature quickly
- when the flag should be removed

- [ ] **Step 2: Prove one deterministic lifecycle test**

The first dogfood test should prove:

1. run reaches `deployed_dark`
2. run transitions to `awaiting_release_decision`
3. authorized human approval moves it to `released`
4. cleanup transition later moves it to `completed`

This can be state-machine-level before true production deploy automation is wired in.

---

## Acceptance Criteria

- `Slackex.Factory.Run` can represent deploy-dark, release-decision, and cleanup states explicitly.
- `completed` no longer ambiguously means only verification complete.
- Feature-flag metadata is modeled explicitly enough to support release decisions.
- Release approval is persisted as a first-class event and authorized action.
- The factory cannot transition to `released` without the defined human approval boundary.
- Channel thread updates clearly distinguish deployed dark, awaiting release decision, and released states.
- At least one deterministic test proves the full lifecycle from verified work to release approval to cleanup completion.

---

## Suggested Execution Order

1. Task 0 - lifecycle and authorization contract
2. Task 1 - schema and migration
3. Task 2 - pure lifecycle transitions
4. Task 3 - human approval modeling
5. Task 4 - MCP tools and authorization
6. Task 5 - dogfood runbook and deterministic lifecycle proof

---

## Recommended Scope Cut For MVP

If this phase feels too large, cut it here:

- implement lifecycle states and release approval modeling
- do not yet automate real production deployment from the factory
- treat `deployed_dark` as an explicitly recorded state transition driven by a trusted operator or deployment integration

That would still let the factory adopt the correct conceptual model without overcommitting to deployment automation too early.
