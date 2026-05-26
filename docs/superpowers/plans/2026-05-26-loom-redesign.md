# Loom Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-skin the live Tenun chat UI into the "Loom" visual identity (warm-charcoal canvas, golden #e8c547 thread accent, Geist + Instrument Serif + Geist Mono type, weave motifs) behind a feature flag, without changing any chat behaviour.

**Architecture:** A scoped CSS layer. A single `loom` class on the chat root (added only when `:loom_redesign` is enabled for the actor) re-maps daisyUI's theme CSS custom properties to the Loom palette — instantly re-coloring everything already built with `bg-base-100` / `text-base-content` / `btn` / `badge` / `input`. Targeted `.loom <hook>` selectors then add the distinctive touches (serif titles, mono timestamps, gold reaction pills, woven thread stubs, weave texture), and ~6 small **additive** markup elements (gated by `@loom`) provide structure CSS can't synthesize. Existing markup, `phx-*` bindings, streams, hooks, and tests are untouched.

**Tech Stack:** Phoenix LiveView, Tailwind CSS v4, daisyUI (theme via `data-theme`), FunWithFlags (Ecto adapter), self-hosted woff2 fonts.

---

## Decisions this plan is built on (override any before execution)

1. **Gate:** new `:loom_redesign` FunWithFlags flag, off by default. Dogfood on your actor in prod, then flip globally. (`:new_ui` is a ghost flag — 0 code references — leave it; optionally delete its `/admin/flags` row.)
2. **Theme scope:** dark-first. Dark Loom is fully built in Phase 1; the light variant (Phase 4) is a fast-follow that only overrides tokens.
3. **Fonts:** self-host woff2 (no CSP change, no third-party call, works offline in the PWA).
4. **Novel features:** restyle all live surfaces + add cheap *aesthetic* weave touches (weave texture, golden warp edge, weft strands, serif AI labels, loom-loader, palette kind-icons). **Defer** anything implying data we don't have: warp **activity** bars wired to real metrics, persisted pinned-summaries rail, semantic search in the palette, and the structured strand/citation Summary layout. Deferred items are captured in detail (what/backend-needed/effort/pick-up-order) in `docs/feature/loom-redesign/deferred-novel-features.md`.

### One inline decision (defaulted, flip if you prefer)

`conversation_header/1` receives `title` as a single string `"##{name}"`. The Loom look wants `#` in mono + name in serif italic, which needs the two split apart. **Default (lower risk): style the whole title as serif italic** (including the `#`) via one selector — no signature change, no call-site edits. *Alternative:* change the attr to `name` and split into two spans in `chat_components.ex` + 2 call sites in `index.html.heex`. This plan assumes the default.

### Honest scope gaps (so review doesn't expect more than the data supports)

- **Summary modal → "The Loom":** the live modal streams **plain/markdown text**; the design shows structured threads-with-citations. We restyle the *container* (right-side drawer, loom mark, serif heading, loom-loader replacing the spinner, gold accents). We do **not** reproduce the strands/citations layout — that needs deferred backend work.
- **Quick switcher → ⌘K palette:** restyled to the palette aesthetic incl. per-item kind icons; results stay the existing channel/DM fuzzy match (no semantic search).
- **Composer `/assist`:** **not** added — it implies unbuilt AI affordances. Composer is restyled only.
- Visual fidelity of CSS surfaces is verified **manually in-browser** (checklist in Phase 5). We do **not** TDD pixels.

---

## File Structure

**Create:**
- `assets/css/loom.css` — the entire Loom layer (token remap, fonts `@font-face`, weave, targeted surface styles). One file, one responsibility. Imported by `app.css`.
- `priv/static/fonts/` — self-hosted woff2 files (Geist 400/500/600/700, GeistMono 400/500, InstrumentSerif 400 + italic).
- `test/slackex_web/live/chat_live/loom_redesign_test.exs` — flag-gating regression test.

**Modify:**
- `assets/css/app.css:217` — add `@import "./loom.css";` at end.
- `lib/slackex_web/endpoint.ex` — add `"fonts"` to `Plug.Static` `:only` list.
- `lib/slackex_web/live/chat_live/index.ex` — assign `:loom` from the flag in `mount/3`.
- `lib/slackex_web/live/chat_live/index.html.heex:1` — add `loom` class + weave-bg div to chat root; pass `loom` to sidebar/thread/summary components.
- `lib/slackex_web/components/chat_components.ex` — ~5 additive hook classes/elements (header title class, sidebar class, composer class, reaction-bar classes, thread-stub strands).
- `lib/slackex_web/live/chat_live/sidebar_component.ex` — `chat-sidebar` hook class; receive/forward `loom`.
- `lib/slackex_web/live/chat_live/thread_panel_component.ex` — gated weft SVG element.
- `lib/slackex_web/live/chat_live/summary_modal.ex` — gated loom-mark + loom-loader.
- `lib/slackex_web/live/chat_live/quick_switcher_modal.ex` — gated per-item kind icon.

