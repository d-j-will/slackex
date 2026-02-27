# DM Safety Phase 2: Feature Evolution

**Date:** 2026-02-27
**Status:** Complete
**Project ID:** dm-safety-phase-2
**Test Count:** 639 (0 failures)
**Duration:** ~84 minutes (13:41 - 15:05 UTC)

## Summary

Phase 2 of the DM Safety System introduced a consent-before-contact model through a DM Request/Accept flow. Users can no longer send direct messages to strangers without recipient consent. The system adds graduated enforcement (cooldowns and auto-blocks on repeated declines), trust scoring (automatic DM restriction for frequently blocked users), account age gates (24-hour hard gate, 7-day shared-channel gate for new accounts), and per-user DM preferences (anyone, shared_channels, nobody). This phase builds directly on the Phase 1 infrastructure (blocking, rate limiting, PubSub per-user topics).

## Motivation

- Phase 1 established reactive safety (block after contact). Phase 2 shifts to proactive safety -- recipients must consent before a stranger can message them.
- New accounts had no friction for mass-messaging other users, enabling spam and phishing vectors.
- Users had no ability to control who could initiate DM conversations with them.
- Repeated unwanted contact from the same sender had no escalating consequences.
- No automated system existed to detect and restrict users who accumulate multiple blocks from different people.

## Architecture Decisions

### Consent-before-contact via DM Requests

New DM conversations between users who have never messaged each other now require an explicit request/accept flow. The sender submits a DM request with a 500-character preview message. The recipient sees the request in a dedicated "Message Requests" sidebar section and can accept (creating the conversation), decline (with escalating consequences), or block (immediately). Users with an existing accepted DM conversation bypass the request flow entirely, preserving the frictionless experience for established contacts.

### Ordered pre-flight pipeline

`create_dm_request/3` runs an ordered pipeline of checks before creating a request: (1) account age < 24h hard gate, (2) bidirectional block check, (3) dm_restricted check, (4) cooldown check from prior declines, (5) rate limits (5/hour, 20/day, 10 pending max), (6) account < 7d shared-channel gate, (7) recipient DM preference gate. The ordering is deliberate -- cheapest and most definitive checks run first, database-heavy checks run later. Each check returns a specific error atom for clear client feedback.

### Graduated enforcement on decline

Rather than a binary block/allow model, declines between the same sender-recipient pair escalate: strike 1 imposes a 7-day cooldown, strike 2 imposes a 30-day cooldown, strike 3 triggers an automatic block via `Chat.block_user/2`. This graduated approach gives legitimate users a second chance while automatically escalating persistent unwanted contact. Cooldown thresholds are configurable via module attributes. The sender receives no notification on decline, preventing retaliation.

### Trust scoring with automatic restriction

The `user_trust_scores` table tracks decline_count, block_count, and report_count per user. When a user accumulates blocks from 5 or more distinct users (configurable via `@block_restriction_threshold`), the system automatically sets `dm_restricted = true`, which is checked early in the pre-flight pipeline. This creates a global safety net: a user who is blocked by multiple unrelated people is likely problematic, and the system acts without requiring manual admin intervention.

### Account age gates as spam defense

Two age-based gates protect against throwaway accounts: accounts under 24 hours old cannot send DM requests at all (hard gate), and accounts under 7 days old can only request DMs from users who share at least one channel (shared-channel gate). This forces new accounts to participate in community spaces before gaining full DM access, significantly raising the cost of spam account creation.

### Atomic accept via Ecto.Multi

`accept_dm_request/2` uses `Ecto.Multi` to atomically: create the DM conversation, update the request status to accepted with `dm_conversation_id` and `responded_at`, and deliver the preview text as the first message. This ensures no partial state -- if any step fails, the entire operation rolls back. The accepted event broadcasts to the sender via PubSub, triggering real-time sidebar updates.

### DM preferences at the user level

The `dm_preference` field on users provides three tiers: "anyone" (default, allows all requests), "shared_channels" (requires at least one common channel subscription), and "nobody" (rejects all new requests). This is checked as the final gate in the pre-flight pipeline, after all safety checks, so that safety enforcement always takes precedence over user preference.

## Implementation Phases

### Phase 01: Schema and Foundation (Steps 01-01 through 01-03)

