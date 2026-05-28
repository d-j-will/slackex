# Sous Slice B1 — Role-Lens + Attention Triage + Facet Drawer (Design Spec)

**Date:** 2026-05-28
**Status:** Approved (brainstorm) — ready for implementation planning
**Feature:** Sous (provisional brand).
**Related:** Slice A spec (`./slice-a-event-stream-tracer-bullet.md`), ADR-001, ADR-002. Source thesis: `docs/feature/sous/sous-brainstorm.md`, handoff `docs/feature/sous/handoff/README.md`.

---

## 1. Goal

Prove the "same stream, role-shaped lens" thesis end-to-end **without** the AI facet pipeline.
Slice A delivered the event-stream spine for a single, hard-coded viewer; B1 introduces a
data-driven **viewer/role** model, a **"Reading as"** switcher, **per-(viewer, work_item) attention**
set by manual triage, and the **Facet Drawer** ("same atom through each prism"). The In Service
board reshapes per role (items rise / sink / hide); switching viewer is a cheap view transform over
the same underlying stream.

The AI-generated per-role facet *text* (the "right-sized prose" each role sees) is deliberately
**deferred to B2** — B1 establishes the data model and UI; B2 fills the `facet_text` column via
the existing API-based `LLMClient` in an isolated Oban pipeline.

## 2. Scope

### In scope
- `Slackex.Sous.Viewer` schema — **data-driven** role-lenses (name, color, focus, position),
  seeded with a default set. Configurable via seeds/migration; no management UI in B1.
- `Slackex.Sous.WorkItemFacet` schema — composite PK `(work_item_id, viewer_id)`, `attention` +
  (nullable) `facet_text` (B2 fills the text). Lazy rows: absent = default `:watch`.
- New event type `:attention_set` with payload `{viewer_id, attention, actor_user_id}`. Projection
  extended; existing single-write-path / atomic-Multi / append-only / self-describing invariants
  apply (Slice A §6).
- **"Reading as" switcher** in the In Service board top bar, backed by an encapsulated
  `Slackex.Sous.ViewerPreference` (behaviour + store); B1 ships a `LocalStorage` store (sticky per
  browser via a JS hook). A future DB-backed store is a one-line config swap — proven by an
  `InMemoryStore` swap-test (see §9).
- **Board reshaping** by the active viewer's attention map: `:act` rises and shows accent edge +
  "behind"; `:watch` default; `:know` dashed/dimmed/compact, sinks; `:hidden` not rendered with a
  session-only "+N not at your altitude" toggle.
- **Facet Drawer** triggered by clicking a card on the board. Top: the work item once (shared
  content — title / What / Why / Next / DRI). Below: a grid of prisms, one per viewer, each with
  the viewer's name + color + the current attention pill. Hidden prisms render as dashed-italic
  "not at this altitude" with a "Show hidden" toggle.
- **Triage** action lives **primarily in the Facet Drawer** (the natural place — you're looking at
  the atom across roles) and as a compact menu on the board card. A 4-pill **selector** (not
  click-to-cycle) lets the actor set each viewer's attention; each change is an `:attention_set`
  event.
- Continued behind the `:sous` flag.

### Out of scope (deferred — do not pull in)
- **AI facet text** — the per-prism right-sized prose. **B2.**
- **Role management UI** — admin to create/edit/remove role-lenses. Roles remain seeded data,
  editable via seeds/admin console. **B-later.**
- **ACL on triage** — any authenticated user can set attention on any role for any work item in
  B1 (single-team internal scope). **B-later if multi-team / privacy boundaries matter.**
- **Linking roles to users** — viewers stay abstract role-lenses (not tied to user accounts) so
  one user can demo all lenses. **B-later if needed.**
- **Lensing surfaces other than the board + drawer** — chat decision cards stay shared / un-lensed
  in B1. **B-later.**
- **Persisted "+N hidden" toggle** — session-only in B1; encapsulating it as a second user
  preference is a **B-later** increment (alongside the `ViewerPreference` seam).

## 3. Decisions carried from brainstorm

