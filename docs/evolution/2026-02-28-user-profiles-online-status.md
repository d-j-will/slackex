# User Profiles and Online Status: Feature Evolution

**Date:** 2026-02-28
**Status:** Complete
**Project ID:** user-profiles-online-status
**Test Count:** 783 (0 failures)
**Duration:** ~15 minutes (01:38 - 01:53 UTC on 2026-02-28)

## Summary

Online presence tracking and user profile system for the Slackex messaging application. The feature adds real-time online/offline status indicators to the sidebar DM list, a profile card popover for viewing user details, and an edit profile modal for updating display name and status. Online status is backed by Redis bulk queries with graceful degradation, propagated in real-time via PubSub presence broadcasts, and stored as a MapSet for O(1) membership checks. Profile updates are broadcast to all connected LiveViews so display names and statuses refresh without page reload.

## Motivation

- Users had no way to see which contacts were currently online, making it difficult to know when to expect timely responses.
- No user profile system existed -- display names and status messages were not supported, limiting personalization.
- The existing `OnlineTracker` only supported single-user checks via `online?/1`, requiring N Redis round-trips to check N users. A bulk query was needed for sidebar rendering performance.
- Real-time presence updates were not propagated -- a user going online or offline required a page refresh for others to see the change.

## Architecture Decisions

### Global PubSub presence topic over per-user topics

A single global topic (`presence:online`) was chosen over per-user topics (e.g., `presence:{user_id}`). With per-user topics, each LiveView would need N subscriptions for N contacts, and the subscription count would scale with the contact graph. The global topic requires one subscription per LiveView, bounded by total concurrent users rather than contact relationships. This is simpler and sufficient at current scale. If broadcast volume grows, the topic can be partitioned by user-id hash without changing the subscription model.

### MapSet for online_user_ids

Online user IDs are stored as a `MapSet` assign in each LiveView. MapSet provides O(1) membership checks for sidebar rendering (each DM list item checks if its user is online). PubSub presence diffs are applied via `MapSet.put/2` and `MapSet.delete/2`, which are efficient incremental updates. The alternative -- a list with `Enum.member?/2` -- would be O(n) per check, which matters when the DM list has dozens of entries.

### Redis MGET for bulk online queries

`OnlineTracker.online_user_ids/1` uses a single Redis `MGET` command to check multiple user IDs in one round-trip, rather than N individual `GET` commands. This reduces Redis latency from O(n) to O(1) network round-trips on mount. The function returns an empty MapSet on Redis connection failure, ensuring the UI renders without online indicators rather than blocking or crashing.

### Profile card as function component (not LiveComponent)

The profile card (`user_profile_card/1`) is implemented as a stateless function component in `chat_components.ex` rather than a stateful LiveComponent. The parent LiveView manages the `profile_user` assign and open/close state. This is simpler because the profile card has no independent state or lifecycle -- it only displays data passed to it. A LiveComponent would add unnecessary complexity for a component that does not need to manage its own assigns or handle its own events.

### Profile update broadcast via dedicated PubSub topic

Profile changes (display name, status) are broadcast on a `profile:updates` topic so all connected LiveViews can refresh displayed names and statuses without page reload. This is a separate topic from `presence:online` because profile updates and presence changes have different payloads and different consumer logic.

## Implementation Phases

### Phase 01: Online Status Infrastructure and Sidebar Integration (Steps 01-01 through 01-02)

| Commit | Step | Description |
|--------|------|-------------|
| `7c6fd8d` | 01-01 | Bulk online query via Redis MGET (`OnlineTracker.online_user_ids/1`), profile changeset with display_name/status validation, `Accounts.get_user/1` and `update_user_profile/2`, ChatLive mount queries online IDs, sidebar DM list shows green online dots |
| `95e4b6f` | 01-02 | Global `presence:online` PubSub topic, mount broadcasts online and terminate broadcasts offline, connected LiveViews handle presence diffs and update `online_user_ids` MapSet in real-time |

