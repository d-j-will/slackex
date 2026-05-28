# Sous Slice B2 — AI Per-Role Facet Text Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fill `WorkItemFacet.facet_text` with right-sized prose per viewer through an isolated Oban pipeline, lazy-on-drawer-open, behind the existing `:sous` flag. Zero changes to B1's data model contracts, single write-path discipline preserved, no new supervised processes beyond the Oban queue.

**Architecture:** Drawer-open auto-enqueues `FacetWorker` jobs (one per viewer whose row state derives to `:never_generated` or `:stale`). The worker calls `LLMClient.complete/2` with `opts[:purpose] = :sous_facet`, then writes via `Sous.set_facet_text/3` which atomically appends a `:facet_generated` event and updates the row via the existing Projection. `:state_changed` events mark rows stale (`facet_stale_at`) but never enqueue — the next drawer-open is the trigger. State_version (count of `:state_changed` events) is read **once at enqueue** and embedded in args/payload so Oban's uniqueness contract holds. Graceful degrade when `LLMClient.configured?/0` is false.

**Tech Stack:** Elixir / Phoenix LiveView, Ecto + PostgreSQL, Oban (queue `:facets`), `Slackex.AI.LLMClient` behaviour (StubLLMClient + OpenAICompatibleClient), Phoenix.PubSub, FunWithFlags, ExUnit + ExMachina, `Oban.Testing` for `assert_enqueued` / `drain_queue`.

**Source of truth:** spec `docs/feature/sous/design/slice-b2-ai-facet-text.md`. Carries forward Slice A's seven + B1's #8–#11 + adds B2's #12–#17.

**Conventions to honor (from CLAUDE.md / project memory):**
- Never use `unless`; use `if` with an inverted condition.
- Gate every B2 surface behind `:sous` (already in place from B1).
- Migrations go through `/new-migration`; B2's migration is purely additive (no contract phase).
- Pre-commit hook runs the full quality gate; commit after every green step.
- **No `rescue _ -> :ok`** in worker code or periodic measurements — propagate to Oban; log on persistent failure.
- Verify library behavior against docs (Context7) before committing config — already done in spec for Oban `unique:` and `drain_queue` shape.
- New Oban worker must NOT use `restart: :permanent`-equivalent behaviour; Oban already provides the per-job crash isolation we need. The queue itself is supervised by Oban.
- Test-fixture honesty: integration tests exercise the real Drawer entry point (`phx-click="open_drawer"` on the board card), not hand-crafted assigns.
- Mandatory acceptance test pattern (CLAUDE.md "Spec-Driven Acceptance Tests"): full producer → consumer path. No faking the upstream.

---

## File Structure

**Create:**
- `priv/repo/migrations/<ts>_sous_b2_facet_text_columns.exs` — add 4 columns to `work_item_facets`.
- `lib/slackex/sous/facet_prompt.ex` — pure module: `@prompt_version 1` + `build/3` returning `[LLMClient.message()]`.
- `lib/slackex/sous/facet_worker.ex` — `Oban.Worker` on queue `:facets`.
- `test/slackex/sous/facet_prompt_test.exs`
- `test/slackex/sous/facet_worker_test.exs`
- `test/slackex/sous/facet_integration_test.exs` — mandatory cross-context integration test (drawer-click → worker → event → projection).

