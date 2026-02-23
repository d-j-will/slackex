# Slackex Component System & Visual Language
## Phase 5 Design Specification

**Date:** 2026-02-23
**Stack:** Phoenix LiveView + daisyUI v5 + Tailwind CSS v4

---

## Design Principles

1. **Semantic over decorative.** Every visual element serves a functional purpose. No shadows, gradients, or colors as ornamentation.
2. **Tokens over raw values.** All colors, radii, and spacing reference daisyUI CSS custom properties. No hardcoded hex/rgb values in templates.
3. **State is the design.** Each interactive element has exactly four states defined: default, hover, active/selected, disabled. Loading is a variant of active.
4. **Consistency at the component boundary.** Shared anatomy means shared mental model — modals all look the same, sidebar items all behave the same.

---

## 1. Design Tokens

### Spacing Scale

Slackex uses Tailwind's default spacing scale. The following sizes are **canonical** for the chat UI — use these and avoid arbitrary values:

| Token | Value | Use |
|-------|-------|-----|
| `0.5` | 2px | Icon-to-text gap in compact elements |
| `1` | 4px | Between grouped messages (same sender) |
| `1.5` | 6px | Gap within action button groups |
| `2` | 8px | Sidebar item padding (horizontal), badge padding |
| `2.5` | 10px | Sidebar item padding (vertical, mobile) |
| `3` | 12px | Between message groups (different sender) |
| `4` | 16px | Message list horizontal padding, modal section padding |
| `6` | 24px | Modal horizontal padding |
| `8` | 32px | Empty state icon size |
| `10` | 40px | Avatar column width (message list alignment) |
| `14` | 56px | Channel header height, sidebar workspace header height |
| `16` | 64px | Sidebar user footer height |
| `64` | 256px | Sidebar width (desktop) |

### Border Radius

Single consistent value across all UI chrome:

```
Interactive items (buttons, inputs, pills):   rounded     (4px)
Containers (cards, modals, panels):           rounded-lg  (8px)
Avatars, badges, online dots:                 rounded-full
Tooltips, dropdowns:                          rounded-md  (6px)
```

Never use `rounded-xl` or larger on UI chrome. Reserve `rounded-2xl` for illustration/marketing only.

### Typography Scale

```
Workspace name (sidebar header):  text-sm font-semibold tracking-tight
Section headers (CHANNELS, DMS):  text-[11px] font-bold tracking-widest uppercase opacity-45
Channel/DM names (sidebar):       text-sm
Message sender name:              text-sm font-semibold
Message content:                  text-sm leading-relaxed
Timestamp / metadata:             text-xs font-mono tabular-nums opacity-40
Badge/count:                      text-xs font-medium
Modal title:                      text-base font-semibold
Modal body:                       text-sm
Form labels:                      text-xs font-medium opacity-60 uppercase tracking-wide
Input text:                       text-sm
Button text:                      text-sm font-medium
```

### Color Token Map

All colors reference daisyUI CSS variables set in `app.css`. Never use raw color values.

```
Background regions:
  bg-base-100     — main content (message area, modal bodies)
  bg-base-200     — sidebar, secondary surfaces
  bg-base-300     — hover state backgrounds, dividers

Text hierarchy:
  text-base-content           — primary text (100%)
  text-base-content/60        — secondary (metadata, descriptions)
  text-base-content/40        — tertiary (timestamps, muted)
  text-base-content/25        — disabled / placeholder

Borders:
  border-base-300             — all dividers and chrome borders
  focus-within:border-primary/50 — focused input containers

Interactive states:
  text-primary                — active channel name, links
  bg-primary                  — unread badges, primary buttons
  bg-primary/20               — own reaction pill background
  border-primary/40           — own reaction pill border

Status:
  bg-success                  — online indicator
  bg-error / text-error       — destructive actions, error states
  bg-warning                  — warning states
```

---

## 2. Component Inventory

All Phase 5 components, organized by file location.

### `lib/slackex_web/components/chat_components.ex`

