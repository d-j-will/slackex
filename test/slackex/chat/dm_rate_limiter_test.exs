defmodule Slackex.Chat.DMRateLimiterTest do
  use Slackex.DataCase, async: false

  alias Slackex.Chat
  alias Slackex.Chat.DMRateLimiter

  @max_dms_per_hour 5

  setup do
    DMRateLimiter.init()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Unit tests: DMRateLimiter.check/1 and reset/1
  # ---------------------------------------------------------------------------

  describe "DMRateLimiter.check/1" do
    test "allows first #{@max_dms_per_hour} requests for a user" do
      user_id = 1

      results =
        for _ <- 1..@max_dms_per_hour do
          DMRateLimiter.check(user_id)
        end

      assert Enum.all?(results, &(&1 == :ok))
    end

    test "blocks the #{@max_dms_per_hour + 1}th request" do
      user_id = 2

      for _ <- 1..@max_dms_per_hour do
        :ok = DMRateLimiter.check(user_id)
      end

      assert {:error, :rate_limited} = DMRateLimiter.check(user_id)
    end

    test "different user IDs have independent rate limit buckets" do
      user_a = 10
      user_b = 20

      # Exhaust user_a's limit
      for _ <- 1..@max_dms_per_hour do
        :ok = DMRateLimiter.check(user_a)
      end

      assert {:error, :rate_limited} = DMRateLimiter.check(user_a)

      # user_b should still be allowed
      assert :ok = DMRateLimiter.check(user_b)
    end
  end

  describe "DMRateLimiter.reset/1" do
    test "clears a user's rate limit bucket" do
      user_id = 3

      # Exhaust the limit
      for _ <- 1..@max_dms_per_hour do
        :ok = DMRateLimiter.check(user_id)
      end

      assert {:error, :rate_limited} = DMRateLimiter.check(user_id)

      # Reset and verify the user can create DMs again
      DMRateLimiter.reset(user_id)

      assert :ok = DMRateLimiter.check(user_id)
    end

    test "reset on non-existent user does not crash" do
      assert :ok = DMRateLimiter.reset(999_999)
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance tests: rate limiting through find_or_create_dm
  # ---------------------------------------------------------------------------

  describe "find_or_create_dm rate limiting" do
    test "new DM creation is rate-limited after #{@max_dms_per_hour} creations per hour" do
      initiator = insert(:user)

      # Create 5 new DM conversations (each with a different user)
      for _ <- 1..@max_dms_per_hour do
        other = insert(:user)
        assert {:ok, _dm} = Chat.find_or_create_dm(initiator.id, other.id)
      end

      # The 6th new DM should be rate-limited
      one_more = insert(:user)
      assert {:error, :rate_limited} = Chat.find_or_create_dm(initiator.id, one_more.id)
    end

    test "reopening an existing DM conversation is not rate-limited" do
      initiator = insert(:user)

      # Create 5 new DM conversations to exhaust the limit
      others =
        for _ <- 1..@max_dms_per_hour do
          other = insert(:user)
          {:ok, _dm} = Chat.find_or_create_dm(initiator.id, other.id)
          other
        end

      # Reopening an already-existing conversation should succeed
      existing_other = hd(others)
      assert {:ok, _dm} = Chat.find_or_create_dm(initiator.id, existing_other.id)
    end

    test "different users have independent rate limit buckets" do
      user_a = insert(:user)
      user_b = insert(:user)

      # Exhaust user_a's limit
      for _ <- 1..@max_dms_per_hour do
        other = insert(:user)
        {:ok, _dm} = Chat.find_or_create_dm(user_a.id, other.id)
      end

      # user_a should be rate-limited
      another_user = insert(:user)
      assert {:error, :rate_limited} = Chat.find_or_create_dm(user_a.id, another_user.id)

      # user_b should still be allowed to create new DMs
      yet_another = insert(:user)
      assert {:ok, _dm} = Chat.find_or_create_dm(user_b.id, yet_another.id)
    end

    test "self-DMs are exempt from rate limiting" do
      user = insert(:user)

      # Exhaust the rate limit
      for _ <- 1..@max_dms_per_hour do
        other = insert(:user)
        {:ok, _dm} = Chat.find_or_create_dm(user.id, other.id)
      end

      # Self-DM should still succeed even though limit is exhausted
      assert {:ok, dm} = Chat.find_or_create_dm(user.id, user.id)
      assert dm.user_a_id == user.id
      assert dm.user_b_id == user.id
    end

    test "rate limit applies to the initiator, not the sorted user ID" do
      initiator = insert(:user)

      # Exhaust initiator's limit with 5 new DM conversations
      for _ <- 1..@max_dms_per_hour do
        other = insert(:user)
        {:ok, _dm} = Chat.find_or_create_dm(initiator.id, other.id)
      end

      # The 6th attempt by the same initiator should fail
      one_more = insert(:user)
      assert {:error, :rate_limited} = Chat.find_or_create_dm(initiator.id, one_more.id)
    end
  end
end
