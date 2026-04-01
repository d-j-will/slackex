# Website Analytics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a homegrown analytics system combining product analytics (feature usage, hotspots) with operational analytics (errors, performance) to Tenun, surfaced via an in-app admin UI and Grafana dashboards.

**Architecture:** Event-sourced design — all analytics events (page views, feature usage, errors, performance, clicks) are written to a single `analytics_events` Postgres table via async Oban jobs. Server-side collection via Plug (HTTP) and on_mount hook (LiveView WebSocket). Client-side collection via a JS LiveView hook. Query layer provides aggregation functions consumed by both an admin LiveView and a Prometheus MetricsBridge for Grafana.

**Tech Stack:** Elixir/Phoenix LiveView, PostgreSQL (jsonb), Oban (async write + cron), FunWithFlags (feature gating), TelemetryMetricsPrometheus.Core (metrics export), Grafana (dashboards + alerting)

**Spec:** `docs/superpowers/specs/2026-04-01-website-analytics-design.md`

---

## File Structure

### New Files

```
lib/slackex/analytics.ex                         — Analytics context (track/3, query functions)
lib/slackex/analytics/event.ex                    — Ecto schema for analytics_events
lib/slackex/analytics/track_worker.ex             — Oban worker for async event insert
lib/slackex/analytics/prune_worker.ex             — Oban cron job for 90-day retention cleanup
lib/slackex/analytics/metrics_bridge.ex           — Oban cron job emitting Prometheus gauges
lib/slackex/analytics/telemetry_handler.ex        — Attaches to Phoenix/Oban exception telemetry
lib/slackex_web/plugs/analytics_plug.ex           — HTTP-level page view + error tracking
lib/slackex_web/live/analytics_tracker.ex          — on_mount hook for LiveView navigation tracking
lib/slackex_web/live/admin_live/analytics.ex       — Admin analytics LiveView (4 tabs)
lib/slackex_web/live/admin_live/analytics.html.heex — Admin analytics template
assets/js/hooks/analytics.js                      — Client-side error, perf, click tracking
infra/grafana/dashboards/tenun-analytics.json     — Grafana analytics dashboard
priv/repo/migrations/*_create_analytics_events.exs — Migration

test/slackex/analytics_test.exs                   — Context unit + query tests
test/slackex/analytics/track_worker_test.exs       — TrackWorker test
test/slackex/analytics/prune_worker_test.exs       — PruneWorker test
test/slackex/analytics/telemetry_handler_test.exs  — TelemetryHandler test
test/slackex_web/plugs/analytics_plug_test.exs     — Plug test
test/slackex_web/live/admin_live/analytics_test.exs — Admin UI LiveView test
test/slackex/analytics/integration_test.exs        — Full pipeline integration test
test/slackex/analytics/contract_test.exs           — Prometheus metric name contract tests
```

### Modified Files

```
lib/slackex_web/router.ex                         — Add admin analytics routes
lib/slackex_web/endpoint.ex                        — Add Analytics.Plug to pipeline
config/config.exs                                  — Add :analytics Oban queue + cron jobs
assets/js/app.js                                   — Register Analytics hook
test/support/test_factory.ex                       — Add analytics_event_factory
```

---

## Task 1: Schema, Migration, and Test Factory

**Files:**
- Create: `lib/slackex/analytics/event.ex`
- Create: `priv/repo/migrations/*_create_analytics_events.exs`
- Modify: `test/support/test_factory.ex`
- Test: `test/slackex/analytics_test.exs`

- [ ] **Step 1: Generate the migration**

Run:
```bash
mix ecto.gen.migration create_analytics_events
```

- [ ] **Step 2: Write the migration**

Open the generated file in `priv/repo/migrations/` and write:

```elixir
defmodule Slackex.Repo.Migrations.CreateAnalyticsEvents do
  use Ecto.Migration

  def change do
    create table(:analytics_events, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :event_type, :string, null: false
      add :event_category, :string, null: false
      add :event_name, :string, null: false
      add :user_id, references(:users, type: :bigint, on_delete: :nilify_all), null: true
      add :session_id, :string
      add :metadata, :map, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:analytics_events, [:event_type, :inserted_at])
    create index(:analytics_events, [:user_id, :inserted_at])
    create index(:analytics_events, [:metadata], using: :gin)
  end
end
```

- [ ] **Step 3: Run the migration**

Run:
```bash
mix ecto.migrate
```
Expected: Migration succeeds, table created.

- [ ] **Step 4: Write the Ecto schema**

Create `lib/slackex/analytics/event.ex`:

```elixir
defmodule Slackex.Analytics.Event do
  use Ecto.Schema
  import Ecto.Changeset

  alias Slackex.Infrastructure.Snowflake

  @primary_key {:id, :integer, autogenerate: false}

  @valid_event_types ~w(page_view feature_used js_error server_error oban_error performance click)
  @valid_categories ~w(product error performance)

  schema "analytics_events" do
    field :event_type, :string
    field :event_category, :string
    field :event_name, :string
    field :user_id, :integer
    field :session_id, :string
    field :metadata, :map, default: %{}
    field :inserted_at, :utc_datetime_usec
  end

  def changeset(event \\ %__MODULE__{}, attrs) do
    event
    |> cast(attrs, [:event_type, :event_category, :event_name, :user_id, :session_id, :metadata])
    |> validate_required([:event_type, :event_category, :event_name])
    |> validate_inclusion(:event_type, @valid_event_types)
    |> validate_inclusion(:event_category, @valid_categories)
    |> put_snowflake_id()
    |> put_inserted_at()
  end

  defp put_snowflake_id(changeset) do
    case get_field(changeset, :id) do
      nil -> put_change(changeset, :id, Snowflake.generate())
      _ -> changeset
    end
  end

  defp put_inserted_at(changeset) do
    case get_field(changeset, :inserted_at) do
      nil -> put_change(changeset, :inserted_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))
      _ -> changeset
    end
  end
end
```

- [ ] **Step 5: Write the changeset test**

Create `test/slackex/analytics_test.exs`:

```elixir
defmodule Slackex.AnalyticsTest do
  use Slackex.DataCase, async: true

  alias Slackex.Analytics.Event

  describe "Event.changeset/2" do
    test "valid attrs produce a valid changeset" do
      attrs = %{
        event_type: "page_view",
        event_category: "product",
        event_name: "chat_index_viewed",
        session_id: "test-session-123",
        metadata: %{"path" => "/chat/general"}
      }

      changeset = Event.changeset(attrs)
      assert changeset.valid?
      assert get_change(changeset, :id) != nil
      assert get_change(changeset, :inserted_at) != nil
    end

    test "rejects invalid event_type" do
      attrs = %{event_type: "invalid", event_category: "product", event_name: "test"}
      changeset = Event.changeset(attrs)
      refute changeset.valid?
      assert {"is invalid", _} = changeset.errors[:event_type]
    end

    test "rejects invalid event_category" do
      attrs = %{event_type: "page_view", event_category: "invalid", event_name: "test"}
      changeset = Event.changeset(attrs)
      refute changeset.valid?
      assert {"is invalid", _} = changeset.errors[:event_category]
    end

    test "requires event_type, event_category, event_name" do
      changeset = Event.changeset(%{})
      refute changeset.valid?
      assert changeset.errors[:event_type]
      assert changeset.errors[:event_category]
      assert changeset.errors[:event_name]
    end
  end
end
```

- [ ] **Step 6: Run test to verify it passes**

Run:
```bash
mix test test/slackex/analytics_test.exs -v
```
Expected: 4 tests pass.

- [ ] **Step 7: Add analytics_event factory to test helpers**

Add to `test/support/test_factory.ex`:

```elixir
def analytics_event_factory do
  %Slackex.Analytics.Event{
    id: unique_bigint_id(),
    event_type: "page_view",
    event_category: "product",
    event_name: sequence(:event_name, &"event_#{&1}"),
    session_id: Ecto.UUID.generate(),
    metadata: %{"path" => "/chat/general"},
    inserted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  }
end
```

- [ ] **Step 8: Commit**

```bash
git add lib/slackex/analytics/event.ex priv/repo/migrations/*_create_analytics_events.exs test/slackex/analytics_test.exs test/support/test_factory.ex
git commit -m "feat(analytics): add Event schema, migration, and test factory"
```

---

## Task 2: Analytics Context — track/3 and TrackWorker

**Files:**
- Create: `lib/slackex/analytics.ex`
- Create: `lib/slackex/analytics/track_worker.ex`
- Modify: `config/config.exs` (add `:analytics` queue)
- Test: `test/slackex/analytics_test.exs` (append)
- Test: `test/slackex/analytics/track_worker_test.exs`

- [ ] **Step 1: Add `:analytics` Oban queue to config**

In `config/config.exs`, add `analytics: 5` to the Oban queues list:

```elixir
config :slackex, Oban,
  repo: Slackex.Repo,
  queues: [default: 10, notifications: 20, embeddings: 5, link_previews: 5, analytics: 5],
```

- [ ] **Step 2: Write the TrackWorker test**

