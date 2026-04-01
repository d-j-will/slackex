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
end
