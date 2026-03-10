# Chat Context Refactoring — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Split the 1589-line `Chat` god module into 6 focused sub-modules with a thin facade.

**Architecture:** Extract functions by domain into `Chat.Channels`, `Chat.Messages`, `Chat.Reactions`, `Chat.DMs`, `Chat.ReadState`, `Chat.Moderation`. The `Chat` module becomes a delegation facade. All callers remain unchanged.

**Tech Stack:** Elixir — pure structural refactoring, no new dependencies.

**Library dependencies:** None — context7 verification not applicable (pure structural refactoring of application code).

**Extraction order:** Self-contained modules first, cross-dependent last:
1. Reactions (zero deps)
2. ReadState (zero deps)
3. Channels (zero deps)
4. Moderation (zero deps — blocks, reports, trust scores)
5. Messages (depends on Channels.get_role)
6. DMs (depends on Moderation.blocked?/block_user)
7. Facade (replace chat.ex with delegates)

**Cross-module call strategy:** When module A needs a function from module B, call B directly (e.g., `Chat.Channels.get_role/2`). The facade delegates everything to the leaf modules.

**Shared helpers:** `normalize_user_pair`, `hours_ago`, `days_ago` are 4 lines total — duplicate in DMs and Moderation rather than creating a shared module.

---

### Task 1: Extract Chat.Reactions

**Files:**
- Create: `lib/slackex/chat/reactions.ex`
- Modify: `lib/slackex/chat/chat.ex` (remove lines 478-552)

**Step 1: Create `lib/slackex/chat/reactions.ex`**

Move these functions from `chat.ex`:
- `toggle_reaction/3` (public, line 489)
- `list_reactions/1` — both clauses (public, lines 537, 539)
- `remove_reaction/1` (private, line 502)
- `swap_reaction/4` (private, line 509)
- `add_reaction/3` (private, line 523)

```elixir
defmodule Slackex.Chat.Reactions do
  @moduledoc "Manages message reactions (add, remove, swap, list)."

  import Ecto.Query

  alias Slackex.Chat.MessageReaction
  alias Slackex.Repo

  # Paste toggle_reaction/3, list_reactions/1 (both clauses),
  # remove_reaction/1, swap_reaction/4, add_reaction/3
  # exactly as they appear in chat.ex lines 489-552
end
```

**Step 2: Remove the moved functions from `chat.ex`**

Delete lines 478-552 (the `# Reactions` section header through `end` of `list_reactions`).

**Step 3: Add delegation in `chat.ex`**

At the top of the module (after aliases), add:

```elixir
defdelegate toggle_reaction(message_id, user_id, emoji), to: Slackex.Chat.Reactions
def list_reactions(message_ids), do: Slackex.Chat.Reactions.list_reactions(message_ids)
```

Note: `list_reactions/1` has two clauses (one for `[]`, one for list) — use a wrapper, not defdelegate.

**Step 4: Run tests**

```bash
mix test test/slackex/chat/message_reaction_test.exs test/slackex/chat/reactions_test.exs --trace
```

Expected: All tests pass. If any fail, check alias/import issues in the new module.

**Step 5: Run full test suite**

```bash
mix test
```

Expected: All 1162+ tests pass.

**Step 6: Commit**

```bash
git add lib/slackex/chat/reactions.ex lib/slackex/chat/chat.ex
git commit -m "refactor(chat): extract Chat.Reactions from god module"
```

---

### Task 2: Extract Chat.ReadState

**Files:**
- Create: `lib/slackex/chat/read_state.ex`
- Modify: `lib/slackex/chat/chat.ex` (remove lines 1156-1270)

**Step 1: Create `lib/slackex/chat/read_state.ex`**

Move these functions:
- `mark_as_read/2` (public, line 1163)
- `unread_count/2` (public, line 1170)
- `mark_dm_as_read/2` (public, line 1188)
- `batch_unread_counts/1` (public, line 1229)
- `upsert_read_cursor/3` (private, line 1194)
- `latest_message_id/2` (private, line 1213)
- `batch_channel_unread_counts/1` (private, line 1236)
- `batch_dm_unread_counts/1` (private, line 1254)
- Module attribute: `@no_cursor_message_id 0` (line 72)
- Module attribute: `@valid_cursor_fields` (line 1192)

