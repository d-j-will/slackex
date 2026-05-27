# Sous Slice A — Event-Stream Tracer Bullet (Design Spec)

**Date:** 2026-05-27
**Status:** Approved (brainstorm) — ready for implementation planning
**Feature:** Sous (provisional brand). Source thesis: `docs/feature/sous/sous-brainstorm.md`, handoff `docs/feature/sous/handoff/README.md`.
**Related:** ADR-001 (`./adr-001-decision-fields-plaintext-in-slice-a.md`), ADR-002 (`./adr-002-sous-chat-linkage-via-card-message-id.md`).

> **Amended 2026-05-27 (ADR-002):** the original "insert the decision-card Message inside the
> work-item `Ecto.Multi`, atomically, with a `work_item_id` FK on `messages`" approach is replaced.
> Messages are written via a write-behind cache (`ChannelServer` → async `BatchWriter`), so a direct
> Multi insert is incompatible. Slice A now uses **Option Q**: the card is posted through the
> existing `Messaging` facade, and the Sous context owns the linkage via `card_message_id` on
> `WorkItem` (set by a `:card_posted` event). §4, §5, §7, §8, §10, §11 below reflect this.

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
- A **rich decision card** posted to the channel (a normal `Message` via the existing facade);
  Sous links it via `card_message_id` on the `WorkItem` (no `Message` schema change). The card
  shows a "lives in: In Service" link. (ADR-002.)
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
| Chat output | Rich decision card via the existing `Messaging` facade; linkage held as `card_message_id` on `WorkItem` (set by a `:card_posted` event) | Reuses the write-behind message pipeline correctly; no hot-path change; survives reload (ADR-002) |
| Stream shape | Projection row + atomic event log (one `Ecto.Multi`) | Idiomatic Phoenix, fast reads, no projection layer yet — superset that keeps pure ES open (§6) |
| `Decision` fields | Plaintext for Slice A | ADR-001 (time-boxed, with binding revisit trigger) |

### Single-viewer semantics & seed defaults (removes the obvious ambiguity)

Slice A has **no viewer model**, so `facet_text` and `attention` are **single global values stored
on the `WorkItem`** — every user who opens the board sees the *same* facet/attention. "Hard-coded
viewer = current user" means only that the board renders as if the reader is the one placeholder
viewer; it does **not** imply per-user values (that arrives with `WorkItemFacet` in Slice B).

Seed defaults at creation (no AI in Slice A):
- `facet_text` ← the decision `title` (a plain restatement; the AI-generated facet is Slice B).
- `attention` ← `:act` — a freshly-made decision demands attention, so the board shows a real
  treatment (accent edge + "behind") from day one rather than a uniform default.
These are set in the `:created` event payload, not entered in the modal.

