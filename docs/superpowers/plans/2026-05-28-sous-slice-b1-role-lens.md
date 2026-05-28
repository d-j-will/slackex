# Sous Slice B1 — Role-Lens + Attention Triage + Facet Drawer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a data-driven viewer/role model, a "Reading as" switcher, per-(viewer, work_item) attention set by manual triage, and the Facet Drawer — all behind `:sous`, no AI. Per-role facet *text* is deferred to B2.

**Architecture:** A new `viewers` table (data-driven, seeded) plus `work_item_facets` (composite PK, lazy rows = default `:watch`). A new `:attention_set` event extends the append-only log; the `Projection` reducer gains one clause and the `Sous.open_decision` payload stops carrying the now-vestigial Slice-A `facet_text`/`attention` keys (which the reducer ignores per invariant #9). The In Service board reshapes per the active viewer's attention map (rise/sink/hide). Viewer preference reads/writes go through a single encapsulated `Slackex.Sous.ViewerPreference` module so a future swap to a DB-backed store is a config change.

**Tech Stack:** Elixir / Phoenix LiveView, Ecto + PostgreSQL, Snowflake IDs (`Slackex.Infrastructure.Snowflake`), Phoenix.PubSub, FunWithFlags, ExUnit + ExMachina (`Slackex.TestFactory`).

**Source of truth:** spec `docs/feature/sous/design/slice-b1-role-lens-and-facet-drawer.md`. Carries forward Slice A's seven invariants + adds B1's four (#8–#11).

**Conventions to honor (from CLAUDE.md / project memory):**
- Never use `unless`; use `if` with an inverted condition.
- Snowflake PK schemas use `@primary_key {:id, :integer, autogenerate: false}` and derive `inserted_at` from the id.
- Gate every B1 surface behind `:sous` from the start.
- Modals/drawers implement the three dismiss mechanisms (backdrop, Escape, X) per project UI convention.
- Migrations go through `/new-migration`; destructive drops (here: `attention`, `facet_text`) carry a doc-comment safety analysis.
- Pre-commit hook runs the full quality gate (format, credo, dialyzer, full suite) — commit after every green step.
- ADR-002 still holds: no changes to `Slackex.Chat.Message`, `Slackex.Messaging.ChannelServer`, or `Slackex.Pipeline.BatchWriter`.

---

## File Structure

**Create:**
- `priv/repo/migrations/<ts>_sous_b1_viewers_and_facets.exs` — `viewers` + `work_item_facets`, drop two `WorkItem` columns, seed default viewers.
- `lib/slackex/sous/viewer.ex` — `Viewer` schema + changeset.
- `lib/slackex/sous/work_item_facet.ex` — `WorkItemFacet` schema (composite PK) + changeset.
- `lib/slackex/sous/viewer_preference.ex` — encapsulating module (the seam).
- `lib/slackex/sous/viewer_preference/store.ex` — `@behaviour` (`load/1`, `save/2`).
- `lib/slackex/sous/viewer_preference/local_storage.ex` — B1 default store (JS-hook-backed).
- `test/support/sous/in_memory_viewer_preference_store.ex` — test-only store, proves the seam.
- `lib/slackex_web/live/sous_live/viewer_switcher.ex` — function component (top-bar switcher).
- `lib/slackex_web/live/sous_live/facet_drawer_component.ex` — LiveComponent.
- `assets/js/hooks/viewer_prefs.js` — localStorage sync hook.
- New tests under `test/slackex/sous/` and `test/slackex_web/live/sous_live/`.

**Modify:**
- `lib/slackex/sous.ex` — `set_attention/4`, `facets_for_viewer/1`, omit Slice-A facet keys from new `:created` payloads.
- `lib/slackex/sous/work_item.ex` — drop `:facet_text` and `:attention` fields + cast.
- `lib/slackex/sous/work_item_event.ex` — add `:attention_set` to `@types`.
- `lib/slackex/sous/projection.ex` — `facets: %{}` in `initial/0` and the `:created` result; new `:attention_set` clause; drop Slice-A facet keys from `:created` projection (invariant #9).
- `lib/slackex_web/live/sous_live/in_service.ex` (+ template) — switcher, facet-map load, per-viewer reshape, "+N hidden" toggle, click-card → drawer.
- `assets/js/app.js` — register the new hook.
- Existing tests (`test/slackex/sous_test.exs`, `test/slackex_web/live/sous_live/in_service_test.exs`) — update assertions that read the dropped columns.

**Do NOT modify** (ADR-002): `lib/slackex/chat/message.ex`, `lib/slackex/messaging/channel_server.ex`, `lib/slackex/pipeline/batch_writer.ex`.

---

## Task 1: Migration — create `viewers` + `work_item_facets`, drop two `WorkItem` columns, seed viewers

**Files:**
- Create: `priv/repo/migrations/<timestamp>_sous_b1_viewers_and_facets.exs`

- [ ] **Step 1: Generate the migration**

Run: `mix ecto.gen.migration sous_b1_viewers_and_facets`
Expected: creates `priv/repo/migrations/<timestamp>_sous_b1_viewers_and_facets.exs` with an empty `change/0`.

- [ ] **Step 2: Write the migration body**

Replace the generated file's contents with:

```elixir
defmodule Slackex.Repo.Migrations.SousB1ViewersAndFacets do
  @moduledoc """
  Slice B1 — role-lens data model.

  Creates the `viewers` (data-driven role-lenses) and `work_item_facets`
  (composite PK; per-(work_item, viewer) attention + reserved-for-B2 facet_text)
  tables. Drops the Slice-A single-viewer placeholder columns from `work_items`.

  Safety on the drops:
    * `:sous` flag is OFF in prod (no rows have meaningful attention/facet_text).
    * Slice A was a tracer bullet; B1 supersedes the single-viewer placeholder.
    * Per spec §10, the `/new-migration` safety hook is expected to WARN on the
      removes — this doc-comment acknowledges the safety analysis. If the hook
      BLOCKS, split into expand/contract per spec guidance.
  """

  use Ecto.Migration

  def change do
    create table(:viewers, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :color, :string, null: false
      add :focus, {:array, :string}, null: false, default: []
      add :position, :integer, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create table(:work_item_facets, primary_key: false) do
      add :work_item_id,
          references(:work_items, on_delete: :delete_all, type: :bigint),
          primary_key: true,
          null: false

      add :viewer_id,
          references(:viewers, on_delete: :delete_all, type: :string),
          primary_key: true,
          null: false

      add :attention, :string, null: false, default: "watch"
      add :facet_text, :text
      add :updated_at, :utc_datetime_usec, null: false
    end

    # Per-viewer board query lookup (`SELECT … WHERE viewer_id = $1`).
    create index(:work_item_facets, [:viewer_id, :work_item_id])

    # Drop the Slice-A single-viewer placeholders (see moduledoc).
    alter table(:work_items) do
      remove :attention, :string, null: false, default: "watch"
      remove :facet_text, :text
    end

    # Seed default viewers (just data — fully editable later via seeds/admin).
    execute(&seed_viewers/0, &delete_viewers/0)
  end

  defp seed_viewers do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    seeds = [
      %{id: "ceo", name: "CEO", color: "#d97757", focus: ["customers", "decisions", "risks", "wins"], position: 0, inserted_at: now, updated_at: now},
      %{id: "cto", name: "CTO", color: "#7c5cff", focus: ["shipping", "risks", "decisions", "pulse"], position: 1, inserted_at: now, updated_at: now},
      %{id: "em", name: "EM", color: "#3ecf8e", focus: ["pulse", "decisions", "blockers"], position: 2, inserted_at: now, updated_at: now},
      %{id: "product", name: "Product", color: "#d97757", focus: ["voice", "shape", "customers"], position: 3, inserted_at: now, updated_at: now},
      %{id: "csm", name: "CSM", color: "#ff8fbf", focus: ["health", "moments", "calls", "renewals"], position: 4, inserted_at: now, updated_at: now},
      %{id: "arch", name: "Architect", color: "#3ecf8e", focus: ["stack", "horizon", "bench"], position: 5, inserted_at: now, updated_at: now},
      %{id: "staff", name: "Staff Engineer", color: "#7c5cff", focus: ["distill", "package", "tension"], position: 6, inserted_at: now, updated_at: now}
    ]

    repo().insert_all("viewers", seeds)
  end

  defp delete_viewers do
    repo().delete_all("viewers")
  end
end
```

- [ ] **Step 3: Format the migration (the seed maps are long)**

Run: `MIX_ENV=test mix format priv/repo/migrations/<timestamp>_sous_b1_viewers_and_facets.exs`
The seven seed `%{...}` literals each exceed the 98-char line-length limit; `mix format` wraps
them. Without this step, the CI-aligned pre-deploy / pre-commit format check will fail.

- [ ] **Step 4: Run the migration**

Run: `mix ecto.migrate`
Expected: creates the two tables, drops two columns from `work_items`, inserts 7 viewers, no errors.

- [ ] **Step 5: Commit**

```bash
git add priv/repo/migrations
git commit -m "feat(sous): B1 migration — viewers, work_item_facets, drop WorkItem.attention/facet_text"
```

---

## Task 2: `Viewer` schema + changeset

**Files:**
- Create: `lib/slackex/sous/viewer.ex`
- Test: `test/slackex/sous/viewer_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/slackex/sous/viewer_test.exs`:

```elixir
defmodule Slackex.Sous.ViewerTest do
  use Slackex.DataCase, async: true

  alias Slackex.Sous.Viewer

  test "default seed loaded by the B1 migration is queryable" do
    viewers = Repo.all(Viewer)
    ids = viewers |> Enum.map(& &1.id) |> MapSet.new()

    for id <- ~w(ceo cto em product csm arch staff) do
      assert MapSet.member?(ids, id), "expected seeded viewer #{id} to be present"
    end
  end

  test "changeset requires id, name, color" do
    cs = Viewer.changeset(%Viewer{}, %{})
    refute cs.valid?
    assert %{id: _, name: _, color: _} = errors_on(cs)
  end

  test "changeset accepts a full viewer" do
    cs =
      Viewer.changeset(%Viewer{}, %{
        id: "dev",
        name: "Developer",
        color: "#aabbcc",
        focus: ["foo"],
        position: 99
      })

    assert cs.valid?
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/slackex/sous/viewer_test.exs`
Expected: FAIL — `Slackex.Sous.Viewer.__struct__/0 is undefined`.

- [ ] **Step 3: Create the schema**

Create `lib/slackex/sous/viewer.ex`:

```elixir
defmodule Slackex.Sous.Viewer do
  @moduledoc """
  A role-lens. Data-driven (the set is configurable per team), seeded by the
  B1 migration. Viewers are IMMUTABLE in B1 (no delete / no rename) — invariant
  #11 in the Slice B1 spec; role management UI is B-later.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "viewers" do
    field :name, :string
    field :color, :string
    field :focus, {:array, :string}, default: []
    field :position, :integer, default: 0
    timestamps(type: :utc_datetime_usec)
  end

  @doc "Listing in switcher order."
  def order_by_position(query \\ __MODULE__), do: order_by(query, [v], asc: v.position)

  def changeset(viewer, attrs) do
    viewer
    |> cast(attrs, [:id, :name, :color, :focus, :position])
    |> validate_required([:id, :name, :color])
  end
end
```

Add `import Ecto.Query` near the top if needed (the order_by helper). On second look, `order_by` is a macro from `Ecto.Query` — yes, add `import Ecto.Query, only: [order_by: 3]`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/slackex/sous/viewer_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/slackex/sous/viewer.ex test/slackex/sous/viewer_test.exs
git commit -m "feat(sous): Viewer schema (data-driven role-lens, immutable in B1)"
```

---

## Task 3: `WorkItemFacet` schema + changeset

**Files:**
- Create: `lib/slackex/sous/work_item_facet.ex`
- Test: `test/slackex/sous/work_item_facet_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/slackex/sous/work_item_facet_test.exs`:

```elixir
defmodule Slackex.Sous.WorkItemFacetTest do
  use Slackex.DataCase, async: true

  alias Slackex.Sous.WorkItemFacet

  test "attentions/0 enumerates the four values" do
    assert WorkItemFacet.attentions() == [:act, :watch, :know, :hidden]
  end

  test "changeset requires work_item_id, viewer_id, attention" do
    cs = WorkItemFacet.changeset(%WorkItemFacet{}, %{})
    refute cs.valid?
    assert %{work_item_id: _, viewer_id: _, attention: _} = errors_on(cs)
  end

  test "changeset rejects an unknown attention" do
    cs = WorkItemFacet.changeset(%WorkItemFacet{}, %{work_item_id: 1, viewer_id: "cto", attention: :bogus})
    refute cs.valid?
    assert errors_on(cs)[:attention]
  end

  test "valid changeset sets updated_at automatically" do
    cs = WorkItemFacet.changeset(%WorkItemFacet{}, %{work_item_id: 1, viewer_id: "cto", attention: :act})
    assert cs.valid?
    assert get_change(cs, :updated_at)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/slackex/sous/work_item_facet_test.exs`
Expected: FAIL — undefined struct.

- [ ] **Step 3: Create the schema**

Create `lib/slackex/sous/work_item_facet.ex`:

```elixir
defmodule Slackex.Sous.WorkItemFacet do
  @moduledoc """
  Per-(work_item, viewer) facet row. Composite PK. Lazy: absence of a row means
  the default `:watch` (spec invariant #8). B1 stores `attention` only; B2 fills
  `facet_text` via the AI pipeline (`:facet_generated` event).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  @attentions [:act, :watch, :know, :hidden]

  schema "work_item_facets" do
    field :work_item_id, :integer, primary_key: true
    field :viewer_id, :string, primary_key: true
    field :attention, Ecto.Enum, values: @attentions, default: :watch
    field :facet_text, :string
    field :updated_at, :utc_datetime_usec
  end

  @doc "The four attention values, in board sort-rank order."
  def attentions, do: @attentions

  def changeset(facet, attrs) do
    facet
    |> cast(attrs, [:work_item_id, :viewer_id, :attention, :facet_text, :updated_at])
    |> validate_required([:work_item_id, :viewer_id, :attention])
    |> put_updated_at()
  end

  defp put_updated_at(changeset) do
    case get_field(changeset, :updated_at) do
      nil -> put_change(changeset, :updated_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))
      _ -> changeset
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/slackex/sous/work_item_facet_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/slackex/sous/work_item_facet.ex test/slackex/sous/work_item_facet_test.exs
git commit -m "feat(sous): WorkItemFacet schema (composite PK, lazy default :watch)"
```

---

## Task 4: Update `WorkItem` schema — remove the dropped fields from the schema + changeset

**Files:**
- Modify: `lib/slackex/sous/work_item.ex`
- Test: `test/slackex/sous/work_item_test.exs` (existing)

The Slice-A schema declared `:facet_text` and `:attention` fields the migration just dropped. The schema must match the table, or every load raises. Also drop the `@attentions` module attribute (it's now on `WorkItemFacet`).

- [ ] **Step 1: Update the existing test**

Open `test/slackex/sous/work_item_test.exs`. The Slice-A test passed `attention: :watch` in the valid-changeset test — remove that key. Also there's a `rejects an unknown state` test that's unaffected.

Replace the file with:

```elixir
defmodule Slackex.Sous.WorkItemTest do
  use Slackex.DataCase, async: true

  alias Slackex.Sous.WorkItem
  alias Slackex.Infrastructure.Snowflake

  test "changeset derives inserted_at from the Snowflake id" do
    id = Snowflake.generate()

    cs =
      WorkItem.changeset(%WorkItem{}, %{
        id: id,
        kind: :decision,
        state: :mise,
        title: "Adopt event sourcing",
        moved_at: DateTime.utc_now()
      })

    assert cs.valid?
    assert get_change(cs, :inserted_at) == DateTime.from_unix!(Snowflake.extract_timestamp(id) * 1_000, :microsecond)
  end

  test "requires id, kind, state, title" do
    cs = WorkItem.changeset(%WorkItem{}, %{})
    refute cs.valid?
    assert %{id: _, kind: _, state: _, title: _} = errors_on(cs)
  end

  test "rejects an unknown state" do
    cs = WorkItem.changeset(%WorkItem{}, %{id: 1, kind: :decision, state: :nope, title: "x"})
    refute cs.valid?
    assert errors_on(cs)[:state]
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/slackex/sous/work_item_test.exs`
Expected: FAIL — schema still has `:facet_text`/`:attention` fields the DB no longer carries, OR existing tests still cast them. (The exact failure depends on the build cache; the next step makes the schema match the DB.)

- [ ] **Step 3: Update the schema**

Replace the body of `lib/slackex/sous/work_item.ex` with (changes: remove `:facet_text`, remove `:attention`, remove `@attentions`, remove from cast list, and remove the public `attentions/0` helper):

```elixir
defmodule Slackex.Sous.WorkItem do
  @moduledoc """
  The work-item projection (authoritative read model). Maintained inline by
  `Slackex.Sous` commands via `Slackex.Sous.Projection`; every field is
  reconstructable from the `work_item_events` log (spec §6, invariant #6).

  B1: per-viewer `attention` (and later `facet_text`) live on
  `Slackex.Sous.WorkItemFacet`, not here.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Slackex.Infrastructure.Snowflake

  @primary_key {:id, :integer, autogenerate: false}

  @states [:order, :mise, :pass, :walked]
  @kinds [:decision]

  schema "work_items" do
    field :kind, Ecto.Enum, values: @kinds
    field :state, Ecto.Enum, values: @states
    field :title, :string
    field :people, :map, default: %{}
    field :channel_id, :integer
    field :thread_root_message_id, :integer
    field :card_message_id, :integer
    field :moved_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec

    has_one :decision, Slackex.Sous.Decision, foreign_key: :work_item_id, references: :id
    has_many :events, Slackex.Sous.WorkItemEvent, foreign_key: :work_item_id, references: :id
    has_many :facets, Slackex.Sous.WorkItemFacet, foreign_key: :work_item_id, references: :id
  end

  def states, do: @states
  def kinds, do: @kinds

  def changeset(work_item, attrs) do
    work_item
    |> cast(attrs, [
      :id,
      :kind,
      :state,
      :title,
      :people,
      :channel_id,
      :thread_root_message_id,
      :card_message_id,
      :moved_at
    ])
    |> validate_required([:id, :kind, :state, :title])
    |> put_inserted_at()
  end

  defp put_inserted_at(changeset) do
    case get_change(changeset, :id) do
      nil ->
        changeset

      id ->
        ts_ms = Snowflake.extract_timestamp(id)
        put_change(changeset, :inserted_at, DateTime.from_unix!(ts_ms * 1_000, :microsecond))
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/slackex/sous/work_item_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/slackex/sous/work_item.ex test/slackex/sous/work_item_test.exs
git commit -m "refactor(sous): drop Slice-A facet_text/attention fields from WorkItem schema"
```

---

## Task 5: `WorkItemEvent` — add `:attention_set` to `@types`

**Files:**
- Modify: `lib/slackex/sous/work_item_event.ex`

- [ ] **Step 1: Update the `@types`**

In `lib/slackex/sous/work_item_event.ex`, change:

```elixir
@types [:created, :state_changed, :card_posted]
```

to:

```elixir
@types [:created, :state_changed, :card_posted, :attention_set]
```

- [ ] **Step 2: Verify the existing tests still pass**

Run: `mix test test/slackex/sous/work_item_event_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 3: Commit**

```bash
git add lib/slackex/sous/work_item_event.ex
git commit -m "feat(sous): add :attention_set to WorkItemEvent.@types"
```

---

## Task 6: `Projection` — `facets: %{}` in state, `:attention_set` clause, ignore Slice-A facet keys in `:created`

This is the heart of invariants #8 (lazy default), #9 (ignore Slice-A keys), and the one-reducer-two-uses claim for `:attention_set`.

**Files:**
- Modify: `lib/slackex/sous/projection.ex`
- Test: `test/slackex/sous/projection_test.exs` (existing)
- Test (new): `test/slackex/sous/projection_attention_test.exs`

- [ ] **Step 1: Update the existing projection_test.exs**

The existing test asserts the `:created` projection produces `state.work_item.attention == :watch`. After B1, the `work_item` map no longer carries `attention`. Replace `test/slackex/sous/projection_test.exs` with:

```elixir
defmodule Slackex.Sous.ProjectionTest do
  use ExUnit.Case, async: true

  alias Slackex.Sous.{Projection, WorkItemEvent}

  defp ev(id, type, payload), do: %WorkItemEvent{id: id, work_item_id: 10, type: type, payload: payload}

  test "fold :created builds work_item + decision; facets start empty (invariant #8)" do
    created =
      ev(1, :created, %{
        "kind" => "decision",
        "title" => "Adopt ES",
        "state" => "mise",
        "people" => %{"lead" => 7, "stakeholders" => [8, 9]},
        "what" => "Use event sourcing",
        "why" => "audit",
        "next" => "spike",
        "channel_id" => 100,
        "thread_root_message_id" => 555,
        "moved_at" => "2026-05-27T10:00:00.000000Z"
      })

    state = Projection.fold([created])

    assert state.work_item.id == 10
    assert state.work_item.kind == :decision
    assert state.work_item.state == :mise
    assert state.work_item.channel_id == 100
    assert state.work_item.card_message_id == nil
    refute Map.has_key?(state.work_item, :attention)
    refute Map.has_key?(state.work_item, :facet_text)
    assert state.facets == %{}
    assert state.decision.what == "Use event sourcing"
  end

  test "fold :created IGNORES Slice-A facet_text/attention payload keys (invariant #9)" do
    legacy_created =
      ev(1, :created, %{
        "kind" => "decision",
        "title" => "Slice-A legacy",
        "state" => "mise",
        "facet_text" => "Slice-A legacy",
        "attention" => "act",
        "what" => "w",
        "moved_at" => "2026-05-27T10:00:00.000000Z"
      })

    state = Projection.fold([legacy_created])
    refute Map.has_key?(state.work_item, :attention)
    refute Map.has_key?(state.work_item, :facet_text)
    assert state.facets == %{}
  end

  test "fold :state_changed updates state + moved_at; facets untouched" do
    events = [
      ev(1, :created, %{"kind" => "decision", "title" => "x", "state" => "mise", "what" => "w", "moved_at" => "2026-05-27T10:00:00.000000Z"}),
      ev(2, :state_changed, %{"from" => "mise", "to" => "pass", "moved_at" => "2026-05-27T11:00:00.000000Z"})
    ]

    state = Projection.fold(events)
    assert state.work_item.state == :pass
    assert state.work_item.moved_at == ~U[2026-05-27 11:00:00.000000Z]
    assert state.facets == %{}
  end

  test "fold :card_posted sets card_message_id" do
    events = [
      ev(1, :created, %{"kind" => "decision", "title" => "x", "state" => "mise", "what" => "w", "moved_at" => "2026-05-27T10:00:00.000000Z"}),
      ev(3, :card_posted, %{"card_message_id" => 9999})
    ]

    state = Projection.fold(events)
    assert state.work_item.card_message_id == 9999
  end
end
```

- [ ] **Step 2: Write the new attention-projection test**

Create `test/slackex/sous/projection_attention_test.exs`:

```elixir
defmodule Slackex.Sous.ProjectionAttentionTest do
  use ExUnit.Case, async: true

  alias Slackex.Sous.{Projection, WorkItemEvent}

  defp ev(id, type, payload), do: %WorkItemEvent{id: id, work_item_id: 10, type: type, payload: payload}

  test "fold :attention_set upserts per-viewer attention into the facets map" do
    events = [
      ev(1, :created, %{"kind" => "decision", "title" => "x", "state" => "mise", "what" => "w", "moved_at" => "2026-05-27T10:00:00.000000Z"}),
      ev(2, :attention_set, %{"viewer_id" => "cto", "attention" => "act", "actor_user_id" => 42}),
      ev(3, :attention_set, %{"viewer_id" => "ceo", "attention" => "know", "actor_user_id" => 42})
    ]

    state = Projection.fold(events)

    assert state.facets["cto"].attention == :act
    assert state.facets["ceo"].attention == :know
    # Other viewers absent → lazy default (invariant #8)
    refute Map.has_key?(state.facets, "em")
  end

  test "repeated :attention_set events are last-write-wins on the row (spec §5)" do
    events = [
      ev(1, :created, %{"kind" => "decision", "title" => "x", "state" => "mise", "what" => "w", "moved_at" => "2026-05-27T10:00:00.000000Z"}),
      ev(2, :attention_set, %{"viewer_id" => "cto", "attention" => "act", "actor_user_id" => 1}),
      ev(3, :attention_set, %{"viewer_id" => "cto", "attention" => "know", "actor_user_id" => 2}),
      ev(4, :attention_set, %{"viewer_id" => "cto", "attention" => "hidden", "actor_user_id" => 3})
    ]

    state = Projection.fold(events)
    assert state.facets["cto"].attention == :hidden
  end
end
```

- [ ] **Step 3: Run both to verify they fail**

Run: `mix test test/slackex/sous/projection_test.exs test/slackex/sous/projection_attention_test.exs`
Expected: FAIL — `state.facets` key missing, `:attention_set` clause missing.

- [ ] **Step 4: Update the projection module**

Replace the body of `lib/slackex/sous/projection.ex` between `def initial` and the `defp get` line with:

```elixir
  def initial, do: %{work_item: nil, decision: nil, facets: %{}}

  def fold(events) when is_list(events) do
    Enum.reduce(events, initial(), &apply_event(&2, &1))
  end

  def apply_event(_state, %WorkItemEvent{type: :created, work_item_id: wid, payload: p}) do
    # B1 invariant #9: the Slice-A `facet_text` and `attention` keys may be present
    # in legacy `:created` payloads, but the B1 reducer does NOT project them.
    # Per-viewer state comes only from :attention_set (and B2's :facet_generated).
    %{
      work_item: %{
        id: wid,
        kind: to_atom(get(p, "kind")),
        state: to_atom(get(p, "state")),
        title: get(p, "title"),
        people: get(p, "people") || %{},
        channel_id: get(p, "channel_id"),
        thread_root_message_id: get(p, "thread_root_message_id"),
        card_message_id: nil,
        moved_at: to_dt(get(p, "moved_at"))
      },
      decision: %{
        work_item_id: wid,
        what: get(p, "what"),
        why: get(p, "why"),
        next: get(p, "next")
      },
      facets: %{}
    }
  end

  def apply_event(%{work_item: wi} = state, %WorkItemEvent{type: :state_changed, payload: p}) do
    %{
      state
      | work_item: %{wi | state: to_atom(get(p, "to")), moved_at: to_dt(get(p, "moved_at"))}
    }
  end

  def apply_event(%{work_item: wi} = state, %WorkItemEvent{type: :card_posted, payload: p}) do
    %{state | work_item: %{wi | card_message_id: get(p, "card_message_id")}}
  end

  # Invariant #4 (one reducer, two uses): this clause is called inline by
  # `Sous.set_attention/4` AND by replay. Last-write-wins on the row (spec §5).
  def apply_event(state, %WorkItemEvent{type: :attention_set, payload: p}) do
    facets = Map.get(state, :facets, %{})
    viewer_id = get(p, "viewer_id")
    attention = to_atom(get(p, "attention"))

    new_facet =
      facets
      |> Map.get(viewer_id, %{attention: :watch, facet_text: nil})
      |> Map.put(:attention, attention)

    Map.put(state, :facets, Map.put(facets, viewer_id, new_facet))
  end
```

The `defp get`, `defp to_atom`, `defp to_dt` helpers stay unchanged at the bottom of the file.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/slackex/sous/projection_test.exs test/slackex/sous/projection_attention_test.exs`
Expected: PASS (6 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/slackex/sous/projection.ex test/slackex/sous/projection_test.exs test/slackex/sous/projection_attention_test.exs
git commit -m "feat(sous): Projection — facets state + :attention_set; ignore Slice-A facet keys (inv #8/#9)"
```

---

## Task 7: Update `Sous.open_decision` — stop writing Slice-A facet keys; fix existing tests

The Slice-A `open_decision` writes `"facet_text"` and `"attention"` into new `:created` payloads. Per invariant #9 those are vestigial; new events should omit them. This is a cleanup, not a behaviour change (the reducer already ignores them).

**Files:**
- Modify: `lib/slackex/sous.ex`
- Test: `test/slackex/sous_test.exs` (existing — drop `assert wi.attention == :act`)

- [ ] **Step 1: Update the existing sous_test.exs assertions**

Open `test/slackex/sous_test.exs`. In the test "creates a :mise decision with a :created event and a Decision" (around line 18), remove the assertions that read the dropped fields. Replace:

```elixir
      assert wi.kind == :decision
      assert wi.state == :mise
      assert wi.attention == :act
      assert wi.facet_text == "Adopt event sourcing"
      assert wi.channel_id == c.id
```

with:

```elixir
      assert wi.kind == :decision
      assert wi.state == :mise
      assert wi.channel_id == c.id
```

Also in the "replay guard" test (around line 50), remove the `assert folded.attention == wi.attention` line — there's no `attention` field anymore.

- [ ] **Step 2: Run the test to verify it currently fails (or compiles dirty)**

Run: `mix test test/slackex/sous_test.exs`
Expected: at least one failure tied to `wi.attention` / `wi.facet_text` no longer existing OR compile warnings — after the edits above, the failures should be gone. If they pass already (because the projection no longer projects those fields, so any assertion on them was always going to fail at compile), proceed.

- [ ] **Step 3: Update the `open_decision` payload in `lib/slackex/sous.ex`**

Find the `payload = %{ ... }` block in `open_decision/1` (around line 46). Remove the `"facet_text"` and `"attention"` keys; the keys we're removing are:

```elixir
      "facet_text" => attrs[:title],
      # Slice A has no viewer model, so attention is a single stored value. A
      # freshly-made decision demands attention → :act (accent edge + "behind"),
      # so the board shows a real treatment from day one. Attention stays :act for
      # Slice A (no attention control — deferred to Slice B).
      "attention" => "act",
```

After the edit the payload looks like:

```elixir
    payload = %{
      "kind" => "decision",
      "title" => attrs[:title],
      "state" => "mise",
      # B1 (invariant #9): per-viewer attention lives on work_item_facets and is
      # set via :attention_set events. The Slice-A single-viewer facet/attention
      # keys are no longer written into new :created payloads.
      # DRI name is snapshotted into the event (self-describing) so the card
      # renders with no render-time user lookup.
      "people" => %{
        "lead" => lead,
        "lead_name" => attrs[:actor_username],
        "supporting" => [],
        "watching" => [],
        "stakeholders" => stakeholders
      },
      "what" => attrs[:what],
      "why" => attrs[:why],
      "next" => attrs[:next],
      "channel_id" => attrs[:channel_id],
      "thread_root_message_id" => attrs[:thread_root_message_id],
      "moved_at" => DateTime.to_iso8601(now)
    }
```

Also remove the `attention` and `facet_text` keys from the `wi_to_attrs/1` helper at the bottom of `sous.ex`:

```elixir
  defp wi_to_attrs(%WorkItem{} = wi) do
    %{
      id: wi.id,
      kind: wi.kind,
      state: wi.state,
      title: wi.title,
      people: wi.people,
      channel_id: wi.channel_id,
      thread_root_message_id: wi.thread_root_message_id,
      card_message_id: wi.card_message_id,
      moved_at: wi.moved_at
    }
  end
```

(Removed `facet_text:` and `attention:` lines.)

- [ ] **Step 4: Run the existing Sous tests to verify they pass**

Run: `mix test test/slackex/sous_test.exs test/slackex/sous_card_test.exs test/slackex/sous/slice_a_integration_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/slackex/sous.ex test/slackex/sous_test.exs
git commit -m "refactor(sous): open_decision no longer writes Slice-A facet_text/attention keys"
```

---

## Task 8: `Sous.set_attention/4` + `facets_for_viewer/1` + replay-guard extension

**Files:**
- Modify: `lib/slackex/sous.ex`
- Test (new): `test/slackex/sous/set_attention_test.exs`
- Test: `test/slackex/sous_test.exs` (extend replay-guard)

- [ ] **Step 1: Write the failing test**

Create `test/slackex/sous/set_attention_test.exs`:

```elixir
defmodule Slackex.Sous.SetAttentionTest do
  use Slackex.DataCase, async: true

  import Ecto.Query

  alias Slackex.Sous
  alias Slackex.Sous.{WorkItemEvent, WorkItemFacet}
  alias Slackex.Repo

  setup do
    user = insert(:user)
    {:ok, channel} = Slackex.Chat.create_channel(user.id, %{name: "deploys"})

    {:ok, wi} =
      Sous.open_decision(%{
        channel_id: channel.id,
        actor_id: user.id,
        actor_username: user.username,
        title: "Adopt facets",
        what: "Per-viewer attention",
        stakeholders: []
      })

    %{user: user, channel: channel, wi: wi}
  end

  describe "set_attention/4" do
    test "creates a :attention_set event and upserts a WorkItemFacet row", %{user: u, wi: wi} do
      Phoenix.PubSub.subscribe(Slackex.PubSub, Sous.work_items_topic())

      assert {:ok, facet} = Sous.set_attention(wi.id, "cto", :act, u.id)
      assert facet.attention == :act
      assert facet.work_item_id == wi.id
      assert facet.viewer_id == "cto"

      events = Repo.all(from e in WorkItemEvent, where: e.work_item_id == ^wi.id, order_by: e.id)
      assert Enum.map(events, & &1.type) |> Enum.member?(:attention_set)

      assert_receive {:work_item_event, :attention_set, %{work_item_id: id, viewer_id: "cto", attention: :act}}
                       when id == wi.id
    end

    test "is last-write-wins on the row but the log keeps both events", %{user: u, wi: wi} do
      {:ok, _} = Sous.set_attention(wi.id, "cto", :act, u.id)
      {:ok, _} = Sous.set_attention(wi.id, "cto", :hidden, u.id)

      facet = Repo.get_by!(WorkItemFacet, work_item_id: wi.id, viewer_id: "cto")
      assert facet.attention == :hidden

      events =
        Repo.all(from e in WorkItemEvent, where: e.work_item_id == ^wi.id and e.type == :attention_set, order_by: e.id)

      assert length(events) == 2
    end

    test "rejects an unknown viewer", %{user: u, wi: wi} do
      assert {:error, :invalid_viewer} = Sous.set_attention(wi.id, "no_such_role", :act, u.id)
    end

    test "rejects an unknown attention", %{user: u, wi: wi} do
      assert {:error, :invalid_attention} = Sous.set_attention(wi.id, "cto", :bogus, u.id)
    end

    test "rejects an unknown work item", %{user: u} do
      assert {:error, :invalid_work_item} = Sous.set_attention(999_999_999_999, "cto", :act, u.id)
    end
  end

  describe "facets_for_viewer/1" do
    test "returns %{work_item_id => attention} for the viewer; missing rows = nothing", %{user: u, wi: wi} do
      {:ok, _} = Sous.set_attention(wi.id, "cto", :act, u.id)
      {:ok, _} = Sous.set_attention(wi.id, "ceo", :know, u.id)

      assert Sous.facets_for_viewer("cto") == %{wi.id => :act}
      assert Sous.facets_for_viewer("ceo") == %{wi.id => :know}
      assert Sous.facets_for_viewer("em") == %{}
    end
  end
end
```

- [ ] **Step 2: Extend the existing replay-guard test (Slice A invariant #7)**

Open `test/slackex/sous_test.exs`. Find the "the persisted row equals folding its full event log (replay guard, invariant #7)" test (around line 55). Extend it to cover `:attention_set` too. Replace the test body:

```elixir
    test "the persisted row equals folding its full event log (replay guard, invariant #7)", %{user: u, channel: c} do
      {:ok, wi} = Sous.open_decision(%{channel_id: c.id, actor_id: u.id, actor_username: u.username, title: "Replayable", what: "w", why: "y", next: "n", stakeholders: [u.id]})
      {:ok, moved} = Sous.move(wi.id, :pass, u.id)
      {:ok, _} = Sous.set_attention(wi.id, "cto", :act, u.id)
      {:ok, _} = Sous.set_attention(wi.id, "ceo", :hidden, u.id)

      persisted = Repo.get!(WorkItem, wi.id) |> Repo.preload(:decision)
      facet_rows = Repo.all(from f in Slackex.Sous.WorkItemFacet, where: f.work_item_id == ^wi.id)
      events = Repo.all(from e in WorkItemEvent, where: e.work_item_id == ^wi.id, order_by: e.id)

      assert Enum.map(events, & &1.type) == [:created, :state_changed, :attention_set, :attention_set]

      folded = Projection.fold(events)

      for field <- [:id, :kind, :state, :title, :people, :channel_id, :thread_root_message_id, :card_message_id, :moved_at] do
        assert Map.get(folded.work_item, field) == Map.get(persisted, field), "field #{field} diverged"
      end

      assert folded.decision.what == persisted.decision.what
      assert folded.decision.why == persisted.decision.why
      assert folded.decision.next == persisted.decision.next

      # Facets: folded.facets must mirror the persisted rows (lazy default = no row).
      persisted_facets = Map.new(facet_rows, fn f -> {f.viewer_id, f.attention} end)
      folded_facets = Map.new(folded.facets, fn {vid, %{attention: a}} -> {vid, a} end)
      assert folded_facets == persisted_facets
    end
```

- [ ] **Step 3: Run the new + extended tests to confirm they fail**

Run: `mix test test/slackex/sous/set_attention_test.exs test/slackex/sous_test.exs`
Expected: FAIL — `Sous.set_attention/4` / `Sous.facets_for_viewer/1` undefined.

- [ ] **Step 4: Add `set_attention/4` + `facets_for_viewer/1` to `lib/slackex/sous.ex`**

Add `alias Slackex.Sous.{Viewer, WorkItemFacet}` to the alias block at the top (extending the existing `alias Slackex.Sous.{Decision, Projection, WorkItem, WorkItemEvent}` line — make it `alias Slackex.Sous.{Decision, Projection, Viewer, WorkItem, WorkItemEvent, WorkItemFacet}`).

Add these public functions inside the module (place near the other commands, e.g. just after `move/3`):

```elixir
  @doc """
  Sets the attention of `viewer_id` for `work_item_id` to `attention`. Appends a
  `:attention_set` event and upserts the `WorkItemFacet` row (last-write-wins).

  `attention` must be in `WorkItemFacet.attentions/0`; `viewer_id` must reference
  an existing `Viewer` row (immutable in B1, invariant #11).
  """
  def set_attention(work_item_id, viewer_id, attention, actor_id) do
    cond do
      attention not in WorkItemFacet.attentions() ->
        {:error, :invalid_attention}

      not Repo.exists?(from v in Viewer, where: v.id == ^viewer_id) ->
        {:error, :invalid_viewer}

      not Repo.exists?(from w in WorkItem, where: w.id == ^work_item_id) ->
        {:error, :invalid_work_item}

      true ->
        do_set_attention(work_item_id, viewer_id, attention, actor_id)
    end
  end

  @doc """
  Per-viewer attention map for the In Service board.
  Returns `%{work_item_id => attention_atom}` for rows where this viewer has been
  triaged; absence = default `:watch` (the caller resolves).
  """
  def facets_for_viewer(viewer_id) when is_binary(viewer_id) do
    from(f in WorkItemFacet,
      where: f.viewer_id == ^viewer_id,
      select: {f.work_item_id, f.attention}
    )
    |> Repo.all()
    |> Map.new()
  end

  def facets_for_viewer(nil), do: %{}

  defp do_set_attention(work_item_id, viewer_id, attention, actor_id) do
    event = %WorkItemEvent{
      id: Snowflake.generate(),
      work_item_id: work_item_id,
      type: :attention_set,
      payload: %{
        "viewer_id" => viewer_id,
        "attention" => Atom.to_string(attention),
        "actor_user_id" => actor_id
      },
      actor_user_id: actor_id
    }

    # Invariant #4 (one reducer, two uses): derive the row attrs through the
    # same Projection.apply_event the replay path uses.
    projected = Projection.apply_event(%{facets: %{}}, event)

    facet_attrs =
      projected.facets[viewer_id]
      |> Map.put(:work_item_id, work_item_id)
      |> Map.put(:viewer_id, viewer_id)

    Multi.new()
    |> Multi.insert(:event, WorkItemEvent.changeset(%WorkItemEvent{}, Map.from_struct(event)))
    |> Multi.insert(
      :facet,
      WorkItemFacet.changeset(%WorkItemFacet{}, facet_attrs),
      on_conflict: {:replace, [:attention, :updated_at]},
      conflict_target: [:work_item_id, :viewer_id]
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{facet: facet}} ->
        _ =
          Phoenix.PubSub.broadcast(
            @pubsub,
            @work_items_topic,
            {:work_item_event, :attention_set,
             %{work_item_id: work_item_id, viewer_id: viewer_id, attention: attention}}
          )

        {:ok, facet}

      {:error, _step, changeset, _} ->
        {:error, changeset}
    end
  end
```

- [ ] **Step 5: Run all Sous tests to confirm green**

Run: `mix test test/slackex/sous`
Expected: PASS (all Sous unit + integration tests).

- [ ] **Step 6: Commit**

```bash
git add lib/slackex/sous.ex test/slackex/sous/set_attention_test.exs test/slackex/sous_test.exs
git commit -m "feat(sous): Sous.set_attention/4 + facets_for_viewer/1 (replay-guard extended)"
```

---

## Task 9: `ViewerPreference` behaviour + LocalStorage store + InMemoryStore (test/support)

Invariant #10: every viewer-preference read/write goes through the `ViewerPreference` module; no LiveView/component touches a store directly. B1 ships the LocalStorage backend; the test-support InMemoryStore exists to *prove* the seam (Task 10).

**Files:**
- Create: `lib/slackex/sous/viewer_preference.ex`
- Create: `lib/slackex/sous/viewer_preference/store.ex`
- Create: `lib/slackex/sous/viewer_preference/local_storage.ex`
- Create: `test/support/sous/in_memory_viewer_preference_store.ex`

- [ ] **Step 1: Create the behaviour**

Create `lib/slackex/sous/viewer_preference/store.ex`:

```elixir
defmodule Slackex.Sous.ViewerPreference.Store do
  @moduledoc """
  Behaviour for `Slackex.Sous.ViewerPreference` backends.

  Implementations:
    * `Slackex.Sous.ViewerPreference.LocalStorage` — B1 default, JS-hook backed.
    * `Slackex.Sous.ViewerPreference.InMemoryStore`  — test-only; proves the seam.
    * (Future) a DB-backed `Repo` store.

  The interface is deliberately tiny — invariant #10 keeps it from leaking into
  call sites, so swapping backends never reshuffles LiveView/component code.
  """

  @callback load(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  @callback save(Phoenix.LiveView.Socket.t(), String.t() | nil) :: Phoenix.LiveView.Socket.t()
end
```

- [ ] **Step 2: Create the facade**

Create `lib/slackex/sous/viewer_preference.ex`:

```elixir
defmodule Slackex.Sous.ViewerPreference do
  @moduledoc """
  The encapsulated viewer-preference seam (Slice B1 invariant #10).

  ALL viewer-preference reads/writes go through this module; LiveViews and
  components never call the underlying store directly. A future swap to a
  DB-backed store is a one-line config change — the LocalStorage default and
  the InMemoryStore (test-only) both implement
  `Slackex.Sous.ViewerPreference.Store`.

  Config:

      config :slackex, :viewer_preference_store,
        Slackex.Sous.ViewerPreference.LocalStorage
  """

  @doc "The viewer assigned to the socket before the client has loaded a preference."
  def default_viewer_id, do: nil

  @doc "Backend-specific load (called from LiveView mount)."
  def load(socket), do: store().load(socket)

  @doc "Set the active viewer; persists via the configured store. `viewer_id` may be nil (the null lens)."
  def put(socket, viewer_id) when is_binary(viewer_id) or is_nil(viewer_id) do
    store().save(socket, viewer_id)
  end

  defp store do
    Application.get_env(
      :slackex,
      :viewer_preference_store,
      Slackex.Sous.ViewerPreference.LocalStorage
    )
  end
end
```

- [ ] **Step 3: Create the LocalStorage store**

Create `lib/slackex/sous/viewer_preference/local_storage.ex`:

```elixir
defmodule Slackex.Sous.ViewerPreference.LocalStorage do
  @moduledoc """
  B1 default `ViewerPreference.Store` — state lives in the browser's
  localStorage via the `assets/js/hooks/viewer_prefs.js` hook.

    * `load/1` — assigns the default viewer (`nil`). The JS hook fires
      `"viewer_pref:loaded"` with the stored slug shortly after connect;
      `SlackexWeb.SousLive.InService` handles that event.
    * `save/2` — updates the assign AND pushes `"viewer_pref:save"` to the JS
      hook so localStorage is updated.
  """

  @behaviour Slackex.Sous.ViewerPreference.Store

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  @impl true
  def load(socket) do
    assign(socket, :active_viewer_id, Slackex.Sous.ViewerPreference.default_viewer_id())
  end

  @impl true
  def save(socket, viewer_id) do
    socket
    |> assign(:active_viewer_id, viewer_id)
    |> push_event("viewer_pref:save", %{viewer_id: viewer_id})
  end
end
```

- [ ] **Step 4: Create the test-only InMemoryStore**

Create `test/support/sous/in_memory_viewer_preference_store.ex`:

```elixir
defmodule Slackex.Sous.ViewerPreference.InMemoryStore do
  @moduledoc """
  Test-only `ViewerPreference.Store` — assigns only, no JS hook, no DB.
  Used by `viewer_preference_seam_test.exs` to prove the encapsulation seam
  (Slice B1 invariant #10).
  """

  @behaviour Slackex.Sous.ViewerPreference.Store

  import Phoenix.Component, only: [assign: 3]

  @impl true
  def load(socket) do
    assign(socket, :active_viewer_id, Slackex.Sous.ViewerPreference.default_viewer_id())
  end

  @impl true
  def save(socket, viewer_id), do: assign(socket, :active_viewer_id, viewer_id)
end
```

Also ensure `test/support` is compiled in `test` env — it already is (`elixirc_paths(:test) = ["lib", "test/support"]`), no change required to `mix.exs`.

- [ ] **Step 5: Verify it compiles**

Run: `MIX_ENV=test mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add lib/slackex/sous/viewer_preference.ex lib/slackex/sous/viewer_preference/store.ex lib/slackex/sous/viewer_preference/local_storage.ex test/support/sous/in_memory_viewer_preference_store.ex
git commit -m "feat(sous): ViewerPreference behaviour + LocalStorage + InMemoryStore (inv #10)"
```

---

## Task 10: ViewerPreference seam test — prove the swap works (invariant #10)

**Files:**
- Test (new): `test/slackex_web/live/sous_live/viewer_preference_seam_test.exs`

- [ ] **Step 1: Write the test**

Create `test/slackex_web/live/sous_live/viewer_preference_seam_test.exs`:

```elixir
defmodule SlackexWeb.SousLive.ViewerPreferenceSeamTest do
  @moduledoc """
  Proves invariant #10 (Slice B1 spec): a `ViewerPreference.Store` swap is a
  one-line config change. The InMemoryStore implements the behaviour; flipping
  the app env to it must not require any change to call sites — the board
  renders and the switcher works.

  `async: false` because the test rebinds `:viewer_preference_store` globally
  (and restores it via on_exit).
  """

  use SlackexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Slackex.Sous

  setup %{conn: conn} do
    FunWithFlags.enable(:sous)
    on_exit(fn -> FunWithFlags.enable(:sous) end)

    original = Application.get_env(:slackex, :viewer_preference_store)
    Application.put_env(:slackex, :viewer_preference_store, Slackex.Sous.ViewerPreference.InMemoryStore)
    on_exit(fn -> Application.put_env(:slackex, :viewer_preference_store, original) end)

    user = insert(:user, username: "alice")
    {:ok, channel} = Slackex.Chat.create_channel(user.id, %{name: "deploys"})

    {:ok, wi} =
      Sous.open_decision(%{
        channel_id: channel.id,
        actor_id: user.id,
        actor_username: user.username,
        title: "Seam decision",
        what: "w",
        stakeholders: []
      })

    %{conn: log_in_user(conn, user), user: user, wi: wi}
  end

  test "the In Service board renders against the InMemoryStore — no LocalStorage hook in play", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/in-service")
    assert html =~ "In Service"

    # The store backs ViewerPreference; switching viewer still works via the
    # switcher (default render shows "All" selected).
    assert render(lv) =~ "All"
  end
end
```

(This file references the switcher's "All" label, set in Task 11.)

- [ ] **Step 2: Note that this test is committed RED until Task 13 wires the switcher**

Run: `mix test test/slackex_web/live/sous_live/viewer_preference_seam_test.exs`
Expected: FAIL with a clear message about the switcher not yet rendering "All" or the LiveView crashing on the missing assign. This is OK — Task 13 wires the switcher and turns this green.

To avoid a red test blocking commits, **tag the test `@tag :pending_b1_task13`** and skip it via `ExUnit.configure(exclude: [:pending_b1_task13])` for the rest of the plan. Add this single tag line right above the test:

```elixir
    @tag :pending_b1_task13
    test "the In Service board renders against the InMemoryStore — no LocalStorage hook in play", %{conn: conn} do
```

Re-run: `mix test test/slackex_web/live/sous_live/viewer_preference_seam_test.exs --include pending_b1_task13` → still RED (expected). The default suite skips it.

- [ ] **Step 3: Commit**

```bash
git add test/slackex_web/live/sous_live/viewer_preference_seam_test.exs
git commit -m "test(sous): ViewerPreference seam test (pending wiring in Task 13)"
```

---

## Task 11: Viewer switcher (function component)

A small function component the In Service board renders. Returns `phx-click="select_viewer"` events on the parent LiveView.

**Files:**
- Create: `lib/slackex_web/live/sous_live/viewer_switcher.ex`

- [ ] **Step 1: Create the component**

Create `lib/slackex_web/live/sous_live/viewer_switcher.ex`:

```elixir
defmodule SlackexWeb.SousLive.ViewerSwitcher do
  @moduledoc """
  Top-bar "Reading as" switcher. Function component; the parent LiveView
  handles the `select_viewer` events and routes them through
  `Slackex.Sous.ViewerPreference.put/2`.

  A null option ("All / no lens") is the default until the user picks — the
  honest default per spec §3 + §7.1. With the null option active every card
  resolves to `:watch` and the board shows shared shape (identical to Slice A).
  """

  use Phoenix.Component

  attr :viewers, :list, required: true
  attr :active_viewer_id, :string, default: nil

  def viewer_switcher(assigns) do
    ~H"""
    <div class="flex items-center gap-2" aria-label="Reading as">
      <span class="text-sm text-base-content/60">Reading as:</span>

      <button
        type="button"
        phx-click="select_viewer"
        phx-value-id=""
        class={[
          "btn btn-xs",
          @active_viewer_id == nil && "btn-primary" || "btn-ghost"
        ]}
        aria-pressed={@active_viewer_id == nil}
      >
        All
      </button>

      <button
        :for={v <- @viewers}
        type="button"
        phx-click="select_viewer"
        phx-value-id={v.id}
        class={[
          "btn btn-xs",
          @active_viewer_id == v.id && "btn-primary" || "btn-ghost"
        ]}
        aria-pressed={@active_viewer_id == v.id}
      >
        <span style={"color: #{v.color}"} aria-hidden="true">●</span>
        {v.name}
      </button>
    </div>
    """
  end
end
```

- [ ] **Step 2: Verify it compiles**

Run: `MIX_ENV=test mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add lib/slackex_web/live/sous_live/viewer_switcher.ex
git commit -m "feat(sous): ViewerSwitcher function component (null default)"
```

---

## Task 12: FacetDrawer LiveComponent — prism grid + 4-pill selector

**Files:**
- Create: `lib/slackex_web/live/sous_live/facet_drawer_component.ex`
- Test (new): `test/slackex_web/live/sous_live/facet_drawer_test.exs`

- [ ] **Step 1: Write the test**

Create `test/slackex_web/live/sous_live/facet_drawer_test.exs`:

```elixir
defmodule SlackexWeb.SousLive.FacetDrawerTest do
  use SlackexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Slackex.Sous

  setup %{conn: conn} do
    FunWithFlags.enable(:sous)
    on_exit(fn -> FunWithFlags.enable(:sous) end)

    user = insert(:user, username: "alice")
    {:ok, channel} = Slackex.Chat.create_channel(user.id, %{name: "deploys"})

    {:ok, wi} =
      Sous.open_decision(%{
        channel_id: channel.id,
        actor_id: user.id,
        actor_username: user.username,
        title: "Drawer me",
        what: "the what",
        why: "the why",
        next: "the next",
        stakeholders: []
      })

    %{conn: log_in_user(conn, user), user: user, wi: wi}
  end

  test "clicking a card opens the drawer with the atom + a prism per seeded viewer", %{conn: conn, wi: wi} do
    {:ok, lv, _} = live(conn, ~p"/in-service")

    lv |> element(~s{[data-work-item="#{wi.id}"]}) |> render_click()

    html = render(lv)
    assert html =~ "Drawer me"
    assert html =~ "the what"
    # All 7 seeded viewers render as a prism.
    for v <- ~w(CEO CTO EM Product CSM Architect Staff) do
      assert html =~ v, "expected prism for #{v}"
    end
  end

  test "selecting an attention in a prism's 4-pill selector triages that viewer", %{conn: conn, wi: wi, user: u} do
    {:ok, lv, _} = live(conn, ~p"/in-service")

    lv |> element(~s{[data-work-item="#{wi.id}"]}) |> render_click()

    # The selector is rendered with 4 pills; selecting :act for the CTO prism
    # emits "triage_attention" with viewer_id=cto, attention=act.
    render_hook(lv, "triage_attention", %{"work_item_id" => Integer.to_string(wi.id), "viewer_id" => "cto", "attention" => "act"})

    facet = Slackex.Repo.get_by!(Slackex.Sous.WorkItemFacet, work_item_id: wi.id, viewer_id: "cto")
    assert facet.attention == :act
    _ = u
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/slackex_web/live/sous_live/facet_drawer_test.exs`
Expected: FAIL — drawer component not present.

- [ ] **Step 3: Create the LiveComponent**

Create `lib/slackex_web/live/sous_live/facet_drawer_component.ex`:

```elixir
defmodule SlackexWeb.SousLive.FacetDrawerComponent do
  @moduledoc """
  The Facet Drawer — same atom rendered through each viewer's prism. Triage
  in-place via a 4-pill selector (Slice B1 spec §7.3). The parent LiveView
  (`SlackexWeb.SousLive.InService`) controls visibility (open/close) and
  receives `triage_attention` events via `phx-target={@myself}` from this
  component, OR via `render_hook` from tests.

  Three dismiss mechanisms per project UI convention: backdrop click, Escape,
  and an explicit X button.
  """

  use SlackexWeb, :live_component

  alias Slackex.Sous.WorkItemFacet

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("close_drawer", _params, socket) do
    send(self(), :close_facet_drawer)
    {:noreply, socket}
  end

  def handle_event("triage_attention", params, socket) do
    send(self(), {:triage_attention, params})
    {:noreply, socket}
  end

  defp attention_pill_class(active?, _value) do
    if active?, do: "btn-primary", else: "btn-ghost"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="facet-drawer"
      phx-window-keydown="close_drawer"
      phx-key="Escape"
      phx-target={@myself}
    >
      <div
        class="fixed inset-0 z-40 bg-black/50"
        phx-click="close_drawer"
        phx-target={@myself}
      />

      <div class="fixed inset-y-0 right-0 z-50 w-full sm:max-w-xl bg-base-100 shadow-xl flex flex-col">
        <div class="p-4 border-b border-base-300 flex items-center justify-between">
          <h3 class="loom-modal-title font-bold text-lg">{@work_item.title}</h3>
          <button
            type="button"
            phx-click="close_drawer"
            phx-target={@myself}
            class="btn btn-ghost btn-sm btn-square"
            aria-label="Close"
          >
            <span class="hero-x-mark size-5" />
          </button>
        </div>

        <div class="p-4 space-y-2 border-b border-base-300 text-sm">
          <p>
            DRI: {@work_item.people["lead_name"] || "—"} · State: {@work_item.state}
          </p>
          <p :if={@work_item.decision}><span class="font-medium">What:</span> {@work_item.decision.what}</p>
          <p :if={@work_item.decision && @work_item.decision.why not in [nil, ""]}><span class="font-medium">Why:</span> {@work_item.decision.why}</p>
          <p :if={@work_item.decision && @work_item.decision.next not in [nil, ""]}><span class="font-medium">Next:</span> {@work_item.decision.next}</p>
        </div>

        <div class="flex-1 overflow-y-auto p-4 space-y-3">
          <h4 class="text-sm uppercase tracking-wide text-base-content/60">Prisms</h4>
          <div
            :for={v <- @viewers}
            class="rounded-lg border border-base-300 p-3"
            data-prism={v.id}
          >
            <div class="flex items-center gap-2 mb-2">
              <span style={"color: #{v.color}"} aria-hidden="true">●</span>
              <span class="font-medium">{v.name}</span>
            </div>
            <div class="flex flex-wrap gap-1">
              <% current = Map.get(@facets, v.id, :watch) %>
              <button
                :for={a <- WorkItemFacet.attentions()}
                type="button"
                phx-click="triage_attention"
                phx-value-work_item_id={@work_item.id}
                phx-value-viewer_id={v.id}
                phx-value-attention={Atom.to_string(a)}
                phx-target={@myself}
                class={["btn btn-xs", attention_pill_class(current == a, a)]}
                aria-pressed={current == a}
              >
                {Atom.to_string(a)}
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
```

The drawer relies on three new parent assigns (wired in Task 13):

* `@drawer_work_item` — the currently-opened work item (with `:decision` preloaded), or `nil`.
* `@viewers` — list of `Viewer` rows in `position` order.
* `@drawer_facets` — `%{viewer_id => attention}` for the open atom (the parent computes from a query).

Task 13 wires the parent.

- [ ] **Step 4: The test will go green together with Task 13's parent wiring**

For now mark the file as committed; the test will pass after Task 13. (Same pattern as Task 10 — the seam test is pending until the parent wires it.)

Tag the two drawer tests `@tag :pending_b1_task13` to keep the default suite green for now:

```elixir
    @tag :pending_b1_task13
    test "clicking a card opens the drawer...
    ...
    @tag :pending_b1_task13
    test "selecting an attention in a prism's 4-pill selector...
```

- [ ] **Step 5: Verify it compiles**

Run: `MIX_ENV=test mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add lib/slackex_web/live/sous_live/facet_drawer_component.ex test/slackex_web/live/sous_live/facet_drawer_test.exs
git commit -m "feat(sous): FacetDrawer LiveComponent (4-pill selector, pending parent in Task 13)"
```

---

## Task 13: Extend `InService` — switcher, facet-map, per-viewer reshape, "+N hidden" toggle, click→drawer, JS hook

This is the integration task. It wires Tasks 9–12 into the board, adds the JS hook, and turns the pending tests from Tasks 10/12 green.

**Files:**
- Modify: `lib/slackex_web/live/sous_live/in_service.ex`
- Create: `assets/js/hooks/viewer_prefs.js`
- Modify: `assets/js/app.js` (register hook)
- Test (new): `test/slackex_web/live/sous_live/in_service_lens_test.exs`

- [ ] **Step 1: Write the integration test (board reshape + hidden toggle + lazy default)**

Create `test/slackex_web/live/sous_live/in_service_lens_test.exs`:

```elixir
defmodule SlackexWeb.SousLive.InServiceLensTest do
  use SlackexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Slackex.Sous

  setup %{conn: conn} do
    FunWithFlags.enable(:sous)
    on_exit(fn -> FunWithFlags.enable(:sous) end)

    user = insert(:user, username: "alice")
    {:ok, channel} = Slackex.Chat.create_channel(user.id, %{name: "deploys"})

    {:ok, a} = Sous.open_decision(%{channel_id: channel.id, actor_id: user.id, actor_username: user.username, title: "Alpha", what: "w", stakeholders: []})
    {:ok, b} = Sous.open_decision(%{channel_id: channel.id, actor_id: user.id, actor_username: user.username, title: "Beta",  what: "w", stakeholders: []})

    %{conn: log_in_user(conn, user), user: user, wi_a: a, wi_b: b}
  end

  test "default lens (null / 'All') resolves every card to :watch with no errors (invariant #8 behavioural)", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/in-service")
    assert html =~ "Alpha"
    assert html =~ "Beta"
    assert html =~ "All"
  end

  test "selecting a viewer reshapes the board by that viewer's attentions", %{conn: conn, user: u, wi_a: a, wi_b: b} do
    {:ok, _} = Sous.set_attention(a.id, "cto", :act, u.id)
    {:ok, _} = Sous.set_attention(b.id, "cto", :hidden, u.id)

    {:ok, lv, _} = live(conn, ~p"/in-service")
    render_click(lv, "select_viewer", %{"id" => "cto"})
    html = render(lv)

    assert html =~ "Alpha"     # :act — visible
    refute html =~ "Beta"      # :hidden — not rendered
    assert html =~ "+1 not at your altitude"
  end

  test "'+N not at your altitude' toggle reveals hidden cards (session-only assign)", %{conn: conn, user: u, wi_a: _a, wi_b: b} do
    {:ok, _} = Sous.set_attention(b.id, "cto", :hidden, u.id)

    {:ok, lv, _} = live(conn, ~p"/in-service")
    render_click(lv, "select_viewer", %{"id" => "cto"})

    refute render(lv) =~ "Beta"
    render_click(lv, "toggle_hidden", %{"column" => "mise"})
    assert render(lv) =~ "Beta"
  end

  test "switching back to 'All' restores the Slice-A shared shape", %{conn: conn, user: u, wi_a: a, wi_b: b} do
    {:ok, _} = Sous.set_attention(a.id, "cto", :act, u.id)
    {:ok, _} = Sous.set_attention(b.id, "cto", :hidden, u.id)

    {:ok, lv, _} = live(conn, ~p"/in-service")
    render_click(lv, "select_viewer", %{"id" => "cto"})
    render_click(lv, "select_viewer", %{"id" => ""})

    html = render(lv)
    assert html =~ "Alpha"
    assert html =~ "Beta"
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/slackex_web/live/sous_live/in_service_lens_test.exs`
Expected: FAIL — `select_viewer` / `toggle_hidden` handlers + facet map / hidden treatment / drawer wiring not yet present.

- [ ] **Step 3: Replace `lib/slackex_web/live/sous_live/in_service.ex`**

Open `lib/slackex_web/live/sous_live/in_service.ex` and replace its contents with:

```elixir
defmodule SlackexWeb.SousLive.InService do
  @moduledoc """
  In Service board (Slice B1).

  Behaviour change from Slice A (named explicitly per spec §7.2): per-column
  sort is `act > watch > know` then `inserted_at desc`. With the null default
  lens (no viewer picked) every card resolves to `:watch` and the sort falls
  back to pure recency — identical to Slice A. Reshaping is opt-in by picking
  a lens via the "Reading as" switcher.
  """
  use SlackexWeb, :live_view

  import Ecto.Query
  import SlackexWeb.SousLive.ViewerSwitcher

  alias Slackex.Repo
  alias Slackex.Sous
  alias Slackex.Sous.{Viewer, WorkItemFacet}

  @columns [
    {:order, "Order"},
    {:mise, "Mise"},
    {:pass, "Pass"},
    {:walked, "Walked"}
  ]

  @attention_rank %{act: 0, watch: 1, know: 2, hidden: 3}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if FunWithFlags.enabled?(:sous, for: user) do
      if connected?(socket), do: Phoenix.PubSub.subscribe(Slackex.PubSub, Sous.work_items_topic())

      viewers = Repo.all(Viewer.order_by_position())

      socket =
        socket
        |> assign(:loom, true)
        |> assign(:columns, @columns)
        |> assign(:viewers, viewers)
        |> assign(:grouped, Sous.list_in_flight())
        |> assign(:facet_map, %{})
        |> assign(:show_hidden, %{order: false, mise: false, pass: false, walked: false})
        |> assign(:drawer_work_item, nil)
        |> assign(:drawer_facets, %{})
        |> Slackex.Sous.ViewerPreference.load()

      {:ok, socket}
    else
      {:ok, socket |> put_flash(:error, "Not available.") |> redirect(to: ~p"/chat")}
    end
  end

  # ---------------------------------------------------------------------------
  # Switcher / hidden toggle
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("select_viewer", %{"id" => raw_id}, socket) do
    viewer_id = if raw_id == "", do: nil, else: raw_id

    socket =
      socket
      |> Slackex.Sous.ViewerPreference.put(viewer_id)
      |> assign(:facet_map, Sous.facets_for_viewer(viewer_id))

    {:noreply, socket}
  end

  def handle_event("viewer_pref:loaded", %{"viewer_id" => viewer_id}, socket) do
    # Bridge from the JS hook — same effect as a user click on the switcher.
    viewer_id = if viewer_id in [nil, ""], do: nil, else: viewer_id

    socket =
      socket
      |> Slackex.Sous.ViewerPreference.put(viewer_id)
      |> assign(:facet_map, Sous.facets_for_viewer(viewer_id))

    {:noreply, socket}
  end

  def handle_event("toggle_hidden", %{"column" => column}, socket) do
    col = String.to_existing_atom(column)
    {:noreply, update(socket, :show_hidden, &Map.put(&1, col, not Map.get(&1, col, false)))}
  end

  # ---------------------------------------------------------------------------
  # Card moves (unchanged from Slice A) and drawer
  # ---------------------------------------------------------------------------

  def handle_event("move_work_item", %{"id" => id, "to" => to}, socket) do
    _ = Sous.move(String.to_integer(id), String.to_existing_atom(to), socket.assigns.current_user.id)
    {:noreply, assign(socket, :grouped, Sous.list_in_flight())}
  end

  def handle_event("open_drawer", %{"id" => id}, socket) do
    wi_id = String.to_integer(id)
    wi = find_work_item(socket, wi_id) |> Repo.preload(:decision)
    {:noreply, socket |> assign(:drawer_work_item, wi) |> assign(:drawer_facets, drawer_facets_for(wi_id))}
  end

  # ---------------------------------------------------------------------------
  # Broadcasts
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:work_item_event, :attention_set, %{viewer_id: vid}}, socket) do
    socket =
      if socket.assigns.active_viewer_id == vid do
        assign(socket, :facet_map, Sous.facets_for_viewer(vid))
      else
        socket
      end

    socket =
      if drawer = socket.assigns.drawer_work_item do
        assign(socket, :drawer_facets, drawer_facets_for(drawer.id))
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:work_item_event, _type, _wi}, socket) do
    {:noreply, assign(socket, :grouped, Sous.list_in_flight())}
  end

  def handle_info(:close_facet_drawer, socket) do
    {:noreply, socket |> assign(:drawer_work_item, nil) |> assign(:drawer_facets, %{})}
  end

  def handle_info({:triage_attention, %{"work_item_id" => wi_id, "viewer_id" => vid, "attention" => att}}, socket) do
    _ =
      Sous.set_attention(
        String.to_integer(wi_id),
        vid,
        String.to_existing_atom(att),
        socket.assigns.current_user.id
      )

    # Optimistic local refresh; the broadcast will arrive too.
    socket =
      if drawer = socket.assigns.drawer_work_item do
        assign(socket, :drawer_facets, drawer_facets_for(drawer.id))
      else
        socket
      end

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Helpers (sort / classify / lookup)
  # ---------------------------------------------------------------------------

  defp attention_for(wi, %{} = facet_map), do: Map.get(facet_map, wi.id, :watch)

  defp sorted_for(state, %{grouped: grouped, facet_map: fm, show_hidden: sh}) do
    items = Map.get(grouped, state, [])

    visible =
      items
      |> Enum.reject(fn wi ->
        attention_for(wi, fm) == :hidden and not Map.get(sh, state, false)
      end)
      |> Enum.sort_by(fn wi ->
        {Map.fetch!(@attention_rank, attention_for(wi, fm)), wi.id}
      end)

    hidden_count =
      Enum.count(items, fn wi -> attention_for(wi, fm) == :hidden end)

    {visible, hidden_count}
  end

  defp attention_class(:act),    do: "border-l-4 border-primary"
  defp attention_class(:watch),  do: "border border-base-300"
  defp attention_class(:know),   do: "border border-dashed border-base-300 opacity-60"
  defp attention_class(:hidden), do: "border border-dashed border-base-300 opacity-40 italic"

  defp find_work_item(%{assigns: %{grouped: grouped}}, wi_id) do
    grouped
    |> Map.values()
    |> List.flatten()
    |> Enum.find(&(&1.id == wi_id))
  end

  defp drawer_facets_for(wi_id) do
    # The drawer needs `%{viewer_id => attention}` for all viewers; default :watch
    # is applied by the caller (the WorkItemFacet rows are lazy — invariant #8).
    Repo.all(from f in WorkItemFacet, where: f.work_item_id == ^wi_id)
    |> Map.new(fn f -> {f.viewer_id, f.attention} end)
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="loom fixed inset-0 z-50 bg-base-200 overflow-auto p-6"
      id="in-service-board"
      phx-hook="ViewerPrefs"
    >
      <div class="flex items-center justify-between mb-4 gap-4">
        <h1 class="loom-modal-title text-2xl font-bold">In Service</h1>
        <.viewer_switcher viewers={@viewers} active_viewer_id={@active_viewer_id} />
        <.link navigate={~p"/chat"} class="btn btn-ghost btn-sm">Close</.link>
      </div>

      <div class="grid grid-cols-4 gap-4">
        <div :for={{state, label} <- @columns} class="flex flex-col gap-2">
          <h2 class="text-sm uppercase tracking-wide text-base-content/60">{label}</h2>

          <% {visible, hidden_count} = sorted_for(state, assigns) %>

          <div
            :for={wi <- visible}
            class={[
              "rounded-lg bg-base-100 p-3 cursor-pointer",
              attention_class(attention_for(wi, @facet_map))
            ]}
            data-work-item={wi.id}
            phx-click="open_drawer"
            phx-value-id={wi.id}
          >
            <p class="font-semibold">{wi.title}</p>
            <p :if={attention_for(wi, @facet_map) == :act} class="text-xs text-primary">behind</p>

            <div :if={attention_for(wi, @facet_map) != :know} class="mt-2 flex flex-wrap gap-1">
              <button
                :for={{target, target_label} <- @columns}
                :if={target != state}
                phx-click="move_work_item"
                phx-value-id={wi.id}
                phx-value-to={target}
                class="btn btn-xs btn-ghost"
              >
                → {target_label}
              </button>
            </div>
          </div>

          <p :if={visible == []} class="text-xs text-base-content/40">—</p>

          <button
            :if={hidden_count > 0 and not Map.get(@show_hidden, state, false)}
            type="button"
            phx-click="toggle_hidden"
            phx-value-column={Atom.to_string(state)}
            class="btn btn-xs btn-ghost text-base-content/60"
          >
            +{hidden_count} not at your altitude
          </button>
        </div>
      </div>

      <.live_component
        :if={@drawer_work_item}
        module={SlackexWeb.SousLive.FacetDrawerComponent}
        id="facet-drawer"
        work_item={@drawer_work_item}
        viewers={@viewers}
        facets={@drawer_facets}
      />
    </div>
    """
  end
end
```

Notes on the file:
- Imports: `Ecto.Query` (for the `from` macro in `drawer_facets_for/1`), `SlackexWeb.SousLive.ViewerSwitcher` (the function component).
- Aliases: `Slackex.Repo`, `Slackex.Sous`, `Slackex.Sous.{Viewer, WorkItemFacet}`.
- The `attention_class(:hidden)` branch is a dead path under normal flow (the hidden-toggle controls *visibility*, not class) but is kept so `render` is total over `WorkItemFacet.attentions/0`.

- [ ] **Step 4: Create the JS hook**

Create `assets/js/hooks/viewer_prefs.js`:

```javascript
// Slice B1: read/write the active viewer slug from localStorage.
// The LiveView is the source of truth at runtime; this hook syncs the browser.
export default {
  mounted() {
    const stored = window.localStorage.getItem("sous:viewer_id");
    this.pushEventTo(this.el, "viewer_pref:loaded", { viewer_id: stored ?? "" });
    this.handleEvent("viewer_pref:save", ({ viewer_id }) => {
      if (viewer_id) {
        window.localStorage.setItem("sous:viewer_id", viewer_id);
      } else {
        window.localStorage.removeItem("sous:viewer_id");
      }
    });
  },
};
```

- [ ] **Step 5: Register the hook in `assets/js/app.js`**

In `assets/js/app.js`, find the `Hooks` object (or the `let Hooks = { ... }` declaration). Add `ViewerPrefs` to it:

```javascript
import ViewerPrefs from "./hooks/viewer_prefs";
// ... existing imports ...

let Hooks = {
  // ... existing hooks ...
  ViewerPrefs,
};
```

(If the project organizes hooks differently, follow its existing pattern — the import + the key in the hooks map are the two anchors.)

- [ ] **Step 6: Drop the `:pending_b1_task13` skip tags**

In `test/slackex_web/live/sous_live/viewer_preference_seam_test.exs` and `test/slackex_web/live/sous_live/facet_drawer_test.exs`, remove the `@tag :pending_b1_task13` lines added in Tasks 10 and 12. The tests should now go green naturally.

- [ ] **Step 7: Run the lens + drawer + seam tests to verify green**

Run: `mix test test/slackex_web/live/sous_live/in_service_lens_test.exs test/slackex_web/live/sous_live/facet_drawer_test.exs test/slackex_web/live/sous_live/viewer_preference_seam_test.exs`
Expected: PASS — all three files.

- [ ] **Step 8: Commit**

```bash
git add lib/slackex_web/live/sous_live/in_service.ex assets/js/hooks/viewer_prefs.js assets/js/app.js \
        test/slackex_web/live/sous_live/in_service_lens_test.exs \
        test/slackex_web/live/sous_live/facet_drawer_test.exs \
        test/slackex_web/live/sous_live/viewer_preference_seam_test.exs
git commit -m "feat(sous): wire B1 board — switcher, facet map, reshape, hidden toggle, drawer"
```

---

## Task 14: Mandatory cross-context integration test (triage → board reshape via PubSub)

Per CLAUDE.md: every cross-context + PubSub bridge needs an integration test that exercises the producer→consumer path end-to-end, not faking the upstream.

**Files:**
- Test (new): `test/slackex/sous/slice_b1_integration_test.exs`

- [ ] **Step 1: Write the test**

Create `test/slackex/sous/slice_b1_integration_test.exs`:

```elixir
defmodule Slackex.Sous.SliceB1IntegrationTest do
  @moduledoc """
  Triage → broadcast → board reshape, real PubSub, no faked upstream.

  Two boards subscribed; one calls Sous.set_attention/4; the other receives
  the broadcast and reshapes.
  """

  use SlackexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Slackex.Sous

  setup %{conn: conn} do
    FunWithFlags.enable(:sous)
    on_exit(fn -> FunWithFlags.enable(:sous) end)

    user = insert(:user, username: "alice")
    {:ok, channel} = Slackex.Chat.create_channel(user.id, %{name: "deploys"})

    {:ok, wi} =
      Sous.open_decision(%{channel_id: channel.id, actor_id: user.id, actor_username: user.username, title: "Bridge", what: "w", stakeholders: []})

    %{conn: log_in_user(conn, user), user: user, wi: wi}
  end

  test "triage propagates: a second connected board reshapes when an :attention_set broadcast lands", %{conn: conn, user: u, wi: wi} do
    {:ok, board, _} = live(conn, ~p"/in-service")
    render_click(board, "select_viewer", %{"id" => "cto"})
    assert render(board) =~ "Bridge"

    # Producer: a different process calls set_attention/4. The board (subscribed
    # to "sous:work_items") must receive the :attention_set broadcast, re-pull
    # facets_for_viewer("cto"), and reshape — "Bridge" becomes :hidden.
    {:ok, _} = Sous.set_attention(wi.id, "cto", :hidden, u.id)

    assert render(board) =~ "+1 not at your altitude"
    refute render(board) =~ "Bridge"
  end
end
```

- [ ] **Step 2: Run**

Run: `mix test test/slackex/sous/slice_b1_integration_test.exs`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add test/slackex/sous/slice_b1_integration_test.exs
git commit -m "test(sous): mandatory B1 integration — triage→broadcast→board reshape"
```

---

## Task 15: RESUME update + final gates

**Files:**
- Modify: `RESUME.md`

- [ ] **Step 1: Update RESUME**

In `RESUME.md`, update the latest-work header line to mention B1, e.g.:

```markdown
_Last updated: 2026-05-28 (Europe/London). Latest work: **Sous Slice B1 built on master** — role-lens viewer model, per-(viewer, work_item) attention triage, Facet Drawer. No AI (B2). Behind `:sous` flag (off in prod). See the Sous section below._
```

And add a brief "B1 built" note to the Sous section listing the new schemas + invariants #8–#11.

- [ ] **Step 2: Run the now-aligned full pre-deploy locally**

Run: `./scripts/pre-deploy`
Expected: all 12 steps pass.

- [ ] **Step 3: Commit RESUME + final**

```bash
git add RESUME.md
git commit -m "docs(resume): Sous Slice B1 built (role-lens + Facet Drawer; behind :sous)"
```

(No tag in this plan. Decide at execution time whether B1 ships as its own version tag or batches with B2.)

---

## Definition of Done

- [ ] All tests pass: `mix test` clean; `mix test --only contract` and `mix test --only e2e` clean.
- [ ] The aligned `scripts/pre-deploy` passes all 12 steps.
- [ ] The new B1 invariants are enforced by tests:
  - #8 lazy default — `in_service_lens_test.exs` (default `:watch`).
  - #9 ignore Slice-A facet keys — `projection_test.exs` (the legacy-`:created` test).
  - #10 ViewerPreference seam — `viewer_preference_seam_test.exs` swaps to `InMemoryStore`.
  - #11 viewers immutable — documented; no schema gives a delete/rename path in B1.
- [ ] `/decide` + chat decision cards + the In Service board (Slice A surfaces) still work unchanged with the null default lens (the board renders identically to Slice A when no viewer is picked).
- [ ] No changes to `lib/slackex/chat/message.ex`, `lib/slackex/messaging/channel_server.ex`, `lib/slackex/pipeline/batch_writer.ex` (ADR-002 preserved).