| Component | Props | Description |
|-----------|-------|-------------|
| `avatar/1` | `user`, `size`, `online` | Circular avatar with initials fallback + optional online dot |
| `channel_list_item/1` | `channel`, `active`, `unread_count` | Sidebar channel nav item |
| `dm_list_item/1` | `dm`, `active`, `online`, `unread_count` | Sidebar DM nav item with avatar |
| `message_bubble/1` | `message`, `current_user_id`, `is_grouped`, `online_user_ids` | Full message row |
| `message_action_bar/1` | `message`, `current_user_id` | Hover-revealed action buttons |
| `reaction_bar/1` | `reactions`, `current_user_id`, `message_id` | Emoji reaction pills row |
| `typing_indicator/1` | `users` | Animated typing dots + names |
| `date_separator/1` | `date` | Horizontal rule with date label |
| `system_message/1` | `text` | Join/leave/topic system events |
| `empty_state/1` | `icon`, `title`, `subtitle` | Empty collection placeholder |
| `unread_badge/1` | `count` | Numeric unread count pill |
| `message_skeleton/1` | `count` | Pulsing placeholder while loading |
| `online_dot/1` | `online`, `size` | Online status indicator dot |

### LiveComponents (separate files)

| Module | File | Role |
|--------|------|------|
| `SidebarComponent` | `sidebar_component.ex` | Full sidebar including workspace header, nav sections, user footer |
| `ThreadPanelComponent` | `thread_panel_component.ex` | Sliding right panel for thread replies |
| `NewDmModal` | `new_dm_modal.ex` | User search + DM start modal |
| `CreateChannelModal` | `create_channel_modal.ex` | Channel creation form modal |
| `BrowseChannelsModal` | `browse_channels_modal.ex` | Public channel discovery modal |
| `EditProfileModal` | `edit_profile_modal.ex` | Profile edit form modal |
| `ChannelMembersModal` | `channel_members_modal.ex` | Member list + management modal |
| `PinnedMessagesModal` | `pinned_messages_modal.ex` | Pinned message list modal |
| `InviteLinkModal` | `invite_link_modal.ex` | Invite link generation + management modal |

---

## 3. Component Specifications

### 3.1 `avatar/1`

**Purpose:** Renders a circular user avatar — image if `avatar_url` present, otherwise initials. Optional online status dot.

**Sizes:**

```
sm:   w-6 h-6   (24px) — sidebar DM items, reaction tooltips
md:   w-8 h-8   (32px) — message list default
lg:   w-12 h-12 (48px) — profile popover, edit profile modal
```

**Initials fallback:** Take first character of `display_name || username`, uppercase. Background color derived from a hash of the user ID (cycle through 6 preset muted colors to ensure visual distinction without relying on random assignment).

**Preset initials colors (using daisyUI semantic where possible):**
```
Index 0: bg-blue-500/20 text-blue-600
Index 1: bg-green-500/20 text-green-600
Index 2: bg-amber-500/20 text-amber-600
Index 3: bg-rose-500/20 text-rose-600
Index 4: bg-violet-500/20 text-violet-600
Index 5: bg-teal-500/20 text-teal-600
```

These opacity-based colors work in both light and dark mode without theme-specific overrides.

**Online dot positioning:**
```
Size sm:   w-2 h-2, ring-1
Size md:   w-2.5 h-2.5, ring-2
Size lg:   w-3 h-3, ring-2
Position:  absolute bottom-0 right-0
Ring:      ring-base-200 (matches sidebar/context background)
```

**Template skeleton:**
```heex
def avatar(assigns) do
  ~H"""
  <div class={["relative inline-block shrink-0", avatar_size(@size)]}>
    <%= if @user.avatar_url do %>
      <img src={@user.avatar_url}
           alt={avatar_alt(@user)}
           class={["rounded-full object-cover w-full h-full", avatar_size(@size)]} />
    <% else %>
      <div class={[
        "rounded-full flex items-center justify-center font-semibold",
        avatar_size(@size),
        initials_color(@user.id)
      ]}>
        <span class={avatar_text_size(@size)}>{initials(@user)}</span>
      </div>
    <% end %>
    <.online_dot :if={@online} size={@size} />
  </div>
  """
end
```

---

### 3.2 `channel_list_item/1`

**States:**

| State | Classes |
|-------|---------|
| Default | `text-base-content/70 hover:bg-base-300/50 hover:text-base-content` |
| Active | `bg-base-300 text-base-content font-medium` |
| Unread (not active) | `text-base-content font-semibold` |
| Hover (active) | No change — already selected |

**Layout:**
```
flex items-center justify-between gap-2
px-2 py-1 rounded
text-sm transition-colors duration-100
cursor-pointer
```

**Inner structure:**
```
Left:  [#-symbol opacity-40] [channel name — truncate]
Right: [unread_badge if count > 0 and not active]
```