### Phase 02: User Profile UI (Steps 02-01 through 02-02)

| Commit | Step | Description |
|--------|------|-------------|
| `529aad3` | 02-01 | `user_profile_card/1` function component, avatar/username click opens profile card showing display_name, @username, status, online indicator, "Send Message" navigates to DM (hidden for own profile), closes on Escape or click outside |
| `a2eaa86` | 02-02 | Edit/settings button in sidebar user footer, `edit_profile_modal/1` with form for display_name and status, saves via `Accounts.update_user_profile/2`, inline validation, broadcasts profile update via `profile:updates` PubSub topic |

### Quality Passes

| Commit | Description |
|--------|-------------|
| `bf3d810` | RPP L1-L4 refactoring: extracted `redis_command/2` helper, unified `dm_other_user`, shared `display_name/1` helper |
| (in-session) | Adversarial review: fixed Testing Theater patterns (D1-D3), wired `profile:updates` handler (D4) |

## Quality Metrics

### Test Coverage

- **Starting test count:** 748
- **New tests added:** 35
- **Final test count:** 783
- **Failures:** 0

### TDD Execution

All 4 steps followed 5-phase TDD cycles (PREPARE, RED_ACCEPTANCE, RED_UNIT, GREEN, COMMIT). Every phase across all steps reached PASS status, with three justified skips: steps 01-02, 02-01, and 02-02 RED_UNIT phases were marked NOT_APPLICABLE because acceptance tests cover the behaviors through the LiveView driving port (PubSub subscription handling, profile card interactions, and edit modal form submission are integration-level concerns). The execution log records 20 events across all steps.

### Refactoring (RPP L1-L4)

Applied Refactoring Priority Protocol to modified files (commit `bf3d810`):
- **L1 (Critical):** Extracted `redis_command/2` helper to eliminate duplicated Redis error handling
- **L2 (High):** Unified `dm_other_user` logic across sidebar and profile card contexts
- **L3 (Medium):** Shared `display_name/1` helper for consistent display name fallback logic
- **L4 (Low):** Idiomatic patterns, consistency

### Adversarial Review

Reviewed by `nw-software-crafter-reviewer`. Four defects found and addressed:

| ID | Severity | Description | Resolution |
|----|----------|-------------|------------|
| D1 | Medium | Testing Theater: test asserted implementation detail rather than observable behavior | Rewrote to assert user-visible outcome |
| D2 | Medium | Testing Theater: redundant test duplicated coverage from another test | Removed duplicate, strengthened remaining test |
| D3 | Medium | Testing Theater: mock-heavy test did not exercise real code path | Replaced with integration-level assertion |
| D4 | High | `profile:updates` PubSub handler not wired in ChatLive `handle_info` | Added handler to update profile data in connected LiveViews |

### Roadmap Validation

Roadmap was validated by `nw-software-crafter-reviewer` before execution. All 4 steps had complete acceptance criteria, file modification lists, and dependency declarations. Phase dependencies (`02` depends on `01`) were correctly specified.

### Mutation Testing

Skipped -- no Elixir mutation testing tool configured. Compensating controls: comprehensive acceptance test coverage across all 4 steps, Redis MGET success/failure/empty-list tests, PubSub presence broadcast and receive tests, profile card open/close/navigation tests, edit modal validation and save tests.

### DES Integrity

All 4 steps verified through DES (Design-Execute-Seal) integrity check. Execution log confirms every step reached PASS status across all TDD phases with timestamps spanning 01:38 to 01:53 UTC.

## Files Modified

### Modified Files

