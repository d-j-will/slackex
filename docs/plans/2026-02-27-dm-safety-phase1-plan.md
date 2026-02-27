# DM Safety Phase 1: Fix DM Delivery + Blocking Foundation

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make cross-user DMs visible in the recipient's sidebar in real-time, order DMs by last activity, and add user blocking.

**Architecture:** Fix the missing PubSub notification path so recipients learn about new DM conversations, add `updated_at` to `dm_conversations` for activity-based ordering, and introduce a `user_blocks` table with enforcement in DM creation and user search.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto, PubSub, ExMachina (test factories), PostgreSQL

**Design doc:** `docs/plans/2026-02-27-dm-safety-system-design.md`

---

## Task 1: Add `updated_at` to `dm_conversations`

**Files:**
- Create: `priv/repo/migrations/TIMESTAMP_add_updated_at_to_dm_conversations.exs`
- Modify: `lib/slackex/chat/dm_conversation.ex`

**Step 1: Write the migration**

```bash
mix ecto.gen.migration add_updated_at_to_dm_conversations
```

Then edit the generated file:

```elixir
defmodule Slackex.Repo.Migrations.AddUpdatedAtToDmConversations do
  use Ecto.Migration

  def change do
    alter table(:dm_conversations) do
      add :updated_at, :utc_datetime_usec
    end

    # Backfill existing rows: set updated_at = inserted_at
    execute(
      "UPDATE dm_conversations SET updated_at = inserted_at WHERE updated_at IS NULL",
      ""
    )

    # Now make it non-null
    alter table(:dm_conversations) do
      modify :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end
  end
end
```

**Step 2: Add `updated_at` field to the schema**

In `lib/slackex/chat/dm_conversation.ex`, add inside the schema block:

```elixir
field :updated_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []}
```

**Step 3: Run the migration**

```bash
mix ecto.migrate
```

Expected: Migration succeeds, no errors.

**Step 4: Commit**

```bash
git add priv/repo/migrations/*_add_updated_at_to_dm_conversations.exs lib/slackex/chat/dm_conversation.ex
git commit -m "feat: add updated_at to dm_conversations for activity ordering"
```

---

## Task 2: Update `updated_at` on each DM message and order sidebar by activity

**Files:**
- Modify: `lib/slackex/chat/chat.ex` (functions: `send_dm`, `list_user_dm_conversations`)
- Test: `test/slackex/chat_test.exs`

**Step 1: Write the failing test**

Add to `test/slackex/chat_test.exs`:

```elixir
describe "DM conversation activity ordering" do
  test "send_dm updates dm_conversation.updated_at" do
    alice = insert(:user)
    bob = insert(:user)
    {:ok, dm} = Chat.find_or_create_dm(alice.id, bob.id)

    before = dm.updated_at
    Process.sleep(10)
    {:ok, _msg} = Chat.send_dm(dm.id, alice.id, "Hello")

    refreshed = Slackex.Repo.get!(Slackex.Chat.DMConversation, dm.id)
    assert DateTime.compare(refreshed.updated_at, before) == :gt
  end

  test "list_user_dm_conversations orders by updated_at desc" do
    alice = insert(:user)
    bob = insert(:user)
    charlie = insert(:user)

    {:ok, dm_bob} = Chat.find_or_create_dm(alice.id, bob.id)
    Process.sleep(10)
    {:ok, dm_charlie} = Chat.find_or_create_dm(alice.id, charlie.id)

    # dm_charlie is newer, should be first
    convos = Chat.list_user_dm_conversations(alice.id)
    assert [first | _] = convos
    assert first.id == dm_charlie.id

    # Now send a message in dm_bob to bump its updated_at
    Process.sleep(10)
    {:ok, _msg} = Chat.send_dm(dm_bob.id, alice.id, "bump")

    convos = Chat.list_user_dm_conversations(alice.id)
    assert [first | _] = convos
    assert first.id == dm_bob.id
  end
end
```

