defmodule Slackex.AI.Telemetry do
  @moduledoc """
  Universal telemetry handlers for all external AI services.

  Attaches `:telemetry` handlers that log structured lines for every
  AI API call. Attach once at application startup.

  ## Events

    * `[:slackex, :ai, :completion]` — LLM chat completions
    * `[:slackex, :ai, :embedding]` — embedding generation
    * `[:slackex, :ai, :rerank]` — reranking (future)
    * `[:slackex, :ai, :moderation]` — moderation (future)
  """

  require Logger

  @events [
    [:slackex, :ai, :completion],
    [:slackex, :ai, :embedding],
    [:slackex, :ai, :rerank],
    [:slackex, :ai, :moderation]
  ]

  @doc "Attaches telemetry handlers for all AI service events."
  def attach_handlers do
    :telemetry.attach_many(
      "slackex-ai-telemetry",
      @events,
      &handle_event/4,
      nil
    )
  end

  defp handle_event([:slackex, :ai, :completion], measurements, metadata, _config) do
    duration_ms = div(measurements.duration, 1_000)

    Logger.info(
      "[AI] completion model=#{metadata.model} prompt=#{metadata.prompt_tokens} completion=#{metadata.completion_tokens} duration=#{duration_ms}ms"
    )
  end

  defp handle_event([:slackex, :ai, :embedding], measurements, metadata, _config) do
    duration_ms = div(measurements.duration, 1_000)

    Logger.info(
      "[AI] embedding model=#{metadata.model} tokens=#{metadata[:tokens] || "n/a"} batch=#{metadata[:batch_size] || 1} duration=#{duration_ms}ms"
    )
  end

  defp handle_event([:slackex, :ai, event_type], measurements, metadata, _config) do
    duration_ms = div(measurements.duration, 1_000)

    Logger.info(
      "[AI] #{event_type} model=#{metadata[:model] || "unknown"} duration=#{duration_ms}ms"
    )
  end
end
