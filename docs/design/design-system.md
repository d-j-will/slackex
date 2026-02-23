# Slackex Design System

**Version:** 1.0
**Stack:** Phoenix LiveView · daisyUI v5 · Tailwind CSS v4 · Heroicons
**Design Direction:** Modern minimal — precision-first, Linear/Notion-inspired

---

## 0. Design Rationale

### Aesthetic Direction: "Slate"

Slackex targets productivity-focused users. The interface should recede when not needed and surface exactly when it is. The design system is built around three convictions:

1. **Information density over decoration.** Every pixel either carries information or creates breathing room between information. No decorative gradients, no illustrative background patterns.
2. **Subdued palette with a single sharp accent.** Most surfaces are cool grays. Indigo (`oklch ~52%`) is the one saturated hue — used only for primary actions and active states. Amber provides a warm counterpoint for badges and highlights.
3. **Motion that signals, not entertains.** Transitions exist to give the user spatial orientation (panels slide, modals fade). Individual elements do not bounce or spin.

**The one memorable thing:** The message hover state — a floating action bar that materialises above the message row with 120ms ease-out, giving the interface a sense of immediate response without visual noise at rest.

---

## 1. Color Palette

### 1.1 Philosophy

- **Surfaces** use near-neutral OKLCH values with a slight cool chroma (~264° hue). This gives backgrounds a clean, intentional look without being sterile.
- **Primary** is indigo: professional, focused, not violet-flashy.
- **Accent** is warm amber: used for unread indicators, warnings, and callouts. It contrasts sharply against the cool base.
- **Success** is sage green. **Error** is muted coral.
- Saturation is deliberately kept low on surfaces (chroma < 0.01) and moderate on interactive elements (chroma 0.17–0.22).

### 1.2 Light Theme — "Slate Light"

| Token | OKLCH Value | Usage |
|-------|-------------|-------|
| `base-100` | `oklch(99% 0.002 264)` | Main content background |
| `base-200` | `oklch(95.5% 0.004 264)` | Sidebar, modals, secondary panels |
| `base-300` | `oklch(90% 0.006 264)` | Borders, dividers, input backgrounds |
| `base-content` | `oklch(14% 0.008 264)` | Primary text (near-black, cool) |
| `primary` | `oklch(52% 0.22 264)` | Brand indigo — active states, primary btns |
| `primary-content` | `oklch(98% 0.005 264)` | Text on primary bg |
| `secondary` | `oklch(62% 0.04 264)` | Secondary labels, muted UI text |
| `secondary-content` | `oklch(98% 0 0)` | Text on secondary bg |
| `accent` | `oklch(68% 0.17 70)` | Unread badges, highlights, amber warm |
| `accent-content` | `oklch(15% 0.04 70)` | Text on accent bg |
| `neutral` | `oklch(40% 0.01 264)` | Ghost buttons, neutral surfaces |
| `neutral-content` | `oklch(97% 0.002 264)` | Text on neutral bg |
| `info` | `oklch(58% 0.16 238)` | Info banners |
| `info-content` | `oklch(97% 0.012 238)` | Text on info bg |
| `success` | `oklch(62% 0.13 165)` | Online indicator, success states |
| `success-content` | `oklch(97% 0.012 165)` | Text on success bg |
| `warning` | `oklch(66% 0.17 58)` | Warnings |
| `warning-content` | `oklch(15% 0.04 58)` | Text on warning bg |
| `error` | `oklch(58% 0.22 17)` | Errors, destructive actions |
| `error-content` | `oklch(97% 0.012 17)` | Text on error bg |

**Semantic aliases (document in code comments):**
```
online-dot    → success color
unread-badge  → accent color
active-nav    → primary / 10% opacity bg
hover-row     → base-300 / 60% opacity
message-hover-actions-bg → base-200 with border base-300
```

### 1.3 Dark Theme — "Slate Dark"

| Token | OKLCH Value | Usage |
|-------|-------------|-------|
| `base-100` | `oklch(17% 0.008 264)` | Main content background |
| `base-200` | `oklch(13.5% 0.007 264)` | Sidebar, secondary panels |
| `base-300` | `oklch(21% 0.010 264)` | Borders, dividers |
| `base-content` | `oklch(93% 0.008 264)` | Primary text |
| `primary` | `oklch(63% 0.20 264)` | Brand indigo (brighter for dark bg) |
| `primary-content` | `oklch(98% 0.005 264)` | Text on primary bg |
| `secondary` | `oklch(55% 0.04 264)` | Secondary labels |
| `secondary-content` | `oklch(95% 0.003 264)` | Text on secondary bg |
| `accent` | `oklch(72% 0.15 70)` | Unread badges, amber warm |
| `accent-content` | `oklch(12% 0.04 70)` | Text on accent bg |
| `neutral` | `oklch(30% 0.010 264)` | Ghost buttons, hover surfaces |
| `neutral-content` | `oklch(90% 0.006 264)` | Text on neutral bg |
| `info` | `oklch(62% 0.15 238)` | Info states |
| `info-content` | `oklch(14% 0.03 238)` | Text on info bg |
| `success` | `oklch(60% 0.14 165)` | Online indicator |
| `success-content` | `oklch(14% 0.03 165)` | Text on success bg |
| `warning` | `oklch(68% 0.16 58)` | Warnings |
| `warning-content` | `oklch(15% 0.04 58)` | Text on warning bg |
| `error` | `oklch(62% 0.20 17)` | Errors |
| `error-content` | `oklch(14% 0.03 17)` | Text on error bg |

---

## 2. Typography Scale

### 2.1 Font Stack

```css
/* UI Chrome — headings, labels, nav, buttons */
font-family: "Geist", "DM Sans", ui-sans-serif, system-ui, -apple-system, sans-serif;

/* Body / Message Content — readable, comfortable */
font-family: "Geist", "DM Sans", ui-sans-serif, system-ui, sans-serif;

/* Code snippets inside messages */
font-family: "Geist Mono", "JetBrains Mono", "Fira Code", ui-monospace, monospace;
```

> **Implementation note:** Prefer bundled/self-hosted fonts only.
> Use system stack by default, or self-host via `@fontsource/*` / local `@font-face` imported through `assets/css/app.css`.
> Do not require external `<link>` font imports in `root.html.heex` for core UI rendering.
>
> **Fallback strategy:** The system font stack (`ui-sans-serif, system-ui, -apple-system`) is acceptable and visually coherent — DM Sans is an enhancement, not a requirement for correct rendering.

### 2.2 Size Scale