```elixir
defmodule Slackex.Chat.ReadState do
  @moduledoc "Manages read cursors and unread counts for channels and DMs."

  import Ecto.Query

  alias Slackex.Chat.{DMConversation, Message, ReadCursor, Subscription}
  alias Slackex.Repo

  @no_cursor_message_id 0
  @valid_cursor_fields [:channel_id, :dm_conversation_id]

  # Paste all functions from chat.ex lines 1163-1270
end
```

**Step 2: Remove the moved functions from `chat.ex`**

Delete lines 1156-1270 (the `# Read cursor operations` section). Also remove `@no_cursor_message_id` from line 72 (it moves to ReadState).

**Step 3: Add delegation in `chat.ex`**

```elixir
defdelegate mark_as_read(user_id, channel_id), to: Slackex.Chat.ReadState
defdelegate unread_count(user_id, channel_id), to: Slackex.Chat.ReadState
defdelegate mark_dm_as_read(user_id, dm_conversation_id), to: Slackex.Chat.ReadState
defdelegate batch_unread_counts(user_id), to: Slackex.Chat.ReadState
```

**Step 4: Run tests**

```bash
mix test test/slackex/chat/unread_counts_test.exs --trace
```

**Step 5: Run full test suite**

```bash
mix test
```

**Step 6: Commit**

```bash
git add lib/slackex/chat/read_state.ex lib/slackex/chat/chat.ex
git commit -m "refactor(chat): extract Chat.ReadState from god module"
```

---

### Task 3: Extract Chat.Channels

**Files:**
- Create: `lib/slackex/chat/channels.ex`
- Modify: `lib/slackex/chat/chat.ex` (remove lines 74-227)

**Step 1: Create `lib/slackex/chat/channels.ex`**

Move these functions:
- `create_channel/2` (public, line 81)
- `count_members/1` (public, line 102)
- `list_public_channels/1` (public, line 113)
- `list_active_channels/1` (public, line 150)
- `list_user_channels/1` (public, line 169)
- `list_user_channel_ids/1` (public, line 181)
- `get_channel!/1` (public, line 187)
- `get_channel_by_slug!/1` (public, line 188)
- `join_channel/2` (public, line 193)
- `leave_channel/2` (public, line 208)
- `get_role/2` (public, line 220)
- `maybe_exclude_member/2` (private, lines 139-147)

```elixir
defmodule Slackex.Chat.Channels do
  @moduledoc "Manages channels: creation, listing, membership, and roles."

  import Ecto.Query

  alias Ecto.Multi
  alias Slackex.Chat.{Channel, Message, Subscription}
  alias Slackex.ReadRepo
  alias Slackex.Repo

  # Paste all functions from chat.ex lines 81-226
end
```

**Step 2: Remove the moved functions from `chat.ex`**

Delete lines 74-227 (the `# Channel operations` section).

**Step 3: Add delegation in `chat.ex`**

```elixir
defdelegate create_channel(user_id, attrs), to: Slackex.Chat.Channels
defdelegate count_members(channel_id), to: Slackex.Chat.Channels
def list_public_channels(opts \\ []), do: Slackex.Chat.Channels.list_public_channels(opts)
def list_active_channels(opts \\ []), do: Slackex.Chat.Channels.list_active_channels(opts)
defdelegate list_user_channels(user_id), to: Slackex.Chat.Channels
defdelegate list_user_channel_ids(user_id), to: Slackex.Chat.Channels
defdelegate get_channel!(id), to: Slackex.Chat.Channels
defdelegate get_channel_by_slug!(slug), to: Slackex.Chat.Channels
defdelegate join_channel(user_id, channel_id), to: Slackex.Chat.Channels
defdelegate leave_channel(user_id, channel_id), to: Slackex.Chat.Channels
defdelegate get_role(user_id, channel_id), to: Slackex.Chat.Channels
```

