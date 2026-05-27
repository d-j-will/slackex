# Sous Slice A — Event-Stream Tracer Bullet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the Sous spine end-to-end — a `/decide` chat command creates an append-only work-item event stream that projects into an "In Service" board, all behind a `:sous` flag.

**Architecture:** A new greenfield `Slackex.Sous` context owns three tables (`work_items`, `decisions`, `work_item_events`) and a pure `Projection` reducer. Every mutation goes through one of two command functions that write a `WorkItemEvent` and apply the projection in the **same `Ecto.Multi`** (single-write-path + complete-log invariants). The decision card is posted to chat via the **existing** `Messaging` facade (write-behind cache); the linkage lives on `WorkItem.card_message_id`, set by a `:card_posted` event (ADR-002 — no changes to the message hot path).

**Tech Stack:** Elixir / Phoenix LiveView, Ecto + PostgreSQL, Snowflake IDs (`Slackex.Infrastructure.Snowflake`), Phoenix.PubSub, FunWithFlags, ExUnit + ExMachina (`Slackex.TestFactory`).

**Source of truth:** spec `docs/feature/sous/design/slice-a-event-stream-tracer-bullet.md`, ADR-001 (plaintext decision fields), ADR-002 (chat linkage). Visual reference for the board: `docs/feature/sous/handoff/README.md` §8 + `handoff/design/src/in-service.jsx`.

**Conventions to honor (from CLAUDE.md / memory):**
- Never use `unless`; use `if` with an inverted condition.
- Snowflake PK schemas use `@primary_key {:id, :integer, autogenerate: false}` and derive `inserted_at` from the id.
- Gate ALL surfaces behind `:sous` from the start.
- Modals implement three dismiss mechanisms (backdrop, Escape, X button).
- New migrations are deploy-safe (new tables only here — no NOT NULL backfills, no renames).
- Commit after every green step.

---

## File Structure

**Create:**
- `priv/repo/migrations/<ts>_create_sous_tables.exs` — the three Sous tables.
- `lib/slackex/sous/work_item.ex` — `WorkItem` schema + changeset.
- `lib/slackex/sous/decision.ex` — `Decision` schema + changeset.
- `lib/slackex/sous/work_item_event.ex` — `WorkItemEvent` schema + changeset.
- `lib/slackex/sous/projection.ex` — pure reducer `apply/2` + `fold/1`.
- `lib/slackex/sous.ex` — context: `open_decision/1`, `move/3`, queries, broadcasts.
- `lib/slackex_web/live/chat_live/decide_modal_component.ex` — `/decide` modal LiveComponent.
- `lib/slackex_web/live/sous_live/in_service.ex` — board LiveView.
- `test/slackex/sous/projection_test.exs`, `test/slackex/sous_test.exs`,
  `test/slackex_web/live/chat_live/decide_test.exs`,
  `test/slackex_web/live/sous_live/in_service_test.exs`,
  `test/slackex/sous/slice_a_integration_test.exs`.

**Modify:**
- `lib/slackex_web/live/chat_live/slash_command.ex` — add `/decide` clause.
- `lib/slackex_web/live/chat_live/index.ex` (+ `index.html.heex`) — open modal, load card map, subscribe, handle_info.
- `lib/slackex_web/components/chat_components.ex` — decision-card render branch.
- `lib/slackex_web/router.ex` — board route in the `:chat` live_session.
- `test/test_helper.exs` — enable `:sous`.

**Do NOT modify** (ADR-002): `lib/slackex/chat/message.ex`, `lib/slackex/messaging/channel_server.ex`, `lib/slackex/pipeline/batch_writer.ex`.

---

## Task 1: Migration — create the three Sous tables

**Files:**
- Create: `priv/repo/migrations/<timestamp>_create_sous_tables.exs`

- [ ] **Step 1: Generate the migration file**

Run: `mix ecto.gen.migration create_sous_tables`
Expected: creates `priv/repo/migrations/<timestamp>_create_sous_tables.exs` with an empty `change/0`.

- [ ] **Step 2: Write the migration body**

Replace the generated file contents with:

```elixir
defmodule Slackex.Repo.Migrations.CreateSousTables do
  use Ecto.Migration

  def change do
    create table(:work_items, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :kind, :string, null: false
      add :state, :string, null: false
      add :title, :text, null: false
      add :facet_text, :text
      add :attention, :string, null: false, default: "watch"
      add :people, :map, null: false, default: %{}
      add :channel_id, references(:channels, on_delete: :delete_all)
      add :thread_root_message_id, :bigint
      # No FK on card_message_id: messages are written async via the cache,
      # so a hard constraint could race the batch writer (ADR-002).
      add :card_message_id, :bigint
      add :moved_at, :utc_datetime_usec, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:work_items, [:state])
    create index(:work_items, [:channel_id])
    create index(:work_items, [:card_message_id])

    create table(:decisions, primary_key: false) do
      add :work_item_id,
          references(:work_items, on_delete: :delete_all, type: :bigint),
          primary_key: true

      add :what, :text, null: false
      add :why, :text
      add :next, :text
    end

    create table(:work_item_events, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :work_item_id, references(:work_items, on_delete: :delete_all, type: :bigint), null: false
      add :type, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :actor_user_id, references(:users, on_delete: :nilify_all)
      add :inserted_at, :utc_datetime_usec, null: false
    end

    # Ordered replay of a work item's log.
    create index(:work_item_events, [:work_item_id, :id])
  end
end
```

- [ ] **Step 3: Run the migration**

Run: `docker compose up -d postgres postgres_test && mix ecto.migrate`
Expected: `* running ... create table work_items` etc., no errors.

- [ ] **Step 4: Commit**

```bash
git add priv/repo/migrations
git commit -m "feat(sous): create work_items, decisions, work_item_events tables"
```

---

## Task 2: `WorkItem` schema + changeset

**Files:**
- Create: `lib/slackex/sous/work_item.ex`
- Test: `test/slackex/sous/work_item_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/slackex/sous/work_item_test.exs`:

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
        attention: :watch,
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
Expected: FAIL — `Slackex.Sous.WorkItem.__struct__/0 is undefined`.

- [ ] **Step 3: Write the schema**

Create `lib/slackex/sous/work_item.ex`:

```elixir
defmodule Slackex.Sous.WorkItem do
  @moduledoc """
  The work-item projection (authoritative read model). Maintained inline by
  `Slackex.Sous` commands via `Slackex.Sous.Projection`; every field is
  reconstructable from the `work_item_events` log (spec §6, invariant #6).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Slackex.Infrastructure.Snowflake

  @primary_key {:id, :integer, autogenerate: false}

  @states [:order, :mise, :pass, :walked]
  @attentions [:act, :watch, :know, :hidden]
  @kinds [:decision]

  schema "work_items" do
    field :kind, Ecto.Enum, values: @kinds
    field :state, Ecto.Enum, values: @states
    field :title, :string
    field :facet_text, :string
    field :attention, Ecto.Enum, values: @attentions, default: :watch
    field :people, :map, default: %{}
    field :channel_id, :integer
    field :thread_root_message_id, :integer
    field :card_message_id, :integer
    field :moved_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec

    has_one :decision, Slackex.Sous.Decision, foreign_key: :work_item_id, references: :id
    has_many :events, Slackex.Sous.WorkItemEvent, foreign_key: :work_item_id, references: :id
  end

  def states, do: @states
  def attentions, do: @attentions
  def kinds, do: @kinds

  def changeset(work_item, attrs) do
    work_item
    |> cast(attrs, [
      :id,
      :kind,
      :state,
      :title,
      :facet_text,
      :attention,
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
git commit -m "feat(sous): WorkItem schema with Snowflake-derived inserted_at"
```

