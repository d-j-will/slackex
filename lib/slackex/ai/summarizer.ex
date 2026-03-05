defmodule Slackex.AI.Summarizer do
  @moduledoc """
  Summarizes recent channel activity using the configured LLM client.

  Loads messages from a channel since a given timestamp, formats them as
  context, and streams an AI-generated summary.
  """

  alias Slackex.AI.LLMClient
  alias Slackex.Chat.Channel
  alias Slackex.Chat.Message
  alias Slackex.Repo

  import Ecto.Query

  @max_context_tokens 4_000
  @chars_per_token 4

  @doc """
  Summarizes a channel's messages since the given timestamp.

  Returns `{:ok, token_stream}` where the stream yields string chunks,
  or `{:error, reason}`.

  ## Errors

    * `:not_configured` — no LLM client configured
    * `:no_messages` — no messages found in the time range
  """
  @spec summarize_channel(integer(), DateTime.t(), integer(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, atom()}
  def summarize_channel(channel_id, since, _user_id, opts \\ []) do
    with :ok <- check_configured(),
         {:ok, messages} <- load_messages(channel_id, since),
         {:ok, context} <- format_context(messages) do
      channel_name = channel_name(channel_id)
      since_human = Calendar.strftime(since, "%B %d, %Y at %H:%M UTC")
      {system_prompt, user_prompt} = build_prompt(channel_name, since_human, context)

      llm_messages = [
        %{role: "system", content: system_prompt},
        %{role: "user", content: user_prompt}
      ]

      LLMClient.stream(llm_messages, opts)
    end
  end

  @doc """
  Builds the system and user prompts for channel summarization.
  """
  @spec build_prompt(String.t(), String.t(), String.t()) :: {String.t(), String.t()}
  def build_prompt(channel_name, since_human, context) do
    system = """
    You are a concise channel summarizer for a team chat app.
    Summarize the conversation clearly and briefly. Include:
    - Key topics discussed
    - Decisions made
    - Action items (with who owns them, if mentioned)
    - Notable messages or announcements
    Do not invent information not present in the messages.\
    """

    user = """
    Summarize the following conversation from #{channel_name} since #{since_human}:

    #{context}\
    """

    {system, user}
  end

  # -- Private --

  defp check_configured do
    if LLMClient.configured?(), do: :ok, else: {:error, :not_configured}
  end

  defp load_messages(channel_id, since) do
    messages =
      from(m in Message,
        where: m.channel_id == ^channel_id,
        where: m.inserted_at >= ^since,
        where: is_nil(m.deleted_at),
        order_by: [asc: m.inserted_at],
        preload: [:sender],
        limit: 200
      )
      |> Repo.all()

    case messages do
      [] -> {:error, :no_messages}
      msgs -> {:ok, msgs}
    end
  end

  defp format_context(messages) do
    max_chars = @max_context_tokens * @chars_per_token

    lines =
      messages
      |> Enum.map(&format_line/1)
      |> truncate_to_budget(max_chars)

    {:ok, Enum.join(lines, "\n")}
  end

  defp format_line(message) do
    timestamp = Calendar.strftime(message.inserted_at, "%Y-%m-%d %H:%M")
    username = if message.sender, do: message.sender.username, else: "[deleted user]"
    content = message.search_content || ""

    "[#{timestamp}] #{username}: #{content}"
  end

  defp truncate_to_budget(lines, max_chars) do
    truncate_lines(lines, max_chars, 0, [])
  end

  defp truncate_lines([], _max, _used, acc), do: Enum.reverse(acc)

  defp truncate_lines([line | rest], max, used, acc) do
    sep = if acc == [], do: 0, else: 1
    total = used + sep + byte_size(line)

    if total <= max do
      truncate_lines(rest, max, total, [line | acc])
    else
      Enum.reverse(acc)
    end
  end

  defp channel_name(channel_id) do
    case Repo.get(Channel, channel_id) do
      nil -> "#unknown"
      channel -> "##{channel.name}"
    end
  end
end
