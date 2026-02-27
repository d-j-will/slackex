# Unread Counts and Notification Polish: Feature Evolution

**Date:** 2026-02-27
**Status:** Complete
**Project ID:** unread-counts-notification-polish
**Test Count:** 666 (0 failures)
**Duration:** ~21 minutes (16:14 - 16:35 UTC)

## Summary

Added unread message count tracking and visual indicators to the sidebar of the Slack-like chat application. The feature introduces a batch unread count query that retrieves counts for all channels and DMs in exactly 2 SQL queries, wires those counts into the sidebar with numeric badges and bold styling for unread conversations, and maintains real-time accuracy through PubSub-driven increments for incoming messages on non-active conversations. Entering a conversation resets its unread count to zero.

## Motivation

- Users had no way to see which conversations had new messages without clicking into each one individually.
- The sidebar treated all conversations identically regardless of activity, making it difficult to prioritize attention.
- Existing per-channel `unread_count/2` queries would create N+1 performance problems when called for every conversation on mount.
- DM conversations had no read cursor tracking at all, so unread state could not be computed for direct messages.

## Architecture Decisions

### Batch query over per-conversation queries

`Chat.batch_unread_counts/1` executes exactly 2 SQL queries regardless of how many conversations the user belongs to: one for all channel counts and one for all DM counts. This avoids the N+1 problem that would arise from calling the existing `Chat.unread_count/2` per conversation. The function returns a normalized map `%{channel_counts: %{id => count}, dm_counts: %{id => count}}` that can be assigned directly to the socket as a single assign, avoiding per-conversation assigns.

### Dual-purpose read_cursors with CHECK constraint

Rather than creating a separate table for DM read cursors, the existing `read_cursors` table was extended with a nullable `dm_conversation_id` column. A CHECK constraint ensures exactly one of `channel_id` or `dm_conversation_id` is non-null per row. This keeps all read-state in a single table, simplifying the batch query (two queries against one table with different WHERE clauses) while maintaining data integrity at the database level.

### Upfront PubSub subscription for all conversations

On mount, `ChatLive.Index` subscribes to PubSub topics for ALL of the user's channels and DMs, not just the active one. This ensures no missed messages -- a lazy subscription model would miss messages arriving in conversations the user hasn't visited yet in the session. The trade-off is acceptable because user conversation count is bounded and Phoenix PubSub subscriptions are lightweight (in-process ETS lookups).

### Unread count as assign map, not per-item assigns

Unread counts are stored as a single `unread_counts` map assign on the socket rather than individual assigns per conversation. This means updating a single conversation's count triggers a single assign patch. The `SidebarComponent` receives the full map and extracts per-item counts during rendering, keeping the data flow unidirectional and the assign surface minimal.

### Active conversation suppression

Messages arriving in the currently active conversation do NOT increment the unread count. The `handle_info` callback checks whether the message's conversation matches the active one before incrementing. When the user enters a conversation, `mark_as_read` (channels) or `mark_dm_as_read` (DMs) is called and the count is reset to zero in the assign map. This prevents the badge from flickering while the user is actively reading.

## Implementation Phases

### Phase 01: Backend -- Batch Unread Query and Mark-as-Read Coverage (Steps 01-01, 01-02)

| Commit | Step | Description |
|--------|------|-------------|
| `228cdf6` | 01-01 | Migration adding `dm_conversation_id` to `read_cursors` with CHECK constraint; ReadCursor schema update; `Chat.batch_unread_counts/1` with 2-query design |
| `00ceaa4` | 01-02 | `Chat.mark_dm_as_read/2` accepting user_id and dm_conversation_id; upserts read cursor with latest message snowflake ID |

### Phase 02: LiveView UI Wiring -- Sidebar Unread Badges and Bold Styling (Steps 02-01, 02-02)

