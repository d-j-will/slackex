# Phase 5 Steps 6-10 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add reactions, threads, channel member management, pinned messages, invite links, and quick switcher to the Slackex messaging UI.

**Architecture:** Each feature follows the established pattern: migration -> schema -> Chat context functions -> Messaging facade (where needed) -> LiveView events/handlers -> UI components. Tests use ExMachina factories (`Slackex.Factory`) and `DataCase` for context tests, `ConnCase` for LiveView tests.

**Tech Stack:** Elixir/Phoenix LiveView, Ecto, PostgreSQL, PubSub envelopes (`Slackex.Messaging.Envelope`), daisyUI/Tailwind CSS, emoji-mart (npm)

**Key patterns in this codebase:**
- Messages use Snowflake IDs (`@primary_key {:id, :integer, autogenerate: false}`)
- Content is encrypted via `Slackex.Encrypted.Binary` with a plaintext `search_content` companion
- PubSub broadcasts use `{:envelope, envelope}` tuples built by `Envelope.wrap/3`
- `BatchWriter` uses raw `Repo.insert_all` bypassing changesets for efficiency
- `ChannelServer` maintains an in-memory `:queue` of recent messages
- Boundary module (`use Boundary`) controls cross-context imports — new schemas must be exported
- Factory IDs use `unique_bigint_id()` (not real Snowflakes)

---

## Task 1: Reactions — Migration & Schema

**Files:**
- Create: `priv/repo/migrations/*_create_message_reactions.exs`
- Create: `lib/slackex/chat/message_reaction.ex`
- Modify: `lib/slackex/chat/chat.ex` (Boundary exports, line ~8-20)
- Create: `test/slackex/chat/message_reaction_test.exs`

**Step 1: Create migration**

Run: `mix ecto.gen.migration create_message_reactions`

Then replace contents:

```elixir
defmodule Slackex.Repo.Migrations.CreateMessageReactions do
  use Ecto.Migration

  def change do
    create table(:message_reactions) do
      add :message_id, :bigint, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :emoji, :string, null: false, size: 50

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:message_reactions, [:message_id, :user_id, :emoji])
    create index(:message_reactions, [:message_id])
  end
end
```

Note: `message_id` is a plain `:bigint` (not a `references`) because `messages.id` is a Snowflake bigint PK and FK references to it require matching types. The application layer enforces referential integrity.

**Step 2: Create schema**

Create `lib/slackex/chat/message_reaction.ex`:

```elixir
defmodule Slackex.Chat.MessageReaction do
  use Ecto.Schema
  import Ecto.Changeset

  schema "message_reactions" do
    field :emoji, :string

    belongs_to :message, Slackex.Chat.Message
    belongs_to :user, Slackex.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(reaction, attrs) do
    reaction
    |> cast(attrs, [:message_id, :user_id, :emoji])
    |> validate_required([:message_id, :user_id, :emoji])
    |> validate_length(:emoji, max: 50)
    |> unique_constraint([:message_id, :user_id, :emoji])
  end
end
```

**Step 3: Add to Boundary exports**

In `lib/slackex/chat/chat.ex`, add `MessageReaction` to the exports list (~line 8-20) and add to the alias block (~line 27-30):

```elixir
# In exports list:
exports: [
  Channel,
  Message,
  MessageReaction,  # <-- add
  # ... rest
]

# In alias block:
alias Slackex.Chat.{
  # ... existing aliases
  MessageReaction,
  # ... rest
}
```

**Step 4: Add factory**

In `test/support/factory.ex`, add alias and factory:

```elixir
# Add to alias block at top:
alias Slackex.Chat.MessageReaction

# Add factory:
def message_reaction_factory do
  %MessageReaction{
    emoji: "👍",
    user: build(:user),
    message: build(:message)
  }
end
```

**Step 5: Write schema test**

Create `test/slackex/chat/message_reaction_test.exs`:

```elixir
defmodule Slackex.Chat.MessageReactionTest do
  use Slackex.DataCase, async: true

  alias Slackex.Chat.MessageReaction

  import Slackex.Factory

  describe "changeset/2" do
    test "valid with all required fields" do
      user = insert(:user)
      channel = insert(:channel)
      message = insert(:message, sender: user, channel: channel)

      changeset =
        MessageReaction.changeset(%MessageReaction{}, %{
          message_id: message.id,
          user_id: user.id,
          emoji: "👍"
        })

      assert changeset.valid?
    end

    test "invalid without required fields" do
      changeset = MessageReaction.changeset(%MessageReaction{}, %{})
      refute changeset.valid?
      assert errors_on(changeset) |> Map.has_key?(:message_id)
      assert errors_on(changeset) |> Map.has_key?(:user_id)
      assert errors_on(changeset) |> Map.has_key?(:emoji)
    end

    test "enforces unique constraint on message_id + user_id + emoji" do
      user = insert(:user)
      channel = insert(:channel)
      message = insert(:message, sender: user, channel: channel)

      insert(:message_reaction, message: message, user: user, emoji: "👍")

      {:error, changeset} =
        %MessageReaction{}
        |> MessageReaction.changeset(%{message_id: message.id, user_id: user.id, emoji: "👍"})
        |> Repo.insert()

      assert errors_on(changeset) |> Map.has_key?(:message_id)
    end

    test "same user can react with different emojis" do
      user = insert(:user)
      channel = insert(:channel)
      message = insert(:message, sender: user, channel: channel)

      insert(:message_reaction, message: message, user: user, emoji: "👍")

      {:ok, _} =
        %MessageReaction{}
        |> MessageReaction.changeset(%{message_id: message.id, user_id: user.id, emoji: "❤️"})
        |> Repo.insert()
    end
  end
end
```

**Step 6: Run migration and tests**

Run: `mix ecto.migrate && mix test test/slackex/chat/message_reaction_test.exs`
Expected: Migration applies, all tests pass

**Step 7: Commit**

```
feat(chat): add MessageReaction schema and migration
```

---

## Task 2: Reactions — Backend Functions

**Files:**
- Modify: `lib/slackex/chat/chat.ex`
- Create: `test/slackex/chat/reactions_test.exs`

**Step 1: Write failing test**

Create `test/slackex/chat/reactions_test.exs`:

```elixir
defmodule Slackex.Chat.ReactionsTest do
  use Slackex.DataCase, async: true

  alias Slackex.Chat

  import Slackex.Factory

  setup do
    user = insert(:user)
    other_user = insert(:user)
    channel = insert(:channel) |> with_subscription(user)
    message = insert(:message, sender: user, channel: channel)
    %{user: user, other_user: other_user, channel: channel, message: message}
  end

  describe "toggle_reaction/3" do
    test "adds a reaction when none exists", %{user: user, message: message} do
      assert {:ok, {:added, reaction}} = Chat.toggle_reaction(message.id, user.id, "👍")
      assert reaction.emoji == "👍"
      assert reaction.user_id == user.id
      assert reaction.message_id == message.id
    end

    test "removes a reaction when it already exists", %{user: user, message: message} do
      {:ok, {:added, _}} = Chat.toggle_reaction(message.id, user.id, "👍")
      assert {:ok, {:removed, _}} = Chat.toggle_reaction(message.id, user.id, "👍")
    end

    test "different users can react with same emoji", %{
      user: user,
      other_user: other_user,
      message: message
    } do
      {:ok, {:added, _}} = Chat.toggle_reaction(message.id, user.id, "👍")
      {:ok, {:added, _}} = Chat.toggle_reaction(message.id, other_user.id, "👍")
    end
  end

  describe "list_reactions/1" do
    test "returns grouped reactions by message_id", %{
      user: user,
      other_user: other_user,
      message: message
    } do
      {:ok, {:added, _}} = Chat.toggle_reaction(message.id, user.id, "👍")
      {:ok, {:added, _}} = Chat.toggle_reaction(message.id, other_user.id, "👍")
      {:ok, {:added, _}} = Chat.toggle_reaction(message.id, user.id, "❤️")

      result = Chat.list_reactions([message.id])

      assert Map.has_key?(result, message.id)
      reactions = result[message.id]

      thumbs = Enum.find(reactions, &(&1.emoji == "👍"))
      assert thumbs.count == 2
      assert Enum.sort(thumbs.user_ids) == Enum.sort([user.id, other_user.id])

      heart = Enum.find(reactions, &(&1.emoji == "❤️"))
      assert heart.count == 1
    end

    test "returns empty map for no reactions" do
      assert Chat.list_reactions([]) == %{}
    end

    test "returns empty map for messages with no reactions", %{message: message} do
      result = Chat.list_reactions([message.id])
      assert result == %{}
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/slackex/chat/reactions_test.exs`
Expected: FAIL — `toggle_reaction` and `list_reactions` not defined

**Step 3: Implement in chat.ex**

Add to `lib/slackex/chat/chat.ex` (after the message edit/delete section, before DM operations):

```elixir
  # ---------------------------------------------------------------------------
  # Reactions
  # ---------------------------------------------------------------------------

  @doc """
  Toggles a reaction on a message. If the user has already reacted with
  this emoji, removes it. Otherwise, adds it.
  Returns `{:ok, {:added, reaction}}` or `{:ok, {:removed, reaction}}`.
  """
  def toggle_reaction(message_id, user_id, emoji) do
    case Repo.get_by(MessageReaction, message_id: message_id, user_id: user_id, emoji: emoji) do
      nil ->
        %MessageReaction{}
        |> MessageReaction.changeset(%{message_id: message_id, user_id: user_id, emoji: emoji})
        |> Repo.insert()
        |> case do
          {:ok, reaction} -> {:ok, {:added, reaction}}
          {:error, changeset} -> {:error, changeset}
        end

      reaction ->
        case Repo.delete(reaction) do
          {:ok, deleted} -> {:ok, {:removed, deleted}}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @doc """
  Batch-loads reactions for a list of message IDs.
  Returns `%{message_id => [%{emoji: "...", count: N, user_ids: [...]}]}`.
  """
  def list_reactions([]), do: %{}

  def list_reactions(message_ids) when is_list(message_ids) do
    from(r in MessageReaction,
      where: r.message_id in ^message_ids,
      group_by: [r.message_id, r.emoji],
      select: %{
        message_id: r.message_id,
        emoji: r.emoji,
        count: count(),
        user_ids: fragment("array_agg(?)", r.user_id)
      }
    )
    |> Repo.all()
    |> Enum.group_by(& &1.message_id)
  end
```