Create `test/slackex/analytics/track_worker_test.exs`:

```elixir
defmodule Slackex.Analytics.TrackWorkerTest do
  use Slackex.DataCase, async: true
  use Oban.Testing, repo: Slackex.Repo

  alias Slackex.Analytics.TrackWorker
  alias Slackex.Analytics.Event
  alias Slackex.Repo

  describe "perform/1" do
    test "inserts an analytics event into the database" do
      args = %{
        "event_type" => "page_view",
        "event_category" => "product",
        "event_name" => "chat_viewed",
        "session_id" => "sess-123",
        "metadata" => %{"path" => "/chat/general"}
      }

      assert :ok = perform_job(TrackWorker, args)

      event = Repo.one!(Event)
      assert event.event_type == "page_view"
      assert event.event_category == "product"
      assert event.event_name == "chat_viewed"
      assert event.session_id == "sess-123"
      assert event.metadata["path"] == "/chat/general"
    end

    test "inserts event with user_id when provided" do
      user = insert(:user)

      args = %{
        "event_type" => "feature_used",
        "event_category" => "product",
        "event_name" => "search_opened",
        "user_id" => user.id,
        "session_id" => "sess-456",
        "metadata" => %{"feature" => "search"}
      }

      assert :ok = perform_job(TrackWorker, args)

      event = Repo.one!(Event)
      assert event.user_id == user.id
    end

    test "returns error on invalid attrs" do
      args = %{
        "event_type" => "invalid_type",
        "event_category" => "product",
        "event_name" => "test"
      }

      assert {:error, _changeset} = perform_job(TrackWorker, args)
    end
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run:
```bash
mix test test/slackex/analytics/track_worker_test.exs -v
```
Expected: FAIL — `TrackWorker` module does not exist.

- [ ] **Step 4: Write TrackWorker**

Create `lib/slackex/analytics/track_worker.ex`:

```elixir
defmodule Slackex.Analytics.TrackWorker do
  use Oban.Worker, queue: :analytics, max_attempts: 3

  alias Slackex.Analytics.Event
  alias Slackex.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    attrs = %{
      event_type: args["event_type"],
      event_category: args["event_category"],
      event_name: args["event_name"],
      user_id: args["user_id"],
      session_id: args["session_id"],
      metadata: args["metadata"] || %{}
    }

    case Event.changeset(attrs) |> Repo.insert() do
      {:ok, _event} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end
end
```

- [ ] **Step 5: Run test to verify it passes**

Run:
```bash
mix test test/slackex/analytics/track_worker_test.exs -v
```
Expected: 3 tests pass.

- [ ] **Step 6: Write the Analytics.track/3 test**

Append to `test/slackex/analytics_test.exs`:

```elixir
describe "track/3" do
  test "enqueues a TrackWorker job with correct args" do
    user = insert(:user)

    Slackex.Analytics.track(
      %{user_id: user.id, session_id: "sess-789"},
      "feature_used",
      %{feature: "reactions", action: "add"}
    )

    assert_enqueued(
      worker: Slackex.Analytics.TrackWorker,
      args: %{
        "event_type" => "feature_used",
        "event_category" => "product",
        "event_name" => "feature_used",
        "user_id" => user.id,
        "session_id" => "sess-789",
        "metadata" => %{"feature" => "reactions", "action" => "add"}
      }
    )
  end

  test "does not enqueue when :website_analytics flag is disabled" do
    FunWithFlags.disable(:website_analytics)

    Slackex.Analytics.track(
      %{user_id: 1, session_id: "sess-000"},
      "page_view",
      %{path: "/chat"}
    )

    refute_enqueued(worker: Slackex.Analytics.TrackWorker)

    # Re-enable for other tests
    FunWithFlags.enable(:website_analytics)
  end

  test "does not enqueue for bot users" do
    FunWithFlags.enable(:website_analytics)
    bot = insert(:user, is_bot: true)

    Slackex.Analytics.track(
      %{user_id: bot.id, session_id: "sess-bot", is_bot: true},
      "page_view",
      %{path: "/chat"}
    )

    refute_enqueued(worker: Slackex.Analytics.TrackWorker)
  end

  test "does not enqueue for users with :exclude_from_analytics flag" do
    FunWithFlags.enable(:website_analytics)
    user = insert(:user)
    FunWithFlags.enable(:exclude_from_analytics, for_actor: user)

    Slackex.Analytics.track(
      %{user_id: user.id, session_id: "sess-admin", user: user},
      "page_view",
      %{path: "/chat"}
    )

    refute_enqueued(worker: Slackex.Analytics.TrackWorker)

    FunWithFlags.disable(:exclude_from_analytics, for_actor: user)
  end
end
```

- [ ] **Step 7: Run test to verify it fails**

Run:
```bash
mix test test/slackex/analytics_test.exs --only describe:"track/3" -v
```
Expected: FAIL — `Slackex.Analytics.track/3` not defined.

- [ ] **Step 8: Write the Analytics context with track/3**

Create `lib/slackex/analytics.ex`:

```elixir
defmodule Slackex.Analytics do
  @moduledoc """
  Analytics context for tracking user behavior, errors, and performance.
  All events are gated behind the :website_analytics feature flag.
  """

  alias Slackex.Analytics.TrackWorker

  @category_map %{
    "page_view" => "product",
    "feature_used" => "product",
    "click" => "product",
    "js_error" => "error",
    "server_error" => "error",
    "oban_error" => "error",
    "performance" => "performance"
  }

  @doc """
  Track an analytics event asynchronously via Oban.

  `context` is a map with at least `:user_id` and `:session_id`.
  Optionally include `:is_bot` and `:user` (the full user struct for flag checks).

  `event_type` is one of: page_view, feature_used, click, js_error, server_error, oban_error, performance.

  `metadata` is a map of event-specific data.
  """
  def track(context, event_type, metadata \\ %{}) do
    with :ok <- check_enabled(),
         :ok <- check_not_bot(context),
         :ok <- check_not_excluded(context) do
      enqueue_event(context, event_type, metadata)
    else
      :skip -> :ok
    end
  end

  defp check_enabled do
    if FunWithFlags.enabled?(:website_analytics), do: :ok, else: :skip
  end

  defp check_not_bot(%{is_bot: true}), do: :skip
  defp check_not_bot(_context), do: :ok

  defp check_not_excluded(%{user: %{} = user}) do
    if FunWithFlags.enabled?(:exclude_from_analytics, for: user), do: :skip, else: :ok
  end
  defp check_not_excluded(_context), do: :ok

  defp enqueue_event(context, event_type, metadata) do
    category = Map.get(@category_map, event_type, "product")

    %{
      event_type: event_type,
      event_category: category,
      event_name: event_type,
      user_id: context[:user_id],
      session_id: context[:session_id],
      metadata: metadata |> stringify_keys()
    }
    |> TrackWorker.new()
    |> Oban.insert()

    :ok
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
```

- [ ] **Step 9: Run tests to verify they pass**

Run:
```bash
mix test test/slackex/analytics_test.exs -v
```
Expected: All tests pass (changeset tests + track/3 tests).

- [ ] **Step 10: Commit**

```bash
git add lib/slackex/analytics.ex lib/slackex/analytics/track_worker.ex config/config.exs test/slackex/analytics_test.exs test/slackex/analytics/track_worker_test.exs
git commit -m "feat(analytics): add Analytics context with track/3 and async TrackWorker"
```

---

## Task 3: Analytics.Plug (HTTP Collection)

**Files:**
- Create: `lib/slackex_web/plugs/analytics_plug.ex`
- Modify: `lib/slackex_web/endpoint.ex` (add plug)
- Test: `test/slackex_web/plugs/analytics_plug_test.exs`

- [ ] **Step 1: Write the Plug test**

Create `test/slackex_web/plugs/analytics_plug_test.exs`:

```elixir
defmodule SlackexWeb.Plugs.AnalyticsPlugTest do
  use SlackexWeb.ConnCase, async: true
  use Oban.Testing, repo: Slackex.Repo

  alias SlackexWeb.Plugs.AnalyticsPlug

  setup do
    FunWithFlags.enable(:website_analytics)
    on_exit(fn -> FunWithFlags.disable(:website_analytics) end)
    :ok
  end

  describe "call/2" do
    test "generates session_id when none exists" do
      conn =
        build_conn(:get, "/chat")
        |> init_test_session(%{})
        |> AnalyticsPlug.call(AnalyticsPlug.init([]))

      session_id = Plug.Conn.get_session(conn, :analytics_session_id)
      assert is_binary(session_id)
      assert String.length(session_id) == 36  # UUID
    end

    test "preserves existing session_id" do
      existing_id = Ecto.UUID.generate()

      conn =
        build_conn(:get, "/chat")
        |> init_test_session(%{analytics_session_id: existing_id})
        |> AnalyticsPlug.call(AnalyticsPlug.init([]))

      assert Plug.Conn.get_session(conn, :analytics_session_id) == existing_id
    end

    test "is a no-op when :website_analytics flag is disabled" do
      FunWithFlags.disable(:website_analytics)

      conn =
        build_conn(:get, "/chat")
        |> init_test_session(%{})
        |> AnalyticsPlug.call(AnalyticsPlug.init([]))

      refute Plug.Conn.get_session(conn, :analytics_session_id)
      refute_enqueued(worker: Slackex.Analytics.TrackWorker)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
