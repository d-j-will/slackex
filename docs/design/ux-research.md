# UX Research: Messaging & Productivity App Patterns
## For Slackex Phase 5 UI Implementation

**Date:** 2026-02-23
**Scope:** Layout, visual design, interaction patterns, mobile, dark mode, message list
**Stack:** Phoenix LiveView + daisyUI + Tailwind CSS
**Design direction:** Modern minimal (Linear/Notion-inspired)

---

## Executive Summary

The current Slackex UI is a functional proof-of-concept: a fixed-height flex container, a `w-64 bg-base-200` sidebar, daisyUI chat bubbles, and a global navbar eating 80px of vertical space. Phase 5 transforms this into a complete, polished messaging product.

The single most important principle from studying Linear, Notion, Slack, and Discord: **visual hierarchy comes from space and weight, not from decorations**. Remove the global navbar for chat routes. Let the sidebar and message area breathe. Use one accent color with discipline. Every shadow, border, and color should earn its place.

---

## 1. Layout Patterns

### What Best Apps Do

**Slack (desktop):** Three-column layout with fixed proportions. Left sidebar is ~220px, contains workspace name, sections (Channels, DMs, Apps), and a bottom user profile area. The middle column (message list) fills remaining space. When a thread opens, the right panel slides in at ~400px and the middle column compresses rather than overlapping — this is critical, it keeps both readable simultaneously. A persistent header bar per channel shows name, description, member count, and action buttons (search, members, pins). The sidebar header shows workspace name with a dropdown chevron. The sidebar sections are collapsible with a subtle triangle affordance.

**Discord:** Adds a 72px icon-only server list as the leftmost column, then a channel/category sidebar (~240px), then main content. More information-dense than Slack but also noisier. Category sections collapse. The channel sidebar uses a tree-like structure with category headers. Their insight: icons-only server rail reduces visual noise while allowing many workspaces.

**Linear:** Two columns. Sidebar (~240px) with icon+label nav items, group headers at lowercase text size, no visible borders between items — spacing creates separation. Main content is generous whitespace. Linear never crowds the sidebar: items have ~32px height, ~8px horizontal padding, ~4px vertical gap. The key insight is that Linear's sidebar feels "open" because items are not contained in any card or box — they float in space with just hover/active state backgrounds.

**Notion:** Sidebar (~240px) collapses completely with a hover-to-reveal trigger. Page list uses tree indentation (16px per level). The sidebar background is slightly warmer/cooler than the main content depending on theme — a 2% luminance difference is enough to signal the regions without a visible border. Notion uses no sidebar border at all in its default view.

### Why It Works

Slack's thread panel compression (vs overlay) works because it maintains spatial context — the user sees both the conversation flow and the thread simultaneously, essential for following discussions. Linear's floating nav items (no boxes) work because they trust whitespace to organize — each item is discoverable by hover, not by a visible container. The absence of borders forces the eye to navigate by content, which feels sophisticated.

### Recommendations for Slackex

**Remove the global navbar for chat routes entirely.** The current `h-[calc(100vh-80px)]` approach wastes 80px permanently. The layout at `/chat/**` should be full-viewport-height with the workspace name, user info, and theme toggle living in the sidebar itself. Modify `app.html.heex` to detect chat context and render edge-to-edge.

```heex
<%# app.html.heex — chat routes get no header %>
<%= if chat_route?(@conn) do %>
  {@inner_content}
<% else %>
  <header class="navbar ...">...</header>
  <main class="px-4 py-6 ...">
    <.flash_group flash={@flash} />
    {@inner_content}
  </main>
<% end %>
```

**Three-region layout for Phase 5:**

```
┌─────────────────────────────────────────────────────────────────┐
│ SIDEBAR (256px fixed)  │  MESSAGE LIST (flex-1)  │ THREAD (400px│
│                        │                          │ slides in)   │
│ ┌──────────────────┐   │ ┌──────────────────────┐ │              │
│ │ Workspace header │   │ │ Channel header        │ │              │
│ ├──────────────────┤   │ ├──────────────────────┤ │              │
│ │ Channels section │   │ │                      │ │              │
│ │   # general      │   │ │   Message stream     │ │              │
│ │   # design       │   │ │                      │ │              │
│ ├──────────────────┤   │ ├──────────────────────┤ │              │
│ │ DMs section      │   │ │   Compose area       │ │              │
│ ├──────────────────┤   │ └──────────────────────┘ │              │
│ │ User footer      │   │                          │              │
│ └──────────────────┘   │                          │              │
└─────────────────────────────────────────────────────────────────┘
```

**Sidebar proportions (Tailwind classes):**

```
Sidebar:        w-64 (256px) — matches Slack's actual sidebar width
Thread panel:   w-[400px] — matches Slack's thread panel
Message list:   flex-1 min-w-0 — compresses to accommodate thread, never overlaps
```

