# Evolution: dm-conversations-ui

**Date:** 2026-02-26
**Status:** Complete
**Commits:** 10 (9 step commits + 1 refactoring commit)
**Tests:** 451 passing, 0 failures

## Summary

Added Direct Message (DM) conversations to the Slackex chat UI. Users can search
for other users via trigram-powered typeahead, initiate one-on-one conversations,
send and receive messages in real time, and see typing indicators -- all within
the existing ChatLive interface.

## Motivation

The channel-based messaging system was functional but lacked private one-to-one
communication. DM support is a baseline expectation for any chat application and
was required to bring Slackex closer to feature parity with production chat
platforms.

## Implementation Phases

### Phase 1 -- Database and Backend (Steps 01-01 through 01-03)

**01-01: Trigram extension and indexes migration**
Created a migration enabling the `pg_trgm` PostgreSQL extension and adding GiST
trigram indexes on `users.username` and `users.display_name`. GiST was chosen
over GIN to support KNN-ordered similarity ranking for typeahead results.

**01-02: Trigram user search in Accounts context**
Added `Accounts.search_users/2` using the pg_trgm `%` similarity operator via
Ecto fragment. Enforces a minimum 2-character query length (returns empty list
without hitting the database for shorter queries). Excludes specified user IDs
from results.

**01-03: DM conversation listing with preloaded other user**
Added `Chat.list_user_dm_conversations/1` returning DM conversations for a user
with the other participant preloaded. Resolves "other user" based on which side
of `user_a_id`/`user_b_id` the caller occupies. Ordered by most recent activity.

### Phase 2 -- Routing and Navigation (Steps 02-01 through 02-02)

**02-01: DM routes and unsubscribe helper**
Added `/chat/dm/new` (`:new_dm` action) and `/chat/dm/:dm_id` (`:dm` action)
routes within the existing `:chat` live session scope. Literal `/chat/dm/*`
routes declared before the slug `/chat/:slug` route to prevent conflicts. Added
`Messaging.unsubscribe_dm/1` and a generalized `leave_conversation/1` helper
that handles both channel and DM unsubscription.

**02-02: DM mount loading and handle_params**
Extended mount to load `@dm_conversations`. Added `handle_params` clause for the
`:dm` action that verifies the current user is a participant, subscribes to the
DM PubSub topic, loads messages, and resets the stream. Non-participants receive
a flash error and redirect. The `enter_dm` pattern mirrors the existing
`enter_channel` pattern.

### Phase 3 -- UI Components and Integration (Steps 03-01 through 03-04)

**03-01: Sidebar DM list rendering**
Passed `@dm_conversations` to `SidebarComponent`. Rendered DM entries below the
channels section under a collapsible "Direct Messages" header with a "New
Message" button. Each entry shows the other user's avatar and display name.
Active DM is highlighted. All navigation uses `push_patch`.

**03-02: New DM modal LiveComponent**
Created `NewDmModal` LiveComponent with a debounced (300ms) user search input.
The component manages its own `@search_query` and `@search_results` state.
Selecting a user sends `{:start_dm, user_id}` to the parent. Modal closes on
backdrop click or escape.

**03-03: Start DM flow and DM message sending**
Handled `{:start_dm, user_id}` in Index by calling `Chat.find_or_create_dm/2`,
updating `@dm_conversations`, and patching to the new DM. Wired `send_message`
to dispatch to `Messaging.send_dm/4` when the active conversation is a DM.
Incoming DM messages arrive in real time via PubSub stream insert.

**03-04: DM typing indicator and load-more pagination**
Extended the typing event to broadcast on the `dm:ID` PubSub topic when in DM
view. Extended `load_more` to paginate DM messages using `Chat.list_dm_messages/2`
with a `:before` cursor. Reuses existing `prepend_older_messages/2` helper and
typing broadcast pattern.

### Post-Implementation

**Refactoring (L1-L4):** Extracted shared helpers (`handle_send_result`,
`broadcast_typing`, `load_older_messages`, template components) from the Index
LiveView. Net result: -58 lines removed through deduplication.

**Adversarial review:** APPROVED with zero blocking issues.

**Mutation testing:** Skipped -- no Elixir mutation testing tool available.

**Integrity verification:** All 9 steps verified complete against roadmap criteria.

## Architecture Decisions