**The `#` prefix:**
```heex
<span class="shrink-0 text-base-content/40 text-[13px]">#</span>
```

Do not use a separate icon for `#` — the character itself is canonical and lighter than any SVG.

---

### 3.3 `dm_list_item/1`

Same state system as `channel_list_item/1`, but left side replaces `#` with a small `avatar/1` (size `sm`) plus online dot.

**Layout:**
```
flex items-center gap-2 px-2 py-1 rounded
text-sm transition-colors duration-100
cursor-pointer
```

**Inner:**
```
Left:  [avatar sm with online dot] [display_name or username — truncate]
Right: [unread_badge if count > 0 and not active]
```

---

### 3.4 `message_bubble/1`

The most complex component. Full specification:

**Outer wrapper (the hover target):**
```
group relative flex gap-3 px-4
py-0.5 (grouped) or pt-3 pb-0.5 (first in group)
hover:bg-base-200/60 rounded-md
transition-colors duration-75
```

**Avatar column (always 40px wide):**
- First in group: renders `avatar/1` at size `md`
- Grouped: renders hover-revealed timestamp (`text-[10px] font-mono opacity-40`)

**Content column:**
```
flex-1 min-w-0
```

**Header row (first in group only):**
```
flex items-baseline gap-2 mb-0.5
```
- Sender name: `font-semibold text-sm text-base-content`
- Timestamp: `text-xs font-mono tabular-nums text-base-content/40`
- "(edited)" label: `text-xs text-base-content/30` (only if `edited_at`)

**Content text:**
- Normal: `text-sm text-base-content leading-relaxed break-words`
- Deleted: `text-sm text-base-content/40 italic`

**Edit mode (inline textarea):**
```
w-full px-3 py-2 mt-0.5
bg-base-200 border border-base-300
focus:border-primary/50 focus:outline-none
rounded text-sm text-base-content
resize-none
```
Below textarea: Save (`btn btn-primary btn-xs`) + Cancel (`btn btn-ghost btn-xs`) + hint text (`text-xs text-base-content/40 "escape to cancel"`)

**Hover action bar:**
```
absolute right-4 top-1
-translate-y-1/2
opacity-0 group-hover:opacity-100
transition-opacity duration-75
flex items-center gap-0.5
bg-base-100 border border-base-300
rounded-md shadow-sm p-0.5 z-10
```
Buttons inside: `btn btn-ghost btn-xs btn-circle` — 4 actions max (react, reply, edit, delete). Edit only for own messages. Delete for own OR admin+.

---

### 3.5 `reaction_bar/1`

Appears below message content when reactions exist. Also shows a `+` button that triggers the emoji picker.

**Pill — reacted by current user:**
```
px-2 py-0.5 rounded-full text-xs
bg-primary/20 border border-primary/40 text-primary
hover:bg-primary/30 transition-colors duration-100
cursor-pointer
```

**Pill — not reacted:**
```
px-2 py-0.5 rounded-full text-xs
bg-base-300/60 border border-base-300 text-base-content/70
hover:bg-base-300 transition-colors duration-100
cursor-pointer
```

**Add reaction button:**
```
px-1.5 py-0.5 rounded-full text-xs
bg-transparent border border-dashed border-base-300
text-base-content/40 hover:text-base-content/70
hover:border-base-content/30 transition-colors duration-100
```

**Tooltip on hover:** Show list of up to 3 user display names who reacted, plus "and N more" if > 3. Use daisyUI `tooltip` component.

**Layout:** `flex flex-wrap items-center gap-1 mt-1`

---

### 3.6 `typing_indicator/1`

**Positioning:** Lives in the compose area, not the message list. Renders as the top-left content of the compose container's bottom bar.

**Animation:** Three dots that pulse in sequence using CSS animation:

```css
/* In app.css */
@keyframes typing-dot {
  0%, 60%, 100% { opacity: 0.2; transform: translateY(0); }
  30% { opacity: 1; transform: translateY(-2px); }
}

.typing-dot:nth-child(1) { animation: typing-dot 1.2s ease infinite 0s; }
.typing-dot:nth-child(2) { animation: typing-dot 1.2s ease infinite 0.2s; }
.typing-dot:nth-child(3) { animation: typing-dot 1.2s ease infinite 0.4s; }
```

