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
  def complete(messages, opts) do
    case Keyword.get(opts, :purpose) do
      :sous_facet -> {:ok, sous_facet_response(messages)}
      _ -> {:ok, @canned_response}
    end
  end

  # Deterministic, viewer-distinguishable string for Sous Slice B2. Parses the
  # FacetPrompt user message (Task 2) for viewer name and decision summary.
  # Existing callers (summarization etc.) are unaffected — the `purpose` branch
  # above is the only divergence.
  defp sous_facet_response(messages) do
    user_content =
      messages
      |> Enum.find(%{}, &(&1.role == "user"))
      |> Map.get(:content, "")

    viewer_name = extract_after("You are reading as the ", ". Focus", user_content)
    focus_csv = extract_after("Focus areas: ", ".\n", user_content)
    decision_what = extract_after("Decision: ", "\n", user_content)

    "[stub:#{viewer_name}] #{decision_what} -- focus: #{focus_csv}"
  end

  defp extract_after(prefix, suffix, content) do
    with [_head, rest] <- String.split(content, prefix, parts: 2),
         [match | _] <- String.split(rest, suffix, parts: 2) do
      String.trim(match)
    else
      _ -> ""
    end
  end

  @impl true
  def stream(_messages, _opts) do
    words = String.split(@canned_response, ~r/(?<=\s)/)
    stream = Stream.map(words, & &1)
    {:ok, stream}
  end
end