**Modify:**
- `lib/slackex/sous/work_item_facet.ex` — extend schema with `facet_model`, `facet_prompt_version`, `facet_generated_at`, `facet_stale_at`; add pure `state/2` pill-state derivation.
- `lib/slackex/sous/work_item_event.ex` — add `:facet_generated` to `@types`.
- `lib/slackex/sous/projection.ex` — new `apply_event(:facet_generated, ...)` clause (lazy row creation per invariant #16).
- `lib/slackex/sous.ex` — add `set_facet_text/3`, `state_version/1`, `invalidate_facets/1`, `facets_for_work_item/1`, `list_viewers/0` (if missing). Hook `Sous.move/3` to call `invalidate_facets/1` inside its Multi.
- `lib/slackex/ai/stub_llm_client.ex` — additively branch on `opts[:purpose] == :sous_facet`; preserve all other behaviour.
- `lib/slackex_web/live/sous_live/facet_drawer_component.ex` — lazy enqueue on mount/update, pill-state rendering (5 branches), PubSub subscribe to `{:sous, :facet_generated, work_item_id, viewer_id}`, manual retry on `:failed` glyph click.
- `lib/slackex_web/live/sous_live/in_service.ex` (+ template) — small dot indicator on board card for `:stale`/`:never_generated` viewers; broadcast handler for `:facet_generated`.
- `config/config.exs` — `queues: [..., facets: 3]`.
- `config/runtime.exs` — `:slackex, :llm_facet_model` from `System.get_env("LLM_FACET_MODEL")`; nil-tolerant (worker will short-circuit via `configured?/0` when missing).
- `RESUME.md` — B2 status, invariants, deferred items.

**Do NOT modify** (ADR-002): `lib/slackex/chat/message.ex`, `lib/slackex/messaging/channel_server.ex`, `lib/slackex/pipeline/batch_writer.ex`.

---

## Task 1: Migration — add 4 columns to `work_item_facets`

**Files:**
- Create: `priv/repo/migrations/<timestamp>_sous_b2_facet_text_columns.exs`

**Steps:**
- [ ] Run `/new-migration sous_b2_facet_text_columns` to scaffold.
- [ ] In `change/0`:
  - `alter table(:work_item_facets) do`
    - `add :facet_model, :string`
    - `add :facet_prompt_version, :integer`
    - `add :facet_generated_at, :utc_datetime_usec`
    - `add :facet_stale_at, :utc_datetime_usec`
  - `end`
- [ ] All nullable, no defaults, no backfill (`:sous` off in prod; existing rows have nil `facet_text` so derive to `:never_generated` correctly).
- [ ] Run `mix ecto.migrate` locally; `mix ecto.rollback`; `mix ecto.migrate` again — verify expand-only behaviour.

**Acceptance:**
- [ ] Migration applies and rolls back cleanly.
- [ ] `mix format` + `mix credo --strict` (project gate non-strict; warnings OK) + `mix test` all green.
- [ ] Commit: `feat(sous): B2 migration — facet text columns on work_item_facets`.

---

## Task 2: `FacetPrompt` pure module + tests

**Files:**
- Create: `lib/slackex/sous/facet_prompt.ex`
- Create: `test/slackex/sous/facet_prompt_test.exs`

**Module shape:**
```elixir
defmodule Slackex.Sous.FacetPrompt do
  @moduledoc """
  Pure prompt-template generator for Sous Slice B2 facet text. Keyed by `viewer.id`.
  Bumping `@prompt_version` auto-stales all rows below the new version (see
  WorkItemFacet.state/2). Viewers are immutable in B1 (#11) so a module-constant
  template is defensible; when role-mgmt UI lands, this moves to a `Viewer.prompt_template` field.
  """

  @prompt_version 1
  def prompt_version, do: @prompt_version

  @system_message """
  You produce a single short paragraph (1–3 sentences, max ~200 chars) that frames a
  decision from a specific role's point of view. Stay on the decision's actual content;
  do not invent facts. Plain prose, no markdown, no bullets.
  """

  @spec build(Slackex.Sous.Viewer.t(), Slackex.Sous.WorkItem.t(), Slackex.Sous.Decision.t()) ::
          [Slackex.AI.LLMClient.message()]
  def build(viewer, work_item, decision), do: [
    %{role: "system", content: @system_message},
    %{role: "user", content: """
      You are reading as the #{viewer.name}. Focus areas: #{Enum.join(viewer.focus, ", ")}.
      Decision: #{decision.what}
      Why: #{decision.why}
      Next: #{decision.next}
      State: #{work_item.state}
      Title: #{work_item.title}

      Write the 1–3-sentence facet that the #{viewer.name} should see.
    """}
  ]
end
```

**Tests:**
- [ ] `build/3` returns a list of two messages with roles "system" and "user".
- [ ] User message contains `viewer.name`, the focus areas joined, and all four decision fields.
- [ ] `build/3` is deterministic — same inputs produce identical output (asserted byte-for-byte).
- [ ] `prompt_version/0` returns the integer `1`.

**Acceptance:**
- [ ] All tests green; `mix format` + suite green.
- [ ] Commit: `feat(sous): B2 FacetPrompt pure module + tests`.

---

## Task 3: Extend `WorkItemFacet` schema + add pill-state derivation

**Files:**
- Modify: `lib/slackex/sous/work_item_facet.ex`
- Modify: `test/slackex/sous/work_item_facet_test.exs` (or create if absent)

**Steps:**
- [ ] Add fields to the schema:
  - `field :facet_model, :string`
  - `field :facet_prompt_version, :integer`
  - `field :facet_generated_at, :utc_datetime_usec`
  - `field :facet_stale_at, :utc_datetime_usec`
- [ ] Extend `changeset/2` cast list to include the new fields (do NOT add to `validate_required` — they are nullable).
- [ ] Add `@spec state(row :: t() | nil, enqueued_set :: MapSet.t(String.t())) :: atom()` pure function per spec §4 pill-state derivation. Branches in order:
  1. `viewer_id in enqueued_set` → `:generating`
  2. `row == nil or row.facet_text == nil` → `:never_generated`
  3. `row.facet_stale_at != nil` → `:stale`
  4. `row.facet_prompt_version < Slackex.Sous.FacetPrompt.prompt_version()` → `:stale`
  5. otherwise → `:fresh`
- [ ] Function signature note: pass the `viewer_id` separately so the function works for both row-present and row-absent cases. Adjust spec wording if cleaner.

**Tests:**
- [ ] All 5 branches of `state/2` (one test each).
- [ ] Specifically: a row with `facet_text != nil` but `facet_prompt_version` lower than current → `:stale`.
- [ ] Specifically: a viewer_id in the enqueued set wins over any row state (including `:fresh`).

**Acceptance:**
- [ ] All tests green; commit: `feat(sous): B2 WorkItemFacet columns + pill-state derivation`.

---

## Task 4: `WorkItemEvent` — add `:facet_generated` to `@types`

**Files:**
- Modify: `lib/slackex/sous/work_item_event.ex`
- Modify: `test/slackex/sous/work_item_event_test.exs` (if exists)

**Steps:**
- [ ] Add `:facet_generated` to `@types`.
- [ ] No schema column change (the existing `type` Ecto.Enum picks up the new atom).
- [ ] If there's a `valid_type?/1` style helper, ensure it accepts `:facet_generated`.

**Tests:**
- [ ] Casting `:facet_generated` round-trips through the schema.

**Acceptance:**
- [ ] Suite green; commit: `feat(sous): B2 add :facet_generated event type`.

---

## Task 5: Projection — `apply_event(:facet_generated, ...)` clause

**Files:**
- Modify: `lib/slackex/sous/projection.ex`
- Modify: `test/slackex/sous/projection_test.exs`

**Steps:**
- [ ] Add clause **between** the existing `:attention_set` and the default fallthrough (B1's reducer):
  ```elixir
  def apply_event(state, %WorkItemEvent{type: :facet_generated, payload: p}) do
    facets = Map.get(state, :facets, %{})
    viewer_id = get(p, "viewer_id")

    existing =
      facets
      |> Map.get(viewer_id, %{attention: :watch, facet_text: nil})

    new_facet =
      existing
      |> Map.put(:facet_text, get(p, "facet_text"))
      |> Map.put(:facet_model, get(p, "model"))
      |> Map.put(:facet_prompt_version, get(p, "prompt_version"))
      |> Map.put(:facet_generated_at, to_dt(get(p, "generated_at")))
      |> Map.put(:facet_stale_at, nil) # generation always clears stale

    Map.put(state, :facets, Map.put(facets, viewer_id, new_facet))
  end
  ```
- [ ] Note the lazy row creation: a viewer who never had attention set gets the default `:watch` map merged with the new facet fields (invariant #16).

**Tests:**
- [ ] Folding a single `:facet_generated` event for a never-attention-set viewer produces a facets entry with `attention: :watch`, the text, model, version, generated_at, and `facet_stale_at: nil`.
- [ ] Folding `:attention_set` then `:facet_generated` preserves the attention value and adds the text.
- [ ] Folding `:facet_generated` then `:attention_set` preserves the text and updates attention.
- [ ] Folding two `:facet_generated` events for the same viewer → last-write-wins on the field (invariant #15).

**Acceptance:**
- [ ] Suite green; commit: `feat(sous): B2 Projection :facet_generated clause`.

---

## Task 6: `Sous` context — `set_facet_text/3`, `state_version/1`, `invalidate_facets/1`, hook into `move/3`

**Files:**
- Modify: `lib/slackex/sous.ex`
- Modify: `test/slackex/sous_test.exs`

**Steps:**
- [ ] Add `state_version/1`:
  ```elixir
  @spec state_version(integer()) :: integer()
  def state_version(work_item_id) do
    Repo.aggregate(
      from(e in WorkItemEvent, where: e.work_item_id == ^work_item_id and e.type == :state_changed),
      :count
    )
  end
  ```
- [ ] Add `set_facet_text/3` — the sole writer of `facet_text`:
  - Accept `(work_item_id, viewer_id, attrs)` where `attrs` is a map with `:facet_text`, `:model`, `:prompt_version`, `:state_version`.
  - Run an `Ecto.Multi` that:
    1. Inserts the `:facet_generated` event with full payload (including `state_version` from attrs unchanged, plus `generated_at: DateTime.utc_now()`).
    2. Upserts the `WorkItemFacet` row with the new text, model, prompt_version, generated_at, **`facet_stale_at: nil`**, and the lazy default `attention: :watch` if the row doesn't exist.
  - Broadcast `{:sous, :facet_generated, work_item_id, viewer_id}` via PubSub on success.
- [ ] Add `invalidate_facets/1` — call from inside `Sous.move/3`'s existing Multi:
  - `update_all(work_item_facets, set: [facet_stale_at: ^DateTime.utc_now()])` scoped by `work_item_id` (only rows that exist; lazy rows stay absent).
  - Crucially: do **not** enqueue any worker here (invariant #14).
- [ ] Add `facets_for_work_item/1` — returns the list of `WorkItemFacet` rows for the work_item (Drawer query). Drawer composes pill state via `WorkItemFacet.state/2`.
- [ ] Confirm `list_viewers/0` exists; add if missing (used by Drawer + integration test).

**Tests:**
- [ ] `state_version/1` returns 0 for a fresh work item, increments by 1 for each `move/3`.
- [ ] `set_facet_text/3` atomically writes event + row; broadcast received.
- [ ] `set_facet_text/3` for a viewer with no existing row creates the row with `attention: :watch` (invariant #16).
- [ ] `set_facet_text/3` clears `facet_stale_at` when called on a stale row.
- [ ] `set_facet_text/3` writes the `state_version` from attrs unchanged (does NOT re-query — verify by passing a stale value and asserting it's persisted).
- [ ] `Sous.move/3` triggers `invalidate_facets/1`: existing rows now have `facet_stale_at` set; no Oban jobs enqueued (`refute_enqueued worker: FacetWorker`).

**Acceptance:**
- [ ] Suite green; commit: `feat(sous): B2 Sous.set_facet_text, state_version, invalidate_facets`.

---

## Task 7: `StubLLMClient` additive extension

**Files:**
- Modify: `lib/slackex/ai/stub_llm_client.ex`
- Modify: `test/slackex/ai/stub_llm_client_test.exs` (if exists; otherwise small inline tests)

**Steps:**
- [ ] In `complete/2`, branch first on `Keyword.get(opts, :purpose)`:
  ```elixir
  def complete(messages, opts \\ []) do
    case Keyword.get(opts, :purpose) do
      :sous_facet -> sous_facet_response(messages)
      _           -> existing_default_response(messages, opts)
    end
  end
  ```
- [ ] `sous_facet_response/1` extracts the viewer name and decision summary deterministically from the user message and returns a short string like `"[stub:#{viewer_name}] #{decision_what} — focus: #{focus_csv}"`. Cheap, deterministic, viewer-distinguishable.
- [ ] Do **not** change `stream/2` (B2 uses `complete/2` only).

**Tests:**
- [ ] `complete/2` with `opts: [purpose: :sous_facet]` returns a deterministic string that includes the viewer's name (parsed from the prompt).
- [ ] Same call twice → identical output (CI guarantee).
- [ ] `complete/2` with no `purpose` opt → unchanged existing behaviour (regression).

**Acceptance:**
- [ ] Suite green (especially existing summarization stub tests); commit: `feat(sous): B2 StubLLMClient :sous_facet purpose branch`.

---

## Task 8: `Slackex.Sous.FacetWorker` Oban worker

**Files:**
- Create: `lib/slackex/sous/facet_worker.ex`
- Create: `test/slackex/sous/facet_worker_test.exs`
- Modify: `config/config.exs` — add `facets: 3` to the Oban `queues:` keyword.
- Modify: `config/runtime.exs` — `config :slackex, :llm_facet_model, System.get_env("LLM_FACET_MODEL")`.

**Module shape:**
```elixir
defmodule Slackex.Sous.FacetWorker do
  @moduledoc """
  Generates per-(work_item, viewer) facet text. The ONLY LLM caller in Sous.
  Reads `state_version` from job.args; never re-queries (preserves Oban uniqueness contract).
  """

  use Oban.Worker,
    queue: :facets,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:work_item_id, :viewer_id, :prompt_version, :state_version]
    ]

  alias Slackex.AI.LLMClient
  alias Slackex.Sous
  alias Slackex.Sous.{FacetPrompt, Viewer, WorkItem, Decision}

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{
    "work_item_id" => wi_id,
    "viewer_id" => viewer_id,
    "prompt_version" => prompt_version,
    "state_version" => state_version
  }}) do
    cond do
      not LLMClient.configured?() ->
        Logger.warning("FacetWorker: LLMClient not configured; discarding job",
          work_item_id: wi_id, viewer_id: viewer_id)
        {:discard, :llm_not_configured}

      true ->
        with %Viewer{} = viewer <- Sous.get_viewer(viewer_id),
             %WorkItem{} = work_item <- Sous.get_work_item(wi_id),
             %Decision{} = decision <- Sous.get_decision(wi_id),
             messages = FacetPrompt.build(viewer, work_item, decision),
             model = Application.get_env(:slackex, :llm_facet_model),
             {:ok, text} <- LLMClient.complete(messages,
                              purpose: :sous_facet,
                              model: model,
                              max_tokens: 200) do
          Sous.set_facet_text(wi_id, viewer_id, %{
            facet_text: text,
            model: model,
            prompt_version: prompt_version,
            state_version: state_version
          })
        else
          nil ->
            # work_item / decision / viewer deleted between enqueue and run
            Logger.warning("FacetWorker: missing dependency; discarding",
              work_item_id: wi_id, viewer_id: viewer_id)
            {:discard, :missing_dependency}

          {:error, reason} ->
            Logger.warning("FacetWorker: LLM call failed; will retry",
              work_item_id: wi_id, viewer_id: viewer_id, reason: inspect(reason))
            {:error, reason}
        end
    end
  end
end
```

**Tests** (use `Oban.Testing`, run as `use Slackex.DataCase`):
- [ ] Configured stub + valid args → returns `{:ok, _}`; row populated; `:facet_generated` event written.
- [ ] `LLMClient.configured?/0` false (Stub returns false, e.g. via app env swap) → returns `{:discard, :llm_not_configured}`; warning logged (assert via `capture_log`).
- [ ] Missing work_item → returns `{:discard, :missing_dependency}`.
- [ ] LLM client returns `{:error, ...}` → returns `{:error, ...}` (Oban retries); warning logged.
- [ ] Two `Oban.insert` calls with identical `(work_item_id, viewer_id, prompt_version, state_version)` → one `Oban.Job{conflict?: true}`; only one event written after `drain_queue`.
- [ ] Worker writes `state_version` from args unchanged into the event payload, even if `Sous.state_version/1` has since incremented (assert by stale-state setup).

**Acceptance:**
- [ ] Suite green; commit: `feat(sous): B2 FacetWorker — Oban worker on :facets queue`.

---

## Task 9: `FacetDrawerComponent` — lazy enqueue + 5 pill states

**Files:**
- Modify: `lib/slackex_web/live/sous_live/facet_drawer_component.ex`
- Modify: existing component tests under `test/slackex_web/live/sous_live/`

**Steps:**
- [ ] In `update/2`:
  - Compute `state_version = Sous.state_version(work_item_id)` once.
  - Compute `enqueued_set = MapSet.new()` (LiveView assign) — viewers about to be enqueued OR already in-flight.
  - For each viewer:
    - Compute `pill_state = WorkItemFacet.state(row_for_viewer, enqueued_set, viewer.id)`.
    - If `pill_state in [:never_generated, :stale]` AND `LLMClient.configured?()` → enqueue `FacetWorker.new(%{work_item_id, viewer_id, prompt_version, state_version})` via `Oban.insert/1` and add `viewer.id` to `enqueued_set`.
  - Assign `enqueued_facets: enqueued_set` to the socket.
  - Subscribe to `Phoenix.PubSub` topic `"sous:facets:#{work_item_id}"` (parent LV may already subscribe; component-level is also fine if scoped).
- [ ] In `handle_info({:sous, :facet_generated, ^work_item_id, viewer_id}, socket)`:
  - Remove viewer_id from `enqueued_facets`.
  - Reload that row from `Sous.facets_for_work_item/1`; re-render.
- [ ] Template — branch on `pill_state` per spec §7.1:
  - `:never_generated` → dimmed italic "…"
  - `:generating` → spinner glyph + "generating…"
  - `:stale` → text at reduced opacity + "may be out of date" hairline note
  - `:fresh` → text at full opacity
  - `:failed` (Oban-exhausted retries) → empty text + `↻ retry` glyph with `phx-click="retry_facet"` and `phx-value-viewer={viewer.id}` (per §7.2 gesture grammar)
  - `LLMClient.configured?() == false` → "AI text unavailable" muted line, no spinner
- [ ] `handle_event("retry_facet", %{"viewer" => viewer_id}, socket)`:
  - Re-enqueue with current `state_version` + `prompt_version`; add to `enqueued_facets`; assign.
- [ ] Three dismiss mechanisms (backdrop, Escape, X) preserved from B1; no regression.

**Tests:**
- [ ] Mount with no facets + LLM configured → 7 jobs enqueued; all viewers render `:generating`.
- [ ] Mount with no facets + LLM not configured → 0 jobs enqueued; all viewers render "AI text unavailable".
- [ ] Mount with all-fresh rows → 0 jobs enqueued.
- [ ] PubSub `:facet_generated` received → that viewer flips to `:fresh`; others unchanged.
- [ ] `:failed` state renders the retry glyph; click → new job enqueued; pill flips to `:generating`.
- [ ] Pill (attention) click still sets attention (B1 invariant — no regression of gesture grammar).

**Acceptance:**
- [ ] Suite green; commit: `feat(sous): B2 FacetDrawer — lazy enqueue + 5 pill states`.

---

## Task 10: `InService` board card — small stale/never indicator + facet broadcast forward

**Files:**
- Modify: `lib/slackex_web/live/sous_live/in_service.ex` (+ template)
- Modify: existing board tests

**Steps:**
- [ ] When the active viewer's row state derives to `:stale` or `:never_generated`, render a tiny dot indicator next to the role-pill area on the board card. Subtle CSS; no card reshape.
- [ ] `handle_info({:work_item_event, :facet_generated, %{work_item_id: wi_id, viewer_id: vid}}, socket)`:
  - If currently showing that work item, refresh the row's state and re-render.
  - If the open Drawer is for that work_item_id, forward via `send_update(FacetDrawerComponent, ...)`.
- [ ] No fan-out cost: this handler only updates the in-memory assigns; no DB query unless rendering changes.

**Tests:**
- [ ] Board card with active viewer in `:stale` state renders the indicator.
- [ ] Board card with active viewer in `:fresh` state does NOT render the indicator.
- [ ] `:facet_generated` broadcast received while Drawer open → Drawer re-renders (via `send_update`).

**Acceptance:**
- [ ] Suite green; commit: `feat(sous): B2 board card stale indicator + facet broadcast forwarding`.

---

## Task 11: Mandatory cross-context integration test

**Files:**
- Create: `test/slackex/sous/facet_integration_test.exs`

**Steps:**
- [ ] One test file with the four mandatory scenarios from spec §9:
  1. **Wiring**: drawer-click → enqueue → drain → events written → projection has text + rows count matches viewer count.
  2. **Invalidation**: `Sous.move/3` marks `facet_stale_at` on existing rows; `refute_enqueued worker: FacetWorker`.
  3. **Idempotency**: two concurrent inserts for the same `(wi, viewer, prompt_v, state_v)` → exactly one event after drain.
  4. **Graceful degrade**: stub returning `configured? == false` → drawer renders "AI text unavailable"; no jobs enqueued; no crash.
- [ ] Use the **real** entry point: `live(conn, "/in-service")` → `element("[phx-click='open_drawer'][phx-value-id='#{wi.id}']") |> render_click()`. No hand-crafted assigns.
- [ ] Per CLAUDE.md "Spec-Driven Acceptance Tests": this test exercises the full producer → consumer path. Failures here mean wiring drift, not just handler bugs.

**Acceptance:**
- [ ] All four scenarios green; commit: `test(sous): B2 mandatory cross-context integration tests`.

---

## Task 12: Failure-visibility test (`capture_log`)

**Files:**
- Modify: `test/slackex/sous/facet_worker_test.exs` (add scenario)

**Steps:**
- [ ] Test that when `LLMClient.complete/2` consistently raises or returns `{:error, _}` for 3 attempts (max), the final job state is `:discarded`, and a warning is logged (assert via `ExUnit.CaptureLog`).
- [ ] Importantly: assert that the test runs the worker through `Oban.drain_queue(queue: :facets, with_recursion: true)` so the retry mechanism is exercised; do NOT manually loop `perform_job/2`.

**Acceptance:**
- [ ] Test green; commit: `test(sous): B2 failure-visibility — persistent LLM error logs at warning level`.

---

## Task 13: Browser dogfood + final code-review pass

**Steps:**
- [ ] `mix phx.server`, log in, enable `:sous` for actor at `/admin/flags`.
- [ ] Open `/in-service`; create a decision via `/decide` modal; click the card to open the Drawer.
- [ ] Observe pill states: should see `:generating` briefly (with stub), then `:fresh` per viewer. Confirm 5–7 distinct facet texts (one per viewer) demonstrating the lens differs across roles.
- [ ] Move the card; reopen Drawer; pills should derive to `:stale` and auto-enqueue → `:generating` → `:fresh`.
- [ ] Temporarily set `:llm_client` to a misconfigured client → reopen Drawer → "AI text unavailable" renders; no crash; no jobs enqueued.
- [ ] Optional: with real OpenAI-compatible client + `LLM_FACET_MODEL` env, run end-to-end once and verify text quality.
- [ ] Dispatch `feature-dev:code-reviewer` agent on the diff (per CLAUDE.md "Agent cross-checking is mandatory"); address any findings.

**Acceptance:**
- [ ] No issues from the dogfood pass.
- [ ] No silent rescues found by review.
- [ ] If reviewer finds anything substantive, fold into a follow-up commit before the RESUME update.

---

## Task 14: RESUME update + final gates

**Files:**
- Modify: `RESUME.md`

**Steps:**
- [ ] Update the Sous section in `RESUME.md`:
  - Append "Slice B2 SHIPPED (in dev; behind `:sous`)" entry with date, commits range, suite count, and new invariants #12–#17.
  - List remaining B-later items (thread-context in prompts, role-mgmt UI, streaming, eager generation, multi-model routing).
  - Note the `LLM_FACET_MODEL` env requirement for prod cutover.
- [ ] Run `scripts/pre-deploy` (the 7-step quality gate) — must come up clean.
- [ ] Decide on prod cutover separately; B2 stays behind `:sous` (already off in prod).

**Acceptance:**
- [ ] RESUME reflects B2 status accurately.
- [ ] `scripts/pre-deploy` green.
- [ ] Final commit: `docs(resume): Sous Slice B2 built (AI facet pipeline; behind :sous)`.

---

## Definition of Done

All from spec §12, plus:

- [ ] All 14 tasks above committed; suite passes (target: B1's 1537 + ~30–40 new tests).
- [ ] 0 dialyzer regressions; credo project-gate green (non-strict).
- [ ] No new supervised processes outside Oban's own per-queue supervisor.
- [ ] No `rescue _ -> :ok` introduced (audited via grep).
- [ ] StubLLMClient existing consumers still pass (regression).
- [ ] Mandatory integration test exercises real LiveView entry point, not hand-crafted assigns.
- [ ] `state_version` is read **once at enqueue**; never re-queried inside `perform/1` (audited by reading the worker).
- [ ] Behind `:sous` (already gated by B1); off in prod.
- [ ] RESUME.md updated; pre-deploy green.

---

## Notes for executor

- **Order matters:** Tasks 1–7 are mostly independent and can be done in sequence with green-suite-after-each. Tasks 8–10 depend on 5–7. Tasks 11–12 depend on 8–10. Task 13 needs the whole feature. Task 14 last.
- **Commit per task** so the executor's progress is visible and any pre-commit hook failure is locally contained.
- **If the executor hits a wall**, surface it immediately: do not introduce `rescue` clauses or scope creep to make it go away. The single-write-path discipline and the `state_version`-from-args-only rule are load-bearing.
- **Watch for accidentally re-querying `state_version`** inside `perform/1`. This is the single mistake most likely to silently break dedup.
