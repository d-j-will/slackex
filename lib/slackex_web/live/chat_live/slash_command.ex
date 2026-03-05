defmodule SlackexWeb.ChatLive.SlashCommand do
  @moduledoc """
  Parses slash commands from message input.

  Commands start with `/` and are dispatched before being sent as messages.
  Extensible via pattern matching — add new commands by adding `do_parse/1` clauses.

  ## Supported Commands

    * `/summarize [range]` — summarize channel (24h, 7d, 30d)
  """

  @type result ::
          {:summarize, String.t()}
          | {:unknown_command, String.t()}
          | :not_command

  @doc "Parses a message string. Returns a command tuple or `:not_command`."
  @spec parse(String.t()) :: result()
  def parse(input) do
    input
    |> String.trim()
    |> do_parse()
  end

  defp do_parse("/" <> rest) do
    case String.split(rest, ~r/\s+/, parts: 2) do
      ["summarize"] -> {:summarize, "24h"}
      ["summarize", range] -> {:summarize, String.trim(range)}
      [command | _] -> {:unknown_command, command}
      [] -> :not_command
    end
  end

  defp do_parse(_), do: :not_command
end