| Decision | Choice | Rationale |
|---|---|---|
| Decompose Slice B | Lens + drawer first (B1), AI facets next (B2) | Concentrates AI cost/latency/prod-constraint risk into its own slice; B1 demoable without AI |
| Viewer model | Data-driven `viewers` table (not Ecto.Enum); seed default set; no mgmt UI | Roles depend on the team — must be data, not a hardcoded enum |
| Attention determination | Manual per-role triage, default `:watch` | Honest model without AI / without role↔user links; B2's AI later suggests, human confirms |
| Storage / event-sourcing | `work_item_facets` table + `:attention_set` event + Projection extension (lazy rows, absent = `:watch`) | Faithful to Slice A's invariants; B2 writes `facet_text` into same rows |
| Slice-A `WorkItem.attention` + `facet_text` | **Drop both** in the B1 migration | `:sous` off in prod, no real data; vestigial drift > clean kill |
| Default viewer | Switcher **unset** by default → shared shape (no lensing) | Most honest default; matches "many items have no facet rows yet" |
| Triage UX | 4-pill selector, not click-to-cycle | Cycling `:act`→`:hidden` is destructively misleading |
| Lens scope | Board + Facet Drawer only; chat un-lensed | Keeps B1 focused; lensing chat surfaces is a later concern |
| Triage permission | Any authenticated user | Single-team internal; ACL is a B-later concern |
| "+N hidden" toggle | Session-only assign | Note future encapsulation alongside ViewerPreference |

## 4. Data model

```
Slackex.Sous.Viewer        — data-driven role-lens (global; single-workspace app)
  id            string PK   (slug: "ceo", "cto", "product", … — stable, human-readable, used as viewer_id key)
  name          string      ("CEO", "CTO", "Product Lead", …)
  color         string      (hex; pill / accent edge)
  focus         {string}    (informational; e.g. ["customers","decisions","risks"])
  position      integer     (switcher ordering)
  inserted_at   utc_datetime_usec
  updated_at    utc_datetime_usec

Slackex.Sous.WorkItemFacet — per-(work_item, viewer) row; lazy (absent = default :watch)
  work_item_id  bigint, references work_items(on_delete: :delete_all)  ┐
  viewer_id     string,  references viewers(on_delete: :delete_all)     ┘ composite PK
  attention     Ecto.Enum [:act, :watch, :know, :hidden], default :watch
  facet_text    text  (NULL in B1; B2 writes via :facet_generated)
  updated_at    utc_datetime_usec   (last :attention_set or :facet_generated)

Slackex.Sous.WorkItemEvent — gains a new type
  type ::= … | :attention_set
  :attention_set payload (string keys): {"viewer_id", "attention", "actor_user_id"}

Slackex.Sous.Projection    — extended
  state ::= %{work_item, decision, facets: %{viewer_id => %{attention, facet_text}}}
  apply_event(:attention_set) → upserts facets[viewer_id].attention
  apply_event(:created) → IGNORES the (now-vestigial) facet_text/attention keys in the payload;
                          per-viewer state starts empty (no rows). Slice-A events still fold
                          cleanly for everything else (kind/state/title/people/etc.).

Slackex.Sous.WorkItem      — drops two columns
  - drop column `attention`     (was the Slice-A single-viewer value)
  - drop column `facet_text`    (was the Slice-A single-viewer value)
```

**Seeded default viewers** (just data — fully editable later):

| id        | name            | color   | focus                                          |
|-----------|-----------------|---------|------------------------------------------------|
| `ceo`     | CEO             | #d97757 | customers · decisions · risks · wins           |
| `cto`     | CTO             | #7c5cff | shipping · risks · decisions · pulse           |
| `em`      | EM              | #3ecf8e | pulse · decisions · blockers                   |
| `product` | Product         | #d97757 | voice · shape · customers                      |
| `csm`     | CSM             | #ff8fbf | health · moments · calls · renewals            |
| `arch`    | Architect       | #3ecf8e | stack · horizon · bench                        |
| `staff`   | Staff Engineer  | #7c5cff | distill · package · tension                    |

