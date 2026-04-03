# Dark Factory Deploy-Dark Lifecycle Plan v2

> **For agentic workers:** REQUIRED: do not automate production deployment in this phase. The purpose of this v2 plan is to install the correct lifecycle and approval model first, with deterministic state transitions and explicit human authority.

**Goal:** Introduce the deploy-dark release model into `Slackex.Factory` without yet automating real production deployment. The factory should be able to represent and enforce these distinctions:

- verified
- deployed dark
- awaiting release decision
- released
- awaiting flag cleanup
- completed

**Why v2 exists:** The broader lifecycle plan is directionally right, but too large for a safe first implementation. This revision keeps the most important change — the correct state model and approval boundary — while deferring real deploy automation and broad MCP surface area.

**Architecture:** Extend `Slackex.Factory.Run` and `Slackex.Factory` with new statuses, release metadata, and explicit human approval transitions. Treat `deployed_dark` as a trusted recorded state in this MVP rather than a fully automated production deploy action.

**Tech Stack:** `Slackex.Factory`, `Slackex.Factory.Run`, `Slackex.Factory.Event`, `SlackexWeb.MCP.FactoryTools`, FunWithFlags, Phoenix PubSub.

**Parent docs:**
- `docs/plans/2026-04-03-dark-factory-deploy-dark-lifecycle-plan.md`
- `docs/research/dark-factory-lifecycle-proposal-2026-04-03.md`
- `docs/research/dark-factory-feature-flag-governance-2026-04-03.md`

**Companion docs:**
- `docs/plans/2026-04-03-dark-factory-release-approval-contract.md` - human approval boundary, minimum metadata, and allowed MVP transitions

---

## MVP Outcome

At the end of this phase:

- the factory run model can represent deploy-dark, release-decision, and cleanup states explicitly
- `completed` no longer means merely "verification passed"
- release approval is a first-class, persisted, authorized event
- the factory can move through a deterministic state machine from verified -> deployed dark -> awaiting PO decision -> released -> completed
- at least one end-to-end state-machine test proves this lifecycle

This is a **lifecycle and authority MVP**, not a deployment automation MVP.

---

## Non-Goals

- Do not automate real production deploys from the factory in this phase.
- Do not add tag creation, CI orchestration, or deploy-run polling to the factory.
- Do not build a broad release-management API.
- Do not implement percentage rollouts or advanced audience targeting yet.
- Do not remove or weaken the human release authority boundary.

---

## Task 0: Lock The Human Approval Contract

**Files:**
- Create a companion contract doc if needed

- [ ] **Step 1: Define who may approve release in the MVP**

Choose one narrow rule and test it explicitly. Recommended default:

- only the designated `feature_owner` may approve release

If `feature_owner` is not yet modeled as a user relation, define the simplest temporary equivalent and document it.

- [ ] **Step 2: Define the minimum metadata required for a run to enter `awaiting_release_decision`**

Recommended minimum:

- `flag_name`
- `rollback_path`
- `release_criteria`

Keep this small. More metadata can be added later.

- [ ] **Step 3: Define the exact status transitions allowed in the MVP**

Required transitions:

- `verifying_tier2 -> deployed_dark`
- `deployed_dark -> awaiting_release_decision`
- `awaiting_release_decision -> released`
- `released -> awaiting_flag_cleanup`
- `awaiting_flag_cleanup -> completed`

Also define the invalid transitions that must fail closed.

---

## Task 1: Extend The Factory Run Model Minimally

**Files:**
- Modify: `lib/slackex/factory/run.ex`
- Add migration under `priv/repo/migrations/`
- Add tests in `test/slackex/factory_test.exs`

- [ ] **Step 1: Add the new statuses**

Add only the statuses needed for the MVP:

- `deployed_dark`
- `awaiting_release_decision`
- `released`
- `awaiting_flag_cleanup`

Do not add `awaiting_deploy` or `deploying_dark` yet.

- [ ] **Step 2: Add only the minimum new fields**

Recommended minimum fields:

- `flag_name`
- `rollback_path`
- `release_criteria`
- `released_at`
- `released_by_id`

These are enough to model the approval boundary without overdesigning the record.

- [ ] **Step 3: Keep the migration expand-only**

Use nullable fields and do not require backfill for old runs.

- [ ] **Step 4: Add schema tests**

Test:

- new statuses are accepted
- required metadata can be validated for release-capable transitions

---

