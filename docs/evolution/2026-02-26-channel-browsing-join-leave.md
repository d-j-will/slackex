# Evolution: channel-browsing-join-leave

**Date:** 2026-02-26
**Status:** Complete
**Commits:** 9 (7 step commits + 1 refactoring + 1 review fix)
**Tests:** 495 passing, 0 failures

## Summary

Added channel browsing, creation, and join/leave membership management to the
Slackex chat UI. Users can create new channels via a modal form with auto-
formatted names, browse public channels they have not yet joined with search
and member counts, join channels from the browse modal or channel header, and
leave channels they are members of. All interactions update the sidebar in real
time.

## Motivation

The existing chat interface supported viewing and messaging within channels but
lacked self-service channel management. Users could not discover available
channels, create new ones, or manage their own membership. These capabilities
are fundamental to a multi-channel chat platform and were required before
scaling beyond a small set of pre-seeded channels.

## Implementation Phases

### Phase 1 -- Backend Extensions and Route Wiring (Steps 01-01, 01-02)

**01-01: Add count_members/1 and enhance list_public_channels/1**
Extended the Chat context with `count_members/1` returning the integer member
count for a channel, and added an `exclude_member` option to
`list_public_channels/1` so it filters out channels the given user already
belongs to. Private channels are never returned. Backward compatible -- calling
with no options returns all public channels.

- Commit: `b9fa002`

**01-02: Add channel creation, browse, and join/leave routes**
Added `/chat/channels/new` (`:create_channel`) and `/chat/channels/browse`
(`:browse_channels`) routes. Both are declared before the `/chat/:slug`
catch-all to prevent slug conflicts. Wired `handle_params` clauses for new
actions in the Index LiveView.

- Commit: `5b58baa`

### Phase 2 -- Channel Creation (Steps 02-01, 02-02)

**02-01: CreateChannelModal LiveComponent**
Built `create_channel_modal.ex` with a form containing name (auto-formats to
lowercase-hyphens on change), description, and `is_private` toggle. Validates
on change, submits on save. On success sends `{:channel_created, channel}` to
parent. Closes via `push_patch` to `/chat`.

- Commit: `21a7aee`

**02-02: Wire CreateChannelModal into Index and sidebar**
Mounted the CreateChannelModal when `live_action` is `:create_channel`. Handled
`{:channel_created, channel}` in Index to refresh the sidebar channel list and
navigate to the new channel. Added a "+" button in the sidebar channels section
linking to `/chat/channels/new`.

- Commit: `52849a4`

### Phase 3 -- Channel Browsing and Membership Actions (Steps 03-01, 03-02, 03-03)

**03-01: BrowseChannelsModal LiveComponent**
Built `browse_channels_modal.ex` listing public channels the user has not
joined. Each entry shows name, description, member count, and a Join button.
Search input filters channels by name (case-insensitive). On join sends
`{:channel_joined, channel}` to parent.

- Commit: `7296227`

**03-02: Wire BrowseChannelsModal into Index and sidebar**
Mounted the BrowseChannelsModal when `live_action` is `:browse_channels`.
Handled `{:channel_joined, channel}` in Index to refresh the sidebar and
navigate to the joined channel. Added a "Browse" link in the sidebar channels
section linking to `/chat/channels/browse`.

- Commit: `cb53135`

**03-03: Channel header Join and Leave buttons**
Extended the channel header to show membership actions: "Join Channel" for
non-members viewing a public channel, "Leave Channel" for members who are not
the owner, hidden for owners. Handled `join_channel` and `leave_channel` events
in Index, refreshing the sidebar accordingly. Leaving navigates to `/chat`.

- Commit: `c83d691`

### Post-Implementation

**Refactoring (L1-L4):** Applied a systematic sweep across all feature files.

- L1 (Dead code): Removed identity case clause in `Chat.join_channel/2`,
  dead `{:sidebar_action, _}` placeholder handler, duplicate `String.to_integer`
  call, and stale moduledoc in SidebarComponent.
- L2 (Naming): Renamed shadowed `channel_id` to `raw_id` in BrowseChannelsModal.
- L3 (Structure): Extracted `enter_modal/2` helper deduplicating three identical
  `handle_params` clauses. Extracted `refresh_channels_and_navigate/2` helper
  deduplicating `:channel_created` and `:channel_joined` handlers. Extracted
  `maybe_exclude_member/2` and `with_member_count/1` pipeline helpers in Chat.
  Extracted `normalize_channel_params/1` in CreateChannelModal.
- L4 (Formatting): Auto-formatted all feature files via `mix format`.
- Net result: -7 lines removed through deduplication and cleanup.
- Commit: `431ae75`

**Adversarial review:** APPROVED after 1 revision. Five findings addressed:

- D1: Replaced N+1 query in `list_public_channels` with a single batched
  subquery joining member counts by `channel_id` in one pass.
- T2: Added DB state assertion to browse channels join test (verifying
  subscription persistence via `Chat.get_role/2`).
- T3: Improved leave test sidebar isolation by asserting against the `<aside>`
  element rather than full page HTML.
- T4: Added case-insensitive search filter test (uppercase "DEV" matching
  "dev-talk").
- T5: Strengthened create channel validation test to verify no channel record
  persisted on failure.
- Commit: `7e6494a`

**Mutation testing:** Skipped -- no Elixir mutation testing tool available.

## Architecture Decisions

### LiveComponent modals for channel creation and browsing
Both CreateChannelModal and BrowseChannelsModal were implemented as LiveComponents
rather than inline in the parent LiveView. This isolates form state, search
state, and validation errors from the parent's assigns. The pattern mirrors
NewDmModal from the dm-conversations-ui feature, establishing a consistent modal
architecture across the application.

