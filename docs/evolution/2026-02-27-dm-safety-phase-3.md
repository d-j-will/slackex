# DM Safety Phase 3: Feature Evolution

**Date:** 2026-02-27
**Status:** Complete
**Project ID:** dm-safety-phase-3
**Test Count:** 712 (0 failures)
**Duration:** ~35 minutes (20:14 - 20:49 UTC)

## Summary

Phase 3 of the DM Safety System introduced a complete abuse reporting system with graduated enforcement. Users can report other users from the DM conversation header or from individual messages, selecting one of five report categories with an optional description. Reports trigger auto-blocking of the reported user, trust score accumulation, distinct-reporter threshold enforcement (dm_restricted at 3+, admin_flagged at 5+), velocity-based restriction (3+ negative signals in 24 hours), and coordinated-report dampening to prevent abuse of the reporting system itself. This phase builds on the Phase 2 infrastructure (trust scores, DM restrictions, blocking).

## Motivation

- Phase 2 established consent-before-contact and trust scoring, but users had no mechanism to report abusive behavior after a conversation was accepted.
- Accumulated blocks from Phase 2 provided one signal, but explicit abuse reports carry stronger intent and enable category-based triage (spam vs harassment vs phishing).
- No automated escalation existed to flag users for admin review based on the volume and diversity of reports.
- Coordinated reporting (multiple users filing reports within a short window) could artificially inflate distinct-reporter counts and trigger premature restrictions.

## Architecture Decisions

### Graduated enforcement via independent gates

Two independent enforcement paths can each trigger `dm_restricted`: (1) distinct-reporter thresholds (3+ dampened clusters restrict, 5+ admin-flag), and (2) velocity detection (3+ negative signals within 24 hours). These gates are independent -- either can fire without the other. This prevents a user who accumulates rapid negative signals from evading restriction just because the distinct-reporter count is still low, and vice versa.

### Coordinated-report dampening

To prevent abuse of the reporting system, reporters whose first report against a given user falls within the same 24-hour window are grouped into a single "cluster" for threshold math. The algorithm walks time-sorted `{reporter_id, first_report_at}` pairs and starts a new cluster whenever a reporter's timestamp exceeds the current window start by more than 24 hours. This means 5 people filing reports in the same afternoon count as 1 distinct reporter cluster, while 3 people filing on 3 separate days count as 3. The dampening only affects threshold calculations -- individual reports are still recorded and visible for admin review.

### Self-report prevention via pattern matching

Self-reporting is prevented at the function head level using Elixir's pattern matching: `defp check_self_report(user_id, user_id), do: {:error, :self_report}`. This is a compile-time structural guarantee rather than a runtime conditional, making the invalid state unrepresentable at the function boundary.

### Auto-block as unidirectional side effect

When a reporter submits a report, the system automatically calls `block_user(reporter_id, reported_user_id)`, creating a unidirectional block. The reporter no longer sees messages from the reported user. This is a side effect of reporting, not a separate action, ensuring immediate relief for the reporter. Errors from `block_user/2` are silently ignored (the user may already be blocked).

### Report modal component reuse

A single `report_modal/1` component serves both header-level reports (no message context) and message-level reports (pre-filled `dm_conversation_id` and `message_id`). The `report_message_id` assign controls whether message context is included. This avoids component duplication while preserving the ability to associate reports with specific messages for admin review.

### Velocity detection across signal types

Velocity detection counts all negative signals (reports, blocks, and request declines) against a user within a 24-hour sliding window. This cross-signal approach means a user who receives 1 report, 1 block, and 1 decline within 24 hours triggers restriction -- any single signal type alone would not reach the threshold, but the combination indicates a problematic user.

## Implementation Phases

### Phase 01: Schema and Report Creation (Steps 01-01 through 01-02)

| Commit | Step | Description |
|--------|------|-------------|
| `3ef2178` | 01-01 | Create `abuse_reports` table: Snowflake PK, reporter/reported user FKs, nullable dm_conversation_id and message_id, category enum, description text, status enum, metadata JSONB, partial unique index on (reporter_id, reported_user_id) WHERE status = 'open' |
| `434c53c` | 01-02 | `create_abuse_report/3` with pre-flight pipeline: self-report check, 7-day account age gate, dm_restricted check; on success: insert report, auto-block, upsert report_count on trust score |

### Phase 02: Auto-escalation and Enforcement (Steps 02-01 through 02-02)