| Name | Tailwind | px equiv | Line Height | Usage |
|------|----------|----------|-------------|-------|
| `2xs` | `text-[10px]` | 10px | `leading-none` | Timestamps, metadata |
| `xs` | `text-xs` | 12px | `leading-4` | Badge labels, captions, `(edited)` marker |
| `sm` | `text-sm` | 14px | `leading-5` | Channel list items, secondary text, form labels |
| `base` | `text-base` | 16px | `leading-6` | Message body content |
| `lg` | `text-lg` | 18px | `leading-7` | Channel header name, modal titles |
| `xl` | `text-xl` | 20px | `leading-7` | Workspace name in sidebar header |
| `2xl` | `text-2xl` | 24px | `leading-8` | Welcome screen headline |

### 2.3 Weight Guide

| Weight | Tailwind | Usage |
|--------|----------|-------|
| Regular | `font-normal` | Message body text |
| Medium | `font-medium` | Username in messages, section headers, timestamps |
| Semibold | `font-semibold` | Channel name in header, active nav items, modal headings |
| Bold | `font-bold` | Workspace name, unread channel names, CTA labels |

### 2.4 Context-Specific Rules

**Sidebar:**
- Section headers: `text-xs font-semibold uppercase tracking-widest text-base-content/40`
- Channel/DM items: `text-sm font-normal text-base-content/70`
- Active item: `text-sm font-semibold text-base-content`
- Unread item: `text-sm font-semibold text-base-content`
- User footer name: `text-sm font-medium text-base-content`
- User footer status: `text-xs text-base-content/50`

**Message Content:**
- Sender name: `text-sm font-semibold text-base-content`
- Timestamp: `text-[10px] font-medium text-base-content/40 tabular-nums`
- Body: `text-sm font-normal text-base-content leading-relaxed`
- `(edited)`: `text-[10px] text-base-content/35 italic ml-1`
- Deleted: `text-sm italic text-base-content/40`
- Code inline: `font-mono text-xs bg-base-300 px-1 py-0.5 rounded`

**Channel Header:**
- Name: `text-base font-semibold text-base-content`
- Description: `text-xs text-base-content/55 truncate`

**Timestamps (compact, in message list):**
- Right-aligned, `tabular-nums`, `text-[10px]`, opacity 40%

---

## 3. Spacing System

### 3.1 Base Unit

**4px (0.25rem)** — all spacing values are multiples of 4px.

### 3.2 Application Measurements

| Element | Measurement | Tailwind Classes |
|---------|-------------|-----------------|
| Sidebar width (desktop) | 256px | `w-64` |
| Sidebar width (mobile) | 288px | `w-72` |
| Sidebar item height | 32px | `h-8` |
| Sidebar item padding (horizontal) | 8px | `px-2` |
| Sidebar item padding (vertical) | 4px | `py-1` |
| Sidebar section header padding | `8px top, 4px bottom` | `pt-2 pb-1` |
| Sidebar outer padding | 8px | `p-2` |
| Space between sidebar items | 2px | `space-y-0.5` |
| Channel header height | 52px | `h-[52px]` |
| Channel header padding | 16px horizontal | `px-4` |
| Thread panel width (desktop) | 400px | `w-[400px]` |
| Message row padding (top/bottom) | 2px | `py-0.5` |
| Message row padding (horizontal) | 16px | `px-4` |
| Message group gap | 16px | `mt-4` (between groups) |
| Message bubble padding | 12px × 16px | `py-3 px-4` |
| Avatar size (message) | 32px | `size-8` |
| Avatar size (sidebar DM) | 24px | `size-6` |
| Avatar size (user footer) | 32px | `size-8` |
| Avatar size (profile popover) | 48px | `size-12` |
| Avatar-to-content gap | 8px | `gap-2` |
| Compose area padding | 12px | `p-3` |
| Compose textarea min-height | 44px | `min-h-11` |
| Compose textarea max-height | 200px | (JS-enforced, `max-h-[200px]`) |
| Modal padding | 24px | `p-6` |
| Modal border radius | 8px | `rounded-lg` (via `--radius-box`) |
| Space between messages (same sender) | 2px | `space-y-0.5` |
| Space between messages (new sender) | 16px | first message in group gets `mt-4` |
| Reaction pill padding | 4px × 8px | `py-1 px-2` |
| Reaction pill gap | 4px | `gap-1` |

---

## 4. Component Specifications

> **daisyUI usage note:** Use daisyUI component classes (`btn`, `avatar`, `badge`, `modal`, `menu`, etc.) as the structural base. Layer Tailwind utilities for spacing, typography, and layout. Avoid overriding daisyUI's semantic color tokens — use them consistently.

---

### 4a. Sidebar

#### Layout

```
┌─────────────────────────────┐  ← w-64 (256px), h-full, flex flex-col
│  Slackex              ≡     │  ← header: px-3 py-3, border-b border-base-300
├─────────────────────────────┤
│  ▾ CHANNELS          [+][⌕] │  ← section header: px-3 pt-3 pb-1
│    # general                │  ← channel item (active)
│    # design          ●2     │  ← channel item (unread, badge)
│    # backend                │  ← channel item (read)
│  ▾ DIRECT MESSAGES   [+]   │  ← section header
│    ● Alice                  │  ← DM item (online)
│    ○ Bob             ●1     │  ← DM item (offline, unread)
├─────────────────────────────┤
│  [AV]  David Williams  ☀ ✏  │  ← user footer: px-3 py-2, border-t border-base-300
└─────────────────────────────┘
```

#### Sidebar Shell

```
class="flex flex-col h-full w-64 bg-base-200 border-r border-base-300
       md:static md:translate-x-0
       fixed inset-y-0 left-0 z-40 transition-transform duration-200 ease-in-out"
```

Mobile-closed adds: `-translate-x-full`
Mobile-open: `translate-x-0` (default)

#### Sidebar Header

```html
<div class="flex items-center justify-between px-3 py-3 border-b border-base-300">
  <span class="text-xl font-bold text-base-content tracking-tight">Slackex</span>
  <!-- Mobile only hamburger -->
  <button class="btn btn-ghost btn-sm btn-square md:hidden">
    <span class="hero-bars-3 size-5" />
  </button>
</div>
```

#### Section Header with Collapse

```html
<div class="flex items-center justify-between px-3 pt-3 pb-1 group">
  <button class="flex items-center gap-1 text-xs font-semibold uppercase tracking-widest
                 text-base-content/40 hover:text-base-content/70 transition-colors duration-100">
    <!-- Chevron rotates 90° when collapsed -->
    <span class="hero-chevron-down size-3 transition-transform duration-150"
          class={if @collapsed, do: "-rotate-90"} />
    Channels
  </button>
  <div class="flex items-center gap-0.5 opacity-0 group-hover:opacity-100 transition-opacity duration-100">
    <button class="btn btn-ghost btn-xs btn-square" title="Create channel">
      <span class="hero-plus size-3.5" />
    </button>
    <button class="btn btn-ghost btn-xs btn-square" title="Browse channels">
      <span class="hero-magnifying-glass size-3.5" />
    </button>
  </div>
</div>
```

