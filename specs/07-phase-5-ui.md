# Phase 5 — Full-Featured UI & App Experience

## Goal

Transform the minimal proof-of-concept LiveView UI (single `ChatLive.Index` with inline sidebar and message list) into a full-featured messaging application. Decompose into reusable components, add responsive layout, and implement the complete feature set users expect from a modern messaging app: channel discovery, DMs, reactions, threads, message editing/deletion, user profiles, invites, member management, and unread tracking.

**Design direction:** Modern minimal (Linear/Notion-inspired), responsive from day one, daisyUI + Tailwind CSS.

## Prerequisites

- Phase 2 complete (CQRS pipeline, ChannelServer, BatchWriter, Presence, PubSub)
- Phase 3 Step 6 complete (CatchupServer for reconnection catch-up)
- Existing `ChatLive.Index` LiveView with basic sidebar, message list, and compose form
- daisyUI already configured in Tailwind

## Dependencies Added

No new Elixir dependencies. Frontend-only additions:

| Library | Version | Purpose |
|---------|---------|---------|
| emoji-mart (JS) | ~> 5.6 | Emoji picker component for reactions (npm) |

## Navigation Contract

- Use patch navigation inside LiveView: `<.link patch={...}>` in templates and `push_patch/2` in LiveView callbacks.
- Route references in this document are absolute (`/chat/...`).
- Use the term "patch navigation" consistently throughout implementation notes and PRs.

---

## Step 1: Layout Refactor & Responsive Shell

Decompose the monolithic `ChatLive.Index` into composable components. Extract sidebar as a LiveComponent, create shared function components, add responsive mobile support, and enhance JS hooks.

### 1.1 Function Components — `chat_components.ex`

Create `lib/slackex_web/components/chat_components.ex` with function components:

```elixir
defmodule SlackexWeb.ChatComponents do
  use Phoenix.Component

  attr :user, :map, required: true
  attr :size, :string, default: "md"
  attr :online, :boolean, default: false
  def avatar(assigns)

  attr :channel, :map, required: true
  attr :active, :boolean, default: false
  attr :unread_count, :integer, default: 0
  def channel_list_item(assigns)

  attr :dm, :map, required: true
  attr :active, :boolean, default: false
  attr :online, :boolean, default: false
  attr :unread_count, :integer, default: 0
  def dm_list_item(assigns)

  attr :message, :map, required: true
  attr :current_user_id, :integer, required: true
  attr :show_hover_actions, :boolean, default: true
  def message_bubble(assigns)

  attr :users, :list, default: []
  def typing_indicator(assigns)

  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :icon, :string, default: nil
  def empty_state(assigns)

  attr :count, :integer, default: 0
  def unread_badge(assigns)
end
```

**Avatar component** renders a circular image (or initials fallback from `display_name || username`) with an optional green/gray online indicator dot positioned bottom-right. Sizes: `"sm"` (24px), `"md"` (32px), `"lg"` (48px).

**Message bubble** renders the sender avatar, username, timestamp, message content, and (on hover) action buttons for edit/delete/react/reply. Own messages show edit + delete; all messages show react + reply.

### 1.2 Sidebar LiveComponent — `sidebar_component.ex`

Create `lib/slackex_web/live/chat_live/sidebar_component.ex`:

```elixir
defmodule SlackexWeb.ChatLive.SidebarComponent do
  use SlackexWeb, :live_component

  # Assigns received from parent:
  # @channels         - list of user's channels
  # @dm_conversations - list of user's DM conversations
  # @active_channel   - currently selected channel/DM (or nil)
  # @current_user     - logged-in user
  # @unread_counts    - %{channel_id => count} map
  # @online_user_ids  - MapSet of online user IDs

  def render(assigns)
  def handle_event("toggle_section", %{"section" => section}, socket)
end
```

Sidebar sections:
1. **Header** — workspace name ("Slackex"), hamburger button (mobile only)
2. **Channels section** — collapsible, "+" button triggers `:create_channel` action, "Browse" link triggers `:browse_channels` action
3. **Direct Messages section** — collapsible, "+" button triggers `:new_dm` action
4. **User footer** — current user avatar, display name, status text, edit profile button, theme toggle

The sidebar sends events to the parent `Index` LiveView via `send(self(), {:sidebar_action, action})`.

### 1.3 Responsive Layout

Add `sidebar_open` assign to `Index` (default `true` on desktop, `false` on mobile):

```elixir
# In mount/3
|> assign(:sidebar_open, true)
```

Sidebar CSS classes:
- Desktop (`md:` breakpoint and up): `md:static md:translate-x-0 w-64`
- Mobile (below `md:`): `fixed inset-y-0 left-0 z-40 w-72 transform transition-transform duration-200` with conditional `-translate-x-full` when closed
- Backdrop overlay on mobile when sidebar is open: `fixed inset-0 z-30 bg-black/50`
- Hamburger button visible only on mobile: `md:hidden`

### 1.4 Compose Hook — `compose.js`

Create `assets/js/hooks/compose.js`:

```javascript
const Compose = {
  mounted() {
    this.textarea = this.el.querySelector("textarea");
    this.textarea.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        this.el.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
      }
    });
    this.textarea.addEventListener("input", () => this.autoResize());
    this.setupTypingDebounce();
  },
  autoResize() {
    this.textarea.style.height = "auto";
    this.textarea.style.height = Math.min(this.textarea.scrollHeight, 200) + "px";
  },
  setupTypingDebounce() {
    let timeout;
    this.textarea.addEventListener("input", () => {
      if (!timeout) {
        this.pushEvent("typing", {});
      }
      clearTimeout(timeout);
      timeout = setTimeout(() => { timeout = null; }, 2000);
    });
  },
  // Reset textarea height after send
  updated() {
    if (this.textarea.value === "") {
      this.textarea.style.height = "auto";
    }
  }
};
export default Compose;
```

**Behavior:** Enter sends (Shift+Enter for newline), textarea auto-resizes up to 200px, typing events debounced at 2-second intervals. Replace the current `<input type="text">` with a `<textarea>` in the compose area.

### 1.5 Enhanced MessageList Hook — `message_list.js`

Enhance existing `assets/js/hooks/message_list.js` with infinite scroll:

```javascript
const MessageList = {
  mounted() {
    this.scrollToBottom();
    this.pending = false;
    this.el.addEventListener("scroll", () => {
      if (this.el.scrollTop < 100 && !this.pending) {
        this.pending = true;
        this.pushEvent("load_more", {});
      }
    });
  },
  updated() {
    this.pending = false;
    if (this.isAtBottom()) {
      this.scrollToBottom();
    }
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight;
  },
  isAtBottom() {
    const threshold = 100;
    return this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < threshold;
  }
};
export default MessageList;
```

The `"load_more"` event is handled by `Index` — it calls `Chat.list_messages/2` with `before: oldest_message_id` and prepends to the stream.

### 1.6 App Layout Adjustment

Modify `lib/slackex_web/components/layouts/app.html.heex`:
- Chat routes (`/chat/**`): full-height edge-to-edge layout, no global navbar, no outer page padding
- Non-chat routes: keep the standard app shell and padded layout

Use LiveView-aware assigns to detect chat context (for example, `assigns[:live_module]`, `@live_action`, or an explicitly assigned `@current_path`). Avoid relying on `@conn` in LiveView-only rendering paths.

### 1.7 Refactor Index LiveView

Refactor `lib/slackex_web/live/chat_live/index.ex`:
- Remove inline sidebar HTML — delegate to `<.live_component module={SidebarComponent} ... />`
- Remove inline message rendering — delegate to `<ChatComponents.message_bubble />` in a comprehension
- Replace `<input>` compose with `<textarea>` inside a `phx-hook="Compose"` container
- Add `handle_info({:sidebar_action, action}, socket)` to receive sidebar events
- Add `handle_event("load_more", _, socket)` for infinite scroll
- Add `handle_event("toggle_sidebar", _, socket)` for mobile hamburger

### Files Changed