## Task 2: Add Pure State Transitions In `Slackex.Factory`

**Files:**
- Modify: `lib/slackex/factory.ex`
- Modify: `lib/slackex/factory/event.ex` if needed
- Create: `test/slackex/factory/release_lifecycle_test.exs`

- [ ] **Step 1: Add explicit transition functions**

Recommended functions:

- `mark_deployed_dark/2`
- `request_release_decision/2`
- `approve_release/2`
- `mark_awaiting_flag_cleanup/2`
- `complete_flag_cleanup/2`

These should be state-machine functions first, not deployment orchestration hooks.

- [ ] **Step 2: Enforce legal transitions only**

Examples:

- cannot approve release before `awaiting_release_decision`
- cannot complete flag cleanup before `awaiting_flag_cleanup`
- cannot skip directly from verification to `released`

- [ ] **Step 3: Persist clear lifecycle events**

Each transition should append an auditable event such as:

- `deployed_dark`
- `awaiting_release_decision`
- `release_approved`
- `awaiting_flag_cleanup`
- `flag_cleanup_completed`

---

## Task 3: Make Human Approval First-Class

**Files:**
- Modify: `lib/slackex/factory.ex`
- Modify: `lib/slackex/factory/channel_notifier.ex`
- Extend tests in `test/slackex/factory/release_lifecycle_test.exs`

- [ ] **Step 1: Persist approver identity and time**

When a run moves to `released`, store:

- approver identity
- approval timestamp
- optional approval note if useful

- [ ] **Step 2: Make the approval boundary visible in the channel thread**

The channel notifier should surface:

- feature deployed dark
- awaiting PO decision
- feature released
- awaiting flag cleanup

- [ ] **Step 3: Ensure unauthorized approval fails closed**

This is the key business rule of the MVP.

---

## Task 4: Add A Minimal MCP Surface

**Files:**
- Modify: `lib/slackex_web/mcp/factory_tools.ex`
- Create: `test/slackex_web/mcp/factory_release_tools_test.exs`

- [ ] **Step 1: Add only the smallest useful tool set**

Recommended MVP tools:

- `mark_factory_deployed_dark`
- `approve_factory_release`
- `complete_factory_flag_cleanup`

Do not add a large deploy-management or release-management surface.

- [ ] **Step 2: Encode the human boundary in `approve_factory_release`**

That tool must:

- require explicit caller identity
- reject unauthorized callers
- reject illegal source states

- [ ] **Step 3: Add positive and negative MCP tests**

At minimum:

- authorized release approval succeeds
- unauthorized release approval fails
- illegal transition fails

---

## Task 5: Prove The Lifecycle With A Deterministic Dogfood Test

**Files:**
- Create: `docs/runbooks/dark-factory-release-decision.md`
- Extend release-lifecycle tests

- [ ] **Step 1: Add one deterministic lifecycle test**

Prove this exact flow:

1. run is verified
2. run is marked `deployed_dark`
3. run moves to `awaiting_release_decision`
4. authorized human approval moves it to `released`
5. run moves to `awaiting_flag_cleanup`
6. cleanup completion moves it to `completed`

- [ ] **Step 2: Write the manual runbook**

Document:

- what the PO sees
- what evidence the PO should review
- how approval is recorded
- when cleanup should happen

This runbook should describe the business workflow, not just the internal state machine.

---

## Acceptance Criteria

- `Slackex.Factory.Run` can represent `deployed_dark`, `awaiting_release_decision`, `released`, and `awaiting_flag_cleanup`.
- `completed` is reserved for released-and-cleaned-up work.
- release approval is a persisted, authorized, auditable transition.
- unauthorized release approval fails closed.
- the channel thread can distinguish deployed dark from released.
- at least one deterministic lifecycle test proves the new end-state model.

---

## Suggested Execution Order

1. Task 0 - human approval contract
2. Task 1 - schema and migration
3. Task 2 - pure transitions
4. Task 3 - approval modeling and notifier updates
5. Task 4 - minimal MCP surface
6. Task 5 - dogfood test and runbook

---

## Deferred Follow-Up Work

If this MVP succeeds, the next phase can add:

- explicit `awaiting_deploy` and `deploying_dark` states
- real deploy integration with tags/CI
- rollout audience controls
- richer release evidence resources over MCP
- automatic cleanup-run creation after release stabilization

Those are intentionally deferred until the lifecycle and authority boundary are proven in code.
