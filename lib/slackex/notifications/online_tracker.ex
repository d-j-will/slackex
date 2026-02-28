defmodule Slackex.Notifications.OnlineTracker do
  @moduledoc """
  Tracks user online status in Redis with a 2-minute TTL.

  Keys use the pattern `online:{user_id}`. TTL is refreshed by periodic
  heartbeat calls from connected LiveViews/Channels.
  """

  @ttl_seconds 120

  defp redis_key(user_id), do: "online:#{user_id}"

  defp random_conn do
    :"redix_#{:rand.uniform(10) - 1}"
  end

  @doc "Marks a user as online with a 2-minute TTL."
  @spec mark_online(integer()) :: :ok
  def mark_online(user_id) do
    Redix.command(random_conn(), ["SET", redis_key(user_id), "1", "EX", @ttl_seconds])
    :ok
  rescue
    _ -> :ok
  end

  @doc "Removes the online marker for a user."
  @spec mark_offline(integer()) :: :ok
  def mark_offline(user_id) do
    Redix.command(random_conn(), ["DEL", redis_key(user_id)])
    :ok
  rescue
    _ -> :ok
  end

  @doc "Refreshes the TTL for an already-online user."
  @spec refresh(integer()) :: :ok
  def refresh(user_id) do
    Redix.command(random_conn(), ["EXPIRE", redis_key(user_id), @ttl_seconds])
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Accepts a list of user IDs and returns a MapSet of those currently online.
  Uses a single Redis MGET call for efficiency. Returns an empty MapSet on
  Redis failure or when given an empty list.
  """
  @spec online_user_ids([integer()]) :: MapSet.t()
  def online_user_ids([]), do: MapSet.new()

  def online_user_ids(user_ids) when is_list(user_ids) do
    keys = Enum.map(user_ids, &redis_key/1)

    case Redix.command(random_conn(), ["MGET" | keys]) do
      {:ok, values} ->
        user_ids
        |> Enum.zip(values)
        |> Enum.filter(fn {_id, val} -> val != nil end)
        |> Enum.map(fn {id, _val} -> id end)
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  rescue
    _ -> MapSet.new()
  end

  @doc "Returns true if the user has an active online marker in Redis."
  @spec online?(integer()) :: boolean()
  def online?(user_id) do
    case Redix.command(random_conn(), ["GET", redis_key(user_id)]) do
      {:ok, nil} -> false
      {:ok, _} -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
