# DM Safety Phase 1: Feature Evolution

**Date:** 2026-02-27
**Status:** Complete
**Project ID:** dm-safety-phase-1
**Test Count:** 545 (0 failures)
**Duration:** ~40 minutes (11:00 - 11:41 UTC)

## Summary

Phase 1 of the DM Safety System addressed two foundational problems in the Phoenix LiveView chat application: broken DM delivery (recipient sidebar never updated in real-time) and the complete absence of safety controls (no blocking, no rate limiting). This phase established the infrastructure layer upon which Phases 2-5 (consent flow, reporting, privacy controls, admin dashboard) will be built.

## Motivation

- DM conversations were invisible to recipients until a manual page refresh, making the feature appear broken.
- Any user could message any other user without restriction, creating vectors for spam, harassment, and phishing.
- No mechanism existed for users to protect themselves from unwanted contact.

## Architecture Decisions

### DM Delivery Fix: PubSub per-user topic

Rather than introducing a polling mechanism or WebSocket push per conversation, the fix leveraged the existing Phoenix PubSub infrastructure. Each user subscribes to a `user:{id}` topic. When a new DM conversation is created, the system broadcasts `{:dm_conversation_new, dm}` to both participants. Reopening an existing conversation does not broadcast, preventing duplicate sidebar entries.

### Activity-based ordering via `updated_at`

Added `updated_at` (utc_datetime_usec) to `dm_conversations` with a backfill migration setting existing rows to `inserted_at`. The `send_dm` function atomically updates this timestamp within the same Ecto.Multi transaction. Sidebar queries now order by `updated_at DESC`, ensuring recent activity surfaces conversations.

### Blocking: directional model with bidirectional enforcement

The `user_blocks` table stores directional blocks (blocker_id, blocked_id) but enforcement is bidirectional: if either user has blocked the other, DM creation returns `{:error, :blocked}`. This prevents a blocked user from circumventing the block by initiating contact from their side. Self-DMs are explicitly exempt from block checks.

### Rate limiting: ETS-backed token bucket

Chose an ETS-backed token bucket (`Slackex.Chat.DmRateLimiter`) over database-backed counters or external dependencies (Redis). Rationale: the application runs as a single node, ETS provides microsecond lookups with zero external dependencies, and the 5 DMs/hour limit is a safety net rather than a precision billing meter. The ETS table is initialized in `application.ex` startup. Reopening existing conversations bypasses rate limiting.

### Search filtering: exclude_ids pattern

Rather than coupling block awareness into the Accounts context, the Chat context provides `list_blocked_user_ids/1` which returns all user IDs that should be excluded. The Accounts context accepts an `exclude_ids` option in `search_users/2`, keeping the boundary clean.

## Implementation Phases

### Phase 01: DM Delivery Fix (Steps 01-01 through 01-03)

| Commit | Description |
|--------|-------------|
| `84aeecd` | Add `updated_at` column to dm_conversations with backfill migration |
| `80a4262` | Atomic `updated_at` update in send_dm, sidebar ordered by activity |
| `ef8d462` | PubSub broadcast of new DM conversations to recipient user topic |

### Phase 02: User Blocking (Steps 02-01 through 02-03)

| Commit | Description |
|--------|-------------|
| `52f529b` | Create `user_blocks` table, schema, unique index, self-block prevention |
| `de56d72` | Context functions: block_user, unblock_user, blocked?, list_blocked_users |
| `b1f6202` | Bidirectional block enforcement in find_or_create_dm and user search |

### Phase 03: Rate Limiting and UI (Steps 03-01 through 03-03)

| Commit | Description |
|--------|-------------|
| `23cb643` | ETS-backed token bucket rate limiter for DM creation (5/hour) |
| `b6821ea` | Block button in DM conversation header with confirmation and redirect |
| `f1275d1` | Filter blocked users from new DM modal search results |

### Quality Passes

| Commit | Description |
|--------|-------------|
| `df24611` | RPP L1-L4 refactoring applied to all feature code and tests |
| `9606ab5` | Adversarial review defects D1-D6 resolved |

## Quality Metrics

### Test Coverage

- **Starting test count:** 495
- **Final test count:** 545 (50 new tests)
- **Failures:** 0

### TDD Execution

All 9 steps followed 5-phase TDD cycles (PREPARE, RED_ACCEPTANCE, RED_UNIT, GREEN, COMMIT). Unit test phases were intentionally skipped in 7 of 9 steps where acceptance tests already covered all distinct behaviors through the driving ports, avoiding redundant implementation-coupled tests.

### Refactoring (RPP L1-L4)