**Step 2: Run test to verify it fails**

```bash
mix test test/slackex/chat_test.exs --seed 0 -v 2>&1 | grep -A 2 "activity ordering"
```

Expected: FAIL — `send_dm` doesn't update `updated_at`, ordering still uses `inserted_at`.

**Step 3: Update `send_dm` in `lib/slackex/chat/chat.ex`**

Replace the `send_dm` function (around line 302) to touch `updated_at` after inserting:

```elixir
def send_dm(dm_id, sender_id, content) do
  dm = Repo.get!(DMConversation, dm_id)

  if sender_id == dm.user_a_id or sender_id == dm.user_b_id do
    id = Snowflake.generate()
    sanitized = HtmlSanitizeEx.strip_tags(content)

    Multi.new()
    |> Multi.insert(:message, Message.changeset(%Message{}, %{
      id: id,
      content: sanitized,
      sender_id: sender_id,
      dm_conversation_id: dm_id
    }))
    |> Multi.update(:dm, Ecto.Changeset.change(dm, updated_at: DateTime.utc_now()))
    |> Repo.transaction()
    |> case do
      {:ok, %{message: message}} ->
        {:ok, Repo.preload(message, :sender)}

      {:error, :message, changeset, _} ->
        {:error, changeset}

      {:error, :dm, changeset, _} ->
        {:error, changeset}
    end
  else
    {:error, :unauthorized}
  end
end
```

**Step 4: Update `list_user_dm_conversations` ordering**

Change `order_by: [desc: d.inserted_at]` to `order_by: [desc: d.updated_at]` on line 348. Also update the returned map to include `updated_at`:

```elixir
def list_user_dm_conversations(user_id) do
  from(d in DMConversation,
    where: d.user_a_id == ^user_id or d.user_b_id == ^user_id,
    order_by: [desc: d.updated_at],
    preload: [:user_a, :user_b]
  )
  |> Repo.all()
  |> Enum.map(fn dm ->
    other_user = if dm.user_a_id == user_id, do: dm.user_b, else: dm.user_a
    %{id: dm.id, other_user: other_user, inserted_at: dm.inserted_at, updated_at: dm.updated_at}
  end)
end
```

**Step 5: Run test to verify it passes**

```bash
mix test test/slackex/chat_test.exs --seed 0 -v 2>&1 | grep -A 2 "activity ordering"
```

Expected: PASS

**Step 6: Run full test suite to check for regressions**

```bash
mix test
```

Expected: All tests pass.

**Step 7: Commit**

```bash
git add lib/slackex/chat/chat.ex test/slackex/chat_test.exs
git commit -m "feat: order DM conversations by last activity, update updated_at on send"
```

---

## Task 3: Broadcast new DM conversations to recipient via PubSub

**Files:**
- Modify: `lib/slackex/chat/chat.ex` (function: `find_or_create_dm`)
- Modify: `lib/slackex_web/live/chat_live/index.ex` (add `handle_info` for `:dm_conversation_new`)
- Test: `test/slackex/chat_test.exs`
- Test: `test/slackex_web/live/chat_live_test.exs`

**Step 1: Write the failing test for PubSub broadcast**

Add to `test/slackex/chat_test.exs`:

```elixir
describe "DM conversation PubSub" do
  test "find_or_create_dm broadcasts to recipient when conversation is new" do
    alice = insert(:user)
    bob = insert(:user)

    # Subscribe to bob's user topic
    Phoenix.PubSub.subscribe(Slackex.PubSub, "user:#{bob.id}")

    {:ok, dm} = Chat.find_or_create_dm(alice.id, bob.id)

    assert_receive {:dm_conversation_new, ^dm}
  end

  test "find_or_create_dm broadcasts to sender when conversation is new" do
    alice = insert(:user)
    bob = insert(:user)

    Phoenix.PubSub.subscribe(Slackex.PubSub, "user:#{alice.id}")

    {:ok, dm} = Chat.find_or_create_dm(alice.id, bob.id)

    assert_receive {:dm_conversation_new, ^dm}
  end

  test "find_or_create_dm does not broadcast for existing conversation" do
    alice = insert(:user)
    bob = insert(:user)
    {:ok, _dm} = Chat.find_or_create_dm(alice.id, bob.id)

    Phoenix.PubSub.subscribe(Slackex.PubSub, "user:#{bob.id}")

    {:ok, _dm} = Chat.find_or_create_dm(alice.id, bob.id)

    refute_receive {:dm_conversation_new, _}
  end
end
```