**Template:**
```heex
<div :if={@users != []} class="flex items-center gap-1.5">
  <div class="flex items-end gap-[3px] h-3">
    <span class="typing-dot w-1.5 h-1.5 rounded-full bg-base-content/40" />
    <span class="typing-dot w-1.5 h-1.5 rounded-full bg-base-content/40" />
    <span class="typing-dot w-1.5 h-1.5 rounded-full bg-base-content/40" />
  </div>
  <span class="text-xs text-base-content/40 italic">{typing_text(@users)}</span>
</div>
```

**Text logic:**
- 1 user: `"Alice is typing..."`
- 2 users: `"Alice and Bob are typing..."`
- 3+ users: `"Several people are typing..."`

---

### 3.7 `empty_state/1`

Used for: no channels, no messages, no search results, no DMs, no members found, no pins.

**Layout:**
```
flex flex-col items-center justify-center gap-3
text-center px-8 py-12
```

**Icon container:**
```
w-14 h-14 rounded-xl
bg-base-300/50 flex items-center justify-center
```

**Icon:** `h-7 w-7 text-base-content/30`

**Title:** `font-semibold text-base-content text-sm mt-1`

**Subtitle:** `text-xs text-base-content/50 mt-0.5 max-w-[220px]`

**Optional CTA:** `btn btn-sm btn-ghost mt-3`

---

### 3.8 `unread_badge/1`

```heex
<span class={[
  "badge badge-sm min-w-[18px] px-1",
  "bg-primary text-primary-content border-0 font-semibold"
]}>
  {if @count > 99, do: "99+", else: @count}
</span>
```

Counts 1-9: show number. 10-99: show number. 100+: show "99+". Never show 0 (guard with `:if={@count > 0}`).

---

### 3.9 `message_skeleton/1`

```heex
<div :for={i <- 1..(@count || 5)}
     class="flex gap-3 px-4 animate-pulse"
     style={"padding-top: #{if rem(i, 3) == 0, do: "12px", else: "2px"}"}>
  <div :if={rem(i, 3) == 0} class="w-8 h-8 rounded-full bg-base-300 shrink-0 mt-0.5" />
  <div :if={rem(i, 3) != 0} class="w-8 shrink-0" />
  <div class="flex-1 space-y-1.5">
    <div :if={rem(i, 3) == 0} class="flex items-center gap-2">
      <div class="h-3 bg-base-300 rounded" style={"width: #{60 + rem(i * 13, 60)}px"} />
      <div class="h-2.5 bg-base-300/60 rounded w-8" />
    </div>
    <div class="h-3 bg-base-300 rounded" style={"width: #{40 + rem(i * 17, 55)}%"} />
    <div :if={rem(i, 4) == 0}
         class="h-3 bg-base-300/70 rounded" style={"width: #{25 + rem(i * 11, 30)}%"} />
  </div>
</div>
```

The `rem`-based widths create naturally varied skeleton lines (not identical widths, which looks artificial).

---

## 4. Sidebar Component Structure

### `SidebarComponent` — Full Anatomy

```
┌──────────────────────────────────┐
│ WORKSPACE HEADER (h-14)          │  bg-base-200, border-b border-base-300
│  [workspace name]  [⌄ chevron]   │  cursor-pointer (future: workspace switcher)
├──────────────────────────────────┤
│ SCROLLABLE NAV (flex-1)          │  overflow-y-auto
│                                  │
│  CHANNELS                [+]     │  section header + add button
│   # general                      │  channel_list_item
│   # design               3       │  channel_list_item (unread)
│   # engineering                  │
│  ▸ CHANNELS (collapsed)          │  collapsed state: just header, click to expand
│                                  │
│  DIRECT MESSAGES         [+]     │  section header + add button
│   ● Alice                        │  dm_list_item (online)
│   ○ Bob                  1       │  dm_list_item (unread)
│                                  │
├──────────────────────────────────┤
│ USER FOOTER (h-16)               │  border-t border-base-300
│  [avatar+dot] [Name]  [✏️] [🌙] │
│               [status text]      │
└──────────────────────────────────┘
```

### Section Header Pattern

