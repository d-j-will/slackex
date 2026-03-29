# Dark Factory Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a work queue in Tenun where users queue feature specs and Claude Code sessions pick up, implement, and verify work via MCP tools.

**Architecture:** Two new DB tables (`factory_runs`, `factory_events`), one context module (`Slackex.Factory`), one Oban cron worker for lifecycle timeouts, one PubSub-driven GenServer for channel notifications, and 10 new MCP tools split into a dedicated `FactoryTools` module. Feature-flagged behind `:dark_factory`.

**Tech Stack:** Ecto, Oban (cron worker), Phoenix.PubSub, FunWithFlags, existing MCP server infrastructure.

**Spec:** `docs/feature/dark-factory/design/architecture.md`

---

## File Structure

| File | Responsibility |
|------|---------------|
| `priv/repo/migrations/TIMESTAMP_create_factory_tables.exs` | Create `factory_runs` and `factory_events` tables |
| `lib/slackex/factory/run.ex` | Ecto schema for `factory_runs` |
| `lib/slackex/factory/event.ex` | Ecto schema for `factory_events` |
| `lib/slackex/factory.ex` | Context module — state machine, queries, PubSub broadcasts |
| `lib/slackex/factory/lifecycle_worker.ex` | Oban cron worker — timeout enforcement |
| `lib/slackex/factory/channel_notifier.ex` | GenServer — PubSub subscriber, posts to channel threads |
| `lib/slackex_web/mcp/factory_tools.ex` | 10 factory MCP tool definitions and handlers |
| `lib/slackex_web/mcp/server.ex` | Modified — dispatch to `FactoryTools` for `factory_*` methods |
| `test/slackex/factory_test.exs` | Context module tests |
| `test/slackex/factory/lifecycle_worker_test.exs` | Oban worker tests |
| `test/slackex_web/mcp/factory_tools_test.exs` | MCP integration tests |

---

## Task 1: Migration — Create factory tables

**Files:**
- Create: `priv/repo/migrations/TIMESTAMP_create_factory_tables.exs`

- [ ] **Step 1: Generate the migration**

Run: `mix ecto.gen.migration create_factory_tables`

- [ ] **Step 2: Write the migration**

```elixir
defmodule Slackex.Repo.Migrations.CreateFactoryTables do
  use Ecto.Migration

  def change do
    create table(:factory_runs) do
      add :spec_path, :string, null: false
      add :spec_commit_sha, :string
      add :status, :string, null: false, default: "queued"
      add :queued_by_id, references(:users, on_delete: :restrict), null: false
      add :channel_id, references(:channels, on_delete: :restrict), null: false
      add :thread_message_id, :bigint
      add :branch_name, :string
      add :claim_token, :string
      add :claimed_at, :utc_datetime_usec
      add :last_heartbeat_at, :utc_datetime_usec
      add :attempt, :integer, null: false, default: 1
      add :max_attempts, :integer, null: false, default: 3
      add :heartbeat_timeout_minutes, :integer, null: false, default: 10
      add :tier1_result, :map
      add :tier2_result, :map
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:factory_runs, [:status])
    create index(:factory_runs, [:queued_by_id])
    create index(:factory_runs, [:status, :queued_by_id])

    create table(:factory_events) do
      add :factory_run_id, references(:factory_runs, on_delete: :delete_all), null: false
      add :event_type, :string, null: false
      add :from_status, :string
      add :to_status, :string
      add :message, :text
      add :metadata, :map

      timestamps(type: :utc_datetime_usec)
    end

    create index(:factory_events, [:factory_run_id])
  end
end
```

- [ ] **Step 3: Run the migration**

Run: `mix ecto.migrate`
Expected: Tables created successfully.

- [ ] **Step 4: Verify migration is reversible**

Run: `mix ecto.rollback && mix ecto.migrate`
Expected: Rollback and re-migrate succeed.

- [ ] **Step 5: Commit**

```
git add priv/repo/migrations/*_create_factory_tables.exs
git commit -m "feat(factory): create factory_runs and factory_events tables"
```

---

## Task 2: Ecto schemas — Run and Event

**Files:**
- Create: `lib/slackex/factory/run.ex`
- Create: `lib/slackex/factory/event.ex`

- [ ] **Step 1: Write the Run schema**

```elixir
defmodule Slackex.Factory.Run do
  @moduledoc """
  Ecto schema for factory pipeline runs. Tracks the lifecycle of a
  spec-to-implementation pipeline from queued through verification.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(queued implementing awaiting_verification verifying_tier2
               completed needs_review cancelled)

  schema "factory_runs" do
    field :spec_path, :string
    field :spec_commit_sha, :string
    field :status, :string, default: "queued"
    field :thread_message_id, :integer
    field :branch_name, :string
    field :claim_token, :string
    field :claimed_at, :utc_datetime_usec
    field :last_heartbeat_at, :utc_datetime_usec
    field :attempt, :integer, default: 1
    field :max_attempts, :integer, default: 3
    field :heartbeat_timeout_minutes, :integer, default: 10
    field :tier1_result, :map
    field :tier2_result, :map
    field :completed_at, :utc_datetime_usec

    belongs_to :queued_by, Slackex.Accounts.User
    belongs_to :channel, Slackex.Chat.Channel

    has_many :events, Slackex.Factory.Event

    timestamps(type: :utc_datetime_usec)
  end

  def queue_changeset(run, attrs) do
    run
    |> cast(attrs, [:spec_path, :queued_by_id, :channel_id, :max_attempts,
                    :heartbeat_timeout_minutes])
    |> validate_required([:spec_path, :queued_by_id, :channel_id])
    |> validate_length(:spec_path, min: 1, max: 500)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:queued_by_id)
    |> foreign_key_constraint(:channel_id)
  end

  def statuses, do: @statuses
end
```

- [ ] **Step 2: Write the Event schema**

```elixir
defmodule Slackex.Factory.Event do
  @moduledoc """
  Append-only audit log for factory pipeline runs.
  Each state transition and progress update is recorded as an event.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "factory_events" do
    field :event_type, :string
    field :from_status, :string
    field :to_status, :string
    field :message, :string
    field :metadata, :map

    belongs_to :factory_run, Slackex.Factory.Run

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:factory_run_id, :event_type, :from_status, :to_status,
                    :message, :metadata])
    |> validate_required([:factory_run_id, :event_type])
    |> validate_inclusion(:event_type, ~w(status_change progress error))
    |> foreign_key_constraint(:factory_run_id)
  end
end
```

- [ ] **Step 3: Verify schemas compile**

Run: `mix compile --warnings-as-errors`
Expected: Compilation succeeds with no warnings.

- [ ] **Step 4: Commit**

```
git add lib/slackex/factory/run.ex lib/slackex/factory/event.ex
git commit -m "feat(factory): add Run and Event ecto schemas"
```

---

## Task 3: Context module — Slackex.Factory (queue + list)

