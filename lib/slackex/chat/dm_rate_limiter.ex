defmodule Slackex.Chat.DMRateLimiter do
  @moduledoc """
  ETS-backed rate limiter for DM conversation creation.

  Uses the pure functional RateLimiter internally, storing per-user
  limiter state in an ETS table. Rate: 5 new DMs per hour per user.
  """

  alias Slackex.Infrastructure.RateLimiter

  @table :dm_rate_limits
  @rate 5
  @per :hour

  @doc """
  Creates the ETS table. Safe to call multiple times (handles table-already-exists).
  Called from application.ex startup.
  """
  @spec init() :: :ok
  def init do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set])
        :ok

      _ref ->
        :ok
    end
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

  defp get_or_create_limiter(user_id) do
    case :ets.lookup(@table, user_id) do
      [{^user_id, limiter}] -> limiter
      [] -> RateLimiter.new(rate: @rate, per: @per)
    end
  end
end
