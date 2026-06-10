defmodule Slackex.Notifications.PushEligibilityTest do
  @moduledoc """
  Integration tests verifying that PushWorker uses ActiveTracker (not OnlineTracker)
  to gate push delivery. A user who is "online" per heartbeat but not actively
  engaged (tab backgrounded) should still receive a push notification.
  """
  use Slackex.DataCase, async: false
  import Slackex.TestFactory

  alias Slackex.Notifications.{ActiveTracker, OnlineTracker, PushWorker}

  setup do
    Redix.command!(:redix_0, ["FLUSHDB"])
    Process.put(:push_test_pid, self())
    FunWithFlags.enable(:push_notifications)

    :ok
  end

  test "channel push is delivered when user is online but not actively engaged" do
    user = insert(:user)
    sender = insert(:user)
    channel = insert(:channel)
    insert(:subscription, user: user, channel: channel)
    insert(:subscription, user: sender, channel: channel)
    insert(:device_token, user: user, token: "test-token", platform: "web")

    # User is "online" per heartbeat but tab is backgrounded — no active marker.
    OnlineTracker.mark_online(user.id)
    ActiveTracker.mark_inactive(user.id)

    job = %Oban.Job{
      args: %{
        "type" => "new_message",
        "channel_id" => channel.id,
        "sender_id" => sender.id,
        "content" => "hi",
        "sender_username" => sender.username
      }
    }

    assert :ok = PushWorker.perform(job)
    assert_received {:stub_push_sent, "test-token", _payload}
  end

  test "channel push is suppressed when user is actively engaged" do
    user = insert(:user)
    sender = insert(:user)
    channel = insert(:channel)
    insert(:subscription, user: user, channel: channel)
    insert(:subscription, user: sender, channel: channel)
    insert(:device_token, user: user, token: "test-token", platform: "web")

    ActiveTracker.mark_active(user.id)

    job = %Oban.Job{
      args: %{
        "type" => "new_message",
        "channel_id" => channel.id,
        "sender_id" => sender.id,
        "content" => "hi",
        "sender_username" => sender.username
      }
    }

    assert :ok = PushWorker.perform(job)
    refute_received {:stub_push_sent, "test-token", _}
  end

  test "DM push is delivered when recipient is not actively engaged" do
    dm = insert(:dm_conversation)
    insert(:device_token, user: dm.user_b, token: "dm-token", platform: "web")

    OnlineTracker.mark_online(dm.user_b.id)
    ActiveTracker.mark_inactive(dm.user_b.id)

    job = %Oban.Job{
      args: %{
        "type" => "new_dm",
        "dm_conversation_id" => dm.id,
        "sender_id" => dm.user_a_id,
        "content" => "hello",
        "sender_username" => dm.user_a.username
      }
    }

    assert :ok = PushWorker.perform(job)
    assert_received {:stub_push_sent, "dm-token", _payload}
  end
end
