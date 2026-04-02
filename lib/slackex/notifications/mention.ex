defmodule Slackex.Notifications.Mention do
  @moduledoc "Detects @username mentions in message content using word-boundary regex."

  @spec mentioned?(String.t(), String.t()) :: boolean()
  def mentioned?(content, username) when is_binary(content) and is_binary(username) do
    escaped = Regex.escape(username)
    pattern = Regex.compile!("(?<!\\w)@#{escaped}\\b", "i")
    Regex.match?(pattern, content)
  end
end
