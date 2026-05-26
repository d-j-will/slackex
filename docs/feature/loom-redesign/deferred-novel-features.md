# Loom Redesign — Deferred Novel Features

These are the novel touches from the "Loom" design (claude.ai/design handoff, 2026-05-26) that were **deliberately deferred** from the initial restyle effort because they require backend/data work we don't have yet. The initial effort (see `docs/superpowers/plans/2026-05-26-loom-redesign.md`) restyles existing surfaces + adds *cheap aesthetic* weave touches only.

Source design bundle components are referenced by their prototype filenames (the React/HTML mockup), kept for fidelity when we pick these up.

---

## 1. Warp activity bars (sidebar channel rows)

**What:** Each channel row shows 3 small "warp" bars filled in proportion to how active the channel is (0..1). The more active, the more bars lit in gold.

**Design ref:** `WarpActivity` component (`icons.jsx`); `CHANNELS[].activity` field in `data.js` (e.g. `deploys: 0.92`).

**Backend needed:** a per-channel activity metric. Candidates: trailing-window message volume (e.g. messages in last 24h normalized across channels), or unread velocity. Compute server-side and pass `activity` into `channel_list_item/1`.

**Effort:** small-medium (one query/metric + a tiny SVG component + sidebar wiring).

**Why deferred:** rendering bars off fake/constant data would imply information we don't track. Per the data-contract-honesty rule, don't ship a "get activity" affordance with no real source.

---

## 2. Pinned-summaries rail ("The Loom · pinned summaries" sidebar section)

**What:** A sidebar section under DMs listing saved AI summaries, each with a gold/copper "strand" marker and relative time ("v2.41 release train · 5m", "Q2 retro · highlights · 2d"). Clicking reopens the summary.

**Design ref:** `sidebar.jsx` (`sb-section--ai`); the summary drawer footer action **"Pin to sidebar"** (`summarize.jsx`).

**Backend needed:** persistence for summaries (a `summaries` table or a "pinned summary" record keyed to channel + range + generated text), plus a "pin" action wired from the summary modal footer, plus a list query for the sidebar.

**Effort:** medium (schema + migration + context fns + sidebar section + pin action).

**Why deferred:** no summary persistence exists today — summaries are generated on demand and streamed, not stored.

---

## 3. Structured summary with strands + citations ("The Loom" drawer)

**What:** The Summarize output reframed as "The Loom": grouped sub-threads, each with a strand swatch per participating voice, bullet points that carry source-message citations (`{from_id, to_id}`) you can click to jump back to the original message (which briefly highlights), a "Voices" legend, and a Followups list where each item has a **"Make task"** action. A woven `LoomLoader` plays while gathering.

**Design ref:** `summarize.jsx`; `SUMMARY` data shape in `data.js` (threads → points → src ids; followups).

**Backend needed:** the summariser must emit **structured output** (threads/points/source-id-ranges) instead of plain streamed prose — i.e. a JSON schema from the model, validated server-side. Plus: a citation→scroll-to-message mechanism (jump + highlight-flash already exists for search), and a Followups → task model if "Make task" is real.

**Effort:** large (prompt + structured-output parsing + schema + LiveView wiring + citation jump). This is the design's signature AI feature and the highest-value follow-up.

**Why deferred:** the live modal streams plain/markdown text. The structured layout cannot be faithfully reproduced without changing what the summariser returns. The loom-loader (cheap, pure SVG) IS shipped in the initial restyle; the structure is not.

**Note:** the initial restyle already maps Summarize → a right-side drawer with serif heading + loom-loader, so the container is "Loom-ready" for this upgrade.

---

## 4. Semantic ⌘K palette

**What:** The command palette (⌘K) accepts natural-language queries ("that thing mina said about embeddings") and returns kind-classified results — semantic message hits, channels, people, actions — with a "powered by pgvector + claude" footer.

**Design ref:** `CommandPalette` in `app.jsx`.

**Backend needed:** wire the existing pgvector semantic search (`:message_search`) into the quick switcher's result set; classify/merge results by kind (semantic vs channel vs DM vs action). Most of the retrieval already exists in `search_component.ex` — this is about surfacing it in the palette.

**Effort:** medium (the search backend exists; the work is merging result sources + ranking + palette UI for mixed kinds).

**Why deferred:** the current quick switcher does channel/DM fuzzy match only. Adding semantic results is a behavioral change, not a restyle.

---

## 5. `/assist` composer affordance

**What:** An inline AI-assist control in the composer that surfaces semantic-search teasers ("related from this channel: jules · chunked summariser PR…") as you type.

**Design ref:** `composer.jsx` (`composer-ai`, `cmp-tool--ai`).

**Backend needed:** semantic retrieval on draft content + a suggestion UI.

**Effort:** medium.

**Why deferred / skipped from the restyle:** adding a visible `/assist` button implies unbuilt AI functionality. We intentionally did **not** add it as a decorative affordance — better to ship it when it does something.

---

## 6. (Minor) Per-reply weft visualization in threads

**What:** The thread panel's "weft" strands map one strand per reply, colored by author, rather than the static 5-strand decoration shipped in the initial restyle.

**Design ref:** `composer.jsx` `Thread` weft SVG (one `<line>` per `THREAD_MESSAGES` entry, `stroke = author color`).

**Backend needed:** none new — just render strands from the actual `@replies` list + author colors.

**Effort:** small. Could fold into the initial effort later as a refinement; deferred only to keep the first pass static and low-risk.

---

## Pick-up order (suggested)

1. **#3 structured summary citations** — signature feature, highest user value, container already Loom-ready.
2. **#4 semantic palette** — leverages existing search backend.
3. **#1 warp activity bars** — small, high visual payoff once a metric exists.
4. **#2 pinned-summaries rail** — depends on summary persistence (pairs with #3).
5. **#6 per-reply weft** — small refinement.
6. **#5 /assist** — last; largest UX surface, depends on #4's retrieval.