> The board implements all four treatments (`act`/`watch`/`know`/`hidden`), but `watch`/`know`/`hidden`
> are per-viewer concepts that only become *meaningful* with Slice B's viewer model. Making them
> exercisable within Slice A (a small board-side attention control backed by an `:attention_set`
> event) is a pending product decision — see the plan's Task 14 note.

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
  card_message_id bigint                                 (the posted decision-card Message; nullable until :card_posted)
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
  type            Ecto.Enum [:created, :state_changed, :card_posted]   (extensible)
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
- `:card_posted` — `{card_message_id}` (records the posted decision-card Message; keeps `card_message_id` in the log so the projection stays derivable — invariant #6).

**No change to the `messages` table.** The decision card is a normal `Message` posted through the
existing write-behind facade; the link lives on `WorkItem.card_message_id` (ADR-002).

## 5. Data flow

Two command functions, both routed through one `Ecto.Multi` helper so the single-write-path and
complete-log invariants hold (§6):

```
Sous.open_decision(attrs)
  # 1. event-stream core — atomic
  build :created event (full snapshot)
  Ecto.Multi:
    insert  WorkItemEvent (:created)
    insert  WorkItem = Projection.apply(nil, event)        # same reducer
    insert  Decision
  on transaction success:
    broadcast {:work_item_event, :created, work_item} -> "sous:work_items"

  # 2. post the card via the EXISTING write-behind facade (ADR-002 — not in the Multi)
  {:ok, msg} = Messaging.send_message(channel_id, actor_id, card_fallback_text)
                                                           # ChannelServer caches + broadcasts
                                                           # "message.new" -> "channel:#{id}"
  # 3. record the linkage as another event (keeps the log complete)
  build :card_posted event {card_message_id: msg.id}
  Ecto.Multi:
    insert WorkItemEvent (:card_posted)
    update WorkItem = Projection.apply(work_item, event)   # sets card_message_id
  on success:
    broadcast {:work_item_event, :card_posted, work_item} -> "sous:work_items"
    broadcast {:decision_card, msg.id, work_item}          -> "sous:cards:channel:#{channel_id}"
  # if step 2/3 fails: work item exists (shown on board, no chat card); log the failure.

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
- `"sous:work_items"` — workspace-wide; the In Service board subscribes (create + move + card_posted).
- `"sous:cards:channel:#{id}"` — channel-scoped; the **chat** LiveView subscribes to upgrade a
  just-posted plain message into the styled decision card live (the two-step render, ADR-002).
- `"channel:#{id}"` — the decision-card `Message` rides the existing chat `"message.new"` broadcast
  via the facade; no new wiring on the message side.

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
- **Decision card** — the chat LiveView loads `card_messages :: %{message_id => work_item}` (with
  preloaded `Decision`) for the active channel on mount, and subscribes to
  `"sous:cards:channel:#{id}"`. The message component branches: if `Map.get(@card_messages, message.id)`
  returns a work item, render the styled card (DRI · What/Why/Next · stakeholders ·
  "lives in: In Service →"); otherwise render as today. On a live `:decision_card` broadcast the
  LiveView adds the entry to `card_messages` and the just-posted plain message re-renders as the card
  (the two-step upgrade, ADR-002). Loom-themed (`loom-*` under `.loom`).
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

- **Atomicity (scoped, ADR-002):** the event-stream core commits atomically in one `Ecto.Multi` —
  `:created` event + `WorkItem` + `Decision` (and separately, the `:state_changed` and `:card_posted`
  events + their projection updates). The card **post** is a separate step through the messaging
  facade. If the post (or the `:card_posted` event) fails, the work item still exists and is shown on
  the board with **no chat card**; the failure is **logged** (loud, not swallowed) and self-heals if
  retried. No partial *event-stream* state ever persists.
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
  process): run `/decide` → assert `WorkItem` created with a `:created` `WorkItemEvent`; assert a
  decision-card `Message` is posted to the channel via the facade and the `WorkItem.card_message_id`
  is set by a `:card_posted` event; assert the In Service board receives the `"sous:work_items"`
  broadcast and renders the card; assert a subscriber to `"sous:cards:channel:#{id}"` receives the
  `:decision_card` upgrade. Then `move/3` → assert `:state_changed` event + the board moves the card live.
- **Replay guard (invariant #7):** construct an ordered list of events, fold via `Projection.apply/2`,
  assert the result equals the inline-maintained `WorkItem`/`Decision`. Fails the moment a mutation
  bypasses the reducer or an event stops being self-describing.
- **Unit:** `SlashCommand.parse/1` `/decide` cases; transition validation; `WorkItem`/`Decision`
  changesets; attention-treatment rendering branches.
- **Flag gating:** board route redirects when `:sous` off; `/decide` rejected when off.
- All Sous tests gated behind `:sous` enabled in `test_helper.exs`.

## 10. Migrations (deploy-safe, via `/new-migration`)

- `create table(:work_items)` — bigint PK (no autogenerate), enum-as-string columns, jsonb `people`,
  FK to channels, `card_message_id` (nullable bigint, no FK constraint — points at a `messages` row
  but messages are written async via the cache, so a hard FK could race; index it), `inserted_at`/`moved_at`.
- `create table(:decisions)` — `work_item_id` PK + FK, text columns.
- `create table(:work_item_events)` — bigint PK, FK to work_items, type column, jsonb `payload`,
  FK to users, `inserted_at`. Index on `(work_item_id, id)` for ordered replay.
- **No `messages` migration** (ADR-002 — the linkage is on `work_items`, not `messages`).

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
# extend: chat_live/slash_command.ex (/decide clause),
#         chat_live/index.ex (open modal; load card_messages map; subscribe "sous:cards:channel:#{id}"),
#         chat_components.ex (decision-card render branch on @card_messages),
#         router.ex (route), test_helper.exs (flag)
# NOTE (ADR-002): NO changes to chat/message.ex, messaging/channel_server.ex, pipeline/batch_writer.ex.
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
- **Message-as-event horizon (ADR-002):** if Sous's thesis deepens toward "every message is an event
  in the stream", the relationship between the write-behind message pipeline and the work-item event
  log becomes a deliberate architectural decision (possibly unifying the two logs) — to be made
  head-on, not patched. Slice A keeps them as separate logs joined by `card_message_id`.