| File | Action |
|------|--------|
| `lib/slackex_web/components/chat_components.ex` | **Create** |
| `lib/slackex_web/live/chat_live/sidebar_component.ex` | **Create** |
| `assets/js/hooks/compose.js` | **Create** |
| `assets/js/hooks/message_list.js` | **Modify** (add infinite scroll) |
| `assets/js/app.js` | **Modify** (register Compose hook) |
| `lib/slackex_web/live/chat_live/index.ex` | **Major refactor** |
| `lib/slackex_web/components/layouts/app.html.heex` | **Modify** (chat layout) |

### Acceptance Criteria

- [ ] Sidebar renders as a LiveComponent with channels listed
- [ ] Mobile: sidebar collapses off-screen, hamburger toggles it, backdrop dismisses it
- [ ] Desktop: sidebar is always visible at 256px width
- [ ] Compose: Enter sends, Shift+Enter adds newline, textarea auto-resizes
- [ ] Typing indicator fires debounced events
- [ ] Infinite scroll loads older messages when scrolling to top
- [ ] Auto-scroll to bottom on new messages (only if already at bottom)
- [ ] All existing functionality preserved (send message, receive real-time messages, typing indicators)

---

## Step 2: DM Conversations in UI

Expose the existing DM backend (DM conversations, DM ChannelServers) in the LiveView. Add user search for starting new DMs.

### 2.1 Route Addition

Add DM route to the authenticated live session in `router.ex`:

```elixir
live "/chat/dm/:dm_id", ChatLive.Index, :dm
```

**Route ordering contract (required):**
- Define literal routes before slug routes: `/chat/channels/new`, `/chat/channels/browse`, `/chat/dm/new`, `/chat/profile/edit` must be declared before `/chat/:slug`.
- Keep `/chat/dm/:dm_id` explicit and declared before `/chat/:slug` so `dm` is never captured as a channel slug.

### 2.2 DM Loading in Mount

In `Index.mount/3`, load the current user's DM conversations:

```elixir
dm_conversations = Chat.list_user_dm_conversations(user.id)
# Returns: [%{id, other_user: %User{}, last_message_at, ...}]

socket =
  socket
  |> assign(:dm_conversations, dm_conversations)
```

Pass `@dm_conversations` to `SidebarComponent`. Display below channels with the other user's avatar and name.

### 2.3 DM Handle Params

In `handle_params/3` for the `:dm` action:

```elixir
def handle_params(%{"dm_id" => dm_id}, _uri, %{assigns: %{live_action: :dm}} = socket) do
  user = socket.assigns.current_user
  dm = Chat.get_dm_conversation!(dm_id)

  # Verify user is a participant
  if user.id in [dm.user_a_id, dm.user_b_id] do
    {:noreply, enter_dm(socket, dm)}
  else
    {:noreply, socket |> put_flash(:error, "Not found.") |> redirect(to: ~p"/chat")}
  end
end
```

`enter_dm/2` mirrors `enter_channel/3`: subscribes to `"dm:#{dm_id}"` PubSub topic, loads recent messages via `Chat.list_dm_messages/2`, resets the message stream.

### 2.4 New DM Modal — `new_dm_modal.ex`

Create `lib/slackex_web/live/chat_live/new_dm_modal.ex` as a LiveComponent:

```elixir
defmodule SlackexWeb.ChatLive.NewDmModal do
  use SlackexWeb, :live_component

  # Assigns: @current_user
  # State: @search_query, @search_results

  def handle_event("search", %{"query" => query}, socket) do
    results = Slackex.Accounts.search_users(query, exclude: socket.assigns.current_user.id)
    {:noreply, assign(socket, :search_results, results)}
  end

  def handle_event("select_user", %{"user-id" => user_id}, socket) do
    send(self(), {:start_dm, String.to_integer(user_id)})
    {:noreply, socket}
  end
end
```

Modal opens via patch navigation to `/chat/dm/new` (add route: `live "/chat/dm/new", ChatLive.Index, :new_dm`). The parent `Index` renders the modal conditionally when `@live_action == :new_dm`.

### 2.5 User Search Backend

Add fuzzy user search to `lib/slackex/accounts/accounts.ex`:

```elixir
@doc """
Searches users by username or display_name using trigram similarity.
Returns up to `limit` results, excluding the given user IDs.
"""
def search_users(query, opts \\ []) do
  exclude_ids = Keyword.get(opts, :exclude, []) |> List.wrap()
  limit = Keyword.get(opts, :limit, 10)

  from(u in User,
    where: u.id not in ^exclude_ids,
    where: fragment(
      "? % ? OR ? % ?",
      u.username, ^query, u.display_name, ^query
    ),
    order_by: fragment(
      "LEAST(? <-> ?, ? <-> ?)",
      u.username, ^query, u.display_name, ^query
    ),
    limit: ^limit,
    select: %{id: u.id, username: u.username, display_name: u.display_name, avatar_url: u.avatar_url}
  )
  |> Repo.all()
end
```

### 2.6 Migration — Trigram Indexes

```elixir
defmodule Slackex.Repo.Migrations.AddTrigramIndexesToUsers do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm"

    execute """
    CREATE INDEX users_username_trgm_idx ON users
    USING gin (username gin_trgm_ops)
    """

    execute """
    CREATE INDEX users_display_name_trgm_idx ON users
    USING gin (display_name gin_trgm_ops)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS users_display_name_trgm_idx"
    execute "DROP INDEX IF EXISTS users_username_trgm_idx"
    # Don't drop pg_trgm extension — other things may depend on it
  end
end
```

### 2.7 Start DM Flow

In `Index`, handle the `:start_dm` message from the modal:

```elixir
def handle_info({:start_dm, other_user_id}, socket) do
  user = socket.assigns.current_user

  case Chat.find_or_create_dm(user.id, other_user_id) do
    {:ok, dm} ->
      {:noreply, push_patch(socket, to: ~p"/chat/dm/#{dm.id}")}
    {:error, _} ->
      {:noreply, put_flash(socket, :error, "Could not start conversation.")}
  end
end
```

### Files Changed

| File | Action |
|------|--------|
| `lib/slackex_web/live/chat_live/new_dm_modal.ex` | **Create** |
| `lib/slackex_web/live/chat_live/index.ex` | **Extend** (DM params, start_dm handler) |
| `lib/slackex_web/live/chat_live/sidebar_component.ex` | **Extend** (DM list section) |
| `lib/slackex/accounts/accounts.ex` | **Extend** (search_users/2) |
| `lib/slackex_web/router.ex` | **Extend** (DM routes) |
| `priv/repo/migrations/*_add_trigram_indexes_to_users.exs` | **Create** |

### Acceptance Criteria

- [ ] DM conversations appear in sidebar below channels
- [ ] Clicking a DM navigates to `/chat/dm/:dm_id` and loads messages
- [ ] "+" button in DM section opens the New DM modal
- [ ] User search returns fuzzy matches by username and display name
- [ ] Selecting a user starts (or resumes) a DM conversation
- [ ] Real-time messages work in DM conversations (send, receive, typing)
- [ ] Migration applies cleanly: `mix ecto.migrate`

---

## Step 3: Channel Browsing, Creation & Join/Leave

### 3.1 Create Channel Modal — `create_channel_modal.ex`

Create `lib/slackex_web/live/chat_live/create_channel_modal.ex`:

```elixir
defmodule SlackexWeb.ChatLive.CreateChannelModal do
  use SlackexWeb, :live_component

  # Form fields: name, description, is_private (toggle)
  # Validates: name format (lowercase, hyphens, 3-50 chars), description (optional, max 500)

  def handle_event("validate", %{"channel" => params}, socket)
  def handle_event("save", %{"channel" => params}, socket)
  # On save: Chat.create_channel(current_user, params)
  # On success: send(self(), {:channel_created, channel})
end
```

Route: `live "/chat/channels/new", ChatLive.Index, :create_channel`

The name field auto-formats input to lowercase with hyphens (spaces become hyphens, special chars stripped). Shows live validation feedback.

