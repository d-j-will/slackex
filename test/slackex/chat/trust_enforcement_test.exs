defmodule Slackex.Chat.TrustEnforcementTest do
  use Slackex.DataCase, async: false

  alias Slackex.Chat
  alias Slackex.Chat.{DMRateLimiter, DMRequest, UserTrustScore}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp insert_user_with_age(hours_ago) do
    user = insert(:user)
    past = DateTime.utc_now() |> DateTime.add(-hours_ago * 3600, :second) |> DateTime.truncate(:microsecond)

    {1, _} =
      Repo.update_all(
        from(u in Slackex.Accounts.User, where: u.id == ^user.id),
        set: [inserted_at: past]
      )

    %{user | inserted_at: past}
  end

  defp insert_user_with_age_days(days_ago) do
    insert_user_with_age(days_ago * 24)
  end

  defp create_distinct_blockers(target_user, count) do
    for _ <- 1..count do
      blocker = insert_user_with_age(48)
      {:ok, _block} = Chat.block_user(blocker.id, target_user.id)
      blocker
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: blocking increments block_count on trust score
  # ---------------------------------------------------------------------------

  describe "block_user/2 trust score increment" do
    test "blocking a user increments block_count on blocked user trust score" do
      blocker = insert_user_with_age(48)
      target = insert_user_with_age(48)

      {:ok, _block} = Chat.block_user(blocker.id, target.id)

      trust_score = Repo.get_by!(UserTrustScore, user_id: target.id)
      assert trust_score.block_count == 1
    end

    test "multiple distinct blockers increment block_count cumulatively" do
      target = insert_user_with_age(48)

      create_distinct_blockers(target, 3)

      trust_score = Repo.get_by!(UserTrustScore, user_id: target.id)
      assert trust_score.block_count == 3
    end

    test "block_count upserts when trust score already exists" do
      target = insert_user_with_age(48)

      # Pre-existing trust score with decline_count
      %UserTrustScore{}
      |> UserTrustScore.changeset(%{user_id: target.id, decline_count: 2})
      |> Repo.insert!()

      blocker = insert_user_with_age(48)
      {:ok, _block} = Chat.block_user(blocker.id, target.id)

      trust_score = Repo.get_by!(UserTrustScore, user_id: target.id)
      assert trust_score.block_count == 1
      assert trust_score.decline_count == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: 5 distinct blocks triggers dm_restricted
  # ---------------------------------------------------------------------------

  describe "block_user/2 auto-restriction at threshold" do
    test "user blocked by 5 distinct users gets dm_restricted set to true" do
      target = insert_user_with_age(48)

      create_distinct_blockers(target, 5)

      trust_score = Repo.get_by!(UserTrustScore, user_id: target.id)
      assert trust_score.block_count == 5
      assert trust_score.dm_restricted == true
      assert trust_score.dm_restricted_at != nil
    end

    test "user blocked by 4 distinct users does NOT get dm_restricted" do
      target = insert_user_with_age(48)

      create_distinct_blockers(target, 4)

      trust_score = Repo.get_by!(UserTrustScore, user_id: target.id)
      assert trust_score.block_count == 4
      assert trust_score.dm_restricted == false
      assert trust_score.dm_restricted_at == nil
    end

    test "dm_restricted_at timestamp is recorded when restriction activates" do
      target = insert_user_with_age(48)
      before_restriction = DateTime.utc_now() |> DateTime.add(-1, :second)

      create_distinct_blockers(target, 5)

      trust_score = Repo.get_by!(UserTrustScore, user_id: target.id)
      assert DateTime.compare(trust_score.dm_restricted_at, before_restriction) == :gt
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: dm_restricted user rejected at pre-flight
  # ---------------------------------------------------------------------------

  describe "dm_restricted user rejected at pre-flight" do
    setup do
      :ets.delete_all_objects(:dm_rate_limits)
      :ok
    end

    test "dm_restricted user cannot send new DM requests" do
      sender = insert_user_with_age_days(10)
      recipient = insert_user_with_age(48)

      # Have 5 distinct users block the sender to trigger restriction
      create_distinct_blockers(sender, 5)

      # Verify sender is now restricted
      trust_score = Repo.get_by!(UserTrustScore, user_id: sender.id)
      assert trust_score.dm_restricted == true

      # Attempt to create a DM request should be rejected
      assert {:error, :dm_restricted} =
               Chat.create_dm_request(sender.id, recipient.id, "Hello!")
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: strike-3 auto-block triggers trust score increment
  # ---------------------------------------------------------------------------

  describe "strike-3 auto-block triggers trust score increment" do
    setup do
      :ets.delete_all_objects(:dm_rate_limits)
      :ok
    end

    test "decline_dm_request strike-3 auto-block increments blocked user block_count" do
      sender = insert_user_with_age_days(40)
      recipient = insert_user_with_age(48)

      # First request + decline (backdate past cooldown)
      {:ok, req1} = Chat.create_dm_request(sender.id, recipient.id, "Hi")
      {:ok, _} = Chat.decline_dm_request(req1.id, recipient.id)

      Repo.update_all(
        from(r in DMRequest, where: r.id == ^req1.id),
        set: [responded_at: DateTime.utc_now() |> DateTime.add(-60 * 24 * 3600, :second)]
      )

      DMRateLimiter.reset_request_hourly(sender.id)

      # Second request + decline (backdate past cooldown)
      {:ok, req2} = Chat.create_dm_request(sender.id, recipient.id, "Hi again")
      {:ok, _} = Chat.decline_dm_request(req2.id, recipient.id)

      Repo.update_all(
        from(r in DMRequest, where: r.id == ^req2.id),
        set: [responded_at: DateTime.utc_now() |> DateTime.add(-31 * 24 * 3600, :second)]
      )

      DMRateLimiter.reset_request_hourly(sender.id)

      # Third request + decline triggers auto-block via block_user
      {:ok, req3} = Chat.create_dm_request(sender.id, recipient.id, "Please?")
      {:ok, _} = Chat.decline_dm_request(req3.id, recipient.id)

      # Verify the auto-block happened
      assert Chat.blocked?(recipient.id, sender.id)

      # Verify the trust score block_count was incremented on the sender
      trust_score = Repo.get_by!(UserTrustScore, user_id: sender.id)
      assert trust_score.block_count >= 1
    end
  end
end