- `lib/slackex/notifications/online_tracker.ex` -- Added `online_user_ids/1` bulk MGET query returning MapSet, graceful degradation on Redis failure
- `lib/slackex/accounts/user.ex` -- Added `profile_changeset/2` validating display_name (max 50) and status (max 100)
- `lib/slackex/accounts/accounts.ex` -- Added `get_user/1` and `update_user_profile/2` context functions
- `lib/slackex_web/live/chat_live/index.ex` -- Mount queries online IDs, subscribes to `presence:online` and `profile:updates` topics, broadcasts presence on connect/disconnect, handles presence diffs and profile updates
- `lib/slackex_web/live/chat_live/sidebar_component.ex` -- Receives `online_user_ids`, renders green online dot on DM list items and user footer, click handlers for profile card, edit profile button in footer
- `lib/slackex_web/components/chat_components.ex` -- Added `user_profile_card/1` and `edit_profile_modal/1` function components
- `test/slackex/notifications/online_tracker_test.exs` -- Bulk query tests (success, empty list, Redis failure)
- `test/slackex/accounts_test.exs` -- Profile changeset and update_user_profile tests
- `test/slackex_web/live/chat_live_test.exs` -- Online indicator, presence broadcast, profile card, edit modal tests

## Commit History (oldest to newest)

| Commit | Message |
|--------|---------|
| `7c6fd8d` | feat(profiles): add bulk online query, profile changeset, and sidebar online indicators |
| `95e4b6f` | feat(profiles): add real-time presence broadcasts via PubSub |
| `529aad3` | feat(profiles): add user profile popover on avatar/username click |
| `a2eaa86` | feat(profiles): add edit own profile from sidebar footer |
| `bf3d810` | refactor(profiles): apply L1-L4 RPP sweep on profile and presence files |

## Lessons Learned

1. **Global PubSub topics simplify presence at the cost of broadcast fan-out.** A single `presence:online` topic means every connected LiveView receives every presence change, even for users not in their DM list. At current scale (tens of concurrent users) this is negligible. The alternative -- per-user topics with N subscriptions per LiveView -- would reduce message volume per subscriber but increase subscription management complexity. The global topic keeps the implementation simple and can be partitioned later if needed. The key metric to watch is PubSub message volume per second; if it exceeds the threshold where LiveView `handle_info` processing becomes a bottleneck, partition by user-id hash.

2. **MapSet assigns are efficient for membership-driven rendering.** The sidebar renders a green dot for each online DM contact by checking `MapSet.member?(online_user_ids, user_id)`. This O(1) check scales well as the DM list grows. The incremental update pattern -- `MapSet.put` on online broadcast, `MapSet.delete` on offline broadcast -- avoids re-querying Redis on every presence change. The only full query happens on mount, which is the correct trade-off between freshness and load.

3. **Graceful degradation on Redis failure prevents cascading UI failures.** `OnlineTracker.online_user_ids/1` returns an empty MapSet when Redis is unavailable, which means the sidebar renders without online indicators rather than crashing. This pattern -- returning a safe default on infrastructure failure rather than propagating the error -- is critical for features that enhance the UI but are not essential for core functionality. Online status is informational; message delivery is not blocked by its absence.

4. **Function components are the right choice for display-only UI elements.** The profile card and edit modal are implemented as function components rather than LiveComponents. They have no independent state -- the parent LiveView manages `profile_user` and `show_edit_profile` assigns. This simplifies the component lifecycle and avoids the overhead of LiveComponent's `update/2` and `handle_event/3` callbacks for components that only need to render props. The rule of thumb: use LiveComponent when the component needs its own state or event handling; use function components for everything else.

5. **Separate PubSub topics for separate concerns prevent handler confusion.** Presence changes (`presence:online`) and profile updates (`profile:updates`) use separate topics even though both affect the sidebar display. This separation means each `handle_info` clause handles exactly one concern with a clear payload shape. Combining them on a single topic would require pattern matching on message type within a shared handler, which is harder to test and reason about. The adversarial review caught a missing `profile:updates` handler (D4), which reinforces that each topic subscription should have an explicit handler wired in the LiveView.
