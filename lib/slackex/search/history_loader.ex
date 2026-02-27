defmodule Slackex.Search.HistoryLoader do
  @moduledoc """
  CQRS read side for message history.

  Provides cache-first access for recent messages and direct DB access
  for paginated history (messages before a given Snowflake ID).
  """

  alias Slackex.Cache
  alias Slackex.Chat

  @doc """
  Returns recent messages for the given target.

  Checks the cache first. On a cache hit (non-empty list), returns the cached
  messages in chronological order (oldest first). On a cache miss, queries the
  database, backfills the cache, and returns messages in chronological order.

  Target is `{:channel, id}` or `{:dm, id}`.
  """
  @spec recent(Cache.target(), pos_integer()) :: {:ok, list()}
  def recent(target, limit \\ 50) do
    case Cache.get_messages(target) do
      {:ok, [_ | _] = messages} ->
        {:ok, messages}

      _ ->
        messages = fetch_from_db(target, limit: limit)
        chronological = Enum.reverse(messages)
        Cache.cache_messages(target, Enum.map(chronological, &struct_to_map/1))
        {:ok, chronological}
    end
  end

  @doc """
  Returns messages before the given Snowflake ID, always from the database.

  Older messages are not worth caching. Returns results in chronological order
  (oldest first). Target is `{:channel, id}` or `{:dm, id}`.
  """
  @spec before(Cache.target(), integer(), pos_integer()) :: {:ok, list()}
  def before(target, before_id, limit \\ 50) do
    messages = fetch_from_db(target, before: before_id, limit: limit)
    {:ok, Enum.reverse(messages)}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_from_db({:channel, id}, opts), do: Chat.list_messages(id, opts)
  defp fetch_from_db({:dm, id}, opts), do: Chat.list_dm_messages(id, opts)

  # Leave calendar types as-is — Jason has built-in encoders for them,
  # and expanding them to maps produces unencodable tuples (e.g. microsecond).
  defp struct_to_map(%{__struct__: module} = struct)
       when module in [DateTime, NaiveDateTime, Date, Time],
       do: struct

  defp struct_to_map(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> Enum.reduce(%{}, fn
      {:__meta__, _}, acc -> acc
      {_k, %Ecto.Association.NotLoaded{}}, acc -> acc
      {k, %{__struct__: _} = inner}, acc -> Map.put(acc, k, struct_to_map(inner))
      {k, v}, acc when is_binary(v) -> if String.valid?(v), do: Map.put(acc, k, v), else: acc
      {k, v}, acc -> Map.put(acc, k, v)
    end)
  end

  defp struct_to_map(map), do: map
end