| Commit | Step | Description |
|--------|------|-------------|
| `ec6616b` | 02-01 | Mount calls `batch_unread_counts/1` once; `SidebarComponent` passes per-item count; unread badge renders when count > 0; active conversation resets to 0 |
| `ea2de60` | 02-02 | `channel_list_item` and `dm_list_item` apply `font-semibold` when `unread_count > 0`; active conversation remains bold regardless |

### Phase 03: Real-Time Updates -- PubSub-Driven Sidebar Unread Refresh (Step 03-01)

| Commit | Step | Description |
|--------|------|-------------|
| `ddbfebf` | 03-01 | Mount subscribes to all user channel and DM PubSub topics; `handle_info` increments count for non-active conversations; sidebar updates via assign patch |

### Quality Passes

| Commit | Description |
|--------|-------------|
| `31be6ec` | RPP L1-L4 refactoring: extracted `@no_cursor_message_id`, `update_unread_count/4`, `reset_unread_count/3`, `upsert_read_cursor/3`, `latest_message_id/2`, `sidebar_item_classes/2` (-11 net lines) |
| `717c50c` | Adversarial review defects D1 and D2 resolved: 4 unit tests added, component assertions standardized |

## Quality Metrics

### Test Coverage

- **Starting test count:** 644
- **Final test count:** 666 (22 new tests)
- **Failures:** 0

Test breakdown by file:
- `test/slackex/chat/unread_counts_test.exs` -- 13 tests (batch counts, mark-as-read, edge cases)
- `test/slackex_web/components/chat_components_test.exs` -- 7 tests (badge rendering, bold styling, sidebar classes)
- `test/slackex_web/live/chat_live/index_test.exs` -- 10 tests added (mount counts, PubSub increment, active suppression, entry reset)

### TDD Execution

All 5 steps followed 5-phase TDD cycles (PREPARE, RED_ACCEPTANCE, RED_UNIT, GREEN, COMMIT). Every phase across all steps reached PASS status. The execution log records 25 events (5 phases x 5 steps), all with disposition PASS, spanning 16:14 to 16:35 UTC.

### Refactoring (RPP L1-L4)

Applied Refactoring Priority Protocol across all modified files (commit `31be6ec`):
- **L1 (Critical):** Extracted `@no_cursor_message_id` constant replacing magic value
- **L2 (High):** Extracted `update_unread_count/4` and `reset_unread_count/3` reducing duplication in handle_info and enter callbacks
- **L4 (Low):** Extracted `upsert_read_cursor/3`, `latest_message_id/2`, and `sidebar_item_classes/2` for idiomatic consistency

Net result: -11 lines while improving readability and testability.

### Adversarial Review

Reviewed by `nw-software-crafter-reviewer`. Initial verdict: NEEDS_REVISION. Findings addressed in commit `717c50c`:

| ID | Severity | Description | Resolution |
|----|----------|-------------|------------|
| D1 | High | Insufficient test budget for component rendering | Added 4 unit tests to chat_components_test.exs |
| D2 | Medium | Inconsistent component assertion patterns | Standardized assertions across all component tests |

Re-review verdict: PASSED.

### Mutation Testing

Skipped -- no Elixir mutation testing tool (e.g., Muzak) configured. Compensating controls: comprehensive acceptance test coverage across all 5 steps, boundary condition tests for zero-count and no-cursor edge cases, active-conversation suppression verified through dedicated test scenarios.

### DES Integrity

All 5 steps verified through DES (Design-Execute-Seal) integrity check. Execution log confirms every step reached PASS status across all 5 TDD phases with timestamps spanning 16:14 to 16:35 UTC.

## Files Modified

### New Files

- `priv/repo/migrations/20260227161500_add_dm_conversation_id_to_read_cursors.exs` -- Migration adding `dm_conversation_id` column with CHECK constraint
- `test/slackex/chat/unread_counts_test.exs` -- 13 tests for batch unread counts and mark-as-read
- `test/slackex_web/components/chat_components_test.exs` -- 7 tests for badge rendering and bold styling

