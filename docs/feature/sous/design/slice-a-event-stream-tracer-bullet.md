# Sous Slice A — Event-Stream Tracer Bullet (Design Spec)

**Date:** 2026-05-27
**Status:** Approved (brainstorm) — ready for implementation planning
**Feature:** Sous (provisional brand). Source thesis: `docs/feature/sous/sous-brainstorm.md`, handoff `docs/feature/sous/handoff/README.md`.
**Related:** ADR-001 (`./adr-001-decision-fields-plaintext-in-slice-a.md`).

---

## 1. Goal

Prove the Sous spine end-to-end with the thinnest possible vertical slice: a chat message
becomes a first-class **work item** on an **append-only event stream**, and that stream projects
into the **In Service** board. One surface, one (hard-coded) viewer, real data flowing
**chat → work item → board**. Every later Sous slice composes onto this spine.

This is a tracer bullet, not a product. Its job is to make the event stream real and demoable,
and to do so in a way that does **not** foreclose pure event-sourcing later (see §6).

## 2. Scope

### In scope
- `Slackex.Sous` context with `WorkItem`, `Decision`, `WorkItemEvent` schemas + `Projection` reducer.
- `/decide` slash command → 3-field modal (What/Why/Next) → creates a `:decision` work item in
  state `:mise`, with the thread as provenance.
- A **rich decision card** posted to the channel (a `Message` carrying a nullable `work_item_id`),
  with a "lives in: In Service" link.
- The **In Service** board LiveView: four columns (Order/Mise/Pass/Walked), full attention
  treatments (`act`/`watch`/`know`/`hidden`) against a single hard-coded viewer = current user.
- **Manual state transitions**: move a card between columns, appending a `:state_changed` event.
- Feature flag `:sous` gating the command, the board route, and the decision-card render.

### Out of scope (later slices — do not pull forward)
- Viewer model + "Reading as" switcher + per-viewer `WorkItemFacet` table (Slice B).
- AI facet generation, echo dedup, summaries beyond what already exists (Slice B+).
- Other surfaces: the Pass, Reduction, Stack, Expo, Floor (Slice C+).
- Customer voice / Theme / Order / Customer entities (Slice D).
- Work-item kinds other than `:decision`; the **Order** column therefore starts **empty**.
- Drag-and-drop (move is via buttons), real-time multi-workspace scoping, ACLs.

## 3. Decisions carried from brainstorm

| Decision | Choice | Rationale |
|---|---|---|
| Facet/attention | Static `facet_text` + `attention` denormalized on `WorkItem`; single hard-coded viewer = current user | Shows the board's distinctive attention UI now; real per-viewer table deferred to Slice B |
| Transitions | Create + manual move (`:state_changed` events) | Proves the append-only log captures transitions — the point of an event stream |
| Chat output | Rich decision card as a real `Message` with nullable `work_item_id` FK | Reuses the message pipeline (Snowflake/PubSub/encryption/history) for free; survives reload |
| Stream shape | Projection row + atomic event log (one `Ecto.Multi`) | Idiomatic Phoenix, fast reads, no projection layer yet — superset that keeps pure ES open (§6) |
| `Decision` fields | Plaintext for Slice A | ADR-001 (time-boxed, with binding revisit trigger) |

### Single-viewer semantics & seed defaults (removes the obvious ambiguity)

Slice A has **no viewer model**, so `facet_text` and `attention` are **single global values stored
on the `WorkItem`** — every user who opens the board sees the *same* facet/attention. "Hard-coded
viewer = current user" means only that the board renders as if the reader is the one placeholder
viewer; it does **not** imply per-user values (that arrives with `WorkItemFacet` in Slice B).

Seed defaults at creation (no AI in Slice A):
- `facet_text` ← the decision `title` (a plain restatement; the AI-generated facet is Slice B).
- `attention` ← `:watch`.
These are set in the `:created` event payload, not entered in the modal.

## 4. Data model

```
Slackex.Sous.WorkItem        — authoritative read model (projection)
  id              bigint PK (Snowflake, @primary_key {:id, :integer, autogenerate: false})
  kind            Ecto.Enum [:decision]                 (extensible)
  state           Ecto.Enum [:order, :mise, :pass, :walked]
  title           string
  facet_text      text                                  (single hard-coded viewer)
  attention       Ecto.Enum [:act, :watch, :know, :hidden]
  people          map (jsonb)  {lead, supporting[], watching[], stakeholders[]}
  channel_id      references(:channels)                 (provenance)
  thread_root_message_id  bigint                         (provenance; nullable)
  moved_at        utc_datetime_usec
  inserted_at     utc_datetime_usec                      (derived from Snowflake id)

Slackex.Sous.Decision        — kind-specific detail, 1:1 with a :decision WorkItem
  work_item_id    bigint PK, references(:work_items, on_delete: :delete_all)
  what            text
  why             text
  next            text

Slackex.Sous.WorkItemEvent   — append-only log (replay source of truth)
  id              bigint PK (Snowflake → total order)
  work_item_id    references(:work_items, on_delete: :delete_all)
  type            Ecto.Enum [:created, :state_changed]   (extensible)
  payload         map (jsonb)  — self-describing fact
  actor_user_id   references(:users)
  inserted_at     utc_datetime_usec                      (derived from Snowflake id)

Slackex.Sous.Projection      — pure module
  apply(state :: t | nil, event :: WorkItemEvent.t) :: t     # fold one event
  # used INLINE by commands now; reused by a future projector to rebuild read models
```

