# Chat Context Refactoring Design

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Split the 1589-line `Chat` god module (112 public functions) into 6 focused sub-modules while maintaining backwards compatibility via a thin facade.

**Architecture:** Extract functions by domain responsibility into new modules under `lib/slackex/chat/`. The existing `Chat` module becomes a thin facade that delegates to sub-modules. Zero caller changes required.

**Tech Stack:** Elixir — pure structural refactoring, no new dependencies.

**Library dependencies:** None. No external library behavior involved — context7 verification not applicable (pure structural refactoring of application code).

---

## Current State

`lib/slackex/chat/chat.ex` contains 6 distinct domains:

| Domain | Public fns | Est. lines | Description |
|--------|-----------|------------|-------------|
| Channels | 9 | ~140 | create, list (3), get (2), join, leave, get_role, count_members |
| Messages | 10 | ~310 | send, edit, delete, get (2), list (2), list_around, send_reply, list_thread |
| Reactions | 2 | ~80 | toggle_reaction, list_reactions |
| DMs | 11 | ~450 | find_or_create_dm, send_dm, list_dms, DM requests (create/accept/decline/list), get_dm_conversation! |
| Read State | 4 | ~100 | mark_as_read, unread_count, mark_dm_as_read, batch_unread_counts |
| Moderation | 6 | ~120 | block/unblock, blocked?, list_blocked (2), create_abuse_report |

Already extracted (not changing): `Chat.Members`, `Chat.Pins`, `Chat.Invites`, `Chat.Permissions`

## New Module Structure

```
lib/slackex/chat/
  chat.ex           -> Thin facade (~80 lines, defdelegate + wrappers)
  channels.ex       -> NEW (rename existing channel.ex schema to channel_schema.ex? No — keep as-is, module name is Chat.Channels not Chat.Channel)
  messages.ex       -> NEW
  reactions.ex      -> NEW
  dms.ex            -> NEW
  read_state.ex     -> NEW
  moderation.ex     -> NEW
  members.ex        -> EXISTING (unchanged)
  pins.ex           -> EXISTING (unchanged)
  invites.ex        -> EXISTING (unchanged)
  permissions.ex    -> EXISTING (unchanged)
  (schemas unchanged: channel.ex, message.ex, dm_conversation.ex, etc.)
```

## Facade Pattern

`Chat` becomes a delegation module. All 82 files calling `Slackex.Chat.*` continue working unchanged.

```elixir
defmodule Slackex.Chat do
  # Functions without default args use defdelegate
  defdelegate get_channel!(id), to: Slackex.Chat.Channels
  defdelegate toggle_reaction(message_id, user_id, emoji), to: Slackex.Chat.Reactions

  # Functions WITH default args need thin wrappers (defdelegate doesn't support defaults)
  def list_messages(channel_id, opts \\ []), do: Slackex.Chat.Messages.list_messages(channel_id, opts)
  def send_message(channel_id, sender_id, content), do: Slackex.Chat.Messages.send_message(channel_id, sender_id, content)
end
```

## Private Helpers

Each helper moves with its domain module:

- `check_not_deleted/1`, `check_is_sender/2`, `authorize_delete/2` -> `Chat.Messages`
- `scope_filter/1` -> duplicated in `Messages` and `DMs` (2-line function, not worth sharing)

## What Doesn't Change

- Schema modules (channel.ex, message.ex, dm_conversation.ex, etc.)
- Already-extracted modules (Members, Pins, Invites, Permissions)
- Test file organization (tests call through Chat facade, continue passing)
- PubSub topic names and broadcast patterns
- No database changes, no migration needed

## Testing Strategy

- Existing tests pass unchanged (they call through Chat facade)
- Run full test suite after each module extraction to catch any missed references
- No new test files needed — existing coverage is sufficient

## Risk

Low. Pure structural refactoring — moving functions between files with delegation wiring. No logic changes, no API changes.