### Modified Files

- `lib/slackex/chat/read_cursor.ex` -- Added optional `dm_conversation_id` field
- `lib/slackex/chat/chat.ex` -- Added `batch_unread_counts/1`, `mark_dm_as_read/2`, extracted `upsert_read_cursor/3`
- `lib/slackex_web/live/chat_live/index.ex` -- Mount subscriptions for all conversations, `handle_info` for unread increment, extracted `update_unread_count/4` and `reset_unread_count/3`
- `lib/slackex_web/live/chat_live/sidebar_component.ex` -- Pass-through of `unread_counts` map to per-item components
- `lib/slackex_web/components/chat_components.ex` -- Conditional `font-semibold` class, extracted `sidebar_item_classes/2`, unread badge rendering
- `test/slackex_web/live/chat_live/index_test.exs` -- 10 tests added for mount counts, PubSub, active suppression

## Commits

| # | Hash | Message |
|---|------|---------|
| 1 | `228cdf6` | feat(chat): add batch unread count query for channels and DMs |
| 2 | `00ceaa4` | test(chat): add mark_dm_as_read/2 verification tests |
| 3 | `ec6616b` | feat(chat): wire unread counts into sidebar with badge rendering |
| 4 | `ea2de60` | feat(chat): bold unread conversation names in sidebar |
| 5 | `ddbfebf` | feat(unread-counts): real-time PubSub unread increment for non-active conversations |
| 6 | `31be6ec` | refactor(unread-counts): L1-L4 RPP sweep on feature files |
| 7 | `717c50c` | test(unread-counts): address review blockers D1 and D2 |

## Lessons Learned

1. **Batch queries should be the default for sidebar data.** The decision to use exactly 2 SQL queries for all unread counts (one for channels, one for DMs) avoids the N+1 trap that would surface as users join more conversations. The existing per-channel `unread_count/2` was fine for single-conversation views but would not scale to the sidebar use case. Designing the batch query from the start avoided a performance regression that would have been harder to fix after the UI was wired up.

2. **Upfront PubSub subscription is worth the trade-off for bounded conversation sets.** Subscribing to all conversations on mount rather than lazily subscribing on first message guarantees no missed unreads. The concern about subscription overhead is theoretical for this application -- Phoenix PubSub subscriptions are process-local ETS entries, and user conversation counts are naturally bounded. The alternative (lazy subscription with a periodic full-refresh fallback) would have added significant complexity for no measurable benefit.

3. **Single-map assigns simplify real-time updates.** Storing unread counts as one `%{id => count}` map rather than per-conversation assigns means updating a count is a single `Map.update` followed by one socket assign. This keeps the `handle_info` callbacks clean and avoids the combinatorial explosion of assigns that would result from tracking each conversation's state independently.

4. **CHECK constraints catch schema design errors at the database level.** The CHECK constraint on `read_cursors` ensuring exactly one of `channel_id` or `dm_conversation_id` is non-null prevents a class of bugs where a cursor could be associated with both or neither. This is cheaper than application-level validation because it is enforced on every write path, including raw SQL and future code paths that might bypass Ecto changesets.

5. **Extracting helper functions during refactoring pays off immediately.** The RPP L1-L4 sweep extracted 6 functions and reduced net lines by 11. More importantly, helpers like `sidebar_item_classes/2` and `update_unread_count/4` made the adversarial review defects (D1, D2) easier to fix because the component logic was already isolated and independently testable. Refactoring before review, not after, reduces the cost of review-driven changes.

6. **Active conversation suppression is a UX requirement, not an optimization.** Without the guard in `handle_info` that skips incrementing the active conversation's count, users would see a badge flash on the conversation they are currently reading every time a message arrives. This was identified during step 03-01 design and implemented as a first-class concern rather than a polish item. Treating it as a core requirement ensured it was tested from the start.