**Step 2: Run test to verify it fails**

```bash
mix test test/slackex/chat_test.exs --seed 0 -v 2>&1 | grep -A 2 "PubSub"
```

Expected: FAIL — no broadcast happens.

**Step 3: Add broadcast to `find_or_create_dm` in `lib/slackex/chat/chat.ex`**

```elixir
def find_or_create_dm(user_a_id, user_b_id) do
  {a, b} = if user_a_id < user_b_id, do: {user_a_id, user_b_id}, else: {user_b_id, user_a_id}

  case Repo.get_by(DMConversation, user_a_id: a, user_b_id: b) do
    nil ->
      result =
        %DMConversation{}
        |> DMConversation.changeset(%{user_a_id: a, user_b_id: b})
        |> Repo.insert()

      case result do
        {:ok, dm} ->
          broadcast_new_dm(dm)
          {:ok, dm}

        error ->
          error
      end

    dm ->
      {:ok, dm}
  end
end

defp broadcast_new_dm(dm) do
  for user_id <- Enum.uniq([dm.user_a_id, dm.user_b_id]) do
    Phoenix.PubSub.broadcast(
      Slackex.PubSub,
      "user:#{user_id}",
      {:dm_conversation_new, dm}
    )
  end
end
```

**Step 4: Run test to verify it passes**

```bash
mix test test/slackex/chat_test.exs --seed 0 -v 2>&1 | grep -A 2 "PubSub"
```

Expected: PASS

**Step 5: Add LiveView handler for `:dm_conversation_new`**

In `lib/slackex_web/live/chat_live/index.ex`, add a new `handle_info` clause **above** the catch-all `handle_info(_msg, socket)` at line 282:

```elixir
@impl true
def handle_info({:dm_conversation_new, _dm}, socket) do
  user = socket.assigns.current_user
  dm_conversations = Chat.list_user_dm_conversations(user.id)
  {:noreply, assign(socket, :dm_conversations, dm_conversations)}
end
```

**Step 6: Run full test suite**

```bash
mix test
```

Expected: All tests pass.

**Step 7: Commit**

```bash
git add lib/slackex/chat/chat.ex lib/slackex_web/live/chat_live/index.ex test/slackex/chat_test.exs
git commit -m "feat: broadcast new DM conversations to both participants via PubSub"
```

---

## Task 4: Create `user_blocks` schema and migration

**Files:**
- Create: `priv/repo/migrations/TIMESTAMP_create_user_blocks.exs`
- Create: `lib/slackex/chat/user_block.ex`

**Step 1: Generate the migration**

```bash
mix ecto.gen.migration create_user_blocks
```

**Step 2: Write the migration**

```elixir
defmodule Slackex.Repo.Migrations.CreateUserBlocks do
  use Ecto.Migration

  def change do
    create table(:user_blocks) do
      add :blocker_id, references(:users, on_delete: :delete_all), null: false
      add :blocked_id, references(:users, on_delete: :delete_all), null: false
      add :reason, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:user_blocks, [:blocker_id, :blocked_id])
    create index(:user_blocks, [:blocked_id])
  end
end
```

**Step 3: Write the schema**

Create `lib/slackex/chat/user_block.ex`:

```elixir
defmodule Slackex.Chat.UserBlock do
  @moduledoc """
  Schema for user blocks. A block prevents the blocked user from
  sending DMs to (or being found by) the blocker.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "user_blocks" do
    belongs_to :blocker, Slackex.Accounts.User
    belongs_to :blocked, Slackex.Accounts.User

    field :reason, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(user_block, attrs) do
    user_block
    |> cast(attrs, [:blocker_id, :blocked_id, :reason])
    |> validate_required([:blocker_id, :blocked_id])
    |> validate_not_self_block()
    |> unique_constraint([:blocker_id, :blocked_id])
    |> foreign_key_constraint(:blocker_id)
    |> foreign_key_constraint(:blocked_id)
  end

  defp validate_not_self_block(changeset) do
    blocker_id = get_field(changeset, :blocker_id)
    blocked_id = get_field(changeset, :blocked_id)

    if blocker_id && blocked_id && blocker_id == blocked_id do
      add_error(changeset, :blocked_id, "cannot block yourself")
    else
      changeset
    end
  end
end
```

**Step 4: Run the migration**

```bash
mix ecto.migrate
```

Expected: Migration succeeds.

**Step 5: Commit**

```bash
git add priv/repo/migrations/*_create_user_blocks.exs lib/slackex/chat/user_block.ex
git commit -m "feat: add user_blocks schema and migration"
```

---

## Task 5: Add blocking context functions and tests

**Files:**
- Modify: `lib/slackex/chat/chat.ex`
- Create: `test/slackex/chat/user_block_test.exs`

**Step 1: Write the failing tests**

Create `test/slackex/chat/user_block_test.exs`:

```elixir
defmodule Slackex.Chat.UserBlockTest do
  use Slackex.DataCase, async: true

  alias Slackex.Chat

  describe "block_user/2" do
    test "blocks a user successfully" do
      alice = insert(:user)
      bob = insert(:user)

      assert {:ok, block} = Chat.block_user(alice.id, bob.id)
      assert block.blocker_id == alice.id
      assert block.blocked_id == bob.id
    end

    test "cannot block yourself" do
      alice = insert(:user)

      assert {:error, changeset} = Chat.block_user(alice.id, alice.id)
      assert %{blocked_id: ["cannot block yourself"]} = errors_on(changeset)
    end

    test "blocking same user twice returns error" do
      alice = insert(:user)
      bob = insert(:user)

      assert {:ok, _} = Chat.block_user(alice.id, bob.id)
      assert {:error, _} = Chat.block_user(alice.id, bob.id)
    end
  end

  describe "unblock_user/2" do
    test "unblocks a blocked user" do
      alice = insert(:user)
      bob = insert(:user)

      {:ok, _} = Chat.block_user(alice.id, bob.id)
      assert :ok = Chat.unblock_user(alice.id, bob.id)
      refute Chat.blocked?(alice.id, bob.id)
    end

    test "unblocking non-blocked user returns error" do
      alice = insert(:user)
      bob = insert(:user)

      assert {:error, :not_found} = Chat.unblock_user(alice.id, bob.id)
    end
  end

  describe "blocked?/2" do
    test "returns true when user is blocked" do
      alice = insert(:user)
      bob = insert(:user)

      Chat.block_user(alice.id, bob.id)
      assert Chat.blocked?(alice.id, bob.id)
    end

    test "returns false when user is not blocked" do
      alice = insert(:user)
      bob = insert(:user)

      refute Chat.blocked?(alice.id, bob.id)
    end

    test "blocking is directional" do
      alice = insert(:user)
      bob = insert(:user)

      Chat.block_user(alice.id, bob.id)
      assert Chat.blocked?(alice.id, bob.id)
      refute Chat.blocked?(bob.id, alice.id)
    end
  end

  describe "list_blocked_users/1" do
    test "returns all users blocked by a user" do
      alice = insert(:user)
      bob = insert(:user)
      charlie = insert(:user)

      Chat.block_user(alice.id, bob.id)
      Chat.block_user(alice.id, charlie.id)

      blocked = Chat.list_blocked_users(alice.id)
      blocked_ids = Enum.map(blocked, & &1.blocked_id)

      assert bob.id in blocked_ids
      assert charlie.id in blocked_ids
      assert length(blocked) == 2
    end
  end
end
```