**Step 4: Run tests**

Run: `mix test test/slackex/chat/reactions_test.exs`
Expected: All pass

**Step 5: Commit**

```
feat(chat): add toggle_reaction and list_reactions functions
```

---

## Task 3: Reactions — Messaging Facade & PubSub

**Files:**
- Modify: `lib/slackex/messaging/messaging.ex`
- Modify: `lib/slackex_web/live/chat_live/index.ex`
- Modify: `lib/slackex_web/components/chat_components.ex`

**Step 1: Add facade function to messaging.ex**

Add after `delete_message/3` (~line 104):

```elixir
  @doc """
  Toggles a reaction on a message. Delegates to `Chat.toggle_reaction/3`,
  then broadcasts `{:envelope, %{event: "reaction.toggled"}}`.
  """
  def toggle_reaction(message_id, user_id, emoji) do
    with {:ok, message} <- Chat.get_message(message_id),
         {:ok, result} <- Chat.toggle_reaction(message_id, user_id, emoji) do
      target = message_target(message)
      {action, reaction} = result

      payload = %{
        message_id: message_id,
        emoji: emoji,
        user_id: user_id,
        action: action
      }

      _ = broadcast_envelope("reaction.toggled", target, payload)

      {:ok, {action, reaction}}
    end
  end
```

**Step 2: Add `reaction_bar/1` component to chat_components.ex**

Add after the existing message-related components:

```elixir
  attr :reactions, :list, default: []
  attr :current_user_id, :integer, required: true
  attr :message_id, :integer, required: true

  def reaction_bar(assigns) do
    ~H"""
    <div :if={@reactions != []} class="flex flex-wrap gap-1 mt-1">
      <button
        :for={reaction <- @reactions}
        phx-click="toggle_reaction"
        phx-value-message-id={@message_id}
        phx-value-emoji={reaction.emoji}
        class={[
          "inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs border",
          "hover:bg-base-300 transition-colors cursor-pointer",
          if(@current_user_id in reaction.user_ids,
            do: "border-primary bg-primary/10 text-primary",
            else: "border-base-300 bg-base-200 text-base-content"
          )
        ]}
      >
        <span>{reaction.emoji}</span>
        <span class="font-medium">{reaction.count}</span>
      </button>
    </div>
    """
  end
```

**Step 3: Add reaction state and handlers to index.ex**

In `mount/3`, add after the `:editing_message_id` assign (~line 83):

```elixir
|> assign(:reactions, %{})
```

In the `enter_channel` / `enter_dm` private functions, after loading messages, load reactions:

```elixir
# After messages are loaded, get their IDs and batch-load reactions:
message_ids = messages |> Enum.map(& &1.id)
reactions = Chat.list_reactions(message_ids)
|> assign(:reactions, reactions)
```

Add event handler:

```elixir
  def handle_event("toggle_reaction", %{"message-id" => msg_id, "emoji" => emoji}, socket) do
    message_id = String.to_integer(msg_id)
    user_id = socket.assigns.current_user.id

    case Messaging.toggle_reaction(message_id, user_id, emoji) do
      {:ok, _} -> {:noreply, socket}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not react.")}
    end
  end
```

Add PubSub handler:

```elixir
  def handle_info({:envelope, %{event: "reaction.toggled", payload: payload}}, socket) do
    reactions = socket.assigns.reactions
    msg_id = payload.message_id

    current_reactions = Map.get(reactions, msg_id, [])

    updated_reactions =
      case payload.action do
        :added ->
          case Enum.find_index(current_reactions, &(&1.emoji == payload.emoji)) do
            nil ->
              [%{emoji: payload.emoji, count: 1, user_ids: [payload.user_id]} | current_reactions]

            idx ->
              List.update_at(current_reactions, idx, fn r ->
                %{r | count: r.count + 1, user_ids: [payload.user_id | r.user_ids]}
              end)
          end

        :removed ->
          current_reactions
          |> Enum.map(fn r ->
            if r.emoji == payload.emoji do
              %{r | count: r.count - 1, user_ids: List.delete(r.user_ids, payload.user_id)}
            else
              r
            end
          end)
          |> Enum.reject(&(&1.count <= 0))
      end

    {:noreply, assign(socket, :reactions, Map.put(reactions, msg_id, updated_reactions))}
  end
```

**Step 4: Add reaction_bar to message rendering in index.ex template**

In the message rendering section, after message content, add:

```heex
<.reaction_bar
  reactions={Map.get(@reactions, message.id, [])}
  current_user_id={@current_user.id}
  message_id={message.id}
/>
```

**Step 5: Run full test suite**

Run: `mix test`
Expected: All existing + new tests pass

**Step 6: Commit**

```
feat(chat): add reactions UI with toggle and real-time broadcast
```

---

## Task 4: Reactions — Emoji Picker (JS)

**Files:**
- Create: `assets/js/hooks/emoji_picker.js`
- Modify: `assets/js/app.js`
- Modify: `assets/package.json`

**Step 1: Install emoji-mart**

Run: `cd assets && npm install emoji-mart @emoji-mart/data`

**Step 2: Create emoji picker hook**

Create `assets/js/hooks/emoji_picker.js`:

```javascript
const EmojiPicker = {
  mounted() {
    this.pickerContainer = null;

    this.handleDocumentClick = (e) => {
      if (this.pickerContainer && !this.pickerContainer.contains(e.target) &&
          !e.target.closest("[data-emoji-trigger]")) {
        this.closePicker();
      }
    };

    document.addEventListener("click", this.handleDocumentClick);
  },

  destroyed() {
    this.closePicker();
    document.removeEventListener("click", this.handleDocumentClick);
  },

  async openPicker(trigger) {
    if (this.pickerContainer) {
      this.closePicker();
      return;
    }

    const messageId = trigger.dataset.messageId;

    // Dynamic import to avoid loading emoji-mart until needed
    const [{ default: data }, { Picker }] = await Promise.all([
      import("@emoji-mart/data"),
      import("emoji-mart"),
    ]);

    const container = document.createElement("div");
    container.className = "absolute z-50 bottom-full right-0 mb-2";

    const picker = new Picker({
      data,
      onEmojiSelect: (emoji) => {
        this.pushEvent("toggle_reaction", {
          "message-id": messageId,
          emoji: emoji.native,
        });
        this.closePicker();
      },
      theme: document.documentElement.getAttribute("data-theme") === "dark" ? "dark" : "light",
      previewPosition: "none",
      skinTonePosition: "none",
      maxFrequentRows: 2,
    });

    container.appendChild(picker);
    trigger.closest(".relative").appendChild(container);
    this.pickerContainer = container;
  },

  closePicker() {
    if (this.pickerContainer) {
      this.pickerContainer.remove();
      this.pickerContainer = null;
    }
  },
};

export default EmojiPicker;
```

**Step 3: Register hook in app.js**

In `assets/js/app.js`, import and add to hooks:

```javascript
import EmojiPicker from "./hooks/emoji_picker";

// In hooks object:
const hooks = {
  // ... existing hooks
  EmojiPicker,
};
```

**Step 4: Add emoji trigger button to message hover actions in chat_components.ex**

In the message bubble hover actions area, add:

```heex
<div id={"emoji-picker-#{@message.id}"} phx-hook="EmojiPicker" class="relative">
  <button
    data-emoji-trigger
    data-message-id={@message.id}
    phx-click={JS.dispatch("emoji:open", to: "#emoji-picker-#{@message.id}")}
    class="btn btn-ghost btn-xs btn-circle"
    title="Add reaction"
  >
    <span class="hero-face-smile size-4" />
  </button>
</div>
```

Update the hook's `mounted()` to listen for the custom event:

```javascript
mounted() {
  // ... existing code
  this.el.addEventListener("emoji:open", (e) => {
    const trigger = this.el.querySelector("[data-emoji-trigger]");
    if (trigger) this.openPicker(trigger);
  });
},
```

**Step 5: Build assets and verify**

Run: `cd assets && npm run build`
Expected: Build succeeds with no errors

**Step 6: Manual smoke test**

Run: `mix phx.server`
- Hover a message -> click smiley icon -> emoji picker opens
- Select an emoji -> reaction pill appears below message
- Click the reaction pill -> toggles it
- Another user sees the reaction in real-time

**Step 7: Commit**

```
feat(ui): add emoji picker for message reactions
```

---

## Task 5: Threads — Migration & Schema

**Files:**
- Create: `priv/repo/migrations/*_add_threads_to_messages.exs`
- Modify: `lib/slackex/chat/message.ex`

**Step 1: Create migration**

Run: `mix ecto.gen.migration add_threads_to_messages`

```elixir
defmodule Slackex.Repo.Migrations.AddThreadsToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :parent_message_id, :bigint
      add :reply_count, :integer, default: 0, null: false
    end

    create index(:messages, [:parent_message_id], where: "parent_message_id IS NOT NULL")
  end
end
```

Note: `parent_message_id` is a plain `:bigint` (not a reference) because messages use Snowflake IDs.

**Step 2: Add fields to message.ex**

In `lib/slackex/chat/message.ex`, add after the `deleted_at` field (~line 17):

```elixir
    field :parent_message_id, :integer
    field :reply_count, :integer, default: 0
```

Update the `changeset/2` function's cast list to include `:parent_message_id`:

```elixir
    |> cast(attrs, [:id, :content, :sender_id, :channel_id, :dm_conversation_id, :edited_at, :parent_message_id])
```

**Step 3: Run migration and compile**