| Commit | Step | Description |
|--------|------|-------------|
| `cf9c4de` | 02-01 | Distinct reporter thresholds with dampening: 3+ dampened clusters trigger dm_restricted, 5+ trigger admin_flagged; migration adds admin_flagged boolean and admin_flagged_at to user_trust_scores |
| `a4ec75d` | 02-02 | Velocity detection: count reports + blocks + declines within 24h, restrict at 3+; coordinated-report dampening algorithm for cluster counting |

### Phase 03: Report UI (Steps 03-01 through 03-02)

| Commit | Step | Description |
|--------|------|-------------|
| `a408549` | 03-01 | Report button in DM header (next to Block, hidden for self-DMs), report_modal component with 5 category radio buttons and optional description, submit/close event handlers with flash feedback |
| `4ebeb04` | 03-02 | Report action on individual messages (hover menu, hidden on own messages), pre-fills dm_conversation_id and message_id, reuses report_modal component |

### Quality Passes

| Commit | Description |
|--------|-------------|
| `09ee541` | Auto-format existing files to pass pre-commit hook |
| `d7db203` | RPP L1-L4 refactoring applied to all feature code and tests |
| `218e8c6` | Adversarial review defects D2, D3, D5, D6, D7 resolved |

## Quality Metrics

### Test Coverage

- **Starting test count:** 666
- **Final test count:** 712 (46 new tests)
- **Failures:** 0

### TDD Execution

All 6 steps followed 5-phase TDD cycles (PREPARE, RED_ACCEPTANCE, RED_UNIT, GREEN, COMMIT). Every phase across all steps reached PASS status. The execution log records 30 events (5 phases x 6 steps), all with disposition PASS.

### Refactoring (RPP L1-L4)

Applied Refactoring Priority Protocol across all modified files (commit `d7db203`):
- **L1 (Critical):** Naming, dead code
- **L2 (High):** Duplication, function length
- **L3 (Medium):** Module organization, documentation
- **L4 (Low):** Idiomatic patterns, consistency

### Adversarial Review

Reviewed by `nw-software-crafter-reviewer`. Findings addressed in commit `218e8c6`:

| ID | Severity | Description |
|----|----------|-------------|
| D2 | High | Review defect resolved |
| D3 | High | Review defect resolved |
| D5 | Medium | Review defect resolved |
| D6 | Medium | Review defect resolved |
| D7 | Medium | Review defect resolved |

### Mutation Testing

Skipped -- no Elixir mutation testing tool (e.g., Muzak) configured. Compensating controls: comprehensive acceptance test coverage across all 6 steps, boundary condition tests for distinct-reporter thresholds and velocity windows, coordinated-report dampening verified through multi-reporter cluster scenarios, self-report prevention tested via pattern-match guard.

### DES Integrity

All 6 steps verified through DES (Design-Execute-Seal) integrity check. Execution log confirms every step reached PASS status across all 5 TDD phases with timestamps spanning 20:14 to 20:49 UTC.

## Files Modified

### New Files

- `lib/slackex/chat/abuse_report.ex` -- AbuseReport schema with Snowflake PK, category/status validation, unique constraint on open reports
- `priv/repo/migrations/20260227200500_create_abuse_reports.exs` -- abuse_reports table with partial unique index
- `priv/repo/migrations/20260227201000_add_admin_flagged_to_user_trust_scores.exs` -- admin_flagged boolean and admin_flagged_at on user_trust_scores
- `test/slackex/chat/abuse_report_test.exs` -- AbuseReport schema and changeset tests
- `test/slackex/chat/abuse_report_flow_test.exs` -- Report creation, threshold enforcement, velocity detection, dampening integration tests

### Modified Files

- `lib/slackex/chat/chat.ex` -- create_abuse_report/3 with pre-flight pipeline, upsert_report_count/1, check_report_thresholds/1, count_distinct_reporters/1, dampen_reporter_clusters/1, check_velocity/1, count_negative_signals_24h/1, maybe_apply_dm_restriction/1, maybe_apply_admin_flag/1
- `lib/slackex/chat/user_trust_score.ex` -- Added admin_flagged and admin_flagged_at fields
- `lib/slackex_web/components/chat_components.ex` -- report_modal/1 component, show_report_action?/1 helper, report action button in message hover menu
- `lib/slackex_web/live/chat_live/index.ex` -- open_report_modal, close_report_modal, report_message, submit_report event handlers; dismiss_report_modal/1 helper; report modal assigns in mount
- `test/slackex_web/live/chat_live/index_test.exs` -- LiveView integration tests for report button visibility, modal interaction, submission flows

### Formatting/Incidental Changes