**Step 2: Run test to verify it fails**

```bash
mix test test/slackex/chat/user_block_test.exs -v
```

Expected: FAIL — functions don't exist.

**Step 3: Add blocking functions to `lib/slackex/chat/chat.ex`**

Add the alias at the top (line 9):

```elixir
alias Slackex.Chat.{Channel, DMConversation, Message, Permissions, ReadCursor, Subscription, UserBlock}
```

Add a new section at the bottom of the module (before the closing `end`):

```elixir
# ---------------------------------------------------------------------------
# User blocking
# ---------------------------------------------------------------------------

@doc "Blocks a user. Returns `{:ok, block}` or `{:error, changeset}`."
def block_user(blocker_id, blocked_id) do
  %UserBlock{}
  |> UserBlock.changeset(%{blocker_id: blocker_id, blocked_id: blocked_id})
  |> Repo.insert()
end

@doc "Unblocks a user. Returns `:ok` or `{:error, :not_found}`."
def unblock_user(blocker_id, blocked_id) do
  case Repo.get_by(UserBlock, blocker_id: blocker_id, blocked_id: blocked_id) do
    nil -> {:error, :not_found}
    block -> Repo.delete(block) && :ok
  end
end

@doc "Returns true if `blocker_id` has blocked `blocked_id`."
def blocked?(blocker_id, blocked_id) do
  Repo.exists?(
    from(b in UserBlock,
      where: b.blocker_id == ^blocker_id and b.blocked_id == ^blocked_id
    )
  )
end

@doc "Returns all blocks created by a user."
def list_blocked_users(user_id) do
  Repo.all(from b in UserBlock, where: b.blocker_id == ^user_id)
end
```

**Step 4: Run test to verify it passes**

```bash
mix test test/slackex/chat/user_block_test.exs -v
```

Expected: All PASS.

**Step 5: Run full test suite**

```bash
mix test
```

Expected: All tests pass.

**Step 6: Commit**

```bash
git add lib/slackex/chat/chat.ex test/slackex/chat/user_block_test.exs
git commit -m "feat: add block_user, unblock_user, blocked?, list_blocked_users"
```

---

## Task 6: Enforce blocks in DM creation and user search

**Files:**
- Modify: `lib/slackex/chat/chat.ex` (function: `find_or_create_dm`)
- Modify: `lib/slackex/accounts/accounts.ex` (if user search exists, add block filtering)
- Test: `test/slackex/chat/user_block_test.exs`

**Step 1: Write the failing test**

Add to `test/slackex/chat/user_block_test.exs`:

```elixir
describe "block enforcement in DMs" do
  test "blocked user cannot create DM with blocker" do
    alice = insert(:user)
    bob = insert(:user)

    Chat.block_user(alice.id, bob.id)

    assert {:error, :blocked} = Chat.find_or_create_dm(bob.id, alice.id)
  end

  test "blocker cannot create DM with blocked user either" do
    alice = insert(:user)
    bob = insert(:user)

    Chat.block_user(alice.id, bob.id)

    assert {:error, :blocked} = Chat.find_or_create_dm(alice.id, bob.id)
  end
end
```

**Step 2: Run test to verify it fails**

```bash
mix test test/slackex/chat/user_block_test.exs -v 2>&1 | grep -A 2 "enforcement"
```

Expected: FAIL — `find_or_create_dm` returns `{:ok, dm}` regardless of blocks.

**Step 3: Add block check to `find_or_create_dm`**

Update `find_or_create_dm` in `lib/slackex/chat/chat.ex`:

```elixir
def find_or_create_dm(user_a_id, user_b_id) do
  {a, b} = if user_a_id < user_b_id, do: {user_a_id, user_b_id}, else: {user_b_id, user_a_id}

  # Check blocks in both directions (skip for self-DMs)
  if user_a_id != user_b_id and (blocked?(user_a_id, user_b_id) or blocked?(user_b_id, user_a_id)) do
    {:error, :blocked}
  else
    case Repo.get_by(DMConversation, user_a_id: a, user_b_id: b) do
      nil ->
        result =
          %DMConversation{}
          |> DMConversation.changeset(%{user_a_id: a, user_b_id: b})
          |> Repo.insert()

        case result do
          {:ok, dm} ->
            broadcast_new_dm(dm)
            {:ok, dm}

          error ->
            error
        end

      dm ->
        {:ok, dm}
    end
  end
end
```

**Step 4: Run test to verify it passes**

```bash
mix test test/slackex/chat/user_block_test.exs -v
```

Expected: All PASS.

**Step 5: Run full test suite**

```bash
mix test
```

Expected: All tests pass.

**Step 6: Commit**

```bash
git add lib/slackex/chat/chat.ex test/slackex/chat/user_block_test.exs
git commit -m "feat: enforce user blocks in DM creation (bidirectional)"
```

---

## Task 7: Add block UI to DM conversation header

**Files:**
- Modify: `lib/slackex_web/live/chat_live/index.ex` (add `handle_event` for block, add `handle_info` for block confirmation)
- Modify: `lib/slackex_web/live/chat_live/index.ex` (template: add block button to DM header)

**Step 1: Add block event handler to `index.ex`**

Add a new `handle_event` clause in the event handlers section:

```elixir
@impl true
def handle_event("block_user", _params, socket) do
  dm = socket.assigns.active_dm
  current_user = socket.assigns.current_user

  if dm do
    other_id = if dm.user_a_id == current_user.id, do: dm.user_b_id, else: dm.user_a_id

    case Chat.block_user(current_user.id, other_id) do
      {:ok, _block} ->
        dm_conversations = Chat.list_user_dm_conversations(current_user.id)

        {:noreply,
         socket
         |> assign(:dm_conversations, dm_conversations)
         |> assign(:active_dm, nil)
         |> put_flash(:info, "User blocked.")
         |> push_patch(to: ~p"/chat")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not block user.")}
    end
  else
    {:noreply, socket}
  end
end
```

**Step 2: Add block button to the DM conversation header in the template**

In the `render/1` function, find the DM section (around line 562) and update it:

```heex
<%= if @active_dm do %>
  <.conversation_header title={@page_title}>
    <:actions>
      <button
        phx-click="block_user"
        data-confirm="Block this user? You won't be able to message each other."
        class="btn btn-ghost btn-xs text-error/70 hover:text-error"
      >
        Block
      </button>
    </:actions>
  </.conversation_header>
  <.message_stream streams={@streams} current_user_id={@current_user.id} />
  <.typing_indicator users={MapSet.to_list(@typing_users)} />
  <.compose_area message_form={@message_form} placeholder={"Message #{@page_title}"} />
<% else %>
```

**Step 3: Verify the conversation_header component accepts an `:actions` slot**

Check `chat_components.ex` — the channel header already uses `<:actions>`. If the DM path doesn't pass it, the slot simply renders empty. No component changes needed.

**Step 4: Manual test**

1. Log in as davewil, open a DM with davewil2
2. Click "Block" button in the header
3. Confirm the browser dialog
4. Verify: redirected to `/chat`, DM removed from sidebar, flash shows "User blocked."
5. Try to create a new DM with davewil2 — should fail

**Step 5: Commit**

```bash
git add lib/slackex_web/live/chat_live/index.ex
git commit -m "feat: add block button to DM conversation header"
```

---

## Task 8: Filter blocked users from new DM user search

**Files:**
- Modify: `lib/slackex_web/live/chat_live/new_dm_modal.ex` (filter search results)
- Modify: `lib/slackex/accounts/accounts.ex` (add `search_users` option to exclude blocked)

