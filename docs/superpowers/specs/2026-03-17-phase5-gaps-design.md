# Phase 5 Gaps: Message Grouping, Loading Skeletons, Test Gap Remediation

**Date:** 2026-03-17
**Scope:** Three independent improvements to close remaining Phase 5 gaps

## Context

Phase 5 Steps 6-10 are fully implemented (reactions, threads, pins, invites, quick switcher). Three polish/infrastructure gaps remain: message grouping, link preview loading skeleton, and test gap remediation. These are independent and can be built in any order.

## 1. Message Grouping

### Problem

Every message renders with full avatar, sender name, and timestamp — even consecutive messages from the same sender seconds apart. This wastes vertical space and makes conversations harder to scan.

### Design

**Grouping rule:** A message is "grouped" (compact) when:
- Same `sender_id` as the previous message
- Within 5 minutes of the previous message's `inserted_at`
- Previous message is not deleted (`deleted_at` is nil)
- Neither message is a system/thread-reply-indicator message

**Stream compatibility:** Phoenix LiveView streams do not maintain a server-side list after initial assignment. The grouping approach must account for this:

- **Initial load:** A pure function `annotate_grouping/1` takes the message list returned by `fetch_messages_for_entry/2` and annotates each message with a `:grouped` boolean before passing the list to `stream/4` in `assign_conversation_state/2`.

- **Incoming messages (PubSub):** Maintain a `@last_message` assign on the socket, updated on every stream insert. When a new message arrives, compare its `sender_id` and `inserted_at` against `@last_message` to determine grouping. Set the `:grouped` field on the incoming message struct before inserting into the stream. Update `@last_message` to the new message. Initialize `@last_message` to `List.last(messages)` in `assign_conversation_state/2` (or `nil` for empty conversations). Reset it on every channel/DM switch.

- **Message deletion:** When a message is deleted (soft-delete), if it equals `@last_message`, the next incoming message cannot reliably determine grouping server-side (the predecessor is unknown). Solution: set `grouped: false` on any message arriving after a deletion, which is the safe default (shows full avatar/name). This is a minor visual imperfection that self-corrects on next page load.

- **Message editing:** Editing doesn't change `sender_id` or `inserted_at`. The `stream_insert` for edits must preserve the existing `:grouped` value from the message struct, not recalculate it.

- **Pagination (prepending older messages):** When `prepend_older_messages` loads an older batch, run `annotate_grouping/1` on the batch. The boundary between the oldest currently-displayed message and the newest prepended message is handled by comparing the first displayed message against the last prepended message — if they should be grouped, re-insert the first displayed message with `grouped: true`.

**Virtual fields for annotations:** Add `field :grouped, :boolean, virtual: true, default: false`, `field :show_divider, :boolean, virtual: true, default: false`, and `field :divider_label, :string, virtual: true` to the `Message` schema. This keeps annotations type-safe and avoids bare `Map.put` on Ecto structs.

**Compact rendering:** `message_bubble/1` receives a `grouped` attr (default `false`). When `true`:
- Avatar replaced with same-width empty `<div>` (alignment preserved)
- Sender name hidden
- Full timestamp hidden — small timestamp appears on row hover (CSS `group-hover`)
- Reduced top margin (`mt-0.5` instead of `mt-3`)

The `grouped` attr is threaded through `message_stream/1` (the caller of `message_bubble/1`).

**Time dividers:** When there's a gap of 30+ minutes between consecutive messages, a visual divider is rendered. Time dividers are NOT stream items — they are rendered via **template logic** in `message_stream/1`. Each message carries a `:show_divider` boolean and `:divider_label` string (e.g., "Today at 14:30"), set during `annotate_grouping/1` (initial load) or by comparing against `@last_message` (incoming messages).

The `message_stream/1` template conditionally renders a `time_divider/1` component before any message with `show_divider: true`. This avoids mixing heterogeneous types in the stream.

Divider label format:
- Same day: "Today at 14:30"
- Yesterday: "Yesterday at 09:15"
- Older: "March 15 at 14:30"

