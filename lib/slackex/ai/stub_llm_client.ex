defmodule Slackex.AI.StubLLMClient do
  @moduledoc """
  Deterministic LLM client for test environments.

  Returns canned responses without network calls. The `stream/2` function
  yields individual words from the response to simulate streaming.
  """

  @behaviour Slackex.AI.LLMClient

  @canned_response "Here is a summary of the conversation:\n\n" <>
                     "**Key Topics:** The team discussed project updates and upcoming deadlines.\n\n" <>
                     "**Decisions Made:** Agreed to proceed with the current approach.\n\n" <>
                     "**Action Items:**\n- Review the pull request (unassigned)\n- Update documentation (unassigned)"

  @impl true
  def complete(_messages, _opts) do
    {:ok, @canned_response}
  end

  @impl true
  def stream(_messages, _opts) do
    words = String.split(@canned_response, ~r/(?<=\s)/)
    stream = Stream.map(words, & &1)
    {:ok, stream}
  end
end