**Reference only (do not restructure):** `lib/slackex_web/components/layouts/root.html.heex` (font preload optional), `lib/slackex_web/router.ex` (CSP — no change needed for self-host).

---

# Phase 0 — Foundation

### Task 0.1: Create the `:loom_redesign` flag and plumb it into the chat root

**Files:**
- Modify: `lib/slackex_web/live/chat_live/index.ex` (mount assigns block, ~line 123-141 where other flags are assigned)
- Modify: `lib/slackex_web/live/chat_live/index.html.heex:1`

- [ ] **Step 1: Assign the flag in `mount/3`.** In the assign chain alongside the other `FunWithFlags.enabled?` calls, add:

```elixir
|> assign(:loom, FunWithFlags.enabled?(:loom_redesign, for: user))
```

(Use the same `user` actor variable the neighbouring `:show_cluster_node` line uses.)

- [ ] **Step 2: Add the `loom` class + weave overlay to the chat root.** `index.html.heex:1` is currently:

```heex
<div class="flex h-full" id="chat-container" phx-hook="QuickSwitcher">
```

Change to:

```heex
<div class={["flex h-full relative", @loom && "loom"]} id="chat-container" phx-hook="QuickSwitcher">
  <div :if={@loom} class="loom-weave-bg" aria-hidden="true"></div>
```

(Add the matching extra `</div>`? No — the weave div is self-contained; just insert it as the first child. The existing closing `</div>` at line 289 still balances the root.)

- [ ] **Step 3: Forward `loom` to child components that need gated markup.** In the same template:
  - SidebarComponent (`index.html.heex:16-31`): add `loom={@loom}`.
  - ThreadPanelComponent (`:if={@threads_enabled and @thread_parent}`, ~line 272): add `loom={@loom}`.
  - SummaryModal (`:if={@show_summary_modal}`, ~line 362): add `loom={@loom}`.
  - QuickSwitcherModal (~line 372): add `loom={@loom}`.

- [ ] **Step 4: Compile.** Run: `mix compile` — Expected: success, no warnings about the new assign.

- [ ] **Step 5: Commit.**

```bash
git add lib/slackex_web/live/chat_live/index.ex lib/slackex_web/live/chat_live/index.html.heex
git commit -m "feat(loom): gate chat root on :loom_redesign flag"
```

> NOTE: child components must declare the new `loom` attr (default false) so LiveView doesn't warn. Add `attr :loom, :boolean, default: false` to each (`render/1` in the live_components). Include this in Step 1-3 edits.

---

### Task 0.2: Self-host the fonts

**Files:**
- Create: `priv/static/fonts/*.woff2`
- Modify: `lib/slackex_web/endpoint.ex` (`Plug.Static` `only:`)

- [ ] **Step 1: Add `fonts` to static serving.** Find the `plug Plug.Static` call in `endpoint.ex`; its `only:` list enumerates served top-level paths (e.g. `~w(assets fonts images robots.txt ...)`). Ensure `"fonts"` is present. If `static_paths/0` is defined in `SlackexWeb` (lib/slackex_web.ex), add `"fonts"` there instead — grep for `static_paths` to find the source of truth.

- [ ] **Step 2: Fetch woff2 files into `priv/static/fonts/`.** These are OFL-licensed (Geist, Instrument Serif). Download from a pinned source (e.g. the Vercel `geist-font` GitHub release for Geist/GeistMono, Google Fonts for Instrument Serif). Required files:
  - `Geist-Regular.woff2` (400), `Geist-Medium.woff2` (500), `Geist-SemiBold.woff2` (600), `Geist-Bold.woff2` (700)
  - `GeistMono-Regular.woff2` (400), `GeistMono-Medium.woff2` (500)
  - `InstrumentSerif-Regular.woff2` (400), `InstrumentSerif-Italic.woff2` (italic 400)

```bash
mkdir -p priv/static/fonts
# fetch each woff2 into priv/static/fonts/ (pin versions; verify license = OFL)
ls -la priv/static/fonts
```

- [ ] **Step 3: Verify the route serves the file.** Run a controller/conn test (added in Task 0.5) or manually: `curl -sI http://localhost:4000/fonts/Geist-Regular.woff2 | head -1` → Expected: `HTTP/1.1 200 OK`.

- [ ] **Step 4: Commit.**

```bash
git add priv/static/fonts lib/slackex_web/endpoint.ex
git commit -m "feat(loom): self-host Geist + Instrument Serif woff2 fonts"
```

---

### Task 0.3: Create `loom.css` — fonts, tokens, and the daisyUI variable remap (the engine)

**Files:**
- Create: `assets/css/loom.css`
- Modify: `assets/css/app.css` (append import)

- [ ] **Step 1: Write `assets/css/loom.css` foundation.** This is the whole-UI re-palette plus Loom token definitions. Complete content for this step:

```css
/* Loom — scoped visual layer for the chat redesign (:loom_redesign).
   Everything lives under `.loom`. Re-maps daisyUI theme vars to the Loom
   palette, then adds weave/serif/gold touches via targeted selectors. */

/* ---- Self-hosted fonts ---- */
@font-face { font-family:"Geist"; font-weight:400; font-style:normal; font-display:swap; src:url("/fonts/Geist-Regular.woff2") format("woff2"); }
@font-face { font-family:"Geist"; font-weight:500; font-style:normal; font-display:swap; src:url("/fonts/Geist-Medium.woff2") format("woff2"); }
@font-face { font-family:"Geist"; font-weight:600; font-style:normal; font-display:swap; src:url("/fonts/Geist-SemiBold.woff2") format("woff2"); }
@font-face { font-family:"Geist"; font-weight:700; font-style:normal; font-display:swap; src:url("/fonts/Geist-Bold.woff2") format("woff2"); }
@font-face { font-family:"Geist Mono"; font-weight:400; font-style:normal; font-display:swap; src:url("/fonts/GeistMono-Regular.woff2") format("woff2"); }
@font-face { font-family:"Geist Mono"; font-weight:500; font-style:normal; font-display:swap; src:url("/fonts/GeistMono-Medium.woff2") format("woff2"); }
@font-face { font-family:"Instrument Serif"; font-weight:400; font-style:normal; font-display:swap; src:url("/fonts/InstrumentSerif-Regular.woff2") format("woff2"); }
@font-face { font-family:"Instrument Serif"; font-weight:400; font-style:italic; font-display:swap; src:url("/fonts/InstrumentSerif-Italic.woff2") format("woff2"); }

/* ---- Loom tokens + daisyUI var remap (dark) ---- */
.loom {
  /* Loom-only tokens used by targeted selectors below */
  --accent:#e8c547;
  --accent-soft:rgba(232,197,71,.33);
  --accent-wash:rgba(232,197,71,.08);
  --copper:#d97757;
  --jade:#6fb59a;
  --ok:#7fb59a;
  --line:rgba(232,220,185,.10);
  --line-strong:rgba(232,220,185,.18);
  --ff-sans:"Geist",ui-sans-serif,system-ui,-apple-system,sans-serif;
  --ff-mono:"Geist Mono",ui-monospace,"SF Mono",monospace;
  --ff-serif:"Instrument Serif",Georgia,serif;

  /* Re-map daisyUI theme vars → Loom palette (warm charcoal + gold).
     Every existing bg-base-*/text-base-content/btn/badge/input picks these up. */
  --color-base-100:#131109;   /* primary panels: headers, composer, modals */
  --color-base-200:#16140d;   /* sidebar / secondary surfaces */
  --color-base-300:#2a2519;   /* borders (border-base-300) + insets */
  --color-base-content:#f2ecdc;
  --color-primary:#e8c547;        --color-primary-content:#1a160c;
  --color-secondary:#d97757;      --color-secondary-content:#1a160c;
  --color-accent:#e8c547;         --color-accent-content:#1a160c;
  --color-neutral:#221e15;        --color-neutral-content:#f2ecdc;
  --color-info:#7fb59a;           --color-info-content:#0b0a07;
  --color-success:#7fb59a;        --color-success-content:#0b0a07;
  --color-warning:#e8c547;        --color-warning-content:#1a160c;
  --color-error:#e07c6e;          --color-error-content:#1a160c;

  --radius-selector:0.4375rem;  /* 7px */
  --radius-field:0.4375rem;
  --radius-box:0.625rem;        /* 10px */
  --border:0.5px;               /* hairline borders are core to Loom */
  --depth:0;
  --noise:0;

  /* canvas + base type */
  background:#0b0a07;            /* --bg-deep, deeper than base-100 panels */
  color:var(--color-base-content);
  font-family:var(--ff-sans);
  -webkit-font-smoothing:antialiased;
}

/* ---- Global weave texture overlay (subtle) ---- */
.loom .loom-weave-bg {
  position:absolute; inset:0; pointer-events:none; z-index:0; mix-blend-mode:screen;
  background-image:
    repeating-linear-gradient(90deg, transparent 0, transparent 11px, rgba(232,197,71,.06) 11px, rgba(232,197,71,.06) 12px),
    repeating-linear-gradient(0deg,  transparent 0, transparent 11px, rgba(232,197,71,.025) 11px, rgba(232,197,71,.025) 12px);
}
/* keep real content above the texture */
.loom > :not(.loom-weave-bg) { position:relative; z-index:1; }
```

- [ ] **Step 2: Import it from `app.css`.** Append at the very end of `assets/css/app.css` (after line 217):

```css
@import "./loom.css";
```

- [ ] **Step 3: Build CSS and verify the remap reaches the output.** Run: `mix tailwind slackex`
Then confirm Loom rules made it into the built file:

```bash
grep -c "\.loom" priv/static/assets/css/app.css   # Expected: > 0
grep -c "Instrument Serif" priv/static/assets/css/app.css  # Expected: >= 1 (font-face survived)
```

- [ ] **Step 4: Verify `.loom` overrides win over daisyUI.** Because we override the *variables* daisyUI consumes (not its rule selectors), there is no specificity fight for colors. For the few targeted rules added later, `.loom .x` (0,2,0) beats daisyUI's `.x` (0,1,0). Sanity-check by loading the app with the flag on (Task 5) — if any color fails to shift, the cause is import order: ensure `@import "./loom.css"` is the LAST import in `app.css` so its `.loom { --color-* }` declarations are not preceded-and-overridden within the same layer.

- [ ] **Step 5: Commit.**

```bash
git add assets/css/loom.css assets/css/app.css
git commit -m "feat(loom): add scoped Loom CSS layer with daisyUI var remap + fonts"
```

---

### Task 0.4: Apply serif/mono type + hairline borders globally within `.loom`

**Files:** Modify `assets/css/loom.css`

- [ ] **Step 1: Append base-typography rules** (these need DOM hooks that already exist or are added in Phase 1; safe to define now):

```css
/* Timestamps everywhere render mono (message <time>, dividers) */
.loom time,
.loom .loom-mono { font-family:var(--ff-mono); letter-spacing:.02em; }

/* kbd chips */
.loom kbd { font-family:var(--ff-mono); background:#2a2519; border:0.5px solid var(--line); }
```

- [ ] **Step 2: Build + commit.**

```bash
mix tailwind slackex
git add assets/css/loom.css
git commit -m "feat(loom): mono timestamps + kbd styling"
```

---

### Task 0.5: Flag-gating regression test + font route test

**Files:** Create `test/slackex_web/live/chat_live/loom_redesign_test.exs`

- [ ] **Step 1: Write the failing test.** Asserts the `loom` class appears on the chat root only when the flag is enabled for the user. Use the project's existing LiveView test helpers (copy auth/login setup from a neighbouring test in `test/slackex_web/live/chat_live/`).

```elixir
defmodule SlackexWeb.ChatLive.LoomRedesignTest do
  use SlackexWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    user = Slackex.AccountsFixtures.user_fixture()  # use the real fixture name in this repo
    %{user: user}
  end

  test "chat root has no loom class when flag disabled", %{conn: conn, user: user} do
    FunWithFlags.disable(:loom_redesign)
    {:ok, _lv, html} = conn |> log_in_user(user) |> live(~p"/chat")
    refute html =~ ~s(id="chat-container" )  # placeholder; assert class absence precisely below
    assert html =~ "chat-container"
    refute html =~ "flex h-full relative loom" |> String.replace("  ", " ")
  end

  test "chat root has loom class when flag enabled for actor", %{conn: conn, user: user} do
    FunWithFlags.enable(:loom_redesign, for_actor: user)
    {:ok, _lv, html} = conn |> log_in_user(user) |> live(~p"/chat")
    assert html =~ "loom"
  end
end
```

> NOTE: refine the assertions to match the exact rendered class string (inspect output once). The point is a real on/off guard, not string golf. Disable the flag in an `on_exit` to avoid leaking global state (FunWithFlags persists to the test DB; `:async false` + cleanup).

- [ ] **Step 2: Run — expect pass** (the markup from Task 0.1 already implements both branches): `mix test test/slackex_web/live/chat_live/loom_redesign_test.exs` — Expected: PASS. If the disabled-case assertion is too loose, tighten it.

- [ ] **Step 3: Font route test (optional but cheap).** Add a `SlackexWeb.ConnCase` test: `get(conn, "/fonts/Geist-Regular.woff2")` → `conn.status == 200`. Skip if fonts aren't committed yet in this branch.

- [ ] **Step 4: Commit.**

```bash
git add test/slackex_web/live/chat_live/loom_redesign_test.exs
git commit -m "test(loom): flag-gating regression guard for chat root"
```

---

# Phase 1 — Surface restyles (dark)

> Each task = small additive markup hooks (gated by `@loom` where the element is net-new) + one cohesive CSS block appended to `loom.css`. After each: `mix tailwind slackex`, then a manual in-browser check (flag on) of that surface. Commit per surface.

### Task 1.1: Sidebar

**Files:** `lib/slackex_web/live/chat_live/sidebar_component.ex`, `assets/css/loom.css`

- [ ] **Step 1: Add a stable hook class.** On the root `<aside class="flex flex-col h-full bg-base-200">` add `chat-sidebar`:
`<aside class="chat-sidebar flex flex-col h-full bg-base-200">`. (Unconditional — harmless when flag off.)

- [ ] **Step 2: Make the workspace title serif.** The `<h1>Tenun</h1>` (line ~70) → add class `loom-wordmark`: `<h1 class="loom-wordmark ...">`.