Timezone: labels use the server's timezone (UTC). A future enhancement could pass user timezone via socket assigns, but this is out of scope.

**Thread panel:** `ThreadPanelComponent` renders replies from a list (not a stream), so `annotate_grouping/1` works directly. Apply the same grouping rules to thread replies.

### Files Changed

- `lib/slackex/chat/message.ex` — add virtual fields: `grouped`, `show_divider`, `divider_label`
- `lib/slackex_web/components/chat_components.ex` — add `grouped` and `show_divider`/`divider_label` attrs to `message_bubble/1`, add `time_divider/1` component, thread `grouped` through `message_stream/1`
- `lib/slackex_web/live/chat_live/index.ex` — `annotate_grouping/1` pure function, `@last_message` assign, update `assign_conversation_state/2` and PubSub handlers, update `prepend_older_messages`
- `lib/slackex_web/live/chat_live/thread_panel_component.ex` — apply `annotate_grouping/1` to thread replies

### Testing

- Unit test `annotate_grouping/1`: same sender within 5 min → grouped, different sender → not grouped, >5 min gap → not grouped, deleted previous → not grouped, 30+ min gap → `show_divider: true` with correct label
- LiveView test: send two messages from same user quickly, assert compact rendering (no duplicate avatar)

## 2. Loading Skeletons

### Problem

Link previews have a genuinely async loading cycle (message sent → Oban job fetches metadata → PubSub broadcasts result). During the `pending` state, nothing is rendered. A skeleton placeholder would indicate that a preview is loading.

### Design

**Scope decision:** All data loading in `index.ex`, modals, and thread panel is synchronous (loaded in `handle_params` / `update` callbacks). Adding skeletons there would require making loading async, which adds complexity and makes the app feel slower (two render cycles instead of one). Since loading is fast, skeletons would flash invisibly. **Skeletons are only added where async loading already exists.**

Existing spinners for search and summarization remain unchanged — they're appropriate for action-triggered feedback.

**Data flow change:** Currently, `list_previews_for_messages/1` in `lib/slackex/links/links.ex` filters to `status == "fetched"`, so pending previews never reach the template. Modify the query to also load previews with `status == "pending"`. This way, when a message is sent with a URL and the `LinkPreview` record is created with `status: "pending"`, the next render includes it.

Note: status values are strings (`"pending"`, `"fetched"`, `"blocked"`), not atoms.

**Link preview skeleton:** The `link_preview_card/1` component gains a branch on the preview's `status` field:
- `"pending"` → render a compact skeleton card: title bar placeholder, description bar placeholder, small image area placeholder. Uses daisyUI `skeleton animate-pulse` classes.
- `"fetched"` → render the full preview card (existing behavior)
- `"blocked"` → render nothing (existing behavior)

When the Oban job completes and broadcasts the fetched preview, the existing `link_previews_ready` PubSub handler updates `@link_previews`, replacing the pending skeleton with the real card.

**Future-proofing:** If channel/DM loading becomes async in the future (e.g., for channels with thousands of messages), a `message_skeleton/1` component can be added at that point. The component is trivial to build when needed — no premature abstraction.

### Files Changed

- `lib/slackex/links/links.ex` — modify `list_previews_for_messages/1` to include `"pending"` status
- `lib/slackex_web/components/chat_components.ex` — add pending state branch to `link_preview_card/1` with skeleton placeholder

### Testing

- Component test: render `link_preview_card/1` with `status: :pending`, assert skeleton elements present
- Component test: render with `status: :fetched`, assert real preview content present

## 3. Test Gap Remediation

### Problem

Contract tests exist but aren't separately visible in CI. No E2E tests verify full user flows across multiple LiveView sessions. Two critical integration paths (link preview pipeline, thread dual broadcast) lack wiring tests despite the project's CLAUDE.md mandate.

### Design

**Part A: Contract test tagging + CI step**

The existing `envelope_contract_test.exs` already uses `@describetag :contract` on individual describe blocks (lines 21, 71, 111, 144). This is sufficient for `mix test --only contract` to find them. No `@moduletag` addition needed.