#### Channel List Item

States: default | hover | active | unread

```html
<li>
  <.link patch={~p"/chat/#{channel.slug}"}
    class={[
      "flex items-center gap-2 px-2 py-1 rounded-md text-sm transition-colors duration-100",
      "hover:bg-base-300/60",
      if(@active, do: "bg-primary/10 text-base-content font-semibold",
                  else: "text-base-content/70 font-normal"),
      if(@unread > 0 and not @active, do: "font-semibold text-base-content")
    ]}>
    <span class="text-base-content/40 font-normal shrink-0">#</span>
    <span class="flex-1 truncate"><%= @channel.name %></span>
    <.unread_badge :if={@unread > 0 and not @active} count={@unread} />
  </.link>
</li>
```

**States:**
- Default: `text-base-content/70`, no bg
- Hover: `bg-base-300/60` (subtle, non-jarring)
- Active: `bg-primary/10 text-base-content font-semibold` (indigo-tinted bg)
- Unread: `font-semibold text-base-content` + unread badge

#### DM List Item

```html
<li>
  <.link patch={~p"/chat/dm/#{@dm.id}"}
    class={[
      "flex items-center gap-2 px-2 py-1 rounded-md text-sm transition-colors duration-100",
      "hover:bg-base-300/60",
      if(@active, do: "bg-primary/10 text-base-content font-semibold",
                  else: "text-base-content/70 font-normal")
    ]}>
    <div class="relative shrink-0">
      <.avatar user={@dm.other_user} size="xs" />
      <.online_dot online={@online} />
    </div>
    <span class="flex-1 truncate"><%= @dm.other_user.display_name || @dm.other_user.username %></span>
    <.unread_badge :if={@unread > 0 and not @active} count={@unread} />
  </.link>
</li>
```

#### User Footer

```html
<div class="flex items-center gap-2 px-3 py-2 border-t border-base-300 mt-auto">
  <div class="relative shrink-0">
    <.avatar user={@current_user} size="sm" />
    <.online_dot online={true} />
  </div>
  <div class="flex-1 min-w-0">
    <p class="text-sm font-medium text-base-content truncate">
      <%= @current_user.display_name || @current_user.username %>
    </p>
    <p :if={@current_user.status} class="text-xs text-base-content/50 truncate">
      <%= @current_user.status %>
    </p>
  </div>
  <div class="flex items-center gap-0.5 shrink-0">
    <!-- Theme toggle -->
    <button phx-click={JS.dispatch("phx:set-theme")} data-phx-theme="dark"
      class="btn btn-ghost btn-xs btn-square dark:hidden" title="Dark mode">
      <span class="hero-moon size-4" />
    </button>
    <button phx-click={JS.dispatch("phx:set-theme")} data-phx-theme="light"
      class="btn btn-ghost btn-xs btn-square hidden dark:flex" title="Light mode">
      <span class="hero-sun size-4" />
    </button>
    <!-- Edit profile -->
    <.link patch={~p"/chat/profile/edit"}
      class="btn btn-ghost btn-xs btn-square" title="Edit profile">
      <span class="hero-pencil-square size-4" />
    </.link>
  </div>
</div>
```

---

### 4b. Message Bubble

#### Layout

```
┌──────────────────────────────────────────────────────────┐
│                                              [✎][🗑][😊][↩] │  ← hover actions (hidden at rest)
│  [AV]  Alice         10:34 am  (edited)                  │
│        Hello! Has anyone had a chance to review the       │
│        design proposals I sent yesterday?                 │
│                                                           │
│        👍 3   ❤️ 2   [+]                                  │  ← reaction bar
└──────────────────────────────────────────────────────────┘
```

#### Full Component Class Recipe

```html
<div id={dom_id}
  class={[
    "group relative flex gap-2 px-4 py-0.5",
    "hover:bg-base-300/30 transition-colors duration-75",
    # First in sender group gets extra top margin
    if(@first_in_group, do: "mt-4", else: "mt-0")
  ]}>

  <!-- Avatar (only on first message in group) -->
  <div class="shrink-0 w-8">
    <.avatar :if={@first_in_group} user={@message.sender} size="md" />
  </div>

  <!-- Content -->
  <div class="flex-1 min-w-0">
    <!-- Header row (only on first in group) -->
    <div :if={@first_in_group} class="flex items-baseline gap-2 mb-0.5">
      <button class="text-sm font-semibold text-base-content hover:underline">
        <%= message_sender_name(@message) %>
      </button>
      <time class="text-[10px] font-medium text-base-content/40 tabular-nums">
        <%= format_time(@message) %>
      </time>
      <span :if={@message.edited_at} class="text-[10px] italic text-base-content/35">(edited)</span>
    </div>

    <!-- Compact timestamp (subsequent messages in group, shown on hover) -->
    <time :if={not @first_in_group}
      class="absolute left-0 w-14 text-right text-[10px] text-base-content/40
             tabular-nums opacity-0 group-hover:opacity-100 transition-opacity duration-100">
      <%= format_time(@message) %>
    </time>

    <!-- Message body or deleted placeholder -->
    <%= if @message.deleted_at do %>
      <p class="text-sm italic text-base-content/40">This message was deleted.</p>
    <% else %>
      <p class="text-sm text-base-content leading-relaxed break-words whitespace-pre-wrap">
        <%= @message.content %>
      </p>
    <% end %>

    <!-- Thread replies count -->
    <button :if={Map.get(@message, :reply_count, 0) > 0}
      phx-click="open_thread" phx-value-message-id={@message.id}
      class="flex items-center gap-1.5 mt-1 text-xs font-medium text-primary
             hover:text-primary/80 hover:underline transition-colors duration-100">
      <span class="hero-chat-bubble-left-right size-3.5" />
      <%= @message.reply_count %> <%= if @message.reply_count == 1, do: "reply", else: "replies" %>
    </button>

    <!-- Reaction bar -->
    <.reaction_bar
      :if={Map.get(@message, :reactions, []) != []}
      reactions={Map.get(@message, :reactions, [])}
      current_user_id={@current_user_id}
      message_id={@message.id} />
  </div>

  <!-- Hover action toolbar -->
  <div class={[
    "absolute right-4 -top-4 z-10",
    "flex items-center gap-0.5 p-0.5",
    "bg-base-100 border border-base-300 rounded-lg shadow-sm",
    "opacity-0 group-hover:opacity-100 scale-95 group-hover:scale-100",
    "transition-all duration-120 ease-out pointer-events-none group-hover:pointer-events-auto"
  ]}>
    <button :if={@is_own_message}
      phx-click="start_edit" phx-value-message-id={@message.id}
      class="btn btn-ghost btn-xs btn-square" title="Edit">
      <span class="hero-pencil size-3.5" />
    </button>
    <button
      data-emoji-trigger data-message-id={@message.id}
      class="btn btn-ghost btn-xs btn-square" title="Add reaction">
      <span class="hero-face-smile size-3.5" />
    </button>
    <button
      phx-click="open_thread" phx-value-message-id={@message.id}
      class="btn btn-ghost btn-xs btn-square" title="Reply in thread">
      <span class="hero-arrow-uturn-left size-3.5" />
    </button>
    <button :if={@can_delete}
      phx-click="delete_message" phx-value-message-id={@message.id}
      class="btn btn-ghost btn-xs btn-square text-error hover:bg-error/10" title="Delete">
      <span class="hero-trash size-3.5" />
    </button>
  </div>
</div>
```

