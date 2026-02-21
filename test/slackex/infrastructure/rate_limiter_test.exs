defmodule Slackex.Infrastructure.RateLimiterTest do
  use ExUnit.Case, async: true

  alias Slackex.Infrastructure.RateLimiter

  describe "new/1" do
    test "creates a limiter with full tokens" do
      limiter = RateLimiter.new(rate: 5, per: :second)
      assert limiter.rate == 5
      assert limiter.tokens >= 5.0
    end
  end

  describe "check/1" do
    test "allows requests within rate limit" do
      limiter = RateLimiter.new(rate: 5, per: :second)

      results =
        Enum.reduce(1..5, {[], limiter}, fn _, {acc, l} ->
          {:ok, updated} = RateLimiter.check(l)
          {[:ok | acc], updated}
        end)

      {statuses, _} = results
      assert Enum.all?(statuses, &(&1 == :ok))
    end

    test "rejects requests exceeding rate limit" do
      limiter = RateLimiter.new(rate: 3, per: :second)

      # Exhaust the 3 tokens
      {:ok, l1} = RateLimiter.check(limiter)
      {:ok, l2} = RateLimiter.check(l1)
      {:ok, l3} = RateLimiter.check(l2)

      # Next request should be rejected
      assert {:error, :rate_limited} = RateLimiter.check(l3)
    end

    test "tokens refill after the time window elapses" do
      limiter = RateLimiter.new(rate: 2, per: :second)

      # Exhaust tokens
      {:ok, l1} = RateLimiter.check(limiter)
      {:ok, l2} = RateLimiter.check(l1)
      assert {:error, :rate_limited} = RateLimiter.check(l2)

      # Simulate time passing by backdating last_refill by 1 second
      refilled = %{l2 | last_refill: l2.last_refill - 1_000}

      # Should succeed after refill
      assert {:ok, _} = RateLimiter.check(refilled)
    end

    test "rate limiter state is independent per instance" do
      limiter_a = RateLimiter.new(rate: 1, per: :second)
      limiter_b = RateLimiter.new(rate: 1, per: :second)

      # Exhaust limiter_a
      {:ok, exhausted_a} = RateLimiter.check(limiter_a)
      assert {:error, :rate_limited} = RateLimiter.check(exhausted_a)

      # limiter_b is unaffected
      assert {:ok, _} = RateLimiter.check(limiter_b)
    end
  end
end