Action items:
- Fix the incorrect moduledoc in `envelope_contract_test.exs` that claims contract tests are "excluded from the default test run" — they are NOT excluded (`:contract` is not in `test_helper.exs` exclude list). Update the moduledoc to reflect reality.
- Survey other test files for contract-like tests (asserting on wire format, metric names, external API shapes) and add `@describetag :contract` where appropriate.
- Add a dedicated CI step for visibility.

**Part B: E2E tests**

New file: `test/slackex_web/live/chat_live/e2e_test.exs`
Tagged: `@moduletag :e2e` (excluded by default in `test_helper.exs`, run with `mix test --include e2e`)

Four test scenarios:

1. **Channel messaging flow** — Alice and Bob connect to same channel via separate `live/2` mounts. Alice submits the message form. Assert Bob's view receives the message via PubSub broadcast. Note: messages go through `ChannelServer` which batches writes on a 2-second interval. The test must use an adequate `assert_receive` timeout (e.g., 5 seconds) to account for batch flush timing. Verifies: form submit → ChannelServer → BatchWriter → PersistenceListener → PubSub → LiveView `handle_info`.

2. **DM request flow** — Alice sends a DM to Bob. Setup: Bob is created with `dm_preference: "shared_channels"` (string, not atom) via the factory, and Alice shares no channel with Bob. Assert DM request is created. Bob accepts the request via the DM request UI. Assert both users can exchange messages bidirectionally. Setup must create both users with the factory and authenticate separate connections.

3. **Link preview pipeline** — User sends a message containing a URL. Assert `LinkPreviewWorker` is enqueued (`assert_enqueued`). The worker calls `MetadataParser.fetch_and_parse/1` which makes HTTP requests — use `Bypass` or `Req.Test` to stub the HTTP response with valid OpenGraph metadata. The test module needs `use Oban.Testing, repo: Slackex.Repo` for queue operations. Drain the queue with `Oban.drain_queue(:link_previews)`. Assert `LinkPreview` record created with `status: "fetched"` (string). Assert PubSub broadcast received by the sender's LiveView (link preview card appears).

4. **Thread dual broadcast** — User A views a channel. User B sends a reply to an existing message (creating a thread). Assert User A's channel-scoped LiveView receives the reply indicator update (reply_count incremented on the parent message). User A opens the thread panel. Assert the reply is listed. Verifies both `channel:#{id}` and `thread:#{parent_id}` PubSub topics are wired.

**Part C: CI integration**

Add to `.github/workflows/ci-deploy.yml` after the main test step:

```yaml
- name: Contract tests
  run: mix test --only contract

- name: E2E tests
  run: mix test --include e2e
```

Note: contract tests run twice (once in the default suite, once isolated). This is intentional — the isolated step makes contract failures immediately distinguishable from general test failures in CI output.

### Files Changed

- `test/slackex_web/channels/envelope_contract_test.exs` — fix moduledoc
- `test/slackex_web/live/chat_live/e2e_test.exs` — new file, 4 test scenarios
- `.github/workflows/ci-deploy.yml` — add contract + E2E CI steps

### Testing

The tests ARE the deliverable. Success = all 4 E2E scenarios pass, contract tests pass in isolation, CI pipeline has both new steps.

## Deviations from Original Plan

- Original test gap remediation plan (`docs/plans/2026-03-06-test-gap-remediation-plan.md`) had 2 E2E tests. This spec adds 2 more (link preview pipeline, thread dual broadcast) based on the project's CLAUDE.md mandate for integration tests on PubSub bridges and Oban pipelines.
- Original plan mentioned tagging 5 contract test files. Existing `@describetag :contract` already accomplishes this for `envelope_contract_test.exs`. Other files will be surveyed during implementation.
- Loading skeletons scoped down from "all transitions" to link preview pending state only, after review identified that all other data loading is synchronous (skeletons would be invisible).

## Implementation Order

These three features are independent. Recommended order:
1. **Test gap remediation** — establishes safety net before UI changes
2. **Message grouping** — higher user-facing impact
3. **Loading skeletons** — small, focused change