| Commit | Step | Description |
|--------|------|-------------|
| `c85201a` | 01-01 | Create `dm_requests` table: Snowflake PK, sender/recipient FKs, preview_text (500 chars), status enum, partial unique index on pending |
| `661a5bf` | 01-02 | Create `user_trust_scores` table: decline/block/report counts, dm_restricted flag, unique index on user_id |
| `68a9531` | 01-03 | Add `dm_preference` column to users with default "anyone", validate allowed values |

### Phase 02: Request/Accept Core Logic (Steps 02-01 through 02-05)

| Commit | Step | Description |
|--------|------|-------------|
| `2decdef` | 02-01 | `create_dm_request/3` with ordered pre-flight: account age, blocks, dm_restricted, shared channels |
| `35dcda1` | 02-02 | Rate limiting extension: 5/hour, 20/day, 10 pending max; self-DMs exempt |
| `cff19a2` | 02-03 | DM preference gate, existing conversation bypass, PubSub broadcast on creation |
| `4379934` | 02-04 | `accept_dm_request/2` via Ecto.Multi: create DM, deliver preview message, broadcast |
| `2dc2f84` | 02-05 | `decline_dm_request/2` with graduated enforcement: 7d/30d cooldown, strike-3 auto-block, trust score increment |

### Phase 03: LiveView UI (Steps 03-01 through 03-02)

| Commit | Step | Description |
|--------|------|-------------|
| `d05bb96` | 03-01 | Message Requests sidebar section with badge count, accept/decline/block buttons |
| `6d387d3` | 03-02 | Real-time PubSub for request notifications, NewDmModal routed through create_dm_request |

### Phase 04: Trust Enforcement (Step 04-01)

| Commit | Step | Description |
|--------|------|-------------|
| `d8c341f` | 04-01 | Wire block_count increment into block_user, auto-restrict at threshold 5 |

### Quality Passes

| Commit | Description |
|--------|-------------|
| `dfaaaf2` | RPP L1-L4 refactoring applied to all feature code and tests |
| `c12f883` | Adversarial review defects D4, D5, D8, D9 resolved |

## Quality Metrics

### Test Coverage

- **Starting test count:** 545
- **Final test count:** 639 (94 new tests)
- **Failures:** 0

### TDD Execution

All 11 steps followed 5-phase TDD cycles (PREPARE, RED_ACCEPTANCE, RED_UNIT, GREEN, COMMIT). Every phase across all steps reached PASS status. The execution log records 55 events (5 phases x 11 steps), all with disposition PASS.

### Refactoring (RPP L1-L4)

Applied Refactoring Priority Protocol across all modified files (commit `dfaaaf2`):
- **L1 (Critical):** Naming, dead code
- **L2 (High):** Duplication, function length
- **L3 (Medium):** Module organization, documentation
- **L4 (Low):** Idiomatic patterns, consistency

### Adversarial Review

Reviewed by `nw-software-crafter-reviewer`. Findings addressed in commit `c12f883`:

| ID | Severity | Description |
|----|----------|-------------|
| D4 | High | Review defect resolved |
| D5 | High | Review defect resolved |
| D8 | Medium | Review defect resolved |
| D9 | Medium | Review defect resolved |

### Mutation Testing

Skipped -- no Elixir mutation testing tool (e.g., Muzak) configured. Compensating controls: comprehensive acceptance test coverage at driving ports across all 11 steps, boundary condition tests for rate limits and cooldown thresholds, graduated enforcement verified through multi-strike test scenarios, trust score accumulation tested to restriction threshold.

### DES Integrity

All 11 steps verified through DES (Design-Execute-Seal) integrity check. Execution log confirms every step reached PASS status across all 5 TDD phases with timestamps spanning 13:41 to 15:05 UTC.

## Files Modified

### New Files

- `lib/slackex/chat/dm_request.ex` -- DmRequest schema with Snowflake PK, status enum, preview_text validation
- `lib/slackex/chat/user_trust_score.ex` -- UserTrustScore schema with decline/block/report counts and dm_restricted flag
- `priv/repo/migrations/*_create_dm_requests.exs` -- dm_requests table with partial unique index
- `priv/repo/migrations/*_create_user_trust_scores.exs` -- user_trust_scores table with unique user_id index
- `priv/repo/migrations/*_add_dm_preference_to_users.exs` -- dm_preference column on users
- `test/slackex/chat/dm_request_test.exs` -- DmRequest schema tests
- `test/slackex/chat/user_trust_score_test.exs` -- UserTrustScore schema tests
- `test/slackex/chat/dm_request_flow_test.exs` -- Request/accept/decline flow integration tests
- `test/slackex/accounts/user_dm_preference_test.exs` -- DM preference validation tests
- `test/slackex/chat/trust_enforcement_test.exs` -- Trust score enforcement and auto-restriction tests