**Files:**
- Create: `lib/slackex/factory.ex`
- Create: `test/slackex/factory_test.exs`

- [ ] **Step 1: Write failing tests for queue_run and list functions**

```elixir
defmodule Slackex.FactoryTest do
  use Slackex.DataCase, async: true

  alias Slackex.Factory

  setup do
    user = insert(:user, is_bot: true)
    channel = insert(:channel, creator: insert(:user))
    %{bot: user, channel: channel}
  end

  describe "queue_run/2" do
    test "creates a run in queued status", %{bot: bot, channel: channel} do
      assert {:ok, run} =
               Factory.queue_run(%{
                 spec_path: "docs/feature/test-feature/",
                 queued_by_id: bot.id,
                 channel_id: channel.id
               })

      assert run.status == "queued"
      assert run.spec_path == "docs/feature/test-feature/"
      assert run.queued_by_id == bot.id
      assert run.attempt == 1
      assert run.max_attempts == 3
    end

    test "creates an initial status_change event", %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/test-feature/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      events = Factory.list_events(run.id)
      assert [event] = events
      assert event.event_type == "status_change"
      assert event.to_status == "queued"
    end

    test "rejects missing required fields" do
      assert {:error, _changeset} = Factory.queue_run(%{})
    end
  end

  describe "list_pending/1" do
    test "returns queued runs for a bot user", %{bot: bot, channel: channel} do
      {:ok, _run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      assert [run] = Factory.list_pending(bot.id)
      assert run.spec_path == "docs/feature/a/"
    end

    test "does not return runs for other users", %{bot: bot, channel: channel} do
      other_bot = insert(:user, is_bot: true)

      {:ok, _run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: other_bot.id,
          channel_id: channel.id
        })

      assert [] = Factory.list_pending(bot.id)
    end

    test "returns max 5 runs in FIFO order", %{bot: bot, channel: channel} do
      for i <- 1..7 do
        Factory.queue_run(%{
          spec_path: "docs/feature/f#{i}/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })
      end

      runs = Factory.list_pending(bot.id)
      assert length(runs) == 5
      assert hd(runs).spec_path == "docs/feature/f1/"
    end
  end

  describe "list_runs/2" do
    test "returns all non-terminal runs by default", %{bot: bot, channel: channel} do
      {:ok, _} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      assert [_] = Factory.list_runs(bot.id)
    end

    test "filters by status", %{bot: bot, channel: channel} do
      {:ok, _} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      assert [_] = Factory.list_runs(bot.id, status: "queued")
      assert [] = Factory.list_runs(bot.id, status: "implementing")
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/slackex/factory_test.exs`
Expected: FAIL — `Slackex.Factory` module does not exist.

- [ ] **Step 3: Write the context module (queue + list functions)**

```elixir
defmodule Slackex.Factory do
  @moduledoc """
  Context for the dark factory pipeline. Manages factory runs through their
  lifecycle: queued -> implementing -> awaiting_verification -> verifying_tier2
  -> completed.

  All state transitions are enforced here. MCP tools delegate to this module.
  """

  import Ecto.Query

  alias Slackex.Factory.{Event, Run}
  alias Slackex.Repo

  @terminal_statuses ~w(completed needs_review cancelled)

  # -- Queue -----------------------------------------------------------------

  def queue_run(attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:run, Run.queue_changeset(%Run{}, attrs))
    |> Ecto.Multi.insert(:event, fn %{run: run} ->
      Event.changeset(%Event{}, %{
        factory_run_id: run.id,
        event_type: "status_change",
        to_status: "queued",
        message: "Run queued for #{run.spec_path}"
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{run: run}} -> {:ok, run}
      {:error, :run, changeset, _} -> {:error, changeset}
    end
  end

  # -- List ------------------------------------------------------------------

  def list_pending(bot_user_id) do
    from(r in Run,
      where: r.queued_by_id == ^bot_user_id and r.status == "queued",
      order_by: [asc: r.inserted_at],
      limit: 5
    )
    |> Repo.all()
  end

  def list_pending_verification(bot_user_id) do
    from(r in Run,
      where: r.queued_by_id == ^bot_user_id and r.status == "awaiting_verification",
      order_by: [asc: r.inserted_at],
      limit: 5
    )
    |> Repo.all()
  end

  def list_runs(bot_user_id, opts \\ []) do
    query = from(r in Run, where: r.queued_by_id == ^bot_user_id, order_by: [desc: r.inserted_at])

    query =
      case Keyword.get(opts, :status) do
        nil -> where(query, [r], r.status not in ^@terminal_statuses)
        "all" -> query
        status -> where(query, [r], r.status == ^status)
      end

    Repo.all(query)
  end

  def list_events(run_id) do
    from(e in Event,
      where: e.factory_run_id == ^run_id,
      order_by: [asc: e.inserted_at]
    )
    |> Repo.all()
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/slackex/factory_test.exs`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```
git add lib/slackex/factory.ex test/slackex/factory_test.exs
git commit -m "feat(factory): add Factory context with queue_run and list functions"
```

---

## Task 4: Context module — claim_run (atomic claim with optimistic lock)

**Files:**
- Modify: `lib/slackex/factory.ex`
- Modify: `test/slackex/factory_test.exs`

- [ ] **Step 1: Write failing tests for claim_run**

Add to `test/slackex/factory_test.exs`:

```elixir
  describe "claim_run/2" do
    test "transitions queued -> implementing", %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      assert {:ok, claimed} =
               Factory.claim_run(run.id, %{commit_sha: "abc123"})

      assert claimed.status == "implementing"
      assert claimed.spec_commit_sha == "abc123"
      assert claimed.claim_token != nil
      assert claimed.claimed_at != nil
      assert claimed.last_heartbeat_at != nil
    end

    test "returns error when already claimed", %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      {:ok, _} = Factory.claim_run(run.id, %{commit_sha: "abc123"})
      assert {:error, :already_claimed} = Factory.claim_run(run.id, %{commit_sha: "def456"})
    end

    test "appends status_change event", %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      {:ok, _} = Factory.claim_run(run.id, %{commit_sha: "abc123"})
      events = Factory.list_events(run.id)
      claim_event = Enum.find(events, &(&1.from_status == "queued"))
      assert claim_event.to_status == "implementing"
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/slackex/factory_test.exs`
Expected: FAIL — `claim_run/2` undefined.

- [ ] **Step 3: Write claim_run in the context module**

Add to `lib/slackex/factory.ex`:

