# Sous Slice B2 — AI Per-Role Facet Text (Design Spec)

**Date:** 2026-05-28
**Status:** Draft — advisor pass #1 incorporated; pending impl planning
**Feature:** Sous (provisional brand).
**Related:** Slice B1 spec (`./slice-b1-role-lens-and-facet-drawer.md`) — especially §13 "Hooks for B2"; Slice A spec (`./slice-a-event-stream-tracer-bullet.md`); ADR-002 (chat linkage).

---

## 1. Goal

Fill `WorkItemFacet.facet_text` with **right-sized prose per viewer** — the "same atom, prism-shaped sentence." B1 stood up the viewer model, the per-(viewer, work_item) row, and the Facet Drawer UI that already has a slot for this text. B2 wires that slot to the AI pipeline through the existing `Slackex.AI.LLMClient` seam, **without** changing B1's data model, command surface, or any of Slice A's seven event-sourcing invariants.

The slice is small on purpose: one new event (`:facet_generated`), one new worker, one new command, one new Drawer state machine. Concentrate the AI cost, latency, and prod-readiness concerns inside this slice so they don't bleed into the lens.

## 2. Scope

### In scope

- New event type `:facet_generated` with payload `{viewer_id, facet_text, model, prompt_version, generated_at, state_version}`. Append-only, atomic Multi alongside the row write (Slice A invariants #1, #2, #3, #5 preserved).
- New command `Slackex.Sous.set_facet_text/3` — the **only** path that writes `facet_text` (extends invariant #5 "one write-path per facet field"). Signature: `set_facet_text(work_item_id, viewer_id, attrs :: map)` where attrs carries `:facet_text`, `:model`, `:prompt_version`, `:state_version` (map-shaped to survive future field additions per Ecto changeset convention).
- New Projection clause `apply_event(:facet_generated, ...)` — writes `facet_text` into the existing `WorkItemFacet` row, merges with `attention` (last-write-wins on the *field*, not the row).
- New Oban worker `Slackex.Sous.FacetWorker` on a dedicated `:facets` queue (low concurrency, isolated supervisor branch via standard Oban config), `restart: :temporary`-equivalent error policy (Oban discard, never bring down the supervisor).
- New module `Slackex.Sous.FacetPrompt` — pure prompt-template generator keyed by `viewer.id`, versioned by `@prompt_version`.
- **Lazy-on-open enqueue**: opening the Facet Drawer auto-enqueues exactly one FacetWorker job for each `(viewer)` whose row state derives to `:never_generated` OR `:stale` (see §4 pill-state derivation). This is the **only automatic enqueue trigger**.
- **Invalidation on relevant events**: `:state_changed`. Invalidation **does not enqueue**; it marks stale (sets `facet_stale_at`) and waits for the next drawer-open. (See invariant #14.)
- **Four UI pill states**: never-generated, generating, stale, fresh. Distinguished in the Drawer + on the board card (the role-pill area B1 already renders).
- **Graceful degrade**: if `LLMClient.configured?/0` is false, the slice presents "AI text unavailable" inline; the rest of the Sous experience is unaffected (B1 stands without B2).
- StubLLMClient contract extended to be deterministic, viewer-distinguishable, and cheap for test + dev.
- Continued behind the `:sous` flag.

### Out of scope (deferred — do not pull in)

- **Thread-context in the prompt** — including recent messages from the work item's chat thread (`card_message_id`) in the prompt would meaningfully improve facet quality but adds a query and prompt-size complexity. Decision: the prompt sees `viewer + work_item + decision body` only in B2. Thread context is B-later if dogfooding shows facets feel context-thin.
- **Role management UI / CRUD over viewers** — B-later (B1 §13).
- **Background eager generation** — pre-warm all `(work_item, viewer)` pairs ahead of drawer-open. Cost/latency multiplier; revisit after dogfooding shows it's needed.
- **Per-user prompt personalisation** — prompts are per-viewer-role, not per-user. Personal lensing is B-later.
- **Streaming the facet text into the Drawer** — non-streaming `LLMClient.complete/2` only; streaming is a UX refinement after the core works.
- **Telemetry/metrics** — add when usage shows it matters. B2 is small enough that loud log lines + Oban's built-in error visibility suffice.
- **Other lensing surfaces** — chat decision cards remain un-lensed.
- **Multi-model routing / A-B prompt experiments** — single configured model.

## 3. Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Where does facet text live | Same `work_item_facets` row B1 already provisions | Zero new write path; one schema, one Projection, one reducer |
| Single write-path enforcement | `Sous.set_facet_text/3` is the only writer | Mirrors B1's `set_attention/4` discipline (invariant #5) |
| Generation trigger | Lazy-on-open (Drawer opens → enqueue if nil/stale) | Avoids fan-out cost of "regenerate all viewers on every state change" |
| What invalidates | `:state_changed`, future `:decision_body_edited`; NOT `:attention_set` | Attention changes don't change the facts the prompt sees |
| Invalidation behaviour | Mark stale (nullify `facet_text` OR set `stale_at`); do **not** enqueue | The next drawer-open enqueues; idle work items don't burn LLM calls |
| `state_version` definition | Integer: `count of :state_changed events for the work_item up to and including the current state`. Computed by `Sous.state_version(work_item_id)` (cheap query). Embedded in worker args **at enqueue time** and in the event payload. | A monotone counter tied to the only thing that changes "the facts the prompt sees" today; survives event-log replay; cheap to compute |
| `state_version` is read **only at enqueue time** | The Drawer computes `state_version` when enqueueing; `FacetWorker.perform/1` reads it from `job.args` and writes it into the event payload **unchanged**. The worker does NOT re-query `Sous.state_version/1` mid-flight. | If `:state_changed` fires while a worker is in-flight, the row will be written with the old `state_version` AND the `facet_stale_at` set by the invalidation — the pill renders `:stale`, and the next drawer-open enqueues again with the new version. Re-querying inside `perform/1` would silently break the uniqueness contract (uniqueness key wouldn't match what was enqueued). |
| Idempotency | `Oban.Worker, unique: [period: :infinity, fields: [:worker, :args], keys: [:work_item_id, :viewer_id, :prompt_version, :state_version]]` | Per Oban docs, `fields: [:worker, :args]` is required for `keys:` to look inside args. Drawer can be opened concurrently / Oban can retry — duplicate `:facet_generated` events are otherwise the default failure mode. |
| Prompt template home | Module constant in `Slackex.Sous.FacetPrompt`, keyed by `viewer.id` | Viewers are immutable in B1 (invariant #11); when role-mgmt UI lands, this becomes a `Viewer.prompt_template` field — flagged migration path in §13 |
| Model selection | Configured via env `LLM_FACET_MODEL` (no hardcoded default in code or spec — the provider's full model ID lives in env to avoid stale model strings) | LLMClient already provider-agnostic; provider IDs (e.g. Anthropic `claude-haiku-4-5-20251001`) change format across providers/gateways |
| Failure visibility | LLM call failures → log warning + Oban retry with backoff; persistent failure surfaces in Drawer as "generation failed — retry" | CLAUDE.md prohibits silent `rescue _ -> :ok` |
| Stub routing | Stub branches on `opts[:purpose] == :sous_facet`; only that branch is changed by B2. Returns `"[#{viewer.id}] #{decision.what} — focus: #{Enum.join(viewer.focus, ",")}"` deterministically. | Additive — does NOT change behaviour for existing stub consumers (summarization etc.) |
| `:generating` state mechanism | LiveView assign (`:enqueued_facets` MapSet of `viewer_id`) tracks in-flight; flipped to `:fresh` by PubSub `:facet_generated`. NOT an Oban query. | Cheaper render path; no Oban query per render. Tradeoff: a Drawer reload mid-generation will briefly show `:never_generated`/`:stale` before the PubSub event arrives — acceptable (the row's `facet_stale_at` / `facet_text` is still authoritative for what to display). |
| `configured?/0` gate | If false: drawer shows "AI text unavailable"; FacetWorker refuses to enqueue (returns `{:discard, :llm_not_configured}`); never crashes | Graceful degrade; B1 still works |
| Concurrent row UPDATE | Accept last-write-wins on the row; both `:facet_generated` events are appended (event log is the source of truth); no `lock("FOR UPDATE")` defensiveness. | Text is regenerated when stale anyway — the race produces two valid generations; whichever lands last wins on the row. Avoids the M-1 row-lock pattern B1 deferred. |

## 4. Data model

```
Slackex.Sous.WorkItemFacet         — UNCHANGED from B1
  work_item_id  bigint  ┐ composite PK
  viewer_id     string  ┘
  attention     Ecto.Enum [:act, :watch, :know, :hidden], default :watch
  facet_text    text    (B2 writes via :facet_generated)
  updated_at    utc_datetime_usec
  -- NEW B2 columns (added via deploy-safe migration):
  facet_model         string       (the model that produced facet_text; e.g. "claude-haiku-4-5")
  facet_prompt_version integer     (the @prompt_version that produced it)
  facet_generated_at  utc_datetime_usec
  facet_stale_at      utc_datetime_usec     (NULL = fresh; set by invalidation)

Slackex.Sous.WorkItemEvent          — gains a new type
  type ::= … | :facet_generated
  :facet_generated payload (string keys): {
    "viewer_id":        string,
    "facet_text":       string,
    "model":            string,
    "prompt_version":   integer,
    "generated_at":     iso8601,
    "state_version":    integer   -- monotonically increasing; see §6.7
  }
```

### Pill state derivation (pure function on the row + LiveView assign)

```
state(row, enqueued_set) =
  cond do
    enqueued_set member? viewer_id              -> :generating  -- LiveView assign, set on enqueue, cleared on PubSub :facet_generated
    row == nil or row.facet_text == nil         -> :never_generated
    row.facet_stale_at != nil                   -> :stale
    row.facet_prompt_version < @prompt_version  -> :stale       -- auto-stale on prompt bump (no migration tool needed; see §13)
    true                                        -> :fresh
  end
```

Only `:generating` consults non-row state, and only LiveView assigns — no Oban query per render. The other branches are pure on the row. The Drawer + board-card render branch on this state (§7).

**`state_version` (referenced throughout):** `Sous.state_version(work_item_id) = count of :state_changed events for that work_item`. Stored in the `:facet_generated` event payload, in the worker args (for the uniqueness key), and in the row after generation. A `:state_changed` event increments it, marks rows stale, but does NOT enqueue (invariant #14). The worker reads `state_version` **only from `job.args`** — it does not re-query mid-flight, because that would silently break the Oban uniqueness contract (the uniqueness key is computed against `args` at enqueue, and a worker that wrote a different version than it claimed would defeat dedup).

## 5. Data flow (lazy-on-open generation)

1. User opens Facet Drawer for `work_item`.
2. Drawer mounts → reads facet rows for all viewers.
3. For each viewer where row is `:never_generated` or `:stale` AND `LLMClient.configured?()` is true → enqueue `FacetWorker.new(%{work_item_id, viewer_id, prompt_version, state_version})` (Oban deduplicates by uniqueness key).
4. Drawer shows pill states immediately (`:generating` for the ones just enqueued).
5. FacetWorker runs:
   - Loads work_item + decision + viewer.
   - `FacetPrompt.build(viewer, work_item, decision) → messages`.
   - `LLMClient.complete(messages, model: configured_model, max_tokens: 200)`.
   - On `{:ok, text}` → `Sous.set_facet_text(work_item_id, viewer_id, text, model, prompt_version, state_version)` which writes `:facet_generated` event + updates row (Multi).
   - On `{:error, reason}` → log warning + return `{:error, reason}` so Oban retries with backoff (max 3 attempts; then discard with loud log).
6. PubSub broadcast `{:sous, :facet_generated, work_item_id, viewer_id}` → Drawer (and board, if open) re-renders that pill → `:fresh`.

## 6. Event-sourcing invariants (extending Slice B1's #8–#11)

12. **One write-path per facet field**: `attention` is written only by `set_attention/4`; `facet_text` is written only by `set_facet_text/3`. The Projection composes them. Direct row mutation is forbidden outside these commands. *(Generalisation of Slice A invariant #5 to per-field writers.)*

13. **`:facet_generated` payload is complete enough for replay**: includes `model`, `prompt_version`, `state_version`, `generated_at`, `viewer_id`, `facet_text`. A future "replay with new prompt" is achievable by ignoring events whose `prompt_version` ≠ current; the data needed to make that decision is in the event log.

14. **Invalidation is not enqueueing**: `:state_changed` (and any future body-edit event) **only** clears freshness; it never produces an LLM call. The next Drawer-open is the trigger. *(Cost containment; without this, 7 viewers × N in-flight work items = unbounded LLM fan-out on every state move.)*

15. **`:facet_generated` is idempotent at the event level**: the FacetWorker uniqueness key `(work_item_id, viewer_id, prompt_version, state_version)` prevents duplicate events for the same logical generation. If a duplicate slips through (e.g. across deploys with cleared Oban state), the Projection accepts it — last-write-wins on the field — and no replay-rebuild produces incorrect state.

16. **No row created without an attention decision OR a facet generation**: B1's "lazy row" invariant #8 stands. A `:facet_generated` event for a viewer who has never had attention set creates a row with `attention: :watch` (the lazy default). The Projection encodes this in a single `apply_event` clause.

17. **LLM call site is unique to the worker; replay is regeneration-free**: the FacetWorker is the *only* LLM caller, and it is fired *only* by drawer-open (auto) or manual retry of `:failed` (§7.1). The Projection is a pure fold — it has no LLM access and applies the `facet_text` already in the event payload during replay. LLM outputs are non-deterministic (sampling); without this constraint, a future "rebuild projection by replay" path could call the LLM again and diverge from the persisted state. *(Prevents a class of "replay produces different state than live" bugs.)*

## 7. UI surfaces

### 7.1 Facet Drawer pill states (mandatory rendering for each viewer prism)

| State | Visual | Behaviour |
|---|---|---|
| `:never_generated` | Attention pill; below: dimmed italic "…" placeholder, no facet text | Drawer mount auto-enqueues FacetWorker (if configured); state transitions to `:generating` |
| `:generating` | Attention pill + small spinner glyph; placeholder text "generating…" | PubSub `:facet_generated` event flips to `:fresh` |
| `:stale` | Attention pill; facet text rendered at reduced opacity + "may be out of date" hairline note | Drawer mount auto-enqueues (same as `:never_generated`); state transitions to `:generating`. **No manual click required.** |
| `:fresh` | Attention pill; facet text at full opacity | No action |
| **Not-configured** (`LLMClient.configured?() == false`) | "AI text unavailable" muted line where facet text would be; no spinner | No worker enqueued |
| **Failed** (Oban exhausted retries) | Facet text empty; small "↻ retry" refresh glyph next to facet area | Click on glyph → manual re-enqueue (the *only* user gesture that enqueues) |

### 7.2 Gesture grammar (avoid B1 gesture conflict)

The viewer prism in the Drawer hosts **two distinct gestures**, never overloaded:

- **Click on the attention pill** (4-pill selector from B1) → sets attention (`:attention_set` event). Unchanged from B1.
- **Click on the `↻ retry` refresh glyph** (only present in `:failed` state) → manual re-enqueue.

`:stale` and `:never_generated` do not require a gesture — drawer-open auto-enqueues them. `:fresh` shows no glyph.

### 7.3 Board card

- The role-pill area B1 renders gains a tiny dot-indicator next to viewers whose state derives to `:stale` or `:never_generated` (only visible when the active viewer has it — i.e. one indicator at most). Subtle; doesn't reshape the card. Click on card opens Drawer as in B1.

### 7.4 No new chrome

- No new modal, no new top-bar element, no settings panel. All B2 UI lives inside surfaces B1 already built.

## 8. Error handling & resilience

- **FacetWorker** uses standard Oban retries (max 3, exponential backoff). On `LLMClient` error: log warning with `work_item_id`, `viewer_id`, and error reason. **No `rescue _ -> :ok`** — propagate errors to Oban (CLAUDE.md mandate).
- **Oban queue isolation**: the `:facets` queue is dedicated; its workers crashing or backing up cannot starve `:default`, `:notifications`, `:embeddings`, `:link_previews`, `:analytics`. Configured with low concurrency (e.g. 3) to bound LLM cost spikes.
- **No new supervised process** beyond the Oban queue itself. Oban's worker model already provides crash isolation per job.
- **`LLMClient.configured?/0` short-circuit**: FacetWorker's `perform/1` checks first; if false, returns `{:discard, :llm_not_configured}` (Oban won't retry) and logs a single warning. Drawer never enqueues when not configured (§5 step 3), so this path only fires across deploys with config changes.
- **Stale detection is purely on `facet_stale_at`**: no clock-drift sensitivity beyond what already exists in `:state_changed` events.
- **Cost ceiling**: Drawer-open auto-enqueue + `:failed` manual retry are the **only** enqueue paths. If a user opens the Drawer 100×/min, Oban uniqueness key (`prompt_version`, `state_version`) collapses to one job per `(work_item, viewer)` per logical change. No "thundering herd" possible.

## 9. Testing strategy

### Mandatory integration tests (per CLAUDE.md "Spec-Driven Acceptance Tests" rule)

```elixir
# PROVES THE WIRING — not just the worker
test "drawer-open → FacetWorker → :facet_generated event → projection has text" do
  enable_flag(:sous, for: user)
  configure_stub_llm()
  {:ok, %{work_item: wi, decision: _}} = Sous.open_decision(%{...})

  # Drawer is a LiveComponent triggered by phx-click="open_drawer" on the board card.
  {:ok, view, _} = live(conn, "/in-service")
  view |> element("[phx-click='open_drawer'][phx-value-id='#{wi.id}']") |> render_click()

  # Lazy-on-open: drawer mount enqueues one job per viewer
  viewer_count = length(Sous.list_viewers())
  for v <- Sous.list_viewers() do
    assert_enqueued(worker: FacetWorker, args: %{"work_item_id" => wi.id, "viewer_id" => v.id})
  end

  # Drain the queue (Oban.Testing)
  assert %{success: success_count} = Oban.drain_queue(queue: :facets)
  assert success_count == viewer_count

  # Event-level: every viewer has a :facet_generated event
  events = Sous.events_for(wi.id)
  assert length(Enum.filter(events, &(&1.type == :facet_generated))) == viewer_count

  # Projection-level: every viewer now has a row (invariant #16: generation creates lazy row)
  # AND every row has text. Asserting both prevents a silent no-op bug.
  rows = Sous.facets_for_work_item(wi.id)
  assert length(rows) == viewer_count
  for r <- rows, do: assert r.facet_text != nil
end

test "invalidation: :state_changed marks stale but does NOT enqueue" do
  # Critical cost-containment invariant #14
  # (setup: generate facets first, then move the work item)
  Sous.move(wi.id, :in_service, actor)
  refute_enqueued(worker: FacetWorker)
  rows = Sous.facets_for_work_item(wi.id)
  for r <- rows, do: assert r.facet_stale_at != nil
end
```

### Unit / pure tests

- `FacetPrompt.build/3` produces deterministic, viewer-distinguishable messages.
- `Projection.apply_event(:facet_generated, ...)` writes text into existing row; works whether row already exists (attention set) or not (lazy creation).
- `WorkItemFacet.state/1` (pill state derivation) covers all five branches.

### Idempotency / contract tests

- Two concurrent FacetWorker jobs with identical `(work_item_id, viewer_id, prompt_version, state_version)` → exactly one `:facet_generated` event written (Oban uniqueness).
- StubLLMClient output is deterministic (same input → same output) — asserted at CI time.

### Graceful-degrade test

- `LLMClient.configured?/0` returning false → Drawer renders "AI text unavailable" placeholders, no jobs enqueued, no crash.

### Failure-visibility test

- LLM client raises → Oban retries → final discard logs at warning level (asserted via `capture_log`).

## 10. Migrations (deploy-safe, via `/new-migration`)

One migration: `add_facet_b2_columns_to_work_item_facets`.

- `add :facet_model, :string` — nullable.
- `add :facet_prompt_version, :integer` — nullable.
- `add :facet_generated_at, :utc_datetime_usec` — nullable.
- `add :facet_stale_at, :utc_datetime_usec` — nullable.

All nullable, no default backfill required. `:sous` is off in prod; even if it were on, all existing rows have `facet_text` NULL, so the pill state `:never_generated` is correct without backfill. Migration is purely additive (expand phase only — no contract phase needed).

## 11. Module layout

```
# new: lib/slackex/sous/facet_prompt.ex
#   - @prompt_version 1
#   - build(viewer, work_item, decision) :: [LLMClient.message()]

# new: lib/slackex/sous/facet_worker.ex
#   - use Oban.Worker, queue: :facets, max_attempts: 3,
#     unique: [period: :infinity, fields: [:worker, :args],
#              keys: [:work_item_id, :viewer_id, :prompt_version, :state_version]]
#   - perform/1: read state_version from args (do NOT re-query); configured?-gate →
#     load → prompt → LLMClient.complete(messages, opts: [purpose: :sous_facet]) →
#     set_facet_text(work_item_id, viewer_id, %{facet_text:, model:, prompt_version:, state_version:})

# extend: lib/slackex/sous.ex
#   - set_facet_text/3 (signature: work_item_id, viewer_id, attrs :: map) — the new command
#   - state_version/1 (counts :state_changed events for the work_item)
#   - invalidate_facets/1 (called by Sous.move/3 — marks stale; does NOT enqueue)
#   - facets_for_work_item/1 (Drawer query, returns rows with derived pill state)
#   - list_viewers/0 (Drawer / tests need it; may already exist from B1)

# extend: lib/slackex/sous/projection.ex
#   - apply_event(:facet_generated, ...) — upsert text into facets map (lazy row creation if needed)

# extend: lib/slackex/sous/work_item_event.ex
#   - @types += [:facet_generated]

# extend: lib/slackex_web/live/sous/facet_drawer_component.ex (B1)
#   - mount: enqueue for nil/stale viewers
#   - subscribe to {:sous, :facet_generated, work_item_id, viewer_id}
#   - render pill states (5 branches per §7.1)

# extend: config/config.exs + config/runtime.exs
#   - queues: [..., facets: 3]
#   - :slackex, :llm_facet_model — sourced from env LLM_FACET_MODEL; no compile-time default
#     (different providers/gateways use different model ID formats; avoid stale strings)

# extend: lib/slackex/ai/stub_llm_client.ex
#   - facet-distinguishable deterministic output (preserved test fixtures pattern)
```

## 12. Definition of done

- [ ] Migration applies in dev + test; no warnings.
- [ ] All B1 invariants (#8–#11) still hold; new B2 invariants (#12–#16) covered by tests.
- [ ] Mandatory integration test (Drawer → Worker → event → projection) green; no faking the upstream.
- [ ] Invalidation test (`:state_changed` marks stale, does NOT enqueue) green.
- [ ] Idempotency test green; concurrent enqueues collapse to one event.
- [ ] Graceful-degrade test green when `LLMClient.configured?/0` is false.
- [ ] Failure-visibility test green; warning logged on persistent failure.
- [ ] StubLLMClient output deterministic and viewer-distinguishable (asserted).
- [ ] Drawer renders all 5 pill states; manual browser-verify in dev with stub + real model (via OpenAI-compatible client).
- [ ] Suite passes (target: B1's 1537 + new tests); 0 credo, 0 dialyzer (relative to current baseline).
- [ ] Behind `:sous` flag (already gated by B1).
- [ ] No silent `rescue` clauses introduced (audited).
- [ ] No new supervised processes outside Oban worker.
- [ ] RESUME.md updated with B2 status, new invariants (#12–#17), and any new deferred items.

## 13. Hooks for B-later (no work now, just don't block them)

- **Viewer.prompt_template** — when role-management UI lands, `prompt_template` becomes a column on `viewers`; `FacetPrompt.build/3` switches from module-constant lookup (`viewer.id`) to row field. Bumping `@prompt_version` will be replaced by a per-row version.
- **Streaming facet text into the Drawer** — `LLMClient.stream/2` exists; B2 deliberately uses `complete/2`. Streaming is a UX increment.
- **Eager background generation** — a periodic Oban job could pre-warm facets for in-flight work items based on actor presence. Requires user-activity signals; B-later if dogfooding shows the lazy delay is annoying.
- **Per-actor personalisation** — facets per (viewer, work_item, actor) when actors want their own prose. Requires extending `WorkItemFacet` PK; B-much-later.
- **Telemetry** — emit `[:sous, :facet, :generated]` with model/duration/tokens when usage matters. Out of scope for B2.
- **Prompt-version migration tooling** — a mix task that re-stales all rows below current `@prompt_version`, letting the next drawer-open regenerate. Defer until prompt is iterated.
- **Multi-model routing** — route different viewers to different models (e.g. CEO summary on Sonnet, dev-team on Haiku). One-line config swap when needed.