**Step 1: Read the current user search function**

Check how `new_dm_modal.ex` searches for users. It likely calls an accounts function. Inspect and add a block filter.

**Step 2: Add block-aware user search**

In `lib/slackex/accounts/accounts.ex`, add or modify the search function to accept an `exclude_user_ids` option:

```elixir
def search_users(query, opts \\ []) do
  exclude_ids = Keyword.get(opts, :exclude_ids, [])

  from(u in User,
    where: ilike(u.username, ^"%#{query}%") or ilike(u.display_name, ^"%#{query}%"),
    where: u.id not in ^exclude_ids,
    limit: 10,
    order_by: [asc: u.username]
  )
  |> Repo.all()
end
```

**Step 3: In `new_dm_modal.ex`, get blocked user IDs and pass to search**

```elixir
def handle_event("search", %{"query" => query}, socket) do
  current_user = socket.assigns.current_user
  blocked_ids = Chat.list_blocked_user_ids(current_user.id)
  users = Accounts.search_users(query, exclude_ids: [current_user.id | blocked_ids])
  {:noreply, assign(socket, :search_results, users)}
end
```

**Step 4: Add `list_blocked_user_ids/1` to `lib/slackex/chat/chat.ex`**

```elixir
@doc "Returns a list of user IDs blocked by the given user."
def list_blocked_user_ids(user_id) do
  Repo.all(from b in UserBlock, where: b.blocker_id == ^user_id, select: b.blocked_id)
end
```

**Step 5: Test manually and run full suite**

```bash
mix test
```

Expected: All tests pass.

**Step 6: Commit**

```bash
git add lib/slackex/chat/chat.ex lib/slackex/accounts/accounts.ex lib/slackex_web/live/chat_live/new_dm_modal.ex
git commit -m "feat: filter blocked users from DM search results"
```

---

## Task 9: Add factory and update test helpers

**Files:**
- Modify: `test/support/factory.ex`

**Step 1: Add `user_block_factory`**

```elixir
def user_block_factory do
  blocker = insert(:user)
  blocked = insert(:user)

  %Slackex.Chat.UserBlock{
    blocker: blocker,
    blocker_id: blocker.id,
    blocked: blocked,
    blocked_id: blocked.id
  }
end
```

**Step 2: Commit**

```bash
git add test/support/factory.ex
git commit -m "test: add user_block factory"
```

---

## Task 10: Final integration verification

**Step 1: Run full test suite**

```bash
mix test
```

Expected: All tests pass, zero failures.

**Step 2: Manual integration test**

1. Start the server: `mix phx.server`
2. Open two browser windows (or incognito), log in as two different users
3. User A: click "+ New Message", search for User B, send a message
4. User B: verify the DM appears in their sidebar in real-time (no page refresh)
5. User B: open the DM, verify messages appear
6. User B: click "Block" on User A
7. User B: verify User A no longer appears in DM search
8. User A: try to DM User B again — verify it fails

**Step 3: Final commit if any cleanup needed**

```bash
git add -A
git commit -m "chore: phase 1 DM safety integration cleanup"
```

---

## Phase 2-5 Outline (future plans)

Phase 2-5 will each get their own detailed implementation plan following the same task structure. See `docs/plans/2026-02-27-dm-safety-system-design.md` for the full design.

**Phase 2:** DM Request/Accept Flow — `dm_requests` table, `user_trust_scores` table, "Message Requests" sidebar section, graduated enforcement
**Phase 3:** Reporting & Trust Escalation — `abuse_reports` table, report modal, IP metadata capture, auto-escalation
**Phase 4:** Privacy Controls & Admin Foundation — `dm_preference` on users, settings UI, blocked users management, basic admin view
**Phase 5:** Admin Dashboard & Ban Evasion — admin actions, IP pattern detection, per-channel trust settings, audit log
