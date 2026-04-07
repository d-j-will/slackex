defmodule SlackexWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics
  require Logger

  alias Slackex.Analytics.TelemetryHandler

  @queue_names [:default, :notifications, :embeddings, :link_previews]

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    :ok = TelemetryHandler.attach()

    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000},
      {TelemetryMetricsPrometheus.Core, metrics: metrics(), name: :slackex_metrics}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Histogram buckets for HTTP request durations (milliseconds)
  @duration_buckets [5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000]
  # Histogram buckets for database query durations (milliseconds)
  @db_duration_buckets [1, 5, 10, 25, 50, 100, 250, 500, 1_000]

  def metrics do
    [
      # Phoenix Metrics
      distribution("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond},
        reporter_options: [buckets: @duration_buckets]
      ),
      distribution("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond},
        reporter_options: [buckets: @duration_buckets]
      ),
      distribution("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond},
        reporter_options: [buckets: @duration_buckets]
      ),
      distribution("phoenix.socket_connected.duration",
        unit: {:native, :millisecond},
        reporter_options: [buckets: @duration_buckets]
      ),
      sum("phoenix.socket_drain.count"),
      distribution("phoenix.channel_joined.duration",
        unit: {:native, :millisecond},
        reporter_options: [buckets: @duration_buckets]
      ),
      distribution("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond},
        reporter_options: [buckets: @duration_buckets]
      ),

      # Database Metrics
      distribution("slackex.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements",
        reporter_options: [buckets: @db_duration_buckets]
      ),
      distribution("slackex.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database",
        reporter_options: [buckets: @db_duration_buckets]
      ),
      distribution("slackex.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query",
        reporter_options: [buckets: @db_duration_buckets]
      ),
      distribution("slackex.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection",
        reporter_options: [buckets: @db_duration_buckets]
      ),
      distribution("slackex.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query",
        reporter_options: [buckets: @db_duration_buckets]
      ),

      # VM Metrics
      last_value("vm.memory.total", unit: :byte),
      last_value("vm.memory.processes", unit: :byte),
      last_value("vm.memory.binary", unit: :byte),
      last_value("vm.memory.ets", unit: :byte),
      last_value("vm.memory.atom", unit: :byte),
      last_value("vm.system_counts.process_count"),
      last_value("vm.system_counts.port_count"),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io"),

      # Application Metrics
      last_value("slackex.oban.queue_depth.running", tags: [:queue]),
      last_value("slackex.oban.queue_depth.available", tags: [:queue]),
      last_value("slackex.presence.connected_users.count"),

      # Analytics Metrics
      last_value("tenun.analytics.page_views.count", tags: [:path]),
      last_value("tenun.analytics.errors.count", tags: [:category]),
      last_value("tenun.analytics.feature_usage.count", tags: [:feature]),
      last_value("tenun.analytics.active_users.count")
    ]
  end

  defp periodic_measurements do
    [
      {__MODULE__, :measure_oban_queue_depth, []},
      {__MODULE__, :measure_connected_users, []}
    ]
  end

  @doc false
  def measure_oban_queue_depth do
    Enum.each(@queue_names, &publish_queue_depth/1)
  end

  @doc false
  def measure_connected_users do
    count =
      case connected_users_count() do
        {:ok, count} ->
          count

        {:error, code} ->
          log_probe_failure(:presence, code)
          0
      end

    :telemetry.execute([:slackex, :presence, :connected_users], %{count: count}, %{})
  end

  defp publish_queue_depth(queue) do
    running_count =
      case queue_running_count(queue) do
        {:ok, count} ->
          count

        {:error, code} ->
          log_probe_failure(:queue, code, queue: queue)
          0
      end

    available_count =
      case queue_available_count(queue) do
        {:ok, count} ->
          count

        {:error, code} ->
          log_probe_failure(:queue_available, code, queue: queue)
          0
      end

    :telemetry.execute(
      [:slackex, :oban, :queue_depth],
      %{running: running_count, available: available_count},
      %{queue: queue}
    )
  end

  defp connected_users_count do
    case online_provider().count() do
      count when is_integer(count) and count >= 0 -> {:ok, count}
      _ -> {:error, :presence_probe_failed}
    end
  rescue
    _ -> {:error, :presence_probe_failed}
  catch
    _, _ -> {:error, :presence_probe_failed}
  end

  defp queue_running_count(queue) do
    case queue_provider().check_queue(queue) do
      %{running: running} when is_list(running) -> {:ok, length(running)}
      _ -> {:error, :queue_probe_failed}
    end
  rescue
    _ -> {:error, :queue_probe_failed}
  catch
    _, _ -> {:error, :queue_probe_failed}
  end

  defp queue_available_count(queue) do
    case queue_provider().count_available(queue) do
      count when is_integer(count) and count >= 0 -> {:ok, count}
      _ -> {:error, :queue_available_probe_failed}
    end
  rescue
    _ -> {:error, :queue_available_probe_failed}
  catch
    _, _ -> {:error, :queue_available_probe_failed}
  end

  defp log_probe_failure(probe, code, metadata \\ []) do
    details =
      metadata
      |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{value}" end)

    suffix = if details == "", do: "", else: " #{details}"

    Logger.warning("telemetry_probe_failed probe=#{probe} code=#{code}#{suffix}")
  end

  defp queue_provider do
    Application.get_env(:slackex, __MODULE__, [])
    |> Keyword.get(:queue_provider, __MODULE__.QueueProvider)
  end

  defp online_provider do
    Application.get_env(:slackex, __MODULE__, [])
    |> Keyword.get(:online_provider, __MODULE__.OnlineProvider)
  end

  defmodule QueueProvider do
    def check_queue(queue), do: Oban.check_queue(queue: queue)

    def count_available(queue) do
      import Ecto.Query

      Slackex.Repo.aggregate(
        from(j in "oban_jobs",
          where: j.state == "available" and j.queue == ^to_string(queue)
        ),
        :count
      )
    end
  end

  defmodule OnlineProvider do
    def count, do: Slackex.Notifications.OnlineTracker.count_online()
  end
end
