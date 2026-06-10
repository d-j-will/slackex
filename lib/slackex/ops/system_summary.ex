defmodule Slackex.Ops.SystemSummary do
  @moduledoc """
  Builds the low-sensitivity operational snapshot exposed through MCP.
  """

  use Boundary, deps: [Slackex.Messaging, Slackex.Notifications], exports: []

  require Logger

  alias Slackex.Notifications.OnlineTracker

  @queue_names [:default, :notifications, :embeddings, :link_previews]

  @type snapshot :: %{
          String.t() => String.t() | non_neg_integer() | map() | nil
        }

  @spec snapshot() :: snapshot()
  def snapshot do
    {channel_count, channel_error} = active_channel_servers()
    {online_count, online_error} = online_users_count()
    {queue_counts, queue_error} = queue_running_counts()

    %{
      "generated_at" => generated_at(),
      "node" => node() |> to_string(),
      "active_channel_servers" => channel_count,
      "online_users_count" => online_count,
      "queue_running_counts" => queue_counts,
      "partial_failures" => %{
        "active_channel_servers" => channel_error,
        "online_users" => online_error,
        "queues" => queue_error
      }
    }
  end

  defp generated_at do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp active_channel_servers do
    case active_channel_server_provider().channel_count() do
      count when is_integer(count) and count >= 0 ->
        {count, nil}

      _ ->
        channel_server_fallback()
    end
  rescue
    _ -> channel_server_fallback()
  catch
    _, _ -> channel_server_fallback()
  end

  defp online_users_count do
    case online_provider().count() do
      count when is_integer(count) and count >= 0 ->
        {count, nil}

      _ ->
        online_fallback()
    end
  rescue
    _ -> online_fallback()
  catch
    _, _ -> online_fallback()
  end

  defp queue_running_counts do
    Enum.reduce_while(@queue_names, {%{}, nil}, fn queue, {counts, _error} ->
      case queue_provider().check_queue(queue) do
        %{running: running} when is_list(running) ->
          {:cont, {Map.put(counts, Atom.to_string(queue), length(running)), nil}}

        _ ->
          {:halt, queues_fallback(queue)}
      end
    end)
  rescue
    _ -> queues_fallback()
  catch
    _, _ -> queues_fallback()
  end

  defp channel_server_fallback do
    log_probe_failure(:active_channel_servers, "channel_server_probe_failed")
    {0, "channel_server_probe_failed"}
  end

  defp online_fallback do
    log_probe_failure(:online_users, "online_probe_failed")
    {0, "online_probe_failed"}
  end

  defp queues_fallback(queue \\ nil) do
    metadata = if is_nil(queue), do: [], else: [queue: queue]
    log_probe_failure(:queues, "queue_probe_failed", metadata)
    {zero_queue_counts(), "queue_probe_failed"}
  end

  defp zero_queue_counts do
    Map.new(@queue_names, fn queue -> {Atom.to_string(queue), 0} end)
  end

  defp log_probe_failure(probe, code, metadata \\ []) do
    details =
      metadata
      |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{value}" end)

    suffix = if details == "", do: "", else: " #{details}"

    Logger.warning("ops_snapshot_probe_failed probe=#{probe} code=#{code}#{suffix}")
  end

  defp active_channel_server_provider do
    Application.get_env(:slackex, __MODULE__, [])
    |> Keyword.get(:active_channel_server_provider, __MODULE__.ActiveChannelServerProvider)
  end

  defp online_provider do
    Application.get_env(:slackex, __MODULE__, [])
    |> Keyword.get(:online_provider, __MODULE__.OnlineProvider)
  end

  defp queue_provider do
    Application.get_env(:slackex, __MODULE__, [])
    |> Keyword.get(:queue_provider, __MODULE__.QueueProvider)
  end

  defmodule ActiveChannelServerProvider do
    @moduledoc false

    def channel_count, do: Slackex.Messaging.channel_count()
  end

  defmodule OnlineProvider do
    @moduledoc false

    def count, do: OnlineTracker.count_online()
  end

  defmodule QueueProvider do
    @moduledoc false

    def check_queue(queue), do: Oban.check_queue(queue: queue)
  end
end