(Names mirror the design's example team but are *just data* — any team can edit them.)

## 5. Data flow

One new command in `Slackex.Sous`:

```
Sous.set_attention(work_item_id, viewer_id, attention, actor_id)
  validate viewer_id is a real viewer; attention ∈ Viewer.attentions/0
  build :attention_set event {"viewer_id", "attention", "actor_user_id"}
  Ecto.Multi:
    insert  WorkItemEvent (:attention_set)
    upsert  WorkItemFacet  (on_conflict :replace_all_except [:work_item_id, :viewer_id])
            = Projection.apply_event(current_state, event).facets[viewer_id]
  on success:
    broadcast {:work_item_event, :attention_set, %{work_item_id, viewer_id, attention}}
              -> "sous:work_items"
```

- **Lazy rows.** Reading attention for `(work_item, viewer)` is `WorkItemFacet`-or-`:watch`.
- **Single write path** preserved: `set_attention/4` is the only entry; LiveViews call it.
- **Atomicity** (Slice A invariant #2): event + facet row commit in one Multi.
- **Self-describing payload** with string keys (invariant #3).
- **Append-only** (invariant #5) — no deletes / updates of `WorkItemEvent`.

## 6. Event-sourcing invariants (binding — extend Slice A's seven)

Slice A's seven invariants (spec §6) carry through unchanged for the event-stream core. B1 adds:

8. **Lazy-default for attention.** Absence of a `WorkItemFacet` row for `(work_item, viewer)`
   means **default `:watch`** — *not* "unknown" / NULL semantics. The reducer never inserts
   default rows; only `:attention_set` events create / update rows.
9. **Slice-A facet fields ignored in projection.** The `:created` event payload still carries
   `facet_text` and `attention` (append-only forbids editing past events), but the B1 reducer
   does not project them into any state — per-viewer state comes only from `:attention_set`
   (and later, `:facet_generated`) events. Documented so a future "replay rebuild" cannot
   silently re-introduce the Slice-A globals.
10. **ViewerPreference seam.** All viewer-preference reads/writes go through
    `Slackex.Sous.ViewerPreference` (a behaviour-backed module). LiveViews/components never
    touch the underlying store directly. Backed by `LocalStorage` in B1; swap-tested against an
    `InMemoryStore` (see §9) to prove the seam is real, not theoretical.

## 7. UI surfaces

### 7.1 "Reading as" switcher
- Lives in the In Service board's top bar (left of "Close"). A segmented control or compact
  dropdown of seeded viewers (name + color dot).
- A **null option** ("All / no lens") is the **default** until the user picks. Selecting it means
  every item renders with shared shape (no attention reshape, no hidden, no rise/sink).
- Persistence via `Slackex.Sous.ViewerPreference`:
  - JS hook (`viewer_prefs`, modeled on `loom_prefs`) reads localStorage on connect and pushes
    `viewer_pref:loaded` with the stored viewer slug (or `null`).
  - LiveView mount: assigns `:active_viewer_id` = `nil` (await hook); a `handle_event("viewer_pref:loaded", …)` updates the assign and re-pulls the facet map.
  - On switcher change: LiveView calls `ViewerPreference.put(socket, viewer_id_or_nil)`; the
    behaviour's `save/2` is invoked (B1 store pushes `viewer_pref:save` to the hook to write
    localStorage; a future `Repo` store would `Repo.insert/update` a `viewer_preferences` row).

### 7.2 In Service board reshaping
- On mount and on viewer-switch, the board queries `Sous.facets_for_viewer(active_viewer_id)`
  → `%{work_item_id => attention}` (one query). With `active_viewer_id = nil`, returns `%{}`
  (everything resolves to default `:watch` → shared shape).
- Per-column rendering:
  - Within a column, sort by attention rank `act > watch > know`, then by `inserted_at desc`.
  - `:act` cards add the accent edge + "behind" tag (existing Slice-A treatment).
  - `:know` cards add `border-dashed` + `opacity-60` + a compact (single-line) treatment.
  - `:hidden` cards are omitted; the column footer shows **"+N not at your altitude"**, which
    toggles a session-only assign `:show_hidden_<column>` (booleans). When toggled on, hidden
    cards render with `opacity-40` + a dashed-italic label.
- On a live `:attention_set` broadcast for the active viewer, the board re-pulls the facet map
  and re-renders.

### 7.3 Facet Drawer (the demo moment)
- New LiveComponent: `SlackexWeb.SousLive.FacetDrawer`. Triggered by clicking a board card
  (existing `data-work-item={wi.id}` becomes clickable). Renders as a side drawer.
- Top: the work item, **once** — title + DRI + What / Why / Next (decision content) + state +
  "Open in chat" link to the channel where the decision was made.
- Below: a **grid of prisms**, one per seeded viewer (in `position` order). Each prism shows the
  viewer's name + color dot + the current attention pill for this atom. Triage in-place: clicking
  the pill opens a **4-pill selector** (`:act` / `:watch` / `:know` / `:hidden`); selecting one
  calls `Sous.set_attention/4`. Hidden prisms render as `not-at-this-altitude` (dashed italic)
  with a "Show hidden" toggle (session-only).
- Live: an `:attention_set` from another user updates the drawer in place (subscribed to
  `"sous:work_items"`).

### 7.4 Triage on the board card (secondary)
- A small overflow menu on each board card exposes the same selector for the **active viewer**
  only (so a triager can quickly adjust without opening the drawer). When no viewer is selected,
  the menu is disabled with a tooltip ("Pick a viewer to triage").

## 8. Error handling & resilience

- The single-write-path command `Sous.set_attention/4` runs in one `Ecto.Multi`; validation
  failures (unknown viewer, unknown attention, missing work item) return `{:error, reason}` and
  surface as a flash on the LiveView.
- No new supervised process, no Oban, no AI in B1 — no new restart-strategy / cascade concerns
  (B2 will add the AI Oban pipeline with `restart: :temporary`).
- Broadcasts only after commit.
- ViewerPreference: the JS hook is a thin sync layer; on connect-fail or localStorage error, B1
  falls back to `:active_viewer_id = nil` (the null lens) — no fatal path.

## 9. Testing strategy

Targeted regressions (red-before-green, like Slice A):

1. **Schema + changeset tests** for `Viewer` and `WorkItemFacet` (validations, FK behaviour).
2. **`Projection.apply_event(:attention_set)`** — fold a log including `:created` + `:attention_set`
   for multiple viewers; assert `state.facets` matches and that Slice-A `:created` `facet_text`/
   `attention` keys are NOT projected (invariant #9).
3. **`Sous.set_attention/4` (Multi + broadcast)** — `:attention_set` event appended, facet row
   upserted, broadcast received.
4. **MANDATORY cross-context + PubSub integration test (per CLAUDE.md):** open the In Service
   board live; switch viewer; trigger `set_attention/4`; assert the board reshapes (sort + dim +
   hide) and the broadcast updates a second subscribed view.
5. **Replay-guard (extends Slice A invariant #7):** fold the full event log (`:created` +
   `:state_changed` + `:card_posted` + `:attention_set`) and assert the projected state
   (`work_item` + `decision` + `facets` map) equals the persisted rows — across **all** fields.
6. **ViewerPreference seam test (invariant #10):**
   - Add `Slackex.Sous.ViewerPreference.InMemoryStore` in `test/support/` (~10 LOC).
   - One LiveView test: configure the `:in_memory` store, mount the board, programmatically
     `put/2` a viewer, assert the board reshapes. Proves the behaviour seam is real and the
     swap to a DB-backed store is a config change.
7. **Flag gating:** with `:sous` off, board redirects; the switcher and drawer surfaces are
   inaccessible.
8. **Default-unset behaviour:** with no viewer chosen, board shows shared shape (no items
   reshaped/hidden).
9. **Selector UX:** opening the prism's attention pill shows four options; selecting one emits
   the event and updates the row.

## 10. Migrations (deploy-safe, via `/new-migration`)

- `create table(:viewers, primary_key: false)` — string PK (slug), name/color/focus/position +
  timestamps. Seed the default set in the same migration (or a follow-up data migration).
- `create table(:work_item_facets, primary_key: false)` — composite PK
  `(work_item_id, viewer_id)`; `attention` enum-as-string default `"watch"`; `facet_text` text
  null. Indexes: `(viewer_id, work_item_id)` for the per-viewer board query.
- `alter table(:work_items)` — **drop columns `attention` and `facet_text`**. Note in the
  migration: `:sous` is off in prod, no real data; safe destructive change. The `/new-migration`
  hook may warn — the warning is acknowledged here.

## 11. Module layout

```
lib/slackex/sous/viewer.ex                            # schema + changeset + listing/seed helpers
lib/slackex/sous/work_item_facet.ex                   # schema + changeset
lib/slackex/sous/viewer_preference.ex                 # behaviour-backed module (the seam)
lib/slackex/sous/viewer_preference/store.ex           # @behaviour Store with load/2 + save/2
lib/slackex/sous/viewer_preference/local_storage.ex   # B1 default store (push_event to JS hook)
# extend: lib/slackex/sous.ex
#   - set_attention/4 (the new command)
#   - facets_for_viewer/1 (the board's per-viewer attention map query)
#   - broadcast helpers updated
# extend: lib/slackex/sous/projection.ex
#   - apply_event(:attention_set, ...) → upserts facets map
#   - apply_event(:created, ...) explicitly ignores facet_text/attention keys (invariant #9)
# extend: lib/slackex/sous/work_item_event.ex  → @types += [:attention_set]

lib/slackex_web/live/sous_live/in_service.ex          # extend: switcher, reshape, hidden-toggle, click-card->drawer
lib/slackex_web/live/sous_live/facet_drawer_component.ex  # new LiveComponent
lib/slackex_web/live/sous_live/viewer_switcher_component.ex  # new LiveComponent
assets/js/hooks/viewer_prefs.js                       # JS hook (model: loom_prefs)

priv/repo/migrations/<ts>_sous_b1_viewers_and_facets.exs
test/slackex/sous/viewer_test.exs
test/slackex/sous/work_item_facet_test.exs
test/slackex/sous/projection_attention_test.exs
test/slackex/sous/set_attention_test.exs              # async:true; no ChannelServer needed
test/slackex_web/live/sous_live/in_service_lens_test.exs
test/slackex_web/live/sous_live/facet_drawer_test.exs
test/slackex_web/live/sous_live/viewer_preference_seam_test.exs
test/support/sous/in_memory_viewer_preference_store.ex
```

## 12. Definition of done

- All §9 tests pass, including the replay-guard extension (invariant #7) and the
  ViewerPreference seam test (invariant #10).
- With `:sous` on: a viewer can switch lens, triage a work item's attention per role from the
  Facet Drawer, and see the board reshape live. Hidden cards are dismissable via "+N not at your
  altitude."
- With `:sous` off: board redirects; everything else behaves as today.
- `mix test`, `mix format --check-formatted`, `mix credo`, `mix dialyzer`, `mix test --only contract`,
  `mix test --only e2e`, `mix hex.audit`, `mix deps.unlock --check-unused` all clean (the now-aligned
  pre-deploy gate).
- No changes to `Slackex.Chat.Message`, `Slackex.Messaging.ChannelServer`, or
  `Slackex.Pipeline.BatchWriter` (ADR-002 preserved).

## 13. Hooks for B2 (no work now, just don't block them)

- AI facet *text* generation lands as `Slackex.Sous.FacetWorker` (an isolated `:facets` Oban
  queue worker) writing into `WorkItemFacet.facet_text` via a `:facet_generated` event — same
  table, same single-write-path, same reducer. The Slice A `LLMClient` is the existing seam
  (provider-agnostic; config-swappable to Claude Haiku if desired).
- Caching + invalidation strategy is B2's concern (lazy-on-open + invalidate on `:state_changed`
  / facet-relevant events). Out of scope here.
- "+N hidden" toggle becomes a second user preference encapsulated alongside `ViewerPreference`
  when persisted UX is wanted.
- Role-management UI (CRUD over `viewers`), if/when configurability becomes a real user need.
- Lensing surfaces other than the board + drawer (e.g. chat decision cards) become incremental
  add-ons; the data model is already per-viewer-ready.