```elixir
  @token_bytes 16

  # -- Claim -----------------------------------------------------------------

  def claim_run(run_id, %{commit_sha: sha}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    token = generate_claim_token()

    result =
      from(r in Run, where: r.id == ^run_id and r.status == "queued")
      |> Repo.update_all(
        set: [
          status: "implementing",
          spec_commit_sha: sha,
          claim_token: token,
          claimed_at: now,
          last_heartbeat_at: now,
          updated_at: now
        ]
      )

    case result do
      {1, _} ->
        run = Repo.get!(Run, run_id)
        append_event(run, "queued", "implementing", "Run claimed")
        broadcast_update(run)
        {:ok, run}

      {0, _} ->
        {:error, :already_claimed}
    end
  end

  # -- Internal helpers (add at bottom of module) ----------------------------

  defp generate_claim_token do
    :crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false)
  end

  defp append_event(run, from_status, to_status, message, metadata \\ nil) do
    %Event{}
    |> Event.changeset(%{
      factory_run_id: run.id,
      event_type: "status_change",
      from_status: from_status,
      to_status: to_status,
      message: message,
      metadata: metadata
    })
    |> Repo.insert!()
  end

  defp broadcast_update(run) do
    Phoenix.PubSub.broadcast(
      Slackex.PubSub,
      "factory:events",
      {:factory_run_updated, run}
    )
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/slackex/factory_test.exs`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```
git add lib/slackex/factory.ex test/slackex/factory_test.exs
git commit -m "feat(factory): add atomic claim_run with optimistic locking"
```

---

## Task 5: Context module — heartbeat, submit_result, cancel

**Files:**
- Modify: `lib/slackex/factory.ex`
- Modify: `test/slackex/factory_test.exs`

- [ ] **Step 1: Write failing tests for heartbeat**

Add to `test/slackex/factory_test.exs`:

```elixir
  describe "heartbeat/2" do
    setup %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      {:ok, run} = Factory.claim_run(run.id, %{commit_sha: "abc"})
      %{run: run}
    end

    test "updates last_heartbeat_at with valid token", %{run: run} do
      old_heartbeat = run.last_heartbeat_at
      Process.sleep(10)
      assert {:ok, updated} = Factory.heartbeat(run.id, run.claim_token)
      assert DateTime.compare(updated.last_heartbeat_at, old_heartbeat) == :gt
    end

    test "rejects invalid claim token", %{run: run} do
      assert {:error, :invalid_token} = Factory.heartbeat(run.id, "wrong-token")
    end

    test "appends progress event when message provided", %{run: run} do
      {:ok, _} = Factory.heartbeat(run.id, run.claim_token, "Working on step 2")
      events = Factory.list_events(run.id)
      progress = Enum.find(events, &(&1.event_type == "progress"))
      assert progress.message == "Working on step 2"
    end
  end
```

- [ ] **Step 2: Write failing tests for submit_result**

Add to `test/slackex/factory_test.exs`:

```elixir
  describe "submit_result/2" do
    setup %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      {:ok, run} = Factory.claim_run(run.id, %{commit_sha: "abc"})
      %{run: run}
    end

    test "success transitions to awaiting_verification", %{run: run} do
      assert {:ok, updated} =
               Factory.submit_result(run.id, %{
                 claim_token: run.claim_token,
                 success: true,
                 branch_name: "factory/run-1",
                 summary: %{tests: 42, failures: 0}
               })

      assert updated.status == "awaiting_verification"
      assert updated.branch_name == "factory/run-1"
      assert updated.tier1_result == %{tests: 42, failures: 0}
    end

    test "failure with attempts remaining stays implementing", %{run: run} do
      assert {:ok, updated} =
               Factory.submit_result(run.id, %{
                 claim_token: run.claim_token,
                 success: false,
                 summary: %{error: "test failures"}
               })

      assert updated.status == "implementing"
      assert updated.attempt == 2
    end

    test "failure with no attempts remaining transitions to needs_review", %{
      bot: bot,
      channel: channel
    } do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/b/",
          queued_by_id: bot.id,
          channel_id: channel.id,
          max_attempts: 1
        })

      {:ok, run} = Factory.claim_run(run.id, %{commit_sha: "abc"})

      assert {:ok, updated} =
               Factory.submit_result(run.id, %{
                 claim_token: run.claim_token,
                 success: false,
                 summary: %{error: "test failures"}
               })

      assert updated.status == "needs_review"
    end

    test "rejects invalid claim token", %{run: run} do
      assert {:error, :invalid_token} =
               Factory.submit_result(run.id, %{
                 claim_token: "wrong",
                 success: true,
                 branch_name: "factory/run-1",
                 summary: %{}
               })
    end
  end
```

- [ ] **Step 3: Write failing tests for cancel_run**

Add to `test/slackex/factory_test.exs`:

```elixir
  describe "cancel_run/2" do
    test "cancels by claim token", %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      {:ok, run} = Factory.claim_run(run.id, %{commit_sha: "abc"})

      assert {:ok, cancelled} =
               Factory.cancel_run(run.id, %{claim_token: run.claim_token})

      assert cancelled.status == "cancelled"
    end

    test "cancels by owner (no claim token needed)", %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      assert {:ok, cancelled} =
               Factory.cancel_run(run.id, %{bot_user_id: bot.id})

      assert cancelled.status == "cancelled"
    end

    test "rejects cancel on terminal state", %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      {:ok, _} = Factory.cancel_run(run.id, %{bot_user_id: bot.id})

      assert {:error, :already_terminal} =
               Factory.cancel_run(run.id, %{bot_user_id: bot.id})
    end
  end
```

- [ ] **Step 4: Run tests to verify they all fail**

Run: `mix test test/slackex/factory_test.exs`
Expected: FAIL — `heartbeat/2`, `heartbeat/3`, `submit_result/2`, `cancel_run/2` undefined.

- [ ] **Step 5: Implement heartbeat, submit_result, cancel_run**

Add to `lib/slackex/factory.ex`:

```elixir
  # -- Heartbeat -------------------------------------------------------------

  def heartbeat(run_id, claim_token, message \\ nil) do
    with {:ok, run} <- get_and_validate_token(run_id, claim_token) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      {:ok, run} =
        run
        |> Ecto.Changeset.change(last_heartbeat_at: now)
        |> Repo.update()

      if message do
        %Event{}
        |> Event.changeset(%{
          factory_run_id: run.id,
          event_type: "progress",
          message: message
        })
        |> Repo.insert!()

        broadcast_update(run)
      end

      {:ok, run}
    end
  end

  # -- Submit Result ---------------------------------------------------------

  def submit_result(run_id, %{claim_token: token, success: success} = params) do
    with {:ok, run} <- get_and_validate_token(run_id, token) do
      if success do
        submit_success(run, params)
      else
        submit_failure(run, params)
      end
    end
  end

  defp submit_success(run, params) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    run
    |> Ecto.Changeset.change(
      status: "awaiting_verification",
      branch_name: params.branch_name,
      tier1_result: params.summary,
      completed_at: now
    )
    |> Repo.update()
    |> case do
      {:ok, run} ->
        append_event(run, "implementing", "awaiting_verification",
          "Implementation complete — awaiting Tier 2 verification")
        broadcast_update(run)
        {:ok, run}
    end
  end

  defp submit_failure(run, params) do
    if run.attempt < run.max_attempts do
      run
      |> Ecto.Changeset.change(
        attempt: run.attempt + 1,
        tier1_result: params[:summary]
      )
      |> Repo.update()
      |> case do
        {:ok, run} ->
          append_event(run, nil, nil,
            "Attempt #{run.attempt - 1} failed, retrying (#{run.attempt}/#{run.max_attempts})",
            params[:summary])
          broadcast_update(run)
          {:ok, run}
      end
    else
      run
      |> Ecto.Changeset.change(
        status: "needs_review",
        tier1_result: params[:summary]
      )
      |> Repo.update()
      |> case do
        {:ok, run} ->
          append_event(run, "implementing", "needs_review",
            "All #{run.max_attempts} attempts exhausted — needs human review")
          broadcast_update(run)
          {:ok, run}
      end
    end
  end

  # -- Cancel ----------------------------------------------------------------

  def cancel_run(run_id, %{claim_token: token}) do
    with {:ok, run} <- get_and_validate_token(run_id, token) do
      do_cancel(run)
    end
  end

  def cancel_run(run_id, %{bot_user_id: bot_id}) do
    run = Repo.get!(Run, run_id)

    if run.queued_by_id == bot_id do
      do_cancel(run)
    else
      {:error, :unauthorized}
    end
  end

  defp do_cancel(run) do
    if run.status in @terminal_statuses do
      {:error, :already_terminal}
    else
      old_status = run.status

      run
      |> Ecto.Changeset.change(status: "cancelled")
      |> Repo.update()
      |> case do
        {:ok, run} ->
          append_event(run, old_status, "cancelled", "Run cancelled")
          broadcast_update(run)
          {:ok, run}
      end
    end
  end

  # -- Token validation (add to internal helpers) ----------------------------

  defp get_and_validate_token(run_id, token) do
    case Repo.get(Run, run_id) do
      %Run{claim_token: ^token} = run -> {:ok, run}
      %Run{} -> {:error, :invalid_token}
      nil -> {:error, :not_found}
    end
  end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/slackex/factory_test.exs`
Expected: All tests pass.

- [ ] **Step 7: Commit**

```
git add lib/slackex/factory.ex test/slackex/factory_test.exs
git commit -m "feat(factory): add heartbeat, submit_result, and cancel_run"
```

---

## Task 6: Context module — verification claim and submit

**Files:**
- Modify: `lib/slackex/factory.ex`
- Modify: `test/slackex/factory_test.exs`

- [ ] **Step 1: Write failing tests for verification functions**

Add to `test/slackex/factory_test.exs`:

```elixir
  describe "claim_verification/1" do
    setup %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      {:ok, run} = Factory.claim_run(run.id, %{commit_sha: "abc"})

      {:ok, run} =
        Factory.submit_result(run.id, %{
          claim_token: run.claim_token,
          success: true,
          branch_name: "factory/run-1",
          summary: %{tests: 10}
        })

      %{run: run}
    end

    test "transitions awaiting_verification -> verifying_tier2", %{run: run} do
      assert {:ok, claimed} = Factory.claim_verification(run.id)

      assert claimed.status == "verifying_tier2"
      assert claimed.claim_token != nil
      assert claimed.claimed_at != nil
    end

    test "returns error when already claimed", %{run: run} do
      {:ok, _} = Factory.claim_verification(run.id)
      assert {:error, :already_claimed} = Factory.claim_verification(run.id)
    end
  end

  describe "submit_verification/2" do
    setup %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      {:ok, run} = Factory.claim_run(run.id, %{commit_sha: "abc"})

      {:ok, run} =
        Factory.submit_result(run.id, %{
          claim_token: run.claim_token,
          success: true,
          branch_name: "factory/run-1",
          summary: %{tests: 10}
        })

      {:ok, run} = Factory.claim_verification(run.id)
      %{run: run}
    end

    test "pass transitions to completed", %{run: run} do
      assert {:ok, completed} =
               Factory.submit_verification(run.id, %{
                 claim_token: run.claim_token,
                 passed: true,
                 scenarios_run: 5,
                 scenarios_passed: 5,
                 details: %{}
               })

      assert completed.status == "completed"
      assert completed.completed_at != nil
      assert completed.tier2_result.scenarios_run == 5
    end

    test "fail transitions to needs_review", %{run: run} do
      assert {:ok, review} =
               Factory.submit_verification(run.id, %{
                 claim_token: run.claim_token,
                 passed: false,
                 scenarios_run: 5,
                 scenarios_passed: 3,
                 details: %{failed: ["scenario_1", "scenario_2"]}
               })

      assert review.status == "needs_review"
    end
  end

  describe "list_pending_verification/1" do
    test "returns awaiting_verification runs", %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      {:ok, run} = Factory.claim_run(run.id, %{commit_sha: "abc"})

      {:ok, _} =
        Factory.submit_result(run.id, %{
          claim_token: run.claim_token,
          success: true,
          branch_name: "factory/run-1",
          summary: %{}
        })

      assert [pending] = Factory.list_pending_verification(bot.id)
      assert pending.status == "awaiting_verification"
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/slackex/factory_test.exs`
Expected: FAIL — `claim_verification/1`, `submit_verification/2` undefined.

- [ ] **Step 3: Implement claim_verification and submit_verification**

Add to `lib/slackex/factory.ex`:

```elixir
  # -- Verification ----------------------------------------------------------

  def claim_verification(run_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    token = generate_claim_token()

    result =
      from(r in Run, where: r.id == ^run_id and r.status == "awaiting_verification")
      |> Repo.update_all(
        set: [
          status: "verifying_tier2",
          claim_token: token,
          claimed_at: now,
          last_heartbeat_at: now,
          updated_at: now
        ]
      )

    case result do
      {1, _} ->
        run = Repo.get!(Run, run_id)
        append_event(run, "awaiting_verification", "verifying_tier2", "Verification started")
        broadcast_update(run)
        {:ok, run}

      {0, _} ->
        {:error, :already_claimed}
    end
  end

  def submit_verification(run_id, %{claim_token: token, passed: passed} = params) do
    with {:ok, run} <- get_and_validate_token(run_id, token) do
      tier2_result = %{
        scenarios_run: params.scenarios_run,
        scenarios_passed: params.scenarios_passed,
        details: params[:details]
      }

      new_status = if passed, do: "completed", else: "needs_review"
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      completed_at = if passed, do: now, else: run.completed_at

      run
      |> Ecto.Changeset.change(
        status: new_status,
        tier2_result: tier2_result,
        completed_at: completed_at
      )
      |> Repo.update()
      |> case do
        {:ok, run} ->
          message =
            if passed,
              do: "Tier 2 passed (#{params.scenarios_passed}/#{params.scenarios_run}) — ready for review",
              else: "Tier 2 failed (#{params.scenarios_passed}/#{params.scenarios_run}) — needs review"

          append_event(run, "verifying_tier2", new_status, message, tier2_result)
          broadcast_update(run)
          {:ok, run}
      end
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/slackex/factory_test.exs`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```
git add lib/slackex/factory.ex test/slackex/factory_test.exs
git commit -m "feat(factory): add verification claim and submit functions"
```