```heex
<div class="flex items-center justify-between px-2 pt-4 pb-1 group/section">
  <button phx-click="toggle_section" phx-value-section={@section}
          class="flex items-center gap-1 cursor-pointer">
    <.icon name={if @expanded, do: "hero-chevron-down", else: "hero-chevron-right"}
           class="h-3 w-3 text-base-content/40 transition-transform duration-150" />
    <span class="text-[11px] font-bold tracking-widest uppercase text-base-content/45">
      {@label}
    </span>
  </button>
  <button phx-click={@on_add}
          class="opacity-0 group-hover/section:opacity-100
                 btn btn-ghost btn-xs btn-circle transition-opacity duration-100"
          title={@add_title}>
    <.icon name="hero-plus" class="h-3.5 w-3.5 text-base-content/50" />
  </button>
</div>
```

The `+` button is hidden by default and appears on section hover (`group-hover/section`) — matching Linear's pattern of hover-first affordance.

### User Footer Pattern

```heex
<div class="flex items-center gap-2 px-3 h-16 border-t border-base-300 shrink-0">
  <%# Avatar with online dot — click opens edit profile %>
  <button phx-click={JS.patch(~p"/chat/profile/edit")} class="shrink-0">
    <.avatar user={@current_user} size="md" online={true} />
  </button>

  <%# Name + status — truncated %>
  <div class="flex-1 min-w-0">
    <p class="text-sm font-medium text-base-content truncate leading-tight">
      {@current_user.display_name || @current_user.username}
    </p>
    <p :if={@current_user.status} class="text-xs text-base-content/50 truncate leading-tight">
      {@current_user.status}
    </p>
  </div>

  <%# Actions %>
  <div class="flex items-center gap-0.5 shrink-0">
    <.link patch={~p"/chat/profile/edit"}
           class="btn btn-ghost btn-xs btn-circle"
           title="Edit profile">
      <.icon name="hero-pencil-square" class="h-4 w-4 text-base-content/50" />
    </.link>
    <button phx-click={JS.dispatch("toggle-theme")}
            class="btn btn-ghost btn-xs btn-circle"
            title="Toggle theme">
      <.icon name="hero-sun-solid" class="h-4 w-4 text-base-content/50 hidden dark:block" />
      <.icon name="hero-moon-solid" class="h-4 w-4 text-base-content/50 dark:hidden" />
    </button>
  </div>
</div>
```

---

## 5. Modal System

All nine Phase 5 modals use identical structure. Only body content varies.

### Modal Shell (reusable pattern)

```heex
<%# Outer: backdrop + centering %>
<div class="fixed inset-0 z-50 flex items-end sm:items-center justify-center
            bg-base-content/20 backdrop-blur-sm"
     phx-key="escape" phx-window-keydown="close_modal">

  <%# Stop clicks inside modal from closing via backdrop handler %>
  <div class={[
    "w-full sm:max-w-lg",                              # standard modal
    # OR "w-full sm:max-w-2xl"                        # wide modal (browse channels)
    "bg-base-100 sm:rounded-xl",
    "border border-base-300 shadow-xl",
    "flex flex-col",
    "max-h-[92vh] sm:max-h-[85vh]"
  ]}
       phx-click-away="close_modal">

    <%# Header %>
    <div class="flex items-center justify-between px-6 py-4 border-b border-base-300 shrink-0">
      <h2 class="font-semibold text-base text-base-content">{@title}</h2>
      <button phx-click="close_modal"
              class="btn btn-ghost btn-sm btn-circle -mr-1">
        <.icon name="hero-x-mark" class="h-5 w-5" />
      </button>
    </div>

    <%# Scrollable body — each modal fills this region %>
    <div class="flex-1 overflow-y-auto">
      {render_modal_body(assigns)}
    </div>

    <%# Footer (optional — some modals have no footer actions) %>
    <div :if={@show_footer}
         class="flex items-center justify-end gap-2 px-6 py-4 border-t border-base-300 shrink-0">
      <button phx-click="close_modal" class="btn btn-ghost btn-sm">Cancel</button>
      <button type="submit" form={@form_id} class="btn btn-primary btn-sm">
        {@submit_label}
      </button>
    </div>

  </div>
</div>
```

### Modal-Specific Specs

**CreateChannelModal:**
- Body: channel name input (auto-formats to lowercase-hyphen) + description textarea + private toggle
- Name field shows live validation: "Channel names are lowercase, with no spaces or periods." in `text-xs text-base-content/50`
- Footer: Cancel + Create Channel

**BrowseChannelsModal:**
- Width: `sm:max-w-2xl` (wider to show channel cards)
- Body: search input at top (sticky), scrollable channel list
- Channel card: `flex items-center gap-3 px-4 py-3 border-b border-base-300/50`
  - Left: `#` + name (font-medium) + description (text-xs opacity-60)
  - Right: member count (text-xs) + Join button (`btn btn-primary btn-xs`)