#### Inline Edit Mode

When `@editing_message_id == @message.id`, replace body with:

```html
<form phx-submit="save_edit" class="mt-1">
  <input type="hidden" name="message-id" value={@message.id} />
  <textarea
    name="content"
    class="textarea textarea-bordered w-full text-sm min-h-[44px] resize-none
           focus:outline-none focus:border-primary/60 bg-base-100"
    phx-hook="AutoResize"
  ><%= @message.content %></textarea>
  <div class="flex items-center gap-2 mt-1.5">
    <button type="submit" class="btn btn-primary btn-xs">Save</button>
    <button type="button" phx-click="cancel_edit" class="btn btn-ghost btn-xs">Cancel</button>
    <span class="text-xs text-base-content/40 ml-auto">Escape to cancel · Enter to save</span>
  </div>
</form>
```

**States summary:**
| State | Visual |
|-------|--------|
| Default | No bg, no hover actions visible |
| Hover | `bg-base-300/30`, action toolbar visible (opacity-100, scale-100) |
| Editing | Textarea replaces content, Save/Cancel controls |
| Own message | Edit + Delete buttons in action bar |
| Deleted | Italic muted text, no actions shown |
| Has thread | "N replies" link below content |

---

### 4c. Compose Area

#### Layout

```
┌─────────────────────────────────────────────────────────┐
│  Message #general                                    ↵  │
│                                                          │
│  [😊] [📎] [Aa]                         Shift+↵ newline │
└─────────────────────────────────────────────────────────┘
  ↑ border-t border-base-300, bg-base-100, p-3
```

#### Class Recipe

```html
<div class="shrink-0 px-4 py-3 border-t border-base-300 bg-base-100">
  <!-- Read-only state (non-member) -->
  <div :if={not @can_send}
    class="flex items-center justify-center h-11 text-sm text-base-content/45
           bg-base-200 rounded-lg border border-base-300">
    Join this channel to send messages
  </div>

  <!-- Active compose -->
  <div :if={@can_send}
    phx-hook="Compose"
    class="flex flex-col gap-2 bg-base-100 border border-base-300 rounded-xl
           focus-within:border-primary/40 focus-within:ring-1 focus-within:ring-primary/20
           transition-shadow duration-150">

    <!-- Textarea -->
    <.form for={@message_form} id="message-form" phx-submit="send_message">
      <textarea
        name="message[content]"
        placeholder={"Message ##{@active_channel.name}"}
        class="w-full px-3 pt-3 pb-1 text-sm bg-transparent resize-none
               min-h-11 max-h-[200px] outline-none placeholder:text-base-content/35"
        autocomplete="off"
        phx-debounce="100"
        rows="1"
      ><%= @message_form[:content].value %></textarea>

      <!-- Toolbar -->
      <div class="flex items-center justify-between px-2 pb-2">
        <div class="flex items-center gap-0.5">
          <button type="button" class="btn btn-ghost btn-xs btn-square" title="Emoji">
            <span class="hero-face-smile size-4 text-base-content/50" />
          </button>
          <button type="button" class="btn btn-ghost btn-xs btn-square" title="Attachment">
            <span class="hero-paper-clip size-4 text-base-content/50" />
          </button>
          <button type="button" class="btn btn-ghost btn-xs btn-square" title="Formatting">
            <span class="hero-bars-3-bottom-left size-4 text-base-content/50" />
          </button>
        </div>
        <div class="flex items-center gap-2">
          <span class="text-[10px] text-base-content/30 hidden sm:block">
            <kbd class="kbd kbd-xs">Shift</kbd>+<kbd class="kbd kbd-xs">↵</kbd> newline
          </span>
          <button type="submit"
            class="btn btn-primary btn-sm gap-1.5 phx-submit-loading:opacity-60">
            <span class="hero-paper-airplane size-4" />
          </button>
        </div>
      </div>
    </.form>
  </div>
</div>
```

**States:**
| State | Visual |
|-------|--------|
| Default | Border `base-300`, no ring |
| Focus | Border `primary/40`, ring `primary/20` |
| Submitting | Send button `opacity-60` (via `phx-submit-loading`) |
| Non-member | Gray info bar, no compose UI |
| Empty | Send button still shows (keyboard UX) |

---

### 4d. Channel Header

#### Layout

```
┌──────────────────────────────────────────────────────────────┐
│  # general           3 members  📌 2          ⚙ Settings    │
│  The main channel for everyone                               │
└──────────────────────────────────────────────────────────────┘
  ↑ h-[52px], border-b border-base-300, bg-base-100
```

#### Class Recipe

