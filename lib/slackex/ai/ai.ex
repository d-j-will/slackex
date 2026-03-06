defmodule Slackex.AI do
  @moduledoc "Context boundary for AI/LLM operations (summarization, streaming)."

  use Boundary,
    deps: [Slackex.Chat],
    exports: [Summarizer, LLMClient, Telemetry]
end