### pg_trgm with GiST indexes (not GIN)
GiST indexes were selected over GIN because user search requires KNN-ordered
similarity ranking for typeahead results. GIN indexes are faster for containment
queries but do not support the distance-ordered results needed for "best match
first" typeahead behavior.

### PubSub dual-topic pattern (channel vs DM)
DM messages use the same `{:envelope, %{event: "message.new"}}` format as
channel messages but broadcast on `dm:ID` topics instead of `channel:ID` topics.
This allows identical message rendering logic while keeping subscription scopes
separate. The `leave_conversation/1` helper generalizes unsubscription across
both conversation types.

### LiveComponent modal for NewDmModal
The new DM modal was implemented as a LiveComponent rather than inline in the
parent LiveView. This isolates the search state (`@search_query`,
`@search_results`) from the parent's assigns, prevents unnecessary re-renders of
the chat view during search, and provides a clean lifecycle (mount/update/unmount)
for the modal interaction.

### Unit test skipping for UI integration steps
Steps 03-02, 03-03, and 03-04 skipped the RED_UNIT phase with documented
justification: LiveComponent and LiveView event handler wiring is covered
adequately through acceptance tests that drive the full interaction through the
parent LiveView. Separate unit tests would duplicate coverage and test internal
implementation details.

## Quality Metrics

| Metric                | Value                          |
|-----------------------|--------------------------------|
| Total tests           | 451 passing, 0 failures        |
| TDD steps             | 9 of 9 complete                |
| Phases                | 3 of 3 complete                |
| Refactoring delta     | -58 net lines                  |
| Commits               | 10 (9 steps + 1 refactoring)   |
| Adversarial review    | APPROVED, 0 blocking issues    |
| Mutation testing      | Skipped (no tooling available) |

## Files Modified and Created

**Created:**
- `lib/slackex_web/live/chat_live/new_dm_modal.ex` -- NewDmModal LiveComponent
- `priv/repo/migrations/*_add_trigram_indexes.exs` -- pg_trgm migration
- `test/slackex/trigram_indexes_test.exs` -- Trigram index verification tests

**Modified:**
- `lib/slackex_web/live/chat_live/index.ex` -- DM mount, handle_params, event handlers
- `lib/slackex_web/live/chat_live/sidebar_component.ex` -- DM list rendering
- `lib/slackex_web/components/chat_components.ex` -- Shared template components
- `lib/slackex_web/router.ex` -- DM routes
- `lib/slackex/accounts/accounts.ex` -- search_users/2
- `lib/slackex/chat/chat.ex` -- list_user_dm_conversations/1
- `lib/slackex/messaging/messaging.ex` -- unsubscribe_dm/1, send_dm/4
- `test/slackex/accounts_test.exs` -- Trigram search tests
- `test/slackex/chat_test.exs` -- DM conversation listing tests
- `test/slackex_web/live/chat_live_test.exs` -- DM UI integration tests

## Lessons Learned

1. **GiST vs GIN is a query-shape decision.** For typeahead (similarity-ranked
   results), GiST is correct. For exact trigram containment, GIN would be faster.
   Document the query pattern driving the index choice.

2. **Generalizing cleanup helpers early pays off.** Extracting `leave_conversation/1`
   during step 02-01 (before the UI steps) avoided duplicating channel/DM
   unsubscription logic across multiple event handlers.

3. **LiveComponent isolation simplifies state management.** Keeping modal search
   state in `NewDmModal` prevented polluting the parent LiveView's assigns and
   eliminated a class of re-render bugs.

4. **Acceptance tests at the LiveView boundary are sufficient for UI wiring.**
   Steps that only wire events between existing components do not benefit from
   separate unit tests. The RED_UNIT skip with documented justification is a
   reasonable trade-off.

5. **Dual-topic PubSub with a shared envelope format enables code reuse.**
   Channel and DM message rendering share the same components because the message
   format is identical -- only the topic changes.

## Timeline

- **16:01** -- Phase 1 started (01-01 trigram migration)
- **16:17** -- Phase 1 complete (01-03 DM listing)
- **16:24** -- Phase 2 started (02-01 routes)
- **16:35** -- Phase 2 complete (02-02 mount/handle_params)
- **16:38** -- Phase 3 started (03-01 sidebar)
- **17:01** -- Phase 3 complete (03-04 typing/pagination)
- **17:12** -- Refactoring commit (L1-L4, -58 net lines)
- **17:12** -- Feature complete, all 451 tests passing
