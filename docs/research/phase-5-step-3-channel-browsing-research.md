# Phase 5 Step 3: Channel Browsing, Creation & Join/Leave -- Deep-Dive Research

**Date:** 2026-02-26
**Researcher:** Nova (nw-researcher)
**Depth:** Deep-dive
**Status:** Complete
**Confidence Distribution:** High: 14 findings, Medium: 4 findings, Low: 1 finding

---

## Table of Contents

1. [Current Codebase State Assessment](#1-current-codebase-state-assessment)
2. [Specification Analysis](#2-specification-analysis)
3. [Phoenix LiveView Best Practices](#3-phoenix-liveview-best-practices)
4. [UX Pattern Analysis](#4-ux-pattern-analysis)
5. [Implementation Recommendations](#5-implementation-recommendations)
6. [Risk Analysis & Mitigation](#6-risk-analysis--mitigation)
7. [Test Strategy](#7-test-strategy)
8. [Knowledge Gaps](#8-knowledge-gaps)
9. [Sources](#9-sources)

---

## 1. Current Codebase State Assessment

### 1.1 What Exists (Backend)

**Confidence: HIGH** -- Direct codebase analysis of 7 source files.

The `Slackex.Chat` context (`lib/slackex/chat/chat.ex`) already provides the core backend operations that Step 3 depends on:

| Function | Status | Notes |
|----------|--------|-------|
| `create_channel/2` | EXISTS | Uses `Ecto.Multi` to atomically create channel + owner subscription. Takes `user_id` and `attrs` map. |
| `join_channel/2` | EXISTS | Idempotent via `on_conflict: :nothing, conflict_target: [:user_id, :channel_id]`. Rejects private channels. |
| `leave_channel/2` | EXISTS | Deletes subscription via `Repo.delete_all`. Returns `:ok`. |
| `list_public_channels/0` | EXISTS (needs enhancement) | Currently takes no arguments. The spec requires an `opts` keyword with `exclude_member` option. |
| `get_role/2` | EXISTS | Returns role string or `nil`. Used for authorization checks. |
| `list_user_channels/1` | EXISTS | Returns channels the user is subscribed to. Used in sidebar. |
| `count_members/1` | MISSING | New function required per spec. |
| `list_public_channels/1` (with opts) | MISSING | Enhanced version with `exclude_member` filtering. |

The `Channel` schema (`lib/slackex/chat/channel.ex`) provides:
- Fields: `name`, `slug`, `description`, `is_private` (boolean, default false), `creator_id`
- Changeset: validates `name` required, length 2-100, auto-generates slug from name via `put_slug/1`
- Slug generation: `String.downcase()` then `String.replace(~r/[^a-z0-9]+/, "-")` then `String.trim("-")`
- Unique constraint on `:slug`

The `Subscription` schema (`lib/slackex/chat/subscription.ex`) uses a composite primary key (`user_id`, `channel_id`) with roles validated as `["owner", "admin", "member", "viewer"]`.

**Key observation:** The spec calls for channel name validation of "lowercase, hyphens, 3-50 chars" but the current `Channel.changeset/2` validates `min: 2, max: 100` with no format validation. The slug generator handles formatting, but live validation feedback in the modal requires explicit format rules. This is a gap between spec and schema that must be reconciled during implementation.

### 1.2 What Exists (Frontend)

**Confidence: HIGH** -- Direct codebase analysis of 5 source files.

**LiveView (`lib/slackex_web/live/chat_live/index.ex`):**
- Single LiveView managing all chat state via `handle_params` clauses
- Routes: `:index`, `:show`, `:new_dm`, `:dm`
- Already has `leave_conversation/1` helper for PubSub unsubscription
- Already has `authorize_channel/2` that returns `{:ok, can_send}` or `{:error, :unauthorized}` -- this already checks if a non-member can view a public channel (`can_send = false`)
- Has a placeholder `handle_info({:sidebar_action, _action}, socket)` explicitly noting "will be wired in Phase 5 Steps 2-3"
- Template renders the `NewDmModal` with `:if={@live_action == :new_dm}` pattern

**Sidebar (`lib/slackex_web/live/chat_live/sidebar_component.ex`):**
- LiveComponent with collapsible sections (channels, DMs)
- Channels section has NO "+" button or "Browse" link yet
- DMs section already has a "+ New Message" link patching to `/chat/dm/new`
- Receives `@channels` and `@active_channel` assigns from parent

**NewDmModal (`lib/slackex_web/live/chat_live/new_dm_modal.ex`):**
- THE pattern to replicate for both CreateChannelModal and BrowseChannelsModal
- Uses `use SlackexWeb, :live_component`
- Manages its own internal state (`search_query`, `search_results`) via `mount/1` and `handle_event/3`
- Communicates with parent via `send(self(), {:start_dm, user_id})`
- Closes by `push_patch(socket, to: ~p"/chat")`
- Uses `phx-target={@myself}` for all events
- Renders backdrop with `phx-click="close_modal"` and modal container
- Search uses `phx-change` on a form with `phx-debounce="300"`

**ChatComponents (`lib/slackex_web/components/chat_components.ex`):**
- Has `conversation_header/1` -- currently shows title and subtitle only, no action buttons
- Has `empty_state/1`, `channel_list_item/1`, `unread_badge/1`, `avatar/1`
- These are function components (stateless), not LiveComponents

**Router (`lib/slackex_web/router.ex`):**
- All chat routes in single `live_session :chat` block
- Current routes: `/chat`, `/chat/dm/new`, `/chat/dm/:dm_id`, `/chat/:slug`
- Missing: `/chat/channels/new` and `/chat/channels/browse`
- **Critical:** Per the information architecture document, `/chat/channels/new` and `/chat/channels/browse` MUST be declared BEFORE `/chat/:slug` to prevent the slug pattern from capturing these literal segments

### 1.3 What Exists (Tests)

**Confidence: HIGH** -- Direct analysis of 4 test files.

| Test File | Coverage | Pattern |
|-----------|----------|---------|
| `test/slackex/chat_test.exs` | Channel lifecycle, join/leave, messaging, DMs, unread tracking | Uses `Slackex.DataCase, async: true` and `insert(:user)` factory |
| `test/slackex_web/live/chat_live_test.exs` | Route resolution, DM flows, sidebar rendering, modal tests, auth | Uses `SlackexWeb.ConnCase`, `live/2`, `render_patch/2`, `element/2` |
| `test/slackex_web/live/chat_live/layout_test.exs` | Sidebar component, responsive, compose, typing, infinite scroll | Uses `ConnCase, async: false`, cleans ETS and Redis |
| `test/slackex_web/live/chat_live/index_test.exs` | Mount, heartbeat, terminate, online tracker | Uses `ConnCase, async: false`, `register_and_log_in_user/1` |

**Test factory** (`test/support/factory.ex`):
- `user_factory`, `channel_factory`, `subscription_factory`, `dm_conversation_factory`
- Helper: `with_subscription(channel, user, role)` for quickly adding members
- Uses ExMachina.Ecto

**Established test patterns for LiveView modals (from `chat_live_test.exs` "new DM modal" describe block):**
1. Mount LiveView at modal route: `live(conn, ~p"/chat/dm/new")`
2. Assert modal renders: `assert html =~ "new-dm-modal"`
3. Test form interaction: `element("#new-dm-search") |> render_change(%{...})`
4. Test selection/submission with targeted element clicks
5. Assert modal closes: `refute html =~ "new-dm-modal"`
6. Assert side effects (navigation, sidebar update)

### 1.4 Design System Constraints

**Confidence: HIGH** -- Direct analysis of 4 design documents.

From `docs/design/component-system.md`:
- **CreateChannelModal**: Form body with name input (auto-formats), description textarea, private toggle. Footer: Cancel + Create Channel.
- **BrowseChannelsModal**: Width `sm:max-w-2xl` (wider than standard). Sticky search input, scrollable channel list. Channel card: `flex items-center gap-3 px-4 py-3 border-b border-base-300/50`. No footer -- Join is inline.
- All modals share identical shell: backdrop (`bg-base-content/20 backdrop-blur-sm`), dialog container, header (title + close button), scrollable body, optional footer.
- Form inputs: `text-xs font-medium text-base-content/60 uppercase tracking-wide` labels, `input w-full text-sm` fields.
- Toggle pattern for `is_private`: daisyUI `toggle toggle-primary toggle-sm`.

From `docs/design/information-architecture.md`:
- Routes: `/chat/channels/new` -> `:create_channel`, `/chat/channels/browse` -> `:browse_channels`
- Sidebar channels section header: `"Channels" [+] [Browse]`
- Channel header actions: Join/Leave buttons per membership state

From `docs/design/ux-research.md`:
- Modal pattern: backdrop with `backdrop-blur-sm`, modal appears with scale animation, closes on Escape and backdrop click, focus trap
- Mobile: modals slide up from bottom via `items-end sm:items-center`

---

## 2. Specification Analysis

### 2.1 Spec Requirements Summary (lines 421-534)

**Confidence: HIGH** -- Direct spec reading.

**Four deliverables:**

1. **CreateChannelModal** (`create_channel_modal.ex`): Form with name (auto-format), description, is_private toggle. Events: `validate` and `save`. On success: `send(self(), {:channel_created, channel})`. Route: `/chat/channels/new` with `:create_channel` action.

2. **BrowseChannelsModal** (`browse_channels_modal.ex`): Lists public channels user has NOT joined. Shows name, description, member count, Join button. Search/filter by name. Event: `join`. On success: `send(self(), {:channel_joined, channel})`. Route: `/chat/channels/browse` with `:browse_channels` action.

3. **Channel Header Actions**: Contextual Join/Leave in header. Not-member-of-public: "Join Channel" button. Member (not owner): "Leave Channel" button. Owner: no leave button.

4. **Backend additions**: `count_members/1` and enhanced `list_public_channels/1` with `exclude_member` option.

### 2.2 Spec-to-Codebase Delta

| Requirement | Codebase State | Gap |
|-------------|---------------|-----|
| `count_members/1` | Does not exist | Must implement |
| `list_public_channels(opts)` | Exists as `/0` (no opts) | Must add arity/1 with `exclude_member` option |
| CreateChannelModal | Does not exist | Must create; follow NewDmModal pattern |
| BrowseChannelsModal | Does not exist | Must create; follow NewDmModal pattern |
| Route `/chat/channels/new` | Does not exist | Must add before `/chat/:slug` |
| Route `/chat/channels/browse` | Does not exist | Must add before `/chat/:slug` |
| Sidebar "+" and "Browse" | Does not exist | Must extend SidebarComponent |
| Channel header Join/Leave | Does not exist | Must extend `conversation_header/1` or Index template |
| `handle_params` for `:create_channel` | Does not exist | Must add clause |
| `handle_params` for `:browse_channels` | Does not exist | Must add clause |
| `handle_info({:channel_created, _})` | Does not exist (placeholder exists for `:sidebar_action`) | Must implement |
| `handle_info({:channel_joined, _})` | Does not exist | Must implement |
| Name validation (3-50 chars, lowercase-hyphens) | Channel.changeset validates 2-100, no format regex | Spec tighter than schema; modal should validate client-side |

---

## 3. Phoenix LiveView Best Practices

### 3.1 LiveComponent Modal with Form + Changeset

**Confidence: HIGH** -- 3 sources: Phoenix official docs, Elixir community patterns, existing codebase precedent.

The recommended pattern for modal forms in LiveComponents:

```elixir
defmodule SlackexWeb.ChatLive.CreateChannelModal do
  use SlackexWeb, :live_component

  alias Slackex.Chat.Channel

  @impl true
  def mount(socket) do
    changeset = Channel.changeset(%Channel{}, %{})
    {:ok, assign(socket, form: to_form(changeset, as: :channel))}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("validate", %{"channel" => params}, socket) do
    changeset =
      %Channel{}
      |> Channel.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: :channel))}
  end

  def handle_event("save", %{"channel" => params}, socket) do
    case Chat.create_channel(socket.assigns.current_user.id, params) do
      {:ok, channel} ->
        send(self(), {:channel_created, channel})
        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :channel))}
    end
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/chat")}
  end
end
```

Key principles from [Phoenix LiveView form bindings docs](https://hexdocs.pm/phoenix_live_view/form-bindings.html):
- Use `to_form/2` to convert changesets to forms
- Set `:action` to `:validate` during validation so errors display before submission
- Use `phx-change` and `phx-submit` on the form element
- Use `phx-target={@myself}` to keep events within the LiveComponent

Key principles from [Phoenix.LiveComponent docs](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveComponent.html):
- `send(self(), msg)` sends to the parent LiveView because the component runs in the parent's process
- `mount/1` is called once when the component is first rendered
- `update/2` is called before each render, receiving new assigns from the parent

### 3.2 Navigation: push_patch for Modals

**Confidence: HIGH** -- 3 sources: Phoenix official docs, LiveView navigation guide, existing codebase pattern.

From [Phoenix LiveView navigation guide](https://github.com/phoenixframework/phoenix_live_view/blob/main/guides/server/live-navigation.md) and [live navigation docs](https://hexdocs.pm/phoenix_live_view/live-navigation.html):

- `push_patch/2` is correct for modal open/close because it stays within the same LiveView, triggering `handle_params/3` without remounting
- The existing codebase already uses this pattern: `NewDmModal` closes via `push_patch(socket, to: ~p"/chat")`
- Modal visibility is controlled by `live_action`: `:if={@live_action == :create_channel}`

From [DEV Community article on patching](https://dev.to/hexshift/mastering-phoenix-liveview-patching-stateful-navigation-without-reloading-your-ui-k5p):
- Patch preserves all socket state (messages stream, typing users, active channel)
- Only `handle_params/3` fires -- mount does not re-execute
- Browser back button naturally closes modals by patching to the previous URL

### 3.3 Real-Time Sidebar Updates via PubSub

**Confidence: HIGH** -- 3 sources: Elixir School PubSub guide, Phoenix PubSub docs, existing codebase pattern.

From [Elixir School PubSub guide](https://elixirschool.com/blog/live-view-with-pub-sub) and [Phoenix PubSub docs](https://hexdocs.pm/phoenix_pubsub/Phoenix.PubSub.html):

The sidebar channel list must update after join/leave/create. Two approaches:

**Approach A: Direct assign update (simpler, single-session):**
```elixir
def handle_info({:channel_created, channel}, socket) do
  channels = Chat.list_user_channels(socket.assigns.current_user.id)
  {:noreply,
   socket
   |> assign(:channels, channels)
   |> push_patch(to: ~p"/chat/#{channel.slug}")}
end
```

**Approach B: PubSub broadcast (cross-session):**
```elixir
# In Chat context after create:
Phoenix.PubSub.broadcast(Slackex.PubSub, "user:#{user_id}", {:channels_updated})

# In Index handle_info:
def handle_info({:envelope, %{event: "channels_updated"}}, socket) do
  channels = Chat.list_user_channels(socket.assigns.current_user.id)
  {:noreply, assign(socket, :channels, channels)}
end
```

**Recommendation:** Start with Approach A. The current spec does not require cross-session sidebar updates (that would be Step 3 enhancement territory). The existing `{:start_dm, user_id}` handler in the codebase follows Approach A -- it re-fetches `dm_conversations` and updates the assign directly. Follow the same pattern for channels.

### 3.4 Debounced Search in LiveComponents

**Confidence: HIGH** -- 3 sources: existing codebase, Phoenix form docs, component system spec.

The `NewDmModal` already implements the search pattern:
```heex
<form id="new-dm-search" phx-change="search" phx-target={@myself} phx-submit="search">
  <input type="text" name="search_query" phx-debounce="300" />
</form>
```

For the `BrowseChannelsModal`, apply the same pattern:
- Use `phx-change` on the form, not on individual inputs
- `phx-debounce="300"` prevents excessive server round-trips
- Filter function should be case-insensitive: `String.contains?(String.downcase(channel.name), String.downcase(query))`
- Client-side filtering is acceptable for <100 channels; for larger datasets, add a server-side query

### 3.5 Stream vs Assign for Modal Lists

**Confidence: MEDIUM** -- 2 sources: Phoenix docs, practical analysis.

For the BrowseChannelsModal's channel list:
- **Use assigns, not streams.** Streams (`stream/3`) are designed for large, append-only lists (like message history) where you need efficient DOM patching. The browse channels list is typically <100 items, loaded all at once, and filtered client-side.
- The existing `NewDmModal` uses assigns (`search_results`), not streams. Follow this pattern.
- Streams would add unnecessary complexity (stream reset on filter, no benefit for small lists).

---

## 4. UX Pattern Analysis

### 4.1 Channel Creation Flow

**Confidence: HIGH** -- 3 sources: Slack design research, component-system.md, information-architecture.md.

**Slack's pattern:**
- Channel creation is a focused modal with name, description (optional), and privacy toggle
- Channel name is auto-formatted: spaces become hyphens, special characters stripped, forced lowercase
- Live validation shows formatting preview: "Your channel will be created as: #my-channel-name"
- Submit button is disabled until name passes validation
- After creation, user is immediately navigated to the new channel

**Discord's pattern:**
- Similar modal but with a channel type selector (text vs voice)
- Name auto-formatting matches Slack
- Description called "Topic" and is also optional
- Privacy is handled at the category level, not individual channel

**Recommended pattern for Slackex (from spec + design documents):**
1. User clicks "+" in sidebar channels section header
2. Patches to `/chat/channels/new` which triggers `:create_channel` action
3. Modal renders with: name input (auto-formatting on keyup), description textarea, private toggle
4. Live validation on `phx-change` shows errors and formatted preview
5. On submit: create channel, navigate to it, update sidebar

**Auto-formatting implementation:**
```elixir
defp format_channel_name(name) do
  name
  |> String.downcase()
  |> String.replace(~r/\s+/, "-")
  |> String.replace(~r/[^a-z0-9-]/, "")
  |> String.replace(~r/-{2,}/, "-")
  |> String.trim("-")
end
```

This should be applied in the `validate` event handler before passing to the changeset, and the formatted value should be shown to the user as feedback.

### 4.2 Channel Browsing Flow

**Confidence: HIGH** -- 3 sources: Slack benchmarking research, information-architecture.md, component-system.md.

From [Slack's design blog](https://slack.com/blog/collaboration/designing-the-future-of-slack-with-customers):
- Slack's benchmarking studies found that first-time users struggle to find and join channels
- Channel discovery is a critical onboarding flow
- The browse interface should show: channel name, description, and member count (social proof)
- A "Join" button should be prominent and immediate (no confirmation dialog)

**Recommended pattern for Slackex:**
1. User clicks "Browse" link in sidebar channels section or "Browse Channels" from welcome state
2. Patches to `/chat/channels/browse` which triggers `:browse_channels` action
3. Modal (wider: `sm:max-w-2xl`) renders with: search input (sticky at top), scrollable channel list
4. Each channel row: `# name` + description + "N members" + "Join" button
5. Search filters in real-time (debounced `phx-change`)
6. On Join: `Chat.join_channel`, update sidebar, navigate to channel
7. Empty state: "No channels found" when search yields no results

### 4.3 Join/Leave Header Actions

**Confidence: HIGH** -- 3 sources: spec, information-architecture.md, component-system.md.

Three states to handle:

| User State | Header Shows | Action |
|------------|-------------|--------|
| Not a member of public channel | "Join Channel" button (`btn btn-primary btn-xs`) | `Chat.join_channel/2` |
| Member (not owner) | "Leave" button (`btn btn-ghost btn-xs text-base-content/60`) | `Chat.leave_channel/2` |
| Owner | No join/leave button | (transfer ownership first) |

**After join:** Refresh `@channels` assign, set `@can_send` to `true`, re-subscribe to channel PubSub.
**After leave:** Refresh `@channels` assign, navigate to `/chat` (no longer viewing this channel).

### 4.4 Empty States

**Confidence: HIGH** -- 3 sources: component-system.md, ux-research.md, information-architecture.md.

| Context | Empty State Text | CTA |
|---------|-----------------|-----|
| Browse modal, no channels | "No public channels available" | "Create a channel" link |
| Browse modal, search no results | "No channels matching '{query}'" | None |
| Welcome state (no channels joined) | "Welcome to Slackex" / "Select a channel..." | "Browse Channels" and "Create Channel" buttons |

---

## 5. Implementation Recommendations

### 5.1 File Creation Order

Based on dependency analysis:

1. **Backend first** -- `chat.ex` additions (`count_members/1`, enhanced `list_public_channels/1`)
2. **Routes** -- Add to `router.ex` (before `:slug` route)
3. **CreateChannelModal** -- New LiveComponent file
4. **BrowseChannelsModal** -- New LiveComponent file
5. **Index.ex extensions** -- `handle_params`, `handle_info`, `handle_event` additions, template changes
6. **SidebarComponent** -- Add "+" and "Browse" buttons to channels section
7. **Channel header** -- Add Join/Leave buttons to conversation header area

### 5.2 Backend: count_members/1

```elixir
@doc "Returns the number of members in a channel."
def count_members(channel_id) do
  from(s in Subscription, where: s.channel_id == ^channel_id, select: count())
  |> Repo.one()
end
```

This is straightforward. Uses `Repo` (write repo) which is fine for an occasional count query from a modal.

### 5.3 Backend: Enhanced list_public_channels/1

The spec provides the exact implementation. Key observations:

```elixir
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

**Important:** This replaces the existing `list_public_channels/0`. The new function has `opts \\ []` so it is backward-compatible -- existing callers (if any) that pass no arguments will continue to work.

**N+1 note:** The `Enum.map` with `count_members` is an acknowledged N+1. See Risk Analysis section 6.1 for mitigation.

### 5.4 Route Additions

```elixir
live_session :chat,
  on_mount: [{SlackexWeb.UserAuth, :ensure_authenticated}],
  layout: {SlackexWeb.Layouts, :chat} do
  live "/chat", ChatLive.Index, :index
  live "/chat/channels/new", ChatLive.Index, :create_channel    # NEW - before :slug
  live "/chat/channels/browse", ChatLive.Index, :browse_channels # NEW - before :slug
  live "/chat/dm/new", ChatLive.Index, :new_dm
  live "/chat/dm/:dm_id", ChatLive.Index, :dm
  live "/chat/:slug", ChatLive.Index, :show                     # MUST be last
end
```

### 5.5 CreateChannelModal Pattern

Follow `NewDmModal` structure precisely. Key differences:
- Uses a changeset-backed form instead of simple search
- Has `phx-change="validate"` and `phx-submit="save"` (vs `phx-change="search"`)
- Needs `to_form/2` for changeset-to-form conversion
- Name field needs auto-formatting via a JS hook or `phx-change` handler
- On save success: `send(self(), {:channel_created, channel})`

**Auto-format approach decision:**
- **Option A: Server-side in validate handler** -- Format the name in `handle_event("validate", ...)`, push formatted value back. Simple, no JS needed, but user sees the change after debounce delay.
- **Option B: JS hook for instant formatting** -- Client-side formatting on every keypress, server validation on debounce. Better UX but requires a new JS hook.

**Recommendation:** Option A (server-side). Matches the existing codebase philosophy of minimal JS. The `phx-debounce="300"` delay is acceptable -- Slack has a similar behavior where the name auto-formats after a brief pause. The validation handler can modify the params before building the changeset:

```elixir
def handle_event("validate", %{"channel" => params}, socket) do
  formatted_name = format_channel_name(params["name"] || "")
  params = Map.put(params, "name", formatted_name)

  changeset =
    %Channel{}
    |> Channel.changeset(params)
    |> Map.put(:action, :validate)

  {:noreply, assign(socket, form: to_form(changeset, as: :channel))}
end
```

### 5.6 BrowseChannelsModal Pattern

Follow `NewDmModal` structure for the search/list pattern. Key differences:
- Loads channels on mount (not search-first like DM modal)
- Search filters the already-loaded list
- Each item has a "Join" button instead of a selection action
- Shows member count per channel

```elixir
def mount(socket) do
  {:ok,
   socket
   |> assign(:search_query, "")
   |> assign(:all_channels, [])    # loaded in update/2
   |> assign(:filtered_channels, [])}
end

def update(assigns, socket) do
  channels =
    Chat.list_public_channels(exclude_member: assigns.current_user.id)

  {:ok,
   socket
   |> assign(assigns)
   |> assign(:all_channels, channels)
   |> assign(:filtered_channels, channels)}
end
```

**Filtering approach:**
```elixir
def handle_event("search", %{"search_query" => query}, socket) do
  filtered =
    if String.length(query) >= 1 do
      query_down = String.downcase(query)
      Enum.filter(socket.assigns.all_channels, fn ch ->
        String.contains?(String.downcase(ch.name), query_down)
      end)
    else
      socket.assigns.all_channels
    end

  {:noreply,
   socket
   |> assign(:search_query, query)
   |> assign(:filtered_channels, filtered)}
end
```

### 5.7 Index.ex Extensions

**New handle_params clauses:**
```elixir
def handle_params(_params, _uri, %{assigns: %{live_action: :create_channel}} = socket) do
  socket = leave_conversation(socket)
  {:noreply,
   socket
   |> assign(:active_channel, nil)
   |> assign(:active_dm, nil)
   |> assign(:page_title, "Create Channel")}
end

def handle_params(_params, _uri, %{assigns: %{live_action: :browse_channels}} = socket) do
  socket = leave_conversation(socket)
  {:noreply,
   socket
   |> assign(:active_channel, nil)
   |> assign(:active_dm, nil)
   |> assign(:page_title, "Browse Channels")}
end
```

**New handle_info clauses:**
```elixir
def handle_info({:channel_created, channel}, socket) do
  channels = Chat.list_user_channels(socket.assigns.current_user.id)
  {:noreply,
   socket
   |> assign(:channels, channels)
   |> push_patch(to: ~p"/chat/#{channel.slug}")}
end

def handle_info({:channel_joined, channel}, socket) do
  channels = Chat.list_user_channels(socket.assigns.current_user.id)
  {:noreply,
   socket
   |> assign(:channels, channels)
   |> push_patch(to: ~p"/chat/#{channel.slug}")}
end
```

**New handle_event clauses for header actions:**
```elixir
def handle_event("join_channel", _params, socket) do
  user = socket.assigns.current_user
  channel = socket.assigns.active_channel

  case Chat.join_channel(user.id, channel.id) do
    {:ok, _sub} ->
      channels = Chat.list_user_channels(user.id)
      {:noreply,
       socket
       |> assign(:channels, channels)
       |> assign(:can_send, true)}

    {:error, _} ->
      {:noreply, put_flash(socket, :error, "Could not join channel.")}
  end
end

def handle_event("leave_channel", _params, socket) do
  user = socket.assigns.current_user
  channel = socket.assigns.active_channel

  Chat.leave_channel(user.id, channel.id)
  channels = Chat.list_user_channels(user.id)

  {:noreply,
   socket
   |> assign(:channels, channels)
   |> push_patch(to: ~p"/chat")}
end
```

**Template additions:**
```heex
<%!-- In render/1, after the existing NewDmModal block --%>

<.live_component
  :if={@live_action == :create_channel}
  module={CreateChannelModal}
  id="create-channel-modal"
  current_user={@current_user}
/>

<.live_component
  :if={@live_action == :browse_channels}
  module={BrowseChannelsModal}
  id="browse-channels-modal"
  current_user={@current_user}
/>
```

### 5.8 SidebarComponent Updates

Add "+" button and "Browse" link to the channels section header:

```heex
<div class="flex items-center justify-between px-2 py-1">
  <button
    phx-click="toggle_section"
    phx-value-section="channels"
    phx-target={@myself}
    class="flex items-center gap-1 text-xs font-semibold uppercase tracking-wider text-base-content/60 hover:text-base-content"
  >
    <span>Channels</span>
    <%!-- chevron SVG --%>
  </button>
  <div class="flex items-center gap-1">
    <.link
      patch={~p"/chat/channels/browse"}
      class="btn btn-ghost btn-xs btn-circle"
      title="Browse channels"
    >
      <%!-- magnifying glass or list icon --%>
    </.link>
    <.link
      patch={~p"/chat/channels/new"}
      class="btn btn-ghost btn-xs btn-circle"
      title="Create channel"
    >
      <%!-- plus icon --%>
    </.link>
  </div>
</div>
```

### 5.9 Channel Header Join/Leave Buttons

Extend the conversation header area in the `render/1` template of `Index`:

```heex
<.conversation_header
  title={"##{@active_channel.name}"}
  subtitle={@active_channel.description}
/>
<%!-- Add after conversation_header, before message_stream --%>
<%= cond do %>
  <% Chat.get_role(@current_user.id, @active_channel.id) == nil and not @active_channel.is_private -> %>
    <%!-- Non-member of public channel --%>
    <div class="px-4 py-2 border-b border-base-300 bg-base-100">
      <button phx-click="join_channel" class="btn btn-primary btn-xs">
        Join Channel
      </button>
    </div>
  <% Chat.get_role(@current_user.id, @active_channel.id) not in [nil, "owner"] -> %>
    <%!-- Member but not owner --%>
    <div class="px-4 py-2 border-b border-base-300 bg-base-100">
      <button phx-click="leave_channel" class="btn btn-ghost btn-xs text-base-content/60">
        Leave Channel
      </button>
    </div>
  <% true -> %>
    <%!-- Owner or private channel member -- no action --%>
<% end %>
```

**INTERPRETATION (labeled):** Rather than calling `Chat.get_role/2` in the template (which would add a DB query per render), it would be better to compute `@user_role` in `enter_channel/3` and store it in assigns. This avoids template-level DB calls and follows the existing pattern of pre-computing `@can_send` in `authorize_channel/2`.

---

## 6. Risk Analysis & Mitigation

### 6.1 N+1 Query in list_public_channels

**Risk: MEDIUM** -- Acknowledged in spec.

The `Enum.map(fn channel -> Map.put(channel, :member_count, count_members(channel.id)) end)` pattern executes one `SELECT count(*)` query per channel.

**Current impact:** For <100 public channels, this adds ~100 lightweight count queries. At ~1ms each, total latency is ~100ms. Acceptable for a modal load.

**Mitigation when needed (future optimization):**
```elixir
def list_public_channels_with_counts(opts \\ []) do
  exclude_member = Keyword.get(opts, :exclude_member)

  base =
    from c in Channel,
      where: c.is_private == false,
      left_join: s in Subscription, on: s.channel_id == c.id,
      group_by: c.id,
      select: %{channel: c, member_count: count(s.user_id)},
      order_by: [asc: c.name]

  base =
    if exclude_member do
      from [c, s] in base,
        left_join: my_sub in Subscription,
        on: my_sub.channel_id == c.id and my_sub.user_id == ^exclude_member,
        where: is_nil(my_sub.id)
    else
      base
    end

  Repo.all(base)
end
```

This reduces N+1 to a single query with GROUP BY. Defer this optimization until channel count exceeds ~50.

**Source:** [Ecto aggregates and subqueries docs](https://hexdocs.pm/ecto/aggregates-and-subqueries.html)

### 6.2 Race Conditions in join_channel

**Risk: LOW** -- Already mitigated.

The existing `join_channel/2` uses `on_conflict: :nothing, conflict_target: [:user_id, :channel_id]`, making it idempotent. If two sessions attempt to join simultaneously, both succeed without error -- one inserts, the other no-ops.

**Caveat from [Ecto constraints docs](https://hexdocs.pm/ecto/constraints-and-upserts.html):** `on_conflict: :nothing` returns `{:ok, subscription}` even on conflict, but the returned struct may not have the ID populated. This is fine for our use case because we only need the `:ok` tuple to proceed with navigation.

### 6.3 Race Conditions in leave_channel

**Risk: LOW** -- Inherently safe.

`leave_channel/2` uses `Repo.delete_all` which returns `{count, nil}`. If the subscription is already deleted (double-click, concurrent sessions), it returns `{0, nil}` -- harmless. The function always returns `:ok`.

### 6.4 PubSub Coordination for Cross-Session Sidebar Updates

**Risk: MEDIUM** -- Deferred concern.

If User A creates a channel and User B has the Browse Channels modal open, User B will not see the new channel until they re-open the modal. Similarly, if User A joins a channel, their other browser tabs will not update the sidebar.

**Mitigation:** Not required for Step 3 per spec. The existing DM flow follows the same single-session pattern (`:start_dm` handler only updates the current session's sidebar). Cross-session updates can be added in a future step via PubSub broadcast on `"user:#{user_id}"` topic.

### 6.5 Channel Name Uniqueness (Case-Insensitive)

**Risk: MEDIUM** -- Partially mitigated.

The `Channel` schema has a `unique_constraint(:slug)`. Since slugs are generated by `String.downcase()` + regex replacement, "My Channel" and "my channel" produce the same slug "my-channel". This provides case-insensitive uniqueness at the slug level.

**Edge case:** "My Channel" and "My-Channel" also produce the same slug. The error will surface as a changeset error (`%{slug: ["has already been taken"]}`). The CreateChannelModal should display this as a user-friendly message: "A channel with this name already exists."

### 6.6 Permission Edge Cases

**Risk: LOW** -- Already handled.

- **Private channels:** `join_channel/2` explicitly checks `channel.is_private` and returns `{:error, :unauthorized}`. The BrowseChannelsModal only shows `is_private == false` channels.
- **Owner leaving:** The spec states owners cannot leave. The `leave_channel/2` function does NOT enforce this -- it deletes any subscription. The enforcement must happen in the UI (hide Leave button for owners) AND in the `handle_event("leave_channel", ...)` handler.

**Recommendation:** Add a guard in the event handler:
```elixir
def handle_event("leave_channel", _params, socket) do
  user = socket.assigns.current_user
  channel = socket.assigns.active_channel
  role = Chat.get_role(user.id, channel.id)

  if role == "owner" do
    {:noreply, put_flash(socket, :error, "Channel owners cannot leave. Transfer ownership first.")}
  else
    Chat.leave_channel(user.id, channel.id)
    # ... navigate away
  end
end
```

### 6.7 Mobile Responsiveness of Modal Components

**Risk: LOW** -- Design system handles this.

The modal shell pattern from `component-system.md` uses `items-end sm:items-center` which makes modals slide up from the bottom on mobile and center on desktop. Both modals use standard form inputs and buttons that are already touch-friendly via daisyUI's default sizing. The BrowseChannelsModal's wider width (`sm:max-w-2xl`) gracefully degrades to full-width on mobile via `w-full`.

### 6.8 Route Ordering Bug Risk

**Risk: HIGH if misconfigured** -- Mitigated by explicit ordering.

If `/chat/channels/new` is placed after `/chat/:slug`, Phoenix will match `/chat/channels/new` as `:slug = "channels"` and then fail looking up `Channel` with `slug = "channels"`. The information architecture document explicitly warns about this.

**Mitigation:** The router diff in section 5.4 places the new routes before `:slug`. A regression test should verify this ordering:
```elixir
test "channel modal routes resolve correctly, not captured by :slug" do
  {:ok, _lv, html} = live(conn, ~p"/chat/channels/new")
  assert html =~ "Create Channel"  # not a 404 or channel lookup error
end
```

---

## 7. Test Strategy

### 7.1 Context-Level Tests (chat_test.exs)

**Confidence: HIGH** -- Based on existing test patterns.

Add to `test/slackex/chat_test.exs`:

```elixir
describe "count_members/1" do
  test "returns correct member count" do
    owner = insert(:user)
    member1 = insert(:user)
    member2 = insert(:user)
    {:ok, channel} = Chat.create_channel(owner.id, %{name: "counted"})
    Chat.join_channel(member1.id, channel.id)
    Chat.join_channel(member2.id, channel.id)

    assert Chat.count_members(channel.id) == 3  # owner + 2 members
  end

  test "returns 0 for channel with no members" do
    # Edge case: channel factory creates without subscription
    channel = insert(:channel)
    assert Chat.count_members(channel.id) == 0
  end
end

describe "list_public_channels/1 with exclude_member" do
  test "excludes channels where user is a member" do
    user = insert(:user)
    {:ok, joined} = Chat.create_channel(user.id, %{name: "joined-ch"})
    other = insert(:user)
    {:ok, not_joined} = Chat.create_channel(other.id, %{name: "not-joined-ch"})

    channels = Chat.list_public_channels(exclude_member: user.id)

    channel_ids = Enum.map(channels, & &1.id)
    refute joined.id in channel_ids
    assert not_joined.id in channel_ids
  end

  test "includes member_count for each channel" do
    user = insert(:user)
    other = insert(:user)
    {:ok, channel} = Chat.create_channel(other.id, %{name: "with-count"})
    Chat.join_channel(user.id, channel.id)

    # Query from a third user who hasn't joined
    viewer = insert(:user)
    [ch] = Chat.list_public_channels(exclude_member: viewer.id)

    assert ch.member_count == 2  # other (owner) + user
  end

  test "excludes private channels" do
    user = insert(:user)
    {:ok, _private} = Chat.create_channel(user.id, %{name: "secret", is_private: true})
    other = insert(:user)

    channels = Chat.list_public_channels(exclude_member: other.id)
    names = Enum.map(channels, & &1.name)
    refute "secret" in names
  end

  test "with no options returns all public channels" do
    user = insert(:user)
    {:ok, _ch} = Chat.create_channel(user.id, %{name: "all-public"})

    channels = Chat.list_public_channels()
    assert length(channels) >= 1
  end
end
```

### 7.2 LiveView Integration Tests

**Confidence: HIGH** -- Based on existing `chat_live_test.exs` patterns.

Create new describe blocks in `test/slackex_web/live/chat_live_test.exs` or a new file `test/slackex_web/live/chat_live/channel_modals_test.exs`:

```elixir
describe "create channel modal" do
  test "modal renders when navigated to /chat/channels/new" do
    {:ok, _lv, html} = live(conn, ~p"/chat/channels/new")
    assert html =~ "create-channel-modal"
    assert html =~ "Create Channel"
  end

  test "route /chat/channels/new is not captured by :slug" do
    {:ok, _lv, html} = live(conn, ~p"/chat/channels/new")
    assert html =~ "Create Channel"
  end

  test "validation shows errors for invalid name" do
    {:ok, lv, _html} = live(conn, ~p"/chat/channels/new")
    html =
      lv
      |> element("#create-channel-form")
      |> render_change(%{"channel" => %{"name" => "a"}})

    assert html =~ "should be at least"  # length validation
  end

  test "name auto-formats to lowercase with hyphens" do
    {:ok, lv, _html} = live(conn, ~p"/chat/channels/new")
    html =
      lv
      |> element("#create-channel-form")
      |> render_change(%{"channel" => %{"name" => "My Cool Channel"}})

    assert html =~ "my-cool-channel"
  end

  test "successful creation navigates to new channel" do
    {:ok, lv, _html} = live(conn, ~p"/chat/channels/new")

    lv
    |> element("#create-channel-form")
    |> render_submit(%{"channel" => %{"name" => "test-new", "description" => "A test"}})

    assert_patch(lv, ~r"/chat/test-new")
  end

  test "created channel appears in sidebar" do
    {:ok, lv, _html} = live(conn, ~p"/chat/channels/new")

    lv
    |> element("#create-channel-form")
    |> render_submit(%{"channel" => %{"name" => "sidebar-test"}})

    html = render(lv)
    assert html =~ "sidebar-test"
  end

  test "duplicate name shows error" do
    # Pre-create a channel
    Chat.create_channel(alice.id, %{name: "existing"})

    {:ok, lv, _html} = live(conn, ~p"/chat/channels/new")

    html =
      lv
      |> element("#create-channel-form")
      |> render_submit(%{"channel" => %{"name" => "existing"}})

    assert html =~ "has already been taken"
  end

  test "modal closes on backdrop click" do
    {:ok, lv, _html} = live(conn, ~p"/chat/channels/new")
    assert render(lv) =~ "create-channel-modal"

    lv
    |> element("#create-channel-modal-backdrop")
    |> render_click()

    html = render(lv)
    refute html =~ "create-channel-modal"
  end
end

describe "browse channels modal" do
  test "modal renders when navigated to /chat/channels/browse" do
    {:ok, _lv, html} = live(conn, ~p"/chat/channels/browse")
    assert html =~ "browse-channels-modal"
    assert html =~ "Browse Channels"
  end

  test "shows public channels user has not joined" do
    other = insert(:user)
    {:ok, _ch} = Chat.create_channel(other.id, %{name: "browseable"})

    {:ok, _lv, html} = live(conn, ~p"/chat/channels/browse")
    assert html =~ "browseable"
  end

  test "does not show channels user has already joined" do
    {:ok, _lv, html} = live(conn, ~p"/chat/channels/browse")
    # alice is already in "general" from setup
    refute html =~ "general"
  end

  test "shows member count for each channel" do
    other = insert(:user)
    {:ok, ch} = Chat.create_channel(other.id, %{name: "popular"})
    for _ <- 1..5, do: Chat.join_channel(insert(:user).id, ch.id)

    {:ok, _lv, html} = live(conn, ~p"/chat/channels/browse")
    assert html =~ "6 members"  # owner + 5
  end

  test "search filters channels by name" do
    other = insert(:user)
    {:ok, _} = Chat.create_channel(other.id, %{name: "alpha-team"})
    {:ok, _} = Chat.create_channel(other.id, %{name: "beta-team"})

    {:ok, lv, _html} = live(conn, ~p"/chat/channels/browse")

    html =
      lv
      |> element("#browse-channels-search")
      |> render_change(%{"search_query" => "alpha"})

    assert html =~ "alpha-team"
    refute html =~ "beta-team"
  end

  test "joining a channel navigates to it" do
    other = insert(:user)
    {:ok, ch} = Chat.create_channel(other.id, %{name: "joinable"})

    {:ok, lv, _html} = live(conn, ~p"/chat/channels/browse")

    lv
    |> element("[phx-click=\"join\"][phx-value-channel-id=\"#{ch.id}\"]")
    |> render_click()

    assert_patch(lv, ~r"/chat/joinable")
  end

  test "joined channel appears in sidebar" do
    other = insert(:user)
    {:ok, ch} = Chat.create_channel(other.id, %{name: "will-join"})

    {:ok, lv, _html} = live(conn, ~p"/chat/channels/browse")

    lv
    |> element("[phx-click=\"join\"][phx-value-channel-id=\"#{ch.id}\"]")
    |> render_click()

    html = render(lv)
    assert html =~ "will-join"
  end

  test "empty state when no channels available" do
    # No other channels besides the ones alice already joined
    {:ok, _lv, html} = live(conn, ~p"/chat/channels/browse")
    assert html =~ "No channels" or html =~ "no public channels"
  end
end

describe "channel header join/leave" do
  test "non-member sees Join Channel button on public channel" do
    other = insert(:user)
    {:ok, ch} = Chat.create_channel(other.id, %{name: "public-view"})

    {:ok, _lv, html} = live(conn, ~p"/chat/#{ch.slug}")
    assert html =~ "Join Channel"
  end

  test "joining via header button enables compose area" do
    other = insert(:user)
    {:ok, ch} = Chat.create_channel(other.id, %{name: "joinme"})

    {:ok, lv, html} = live(conn, ~p"/chat/#{ch.slug}")
    assert html =~ "Join this channel to send messages"

    lv |> element("[phx-click=\"join_channel\"]") |> render_click()

    html = render(lv)
    assert html =~ "phx-submit=\"send_message\""
    refute html =~ "Join this channel to send messages"
  end

  test "member (not owner) sees Leave button" do
    # alice is a member (not owner) of this channel
    other = insert(:user)
    {:ok, ch} = Chat.create_channel(other.id, %{name: "leaveable"})
    Chat.join_channel(alice.id, ch.id)

    {:ok, _lv, html} = live(conn, ~p"/chat/#{ch.slug}")
    assert html =~ "Leave"
    refute html =~ "Join Channel"
  end

  test "owner does not see Leave button" do
    # alice is owner of "general" from setup
    {:ok, _lv, html} = live(conn, ~p"/chat/#{channel.slug}")
    refute html =~ "Leave"
  end

  test "leaving via header navigates to /chat" do
    other = insert(:user)
    {:ok, ch} = Chat.create_channel(other.id, %{name: "will-leave"})
    Chat.join_channel(alice.id, ch.id)

    {:ok, lv, _html} = live(conn, ~p"/chat/#{ch.slug}")
    lv |> element("[phx-click=\"leave_channel\"]") |> render_click()

    assert_patch(lv, "/chat")
  end

  test "sidebar updates after leaving" do
    other = insert(:user)
    {:ok, ch} = Chat.create_channel(other.id, %{name: "leaving-sidebar"})
    Chat.join_channel(alice.id, ch.id)

    {:ok, lv, html} = live(conn, ~p"/chat")
    assert html =~ "leaving-sidebar"

    render_patch(lv, ~p"/chat/#{ch.slug}")
    lv |> element("[phx-click=\"leave_channel\"]") |> render_click()

    html = render(lv)
    refute html =~ "leaving-sidebar"
  end
end
```

### 7.3 PubSub Event Testing

From [Phoenix.LiveViewTest docs](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveViewTest.html): Test PubSub by directly sending messages to the LiveView process:

```elixir
test "channel_created message updates sidebar and navigates" do
  {:ok, lv, _html} = live(conn, ~p"/chat")
  other = insert(:user)
  {:ok, channel} = Chat.create_channel(other.id, %{name: "pubsub-test"})
  Chat.join_channel(alice.id, channel.id)

  send(lv.pid, {:channel_created, channel})

  html = render(lv)
  assert html =~ "pubsub-test"
end
```

### 7.4 Test Organization Recommendation

Given the scope of Step 3, create a dedicated test file:

```
test/slackex_web/live/chat_live/channel_modals_test.exs
```

This follows the established pattern of `layout_test.exs` and `index_test.exs` being separate from the main `chat_live_test.exs`. The context tests should go into the existing `chat_test.exs` file as new describe blocks.

---

## 8. Knowledge Gaps

### 8.1 Channel Name Validation Spec vs Schema Mismatch

**Searched for:** Reconciliation between spec requirement (3-50 chars, lowercase, hyphens only) and current schema validation (2-100 chars, no format constraint).

**Finding:** The spec calls for stricter validation in the modal (3-50 chars, lowercase-hyphens format) than the schema enforces (2-100 chars, any characters). The auto-formatting approach in the modal will handle character transformation, but the length bounds differ. **Decision needed:** Should the Channel schema be updated to match the spec (min 3, max 50, format regex), or should the modal apply stricter validation on top of the permissive schema?

**Recommendation:** Update the schema to add a format validation (`validate_format(:name, ~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/)`), but keep the length as-is (2-100) for backward compatibility. The modal adds its own 3-50 character guidance. This way the schema is the source of truth for database constraints and the modal provides tighter UX guidance.

### 8.2 Cross-Session Sidebar Refresh After Join/Leave

**Searched for:** Whether the spec requires other browser tabs/sessions to update when a user joins/leaves a channel.

**Finding:** The spec does not explicitly address cross-session updates. The acceptance criteria state "Channel list in sidebar updates after join/leave/create" -- this likely refers to the current session only, consistent with how the DM sidebar update works (single-session `assign` update in `{:start_dm, user_id}` handler). Cross-session updates would require PubSub broadcasts on the `"user:#{user_id}"` topic.

**Confidence: MEDIUM** -- Implicit from spec phrasing.

### 8.3 BrowseChannelsModal Refresh After Join

**Searched for:** Whether the BrowseChannelsModal should remove a channel from its list after the user joins it.

**Finding:** The spec's flow says "send(self(), {:channel_joined, channel})" which triggers navigation away from the browse modal. So the modal closes on join. However, if the user opens the browse modal again, the joined channel should no longer appear (the `exclude_member` filter handles this). No in-modal live removal is needed.

**Confidence: HIGH** -- Verified through spec and code analysis.

---

## 9. Sources

### Codebase Sources (Primary)

| File | Purpose in Research |
|------|-------------------|
| `specs/07-phase-5-ui.md` (lines 421-534) | Step 3 specification |
| `lib/slackex_web/live/chat_live/index.ex` | Main LiveView patterns |
| `lib/slackex_web/live/chat_live/new_dm_modal.ex` | Modal LiveComponent pattern to replicate |
| `lib/slackex_web/live/chat_live/sidebar_component.ex` | Sidebar structure to extend |
| `lib/slackex_web/components/chat_components.ex` | Existing function components |
| `lib/slackex/chat/chat.ex` | Backend context functions |
| `lib/slackex/chat/channel.ex` | Channel schema and changeset |
| `lib/slackex/chat/subscription.ex` | Subscription schema (composite PK) |
| `lib/slackex_web/router.ex` | Current route definitions |
| `docs/design/information-architecture.md` | Route map, user flows, screen states |
| `docs/design/ux-research.md` | Modal patterns, interaction design |
| `docs/design/design-system.md` | Color tokens, spacing, typography |
| `docs/design/component-system.md` | Component specs for CreateChannelModal, BrowseChannelsModal |
| `test/slackex/chat_test.exs` | Context test patterns |
| `test/slackex_web/live/chat_live_test.exs` | LiveView integration test patterns |
| `test/slackex_web/live/chat_live/layout_test.exs` | Layout/component test patterns |
| `test/support/factory.ex` | ExMachina factory definitions |

### External Sources

- [Phoenix LiveView Form Bindings -- v1.1.24](https://hexdocs.pm/phoenix_live_view/form-bindings.html) -- `to_form/2`, changeset validation, `phx-change`/`phx-submit` patterns
- [Phoenix.LiveComponent -- v1.1.24](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveComponent.html) -- `send(self(), msg)` parent communication, lifecycle callbacks
- [Phoenix LiveView Live Navigation](https://hexdocs.pm/phoenix_live_view/live-navigation.html) -- `push_patch/2` vs `push_navigate/2` for modal patterns
- [Phoenix LiveView Navigation Guide (GitHub)](https://github.com/phoenixframework/phoenix_live_view/blob/main/guides/server/live-navigation.md) -- Patch preserves socket state
- [Mastering Phoenix LiveView Patching (DEV)](https://dev.to/hexshift/mastering-phoenix-liveview-patching-stateful-navigation-without-reloading-your-ui-k5p) -- Patch-aware components, modal close patterns
- [Phoenix LiveView Navigation When to Use (DEV)](https://dev.to/ceolinwill/phoenix-liveview-when-to-use-navigate-patch-href-redirect-pushpatch-pushnavigate-6pl) -- Decision guide for navigation types
- [Building Real-Time Features with Phoenix LiveView and PubSub (Elixir School)](https://elixirschool.com/blog/live-view-with-pub-sub) -- PubSub subscribe/broadcast pattern
- [Phoenix.PubSub -- v2.2.0](https://hexdocs.pm/phoenix_pubsub/Phoenix.PubSub.html) -- `broadcast/3`, `subscribe/2` API
- [How to Use Phoenix LiveView for Real-Time UIs (OneUptime)](https://oneuptime.com/blog/post/2026-01-26-phoenix-liveview-realtime/view) -- Real-time list update patterns
- [Ecto Aggregates and Subqueries -- v3.13.5](https://hexdocs.pm/ecto/aggregates-and-subqueries.html) -- Subquery optimization for N+1
- [Ecto Constraints and Upserts -- v3.13.5](https://hexdocs.pm/ecto/constraints-and-upserts.html) -- `on_conflict: :nothing` behavior and caveats
- [Phoenix.LiveViewTest -- v1.1.23](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveViewTest.html) -- `assert_patch/2`, `render_submit/1`, `element/2`
- [Testing LiveView Forms (Fly.io)](https://fly.io/phoenix-files/forms-testing/) -- Form testing patterns
- [Slack Blog: Designing Teamwork](https://slack.com/blog/collaboration/designing-the-future-of-slack-with-customers) -- Channel discovery UX research

---

## Summary

Phase 5 Step 3 is a well-scoped feature addition with clear specification, strong codebase precedent (the NewDmModal pattern), and no architectural surprises. The primary implementation risk is route ordering (HIGH if misconfigured, trivially mitigated). The N+1 query is acknowledged and acceptable at current scale. The biggest decision point is reconciling channel name validation between the spec (stricter) and the schema (permissive).

**Estimated scope:** 7 files changed/created, ~400-500 lines of new code, ~200 lines of tests.

| File | Action | Estimated Lines |
|------|--------|----------------|
| `lib/slackex/chat/chat.ex` | Extend | +40 |
| `lib/slackex_web/router.ex` | Extend | +2 |
| `lib/slackex_web/live/chat_live/create_channel_modal.ex` | Create | ~120 |
| `lib/slackex_web/live/chat_live/browse_channels_modal.ex` | Create | ~130 |
| `lib/slackex_web/live/chat_live/index.ex` | Extend | +80 |
| `lib/slackex_web/live/chat_live/sidebar_component.ex` | Extend | +30 |
| `test/slackex/chat_test.exs` | Extend | +60 |
| `test/slackex_web/live/chat_live/channel_modals_test.exs` | Create | ~200 |