- No footer — Join acts inline

**NewDmModal:**
- Body: search input + results list
- Result item: avatar sm + display_name + username in opacity-50 + click-to-select
- Selected state: `bg-primary/10 border-primary/30`

**EditProfileModal:**
- Body: display_name input + status input + avatar_url input (with preview if URL valid)
- Footer: Cancel + Save Changes

**ChannelMembersModal:**
- Body: search input + member list
- Member row: avatar md + name + username + role badge + actions (role dropdown, kick button)
- Role badge: `badge badge-sm` in neutral
- Width: `sm:max-w-xl`

**PinnedMessagesModal:**
- Body: list of pinned messages
- Pin card: message content preview (2 lines max, `line-clamp-2`) + sender + pin date + unpin button
- Width: `sm:max-w-xl`

**InviteLinkModal:**
- Body: existing links list + generate new link form
- Link row: code (font-mono text-sm) + uses/max + expiry + copy button + revoke button
- Copy button uses CopyToClipboard hook, shows "Copied!" for 2s on click

---

## 6. Thread Panel Component

### Layout

```heex
<div class={[
  "flex flex-col bg-base-100",
  "fixed inset-0 z-30",                              # mobile: full screen overlay
  "md:static md:inset-auto md:z-auto",               # desktop: side panel
  "md:w-[400px] md:border-l md:border-base-300",
  "transition-transform duration-200 ease-out",
  if(@thread_open, do: "translate-x-0",
                   else: "translate-x-full md:translate-x-0 md:hidden")
]}>
```

### Internal Structure

```
Thread header (h-14):
  [← back button — mobile only] [Thread] [× close — desktop]
  border-b border-base-300

Parent message (read-only, slightly highlighted):
  mx-4 my-3 p-3 rounded-lg bg-base-200/60
  [full message_bubble in non-interactive mode]
  border border-base-300/50

Divider:
  "N Replies" centered label, same as date_separator/1

Reply list (flex-1 overflow-y-auto):
  Same message_bubble rendering as main list
  No nested thread actions (no reply button on replies)

Compose (same as main compose):
  px-4 pb-4 pt-2
```

### Thread Header

```heex
<div class="flex items-center justify-between h-14 px-4 border-b border-base-300 shrink-0">
  <%# Back button — mobile only %>
  <button class="btn btn-ghost btn-sm btn-circle md:hidden"
          phx-click="close_thread">
    <.icon name="hero-arrow-left" class="h-5 w-5" />
  </button>

  <span class="font-semibold text-sm text-base-content">Thread</span>

  <%# Close button — desktop only %>
  <button class="btn btn-ghost btn-sm btn-circle hidden md:flex"
          phx-click="close_thread">
    <.icon name="hero-x-mark" class="h-5 w-5" />
  </button>
</div>
```

---

## 7. Form Components

### Input Fields

All chat modal inputs follow this pattern:

```heex
<div class="space-y-1">
  <label class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
    {label}
  </label>
  <input type="text"
         class={[
           "input w-full text-sm",
           "bg-base-100 border-base-300",
           "focus:border-primary/50 focus:outline-none",
           "placeholder:text-base-content/30",
           if(has_error, do: "border-error")
         ]} />
  <p :if={error} class="text-xs text-error">{error}</p>
  <p :if={hint} class="text-xs text-base-content/40">{hint}</p>
</div>
```

### Toggle / Switch

For `is_private` channel toggle:

```heex
<label class="flex items-center justify-between gap-3 cursor-pointer">
  <div>
    <p class="text-sm font-medium text-base-content">Private channel</p>
    <p class="text-xs text-base-content/50">Only invited members can join</p>
  </div>
  <input type="checkbox" class="toggle toggle-primary toggle-sm"
         name={f[:is_private].name}
         checked={f[:is_private].value} />
</label>
```

### Search Input (modals + quick switcher)

```heex
<div class="relative">
  <.icon name="hero-magnifying-glass"
         class="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-base-content/40 pointer-events-none" />
  <input type="text"
         class="input w-full pl-9 text-sm bg-base-100 border-base-300
                placeholder:text-base-content/30 focus:border-primary/50 focus:outline-none"
         placeholder="Search..." />
</div>
```

---

## 8. Profile Popover

