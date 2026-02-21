defmodule Slackex.Infrastructure.RateLimiter do
  @moduledoc """
  Pure functional token bucket rate limiter. No GenServer — the caller owns state.

  Example:

      limiter = RateLimiter.new(rate: 10, per: :second)

      case RateLimiter.check(limiter) do
        {:ok, updated} -> # proceed, use `updated` for next call
        {:error, :rate_limited} -> # reject request
      end
  """

  @enforce_keys [:rate, :per_ms, :tokens, :last_refill]
  defstruct [:rate, :per_ms, :tokens, :last_refill]

  @type t :: %__MODULE__{
          rate: pos_integer(),
          per_ms: pos_integer(),
          tokens: float(),
          last_refill: integer()
        }

  @spec new(rate: pos_integer(), per: :second | :minute | :hour) :: t()
  def new(rate: rate, per: per) do
    %__MODULE__{
      rate: rate,
      per_ms: per_to_ms(per),
      tokens: rate,
      last_refill: :os.system_time(:millisecond)
    }
  end

  @spec check(t()) :: {:ok, t()} | {:error, :rate_limited}
  def check(%__MODULE__{} = limiter) do
    now = :os.system_time(:millisecond)
    refilled = refill(limiter, now)

    if refilled.tokens >= 1 do
      {:ok, %{refilled | tokens: refilled.tokens - 1}}
    else
      {:error, :rate_limited}
    end
  end

  defp refill(
         %{tokens: tokens, rate: rate, per_ms: per_ms, last_refill: last_refill} = limiter,
         now
       ) do
    elapsed = now - last_refill
    new_tokens = min(rate * 1.0, tokens + elapsed * rate / per_ms)
    %{limiter | tokens: new_tokens, last_refill: now}
  end

  defp per_to_ms(:second), do: 1_000
  defp per_to_ms(:minute), do: 60_000
  defp per_to_ms(:hour), do: 3_600_000
end