Run: `mix ecto.migrate && mix compile --warnings-as-errors`
Expected: Both succeed

**Step 4: Commit**

```
feat(chat): add thread fields to messages schema
```

---

## Task 6: Threads — Backend Functions

**Files:**
- Modify: `lib/slackex/chat/chat.ex`
- Create: `test/slackex/chat/threads_test.exs`

**Step 1: Write failing test**

Create `test/slackex/chat/threads_test.exs`:

```elixir
defmodule Slackex.Chat.ThreadsTest do
  use Slackex.DataCase, async: true

  alias Slackex.Chat

  import Slackex.Factory

  setup do
    user = insert(:user)
    replier = insert(:user)
    channel = insert(:channel) |> with_subscription(user) |> with_subscription(replier)
    parent = insert(:message, sender: user, channel: channel)
    %{user: user, replier: replier, channel: channel, parent: parent}
  end

  describe "send_reply/4" do
    test "creates a reply linked to parent", %{replier: replier, channel: channel, parent: parent} do
      {:ok, reply} = Chat.send_reply(channel.id, replier.id, parent.id, "A reply")

      assert reply.parent_message_id == parent.id
      assert reply.content == "A reply"
      assert reply.channel_id == channel.id
    end

    test "increments parent reply_count atomically", %{
      replier: replier,
      channel: channel,
      parent: parent
    } do
      {:ok, _} = Chat.send_reply(channel.id, replier.id, parent.id, "Reply 1")
      {:ok, _} = Chat.send_reply(channel.id, replier.id, parent.id, "Reply 2")

      updated_parent = Chat.get_message!(parent.id)
      assert updated_parent.reply_count == 2
    end

    test "returns error for invalid parent channel", %{replier: replier} do
      other_channel = insert(:channel)
      other_msg = insert(:message, sender: replier, channel: other_channel)

      result = Chat.send_reply(other_channel.id + 999, replier.id, other_msg.id, "Bad")
      assert {:error, _} = result
    end
  end

  describe "list_thread/2" do
    test "returns replies ordered by insertion time", %{
      replier: replier,
      channel: channel,
      parent: parent
    } do
      {:ok, r1} = Chat.send_reply(channel.id, replier.id, parent.id, "First")
      {:ok, r2} = Chat.send_reply(channel.id, replier.id, parent.id, "Second")

      replies = Chat.list_thread(parent.id)
      assert length(replies) == 2
      assert hd(replies).id == r1.id
      assert List.last(replies).id == r2.id
    end

    test "excludes soft-deleted replies", %{
      user: user,
      replier: replier,
      channel: channel,
      parent: parent
    } do
      {:ok, reply} = Chat.send_reply(channel.id, replier.id, parent.id, "To delete")
      {:ok, _} = Chat.delete_message(reply.id, replier.id)

      replies = Chat.list_thread(parent.id)
      assert replies == []
    end

    test "returns empty list for message with no replies", %{parent: parent} do
      assert Chat.list_thread(parent.id) == []
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/slackex/chat/threads_test.exs`
Expected: FAIL — `send_reply` and `list_thread` not defined

**Step 3: Implement in chat.ex**

Add to `lib/slackex/chat/chat.ex` (after the reactions section):

```elixir
  # ---------------------------------------------------------------------------
  # Threads
  # ---------------------------------------------------------------------------

  @doc """
  Sends a reply to a parent message. Creates the reply message and
  atomically increments the parent's reply_count.

  Returns `{:ok, message}` or `{:error, reason}`.
  """
  def send_reply(channel_id, sender_id, parent_message_id, content) do
    parent = get_message!(parent_message_id)

    parent_channel_id = parent.channel_id
    parent_dm_id = parent.dm_conversation_id

    target_matches =
      (parent_channel_id != nil and parent_channel_id == channel_id) or
        (parent_dm_id != nil and parent_dm_id == channel_id)

    unless target_matches do
      {:error, :invalid_parent}
    else
      id = Slackex.Infrastructure.Snowflake.generate()
      sanitized = HtmlSanitizeEx.strip_tags(content)

      attrs = %{
        id: id,
        content: sanitized,
        sender_id: sender_id,
        channel_id: parent.channel_id,
        dm_conversation_id: parent.dm_conversation_id,
        parent_message_id: parent_message_id
      }

      Multi.new()
      |> Multi.insert(:reply, Message.changeset(%Message{}, attrs))
      |> Multi.update_all(
        :increment_reply_count,
        from(m in Message, where: m.id == ^parent_message_id),
        inc: [reply_count: 1]
      )
      |> Repo.transaction()
      |> case do
        {:ok, %{reply: reply}} -> {:ok, Repo.preload(reply, :sender)}
        {:error, :reply, changeset, _} -> {:error, changeset}
      end
    end
  end

  @doc """
  Lists replies to a parent message, ordered by insertion time ascending.
  Excludes soft-deleted replies.
  """
  def list_thread(parent_message_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(m in Message,
      where: m.parent_message_id == ^parent_message_id,
      where: is_nil(m.deleted_at),
      order_by: [asc: m.id],
      limit: ^limit,
      preload: [:sender]
    )
    |> Repo.all()
  end
```

**Step 4: Run tests**

Run: `mix test test/slackex/chat/threads_test.exs`
Expected: All pass

**Step 5: Commit**

```
feat(chat): add send_reply and list_thread functions
```

---

## Task 7: Threads — Messaging Facade, BatchWriter, Routes

**Files:**
- Modify: `lib/slackex/messaging/messaging.ex`
- Modify: `lib/slackex/pipeline/batch_writer.ex` (~line 98-109, `to_row/1`)
- Modify: `lib/slackex/messaging/channel_server.ex` (~line 127-182, `send_message` handle_call)
- Modify: `lib/slackex_web/router.ex`

**Step 1: Add parent_message_id to BatchWriter's to_row**

In `lib/slackex/pipeline/batch_writer.ex`, update `to_row/1` (~line 98-109):

```elixir
  defp to_row(%{id: id, content: content, sender_id: sender_id} = message) do
    timestamp_ms = Snowflake.extract_timestamp(id)
    inserted_at = DateTime.from_unix!(timestamp_ms * @milliseconds_to_microseconds, :microsecond)

    %{
      id: id,
      content: content,
      sender_id: sender_id,
      channel_id: Map.get(message, :channel_id),
      dm_conversation_id: Map.get(message, :dm_conversation_id),
      parent_message_id: Map.get(message, :parent_message_id),
      inserted_at: inserted_at
    }
  end
```

**Step 2: Add thread route to router.ex**

In `lib/slackex_web/router.ex`, add before the `live "/chat/:slug"` line (~line 73):

```elixir
      live "/chat/:slug/thread/:message_id", ChatLive.Index, :thread
```

**Step 3: Add send_reply facade to messaging.ex**

Add after `toggle_reaction/3`:

```elixir
  @doc """
  Sends a reply to a parent message. Broadcasts to both the channel topic
  and the thread topic.
  """
  def send_reply(channel_id, channel_type, sender_id, parent_message_id, content) do
    with {:ok, reply} <- Chat.send_reply(channel_id, sender_id, parent_message_id, content) do
      target = {channel_type, channel_id}

      reply_payload = %{
        id: reply.id,
        content: reply.content,
        sender_id: reply.sender_id,
        sender: %{
          id: reply.sender.id,
          username: reply.sender.username,
          display_name: reply.sender.display_name,
          avatar_url: reply.sender.avatar_url
        },
        inserted_at: reply.inserted_at,
        parent_message_id: parent_message_id,
        channel_id: reply.channel_id,
        dm_conversation_id: reply.dm_conversation_id
      }

      # Broadcast to channel/DM topic
      _ = broadcast_envelope("message.new", target, reply_payload)

      # Broadcast to thread-specific topic
      thread_envelope =
        Envelope.wrap("thread.reply", target, reply_payload)

      _ =
        Phoenix.PubSub.broadcast(
          @pubsub,
          "thread:#{parent_message_id}",
          {:envelope, thread_envelope}
        )

      # Broadcast reply_count update
      parent = Chat.get_message!(parent_message_id)

      _ =
        broadcast_envelope("message.reply_count_updated", target, %{
          message_id: parent_message_id,
          reply_count: parent.reply_count
        })

      {:ok, reply}
    end
  end
```

**Step 4: Compile and run existing tests**

Run: `mix compile --warnings-as-errors && mix test`
Expected: All pass

**Step 5: Commit**

```
feat(messaging): add thread reply facade and BatchWriter support
```

---

## Task 8: Threads — Thread Panel UI

**Files:**
- Create: `lib/slackex_web/live/chat_live/thread_panel_component.ex`
- Modify: `lib/slackex_web/live/chat_live/index.ex`
- Modify: `lib/slackex_web/components/chat_components.ex`

**Step 1: Create ThreadPanelComponent**

Create `lib/slackex_web/live/chat_live/thread_panel_component.ex`:

```elixir
defmodule SlackexWeb.ChatLive.ThreadPanelComponent do
  use SlackexWeb, :live_component

  alias Slackex.Chat

  import SlackexWeb.ChatComponents

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:replies, [])
     |> assign(:reply_form, to_form(%{"content" => ""}, as: :reply))}
  end

  @impl true
  def update(%{new_reply: reply}, socket) do
    {:ok, assign(socket, :replies, socket.assigns.replies ++ [reply])}
  end

  def update(assigns, socket) do
    replies = Chat.list_thread(assigns.parent_message.id)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:replies, replies)}
  end

  @impl true
  def handle_event("send_reply", %{"reply" => %{"content" => content}}, socket) do
    if String.trim(content) != "" do
      send(self(), {:send_thread_reply, socket.assigns.parent_message.id, content})
    end

    {:noreply, assign(socket, :reply_form, to_form(%{"content" => ""}, as: :reply))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class={[
      "flex flex-col border-l border-base-300 bg-base-100",
      "w-full md:w-[400px] h-full"
    ]}>
      <%!-- Header --%>
      <div class="flex items-center justify-between px-4 py-3 border-b border-base-300">
        <h3 class="font-semibold text-sm">Thread</h3>
        <button
          phx-click="close_thread"
          class="btn btn-ghost btn-sm btn-square"
        >
          <span class="hero-x-mark size-5" />
        </button>
      </div>

      <%!-- Parent message --%>
      <div class="px-4 py-3 border-b border-base-300 bg-base-200/50">
        <.message_bubble
          message={@parent_message}
          current_user_id={@current_user.id}
          show_hover_actions={false}
        />
      </div>

      <%!-- Replies --%>
      <div class="flex-1 overflow-y-auto px-4 py-2 space-y-2">
        <div :if={@replies == []} class="text-center text-base-content/50 py-8 text-sm">
          No replies yet. Start the conversation!
        </div>
        <.message_bubble
          :for={reply <- @replies}
          message={reply}
          current_user_id={@current_user.id}
          show_hover_actions={false}
        />
      </div>

      <%!-- Reply compose --%>
      <div class="px-4 py-3 border-t border-base-300">
        <.form
          for={@reply_form}
          phx-submit="send_reply"
          phx-target={@myself}
        >
          <div class="flex gap-2">
            <textarea
              name="reply[content]"
              value={@reply_form[:content].value}
              placeholder="Reply..."
              class="textarea textarea-bordered textarea-sm flex-1 min-h-[36px] max-h-[120px] resize-none"
              rows="1"
              phx-hook="Compose"
              id={"thread-compose-#{@parent_message.id}"}
            />
            <button type="submit" class="btn btn-primary btn-sm self-end">
              <span class="hero-paper-airplane size-4" />
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end
end
```

**Step 2: Add thread state and handlers to index.ex**

In `mount/3`, add assigns:

```elixir
|> assign(:thread_parent, nil)
```

Add `handle_params` clause for `:thread` action:

```elixir
  def handle_params(
        %{"slug" => slug, "message_id" => message_id},
        _uri,
        %{assigns: %{live_action: :thread}} = socket
      ) do
    channel = Chat.get_channel_by_slug!(slug)
    parent = Chat.get_message!(String.to_integer(message_id))

    # Subscribe to thread topic
    _ = Phoenix.PubSub.subscribe(Slackex.PubSub, "thread:#{parent.id}")

    socket =
      socket
      |> maybe_enter_channel(channel)
      |> assign(:thread_parent, parent)

    {:noreply, socket}
  end
```

Add event handlers:

```elixir
  def handle_event("close_thread", _params, socket) do
    if socket.assigns.thread_parent do
      _ = Phoenix.PubSub.unsubscribe(Slackex.PubSub, "thread:#{socket.assigns.thread_parent.id}")
    end

    slug = socket.assigns.active_channel.slug
    {:noreply, socket |> assign(:thread_parent, nil) |> push_patch(to: ~p"/chat/#{slug}")}
  end

  def handle_event("open_thread", %{"message-id" => msg_id}, socket) do
    slug = socket.assigns.active_channel.slug
    {:noreply, push_patch(socket, to: ~p"/chat/#{slug}/thread/#{msg_id}")}
  end
```

Add `handle_info` for thread reply sending:

```elixir
  def handle_info({:send_thread_reply, parent_id, content}, socket) do
    user = socket.assigns.current_user
    {type, id} = active_target(socket)

    case Messaging.send_reply(id, type, user.id, parent_id, content) do
      {:ok, _reply} -> {:noreply, socket}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not send reply.")}
    end
  end
```

Add PubSub handler for thread replies:

```elixir
  def handle_info({:envelope, %{event: "thread.reply", payload: payload}}, socket) do
    if socket.assigns.thread_parent &&
         socket.assigns.thread_parent.id == payload.parent_message_id do
      send_update(SlackexWeb.ChatLive.ThreadPanelComponent,
        id: "thread-panel",
        new_reply: payload
      )
    end

    {:noreply, socket}
  end

  def handle_info({:envelope, %{event: "message.reply_count_updated", payload: payload}}, socket) do
    # Update the reply_count on the message in the stream
    {:noreply, update_message_in_stream(socket, payload.message_id, %{reply_count: payload.reply_count})}
  end
```

**Step 3: Add thread indicator to message_bubble and reply button**

In `chat_components.ex`, add to the message bubble's hover actions:

```heex
<button
  :if={@show_hover_actions}
  phx-click="open_thread"
  phx-value-message-id={@message.id}
  class="btn btn-ghost btn-xs btn-circle"
  title="Reply in thread"
>
  <span class="hero-chat-bubble-left size-4" />
</button>
```

Add thread reply count indicator below message content:

```heex
<button
  :if={Map.get(@message, :reply_count, 0) > 0}
  phx-click="open_thread"
  phx-value-message-id={@message.id}
  class="text-xs text-primary hover:underline cursor-pointer mt-1"
>
  {Map.get(@message, :reply_count)} {if Map.get(@message, :reply_count) == 1, do: "reply", else: "replies"}
</button>
```

**Step 4: Add thread panel to index.ex template**

In the main layout, conditionally render the thread panel alongside the message list:

```heex
<div class="flex flex-1 overflow-hidden">
  <%!-- Message list (shrinks when thread open) --%>
  <div class={["flex-1 flex flex-col overflow-hidden", @thread_parent && "hidden md:flex"]}>
    <%!-- existing message list content --%>
  </div>

  <%!-- Thread panel --%>
  <.live_component
    :if={@thread_parent}
    module={SlackexWeb.ChatLive.ThreadPanelComponent}
    id="thread-panel"
    parent_message={@thread_parent}
    current_user={@current_user}
  />
</div>
```

**Step 5: Compile and test**

Run: `mix compile --warnings-as-errors && mix test`
Expected: All pass

**Step 6: Commit**

```
feat(ui): add thread panel with reply support
```

---

## Task 9: Channel Members & Pins — Migration & Schemas

**Files:**
- Create: `priv/repo/migrations/*_create_pinned_messages.exs`
- Create: `lib/slackex/chat/pinned_message.ex`
- Modify: `lib/slackex/chat/chat.ex` (exports)

**Step 1: Create migration**

Run: `mix ecto.gen.migration create_pinned_messages`

```elixir
defmodule Slackex.Repo.Migrations.CreatePinnedMessages do
  use Ecto.Migration

  def change do
    create table(:pinned_messages) do
      add :message_id, :bigint, null: false
      add :channel_id, references(:channels, on_delete: :delete_all), null: false
      add :pinned_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:pinned_messages, [:message_id, :channel_id])
    create index(:pinned_messages, [:channel_id])
  end
end
```

**Step 2: Create PinnedMessage schema**

Create `lib/slackex/chat/pinned_message.ex`:

```elixir
defmodule Slackex.Chat.PinnedMessage do
  use Ecto.Schema
  import Ecto.Changeset

  schema "pinned_messages" do
    belongs_to :message, Slackex.Chat.Message
    belongs_to :channel, Slackex.Chat.Channel
    belongs_to :pinned_by, Slackex.Accounts.User, foreign_key: :pinned_by_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(pin, attrs) do
    pin
    |> cast(attrs, [:message_id, :channel_id, :pinned_by_id])
    |> validate_required([:message_id, :channel_id])
    |> unique_constraint([:message_id, :channel_id])
  end
end
```

**Step 3: Add to Boundary exports and alias block in chat.ex**

```elixir
# In exports:
PinnedMessage,

# In alias block:
PinnedMessage,
```

**Step 4: Run migration**

Run: `mix ecto.migrate && mix compile --warnings-as-errors`
Expected: Success

**Step 5: Commit**

```
feat(chat): add PinnedMessage schema and migration
```

---

## Task 10: Channel Members & Pins — Backend Functions

**Files:**
- Modify: `lib/slackex/chat/chat.ex`
- Modify: `lib/slackex/chat/permissions.ex`
- Create: `test/slackex/chat/members_pins_test.exs`

**Step 1: Add permission actions to permissions.ex**

In `lib/slackex/chat/permissions.ex`, add to `@action_min_level` (~line 25-33):

```elixir
  @action_min_level %{
    send_message: 2,
    read_messages: 1,
    manage_channel: 3,
    delete_channel: 4,
    edit_own_message: 2,
    delete_own_message: 2,
    delete_any_message: 3,
    manage_members: 3,
    pin_message: 3
  }
```

**Step 2: Write failing test**

Create `test/slackex/chat/members_pins_test.exs`:

```elixir
defmodule Slackex.Chat.MembersPinsTest do
  use Slackex.DataCase, async: true

  alias Slackex.Chat

  import Slackex.Factory

  setup do
    owner = insert(:user)
    admin = insert(:user)
    member = insert(:user)

    channel =
      insert(:channel)
      |> with_subscription(owner, "owner")
      |> with_subscription(admin, "admin")
      |> with_subscription(member)

    message = insert(:message, sender: member, channel: channel)

    %{owner: owner, admin: admin, member: member, channel: channel, message: message}
  end

  describe "list_members/1" do
    test "returns all channel members with roles", %{channel: channel} do
      members = Chat.list_members(channel.id)
      assert length(members) == 3
      roles = Enum.map(members, & &1.role) |> Enum.sort()
      assert roles == ["admin", "member", "owner"]
    end
  end

  describe "update_member_role/4" do
    test "admin can promote member to admin", %{
      admin: admin,
      member: member,
      channel: channel
    } do
      assert :ok = Chat.update_member_role(channel.id, admin.id, member.id, "admin")
      assert Chat.get_role(member.id, channel.id) == "admin"
    end

    test "member cannot change roles", %{member: member, admin: admin, channel: channel} do
      assert {:error, :unauthorized} =
               Chat.update_member_role(channel.id, member.id, admin.id, "member")
    end

    test "cannot modify owner role", %{admin: admin, owner: owner, channel: channel} do
      assert {:error, :cannot_modify_owner} =
               Chat.update_member_role(channel.id, admin.id, owner.id, "member")
    end

    test "cannot change own role", %{admin: admin, channel: channel} do
      assert {:error, :cannot_change_own_role} =
               Chat.update_member_role(channel.id, admin.id, admin.id, "member")
    end
  end

  describe "kick_member/3" do
    test "admin can kick member", %{admin: admin, member: member, channel: channel} do
      assert :ok = Chat.kick_member(channel.id, admin.id, member.id)
      assert Chat.get_role(member.id, channel.id) == nil
    end

    test "cannot kick owner", %{admin: admin, owner: owner, channel: channel} do
      assert {:error, :cannot_kick_owner} =
               Chat.kick_member(channel.id, admin.id, owner.id)
    end

    test "member cannot kick", %{member: member, admin: admin, channel: channel} do
      assert {:error, :unauthorized} =
               Chat.kick_member(channel.id, member.id, admin.id)
    end
  end

  describe "pin_message/3 and unpin_message/3" do
    test "admin can pin a message", %{admin: admin, channel: channel, message: message} do
      assert {:ok, pin} = Chat.pin_message(channel.id, admin.id, message.id)
      assert pin.message_id == message.id
    end

    test "member cannot pin", %{member: member, channel: channel, message: message} do
      assert {:error, :unauthorized} = Chat.pin_message(channel.id, member.id, message.id)
    end

    test "admin can unpin", %{admin: admin, channel: channel, message: message} do
      {:ok, _} = Chat.pin_message(channel.id, admin.id, message.id)
      assert :ok = Chat.unpin_message(channel.id, admin.id, message.id)
      assert Chat.list_pinned_messages(channel.id) == []
    end

    test "list_pinned_messages returns pinned messages", %{
      admin: admin,
      channel: channel,
      message: message
    } do
      {:ok, _} = Chat.pin_message(channel.id, admin.id, message.id)
      pins = Chat.list_pinned_messages(channel.id)
      assert length(pins) == 1
      assert hd(pins).message_id == message.id
    end
  end
end
```

**Step 2b: Run test to verify it fails**

Run: `mix test test/slackex/chat/members_pins_test.exs`
Expected: FAIL

**Step 3: Implement in chat.ex**

Add member management and pin functions:

```elixir
  # ---------------------------------------------------------------------------
  # Member management
  # ---------------------------------------------------------------------------

  @doc "Lists members of a channel with their roles."
  def list_members(channel_id) do
    from(s in Subscription,
      where: s.channel_id == ^channel_id,
      join: u in assoc(s, :user),
      select: %{user: u, role: s.role, joined_at: s.inserted_at}
    )
    |> Repo.all()
  end

  @doc "Updates a member's role. Requires manage_members permission."
  def update_member_role(channel_id, actor_user_id, target_user_id, new_role)
      when new_role in ~w(admin member viewer) do
    actor_role = get_role(actor_user_id, channel_id)
    target_role = get_role(target_user_id, channel_id)

    cond do
      not Permissions.can?(actor_role, :manage_members) ->
        {:error, :unauthorized}

      actor_user_id == target_user_id ->
        {:error, :cannot_change_own_role}

      is_nil(target_role) ->
        {:error, :not_a_member}

      target_role == "owner" ->
        {:error, :cannot_modify_owner}

      true ->
        {1, _} =
          from(s in Subscription,
            where: s.channel_id == ^channel_id and s.user_id == ^target_user_id
          )
          |> Repo.update_all(set: [role: new_role])

        :ok
    end
  end

  @doc "Removes a member from a channel. Requires manage_members permission."
  def kick_member(channel_id, actor_user_id, target_user_id) do
    actor_role = get_role(actor_user_id, channel_id)
    target_role = get_role(target_user_id, channel_id)

    cond do
      not Permissions.can?(actor_role, :manage_members) ->
        {:error, :unauthorized}

      actor_user_id == target_user_id ->
        {:error, :cannot_kick_self}

      is_nil(target_role) ->
        {:error, :not_a_member}

      target_role == "owner" ->
        {:error, :cannot_kick_owner}

      true ->
        {1, _} =
          from(s in Subscription,
            where: s.channel_id == ^channel_id and s.user_id == ^target_user_id
          )
          |> Repo.delete_all()

        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Pinned messages
  # ---------------------------------------------------------------------------

  @doc "Pins a message in a channel. Requires pin_message permission."
  def pin_message(channel_id, user_id, message_id) do
    role = get_role(user_id, channel_id)

    if Permissions.can?(role, :pin_message) do
      %PinnedMessage{}
      |> PinnedMessage.changeset(%{
        message_id: message_id,
        channel_id: channel_id,
        pinned_by_id: user_id
      })
      |> Repo.insert()
    else
      {:error, :unauthorized}
    end
  end

  @doc "Unpins a message from a channel."
  def unpin_message(channel_id, user_id, message_id) do
    role = get_role(user_id, channel_id)

    if Permissions.can?(role, :pin_message) do
      from(p in PinnedMessage,
        where: p.channel_id == ^channel_id and p.message_id == ^message_id
      )
      |> Repo.delete_all()

      :ok
    else
      {:error, :unauthorized}
    end
  end

  @doc "Lists pinned messages for a channel."
  def list_pinned_messages(channel_id) do
    from(p in PinnedMessage,
      where: p.channel_id == ^channel_id,
      order_by: [desc: p.inserted_at],
      preload: [message: [:sender]]
    )
    |> Repo.all()
  end
```

**Step 4: Run tests**

Run: `mix test test/slackex/chat/members_pins_test.exs`
Expected: All pass

**Step 5: Commit**

```
feat(chat): add member management and pinned messages functions
```

---

## Task 11: Members & Pins — UI Modals

**Files:**
- Create: `lib/slackex_web/live/chat_live/channel_members_modal.ex`
- Create: `lib/slackex_web/live/chat_live/pinned_messages_modal.ex`
- Modify: `lib/slackex_web/live/chat_live/index.ex`
- Modify: `lib/slackex_web/router.ex`

**Step 1: Add routes**

In `lib/slackex_web/router.ex`, add before the `:thread` route:

```elixir
      live "/chat/:slug/members", ChatLive.Index, :members
      live "/chat/:slug/pins", ChatLive.Index, :pinned
```

**Step 2: Create ChannelMembersModal**

Create `lib/slackex_web/live/chat_live/channel_members_modal.ex`:

```elixir
defmodule SlackexWeb.ChatLive.ChannelMembersModal do
  use SlackexWeb, :live_component

  alias Slackex.Chat

  import SlackexWeb.ChatComponents

  @impl true
  def update(assigns, socket) do
    members = Chat.list_members(assigns.channel.id)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:members, members)
     |> assign(:search, "")}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, assign(socket, :search, query)}
  end

  def handle_event("update_role", %{"user-id" => user_id, "role" => role}, socket) do
    send(self(), {:update_member_role, String.to_integer(user_id), role})
    {:noreply, socket}
  end

  def handle_event("kick", %{"user-id" => user_id}, socket) do
    send(self(), {:kick_member, String.to_integer(user_id)})
    {:noreply, socket}
  end

  defp filtered_members(members, ""), do: members

  defp filtered_members(members, search) do
    q = String.downcase(search)

    Enum.filter(members, fn m ->
      String.contains?(String.downcase(m.user.username), q) ||
        (m.user.display_name && String.contains?(String.downcase(m.user.display_name), q))
    end)
  end

  defp role_badge_class("owner"), do: "badge-warning"
  defp role_badge_class("admin"), do: "badge-info"
  defp role_badge_class("viewer"), do: "badge-ghost"
  defp role_badge_class(_), do: "badge-neutral"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :filtered, filtered_members(assigns.members, assigns.search))

    ~H"""
    <div>
      <div class="mb-4">
        <input
          type="text"
          placeholder="Search members..."
          phx-keyup="search"
          phx-target={@myself}
          value={@search}
          class="input input-bordered input-sm w-full"
        />
      </div>

      <div class="space-y-2 max-h-[400px] overflow-y-auto">
        <div
          :for={member <- @filtered}
          class="flex items-center justify-between py-2 px-2 rounded hover:bg-base-200"
        >
          <div class="flex items-center gap-3">
            <.avatar user={member.user} size="sm" />
            <div>
              <span class="font-medium text-sm">
                {member.user.display_name || member.user.username}
              </span>
              <span class={"badge badge-xs ml-2 #{role_badge_class(member.role)}"}>
                {member.role}
              </span>
            </div>
          </div>

          <div :if={@can_manage && member.role != "owner" && member.user.id != @current_user.id} class="flex gap-1">
            <select
              phx-change="update_role"
              phx-target={@myself}
              phx-value-user-id={member.user.id}
              name="role"
              class="select select-bordered select-xs"
            >
              <option value="admin" selected={member.role == "admin"}>Admin</option>
              <option value="member" selected={member.role == "member"}>Member</option>
              <option value="viewer" selected={member.role == "viewer"}>Viewer</option>
            </select>
            <button
              phx-click="kick"
              phx-target={@myself}
              phx-value-user-id={member.user.id}
              class="btn btn-error btn-xs"
              data-confirm="Remove this member?"
            >
              Remove
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
```

**Step 3: Create PinnedMessagesModal**

Create `lib/slackex_web/live/chat_live/pinned_messages_modal.ex`:

```elixir
defmodule SlackexWeb.ChatLive.PinnedMessagesModal do
  use SlackexWeb, :live_component

  alias Slackex.Chat

  import SlackexWeb.ChatComponents

  @impl true
  def update(assigns, socket) do
    pins = Chat.list_pinned_messages(assigns.channel.id)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:pins, pins)}
  end

  @impl true
  def handle_event("unpin", %{"message-id" => msg_id}, socket) do
    send(self(), {:unpin_message, String.to_integer(msg_id)})
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div :if={@pins == []} class="text-center text-base-content/50 py-8">
        No pinned messages yet.
      </div>

      <div class="space-y-3 max-h-[400px] overflow-y-auto">
        <div
          :for={pin <- @pins}
          class="border border-base-300 rounded-lg p-3 hover:bg-base-200/50"
        >
          <div class="flex items-start justify-between gap-2">
            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-2 mb-1">
                <.avatar user={pin.message.sender} size="sm" />
                <span class="font-medium text-sm">{pin.message.sender.username}</span>
              </div>
              <p class="text-sm text-base-content/80 line-clamp-3">
                {pin.message.content}
              </p>
            </div>
            <button
              :if={@can_manage}
              phx-click="unpin"
              phx-target={@myself}
              phx-value-message-id={pin.message_id}
              class="btn btn-ghost btn-xs"
              title="Unpin"
            >
              <span class="hero-x-mark size-4" />
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
```

