# Phase 5 Steps 6-10 Design: Reactions, Threads, Members/Pins, Invites, Polish

**Date:** 2026-03-06
**Spec:** `specs/07-phase-5-ui.md` Steps 6-10
**Prerequisite:** Steps 1-5 complete, user blocks already implemented

## Context

Steps 1-5 established the UI foundation: responsive layout, sidebar LiveComponent, chat components, DM UI, channel browsing/creation, user profiles with online status, and message editing/deletion. Blocks (from Step 9) were implemented in the DM safety phase.

## Scope

| Step | Feature | New Schemas | Migrations |
|------|---------|-------------|------------|
| 6 | Reactions | `MessageReaction` | `create_message_reactions` |
| 7 | Threads/Replies | (extend `Message`) | `add_threads_to_messages` |
| 8 | Members & Pins | `PinnedMessage` | `create_pinned_messages` |
| 9 | Invite Links | `InviteLink` | `create_invite_links` |
| 10 | Unread & Polish | (none) | (none) |

## Architecture Decisions

### 1. Reactions via toggle pattern

Single `toggle_reaction/3` handles both add and remove. Reactions batch-loaded with `list_reactions/1` (GROUP BY message_id, emoji) to avoid N+1. Stored per-user-per-emoji with unique constraint.

### 2. Thread panel as sliding side panel

400px on desktop alongside message list; full-width overlay on mobile. Not a modal — both channel and thread visible simultaneously. Thread panel is a LiveComponent; parent Index subscribes to `"thread:#{parent_id}"` PubSub topic and forwards messages via `send_update/3` (LiveComponents cannot receive `handle_info` directly).

### 3. Dual broadcast for thread replies

Replies broadcast to both the channel topic (`"message.new"` with thread indicator) and `"thread:#{parent_id}"` topic (`"thread.reply"`). Parent message's `reply_count` updated atomically via `Repo.update_all(inc: [reply_count: 1])`.

### 4. Invite redemption with row-level locking

`redeem_invite/2` uses `SELECT ... FOR UPDATE` inside a transaction to prevent over-redemption. Conditional increment of `use_count` ensures max_uses is never exceeded under concurrency.

### 5. Bulk unread counts via lateral join

Single query joining `subscriptions` -> `read_cursors` -> lateral count on `messages`. `ReadCursor` table already exists with Redis caching layer. Read cursor updated when entering a channel (already implemented).

### 6. Quick switcher

Cmd+K / Ctrl+K opens a fuzzy-search modal over channels and DMs. Implemented as a JS keydown listener pushing a LiveView event, with a simple LiveComponent modal.

## Deviations from Spec

- **Blocks**: Already in `Chat` context (not `Accounts`) with trust scoring. Step 9 only needs invite links.
- **Edit Profile**: Already inline in Index. No separate modal file needed.
- **`emoji-mart`**: Only new npm dependency across all 5 steps.
- **Thread PubSub**: Index subscribes and forwards to ThreadPanelComponent (spec incorrectly shows component subscribing directly).

## New Files

| File | Step | Type |
|------|------|------|
| `lib/slackex/chat/message_reaction.ex` | 6 | Schema |
| `assets/js/hooks/emoji_picker.js` | 6 | JS Hook |
| `lib/slackex_web/live/chat_live/thread_panel_component.ex` | 7 | LiveComponent |
| `lib/slackex/chat/pinned_message.ex` | 8 | Schema |
| `lib/slackex_web/live/chat_live/channel_members_modal.ex` | 8 | LiveComponent |
| `lib/slackex_web/live/chat_live/pinned_messages_modal.ex` | 8 | LiveComponent |
| `lib/slackex/chat/invite_link.ex` | 9 | Schema |
| `lib/slackex_web/live/chat_live/invite_link_modal.ex` | 9 | LiveComponent |
| `lib/slackex_web/live/invite_live.ex` | 9 | LiveView |
| `assets/js/hooks/copy_to_clipboard.js` | 9 | JS Hook |

## Modified Files (key changes only)

- `chat.ex` — toggle_reaction, list_reactions, send_reply, list_thread, list_members, update_member_role, kick_member, pin/unpin, invite CRUD, bulk_unread_counts
- `messaging.ex` — toggle_reaction, send_reply facades with PubSub
- `channel_server.ex` — optional parent_message_id in send flow
- `batch_writer.ex` — include parent_message_id in row mapping
- `message.ex` — parent_message_id, reply_count fields + associations
- `permissions.ex` — manage_members, pin_message action levels
- `index.ex` — reaction/thread/pin/invite/unread event handlers, modal routing
- `chat_components.ex` — reaction_bar, thread indicators, empty states, loading skeletons
- `sidebar_component.ex` — unread badges, theme toggle
- `router.ex` — thread, members, pins, invites, invite redemption routes
- `app.js` — register EmojiPicker, CopyToClipboard hooks; Cmd+K listener
- `package.json` — add emoji-mart

## Migration Sequence

1. `create_message_reactions` (Step 6)
2. `add_threads_to_messages` (Step 7)
3. `create_pinned_messages` (Step 8)
4. `create_invite_links` (Step 9)
