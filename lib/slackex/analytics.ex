defmodule Slackex.Analytics do
  @moduledoc """
  Analytics context for tracking user and system events.

  Provides `track/3` for fire-and-forget event recording. Events are
  validated and persisted asynchronously via `TrackWorker` on the
  `:analytics` Oban queue.

  Tracking is gated by the `:website_analytics` feature flag. Bot users
  and users with the `:exclude_from_analytics` per-actor flag are silently
  skipped.
  """

  use Boundary,
    deps: [Slackex.Infrastructure],
    exports: [MetricsBridge, PruneWorker, TelemetryHandler]

  import Ecto.Query
  alias Slackex.Analytics.Event
  alias Slackex.Analytics.TrackWorker
  alias Slackex.Repo

  @period_durations %{
    last_24_hours: 1,
    last_7_days: 7,
    last_30_days: 30,
    last_90_days: 90
  }

  @category_map %{
    "page_view" => "product",
    "feature_used" => "product",
    "click" => "product",
    "js_error" => "error",
    "server_error" => "error",
    "oban_error" => "error",
    "performance" => "performance"
  }

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
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  def page_views(opts \\ []) do
    period = Keyword.get(opts, :period, :last_7_days)
    since = period_start(period)

    Event
    |> where([e], e.event_type == "page_view")
    |> where([e], e.inserted_at >= ^since)
    |> where(
      [e],
      fragment(
        "(?->>'is_reconnect') IS NULL OR (?->>'is_reconnect')::text != 'true'",
        e.metadata,
        e.metadata
      )
    )
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
    |> group_by([e], [fragment("?->>'message'", e.metadata), e.event_type])
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
      p95_ms:
        fragment(
          "percentile_cont(0.95) within group (order by (?->>'duration_ms')::int)::float",
          e.metadata
        ),
      count: count(e.id)
    })
    |> order_by([e], desc: fragment("avg((?->>'duration_ms')::int)", e.metadata))
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
        stat.visit_count / max(max_visits, 1) * 0.4 +
          stat.avg_duration_ms / max(max_duration, 1.0) * 0.3 +
          errors / max(max_errors, 1) * 0.3

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
end
