defmodule Slackex.Embeddings.RAGContext do
  @moduledoc """
  Retrieves semantically relevant messages and formats them as a plain-text
  context string suitable for LLM prompt injection.

  Each result line is formatted as:

      [YYYY-MM-DD HH:MM] username: content

  The output is truncated to fit within a token budget (default 4000 tokens,
  estimated at ~4 characters per token) without cutting mid-line.
  """

  alias Slackex.Search.MessageSearch

  @default_max_tokens 4_000
  @default_limit 20
  @chars_per_token 4

  @doc """
  Runs semantic search for the given query and formats results as a
  newline-separated context string.

  Returns `{:ok, context_string, message_count}` or `{:error, reason}`.

  ## Options

    * `:user_id` - required, the searching user's ID (for authorization)
    * `:max_tokens` - token budget (default 4000, ~4 chars/token)
    * `:channel_id` - optional channel scope
    * `:limit` - max messages to retrieve before formatting (default 20)
    * `:embedding_client` - embedding generation function for DI

  """
  @spec retrieve(String.t(), keyword()) ::
          {:ok, String.t(), non_neg_integer()} | {:error, term()}
  def retrieve(query, opts \\ []) do
    user_id = Keyword.fetch!(opts, :user_id)
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    limit = Keyword.get(opts, :limit, @default_limit)

    search_opts =
      opts
      |> Keyword.take([:channel_id, :embedding_client])
      |> Keyword.put(:limit, limit)

    case MessageSearch.semantic_search(user_id, query, search_opts) do
      {:ok, messages} ->
        max_chars = max_tokens * @chars_per_token

        messages
        |> Enum.map(&format_line/1)
        |> truncate_to_budget(max_chars)
        |> build_result()

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Formatting
  # ---------------------------------------------------------------------------

  defp format_line(message) do
    timestamp = format_timestamp(message.inserted_at)
    username = sender_name(message.sender)
    content = message.search_content || ""

    "[#{timestamp}] #{username}: #{content}"
  end

  defp sender_name(nil), do: "[deleted user]"
  defp sender_name(%{username: username}), do: username

  defp format_timestamp(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
  end

  # ---------------------------------------------------------------------------
  # Token-budget truncation (never cuts mid-line)
  # ---------------------------------------------------------------------------

  defp truncate_to_budget(lines, max_chars) do
    truncate_lines(lines, max_chars, 0, [])
  end

  defp truncate_lines([], _max_chars, _used, accepted) do
    Enum.reverse(accepted)
  end

  defp truncate_lines([line | rest], max_chars, used, accepted) do
    line_size = byte_size(line)
    # Account for newline separator between lines
    separator_cost = if accepted == [], do: 0, else: 1
    total_with_line = used + separator_cost + line_size

    if total_with_line <= max_chars do
      truncate_lines(rest, max_chars, total_with_line, [line | accepted])
    else
      Enum.reverse(accepted)
    end
  end

  # ---------------------------------------------------------------------------
  # Result assembly
  # ---------------------------------------------------------------------------

  defp build_result(lines) do
    context = Enum.join(lines, "\n")
    count = length(lines)
    {:ok, context, count}
  end
end