Event payloads:
- `:created` — full snapshot: `{kind, title, state, facet_text, attention, people, what, why, next, channel_id, thread_root_message_id}`.
- `:state_changed` — `{from, to, moved_at}`.

`messages` gains one column: `work_item_id` (nullable, `references(:work_items, on_delete: :nilify_all)`).

## 5. Data flow

Two command functions, both routed through one `Ecto.Multi` helper so the single-write-path and
complete-log invariants hold (§6):

```
Sous.open_decision(attrs)
  build :created event (full snapshot)
  Ecto.Multi:
    insert  WorkItemEvent
    insert  WorkItem = Projection.apply(nil, event)        # same reducer
    insert  Decision
    insert  decision-card Message (work_item_id set)       # via Messaging path
  on transaction success:
    broadcast {:work_item_event, :created, work_item} -> "sous:work_items"
    (Message send broadcasts "message.new" -> "channel:#{id}" via existing path)

Sous.move(work_item_id, to_state, actor)
  load current WorkItem; validate transition (to ∈ states, to != current)
  build :state_changed event {from, to, moved_at}
  Ecto.Multi:
    insert WorkItemEvent
    update WorkItem = Projection.apply(current, event)      # same reducer
  on success:
    broadcast {:work_item_event, :state_changed, work_item} -> "sous:work_items"
```

**PubSub topics**
- `"sous:work_items"` — workspace-wide; the In Service board subscribes (create + move).
- `"channel:#{id}"` — the decision-card `Message` rides the existing chat broadcast; no new wiring.

**Snowflake IDs** generated via `Slackex.Infrastructure.Snowflake.generate/0` (same as `Message`);
`inserted_at` derived from the id (mirror `Message.put_inserted_at/1`).

## 6. Event-sourcing readiness invariants (binding)

These keep the later "projection row → pure event-sourcing" switch a localized refactor. The
implementation plan and review MUST verify each:

1. **Single write path.** All mutations go through `Sous.open_decision/1` and `Sous.move/3`.
   No code updates `WorkItem`/`Decision` directly.
2. **Complete log.** Every projection-state change appends a `WorkItemEvent` in the **same
   transaction**. No event ⇒ no mutation.
3. **Self-describing events.** Each payload reconstructs its change with no external lookup
   (`:created` is a full snapshot).
4. **One reducer, two uses.** `Projection.apply/2` is pure; commands call it inline now, a future
   projector calls the same function to rebuild read models. Inline projection written any other
   way is a violation.
5. **Append-only.** Events are never updated or deleted.
6. **Derivable projection.** No `WorkItem`/`Decision` field exists that isn't reconstructable from
   the log.
7. **Replay guard test.** A CI test folds a constructed log via `Projection.apply/2` and asserts it
   reproduces the inline-maintained row (see §9).

## 7. UI surfaces

- **`/decide` modal** — `SlashCommand.parse/1` gains a `{:decide}` clause; `ChatLive.Index`
  `send_message` handler opens the modal (prefill DRI = current user, stakeholders = thread
  participants). Run **outside** a thread (in the main channel), stakeholders prefill **empty** and
  `thread_root_message_id` is `nil` — both still valid. Fields: Title, What, Why, Next, DRI, Stakeholders. Implements all three dismiss
  mechanisms (backdrop, Escape, X button) per project UI convention. Submit → `Sous.open_decision/1`.
- **Decision card** — a `Message` with `work_item_id` set renders as a styled card
  (DRI · What/Why/Next · stakeholders · "lives in: In Service →"). Loom-themed (`loom-*` under `.loom`).
- **In Service board** — `SlackexWeb.SousLive.InService`, route `live "/in-service", SousLive.InService, :index`
  inside the existing `:chat` `live_session` (inherits `:ensure_authenticated`, analytics, chat layout).
  Mount gates on `FunWithFlags.enabled?(:sous, for: user)` (redirect+flash if off), assigns `:loom`,
  subscribes to `"sous:work_items"`. Four columns; attention treatments:
  `act` = accent edge + full prose + rises; `watch` = default; `know` = dashed/dimmed/compact;
  `hidden` = not rendered + "+N not at your altitude" peek toggle. Per-card move buttons →
  `handle_event("move_work_item", …)` → `Sous.move/3`. Live updates via `handle_info` + streams.
  ⌘L keybind is optional (nice-to-have); a sidebar nav entry is the core entry point.