**Step 4: Run tests**

```bash
mix test test/slackex/chat_test.exs test/slackex/chat/members_test.exs --trace
```

**Step 5: Run full test suite**

```bash
mix test
```

**Step 6: Commit**

```bash
git add lib/slackex/chat/channels.ex lib/slackex/chat/chat.ex
git commit -m "refactor(chat): extract Chat.Channels from god module"
```

---

### Task 4: Extract Chat.Moderation

**Files:**
- Create: `lib/slackex/chat/moderation.ex`
- Modify: `lib/slackex/chat/chat.ex` (remove lines 1272-1575 + velocity section)

**Step 1: Create `lib/slackex/chat/moderation.ex`**

Move these functions:

**User blocks (lines 1272-1368):**
- `block_user/2`, `unblock_user/2`, `blocked?/2`, `list_blocked_user_ids/1`, `list_blocked_users/1`
- `upsert_block_count/1`, `maybe_apply_block_restriction/1`

**Abuse reports (lines 1370-1536):**
- `create_abuse_report/3`
- `check_self_report/2`, `check_reporter_account_age/1`, `check_not_dm_restricted/1`
- `upsert_report_count/1`, `check_report_thresholds/1`, `count_distinct_reporters/1`
- `dampen_reporter_clusters/1`, `maybe_apply_dm_restriction/1`, `maybe_apply_admin_flag/1`

**Velocity (lines 1538-1575):**
- `check_velocity/1`, `count_negative_signals_24h/1`

**Shared helpers needed (duplicate from Shared helpers section):**
- `hours_ago/1`, `days_ago/1`

**Module attributes needed:**
- `@auto_restrict_block_threshold 5`
- `@report_restrict_threshold 3`
- `@report_admin_flag_threshold 5`
- `@velocity_signal_threshold 3`
- `@velocity_window_hours 24`
- `@dampening_window_seconds 86_400`
- `@new_account_age_days 7` (used by `check_reporter_account_age`)

```elixir
defmodule Slackex.Chat.Moderation do
  @moduledoc "Manages user blocks, abuse reports, trust scores, and velocity detection."

  import Ecto.Query

  alias Slackex.Accounts.User
  alias Slackex.Chat.{AbuseReport, DMRequest, UserBlock, UserTrustScore}
  alias Slackex.Repo

  @new_account_age_days 7
  @auto_restrict_block_threshold 5
  @report_restrict_threshold 3
  @report_admin_flag_threshold 5
  @velocity_signal_threshold 3
  @velocity_window_hours 24
  @dampening_window_seconds 86_400

  # Paste all block, report, velocity, and trust score functions
  # Include hours_ago/1 and days_ago/1 as private helpers

  defp hours_ago(hours), do: DateTime.utc_now() |> DateTime.add(-hours * 3600, :second)
  defp days_ago(days), do: hours_ago(days * 24)
end
```

**Important:** `check_not_dm_restricted/1` is also called by DMs (Task 6). Make it `def` (public) so DMs can call `Chat.Moderation.check_not_dm_restricted/1`.

**Step 2: Remove the moved functions from `chat.ex`**

Delete lines 1272-1575 (blocks + reports + velocity sections). Also remove the module attributes that moved.

**Step 3: Add delegation in `chat.ex`**

```elixir
defdelegate block_user(blocker_id, blocked_id), to: Slackex.Chat.Moderation
defdelegate unblock_user(blocker_id, blocked_id), to: Slackex.Chat.Moderation
defdelegate blocked?(blocker_id, blocked_id), to: Slackex.Chat.Moderation
defdelegate list_blocked_user_ids(user_id), to: Slackex.Chat.Moderation
defdelegate list_blocked_users(user_id), to: Slackex.Chat.Moderation
defdelegate create_abuse_report(reporter_id, reported_user_id, attrs), to: Slackex.Chat.Moderation
```

**Step 4: Run tests**