- [ ] **Step 3: Append CSS:**

```css
/* Sidebar: gradient bg + golden warp thread down the right edge */
.loom .chat-sidebar {
  background:linear-gradient(180deg,#131109 0%,#16140d 100%);
  border-right:0.5px solid var(--line);
  position:relative;
}
.loom .chat-sidebar::after {
  content:''; position:absolute; top:0; bottom:0; right:-0.5px; width:1px; pointer-events:none;
  opacity:.4;
  background:linear-gradient(180deg,transparent 0,var(--accent-soft) 20%,transparent 35%,var(--accent-soft) 55%,transparent 70%,var(--accent-soft) 88%,transparent 100%);
}
.loom .loom-wordmark { font-family:var(--ff-serif); font-style:italic; font-weight:400; letter-spacing:.005em; }
/* active channel: gold wash + inset bar (existing active classes use bg-base-300/primary) */
.loom .chat-sidebar .menu li > .active,
.loom .chat-sidebar [aria-current="page"] {
  background:var(--accent-wash); box-shadow:inset 2px 0 0 var(--accent); color:var(--color-base-content);
}
```

> NOTE: confirm the active-channel element/class in `channel_list_item/1` (it uses `.link patch=...` + an active style). Target whatever class marks active; adjust the selector above to match the real one (read `chat_components.ex:66-84`).

- [ ] **Step 4:** `mix tailwind slackex`; load `/chat` with flag on; verify sidebar gradient, golden edge, serif wordmark, active-channel gold wash. Commit.

### Task 1.2: Channel header (+ Summarize button as "The Loom")

**Files:** `lib/slackex_web/components/chat_components.ex` (`conversation_header/1`, lines 513-531), `assets/css/loom.css`

- [ ] **Step 1: Hook the title.** Add class `chat-title` to the `<h2>`: `<h2 class="chat-title ...">{@title}</h2>`. (Default decision: whole title serif italic incl. `#`.)
- [ ] **Step 2: Append CSS:**

```css
.loom .chat-title { font-family:var(--ff-serif); font-style:italic; font-weight:400; font-size:1.4rem; letter-spacing:-.005em; }
.loom .conversation-subtitle, .loom .chat-title + p { color:#80785f; }
/* header bar */
.loom .chat-header, .loom [data-role="conversation-header"] { background:linear-gradient(180deg,#131109,#0b0a07); border-bottom:0.5px solid var(--line); }
/* Summarize button → gold-washed AI affordance */
.loom [data-role="summarize-button"] { background:linear-gradient(135deg,var(--accent-wash),transparent); border:0.5px solid var(--accent-soft); color:var(--color-base-content); border-radius:var(--radius-field); }
.loom [data-role="summarize-button"]:hover { border-color:var(--accent); }
```

> NOTE: add `data-role="conversation-header"` (or class `chat-header`) to the header root in `conversation_header/1` so the bar selector has a hook.

- [ ] **Step 3:** Build; verify serif italic channel name, gold Summarize button. Commit.

### Task 1.3: Message rows

**Files:** `chat_components.ex` (`message_bubble/1` 157-403, `reaction_bar/1` 407-433, `time_divider/1` 143-153), `assets/css/loom.css`

- [ ] **Step 1: Hooks (additive, safe when flag off):**
  - `reaction_bar/1` root `<div class="flex flex-wrap gap-1">` → add `reaction-bar`; each reaction `<button>` → add `reaction` (keep all `phx-click="toggle_reaction"` + `phx-value-*` exactly).
  - sender name span → add `msg-name`; bot/system AI label (if present) → add `msg-ai-label`.
- [ ] **Step 2: Append CSS:**

```css
/* sender name + timestamp */
.loom .msg-name { font-weight:600; color:var(--color-base-content); }
.loom #message-list time { font-family:var(--ff-mono); font-size:10.5px; color:#56503e; }
/* day divider → dashed thread line + mono pill */
.loom .time-divider-label, .loom [data-role="time-divider"] span { font-family:var(--ff-mono); font-size:11px; color:#80785f; }
/* reactions as woven pills */
.loom .reaction { border-radius:999px; border:0.5px solid var(--line); background:#1b1810; font-family:var(--ff-mono); font-size:11.5px; padding:2px 7px 2px 5px; transition:transform .15s,border-color .15s; }
.loom .reaction:hover { transform:translateY(-1px); border-color:var(--line-strong); }
.loom .reaction.is-mine, .loom .reaction[aria-pressed="true"] { background:var(--accent-wash); border-color:var(--accent-soft); color:var(--accent); }
/* hover action bar */
.loom [data-role="message-actions"] { background:#1b1810; border:0.5px solid var(--line); border-radius:var(--radius-field); box-shadow:0 8px 24px rgba(0,0,0,.32); }
/* AI/bot serif label */
.loom .msg-ai-label { font-family:var(--ff-serif); font-style:italic; color:var(--accent); }
/* code blocks + inline code already pick up base-200; tighten */
.loom #message-list pre, .loom #message-list code { font-family:var(--ff-mono); }
.loom #message-list :not(pre) > code { color:var(--accent); }
```