### Modified Files

- `lib/slackex/chat/chat.ex` -- 7 new public functions: create_dm_request/3, accept_dm_request/2, decline_dm_request/2, list_pending_dm_requests/1, get_dm_request/1, increment_trust_score/2, trust score enforcement in block_user/2
- `lib/slackex/chat/dm_rate_limiter.ex` -- Extended with request rate limiting (hourly and daily buckets)
- `lib/slackex/accounts/user.ex` -- Added dm_preference field with validation
- `lib/slackex_web/live/chat_live/index.ex` -- Request accept/decline/block event handlers, PubSub subscription for dm_request events
- `lib/slackex_web/live/chat_live/sidebar_component.ex` -- Message Requests section with badge count, request list rendering
- `lib/slackex_web/live/chat_live/new_dm_modal.ex` -- Routes first contact through create_dm_request instead of find_or_create_dm
- `test/slackex_web/live/chat_live_test.exs` -- LiveView integration tests for request UI and real-time updates
- `test/slackex/chat/dm_rate_limiter_test.exs` -- Extended with request rate limit tests

## Future Phases Remaining

### Phase 3: Reporting and Trust Escalation

- `abuse_reports` table with categories (spam, harassment, phishing, etc.)
- Report modal UI with category selection
- Auto-block on report, IP metadata capture
- Auto-restriction at `report_count >= 3`

### Phase 4: Privacy Controls and Admin Foundation

- Privacy settings UI for dm_preference management
- Blocked users management page
- Basic admin view for flagged users and open reports

### Phase 5: Admin Dashboard and Ban Evasion

- Admin action capabilities (suspend, warn, clear)
- IP pattern detection for ban evasion
- Per-channel DM trust settings, audit logging

**Deployment note:** The consent-before-contact model is now active. The system should remain invite-only / limited beta until Phase 3 (reporting) is complete. Phase 4 enables wider beta. Phase 5 targets production readiness for open registration.

## Lessons Learned

1. **Ordered pre-flight pipelines make complex validation maintainable.** The 7-step pipeline in `create_dm_request/3` could easily become a nested conditional mess. By structuring it as an ordered sequence with early returns and specific error atoms, each check is independently testable and the order can be reasoned about (cheapest checks first, database queries last). Adding new checks in future phases requires inserting a single function call at the correct position.

2. **Graduated enforcement is more effective than binary decisions.** The 3-strike system (7-day cooldown, 30-day cooldown, auto-block) handles the nuance between a misguided first attempt and persistent harassment. It also creates a natural data signal -- users who accumulate multiple declines from different recipients feed into the trust scoring system, enabling automated restriction without manual intervention.

3. **Trust scoring creates a self-maintaining safety system.** By wiring block_count increments into the existing `block_user/2` function, every block in the system (manual blocks, strike-3 auto-blocks, future report-triggered blocks) contributes to the trust score. The auto-restriction at threshold 5 means the safety system becomes more effective over time as it accumulates signal, without requiring admin dashboard features that are deferred to Phase 5.

4. **Existing conversation bypass preserves established relationships.** A critical UX decision: once two users have an accepted DM conversation, the request flow is completely bypassed. This prevents the consent system from adding friction to ongoing conversations. The bypass check runs before all other gates, making it the cheapest path for the common case.

5. **PubSub per-user topics proved their versatility again.** The `user:{id}` topic pattern from Phase 1 (DM conversation notifications) extended naturally to DM request notifications (new request to recipient, accepted request to sender). No new subscription infrastructure was needed -- the existing mount-time subscription handles both event types. This validates the Phase 1 decision to invest in per-user topics over per-conversation topics.

6. **Atomic multi-step operations prevent inconsistent state.** The `accept_dm_request/2` Ecto.Multi transaction ensures that conversation creation, request status update, and first message delivery either all succeed or all fail. Without this, a crash between steps could leave a request marked as accepted with no conversation, or a conversation with no initial message. The cost of Ecto.Multi is negligible compared to the debugging cost of inconsistent state.
