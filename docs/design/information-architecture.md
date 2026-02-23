# Information Architecture — Slackex

**Prepared by:** Ariadne (Information Architect)
**Date:** 2026-02-23
**Scope:** Phase 5 UI — Full-Feature Chat Application
**Status:** Design reference for implementation

---

## Table of Contents

1. [Navigation Model](#1-navigation-model)
2. [Information Hierarchy](#2-information-hierarchy)
3. [Screen States](#3-screen-states)
4. [Key User Flows](#4-key-user-flows)
5. [Keyboard-Driven Workflows](#5-keyboard-driven-workflows)
6. [Responsive Breakpoints](#6-responsive-breakpoints)
7. [Content and Naming Guide](#7-content-and-naming-guide)

---

## 1. Navigation Model

### 1.1 Complete URL Map

Every route in the application, with its `live_action` value and the component(s) rendered:

| URL Pattern | `live_action` | Component(s) Rendered | Auth Required |
|---|---|---|---|
| `/` | — | `PageController` (static) | No |
| `/users/register` | `:new` | `AuthLive.Register` | No (redirects if logged in) |
| `/users/log-in` | `:new` | `AuthLive.Login` | No (redirects if logged in) |
| `/invite/:code` | `:redeem` | `InviteLive` | No (handles both states) |
| `/chat` | `:index` | `ChatLive.Index` — welcome state | Yes |
| `/chat/:slug` | `:show` | `ChatLive.Index` — channel view | Yes |
| `/chat/:slug/thread/:message_id` | `:thread` | `ChatLive.Index` — channel + thread panel | Yes |
| `/chat/:slug/members` | `:members` | `ChatLive.Index` + `ChannelMembersModal` | Yes |
| `/chat/:slug/pins` | `:pinned` | `ChatLive.Index` + `PinnedMessagesModal` | Yes |
| `/chat/:slug/invites` | `:invites` | `ChatLive.Index` + `InviteLinkModal` | Yes |
| `/chat/channels/new` | `:create_channel` | `ChatLive.Index` + `CreateChannelModal` | Yes |
| `/chat/channels/browse` | `:browse_channels` | `ChatLive.Index` + `BrowseChannelsModal` | Yes |
| `/chat/dm/new` | `:new_dm` | `ChatLive.Index` + `NewDmModal` | Yes |
| `/chat/dm/:dm_id` | `:dm` | `ChatLive.Index` — DM view | Yes |
| `/chat/profile/edit` | `:edit_profile` | `ChatLive.Index` + `EditProfileModal` | Yes |

**Route ordering note:** The router must declare `/chat/channels/new`, `/chat/channels/browse`, `/chat/dm/new`, and `/chat/profile/edit` before `/chat/:slug` to prevent the slug pattern from capturing those literal path segments. Similarly, `/chat/dm/:dm_id` must be distinct from `/chat/:slug`.

**Quick switcher** is not URL-routed — it is a modal toggled by `Ctrl+K`/`Cmd+K` that lives entirely in client-side state.

---

### 1.2 Navigation Mechanisms

#### live_patch (same LiveView, no remount)
Used for all in-chat navigation. The single `ChatLive.Index` LiveView persists across these transitions, preserving socket state, PubSub subscriptions, and unread counts.

```
/chat  →  /chat/:slug          live_patch  (enter channel)
/chat/:slug  →  /chat/:slug/thread/:message_id   live_patch  (open thread)
/chat/:slug  →  /chat/:slug/members              live_patch  (open modal)
/chat/:slug  →  /chat/channels/new               live_patch  (open modal)
/chat/:slug  →  /chat/dm/:dm_id                  live_patch  (switch to DM)
```

#### redirect (full page transition)
Used only when crossing authentication boundaries or leaving the LiveView entirely.

```
/invite/:code  →  /users/log-in?invite=:code     redirect  (unauthenticated)
/users/log-in  →  /chat                          redirect  (after login)
/users/register  →  /chat                        redirect  (after register)
```

#### Sidebar navigation
Clicking a channel or DM item in the sidebar calls `live_patch` to the appropriate URL. This is the primary navigation mechanism for switching contexts.

#### In-context navigation
- Clicking a message's reply count badge → `live_patch` to `/:slug/thread/:message_id`
- Clicking member count in channel header → `live_patch` to `/:slug/members`
- Clicking pin count in channel header → `live_patch` to `/:slug/pins`
- Clicking "Generate Invite" in members modal → `live_patch` to `/:slug/invites`

---

### 1.3 Where-Am-I Indicators (Context Signals)

Users always need to know: which channel, which conversation, and which panel are active.

| Signal | Location | What it Communicates |
|---|---|---|
| **Active sidebar item** | Sidebar channel/DM list | Currently selected channel or DM (highlighted row) |
| **Channel header** | Main content area, top | Channel name (`#general`), description, member count, pin count |
| **DM header** | Main content area, top | Other user's name, avatar, and online status indicator |
| **Thread panel header** | Right panel, top | "Thread" label + parent message sender and preview |
| **URL** | Browser address bar | Full current path; deep-linkable |
| **Browser tab title** | Browser tab | `#channel-name — Slackex` or `@username — Slackex` |
| **Unread badge** | Sidebar items | Bold channel name + count pill when messages are unread |
| **Modal title** | Modal header | Clearly names the modal's purpose (e.g., "Create Channel") |

**No breadcrumb trail** is needed — the information hierarchy is shallow (2 levels max: workspace → channel/DM) and the sidebar provides the full map at all times.

---

### 1.4 Back Button Behavior

Because all in-chat navigation uses `live_patch`, the browser back button traverses URL history without remounting the LiveView. The behavior for each transition:

| User presses Back from... | Arrives at... | Effect |
|---|---|---|
| Thread panel open (`/:slug/thread/:id`) | `/:slug` | Thread panel closes, message list expands |
| Modal open (`/:slug/members`, `/channels/new`, etc.) | Previous URL | Modal unmounts, underlying view restored |
| Channel view (`/:slug`) | `/chat` or prior URL | Welcome state or previous channel |
| DM view (`/chat/dm/:dm_id`) | Previous URL | Prior channel or welcome state |
| `/invite/:code` error state | Previous page | Outside the app (browser handles) |

**Principle:** Back always closes the "deepest" layer first (modal → thread → channel → welcome). This matches standard browser expectations.

**In-app close buttons** (on modals, thread panel) also call `live_patch` back to the previous URL, keeping browser history consistent with native back button behavior.

---

### 1.5 Deep Linking

All routes are deep-linkable and shareable:

| Link shared | Recipient lands on | Unauthenticated redirect |
|---|---|---|
| `/chat/:slug` | Channel view | → `/users/log-in`, then `/chat/:slug` after login |
| `/chat/:slug/thread/:message_id` | Channel with thread panel open | → login → thread |
| `/chat/dm/:dm_id` | DM conversation (if participant) | → login → DM or "Not found" |
| `/invite/:code` | Invite redemption page | → login with `?invite=:code`, then auto-redeem |

**Thread deep links** load the full channel message list plus the thread panel. The parent message is always visible in the thread panel header, providing context even without scrolling to it in the main list.

**DM deep links** validate participant membership before loading — non-participants are redirected to `/chat` with an error flash.

---

## 2. Information Hierarchy

### 2.1 Layers of Visibility

```
┌─────────────────────────────────────────────────────────────────┐
│  LAYER 0: ALWAYS VISIBLE (persistent layout)                    │
│  ┌──────────────────┐  ┌──────────────────────────────────────┐ │
│  │    SIDEBAR       │  │         MAIN CONTENT AREA            │ │
│  │  (always on      │  │   (changes based on live_action)     │ │
│  │   desktop)       │  │                                      │ │
│  └──────────────────┘  └──────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  LAYER 1: CONTEXTUAL (visible when a channel/DM is active)      │
│  • Channel header (name, description, member count, pin count)  │
│  • Message list with scroll                                     │
│  • Compose area (textarea + send button)                        │
│  • Typing indicator                                             │
│  • Thread panel (when live_action == :thread)                   │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  LAYER 2: ON-DEMAND (visible only when triggered)               │
│  • Modals (create channel, browse, new DM, members, pins,       │
│    invites, edit profile)                                       │
│  • Profile popover (click any avatar/username)                  │
│  • Message hover actions (edit, delete, react, reply, pin)      │
│  • Emoji picker (triggered from message hover action)           │
│  • Quick switcher (Ctrl+K)                                      │
│  • Mobile sidebar (hamburger button)                            │
└─────────────────────────────────────────────────────────────────┘
```

---

### 2.2 Sidebar Hierarchy

```
SIDEBAR (256px wide on desktop, 288px on mobile overlay)
│
├── WORKSPACE HEADER
│   └── "Slackex" (workspace name)
│       └── [≡ Hamburger] (mobile only, top-right of sidebar)
│
├── CHANNELS SECTION
│   ├── Section label: "Channels"   [+] [Browse]
│   ├── channel-list-item: # general         [bold if unread] [99]
│   ├── channel-list-item: # design          [normal if read]
│   ├── channel-list-item: # engineering
│   └── ... (scrollable if many channels)
│
├── DIRECT MESSAGES SECTION
│   ├── Section label: "Direct Messages"     [+]
│   ├── dm-list-item: [●] Alice Smith        [bold if unread] [3]
│   ├── dm-list-item: [○] Bob Jones
│   └── ... (scrollable)
│
└── USER FOOTER (always at bottom)
    ├── [avatar + online dot] Display Name
    ├── Status text (truncated)
    ├── [✏] Edit profile button
    └── [☀/☾] Theme toggle
```

**Priority order within sidebar:**
1. Workspace identity (top) — orientation
2. Channels with unread messages (sorted to top of section or badged)
3. DMs with unread messages
4. Read channels and DMs
5. User identity and controls (bottom) — always accessible

---

### 2.3 Main Content Area Hierarchy

#### Channel view (`:show`)

```
MAIN CONTENT AREA
│
├── CHANNEL HEADER (sticky top)
│   ├── # channel-name (H1)
│   ├── Channel description (subtitle, truncated)
│   ├── [👥 N members] → opens members modal
│   ├── [📌 N pins] → opens pinned messages modal
│   └── [Join Channel] or [Leave Channel] (conditional)
│
├── MESSAGE LIST (scrollable, fills remaining height)
│   ├── [Load older messages...] (appears at top when scrolling up)
│   ├── message-bubble: [avatar] Username  timestamp
│   │   ├── Message content
│   │   ├── "(edited)" indicator (if edited)
│   │   ├── Reaction bar (emoji pills, "+" button)
│   │   ├── "N replies" link (if reply_count > 0)
│   │   └── [hover] → edit | delete | react | reply | pin (admin)
│   ├── message-bubble: ...
│   ├── [deleted] "[This message was deleted]" placeholder
│   └── Typing indicator: "Alice is typing..."
│
└── COMPOSE AREA (sticky bottom)
    ├── Textarea: "Message #channel-name"
    └── [Send] button (or icon button)
```

**Priority order within message list:**
1. Most recent messages (bottom of scroll) — primary content
2. Reaction bars — social signal, immediate feedback
3. Reply count links — conversation depth indicator
4. Typing indicator — presence signal
5. Older messages (top) — historical context, loaded on demand

---

### 2.4 Thread Panel Hierarchy

```
THREAD PANEL (400px on desktop, full-width on mobile)
│
├── PANEL HEADER (sticky)
│   ├── "Thread"
│   └── [✕ Close] button → live_patch back to /:slug
│
├── PARENT MESSAGE (pinned at top, read-only, visually distinct)
│   ├── [avatar] Username  timestamp
│   └── Message content (full)
│
├── DIVIDER: "N replies"
│
├── REPLY LIST (scrollable)
│   ├── reply-bubble: [avatar] Username  timestamp
│   │   └── Reply content
│   └── ...
│
└── REPLY COMPOSE (sticky bottom)
    ├── Textarea: "Reply..."
    └── [Send] button
```

---

### 2.5 Modal Hierarchy

All modals share the same structural pattern:

```
MODAL OVERLAY (full-screen backdrop, z-index above everything)
│
└── MODAL DIALOG (centered, max-width varies by content)
    ├── MODAL HEADER
    │   ├── Title (e.g., "Create Channel")
    │   └── [✕ Close] button → live_patch back
    ├── MODAL BODY (scrollable if tall)
    │   └── [content specific to each modal]
    └── MODAL FOOTER
        ├── [Primary Action] button (e.g., "Create Channel")
        └── [Cancel] button → live_patch back
```

**Modal content structures:**

```
CREATE CHANNEL MODAL
├── Name field: "e.g. team-updates" (auto-formats to lowercase-hyphenated)
├── Description field: "What's this channel about?"
├── Private toggle: "Make private"
└── [Create Channel] [Cancel]

BROWSE CHANNELS MODAL
├── Search input: "Search channels..."
├── Channel list (filterable):
│   └── row: # channel-name | description | N members | [Join]
└── (no footer buttons — [Join] is inline)

NEW DM MODAL
├── Search input: "Search users..."
├── Results list:
│   └── row: [avatar] Display name @username | [Select]
└── (no footer — selecting navigates immediately)

EDIT PROFILE MODAL
├── Avatar preview + URL field
├── Display name field
├── Status field: "What are you up to?"
└── [Save Changes] [Cancel]

CHANNEL MEMBERS MODAL
├── Search input: "Search members..."
├── Member list:
│   └── row: [avatar] Name @username | [role badge] | [▼ role menu] [Kick] (admin+)
└── (no footer buttons)

PINNED MESSAGES MODAL
├── Pinned message list:
│   └── row: [avatar] Sender | message preview | pinned date | [Unpin] (admin+)
└── (no footer buttons)

INVITE LINK MODAL
├── Existing links list:
│   └── row: code | uses | expires | [Copy] [Revoke]
├── GENERATE NEW LINK form:
│   ├── Max uses: [None ▼]
│   ├── Expires: [7 days ▼]
│   └── [Generate Link]
└── (no footer buttons)
```

---

## 3. Screen States

Every distinct configuration the UI can be in, with its URL and what's visible:

### State 0: Welcome (no channel selected)

**URL:** `/chat`
**live_action:** `:index`

```
[Sidebar] [Main: empty state]
           "Welcome to Slackex"
           "Select a channel to get started, or browse available channels."
           [Browse Channels] [Create Channel]
```

**Visible:** Sidebar (channels loaded, no item highlighted), empty state in main area.
**Hidden:** Channel header, message list, compose area, thread panel.

---

### State 1: Channel selected

**URL:** `/chat/:slug`
**live_action:** `:show`

```
[Sidebar: #general highlighted] [Channel header] [Message list] [Compose]
```

**Visible:** All persistent layout + channel header, message list, compose area.
**Hidden:** Thread panel, any modals.

---

### State 2: Channel + thread open (split view)

**URL:** `/chat/:slug/thread/:message_id`
**live_action:** `:thread`

```
[Sidebar] [Channel header                                      ]
          [Message list (narrower)] | [Thread panel (400px)   ]
          [Compose (main)         ] | [Reply compose (thread) ]
```

**Visible:** Full channel view + thread panel alongside (desktop) or overlaid (mobile).
**Hidden:** Modals.
**Note:** Message list narrows to accommodate thread panel on desktop. Thread panel has its own compose for replies.

---

### State 3: Modal open

**URL:** `/chat/:slug/members` | `/chat/:slug/pins` | `/chat/:slug/invites` | `/chat/channels/new` | `/chat/channels/browse` | `/chat/dm/new` | `/chat/profile/edit`
**live_action:** `:members` | `:pinned` | `:invites` | `:create_channel` | `:browse_channels` | `:new_dm` | `:edit_profile`

```
[Sidebar] [Channel view (behind, dimmed)]
                  ┌────────────────────┐
                  │   MODAL DIALOG     │
                  └────────────────────┘
```

**Visible:** Full underlying view + modal overlay on top.
**Behind modal:** Channel view remains rendered but non-interactive (backdrop intercepts clicks).
**Note:** Thread panel, if open, remains open behind the modal.

---

### State 4: DM conversation

**URL:** `/chat/dm/:dm_id`
**live_action:** `:dm`

```
[Sidebar: DM item highlighted] [DM header] [Message list] [Compose]
```

**Visible:** Same layout as State 1 but with DM-specific header (user avatar, name, online status). No "Join/Leave Channel" button. No pin/member count.
**Hidden:** Channel-specific controls (pin, member count, join/leave).

---

### State 5: Mobile — sidebar open

**URL:** Any chat URL
**Trigger:** Hamburger button tap

```
[Sidebar (overlay, full height, z-40)] [Backdrop (z-30, dimmed)]
[Main content (behind, non-interactive)                         ]
```

**Visible:** Sidebar slides in over content. Backdrop covers main content.
**Interaction:** Tap backdrop or tap a sidebar item → sidebar closes.
**Note:** This is a client-side state only; no URL change. The `sidebar_open` assign controls rendering.

---

### State 6: Quick switcher open

**URL:** Current URL (unchanged)
**Trigger:** `Ctrl+K` / `Cmd+K`

```
[Current view (behind)]
        ┌──────────────────────────────┐
        │  [🔍 Search channels, DMs...] │
        │  > # general                 │
        │  > # design                  │
        │  > @ Alice Smith             │
        └──────────────────────────────┘
```

**Visible:** Centered search dialog over current view. Live-filtered results as user types.
**Closes on:** `Escape`, click outside, or selecting a result.
**Note:** Client-side state only; no URL change.

---

### State 7: Profile popover open

**URL:** Current URL (unchanged)
**Trigger:** Click on any avatar or username

```
[Message list (behind)]
  ┌────────────────────────┐
  │ [avatar large]         │
  │ Display Name           │
  │ @username              │
  │ "Status text"          │
  │ [●] Online             │
  │ [Message]  [Block]     │
  └────────────────────────┘
```

**Closes on:** Click outside, `Escape`.
**Note:** Client-side state only. Only one popover open at a time.

---

### State 8: Message edit mode (inline)

**URL:** Current URL (unchanged)
**Trigger:** Click edit (pencil) on own message

```
[Message bubble]
  [avatar] Username  timestamp
  ┌──────────────────────────────────────┐
  │ [inline textarea with current text]  │
  └──────────────────────────────────────┘
  [Save] [Cancel]  (Escape to cancel, Enter to save)
```

**Note:** Only one message can be in edit mode at a time. Other messages remain in read mode.

---

### State 9: Disconnected / reconnecting

**URL:** Current URL (unchanged)
**Trigger:** WebSocket disconnection

```
[Yellow banner at top]
"Connection lost. Reconnecting..."   [●●●]

→ On reconnect:
"Back online. Loading missed messages..."  [spinner]

→ On catchup complete:
Banner fades out, unread badges update.
```

---

## 4. Key User Flows

### Flow A: First-time user onboarding

**Goal:** New user registers, finds a channel, and sends their first message.

```
Step 1  /users/register
        User fills: username, email, password
        Clicks [Create Account]
        → Server creates user, logs them in
        → live_redirect to /chat

Step 2  /chat (State 0: Welcome)
        User sees: "Welcome to Slackex" empty state
        Sees sidebar: no channels yet (only channels they're in)
        Clicks [Browse Channels]
        → live_patch to /chat/channels/browse

Step 3  /chat/channels/browse (State 3: Modal)
        User sees: list of public channels with names, descriptions, member counts
        Finds "# general" — clicks [Join]
        → Chat.join_channel called
        → send(self(), {:channel_joined, channel})
        → live_patch to /chat/general

Step 4  /chat/general (State 1: Channel selected)
        Sidebar now shows "# general" highlighted
        Message list shows recent messages (or empty state if no messages yet)
        Compose area shows: "Message #general"
        User types a message, presses Enter
        → Message sent, appears in list immediately

        First message sent ✓
```

**State transitions:** Welcome → Modal (Browse) → Channel

---

### Flow B: Start a DM conversation

**Goal:** User finds another user and opens a direct message conversation.

```
Step 1  User is in any channel view
        Sees "Direct Messages" section in sidebar
        Clicks [+] next to "Direct Messages"
        → live_patch to /chat/dm/new

Step 2  /chat/dm/new (State 3: Modal — New DM)
        Modal opens: "New Message"
        User types in "Search users..." input
        → phx-change fires "search" event
        → Accounts.search_users/2 returns fuzzy matches
        Results appear: avatars, display names, usernames

Step 3  User clicks a result row (e.g., "Alice Smith")
        → handle_event "select_user" fires
        → send(self(), {:start_dm, alice_id})
        → Chat.find_or_create_dm(current_user_id, alice_id)
        → live_patch to /chat/dm/:dm_id

Step 4  /chat/dm/:dm_id (State 4: DM conversation)
        Header shows: [avatar] Alice Smith [● Online]
        Message list: empty (or existing messages if prior conversation)
        Compose: "Message Alice Smith"
        User types and sends
        → Message delivered in real time

        DM started ✓
```

**State transitions:** Channel → Modal (New DM) → DM

---

### Flow C: React to a message

**Goal:** User adds an emoji reaction to a message.

```
Step 1  User is viewing a channel (State 1)
        User hovers over a message
        → CSS group-hover reveals action buttons
        → [✏ Edit] [🗑 Delete] [😊 React] [↩ Reply] [📌 Pin (admin)]

Step 2  User clicks [😊 React] button
        → data-emoji-trigger attribute detected by EmojiPicker hook
        → Picker mounts below the button

Step 3  Emoji picker is visible (State: Picker open)
        User browses or searches for emoji
        User clicks an emoji (e.g., 👍)
        → onEmojiSelect fires
        → pushEvent("toggle_reaction", {message_id, emoji: "👍"})
        → picker closes

Step 4  Server: handle_event "toggle_reaction"
        → Chat.toggle_reaction(message_id, user_id, "👍")
        → {:ok, {:added, reaction}}
        → Broadcasts "reaction.toggled" to channel topic
        → All subscribers receive update

Step 5  Reaction bar updates for all clients
        👍 1  (highlighted for the reacting user)

        Reaction added ✓
```

**Idempotent:** Clicking the existing 👍 pill removes the reaction (toggle behavior).

---

### Flow D: Reply in a thread

**Goal:** User opens a thread and sends a reply.

```
Step 1  User is in channel view (State 1)
        User hovers a message → sees "↩ Reply" action button
        User clicks [↩ Reply]
        → live_patch to /chat/:slug/thread/:message_id

Step 2  /chat/:slug/thread/:message_id (State 2: Split view)
        Thread panel slides in from the right (200ms transition)
        Shows: parent message (read-only) + existing replies
        Compose: "Reply..."
        Focus moves to thread compose textarea

Step 3  User types reply, presses Enter
        → ThreadPanelComponent handle_event "send_reply"
        → Messaging.send_reply(channel_id, user_id, parent_id, content)
        → Two broadcasts:
           "message.new" on channel topic (appears in main list with thread indicator)
           "thread.reply" on "thread:#{parent_id}" topic (appears in thread panel)

Step 4  Main message list:
        Parent message shows "N replies" link (incremented)
        Reply appears in main list with "In thread" indicator

        Thread panel:
        Reply appears at bottom of reply list

        Reply sent ✓

Step 5  User clicks [✕ Close] or presses Escape
        → live_patch back to /chat/:slug
        Thread panel slides out (200ms transition)
        Message list expands back to full width
```

**State transitions:** Channel → Channel+Thread → Channel

---

### Flow E: Channel management

**Goal:** Admin creates a channel, generates an invite link, reviews members, and pins a message.

```
Step 1  CREATE CHANNEL
        User clicks [+] next to "Channels" in sidebar
        → live_patch to /chat/channels/new
        CreateChannelModal opens
        User types name: "team-updates"
          → auto-formatted to lowercase-hyphenated
          → live validation shows green check
        Sets description: "Important announcements for the team"
        Leaves private toggle off
        Clicks [Create Channel]
        → Chat.create_channel(current_user, params)
        → send(self(), {:channel_created, channel})
        → Sidebar updates: "# team-updates" added
        → live_patch to /chat/team-updates

Step 2  INVITE MEMBERS VIA LINK
        In /chat/team-updates, user clicks [👥 N members]
        → live_patch to /chat/team-updates/members
        Channel Members modal opens
        User sees themselves listed as owner
        User clicks or navigates to [Invite Links] / [Generate Invite]
        → live_patch to /chat/team-updates/invites
        InviteLink modal opens
        Sets: Max uses = None, Expires = 7 days
        Clicks [Generate Link]
        → Chat.create_invite_link(channel_id, user_id, expires_in_hours: 168)
        Link appears: https://app.slackex.com/invite/AbCdEfGh1234
        User clicks [Copy Link]
        → CopyToClipboard hook writes to clipboard
        Button text briefly shows "Copied!"
        User shares link externally

Step 3  MANAGE MEMBERS (after others join)
        Back in /chat/team-updates/members
        User sees all members with role badges
        Sees "Bob Jones" listed as "member"
        Admin clicks role dropdown next to Bob → selects "admin"
        → Chat.update_member_role(channel_id, actor_id, bob_id, "admin")
        Role badge updates to "admin"

Step 4  PIN A MESSAGE
        User closes modal (back to /chat/team-updates)
        User hovers over an important announcement message
        Admin sees [📌 Pin] button in hover actions
        Clicks [📌 Pin]
        → Chat.pin_message(channel_id, user_id, message_id)
        Pin count in header increments: "📌 1"

        Channel set up ✓
```

---

### Flow F: Edit and delete a message

**Goal:** User corrects a typo in their message; separately, deletes a wrong message.

```
EDIT FLOW:

Step 1  User hovers their own message
        Sees [✏ Edit] in hover actions

Step 2  User clicks [✏ Edit]
        → handle_event "start_edit", %{message_id: id}
        → @editing_message_id set in socket
        Message content transforms to inline textarea
        Current content pre-filled in textarea
        [Save] [Cancel] appear below

Step 3  User modifies text (State 8: Edit mode)
        Presses Enter (or clicks [Save])
        → handle_event "save_edit", %{message_id: id, content: new_content}
        → Messaging.edit_message(channel_id, user_id, message_id, new_content)
        → Broadcasts "message.edited"
        → All clients see updated content + "(edited)" indicator

Step 4  Alternatively, user presses Escape or clicks [Cancel]
        → @editing_message_id cleared
        Inline textarea reverts to original content display

        Message edited ✓

DELETE FLOW:

Step 1  User hovers their own message → sees [🗑 Delete]

Step 2  User clicks [🗑 Delete]
        → Confirmation dialog: "Delete this message? This cannot be undone."
        → [Delete Message] [Cancel]

Step 3  User confirms [Delete Message]
        → handle_event "delete_message", %{message_id: id}
        → Messaging.delete_message(channel_id, user_id, message_id)
        → Broadcasts "message.deleted"
        → All clients: content replaced with "[This message was deleted]"
           (italic, gray, with sender still visible)

        Message deleted ✓
```

---

### Flow G: Reconnection catch-up

**Goal:** User's connection drops and resumes; missed messages appear seamlessly.

```
Step 1  DISCONNECTION
        WebSocket drops (network issue, server restart, etc.)
        → Browser detects lost connection
        → Yellow reconnection banner appears at top:
           "Connection lost. Reconnecting..."
        → User can still see existing messages (read-only)
        → Compose area disabled during disconnection

Step 2  RECONNECTION
        LiveView socket reconnects
        → Banner updates: "Back online. Loading missed messages..."
        → connected?(socket) is true
        → If @last_seen_id is set:
           CatchupServer.build_catchup(user_id, last_seen_id)
        → Missed messages applied to active channel stream
        → Unread badges updated for other channels

Step 3  CATCH-UP COMPLETE
        → Compose area re-enabled
        → Banner fades out (after 2 seconds)
        → If missed messages in active channel: scroll position
          preserved (does not auto-scroll if user was reading history)
        → Unread badges on sidebar updated to reflect missed messages

        Catch-up complete ✓
```

---

## 5. Keyboard-Driven Workflows

### 5.1 Keyboard Shortcut Map

| Shortcut | Context | Action |
|---|---|---|
| `Ctrl+K` / `Cmd+K` | Anywhere in chat | Open quick switcher |
| `Escape` | Quick switcher open | Close quick switcher |
| `Escape` | Modal open | Close modal, live_patch back |
| `Escape` | Thread panel open | Close thread panel, live_patch back |
| `Escape` | Message edit mode | Cancel edit, restore original content |
| `Escape` | Profile popover open | Close popover |
| `Escape` | Emoji picker open | Close emoji picker |
| `Enter` | Compose textarea focused | Send message |
| `Shift+Enter` | Compose textarea focused | Insert newline |
| `Enter` | Thread reply textarea focused | Send reply |
| `Shift+Enter` | Thread reply textarea focused | Insert newline |
| `Enter` | Message edit textarea | Save edit |
| `↑` arrow | Compose empty, cursor at start | Edit last own message |
| `↓` / `↑` | Quick switcher results | Navigate results list |
| `Enter` | Quick switcher result highlighted | Navigate to selected |
| `Tab` | Modal open | Cycle through focusable elements (trapped) |
| `Shift+Tab` | Modal open | Cycle focus backward (trapped) |
| `Tab` | Sidebar | Navigate between channel/DM items |
| `Enter` | Sidebar item focused | Navigate to that channel/DM |

---

### 5.2 Focus Management

Focus management is critical for keyboard users and screen reader users. Define the expected focus behavior for every state change:

| Trigger | Focus moves to... | Focus returns to... |
|---|---|---|
| Enter channel (click sidebar) | Compose textarea | — |
| Open Create Channel modal | First form field (name) | Sidebar "+" button that opened it |
| Open Browse Channels modal | Search input | Sidebar "Browse" link |
| Open New DM modal | User search input | Sidebar "+" button |
| Open Edit Profile modal | Display name field | Sidebar edit profile button |
| Open Members modal | Search input (or first member if no search) | Channel header members count |
| Open Pins modal | First pinned message (or empty state) | Channel header pin count |
| Open Invite Links modal | "Generate Link" form or existing link | Channel header (if triggered from there) |
| Open thread panel | Thread reply compose textarea | Message "Reply" button |
| Close any modal | Trigger element that opened the modal | — |
| Close thread panel | Main compose textarea | — |
| Open quick switcher | Search input | Element that had focus before Ctrl+K |
| Close quick switcher (Escape) | Element that had focus before Ctrl+K | — |
| Open emoji picker | Emoji picker search/grid | Emoji trigger button |
| Close emoji picker | Emoji trigger button | — |
| Enter message edit mode | Edit textarea (end of content) | Message content area |
| Cancel/save edit | Next focusable element or compose | — |

**Focus trap in modals:** When a modal is open, `Tab` must cycle only through focusable elements within the modal dialog. Focus must not reach elements behind the modal overlay. Implement using a focus-trap utility or the `inert` HTML attribute on the backdrop content.

**Auto-focus on channel enter:** When navigating to a new channel via the sidebar, the compose textarea receives focus automatically. This allows users to begin typing immediately.

---

### 5.3 Screen Reader Considerations

| Element | ARIA Implementation |
|---|---|
| Sidebar | `<nav aria-label="Channels and direct messages">` |
| Channel list | `<ul role="list">` with `<li>` items |
| Active channel | `aria-current="page"` on active sidebar item |
| Unread badge | `<span aria-label="3 unread messages">3</span>` |
| Message list | `<main aria-label="Messages in #general">` |
| New message (real-time) | `<div aria-live="polite" aria-atomic="false">` wrapper — announces new messages to screen readers |
| Typing indicator | `<div aria-live="polite">` — "Alice is typing..." |
| Modal | `role="dialog"` `aria-modal="true"` `aria-labelledby="modal-title"` |
| Modal title | `id="modal-title"` matching `aria-labelledby` |
| Thread panel | `<aside aria-label="Thread">` |
| Message hover actions | `aria-label` on each icon button: "Edit message", "Delete message", "Add reaction", "Reply in thread", "Pin message" |
| Reaction pills | `<button aria-label="👍 thumbs up, 3 reactions. Press to toggle">` |
| Emoji picker | Standard emoji-mart ARIA (built in) |
| Deleted message | `<p aria-label="Deleted message">[This message was deleted]</p>` |
| Connection status banner | `role="status"` `aria-live="assertive"` for critical connection alerts |
| Online indicator | `<span class="sr-only">Online</span>` visually hidden text inside avatar component |

**Announcement strategy for new messages:**
- Use `aria-live="polite"` so new messages are announced after current speech completes
- Announce only the message count delta, not full content, to avoid verbosity: "1 new message in #general"
- When the user is focused on the message list, announce message content via a separate live region

---

## 6. Responsive Breakpoints

### 6.1 Breakpoint Definitions

| Breakpoint | CSS | Range |
|---|---|---|
| **Mobile** | default (no prefix) | < 768px |
| **Tablet** | `md:` | 768px – 1024px |
| **Desktop** | `lg:` | > 1024px |

These align with Tailwind's default `md` and `lg` breakpoints. The app uses `md:` as the primary split point between mobile and desktop layout modes.

---

### 6.2 Sidebar Behavior

| Breakpoint | Behavior | Width | Trigger |
|---|---|---|---|
| Mobile | Hidden by default; slides in as overlay (`fixed inset-y-0 left-0 z-40`) with `transform transition-transform duration-200` | 288px | Hamburger button |
| Mobile (open) | Covers left portion of screen; backdrop (`fixed inset-0 z-30 bg-black/50`) dismisses on tap | 288px | Tap backdrop or select item |
| Tablet | Static, always visible | 256px (`w-64`) | N/A |
| Desktop | Static, always visible | 256px (`w-64`) | N/A |

**Hamburger button:** Visible only on mobile (`md:hidden`). Located in sidebar header (top-right) and optionally in main content header when sidebar is closed.

---

### 6.3 Thread Panel Behavior

| Breakpoint | Behavior | Width |
|---|---|---|
| Mobile | Full-width overlay over message list; shows back button in panel header (not ✕ close) | 100% |
| Tablet | Shares space with message list; message list narrows | 320px |
| Desktop | Shares space with message list; message list narrows | 400px |

**Mobile thread back button:** Label "← Back to #channel-name" — clearer than ✕ close which implies dismissal rather than navigation.

**On mobile:** Thread panel and message list cannot both be visible simultaneously. Opening a thread replaces the message list view.

---

### 6.4 Modal Sizing

| Breakpoint | Width | Height |
|---|---|---|
| Mobile | Full-screen (`w-full h-full rounded-none`) | Full screen |
| Tablet | Fixed max-width (`max-w-lg`) centered | Auto (max 90vh) |
| Desktop | Fixed max-width (`max-w-xl`) centered | Auto (max 80vh) |

**Mobile modals** cover the full screen, making them easier to interact with on touch devices. They should animate in from the bottom (`translate-y` slide) rather than fading in center.

---

### 6.5 Header Layout

| Breakpoint | Channel Header |
|---|---|
| Mobile | [≡ Hamburger] [# channel-name] [info icon → overflow menu] |
| Tablet | [# channel-name] [description] [👥 N] [📌 N] [Join/Leave] |
| Desktop | [# channel-name] [description] [👥 N members] [📌 N pins] [Join Channel] / [Leave Channel] |

On mobile, member count, pin count, and join/leave are moved to an overflow menu (accessible via an info icon in the header) to prevent crowding the narrow header.

---

### 6.6 Compose Area

| Breakpoint | Behavior |
|---|---|
| Mobile | Full-width textarea; soft keyboard pushes compose up (ensure `position: sticky; bottom: 0` works with virtual keyboard) |
| Tablet | Full-width textarea with send button on right |
| Desktop | Full-width textarea with send button on right, auto-resizes up to 200px |

**Mobile virtual keyboard:** Set `min-height` on the message list container and use `env(safe-area-inset-bottom)` for iOS bottom-safe-area compliance.

---

### 6.7 Touch-Specific Interactions

| Interaction | Implementation |
|---|---|
| **Swipe right to open sidebar** | JS touch event listener on main content area: `touchstart` + `touchend` with delta-X threshold (e.g., 50px) |
| **Swipe left to close sidebar** | JS touch event listener on sidebar: swipe-left closes |
| **Long-press for message context menu** | `touchstart` + 500ms timeout → show context menu (same actions as hover: edit, delete, react, reply, pin). Cancel on `touchmove`. |
| **Pull-to-refresh message list** | Not recommended (infinite scroll covers this case). If implemented, must not conflict with scroll-to-load-older. |
| **Tap outside modal** | Closes modal (same as backdrop click on desktop) |
| **Tap outside popover** | Closes profile popover |

**Long-press context menu** replaces hover actions (which don't work on touch). It should show the same actions as the hover toolbar: Edit (if own message), Delete (if own or admin), React, Reply, Pin (if admin).

---

## 7. Content and Naming Guide

### 7.1 Core Terminology

These terms must be used consistently across all UI surfaces: buttons, labels, placeholders, error messages, tooltips, and in-app copy.

| Use This | Not This | Why |
|---|---|---|
| **channel** | room, space, group | Industry standard for this product type |
| **message** | post, update, comment | Conversational — matches the compose action |
| **thread** | conversation, discussion | Matches the panel label |
| **reply** | response, comment | Matches the action button |
| **reaction** | emoji, like | Precise to the feature |
| **direct message** / **DM** | private message, chat, IM | Standard industry term |
| **member** | participant, user (in channel context) | Matches role model |
| **workspace** | team, organization | Top-level container name |
| **invite link** | invitation, join link, referral | Precise to the feature |
| **online** | active, available, green | Presence state term |
| **pin** / **pinned message** | bookmark, save, highlight | Matches action and panel label |

---

### 7.2 Button Labels

Buttons use imperative verb phrases. Never use vague labels like "Submit", "OK", "Done", or "Confirm" without context.

| Context | Primary Action Button | Secondary Button |
|---|---|---|
| Create Channel form | **Create Channel** | Cancel |
| Browse Channels list | **Join** | — (inline, no modal footer) |
| New DM search results | **Open** | — (inline) |
| Edit Profile form | **Save Changes** | Cancel |
| Message delete confirmation | **Delete Message** | Cancel |
| Message edit mode | **Save** | Cancel |
| Invite Link generation | **Generate Link** | — |
| Invite Link copy | **Copy Link** → **Copied!** (2s) | — |
| Invite Link revoke | **Revoke** | — |
| Member role change | **Save** | — (dropdown auto-applies) |
| Kick member | **Remove from Channel** | Cancel |
| Pin message | **Pin** | — (inline) |
| Unpin message | **Unpin** | — (inline) |
| Leave channel confirmation | **Leave Channel** | Cancel |
| Send message | **Send** | — |
| Send reply | **Send** | — |

---

### 7.3 Section and Panel Titles

| UI Element | Label |
|---|---|
| Sidebar section: channels | **Channels** |
| Sidebar section: DMs | **Direct Messages** |
| Thread panel header | **Thread** |
| Pinned messages modal title | **Pinned Messages** |
| Channel members modal title | **Members** |
| Invite links modal title | **Invite Links** |
| Create channel modal title | **Create a Channel** |
| Browse channels modal title | **Browse Channels** |
| New DM modal title | **New Message** |
| Edit profile modal title | **Edit Profile** |
| Quick switcher dialog | _(no title — search input is self-labeling)_ |
| Channel header: member count | **N members** |
| Channel header: pin count | **N pinned** |

---

### 7.4 Placeholder Text

Placeholder text sets expectations for the input — it disappears when the user types. Use concrete examples rather than instructions.

| Input | Placeholder |
|---|---|
| Channel compose (channel) | `Message #channel-name` (dynamic) |
| DM compose | `Message @display-name` (dynamic) |
| Thread reply compose | `Reply...` |
| Message edit textarea | _(no placeholder — pre-filled with current content)_ |
| Create channel: name | `e.g. team-updates` |
| Create channel: description | `What's this channel about?` |
| Browse channels: search | `Search channels...` |
| New DM: user search | `Search users...` |
| Members modal: search | `Search members...` |
| Edit profile: display name | `Display name` |
| Edit profile: status | `What are you up to?` |
| Quick switcher search | `Jump to a channel or DM...` |

---

### 7.5 Error Messages

Error messages must be friendly and actionable — tell the user what happened and what they can do about it.

| Situation | Error Message |
|---|---|
| Invite expired | "This invite link has expired. Ask the channel owner for a new one." |
| Invite max uses reached | "This invite link has reached its limit. Ask the channel owner for a new one." |
| Invite not found (invalid code) | "This invite link is not valid. It may have been revoked." |
| DM blocked by recipient | "You can't send messages to this person." |
| Cannot join private channel without invite | "This channel is private. You need an invite link to join." |
| Channel name taken | "A channel named #that-name already exists. Choose a different name." |
| Channel name invalid format | "Channel names can only contain lowercase letters, numbers, and hyphens." |
| Channel name too short | "Channel name must be at least 3 characters." |
| Profile display name too long | "Display name must be 100 characters or fewer." |
| Cannot kick yourself | "You can't remove yourself from a channel. Use Leave Channel instead." |
| Cannot change own role | "You can't change your own role. Ask another admin to make this change." |
| Message too long | "Messages can't be longer than 4,000 characters." |
| Message send failed | "Your message couldn't be sent. Please try again." |
| Not a participant of DM | "That conversation wasn't found." |
| Session expired | "You've been signed out. Please sign in again." |

---

### 7.6 Empty State Copy

Every collection that can be empty must have a meaningful empty state. Do not show a blank space.

| Empty Context | Heading | Supporting Text | Call to Action |
|---|---|---|---|
| Welcome state (no channel) | "Welcome to Slackex" | "Select a channel to start chatting, or discover what's available." | [Browse Channels] [Create Channel] |
| Empty channel (no messages) | "Start the conversation" | "You're the first one here. Say something!" | _(focus is on compose)_ |
| Empty DM (no messages) | "Start a conversation with @name" | "This is the beginning of your direct message history." | _(focus is on compose)_ |
| Empty thread (no replies) | "No replies yet" | "Be the first to reply." | _(focus is on thread compose)_ |
| Browse channels: no results | "No channels found" | "Try a different search term." | _(clear search)_ |
| Members modal: no results | "No members found" | "Try a different search term." | _(clear search)_ |
| Pinned messages: none | "No pinned messages" | "Admins can pin important messages by hovering over them." | _(no CTA)_ |
| Invite links: none | "No invite links" | "Generate a link to share with people you want to invite." | [Generate Link] |
| Direct messages section: none | _(no heading)_ | _(show section label with + only)_ | Click [+] to start a DM |
| Quick switcher: no results | "No matches" | "Try searching for a different channel or person." | _(clear input or Escape)_ |

---

### 7.7 Naming Conventions for Channel Names

Rules enforced in the UI during channel creation and communicated to users:

- **Lowercase only** — auto-formatted as user types
- **Letters, numbers, and hyphens only** — spaces converted to hyphens, special characters stripped
- **3–50 characters** — validated with live feedback
- **No leading or trailing hyphens** — stripped automatically

Example transformations shown to user as they type:

| User types | Field shows | Validation |
|---|---|---|
| "Team Updates" | `team-updates` | ✓ Valid |
| "Q&A Forum" | `qa-forum` | ✓ Valid |
| "ab" | `ab` | ✗ "At least 3 characters" |
| "#general" | `general` | ✓ (# stripped) |

---

### 7.8 Status and System Messages (In-Channel)

System-generated messages that appear in the channel message list (rendered differently from user messages — no avatar, italic style):

| Event | In-channel message |
|---|---|
| User joined channel | _Alice joined the channel._ |
| User left channel | _Bob left the channel._ |
| User was removed | _Charlie was removed from the channel._ |
| Channel description changed | _Alice updated the channel description._ |
| Message pinned | _Alice pinned a message._ |

---

*End of Information Architecture Document*

*Boundaries of this document: This IA covers structure, naming, navigation, and findability. It does not cover visual design (colors, typography, icons — see designer), user research validation (testing with real users — see ux-researcher), or technical implementation details (component APIs, state management — see architect).*