Appears on click of any username or avatar. Positioned absolutely relative to trigger element.

```heex
<div class={[
  "absolute z-30 w-64 bg-base-100 rounded-lg border border-base-300 shadow-lg",
  "top-full mt-2",                                    # positions below trigger
  popover_horizontal_class(@trigger_position)         # left: or right: to stay in viewport
]}>
  <%# Avatar + name section %>
  <div class="p-4 border-b border-base-300">
    <.avatar user={@user} size="lg" online={@user.id in @online_user_ids} />
    <h3 class="font-semibold text-sm text-base-content mt-3 leading-tight">
      {@user.display_name || @user.username}
    </h3>
    <p :if={@user.display_name}
       class="text-xs text-base-content/50 leading-tight">@{@user.username}</p>
    <p :if={@user.status}
       class="text-xs text-base-content/60 mt-1">{@user.status}</p>
  </div>

  <%# Actions %>
  <div class="p-1">
    <button phx-click="start_dm" phx-value-user-id={@user.id}
            class="flex items-center gap-2 w-full px-3 py-2 text-sm text-base-content
                   rounded hover:bg-base-200 transition-colors duration-75">
      <.icon name="hero-chat-bubble-left" class="h-4 w-4 text-base-content/50" />
      Send a message
    </button>
    <button phx-click="block_user" phx-value-user-id={@user.id}
            class="flex items-center gap-2 w-full px-3 py-2 text-sm text-error
                   rounded hover:bg-error/10 transition-colors duration-75">
      <.icon name="hero-no-symbol" class="h-4 w-4" />
      Block user
    </button>
  </div>
</div>
```

**Dismissal:** Click outside closes via `phx-click-away` on the outer overlay div. Escape key closes via `phx-window-keydown="close_popover"`.

---

## 9. Channel Header

```heex
<div class="flex items-center justify-between h-14 px-4 border-b border-base-300 bg-base-100 shrink-0">

  <%# Left: channel identity %>
  <div class="flex items-center gap-2 min-w-0">
    <span class="text-base-content/50 font-medium shrink-0">#</span>
    <h2 class="font-semibold text-sm text-base-content truncate">
      {@active_channel.name}
    </h2>
    <span :if={@active_channel.description}
          class="hidden lg:block text-xs text-base-content/50 truncate border-l border-base-300 pl-3">
      {@active_channel.description}
    </span>
  </div>

  <%# Right: actions %>
  <div class="flex items-center gap-0.5 shrink-0">
    <%# Member count %>
    <.link patch={~p"/chat/#{@active_channel.slug}/members"}
           class="btn btn-ghost btn-xs gap-1.5 text-base-content/60 hover:text-base-content">
      <.icon name="hero-users" class="h-4 w-4" />
      <span class="hidden sm:inline text-xs">{@member_count}</span>
    </.link>

    <%# Pinned messages %>
    <.link patch={~p"/chat/#{@active_channel.slug}/pins"}
           class="btn btn-ghost btn-xs gap-1.5 text-base-content/60 hover:text-base-content">
      <.icon name="hero-map-pin" class="h-4 w-4" />
      <span :if={@pin_count > 0} class="hidden sm:inline text-xs">{@pin_count}</span>
    </.link>

    <%# Invite (admin+ only) %>
    <.link :if={@can_manage}
           patch={~p"/chat/#{@active_channel.slug}/invites"}
           class="btn btn-ghost btn-xs gap-1.5 text-base-content/60 hover:text-base-content">
      <.icon name="hero-user-plus" class="h-4 w-4" />
    </.link>

    <%# Join / Leave %>
    <button :if={@can_join}
            phx-click="join_channel"
            class="btn btn-primary btn-xs">
      Join Channel
    </button>
    <button :if={@can_leave}
            phx-click="leave_channel"
            class="btn btn-ghost btn-xs text-base-content/60">
      Leave
    </button>
  </div>
</div>
```

---

## 10. Accessibility Requirements

### ARIA Attributes

Every interactive element needs an accessible label if it has no visible text:

```heex
<%# Icon-only buttons MUST have title or aria-label %>
<button class="btn btn-ghost btn-xs btn-circle"
        aria-label="React to message"
        title="Add reaction">
  <.icon name="hero-face-smile" class="h-4 w-4" />
</button>

<%# Modals need role and aria-modal %>
<div role="dialog" aria-modal="true" aria-labelledby="modal-title">

<%# Navigation landmark for sidebar %>
<nav aria-label="Channels and conversations">
```