**Step 4: Add modal rendering and handlers to index.ex**

Add aliases:

```elixir
alias SlackexWeb.ChatLive.ChannelMembersModal
alias SlackexWeb.ChatLive.PinnedMessagesModal
```

Add `handle_params` clauses for `:members` and `:pinned`:

```elixir
  def handle_params(%{"slug" => slug}, _uri, %{assigns: %{live_action: :members}} = socket) do
    channel = Chat.get_channel_by_slug!(slug)
    {:noreply, maybe_enter_channel(socket, channel)}
  end

  def handle_params(%{"slug" => slug}, _uri, %{assigns: %{live_action: :pinned}} = socket) do
    channel = Chat.get_channel_by_slug!(slug)
    {:noreply, maybe_enter_channel(socket, channel)}
  end
```

Add event handlers:

```elixir
  def handle_event("pin_message", %{"message-id" => msg_id}, socket) do
    channel = socket.assigns.active_channel
    user = socket.assigns.current_user

    case Chat.pin_message(channel.id, user.id, String.to_integer(msg_id)) do
      {:ok, _} -> {:noreply, put_flash(socket, :info, "Message pinned.")}
      {:error, :unauthorized} -> {:noreply, put_flash(socket, :error, "Not authorized.")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not pin message.")}
    end
  end

  def handle_info({:unpin_message, message_id}, socket) do
    channel = socket.assigns.active_channel
    user = socket.assigns.current_user

    case Chat.unpin_message(channel.id, user.id, message_id) do
      :ok -> {:noreply, put_flash(socket, :info, "Message unpinned.")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not unpin.")}
    end
  end

  def handle_info({:update_member_role, target_id, role}, socket) do
    channel = socket.assigns.active_channel
    user = socket.assigns.current_user

    case Chat.update_member_role(channel.id, user.id, target_id, role) do
      :ok -> {:noreply, put_flash(socket, :info, "Role updated.")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Error: #{reason}")}
    end
  end

  def handle_info({:kick_member, target_id}, socket) do
    channel = socket.assigns.active_channel
    user = socket.assigns.current_user

    case Chat.kick_member(channel.id, user.id, target_id) do
      :ok -> {:noreply, put_flash(socket, :info, "Member removed.")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Error: #{reason}")}
    end
  end
```

Add modal rendering in template (inside the modal rendering section):

```heex
<.modal
  :if={@live_action == :members && @active_channel}
  id="members-modal"
  show
  on_cancel={JS.patch(~p"/chat/#{@active_channel.slug}")}
>
  <:title>Members - #{@active_channel.name}</:title>
  <.live_component
    module={ChannelMembersModal}
    id="channel-members"
    channel={@active_channel}
    current_user={@current_user}
    can_manage={Permissions.can?(@user_role, :manage_members)}
  />
</.modal>

<.modal
  :if={@live_action == :pinned && @active_channel}
  id="pins-modal"
  show
  on_cancel={JS.patch(~p"/chat/#{@active_channel.slug}")}
>
  <:title>Pinned Messages - #{@active_channel.name}</:title>
  <.live_component
    module={PinnedMessagesModal}
    id="pinned-messages"
    channel={@active_channel}
    current_user={@current_user}
    can_manage={Permissions.can?(@user_role, :pin_message)}
  />
</.modal>
```

Add channel header buttons for members/pins count:

```heex
<.link
  :if={@active_channel}
  patch={~p"/chat/#{@active_channel.slug}/members"}
  class="btn btn-ghost btn-xs gap-1"
>
  <span class="hero-users size-4" />
  <span class="text-xs">{Chat.count_members(@active_channel.id)}</span>
</.link>

<.link
  :if={@active_channel}
  patch={~p"/chat/#{@active_channel.slug}/pins"}
  class="btn btn-ghost btn-xs gap-1"
>
  <span class="hero-bookmark size-4" />
</.link>
```

**Step 5: Compile and test**

Run: `mix compile --warnings-as-errors && mix test`
Expected: All pass

**Step 6: Commit**

```
feat(ui): add channel members and pinned messages modals
```

---

## Task 12: Invite Links — Migration, Schema & Backend

**Files:**
- Create: `priv/repo/migrations/*_create_invite_links.exs`
- Create: `lib/slackex/chat/invite_link.ex`
- Modify: `lib/slackex/chat/chat.ex`
- Create: `test/slackex/chat/invite_links_test.exs`

**Step 1: Create migration**

Run: `mix ecto.gen.migration create_invite_links`

```elixir
defmodule Slackex.Repo.Migrations.CreateInviteLinks do
  use Ecto.Migration

  def change do
    create table(:invite_links) do
      add :code, :string, null: false, size: 32
      add :channel_id, references(:channels, on_delete: :delete_all), null: false
      add :created_by_id, references(:users, on_delete: :nilify_all)
      add :max_uses, :integer
      add :use_count, :integer, default: 0, null: false
      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:invite_links, [:code])
    create index(:invite_links, [:channel_id])
  end
end
```

**Step 2: Create InviteLink schema**

Create `lib/slackex/chat/invite_link.ex`:

```elixir
defmodule Slackex.Chat.InviteLink do
  use Ecto.Schema
  import Ecto.Changeset

  schema "invite_links" do
    field :code, :string
    field :max_uses, :integer
    field :use_count, :integer, default: 0
    field :expires_at, :utc_datetime_usec

    belongs_to :channel, Slackex.Chat.Channel
    belongs_to :created_by, Slackex.Accounts.User, foreign_key: :created_by_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:code, :channel_id, :created_by_id, :max_uses, :expires_at])
    |> validate_required([:channel_id])
    |> put_code_if_missing()
    |> unique_constraint(:code)
  end

  defp put_code_if_missing(changeset) do
    if get_field(changeset, :code) do
      changeset
    else
      put_change(changeset, :code, generate_code())
    end
  end

  defp generate_code do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false) |> binary_part(0, 22)
  end
end
```

**Step 3: Add to Boundary exports**

```elixir
InviteLink,
```

**Step 4: Write test**

Create `test/slackex/chat/invite_links_test.exs`:

```elixir
defmodule Slackex.Chat.InviteLinksTest do
  use Slackex.DataCase, async: true

  alias Slackex.Chat

  import Slackex.Factory

  setup do
    owner = insert(:user)
    member = insert(:user)
    joiner = insert(:user)
    channel = insert(:channel) |> with_subscription(owner, "owner") |> with_subscription(member)
    %{owner: owner, member: member, joiner: joiner, channel: channel}
  end

  describe "create_invite_link/3" do
    test "owner can create invite", %{owner: owner, channel: channel} do
      {:ok, invite} = Chat.create_invite_link(channel.id, owner.id)
      assert invite.code != nil
      assert invite.channel_id == channel.id
      assert String.length(invite.code) == 22
    end

    test "member cannot create invite", %{member: member, channel: channel} do
      assert {:error, :unauthorized} = Chat.create_invite_link(channel.id, member.id)
    end

    test "supports max_uses and expires_in_hours", %{owner: owner, channel: channel} do
      {:ok, invite} =
        Chat.create_invite_link(channel.id, owner.id, max_uses: 5, expires_in_hours: 24)

      assert invite.max_uses == 5
      assert invite.expires_at != nil
    end
  end

  describe "redeem_invite/2" do
    test "adds user to channel", %{owner: owner, joiner: joiner, channel: channel} do
      {:ok, invite} = Chat.create_invite_link(channel.id, owner.id)
      assert {:ok, _} = Chat.redeem_invite(invite.code, joiner.id)
      assert Chat.get_role(joiner.id, channel.id) == "member"
    end

    test "increments use_count", %{owner: owner, joiner: joiner, channel: channel} do
      {:ok, invite} = Chat.create_invite_link(channel.id, owner.id)
      {:ok, _} = Chat.redeem_invite(invite.code, joiner.id)

      updated = Repo.get!(Slackex.Chat.InviteLink, invite.id)
      assert updated.use_count == 1
    end

    test "rejects expired invite", %{owner: owner, joiner: joiner, channel: channel} do
      {:ok, invite} = Chat.create_invite_link(channel.id, owner.id, expires_in_hours: 0)

      # Force expire
      Repo.update_all(
        from(i in Slackex.Chat.InviteLink, where: i.id == ^invite.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)]
      )

      assert {:error, :expired} = Chat.redeem_invite(invite.code, joiner.id)
    end

    test "rejects when max_uses reached", %{owner: owner, channel: channel} do
      {:ok, invite} = Chat.create_invite_link(channel.id, owner.id, max_uses: 1)
      joiner1 = insert(:user)
      joiner2 = insert(:user)

      {:ok, _} = Chat.redeem_invite(invite.code, joiner1.id)
      assert {:error, :max_uses_reached} = Chat.redeem_invite(invite.code, joiner2.id)
    end

    test "rejects already member", %{owner: owner, member: member, channel: channel} do
      {:ok, invite} = Chat.create_invite_link(channel.id, owner.id)
      assert {:error, :already_member} = Chat.redeem_invite(invite.code, member.id)
    end

    test "returns not_found for bad code", %{joiner: joiner} do
      assert {:error, :not_found} = Chat.redeem_invite("nonexistent_code_xxx", joiner.id)
    end
  end

  describe "revoke_invite_link/2" do
    test "owner can revoke", %{owner: owner, channel: channel} do
      {:ok, invite} = Chat.create_invite_link(channel.id, owner.id)
      assert {:ok, _} = Chat.revoke_invite_link(invite.id, owner.id)
    end

    test "member cannot revoke", %{owner: owner, member: member, channel: channel} do
      {:ok, invite} = Chat.create_invite_link(channel.id, owner.id)
      assert {:error, :unauthorized} = Chat.revoke_invite_link(invite.id, member.id)
    end
  end
end
```