```html
<div class="flex items-center gap-3 px-4 h-[52px] border-b border-base-300 bg-base-100 shrink-0">
  <!-- Name -->
  <div class="flex-1 min-w-0">
    <div class="flex items-center gap-1">
      <span class="text-base-content/40 font-normal text-base">#</span>
      <h2 class="text-base font-semibold text-base-content truncate">
        <%= @active_channel.name %>
      </h2>
    </div>
    <p :if={@active_channel.description}
      class="text-xs text-base-content/55 truncate leading-none">
      <%= @active_channel.description %>
    </p>
  </div>

  <!-- Right-side actions -->
  <div class="flex items-center gap-1 shrink-0">
    <!-- Members -->
    <.link patch={~p"/chat/#{@active_channel.slug}/members"}
      class="btn btn-ghost btn-sm gap-1.5 text-xs text-base-content/60 hover:text-base-content">
      <span class="hero-users size-4" />
      <%= @member_count %>
    </.link>

    <!-- Pins -->
    <.link patch={~p"/chat/#{@active_channel.slug}/pins"}
      class="btn btn-ghost btn-sm gap-1.5 text-xs text-base-content/60 hover:text-base-content">
      <span class="hero-bookmark size-4" />
      <span :if={@pin_count > 0} class="badge badge-xs badge-accent"><%= @pin_count %></span>
    </.link>

    <!-- Settings / invite (admin only) -->
    <.link :if={@is_admin} patch={~p"/chat/#{@active_channel.slug}/invites"}
      class="btn btn-ghost btn-sm btn-square text-base-content/60" title="Invite">
      <span class="hero-user-plus size-4" />
    </.link>

    <!-- Join/Leave -->
    <button :if={not @is_member}
      phx-click="join_channel"
      class="btn btn-primary btn-sm">Join Channel</button>
    <button :if={@is_member and not @is_owner}
      phx-click="leave_channel"
      class="btn btn-ghost btn-sm text-base-content/60">Leave</button>
  </div>
</div>
```

---

### 4e. Thread Panel

#### Layout

```
                        ┌─────────────────────────────┐
                        │  Thread              ✕       │  ← header, border-b
                        ├─────────────────────────────┤
                        │  [AV] Alice  10:30           │  ← parent message
                        │       Original message here  │    (bg-base-200/60, rounded)
                        ├─────────────────────────────┤
                        │  2 replies                   │  ← divider
                        ├─────────────────────────────┤
                        │  [AV] Bob  10:45             │  ← reply
                        │       First reply            │
                        │  [AV] Alice  10:46           │
                        │       Second reply           │
                        ├─────────────────────────────┤
                        │  [compose reply...]          │  ← reply compose
                        └─────────────────────────────┘
```

#### Class Recipe

```html
<!-- Thread panel container -->
<div class={[
  "flex flex-col border-l border-base-300 bg-base-100",
  "w-[400px] shrink-0",
  # Mobile: full-width overlay
  "md:relative md:w-[400px]",
  "fixed inset-y-0 right-0 z-30 w-full md:w-[400px]",
  "transition-transform duration-200 ease-in-out",
  if(@thread_open, do: "translate-x-0", else: "translate-x-full md:translate-x-0")
]}>
  <!-- Header -->
  <div class="flex items-center justify-between px-4 h-[52px] border-b border-base-300 shrink-0">
    <h3 class="text-base font-semibold text-base-content">Thread</h3>
    <button phx-click="close_thread" class="btn btn-ghost btn-sm btn-square">
      <span class="hero-x-mark size-5" />
    </button>
  </div>

  <!-- Parent message (read-only, highlighted) -->
  <div class="px-4 py-3 border-b border-base-300">
    <div class="bg-base-200/60 rounded-lg p-3">
      <.message_bubble message={@parent_message} current_user_id={@current_user_id}
        show_hover_actions={false} first_in_group={true} />
    </div>
    <p class="text-xs text-base-content/40 mt-2 pl-1">
      <%= @parent_message.reply_count %> <%= if @parent_message.reply_count == 1, do: "reply", else: "replies" %>
    </p>
  </div>

  <!-- Reply list -->
  <div id="thread-replies" phx-update="stream"
    class="flex-1 overflow-y-auto py-2">
    <div :for={{dom_id, reply} <- @streams.replies} id={dom_id}>
      <.message_bubble message={reply} current_user_id={@current_user_id}
        show_hover_actions={true} first_in_group={true} />
    </div>
  </div>

  <!-- Reply compose -->
  <div class="shrink-0 px-4 py-3 border-t border-base-300">
    <div class="border border-base-300 rounded-xl focus-within:border-primary/40
                focus-within:ring-1 focus-within:ring-primary/20 transition-shadow duration-150">
      <textarea
        placeholder="Reply in thread..."
        class="w-full px-3 pt-2.5 pb-1 text-sm bg-transparent resize-none
               min-h-[44px] max-h-[120px] outline-none placeholder:text-base-content/35"
        rows="1"
      ></textarea>
      <div class="flex justify-end px-2 pb-2">
        <button class="btn btn-primary btn-sm">
          <span class="hero-paper-airplane size-4" />
        </button>
      </div>
    </div>
  </div>
</div>
```

---

### 4f. Modal

#### Base Shell

```
┌────────────────────────────────────────────────────────┐
│  ╔══════════════════════════════════════════════════╗  │
│  ║  Modal Title                                  ✕  ║  │  ← header, border-b
│  ╠══════════════════════════════════════════════════╣  │
│  ║                                                  ║  │
│  ║  [modal content]                                 ║  │  ← body, overflow-y-auto
│  ║                                                  ║  │
│  ╠══════════════════════════════════════════════════╣  │
│  ║  [Cancel]                          [Primary CTA] ║  │  ← footer, border-t
│  ╚══════════════════════════════════════════════════╝  │
└────────────────────────────────────────────────────────┘
  ↑ backdrop: fixed inset-0 bg-black/50 backdrop-blur-[2px]
```

#### Class Recipe

```html
<!-- Backdrop -->
<div class="fixed inset-0 z-50 flex items-center justify-center p-4
            bg-base-content/20 backdrop-blur-[2px]"
  phx-click="close_modal">

  <!-- Modal box -->
  <div class={[
    "relative flex flex-col bg-base-100 rounded-xl shadow-2xl",
    "border border-base-300",
    "w-full max-h-[90vh]",
    # Sizes
    "sm:max-w-md",   # default
    # "sm:max-w-lg",  # large
    # "sm:max-w-sm",  # small
    "animate-in fade-in-0 zoom-in-95 duration-150"
  ]}
  phx-click-away="close_modal">

    <!-- Header -->
    <div class="flex items-center justify-between px-6 py-4 border-b border-base-300 shrink-0">
      <h2 class="text-base font-semibold text-base-content">Modal Title</h2>
      <button phx-click="close_modal"
        class="btn btn-ghost btn-sm btn-square -mr-2">
        <span class="hero-x-mark size-5" />
      </button>
    </div>

    <!-- Body -->
    <div class="flex-1 overflow-y-auto px-6 py-4">
      <!-- Content slot -->
    </div>

    <!-- Footer -->
    <div class="flex items-center justify-end gap-2 px-6 py-4
                border-t border-base-300 shrink-0">
      <button phx-click="close_modal" class="btn btn-ghost btn-sm">Cancel</button>
      <button type="submit" form="modal-form" class="btn btn-primary btn-sm">
        Save
      </button>
    </div>
  </div>
</div>
```