### 3.2 Browse Channels Modal — `browse_channels_modal.ex`

Create `lib/slackex_web/live/chat_live/browse_channels_modal.ex`:

```elixir
defmodule SlackexWeb.ChatLive.BrowseChannelsModal do
  use SlackexWeb, :live_component

  # Lists public channels the user has NOT joined
  # Shows: channel name, description, member count, "Join" button
  # Search/filter by name

  def mount(socket) do
    channels = Chat.list_public_channels(exclude_member: socket.assigns.current_user.id)
    {:ok, assign(socket, channels: channels, search: "")}
  end

  def handle_event("join", %{"channel-id" => id}, socket)
  # Chat.join_channel(current_user.id, channel_id)
  # send(self(), {:channel_joined, channel})
end
```

Route: `live "/chat/channels/browse", ChatLive.Index, :browse_channels`

### 3.3 Channel Header Actions

Add Join/Leave buttons to the channel header area in `Index`:

- **Not a member of public channel:** Show "Join Channel" button → calls `Chat.join_channel/2`
- **Member (not owner):** Show "Leave Channel" button → calls `Chat.leave_channel/2`
- **Owner:** No leave button (transfer ownership first)

### 3.4 Backend — Member Count

Add to `lib/slackex/chat/chat.ex`:

```elixir
@doc "Returns the number of members in a channel."
def count_members(channel_id) do
  from(s in Subscription, where: s.channel_id == ^channel_id, select: count())
  |> Repo.one()
end

@doc "Lists public channels, optionally excluding channels where user_id is a member."
def list_public_channels(opts \\ []) do
  exclude_member = Keyword.get(opts, :exclude_member)

  query = from(c in Channel, where: c.is_private == false, order_by: [asc: c.name])

  query =
    if exclude_member do
      from c in query,
        left_join: s in Subscription,
        on: s.channel_id == c.id and s.user_id == ^exclude_member,
        where: is_nil(s.id)
    else
      query
    end

  query
  |> Repo.all()
  |> Enum.map(fn channel ->
    Map.put(channel, :member_count, count_members(channel.id))
  end)
end
```

> **Note:** The `count_members` call per channel in `list_public_channels` is an N+1 query. For the browse modal (typically <100 public channels), this is acceptable. If channel count grows significantly, optimize with a subquery or cached count column.

### Files Changed

| File | Action |
|------|--------|
| `lib/slackex_web/live/chat_live/create_channel_modal.ex` | **Create** |
| `lib/slackex_web/live/chat_live/browse_channels_modal.ex` | **Create** |
| `lib/slackex_web/live/chat_live/index.ex` | **Extend** (modal routing, join/leave handlers) |
| `lib/slackex/chat/chat.ex` | **Extend** (count_members, list_public_channels) |
| `lib/slackex_web/router.ex` | **Extend** (channel modal routes) |

### Acceptance Criteria

- [ ] "+" button in channels section opens Create Channel modal
- [ ] Channel creation validates name format and creates channel with user as owner
- [ ] "Browse" link opens Browse Channels modal with public channels
- [ ] Browse modal shows channel name, description, member count
- [ ] "Join" button in browse modal adds user to channel and navigates to it
- [ ] "Leave Channel" button in channel header removes membership
- [ ] Channel list in sidebar updates after join/leave/create

---

## Step 4: User Profiles & Online Status

### 4.1 Edit Profile Modal — `edit_profile_modal.ex`

Create `lib/slackex_web/live/chat_live/edit_profile_modal.ex`:

```elixir
defmodule SlackexWeb.ChatLive.EditProfileModal do
  use SlackexWeb, :live_component

  # Editable fields: display_name, avatar_url, status
  # Uses User.profile_changeset/2 for validation

  def handle_event("validate", %{"user" => params}, socket)
  def handle_event("save", %{"user" => params}, socket)
  # Accounts.update_profile(current_user, params)
end
```

Route: `live "/chat/profile/edit", ChatLive.Index, :edit_profile`

### 4.2 Profile Changeset

Add to `lib/slackex/accounts/user.ex`:

```elixir
@doc "Changeset for profile updates (display_name, avatar_url, status)."
def profile_changeset(user, attrs) do
  user
  |> cast(attrs, [:display_name, :avatar_url, :status])
  |> validate_length(:display_name, max: 100)
  |> validate_length(:avatar_url, max: 500)
  |> validate_length(:status, max: 200)
end
```

Add to `lib/slackex/accounts/accounts.ex`:

```elixir
def update_profile(user, attrs) do
  user
  |> User.profile_changeset(attrs)
  |> Repo.update()
end
```

### 4.3 User Profile Popover

On clicking a username or avatar anywhere in the chat, show a popover/dropdown with:
- Avatar (large), display name, username, status text
- "Send Message" button → starts or navigates to DM
- "Block User" button (see Step 9)

Implementation: use a `<div>` with absolute positioning toggled by `phx-click` on the username element. Store `@profile_popover_user_id` in Index assigns.

### 4.4 Online Status Integration

The `OnlineTracker` module already tracks online users. Integrate into UI:

1. In `Index.mount/3`, fetch online user IDs: `online_ids = OnlineTracker.online_user_ids()`
2. Pass `@online_user_ids` to `SidebarComponent` and use in `avatar/1` component
3. Subscribe to presence diffs to keep online status live:
   ```elixir
   if connected?(socket) do
     Phoenix.PubSub.subscribe(Slackex.PubSub, "presence:lobby")
   end
   ```
4. Handle presence diffs in `handle_info` to update `@online_user_ids`

### 4.5 Sidebar User Footer

Add to `SidebarComponent` bottom section:
- Current user's avatar with online dot
- Display name (or username fallback)
- Status text (truncated)
- Edit profile button (pencil icon)
- Theme toggle button (sun/moon icon, uses existing `theme.js`)

### Files Changed

| File | Action |
|------|--------|
| `lib/slackex_web/live/chat_live/edit_profile_modal.ex` | **Create** |
| `lib/slackex/accounts/user.ex` | **Extend** (profile_changeset) |
| `lib/slackex/accounts/accounts.ex` | **Extend** (update_profile) |
| `lib/slackex_web/components/chat_components.ex` | **Extend** (online indicator in avatar) |
| `lib/slackex_web/live/chat_live/sidebar_component.ex` | **Extend** (user footer, online dots on DMs) |
| `lib/slackex_web/live/chat_live/index.ex` | **Extend** (profile popover, online tracking) |
| `lib/slackex_web/router.ex` | **Extend** (profile route) |

### Acceptance Criteria

- [ ] Edit Profile modal allows changing display_name, avatar_url, status
- [ ] Profile changes persist and reflect immediately in sidebar and messages
- [ ] Clicking a username shows a profile popover with user info
- [ ] Online indicator (green dot) appears on avatars of online users
- [ ] Sidebar DM items show online status of the other user
- [ ] Sidebar footer shows current user info with edit and theme toggle buttons

---

## Step 5: Message Editing & Deletion

### 5.1 Migration — Soft Delete Column

```elixir
defmodule Slackex.Repo.Migrations.AddDeletedAtToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :deleted_at, :utc_datetime_usec
    end

    create index(:messages, [:deleted_at], where: "deleted_at IS NOT NULL")
  end
end
```

### 5.2 Schema Update

Add to `lib/slackex/chat/message.ex`:

```elixir
field :deleted_at, :utc_datetime_usec
```

Add edit changeset:

```elixir
def edit_changeset(message, attrs) do
  message
  |> cast(attrs, [:content, :edited_at])
  |> validate_required([:content])
  |> validate_length(:content, min: 1, max: 4000)
end
```

### 5.3 Backend Functions

Add to `lib/slackex/chat/chat.ex`:

```elixir
@doc "Edits a message. Only the sender can edit their own messages."
def edit_message(message_id, user_id, new_content) do
  message = get_message!(message_id)

  cond do
    message.sender_id != user_id ->
      {:error, :unauthorized}
    message.deleted_at != nil ->
      {:error, :already_deleted}
    true ->
      message
      |> Message.edit_changeset(%{content: new_content, edited_at: DateTime.utc_now()})
      |> Repo.update()
  end
end

@doc """
Soft-deletes a message. Sender can delete own messages.
Admins/owners can delete any message in their channels.
"""
def delete_message(message_id, user_id) do
  message = get_message!(message_id)

  authorized =
    message.sender_id == user_id ||
      (message.channel_id && can_manage?(user_id, message.channel_id))

  if authorized do
    message
    |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
    |> Repo.update()
  else
    {:error, :unauthorized}
  end
end

defp can_manage?(user_id, channel_id) do
  role = get_role(user_id, channel_id)
  Permissions.can?(role, :manage_channel)
end
```

### 5.4 Messaging Facade

Add to `lib/slackex/messaging/messaging.ex`:

```elixir
def edit_message(channel_id, user_id, message_id, new_content) do
  with {:ok, message} <- Chat.edit_message(message_id, user_id, new_content) do
    broadcast_envelope(channel_id, "message.edited", %{
      message_id: message.id,
      content: message.content,
      edited_at: message.edited_at
    })
    {:ok, message}
  end
end

def delete_message(channel_id, user_id, message_id) do
  with {:ok, message} <- Chat.delete_message(message_id, user_id) do
    broadcast_envelope(channel_id, "message.deleted", %{
      message_id: message.id,
      deleted_at: message.deleted_at
    })
    {:ok, message}
  end
end
```

### 5.5 ChannelServer Extension

Add `handle_call` clauses to `lib/slackex/messaging/channel_server.ex` for edit and delete:

- **Edit:** Updates the message in the in-memory queue (find by ID, replace content), then persists via `Chat.edit_message/3`, broadcasts `"message.edited"` envelope
- **Delete:** Marks the message in the in-memory queue with `deleted_at`, persists via `Chat.delete_message/2`, broadcasts `"message.deleted"` envelope

### 5.6 UI — Hover Actions & Inline Edit

In `message_bubble/1` component:

- **Hover actions** (visible on mouse hover via CSS `group-hover`): Edit (pencil icon), Delete (trash icon), React (smiley icon), Reply (arrow icon)
- **Edit mode:** When user clicks edit, the message content area transforms into a textarea with the current content, plus Save/Cancel buttons. `phx-submit` sends `"save_edit"` event to Index.
- **Deleted placeholder:** When `message.deleted_at` is not nil, render `"[This message was deleted]"` in italic gray text instead of the content.
- **Edited indicator:** When `message.edited_at` is not nil, show "(edited)" text after the timestamp.

### 5.7 LiveView Event Handlers

Add to `Index`:

```elixir
# Enter edit mode
def handle_event("start_edit", %{"message-id" => id}, socket)
# Save edit
def handle_event("save_edit", %{"message-id" => id, "content" => content}, socket)
# Cancel edit
def handle_event("cancel_edit", _, socket)
# Delete message (with confirmation)
def handle_event("delete_message", %{"message-id" => id}, socket)

# Real-time handlers
def handle_info({:envelope, %{event: "message.edited", payload: payload}}, socket)
def handle_info({:envelope, %{event: "message.deleted", payload: payload}}, socket)
```

Edit and delete update the stream item in-place via `stream_insert/3` with the updated message.

### Files Changed

| File | Action |
|------|--------|
| `lib/slackex/chat/message.ex` | **Extend** (deleted_at field, edit_changeset) |
| `lib/slackex/chat/chat.ex` | **Extend** (edit_message, delete_message) |
| `lib/slackex/messaging/messaging.ex` | **Extend** (edit/delete facade) |
| `lib/slackex/messaging/channel_server.ex` | **Extend** (edit/delete handle_call) |
| `lib/slackex_web/components/chat_components.ex` | **Extend** (hover actions, edit mode, deleted state) |
| `lib/slackex_web/live/chat_live/index.ex` | **Extend** (edit/delete events + PubSub handlers) |
| `priv/repo/migrations/*_add_deleted_at_to_messages.exs` | **Create** |

### Acceptance Criteria

- [ ] Hovering a message reveals action buttons (edit, delete, react, reply)
- [ ] Clicking edit transforms message into inline textarea with save/cancel
- [ ] Saving edit persists and broadcasts — all connected clients see the update
- [ ] "(edited)" indicator appears on edited messages
- [ ] Delete soft-deletes and shows "[This message was deleted]" placeholder
- [ ] Admins can delete any message in channels they manage
- [ ] Cannot edit or delete already-deleted messages
- [ ] Real-time: edit/delete events update other clients immediately

---

## Step 6: Reactions

### 6.1 Migration — Message Reactions Table

```elixir
defmodule Slackex.Repo.Migrations.CreateMessageReactions do
  use Ecto.Migration

  def change do
    create table(:message_reactions) do
      add :message_id, references(:messages, type: :bigint, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :emoji, :string, null: false, size: 50

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:message_reactions, [:message_id, :user_id, :emoji])
    create index(:message_reactions, [:message_id])
  end
end
```

### 6.2 Schema — `message_reaction.ex`

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

### 6.3 Backend Functions

Add to `lib/slackex/chat/chat.ex`:

```elixir
@doc """
Toggles a reaction on a message. If the user has already reacted with
this emoji, removes it. Otherwise, adds it. Returns {:added, reaction} or {:removed, reaction}.
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
      Repo.delete(reaction)
      {:ok, {:removed, reaction}}
  end
end

@doc """
Batch-loads reactions for a list of message IDs.
Returns %{message_id => [%{emoji: "...", count: N, user_ids: [...]}]}
"""
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

### 6.4 Emoji Picker Hook — `emoji_picker.js`

Create `assets/js/hooks/emoji_picker.js`:

```javascript
// Uses emoji-mart web component (lightweight, framework-agnostic)
import { Picker } from "emoji-mart";

