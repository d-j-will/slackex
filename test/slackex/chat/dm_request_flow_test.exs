defmodule Slackex.Chat.DMRequestFlowTest do
  use Slackex.DataCase, async: true

  alias Slackex.Chat
  alias Slackex.Chat.{DMRequest, UserTrustScore}

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

  defp subscribe_to_channel(user, channel) do
    insert(:subscription, %{user: user, channel: channel, role: "member"})
  end

  defp mark_dm_restricted(user) do
    %UserTrustScore{}
    |> UserTrustScore.changeset(%{user_id: user.id, dm_restricted: true})
    |> Repo.insert!()
  end

  # ---------------------------------------------------------------------------
  # Acceptance: pre-flight rejections
  # ---------------------------------------------------------------------------

  describe "create_dm_request/3 pre-flight rejections" do
    test "rejects sender with account under 24 hours old" do
      sender = insert_user_with_age(12)
      recipient = insert_user_with_age(48)

      assert {:error, :account_too_new} =
               Chat.create_dm_request(sender.id, recipient.id, "Hello!")
    end

    test "rejects when block exists from sender to recipient" do
      sender = insert_user_with_age(48)
      recipient = insert_user_with_age(48)
      Chat.block_user(sender.id, recipient.id)

      assert {:error, :blocked} =
               Chat.create_dm_request(sender.id, recipient.id, "Hello!")
    end

    test "rejects when block exists from recipient to sender" do
      sender = insert_user_with_age(48)
      recipient = insert_user_with_age(48)
      Chat.block_user(recipient.id, sender.id)

      assert {:error, :blocked} =
               Chat.create_dm_request(sender.id, recipient.id, "Hello!")
    end

    test "rejects when sender has dm_restricted trust score" do
      sender = insert_user_with_age(48)
      recipient = insert_user_with_age(48)
      mark_dm_restricted(sender)

      assert {:error, :dm_restricted} =
               Chat.create_dm_request(sender.id, recipient.id, "Hello!")
    end

    test "rejects account under 7 days with no shared channels" do
      sender = insert_user_with_age_days(3)
      recipient = insert_user_with_age(48)

      assert {:error, :no_shared_channels} =
               Chat.create_dm_request(sender.id, recipient.id, "Hello!")
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: shared channel gate nuance
  # ---------------------------------------------------------------------------

  describe "create_dm_request/3 shared channel gate" do
    test "allows account under 7 days when shared channel exists" do
      sender = insert_user_with_age_days(3)
      recipient = insert_user_with_age(48)
      channel = insert(:channel)
      subscribe_to_channel(sender, channel)
      subscribe_to_channel(recipient, channel)

      assert {:ok, %DMRequest{status: "pending"}} =
               Chat.create_dm_request(sender.id, recipient.id, "Hello!")
    end

    test "account over 7 days bypasses shared channel gate" do
      sender = insert_user_with_age_days(10)
      recipient = insert_user_with_age(48)
      # No shared channels, but account is old enough

      assert {:ok, %DMRequest{status: "pending"}} =
               Chat.create_dm_request(sender.id, recipient.id, "Hello!")
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: happy path
  # ---------------------------------------------------------------------------

  describe "create_dm_request/3 happy path" do
    test "creates pending dm_request with preview_text on successful pre-flight" do
      sender = insert_user_with_age_days(10)
      recipient = insert_user_with_age(48)

      assert {:ok, dm_request} =
               Chat.create_dm_request(sender.id, recipient.id, "Want to collaborate?")

      assert dm_request.sender_id == sender.id
      assert dm_request.recipient_id == recipient.id
      assert dm_request.preview_text == "Want to collaborate?"
      assert dm_request.status == "pending"
      assert dm_request.id != nil
    end

    test "self-DM request bypasses all pre-flight checks and creates DM directly" do
      sender = insert_user_with_age(1)

      assert {:ok, dm} = Chat.create_dm_request(sender.id, sender.id, "Note to self")

      # Self-DM returns a DMConversation, not a DMRequest
      assert dm.user_a_id == sender.id
      assert dm.user_b_id == sender.id
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance: pre-flight ordering (early exit)
  # ---------------------------------------------------------------------------

  describe "create_dm_request/3 pre-flight ordering" do
    test "account age check runs before block check" do
      # Both conditions would fail, but account_too_new should come first
      sender = insert_user_with_age(12)
      recipient = insert_user_with_age(48)
      Chat.block_user(sender.id, recipient.id)

      assert {:error, :account_too_new} =
               Chat.create_dm_request(sender.id, recipient.id, "Hello!")
    end
  end
end