### Message-based parent-child communication
Modals communicate results to the parent via `send(self(), {:channel_created, channel})`
and `send(self(), {:channel_joined, channel})`. This decouples modal logic from
the parent's implementation details and allows the parent to handle sidebar
refresh and navigation uniformly through `refresh_channels_and_navigate/2`.

### Route ordering to prevent slug conflicts
The `/chat/channels/new` and `/chat/channels/browse` routes are declared before
the `/chat/:slug` catch-all. This follows the same pattern established for DM
routes (`/chat/dm/new`, `/chat/dm/:dm_id`) and prevents "channels" from being
interpreted as a channel slug.

### Batched member count query (post-review)
The initial implementation used per-channel `count_members/1` calls, creating an
N+1 query pattern. The adversarial review identified this, and it was replaced
with a single subquery that groups and counts memberships by `channel_id`,
joining the results in one database pass.

### Role-based header action visibility
Channel header actions use `Chat.get_role/2` to determine visibility: owners see
no action button (preventing accidental orphaning), members see "Leave Channel",
and non-members viewing public channels see "Join Channel". This keeps
authorization logic in the context layer rather than the template.

## Quality Metrics

| Metric                | Value                          |
|-----------------------|--------------------------------|
| Total tests           | 495 passing, 0 failures        |
| TDD steps             | 7 of 7 complete                |
| Phases                | 3 of 3 complete                |
| Refactoring delta     | -7 net lines                   |
| Commits               | 9 (7 steps + 1 refactoring + 1 review fix) |
| Adversarial review    | APPROVED after 1 revision (5 findings fixed) |
| Mutation testing      | Skipped (no tooling available) |

## Files Created and Modified

**Created:**
- `lib/slackex_web/live/chat_live/create_channel_modal.ex` -- CreateChannelModal LiveComponent
- `lib/slackex_web/live/chat_live/browse_channels_modal.ex` -- BrowseChannelsModal LiveComponent
- `test/slackex_web/live/chat_live/channel_routes_test.exs` -- Channel route resolution tests

**Modified:**
- `lib/slackex/chat/chat.ex` -- count_members/1, list_public_channels/1 with exclude_member, batched member count query
- `lib/slackex_web/live/chat_live/index.ex` -- Modal mounting, handle_params, join/leave event handlers, extracted helpers
- `lib/slackex_web/live/chat_live/sidebar_component.ex` -- "+" button, "Browse" link in channels section
- `lib/slackex_web/components/chat_components.ex` -- Join/Leave button in channel header
- `lib/slackex_web/router.ex` -- /chat/channels/new and /chat/channels/browse routes
- `test/slackex/chat_test.exs` -- count_members and list_public_channels tests
- `test/slackex_web/live/chat_live_test.exs` -- Channel creation, browsing, join/leave UI tests

## Key Patterns Established

1. **Modal LiveComponent pattern.** CreateChannelModal and BrowseChannelsModal
   follow the same structure as NewDmModal: isolated state, message-based parent
   communication, backdrop/escape close, `push_patch`-based dismissal. This is
   now the standard pattern for modal interactions in the chat interface.

2. **Sidebar wiring pattern.** Both "+" (create) and "Browse" links follow the
   established pattern of sidebar actions linking to live routes that trigger
   modal rendering via `live_action` matching.

3. **Header action pattern.** Role-based conditional rendering in the channel
   header (join/leave/hidden based on `get_role/2`) provides a reusable approach
   for future membership-related actions.

4. **Extracted deduplication helpers.** `enter_modal/2` and
   `refresh_channels_and_navigate/2` in the Index LiveView reduce boilerplate
   for future modal and channel-action flows.

## Lessons Learned

1. **N+1 queries hide behind simple abstractions.** The initial `count_members/1`
   per-channel call looked clean but created a query-per-row pattern. Batching
   member counts into the listing query eliminated the N+1 at the cost of a
   slightly more complex query, but with significantly better performance
   characteristics. Query patterns should be reviewed even when individual
   functions look correct in isolation.

2. **Modal pattern convergence accelerates delivery.** Because the
   CreateChannelModal and BrowseChannelsModal followed the same structural
   pattern as NewDmModal, steps 02-01 and 03-01 were executed in parallel. A
   consistent component architecture enables parallel work.

3. **Test isolation matters for sidebar assertions.** Asserting against the full
   page HTML for sidebar state can produce false positives when channel names
   appear elsewhere in the page. Scoping assertions to the `<aside>` element
   (T3 review finding) is more precise and resilient.

4. **Auto-formatting input fields should be tested for edge cases.** The channel
   name auto-formatter (lowercase-hyphens) combined with case-insensitive
   search (T4) requires tests at both layers to prevent mismatches.

5. **Role-based visibility needs explicit negative tests.** The adversarial
   review confirmed that testing what users should NOT see (owner should not see
   Leave button) is as important as testing what they should see.

## Timeline

- **23:25** -- Phase 1 started (01-01 count_members and list_public_channels)
- **23:30** -- Phase 1 complete (01-02 routes)
- **23:32** -- Phase 2 started (02-01 CreateChannelModal) -- parallel with 03-01
- **23:33** -- Phase 3 started (03-01 BrowseChannelsModal) -- parallel with 02-01
- **23:38** -- 02-01 and 03-01 complete
- **23:41** -- 02-02 complete (sidebar wiring for creation)
- **23:43** -- 03-02 complete (sidebar wiring for browsing)
- **23:47** -- 03-03 complete (header join/leave buttons)
- **23:52** -- Refactoring commit (L1-L4, -7 net lines)
- **23:59** -- Adversarial review fix commit (D1, T2-T5)
- **23:59** -- Feature complete, all 495 tests passing