const EmojiPicker = {
  mounted() {
    this.picker = null;
    this.el.addEventListener("click", (e) => {
      if (e.target.closest("[data-emoji-trigger]")) {
        this.togglePicker(e.target.closest("[data-emoji-trigger]"));
      }
    });
    document.addEventListener("click", (e) => {
      if (this.picker && !this.el.contains(e.target)) {
        this.closePicker();
      }
    });
  },
  togglePicker(trigger) {
    if (this.picker) {
      this.closePicker();
      return;
    }
    const messageId = trigger.dataset.messageId;
    const container = document.createElement("div");
    container.className = "absolute z-50 bottom-full mb-2";
    this.picker = new Picker({
      onEmojiSelect: (emoji) => {
        this.pushEvent("toggle_reaction", { message_id: messageId, emoji: emoji.native });
        this.closePicker();
      },
      theme: document.documentElement.dataset.theme === "dark" ? "dark" : "light",
      previewPosition: "none",
      skinTonePosition: "none",
      maxFrequentRows: 2,
    });
    container.appendChild(this.picker);
    trigger.parentElement.appendChild(container);
  },
  closePicker() {
    if (this.picker) {
      this.picker.parentElement?.remove();
      this.picker = null;
    }
  },
  destroyed() {
    this.closePicker();
  },
};
export default EmojiPicker;
```

### 6.5 UI — Reaction Bar

Add `reaction_bar/1` component to `chat_components.ex`:

```elixir
attr :reactions, :list, default: []
attr :current_user_id, :integer, required: true
attr :message_id, :integer, required: true
def reaction_bar(assigns)
# Renders emoji pills: each shows emoji + count
# Own reactions highlighted with primary color
# "+" button triggers emoji picker
```

### 6.6 LiveView Integration

Add to `Index`:
- Load reactions when entering a channel: `reactions = Chat.list_reactions(message_ids)`
- Store `@reactions` as a map in assigns
- Handle `"toggle_reaction"` event → call `Chat.toggle_reaction/3`, broadcast envelope
- Handle `{:envelope, %{event: "reaction.toggled"}}` → update `@reactions` assign

### Files Changed

| File | Action |
|------|--------|
| `lib/slackex/chat/message_reaction.ex` | **Create** |
| `lib/slackex/chat/chat.ex` | **Extend** (toggle_reaction, list_reactions) |
| `assets/js/hooks/emoji_picker.js` | **Create** |
| `assets/js/app.js` | **Modify** (register EmojiPicker hook) |
| `lib/slackex_web/components/chat_components.ex` | **Extend** (reaction_bar component) |
| `lib/slackex_web/live/chat_live/index.ex` | **Extend** (reaction events + PubSub) |
| `priv/repo/migrations/*_create_message_reactions.exs` | **Create** |
| `package.json` | **Modify** (add emoji-mart dependency) |

### Acceptance Criteria

- [ ] "+" button on message hover opens emoji picker
- [ ] Selecting an emoji adds a reaction pill below the message
- [ ] Clicking an existing reaction pill toggles it (add if not reacted, remove if already reacted)
- [ ] Own reactions are visually highlighted
- [ ] Reaction counts update in real-time for all connected clients
- [ ] Reactions persist across page reloads
- [ ] Batch loading prevents N+1 queries when loading message list

---

## Step 7: Threads/Replies

### 7.1 Migration — Thread Fields

```elixir
defmodule Slackex.Repo.Migrations.AddThreadsToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :parent_message_id, references(:messages, type: :bigint, on_delete: :nilify_all)
      add :reply_count, :integer, default: 0, null: false
    end

    create index(:messages, [:parent_message_id], where: "parent_message_id IS NOT NULL")
  end
end
```

### 7.2 Schema Update

Add to `lib/slackex/chat/message.ex`:

```elixir
field :parent_message_id, :integer
field :reply_count, :integer, default: 0

belongs_to :parent_message, __MODULE__, foreign_key: :parent_message_id, define_field: false
has_many :replies, __MODULE__, foreign_key: :parent_message_id
```

### 7.3 Backend Functions

Add to `lib/slackex/chat/chat.ex`:

```elixir
@doc "Sends a reply to a parent message. Increments parent's reply_count atomically."
def send_reply(channel_id, sender_id, parent_message_id, content) do
  Repo.transaction(fn ->
    # Verify parent exists and belongs to this channel
    parent = get_message!(parent_message_id)

    if parent.channel_id != channel_id && parent.dm_conversation_id != nil do
      Repo.rollback(:invalid_parent)
    end

    # Create the reply message
    reply_attrs = %{
      content: content,
      sender_id: sender_id,
      channel_id: parent.channel_id,
      dm_conversation_id: parent.dm_conversation_id,
      parent_message_id: parent_message_id
    }

    # Atomically increment parent reply_count
    from(m in Message, where: m.id == ^parent_message_id)
    |> Repo.update_all(inc: [reply_count: 1])

    reply_attrs
  end)
end

@doc "Lists replies to a parent message, ordered by insertion time."
def list_thread(parent_message_id, opts \\ []) do
  limit = Keyword.get(opts, :limit, 50)

  from(m in Message,
    where: m.parent_message_id == ^parent_message_id,
    where: is_nil(m.deleted_at),
    order_by: [asc: m.inserted_at],
    limit: ^limit,
    preload: [:sender]
  )
  |> Repo.all()
end
```

### 7.4 Thread Panel LiveComponent — `thread_panel_component.ex`

Create `lib/slackex_web/live/chat_live/thread_panel_component.ex`:

```elixir
defmodule SlackexWeb.ChatLive.ThreadPanelComponent do
  use SlackexWeb, :live_component

  # Assigns from parent:
  # @parent_message  - the message being replied to
  # @current_user    - logged-in user
  # State:
  # @replies         - list of reply messages
  # @reply_form      - form for new reply

  def mount(socket) do
    {:ok, assign(socket, replies: [], reply_form: to_form(%{"content" => ""}, as: :reply))}
  end

  def update(%{parent_message: parent} = assigns, socket) do
    replies = Chat.list_thread(parent.id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Slackex.PubSub, "thread:#{parent.id}")
    end

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:replies, replies)}
  end

  def handle_event("send_reply", %{"reply" => %{"content" => content}}, socket)
  # Messaging.send_reply(channel_id, user_id, parent_id, content)
end
```

**Layout:** The thread panel is a sliding right panel:
- Desktop: 400px wide, alongside the main message list (message list shrinks to accommodate)
- Mobile: full-width overlay with a back button
- Contains: parent message (read-only, highlighted), reply list, compose box

### 7.5 PubSub for Threads

New PubSub topic: `"thread:#{parent_message_id}"`

When a reply is sent:
1. Broadcast `"message.new"` on the channel's main topic (reply appears in channel with "in thread" indicator)
2. Broadcast `"thread.reply"` on `"thread:#{parent_id}"` topic (reply appears in thread panel)
3. Update parent message's `reply_count` in the main channel stream

### 7.6 ChannelServer Extension

Extend `send_message` flow to accept optional `parent_message_id`:
- If present, the message is a reply — set `parent_message_id` in the message map
- Atomically increment parent's `reply_count`
- Broadcast to both channel and thread topics

### 7.7 BatchWriter Extension

Include `parent_message_id` in the row mapping in `lib/slackex/messaging/batch_writer.ex`. The field is nullable — regular messages have `nil`, replies have the parent's ID.

### 7.8 Thread Routing

Add to router: `live "/chat/:slug/thread/:message_id", ChatLive.Index, :thread`

In `Index`, when `@live_action == :thread`:
- Parse `message_id` from params
- Load parent message
- Render `ThreadPanelComponent` alongside message list

"N replies" link on messages with `reply_count > 0` navigates via patch navigation to the thread route.

### Files Changed

| File | Action |
|------|--------|
| `lib/slackex_web/live/chat_live/thread_panel_component.ex` | **Create** |
| `lib/slackex/chat/message.ex` | **Extend** (parent_message_id, reply_count, associations) |
| `lib/slackex/chat/chat.ex` | **Extend** (send_reply, list_thread) |
| `lib/slackex/messaging/messaging.ex` | **Extend** (send_reply facade) |
| `lib/slackex/messaging/channel_server.ex` | **Extend** (parent_message_id in send flow) |
| `lib/slackex/messaging/batch_writer.ex` | **Extend** (include parent_message_id) |
| `lib/slackex_web/live/chat_live/index.ex` | **Extend** (thread state, routing, PubSub) |
| `lib/slackex_web/router.ex` | **Extend** (thread route) |
| `priv/repo/migrations/*_add_threads_to_messages.exs` | **Create** |

### Acceptance Criteria

- [ ] "Reply" action on a message opens the thread panel
- [ ] Thread panel shows parent message and its replies
- [ ] Typing in thread panel and sending creates a reply
- [ ] Parent message shows "N replies" link when reply_count > 0
- [ ] Clicking "N replies" opens the thread panel
- [ ] Replies broadcast in real-time to thread panel subscribers
- [ ] Replies also appear in the main channel as regular messages (with thread indicator)
- [ ] Thread panel closes when navigating away or clicking close button
- [ ] Desktop: thread panel and message list visible side by side
- [ ] Mobile: thread panel takes full width with back button

---

## Step 8: Channel Members & Pinned Messages

### 8.1 Migration — Pinned Messages Table

```elixir
defmodule Slackex.Repo.Migrations.CreatePinnedMessages do
  use Ecto.Migration

  def change do
    create table(:pinned_messages) do
      add :message_id, references(:messages, type: :bigint, on_delete: :delete_all), null: false
      add :channel_id, references(:channels, on_delete: :delete_all), null: false
      add :pinned_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:pinned_messages, [:message_id, :channel_id])
    create index(:pinned_messages, [:channel_id])
  end
end
```

### 8.2 Schema — `pinned_message.ex`

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

### 8.3 Backend Functions

Add to `lib/slackex/chat/chat.ex`:

```elixir
# --- Members ---

@doc "Lists members of a channel with their roles."
def list_members(channel_id) do
  from(s in Subscription,
    where: s.channel_id == ^channel_id,
    join: u in assoc(s, :user),
    select: %{user: u, role: s.role, joined_at: s.inserted_at}
  )
  |> Repo.all()
end

@doc "Updates a member's role. Requires manage_channel permission."
def update_member_role(channel_id, actor_user_id, target_user_id, new_role)
    when new_role in ~w(admin member viewer) do
  actor_role = get_role(actor_user_id, channel_id)
  target_role = get_role(target_user_id, channel_id)

  cond do
    not Permissions.can?(actor_role, :manage_channel) ->
      {:error, :unauthorized}
    actor_user_id == target_user_id ->
      {:error, :cannot_change_own_role}
    is_nil(target_role) ->
      {:error, :not_a_member}
    target_role == "owner" ->
      {:error, :cannot_modify_owner}
    true ->
      from(s in Subscription,
        where: s.channel_id == ^channel_id and s.user_id == ^target_user_id
      )
      |> Repo.update_all(set: [role: new_role])
      |> case do
        {1, _} -> :ok
        {0, _} -> {:error, :update_failed}
      end
  end
end

@doc "Removes a member from a channel. Requires manage_channel permission."
def kick_member(channel_id, actor_user_id, target_user_id) do
  actor_role = get_role(actor_user_id, channel_id)
  target_role = get_role(target_user_id, channel_id)

  cond do
    not Permissions.can?(actor_role, :manage_channel) ->
      {:error, :unauthorized}
    actor_user_id == target_user_id ->
      {:error, :cannot_kick_self}
    is_nil(target_role) ->
      {:error, :not_a_member}
    target_role == "owner" ->
      {:error, :cannot_kick_owner}
    true ->
      from(s in Subscription,
        where: s.channel_id == ^channel_id and s.user_id == ^target_user_id
      )
      |> Repo.delete_all()
      |> case do
        {1, _} -> :ok
        {0, _} -> {:error, :not_a_member}
      end
  end
end

# --- Pins ---

@doc "Pins a message in a channel. Requires admin+ role."
def pin_message(channel_id, user_id, message_id) do
  role = get_role(user_id, channel_id)

  if Permissions.can?(role, :manage_channel) do
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

  if Permissions.can?(role, :manage_channel) do
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
    join: m in assoc(p, :message),
    join: u in assoc(m, :sender),
    order_by: [desc: p.inserted_at],
    preload: [message: {m, sender: u}]
  )
  |> Repo.all()
end
```

### 8.4 Permissions Extension

Add to `lib/slackex/chat/permissions.ex`:

```elixir
@action_min_level %{
  send_message: 2,
  read_messages: 1,
  manage_channel: 3,
  delete_channel: 4,
  manage_members: 3,  # new
  pin_message: 3       # new
}
```

### 8.5 Channel Members Modal — `channel_members_modal.ex`

Create `lib/slackex_web/live/chat_live/channel_members_modal.ex`:

- Lists all channel members with avatar, name, role badge (owner/admin/member/viewer)
- Admin+ users see role dropdown (promote/demote) and kick button per member
- Owner cannot be kicked or demoted (enforced in backend, not only hidden in UI)
- Search/filter members by name

Route: `live "/chat/:slug/members", ChatLive.Index, :members`

### 8.6 Pinned Messages Modal — `pinned_messages_modal.ex`

Create `lib/slackex_web/live/chat_live/pinned_messages_modal.ex`:

- Lists pinned messages with content preview, sender, and pin date
- Admin+ users see "Unpin" button per message
- Clicking a pinned message scrolls to it in the main message list (or loads it if not in view)

Route: `live "/chat/:slug/pins", ChatLive.Index, :pinned`

### 8.7 Channel Header Enhancement

Add to channel header:
- Members count with icon → links to members modal
- Pin icon with count badge → links to pinned messages modal
- "Pin" action in message hover actions (for admin+ users)

### Files Changed

| File | Action |
|------|--------|
| `lib/slackex/chat/pinned_message.ex` | **Create** |
| `lib/slackex_web/live/chat_live/channel_members_modal.ex` | **Create** |
| `lib/slackex_web/live/chat_live/pinned_messages_modal.ex` | **Create** |
| `lib/slackex/chat/chat.ex` | **Extend** (members, pins functions) |
| `lib/slackex/chat/permissions.ex` | **Extend** (manage_members, pin_message actions) |
| `lib/slackex_web/live/chat_live/index.ex` | **Extend** (modal routing, pin events) |
| `lib/slackex_web/router.ex` | **Extend** (members, pins routes) |
| `priv/repo/migrations/*_create_pinned_messages.exs` | **Create** |

### Acceptance Criteria

- [ ] Channel header shows member count and pin count
- [ ] Members modal lists all channel members with role badges
- [ ] Admin+ can promote, demote, and kick members
- [ ] Owner cannot be kicked or demoted (backend returns `:cannot_modify_owner` / `:cannot_kick_owner`)
- [ ] Pin action appears on message hover for admin+ users
- [ ] Pinned messages modal lists all pins with message previews
- [ ] Admin+ can unpin messages
- [ ] Migration applies cleanly

---

## Step 9: Invite Links & User Blocks

### 9.1 Migrations

**Invite Links:**

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

**User Blocks:**

```elixir
defmodule Slackex.Repo.Migrations.CreateUserBlocks do
  use Ecto.Migration

  def change do
    create table(:user_blocks) do
      add :blocker_id, references(:users, on_delete: :delete_all), null: false
      add :blocked_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:user_blocks, [:blocker_id, :blocked_id])
    create index(:user_blocks, [:blocked_id])
  end
end
```

### 9.2 Schemas

**`lib/slackex/chat/invite_link.ex`:**

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
    |> validate_required([:code, :channel_id])
    |> unique_constraint(:code)
    |> put_code_if_missing()
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

**`lib/slackex/accounts/user_block.ex`:**

```elixir
defmodule Slackex.Accounts.UserBlock do
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_blocks" do
    belongs_to :blocker, Slackex.Accounts.User, foreign_key: :blocker_id
    belongs_to :blocked, Slackex.Accounts.User, foreign_key: :blocked_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(block, attrs) do
    block
    |> cast(attrs, [:blocker_id, :blocked_id])
    |> validate_required([:blocker_id, :blocked_id])
    |> validate_not_self_block()
    |> unique_constraint([:blocker_id, :blocked_id])
  end

  defp validate_not_self_block(changeset) do
    blocker = get_field(changeset, :blocker_id)
    blocked = get_field(changeset, :blocked_id)

    if blocker && blocker == blocked do
      add_error(changeset, :blocked_id, "cannot block yourself")
    else
      changeset
    end
  end
end
```

### 9.3 Backend Functions — Invites

Add to `lib/slackex/chat/chat.ex`:

```elixir
@doc "Creates an invite link for a channel. Requires manage_channel permission."
def create_invite_link(channel_id, user_id, opts \\ []) do
  role = get_role(user_id, channel_id)

  if Permissions.can?(role, :manage_channel) do
    max_uses = Keyword.get(opts, :max_uses)
    expires_in_hours = Keyword.get(opts, :expires_in_hours, 168)  # 7 days default

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(expires_in_hours * 3600, :second)

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

@doc "Redeems an invite code. Adds the user to the channel if the invite is valid."
def redeem_invite(code, user_id) do
  Repo.transaction(fn ->
    invite =
      from(i in InviteLink,
        where: i.code == ^code,
        lock: "FOR UPDATE"
      )
      |> Repo.one()
      || Repo.rollback(:not_found)

    cond do
      invite.expires_at && DateTime.compare(DateTime.utc_now(), invite.expires_at) == :gt ->
        Repo.rollback(:expired)

      invite.max_uses && invite.use_count >= invite.max_uses ->
        Repo.rollback(:max_uses_reached)

      get_role(user_id, invite.channel_id) != nil ->
        Repo.rollback(:already_member)

      true ->
        # Invite redemption must be valid for private channels as well.
        %Subscription{}
        |> Subscription.changeset(%{
          user_id: user_id,
          channel_id: invite.channel_id,
          role: "member"
        })
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :channel_id])
        |> case do
          {:ok, _subscription} ->
            case from(i in InviteLink,
                   where: i.id == ^invite.id,
                   where: is_nil(i.max_uses) or i.use_count < i.max_uses
                 )
                 |> Repo.update_all(inc: [use_count: 1]) do
              {1, _} -> invite
              {0, _} -> Repo.rollback(:max_uses_reached)
            end

          {:error, _changeset} ->
            Repo.rollback(:join_failed)
        end
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

### 9.4 Backend Functions — Blocks

Add to `lib/slackex/accounts/accounts.ex`:

```elixir
@doc "Blocks a user. Blocked users cannot send DMs to the blocker."
def block_user(blocker_id, blocked_id) do
  %UserBlock{}
  |> UserBlock.changeset(%{blocker_id: blocker_id, blocked_id: blocked_id})
  |> Repo.insert()
end

@doc "Unblocks a user."
def unblock_user(blocker_id, blocked_id) do
  from(b in UserBlock,
    where: b.blocker_id == ^blocker_id and b.blocked_id == ^blocked_id
  )
  |> Repo.delete_all()

  :ok
end

@doc "Checks if a user is blocked by another user."
def blocked?(blocker_id, blocked_id) do
  Repo.exists?(
    from(b in UserBlock,
      where: b.blocker_id == ^blocker_id and b.blocked_id == ^blocked_id
    )
  )
end
```

**DM blocking enforcement:** In `Messaging.send_message/3`, before sending a DM message, check if the sender is blocked by the recipient:

```elixir
# In the DM send path
if Accounts.blocked?(recipient_id, sender_id) do
  {:error, :blocked}
end
```

### 9.5 Invite Link Modal — `invite_link_modal.ex`

Create `lib/slackex_web/live/chat_live/invite_link_modal.ex`:

- Lists existing invite links with code, uses, expiry, and revoke button
- "Generate Link" form with max_uses (optional) and expiry duration dropdown
- Generated link displayed with copy-to-clipboard button

Route: `live "/chat/:slug/invites", ChatLive.Index, :invites`

### 9.6 Public Invite Route — `invite_live.ex`

Create `lib/slackex_web/live/invite_live.ex`:

```elixir
defmodule SlackexWeb.InviteLive do
  use SlackexWeb, :live_view

  def mount(%{"code" => code}, _session, socket) do
    case socket.assigns[:current_user] do
      nil ->
        # Store code in session and redirect to login
        {:ok, redirect(socket, to: ~p"/users/log-in?invite=#{code}")}

      user ->
        case Chat.redeem_invite(code, user.id) do
          {:ok, invite} ->
            channel = Chat.get_channel!(invite.channel_id)
            {:ok, redirect(socket, to: ~p"/chat/#{channel.slug}")}

          {:error, :already_member} ->
            invite = Repo.get_by!(InviteLink, code: code)
            channel = Chat.get_channel!(invite.channel_id)
            {:ok, redirect(socket, to: ~p"/chat/#{channel.slug}")}

          {:error, reason} ->
            {:ok, assign(socket, :error, invite_error_message(reason))}
        end
    end
  end
end
```

Router: `live "/invite/:code", InviteLive, :redeem` (outside authenticated session — handles both cases)

### 9.7 Copy to Clipboard Hook — `copy_to_clipboard.js`

Create `assets/js/hooks/copy_to_clipboard.js`:

```javascript
const CopyToClipboard = {
  mounted() {
    this.el.addEventListener("click", () => {
      const text = this.el.dataset.clipboardText;
      navigator.clipboard.writeText(text).then(() => {
        const original = this.el.textContent;
        this.el.textContent = "Copied!";
        setTimeout(() => { this.el.textContent = original; }, 2000);
      });
    });
  },
};
export default CopyToClipboard;
```

### Files Changed

| File | Action |
|------|--------|
| `lib/slackex/chat/invite_link.ex` | **Create** |
| `lib/slackex/accounts/user_block.ex` | **Create** |
| `lib/slackex_web/live/chat_live/invite_link_modal.ex` | **Create** |
| `lib/slackex_web/live/invite_live.ex` | **Create** |
| `assets/js/hooks/copy_to_clipboard.js` | **Create** |
| `assets/js/app.js` | **Modify** (register CopyToClipboard hook) |
| `lib/slackex/chat/chat.ex` | **Extend** (invite functions) |
| `lib/slackex/accounts/accounts.ex` | **Extend** (block functions) |
| `lib/slackex/messaging/messaging.ex` | **Extend** (block check in DM send) |
| `lib/slackex_web/router.ex` | **Extend** (invite routes) |
| `priv/repo/migrations/*_create_invite_links.exs` | **Create** |
| `priv/repo/migrations/*_create_user_blocks.exs` | **Create** |

### Acceptance Criteria

- [ ] Admin+ can generate invite links with optional max uses and expiry
- [ ] Invite link URL can be copied to clipboard
- [ ] Admin+ can revoke invite links
- [ ] Public `/invite/:code` route redeems the invite and joins the user to the channel
- [ ] Unauthenticated users are redirected to login, then back to invite redemption
- [ ] Expired and maxed-out invites show appropriate error messages
- [ ] Block/unblock actions available in user profile popover
- [ ] Blocked users cannot send DMs (receive `{:error, :blocked}`)
- [ ] Migrations apply cleanly

---

## Step 10: Unread Counts, Catchup & Polish

### 10.1 Bulk Unread Counts

Add to `lib/slackex/chat/chat.ex`:

```elixir
@doc """
Returns unread message counts for all channels/DMs a user is subscribed to.
Single query instead of N queries per channel.
Returns %{channel_id => unread_count}.
"""
def bulk_unread_counts(user_id) do
  from(s in Subscription,
    left_join: rc in ReadCursor,
    on: rc.user_id == ^user_id and rc.channel_id == s.channel_id,
    left_lateral_join: c in fragment(
      "SELECT COUNT(*) AS cnt FROM messages WHERE channel_id = ? AND id > COALESCE(?, 0) AND deleted_at IS NULL",
      s.channel_id, rc.last_read_message_id
    ),
    where: s.user_id == ^user_id,
    select: {s.channel_id, c.cnt}
  )
  |> Repo.all()
  |> Map.new()
end
```

> **Implementation note:** The lateral join approach executes as a single query with one pass over subscriptions. For users with many channels (>100), consider caching this in ETS with a short TTL (5 seconds) and invalidating on message receipt.

### 10.2 Sidebar Unread Badges

In `Index.mount/3`:
```elixir
unread_counts = Chat.bulk_unread_counts(user.id)
|> assign(:unread_counts, unread_counts)
```

Pass `@unread_counts` to `SidebarComponent`. The `channel_list_item/1` and `dm_list_item/1` components render an `unread_badge/1` when count > 0.

On new message receipt (in `handle_info` for `"message.new"` envelope):
- If the message is for the currently active channel → mark as read (already done)
- If for a different channel → increment `@unread_counts[channel_id]`

On entering a channel → reset that channel's count to 0.

### 10.3 Catchup Integration

On socket reconnection (detected via `connected?/1` returning `true` after a disconnect):

```elixir
if connected?(socket) do
  # If we have a last_seen_id, request catchup
  if socket.assigns[:last_seen_id] do
    case Slackex.Messaging.CatchupServer.build_catchup(
      user_id: user.id,
      last_seen_id: socket.assigns.last_seen_id
    ) do
      {:ok, catchup} ->
        # Apply missed messages to relevant streams
        # Update unread counts
        socket
      {:error, _} ->
        socket
    end
  end
end
```

Track `@last_seen_id` — updated to the latest message ID whenever a message is received.

### 10.4 Theme Toggle

The existing `assets/js/theme.js` handles theme persistence. Connect it to the sidebar footer toggle button:

```elixir
# In sidebar_component.ex
<button phx-click={JS.dispatch("toggle-theme")} class="btn btn-ghost btn-sm btn-circle">
  <.icon name="hero-sun-solid" class="hidden dark:block h-4 w-4" />
  <.icon name="hero-moon-solid" class="dark:hidden h-4 w-4" />
</button>
```

### 10.5 Quick Switcher (Ctrl+K / Cmd+K)

Add a `QuickSwitcher` JS hook that listens for `Ctrl+K` / `Cmd+K`:

```javascript
// In app.js or a dedicated hook
document.addEventListener("keydown", (e) => {
  if ((e.ctrlKey || e.metaKey) && e.key === "k") {
    e.preventDefault();
    // Push event to LiveView to open quick switcher modal
    window.liveSocket?.main?.channel?.push("event", {
      type: "quick_switcher",
      event: "phx:open_quick_switcher"
    });
  }
});
```

The quick switcher is a modal with a search input that fuzzy-matches channel names and DM conversation names. Selecting an item navigates via patch navigation.

### 10.6 Visual Polish

Final pass across all components:

- **Consistent spacing:** Use Tailwind `space-y` and `gap` utilities consistently. Message list: `space-y-1`. Sidebar items: `space-y-0.5`.
- **Transitions:** Sidebar slide `duration-200 ease-in-out`. Modal fade `duration-150`. Thread panel slide `duration-200`.
- **Empty states:** Use `empty_state/1` component for: no channels ("Create or join a channel to get started"), no messages ("Start the conversation!"), no search results ("No matches found"), no DMs ("Start a conversation").
- **Loading states:** Show skeleton placeholders while messages load. Subtle spinner in compose button while sending.
- **Focus management:** Auto-focus compose textarea when entering a channel. Return focus to trigger element when closing modals.
- **Truncation:** Long channel names truncated with `truncate` class. Long messages wrap naturally. Long usernames truncated in sidebar.

### Files Changed

| File | Action |
|------|--------|
| `lib/slackex_web/live/chat_live/index.ex` | **Extend** (unread tracking, catchup, quick switcher) |
| `lib/slackex_web/live/chat_live/sidebar_component.ex` | **Extend** (unread badges, theme toggle) |
| `lib/slackex/chat/chat.ex` | **Extend** (bulk_unread_counts) |
| `lib/slackex_web/components/chat_components.ex` | **Extend** (polish, empty states, loading) |
| `assets/js/app.js` | **Modify** (quick switcher keybinding) |

### Acceptance Criteria

- [ ] Unread badges appear on sidebar channels/DMs with new messages
- [ ] Badges clear when entering a channel
- [ ] Unread counts load efficiently via single bulk query
- [ ] On reconnection, missed messages are caught up via CatchupServer
- [ ] Theme toggle switches between light and dark modes
- [ ] Ctrl+K / Cmd+K opens quick switcher
- [ ] Quick switcher fuzzy-searches channels and DMs
- [ ] Empty states render for all empty collections
- [ ] Transitions are smooth (sidebar, modals, thread panel)
- [ ] All components have consistent spacing and styling

---

## New Database Migrations Summary

| # | Migration | Step | Table/Column |
|---|-----------|------|--------------|
| 1 | `add_trigram_indexes_to_users` | 2 | pg_trgm extension + GIN indexes on users |
| 2 | `add_deleted_at_to_messages` | 5 | `messages.deleted_at` column |
| 3 | `create_message_reactions` | 6 | `message_reactions` table |
| 4 | `add_threads_to_messages` | 7 | `messages.parent_message_id`, `messages.reply_count` |
| 5 | `create_pinned_messages` | 8 | `pinned_messages` table |
| 6 | `create_invite_links` | 9 | `invite_links` table |
| 7 | `create_user_blocks` | 9 | `user_blocks` table |

## New Schemas

| Schema | Module | File |
|--------|--------|------|
| MessageReaction | `Slackex.Chat.MessageReaction` | `lib/slackex/chat/message_reaction.ex` |
| PinnedMessage | `Slackex.Chat.PinnedMessage` | `lib/slackex/chat/pinned_message.ex` |
| InviteLink | `Slackex.Chat.InviteLink` | `lib/slackex/chat/invite_link.ex` |
| UserBlock | `Slackex.Accounts.UserBlock` | `lib/slackex/accounts/user_block.ex` |

## Key Architecture Decisions

1. **Single LiveView with components** — `ChatLive.Index` stays the top-level LiveView. Sidebar, thread panel, and modals are LiveComponents. Message bubbles, avatars, etc. are function components. This preserves PubSub subscriptions and socket state across patch navigation.

2. **Modal routing via live_action** — Modals are triggered by patch URL changes (e.g., `/chat/channels/new`). The modal component renders conditionally based on `@live_action`. This gives modals shareable URLs and browser back-button support.

3. **Thread panel as side panel, not modal** — Thread view is a sliding right panel (400px on desktop, full width on mobile) alongside the main message list. Both message list and thread panel can be visible simultaneously, matching Slack's UX pattern.

4. **Reactions via toggle pattern** — Single `toggle_reaction/3` function handles both add and remove (insert if not exists, delete if exists). Reactions are batch-loaded with messages via `list_reactions/1` to avoid N+1.

5. **Soft delete for messages** — `deleted_at` timestamp rather than hard delete. Preserves thread integrity (replies reference parent by ID), message ordering, and reaction data. UI shows "[This message was deleted]" placeholder.

6. **Invite links with row-level locking + conditional increment** — `redeem_invite/2` locks the invite row (`FOR UPDATE`), validates limits, inserts membership, and conditionally increments `use_count` in-transaction. This is the contract that prevents over-redemption under concurrency.

7. **Bulk unread counts** — Single lateral-join query for all channel unread counts instead of N per-channel queries. Critical for sidebar performance with many channels.

## Verification

After each step:
1. `mix compile --warnings-as-errors` passes
2. `mix credo --strict` passes
3. `mix test` — all existing + new tests pass
4. `mix assets.build` — JS/CSS compiles cleanly
5. Manual smoke test: start server (`mix phx.server`), register/login, exercise the new feature

### Required Automated Test Matrix

Every implemented step must include tests that prove behavior, not only render checks.

1. Routing + navigation tests:
- Router ordering protects literal routes from `:slug` capture (`/chat/dm/new`, `/chat/channels/new`, `/chat/profile/edit`).
- Deep links for `/chat/:slug`, `/chat/:slug/thread/:message_id`, `/chat/dm/:dm_id` load the correct LiveView state.
- Modal and thread close actions use patch navigation and preserve back-button behavior.

2. Authorization and role invariants:
- `update_member_role/4` and `kick_member/3` reject owner-target mutations.
- Unauthorized actors cannot manage members/pins/invites.
- UI visibility checks are paired with backend assertion tests (server-side enforcement).

3. Invite redemption concurrency:
- Concurrent redeem attempts on limited invites never exceed `max_uses`.
- Expired, exhausted, and not-found invite codes return stable error atoms.
- Invite redemption can add users to private channels.

4. DM block enforcement:
- Sending DM to a blocker returns `:blocked`.
- Unblock restores DM send capability.

5. LiveView interaction tests:
- Use `Phoenix.LiveViewTest` element-based assertions against stable IDs for forms, modals, thread panel, unread badges, and compose controls.
- Verify stream behavior for message append/prepend and pagination events (`load_more`).

End-to-end after all steps:
- Register two users, create a public channel, second user discovers and joins via browse
- Send messages, react with emoji, reply in thread
- Edit and delete messages
- Generate invite link, open in incognito, join via link
- Start DM conversation via user search
- Edit profile (display name, status)
- View online status indicators
- Pin a message, view pinned messages
- Manage channel members (promote/kick)
- Block a user, verify DM is blocked
- Test on mobile viewport (sidebar collapse, touch interactions)
- Verify unread badges appear and clear correctly
- Test Ctrl+K quick switcher
- Toggle theme between light and dark
