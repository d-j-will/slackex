# Phase 5 Step 2: DM Conversations in UI — Comprehensive Research

**Research Date:** 2026-02-26
**Scope:** Evidence-driven research for implementing DM conversations in the Slackex LiveView UI
**Method:** 4 parallel research agents covering pg_trgm, LiveView modals, routing patterns, and DM PubSub architecture. Cross-referenced against existing codebase (408 tests, 70 source files).

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Codebase Gap Analysis](#2-codebase-gap-analysis)
3. [PostgreSQL pg_trgm Fuzzy Search](#3-postgresql-pg_trgm-fuzzy-search)
4. [Phoenix LiveView Routing Patterns](#4-phoenix-liveview-routing-patterns)
5. [LiveView Modal & Search-as-you-Type Patterns](#5-liveview-modal--search-as-you-type-patterns)
6. [DM PubSub & Real-Time Patterns](#6-dm-pubsub--real-time-patterns)
7. [Cross-Cutting Concerns & Spec Refinements](#7-cross-cutting-concerns--spec-refinements)
8. [Implementation Recommendations](#8-implementation-recommendations)
9. [Sources](#9-sources)

---

## 1. Executive Summary

Phase 5 Step 2 exposes the existing DM backend in the LiveView UI and adds user search for starting new DMs. The backend infrastructure is **surprisingly mature** — `Messaging.send_dm/4`, `Messaging.subscribe_dm/1`, `ChannelServer` with `:dm` topic types, and the `DMConversation` schema with user ordering invariant all exist. The work is primarily **UI wiring**.

### Key Research Findings

| Area | Finding | Confidence | Impact |
|------|---------|------------|--------|
| **Route ordering** | `/chat/dm/:dm_id` (3 segments) cannot structurally conflict with `/chat/:slug` (2 segments) | HIGH | Spec is safe as written |
| **Index type** | GiST preferred over GIN for user search typeahead (KNN ordering support) | HIGH | Spec refinement opportunity |
| **Minimum query length** | pg_trgm unreliable for <3 char queries; fallback to ILIKE prefix match | HIGH | Must handle in application layer |
| **Modal approach** | LiveComponent for stateful search modal, function component for the modal shell | HIGH | Spec approach is correct |
| **PubSub model** | Dual subscription: permanent `user:#{id}` in mount, conversation-level in handle_params | HIGH | Extends existing pattern |
| **find_or_create_dm race** | TOCTOU vulnerability in current implementation; use `on_conflict: :nothing` | HIGH | Bug fix opportunity |
| **Missing `last_message_at`** | `dm_conversations` table lacks column for proper sidebar ordering | MEDIUM | Schema addition needed |

---

## 2. Codebase Gap Analysis

### What Already Exists

| Component | Location | Status |
|-----------|----------|--------|
| `DMConversation` schema with user ordering | `lib/slackex/chat/dm_conversation.ex` | Complete |
| `Chat.find_or_create_dm/2` | `lib/slackex/chat/chat.ex:237` | Works (has race condition) |
| `Chat.send_dm/3` | `lib/slackex/chat/chat.ex:254` | Complete |
| `Chat.list_dm_messages/2` (paginated) | `lib/slackex/chat/chat.ex:198` | Complete |
| `Chat.list_dms/1` (raw structs) | `lib/slackex/chat/chat.ex:284` | Needs enrichment |
| `Messaging.send_dm/4` (via ChannelServer) | `lib/slackex/messaging/messaging.ex:38` | Complete |
| `Messaging.subscribe_dm/1` | `lib/slackex/messaging/messaging.ex:81` | Complete |
| `ChannelServer` `:dm` topic type | `lib/slackex/messaging/channel_server.ex:409` | Complete |
| `DMChannel` WebSocket channel | `lib/slackex_web/channels/dm_channel.ex` | Complete |
| `Envelope.wrap/4` with `{:dm, id}` target | `lib/slackex/messaging/envelope.ex` | Complete |
| Sidebar `dms_expanded` toggle state | `lib/slackex_web/live/chat_live/sidebar_component.ex:21` | Placeholder only |
| `handle_info({:sidebar_action, _})` | `lib/slackex_web/live/chat_live/index.ex:178` | Placeholder |

### What Needs to Be Built

| Component | Spec Section | Gap Description |
|-----------|-------------|-----------------|
| `Chat.list_user_dm_conversations/1` | 2.2 | Enriched query returning `%{id, other_user: %User{}, last_message_at}` |
| `Chat.get_dm_conversation!/1` | 2.3 | Bang version for handle_params (currently only `get_dm/1` returning tagged tuple) |
| `Accounts.search_users/2` | 2.5 | Trigram fuzzy search with exclude option |
| DM routes in router | 2.1 | `/chat/dm/new` and `/chat/dm/:dm_id` |
| `handle_params` for `:dm` action | 2.3 | Enter DM, subscribe, load messages |
| `handle_params` for `:new_dm` action | 2.4 | Show New DM modal |
| `NewDmModal` LiveComponent | 2.4 | User search, selection, DM creation |
| Sidebar DM list rendering | 2.2 | Display DM conversations below channels |
| `handle_info({:start_dm, ...})` | 2.7 | Find-or-create DM, navigate |
| Trigram migration | 2.6 | `pg_trgm` extension + indexes on users |
| Generalized `unsubscribe_current/1` | — | Handle channel-to-DM and DM-to-channel transitions |

---

## 3. PostgreSQL pg_trgm Fuzzy Search

### 3.1 How Trigrams Work

Strings are lowercased, padded (`"  hello "`), and split into 3-character sliding windows. `similarity(a, b)` returns the Jaccard coefficient (0-1) of the trigram sets. The `%` operator returns true when similarity exceeds the threshold (default 0.3). The `<->` distance operator returns `1 - similarity()`.

**Sources:** PostgreSQL 16 official docs, pganalyze, Citus Data

### 3.2 GIN vs GiST — Index Recommendation

| Criterion | GIN (`gin_trgm_ops`) | GiST (`gist_trgm_ops`) |
|-----------|---------------------|------------------------|
| Filtering speed | **Faster** | Slower |
| KNN ordering (`ORDER BY <->`) | Not supported | **Supported** |
| Build time | Slower | **Faster** |
| Index size | Larger (3-5x B-tree) | **Smaller** (2-3x B-tree) |
| Write overhead | Higher | **Lower** |
| ILIKE acceleration | Yes | Yes |

**Recommendation: Use GiST for user search.** The spec's typeahead pattern (`ORDER BY username <-> 'term' LIMIT 10`) is a KNN query that only GiST can accelerate at the index level. GIN would require computing similarity for all matching rows and then sorting — unnecessary overhead for a small `users` table.

> **Spec refinement:** The spec at section 2.6 specifies GIN indexes. Consider switching to GiST for the user search use case. GIN remains appropriate if ILIKE wildcard acceleration is the primary goal or if the table is very large and read-heavy.

### 3.3 Minimum Query Length — Critical Pitfall

Trigrams are 3-character sequences. Queries shorter than 3 characters produce unreliable results:

- 1-char query: 1 trigram, matches almost everything
- 2-char query: 2 trigrams, very broad matches

**Recommendation:** Enforce minimum 2-3 character length at the application layer. For shorter queries, fall back to `ILIKE 'ab%'` prefix matching (which GIN/GiST trigram indexes also accelerate).

### 3.4 Similarity Threshold

The default threshold of 0.3 is appropriate for user search typeahead. Avoid using `SET pg_trgm.similarity_threshold` in a connection-pooled environment (Ecto) — the setting may not persist across checkouts. Instead, use explicit comparison:

```elixir
where: fragment("similarity(?, ?) > ?", u.username, ^query, ^0.3)
```

### 3.5 Ecto Integration Pattern

```elixir
def search_users(query, opts \\ []) do
  exclude_ids = Keyword.get(opts, :exclude, []) |> List.wrap()
  limit = Keyword.get(opts, :limit, 10)

  from(u in User,
    where: u.id not in ^exclude_ids,
    where: fragment("? % ? OR ? % ?", u.username, ^query, u.display_name, ^query),
    order_by: fragment("LEAST(? <-> ?, ? <-> ?)", u.username, ^query, u.display_name, ^query),
    limit: ^limit,
    select: %{id: u.id, username: u.username, display_name: u.display_name, avatar_url: u.avatar_url}
  )
  |> Repo.all()
end
```

**Gotchas:**
- Fragment parameter binding order matters — `%>` has search term LEFT, column RIGHT
- The `%` pg_trgm operator does not conflict with Ecto's `?` interpolation
- pg_trgm is **case-insensitive** by default (lowercases before extracting trigrams)

---

## 4. Phoenix LiveView Routing Patterns

### 4.1 Route Ordering

Phoenix compiles routes into pattern-matched function clauses in definition order. The first matching clause wins. Key finding: **segment count matters**.

| Route | Segments | Conflict Risk |
|-------|----------|--------------|
| `/chat` | 1 | None |
| `/chat/dm/new` | 3 (all literal) | None vs `:slug` (different segment count) |
| `/chat/dm/:dm_id` | 3 (parameterized last) | Must follow `/chat/dm/new` |
| `/chat/:slug` | 2 (parameterized) | Cannot capture 3-segment paths |

**Key insight:** `/chat/:slug` (2 segments) **cannot** accidentally match `/chat/dm/42` (3 segments). The structural conflict the spec warns about only applies at same segment counts. However, `/chat/dm/new` MUST precede `/chat/dm/:dm_id` to avoid `"new"` being captured as a `dm_id`.

**Source:** Phoenix.Router `__before_compile__` compilation mechanism (lines 455-465, 599-619)

### 4.2 Recommended Route Order

```elixir
live_session :chat,
  on_mount: [{SlackexWeb.UserAuth, :ensure_authenticated}],
  layout: {SlackexWeb.Layouts, :chat} do
  live "/chat", ChatLive.Index, :index
  live "/chat/dm/new", ChatLive.Index, :new_dm
  live "/chat/dm/:dm_id", ChatLive.Index, :dm
  live "/chat/:slug", ChatLive.Index, :show
end
```

### 4.3 push_patch for ALL In-View Navigation

Since all chat routes point to the same `ChatLive.Index` LiveView within the same `live_session :chat`, **use `push_patch` for all navigation**. This preserves the WebSocket connection, LiveView process, socket assigns, and scroll position. `push_navigate` would remount the LiveView (unnecessary here).

| Navigation | Method |
|------------|--------|
| Channel -> Channel | `push_patch` |
| Channel -> DM | `push_patch` |
| DM -> Channel | `push_patch` |
| Any -> New DM modal | `push_patch` |

**Source:** Phoenix.LiveView `push_patch/2` docs (lines 1062-1087)

### 4.4 handle_params Multi-Action Pattern

```elixir
def handle_params(%{"dm_id" => dm_id}, _uri, socket) do
  # @live_action == :dm
end

def handle_params(%{"slug" => slug}, _uri, socket) do
  # @live_action == :show (existing)
end

def handle_params(_params, _uri, %{assigns: %{live_action: :new_dm}} = socket) do
  # Show modal
end

def handle_params(_params, _uri, socket) do
  # @live_action == :index (existing fallback)
end
```

**Source:** Phoenix.LiveView.Router `live/4` macro documentation

---

## 5. LiveView Modal & Search-as-you-Type Patterns

### 5.1 Modal Architecture Decision

| Modal Type | Component Type | Rationale |
|------------|---------------|-----------|
| Modal shell (backdrop, close, animation) | **Function component** | Presentational only |
| New DM content (search + selection) | **LiveComponent** | Owns search state, handles events |

> "Prefer function components over live components as they are a simpler abstraction. The use case for live components only arises when there is a need to encapsulate both event handling and additional state." — Phoenix.LiveComponent docs

### 5.2 Opening/Closing Pattern

**Open:** `push_patch` to `/chat/dm/new` sets `@live_action = :new_dm`, which conditionally renders the modal via `:if`.

**Close:** `JS.patch(~p"/chat")` or `push_patch(socket, to: ~p"/chat")` changes `@live_action` back, removing the modal. The `phx-remove` binding triggers exit animation.

```heex
<.modal :if={@live_action == :new_dm} id="new-dm-modal" on_cancel={JS.patch(~p"/chat")}>
  <.live_component module={NewDmModal} id="new-dm" current_user={@current_user} />
</.modal>
```

**Source:** Phoenix.LiveView.Router docs, Phoenix.LiveView.JS modal example

### 5.3 Search-as-you-Type

- Use `phx-change` on a form wrapping the search input
- Use `phx-debounce="300"` on the input (300ms is the industry standard for typeahead)
- Use `phx-target={@myself}` to route events to the LiveComponent
- Enforce minimum query length (>= 2 chars) before querying the database
- Show "No users found" only when query is >= 2 chars and results are empty

### 5.4 Parent-Child Communication

The canonical pattern is `send(self(), message)` from LiveComponent to parent LiveView:

```elixir
# In NewDmModal LiveComponent
def handle_event("select_user", %{"user-id" => user_id}, socket) do
  send(self(), {:start_dm, String.to_integer(user_id)})
  {:noreply, socket}
end

# In ChatLive.Index parent
def handle_info({:start_dm, other_user_id}, socket) do
  case Chat.find_or_create_dm(user.id, other_user_id) do
    {:ok, dm} -> {:noreply, push_patch(socket, to: ~p"/chat/dm/#{dm.id}")}
    {:error, _} -> {:noreply, put_flash(socket, :error, "Could not start conversation.")}
  end
end
```

**Source:** Phoenix.LiveComponent docs; existing `SidebarComponent` pattern in codebase

### 5.5 Phoenix 1.8 Modal Note

Phoenix 1.8's `phx.gen.live` generator **no longer includes a `modal/1` component** in CoreComponents (changed from 1.7). A custom modal function component must be created. The `Phoenix.LiveView.JS` module provides the building blocks: `JS.show/hide` with transitions, `phx-click-away`, `phx-window-keydown` + `phx-key="escape"`, `JS.focus_first`, `JS.pop_focus`.

---

## 6. DM PubSub & Real-Time Patterns

### 6.1 Three-Tier Topic Architecture

| Topic | Scope | Lifecycle | Purpose |
|-------|-------|-----------|---------|
| `"channel:#{id}"` | One channel | Subscribe in `handle_params`, unsubscribe on navigation | Channel messages, typing |
| `"dm:#{dm_id}"` | One DM conversation | Subscribe in `handle_params`, unsubscribe on navigation | DM messages, typing |
| `"user:#{user_id}"` | One user (all views) | Subscribe in `mount` (permanent) | Cross-conversation notifications, sidebar updates |

**Source:** ChannelServer (`channel_server.ex:409`), Messaging module (`messaging.ex:69-88`)

### 6.2 Subscription Lifecycle

```
mount/3
  └── subscribe("user:#{user_id}")           ← permanent

handle_params(%{"slug" => slug})              ← channel navigation
  ├── unsubscribe_current_conversation()
  └── subscribe("channel:#{channel_id}")

handle_params(%{"dm_id" => dm_id})            ← DM navigation
  ├── unsubscribe_current_conversation()
  └── subscribe("dm:#{dm_id}")

handle_params(_, _, %{live_action: :index})   ← lobby
  └── unsubscribe_current_conversation()

terminate/2
  └── (PubSub auto-cleans on process death)
```

### 6.3 Generalized Conversation Tracking

The current codebase only handles channel-to-channel transitions. DM support requires a generalized helper. **Recommended: tagged tuple assigns.**

```elixir
# Instead of separate :active_channel and :active_dm
assign(socket, :active_conversation, {:channel, channel})
assign(socket, :active_conversation, {:dm, dm})
assign(socket, :active_conversation, nil)

defp leave_conversation(socket) do
  if connected?(socket) do
    case socket.assigns[:active_conversation] do
      {:channel, %{id: id}} -> Messaging.unsubscribe_channel(id)
      {:dm, %{id: id}} -> Messaging.unsubscribe_dm(id)
      _ -> :ok
    end
  end
  assign(socket, :active_conversation, nil)
end
```

> **Note:** This is a structural refactor of the existing `active_channel` assign. Alternatively, keep `active_channel` and add `active_dm` with explicit nil-checking in each transition, matching the spec's approach more closely.

### 6.4 DM Notification Delivery (Cross-Conversation)

When User A sends a DM while User B is viewing a different conversation:

1. `ChannelServer` broadcasts to `"dm:#{dm_id}"` → User B not subscribed (viewing channel) → ignored
2. `ChannelServer` broadcasts to `"user:#{user_b_id}"` → User B's LiveView always subscribed → sidebar updates

The user-level broadcast should include enough data to update the sidebar (DM id, sender info, preview text).

### 6.5 find_or_create_dm Race Condition Fix

**Current code** (TOCTOU vulnerable):
```elixir
case Repo.get_by(DMConversation, user_a_id: a, user_b_id: b) do
  nil -> Repo.insert(changeset)  # Two concurrent calls both reach here
  dm -> {:ok, dm}
end
```

**Recommended fix** (matches existing `join_channel` pattern at `chat.ex:89`):
```elixir
%DMConversation{}
|> DMConversation.changeset(%{user_a_id: a, user_b_id: b})
|> Repo.insert(on_conflict: :nothing, conflict_target: [:user_a_id, :user_b_id])
|> case do
  {:ok, %{id: nil}} ->
    {:ok, Repo.get_by!(DMConversation, user_a_id: a, user_b_id: b)}
  {:ok, dm} -> {:ok, dm}
  {:error, changeset} -> {:error, changeset}
end
```

### 6.6 Security: Defense in Depth

DM authorization is verified at **every layer** — a strength of the existing architecture:

| Layer | Check | Prevents |
|-------|-------|----------|
| `handle_params` | `user.id in [dm.user_a_id, dm.user_b_id]` | URL manipulation |
| `Messaging.send_dm/4` | `validate_dm_participant/2` | Unauthorized send |
| `ChannelServer.check_permission/3` | Participant check | Direct GenServer bypass |
| `DMChannel.join/3` | Participant check | Unauthorized WebSocket subscription |
| DB CHECK constraint | `user_a_id < user_b_id` | User ordering invariant bypass |
| DB unique index | `[:user_a_id, :user_b_id]` | Duplicate conversations |

---

## 7. Cross-Cutting Concerns & Spec Refinements

### 7.1 Spec Refinements Identified

| Section | Current Spec | Recommended Refinement | Rationale |
|---------|-------------|----------------------|-----------|
| 2.5 | Uses `%` operator only | Add minimum query length guard (>= 2-3 chars) | Trigrams unreliable for short queries |
| 2.5 | Combined `OR` for username and display_name | Consider adding `ILIKE` prefix fallback for short queries | Better UX for 1-2 char searches |
| 2.6 | GIN indexes (`gin_trgm_ops`) | Consider GiST (`gist_trgm_ops`) | KNN ordering for typeahead; lower write overhead |
| 2.6 | Only trigram indexes | Consider also adding `display_name` to the migration | Spec's search_users queries both fields |
| — | No `last_message_at` column | Add to `dm_conversations` or compute via subquery | Sidebar ordering by recent activity |
| 2.3 | Uses `Chat.get_dm_conversation!/1` | Function doesn't exist; need to create or use `get_dm/1` + raise | API gap |
| — | No user-level DM notification | Add broadcast to `"user:#{recipient_id}"` on DM send | Sidebar updates when viewing other conversations |

### 7.2 Missing `modal/1` Component

Phoenix 1.8 does not generate a `modal/1` in CoreComponents. The project needs a custom modal function component with:
- Backdrop + click-away dismiss (`phx-click-away`)
- Escape key dismiss (`phx-window-keydown` + `phx-key="escape"`)
- Show/hide transitions via `JS.show`/`JS.hide`
- Focus management (`JS.focus_first`, `JS.pop_focus`)
- `on_cancel` callback (typically `JS.patch(~p"/chat")`)

### 7.3 `connected?/1` Guards

All PubSub subscribe/unsubscribe calls must be wrapped in `connected?(socket)` guards. During the initial static HTML render (disconnected), PubSub operations are meaningless and should be skipped. The existing codebase follows this pattern correctly.

---

## 8. Implementation Recommendations

### Build Order

| Order | Component | Dependencies | Risk |
|-------|-----------|-------------|------|
| 1 | Trigram migration | None | Low — additive schema change |
| 2 | `Accounts.search_users/2` | Migration #1 | Low — new function, no side effects |
| 3 | `Chat.list_user_dm_conversations/1` | None | Low — new query function |
| 4 | Routes in router | None | Low — additive route change |
| 5 | `modal/1` function component | None | Low — UI component |
| 6 | `NewDmModal` LiveComponent | #2, #5 | Medium — new component with search |
| 7 | `handle_params` for `:dm` and `:new_dm` | #3, #4 | Medium — core navigation logic |
| 8 | Sidebar DM list rendering | #3 | Low — template extension |
| 9 | `handle_info({:start_dm, ...})` | #6, #7 | Low — event wiring |
| 10 | Generalized conversation unsubscribe | #7 | Medium — refactors existing pattern |

### Testing Strategy

- **Unit:** `search_users/2` with various query lengths, special characters, exclude lists
- **Unit:** `list_user_dm_conversations/1` with preloaded other_user
- **Integration:** Route ordering (ensure `/chat/dm/new` doesn't match as slug)
- **Integration:** DM navigation lifecycle (subscribe/unsubscribe across transitions)
- **LiveView:** NewDmModal search debounce, user selection, parent communication
- **LiveView:** DM message display, send, real-time receive
- **Contract:** find_or_create_dm idempotency under concurrent calls

---

## 9. Sources

### Primary Sources (Framework)

| ID | Source | Version |
|----|--------|---------|
| F1 | `Phoenix.Router` module doc | Phoenix 1.8.1 |
| F2 | `Phoenix.LiveView.Router` `live/4` macro | LiveView 1.1.0 |
| F3 | `Phoenix.LiveView` `push_patch/2`, `push_navigate/2` | LiveView 1.1.0 |
| F4 | `Phoenix.LiveComponent` module doc | LiveView 1.1.0 |
| F5 | `Phoenix.LiveView.JS` module doc | LiveView 1.1.0 |
| F6 | `Phoenix.Component` module doc | LiveView 1.1.0 |
| F7 | `phx.gen.live` generator templates | Phoenix 1.8.1 |

### Primary Sources (Database)

| ID | Source | URL |
|----|--------|-----|
| D1 | PostgreSQL 16 — pg_trgm | https://www.postgresql.org/docs/16/pgtrgm.html |
| D2 | PostgreSQL 16 — GIN/GiST index types | https://www.postgresql.org/docs/16/gin.html |
| D3 | pganalyze — pg_trgm fuzzy matching | https://pganalyze.com/blog/pg-trgm-fuzzy-matching |
| D4 | Citus Data — Trigram indexes | https://www.citusdata.com/blog/2013/09/17/trigram-indexes-for-wildcard-search/ |
| D5 | Supabase — pg_trgm docs | https://supabase.com/docs/guides/database/extensions/pg_trgm |
| D6 | Percona — PostgreSQL trigram search | https://www.percona.com/blog/postgresql-trigram-search/ |

### Primary Sources (Codebase)

| ID | File | Key Content |
|----|------|-------------|
| C1 | `lib/slackex/messaging/channel_server.ex` | ChannelServer `:dm` topic, envelope broadcast |
| C2 | `lib/slackex/messaging/messaging.ex` | subscribe_dm, send_dm, subscribe_user |
| C3 | `lib/slackex/messaging/envelope.ex` | Versioned envelope with `{:dm, id}` target |
| C4 | `lib/slackex/chat/chat.ex` | find_or_create_dm, list_dms, send_dm |
| C5 | `lib/slackex/chat/dm_conversation.ex` | User ordering invariant |
| C6 | `lib/slackex_web/live/chat_live/index.ex` | Current handle_params, enter_channel |
| C7 | `lib/slackex_web/live/chat_live/sidebar_component.ex` | dms_expanded toggle |
| C8 | `lib/slackex_web/router.ex` | Current route structure |
| C9 | `lib/slackex/accounts/user.ex` | User schema fields |
| C10 | `priv/repo/migrations/20260221000007_create_dm_conversations.exs` | DB constraints |

### Knowledge Gaps

| Gap | Impact | Mitigation |
|-----|--------|------------|
| No web access for community validation | Medium | All findings verified against framework source code |
| No benchmarks on actual Slackex data | Low | User table is small (<1000 rows); performance is not a concern |
| daisyUI modal + LiveView DOM patching | Low | Test modal component with daisyUI classes empirically |
| Phoenix compile-time route shadowing warnings | Low | Phoenix silently uses first match; no warnings found in source |
| `last_message_at` migration impact | Low | Additive column with default; zero-downtime migration |
