defmodule Slackex.Search.HistoryLoader do
  @moduledoc """
  CQRS read side for message history.

  Provides cache-first access for recent messages and direct DB access
  for paginated history (messages before a given Snowflake ID).
  """

  alias Slackex.Cache.Local
  alias Slackex.Chat

  @doc """
  Returns recent messages for the given target.

  Checks the cache first. On a cache hit (non-empty list), returns the cached
  messages in chronological order (oldest first). On a cache miss, queries the
  database, backfills the cache, and returns messages in chronological order.

  Target is `{:channel, id}` or `{:dm, id}`.
  """
  @spec recent(Local.target(), pos_integer()) :: {:ok, list()}
  def recent(target, limit \\ 50) do
    case Local.get_messages(target) do
      {:ok, [_ | _] = messages} ->
        {:ok, messages}

      {:ok, []} ->
        messages = fetch_from_db(target, limit: limit)
        chronological = Enum.reverse(messages)

        Enum.each(chronological, fn msg ->
          Local.put_message(target, struct_to_map(msg))
        end)

        {:ok, chronological}
    end
  end

  @doc """
  Returns messages before the given Snowflake ID, always from the database.

  Older messages are not worth caching. Returns results in chronological order
  (oldest first). Target is `{:channel, id}` or `{:dm, id}`.
  """
  @spec before(Local.target(), integer(), pos_integer()) :: {:ok, list()}
  def before(target, before_id, limit \\ 50) do
    messages = fetch_from_db(target, before: before_id, limit: limit)
    {:ok, Enum.reverse(messages)}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_from_db({:channel, id}, opts), do: Chat.list_messages(id, opts)
  defp fetch_from_db({:dm, id}, opts), do: Chat.list_dm_messages(id, opts)

  defp struct_to_map(%{__struct__: _} = struct), do: Map.from_struct(struct)
  defp struct_to_map(map), do: map
end
