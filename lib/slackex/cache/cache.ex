defmodule Slackex.Cache do
  @moduledoc """
  Three-tier cache facade: ETS (hot) → Redis (warm) → miss.

  Coordinates `Cache.Local` (ETS) and `Cache.Redis` for reads and
  write-through writes. ETS is authoritative for hot data; Redis
  serves as a cross-node warm cache. Redis writes are best-effort
  and never block the message broadcast path.

  ## Read path (get_messages/1)
    1. ETS hit  → return immediately
    2. Redis hit → backfill ETS, return
    3. Both miss → return `{:miss, []}` (caller falls through to DB)

  ## Write path (put_message/2)
    1. Write to ETS (always — synchronous, authoritative)
    2. Write to Redis (best-effort, 100 ms timeout, drop on failure)
  """

  require Logger

  alias Slackex.Cache.Local
  alias Slackex.Cache.Redis

  @type target :: {:channel, term()} | {:dm, term()}

  @doc """
  Reads messages from the 3-tier cascade.
  Returns `{:ok, messages}` on any hit or `{:miss, []}` if both caches miss.
  """
  @spec get_messages(target()) :: {:ok, [map()]} | {:miss, []}
  def get_messages(target) do
    case Local.get_messages(target) do
      {:ok, [_ | _] = messages} ->
        {:ok, messages}

      {:ok, []} ->
        case Redis.get_messages(target) do
          {:ok, messages} ->
            Enum.each(messages, &Local.put_message(target, &1))
            {:ok, messages}

          {:miss, []} ->
            {:miss, []}
        end
    end
  end

  @doc """
  Write-through: appends `message` to both ETS and Redis.
  ETS write is synchronous; Redis write is best-effort (100 ms timeout).
  """
  @spec put_message(target(), map()) :: :ok
  def put_message(target, message) do
    Local.put_message(target, message)
    Redis.push_message(target, message)
    :ok
  end

  @doc "Updates a cached message in-place by id. ETS only (Redis invalidated)."
  @spec update_message(target(), integer(), map()) :: :ok
  def update_message(target, message_id, updates) do
    Local.update_message(target, message_id, updates)
    Redis.invalidate(target)
    :ok
  end

  @doc "Removes a cached message by id. ETS only (Redis invalidated)."
  @spec remove_message(target(), integer()) :: :ok
  def remove_message(target, message_id) do
    Local.remove_message(target, message_id)
    Redis.invalidate(target)
    :ok
  end

  @doc "Invalidates `target` in both ETS and Redis."
  @spec invalidate(target()) :: :ok
  def invalidate(target) do
    Local.invalidate(target)
    Redis.invalidate(target)
    :ok
  end

  @doc "Bulk backfills both ETS and Redis with `messages`."
  @spec cache_messages(target(), [map()]) :: :ok
  def cache_messages(target, messages) do
    Enum.each(messages, &Local.put_message(target, &1))
    Redis.cache_messages(target, messages)
    :ok
  end
end