**Thread panel behavior:** Use `flex` on the outer container. When thread opens, thread panel slides in from the right and message list compresses. On mobile, thread panel overlays full-width.

```
Outer: class="flex h-screen overflow-hidden"
Sidebar: class="w-64 shrink-0 flex flex-col"
Main: class="flex-1 flex flex-col min-w-0"
Thread: class="w-[400px] shrink-0 border-l border-base-300 flex flex-col
              transition-all duration-200 ease-out"
       (add hidden or translate-x-full when closed)
```

**Sidebar internal structure:**

```
Workspace header:   h-14, border-b border-base-300, workspace name + chevron
Channels section:   flex-1, overflow-y-auto, p-2
DMs section:        flex-1 (shared scroll), p-2
User footer:        h-16, border-t border-base-300, avatar + name + actions
```

**Channel header (inside main area):**

```
Height:     h-14, border-b border-base-300
Content:    # channel-name (font-semibold) + description (text-sm opacity-60)
            + members count (right-aligned) + pins icon + search icon
```

---

## 2. Visual Design Language

### What Makes Linear/Notion "Modern Minimal"

**Linear's approach (deeply analyzed):**

1. **No card shadows.** Nothing has `box-shadow`. Visual hierarchy comes entirely from background color differences (`bg-[#141414]` vs `bg-[#161616]`) and typography weight.
2. **Muted palette with one sharp accent.** Dark backgrounds are near-neutral (very slightly warm or cool). The accent (Linear's purple/indigo) appears only on active states, CTAs, and key indicators — never as decoration.
3. **Border strategy:** Borders are `1px solid rgba(255,255,255,0.06)` in dark mode — barely visible, just enough to separate regions. In light mode, `1px solid rgba(0,0,0,0.08)`. You can see them but you don't notice them.
4. **Typography is weight-dominant:** Linear uses font-weight as the primary hierarchy signal. Page titles are `font-semibold`, metadata is `font-normal text-xs opacity-50`. No font-size hierarchy explosion.
5. **Icon stroke consistency:** All icons at 1.5px stroke weight, 16-20px size. Never filled except for active/selected states (which switch to filled variant).

**Notion's approach:**

1. **Generous whitespace as structure.** Notion uses padding aggressively — sidebar items have `px-3 py-1`, but sections have `mt-4` between them. The blank space communicates hierarchy.
2. **Semantic grays.** Text has four levels: primary (opacity-90), secondary (opacity-60), tertiary (opacity-40), placeholder (opacity-30). No additional colors used for text hierarchy.
3. **Hover-first affordance.** Actions (the `...` menu, drag handles) only appear on hover. This keeps the resting state clean.
4. **Consistent radius:** Everything that has a border-radius uses the same value. Notion uses `4px` (very slight). Nothing feels bubble-like.

### Recommendations for Slackex

**The existing daisyUI theme is well-calibrated** — the OKLCH color values use perceptually uniform lightness, and the `base-100/200/300` tokens create a natural depth hierarchy. Leverage these rather than fighting them.

**Aesthetic direction: "Structured Clarity"**
- Sidebar: `bg-base-200` (slightly darker than content) — already correct
- Content area: `bg-base-100` (lightest, most prominent)
- Dividers: `border-base-300` at default thickness — already correct
- Remove ALL box shadows from the chat UI chrome (keep them only for modals/dropdowns)

**Typography recommendations:**

Do NOT add external font imports — they add network overhead and LiveView apps need fast initial renders. Instead, use the system font stack with specific modifications:

```css
/* In app.css — add after existing imports */
.chat-ui {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
  font-feature-settings: "kern" 1, "liga" 1;
  -webkit-font-smoothing: antialiased;
}

.channel-name {
  font-variant-numeric: tabular-nums;
  letter-spacing: -0.01em;
}

.message-content {
  line-height: 1.5;
  letter-spacing: 0;
}

.sidebar-label {
  font-size: 0.6875rem; /* 11px */
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  opacity: 0.45;
}
```

**Color token usage (Tailwind classes mapped to daisyUI tokens):**

| Element | Light | Dark | Class |
|---------|-------|------|-------|
| Sidebar background | base-200 | base-200 | `bg-base-200` |
| Message area | base-100 | base-100 | `bg-base-100` |
| Active channel item | base-300 | base-300 | `bg-base-300` |
| Hover state | base-300/50 | base-300/40 | `hover:bg-base-300/50` |
| Primary text | base-content | base-content | `text-base-content` |
| Secondary text | base-content/60 | base-content/60 | `text-base-content/60` |
| Muted text | base-content/40 | base-content/40 | `text-base-content/40` |
| Dividers | base-300 | base-300 | `border-base-300` |
| Unread badge | primary | primary | `bg-primary text-primary-content` |
| Online dot | success | success | `bg-success` |

**What to avoid:**
- `shadow-lg` or any shadow on sidebar/header — use border instead
- Multiple accent colors — the existing `primary` (orange in light, purple in dark) is the only accent
- `rounded-xl` or `rounded-2xl` on UI chrome — use `rounded` (4px) or `rounded-md` (6px)
- Gradient backgrounds — flat colors only
- `text-primary` for informational text — reserve primary color for interactive elements only

---

## 3. Interaction Patterns

### What Best Apps Do

**Linear's hover states:** Background transitions to `rgba(255,255,255,0.04)` over 100ms `ease-out`. No border change, no shadow. The subtlety makes it feel native rather than web-ish. Linear also uses `cursor: pointer` on all interactive elements without exception.

**Slack's message hover:** The entire message row gets a `bg-[rgba(var(--sk_highlight-hovered-bg))]` on hover — the whole row, not just the bubble. The action buttons (emoji, reply, more) appear absolutely positioned at the top-right of the row, with their own background to float above the row background. Actions fade in at `opacity: 0 → 1` over 80ms.

**Discord's transitions:** Panel opens/closes use `transform: translateX()` with `200ms cubic-bezier(0.2, 0, 0, 1)` — this is a custom ease that starts fast and decelerates, feeling physical/responsive.

**Modal patterns (Notion/Linear):**
- Backdrop: `bg-black/50` with `backdrop-blur-sm` on the modal container
- Modal appears with `scale(0.96) → scale(1)` over 150ms — avoids jarring pop-in
- Modal closes on Escape key and backdrop click (always, no exceptions)
- Focus trap inside modal while open

**Context menus (Linear):**
Right-click or `...` button reveals a clean dropdown. Each item is `h-8 px-3 text-sm` with `hover:bg-base-300/50`. Destructive actions (delete) appear last, separated by a divider, in `text-error`. No icons in context menu items — just text.

**Typing indicators:**
Linear/Notion don't have typing indicators (async tools), but Slack's is perfectly calibrated: 3 animated dots that pulse in sequence, positioned below the last message rather than in the compose area. The text "Name is typing..." appears only after 500ms of typing to avoid flashing on short messages.

### Recommendations for Slackex

**Transition system — establish these as CSS custom properties:**

```css
/* app.css */
:root {
  --duration-instant: 80ms;
  --duration-fast: 150ms;
  --duration-base: 200ms;
  --duration-slow: 300ms;
  --ease-out: cubic-bezier(0.0, 0.0, 0.2, 1);
  --ease-spring: cubic-bezier(0.2, 0, 0, 1);
}
```

**Tailwind transition classes to use consistently:**

```
Sidebar slide (mobile):     transition-transform duration-200 ease-out
Thread panel open/close:    transition-[width,opacity] duration-200 ease-out
Modal appear:               transition-[transform,opacity] duration-150 ease-out
Hover backgrounds:          transition-colors duration-100
Action buttons reveal:      transition-opacity duration-75
```

**Message hover actions — the right pattern:**

```heex
<%# In message_bubble component %>
<div class="group relative flex gap-3 px-4 py-0.5 hover:bg-base-200/60 rounded-md">
  <%# Avatar + content %>

  <%# Hover actions — absolutely positioned top-right %>
  <div class="absolute right-4 top-0 -translate-y-1/2
              opacity-0 group-hover:opacity-100
              transition-opacity duration-75
              flex items-center gap-0.5 bg-base-100 border border-base-300
              rounded-md shadow-sm p-0.5">
    <button class="btn btn-ghost btn-xs btn-circle" title="React">
      <.icon name="hero-face-smile" class="h-4 w-4" />
    </button>
    <button class="btn btn-ghost btn-xs btn-circle" title="Reply in thread">
      <.icon name="hero-chat-bubble-left" class="h-4 w-4" />
    </button>
    <%# Edit/delete only for own messages %>
    <button class="btn btn-ghost btn-xs btn-circle" title="Edit">
      <.icon name="hero-pencil" class="h-4 w-4" />
    </button>
    <button class="btn btn-ghost btn-xs btn-circle text-error" title="Delete">
      <.icon name="hero-trash" class="h-4 w-4" />
    </button>
  </div>
</div>
```

**Keyboard shortcuts to implement (Phase 5):**

| Shortcut | Action |
|----------|--------|
| `Ctrl/Cmd + K` | Open quick switcher |
| `Escape` | Close modal, panel, or popover |
| `Escape` (in compose) | Cancel edit mode |
| `Enter` | Send message |
| `Shift + Enter` | Newline in message |
| `Up arrow` (in empty compose) | Edit last own message |
| `Alt + Shift + Up/Down` | Navigate between channels |

**Sidebar item hover (exact classes):**

```
Channel item: class="flex items-center gap-2 px-2 py-1 rounded
                     text-sm text-base-content/70
                     hover:bg-base-300/50 hover:text-base-content
                     transition-colors duration-100 cursor-pointer"

Active channel: class="... bg-base-300 text-base-content font-medium"
```

**Context menu for messages (right-click):**

```
Width: w-48
Padding: p-1
Items: px-3 py-1.5 text-sm rounded hover:bg-base-300/50 cursor-pointer
Separator: my-1 border-t border-base-300
Destructive: text-error hover:bg-error/10
```

**Compose area behavior:**
- Textarea auto-resizes from 1 line (44px) to max 200px
- Border changes from `border-base-300` to `border-primary` on focus (ring-free, border-only)
- Send button is icon-only (`hero-paper-airplane`) on small compose, text "Send" on large
- Compose toolbar (formatting, emoji) appears above textarea when focused

---

## 4. Mobile Responsiveness

### How Slack and Discord Handle Mobile

**Slack mobile:** Drops entirely to single-column. Bottom tab bar with: Home (channels list), DMs, Activity (notifications), You (profile). The sidebar doesn't slide in from the left — instead, Home IS the channel list screen. Navigating to a channel pushes the full-screen message view. The back button returns to the list. This is a native-app pattern that doesn't translate cleanly to LiveView's SPA model.

**Discord mobile:** More similar to what we need for a web app. Single-column with a swipe-right gesture to reveal the channel sidebar. Long-press on messages for the action menu (no hover). Bottom spacing accounts for iOS safe areas.

**The web app approach (not native app):** For LiveView, the pragmatic approach is:
1. Single breakpoint: `md` (768px) separates "mobile" from "desktop"
2. Below `md`: sidebar is a fixed overlay, triggered by a hamburger button
3. Thread panel on mobile: full-width overlay with a close/back button
4. No bottom tab bar (too complex for LiveView without heavy JS)

### Recommendations for Slackex

**Breakpoint strategy — single pivot at `md`:**

```
< 768px (mobile):   Sidebar hidden by default, full-screen message list
≥ 768px (desktop):  Sidebar always visible at w-64
```

**Mobile sidebar implementation (from spec, refined):**

```heex
<%# Hamburger — mobile only %>
<button class="md:hidden btn btn-ghost btn-sm btn-circle"
        phx-click="toggle_sidebar">
  <.icon name="hero-bars-3" class="h-5 w-5" />
</button>

<%# Sidebar overlay on mobile %>
<aside class={[
  "fixed inset-y-0 left-0 z-40 flex flex-col w-72 bg-base-200",
  "md:static md:w-64 md:translate-x-0",
  "transition-transform duration-200 ease-out",
  if(@sidebar_open, do: "translate-x-0", else: "-translate-x-full md:translate-x-0")
]}>
  <%# sidebar content %>
</aside>

<%# Backdrop — mobile only, when sidebar open %>
<div :if={@sidebar_open}
     class="fixed inset-0 z-30 bg-black/50 md:hidden"
     phx-click="toggle_sidebar" />
```

**Touch targets — minimum 44×44px (Apple HIG / WCAG 2.5.5):**

```
Channel list items:     py-2 (32px height + 8px padding each side = 48px tap area) ✓
Message action buttons: btn-sm minimum (h-8 = 32px — add py-1 wrapper if needed)
Avatar click targets:   Always wrap in button with p-1 to reach 44px
Compose send button:    btn btn-primary — default daisyUI btn is 48px ✓
```

**Thread panel on mobile:**

```heex
<%# Full-width overlay on mobile, side panel on desktop %>
<div class={[
  "fixed inset-0 z-30 bg-base-100 flex flex-col",
  "md:static md:w-[400px] md:inset-auto md:z-auto",
  "transition-transform duration-200 ease-out",
  unless(@thread_open, do: "translate-x-full md:translate-x-0 md:hidden")
]}>
  <div class="flex items-center gap-2 h-14 px-4 border-b border-base-300 md:hidden">
    <button phx-click="close_thread" class="btn btn-ghost btn-sm btn-circle">
      <.icon name="hero-arrow-left" class="h-5 w-5" />
    </button>
    <span class="font-semibold">Thread</span>
  </div>
  <%# thread content %>
</div>
```

**Mobile-specific spacing adjustments:**

```
Compose area:   Add pb-safe (env(safe-area-inset-bottom)) for iOS notch
Message list:   Reduce px-4 to px-3 on mobile
Sidebar items:  Increase to py-2.5 on mobile (better tap targets)
```

**iOS safe area handling (add to app.css):**

```css
.compose-area {
  padding-bottom: max(1rem, env(safe-area-inset-bottom));
}

.message-list {
  padding-bottom: max(0.5rem, env(safe-area-inset-bottom));
}
```

---

## 5. Dark Mode

### Color Token Strategy from Best Apps

**Linear (dark):** Uses HSL colors with very low saturation for backgrounds. The sidebar is `hsl(220, 6%, 10%)`, the main area is `hsl(220, 6%, 8%)`. The sidebar is actually slightly LIGHTER than the main area — the opposite of what you'd expect — because in dark mode, lighter = closer to the user = "in front." Their insight: **dark mode sidebar should be the same lightness or very slightly lighter than content, not darker.**

**Notion (dark):** Similar — sidebar is `#191919`, content is `#191919` with a `#202020` hover. Very close together. The separation is achieved by subtle sidebar borders and whitespace, not luminance difference.

**Slack (dark):** More opinionated — sidebar is distinctly darker than content (`#19171D` vs `#1A1D21`). The contrast provides clear wayfinding. This works for Slack's complex sidebar because users need the spatial anchoring.

**The key insight:** In the current Slackex dark theme, `base-200` is `oklch(25.26% 0.014 253.1)` and `base-100` is `oklch(30.33% 0.016 252.42)` — so `base-100` is lighter (higher L value). This means the sidebar (`base-200`) IS correctly darker than the content (`base-100`). This matches Slack's pattern and is the right call for a messaging app where sidebar context matters.

### Semantic vs Absolute Color Approaches

**Absolute (what NOT to do):**
```css
/* Breaks when switching themes */
.sidebar { background: #1a1a2e; }
.message { color: #e2e8f0; }
```

**Semantic (what to do):**
```css
/* Works in both light and dark themes */
.sidebar { background: oklch(var(--color-base-200)); }
.message { color: oklch(var(--color-base-content)); }
```

The existing daisyUI setup already does this correctly with CSS custom properties.

### Recommendations for Slackex

**Theme-aware color decisions — always use daisyUI tokens, never raw colors:**

```heex
<%# WRONG — breaks in dark mode %>
<div class="bg-gray-800 text-gray-200">

<%# RIGHT — adapts to theme via CSS vars %>
<div class="bg-base-200 text-base-content">
```

**Reaction pills — require special dark mode handling:**

```heex
<%# Own reaction (user has reacted) %>
<button class="px-2 py-0.5 rounded-full text-xs
               bg-primary/20 border border-primary/40 text-primary
               hover:bg-primary/30 transition-colors">
  👍 3
</button>

<%# Other reaction %>
<button class="px-2 py-0.5 rounded-full text-xs
               bg-base-300/60 border border-base-300 text-base-content/70
               hover:bg-base-300 transition-colors">
  ❤️ 2
</button>
```

**Online indicator colors — use semantic tokens:**

```heex
<%# Online dot — use success color (already calibrated for both themes) %>
<span class="block w-2.5 h-2.5 rounded-full bg-success ring-2 ring-base-200" />

<%# Offline dot %>
<span class="block w-2.5 h-2.5 rounded-full bg-base-content/20 ring-2 ring-base-200" />
```

**Maintaining contrast hierarchy — the four text levels:**

```
Text level 1 (primary content):    text-base-content           (opacity 100%)
Text level 2 (secondary/meta):     text-base-content/60        (opacity 60%)
Text level 3 (placeholder/hint):   text-base-content/40        (opacity 40%)
Text level 4 (disabled/faded):     text-base-content/25        (opacity 25%)
```

Always check: in dark mode, `text-base-content` is `oklch(97.8%)` (near-white). At 60% opacity that's still ~58% luminance — readable. At 25% it's ~24% — borderline. Never go below 25% for any text that carries information.

**Modal backdrop in both themes:**

```heex
<div class="fixed inset-0 z-50 flex items-center justify-center
            bg-base-content/20 backdrop-blur-sm">
  <%# bg-base-content/20 reads as dark gray in light mode,
      near-black in dark mode — both appropriate %>
</div>
```

**Theme toggle implementation — matches spec:**

```heex
<button phx-click={JS.dispatch("toggle-theme")}
        class="btn btn-ghost btn-sm btn-circle"
        title="Toggle theme">
  <.icon name="hero-sun-solid"
         class="h-4 w-4 hidden dark:block" />
  <.icon name="hero-moon-solid"
         class="h-4 w-4 dark:hidden" />
</button>
```

The existing `data-theme` attribute approach on `<html>` already handles this correctly. The `@custom-variant dark` in `app.css` maps `dark:` prefix to `[data-theme=dark]`.

---

## 6. Message List Design

### Compact vs Cozy — What Apps Do

**Slack (cozy, default):**
- 4px between messages from different senders (group gap)
- Messages from the same sender within 5 minutes collapse: only the first shows avatar + name
- Collapsed messages show a hover-revealed timestamp on the left
- Date separators: horizontally centered pill with text like "Monday, February 23"
- System messages (joins, topic changes): centered text in `text-base-content/50`

**Slack (compact mode):** Available in settings. Reduces padding, shows usernames inline (no avatar-per-message), smaller text. 40% more messages visible. Not recommended as a default — feels cramped.

**Discord:** Similar grouping behavior but with larger avatars (40px vs Slack's 36px). Message content area aligns with a `left: 72px` offset from the message list edge, creating a consistent reading column. Discord also groups by time (7-minute window).

**Linear:** Not a messaging app, but its activity feed uses a timeline with thin vertical connecting lines between entries from the same author — a more structured version of message grouping.

### Message Grouping Logic

The key insight from Slack's UX: **consecutive messages from the same sender feel like a single unit.** The full header (avatar + name + time) appears only on the first message of a group. Subsequent messages in the group show only content — the avatar space is preserved as whitespace, keeping text alignment consistent.

Grouping conditions:
1. Same `sender_id`
2. Within 5 minutes of the previous message
3. No system events between them

### Recommendations for Slackex

**Message grouping implementation in `message_bubble/1`:**

The LiveView stream makes this tricky — each message renders independently without context from adjacent messages. The practical approach for Phase 5: pass a `is_grouped` attribute derived from comparing `message.sender_id` and `message.inserted_at` with the previous message at the template level.

```heex
<%# In Index render — track previous message for grouping %>
<%# This requires a comprehension with index awareness %>

<div :for={{dom_id, message} <- @streams.messages}
     id={dom_id}
     class={[
       "group relative flex gap-3 px-4",
       if(grouped?(message), do: "pt-0.5 pb-0", else: "pt-3 pb-0")
     ]}>

  <%# Avatar column — always 40px wide for alignment %>
  <div class="w-10 shrink-0 flex justify-center">
    <%= if not grouped?(message) do %>
      <ChatComponents.avatar user={message.sender} size="md"
                             online={message.sender_id in @online_user_ids} />
    <% else %>
      <%# Hover-revealed timestamp for grouped messages %>
      <span class="opacity-0 group-hover:opacity-100 transition-opacity
                   text-[10px] text-base-content/40 leading-[1.375rem]
                   font-mono tabular-nums mt-0.5">
        {format_time_short(message)}
      </span>
    <% end %>
  </div>

  <%# Content column %>
  <div class="flex-1 min-w-0">
    <%# Header — only for first in group %>
    <div :if={not grouped?(message)} class="flex items-baseline gap-2 mb-0.5">
      <span class="font-semibold text-sm text-base-content leading-snug">
        {message_sender_name(message)}
      </span>
      <time class="text-xs text-base-content/40 font-mono tabular-nums">
        {format_time(message)}
      </time>
      <span :if={message.edited_at} class="text-xs text-base-content/30">
        (edited)
      </span>
    </div>

    <%# Message content %>
    <%= if message.deleted_at do %>
      <p class="text-sm text-base-content/40 italic">
        This message was deleted.
      </p>
    <% else %>
      <p class="text-sm text-base-content leading-relaxed break-words">
        {message.content}
      </p>
    <% end %>

    <%# Reaction bar %>
    <ChatComponents.reaction_bar
      :if={has_reactions?(message)}
      reactions={@reactions[message.id] || []}
      current_user_id={@current_user.id}
      message_id={message.id}
    />

    <%# Thread reply count %>
    <button :if={message.reply_count > 0}
            phx-click={JS.patch(~p"/chat/#{@active_channel.slug}/thread/#{message.id}")}
            class="mt-1 text-xs text-primary hover:underline flex items-center gap-1">
      <.icon name="hero-chat-bubble-left-right" class="h-3.5 w-3.5" />
      {message.reply_count} {if message.reply_count == 1, do: "reply", else: "replies"}
    </button>
  </div>

  <%# Hover actions (absolutely positioned) %>
  <div class="absolute right-4 top-1
              opacity-0 group-hover:opacity-100 transition-opacity duration-75
              flex items-center gap-0.5
              bg-base-100 border border-base-300 rounded-md shadow-sm p-0.5 z-10">
    <button data-emoji-trigger data-message-id={message.id}
            class="btn btn-ghost btn-xs btn-circle">
      <.icon name="hero-face-smile" class="h-4 w-4" />
    </button>
    <button phx-click={JS.patch(~p"/chat/#{@active_channel.slug}/thread/#{message.id}")}
            class="btn btn-ghost btn-xs btn-circle">
      <.icon name="hero-chat-bubble-left" class="h-4 w-4" />
    </button>
    <button :if={message.sender_id == @current_user.id}
            phx-click="start_edit" phx-value-message-id={message.id}
            class="btn btn-ghost btn-xs btn-circle">
      <.icon name="hero-pencil" class="h-4 w-4" />
    </button>
    <button :if={can_delete?(@current_user, message, @active_channel)}
            phx-click="delete_message" phx-value-message-id={message.id}
            phx-confirm="Delete this message?"
            class="btn btn-ghost btn-xs btn-circle text-error">
      <.icon name="hero-trash" class="h-4 w-4" />
    </button>
  </div>
</div>
```

**Date separator component:**

```heex
<%# date_separator function component %>
<div class="flex items-center gap-3 px-4 my-4">
  <div class="flex-1 h-px bg-base-300" />
  <span class="text-xs text-base-content/50 font-medium px-2">
    {format_date_separator(date)}
  </span>
  <div class="flex-1 h-px bg-base-300" />
</div>
```

**System message component (join/leave/topic change):**

```heex
<div class="flex items-center gap-2 px-4 py-1 my-1">
  <.icon name="hero-information-circle" class="h-4 w-4 text-base-content/30 shrink-0" />
  <p class="text-xs text-base-content/50 italic">
    {system_message_text}
  </p>
</div>
```

**Compose area design:**

```heex
<div class="px-4 pb-4 pt-2">
  <div class="border border-base-300 focus-within:border-primary/50 rounded-lg
              transition-colors duration-150 bg-base-100">

    <%# Compose toolbar (formatting actions) — always visible %>
    <div class="flex items-center gap-0.5 px-2 pt-2 pb-1 border-b border-base-300/50">
      <button class="btn btn-ghost btn-xs btn-circle opacity-50 hover:opacity-100">
        <.icon name="hero-bold" class="h-3.5 w-3.5" />
      </button>
      <button class="btn btn-ghost btn-xs btn-circle opacity-50 hover:opacity-100">
        <.icon name="hero-code-bracket" class="h-3.5 w-3.5" />
      </button>
    </div>

    <%# Textarea %>
    <textarea
      name="message[content]"
      placeholder={"Message ##{@active_channel.name}"}
      class="w-full px-3 py-2 bg-transparent resize-none
             text-sm text-base-content placeholder:text-base-content/30
             focus:outline-none min-h-[44px] max-h-[200px]"
      rows="1"
    />

    <%# Bottom bar: typing indicator left, send right %>
    <div class="flex items-center justify-between px-3 pb-2">
      <span class="text-xs text-base-content/40 italic h-4">
        {typing_text(@typing_users)}
      </span>
      <button type="submit"
              class="btn btn-primary btn-sm gap-1.5"
              disabled={compose_empty?(@message_form)}>
        <.icon name="hero-paper-airplane" class="h-4 w-4" />
        <span class="hidden sm:inline">Send</span>
      </button>
    </div>
  </div>
</div>
```

**Skeleton loading state (while messages load):**

```heex
<%# Show while message stream is loading %>
<div :for={_ <- 1..5} class="flex gap-3 px-4 py-3 animate-pulse">
  <div class="w-10 h-10 rounded-full bg-base-300 shrink-0" />
  <div class="flex-1 space-y-2">
    <div class="flex items-center gap-2">
      <div class="h-3 w-24 bg-base-300 rounded" />
      <div class="h-3 w-12 bg-base-300/50 rounded" />
    </div>
    <div class="h-3 w-3/4 bg-base-300 rounded" />
    <div class="h-3 w-1/2 bg-base-300/70 rounded" />
  </div>
</div>
```

**Empty state:**

```heex
<div class="flex flex-col items-center justify-center h-full gap-3 text-center px-8">
  <div class="w-16 h-16 rounded-2xl bg-base-300 flex items-center justify-center">
    <.icon name="hero-chat-bubble-left-right" class="h-8 w-8 text-base-content/30" />
  </div>
  <div>
    <h3 class="font-semibold text-base-content">
      Start the conversation
    </h3>
    <p class="text-sm text-base-content/50 mt-1">
      Be the first to post in #{"channel-name"}
    </p>
  </div>
</div>
```

---

## 7. Unread Badges & Sidebar Density

### Recommendation

Sidebar channel items should follow this density: `py-1` (8px top/bottom) with `text-sm` (14px). This gives each item ~30px height, fitting ~20 channels without scrolling on a typical 900px viewport.

**Unread badge (the `unread_badge/1` component):**

```heex
<%# Dot style for small counts, number for large %>
<%= if @count <= 9 do %>
  <span class="badge badge-primary badge-xs min-w-[18px]">
    {@count}
  </span>
<% else %>
  <span class="badge badge-primary badge-xs">
    9+
  </span>
<% end %>
```

**Channel item with unread — bold name when unread:**

```heex
<li>
  <.link patch={~p"/chat/#{channel.slug}"}
        class={[
          "flex items-center justify-between gap-2 px-2 py-1 rounded",
          "text-sm transition-colors duration-100",
          "hover:bg-base-300/50 hover:text-base-content",
          if(active, do: "bg-base-300 text-base-content font-medium",
                    else: "text-base-content/70"),
          if(unread_count > 0 and not active,
             do: "font-semibold text-base-content")
        ]}>
    <span class="flex items-center gap-1.5 min-w-0">
      <span class="text-base-content/40 shrink-0">#</span>
      <span class="truncate">{channel.name}</span>
    </span>
    <.unread_badge :if={unread_count > 0 and not active} count={unread_count} />
  </.link>
</li>
```

---

## 8. Modal Design Standards

All modals in Phase 5 (NewDm, CreateChannel, BrowseChannels, EditProfile, ChannelMembers, PinnedMessages, InviteLinks) should follow this anatomy:

```heex
<%# Outer backdrop %>
<div class="fixed inset-0 z-50 flex items-end sm:items-center justify-center
            bg-base-content/20 backdrop-blur-sm p-0 sm:p-4"
     phx-click-away="close_modal">

  <%# Modal container %>
  <div class="w-full sm:max-w-lg bg-base-100 sm:rounded-xl shadow-xl
              border border-base-300
              flex flex-col max-h-[90vh] sm:max-h-[85vh]">

    <%# Header %>
    <div class="flex items-center justify-between px-6 py-4 border-b border-base-300 shrink-0">
      <h2 class="font-semibold text-base">Modal Title</h2>
      <button phx-click="close_modal" class="btn btn-ghost btn-sm btn-circle">
        <.icon name="hero-x-mark" class="h-5 w-5" />
      </button>
    </div>

    <%# Scrollable body %>
    <div class="flex-1 overflow-y-auto px-6 py-4">
      <%# content %>
    </div>

    <%# Footer (actions) %>
    <div class="flex items-center justify-end gap-2 px-6 py-4 border-t border-base-300 shrink-0">
      <button phx-click="close_modal" class="btn btn-ghost btn-sm">Cancel</button>
      <button type="submit" class="btn btn-primary btn-sm">Save</button>
    </div>
  </div>
</div>
```

**On mobile:** modals should slide up from the bottom (sheet pattern). The `items-end sm:items-center` class achieves this — on mobile the modal anchors to the bottom edge, on desktop it centers.

---

## 9. Quick Switcher (Ctrl+K)

Modeled after Linear's command palette:

```heex
<div class="fixed inset-0 z-50 flex items-start justify-center pt-[15vh]
            bg-base-content/20 backdrop-blur-sm">
  <div class="w-full max-w-md bg-base-100 rounded-xl border border-base-300
              shadow-xl overflow-hidden">

    <%# Search input %>
    <div class="flex items-center gap-3 px-4 h-14 border-b border-base-300">
      <.icon name="hero-magnifying-glass" class="h-5 w-5 text-base-content/40 shrink-0" />
      <input type="text" placeholder="Jump to channel or DM..."
             class="flex-1 bg-transparent text-sm text-base-content
                    placeholder:text-base-content/30 focus:outline-none"
             phx-keyup="quick_switcher_search"
             phx-debounce="100"
             autofocus />
      <kbd class="text-xs text-base-content/30 font-mono">esc</kbd>
    </div>

    <%# Results %>
    <div class="max-h-80 overflow-y-auto py-1">
      <div :for={result <- @quick_switcher_results}
           phx-click={JS.patch(result.path)}
           class="flex items-center gap-3 px-4 py-2.5
                  hover:bg-base-200 cursor-pointer transition-colors duration-75">
        <span :if={result.type == :channel} class="text-base-content/50">#</span>
        <ChatComponents.avatar :if={result.type == :dm}
                               user={result.user} size="sm" />
        <span class="text-sm text-base-content">{result.name}</span>
        <span class="text-xs text-base-content/40 ml-auto">{result.type_label}</span>
      </div>
    </div>
  </div>
</div>
```

---

## Summary: Priority Implementation Order

For Phase 5 visual consistency, implement in this order:

1. **Remove global navbar for chat routes** — highest visual impact, unblocks all other layout work
2. **Three-region layout shell** — sidebar + main + thread panel structure
3. **Sidebar visual language** — hover states, active states, section headers, user footer
4. **Message grouping** — single biggest improvement to message list feel
5. **Compose area** — bordered container with toolbar, not standalone input
6. **Modal anatomy** — consistent header/body/footer across all 6+ modals
7. **Dark mode audit** — verify every new component uses semantic tokens only
8. **Mobile sidebar overlay** — hamburger + backdrop + transition
9. **Transitions** — apply consistent duration/easing system across all interactions
10. **Skeleton loading + empty states** — final polish pass

---

*Document prepared for Slackex Phase 5 implementation. All Tailwind class recommendations are compatible with Tailwind v4 (used in this project) and daisyUI v5.*
