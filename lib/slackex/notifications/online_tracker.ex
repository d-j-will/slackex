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

  # Executes a Redis command, returning `fallback` on any error.
  # All public functions route through here for consistent error handling.
  defp redis_command(args, fallback) do
    case Redix.command(random_conn(), args) do
      {:ok, result} -> result
      _ -> fallback
    end
  rescue
    _ -> fallback
  end

  @doc "Marks a user as online with a 2-minute TTL."
  @spec mark_online(integer()) :: :ok
  def mark_online(user_id) do
    redis_command(["SET", redis_key(user_id), "1", "EX", @ttl_seconds], nil)
    :ok
  end

  @doc "Removes the online marker for a user."
  @spec mark_offline(integer()) :: :ok
  def mark_offline(user_id) do
    redis_command(["DEL", redis_key(user_id)], nil)
    :ok
  end

  @doc "Refreshes the TTL for an already-online user."
  @spec refresh(integer()) :: :ok
  def refresh(user_id) do
    redis_command(["EXPIRE", redis_key(user_id), @ttl_seconds], nil)
    :ok
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

    case redis_command(["MGET" | keys], :error) do
      :error ->
        MapSet.new()

      values ->
        user_ids
        |> Enum.zip(values)
        |> Enum.reduce(MapSet.new(), fn
          {id, val}, acc when val != nil -> MapSet.put(acc, id)
          _, acc -> acc
        end)
    end
  end

  @doc "Returns true if the user has an active online marker in Redis."
  @spec online?(integer()) :: boolean()
  def online?(user_id) do
    redis_command(["GET", redis_key(user_id)], nil) != nil
  end
end