### Focus Management

- **Modal open:** Focus moves to first focusable element inside modal (typically the first input, or the close button if no input)
- **Modal close:** Focus returns to the element that triggered the modal open
- **Thread panel open:** Focus moves to the thread reply compose textarea
- **Quick switcher:** Focus on search input immediately

LiveView's `JS.focus/1` and `JS.focus_first/1` handle this:
```heex
<button phx-click={JS.patch(path) |> JS.focus_first(to: "#modal-body")}>
```

### Keyboard Navigation

- All interactive elements reachable via `Tab`
- `Escape` closes any open overlay (modal, popover, thread panel, quick switcher)
- `Enter` on focused channel/DM item navigates to it
- Sidebar channel list uses `role="listbox"` with `aria-selected` on active item

### Color Contrast

The daisyUI OKLCH token values are pre-calibrated for WCAG AA contrast. Verify these specific cases:
- `text-base-content/40` on `bg-base-100`: ~4.5:1 in both themes (timestamps, metadata)
- `text-base-content/25`: Only use for purely decorative text, not information-bearing
- `text-primary` on `bg-base-100`: Orange (light) and purple (dark) — confirm contrast with browser DevTools
- Reaction pills: `text-primary` on `bg-primary/20` — may need darkening in light mode

---

## 11. Animation Inventory

All animations used in Phase 5, with consistent values:

| Animation | Duration | Easing | Trigger |
|-----------|----------|--------|---------|
| Sidebar slide (mobile) | 200ms | `ease-out` | Hamburger click |
| Thread panel slide | 200ms | `ease-out` | Reply click / URL change |
| Modal appear (opacity) | 150ms | `ease-out` | Route change / button click |
| Modal scale (0.97→1.0) | 150ms | `ease-out` | Same as above |
| Hover background | 100ms | linear | Mouse enter element |
| Message action bar | 75ms | linear | Mouse enter message row |
| Section collapse | 200ms | `ease-out` | Section header click |
| Typing dots | 1200ms | ease | Infinite loop |
| Skeleton pulse | 2000ms | ease-in-out | While loading |
| Unread badge appear | 300ms | `ease-out` | New message received |
| Toast/flash appear | 150ms | `ease-out` | Flash message pushed |

**CSS transition shorthand for Tailwind:**
```
Hover backgrounds:    transition-colors duration-100
Opacity reveals:      transition-opacity duration-75
Transforms (panels):  transition-transform duration-200 ease-out
Mixed (size+opacity): transition-[transform,opacity] duration-150 ease-out
```

---

## 12. Implementation Notes for LiveView

### Grouping Without Context

Phoenix LiveView streams render each item independently. For message grouping, pass a precomputed `grouped` boolean from the parent:

```elixir
# In Index, before streaming:
messages_with_grouping =
  messages
  |> Enum.with_index()
  |> Enum.map(fn {msg, i} ->
    prev = Enum.at(messages, i - 1)
    grouped = prev &&
              prev.sender_id == msg.sender_id &&
              DateTime.diff(msg.inserted_at, prev.inserted_at, :second) < 300
    Map.put(msg, :grouped, grouped)
  end)
```

New messages appended via `stream_insert` should check against the current last message. Store `@last_message` in assigns for this comparison.

### JS.toggle for Collapsible Sections

```heex
<button phx-click={JS.toggle(to: "#channels-list", in: "opacity-100", out: "opacity-0")}>
```

For simple show/hide without server round-trip, use `JS` commands. Server state (`sidebar_sections_open`) only needed if the state should persist across page reloads.

### Popover Positioning

Profile popovers need viewport-aware positioning. Simple heuristic: if the trigger element is in the right half of the viewport, position the popover to the left; otherwise to the right. Detect via JS:

```javascript
// In a Popover hook
mounted() {
  const rect = this.el.getBoundingClientRect();
  const isRightHalf = rect.left > window.innerWidth / 2;
  this.el.querySelector("[data-popover]").classList.toggle("right-0", isRightHalf);
  this.el.querySelector("[data-popover]").classList.toggle("left-0", !isRightHalf);
}
```

---

*This document provides the complete component specification for Phase 5 implementation. All components should be implemented in the order listed in Section 2, starting with the foundation components (`avatar`, `unread_badge`, `online_dot`) before assembling composite components (`channel_list_item`, `message_bubble`).*