- `lib/slackex/chat/dm_request.ex` -- Auto-formatted
- `lib/slackex_web/live/chat_live/browse_channels_modal.ex` -- Auto-formatted
- `lib/slackex_web/live/chat_live/create_channel_modal.ex` -- Auto-formatted
- `lib/slackex_web/live/mockup_live/index.ex` -- Auto-formatted
- `priv/repo/migrations/20260227134200_create_dm_requests.exs` -- Auto-formatted
- `priv/repo/migrations/20260227161500_add_dm_conversation_id_to_read_cursors.exs` -- Auto-formatted
- `test/slackex/accounts_test.exs` -- Auto-formatted
- `test/slackex/chat/unread_counts_test.exs` -- Auto-formatted
- `test/slackex/chat/user_block_test.exs` -- Auto-formatted
- `test/support/factory.ex` -- Extended with abuse report factory helpers

## Commit History (oldest to newest)

| Commit | Message |
|--------|---------|
| `09ee541` | style: auto-format existing files to pass pre-commit hook |
| `3ef2178` | feat(chat): add abuse_reports table and AbuseReport schema |
| `434c53c` | feat(chat): add create_abuse_report/3 with pre-flight checks and auto-block |
| `cf9c4de` | feat: enforce distinct reporter thresholds with admin flagging |
| `a4ec75d` | feat: add velocity detection and coordinated-report dampening |
| `a408549` | feat(chat): add Report button and modal in DM conversation header |
| `4ebeb04` | feat(chat): add Report button on individual DM messages |
| `d7db203` | refactor(dm-safety): L1-L4 RPP sweep on feature files |
| `218e8c6` | fix(dm-safety): address review defects D2, D3, D5, D6, D7 |

## Future Phases Remaining

### Phase 4: Privacy Controls and Admin Foundation

- Privacy settings UI for dm_preference management
- Blocked users management page
- Basic admin view for flagged users and open reports

### Phase 5: Admin Dashboard and Ban Evasion

- Admin action capabilities (suspend, warn, clear)
- IP pattern detection for ban evasion
- Per-channel DM trust settings, audit logging

**Deployment note:** The abuse reporting system is now active. Users flagged by admin_flagged = true (5+ distinct reporter clusters) should be reviewed manually until the Phase 4 admin interface is available. The system is self-maintaining for restriction (dm_restricted) but admin flagging currently has no consumer beyond the database flag.

## Lessons Learned

1. **Dampening algorithms prevent meta-abuse of safety systems.** The coordinated-report dampening turned out to be the most nuanced piece of the implementation. Without it, a group of users could file reports simultaneously to artificially inflate the distinct-reporter count and trigger restrictions against innocent users. The sliding-window cluster approach balances two competing concerns: reports from genuinely independent reporters over time should accumulate, while reports from a coordinated group within a short window should not multiply impact. The algorithm is simple (time-sorted walk with window-based clustering) but the design reasoning required careful analysis of adversarial scenarios.

2. **Independent enforcement gates provide defense in depth.** By keeping velocity detection and distinct-reporter thresholds as independent paths to dm_restricted, the system catches different abuse patterns. A user who receives a burst of negative signals (reports + blocks + declines) in a single day gets caught by velocity even if the distinct-reporter count is dampened. A user who slowly accumulates reports from different people over weeks gets caught by thresholds even if no single 24-hour window is alarming. Neither gate alone covers both patterns.

3. **Pattern matching for invalid state prevention is idiomatic Elixir.** The self-report check `defp check_self_report(user_id, user_id)` is a single function head that makes the invalid case structurally impossible to miss. Compared to a runtime `if reporter_id == reported_user_id` conditional, the pattern match is both more concise and more visible during code review. This pattern extends well to other domain invariants (e.g., preventing a user from blocking themselves, which Phase 1 already handles the same way).

4. **Component reuse through optional assigns simplifies UI maintenance.** The report_modal component serves both header-level and message-level reports by conditioning on the presence of `report_message_id`. This avoided duplicating the modal template, form handling, and validation logic. The LiveView event handlers manage the assign state, and the component remains a pure function of its inputs. When the modal needs changes (e.g., adding a new category), there is exactly one template to update.

5. **Cross-signal velocity detection captures what single-signal thresholds miss.** A user who receives 1 report, 1 block, and 1 decline in 24 hours might not trigger any single-type threshold, but the combination is a strong signal of problematic behavior. By counting all negative signal types together in `count_negative_signals_24h/1`, the velocity gate catches users who spread their unwanted behavior across different interaction types. This was a direct lesson from Phase 2's trust scoring, which tracked signals in separate columns but only used block_count for automated restriction.
