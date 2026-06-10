defmodule SlackexWeb.ChatLive.SlashCommand do
  @moduledoc """
  Parses slash commands from message input.

  Commands start with `/` and are dispatched before being sent as messages.
  Extensible via pattern matching — add new commands by adding `do_parse/1` clauses.

  ## Supported Commands

    * `/summarize [range]` — summarize channel (24h, 7d, 30d)
    * `/decide` — capture a decision
    * `/subscribe-bot <name>` — subscribe an MCP bot to the active channel
    * `/unsubscribe-bot <name>` — remove an MCP bot from the active channel
  """

  @type result ::
          {:summarize, String.t()}
          | {:decide}
          | {:bot_subscription, SlackexWeb.ChatLive.BotSubscription.action()}
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
      [] -> :not_command
      [command] -> command(command, nil)
      [command, arg] -> command(command, String.trim(arg))
    end
  end

  defp do_parse(_), do: :not_command

  defp command("summarize", nil), do: {:summarize, "24h"}
  defp command("summarize", range), do: {:summarize, range}
  defp command("decide", _arg), do: {:decide}
  defp command("subscribe-bot", nil), do: {:bot_subscription, :subscribe_help}
  defp command("subscribe-bot", name), do: {:bot_subscription, {:subscribe, name}}
  defp command("unsubscribe-bot", nil), do: {:bot_subscription, :unsubscribe_help}
  defp command("unsubscribe-bot", name), do: {:bot_subscription, {:unsubscribe, name}}
  defp command(command, _arg), do: {:unknown_command, command}
end