Applied Refactoring Priority Protocol across all modified files:
- **L1 (Critical):** Naming, dead code
- **L2 (High):** Duplication, function length
- **L3 (Medium):** Module organization, documentation
- **L4 (Low):** Idiomatic patterns, consistency

### Adversarial Review

Reviewed by `nw-software-crafter-reviewer`. Findings:

| ID | Severity | Issue | Resolution |
|----|----------|-------|------------|
| D1-D6 | Various | 5 defects found across the implementation | All resolved in commit `9606ab5` |

### Mutation Testing

Skipped -- no Elixir mutation testing tool (e.g., Muzak) was configured. Compensating controls documented: high acceptance test coverage at driving ports, bidirectional block enforcement verified through explicit test scenarios, rate limiter tested with boundary conditions.

### DES Integrity

All 9 steps verified through DES (Design-Execute-Seal) integrity check. Execution log confirms every step reached PASS status with timestamps.

## Files Modified

### New Files

- `lib/slackex/chat/user_block.ex` -- UserBlock schema
- `lib/slackex/chat/dm_rate_limiter.ex` -- ETS-backed token bucket
- `test/slackex/chat/user_block_test.exs` -- Blocking tests
- `test/slackex/chat/dm_rate_limiter_test.exs` -- Rate limiter tests
- `priv/repo/migrations/*_add_updated_at_to_dm_conversations.exs`
- `priv/repo/migrations/*_create_user_blocks.exs`

### Modified Files

- `lib/slackex/chat/dm_conversation.ex` -- Added updated_at field
- `lib/slackex/chat/chat.ex` -- Activity ordering, PubSub broadcast, blocking context, rate limit integration
- `lib/slackex/accounts/accounts.ex` -- exclude_ids support in search_users
- `lib/slackex/application.ex` -- ETS table initialization
- `lib/slackex_web/live/chat_live/index.ex` -- PubSub handler, block button UI
- `lib/slackex_web/live/chat_live/new_dm_modal.ex` -- Blocked user filtering
- `test/slackex/chat_test.exs` -- DM delivery and ordering tests
- `test/slackex_web/live/chat_live_test.exs` -- LiveView integration tests
- `test/support/factory.ex` -- Test factory additions

## Future Phases Remaining

### Phase 2: DM Request/Accept Flow

- `dm_requests` table with pending/accepted/declined status
- `user_trust_scores` table for automated enforcement
- "Message Requests" sidebar section with sanitized previews
- Graduated enforcement on decline (3-strike to auto-block)
- Account age gates (24 hours for DM requests, 7 days for non-shared-channel DMs)
- DM request rate limits (10 pending, 5 new/hour, 20/day)

### Phase 3: Reporting and Trust Escalation

- `abuse_reports` table with categories (spam, harassment, phishing, etc.)
- Report modal UI
- Auto-block on report, IP metadata capture
- Auto-restriction at `report_count >= 3`

### Phase 4: Privacy Controls and Admin Foundation

- `dm_preference` field on users (anyone, shared_channels, nobody)
- Privacy settings UI, blocked users management page
- Basic admin view for flagged users and open reports

### Phase 5: Admin Dashboard and Ban Evasion

- Admin action capabilities (suspend, warn, clear)
- IP pattern detection for ban evasion
- Per-channel DM trust settings, audit logging

**Deployment note:** The system should remain invite-only / limited beta until Phase 3 is complete. Phase 4 enables wider beta. Phase 5 targets production readiness for open registration.

## Lessons Learned

1. **PubSub per-user topics are a versatile pattern.** The `user:{id}` topic introduced for DM conversation notifications will serve as the foundation for DM request notifications in Phase 2 and potentially presence features. Investing in this pattern early avoided point-to-point broadcast logic.

2. **Bidirectional enforcement from a directional data model is the right tradeoff.** Storing blocks directionally (who blocked whom) preserves important information for trust scoring and admin review, while enforcing bidirectionally at the application layer prevents circumvention. The query cost is negligible (two indexed lookups).

3. **ETS rate limiting is sufficient for single-node.** The token bucket implementation is simple, fast, and requires no external dependencies. If the application scales to multiple nodes, this will need to move to a shared store (Redis, database, or distributed ETS via pg/syn). This is a known future migration path, not a defect.

4. **Acceptance tests at driving ports catch more real bugs than unit tests on internals.** In 7 of 9 steps, the RED_UNIT phase was intentionally skipped because acceptance tests already covered all distinct behaviors. This kept the test suite focused on observable behavior rather than implementation details, making future refactoring safer.

5. **Adversarial review after RPP refactoring catches a different class of defects.** The RPP pass cleaned up naming, duplication, and idioms. The subsequent adversarial review found integration-level concerns (boundary conditions, error handling paths) that refactoring alone would not surface. The two-pass quality approach is complementary, not redundant.