---

## Task 7: Lifecycle worker — Oban cron for timeout enforcement

**Files:**
- Create: `lib/slackex/factory/lifecycle_worker.ex`
- Create: `test/slackex/factory/lifecycle_worker_test.exs`
- Modify: `config/config.exs` (add cron entry and queue)
- Modify: `lib/slackex/factory.ex` (add `release_stale_claims/0`)

- [ ] **Step 1: Write failing tests for release_stale_claims**

```elixir
defmodule Slackex.Factory.LifecycleWorkerTest do
  use Slackex.DataCase, async: false

  alias Slackex.Factory

  setup do
    bot = insert(:user, is_bot: true)
    channel = insert(:channel, creator: insert(:user))
    %{bot: bot, channel: channel}
  end

  describe "release_stale_claims/0" do
    test "releases implementing run past heartbeat timeout", %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id,
          heartbeat_timeout_minutes: 1
        })

      {:ok, run} = Factory.claim_run(run.id, %{commit_sha: "abc"})

      # Backdate heartbeat to exceed timeout
      stale = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:microsecond)

      run
      |> Ecto.Changeset.change(last_heartbeat_at: stale)
      |> Slackex.Repo.update!()

      assert {1, _} = Factory.release_stale_claims()

      updated = Slackex.Repo.get!(Slackex.Factory.Run, run.id)
      assert updated.status == "queued"
      assert updated.claim_token == nil
      assert updated.claimed_at == nil
      assert updated.branch_name == nil
      assert updated.attempt == 1
    end

    test "releases verifying_tier2 run back to awaiting_verification", %{
      bot: bot,
      channel: channel
    } do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id,
          heartbeat_timeout_minutes: 1
        })

      {:ok, run} = Factory.claim_run(run.id, %{commit_sha: "abc"})

      {:ok, run} =
        Factory.submit_result(run.id, %{
          claim_token: run.claim_token,
          success: true,
          branch_name: "factory/run-1",
          summary: %{}
        })

      {:ok, run} = Factory.claim_verification(run.id)

      stale = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:microsecond)

      run
      |> Ecto.Changeset.change(last_heartbeat_at: stale)
      |> Slackex.Repo.update!()

      assert {1, _} = Factory.release_stale_claims()

      updated = Slackex.Repo.get!(Slackex.Factory.Run, run.id)
      assert updated.status == "awaiting_verification"
      assert updated.claim_token == nil
    end

    test "does not release runs within timeout", %{bot: bot, channel: channel} do
      {:ok, run} =
        Factory.queue_run(%{
          spec_path: "docs/feature/a/",
          queued_by_id: bot.id,
          channel_id: channel.id
        })

      {:ok, _} = Factory.claim_run(run.id, %{commit_sha: "abc"})

      assert {0, _} = Factory.release_stale_claims()
    end
  end

  describe "perform/1" do
    test "calls release_stale_claims" do
      assert :ok = perform_job(Slackex.Factory.LifecycleWorker, %{})
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/slackex/factory/lifecycle_worker_test.exs`
Expected: FAIL — modules not defined.

- [ ] **Step 3: Add release_stale_claims to Factory context**

Add to `lib/slackex/factory.ex`:

```elixir
  # -- Lifecycle -------------------------------------------------------------

  def release_stale_claims do
    now = DateTime.utc_now()

    # Release stale implementing runs -> queued
    implementing_released =
      from(r in Run,
        where: r.status == "implementing",
        where:
          fragment(
            "? + make_interval(mins => ?) < ?",
            r.last_heartbeat_at,
            r.heartbeat_timeout_minutes,
            ^now
          )
      )
      |> Repo.update_all(
        set: [
          status: "queued",
          claim_token: nil,
          claimed_at: nil,
          last_heartbeat_at: nil,
          branch_name: nil,
          updated_at: now |> DateTime.truncate(:microsecond)
        ]
      )

    # Release stale verifying_tier2 runs -> awaiting_verification
    verifying_released =
      from(r in Run,
        where: r.status == "verifying_tier2",
        where:
          fragment(
            "? + make_interval(mins => ?) < ?",
            r.last_heartbeat_at,
            r.heartbeat_timeout_minutes,
            ^now
          )
      )
      |> Repo.update_all(
        set: [
          status: "awaiting_verification",
          claim_token: nil,
          claimed_at: nil,
          last_heartbeat_at: nil,
          updated_at: now |> DateTime.truncate(:microsecond)
        ]
      )

    {elem(implementing_released, 0) + elem(verifying_released, 0), nil}
  end
```

- [ ] **Step 4: Write the Oban worker**

```elixir
defmodule Slackex.Factory.LifecycleWorker do
  @moduledoc """
  Oban cron worker that runs every 2 minutes to release stale factory run
  claims. A run is stale when its last_heartbeat_at exceeds its
  heartbeat_timeout_minutes.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if FunWithFlags.enabled?(:dark_factory) do
      Slackex.Factory.release_stale_claims()
    end

    :ok
  end
end
```

- [ ] **Step 5: Add cron entry and queue config**

In `config/config.exs`, add to the existing crontab list:

```elixir
{"*/2 * * * *", Slackex.Factory.LifecycleWorker}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/slackex/factory/lifecycle_worker_test.exs`
Expected: All tests pass.

- [ ] **Step 7: Run full factory test suite**

Run: `mix test test/slackex/factory_test.exs test/slackex/factory/lifecycle_worker_test.exs`
Expected: All tests pass.

- [ ] **Step 8: Commit**

```
git add lib/slackex/factory.ex lib/slackex/factory/lifecycle_worker.ex \
  test/slackex/factory/lifecycle_worker_test.exs config/config.exs
git commit -m "feat(factory): add lifecycle worker for timeout enforcement"
```

---

## Task 8: Channel notifier — PubSub subscriber

**Files:**
- Create: `lib/slackex/factory/channel_notifier.ex`
- Modify: `lib/slackex/application.ex` (add to supervisor children)

- [ ] **Step 1: Write the ChannelNotifier GenServer**