**Modal variants:**
- **Form modal** (create channel, edit profile): Standard shell with `<.form>` in body
- **Browse/list modal** (browse channels, members): Adds search input at top of body, scrollable list below
- **Confirm modal** (delete message): No form, just description text + destructive action button (use `btn-error`)
- **Info modal** (pinned messages): Read-only list with optional unpin actions

**States:**
| State | Visual |
|-------|--------|
| Enter | `fade-in zoom-in-95` 150ms (use Tailwind `animate-in` or JS transition) |
| Exit | `fade-out zoom-out-95` 100ms |
| Submitting | Primary button `phx-submit-loading:opacity-60 phx-submit-loading:cursor-not-allowed` |
| With error | Form field shows error below with `text-error text-xs` |

---

### 4g. Emoji Reaction Pill

#### Layout

```
┌────────────────────────────────┐
│  👍 3   ❤️ 2   😂 1   [+]      │
└────────────────────────────────┘
```

#### Class Recipe

```html
<div class="flex flex-wrap items-center gap-1 mt-1.5">
  <button :for={reaction <- @grouped_reactions}
    phx-click="toggle_reaction"
    phx-value-message-id={@message_id}
    phx-value-emoji={reaction.emoji}
    class={[
      "inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs",
      "border transition-colors duration-100",
      if(reaction.user_reacted,
        do: "bg-primary/10 border-primary/30 text-primary font-medium",
        else: "bg-base-200 border-base-300 text-base-content/70 hover:bg-base-300 hover:border-base-300/80"
      )
    ]}>
    <span class="text-sm leading-none"><%= reaction.emoji %></span>
    <span class="tabular-nums"><%= reaction.count %></span>
  </button>

  <!-- Add reaction -->
  <button
    data-emoji-trigger data-message-id={@message_id}
    class="inline-flex items-center justify-center w-7 h-6 rounded-full text-xs
           bg-base-200 border border-base-300 text-base-content/50
           hover:bg-base-300 hover:text-base-content transition-colors duration-100">
    <span class="hero-plus size-3" />
  </button>
</div>
```

**States:**
| State | Class |
|-------|-------|
| Default | `bg-base-200 border-base-300 text-base-content/70` |
| Hover | `bg-base-300` |
| Own reaction | `bg-primary/10 border-primary/30 text-primary font-medium` |
| Own + hover | `bg-primary/15 border-primary/40` |

---

### 4h. Unread Badge

#### Class Recipe

```html
<span class={[
  "inline-flex items-center justify-center",
  "min-w-[18px] h-[18px] px-1",
  "rounded-full text-[10px] font-bold tabular-nums",
  "bg-accent text-accent-content",
  "shrink-0"
]}>
  <%= if @count > 99, do: "99+", else: @count %>
</span>
```

**Appear animation:** `animate-in zoom-in-75 duration-150` when badge first appears (count goes from 0 → N).

**States:**
| State | Visual |
|-------|--------|
| 1–99 | Numeric count |
| 100+ | "99+" |
| 0 / cleared | Hidden (use `:if={@count > 0}`) |

---

### 4i. Online Status Dot

#### Sizes and Class Recipe

```html
<!-- On avatar: positioned bottom-right -->
<div class="relative inline-block">
  <!-- avatar content -->
  <span :if={@online}
    class={[
      "absolute bottom-0 right-0 rounded-full ring-2 ring-base-200",
      case @size do
        "xs" -> "size-2"    # 8px — on sidebar DM items
        "sm" -> "size-2.5"  # 10px — on user footer
        "md" -> "size-3"    # 12px — on message avatars, profile popover
        _ -> "size-2.5"
      end,
      "bg-success"
    ]} />
  <span :if={not @online}
    class={[
      "absolute bottom-0 right-0 rounded-full ring-2 ring-base-200 bg-base-300",
      case @size do
        "xs" -> "size-2"
        "sm" -> "size-2.5"
        "md" -> "size-3"
        _ -> "size-2.5"
      end
    ]} />
</div>
```

