defmodule Slackex.Chat.DMRateLimiter do
  @moduledoc """
  ETS-backed rate limiter for DM conversation creation and DM request creation.

  Uses the pure functional RateLimiter internally, storing per-user
  limiter state in an ETS table. Supports three independent buckets:

    - DM creation: 5 new DMs per hour (key: `user_id`)
    - DM request hourly: 5 requests per hour (key: `{:request_hourly, user_id}`)
    - DM request daily: 20 requests per day (key: `{:request_daily, user_id}`)

  Runs as a GenServer to own the ETS table lifecycle. The table is
  `:public`, so check/reset are direct ETS operations with no
  GenServer bottleneck.
  """

  use GenServer

  alias Slackex.Infrastructure.RateLimiter

  @table :dm_rate_limits
  @rate 5
  @per :hour

  @request_hourly_rate 5
  @request_hourly_per :hour
  @request_daily_rate 20
  @request_daily_per :day

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
    check_bucket(user_id, @rate, @per)
  end

  @doc """
  Checks if the user can send a new DM request (hourly bucket).
  Returns `:ok` or `{:error, :rate_limited}`.
  """
  @spec check_request_hourly(integer()) :: :ok | {:error, :rate_limited}
  def check_request_hourly(user_id) do
    check_bucket({:request_hourly, user_id}, @request_hourly_rate, @request_hourly_per)
  end

  @doc """
  Checks if the user can send a new DM request (daily bucket).
  Returns `:ok` or `{:error, :rate_limited}`.
  """
  @spec check_request_daily(integer()) :: :ok | {:error, :rate_limited}
  def check_request_daily(user_id) do
    check_bucket({:request_daily, user_id}, @request_daily_rate, @request_daily_per)
  end

  @doc """
  Resets the rate limit bucket for a user (DM creation).
  """
  @spec reset(integer()) :: :ok
  def reset(user_id) do
    :ets.delete(@table, user_id)
    :ok
  end

  @doc """
  Resets the hourly request rate limit bucket for a user.
  """
  @spec reset_request_hourly(integer()) :: :ok
  def reset_request_hourly(user_id) do
    :ets.delete(@table, {:request_hourly, user_id})
    :ok
  end

  ## GenServer callbacks

  @impl true
  def init(_) do
    table = :ets.new(@table, [:named_table, :public, :set])
    {:ok, %{table: table}}
  end

  ## Private

  defp check_bucket(key, rate, per) do
    limiter = get_or_create_limiter(key, rate, per)

    case RateLimiter.check(limiter) do
      {:ok, updated_limiter} ->
        :ets.insert(@table, {key, updated_limiter})
        :ok

      {:error, :rate_limited} ->
        {:error, :rate_limited}
    end
  end

  defp get_or_create_limiter(key, rate, per) do
    case :ets.lookup(@table, key) do
      [{^key, limiter}] -> limiter
      [] -> RateLimiter.new(rate: rate, per: per)
    end
  end
end