```elixir
defmodule Slackex.Factory.ChannelNotifier do
  @moduledoc """
  Subscribes to factory PubSub events and posts status updates to the
  run's channel thread. Uses the bot user who queued the run as sender.

  Supervised with `restart: :temporary` — factory notifications failing
  must not affect the chat application.
  """

  use GenServer

  require Logger

  @pubsub Slackex.PubSub
  @topic "factory:events"

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(_opts) do
    _ = Phoenix.PubSub.subscribe(@pubsub, @topic)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info({:factory_run_updated, run}, state) do
    if FunWithFlags.enabled?(:dark_factory) do
      notify(run)
    end

    {:noreply, state}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  defp notify(%{channel_id: nil}), do: :ok

  defp notify(run) do
    events = Slackex.Factory.list_events(run.id)
    latest = List.last(events)

    if latest do
      message = format_message(run, latest)
      post_to_thread(run, message)
    end
  rescue
    error ->
      Logger.warning("ChannelNotifier failed for run #{run.id}: #{inspect(error)}")
  end

  defp format_message(run, event) do
    prefix = "[Factory: #{Path.basename(run.spec_path)}]"

    case event.event_type do
      "status_change" -> "#{prefix} #{event.message}"
      "progress" -> "#{prefix} #{event.message}"
      "error" -> "#{prefix} Error: #{event.message}"
      _ -> "#{prefix} #{event.message}"
    end
  end

  defp post_to_thread(%{thread_message_id: nil} = run, message) do
    # First message — create the thread
    case Slackex.Messaging.send_message(run.channel_id, run.queued_by_id, message, []) do
      {:ok, msg} ->
        run
        |> Ecto.Changeset.change(thread_message_id: msg.id)
        |> Slackex.Repo.update()

      {:error, reason} ->
        Logger.warning("ChannelNotifier: failed to create thread: #{inspect(reason)}")
    end
  end

  defp post_to_thread(run, message) do
    case Slackex.Messaging.send_reply(
           run.channel_id,
           :channel,
           run.queued_by_id,
           run.thread_message_id,
           message
         ) do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("ChannelNotifier: failed to post update: #{inspect(reason)}")
    end
  end
end
```

- [ ] **Step 2: Add to application supervisor**

In `lib/slackex/application.ex`, add `Slackex.Factory.ChannelNotifier` to the children list after the existing listeners (after `Slackex.Links.LinkPreviewListener`):

```elixir
Slackex.Factory.ChannelNotifier,
```

- [ ] **Step 3: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: Compilation succeeds.

- [ ] **Step 4: Commit**

```
git add lib/slackex/factory/channel_notifier.ex lib/slackex/application.ex
git commit -m "feat(factory): add ChannelNotifier for PubSub -> thread updates"
```

---

## Task 9: MCP factory tools — tool definitions and dispatch

**Files:**
- Create: `lib/slackex_web/mcp/factory_tools.ex`
- Modify: `lib/slackex_web/mcp/server.ex` (add dispatch to factory tools)

- [ ] **Step 1: Create the FactoryTools module with tool definitions**

