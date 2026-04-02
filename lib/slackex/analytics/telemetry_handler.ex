defmodule Slackex.Analytics.TelemetryHandler do
  @moduledoc "Attaches to Phoenix and Oban telemetry events to track exceptions."

  require Logger

  def attach do
    _ =
      :telemetry.attach(
        "analytics-lv-exception",
        [:phoenix, :live_view, :handle_event, :exception],
        &__MODULE__.handle_liveview_exception/4,
        nil
      )

    _ =
      :telemetry.attach(
        "analytics-oban-exception",
        [:oban, :job, :exception],
        &__MODULE__.handle_oban_exception/4,
        nil
      )

    :ok
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

      _ =
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
      %{job: job, kind: _kind, reason: reason, stacktrace: _stacktrace} = metadata
      trace_id = get_otel_trace_id()

      context = %{user_id: nil, session_id: nil}

      _ =
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
    span_ctx = OpenTelemetry.Tracer.current_span_ctx()

    case span_ctx do
      :undefined -> nil
      ctx -> OpenTelemetry.Span.trace_id(ctx) |> Integer.to_string(16) |> String.downcase()
    end
  rescue
    _ -> nil
  end
end
