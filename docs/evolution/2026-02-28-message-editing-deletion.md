# Message Editing & Deletion — Evolution Document

**Date**: 2026-02-28
**Project ID**: message-editing-deletion
**Status**: Complete

## Summary

Added message editing and soft-deletion to the Slackex messaging application. Users can edit their own messages (inline form with Save/Cancel/Escape), and delete their own messages in any context. Channel admins/owners can delete any message in channels they manage. All operations broadcast in real-time to connected users via PubSub.

## Architecture Decisions

### Soft Delete Pattern
Messages are soft-deleted by nullifying `content` and setting `deleted_at`. The row is preserved for audit trails and conversation continuity. Deleted messages render as "[This message has been deleted]" in muted italic styling.

### Authorization Model
- **Edit**: Only the message sender can edit their own message (level 2 = member+)
- **Delete own**: Any user can delete their own message in any context (level 2)
- **Delete any**: Admin/owner role can delete any message in channels they manage (level 3)
- **DM restriction**: Users can only delete their own messages in DMs (no admin override)

### Cache Strategy
Cache is invalidated (not patched) on edit and delete. ChannelServer subscribes to PubSub and updates its in-memory queue via `handle_info` without requiring a full DB rebuild. This avoids cache coherency complexity while keeping the hot path fast.

### Inline Edit Form
Edit mode is tracked via `editing_message_id` assign. Only one message can be in edit mode at a time. The EditMessage JS hook handles Escape key cancellation and captures the textarea's current content for the save_edit event (avoiding stale `phx-value` issues).

## Implementation

### Phase 1 — Domain Layer (Steps 01-01, 01-02)
- Migration: added `deleted_at` (utc_datetime_usec, nullable) to messages table
- `Message.edit_changeset/2`: updates content + edited_at with HTML sanitization
- `Message.delete_changeset/1`: nullifies content, sets deleted_at
- `Chat.edit_message/3` and `Chat.delete_message/3` with full authorization
- 3 new permission actions: `edit_own_message(2)`, `delete_own_message(2)`, `delete_any_message(3)`
- `Messaging.edit_message/3` and `Messaging.delete_message/2`: facade delegates to Chat, broadcasts envelope, updates cache
- ChannelServer subscribes to PubSub and updates in-memory queue on edit/delete envelopes

### Phase 2 — LiveView Event Handling (Step 02-01)
- `handle_event` for: edit_message, save_edit, cancel_edit, delete_message
- `handle_info` for: message.edited, message.deleted envelopes
- Stream updates via `stream_insert` for real-time UI updates
- Delete confirmation via `data-confirm` attribute (browser native dialog)

### Phase 3 — UI Components (Steps 03-01, 03-02)
- Hover action bar: Edit button (own messages), Delete button (own + admin)
- "(edited)" indicator next to timestamp when `edited_at` is set
- "[This message has been deleted]" placeholder for soft-deleted messages
- Inline edit form: textarea with Save/Cancel buttons, Escape key support
- EditMessage JS hook for keyboard handling and content capture

## Files Modified

### New Files
- `priv/repo/migrations/20260228032700_add_deleted_at_to_messages.exs`
- `test/slackex/chat/chat_edit_delete_test.exs`
- `assets/js/hooks/edit_message.js`

### Modified Files
- `lib/slackex/chat/message.ex` — deleted_at field, edit/delete changesets
- `lib/slackex/chat/chat.ex` — get_message, edit_message, delete_message with authorization
- `lib/slackex/chat/permissions.ex` — 3 new permission actions
- `lib/slackex/messaging/messaging.ex` — facade functions with broadcast
- `lib/slackex/messaging/channel_server.ex` — PubSub subscription, queue updates
- `lib/slackex/cache/cache.ex` — update_message, remove_message
- `lib/slackex/cache/local.ex` — ETS update/remove operations
- `lib/slackex_web/live/chat_live/index.ex` — event handlers, stream updates
- `lib/slackex_web/components/chat_components.ex` — hover actions, indicators, edit form
- `assets/js/app.js` — EditMessage hook registration

## Test Coverage

- **838 total tests** (up from 783 before feature start, +55 new tests)
- 8 Chat context tests (edit/delete authorization scenarios)
- 15 Permissions tests (3 new actions × 5 roles)
- 8 Messaging integration tests (broadcast + cache)
- ~24 LiveView tests (edit flow, delete flow, real-time updates, DM editing)

## Commits

| Hash | Description |
|------|-------------|
| `5c1fb3f` | Domain layer: Chat edit/delete + permissions + migration |
| `cfbbd07` | Messaging facade: broadcast + cache invalidation |
| `628ec04` | LiveView: handle_event/handle_info for edit/delete |
| `7861025` | UI: hover actions, edited indicator, deleted placeholder |
| `0bed4d6` | UI: inline edit form with Save/Cancel/Escape |
| `2c049f3` | L1-L4 refactoring sweep |

## Retrospective

Clean execution — no failures, no retries needed. Two agent timeouts during steps 02-01 and 03-01 were recovered by verifying tests pass and committing the completed work. One test fix required during step 03-01 (substring false positive: "Delete me" matched within "Delete message" button title).