```elixir
defmodule SlackexWeb.MCP.FactoryTools do
  @moduledoc """
  MCP tool definitions and handlers for the dark factory pipeline.
  Delegates all business logic to `Slackex.Factory` context.
  """

  alias Slackex.Factory

  def tools do
    [
      %{
        name: "queue_factory_run",
        description: "Queue a feature spec for dark factory implementation",
        inputSchema: %{
          type: "object",
          required: ["spec_path", "channel_id"],
          properties: %{
            "spec_path" => %{type: "string", description: "Path to spec directory (e.g. docs/feature/my-feature/)"},
            "channel_id" => %{type: "string", description: "Channel ID for status updates"}
          }
        }
      },
      %{
        name: "list_factory_work",
        description: "List pending factory runs available for implementation (max 5, FIFO)",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "claim_factory_work",
        description: "Claim a queued run for implementation. Returns claim token required for all subsequent updates.",
        inputSchema: %{
          type: "object",
          required: ["run_id", "commit_sha"],
          properties: %{
            "run_id" => %{type: "string", description: "Factory run ID"},
            "commit_sha" => %{type: "string", description: "Git HEAD commit SHA"}
          }
        }
      },
      %{
        name: "factory_heartbeat",
        description: "Heartbeat to keep a factory run claim alive. Optionally posts a progress message to the run's channel thread.",
        inputSchema: %{
          type: "object",
          required: ["run_id", "claim_token"],
          properties: %{
            "run_id" => %{type: "string", description: "Factory run ID"},
            "claim_token" => %{type: "string", description: "Claim token from claim response"},
            "message" => %{type: "string", description: "Optional progress message"}
          }
        }
      },
      %{
        name: "submit_factory_result",
        description: "Submit implementation result. On success, moves to verification queue. On failure, retries or escalates to needs_review.",
        inputSchema: %{
          type: "object",
          required: ["run_id", "claim_token", "success"],
          properties: %{
            "run_id" => %{type: "string", description: "Factory run ID"},
            "claim_token" => %{type: "string", description: "Claim token"},
            "success" => %{type: "boolean", description: "Whether implementation + Tier 1 tests passed"},
            "branch_name" => %{type: "string", description: "Git branch name (required if success)"},
            "summary" => %{type: "object", description: "Result summary (test counts, errors, etc.)"}
          }
        }
      },
      %{
        name: "list_verification_work",
        description: "List factory runs awaiting Tier 2 verification (max 5, FIFO). Returns spec and branch only — no implementation context.",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "claim_verification_work",
        description: "Claim a run for Tier 2 verification. Returns claim token, spec path, and branch name.",
        inputSchema: %{
          type: "object",
          required: ["run_id"],
          properties: %{
            "run_id" => %{type: "string", description: "Factory run ID"}
          }
        }
      },
      %{
        name: "submit_verification",
        description: "Submit Tier 2 verification results. Pass moves to completed. Fail moves to needs_review (never retries).",
        inputSchema: %{
          type: "object",
          required: ["run_id", "claim_token", "passed", "scenarios_run", "scenarios_passed"],
          properties: %{
            "run_id" => %{type: "string", description: "Factory run ID"},
            "claim_token" => %{type: "string", description: "Claim token"},
            "passed" => %{type: "boolean", description: "Whether all scenarios passed"},
            "scenarios_run" => %{type: "integer", description: "Total scenarios executed"},
            "scenarios_passed" => %{type: "integer", description: "Scenarios that passed"},
            "details" => %{type: "object", description: "Per-scenario results"}
          }
        }
      },
      %{
        name: "list_factory_runs",
        description: "List all factory runs with optional status filter. Defaults to non-terminal runs.",
        inputSchema: %{
          type: "object",
          properties: %{
            "status" => %{type: "string", description: "Filter by status (omit for non-terminal, 'all' for everything)"}
          }
        }
      },
      %{
        name: "cancel_factory_run",
        description: "Cancel a factory run. Requires claim_token if in-flight, or ownership if queued.",
        inputSchema: %{
          type: "object",
          required: ["run_id"],
          properties: %{
            "run_id" => %{type: "string", description: "Factory run ID"},
            "claim_token" => %{type: "string", description: "Claim token (optional if you own the run)"}
          }
        }
      }
    ]
  end

  # -- Tool handlers ---------------------------------------------------------

  def call_tool("queue_factory_run", %{"spec_path" => path, "channel_id" => cid}, session) do
    with {:ok, channel_id} <- parse_id(cid) do
      case Factory.queue_run(%{
             spec_path: path,
             queued_by_id: session.bot_user.id,
             channel_id: channel_id
           }) do
        {:ok, run} ->
          {:ok, json_content(%{run_id: to_string(run.id), status: run.status})}

        {:error, changeset} ->
          {:error, format_errors(changeset)}
      end
    end
  end

  def call_tool("list_factory_work", _args, session) do
    runs = Factory.list_pending(session.bot_user.id)
    data = Enum.map(runs, &serialize_run_summary/1)
    {:ok, json_content(data)}
  end

  def call_tool("claim_factory_work", %{"run_id" => rid, "commit_sha" => sha}, _session) do
    with {:ok, run_id} <- parse_id(rid) do
      case Factory.claim_run(run_id, %{commit_sha: sha}) do
        {:ok, run} ->
          {:ok,
           json_content(%{
             claim_token: run.claim_token,
             spec_path: run.spec_path,
             spec_commit_sha: run.spec_commit_sha,
             channel_id: to_string(run.channel_id),
             thread_message_id: run.thread_message_id && to_string(run.thread_message_id),
             attempt: run.attempt,
             max_attempts: run.max_attempts
           })}

        {:error, reason} ->
          {:error, to_string(reason)}
      end
    end
  end

  def call_tool("factory_heartbeat", %{"run_id" => rid, "claim_token" => token} = args, _session) do
    with {:ok, run_id} <- parse_id(rid) do
      case Factory.heartbeat(run_id, token, args["message"]) do
        {:ok, _} -> {:ok, json_content(%{ok: true})}
        {:error, reason} -> {:error, to_string(reason)}
      end
    end
  end

  def call_tool("submit_factory_result", %{"run_id" => rid, "claim_token" => token} = args, _session) do
    with {:ok, run_id} <- parse_id(rid) do
      params = %{
        claim_token: token,
        success: args["success"],
        branch_name: args["branch_name"],
        summary: args["summary"] || %{}
      }

      case Factory.submit_result(run_id, params) do
        {:ok, run} ->
          result = %{status: run.status, attempt: run.attempt, max_attempts: run.max_attempts}

          result =
            if run.status == "implementing",
              do: Map.put(result, :retry, true),
              else: result

          {:ok, json_content(result)}

        {:error, reason} ->
          {:error, to_string(reason)}
      end
    end
  end

  def call_tool("list_verification_work", _args, session) do
    runs = Factory.list_pending_verification(session.bot_user.id)

    data =
      Enum.map(runs, fn r ->
        %{
          run_id: to_string(r.id),
          spec_path: r.spec_path,
          spec_commit_sha: r.spec_commit_sha,
          branch_name: r.branch_name
        }
      end)

    {:ok, json_content(data)}
  end

  def call_tool("claim_verification_work", %{"run_id" => rid}, _session) do
    with {:ok, run_id} <- parse_id(rid) do
      case Factory.claim_verification(run_id) do
        {:ok, run} ->
          {:ok,
           json_content(%{
             claim_token: run.claim_token,
             spec_path: run.spec_path,
             spec_commit_sha: run.spec_commit_sha,
             branch_name: run.branch_name
           })}

        {:error, reason} ->
          {:error, to_string(reason)}
      end
    end
  end

  def call_tool(
        "submit_verification",
        %{"run_id" => rid, "claim_token" => token} = args,
        _session
      ) do
    with {:ok, run_id} <- parse_id(rid) do
      params = %{
        claim_token: token,
        passed: args["passed"],
        scenarios_run: args["scenarios_run"],
        scenarios_passed: args["scenarios_passed"],
        details: args["details"] || %{}
      }

      case Factory.submit_verification(run_id, params) do
        {:ok, run} -> {:ok, json_content(%{status: run.status})}
        {:error, reason} -> {:error, to_string(reason)}
      end
    end
  end

  def call_tool("list_factory_runs", args, session) do
    opts =
      case args["status"] do
        nil -> []
        status -> [status: status]
      end

    runs = Factory.list_runs(session.bot_user.id, opts)
    data = Enum.map(runs, &serialize_run_summary/1)
    {:ok, json_content(data)}
  end

  def call_tool("cancel_factory_run", %{"run_id" => rid} = args, session) do
    with {:ok, run_id} <- parse_id(rid) do
      cancel_params =
        if args["claim_token"],
          do: %{claim_token: args["claim_token"]},
          else: %{bot_user_id: session.bot_user.id}

      case Factory.cancel_run(run_id, cancel_params) do
        {:ok, run} -> {:ok, json_content(%{status: run.status})}
        {:error, reason} -> {:error, to_string(reason)}
      end
    end
  end

  def call_tool(name, _args, _session), do: {:error, "Unknown factory tool: #{name}"}

  # -- Helpers ---------------------------------------------------------------

  defp parse_id(str) when is_binary(str) do
    case Integer.parse(str) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "Invalid ID: #{str}"}
    end
  end

  defp parse_id(_), do: {:error, "Invalid ID"}

  defp json_content(data) do
    [%{type: "text", text: Jason.encode!(data)}]
  end

  defp serialize_run_summary(run) do
    %{
      run_id: to_string(run.id),
      spec_path: run.spec_path,
      status: run.status,
      attempt: run.attempt,
      branch_name: run.branch_name,
      inserted_at: DateTime.to_iso8601(run.inserted_at)
    }
  end

  defp format_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> inspect()
  end

  defp format_errors(other), do: inspect(other)
end
```

- [ ] **Step 2: Wire FactoryTools into MCP Server dispatch**

In `lib/slackex_web/mcp/server.ex`, modify the `dispatch` function for `tools/list` to include factory tools, and add a dispatch clause for factory tool calls.

Change `tools/list` dispatch:

```elixir
  defp dispatch(%{"method" => "tools/list"} = req, _session) do
    all_tools =
      if FunWithFlags.enabled?(:dark_factory),
        do: tools() ++ SlackexWeb.MCP.FactoryTools.tools(),
        else: tools()

    ok_response(req["id"], %{tools: all_tools})
  end
```

Change `tools/call` dispatch to try factory tools:

```elixir
  defp dispatch(%{"method" => "tools/call", "params" => params} = req, session) do
    name = params["name"]
    args = params["arguments"] || %{}

    result =
      if String.starts_with?(name, "queue_factory") or
           String.starts_with?(name, "list_factory") or
           String.starts_with?(name, "claim_factory") or
           String.starts_with?(name, "factory_") or
           String.starts_with?(name, "submit_factory") or
           String.starts_with?(name, "list_verification") or
           String.starts_with?(name, "claim_verification") or
           String.starts_with?(name, "submit_verification") or
           String.starts_with?(name, "cancel_factory") do
        if FunWithFlags.enabled?(:dark_factory) do
          SlackexWeb.MCP.FactoryTools.call_tool(name, args, session)
        else
          {:error, "Dark factory is not enabled"}
        end
      else
        call_tool(name, args, session)
      end

    case result do
      {:ok, content} ->
        ok_response(req["id"], %{content: content})

      {:error, msg} ->
        ok_response(req["id"], %{content: [%{type: "text", text: "Error: #{msg}"}], isError: true})
    end
  end
```