> NOTE: the "is-mine" reaction marker — check how `reaction_bar/1` flags the current user's reaction (contract sheet: button class flips when `@current_user_id in reaction.user_ids`). Add a stable `is-mine` class in that branch so the selector matches; don't rely on `aria-pressed` unless it's actually emitted.

- [ ] **Step 3:** Build; verify message grid, mono timestamps, woven reaction pills, hover bar, code styling. Commit.

### Task 1.4: Composer

**Files:** `chat_components.ex` (`compose_area/1` 641-665), `assets/css/loom.css`

- [ ] **Step 1: Hook.** Wrapper `<div class="p-3 border-t ...">` → add `chat-composer`. Send `<button>` → add `loom-send`.
- [ ] **Step 2: Append CSS:**

```css
.loom .chat-composer { background:#0b0a07; }
.loom .chat-composer textarea, .loom #message-form textarea {
  background:#1b1810; border:0.5px solid var(--line); border-radius:var(--radius-box);
  font-family:var(--ff-sans);
}
.loom .chat-composer textarea:focus, .loom #message-form textarea:focus {
  border-color:var(--accent-soft); box-shadow:0 0 0 3px var(--accent-wash); outline:0;
}
.loom .chat-composer textarea::placeholder { font-family:var(--ff-serif); font-style:italic; color:#56503e; }
.loom .loom-send { background:var(--accent); color:#1a160c; font-weight:600; border-radius:var(--radius-field); }
.loom .loom-send:hover { filter:brightness(1.08); }
```

- [ ] **Step 3:** Build; verify woven input, gold focus ring, serif placeholder, gold Send. Commit.

### Task 1.5: Thread panel (weft strands)

**Files:** `thread_panel_component.ex` (header 50-57, replies 69-84, composer 87-108), `assets/css/loom.css`

- [ ] **Step 1: Gated weft element.** Above the replies list, add (only when `@loom`):

```heex
<svg :if={@loom} class="loom-weft" viewBox="0 0 200 20" preserveAspectRatio="none" width="100%" height="14" aria-hidden="true">
  <line :for={i <- 0..4} x1="0" x2="200" y1={(i + 0.5) * 4} y2={(i + 0.5) * 4}
        stroke="var(--accent)" stroke-width="1.3" stroke-dasharray="2 4" opacity="0.5" />
</svg>
```

(Static 5 strands — purely decorative; no dependency on reply count. Add `attr :loom, :boolean, default: false`.)

- [ ] **Step 2: Hook + CSS.** Add `thread-title` to the `<h3>Thread</h3>`. Append:

```css
.loom [data-role="thread-panel"], .loom .thread-panel { background:linear-gradient(180deg,#131109,#16140d); border-left:0.5px solid var(--line); }
.loom .thread-title { font-family:var(--ff-serif); font-style:italic; }
.loom .loom-weft { display:block; padding:0 16px; }
```

(Add `thread-panel` class or `data-role="thread-panel"` to the panel root for the bg hook.)

- [ ] **Step 3:** Build; open a thread with flag on; verify weft strands, serif "Thread" title, panel bg. Commit.

### Task 1.6: Summary modal → "The Loom" (restyle only)

**Files:** `summary_modal.ex` (48-119), `assets/css/loom.css`

- [ ] **Step 1: Gated loom-mark + serif heading.** Add `loom-sum-title` class to the `<h3>Channel Summary</h3>`. Optionally prepend a gated loom mark span before it.
- [ ] **Step 2: Gated loom-loader.** In the `:loading` branch, replace the daisyUI spinner with a gated loom-loader SVG (keep the spinner as the `@loom`-false fallback):

```heex
<.loom_loader :if={@loom} />
<span :if={!@loom} class="loading loading-spinner"></span>
```