mix test test/slackex_web/plugs/analytics_plug_test.exs -v
```
Expected: FAIL — module `SlackexWeb.Plugs.AnalyticsPlug` not found.

- [ ] **Step 3: Write Analytics.Plug**

Create `lib/slackex_web/plugs/analytics_plug.ex`:

```elixir
defmodule SlackexWeb.Plugs.AnalyticsPlug do
  @moduledoc """
  Plug that tracks HTTP page views and manages analytics session IDs.
  Only fires on the initial HTTP request — LiveView navigations are
  handled by Analytics.LiveViewTracker via WebSocket.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if FunWithFlags.enabled?(:website_analytics) do
      conn
      |> ensure_session_id()
      |> register_page_view_callback()
    else
      conn
    end
  end

  defp ensure_session_id(conn) do
    case get_session(conn, :analytics_session_id) do
      nil ->
        session_id = Ecto.UUID.generate()
        put_session(conn, :analytics_session_id, session_id)

      _existing ->
        conn
    end
  end

  defp register_page_view_callback(conn) do
    register_before_send(conn, fn conn ->
      if conn.status in 200..299 and html_request?(conn) do
        track_page_view(conn)
      end

      conn
    end)
  end

  defp track_page_view(conn) do
    user = conn.assigns[:current_user]
    is_bot = if user, do: Map.get(user, :is_bot, false), else: false

    context = %{
      user_id: if(user, do: user.id),
      session_id: get_session(conn, :analytics_session_id),
      is_bot: is_bot,
      user: user
    }

    Slackex.Analytics.track(context, "page_view", %{
      path: conn.request_path,
      referrer: get_req_header(conn, "referer") |> List.first(),
      is_reconnect: false
    })
  end

  defp html_request?(conn) do
    case get_resp_header(conn, "content-type") do
      [content_type | _] -> String.contains?(content_type, "text/html")
      [] -> false
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
mix test test/slackex_web/plugs/analytics_plug_test.exs -v
```
Expected: 3 tests pass.

- [ ] **Step 5: Add the Plug to the endpoint**

In `lib/slackex_web/endpoint.ex`, add after the session plug and before the router:

```elixir
plug SlackexWeb.Plugs.AnalyticsPlug
```

This must come after `Plug.Session` (so sessions are available) and before `SlackexWeb.Router`.

- [ ] **Step 6: Commit**

```bash
git add lib/slackex_web/plugs/analytics_plug.ex lib/slackex_web/endpoint.ex test/slackex_web/plugs/analytics_plug_test.exs
git commit -m "feat(analytics): add HTTP-level AnalyticsPlug for page views and session IDs"
```

---

## Task 4: Analytics.LiveViewTracker (WebSocket Collection)

**Files:**
- Create: `lib/slackex_web/live/analytics_tracker.ex`
- Modify: `lib/slackex_web/router.ex` (add to on_mount)

- [ ] **Step 1: Write the LiveViewTracker module**

Create `lib/slackex_web/live/analytics_tracker.ex`:

```elixir
defmodule SlackexWeb.AnalyticsTracker do
  @moduledoc """
  LiveView on_mount hook that tracks navigation events within a LiveView session.
  Captures page views on handle_params (live_patch/live_navigate) and mount timing.
  """

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]

  def on_mount(:default, _params, session, socket) do
    if FunWithFlags.enabled?(:website_analytics) and connected?(socket) do
      mount_start = System.monotonic_time(:millisecond)
      session_id = session["analytics_session_id"]
      user = socket.assigns[:current_user]

      socket =
        socket
        |> assign(:analytics_session_id, session_id)
        |> assign(:analytics_mount_start, mount_start)
        |> attach_hook(:analytics_handle_params, :handle_params, fn params, uri, socket ->
          track_navigation(socket, uri)
          {:cont, socket}
        end)

      # Track the initial mount
      track_mount(socket, user, session_id, mount_start)

      {:cont, socket}
    else
      {:cont, socket}
    end
  end

  defp track_mount(socket, user, session_id, mount_start) do
    duration_ms = System.monotonic_time(:millisecond) - mount_start
    is_bot = if user, do: Map.get(user, :is_bot, false), else: false

    context = %{
      user_id: if(user, do: user.id),
      session_id: session_id,
      is_bot: is_bot,
      user: user
    }

    Slackex.Analytics.track(context, "page_view", %{
      path: socket.assigns[:current_path] || "/",
      live_action: to_string(socket.assigns[:live_action] || :index),
      duration_ms: duration_ms,
      is_reconnect: false
    })
  end

  defp track_navigation(socket, uri) do
    user = socket.assigns[:current_user]
    is_bot = if user, do: Map.get(user, :is_bot, false), else: false
    path = URI.parse(uri).path

    context = %{
      user_id: if(user, do: user.id),
      session_id: socket.assigns[:analytics_session_id],
      is_bot: is_bot,
      user: user
    }

    Slackex.Analytics.track(context, "page_view", %{
      path: path,
      live_action: to_string(socket.assigns[:live_action] || :unknown),
      is_reconnect: false
    })
  end
end
```

- [ ] **Step 2: Add to router's authenticated live_session**

In `lib/slackex_web/router.ex`, add `SlackexWeb.AnalyticsTracker` to the authenticated live_session's `on_mount` list:

```elixir
live_session :authenticated,
  on_mount: [
    {SlackexWeb.UserAuth, :ensure_authenticated},
    SlackexWeb.AnalyticsTracker
  ] do
```

Note: `SlackexWeb.AnalyticsTracker` must come AFTER `UserAuth` so that `current_user` is available in assigns.

- [ ] **Step 3: Run the full test suite to verify no regressions**

Run:
```bash
mix test --max-failures 5
```
Expected: All tests pass. The tracker is a no-op when the flag is disabled, so existing tests are unaffected.

- [ ] **Step 4: Commit**

```bash
git add lib/slackex_web/live/analytics_tracker.ex lib/slackex_web/router.ex
git commit -m "feat(analytics): add LiveViewTracker on_mount hook for navigation tracking"
```

---

## Task 5: Analytics.TelemetryHandler (Exception Listeners)

**Files:**
- Create: `lib/slackex/analytics/telemetry_handler.ex`
- Modify: `lib/slackex_web/telemetry.ex` (attach handlers)
- Test: `test/slackex/analytics/telemetry_handler_test.exs`

- [ ] **Step 1: Write the TelemetryHandler test**

Create `test/slackex/analytics/telemetry_handler_test.exs`:

```elixir
defmodule Slackex.Analytics.TelemetryHandlerTest do
  use Slackex.DataCase, async: true
  use Oban.Testing, repo: Slackex.Repo

  alias Slackex.Analytics.TelemetryHandler

  setup do
    FunWithFlags.enable(:website_analytics)
    TelemetryHandler.attach()
    on_exit(fn ->
      FunWithFlags.disable(:website_analytics)
      :telemetry.detach("analytics-lv-exception")
      :telemetry.detach("analytics-oban-exception")
    end)
    :ok
  end

  describe "LiveView exception handler" do
    test "tracks server_error on LiveView handle_event exception" do
      :telemetry.execute(
        [:phoenix, :live_view, :handle_event, :exception],
        %{duration: 1_000_000},
        %{
          event: "click",
          socket: %{assigns: %{current_user: nil}},
          kind: :error,
          reason: %RuntimeError{message: "test error"},
          stacktrace: []
        }
      )

      assert_enqueued(
        worker: Slackex.Analytics.TrackWorker,
        args: %{"event_type" => "server_error"}
      )
    end
  end

  describe "Oban exception handler" do
    test "tracks oban_error on job exception" do
      :telemetry.execute(
        [:oban, :job, :exception],
        %{duration: 2_000_000},
        %{
          job: %Oban.Job{
            worker: "Slackex.Workers.CacheWarmer",
            queue: "default",
            args: %{"key" => "value"},
            attempt: 1
          },
          kind: :error,
          reason: %RuntimeError{message: "job failed"},
          stacktrace: []
        }
      )

      assert_enqueued(
        worker: Slackex.Analytics.TrackWorker,
        args: %{"event_type" => "oban_error"}
      )
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
mix test test/slackex/analytics/telemetry_handler_test.exs -v
```
Expected: FAIL — `TelemetryHandler` module not found.

- [ ] **Step 3: Write TelemetryHandler**

Create `lib/slackex/analytics/telemetry_handler.ex`:

```elixir
defmodule Slackex.Analytics.TelemetryHandler do
  @moduledoc """
  Attaches to Phoenix and Oban telemetry events to track exceptions.
  """

  require Logger

  def attach do
    :telemetry.attach(
      "analytics-lv-exception",
      [:phoenix, :live_view, :handle_event, :exception],
      &__MODULE__.handle_liveview_exception/4,
      nil
    )

    :telemetry.attach(
      "analytics-oban-exception",
      [:oban, :job, :exception],
      &__MODULE__.handle_oban_exception/4,
      nil
    )
  end

  def handle_liveview_exception(_event_name, _measurements, metadata, _config) do
    if FunWithFlags.enabled?(:website_analytics) do
      %{kind: kind, reason: reason, stacktrace: stacktrace} = metadata
      user = get_in(metadata, [:socket, :assigns, :current_user])

      trace_id = get_otel_trace_id()

      context = %{
        user_id: if(user, do: Map.get(user, :id)),
        session_id: nil
      }

      Slackex.Analytics.track(context, "server_error", %{
        kind: inspect(kind),
        reason: inspect(reason),
        stacktrace: Exception.format_stacktrace(stacktrace) |> String.slice(0, 2000),
        path: get_in(metadata, [:socket, :assigns, :current_path]),
        trace_id: trace_id
      })
    end
  end

  def handle_oban_exception(_event_name, _measurements, metadata, _config) do
    if FunWithFlags.enabled?(:website_analytics) do
      %{job: job, kind: kind, reason: reason, stacktrace: stacktrace} = metadata
      trace_id = get_otel_trace_id()

      context = %{user_id: nil, session_id: nil}

      Slackex.Analytics.track(context, "oban_error", %{
        worker: job.worker,
        queue: to_string(job.queue),
        args: inspect(job.args) |> String.slice(0, 500),
        error: inspect(reason) |> String.slice(0, 2000),
        attempt: job.attempt,
        trace_id: trace_id
      })
    end
  end

  defp get_otel_trace_id do
    try do
      span_ctx = OpenTelemetry.Tracer.current_span_ctx()
      case span_ctx do
        :undefined -> nil
        ctx -> OpenTelemetry.Span.trace_id(ctx) |> Integer.to_string(16) |> String.downcase()
      end
    rescue
      _ -> nil
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
mix test test/slackex/analytics/telemetry_handler_test.exs -v
```
Expected: 2 tests pass.

- [ ] **Step 5: Attach handlers in telemetry.ex**

In `lib/slackex_web/telemetry.ex`, add to the `start/2` or `init/1` function:

```elixir
Slackex.Analytics.TelemetryHandler.attach()
```

- [ ] **Step 6: Commit**

```bash
git add lib/slackex/analytics/telemetry_handler.ex lib/slackex_web/telemetry.ex test/slackex/analytics/telemetry_handler_test.exs
git commit -m "feat(analytics): add TelemetryHandler for LiveView and Oban exception tracking"
```

---

## Task 6: Client-Side analytics.js Hook

**Files:**
- Create: `assets/js/hooks/analytics.js`
- Modify: `assets/js/app.js` (register hook)

- [ ] **Step 1: Write the Analytics JS hook**

Create `assets/js/hooks/analytics.js`:

```javascript
const RATE_LIMIT_MS = 60_000;

const Analytics = {
  mounted() {
    if (this.el.dataset.analyticsEnabled !== "true") return;

    this._recentErrors = new Map();

    // JS error tracking
    this._errorHandler = (event) => {
      const key = `${event.message}:${event.filename}:${event.lineno}`;
      if (this._isRateLimited(key)) return;

      this.pushEvent("analytics:js_error", {
        message: event.message || "Unknown error",
        stack: event.error?.stack || "",
        url: event.filename || window.location.href,
        line: event.lineno || 0,
        column: event.colno || 0,
        user_agent: navigator.userAgent,
      });
    };

    this._rejectionHandler = (event) => {
      const message = event.reason?.message || String(event.reason);
      const key = `unhandled_rejection:${message}`;
      if (this._isRateLimited(key)) return;

      this.pushEvent("analytics:js_error", {
        message: message,
        stack: event.reason?.stack || "",
        url: window.location.href,
        line: 0,
        column: 0,
        user_agent: navigator.userAgent,
      });
    };

    window.addEventListener("error", this._errorHandler);
    window.addEventListener("unhandledrejection", this._rejectionHandler);

    // Click tracking (declarative via data-track)
    this._clickHandler = (event) => {
      const tracked = event.target.closest("[data-track]");
      if (!tracked) return;

      this.pushEvent("analytics:click", {
        target: tracked.dataset.track,
        context: tracked.dataset.trackContext || "",
        path: window.location.pathname,
      });
    };

    document.addEventListener("click", this._clickHandler, true);

    // Performance metrics (batched)
    this._perfEntries = [];
    this._perfInterval = setInterval(() => this._flushPerf(), 30_000);

    if (typeof PerformanceObserver !== "undefined") {
      try {
        this._lcpObserver = new PerformanceObserver((list) => {
          const entries = list.getEntries();
          const last = entries[entries.length - 1];
          if (last) {
            this._perfEntries.push({
              metric: "lcp",
              value: Math.round(last.startTime),
              path: window.location.pathname,
            });
          }
        });
        this._lcpObserver.observe({ type: "largest-contentful-paint", buffered: true });

        this._longTaskObserver = new PerformanceObserver((list) => {
          for (const entry of list.getEntries()) {
            this._perfEntries.push({
              metric: "long_task",
              value: Math.round(entry.duration),
              path: window.location.pathname,
            });
          }
        });
        this._longTaskObserver.observe({ type: "longtask", buffered: true });
      } catch (_e) {
        // PerformanceObserver types not supported in this browser
      }
    }
  },

  destroyed() {
    if (this._errorHandler) {
      window.removeEventListener("error", this._errorHandler);
      window.removeEventListener("unhandledrejection", this._rejectionHandler);
    }
    if (this._clickHandler) {
      document.removeEventListener("click", this._clickHandler, true);
    }
    if (this._perfInterval) {
      clearInterval(this._perfInterval);
      this._flushPerf();
    }
    if (this._lcpObserver) this._lcpObserver.disconnect();
    if (this._longTaskObserver) this._longTaskObserver.disconnect();
  },

  _isRateLimited(key) {
    const now = Date.now();
    const lastSeen = this._recentErrors.get(key);
    if (lastSeen && now - lastSeen < RATE_LIMIT_MS) return true;
    this._recentErrors.set(key, now);
    return false;
  },

  _flushPerf() {
    if (this._perfEntries.length === 0) return;
    const batch = this._perfEntries.splice(0);
    for (const entry of batch) {
      this.pushEvent("analytics:performance", entry);
    }
  },
};

export default Analytics;
```

- [ ] **Step 2: Register the hook in app.js**

In `assets/js/app.js`, import and register:

```javascript
import Analytics from "./hooks/analytics";
```

Add to the Hooks object:

```javascript
Hooks.Analytics = Analytics;
```

- [ ] **Step 3: Add the hook mount point to the root layout**

In the root layout template (likely `lib/slackex_web/components/layouts/root.html.heex`), add `data-analytics-enabled` to the app container element that wraps the LiveView:

```heex
<div id="app-container" phx-hook="Analytics" data-analytics-enabled={to_string(FunWithFlags.enabled?(:website_analytics))}>
```

If there's no suitable wrapper element, the `<body>` tag or the main content `<div>` can be used.

- [ ] **Step 4: Add server-side event handlers for client analytics events**

In `lib/slackex_web/live/chat_live/index.ex` (or a shared helper module), add handlers:

```elixir
def handle_event("analytics:" <> event_type, params, socket) do
  user = socket.assigns.current_user
  session_id = socket.assigns[:analytics_session_id]

  context = %{
    user_id: if(user, do: user.id),
    session_id: session_id,
    is_bot: Map.get(user || %{}, :is_bot, false),
    user: user
  }

  metadata = params |> Map.drop(["_target"])

  Slackex.Analytics.track(context, event_type, metadata)

  {:noreply, socket}
end
```

- [ ] **Step 5: Commit**

```bash
git add assets/js/hooks/analytics.js assets/js/app.js lib/slackex_web/components/layouts/root.html.heex lib/slackex_web/live/chat_live/index.ex
git commit -m "feat(analytics): add client-side JS hook for error, perf, and click tracking"
```

---

## Task 7: Query Functions

**Files:**
- Modify: `lib/slackex/analytics.ex` (add query functions)
- Test: `test/slackex/analytics_test.exs` (append query tests)

- [ ] **Step 1: Write query function tests**

Append to `test/slackex/analytics_test.exs`:

```elixir
describe "page_views/1" do
  test "returns page views grouped by path with counts" do
    user = insert(:user)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    insert(:analytics_event, event_type: "page_view", event_name: "page_view", user_id: user.id, metadata: %{"path" => "/chat/general"}, inserted_at: now)
    insert(:analytics_event, event_type: "page_view", event_name: "page_view", user_id: user.id, metadata: %{"path" => "/chat/general"}, inserted_at: now)
    insert(:analytics_event, event_type: "page_view", event_name: "page_view", user_id: user.id, metadata: %{"path" => "/chat/random"}, inserted_at: now)

    results = Slackex.Analytics.page_views(period: :last_7_days)
    general = Enum.find(results, &(&1.path == "/chat/general"))
    assert general.count == 2
    assert general.unique_users == 1
  end

  test "excludes reconnect events by default" do
    insert(:analytics_event, event_type: "page_view", event_name: "page_view", metadata: %{"path" => "/chat", "is_reconnect" => true})
    insert(:analytics_event, event_type: "page_view", event_name: "page_view", metadata: %{"path" => "/chat", "is_reconnect" => false})

    results = Slackex.Analytics.page_views(period: :last_7_days)
    chat = Enum.find(results, &(&1.path == "/chat"))
    assert chat.count == 1
  end
end

describe "feature_usage/1" do
  test "returns feature usage grouped by feature name" do
    user1 = insert(:user)
    user2 = insert(:user)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    insert(:analytics_event, event_type: "feature_used", event_name: "feature_used", user_id: user1.id, metadata: %{"feature" => "search"}, inserted_at: now)
    insert(:analytics_event, event_type: "feature_used", event_name: "feature_used", user_id: user2.id, metadata: %{"feature" => "search"}, inserted_at: now)
    insert(:analytics_event, event_type: "feature_used", event_name: "feature_used", user_id: user1.id, metadata: %{"feature" => "reactions"}, inserted_at: now)

    results = Slackex.Analytics.feature_usage(period: :last_30_days)
    search = Enum.find(results, &(&1.feature == "search"))
    assert search.count == 2
    assert search.unique_users == 2
  end
end

describe "errors/1" do
  test "returns errors grouped by message with counts" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    insert(:analytics_event, event_type: "js_error", event_category: "error", event_name: "js_error", metadata: %{"message" => "TypeError: null"}, inserted_at: now)
    insert(:analytics_event, event_type: "js_error", event_category: "error", event_name: "js_error", metadata: %{"message" => "TypeError: null"}, inserted_at: now)
    insert(:analytics_event, event_type: "server_error", event_category: "error", event_name: "server_error", metadata: %{"message" => "500 error"}, inserted_at: now)

    results = Slackex.Analytics.errors(period: :last_24_hours)
    type_error = Enum.find(results, &(&1.message == "TypeError: null"))
    assert type_error.count == 2

    js_only = Slackex.Analytics.errors(period: :last_24_hours, category: "js_error")
    assert length(js_only) == 1
  end
end

describe "slow_pages/1" do
  test "returns pages exceeding the duration threshold" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    insert(:analytics_event, event_type: "page_view", event_name: "page_view", metadata: %{"path" => "/chat/general", "duration_ms" => 600}, inserted_at: now)
    insert(:analytics_event, event_type: "page_view", event_name: "page_view", metadata: %{"path" => "/chat/general", "duration_ms" => 700}, inserted_at: now)
    insert(:analytics_event, event_type: "page_view", event_name: "page_view", metadata: %{"path" => "/chat/random", "duration_ms" => 100}, inserted_at: now)

    results = Slackex.Analytics.slow_pages(threshold_ms: 500, period: :last_7_days)
    assert length(results) == 1
    assert hd(results).path == "/chat/general"
    assert hd(results).avg_duration_ms == 650.0
  end
end

describe "hotspots/1" do
  test "returns pages ranked by composite score" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    # High-traffic page with errors
    for _ <- 1..10 do
      insert(:analytics_event, event_type: "page_view", event_name: "page_view", metadata: %{"path" => "/chat/general", "duration_ms" => 200}, inserted_at: now)
    end
    insert(:analytics_event, event_type: "js_error", event_category: "error", event_name: "js_error", metadata: %{"url" => "/chat/general"}, inserted_at: now)

    # Low-traffic page, no errors
    insert(:analytics_event, event_type: "page_view", event_name: "page_view", metadata: %{"path" => "/chat/random", "duration_ms" => 100}, inserted_at: now)

    results = Slackex.Analytics.hotspots(period: :last_7_days)
    assert length(results) >= 1
    assert hd(results).path == "/chat/general"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
mix test test/slackex/analytics_test.exs --only describe:"page_views/1" -v
```
Expected: FAIL — function `page_views/1` not defined.

- [ ] **Step 3: Add query functions to Analytics context**

Append to `lib/slackex/analytics.ex`:

```elixir
import Ecto.Query

alias Slackex.Analytics.Event
alias Slackex.Repo

@period_durations %{
  last_24_hours: 1,
  last_7_days: 7,
  last_30_days: 30,
  last_90_days: 90
}

def page_views(opts \\ []) do
  period = Keyword.get(opts, :period, :last_7_days)
  since = period_start(period)

  Event
  |> where([e], e.event_type == "page_view")
  |> where([e], e.inserted_at >= ^since)
  |> where([e], fragment("(?->>'is_reconnect')::text != 'true'", e.metadata))
  |> group_by([e], fragment("?->>'path'", e.metadata))
  |> select([e], %{
    path: fragment("?->>'path'", e.metadata),
    count: count(e.id),
    unique_users: count(e.user_id, :distinct)
  })
  |> order_by([e], desc: count(e.id))
  |> Repo.all()
end

def feature_usage(opts \\ []) do
  period = Keyword.get(opts, :period, :last_30_days)
  since = period_start(period)

  Event
  |> where([e], e.event_type == "feature_used")
  |> where([e], e.inserted_at >= ^since)
  |> group_by([e], fragment("?->>'feature'", e.metadata))
  |> select([e], %{
    feature: fragment("?->>'feature'", e.metadata),
    count: count(e.id),
    unique_users: count(e.user_id, :distinct)
  })
  |> order_by([e], desc: count(e.id))
  |> Repo.all()
end

def errors(opts \\ []) do
  period = Keyword.get(opts, :period, :last_24_hours)
  category = Keyword.get(opts, :category)
  since = period_start(period)

  query =
    Event
    |> where([e], e.event_category == "error")
    |> where([e], e.inserted_at >= ^since)

  query = if category, do: where(query, [e], e.event_type == ^category), else: query

  query
  |> group_by([e], fragment("?->>'message'", e.metadata))
  |> group_by([e], [e.event_type])
  |> select([e], %{
    message: fragment("?->>'message'", e.metadata),
    event_type: e.event_type,
    count: count(e.id),
    last_seen: max(e.inserted_at),
    affected_users: count(e.user_id, :distinct)
  })
  |> order_by([e], desc: count(e.id))
  |> Repo.all()
end

def slow_pages(opts \\ []) do
  period = Keyword.get(opts, :period, :last_7_days)
  threshold_ms = Keyword.get(opts, :threshold_ms, 500)
  since = period_start(period)

  Event
  |> where([e], e.event_type == "page_view")
  |> where([e], e.inserted_at >= ^since)
  |> where([e], fragment("(?->>'duration_ms')::int > 0", e.metadata))
  |> group_by([e], fragment("?->>'path'", e.metadata))
  |> having([e], fragment("avg((?->>'duration_ms')::int) >= ?", e.metadata, ^threshold_ms))
  |> select([e], %{
    path: fragment("?->>'path'", e.metadata),
    avg_duration_ms: fragment("avg((?->>'duration_ms')::int)::float", e.metadata),
    p95_ms: fragment("percentile_cont(0.95) within group (order by (?->>'duration_ms')::int)::float", e.metadata),
    count: count(e.id)
  })
  |> order_by([e], desc: fragment("avg((?->>'duration_ms')::int)", e.metadata))
  |> Repo.all()
end

def user_activity(user_id, opts \\ []) do
  period = Keyword.get(opts, :period, :last_30_days)
  since = period_start(period)

  Event
  |> where([e], e.user_id == ^user_id)
  |> where([e], e.inserted_at >= ^since)
  |> group_by([e], fragment("?::date", e.inserted_at))
  |> select([e], %{
    date: fragment("?::date", e.inserted_at),
    events: count(e.id),
    features_used: fragment("array_agg(distinct ?->>'feature') filter (where ?->>'feature' is not null)", e.metadata, e.metadata)
  })
  |> order_by([e], asc: fragment("?::date", e.inserted_at))
  |> Repo.all()
end

def hotspots(opts \\ []) do
  period = Keyword.get(opts, :period, :last_7_days)
  since = period_start(period)

  page_view_stats =
    Event
    |> where([e], e.event_type == "page_view")
    |> where([e], e.inserted_at >= ^since)
    |> group_by([e], fragment("?->>'path'", e.metadata))
    |> select([e], %{
      path: fragment("?->>'path'", e.metadata),
      visit_count: count(e.id),
      avg_duration_ms: fragment("coalesce(avg((?->>'duration_ms')::int), 0)::float", e.metadata)
    })
    |> Repo.all()

  error_counts =
    Event
    |> where([e], e.event_category == "error")
    |> where([e], e.inserted_at >= ^since)
    |> group_by([e], fragment("coalesce(?->>'path', ?->>'url')", e.metadata, e.metadata))
    |> select([e], %{
      path: fragment("coalesce(?->>'path', ?->>'url')", e.metadata, e.metadata),
      error_count: count(e.id)
    })
    |> Repo.all()
    |> Map.new(&{&1.path, &1.error_count})

  max_visits = page_view_stats |> Enum.map(& &1.visit_count) |> Enum.max(fn -> 1 end)
  max_duration = page_view_stats |> Enum.map(& &1.avg_duration_ms) |> Enum.max(fn -> 1.0 end)
  max_errors = error_counts |> Map.values() |> Enum.max(fn -> 1 end)

  page_view_stats
  |> Enum.map(fn stat ->
    errors = Map.get(error_counts, stat.path, 0)

    score =
      (stat.visit_count / max(max_visits, 1)) * 0.4 +
      (stat.avg_duration_ms / max(max_duration, 1.0)) * 0.3 +
      (errors / max(max_errors, 1)) * 0.3

    %{
      path: stat.path,
      visit_count: stat.visit_count,
      avg_duration_ms: stat.avg_duration_ms,
      error_count: errors,
      score: Float.round(score, 3)
    }
  end)
  |> Enum.sort_by(& &1.score, :desc)
end

def active_user_count(opts \\ []) do
  period = Keyword.get(opts, :period, :last_24_hours)
  since = period_start(period)

  Event
  |> where([e], not is_nil(e.user_id))
  |> where([e], e.inserted_at >= ^since)
  |> select([e], count(e.user_id, :distinct))
  |> Repo.one()
end

defp period_start(period) do
  days = Map.get(@period_durations, period, 7)
  DateTime.utc_now()
  |> DateTime.add(-days * 86_400, :second)
  |> DateTime.truncate(:microsecond)
end
```

- [ ] **Step 4: Run all query tests**

Run:
```bash
mix test test/slackex/analytics_test.exs -v
```
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/slackex/analytics.ex test/slackex/analytics_test.exs
git commit -m "feat(analytics): add query functions for page views, features, errors, hotspots"
```

---

## Task 8: MetricsBridge and PruneWorker

**Files:**
- Create: `lib/slackex/analytics/metrics_bridge.ex`
- Create: `lib/slackex/analytics/prune_worker.ex`
- Modify: `config/config.exs` (add cron entries)
- Test: `test/slackex/analytics/prune_worker_test.exs`

- [ ] **Step 1: Write the PruneWorker test**

Create `test/slackex/analytics/prune_worker_test.exs`:

```elixir
defmodule Slackex.Analytics.PruneWorkerTest do
  use Slackex.DataCase, async: true
  use Oban.Testing, repo: Slackex.Repo

  alias Slackex.Analytics.PruneWorker
  alias Slackex.Analytics.Event
  alias Slackex.Repo

  test "deletes events older than 90 days" do
    old = DateTime.utc_now() |> DateTime.add(-91 * 86_400, :second) |> DateTime.truncate(:microsecond)
    recent = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    insert(:analytics_event, inserted_at: old)
    insert(:analytics_event, inserted_at: recent)

    assert :ok = perform_job(PruneWorker, %{})

    events = Repo.all(Event)
    assert length(events) == 1
    assert hd(events).inserted_at == recent
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
mix test test/slackex/analytics/prune_worker_test.exs -v
```
Expected: FAIL — `PruneWorker` not found.

- [ ] **Step 3: Write PruneWorker**

Create `lib/slackex/analytics/prune_worker.ex`:

```elixir
defmodule Slackex.Analytics.PruneWorker do
  use Oban.Worker, queue: :analytics, max_attempts: 1

  import Ecto.Query
  alias Slackex.Analytics.Event
  alias Slackex.Repo

  @default_retention_days 90

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    retention_days = Application.get_env(:slackex, Slackex.Analytics)[:retention_days] || @default_retention_days
    cutoff = DateTime.utc_now() |> DateTime.add(-retention_days * 86_400, :second) |> DateTime.truncate(:microsecond)

    {deleted, _} =
      Event
      |> where([e], e.inserted_at < ^cutoff)
      |> Repo.delete_all()

    if deleted > 0 do
      require Logger
      Logger.info("Analytics: pruned #{deleted} events older than #{retention_days} days")
    end

    :ok
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
mix test test/slackex/analytics/prune_worker_test.exs -v
```
Expected: 1 test passes.

- [ ] **Step 5: Write MetricsBridge**

Create `lib/slackex/analytics/metrics_bridge.ex`:

```elixir
defmodule Slackex.Analytics.MetricsBridge do
  @moduledoc """
  Oban cron job that queries analytics aggregates and emits them as
  telemetry events for Prometheus scraping. Runs with Oban unique
  constraint to ensure single-node execution in multi-node deploys.
  """

  use Oban.Worker, queue: :analytics, max_attempts: 1, unique: [period: 55]

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if FunWithFlags.enabled?(:website_analytics) do
      emit_page_view_metrics()
      emit_error_metrics()
      emit_feature_usage_metrics()
      emit_active_user_metrics()
    end

    :ok
  end

  defp emit_page_view_metrics do
    Slackex.Analytics.page_views(period: :last_24_hours)
    |> Enum.each(fn %{path: path, count: count} ->
      :telemetry.execute(
        [:tenun, :analytics, :page_views],
        %{count: count},
        %{path: path}
      )
    end)
  end

  defp emit_error_metrics do
    for category <- ~w(js_error server_error oban_error) do
      count =
        Slackex.Analytics.errors(period: :last_24_hours, category: category)
        |> Enum.map(& &1.count)
        |> Enum.sum()

      :telemetry.execute(
        [:tenun, :analytics, :errors],
        %{count: count},
        %{category: category}
      )
    end
  end

  defp emit_feature_usage_metrics do
    Slackex.Analytics.feature_usage(period: :last_24_hours)
    |> Enum.each(fn %{feature: feature, count: count} ->
      :telemetry.execute(
        [:tenun, :analytics, :feature_usage],
        %{count: count},
        %{feature: feature}
      )
    end)
  end

  defp emit_active_user_metrics do
    count = Slackex.Analytics.active_user_count(period: :last_24_hours)

    :telemetry.execute(
      [:tenun, :analytics, :active_users],
      %{count: count},
      %{}
    )
  end
end
```

- [ ] **Step 6: Add cron entries to config**

In `config/config.exs`, add to the Oban cron list:

```elixir
{"0 3 * * *", Slackex.Analytics.PruneWorker},
{"* * * * *", Slackex.Analytics.MetricsBridge}
```

- [ ] **Step 7: Register telemetry metrics in telemetry.ex**

In `lib/slackex_web/telemetry.ex`, add these metric definitions to the list. **Important: verify the exact API against TelemetryMetricsPrometheus.Core docs before implementation — metric names and types must match what the library actually exports.**

```elixir
Telemetry.Metrics.last_value("tenun.analytics.page_views", tags: [:path]),
Telemetry.Metrics.last_value("tenun.analytics.errors", tags: [:category]),
Telemetry.Metrics.last_value("tenun.analytics.feature_usage", tags: [:feature]),
Telemetry.Metrics.last_value("tenun.analytics.active_users")
```

- [ ] **Step 8: Commit**

```bash
git add lib/slackex/analytics/prune_worker.ex lib/slackex/analytics/metrics_bridge.ex config/config.exs lib/slackex_web/telemetry.ex test/slackex/analytics/prune_worker_test.exs
git commit -m "feat(analytics): add PruneWorker (90-day retention) and MetricsBridge (Prometheus export)"
```

---

## Task 9: Admin UI — Routing and Overview Tab

**Files:**
- Create: `lib/slackex_web/live/admin_live/analytics.ex`
- Create: `lib/slackex_web/live/admin_live/analytics.html.heex`
- Modify: `lib/slackex_web/router.ex` (add admin analytics routes)
- Test: `test/slackex_web/live/admin_live/analytics_test.exs`

- [ ] **Step 1: Add admin analytics routes**

In `lib/slackex_web/router.ex`, add after the existing `/admin/flags` scope:

```elixir
scope "/admin/analytics" do
  pipe_through [:browser, :admin_flags_auth]

  live_session :admin_analytics do
    live "/", SlackexWeb.AdminLive.Analytics, :overview
    live "/hotspots", SlackexWeb.AdminLive.Analytics, :hotspots
    live "/errors", SlackexWeb.AdminLive.Analytics, :errors
    live "/features", SlackexWeb.AdminLive.Analytics, :features
  end
end
```

- [ ] **Step 2: Write the admin analytics test**

Create `test/slackex_web/live/admin_live/analytics_test.exs`:

```elixir
defmodule SlackexWeb.AdminLive.AnalyticsTest do
  use SlackexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup do
    FunWithFlags.enable(:website_analytics)
    on_exit(fn -> FunWithFlags.disable(:website_analytics) end)
    :ok
  end

  describe "overview tab" do
    test "renders analytics overview when flag is enabled", %{conn: conn} do
      conn = auth_admin(conn)
      {:ok, view, html} = live(conn, "/admin/analytics")

      assert html =~ "Analytics"
      assert html =~ "Active Users"
      assert html =~ "Page Views"
      assert html =~ "Errors"
    end

    test "shows disabled message when flag is off", %{conn: conn} do
      FunWithFlags.disable(:website_analytics)
      conn = auth_admin(conn)
      {:ok, _view, html} = live(conn, "/admin/analytics")

      assert html =~ "Analytics disabled"
    end
  end

  describe "tab navigation" do
    test "can navigate between tabs", %{conn: conn} do
      conn = auth_admin(conn)
      {:ok, view, _html} = live(conn, "/admin/analytics")

      {:ok, view, html} = view |> element("a", "Hotspots") |> render_click() |> follow_redirect(conn)
      assert html =~ "Hotspots"

      {:ok, view, html} = view |> element("a", "Errors") |> render_click() |> follow_redirect(conn)
      assert html =~ "Errors"

      {:ok, _view, html} = view |> element("a", "Features") |> render_click() |> follow_redirect(conn)
      assert html =~ "Feature Adoption"
    end
  end

  defp auth_admin(conn) do
    config = Application.fetch_env!(:slackex, :flags_admin_auth)
    credentials = Base.encode64("#{config[:username]}:#{config[:password]}")

    conn
    |> put_req_header("authorization", "Basic #{credentials}")
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run:
```bash
mix test test/slackex_web/live/admin_live/analytics_test.exs -v
```
Expected: FAIL — module not found.

- [ ] **Step 4: Write the AdminLive.Analytics LiveView**

Create `lib/slackex_web/live/admin_live/analytics.ex`:

```elixir
defmodule SlackexWeb.AdminLive.Analytics do
  use SlackexWeb, :live_view

  alias Slackex.Analytics

  @tabs [
    {:overview, "Overview", ~p"/admin/analytics"},
    {:hotspots, "Hotspots", ~p"/admin/analytics/hotspots"},
    {:errors, "Errors", ~p"/admin/analytics/errors"},
    {:features, "Features", ~p"/admin/analytics/features"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    enabled = FunWithFlags.enabled?(:website_analytics)

    socket =
      socket
      |> assign(:enabled, enabled)
      |> assign(:tabs, @tabs)
      |> assign(:period, :last_7_days)

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_tab_data(socket)}
  end

  @impl true
  def handle_event("change_period", %{"period" => period}, socket) do
    period = String.to_existing_atom(period)
    socket = socket |> assign(:period, period) |> load_tab_data()
    {:noreply, socket}
  end

  defp load_tab_data(%{assigns: %{enabled: false}} = socket) do
    socket
  end

  defp load_tab_data(%{assigns: %{live_action: :overview, period: period}} = socket) do
    socket
    |> assign(:active_today, Analytics.active_user_count(period: :last_24_hours))
    |> assign(:active_7d, Analytics.active_user_count(period: :last_7_days))
    |> assign(:active_30d, Analytics.active_user_count(period: :last_30_days))
    |> assign(:page_views, Analytics.page_views(period: period) |> Enum.take(10))
    |> assign(:error_count, Analytics.errors(period: period) |> Enum.map(& &1.count) |> Enum.sum())
    |> assign(:top_features, Analytics.feature_usage(period: period) |> Enum.take(10))
  end

  defp load_tab_data(%{assigns: %{live_action: :hotspots, period: period}} = socket) do
    assign(socket, :hotspots, Analytics.hotspots(period: period))
  end

  defp load_tab_data(%{assigns: %{live_action: :errors, period: period}} = socket) do
    assign(socket, :errors, Analytics.errors(period: period))
  end

  defp load_tab_data(%{assigns: %{live_action: :features, period: period}} = socket) do
    assign(socket, :features, Analytics.feature_usage(period: period))
  end
end
```

- [ ] **Step 5: Write the admin analytics template**

Create `lib/slackex_web/live/admin_live/analytics.html.heex`:

```heex
<div class="min-h-screen bg-base-200 p-6">
  <h1 class="text-2xl font-bold mb-6">Analytics</h1>

  <%= if not @enabled do %>
    <div class="alert alert-warning">Analytics disabled. Enable the <code>:website_analytics</code> feature flag to start collecting data.</div>
  <% else %>
    <%!-- Tab navigation --%>
    <div class="tabs tabs-boxed mb-6">
      <%= for {action, label, path} <- @tabs do %>
        <.link navigate={path} class={"tab #{if @live_action == action, do: "tab-active"}"}>
          <%= label %>
        </.link>
      <% end %>
    </div>

    <%!-- Period selector --%>
    <div class="flex justify-end mb-4">
      <select name="period" phx-change="change_period" class="select select-sm select-bordered">
        <option value="last_24_hours" selected={@period == :last_24_hours}>Last 24 hours</option>
        <option value="last_7_days" selected={@period == :last_7_days}>Last 7 days</option>
        <option value="last_30_days" selected={@period == :last_30_days}>Last 30 days</option>
        <option value="last_90_days" selected={@period == :last_90_days}>Last 90 days</option>
      </select>
    </div>

    <%!-- Tab content --%>
    <%= case @live_action do %>
      <% :overview -> %>
        <div class="grid grid-cols-1 md:grid-cols-4 gap-4 mb-6">
          <div class="stat bg-base-100 rounded-lg shadow">
            <div class="stat-title">Active Users (24h)</div>
            <div class="stat-value"><%= @active_today %></div>
          </div>
          <div class="stat bg-base-100 rounded-lg shadow">
            <div class="stat-title">Active Users (7d)</div>
            <div class="stat-value"><%= @active_7d %></div>
          </div>
          <div class="stat bg-base-100 rounded-lg shadow">
            <div class="stat-title">Active Users (30d)</div>
            <div class="stat-value"><%= @active_30d %></div>
          </div>
          <div class="stat bg-base-100 rounded-lg shadow">
            <div class="stat-title">Errors</div>
            <div class="stat-value text-error"><%= @error_count %></div>
          </div>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <div class="bg-base-100 rounded-lg shadow p-4">
            <h3 class="font-semibold mb-3">Top Pages</h3>
            <table class="table table-sm">
              <thead><tr><th>Path</th><th>Views</th><th>Users</th></tr></thead>
              <tbody>
                <%= for pv <- @page_views do %>
                  <tr><td class="font-mono text-sm"><%= pv.path %></td><td><%= pv.count %></td><td><%= pv.unique_users %></td></tr>
                <% end %>
              </tbody>
            </table>
          </div>
          <div class="bg-base-100 rounded-lg shadow p-4">
            <h3 class="font-semibold mb-3">Top Features</h3>
            <table class="table table-sm">
              <thead><tr><th>Feature</th><th>Uses</th><th>Users</th></tr></thead>
              <tbody>
                <%= for f <- @top_features do %>
                  <tr><td><%= f.feature %></td><td><%= f.count %></td><td><%= f.unique_users %></td></tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>

      <% :hotspots -> %>
        <div class="bg-base-100 rounded-lg shadow p-4">
          <h3 class="font-semibold mb-3">Hotspots</h3>
          <table class="table">
            <thead><tr><th>Path</th><th>Visits</th><th>Avg Load (ms)</th><th>Errors</th><th>Score</th></tr></thead>
            <tbody>
              <%= for h <- @hotspots do %>
                <tr>
                  <td class="font-mono text-sm"><%= h.path %></td>
                  <td><%= h.visit_count %></td>
                  <td><%= round(h.avg_duration_ms) %></td>
                  <td class={if h.error_count > 0, do: "text-error font-bold"}><%= h.error_count %></td>
                  <td><%= h.score %></td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>

      <% :errors -> %>
        <div class="bg-base-100 rounded-lg shadow p-4">
          <h3 class="font-semibold mb-3">Errors</h3>
          <table class="table">
            <thead><tr><th>Message</th><th>Type</th><th>Count</th><th>Last Seen</th><th>Users</th></tr></thead>
            <tbody>
              <%= for e <- @errors do %>
                <tr>
                  <td class="font-mono text-sm max-w-md truncate"><%= e.message %></td>
                  <td><span class="badge badge-sm"><%= e.event_type %></span></td>
                  <td class="font-bold"><%= e.count %></td>
                  <td><%= if e.last_seen, do: Calendar.strftime(e.last_seen, "%Y-%m-%d %H:%M") %></td>
                  <td><%= e.affected_users %></td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>

      <% :features -> %>
        <div class="bg-base-100 rounded-lg shadow p-4">
          <h3 class="font-semibold mb-3">Feature Adoption</h3>
          <table class="table">
            <thead><tr><th>Feature</th><th>Total Uses</th><th>Unique Users</th></tr></thead>
            <tbody>
              <%= for f <- @features do %>
                <tr>
                  <td><%= f.feature %></td>
                  <td><%= f.count %></td>
                  <td><%= f.unique_users %></td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
    <% end %>
  <% end %>
</div>
```

- [ ] **Step 6: Run tests**

Run:
```bash
mix test test/slackex_web/live/admin_live/analytics_test.exs -v
```
Expected: Tests pass (may need adjustments based on exact auth pattern).

- [ ] **Step 7: Commit**

```bash
git add lib/slackex_web/live/admin_live/analytics.ex lib/slackex_web/live/admin_live/analytics.html.heex lib/slackex_web/router.ex test/slackex_web/live/admin_live/analytics_test.exs
git commit -m "feat(analytics): add admin analytics LiveView with overview, hotspots, errors, and features tabs"
```

---

## Task 10: Grafana Dashboard

**Files:**
- Create: `infra/grafana/dashboards/tenun-analytics.json`

- [ ] **Step 1: Create the Grafana dashboard JSON**

Create `infra/grafana/dashboards/tenun-analytics.json`. This is a Grafana provisioned dashboard with panels for:
- Error rate over time (time series, by category)
- Slowest pages p95 (table)
- Feature adoption trend (stat panel)
- Active users (stat panel)
- Error log (table)

The dashboard should reference the Prometheus datasource UID used by the existing `slackex-overview.json` dashboard. Check the existing dashboard's datasource UID:

```bash
grep -o '"uid":"[^"]*"' infra/grafana/dashboards/slackex-overview.json | head -1
```

Use the same UID in the new dashboard. The PromQL queries must use the exact metric names exported by TelemetryMetricsPrometheus.Core — verify against the contract tests (Task 11) before finalizing.

- [ ] **Step 2: Add alerting rule**

In the dashboard JSON, add an alert panel or configure a Grafana alert rule (depending on your Grafana version — v9+ uses unified alerting):

Alert: `tenun.analytics.errors` exceeds 10 in 15 minutes → fire notification.

- [ ] **Step 3: Commit**

```bash
git add infra/grafana/dashboards/tenun-analytics.json
git commit -m "feat(analytics): add Grafana analytics dashboard with error alerting"
```

---

## Task 11: Integration and Contract Tests

**Files:**
- Create: `test/slackex/analytics/integration_test.exs`
- Create: `test/slackex/analytics/contract_test.exs`

- [ ] **Step 1: Write the full pipeline integration test**

Create `test/slackex/analytics/integration_test.exs`:

```elixir
defmodule Slackex.Analytics.IntegrationTest do
  use Slackex.DataCase, async: true
  use Oban.Testing, repo: Slackex.Repo

  alias Slackex.Analytics
  alias Slackex.Analytics.Event
  alias Slackex.Repo

  setup do
    FunWithFlags.enable(:website_analytics)
    on_exit(fn -> FunWithFlags.disable(:website_analytics) end)
    :ok
  end

  test "full pipeline: track → Oban job → DB row → query returns it" do
    user = insert(:user)

    # 1. Track an event
    Analytics.track(
      %{user_id: user.id, session_id: "integration-test-session"},
      "feature_used",
      %{feature: "search", query_type: "hybrid"}
    )

    # 2. Assert job was enqueued
    assert_enqueued(worker: Slackex.Analytics.TrackWorker)

    # 3. Drain the queue (execute the job)
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :analytics)

    # 4. Verify row in DB
    event = Repo.one!(Event)
    assert event.event_type == "feature_used"
    assert event.user_id == user.id
    assert event.metadata["feature"] == "search"

    # 5. Verify query function returns it
    results = Analytics.feature_usage(period: :last_24_hours)
    assert [%{feature: "search", count: 1, unique_users: 1}] = results
  end

  test "bot users are excluded from the pipeline" do
    bot = insert(:user, is_bot: true)

    Analytics.track(
      %{user_id: bot.id, session_id: "bot-session", is_bot: true},
      "page_view",
      %{path: "/chat"}
    )

    refute_enqueued(worker: Slackex.Analytics.TrackWorker)
  end

  test "events are excluded when flag is disabled" do
    FunWithFlags.disable(:website_analytics)

    Analytics.track(
      %{user_id: 1, session_id: "disabled-session"},
      "page_view",
      %{path: "/chat"}
    )

    refute_enqueued(worker: Slackex.Analytics.TrackWorker)
  end
end
```

- [ ] **Step 2: Run integration test**

Run:
```bash
mix test test/slackex/analytics/integration_test.exs -v
```
Expected: 3 tests pass.

- [ ] **Step 3: Write contract tests for Prometheus metric names**

Create `test/slackex/analytics/contract_test.exs`:

```elixir
defmodule Slackex.Analytics.ContractTest do
  @moduledoc """
  Contract tests verifying that Prometheus metric names emitted by
  MetricsBridge match the names expected in Grafana dashboard PromQL queries.

  If these tests break, the Grafana dashboard will show blank panels.
  """

  use Slackex.DataCase, async: true

  test "analytics telemetry metric definitions exist in telemetry.ex metrics list" do
    # The metrics defined in telemetry.ex are the contract between
    # MetricsBridge (emitter) and Prometheus/Grafana (consumer).
    # This test verifies the metric names are registered.
    metrics = SlackexWeb.Telemetry.metrics()

    metric_names = Enum.map(metrics, & &1.name)

    # These are the logical telemetry event names that MetricsBridge emits.
    # TelemetryMetricsPrometheus.Core translates them to Prometheus format.
    assert [:tenun, :analytics, :page_views] in metric_names
    assert [:tenun, :analytics, :errors] in metric_names
    assert [:tenun, :analytics, :feature_usage] in metric_names
    assert [:tenun, :analytics, :active_users] in metric_names
  end
end
```

Note: The exact metric name atoms depend on how `Telemetry.Metrics.last_value/2` constructs the name from the string. During implementation, verify the actual name format by reading the TelemetryMetricsPrometheus.Core source or docs. The contract test MUST assert on the real exported name.

- [ ] **Step 4: Run contract test**

Run:
```bash
mix test test/slackex/analytics/contract_test.exs -v
```
Expected: 1 test passes.

- [ ] **Step 5: Run the full test suite**

Run:
```bash
mix test
```
Expected: All tests pass, including existing tests (no regressions).

- [ ] **Step 6: Commit**

```bash
git add test/slackex/analytics/integration_test.exs test/slackex/analytics/contract_test.exs
git commit -m "test(analytics): add full pipeline integration test and Prometheus metric contract tests"
```

---

## Task 12: Feature Flag Instrumentation and Final Wiring

**Files:**
- Modify: `lib/slackex_web/live/chat_live/index.ex` (add feature usage tracking calls)

- [ ] **Step 1: Add Analytics.track calls to key feature handlers**

In `lib/slackex_web/live/chat_live/index.ex`, add tracking calls at the feature interaction points. These are the feature-flagged features that need usage tracking:

```elixir
# In the search handler (wherever search is triggered)
# After the search logic:
Analytics.track(
  %{user_id: socket.assigns.current_user.id, session_id: socket.assigns[:analytics_session_id], user: socket.assigns.current_user},
  "feature_used",
  %{feature: "search", query_type: search_mode}
)

# In the reactions handler:
Analytics.track(
  %{user_id: socket.assigns.current_user.id, session_id: socket.assigns[:analytics_session_id], user: socket.assigns.current_user},
  "feature_used",
  %{feature: "reactions", action: "add"}
)

# In the thread open handler:
Analytics.track(
  %{user_id: socket.assigns.current_user.id, session_id: socket.assigns[:analytics_session_id], user: socket.assigns.current_user},
  "feature_used",
  %{feature: "threads", action: "open"}
)
```

Add similar calls for: summarization, link previews, quick switcher, markdown toggle. Each call follows the same pattern — identify the `handle_event` clause for the feature and add `Analytics.track` after the feature logic.

To reduce boilerplate, extract a helper:

```elixir
defp track_feature(socket, feature, metadata \\ %{}) do
  user = socket.assigns.current_user
  Slackex.Analytics.track(
    %{
      user_id: user.id,
      session_id: socket.assigns[:analytics_session_id],
      user: user
    },
    "feature_used",
    Map.put(metadata, :feature, feature)
  )
end
```

- [ ] **Step 2: Add `data-track` attributes to key UI elements**

In the relevant HEEx templates, add `data-track` to important buttons:

```heex
<button phx-click="send_message" data-track="send_message" data-track-context="channel">Send</button>
<button phx-click="toggle_search" data-track="search_toggle">Search</button>
```

- [ ] **Step 3: Run full test suite to verify no regressions**

Run:
```bash
mix test
```
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add lib/slackex_web/live/chat_live/index.ex
git commit -m "feat(analytics): instrument feature-flagged features with usage tracking"
```

---

## Post-Implementation Checklist

After all tasks are complete:

- [ ] Enable `:website_analytics` flag: `FunWithFlags.enable(:website_analytics)`
- [ ] Verify events appear in the database: `Slackex.Repo.aggregate(Slackex.Analytics.Event, :count)`
- [ ] Visit `/admin/analytics` and confirm data renders
- [ ] Check Grafana dashboard receives metrics (may take 60s for MetricsBridge to run)
- [ ] Set `:exclude_from_analytics` on admin users if desired
- [ ] Verify Grafana alert rule fires correctly (trigger test errors, check alert state)