```bash
mix test test/slackex/chat/user_block_test.exs test/slackex/chat/abuse_report_test.exs test/slackex/chat/abuse_report_flow_test.exs test/slackex/chat/user_trust_score_test.exs test/slackex/chat/trust_enforcement_test.exs --trace
```

**Step 5: Run full test suite**

```bash
mix test
```

**Step 6: Commit**

```bash
git add lib/slackex/chat/moderation.ex lib/slackex/chat/chat.ex
git commit -m "refactor(chat): extract Chat.Moderation from god module"
```

---

### Task 5: Extract Chat.Messages

**Files:**
- Create: `lib/slackex/chat/messages.ex`
- Modify: `lib/slackex/chat/chat.ex` (remove message + thread sections)

**Step 1: Create `lib/slackex/chat/messages.ex`**

Move these functions:

**Messages (lines 228-476):**
- `get_message!/1`, `get_message/1`, `edit_message/3`, `delete_message/3`, `send_message/3`
- `list_messages/2`, `list_dm_messages/2`, `list_messages_around/3`
- `check_not_deleted/1`, `check_is_sender/2`, `authorize_delete/2`, `scope_filter/1`

**Threads (lines 554-616):**
- `send_reply/4`, `list_thread/2`

**Cross-module calls needed:**
- `authorize_delete/2` calls `get_role/2` → change to `Slackex.Chat.Channels.get_role/2`
- `send_message/3` calls `get_role/2` → change to `Slackex.Chat.Channels.get_role/2`
- Both call `Permissions.can?/2` → already a separate module, alias works

```elixir
defmodule Slackex.Chat.Messages do
  @moduledoc "Manages messages: send, edit, delete, list, threads."

  import Ecto.Query

  alias Ecto.Multi
  alias Slackex.Chat.{Message, Permissions}
  alias Slackex.Infrastructure.Snowflake
  alias Slackex.ReadRepo
  alias Slackex.Repo

  # In authorize_delete and send_message, replace:
  #   get_role(user_id, channel_id)
  # with:
  #   Slackex.Chat.Channels.get_role(user_id, channel_id)

  # Paste all message + thread functions
end
```

**Step 2: Remove the moved functions from `chat.ex`**

Delete the Message operations section and Threads section.

**Step 3: Add delegation in `chat.ex`**

```elixir
defdelegate get_message!(id), to: Slackex.Chat.Messages
defdelegate get_message(id), to: Slackex.Chat.Messages
defdelegate edit_message(message_id, user_id, new_content), to: Slackex.Chat.Messages
def delete_message(message_id, user_id, opts \\ []), do: Slackex.Chat.Messages.delete_message(message_id, user_id, opts)
defdelegate send_message(channel_id, sender_id, content), to: Slackex.Chat.Messages
def list_messages(channel_id, opts \\ []), do: Slackex.Chat.Messages.list_messages(channel_id, opts)
def list_dm_messages(dm_id, opts \\ []), do: Slackex.Chat.Messages.list_dm_messages(dm_id, opts)
def list_messages_around(target, message_id, opts \\ []), do: Slackex.Chat.Messages.list_messages_around(target, message_id, opts)
defdelegate send_reply(channel_id, sender_id, parent_message_id, content), to: Slackex.Chat.Messages
def list_thread(parent_message_id, opts \\ []), do: Slackex.Chat.Messages.list_thread(parent_message_id, opts)
```

**Step 4: Run tests**

```bash
mix test test/slackex/chat_test.exs test/slackex/chat/chat_edit_delete_test.exs test/slackex/chat/threads_test.exs test/slackex/chat/list_messages_around_test.exs --trace
```

**Step 5: Run full test suite**

```bash
mix test
```

**Step 6: Commit**

```bash
git add lib/slackex/chat/messages.ex lib/slackex/chat/chat.ex
git commit -m "refactor(chat): extract Chat.Messages from god module"
```

---

### Task 6: Extract Chat.DMs

**Files:**
- Create: `lib/slackex/chat/dms.ex`
- Modify: `lib/slackex/chat/chat.ex` (remove DM sections — the last major block)