**Step 5: Implement in chat.ex**

```elixir
  # ---------------------------------------------------------------------------
  # Invite links
  # ---------------------------------------------------------------------------

  @doc "Creates an invite link for a channel. Requires manage_channel permission."
  def create_invite_link(channel_id, user_id, opts \\ []) do
    role = get_role(user_id, channel_id)

    if Permissions.can?(role, :manage_channel) do
      max_uses = Keyword.get(opts, :max_uses)
      expires_in_hours = Keyword.get(opts, :expires_in_hours, 168)

      expires_at =
        DateTime.utc_now()
        |> DateTime.add(expires_in_hours * 3600, :second)
        |> DateTime.truncate(:microsecond)

      %InviteLink{}
      |> InviteLink.changeset(%{
        channel_id: channel_id,
        created_by_id: user_id,
        max_uses: max_uses,
        expires_at: expires_at
      })
      |> Repo.insert()
    else
      {:error, :unauthorized}
    end
  end

  @doc "Redeems an invite code. Adds the user to the channel if valid."
  def redeem_invite(code, user_id) do
    Repo.transaction(fn ->
      invite =
        from(i in InviteLink,
          where: i.code == ^code,
          lock: "FOR UPDATE"
        )
        |> Repo.one()

      unless invite, do: Repo.rollback(:not_found)

      cond do
        invite.expires_at &&
            DateTime.compare(DateTime.utc_now(), invite.expires_at) == :gt ->
          Repo.rollback(:expired)

        invite.max_uses && invite.use_count >= invite.max_uses ->
          Repo.rollback(:max_uses_reached)

        get_role(user_id, invite.channel_id) != nil ->
          Repo.rollback(:already_member)

        true ->
          %Subscription{}
          |> Subscription.changeset(%{
            user_id: user_id,
            channel_id: invite.channel_id,
            role: "member"
          })
          |> Repo.insert!(on_conflict: :nothing, conflict_target: [:user_id, :channel_id])

          {1, _} =
            from(i in InviteLink, where: i.id == ^invite.id)
            |> Repo.update_all(inc: [use_count: 1])

          invite
      end
    end)
    |> case do
      {:ok, invite} -> {:ok, invite}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Lists invite links for a channel."
  def list_invite_links(channel_id) do
    from(i in InviteLink,
      where: i.channel_id == ^channel_id,
      order_by: [desc: i.inserted_at],
      preload: [:created_by]
    )
    |> Repo.all()
  end

  @doc "Revokes (deletes) an invite link."
  def revoke_invite_link(invite_id, user_id) do
    invite = Repo.get!(InviteLink, invite_id)
    role = get_role(user_id, invite.channel_id)

    if Permissions.can?(role, :manage_channel) do
      Repo.delete(invite)
    else
      {:error, :unauthorized}
    end
  end
```

**Step 6: Run migration and tests**

Run: `mix ecto.migrate && mix test test/slackex/chat/invite_links_test.exs`
Expected: All pass

**Step 7: Commit**

```
feat(chat): add invite link creation, redemption, and revocation
```

---

## Task 13: Invite Links — UI (Modal, Public Route, Copy Hook)

**Files:**
- Create: `lib/slackex_web/live/chat_live/invite_link_modal.ex`
- Create: `lib/slackex_web/live/invite_live.ex`
- Create: `assets/js/hooks/copy_to_clipboard.js`
- Modify: `assets/js/app.js`
- Modify: `lib/slackex_web/router.ex`
- Modify: `lib/slackex_web/live/chat_live/index.ex`

**Step 1: Create CopyToClipboard hook**

Create `assets/js/hooks/copy_to_clipboard.js`:

```javascript
const CopyToClipboard = {
  mounted() {
    this.el.addEventListener("click", () => {
      const text = this.el.dataset.clipboardText;
      navigator.clipboard.writeText(text).then(() => {
        const original = this.el.textContent;
        this.el.textContent = "Copied!";
        setTimeout(() => {
          this.el.textContent = original;
        }, 2000);
      });
    });
  },
};

export default CopyToClipboard;
```

Register in `assets/js/app.js`:

```javascript
import CopyToClipboard from "./hooks/copy_to_clipboard";
// In hooks: CopyToClipboard,
```

**Step 2: Add routes**

In `router.ex`, add to the chat live_session:

```elixir
      live "/chat/:slug/invites", ChatLive.Index, :invites
```

Add public invite route (outside authenticated live_session, but still in browser pipeline):

```elixir
  scope "/", SlackexWeb do
    pipe_through :browser

    live_session :public_invite,
      on_mount: [{SlackexWeb.UserAuth, :mount_current_user}] do
      live "/invite/:code", InviteLive, :redeem
    end
  end
```

**Step 3: Create InviteLinkModal**

Create `lib/slackex_web/live/chat_live/invite_link_modal.ex`:

```elixir
defmodule SlackexWeb.ChatLive.InviteLinkModal do
  use SlackexWeb, :live_component

  alias Slackex.Chat

  @impl true
  def update(assigns, socket) do
    invites = Chat.list_invite_links(assigns.channel.id)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:invites, invites)
     |> assign(:generated_url, nil)
     |> assign(:form, to_form(%{"max_uses" => "", "expires" => "168"}, as: :invite))}
  end

  @impl true
  def handle_event("generate", %{"invite" => params}, socket) do
    channel = socket.assigns.channel
    user = socket.assigns.current_user

    opts =
      [expires_in_hours: String.to_integer(params["expires"])]
      |> then(fn opts ->
        case params["max_uses"] do
          "" -> opts
          n -> Keyword.put(opts, :max_uses, String.to_integer(n))
        end
      end)

    case Chat.create_invite_link(channel.id, user.id, opts) do
      {:ok, invite} ->
        url = SlackexWeb.Endpoint.url() <> "/invite/#{invite.code}"
        invites = Chat.list_invite_links(channel.id)

        {:noreply,
         socket
         |> assign(:generated_url, url)
         |> assign(:invites, invites)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("revoke", %{"invite-id" => id}, socket) do
    user = socket.assigns.current_user

    case Chat.revoke_invite_link(String.to_integer(id), user.id) do
      {:ok, _} ->
        invites = Chat.list_invite_links(socket.assigns.channel.id)
        {:noreply, assign(socket, :invites, invites)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <%!-- Generate form --%>
      <.form for={@form} phx-submit="generate" phx-target={@myself} class="flex gap-2 mb-4">
        <select name="invite[expires]" class="select select-bordered select-sm">
          <option value="1">1 hour</option>
          <option value="24">24 hours</option>
          <option value="168" selected>7 days</option>
          <option value="720">30 days</option>
        </select>
        <input
          name="invite[max_uses]"
          type="number"
          min="1"
          placeholder="Max uses (unlimited)"
          class="input input-bordered input-sm w-32"
        />
        <button type="submit" class="btn btn-primary btn-sm">Generate</button>
      </.form>

      <%!-- Generated URL --%>
      <div :if={@generated_url} class="alert alert-success mb-4">
        <div class="flex items-center gap-2 w-full">
          <code class="flex-1 text-sm truncate">{@generated_url}</code>
          <button
            phx-hook="CopyToClipboard"
            id="copy-invite-url"
            data-clipboard-text={@generated_url}
            class="btn btn-sm btn-ghost"
          >
            Copy
          </button>
        </div>
      </div>

      <%!-- Existing invites --%>
      <div class="space-y-2">
        <div
          :for={invite <- @invites}
          class="flex items-center justify-between py-2 px-2 rounded border border-base-300"
        >
          <div class="text-sm">
            <code class="text-xs">{invite.code}</code>
            <span class="ml-2 text-base-content/50">
              {invite.use_count}{if invite.max_uses, do: "/#{invite.max_uses}", else: ""} uses
            </span>
          </div>
          <button
            phx-click="revoke"
            phx-target={@myself}
            phx-value-invite-id={invite.id}
            class="btn btn-ghost btn-xs text-error"
            data-confirm="Revoke this invite?"
          >
            Revoke
          </button>
        </div>
      </div>
    </div>
    """
  end
end
```

**Step 4: Create InviteLive**

Create `lib/slackex_web/live/invite_live.ex`:

```elixir
defmodule SlackexWeb.InviteLive do
  use SlackexWeb, :live_view

  alias Slackex.Chat

  @impl true
  def mount(%{"code" => code}, _session, socket) do
    case socket.assigns[:current_user] do
      nil ->
        {:ok, redirect(socket, to: ~p"/users/log-in?invite=#{code}")}

      user ->
        case Chat.redeem_invite(code, user.id) do
          {:ok, invite} ->
            channel = Chat.get_channel!(invite.channel_id)
            {:ok, redirect(socket, to: ~p"/chat/#{channel.slug}")}

          {:error, :already_member} ->
            invite = Slackex.Repo.get_by!(Slackex.Chat.InviteLink, code: code)
            channel = Chat.get_channel!(invite.channel_id)
            {:ok, redirect(socket, to: ~p"/chat/#{channel.slug}")}

          {:error, reason} ->
            {:ok,
             socket
             |> assign(:error, invite_error_message(reason))
             |> assign(:page_title, "Invite")}
        end
    end
  end

  defp invite_error_message(:expired), do: "This invite link has expired."
  defp invite_error_message(:max_uses_reached), do: "This invite link has reached its usage limit."
  defp invite_error_message(:not_found), do: "This invite link is invalid."
  defp invite_error_message(_), do: "Could not redeem this invite."

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center">
      <div class="card bg-base-100 shadow-xl p-8 max-w-md">
        <h2 class="text-xl font-bold mb-4">Invite Error</h2>
        <p class="text-base-content/70">{@error}</p>
        <.link navigate={~p"/chat"} class="btn btn-primary mt-4">
          Go to Chat
        </.link>
      </div>
    </div>
    """
  end
end
```

