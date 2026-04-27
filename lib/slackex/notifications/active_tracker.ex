defmodule Slackex.Notifications.ActiveTracker do
  @moduledoc """
  Tracks whether a user is *actively engaged* (tab visible, focused) — distinct
  from `Slackex.Notifications.OnlineTracker`, which only knows the LiveView
  heartbeat is alive.

  Used by `Slackex.Notifications.PushWorker` to decide whether a push is
  necessary. Backgrounded PWAs and suspended sockets should still receive
  push deliveries; only an actively-engaged tab suppresses them.

  Key: `active:{user_id}`. TTL 20s. Refreshed by client-driven heartbeats
  every 10s while the page is visible.
  """

  @ttl_seconds 20

  defp redis_key(user_id), do: "active:#{user_id}"

  defp random_conn, do: :"redix_#{:rand.uniform(10) - 1}"

  defp redis_command(args, fallback) do
    case Redix.command(random_conn(), args) do
      {:ok, result} -> result
      _ -> fallback
    end
  rescue
    _ -> fallback
  end

  @doc "Marks a user as actively engaged with a 20s TTL."
  @spec mark_active(integer()) :: :ok
  def mark_active(user_id) do
    _ = redis_command(["SET", redis_key(user_id), "1", "EX", @ttl_seconds], nil)
    :ok
  end

  @doc "Removes the active marker for a user."
  @spec mark_inactive(integer()) :: :ok
  def mark_inactive(user_id) do
    _ = redis_command(["DEL", redis_key(user_id)], nil)
    :ok
  end

  @doc "Returns true when the user has an unexpired active marker."
  @spec active?(integer()) :: boolean()
  def active?(user_id) do
    redis_command(["GET", redis_key(user_id)], nil) != nil
  end
end