**Step 1: Create `lib/slackex/chat/dms.ex`**

Move these functions:

**DM operations (lines 618-686):**
- `get_dm/1`, `find_or_create_dm/2`, `block_exists_between?/2`, `find_or_create_dm_record/4`
- `maybe_broadcast_new_dm/1`, `check_rate_limit/2`, `broadcast_new_dm/1`

**DM requests (lines 688-1086):**
- `create_dm_request/3` (both clauses), `accept_dm_request/2`, `decline_dm_request/2`
- `list_pending_requests_for_user/1`
- All private helpers: `check_account_age`, `check_not_blocked`, `check_shared_channels_if_new`, `shared_channel_exists?`, `check_request_rate_hourly`, `check_request_rate_daily`, `check_pending_request_count`, `check_dm_preference`, `check_existing_conversation`, `check_cooldown`, `most_recent_decline_timestamp`, `broadcast_dm_request_new`, `insert_dm_request`, `fetch_pending_request`, `find_or_insert_dm_conversation`, `insert_dm_conversation`, `handle_upsert_result`, `broadcast_dm_request_accepted`, `count_prior_declines`, `upsert_decline_count`

**DM messaging (lines 1091-1154):**
- `send_dm/3`, `list_dms/1`, `list_user_dm_conversations/1`, `get_dm_conversation!/1`
- `verify_dm_participant/2`

**Shared helpers to duplicate:**
- `normalize_user_pair/2`, `hours_ago/1`, `days_ago/1`

**Module attributes:**
- All DM safety thresholds (lines 56-69): `@min_account_age_hours`, `@new_account_age_days`, `@max_requests_per_hour`, etc.

**Cross-module calls:**
- `blocked?/2` → `Slackex.Chat.Moderation.blocked?/2`
- `block_user/2` (in `decline_dm_request`) → `Slackex.Chat.Moderation.block_user/2`
- `check_not_dm_restricted/1` → `Slackex.Chat.Moderation.check_not_dm_restricted/1`

```elixir
defmodule Slackex.Chat.DMs do
  @moduledoc "Manages DM conversations, DM requests, and DM messaging."

  import Ecto.Query

  alias Ecto.Multi
  alias Slackex.Accounts.User
  alias Slackex.Chat.{DMConversation, DMRateLimiter, DMRequest, Message, Subscription, UserTrustScore}
  alias Slackex.Infrastructure.Snowflake
  alias Slackex.Repo

  @min_account_age_hours 24
  @new_account_age_days 7
  @max_requests_per_hour 5
  @max_requests_per_day 20
  @max_pending_requests 10
  @cooldown_after_first_decline_days 7
  @cooldown_after_second_decline_days 30
  @auto_block_after_declines 3

  # Replace blocked?(a, b) calls with Slackex.Chat.Moderation.blocked?(a, b)
  # Replace block_user(a, b) calls with Slackex.Chat.Moderation.block_user(a, b)
  # Replace check_not_dm_restricted(id) with Slackex.Chat.Moderation.check_not_dm_restricted(id)

  # Paste all DM functions

  # Duplicate shared helpers
  defp normalize_user_pair(user_a_id, user_b_id) when user_a_id < user_b_id,
    do: {user_a_id, user_b_id}
  defp normalize_user_pair(user_a_id, user_b_id),
    do: {user_b_id, user_a_id}

  defp hours_ago(hours), do: DateTime.utc_now() |> DateTime.add(-hours * 3600, :second)
  defp days_ago(days), do: hours_ago(days * 24)
end
```

**Step 2: Remove the moved functions from `chat.ex`**

Delete all DM sections and the Shared helpers section. Remove DM safety threshold module attributes.

**Step 3: Add delegation in `chat.ex`**