**Step 5: Add invite modal rendering to index.ex**

Add alias and modal rendering following the same pattern as members/pins:

```elixir
alias SlackexWeb.ChatLive.InviteLinkModal

# handle_params for :invites
def handle_params(%{"slug" => slug}, _uri, %{assigns: %{live_action: :invites}} = socket) do
  channel = Chat.get_channel_by_slug!(slug)
  {:noreply, maybe_enter_channel(socket, channel)}
end
```

```heex
<.modal
  :if={@live_action == :invites && @active_channel}
  id="invites-modal"
  show
  on_cancel={JS.patch(~p"/chat/#{@active_channel.slug}")}
>
  <:title>Invite Links - #{@active_channel.name}</:title>
  <.live_component
    module={InviteLinkModal}
    id="invite-links"
    channel={@active_channel}
    current_user={@current_user}
  />
</.modal>
```

Add invite button to channel header (next to members/pins):

```heex
<.link
  :if={@active_channel && Permissions.can?(@user_role, :manage_channel)}
  patch={~p"/chat/#{@active_channel.slug}/invites"}
  class="btn btn-ghost btn-xs gap-1"
  title="Invite links"
>
  <span class="hero-link size-4" />
</.link>
```

**Step 6: Build assets and test**

Run: `cd assets && npm run build && cd .. && mix compile --warnings-as-errors && mix test`
Expected: All pass

**Step 7: Commit**

```
feat(ui): add invite link modal, public redemption, and clipboard hook
```

---

## Task 14: Quick Switcher (Cmd+K)

**Files:**
- Modify: `lib/slackex_web/live/chat_live/index.ex`
- Modify: `assets/js/app.js` (or create `assets/js/hooks/quick_switcher.js`)

**Step 1: Add quick switcher state to index.ex mount**

Add assign:

```elixir
|> assign(:quick_switcher_open, false)
|> assign(:quick_switcher_results, [])
|> assign(:quick_switcher_query, "")
```

**Step 2: Add event handlers**

```elixir
  def handle_event("open_quick_switcher", _params, socket) do
    {:noreply, assign(socket, :quick_switcher_open, true)}
  end

  def handle_event("close_quick_switcher", _params, socket) do
    {:noreply,
     socket
     |> assign(:quick_switcher_open, false)
     |> assign(:quick_switcher_results, [])
     |> assign(:quick_switcher_query, "")}
  end

  def handle_event("quick_switcher_search", %{"query" => query}, socket) do
    results =
      if String.trim(query) == "" do
        []
      else
        q = String.downcase(query)

        channels =
          socket.assigns.channels
          |> Enum.filter(&String.contains?(String.downcase(&1.name), q))
          |> Enum.map(&%{type: :channel, name: &1.name, slug: &1.slug, id: &1.id})

        dms =
          socket.assigns.dm_conversations
          |> Enum.filter(fn dm ->
            other = dm.other_user
            String.contains?(String.downcase(other.username), q) ||
              (other.display_name && String.contains?(String.downcase(other.display_name), q))
          end)
          |> Enum.map(&%{type: :dm, name: &1.other_user.display_name || &1.other_user.username, id: &1.id})

        channels ++ dms
      end

    {:noreply,
     socket
     |> assign(:quick_switcher_results, Enum.take(results, 10))
     |> assign(:quick_switcher_query, query)}
  end

  def handle_event("quick_switcher_select", %{"type" => "channel", "slug" => slug}, socket) do
    {:noreply,
     socket
     |> assign(:quick_switcher_open, false)
     |> push_patch(to: ~p"/chat/#{slug}")}
  end

  def handle_event("quick_switcher_select", %{"type" => "dm", "id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:quick_switcher_open, false)
     |> push_patch(to: ~p"/chat/dm/#{id}")}
  end
```

**Step 3: Add quick switcher modal to template**

```heex
<.modal
  :if={@quick_switcher_open}
  id="quick-switcher"
  show
  on_cancel={JS.push("close_quick_switcher")}
>
  <div phx-window-keydown="close_quick_switcher" phx-key="Escape">
    <input
      type="text"
      placeholder="Search channels and conversations..."
      phx-keyup="quick_switcher_search"
      value={@quick_switcher_query}
      class="input input-bordered w-full mb-3"
      autofocus
      phx-debounce="150"
    />

    <div class="space-y-1 max-h-[300px] overflow-y-auto">
      <div :if={@quick_switcher_results == [] && @quick_switcher_query != ""} class="text-center text-base-content/50 py-4 text-sm">
        No matches found
      </div>

      <button
        :for={result <- @quick_switcher_results}
        phx-click="quick_switcher_select"
        phx-value-type={result.type}
        phx-value-slug={Map.get(result, :slug)}
        phx-value-id={result.id}
        class="flex items-center gap-3 w-full p-2 rounded hover:bg-base-200 text-left"
      >
        <span :if={result.type == :channel} class="text-base-content/50">#</span>
        <span :if={result.type == :dm} class="hero-user size-4 text-base-content/50" />
        <span class="font-medium text-sm">{result.name}</span>
      </button>
    </div>
  </div>
</.modal>
```

**Step 4: Add Cmd+K listener**

In `assets/js/app.js`, add near the bottom (before `liveSocket.connect()`):

```javascript
document.addEventListener("keydown", (e) => {
  if ((e.ctrlKey || e.metaKey) && e.key === "k") {
    e.preventDefault();
    const view = document.querySelector("[data-phx-main]");
    if (view) {
      liveSocket.execJS(view, 'push', { event: "open_quick_switcher", data: {} });
      // Alternative: direct push via the main view
    }
  }
});
```

Or simpler — add `phx-window-keydown` to the root element in the chat layout:

```heex
<main phx-window-keydown="global_keydown">
```

And handle in index.ex:

```elixir
  def handle_event("global_keydown", %{"key" => "k", "metaKey" => true}, socket) do
    {:noreply, assign(socket, :quick_switcher_open, true)}
  end

  def handle_event("global_keydown", %{"key" => "k", "ctrlKey" => true}, socket) do
    {:noreply, assign(socket, :quick_switcher_open, true)}
  end

  def handle_event("global_keydown", _params, socket) do
    {:noreply, socket}
  end
```

**Step 5: Compile and test**

Run: `mix compile --warnings-as-errors && mix test`
Expected: All pass

**Step 6: Manual smoke test**

- Press Cmd+K -> quick switcher opens
- Type channel name -> filtered results
- Click result -> navigates to channel
- Press Escape -> closes

**Step 7: Commit**

```
feat(ui): add quick switcher with Cmd+K shortcut
```

---

## Task 15: Catchup Integration & Final Polish

**Files:**
- Modify: `lib/slackex_web/live/chat_live/index.ex`

**Step 1: Add catchup on reconnection**

In index.ex, the `connected?` branch in mount already handles initial load. For reconnection detection, track `last_seen_id`:

In mount, add:

```elixir
|> assign(:last_seen_id, nil)
```

In the `message.new` envelope handler, track the latest message ID:

```elixir
# At the end of the handle_info for message.new:
|> assign(:last_seen_id, payload.id)
```

Note: Full CatchupServer integration requires reconnection detection which LiveView handles via re-mount. On re-mount, `mount/3` runs fresh — messages are loaded from DB/cache, unread counts recalculated. The current architecture already handles this correctly. The `last_seen_id` is mainly useful for detecting gaps during a single session.

**Step 2: Add sidebar theme toggle connection**

In `sidebar_component.ex`, if not already present, ensure the theme toggle button dispatches the toggle event:

```heex
<button phx-click={JS.dispatch("toggle-theme")} class="btn btn-ghost btn-sm btn-circle">
  <span class="hero-sun-solid hidden dark:block size-4" />
  <span class="hero-moon-solid dark:hidden size-4" />
</button>
```

**Step 3: Verify all existing empty_state usage**

Check that `empty_state` is used in:
- No channels selected → "Select a channel to start chatting"
- Empty message list → "No messages yet. Start the conversation!"
- Empty thread → "No replies yet" (added in Task 8)
- Empty search results → (already handled by SearchComponent)

**Step 4: Final compile and full test suite**

Run: `mix compile --warnings-as-errors && mix test`
Expected: All 1002+ tests pass

**Step 5: Commit**

```
feat(ui): add catchup tracking and polish
```

---

## Summary of Commits

| # | Task | Commit Message |
|---|------|---------------|
| 1 | Reactions schema | `feat(chat): add MessageReaction schema and migration` |
| 2 | Reactions backend | `feat(chat): add toggle_reaction and list_reactions functions` |
| 3 | Reactions UI | `feat(chat): add reactions UI with toggle and real-time broadcast` |
| 4 | Emoji picker | `feat(ui): add emoji picker for message reactions` |
| 5 | Threads schema | `feat(chat): add thread fields to messages schema` |
| 6 | Threads backend | `feat(chat): add send_reply and list_thread functions` |
| 7 | Threads facade | `feat(messaging): add thread reply facade and BatchWriter support` |
| 8 | Thread panel UI | `feat(ui): add thread panel with reply support` |
| 9 | Pins schema | `feat(chat): add PinnedMessage schema and migration` |
| 10 | Members & pins backend | `feat(chat): add member management and pinned messages functions` |
| 11 | Members & pins UI | `feat(ui): add channel members and pinned messages modals` |
| 12 | Invites backend | `feat(chat): add invite link creation, redemption, and revocation` |
| 13 | Invites UI | `feat(ui): add invite link modal, public redemption, and clipboard hook` |
| 14 | Quick switcher | `feat(ui): add quick switcher with Cmd+K shortcut` |
| 15 | Polish | `feat(ui): add catchup tracking and polish` |