- **Flag `:sous`** gates the `/decide` branch (flash if off), the board mount, and the card render.
  Enabled in `test_helper.exs`. Wired manually, mirroring `:loom_redesign`.

## 8. Error handling & resilience

- **Atomicity:** the `Ecto.Multi` guarantees event + projection + (for create) message + decision
  all commit or none do. No partial state; failures surface as a flash, never a silent half-write.
- **Validation:** decision changeset requires `title` + `what` (Why/Next optional); transition
  validation rejects unknown/no-op moves. Errors render in the modal / as a flash.
- **No new supervised process, no Oban, no AI in Slice A** — so no restart-strategy or cascade
  concerns; the slice stays trivially within the project's OTP-resilience rules. (Slice B's facet
  pipeline is where `restart: :temporary` + isolated Oban queue will matter.)
- **Flag off:** board route redirects with a flash; `/decide` returns a flash; card render falls
  back to plain message. No crashes.
- **Broadcasts only after commit** — never broadcast speculative state.

## 9. Testing strategy

- **MANDATORY integration test (cross-context + PubSub bridge, per CLAUDE.md):** exercise the FULL
  path, not a faked upstream. From a connected LiveView (or the command + a subscribed board test
  process): run `/decide` → assert `WorkItem` created with a `:created` `WorkItemEvent`; assert the
  decision-card `Message` is posted to the channel with `work_item_id` set; assert the In Service
  board receives the `"sous:work_items"` broadcast and renders the card. Then `move/3` → assert
  `:state_changed` event + the board moves the card live.
- **Replay guard (invariant #7):** construct an ordered list of events, fold via `Projection.apply/2`,
  assert the result equals the inline-maintained `WorkItem`/`Decision`. Fails the moment a mutation
  bypasses the reducer or an event stops being self-describing.
- **Unit:** `SlashCommand.parse/1` `/decide` cases; transition validation; `WorkItem`/`Decision`
  changesets; attention-treatment rendering branches.
- **Flag gating:** board route redirects when `:sous` off; `/decide` rejected when off.
- All Sous tests gated behind `:sous` enabled in `test_helper.exs`.

## 10. Migrations (deploy-safe, via `/new-migration`)

- `create table(:work_items)` — bigint PK (no autogenerate), enum-as-string columns, jsonb `people`,
  FK to channels, `inserted_at`/`moved_at`.
- `create table(:decisions)` — `work_item_id` PK + FK, text columns.
- `create table(:work_item_events)` — bigint PK, FK to work_items, type column, jsonb `payload`,
  FK to users, `inserted_at`. Index on `(work_item_id, id)` for ordered replay.
- `alter table(:messages) add :work_item_id` — **nullable** FK, `on_delete: :nilify_all`. Expand-only,
  no backfill, no NOT NULL → deploy-safe.

## 11. Module layout

```
lib/slackex/sous/work_item.ex          # schema + changeset
lib/slackex/sous/decision.ex           # schema + changeset
lib/slackex/sous/work_item_event.ex    # schema
lib/slackex/sous/projection.ex         # pure reducer apply/2
lib/slackex/sous.ex                    # context: open_decision/1, move/3, list/queries, broadcasts
lib/slackex_web/live/sous_live/in_service.ex          # board LiveView
lib/slackex_web/live/sous_live/in_service.html.heex   # board template
lib/slackex_web/live/chat_live/decide_modal_component.ex   # /decide modal (LiveComponent)
# extend: chat_live/slash_command.ex, chat_live/index.ex, chat_components.ex (card render),
#         router.ex (route), test_helper.exs (flag)
```

## 12. Definition of done

- All §9 tests pass (including the mandatory integration test and the replay guard).
- `/decide` in a channel/thread produces a decision card + a board card, live, end-to-end.
- A card moves between columns and the move is an appended event, reflected live.
- Everything is behind `:sous`; with the flag off the app behaves exactly as today.
- `mix test`, `mix format`, credo, dialyzer clean (pre-deploy gates).

## 13. Hooks for Slice B (no work now, just don't block them)

- The single hard-coded viewer is replaced by a `viewer` model + `WorkItemFacet` (composite PK)
  table; `facet_text`/`attention` move off `WorkItem` into per-(viewer, work_item) rows.
- The inline `Projection.apply/2` call is lifted into an event-reacting projector if/when pure
  event-sourcing is adopted (§6 makes this localized).
- AI facet generation arrives as an isolated `restart: :temporary` Oban pipeline (API-based, not
  local Bumblebee — prod has no GPU).
