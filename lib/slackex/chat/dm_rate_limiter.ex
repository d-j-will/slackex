defmodule Slackex.Chat.DMRateLimiter do
  @moduledoc """
  ETS-backed rate limiter for DM conversation creation.

  Uses the pure functional RateLimiter internally, storing per-user
  limiter state in an ETS table. Rate: 5 new DMs per hour per user.

  Runs as a GenServer to own the ETS table lifecycle. The table is
  `:public`, so check/reset are direct ETS operations with no
  GenServer bottleneck.
  """

  use GenServer

  alias Slackex.Infrastructure.RateLimiter

  @table :dm_rate_limits
  @rate 5
  @per :hour

  ## Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Checks if the user can create a new DM conversation.
  Returns `:ok` or `{:error, :rate_limited}`.
  """
  @spec check(integer()) :: :ok | {:error, :rate_limited}
  def check(user_id) do
    limiter = get_or_create_limiter(user_id)

    case RateLimiter.check(limiter) do
      {:ok, updated_limiter} ->
        :ets.insert(@table, {user_id, updated_limiter})
        :ok

      {:error, :rate_limited} ->
        {:error, :rate_limited}
    end
  end

  @doc """
  Resets the rate limit bucket for a user.
  """
  @spec reset(integer()) :: :ok
  def reset(user_id) do
    :ets.delete(@table, user_id)
    :ok
  end

  ## GenServer callbacks

  @impl true
  def init(_) do
    table = :ets.new(@table, [:named_table, :public, :set])
    {:ok, %{table: table}}
  end

  ## Private

  defp get_or_create_limiter(user_id) do
    case :ets.lookup(@table, user_id) do
      [{^user_id, limiter}] -> limiter
      [] -> RateLimiter.new(rate: @rate, per: @per)
    end
  end
end