---

## Task 3: `Decision` schema + changeset

**Files:**
- Create: `lib/slackex/sous/decision.ex`
- Test: `test/slackex/sous/decision_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/slackex/sous/decision_test.exs`:

```elixir
defmodule Slackex.Sous.DecisionTest do
  use Slackex.DataCase, async: true

  alias Slackex.Sous.Decision

  test "requires work_item_id and what; why/next optional" do
    cs = Decision.changeset(%Decision{}, %{work_item_id: 1, what: "Use ES"})
    assert cs.valid?

    cs2 = Decision.changeset(%Decision{}, %{work_item_id: 1})
    refute cs2.valid?
    assert errors_on(cs2)[:what]
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/slackex/sous/decision_test.exs`
Expected: FAIL — `Slackex.Sous.Decision.__struct__/0 is undefined`.

- [ ] **Step 3: Write the schema**

Create `lib/slackex/sous/decision.ex`:

```elixir
defmodule Slackex.Sous.Decision do
  @moduledoc """
  Kind-specific detail for a `:decision` work item (1:1). Plaintext fields by
  deliberate Slice A choice — see ADR-001.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  schema "decisions" do
    field :work_item_id, :integer, primary_key: true
    field :what, :string
    field :why, :string
    field :next, :string
  end

  def changeset(decision, attrs) do
    decision
    |> cast(attrs, [:work_item_id, :what, :why, :next])
    |> validate_required([:work_item_id, :what])
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/slackex/sous/decision_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/slackex/sous/decision.ex test/slackex/sous/decision_test.exs
git commit -m "feat(sous): Decision schema (plaintext fields, ADR-001)"
```

---

## Task 4: `WorkItemEvent` schema + changeset

**Files:**
- Create: `lib/slackex/sous/work_item_event.ex`
- Test: `test/slackex/sous/work_item_event_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/slackex/sous/work_item_event_test.exs`:

```elixir
defmodule Slackex.Sous.WorkItemEventTest do
  use Slackex.DataCase, async: true

  alias Slackex.Sous.WorkItemEvent
  alias Slackex.Infrastructure.Snowflake

  test "valid event derives inserted_at from id and accepts known types" do
    id = Snowflake.generate()

    cs =
      WorkItemEvent.changeset(%WorkItemEvent{}, %{
        id: id,
        work_item_id: 123,
        type: :created,
        payload: %{"title" => "x"},
        actor_user_id: 1
      })

    assert cs.valid?
    assert get_change(cs, :inserted_at)
  end

  test "rejects unknown event type" do
    cs = WorkItemEvent.changeset(%WorkItemEvent{}, %{id: 1, work_item_id: 1, type: :bogus})
    refute cs.valid?
    assert errors_on(cs)[:type]
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/slackex/sous/work_item_event_test.exs`
Expected: FAIL — undefined struct.

- [ ] **Step 3: Write the schema**

Create `lib/slackex/sous/work_item_event.ex`:

```elixir
defmodule Slackex.Sous.WorkItemEvent do
  @moduledoc """
  Append-only event log — the replay source of truth for a work item.
  Events are never updated or deleted (invariant #5). Payloads are
  self-describing (invariant #3) with string keys so the inline projection
  and a future replay-from-jsonb projection agree.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Slackex.Infrastructure.Snowflake

  @primary_key {:id, :integer, autogenerate: false}

  @types [:created, :state_changed, :card_posted]

  schema "work_item_events" do
    field :work_item_id, :integer
    field :type, Ecto.Enum, values: @types
    field :payload, :map, default: %{}
    field :actor_user_id, :integer
    field :inserted_at, :utc_datetime_usec
  end

  def types, do: @types

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:id, :work_item_id, :type, :payload, :actor_user_id])
    |> validate_required([:id, :work_item_id, :type])
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

Run: `mix test test/slackex/sous/work_item_event_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/slackex/sous/work_item_event.ex test/slackex/sous/work_item_event_test.exs
git commit -m "feat(sous): WorkItemEvent append-only log schema"
```

---

## Task 5: `Projection` pure reducer (the event-sourcing-readiness core)

This is the single function both the inline commands and a future replay projector use
(invariant #4). It folds events (with **string-keyed** payloads) into a projected state map.

**Files:**
- Create: `lib/slackex/sous/projection.ex`
- Test: `test/slackex/sous/projection_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/slackex/sous/projection_test.exs`:

```elixir
defmodule Slackex.Sous.ProjectionTest do
  use ExUnit.Case, async: true

  alias Slackex.Sous.{Projection, WorkItemEvent}

  defp ev(id, type, payload), do: %WorkItemEvent{id: id, work_item_id: 10, type: type, payload: payload}

  test "fold :created builds the work item and decision attrs" do
    created =
      ev(1, :created, %{
        "kind" => "decision",
        "title" => "Adopt ES",
        "state" => "mise",
        "facet_text" => "Adopt ES",
        "attention" => "watch",
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
    assert state.work_item.attention == :watch
    assert state.work_item.channel_id == 100
    assert state.work_item.card_message_id == nil
    assert state.decision.what == "Use event sourcing"
  end

  test "fold :state_changed updates state and moved_at" do
    events = [
      ev(1, :created, %{"kind" => "decision", "title" => "x", "state" => "mise", "what" => "w", "moved_at" => "2026-05-27T10:00:00.000000Z"}),
      ev(2, :state_changed, %{"from" => "mise", "to" => "pass", "moved_at" => "2026-05-27T11:00:00.000000Z"})
    ]

    state = Projection.fold(events)
    assert state.work_item.state == :pass
    assert state.work_item.moved_at == ~U[2026-05-27 11:00:00.000000Z]
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

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/slackex/sous/projection_test.exs`
Expected: FAIL — `Slackex.Sous.Projection.fold/1 is undefined`.

- [ ] **Step 3: Write the reducer**

Create `lib/slackex/sous/projection.ex`:

```elixir
defmodule Slackex.Sous.Projection do
  @moduledoc """
  Pure fold from a work item's event log to its projected state.

  Used INLINE by `Slackex.Sous` commands to compute the row to persist, and
  reusable by a future event-replay projector — the same function, satisfying
  invariant #4. Payloads use string keys (jsonb round-trips as strings), so the
  inline path and a replay-from-DB path produce identical results.

  Returns `%{work_item: map | nil, decision: map | nil}` where the inner maps are
  attribute maps suitable for `WorkItem.changeset/2` / `Decision.changeset/2`.
  """

  alias Slackex.Sous.WorkItemEvent

  @type state :: %{work_item: map() | nil, decision: map() | nil}

  @spec initial() :: state()
  def initial, do: %{work_item: nil, decision: nil}

  @spec fold([WorkItemEvent.t()]) :: state()
  def fold(events) when is_list(events) do
    Enum.reduce(events, initial(), &apply_event(&2, &1))
  end

  @spec apply_event(state(), WorkItemEvent.t()) :: state()
  def apply_event(_state, %WorkItemEvent{type: :created, work_item_id: wid, payload: p}) do
    %{
      work_item: %{
        id: wid,
        kind: to_atom(get(p, "kind")),
        state: to_atom(get(p, "state")),
        title: get(p, "title"),
        facet_text: get(p, "facet_text"),
        attention: to_atom(get(p, "attention") || "watch"),
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
      }
    }
  end

  def apply_event(%{work_item: wi} = state, %WorkItemEvent{type: :state_changed, payload: p}) do
    %{state | work_item: %{wi | state: to_atom(get(p, "to")), moved_at: to_dt(get(p, "moved_at"))}}
  end

  def apply_event(%{work_item: wi} = state, %WorkItemEvent{type: :card_posted, payload: p}) do
    %{state | work_item: %{wi | card_message_id: get(p, "card_message_id")}}
  end

  defp get(map, key), do: Map.get(map, key)

  defp to_atom(nil), do: nil
  defp to_atom(v) when is_atom(v), do: v
  defp to_atom(v) when is_binary(v), do: String.to_existing_atom(v)

  defp to_dt(nil), do: nil
  defp to_dt(%DateTime{} = dt), do: dt

  defp to_dt(v) when is_binary(v) do
    {:ok, dt, _} = DateTime.from_iso8601(v)
    dt
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/slackex/sous/projection_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/slackex/sous/projection.ex test/slackex/sous/projection_test.exs
git commit -m "feat(sous): pure Projection reducer (inline + replay, invariant #4)"
```

---

## Task 6: Enable the `:sous` feature flag in tests

**Files:**
- Modify: `test/test_helper.exs`

- [ ] **Step 1: Add `:sous` to the flag-enable loop**

In `test/test_helper.exs`, change the flag list:

```elixir
for flag <- [
      :message_search,
      :channel_summarization,
      :sous
    ] do
  FunWithFlags.enable(flag)
end
```

- [ ] **Step 2: Verify the suite still boots**

Run: `mix test test/slackex/sous/projection_test.exs`
Expected: PASS (flag enable runs at boot without error).

- [ ] **Step 3: Commit**

```bash
git add test/test_helper.exs
git commit -m "test(sous): enable :sous flag in the test suite"
```

---

## Task 7: `Slackex.Sous` context — `open_decision/1` (event-stream core)

The command builds a `:created` event with a **string-keyed snapshot payload**, runs the event +
`WorkItem` + `Decision` inserts in one `Ecto.Multi` (invariants #1, #2), then broadcasts. The card
post is a **separate** later step (Task 8).

**Files:**
- Create: `lib/slackex/sous.ex`
- Test: `test/slackex/sous_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/slackex/sous_test.exs`:

```elixir
defmodule Slackex.SousTest do
  use Slackex.DataCase, async: true

  alias Slackex.Sous
  alias Slackex.Sous.{WorkItem, WorkItemEvent, Projection}
  alias Slackex.Repo

  import Ecto.Query

  setup do
    user = insert(:user)
    {:ok, channel} = Slackex.Chat.create_channel(user.id, %{name: "deploys"})
    %{user: user, channel: channel}
  end

  describe "open_decision/1" do
    test "creates a :mise decision with a :created event and a Decision", %{user: u, channel: c} do
      assert {:ok, wi} =
               Sous.open_decision(%{
                 channel_id: c.id,
                 thread_root_message_id: nil,
                 actor_id: u.id,
                 title: "Adopt event sourcing",
                 what: "Use an append-only log",
                 why: "Auditability",
                 next: "Spike the reducer",
                 stakeholders: [u.id]
               })

      assert wi.kind == :decision
      assert wi.state == :mise
      assert wi.attention == :watch
      assert wi.facet_text == "Adopt event sourcing"
      assert wi.channel_id == c.id

      events = Repo.all(from e in WorkItemEvent, where: e.work_item_id == ^wi.id, order_by: e.id)
      assert [%{type: :created}] = events

      decision = Repo.get_by!(Slackex.Sous.Decision, work_item_id: wi.id)
      assert decision.what == "Use an append-only log"
    end

    test "the persisted row equals folding its event log (replay guard, invariant #7)", %{user: u, channel: c} do
      {:ok, wi} =
        Sous.open_decision(%{
          channel_id: c.id,
          actor_id: u.id,
          title: "Replayable",
          what: "w",
          stakeholders: []
        })

      events = Repo.all(from e in WorkItemEvent, where: e.work_item_id == ^wi.id, order_by: e.id)
      folded = Projection.fold(events).work_item

      assert folded.state == wi.state
      assert folded.title == wi.title
      assert folded.kind == wi.kind
      assert folded.attention == wi.attention
    end

    test "rolls back entirely when the decision is invalid", %{user: u, channel: c} do
      assert {:error, _step, _changeset, _} =
               Sous.open_decision(%{
                 channel_id: c.id,
                 actor_id: u.id,
                 title: "No what field",
                 what: nil,
                 stakeholders: []
               })

      assert Repo.aggregate(WorkItem, :count) == 0
      assert Repo.aggregate(WorkItemEvent, :count) == 0
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/slackex/sous_test.exs`
Expected: FAIL — `Slackex.Sous.open_decision/1 is undefined`.

- [ ] **Step 3: Write the context with `open_decision/1`**

Create `lib/slackex/sous.ex`:

```elixir
defmodule Slackex.Sous do
  @moduledoc """
  The Sous work-item event stream (Slice A).

  All mutations flow through this module's command functions (single write
  path, invariant #1). Each writes a `WorkItemEvent` and applies the projection
  via `Slackex.Sous.Projection` in the SAME transaction (invariant #2). Event
  payloads are self-describing with string keys (invariant #3) so the inline
  projection here and a future replay projection agree.

  Topics:
    * "sous:work_items"            — workspace-wide; the In Service board.
    * "sous:cards:channel:\#{id}"  — channel-scoped; chat decision-card upgrade.
  """

  alias Ecto.Multi
  alias Slackex.Infrastructure.Snowflake
  alias Slackex.Repo
  alias Slackex.Sous.{Decision, Projection, WorkItem, WorkItemEvent}

  @pubsub Slackex.PubSub
  @work_items_topic "sous:work_items"

  @doc "Workspace-wide board topic."
  def work_items_topic, do: @work_items_topic

  @doc "Channel-scoped decision-card upgrade topic."
  def cards_topic(channel_id), do: "sous:cards:channel:#{channel_id}"

  @doc """
  Creates a `:decision` work item in state `:mise` from a chat context.

  Required attrs: `:channel_id`, `:actor_id`, `:title`, `:what`.
  Optional: `:why`, `:next`, `:thread_root_message_id`, `:stakeholders` (list of user ids).
  """
  def open_decision(attrs) do
    id = Snowflake.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    lead = attrs[:actor_id]
    stakeholders = attrs[:stakeholders] || []

    payload = %{
      "kind" => "decision",
      "title" => attrs[:title],
      "state" => "mise",
      "facet_text" => attrs[:title],
      "attention" => "watch",
      "people" => %{"lead" => lead, "supporting" => [], "watching" => [], "stakeholders" => stakeholders},
      "what" => attrs[:what],
      "why" => attrs[:why],
      "next" => attrs[:next],
      "channel_id" => attrs[:channel_id],
      "thread_root_message_id" => attrs[:thread_root_message_id],
      "moved_at" => DateTime.to_iso8601(now)
    }

    event = %WorkItemEvent{id: Snowflake.generate(), work_item_id: id, type: :created, payload: payload, actor_user_id: lead}
    projected = Projection.apply_event(Projection.initial(), event)

    Multi.new()
    |> Multi.insert(:event, WorkItemEvent.changeset(%WorkItemEvent{}, Map.from_struct(event)))
    |> Multi.insert(:work_item, WorkItem.changeset(%WorkItem{}, Map.put(projected.work_item, :id, id)))
    |> Multi.insert(:decision, Decision.changeset(%Decision{}, projected.decision))
    |> Repo.transaction()
    |> case do
      {:ok, %{work_item: work_item}} ->
        broadcast_work_item(:created, work_item)
        {:ok, work_item}

      {:error, step, changeset, _changes} ->
        {:error, step, changeset, %{}}
    end
  end

  defp broadcast_work_item(event_type, work_item) do
    Phoenix.PubSub.broadcast(@pubsub, @work_items_topic, {:work_item_event, event_type, work_item})
  end
end
```

> Note: `projected.work_item` already contains `id: id`; `Map.put(..., :id, id)` is belt-and-braces
> so the changeset always has the PK even if `apply_event` evolves.

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/slackex/sous_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/slackex/sous.ex test/slackex/sous_test.exs
git commit -m "feat(sous): Sous.open_decision/1 — atomic event + projection + decision"
```

---

## Task 8: `Sous.post_decision_card/2` — post the card + `:card_posted` event

Posts the card via the **existing** `Messaging.send_message/4` facade (write-behind path), then
records the linkage as a `:card_posted` event that updates `card_message_id`. Separate from
`open_decision/1` per ADR-002 (the card post is not in the event-stream Multi).

**Files:**
- Modify: `lib/slackex/sous.ex`
- Test: `test/slackex/sous_card_test.exs` (NEW, `async: false` — posting goes through the
  `ChannelServer` GenServer, which needs a shared sandbox; keeping it out of the `async: true`
  `sous_test.exs` preserves isolation for the rest of the suite).

- [ ] **Step 1: Write the failing test**

Create `test/slackex/sous_card_test.exs` as a standalone **`async: false`** module:

```elixir
defmodule Slackex.SousCardTest do
  @moduledoc "ChannelServer-dependent Sous tests — shared sandbox, not async."
  use Slackex.DataCase, async: false

  import Ecto.Query

  alias Slackex.Sous
  alias Slackex.Sous.{WorkItem, WorkItemEvent}
  alias Slackex.Repo

  setup do
    # ChannelServer runs in its own process; share the sandbox connection with it.
    Ecto.Adapters.SQL.Sandbox.mode(Slackex.Repo, {:shared, self()})
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Slackex.Repo, :manual) end)

    user = insert(:user)
    {:ok, channel} = Slackex.Chat.create_channel(user.id, %{name: "deploys"})
    {:ok, wi} = Sous.open_decision(%{channel_id: channel.id, actor_id: user.id, title: "Card me", what: "w", stakeholders: []})
    %{user: user, channel: channel, wi: wi}
  end

  test "posts a chat message and records card_message_id via a :card_posted event", %{wi: wi, user: u} do
    Phoenix.PubSub.subscribe(Slackex.PubSub, Sous.cards_topic(wi.channel_id))

    assert {:ok, updated} = Sous.post_decision_card(wi, u.id)
    assert updated.card_message_id

    assert_receive {:decision_card, msg_id, %WorkItem{} = card_wi}, 2000
    assert card_wi.id == wi.id
    assert msg_id == updated.card_message_id

    events = Repo.all(from e in WorkItemEvent, where: e.work_item_id == ^wi.id, order_by: e.id)
    assert Enum.map(events, & &1.type) == [:created, :card_posted]
  end

  test "card_messages_for_channel/1 maps card_message_id => work_item", %{wi: wi, user: u, channel: c} do
    {:ok, carded} = Sous.post_decision_card(wi, u.id)

    map = Sous.card_messages_for_channel(c.id)
    assert Map.has_key?(map, carded.card_message_id)
    assert map[carded.card_message_id].id == wi.id
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/slackex/sous_card_test.exs`
Expected: FAIL — `Slackex.Sous.post_decision_card/2 is undefined`.

- [ ] **Step 3: Implement `post_decision_card/2` + the card broadcast**

In `lib/slackex/sous.ex`, add the alias and function. Add `alias Slackex.Messaging` to the aliases,
and add:

```elixir
  @doc """
  Posts the decision card to the work item's channel via the existing messaging
  facade, then records the linkage as a `:card_posted` event (ADR-002).

  Returns `{:ok, work_item}` with `card_message_id` set, or `{:error, reason}`.
  On failure the work item is left intact (no card); the caller logs it.
  """
  def post_decision_card(%WorkItem{} = wi, actor_id) do
    with {:ok, msg} <- Messaging.send_message(wi.channel_id, actor_id, card_fallback_text(wi)) do
      event = %WorkItemEvent{
        id: Snowflake.generate(),
        work_item_id: wi.id,
        type: :card_posted,
        payload: %{"card_message_id" => msg.id},
        actor_user_id: actor_id
      }

      projected = Projection.apply_event(%{work_item: wi_to_attrs(wi), decision: nil}, event)

      Multi.new()
      |> Multi.insert(:event, WorkItemEvent.changeset(%WorkItemEvent{}, Map.from_struct(event)))
      |> Multi.update(:work_item, WorkItem.changeset(wi, %{card_message_id: projected.work_item.card_message_id}))
      |> Repo.transaction()
      |> case do
        {:ok, %{work_item: updated}} ->
          broadcast_work_item(:card_posted, updated)
          Phoenix.PubSub.broadcast(@pubsub, cards_topic(wi.channel_id), {:decision_card, msg.id, updated})
          {:ok, updated}

        {:error, _step, changeset, _} ->
          {:error, changeset}
      end
    end
  end

  defp card_fallback_text(%WorkItem{title: title}), do: "Decision: #{title}"

  defp wi_to_attrs(%WorkItem{} = wi) do
    %{
      id: wi.id,
      kind: wi.kind,
      state: wi.state,
      title: wi.title,
      facet_text: wi.facet_text,
      attention: wi.attention,
      people: wi.people,
      channel_id: wi.channel_id,
      thread_root_message_id: wi.thread_root_message_id,
      card_message_id: wi.card_message_id,
      moved_at: wi.moved_at
    }
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/slackex/sous_card_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/slackex/sous.ex test/slackex/sous_card_test.exs
git commit -m "feat(sous): post_decision_card/2 via facade + :card_posted event (ADR-002)"
```

---

## Task 9: `Sous.move/3` — state transitions

**Files:**
- Modify: `lib/slackex/sous.ex`
- Test: `test/slackex/sous_test.exs`

- [ ] **Step 1: Write the failing test**

Add to the first (`async: true`) describe section of `test/slackex/sous_test.exs`:

```elixir
  describe "move/3" do
    setup %{user: u, channel: c} do
      {:ok, wi} = Sous.open_decision(%{channel_id: c.id, actor_id: u.id, title: "Movable", what: "w", stakeholders: []})
      %{wi: wi}
    end

    test "moves to a new state and appends a :state_changed event", %{wi: wi, user: u} do
      Phoenix.PubSub.subscribe(Slackex.PubSub, Sous.work_items_topic())

      assert {:ok, moved} = Sous.move(wi.id, :pass, u.id)
      assert moved.state == :pass
      assert DateTime.compare(moved.moved_at, wi.moved_at) in [:gt, :eq]

      assert_receive {:work_item_event, :state_changed, %WorkItem{state: :pass}}

      events = Repo.all(from e in WorkItemEvent, where: e.work_item_id == ^wi.id, order_by: e.id)
      assert Enum.map(events, & &1.type) == [:created, :state_changed]
    end

    test "rejects an unknown target state", %{wi: wi, user: u} do
      assert {:error, :invalid_state} = Sous.move(wi.id, :bogus, u.id)
    end

    test "rejects a no-op move to the same state", %{wi: wi, user: u} do
      assert {:error, :no_op} = Sous.move(wi.id, :mise, u.id)
    end
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/slackex/sous_test.exs -k "move/3"` (or run the file)
Expected: FAIL — `Sous.move/3 is undefined`.

- [ ] **Step 3: Implement `move/3` and a query helper**

In `lib/slackex/sous.ex`, add:

```elixir
  @doc """
  Moves a work item to `to_state` (one of `WorkItem.states/0`), appending a
  `:state_changed` event. Returns `{:ok, work_item}` or `{:error, reason}`.
  """
  def move(work_item_id, to_state, actor_id) do
    cond do
      to_state not in WorkItem.states() ->
        {:error, :invalid_state}

      true ->
        wi = Repo.get!(WorkItem, work_item_id)

        if wi.state == to_state do
          {:error, :no_op}
        else
          do_move(wi, to_state, actor_id)
        end
    end
  end

  defp do_move(%WorkItem{} = wi, to_state, actor_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    event = %WorkItemEvent{
      id: Snowflake.generate(),
      work_item_id: wi.id,
      type: :state_changed,
      payload: %{"from" => Atom.to_string(wi.state), "to" => Atom.to_string(to_state), "moved_at" => DateTime.to_iso8601(now)},
      actor_user_id: actor_id
    }

    projected = Projection.apply_event(%{work_item: wi_to_attrs(wi), decision: nil}, event)

    Multi.new()
    |> Multi.insert(:event, WorkItemEvent.changeset(%WorkItemEvent{}, Map.from_struct(event)))
    |> Multi.update(:work_item, WorkItem.changeset(wi, %{state: projected.work_item.state, moved_at: projected.work_item.moved_at}))
    |> Repo.transaction()
    |> case do
      {:ok, %{work_item: updated}} ->
        broadcast_work_item(:state_changed, updated)
        {:ok, updated}

      {:error, _step, changeset, _} ->
        {:error, changeset}
    end
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/slackex/sous_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/slackex/sous.ex test/slackex/sous_test.exs
git commit -m "feat(sous): Sous.move/3 — validated state transitions as events"
```

---

## Task 10: `Sous` queries — board listing + channel card map

**Files:**
- Modify: `lib/slackex/sous.ex`
- Test: `test/slackex/sous_test.exs`

- [ ] **Step 1: Write the failing test**

Add to the `async: true` section:

```elixir
  describe "queries" do
    test "list_in_flight/0 groups work items by state", %{user: u, channel: c} do
      {:ok, a} = Sous.open_decision(%{channel_id: c.id, actor_id: u.id, title: "A", what: "w", stakeholders: []})
      {:ok, b} = Sous.open_decision(%{channel_id: c.id, actor_id: u.id, title: "B", what: "w", stakeholders: []})
      {:ok, _} = Sous.move(b.id, :pass, u.id)

      grouped = Sous.list_in_flight()
      assert Enum.map(grouped[:mise], & &1.id) == [a.id]
      assert Enum.map(grouped[:pass], & &1.id) == [b.id]
      assert grouped[:order] == []
      assert grouped[:walked] == []
    end
  end
```

> `card_messages_for_channel/1` is exercised in `test/slackex/sous_card_test.exs` (Task 8), since it
> requires a posted card (ChannelServer → shared sandbox). Keep `sous_test.exs` `async: true`.
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/slackex/sous_test.exs`
Expected: FAIL — `Sous.list_in_flight/0 is undefined`.

- [ ] **Step 3: Implement the queries**

In `lib/slackex/sous.ex`, add `import Ecto.Query` near the top (after the aliases) and:

```elixir
  @doc "All in-flight work items grouped by state. Every state key is present (possibly empty)."
  def list_in_flight do
    base = for s <- WorkItem.states(), into: %{}, do: {s, []}

    WorkItem
    |> order_by(asc: :inserted_at)
    |> preload(:decision)
    |> Repo.all()
    |> Enum.group_by(& &1.state)
    |> then(&Map.merge(base, &1))
  end

  @doc "Map of `card_message_id => work_item` (with decision preloaded) for a channel."
  def card_messages_for_channel(channel_id) do
    WorkItem
    |> where([w], w.channel_id == ^channel_id and not is_nil(w.card_message_id))
    |> preload(:decision)
    |> Repo.all()
    |> Map.new(fn wi -> {wi.card_message_id, wi} end)
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/slackex/sous_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/slackex/sous.ex test/slackex/sous_test.exs
git commit -m "feat(sous): board listing + channel card-message map queries"
```

---

## Task 11: `/decide` slash-command parsing

**Files:**
- Modify: `lib/slackex_web/live/chat_live/slash_command.ex`
- Test: `test/slackex_web/live/chat_live/slash_command_test.exs` (create if absent)

- [ ] **Step 1: Write the failing test**

Create or extend `test/slackex_web/live/chat_live/slash_command_test.exs`:

```elixir
defmodule SlackexWeb.ChatLive.SlashCommandTest do
  use ExUnit.Case, async: true

  alias SlackexWeb.ChatLive.SlashCommand

  test "/decide parses to {:decide}" do
    assert SlashCommand.parse("/decide") == {:decide}
    assert SlashCommand.parse("  /decide  ") == {:decide}
  end

  test "non-decide input is unaffected" do
    assert SlashCommand.parse("/summarize") == {:summarize, "24h"}
    assert SlashCommand.parse("hello") == :not_command
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/slackex_web/live/chat_live/slash_command_test.exs`
Expected: FAIL — `/decide` returns `{:unknown_command, "decide"}`, not `{:decide}`.

- [ ] **Step 3: Add the `/decide` clause**

In `lib/slackex_web/live/chat_live/slash_command.ex`:

- Extend the `@type result` union to include `{:decide}`:

```elixir
  @type result ::
          {:summarize, String.t()}
          | {:decide}
          | {:unknown_command, String.t()}
          | :not_command
```

- Add a clause to the `case` in `do_parse/1`, BEFORE the catch-all `[command | _]` clause:

```elixir
  defp do_parse("/" <> rest) do
    case String.split(rest, ~r/\s+/, parts: 2) do
      ["summarize"] -> {:summarize, "24h"}
      ["summarize", range] -> {:summarize, String.trim(range)}
      ["decide"] -> {:decide}
      ["decide", _rest] -> {:decide}
      [command | _] -> {:unknown_command, command}
      [] -> :not_command
    end
  end
```

- Update the moduledoc "Supported Commands" list to add `* /decide — capture a decision`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/slackex_web/live/chat_live/slash_command_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/slackex_web/live/chat_live/slash_command.ex test/slackex_web/live/chat_live/slash_command_test.exs
git commit -m "feat(sous): parse /decide slash command"
```

---

## Task 12: `/decide` modal LiveComponent + index wiring

The modal collects Title/What/Why/Next/Stakeholders, then on submit calls `Sous.open_decision/1`
followed by `Sous.post_decision_card/2`. It implements the three dismiss mechanisms.

**Files:**
- Create: `lib/slackex_web/live/chat_live/decide_modal_component.ex`
- Modify: `lib/slackex_web/live/chat_live/index.ex` (parse `{:decide}`, toggle modal),
  `lib/slackex_web/live/chat_live/index.html.heex` (render the component).
- Test: `test/slackex_web/live/chat_live/decide_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/slackex_web/live/chat_live/decide_test.exs`:

```elixir
defmodule SlackexWeb.ChatLive.DecideTest do
  use SlackexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Slackex.Sous

  setup %{conn: conn} do
    Ecto.Adapters.SQL.Sandbox.mode(Slackex.Repo, {:shared, self()})
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Slackex.Repo, :manual) end)

    alice = insert(:user, username: "alice")
    {:ok, channel} = Slackex.Chat.create_channel(alice.id, %{name: "deploys"})
    conn = log_in_user(conn, alice)
    %{conn: conn, alice: alice, channel: channel}
  end

  test "typing /decide opens the modal", %{conn: conn, channel: channel} do
    {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

    html =
      lv
      |> form("#message-form", %{message: %{content: "/decide"}})
      |> render_submit()

    assert html =~ "Capture a decision"
  end

  test "submitting the modal creates a work item and a decision card", %{conn: conn, channel: channel, alice: alice} do
    {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

    lv |> form("#message-form", %{message: %{content: "/decide"}}) |> render_submit()

    lv
    |> form("#decide-form", %{
      decision: %{title: "Adopt ES", what: "Use a log", why: "audit", next: "spike"}
    })
    |> render_submit()

    grouped = Sous.list_in_flight()
    assert Enum.any?(grouped[:mise], &(&1.title == "Adopt ES"))
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/slackex_web/live/chat_live/decide_test.exs`
Expected: FAIL — submitting `/decide` does not render "Capture a decision".

- [ ] **Step 3: Create the modal component**

Create `lib/slackex_web/live/chat_live/decide_modal_component.ex`:

```elixir
defmodule SlackexWeb.ChatLive.DecideModalComponent do
  @moduledoc """
  Modal for `/decide`: captures a decision (Title/What/Why/Next/Stakeholders)
  and creates a Sous work item + posts the decision card. Three dismiss
  mechanisms per project UI convention.
  """
  use SlackexWeb, :live_component

  alias Slackex.Sous
  require Logger

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:form, fn -> to_form(%{"title" => "", "what" => "", "why" => "", "next" => ""}, as: :decision) end)}
  end

  @impl true
  def handle_event("close_decide", _params, socket) do
    {:noreply, push_patch(socket, to: socket.assigns.return_to)}
  end

  def handle_event("save_decide", %{"decision" => params}, socket) do
    actor = socket.assigns.current_user
    channel = socket.assigns.channel

    attrs = %{
      channel_id: channel.id,
      thread_root_message_id: socket.assigns[:thread_root_message_id],
      actor_id: actor.id,
      title: params["title"],
      what: params["what"],
      why: params["why"],
      next: params["next"],
      stakeholders: socket.assigns[:stakeholder_ids] || []
    }

    case Sous.open_decision(attrs) do
      {:ok, work_item} ->
        case Sous.post_decision_card(work_item, actor.id) do
          {:ok, _} -> :ok
          {:error, reason} -> Logger.warning("Sous decision card post failed: #{inspect(reason)}")
        end

        {:noreply, push_patch(socket, to: socket.assigns.return_to)}

      {:error, _step, _changeset, _} ->
        {:noreply,
         socket
         |> assign(:form, to_form(params, as: :decision))
         |> assign(:error, "Title and What are required.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="decide-modal" phx-window-keydown="close_decide" phx-key="Escape" phx-target={@myself}>
      <div class="fixed inset-0 z-40 bg-black/50" phx-click="close_decide" phx-target={@myself} />
      <div class="fixed inset-0 z-50 flex items-start justify-center pt-20 px-4">
        <div class="loom bg-base-100 rounded-xl shadow-xl w-full sm:max-w-lg max-h-[80vh] flex flex-col">
          <div class="p-4 border-b border-base-300 flex items-center justify-between">
            <h3 class="loom-modal-title font-bold text-lg">Capture a decision</h3>
            <button type="button" phx-click="close_decide" phx-target={@myself} class="btn btn-ghost btn-sm btn-square" aria-label="Close">
              <span class="hero-x-mark size-5" />
            </button>
          </div>
          <.form for={@form} phx-submit="save_decide" phx-target={@myself} id="decide-form" class="p-4 space-y-3 overflow-y-auto">
            <p :if={assigns[:error]} class="text-error text-sm">{@error}</p>
            <.input field={@form[:title]} label="Title" required />
            <.input field={@form[:what]} type="textarea" label="What" required />
            <.input field={@form[:why]} type="textarea" label="Why" />
            <.input field={@form[:next]} type="textarea" label="Next" />
            <div class="flex justify-end gap-2 pt-2">
              <button type="button" phx-click="close_decide" phx-target={@myself} class="btn btn-ghost">Cancel</button>
              <button type="submit" class="btn btn-primary loom-send">Create decision</button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end
end
```

- [ ] **Step 4: Wire the modal into the chat LiveView**

In `lib/slackex_web/live/chat_live/index.ex`, find the `handle_event("send_message", ...)` clause
(around line 340) that calls `SlashCommand.parse/1`. Add handling for `{:decide}` BEFORE the normal
send path. The existing code branches on the parse result; add a `{:decide}` branch that opens the
modal by assigning a flag:

```elixir
      {:decide} ->
        {:noreply, assign(socket, :show_decide, true)}
```

Add `|> assign_new(:show_decide, fn -> false end)` in `mount/3` (near the other assigns around line
124). Add a `handle_event("close_decide", ...)` is handled by the component; the parent only needs
the toggle assign and a way to clear it. Add this parent handler so the component's `push_patch`
return lands cleanly:

```elixir
  # Clears the decide modal when the component patches back.
  def handle_event("close_decide", _params, socket) do
    {:noreply, assign(socket, :show_decide, false)}
  end
```

> Because the component uses `push_patch(to: @return_to)` we pass `return_to` as the current channel
> path and also reset `show_decide` on the next `handle_params`. Simplest: in `handle_params/3` add
> `|> assign(:show_decide, false)` so any navigation closes the modal.

In `lib/slackex_web/live/chat_live/index.html.heex`, near the other modal components (around line
322), add:

```heex
  <.live_component
    :if={@show_decide and @active_channel}
    module={SlackexWeb.ChatLive.DecideModalComponent}
    id="decide-modal"
    channel={@active_channel}
    current_user={@current_user}
    return_to={~p"/chat/#{@active_channel.slug}"}
  />
```

Ensure the alias `alias SlackexWeb.ChatLive.SlashCommand` already exists (it does, used at line 343).

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/slackex_web/live/chat_live/decide_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/slackex_web/live/chat_live/decide_modal_component.ex \
        lib/slackex_web/live/chat_live/index.ex \
        lib/slackex_web/live/chat_live/index.html.heex \
        test/slackex_web/live/chat_live/decide_test.exs
git commit -m "feat(sous): /decide modal creates a decision + posts the card"
```

---

## Task 13: Decision-card render in chat

The chat LiveView loads the channel's card map on mount and subscribes to the card topic; the
message component renders a styled card when a message id is in the map. On a live `:decision_card`
broadcast the message upgrades from plain to card (the two-step render, ADR-002).

**Files:**
- Modify: `lib/slackex_web/live/chat_live/index.ex` (load `card_messages`, subscribe, handle_info),
  `lib/slackex_web/components/chat_components.ex` (render branch).
- Test: `test/slackex_web/live/chat_live/decide_test.exs` (add a render assertion).

- [ ] **Step 1: Write the failing test**

Add to `test/slackex_web/live/chat_live/decide_test.exs`:

```elixir
  test "a posted decision renders as a card in the channel", %{conn: conn, channel: channel} do
    {:ok, lv, _html} = live(conn, ~p"/chat/#{channel.slug}")

    lv |> form("#message-form", %{message: %{content: "/decide"}}) |> render_submit()

    html =
      lv
      |> form("#decide-form", %{decision: %{title: "Visible Card", what: "the what", why: "", next: ""}})
      |> render_submit()

    # The card upgrade arrives via the "sous:cards:channel" broadcast → handle_info.
    assert render(lv) =~ "lives in: In Service"
    assert render(lv) =~ "the what"
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/slackex_web/live/chat_live/decide_test.exs`
Expected: FAIL — rendered HTML does not contain "lives in: In Service".

- [ ] **Step 3: Load the card map + subscribe in the chat LiveView**

In `lib/slackex_web/live/chat_live/index.ex`:

- In `mount/3`, add `|> assign(:card_messages, %{})` to the initial assigns.
- Where the LiveView subscribes to the channel topic (search for `Phoenix.PubSub.subscribe(Slackex.PubSub, "channel:#{...}"` around line 194/227), also subscribe to the Sous cards topic for the active channel and load the card map. Add a private helper and call it when a channel becomes active (in the function that sets `@active_channel` — typically `handle_params/3` or an `apply_action`):

```elixir
  defp load_sous_cards(socket, channel) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Slackex.PubSub, Slackex.Sous.cards_topic(channel.id))
    end

    assign(socket, :card_messages, Slackex.Sous.card_messages_for_channel(channel.id))
  end
```

Call `|> load_sous_cards(channel)` wherever `@active_channel` is assigned for a channel view.

- Add the `handle_info` for the live upgrade:

```elixir
  def handle_info({:decision_card, message_id, work_item}, socket) do
    {:noreply, update(socket, :card_messages, &Map.put(&1, message_id, work_item))}
  end
```

- [ ] **Step 4: Pass the card map down and add the render branch**

The message list renders each message via `message_bubble/1` in
`lib/slackex_web/components/chat_components.ex`. Pass the matching work item to each bubble. In the
template that loops messages (in `index.html.heex` or a component), compute and pass an optional
`work_item` assign. Simplest: pass `card_messages` to the bubble and let it look up.

In `chat_components.ex`, add an attr and a render branch. Near the top of `message_bubble/1` add:

```elixir
  attr :card_messages, :map, default: %{}
```

In the content area (after the `<div data-message-content>` block, around line 274), add:

```heex
            <% decision_wi = Map.get(@card_messages, @message.id) %>
            <div :if={decision_wi} class="loom mt-2 rounded-lg border border-base-300 p-3 space-y-1" data-decision-card>
              <div class="flex items-center justify-between">
                <span class="loom-modal-title font-semibold">{decision_wi.title}</span>
                <.link navigate={~p"/in-service"} class="text-xs text-primary">lives in: In Service →</.link>
              </div>
              <p :if={decision_wi.decision} class="text-sm"><span class="font-medium">What:</span> {decision_wi.decision.what}</p>
              <p :if={decision_wi.decision && decision_wi.decision.why not in [nil, ""]} class="text-sm"><span class="font-medium">Why:</span> {decision_wi.decision.why}</p>
              <p :if={decision_wi.decision && decision_wi.decision.next not in [nil, ""]} class="text-sm"><span class="font-medium">Next:</span> {decision_wi.decision.next}</p>
            </div>
```

Where `message_bubble/1` is invoked in the message list, pass `card_messages={@card_messages}`.
(Find the `<.message_bubble ... />` call site in `index.html.heex` and add the attribute.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/slackex_web/live/chat_live/decide_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/slackex_web/live/chat_live/index.ex \
        lib/slackex_web/components/chat_components.ex \
        test/slackex_web/live/chat_live/decide_test.exs
git commit -m "feat(sous): render decision cards in chat (two-step upgrade, ADR-002)"
```

---

## Task 14: In Service board route + LiveView (flag-gated)

**Files:**
- Create: `lib/slackex_web/live/sous_live/in_service.ex`
- Modify: `lib/slackex_web/router.ex`
- Test: `test/slackex_web/live/sous_live/in_service_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/slackex_web/live/sous_live/in_service_test.exs`:

```elixir
defmodule SlackexWeb.SousLive.InServiceTest do
  use SlackexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Slackex.Sous

  setup %{conn: conn} do
    alice = insert(:user, username: "alice")
    {:ok, channel} = Slackex.Chat.create_channel(alice.id, %{name: "deploys"})
    conn = log_in_user(conn, alice)
    %{conn: conn, alice: alice, channel: channel}
  end

  test "renders the four columns with an existing decision in Mise", %{conn: conn, alice: a, channel: c} do
    {:ok, _wi} = Sous.open_decision(%{channel_id: c.id, actor_id: a.id, title: "Board Item", what: "w", stakeholders: []})

    {:ok, _lv, html} = live(conn, ~p"/in-service")

    assert html =~ "Order"
    assert html =~ "Mise"
    assert html =~ "Pass"
    assert html =~ "Walked"
    assert html =~ "Board Item"
  end

  test "moving a card via a button updates the board", %{conn: conn, alice: a, channel: c} do
    {:ok, wi} = Sous.open_decision(%{channel_id: c.id, actor_id: a.id, title: "Mover", what: "w", stakeholders: []})

    {:ok, lv, _html} = live(conn, ~p"/in-service")

    lv |> element(~s{button[phx-value-id="#{wi.id}"][phx-value-to="pass"]}) |> render_click()

    assert Sous.list_in_flight()[:pass] |> Enum.map(& &1.id) == [wi.id]
  end

  test "redirects when the :sous flag is off", %{conn: conn} do
    FunWithFlags.disable(:sous)
    on_exit(fn -> FunWithFlags.enable(:sous) end)

    assert {:error, {:redirect, %{to: "/chat"}}} = live(conn, ~p"/in-service")
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/slackex_web/live/sous_live/in_service_test.exs`
Expected: FAIL — no route for `/in-service`.

- [ ] **Step 3: Add the route**

In `lib/slackex_web/router.ex`, inside the existing `live_session :chat do ... end` block (after the
last `live "/chat/:slug", ...` line, before the block's `end`), add:

```elixir
      live "/in-service", SousLive.InService, :index
```

Add the alias if the router aliases LiveViews explicitly; otherwise the `SlackexWeb` scope resolves
`SousLive.InService` to `SlackexWeb.SousLive.InService`.

- [ ] **Step 4: Create the board LiveView**

Create `lib/slackex_web/live/sous_live/in_service.ex`:

```elixir
defmodule SlackexWeb.SousLive.InService do
  @moduledoc """
  The In Service board (Slice A): four columns (Order/Mise/Pass/Walked) rendering
  work items for a single hard-coded viewer = the current user. Attention
  treatments per spec §7. Visual reference: handoff/design/src/in-service.jsx.
  """
  use SlackexWeb, :live_view

  alias Slackex.Sous

  @columns [
    {:order, "Order"},
    {:mise, "Mise"},
    {:pass, "Pass"},
    {:walked, "Walked"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if FunWithFlags.enabled?(:sous, for: user) do
      if connected?(socket), do: Phoenix.PubSub.subscribe(Slackex.PubSub, Sous.work_items_topic())

      {:ok,
       socket
       |> assign(:loom, true)
       |> assign(:columns, @columns)
       |> assign(:grouped, Sous.list_in_flight())}
    else
      {:ok, socket |> put_flash(:error, "Not available.") |> redirect(to: ~p"/chat")}
    end
  end

  @impl true
  def handle_event("move_work_item", %{"id" => id, "to" => to}, socket) do
    _ = Sous.move(String.to_integer(id), String.to_existing_atom(to), socket.assigns.current_user.id)
    {:noreply, assign(socket, :grouped, Sous.list_in_flight())}
  end

  @impl true
  def handle_info({:work_item_event, _type, _work_item}, socket) do
    {:noreply, assign(socket, :grouped, Sous.list_in_flight())}
  end

  # Attention → CSS treatment (spec §7).
  defp attention_class(:act), do: "border-l-4 border-primary"
  defp attention_class(:watch), do: "border border-base-300"
  defp attention_class(:know), do: "border border-dashed border-base-300 opacity-60"
  defp attention_class(:hidden), do: "hidden"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="loom fixed inset-0 z-50 bg-base-200 overflow-auto p-6">
      <div class="flex items-center justify-between mb-4">
        <h1 class="loom-modal-title text-2xl font-bold">In Service</h1>
        <.link navigate={~p"/chat"} class="btn btn-ghost btn-sm">Close</.link>
      </div>
      <div class="grid grid-cols-4 gap-4">
        <div :for={{state, label} <- @columns} class="flex flex-col gap-2">
          <h2 class="text-sm uppercase tracking-wide text-base-content/60">{label}</h2>
          <div
            :for={wi <- @grouped[state]}
            class={["rounded-lg bg-base-100 p-3", attention_class(wi.attention)]}
            data-work-item={wi.id}
          >
            <p class="font-semibold">{wi.title}</p>
            <p :if={wi.attention == :act} class="text-xs text-primary">behind</p>
            <p class="text-xs text-base-content/60">{wi.facet_text}</p>
            <div class="mt-2 flex flex-wrap gap-1">
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
          <p :if={@grouped[state] == []} class="text-xs text-base-content/40">—</p>
        </div>
      </div>
    </div>
    """
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/slackex_web/live/sous_live/in_service_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/slackex_web/live/sous_live/in_service.ex lib/slackex_web/router.ex \
        test/slackex_web/live/sous_live/in_service_test.exs
git commit -m "feat(sous): In Service board LiveView with attention treatments + moves"
```

---

## Task 15: Mandatory end-to-end integration test (cross-context + PubSub bridge)

Exercises the FULL path with the REAL message facade and a REAL subscribed board — no faked
upstream (CLAUDE.md). Uses a shared sandbox (`async: false`) because `ChannelServer` runs in its own
process.

**Files:**
- Create: `test/slackex/sous/slice_a_integration_test.exs`

- [ ] **Step 1: Write the integration test**

Create `test/slackex/sous/slice_a_integration_test.exs`:

```elixir
defmodule Slackex.Sous.SliceAIntegrationTest do
  @moduledoc "Full chat → work-item → board spine, real facade, no faked upstream."
  use SlackexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Slackex.Sous
  alias Slackex.Sous.WorkItem

  setup %{conn: conn} do
    Ecto.Adapters.SQL.Sandbox.mode(Slackex.Repo, {:shared, self()})
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Slackex.Repo, :manual) end)

    alice = insert(:user, username: "alice")
    {:ok, channel} = Slackex.Chat.create_channel(alice.id, %{name: "deploys"})
    conn = log_in_user(conn, alice)
    %{conn: conn, alice: alice, channel: channel}
  end

  test "/decide flows to a chat card AND the In Service board, then a move propagates", ctx do
    %{conn: conn, alice: alice, channel: channel} = ctx

    # A board client is live and subscribed (the consumer end of the bridge).
    {:ok, board, _html} = live(conn, ~p"/in-service")

    # Producer: open a decision + post its card through the real facade.
    {:ok, wi} = Sous.open_decision(%{channel_id: channel.id, actor_id: alice.id, title: "Wire it up", what: "do the thing", stakeholders: [alice.id]})
    {:ok, carded} = Sous.post_decision_card(wi, alice.id)

    # The work item is real, with both events in order.
    assert carded.card_message_id
    events = Slackex.Repo.all(Ecto.Query.from(e in Slackex.Sous.WorkItemEvent, where: e.work_item_id == ^wi.id, order_by: e.id))
    assert Enum.map(events, & &1.type) == [:created, :card_posted]

    # The board (consumer) shows it in Mise after the broadcast.
    assert render(board) =~ "Wire it up"

    # The chat surface renders the card (loaded from the channel card map).
    {:ok, chat, _} = live(conn, ~p"/chat/#{channel.slug}")
    assert render(chat) =~ "lives in: In Service"
    assert render(chat) =~ "do the thing"

    # A move propagates to the board.
    {:ok, _} = Sous.move(wi.id, :pass, alice.id)
    assert render(board) =~ "Wire it up"
    assert Sous.list_in_flight()[:pass] |> Enum.map(& &1.id) == [wi.id]
    refute match?(%WorkItem{state: :mise}, Slackex.Repo.get!(WorkItem, wi.id))
  end
end
```

- [ ] **Step 2: Run it to verify it passes**

Run: `mix test test/slackex/sous/slice_a_integration_test.exs`
Expected: PASS. If it fails on a DB ownership error from `ChannelServer`, confirm the shared-sandbox
`setup` ran and the test is `async: false`.

- [ ] **Step 3: Commit**

```bash
git add test/slackex/sous/slice_a_integration_test.exs
git commit -m "test(sous): mandatory end-to-end chat→work-item→board integration"
```

---

## Task 16: Sidebar nav entry + full-suite green

**Files:**
- Modify: the chat sidebar template (search `lib/slackex_web` for the channels sidebar in
  `chat_live/index.html.heex` or a sidebar component) to add an "In Service" link.

- [ ] **Step 1: Add the nav link (flag-gated)**

In the sidebar markup (near the CHANNELS section), add:

```heex
  <.link :if={FunWithFlags.enabled?(:sous, for: @current_user)} navigate={~p"/in-service"} class="block px-3 py-1 text-sm">
    In Service
  </.link>
```

- [ ] **Step 2: Run the full suite + quality gates**

Run: `mix test`
Expected: PASS — the prior count + the new Sous tests, zero failures.

Run: `mix format --check-formatted && mix credo --strict`
Expected: no issues. Fix any formatting/credo findings and re-run.

- [ ] **Step 3: Commit**

```bash
git add lib/slackex_web/live/chat_live/index.html.heex
git commit -m "feat(sous): flag-gated In Service nav link"
```

---

## Definition of Done (spec §12)

- [ ] All Sous tests pass, including the replay guard (Task 7) and the mandatory integration test (Task 15).
- [ ] `/decide` in a channel produces a decision card in chat AND a card on the In Service board, live.
- [ ] A card moves between columns; the move is an appended `:state_changed` event reflected live.
- [ ] Everything is behind `:sous`; with the flag off the board redirects and `/decide` does nothing special.
- [ ] No changes to `message.ex`, `channel_server.ex`, or `batch_writer.ex` (ADR-002).
- [ ] `mix test`, `mix format --check-formatted`, `mix credo --strict` all clean. (Run `mix dialyzer` before deploy.)
```