Define `loom_loader/1` as a small function component in this module (animated warp/weft SVG — copy from the design's `LoomLoader`). Keep streamed `@summary_text` rendering unchanged.

- [ ] **Step 3: Append CSS:**

```css
.loom .loom-sum-title { font-family:var(--ff-serif); font-style:italic; font-weight:400; }
.loom .loom-loader { color:var(--accent); width:40px; height:40px; }
/* the modal container already uses bg-base-100 → re-palettes for free */
```

- [ ] **Step 4:** Build; open Summarize with flag on; verify serif heading, loom-loader during generation, gold accents. Confirm the three dismiss mechanisms still work (backdrop/Escape/X). Commit.

### Task 1.7: Quick switcher → ⌘K palette

**Files:** `quick_switcher_modal.ex` (input 105-115, results 118-139), `assets/css/loom.css`

- [ ] **Step 1: Hooks.** Add `loom-palette` to the inner panel div; `loom-palette-input` to the `<input>`; keep `phx-keyup="search"`, `phx-click="navigate"`, `phx-value-to`, `phx-target={@myself}` exactly. The result item already branches on `item.type` (`:channel` / `:dm`) — style those kind glyphs (no new markup needed beyond a class on each glyph span).
- [ ] **Step 2: Append CSS:**

```css
.loom .loom-palette { background:#131109; border:0.5px solid var(--line-strong); border-radius:var(--radius-box); }
.loom .loom-palette-input { font-family:var(--ff-serif); font-style:italic; font-size:18px; background:transparent; }
.loom .loom-palette .menu-active, .loom .loom-palette [aria-selected="true"] { box-shadow:inset 2px 0 0 var(--accent); background:#221e15; }
```

- [ ] **Step 3:** Build; open ⌘K with flag on; verify serif italic prompt, item styling, keyboard nav intact. Commit.

### Task 1.8: Search component

**Files:** `search_component.ex` (109-200), `assets/css/loom.css`

- [ ] **Step 1:** Add `loom-search` to the panel root `<div ...w-80>`. Keep all `phx-*` (`search`, `set_mode`, `jump_to_message`, `close_search`) and `phx-value-*` intact.
- [ ] **Step 2: Append CSS:**

```css
.loom .loom-search { background:#131109; border-left:0.5px solid var(--line); }
.loom .loom-search mark { background:var(--accent); color:#1a160c; }
/* mode buttons + results inherit btn/base re-palette */
```

- [ ] **Step 3:** Build; open search with flag on; run a query; verify match highlight in gold, mode buttons, jump-to works. Commit.

---

# Phase 2 — Empty/edge surfaces

### Task 2.1: Empty state, typing indicator, "join channel" footer, mobile drawer

**Files:** `chat_components.ex` (`empty_state/1`, `typing_indicator/1`), `index.html.heex` (no-conversation + can't-send blocks), `assets/css/loom.css`

- [ ] **Step 1:** Add `loom-empty` to `empty_state` root; `loom-typing` to `typing_indicator` root.
- [ ] **Step 2: Append CSS:**

```css
.loom .loom-empty h2, .loom .loom-empty .empty-title { font-family:var(--ff-serif); font-style:italic; }
.loom .loom-typing { font-family:var(--ff-mono); font-size:10.5px; color:#80785f; }
.loom .loom-typing i, .loom .loom-typing .dot { background:var(--accent); }
```

- [ ] **Step 3:** Verify empty state (no channel selected), typing indicator, the mobile sidebar drawer (`-translate-x-full` toggle) still slides and looks right under Loom. Commit.

---

# Phase 3 — Responsive & PWA integrity (hard constraint)

### Task 3.1: Confirm mobile, safe-area insets, and PWA chrome survive Loom

- [ ] **Step 1: Mobile breakpoints.** At <768px, verify: sidebar is the off-canvas drawer (not the desktop 3-pane); backdrop tap closes it; thread panel goes full-width (`w-full md:w-[400px]`). No horizontal scroll.
- [ ] **Step 2: Safe-area insets.** `chat.html.heex` main uses `pt-[env(safe-area-inset-top)]` etc. Confirm Loom backgrounds extend under the notch (the `.loom` canvas bg should paint the inset area). If a seam appears, set the inset container bg under `.loom`.
- [ ] **Step 3: Standalone PWA.** Launch installed PWA (or emulate `display-mode: standalone`); confirm the warm-charcoal canvas reads correctly against the OS chrome and the offline page still matches.
- [ ] **Step 4:** No code unless a seam is found; if so, add a minimal `.loom` rule and commit.

---

# Phase 4 — Light variant (fast-follow)

### Task 4.1: Light Loom token overrides

**Files:** `assets/css/loom.css`

- [ ] **Step 1:** The app toggles light/dark via `data-theme` (theme.js). Add light overrides scoped to both `.loom` and the light theme:

```css
.loom:where([data-theme="light"], [data-theme="light"] *),
[data-theme="light"] .loom {
  --color-base-100:#fbf7eb;
  --color-base-200:#f3eedd;
  --color-base-300:rgba(40,32,12,.14);
  --color-base-content:#1a160c;
  --accent-wash:rgba(232,197,71,.20);
  --line:rgba(40,32,12,.10);
  --line-strong:rgba(40,32,12,.18);
  background:#f6f1e2;
}
.loom:where([data-theme="light"]) .chat-sidebar { background:linear-gradient(180deg,#fbf7eb,#f3eedd); }
.loom:where([data-theme="light"]) .loom-weave-bg { mix-blend-mode:multiply; background-image:
  repeating-linear-gradient(90deg,transparent 0,transparent 11px,rgba(120,90,0,.05) 11px,rgba(120,90,0,.05) 12px),
  repeating-linear-gradient(0deg, transparent 0,transparent 11px,rgba(120,90,0,.02) 11px,rgba(120,90,0,.02) 12px); }
```

> NOTE: confirm the exact selector daisyUI/theme.js sets (`html[data-theme="light"]`). The `.loom` element is *inside* `<html>`, so `[data-theme="light"] .loom` is the reliable form. Verify and keep only the form that wins.

- [ ] **Step 2:** Build; toggle theme (sidebar moon/sun button → `JS.dispatch("phx:set-theme", detail: %{toggle:true})`); verify every Phase 1 surface in light. Commit.

---

# Phase 5 — Verification & rollout

### Task 5.1: Full verification pass

- [ ] **Step 1: Static gates.** Run: `mix format`, `mix credo --strict` (if used in CI), `mix compile --warnings-as-errors`. Expected: clean.
- [ ] **Step 2: Test suite.** `docker compose up -d postgres_test redis && mix test`. Expected: all pass (existing tests exercise the flag-OFF look; the new Loom test covers flag-ON). Confirm count didn't drop.
- [ ] **Step 3: CSS asset build.** `mix assets.build`. Expected: success; `priv/static/assets/css/app.css` contains `.loom` rules and font-faces.
- [ ] **Step 4: Manual in-browser checklist (flag ON, dark).** Walk each surface and confirm against the design screenshots: sidebar (gradient, golden edge, serif wordmark, active wash) · header (serif italic channel, gold Summarize) · messages (mono timestamps, woven reaction pills, hover bar, code) · composer (woven input, gold focus, serif placeholder, gold Send) · thread (weft, serif title) · summary (serif heading, loom-loader, dismiss ×3) · ⌘K palette (serif prompt, nav) · search (gold highlight). Confirm **flag OFF** still renders the unchanged daisyUI look.
- [ ] **Step 5: Pre-deploy.** Run `scripts/pre-deploy` (the 7-step gate). Then deploy per `/deploy` (tag). After deploy, enable `:loom_redesign` for your own actor at `/admin/flags`; dogfood in prod before any wider rollout.

### Task 5.2 (OUT OF SCOPE — future, after bake)

Once `:loom_redesign` is at 100% and stable for a sustained period, a separate effort should: remove the flag conditionals, delete the old daisyUI purple/orange theme blocks from `app.css` if Loom becomes the default, fold `loom.css` into the base theme, and drop the dead `:new_ui` DB row. **Do not do this now** — the flag is the safety net.

**PWA chrome (global, can't be flag-gated — defer to this cutover):** update the warm-charcoal/gold palette in the surfaces that sit *outside* `.loom` and apply to all users:
- `lib/slackex_web/components/layouts/root.html.heex` — `<meta name="theme-color">` (currently `#5D4D8F` dark / `#E8A835` light) → charcoal; and `apple-mobile-web-app-status-bar-style` `default` → `black-translucent`.
- `priv/static/manifest.json` — `theme_color` / `background_color` (currently `#2A2640` / `#5D4D8F`) → Loom charcoal/gold.
- `lib/slackex_web/controllers/offline_controller.ex` — the offline page is static + outside `.loom` (old purple/orange `#2A2640`/`#5D4D8F`/`#E8A835`); recolor to the Loom palette so it doesn't jar against the app.
Changing these *before* the cutover would mis-color the PWA status bar / splash / offline screen for non-Loom prod users — that's why they wait. (Identified in the 2026-05-27 mobile/PWA audit.)

---

## Self-Review

- **Spec coverage:** sidebar ✓ (1.1), header ✓ (1.2), messages incl. code/reactions/unfurl/bot ✓ (1.3), composer ✓ (1.4), thread + weft ✓ (1.5), summary/"Loom" + loom-loader ✓ (1.6), ⌘K palette ✓ (1.7), search ✓ (1.8), weave texture ✓ (0.3), serif AI moments ✓ (1.3/1.6), fonts ✓ (0.2/0.3), flag ✓ (0.1), light ✓ (4.1). Deferred-by-decision: warp activity bars, pinned-summaries rail, semantic palette, structured summary citations — explicitly out of scope, not gaps.
- **Placeholder scan:** CSS blocks are concrete. Two honest "read-the-real-class-and-adjust-the-selector" NOTEs (active-channel marker in 1.1/1.3, theme selector form in 4.1) — these require reading 3 specific functions at execution time; the target CSS is given, only the hook name is confirmed live. This is intentional, not a placeholder.
- **Type/consistency:** flag name `:loom_redesign` and assign `@loom` used consistently; `loom` attr added to every child component that reads it; hook class names (`chat-sidebar`, `chat-title`, `chat-composer`, `reaction`/`reaction-bar`, `thread-title`, `loom-palette`, `loom-search`) are unique and used in both markup and CSS.

---

## Execution Handoff

Plan saved to `docs/superpowers/plans/2026-05-26-loom-redesign.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session with checkpoints for review.

Which approach?