```elixir
defdelegate get_dm(id), to: Slackex.Chat.DMs
defdelegate find_or_create_dm(user_a_id, user_b_id), to: Slackex.Chat.DMs
defdelegate create_dm_request(sender_id, recipient_id, preview_text), to: Slackex.Chat.DMs
defdelegate accept_dm_request(request_id, recipient_id), to: Slackex.Chat.DMs
defdelegate decline_dm_request(request_id, recipient_id), to: Slackex.Chat.DMs
defdelegate list_pending_requests_for_user(user_id), to: Slackex.Chat.DMs
defdelegate send_dm(dm_id, sender_id, content), to: Slackex.Chat.DMs
defdelegate list_dms(user_id), to: Slackex.Chat.DMs
defdelegate list_user_dm_conversations(user_id), to: Slackex.Chat.DMs
defdelegate get_dm_conversation!(id), to: Slackex.Chat.DMs
defdelegate mark_dm_as_read(user_id, dm_conversation_id), to: Slackex.Chat.ReadState
```

**Step 4: Run tests**

```bash
mix test test/slackex/chat/dm_request_test.exs test/slackex/chat/dm_request_flow_test.exs test/slackex/chat/dm_request_encryption_test.exs test/slackex/chat/dm_rate_limiter_test.exs --trace
```

**Step 5: Run full test suite**

```bash
mix test
```

**Step 6: Commit**

```bash
git add lib/slackex/chat/dms.ex lib/slackex/chat/chat.ex
git commit -m "refactor(chat): extract Chat.DMs from god module"
```

---

### Task 7: Clean up facade

**Files:**
- Modify: `lib/slackex/chat/chat.ex` (final cleanup)

After Tasks 1-6, `chat.ex` should contain ONLY:
- Module definition with `use Boundary` and exports
- `defdelegate` and thin wrapper functions
- No `import Ecto.Query`, no direct Repo calls, no private helpers

**Step 1: Verify chat.ex is facade-only**

Read the file. It should be ~80-100 lines of pure delegation. If any business logic remains, it was missed in a prior task — move it now.

**Step 2: Clean up imports and aliases**

Remove any aliases/imports that are no longer needed in `chat.ex`. The facade only needs:
- `use Boundary` with exports (keep existing exports list)
- No `import Ecto.Query`
- No `alias Ecto.Multi`
- No `alias Slackex.Repo` / `ReadRepo`

Keep only aliases needed for the Boundary exports declaration.

**Step 3: Update the Boundary exports**

Add the new modules to the exports list:

```elixir
use Boundary,
  deps: [Slackex.Accounts, Slackex.Infrastructure, Slackex.Encrypted],
  exports: [
    Channel,
    Channels,
    Message,
    Messages,
    MessageReaction,
    Reactions,
    PinnedMessage,
    Members,
    Pins,
    InviteLink,
    Invites,
    DMConversation,
    DMs,
    DMRequest,
    ReadCursor,
    ReadState,
    Subscription,
    UserBlock,
    UserTrustScore,
    AbuseReport,
    Moderation,
    Permissions,
    DMRateLimiter
  ]
```

**Step 4: Run full test suite**

```bash
mix test
```

Expected: All tests pass.

**Step 5: Run quality checks**

```bash
mix compile --warnings-as-errors && mix credo && mix dialyzer --format github
```

Expected: Clean compile, no Credo issues, no Dialyzer warnings.

**Step 6: Commit**

```bash
git add lib/slackex/chat/chat.ex
git commit -m "refactor(chat): finalize facade — Chat is now pure delegation"
```

---

## Verification Checklist

After all 7 tasks:

- [ ] `chat.ex` is ~80-100 lines (was 1589)
- [ ] 6 new modules exist: `channels.ex`, `messages.ex`, `reactions.ex`, `dms.ex`, `read_state.ex`, `moderation.ex`
- [ ] `mix test` — all tests pass
- [ ] `mix compile --warnings-as-errors` — clean
- [ ] `mix credo` — clean
- [ ] `mix dialyzer` — clean
- [ ] No caller changes outside `lib/slackex/chat/` (facade handles everything)
- [ ] Each new module has `@moduledoc`
- [ ] Each new module only imports/aliases what it needs