- [ ] **Step 3: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: Compilation succeeds.

- [ ] **Step 4: Commit**

```
git add lib/slackex_web/mcp/factory_tools.ex lib/slackex_web/mcp/server.ex
git commit -m "feat(factory): add MCP factory tools and wire into server dispatch"
```

---

## Task 10: MCP integration tests

**Files:**
- Create: `test/slackex_web/mcp/factory_tools_test.exs`

- [ ] **Step 1: Write MCP integration tests**

```elixir
defmodule SlackexWeb.MCP.FactoryToolsTest do
  use SlackexWeb.ConnCase, async: false

  alias Slackex.Integrations.McpTokens

  setup do
    user = insert(:user)
    channel = insert(:channel, creator: user, is_private: false)
    insert(:subscription, user: user, channel: channel)

    {:ok, %{mcp_token: _token, raw_token: raw_token, bot_user: bot}} =
      McpTokens.create_mcp_token(%{name: "Factory Agent"})

    insert(:subscription, user: bot, channel: channel)
    FunWithFlags.enable(:dark_factory)

    %{channel: channel, bot: bot, raw_token: raw_token}
  end

  defp mcp_post(conn, raw_token, body) do
    conn
    |> put_req_header("authorization", "Bearer #{raw_token}")
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", body)
  end

  defp jsonrpc(method, params, id \\ 1) do
    %{"jsonrpc" => "2.0", "method" => method, "id" => id, "params" => params}
  end

  defp call_tool(conn, token, name, args \\ %{}) do
    mcp_post(conn, token, jsonrpc("tools/call", %{"name" => name, "arguments" => args}))
  end

  defp parse_tool_result(conn) do
    %{"result" => %{"content" => [%{"text" => text}]}} = json_response(conn, 200)
    Jason.decode!(text)
  end

  describe "full factory pipeline via MCP" do
    test "queue -> claim -> submit success -> claim verification -> submit pass", %{
      conn: conn,
      raw_token: token,
      channel: channel
    } do
      # Queue
      conn1 =
        call_tool(conn, token, "queue_factory_run", %{
          "spec_path" => "docs/feature/test/",
          "channel_id" => to_string(channel.id)
        })

      result = parse_tool_result(conn1)
      run_id = result["run_id"]
      assert result["status"] == "queued"

      # List work
      conn2 = call_tool(build_conn(), token, "list_factory_work")
      runs = parse_tool_result(conn2)
      assert length(runs) == 1
      assert hd(runs)["run_id"] == run_id

      # Claim
      conn3 =
        call_tool(build_conn(), token, "claim_factory_work", %{
          "run_id" => run_id,
          "commit_sha" => "abc123"
        })

      claim = parse_tool_result(conn3)
      assert claim["claim_token"] != nil
      claim_token = claim["claim_token"]

      # Heartbeat
      conn4 =
        call_tool(build_conn(), token, "factory_heartbeat", %{
          "run_id" => run_id,
          "claim_token" => claim_token,
          "message" => "Working on it"
        })

      assert %{"ok" => true} = parse_tool_result(conn4)

      # Submit success
      conn5 =
        call_tool(build_conn(), token, "submit_factory_result", %{
          "run_id" => run_id,
          "claim_token" => claim_token,
          "success" => true,
          "branch_name" => "factory/run-1",
          "summary" => %{"tests" => 42}
        })

      submit = parse_tool_result(conn5)
      assert submit["status"] == "awaiting_verification"

      # List verification work
      conn6 = call_tool(build_conn(), token, "list_verification_work")
      v_runs = parse_tool_result(conn6)
      assert length(v_runs) == 1
      assert hd(v_runs)["branch_name"] == "factory/run-1"

      # Claim verification
      conn7 =
        call_tool(build_conn(), token, "claim_verification_work", %{"run_id" => run_id})

      v_claim = parse_tool_result(conn7)
      v_token = v_claim["claim_token"]
      assert v_token != nil

      # Submit verification pass
      conn8 =
        call_tool(build_conn(), token, "submit_verification", %{
          "run_id" => run_id,
          "claim_token" => v_token,
          "passed" => true,
          "scenarios_run" => 5,
          "scenarios_passed" => 5,
          "details" => %{}
        })

      v_result = parse_tool_result(conn8)
      assert v_result["status"] == "completed"
    end

    test "cancel by owner", %{conn: conn, raw_token: token, channel: channel} do
      conn1 =
        call_tool(conn, token, "queue_factory_run", %{
          "spec_path" => "docs/feature/cancel-test/",
          "channel_id" => to_string(channel.id)
        })

      run_id = parse_tool_result(conn1)["run_id"]

      conn2 =
        call_tool(build_conn(), token, "cancel_factory_run", %{"run_id" => run_id})

      assert %{"status" => "cancelled"} = parse_tool_result(conn2)
    end

    test "tools hidden when feature flag disabled", %{conn: conn, raw_token: token} do
      FunWithFlags.disable(:dark_factory)

      body = %{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 1}
      conn1 = mcp_post(conn, token, body)

      %{"result" => %{"tools" => tools}} = json_response(conn1, 200)
      tool_names = Enum.map(tools, & &1["name"])
      refute "queue_factory_run" in tool_names
    end
  end
end
```

- [ ] **Step 2: Run the integration tests**

Run: `mix test test/slackex_web/mcp/factory_tools_test.exs`
Expected: All tests pass.

- [ ] **Step 3: Run the full test suite**

Run: `mix test`
Expected: All tests pass, no regressions.

- [ ] **Step 4: Commit**

```
git add test/slackex_web/mcp/factory_tools_test.exs
git commit -m "feat(factory): add MCP integration tests for full pipeline"
```

---

## Task 11: Dialyzer + final verification

**Files:** None new — verification only.

- [ ] **Step 1: Run dialyzer**

Run: `mix dialyzer`
Expected: 0 errors.

- [ ] **Step 2: Run credo**

Run: `mix credo --strict`
Expected: No issues (or only pre-existing ones).

- [ ] **Step 3: Run the full test suite one final time**

Run: `mix test`
Expected: All tests pass.

- [ ] **Step 4: Verify feature flag guards everything**

Open an IEx session and confirm factory tools are hidden when flag is off:

Run: `mix test test/slackex_web/mcp/factory_tools_test.exs`

The "tools hidden when feature flag disabled" test covers this.

- [ ] **Step 5: Final commit if any cleanup was needed**

If dialyzer or credo required fixes, commit them:

```
git commit -m "chore(factory): address dialyzer/credo feedback"
```