**Notes:**
- `ring-2 ring-base-200` creates a visible gap between dot and avatar (matches the panel background)
- Online = `bg-success` (sage green)
- Offline = `bg-base-300` (muted gray, subtle — doesn't demand attention)
- Never show a status dot if online status is unknown (omit the element)

---

### 4j. Empty State

#### Layout

```
         ┌──────────────────────┐
         │                      │
         │         icon         │  ← 40px, text-base-content/25
         │                      │
         │   Nothing here yet   │  ← text-base font-medium
         │                      │
         │  Description text    │  ← text-sm text-base-content/50
         │                      │
         │    [CTA Button]      │  ← optional
         └──────────────────────┘
```

#### Class Recipe

```html
<div class="flex flex-col items-center justify-center gap-3 py-16 px-8 text-center">
  <div class="size-10 text-base-content/25">
    <span class={["hero-#{@icon} size-10"]} />
  </div>
  <div class="space-y-1">
    <h3 class="text-base font-medium text-base-content"><%= @title %></h3>
    <p :if={@subtitle} class="text-sm text-base-content/50 max-w-xs"><%= @subtitle %></p>
  </div>
  <%= render_slot(@inner_block) %>
</div>
```

**Instance reference:**

| Context | Icon | Title | Subtitle |
|---------|------|-------|----------|
| No channel selected | `chat-bubble-left-right` | Welcome to Slackex | Select a channel to start chatting |
| No messages | `chat-bubble-oval-left` | No messages yet | Be the first to say something! |
| No DMs | `user-group` | No conversations | Search for a person above to start a DM |
| No search results | `magnifying-glass` | No results | Try a different search term |
| No channels to browse | `hash` | All caught up | You've joined all public channels |
| No pinned messages | `bookmark` | No pins | Pin important messages to find them later |

---

### 4k. Typing Indicator

#### Layout

```
┌────────────────────────────────────────────────┐
│  ● ● ●  Alice is typing...                     │
└────────────────────────────────────────────────┘
  ↑ 28px tall, px-4, sits between message list and compose
```

#### Class Recipe

```html
<div :if={@typing_text}
  class="flex items-center gap-2 px-4 py-1 h-7 transition-all duration-200">
  <!-- Animated dots -->
  <div class="flex items-center gap-0.5">
    <span class="size-1.5 rounded-full bg-base-content/40 animate-bounce [animation-delay:0ms]" />
    <span class="size-1.5 rounded-full bg-base-content/40 animate-bounce [animation-delay:150ms]" />
    <span class="size-1.5 rounded-full bg-base-content/40 animate-bounce [animation-delay:300ms]" />
  </div>
  <span class="text-xs text-base-content/50 italic"><%= @typing_text %></span>
</div>
```

Add the bounce animation configuration in `app.css`:

```css
/* Typing dot animation — staggered bounce */
@keyframes typing-dot {
  0%, 60%, 100% { transform: translateY(0); opacity: 0.4; }
  30% { transform: translateY(-4px); opacity: 0.9; }
}

.typing-dot {
  animation: typing-dot 1.2s ease-in-out infinite;
}
```

**Appearance/disappearance:**
- Appear: element transitions from `h-0 opacity-0` to `h-7 opacity-100` (use CSS transitions or JS.show/hide with transition classes)
- Disappear after 3 seconds of no typing activity (handled in LiveView with `Process.send_after`)

---

## 5. Animation & Transition Specifications

### 5.1 Principles

1. **Duration is inversely proportional to spatial distance.** Small changes (hover color) = 75–100ms. Panel slides = 200ms. Modals = 150ms.
2. **Easing:** `ease-out` for things entering, `ease-in` for things leaving. `ease-in-out` for reversible toggle motions.
3. **No animation for pure data updates.** Message text changes, unread count updates — instant. Only spatial/visibility changes animate.

### 5.2 Transition Reference

| Element | Trigger | Duration | Easing | CSS/Tailwind |
|---------|---------|----------|--------|--------------|
| Sidebar slide (mobile) | Hamburger toggle | 200ms | ease-in-out | `transition-transform duration-200 ease-in-out` |
| Sidebar backdrop fade | Same | 200ms | ease-in-out | `transition-opacity duration-200` |
| Modal backdrop | Open/close | 150ms | ease-out / ease-in | `duration-150` |
| Modal panel | Open | 150ms | ease-out | `animate-in fade-in zoom-in-95 duration-150` |
| Modal panel | Close | 100ms | ease-in | `animate-out fade-out zoom-out-95 duration-100` |
| Thread panel slide | Reply click / close | 200ms | ease-in-out | `transition-transform duration-200 ease-in-out` |
| Message row hover bg | Hover | 75ms | ease-out | `transition-colors duration-75` |
| Action toolbar | Hover | 120ms | ease-out | `transition-all duration-[120ms] ease-out` |
| Action toolbar scale | Same | 120ms | ease-out | (same, scale-95 → scale-100) |
| Sidebar item hover | Hover | 100ms | ease-out | `transition-colors duration-100` |
| Nav link active state | Navigation | instant | — | No animation (reduces distraction during nav) |
| Unread badge appear | New message | 150ms | ease-out | `animate-in zoom-in-75 duration-150` |
| Typing indicator | Appear/disappear | 200ms | ease-out / ease-in | `transition-all duration-200` |
| Typing dots | Continuous | 1200ms | ease-in-out | CSS `@keyframes`, stagger 150ms |
| Reaction pill hover | Hover | 100ms | ease-out | `transition-colors duration-100` |
| Compose border focus | Focus | 150ms | ease-out | `transition-shadow duration-150` |
| Section collapse | Toggle | 150ms | ease-in-out | `transition-transform duration-150` on chevron |
| Online dot | Status change | instant | — | No animation |
| Flash toast | Appear | 300ms | ease-out | Existing `CoreComponents.show` |
| Flash toast | Dismiss | 200ms | ease-in | Existing `CoreComponents.hide` |

### 5.3 Reduced Motion

Respect `prefers-reduced-motion`. Add to `app.css`:

```css
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after {
    animation-duration: 0.01ms !important;
    transition-duration: 0.01ms !important;
  }
}
```

The Tailwind `motion-safe:` variant can gate specific animations:
```
class="motion-safe:animate-bounce"
```

---

## 6. daisyUI Theme Configuration

The project uses **Tailwind CSS v4 CSS-first configuration** via `@plugin` directives in `assets/css/app.css`. There is no `tailwind.config.js`. Theme tokens are set as CSS custom properties inside `@plugin "../vendor/daisyui-theme" { ... }` blocks.

Replace the existing light and dark theme blocks in `assets/css/app.css` with the following:

### 6.1 Light Theme — "slackex-light"

```css
@plugin "../vendor/daisyui-theme" {
  name: "light";
  default: true;
  prefersdark: false;
  color-scheme: "light";

  /* --- Surfaces --- */
  --color-base-100: oklch(99% 0.002 264);
  --color-base-200: oklch(95.5% 0.004 264);
  --color-base-300: oklch(90% 0.006 264);
  --color-base-content: oklch(14% 0.008 264);

  /* --- Brand: Indigo --- */
  --color-primary: oklch(52% 0.22 264);
  --color-primary-content: oklch(98% 0.005 264);

  /* --- Secondary: Cool gray --- */
  --color-secondary: oklch(62% 0.04 264);
  --color-secondary-content: oklch(98% 0 0);

  /* --- Accent: Warm amber --- */
  --color-accent: oklch(68% 0.17 70);
  --color-accent-content: oklch(15% 0.04 70);

  /* --- Neutral --- */
  --color-neutral: oklch(40% 0.010 264);
  --color-neutral-content: oklch(97% 0.002 264);

  /* --- Semantic --- */
  --color-info: oklch(58% 0.16 238);
  --color-info-content: oklch(97% 0.012 238);
  --color-success: oklch(62% 0.13 165);
  --color-success-content: oklch(97% 0.012 165);
  --color-warning: oklch(66% 0.17 58);
  --color-warning-content: oklch(15% 0.04 58);
  --color-error: oklch(58% 0.22 17);
  --color-error-content: oklch(97% 0.012 17);

  /* --- Shape --- */
  --radius-selector: 0.375rem;
  --radius-field: 0.375rem;
  --radius-box: 0.5rem;

  /* --- Size --- */
  --size-selector: 0.21875rem;
  --size-field: 0.21875rem;

  /* --- Border --- */
  --border: 1px;

  /* --- Depth / Noise --- */
  --depth: 0;
  --noise: 0;
}
```

### 6.2 Dark Theme — "slackex-dark"

```css
@plugin "../vendor/daisyui-theme" {
  name: "dark";
  default: false;
  prefersdark: true;
  color-scheme: "dark";

  /* --- Surfaces --- */
  --color-base-100: oklch(17% 0.008 264);
  --color-base-200: oklch(13.5% 0.007 264);
  --color-base-300: oklch(21% 0.010 264);
  --color-base-content: oklch(93% 0.008 264);

  /* --- Brand: Indigo (brighter for dark bg) --- */
  --color-primary: oklch(63% 0.20 264);
  --color-primary-content: oklch(98% 0.005 264);

  /* --- Secondary: Muted cool gray --- */
  --color-secondary: oklch(55% 0.04 264);
  --color-secondary-content: oklch(95% 0.003 264);

  /* --- Accent: Warm amber --- */
  --color-accent: oklch(72% 0.15 70);
  --color-accent-content: oklch(12% 0.04 70);

  /* --- Neutral --- */
  --color-neutral: oklch(30% 0.010 264);
  --color-neutral-content: oklch(90% 0.006 264);

  /* --- Semantic --- */
  --color-info: oklch(62% 0.15 238);
  --color-info-content: oklch(14% 0.03 238);
  --color-success: oklch(60% 0.14 165);
  --color-success-content: oklch(14% 0.03 165);
  --color-warning: oklch(68% 0.16 58);
  --color-warning-content: oklch(15% 0.04 58);
  --color-error: oklch(62% 0.20 17);
  --color-error-content: oklch(14% 0.03 17);

  /* --- Shape --- */
  --radius-selector: 0.375rem;
  --radius-field: 0.375rem;
  --radius-box: 0.5rem;

  /* --- Size --- */
  --size-selector: 0.21875rem;
  --size-field: 0.21875rem;

  /* --- Border --- */
  --border: 1px;

  /* --- Depth / Noise --- */
  --depth: 0;
  --noise: 0;
}
```

### 6.3 Additional Global CSS Additions

Add these to `assets/css/app.css` after the theme blocks:

```css
/* ─── Typing indicator bounce ─────────────────────────── */
@keyframes typing-dot-bounce {
  0%, 60%, 100% { transform: translateY(0); opacity: 0.4; }
  30% { transform: translateY(-3px); opacity: 0.85; }
}

.typing-dot {
  animation: typing-dot-bounce 1.2s ease-in-out infinite;
}

/* ─── Modal enter/exit animations ─────────────────────── */
@keyframes modal-enter {
  from { opacity: 0; transform: scale(0.96) translateY(4px); }
  to   { opacity: 1; transform: scale(1) translateY(0); }
}
@keyframes modal-exit {
  from { opacity: 1; transform: scale(1) translateY(0); }
  to   { opacity: 0; transform: scale(0.96) translateY(4px); }
}

.modal-enter { animation: modal-enter 150ms ease-out forwards; }
.modal-exit  { animation: modal-exit 100ms ease-in forwards; }

/* ─── Reduced motion ───────────────────────────────────── */
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after {
    animation-duration: 0.01ms !important;
    transition-duration: 0.01ms !important;
  }
}

/* ─── Message action toolbar ───────────────────────────── */
/*
   The group-hover pattern handles most cases via Tailwind utilities.
   This handles the pointer-events toggle cleanly:
*/
.message-actions {
  pointer-events: none;
}
.message-row:hover .message-actions {
  pointer-events: auto;
}
```

---

## 7. Avatar Component Specification

Since `avatar` is used throughout, here is the full spec:

```html
<!-- avatar/1 function component -->
<div class={[
  "avatar",
  if(@online, do: "avatar-online", else: "avatar-offline")
]}>
  <div class={[
    "rounded-full bg-base-300",
    case @size do
      "xs"  -> "size-6"    # 24px
      "sm"  -> "size-8"    # 32px
      "md"  -> "size-10"   # 40px
      "lg"  -> "size-12"   # 48px
      _     -> "size-8"
    end
  ]}>
    <%= if @user.avatar_url do %>
      <img src={@user.avatar_url} alt={@user.username} class="object-cover" />
    <% else %>
      <!-- Initials fallback -->
      <span class={[
        "flex items-center justify-center h-full font-semibold text-base-content/70",
        case @size do
          "xs" -> "text-[9px]"
          "sm" -> "text-xs"
          "md" -> "text-sm"
          "lg" -> "text-base"
          _    -> "text-xs"
        end
      ]}>
        <%= initials(@user) %>
      </span>
    <% end %>
  </div>
</div>
```

**Note:** daisyUI's `avatar-online` / `avatar-offline` classes render the online dot via CSS ring. If you prefer manual control (for custom sizing of the dot), use the manual `online_dot` pattern from section 4i instead and omit the daisyUI avatar modifier classes.

**Initials helper** (in `ChatComponents`):
```elixir
defp initials(%{display_name: name}) when is_binary(name) and name != "" do
  name |> String.split() |> Enum.take(2) |> Enum.map(&String.first/1) |> Enum.join()
end
defp initials(%{username: username}) when is_binary(username) do
  String.first(username) |> String.upcase()
end
defp initials(_), do: "?"
```

---

## 8. Accessibility Notes

| Concern | Implementation |
|---------|---------------|
| Focus rings | daisyUI provides default focus rings; ensure `outline-none` is only used on elements with custom `focus-visible:ring` |
| ARIA for sidebar | `role="navigation"` on sidebar nav, `aria-current="page"` on active channel link |
| ARIA for modals | `role="dialog"` `aria-modal="true"` `aria-labelledby` on modal shell; trap focus inside |
| Keyboard — compose | Enter sends, Shift+Enter newline (via Compose JS hook) |
| Keyboard — quick switch | Ctrl+K / Cmd+K (global keydown listener) |
| Screen readers — badges | `aria-label="3 unread messages"` on unread badge span |
| Screen readers — online dot | `aria-label="Online"` or `aria-hidden="true"` with surrounding text providing context |
| Touch — sidebar | Swipe gestures are an enhancement; hamburger is the primary mobile toggle |
| Color contrast | All text/bg combinations in this palette meet WCAG AA (4.5:1 for body text, 3:1 for large text); verify with browser DevTools accessibility panel |

---

## 9. Implementation Checklist

Use this when implementing Phase 5 components:

- [ ] Replace theme blocks in `app.css` with Section 6 definitions
- [ ] Add font import to `root.html.heex`
- [ ] Add typing indicator CSS keyframes to `app.css`
- [ ] Add modal animation CSS to `app.css`
- [ ] Implement `avatar/1` component with initials fallback
- [ ] Implement `channel_list_item/1` with active/unread states
- [ ] Implement `dm_list_item/1` with online dot
- [ ] Implement `message_bubble/1` with hover action toolbar
- [ ] Implement `reaction_bar/1` and `emoji_reaction_pill/1`
- [ ] Implement `unread_badge/1`
- [ ] Implement `online_dot/1`
- [ ] Implement `empty_state/1`
- [ ] Implement `typing_indicator/1`
- [ ] Build `SidebarComponent` with all four sections
- [ ] Build channel header with action buttons
- [ ] Build compose area with auto-resize textarea
- [ ] Build thread panel component
- [ ] Build modal shell (reusable across all modal use cases)
- [ ] Verify light/dark theme rendering on all components
- [ ] Verify responsive layout (sidebar collapse on mobile)
- [ ] Run accessibility audit (contrast, keyboard nav, screen reader)
